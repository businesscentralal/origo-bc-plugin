# UBL XML Templates

> Loaded on demand. Only read this file when the user asks about
> electronic invoicing, UBL, or Peppol.

## Tools

| Tool | Purpose |
|------|---------|
| `list_ubl_templates` | Returns available UBL templates with metadata |
| `render_ubl_template` | Renders a UBL document from a posted document |

### render_ubl_template

| Parameter | Required | Description |
|-----------|----------|-------------|
| `templateCode` | Yes | Template code from `list_ubl_templates` |
| `documentNo` | Yes | Posted document number |
| `documentType` | No | `Invoice` (default) or `CreditMemo` |

## Workflow

1. `list_ubl_templates` → pick template by standard/format
2. `render_ubl_template` → returns UBL XML

## EndpointID resolution

How `cac:EndpointID` is populated (by `schemeID`):

| schemeID | Source field | Example |
|----------|-------------|---------|
| `0196` | Customer "Registration No." | `5402696029` |
| `0230` | Customer "VAT Registration No." | `IS108630` |
| `9956` | Customer "Registration No." (BE) | `BE0477472701` |
| `DUNS` | Customer "DUNS No." | `123456789` |
| `GLN` | Customer "GLN No." | `5790000435951` |

## Standards

| Standard | Profile | Use case |
|----------|---------|----------|
| BIS Billing 3.0 | Peppol | EU/EEA cross-border |
| IS-TS-136 | Icelandic TSk | Domestic Iceland |
| TSk 2.0 | TSk domestic | Newer Icelandic format |
