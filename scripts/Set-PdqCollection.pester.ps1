#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Set-PdqCollection.ps1. Path-shaped functions model the product CLI and its
    shipped database tool, including batched exports, minimal imports, the established prune
    transaction, built-in and library protection, and verification after mutation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path $PSScriptRoot 'Set-PdqCollection.ps1'
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
  $script:SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe'
  $script:DatabasePath = 'C:\Data\Inventory.db'
  $global:FakeDatabasePath = $script:DatabasePath

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

  Function global:New-CollectionText {
    Param (
      [System.String] $Name,
      [System.String] $Detail = 'current'
    )
    $Lines = @(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<AdminArsenal.Export Code="PDQInventory" Name="PDQ Inventory">'
      '<Collection>'
      ('<Name>{0}</Name>' -f [System.Security.SecurityElement]::Escape($Name))
      ('<Description>{0}</Description>' -f [System.Security.SecurityElement]::Escape($Detail))
      '</Collection>'
      '</AdminArsenal.Export>'
    )
    Return $Lines -join [System.Environment]::NewLine
  }

  Function global:Get-FakeHex {
    Param ([System.String] $Text)
    Return -join ([System.Text.Encoding]::UTF8.GetBytes($Text) |
        ForEach-Object { $PSItem.ToString('X2') })
  }

  Function global:Add-FakeCollectionRow {
    Param (
      [System.String] $Name,
      [System.String] $Type = 'DynamicCollection',
      [System.String] $Parent = '',
      [System.String] $ADDistinguishedName = ''
    )
    $Existing = @($global:FakeRows | Where-Object {
        $PSItem.Name -ceq $Name -and $PSItem.Parent -ceq $Parent
      } | Select-Object -First 1)
    If ($Existing.Count -eq 0) {
      $global:FakeRows.Add([PSCustomObject]@{
          Id                    = [System.String]$global:FakeNextId
          Parent                = $Parent
          Type                  = $Type
          Name                  = $Name
          ADDistinguishedName   = $ADDistinguishedName
        })
      $global:FakeNextId++
    }
  }
}

