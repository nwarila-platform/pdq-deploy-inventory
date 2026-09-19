#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Set-PdqPackage.ps1. Path-shaped functions model PDQ Deploy's command line,
    PDQ Inventory's, and the shipped database tool, including directory-based batched exports,
    partial-success stderr, minimal imports, forced deletes, the console-local ids a definition
    cannot carry, and verification after mutation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path $PSScriptRoot 'Set-PdqPackage.ps1'
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
  $script:InventoryCliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
  $script:SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
  $script:DeployDatabase = 'C:\Data\Deploy.db'
  $script:InventoryDatabase = 'C:\Data\Inventory.db'

  # Both command lines are fixed for every call; only the declaration and what its scan steps run
  # vary from one example to the next.
  Function Invoke-Reconcile {
    Param (
      [System.String[]] $Definition,
      [System.Collections.IDictionary] $ScanProfile = @{}
    )
    & $script:ScriptPath -CliPath:$script:CliPath -Definition:$Definition `
      -InventoryCliPath:$script:InventoryCliPath -ScanProfile:$ScanProfile
  }

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
      [System.String] $Dependency = '',
      [System.String] $Collection = '',
      [System.String] $ScanProfileId = '',
      [System.String] $NestedTarget = '',
      [System.String] $NestedPath = '',
      [System.Int32] $NestedCount = 1,
      [System.String] $MinimumVersion = '15.0'
    )
    $Lines = [System.Collections.Generic.List[System.String]]::new()
    $Lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $Lines.Add(('<AdminArsenal.Export Code="PDQDeploy" Name="PDQ Deploy" ' +
        'Version="20.1.8.0" MinimumVersion="{0}">' -f `
        [System.Security.SecurityElement]::Escape($MinimumVersion)))
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
    If ($Collection.Length -gt 0 -or $ScanProfileId.Length -gt 0 -or
      $NestedTarget.Length -gt 0) {
      $Lines.Add('    <PackageDefinition name="Definition">')
      $Lines.Add('      <Steps type="list">')
      If ($NestedTarget.Length -gt 0) {
        $TargetPath = If ($PSBoundParameters.ContainsKey('NestedPath')) {
          $NestedPath
        } Else {
          $NestedTarget
        }
        For ($Nested = 0; $Nested -lt $NestedCount; $Nested++) {
          $Lines.Add('        <NestedPackageStep>')
          $Lines.Add('          <TargetPackageId value="null" />')
          $Lines.Add(('          <TargetPackageName>{0}</TargetPackageName>' -f `
                [System.Security.SecurityElement]::Escape($NestedTarget)))
          $Lines.Add(('          <TargetPackagePath>{0}</TargetPackagePath>' -f `
                [System.Security.SecurityElement]::Escape($TargetPath)))
          $Lines.Add('          <UseNestedPackageConditions value="false" />')
          $Lines.Add(('          <Title>Call: {0}</Title>' -f `
                [System.Security.SecurityElement]::Escape($NestedTarget)))
          $Lines.Add('          <TypeName>NestedPackage</TypeName>')
          $Lines.Add('        </NestedPackageStep>')
        }
      }
      If ($Collection.Length -gt 0) {
        $Lines.Add('        <InstallStep>')
        $Lines.Add(('          <Title>Install: {0}</Title>' -f `
              [System.Security.SecurityElement]::Escape($Name)))
        $Lines.Add('          <TypeName>Install</TypeName>')
        $Lines.Add('          <Conditions type="list">')
        $Lines.Add('            <PackageStepCondition>')
        $Lines.Add('              <ConditionMode>Include</ConditionMode>')
        $Lines.Add('              <InventoryCollectionId value="null" />')
        $Lines.Add(('              <InventoryCollectionName>{0}</InventoryCollectionName>' -f `
              [System.Security.SecurityElement]::Escape($Collection)))
        $Lines.Add('              <TypeName>Collection</TypeName>')
        $Lines.Add('            </PackageStepCondition>')
        $Lines.Add('          </Conditions>')
        $Lines.Add('        </InstallStep>')
      }
      If ($ScanProfileId.Length -gt 0) {
        $Lines.Add('        <PackageStep>')
        $Lines.Add(('          <InventoryScanProfileId value="{0}" />' -f $ScanProfileId))
        $Lines.Add('          <Title>Scan After Deployment</Title>')
        $Lines.Add('          <TypeName>ScanStep</TypeName>')
        $Lines.Add('        </PackageStep>')
      }
      $Lines.Add('      </Steps>')
      $Lines.Add('    </PackageDefinition>')
    }
    $Lines.Add('  </Package>')
    $Lines.Add('</AdminArsenal.Export>')
    Return ([System.String][System.Char]0xFEFF + ($Lines -join "`r`n") + "`r`n")
  }

  Function global:Get-FakeHex {
    Param ([System.String] $Text)
    Return -join ([System.Text.Encoding]::UTF8.GetBytes($Text) |
        ForEach-Object { $PSItem.ToString('X2') })
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
    ForEach ($Path In @($script:CliPath, $script:InventoryCliPath, $script:SqlitePath,
        $script:DeployDatabase, $script:InventoryDatabase)) {
      New-Item -ItemType:'Directory' -Path:(Split-Path -Parent $Path) -Force | Out-Null
      Set-Content -LiteralPath:$Path -Value:'stub' -WhatIf:$False
    }
    # The script composes this one from the command line's directory, so the stand-in has to
    # answer to the composed spelling rather than to the one written above.
    $script:SqliteCommand = Join-Path -Path:(Split-Path -Path:$script:CliPath -Parent) `
      -ChildPath:'sqlite3.exe'

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
    $global:FakeDropNestedReference = @()
    $global:FakeKeepOneNestedReference = @()
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeCliArgumentCalls = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeExportBatches = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeImportedNames = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeDeployDatabase = $script:DeployDatabase
    $global:FakeInventoryDatabase = $script:InventoryDatabase
    $global:FakeCollectionIds = @{ 'Servers' = '7'; 'Workstations' = '9' }
    $global:FakeScanProfileIds = @{ 'Standard' = '1'; 'Applications' = '5' }
    $global:FakeConditionRows = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeNextConditionRow = 1
    $global:FakeUnwritableCondition = @()
    $global:FakeSqliteCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    New-Item -Force -Path:('function:global:' + $script:CliPath) -Value {
      $Argument = [System.String[]]@($args)
      $global:FakeCliCalls.Add($Argument -join ' ')
      $global:FakeCliArgumentCalls.Add([PSCustomObject]@{ Argument = $Argument })
      Switch ($Argument[0]) {
        'SystemInfo' {
          If ($Argument.Count -ne 1) {
            Throw ('unexpected SystemInfo arguments: {0}' -f ($Argument -join ' '))
          }
          Write-Output ('Database : {0}' -f $global:FakeDeployDatabase)
          $global:LASTEXITCODE = 0
        }
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
              # The export is modelled as carrying whatever collection id the row now holds, which
              # is the worse of the two possible product behaviours: the declaration can only ever
              # carry null, so a converge has to agree with the resolved id either way.
              $Text = $global:FakePackages[$Name]
              ForEach ($Row In @($global:FakeConditionRows | Where-Object {
                    $PSItem.Package -ceq $Name -and $Null -ne $PSItem.Id
                  })) {
                $Text = $Text.Replace('<InventoryCollectionId value="null" />',
                  ('<InventoryCollectionId value="{0}" />' -f $Row.Id))
              }
              $ExportDocument = [System.Xml.XmlDocument]::new()
              $ExportDocument.PreserveWhitespace = $True
              $ExportDocument.LoadXml($Text.TrimStart([System.Char]0xFEFF))
              $Included = [System.Collections.Generic.HashSet[System.String]]::new(
                [System.StringComparer]::Ordinal
              )
              ForEach ($Target In $ExportDocument.SelectNodes(
                  '/AdminArsenal.Export/Package[1]//NestedPackageStep/TargetPackagePath')) {
                If ($global:FakePackages.ContainsKey($Target.InnerText) -and
                  $Included.Add($Target.InnerText)) {
                  $DependencyDocument = [System.Xml.XmlDocument]::new()
                  $DependencyDocument.LoadXml(
                    $global:FakePackages[$Target.InnerText].TrimStart([System.Char]0xFEFF)
                  )
                  $DependencyPackage = $DependencyDocument.SelectSingleNode(
                    '/AdminArsenal.Export/Package'
                  )
                  $Null = $ExportDocument.DocumentElement.AppendChild(
                    $ExportDocument.ImportNode($DependencyPackage, $True)
                  )
                }
              }
              $Text = $ExportDocument.OuterXml
              Set-Content -LiteralPath:(Join-Path $Staged $FileName) `
                -Value:$Text -NoNewline -WhatIf:$False
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
          $global:FakeImportedNames.Add($Name)
          If ($global:FakeImportExit -eq 0 -and $global:FakeIgnored -notcontains $Name) {
            $Nested = 0
            ForEach ($Node In @($Document.SelectNodes(
                  "//NestedPackageStep[TypeName='NestedPackage']"))) {
              $Target = $Node.SelectSingleNode('TargetPackagePath')
              If ($global:FakeDropNestedReference -contains $Name -or
                ($global:FakeKeepOneNestedReference -contains $Name -and $Nested -gt 0) -or
                $Null -eq $Target -or
                -not $global:FakePackages.ContainsKey($Target.InnerText)) {
                $Null = $Node.ParentNode.RemoveChild($Node)
              } Else {
                $Node.SelectSingleNode('TargetPackageId').SetAttribute('value', '900')
                $Node.SelectSingleNode('TargetPackageName').InnerText = $Target.InnerText
              }
              $Nested++
            }
            $Text = $Document.OuterXml
            $global:FakePackages[$Name] = $Text
            # Measured: the import keeps the condition's collection NAME and leaves its id null.
            ForEach ($Stale In @($global:FakeConditionRows | Where-Object {
                  $PSItem.Package -ceq $Name
                })) {
              $Null = $global:FakeConditionRows.Remove($Stale)
            }
            ForEach ($Node In $Document.SelectNodes(
                "//PackageStepCondition[TypeName='Collection']/InventoryCollectionName")) {
              If ($Node.InnerText.Length -gt 0) {
                $global:FakeConditionRows.Add([PSCustomObject]@{
                    Current = $True
                    Id      = $Null
                    Name    = $Node.InnerText
                    Package = $Name
                    Row     = [System.String]$global:FakeNextConditionRow
                  })
                $global:FakeNextConditionRow++
              }
            }
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

    New-Item -Force -Path:('function:global:' + $script:InventoryCliPath) -Value {
      $Argument = [System.String[]]@($args)
      $global:FakeCliCalls.Add($Argument -join ' ')
      If ($Argument.Count -ne 1 -or $Argument[0] -cne 'SystemInfo') {
        Throw ('unexpected PDQInventory arguments: {0}' -f ($Argument -join ' '))
      }
      Write-Output ('Database : {0}' -f $global:FakeInventoryDatabase)
      $global:LASTEXITCODE = 0
    } | Out-Null

    New-Item -Force -Path:('function:global:' + $script:SqliteCommand) -Value {
      $Database = [System.String]$args[0]
      $Sql = [System.String]$args[1]
      $global:FakeSqliteCalls.Add($Sql)
      If ($Sql -like 'SELECT CollectionId*') {
        If ($Database -cne $global:FakeInventoryDatabase) {
          Throw ('the collections were read from {0}' -f $Database)
        }
        ForEach ($Entry In $global:FakeCollectionIds.GetEnumerator()) {
          Write-Output ('{0}|{1}' -f $Entry.Value, (Get-FakeHex -Text:$Entry.Key))
        }
      } ElseIf ($Sql -like 'SELECT InventoryScanProfileId*') {
        If ($Database -cne $global:FakeDeployDatabase) {
          Throw ('the scan profiles were read from {0}' -f $Database)
        }
        ForEach ($Entry In $global:FakeScanProfileIds.GetEnumerator()) {
          Write-Output ('{0}|{1}' -f $Entry.Value, (Get-FakeHex -Text:$Entry.Key))
        }
      } ElseIf ($Sql -like 'SELECT c.rowid*') {
        If ($Database -cne $global:FakeDeployDatabase) {
          Throw ('the collection conditions were read from {0}' -f $Database)
        }
        ForEach ($Row In @($global:FakeConditionRows | Where-Object Current)) {
          Write-Output ('{0}|{1}|{2}|{3}' -f @(
              $Row.Row, $Row.Id, (Get-FakeHex -Text:$Row.Name),
              (Get-FakeHex -Text:$Row.Package)
            ))
        }
      } ElseIf ($Sql -like '*UPDATE PackageStepConditionCollection*') {
        $Pattern = ('SET InventoryCollectionId = (?<New>[0-9]+) ' +
          'WHERE rowid = (?<Row>[0-9]+) AND ' +
          "IFNULL\((?<IdExpression>CAST\(InventoryCollectionId AS TEXT\)|" +
          "InventoryCollectionId), ''\) = '(?<Old>[0-9]*)' " +
          "AND hex\(IFNULL\(InventoryCollectionName, ''\)\) = '(?<Name>[0-9A-F]*)'")
        ForEach ($Match In [Regex]::Matches($Sql, $Pattern)) {
          $Row = @($global:FakeConditionRows | Where-Object {
              $StoredIdMatches = If ($Match.Groups['IdExpression'].Value -ceq
                'CAST(InventoryCollectionId AS TEXT)') {
                If ($Null -eq $PSItem.Id) {
                  $Match.Groups['Old'].Value.Length -eq 0
                } Else {
                  ([System.String]$PSItem.Id) -ceq $Match.Groups['Old'].Value
                }
              } Else {
                $Null -eq $PSItem.Id -and $Match.Groups['Old'].Value.Length -eq 0
              }
              $PSItem.Row -ceq $Match.Groups['Row'].Value -and $StoredIdMatches -and
              (Get-FakeHex -Text:$PSItem.Name) -ceq $Match.Groups['Name'].Value
            } | Select-Object -First 1)
          If ($Row.Count -eq 1 -and $global:FakeUnwritableCondition -notcontains $Row[0].Name) {
            $Row[0].Id = [System.Int64]$Match.Groups['New'].Value
          }
        }
      } Else {
        Throw ('unexpected statement: {0}' -f $Sql)
      }
      $global:LASTEXITCODE = 0
    } | Out-Null
  }

  AfterEach {
    ForEach ($Path In @($script:CliPath, $script:InventoryCliPath, $script:SqliteCommand)) {
      Remove-Item -LiteralPath:('function:global:' + $Path) -Force `
        -ErrorAction:'SilentlyContinue'
    }
    If ($script:MountedDrive) {
      Remove-PSDrive -Name:$script:MountedDrive -Force -ErrorAction:'SilentlyContinue'
    }
    Remove-Item -LiteralPath:$script:Tmpdir -Recurse -Force -ErrorAction:'SilentlyContinue'
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-Variable -Name:'FakePackages', 'FakeIgnored', 'FakeUndeletable', 'FakeImportExit',
      'FakeDeleteExit', 'FakeListExit', 'FakeExportExit', 'FakeExportOmissions',
      'FakeExportExtraError', 'FakeExportSuppressMissingError', 'FakeDropNestedReference',
      'FakeKeepOneNestedReference', 'FakeCliCalls', 'FakeCliArgumentCalls',
      'FakeExportBatches', 'FakeImportedNames', 'FakeDeployDatabase',
      'FakeInventoryDatabase', 'FakeCollectionIds', 'FakeScanProfileIds', 'FakeConditionRows',
      'FakeNextConditionRow', 'FakeUnwritableCondition', 'FakeSqliteCalls' -Scope:'Global' `
      -Force -ErrorAction:'SilentlyContinue'
  }

  Context 'the declaration boundary' {
    It 'refuses a command line that is not there' {
      {
        & $script:ScriptPath -Definition:@() -CliPath:'C:\nope\PDQDeploy.exe' `
          -InventoryCliPath:$script:InventoryCliPath -ScanProfile:@{}
      } | Should -Throw '*command line is not at*'
    }

    It 'refuses invalid, nameless and duplicate definitions before reading the product' {
      {
        Invoke-Reconcile -Definition:@('not xml')
      } | Should -Throw '*not valid XML*'
      $Nameless = '<?xml version="1.0"?><AdminArsenal.Export><Package /></AdminArsenal.Export>'
      {
        Invoke-Reconcile -Definition:@($Nameless)
      } | Should -Throw '*does not name a package*'
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Chrome -Detail:'second'
        )
      } | Should -Throw '*declared more than once*'
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'refuses names the command line would read as selection syntax' {
      ForEach ($Bad In @('Chrome*', 'Chrome?', 'Chrome,Firefox')) {
        {
          Invoke-Reconcile -Definition:@(New-PackageText -Name:$Bad)
        } | Should -Throw '*selection syntax*'
      }
      $global:FakeCliCalls.Count | Should -Be 0
    }
  }

  Context 'nested package references' {
    It 'refuses an empty target path before reading the product' {
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox `
            -NestedPath:''
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ("*$($script:Chrome) carries the step 'Call: $($script:Firefox)' with " +
        'an empty TargetPackagePath*')
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'refuses a target no declaration names even when the product holds it' {
      $Target = 'Held But Undeclared'
      $global:FakePackages.Add($Target, (New-PackageText -Name:$Target))
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -NestedTarget:$Target
        )
      } | Should -Throw ("*$($script:Chrome) carries the step 'Call: $Target', which nests " +
        "'$Target', but no declaration names that target*")
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'refuses a reference cycle and names the cycle' {
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox
          New-PackageText -Name:$script:Firefox -NestedTarget:$script:Chrome
        )
      } | Should -Throw ("*$($script:Chrome) -> $($script:Firefox) -> $($script:Chrome)*")
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'imports a target before the package that nests it' {
      $global:FakePackages.Clear()
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:@(
        New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Failed | Should -BeFalse
      $global:FakeImportedNames | Should -Be @($script:Firefox, $script:Chrome)
      $Context.Result.applied | Should -Be @($script:Chrome, $script:Firefox)
    }

    It 'ignores a nested target id and name but compares its path' {
      $Declaration = New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox
      $global:FakePackages[$script:Chrome] = $Declaration.
        Replace('<TargetPackageId value="null" />', '<TargetPackageId value="83" />').
        Replace(
          ('<TargetPackageName>{0}</TargetPackageName>' -f $script:Firefox),
          '<TargetPackageName>Console-derived name</TargetPackageName>'
        )
      $First = New-AnsibleContext
      Invoke-Reconcile -Definition:@(
        $Declaration
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $First.Changed | Should -BeFalse
      $global:FakeImportedNames.Count | Should -Be 0

      $global:FakePackages[$script:Chrome] = $global:FakePackages[$script:Chrome].Replace(
        ('<TargetPackagePath>{0}</TargetPackagePath>' -f $script:Firefox),
        '<TargetPackagePath>Wrong stored path</TargetPackagePath>'
      )
      $Second = New-AnsibleContext
      Invoke-Reconcile -Definition:@(
        $Declaration
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Second.Changed | Should -BeTrue
      $global:FakeImportedNames | Should -Be @($script:Chrome)
    }

    It 'reads a multi-package export as the requested first package' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name:$script:Chrome `
        -NestedTarget:$script:Firefox
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:@(
        New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Changed | Should -BeFalse
      $global:FakeExportBatches.Count | Should -Be 1
      $global:FakeImportedNames.Count | Should -Be 0
    }

    It 'collects the package, step and target and fails when the product drops the reference' {
      $global:FakeDropNestedReference = @($script:Chrome)
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ("*$($script:Chrome) does not carry the step 'Call: " +
        "$($script:Firefox)' targeting '$($script:Firefox)' after the import*")
      $global:FakeImportedNames | Should -Be @($script:Chrome)
    }

    It 'fails naming a duplicated reference when the product retains only one' {
      $global:FakeKeepOneNestedReference = @($script:Chrome)
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox -NestedCount:2
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ("*$($script:Chrome) does not carry the step 'Call: " +
        "$($script:Firefox)' targeting '$($script:Firefox)' after the import*")
      $global:FakeImportedNames | Should -Be @($script:Chrome)
    }

    It 'leaves a fully converged nested package unchanged without importing it' {
      $Declaration = New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox
      $global:FakePackages[$script:Chrome] = $Declaration
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:@(
        $Declaration
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Changed | Should -BeFalse
      $Context.Result.unchanged | Should -Be @($script:Chrome, $script:Firefox)
      $global:FakeImportedNames.Count | Should -Be 0
    }

    It 'compares equal when only the export envelope MinimumVersion differs' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name:$script:Chrome `
        -MinimumVersion:'17.0'
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:@(
        New-PackageText -Name:$script:Chrome -MinimumVersion:'15.0'
        New-PackageText -Name:$script:Firefox
      ) | Out-Null

      $Context.Changed | Should -BeFalse
      $global:FakeImportedNames.Count | Should -Be 0
    }
  }

  Context 'the batched read contract' {
    It 'passes separate names once, uses a directory and trusts each file Name rather than its filename' {
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:@(
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
      Invoke-Reconcile -Definition:@(
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
      Invoke-Reconcile -Definition:@(
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
        Invoke-Reconcile -Definition:@(
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
        Invoke-Reconcile -Definition:@(
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
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ('*{0}*' -f $Message)
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'rejects status 0 when the batch omits a requested package file' {
      $global:FakeExportOmissions = @($script:Firefox)
      {
        Invoke-Reconcile -Definition:@(
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
      Invoke-Reconcile -Definition:$Definition | Out-Null
      $First.Result.applied | Should -Be @($script:Chrome)
      $First.Result.unchanged | Should -Be @($script:Firefox)
      $First.Result.msg | Should -Match ([Regex]::Escape($script:Chrome))
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 1

      $ExportsAfterFirst = @($global:FakeCliCalls -like 'ExportPackages*').Count
      $Second = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition | Out-Null
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
      Invoke-Reconcile -Definition:@(
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
      Invoke-Reconcile -Definition:@(
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
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -Dependency:$script:Firefox
        )
      } | Should -Throw '*a declared package refers to it*'
      @($global:FakeCliCalls -like 'ExportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
    }

    It 'treats an empty declaration as an instruction to remove every package' {
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:@() | Out-Null
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
      Invoke-Reconcile -Definition:@(
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
      Invoke-Reconcile -Definition:@(
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
      Invoke-Reconcile -Definition:@(
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
        Invoke-Reconcile -Definition:@(
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
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw '*Removing the package*exited 4*'
    }

    It 'leaves no staged files or directories behind' {
      $global:FakePackages[$script:Chrome] = New-PackageText -Name:$script:Chrome -Detail:'old'
      New-AnsibleContext | Out-Null
      Invoke-Reconcile -Definition:@(
        New-PackageText -Name:$script:Chrome -Detail:'new'
        New-PackageText -Name:$script:Firefox
      ) | Out-Null
      Test-Path -LiteralPath:(Join-Path $script:Tmpdir 'pdq-package-export') | Should -BeFalse
      Test-Path -LiteralPath:(Join-Path $script:Tmpdir 'pdq-package-import.xml') | Should -BeFalse
    }
  }

  Context 'the ids that belong to this console' {
    It 'points a collection condition at this console''s own collection' {
      $Definition = @(
        New-PackageText -Name:$script:Chrome -Collection:'Servers'
        New-PackageText -Name:$script:Firefox
      )
      $First = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition | Out-Null

      $First.Failed | Should -BeFalse
      $First.Result.applied | Should -Be @($script:Chrome)
      @($global:FakeConditionRows | ForEach-Object Id) | Should -Be @(7)
      @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*').Count |
        Should -Be 1

      # The resolved id lives only on this console, so the same declaration must still converge.
      $Second = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition | Out-Null
      $Second.Changed | Should -BeFalse
      @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*').Count |
        Should -Be 1
    }

    It 'repairs an integer-stored moved collection id and binds the write as text' {
      $Definition = @(
        New-PackageText -Name:$script:Chrome -Collection:'Servers'
        New-PackageText -Name:$script:Firefox
      )
      $global:FakePackages[$script:Chrome] = $Definition[0]
      $global:FakeConditionRows.Add([PSCustomObject]@{
          Current = $True; Id = 6; Name = 'Servers'; Package = $script:Chrome; Row = '1'
        })
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Changed | Should -BeTrue
      $Context.Result.applied.Count | Should -Be 0
      $Context.Result.repaired | Should -Be @($script:Chrome)
      $Context.Result.unchanged | Should -Be @($script:Chrome, $script:Firefox)
      $Context.Result.msg | Should -Be (
        "Repaired references: $($script:Chrome); already correct: 2"
      )
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
      @($global:FakeConditionRows | ForEach-Object Id) | Should -Be @(7)
      $Writes = @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*')
      $Writes.Count | Should -Be 1
      $Writes[0] | Should -Match ([Regex]::Escape(
          "IFNULL(CAST(InventoryCollectionId AS TEXT), '') = '6'"
        ))
    }

    It 'predicts a moved collection id repair in check mode without writing' {
      $Definition = @(
        New-PackageText -Name:$script:Chrome -Collection:'Servers'
        New-PackageText -Name:$script:Firefox
      )
      $global:FakePackages[$script:Chrome] = $Definition[0]
      $global:FakeConditionRows.Add([PSCustomObject]@{
          Current = $True; Id = 6; Name = 'Servers'; Package = $script:Chrome; Row = '1'
        })
      $Context = New-AnsibleContext -CheckMode
      Invoke-Reconcile -Definition:$Definition | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Changed | Should -BeTrue
      $Context.Result.applied.Count | Should -Be 0
      $Context.Result.repaired | Should -Be @($script:Chrome)
      $Context.Result.unchanged | Should -Be @($script:Chrome, $script:Firefox)
      $Context.Result.msg | Should -Be (
        "Would apply: ; would remove: ; would repair references: $($script:Chrome); " +
        'already correct: 2'
      )
      @($global:FakeConditionRows | ForEach-Object Id) | Should -Be @(6)
      @($global:FakeSqliteCalls -like 'SELECT c.rowid*').Count | Should -Be 1
      @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*').Count |
        Should -Be 0
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
      @($global:FakeCliCalls -like 'DeletePackages*').Count | Should -Be 0
    }

    It 'writes nothing and reports no change on the converge after an id repair' {
      $Definition = @(
        New-PackageText -Name:$script:Chrome -Collection:'Servers'
        New-PackageText -Name:$script:Firefox
      )
      $global:FakePackages[$script:Chrome] = $Definition[0]
      $global:FakeConditionRows.Add([PSCustomObject]@{
          Current = $True; Id = 6; Name = 'Servers'; Package = $script:Chrome; Row = '1'
        })
      New-AnsibleContext | Out-Null
      Invoke-Reconcile -Definition:$Definition | Out-Null
      $Writes = @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*').Count

      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Changed | Should -BeFalse
      @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*').Count |
        Should -Be $Writes
    }

    It 'ignores a superseded collection id held by an older package version' {
      $Definition = @(
        New-PackageText -Name:$script:Chrome -Collection:'Servers'
        New-PackageText -Name:$script:Firefox
      )
      $global:FakePackages[$script:Chrome] = $Definition[0]
      $global:FakeConditionRows.Add([PSCustomObject]@{
          Current = $True; Id = 7; Name = 'Servers'; Package = $script:Chrome; Row = '1'
        })
      $global:FakeConditionRows.Add([PSCustomObject]@{
          Current = $False; Id = 6; Name = 'Servers'; Package = $script:Chrome; Row = '2'
        })
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Changed | Should -BeFalse
      @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*').Count |
        Should -Be 0
      @($global:FakeConditionRows | Where-Object { -not $PSItem.Current } |
          ForEach-Object Id) | Should -Be @(6)
    }

    It 'stops the run naming the package, the step and the collection it cannot find' {
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -Collection:'No Such Collection'
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ("*$($script:Chrome) gates the step 'Install: $($script:Chrome)' on the " +
        "collection 'No Such Collection', which PDQ Inventory does not hold*")
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'rewrites a scan step to this console''s own scan profile' {
      $Definition = @(
        New-PackageText -Name:$script:Chrome -ScanProfileId:'2'
        New-PackageText -Name:$script:Firefox
      )
      $Runs = @{ $script:Chrome = 'Applications' }
      $First = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition -ScanProfile:$Runs | Out-Null

      $First.Failed | Should -BeFalse
      $First.Result.applied | Should -Be @($script:Chrome)
      $global:FakePackages[$script:Chrome] | Should -Match '<InventoryScanProfileId value="5" />'
      $global:FakePackages[$script:Chrome] | Should -Not -Match 'value="2"'

      $Second = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition -ScanProfile:$Runs | Out-Null
      $Second.Changed | Should -BeFalse
    }

    It 'checks a nester scan step without reading its dependency scan step' {
      $global:FakePackages.Clear()
      $Definition = @(
        New-PackageText -Name:$script:Chrome -NestedTarget:$script:Firefox `
          -ScanProfileId:'2'
        New-PackageText -Name:$script:Firefox -ScanProfileId:'2'
      )
      $Runs = @{
        $script:Chrome = 'Applications'
        $script:Firefox = 'Standard'
      }
      $Context = New-AnsibleContext
      Invoke-Reconcile -Definition:$Definition -ScanProfile:$Runs | Out-Null

      $Context.Failed | Should -BeFalse
      $Context.Result.applied | Should -Be @($script:Chrome, $script:Firefox)
      $global:FakeImportedNames | Should -Be @($script:Firefox, $script:Chrome)
      $global:FakePackages[$script:Chrome] | Should -Match `
        '<InventoryScanProfileId value="5" />'
      $global:FakePackages[$script:Firefox] | Should -Match `
        '<InventoryScanProfileId value="1" />'
    }

    It 'stops the run naming the package, the step and the scan profile it cannot find' {
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -ScanProfileId:'2'
          New-PackageText -Name:$script:Firefox
        ) -ScanProfile:@{ $script:Chrome = 'No Such Profile' }
      } | Should -Throw ("*$($script:Chrome) runs the scan profile 'No Such Profile' at the step " +
        "'Scan After Deployment', which PDQ Deploy does not hold*")
      @($global:FakeCliCalls -like 'ImportPackages*').Count | Should -Be 0
    }

    It 'refuses a scan step that no declaration names a profile for' {
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -ScanProfileId:'2'
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ("*$($script:Chrome) carries the step 'Scan After Deployment', which runs " +
        'a scan profile no declaration names*')
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'refuses a declared scan profile that names no definition' {
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome
          New-PackageText -Name:$script:Firefox
        ) -ScanProfile:@{ 'Never Declared' = 'Applications' }
      } | Should -Throw '*A scan profile is declared for Never Declared, which no definition names*'
      $global:FakeCliCalls.Count | Should -Be 0
    }

    It 'fails after the write when a condition still does not carry the collection' {
      $global:FakeUnwritableCondition = @('Servers')
      {
        Invoke-Reconcile -Definition:@(
          New-PackageText -Name:$script:Chrome -Collection:'Servers'
          New-PackageText -Name:$script:Firefox
        )
      } | Should -Throw ("*$($script:Chrome) does not gate the step 'Install: $($script:Chrome)' " +
        "on the collection 'Servers' after the import*")
      @($global:FakeSqliteCalls -like '*UPDATE PackageStepConditionCollection*').Count |
        Should -Be 1
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
