---
name: origo-bc-setup
description: >
  Guided first-time connection wizard for Origo Business Central. Use this
  skill when the user types `/origo-bc-setup`, says they want to connect
  Cowork to Business Central, set up Origo BC, hook up dynamics.is, wire up
  the BC MCP server, or otherwise establish their first BC tenant inside
  Cowork. Delivers the bundled scripts into `%USERPROFILE%\OrigoBC\`
  via `mcp__cowork__present_files`, collects tenant / client /
  environment details, asks the user to produce the connection blob
  (AES-256-GCM encrypted via the server's `encrypt_data` endpoint) in
  their own terminal, then writes a new entry into the Cowork MCP config.
metadata:
  version: "0.7.0"
  author: "Origo hf."
---

# `/origo-bc-setup` — First-time BC connection

Walks the user through connecting their first Business Central tenant to
Cowork via the Origo MCP endpoint (`https://dynamics.is/api/mcp`).

Two authentication flows are supported:

- **Client secret** (application permissions) — the user enters a secret
  in the terminal helper; a `clientSecret` blob is produced.
- **Device code** (delegated permissions) — the user authenticates
  interactively in their browser; a `refreshToken` blob is produced.

Credentials **never** pass through Claude chat. They are collected only
by the PowerShell / Node helper running in the user's own terminal.

## What this command does

1. **Verify Node.js is installed and on PATH.** Every `bc-*` MCP entry
   Cowork launches is `node <path>\dynamics-is.js ...`, so without Node
   the connection cannot run.
2. Downloads the three scripts (`dynamics-is.js`,
   `Create-ConnectionString.ps1`, `create-connection-string.js`) from
   the public GitHub repository into `%USERPROFILE%\OrigoBC\`
   (creating that folder first).
3. Asks the user (one question at a time via `AskUserQuestion`) for:
   - A short nickname for this tenant (used as MCP key `bc-<nickname>`).
   - Azure AD **tenant ID**.
   - Azure AD **client ID**.
   - **Authentication method**: Client secret or Device code.
   - If Device code: whether to launch the verification URL in a
     **private / incognito browser window** (useful when the default
     browser is already signed in as a different Entra account).
   - BC **environment** name (e.g. `Production`, `UAT`).
   - Optional **default company ID** (GUID).
4. Presents **one** PowerShell command the user runs in their own
   terminal. `Create-ConnectionString.ps1` with `-Nickname` calls the
   server's `encrypt_data` endpoint to produce an AES-256-GCM blob,
   **round-trips the fresh blob through `list_companies` as an
   end-to-end validation check**, DPAPI-wraps it, auto-detects the
   Claude Desktop config path (MSIX vs classic), and writes the
   `bc-<nickname>` entry in a single invocation. There is **no**
   clipboard hand-off, and the config is **never** written if
   validation fails — so rotated secrets, insufficient device-code
   scopes, and server-side auth routing bugs all surface as a clean
   error in the terminal before they become broken MCP entries. The
   entry has the shape:

   ```json
   "bc-<nickname>": {
     "command": "node",
     "args": [
       "<userprofile>\\OrigoBC\\dynamics-is.js",
       "<dpapi-wrapped-blob>",
       "<default-company-guid>"
     ]
   }
   ```

   If the user did not provide a default company GUID, the script omits
   the third element of `args` — the proxy accepts a missing company
   and the user can pick one later with `/origo-bc-switch-company`. On
   non-Windows platforms the `-Nickname` one-shot mode is unavailable
   (DPAPI is Windows-only); fall back to the clipboard-based two-step
   flow described at the bottom of this skill.

5. Tells the user to restart Cowork, then verify with:
   `mcp__bc-<nickname>__list_companies`.

## Why one command

Earlier versions of this skill used a clipboard hand-off: the first
PowerShell block generated the blob and ran `Set-Clipboard`, then a
second block read `Get-Clipboard` and patched the config. That is
fragile — anything copied between the two blocks (for example, the
second block itself!) clobbers the clipboard, and the config gets
written with whatever text happened to be in the buffer. Running both
halves inside one script call eliminates the IPC problem entirely.

## Guardrails

- **Never** ask for the client secret or refresh token in chat. If the
  user volunteers either, refuse to store it and instruct them to use
  only the PowerShell / Node helper in their own terminal.
- **Never** attempt to decrypt or inspect the AES blob. It is opaque
  ciphertext that only the server can decrypt.
- If `%USERPROFILE%\OrigoBC\dynamics-is.js` already exists, ask before
  overwriting; otherwise just add the new config entry (use `/origo-bc-add-env`
  for that flow when the install is clearly already present).
- Scripts are downloaded from the public GitHub mirror at
  `https://raw.githubusercontent.com/businesscentralal/origo-bc-plugin/main/plugins/origo-bc/scripts/`.
  Never reference `${CLAUDE_PLUGIN_ROOT}` or sandbox paths — they are
  not accessible from the user's real filesystem.

## Windows PowerShell pitfalls — READ BEFORE WRITING COMMANDS

