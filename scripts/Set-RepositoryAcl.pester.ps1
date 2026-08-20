#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-RepositoryAcl.ps1 (org pair convention: every script
    ships with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one
    leg per pair).

    Runs anywhere, Linux CI included: the ACL and principal APIs are Windows
    resource management and refuse to construct on other platforms, so the
    script confines every platform call to Get-Acl and Set-Acl and handles the
    descriptor purely as its SDDL string. This file stubs those two cmdlets
    around an in-memory descriptor, which exercises the whole decision surface
    -- compare, apply, verify, refuse -- with no filesystem at all.

    Stub state lives in $global: variables because inside a function called
    from a child SCRIPT, $script: resolves to the child script's own scope, not
    this file's.

    Both transports are asserted: the standalone JSON emission and the $Ansible
    path via the inline context below (pairs are self-contained; no imports).
    Its Changed defaults to $True exactly like win_powershell -- so the spec
    proves the script SETS Changed rather than inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-RepositoryAcl.ps1'
  $script:Desired = 'D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;BU)'
  $script:Drifted = 'D:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;BU)'

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

  # In-memory descriptor. $global:FakeSddl is the directory's current DACL;
  # Get-Acl hands out an object whose SDDL methods read it and stage a pending
  # write; Set-Acl commits the staged value -- unless the spec sets
  # $global:FakeWriteIgnored, which models a platform that silently keeps its
  # own shape and is exactly the failure the script's verify pass exists for.
  Function Get-Acl {
    [CmdletBinding()]
    Param (
      [Parameter()] [System.String]$LiteralPath,
      [Parameter(ValueFromPipeline = $True)] [System.Object]$Path
    )

    If ($global:FakeMissing) {
      Throw ('Cannot find path {0} because it does not exist.' -f $LiteralPath)
    }
    $global:FakeReads++
    $Descriptor = [PSCustomObject]@{ PendingSddl = $Null }
    $Descriptor | Add-Member -MemberType ScriptMethod -Name 'GetSecurityDescriptorSddlForm' -Value {
      Param ([System.String]$Section)
      $global:FakeSddl
    }
    $Descriptor | Add-Member -MemberType ScriptMethod -Name 'SetSecurityDescriptorSddlForm' -Value {
      Param ([System.String]$Sddl)
      $this.PendingSddl = $Sddl
    }
    Return $Descriptor
  }

  Function Set-Acl {
    [CmdletBinding()]
    Param (
      [Parameter()] [System.String]$LiteralPath,
      [Parameter()] [System.Object]$AclObject
    )

    $global:FakeWrites++
    If (-not $global:FakeWriteIgnored) {
      $global:FakeSddl = $AclObject.PendingSddl
    }
  }
}

Describe 'Set-RepositoryAcl' {

  BeforeEach {
    $global:FakeSddl = $script:Desired
    $global:FakeReads = 0
    $global:FakeWrites = 0
    $global:FakeWriteIgnored = $False
    $global:FakeMissing = $False
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-AnsibleContext
    Remove-Variable -Name 'FakeSddl', 'FakeReads', 'FakeWrites', 'FakeWriteIgnored', 'FakeMissing' `
      -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Context 'convergence decisions' {

    It 'reports no change when the DACL is already exact, and never writes' {
      $Result = & $script:ScriptPath -Path 'F:\PDQ Repository' | ConvertFrom-Json

      $Result.changed | Should -BeFalse
      $Result.before | Should -Be $script:Desired
      $Result.after | Should -Be $script:Desired
      $global:FakeWrites | Should -Be 0
    }

    It 'replaces a drifted DACL wholesale and verifies the readback' {
      $global:FakeSddl = $script:Drifted

      $Result = & $script:ScriptPath -Path 'F:\PDQ Repository' | ConvertFrom-Json

      $Result.changed | Should -BeTrue
      $Result.before | Should -Be $script:Drifted
      $Result.after | Should -Be $script:Desired
      $global:FakeWrites | Should -Be 1
      $global:FakeSddl | Should -Be $script:Desired
    }

    It 'fails loudly when the write does not take, instead of claiming a change' {
      $global:FakeSddl = $script:Drifted
      $global:FakeWriteIgnored = $True

      { & $script:ScriptPath -Path 'F:\PDQ Repository' } | Should -Throw
    }

    It 'fails loudly on a missing directory' {
      $global:FakeMissing = $True

      { & $script:ScriptPath -Path 'F:\Absent' } | Should -Throw
    }
  }

  Context '$Ansible transport' {

    It 'sets Changed=$False explicitly on an already-exact directory' {
      $Context = New-AnsibleContext

      & $script:ScriptPath -Path 'F:\PDQ Repository' | Out-Null

      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeFalse
      $Context.Result.msg | Should -Match 'already exact'
    }

    It 'reports the would-be change in check mode without writing' {
      $global:FakeSddl = $script:Drifted
      $Context = New-AnsibleContext -CheckMode

      & $script:ScriptPath -Path 'F:\PDQ Repository' | Out-Null

      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $global:FakeWrites | Should -Be 0
      $global:FakeSddl | Should -Be $script:Drifted
    }
  }
}
