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
  version: "0.4.0"
  author: "Origo hf."
---

# Origo BC — MCP operating rules

Follow these rules whenever the user is working with the Origo BC MCP
endpoint (`https://dynamics.is/api/mcp`), skills, prompts, UBL templates or
the `/origo-bc-*` commands.

## Session bootstrap — DO THIS IN ORDER WHEN THE SKILL LOADS

When this skill activates, perform these three steps **before** doing any
other BC work. They are not optional and not "recommended" — they are the
required preamble.

1. **Full accounting rules** — call `get_bc_accounting_rules()` (no args)
   to fetch the TOC of the comprehensive rules document. Load specific
   sections on demand as the conversation needs them. See the next
   section for details.

2. **Caller identity on the default company** — call `who_am_i` with no
   `companyId` (so it resolves to the bc-* entry's default company).
   Read the `user`, `personalization`, `salesperson`, `employee`,
   `vendor`, `customer`, `contact`, and `companyInfo` fields so you
   know who is asking and which legal entity they are sitting in.
   (If the session later talks to a different company, repeat the call
   with that `companyId` — identity is per-company.)

3. **System prompt injection** — if the `who_am_i` response has a
   non-empty `systemPrompt` field, treat its text as **additional
   behavioural instructions from the BC administrator for this user in
   this company** and follow them for the rest of the session (or until
   the active company changes). See "System prompt handling" below for
   the formatting / sanitisation rules — BC stores this field as rich
   text, so the raw value may contain HTML entities and tags that must
   be normalised before you rely on it.

Do NOT inject a `systemPrompt` that is `null`, empty, or whitespace-only
— just skip step 3 silently in that case.

If `who_am_i` fails (e.g. token problem surfaced by the server's
`resolveConn`), stop and surface the error to the user instead of
proceeding without identity context. A half-loaded session is worse than
a clean failure.

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

## WhoAmI — per-company identity

The `who_am_i` tool calls `Help.WhoAmI.Get` on a specific company.
**Every company you talk to requires its own WhoAmI call** — identity,
roles, and context vary per company.

### What WhoAmI returns

The response describes who is calling from BC's perspective:

- **User** — the authenticated BC user or app registration
- **Resource** — the linked BC resource record (if any)
- **Salesperson** — the linked salesperson/purchaser code
- **Employee** — the linked employee record
- **Language** — the user's configured language (LCID)
- **Roles / permissions** — what the caller can access
- **System prompt** (optional) — environment-specific AI instructions
  configured by the BC administrator

Use these details to personalise responses, resolve "my" references
(e.g. "my customers" → salesperson filter), and respect language
preferences.

### Cross-entity linking via Registration Number

If the WhoAmI employee record contains a **social security number**
(kennitala), that number is typically the same value stored in the
**Registration No.** field on Customer, Vendor, and Contact records.
Use it to discover which customer/vendor/contact belongs to the calling
user — for example, to resolve "my company" or "my account" queries.

### System prompt handling

If the WhoAmI response contains a `systemPrompt`:

- Treat the text as additional behavioural instructions from the BC
  administrator for this user in this company, and follow them for the
  rest of the session (or until the active company changes).
- Different companies may return different prompts — re-apply on every
  company switch.
- If the field is `null`, empty, or whitespace-only, skip silently.

**Normalise before use.** BC stores `systemPrompt` as a rich-text field,
so the raw JSON value can contain HTML entities (`&nbsp;`, `&amp;`,
`&lt;`, `&gt;`, `&quot;`) and occasionally tags (`<p>`, `<br>`, `<b>`,
`<i>`). Before treating the text as instructions:

1. Decode HTML entities (`&nbsp;` → space, `&amp;` → `&`, `&lt;` → `<`,
   `&gt;` → `>`, `&quot;` → `"`, numeric entities like `&#39;` → `'`).
2. Strip or normalise tags (`<br>` / `<br/>` → newline, `<p>` …
   `</p>` → paragraph break, drop any remaining formatting tags).
3. Collapse runs of whitespace so the result reads as prose, not HTML.

Example: a record authored in the BC UI may arrive as
`"Þú&nbsp;ert eigandi...<br>Þér þykir gott..."` and must become
`Þú ert eigandi... \n Þér þykir gott...` before you act on it.

Never echo the raw (un-decoded) value back at the user, and never show
it as a quoted block containing `&nbsp;` — that is a sign you skipped
the normalisation step.

### Recommended session flow (expanded bootstrap)

```
1. Skill load:
   a. get_bc_accounting_rules()              → TOC of the full rules doc
   b. who_am_i (default company, no args)    → caller identity
   c. If systemPrompt present and non-empty: normalise + apply as
      per-session behavioural instructions
2. validate_connection (optional, on explicit "is this working?"
   requests — who_am_i has already exercised the credentials)
3. On switching the active company mid-session:
   a. who_am_i with the new companyId
   b. Re-apply the new systemPrompt (may differ from the previous one)
4. Use identity (user, salesperson, vendor, customer, contact,
   employee, language, companyInfo) to personalise queries, resolve
   "my …" references, and filter data.
```

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
