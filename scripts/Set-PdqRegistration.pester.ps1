#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqRegistration.ps1 (org pair convention: every script
    ships with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one
    leg per pair).

    Runs anywhere, Linux CI included: the script touches the platform through
    exactly three doors -- the licence read (Get-ItemProperty on one HKLM key),
    the product's command line, and its sqlite tool. This file stubs all three
    for both products: the registry cmdlet returns a marker-wrapped base64
    licence built by the spec, and the executables are FUNCTIONS named with
    their literal Windows paths, because the call operator resolves a
    path-shaped string to a function before it ever consults a filesystem.

    Join-Path uses the current filesystem provider's separator, so a scoped
    invocation helper supplies Windows path semantics while the spec runs on
    Linux. That keeps the derived paths byte-for-byte equal to the paths used
    on the Windows target without changing the host's global command surface.

    Stub state lives in $global: variables because inside a function called
    from a child SCRIPT, $script: resolves to the child script's own scope, not
    this file's. The in-memory database is three arrays of pipe-joined rows,
    exactly the shape sqlite prints; the write stub applies INSERT and
    INSERT OR REPLACE statements against them so a re-run reads its own writes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Products = @(
  @{
    ProductName = 'PDQ Deploy'
    CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
    SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
    LicenseKey = 'HKLM:\SOFTWARE\Admin Arsenal\PDQ Deploy'
  }
  @{
    ProductName = 'PDQ Inventory'
    CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
    SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe'
    LicenseKey = 'HKLM:\SOFTWARE\Admin Arsenal\PDQ Inventory'
  }
)

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PdqRegistration.ps1'

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

  # The target is Windows PowerShell 5.1. Its filesystem provider preserves the backslash paths
  # below; Linux PowerShell uses forward slashes, so scope the target semantics to each invocation.
  Function Invoke-PdqRegistration {
    Param (
      [System.String] $CliPath,
      [System.String] $Email,
      [Switch] $WhatIf
    )

    Function Split-Path {
      Param (
        [System.String] $Path,
        [Switch] $Parent,
        [Switch] $Leaf
      )

      $LastSeparator = $Path.LastIndexOf('\')
      If ($Leaf) {
        Return $Path.Substring($LastSeparator + 1)
      }
      If ($Parent) {
        Return $Path.Substring(0, $LastSeparator)
      }
      Throw 'unexpected Split-Path invocation'
    }

    Function Join-Path {
      Param (
        [System.String] $Path,
        [System.String] $ChildPath
      )

      '{0}\{1}' -f $Path, $ChildPath
    }

    $DerivedSqlitePath = Join-Path (Split-Path -Path $CliPath -Parent) 'sqlite3.exe'
    New-Item -Force -Path ('function:' + $CliPath) -Value $script:CliStub | Out-Null
    New-Item -Force -Path ('function:' + $DerivedSqlitePath) -Value $script:SqliteStub | Out-Null
    & $script:ScriptPath -Email $Email -CliPath $CliPath -WhatIf:$WhatIf
  }

  # The licence the registry hands out: the same marker-wrapped base64 XML the
  # product stores, built here so a test can vary the ID or the address.
  Function New-FakeLicense {
    Param ([System.String]$Id, [System.String]$Email, [System.String]$ProductName)
    $Xml = '<License Version="2.0" ID="{0}" Name="{1}" Mode="Enterprise" E-Mail="{2}" />' -f $Id, $ProductName, $Email
    '--- START LICENSE ---{0}--- END LICENSE ---' -f [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Xml))
  }

  # Registry door: the script reads exactly one key. Anything else is a
  # mistake this stub surfaces by refusing it.
  Function Get-ItemProperty {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    $global:LicenseKeyReads += $LiteralPath
    If ($LiteralPath -ne $global:ExpectedLicenseKey) {
      Throw ('unexpected registry read: {0}' -f $LiteralPath)
    }
    [PSCustomObject]@{ License = $global:FakeLicenseBlob }
  }

  # The database-exists guard checks the path SystemInfo reports; it is present unless a test
  # clears $global:FakeDbPresent to model a stale/broken install.
  Function Test-Path {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    If ($LiteralPath -eq 'C:\fake\Database.db') { Return [bool]$global:FakeDbPresent }
    Throw ('unexpected Test-Path: {0}' -f $LiteralPath)
  }

  # Command-line door: SystemInfo names the database, nothing else is asked.
  $script:CliStub = {
    $global:CliCommandPaths += $MyInvocation.MyCommand.Name
    $global:CliCalls += , @($args)
    $global:LASTEXITCODE = 0
    @('  Console Version : 20.1.8.0', '  Database : C:\fake\Database.db')
  }

  # Sqlite door: SELECTs read the arrays; the write call applies each
  # statement so later reads observe it. Row shape is sqlite's own pipe join.
  $script:SqliteStub = {
    $global:SqliteCommandPaths += $MyInvocation.MyCommand.Name
    $Database, $Sql = $args
    $global:SqliteCalls += , @($Database, $Sql)
    $global:LASTEXITCODE = If ($global:FakeSqliteFails) { 1 } Else { 0 }
    If ($global:FakeSqliteFails) { Return }
    Switch -Regex ($Sql) {
      'SELECT \* FROM LicensedMachine;' { $global:FakeMachines; Break }
      'SELECT \* FROM LicensedUser;' { $global:FakeUsers; Break }
      'SELECT \* FROM Registration;' { $global:FakeRegistrations; Break }
      Default {
        $global:WriteCalls += 1
        ForEach ($Statement In ($Sql -split ';')) {
          If ($Statement -match "^\s*INSERT INTO LicensedMachine VALUES\('([^']*)','([^']*)'\)") {
            $global:FakeMachines += ('{0}|{1}' -f $Matches[1], $Matches[2])
          } ElseIf ($Statement -match "^\s*INSERT INTO LicensedUser VALUES\('([^']*)','([^']*)'\)") {
            $global:FakeUsers += ('{0}|{1}' -f $Matches[1], $Matches[2])
          } ElseIf ($Statement -match "^\s*INSERT OR REPLACE INTO Registration VALUES\('([^']*)','([^']*)','([^']*)','([^']*)','([^']*)','([^']*)',(\d)\)") {
            $Row = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5], $Matches[6], $Matches[7]
            $Kept = @($global:FakeRegistrations | Where-Object -FilterScript {
                $F = $PSItem.Split('|')
                -not ($F[0] -eq $Matches[1] -and $F[1] -eq $Matches[2] -and $F[2] -eq $Matches[3])
              })
            $global:FakeRegistrations = $Kept + $Row
            If ($global:FakeWriteIgnored) {
              $global:FakeRegistrations = $Kept
            }
          }
        }
      }
    }
  }
}

