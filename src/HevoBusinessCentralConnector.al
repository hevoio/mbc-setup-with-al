// Hevo Business Central Connector: the whole extension in one file.
//
// Read-only API pages on the route hevo/businessCentral/v1.0 for the 48 company-scoped objects Hevo's
// Business Central connector syncs (the companies entity is Business Central's own), and delete
// capture: every delete of a row those pages read is recorded as a tombstone in the deleting
// company, inside the deleting transaction, and served by the deletedRecords and integrationStatus
// pages. Capture is on by default in every company: install and upgrade turn it on, and a new
// company is created with it on. Hevo's connector reads deletes from this feed; in a company whose
// capture an admin turns off on the Hevo Integration Setup page, syncs keep running and the connector
// falls back to a weekly full resync of every object to pick up deletes.
//
// Layout: the hand-written delete capture objects first, then the objects generated from
// contract/entities.json by tools/generate_pages.py between the two marker lines. Edit the contract
// (or the generator) and rerun it to change a page; never edit the generated objects by hand.

// CodeCop AA0215 asks for one object per file, named after the object; this extension is one file
// on purpose.
#pragma warning disable AA0215

codeunit 86501 "Hevo Delete Capture"
{
    // Writes tombstones for codeunit "Hevo Delete Subscribers" and for deleted companies, keeps the
    // per-company setup row, and registers the tombstone table with Microsoft's Retention Policy
    // framework.
    Access = Internal;
    Permissions = tabledata "Hevo Deleted Record" = i,
                  tabledata "Hevo Integration Setup" = rim,
                  tabledata "Retention Period" = ri,
                  tabledata "Retention Policy Setup" = rim;

    var
        CompaniesEntitySetTxt: Label 'companies', Locked = true;
        MissedCaptureTxt: Label 'Hevo delete capture: a row of table %1 was deleted without its SystemId loaded, so no tombstone was written. Hevo flags it only at the table''s next complete read (a resync).', Locked = true;

    /// <summary>
    /// Records one deleted row, in the company the row belonged to (a delete made through
    /// ChangeCompany belongs to that company's feed). Called inside the deleting transaction, so a
    /// rolled-back delete leaves no tombstone.
    /// </summary>
    procedure Capture(TableNo: Integer; EntitySetName: Text[50]; RecordCompany: Text; IsTemporary: Boolean; RecordSystemId: Guid; RecordSystemCreatedAt: DateTime; RecordSystemModifiedAt: DateTime)
    var
        DeletedRecord: Record "Hevo Deleted Record";
    begin
        if IsTemporary then
            exit;
        if IsNullGuid(RecordSystemId) then begin
            // Only a record deleted without being read first (key fields set, then Delete) arrives
            // without its SystemId; there is nothing to record, so make the miss visible.
            Session.LogMessage('HEVO-0001', StrSubstNo(MissedCaptureTxt, TableNo), Verbosity::Warning, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, 'TableNo', Format(TableNo));
            exit;
        end;
        if not IsCaptureEnabled(RecordCompany) then
            exit;
        DeletedRecord.Init();
        DeletedRecord."Table No." := TableNo;
        DeletedRecord."Entity Set Name" := EntitySetName;
        DeletedRecord."Record SystemId" := RecordSystemId;
        DeletedRecord."Record SystemCreatedAt" := RecordSystemCreatedAt;
        DeletedRecord."Record SystemModifiedAt" := RecordSystemModifiedAt;
        InsertTombstone(DeletedRecord, RecordCompany);
    end;

    local procedure InsertTombstone(var DeletedRecord: Record "Hevo Deleted Record"; RecordCompany: Text)
    begin
        if IsOtherCompany(RecordCompany) then
            DeletedRecord.ChangeCompany(RecordCompany);
        DeletedRecord."Deleted At" := CurrentDateTime();
        DeletedRecord.Insert();
    end;

    /// <summary>
    /// Records a deleted company in every remaining company's feed, under table Company
    /// (2000000006). The deleted company's own feed is deleted with its data, so its tombstone must
    /// live elsewhere; each remaining company holds a copy, and the connector reads the company
    /// object's deletes from any company it syncs. Inside the deleting transaction, like Capture.
    /// </summary>
    procedure CaptureCompany(var DeletedCompany: Record Company)
    var
        RemainingCompany: Record Company;
    begin
        if DeletedCompany.IsTemporary() then
            exit;
        RemainingCompany.SetFilter(Name, '<>%1', DeletedCompany.Name);
        RemainingCompany.SetLoadFields(Name);
        if RemainingCompany.FindSet() then
            repeat
                CaptureCompanyIn(DeletedCompany, RemainingCompany.Name);
            until RemainingCompany.Next() = 0;
    end;

    /// <summary>
    /// One copy of a deleted company's tombstone, in one remaining company. A fresh record variable
    /// per company, so no ChangeCompany carries over from the previous one. The tombstone carries the
    /// company's name and display name: the connector matches a configured company that no longer
    /// resolves against them.
    /// </summary>
    local procedure CaptureCompanyIn(var DeletedCompany: Record Company; RecordCompany: Text)
    var
        DeletedRecord: Record "Hevo Deleted Record";
    begin
        if not IsCaptureEnabled(RecordCompany) then
            exit;
        DeletedRecord.Init();
        DeletedRecord."Table No." := Database::Company;
        DeletedRecord."Entity Set Name" := CompaniesEntitySetTxt;
        DeletedRecord."Record SystemId" := DeletedCompany.SystemId;
        DeletedRecord."Record SystemCreatedAt" := DeletedCompany.SystemCreatedAt;
        DeletedRecord."Record SystemModifiedAt" := DeletedCompany.SystemModifiedAt;
        DeletedRecord."Deleted Company Name" := DeletedCompany.Name;
        DeletedRecord."Deleted Company Display Name" := DeletedCompany."Display Name";
        InsertTombstone(DeletedRecord, RecordCompany);
    end;

    /// <summary>
    /// Capture is on unless the company's setup row turns it off. A company without a row (created
    /// before this version was installed and never initialized) is captured, and reports no row on
    /// integrationStatus; the connector does not fail that company's syncs because of it.
    /// </summary>
    procedure IsCaptureEnabled(RecordCompany: Text): Boolean
    var
        Setup: Record "Hevo Integration Setup";
    begin
        // Read on every delete, never cached: a session that cached "off" would miss deletes made
        // after an admin turned capture back on, which the feed would then claim to hold.
        if IsOtherCompany(RecordCompany) then
            Setup.ChangeCompany(RecordCompany);
        Setup.SetLoadFields("Delete Capture Enabled");
        if not Setup.Get() then
            exit(true);
        exit(Setup."Delete Capture Enabled");
    end;

    local procedure IsOtherCompany(RecordCompany: Text): Boolean
    begin
        exit((RecordCompany <> '') and (RecordCompany <> CompanyName()));
    end;

    /// <summary>
    /// Creates the company's setup row with capture on, if missing, and turns capture on in an
    /// existing row that has it off: Hevo's connector has no other way to see deletes. Turning it on
    /// restarts the complete-from time, since deletes made while it was off have no tombstone. With
    /// RestartCapture, a row with capture already on restarts its complete-from time too: used on
    /// install, because deletes made while the extension was uninstalled (without deleting its data)
    /// have no tombstone.
    /// </summary>
    procedure EnsureSetup(RestartCapture: Boolean): Boolean
    var
        Setup: Record "Hevo Integration Setup";
    begin
        if Setup.Get() then begin
            if RestartCapture or not Setup."Delete Capture Enabled" then begin
                Setup."Delete Capture Enabled" := true;
                Setup."Capture Enabled At" := CurrentDateTime();
                Setup.Modify();
            end;
            exit(false);
        end;
        Setup.Init();
        Setup."Delete Capture Enabled" := true;
        Setup."Capture Enabled At" := CurrentDateTime();
        Setup.Insert();
        exit(true);
    end;

    /// <summary>Sets up a company: its setup row and, the first time, the default retention policy.</summary>
    procedure InitializeCompany(RestartCapture: Boolean)
    begin
        AddAllowedTable();
        if EnsureSetup(RestartCapture) then
            CreateDefaultRetentionPolicy();
    end;

    /// <summary>
    /// Company creation must never fail because of this extension: a user who may not create the
    /// setup row leaves the company without one, which integrationStatus reports (no row); the
    /// connector's syncs keep running. An admin opening the setup page creates it.
    /// </summary>
    local procedure InitializeCompanyIfPermitted()
    var
        Setup: Record "Hevo Integration Setup";
    begin
        if not Setup.WritePermission() then
            exit;
        InitializeCompany(false);
    end;

    /// <summary>
    /// Allows a retention policy on the tombstone table, filtered on Deleted At, never shorter than a
    /// week (a purge past a pipeline's checkpoint misses those deletes, without failing, until a
    /// Resync). Per company: "Retention Policy Allowed Table" is per company, and registering per
    /// database fails to install (spike 0.1.0.0, 2026-10-14).
    /// </summary>
    procedure AddAllowedTable()
    var
        DeletedRecord: Record "Hevo Deleted Record";
        RetenPolAllowedTables: Codeunit "Reten. Pol. Allowed Tables";
        MinRetentionDays: Integer;
    begin
        MinRetentionDays := 7;
        RetenPolAllowedTables.AddAllowedTable(Database::"Hevo Deleted Record", DeletedRecord.FieldNo("Deleted At"), MinRetentionDays);
    end;

    /// <summary>
    /// A one-month policy on all tombstones, enabled when the installing user can schedule the
    /// retention job, as Microsoft's Base Application does for its own log tables. Created once per
    /// company (with its setup row), so an admin's later change or removal is kept.
    /// </summary>
    local procedure CreateDefaultRetentionPolicy()
    var
        RetentionPolicySetup: Record "Retention Policy Setup";
        RetentionPeriod: Record "Retention Period";
        [SecurityFiltering(SecurityFilter::Ignored)]
        JobQueueEntry: Record "Job Queue Entry";
        RetentionPolicySetupCU: Codeunit "Retention Policy Setup";
    begin
        // A user who may not create policies (install by a non-SUPER admin) gets none rather than a
        // failed install; the README asks admins to check the Retention Policies page.
        if not (RetentionPolicySetup.WritePermission() and RetentionPeriod.WritePermission()) then
            exit;
        if RetentionPolicySetup.Get(Database::"Hevo Deleted Record") then
            exit;
        RetentionPolicySetup.Validate("Table Id", Database::"Hevo Deleted Record");
        RetentionPolicySetup.Validate("Apply to all records", true);
        RetentionPolicySetup.Validate("Retention Period", RetentionPolicySetupCU.FindOrCreateRetentionPeriod(Enum::"Retention Period Enum"::"1 Month"));
        RetentionPolicySetup.Validate(Enabled, false);
        RetentionPolicySetup.Insert(true);

        if not TaskScheduler.CanCreateTask() then
            exit;
        if not (JobQueueEntry.ReadPermission() and JobQueueEntry.WritePermission()) then
            exit;
        if not JobQueueEntry.HasRequiredPermissions() then
            exit;
        RetentionPolicySetup.Validate(Enabled, true);
        RetentionPolicySetup.Modify(true);
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Reten. Pol. Allowed Tables", 'OnRefreshAllowedTables', '', false, false)]
    local procedure AddAllowedTableOnRefreshAllowedTables()
    begin
        AddAllowedTable();
    end;

    // The companies entity is Business Central's own, not a page of this extension, so its subscriber
    // is written here rather than generated with the 48 others. Base Application subscribes to the
    // same event (codeunit "Company-Initialize", OnAfterCompanyDeleteRemoveReferences).
    [EventSubscriber(ObjectType::Table, Database::Company, 'OnAfterDeleteEvent', '', false, false)]
    local procedure CaptureDeletedCompany(var Rec: Record Company; RunTrigger: Boolean)
    begin
        CaptureCompany(Rec);
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Company-Initialize", 'OnCompanyInitialize', '', false, false)]
    local procedure InitializeNewCompany()
    begin
        InitializeCompanyIfPermitted();
    end;

    /// <summary>
    /// Any removed tombstone (the retention policy deletes with DeleteAll(true), row by row while
    /// this subscriber exists) moves Tombstones Purged Through, so the connector can tell a gap from
    /// a quiet period. Without permission to update the setup row the removal fails, rather than
    /// leaving a gap the feed would not report.
    /// </summary>
    [EventSubscriber(ObjectType::Table, Database::"Hevo Deleted Record", 'OnAfterDeleteEvent', '', false, false)]
    local procedure TrackPurgedTombstone(var Rec: Record "Hevo Deleted Record"; RunTrigger: Boolean)
    var
        Setup: Record "Hevo Integration Setup";
    begin
        if Rec.IsTemporary() then
            exit;
        if IsOtherCompany(Rec.CurrentCompany()) then
            Setup.ChangeCompany(Rec.CurrentCompany());
        if not Setup.Get() then
            exit;
        if Rec."Deleted At" <= Setup."Tombstones Purged Through" then
            exit;
        Setup."Tombstones Purged Through" := Rec."Deleted At";
        Setup.Modify();
    end;
}

table 86500 "Hevo Deleted Record"
{
    Caption = 'Hevo Deleted Record', Locked = true;
    DataClassification = SystemMetadata;
    Access = Internal;
    // One row (tombstone) per row deleted from a table a Hevo page reads, written by codeunit
    // "Hevo Delete Capture" in the deleting transaction. Per company (DataPerCompany defaults to
    // true), like the tables it records.
    //
    // Every user who deletes a captured row must be able to write its tombstone, or the delete itself
    // fails: the capture codeunit's Permissions property alone made deletes fail with "TableData ...
    // IndirectInsert" for users without indirect insert (delete-capture spike, S1, 2026-10-13). Insert
    // only: reading needs HEVO READ, deleting (retention) needs HEVO ADMIN or SUPER. The table is
    // Internal and no page can insert, so only this extension's code writes rows.
    InherentPermissions = I;
    InherentEntitlements = I;

    fields
    {
        field(1; "Entry No."; BigInteger)
        {
            Caption = 'Entry No.', Locked = true;
            AutoIncrement = true;
        }
        field(2; "Table No."; Integer)
        {
            Caption = 'Table No.', Locked = true;
        }
        field(3; "Entity Set Name"; Text[50])
        {
            Caption = 'Entity Set Name', Locked = true;
        }
        field(4; "Record SystemId"; Guid)
        {
            Caption = 'Record SystemId', Locked = true;
        }
        field(5; "Deleted At"; DateTime)
        {
            Caption = 'Deleted At', Locked = true;
        }
        // The deleted row's SystemCreatedAt: a row created after the connector's last read of its
        // table was never loaded, so the connector can skip its tombstone instead of loading a row
        // with only a key (a hollow delete for a key the destination lacks inserts such a row; spike,
        // connector side, 2026-10-14).
        field(6; "Record SystemCreatedAt"; DateTime)
        {
            Caption = 'Record SystemCreatedAt', Locked = true;
        }
        field(7; "Record SystemModifiedAt"; DateTime)
        {
            Caption = 'Record SystemModifiedAt', Locked = true;
        }
        // Set only for a deleted company (Table No. 2000000006): a pipeline configures companies by
        // name or display name, and once the company is gone no lookup returns its id, so the
        // connector matches the configured name here to tell a deleted company from a mistyped or
        // renamed one.
        field(8; "Deleted Company Name"; Text[30])
        {
            Caption = 'Deleted Company Name', Locked = true;
        }
        field(9; "Deleted Company Display Name"; Text[250])
        {
            Caption = 'Deleted Company Display Name', Locked = true;
        }
    }

    keys
    {
        key(PK; "Entry No.")
        {
            Clustered = true;
        }
        // The connector reads one table's tombstones changed since its marker.
        key(TableModified; "Table No.", SystemModifiedAt) { }
        // Retention filters on Deleted At.
        key(DeletedAt; "Deleted At") { }
    }
}

page 86600 "Hevo Deleted Records"
{
    // The tombstone feed the connector reads after each incremental, on the same route as the data
    // pages: companies({id})/deletedRecords?$filter=tableId eq <n> and systemModifiedAt gt <marker>.
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'deletedRecord';
    EntitySetName = 'deletedRecords';
    Caption = 'deletedRecords', Locked = true;
    SourceTable = "Hevo Deleted Record";
    ODataKeyFields = SystemId;
    // Asks for the primary database, where a tombstone is visible as soon as its delete commits. A
    // request header Data-Access-Intent: ReadOnly overrides this and reads a replica, which can lag;
    // the connector's 5-minute overlap on its marker covers that.
    DataAccessIntent = ReadWrite;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field(systemId; Rec.SystemId) { }
                field(entryNo; Rec."Entry No.") { }
                field(tableId; Rec."Table No.") { }
                field(entitySetName; Rec."Entity Set Name") { }
                field(recordSystemId; Rec."Record SystemId") { }
                field(deletedAt; Rec."Deleted At") { }
                field(recordSystemCreatedAt; Rec."Record SystemCreatedAt") { }
                field(recordSystemModifiedAt; Rec."Record SystemModifiedAt") { }
                field(deletedCompanyName; Rec."Deleted Company Name") { }
                field(deletedCompanyDisplayName; Rec."Deleted Company Display Name") { }
                field(systemCreatedAt; Rec.SystemCreatedAt) { }
                field(systemModifiedAt; Rec.SystemModifiedAt) { }
            }
        }
    }
}

table 86501 "Hevo Integration Setup"
{
    Caption = 'Hevo Integration Setup';
    DataClassification = SystemMetadata;
    Access = Internal;
    // Every deleting user's session reads this row to know whether capture is on; without read
    // permission the delete itself would fail (see table "Hevo Deleted Record"). Read only: the row
    // holds a flag and timestamps, and changing it needs HEVO ADMIN or SUPER.
    InherentPermissions = R;
    InherentEntitlements = R;

    fields
    {
        field(1; "Primary Key"; Code[10])
        {
            Caption = 'Primary Key', Locked = true;
        }
        field(2; "Delete Capture Enabled"; Boolean)
        {
            Caption = 'Delete Capture Enabled';
            InitValue = true;

            trigger OnValidate()
            begin
                // Deletes made while capture was off have no tombstone, so the feed is complete only
                // from the moment it is turned back on.
                if Rec."Delete Capture Enabled" and not xRec."Delete Capture Enabled" then
                    Rec."Capture Enabled At" := CurrentDateTime();
            end;
        }
        // The feed has a tombstone for every captured delete since this time (install, reinstall, or
        // capture last turned on).
        field(3; "Capture Enabled At"; DateTime)
        {
            Caption = 'Capture Enabled At';
            Editable = false;
        }
        // The newest Deleted At of any tombstone removed (by the retention policy or anyone else):
        // tombstones up to this time may be missing from the feed.
        field(4; "Tombstones Purged Through"; DateTime)
        {
            Caption = 'Tombstones Purged Through';
            Editable = false;
        }
    }

    keys
    {
        key(PK; "Primary Key")
        {
            Clustered = true;
        }
    }

    /// <summary>
    /// The time from which the feed holds every captured delete: the later of Capture Enabled At and
    /// Tombstones Purged Through; blank when capture is off or the start is unknown.
    /// </summary>
    procedure DeletesCompleteFrom(): DateTime
    begin
        if not Rec."Delete Capture Enabled" or (Rec."Capture Enabled At" = 0DT) then
            exit(0DT);
        if Rec."Tombstones Purged Through" > Rec."Capture Enabled At" then
            exit(Rec."Tombstones Purged Through");
        exit(Rec."Capture Enabled At");
    end;
}

page 86601 "Hevo Integration Setup"
{
    Caption = 'Hevo Integration Setup';
    PageType = Card;
    ApplicationArea = All;
    UsageCategory = Administration;
    SourceTable = "Hevo Integration Setup";
    InsertAllowed = false;
    DeleteAllowed = false;

    layout
    {
        area(Content)
        {
            group(Capture)
            {
                Caption = 'Delete capture';

                field("Delete Capture Enabled"; Rec."Delete Capture Enabled")
                {
                    ToolTip = 'Specifies whether deleted records are recorded for Hevo. On by default. Hevo reads this company''s deleted records from here. While it is off, Hevo pipelines that sync this company keep running, and Hevo runs a weekly full resync of every object to pick up deleted records.';
                }
                field("Capture Enabled At"; Rec."Capture Enabled At")
                {
                    ToolTip = 'Specifies when delete capture was last turned on in this company.';
                }
                field("Tombstones Purged Through"; Rec."Tombstones Purged Through")
                {
                    ToolTip = 'Specifies the newest deletion whose record was removed by the retention policy. Hevo reads a table in full if it has not synced since then.';
                }
            }
        }
    }

    trigger OnOpenPage()
    var
        DeleteCapture: Codeunit "Hevo Delete Capture";
    begin
        // Only a company that has no row yet (never initialized) is set up here.
        if not Rec.Get() then begin
            DeleteCapture.InitializeCompany(false);
            Rec.Get();
        end;
    end;
}

page 86602 "Hevo Integration Status"
{
    // One row per company that has a setup row. The connector trusts a company's tombstone feed only
    // from deletesCompleteFrom: with a checkpoint older than it the object's earlier deletes are
    // missed, without failing, until a Resync. No row (extension 1.1, or a company never initialized)
    // does not fail the company's sync, and capture off does not either: the connector runs a weekly
    // full resync of every object instead.
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'integrationStatus';
    EntitySetName = 'integrationStatus';
    Caption = 'integrationStatus', Locked = true;
    SourceTable = "Hevo Integration Setup";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadWrite;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field(systemId; Rec.SystemId) { }
                field(extensionVersion; ExtensionVersion) { }
                field(deleteCaptureEnabled; Rec."Delete Capture Enabled") { }
                field(captureEnabledAt; Rec."Capture Enabled At") { }
                field(tombstonesPurgedThrough; Rec."Tombstones Purged Through") { }
                field(deletesCompleteFrom; DeletesCompleteFrom) { }
                field(systemModifiedAt; Rec.SystemModifiedAt) { }
            }
        }
    }

    var
        ExtensionVersion: Text[30];
        DeletesCompleteFrom: DateTime;

    trigger OnAfterGetRecord()
    var
        ModuleInfo: ModuleInfo;
    begin
        NavApp.GetCurrentModuleInfo(ModuleInfo);
        ExtensionVersion := CopyStr(Format(ModuleInfo.AppVersion()), 1, MaxStrLen(ExtensionVersion));
        DeletesCompleteFrom := Rec.DeletesCompleteFrom();
    end;
}

codeunit 86502 "Hevo Install"
{
    Subtype = Install;
    Access = Internal;

    trigger OnInstallAppPerCompany()
    var
        DeleteCapture: Codeunit "Hevo Delete Capture";
    begin
        // Turns capture on. A reinstall after an uninstall that kept the data restarts the feed's
        // complete-from time: deletes made in between have no tombstone. No business data is read
        // or changed.
        DeleteCapture.InitializeCompany(true);
    end;
}

codeunit 86503 "Hevo Upgrade"
{
    Subtype = Upgrade;
    Access = Internal;

    trigger OnUpgradePerCompany()
    var
        DeleteCapture: Codeunit "Hevo Delete Capture";
    begin
        // From 1.1.0.0 (no capture): create the setup row, capture on from now, and the default
        // retention policy. From 1.2.0.0 or later: keep a row with capture on as it is, so the feed
        // stays complete; turn capture back on in a row that has it off (complete from now).
        // Idempotent; no business data is read or changed.
        DeleteCapture.InitializeCompany(false);
    end;
}

permissionset 86501 "HEVO ADMIN"
{
    Assignable = true;
    Caption = 'Hevo connector administration', Locked = true;
    IncludedPermissionSets = "HEVO READ";
    // Turn delete capture on or off, and let the retention job (when run by a user without SUPER)
    // remove tombstones and record that it did.
    Permissions =
        tabledata "Hevo Integration Setup" = RIM,
        tabledata "Hevo Deleted Record" = RD,
        page "Hevo Integration Setup" = X;
}

// ---- Generated by al-extension/tools/generate_pages.py from contract/entities.json. Do not edit by hand below this line. ----

permissionset 86500 "HEVO READ"
{
    Assignable = true;
    Caption = 'Hevo connector read access', Locked = true;
    // Reading a page also calculates its FlowFields, which reads other tables (a customer's balance
    // reads its ledger entries), so the business data itself is granted through D365 READ.
    IncludedPermissionSets = "D365 READ";
    Permissions =
        page "Hevo BankAccount" = X,
        page "Hevo CompanyInformation" = X,
        page "Hevo Contact" = X,
        page "Hevo CountryRegion" = X,
        page "Hevo Currency" = X,
        page "Hevo CurrencyExchangeRate" = X,
        page "Hevo Customer" = X,
        page "Hevo DefaultDimension" = X,
        page "Hevo Dimension" = X,
        page "Hevo DimensionSetEntry" = X,
        page "Hevo DimensionValue" = X,
        page "Hevo Employee" = X,
        page "Hevo GLAccount" = X,
        page "Hevo GLEntry" = X,
        page "Hevo GenJournalBatch" = X,
        page "Hevo GenJournalLine" = X,
        page "Hevo GenProductPostingGroup" = X,
        page "Hevo InventoryPostingGroup" = X,
        page "Hevo Item" = X,
        page "Hevo ItemCategory" = X,
        page "Hevo ItemLedgerEntry" = X,
        page "Hevo ItemVariant" = X,
        page "Hevo Job" = X,
        page "Hevo Location" = X,
        page "Hevo Opportunity" = X,
        page "Hevo PaymentMethod" = X,
        page "Hevo PaymentTerms" = X,
        page "Hevo PostedGenJournalBatch" = X,
        page "Hevo PostedGenJournalLine" = X,
        page "Hevo PurchInvHeader" = X,
        page "Hevo PurchInvLine" = X,
        page "Hevo PurchRcptHeader" = X,
        page "Hevo PurchRcptLine" = X,
        page "Hevo PurchaseHeader" = X,
        page "Hevo PurchaseLine" = X,
        page "Hevo ReasonCode" = X,
        page "Hevo SalesCrMemoHeader" = X,
        page "Hevo SalesCrMemoLine" = X,
        page "Hevo SalesHeader" = X,
        page "Hevo SalesInvoiceHeader" = X,
        page "Hevo SalesInvoiceLine" = X,
        page "Hevo SalesLine" = X,
        page "Hevo SalesShipmentHeader" = X,
        page "Hevo SalesShipmentLine" = X,
        page "Hevo ShipmentMethod" = X,
        page "Hevo TimeSheetDetail" = X,
        page "Hevo UnitOfMeasure" = X,
        page "Hevo Vendor" = X,
        tabledata "Hevo Deleted Record" = R,
        tabledata "Hevo Integration Setup" = R,
        page "Hevo Deleted Records" = X,
        page "Hevo Integration Status" = X;
}

