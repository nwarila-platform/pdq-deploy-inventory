#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    Pester spec for Remove-PdqCollection.ps1 (org pair convention: every script ships with a
    sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script drives two external programs -- the product's
    command line at the path the CALLER passes, and the sqlite3.exe the script derives beside
    it -- so this file registers FUNCTIONS named with those exact path strings, under the
    spelling the script computes, because a function name matches as a string, not as a path.

    $global:FakeRows is the collection table: Id, Parent (empty string at the top level), Type,
    Name. The sqlite stub renders it for the SELECT, honours identity-bound DELETEs against it,
    and the listing stub renders the product's view of the same rows -- library rows under the
    synthetic Collection Library root, a synthetic All Computers entry no row backs -- so a test
    states a product, not a sequence of calls.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Remove-PdqCollection.ps1'
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
  $script:DbPath = 'C:\PDQ Data\Database.db'

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

  Function global:New-CollectionText {
    Param ([System.String]$Name)
    $Lines = @(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<AdminArsenal.Export Code="PDQInventory" Name="PDQ Inventory" Version="20.1.8.0" MinimumVersion="4.0">'
      '  <Collection>'
      ('    <Name>{0}</Name>' -f [System.Security.SecurityElement]::Escape($Name))
      '  </Collection>'
      '</AdminArsenal.Export>'
    )
    Return ($Lines -join "`n")
  }

  Function global:Add-FakeRow {
    Param ([System.String]$Id, [System.String]$Parent, [System.String]$Type, [System.String]$Name)
    $global:FakeRows.Add([PSCustomObject]@{ Id = $Id; Parent = $Parent; Type = $Type; Name = $Name })
  }

  Function global:ConvertTo-FakeHex {
    Param ([System.String]$Text)
    Return (-join ([System.Text.Encoding]::UTF8.GetBytes($Text) | ForEach-Object { $_.ToString('X2') }))
  }
}

