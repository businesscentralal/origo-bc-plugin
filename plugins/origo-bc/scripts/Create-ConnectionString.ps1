<#
.SYNOPSIS
    Builds an AES-256-GCM encrypted connection blob for the BC Origo MCP
    server by calling the server's encrypt_data tool, then optionally wraps
    the result with Windows DPAPI (CurrentUser scope).

    The server's resolveConn only accepts encrypted blobs — unencrypted
    "plain:" connection strings are no longer supported.

.DESCRIPTION
    Two authentication flows are supported:

    Client-secret flow (default):
      1. Collects BC credentials (tenant, client ID, client secret, environment).
      2. POSTs a JSON-RPC call to the MCP server's encrypt_data tool.
      3. The blob contains { tenantId, clientId, clientSecret, environment }.

    Device-code flow (-DeviceCode switch):
      1. Initiates an OAuth 2.0 device code flow against Entra ID.
      2. User authenticates in a browser using the displayed code.
      3. On success, stores the refresh token in the blob instead of a
         client secret. The blob contains { tenantId, clientId, refreshToken,
         environment }.
      4. The MCP server uses the refresh token to acquire access tokens
         on behalf of the user (delegated permissions).

    In both cases the credentials JSON is encrypted server-side with
    MCP_ENCRYPTION_KEY (AES-256-GCM). On Windows (default) the ciphertext
    is additionally wrapped with DPAPI (CurrentUser scope).

    Security properties:
      - At rest (config file): DPAPI + AES-256-GCM (double layer).
      - In transit to server: TLS + AES-256-GCM.
      - At server: decrypted only in memory by resolveConn.
      - The client secret is taken as a [SecureString] so it is never echoed
        to the terminal, stored in history, or persisted in a file.
      - The refresh token is handled identically to the client secret — never
        echoed or persisted in plaintext.

.PARAMETER TenantId
    The BC tenant (e.g. 'dynamics.is').

.PARAMETER ClientId
    The Azure AD app registration's client ID (GUID).

.PARAMETER ClientSecret
    The Azure AD app registration's client secret, as a SecureString.
    Required unless -DeviceCode is specified. If omitted from the command
    line, PowerShell will prompt with masked input.

.PARAMETER DeviceCode
    Use the OAuth 2.0 device code flow instead of a client secret.
    The user authenticates interactively in a browser. The resulting
    refresh token is stored in the connection blob.

.PARAMETER Environment
    BC environment name (e.g. 'UAT', 'Production'). Defaults to 'UAT'.

.PARAMETER McpUrl
    URL of the MCP server endpoint. Defaults to 'https://dynamics.is/api/mcp'.

.PARAMETER NoDpapi
    Skip the DPAPI wrap and emit the raw AES ciphertext string instead.
    Use this on non-Windows platforms. The blob is still encrypted with the
    server's key — it just isn't machine-bound.

