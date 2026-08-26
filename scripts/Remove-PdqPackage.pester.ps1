#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Remove-PdqPackage.ps1 (org pair convention: every script ships with a sibling
    <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script drives one external program at a path the CALLER
    passes (-CliPath), so this file registers a FUNCTION named with that exact path string:
    PowerShell's call operator resolves a path-shaped command to a function of that name before it
    looks for a file on disk, which lets the whole flow -- list, delete, list again -- run with no
    PDQ installed. The stub also sets $LASTEXITCODE, because a function does not and the script
    reads it after every call.

    Stub state lives in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's. $global:FakePackages is the
    product's package list; DeletePackages mutates it, so a test states an outcome rather than a
    sequence of calls. $global:FakeUndeletable names a package the command line accepts and does
    NOT remove -- the product reporting success for a delete it did not perform, which is why the
    script reads the list back.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Remove-PdqPackage.ps1'
  # The caller passes the CLI path; a Windows-shaped string so the path-function trick resolves.
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'

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

  # A definition as the caller hands it over: the package's own Name element is what it declares,
  # and any -Nests name appears as a whole element value, the way a nested step names its target.
  Function global:New-Definition {
    Param ([System.String]$Name, [System.String]$Nests)
    $Lines = @(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<AdminArsenal.Export Code="PDQDeploy" Name="PDQ Deploy" Version="20.1.8.0" MinimumVersion="15.0">'
      '  <Package>'
      ('    <Name>{0}</Name>' -f [System.Security.SecurityElement]::Escape($Name))
      '    <Steps type="list">'
    )
    If ($Nests) {
      $Lines += '      <NestedInstallStep>'
      $Lines += ('        <PackageName>{0}</PackageName>' -f [System.Security.SecurityElement]::Escape($Nests))
      $Lines += '      </NestedInstallStep>'
    }
    $Lines += '    </Steps>'
    $Lines += '  </Package>'
    $Lines += '</AdminArsenal.Export>'
    Return ($Lines -join "`n")
  }
}