page 86500 "Hevo BankAccount"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'bankAccount';
    EntitySetName = 'bankAccounts';
    Caption = 'bankAccounts', Locked = true;
    SourceTable = "Bank Account";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("address"; Rec."Address") { }
                field("address2"; Rec."Address 2") { }
                field("amount"; Rec."Amount") { }
                field("automaticStmtImportEnabled"; Rec."Automatic Stmt. Import Enabled") { }
                field("balance"; Rec."Balance") { }
                field("balanceLCY"; Rec."Balance (LCY)") { }
                field("balanceLastStatement"; Rec."Balance Last Statement") { }
                field("balanceAtDate"; Rec."Balance at Date") { }
                field("balanceAtDateLCY"; Rec."Balance at Date (LCY)") { }
                field("bankAccPostingGroup"; Rec."Bank Acc. Posting Group") { }
                field("bankAccountNo"; Rec."Bank Account No.") { }
                field("bankBranchNo"; Rec."Bank Branch No.") { }
                field("bankClearingCode"; Rec."Bank Clearing Code") { }
                field("bankClearingStandard"; Rec."Bank Clearing Standard") { }
                field("bankStatementImportFormat"; Rec."Bank Statement Import Format") { }
                field("bankStmtServiceRecordID"; Rec."Bank Stmt. Service Record ID") { }
                field("blocked"; Rec."Blocked") { }
                field("chainName"; Rec."Chain Name") { }
                field("checkReportID"; Rec."Check Report ID") { }
                field("checkReportName"; Rec."Check Report Name") { }
                field("city"; Rec."City") { }
                field("comment"; Rec."Comment") { }
                field("contact"; Rec."Contact") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("county"; Rec."County") { }
                field("creditAmount"; Rec."Credit Amount") { }
                field("creditAmountLCY"; Rec."Credit Amount (LCY)") { }
                field("creditTransferMsgNos"; Rec."Credit Transfer Msg. Nos.") { }
                field("creditorNo"; Rec."Creditor No.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("debitAmount"; Rec."Debit Amount") { }
                field("debitAmountLCY"; Rec."Debit Amount (LCY)") { }
                field("directDebitMsgNos"; Rec."Direct Debit Msg. Nos.") { }
                field("disableAutomaticPmtMatching"; Rec."Disable Automatic Pmt Matching") { }
                field("eMail"; Rec."E-Mail") { }
                field("faxNo"; Rec."Fax No.") { }
                field("formatRegion"; Rec."Format Region") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("iban"; Rec."IBAN") { }
                field("image"; Rec."Image") { }
                field("intercompanyEnable"; Rec."IntercompanyEnable") { }
                field("languageCode"; Rec."Language Code") { }
                field("lastCheckNo"; Rec."Last Check No.") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastPaymentStatementNo"; Rec."Last Payment Statement No.") { }
                field("lastStatementNo"; Rec."Last Statement No.") { }
                field("matchToleranceType"; Rec."Match Tolerance Type") { }
                field("matchToleranceValue"; Rec."Match Tolerance Value") { }
                field("minBalance"; Rec."Min. Balance") { }
                field("mobilePhoneNo"; Rec."Mobile Phone No.") { }
                field("name"; Rec."Name") { }
                field("name2"; Rec."Name 2") { }
                field("netChange"; Rec."Net Change") { }
                field("netChangeLCY"; Rec."Net Change (LCY)") { }
                field("no"; Rec."No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("ourContactCode"; Rec."Our Contact Code") { }
                field("paymentExportFormat"; Rec."Payment Export Format") { }
                field("phoneNo"; Rec."Phone No.") { }
                field("pmtRecNoSeries"; Rec."Pmt. Rec. No. Series") { }
                field("positivePayExportCode"; Rec."Positive Pay Export Code") { }
                field("postCode"; Rec."Post Code") { }
                field("sepaDirectDebitExpFormat"; Rec."SEPA Direct Debit Exp. Format") { }
                field("swiftCode"; Rec."SWIFT Code") { }
                field("searchName"; Rec."Search Name") { }
                field("statisticsGroup"; Rec."Statistics Group") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("telexAnswerBack"; Rec."Telex Answer Back") { }
                field("telexNo"; Rec."Telex No.") { }
                field("territoryCode"; Rec."Territory Code") { }
                field("totalOnChecks"; Rec."Total on Checks") { }
                field("transactionImportTimespan"; Rec."Transaction Import Timespan") { }
                field("transitNo"; Rec."Transit No.") { }
                field("useAsDefaultForCurrency"; Rec."Use as Default for Currency") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("globalDimension1Filter"; Rec."Global Dimension 1 Filter") { }
                field("globalDimension2Filter"; Rec."Global Dimension 2 Filter") { }
            }
        }
    }
}

page 86501 "Hevo CompanyInformation"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'companyInformation';
    EntitySetName = 'companyInformation';
    Caption = 'companyInformation', Locked = true;
    SourceTable = "Company Information";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("address"; Rec."Address") { }
                field("address2"; Rec."Address 2") { }
                field("allowBlankPaymentInfo"; Rec."Allow Blank Payment Info.") { }
                field("alternativeLanguageCode"; Rec."Alternative Language Code") { }
                field("bankAccountNo"; Rec."Bank Account No.") { }
                field("bankBranchNo"; Rec."Bank Branch No.") { }
                field("bankName"; Rec."Bank Name") { }
                field("baseCalendarCode"; Rec."Base Calendar Code") { }
                field("brandColorCode"; Rec."Brand Color Code") { }
                field("brandColorValue"; Rec."Brand Color Value") { }
                field("calConvergenceTimeFrame"; Rec."Cal. Convergence Time Frame") { }
                field("checkAvailPeriodCalc"; Rec."Check-Avail. Period Calc.") { }
                field("checkAvailTimeBucket"; Rec."Check-Avail. Time Bucket") { }
                field("city"; Rec."City") { }
                field("contactPerson"; Rec."Contact Person") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("county"; Rec."County") { }
                field("createdDateTime"; Rec."Created DateTime") { }
                field("customSystemIndicatorText"; Rec."Custom System Indicator Text") { }
                field("customsPermitDate"; Rec."Customs Permit Date") { }
                field("customsPermitNo"; Rec."Customs Permit No.") { }
                field("demoCompany"; Rec."Demo Company") { }
                field("eMail"; Rec."E-Mail") { }
                field("eoriNumber"; Rec."EORI Number") { }
                field("faxNo"; Rec."Fax No.") { }
                field("gln"; Rec."GLN") { }
                field("giroNo"; Rec."Giro No.") { }
                field("iban"; Rec."IBAN") { }
                field("industrialClassification"; Rec."Industrial Classification") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("locationCode"; Rec."Location Code") { }
                field("name"; Rec."Name") { }
                field("name2"; Rec."Name 2") { }
                field("paymentRoutingNo"; Rec."Payment Routing No.") { }
                field("phoneNo"; Rec."Phone No.") { }
                field("phoneNo2"; Rec."Phone No. 2") { }
                field("picture"; Rec."Picture") { }
                field("pictureLastModDateTime"; Rec."Picture - Last Mod. Date Time") { }
                field("postCode"; Rec."Post Code") { }
                field("primaryKey"; Rec."Primary Key") { }
                field("registrationNo"; Rec."Registration No.") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("swiftCode"; Rec."SWIFT Code") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("systemIndicator"; Rec."System Indicator") { }
                field("systemIndicatorStyle"; Rec."System Indicator Style") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("telexAnswerBack"; Rec."Telex Answer Back") { }
                field("telexNo"; Rec."Telex No.") { }
                field("useGLNInElectronicDocument"; Rec."Use GLN in Electronic Document") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
            }
        }
    }
}

page 86502 "Hevo Contact"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'contact';
    EntitySetName = 'contacts';
    Caption = 'contacts', Locked = true;
    SourceTable = "Contact";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("address"; Rec."Address") { }
                field("address2"; Rec."Address 2") { }
                field("calcdCurrentValueLCY"; Rec."Calcd. Current Value (LCY)") { }
                field("city"; Rec."City") { }
                field("comment"; Rec."Comment") { }
                field("companyName"; Rec."Company Name") { }
                field("companyNo"; Rec."Company No.") { }
                field("contactBusinessRelation"; Rec."Contact Business Relation") { }
                field("correspondenceType"; Rec."Correspondence Type") { }
                field("costLCY"; Rec."Cost (LCY)") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("county"; Rec."County") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("dateOfLastInteraction"; Rec."Date of Last Interaction") { }
                field("durationMin"; Rec."Duration (Min.)") { }
                field("eMail"; Rec."E-Mail") { }
                field("eMail2"; Rec."E-Mail 2") { }
                field("estimatedValueLCY"; Rec."Estimated Value (LCY)") { }
                field("excludeFromSegment"; Rec."Exclude from Segment") { }
                field("extensionNo"; Rec."Extension No.") { }
                field("externalID"; Rec."External ID") { }
                field("faxNo"; Rec."Fax No.") { }
                field("firstName"; Rec."First Name") { }
                field("formatRegion"; Rec."Format Region") { }
                field("image"; Rec."Image") { }
                field("initials"; Rec."Initials") { }
                field("jobTitle"; Rec."Job Title") { }
                field("languageCode"; Rec."Language Code") { }
                field("lastDateAttempted"; Rec."Last Date Attempted") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastTimeModified"; Rec."Last Time Modified") { }
                field("lookupContactNo"; Rec."Lookup Contact No.") { }
                field("middleName"; Rec."Middle Name") { }
                field("minor"; Rec."Minor") { }
                field("mobilePhoneNo"; Rec."Mobile Phone No.") { }
                field("name"; Rec."Name") { }
                field("name2"; Rec."Name 2") { }
                field("nextTaskDate"; Rec."Next Task Date") { }
                field("no"; Rec."No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("noOfBusinessRelations"; Rec."No. of Business Relations") { }
                field("noOfIndustryGroups"; Rec."No. of Industry Groups") { }
                field("noOfInteractions"; Rec."No. of Interactions") { }
                field("noOfJobResponsibilities"; Rec."No. of Job Responsibilities") { }
                field("noOfMailingGroups"; Rec."No. of Mailing Groups") { }
                field("noOfOpportunities"; Rec."No. of Opportunities") { }
                field("opportunityEntryExists"; Rec."Opportunity Entry Exists") { }
                field("organizationalLevelCode"; Rec."Organizational Level Code") { }
                field("pager"; Rec."Pager") { }
                field("parentalConsentReceived"; Rec."Parental Consent Received") { }
                field("phoneNo"; Rec."Phone No.") { }
                field("postCode"; Rec."Post Code") { }
                field("privacyBlocked"; Rec."Privacy Blocked") { }
                field("registrationNumber"; Rec."Registration Number") { }
                field("salespersonCode"; Rec."Salesperson Code") { }
                field("salutationCode"; Rec."Salutation Code") { }
                field("searchEMail"; Rec."Search E-Mail") { }
                field("searchName"; Rec."Search Name") { }
                field("surname"; Rec."Surname") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taskEntryExists"; Rec."Task Entry Exists") { }
                field("telexAnswerBack"; Rec."Telex Answer Back") { }
                field("telexNo"; Rec."Telex No.") { }
                field("territoryCode"; Rec."Territory Code") { }
                field("type"; Rec."Type") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("xrmId"; Rec."Xrm Id") { }
                field("actionTakenFilter"; Rec."Action Taken Filter") { }
                field("calcdCurrentValueFilter"; Rec."Calcd. Current Value Filter") { }
                field("campaignFilter"; Rec."Campaign Filter") { }
                field("chancesOfSuccessFilter"; Rec."Chances of Success % Filter") { }
                field("closeOpportunityFilter"; Rec."Close Opportunity Filter") { }
                field("completedFilter"; Rec."Completed % Filter") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("estimatedValueFilter"; Rec."Estimated Value Filter") { }
                field("jobResponsibilityFilter"; Rec."Job Responsibility Filter") { }
                field("priorityFilter"; Rec."Priority Filter") { }
                field("probabilityFilter"; Rec."Probability % Filter") { }
                field("salesCycleFilter"; Rec."Sales Cycle Filter") { }
                field("salesCycleStageFilter"; Rec."Sales Cycle Stage Filter") { }
                field("salespersonFilter"; Rec."Salesperson Filter") { }
                field("taskClosedFilter"; Rec."Task Closed Filter") { }
                field("taskStatusFilter"; Rec."Task Status Filter") { }
                field("teamFilter"; Rec."Team Filter") { }
            }
        }
    }
}

page 86503 "Hevo CountryRegion"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'countryRegion';
    EntitySetName = 'countriesRegions';
    Caption = 'countriesRegions', Locked = true;
    SourceTable = "Country/Region";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("addressFormat"; Rec."Address Format") { }
                field("code"; Rec."Code") { }
                field("contactAddressFormat"; Rec."Contact Address Format") { }
                field("countyName"; Rec."County Name") { }
                field("euCountryRegionCode"; Rec."EU Country/Region Code") { }
                field("isoCode"; Rec."ISO Code") { }
                field("isoNumericCode"; Rec."ISO Numeric Code") { }
                field("intrastatCode"; Rec."Intrastat Code") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("name"; Rec."Name") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("vatScheme"; Rec."VAT Scheme") { }
            }
        }
    }
}

page 86504 "Hevo Currency"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'currency';
    EntitySetName = 'currencies';
    Caption = 'currencies', Locked = true;
    SourceTable = "Currency";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("amountDecimalPlaces"; Rec."Amount Decimal Places") { }
                field("amountRoundingPrecision"; Rec."Amount Rounding Precision") { }
                field("applnRoundingPrecision"; Rec."Appln. Rounding Precision") { }
                field("code"; Rec."Code") { }
                field("convLCYRndgCreditAcc"; Rec."Conv. LCY Rndg. Credit Acc.") { }
                field("convLCYRndgDebitAcc"; Rec."Conv. LCY Rndg. Debit Acc.") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("custLedgEntriesInFilter"; Rec."Cust. Ledg. Entries in Filter") { }
                field("customerBalance"; Rec."Customer Balance") { }
                field("customerBalanceLCY"; Rec."Customer Balance (LCY)") { }
                field("customerBalanceDue"; Rec."Customer Balance Due") { }
                field("customerOutstandingOrders"; Rec."Customer Outstanding Orders") { }
                field("customerShippedNotInvoiced"; Rec."Customer Shipped Not Invoiced") { }
                field("description"; Rec."Description") { }
                field("emuCurrency"; Rec."EMU Currency") { }
                field("isoCode"; Rec."ISO Code") { }
                field("isoNumericCode"; Rec."ISO Numeric Code") { }
                field("invoiceRoundingPrecision"; Rec."Invoice Rounding Precision") { }
                field("invoiceRoundingType"; Rec."Invoice Rounding Type") { }
                field("lastDateAdjusted"; Rec."Last Date Adjusted") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("maxPaymentToleranceAmount"; Rec."Max. Payment Tolerance Amount") { }
                field("maxVATDifferenceAllowed"; Rec."Max. VAT Difference Allowed") { }
                field("paymentTolerance"; Rec."Payment Tolerance %") { }
                field("realizedGLGainsAccount"; Rec."Realized G/L Gains Account") { }
                field("realizedGLLossesAccount"; Rec."Realized G/L Losses Account") { }
                field("realizedGainsAcc"; Rec."Realized Gains Acc.") { }
                field("realizedLossesAcc"; Rec."Realized Losses Acc.") { }
                field("residualGainsAccount"; Rec."Residual Gains Account") { }
                field("residualLossesAccount"; Rec."Residual Losses Account") { }
                field("symbol"; Rec."Symbol") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("unitAmountDecimalPlaces"; Rec."Unit-Amount Decimal Places") { }
                field("unitAmountRoundingPrecision"; Rec."Unit-Amount Rounding Precision") { }
                field("unrealizedGainsAcc"; Rec."Unrealized Gains Acc.") { }
                field("unrealizedLossesAcc"; Rec."Unrealized Losses Acc.") { }
                field("vatRoundingType"; Rec."VAT Rounding Type") { }
                field("vendorAmtRcdNotInvoiced"; Rec."Vendor Amt. Rcd. Not Invoiced") { }
                field("vendorBalance"; Rec."Vendor Balance") { }
                field("vendorBalanceLCY"; Rec."Vendor Balance (LCY)") { }
                field("vendorBalanceDue"; Rec."Vendor Balance Due") { }
                field("vendorLedgEntriesInFilter"; Rec."Vendor Ledg. Entries in Filter") { }
                field("vendorOutstandingOrders"; Rec."Vendor Outstanding Orders") { }
            }
        }
    }
}

page 86505 "Hevo CurrencyExchangeRate"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'currencyExchangeRate';
    EntitySetName = 'currencyExchangeRates';
    Caption = 'currencyExchangeRates', Locked = true;
    SourceTable = "Currency Exchange Rate";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("adjustmentExchRateAmount"; Rec."Adjustment Exch. Rate Amount") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("exchangeRateAmount"; Rec."Exchange Rate Amount") { }
                field("fixExchangeRateAmount"; Rec."Fix Exchange Rate Amount") { }
                field("relationalAdjmtExchRateAmt"; Rec."Relational Adjmt Exch Rate Amt") { }
                field("relationalCurrencyCode"; Rec."Relational Currency Code") { }
                field("relationalExchRateAmount"; Rec."Relational Exch. Rate Amount") { }
                field("startingDate"; Rec."Starting Date") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

// Not bound: invoiceCopies ("Invoice Copies"), marked for removal by Microsoft (tag 27.0). The connector loads it as NULL on this route.
page 86506 "Hevo Customer"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'customer';
    EntitySetName = 'customers';
    Caption = 'customers', Locked = true;
    SourceTable = "Customer";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("address"; Rec."Address") { }
                field("address2"; Rec."Address 2") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("allowMultiplePostingGroups"; Rec."Allow Multiple Posting Groups") { }
                field("amount"; Rec."Amount") { }
                field("applicationMethod"; Rec."Application Method") { }
                field("balance"; Rec."Balance") { }
                field("balanceLCY"; Rec."Balance (LCY)") { }
                field("balanceDue"; Rec."Balance Due") { }
                field("balanceDueLCY"; Rec."Balance Due (LCY)") { }
                field("baseCalendarCode"; Rec."Base Calendar Code") { }
                field("billToNoOfBlanketOrders"; Rec."Bill-To No. of Blanket Orders") { }
                field("billToNoOfCreditMemos"; Rec."Bill-To No. of Credit Memos") { }
                field("billToNoOfInvoices"; Rec."Bill-To No. of Invoices") { }
                field("billToNoOfOrders"; Rec."Bill-To No. of Orders") { }
                field("billToNoOfPstdCrMemos"; Rec."Bill-To No. of Pstd. Cr. Memos") { }
                field("billToNoOfPstdInvoices"; Rec."Bill-To No. of Pstd. Invoices") { }
                field("billToNoOfPstdReturnR"; Rec."Bill-To No. of Pstd. Return R.") { }
                field("billToNoOfPstdShipments"; Rec."Bill-To No. of Pstd. Shipments") { }
                field("billToNoOfQuotes"; Rec."Bill-To No. of Quotes") { }
                field("billToNoOfReturnOrders"; Rec."Bill-To No. of Return Orders") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("billToNoOfArchivedDoc"; Rec."Bill-to No. Of Archived Doc.") { }
                field("blockPaymentTolerance"; Rec."Block Payment Tolerance") { }
                field("blocked"; Rec."Blocked") { }
                field("budgetedAmount"; Rec."Budgeted Amount") { }
                field("cashFlowPaymentTermsCode"; Rec."Cash Flow Payment Terms Code") { }
                field("chainName"; Rec."Chain Name") { }
                field("city"; Rec."City") { }
                field("collectionMethod"; Rec."Collection Method") { }
                field("combineShipments"; Rec."Combine Shipments") { }
                field("comment"; Rec."Comment") { }
                field("contact"; Rec."Contact") { }
                field("contactGraphId"; Rec."Contact Graph Id") { }
                field("contactID"; Rec."Contact ID") { }
                field("contactType"; Rec."Contact Type") { }
                field("contractGainLossAmount"; Rec."Contract Gain/Loss Amount") { }
                field("copySellToAddrToQteFrom"; Rec."Copy Sell-to Addr. to Qte From") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("county"; Rec."County") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("crMemoAmounts"; Rec."Cr. Memo Amounts") { }
                field("crMemoAmountsLCY"; Rec."Cr. Memo Amounts (LCY)") { }
                field("creditAmount"; Rec."Credit Amount") { }
                field("creditAmountLCY"; Rec."Credit Amount (LCY)") { }
                field("creditLimitLCY"; Rec."Credit Limit (LCY)") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyId"; Rec."Currency Id") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPostingGroup"; Rec."Customer Posting Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("debitAmount"; Rec."Debit Amount") { }
                field("debitAmountLCY"; Rec."Debit Amount (LCY)") { }
                field("disableSearchByName"; Rec."Disable Search by Name") { }
                field("documentSendingProfile"; Rec."Document Sending Profile") { }
                field("eMail"; Rec."E-Mail") { }
                field("eoriNumber"; Rec."EORI Number") { }
                field("excludeFromPmtPractices"; Rec."Exclude from Pmt. Practices") { }
                field("faxNo"; Rec."Fax No.") { }
                field("finChargeMemoAmountsLCY"; Rec."Fin. Charge Memo Amounts (LCY)") { }
                field("finChargeTermsCode"; Rec."Fin. Charge Terms Code") { }
                field("financeChargeMemoAmounts"; Rec."Finance Charge Memo Amounts") { }
                field("formatRegion"; Rec."Format Region") { }
                field("gln"; Rec."GLN") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("image"; Rec."Image") { }
                field("intrastatPartnerType"; Rec."Intrastat Partner Type") { }
                field("invAmountsLCY"; Rec."Inv. Amounts (LCY)") { }
                field("invDiscountsLCY"; Rec."Inv. Discounts (LCY)") { }
                field("invoiceAmounts"; Rec."Invoice Amounts") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("languageCode"; Rec."Language Code") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("lastStatementNo"; Rec."Last Statement No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("mobilePhoneNo"; Rec."Mobile Phone No.") { }
                field("name"; Rec."Name") { }
                field("name2"; Rec."Name 2") { }
                field("netChange"; Rec."Net Change") { }
                field("netChangeLCY"; Rec."Net Change (LCY)") { }
                field("no"; Rec."No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("noOfBlanketOrders"; Rec."No. of Blanket Orders") { }
                field("noOfCreditMemos"; Rec."No. of Credit Memos") { }
                field("noOfInvoices"; Rec."No. of Invoices") { }
                field("noOfOrders"; Rec."No. of Orders") { }
                field("noOfPstdCreditMemos"; Rec."No. of Pstd. Credit Memos") { }
                field("noOfPstdInvoices"; Rec."No. of Pstd. Invoices") { }
                field("noOfPstdReturnReceipts"; Rec."No. of Pstd. Return Receipts") { }
                field("noOfPstdShipments"; Rec."No. of Pstd. Shipments") { }
                field("noOfQuotes"; Rec."No. of Quotes") { }
                field("noOfReturnOrders"; Rec."No. of Return Orders") { }
                field("noOfShipToAddresses"; Rec."No. of Ship-to Addresses") { }
                field("otherAmounts"; Rec."Other Amounts") { }
                field("otherAmountsLCY"; Rec."Other Amounts (LCY)") { }
                field("ourAccountNo"; Rec."Our Account No.") { }
                field("outstandingInvoices"; Rec."Outstanding Invoices") { }
                field("outstandingInvoicesLCY"; Rec."Outstanding Invoices (LCY)") { }
                field("outstandingOrders"; Rec."Outstanding Orders") { }
                field("outstandingOrdersLCY"; Rec."Outstanding Orders (LCY)") { }
                field("outstandingServOrdersLCY"; Rec."Outstanding Serv. Orders (LCY)") { }
                field("outstandingServInvoicesLCY"; Rec."Outstanding Serv.Invoices(LCY)") { }
                field("partnerType"; Rec."Partner Type") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentMethodId"; Rec."Payment Method Id") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("paymentTermsId"; Rec."Payment Terms Id") { }
                field("payments"; Rec."Payments") { }
                field("paymentsLCY"; Rec."Payments (LCY)") { }
                field("phoneNo"; Rec."Phone No.") { }
                field("placeOfExport"; Rec."Place of Export") { }
                field("pmtDiscToleranceLCY"; Rec."Pmt. Disc. Tolerance (LCY)") { }
                field("pmtDiscountsLCY"; Rec."Pmt. Discounts (LCY)") { }
                field("pmtToleranceLCY"; Rec."Pmt. Tolerance (LCY)") { }
                field("postCode"; Rec."Post Code") { }
                field("preferredBankAccountCode"; Rec."Preferred Bank Account Code") { }
                field("prepayment"; Rec."Prepayment %") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("primaryContactNo"; Rec."Primary Contact No.") { }
                field("printStatements"; Rec."Print Statements") { }
                field("priority"; Rec."Priority") { }
                field("privacyBlocked"; Rec."Privacy Blocked") { }
                field("profitLCY"; Rec."Profit (LCY)") { }
                field("refunds"; Rec."Refunds") { }
                field("refundsLCY"; Rec."Refunds (LCY)") { }
                field("registrationNumber"; Rec."Registration Number") { }
                field("reminderAmounts"; Rec."Reminder Amounts") { }
                field("reminderAmountsLCY"; Rec."Reminder Amounts (LCY)") { }
                field("reminderTermsCode"; Rec."Reminder Terms Code") { }
                field("reserve"; Rec."Reserve") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("salesLCY"; Rec."Sales (LCY)") { }
                field("salespersonCode"; Rec."Salesperson Code") { }
                field("searchName"; Rec."Search Name") { }
                field("sellToNoOfArchivedDoc"; Rec."Sell-to No. Of Archived Doc.") { }
                field("servShippedNotInvoicedLCY"; Rec."Serv Shipped Not Invoiced(LCY)") { }
                field("serviceZoneCode"; Rec."Service Zone Code") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shipmentMethodId"; Rec."Shipment Method Id") { }
                field("shippedNotInvoiced"; Rec."Shipped Not Invoiced") { }
                field("shippedNotInvoicedLCY"; Rec."Shipped Not Invoiced (LCY)") { }
                field("shippingAdvice"; Rec."Shipping Advice") { }
                field("shippingAgentCode"; Rec."Shipping Agent Code") { }
                field("shippingAgentServiceCode"; Rec."Shipping Agent Service Code") { }
                field("shippingTime"; Rec."Shipping Time") { }
                field("statisticsGroup"; Rec."Statistics Group") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxAreaID"; Rec."Tax Area ID") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("telexAnswerBack"; Rec."Telex Answer Back") { }
                field("telexNo"; Rec."Telex No.") { }
                field("territoryCode"; Rec."Territory Code") { }
                field("useGLNInElectronicDocument"; Rec."Use GLN in Electronic Document") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("validateEUVatRegNo"; Rec."Validate EU Vat Reg. No.") { }
                field("currencyFilter"; Rec."Currency Filter") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("globalDimension1Filter"; Rec."Global Dimension 1 Filter") { }
                field("globalDimension2Filter"; Rec."Global Dimension 2 Filter") { }
                field("shipToFilter"; Rec."Ship-to Filter") { }
            }
        }
    }
}

page 86507 "Hevo DefaultDimension"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'defaultDimension';
    EntitySetName = 'defaultDimensions';
    Caption = 'defaultDimensions', Locked = true;
    SourceTable = "Default Dimension";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowedValuesFilter"; Rec."Allowed Values Filter") { }
                field("dimensionCode"; Rec."Dimension Code") { }
                field("dimensionValueCode"; Rec."Dimension Value Code") { }
                field("dimensionId"; Rec."DimensionId") { }
                field("dimensionValueId"; Rec."DimensionValueId") { }
                field("multiSelectionAction"; Rec."Multi Selection Action") { }
                field("no"; Rec."No.") { }
                field("parentType"; Rec."Parent Type") { }
                field("parentId"; Rec."ParentId") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("tableCaption"; Rec."Table Caption") { }
                field("tableID"; Rec."Table ID") { }
                field("valuePosting"; Rec."Value Posting") { }
            }
        }
    }
}

page 86508 "Hevo Dimension"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'dimension';
    EntitySetName = 'dimensions';
    Caption = 'dimensions', Locked = true;
    SourceTable = "Dimension";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("blocked"; Rec."Blocked") { }
                field("code"; Rec."Code") { }
                field("codeCaption"; Rec."Code Caption") { }
                field("consolidationCode"; Rec."Consolidation Code") { }
                field("description"; Rec."Description") { }
                field("filterCaption"; Rec."Filter Caption") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("mapToICDimensionCode"; Rec."Map-to IC Dimension Code") { }
                field("name"; Rec."Name") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86509 "Hevo DimensionSetEntry"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'dimensionSetEntry';
    EntitySetName = 'dimensionSetEntries';
    Caption = 'dimensionSetEntries', Locked = true;
    SourceTable = "Dimension Set Entry";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("dimensionCode"; Rec."Dimension Code") { }
                field("dimensionName"; Rec."Dimension Name") { }
                field("dimensionValueCode"; Rec."Dimension Value Code") { }
                field("dimensionValueID"; Rec."Dimension Value ID") { }
                field("dimensionValueName"; Rec."Dimension Value Name") { }
                field("globalDimensionNo"; Rec."Global Dimension No.") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemId"; Rec."SystemId") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86510 "Hevo DimensionValue"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'dimensionValue';
    EntitySetName = 'dimensionValues';
    Caption = 'dimensionValues', Locked = true;
    SourceTable = "Dimension Value";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("blocked"; Rec."Blocked") { }
                field("code"; Rec."Code") { }
                field("consolidationCode"; Rec."Consolidation Code") { }
                field("dimensionCode"; Rec."Dimension Code") { }
                field("dimensionId"; Rec."Dimension Id") { }
                field("dimensionValueID"; Rec."Dimension Value ID") { }
                field("dimensionValueType"; Rec."Dimension Value Type") { }
                field("globalDimensionNo"; Rec."Global Dimension No.") { }
                field("indentation"; Rec."Indentation") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("mapToICDimensionCode"; Rec."Map-to IC Dimension Code") { }
                field("mapToICDimensionValueCode"; Rec."Map-to IC Dimension Value Code") { }
                field("name"; Rec."Name") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("totaling"; Rec."Totaling") { }
            }
        }
    }
}