.EXAMPLE
    .\Create-ConnectionString.ps1 `
        -TenantId 'dynamics.is' `
        -ClientId '<your-client-id-guid>' `
        -Environment 'UAT'
    # Prompts for ClientSecret (masked), copies "dpapi:<...>" to clipboard.

.EXAMPLE
    .\Create-ConnectionString.ps1 `
        -TenantId 'dynamics.is' `
        -ClientId '<your-client-id-guid>' `
        -DeviceCode `
        -Environment 'UAT'
    # Opens device code flow in browser, copies "dpapi:<...>" to clipboard.

.EXAMPLE
    $sec = Read-Host -AsSecureString 'BC client secret'
    .\Create-ConnectionString.ps1 `
        -TenantId 'dynamics.is' `
        -ClientId '<your-client-id-guid>' `
        -ClientSecret $sec `
        -NoDpapi
    # Emits the AES ciphertext without DPAPI wrap (cross-platform friendly).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ClientId,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString] $ClientSecret,

    [switch] $DeviceCode,

    [ValidateNotNullOrEmpty()]
    [string] $Environment = 'UAT',

    [ValidateNotNullOrEmpty()]
    [string] $McpUrl = 'https://dynamics.is/api/mcp',

    [switch] $NoDpapi
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Create-ConnectionString'

# ── Validate parameter combinations ──────────────────────────────────────────
if (-not $DeviceCode -and -not $ClientSecret) {
    throw "[$ScriptName] Either -ClientSecret or -DeviceCode must be specified."
}
if ($DeviceCode -and $ClientSecret) {
    throw "[$ScriptName] -ClientSecret and -DeviceCode are mutually exclusive."
}

# ── Device-code flow helper ──────────────────────────────────────────────────
# Initiates the OAuth 2.0 device code flow against Entra ID and polls for
# the user to complete authentication. Returns the refresh token.

function Invoke-DeviceCodeFlow {
    param(
        [string] $Tenant,
        [string] $Client
    )

    $deviceCodeUrl = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode"
    $tokenUrl      = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
    $scope         = 'https://api.businesscentral.dynamics.com/.default offline_access'

    # Step 1: Request a device code
    $dcResponse = Invoke-RestMethod -Uri $deviceCodeUrl -Method POST -Body @{
        client_id = $Client
        scope     = $scope
    } -ContentType 'application/x-www-form-urlencoded'

    Write-Host ""
    Write-Host "[$ScriptName] ── Device Code Authentication ──" -ForegroundColor Cyan
    Write-Host "[$ScriptName] $($dcResponse.message)" -ForegroundColor Yellow
    Write-Host ""

    # Try to open the verification URL in the default browser
    try {
        Start-Process $dcResponse.verification_uri
    } catch {
        # Non-fatal — user can open the URL manually
    }

    # Step 2: Poll for token
    $interval = [math]::Max($dcResponse.interval, 5)
    $expiry   = (Get-Date).AddSeconds($dcResponse.expires_in)

    while ((Get-Date) -lt $expiry) {
        Start-Sleep -Seconds $interval

        try {
            $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body @{
                client_id  = $Client
                grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                device_code = $dcResponse.device_code
            } -ContentType 'application/x-www-form-urlencoded'

            # Success — return the refresh token
            if (-not $tokenResponse.refresh_token) {
                throw "[$ScriptName] Token response did not include a refresh_token. Ensure the app registration has offline_access scope."
            }
            Write-Host "[$ScriptName] Authentication successful." -ForegroundColor Green
            return $tokenResponse.refresh_token
        } catch {
            $err = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($err.error -eq 'authorization_pending') {
                # User hasn't completed auth yet — keep polling
                continue
            } elseif ($err.error -eq 'slow_down') {
                $interval += 5
                continue
            } else {
                $errorDesc = if ($err.error_description) { $err.error_description } else { $_.Exception.Message }
                throw "[$ScriptName] Device code flow failed: $errorDesc"
            }
        }
    }

    throw "[$ScriptName] Device code flow timed out. Please try again."
}

# ── 1. Build the credentials JSON ────────────────────────────────────────────

if ($DeviceCode) {
    # Device code flow — get a refresh token interactively
    $refreshToken = Invoke-DeviceCodeFlow -Tenant $TenantId -Client $ClientId

    $payload = [ordered]@{
        tenantId     = $TenantId
        clientId     = $ClientId
        refreshToken = $refreshToken
        environment  = $Environment
    } | ConvertTo-Json -Compress

    $refreshToken = $null   # drop plaintext refresh token
} else {
    # Client secret flow — unwrap the SecureString only long enough to build JSON
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    try {
        $secretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $payload = [ordered]@{
        tenantId     = $TenantId
        clientId     = $ClientId
        clientSecret = $secretPlain
        environment  = $Environment
    } | ConvertTo-Json -Compress

    $secretPlain = $null   # drop our plaintext copy of the secret
}

# ── 2. Call the MCP server's encrypt_data tool ────────────────────────────────
# No authentication headers are needed — encrypt_data is an open tool.
# It encrypts the payload with AES-256-GCM using the server's MCP_ENCRYPTION_KEY.

$rpcBody = @{
    jsonrpc = '2.0'
    id      = 1
    method  = 'tools/call'
    params  = @{
        name      = 'encrypt_data'
        arguments = @{ plaintext = $payload }
    }
} | ConvertTo-Json -Depth 10 -Compress

$payload = $null   # drop plaintext JSON

Write-Host "[$ScriptName] Calling encrypt_data at $McpUrl ..." -ForegroundColor Cyan

try {
    $response = Invoke-WebRequest -Uri $McpUrl -Method POST `
        -ContentType 'application/json' -Body $rpcBody -UseBasicParsing
} catch {
    throw "[$ScriptName] Failed to reach MCP server at $McpUrl : $_"
}

