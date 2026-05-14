---
name: origo-bc-accounting
description: >
  Use when the user mentions Business Central, BC, Dynamics 365, Origo BC,
  the MCP server at dynamics.is, skills/prompts stored in BC, memory tools,
  default skills/notes/prompts, UBL templates, or `/origo-bc-*` commands.
metadata:
  version: "1.0.1"
  author: "Origo hf."
references:
  - url: https://github.com/businesscentralal/origo-bc-plugin/blob/main/plugins/origo-bc/skills/origo-bc-accounting/references/TOOLS.md
    fallback: ./references/TOOLS.md
    description: Notification & approval tool parameters (load on demand)
  - url: https://github.com/businesscentralal/origo-bc-plugin/blob/main/plugins/origo-bc/skills/origo-bc-accounting/references/SETUP.md
    fallback: ./references/SETUP.md
    description: Connection scripts & blob format (load on demand)
  - url: https://github.com/businesscentralal/origo-bc-plugin/blob/main/plugins/origo-bc/skills/origo-bc-accounting/references/UBL.md
    fallback: ./references/UBL.md
    description: UBL/Peppol templates & EndpointID (load on demand)
---

# Origo BC — MCP operating rules

Rules for the Origo BC MCP endpoint (`https://dynamics.is/api/mcp`).

---

## 1. Session bootstrap (mandatory, in order)

**Step 1 — Identity:** Call `who_am_i` (no args → default company). Note:
- `personalization.languageId` → session language (see §4)
- `canUpdateCompanyMemory` → gate for company memory writes
- `canSendAndCancelApprovalRequests` → gate for approval submit/cancel
- `unreadNotifications` / `pendingApprovals` → surface proactively
- All identity sections (user, employee, salesperson, companyInfo, etc.) → personalise "my …" queries

**Step 2 — System prompt:** If `systemPrompt` is non-empty, treat as
admin-injected behavioural instructions for this user+company.
Skip silently if null/empty.

**On failure:** Surface error and stop. Never proceed without identity.

**On company switch:** Repeat both steps with the new `companyId`.

---

## 2. Three-tier storage model

| Tier | Tools | Visibility | Write | Purpose |
|------|-------|-----------|-------|----------|
| **User** (default) | `list/get/set_user_memory` | Private | Always | Personal skills, notes, prompts |
| **Company** | `list/get/set_company_memory` | All company users | `canUpdateCompanyMemory = true` | Shared team knowledge |
| **Default** | `list/get_default_memory` | All environments | Read-only | Centrally managed defaults (skills, notes, prompts) |

**Default = user memory.** "Save this" / "remember" without qualifier → user tier.

Use company tier for shared team knowledge when permission allows.

### Default memory (setup environment)

The Default tier reads from a **central setup environment** shared across all
customers/tenants. It is **read-only** — there is no `set_default_memory` tool.

**When to use:**
- On first session or when a user has no skills yet → check defaults for starter content.
- When a user asks "what default skills/prompts are available?" or similar.
- To seed a new company: `list_default_memory` → pick entries → `set_company_memory` to copy.

**Pattern — discover & adopt:**
```
1. list_default_memory()                        → browse available defaults
2. get_default_memory(tableView: "WHERE(Description=FILTER(skill:*))")
                                                → read full content of default skills
3. set_user_memory / set_company_memory          → copy desired entries locally
```

Default memory entries use the same description prefixes (`skill:`, `prompt:`,
`note:`) and the same `tableView` / `skip` / `take` / `fetchAll` parameters as
user and company memory.

### Cowork / Claude.ai scope
- Use memory tools for skills/prompts (they live in BC, not local files).
- Never call `check_standards_status`, `update_bc_standards`, or
  `setup_origo_bc_environment` (VS Code developer tools only).

---

## 3. Memory tools — list / get / set

| Verb | Returns | Use |
|------|---------|-----|
| `list` | id + description | Discovery |
| `get` | id + description + memory (full markdown) | Read content |
| `set` | Creates or updates | Write |
| `list_default` | id + description (setup env) | Discover centrally managed defaults |
| `get_default` | id + description + memory (setup env) | Read default content |

**Description prefixes:** `skill:<name>`, `prompt:<name>`, `note:<topic>`

**Filtering:** `tableView: "WHERE(Description=FILTER(*keyword*))"` — works on all verbs. Pagination via `skip`/`take`.

**Lifecycle:** Create = set without id. Update = set with id. Delete = set memory to empty string (tombstone).

---

## 4. Language handling

`who_am_i` returns LCID. Rules:
1. Reply in that language by default. Follow user's lead if they switch.
2. Pass numeric LCID to MCP tools matching the user's active language (ISL→1039, ENU→1033).
3. Present tool output in the user's active language.
4. On company switch, adopt the new LCID immediately.
5. Fallback: Icelandic (1039).

---

## 5. Cross-entity linking

Employee `socialSecurityNo` (kennitala) = Customer/Vendor/Contact `Registration No.`
→ use to resolve "my company" / "my account" queries.

---

## 6. Notifications & Approvals

Tools: `send_notification`, `get_notifications`, `mark_notifications_read`,
`get_notification_count`, `get_notification_thread`, `get_my_approvals`,
`get_approval_entries`, `send_for_approval`, `approve_entries`,
`reject_entries`, `delegate_approval`, `cancel_approval`.

**Quick patterns:**
- Check unread: `unreadNotifications` from who_am_i → `get_notifications` for full details.
- Thread: send with `threadId`, reply with same `threadId` + `parentEntryNo`.
- Approvals: `pendingApprovals` from who_am_i → `get_my_approvals` → present → approve/reject.

> **Full parameter tables:** Load `references/TOOLS.md` when you need exact parameters.

---

## 7. UBL XML templates

Never write UBL from scratch. Use:
1. `list_ubl_templates()` → discover available templates
2. `render_ubl_template({ templateCode, documentNo, documentType })` → render

Standards: PEPPOL BIS 3.0 (default), BIS 2.0 (legacy), IS BII1 (oldest).

> **Full EndpointID resolution & details:** Load `references/UBL.md` when working with e-invoicing.

---

## 8. Update rules

When you discover a new pattern, bug, or workaround — write to memory immediately:
- Personal → `set_user_memory({ description: "note:<topic>", memory: "..." })`
- Shared (if `canUpdateCompanyMemory`) → `set_company_memory({ ... })`

Skills/prompts: use `skill:` or `prompt:` prefix. No separate index needed — discover via `list_*_memory`.

Promote user → company: get from user, set to company (same description).

---

## 9. Connection format

AES-256-GCM only. `plain:<base64>` is rejected (migration error).

> **Setup scripts & details:** Load `references/SETUP.md` when helping with connection setup.

---

## 10. Single source of truth

Skills and prompts live in the BC database (user/company memory).
Local files describe how to fetch them — they don't store the content.
