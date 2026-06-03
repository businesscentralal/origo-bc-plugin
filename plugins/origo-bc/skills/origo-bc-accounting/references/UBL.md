# UBL XML Templates

> Loaded on demand. Only read this file when the user asks about
> electronic invoicing, UBL, or Peppol.

## Tools

| Tool | Purpose |
|------|---------|
| `list_ubl_templates` | Returns available UBL templates with metadata (reads from bc-cloud-events-setup) |
| `render_ubl_template` | Renders a UBL document from a template GUID and a data object |

### render_ubl_template

| Parameter | Required | Description |
|-----------|----------|-------------|
| `templateGuid` | Yes | GUID from `list_ubl_templates` |
| `data` | Yes | Object whose keys match `{{placeholder}}` names in the template |
| `embeddings` | No | Array of `{id, description, mimeCode, filename, base64Content}` for AdditionalDocumentReference |

> **Note:** Templates are stored in the `bc-cloud-events-setup` BC environment (Cloud Events Storage,
> source = "UBL Templates"). The tool is a NO-CONN tool — no per-call auth needed.

## Placeholder Syntax

Templates use `{{name|default}}` syntax:
- `{{invoiceNo}}` — required (no default)
- `{{currencyCode|ISK}}` — optional with default ISK
- `{{note|}}` — optional, element stripped if empty

Repeating blocks: `{{#lines}}...{{/lines}}` and `{{#taxSubtotals}}...{{/taxSubtotals}}`

The renderer triggers line repeating via `<!-- Repeat {lineElement} per (?:line )?item -->` comment in the template.
**Bug note:** DespatchAdvice BII1 (008) and BIS 2.0 (017) use `<!-- Repeat DespatchLine per shipped item -->` which
does NOT match the regex — lines don't repeat. Workaround: write XML directly or patch the template comment.

**Statement (007) bug:** Uses `{{#block StatementLine}}...{{/block}}` syntax (non-standard) which is NOT processed
by the renderer. Write Statement XML directly.

## Full Workflow: Invoice/CreditNote into BC Purchases

### Step 1: Render template

```js
const result = await render_ubl_template({ templateGuid: "DDDD0000-0000-0000-0000-000000000001", data: {...} });
const xmlBase64 = Buffer.from(result.xml).toString("base64");
```

### Step 2: Create Incoming Document

```js
await create_incoming_document({ fileName: "SINV-001.xml", fileContent: xmlBase64, vendorName: "...", ... });
// Returns entryNo
```

### Step 3: Process Incoming Document

```js
await process_incoming_document({ entryNo: N });
// Returns processResult.status = "Success" + record (Purchase Header table 38)
```

### Step 4: Approve + Post (if approval workflow active)

```js
await call_message_type({
  type: "Document.Approval.Send",
  data: {
    recordSystemId: "...",
    tableName: "Purchase Header",
    approvals: [{ approverUserId: "USER", sequenceNo: 1 }],
  },
});
await call_message_type({
  type: "Document.Approval.Approve",
  data: { entries: [{ entryNo: N }] },
});
await call_message_type({
  type: "Purchase.Document.Post",
  data: { invoiceNo: "R000XX" },
});
```

### Pre-requisites for successful processing

**Vendor matching:** BC matches incoming XML vendor by:
- **PEPPOL BIS 3.0:** Name + Street Address (text match on Vendor table fields 2+5)
- **IS BII1 / PEPPOL BIS 2.0:** Registration Number / Kennitala (Vendor field 25 = `RegistrationNumber`)

To set kennitala on a vendor: `set_records({ table: "Vendor", mode: "modify", data: [{ primaryKey: { No_: "20000" }, fields: { RegistrationNumber: "6506941229" } }] })`

**Text-to-Account Mapping (table 410):** Required for PEPPOL BIS 3.0 invoices — BC needs a G/L account for each line item.

```js
// Insert (avoids the "default mapping" confirmation dialog):
await set_records({ table: "Text-to-Account Mapping", mode: "insert", data: [{
  primaryKey: { LineNo_: 10000 },
  fields: { MappingText: "Line description text", DebitAcc_No_: "2010", VendorNo_: "20000", oriDef_Mapping: false }
}] });
```

**ori Accounting Cost Mapping (table 10043584):** Required for credit memos (PEPPOL_CRINV_XML). Uses two-step insert due to BC validation:

```js
// Step 1: insert without oriValue (avoids Fixed Asset validation)
await set_records({ table: "ori Accounting Cost Mapping", mode: "insert", data: [{
  primaryKey: { oriLineNo_: 10000 },
  fields: { oriMappingText: "Line description text", oriVendorNo_: "20000",
            oriMappingTypeEnum: "G/L Account",   // ordinal 1
            oriImpMappingFromType: "3. Line Text" // ordinal 2 = Line Description
  }
}] });
// Step 2: set G/L account
await set_records({ table: "ori Accounting Cost Mapping", mode: "modify", data: [{
  primaryKey: { oriLineNo_: 10000 },
  fields: { oriValue: "2010" }
}] });
```

