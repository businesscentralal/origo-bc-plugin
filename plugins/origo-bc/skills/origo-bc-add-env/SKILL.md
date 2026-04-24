---
name: origo-bc-add-env
description: >
  Add another Business Central tenant or environment to an existing Origo
  BC setup in Cowork. Use this skill when the user types
  `/origo-bc-add-env`, says they want to add a new BC tenant, hook up a
  second environment, register another BC company, or connect Cowork to an
  additional dynamics.is BC install. Re-uses the scripts already installed
  under `%USERPROFILE%\OrigoBC\` and only appends a new entry to the Cowork
  MCP config.
metadata:
  version: "0.6.0"
  author: "Origo hf."
---

# `/origo-bc-add-env` — Add another BC tenant / environment

Adds a new `bc-<nickname>` entry to the Cowork MCP config using the
scripts already installed under `%USERPROFILE%\OrigoBC\`. Does **not**
reinstall scripts; if that folder is missing, redirect the user to
`/origo-bc-setup` instead.

## Preconditions

Before doing anything:

1. **Node.js 18+ must be on PATH.** Run `node --version`; abort if the
   command fails or reports a major version below 18. Cowork launches each
   `bc-*` entry as `node <path>\dynamics-is.js ...`, so there is no point
   adding a broken entry. Tell the user:

   > I can't add another BC environment without Node.js 18+. Install it
   > from <https://nodejs.org/> (LTS is fine), open a new Cowork session
   > so PATH refreshes, then re-run `/origo-bc-add-env`.

2. `%USERPROFILE%\OrigoBC\dynamics-is.js` exists. If it doesn't, offer to
   download the scripts directly from the public GitHub mirror:

   **Windows PowerShell:**

   ```powershell
   $dir = "$env:USERPROFILE\OrigoBC"
   New-Item -ItemType Directory -Force -Path $dir | Out-Null
   $base    = 'https://raw.githubusercontent.com/businesscentralal/origo-bc-plugin/main/plugins/origo-bc/scripts'
   $utf8Bom = New-Object System.Text.UTF8Encoding($true)
   @('dynamics-is.js', 'Create-ConnectionString.ps1', 'create-connection-string.js') | ForEach-Object {
       $dst  = Join-Path $dir $_
       # Invoke-WebRequest.Content is a decoded string; re-save with a UTF-8
       # BOM so Windows PowerShell 5.1 parses em-dashes / non-ASCII chars in
       # the .ps1 source correctly. PS 5.1 defaults to ANSI/CP1252 for .ps1
       # and will otherwise mis-read '—' as bytes that include a stray
       # closing quote, silently breaking string parsing later in the file.
       $text = (Invoke-WebRequest -Uri "$base/$_" -UseBasicParsing).Content
       [System.IO.File]::WriteAllText($dst, $text, $utf8Bom)
       Write-Host "Downloaded $_" -ForegroundColor Green
   }
   ```

   **macOS / Linux:**

   ```bash
   dir="$HOME/OrigoBC"
   mkdir -p "$dir"
   base='https://raw.githubusercontent.com/businesscentralal/origo-bc-plugin/main/plugins/origo-bc/scripts'
   for f in dynamics-is.js Create-ConnectionString.ps1 create-connection-string.js; do
       curl -fsSL "$base/$f" -o "$dir/$f"
       echo "Downloaded $f"
   done
   ```

   Alternatively, redirect the user to `/origo-bc-setup` for the full
   guided experience.

## What this command does

1. Confirm `%USERPROFILE%\OrigoBC\` is already populated.
2. Ask (via `AskUserQuestion`, one at a time):
   - Short nickname (must be unique vs. existing `bc-*` entries).
   - Tenant ID, client ID, environment.
   - Authentication method (client secret or device code).
   - Whether to launch the device-code URL in a private / incognito
     browser window (only relevant for device code).
   - Optional default company GUID.
3. Present **one** PowerShell command that generates the AES+DPAPI blob,
   **validates it against the server's `list_companies` tool end-to-end**,
   **and** writes the new `bc-<nickname>` entry into the Claude Desktop
   MCP config — all in a single invocation (via
   `Create-ConnectionString.ps1 -Nickname …`). No clipboard round-trip,
   and the config is not written if validation fails.
4. Prompt the user to restart Cowork and verify with
   `mcp__bc-<nickname>__list_companies`.

## Why one command

Earlier versions of this skill printed two PowerShell blocks — first the
helper to generate the blob (which ended with `Set-Clipboard`), then a
second block that read `Get-Clipboard` and patched the config. That
design is fragile: anything copied between the two blocks (for example,
the second block itself!) clobbers the clipboard, and the config ends up
with whatever text happened to be on the clipboard at the time. One
command eliminates the whole IPC hand-off.

## Uniqueness check

Before asking for the nickname, read the current MCP config and list the
existing `bc-*` keys back to the user as forbidden values. If the user's
chosen nickname collides, ask again.

## Guardrails

Same as `/origo-bc-setup`:

- Never prompt for the client secret or refresh token in chat.
- Never attempt to decrypt or inspect the AES blob.
- Atomic write of the config (temp file + rename).

## Windows PowerShell pitfalls — READ BEFORE WRITING COMMANDS

The same three traps apply as in `/origo-bc-setup`. Full detail in that
skill; the short version:

1. **`Set-Content -Encoding UTF8` adds a BOM in PS 5.1** — Claude's JSON
   parser rejects the config with `Unexpected token '﻿'`. Always write
   the config via
   `[System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))`.
2. **Downloaded `.ps1` files must be re-saved with a UTF-8 BOM.** PS 5.1
   reads `.ps1` as ANSI/CP1252 by default and mis-parses em-dashes and
   other non-ASCII characters. The download block above handles this.
3. **The Claude config path differs between MSIX and classic installs.**
   Store/MSIX Claude lives at
   `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json`;
   classic installs use `%APPDATA%\Claude\claude_desktop_config.json`.
   Auto-detect both in Step 6.

Rule of thumb: **config JSON — BOM off. Script `.ps1` — BOM on. Don't swap.**

## Step-by-step

### Step 1 — Verify Node.js and the existing install

```bash
node --version   # must exit 0 and report v18+ (v18/v20/v22 LTS all fine)
test -f "$USERPROFILE/OrigoBC/dynamics-is.js" && echo OK
```

If either check fails, stop and redirect the user (Node → <https://nodejs.org/>;
missing install → `/origo-bc-setup`).

### Step 2 — List existing entries

Read the active Claude config (auto-detect MSIX vs classic path — see
pitfall #3 above), enumerate keys under `mcpServers` that start with
`bc-`, and show them to the user so they can pick a non-colliding
nickname. Example probe block the user can run if Claude itself is the
source of truth:

```powershell
$msixCfg    = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json'
$classicCfg = Join-Path $env:APPDATA      'Claude\claude_desktop_config.json'
$cfgPath = if (Test-Path $msixCfg) { $msixCfg } else { $classicCfg }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$cfg.mcpServers.PSObject.Properties.Name | Where-Object { $_ -like 'bc-*' }
```

Claude can also just read the current tool surface it can see — any
`mcp__bc-<nickname>__*` tool implies that nickname is already in use.

### Step 3 — Collect coordinates

Use `AskUserQuestion` (one question at a time) for: nickname, tenant,
client, **authentication method** (Client secret or Device code),
environment, and — if Device code — whether to use a **private /
incognito browser window** for sign-in (useful when you want to
authenticate as a different Entra account than the one already signed in
to the default browser). Finally, optional default company GUID.

See `/origo-bc-setup` Step 3 for the explanation of each auth method.

### Step 4 — Make sure the local script is current

The one-shot `-Nickname` mode was added in
`Create-ConnectionString.ps1` v0.5.0+. If the user installed Origo BC
before that, overwrite the local copy from the GitHub mirror so they
pick up the new params:

```powershell
$dir     = "$env:USERPROFILE\OrigoBC"
$base    = 'https://raw.githubusercontent.com/businesscentralal/origo-bc-plugin/main/plugins/origo-bc/scripts'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
# UTF-8 WITH BOM for .ps1 — PS 5.1 mis-parses em-dashes otherwise.
$text = (Invoke-WebRequest -Uri "$base/Create-ConnectionString.ps1" -UseBasicParsing).Content
[System.IO.File]::WriteAllText((Join-Path $dir 'Create-ConnectionString.ps1'), $text, $utf8Bom)
Write-Host "Refreshed Create-ConnectionString.ps1" -ForegroundColor Green
```

Skip this step if `/origo-bc-setup` was just run in the same session;
it already pulled the current version.

**If you are copying from a local working tree instead of GitHub** (for
example, developing the plugin in-place), you must still re-save with a
UTF-8 BOM. A naive `Copy-Item` preserves the source's byte-for-byte
encoding; if the source is UTF-8 *without* a BOM, PS 5.1 will
mis-parse the em-dashes (`──`, `→`) inside the script's section
headers and fail with `Missing closing '}'` errors hundreds of lines
away from the actual cause. Correct pattern:

```powershell
$src     = '<path-to-working-tree>\Create-ConnectionString.ps1'
$dst     = "$env:USERPROFILE\OrigoBC\Create-ConnectionString.ps1"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$text    = [System.IO.File]::ReadAllText($src)
[System.IO.File]::WriteAllText($dst, $text, $utf8Bom)
```

Do **not** use `Copy-Item` for this step.

### Step 5 — One-shot: generate the blob AND write the config

Present a **single** PowerShell command. The script encrypts the
credentials, DPAPI-wraps the result, auto-detects MSIX vs classic
Claude, and writes the `bc-<nickname>` entry BOM-free — all in one
invocation. No clipboard hand-off.

**Client secret flow** (prompts for the secret with masked input):

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId    '<tenant>' `
  -ClientId    '<client>' `
  -Environment '<env>' `
  -Nickname    '<nickname>' `
  -CompanyId   '<default-company-guid>'
```

