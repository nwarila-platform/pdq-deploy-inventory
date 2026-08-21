#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqSetting.ps1 (org pair convention: every script ships
    with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg
    per pair).

    Runs anywhere, Linux CI included. The script drives two external programs
    at fixed paths, so this file registers FUNCTIONS named with those exact
    path strings: PowerShell's call operator resolves a path-shaped command to
    a function of that name before it looks for a file on disk, which is what
    lets the whole flow -- export, compare, write, re-export, verify -- run
    with no PDQ installed. The stubs also set $LASTEXITCODE, because a function
    does not, and the script reads it after every invocation.

    The export path is likewise a Windows string. The script reaches the file
    entirely through the PowerShell provider -- existence, read and delete --
    so each test mounts a C: drive over its own temporary directory and creates
    the Windows\Temp folder inside it. The Windows-shaped constant then
    resolves to a real file on any platform, and the stub writes exactly the
    file the script reads.

    Stub state lives in $global: variables because inside a function called
    from a child SCRIPT, $script: resolves to the child script's own scope, not
    this file's.

    $global:FakeSettings is the product's configuration. The export stub
    renders it as the product renders it -- an element per setting under its
    section, values on a `value` attribute -- and the write stubs mutate it,
    so a test states an outcome rather than a sequence of calls. A name listed
    in $global:FakeIgnored is accepted and NOT stored, which is the product's
    real and dangerous behaviour: it reports success for names it does not use.

    Both transports are asserted: the standalone JSON emission and the $Ansible
    path via the inline context below (pairs are self-contained; no imports).
    Its Changed defaults to $True exactly like win_powershell -- so every test
    proves the script SETS Changed rather than inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PdqSetting.ps1'
  # The context every call carries: where the database lives and what the share is called,
  # from which the script derives the repository path and the two beside-the-database
  # locations. The fake export is seeded to match, so derivation reads as unchanged and each
  # case still exercises exactly the settings it names.
  $script:Ctx = @{
    DatabaseDrive       = 'E'
    DatabaseDirectory   = 'PDQ Deploy'
    RepositoryShareName = 'AppRepo$'
  }

  # The three constants the script owns. Named here so a drift between the two
  # files fails the spec rather than silently testing nothing.
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
  $script:SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
  $script:ExportPath = 'C:\Windows\Temp\pdq-settings-export.xml'
  # Also global: Write-FakeExport runs inside a stub invoked from the child
  # script, where $script: resolves to that script's scope, not this file's.
  $global:FakeExportPath = $script:ExportPath
  $script:DatabasePath = 'E:\PDQ Deploy\Database.db'

  # Inline $Ansible stand-in (org contract: pairs are self-contained, no
  # imports). Faithful to win_powershell: Changed defaults to $True, and only
  # the ratified surface (Changed, CheckMode, Failed, Result) is modeled.
  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  # Renders $global:FakeSettings the way the product's export renders it: one
  # section element per dotted name, the leaf carrying a `value` attribute.
  # Sections whose name ends in ViewModel are emitted with the leaf one level
  # deeper, which is exactly the nesting that makes the script index a setting
  # under both its full path and its two-part name.
  Function global:Write-FakeExport {
    $Lines = [System.Collections.Generic.List[System.String]]::new()
    $Lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $Lines.Add('<AdminArsenal.Export Code="PDQDeploy" Name="PDQ Deploy" Version="20.1.8.0">')
    ForEach ($Name In ($global:FakeSettings.Keys | Sort-Object)) {
      $Parts = $Name -split '\.'
      $Value = [System.Security.SecurityElement]::Escape([System.String]$global:FakeSettings[$Name])
      If ($Parts[0] -eq 'AutoDeployDefaultSettings') {
        # Rendered the way the product nests it: a view model above the section,
        # so the leaf's full trail is three deep and only its last two
        # components match the command line's name. The section element carries a
        # 'name' ATTRIBUTE exactly as the product writes it: that attribute is what
        # PowerShell's XML adapter hands back in place of the tag when a walker asks
        # for .Name, which once cost this script every setting nested here.
        $Lines.Add('  <PackageLibrarySettingsViewModel>')
        $Lines.Add(('    <{0} name="{0}ViewModel">' -f $Parts[0]))
        $Lines.Add(('      <{0} value="{1}" />' -f $Parts[1], $Value))
        $Lines.Add(('    </{0}>' -f $Parts[0]))
        $Lines.Add('  </PackageLibrarySettingsViewModel>')
      } Else {
        $Lines.Add(('  <{0}>' -f $Parts[0]))
        $Lines.Add(('    <{0} value="{1}" />' -f $Parts[1], $Value))
        $Lines.Add(('  </{0}>' -f $Parts[0]))
      }
    }
    $Lines.Add('</AdminArsenal.Export>')
    Set-Content -LiteralPath $global:FakeExportPath -Value ($Lines -join "`n") -Encoding 'utf8'
  }
}