page 86511 "Hevo Employee"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'employee';
    EntitySetName = 'employees';
    Caption = 'employees', Locked = true;
    SourceTable = "Employee";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("address"; Rec."Address") { }
                field("address2"; Rec."Address 2") { }
                field("altAddressCode"; Rec."Alt. Address Code") { }
                field("altAddressEndDate"; Rec."Alt. Address End Date") { }
                field("altAddressStartDate"; Rec."Alt. Address Start Date") { }
                field("applicationMethod"; Rec."Application Method") { }
                field("balance"; Rec."Balance") { }
                field("bankAccountNo"; Rec."Bank Account No.") { }
                field("bankBranchNo"; Rec."Bank Branch No.") { }
                field("birthDate"; Rec."Birth Date") { }
                field("causeOfInactivityCode"; Rec."Cause of Inactivity Code") { }
                field("city"; Rec."City") { }
                field("comment"; Rec."Comment") { }
                field("companyEMail"; Rec."Company E-Mail") { }
                field("costCenterCode"; Rec."Cost Center Code") { }
                field("costObjectCode"; Rec."Cost Object Code") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("county"; Rec."County") { }
                field("eMail"; Rec."E-Mail") { }
                field("employeePostingGroup"; Rec."Employee Posting Group") { }
                field("employmentDate"; Rec."Employment Date") { }
                field("emplymtContractCode"; Rec."Emplymt. Contract Code") { }
                field("extension"; Rec."Extension") { }
                field("faxNo"; Rec."Fax No.") { }
                field("firstName"; Rec."First Name") { }
                field("gender"; Rec."Gender") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("groundsForTermCode"; Rec."Grounds for Term. Code") { }
                field("iban"; Rec."IBAN") { }
                field("image"; Rec."Image") { }
                field("inactiveDate"; Rec."Inactive Date") { }
                field("initials"; Rec."Initials") { }
                field("jobTitle"; Rec."Job Title") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("lastName"; Rec."Last Name") { }
                field("managerNo"; Rec."Manager No.") { }
                field("middleName"; Rec."Middle Name") { }
                field("mobilePhoneNo"; Rec."Mobile Phone No.") { }
                field("no"; Rec."No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("pager"; Rec."Pager") { }
                field("phoneNo"; Rec."Phone No.") { }
                field("postCode"; Rec."Post Code") { }
                field("privacyBlocked"; Rec."Privacy Blocked") { }
                field("resourceNo"; Rec."Resource No.") { }
                field("swiftCode"; Rec."SWIFT Code") { }
                field("salespersPurchCode"; Rec."Salespers./Purch. Code") { }
                field("searchName"; Rec."Search Name") { }
                field("socialSecurityNo"; Rec."Social Security No.") { }
                field("statisticsGroupCode"; Rec."Statistics Group Code") { }
                field("status"; Rec."Status") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("terminationDate"; Rec."Termination Date") { }
                field("title"; Rec."Title") { }
                field("totalAbsenceBase"; Rec."Total Absence (Base)") { }
                field("unionCode"; Rec."Union Code") { }
                field("unionMembershipNo"; Rec."Union Membership No.") { }
                field("causeOfAbsenceFilter"; Rec."Cause of Absence Filter") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("employeeNoFilter"; Rec."Employee No. Filter") { }
                field("globalDimension1Filter"; Rec."Global Dimension 1 Filter") { }
                field("globalDimension2Filter"; Rec."Global Dimension 2 Filter") { }
            }
        }
    }
}

page 86512 "Hevo GLAccount"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'generalLedgerAccount';
    EntitySetName = 'generalLedgerAccounts';
    Caption = 'generalLedgerAccounts', Locked = true;
    SourceTable = "G/L Account";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("apiAccountType"; Rec."API Account Type") { }
                field("accountCategory"; Rec."Account Category") { }
                field("accountSubcategoryDescript"; Rec."Account Subcategory Descript.") { }
                field("accountSubcategoryEntryNo"; Rec."Account Subcategory Entry No.") { }
                field("accountType"; Rec."Account Type") { }
                field("addCurrencyBalanceAtDate"; Rec."Add.-Currency Balance at Date") { }
                field("addCurrencyCreditAmount"; Rec."Add.-Currency Credit Amount") { }
                field("addCurrencyDebitAmount"; Rec."Add.-Currency Debit Amount") { }
                field("additionalCurrencyBalance"; Rec."Additional-Currency Balance") { }
                field("additionalCurrencyNetChange"; Rec."Additional-Currency Net Change") { }
                field("automaticExtTexts"; Rec."Automatic Ext. Texts") { }
                field("balance"; Rec."Balance") { }
                field("balanceAtDate"; Rec."Balance at Date") { }
                field("blocked"; Rec."Blocked") { }
                field("budgetAtDate"; Rec."Budget at Date") { }
                field("budgetedAmount"; Rec."Budgeted Amount") { }
                field("budgetedCreditAmount"; Rec."Budgeted Credit Amount") { }
                field("budgetedDebitAmount"; Rec."Budgeted Debit Amount") { }
                field("comment"; Rec."Comment") { }
                field("consolCreditAcc"; Rec."Consol. Credit Acc.") { }
                field("consolDebitAcc"; Rec."Consol. Debit Acc.") { }
                field("consolTranslationMethod"; Rec."Consol. Translation Method") { }
                field("costTypeNo"; Rec."Cost Type No.") { }
                field("creditAmount"; Rec."Credit Amount") { }
                field("debitAmount"; Rec."Debit Amount") { }
                field("debitCredit"; Rec."Debit/Credit") { }
                field("defaultDeferralTemplateCode"; Rec."Default Deferral Template Code") { }
                field("defaultICPartnerGLAccNo"; Rec."Default IC Partner G/L Acc. No") { }
                field("directPosting"; Rec."Direct Posting") { }
                field("exchangeRateAdjustment"; Rec."Exchange Rate Adjustment") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genPostingType"; Rec."Gen. Posting Type") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("incomeBalance"; Rec."Income/Balance") { }
                field("indentation"; Rec."Indentation") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("name"; Rec."Name") { }
                field("netChange"; Rec."Net Change") { }
                field("newPage"; Rec."New Page") { }
                field("no"; Rec."No.") { }
                field("no2"; Rec."No. 2") { }
                field("noOfBlankLines"; Rec."No. of Blank Lines") { }
                field("omitDefaultDescrInJnl"; Rec."Omit Default Descr. in Jnl.") { }
                field("picture"; Rec."Picture") { }
                field("reconciliationAccount"; Rec."Reconciliation Account") { }
                field("searchName"; Rec."Search Name") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("totaling"; Rec."Totaling") { }
                field("vatAmt"; Rec."VAT Amt.") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("budgetFilter"; Rec."Budget Filter") { }
                field("businessUnitFilter"; Rec."Business Unit Filter") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("dimensionSetIDFilter"; Rec."Dimension Set ID Filter") { }
                field("globalDimension1Filter"; Rec."Global Dimension 1 Filter") { }
                field("globalDimension2Filter"; Rec."Global Dimension 2 Filter") { }
                field("vatReportingDateFilter"; Rec."VAT Reporting Date Filter") { }
            }
        }
    }
}

page 86513 "Hevo GLEntry"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'generalLedgerEntry';
    EntitySetName = 'generalLedgerEntries';
    Caption = 'generalLedgerEntries', Locked = true;
    SourceTable = "G/L Entry";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("accountId"; Rec."Account Id") { }
                field("addCurrencyCreditAmount"; Rec."Add.-Currency Credit Amount") { }
                field("addCurrencyDebitAmount"; Rec."Add.-Currency Debit Amount") { }
                field("additionalCurrencyAmount"; Rec."Additional-Currency Amount") { }
                field("allocationAccountNo"; Rec."Allocation Account No.") { }
                field("amount"; Rec."Amount") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("businessUnitCode"; Rec."Business Unit Code") { }
                field("closeIncomeStatementDimID"; Rec."Close Income Statement Dim. ID") { }
                field("comment"; Rec."Comment") { }
                field("creditAmount"; Rec."Credit Amount") { }
                field("debitAmount"; Rec."Debit Amount") { }
                field("description"; Rec."Description") { }
                field("dimensionChangesCount"; Rec."Dimension Changes Count") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentNo"; Rec."Document No.") { }
                field("documentType"; Rec."Document Type") { }
                field("entryNo"; Rec."Entry No.") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("faEntryNo"; Rec."FA Entry No.") { }
                field("faEntryType"; Rec."FA Entry Type") { }
                field("gLAccountName"; Rec."G/L Account Name") { }
                field("gLAccountNo"; Rec."G/L Account No.") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genPostingType"; Rec."Gen. Posting Type") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("jobNo"; Rec."Job No.") { }
                field("journalBatchName"; Rec."Journal Batch Name") { }
                field("journalTemplName"; Rec."Journal Templ. Name") { }
                field("lastDimCorrectionEntryNo"; Rec."Last Dim. Correction Entry No.") { }
                field("lastDimCorrectionNode"; Rec."Last Dim. Correction Node") { }
                field("lastModifiedDateTime"; Rec."Last Modified DateTime") { }
                field("noSeries"; Rec."No. Series") { }
                field("nonDeductibleVATAmount"; Rec."Non-Deductible VAT Amount") { }
                field("nonDeductibleVATAmountACY"; Rec."Non-Deductible VAT Amount ACY") { }
                field("postingDate"; Rec."Posting Date") { }
                field("priorYearEntry"; Rec."Prior-Year Entry") { }
                field("prodOrderNo"; Rec."Prod. Order No.") { }
                field("quantity"; Rec."Quantity") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("reversed"; Rec."Reversed") { }
                field("reversedEntryNo"; Rec."Reversed Entry No.") { }
                field("reversedByEntryNo"; Rec."Reversed by Entry No.") { }
                field("shortcutDimension3Code"; Rec."Shortcut Dimension 3 Code") { }
                field("shortcutDimension4Code"; Rec."Shortcut Dimension 4 Code") { }
                field("shortcutDimension5Code"; Rec."Shortcut Dimension 5 Code") { }
                field("shortcutDimension6Code"; Rec."Shortcut Dimension 6 Code") { }
                field("shortcutDimension7Code"; Rec."Shortcut Dimension 7 Code") { }
                field("shortcutDimension8Code"; Rec."Shortcut Dimension 8 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("sourceNo"; Rec."Source No.") { }
                field("sourceType"; Rec."Source Type") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionNo"; Rec."Transaction No.") { }
                field("useTax"; Rec."Use Tax") { }
                field("userID"; Rec."User ID") { }
                field("vatAmount"; Rec."VAT Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("vatReportingDate"; Rec."VAT Reporting Date") { }
            }
        }
    }
}

page 86514 "Hevo GenJournalBatch"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'generalJournalBatch';
    EntitySetName = 'generalJournalBatches';
    Caption = 'generalJournalBatches', Locked = true;
    SourceTable = "Gen. Journal Batch";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowPaymentExport"; Rec."Allow Payment Export") { }
                field("allowVATDifference"; Rec."Allow VAT Difference") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("balAccountId"; Rec."BalAccountId") { }
                field("bankStatementImportFormat"; Rec."Bank Statement Import Format") { }
                field("copyVATSetupToJnlLines"; Rec."Copy VAT Setup to Jnl. Lines") { }
                field("copyToPostedJnlLines"; Rec."Copy to Posted Jnl. Lines") { }
                field("description"; Rec."Description") { }
                field("journalTemplateName"; Rec."Journal Template Name") { }
                field("lastModifiedDateTime"; Rec."Last Modified DateTime") { }
                field("name"; Rec."Name") { }
                field("noSeries"; Rec."No. Series") { }
                field("pendingApproval"; Rec."Pending Approval") { }
                field("postingNoSeries"; Rec."Posting No. Series") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("recurring"; Rec."Recurring") { }
                field("suggestBalancingAmount"; Rec."Suggest Balancing Amount") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("templateType"; Rec."Template Type") { }
            }
        }
    }
}

page 86515 "Hevo GenJournalLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'generalJournalLine';
    EntitySetName = 'generalJournalLines';
    Caption = 'generalJournalLines', Locked = true;
    SourceTable = "Gen. Journal Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("accountId"; Rec."Account Id") { }
                field("accountNo"; Rec."Account No.") { }
                field("accountType"; Rec."Account Type") { }
                field("additionalCurrencyPosting"; Rec."Additional-Currency Posting") { }
                field("allocAccModifiedByUser"; Rec."Alloc. Acc. Modified by User") { }
                field("allocatedAmtLCY"; Rec."Allocated Amt. (LCY)") { }
                field("allocationAccountNo"; Rec."Allocation Account No.") { }
                field("allowApplication"; Rec."Allow Application") { }
                field("allowZeroAmountPosting"; Rec."Allow Zero-Amount Posting") { }
                field("amount"; Rec."Amount") { }
                field("amountLCY"; Rec."Amount (LCY)") { }
                field("appliedAutomatically"; Rec."Applied Automatically") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("appliesToExtDocNo"; Rec."Applies-to Ext. Doc. No.") { }
                field("appliesToID"; Rec."Applies-to ID") { }
                field("appliesToInvoiceId"; Rec."Applies-to Invoice Id") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("balGenBusPostingGroup"; Rec."Bal. Gen. Bus. Posting Group") { }
                field("balGenPostingType"; Rec."Bal. Gen. Posting Type") { }
                field("balGenProdPostingGroup"; Rec."Bal. Gen. Prod. Posting Group") { }
                field("balNonDedVAT"; Rec."Bal. Non-Ded. VAT %") { }
                field("balNonDedVATAmount"; Rec."Bal. Non-Ded. VAT Amount") { }
                field("balNonDedVATAmountLCY"; Rec."Bal. Non-Ded. VAT Amount LCY") { }
                field("balNonDedVATBase"; Rec."Bal. Non-Ded. VAT Base") { }
                field("balNonDedVATBaseLCY"; Rec."Bal. Non-Ded. VAT Base LCY") { }
                field("balTaxAreaCode"; Rec."Bal. Tax Area Code") { }
                field("balTaxGroupCode"; Rec."Bal. Tax Group Code") { }
                field("balTaxLiable"; Rec."Bal. Tax Liable") { }
                field("balUseTax"; Rec."Bal. Use Tax") { }
                field("balVAT"; Rec."Bal. VAT %") { }
                field("balVATAmount"; Rec."Bal. VAT Amount") { }
                field("balVATAmountLCY"; Rec."Bal. VAT Amount (LCY)") { }
                field("balVATBaseAmount"; Rec."Bal. VAT Base Amount") { }
                field("balVATBaseAmountLCY"; Rec."Bal. VAT Base Amount (LCY)") { }
                field("balVATBusPostingGroup"; Rec."Bal. VAT Bus. Posting Group") { }
                field("balVATCalculationType"; Rec."Bal. VAT Calculation Type") { }
                field("balVATDifference"; Rec."Bal. VAT Difference") { }
                field("balVATProdPostingGroup"; Rec."Bal. VAT Prod. Posting Group") { }
                field("balanceLCY"; Rec."Balance (LCY)") { }
                field("balanceAccountId"; Rec."Balance Account Id") { }
                field("bankPaymentType"; Rec."Bank Payment Type") { }
                field("billToPayToNo"; Rec."Bill-to/Pay-to No.") { }
                field("budgetedFANo"; Rec."Budgeted FA No.") { }
                field("businessUnitCode"; Rec."Business Unit Code") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("checkExported"; Rec."Check Exported") { }
                field("checkPrinted"; Rec."Check Printed") { }
                field("checkTransmitted"; Rec."Check Transmitted") { }
                field("comment"; Rec."Comment") { }
                field("contactGraphId"; Rec."Contact Graph Id") { }
                field("copyVATSetupToJnlLines"; Rec."Copy VAT Setup to Jnl. Lines") { }
                field("correction"; Rec."Correction") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("creditAmount"; Rec."Credit Amount") { }
                field("creditorNo"; Rec."Creditor No.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("customerId"; Rec."Customer Id") { }
                field("dataExchEntryNo"; Rec."Data Exch. Entry No.") { }
                field("dataExchLineNo"; Rec."Data Exch. Line No.") { }
                field("debitAmount"; Rec."Debit Amount") { }
                field("deferralCode"; Rec."Deferral Code") { }
                field("deferralLineNo"; Rec."Deferral Line No.") { }
                field("deprAcquisitionCost"; Rec."Depr. Acquisition Cost") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("directDebitMandateID"; Rec."Direct Debit Mandate ID") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentNo"; Rec."Document No.") { }
                field("documentType"; Rec."Document Type") { }
                field("dueDate"; Rec."Due Date") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("eu3PartyTrade"; Rec."EU 3-Party Trade") { }
                field("expirationDate"; Rec."Expiration Date") { }
                field("exportedToPaymentFile"; Rec."Exported to Payment File") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("faAddCurrencyFactor"; Rec."FA Add.-Currency Factor") { }
                field("faErrorEntryNo"; Rec."FA Error Entry No.") { }
                field("faGLAccountNo"; Rec."FA G/L Account No.") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("faPostingType"; Rec."FA Posting Type") { }
                field("faReclassificationEntry"; Rec."FA Reclassification Entry") { }
                field("financialVoid"; Rec."Financial Void") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genPostingType"; Rec."Gen. Posting Type") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("hasPaymentExportError"; Rec."Has Payment Export Error") { }
                field("icAccountNo"; Rec."IC Account No.") { }
                field("icAccountType"; Rec."IC Account Type") { }
                field("icDirection"; Rec."IC Direction") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("icPartnerTransactionNo"; Rec."IC Partner Transaction No.") { }
                field("incomingDocumentEntryNo"; Rec."Incoming Document Entry No.") { }
                field("indexEntry"; Rec."Index Entry") { }
                field("insuranceNo"; Rec."Insurance No.") { }
                field("invDiscountLCY"; Rec."Inv. Discount (LCY)") { }
                field("invoiceReceivedDate"; Rec."Invoice Received Date") { }
                field("jobCurrencyCode"; Rec."Job Currency Code") { }
                field("jobCurrencyFactor"; Rec."Job Currency Factor") { }
                field("jobLineAmount"; Rec."Job Line Amount") { }
                field("jobLineAmountLCY"; Rec."Job Line Amount (LCY)") { }
                field("jobLineDiscAmountLCY"; Rec."Job Line Disc. Amount (LCY)") { }
                field("jobLineDiscount"; Rec."Job Line Discount %") { }
                field("jobLineDiscountAmount"; Rec."Job Line Discount Amount") { }
                field("jobLineType"; Rec."Job Line Type") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobPlanningLineNo"; Rec."Job Planning Line No.") { }
                field("jobQuantity"; Rec."Job Quantity") { }
                field("jobQueueEntryID"; Rec."Job Queue Entry ID") { }
                field("jobQueueStatus"; Rec."Job Queue Status") { }
                field("jobRemainingQty"; Rec."Job Remaining Qty.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("jobTotalCost"; Rec."Job Total Cost") { }
                field("jobTotalCostLCY"; Rec."Job Total Cost (LCY)") { }
                field("jobTotalPrice"; Rec."Job Total Price") { }
                field("jobTotalPriceLCY"; Rec."Job Total Price (LCY)") { }
                field("jobUnitCost"; Rec."Job Unit Cost") { }
                field("jobUnitCostLCY"; Rec."Job Unit Cost (LCY)") { }
                field("jobUnitOfMeasureCode"; Rec."Job Unit Of Measure Code") { }
                field("jobUnitPrice"; Rec."Job Unit Price") { }
                field("jobUnitPriceLCY"; Rec."Job Unit Price (LCY)") { }
                field("journalBatchId"; Rec."Journal Batch Id") { }
                field("journalBatchName"; Rec."Journal Batch Name") { }
                field("journalTemplateName"; Rec."Journal Template Name") { }
                field("keepDescription"; Rec."Keep Description") { }
                field("lastModifiedDateTime"; Rec."Last Modified DateTime") { }
                field("lineNo"; Rec."Line No.") { }
                field("linkedSystemID"; Rec."Linked System ID") { }
                field("linkedTableID"; Rec."Linked Table ID") { }
                field("maintenanceCode"; Rec."Maintenance Code") { }
                field("messageToRecipient"; Rec."Message to Recipient") { }
                field("noOfDepreciationDays"; Rec."No. of Depreciation Days") { }
                field("nonDeductibleVAT"; Rec."Non-Deductible VAT %") { }
                field("nonDeductibleVATAmount"; Rec."Non-Deductible VAT Amount") { }
                field("nonDeductibleVATAmountACY"; Rec."Non-Deductible VAT Amount ACY") { }
                field("nonDeductibleVATAmountLCY"; Rec."Non-Deductible VAT Amount LCY") { }
                field("nonDeductibleVATBase"; Rec."Non-Deductible VAT Base") { }
                field("nonDeductibleVATBaseACY"; Rec."Non-Deductible VAT Base ACY") { }
                field("nonDeductibleVATBaseLCY"; Rec."Non-Deductible VAT Base LCY") { }
                field("nonDeductibleVATDiff"; Rec."Non-Deductible VAT Diff.") { }
                field("onHold"; Rec."On Hold") { }
                field("origPmtDiscPossible"; Rec."Orig. Pmt. Disc. Possible") { }
                field("origPmtDiscPossibleLCY"; Rec."Orig. Pmt. Disc. Possible(LCY)") { }
                field("payerInformation"; Rec."Payer Information") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentMethodId"; Rec."Payment Method Id") { }
                field("paymentReference"; Rec."Payment Reference") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pendingApproval"; Rec."Pending Approval") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("postingNoSeries"; Rec."Posting No. Series") { }
                field("prepayment"; Rec."Prepayment") { }
                field("printPostedDocuments"; Rec."Print Posted Documents") { }
                field("prodOrderNo"; Rec."Prod. Order No.") { }
                field("profitLCY"; Rec."Profit (LCY)") { }
                field("quantity"; Rec."Quantity") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("recipientBankAccount"; Rec."Recipient Bank Account") { }
                field("recurringFrequency"; Rec."Recurring Frequency") { }
                field("recurringMethod"; Rec."Recurring Method") { }
                field("remitToCode"; Rec."Remit-to Code") { }
                field("reverseDateCalculation"; Rec."Reverse Date Calculation") { }
                field("reversingEntry"; Rec."Reversing Entry") { }
                field("salesPurchLCY"; Rec."Sales/Purch. (LCY)") { }
                field("salespersPurchCode"; Rec."Salespers./Purch. Code") { }
                field("salvageValue"; Rec."Salvage Value") { }
                field("selectedAllocAccountNo"; Rec."Selected Alloc. Account No.") { }
                field("sellToBuyFromNo"; Rec."Sell-to/Buy-from No.") { }
                field("shipToOrderAddressCode"; Rec."Ship-to/Order Address Code") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("sourceCurrVATAmount"; Rec."Source Curr. VAT Amount") { }
                field("sourceCurrVATBaseAmount"; Rec."Source Curr. VAT Base Amount") { }
                field("sourceCurrencyAmount"; Rec."Source Currency Amount") { }
                field("sourceCurrencyCode"; Rec."Source Currency Code") { }
                field("sourceLineNo"; Rec."Source Line No.") { }
                field("sourceNo"; Rec."Source No.") { }
                field("sourceType"; Rec."Source Type") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionInformation"; Rec."Transaction Information") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("useTax"; Rec."Use Tax") { }
                field("vat"; Rec."VAT %") { }
                field("vatAmount"; Rec."VAT Amount") { }
                field("vatAmountLCY"; Rec."VAT Amount (LCY)") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBaseAmountLCY"; Rec."VAT Base Amount (LCY)") { }
                field("vatBaseBeforePmtDisc"; Rec."VAT Base Before Pmt. Disc.") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatDifference"; Rec."VAT Difference") { }
                field("vatPosting"; Rec."VAT Posting") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("vatReportingDate"; Rec."VAT Reporting Date") { }
                field("vendorId"; Rec."Vendor Id") { }
                field("yourReference"; Rec."Your Reference") { }
            }
        }
    }
}

