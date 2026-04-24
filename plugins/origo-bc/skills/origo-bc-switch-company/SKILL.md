---
name: origo-bc-switch-company
description: >
  Change the default company GUID on an existing Business Central entry
  in the Cowork MCP config. Use this skill when the user types
  `/origo-bc-switch-company`, says they want to switch BC companies, set a
  different default company, change which company a `bc-<nickname>` entry
  points at, or re-target an Origo BC MCP connection. Lists the existing
  `bc-*` entries, asks which to modify, queries BC for the available
  companies, and rewrites just the company argument.
metadata:
  version: "0.1.0"
  author: "Origo hf."
---

# `/origo-bc-switch-company` — Change the default company on a BC entry

Lets the user point an existing `bc-<nickname>` MCP entry at a different
company without touching the connection blob.

## What this command does

1. Read the Cowork MCP config and list every `bc-*` entry.
2. Ask the user (via `AskUserQuestion`) which entry to modify.
3. Call `mcp__bc-<nickname>__list_companies` on that entry to fetch the
   available companies for the tenant.
4. Ask the user to pick one (show the company name, ID, and display name).
5. Rewrite the `args` array for that entry:
   - If `args` currently has 2 elements (`[scriptPath, blob]`), append the
     new company GUID.
   - If `args` currently has 3 elements (`[scriptPath, blob, companyGuid]`),
     replace the third element.
6. Write the config atomically (temp file + rename).
7. Tell the user to restart Cowork for the change to take effect.

## Preconditions

- `%USERPROFILE%\OrigoBC\dynamics-is.js` (or its mac / linux equivalent)
  must exist — if not, redirect to `/origo-bc-setup`.
- The chosen `bc-<nickname>` entry must be reachable (i.e. its MCP tools
  are loaded). If `list_companies` fails, surface the error and stop
  before writing anything.

## Guardrails

- **Never** ask for the client secret or refresh token in chat. If the
  user volunteers either, refuse to store it and instruct them to use
  only the PowerShell / Node helper in their own terminal.
- **Never** attempt to decrypt or inspect the AES blob. It is opaque
  ciphertext that only the server can decrypt.
- **Don't** touch the connection blob. The only change is the third
  element of `args`.
- **Don't** create new entries — this command only edits existing ones.
  For new tenants use `/origo-bc-add-env`; for the very first tenant use
  `/origo-bc-setup`.
- Validate the chosen company GUID matches one of the companies returned
  by `list_companies` before writing.

## Windows PowerShell pitfalls — READ BEFORE WRITING COMMANDS

This command writes the MCP config, so the same encoding / path traps
from `/origo-bc-setup` apply:

1. **`Set-Content -Encoding UTF8` adds a BOM in PS 5.1** — Claude's JSON
   parser rejects the config with `Unexpected token '\uFEFF'`. Always write
   the config via
   `[System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))`.

2. **The Claude config path differs between MSIX and classic installs.**
   Store/MSIX-packaged Claude redirects `%APPDATA%\Claude\` writes into
   `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\`.
   Auto-detect both paths; if both exist, the MSIX path wins.

Rule of thumb: **config JSON — BOM off.**

## Step-by-step

### Step 1 — Enumerate entries

```python
with open(config_path) as f:
    cfg = json.load(f)
bc_keys = [k for k in cfg.get("mcpServers", {}) if k.startswith("bc-")]
```

If empty, stop and suggest `/origo-bc-setup`.

### Step 2 — Ask which entry to modify

Use `AskUserQuestion` with a multi-choice list built from `bc_keys`.

### Step 3 — Fetch companies

Call `mcp__bc-<chosen-nickname>__list_companies`. If this fails, stop and
show the error.

### Step 4 — Ask which company

Use `AskUserQuestion` with one option per company (label = company name,
value = company GUID).

### Step 5 — Rewrite `args`

```python
entry = cfg["mcpServers"][chosen_key]
args  = list(entry.get("args", []))
if len(args) < 2:
    raise RuntimeError("Malformed BC entry: args too short")
if len(args) == 2:
    args.append(new_company_guid)
else:
    args[2] = new_company_guid
entry["args"] = args
```

### Step 6 — Atomic write

Write the updated config to `<config>.tmp` in the same directory, then
rename over the original. Never truncate the original file first.

### Step 7 — Wrap up

Tell the user:

> Updated `bc-<nickname>` to default company `<GUID>`. Quit Cowork fully
> and reopen it for the change to take effect.
