# mbc-setup-with-al

AL extension for **Microsoft Dynamics 365 Business Central** that Hevo's Business Central connector
reads from. Install it in each Business Central environment you want to replicate with Hevo.

It does two things:

1. **Exposes your data through read-only API pages** on the route
   `api/hevo/businessCentral/v1.0`, with `systemModifiedAt` on every page so Hevo can sync
   incrementally.
2. **Captures deletes.** Every delete of a row those pages read is recorded (in the same
   transaction) in a per-company feed, so Hevo can mark the row deleted on its next incremental
   sync instead of waiting for a full re-read.

The whole extension is one file, [`src/HevoBusinessCentralConnector.al`](src/HevoBusinessCentralConnector.al),
with its manifest in [`app.json`](app.json).

| | |
|---|---|
| Publisher / name | Hevo Data / Hevo Business Central Connector |
| Version | 1.2.0.0 |
| Target | Business Central online (Cloud), platform and application 28.0+, AL runtime 17.0 |
| Dependencies | none beyond Microsoft's Base and System Application |
| Object IDs | 86500–86649 |
| API route | `https://api.businesscentral.dynamics.com/v2.0/<tenant>/<environment>/api/hevo/businessCentral/v1.0` |

## What it exposes

All pages are company-scoped (`companies(<id>)/<entitySet>`), keyed on `systemId`, and read-only
(`DataAccessIntent = ReadOnly`, no inserts, edits or deletes).

**Data (48 entity sets):** `bankAccounts`, `companyInformation`, `contacts`, `countriesRegions`,
`currencies`, `currencyExchangeRates`, `customers`, `defaultDimensions`, `dimensions`,
`dimensionSetEntries`, `dimensionValues`, `employees`, `generalLedgerAccounts`,
`generalLedgerEntries`, `generalJournalBatches`, `generalJournalLines`,
`generalProductPostingGroups`, `inventoryPostingGroups`, `items`, `itemCategories`,
`itemLedgerEntries`, `itemVariants`, `jobs`, `locations`, `opportunities`, `paymentMethods`,
`paymentTerms`, `postedGeneralJournalBatch`, `postedGeneralJournalLines`,
`purchaseInvoiceHeaders`, `purchaseInvoiceLines`, `purchaseReceiptHeaders`,
`purchaseReceiptLines`, `purchaseHeaders`, `purchaseLines`, `reasonCodes`,
`salesCreditMemoHeaders`, `salesCreditMemoLines`, `salesHeaders`, `salesInvoiceHeaders`,
`salesInvoiceLines`, `salesLines`, `salesShipmentHeaders`, `salesShipmentLines`,
`shipmentMethods`, `timeSheetDetails`, `unitsOfMeasure`, `vendors`.
Companies themselves come from Business Central's built-in `companies` entity.

**Delete capture:**

| Entity set | What it returns |
|---|---|
| `deletedRecords` | One row per deleted record: table no., entity set, the record's `systemId`, when it was deleted, and its original `systemCreatedAt` / `systemModifiedAt`. Deleted companies are recorded too. |
| `integrationStatus` | Per company: extension version, whether capture is on, when it was enabled, and `deletesCompleteFrom` (the point from which the feed holds every delete). |

## Objects

| Object | Purpose |
|---|---|
| pages 86500–86547 | The 48 read-only data API pages |
| page 86600 `Hevo Deleted Records` | `deletedRecords` API page |
| page 86601 `Hevo Integration Setup` | Card page to turn delete capture on or off per company |
| page 86602 `Hevo Integration Status` | `integrationStatus` API page |
| table 86500 `Hevo Deleted Record` | Tombstones, one per captured delete |
| table 86501 `Hevo Integration Setup` | One setup row per company |
| codeunit 86500 `Hevo Delete Subscribers` | `OnAfterDeleteEvent` subscribers for each exposed table |
| codeunit 86501 `Hevo Delete Capture` | Writes tombstones, handles deleted companies, retention |
| codeunits 86502 / 86503 | Install / upgrade: create the setup row and retention policy |
| permission set 86500 `HEVO READ` | What Hevo's user needs |
| permission set 86501 `HEVO ADMIN` | `HEVO READ` plus changing the setup and removing tombstones |

## Install

1. **Build the `.app`.** Open this folder in VS Code with the
   [AL Language extension](https://marketplace.visualstudio.com/items?itemName=ms-dynamics-smb.al),
   run **AL: Download symbols** against a sandbox, then **AL: Package** (`Ctrl+Shift+B`).
   This produces `Hevo Data_Hevo Business Central Connector_1.2.0.0.app`.
2. **Upload it.** In Business Central open **Extension Management → Manage → Upload Extension**,
   choose the `.app`, and deploy it. Try a sandbox environment first.
3. **Grant access.** Assign the `HEVO READ` permission set to the user, or Microsoft Entra
   application, that Hevo authenticates as. Leave the *Company* column blank to cover all
   companies, or add it once per company you want to sync.
4. **Check it.** As that user, call
   `GET …/api/hevo/businessCentral/v1.0/companies` and then one entity set, for example
   `GET …/companies(<id>)/customers?$top=1`. `companies(<id>)/integrationStatus` should return one
   row with `deleteCaptureEnabled = true`.

Upgrading from an earlier version of this extension is done in place by uploading the new `.app`.

## Permissions

| Who | Needs |
|---|---|
| The user / Entra app Hevo signs in as | `HEVO READ` (includes Microsoft's `D365 READ`, because reading a page calculates FlowFields from other tables) |
| Admins who turn delete capture on/off or run the retention job without SUPER | `HEVO ADMIN` |
| Everyone else, including users who delete records | nothing |

The extension stores no credentials, tokens or URLs and makes no outbound HTTP requests.

## Delete capture

- Capture is **on by default** in every company: the setup row is created on install, upgrade and
  when a new company is created. An admin can turn it off per company on the **Hevo Integration
  Setup** page.
- The tombstone is written **inside the deleting transaction**, so a rolled-back delete leaves none
  and a committed delete always has one. Temporary records are ignored.
- Capture **never makes a delete fail**: the tombstone and setup tables grant the needed access to
  every user through inherent permissions.
- **Retention:** the tombstone table is registered with Business Central's Retention Policy
  framework, with a default policy of one month. Admins can change it on the **Retention Policies**
  page; anything purged is reflected in `integrationStatus.deletesCompleteFrom`.

## Known limits

- **Bulk deletes get slower.** While a table has a delete subscriber, Business Central runs
  `DeleteAll` row by row, and each row writes a tombstone. Posting large journals, date compression
  and other bulk deletes on the exposed tables take longer.
- **Uninstalling stops capture.** Reinstalling restarts `deletesCompleteFrom`; uninstalling with
  *Delete Extension Data* removes the tombstones and setup.
- **Obsolete fields are not exposed.** Fields Microsoft has marked for removal (today
  `Customer."Invoice Copies"`) are left out so the extension keeps compiling across major updates.
- **FlowFields** are calculated on read and don't move `systemModifiedAt`.
- **Blob fields** (`picture`, `workDescription`) are OData streams and are not inlined;
  **Media/MediaSet fields** (`image`, item `picture`) return the media ID, not the image.
- **Localisations** that remove a US/W1 Base Application field will fail to compile.

## Object ID conflicts

Two extensions with overlapping object IDs can't be installed in the same environment. This
extension uses 86500–86649, away from the 50000–50999 block most per-tenant extensions use. If your
tenant already uses this range, change `idRanges` in `app.json` and renumber the objects before
building. Note that moving an installed extension to new IDs loses its stored tombstones.