page 86516 "Hevo GenProductPostingGroup"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'generalProductPostingGroup';
    EntitySetName = 'generalProductPostingGroups';
    Caption = 'generalProductPostingGroups', Locked = true;
    SourceTable = "Gen. Product Posting Group";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("autoInsertDefault"; Rec."Auto Insert Default") { }
                field("code"; Rec."Code") { }
                field("defVATProdPostingGroup"; Rec."Def. VAT Prod. Posting Group") { }
                field("description"; Rec."Description") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86517 "Hevo InventoryPostingGroup"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'inventoryPostingGroup';
    EntitySetName = 'inventoryPostingGroups';
    Caption = 'inventoryPostingGroups', Locked = true;
    SourceTable = "Inventory Posting Group";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("code"; Rec."Code") { }
                field("description"; Rec."Description") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86518 "Hevo Item"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'item';
    EntitySetName = 'items';
    Caption = 'items', Locked = true;
    SourceTable = "Item";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("allowOnlineAdjustment"; Rec."Allow Online Adjustment") { }
                field("alternativeItemNo"; Rec."Alternative Item No.") { }
                field("applicationWkshUserID"; Rec."Application Wksh. User ID") { }
                field("assemblyBOM"; Rec."Assembly BOM") { }
                field("assemblyPolicy"; Rec."Assembly Policy") { }
                field("automaticExtTexts"; Rec."Automatic Ext. Texts") { }
                field("baseUnitOfMeasure"; Rec."Base Unit of Measure") { }
                field("blockReason"; Rec."Block Reason") { }
                field("blocked"; Rec."Blocked") { }
                field("budgetProfit"; Rec."Budget Profit") { }
                field("budgetQuantity"; Rec."Budget Quantity") { }
                field("budgetedAmount"; Rec."Budgeted Amount") { }
                field("cogsLCY"; Rec."COGS (LCY)") { }
                field("comment"; Rec."Comment") { }
                field("commissionGroup"; Rec."Commission Group") { }
                field("commonItemNo"; Rec."Common Item No.") { }
                field("costIsAdjusted"; Rec."Cost is Adjusted") { }
                field("costIsPostedToGL"; Rec."Cost is Posted to G/L") { }
                field("costOfOpenProductionOrders"; Rec."Cost of Open Production Orders") { }
                field("costingMethod"; Rec."Costing Method") { }
                field("countryRegionPurchasedCode"; Rec."Country/Region Purchased Code") { }
                field("countryRegionOfOriginCode"; Rec."Country/Region of Origin Code") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("createdFromNonstockItem"; Rec."Created From Nonstock Item") { }
                field("critical"; Rec."Critical") { }
                field("dampenerPeriod"; Rec."Dampener Period") { }
                field("dampenerQuantity"; Rec."Dampener Quantity") { }
                field("defaultDeferralTemplateCode"; Rec."Default Deferral Template Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("discreteOrderQuantity"; Rec."Discrete Order Quantity") { }
                field("durability"; Rec."Durability") { }
                field("dutyCode"; Rec."Duty Code") { }
                field("dutyDue"; Rec."Duty Due %") { }
                field("dutyUnitConversion"; Rec."Duty Unit Conversion") { }
                field("expirationCalculation"; Rec."Expiration Calculation") { }
                field("fpOrderReceiptQty"; Rec."FP Order Receipt (Qty.)") { }
                field("flushingMethod"; Rec."Flushing Method") { }
                field("freightType"; Rec."Freight Type") { }
                field("gtin"; Rec."GTIN") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("genProdPostingGroupId"; Rec."Gen. Prod. Posting Group Id") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("identifierCode"; Rec."Identifier Code") { }
                field("includeInventory"; Rec."Include Inventory") { }
                field("indirectCost"; Rec."Indirect Cost %") { }
                field("inventory"; Rec."Inventory") { }
                field("inventoryPostingGroup"; Rec."Inventory Posting Group") { }
                field("inventoryPostingGroupId"; Rec."Inventory Posting Group Id") { }
                field("inventoryValueZero"; Rec."Inventory Value Zero") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemCategoryId"; Rec."Item Category Id") { }
                field("itemDiscGroup"; Rec."Item Disc. Group") { }
                field("itemTrackingCode"; Rec."Item Tracking Code") { }
                field("lastCountingPeriodUpdate"; Rec."Last Counting Period Update") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastDateTimeModified"; Rec."Last DateTime Modified") { }
                field("lastDirectCost"; Rec."Last Direct Cost") { }
                field("lastPhysInvtDate"; Rec."Last Phys. Invt. Date") { }
                field("lastTimeModified"; Rec."Last Time Modified") { }
                field("lastUnitCostCalcDate"; Rec."Last Unit Cost Calc. Date") { }
                field("leadTimeCalculation"; Rec."Lead Time Calculation") { }
                field("lotAccumulationPeriod"; Rec."Lot Accumulation Period") { }
                field("lotNos"; Rec."Lot Nos.") { }
                field("lotSize"; Rec."Lot Size") { }
                field("lowLevelCode"; Rec."Low-Level Code") { }
                field("manufacturerCode"; Rec."Manufacturer Code") { }
                field("manufacturingPolicy"; Rec."Manufacturing Policy") { }
                field("maximumInventory"; Rec."Maximum Inventory") { }
                field("maximumOrderQuantity"; Rec."Maximum Order Quantity") { }
                field("minimumOrderQuantity"; Rec."Minimum Order Quantity") { }
                field("negativeAdjmtLCY"; Rec."Negative Adjmt. (LCY)") { }
                field("negativeAdjmtQty"; Rec."Negative Adjmt. (Qty.)") { }
                field("netChange"; Rec."Net Change") { }
                field("netInvoicedQty"; Rec."Net Invoiced Qty.") { }
                field("netWeight"; Rec."Net Weight") { }
                field("nextCountingEndDate"; Rec."Next Counting End Date") { }
                field("nextCountingStartDate"; Rec."Next Counting Start Date") { }
                field("no"; Rec."No.") { }
                field("no2"; Rec."No. 2") { }
                field("noSeries"; Rec."No. Series") { }
                field("noOfSubstitutes"; Rec."No. of Substitutes") { }
                field("orderMultiple"; Rec."Order Multiple") { }
                field("orderTrackingPolicy"; Rec."Order Tracking Policy") { }
                field("overReceiptCode"; Rec."Over-Receipt Code") { }
                field("overflowLevel"; Rec."Overflow Level") { }
                field("overheadRate"; Rec."Overhead Rate") { }
                field("physInvtCountingPeriodCode"; Rec."Phys Invt Counting Period Code") { }
                field("picture"; Rec."Picture") { }
                field("plannedOrderReceiptQty"; Rec."Planned Order Receipt (Qty.)") { }
                field("plannedOrderReleaseQty"; Rec."Planned Order Release (Qty.)") { }
                field("planningIssuesQty"; Rec."Planning Issues (Qty.)") { }
                field("planningReceiptQty"; Rec."Planning Receipt (Qty.)") { }
                field("planningReleaseQty"; Rec."Planning Release (Qty.)") { }
                field("planningTransferShipQty"; Rec."Planning Transfer Ship. (Qty).") { }
                field("planningWorksheetQty"; Rec."Planning Worksheet (Qty.)") { }
                field("positiveAdjmtLCY"; Rec."Positive Adjmt. (LCY)") { }
                field("positiveAdjmtQty"; Rec."Positive Adjmt. (Qty.)") { }
                field("preventNegativeInventory"; Rec."Prevent Negative Inventory") { }
                field("priceIncludesVAT"; Rec."Price Includes VAT") { }
                field("priceUnitConversion"; Rec."Price Unit Conversion") { }
                field("priceProfitCalculation"; Rec."Price/Profit Calculation") { }
                field("prodForecastQuantityBase"; Rec."Prod. Forecast Quantity (Base)") { }
                field("productionBOMNo"; Rec."Production BOM No.") { }
                field("profit"; Rec."Profit %") { }
                field("purchReqReceiptQty"; Rec."Purch. Req. Receipt (Qty.)") { }
                field("purchReqReleaseQty"; Rec."Purch. Req. Release (Qty.)") { }
                field("purchUnitOfMeasure"; Rec."Purch. Unit of Measure") { }
                field("purchasesLCY"; Rec."Purchases (LCY)") { }
                field("purchasesQty"; Rec."Purchases (Qty.)") { }
                field("purchasingBlocked"; Rec."Purchasing Blocked") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("putAwayTemplateCode"; Rec."Put-away Template Code") { }
                field("putAwayUnitOfMeasureCode"; Rec."Put-away Unit of Measure Code") { }
                field("qtyAssignedToShip"; Rec."Qty. Assigned to ship") { }
                field("qtyPicked"; Rec."Qty. Picked") { }
                field("qtyInTransit"; Rec."Qty. in Transit") { }
                field("qtyOnAsmComponent"; Rec."Qty. on Asm. Component") { }
                field("qtyOnAssemblyOrder"; Rec."Qty. on Assembly Order") { }
                field("qtyOnComponentLines"; Rec."Qty. on Component Lines") { }
                field("qtyOnJobOrder"; Rec."Qty. on Job Order") { }
                field("qtyOnProdOrder"; Rec."Qty. on Prod. Order") { }
                field("qtyOnPurchOrder"; Rec."Qty. on Purch. Order") { }
                field("qtyOnPurchReturn"; Rec."Qty. on Purch. Return") { }
                field("qtyOnSalesOrder"; Rec."Qty. on Sales Order") { }
                field("qtyOnSalesReturn"; Rec."Qty. on Sales Return") { }
                field("qtyOnServiceOrder"; Rec."Qty. on Service Order") { }
                field("relOrderReceiptQty"; Rec."Rel. Order Receipt (Qty.)") { }
                field("reorderPoint"; Rec."Reorder Point") { }
                field("reorderQuantity"; Rec."Reorder Quantity") { }
                field("reorderingPolicy"; Rec."Reordering Policy") { }
                field("replenishmentSystem"; Rec."Replenishment System") { }
                field("resQtyOnAsmComp"; Rec."Res. Qty. on  Asm. Comp.") { }
                field("resQtyOnAssemblyOrder"; Rec."Res. Qty. on Assembly Order") { }
                field("resQtyOnInboundTransfer"; Rec."Res. Qty. on Inbound Transfer") { }
                field("resQtyOnJobOrder"; Rec."Res. Qty. on Job Order") { }
                field("resQtyOnOutboundTransfer"; Rec."Res. Qty. on Outbound Transfer") { }
                field("resQtyOnProdOrderComp"; Rec."Res. Qty. on Prod. Order Comp.") { }
                field("resQtyOnPurchReturns"; Rec."Res. Qty. on Purch. Returns") { }
                field("resQtyOnReqLine"; Rec."Res. Qty. on Req. Line") { }
                field("resQtyOnSalesReturns"; Rec."Res. Qty. on Sales Returns") { }
                field("resQtyOnServiceOrders"; Rec."Res. Qty. on Service Orders") { }
                field("reschedulingPeriod"; Rec."Rescheduling Period") { }
                field("reserve"; Rec."Reserve") { }
                field("reservedQtyOnInventory"; Rec."Reserved Qty. on Inventory") { }
                field("reservedQtyOnProdOrder"; Rec."Reserved Qty. on Prod. Order") { }
                field("reservedQtyOnPurchOrders"; Rec."Reserved Qty. on Purch. Orders") { }
                field("reservedQtyOnSalesOrders"; Rec."Reserved Qty. on Sales Orders") { }
                field("rolledUpCapOverheadCost"; Rec."Rolled-up Cap. Overhead Cost") { }
                field("rolledUpCapacityCost"; Rec."Rolled-up Capacity Cost") { }
                field("rolledUpMaterialCost"; Rec."Rolled-up Material Cost") { }
                field("rolledUpMfgOvhdCost"; Rec."Rolled-up Mfg. Ovhd Cost") { }
                field("rolledUpSubcontractedCost"; Rec."Rolled-up Subcontracted Cost") { }
                field("roundingPrecision"; Rec."Rounding Precision") { }
                field("routingNo"; Rec."Routing No.") { }
                field("safetyLeadTime"; Rec."Safety Lead Time") { }
                field("safetyStockQuantity"; Rec."Safety Stock Quantity") { }
                field("salesLCY"; Rec."Sales (LCY)") { }
                field("salesQty"; Rec."Sales (Qty.)") { }
                field("salesBlocked"; Rec."Sales Blocked") { }
                field("salesUnitOfMeasure"; Rec."Sales Unit of Measure") { }
                field("scheduledReceiptQty"; Rec."Scheduled Receipt (Qty.)") { }
                field("scrap"; Rec."Scrap %") { }
                field("searchDescription"; Rec."Search Description") { }
                field("serialNos"; Rec."Serial Nos.") { }
                field("serviceItemGroup"; Rec."Service Item Group") { }
                field("shelfNo"; Rec."Shelf No.") { }
                field("singleLevelCapOvhdCost"; Rec."Single-Level Cap. Ovhd Cost") { }
                field("singleLevelCapacityCost"; Rec."Single-Level Capacity Cost") { }
                field("singleLevelMaterialCost"; Rec."Single-Level Material Cost") { }
                field("singleLevelMfgOvhdCost"; Rec."Single-Level Mfg. Ovhd Cost") { }
                field("singleLevelSubcontrdCost"; Rec."Single-Level Subcontrd. Cost") { }
                field("specialEquipmentCode"; Rec."Special Equipment Code") { }
                field("standardCost"; Rec."Standard Cost") { }
                field("statisticsGroup"; Rec."Statistics Group") { }
                field("stockkeepingUnitExists"; Rec."Stockkeeping Unit Exists") { }
                field("stockoutWarning"; Rec."Stockout Warning") { }
                field("substitutesExist"; Rec."Substitutes Exist") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("tariffNo"; Rec."Tariff No.") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxGroupId"; Rec."Tax Group Id") { }
                field("timeBucket"; Rec."Time Bucket") { }
                field("transOrdReceiptQty"; Rec."Trans. Ord. Receipt (Qty.)") { }
                field("transOrdShipmentQty"; Rec."Trans. Ord. Shipment (Qty.)") { }
                field("transferredLCY"; Rec."Transferred (LCY)") { }
                field("transferredQty"; Rec."Transferred (Qty.)") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitGroupExists"; Rec."Unit Group Exists") { }
                field("unitListPrice"; Rec."Unit List Price") { }
                field("unitPrice"; Rec."Unit Price") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasureId"; Rec."Unit of Measure Id") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useCrossDocking"; Rec."Use Cross-Docking") { }
                field("vatBusPostingGrPrice"; Rec."VAT Bus. Posting Gr. (Price)") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantMandatoryIfExists"; Rec."Variant Mandatory if Exists") { }
                field("vendorItemNo"; Rec."Vendor Item No.") { }
                field("vendorNo"; Rec."Vendor No.") { }
                field("warehouseClassCode"; Rec."Warehouse Class Code") { }
                field("binFilter"; Rec."Bin Filter") { }
                field("componentForecast"; Rec."Component Forecast") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("dropShipmentFilter"; Rec."Drop Shipment Filter") { }
                field("globalDimension1Filter"; Rec."Global Dimension 1 Filter") { }
                field("globalDimension2Filter"; Rec."Global Dimension 2 Filter") { }
                field("locationFilter"; Rec."Location Filter") { }
                field("lotNoFilter"; Rec."Lot No. Filter") { }
                field("packageNoFilter"; Rec."Package No. Filter") { }
                field("productionForecastName"; Rec."Production Forecast Name") { }
                field("serialNoFilter"; Rec."Serial No. Filter") { }
                field("unitOfMeasureFilter"; Rec."Unit of Measure Filter") { }
                field("variantFilter"; Rec."Variant Filter") { }
            }
        }
    }
}

page 86519 "Hevo ItemCategory"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'itemCategory';
    EntitySetName = 'itemCategories';
    Caption = 'itemCategories', Locked = true;
    SourceTable = "Item Category";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("code"; Rec."Code") { }
                field("description"; Rec."Description") { }
                field("hasChildren"; Rec."Has Children") { }
                field("indentation"; Rec."Indentation") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("parentCategory"; Rec."Parent Category") { }
                field("presentationOrder"; Rec."Presentation Order") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86520 "Hevo ItemLedgerEntry"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'itemLedgerEntry';
    EntitySetName = 'itemLedgerEntries';
    Caption = 'itemLedgerEntries', Locked = true;
    SourceTable = "Item Ledger Entry";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("appliedEntryToAdjust"; Rec."Applied Entry to Adjust") { }
                field("appliesToEntry"; Rec."Applies-to Entry") { }
                field("area"; Rec."Area") { }
                field("assembleToOrder"; Rec."Assemble to Order") { }
                field("completelyInvoiced"; Rec."Completely Invoiced") { }
                field("correction"; Rec."Correction") { }
                field("costAmountActual"; Rec."Cost Amount (Actual)") { }
                field("costAmountActualACY"; Rec."Cost Amount (Actual) (ACY)") { }
                field("costAmountExpected"; Rec."Cost Amount (Expected)") { }
                field("costAmountExpectedACY"; Rec."Cost Amount (Expected) (ACY)") { }
                field("costAmountNonInvtbl"; Rec."Cost Amount (Non-Invtbl.)") { }
                field("costAmountNonInvtblACY"; Rec."Cost Amount (Non-Invtbl.)(ACY)") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("derivedFromBlanketOrder"; Rec."Derived from Blanket Order") { }
                field("description"; Rec."Description") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentLineNo"; Rec."Document Line No.") { }
                field("documentNo"; Rec."Document No.") { }
                field("documentType"; Rec."Document Type") { }
                field("dropShipment"; Rec."Drop Shipment") { }
                field("entryNo"; Rec."Entry No.") { }
                field("entryType"; Rec."Entry Type") { }
                field("entryExitPoint"; Rec."Entry/Exit Point") { }
                field("expirationDate"; Rec."Expiration Date") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("invoicedQuantity"; Rec."Invoiced Quantity") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemNo"; Rec."Item No.") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemTracking"; Rec."Item Tracking") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobPurchase"; Rec."Job Purchase") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("lastInvoiceDate"; Rec."Last Invoice Date") { }
                field("locationCode"; Rec."Location Code") { }
                field("lotNo"; Rec."Lot No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("nonstock"; Rec."Nonstock") { }
                field("open"; Rec."Open") { }
                field("orderLineNo"; Rec."Order Line No.") { }
                field("orderNo"; Rec."Order No.") { }
                field("orderType"; Rec."Order Type") { }
                field("originallyOrderedNo"; Rec."Originally Ordered No.") { }
                field("originallyOrderedVarCode"; Rec."Originally Ordered Var. Code") { }
                field("outOfStockSubstitution"; Rec."Out-of-Stock Substitution") { }
                field("packageNo"; Rec."Package No.") { }
                field("positive"; Rec."Positive") { }
                field("postingDate"; Rec."Posting Date") { }
                field("prodOrderCompLineNo"; Rec."Prod. Order Comp. Line No.") { }
                field("purchaseAmountActual"; Rec."Purchase Amount (Actual)") { }
                field("purchaseAmountExpected"; Rec."Purchase Amount (Expected)") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("quantity"; Rec."Quantity") { }
                field("remainingQuantity"; Rec."Remaining Quantity") { }
                field("reservedQuantity"; Rec."Reserved Quantity") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("salesAmountActual"; Rec."Sales Amount (Actual)") { }
                field("salesAmountExpected"; Rec."Sales Amount (Expected)") { }
                field("serialNo"; Rec."Serial No.") { }
                field("shippedQtyNotReturned"; Rec."Shipped Qty. Not Returned") { }
                field("shortcutDimension3Code"; Rec."Shortcut Dimension 3 Code") { }
                field("shortcutDimension4Code"; Rec."Shortcut Dimension 4 Code") { }
                field("shortcutDimension5Code"; Rec."Shortcut Dimension 5 Code") { }
                field("shortcutDimension6Code"; Rec."Shortcut Dimension 6 Code") { }
                field("shortcutDimension7Code"; Rec."Shortcut Dimension 7 Code") { }
                field("shortcutDimension8Code"; Rec."Shortcut Dimension 8 Code") { }
                field("shptMethodCode"; Rec."Shpt. Method Code") { }
                field("sourceNo"; Rec."Source No.") { }
                field("sourceType"; Rec."Source Type") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("variantCode"; Rec."Variant Code") { }
                field("warrantyDate"; Rec."Warranty Date") { }
            }
        }
    }
}

page 86521 "Hevo ItemVariant"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'itemVariant';
    EntitySetName = 'itemVariants';
    Caption = 'itemVariants', Locked = true;
    SourceTable = "Item Variant";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("blocked"; Rec."Blocked") { }
                field("code"; Rec."Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("itemId"; Rec."Item Id") { }
                field("itemNo"; Rec."Item No.") { }
                field("purchasingBlocked"; Rec."Purchasing Blocked") { }
                field("salesBlocked"; Rec."Sales Blocked") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86522 "Hevo Job"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'job';
    EntitySetName = 'jobs';
    Caption = 'jobs', Locked = true;
    SourceTable = "Job";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowScheduleContractLines"; Rec."Allow Schedule/Contract Lines") { }
                field("appliedCostsGLAmount"; Rec."Applied Costs G/L Amount") { }
                field("appliedSalesGLAmount"; Rec."Applied Sales G/L Amount") { }
                field("applyUsageLink"; Rec."Apply Usage Link") { }
                field("billToAddress"; Rec."Bill-to Address") { }
                field("billToAddress2"; Rec."Bill-to Address 2") { }
                field("billToCity"; Rec."Bill-to City") { }
                field("billToContact"; Rec."Bill-to Contact") { }
                field("billToContactNo"; Rec."Bill-to Contact No.") { }
                field("billToCountryRegionCode"; Rec."Bill-to Country/Region Code") { }
                field("billToCounty"; Rec."Bill-to County") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("billToName"; Rec."Bill-to Name") { }
                field("billToName2"; Rec."Bill-to Name 2") { }
                field("billToPostCode"; Rec."Bill-to Post Code") { }
                field("blocked"; Rec."Blocked") { }
                field("calcRecogCostsAmount"; Rec."Calc. Recog. Costs Amount") { }
                field("calcRecogCostsGLAmount"; Rec."Calc. Recog. Costs G/L Amount") { }
                field("calcRecogSalesAmount"; Rec."Calc. Recog. Sales Amount") { }
                field("calcRecogSalesGLAmount"; Rec."Calc. Recog. Sales G/L Amount") { }
                field("comment"; Rec."Comment") { }
                field("complete"; Rec."Complete") { }
                field("completelyPicked"; Rec."Completely Picked") { }
                field("costCalculationMethod"; Rec."Cost Calculation Method") { }
                field("creationDate"; Rec."Creation Date") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("endingDate"; Rec."Ending Date") { }
                field("exchCalculationCost"; Rec."Exch. Calculation (Cost)") { }
                field("exchCalculationPrice"; Rec."Exch. Calculation (Price)") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("image"; Rec."Image") { }
                field("invoiceCurrencyCode"; Rec."Invoice Currency Code") { }
                field("jobPostingGroup"; Rec."Job Posting Group") { }
                field("languageCode"; Rec."Language Code") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("nextInvoiceDate"; Rec."Next Invoice Date") { }
                field("no"; Rec."No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("overBudget"; Rec."Over Budget") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("personResponsible"; Rec."Person Responsible") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("projectManager"; Rec."Project Manager") { }
                field("recogCostsAmount"; Rec."Recog. Costs Amount") { }
                field("recogCostsGLAmount"; Rec."Recog. Costs G/L Amount") { }
                field("recogSalesAmount"; Rec."Recog. Sales Amount") { }
                field("recogSalesGLAmount"; Rec."Recog. Sales G/L Amount") { }
                field("reserve"; Rec."Reserve") { }
                field("scheduledResGrQty"; Rec."Scheduled Res. Gr. Qty.") { }
                field("scheduledResQty"; Rec."Scheduled Res. Qty.") { }
                field("searchDescription"; Rec."Search Description") { }
                field("sellToAddress"; Rec."Sell-to Address") { }
                field("sellToAddress2"; Rec."Sell-to Address 2") { }
                field("sellToCity"; Rec."Sell-to City") { }
                field("sellToContact"; Rec."Sell-to Contact") { }
                field("sellToContactNo"; Rec."Sell-to Contact No.") { }
                field("sellToCountryRegionCode"; Rec."Sell-to Country/Region Code") { }
                field("sellToCounty"; Rec."Sell-to County") { }
                field("sellToCustomerName"; Rec."Sell-to Customer Name") { }
                field("sellToCustomerName2"; Rec."Sell-to Customer Name 2") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("sellToEMail"; Rec."Sell-to E-Mail") { }
                field("sellToPhoneNo"; Rec."Sell-to Phone No.") { }
                field("sellToPostCode"; Rec."Sell-to Post Code") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("startingDate"; Rec."Starting Date") { }
                field("status"; Rec."Status") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("totalWIPCostAmount"; Rec."Total WIP Cost Amount") { }
                field("totalWIPCostGLAmount"; Rec."Total WIP Cost G/L Amount") { }
                field("totalWIPSalesAmount"; Rec."Total WIP Sales Amount") { }
                field("totalWIPSalesGLAmount"; Rec."Total WIP Sales G/L Amount") { }
                field("wipCompletionCalculated"; Rec."WIP Completion Calculated") { }
                field("wipCompletionPosted"; Rec."WIP Completion Posted") { }
                field("wipEntriesExist"; Rec."WIP Entries Exist") { }
                field("wipGLPostingDate"; Rec."WIP G/L Posting Date") { }
                field("wipMethod"; Rec."WIP Method") { }
                field("wipPostingDate"; Rec."WIP Posting Date") { }
                field("wipPostingMethod"; Rec."WIP Posting Method") { }
                field("wipWarnings"; Rec."WIP Warnings") { }
                field("yourReference"; Rec."Your Reference") { }
                field("planningDateFilter"; Rec."Planning Date Filter") { }
                field("postingDateFilter"; Rec."Posting Date Filter") { }
                field("resourceFilter"; Rec."Resource Filter") { }
                field("resourceGrFilter"; Rec."Resource Gr. Filter") { }
            }
        }
    }
}

page 86523 "Hevo Location"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'location';
    EntitySetName = 'locations';
    Caption = 'locations', Locked = true;
    SourceTable = "Location";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("address"; Rec."Address") { }
                field("address2"; Rec."Address 2") { }
                field("adjustmentBinCode"; Rec."Adjustment Bin Code") { }
                field("allowBreakbulk"; Rec."Allow Breakbulk") { }
                field("alwaysCreatePickLine"; Rec."Always Create Pick Line") { }
                field("alwaysCreatePutAwayLine"; Rec."Always Create Put-away Line") { }
                field("asmConsumpWhseHandling"; Rec."Asm. Consump. Whse. Handling") { }
                field("asmToOrderShptBinCode"; Rec."Asm.-to-Order Shpt. Bin Code") { }
                field("baseCalendarCode"; Rec."Base Calendar Code") { }
                field("binCapacityPolicy"; Rec."Bin Capacity Policy") { }
                field("binMandatory"; Rec."Bin Mandatory") { }
                field("checkWhseClass"; Rec."Check Whse. Class") { }
                field("city"; Rec."City") { }
                field("code"; Rec."Code") { }
                field("contact"; Rec."Contact") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("county"; Rec."County") { }
                field("crossDockBinCode"; Rec."Cross-Dock Bin Code") { }
                field("crossDockDueDateCalc"; Rec."Cross-Dock Due Date Calc.") { }
                field("defaultBinCode"; Rec."Default Bin Code") { }
                field("defaultBinSelection"; Rec."Default Bin Selection") { }
                field("directedPutAwayAndPick"; Rec."Directed Put-away and Pick") { }
                field("eMail"; Rec."E-Mail") { }
                field("faxNo"; Rec."Fax No.") { }
                field("fromAssemblyBinCode"; Rec."From-Assembly Bin Code") { }
                field("fromProductionBinCode"; Rec."From-Production Bin Code") { }
                field("inboundWhseHandlingTime"; Rec."Inbound Whse. Handling Time") { }
                field("jobConsumpWhseHandling"; Rec."Job Consump. Whse. Handling") { }
                field("name"; Rec."Name") { }
                field("name2"; Rec."Name 2") { }
                field("openShopFloorBinCode"; Rec."Open Shop Floor Bin Code") { }
                field("outboundWhseHandlingTime"; Rec."Outbound Whse. Handling Time") { }
                field("phoneNo"; Rec."Phone No.") { }
                field("phoneNo2"; Rec."Phone No. 2") { }
                field("pickAccordingToFEFO"; Rec."Pick According to FEFO") { }
                field("pickBinPolicy"; Rec."Pick Bin Policy") { }
                field("postCode"; Rec."Post Code") { }
                field("prodConsumpWhseHandling"; Rec."Prod. Consump. Whse. Handling") { }
                field("prodOutputWhseHandling"; Rec."Prod. Output Whse. Handling") { }
                field("putAwayBinPolicy"; Rec."Put-away Bin Policy") { }
                field("putAwayTemplateCode"; Rec."Put-away Template Code") { }
                field("receiptBinCode"; Rec."Receipt Bin Code") { }
                field("requirePick"; Rec."Require Pick") { }
                field("requirePutAway"; Rec."Require Put-away") { }
                field("requireReceive"; Rec."Require Receive") { }
                field("requireShipment"; Rec."Require Shipment") { }
                field("shipmentBinCode"; Rec."Shipment Bin Code") { }
                field("specialEquipment"; Rec."Special Equipment") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("telexNo"; Rec."Telex No.") { }
                field("toAssemblyBinCode"; Rec."To-Assembly Bin Code") { }
                field("toJobBinCode"; Rec."To-Job Bin Code") { }
                field("toProductionBinCode"; Rec."To-Production Bin Code") { }
                field("useADCS"; Rec."Use ADCS") { }
                field("useAsInTransit"; Rec."Use As In-Transit") { }
                field("useCrossDocking"; Rec."Use Cross-Docking") { }
                field("usePutAwayWorksheet"; Rec."Use Put-away Worksheet") { }
            }
        }
    }
}

page 86524 "Hevo Opportunity"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'opportunity';
    EntitySetName = 'opportunities';
    Caption = 'opportunities', Locked = true;
    SourceTable = "Opportunity";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("activateFirstStage"; Rec."Activate First Stage") { }
                field("calcdCurrentValueLCY"; Rec."Calcd. Current Value (LCY)") { }
                field("campaignDescription"; Rec."Campaign Description") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("chancesOfSuccess"; Rec."Chances of Success %") { }
                field("closed"; Rec."Closed") { }
                field("comment"; Rec."Comment") { }
                field("completed"; Rec."Completed %") { }
                field("contactCompanyName"; Rec."Contact Company Name") { }
                field("contactCompanyNo"; Rec."Contact Company No.") { }
                field("contactName"; Rec."Contact Name") { }
                field("contactNo"; Rec."Contact No.") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("creationDate"; Rec."Creation Date") { }
                field("currentSalesCycleStage"; Rec."Current Sales Cycle Stage") { }
                field("dateClosed"; Rec."Date Closed") { }
                field("description"; Rec."Description") { }
                field("estimatedClosingDate"; Rec."Estimated Closing Date") { }
                field("estimatedValueLCY"; Rec."Estimated Value (LCY)") { }
                field("no"; Rec."No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("noOfInteractions"; Rec."No. of Interactions") { }
                field("priority"; Rec."Priority") { }
                field("probability"; Rec."Probability %") { }
                field("salesCycleCode"; Rec."Sales Cycle Code") { }
                field("salesDocumentNo"; Rec."Sales Document No.") { }
                field("salesDocumentType"; Rec."Sales Document Type") { }
                field("salespersonCode"; Rec."Salesperson Code") { }
                field("salespersonName"; Rec."Salesperson Name") { }
                field("segmentDescription"; Rec."Segment Description") { }
                field("segmentNo"; Rec."Segment No.") { }
                field("status"; Rec."Status") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("wizardCampaignDescription"; Rec."Wizard Campaign Description") { }
                field("wizardChancesOfSuccess"; Rec."Wizard Chances of Success %") { }
                field("wizardContactName"; Rec."Wizard Contact Name") { }
                field("wizardEstimatedClosingDate"; Rec."Wizard Estimated Closing Date") { }
                field("wizardEstimatedValueLCY"; Rec."Wizard Estimated Value (LCY)") { }
                field("wizardStep"; Rec."Wizard Step") { }
            }
        }
    }
}

