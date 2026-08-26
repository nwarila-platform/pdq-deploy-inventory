#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Set-PdqPackage.ps1 (org pair convention: every script ships with a sibling
    <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script drives one external program at a path the CALLER
    passes (-CliPath), so this file registers a FUNCTION named with that exact path string:
    PowerShell's call operator resolves a path-shaped command to a function of that name before it
    looks for a file on disk, which lets the whole flow -- export, compare, import, re-export,
    verify -- run with no PDQ installed. The stub also sets $LASTEXITCODE, because a function does
    not and the script reads it after every call.

    The script stages its files in the scratch directory the module hands over ($Ansible.Tmpdir),
    so a test supplies a real directory and no Windows path has to exist.

    Stub state lives in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's. $global:FakePackages is the
    product's package store, keyed by package name and holding the export text; ImportPackages
    mutates it, so a test states an outcome rather than a sequence of calls. The export stub's exit
    code and whether it writes a file are set independently, because the product reporting one and
    doing the other is exactly what the script has to survive. $global:FakeIgnored names a package
    the product accepts and does NOT store -- reporting success for a write it did not make, which
    is the whole reason the script verifies.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PdqPackage.ps1'
  # The caller passes the CLI path; a Windows-shaped string so the path-function trick resolves.
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
  # The script refuses a CLI path that is not there, so the spec mounts a C: drive over a temporary
  # directory and puts a file at that exact path. The path-shaped FUNCTION still wins when the
  # command is invoked -- PowerShell resolves a function of that name before a file on disk.

  # Inline $Ansible stand-in (org contract: pairs are self-contained). Faithful to win_powershell:
  # Changed defaults to $True, Tmpdir is scratch the module cleans up, and only the ratified
  # surface is modeled.
  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
      Tmpdir    = $script:Tmpdir
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  # A package as the product exports it (measured 2026-08-25, PDQ Deploy 20.1.8.0): a byte-order
  # mark, CRLF endings, and the name in the element the script reads. $Detail stands in for the
  # rest of the package, so two definitions can differ in something other than the name.
  Function global:New-PackageText {
    Param ([System.String]$Name, [System.String]$Detail = 'Silent install')
    $Lines = @(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<AdminArsenal.Export Code="PDQDeploy" Name="PDQ Deploy" Version="20.1.8.0" MinimumVersion="15.0">'
      '  <Package>'
      ('    <Name>{0}</Name>' -f [System.Security.SecurityElement]::Escape($Name))
      ('    <Description>{0}</Description>' -f [System.Security.SecurityElement]::Escape($Detail))
      '  </Package>'
      '</AdminArsenal.Export>'
    )
    Return ([System.String][System.Char]0xFEFF + ($Lines -join "`r`n") + "`r`n")
  }
}

