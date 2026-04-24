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
  version: "0.5.0"
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
2. Delivers the three bundled scripts (`dynamics-is.js`,
   `Create-ConnectionString.ps1`, `create-connection-string.js`) to the
   user via `mcp__cowork__present_files`, and asks them to save the
   cards into `%USERPROFILE%\OrigoBC\` (creating that folder with a
   short PowerShell line first).
3. Asks the user (one question at a time via `AskUserQuestion`) for:
   - A short nickname for this tenant (used as MCP key `bc-<nickname>`).
   - Azure AD **tenant ID**.
   - Azure AD **client ID**.
   - **Authentication method**: Client secret or Device code.
   - BC **environment** name (e.g. `Production`, `UAT`).
   - Optional **default company ID** (GUID).
4. Prints a single ready-to-paste PowerShell one-liner the user runs in
   their own terminal. On non-Windows platforms it prints the equivalent
   `node create-connection-string.js` command. For device code flow, the
   `-DeviceCode` / `--device-code` flag is included instead of prompting
   for a secret. These helpers call the server's `encrypt_data` endpoint
   to produce an AES-256-GCM encrypted blob, then DPAPI-wrap it on
   Windows. The final value is copied to the clipboard.
5. Patches `%APPDATA%\Claude\claude_desktop_config.json` directly from
   the user's own PowerShell, reading the blob from `Get-Clipboard` (the
   file tools can't reach that config). The entry has the shape:

   ```json
   "bc-<nickname>": {
     "command": "node",
     "args": [
       "<userprofile>\\OrigoBC\\dynamics-is.js",
       "<pasted-blob>",
       "<default-company-guid>"
     ]
   }
   ```

   If the user did not provide a default company GUID, omit that argument
   — the proxy accepts a missing company and the user can pick one later
   with `/origo-bc-switch-company`. On non-Windows platforms (or if the
   clipboard approach fails), fall back to asking the user to paste the
   blob into chat and write the config entry some other way.

6. Tells the user to restart Cowork, then verify with:
   `mcp__bc-<nickname>__list_companies`.

## Guardrails

- **Never** ask for the client secret or refresh token in chat. If the
  user volunteers either, refuse to store it and instruct them to use
  only the PowerShell / Node helper in their own terminal.
- **Never** attempt to decrypt or inspect the AES blob. It is opaque
  ciphertext that only the server can decrypt.
- If `%USERPROFILE%\OrigoBC\dynamics-is.js` already exists, ask before
  overwriting; otherwise just add the new config entry (use `/origo-bc-add-env`
  for that flow when the install is clearly already present).
- Use `${CLAUDE_PLUGIN_ROOT}/scripts/` to locate the bundled scripts in
  the plugin; never hardcode absolute paths or session-scoped UUIDs.
  When delivering scripts to the user on Windows, do not `cp` from that
  path via the `Bash` tool — it resolves to the Linux sandbox and the
  Windows form is not a real on-disk location. Use
  `mcp__cowork__present_files` instead.

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

### Step 2 — Deliver the three scripts into OrigoBC

The `Bash` tool runs in a Linux sandbox that can't see the user's home
directory, so don't try to `cp` the scripts into `$USERPROFILE` from
there. Instead, hand the files to the user via `mcp__cowork__present_files`
and ask them to drop the cards into `%USERPROFILE%\OrigoBC\`.

1. Call `mcp__cowork__present_files` with the three paths under
   `${CLAUDE_PLUGIN_ROOT}/scripts/`:

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/dynamics-is.js
   ${CLAUDE_PLUGIN_ROOT}/scripts/Create-ConnectionString.ps1
   ${CLAUDE_PLUGIN_ROOT}/scripts/create-connection-string.js
   ```

   If `present_files` rejects the Windows-style form of those paths (it
   can, depending on the host), fall back to the sandbox form visible
   under `/sessions/<session-id>/mnt/.remote-plugins/<plugin-dir>/scripts/`.