page 86525 "Hevo PaymentMethod"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'paymentMethod';
    EntitySetName = 'paymentMethods';
    Caption = 'paymentMethods', Locked = true;
    SourceTable = "Payment Method";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("code"; Rec."Code") { }
                field("description"; Rec."Description") { }
                field("directDebit"; Rec."Direct Debit") { }
                field("directDebitPmtTermsCode"; Rec."Direct Debit Pmt. Terms Code") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("pmtExportLineDefinition"; Rec."Pmt. Export Line Definition") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86526 "Hevo PaymentTerms"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'paymentTerm';
    EntitySetName = 'paymentTerms';
    Caption = 'paymentTerms', Locked = true;
    SourceTable = "Payment Terms";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("calcPmtDiscOnCrMemos"; Rec."Calc. Pmt. Disc. on Cr. Memos") { }
                field("code"; Rec."Code") { }
                field("description"; Rec."Description") { }
                field("discount"; Rec."Discount %") { }
                field("discountDateCalculation"; Rec."Discount Date Calculation") { }
                field("dueDateCalculation"; Rec."Due Date Calculation") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86527 "Hevo PostedGenJournalBatch"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'postedGeneralJournalBatch';
    EntitySetName = 'postedGeneralJournalBatch';
    Caption = 'postedGeneralJournalBatch', Locked = true;
    SourceTable = "Posted Gen. Journal Batch";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowPaymentExport"; Rec."Allow Payment Export") { }
                field("allowVATDifference"; Rec."Allow VAT Difference") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("bankStatementImportFormat"; Rec."Bank Statement Import Format") { }
                field("copyVATSetupToJnlLines"; Rec."Copy VAT Setup to Jnl. Lines") { }
                field("copyToPostedJnlLines"; Rec."Copy to Posted Jnl. Lines") { }
                field("description"; Rec."Description") { }
                field("journalTemplateName"; Rec."Journal Template Name") { }
                field("name"; Rec."Name") { }
                field("noSeries"; Rec."No. Series") { }
                field("postingNoSeries"; Rec."Posting No. Series") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("suggestBalancingAmount"; Rec."Suggest Balancing Amount") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86528 "Hevo PostedGenJournalLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'postedGeneralJournalLine';
    EntitySetName = 'postedGeneralJournalLines';
    Caption = 'postedGeneralJournalLines', Locked = true;
    SourceTable = "Posted Gen. Journal Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("accountId"; Rec."Account Id") { }
                field("accountNo"; Rec."Account No.") { }
                field("accountType"; Rec."Account Type") { }
                field("additionalCurrencyPosting"; Rec."Additional-Currency Posting") { }
                field("allowApplication"; Rec."Allow Application") { }
                field("allowZeroAmountPosting"; Rec."Allow Zero-Amount Posting") { }
                field("amount"; Rec."Amount") { }
                field("amountLCY"; Rec."Amount (LCY)") { }
                field("appliedAutomatically"; Rec."Applied Automatically") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("appliesToExtDocNo"; Rec."Applies-to Ext. Doc. No.") { }
                field("appliesToID"; Rec."Applies-to ID") { }
                field("appliesToInvoiceId"; Rec."Applies-to Invoice Id") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("balGenBusPostingGroup"; Rec."Bal. Gen. Bus. Posting Group") { }
                field("balGenPostingType"; Rec."Bal. Gen. Posting Type") { }
                field("balGenProdPostingGroup"; Rec."Bal. Gen. Prod. Posting Group") { }
                field("balTaxAreaCode"; Rec."Bal. Tax Area Code") { }
                field("balTaxGroupCode"; Rec."Bal. Tax Group Code") { }
                field("balTaxLiable"; Rec."Bal. Tax Liable") { }
                field("balUseTax"; Rec."Bal. Use Tax") { }
                field("balVAT"; Rec."Bal. VAT %") { }
                field("balVATAmount"; Rec."Bal. VAT Amount") { }
                field("balVATAmountLCY"; Rec."Bal. VAT Amount (LCY)") { }
                field("balVATBaseAmount"; Rec."Bal. VAT Base Amount") { }
                field("balVATBaseAmountLCY"; Rec."Bal. VAT Base Amount (LCY)") { }
                field("balVATBusPostingGroup"; Rec."Bal. VAT Bus. Posting Group") { }
                field("balVATCalculationType"; Rec."Bal. VAT Calculation Type") { }
                field("balVATDifference"; Rec."Bal. VAT Difference") { }
                field("balVATProdPostingGroup"; Rec."Bal. VAT Prod. Posting Group") { }
                field("balanceLCY"; Rec."Balance (LCY)") { }
                field("bankPaymentType"; Rec."Bank Payment Type") { }
                field("billToPayToNo"; Rec."Bill-to/Pay-to No.") { }
                field("budgetedFANo"; Rec."Budgeted FA No.") { }
                field("businessUnitCode"; Rec."Business Unit Code") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("checkExported"; Rec."Check Exported") { }
                field("checkPrinted"; Rec."Check Printed") { }
                field("checkTransmitted"; Rec."Check Transmitted") { }
                field("comment"; Rec."Comment") { }
                field("contactGraphId"; Rec."Contact Graph Id") { }
                field("copyVATSetupToJnlLines"; Rec."Copy VAT Setup to Jnl. Lines") { }
                field("correction"; Rec."Correction") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("creditAmount"; Rec."Credit Amount") { }
                field("creditorNo"; Rec."Creditor No.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("customerId"; Rec."Customer Id") { }
                field("dataExchEntryNo"; Rec."Data Exch. Entry No.") { }
                field("dataExchLineNo"; Rec."Data Exch. Line No.") { }
                field("debitAmount"; Rec."Debit Amount") { }
                field("deferralCode"; Rec."Deferral Code") { }
                field("deferralLineNo"; Rec."Deferral Line No.") { }
                field("deprAcquisitionCost"; Rec."Depr. Acquisition Cost") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("directDebitMandateID"; Rec."Direct Debit Mandate ID") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentNo"; Rec."Document No.") { }
                field("documentType"; Rec."Document Type") { }
                field("dueDate"; Rec."Due Date") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("eu3PartyTrade"; Rec."EU 3-Party Trade") { }
                field("expirationDate"; Rec."Expiration Date") { }
                field("exportedToPaymentFile"; Rec."Exported to Payment File") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("faAddCurrencyFactor"; Rec."FA Add.-Currency Factor") { }
                field("faErrorEntryNo"; Rec."FA Error Entry No.") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("faPostingType"; Rec."FA Posting Type") { }
                field("faReclassificationEntry"; Rec."FA Reclassification Entry") { }
                field("financialVoid"; Rec."Financial Void") { }
                field("gLRegisterNo"; Rec."G/L Register No.") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genPostingType"; Rec."Gen. Posting Type") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("icAccountNo"; Rec."IC Account No.") { }
                field("icAccountType"; Rec."IC Account Type") { }
                field("icDirection"; Rec."IC Direction") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("icPartnerTransactionNo"; Rec."IC Partner Transaction No.") { }
                field("incomingDocumentEntryNo"; Rec."Incoming Document Entry No.") { }
                field("indentation"; Rec."Indentation") { }
                field("indexEntry"; Rec."Index Entry") { }
                field("insuranceNo"; Rec."Insurance No.") { }
                field("invDiscountLCY"; Rec."Inv. Discount (LCY)") { }
                field("invoiceReceivedDate"; Rec."Invoice Received Date") { }
                field("jobCurrencyCode"; Rec."Job Currency Code") { }
                field("jobCurrencyFactor"; Rec."Job Currency Factor") { }
                field("jobLineAmount"; Rec."Job Line Amount") { }
                field("jobLineAmountLCY"; Rec."Job Line Amount (LCY)") { }
                field("jobLineDiscAmountLCY"; Rec."Job Line Disc. Amount (LCY)") { }
                field("jobLineDiscount"; Rec."Job Line Discount %") { }
                field("jobLineDiscountAmount"; Rec."Job Line Discount Amount") { }
                field("jobLineType"; Rec."Job Line Type") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobPlanningLineNo"; Rec."Job Planning Line No.") { }
                field("jobQuantity"; Rec."Job Quantity") { }
                field("jobQueueEntryID"; Rec."Job Queue Entry ID") { }
                field("jobQueueStatus"; Rec."Job Queue Status") { }
                field("jobRemainingQty"; Rec."Job Remaining Qty.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("jobTotalCost"; Rec."Job Total Cost") { }
                field("jobTotalCostLCY"; Rec."Job Total Cost (LCY)") { }
                field("jobTotalPrice"; Rec."Job Total Price") { }
                field("jobTotalPriceLCY"; Rec."Job Total Price (LCY)") { }
                field("jobUnitCost"; Rec."Job Unit Cost") { }
                field("jobUnitCostLCY"; Rec."Job Unit Cost (LCY)") { }
                field("jobUnitOfMeasureCode"; Rec."Job Unit Of Measure Code") { }
                field("jobUnitPrice"; Rec."Job Unit Price") { }
                field("jobUnitPriceLCY"; Rec."Job Unit Price (LCY)") { }
                field("journalBatchId"; Rec."Journal Batch Id") { }
                field("journalBatchName"; Rec."Journal Batch Name") { }
                field("journalTemplateName"; Rec."Journal Template Name") { }
                field("lastModifiedDateTime"; Rec."Last Modified DateTime") { }
                field("lineNo"; Rec."Line No.") { }
                field("maintenanceCode"; Rec."Maintenance Code") { }
                field("messageToRecipient"; Rec."Message to Recipient") { }
                field("noOfDepreciationDays"; Rec."No. of Depreciation Days") { }
                field("nonDeductibleVAT"; Rec."Non-Deductible VAT %") { }
                field("nonDeductibleVATAmount"; Rec."Non-Deductible VAT Amount") { }
                field("nonDeductibleVATAmountACY"; Rec."Non-Deductible VAT Amount ACY") { }
                field("nonDeductibleVATAmountLCY"; Rec."Non-Deductible VAT Amount LCY") { }
                field("nonDeductibleVATBase"; Rec."Non-Deductible VAT Base") { }
                field("nonDeductibleVATBaseACY"; Rec."Non-Deductible VAT Base ACY") { }
                field("nonDeductibleVATBaseLCY"; Rec."Non-Deductible VAT Base LCY") { }
                field("nonDeductibleVATDiff"; Rec."Non-Deductible VAT Diff.") { }
                field("onHold"; Rec."On Hold") { }
                field("origPmtDiscPossible"; Rec."Orig. Pmt. Disc. Possible") { }
                field("origPmtDiscPossibleLCY"; Rec."Orig. Pmt. Disc. Possible(LCY)") { }
                field("payerInformation"; Rec."Payer Information") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentMethodId"; Rec."Payment Method Id") { }
                field("paymentReference"; Rec."Payment Reference") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("postingNoSeries"; Rec."Posting No. Series") { }
                field("prepayment"; Rec."Prepayment") { }
                field("printPostedDocuments"; Rec."Print Posted Documents") { }
                field("prodOrderNo"; Rec."Prod. Order No.") { }
                field("profitLCY"; Rec."Profit (LCY)") { }
                field("quantity"; Rec."Quantity") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("recipientBankAccount"; Rec."Recipient Bank Account") { }
                field("recurringFrequency"; Rec."Recurring Frequency") { }
                field("recurringMethod"; Rec."Recurring Method") { }
                field("reversingEntry"; Rec."Reversing Entry") { }
                field("salesPurchLCY"; Rec."Sales/Purch. (LCY)") { }
                field("salespersPurchCode"; Rec."Salespers./Purch. Code") { }
                field("salvageValue"; Rec."Salvage Value") { }
                field("sellToBuyFromNo"; Rec."Sell-to/Buy-from No.") { }
                field("shipToOrderAddressCode"; Rec."Ship-to/Order Address Code") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("sourceCurrVATAmount"; Rec."Source Curr. VAT Amount") { }
                field("sourceCurrVATBaseAmount"; Rec."Source Curr. VAT Base Amount") { }
                field("sourceCurrencyAmount"; Rec."Source Currency Amount") { }
                field("sourceCurrencyCode"; Rec."Source Currency Code") { }
                field("sourceLineNo"; Rec."Source Line No.") { }
                field("sourceNo"; Rec."Source No.") { }
                field("sourceType"; Rec."Source Type") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionInformation"; Rec."Transaction Information") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("useTax"; Rec."Use Tax") { }
                field("vat"; Rec."VAT %") { }
                field("vatAmount"; Rec."VAT Amount") { }
                field("vatAmountLCY"; Rec."VAT Amount (LCY)") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBaseAmountLCY"; Rec."VAT Base Amount (LCY)") { }
                field("vatBaseBeforePmtDisc"; Rec."VAT Base Before Pmt. Disc.") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatDifference"; Rec."VAT Difference") { }
                field("vatPosting"; Rec."VAT Posting") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
            }
        }
    }
}

page 86529 "Hevo PurchInvHeader"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'purchaseInvoiceHeader';
    EntitySetName = 'purchaseInvoiceHeaders';
    Caption = 'purchaseInvoiceHeaders', Locked = true;
    SourceTable = "Purch. Inv. Header";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("area"; Rec."Area") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("buyFromAddress"; Rec."Buy-from Address") { }
                field("buyFromAddress2"; Rec."Buy-from Address 2") { }
                field("buyFromCity"; Rec."Buy-from City") { }
                field("buyFromContact"; Rec."Buy-from Contact") { }
                field("buyFromContactNo"; Rec."Buy-from Contact No.") { }
                field("buyFromCountryRegionCode"; Rec."Buy-from Country/Region Code") { }
                field("buyFromCounty"; Rec."Buy-from County") { }
                field("buyFromPostCode"; Rec."Buy-from Post Code") { }
                field("buyFromVendorName"; Rec."Buy-from Vendor Name") { }
                field("buyFromVendorName2"; Rec."Buy-from Vendor Name 2") { }
                field("buyFromVendorNo"; Rec."Buy-from Vendor No.") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("cancelled"; Rec."Cancelled") { }
                field("closed"; Rec."Closed") { }
                field("comment"; Rec."Comment") { }
                field("correction"; Rec."Correction") { }
                field("corrective"; Rec."Corrective") { }
                field("creditorNo"; Rec."Creditor No.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentDate"; Rec."Document Date") { }
                field("draftInvoiceSystemId"; Rec."Draft Invoice SystemId") { }
                field("dueDate"; Rec."Due Date") { }
                field("entryPoint"; Rec."Entry Point") { }
                field("expectedReceiptDate"; Rec."Expected Receipt Date") { }
                field("formatRegion"; Rec."Format Region") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("invoiceDiscountAmount"; Rec."Invoice Discount Amount") { }
                field("languageCode"; Rec."Language Code") { }
                field("locationCode"; Rec."Location Code") { }
                field("no"; Rec."No.") { }
                field("noPrinted"; Rec."No. Printed") { }
                field("noSeries"; Rec."No. Series") { }
                field("onHold"; Rec."On Hold") { }
                field("orderAddressCode"; Rec."Order Address Code") { }
                field("orderDate"; Rec."Order Date") { }
                field("orderNo"; Rec."Order No.") { }
                field("orderNoSeries"; Rec."Order No. Series") { }
                field("payToAddress"; Rec."Pay-to Address") { }
                field("payToAddress2"; Rec."Pay-to Address 2") { }
                field("payToCity"; Rec."Pay-to City") { }
                field("payToContact"; Rec."Pay-to Contact") { }
                field("payToContactNo"; Rec."Pay-to Contact No.") { }
                field("payToCountryRegionCode"; Rec."Pay-to Country/Region Code") { }
                field("payToCounty"; Rec."Pay-to County") { }
                field("payToName"; Rec."Pay-to Name") { }
                field("payToName2"; Rec."Pay-to Name 2") { }
                field("payToPostCode"; Rec."Pay-to Post Code") { }
                field("payToVendorNo"; Rec."Pay-to Vendor No.") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentReference"; Rec."Payment Reference") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingDescription"; Rec."Posting Description") { }
                field("preAssignedNo"; Rec."Pre-Assigned No.") { }
                field("preAssignedNoSeries"; Rec."Pre-Assigned No. Series") { }
                field("prepaymentInvoice"; Rec."Prepayment Invoice") { }
                field("prepaymentNoSeries"; Rec."Prepayment No. Series") { }
                field("prepaymentOrderNo"; Rec."Prepayment Order No.") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("purchaserCode"; Rec."Purchaser Code") { }
                field("quoteNo"; Rec."Quote No.") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("remainingAmount"; Rec."Remaining Amount") { }
                field("remitToCode"; Rec."Remit-to Code") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("userID"; Rec."User ID") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCountryRegionCode"; Rec."VAT Country/Region Code") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("vatReportingDate"; Rec."VAT Reporting Date") { }
                field("vendorInvoiceNo"; Rec."Vendor Invoice No.") { }
                field("vendorLedgerEntryNo"; Rec."Vendor Ledger Entry No.") { }
                field("vendorOrderNo"; Rec."Vendor Order No.") { }
                field("vendorPostingGroup"; Rec."Vendor Posting Group") { }
                field("yourReference"; Rec."Your Reference") { }
            }
        }
    }
}

page 86530 "Hevo PurchInvLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'purchaseInvoiceLine';
    EntitySetName = 'purchaseInvoiceLines';
    Caption = 'purchaseInvoiceLines', Locked = true;
    SourceTable = "Purch. Inv. Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allocationAccountNo"; Rec."Allocation Account No.") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("applToItemEntry"; Rec."Appl.-to Item Entry") { }
                field("area"; Rec."Area") { }
                field("attachedToLineNo"; Rec."Attached to Line No.") { }
                field("binCode"; Rec."Bin Code") { }
                field("blanketOrderLineNo"; Rec."Blanket Order Line No.") { }
                field("blanketOrderNo"; Rec."Blanket Order No.") { }
                field("budgetedFANo"; Rec."Budgeted FA No.") { }
                field("buyFromVendorNo"; Rec."Buy-from Vendor No.") { }
                field("deferralCode"; Rec."Deferral Code") { }
                field("deprAcquisitionCost"; Rec."Depr. Acquisition Cost") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("directUnitCost"; Rec."Direct Unit Cost") { }
                field("documentNo"; Rec."Document No.") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("entryPoint"; Rec."Entry Point") { }
                field("expectedReceiptDate"; Rec."Expected Receipt Date") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("faPostingType"; Rec."FA Posting Type") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("icCrossReferenceNo"; Rec."IC Cross-Reference No.") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("icPartnerRefType"; Rec."IC Partner Ref. Type") { }
                field("icPartnerReference"; Rec."IC Partner Reference") { }
                field("indirectCost"; Rec."Indirect Cost %") { }
                field("insuranceNo"; Rec."Insurance No.") { }
                field("invDiscountAmount"; Rec."Inv. Discount Amount") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemReferenceType"; Rec."Item Reference Type") { }
                field("itemReferenceTypeNo"; Rec."Item Reference Type No.") { }
                field("itemReferenceUnitOfMeasure"; Rec."Item Reference Unit of Measure") { }
                field("jobCurrencyCode"; Rec."Job Currency Code") { }
                field("jobCurrencyFactor"; Rec."Job Currency Factor") { }
                field("jobLineAmount"; Rec."Job Line Amount") { }
                field("jobLineAmountLCY"; Rec."Job Line Amount (LCY)") { }
                field("jobLineDiscAmountLCY"; Rec."Job Line Disc. Amount (LCY)") { }
                field("jobLineDiscount"; Rec."Job Line Discount %") { }
                field("jobLineDiscountAmount"; Rec."Job Line Discount Amount") { }
                field("jobLineType"; Rec."Job Line Type") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("jobTotalPrice"; Rec."Job Total Price") { }
                field("jobTotalPriceLCY"; Rec."Job Total Price (LCY)") { }
                field("jobUnitPrice"; Rec."Job Unit Price") { }
                field("jobUnitPriceLCY"; Rec."Job Unit Price (LCY)") { }
                field("lineAmount"; Rec."Line Amount") { }
                field("lineDiscount"; Rec."Line Discount %") { }
                field("lineDiscountAmount"; Rec."Line Discount Amount") { }
                field("lineNo"; Rec."Line No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("maintenanceCode"; Rec."Maintenance Code") { }
                field("netWeight"; Rec."Net Weight") { }
                field("no"; Rec."No.") { }
                field("nonDeductibleVAT"; Rec."Non-Deductible VAT %") { }
                field("nonDeductibleVATAmount"; Rec."Non-Deductible VAT Amount") { }
                field("nonDeductibleVATBase"; Rec."Non-Deductible VAT Base") { }
                field("nonDeductibleVATDiff"; Rec."Non-Deductible VAT Diff.") { }
                field("nonstock"; Rec."Nonstock") { }
                field("operationNo"; Rec."Operation No.") { }
                field("orderLineNo"; Rec."Order Line No.") { }
                field("orderNo"; Rec."Order No.") { }
                field("overheadRate"; Rec."Overhead Rate") { }
                field("payToVendorNo"; Rec."Pay-to Vendor No.") { }
                field("pmtDiscountAmount"; Rec."Pmt. Discount Amount") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("prepaymentLine"; Rec."Prepayment Line") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("prodOrderLineNo"; Rec."Prod. Order Line No.") { }
                field("prodOrderNo"; Rec."Prod. Order No.") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("quantity"; Rec."Quantity") { }
                field("quantityBase"; Rec."Quantity (Base)") { }
                field("receiptLineNo"; Rec."Receipt Line No.") { }
                field("receiptNo"; Rec."Receipt No.") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("routingNo"; Rec."Routing No.") { }
                field("routingReferenceNo"; Rec."Routing Reference No.") { }
                field("salvageValue"; Rec."Salvage Value") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitCostLCY"; Rec."Unit Cost (LCY)") { }
                field("unitPriceLCY"; Rec."Unit Price (LCY)") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasure"; Rec."Unit of Measure") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("useTax"; Rec."Use Tax") { }
                field("vat"; Rec."VAT %") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatDifference"; Rec."VAT Difference") { }
                field("vatIdentifier"; Rec."VAT Identifier") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantCode"; Rec."Variant Code") { }
                field("vendorItemNo"; Rec."Vendor Item No.") { }
                field("workCenterNo"; Rec."Work Center No.") { }
            }
        }
    }
}

page 86531 "Hevo PurchRcptHeader"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'purchaseReceiptHeader';
    EntitySetName = 'purchaseReceiptHeaders';
    Caption = 'purchaseReceiptHeaders', Locked = true;
    SourceTable = "Purch. Rcpt. Header";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("area"; Rec."Area") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("buyFromAddress"; Rec."Buy-from Address") { }
                field("buyFromAddress2"; Rec."Buy-from Address 2") { }
                field("buyFromCity"; Rec."Buy-from City") { }
                field("buyFromContact"; Rec."Buy-from Contact") { }
                field("buyFromContactNo"; Rec."Buy-from Contact No.") { }
                field("buyFromCountryRegionCode"; Rec."Buy-from Country/Region Code") { }
                field("buyFromCounty"; Rec."Buy-from County") { }
                field("buyFromPostCode"; Rec."Buy-from Post Code") { }
                field("buyFromVendorName"; Rec."Buy-from Vendor Name") { }
                field("buyFromVendorName2"; Rec."Buy-from Vendor Name 2") { }
                field("buyFromVendorNo"; Rec."Buy-from Vendor No.") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("comment"; Rec."Comment") { }
                field("correction"; Rec."Correction") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentDate"; Rec."Document Date") { }
                field("dueDate"; Rec."Due Date") { }
                field("entryPoint"; Rec."Entry Point") { }
                field("expectedReceiptDate"; Rec."Expected Receipt Date") { }
                field("formatRegion"; Rec."Format Region") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("inboundWhseHandlingTime"; Rec."Inbound Whse. Handling Time") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("languageCode"; Rec."Language Code") { }
                field("leadTimeCalculation"; Rec."Lead Time Calculation") { }
                field("locationCode"; Rec."Location Code") { }
                field("no"; Rec."No.") { }
                field("noPrinted"; Rec."No. Printed") { }
                field("noSeries"; Rec."No. Series") { }
                field("onHold"; Rec."On Hold") { }
                field("orderAddressCode"; Rec."Order Address Code") { }
                field("orderDate"; Rec."Order Date") { }
                field("orderNo"; Rec."Order No.") { }
                field("orderNoSeries"; Rec."Order No. Series") { }
                field("payToAddress"; Rec."Pay-to Address") { }
                field("payToAddress2"; Rec."Pay-to Address 2") { }
                field("payToCity"; Rec."Pay-to City") { }
                field("payToContact"; Rec."Pay-to Contact") { }
                field("payToContactNo"; Rec."Pay-to Contact no.") { }
                field("payToCountryRegionCode"; Rec."Pay-to Country/Region Code") { }
                field("payToCounty"; Rec."Pay-to County") { }
                field("payToName"; Rec."Pay-to Name") { }
                field("payToName2"; Rec."Pay-to Name 2") { }
                field("payToPostCode"; Rec."Pay-to Post Code") { }
                field("payToVendorNo"; Rec."Pay-to Vendor No.") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingDescription"; Rec."Posting Description") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("promisedReceiptDate"; Rec."Promised Receipt Date") { }
                field("purchaserCode"; Rec."Purchaser Code") { }
                field("quoteNo"; Rec."Quote No.") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("requestedReceiptDate"; Rec."Requested Receipt Date") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("userID"; Rec."User ID") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCountryRegionCode"; Rec."VAT Country/Region Code") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("vendorOrderNo"; Rec."Vendor Order No.") { }
                field("vendorPostingGroup"; Rec."Vendor Posting Group") { }
                field("vendorShipmentNo"; Rec."Vendor Shipment No.") { }
                field("yourReference"; Rec."Your Reference") { }
            }
        }
    }
}

page 86532 "Hevo PurchRcptLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'purchaseReceiptLine';
    EntitySetName = 'purchaseReceiptLines';
    Caption = 'purchaseReceiptLines', Locked = true;
    SourceTable = "Purch. Rcpt. Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("applToItemEntry"; Rec."Appl.-to Item Entry") { }
                field("area"; Rec."Area") { }
                field("attachedToLineNo"; Rec."Attached to Line No.") { }
                field("binCode"; Rec."Bin Code") { }
                field("blanketOrderLineNo"; Rec."Blanket Order Line No.") { }
                field("blanketOrderNo"; Rec."Blanket Order No.") { }
                field("budgetedFANo"; Rec."Budgeted FA No.") { }
                field("buyFromVendorNo"; Rec."Buy-from Vendor No.") { }
                field("correction"; Rec."Correction") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("deprAcquisitionCost"; Rec."Depr. Acquisition Cost") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("directUnitCost"; Rec."Direct Unit Cost") { }
                field("documentId"; Rec."Document Id") { }
                field("documentNo"; Rec."Document No.") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("entryPoint"; Rec."Entry Point") { }
                field("expectedReceiptDate"; Rec."Expected Receipt Date") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("faPostingType"; Rec."FA Posting Type") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("icItemReferenceNo"; Rec."IC Item Reference No.") { }
                field("icPartnerRefType"; Rec."IC Partner Ref. Type") { }
                field("icPartnerReference"; Rec."IC Partner Reference") { }
                field("inboundWhseHandlingTime"; Rec."Inbound Whse. Handling Time") { }
                field("indirectCost"; Rec."Indirect Cost %") { }
                field("insuranceNo"; Rec."Insurance No.") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemChargeBaseAmount"; Rec."Item Charge Base Amount") { }
                field("itemRcptEntryNo"; Rec."Item Rcpt. Entry No.") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemReferenceType"; Rec."Item Reference Type") { }
                field("itemReferenceTypeNo"; Rec."Item Reference Type No.") { }
                field("itemReferenceUnitOfMeasure"; Rec."Item Reference Unit of Measure") { }
                field("jobCurrencyCode"; Rec."Job Currency Code") { }
                field("jobCurrencyFactor"; Rec."Job Currency Factor") { }
                field("jobLineAmount"; Rec."Job Line Amount") { }
                field("jobLineAmountLCY"; Rec."Job Line Amount (LCY)") { }
                field("jobLineDiscAmountLCY"; Rec."Job Line Disc. Amount (LCY)") { }
                field("jobLineDiscount"; Rec."Job Line Discount %") { }
                field("jobLineDiscountAmount"; Rec."Job Line Discount Amount") { }
                field("jobLineType"; Rec."Job Line Type") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("jobTotalPrice"; Rec."Job Total Price") { }
                field("jobTotalPriceLCY"; Rec."Job Total Price (LCY)") { }
                field("jobUnitPrice"; Rec."Job Unit Price") { }
                field("jobUnitPriceLCY"; Rec."Job Unit Price (LCY)") { }
                field("leadTimeCalculation"; Rec."Lead Time Calculation") { }
                field("lineDiscount"; Rec."Line Discount %") { }
                field("lineNo"; Rec."Line No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("maintenanceCode"; Rec."Maintenance Code") { }
                field("netWeight"; Rec."Net Weight") { }
                field("no"; Rec."No.") { }
                field("nonstock"; Rec."Nonstock") { }
                field("operationNo"; Rec."Operation No.") { }
                field("orderDate"; Rec."Order Date") { }
                field("orderLineNo"; Rec."Order Line No.") { }
                field("orderNo"; Rec."Order No.") { }
                field("overReceiptCode2"; Rec."Over-Receipt Code 2") { }
                field("overReceiptQuantity"; Rec."Over-Receipt Quantity") { }
                field("overheadRate"; Rec."Overhead Rate") { }
                field("payToVendorNo"; Rec."Pay-to Vendor No.") { }
                field("plannedReceiptDate"; Rec."Planned Receipt Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("prodOrderLineNo"; Rec."Prod. Order Line No.") { }
                field("prodOrderNo"; Rec."Prod. Order No.") { }
                field("promisedReceiptDate"; Rec."Promised Receipt Date") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyInvoicedBase"; Rec."Qty. Invoiced (Base)") { }
                field("qtyRcdNotInvoiced"; Rec."Qty. Rcd. Not Invoiced") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("quantity"; Rec."Quantity") { }
                field("quantityBase"; Rec."Quantity (Base)") { }
                field("quantityInvoiced"; Rec."Quantity Invoiced") { }
                field("requestedReceiptDate"; Rec."Requested Receipt Date") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("routingNo"; Rec."Routing No.") { }
                field("routingReferenceNo"; Rec."Routing Reference No.") { }
                field("salesOrderLineNo"; Rec."Sales Order Line No.") { }
                field("salesOrderNo"; Rec."Sales Order No.") { }
                field("salvageValue"; Rec."Salvage Value") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("specialOrderSalesLineNo"; Rec."Special Order Sales Line No.") { }
                field("specialOrderSalesNo"; Rec."Special Order Sales No.") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitCostLCY"; Rec."Unit Cost (LCY)") { }
                field("unitPriceLCY"; Rec."Unit Price (LCY)") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasure"; Rec."Unit of Measure") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("useTax"; Rec."Use Tax") { }
                field("vat"; Rec."VAT %") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantCode"; Rec."Variant Code") { }
                field("vendorItemNo"; Rec."Vendor Item No.") { }
                field("workCenterNo"; Rec."Work Center No.") { }
            }
        }
    }
}

