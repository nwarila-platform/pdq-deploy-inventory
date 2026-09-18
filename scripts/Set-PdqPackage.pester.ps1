#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Set-PdqPackage.ps1. A path-shaped function models PDQ Deploy's command line,
    including directory-based batched exports, partial-success stderr, minimal imports, forced
    deletes and verification after mutation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path $PSScriptRoot 'Set-PdqPackage.ps1'
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'

  Function New-AnsibleContext {
    Param ([Switch] $CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
      Tmpdir    = $script:Tmpdir
    }
    Return $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name:'Ansible' -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
  }

  Function global:New-PackageText {
    Param (
      [System.String] $Name,
      [System.String] $Detail = 'Silent install',
      [System.String] $Dependency = ''
    )
    $Lines = [System.Collections.Generic.List[System.String]]::new()
    $Lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $Lines.Add('<AdminArsenal.Export Code="PDQDeploy" Name="PDQ Deploy" Version="20.1.8.0">')
    $Lines.Add('  <Package>')
    $Lines.Add(('    <Name>{0}</Name>' -f [System.Security.SecurityElement]::Escape($Name)))
    $Lines.Add(('    <Description>{0}</Description>' -f `
          [System.Security.SecurityElement]::Escape($Detail)))
    If ($Dependency.Length -gt 0) {
      $Lines.Add('    <PackageStep>')
      $Lines.Add(('      <PackageName>{0}</PackageName>' -f `
            [System.Security.SecurityElement]::Escape($Dependency)))
      $Lines.Add('    </PackageStep>')
    }
    $Lines.Add('  </Package>')
    $Lines.Add('</AdminArsenal.Export>')
    Return ([System.String][System.Char]0xFEFF + ($Lines -join "`r`n") + "`r`n")
  }
}

