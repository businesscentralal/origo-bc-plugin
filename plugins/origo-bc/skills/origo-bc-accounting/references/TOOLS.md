# Tool Reference — Notifications & Approvals

> Loaded on demand. Only read this file when working with notification
> or approval message types for the first time in a session.

All notification and approval operations are invoked via the
`call_message_type` tool. There are no standalone notification/approval
tools any more. Every call has the same shape:

```js
call_message_type({ type: "<Message.Type>", data: { /* fields */ } })
```

The authoritative per-type schema (with current parameter names, defaults
and error messages) is available at runtime via:

```js
get_message_type_help({ type: "<Message.Type>" })
```

When in doubt, call `get_message_type_help` first — it is regenerated
from the server source and never goes stale.

## Notification message types

| Type | Direction | Purpose |
|------|-----------|---------|
| `User.Notification.Send` | Inbound | Send a notification to a BC user |
| `User.Notification.Get` | Outbound | Retrieve notifications for the authenticated user |
| `User.Notification.Read` | Inbound | Mark notifications as read or unread |
| `User.Notification.Count` | Outbound | Get total / unread / read counts |
| `User.Notification.Thread` | Outbound | Retrieve all notifications in a specific thread |

### `User.Notification.Send`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `recipientUserId` | Yes | Code[50] | BC user name of the recipient |
| `subject` | Yes | Text[250] | Subject line |
| `body` | No | Text | Body text (stored in Body blob) |
| `threadId` | No | GUID | Existing thread to append to |
| `parentEntryNo` | Required when `threadId` is set | Integer | Parent entry no. |
| `relatedTableId` | No | Integer | Table ID of the linked record |
| `relatedRecordSystemId` | No | GUID | SystemId of the linked record |
| `notificationType` | No | Text | Name of a `Notification Entry Type` enum value |

Returns the created Cloud Events Note record.

### `User.Notification.Get`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |
| `tableView` | No | Text | BC filter syntax |

Returns notification entries with `entryNo`, `threadId`,
`parentEntryNo`, `recipientUserId`, `senderUserId`, `relatedTableId`,
`relatedRecordSystemId`, `approvalEntryNo`, `subject`, `body`, `isRead`,
`sourceEntrySystemId`, `systemId`, `systemCreatedAt`,
`systemModifiedAt`, `notificationType`.

### `User.Notification.Read`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `entryNos` | Yes | Text | Comma-separated entry numbers |
| `isRead` | No | Boolean | `true` (default) = read, `false` = unread |

### `User.Notification.Count`

No fields. Returns `total`, `unread`, `read`.

### `User.Notification.Thread`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `threadId` | Yes | GUID | Thread to retrieve |
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |

### Notification patterns

- **Check unread:** Use `unreadNotifications` from `who_am_i` for a quick summary, then `User.Notification.Get` for full details.
- **Thread a conversation:** Send with a `threadId` (GUID). Reply with same `threadId` + `parentEntryNo`. Retrieve the whole thread via `User.Notification.Thread`.
- **Acknowledge:** After presenting content, offer to mark as read with `User.Notification.Read`.

---

## Approval message types

| Type | Direction | Purpose |
|------|-----------|---------|
| `Document.Approval.Me` | Outbound | Approvals assigned to me |
| `Document.Approval.Get` | Outbound | Approval log for a specific record |
| `Document.Approval.Send` | Inbound | Submit a record for approval |
| `Document.Approval.Approve` | Inbound | Approve one or more entries |
| `Document.Approval.Reject` | Inbound | Reject one or more entries |
| `Document.Approval.Delegate` | Inbound | Delegate to another user |
| `Document.Approval.Cancel` | Inbound | Cancel a pending approval request |

### `Document.Approval.Me`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |
| `tableView` | No | Text | BC filter syntax |

Returns per entry: `entryNo`, `sequenceNo`, `tableId`, `tableName`,
`tableCaption`, `documentType`, `documentNo`, `recordSystemId`,
`status`, `dueDate`, `amount`, `amountLCY`, `currencyCode`,
`comments[]`, `approvalCode`, `lastModified`,
`linkedApprovalEntries[]`, `linkedPostedApprovalEntries[]`.

### `Document.Approval.Get`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `tableName` | No | Text | Table name (e.g. `Purchase Header`) |
| `tableNumber` | No | Integer | Table ID (e.g. `38`) |
| `recordSystemId` | Yes | GUID | SystemId of the record |
| `skip` | No | Integer | Records to skip |
| `take` | No | Integer | Records to return |
| `tableView` | No | Text | BC filter syntax |

### `Document.Approval.Send`

Requires `canSendAndCancelApprovalRequests = true`.

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `tableName` | No | Text | Table name |
| `tableId` / `tableNumber` | No | Integer | Table ID |
| `recordSystemId` | Yes | GUID | Record to submit |
| `approvals` | No | Array | Explicit chain: `[{ approverUserId, sequenceNo, dueDate, lineNumbers }]` |

When `approvals` is omitted, BC uses the configured workflow.

### `Document.Approval.Approve` / `Document.Approval.Reject`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `entries` | No | Array | `[{ entryNo }]` or `[{ systemId }]` — batch |
| `entryNo` | No | Integer | Single entry |
| `systemId` | No | GUID | Single entry by SystemId |
| `comment` | No | Text | Comment attached to the decision |

Provide either `entries[]` for batch or `entryNo` / `systemId` for a single entry.

### `Document.Approval.Delegate`

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `entries` | No | Array | `[{ entryNo }]` or `[{ systemId }]` — batch |
| `entryNo` | No | Integer | Single entry |
| `systemId` | No | GUID | Single entry by SystemId |
| `delegateToUserId` | Yes | Text | BC user name to delegate to |
| `comment` | No | Text | Comment |

### `Document.Approval.Cancel`

Requires `canSendAndCancelApprovalRequests = true`.

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `tableName` | No | Text | Table name |
| `tableId` / `tableNumber` | No | Integer | Table number |
| `recordSystemId` | Yes | GUID | Record to cancel |

**Document shortcuts** (provide one in place of `recordSystemId`):
- Sales: `orderNo`, `quoteNo`, `invoiceNo`, `creditMemoNo`, `blanketOrderNo`, `returnOrderNo`
- Purchase: same set

### Approval patterns

- **Quick check → drill down:** `pendingApprovals` from `who_am_i` → `Document.Approval.Me` for full details.
- **Approve/reject:** Present details → ask user → call `Document.Approval.Approve` or `Document.Approval.Reject` with optional comment.
- **Delegation:** Use `Document.Approval.Delegate` when the user cannot act (e.g. out of office).
- **Submit:** Use `Document.Approval.Send` with the record's SystemId.

---

## Example calls

```js
// Send a notification
await call_message_type({
  type: "User.Notification.Send",
  data: {
    recipientUserId: "JANE",
    subject: "Please review SO-1023",
    body: "Customer asked about shipping date.",
    relatedTableId: 36,
    relatedRecordSystemId: "a1b2c3d4-...",
  },
});

// Approve a batch
await call_message_type({
  type: "Document.Approval.Approve",
  data: {
    entries: [{ entryNo: 1042 }, { entryNo: 1043 }],
    comment: "Approved per email thread 2026-05-10",
  },
});
```
