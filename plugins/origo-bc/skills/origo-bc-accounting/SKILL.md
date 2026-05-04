---
name: origo-bc-accounting
description: >
  This skill should be used when the user mentions Business Central, BC,
  Dynamics 365, Origo BC, the MCP server at dynamics.is, skills or prompts
  stored in BC, memory tools, UBL templates, or asks about the
  `/origo-bc-*` commands. Loads the Origo BC operating rules that govern
  the two-tier storage model (user memory, company memory), identity
  handling via who_am_i, and which connection formats are accepted by the
  server.
metadata:
  version: "0.7.0"
  author: "Origo hf."
---

# Origo BC — MCP operating rules

Follow these rules whenever the user is working with the Origo BC MCP
endpoint (`https://dynamics.is/api/mcp`), skills, prompts, memory,
UBL templates, or the `/origo-bc-*` commands.

## Session bootstrap — DO THIS IN ORDER WHEN THE SKILL LOADS

When this skill activates, perform these steps **before** doing any
other BC work. They are not optional and not "recommended" — they are the
required preamble.

1. **Caller identity on the default company** — call `who_am_i` with no
   `companyId` (so it resolves to the bc-* entry's default company).
   Read the `user`, `personalization`, `userSetup`, `approvalSetup`,
   `notificationSetup`, `resource`, `salesperson`, `employee`,
   `manager`, `companyInfo`, `warehouseLocations`,
   `responsibilityCenters`, `dueFromToOwner`, `customer`, `vendor`,
   `contact`, `unreadNotifications`, and `pendingApprovals` fields so
   you know who is asking, what they can approve, how they are notified,
   what needs their attention, and which legal entity they sit in.
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

## Two-tier storage model

Skills, prompts, notes, and configuration are stored across two tiers.
Each tier has different visibility, permissions, and tools.

| Tier | BC table | Visibility | Tools | Write permission |
|------|----------|-----------|-------|------------------|
| **User** (default) | Cloud Events User Memory (65320) | Private to calling user | `list_user_memory` / `get_user_memory` / `set_user_memory` | Always — own records only |
| **Company** | Cloud Events Memory (65319) | All authenticated users in the company | `list_company_memory` / `get_company_memory` / `set_company_memory` | `canUpdateCompanyMemory = true` (from `who_am_i`) |

### Default tier: user memory

**User memory is the primary and default storage.** When the user says
"save this", "remember this", "create a skill", or "store a prompt"
without specifying a tier, write to user memory.

### When to use each tier

| Use case | Tier | Reason |
|----------|------|--------|
| Personal skills, prompts, notes, preferences | **User** | Private, no permission gate |
| Shared team knowledge, company-wide rules, shared skills | **Company** | Visible to all users in the company |
| Promoting a personal skill to team use | **User → Company** | Read from user, write to company |

### Cowork / Claude.ai scope

When running inside Cowork chat or Claude.ai (not VS Code / Claude Code):

- Use **memory tools** (`list_*` / `get_*` / `set_*_memory`) for skills
  and prompts. For UBL Templates, use the dedicated `list_ubl_templates`
  and `render_ubl_template` tools.
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
| `note:<topic>` | Working notes, patterns, decisions | `note:dynamics-portfolio` |

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

| Section | Type | Contents |
|---------|------|----------|
| `user` | Object/null | userSecurityId, userName, fullName, contactEmail, authenticationEmail |
| `personalization` | Object/null | profileId, languageId (LCID), localeId, company, timeZone |
| `userSetup` | Object/null | userId, salesPurchCode, approverId, resp-centre filters, posting date range, email |
| `approvalSetup` | Object/null | approverId, administrator flag, unlimited flags, sales/purchase/request amount limits, substitute |
| `notificationSetup` | Array/null | notificationType, notificationMethod, recurrence, time, dailyFrequency |
| `resource` | Object/null | no, name, type — linked via Time Sheet Owner or CE User Setup override |
| `salesperson` | Object/null | code, name, email, phoneNo — linked via User Setup or CE User Setup override |
| `employee` | Object/null | no, firstName, lastName, socialSecurityNo, email, phoneNo, jobTitle, managerNo, resourceNo |
| `manager` | Object/null | no, firstName, lastName, email, phoneNo, jobTitle — the employee's manager |
| `companyInfo` | Object/null | name, address, city, postCode, countryRegionCode, phoneNo, email, homePage, vatRegistrationNo, registrationNo |
| `warehouseLocations` | Array/null | locationCode, default, adcsUser — Warehouse Employee assignments |
| `responsibilityCenters` | Object/null | salesRespCtrFilter, purchaseRespCtrFilter, serviceRespCtrFilter |
| `dueFromToOwner` | Object/null | glAccountNo, name, balanceAtDate, netChange — owner G/L account from CE User Setup |
| `customer` | Object/null | no, name, address, city, postCode, phoneNo, email, creditLimitLCY, balanceLCY, balanceDueLCY |
| `vendor` | Object/null | no, name, address, city, postCode, phoneNo, email, balanceLCY, balanceDueLCY |
| `contact` | Object/null | no, name, address, city, postCode, phoneNo, email, type, companyNo, companyName |
| `systemPrompt` | String/null | Per-user, per-company system prompt (UTF-8 text, may contain HTML entities) |
| `unreadNotifications` | Array | Unread notification threads — each entry: `sender`, `subject`, `threadId`. Deduped by threadId (one entry per thread). Empty array if none |
| `pendingApprovals` | Array | Open approval entries assigned to user — each entry: `documentType`, `documentNo`, `amountLCY`, `dueDate`. Empty array if none |
| `canUpdateCompanyMemory` | Boolean | Whether the caller can write to company memory via `set_company_memory` |

Any section returns `null` when the corresponding record does not exist.

Use these details to personalise responses, resolve "my" references
(e.g. "my customers" → salesperson filter), determine approval limits,
understand notification preferences, and respect language preferences.

## User Notification framework

The MCP server exposes a notification system built on the BC "Cloud
Events Note" table. It allows agents and integrations to send, retrieve,
and manage per-user notifications with threading support.

### Notification tools

| Tool | Direction | Purpose |
|------|-----------|---------|
| `send_notification` | Inbound | Send a notification to a BC user |
| `get_notifications` | Outbound | Retrieve notifications for the authenticated user |
| `mark_notifications_read` | Inbound | Mark notifications as read or unread |
| `get_notification_count` | Outbound | Get total / unread / read counts |
| `get_notification_thread` | Outbound | Retrieve all notifications in a specific thread |

### send_notification

Creates a notification entry visible in the recipient's notification
centre. Supports threading and linking to related records.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `recipientUserId` | Yes | String | BC User ID of the recipient (e.g. `ADMIN`) |
| `subject` | Yes | String | Subject line of the notification |
| `body` | No | String | Body text |
| `threadId` | No | String (GUID) | Groups notifications into a conversation thread |
| `parentEntryNo` | No | Integer | Entry No. of parent notification (for threaded replies) |
| `relatedTableId` | No | Integer | Table ID of the related record (e.g. 38 for Purchase Header) |
| `relatedRecordSystemId` | No | String (GUID) | SystemId of the related record |
| `notificationType` | No | String | Enum: `New Record`, `Approval`, or `Overdue` |

Returns the created notification entry with `entryNo`.

### get_notifications

Retrieves notifications for the authenticated user with optional
pagination and filtering.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `skip` | No | Integer | Number of records to skip (default 0) |
| `take` | No | Integer | Number of records to return (default 50) |
| `tableView` | No | String | BC filter syntax for additional filtering |

Response includes `result[]` with: `entryNo`, `threadId`,
`parentEntryNo`, `recipientUserId`, `senderUserId`, `relatedTableId`,
`relatedRecordSystemId`, `approvalEntryNo`, `subject`, `body`, `isRead`,
`sourceEntrySystemId`, `systemId`, `systemCreatedAt`,
`systemModifiedAt`, `notificationType`.

### mark_notifications_read

Marks one or more notifications as read or unread.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `entryNos` | Yes | String | Comma-separated entry numbers (e.g. `1,5,12`) |
| `isRead` | No | Boolean | `true` = mark read (default), `false` = mark unread |

### get_notification_count

Lightweight call for badge/indicator display.

Returns: `total`, `unread`, `read` counts for the authenticated user.

### get_notification_thread

Retrieves all notifications in a specific thread, ordered by creation
time with pagination support.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `threadId` | Yes | String (GUID) | The thread ID to retrieve |
| `skip` | No | Integer | Number of records to skip (default 0) |
| `take` | No | Integer | Number of records to return (default 50) |

### Notification workflow patterns

**Check for unread notifications:**
Use the `unreadNotifications` array from `who_am_i` for a quick summary
of unread threads (deduped by threadId). For full details, call
`get_notifications` or `get_notification_count`.

**Threaded conversations:**
1. Send a notification with a `threadId` (GUID) to start a thread.
2. Reply in the same thread by passing the same `threadId` plus the
   `parentEntryNo` of the message being replied to.
3. Use `get_notification_thread` to retrieve the full conversation.

**Acknowledging notifications:**
After presenting notification content to the user, offer to mark them as
read with `mark_notifications_read`.

## Approval workflow

The `pendingApprovals` array in `who_am_i` gives a quick summary of open
approval entries assigned to the user (documentType, documentNo,
amountLCY, dueDate). For full details and actions, use the approval
tools below.

### Approval tools

| Tool | Direction | Purpose |
|------|-----------|---------|
| `get_my_approvals` | Outbound | Full details on approvals assigned to me |
| `get_approval_entries` | Outbound | Approval history for a specific record |
| `send_for_approval` | Inbound | Submit a record for approval |
| `approve_entries` | Inbound | Approve one or more entries |
| `reject_entries` | Inbound | Reject one or more entries |
| `delegate_approval` | Inbound | Delegate an entry to another user |
| `cancel_approval` | Inbound | Cancel a pending approval request |

### get_my_approvals

Retrieves approval entries assigned to the authenticated user with full
detail — the expanded version of `pendingApprovals` from `who_am_i`.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |
| `tableView` | No | String | BC filter syntax for additional filtering |

Response fields per entry: `entryNo`, `sequenceNo`, `tableId`,
`tableName`, `tableCaption`, `documentType`, `documentNo`,
`recordSystemId`, `status`, `dueDate`, `amount`, `amountLCY`,
`currencyCode`, `comments[]`, `approvalCode`, `lastModified`.
Each entry also includes `linkedApprovalEntries[]` and
`linkedPostedApprovalEntries[]` for the full approval chain.

### get_approval_entries

Retrieves the approval log for a specific record.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `tableName` | No | String | Table name (e.g. `Purchase Header`) |
| `tableNumber` | No | Integer | Table ID (e.g. `38`) |
| `recordSystemId` | Yes | String (GUID) | SystemId of the record |
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |
| `tableView` | No | String | BC filter syntax |

Returns the same entry structure as `get_my_approvals`.

### send_for_approval

Submits a record for approval. Optionally provides an explicit approver
chain.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `tableName` | No | String | Table name |
| `tableId` | No | Integer | Table ID |
| `tableNumber` | No | Integer | Table number (alias for tableId) |
| `recordSystemId` | Yes | String (GUID) | SystemId of the record to submit |
| `approvals` | No | Array | Explicit chain: `[{ approverUserId, sequenceNo, dueDate, lineNumbers }]` |

When `approvals` is omitted, BC uses the configured approval workflow.

### approve_entries / reject_entries

Approve or reject one or more approval entries.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `entries` | No | Array | `[{ entryNo }]` or `[{ systemId }]` — batch mode |
| `entryNo` | No | Integer | Single entry (alternative to array) |
| `systemId` | No | String (GUID) | Single entry by SystemId |
| `comment` | No | String | Comment attached to the decision |

Provide either `entries[]` for batch or `entryNo`/`systemId` for single.

### delegate_approval

Delegates an approval entry to another user.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `entries` | No | Array | `[{ entryNo }]` or `[{ systemId }]` — batch mode |
| `entryNo` | No | Integer | Single entry |
| `systemId` | No | String (GUID) | Single entry by SystemId |
| `delegateToUserId` | Yes | String | BC User ID to delegate to |
| `comment` | No | String | Comment |

### cancel_approval

Cancels a pending approval request on a record.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `tableName` | No | String | Table name |
| `tableId` | No | Integer | Table ID |
| `tableNumber` | No | Integer | Table number |
| `recordSystemId` | Yes | String (GUID) | SystemId of the record |


**Sales parameters** (provide one):
`orderNo`, `quoteNo`, `invoiceNo`, `creditMemoNo`, `blanketOrderNo`,
`returnOrderNo`

**Purchase parameters** (provide one):
`orderNo`, `quoteNo`, `invoiceNo`, `creditMemoNo`, `blanketOrderNo`,
`returnOrderNo`

### Approval workflow patterns

**Quick check → drill down:**
Use `pendingApprovals` from `who_am_i` to see if approvals need
attention. If entries exist, call `get_my_approvals` for full details
including amounts, comments, and linked entries.

**Approve/reject flow:**
1. Present the approval details to the user (document type, number,
   amount, due date, any comments from the sender).
2. Ask the user for their decision.
3. Call `approve_entries` or `reject_entries` with an optional comment.

**Delegation:**
When the user cannot act on an approval (e.g. out of office), use
`delegate_approval` with the target `delegateToUserId`.

**Submitting documents:**
Use `send_for_approval` with the
record's SystemId.

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
4. Use identity (user, userSetup, approvalSetup, notificationSetup,
   resource, salesperson, employee, manager, companyInfo,
   warehouseLocations, responsibilityCenters, dueFromToOwner,
   customer, vendor, contact, unreadNotifications, pendingApprovals,
   language) to personalise queries, resolve "my …" references, and
   filter data.
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

## UBL XML templates

Icelandic PEPPOL UBL XML templates are served via **dedicated MCP tools**.
Whenever Claude is producing PEPPOL UBL XML (invoice, credit note, order,
etc.), use these tools. Never write UBL XML from scratch; the templates
enforce correct namespace declarations, PEPPOL `CustomizationID` /
`ProfileID`, and Iceland-specific defaults.

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

### Single source of truth

Skills and prompts in BC (user memory or company memory) are the **one
source of truth**. Local files only describe how to fetch them — they
don't store the content.