Describe 'Set-PdqPackage' {
  It 'declares a plural package parameter and supports check mode' {
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:ScriptPath, [ref]$Null, [ref]$Null
    )
    $Definition = $Ast.ParamBlock.Parameters |
      Where-Object { $PSItem.Name.VariablePath.UserPath -eq 'Definition' }
    $Binding = $Ast.ParamBlock.Attributes |
      Where-Object { $PSItem.TypeName.FullName -eq 'CmdletBinding' }
    $Definition.StaticType | Should -Be ([System.String[]])
    $Binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
  }

  BeforeEach {
    $script:Tmpdir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType:'Directory' -Path:$script:Tmpdir -Force | Out-Null
    $script:MountedDrive = $Null
    If (-not (Get-PSDrive -Name:'C' -ErrorAction:'SilentlyContinue')) {
      New-PSDrive -Name:'C' -PSProvider:'FileSystem' -Root:$script:Tmpdir -Scope:'Global' |
        Out-Null
      $script:MountedDrive = 'C'
    }
    New-Item -ItemType:'Directory' -Path:(Split-Path -Parent $script:CliPath) -Force |
      Out-Null
    Set-Content -LiteralPath:$script:CliPath -Value:'stub' -WhatIf:$False

    $script:Chrome = 'Google Chrome - Install'
    $script:Firefox = 'Mozilla Firefox - Install'
    $global:FakePackages = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
      [System.StringComparer]::Ordinal
    )
    $global:FakePackages.Add($script:Chrome, (New-PackageText -Name:$script:Chrome))
    $global:FakePackages.Add($script:Firefox, (New-PackageText -Name:$script:Firefox))
    $global:FakeIgnored = @()
    $global:FakeUndeletable = @()
    $global:FakeImportExit = 0
    $global:FakeDeleteExit = 0
    $global:FakeListExit = 0
    $global:FakeExportExit = $Null
    $global:FakeExportOmissions = @()
    $global:FakeExportExtraError = @()
    $global:FakeExportSuppressMissingError = $False
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeCliArgumentCalls = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeExportBatches = [System.Collections.Generic.List[System.Object]]::new()
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    New-Item -Force -Path:('function:global:' + $script:CliPath) -Value {
      $Argument = [System.String[]]@($args)
      $global:FakeCliCalls.Add($Argument -join ' ')
      $global:FakeCliArgumentCalls.Add([PSCustomObject]@{ Argument = $Argument })
      Switch ($Argument[0]) {
        'GetPackageNames' {
          If ($Argument.Count -ne 1) {
            Throw ('unexpected GetPackageNames arguments: {0}' -f ($Argument -join ' '))
          }
          If ($global:FakeListExit -eq 0) {
            $global:FakePackages.Keys | ForEach-Object { Write-Output $PSItem }
          }
          $global:LASTEXITCODE = $global:FakeListExit
        }
        'ExportPackages' {
          $NameIndex = [System.Array]::IndexOf($Argument, '-Name')
          $PathIndex = [System.Array]::IndexOf($Argument, '-Path')
          If ($NameIndex -ne 1 -or $PathIndex -le 2 -or
            $Argument[$PathIndex + 2] -cne '-Overwrite' -or
            $PathIndex + 2 -ne $Argument.Count - 1) {
            Throw ('unexpected ExportPackages arguments: {0}' -f ($Argument -join ' '))
          }
          $Names = [System.String[]]@($Argument[($NameIndex + 1)..($PathIndex - 1)])
          $Staged = $Argument[$PathIndex + 1]
          $WasDirectory = Test-Path -LiteralPath:$Staged -PathType:'Container'
          If (-not $WasDirectory) {
            Throw 'ExportPackages requires a directory for multiple names'
          }
          If ($Null -ne $global:FakeExportExit -and
            @(0, 1, 3) -notcontains $global:FakeExportExit) {
            $global:FakeExportBatches.Add([PSCustomObject]@{
                Exit         = $global:FakeExportExit
                Files        = [System.String[]]@()
                Missing      = [System.String[]]@()
                Names        = $Names
                Path         = $Staged
                WasDirectory = $WasDirectory
              })
            $global:LASTEXITCODE = $global:FakeExportExit
            Return
          }

          $Held = [System.String[]]@($Names | Where-Object {
              $global:FakePackages.ContainsKey($PSItem)
            })
          $Missing = [System.String[]]@($Names | Where-Object {
              -not $global:FakePackages.ContainsKey($PSItem)
            })
          $Written = [System.Collections.Generic.List[System.String]]::new()
          $Index = 0
          ForEach ($Name In $Held) {
            If ($global:FakeExportOmissions -notcontains $Name) {
              $FileName = 'package-{0}.xml' -f $Index
              Set-Content -LiteralPath:(Join-Path $Staged $FileName) `
                -Value:$global:FakePackages[$Name] -NoNewline -WhatIf:$False
              $Written.Add($FileName)
              Write-Output ('Exported "{0}" to {1}' -f $Name, (Join-Path $Staged $FileName))
              $Index++
            }
          }
          If (-not $global:FakeExportSuppressMissingError) {
            ForEach ($Name In $Missing) {
              Write-Error -Message:('Error: Package "{0}" not found.' -f $Name)
            }
          }
          ForEach ($Line In $global:FakeExportExtraError) {
            Write-Error -Message:$Line
          }
          $Exit = If ($Null -ne $global:FakeExportExit) {
            $global:FakeExportExit
          } ElseIf ($Held.Count -eq 0) {
            3
          } ElseIf ($Missing.Count -gt 0) {
            1
          } Else {
            0
          }
          $global:FakeExportBatches.Add([PSCustomObject]@{
              Exit         = $Exit
              Files        = $Written.ToArray()
              Missing      = $Missing
              Names        = $Names
              Path         = $Staged
              WasDirectory = $WasDirectory
            })
          $global:LASTEXITCODE = $Exit
        }
        'ImportPackages' {
          If ($Argument.Count -ne 4 -or $Argument[1] -cne '-Path' -or
            $Argument[3] -cne '-Overwrite') {
            Throw ('unexpected ImportPackages arguments: {0}' -f ($Argument -join ' '))
          }
          $Text = Get-Content -LiteralPath:$Argument[2] -Raw
          $Document = [System.Xml.XmlDocument]::new()
          $Document.LoadXml($Text.TrimStart([System.Char]0xFEFF))
          $Name = $Document.SelectSingleNode('/AdminArsenal.Export/Package/Name').InnerText
          If ($global:FakeImportExit -eq 0 -and $global:FakeIgnored -notcontains $Name) {
            $global:FakePackages[$Name] = $Text
          }
          $global:LASTEXITCODE = $global:FakeImportExit
        }
        'DeletePackages' {
          If ($Argument.Count -ne 4 -or $Argument[1] -cne '-Name' -or
            $Argument[3] -cne '-Force') {
            Throw ('unexpected DeletePackages arguments: {0}' -f ($Argument -join ' '))
          }
          If ($global:FakeDeleteExit -eq 0 -and
            $global:FakeUndeletable -notcontains $Argument[2]) {
            $Null = $global:FakePackages.Remove($Argument[2])
          }
          $global:LASTEXITCODE = $global:FakeDeleteExit
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null
  }

  AfterEach {
    Remove-Item -LiteralPath:('function:global:' + $script:CliPath) -Force `
      -ErrorAction:'SilentlyContinue'
    If ($script:MountedDrive) {
      Remove-PSDrive -Name:$script:MountedDrive -Force -ErrorAction:'SilentlyContinue'
    }
    Remove-Item -LiteralPath:$script:Tmpdir -Recurse -Force -ErrorAction:'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name:'FakePackages', 'FakeIgnored', 'FakeUndeletable', 'FakeImportExit',
      'FakeDeleteExit', 'FakeListExit', 'FakeExportExit', 'FakeExportOmissions',
      'FakeExportExtraError', 'FakeExportSuppressMissingError', 'FakeCliCalls',
      'FakeCliArgumentCalls', 'FakeExportBatches' -Scope:'Global' -Force `
      -ErrorAction:'SilentlyContinue'
  }

  Context 'the declaration boundary' {
    It 'refuses a command line that is not there' {
      { & $script:ScriptPath -Definition:@() -CliPath:'C:\nope\PDQDeploy.exe' } |
        Should -Throw '*command line is not at*'
    }

    It 'refuses invalid, nameless and duplicate definitions before reading the product' {
      {
        & $script:ScriptPath -Definition:@('not xml') -CliPath:$script:CliPath
      } | Should -Throw '*not valid XML*'
      $Nameless = '<?xml version="1.0"?><AdminArsenal.Export><Package /></AdminArsenal.Export>'
      {
        & $script:ScriptPath -Definition:@($Nameless) -CliPath:$script:CliPath
      } | Should -Throw '*does not name a package*'
      {
        & $script:ScriptPath -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Chrome -Detail:'second'
        ) -CliPath:$script:CliPath
      } | Should -Throw '*declared more than once*'
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'refuses names the command line would read as selection syntax' {
      ForEach ($Bad In @('Chrome*', 'Chrome?', 'Chrome,Firefox')) {
        {
          & $script:ScriptPath -Definition:@(New-PackageText -Name:$Bad) `
            -CliPath:$script:CliPath
        } | Should -Throw '*selection syntax*'
      }
      $global:FakeCliCalls.Count | Should -Be 0
    }
  }

  Context 'the batched read contract' {
    It 'passes separate names once, uses a directory and trusts each file Name rather than its filename' {
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Changed | Should -BeFalse
      $Exports = @($global:FakeCliArgumentCalls | Where-Object {
          $PSItem.Argument[0] -ceq 'ExportPackages'
        })
      $Exports.Count | Should -Be 1
      $Exports[0].Argument | Should -Be @(
        'ExportPackages'
        '-Name'
        $script:Chrome
        $script:Firefox
        '-Path'
        $global:FakeExportBatches[0].Path
        '-Overwrite'
      )
      $global:FakeExportBatches[0].WasDirectory | Should -BeTrue
      $global:FakeExportBatches[0].Files | Should -Be @('package-0.xml', 'package-1.xml')
      Test-Path -LiteralPath:$global:FakeExportBatches[0].Path | Should -BeFalse
    }

    It 'accepts exit 1 when every missing name has its not-found line' {
      $Null = $global:FakePackages.Remove($script:Firefox)
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Result.applied | Should -Be @($script:Firefox)
      $Context.Result.unchanged | Should -Be @($script:Chrome)
      $global:FakeExportBatches[0].Exit | Should -Be 1
      $global:FakeExportBatches[0].Missing | Should -Be @($script:Firefox)
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 2
    }

    It 'accepts exit 3 when a fresh product holds none of the declaration' {
      $global:FakePackages.Clear()
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Result.applied | Should -Be @($script:Chrome, $script:Firefox)
      $global:FakeExportBatches[0].Exit | Should -Be 3
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 2
    }

    It 'rejects exit 1 when a missing package has no matching not-found line' {
      $Null = $global:FakePackages.Remove($script:Firefox)
      $global:FakeExportSuppressMissingError = $True
      {
        & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw '*without an exact not-found error*'
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
    }

    It 'rejects an error line that cannot be accounted for by a missing package' {
      $Null = $global:FakePackages.Remove($script:Firefox)
      $global:FakeExportExtraError = @('Error: the export store is unavailable.')
      {
        & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw '*without an exact not-found error*'
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'fails on documented non-readable export status <Exit>' -TestCases @(
      @{ Exit = 2; Message = 'cancelled' }
      @{ Exit = 4; Message = 'skipped one or more requested packages' }
    ) {
      Param ($Exit, $Message)
      $global:FakeExportExit = $Exit
      {
        & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ('*{0}*' -f $Message)
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'rejects status 0 when the batch omits a requested package file' {
      $global:FakeExportOmissions = @($script:Firefox)
      {
        & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw '*reported success for 2 requested package(s) but wrote 1 export file(s)*'
    }
  }

  Context 'set reconciliation' {
    It 'imports only the differing definition and leaves the second converge unchanged' {
      $Definition = @(
        New-PackageText -Name:$script:Chrome -Detail:'new'
        New-PackageText -Name:$script:Firefox
      )
      $First = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:$Definition | Out-Null
      $First.Result.applied | Should -Be @($script:Chrome)
      $First.Result.unchanged | Should -Be @($script:Firefox)
      $First.Result.msg | Should -Match ([Regex]::Escape($script:Chrome))
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 1

      $ExportsAfterFirst = @($global:FakeCliCalls -like 'ExportPackages*').Count
      $Second = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:$Definition | Out-Null
      $Second.Changed | Should -BeFalse
      $Second.Result.applied.Count | Should -Be 0
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 1
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be ($ExportsAfterFirst + 1)
    }

    It 'ignores transport formatting, placement and custom-variable snapshots' {
      $Stored = (New-PackageText -Name:$script:Chrome).TrimStart([System.Char]0xFEFF).
        Replace("`r`n", "`n").Replace(
          '  </Package>',
          '<FolderId value="null" />' +
          '<Path>Packages\Browsers\Google Chrome - Install</Path>' +
          '<CustomVariables><CustomVariable><Value>147.0</Value></CustomVariable></CustomVariables>' +
          '  </Package>'
        )
      $global:FakePackages[$script:Chrome] = $Stored
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome
        New-PackageText -Name:$script:Firefox
      ) | Out-Null
      $Context.Changed | Should -BeFalse
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'removes an undeclared package and names it in the result' {
      $Stray = 'Undeclared By Hand'
      $global:FakePackages.Add($Stray, (New-PackageText -Name:$Stray))
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Result.removed | Should -Be @($Stray)
      $Context.Result.msg | Should -Match ([Regex]::Escape($Stray))
      $global:FakePackages.ContainsKey($Stray) | Should -BeFalse
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 1
    }

    It 'refuses to remove an undeclared package a declaration refers to' {
      {
        & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
          New-PackageText -Name:$script:Chrome -Dependency:$script:Firefox
        )
      } | Should -Throw '*a declared package refers to it*'
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
    }

    It 'treats an empty declaration as an instruction to remove every package' {
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@() | Out-Null
      $Context.Result.declared | Should -Be 0
      $Context.Result.removed | Should -Contain $script:Chrome
      $Context.Result.removed | Should -Contain $script:Firefox
      $global:FakePackages.Count | Should -Be 0
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 2
      @($global:FakeCliCalls -like 'GetPackageNames*').Count | Should -Be 2
    }

    It 'reports imports and removals in check mode without mutating the product' {
      $Stray = 'Undeclared By Hand'
      $global:FakePackages[$script:Chrome] = New-PackageText -Name:$script:Chrome -Detail:'old'
      $global:FakePackages.Add($Stray, (New-PackageText -Name:$Stray))
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome -Detail:'new'
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Changed | Should -BeTrue
      $Context.Result.applied | Should -Be @($script:Chrome)
      $Context.Result.removed | Should -Be @($Stray)
      $global:FakePackages.ContainsKey($Stray) | Should -BeTrue
      $global:FakePackages[$script:Chrome] | Should -Match '<Description>old</Description>'
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
    }
  }

  Context 'verification after mutation' {
    It 're-exports the set and fails while naming a definition the product ignored' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name:$script:Chrome -Detail:'old'
      $global:FakeIgnored = @($script:Chrome)
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome -Detail:'new'
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeTrue
      $Context.Result.ignored | Should -Be @($script:Chrome)
      $Context.Result.msg | Should -Match ([Regex]::Escape($script:Chrome))
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 2
    }

    It 're-lists the set and fails while naming an undeclared package that survived deletion' {
      $Stray = 'Undeclared By Hand'
      $global:FakePackages.Add($Stray, (New-PackageText -Name:$Stray))
      $global:FakeUndeletable = @($Stray)
      $Context = New-AnsibleContext
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeTrue
      $Context.Result.survivors | Should -Be @($Stray)
      $Context.Result.msg | Should -Match ([Regex]::Escape($Stray))
      @($global:FakeCliCalls -like 'GetPackageNames*').Count | Should -Be 2
    }

    It 'fails loudly when an import command fails' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name:$script:Chrome -Detail:'old'
      $global:FakeImportExit = 1
      {
        & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
          New-PackageText -Name:$script:Chrome -Detail:'new'
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw '*Importing the package*exited 1*'
    }

    It 'fails loudly when a delete command fails' {
      $Stray = 'Undeclared By Hand'
      $global:FakePackages.Add($Stray, (New-PackageText -Name:$Stray))
      $global:FakeDeleteExit = 4
      {
        & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw '*Removing the package*exited 4*'
    }

    It 'leaves no staged files or directories behind' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name:$script:Chrome -Detail:'old'
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -CliPath:$script:CliPath -Definition:@(
        New-PackageText -Name:$script:Chrome -Detail:'new'
        New-PackageText -Name:$script:Firefox
      ) | Out-Null
      Test-Path -LiteralPath:(Join-Path $script:Tmpdir 'pdq-package-export') | Should -BeFalse
      Test-Path -LiteralPath:(Join-Path $script:Tmpdir 'pdq-package-import.xml') | Should -BeFalse
    }
  }

  It 'carries the shared native-command helper unchanged from the remaining siblings' {
    $Extract = {
      Param ($File)
      $Text = Get-Content -LiteralPath:$File -Raw
      $Start = $Text.IndexOf('Function Invoke-NativeCommand')
      Return $Text.Substring(
        $Start,
        $Text.IndexOf([System.Environment]::NewLine + '}', $Start) - $Start
      )
    }
    $Mine = & $Extract $script:ScriptPath
    ForEach ($Sibling In @(
        'Set-PdqVariable.ps1', 'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1',
        'Set-PdqCollection.ps1')) {
      (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because:$Sibling
    }
  }
}