Describe 'Remove-PdqCollection' {
  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Attributes = [System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path $PSScriptRoot 'Remove-PdqCollection.ps1'), [ref]$Null, [ref]$Null
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
    Set-Content -LiteralPath ($script:CliPath -replace 'PDQInventory\.exe$', 'sqlite3.exe') -Value 'stub' -WhatIf:$False
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:DbPath) -Force | Out-Null
    Set-Content -LiteralPath $script:DbPath -Value 'db' -WhatIf:$False

    $script:BuiltIn = @('Servers', 'Workstations')
    $global:FakeRows = [System.Collections.Generic.List[System.Object]]::new()
    Add-FakeRow -Id '1' -Parent '' -Type 'DynamicCollection' -Name 'Servers'
    Add-FakeRow -Id '2' -Parent '' -Type 'DynamicCollection' -Name 'Workstations'
    Add-FakeRow -Id '100' -Parent '' -Type 'LibraryCollection' -Name 'Applications'
    Add-FakeRow -Id '101' -Parent '100' -Type 'LibraryCollection' -Name '010 Editor 32bit'
    $global:FakeUndeletable = @()
    $global:FakeRenamed = @()
    $global:FakeMoved = @()
    $global:FakeListingOmits = @()
    $global:FakeReferencedIds = @()
    $global:FakeNoDbLine = $False
    $global:FakeLibraryVanishes = $False
    $global:FakeSqlBatches = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeDbPath = $script:DbPath
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      Switch ($args[0]) {
        'SystemInfo' {
          'Console Version: 20.1.8.0'
          If (-not $global:FakeNoDbLine) { 'Database: ' + $global:FakeDbPath }
          $global:LASTEXITCODE = 0
        }
        'GetAllCollections' {
          # The product's view: a synthetic entry no table row backs, library rows under a
          # synthetic root, everything else by its bare name -- measured shape.
          'All Computers'
          ForEach ($Row In $global:FakeRows) {
            If ($global:FakeListingOmits -contains $Row.Name) { Continue }
            If ($Row.Type -ceq 'LibraryCollection') { 'Collection Library\' + $Row.Name }
            Else { $Row.Name }
          }
          $global:LASTEXITCODE = 0
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null

    $script:SqliteCallable = Join-Path -Path (Split-Path -Path $script:CliPath -Parent) -ChildPath 'sqlite3.exe'
    New-Item -Force -Path ('function:global:' + $script:SqliteCallable) -Value {
      If ($args.Count -ne 2) {
        Throw ('unexpected sqlite3 arguments: {0}' -f ($args -join ' '))
      }
      If ($args[1] -like '*SELECT CollectionId, IFNULL(ParentId*') {
        If ($args[1] -match 'PRAGMA') {
          Throw 'the table read must not carry a pragma: its echo is a malformed row to the parser'
        }
        ForEach ($Row In $global:FakeRows) {
          '{0}|{1}|{2}|{3}' -f $Row.Id, $Row.Parent, $Row.Type, (ConvertTo-FakeHex $Row.Name)
        }
        $global:LASTEXITCODE = 0
        Return
      }
      If ($args[1] -like '*FROM ScanProfileCollections*' -and $args[1] -notlike '*DELETE*') {
        # The reference READ only: the delete batch also names this table inside its own NOT IN
        # conditions and must fall through to the branch below.
        $global:FakeReferencedIds | ForEach-Object { $_ }
        $global:LASTEXITCODE = 0
        Return
      }
      $global:FakeSqlBatches.Add($args[1])
      '5000'
      ForEach ($Match In [System.Text.RegularExpressions.Regex]::Matches(
          $args[1], "DELETE FROM Collections WHERE CollectionId = ([0-9]+) AND hex\(Name\) = '([0-9A-F]*)' AND IFNULL\(ParentId, ''\) = '([0-9]*)' AND hex\(IFNULL\(Type, ''\)\) = '([0-9A-F]*)' AND CollectionId NOT IN \(SELECT CollectionId FROM ScanProfileCollections\) AND CollectionId NOT IN \(SELECT IFNULL\(CollectionSourceId, -1\) FROM AutoReports\);")) {
        $Target = @($global:FakeRows | Where-Object { $_.Id -eq $Match.Groups[1].Value })[0]
        If ($Null -eq $Target) { Continue }
        # The row as it is NOW: a renamed, moved or retyped row no longer matches the predicate,
        # and a referenced id is spared from inside the transaction -- the measured semantics.
        $Current = If ($global:FakeRenamed -contains $Target.Name) { $Target.Name + ' (renamed)' } Else { $Target.Name }
        $Parent = If ($global:FakeMoved -contains $Target.Name) { '999' } Else { $Target.Parent }
        If ((ConvertTo-FakeHex $Current) -ceq $Match.Groups[2].Value -and
          $Parent -ceq $Match.Groups[3].Value -and
          (ConvertTo-FakeHex $Target.Type) -ceq $Match.Groups[4].Value -and
          $global:FakeReferencedIds -notcontains $Target.Id -and
          $global:FakeUndeletable -notcontains $Target.Name) {
          $Null = $global:FakeRows.Remove($Target)
        }
      }
      If ($global:FakeLibraryVanishes) {
        ForEach ($Gone In @($global:FakeRows | Where-Object { $_.Type -ceq 'LibraryCollection' } | Select-Object -First 1)) {
          $Null = $global:FakeRows.Remove($Gone)
        }
      }
      $global:LASTEXITCODE = 0
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
    Remove-Variable -Name 'FakeRows', 'FakeUndeletable', 'FakeRenamed', 'FakeMoved', 'FakeListingOmits',
      'FakeReferencedIds', 'FakeNoDbLine', 'FakeLibraryVanishes', 'FakeSqlBatches', 'FakeDbPath' `
      -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Context 'ownership at the top level' {
    It 'removes an undeclared stranger together with its children, and nothing else' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      Add-FakeRow -Id '11' -Parent '10' -Type 'DynamicCollection' -Name 'Hand Made Child'
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.removed | Should -Be @('Hand Made')
      @($global:FakeRows | ForEach-Object Name) | Should -Not -Contain 'Hand Made'
      @($global:FakeRows | ForEach-Object Name) | Should -Not -Contain 'Hand Made Child'
      @($global:FakeRows | ForEach-Object Name) | Should -Contain 'Servers'
    }

    It 'keeps a declared collection and reports unchanged when nothing is undeclared' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Chrome Below Pinned Version'
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @((New-CollectionText -Name 'Chrome Below Pinned Version')) `
        -BuiltIn $script:BuiltIn -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      $global:FakeSqlBatches.Count | Should -Be 0
      $Context.Result.msg | Should -Match 'No undeclared collections'
    }

    It 'never touches a library collection, wherever it sits' {
      # The library announces itself on the row; it is neither declared nor built-in, and stays.
      $Context = New-AnsibleContext
      & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeFalse
      @($global:FakeRows | Where-Object { $_.Type -ceq 'LibraryCollection' }).Count | Should -Be 2
    }

    It 'refuses to prune a stranger holding a library collection beneath it' {
      # Deleting the tree would take a vendor row with it; the run stops with everything intact.
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      Add-FakeRow -Id '11' -Parent '10' -Type 'LibraryCollection' -Name 'Captured Library Row'
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*belongs to the Collection Library*'
      $global:FakeSqlBatches.Count | Should -Be 0
      $global:FakeRows.Count | Should -Be 6
    }

    It 'refuses to remove anything when a built-in collection is missing' {
      # Furniture that moved means the pinned list no longer describes the product; deleting the
      # stranger that replaced it would destroy the new furniture.
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'New Furniture'
      $Null = $global:FakeRows.Remove(@($global:FakeRows | Where-Object { $_.Name -eq 'Servers' })[0])
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*furniture no longer matches this list*'
      $global:FakeSqlBatches.Count | Should -Be 0
    }

    It 'refuses a name that is both declared and built-in' {
      { & $script:ScriptPath -Definition @((New-CollectionText -Name 'Servers')) `
          -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*one name cannot have two owners*'
    }

    It 'refuses a name declared twice' {
      { & $script:ScriptPath -Definition @((New-CollectionText -Name 'Twice'), (New-CollectionText -Name 'twice')) `
          -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*declared more than once*'
    }

    It 'refuses a table row wearing a synthetic listing name' {
      # 'All Computers' is an entry the listing invents; a real row under that name would
      # corroborate against it and prove nothing.
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'All Computers'
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*invents for itself*'
    }

    It 'fails when the library does not count the same after the run' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      $global:FakeLibraryVanishes = $True
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*nothing here may touch it*'
    }

    It 'refuses a definition that does not name a collection' {
      { & $script:ScriptPath -Definition @('<AdminArsenal.Export><Collection /></AdminArsenal.Export>') `
          -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*does not name a collection*'
    }
  }

  Context 'what it refuses to prune' {
    It 'refuses a stranger a scan profile or auto report refers to' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      $global:FakeReferencedIds = @('10')
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*scan profile or auto report refers to it*'
      @($global:FakeRows | ForEach-Object Name) | Should -Contain 'Hand Made'
    }

    It 'refuses to prune when the listing does not corroborate a table row' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      $global:FakeListingOmits = @('Hand Made')
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*readings disagree*'
      $global:FakeSqlBatches.Count | Should -Be 0
    }

    It 'refuses a top-level name carrying a backslash' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand\Made'
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*level separator*'
    }

    It 'refuses two top-level collections that differ only by case' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      Add-FakeRow -Id '11' -Parent '' -Type 'DynamicCollection' -Name 'HAND MADE'
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*differing only by case*'
    }

    It 'fails rather than deleting a row that was renamed between the read and the write' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      $global:FakeRenamed = @('Hand Made')
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*still holds the undeclared collection*'
    }

    It 'fails rather than deleting a row that MOVED between the read and the write' {
      # Under another parent it may be nested drift this script deliberately leaves standing;
      # the predicate binds the parent as read, so the moved row matches nothing.
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      $global:FakeMoved = @('Hand Made')
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*still holds the undeclared collection*'
      @($global:FakeRows | ForEach-Object Name) | Should -Contain 'Hand Made'
    }

    It 'reports a CHILD the database kept, not merely a surviving root' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      Add-FakeRow -Id '11' -Parent '10' -Type 'DynamicCollection' -Name 'Stubborn Child'
      $global:FakeUndeletable = @('Stubborn Child')
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*Stubborn Child*'
    }


    It 'fails when the database accepts a delete it did not perform' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      $global:FakeUndeletable = @('Hand Made')
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*still holds the undeclared collection*'
    }

    It 'fails when a declared or built-in collection is not there afterwards' {
      { & $script:ScriptPath -Definition @((New-CollectionText -Name 'Not There')) `
          -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*does not hold the declared or built-in collection*'
    }
  }

  Context 'the database write' {
    It 'binds every delete to the row''s id AND its hex name, children before parents' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      Add-FakeRow -Id '11' -Parent '10' -Type 'DynamicCollection' -Name 'Hand Made Child'
      New-AnsibleContext | Out-Null
      & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath | Out-Null
      $global:FakeSqlBatches.Count | Should -Be 1
      $global:FakeSqlBatches[0] | Should -Match '^PRAGMA busy_timeout = 5000; BEGIN IMMEDIATE; (DELETE FROM Collections WHERE CollectionId = [0-9]+ AND hex\(Name\) = ''[0-9A-F]*'' AND IFNULL\(ParentId, ''''\) = ''[0-9]*'' AND hex\(IFNULL\(Type, ''''\)\) = ''[0-9A-F]*'' AND CollectionId NOT IN \(SELECT CollectionId FROM ScanProfileCollections\) AND CollectionId NOT IN \(SELECT IFNULL\(CollectionSourceId, -1\) FROM AutoReports\); ){2}COMMIT;$'
      $global:FakeSqlBatches[0] | Should -Not -Match 'Hand Made'
      # The child's id appears before the parent's.
      $global:FakeSqlBatches[0].IndexOf('CollectionId = 11') | Should -BeLessThan $global:FakeSqlBatches[0].IndexOf('CollectionId = 10')
    }

    It 'refuses to run without the database tool beside the command line' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      Remove-Item -LiteralPath ($script:CliPath -replace 'PDQInventory\.exe$', 'sqlite3.exe') -Force
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*database tool is not at*'
    }

    It 'refuses a system information report with no database path' {
      $global:FakeNoDbLine = $True
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*did not report a database path*'
    }

    It 'does not touch the database in check mode, and reports what it would remove' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath | Out-Null
      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $Context.Result.removed | Should -Be @('Hand Made')
      $Context.Result.msg | Should -Match 'Would remove'
      $global:FakeSqlBatches.Count | Should -Be 0
      @($global:FakeRows | ForEach-Object Name) | Should -Contain 'Hand Made'
    }

    It 'fails check mode on a host where removal is impossible, rather than promising it' {
      Add-FakeRow -Id '10' -Parent '' -Type 'DynamicCollection' -Name 'Hand Made'
      Remove-Item -LiteralPath ($script:CliPath -replace 'PDQInventory\.exe$', 'sqlite3.exe') -Force
      New-AnsibleContext -CheckMode | Out-Null
      { & $script:ScriptPath -Definition @() -BuiltIn $script:BuiltIn -CliPath $script:CliPath } |
        Should -Throw '*database tool is not at*'
    }
  }

  Context 'the hazards it must not reintroduce' {
    It 'refuses a command line that is not there' {
      { & $script:ScriptPath -Definition @() -BuiltIn @() -CliPath 'C:\nope\PDQInventory.exe' } |
        Should -Throw '*command line is not at*'
    }

    It 'keeps all three halves of the native-command contract' {
      $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Remove-PdqCollection.ps1') -Raw
      $Source | Should -Match "ErrorActionPreference = 'Continue'"
      $Source | Should -Match '& \$FilePath @Argument 2>&1'
      $Source | Should -Match '\[System\.Management\.Automation\.ErrorRecord\]'
    }

    It 'carries the same native-command helper as its siblings' {
      $Extract = {
        Param ($File)
        $Text = Get-Content -LiteralPath $File -Raw
        $Start = $Text.IndexOf('Function Invoke-NativeCommand')
        $Text.Substring($Start, $Text.IndexOf("`n}", $Start) - $Start)
      }
      $Mine = & $Extract (Join-Path $PSScriptRoot 'Remove-PdqCollection.ps1')
      ForEach ($Sibling In @('Set-PdqPackage.ps1', 'Remove-PdqPackage.ps1', 'Set-PdqVariable.ps1',
          'Set-PdqSetting.ps1', 'Set-PdqRegistration.ps1', 'Remove-PdqVariable.ps1',
          'Set-PdqCollection.ps1', 'Remove-PdqCollection.ps1')) {
        (& $Extract (Join-Path $PSScriptRoot $Sibling)) | Should -BeExactly $Mine -Because $Sibling
      }
    }
  }
}
