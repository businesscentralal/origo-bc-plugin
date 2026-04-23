---
name: origo-bc-update-env
description: >
  Re-generate the connection blob for an existing `bc-*` entry in the
  Cowork MCP config. Use this skill when the user types
  `/origo-bc-update-env`, says their BC connection stopped working, needs
  to re-authenticate, wants to rotate credentials, or sees the error
  "plain: connection strings are no longer supported". Walks through
  identifying the affected entry, optionally updating the local scripts,
  running the connection helper, and replacing the blob in the config.
metadata:
  version: "0.3.0"
  author: "Origo hf."
---

# `/origo-bc-update-env` — Update an existing BC connection

Re-generates the AES-256-GCM connection blob for an existing `bc-<name>`
entry in the Cowork MCP config. Common triggers:

- **v0.3 migration**: user sees the error _"plain: connection strings are
  no longer supported"_ after the server-side update.
- **Credential rotation**: client secret was renewed in Azure AD.
- **Environment change**: same tenant/client but different BC environment.

The client secret **never** passes through Claude chat.

## Preconditions

1. **Node.js 18+ on PATH** — abort otherwise (same as `/origo-bc-setup`).
2. `%USERPROFILE%\OrigoBC\dynamics-is.js` exists — if not, redirect to
   `/origo-bc-setup`.
3. At least one `bc-*` entry exists in the MCP config — if not, redirect
   to `/origo-bc-add-env`.

## What this command does

1. Read the MCP config and list all `bc-*` entries.
2. Ask the user which entry to update (or auto-detect if only one exists).
3. Extract the existing entry's args to pre-fill tenant / client /
   environment where possible. (The blob itself is opaque — we cannot
   read tenant/client from it. But some configs store them as separate
   args or comments.)
4. Optionally update the local scripts in `%USERPROFILE%\OrigoBC\` if the
   plugin ships newer versions.
5. Print the connection helper command pre-filled with the known
   coordinates. The user runs it in their own terminal.
6. Receive the new blob (pasted from clipboard).
7. Replace the old blob in the MCP config entry's args.
8. Prompt the user to restart Cowork and verify.

## Guardrails

- Never prompt for the client secret in chat.
- Never attempt to decrypt or inspect the old or new blob.
- When replacing the blob, use atomic write (temp file + rename).
- If the user has multiple `bc-*` entries, only modify the one they
  selected — never bulk-replace.

## Step-by-step

### Step 1 — Verify Node.js and the existing install

```bash
node --version   # must exit 0 and report v18+
test -f "$USERPROFILE/OrigoBC/dynamics-is.js" && echo OK
```

### Step 2 — List existing entries and select target

Read `%APPDATA%\Claude\claude_desktop_config.json`, enumerate keys under
`mcpServers` that start with `bc-`, and present them:

| # | Entry | Args (redacted) |
|---|-------|-----------------|
| 1 | `bc-origo` | `dynamics-is.js`, `dpapi:...` (redacted), `<company>` |
| 2 | `bc-contoso` | `dynamics-is.js`, `dpapi:...` (redacted) |

If only one entry exists, auto-select it and confirm. Otherwise ask.

### Step 3 — Detect migration scenario

Check the selected entry's args array. If the blob (second element after
the `dynamics-is.js` path) starts with `plain:`, tell the user:

> This entry uses the old `plain:` format which is no longer accepted by
> the server. I'll help you generate a new AES-256-GCM encrypted blob to
> replace it.

### Step 4 — Optionally update local scripts

Compare the bundled plugin scripts against `%USERPROFILE%\OrigoBC\`. If
the plugin ships newer versions (check file size or a version comment in
the script header), offer to update:

> Your local scripts in `%USERPROFILE%\OrigoBC\` may be outdated. Update
> them? (Yes / Skip)

If yes, copy from the plugin's `scripts/` folder (same as `/origo-bc-setup`
Step 2).

### Step 5 — Collect coordinates

Use `AskUserQuestion` for tenant ID, client ID, and environment. Pre-fill
defaults from any known context (e.g., if the entry name hints at the
environment). Ask the user to confirm or correct each value.

### Step 6 — Generate the new blob

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
input and copy the new AES-encrypted blob to the clipboard.

### Step 7 — Receive the new blob

Ask the user to paste the value. Do not print it back.

### Step 8 — Replace the blob in the MCP config

Read the config, find the selected `bc-<name>` entry, replace the blob
argument (second element in the `args` array) with the new value. Write
the updated config atomically.

Tell the user to **restart Cowork** and verify with:

```
mcp__bc-<name>__list_companies
```

If the old entry had a company GUID as the third arg, preserve it. If the
user wants to change the company, suggest `/origo-bc-switch-company`.
