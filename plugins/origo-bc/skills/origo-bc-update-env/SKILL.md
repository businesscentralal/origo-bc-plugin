---
name: origo-bc-update-env
description: >
  Re-generate the connection blob for an existing `bc-*` entry in the
  Cowork MCP config. Use this skill when the user types
  `/origo-bc-update-env`, says their BC connection stopped working, needs
  to re-authenticate, wants to rotate credentials, or sees the error
  "plain: connection strings are no longer supported". Walks through
  identifying the affected entry, optionally updating the local scripts,
  and running the PowerShell helper in one-shot mode so the new
  AES-256-GCM blob is validated end-to-end and patched into the config
  without a clipboard hand-off.
metadata:
  version: "0.5.0"
  author: "Origo hf."
---

# `/origo-bc-update-env` — Update an existing BC connection

Re-generates the AES-256-GCM connection blob for an existing `bc-<name>`
entry in the Cowork MCP config. Common triggers:

- **v0.3 migration**: user sees the error _"plain: connection strings are
  no longer supported"_ after the server-side update.
- **Credential rotation**: client secret was renewed in Azure AD.
- **Refresh token expired**: device-code connection needs re-authentication.
- **Environment change**: same tenant/client but different BC environment.
- **Auth method switch**: migrating from client secret to device code or
  vice versa.
- **AADSTS7000215 from a device-code blob**: server was running a build
  that blended `BC_CLIENT_SECRET` from its own env vars into device-code
  blobs. Fixed in server ≥ April 2026; a re-run with this skill against
  the fixed server produces a working entry.

Credentials (client secret or refresh token) **never** pass through
Claude chat.

## Preconditions

1. **Node.js 18+ on PATH** — abort otherwise (same as `/origo-bc-setup`).
2. `%USERPROFILE%\OrigoBC\dynamics-is.js` exists — if not, redirect to
   `/origo-bc-setup`.
3. At least one `bc-*` entry exists in the MCP config — if not, redirect
   to `/origo-bc-add-env`.

## What this command does

