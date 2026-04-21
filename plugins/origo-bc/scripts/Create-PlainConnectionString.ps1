<#
.SYNOPSIS
    Builds a "plain:<base64>" connection blob for the BC Origo MCP server and
    wraps it with Windows DPAPI (CurrentUser scope). Nothing is sent over the
    network — the blob is just base64-encoded JSON, and the server accepts it
    directly via resolveConn's "plain:" branch.

    Output is a "dpapi:<base64>" string which stdio-proxy.js auto-unwraps at
    startup. The inner value after DPAPI unwrap is "plain:<base64-json>".

.DESCRIPTION
    Unlike Create-ConnectionString.ps1, this script does NOT call the server's
    encrypt_data tool. There is no HTTPS round-trip. The security properties
    on Windows are:

      • Config file at rest: protected by DPAPI (same as before — copied
        config is useless on another Windows user account or machine).
      • In transit to server: protected by TLS (same as before).
      • At rest in server logs / memory: credentials are handled the same
        way as with the old flow, because resolveConn ends up with the same
        plaintext either way.

    The client secret is taken as a [SecureString] so it is never echoed to
    the terminal, stored in PowerShell history, or persisted in a file. It
    is briefly unwrapped in memory only to build the JSON body, then scrubbed.

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

.PARAMETER NoDpapi
    Skip the DPAPI wrap and emit the raw "plain:<base64>" string instead.
    Use this on non-Windows platforms, or when you explicitly want a portable
    blob (understanding that anyone with the file can use it).

.EXAMPLE
    .\Create-PlainConnectionString.ps1 `
        -TenantId 'dynamics.is' `
        -ClientId '<your-client-id-guid>' `
        -Environment 'UAT'
    # Prompts for ClientSecret (masked), copies "dpapi:<...>" to clipboard.

.EXAMPLE
    $sec = Read-Host -AsSecureString 'BC client secret'
    .\Create-PlainConnectionString.ps1 `
        -TenantId 'dynamics.is' `
        -ClientId '<your-client-id-guid>' `
        -ClientSecret $sec `
        -NoDpapi
    # Emits "plain:<base64>" without DPAPI wrap (cross-platform friendly).
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

    [switch] $NoDpapi
)

$ErrorActionPreference = 'Stop'

# ── 1. Build base64-encoded JSON with the connection fields ──────────────────
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

$plainBytes  = [System.Text.Encoding]::UTF8.GetBytes($payload)
$payload     = $null   # drop plaintext JSON too
$plainB64    = [Convert]::ToBase64String($plainBytes)

# Best-effort scrub of the plaintext JSON buffer.
for ($i = 0; $i -lt $plainBytes.Length; $i++) { $plainBytes[$i] = 0 }

$plainValue = 'plain:' + $plainB64

if ($NoDpapi) {
    # ── 2a. Emit the plain:<base64> string directly ──────────────────────────
    try {
        $plainValue | Set-Clipboard
        Write-Host '[Create-PlainConnectionString] plain:<...> value copied to clipboard.' -ForegroundColor Green
        Write-Host '[Create-PlainConnectionString] Paste it into the x-encrypted-conn arg' -ForegroundColor Green
        Write-Host '[Create-PlainConnectionString] of your MCP config (stdio-proxy arg 1).' -ForegroundColor Green
        Write-Host '[Create-PlainConnectionString] WARNING: No DPAPI wrap. Protect the config file with filesystem permissions.' -ForegroundColor Yellow
    } catch {
        Write-Host '[Create-PlainConnectionString] Clipboard unavailable; printing value instead:' -ForegroundColor Yellow
        Write-Output $plainValue
    }
    return
}

# ── 2b. Protect the plain: blob with DPAPI (CurrentUser) ─────────────────────
# Same primitive PowerShell's ConvertFrom-SecureString uses when no -Key is
# supplied. The resulting ciphertext can only be unwrapped by this Windows
# user on this machine. stdio-proxy.js unwraps it at startup and forwards
# the inner "plain:<base64>" string verbatim as the x-encrypted-conn header.

if (-not $IsWindows -and $PSVersionTable.Platform -ne $null) {
    throw "DPAPI is Windows-only. Re-run with -NoDpapi on this platform."
}

Add-Type -AssemblyName System.Security | Out-Null

$plainValueBytes = [System.Text.Encoding]::UTF8.GetBytes($plainValue)
try {
    $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainValueBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
} finally {
    for ($i = 0; $i -lt $plainValueBytes.Length; $i++) { $plainValueBytes[$i] = 0 }
    $plainValue = $null
}

$dpapiValue = 'dpapi:' + [Convert]::ToBase64String($cipherBytes)

# ── 3. Hand the protected value to the user ──────────────────────────────────

try {
    $dpapiValue | Set-Clipboard
    Write-Host '[Create-PlainConnectionString] dpapi:<...> value copied to clipboard.' -ForegroundColor Green
    Write-Host '[Create-PlainConnectionString] Paste it into the x-encrypted-conn arg' -ForegroundColor Green
    Write-Host '[Create-PlainConnectionString] of your MCP config (stdio-proxy arg 1).' -ForegroundColor Green
} catch {
    Write-Host '[Create-PlainConnectionString] Clipboard unavailable; printing value instead:' -ForegroundColor Yellow
    Write-Output $dpapiValue
}