Describe 'Set-PdqCollection' {
  It 'declares plural collection and built-in parameters' {
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:ScriptPath, [ref]$Null, [ref]$Null
    )
    $Definition = $Ast.ParamBlock.Parameters |
      Where-Object { $PSItem.Name.VariablePath.UserPath -eq 'Definition' }
    $BuiltIn = $Ast.ParamBlock.Parameters |
      Where-Object { $PSItem.Name.VariablePath.UserPath -eq 'BuiltIn' }
    $Definition.StaticType | Should -Be ([System.String[]])
    $BuiltIn.StaticType | Should -Be ([System.String[]])
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
    ForEach ($Path In @($script:CliPath, $script:SqlitePath, $script:DatabasePath)) {
      New-Item -ItemType:'Directory' -Path:(Split-Path -Parent $Path) -Force | Out-Null
      Set-Content -LiteralPath:$Path -Value:'stub' -WhatIf:$False
    }
    $script:SqliteCommand = Join-Path -Path:(Split-Path -Path:$script:CliPath -Parent) `
      -ChildPath:'sqlite3.exe'

    $script:Chrome = 'Chrome Below Pinned Version'
    $script:Firefox = 'Firefox Below Pinned Version'
    $script:BuiltIn = @('Servers', 'Workstations')
    $global:FakeCollections = @{
      $script:Chrome  = New-CollectionText -Name:$script:Chrome
      $script:Firefox = New-CollectionText -Name:$script:Firefox
    }
    $global:FakeRows = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeNextId = 1
    Add-FakeCollectionRow -Name:'Servers'
    Add-FakeCollectionRow -Name:'Workstations'
    Add-FakeCollectionRow -Name:'Applications' -Type:'LibraryCollection'
    Add-FakeCollectionRow -Name:$script:Chrome
    Add-FakeCollectionRow -Name:$script:Firefox
    $global:FakeIgnored = @()
    $global:FakeUndeletable = @()
    $global:FakeReferenced = @()
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeCliArgumentCalls = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeExportBatches = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeExportExitCode = 0
    $global:FakeExportOmissions = @()
    $global:FakeSqliteCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    New-Item -Force -Path:('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      $Argument = [System.String[]]@($args)
      $global:FakeCliArgumentCalls.Add([PSCustomObject]@{ Argument = $Argument })
      Switch ($args[0]) {
        'ExportCollections' {
          $NameIndex = [System.Array]::IndexOf($Argument, '-Name')
          $PathIndex = [System.Array]::IndexOf($Argument, '-Path')
          $Names = [System.String[]]@($Argument[($NameIndex + 1)..($PathIndex - 1)])
          $Staged = $Argument[$PathIndex + 1]
          $WasDirectory = Test-Path -LiteralPath:$Staged -PathType:'Container'
          If ($global:FakeExportExitCode -ne 0) {
            $global:FakeExportBatches.Add([PSCustomObject]@{
                Exit         = $global:FakeExportExitCode
                FileCount    = 0
                Files        = [System.String[]]@()
                Names        = $Names
                Path         = $Staged
                WasDirectory = $WasDirectory
              })
            $global:LASTEXITCODE = $global:FakeExportExitCode
            Return
          }
          If (-not $WasDirectory) {
            Throw 'ExportCollections requires a directory for multiple names'
          }
          $Held = @($Names | Where-Object { $global:FakeCollections.ContainsKey($PSItem) })
          If ($Held.Count -eq 0) {
            $global:FakeExportBatches.Add([PSCustomObject]@{
                Exit         = 3
                FileCount    = 0
                Files        = [System.String[]]@()
                Names        = $Names
                Path         = $Staged
                WasDirectory = $WasDirectory
              })
            $global:LASTEXITCODE = 3
            Return
          }
          $Written = @($Held | Where-Object { $global:FakeExportOmissions -notcontains $PSItem })
          ForEach ($Name In $Written) {
            Set-Content -LiteralPath:(Join-Path $Staged ($Name + '.xml')) `
              -Value:$global:FakeCollections[$Name] -NoNewline -WhatIf:$False
          }
          $global:FakeExportBatches.Add([PSCustomObject]@{
              Exit         = 0
              FileCount    = $Written.Count
              Files        = [System.String[]]@($Written | ForEach-Object { $PSItem + '.xml' })
              Names        = $Names
              Path         = $Staged
              WasDirectory = $WasDirectory
            })
          $global:LASTEXITCODE = 0
        }
        'ImportCollections' {
          $Text = Get-Content -LiteralPath:$args[2] -Raw
          $Document = [System.Xml.XmlDocument]::new()
          $Document.LoadXml($Text)
          $Name = $Document.SelectSingleNode('/AdminArsenal.Export/Collection/Name').InnerText
          If ($global:FakeIgnored -notcontains $Name) {
            $global:FakeCollections[$Name] = $Text
            Add-FakeCollectionRow -Name:$Name
          }
          $global:LASTEXITCODE = 0
        }
        'SystemInfo' {
          Write-Output ('Database : {0}' -f $global:FakeDatabasePath)
          $global:LASTEXITCODE = 0
        }
        'GetAllCollections' {
          Write-Output 'All Computers'
          ForEach ($Row In @($global:FakeRows | Where-Object {
                $PSItem.Parent -eq '' -and $PSItem.Type -cne 'LibraryCollection'
              })) {
            Write-Output $Row.Name
          }
          Write-Output 'Collection Library\Applications'
          $global:LASTEXITCODE = 0
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null

    New-Item -Force -Path:('function:global:' + $script:SqliteCommand) -Value {
      $Sql = [System.String]$args[1]
      $global:FakeSqliteCalls.Add($Sql)
      If ($Sql -like 'SELECT CollectionId*') {
        ForEach ($Row In $global:FakeRows) {
          Write-Output ('{0}|{1}|{2}|{3}|{4}' -f @(
              $Row.Id, $Row.Parent, $Row.Type, (Get-FakeHex -Text:$Row.Name),
              (Get-FakeHex -Text:$Row.ADDistinguishedName)
            ))
        }
      } ElseIf ($Sql -like 'SELECT IFNULL(CollectionId*') {
        $global:FakeReferenced | ForEach-Object { Write-Output $PSItem }
      } ElseIf ($Sql -like '*DELETE FROM Collections*') {
        ForEach ($Match In [Regex]::Matches(
            $Sql, "CollectionId = ([0-9]+) AND hex\(Name\) = '([0-9A-F]+)'")) {
          $Id = $Match.Groups[1].Value
          $Hex = $Match.Groups[2].Value
          $Row = @($global:FakeRows | Where-Object {
              $PSItem.Id -eq $Id -and (Get-FakeHex -Text:$PSItem.Name) -ceq $Hex
            } | Select-Object -First 1)
          If ($Row.Count -eq 1 -and $global:FakeUndeletable -notcontains $Row[0].Name) {
            $global:FakeRows.Remove($Row[0])
            $global:FakeCollections.Remove($Row[0].Name)
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
    Remove-Item -LiteralPath:$script:Tmpdir -Recurse -Force -ErrorAction:'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name:'FakeCollections', 'FakeRows', 'FakeNextId', 'FakeIgnored',
      'FakeUndeletable', 'FakeReferenced', 'FakeCliCalls', 'FakeCliArgumentCalls',
      'FakeExportBatches', 'FakeExportExitCode', 'FakeExportOmissions', 'FakeSqliteCalls',
      'FakeDatabasePath' -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
  }

  It 'reads multiple names as separate arguments from one file per collection in a directory' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null
    $Context.Changed | Should -BeFalse
    $Exports = @($global:FakeCliArgumentCalls | Where-Object {
        $PSItem.Argument[0] -ceq 'ExportCollections'
      })
    $Exports.Count | Should -Be 1
    $Exports[0].Argument | Should -Be @(
      'ExportCollections'
      '-Name'
      $script:Chrome
      $script:Firefox
      '-Path'
      $global:FakeExportBatches[0].Path
      '-Overwrite'
    )
    $global:FakeExportBatches[0].WasDirectory | Should -BeTrue
    $global:FakeExportBatches[0].FileCount | Should -Be 2
    $global:FakeExportBatches[0].Files | Should -Be @(
      $script:Chrome + '.xml'
      $script:Firefox + '.xml'
    )
    $global:FakeExportBatches[0].Names | Should -Be @($script:Chrome, $script:Firefox)
    Test-Path -LiteralPath:$global:FakeExportBatches[0].Path | Should -BeFalse
  }

  It 'accepts exit 3 when a fresh product holds none of the declared collections' {
    $global:FakeCollections.Clear()
    ForEach ($Row In @($global:FakeRows | Where-Object {
          $PSItem.Name -ceq $script:Chrome -or $PSItem.Name -ceq $script:Firefox
        })) {
      $global:FakeRows.Remove($Row)
    }

    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null

    $Context.Failed | Should -BeFalse
    $Context.Result.applied | Should -Be @($script:Chrome, $script:Firefox)
    $global:FakeExportBatches[0].Exit | Should -Be 3
    $global:FakeExportBatches[0].FileCount | Should -Be 0
    @($global:FakeCliCalls -like 'ExportCollections*').Count | Should -Be 2
  }

  It 'fails when ExportCollections returns documented status <Exit>' -TestCases @(
    @{ Exit = 1; Message = 'one or more requested collections failed to export' }
    @{ Exit = 2; Message = 'ExportCollections was cancelled' }
    @{ Exit = 4; Message = 'skipped one or more requested collections because an export file already existed' }
  ) {
    Param ($Exit, $Message)
    $global:FakeExportExitCode = $Exit
    $Stray = 'Undeclared By Hand'
    $global:FakeCollections[$Stray] = New-CollectionText -Name:$Stray
    Add-FakeCollectionRow -Name:$Stray

    {
      & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
        New-CollectionText -Name:$script:Chrome
        New-CollectionText -Name:$script:Firefox
      )
    } | Should -Throw ('*{0}*' -f $Message)
    @($global:FakeCliCalls -like 'ImportCollections*').Count | Should -Be 0
    @($global:FakeSqliteCalls -like '*DELETE FROM Collections*').Count | Should -Be 0
  }

  It 'rejects status 0 when the batch does not write one file per requested collection' {
    $global:FakeExportOmissions = @($script:Firefox)

    {
      & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
        New-CollectionText -Name:$script:Chrome
        New-CollectionText -Name:$script:Firefox
      )
    } | Should -Throw '*reported success for 2 requested collection(s) but wrote 1 export file(s)*'
  }

  It 'imports only the definition that differs and leaves the second converge unchanged' {
    $Definition = @(
      New-CollectionText -Name:$script:Chrome -Detail:'new'
      New-CollectionText -Name:$script:Firefox
    )
    $First = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn `
      -Definition:$Definition | Out-Null
    $First.Result.applied | Should -Be @($script:Chrome)
    $First.Result.unchanged | Should -Be @($script:Firefox)
    @($global:FakeCliCalls -like 'ImportCollections*').Count | Should -Be 1

    $ExportsAfterFirst = @($global:FakeCliCalls -like 'ExportCollections*').Count
    $Second = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn `
      -Definition:$Definition | Out-Null
    $Second.Changed | Should -BeFalse
    $Second.Result.applied.Count | Should -Be 0
    @($global:FakeCliCalls -like 'ExportCollections*').Count | Should -Be ($ExportsAfterFirst + 1)
  }

  It 'removes an undeclared top-level collection and names it in the result' {
    $Stray = 'Undeclared By Hand'
    $global:FakeCollections[$Stray] = New-CollectionText -Name:$Stray
    Add-FakeCollectionRow -Name:$Stray
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null
    $Context.Result.removed | Should -Be @($Stray)
    $global:FakeCollections.Keys | Should -Not -Contain $Stray
  }

  It 'preserves every declared built-in and every Collection Library row' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null
    @($global:FakeRows | ForEach-Object Name) | Should -Contain 'Servers'
    @($global:FakeRows | ForEach-Object Name) | Should -Contain 'Workstations'
    @($global:FakeRows | Where-Object { $PSItem.Type -ceq 'LibraryCollection' }).Count |
      Should -Be 1
    $Context.Result.library | Should -Be 1
  }

  It 'leaves Active Directory collections alone while declared and stray rows reconcile' {
    $DirectoryTyped = 'Directory Typed'
    $DirectoryMarked = 'Directory Marked'
    $Stray = 'Undeclared By Hand'
    Add-FakeCollectionRow -Name:$DirectoryTyped -Type:'ActiveDirectoryCollection'
    Add-FakeCollectionRow -Name:$DirectoryMarked `
      -ADDistinguishedName:'OU=Managed,DC=example,DC=test'
    Add-FakeCollectionRow -Name:$Stray
    $global:FakeCollections[$Stray] = New-CollectionText -Name:$Stray

    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome -Detail:'new'
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null

    $Context.Failed | Should -BeFalse
    $Context.Result.applied | Should -Be @($script:Chrome)
    $Context.Result.unchanged | Should -Be @($script:Firefox)
    $Context.Result.removed | Should -Be @($Stray)
    @($global:FakeRows | ForEach-Object Name) | Should -Contain $DirectoryTyped
    @($global:FakeRows | ForEach-Object Name) | Should -Contain $DirectoryMarked
  }

  It 'refuses an Active Directory row inside a doomed subtree before mutation' {
    $Stray = 'Undeclared By Hand'
    $DirectoryChild = 'Directory Child'
    Add-FakeCollectionRow -Name:$Stray
    $RootId = @($global:FakeRows | Where-Object { $PSItem.Name -ceq $Stray })[0].Id
    Add-FakeCollectionRow -Name:$DirectoryChild -Type:'ActiveDirectoryCollection' -Parent:$RootId
    $global:FakeCollections[$Stray] = New-CollectionText -Name:$Stray

    {
      & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
        New-CollectionText -Name:$script:Chrome
        New-CollectionText -Name:$script:Firefox
      )
    } | Should -Throw '*belongs to Active Directory sync*'

    @($global:FakeRows | ForEach-Object Name) | Should -Contain $Stray
    @($global:FakeRows | ForEach-Object Name) | Should -Contain $DirectoryChild
    @($global:FakeSqliteCalls -like '*DELETE FROM Collections*').Count | Should -Be 0
  }

  It 'refuses a declaration that claims an Active Directory collection before importing' {
    $DirectoryName = 'Directory Owned'
    Add-FakeCollectionRow -Name:$DirectoryName -Type:'ActiveDirectoryCollection'
    $global:FakeCollections[$DirectoryName] = New-CollectionText -Name:$DirectoryName

    {
      & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
        New-CollectionText -Name:$script:Chrome
        New-CollectionText -Name:$script:Firefox
        New-CollectionText -Name:$DirectoryName -Detail:'declared'
      )
    } | Should -Throw '*one name cannot have two owners*'

    @($global:FakeCliCalls -like 'ImportCollections*').Count | Should -Be 0
  }

  It 'treats an empty declaration as owning no custom collections' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@() |
      Out-Null
    $Context.Result.removed.Count | Should -Be 2
    @($global:FakeRows | Where-Object {
        $PSItem.Type -cne 'LibraryCollection' -and $script:BuiltIn -notcontains $PSItem.Name
      }).Count | Should -Be 0
    @($global:FakeCliCalls -like 'ExportCollections*').Count | Should -Be 0
  }

  It 're-exports the batch after writes and fails while naming a definition that did not settle' {
    $global:FakeIgnored = @($script:Chrome)
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome -Detail:'new'
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null
    $Context.Failed | Should -BeTrue
    $Context.Result.ignored | Should -Be @($script:Chrome)
    @($global:FakeCliCalls -like 'ExportCollections*').Count | Should -Be 2
  }

  It 'fails while naming an undeclared collection the delete did not remove' {
    $Stray = 'Undeclared By Hand'
    $global:FakeCollections[$Stray] = New-CollectionText -Name:$Stray
    Add-FakeCollectionRow -Name:$Stray
    $global:FakeUndeletable = @($Stray)
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null
    $Context.Failed | Should -BeTrue
    $Context.Result.survivors | Should -Be @($Stray)
  }

  It 'fails while naming a descendant left behind after its undeclared root was removed' {
    $Stray = 'Undeclared By Hand'
    $Child = 'Undeclared Child'
    Add-FakeCollectionRow -Name:$Stray
    $RootId = @($global:FakeRows | Where-Object { $PSItem.Name -ceq $Stray })[0].Id
    Add-FakeCollectionRow -Name:$Child -Parent:$RootId
    $global:FakeCollections[$Stray] = New-CollectionText -Name:$Stray
    $global:FakeUndeletable = @($Child)
    $Context = New-AnsibleContext
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null
    $Context.Failed | Should -BeTrue
    $Context.Result.survivors | Should -Be @($Child)
  }

  It 'reports imports and removals in check mode without mutating either store' {
    $Stray = 'Undeclared By Hand'
    $global:FakeCollections[$Stray] = New-CollectionText -Name:$Stray
    Add-FakeCollectionRow -Name:$Stray
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
      New-CollectionText -Name:$script:Chrome -Detail:'new'
      New-CollectionText -Name:$script:Firefox
    ) | Out-Null
    $Context.Result.applied | Should -Be @($script:Chrome)
    $Context.Result.removed | Should -Be @($Stray)
    $global:FakeCollections.Keys | Should -Contain $Stray
    @($global:FakeCliCalls -like 'ImportCollections*').Count | Should -Be 0
  }

  It 'refuses a definition that claims a built-in name before importing anything' {
    {
      & $script:ScriptPath -CliPath:$script:CliPath -BuiltIn:$script:BuiltIn -Definition:@(
        New-CollectionText -Name:'Servers'
      )
    } | Should -Throw '*one name cannot have two owners*'
    @($global:FakeCliCalls -like 'ImportCollections*').Count | Should -Be 0
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
