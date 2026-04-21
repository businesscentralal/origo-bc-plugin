---
name: origo-bc-cloud-events
description: >
  This skill should be used when the user mentions Cloud Events, Cloud Events
  API, message types, Data.Records.Get, Data.Records.Set, integration
  timestamps, the Cloud Events delete log, or starts any Cloud Events MCP
  development work. It loads the full authoring rules, message type catalog,
  and examples via the MCP server.
metadata:
  version: "0.1.0"
  author: "Origo hf."
---

# Origo BC — Cloud Events API skill

This is a loader skill. The full Cloud Events API rules, message type catalog,
and authoring examples are hosted at
`https://origopublic.blob.core.windows.net/help/Cloud%20Events/bc27/en-US/SKILL.md`
and served by the MCP tool described below.

## Loading the full skill — `get_cloud_events_api_skill`

**When this skill activates, call `get_cloud_events_api_skill` on the MCP
server to load the Cloud Events authoring rules into the session.**

The full document is large (~140 k chars). The tool supports three retrieval
modes to keep payloads manageable:

| Call | What you get |
|------|-------------|
| `get_cloud_events_api_skill()` | Frontmatter, intro, and a heading-only table of contents (small payload — start here). |
| `get_cloud_events_api_skill({ section: "Data.Records.Get" })` | A single section by heading text (case-insensitive, substring match). |
| `get_cloud_events_api_skill({ full: true })` | The entire document — use only when the full context is truly needed. |

The tool caches the document for 5 minutes. Pass `{ refresh: true }` to
bypass the cache. No BC connection is required — this tool works without
credentials.

**Recommended flow:**
1. Call with no arguments to get the TOC.
2. Load sections on demand as the conversation requires them (e.g.
   `{ section: "Data.Records.Get" }`, `{ section: "Pagination Pattern" }`).
3. Only request `{ full: true }` for broad reviews or cross-cutting tasks.

## What the full skill covers

- Message type catalog (Data.Records.Get/Set, Deleted.Records.Get, etc.)
- Request/response schemas and field-level documentation
- Pagination patterns and batch processing
- Integration timestamp management (`get_integration_timestamp`,
  `set_integration_timestamp`, `reverse_integration_timestamp`)
- Cloud Events Delete Log queries (`get_deleted_records`,
  `get_deleted_record_ids`)
- UBL XML templates and document generation
- Error handling and retry patterns
- Authoring rules for new message types

## Related MCP tools (require BC connection)

These tools are part of the Cloud Events ecosystem and require an active BC
connection:

| Tool | Purpose |
|------|---------|
| `get_records` | Read records via Data.Records.Get |
| `set_records` | Write records via Data.Records.Set |
| `batch_records` | Execute multiple record operations in a single call |
| `get_deleted_records` | Full record snapshots from the Cloud Events Delete Log |
| `get_deleted_record_ids` | Lightweight deleted record ID list for incremental sync |
| `get_integration_timestamp` | Latest non-reversed timestamp for a source + tableId |
| `set_integration_timestamp` | Record a new integration timestamp |
| `reverse_integration_timestamp` | Mark the latest timestamp as reversed |
| `get_item_availability` | Item inventory / projected availability |
| `changelog_field_enabled` | Check Change Log coverage for a field |
