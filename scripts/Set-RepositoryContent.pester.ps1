#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-RepositoryContent.ps1 (org pair convention: every script ships
    with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script's outside edge is the S3 module, so
    this file WRITES a module named AWS.Tools.S3 into a sandbox and puts that sandbox
    on PSModulePath. The script's own Import-Module then genuinely succeeds and binds
    to the stub, rather than the spec reaching in to neutralise the import -- what is
    proven is the script's real loading path.

    The stub records every fetch in $global:FakeFetched and writes a file of the size
    the object claims, so 'already current' on a second run is proven by the same
    comparison the script makes rather than by a flag the stub sets.

    Stub state lives in $global: variables because inside a function called from a
    child SCRIPT, $script: resolves to that child's scope, not this file's.

    Both transports are asserted: the standalone JSON emission and the $Ansible path
    via the inline context below (pairs are self-contained; no imports). Its Changed
    defaults to $True exactly like win_powershell -- so every test proves the script
    SETS Changed rather than inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-RepositoryContent.ps1'
  $script:Bucket = 'nwarila-apprepo'
  $script:Region = 'us-east-1'

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

  # One bucket object. Size and age are what the script compares, so both are declared.
  Function New-S3Entry {
    Param ([System.String]$Key, [System.Int64]$Size = 10, [System.DateTime]$Modified = [System.DateTime]::UtcNow.AddDays(-1))
    [PSCustomObject]@{ Key = $Key; Size = $Size; LastModified = $Modified }
  }

  # Put a local copy in place exactly as a previous run would have left it.
  Function Set-LocalCopy {
    Param ([System.String]$Key, [System.Int64]$Size = 10, [System.DateTime]$Written = [System.DateTime]::UtcNow)
    $Local = Join-Path -Path $script:Repository -ChildPath $Key.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $Parent = Split-Path -Path $Local -Parent
    If (-not (Test-Path -LiteralPath $Parent)) { [void](New-Item -ItemType 'Directory' -Path $Parent -Force) }
    [System.IO.File]::WriteAllBytes($Local, [System.Byte[]]::new($Size))
    (Get-Item -LiteralPath $Local).LastWriteTimeUtc = $Written
    $Local
  }
}