page 86533 "Hevo PurchaseHeader"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'purchaseHeader';
    EntitySetName = 'purchaseHeaders';
    Caption = 'purchaseHeaders', Locked = true;
    SourceTable = "Purchase Header";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("aRcdNotInvExVATLCY"; Rec."A. Rcd. Not Inv. Ex. VAT (LCY)") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("amtRcdNotInvoicedLCY"; Rec."Amt. Rcd. Not Invoiced (LCY)") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("appliesToID"; Rec."Applies-to ID") { }
                field("area"; Rec."Area") { }
                field("assignedUserID"; Rec."Assigned User ID") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("buyFromAddress"; Rec."Buy-from Address") { }
                field("buyFromAddress2"; Rec."Buy-from Address 2") { }
                field("buyFromCity"; Rec."Buy-from City") { }
                field("buyFromContact"; Rec."Buy-from Contact") { }
                field("buyFromContactNo"; Rec."Buy-from Contact No.") { }
                field("buyFromCountryRegionCode"; Rec."Buy-from Country/Region Code") { }
                field("buyFromCounty"; Rec."Buy-from County") { }
                field("buyFromICPartnerCode"; Rec."Buy-from IC Partner Code") { }
                field("buyFromPostCode"; Rec."Buy-from Post Code") { }
                field("buyFromVendorName"; Rec."Buy-from Vendor Name") { }
                field("buyFromVendorName2"; Rec."Buy-from Vendor Name 2") { }
                field("buyFromVendorNo"; Rec."Buy-from Vendor No.") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("comment"; Rec."Comment") { }
                field("completelyReceived"; Rec."Completely Received") { }
                field("compressPrepayment"; Rec."Compress Prepayment") { }
                field("correction"; Rec."Correction") { }
                field("creditorNo"; Rec."Creditor No.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("docNoOccurrence"; Rec."Doc. No. Occurrence") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentType"; Rec."Document Type") { }
                field("dueDate"; Rec."Due Date") { }
                field("entryPoint"; Rec."Entry Point") { }
                field("expectedReceiptDate"; Rec."Expected Receipt Date") { }
                field("formatRegion"; Rec."Format Region") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("icDirection"; Rec."IC Direction") { }
                field("icReferenceDocumentNo"; Rec."IC Reference Document No.") { }
                field("icStatus"; Rec."IC Status") { }
                field("inboundWhseHandlingTime"; Rec."Inbound Whse. Handling Time") { }
                field("incomingDocumentEntryNo"; Rec."Incoming Document Entry No.") { }
                field("invoice"; Rec."Invoice") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("invoiceDiscountAmount"; Rec."Invoice Discount Amount") { }
                field("invoiceDiscountCalculation"; Rec."Invoice Discount Calculation") { }
                field("invoiceDiscountValue"; Rec."Invoice Discount Value") { }
                field("invoiceReceivedDate"; Rec."Invoice Received Date") { }
                field("jobQueueEntryID"; Rec."Job Queue Entry ID") { }
                field("jobQueueStatus"; Rec."Job Queue Status") { }
                field("journalTemplName"; Rec."Journal Templ. Name") { }
                field("languageCode"; Rec."Language Code") { }
                field("lastPostingNo"; Rec."Last Posting No.") { }
                field("lastPrepaymentNo"; Rec."Last Prepayment No.") { }
                field("lastPrepmtCrMemoNo"; Rec."Last Prepmt. Cr. Memo No.") { }
                field("lastReceivingNo"; Rec."Last Receiving No.") { }
                field("lastReturnShipmentNo"; Rec."Last Return Shipment No.") { }
                field("leadTimeCalculation"; Rec."Lead Time Calculation") { }
                field("locationCode"; Rec."Location Code") { }
                field("no"; Rec."No.") { }
                field("noPrinted"; Rec."No. Printed") { }
                field("noSeries"; Rec."No. Series") { }
                field("noOfArchivedVersions"; Rec."No. of Archived Versions") { }
                field("onHold"; Rec."On Hold") { }
                field("orderAddressCode"; Rec."Order Address Code") { }
                field("orderClass"; Rec."Order Class") { }
                field("orderDate"; Rec."Order Date") { }
                field("partiallyInvoiced"; Rec."Partially Invoiced") { }
                field("payToAddress"; Rec."Pay-to Address") { }
                field("payToAddress2"; Rec."Pay-to Address 2") { }
                field("payToCity"; Rec."Pay-to City") { }
                field("payToContact"; Rec."Pay-to Contact") { }
                field("payToContactNo"; Rec."Pay-to Contact No.") { }
                field("payToCountryRegionCode"; Rec."Pay-to Country/Region Code") { }
                field("payToCounty"; Rec."Pay-to County") { }
                field("payToICPartnerCode"; Rec."Pay-to IC Partner Code") { }
                field("payToName"; Rec."Pay-to Name") { }
                field("payToName2"; Rec."Pay-to Name 2") { }
                field("payToPostCode"; Rec."Pay-to Post Code") { }
                field("payToVendorNo"; Rec."Pay-to Vendor No.") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentReference"; Rec."Payment Reference") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pendingApprovals"; Rec."Pending Approvals") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingDescription"; Rec."Posting Description") { }
                field("postingNo"; Rec."Posting No.") { }
                field("postingNoSeries"; Rec."Posting No. Series") { }
                field("postingFromWhseRef"; Rec."Posting from Whse. Ref.") { }
                field("prepayment"; Rec."Prepayment %") { }
                field("prepaymentDueDate"; Rec."Prepayment Due Date") { }
                field("prepaymentNo"; Rec."Prepayment No.") { }
                field("prepaymentNoSeries"; Rec."Prepayment No. Series") { }
                field("prepmtCrMemoNo"; Rec."Prepmt. Cr. Memo No.") { }
                field("prepmtCrMemoNoSeries"; Rec."Prepmt. Cr. Memo No. Series") { }
                field("prepmtPaymentDiscount"; Rec."Prepmt. Payment Discount %") { }
                field("prepmtPaymentTermsCode"; Rec."Prepmt. Payment Terms Code") { }
                field("prepmtPmtDiscountDate"; Rec."Prepmt. Pmt. Discount Date") { }
                field("prepmtPostingDescription"; Rec."Prepmt. Posting Description") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("printPostedDocuments"; Rec."Print Posted Documents") { }
                field("promisedReceiptDate"; Rec."Promised Receipt Date") { }
                field("purchaserCode"; Rec."Purchaser Code") { }
                field("quoteNo"; Rec."Quote No.") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("recalculateInvoiceDisc"; Rec."Recalculate Invoice Disc.") { }
                field("receive"; Rec."Receive") { }
                field("receivingNo"; Rec."Receiving No.") { }
                field("receivingNoSeries"; Rec."Receiving No. Series") { }
                field("remitToCode"; Rec."Remit-to Code") { }
                field("requestedReceiptDate"; Rec."Requested Receipt Date") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnShipmentNo"; Rec."Return Shipment No.") { }
                field("returnShipmentNoSeries"; Rec."Return Shipment No. Series") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("sendICDocument"; Rec."Send IC Document") { }
                field("ship"; Rec."Ship") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("status"; Rec."Status") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCountryRegionCode"; Rec."VAT Country/Region Code") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("vatReportingDate"; Rec."VAT Reporting Date") { }
                field("vendorAuthorizationNo"; Rec."Vendor Authorization No.") { }
                field("vendorCrMemoNo"; Rec."Vendor Cr. Memo No.") { }
                field("vendorInvoiceNo"; Rec."Vendor Invoice No.") { }
                field("vendorOrderNo"; Rec."Vendor Order No.") { }
                field("vendorPostingGroup"; Rec."Vendor Posting Group") { }
                field("vendorShipmentNo"; Rec."Vendor Shipment No.") { }
                field("yourReference"; Rec."Your Reference") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("locationFilter"; Rec."Location Filter") { }
            }
        }
    }
}

page 86534 "Hevo PurchaseLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'purchaseLine';
    EntitySetName = 'purchaseLines';
    Caption = 'purchaseLines', Locked = true;
    SourceTable = "Purchase Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("aRcdNotInvExVATLCY"; Rec."A. Rcd. Not Inv. Ex. VAT (LCY)") { }
                field("allocAccModifiedByUser"; Rec."Alloc. Acc. Modified by User") { }
                field("allocationAccountNo"; Rec."Allocation Account No.") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("allowItemChargeAssignment"; Rec."Allow Item Charge Assignment") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("amtRcdNotInvoiced"; Rec."Amt. Rcd. Not Invoiced") { }
                field("amtRcdNotInvoicedLCY"; Rec."Amt. Rcd. Not Invoiced (LCY)") { }
                field("applToItemEntry"; Rec."Appl.-to Item Entry") { }
                field("area"; Rec."Area") { }
                field("attachedDocCount"; Rec."Attached Doc Count") { }
                field("attachedLinesCount"; Rec."Attached Lines Count") { }
                field("attachedToLineNo"; Rec."Attached to Line No.") { }
                field("binCode"; Rec."Bin Code") { }
                field("blanketOrderLineNo"; Rec."Blanket Order Line No.") { }
                field("blanketOrderNo"; Rec."Blanket Order No.") { }
                field("budgetedFANo"; Rec."Budgeted FA No.") { }
                field("buyFromVendorNo"; Rec."Buy-from Vendor No.") { }
                field("completelyReceived"; Rec."Completely Received") { }
                field("copiedFromPostedDoc"; Rec."Copied From Posted Doc.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("deferralCode"; Rec."Deferral Code") { }
                field("deprAcquisitionCost"; Rec."Depr. Acquisition Cost") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("directUnitCost"; Rec."Direct Unit Cost") { }
                field("documentNo"; Rec."Document No.") { }
                field("documentType"; Rec."Document Type") { }
                field("dropShipment"; Rec."Drop Shipment") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("entryPoint"; Rec."Entry Point") { }
                field("expectedReceiptDate"; Rec."Expected Receipt Date") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("faPostingType"; Rec."FA Posting Type") { }
                field("finished"; Rec."Finished") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("icItemReferenceNo"; Rec."IC Item Reference No.") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("icPartnerRefType"; Rec."IC Partner Ref. Type") { }
                field("icPartnerReference"; Rec."IC Partner Reference") { }
                field("inboundWhseHandlingTime"; Rec."Inbound Whse. Handling Time") { }
                field("indirectCost"; Rec."Indirect Cost %") { }
                field("insuranceNo"; Rec."Insurance No.") { }
                field("invDiscAmountToInvoice"; Rec."Inv. Disc. Amount to Invoice") { }
                field("invDiscountAmount"; Rec."Inv. Discount Amount") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemChargeQtyToHandle"; Rec."Item Charge Qty. to Handle") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemReferenceType"; Rec."Item Reference Type") { }
                field("itemReferenceTypeNo"; Rec."Item Reference Type No.") { }
                field("itemReferenceUnitOfMeasure"; Rec."Item Reference Unit of Measure") { }
                field("jobCurrencyCode"; Rec."Job Currency Code") { }
                field("jobCurrencyFactor"; Rec."Job Currency Factor") { }
                field("jobLineAmount"; Rec."Job Line Amount") { }
                field("jobLineAmountLCY"; Rec."Job Line Amount (LCY)") { }
                field("jobLineDiscAmountLCY"; Rec."Job Line Disc. Amount (LCY)") { }
                field("jobLineDiscount"; Rec."Job Line Discount %") { }
                field("jobLineDiscountAmount"; Rec."Job Line Discount Amount") { }
                field("jobLineType"; Rec."Job Line Type") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobPlanningLineNo"; Rec."Job Planning Line No.") { }
                field("jobRemainingQty"; Rec."Job Remaining Qty.") { }
                field("jobRemainingQtyBase"; Rec."Job Remaining Qty. (Base)") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("jobTotalPrice"; Rec."Job Total Price") { }
                field("jobTotalPriceLCY"; Rec."Job Total Price (LCY)") { }
                field("jobUnitPrice"; Rec."Job Unit Price") { }
                field("jobUnitPriceLCY"; Rec."Job Unit Price (LCY)") { }
                field("leadTimeCalculation"; Rec."Lead Time Calculation") { }
                field("lineAmount"; Rec."Line Amount") { }
                field("lineDiscount"; Rec."Line Discount %") { }
                field("lineDiscountAmount"; Rec."Line Discount Amount") { }
                field("lineNo"; Rec."Line No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("mpsOrder"; Rec."MPS Order") { }
                field("maintenanceCode"; Rec."Maintenance Code") { }
                field("netWeight"; Rec."Net Weight") { }
                field("no"; Rec."No.") { }
                field("nonDeductibleVAT"; Rec."Non-Deductible VAT %") { }
                field("nonDeductibleVATAmount"; Rec."Non-Deductible VAT Amount") { }
                field("nonDeductibleVATBase"; Rec."Non-Deductible VAT Base") { }
                field("nonDeductibleVATDiff"; Rec."Non-Deductible VAT Diff.") { }
                field("nonstock"; Rec."Nonstock") { }
                field("operationNo"; Rec."Operation No.") { }
                field("orderDate"; Rec."Order Date") { }
                field("orderLineNo"; Rec."Order Line No.") { }
                field("orderNo"; Rec."Order No.") { }
                field("outstandingAmount"; Rec."Outstanding Amount") { }
                field("outstandingAmountLCY"; Rec."Outstanding Amount (LCY)") { }
                field("outstandingAmtExVATLCY"; Rec."Outstanding Amt. Ex. VAT (LCY)") { }
                field("outstandingQtyBase"; Rec."Outstanding Qty. (Base)") { }
                field("outstandingQuantity"; Rec."Outstanding Quantity") { }
                field("overReceiptApprovalStatus"; Rec."Over-Receipt Approval Status") { }
                field("overReceiptCode"; Rec."Over-Receipt Code") { }
                field("overReceiptQuantity"; Rec."Over-Receipt Quantity") { }
                field("overheadRate"; Rec."Overhead Rate") { }
                field("payToVendorNo"; Rec."Pay-to Vendor No.") { }
                field("plannedReceiptDate"; Rec."Planned Receipt Date") { }
                field("planningFlexibility"; Rec."Planning Flexibility") { }
                field("pmtDiscountAmount"; Rec."Pmt. Discount Amount") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("prepayment"; Rec."Prepayment %") { }
                field("prepaymentAmount"; Rec."Prepayment Amount") { }
                field("prepaymentLine"; Rec."Prepayment Line") { }
                field("prepaymentTaxAreaCode"; Rec."Prepayment Tax Area Code") { }
                field("prepaymentTaxGroupCode"; Rec."Prepayment Tax Group Code") { }
                field("prepaymentTaxLiable"; Rec."Prepayment Tax Liable") { }
                field("prepaymentVAT"; Rec."Prepayment VAT %") { }
                field("prepaymentVATDifference"; Rec."Prepayment VAT Difference") { }
                field("prepaymentVATIdentifier"; Rec."Prepayment VAT Identifier") { }
                field("prepmtAmtDeducted"; Rec."Prepmt Amt Deducted") { }
                field("prepmtAmtToDeduct"; Rec."Prepmt Amt to Deduct") { }
                field("prepmtVATDiffDeducted"; Rec."Prepmt VAT Diff. Deducted") { }
                field("prepmtVATDiffToDeduct"; Rec."Prepmt VAT Diff. to Deduct") { }
                field("prepmtAmountInvLCY"; Rec."Prepmt. Amount Inv. (LCY)") { }
                field("prepmtAmountInvInclVAT"; Rec."Prepmt. Amount Inv. Incl. VAT") { }
                field("prepmtAmtInclVAT"; Rec."Prepmt. Amt. Incl. VAT") { }
                field("prepmtAmtInv"; Rec."Prepmt. Amt. Inv.") { }
                field("prepmtLineAmount"; Rec."Prepmt. Line Amount") { }
                field("prepmtNonDeductVATAmount"; Rec."Prepmt. Non-Deduct. VAT Amount") { }
                field("prepmtNonDeductVATBase"; Rec."Prepmt. Non-Deduct. VAT Base") { }
                field("prepmtPmtDiscountAmount"; Rec."Prepmt. Pmt. Discount Amount") { }
                field("prepmtVATAmountInvLCY"; Rec."Prepmt. VAT Amount Inv. (LCY)") { }
                field("prepmtVATBaseAmt"; Rec."Prepmt. VAT Base Amt.") { }
                field("prepmtVATCalcType"; Rec."Prepmt. VAT Calc. Type") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("prodOrderLineNo"; Rec."Prod. Order Line No.") { }
                field("prodOrderNo"; Rec."Prod. Order No.") { }
                field("profit"; Rec."Profit %") { }
                field("promisedReceiptDate"; Rec."Promised Receipt Date") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyAssigned"; Rec."Qty. Assigned") { }
                field("qtyInvoicedBase"; Rec."Qty. Invoiced (Base)") { }
                field("qtyRcdNotInvoiced"; Rec."Qty. Rcd. Not Invoiced") { }
                field("qtyRcdNotInvoicedBase"; Rec."Qty. Rcd. Not Invoiced (Base)") { }
                field("qtyReceivedBase"; Rec."Qty. Received (Base)") { }
                field("qtyRoundingPrecision"; Rec."Qty. Rounding Precision") { }
                field("qtyRoundingPrecisionBase"; Rec."Qty. Rounding Precision (Base)") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("qtyToAssign"; Rec."Qty. to Assign") { }
                field("qtyToInvoice"; Rec."Qty. to Invoice") { }
                field("qtyToInvoiceBase"; Rec."Qty. to Invoice (Base)") { }
                field("qtyToReceive"; Rec."Qty. to Receive") { }
                field("qtyToReceiveBase"; Rec."Qty. to Receive (Base)") { }
                field("quantity"; Rec."Quantity") { }
                field("quantityBase"; Rec."Quantity (Base)") { }
                field("quantityInvoiced"; Rec."Quantity Invoiced") { }
                field("quantityReceived"; Rec."Quantity Received") { }
                field("recalculateInvoiceDisc"; Rec."Recalculate Invoice Disc.") { }
                field("receiptLineNo"; Rec."Receipt Line No.") { }
                field("receiptNo"; Rec."Receipt No.") { }
                field("requestedReceiptDate"; Rec."Requested Receipt Date") { }
                field("reservedQtyBase"; Rec."Reserved Qty. (Base)") { }
                field("reservedQuantity"; Rec."Reserved Quantity") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("retQtyShpdNotInvdBase"; Rec."Ret. Qty. Shpd Not Invd.(Base)") { }
                field("returnQtyShipped"; Rec."Return Qty. Shipped") { }
                field("returnQtyShippedBase"; Rec."Return Qty. Shipped (Base)") { }
                field("returnQtyShippedNotInvd"; Rec."Return Qty. Shipped Not Invd.") { }
                field("returnQtyToShip"; Rec."Return Qty. to Ship") { }
                field("returnQtyToShipBase"; Rec."Return Qty. to Ship (Base)") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("returnShipmentLineNo"; Rec."Return Shipment Line No.") { }
                field("returnShipmentNo"; Rec."Return Shipment No.") { }
                field("returnShpdNotInvd"; Rec."Return Shpd. Not Invd.") { }
                field("returnShpdNotInvdLCY"; Rec."Return Shpd. Not Invd. (LCY)") { }
                field("returnsDeferralStartDate"; Rec."Returns Deferral Start Date") { }
                field("routingNo"; Rec."Routing No.") { }
                field("routingReferenceNo"; Rec."Routing Reference No.") { }
                field("safetyLeadTime"; Rec."Safety Lead Time") { }
                field("salesOrderLineNo"; Rec."Sales Order Line No.") { }
                field("salesOrderNo"; Rec."Sales Order No.") { }
                field("salvageValue"; Rec."Salvage Value") { }
                field("selectedAllocAccountNo"; Rec."Selected Alloc. Account No.") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("specialOrder"; Rec."Special Order") { }
                field("specialOrderSalesLineNo"; Rec."Special Order Sales Line No.") { }
                field("specialOrderSalesNo"; Rec."Special Order Sales No.") { }
                field("subtype"; Rec."Subtype") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitCostLCY"; Rec."Unit Cost (LCY)") { }
                field("unitPriceLCY"; Rec."Unit Price (LCY)") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasure"; Rec."Unit of Measure") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("useTax"; Rec."Use Tax") { }
                field("vat"; Rec."VAT %") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatDifference"; Rec."VAT Difference") { }
                field("vatIdentifier"; Rec."VAT Identifier") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantCode"; Rec."Variant Code") { }
                field("vendorItemNo"; Rec."Vendor Item No.") { }
                field("whseOutstandingQtyBase"; Rec."Whse. Outstanding Qty. (Base)") { }
                field("workCenterNo"; Rec."Work Center No.") { }
            }
        }
    }
}

page 86535 "Hevo ReasonCode"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'reasonCode';
    EntitySetName = 'reasonCodes';
    Caption = 'reasonCodes', Locked = true;
    SourceTable = "Reason Code";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("code"; Rec."Code") { }
                field("contractGainLossAmount"; Rec."Contract Gain/Loss Amount") { }
                field("description"; Rec."Description") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("dateFilter"; Rec."Date Filter") { }
            }
        }
    }
}

page 86536 "Hevo SalesCrMemoHeader"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesCreditMemoHeader';
    EntitySetName = 'salesCreditMemoHeaders';
    Caption = 'salesCreditMemoHeaders', Locked = true;
    SourceTable = "Sales Cr.Memo Header";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("area"; Rec."Area") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("billToAddress"; Rec."Bill-to Address") { }
                field("billToAddress2"; Rec."Bill-to Address 2") { }
                field("billToCity"; Rec."Bill-to City") { }
                field("billToContact"; Rec."Bill-to Contact") { }
                field("billToContactNo"; Rec."Bill-to Contact No.") { }
                field("billToCountryRegionCode"; Rec."Bill-to Country/Region Code") { }
                field("billToCounty"; Rec."Bill-to County") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("billToName"; Rec."Bill-to Name") { }
                field("billToName2"; Rec."Bill-to Name 2") { }
                field("billToPostCode"; Rec."Bill-to Post Code") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("cancelled"; Rec."Cancelled") { }
                field("comment"; Rec."Comment") { }
                field("companyBankAccountCode"; Rec."Company Bank Account Code") { }
                field("correction"; Rec."Correction") { }
                field("corrective"; Rec."Corrective") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("custLedgerEntryNo"; Rec."Cust. Ledger Entry No.") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPostingGroup"; Rec."Customer Posting Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("docExchOriginalIdentifier"; Rec."Doc. Exch. Original Identifier") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentExchangeIdentifier"; Rec."Document Exchange Identifier") { }
                field("documentExchangeStatus"; Rec."Document Exchange Status") { }
                field("draftCrMemoSystemId"; Rec."Draft Cr. Memo SystemId") { }
                field("dueDate"; Rec."Due Date") { }
                field("eu3PartyTrade"; Rec."EU 3-Party Trade") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("formatRegion"; Rec."Format Region") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("getReturnReceiptUsed"; Rec."Get Return Receipt Used") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("invoiceDiscountAmount"; Rec."Invoice Discount Amount") { }
                field("languageCode"; Rec."Language Code") { }
                field("locationCode"; Rec."Location Code") { }
                field("no"; Rec."No.") { }
                field("noPrinted"; Rec."No. Printed") { }
                field("noSeries"; Rec."No. Series") { }
                field("onHold"; Rec."On Hold") { }
                field("opportunityNo"; Rec."Opportunity No.") { }
                field("paid"; Rec."Paid") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingDescription"; Rec."Posting Description") { }
                field("preAssignedNo"; Rec."Pre-Assigned No.") { }
                field("preAssignedNoSeries"; Rec."Pre-Assigned No. Series") { }
                field("prepaymentCreditMemo"; Rec."Prepayment Credit Memo") { }
                field("prepaymentOrderNo"; Rec."Prepayment Order No.") { }
                field("prepmtCrMemoNoSeries"; Rec."Prepmt. Cr. Memo No. Series") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("rcvdFromCountRegionCode"; Rec."Rcvd.-from Count./Region Code") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("remainingAmount"; Rec."Remaining Amount") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnOrderNo"; Rec."Return Order No.") { }
                field("returnOrderNoSeries"; Rec."Return Order No. Series") { }
                field("salespersonCode"; Rec."Salesperson Code") { }
                field("sellToAddress"; Rec."Sell-to Address") { }
                field("sellToAddress2"; Rec."Sell-to Address 2") { }
                field("sellToCity"; Rec."Sell-to City") { }
                field("sellToContact"; Rec."Sell-to Contact") { }
                field("sellToContactNo"; Rec."Sell-to Contact No.") { }
                field("sellToCountryRegionCode"; Rec."Sell-to Country/Region Code") { }
                field("sellToCounty"; Rec."Sell-to County") { }
                field("sellToCustomerName"; Rec."Sell-to Customer Name") { }
                field("sellToCustomerName2"; Rec."Sell-to Customer Name 2") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("sellToEMail"; Rec."Sell-to E-Mail") { }
                field("sellToPhoneNo"; Rec."Sell-to Phone No.") { }
                field("sellToPostCode"; Rec."Sell-to Post Code") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shippingAgentCode"; Rec."Shipping Agent Code") { }
                field("shippingAgentServiceCode"; Rec."Shipping Agent Service Code") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("userID"; Rec."User ID") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCountryRegionCode"; Rec."VAT Country/Region Code") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("vatReportingDate"; Rec."VAT Reporting Date") { }
                field("workDescription"; Rec."Work Description") { }
                field("yourReference"; Rec."Your Reference") { }
            }
        }
    }
}

page 86537 "Hevo SalesCrMemoLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesCreditMemoLine';
    EntitySetName = 'salesCreditMemoLines';
    Caption = 'salesCreditMemoLines', Locked = true;
    SourceTable = "Sales Cr.Memo Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("applFromItemEntry"; Rec."Appl.-from Item Entry") { }
                field("applToItemEntry"; Rec."Appl.-to Item Entry") { }
                field("area"; Rec."Area") { }
                field("attachedToLineNo"; Rec."Attached to Line No.") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("binCode"; Rec."Bin Code") { }
                field("blanketOrderLineNo"; Rec."Blanket Order Line No.") { }
                field("blanketOrderNo"; Rec."Blanket Order No.") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("deferralCode"; Rec."Deferral Code") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentNo"; Rec."Document No.") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("icItemReferenceNo"; Rec."IC Item Reference No.") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("icPartnerRefType"; Rec."IC Partner Ref. Type") { }
                field("icPartnerReference"; Rec."IC Partner Reference") { }
                field("invDiscountAmount"; Rec."Inv. Discount Amount") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemReferenceType"; Rec."Item Reference Type") { }
                field("itemReferenceTypeNo"; Rec."Item Reference Type No.") { }
                field("itemReferenceUnitOfMeasure"; Rec."Item Reference Unit of Measure") { }
                field("jobContractEntryNo"; Rec."Job Contract Entry No.") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("lineAmount"; Rec."Line Amount") { }
                field("lineDiscount"; Rec."Line Discount %") { }
                field("lineDiscountAmount"; Rec."Line Discount Amount") { }
                field("lineDiscountCalculation"; Rec."Line Discount Calculation") { }
                field("lineNo"; Rec."Line No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("netWeight"; Rec."Net Weight") { }
                field("no"; Rec."No.") { }
                field("nonstock"; Rec."Nonstock") { }
                field("orderLineNo"; Rec."Order Line No.") { }
                field("orderNo"; Rec."Order No.") { }
                field("pmtDiscountAmount"; Rec."Pmt. Discount Amount") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("prepaymentLine"; Rec."Prepayment Line") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("quantity"; Rec."Quantity") { }
                field("quantityBase"; Rec."Quantity (Base)") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("returnReceiptLineNo"; Rec."Return Receipt Line No.") { }
                field("returnReceiptNo"; Rec."Return Receipt No.") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxCategory"; Rec."Tax Category") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitCostLCY"; Rec."Unit Cost (LCY)") { }
                field("unitPrice"; Rec."Unit Price") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasure"; Rec."Unit of Measure") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("vat"; Rec."VAT %") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatClauseCode"; Rec."VAT Clause Code") { }
                field("vatDifference"; Rec."VAT Difference") { }
                field("vatIdentifier"; Rec."VAT Identifier") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantCode"; Rec."Variant Code") { }
                field("workTypeCode"; Rec."Work Type Code") { }
            }
        }
    }
}

