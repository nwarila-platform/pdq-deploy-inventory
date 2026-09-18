#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Set-PdqVariable.ps1. Product executables are path-shaped functions, so the
    complete read, minimal writes, established prune transaction and read-back proof run on Linux
    CI without either product installed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path $PSScriptRoot 'Set-PdqVariable.ps1'
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
  $script:SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe'
  $script:DatabasePath = 'C:\Data\Inventory.db'
  $script:ExportPath = 'C:\Windows\Temp\pdq-variables-export.xml'
  $global:FakeDatabasePath = $script:DatabasePath
  $global:FakeExportPath = $script:ExportPath

  Function New-AnsibleContext {
    Param ([Switch] $CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    Return $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name:'Ansible' -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
  }

  Function global:Write-FakeVariableExport {
    $Lines = [System.Collections.Generic.List[System.String]]::new()
    $Lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $Lines.Add('<AdminArsenal.Export><VariablesSettingsViewModel><CustomVariables type="list">')
    ForEach ($Name In ($global:FakeVariables.Keys | Sort-Object)) {
      $Lines.Add('<CustomVariable><Name>{0}</Name><Value>{1}</Value></CustomVariable>' -f @(
          [System.Security.SecurityElement]::Escape($Name)
          [System.Security.SecurityElement]::Escape($global:FakeVariables[$Name])
        ))
    }
    $Lines.Add('</CustomVariables></VariablesSettingsViewModel></AdminArsenal.Export>')
    Set-Content -LiteralPath:$global:FakeExportPath -Value:($Lines -join [System.Environment]::NewLine) -Encoding:'utf8' -WhatIf:$False
  }

  Function global:Get-FakeHex {
    Param ([System.String] $Text)
    Return -join ([System.Text.Encoding]::UTF8.GetBytes($Text) |
        ForEach-Object { $PSItem.ToString('X2') })
  }
}