Describe 'Set-PdqSetting' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    # win_powershell SKIPS a script in check mode unless it advertises this, returning
    # changed=true and no result -- the exact spelling the module's own detector keys on.
    $Script = Get-Content -Raw (Join-Path $PSScriptRoot 'Set-PdqSetting.ps1')
    $Script | Should -Match '\[CmdletBinding\(SupportsShouldProcess'
  }


  BeforeEach {
    # Each test owns a directory, mounted as C: so the script's Windows-shaped
    # constant resolves to a real file on any platform. On Windows the drive
    # already exists and the mount is simply redundant.
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    $script:MountedDrive = $Null
    If (-not (Get-PSDrive -Name 'C' -ErrorAction 'SilentlyContinue')) {
      New-PSDrive -Name 'C' -PSProvider 'FileSystem' -Root $script:Sandbox -Scope 'Global' | Out-Null
      $script:MountedDrive = 'C'
    }
    New-Item -ItemType Directory -Path 'C:\Windows\Temp' -Force | Out-Null

    $env:COMPUTERNAME = 'TESTBOX'
    $global:FakeSettings = @{
      'DeploymentSettings.CleanupDays'                = '30'
      'PerformanceSettings.CopyMode'                  = 'Push'
      'RepositorySettings.Path'                       = '\\TESTBOX\AppRepo$'
      'DatabaseBackupSettings.BackupDirectory'        = 'E:\PDQ Deploy\Backups'
      'AuditLogSettings.VerboseFileDirectory'         = 'E:\PDQ Deploy\Logs'
      'AnalyticsSettings.CollectAnalyticsUsage'       = 'true'
      'AutoDeployDefaultSettings.ApprovalMode'        = 'Delayed'
    }
    $global:FakeIgnored = @()
    $global:FakeDbRows = @{}
    $global:FakeConsoleSessions = @()
    $global:FakeDrainStalls = $False
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeSqliteCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeExportFails = $False
    $global:FakeSystemInfoBlank = $False
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    # The product's command line. A path-shaped call resolves to this function.
    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      Switch ($args[0]) {
        'ExportSettings' {
          If ($global:FakeExportFails) { $global:LASTEXITCODE = 1; Return }
          Write-FakeExport
          $global:LASTEXITCODE = 0
        }
        'SystemInfo' {
          $global:LASTEXITCODE = 0
          If ($global:FakeSystemInfoBlank) { Return 'Version      : 20.1.8.0' }
          Return @('Database     : E:\PDQ Deploy\Database.db', 'Version      : 20.1.8.0')
        }
        'Settings' {
          # -Name <n> -Set <v>, or -Name <n> -Reset, which deletes the override
          # so the compiled default (blank, in this model) shows through. A name
          # the product does not use is accepted and discarded either way, which
          # is the whole reason the script verifies.
          # The real product stores a few families under a 'Product' prefix and
          # publishes them in the export without it; the fake mirrors that.
          $Name = $args[2] -replace '^ProductPrintingSettings\.', 'PrintingSettings.'
          # The row lands for ANY name -- the bogus-name control measured that -- and only the
          # EXPORT drops the ones the product does not read. A stalled fake models the queue.
          If ($args[3] -eq '-Reset') {
            $global:FakeDbRows.Remove($args[2])
          } ElseIf (-not $global:FakeDrainStalls) {
            $global:FakeDbRows[$args[2]] = $args[4]
          }
          If ($global:FakeIgnored -notcontains $Name) {
            If ($args[3] -eq '-Reset') {
              $global:FakeSettings[$Name] = ''
            } Else {
              $global:FakeSettings[$Name] = $args[4]
            }
          }
          $global:LASTEXITCODE = 0
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null

    # The sqlite tool. Only the repository system variable reaches it.
    New-Item -Force -Path ('function:global:' + $script:SqlitePath) -Value {
      $global:FakeSqliteCalls.Add($args -join ' ')
      If ($args[1] -match "SET Value = '(?<v>.*?)'") {
        $global:FakeSettings['RepositorySettings.Path'] = $Matches['v']
      }
      If ($args[1] -like 'SELECT Name, Value FROM Settings*') {
        ForEach ($K In @($global:FakeDbRows.Keys)) { '{0}|{1}' -f $K, $global:FakeDbRows[$K] }
      }
      If ($args[1] -like 'SELECT UserName FROM ConsoleUserSessions*') {
        $global:FakeConsoleSessions
      }
      $global:LASTEXITCODE = 0
    } | Out-Null
  }

  AfterEach {
    If ($script:MountedDrive) {
      Remove-PSDrive -Name $script:MountedDrive -Force -ErrorAction 'SilentlyContinue'
    }
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:CliPath) -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:SqlitePath) -Force -ErrorAction 'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name 'FakeSettings', 'FakeIgnored', 'FakeCliCalls', 'FakeSqliteCalls',
      'FakeExportFails', 'FakeSystemInfoBlank', 'FakeExportPath' -Scope 'Global' -Force `
      -ErrorAction 'SilentlyContinue'
  }

  Context 'the constants it owns' {

    It 'still names the paths this spec stubs' {
      $Source = Get-Content -LiteralPath $script:ScriptPath -Raw

      $Source | Should -BeLike ('*' + $script:CliPath + '*')
      $Source | Should -BeLike ('*' + $script:SqlitePath + '*')
      $Source | Should -BeLike ('*' + $script:ExportPath + '*')
    }
  }

  Context 'the table as the contract' {

    It 'refuses a name it does not carry, rather than storing a row nothing reads' {
      { & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_day' = 45 } } |
        Should -Throw -ExpectedMessage '*not a setting this script can apply*'

      @($global:FakeCliCalls).Count | Should -Be 0
    }

    It 'refuses a value of the wrong type before anything is read or written' {
      { & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 'soon' } } |
        Should -Throw -ExpectedMessage '*takes a Int32*'

      @($global:FakeCliCalls).Count | Should -Be 0
    }

    It 'refuses a value outside an enumerated setting' {
      { & $script:ScriptPath @script:Ctx -Preference @{ 'performance.copy_mode' = 'Sideways' } } |
        Should -Throw -ExpectedMessage '*takes one of: Push, Pull*'
    }

    It 'treats a declared-but-null value as unmanaged' {
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = $Null } | ConvertFrom-Json

      $Result.requested | Should -Be 3
      $Result.changed | Should -BeFalse
      @($global:FakeCliCalls | Where-Object { $_ -like 'Settings*' }).Count | Should -Be 0
    }
  }

  Context 'deciding what to write' {

    It 'writes nothing when every declared setting already matches' {
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 30 } | ConvertFrom-Json

      $Result.changed | Should -BeFalse
      $Result.unchanged | Should -Contain 'DeploymentSettings.CleanupDays'
      @($global:FakeCliCalls | Where-Object { $_ -like 'Settings*' }).Count | Should -Be 0
    }

    It 'takes the console shape: pages holding their settings' {
      # The caller may hand a map of PAGES exactly as the console groups them;
      # the script flattens page.setting itself, so the two spellings are one.
      $Result = & $script:ScriptPath @script:Ctx -Preference @{
        deployments = @{ cleanup_days = 45 }
        performance = @{ copy_mode = 'Push' }
      } | ConvertFrom-Json
      $Result.applied | Should -Be @('DeploymentSettings.CleanupDays')
      $Result.unchanged | Should -Contain 'PerformanceSettings.CopyMode'
    }

    It 'writes through the storage spelling when it differs from the export name' {
      # Printing stores as ProductPrintingSettings.* while the export says
      # PrintingSettings.*; the row's Store field carries the stored name and
      # the export name stays the oracle the verify pass reads.
      $global:FakeSettings['PrintingSettings.MarginTop'] = '20'
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'printing.margin_top' = 21 } | ConvertFrom-Json
      $Result.applied | Should -Be @('PrintingSettings.MarginTop')
      ($global:FakeCliCalls -join '; ') | Should -Match 'ProductPrintingSettings\.MarginTop -Set 21'
      $global:FakeSettings['PrintingSettings.MarginTop'] | Should -Be '21'
    }

    It 'names whoever has a console open when it writes' {
      # An open console's next save writes its stale model back over applied rows (measured);
      # a converge that wrote anything says who is holding one.
      $global:FakeConsoleSessions = @('HOST\\someone')
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ deployments = @{ cleanup_days = 45 } } |
        ConvertFrom-Json
      $Result.open_consoles | Should -Be @('HOST\\someone')
      $Result.msg | Should -Match 'console is open'
      $global:FakeConsoleSessions = @()
      $Quiet = & $script:ScriptPath @script:Ctx -Preference @{ deployments = @{ cleanup_days = 30 } } |
        ConvertFrom-Json
      $Quiet.open_consoles | Should -BeNullOrEmpty
    }

    It 'proves an export-invisible setting against its database row' {
      # Four measured names are real -- the console displays them -- yet the export never
      # publishes them; their table rows carry Unexported, and compare and verify read the
      # database instead. Modeled here by an export that drops the name while the row lands.
      $global:FakeIgnored = @('InterfaceSettings.ShowDashboardOnLaunch')
      $Result = & $script:ScriptPath @script:Ctx -Preference @{
        interface = @{ show_dashboard_on_launch = $False }
      } | ConvertFrom-Json
      $Result.applied | Should -Contain 'InterfaceSettings.ShowDashboardOnLaunch'
      $Result.changed | Should -BeTrue
      $Again = & $script:ScriptPath @script:Ctx -Preference @{
        interface = @{ show_dashboard_on_launch = $False }
      } | ConvertFrom-Json
      $Again.unchanged | Should -Contain 'InterfaceSettings.ShowDashboardOnLaunch'
      $Again.changed | Should -BeFalse
    }

    It 'waits for the service to persist the queue, and fails when it never drains' {
      # Edits are queued with the background service and drain at its own pace; the export
      # shows the pending state, so the script waits on the database row itself. A queue that
      # never drains -- here, a stalled fake -- must fail the run, not report applied.
      $global:FakeDrainStalls = $True
      { & $script:ScriptPath @script:Ctx -Preference @{ deployments = @{ cleanup_days = 45 } } 2>$null } |
        Should -Throw '*settle window*'
    }

    It 'restores a blank default by resetting, never by writing an empty value' {
      # The command line refuses -Set with an empty value, so blank travels as
      # -Reset -- measured 2026-08-21 after a converge died mid-campaign and the
      # revert to blank was refused with 'Parameter Set requires a single value'.
      $global:FakeSettings['AuditLogSettings.CustomConfigPath'] = 'left-behind'
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'logging.logging_configuration_file' = '' } |
        ConvertFrom-Json
      $Result.applied | Should -Be @('AuditLogSettings.CustomConfigPath')
      $global:FakeSettings['AuditLogSettings.CustomConfigPath'] | Should -Be ''
      ($global:FakeCliCalls -join "; ") | Should -Match ([regex]::Escape('-Reset'))
      ($global:FakeCliCalls -join "; ") | Should -Not -Match ([regex]::Escape('-Set ;'))
    }

    It 'writes only the setting that differs, leaving the rest alone' {
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45; 'performance.copy_mode' = 'Push' } |
        ConvertFrom-Json

      $Result.applied | Should -Be @('DeploymentSettings.CleanupDays')
      $Result.unchanged | Should -Contain 'PerformanceSettings.CopyMode'
      $Result.changed | Should -BeTrue
      $global:FakeSettings['DeploymentSettings.CleanupDays'] | Should -Be '45'
      @($global:FakeCliCalls | Where-Object { $_ -like 'Settings*' }).Count | Should -Be 1
    }

    It 'manages only the parameters that were passed' {
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45 } | ConvertFrom-Json

      $Result.requested | Should -Be 4
      $global:FakeSettings['PerformanceSettings.CopyMode'] | Should -Be 'Push'
    }

    It 'spells booleans the way the export does' {
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'usage_data.collect_usage_data' = $False } | ConvertFrom-Json

      $Result.applied | Should -Be @('AnalyticsSettings.CollectAnalyticsUsage')
      $global:FakeSettings['AnalyticsSettings.CollectAnalyticsUsage'] | Should -Be 'false'
    }

    It 'finds a setting the export nests under a view model by its two-part name' {
      # The export carries this three deep --
      # PackageLibrarySettingsViewModel.AutoDeployDefaultSettings.ApprovalMode --
      # while the product's command line takes the last two components. The
      # caller states neither: it passes a parameter, and the script indexes
      # both spellings so the nesting never reaches the playbook.
      $Result = & $script:ScriptPath @script:Ctx -Preference @{ 'auto_download.approval' = 'Delayed' } |
        ConvertFrom-Json

      $Result.unchanged | Should -Contain 'AutoDeployDefaultSettings.ApprovalMode'
      $Result.changed | Should -BeFalse
    }
  }

  Context 'proving the write landed' {

    It 'reports a setting the product accepted and discarded as ignored, and fails' {
      $global:FakeIgnored = @('DeploymentSettings.CleanupDays')

      $Output = & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45 }
      $Result = $Output | ConvertFrom-Json

      $Result.ignored | Should -Be @('DeploymentSettings.CleanupDays')
      $Result.applied | Should -BeNullOrEmpty
      $Result.changed | Should -BeFalse
      $Result.msg | Should -Match 'accepted but did not apply'
    }

    It 'exports twice: once to decide, once to prove' {
      & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45 } | Out-Null

      @($global:FakeCliCalls | Where-Object { $_ -like 'ExportSettings*' }).Count | Should -Be 2
    }

    It 'leaves no export file behind' {
      & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45 } | Out-Null

      Test-Path -LiteralPath $script:ExportPath | Should -BeFalse
    }

    It 'fails loudly when the export itself fails' {
      $global:FakeExportFails = $True

      { & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45 } } | Should -Throw
    }
  }

  Context 'the settings that are not reachable by command line' {

    It 'writes the repository through the database, never the command line' {
      $global:FakeSettings['RepositorySettings.Path'] = '\\TESTBOX\Old$'
      $Result = & $script:ScriptPath @script:Ctx -Preference @{} | ConvertFrom-Json

      $Result.applied | Should -Be @('RepositorySettings.Path')
      @($global:FakeSqliteCalls | Where-Object { $_ -match 'SystemVariables' }).Count | Should -Be 1
      $global:FakeSqliteCalls[0] | Should -Match 'UPDATE SystemVariables'
      $global:FakeSqliteCalls[0] | Should -Match "WHERE Name = 'Repository'"
      @($global:FakeCliCalls | Where-Object { $_ -like 'Settings*' }).Count | Should -Be 0
    }

    It 'asks the product where its database is rather than assuming' {
      $global:FakeSettings['RepositorySettings.Path'] = '\\TESTBOX\Old$'
      & $script:ScriptPath @script:Ctx -Preference @{} | Out-Null

      @($global:FakeCliCalls | Where-Object { $_ -eq 'SystemInfo' }).Count | Should -Be 1
      $global:FakeSqliteCalls[0] | Should -BeLike ($script:DatabasePath + '*')
    }

    It 'fails loudly when the product will not say where its database is' {
      $global:FakeSystemInfoBlank = $True

      $global:FakeSettings['RepositorySettings.Path'] = '\\TESTBOX\Old$'
      { & $script:ScriptPath @script:Ctx -Preference @{} } | Should -Throw
    }
  }

  Context '$Ansible transport' {

    It 'sets Changed=$False explicitly when nothing differs' {
      $Context = New-AnsibleContext

      & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 30 } | Out-Null

      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeFalse
      $Context.Result.msg | Should -Match 'already correct'
    }

    It 'fails the task when a setting was ignored, publishing the evidence first' {
      $global:FakeIgnored = @('DeploymentSettings.CleanupDays')
      $Context = New-AnsibleContext

      & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45 } | Out-Null

      $Context.Failed | Should -BeTrue
      $Context.Result.ignored | Should -Be @('DeploymentSettings.CleanupDays')
    }

    It 'reports the would-be change in check mode and writes nothing' {
      $Context = New-AnsibleContext -CheckMode

      & $script:ScriptPath @script:Ctx -Preference @{ 'deployments.cleanup_days' = 45 } | Out-Null

      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $global:FakeSettings['DeploymentSettings.CleanupDays'] | Should -Be '30'
      @($global:FakeCliCalls | Where-Object { $_ -like 'ExportSettings*' }).Count | Should -Be 1
    }
  }
}