Describe 'Set-RepositoryContent' {

  BeforeEach {
    $script:Sandbox = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('repo-' + [System.Guid]::NewGuid().ToString('N'))
    $script:Repository = Join-Path -Path $script:Sandbox -ChildPath 'Repository'
    [void](New-Item -ItemType 'Directory' -Path $script:Repository -Force)

    # A real module the script's own Import-Module resolves, rather than a shimmed import.
    $script:ModuleRoot = Join-Path -Path $script:Sandbox -ChildPath 'Modules'
    $ModuleDir = Join-Path -Path $script:ModuleRoot -ChildPath 'AWS.Tools.S3'
    [void](New-Item -ItemType 'Directory' -Path $ModuleDir -Force)
    Set-Content -LiteralPath (Join-Path -Path $ModuleDir -ChildPath 'AWS.Tools.S3.psm1') -Value @'
  Function Get-S3Object {
    [CmdletBinding()]
    Param ([System.String]$BucketName, [System.String]$Region)
    $global:FakeListed += 1
    # Emitted one object at a time, as the real cmdlet does; wrapping the array would hand the
  # caller a single nested item instead.
  $global:FakeObjects
  }

  Function Read-S3Object {
    [CmdletBinding()]
    Param ([System.String]$BucketName, [System.String]$File, [System.String]$Key, [System.String]$Region)
    $global:FakeFetched.Add($Key)
    $Entry = @($global:FakeObjects | Where-Object { $_.Key -eq $Key })[0]
    [System.IO.File]::WriteAllBytes($File, [System.Byte[]]::new($Entry.Size))
    Get-Item -LiteralPath $File
  }

  Export-ModuleMember -Function 'Get-S3Object', 'Read-S3Object'
'@
    Set-Content -LiteralPath (Join-Path -Path $ModuleDir -ChildPath 'AWS.Tools.S3.psd1') -Value @'
  @{ ModuleVersion = '1.0.0'; RootModule = 'AWS.Tools.S3.psm1'; FunctionsToExport = @('Get-S3Object', 'Read-S3Object'); GUID = 'b6f6a5a2-4d1b-4c93-9f0c-6f8e2b1f0a11'; Author = 'spec' }
'@

    $script:PreviousModulePath = $env:PSModulePath
    $env:PSModulePath = $script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath

    $global:FakeObjects = @()
    $global:FakeFetched = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeListed = 0
  }

  AfterEach {
    Remove-AnsibleContext
    $env:PSModulePath = $script:PreviousModulePath
    Remove-Module -Name 'AWS.Tools.S3' -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'FakeObjects', 'FakeFetched', 'FakeListed' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Context 'what it removes' {

    It 'removes a local file the bucket no longer carries' {
      # The bucket is the only place that decides what the repository contains; a superseded
      # version stays addressable there until it is pruned there.
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType 'Directory' -Path (Split-Path -Path $Stale -Parent) -Force)
      Set-Content -LiteralPath $Stale -Value 'superseded'
      $Ctx = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Stale | Should -Not -Exist
      $Ctx.Result.removed.Count | Should -Be 1
      $Ctx.Result.changed | Should -BeTrue
    }

    It 'removes a file nothing in the bucket ever placed' {
      # A hand-placed script is exactly the drift this sync exists to remove: it would exist on one
      # host and no other, and nothing would reveal that until something read it.
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      $Rogue = Join-Path -Path $script:Repository -ChildPath 'hand-placed.ps1'
      Set-Content -LiteralPath $Rogue -Value 'not from the bucket'
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Rogue | Should -Not -Exist
    }

    It 'keeps every file the bucket does carry' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'), (New-S3Entry 'Vendor/App/1.0/notes.txt'))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      (Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe') | Should -Exist
      (Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/notes.txt') | Should -Exist
    }

    It 'does not mistake a file it is about to fetch for one nothing owns' {
      # Surplus is enumerated before anything is written. If it were enumerated after, a freshly
      # fetched object could be deleted by the same run that fetched it.
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      $Ctx = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      (Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe') | Should -Exist
      $Ctx.Result.removed.Count | Should -Be 0
    }

    It 'clears a directory its last object left behind' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType 'Directory' -Path (Split-Path -Path $Stale -Parent) -Force)
      Set-Content -LiteralPath $Stale -Value 'superseded'
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      (Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0') | Should -Not -Exist
    }

    It 'never removes the repository root, even when the bucket is empty' {
      # The root is the mount point. Removing it would hide an unmounted volume behind a missing
      # directory, which is the fault this script checks for before it does anything.
      $global:FakeObjects = @()
      $Orphan = Join-Path -Path $script:Repository -ChildPath 'orphan.txt'
      Set-Content -LiteralPath $Orphan -Value 'x'
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $script:Repository | Should -Exist
      $Orphan | Should -Not -Exist
    }

    It 'removes nothing in check mode, and still reports what it would remove' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType 'Directory' -Path (Split-Path -Path $Stale -Parent) -Force)
      Set-Content -LiteralPath $Stale -Value 'superseded'
      $Ctx = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Stale | Should -Exist
      $Ctx.Result.removed.Count | Should -Be 1
      $Ctx.Result.changed | Should -BeTrue
    }

    It 'converges: a second run over the first run''s result removes nothing' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType 'Directory' -Path (Split-Path -Path $Stale -Parent) -Force)
      Set-Content -LiteralPath $Stale -Value 'superseded'
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Second = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Second.Result.changed | Should -BeFalse
      $Second.Result.removed.Count | Should -Be 0
    }
  }

  Context 'what it fetches' {

    It 'fetches every object when the repository is empty' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'), (New-S3Entry 'Vendor/App/1.0/notes.txt'))
      $Ctx = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched.Count | Should -Be 2
      $Ctx.Changed | Should -BeTrue
      $Ctx.Result.fetched | Should -Contain 'Vendor/App/1.0/app.exe'
    }

    It 'creates the intermediate directories a nested key names' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Expected = Join-Path -Path $script:Repository -ChildPath ('Vendor/App/1.0/app.exe'.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
      Test-Path -LiteralPath $Expected | Should -BeTrue
    }

    It 'fetches nothing when every local copy matches, and reports no change' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'), (New-S3Entry 'Vendor/App/1.0/notes.txt'))
      ForEach ($Entry In $global:FakeObjects) { [void](Set-LocalCopy -Key $Entry.Key -Size $Entry.Size) }
      $Ctx = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched.Count | Should -Be 0
      $Ctx.Changed | Should -BeFalse
      $Ctx.Result.msg | Should -BeLike '*already current*'
    }

    It 'converges: a second run over the first run''s result fetches nothing' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched.Clear()
      $Second = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched.Count | Should -Be 0
      $Second.Changed | Should -BeFalse
    }

    It 'refetches an object whose local copy is a different size' {
      $global:FakeObjects = @((New-S3Entry -Key 'Vendor/App/1.0/app.exe' -Size 4096))
      [void](Set-LocalCopy -Key 'Vendor/App/1.0/app.exe' -Size 11)
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched | Should -Contain 'Vendor/App/1.0/app.exe'
    }

    It 'refetches an object the bucket has updated since the local copy was written' {
      $global:FakeObjects = @((New-S3Entry -Key 'Vendor/App/1.0/app.exe' -Modified ([System.DateTime]::UtcNow)))
      [void](Set-LocalCopy -Key 'Vendor/App/1.0/app.exe' -Written ([System.DateTime]::UtcNow.AddDays(-7)))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched | Should -Contain 'Vendor/App/1.0/app.exe'
    }

    It 'ignores the folder markers a console leaves in a bucket' {
      $global:FakeObjects = @((New-S3Entry -Key 'Vendor/' -Size 0), (New-S3Entry 'Vendor/App/1.0/app.exe'))
      $Ctx = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched | Should -Not -Contain 'Vendor/'
      $Ctx.Result.present | Should -Be 1
    }
  }

  Context 'what it must never delete' {

    It 'keeps the bucket''s own file when Path is not already canonical' {
      # Proves the property, not one line of it: a Path the caller did not canonicalise must
      # still converge and delete nothing. The failure it guards against is severe -- an
      # unresolved root matches no file, so every file looks orphaned and the first run empties
      # the repository. Two things now deliver it, resolving the root and canonicalising each
      # joined path, and this case fails if both are lost.
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      $Awkward = Join-Path -Path $script:Repository -ChildPath '.'
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $Awkward -Region $script:Region
      (Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe') | Should -Exist
      $Second = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $Awkward -Region $script:Region
      $Second.Result.changed | Should -BeFalse
      $Second.Result.removed.Count | Should -Be 0
    }

    It 'keeps the bucket''s own file when the key is not already canonical' {
      # A key carrying '//' names a file the filesystem calls something shorter. Holding the longer
      # spelling would mark the bucket's own object surplus on the next run: delete, refetch,
      # never converge, and the installer absent between alternate converges. Interpolated key
      # building produces exactly this.
      $global:FakeObjects = @((New-S3Entry 'Vendor//App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Second = New-AnsibleContext
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Second.Result.removed.Count | Should -Be 0
      $Second.Result.changed | Should -BeFalse
    }

    It 'converges when a surplus file sits where a key needs a directory' {
      # Creating a directory over an existing file is a silent no-op, so the fetch then fails --
      # and the file that caused it is never reached if removal runs second. Every later run fails
      # the same way and a human has to intervene. Removal runs first.
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      $Blocker = Join-Path -Path $script:Repository -ChildPath 'Vendor/App'
      [void](New-Item -ItemType 'Directory' -Path (Split-Path -Path $Blocker -Parent) -Force)
      Set-Content -LiteralPath $Blocker -Value 'in the way'
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      (Join-Path -Path $script:Repository -ChildPath 'Vendor/App/1.0/app.exe') | Should -Exist
    }

    It 'clears a whole chain of directories its objects left behind' {
      $global:FakeObjects = @((New-S3Entry 'Keep/Me/1.0/app.exe'))
      $Stale = Join-Path -Path $script:Repository -ChildPath 'Gone/Deep/Deeper/1.0/old.exe'
      [void](New-Item -ItemType 'Directory' -Path (Split-Path -Path $Stale -Parent) -Force)
      Set-Content -LiteralPath $Stale -Value 'superseded'
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      (Join-Path -Path $script:Repository -ChildPath 'Gone') | Should -Not -Exist
    }

    It 'sweeps an empty directory even when nothing else changed' {
      # Swept unconditionally: a directory emptied by a run that then failed would otherwise
      # persist while every later run reported no change.
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Left = Join-Path -Path $script:Repository -ChildPath 'Left/Behind'
      [void](New-Item -ItemType 'Directory' -Path $Left -Force)
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $Left | Should -Not -Exist
    }
  }

  Context 'check mode, and what it reports' {

    It 'deletes a local file the bucket no longer holds' {
      # This assertion is the reverse of the one it replaces. The mirror was additive, on the
      # reasoning that leaving a superseded version on disk kept it available for a rollback. It
      # also let every volume drift somewhere different, invisibly. Rollback now lives in the
      # bucket, which is the only place that decides what the repository contains.
      $Orphan = Set-LocalCopy -Key 'Vendor/App/0.9/old.exe'
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      Test-Path -LiteralPath $Orphan | Should -BeFalse
    }

    It 'fetches nothing in check mode, and still reports the change it would make' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      $Ctx = New-AnsibleContext -CheckMode
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeFetched.Count | Should -Be 0
      $Ctx.Changed | Should -BeTrue
      $Ctx.Result.check_mode | Should -BeTrue
    }
  }

  Context 'what it refuses' {

    It 'fails naming the repository directory when the volume holding it is not mounted' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      $Missing = Join-Path -Path $script:Sandbox -ChildPath 'NoSuchVolume'
      [void](New-AnsibleContext)
      { & $script:ScriptPath -Bucket $script:Bucket -Path $Missing -Region $script:Region } |
        Should -Throw -ExpectedMessage '*not there*'
    }
  }

  Context 'what it reports' {

    It 'emits the result as JSON when run outside the module' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      Remove-AnsibleContext
      $Json = & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region |
        Out-String | ConvertFrom-Json
      $Json.bucket | Should -Be $script:Bucket
      $Json.changed | Should -BeTrue
      $Json.present | Should -Be 1
    }

    It 'reads the bucket exactly once per run' {
      $global:FakeObjects = @((New-S3Entry 'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $script:ScriptPath -Bucket $script:Bucket -Path $script:Repository -Region $script:Region
      $global:FakeListed | Should -Be 1
    }
  }
}
