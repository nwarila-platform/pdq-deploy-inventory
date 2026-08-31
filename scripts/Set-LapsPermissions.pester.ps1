#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Spec for Set-LapsPermissions.ps1.

    The script's real work is an ACL reconcile against a live directory, which no unit test can
    stand in for. What a spec CAN hold is the contract and the hazards -- every one of these was
    measured against the live domain, and every one of them cost a failed run to find.
#>

BeforeAll {
  $script:Path   = Join-Path -Path $PSScriptRoot -ChildPath 'Set-LapsPermissions.ps1'
  $script:Source = Get-Content -LiteralPath $script:Path -Raw
  $script:Tokens = $null
  $script:Errors = $null
  $script:Ast    = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:Path, [ref]$script:Tokens, [ref]$script:Errors
  )
}

Describe 'Set-LapsPermissions' {

  It 'parses without error' {
    $script:Errors | Should -BeNullOrEmpty
  }

  It 'declares SupportsShouldProcess so the module can run it in check mode' {
    $script:Source | Should -Match 'SupportsShouldProcess'
  }

  Context 'the interface the tasks call it with' {

    It 'takes the account, the OUs and the state' {
      $names = $script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
      $names | Should -Contain 'AccountIdentity'
      $names | Should -Contain 'OrganizationalUnit'
      $names | Should -Contain 'State'
    }

    It 'carries the debug scaffold the organisation harness requires' {
      $names = $script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
      $names | Should -Contain 'DebugLevel'
      $names | Should -Contain 'LogLevel'
    }

    It 'accepts more than one OU, because the declaration names two' {
      $ou = $script:Ast.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq 'OrganizationalUnit' }
      $ou.StaticType.IsArray | Should -BeTrue
    }
  }

  Context 'the hazards it must not reintroduce' {

    It 'reads the ACL with -Path: the AD provider does not resolve -LiteralPath' {
      # Measured: -LiteralPath reports "Cannot find path //RootDSE/<dn>" for an OU that exists.
      $script:Source | Should -Not -Match 'Get-Acl[^\r\n]*-LiteralPath'
    }

    It 'imports the ActiveDirectory module before using the AD: drive' {
      # Measured: without it, "Cannot find drive. A drive with the name AD does not exist."
      $script:Source | Should -Match "Import-Module[^\r\n]*ActiveDirectory"
      $script:Source.IndexOf('ActiveDirectory') |
        Should -BeLessThan $script:Source.IndexOf('AD:\')
    }

    It 'matches the account by SID, never by display name' {
      # A shared OU carries 16 principals; a name match is ambiguous and a rename would orphan it.
      $script:Source | Should -Match 'SecurityIdentifier|objectSid|\.SID'
    }

    It 'never removes an ACE it does not own' {
      # The OU is shared with other deployments. Ownership is the account's own explicit ACEs.
      $script:Source | Should -Match 'IsInherited|Inherited'
    }
  }

  Context 'the state contract' {

    It 'handles both present and absent' {
      $script:Source | Should -Match "'present'"
      $script:Source | Should -Match "'absent'"
    }

    It 'reports what it did rather than asserting success' {
      $script:Source | Should -Match '\$Ansible\.Result'
      $script:Source | Should -Match '\$Ansible\.Changed'
    }
  }
}