**ori Accounting Cost Mapping — enum values:**
- `oriMappingTypeEnum`: Fixed Asset=0, G/L Account=1, Map To Dimensions Only=2, Item=3, Item Charge=4, Allocation Account=10, Customer=11, Vendor=12
- `oriImpMappingFromType`: Accounting Cost=0, Item No=1, Line Description=2, Default for Vendor=3, Multiple Conditions=4, Contract Doc Ref=5

## PEPPOL BIS 3.0 Invoice — Placeholder Reference (GUID: `DDDD0000-0000-0000-0000-000000000001`)

### Document level
| Placeholder | Required | Example |
|-------------|----------|---------|
| `invoiceNo` | ✓ | `SINV-2026-1001` |
| `issueDate` | ✓ | `2026-04-30` |
| `dueDate` | ✓ | `2026-05-30` |
| `typeCode` | default 380 | `380` |
| `note` | optional | `Prófreikningur` |
| `currencyCode` | default ISK | `ISK` |

### Vendor (AccountingSupplierParty)
| Placeholder | Required | Example |
|-------------|----------|---------|
| `vendorKennitala` | ✓ | `6506941229` |
| `vendorName` | ✓ | `First Up Consultants` |
| `vendorEndpointId` | ✓ | `6506941229` |
| `vendorEndpointSchemeId` | default 0196 | `0196` |
| `vendorAddress` | optional | `Allan Turing Road, 20` |
| `vendorCity` | optional | `Reykjavík` |
| `vendorPostCode` | optional | `108` |
| `vendorCountry` | default IS | `IS` |
| `vendorBankAccount` | optional | `0111-26-012345` |

### Customer (AccountingCustomerParty)
| Placeholder | Required | Example |
|-------------|----------|---------|
| `customerKennitala` | ✓ | `5302922079` |
| `customerName` | ✓ | `Origo Demo` |
| `customerEndpointId` | ✓ | `5302922079` |
| `customerEndpointSchemeId` | default 0196 | `0196` |
| `customerAddress` | optional | `Borgartún 37` |
| `customerCity` | optional | `Reykjavík` |
| `customerPostCode` | optional | `105` |
| `customerCountry` | default IS | `IS` |

### Payment
`paymentMeansCode` — default 30

### TaxTotal
`totalTaxAmount` — required

### taxSubtotals array
`taxableAmount`, `taxSubtotalAmount`, `vatPercent` (default 24)

### LegalMonetaryTotal
`lineExtensionAmount`, `taxExclusiveAmount`, `taxInclusiveAmount`, `payableAmount` — all required

### lines array
| Placeholder | Required | Example |
|-------------|----------|---------|
| `lineNo` | ✓ | `1` |
| `quantity` | ✓ | `5` |
| `unitCode` | default EA | `EA`, `HUR` |
| `lineAmount` | ✓ | `125000` |
| `lineName` | ✓ | `Ráðgjafafjónusta` |
| `lineDescription` | optional | `Forritun og þróun` |
| `lineVatPercent` | default 24 | `24` |
| `unitPrice` | ✓ | `25000` |

## PEPPOL BIS 3.0 CreditNote (GUID: `DDDD0000-0000-0000-0000-000000000002`)

Same placeholders as Invoice except:
- `creditNoteNo` instead of `invoiceNo`
- `originalInvoiceNo` — optional, references original invoice
- `typeCode` default 381, root = CreditNote, lineElement = CreditNoteLine

**Important:** BC requires the original invoice to be POSTED before processing a credit memo against it.

## IS BII1 Invoice (GUID: `DDDD0000-0000-0000-0000-000000000008`)

Key differences from BIS 3.0:
- `vendorVsknr` — IS:VSKNR VAT number
- `bankAccountNo`, `bankBranchNo`, `paymentDueDate` — required
- `taxCategoryId`, `lineTaxCategoryId` — use "S"
- `lineTaxAmount` — per-line tax amount required
- `payableRoundingAmount` — usually "0.00"
- EndpointID schemeID = IS:KT (not 0196)

## IS BII1 CreditNote (GUID: `DDDD0000-0000-0000-0000-000000000009`)

Same as BII1 Invoice but: `creditNoteNo`, `originalInvoiceNo`, CreditNoteLine element.

## PEPPOL BIS 2.0 Invoice (GUID: `DDDD0000-0000-0000-0000-000000000013`)