1. Read the MCP config and list all `bc-*` entries.
2. Ask the user which entry to update (or auto-detect if only one exists).
3. Optionally refresh the local scripts in `%USERPROFILE%\OrigoBC\` if
   the plugin ships newer versions.
4. Collect tenant / client / environment / auth method via
   `AskUserQuestion`. The blob is opaque so we cannot read these from
   the existing entry — the user must confirm or supply them.
5. Emit **one** PowerShell command using `-Nickname <existing-name>`.
   `Create-ConnectionString.ps1` encrypts the credentials,
   **round-trips the fresh blob through `list_companies` as an
   end-to-end validation check**, DPAPI-wraps it, and replaces the
   `bc-<nickname>` entry in the config. The company GUID on the
   existing entry is preserved by passing `-CompanyId` with the
   existing third-element value (if present). The config is **never**
   written if validation fails.
6. Prompt the user to restart Cowork and verify.

## Why one command

Earlier versions of this skill used a clipboard hand-off: the helper
printed a new blob to `Set-Clipboard`, then a second PowerShell block
read `Get-Clipboard` and patched the config. That is fragile — anything
copied between the two blocks (for example, the second block itself!)
clobbers the clipboard, and the config gets patched with whatever text
happened to be in the buffer. Running both halves inside one script call
eliminates the IPC problem entirely and — since validation is baked in
— guarantees the replacement blob actually works before it overwrites
the last one.

## Guardrails

- Never prompt for the client secret or refresh token in chat.
- Never attempt to decrypt or inspect the old or new blob.
- `Create-ConnectionString.ps1 -Nickname` writes the config atomically
  (temp file + rename), BOM-free.
- If the user has multiple `bc-*` entries, only modify the one they
  selected — never bulk-replace.
- Preserve the existing `args[2]` (default company GUID) unless the user
  explicitly wants to change it. Changing the default company is the job
  of `/origo-bc-switch-company`.

## Windows PowerShell pitfalls — READ BEFORE WRITING COMMANDS

Same three pitfalls as `/origo-bc-setup`. Summary:

1. **JSON config**: BOM **off** (`UTF8Encoding($false)`). The script
   handles this; don't write the config yourself.
2. **`.ps1` source refresh**: BOM **on** (`UTF8Encoding($true)`).
   **Never use `Copy-Item` to refresh from a working tree** — use the
   `ReadAllText` + `WriteAllText` block below. PS 5.1 reads BOM-less
   `.ps1` as CP1252 and mis-decodes em-dashes / Icelandic letters /
   box-drawing characters, which breaks parsing tens of lines later
   with a misleading `Missing closing '}' in statement block` error.
3. **Claude config path**: MSIX-packaged Claude redirects
   `%APPDATA%\Claude\` writes into
   `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\`.
   The script auto-detects this; do not hard-code `%APPDATA%\Claude\`.

## Step-by-step

### Step 1 — Verify Node.js and the existing install

Run `node --version` via `Bash`; abort with an install hint if exit ≠ 0
or major version < 18. Confirm
`$env:USERPROFILE\OrigoBC\dynamics-is.js` exists; if not, redirect to
`/origo-bc-setup`.

### Step 2 — List existing entries and select target

Read the Claude Desktop config. Prefer the MSIX path
`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json`;
fall back to `%APPDATA%\Claude\claude_desktop_config.json`. Enumerate
keys under `mcpServers` that start with `bc-`, and present them:

| # | Entry | Args (redacted) |
|---|-------|-----------------|
| 1 | `bc-origo` | `dynamics-is.js`, `dpapi:…` (redacted), `<company>` |
| 2 | `bc-contoso` | `dynamics-is.js`, `dpapi:…` (redacted) |

If only one entry exists, auto-select it and confirm. Otherwise ask.

### Step 3 — Detect migration scenario

Check the selected entry's `args` array:

- If `args[1]` starts with `plain:` → tell the user this entry uses the
  legacy format no longer accepted by the server, and that this
  command will replace it with a proper AES-256-GCM blob.
- If `args[1]` starts with `dpapi:` or looks like AES ciphertext →
  this is a rotation / re-auth / broken-credential case; proceed.
- Capture `args[2]` if present — that is the existing default company
  GUID that must be preserved.

### Step 4 — Optionally refresh the local scripts

Offer to re-download the latest scripts:

> Your local scripts in `%USERPROFILE%\OrigoBC\` may be outdated. Update
> them? (Yes / Skip)

If yes, use the BOM-aware download block from `/origo-bc-setup` Step 2:

```powershell
$dir = "$env:USERPROFILE\OrigoBC"
$base = 'https://raw.githubusercontent.com/businesscentralal/origo-bc-plugin/main/plugins/origo-bc/scripts'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
@('dynamics-is.js', 'Create-ConnectionString.ps1', 'create-connection-string.js') | ForEach-Object {
    $dst  = Join-Path $dir $_
    $text = (Invoke-WebRequest -Uri "$base/$_" -UseBasicParsing).Content
    [System.IO.File]::WriteAllText($dst, $text, $utf8Bom)
    Write-Host "Updated $_" -ForegroundColor Green
}
```

If the user is refreshing from a local working tree instead:

```powershell
$src = '<path-to-working-tree>\Create-ConnectionString.ps1'
$dst = "$env:USERPROFILE\OrigoBC\Create-ConnectionString.ps1"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$text = [System.IO.File]::ReadAllText($src)
[System.IO.File]::WriteAllText($dst, $text, $utf8Bom)
```

`Copy-Item` is **not** a safe substitute — it preserves the working
tree's encoding and retriggers the CP1252 parsing trap.

### Step 5 — Collect coordinates

Use `AskUserQuestion` for tenant ID, client ID, **authentication method**
(Client secret or Device code), environment, and — for device code —
whether to launch the verification URL in a private / incognito browser
window. Pre-fill defaults where any are hintable from the entry name
(e.g. `bc-origo-uat` hints environment `UAT`). Ask the user to confirm
or correct each value.

See `/origo-bc-setup` Step 3 for the explanation of each auth method.
If the user originally used one method and wants to switch, that's fine
— the new blob simply replaces the old one regardless of auth type.

### Step 6 — One-shot: generate the blob AND replace the entry (Windows)

Present **one** PowerShell command using `-Nickname <existing-name>`.
`Create-ConnectionString.ps1` will:

1. Encrypt the credentials via `encrypt_data` on the MCP server
   (AES-256-GCM).
2. Validate them by calling `list_companies` round-trip with the fresh
   blob.
3. DPAPI-wrap the ciphertext (CurrentUser scope).
4. Auto-detect the MSIX vs classic Claude config path.
5. Replace the `bc-<nickname>` entry wholesale (BOM-free).

Always pass `-CompanyId <existing-guid>` when the existing entry had an
`args[2]`, so the replacement preserves the default company. Omit it
otherwise.

**Client secret flow** (the script prompts for the secret with hidden
input):

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId    '<tenant>' `
  -ClientId    '<client>' `
  -Environment '<env>' `
  -Nickname    '<existing-nickname>' `
  -CompanyId   '<existing-company-guid-if-any>'
```

