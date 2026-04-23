---
name: origo-bc-accounting
description: >
  This skill should be used when the user mentions Business Central, BC,
  Dynamics 365, Origo BC, the MCP server at dynamics.is, skills or prompts
  stored in BC, `get_config`, `set_config`, UBL templates, or asks about the
  `/origo-bc-*` commands. Loads the Origo BC operating rules that govern how
  Claude reads and writes skills, prompts and UBL templates in the BC
  MCP-Skills, MCP-Prompts and UBL Templates namespaces, and which connection
  formats are accepted by the server.
metadata:
  version: "0.3.0"
  author: "Origo hf."
---

# Origo BC — MCP operating rules

Follow these rules whenever the user is working with the Origo BC MCP
endpoint (`https://dynamics.is/api/mcp`), skills, prompts, UBL templates or
the `/origo-bc-*` commands.

## Full accounting rules — `get_bc_accounting_rules`

This skill is a compact starter set. The MCP server hosts a **comprehensive
version** of the Origo BC accounting and development rules at
`https://origopublic.blob.core.windows.net/resources/mcp/CLAUDE.online.md`.

**When this skill loads, call `get_bc_accounting_rules` on the MCP server to
fetch the full rules.** The tool supports three retrieval modes:

| Call | What you get |
|------|-------------|
| `get_bc_accounting_rules()` | Frontmatter, intro, and a heading-only table of contents (small payload — start here). |
| `get_bc_accounting_rules({ section: "AL Naming Conventions" })` | A single section by heading text (case-insensitive, substring match). |
| `get_bc_accounting_rules({ full: true })` | The entire document — use only when the full context is truly needed. |

The tool caches the document for 5 minutes. Pass `{ refresh: true }` to
bypass the cache.

**Recommended flow:**
1. Call with no arguments to get the TOC.
2. Load sections on demand as the conversation requires them.
3. Only request `{ full: true }` when a broad review or cross-cutting task
   needs the complete document.

## Cowork / Claude.ai scope

When running inside Cowork chat or Claude.ai (not VS Code / Claude Code):

- Use **only** `get_config` and `set_config` to read and write skills and
  prompts.
- **Never** call `check_standards_status`, `update_bc_standards`, or
  `setup_origo_bc_environment` — those tools are for VS Code's developer
  environment only.
- Skills and prompts live in the Business Central database, not in local
  files.
- The words "SKILL" / "skills" always refer to BC `MCP-Skills` records.
- The words "PROMPT" / "prompts" always refer to BC `MCP-Prompts` records.

## Two BC namespaces

| Source        | Role                    | Content                                   |
| ------------- | ----------------------- | ----------------------------------------- |
| `MCP-Skills`  | Knowledge / lookup text | JSON with patterns, rules, reference data |
| `MCP-Prompts` | Triggers / workflows    | Markdown body + frontmatter + variables   |

Both namespaces use the same index pattern: the record at GUID
`00000000-0000-0000-0000-000000000000` is the index of every record in that
namespace.

Fetch the index **only when the user asks about BC, skills, or a BC-adjacent
task** — never automatically at the start of every conversation.

## Reading skills from BC

```
get_config(source: "MCP-Skills", id: "00000000-0000-0000-0000-000000000000")
get_config(source: "MCP-Skills", id: "<guid>")
```

`data` is the full record body — use it as source material for the relevant
slice of work.

### Two skill storage types

| `type`          | Where is the content?                             | How to load                                                      |
| --------------- | ------------------------------------------------- | ---------------------------------------------------------------- |
| `content`       | Inline in the record's `data` field               | Read `data` directly                                             |
| `remote-loader` | Metadata + `sourceUrl` only; body is on the web   | Fetch `sourceUrl` via WebFetch and treat the response as source  |

For a `remote-loader` skill: fetch the record, then fetch `sourceUrl`, then
use the downloaded content as the authoritative body.

## Reading prompts from BC

Prompts are slash-command templates that reference one or more skills via
`skillRefs`.

```
get_config(source: "MCP-Prompts", id: "00000000-0000-0000-0000-000000000000")
get_config(source: "MCP-Prompts", id: "<guid>")
```

Prompt record shape:

```json
{
  "name": "<prompt-name>",
  "description": "<what it does>",
  "frontmatter": { "mode": "agent", "tools": [] },
  "variables": [ { "name": "foo", "type": "input", "description": "" } ],
  "skillRefs": ["<skill-guid-1>", "<skill-guid-2>"],
  "body": "<markdown with ${input:variable} placeholders>"
}
```

When a user's request matches a prompt: fetch that prompt, fetch every
referenced skill, then execute the `body`.

## MCP connection format — AES-256-GCM

The server's `resolveConn` accepts **only** AES-256-GCM encrypted blobs.
`plain:<base64>` blobs are **rejected** as of v0.3.0 — the server returns a
migration error directing the user to re-run the connection script.

### How the blob is produced

1. The helper script (`Create-ConnectionString.ps1` on Windows,
   `create-connection-string.js` elsewhere) collects tenant, client,
   secret, and environment.
2. It calls the `encrypt_data` endpoint on the MCP server
   (`https://dynamics.is/api/mcp`) via JSON-RPC — no authentication
   headers required.
3. The server encrypts the JSON with AES-256-GCM using `MCP_ENCRYPTION_KEY`
   and returns base64 ciphertext.
4. On Windows, the script wraps the ciphertext with DPAPI (bound to the
   current user and machine) before storing it.

**Protection in practice:**

- In transit: TLS from helper to server.
- At rest: DPAPI on Windows (user + machine bound), filesystem permissions
  elsewhere (`chmod 600`).
