#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqVariable.ps1 (org pair convention: every script ships with a sibling
    <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script drives one external program at a path the CALLER
    passes (-CliPath), so this file registers a FUNCTION named with that exact path string:
    PowerShell's call operator resolves a path-shaped command to a function of that name before it
    looks for a file on disk, which lets the whole flow -- export, compare, create, re-export,
    verify -- run with no PDQ installed. The stub also sets $LASTEXITCODE, because a function does
    not and the script reads it after every invocation.

    The export path is a Windows string the script owns. The script reaches the file entirely
    through the PowerShell provider, so each test mounts a C: drive over its own temporary directory
    and creates Windows\Temp inside it; the Windows-shaped constant then resolves to a real file on
    any platform, and the stub writes exactly the file the script reads.

    Stub state lives in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's. $global:FakeVariables is the
    product's custom-variable store; the export stub renders it as the product does
    (CustomVariable/Name/Value). CreateCustomVariable mutates it, so a test states an outcome
    rather than a sequence of calls. A name listed in $global:FakeIgnored is accepted and NOT
    stored -- the product's real and dangerous behaviour of reporting success for a no-op, which is
    the whole reason the script verifies. An empty store models a fresh install, where the product's
    ExportVariables exits 3 and writes no file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PdqVariable.ps1'
  # The caller passes the CLI path; a Windows-shaped string so the path-function trick resolves.
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
  # The one constant the script owns; named here so a drift between the two files fails the spec.
  $script:ExportPath = 'C:\Windows\Temp\pdq-variables-export.xml'
  $global:FakeExportPath = $script:ExportPath

  # Inline $Ansible stand-in (org contract: pairs are self-contained). Faithful to win_powershell:
  # Changed defaults to $True, and only the ratified surface is modeled.
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

  # Renders $global:FakeVariables the way the product's ExportVariables renders it (measured
  # 2026-08-22): a CustomVariable element per entry, Name and Value as child elements, under
  # VariablesSettingsViewModel/CustomVariables.
  Function global:Write-FakeExport {
    $Lines = [System.Collections.Generic.List[System.String]]::new()
    $Lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $Lines.Add('<AdminArsenal.Export Code="PDQInventory" Name="PDQ Inventory" Version="20.1.8.0" MinimumVersion="5.0">')
    $Lines.Add('  <VariablesSettingsViewModel>')
    $Lines.Add('    <CustomVariables type="list">')
    ForEach ($Name In ($global:FakeVariables.Keys | Sort-Object)) {
      $NameEsc = [System.Security.SecurityElement]::Escape([System.String]$Name)
      $ValueEsc = [System.Security.SecurityElement]::Escape([System.String]$global:FakeVariables[$Name])
      $Lines.Add('      <CustomVariable>')
      $Lines.Add(('        <Name>{0}</Name>' -f $NameEsc))
      $Lines.Add(('        <Value>{0}</Value>' -f $ValueEsc))
      $Lines.Add('      </CustomVariable>')
    }
    $Lines.Add('    </CustomVariables>')
    $Lines.Add('  </VariablesSettingsViewModel>')
    $Lines.Add('</AdminArsenal.Export>')
    # -WhatIf:$False models the native exporter: an external tool ignores the transport's -WhatIf
    # and writes the scratch file even in check mode, which is why the script forces its cleanups.
    Set-Content -LiteralPath $global:FakeExportPath -Value ($Lines -join "`n") -Encoding 'utf8' -WhatIf:$False
  }
}

