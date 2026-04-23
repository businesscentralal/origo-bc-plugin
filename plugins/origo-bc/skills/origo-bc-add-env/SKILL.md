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
  version: "0.4.0"
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

2. `%USERPROFILE%\OrigoBC\dynamics-is.js` exists. If it doesn't, stop and
   tell the user:

   > It looks like Origo BC has not been set up on this machine yet. Run
   > `/origo-bc-setup` first.

## What this command does

1. Confirm `%USERPROFILE%\OrigoBC\` is already populated.
2. Ask (via `AskUserQuestion`, one at a time):
   - Short nickname (must be unique vs. existing `bc-*` entries).
   - Tenant ID, client ID, environment.
   - Optional default company GUID.
3. Print the helper command for the user to run in their own terminal
   (`Create-ConnectionString.ps1` on Windows, `create-connection-string.js`
   elsewhere) with the tenant / client / environment pre-filled.
4. Receive the pasted blob (AES-256-GCM ciphertext, DPAPI-wrapped on
   Windows).
5. Append a new `bc-<nickname>` entry to the Cowork MCP config.
6. Prompt the user to restart Cowork and verify with
   `mcp__bc-<nickname>__list_companies`.

## Uniqueness check

Before asking for the nickname, read the current MCP config and list the
existing `bc-*` keys back to the user as forbidden values. If the user's
chosen nickname collides, ask again.

## Guardrails

Same as `/origo-bc-setup`:

- Never prompt for the client secret or refresh token in chat.
- Never attempt to decrypt or inspect the AES blob.
- Atomic write of the config (temp file + rename).

## Step-by-step

### Step 1 — Verify Node.js and the existing install

```bash
node --version   # must exit 0 and report v18+ (v18/v20/v22 LTS all fine)
test -f "$USERPROFILE/OrigoBC/dynamics-is.js" && echo OK
```

If either check fails, stop and redirect the user (Node → <https://nodejs.org/>;
missing install → `/origo-bc-setup`).

### Step 2 — List existing entries

Read `%APPDATA%\Claude\claude_desktop_config.json`, enumerate keys under
`mcpServers` that start with `bc-`, and show them to the user so they can
pick a non-colliding nickname.

### Step 3 — Collect coordinates

Use `AskUserQuestion` for: nickname, tenant, client, **authentication
method** (Client secret or Device code), environment, optional default
company GUID.

See `/origo-bc-setup` Step 3 for the explanation of each auth method.

### Step 4 — Generate the blob

**If the user chose Client secret:**

Windows PowerShell:

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId    '<tenant>' `
  -ClientId    '<client>' `
  -Environment '<env>'
```

macOS / Linux:

```bash
cd ~/OrigoBC
node create-connection-string.js \
  --tenant      '<tenant>' \
  --client      '<client>' \
  --environment '<env>'
```

Tell the user the helper will prompt for the client secret with hidden
input and copy the final AES-encrypted blob to the clipboard.

**If the user chose Device code:**

Windows PowerShell:

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId    '<tenant>' `
  -ClientId    '<client>' `
  -DeviceCode `
  -Environment '<env>'
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
copy the final AES-encrypted blob to the clipboard. No secret is needed.

### Step 5 — Receive the blob

Ask the user to paste the value (`dpapi:` on Windows, raw base64
elsewhere). Do not print it back. Do not echo it in tool calls that
surface the content to the UI.

### Step 6 — Write the MCP config entry

Add a new entry to the Cowork MCP config:

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

If the user did not provide a default company GUID, omit that argument.

Tell the user to **restart Cowork** and verify with:

```
mcp__bc-<nickname>__list_companies
```
  -ClientId    '<client>'