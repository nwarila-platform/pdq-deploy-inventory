#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Remove-PdqVariable.ps1 (org pair convention: every script ships with a sibling
    <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script drives two external programs -- the product's
    command line at the path the CALLER passes, and the sqlite3.exe the script derives beside it --
    so this file registers FUNCTIONS named with those exact path strings: PowerShell's call
    operator resolves a path-shaped command to a function of that name before it looks for a file
    on disk, which lets the whole flow -- export, delete, export again -- run with no PDQ
    installed. The stubs also set $LASTEXITCODE, because a function does not and the script reads
    it after every call.

    Stub state lives in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's. $global:FakeVariables is
    the product's variable store; the sqlite3 stub mutates it by parsing the DELETE batch it is
    handed, so a test states an outcome rather than a sequence of calls. $global:FakeUndeletable
    names a variable the database accepts a DELETE for and does NOT remove -- the exact failure
    the read-back exists to catch.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Remove-PdqVariable.ps1'
  # The caller passes the CLI path; a Windows-shaped string so the path-function trick resolves.
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
  $script:SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
  $script:DbPath = 'C:\PDQ Data\Database.db'

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
}

Describe 'Remove-PdqVariable' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Attributes = [System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path $PSScriptRoot 'Remove-PdqVariable.ps1'), [ref]$Null, [ref]$Null
    ).ParamBlock.Attributes
    $Binding = $Attributes | Where-Object { $_.TypeName.FullName -eq 'CmdletBinding' }
    $Binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
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
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:CliPath) -Force | Out-Null
    Set-Content -LiteralPath $script:CliPath -Value 'stub' -WhatIf:$False
    Set-Content -LiteralPath $script:SqlitePath -Value 'stub' -WhatIf:$False
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:DbPath) -Force | Out-Null
    Set-Content -LiteralPath $script:DbPath -Value 'db' -WhatIf:$False

    $script:Chrome = 'GoogleLlc_GoogleChrome'
    $script:Firefox = 'Mozilla_MozillaFirefox'
    $global:FakeVariables = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeUndeletable = @()
    $global:FakeExportExit = $Null
    $global:FakeExportNoFile = $False
    $global:FakeNoDbLine = $False
    $global:FakeSqliteExit = 0
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeSqlBatches = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeTableHides = @()
    $global:FakeDeleted = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeDbPath = $script:DbPath
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    # The product's command line. A path-shaped call resolves to this function.
    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      Switch ($args[0]) {
        'ExportVariables' {
          # The exact vector, so swapping a flag fails the spec rather than passing unnoticed.
          If ($args.Count -ne 4 -or $args[1] -ne '-Path' -or $args[3] -ne '-Overwrite') {
            Throw ('unexpected ExportVariables arguments: {0}' -f ($args -join ' '))
          }
          $Exit = If ($Null -ne $global:FakeExportExit) { $global:FakeExportExit }
                  ElseIf ($global:FakeVariables.Count -eq 0) { 3 } Else { 0 }
          If ($Exit -eq 0 -and -not $global:FakeExportNoFile) {
            $Lines = [System.Collections.Generic.List[System.String]]::new()
            $Lines.Add('<?xml version="1.0" encoding="utf-8"?>')
            $Lines.Add('<AdminArsenal.Export><VariablesSettingsViewModel><CustomVariables type="list">')
            ForEach ($Held In $global:FakeVariables) {
              $Lines.Add(('<CustomVariable><Name>{0}</Name><Value>x</Value></CustomVariable>' -f
                [System.Security.SecurityElement]::Escape($Held)))
            }
            $Lines.Add('</CustomVariables></VariablesSettingsViewModel></AdminArsenal.Export>')
            Set-Content -LiteralPath $args[2] -Value ($Lines -join "`n") -WhatIf:$False
          }
          $global:LASTEXITCODE = $Exit
        }
        'SystemInfo' {
          'Console Version: 20.1.8.0'
          If (-not $global:FakeNoDbLine) { 'Database: ' + $global:FakeDbPath }
          'License Mode: Enterprise'
          $global:LASTEXITCODE = 0
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null

    # The vendor's database tool, resolved beside the command line. The stub honors the batch it
    # is handed: it parses each DELETE's name literal, un-doubles the quote escaping, and mutates
    # the store -- so a test about escaping is a test about an outcome, not about string shape.
    # Registered under the SPELLING THE SCRIPT COMPUTES: Join-Path renders the separator for the
    # platform the spec runs on, and a function name matches as a string, not as a path.
    $script:SqliteCallable = Join-Path -Path (Split-Path -Path $script:CliPath -Parent) -ChildPath 'sqlite3.exe'
    New-Item -Force -Path ('function:global:' + $script:SqliteCallable) -Value {
      If ($args.Count -ne 2) {
        Throw ('unexpected sqlite3 arguments: {0}' -f ($args -join ' '))
      }
      If ($args[1] -like '*SELECT CustomVariableId, hex(Name) FROM CustomVariables;*') {
        # Measured: PRAGMA busy_timeout echoes its value as an output row, which the script's
        # strict parse would refuse -- so the read must carry no pragma at all.
        If ($args[1] -match 'PRAGMA') {
          Throw 'the id read must not carry a pragma: its echo is a malformed row to the parser'
        }
        # Row ids are the name's position plus one, stable for the test's lifetime, hex exactly
        # as SQLite renders it: upper-case, of the UTF-8 bytes. A name in FakeTableHides is
        # withheld -- the export and the table disagreeing is a state the script must refuse.
        For ($I = 0; $I -lt $global:FakeVariables.Count; $I++) {
          $Held = $global:FakeVariables[$I]
          If ($global:FakeTableHides -contains $Held) { Continue }
          $Hex = -join ([System.Text.Encoding]::UTF8.GetBytes($Held) | ForEach-Object { $_.ToString('X2') })
          '{0}|{1}' -f ($I + 1), $Hex
        }
        $global:LASTEXITCODE = 0
        Return
      }
      $global:FakeSqlBatches.Add($args[1])
      # The batch's own pragma echoes '5000' -- measured -- and the script must not read the
      # delete invocation's output at all.
      '5000'
      $Match = [System.Text.RegularExpressions.Regex]::Match(
        $args[1], 'DELETE FROM CustomVariables WHERE CustomVariableId IN \(([0-9, ]+)\);')
      If ($Match.Success) {
        ForEach ($Id In ($Match.Groups[1].Value -split ',\s*')) {
          $Target = $global:FakeVariables[[System.Int32]$Id - 1]
          If ($global:FakeUndeletable -notcontains $Target) {
            $global:FakeDeleted.Add($Target)
          }
        }
        # Removal happens after the loop so the position-derived ids stay stable within one batch.
        ForEach ($Gone In $global:FakeDeleted) { $Null = $global:FakeVariables.Remove($Gone) }
      }
      $global:LASTEXITCODE = $global:FakeSqliteExit
    } | Out-Null
  }

  AfterEach {
    Remove-Item -LiteralPath ('function:global:' + $script:CliPath) -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:SqliteCallable) -Force -ErrorAction 'SilentlyContinue'
    If ($script:MountedDrive) {
      Remove-PSDrive -Name $script:MountedDrive -Force -ErrorAction 'SilentlyContinue'
    }
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name 'FakeVariables', 'FakeUndeletable', 'FakeExportExit', 'FakeExportNoFile',
      'FakeNoDbLine', 'FakeSqliteExit', 'FakeCliCalls', 'FakeSqlBatches', 'FakeDbPath',
      'FakeTableHides', 'FakeDeleted' `
      -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Context 'when the product already holds exactly what was declared' {
    It 'removes nothing and reports unchanged' {
      $global:FakeVariables.Add($script:Chrome)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeFalse
      $Context.Result.msg | Should -Match 'No undeclared variables'
      $global:FakeSqlBatches.Count | Should -Be 0
    }

    It 'still proves the final state from a fresh reading when it removed nothing' {
      # The claim is about the product NOW, so it may not be made from a reading taken earlier.
      $global:FakeVariables.Add($script:Chrome)
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath | Out-Null
      @($global:FakeCliCalls -like 'ExportVariables*').Count | Should -Be 2
    }

    It 'keeps a case-variant of a declared name, agreeing with the import step' {
      # The import script's current-state lookup treats a name differing only by case as the same
      # variable, so a case-variant has already been accepted as satisfying the declaration.
      # Removing it here would delete a variable the import just called correct. The opposite of
      # the package pruner, whose import step is byte-exact -- each agrees with its own importer.
      $global:FakeVariables.Add($script:Chrome.ToUpper())
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      $Context.Result.kept | Should -Be @($script:Chrome.ToUpper())
      $global:FakeVariables | Should -Be @($script:Chrome.ToUpper())
    }
  }

  Context 'when the product holds something the declaration does not name' {
    It 'removes it and keeps the declared one' {
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeVariables.Add($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeFalse
      $Context.Result.removed | Should -Be @($script:Firefox)
      $Context.Result.kept | Should -Be @($script:Chrome)
      $global:FakeVariables | Should -Be @($script:Chrome)
    }

    It 'empties the product when the declaration is empty' {
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeVariables.Add($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @() -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.removed.Count | Should -Be 2
      $global:FakeVariables.Count | Should -Be 0
    }

    It 'treats an export that says the product holds none as an empty state, not a failure' {
      # Exit 3 with no file is the product's own way of saying "none yet".
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @() -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      $Context.Result.msg | Should -Match 'No undeclared variables'
    }

    It 'fails when the database accepts a delete it did not perform' {
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeVariables.Add($script:Firefox)
      $global:FakeUndeletable = @($script:Firefox)
      { & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*still holds the undeclared variable*'
    }

    It 'fails when the database tool reports a non-zero exit code' {
      $global:FakeVariables.Add($script:Firefox)
      $global:FakeSqliteExit = 1
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*Removing the undeclared variables*exited 1*'
    }
  }

  Context 'the database write' {
    It 'deletes by validated integer id in one immediate transaction, never by name' {
      $global:FakeVariables.Add('Stray One')
      $global:FakeVariables.Add('Stray Two')
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Name @() -CliPath $script:CliPath | Out-Null
      $global:FakeSqlBatches.Count | Should -Be 1
      $global:FakeSqlBatches[0] | Should -Match '^PRAGMA busy_timeout = 5000; BEGIN IMMEDIATE; DELETE FROM CustomVariables WHERE CustomVariableId IN \(1, 2\); COMMIT;$'
      $global:FakeSqlBatches[0] | Should -Not -Match 'Stray'
    }

    It 'removes a name no SQL literal could carry safely, because no name enters SQL' {
      $Awkward = "O'Brien`"s`r`nBuild|x"
      $global:FakeVariables.Add($Awkward)
      $global:FakeVariables.Add($script:Chrome)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Result.removed | Should -Be @($Awkward)
      $global:FakeVariables | Should -Be @($script:Chrome)
      $global:FakeSqlBatches[0] | Should -Not -Match 'Brien'
    }

    It 'refuses to prune when the export and the table disagree about a name' {
      $global:FakeVariables.Add($script:Firefox)
      $global:FakeTableHides = @($script:Firefox)
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*readings disagree*'
      $global:FakeSqlBatches.Count | Should -Be 0
      $global:FakeVariables.Count | Should -Be 1
    }

    It 'refuses a product holding two names that differ only by case' {
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeVariables.Add($script:Chrome.ToUpper())
      { & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*differing only by case*'
      $global:FakeVariables.Count | Should -Be 2
    }

    It 'keeps a name the product spelled with surrounding spaces intact' {
      # Trimming would address a different variable than the one the product named.
      $global:FakeVariables.Add(' ' + $script:Chrome)
      $global:FakeVariables.Add($script:Chrome)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Result.removed | Should -Be @(' ' + $script:Chrome)
      $global:FakeVariables | Should -Be @($script:Chrome)
    }

    It 'refuses to run without the database tool beside the command line' {
      $global:FakeVariables.Add($script:Firefox)
      Remove-Item -LiteralPath $script:SqlitePath -Force
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*database tool is not at*'
      $global:FakeVariables.Count | Should -Be 1
    }

    It 'refuses a system information report with no database path' {
      $global:FakeVariables.Add($script:Firefox)
      $global:FakeNoDbLine = $True
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*did not report a database path*'
    }

    It 'refuses a reported database path with no database behind it' {
      $global:FakeVariables.Add($script:Firefox)
      $global:FakeDbPath = 'C:\PDQ Data\Not-There.db'
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*database is not at*'
    }

    It 'fails check mode on a host where removal is impossible, rather than promising it' {
      $global:FakeVariables.Add($script:Firefox)
      Remove-Item -LiteralPath $script:SqlitePath -Force
      New-AnsibleContext -CheckMode | Out-Null
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*database tool is not at*'
    }

    It 'does not touch the database in check mode, and reports what it would remove' {
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeVariables.Add($script:Firefox)
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $Context.Result.removed | Should -Be @($script:Firefox)
      $Context.Result.msg | Should -Match 'Would remove'
      $global:FakeSqlBatches.Count | Should -Be 0
      $global:FakeVariables.Count | Should -Be 2
    }
  }

  Context 'a reading it cannot trust' {
    It 'refuses to prune against a failed export' {
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeExportExit = 1
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*Exporting the variables*exited 1*'
      $global:FakeSqlBatches.Count | Should -Be 0
    }

    It 'refuses an export that reported success and wrote no file' {
      # A read that failed must never be read as "the product holds nothing".
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeExportNoFile = $True
      { & $script:ScriptPath -Name @() -CliPath $script:CliPath } |
        Should -Throw '*reported success and wrote no file*'
      $global:FakeSqlBatches.Count | Should -Be 0
    }

    It 'fails when a declared variable is not there afterwards' {
      # Nothing declared is held: the promise is not true, whatever the deletes reported.
      { & $script:ScriptPath -Name @($script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*does not hold the declared variable*'
    }

    It 'refuses a command line that is not there' {
      { & $script:ScriptPath -Name @() -CliPath 'C:\nope\PDQDeploy.exe' } |
        Should -Throw '*command line is not at*'
    }

    It 'keeps all three halves of the native-command contract' {
      # Measured on a Windows target under win_powershell with error_action stop: with the
      # preference at Stop a native command's stderr is a TERMINATING error, redirected or not; left
      # on its own stream it becomes an error record and the module fails the task even though
      # nothing threw. So the preference is lowered across the call, stderr is merged into the
      # capture, and the records are separated back out of the output. Drop any one and the ordinary
      # "not found" the product writes alongside an absent-means-absent exit code fails the run.
      # Pinned here because all three are invisible on review.
      $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Remove-PdqVariable.ps1') -Raw
      $Source | Should -Match "ErrorActionPreference = 'Continue'"
      $Source | Should -Match '& \$FilePath @Argument 2>&1'
      $Source | Should -Match '\[System\.Management\.Automation\.ErrorRecord\]'
    }

    It 'carries the same native-command helper as its siblings' {
      # There is no shared module -- one file per script is the org contract -- so the six copies
      # are kept identical by checking, not by convention. A fix applied to one and not the others
      # is the realistic hazard, and no other assertion here would notice it.
      $Extract = {
        Param ($File)
        $Text = Get-Content -LiteralPath $File -Raw
        $Start = $Text.IndexOf('Function Invoke-NativeCommand')
        $Text.Substring($Start, $Text.IndexOf("`n}", $Start) - $Start)
      }
      $Mine = & $Extract (Join-Path $PSScriptRoot 'Remove-PdqVariable.ps1')
      ForEach ($Sibling In @('Set-PdqPackage.ps1', 'Remove-PdqPackage.ps1', 'Set-PdqVariable.ps1',
          'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1', 'Remove-PdqVariable.ps1')) {
        (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because $Sibling
      }
    }
  }

  Context '$Ansible transport' {
    It 'counts what was declared' {
      $global:FakeVariables.Add($script:Chrome)
      $global:FakeVariables.Add($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Name @($script:Chrome, $script:Firefox) -CliPath $script:CliPath | Out-Null
      $Context.Result.declared | Should -Be 2
      $Context.Changed | Should -BeFalse
    }
  }
}