**Device-code flow** (opens a browser for interactive sign-in):

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId    '<tenant>' `
  -ClientId    '<client>' `
  -DeviceCode `
  -Environment '<env>' `
  -Nickname    '<nickname>' `
  -CompanyId   '<default-company-guid>'
```

If the user chose the private-browser option, append `-InPrivate`:

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId    '<tenant>' `
  -ClientId    '<client>' `
  -DeviceCode -InPrivate `
  -Environment '<env>' `
  -Nickname    '<nickname>' `
  -CompanyId   '<default-company-guid>'
```

If the user did not supply a default company GUID, omit the
`-CompanyId` line entirely — the script leaves the third element out of
the `args` array.

macOS / Linux (`create-connection-string.js`) still uses the legacy
clipboard hand-off because DPAPI is Windows-only; the `-Nickname`
one-shot mode is Windows-only. On Unix, fall back to the two-step flow
described in `/origo-bc-setup`. The JS helper still performs the
`list_companies` validation before emitting the blob to the clipboard,
so a misconfigured tenant/client/secret is surfaced immediately.

**Validation output.** The command prints:

```
[Create-ConnectionString] Validating credentials via list_companies ...
[Create-ConnectionString] Validation OK — credentials work (N companies visible).
```

If it fails, the script throws before the DPAPI wrap and config write —
no broken entry is added. Pass `-SkipValidation` only as a last resort
when the server's `list_companies` is temporarily down. See the setup
skill for the catalog of error messages and their root causes.

### Step 6 — Restart and verify

Tell the user to **restart Cowork / Claude Desktop** so the new
`bc-<nickname>` entry is picked up. Then verify:

```
mcp__bc-<nickname>__list_companies
```

If the entry already existed, the script replaced it wholesale (same
entry name → last call wins). If the user wanted a *second* entry with a
different nickname, re-run Step 5 with that new nickname.