page 86538 "Hevo SalesHeader"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesHeader';
    EntitySetName = 'salesHeaders';
    Caption = 'salesHeaders', Locked = true;
    SourceTable = "Sales Header";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("amtShipNotInvLCY"; Rec."Amt. Ship. Not Inv. (LCY)") { }
                field("amtShipNotInvLCYBase"; Rec."Amt. Ship. Not Inv. (LCY) Base") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("appliesToID"; Rec."Applies-to ID") { }
                field("area"; Rec."Area") { }
                field("assignedUserID"; Rec."Assigned User ID") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("billToAddress"; Rec."Bill-to Address") { }
                field("billToAddress2"; Rec."Bill-to Address 2") { }
                field("billToCity"; Rec."Bill-to City") { }
                field("billToContact"; Rec."Bill-to Contact") { }
                field("billToContactNo"; Rec."Bill-to Contact No.") { }
                field("billToCountryRegionCode"; Rec."Bill-to Country/Region Code") { }
                field("billToCounty"; Rec."Bill-to County") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("billToCustomerTemplCode"; Rec."Bill-to Customer Templ. Code") { }
                field("billToICPartnerCode"; Rec."Bill-to IC Partner Code") { }
                field("billToName"; Rec."Bill-to Name") { }
                field("billToName2"; Rec."Bill-to Name 2") { }
                field("billToPostCode"; Rec."Bill-to Post Code") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("combineShipments"; Rec."Combine Shipments") { }
                field("comment"; Rec."Comment") { }
                field("companyBankAccountCode"; Rec."Company Bank Account Code") { }
                field("completelyShipped"; Rec."Completely Shipped") { }
                field("compressPrepayment"; Rec."Compress Prepayment") { }
                field("correction"; Rec."Correction") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPostingGroup"; Rec."Customer Posting Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("directDebitMandateID"; Rec."Direct Debit Mandate ID") { }
                field("docNoOccurrence"; Rec."Doc. No. Occurrence") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentType"; Rec."Document Type") { }
                field("dueDate"; Rec."Due Date") { }
                field("eu3PartyTrade"; Rec."EU 3-Party Trade") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("formatRegion"; Rec."Format Region") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("getShipmentUsed"; Rec."Get Shipment Used") { }
                field("icDirection"; Rec."IC Direction") { }
                field("icReferenceDocumentNo"; Rec."IC Reference Document No.") { }
                field("icStatus"; Rec."IC Status") { }
                field("incomingDocumentEntryNo"; Rec."Incoming Document Entry No.") { }
                field("invoice"; Rec."Invoice") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("invoiceDiscountAmount"; Rec."Invoice Discount Amount") { }
                field("invoiceDiscountCalculation"; Rec."Invoice Discount Calculation") { }
                field("invoiceDiscountValue"; Rec."Invoice Discount Value") { }
                field("isTest"; Rec."IsTest") { }
                field("jobQueueEntryID"; Rec."Job Queue Entry ID") { }
                field("jobQueueStatus"; Rec."Job Queue Status") { }
                field("journalTemplName"; Rec."Journal Templ. Name") { }
                field("languageCode"; Rec."Language Code") { }
                field("lastPostingNo"; Rec."Last Posting No.") { }
                field("lastPrepaymentNo"; Rec."Last Prepayment No.") { }
                field("lastPrepmtCrMemoNo"; Rec."Last Prepmt. Cr. Memo No.") { }
                field("lastReturnReceiptNo"; Rec."Last Return Receipt No.") { }
                field("lastShipmentDate"; Rec."Last Shipment Date") { }
                field("lastShippingNo"; Rec."Last Shipping No.") { }
                field("lateOrderShipping"; Rec."Late Order Shipping") { }
                field("locationCode"; Rec."Location Code") { }
                field("no"; Rec."No.") { }
                field("noPrinted"; Rec."No. Printed") { }
                field("noSeries"; Rec."No. Series") { }
                field("noOfArchivedVersions"; Rec."No. of Archived Versions") { }
                field("onHold"; Rec."On Hold") { }
                field("opportunityNo"; Rec."Opportunity No.") { }
                field("orderClass"; Rec."Order Class") { }
                field("orderDate"; Rec."Order Date") { }
                field("outboundWhseHandlingTime"; Rec."Outbound Whse. Handling Time") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentServiceSetID"; Rec."Payment Service Set ID") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingDescription"; Rec."Posting Description") { }
                field("postingNo"; Rec."Posting No.") { }
                field("postingNoSeries"; Rec."Posting No. Series") { }
                field("postingFromWhseRef"; Rec."Posting from Whse. Ref.") { }
                field("prepayment"; Rec."Prepayment %") { }
                field("prepaymentDueDate"; Rec."Prepayment Due Date") { }
                field("prepaymentNo"; Rec."Prepayment No.") { }
                field("prepaymentNoSeries"; Rec."Prepayment No. Series") { }
                field("prepmtCrMemoNo"; Rec."Prepmt. Cr. Memo No.") { }
                field("prepmtCrMemoNoSeries"; Rec."Prepmt. Cr. Memo No. Series") { }
                field("prepmtPaymentDiscount"; Rec."Prepmt. Payment Discount %") { }
                field("prepmtPaymentTermsCode"; Rec."Prepmt. Payment Terms Code") { }
                field("prepmtPmtDiscountDate"; Rec."Prepmt. Pmt. Discount Date") { }
                field("prepmtPostingDescription"; Rec."Prepmt. Posting Description") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("printPostedDocuments"; Rec."Print Posted Documents") { }
                field("promisedDeliveryDate"; Rec."Promised Delivery Date") { }
                field("quoteAccepted"; Rec."Quote Accepted") { }
                field("quoteAcceptedDate"; Rec."Quote Accepted Date") { }
                field("quoteNo"; Rec."Quote No.") { }
                field("quoteSentToCustomer"; Rec."Quote Sent to Customer") { }
                field("quoteValidUntilDate"; Rec."Quote Valid Until Date") { }
                field("rcvdFromCountRegionCode"; Rec."Rcvd.-from Count./Region Code") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("recalculateInvoiceDisc"; Rec."Recalculate Invoice Disc.") { }
                field("receive"; Rec."Receive") { }
                field("requestedDeliveryDate"; Rec."Requested Delivery Date") { }
                field("reserve"; Rec."Reserve") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnReceiptNo"; Rec."Return Receipt No.") { }
                field("returnReceiptNoSeries"; Rec."Return Receipt No. Series") { }
                field("salespersonCode"; Rec."Salesperson Code") { }
                field("sellToAddress"; Rec."Sell-to Address") { }
                field("sellToAddress2"; Rec."Sell-to Address 2") { }
                field("sellToCity"; Rec."Sell-to City") { }
                field("sellToContact"; Rec."Sell-to Contact") { }
                field("sellToContactNo"; Rec."Sell-to Contact No.") { }
                field("sellToCountryRegionCode"; Rec."Sell-to Country/Region Code") { }
                field("sellToCounty"; Rec."Sell-to County") { }
                field("sellToCustomerName"; Rec."Sell-to Customer Name") { }
                field("sellToCustomerName2"; Rec."Sell-to Customer Name 2") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("sellToCustomerTemplCode"; Rec."Sell-to Customer Templ. Code") { }
                field("sellToEMail"; Rec."Sell-to E-Mail") { }
                field("sellToICPartnerCode"; Rec."Sell-to IC Partner Code") { }
                field("sellToPhoneNo"; Rec."Sell-to Phone No.") { }
                field("sellToPostCode"; Rec."Sell-to Post Code") { }
                field("sendICDocument"; Rec."Send IC Document") { }
                field("ship"; Rec."Ship") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shipped"; Rec."Shipped") { }
                field("shippedNotInvoiced"; Rec."Shipped Not Invoiced") { }
                field("shippingAdvice"; Rec."Shipping Advice") { }
                field("shippingAgentCode"; Rec."Shipping Agent Code") { }
                field("shippingAgentServiceCode"; Rec."Shipping Agent Service Code") { }
                field("shippingNo"; Rec."Shipping No.") { }
                field("shippingNoSeries"; Rec."Shipping No. Series") { }
                field("shippingTime"; Rec."Shipping Time") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("status"; Rec."Status") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCountryRegionCode"; Rec."VAT Country/Region Code") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("vatReportingDate"; Rec."VAT Reporting Date") { }
                field("workDescription"; Rec."Work Description") { }
                field("yourReference"; Rec."Your Reference") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("locationFilter"; Rec."Location Filter") { }
            }
        }
    }
}

page 86539 "Hevo SalesInvoiceHeader"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesInvoiceHeader';
    EntitySetName = 'salesInvoiceHeaders';
    Caption = 'salesInvoiceHeaders', Locked = true;
    SourceTable = "Sales Invoice Header";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("area"; Rec."Area") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("billToAddress"; Rec."Bill-to Address") { }
                field("billToAddress2"; Rec."Bill-to Address 2") { }
                field("billToCity"; Rec."Bill-to City") { }
                field("billToContact"; Rec."Bill-to Contact") { }
                field("billToContactNo"; Rec."Bill-to Contact No.") { }
                field("billToCountryRegionCode"; Rec."Bill-to Country/Region Code") { }
                field("billToCounty"; Rec."Bill-to County") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("billToName"; Rec."Bill-to Name") { }
                field("billToName2"; Rec."Bill-to Name 2") { }
                field("billToPostCode"; Rec."Bill-to Post Code") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("cancelled"; Rec."Cancelled") { }
                field("closed"; Rec."Closed") { }
                field("comment"; Rec."Comment") { }
                field("companyBankAccountCode"; Rec."Company Bank Account Code") { }
                field("correction"; Rec."Correction") { }
                field("corrective"; Rec."Corrective") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("custLedgerEntryNo"; Rec."Cust. Ledger Entry No.") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPostingGroup"; Rec."Customer Posting Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("directDebitMandateID"; Rec."Direct Debit Mandate ID") { }
                field("docExchOriginalIdentifier"; Rec."Doc. Exch. Original Identifier") { }
                field("documentDate"; Rec."Document Date") { }
                field("documentExchangeIdentifier"; Rec."Document Exchange Identifier") { }
                field("documentExchangeStatus"; Rec."Document Exchange Status") { }
                field("draftInvoiceSystemId"; Rec."Draft Invoice SystemId") { }
                field("dueDate"; Rec."Due Date") { }
                field("eu3PartyTrade"; Rec."EU 3-Party Trade") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("formatRegion"; Rec."Format Region") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("getShipmentUsed"; Rec."Get Shipment Used") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("invoiceDiscountAmount"; Rec."Invoice Discount Amount") { }
                field("invoiceDiscountCalculation"; Rec."Invoice Discount Calculation") { }
                field("invoiceDiscountValue"; Rec."Invoice Discount Value") { }
                field("languageCode"; Rec."Language Code") { }
                field("locationCode"; Rec."Location Code") { }
                field("no"; Rec."No.") { }
                field("noPrinted"; Rec."No. Printed") { }
                field("noSeries"; Rec."No. Series") { }
                field("onHold"; Rec."On Hold") { }
                field("opportunityNo"; Rec."Opportunity No.") { }
                field("orderDate"; Rec."Order Date") { }
                field("orderNo"; Rec."Order No.") { }
                field("orderNoSeries"; Rec."Order No. Series") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentReference"; Rec."Payment Reference") { }
                field("paymentServiceSetID"; Rec."Payment Service Set ID") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingDescription"; Rec."Posting Description") { }
                field("preAssignedNo"; Rec."Pre-Assigned No.") { }
                field("preAssignedNoSeries"; Rec."Pre-Assigned No. Series") { }
                field("prepaymentInvoice"; Rec."Prepayment Invoice") { }
                field("prepaymentNoSeries"; Rec."Prepayment No. Series") { }
                field("prepaymentOrderNo"; Rec."Prepayment Order No.") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("quoteNo"; Rec."Quote No.") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("remainingAmount"; Rec."Remaining Amount") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("reversed"; Rec."Reversed") { }
                field("salespersonCode"; Rec."Salesperson Code") { }
                field("sellToAddress"; Rec."Sell-to Address") { }
                field("sellToAddress2"; Rec."Sell-to Address 2") { }
                field("sellToCity"; Rec."Sell-to City") { }
                field("sellToContact"; Rec."Sell-to Contact") { }
                field("sellToContactNo"; Rec."Sell-to Contact No.") { }
                field("sellToCountryRegionCode"; Rec."Sell-to Country/Region Code") { }
                field("sellToCounty"; Rec."Sell-to County") { }
                field("sellToCustomerName"; Rec."Sell-to Customer Name") { }
                field("sellToCustomerName2"; Rec."Sell-to Customer Name 2") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("sellToEMail"; Rec."Sell-to E-Mail") { }
                field("sellToPhoneNo"; Rec."Sell-to Phone No.") { }
                field("sellToPostCode"; Rec."Sell-to Post Code") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shippingAgentCode"; Rec."Shipping Agent Code") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("userID"; Rec."User ID") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCountryRegionCode"; Rec."VAT Country/Region Code") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("vatReportingDate"; Rec."VAT Reporting Date") { }
                field("workDescription"; Rec."Work Description") { }
                field("yourReference"; Rec."Your Reference") { }
            }
        }
    }
}

page 86540 "Hevo SalesInvoiceLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesInvoiceLine';
    EntitySetName = 'salesInvoiceLines';
    Caption = 'salesInvoiceLines', Locked = true;
    SourceTable = "Sales Invoice Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allocationAccountNo"; Rec."Allocation Account No.") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("applFromItemEntry"; Rec."Appl.-from Item Entry") { }
                field("applToItemEntry"; Rec."Appl.-to Item Entry") { }
                field("area"; Rec."Area") { }
                field("attachedToLineNo"; Rec."Attached to Line No.") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("binCode"; Rec."Bin Code") { }
                field("blanketOrderLineNo"; Rec."Blanket Order Line No.") { }
                field("blanketOrderNo"; Rec."Blanket Order No.") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("deferralCode"; Rec."Deferral Code") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentNo"; Rec."Document No.") { }
                field("dropShipment"; Rec."Drop Shipment") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("icItemReferenceNo"; Rec."IC Item Reference No.") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("icPartnerRefType"; Rec."IC Partner Ref. Type") { }
                field("icPartnerReference"; Rec."IC Partner Reference") { }
                field("invDiscountAmount"; Rec."Inv. Discount Amount") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemReferenceType"; Rec."Item Reference Type") { }
                field("itemReferenceTypeNo"; Rec."Item Reference Type No.") { }
                field("itemReferenceUnitOfMeasure"; Rec."Item Reference Unit of Measure") { }
                field("jobContractEntryNo"; Rec."Job Contract Entry No.") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("lineAmount"; Rec."Line Amount") { }
                field("lineDiscount"; Rec."Line Discount %") { }
                field("lineDiscountAmount"; Rec."Line Discount Amount") { }
                field("lineDiscountCalculation"; Rec."Line Discount Calculation") { }
                field("lineNo"; Rec."Line No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("netWeight"; Rec."Net Weight") { }
                field("no"; Rec."No.") { }
                field("nonstock"; Rec."Nonstock") { }
                field("orderLineNo"; Rec."Order Line No.") { }
                field("orderNo"; Rec."Order No.") { }
                field("pmtDiscountAmount"; Rec."Pmt. Discount Amount") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("prepaymentLine"; Rec."Prepayment Line") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("priceDescription"; Rec."Price description") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("quantity"; Rec."Quantity") { }
                field("quantityBase"; Rec."Quantity (Base)") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shipmentLineNo"; Rec."Shipment Line No.") { }
                field("shipmentNo"; Rec."Shipment No.") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxCategory"; Rec."Tax Category") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitCostLCY"; Rec."Unit Cost (LCY)") { }
                field("unitPrice"; Rec."Unit Price") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasure"; Rec."Unit of Measure") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("vat"; Rec."VAT %") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatClauseCode"; Rec."VAT Clause Code") { }
                field("vatDifference"; Rec."VAT Difference") { }
                field("vatIdentifier"; Rec."VAT Identifier") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantCode"; Rec."Variant Code") { }
                field("workTypeCode"; Rec."Work Type Code") { }
            }
        }
    }
}

page 86541 "Hevo SalesLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesLine';
    EntitySetName = 'salesLines';
    Caption = 'salesLines', Locked = true;
    SourceTable = "Sales Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("atoWhseOutstandingQty"; Rec."ATO Whse. Outstanding Qty.") { }
                field("atoWhseOutstdQtyBase"; Rec."ATO Whse. Outstd. Qty. (Base)") { }
                field("allocAccModifiedByUser"; Rec."Alloc. Acc. Modified by User") { }
                field("allocationAccountNo"; Rec."Allocation Account No.") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("allowItemChargeAssignment"; Rec."Allow Item Charge Assignment") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("amount"; Rec."Amount") { }
                field("amountIncludingVAT"; Rec."Amount Including VAT") { }
                field("applFromItemEntry"; Rec."Appl.-from Item Entry") { }
                field("applToItemEntry"; Rec."Appl.-to Item Entry") { }
                field("area"; Rec."Area") { }
                field("attachedDocCount"; Rec."Attached Doc Count") { }
                field("attachedLinesCount"; Rec."Attached Lines Count") { }
                field("attachedToLineNo"; Rec."Attached to Line No.") { }
                field("bomItemNo"; Rec."BOM Item No.") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("binCode"; Rec."Bin Code") { }
                field("blanketOrderLineNo"; Rec."Blanket Order Line No.") { }
                field("blanketOrderNo"; Rec."Blanket Order No.") { }
                field("completelyShipped"; Rec."Completely Shipped") { }
                field("copiedFromPostedDoc"; Rec."Copied From Posted Doc.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("deferralCode"; Rec."Deferral Code") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentNo"; Rec."Document No.") { }
                field("documentType"; Rec."Document Type") { }
                field("dropShipment"; Rec."Drop Shipment") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("icItemReferenceNo"; Rec."IC Item Reference No.") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("icPartnerRefType"; Rec."IC Partner Ref. Type") { }
                field("icPartnerReference"; Rec."IC Partner Reference") { }
                field("invDiscAmountToInvoice"; Rec."Inv. Disc. Amount to Invoice") { }
                field("invDiscountAmount"; Rec."Inv. Discount Amount") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemChargeQtyToHandle"; Rec."Item Charge Qty. to Handle") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemReferenceType"; Rec."Item Reference Type") { }
                field("itemReferenceTypeNo"; Rec."Item Reference Type No.") { }
                field("itemReferenceUnitOfMeasure"; Rec."Item Reference Unit of Measure") { }
                field("jobContractEntryNo"; Rec."Job Contract Entry No.") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("lineAmount"; Rec."Line Amount") { }
                field("lineDiscount"; Rec."Line Discount %") { }
                field("lineDiscountAmount"; Rec."Line Discount Amount") { }
                field("lineDiscountCalculation"; Rec."Line Discount Calculation") { }
                field("lineNo"; Rec."Line No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("netWeight"; Rec."Net Weight") { }
                field("no"; Rec."No.") { }
                field("nonstock"; Rec."Nonstock") { }
                field("originallyOrderedNo"; Rec."Originally Ordered No.") { }
                field("originallyOrderedVarCode"; Rec."Originally Ordered Var. Code") { }
                field("outOfStockSubstitution"; Rec."Out-of-Stock Substitution") { }
                field("outboundWhseHandlingTime"; Rec."Outbound Whse. Handling Time") { }
                field("outstandingAmount"; Rec."Outstanding Amount") { }
                field("outstandingAmountLCY"; Rec."Outstanding Amount (LCY)") { }
                field("outstandingQtyBase"; Rec."Outstanding Qty. (Base)") { }
                field("outstandingQuantity"; Rec."Outstanding Quantity") { }
                field("planned"; Rec."Planned") { }
                field("plannedDeliveryDate"; Rec."Planned Delivery Date") { }
                field("plannedShipmentDate"; Rec."Planned Shipment Date") { }
                field("pmtDiscountAmount"; Rec."Pmt. Discount Amount") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("prepayment"; Rec."Prepayment %") { }
                field("prepaymentAmount"; Rec."Prepayment Amount") { }
                field("prepaymentLine"; Rec."Prepayment Line") { }
                field("prepaymentTaxAreaCode"; Rec."Prepayment Tax Area Code") { }
                field("prepaymentTaxGroupCode"; Rec."Prepayment Tax Group Code") { }
                field("prepaymentTaxLiable"; Rec."Prepayment Tax Liable") { }
                field("prepaymentVAT"; Rec."Prepayment VAT %") { }
                field("prepaymentVATDifference"; Rec."Prepayment VAT Difference") { }
                field("prepaymentVATIdentifier"; Rec."Prepayment VAT Identifier") { }
                field("prepmtAmtDeducted"; Rec."Prepmt Amt Deducted") { }
                field("prepmtAmtToDeduct"; Rec."Prepmt Amt to Deduct") { }
                field("prepmtVATDiffDeducted"; Rec."Prepmt VAT Diff. Deducted") { }
                field("prepmtVATDiffToDeduct"; Rec."Prepmt VAT Diff. to Deduct") { }
                field("prepmtAmountInvLCY"; Rec."Prepmt. Amount Inv. (LCY)") { }
                field("prepmtAmountInvInclVAT"; Rec."Prepmt. Amount Inv. Incl. VAT") { }
                field("prepmtAmtInclVAT"; Rec."Prepmt. Amt. Incl. VAT") { }
                field("prepmtAmtInv"; Rec."Prepmt. Amt. Inv.") { }
                field("prepmtLineAmount"; Rec."Prepmt. Line Amount") { }
                field("prepmtPmtDiscountAmount"; Rec."Prepmt. Pmt. Discount Amount") { }
                field("prepmtVATAmountInvLCY"; Rec."Prepmt. VAT Amount Inv. (LCY)") { }
                field("prepmtVATBaseAmt"; Rec."Prepmt. VAT Base Amt.") { }
                field("prepmtVATCalcType"; Rec."Prepmt. VAT Calc. Type") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("priceDescription"; Rec."Price description") { }
                field("profit"; Rec."Profit %") { }
                field("promisedDeliveryDate"; Rec."Promised Delivery Date") { }
                field("purchOrderLineNo"; Rec."Purch. Order Line No.") { }
                field("purchaseOrderNo"; Rec."Purchase Order No.") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyAssigned"; Rec."Qty. Assigned") { }
                field("qtyInvoicedBase"; Rec."Qty. Invoiced (Base)") { }
                field("qtyRoundingPrecision"; Rec."Qty. Rounding Precision") { }
                field("qtyRoundingPrecisionBase"; Rec."Qty. Rounding Precision (Base)") { }
                field("qtyShippedBase"; Rec."Qty. Shipped (Base)") { }
                field("qtyShippedNotInvdBase"; Rec."Qty. Shipped Not Invd. (Base)") { }
                field("qtyShippedNotInvoiced"; Rec."Qty. Shipped Not Invoiced") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("qtyToAsmToOrderBase"; Rec."Qty. to Asm. to Order (Base)") { }
                field("qtyToAssembleToOrder"; Rec."Qty. to Assemble to Order") { }
                field("qtyToAssign"; Rec."Qty. to Assign") { }
                field("qtyToInvoice"; Rec."Qty. to Invoice") { }
                field("qtyToInvoiceBase"; Rec."Qty. to Invoice (Base)") { }
                field("qtyToShip"; Rec."Qty. to Ship") { }
                field("qtyToShipBase"; Rec."Qty. to Ship (Base)") { }
                field("quantity"; Rec."Quantity") { }
                field("quantityBase"; Rec."Quantity (Base)") { }
                field("quantityInvoiced"; Rec."Quantity Invoiced") { }
                field("quantityShipped"; Rec."Quantity Shipped") { }
                field("recalculateInvoiceDisc"; Rec."Recalculate Invoice Disc.") { }
                field("requestedDeliveryDate"; Rec."Requested Delivery Date") { }
                field("reserve"; Rec."Reserve") { }
                field("reservedQtyBase"; Rec."Reserved Qty. (Base)") { }
                field("reservedQuantity"; Rec."Reserved Quantity") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("retQtyRcdNotInvdBase"; Rec."Ret. Qty. Rcd. Not Invd.(Base)") { }
                field("returnQtyRcdNotInvd"; Rec."Return Qty. Rcd. Not Invd.") { }
                field("returnQtyReceived"; Rec."Return Qty. Received") { }
                field("returnQtyReceivedBase"; Rec."Return Qty. Received (Base)") { }
                field("returnQtyToReceive"; Rec."Return Qty. to Receive") { }
                field("returnQtyToReceiveBase"; Rec."Return Qty. to Receive (Base)") { }
                field("returnRcdNotInvd"; Rec."Return Rcd. Not Invd.") { }
                field("returnRcdNotInvdLCY"; Rec."Return Rcd. Not Invd. (LCY)") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("returnReceiptLineNo"; Rec."Return Receipt Line No.") { }
                field("returnReceiptNo"; Rec."Return Receipt No.") { }
                field("returnsDeferralStartDate"; Rec."Returns Deferral Start Date") { }
                field("selectedAllocAccountNo"; Rec."Selected Alloc. Account No.") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shipmentLineNo"; Rec."Shipment Line No.") { }
                field("shipmentNo"; Rec."Shipment No.") { }
                field("shippedNotInvLCYNoVAT"; Rec."Shipped Not Inv. (LCY) No VAT") { }
                field("shippedNotInvoiced"; Rec."Shipped Not Invoiced") { }
                field("shippedNotInvoicedLCY"; Rec."Shipped Not Invoiced (LCY)") { }
                field("shippingAgentCode"; Rec."Shipping Agent Code") { }
                field("shippingAgentServiceCode"; Rec."Shipping Agent Service Code") { }
                field("shippingTime"; Rec."Shipping Time") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("specialOrder"; Rec."Special Order") { }
                field("specialOrderPurchLineNo"; Rec."Special Order Purch. Line No.") { }
                field("specialOrderPurchaseNo"; Rec."Special Order Purchase No.") { }
                field("substitutionAvailable"; Rec."Substitution Available") { }
                field("subtype"; Rec."Subtype") { }
                field("systemCreatedEntry"; Rec."System-Created Entry") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxCategory"; Rec."Tax Category") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitCostLCY"; Rec."Unit Cost (LCY)") { }
                field("unitPrice"; Rec."Unit Price") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasure"; Rec."Unit of Measure") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("vat"; Rec."VAT %") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatClauseCode"; Rec."VAT Clause Code") { }
                field("vatDifference"; Rec."VAT Difference") { }
                field("vatIdentifier"; Rec."VAT Identifier") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantCode"; Rec."Variant Code") { }
                field("whseOutstandingQty"; Rec."Whse. Outstanding Qty.") { }
                field("whseOutstandingQtyBase"; Rec."Whse. Outstanding Qty. (Base)") { }
                field("workTypeCode"; Rec."Work Type Code") { }
            }
        }
    }
}