Same as BII1 but:
- EndpointID schemeID = 9917 (not IS:KT)
- No `listAgencyID`/`listID` on type codes

## PEPPOL BIS 2.0 CreditNote (GUID: `DDDD0000-0000-0000-0000-000000000014`)

Same as BIS 2.0 Invoice but: `creditNoteNo`, `originalInvoiceNo`, CreditNoteLine.

## Order (PEPPOL BIS 3.0: `003`, BII1: `010`, BIS 2.0: `015`)

- `orderNo`, `issueDate`, `currencyCode`
- Buyer = `buyerKennitala`, `buyerName`, `buyerEndpointId`, etc.
- Seller = `sellerKennitala`, `sellerName`, `sellerEndpointId`, etc.
- `deliveryDate` — requested delivery end date
- `lineExtensionAmount`, `taxInclusiveAmount`, `payableAmount`
- lines: `lineNo`, `quantity`, `unitCode`, `lineAmount`, `unitPrice`, `lineName`
- BII1 additionally: `taxAmount`, `lineTaxAmount` per line

## OrderResponse (BIS 3.0: `004`, BIS 2.0: `016`) / OrderResponseSimple (BII1: `011`)

- `responseNo`, `issueDate`, `originalOrderNo`
- `responseCode`: 29=Accepted, 27=Rejected, 30=Conditional (BIS 3.0/2.0)
- `accepted`: true/false (BII1 OrderResponseSimple only)
- Seller and Buyer party info

## DespatchAdvice (BIS 3.0: `006`, BII1: `012`, BIS 2.0: `017`)

- `despatchNo`, `issueDate`, `originalOrderNo`
- Supplier = shipper, Customer = recipient
- `shipmentNo`, `actualShipDate`, delivery address
- lines: `lineNo`, `deliveredQuantity`, `unitCode`, `orderLineNo`/`originalLineNo`, `lineName`/`itemName`

**Template bug:** BII1 (012) and BIS 2.0 (017) use `<!-- Repeat DespatchLine per shipped item -->` comment
which doesn't match the renderer regex. Use BIS 3.0 template or write XML directly.

## Catalogue (BIS 3.0: `005`)

- `catalogueNo`, `issueDate`, `versionId`
- Provider = seller, Receiver = buyer
- lines: `lineNo`, `actionCode` (Add/Update/Delete), `unitCode`, `unitPrice`, `itemName`, `sellerItemNo`, `vatPercent`

## Statement (BIS 3.0 + Origo: `007`)

- `statementNo`, `issueDate`, Supplier and Customer party info
- lines: `lineNo`, `lineDescription`, `debitAmount`/`creditAmount`, `lineDocumentDate`, `lineDocumentNo`, `lineDueDate`
- Totals: `totalDebitAmount`, `totalCreditAmount`, `totalBalanceAmount`

**Template bug:** Uses `{{#block StatementLine}}...{{/block}}` (non-standard) — not processed by renderer.
Write Statement XML directly.

## EndpointID resolution

| schemeID | Source | Use case |
|----------|--------|----------|
| `0196` | Kennitala | PEPPOL BIS 3.0 (default for Iceland) |
| `0088` | GLN (13-char) | Global |
| `9917` | Kennitala | PEPPOL BIS 2.0 network routing |
| `IS:KT` | Kennitala | IS BII1 |

## Icelandic VAT rates

| Percent | Category | Description |
|---------|----------|-------------|
| 24% | S | Standard rate (staðalhlutfall) |
| 11% | S or AA | Reduced rate (lækkað hlutfall) |
| 0% | Z or E | Zero/exempt (undanþága) |

## Processing results (tested 2026-05-06 in Origo Demo)

| Template | GUID | Result in BC |
|----------|------|-------------|
| PEPPOL BIS 3.0 Invoice | 001 | ✅ Creates Purchase Invoice |
| PEPPOL BIS 3.0 CreditNote | 002 | ✅ Creates Purchase Credit Memo |
| IS BII1 Invoice | 008 | ✅ Creates Purchase Invoice |
| IS BII1 CreditNote | 009 | ✅ Creates Purchase Credit Memo |
| PEPPOL BIS 2.0 Invoice | 013 | ✅ Creates Purchase Invoice |
| PEPPOL BIS 2.0 CreditNote | 014 | ✅ Creates Purchase Credit Memo |
| All Orders (003, 010, 015) | — | Stored as Incoming Document (no purchase processing) |
| All DespatchAdvice (006, 012, 017) | — | Stored as Incoming Document |
| OrderResponse (004, 011, 016) | — | Stored as Incoming Document |
| Catalogue (005) | — | Stored as Incoming Document |
| Statement (007) | — | Stored as Incoming Document |
