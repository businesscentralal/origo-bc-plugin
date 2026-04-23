---
name: origo-bc-setup
description: >
  Guided first-time connection wizard for Origo Business Central. Use this
  skill when the user types `/origo-bc-setup`, says they want to connect
  Cowork to Business Central, set up Origo BC, hook up dynamics.is, wire up
  the BC MCP server, or otherwise establish their first BC tenant inside
  Cowork. Copies the bundled scripts to `%USERPROFILE%\OrigoBC\`, collects
  tenant / client / environment details, asks the user to produce the
  connection blob (AES-256-GCM encrypted via the server's `encrypt_data`
  endpoint) in their own terminal, then writes a new entry into the
  Cowork MCP config.
metadata:
  version: "0.4.0"
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
2. Creates `%USERPROFILE%\OrigoBC\` if missing and copies the three bundled
   scripts from the plugin into that folder (`dynamics-is.js`,
   `Create-ConnectionString.ps1`, `create-connection-string.js`).
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
5. Asks the user to paste back the value from the clipboard (just the
   opaque blob).
6. Edits the Cowork / Claude Desktop MCP config
   (`%APPDATA%\Claude\claude_desktop_config.json` on Windows) and adds a
   new entry:

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
   with `/origo-bc-switch-company`.

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
- Use `C:/Users/ori.gunnarge/AppData/Roaming/Claude/local-agent-mode-sessions/a24064d7-8d67-4839-99b7-e2d8f7e2e343/074adcd2-588a-4bff-bde5-f9cf0161d32a/rpm/plugin_018pLNd4CGF8vEEmyztWR7fi` to locate the bundled scripts in the plugin;
  never hardcode absolute paths.

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

### Step 2 — Ensure OrigoBC folder exists and copy scripts

On Windows (via `Bash` tool):

```bash
mkdir -p "$USERPROFILE/OrigoBC"
cp "${CLAUDE_PLUGIN_ROOT}/scripts/dynamics-is.js" "$USERPROFILE/OrigoBC/"
cp "${CLAUDE_PLUGIN_ROOT}/scripts/Create-ConnectionString.ps1" "$USERPROFILE/OrigoBC/"
cp "${CLAUDE_PLUGIN_ROOT}/scripts/create-connection-string.js" "$USERPROFILE/OrigoBC/"
```

On macOS / Linux use `$HOME/OrigoBC` as the destination.

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

### Step 5 — Receive the blob

Ask the user to paste the value (it starts with `dpapi:` on Windows or is
raw base64 on other platforms). Do not print it back. Do not echo it in
tool calls that surface the content to the UI beyond what is strictly
required to write it into the config file.

### Step 6 — Write the MCP config entry

Edit the Cowork / Claude Desktop MCP config and add the `bc-<nickname>`
entry as described in "What this command does" step 6 above.

Then tell the user to **restart Cowork** and verify with:

```
mcp__bc-<nickname>__list_companies
```
the config fi