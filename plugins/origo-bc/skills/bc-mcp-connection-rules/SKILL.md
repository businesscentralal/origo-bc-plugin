---
name: bc-mcp-connection-rules
description: >
  This skill should be used when the user mentions Business Central, BC,
  Dynamics 365, Origo BC, the MCP server at dynamics.is, skills or prompts
  stored in BC, `get_config`, `set_config`, UBL templates, or asks about the
  `/origo-bc-*` commands. Loads the Origo BC operating rules that govern how
  Claude reads and writes skills, prompts and UBL templates in the BC
  MCP-Skills, MCP-Prompts and UBL Templates namespaces, and which connection
  formats are accepted by the server.
metadata:
  version: "0.1.0"
  author: "Origo hf."
---

# Origo BC — MCP operating rules

Follow these rules whenever the user is working with the Origo BC MCP
endpoint (`https://dynamics.is/api/mcp`), skills, prompts, UBL templates or
the `/origo-bc-*` commands.

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

Example: `bc-cloud-events` (`A4000001-0000-0000-0000-000000000001`) is a
`remote-loader` that pulls from
`https://origopublic.blob.core.windows.net/help/Cloud%20Events/bc27/en-US/SKILL.md`.

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

## MCP connection formats — two options

The server's `resolveConn` accepts two formats for `encryptedConn` (whether
the blob arrives as the `x-encrypted-conn` header or as a tool argument):

### Option A — `plain:<base64>` (preferred for new installs)

Base64-encoded JSON `{tenantId, clientId, clientSecret, environment}`. No
HTTPS setup round-trip, no `MCP_ENCRYPTION_KEY` required server-side.

**How to build the blob:**

- Windows: `.\Create-PlainConnectionString.ps1 -TenantId ... -ClientId ... -Environment ...`
  → returns `dpapi:<base64>` (the `plain:` payload DPAPI-wrapped to the
  current Windows user/machine).
- macOS / Linux: `node create-connection-string.js --tenant ... --client ... --environment ...`
  → returns `plain:<base64>` with no DPAPI wrap; protect the config file
  with `chmod 600` or a platform secret manager.

**Protection in practice:**

- In transit: TLS from proxy to server.
- At rest: DPAPI on Windows (bound to user + machine), filesystem
  permissions elsewhere.
- No double encryption, no server key to leak.

### Option B — AES-256-GCM ciphertext (legacy, still supported)

Calls `encrypt_data` on the server with plaintext JSON → receives base64
ciphertext → DPAPI-wraps locally on Windows.

Use only for environments that already have configured `dpapi:<...>` blobs
containing AES ciphertext, or when the user explicitly requests a second
encryption layer.

### Choosing

| Situation                       | Choice              |
| ------------------------------- | ------------------- |
| New install on Windows          | A (plain: + DPAPI)  |
| New install on macOS / Linux    | A (plain: + chmod)  |
| Existing working config         | B — leave it alone  |
| Server without encryption key   | A                   |

The `stdio-proxy.js` bridge is format-agnostic — it forwards whatever string
it has in `x-encrypted-conn`. The server branches on the prefix (`plain:`
decodes base64, otherwise AES-decrypts).

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
   - `A4xxxxxx` — `bc-integration/*` (often remote-loader)
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
