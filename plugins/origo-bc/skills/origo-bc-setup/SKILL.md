---
name: origo-bc-setup
description: >
  Guided first-time connection wizard for Origo Business Central. Use this
  skill when the user types `/origo-bc-setup`, says they want to connect
  Cowork to Business Central, set up Origo BC, hook up dynamics.is, wire up
  the BC MCP server, or otherwise establish their first BC tenant inside
  Cowork. Copies the bundled scripts to `%USERPROFILE%\OrigoBC\`, collects
  tenant / client / environment details, asks the user to produce the
  connection blob in their own terminal, then writes a new entry into the
  Cowork MCP config.
metadata:
  version: "0.1.0"
  author: "Origo hf."
---

# `/origo-bc-setup` — First-time BC connection

Walks the user through connecting their first Business Central tenant to
Cowork via the Origo MCP endpoint (`https://dynamics.is/api/mcp`).

The client secret **never** passes through Claude chat. It is collected
only by the PowerShell / Node helper running in the user's own terminal.

## What this command does

1. **Verify Node.js is installed and on PATH.** Every `bc-*` MCP entry
   Cowork launches is `node <path>\dynamics-is.js ...`, so without Node
   the connection cannot run.
2. Creates `%USERPROFILE%\OrigoBC\` if missing and copies the three bundled
   scripts from the plugin into that folder (`dynamics-is.js`,
   `Create-PlainConnectionString.ps1`, `create-connection-string.js`).
3. Asks the user (one question at a time via `AskUserQuestion`) for:
   - A short nickname for this tenant (used as MCP key `bc-<nickname>`).
   - Azure AD **tenant ID**.
   - Azure AD **client ID**.
   - BC **environment** name (e.g. `Production`, `UAT`).
   - Optional **default company ID** (GUID).
4. Prints a single ready-to-paste PowerShell one-liner the user runs in
   their own terminal. On non-Windows platforms it prints the equivalent
   `node create-connection-string.js` command. These helpers prompt for the
   secret with a hidden SecureString / readline prompt and copy the final
   `dpapi:<...>` or `plain:<...>` value to the clipboard.
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

- **Never** ask for the client secret in chat. If the user volunteers it,
  refuse to store it and instruct them to paste it only into the
  PowerShell / Node prompt.
- **Never** transmit the `plain:<base64>` payload to any service. It
  contains the secret in recoverable form.
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
cp "${CLAUDE_PLUGIN_ROOT}/scripts/Create-PlainConnectionString.ps1" "$USERPROFILE/OrigoBC/"
cp "${CLAUDE_PLUGIN_ROOT}/scripts/create-connection-string.js" "$USERPROFILE/OrigoBC/"
```

On macOS / Linux use `$HOME/OrigoBC` as the destination.

### Step 3 — Collect BC coordinates

Use `AskUserQuestion` for each of these (one at a time):

- Nickname (free text, lower-case, no spaces). Default: ask again if blank.
- Tenant ID (either a GUID or a domain like `origo.is`). Required.
- Client ID (GUID). Required.
- Environment (e.g. `Production`, `UAT`). Default: `Production`.
- Default company GUID. Optional — offer a "Skip" option.

### Step 4 — Ask user to generate the connection blob

Windows PowerShell (preferred):

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-PlainConnectionString.ps1 `
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

### Step 5 — Receive the blob

Ask the user to paste the value (it starts with either `dpapi:` or
`plain:`). Do not print it back. Do not echo it in tool calls that surface
the content to the UI beyond what is strictly required to write it into
the config fi