Three encoding/path gotchas have each broken this skill in production.
Every PowerShell block you emit must honour them:

**1. Never use `Set-Content -Encoding UTF8` to write `claude_desktop_config.json`.**
In Windows PowerShell 5.1 that encoding name means *UTF-8 with BOM*, and
Claude's JSON parser rejects the BOM at file start with
`Unexpected token '﻿', "﻿{..." is not valid JSON`. The entire app
fails to load until the BOM is stripped. Always write the config via:

```powershell
[System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
```

The `$false` is required and means "no BOM". PowerShell 7's
`Set-Content -Encoding UTF8` is BOM-free, but you can't assume the user
is on 7 — default Windows still ships 5.1.

**2. Always re-save downloaded OR locally-copied `.ps1` files as
UTF-8 *with* BOM.** PS 5.1 parses `.ps1` source as ANSI/CP1252 by
default. Any non-ASCII character in the script (em-dashes, Icelandic
letters, box-drawing characters `── →`, smart quotes) gets misread
byte-by-byte; specifically an em-dash inside a double-quoted string
leaks a `0x94` (CP1252 curly quote) that silently terminates the string
and breaks parsing tens of lines later with a misleading
`Missing closing '}' in statement block` error. The download block in
Step 2 handles this correctly. **Do not use `Copy-Item` to refresh the
local script from a working tree — it preserves the source's BOM-less
encoding and re-triggers the trap.** Use this pattern instead:

```powershell
$src     = '<path-to-working-tree>\Create-ConnectionString.ps1'
$dst     = "$env:USERPROFILE\OrigoBC\Create-ConnectionString.ps1"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$text    = [System.IO.File]::ReadAllText($src)
[System.IO.File]::WriteAllText($dst, $text, $utf8Bom)
```

Config JSON: BOM **off**. Script `.ps1`: BOM **on**. Don't swap these.

