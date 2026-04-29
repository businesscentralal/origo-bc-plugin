---
name: origo-bc-accounting
description: >
  This skill should be used when the user mentions Business Central, BC,
  Dynamics 365, Origo BC, the MCP server at dynamics.is, skills or prompts
  stored in BC, memory tools, `get_config`, `set_config`, UBL templates, or
  asks about the `/origo-bc-*` commands. Loads the Origo BC operating rules
  that govern the three-tier storage model (user memory, company memory,
  environment config), identity handling via who_am_i, and which connection
  formats are accepted by the server.
metadata:
  version: "0.5.0"
  author: "Origo hf."
---

# Origo BC — MCP operating rules

Follow these rules whenever the user is working with the Origo BC MCP
endpoint (`https://dynamics.is/api/mcp`), skills, prompts, memory,
UBL templates or the `/origo-bc-*` commands.

## Session bootstrap — DO THIS IN ORDER WHEN THE SKILL LOADS

When this skill activates, perform these steps **before** doing any
other BC work. They are not optional and not "recommended" — they are the
required preamble.

1. **Caller identity on the default company** — call `who_am_i` with no
   `companyId` (so it resolves to the bc-* entry's default company).
   Read the `user`, `personalization`, `salesperson`, `employee`,
   `vendor`, `customer`, `contact`, and `companyInfo` fields so you
   know who is asking and which legal entity they are sitting in.
   (If the session later talks to a different company, repeat the call
   with that `companyId` — identity is per-company.)

   **Language default:** The response includes a language code (LCID).
   From this point forward, use that language for **all** chat responses
   and MCP tool interactions in this session. See "Language handling"
   below for the full rules.

   **Permissions:** The response includes `canUpdateCompanyMemory`
   (boolean) — note this for write operations to company memory.

2. **System prompt injection** — if the `who_am_i` response has a
   non-empty `systemPrompt` field, treat its text as **additional
   behavioural instructions from the BC administrator for this user in
   this company** and follow them for the rest of the session (or until
   the active company changes). See "System prompt handling" below for
   the formatting / sanitisation rules — BC stores this field as rich
   text, so the raw value may contain HTML entities and tags that must
   be normalised before you rely on it.

Do NOT inject a `systemPrompt` that is `null`, empty, or whitespace-only
— just skip step 2 silently in that case.

If `who_am_i` fails (e.g. token problem surfaced by the server's
`resolveConn`), stop and surface the error to the user instead of
proceeding without identity context. A half-loaded session is worse than
a clean failure.

## Three-tier storage model

Skills, prompts, notes, and configuration are stored across three tiers.
Each tier has different visibility, permissions, and tools.

| Tier | BC table | Visibility | Tools | Write permission |
|------|----------|-----------|-------|-----------------|
| **User** (default) | Cloud Events User Memory (65320) | Private to calling user | `list_user_memory` / `get_user_memory` / `set_user_memory` | Always — own records only |
| **Company** | Cloud Events Memory (65319) | All authenticated users in the company | `list_company_memory` / `get_company_memory` / `set_company_memory` | `canUpdateCompanyMemory = true` (from `who_am_i`) |
| **Environment** | Cloud Events Storage (65308) | All companies, environment-wide | `get_config` / `set_config` with source string | `get_table_permissions({ table: "Cloud Events Storage" })` must show write access |

### Default tier: user memory

**User memory is the primary and default storage.** When the user says
"save this", "remember this", "create a skill", or "store a prompt"
without specifying a tier, write to user memory.

### When to use each tier

| Use case | Tier | Reason |
|----------|------|--------|
| Personal skills, prompts, notes, preferences | **User** | Private, no permission gate |
| Shared team knowledge, company-wide rules, shared skills | **Company** | Visible to all users in the company |
| Global templates (UBL XML), environment-wide config | **Environment** (via dedicated tools) | Cross-company, accessed via `list_ubl_templates` / `render_ubl_template` |
| Promoting a personal skill to team use | **User → Company** | Read from user, write to company |

### Cowork / Claude.ai scope

When running inside Cowork chat or Claude.ai (not VS Code / Claude Code):

- Use **memory tools** (`list_*` / `get_*` / `set_*_memory`) for skills
  and prompts. Use `get_config` / `set_config` only for environment-tier
  records (legacy MCP-Skills/MCP-Prompts). For UBL Templates, use the
  dedicated `list_ubl_templates` and `render_ubl_template` tools.
- **Never** call `check_standards_status`, `update_bc_standards`, or
  `setup_origo_bc_environment` — those tools are for VS Code's developer
  environment only.
- Skills and prompts live in the Business Central database, not in local
  files.

## Memory tools — list / get / set

Each of the user and company tiers has three verbs:

| Verb | What it returns | When to use |
|------|----------------|-------------|
| **list** | `id` (GUID) + `description` (Text[2048]) only | Discovery — find what exists without loading full content |
| **get** | `id` + `description` + `memory` (full UTF-8 markdown) | Read the actual content of a specific record |
| **set** | Creates or updates a record | Write new or update existing content |

### Discovery workflow

1. **List** to find records — use `tableView` to filter by description:
   ```
   list_user_memory({ tableView: "WHERE(Description=FILTER(*exchange-rate*))" })
   ```
2. **Get** a specific record by ID or filtered:
   ```
   get_user_memory({ tableView: "WHERE(Description=CONST(skill:exchange-rates))" })
   ```
3. **Set** to create or update:
   ```
   set_user_memory({ description: "skill:exchange-rates", memory: "..." })        // create new
   set_user_memory({ id: "<guid>", memory: "...updated content..." })             // update existing
   ```

### Description field conventions

The description field (max 2048 characters) serves as the primary
discovery mechanism. Use structured prefixes:

| Prefix | Meaning | Example |
|--------|---------|---------|
| `skill:<name>` | Knowledge / reference material | `skill:exchange-rates` |
| `prompt:<name>` | Workflow template / slash command | `prompt:post-journal` |
| `note:<topic>` | Working notes, patterns, decisions | `note:kappi-portfolio` |

### Record lifecycle

- **Create**: call `set_*_memory` with `description` + `memory` (no `id`)
  — the server auto-generates the GUID.
- **Update**: call `set_*_memory` with `id` + the fields to change.
- **"Delete"**: records cannot be deleted. Set `memory` to empty string
  to clear content. The record remains with its description as a tombstone.

### Filtering with tableView

The `tableView` parameter accepts standard BC filter syntax on the
Description field:

| Pattern | Example |
|---------|---------|
| Exact match | `WHERE(Description=CONST(skill:exchange-rates))` |
| Wildcard | `WHERE(Description=FILTER(skill:*))` |
| Substring | `WHERE(Description=FILTER(*journal*))` |

All three verbs (list, get, set) plus `skip` and `take` for pagination.

## Environment tier — get_config / set_config

The environment tier uses `get_config` and `set_config` with a `source`
string. This tier is for global, cross-company content that predates
the memory tools.

| Source | Content | Index GUID |
|--------|---------|-----------|
| `MCP-Skills` | Legacy skills (JSON with patterns, rules, reference data) | `00000000-0000-0000-0000-000000000000` |
| `MCP-Prompts` | Legacy prompts (markdown + frontmatter + variables) | `00000000-0000-0000-0000-000000000000` |
| `UBL Templates` | PEPPOL UBL XML templates | `DDDD0000-0000-0000-0000-000000000000` |

```
get_config(source: "MCP-Skills", id: "00000000-0000-0000-0000-000000000000")   // skills index
get_config(source: "MCP-Skills", id: "<guid>")                                 // specific skill
set_config(source: "MCP-Skills", id: "<guid>", data: { ... })                  // update skill
```

### Two skill storage types (environment tier)

| `type` | Where is the content? | How to load |
|--------|----------------------|-------------|
| `content` | Inline in the record's `data` field | Read `data` directly |
| `remote-loader` | Metadata + `sourceUrl` only; body is on the web | Fetch `sourceUrl` via WebFetch and treat the response as source |

For a `remote-loader` skill: fetch the record, then fetch `sourceUrl`,
then use the downloaded content as the authoritative body.

### Prompt record shape (environment tier)

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

### Migration note

New skills and prompts should be created in **user memory** (personal)
or **company memory** (shared) rather than the environment tier. The
environment tier remains for UBL Templates and existing MCP-Skills /
MCP-Prompts records that have not yet been migrated.

## MCP connection format — AES-256-GCM

The server's `resolveConn` accepts **only** AES-256-GCM encrypted blobs.
`plain:<base64>` blobs are **rejected** — the server returns a migration
error directing the user to re-run the connection script.

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
- **canUpdateCompanyMemory** — boolean; true when the caller can write
  to company memory via `set_company_memory`
- **System prompt** (optional) — environment-specific AI instructions
  configured by the BC administrator

Use these details to personalise responses, resolve "my" references
(e.g. "my customers" → salesperson filter), and respect language
preferences.

### Language handling

The `who_am_i` response includes a language code (LCID, e.g. `ISL` for
Icelandic, `ENU` for English). This is the user's configured language in
Business Central and it governs the **entire session**:

1. **Chat responses** — write all replies to the user in this language by
   default. If the user explicitly switches language mid-conversation
   (e.g. writes in English), follow their lead, but revert to the
   WhoAmI language when they stop overriding.
2. **MCP tool calls — match the user's active language.** When calling
   MCP tools, pass the numeric LCID that corresponds to the language the
   user is **currently writing in**:
   - Icelandic → `1039`
   - English → `1033`
   If the user switches language mid-conversation, switch the LCID sent
   to the MCP server immediately. Always keep the MCP language in sync
   with whatever language the user is using right now.
3. **MCP tool output** — when presenting tool output, field names,
   status messages, or summaries, use the user's active language.
4. **Error messages and prompts** — surface errors and ask clarifying
   questions in this language.
5. **Company switch** — when the active company changes and a new
   `who_am_i` call returns a different language code, switch to the new
   language immediately.
6. **Fallback** — if `who_am_i` returns no language code or the value is
   unrecognised, default to Icelandic (`1039`) for Origo BC sessions.

Do **not** wait for the user to ask you to switch language — the WhoAmI
language is the default from the moment it is received.

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

### Recommended session flow

```
1. Skill load:
   a. who_am_i (default company, no args)    → caller identity + language
                                                + canUpdateCompanyMemory
   b. Apply language code as session default (all replies in that language)
   c. If systemPrompt present and non-empty: normalise + apply as
      per-session behavioural instructions
2. validate_connection (optional, on explicit "is this working?"
   requests — who_am_i has already exercised the credentials)
3. On switching the active company mid-session:
   a. who_am_i with the new companyId
   b. Re-apply language code (may differ from previous company)
   c. Re-apply the new systemPrompt (may differ from the previous one)
   d. Note the new canUpdateCompanyMemory value
4. Use identity (user, salesperson, vendor, customer, contact,
   employee, language, companyInfo) to personalise queries, resolve
   "my …" references, and filter data.
```

### How the connection blob is produced

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
|----------|---------|--------|
| Windows | `.\Create-ConnectionString.ps1 -TenantId ... -ClientId ... -Environment ...` | `dpapi:<base64>` |
| macOS | `node create-connection-string.js --tenant ... --client ... --environment ...` | `keychain:<service>` (Keychain-bound) |
| Linux | `node create-connection-string.js --tenant ... --client ... --environment ...` | `plain:<base64>` |

Both scripts prompt for the client secret with hidden input. With
`--nickname` / `-Nickname` the result is written directly into the
Claude Desktop MCP config (no clipboard). Without it, the result is
copied to the clipboard.

## Update rules

### When you learn something new

If you discover a new pattern, a known bug, a workaround, or a confirmation
that something works (or doesn't), **write it to memory immediately** so
it persists across sessions.

**Default: user memory** — personal knowledge and working notes:
```
set_user_memory({ description: "note:<topic>", memory: "...markdown content..." })
```

**Shared knowledge** — if the insight applies to all users in the company
and `canUpdateCompanyMemory` is true:
```
set_company_memory({ description: "note:<topic>", memory: "...markdown content..." })
```

### When adding a new skill or prompt

1. Choose the tier:
   - **User memory** (default) — personal skill or prompt
   - **Company memory** — shared with all users in the company
   - **Environment** — global, cross-company (legacy — prefer memory tiers)
2. Write the record with an appropriate description prefix:
   ```
   set_user_memory({ description: "skill:my-new-skill", memory: "...markdown..." })
   set_user_memory({ description: "prompt:my-workflow", memory: "...markdown..." })
   ```
3. No separate index record is needed — use `list_*_memory` with
   description filters for discovery.

### Promoting between tiers

To promote a personal skill to company-wide:
```
1. get_user_memory({ tableView: "WHERE(Description=CONST(skill:my-skill))" })
2. set_company_memory({ description: "skill:my-skill", memory: "<content from step 1>" })
```

Requires `canUpdateCompanyMemory = true`.

### Environment-tier updates (legacy)

For existing records in MCP-Skills, MCP-Prompts, or UBL Templates:
```
set_config(source: "MCP-Skills", id: "<guid>", data: { ...updated body... })
```

Requires write access to Cloud Events Storage (table 65308) — verify with
`get_table_permissions({ table: "Cloud Events Storage" })`.

### GUID conventions (environment tier only)

Environment-tier records use structured GUID prefixes:

| Prefix | Category |
|--------|----------|
| `A1xxxxxx-0000-0000-0000-xxxxxxxxxxxx` | `bc-general/*` skills (content) |
| `A2xxxxxx-0000-0000-0000-xxxxxxxxxxxx` | `bc-journal-corrections/*` skills (content) |
| `A3xxxxxx-0000-0000-0000-xxxxxxxxxxxx` | `bc-incoming-document/*` skills (content) |
| `A4xxxxxx-0000-0000-0000-xxxxxxxxxxxx` | `bc-integration/*` skills (often remote-loader) |
| `A9xxxxxx-0000-0000-0000-xxxxxxxxxxxx` | Top-level orchestration skills (content) |
| `B9xxxxxx-0000-0000-0000-xxxxxxxxxxxx` | Top-level orchestration prompts |
| `DDDD0000-0000-0000-0000-xxxxxxxxxxxx` | UBL Templates |

GUIDs may contain only hex characters (0-9, A-F). Memory-tier records
use auto-generated GUIDs — no manual minting needed.

## UBL XML templates

Icelandic PEPPOL UBL XML templates live in Cloud Events Storage under
`source = "UBL Templates"`. Whenever Claude is producing PEPPOL UBL XML
(invoice, credit note, order, etc.), **use the dedicated MCP tools**.
Never write UBL XML from scratch; the templates enforce correct namespace
declarations, PEPPOL `CustomizationID` / `ProfileID`, and Iceland-specific
defaults.

### Tools

| Tool | Purpose |
|------|--------|
| `list_ubl_templates` | Returns the template index — all available templates with their IDs and descriptions |
| `render_ubl_template` | Fetches a template by ID and renders it with supplied placeholder values and optional embeddings |

These tools use a centralized server-side connection (`SETUP_*` env vars)
and do **not** require the caller to pass any connection parameters.

### Workflow

1. **Discover** — call `list_ubl_templates()` to see available templates.
2. **Render** — call `render_ubl_template({ templateId, placeholders, embeddings })` where:
   - `templateId` — GUID from the index
   - `placeholders` — object mapping placeholder names to values (e.g. `{ "InvoiceNo": "INV-001", ... }`)
   - `embeddings` — optional array of `{ id, description, mimeCode, filename, base64Content }` for attachments
3. The tool handles placeholder substitution, removes empty optional blocks,
   converts legacy `[BLOCK:...]...[/BLOCK:...]` syntax, and injects
   `<cac:AdditionalDocumentReference>` elements for embeddings.

### Do NOT use `get_config` for UBL

The old pattern (`get_config(source: "UBL Templates", id: "...")` +
manual placeholder replacement) is **deprecated**. Always use the
dedicated tools which handle rendering server-side with proper XML
escaping.

Three standards are supported:

| Standard | UBL version | Use |
|----------|-------------|-----|
| **PEPPOL BIS 3.0** | 2.1 | Current standard — use by default |
| **PEPPOL BIS 2.0** | 2.1 | Transition standard (~2017–2021) |
| **IS e-reikningur BII1** | 2.0 | Original Icelandic electronic invoice (legacy systems) |

Identify the right standard from `CustomizationID` and `ProfileID` on the
source document.

Resolve customer data by field numbers 90 (GLN) and 47 (Registration No.)
to determine `EndpointID`.

### EndpointID resolution

| GLN value | EndpointID | schemeID (BIS 3.0) | schemeID (BIS 2.0) | schemeID (BII1) |
|-----------|-----------|-------------------|-------------------|-----------------|
| 10 digits | GLN (= kennitala) | `0196` | `9917` | `IS:KT` |
| 13 characters | GLN (international GS1) | `0088` | `0088` | `0088` |
| Empty | Registration No. (kennitala) | `0196` | `9917` | `IS:KT` |

`0088` = GS1 GLN scheme. `0196` = Icelandic national registry (BIS 3.0).
`9917` = kennitala EAS code (BIS 2.0). `IS:KT` = kennitala (BII1).

## Local files

Files under `C:\Data\MCP\prompts\*.prompt.md` are **mirrors** of BC
records — VS Code / Claude Code reads them as slash commands. They are
**not** the source of truth; if a mirror drifts from BC, rebuild it from
the BC record.

### Single source of truth

Skills and prompts in BC (user memory, company memory, or environment
config) are the **one source of truth**. Local files only describe how
to fetch them — they don't store the content.