Describe 'Set-PdqPackage' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Attributes = [System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path $PSScriptRoot 'Set-PdqPackage.ps1'), [ref]$Null, [ref]$Null
    ).ParamBlock.Attributes
    $Binding = $Attributes | Where-Object { $_.TypeName.FullName -eq 'CmdletBinding' }
    $Binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
  }

  BeforeEach {
    $script:Tmpdir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Tmpdir -Force | Out-Null
    $script:MountedDrive = $Null
    If (-not (Get-PSDrive -Name 'C' -ErrorAction 'SilentlyContinue')) {
      New-PSDrive -Name 'C' -PSProvider 'FileSystem' -Root $script:Tmpdir -Scope 'Global' | Out-Null
      $script:MountedDrive = 'C'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:CliPath) -Force | Out-Null
    Set-Content -LiteralPath $script:CliPath -Value 'stub' -WhatIf:$False

    $script:Chrome = 'Google Chrome - Install'
    $global:FakePackages = @{}
    $global:FakeIgnored = @()
    $global:FakeImportExit = 0
    # The export stub's two halves, set apart so a test can state a product that reports one thing
    # and does another. $Null means "behave", i.e. exit 0 with a file or exit 3 without one.
    $global:FakeExportExit = $Null
    $global:FakeExportWritesFile = $Null
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    # The product's command line. A path-shaped call resolves to this function.
    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      Switch ($args[0]) {
        'ExportPackages' {
          # The exact vector, so swapping a flag or adding an argument fails the spec rather than
          # passing unnoticed.
          If ($args.Count -ne 6 -or $args[1] -ne '-Name' -or $args[3] -ne '-Path' -or $args[5] -ne '-Overwrite') {
            Throw ('unexpected ExportPackages arguments: {0}' -f ($args -join ' '))
          }
          $Name = $args[2]
          $Held = $global:FakePackages.ContainsKey($Name)
          $Writes = If ($Null -eq $global:FakeExportWritesFile) { $Held } Else { $global:FakeExportWritesFile }
          # A package the product does not hold: exit 3, "no packages found matching".
          $Exit = If ($Null -eq $global:FakeExportExit) { If ($Held) { 0 } Else { 3 } } Else { $global:FakeExportExit }
          If ($Writes) {
            $Text = If ($Held) { $global:FakePackages[$Name] } Else { New-PackageText -Name $Name -Detail 'partial' }
            Set-Content -LiteralPath $args[4] -Value $Text -NoNewline -WhatIf:$False
          }
          $global:LASTEXITCODE = $Exit
        }
        'ImportPackages' {
          If ($args.Count -ne 4 -or $args[1] -ne '-Path' -or $args[3] -ne '-Overwrite') {
            Throw ('unexpected ImportPackages arguments: {0}' -f ($args -join ' '))
          }
          $Text = Get-Content -LiteralPath $args[2] -Raw
          $Document = [System.Xml.XmlDocument]::new()
          $Document.LoadXml($Text.TrimStart([System.Char]0xFEFF))
          $Name = $Document.SelectSingleNode('/AdminArsenal.Export/Package/Name').InnerText
          # A name in the ignored set is accepted and NOT stored -- the no-op the script exists to
          # catch. Every other name is stored as the product would re-export it: mark and CRLF.
          If ($global:FakeIgnored -notcontains $Name) {
            $global:FakePackages[$Name] =
            [System.String][System.Char]0xFEFF + $Text.TrimStart([System.Char]0xFEFF).Replace("`n", "`r`n")
          }
          $global:LASTEXITCODE = $global:FakeImportExit
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null
  }

  AfterEach {
    If ($script:MountedDrive) {
      Remove-PSDrive -Name $script:MountedDrive -Force -ErrorAction 'SilentlyContinue'
    }
    Remove-Item -LiteralPath $script:Tmpdir -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:CliPath) -Force -ErrorAction 'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name 'FakePackages', 'FakeIgnored', 'FakeImportExit', 'FakeExportExit',
      'FakeExportWritesFile', 'FakeCliCalls' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Context 'the hazards it must not reintroduce' {
    It 'keeps all three halves of the native-command contract' {
      # Measured on a Windows target under win_powershell with error_action stop: with the
      # preference at Stop a native command's stderr is a TERMINATING error, redirected or not; left
      # on its own stream it becomes an error record and the module fails the task even though
      # nothing threw. So the preference is lowered across the call, stderr is merged into the
      # capture, and the records are separated back out of the output. Drop any one and the ordinary
      # "not found" the product writes alongside an absent-means-absent exit code fails the run.
      # Pinned here because all three are invisible on review.
      $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Set-PdqPackage.ps1') -Raw
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
      $Mine = & $Extract (Join-Path $PSScriptRoot 'Set-PdqPackage.ps1')
      ForEach ($Sibling In @('Set-PdqPackage.ps1', 'Remove-PdqPackage.ps1', 'Set-PdqVariable.ps1',
          'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1', 'Remove-PdqVariable.ps1',
          'Set-PdqCollection.ps1', 'Remove-PdqCollection.ps1')) {
        (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because $Sibling
      }
    }

    It 'refuses a command line that is not there' {
      { & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) `
          -CliPath 'C:\nope\PDQDeploy.exe' } | Should -Throw '*command line is not at*'
    }
  }

  Context 'reading the declaration' {
    It 'refuses a definition that is not XML' {
      { & $script:ScriptPath -Definition 'not xml' -CliPath $script:CliPath } | Should -Throw
    }

    It 'refuses a definition that does not name a package' {
      $Nameless = @'
<?xml version="1.0" encoding="utf-8"?>
<AdminArsenal.Export Code="PDQDeploy" Name="PDQ Deploy" Version="20.1.8.0" MinimumVersion="15.0">
  <Package />
</AdminArsenal.Export>
'@
      { & $script:ScriptPath -Definition $Nameless -CliPath $script:CliPath } |
        Should -Throw '*does not name a package*'
    }

    It 'refuses a name the command line would read as a selection pattern' {
      ForEach ($Bad In @('Chrome*', 'Chrome?', 'Chrome,Firefox')) {
        { & $script:ScriptPath -Definition (New-PackageText -Name $Bad) -CliPath $script:CliPath } |
          Should -Throw '*selection syntax*'
      }
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'reads the name before writing anything, so a bad definition writes nothing' {
      { & $script:ScriptPath -Definition 'not xml' -CliPath $script:CliPath } | Should -Throw
      $global:FakePackages.Count | Should -Be 0
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'names the package in its result' {
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $global:Ansible.Result.name | Should -Be $script:Chrome
    }

    It 'returns the declaration, so the pruning step can see what it refers to' {
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $global:Ansible.Result.definition | Should -Match ('<Name>' + [Regex]::Escape($script:Chrome) + '</Name>')
      # Normalised on the way in: the mark and the CRLFs are gone.
      $global:Ansible.Result.definition | Should -Not -Match "`r"
    }
  }

  Context 'deciding what to write' {
    It 'writes nothing when the product already holds the declared package' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'ignores the byte-order mark and the line-ending style when comparing' {
      # The same package, stored the way another tool would write it: no mark, Unix endings.
      $global:FakePackages[$script:Chrome] =
      (New-PackageText -Name $script:Chrome).TrimStart([System.Char]0xFEFF).Replace("`r`n", "`n")
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
    }

    It 'treats case-only drift as a change, not a match' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome -Detail 'silent install'
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome -Detail 'Silent install') `
        -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
    }

    It 'imports a package the product does not hold, reported through exit 3' {
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeFalse
      $Context.Result.msg | Should -Match 'applied'
      $global:FakePackages.Keys | Should -Contain $script:Chrome
    }

    It 'imports again when the product holds the package differently' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome -Detail 'Install v1'
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome -Detail 'Install v2') `
        -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $global:FakePackages[$script:Chrome] | Should -BeLike '*Install v2*'
    }
  }

  Context 'a read it cannot trust' {
    It 'refuses to treat a failed export as a product holding nothing' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome
      $global:FakeExportExit = 1
      $global:FakeExportWritesFile = $false
      { & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*Exporting the package*exited 1*'
      # The package it could not read is the package it must not overwrite.
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'refuses a file written under a failure exit code' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome
      $global:FakeExportExit = 1
      $global:FakeExportWritesFile = $true
      { & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*Exporting the package*exited 1*'
    }

    It 'refuses a success exit code that wrote no file' {
      $global:FakeExportExit = 0
      $global:FakeExportWritesFile = $false
      { & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*wrote no file*'
    }
  }

  Context 'proving the write' {
    It 'exports twice when it writes: once to decide, once to prove' {
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 2
    }

    It 'exports once when it writes nothing' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 1
    }

    It 'fails when the package does not read back as declared, and still reports the write' {
      $global:FakeIgnored = @($script:Chrome)
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Failed | Should -BeTrue
      # The product was told to write: reporting unchanged here would hide a mutation.
      $Context.Changed | Should -BeTrue
      $Context.Result.ignored | Should -BeTrue
      $Context.Result.msg | Should -Match 'does not read back as declared'
    }

    It 'fails loudly when the import itself fails, naming the operation' {
      $global:FakeImportExit = 1
      { & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath } |
        Should -Throw '*Importing the package*exited 1*'
    }

    It 'leaves neither staged file behind' {
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      @(Get-ChildItem -LiteralPath $script:Tmpdir -File).Count | Should -Be 0
    }
  }

  Context '$Ansible transport' {
    It 'sets Changed=$False explicitly when nothing differs' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeFalse
      $Context.Result.msg | Should -Match 'already correct'
    }

    It 'reports the would-be change in check mode and writes nothing' {
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $Context.Result.msg | Should -Match 'would be applied'
      $global:FakePackages.Count | Should -Be 0
      @(Get-ChildItem -LiteralPath $script:Tmpdir -File).Count | Should -Be 0
    }

    It 'reports unchanged in check mode when the package is already correct' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name $script:Chrome
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Definition (New-PackageText -Name $script:Chrome) -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      $Context.Result.msg | Should -Match 'already correct'
    }
  }
}
