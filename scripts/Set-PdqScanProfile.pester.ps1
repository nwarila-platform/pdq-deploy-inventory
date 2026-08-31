#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
# Pester spec for the complete scan-profile reconciler. The product executables are path-shaped
# functions; sqlite calls pass through to the local executable against exact 20.1.8.0 fixture
# schemas, so transaction and rollback behavior is exercised rather than mocked.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path:$PSScriptRoot -ChildPath:'Set-PdqScanProfile.ps1'
  $script:RealSqlite = @(Get-Command -Name:'sqlite3' -CommandType:'Application')[0].Source
  $script:Standard = Get-Content -LiteralPath:(
    Join-Path -Path:$PSScriptRoot -ChildPath:'../ansible/applications/pdq_inventory/files/scan-profiles/Standard.xml'
  ) -Raw
  $script:Awesome = Get-Content -LiteralPath:(
    Join-Path -Path:$PSScriptRoot -ChildPath:'../ansible/applications/pdq_inventory/files/scan-profiles/AwesomeScanProfile.xml'
  ) -Raw

  Function Invoke-TestSql {
    Param (
      [System.String] $Database,
      [System.String] $Statement
    )
    $Output = & $script:RealSqlite $Database $Statement
    If ($LASTEXITCODE -ne 0) {
      Throw ('fixture SQL exited {0}' -f $LASTEXITCODE)
    }
    $Output
  }

  Function New-ScanProfileText {
    Param (
      [System.String] $Name,
      [AllowEmptyString()]
      [System.String] $Description = '',
      [System.String[]] $Scanner = @('<Scanner><TypeName>Computer</TypeName><SourceScannerId value="700" /></Scanner>')
    )
    @"
<?xml version="1.0" encoding="utf-8"?>
<AdminArsenal.Export Code="PDQInventory" Name="PDQ Inventory" Version="20.1.8.0" MinimumVersion="19.0">
  <ScanProfile>
    <Collections type="list" />
    <Scanners type="list">$($Scanner -join '')</Scanners>
    <Description>$([System.Security.SecurityElement]::Escape($Description))</Description>
    <ScanProfileId value="999" />
    <Name>$([System.Security.SecurityElement]::Escape($Name))</Name>
    <ScanAs>Admin</ScanAs>
    <ScheduleTriggerSet name="ScheduleTriggers"><Triggers type="list" /></ScheduleTriggerSet>
  </ScanProfile>
</AdminArsenal.Export>
"@
  }

  Function New-TestEnvironment {
    $Root = Join-Path -Path:([System.IO.Path]::GetTempPath()) -ChildPath:('scan-profile-' + [System.Guid]::NewGuid())
    $Null = New-Item -ItemType:'Directory' -Path:$Root -Force
    $InventoryCli = Join-Path -Path:$Root -ChildPath:'PDQInventory.exe'
    $DeployCli = Join-Path -Path:$Root -ChildPath:'PDQDeploy.exe'
    $Sqlite = Join-Path -Path:$Root -ChildPath:'sqlite3.exe'
    $InventoryDatabase = Join-Path -Path:$Root -ChildPath:'Inventory.db'
    $DeployDatabase = Join-Path -Path:$Root -ChildPath:'Deploy.db'
    Set-Content -LiteralPath:$InventoryCli -Value:'stub' -NoNewline
    Set-Content -LiteralPath:$DeployCli -Value:'stub' -NoNewline
    Set-Content -LiteralPath:$Sqlite -Value:'stub' -NoNewline

    Invoke-TestSql -Database:$InventoryDatabase -Statement:@'
CREATE TABLE Scanners (ScannerId integer not null primary key autoincrement, Name);
CREATE TABLE FileScanners (ScannerId integer not null primary key autoincrement, DateCreated, DateModified, IncludePatterns, ExcludePatterns, RowLimit, FileScanType);
CREATE TABLE PowerShellScanners (ScannerId integer not null primary key autoincrement, Name, UID, Script, FileName, Parameters, AdditionalFiles, ModifiedDate, RowLimit);
CREATE TABLE RegistryScanners (ScannerId integer not null primary key autoincrement, Hive, IncludePattern, ExcludePattern, RowLimit);
CREATE TABLE WMIScanners (ScannerId integer not null primary key autoincrement, Name, Namespace, RowLimit, Timeout, WQL, UsePreferencesTimeout, ModifiedDate, WMIClassName);
CREATE TABLE ScheduleTriggers (ScheduleTriggerId integer not null primary key autoincrement, ScheduleTriggerSetId, StartDateTime, EndDateTimeIsEnabled, EndDateTime, IsEnabled, Description, Sequence, TriggerType, EnableTriggerStartTime, EnableTriggerEndTime, TriggerTimeFrameIsEnabled, TimeOfDay, Days, TimeSpan, DaysOfMonth, DaysOfWeek, MonthlyTriggerType, WeeksOfMonth, ScanAge, TimeOfDayIsEnabled);
CREATE TABLE ScheduleTriggerSets (ScheduleTriggerSetId integer not null primary key autoincrement);
CREATE TABLE ScanProfileCollections (ScanProfileCollectionId integer not null primary key autoincrement, ScanProfileId, CollectionId);
CREATE TABLE ScanProfileScanner (ScanProfileId, ScannerId, primary key (ScanProfileId, ScannerId));
CREATE TABLE ScanProfiles (ScanProfileId integer not null primary key autoincrement, ScheduleTriggerSetId, Name, Description, IsDefault, ScanAs);
CREATE TABLE ScannerFiles (ScannerId, FileId, primary key (ScannerId, FileId));
CREATE TABLE ScannerRegistryEntries (ScannerId, RegistryEntryId, primary key (ScannerId, RegistryEntryId));
CREATE TABLE ScanProfileComputers (ScanProfileComputerId integer primary key autoincrement, ScanProfileId, ComputerId, AttemptedScanDate, SuccessfulScanDate);
CREATE TABLE ComputerScans (ComputerScanId integer primary key autoincrement, ComputerId, ScanProfileId);
CREATE TABLE CustomTools (ComputerToolId integer primary key autoincrement, ScanProfileId);
CREATE TABLE RemoteCommands (RemoteCommandId integer primary key autoincrement, ScanProfileId);
CREATE TABLE RemoteCommandHistory (RemoteCommandHistoryId integer primary key autoincrement, ScanProfileId);
'@
    Invoke-TestSql -Database:$DeployDatabase -Statement:@'
CREATE TABLE Schedules (ScheduleId integer primary key autoincrement, InventoryScanProfileId);
CREATE TABLE Deployments (DeploymentId integer primary key autoincrement, InventoryScanProfileId);
CREATE TABLE ScanSteps (PackageStepId integer primary key autoincrement, InventoryScanProfileId);
CREATE TABLE PackageDefinitions (PackageDefinitionId integer primary key autoincrement, InventoryScanProfileId);
CREATE TABLE InventoryScanProfiles (InventoryScanProfileId integer primary key autoincrement, Name, IsDefault);
'@

    $global:FakeInventoryCli = $InventoryCli
    $global:FakeDeployCli = $DeployCli
    $global:FakeSqlite = $Sqlite
    $global:FakeInventoryDatabase = $InventoryDatabase
    $global:FakeDeployDatabase = $DeployDatabase
    $global:FakeRealSqlite = $script:RealSqlite
    $global:FakeProductCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeSqlStatements = [System.Collections.Generic.List[System.String]]::new()
    $global:LASTEXITCODE = 0

    New-Item -Force -Path:('function:global:' + $InventoryCli) -Value:{
      $global:FakeProductCalls.Add(('Inventory ' + ($args -join ' ')))
      Switch ($args[0]) {
        'SystemInfo' { "Database : $global:FakeInventoryDatabase"; $global:LASTEXITCODE = 0 }
        'GetAllScanProfiles' {
          & $global:FakeRealSqlite $global:FakeInventoryDatabase 'SELECT Name FROM ScanProfiles ORDER BY ScanProfileId;'
          $global:LASTEXITCODE = $LASTEXITCODE
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null
    New-Item -Force -Path:('function:global:' + $DeployCli) -Value:{
      $global:FakeProductCalls.Add(('Deploy ' + ($args -join ' ')))
      If ($args[0] -ceq 'SystemInfo') {
        "Database : $global:FakeDeployDatabase"
        $global:LASTEXITCODE = 0
      } Else {
        $global:LASTEXITCODE = 1
      }
    } | Out-Null
    New-Item -Force -Path:('function:global:' + $Sqlite) -Value:{
      $global:FakeSqlStatements.Add([System.String]$args[1])
      & $global:FakeRealSqlite @args
      $global:LASTEXITCODE = $LASTEXITCODE
    } | Out-Null

    [PSCustomObject]@{
      root               = $Root
      inventory_cli      = $InventoryCli
      deploy_cli         = $DeployCli
      sqlite             = $Sqlite
      inventory_database = $InventoryDatabase
      deploy_database    = $DeployDatabase
    }
  }

  Function Remove-TestEnvironment {
    Param ([PSCustomObject] $Environment)
    If ($Null -eq $Environment) {
      Return
    }
    Remove-Item -LiteralPath:('function:global:' + $Environment.inventory_cli) -Force -ErrorAction:'SilentlyContinue'
    Remove-Item -LiteralPath:('function:global:' + $Environment.deploy_cli) -Force -ErrorAction:'SilentlyContinue'
    Remove-Item -LiteralPath:('function:global:' + $Environment.sqlite) -Force -ErrorAction:'SilentlyContinue'
    Remove-Item -LiteralPath:$Environment.root -Recurse -Force -ErrorAction:'SilentlyContinue'
    Remove-Variable -Name:'Ansible', 'FakeInventoryCli', 'FakeDeployCli', 'FakeSqlite',
      'FakeInventoryDatabase', 'FakeDeployDatabase', 'FakeRealSqlite', 'FakeProductCalls',
      'FakeSqlStatements' -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
  }

  Function New-AnsibleContext {
    Param ([Switch] $CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Invoke-Reconciler {
    Param (
      [PSCustomObject] $Environment,
      [System.String[]] $Definition,
      [System.String[]] $BuiltIn = @(),
      [Switch] $WithDeploy,
      [Switch] $CheckMode
    )
    $Context = New-AnsibleContext -CheckMode:$CheckMode
    & $script:ScriptPath -Definition:$Definition -BuiltIn:$BuiltIn `
      -CliPath:$Environment.inventory_cli `
      -DeployCliPath:$(If ($WithDeploy) { $Environment.deploy_cli } Else { '' }) | Out-Null
    $Context
  }

  Function Add-BareProfile {
    Param (
      [PSCustomObject] $Environment,
      [System.String] $Name,
      [System.Int32] $ProfileId,
      [System.Int32] $ScannerId,
      [System.Int32] $IsDefault = 0,
      [System.String] $Description = ''
    )
    $SafeName = $Name.Replace("'", "''")
    $SafeDescription = $Description.Replace("'", "''")
    Invoke-TestSql -Database:$Environment.inventory_database -Statement:(
      "INSERT INTO ScheduleTriggerSets (ScheduleTriggerSetId) VALUES ($ProfileId); " +
      "INSERT INTO ScanProfiles VALUES ($ProfileId, $ProfileId, '$SafeName', '$SafeDescription', $IsDefault, 'Admin'); " +
      "INSERT OR IGNORE INTO Scanners (ScannerId, Name) VALUES ($ScannerId, 'Computer'); " +
      "INSERT INTO ScanProfileScanner VALUES ($ProfileId, $ScannerId);"
    )
  }
}

Describe 'Set-PdqScanProfile' {
  BeforeEach {
    $script:Environment = New-TestEnvironment
  }

  AfterEach {
    Remove-TestEnvironment -Environment:$script:Environment
  }

  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Attributes = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:ScriptPath, [ref]$Null, [ref]$Null
    ).ParamBlock.Attributes
    $Binding = $Attributes | Where-Object { $PSItem.TypeName.FullName -ceq 'CmdletBinding' }
    $Binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
  }

  It 'creates both real declarations and converges unchanged on the second run' {
    $First = Invoke-Reconciler -Environment:$script:Environment `
      -Definition:@($script:Standard, $script:Awesome) -BuiltIn:@('Standard')
    $First.Changed | Should -BeTrue
    Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:(
      "SELECT count(*) FROM ScanProfiles WHERE Name IN ('Standard','AwesomeScanProfile');"
    ) | Should -Be '2'
    Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:(
      "SELECT count(*) FROM ScanProfileScanner WHERE ScanProfileId = " +
      "(SELECT ScanProfileId FROM ScanProfiles WHERE Name = 'Standard');"
    ) | Should -Be '17'
    Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:(
      "SELECT count(*) FROM ScanProfileScanner WHERE ScanProfileId = " +
      "(SELECT ScanProfileId FROM ScanProfiles WHERE Name = 'AwesomeScanProfile');"
    ) | Should -Be '18'

    $Second = Invoke-Reconciler -Environment:$script:Environment `
      -Definition:@($script:Standard, $script:Awesome) -BuiltIn:@('Standard')
    $Second.Changed | Should -BeFalse
  }

  It 'ignores host ids, source ids, timestamps, and default status in the projection' {
    Invoke-Reconciler -Environment:$script:Environment -Definition:@($script:Standard) `
      -BuiltIn:@('Standard') | Out-Null
    Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:(
      "UPDATE ScanProfiles SET IsDefault = 1 WHERE Name = 'Standard';"
    ) | Out-Null
    $ChangedExclusions = $script:Standard.Replace('value="1"', 'value="9101"').
      Replace('value="33"', 'value="9133"').
      Replace('2026-08-28T18:50:26.0000000+00:00', '2030-01-01T00:00:00.0000000+00:00')
    $Result = Invoke-Reconciler -Environment:$script:Environment `
      -Definition:@($ChangedExclusions) -BuiltIn:@('Standard')
    $Result.Changed | Should -BeFalse
  }

  It 'treats an empty declaration description and database null as equal' {
    Invoke-Reconciler -Environment:$script:Environment -Definition:@($script:Awesome) | Out-Null
    Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:(
      "UPDATE ScanProfiles SET Description = NULL WHERE Name = 'AwesomeScanProfile';"
    ) | Out-Null
    (Invoke-Reconciler -Environment:$script:Environment -Definition:@($script:Awesome)).Changed |
      Should -BeFalse
  }

  It 'preserves two identical Files scanners as two rows' {
    $Files = @'
<Scanner><ExcludePatterns type="list" /><FileScanType>File</FileScanType><IncludePatterns type="list"><item>C:\TMP\*</item></IncludePatterns><IncludePatternText>C:\TMP\*</IncludePatternText><ExcludePatternText></ExcludePatternText><RowLimit value="2500" /><TypeName>Files</TypeName><SourceScannerId value="77" /><DateCreated>2030-01-01</DateCreated><DateModified>2030-01-01</DateModified></Scanner>
'@
    $Definition = New-ScanProfileText -Name:'Duplicate Files' -Scanner:@($Files, $Files)
    Invoke-Reconciler -Environment:$script:Environment -Definition:@($Definition) | Out-Null
    Invoke-TestSql -Database:$script:Environment.inventory_database `
      -Statement:'SELECT count(*) FROM FileScanners;' | Should -Be '2'
    (Invoke-Reconciler -Environment:$script:Environment -Definition:@($Definition)).Changed |
      Should -BeFalse
  }

  It 'retains a PowerShell scanner UID while applying changed scanner content' {
    Invoke-Reconciler -Environment:$script:Environment -Definition:@($script:Standard) `
      -BuiltIn:@('Standard') | Out-Null
    $ChangedScript = $script:Standard.Replace('(Get-Service WinMgmt).Status', '(Get-Service Winmgmt).Status')
    $Result = Invoke-Reconciler -Environment:$script:Environment -Definition:@($ChangedScript) `
      -BuiltIn:@('Standard')
    $Result.Changed | Should -BeTrue
    Invoke-TestSql -Database:$script:Environment.inventory_database `
      -Statement:"SELECT UID FROM PowerShellScanners;" |
      Should -Be 'f78186fbb92443c695571d0e6079c264'
  }

  It 'applies a declaration that is also listed as built in' {
    $Definition = New-ScanProfileText -Name:'Standard' -Description:'owned'
    $Result = Invoke-Reconciler -Environment:$script:Environment `
      -Definition:@($Definition) -BuiltIn:@('Standard')
    $Result.Changed | Should -BeTrue
    Invoke-TestSql -Database:$script:Environment.inventory_database `
      -Statement:"SELECT Description FROM ScanProfiles WHERE Name = 'Standard';" |
      Should -Be 'owned'
  }

  It 'refuses a removal referenced by Inventory CustomTools' {
    Add-BareProfile -Environment:$script:Environment -Name:'Stranger' -ProfileId:1 -ScannerId:1
    Invoke-TestSql -Database:$script:Environment.inventory_database `
      -Statement:'INSERT INTO CustomTools (ScanProfileId) VALUES (1);' | Out-Null
    { Invoke-Reconciler -Environment:$script:Environment -Definition:@() } |
      Should -Throw '*CustomTools*'
  }

  It 'refuses a removal referenced by Inventory RemoteCommands' {
    Add-BareProfile -Environment:$script:Environment -Name:'Stranger' -ProfileId:1 -ScannerId:1
    Invoke-TestSql -Database:$script:Environment.inventory_database `
      -Statement:'INSERT INTO RemoteCommands (ScanProfileId) VALUES (1);' | Out-Null
    { Invoke-Reconciler -Environment:$script:Environment -Definition:@() } |
      Should -Throw '*RemoteCommands*'
  }

  It 'refuses a removal referenced by a Deploy schedule' {
    Add-BareProfile -Environment:$script:Environment -Name:'Stranger' -ProfileId:1 -ScannerId:1
    Invoke-TestSql -Database:$script:Environment.deploy_database `
      -Statement:'INSERT INTO Schedules (InventoryScanProfileId) VALUES (1);' | Out-Null
    { Invoke-Reconciler -Environment:$script:Environment -Definition:@() -WithDeploy } |
      Should -Throw '*Schedules*'
  }

  It 'refuses to remove the default profile' {
    Add-BareProfile -Environment:$script:Environment -Name:'Stranger' -ProfileId:1 `
      -ScannerId:1 -IsDefault:1
    { Invoke-Reconciler -Environment:$script:Environment -Definition:@() } |
      Should -Throw '*default scan profile*'
  }

  It 'refuses to remove a profile whose scanner is shared' {
    Add-BareProfile -Environment:$script:Environment -Name:'Stranger' -ProfileId:1 -ScannerId:1
    Add-BareProfile -Environment:$script:Environment -Name:'Kept' -ProfileId:2 -ScannerId:1
    { Invoke-Reconciler -Environment:$script:Environment -Definition:@() -BuiltIn:@('Kept') } |
      Should -Throw '*also referenced by*Kept*'
  }

  It 'refuses an in-place apply whose scanner is shared' {
    Add-BareProfile -Environment:$script:Environment -Name:'Owned' -ProfileId:1 `
      -ScannerId:1 -Description:'old'
    Add-BareProfile -Environment:$script:Environment -Name:'Kept' -ProfileId:2 -ScannerId:1
    $Definition = New-ScanProfileText -Name:'Owned' -Description:'new'
    { Invoke-Reconciler -Environment:$script:Environment -Definition:@($Definition) `
        -BuiltIn:@('Kept') } | Should -Throw '*also referenced by*Kept*'
  }

  It 'rolls the whole reconciliation back when a later scanner write fails' {
    $Definition = New-ScanProfileText -Name:'Rollback'
    Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:@'
CREATE TRIGGER FailScanner BEFORE INSERT ON Scanners
BEGIN
  SELECT RAISE(ABORT, 'injected scanner failure');
END;
'@ | Out-Null
    $Before = Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:'.dump'
    $Context = New-AnsibleContext
    { & $script:ScriptPath -Definition:@($Definition) -BuiltIn:@() `
        -CliPath:$script:Environment.inventory_cli -DeployCliPath:'' } |
      Should -Throw '*injected scanner failure*'
    $After = Invoke-TestSql -Database:$script:Environment.inventory_database -Statement:'.dump'
    ($After -join "`n") | Should -BeExactly ($Before -join "`n")
    $Context.Result | Should -BeNullOrEmpty
  }

  It 'uses one immediate transaction for creations, updates, and removals together' {
    Add-BareProfile -Environment:$script:Environment -Name:'Remove Me' -ProfileId:1 -ScannerId:1
    $Definition = New-ScanProfileText -Name:'Create Me'
    Invoke-Reconciler -Environment:$script:Environment -Definition:@($Definition) | Out-Null
    $Transactions = @($global:FakeSqlStatements | Where-Object { $PSItem -match 'BEGIN IMMEDIATE' })
    $Transactions.Count | Should -Be 1
    ([Regex]::Matches($Transactions[0], 'BEGIN IMMEDIATE').Count) | Should -Be 1
    ([Regex]::Matches($Transactions[0], 'COMMIT;').Count) | Should -Be 1
    @($global:FakeProductCalls | Where-Object { $PSItem -match 'Inventory (?!SystemInfo|GetAllScanProfiles)' }).Count |
      Should -Be 0
  }

  It 'reports check-mode drift without opening a transaction' {
    $Definition = New-ScanProfileText -Name:'Check Mode'
    $Result = Invoke-Reconciler -Environment:$script:Environment -Definition:@($Definition) -CheckMode
    $Result.Changed | Should -BeTrue
    $Result.Result.check_mode | Should -BeTrue
    @($global:FakeSqlStatements | Where-Object { $PSItem -match 'BEGIN IMMEDIATE' }).Count |
      Should -Be 0
    Invoke-TestSql -Database:$script:Environment.inventory_database `
      -Statement:'SELECT count(*) FROM ScanProfiles;' | Should -Be '0'
  }
}