Describe 'Set-PdqVariable' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Script = Get-Content -Raw (Join-Path $PSScriptRoot 'Set-PdqVariable.ps1')
    $Script | Should -Match '\[CmdletBinding\(SupportsShouldProcess'
  }

  BeforeEach {
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    $script:MountedDrive = $Null
    If (-not (Get-PSDrive -Name 'C' -ErrorAction 'SilentlyContinue')) {
      New-PSDrive -Name 'C' -PSProvider 'FileSystem' -Root $script:Sandbox -Scope 'Global' | Out-Null
      $script:MountedDrive = 'C'
    }
    New-Item -ItemType Directory -Path 'C:\Windows\Temp' -Force | Out-Null

    $global:FakeVariables = @{
      'GoogleLlc_GoogleChrome' = '129.0.6668.90'
      'MozillaOrg_Firefox'     = '131.0'
    }
    $global:FakeIgnored = @()
    $global:FakeExportFails = $False
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    # The product's command line. A path-shaped call resolves to this function.
    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      Switch ($args[0]) {
        'ExportVariables' {
          If ($global:FakeExportFails) { $global:LASTEXITCODE = 1; Return }
          # A fresh install holds no variables: the product exits 3 and writes no file.
          If ($global:FakeVariables.Count -eq 0) { $global:LASTEXITCODE = 3; Return }
          Write-FakeExport
          $global:LASTEXITCODE = 0
        }
        'CreateCustomVariable' {
          # & CliPath CreateCustomVariable -Name <n> -Value <v> -Force
          $Name = $args[2]
          $Value = $args[4]
          # A name in the ignored set is accepted and NOT stored -- the no-op the script exists to
          # catch. Every other name is created or overwritten.
          If ($global:FakeIgnored -notcontains $Name) {
            $global:FakeVariables[$Name] = $Value
          }
          $global:LASTEXITCODE = 0
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null
  }

  AfterEach {
    If ($script:MountedDrive) {
      Remove-PSDrive -Name $script:MountedDrive -Force -ErrorAction 'SilentlyContinue'
    }
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:CliPath) -Force -ErrorAction 'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name 'FakeVariables', 'FakeIgnored', 'FakeExportFails', 'FakeCliCalls',
      'FakeExportPath' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Context 'the constant it owns' {
    It 'still names the export path this spec stubs' {
      $Source = Get-Content -LiteralPath $script:ScriptPath -Raw
      $Source | Should -BeLike ('*' + $script:ExportPath + '*')
    }
  }

  Context 'validating the request' {
    It 'refuses a name carrying the reference punctuation the product forbids' {
      { & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'Bad$Name' = '1' } } |
        Should -Throw -ExpectedMessage '*not a valid PDQ variable name*'
      @($global:FakeCliCalls).Count | Should -Be 0
    }

    It 'refuses a value that is not a string before anything is read or written' {
      { & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoodName' = 42 } } |
        Should -Throw -ExpectedMessage '*takes a String value*'
      @($global:FakeCliCalls).Count | Should -Be 0
    }

    It 'treats a declared-but-null value as unmanaged' {
      $Result = & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoodName' = $Null } |
        ConvertFrom-Json
      $Result.requested | Should -Be 0
      $Result.changed | Should -BeFalse
      @($global:FakeCliCalls | Where-Object { $_ -like 'CreateCustomVariable*' }).Count | Should -Be 0
    }
  }

  Context 'deciding what to write' {
    It 'writes nothing when every variable already matches' {
      $Result = & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '129.0.6668.90' } |
        ConvertFrom-Json
      $Result.changed | Should -BeFalse
      $Result.unchanged | Should -Contain 'GoogleLlc_GoogleChrome'
      @($global:FakeCliCalls | Where-Object { $_ -like 'CreateCustomVariable*' }).Count | Should -Be 0
    }

    It 'writes only the variable that differs, leaving the rest alone' {
      $Result = & $script:ScriptPath -CliPath $script:CliPath -Variable @{
        'GoogleLlc_GoogleChrome' = '130.0.0.0'
        'MozillaOrg_Firefox'     = '131.0'
      } | ConvertFrom-Json
      $Result.applied | Should -Be @('GoogleLlc_GoogleChrome')
      $Result.unchanged | Should -Contain 'MozillaOrg_Firefox'
      $Result.changed | Should -BeTrue
      $global:FakeVariables['GoogleLlc_GoogleChrome'] | Should -Be '130.0.0.0'
      @($global:FakeCliCalls | Where-Object { $_ -like 'CreateCustomVariable*' }).Count | Should -Be 1
    }

    It 'treats case-only drift as a change, not a match' {
      $global:FakeVariables['MozillaOrg_Firefox'] = 'esr'
      $Result = & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'MozillaOrg_Firefox' = 'ESR' } |
        ConvertFrom-Json
      $Result.applied | Should -Contain 'MozillaOrg_Firefox'
    }

    It 'creates a variable the product does not yet hold' {
      $Result = & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'NotepadPlusPlusTeam_NotepadPlusPlus' = '8.7.1' } |
        ConvertFrom-Json
      $Result.applied | Should -Contain 'NotepadPlusPlusTeam_NotepadPlusPlus'
      $Result.changed | Should -BeTrue
      $global:FakeVariables['NotepadPlusPlusTeam_NotepadPlusPlus'] | Should -Be '8.7.1'
    }

    It 'treats an empty store (a fresh install, ExportVariables exit 3) as no variables and creates them all' {
      $global:FakeVariables = @{}
      $Result = & $script:ScriptPath -CliPath $script:CliPath -Variable @{
        'GoogleLlc_GoogleChrome' = '129.0.6668.90'
        'MozillaOrg_Firefox'     = '131.0'
      } | ConvertFrom-Json
      $Result.applied.Count | Should -Be 2
      $Result.changed | Should -BeTrue
    }
  }

  Context 'proving the write landed' {
    It 'reports a variable the product accepted and discarded as ignored, and fails' {
      $global:FakeIgnored = @('GoogleLlc_GoogleChrome')
      $Output = & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '200.0' }
      $Result = $Output | ConvertFrom-Json
      $Result.ignored | Should -Be @('GoogleLlc_GoogleChrome')
      $Result.applied | Should -BeNullOrEmpty
      $Result.changed | Should -BeFalse
      $Result.msg | Should -Match 'accepted but did not apply'
    }

    It 'exports twice: once to decide, once to prove' {
      & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '130.0.0.0' } | Out-Null
      @($global:FakeCliCalls | Where-Object { $_ -like 'ExportVariables*' }).Count | Should -Be 2
    }

    It 'leaves no export file behind' {
      & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '130.0.0.0' } | Out-Null
      Test-Path -LiteralPath $script:ExportPath | Should -BeFalse
    }

    It 'fails loudly when the export itself fails' {
      $global:FakeExportFails = $True
      { & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '130.0.0.0' } } |
        Should -Throw
    }
  }

  Context '$Ansible transport' {
    It 'sets Changed=$False explicitly when nothing differs' {
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '129.0.6668.90' } | Out-Null
      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeFalse
      $Context.Result.msg | Should -Match 'already correct'
    }

    It 'fails the task when a variable was ignored, publishing the evidence first' {
      $global:FakeIgnored = @('GoogleLlc_GoogleChrome')
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '200.0' } | Out-Null
      $Context.Failed | Should -BeTrue
      $Context.Result.ignored | Should -Be @('GoogleLlc_GoogleChrome')
    }

    It 'reports the would-be change in check mode and writes nothing' {
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -CliPath $script:CliPath -Variable @{ 'GoogleLlc_GoogleChrome' = '130.0.0.0' } | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $global:FakeVariables['GoogleLlc_GoogleChrome'] | Should -Be '129.0.6668.90'
      @($global:FakeCliCalls | Where-Object { $_ -like 'ExportVariables*' }).Count | Should -Be 1
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
      $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Set-PdqVariable.ps1') -Raw
      $Source | Should -Match "ErrorActionPreference = 'Continue'"
      $Source | Should -Match '& \$FilePath @Argument 2>&1'
      $Source | Should -Match '\[System\.Management\.Automation\.ErrorRecord\]'
    }
    It 'carries the same native-command helper as its siblings' {
      # There is no shared module -- one file per script is the org contract -- so the five copies
      # are kept identical by checking, not by convention. A fix applied to one and not the others
      # is the realistic hazard, and no other assertion here would notice it.
      $Extract = {
        Param ($File)
        $Text = Get-Content -LiteralPath $File -Raw
        $Start = $Text.IndexOf('Function Invoke-NativeCommand')
        $Text.Substring($Start, $Text.IndexOf("`n}", $Start) - $Start)
      }
      $Mine = & $Extract (Join-Path $PSScriptRoot 'Set-PdqVariable.ps1')
      ForEach ($Sibling In @('Set-PdqPackage.ps1', 'Remove-PdqPackage.ps1', 'Set-PdqVariable.ps1',
          'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1')) {
        (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because $Sibling
      }
    }
  }

}