2. Print this one-liner for the user to run in their own PowerShell
   window so the destination folder exists before they save the files:

   ```powershell
   New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\OrigoBC" | Out-Null
   ```

   On macOS / Linux use `mkdir -p "$HOME/OrigoBC"` instead.

3. Tell the user to save each of the three presented cards into
   `%USERPROFILE%\OrigoBC\` (or `$HOME/OrigoBC`).

4. If `%USERPROFILE%\OrigoBC\dynamics-is.js` already exists from a prior
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
- Environment (e.g. `Production`, `UAT`). Default: `Production`.
- Default company GUID. Optional — offer a "Skip" option.

### Step 4 — Ask user to generate the connection blob

**If the user chose Client secret:**

Windows PowerShell (preferred):

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId     '<tenant>' `
  -ClientId     '<client>' `
  -Environment  '<env>'
```

macOS / Linux:

```bash
cd ~/OrigoBC
node create-connection-string.js \
  --tenant      '<tenant>' \
  --client      '<client>' \
  --environment '<env>'
```

Tell the user the helper will prompt for the secret with hidden input and
copy the final value to the clipboard.

**If the user chose Device code:**

Windows PowerShell (preferred):

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId     '<tenant>' `
  -ClientId     '<client>' `
  -DeviceCode `
  -Environment  '<env>'
```

macOS / Linux:

```bash
cd ~/OrigoBC
node create-connection-string.js \
  --tenant      '<tenant>' \
  --client      '<client>' \
  --device-code \
  --environment '<env>'
```

Tell the user the helper will open their browser for sign-in and then
copy the final value to the clipboard. No secret is needed.

### Step 5 — Write the MCP config entry (Windows, preferred)

On Windows the `%APPDATA%\Claude\claude_desktop_config.json` file is
outside the session's connected folders and the Read/Write/Edit tools
can't reach it. Rather than routing the encrypted blob through chat,
give the user a second PowerShell block that runs in the **same terminal
window** as Step 4 (so the `dpapi:…` value is still on the clipboard)
and patches the config directly:

```powershell
$blob = Get-Clipboard
if ([string]::IsNullOrWhiteSpace($blob) -or -not $blob.StartsWith('dpapi:')) {
    throw "Clipboard doesn't hold a 'dpapi:' blob. Re-run Step 4 first."
}
$cfgPath = "$env:APPDATA\Claude\claude_desktop_config.json"
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
if (-not $cfg.PSObject.Properties.Match('mcpServers').Count) {
    $cfg | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{})
}
$entry = [pscustomobject]@{
    command = 'node'
    args    = @(
        "$env:USERPROFILE\OrigoBC\dynamics-is.js",
        $blob,
        '<default-company-guid-or-omit-this-line>'
    )
}
if ($cfg.mcpServers.PSObject.Properties.Match('bc-<nickname>').Count) {
    $cfg.mcpServers.'bc-<nickname>' = $entry
} else {
    $cfg.mcpServers | Add-Member -MemberType NoteProperty -Name 'bc-<nickname>' -Value $entry
}
$cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8
Write-Host "bc-<nickname> added. Restart Cowork to activate." -ForegroundColor Green
```

Substitute `<nickname>` and the default company GUID before presenting.
If the user did not provide a default company GUID, drop the third
element of the `args` array entirely — the proxy accepts a missing
company and the user can pick one later with `/origo-bc-switch-company`.

### Step 6 — Fallback: paste the blob back (only if Step 5 is not viable)

If the user is not on Windows, or the clipboard approach fails, fall
back to asking them to paste the value into chat. The blob starts with
`dpapi:` on Windows or is raw base64 on other platforms. Do not print it
back. Do not echo it in tool calls that surface the content to the UI
beyond what is strictly required to write it into the config file.

Then edit the Cowork / Claude Desktop MCP config and add the
`bc-<nickname>` entry as described in "What this command does" step 5
above.

### Step 7 — Restart and verify

Tell the user to **restart Cowork** and verify with:

```
mcp__bc-<nickname>__list_companies
```