AfterAll {
  Remove-AnsibleContext
}

Describe 'Set-PdqRegistration <ProductName>' -ForEach $script:Products {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    # win_powershell SKIPS a script in check mode unless it advertises this, returning
    # changed=true and no result -- the exact spelling the module's own detector keys on.
    $Script = Get-Content -Raw $script:ScriptPath
    $Script | Should -Match '\[CmdletBinding\(SupportsShouldProcess'
  }

  BeforeEach {
    $env:COMPUTERNAME = 'TESTBOX'
    $global:ExpectedLicenseKey = $LicenseKey
    $global:FakeLicenseBlob = New-FakeLicense -Id 'lic-0001' -Email 'someone@example.com' -ProductName $ProductName
    $global:FakeMachines = @()
    $global:FakeUsers = @()
    $global:FakeRegistrations = @()
    $global:FakeDbPresent = $True
    $global:FakeSqliteFails = $False
    $global:FakeWriteIgnored = $False
    $global:CliCalls = @()
    $global:CliCommandPaths = @()
    $global:SqliteCalls = @()
    $global:SqliteCommandPaths = @()
    $global:LicenseKeyReads = @()
    $global:WriteCalls = 0
    Remove-AnsibleContext
  }

  Context 'refusing bad input' {
    It 'throws when the email does not match the one the licence was issued to' {
      { Invoke-PdqRegistration -CliPath $CliPath -Email 'other@example.com' 2>$null } |
        Should -Throw '*does not match*'
      $global:WriteCalls | Should -Be 0
    }

    It 'throws when the licence carries no ID to register against' {
      $global:FakeLicenseBlob = '--- START LICENSE ---{0}--- END LICENSE ---' -f
        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('<License Version="2.0" />'))
      { Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com' 2>$null } |
        Should -Throw '*no ID*'
    }

    It 'throws when the database fails, naming the operation and the program' {
      $global:FakeSqliteFails = $True
      { Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com' 2>$null } |
        Should -Throw '*Reading the LicensedMachine table: sqlite3.exe exited 1*'
    }
  }

  Context 'deriving product paths' {
    It 'uses the exact command, sqlite and licence paths from the product CLI path' {
      $Null = Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com'

      ($global:CliCommandPaths | Select-Object -Unique) | Should -BeExactly $CliPath
      ($global:SqliteCommandPaths | Select-Object -Unique) | Should -BeExactly $SqlitePath
      ($global:LicenseKeyReads | Select-Object -Unique) | Should -BeExactly $LicenseKey
    }
  }

  Context 'hardening' {
    It 'escapes every interpolated value, not just the email' {
      $env:COMPUTERNAME = "o'brien-pc"
      $Null = Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com'
      $Batch = ($global:SqliteCalls | Where-Object { $_[1] -match 'INSERT' } | Select-Object -Last 1)[1]
      $Batch | Should -Match "o''brien-pc"
      $Batch | Should -Not -Match "o'brien-pc'"
    }

    It 'refuses an absent database rather than creating an empty one' {
      $global:FakeDbPresent = $False
      { Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com' 2>$null } |
        Should -Throw '*is not at*'
    }

    It 'reports no change when the email guard rejects the input' {
      $global:FakeLicenseBlob = New-FakeLicense -Id 'lic-0001' -Email 'real@example.com' -ProductName $ProductName
      $Context = New-AnsibleContext
      { Invoke-PdqRegistration -CliPath $CliPath -Email 'wrong@example.com' 2>$null } |
        Should -Throw '*does not match*'
      $Context.Changed | Should -BeFalse
      Remove-AnsibleContext
    }
  }

  Context 'recording a fresh build' {
    It 'creates the machine, the user and the registration, and reports the change' {
      $Result = Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com' |
        ConvertFrom-Json
      $Result.changed | Should -BeTrue
      $Result.registered | Should -Be 'someone@example.com'
      $global:FakeMachines | Should -Be @('testbox|' + $global:FakeMachines[0].Split('|')[1])
      $global:FakeUsers[0] | Should -Match '^testbox\\administrator\|'
      $global:FakeRegistrations.Count | Should -Be 1
      $global:FakeRegistrations[0] | Should -Match '^lic-0001\|.+\|.+\|someone@example\.com\|Server\|Registered\|0$'
    }

    It 'stores lower-case names whatever the machine reports' {
      $env:COMPUTERNAME = 'UPPERBOX'
      $Null = Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com'
      $global:FakeMachines[0] | Should -Match '^upperbox\|'
      $global:FakeUsers[0] | Should -Match '^upperbox\\administrator\|'
    }

    It 'fails the run when the row does not read back as written' {
      $global:FakeWriteIgnored = $True
      { Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com' 2>$null } |
        Should -Throw '*did not read back*'
    }
  }

  Context 'converging an already-registered build' {
    BeforeEach {
      $Null = Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com'
      $global:WriteCalls = 0
    }

    It 'changes nothing and writes nothing the second time' {
      $Result = Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com' |
        ConvertFrom-Json
      $Result.changed | Should -BeFalse
      $Result.msg | Should -Be 'registration already present'
      $global:WriteCalls | Should -Be 0
    }

    It 'replaces the row but keeps both ids when only the address moved' {
      $Before = $global:FakeRegistrations[0].Split('|')
      $global:FakeLicenseBlob = New-FakeLicense -Id 'lic-0001' -Email 'renamed@example.com' -ProductName $ProductName
      $Result = Invoke-PdqRegistration -CliPath $CliPath -Email 'renamed@example.com' |
        ConvertFrom-Json
      $Result.changed | Should -BeTrue
      $After = $global:FakeRegistrations[0].Split('|')
      $After[1] | Should -Be $Before[1]
      $After[2] | Should -Be $Before[2]
      $After[3] | Should -Be 'renamed@example.com'
    }
  }

  Context '$Ansible transport' {
    AfterEach { Remove-AnsibleContext }

    It 'sets Changed=$False explicitly when the registration is already present' {
      $Null = Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com'
      $Context = New-AnsibleContext
      Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com'
      $Context.Changed | Should -BeFalse
      $Context.Result.registered | Should -Be 'someone@example.com'
    }

    It 'reports the would-be change in check mode and writes nothing' {
      $Null = New-AnsibleContext -CheckMode
      Invoke-PdqRegistration -CliPath $CliPath -Email 'someone@example.com' -WhatIf
      $global:Ansible.Changed | Should -BeTrue
      $global:WriteCalls | Should -Be 0
      $global:FakeRegistrations.Count | Should -Be 0
    }
  }

  Context 'the hazard it must not reintroduce' {
    It 'keeps all three halves of the native-command contract' {
      # Measured on a Windows target under win_powershell with error_action stop: with the
      # preference at Stop a native command's stderr is a TERMINATING error, redirected or not; left
      # on its own stream it becomes an error record and the module fails the task even though
      # nothing threw. So the preference is lowered across the call, stderr is merged into the
      # capture, and the records are separated back out of the output. Drop any one and the ordinary
      # "not found" the product writes alongside an absent-means-absent exit code fails the run.
      # Pinned here because all three are invisible on review.
      $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Set-PdqRegistration.ps1') -Raw
      $Source | Should -Match "ErrorActionPreference = 'Continue'"
      $Source | Should -Match '& \$FilePath @Argument 2>&1'
      $Source | Should -Match '\[System\.Management\.Automation\.ErrorRecord\]'
    }
    It 'carries the same native-command helper as its siblings' {
      # There is no shared module -- one file per script is the org contract -- so the copies are
      # kept identical by checking, not by convention: a fix applied to one and not the others is
      # the realistic hazard, and no other assertion here would notice it.
      $Extract = {
        Param ($File)
        $Text = Get-Content -LiteralPath $File -Raw
        $Start = $Text.IndexOf('Function Invoke-NativeCommand')
        $Text.Substring($Start, $Text.IndexOf("`n}", $Start) - $Start)
      }
      $Mine = & $Extract (Join-Path $PSScriptRoot 'Set-PdqRegistration.ps1')
      ForEach ($Sibling In @('Set-PdqPackage.ps1', 'Remove-PdqPackage.ps1', 'Set-PdqVariable.ps1',
          'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1', 'Remove-PdqVariable.ps1',
          'Set-PdqCollection.ps1', 'Remove-PdqCollection.ps1')) {
        (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because $Sibling
      }
    }
  }

}
