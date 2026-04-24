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

.PARAMETER Nickname
    One-shot mode. When supplied, the script skips the clipboard hand-off
    and writes a `bc-<Nickname>` entry directly into the Claude Desktop MCP
    config. The config path is auto-detected (MSIX vs classic install) and
    written BOM-free so Claude's JSON parser accepts it.

.PARAMETER CompanyId
    Optional default company GUID to include as the third positional arg
    in the MCP entry's `args` array. Required format: 8-4-4-4-12 hex GUID.
    Only honored when -Nickname is set.

.PARAMETER ConfigPath
    Optional override for the Claude Desktop MCP config file path. If not
    supplied, auto-detect MSIX first, then fall back to %APPDATA%\Claude.
    Only honored when -Nickname is set.

.PARAMETER ScriptsPath
    Where `dynamics-is.js` lives. Defaults to `%USERPROFILE%\OrigoBC`.
    Used only when writing the MCP entry's `command`/`args`.

.PARAMETER InPrivate
    Launch the device-code verification URL in a private / incognito
    browser window (Edge --inprivate, Chrome --incognito, or Firefox
    -private-window). Useful when you want to authenticate as a different
    Entra account than the one currently signed into the default browser.
    Only meaningful with -DeviceCode.

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
    .\Create-ConnectionString.ps1 `
        -TenantId 'kappi.is' `
        -ClientId '<your-client-id-guid>' `
        -DeviceCode -InPrivate `
        -Environment 'Production' `
        -Nickname 'kappi-holdin' `
        -CompanyId '10c11e99-2650-f011-be59-000d3ab119bb'
    # One-shot: device-code in an incognito browser, then writes the
    # bc-kappi-holdin entry directly into the Claude Desktop MCP config.
    # No clipboard round-trip.

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

    [switch] $NoDpapi,

    # ── One-shot config-write mode ──────────────────────────────────────────
    # If -Nickname is supplied, the script writes the bc-<Nickname> entry
    # directly into the Claude Desktop MCP config and skips the fragile
    # clipboard hand-off. Nickname must match the regex below (lower-case
    # letters, digits, hyphens) to avoid surprises in tool names like
    # `mcp__bc-<nickname>__*`.
    [ValidatePattern('^[a-z0-9-]+$')]
    [string] $Nickname,

    [string] $CompanyId,

    [string] $ConfigPath,

    [ValidateNotNullOrEmpty()]
    [string] $ScriptsPath = (Join-Path $env:USERPROFILE 'OrigoBC'),

    # Launch the device-code URL in a private/incognito browser window.
    # Only meaningful when -DeviceCode is also set.
    [switch] $InPrivate,

    # Skip the post-encrypt validation call against list_companies. Use only
    # when the server's tools/call endpoint is temporarily unavailable but
    # you still want to write the config. Strongly discouraged — validation
    # is what catches rotated secrets, wrong scopes, and server-side routing
    # bugs before they become broken MCP entries.
    [switch] $SkipValidation
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Create-ConnectionString'

# ── Validate parameter combinations ──────────────────────────────────────────
if ($DeviceCode -and $ClientSecret) {
    throw "[$ScriptName] -ClientSecret and -DeviceCode are mutually exclusive."
}
if (-not $DeviceCode -and -not $ClientSecret) {
    # Prompt interactively with masked input so the secret never appears on
    # the command line, in history, or on stdout.
    $ClientSecret = Read-Host -AsSecureString "Enter BC client secret"
    if (-not $ClientSecret -or $ClientSecret.Length -eq 0) {
        throw "[$ScriptName] Client secret is required (or use -DeviceCode)."
    }
}

# ── One-shot mode validation ─────────────────────────────────────────────────
# -Nickname triggers direct config-write. It needs a DPAPI-wrapped blob
# (stdio-proxy.js requires "dpapi:" on Windows) and a well-formed CompanyId.
if ($Nickname) {
    if ($NoDpapi) {
        throw "[$ScriptName] -Nickname writes a Windows MCP config entry which requires a DPAPI-wrapped blob. Drop -NoDpapi or drop -Nickname."
    }
    if ($CompanyId) {
        $normalized = $CompanyId -replace '^\{(.*)\}$', '$1'
        if ($normalized -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            throw "[$ScriptName] -CompanyId must be a GUID in 8-4-4-4-12 hex format. Got: $CompanyId"
        }
        $CompanyId = $normalized
    }
}
if ($InPrivate -and -not $DeviceCode) {
    Write-Host "[$ScriptName] -InPrivate has no effect without -DeviceCode; ignoring." -ForegroundColor Yellow
}