- Server-side: `MCP_ENCRYPTION_KEY` is a 256-bit key stored as an
  environment variable on the Azure Function.

### Scripts

| Platform | Command | Output |
| -------- | ------- | ------ |
| Windows  | `.\Create-ConnectionString.ps1 -TenantId ... -ClientId ... -Environment ...` | `dpapi:<base64>` |
| macOS / Linux | `node create-connection-string.js --tenant ... --client ... --environment ...` | Raw AES ciphertext (base64) |

Both scripts prompt for the client secret with hidden input and copy the
result to the clipboard.

### v0.3 migration — existing users

If a user's existing `bc-*` entry uses a `plain:<base64>` blob, it will
stop working after the server update. The error message from `resolveConn`
is:

> `plain: connection strings are no longer supported. Re-run Create-ConnectionString.ps1 (Windows) or create-connection-string.js to generate an AES-256-GCM encrypted blob.`

**Fix:** Run `/origo-bc-update-env` to re-generate the blob for the
affected entry. The skill pre-fills tenant/client/environment from the
existing config and walks the user through the re-authentication.

### Choosing a format (no longer applies)

There is only one format. All new and existing installs must use
AES-256-GCM encrypted blobs. The `stdio-proxy.js` bridge forwards whatever
string it has in `x-encrypted-conn`; the server decrypts it.

## Update rules

### When you learn something new

If you discover a new pattern, a known bug, a workaround, or a confirmation
that something works (or doesn't), **write it into the relevant skill
record immediately** so it persists across sessions.

```
set_config(source: "MCP-Skills", id: "<guid>", data: { ...updated body... })
```

### When adding a new skill

1. Mint a new GUID in the form `AXXXXXXX-0000-0000-0000-XXXXXXXXXXXX`:
   - `A1xxxxxx` — `bc-general/*` (content)
   - `A2xxxxxx` — `bc-journal-corrections/*` (content)
   - `A3xxxxxx` — `bc-incoming-document/*` (content)
   - `A9xxxxxx` — top-level orchestration skills (content)
2. Decide `type`: `content` (store in BC) or `remote-loader` (store metadata + URL).
3. Save the skill with `set_config(source: "MCP-Skills", ...)`.
4. **Update the skills index** with the name, GUID, `type`, description, and
   trigger conditions.

```
set_config(source: "MCP-Skills", id: "00000000-0000-0000-0000-000000000000", data: { ...index with new entry... })
```

### When adding a new prompt

1. Mint a new GUID in the form `BXXXXXXX-0000-0000-0000-XXXXXXXXXXXX`:
   - `B9xxxxxx` — top-level orchestration prompts (pairs with A9 skills).
   - GUIDs may contain only hex (0-9, A-F). `P` is not valid hex.
2. Save the prompt with `set_config(source: "MCP-Prompts", ...)`.
3. **Update the prompts index** with the name, GUID, description, variables,
   `skillRefs`, and trigger conditions.

### When to update the index

Always update the index when:

- A new record is added.
- A record is removed or merged into another.
- A trigger condition or description changes.

## UBL XML templates

Icelandic PEPPOL UBL XML templates live in Cloud Events Storage under
`source = "UBL Templates"`. Whenever Claude is producing PEPPOL UBL XML
(invoice, credit note, order, etc.), **fetch a template first**. Never
write UBL XML from scratch; the templates enforce correct namespace
declarations, PEPPOL `CustomizationID` / `ProfileID`, and Iceland-specific
defaults.

```
get_config(source: "UBL Templates", id: "DDDD0000-0000-0000-0000-000000000000")
get_config(source: "UBL Templates", id: "<guid-from-index>")
```

Three standards are supported:

| Standard                   | UBL version | Use                                                                    |
| -------------------------- | ----------- | ---------------------------------------------------------------------- |
| **PEPPOL BIS 3.0**         | 2.1         | Current standard — use by default                                     |
| **PEPPOL BIS 2.0**         | 2.1         | Transition standard (~2017–2021)                                      |
| **IS e-reikningur BII1**   | 2.0         | Original Icelandic electronic invoice (legacy systems)                |

Identify the right standard from `CustomizationID` and `ProfileID` on the
source document.

Template use:

1. Fetch the template for the document type.
2. Replace every `{{placeholder|default}}` with the real value (use
   `default` if nothing is available).
3. Remove empty optional blocks (those whose placeholder had no default and
   no data).
4. Repeat line blocks (`InvoiceLine`, `CreditNoteLine`, etc.) once per line.
5. Resolve customer data by field numbers 90 (GLN) and 47 (Registration No.)
   to determine `EndpointID`.

### EndpointID resolution

| GLN value      | EndpointID                 | schemeID (BIS 3.0) | schemeID (BIS 2.0) | schemeID (BII1) |
| -------------- | -------------------------- | ------------------ | ------------------ | --------------- |
| 10 digits      | GLN (= kennitala)          | `0196`             | `9917`             | `IS:KT`         |
| 13 characters  | GLN (international GS1)    | `0088`             | `0088`             | `0088`          |
| Empty          | Registration No. (kennitala) | `0196`           | `9917`             | `IS:KT`         |

`0088` = GS1 GLN scheme. `0196` = Icelandic national registry (BIS 3.0).
`9917` = kennitala EAS code (BIS 2.0). `IS:KT` = kennitala (BII1).

## Local files

Files under `C:\Data\MCP\prompts\*.prompt.md` are **mirrors** of BC prompt
records — VS Code / Claude Code reads them as slash commands. They are
**not** the source of truth; if a mirror drifts from BC, rebuild it from
the BC record.

### Single source of truth

Skills and prompts in BC are the **one source of truth**. Local files only
describe how to fetch them — they don't store the content.