Describe 'Set-PdqVariable' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Attributes = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:ScriptPath, [ref]$Null, [ref]$Null
    ).ParamBlock.Attributes
    $Binding = $Attributes | Where-Object { $PSItem.TypeName.FullName -eq 'CmdletBinding' }
    $Binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
  }

  BeforeEach {
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType:'Directory' -Path:$script:Sandbox -Force | Out-Null
    $script:MountedDrive = $Null
    If (-not (Get-PSDrive -Name:'C' -ErrorAction:'SilentlyContinue')) {
      New-PSDrive -Name:'C' -PSProvider:'FileSystem' -Root:$script:Sandbox -Scope:'Global' |
        Out-Null
      $script:MountedDrive = 'C'
    }
    ForEach ($Path In @($script:CliPath, $script:SqlitePath, $script:DatabasePath)) {
      New-Item -ItemType:'Directory' -Path:(Split-Path -Parent $Path) -Force | Out-Null
      Set-Content -LiteralPath:$Path -Value:'stub' -WhatIf:$False
    }
    $script:SqliteCommand = Join-Path -Path:(Split-Path -Path:$script:CliPath -Parent) `
      -ChildPath:'sqlite3.exe'
    New-Item -ItemType:'Directory' -Path:(Split-Path -Parent $script:ExportPath) -Force |
      Out-Null

    $global:FakeVariables = @{
      'GoogleLlc_GoogleChrome' = '129.0'
      'MozillaOrg_Firefox'     = '131.0'
    }
    $global:FakeIds = @{
      'GoogleLlc_GoogleChrome' = 1
      'MozillaOrg_Firefox'     = 2
    }
    $global:FakeNextId = 3
    $global:FakeIgnored = @()
    $global:FakeUndeletable = @()
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeSqliteCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    New-Item -Force -Path:('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      Switch ($args[0]) {
        'ExportVariables' {
          If ($global:FakeVariables.Count -eq 0) {
            $global:LASTEXITCODE = 3
            Return
          }
          Write-FakeVariableExport
          $global:LASTEXITCODE = 0
        }
        'CreateCustomVariable' {
          $Name = [System.String]$args[2]
          If ($global:FakeIgnored -notcontains $Name) {
            If (-not $global:FakeIds.ContainsKey($Name)) {
              $global:FakeIds[$Name] = $global:FakeNextId
              $global:FakeNextId++
            }
            $global:FakeVariables[$Name] = [System.String]$args[4]
          }
          $global:LASTEXITCODE = 0
        }
        'SystemInfo' {
          Write-Output ('Database : {0}' -f $global:FakeDatabasePath)
          $global:LASTEXITCODE = 0
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null

    New-Item -Force -Path:('function:global:' + $script:SqliteCommand) -Value {
      $Sql = [System.String]$args[1]
      $global:FakeSqliteCalls.Add($Sql)
      If ($Sql -like 'SELECT CustomVariableId*') {
        ForEach ($Name In ($global:FakeVariables.Keys | Sort-Object)) {
          Write-Output ('{0}|{1}' -f $global:FakeIds[$Name], (Get-FakeHex -Text:$Name))
        }
      } ElseIf ($Sql -like '*DELETE FROM CustomVariables*') {
        ForEach ($Match In [Regex]::Matches(
            $Sql, "CustomVariableId = ([0-9]+) AND hex\(Name\) = '([0-9A-F]+)'")) {
          $Id = [System.Int32]$Match.Groups[1].Value
          $Hex = $Match.Groups[2].Value
          $Name = @($global:FakeIds.Keys | Where-Object {
              $global:FakeIds[$PSItem] -eq $Id -and (Get-FakeHex -Text:$PSItem) -ceq $Hex
            } | Select-Object -First 1)
          If ($Name.Count -eq 1 -and $global:FakeUndeletable -notcontains $Name[0]) {
            $global:FakeVariables.Remove($Name[0])
            $global:FakeIds.Remove($Name[0])
          }
        }
      }
      $global:LASTEXITCODE = 0
    } | Out-Null
  }

  AfterEach {
    Remove-Item -LiteralPath:('function:global:' + $script:CliPath) -Force -ErrorAction:'SilentlyContinue'
    Remove-Item -LiteralPath:('function:global:' + $script:SqliteCommand) -Force -ErrorAction:'SilentlyContinue'
    If ($script:MountedDrive) {
      Remove-PSDrive -Name:$script:MountedDrive -Force -ErrorAction:'SilentlyContinue'
    }
    Remove-Item -LiteralPath:$script:Sandbox -Recurse -Force -ErrorAction:'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name:'FakeVariables', 'FakeIds', 'FakeNextId', 'FakeIgnored',
      'FakeUndeletable', 'FakeCliCalls', 'FakeSqliteCalls', 'FakeExportPath',
      'FakeDatabasePath' -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
  }

  It 'reads the whole declared map in one ExportVariables launch on a converged host' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{
      'GoogleLlc_GoogleChrome' = '129.0'
      'MozillaOrg_Firefox'     = '131.0'
    } | Out-Null
    $Context.Changed | Should -BeFalse
    @($global:FakeCliCalls -like 'ExportVariables*').Count | Should -Be 1
  }

  It 'writes only a declared variable whose value differs' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{
      'GoogleLlc_GoogleChrome' = '130.0'
      'MozillaOrg_Firefox'     = '131.0'
    } | Out-Null
    $Context.Result.applied | Should -Be @('GoogleLlc_GoogleChrome')
    $Context.Result.unchanged | Should -Be @('MozillaOrg_Firefox')
    @($global:FakeCliCalls -like 'CreateCustomVariable*').Count | Should -Be 1
  }

  It 'removes every undeclared variable and names it in the result' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{
      'GoogleLlc_GoogleChrome' = '129.0'
    } | Out-Null
    $Context.Changed | Should -BeTrue
    $Context.Result.removed | Should -Be @('MozillaOrg_Firefox')
    $global:FakeVariables.Keys | Should -Not -Contain 'MozillaOrg_Firefox'
  }

  It 'treats an empty declaration as an instruction to remove every custom variable' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{} | Out-Null
    $Context.Result.removed.Count | Should -Be 2
    $global:FakeVariables.Count | Should -Be 0
  }

  It 'reads back once after writes and fails while naming a variable that did not settle' {
    $global:FakeIgnored = @('GoogleLlc_GoogleChrome')
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{
      'GoogleLlc_GoogleChrome' = '130.0'
      'MozillaOrg_Firefox'     = '131.0'
    } | Out-Null
    $Context.Failed | Should -BeTrue
    $Context.Result.ignored | Should -Be @('GoogleLlc_GoogleChrome')
    @($global:FakeCliCalls -like 'ExportVariables*').Count | Should -Be 2
  }

  It 'fails while naming an undeclared variable the delete did not remove' {
    $global:FakeUndeletable = @('MozillaOrg_Firefox')
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{
      'GoogleLlc_GoogleChrome' = '129.0'
    } | Out-Null
    $Context.Failed | Should -BeTrue
    $Context.Result.survivors | Should -Be @('MozillaOrg_Firefox')
  }

  It 'reports the complete would-change set in check mode without mutating it' {
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{
      'GoogleLlc_GoogleChrome' = '130.0'
    } | Out-Null
    $Context.Changed | Should -BeTrue
    $Context.Result.applied | Should -Be @('GoogleLlc_GoogleChrome')
    $Context.Result.removed | Should -Be @('MozillaOrg_Firefox')
    $global:FakeVariables['GoogleLlc_GoogleChrome'] | Should -Be '129.0'
    $global:FakeVariables.Keys | Should -Contain 'MozillaOrg_Firefox'
    @($global:FakeCliCalls -like 'ExportVariables*').Count | Should -Be 1
  }

  It 'refuses an invalid request before reading the product' {
    { & $script:ScriptPath -CliPath:$script:CliPath -Variable:@{ 'Bad$Name' = '1' } } |
      Should -Throw '*not a valid PDQ variable name*'
    $global:FakeCliCalls.Count | Should -Be 0
  }

  It 'carries the same native-command helper as its remaining siblings' {
    $Extract = {
      Param ($File)
      $Text = Get-Content -LiteralPath:$File -Raw
      $Start = $Text.IndexOf('Function Invoke-NativeCommand')
      Return $Text.Substring($Start, $Text.IndexOf([System.Environment]::NewLine + '}', $Start) - $Start)
    }
    $Mine = & $Extract $script:ScriptPath
    ForEach ($Sibling In @(
        'Set-PdqPackage.ps1', 'Set-PdqVariable.ps1',
        'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1', 'Set-PdqCollection.ps1')) {
      (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because:$Sibling
    }
  }
}