# ── Device-code flow helper ──────────────────────────────────────────────────
# Initiates the OAuth 2.0 device code flow against Entra ID and polls for
# the user to complete authentication. Returns the refresh token.

function Invoke-DeviceCodeFlow {
    param(
        [string] $Tenant,
        [string] $Client,
        [switch] $UseInPrivate
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

    # Step 1b: Open the verification URL. In -InPrivate mode try each known
    # private-browsing flag until one launches; otherwise fall back to
    # Start-Process (honours the user's default browser).
    $opened = $false
    if ($UseInPrivate) {
        $candidates = @(
            @{ Name = 'msedge';   Args = @('--inprivate',       $dcResponse.verification_uri) },
            @{ Name = 'chrome';   Args = @('--incognito',       $dcResponse.verification_uri) },
            @{ Name = 'brave';    Args = @('--incognito',       $dcResponse.verification_uri) },
            @{ Name = 'firefox';  Args = @('-private-window',   $dcResponse.verification_uri) }
        )
        foreach ($c in $candidates) {
            try {
                Start-Process -FilePath $c.Name -ArgumentList $c.Args -ErrorAction Stop | Out-Null
                Write-Host "[$ScriptName] Opened verification URL in $($c.Name) (private window)." -ForegroundColor DarkGray
                $opened = $true
                break
            } catch {
                # Browser not installed / not on PATH — try the next one.
                continue
            }
        }
        if (-not $opened) {
            Write-Host "[$ScriptName] Couldn't launch a private browser window. Open the URL manually." -ForegroundColor Yellow
        }
    }
    if (-not $opened) {
        try {
            Start-Process $dcResponse.verification_uri
        } catch {
            # Non-fatal — user can open the URL manually
        }
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
    $refreshToken = Invoke-DeviceCodeFlow -Tenant $TenantId -Client $ClientId -UseInPrivate:$InPrivate

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

# ── 2b. End-to-end validation before writing anything to disk ────────────────
# Round-trip the fresh AES ciphertext through the server's list_companies
# tool. If the server cannot use these credentials to authenticate with BC,
# fail now instead of writing a broken entry into the Cowork MCP config that
# the user will only discover after a full app restart. Catches:
#   - Rotated or wrong client secret.
#   - Device-code refresh token with insufficient scopes.
#   - Server-side routing bugs (e.g. client-credentials grant used when the
#     payload only contains a refreshToken).
# Use -SkipValidation only if list_companies is temporarily down.
if (-not $SkipValidation) {
    Write-Host "[$ScriptName] Validating credentials via list_companies ..." -ForegroundColor Cyan

    $validateBody = @{
        jsonrpc = '2.0'
        id      = 2
        method  = 'tools/call'
        params  = @{
            name      = 'list_companies'
            arguments = @{ encryptedConn = $aesCiphertext }
        }
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $vResp = Invoke-WebRequest -Uri $McpUrl -Method POST `
            -Headers @{ 'Accept' = 'application/json, text/event-stream' } `
            -ContentType 'application/json' `
            -Body $validateBody -UseBasicParsing
    } catch {
        throw "[$ScriptName] Validation request to $McpUrl failed: $($_.Exception.Message)"
    }

    $vJson = $vResp.Content | ConvertFrom-Json

    # JSON-RPC-level error (e.g. server requires initialize first)
    if ($vJson.error) {
        throw "[$ScriptName] Validation failed (JSON-RPC error $($vJson.error.code)): $($vJson.error.message)"
    }

    # Tool-level error. MCP surfaces these two ways in practice:
    #   1. result.isError = true, with the message in content[0].text
    #   2. result.content[0].text starts with "Error:" / "Token error" / "Unauthorized"
    $resultText = $null
    if ($vJson.result -and $vJson.result.content -and $vJson.result.content.Count -gt 0) {
        $resultText = $vJson.result.content[0].text
    }

    if ($vJson.result -and $vJson.result.isError) {
        throw "[$ScriptName] Validation failed: $resultText"
    }
    if ($resultText -and $resultText -match '^\s*(Error|Token error|Unauthorized|Forbidden|AADSTS)\b') {
        throw "[$ScriptName] Validation failed: $resultText"
    }

    # Try to parse the response for a nicer status line, but don't fail if the
    # shape is unfamiliar — any non-error response means auth worked.
    $suffix = ''
    try {
        $companies = $resultText | ConvertFrom-Json -ErrorAction Stop
        $count =
            if ($companies -is [System.Array])     { $companies.Count }
            elseif ($companies.companies)          { $companies.companies.Count }
            elseif ($companies.value)              { $companies.value.Count }
            else                                   { $null }
        if ($null -ne $count) {
            $plural = if ($count -eq 1) { 'company' } else { 'companies' }
            $suffix = " ($count $plural visible)"
        }
    } catch { }

    Write-Host "[$ScriptName] Validation OK — credentials work$suffix." -ForegroundColor Green
}

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

# ── 4. Output: clipboard hand-off OR direct MCP config patch ─────────────────
# Clipboard-as-IPC is fragile (any subsequent copy clobbers the blob, leaving
# downstream steps to paste the wrong thing into the config). When -Nickname
# is supplied we skip the clipboard entirely and write the config ourselves.

if ($Nickname) {
    # ── Resolve config path: explicit override → MSIX → classic ──────────────
    $resolvedCfgPath = if ($ConfigPath) {
        $ConfigPath
    } else {
        $msixCfg    = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json'
        $classicCfg = Join-Path $env:APPDATA      'Claude\claude_desktop_config.json'
        if (Test-Path $msixCfg) { $msixCfg } else { $classicCfg }
    }

    Write-Host "[$ScriptName] Patching $resolvedCfgPath" -ForegroundColor DarkGray

    # Ensure file + parent directory exist. Initialize with an empty
    # mcpServers shell so the ConvertFrom-Json round-trip has something to
    # hang new entries off. Important: write BOM-free — Claude's JSON parser
    # rejects the UTF-8 BOM with "Unexpected token '\uFEFF'".
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $cfgDir = Split-Path -Parent $resolvedCfgPath
    if ($cfgDir -and -not (Test-Path $cfgDir)) {
        New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    }
    if (-not (Test-Path $resolvedCfgPath)) {
        New-Item -ItemType File -Path $resolvedCfgPath -Force | Out-Null
        [System.IO.File]::WriteAllText($resolvedCfgPath, '{ "mcpServers": {} }', $utf8NoBom)
    }

    # Read + parse current config. Guard against an empty file (ConvertFrom-Json
    # would throw) and against a missing mcpServers property.
    $raw = Get-Content $resolvedCfgPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
    $cfg = $raw | ConvertFrom-Json
    if (-not $cfg.PSObject.Properties.Match('mcpServers').Count) {
        $cfg | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{})
    }

    $entryKey = "bc-$Nickname"

    # Build the args array conditionally — stdio-proxy.js treats arg[2] as the
    # default company GUID and arg[3]+ as ignored, so only include the company
    # element if the caller supplied one.
    $dynamicsPath = Join-Path $ScriptsPath 'dynamics-is.js'
    $argsList = @($dynamicsPath, $dpapiValue)
    if ($CompanyId) { $argsList += $CompanyId }

    $entry = [pscustomobject]@{
        command = 'node'
        args    = $argsList
    }

    if ($cfg.mcpServers.PSObject.Properties.Match($entryKey).Count) {
        # Overwrite existing entry. The blob & company GUID are the parts most
        # likely to be stale, so replacing wholesale is the safer default than
        # trying to merge in place.
        $cfg.mcpServers.$entryKey = $entry
        Write-Host "[$ScriptName] Replaced existing $entryKey entry." -ForegroundColor Yellow
    } else {
        $cfg.mcpServers | Add-Member -MemberType NoteProperty -Name $entryKey -Value $entry
        Write-Host "[$ScriptName] Added new $entryKey entry." -ForegroundColor Green
    }

    # Atomic-ish write: render JSON, then a single WriteAllText call replaces
    # the file contents. -Depth 20 covers nested args / env blocks other
    # servers sometimes add. BOM-free encoding is critical.
    $json = $cfg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($resolvedCfgPath, $json, $utf8NoBom)

    # Drop the blob from memory. The file on disk is DPAPI-wrapped anyway.
    $dpapiValue = $null

    Write-Host ""
    Write-Host "[$ScriptName] Done. Restart Cowork / Claude Desktop to activate $entryKey." -ForegroundColor Green
    Write-Host "[$ScriptName] Verify with: mcp__${entryKey}__list_companies" -ForegroundColor Green
    return
}

# ── Legacy clipboard hand-off ────────────────────────────────────────────────
try {
    $dpapiValue | Set-Clipboard
    Write-Host "[$ScriptName] dpapi:<...> value copied to clipboard." -ForegroundColor Green
    Write-Host "[$ScriptName] Paste it into the x-encrypted-conn arg" -ForegroundColor Green
    Write-Host "[$ScriptName] of your MCP config (stdio-proxy arg 1)." -ForegroundColor Green
} catch {
    Write-Host "[$ScriptName] Clipboard unavailable; printing value instead:" -ForegroundColor Yellow
    Write-Output $dpapiValue
}
