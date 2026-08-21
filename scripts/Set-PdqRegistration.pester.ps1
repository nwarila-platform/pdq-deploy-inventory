#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqRegistration.ps1 (org pair convention: every script
    ships with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one
    leg per pair).

    Runs anywhere, Linux CI included: the script touches the platform through
    exactly three doors -- the licence read (Get-ItemProperty on one HKLM key),
    the product's command line, and its sqlite tool. This file stubs all three:
    the registry cmdlet returns a marker-wrapped base64 licence built by the
    spec, and the two executables are FUNCTIONS named with their literal
    Windows paths, because the call operator resolves a path-shaped string to a
    function before it ever consults a filesystem.

    Stub state lives in $global: variables because inside a function called
    from a child SCRIPT, $script: resolves to the child script's own scope, not
    this file's. The in-memory database is three arrays of pipe-joined rows,
    exactly the shape sqlite prints; the write stub applies INSERT and
    INSERT OR REPLACE statements against them so a re-run reads its own writes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

  # The licence the registry hands out: the same marker-wrapped base64 XML the
  # product stores, built here so a test can vary the ID or the address.
  Function New-FakeLicense {
    Param ([System.String]$Id, [System.String]$Email)
    $Xml = '<License Version="2.0" ID="{0}" Name="PDQ Deploy" Mode="Enterprise" E-Mail="{1}" />' -f $Id, $Email
    '--- START LICENSE ---{0}--- END LICENSE ---' -f [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Xml))
  }

  # Registry door: the script reads exactly one key. Anything else is a
  # mistake this stub surfaces by refusing it.
  Function Get-ItemProperty {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    If ($LiteralPath -ne 'HKLM:\SOFTWARE\Admin Arsenal\PDQ Deploy') {
      Throw ('unexpected registry read: {0}' -f $LiteralPath)
    }
    [PSCustomObject]@{ License = $global:FakeLicenseBlob }
  }

  # Command-line door: SystemInfo names the database, nothing else is asked.
  New-Item -Force -Path 'function:C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe' -Value {
    $global:CliCalls += , @($args)
    $global:LASTEXITCODE = 0
    @('  Console Version : 20.1.8.0', '  Database : C:\fake\Database.db')
  }

  # Sqlite door: SELECTs read the arrays; the write call applies each
  # statement so later reads observe it. Row shape is sqlite's own pipe join.
  New-Item -Force -Path 'function:C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe' -Value {
    $Database, $Sql = $args
    $global:SqliteCalls += , @($Database, $Sql)
    $global:LASTEXITCODE = If ($global:FakeSqliteFails) { 1 } Else { 0 }
    If ($global:FakeSqliteFails) { Return }
    Switch -Regex ($Sql) {
      '^SELECT \* FROM LicensedMachine;$' { $global:FakeMachines; Break }
      '^SELECT \* FROM LicensedUser;$' { $global:FakeUsers; Break }
      '^SELECT \* FROM Registration;$' { $global:FakeRegistrations; Break }
      Default {
        $global:WriteCalls += 1
        ForEach ($Statement In ($Sql -split ';')) {
          If ($Statement -match "^\s*INSERT INTO LicensedMachine VALUES\('([^']*)','([^']*)'\)") {
            $global:FakeMachines += ('{0}|{1}' -f $Matches[1], $Matches[2])
          } ElseIf ($Statement -match "^\s*INSERT INTO LicensedUser VALUES\('([^']*)','([^']*)'\)") {
            $global:FakeUsers += ('{0}|{1}' -f $Matches[1], $Matches[2])
          } ElseIf ($Statement -match "^\s*INSERT OR REPLACE INTO Registration VALUES\('([^']*)','([^']*)','([^']*)','([^']*)','([^']*)','([^']*)',(\d)\)") {
            $Row = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5], $Matches[6], $Matches[7]
            $Kept = @($global:FakeRegistrations | Where-Object -FilterScript { $PSItem.Split('|')[0] -ne $Matches[1] })
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

Describe 'Set-PdqRegistration' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    # win_powershell SKIPS a script in check mode unless it advertises this, returning
    # changed=true and no result -- the exact spelling the module's own detector keys on.
    $Script = Get-Content -Raw (Join-Path $PSScriptRoot 'Set-PdqRegistration.ps1')
    $Script | Should -Match '\[CmdletBinding\(SupportsShouldProcess'
  }

  BeforeEach {
    $env:COMPUTERNAME = 'TESTBOX'
    $global:FakeLicenseBlob = New-FakeLicense -Id 'lic-0001' -Email 'someone@example.com'
    $global:FakeMachines = @()
    $global:FakeUsers = @()
    $global:FakeRegistrations = @()
    $global:FakeSqliteFails = $False
    $global:FakeWriteIgnored = $False
    $global:CliCalls = @()
    $global:SqliteCalls = @()
    $global:WriteCalls = 0
    Remove-AnsibleContext
  }

  Context 'refusing bad input' {
    It 'throws when the email does not match the one the licence was issued to' {
      { & $script:ScriptPath -Email 'other@example.com' 2>$null } | Should -Throw '*does not match*'
      $global:WriteCalls | Should -Be 0
    }

    It 'throws when the licence carries no ID to register against' {
      $global:FakeLicenseBlob = '--- START LICENSE ---{0}--- END LICENSE ---' -f
        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('<License Version="2.0" />'))
      { & $script:ScriptPath -Email 'someone@example.com' 2>$null } | Should -Throw '*no ID*'
    }

    It 'throws when the database write fails' {
      $global:FakeSqliteFails = $True
      { & $script:ScriptPath -Email 'someone@example.com' 2>$null } | Should -Throw '*exit code 1*'
    }
  }

  Context 'recording a fresh build' {
    It 'creates the machine, the user and the registration, and reports the change' {
      $Result = & $script:ScriptPath -Email 'someone@example.com' | ConvertFrom-Json
      $Result.changed | Should -BeTrue
      $Result.registered | Should -Be 'someone@example.com'
      $global:FakeMachines | Should -Be @('testbox|' + $global:FakeMachines[0].Split('|')[1])
      $global:FakeUsers[0] | Should -Match '^testbox\\administrator\|'
      $global:FakeRegistrations.Count | Should -Be 1
      $global:FakeRegistrations[0] | Should -Match '^lic-0001\|.+\|.+\|someone@example\.com\|Server\|Registered\|0$'
    }

    It 'stores lower-case names whatever the machine reports' {
      $env:COMPUTERNAME = 'UPPERBOX'
      $Null = & $script:ScriptPath -Email 'someone@example.com'
      $global:FakeMachines[0] | Should -Match '^upperbox\|'
      $global:FakeUsers[0] | Should -Match '^upperbox\\administrator\|'
    }

    It 'fails the run when the row does not read back as written' {
      $global:FakeWriteIgnored = $True
      { & $script:ScriptPath -Email 'someone@example.com' 2>$null } | Should -Throw '*did not read back*'
    }
  }

  Context 'converging an already-registered build' {
    BeforeEach {
      $Null = & $script:ScriptPath -Email 'someone@example.com'
      $global:WriteCalls = 0
    }

    It 'changes nothing and writes nothing the second time' {
      $Result = & $script:ScriptPath -Email 'someone@example.com' | ConvertFrom-Json
      $Result.changed | Should -BeFalse
      $Result.msg | Should -Be 'registration already present'
      $global:WriteCalls | Should -Be 0
    }

    It 'replaces the row but keeps both ids when only the address moved' {
      $Before = $global:FakeRegistrations[0].Split('|')
      $global:FakeLicenseBlob = New-FakeLicense -Id 'lic-0001' -Email 'renamed@example.com'
      $Result = & $script:ScriptPath -Email 'renamed@example.com' | ConvertFrom-Json
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
      $Null = & $script:ScriptPath -Email 'someone@example.com'
      $Context = New-AnsibleContext
      & $script:ScriptPath -Email 'someone@example.com'
      $Context.Changed | Should -BeFalse
      $Context.Result.registered | Should -Be 'someone@example.com'
    }

    It 'reports the would-be change in check mode and writes nothing' {
      $Null = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Email 'someone@example.com'
      $global:Ansible.Changed | Should -BeTrue
      $global:WriteCalls | Should -Be 0
      $global:FakeRegistrations.Count | Should -Be 0
    }
  }
}