page 86542 "Hevo SalesShipmentHeader"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesShipmentHeader';
    EntitySetName = 'salesShipmentHeaders';
    Caption = 'salesShipmentHeaders', Locked = true;
    SourceTable = "Sales Shipment Header";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("appliesToDocNo"; Rec."Applies-to Doc. No.") { }
                field("appliesToDocType"; Rec."Applies-to Doc. Type") { }
                field("area"; Rec."Area") { }
                field("balAccountNo"; Rec."Bal. Account No.") { }
                field("balAccountType"; Rec."Bal. Account Type") { }
                field("billToAddress"; Rec."Bill-to Address") { }
                field("billToAddress2"; Rec."Bill-to Address 2") { }
                field("billToCity"; Rec."Bill-to City") { }
                field("billToContact"; Rec."Bill-to Contact") { }
                field("billToContactNo"; Rec."Bill-to Contact No.") { }
                field("billToCountryRegionCode"; Rec."Bill-to Country/Region Code") { }
                field("billToCounty"; Rec."Bill-to County") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("billToName"; Rec."Bill-to Name") { }
                field("billToName2"; Rec."Bill-to Name 2") { }
                field("billToPostCode"; Rec."Bill-to Post Code") { }
                field("campaignNo"; Rec."Campaign No.") { }
                field("comment"; Rec."Comment") { }
                field("companyBankAccountCode"; Rec."Company Bank Account Code") { }
                field("correction"; Rec."Correction") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyFactor"; Rec."Currency Factor") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPostingGroup"; Rec."Customer Posting Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentDate"; Rec."Document Date") { }
                field("dueDate"; Rec."Due Date") { }
                field("eu3PartyTrade"; Rec."EU 3-Party Trade") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("externalDocumentNo"; Rec."External Document No.") { }
                field("formatRegion"; Rec."Format Region") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("languageCode"; Rec."Language Code") { }
                field("locationCode"; Rec."Location Code") { }
                field("no"; Rec."No.") { }
                field("noPrinted"; Rec."No. Printed") { }
                field("noSeries"; Rec."No. Series") { }
                field("onHold"; Rec."On Hold") { }
                field("opportunityNo"; Rec."Opportunity No.") { }
                field("orderDate"; Rec."Order Date") { }
                field("orderNo"; Rec."Order No.") { }
                field("orderNoSeries"; Rec."Order No. Series") { }
                field("outboundWhseHandlingTime"; Rec."Outbound Whse. Handling Time") { }
                field("paymentDiscount"; Rec."Payment Discount %") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("pmtDiscountDate"; Rec."Pmt. Discount Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingDescription"; Rec."Posting Description") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("promisedDeliveryDate"; Rec."Promised Delivery Date") { }
                field("quoteNo"; Rec."Quote No.") { }
                field("reasonCode"; Rec."Reason Code") { }
                field("requestedDeliveryDate"; Rec."Requested Delivery Date") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("salespersonCode"; Rec."Salesperson Code") { }
                field("sellToAddress"; Rec."Sell-to Address") { }
                field("sellToAddress2"; Rec."Sell-to Address 2") { }
                field("sellToCity"; Rec."Sell-to City") { }
                field("sellToContact"; Rec."Sell-to Contact") { }
                field("sellToContactNo"; Rec."Sell-to Contact No.") { }
                field("sellToCountryRegionCode"; Rec."Sell-to Country/Region Code") { }
                field("sellToCounty"; Rec."Sell-to County") { }
                field("sellToCustomerName"; Rec."Sell-to Customer Name") { }
                field("sellToCustomerName2"; Rec."Sell-to Customer Name 2") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("sellToEMail"; Rec."Sell-to E-Mail") { }
                field("sellToPhoneNo"; Rec."Sell-to Phone No.") { }
                field("sellToPostCode"; Rec."Sell-to Post Code") { }
                field("shipToAddress"; Rec."Ship-to Address") { }
                field("shipToAddress2"; Rec."Ship-to Address 2") { }
                field("shipToCity"; Rec."Ship-to City") { }
                field("shipToCode"; Rec."Ship-to Code") { }
                field("shipToContact"; Rec."Ship-to Contact") { }
                field("shipToCountryRegionCode"; Rec."Ship-to Country/Region Code") { }
                field("shipToCounty"; Rec."Ship-to County") { }
                field("shipToName"; Rec."Ship-to Name") { }
                field("shipToName2"; Rec."Ship-to Name 2") { }
                field("shipToPostCode"; Rec."Ship-to Post Code") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shippingAgentCode"; Rec."Shipping Agent Code") { }
                field("shippingAgentServiceCode"; Rec."Shipping Agent Service Code") { }
                field("shippingTime"; Rec."Shipping Time") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("sourceCode"; Rec."Source Code") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("userID"; Rec."User ID") { }
                field("vatBaseDiscount"; Rec."VAT Base Discount %") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCountryRegionCode"; Rec."VAT Country/Region Code") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("workDescription"; Rec."Work Description") { }
                field("yourReference"; Rec."Your Reference") { }
            }
        }
    }
}

page 86543 "Hevo SalesShipmentLine"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'salesShipmentLine';
    EntitySetName = 'salesShipmentLines';
    Caption = 'salesShipmentLines', Locked = true;
    SourceTable = "Sales Shipment Line";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("allowInvoiceDisc"; Rec."Allow Invoice Disc.") { }
                field("allowLineDisc"; Rec."Allow Line Disc.") { }
                field("applFromItemEntry"; Rec."Appl.-from Item Entry") { }
                field("applToItemEntry"; Rec."Appl.-to Item Entry") { }
                field("area"; Rec."Area") { }
                field("attachedToLineNo"; Rec."Attached to Line No.") { }
                field("authorizedForCreditCard"; Rec."Authorized for Credit Card") { }
                field("billToCustomerNo"; Rec."Bill-to Customer No.") { }
                field("binCode"; Rec."Bin Code") { }
                field("blanketOrderLineNo"; Rec."Blanket Order Line No.") { }
                field("blanketOrderNo"; Rec."Blanket Order No.") { }
                field("correction"; Rec."Correction") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("customerDiscGroup"; Rec."Customer Disc. Group") { }
                field("customerPriceGroup"; Rec."Customer Price Group") { }
                field("deprUntilFAPostingDate"; Rec."Depr. until FA Posting Date") { }
                field("depreciationBookCode"; Rec."Depreciation Book Code") { }
                field("description"; Rec."Description") { }
                field("description2"; Rec."Description 2") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("documentId"; Rec."Document Id") { }
                field("documentNo"; Rec."Document No.") { }
                field("dropShipment"; Rec."Drop Shipment") { }
                field("duplicateInDepreciationBook"; Rec."Duplicate in Depreciation Book") { }
                field("exitPoint"; Rec."Exit Point") { }
                field("faPostingDate"; Rec."FA Posting Date") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("genProdPostingGroup"; Rec."Gen. Prod. Posting Group") { }
                field("grossWeight"; Rec."Gross Weight") { }
                field("icItemReferenceNo"; Rec."IC Item Reference No.") { }
                field("icPartnerRefType"; Rec."IC Partner Ref. Type") { }
                field("icPartnerReference"; Rec."IC Partner Reference") { }
                field("itemCategoryCode"; Rec."Item Category Code") { }
                field("itemChargeBaseAmount"; Rec."Item Charge Base Amount") { }
                field("itemReferenceNo"; Rec."Item Reference No.") { }
                field("itemReferenceType"; Rec."Item Reference Type") { }
                field("itemReferenceTypeNo"; Rec."Item Reference Type No.") { }
                field("itemReferenceUnitOfMeasure"; Rec."Item Reference Unit of Measure") { }
                field("itemShptEntryNo"; Rec."Item Shpt. Entry No.") { }
                field("jobContractEntryNo"; Rec."Job Contract Entry No.") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("lineDiscount"; Rec."Line Discount %") { }
                field("lineNo"; Rec."Line No.") { }
                field("locationCode"; Rec."Location Code") { }
                field("netWeight"; Rec."Net Weight") { }
                field("no"; Rec."No.") { }
                field("nonstock"; Rec."Nonstock") { }
                field("orderLineNo"; Rec."Order Line No.") { }
                field("orderNo"; Rec."Order No.") { }
                field("outboundWhseHandlingTime"; Rec."Outbound Whse. Handling Time") { }
                field("plannedDeliveryDate"; Rec."Planned Delivery Date") { }
                field("plannedShipmentDate"; Rec."Planned Shipment Date") { }
                field("postingDate"; Rec."Posting Date") { }
                field("postingGroup"; Rec."Posting Group") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("promisedDeliveryDate"; Rec."Promised Delivery Date") { }
                field("purchOrderLineNo"; Rec."Purch. Order Line No.") { }
                field("purchaseOrderNo"; Rec."Purchase Order No.") { }
                field("purchasingCode"; Rec."Purchasing Code") { }
                field("qtyInvoicedBase"; Rec."Qty. Invoiced (Base)") { }
                field("qtyShippedNotInvoiced"; Rec."Qty. Shipped Not Invoiced") { }
                field("qtyPerUnitOfMeasure"; Rec."Qty. per Unit of Measure") { }
                field("quantity"; Rec."Quantity") { }
                field("quantityBase"; Rec."Quantity (Base)") { }
                field("quantityInvoiced"; Rec."Quantity Invoiced") { }
                field("requestedDeliveryDate"; Rec."Requested Delivery Date") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("returnReasonCode"; Rec."Return Reason Code") { }
                field("sellToCustomerNo"; Rec."Sell-to Customer No.") { }
                field("shipmentDate"; Rec."Shipment Date") { }
                field("shippingTime"; Rec."Shipping Time") { }
                field("shortcutDimension1Code"; Rec."Shortcut Dimension 1 Code") { }
                field("shortcutDimension2Code"; Rec."Shortcut Dimension 2 Code") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxGroupCode"; Rec."Tax Group Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("transactionSpecification"; Rec."Transaction Specification") { }
                field("transactionType"; Rec."Transaction Type") { }
                field("transportMethod"; Rec."Transport Method") { }
                field("type"; Rec."Type") { }
                field("unitCost"; Rec."Unit Cost") { }
                field("unitCostLCY"; Rec."Unit Cost (LCY)") { }
                field("unitPrice"; Rec."Unit Price") { }
                field("unitVolume"; Rec."Unit Volume") { }
                field("unitOfMeasure"; Rec."Unit of Measure") { }
                field("unitOfMeasureCode"; Rec."Unit of Measure Code") { }
                field("unitsPerParcel"; Rec."Units per Parcel") { }
                field("useDuplicationList"; Rec."Use Duplication List") { }
                field("vat"; Rec."VAT %") { }
                field("vatBaseAmount"; Rec."VAT Base Amount") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatCalculationType"; Rec."VAT Calculation Type") { }
                field("vatProdPostingGroup"; Rec."VAT Prod. Posting Group") { }
                field("variantCode"; Rec."Variant Code") { }
                field("workTypeCode"; Rec."Work Type Code") { }
            }
        }
    }
}

page 86544 "Hevo ShipmentMethod"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'shipmentMethod';
    EntitySetName = 'shipmentMethods';
    Caption = 'shipmentMethods', Locked = true;
    SourceTable = "Shipment Method";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("code"; Rec."Code") { }
                field("description"; Rec."Description") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86545 "Hevo TimeSheetDetail"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'timeSheetDetail';
    EntitySetName = 'timeSheetDetails';
    Caption = 'timeSheetDetails', Locked = true;
    SourceTable = "Time Sheet Detail";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("assemblyOrderLineNo"; Rec."Assembly Order Line No.") { }
                field("assemblyOrderNo"; Rec."Assembly Order No.") { }
                field("causeOfAbsenceCode"; Rec."Cause of Absence Code") { }
                field("date"; Rec."Date") { }
                field("dimensionSetID"; Rec."Dimension Set ID") { }
                field("jobId"; Rec."Job Id") { }
                field("jobNo"; Rec."Job No.") { }
                field("jobTaskNo"; Rec."Job Task No.") { }
                field("lastModifiedDateTime"; Rec."Last Modified DateTime") { }
                field("posted"; Rec."Posted") { }
                field("postedQuantity"; Rec."Posted Quantity") { }
                field("quantity"; Rec."Quantity") { }
                field("resourceNo"; Rec."Resource No.") { }
                field("serviceOrderLineNo"; Rec."Service Order Line No.") { }
                field("serviceOrderNo"; Rec."Service Order No.") { }
                field("status"; Rec."Status") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("timeSheetLineNo"; Rec."Time Sheet Line No.") { }
                field("timeSheetNo"; Rec."Time Sheet No.") { }
                field("type"; Rec."Type") { }
            }
        }
    }
}

page 86546 "Hevo UnitOfMeasure"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'unitOfMeasure';
    EntitySetName = 'unitsOfMeasure';
    Caption = 'unitsOfMeasure', Locked = true;
    SourceTable = "Unit of Measure";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("code"; Rec."Code") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("description"; Rec."Description") { }
                field("internationalStandardCode"; Rec."International Standard Code") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("symbol"; Rec."Symbol") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
            }
        }
    }
}

page 86547 "Hevo Vendor"
{
    PageType = API;
    APIPublisher = 'hevo';
    APIGroup = 'businessCentral';
    APIVersion = 'v1.0';
    EntityName = 'vendor';
    EntitySetName = 'vendors';
    Caption = 'vendors', Locked = true;
    SourceTable = "Vendor";
    ODataKeyFields = SystemId;
    DataAccessIntent = ReadOnly;
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;

    layout
    {
        area(Content)
        {
            repeater(Records)
            {
                field("systemId"; Rec."SystemId") { }
                field("address"; Rec."Address") { }
                field("address2"; Rec."Address 2") { }
                field("allowMultiplePostingGroups"; Rec."Allow Multiple Posting Groups") { }
                field("amtRcdNotInvoiced"; Rec."Amt. Rcd. Not Invoiced") { }
                field("amtRcdNotInvoicedLCY"; Rec."Amt. Rcd. Not Invoiced (LCY)") { }
                field("applicationMethod"; Rec."Application Method") { }
                field("balance"; Rec."Balance") { }
                field("balanceLCY"; Rec."Balance (LCY)") { }
                field("balanceDue"; Rec."Balance Due") { }
                field("balanceDueLCY"; Rec."Balance Due (LCY)") { }
                field("baseCalendarCode"; Rec."Base Calendar Code") { }
                field("blockPaymentTolerance"; Rec."Block Payment Tolerance") { }
                field("blocked"; Rec."Blocked") { }
                field("budgetedAmount"; Rec."Budgeted Amount") { }
                field("buyFromNoOfArchivedDoc"; Rec."Buy-from No. Of Archived Doc.") { }
                field("cashFlowPaymentTermsCode"; Rec."Cash Flow Payment Terms Code") { }
                field("city"; Rec."City") { }
                field("comment"; Rec."Comment") { }
                field("companySizeCode"; Rec."Company Size Code") { }
                field("contact"; Rec."Contact") { }
                field("countryRegionCode"; Rec."Country/Region Code") { }
                field("county"; Rec."County") { }
                field("coupledToDataverse"; Rec."Coupled to Dataverse") { }
                field("crMemoAmounts"; Rec."Cr. Memo Amounts") { }
                field("crMemoAmountsLCY"; Rec."Cr. Memo Amounts (LCY)") { }
                field("creditAmount"; Rec."Credit Amount") { }
                field("creditAmountLCY"; Rec."Credit Amount (LCY)") { }
                field("creditorNo"; Rec."Creditor No.") { }
                field("currencyCode"; Rec."Currency Code") { }
                field("currencyId"; Rec."Currency Id") { }
                field("debitAmount"; Rec."Debit Amount") { }
                field("debitAmountLCY"; Rec."Debit Amount (LCY)") { }
                field("disableSearchByName"; Rec."Disable Search by Name") { }
                field("documentSendingProfile"; Rec."Document Sending Profile") { }
                field("eMail"; Rec."E-Mail") { }
                field("eoriNumber"; Rec."EORI Number") { }
                field("excludeFromPmtPractices"; Rec."Exclude from Pmt. Practices") { }
                field("faxNo"; Rec."Fax No.") { }
                field("finChargeMemoAmountsLCY"; Rec."Fin. Charge Memo Amounts (LCY)") { }
                field("finChargeTermsCode"; Rec."Fin. Charge Terms Code") { }
                field("financeChargeMemoAmounts"; Rec."Finance Charge Memo Amounts") { }
                field("formatRegion"; Rec."Format Region") { }
                field("gln"; Rec."GLN") { }
                field("genBusPostingGroup"; Rec."Gen. Bus. Posting Group") { }
                field("globalDimension1Code"; Rec."Global Dimension 1 Code") { }
                field("globalDimension2Code"; Rec."Global Dimension 2 Code") { }
                field("icPartnerCode"; Rec."IC Partner Code") { }
                field("image"; Rec."Image") { }
                field("intrastatPartnerType"; Rec."Intrastat Partner Type") { }
                field("invAmountsLCY"; Rec."Inv. Amounts (LCY)") { }
                field("invDiscountsLCY"; Rec."Inv. Discounts (LCY)") { }
                field("invoiceAmounts"; Rec."Invoice Amounts") { }
                field("invoiceDiscCode"; Rec."Invoice Disc. Code") { }
                field("languageCode"; Rec."Language Code") { }
                field("lastDateModified"; Rec."Last Date Modified") { }
                field("lastModifiedDateTime"; Rec."Last Modified Date Time") { }
                field("leadTimeCalculation"; Rec."Lead Time Calculation") { }
                field("locationCode"; Rec."Location Code") { }
                field("mobilePhoneNo"; Rec."Mobile Phone No.") { }
                field("name"; Rec."Name") { }
                field("name2"; Rec."Name 2") { }
                field("netChange"; Rec."Net Change") { }
                field("netChangeLCY"; Rec."Net Change (LCY)") { }
                field("no"; Rec."No.") { }
                field("noSeries"; Rec."No. Series") { }
                field("noOfBlanketOrders"; Rec."No. of Blanket Orders") { }
                field("noOfCreditMemos"; Rec."No. of Credit Memos") { }
                field("noOfIncomingDocuments"; Rec."No. of Incoming Documents") { }
                field("noOfInvoices"; Rec."No. of Invoices") { }
                field("noOfOrderAddresses"; Rec."No. of Order Addresses") { }
                field("noOfOrders"; Rec."No. of Orders") { }
                field("noOfPstdCreditMemos"; Rec."No. of Pstd. Credit Memos") { }
                field("noOfPstdInvoices"; Rec."No. of Pstd. Invoices") { }
                field("noOfPstdReceipts"; Rec."No. of Pstd. Receipts") { }
                field("noOfPstdReturnShipments"; Rec."No. of Pstd. Return Shipments") { }
                field("noOfQuotes"; Rec."No. of Quotes") { }
                field("noOfReturnOrders"; Rec."No. of Return Orders") { }
                field("otherAmounts"; Rec."Other Amounts") { }
                field("otherAmountsLCY"; Rec."Other Amounts (LCY)") { }
                field("ourAccountNo"; Rec."Our Account No.") { }
                field("outstandingInvoices"; Rec."Outstanding Invoices") { }
                field("outstandingInvoicesLCY"; Rec."Outstanding Invoices (LCY)") { }
                field("outstandingOrders"; Rec."Outstanding Orders") { }
                field("outstandingOrdersLCY"; Rec."Outstanding Orders (LCY)") { }
                field("overReceiptCode"; Rec."Over-Receipt Code") { }
                field("partnerType"; Rec."Partner Type") { }
                field("payToNoOfArchivedDoc"; Rec."Pay-to No. Of Archived Doc.") { }
                field("payToNoOfBlanketOrders"; Rec."Pay-to No. of Blanket Orders") { }
                field("payToNoOfCreditMemos"; Rec."Pay-to No. of Credit Memos") { }
                field("payToNoOfInvoices"; Rec."Pay-to No. of Invoices") { }
                field("payToNoOfOrders"; Rec."Pay-to No. of Orders") { }
                field("payToNoOfPstdCrMemos"; Rec."Pay-to No. of Pstd. Cr. Memos") { }
                field("payToNoOfPstdInvoices"; Rec."Pay-to No. of Pstd. Invoices") { }
                field("payToNoOfPstdReceipts"; Rec."Pay-to No. of Pstd. Receipts") { }
                field("payToNoOfPstdReturnS"; Rec."Pay-to No. of Pstd. Return S.") { }
                field("payToNoOfQuotes"; Rec."Pay-to No. of Quotes") { }
                field("payToNoOfReturnOrders"; Rec."Pay-to No. of Return Orders") { }
                field("payToVendorNo"; Rec."Pay-to Vendor No.") { }
                field("paymentMethodCode"; Rec."Payment Method Code") { }
                field("paymentMethodId"; Rec."Payment Method Id") { }
                field("paymentTermsCode"; Rec."Payment Terms Code") { }
                field("paymentTermsId"; Rec."Payment Terms Id") { }
                field("payments"; Rec."Payments") { }
                field("paymentsLCY"; Rec."Payments (LCY)") { }
                field("phoneNo"; Rec."Phone No.") { }
                field("pmtDiscToleranceLCY"; Rec."Pmt. Disc. Tolerance (LCY)") { }
                field("pmtDiscountsLCY"; Rec."Pmt. Discounts (LCY)") { }
                field("pmtToleranceLCY"; Rec."Pmt. Tolerance (LCY)") { }
                field("postCode"; Rec."Post Code") { }
                field("preferredBankAccountCode"; Rec."Preferred Bank Account Code") { }
                field("prepayment"; Rec."Prepayment %") { }
                field("priceCalculationMethod"; Rec."Price Calculation Method") { }
                field("pricesIncludingVAT"; Rec."Prices Including VAT") { }
                field("primaryContactNo"; Rec."Primary Contact No.") { }
                field("priority"; Rec."Priority") { }
                field("privacyBlocked"; Rec."Privacy Blocked") { }
                field("purchaserCode"; Rec."Purchaser Code") { }
                field("purchasesLCY"; Rec."Purchases (LCY)") { }
                field("refunds"; Rec."Refunds") { }
                field("refundsLCY"; Rec."Refunds (LCY)") { }
                field("registrationNumber"; Rec."Registration Number") { }
                field("reminderAmounts"; Rec."Reminder Amounts") { }
                field("reminderAmountsLCY"; Rec."Reminder Amounts (LCY)") { }
                field("responsibilityCenter"; Rec."Responsibility Center") { }
                field("searchName"; Rec."Search Name") { }
                field("shipmentMethodCode"; Rec."Shipment Method Code") { }
                field("shippingAgentCode"; Rec."Shipping Agent Code") { }
                field("statisticsGroup"; Rec."Statistics Group") { }
                field("systemCreatedAt"; Rec."SystemCreatedAt") { }
                field("systemCreatedBy"; Rec."SystemCreatedBy") { }
                field("systemModifiedAt"; Rec."SystemModifiedAt") { }
                field("systemModifiedBy"; Rec."SystemModifiedBy") { }
                field("taxAreaCode"; Rec."Tax Area Code") { }
                field("taxLiable"; Rec."Tax Liable") { }
                field("telexAnswerBack"; Rec."Telex Answer Back") { }
                field("telexNo"; Rec."Telex No.") { }
                field("territoryCode"; Rec."Territory Code") { }
                field("vatBusPostingGroup"; Rec."VAT Bus. Posting Group") { }
                field("vatRegistrationNo"; Rec."VAT Registration No.") { }
                field("validateEUVatRegNo"; Rec."Validate EU Vat Reg. No.") { }
                field("vendorPostingGroup"; Rec."Vendor Posting Group") { }
                field("currencyFilter"; Rec."Currency Filter") { }
                field("dateFilter"; Rec."Date Filter") { }
                field("globalDimension1Filter"; Rec."Global Dimension 1 Filter") { }
                field("globalDimension2Filter"; Rec."Global Dimension 2 Filter") { }
            }
        }
    }
}

codeunit 86500 "Hevo Delete Subscribers"
{
    // One subscriber per table a page reads. OnAfterDeleteEvent fires for Delete and DeleteAll, with
    // or without triggers (RunTrigger is not a filter: posting deletes with triggers off), inside the
    // deleting transaction, so a tombstone exists exactly when the delete commits. The record's own
    // company is passed on, so a delete made through ChangeCompany is recorded in that company.
    Access = Internal;

    var
        DeleteCapture: Codeunit "Hevo Delete Capture";

    [EventSubscriber(ObjectType::Table, Database::"Bank Account", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete270(var Rec: Record "Bank Account"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Bank Account", 'bankAccounts', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Company Information", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete79(var Rec: Record "Company Information"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Company Information", 'companyInformation', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Contact", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete5050(var Rec: Record "Contact"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Contact", 'contacts', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Country/Region", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete9(var Rec: Record "Country/Region"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Country/Region", 'countriesRegions', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Currency", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete4(var Rec: Record "Currency"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Currency", 'currencies', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Currency Exchange Rate", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete330(var Rec: Record "Currency Exchange Rate"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Currency Exchange Rate", 'currencyExchangeRates', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Customer", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete18(var Rec: Record "Customer"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Customer", 'customers', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Default Dimension", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete352(var Rec: Record "Default Dimension"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Default Dimension", 'defaultDimensions', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Dimension", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete348(var Rec: Record "Dimension"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Dimension", 'dimensions', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Dimension Set Entry", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete480(var Rec: Record "Dimension Set Entry"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Dimension Set Entry", 'dimensionSetEntries', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Dimension Value", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete349(var Rec: Record "Dimension Value"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Dimension Value", 'dimensionValues', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Employee", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete5200(var Rec: Record "Employee"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Employee", 'employees', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"G/L Account", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete15(var Rec: Record "G/L Account"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"G/L Account", 'generalLedgerAccounts', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"G/L Entry", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete17(var Rec: Record "G/L Entry"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"G/L Entry", 'generalLedgerEntries', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Gen. Journal Batch", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete232(var Rec: Record "Gen. Journal Batch"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Gen. Journal Batch", 'generalJournalBatches', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Gen. Journal Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete81(var Rec: Record "Gen. Journal Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Gen. Journal Line", 'generalJournalLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Gen. Product Posting Group", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete251(var Rec: Record "Gen. Product Posting Group"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Gen. Product Posting Group", 'generalProductPostingGroups', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Inventory Posting Group", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete94(var Rec: Record "Inventory Posting Group"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Inventory Posting Group", 'inventoryPostingGroups', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Item", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete27(var Rec: Record "Item"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Item", 'items', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Item Category", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete5722(var Rec: Record "Item Category"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Item Category", 'itemCategories', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Item Ledger Entry", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete32(var Rec: Record "Item Ledger Entry"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Item Ledger Entry", 'itemLedgerEntries', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Item Variant", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete5401(var Rec: Record "Item Variant"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Item Variant", 'itemVariants', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Job", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete167(var Rec: Record "Job"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Job", 'jobs', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Location", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete14(var Rec: Record "Location"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Location", 'locations', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Opportunity", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete5092(var Rec: Record "Opportunity"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Opportunity", 'opportunities', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Payment Method", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete289(var Rec: Record "Payment Method"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Payment Method", 'paymentMethods', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Payment Terms", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete3(var Rec: Record "Payment Terms"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Payment Terms", 'paymentTerms', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Posted Gen. Journal Batch", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete182(var Rec: Record "Posted Gen. Journal Batch"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Posted Gen. Journal Batch", 'postedGeneralJournalBatch', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Posted Gen. Journal Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete181(var Rec: Record "Posted Gen. Journal Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Posted Gen. Journal Line", 'postedGeneralJournalLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Purch. Inv. Header", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete122(var Rec: Record "Purch. Inv. Header"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Purch. Inv. Header", 'purchaseInvoiceHeaders', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Purch. Inv. Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete123(var Rec: Record "Purch. Inv. Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Purch. Inv. Line", 'purchaseInvoiceLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Purch. Rcpt. Header", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete120(var Rec: Record "Purch. Rcpt. Header"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Purch. Rcpt. Header", 'purchaseReceiptHeaders', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Purch. Rcpt. Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete121(var Rec: Record "Purch. Rcpt. Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Purch. Rcpt. Line", 'purchaseReceiptLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Purchase Header", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete38(var Rec: Record "Purchase Header"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Purchase Header", 'purchaseHeaders', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Purchase Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete39(var Rec: Record "Purchase Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Purchase Line", 'purchaseLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Reason Code", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete231(var Rec: Record "Reason Code"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Reason Code", 'reasonCodes', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Cr.Memo Header", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete114(var Rec: Record "Sales Cr.Memo Header"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Cr.Memo Header", 'salesCreditMemoHeaders', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Cr.Memo Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete115(var Rec: Record "Sales Cr.Memo Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Cr.Memo Line", 'salesCreditMemoLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Header", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete36(var Rec: Record "Sales Header"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Header", 'salesHeaders', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Invoice Header", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete112(var Rec: Record "Sales Invoice Header"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Invoice Header", 'salesInvoiceHeaders', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Invoice Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete113(var Rec: Record "Sales Invoice Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Invoice Line", 'salesInvoiceLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete37(var Rec: Record "Sales Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Line", 'salesLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Shipment Header", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete110(var Rec: Record "Sales Shipment Header"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Shipment Header", 'salesShipmentHeaders', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Sales Shipment Line", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete111(var Rec: Record "Sales Shipment Line"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Sales Shipment Line", 'salesShipmentLines', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Shipment Method", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete10(var Rec: Record "Shipment Method"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Shipment Method", 'shipmentMethods', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Time Sheet Detail", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete952(var Rec: Record "Time Sheet Detail"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Time Sheet Detail", 'timeSheetDetails', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Unit of Measure", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete204(var Rec: Record "Unit of Measure"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Unit of Measure", 'unitsOfMeasure', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;

    [EventSubscriber(ObjectType::Table, Database::"Vendor", 'OnAfterDeleteEvent', '', false, false)]
    local procedure OnAfterDelete23(var Rec: Record "Vendor"; RunTrigger: Boolean)
    begin
        DeleteCapture.Capture(Database::"Vendor", 'vendors', Rec.CurrentCompany(), Rec.IsTemporary(), Rec.SystemId, Rec.SystemCreatedAt, Rec.SystemModifiedAt);
    end;
}

// ---- End of generated objects. ----