$rpcBody = $null   # contains plaintext in the arguments

$json = $response.Content | ConvertFrom-Json

if ($json.error) {
    throw "[$ScriptName] encrypt_data returned error: $($json.error.message)"
}

# The encrypt_data tool returns { content: [{ type: "text", text: "{\"ciphertext\":\"...\"}" }] }
$innerText = $json.result.content[0].text
$inner = $innerText | ConvertFrom-Json
$aesCiphertext = $inner.ciphertext

if (-not $aesCiphertext) {
    throw "[$ScriptName] encrypt_data response did not contain a ciphertext field."
}

Write-Host "[$ScriptName] Credentials encrypted successfully (AES-256-GCM)." -ForegroundColor Green

# ── 3. Output ─────────────────────────────────────────────────────────────────

if ($NoDpapi) {
    # Emit the raw AES ciphertext — already encrypted, just not machine-bound.
    try {
        $aesCiphertext | Set-Clipboard
        Write-Host "[$ScriptName] AES ciphertext copied to clipboard." -ForegroundColor Green
        Write-Host "[$ScriptName] Paste it into the x-encrypted-conn arg" -ForegroundColor Green
        Write-Host "[$ScriptName] of your MCP config (stdio-proxy arg 1)." -ForegroundColor Green
        Write-Host "[$ScriptName] NOTE: No DPAPI wrap — the blob is still AES-encrypted" -ForegroundColor Yellow
        Write-Host "[$ScriptName] but not bound to this machine/user." -ForegroundColor Yellow
    } catch {
        Write-Host "[$ScriptName] Clipboard unavailable; printing value instead:" -ForegroundColor Yellow
        Write-Output $aesCiphertext
    }
    return
}

# ── 3b. DPAPI-wrap the AES ciphertext (CurrentUser) ──────────────────────────
# The resulting blob can only be unwrapped by this Windows user on this
# machine. stdio-proxy.js unwraps DPAPI at startup and forwards the inner
# AES ciphertext as the x-encrypted-conn header. The server then decrypts
# with MCP_ENCRYPTION_KEY.

if (-not $IsWindows -and $PSVersionTable.Platform -ne $null) {
    throw "DPAPI is Windows-only. Re-run with -NoDpapi on this platform."
}

Add-Type -AssemblyName System.Security | Out-Null

$aesBytes = [System.Text.Encoding]::UTF8.GetBytes($aesCiphertext)
try {
    $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $aesBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
} finally {
    for ($i = 0; $i -lt $aesBytes.Length; $i++) { $aesBytes[$i] = 0 }
    $aesCiphertext = $null
}

$dpapiValue = 'dpapi:' + [Convert]::ToBase64String($cipherBytes)

try {
    $dpapiValue | Set-Clipboard
    Write-Host "[$ScriptName] dpapi:<...> value copied to clipboard." -ForegroundColor Green
    Write-Host "[$ScriptName] Paste it into the x-encrypted-conn arg" -ForegroundColor Green
    Write-Host "[$ScriptName] of your MCP config (stdio-proxy arg 1)." -ForegroundColor Green
} catch {
    Write-Host "[$ScriptName] Clipboard unavailable; printing value instead:" -ForegroundColor Yellow
    Write-Output $dpapiValue
}
