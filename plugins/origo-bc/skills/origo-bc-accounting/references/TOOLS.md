# Tool Reference — Notifications & Approvals

> Loaded on demand. Only read this file when working with notification
> or approval tools for the first time in a session.

## Notification tools

| Tool | Direction | Purpose |
|------|-----------|---------|
| `send_notification` | Inbound | Send a notification to a BC user |
| `get_notifications` | Outbound | Retrieve notifications for the authenticated user |
| `mark_notifications_read` | Inbound | Mark notifications as read or unread |
| `get_notification_count` | Outbound | Get total / unread / read counts |
| `get_notification_thread` | Outbound | Retrieve all notifications in a specific thread |

### send_notification

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `recipientUserId` | Yes | String | BC User ID of the recipient |
| `subject` | Yes | String | Subject line |
| `body` | No | String | Body text |
| `threadId` | No | String (GUID) | Groups notifications into a thread |
| `parentEntryNo` | No | Integer | Parent entry (for threaded replies) |
| `relatedTableId` | No | Integer | Table ID of the related record |
| `relatedRecordSystemId` | No | String (GUID) | SystemId of the related record |
| `notificationType` | No | String | `New Record`, `Approval`, or `Overdue` |

Returns the created notification with `entryNo`.

### get_notifications

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |
| `tableView` | No | String | BC filter syntax |

Response fields: `entryNo`, `threadId`, `parentEntryNo`,
`recipientUserId`, `senderUserId`, `relatedTableId`,
`relatedRecordSystemId`, `approvalEntryNo`, `subject`, `body`, `isRead`,
`sourceEntrySystemId`, `systemId`, `systemCreatedAt`,
`systemModifiedAt`, `notificationType`.

### mark_notifications_read

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `entryNos` | Yes | String | Comma-separated entry numbers |
| `isRead` | No | Boolean | `true` = read (default), `false` = unread |

### get_notification_count

No parameters. Returns: `total`, `unread`, `read` counts.

### get_notification_thread

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `threadId` | Yes | String (GUID) | Thread to retrieve |
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |

### Notification patterns

- **Check unread:** Use `unreadNotifications` from `who_am_i` for quick summary. Call `get_notifications` for full details.
- **Thread a conversation:** Send with a `threadId` (GUID). Reply with same `threadId` + `parentEntryNo`. Retrieve with `get_notification_thread`.
- **Acknowledge:** After presenting content, offer to mark as read.

---

## Approval tools

| Tool | Direction | Purpose |
|------|-----------|---------|
| `get_my_approvals` | Outbound | Full details on approvals assigned to me |
| `get_approval_entries` | Outbound | Approval history for a specific record |
| `send_for_approval` | Inbound | Submit a record for approval |
| `approve_entries` | Inbound | Approve one or more entries |
| `reject_entries` | Inbound | Reject one or more entries |
| `delegate_approval` | Inbound | Delegate to another user |
| `cancel_approval` | Inbound | Cancel a pending approval request |

### get_my_approvals

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `skip` | No | Integer | Records to skip (default 0) |
| `take` | No | Integer | Records to return (default 50) |
| `tableView` | No | String | BC filter syntax |

Response per entry: `entryNo`, `sequenceNo`, `tableId`, `tableName`,
`tableCaption`, `documentType`, `documentNo`, `recordSystemId`,
`status`, `dueDate`, `amount`, `amountLCY`, `currencyCode`,
`comments[]`, `approvalCode`, `lastModified`,
`linkedApprovalEntries[]`, `linkedPostedApprovalEntries[]`.

### get_approval_entries

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `tableName` | No | String | Table name (e.g. `Purchase Header`) |
| `tableNumber` | No | Integer | Table ID (e.g. `38`) |
| `recordSystemId` | Yes | String (GUID) | SystemId of the record |
| `skip` | No | Integer | Records to skip |
| `take` | No | Integer | Records to return |
| `tableView` | No | String | BC filter syntax |

### send_for_approval

Requires `canSendAndCancelApprovalRequests = true`.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `tableName` | No | String | Table name |
| `tableId` | No | Integer | Table ID |
| `tableNumber` | No | Integer | Alias for tableId |
| `recordSystemId` | Yes | String (GUID) | Record to submit |
| `approvals` | No | Array | Explicit chain: `[{ approverUserId, sequenceNo, dueDate, lineNumbers }]` |

When `approvals` is omitted, BC uses the configured workflow.

### approve_entries / reject_entries

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `entries` | No | Array | `[{ entryNo }]` or `[{ systemId }]` — batch |
| `entryNo` | No | Integer | Single entry |
| `systemId` | No | String (GUID) | Single entry by SystemId |
| `comment` | No | String | Comment attached to the decision |

Provide either `entries[]` for batch or `entryNo`/`systemId` for single.

### delegate_approval

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `entries` | No | Array | `[{ entryNo }]` or `[{ systemId }]` — batch |
| `entryNo` | No | Integer | Single entry |
| `systemId` | No | String (GUID) | Single entry by SystemId |
| `delegateToUserId` | Yes | String | BC User ID to delegate to |
| `comment` | No | String | Comment |

### cancel_approval

Requires `canSendAndCancelApprovalRequests = true`.

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `tableName` | No | String | Table name |
| `tableId` | No | Integer | Table ID |
| `tableNumber` | No | Integer | Table number |
| `recordSystemId` | Yes | String (GUID) | Record to cancel |

**Document shortcuts** (provide one):
- Sales: `orderNo`, `quoteNo`, `invoiceNo`, `creditMemoNo`, `blanketOrderNo`, `returnOrderNo`
- Purchase: same set

### Approval patterns

- **Quick check → drill down:** `pendingApprovals` from `who_am_i` → `get_my_approvals` for full details.
- **Approve/reject:** Present details → ask user → call `approve_entries` or `reject_entries` with optional comment.
- **Delegation:** Use `delegate_approval` when user cannot act (e.g. out of office).
- **Submit:** Use `send_for_approval` with the record's SystemId.
