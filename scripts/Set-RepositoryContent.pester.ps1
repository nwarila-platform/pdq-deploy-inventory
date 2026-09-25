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
    proven is the script's real loading path. The cases that choose between the two
    modules the script accepts write AWSPowerShell too, and see only their own sandbox.

    The stub serves the bucket a case declares and writes a file of the size each
    object claims, so 'already current' on a second run is proven by the same
    comparison the script makes rather than by a flag the stub sets. It keeps its
    state in the case's sandbox -- the bucket, and a log of every listing, every fetch
    and the module that answered each call -- because a module's functions cannot see
    this file's scopes.

    Both transports are asserted: the standalone JSON emission and the $Ansible path
    via the inline context below (pairs are self-contained; no imports). Its Changed
    defaults to $True exactly like win_powershell -- so every test proves the script
    SETS Changed rather than inheriting a default. The context lives in this file's
    script scope, where the script finds it by name, and is removed after every case.
#>

Set-StrictMode -Version:'Latest'
$ErrorActionPreference = 'Stop'

BeforeAll {
  $Script:ScriptPath = Join-Path -Path:$PSScriptRoot -ChildPath:'Set-RepositoryContent.ps1'
  $Script:Bucket = 'nwarila-apprepo'
  $Script:Region = 'us-east-1'

  Function New-AnsibleContext {
    [CmdletBinding(
      ConfirmImpact = 'None',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $False
    )]
    [OutputType([PSCustomObject])]
    Param (
      [Parameter(
        DontShow = $False,
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.Management.Automation.SwitchParameter]
      $CheckMode
    )
    Write-Debug -Message:'[New-AnsibleContext] Entering'

    # Initialize Variable(s)
    [PSCustomObject]$Private:Result = $Null

    $Script:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }

    [PSCustomObject]$Result = $Script:Ansible
    $Result

    Write-Debug -Message:'[New-AnsibleContext] Exiting'
  }

  # One bucket object. Size and age are what the script compares, so both are declared.
  Function New-S3Entry {
    [CmdletBinding(
      ConfirmImpact = 'None',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $False
    )]
    [OutputType([PSCustomObject])]
    Param (
      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $Key,

      [Parameter(
        DontShow = $False,
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.DateTime]
      $Modified = [System.DateTime]::UtcNow.AddDays(-1),

      [Parameter(
        DontShow = $False,
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.Int64]
      $Size = 10
    )
    Write-Debug -Message:'[New-S3Entry] Entering'

    # Initialize Variable(s)
    [PSCustomObject]$Private:Result = $Null

    [PSCustomObject]$Result = [PSCustomObject]@{ Key = $Key; Size = $Size; LastModified = $Modified }
    $Result

    Write-Debug -Message:'[New-S3Entry] Exiting'
  }

  # Put a local copy in place exactly as a previous run would have left it.
  Function Set-LocalCopy {
    [CmdletBinding(
      ConfirmImpact = 'None',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $False
    )]
    [OutputType([System.String])]
    Param (
      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $Key,

      [Parameter(
        DontShow = $False,
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.Int64]
      $Size = 10,

      [Parameter(
        DontShow = $False,
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.DateTime]
      $Written = [System.DateTime]::UtcNow
    )
    Write-Debug -Message:'[Set-LocalCopy] Entering'

    # Initialize Variable(s)
    [System.String]$Private:LocalPath = [System.String]::Empty
    [System.String]$Private:Parent = [System.String]::Empty
    [System.String]$Private:Result = [System.String]::Empty

    $LocalPath = Join-Path -Path:$Script:Repository -ChildPath:($Key.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $Parent = Split-Path -Path:$LocalPath -Parent
    If (-not (Test-Path -LiteralPath:$Parent)) { [void](New-Item -ItemType:'Directory' -Path:$Parent -Force) }
    [System.IO.File]::WriteAllBytes($LocalPath, [System.Byte[]]::new($Size))
    (Get-Item -LiteralPath:$LocalPath).LastWriteTimeUtc = $Written

    [System.String]$Result = $LocalPath
    $Result

    Write-Debug -Message:'[Set-LocalCopy] Exiting'
  }

  # A real module the script's own Import-Module resolves, rather than a shimmed import. Either
  # name serves the same fake bucket, from the case's state directory.
  Function New-S3StubModule {
    [CmdletBinding(
      ConfirmImpact = 'None',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $False
    )]
    [OutputType([System.Void])]
    Param (
      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $Name,

      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $Root,

      [Parameter(
        DontShow = $False,
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.Management.Automation.SwitchParameter]
      $UseMultipartDownload
    )
    Write-Debug -Message:'[New-S3StubModule] Entering'

    # Initialize Variable(s)
    [System.String]$Private:ModuleDir = [System.String]::Empty
    [System.String]$Private:Source = [System.String]::Empty

    $ModuleDir = Join-Path -Path:$Root -ChildPath:$Name
    [void](New-Item -ItemType:'Directory' -Path:$ModuleDir -Force)
    $Source = @'
  Function Get-S3Object {
    [CmdletBinding()]
    Param ([System.String]$BucketName, [System.String]$Region)
    Add-Content -LiteralPath:'{State}/Listed.log' -Value:$BucketName
    Add-Content -LiteralPath:'{State}/Served.log' -Value:($MyInvocation.MyCommand.Module.Name)
    # Emitted one object at a time, as the real cmdlet does.
    Import-Clixml -LiteralPath:'{State}/Bucket.xml'
  }

  Function Read-S3Object {
    [CmdletBinding()]
    Param ([System.String]$BucketName, [System.String]$File, [System.String]$Key, [System.String]$Region{MultipartParameter})
    Add-Content -LiteralPath:'{State}/Fetched.log' -Value:$Key
    Add-Content -LiteralPath:'{State}/Multipart.log' -Value:($PSBoundParameters.ContainsKey('UseMultipartDownload'))
    Add-Content -LiteralPath:'{State}/Served.log' -Value:($MyInvocation.MyCommand.Module.Name)
    $Entry = @(Import-Clixml -LiteralPath:'{State}/Bucket.xml' | Where-Object -FilterScript:({ $PSItem.Key -eq $Key }))[0]
    [System.IO.File]::WriteAllBytes($File, [System.Byte[]]::new($Entry.Size))
    Get-Item -LiteralPath:$File
  }

  Export-ModuleMember -Function:@('Get-S3Object', 'Read-S3Object')
'@
    Set-Content -LiteralPath:(Join-Path -Path:$ModuleDir -ChildPath:($Name + '.psm1')) -Value:($Source.Replace('{MultipartParameter}', $(If ($UseMultipartDownload) { ', [System.Management.Automation.SwitchParameter]$UseMultipartDownload' } Else { [System.String]::Empty })).Replace('{State}', $Script:FakeS3))
    Set-Content -LiteralPath:(Join-Path -Path:$ModuleDir -ChildPath:($Name + '.psd1')) -Value:(
      "@{ ModuleVersion = '1.0.0'; RootModule = '$Name.psm1'; FunctionsToExport = @('Get-S3Object', 'Read-S3Object'); GUID = '$([System.Guid]::NewGuid())'; Author = 'spec' }"
    )

    Write-Debug -Message:'[New-S3StubModule] Exiting'
  }

  # The bucket the stub serves for the rest of the case.
  Function Set-FakeBucket {
    [CmdletBinding(
      ConfirmImpact = 'None',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $False
    )]
    [OutputType([System.Void])]
    Param (
      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [AllowEmptyCollection()]
      [System.Object[]]
      $Entry
    )
    Write-Debug -Message:'[Set-FakeBucket] Entering'

    $Entry | Export-Clixml -LiteralPath:(Join-Path -Path:$Script:FakeS3 -ChildPath:'Bucket.xml') -Force

    Write-Debug -Message:'[Set-FakeBucket] Exiting'
  }

  # What the stub recorded in this case, one line per call: 'Listed' holds the bucket each
  # listing asked for, 'Fetched' each key read, and 'Served' the module that answered each call.
  Function Get-FakeS3Log {
    [CmdletBinding(
      ConfirmImpact = 'None',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $False
    )]
    [OutputType([System.String[]])]
    Param (
      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [ValidateSet('Fetched', 'Listed', 'Multipart', 'Served')]
      [System.String]
      $Name
    )
    Write-Debug -Message:'[Get-FakeS3Log] Entering'

    # Initialize Variable(s)
    [System.String[]]$Private:Result = @()

    [System.String[]]$Result = @(Get-Content -LiteralPath:(Join-Path -Path:$Script:FakeS3 -ChildPath:($Name + '.log')))
    $Result

    Write-Debug -Message:'[Get-FakeS3Log] Exiting'
  }
}

Describe 'Set-RepositoryContent' {

  BeforeEach {
    $Script:Sandbox = Join-Path -Path:([System.IO.Path]::GetTempPath()) -ChildPath:('repo-' + [System.Guid]::NewGuid().ToString('N'))
    $Script:Repository = Join-Path -Path:$Script:Sandbox -ChildPath:'Repository'
    [void](New-Item -ItemType:'Directory' -Path:$Script:Repository -Force)

    $Script:FakeS3 = Join-Path -Path:$Script:Sandbox -ChildPath:'FakeS3'
    [void](New-Item -ItemType:'Directory' -Path:$Script:FakeS3 -Force)
    ForEach ($LogName In @('Fetched', 'Listed', 'Served')) {
      [void](New-Item -ItemType:'File' -Path:(Join-Path -Path:$Script:FakeS3 -ChildPath:($LogName + '.log')) -Force)
    }
    Set-FakeBucket -Entry:@()

    $Script:ModuleRoot = Join-Path -Path:$Script:Sandbox -ChildPath:'Modules'
    New-S3StubModule -Name:'AWS.Tools.S3' -Root:$Script:ModuleRoot

    $Script:PreviousModulePath = $env:PSModulePath
    $env:PSModulePath = $Script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
  }

  AfterEach {
    Remove-Variable -Name:'Ansible' -Scope:'Script' -Force -ErrorAction:'SilentlyContinue'
    $env:PSModulePath = $Script:PreviousModulePath
    Remove-Module -Name:@('AWS.Tools.S3', 'AWSPowerShell') -Force -ErrorAction:'SilentlyContinue'
    Remove-Item -LiteralPath:$Script:Sandbox -Recurse -Force -ErrorAction:'SilentlyContinue'
  }

  Context 'what it removes' {

    It 'removes a local file the bucket no longer carries' {
      # The bucket is the only place that decides what the repository contains; a superseded
      # version stays addressable there until it is pruned there.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$Stale -Parent) -Force)
      Set-Content -LiteralPath:$Stale -Value:'superseded'
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Stale | Should -Not -Exist
      $Ctx.Result.removed.Count | Should -Be 1
      $Ctx.Result.changed | Should -BeTrue
    }

    It 'removes a file nothing in the bucket ever placed' {
      # A hand-placed script is exactly the drift this sync exists to remove: it would exist on one
      # host and no other, and nothing would reveal that until something read it.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Rogue = Join-Path -Path:$Script:Repository -ChildPath:'hand-placed.ps1'
      Set-Content -LiteralPath:$Rogue -Value:'not from the bucket'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Rogue | Should -Not -Exist
    }

    It 'keeps every file the bucket does carry' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'), (New-S3Entry -Key:'Vendor/App/1.0/notes.txt'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      (Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe') | Should -Exist
      (Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/notes.txt') | Should -Exist
    }

    It 'does not mistake a file it is about to fetch for one nothing owns' {
      # Surplus is enumerated before anything is written. If it were enumerated after, a freshly
      # fetched object could be deleted by the same run that fetched it.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      (Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe') | Should -Exist
      $Ctx.Result.removed.Count | Should -Be 0
    }

    It 'clears a directory its last object left behind' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$Stale -Parent) -Force)
      Set-Content -LiteralPath:$Stale -Value:'superseded'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      (Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0') | Should -Not -Exist
    }

    It 'never removes the repository root, even when the bucket is empty' {
      # The root is the mount point. Removing it would hide an unmounted volume behind a missing
      # directory, which is the fault this script checks for before it does anything.
      Set-FakeBucket -Entry:@()
      $Orphan = Join-Path -Path:$Script:Repository -ChildPath:'orphan.txt'
      Set-Content -LiteralPath:$Orphan -Value:'x'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Script:Repository | Should -Exist
      $Orphan | Should -Not -Exist
    }

    It 'removes nothing in check mode, and still reports what it would remove' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$Stale -Parent) -Force)
      Set-Content -LiteralPath:$Stale -Value:'superseded'
      $Ctx = New-AnsibleContext -CheckMode
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Stale | Should -Exist
      $Ctx.Result.removed.Count | Should -Be 1
      $Ctx.Result.swept.Count | Should -Be 1
      $Ctx.Result.changed | Should -BeTrue
    }

    It 'converges: a second run over the first run''s result removes nothing' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/2.0/app.exe'))
      $Stale = Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe'
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$Stale -Parent) -Force)
      Set-Content -LiteralPath:$Stale -Value:'superseded'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Second = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Second.Result.changed | Should -BeFalse
      $Second.Result.removed.Count | Should -Be 0
    }
  }

  Context 'what it fetches' {

    It 'fetches every object when the repository is empty' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'), (New-S3Entry -Key:'Vendor/App/1.0/notes.txt'))
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      @(Get-FakeS3Log -Name:'Fetched').Count | Should -Be 2
      $Ctx.Changed | Should -BeTrue
      $Ctx.Result.fetched | Should -Contain 'Vendor/App/1.0/app.exe'
    }

    It 'uses multipart download for every fetch when the module offers it' {
      New-S3StubModule -Name:'AWS.Tools.S3' -Root:$Script:ModuleRoot -UseMultipartDownload
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'), (New-S3Entry -Key:'Vendor/App/1.0/notes.txt'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Get-FakeS3Log -Name:'Multipart' | Select-Object -Unique | Should -Be 'True'
    }

    It 'does not use multipart download for any fetch when the module does not offer it' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'), (New-S3Entry -Key:'Vendor/App/1.0/notes.txt'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Get-FakeS3Log -Name:'Multipart' | Select-Object -Unique | Should -Be 'False'
    }

    It 'creates the intermediate directories a nested key names' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Expected = Join-Path -Path:$Script:Repository -ChildPath:('Vendor/App/1.0/app.exe'.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
      Test-Path -LiteralPath:$Expected | Should -BeTrue
    }

    It 'fetches nothing when every local copy matches, and reports no change' {
      $Entries = @((New-S3Entry -Key:'Vendor/App/1.0/app.exe'), (New-S3Entry -Key:'Vendor/App/1.0/notes.txt'))
      Set-FakeBucket -Entry:$Entries
      ForEach ($Entry In $Entries) { [void](Set-LocalCopy -Key:($Entry.Key) -Size:($Entry.Size)) }
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      @(Get-FakeS3Log -Name:'Fetched').Count | Should -Be 0
      $Ctx.Changed | Should -BeFalse
      $Ctx.Result.msg | Should -BeLike '*already current*'
    }

    It 'converges: a second run over the first run''s result fetches nothing' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Clear-Content -LiteralPath:(Join-Path -Path:$Script:FakeS3 -ChildPath:'Fetched.log')
      $Second = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      @(Get-FakeS3Log -Name:'Fetched').Count | Should -Be 0
      $Second.Changed | Should -BeFalse
    }

    It 'refetches an object whose local copy is a different size' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe' -Size:4096))
      [void](Set-LocalCopy -Key:'Vendor/App/1.0/app.exe' -Size:11)
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Get-FakeS3Log -Name:'Fetched' | Should -Contain 'Vendor/App/1.0/app.exe'
    }

    It 'refetches an object the bucket has updated since the local copy was written' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe' -Modified:([System.DateTime]::UtcNow)))
      [void](Set-LocalCopy -Key:'Vendor/App/1.0/app.exe' -Written:([System.DateTime]::UtcNow.AddDays(-7)))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Get-FakeS3Log -Name:'Fetched' | Should -Contain 'Vendor/App/1.0/app.exe'
    }

    It 'ignores the folder markers a console leaves in a bucket' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/' -Size:0), (New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Get-FakeS3Log -Name:'Fetched' | Should -Not -Contain 'Vendor/'
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
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Awkward = Join-Path -Path:$Script:Repository -ChildPath:'.'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Awkward -Region:$Script:Region
      (Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe') | Should -Exist
      $Second = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Awkward -Region:$Script:Region
      $Second.Result.changed | Should -BeFalse
      $Second.Result.removed.Count | Should -Be 0
    }

    It 'keeps the bucket''s own file when the key is not already canonical' {
      # A key carrying '//' names a file the filesystem calls something shorter. Holding the longer
      # spelling would mark the bucket's own object surplus on the next run: delete, refetch,
      # never converge, and the installer absent between alternate converges. Interpolated key
      # building produces exactly this.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor//App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Second = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Second.Result.removed.Count | Should -Be 0
      $Second.Result.changed | Should -BeFalse
    }

    It 'converges when a surplus file sits where a key needs a directory' {
      # Creating a directory over an existing file is a silent no-op, so the fetch then fails --
      # and the file that caused it is never reached if removal runs second. Every later run fails
      # the same way and a human has to intervene. Removal runs first.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Blocker = Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App'
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$Blocker -Parent) -Force)
      Set-Content -LiteralPath:$Blocker -Value:'in the way'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      (Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0/app.exe') | Should -Exist
    }

    It 'clears a whole chain of directories its objects left behind' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Keep/Me/1.0/app.exe'))
      $Stale = Join-Path -Path:$Script:Repository -ChildPath:'Gone/Deep/Deeper/1.0/old.exe'
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$Stale -Parent) -Force)
      Set-Content -LiteralPath:$Stale -Value:'superseded'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      (Join-Path -Path:$Script:Repository -ChildPath:'Gone') | Should -Not -Exist
    }

    It 'sweeps an empty directory even when nothing else changed' {
      # Swept unconditionally: a directory emptied by a run that then failed would otherwise
      # persist while every later run reported no change.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Left = Join-Path -Path:$Script:Repository -ChildPath:'Left/Behind'
      [void](New-Item -ItemType:'Directory' -Path:$Left -Force)
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Left | Should -Not -Exist
    }
  }

  Context 'check mode, and what it reports' {

    It 'deletes a local file the bucket no longer holds' {
      # This assertion is the reverse of the one it replaces. The mirror was additive, on the
      # reasoning that leaving a superseded version on disk kept it available for a rollback. It
      # also let every volume drift somewhere different, invisibly. Rollback now lives in the
      # bucket, which is the only place that decides what the repository contains.
      $Orphan = Set-LocalCopy -Key:'Vendor/App/0.9/old.exe'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Test-Path -LiteralPath:$Orphan | Should -BeFalse
    }

    It 'fetches nothing in check mode, and still reports the change it would make' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Ctx = New-AnsibleContext -CheckMode
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      @(Get-FakeS3Log -Name:'Fetched').Count | Should -Be 0
      $Ctx.Changed | Should -BeTrue
      $Ctx.Result.check_mode | Should -BeTrue
    }
  }

  Context 'what it refuses to walk' {

    It 'refuses a reparse point rather than deleting through it' {
      # Windows PowerShell follows directory junctions when it recurses, so a junction here would
      # present files living on another volume as surplus and this script would delete them --
      # outside the repository, with the privileges a deployment runs as.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Outside = Join-Path -Path:$Script:Sandbox -ChildPath:'Outside'
      [void](New-Item -ItemType:'Directory' -Path:$Outside -Force)
      Set-Content -LiteralPath:(Join-Path -Path:$Outside -ChildPath:'keep.txt') -Value:'not ours'
      $Link = Join-Path -Path:$Script:Repository -ChildPath:'escape'
      [void](New-Item -ItemType:'SymbolicLink' -Path:$Link -Target:$Outside -ErrorAction:'SilentlyContinue')
      If (-not (Test-Path -LiteralPath:$Link)) { Set-ItResult -Skipped -Because:'links need privilege here' ; Return }
      [void](New-AnsibleContext)
      { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -ExpectedMessage '*reparse point*'
      (Join-Path -Path:$Outside -ChildPath:'keep.txt') | Should -Exist
    }

    It 'refuses a reparse point nested below the top level' {
      # The first version of this guard checked only the repository's immediate children while the
      # enumeration recursed past that, so a junction one level down was walked and deleted through.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Outside = Join-Path -Path:$Script:Sandbox -ChildPath:'Outside'
      [void](New-Item -ItemType:'Directory' -Path:$Outside -Force)
      Set-Content -LiteralPath:(Join-Path -Path:$Outside -ChildPath:'keep.txt') -Value:'not ours'
      $Nested = Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App'
      [void](New-Item -ItemType:'Directory' -Path:$Nested -Force)
      $Link = Join-Path -Path:$Nested -ChildPath:'escape'
      [void](New-Item -ItemType:'SymbolicLink' -Path:$Link -Target:$Outside -ErrorAction:'SilentlyContinue')
      If (-not (Test-Path -LiteralPath:$Link)) { Set-ItResult -Skipped -Because:'links need privilege here' ; Return }
      [void](New-AnsibleContext)
      { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -ExpectedMessage '*reparse point*'
      (Join-Path -Path:$Outside -ChildPath:'keep.txt') | Should -Exist
    }

    It 'refuses a key that resolves outside the repository' {
      # Canonicalising a key collapses '..', which can land outside the volume entirely. This
      # script is the one place a key from the bucket becomes a local path, so containment is
      # checked here or nowhere.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/../../escaped.exe'))
      [void](New-AnsibleContext)
      { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -ExpectedMessage '*outside the repository*'
      (Join-Path -Path:$Script:Sandbox -ChildPath:'escaped.exe') | Should -Not -Exist
    }

    It 'does not sweep a directory the fetch has just refilled' {
      # The fetch runs between the emptiness check and the sweep, so a folder that was empty when
      # the list was built can hold a freshly fetched object by the time the sweep reaches it.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Empty = Join-Path -Path:$Script:Repository -ChildPath:'Vendor/App/1.0'
      [void](New-Item -ItemType:'Directory' -Path:$Empty -Force)
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      (Join-Path -Path:$Empty -ChildPath:'app.exe') | Should -Exist
      $Ctx.Result.swept | Should -Not -Contain $Empty
    }

    It 'honours -WhatIf, because a person reaching for it expects nothing to change' {
      # The module injects -WhatIf in check mode and this script decides check mode from
      # $Ansible.CheckMode instead -- but a person running it directly still expects -WhatIf to
      # mean change nothing, and this script deletes.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Rogue = Join-Path -Path:$Script:Repository -ChildPath:'rogue.txt'
      Set-Content -LiteralPath:$Rogue -Value:'hand placed'
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region -WhatIf
      $Rogue | Should -Exist
      @(Get-FakeS3Log -Name:'Fetched').Count | Should -Be 0
      $Ctx.Result.check_mode | Should -BeTrue
    }
  }

  Context 'what it refuses' {

    It 'fails naming the repository directory when the volume holding it is not mounted' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      $Missing = Join-Path -Path:$Script:Sandbox -ChildPath:'NoSuchVolume'
      [void](New-AnsibleContext)
      { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Missing -Region:$Script:Region } |
        Should -Throw -ExpectedMessage '*not there*'
    }
  }

  Context 'which S3 module it reads through' {

    BeforeEach {
      # Only the modules a case writes may answer: the runner's own AWS modules, or a stub left
      # loaded by an earlier case, would otherwise decide the result.
      Remove-Module -Name:@('AWS.Tools.S3', 'AWSPowerShell') -Force -ErrorAction:'SilentlyContinue'
      $Script:OwnModules = Join-Path -Path:$Script:Sandbox -ChildPath:'OwnModules'
      [void](New-Item -ItemType:'Directory' -Path:$Script:OwnModules -Force)
      $env:PSModulePath = $Script:OwnModules
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
    }

    It 'reads through AWSPowerShell when it is the only one, as on stock Windows Server 2019' {
      New-S3StubModule -Name:'AWSPowerShell' -Root:$Script:OwnModules
      $Ctx = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Get-FakeS3Log -Name:'Served' | Select-Object -Unique | Should -Be 'AWSPowerShell'
      $Ctx.Result.fetched | Should -Contain 'Vendor/App/1.0/app.exe'
    }

    It 'reads through AWS.Tools.S3 when both are installed' {
      New-S3StubModule -Name:'AWSPowerShell' -Root:$Script:OwnModules
      New-S3StubModule -Name:'AWS.Tools.S3' -Root:$Script:OwnModules
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      Get-FakeS3Log -Name:'Served' | Select-Object -Unique | Should -Be 'AWS.Tools.S3'
      Get-Module -Name:'AWSPowerShell' | Should -BeNullOrEmpty
    }

    It 'fails naming both when neither is installed' {
      [void](New-AnsibleContext)
      { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -ExpectedMessage '*AWS.Tools.S3*AWSPowerShell*'
      @(Get-FakeS3Log -Name:'Fetched').Count | Should -Be 0
    }

    It 'writes a failure it throws as a warning into redirected output' {
      # A background run keeps only what its redirect captures: the error itself goes to the
      # host's error output, which Task Scheduler discards.
      $Log = Join-Path -Path:$Script:Sandbox -ChildPath:'Sync-Repository.log'
      Remove-Variable -Name:'Ansible' -Scope:'Script' -Force -ErrorAction:'SilentlyContinue'
      { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region 3> $Log } |
        Should -Throw
      Get-Content -LiteralPath:$Log -Raw | Should -BeLike '*Neither AWS.Tools.S3 nor AWSPowerShell is installed*'
    }
  }

  Context 'what it reports' {

    It 'emits the result as JSON when run outside the module' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      Remove-Variable -Name:'Ansible' -Scope:'Script' -Force -ErrorAction:'SilentlyContinue'
      $Json = & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region |
        Out-String | ConvertFrom-Json
      $Json.bucket | Should -Be $Script:Bucket
      $Json.changed | Should -BeTrue
      $Json.present | Should -Be 1
    }

    It 'writes that JSON as exactly one line, which parses back to the result' {
      # A log that captures every stream then still ends with the whole result.
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'), (New-S3Entry -Key:'Vendor/App/1.0/notes.txt'))
      Remove-Variable -Name:'Ansible' -Scope:'Script' -Force -ErrorAction:'SilentlyContinue'
      $Output = @(& $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region)
      $Output.Count | Should -Be 1
      $Output[0] | Should -Not -Match '[\r\n]'
      $Json = $Output[0] | ConvertFrom-Json
      $Json.bucket | Should -Be $Script:Bucket
      $Json.changed | Should -BeTrue
      $Json.present | Should -Be 2
      $Json.fetched | Should -HaveCount 2
      $Json.fetched | Should -Contain 'Vendor/App/1.0/notes.txt'
    }

    It 'reads the bucket exactly once per run' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      @(Get-FakeS3Log -Name:'Listed').Count | Should -Be 1
    }
  }
}