Describe 'Remove-PdqPackage' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Attributes = [System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path $PSScriptRoot 'Remove-PdqPackage.ps1'), [ref]$Null, [ref]$Null
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
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:CliPath) -Force | Out-Null
    Set-Content -LiteralPath $script:CliPath -Value 'stub' -WhatIf:$False

    $script:Chrome = 'Google Chrome - Install'
    $script:Firefox = 'Mozilla Firefox - Install'
    $global:FakePackages = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeUndeletable = @()
    $global:FakeListExit = 0
    $global:FakeDeleteExit = 0
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    # The product's command line. A path-shaped call resolves to this function.
    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      Switch ($args[0]) {
        'GetPackageNames' {
          # The exact vector: the verb and nothing else.
          If ($args.Count -ne 1) {
            Throw ('unexpected GetPackageNames arguments: {0}' -f ($args -join ' '))
          }
          $global:FakePackages | ForEach-Object { $PSItem }
          $global:LASTEXITCODE = $global:FakeListExit
        }
        'DeletePackages' {
          # The exact vector, so swapping a flag fails the spec rather than passing unnoticed.
          If ($args.Count -ne 4 -or $args[1] -ne '-Name' -or $args[3] -ne '-Force') {
            Throw ('unexpected DeletePackages arguments: {0}' -f ($args -join ' '))
          }
          $Name = $args[2]
          If ($global:FakeUndeletable -notcontains $Name) {
            $Null = $global:FakePackages.Remove($Name)
          }
          $global:LASTEXITCODE = $global:FakeDeleteExit
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null
  }

  AfterEach {
    Remove-Item -LiteralPath ('function:global:' + $script:CliPath) -Force -ErrorAction 'SilentlyContinue'
    If ($script:MountedDrive) {
      Remove-PSDrive -Name $script:MountedDrive -Force -ErrorAction 'SilentlyContinue'
    }
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name 'FakePackages', 'FakeUndeletable', 'FakeListExit', 'FakeDeleteExit',
      'FakeCliCalls' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Context 'when the product already holds exactly what was declared' {
    It 'removes nothing and reports unchanged' {
      $global:FakePackages.Add($script:Chrome)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeFalse
      $Context.Result.msg | Should -Match 'No undeclared packages'
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
    }

    It 'still proves the final state from a fresh reading when it removed nothing' {
      # The claim is about the product NOW, so it may not be made from a reading taken earlier.
      $global:FakePackages.Add($script:Chrome)
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      @($global:FakeCliCalls -like 'GetPackageNames*').Count | Should -Be 2
    }

    It 'treats a case-only difference as a different package, agreeing with the import step' {
      # The import step requires a package to export back byte-for-byte as declared, so a product
      # holding it under another case fails there and the run never reaches this script. Matching
      # exactly here therefore cannot delete what the import just wrote -- and it does mean a
      # case-variant stranger is correctly seen as a stranger.
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Chrome.ToUpper())
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Result.removed | Should -Be @($script:Chrome.ToUpper())
      $global:FakePackages | Should -Be @($script:Chrome)
    }
  }

  Context 'when the product holds something the declaration does not name' {
    It 'removes it and keeps the declared one' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeFalse
      $Context.Result.removed | Should -Be @($script:Firefox)
      $Context.Result.kept | Should -Be @($script:Chrome)
      $global:FakePackages | Should -Be @($script:Chrome)
    }

    It 'empties the product when the declaration is empty' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @() -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.removed.Count | Should -Be 2
      $global:FakePackages.Count | Should -Be 0
    }

    It 'reads the list again to prove the removal, rather than trusting the delete' {
      $global:FakePackages.Add($script:Firefox)
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition @() -CliPath $script:CliPath | Out-Null
      @($global:FakeCliCalls -like 'GetPackageNames*').Count | Should -Be 2
    }

    It 'fails when the command line accepts a delete it did not perform' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Firefox)
      $global:FakeUndeletable = @($script:Firefox)
      { & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*still holds*'
    }

    It 'fails when the delete reports a non-zero exit code' {
      $global:FakePackages.Add($script:Firefox)
      $global:FakeDeleteExit = 4
      { & $script:ScriptPath -Definition @() -CliPath $script:CliPath } |
        Should -Throw '*Removing the package*exited 4*'
    }
  }

  Context 'what a declared package needs' {
    It 'refuses to delete a package a declared definition refers to' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Firefox)
      # Chrome nests Firefox, and Firefox is not declared. Deleting it would leave Chrome broken
      # while every name-set assertion still passed, which is the whole point of the guard.
      { & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome -Nests $script:Firefox) `
          -CliPath $script:CliPath } | Should -Throw '*a declared package refers to it*'
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
      $global:FakePackages.Count | Should -Be 2
    }

    It 'still deletes a stranger nothing refers to' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome -Nests 'Some Other Package') `
        -CliPath $script:CliPath | Out-Null
      $Context.Result.removed | Should -Be @($script:Firefox)
    }

    It 'refuses a definition that is not valid XML, before touching anything' {
      $global:FakePackages.Add($script:Chrome)
      { & $script:ScriptPath -Definition @('not xml') -CliPath $script:CliPath } |
        Should -Throw '*not valid XML*'
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'refuses a definition that does not name a package' {
      { & $script:ScriptPath -Definition @('<?xml version="1.0"?><AdminArsenal.Export><Package /></AdminArsenal.Export>') `
          -CliPath $script:CliPath } | Should -Throw '*does not name a package*'
    }
  }

  Context 'a list it cannot trust' {
    It 'refuses to prune against a failed listing' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakeListExit = 1
      { & $script:ScriptPath -Definition @() -CliPath $script:CliPath } |
        Should -Throw '*Listing the packages*exited 1*'
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
    }

    It 'fails when a declared package is not there afterwards' {
      # Nothing declared is held: the promise is not true, whatever the deletes reported.
      $global:FakePackages.Add($script:Firefox)
      { & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*does not hold the declared package*'
    }

    It 'refuses a held name the command line would read as a selection pattern' {
      ForEach ($Bad In @('Chrome*', 'Chrome?', 'Chrome,Firefox')) {
        $global:FakePackages.Clear()
        $global:FakePackages.Add($Bad)
        $global:FakePackages.Add($script:Chrome)
        $global:FakeCliCalls.Clear()
        { & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath } |
          Should -Throw '*selection syntax*'
        # Nothing is deleted, so a name it cannot address never half-prunes the product.
        @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
        $global:FakePackages.Count | Should -Be 2
      }
    }

    It 'keeps a name the product spelled with surrounding spaces intact' {
      # Trimming would address a different package than the one the product named.
      $global:FakePackages.Add(' Google Chrome - Install')
      $global:FakePackages.Add($script:Chrome)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Result.removed | Should -Be @(' Google Chrome - Install')
      $global:FakePackages | Should -Be @($script:Chrome)
    }

    It 'stops at the first delete that fails, leaving the rest alone' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add('AAA Stranger')
      $global:FakePackages.Add('BBB Stranger')
      $global:FakeDeleteExit = 4
      { & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*Removing the package*exited 4*'
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 1
    }

    It 'refuses a command line that is not there' {
      { & $script:ScriptPath -Definition @() -CliPath 'C:\nope\PDQDeploy.exe' } |
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
      $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Remove-PdqPackage.ps1') -Raw
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
      $Mine = & $Extract (Join-Path $PSScriptRoot 'Remove-PdqPackage.ps1')
      ForEach ($Sibling In @('Set-PdqPackage.ps1', 'Remove-PdqPackage.ps1', 'Set-PdqVariable.ps1',
          'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1', 'Remove-PdqVariable.ps1',
          'Set-PdqCollection.ps1', 'Remove-PdqCollection.ps1')) {
        (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because $Sibling
      }
    }
  }

  Context '$Ansible transport' {
    It 'reports what it would remove in check mode and removes nothing' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Firefox)
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Definition @(New-Definition -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $Context.Result.removed | Should -Be @($script:Firefox)
      $Context.Result.msg | Should -Match 'Would remove'
      $global:FakePackages.Count | Should -Be 2
    }

    It 'counts what was declared' {
      $global:FakePackages.Add($script:Chrome)
      $global:FakePackages.Add($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @((New-Definition -Name $script:Chrome), (New-Definition -Name $script:Firefox)) -CliPath $script:CliPath | Out-Null
      $Context.Result.declared | Should -Be 2
      $Context.Changed | Should -BeFalse
    }
  }
}