**Device-code flow** (opens a browser for interactive sign-in):

```powershell
cd $env:USERPROFILE\OrigoBC
.\Create-ConnectionString.ps1 `
  -TenantId    '<tenant>' `
  -ClientId    '<client>' `
  -DeviceCode `
  -Environment '<env>' `
  -Nickname    '<existing-nickname>' `
  -CompanyId   '<existing-company-guid-if-any>'
```

Add `-InPrivate` for an incognito browser window on device-code flow if
the user's default browser is signed in to the wrong Entra account. The
script tries Edge (`--inprivate`), Chrome (`--incognito`), Brave, then
Firefox (`-private-window`), falling back to the default browser.

`-Nickname` on an existing entry is a **replace**, not an append — this
skill's entire purpose. The script preserves neighboring `bc-*` entries
untouched.

### Step 7 — What validation looks like in the output

Between `Credentials encrypted successfully (AES-256-GCM).` and
`Replaced existing bc-<nickname> entry.`, the script prints:

```
[Create-ConnectionString] Validating credentials via list_companies ...
[Create-ConnectionString] Validation OK — credentials work (N companies visible).
```

If validation fails, the script throws and **the config is not written**
— the old (broken) entry stays put so the user doesn't end up with two
broken configs in a row. Expect messages like:

- `Validation failed: Token error (invalid_client): AADSTS7000215…`
  → Wrong or rotated client secret. Verify in Azure AD → App
  registrations → your app → Certificates & secrets, or switch to
  `-DeviceCode`. (Pre-fix servers: this also surfaced when a device-code
  blob accidentally inherited the server's own `BC_CLIENT_SECRET`; the
  fixed server no longer does that.)
- `Validation failed: AADSTS7000218…`
  → Public client flows disabled. In Azure portal: Authentication →
  "Allow public client flows" → Yes.
- `Validation failed: invalid_grant` (device-code)
  → Refresh token expired or user revoked consent. Re-run this command
  and sign in again.
- `Validation failed: Unauthorized` / `Forbidden`
  → The authenticated principal has no permissions in the tenant.
- `Validation request to https://dynamics.is/… failed: …`
  → Network / TLS / server down. Retry later, or pass
  `-SkipValidation` to write the new blob anyway (strongly discouraged
  — only use when you have reason to believe the credentials are
  correct and the server is temporarily unreachable).

### Step 8 — Fallback: macOS / Linux

`Create-ConnectionString.ps1 -Nickname` is Windows-only (DPAPI). On
macOS / Linux use the cross-platform Node helper and patch the config
manually:

```bash
cd ~/OrigoBC
node create-connection-string.js \
  --tenant      '<tenant>' \
  --client      '<client>' \
  --environment '<env>'          # add --device-code for device flow
```

The Node helper performs the same `list_companies` round-trip
validation and aborts with a clear error if it fails. On success it
copies a `plain:<ciphertext>` blob to the clipboard. Replace the
second element of the existing `bc-<nickname>` entry's `args` array
with that value. Do not print the blob back in chat.

### Step 9 — Restart and verify

Tell the user to **restart Cowork / Claude Desktop** and verify with:

```
mcp__bc-<nickname>__list_companies
```

If the user wants to change the default company at the same time,
suggest `/origo-bc-switch-company` after the restart rather than folding
it into this command — the two concerns stay cleanly separated.
