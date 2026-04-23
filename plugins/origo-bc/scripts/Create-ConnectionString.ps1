<#
.SYNOPSIS
    Builds an AES-256-GCM encrypted connection blob for the BC Origo MCP
    server by calling the server's encrypt_data tool, then optionally wraps
    the result with Windows DPAPI (CurrentUser scope).

    The server's resolveConn only accepts encrypted blobs — unencrypted
    "plain:" connection strings are no longer supported.

.DESCRIPTION
    Flow:
      1. Collects BC credentials (tenant, client ID, client secret, environment).
      2. POSTs a JSON-RPC call to the MCP server's encrypt_data tool. The
         server encrypts the credentials JSON with its MCP_ENCRYPTION_KEY
         (AES-256-GCM) and returns a base64 ciphertext.
      3. On Windows (default): DPAPI-wraps the ciphertext so the config file
         is bound to this user + machine. stdio-proxy.js unwraps DPAPI at
         startup and sends the inner AES blob as x-encrypted-conn.
      4. Copies the result to the clipboard.

    Security properties:
      - At rest (config file): DPAPI + AES-256-GCM (double layer).
      - In transit to server: TLS + AES-256-GCM.
      - At server: decrypted only in memory by resolveConn.
      - The client secret is taken as a [SecureString] so it is never echoed
        to the terminal, stored in history, or persisted in a file.

.PARAMETER TenantId
    The BC tenant (e.g. 'dynamics.is').

.PARAMETER ClientId
    The Azure AD app registration's client ID (GUID).

.PARAMETER ClientSecret
    The Azure AD app registration's client secret, as a SecureString.
    If omitted from the command line, PowerShell will prompt with
    masked input.

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

    [Parameter(Mandatory = $true)]
    [System.Security.SecureString] $ClientSecret,

    [ValidateNotNullOrEmpty()]
    [string] $Environment = 'UAT',

    [ValidateNotNullOrEmpty()]
    [string] $McpUrl = 'https://dynamics.is/api/mcp',

    [switch] $NoDpapi
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Create-ConnectionString'

# ── 1. Build the credentials JSON ────────────────────────────────────────────
# Unwrap the SecureString only long enough to build the JSON body, then
# scrub our plaintext copy of the secret.

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