**3. The Claude config path differs between MSIX and classic installs.**
Store/MSIX-packaged Claude redirects writes to
`%APPDATA%\Claude\` into a sandbox at
`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\`.
The skill auto-detects this in Step 5 — do not revert to a hard-coded
`%APPDATA%\Claude\claude_desktop_config.json`. If both paths exist,
the MSIX path wins. When unsure, ask the user what path opens via
Claude's **Settings → Edit Config**; the file the UI opens is always
the file the app actually reads.

## Step-by-step script

### Step 1 — Verify Node.js 18+ is installed

Run `node --version` via the `Bash` tool. The command must:

- **Exit 0** (exit code != 0 means Node is not on PATH).
- **Report major version ≥ 18** (e.g. `v18.17.0`, `v20.11.1`, `v22.x`).

Parse the output with a regex such as `^v(\d+)\.`. If either check fails,
**abort immediately** before touching the filesystem or the MCP config, and
reply to the user with something like:

> I need Node.js 18 or newer to set up Origo BC, because Cowork launches
> the BC connection through `node dynamics-is.js ...`. I couldn't find a
> working Node on PATH (got: `<version or error>`).
>
> Install Node (LTS is fine) from <https://nodejs.org/>, open a **new**
> Cowork session so the PATH refresh is picked up, and re-run
> `/origo-bc-setup`.
>
> Quick check in a new terminal window: `node --version`

Do not proceed with any other step until Node is confirmed on this run.

Note that `Bash` in Cowork runs in a Linux sandbox, so this check
verifies *sandbox* Node rather than the Node that Windows will invoke
when launching `node dynamics-is.js`. In practice the two are usually
both present, but if Step 7 ultimately fails with `'node' is not
recognized` on restart, ask the user to run `node --version` in their
own PowerShell window and install the Windows LTS build from
<https://nodejs.org/> if missing.

### Step 2 — Download the three scripts into OrigoBC

The scripts are hosted on the public GitHub mirror. Give the user a
ready-to-paste block that creates the target folder and downloads all
three files in one go.

**GitHub raw base URL:**
```
https://raw.githubusercontent.com/businesscentralal/origo-bc-plugin/main/plugins/origo-bc/scripts
```

**Windows PowerShell:**

```powershell
$dir = "$env:USERPROFILE\OrigoBC"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$base  = 'https://raw.githubusercontent.com/businesscentralal/origo-bc-plugin/main/plugins/origo-bc/scripts'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
@('dynamics-is.js', 'Create-ConnectionString.ps1', 'create-connection-string.js') | ForEach-Object {
    $dst = Join-Path $dir $_
    # Invoke-WebRequest.Content is already a decoded .NET string (UTF-8 from
    # GitHub raw). We re-save it with a UTF-8 BOM so Windows PowerShell 5.1,
    # which defaults to ANSI/CP1252 for .ps1 source, sees the Unicode signal
    # and parses multi-byte characters (em-dashes, Icelandic letters, etc.)
    # correctly. Without the BOM, a character like '—' inside a double-quoted
    # string decodes to bytes that include 0x94 (a curly closing quote in
    # CP1252), which silently terminates the string and breaks parsing tens
    # of lines later.
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

If `%USERPROFILE%\OrigoBC\dynamics-is.js` already exists from a prior
setup, ask before overwriting; otherwise redirect the user to
`/origo-bc-add-env`.

### Step 3 — Collect BC coordinates

Use `AskUserQuestion` for each of these (one at a time):

- Nickname (free text, lower-case, no spaces). Default: ask again if blank.
- Tenant ID (either a GUID or a domain like `origo.is`). Required.
- Client ID (GUID). Required.
- **Authentication method**: "Client secret" or "Device code (browser login)".
  Default: Client secret. Explain the difference briefly:
  - *Client secret*: app-to-app auth, no user interaction after entering
    the secret. Requires a client secret from the app registration.
  - *Device code*: interactive browser login, uses delegated permissions.
    Good when the user doesn't have a client secret or prefers user-level
    access. Produces a refresh token.
- **(Device code only)** Private / incognito browser window? Yes / No.
  Default: No. Recommend Yes if the user's default browser is already
  signed in as the wrong Entra account.
- Environment (e.g. `Production`, `UAT`). Default: `Production`.
- Default company GUID. Optional — offer a "Skip" option.

### Step 4 — One-shot: generate the blob AND write the config (Windows)

Present a **single** PowerShell command that:

1. Calls `encrypt_data` on the MCP server to AES-256-GCM-encrypt the
   credentials.
2. Wraps the ciphertext with Windows DPAPI (CurrentUser).
3. Auto-detects MSIX vs classic Claude config path.
4. Writes the `bc-<nickname>` entry, BOM-free.

No clipboard, no second block to paste.

**Client secret flow** (the script prompts for the secret with hidden
input):

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

If the user chose a **private / incognito** browser window, add
`-InPrivate`. The script tries Edge (`--inprivate`), then Chrome
(`--incognito`), then Brave, then Firefox (`-private-window`), falling
back to the default browser if none of them is on PATH:

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

If the user did **not** supply a default company GUID, omit the
`-CompanyId` line — the script will leave the third element out of the
entry's `args` array. The user can pick a company later with
`/origo-bc-switch-company`.

If `bc-<nickname>` already exists in the config, the script **replaces
it wholesale** (last call wins). That is intentional: re-running this
step is the canonical way to rotate credentials.

Claude on Windows ships in two flavors with different config paths —
the script auto-detects them:

- **MSIX / Microsoft Store install**:
  `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json`
  (The user can verify by clicking **Settings → Edit Config** inside
  Claude; the file that opens is the one the app actually reads.)
- **Classic installer**:
  `%APPDATA%\Claude\claude_desktop_config.json`

If both exist (rare), MSIX wins. If neither is where the script looks,
pass `-ConfigPath '<full-path-to-claude_desktop_config.json>'`.

**What validation looks like in the output.** Between
`Credentials encrypted successfully (AES-256-GCM).` and
`Added new bc-<nickname> entry.`, the script prints:

```
[Create-ConnectionString] Validating credentials via list_companies ...
[Create-ConnectionString] Validation OK — credentials work (N companies visible).
```

If validation fails, the script throws and **the config is not written**.
Expect messages like:

- `Validation failed: Token error (invalid_client): AADSTS7000215...`
  → The client secret is wrong, rotated, or the app has no secret and
  the server is using client-credentials flow. Verify the secret or
  switch to `-DeviceCode`.
- `Validation failed: AADSTS7000218...`
  → The app registration's Authentication → "Allow public client
  flows" is set to No. Enable it in Azure portal, then retry.
- `Validation failed: Unauthorized` / `Forbidden`
  → The authenticated principal has no permissions in the tenant.
- `Validation request to https://dynamics.is/... failed: ...`
  → Network / TLS / server down. Retry later, or pass
  `-SkipValidation` to write the config anyway (strongly
  discouraged — only use when you know the server is temporarily
  unavailable and you have reason to believe the credentials are
  correct).

### Step 5 — macOS / Linux (one-shot via JS helper)

The cross-platform Node helper supports `--nickname` one-shot mode
just like the PowerShell script. On macOS the blob is Keychain-bound
(`keychain:`); on Linux it falls back to `plain:`. The config path
is auto-detected per platform.

```bash
cd ~/OrigoBC
node create-connection-string.js \
  --tenant      '<tenant>' \
  --client      '<client>' \
  --environment '<env>' \
  --nickname    '<nickname>' \
  --company-id  '<default-company-guid>'   # optional
  # add --device-code for device flow
```

The script auto-detects the Claude Desktop config path
(`~/Library/Application Support/Claude/` on macOS,
`~/.config/Claude/` on Linux). Override with `--config-path`.
Validation and config write happen in one invocation — no clipboard
round-trip. Do not print the blob back in chat.

### Step 6 — Restart and verify

Tell the user to **restart Cowork / Claude Desktop** and verify with:

```
mcp__bc-<nickname>__list_companies
```