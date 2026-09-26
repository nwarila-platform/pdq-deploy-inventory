#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-RepositoryContent.ps1 (org pair convention: every script ships
    with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. Bucket listing is an S3-module edge, so this
    file WRITES AWS.Tools.S3 into a sandbox and puts that sandbox on PSModulePath. The
    script's own Import-Module genuinely succeeds and binds to the stub, proving its
    real loading path. Cases choosing between the two accepted modules write
    AWSPowerShell too, and see only their own sandbox.

    The hidden part-fetch seam supplies tasks and disposable response owners without
    an SDK on the runner. The engine still schedules the parts, copies each body,
    checks its length, retries it and promotes the completed temp file. The fake pins
    every call to the listed ETag and records its range, attempt and time. Thus a
    second run proves 'already current' through the script's own comparison rather
    than a flag the fake sets.

    Both transports are asserted: the standalone JSON emission and the $Ansible path
    via the inline context below (pairs are self-contained; no imports). Its Changed
    defaults to $True exactly like win_powershell -- so every test proves the script
    SETS Changed rather than inheriting a default. The context lives in this file's
    script scope, where the script finds it by name, and is removed after every case.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester-generated scopes share the event recorder only through uniquely named process-local test state.')]
Param ()

Class RepositorySyncFaultStream : System.IO.Stream {
  [System.IO.MemoryStream]$Inner
  [System.Int64]$FailAfter

  RepositorySyncFaultStream([System.Byte[]]$Bytes, [System.Int64]$FailAfter) {
    $this.Inner = [System.IO.MemoryStream]::new($Bytes, $False)
    $this.FailAfter = $FailAfter
  }

  [System.Boolean] get_CanRead() { Return $True }
  [System.Boolean] get_CanSeek() { Return $False }
  [System.Boolean] get_CanWrite() { Return $False }
  [System.Int64] get_Length() { Return $this.Inner.Length }
  [System.Int64] get_Position() { Return $this.Inner.Position }
  [void] set_Position([System.Int64]$Value) { Throw 'Position is not supported.' }
  [void] Flush() {}
  [System.Int32] Read([System.Byte[]]$Buffer, [System.Int32]$Offset, [System.Int32]$Count) {
    If ($this.Inner.Position -ge $this.FailAfter) { Throw 'fake mid-body failure' }
    [System.Int32]$Private:Allowed = [System.Math]::Min($Count, $this.FailAfter - $this.Inner.Position)
    Return $this.Inner.Read($Buffer, $Offset, $Allowed)
  }
  [System.Int64] Seek([System.Int64]$Offset, [System.IO.SeekOrigin]$Origin) { Throw 'Seek is not supported.' }
  [void] SetLength([System.Int64]$Value) { Throw 'SetLength is not supported.' }
  [void] Write([System.Byte[]]$Buffer, [System.Int32]$Offset, [System.Int32]$Count) { Throw 'Write is not supported.' }
}

Class RepositorySyncOwner : System.IDisposable {
  [System.Int64]$ContentLength
  [System.String]$Id
  [System.Management.Automation.ScriptBlock]$OnDispose
  [System.IO.Stream]$ResponseStream

  RepositorySyncOwner(
    [System.Int64]$ContentLength,
    [System.IO.Stream]$ResponseStream,
    [PSCustomObject]$Call,
    [System.Management.Automation.ScriptBlock]$OnDispose
  ) {
    $Global:RepositorySyncOwnerNumber++
    $this.ContentLength = $ContentLength
    $this.Id = '{0}|{1}|{2}' -f $Call.Key, $Call.Start, $Global:RepositorySyncOwnerNumber
    $this.OnDispose = $OnDispose
    $this.ResponseStream = $ResponseStream
  }

  [void] Dispose() {
    [System.Boolean]$Private:Observed = $False
    If ($Null -ne $this.OnDispose) { $Observed = [System.Boolean](& $this.OnDispose) }
    [void]$Global:RepositorySyncDisposals.Add([PSCustomObject]@{
        Id                = $this.Id
        ObservePathExists = $Observed
      })
    If ($Null -ne $this.ResponseStream) {
      $this.ResponseStream.Dispose()
      $this.ResponseStream = $Null
    }
  }
}

Class RepositorySyncFixture {
  Static [System.Byte[]] ContentBytes([System.Int32]$Length, [System.Int64]$Start) {
    [System.Byte[]]$Private:Bytes = [System.Byte[]]::new($Length)
    For ([System.Int32]$Index = 0; $Index -lt $Length; $Index += 4096) {
      $Bytes[$Index] = [System.Byte](($Start + $Index) % 251)
    }
    If ($Length -gt 0) { $Bytes[$Length - 1] = [System.Byte](($Start + $Length - 1) % 251) }
    Return $Bytes
  }

  Static [System.String] ContentHash([System.Int32]$Length) {
    [System.Byte[]]$Private:Bytes = [RepositorySyncFixture]::ContentBytes($Length, 0)
    [System.Security.Cryptography.SHA256]$Private:Hasher = [System.Security.Cryptography.SHA256]::Create()
    Try {
      For ([System.Int32]$PartEnd = 8MB - 1; $PartEnd -lt $Length; $PartEnd += 8MB) {
        $Bytes[$PartEnd] = [System.Byte]($PartEnd % 251)
      }
      Return [System.BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    } Finally {
      $Hasher.Dispose()
    }
  }

  Static [System.Threading.Tasks.Task] DefaultPartTask([PSCustomObject]$Call) {
    [System.Int32]$Private:Length = If ($Call.Unranged) { 0 } Else { [System.Int32]($Call.End - $Call.Start + 1) }
    [System.Byte[]]$Private:Bytes = [RepositorySyncFixture]::ContentBytes($Length, $Call.Start)
    Return [RepositorySyncFixture]::PartTask($Call, $Length, [System.IO.MemoryStream]::new($Bytes, $False), $Null)
  }

  Static [System.Threading.Tasks.Task] PartTask(
    [PSCustomObject]$Call,
    [System.Int64]$ContentLength,
    [System.IO.Stream]$ResponseStream,
    [System.Management.Automation.ScriptBlock]$OnDispose
  ) {
    [RepositorySyncOwner]$Private:Owner = [RepositorySyncOwner]::new(
      $ContentLength,
      $ResponseStream,
      $Call,
      $OnDispose
    )
    Return [System.Threading.Tasks.Task[System.Object]]::FromResult([System.Object]$Owner)
  }
}

Set-StrictMode -Version:'Latest'
$ErrorActionPreference = 'Stop'

BeforeAll {
  $Script:ImplementationPath = Join-Path -Path:$PSScriptRoot -ChildPath:'Set-RepositoryContent.ps1'
  $Script:ScriptPath = {
    [CmdletBinding(
      ConfirmImpact = 'Medium',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $True
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
      $Bucket,

      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $Path,

      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $Region
    )

    & $Script:ImplementationPath -Bucket:$Bucket -PartFetcher:$Script:PartFetcher -Path:$Path -Region:$Region
  }
  $Script:Bucket = 'nwarila-apprepo'
  $Script:Region = 'us-east-1'

  Function Write-EventLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The spec records event-log writes on Linux, where the cmdlet is absent.')]
    [CmdletBinding(ConfirmImpact = 'None', DefaultParameterSetName = 'default', HelpUri = '', PositionalBinding = $False, SupportsPaging = $False, SupportsShouldProcess = $False)]
    [OutputType([PSCustomObject])]
    Param (
      [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)][System.String]$EntryType,
      [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)][System.Int64]$EventId,
      [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)][System.String]$LogName,
      [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)][System.String]$Message,
      [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)][System.String]$Source
    )
    Write-Debug -Message:'[Write-EventLog] Entering'
    [PSCustomObject]$Private:Result = $Null
    If ($Global:RepositorySyncFailEventId -eq $EventId) { Throw 'fake event-log failure' }
    [void]$Global:RepositorySyncEventLog.Add([PSCustomObject]@{ EntryType = $EntryType; EventId = $EventId; LogName = $LogName; Message = $Message; Source = $Source })
    [PSCustomObject]$Result = [PSCustomObject]@{ Sentinel = $True }
    $Result
    Write-Debug -Message:'[Write-EventLog] Exiting'
  }

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
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $ETag = [System.String]::Empty,

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
      $Size = 10,

      [Parameter(
        DontShow = $False,
        Mandatory = $False,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [ValidateSet('DEEP_ARCHIVE', 'GLACIER', 'GLACIER_IR', 'STANDARD')]
      [System.String]
      $StorageClass = 'STANDARD'
    )
    Write-Debug -Message:'[New-S3Entry] Entering'

    # Initialize Variable(s)
    [System.String]$Private:EntryETag = [System.String]::Empty
    [PSCustomObject]$Private:Result = $Null

    $EntryETag = If ([System.String]::IsNullOrEmpty($ETag)) { '"{0}"' -f $Key } Else { $ETag }
    [PSCustomObject]$Result = [PSCustomObject]@{
      ETag         = $EntryETag
      Key          = $Key
      LastModified = $Modified
      Size         = $Size
      StorageClass = $StorageClass
    }
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
      $Root
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
    If ([System.Net.ServicePointManager]::DefaultConnectionLimit -ne 10) {
      Throw 'DefaultConnectionLimit was not 10 before Get-S3Object.'
    }
    Add-Content -LiteralPath:'{State}/Listed.log' -Value:$BucketName
    Add-Content -LiteralPath:'{State}/Served.log' -Value:($MyInvocation.MyCommand.Module.Name)
    # Emitted one object at a time, as the real cmdlet does.
    Import-Clixml -LiteralPath:'{State}/Bucket.xml'
  }

  Export-ModuleMember -Function:'Get-S3Object'
'@
    Set-Content -LiteralPath:(Join-Path -Path:$ModuleDir -ChildPath:($Name + '.psm1')) -Value:($Source.Replace('{State}', $Script:FakeS3))
    Set-Content -LiteralPath:(Join-Path -Path:$ModuleDir -ChildPath:($Name + '.psd1')) -Value:(
      "@{ ModuleVersion = '1.0.0'; RootModule = '$Name.psm1'; FunctionsToExport = @('Get-S3Object'); GUID = '$([System.Guid]::NewGuid())'; Author = 'spec' }"
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

    $Global:RepositorySyncEntries = @{}
    ForEach ($Object In $Entry) {
      $Global:RepositorySyncEntries[[System.String]$Object.Key] = $Object
    }
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
      [ValidateSet('Fetched', 'Listed', 'Served')]
      [System.String]
      $Name
    )
    Write-Debug -Message:'[Get-FakeS3Log] Entering'

    # Initialize Variable(s)
    [System.String[]]$Private:Result = @()

    [System.String[]]$Result = If ($Name -eq 'Fetched') {
      @($Global:RepositorySyncCalls | ForEach-Object -Process:({ $PSItem.Key }))
    } Else {
      @(Get-Content -LiteralPath:(Join-Path -Path:$Script:FakeS3 -ChildPath:($Name + '.log')))
    }
    $Result

    Write-Debug -Message:'[Get-FakeS3Log] Exiting'
  }

  Function Get-FakePartTask {
    [CmdletBinding(
      ConfirmImpact = 'None',
      DefaultParameterSetName = 'default',
      HelpUri = '',
      PositionalBinding = $False,
      SupportsPaging = $False,
      SupportsShouldProcess = $False
    )]
    [OutputType([System.Threading.Tasks.Task])]
    Param (
      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $Bucket,

      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.Int64]
      $End,

      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.String]
      $ETag,

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
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.Int64]
      $Start,

      [Parameter(
        DontShow = $False,
        Mandatory = $True,
        ParameterSetName = 'default',
        ValueFromPipeline = $False,
        ValueFromPipelineByPropertyName = $False
      )]
      [System.Boolean]
      $Unranged
    )
    Write-Debug -Message:'[Get-FakePartTask] Entering'

    # Initialize Variable(s)
    [System.Int32]$Private:Attempt = 0
    [PSCustomObject]$Private:Call = $Null
    [System.String]$Private:ExpectedETag = [System.String]::Empty
    [System.String]$Private:Identity = [System.String]::Empty
    [System.Threading.Tasks.Task]$Private:Result = $Null

    If ($Bucket -cne $Script:Bucket) { Throw ('Unexpected bucket: {0}' -f $Bucket) }
    $ExpectedETag = [System.String]$Global:RepositorySyncEntries[$Key].ETag
    If ($ETag -cne $ExpectedETag) {
      Throw ('ETag mismatch for {0}: {1} != {2}' -f $Key, $ETag, $ExpectedETag)
    }
    $Identity = '{0}|{1}|{2}' -f $Key, $Start, $End
    If (-not $Global:RepositorySyncAttempts.ContainsKey($Identity)) {
      $Global:RepositorySyncAttempts[$Identity] = 0
    }
    $Global:RepositorySyncAttempts[$Identity]++
    $Attempt = [System.Int32]$Global:RepositorySyncAttempts[$Identity]
    $Call = [PSCustomObject]@{
      Attempt  = $Attempt
      End      = $End
      Key      = $Key
      Start    = $Start
      Time     = [System.DateTime]::UtcNow
      Unranged = $Unranged
    }
    [void]$Global:RepositorySyncCalls.Add($Call)
    $Global:RepositorySyncCurrentCall = $Call

    [System.Threading.Tasks.Task]$Result = If ($Null -ne $Global:RepositorySyncBehavior) {
      & $Global:RepositorySyncBehavior
    } Else {
      [RepositorySyncFixture]::DefaultPartTask($Call)
    }
    $Result

    Write-Debug -Message:'[Get-FakePartTask] Exiting'
  }
}

Describe 'Set-RepositoryContent' {

  BeforeEach {
    $Script:PreviousConnectionLimit = [System.Net.ServicePointManager]::DefaultConnectionLimit
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 2
    [System.Collections.Generic.List[System.Object]]$Global:RepositorySyncCalls = [System.Collections.Generic.List[System.Object]]::new()
    [System.Management.Automation.ScriptBlock]$Global:RepositorySyncBehavior = $Null
    [PSCustomObject]$Global:RepositorySyncCurrentCall = $Null
    [System.Collections.Generic.List[System.Object]]$Global:RepositorySyncDisposals = [System.Collections.Generic.List[System.Object]]::new()
    [System.Collections.Hashtable]$Global:RepositorySyncEntries = @{}
    [System.Collections.Generic.List[System.Object]]$Global:RepositorySyncEventLog = [System.Collections.Generic.List[System.Object]]::new()
    [System.Int64]$Global:RepositorySyncFailEventId = 0
    [System.Int64]$Global:RepositorySyncOwnerNumber = 0
    [System.Collections.Hashtable]$Global:RepositorySyncAttempts = @{}
    [System.Object]$Global:RepositorySyncTestState = $Null
    $Script:PartFetcher = ${Function:Get-FakePartTask}
    $Script:Sandbox = Join-Path -Path:([System.IO.Path]::GetTempPath()) -ChildPath:('repo-' + [System.Guid]::NewGuid().ToString('N'))
    $Script:Repository = Join-Path -Path:$Script:Sandbox -ChildPath:'Repository'
    [void](New-Item -ItemType:'Directory' -Path:$Script:Repository -Force)

    $Script:FakeS3 = Join-Path -Path:$Script:Sandbox -ChildPath:'FakeS3'
    [void](New-Item -ItemType:'Directory' -Path:$Script:FakeS3 -Force)
    ForEach ($LogName In @('Listed', 'Served')) {
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
    [System.Net.ServicePointManager]::DefaultConnectionLimit = $Script:PreviousConnectionLimit
    $env:PSModulePath = $Script:PreviousModulePath
    Remove-Module -Name:@('AWS.Tools.S3', 'AWSPowerShell') -Force -ErrorAction:'SilentlyContinue'
    Remove-Item -LiteralPath:$Script:Sandbox -Recurse -Force -ErrorAction:'SilentlyContinue'
    Remove-Variable -Name:@(
      'RepositorySyncAttempts',
      'RepositorySyncBehavior',
      'RepositorySyncCalls',
      'RepositorySyncCurrentCall',
      'RepositorySyncDisposals',
      'RepositorySyncEntries',
      'RepositorySyncEventLog',
      'RepositorySyncFailEventId',
      'RepositorySyncOwnerNumber',
      'RepositorySyncTestState'
    ) -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
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
      $Global:RepositorySyncCalls.Clear()
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
      $Ctx.Result.fetched | Should -BeExactly @('Vendor/App/1.0/app.exe')
      $Ctx.Result.msg | Should -BeLike '*1 of 1 object(s) fetched*1 local file(s) removed*'
      $Success = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1000)
      ($Success[0].Message | ConvertFrom-Json).fetched | Should -Be 1
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

    It 'writes one bounded success event carrying counts' {
      Set-FakeBucket -Entry:@((New-S3Entry -Key:'Vendor/App/1.0/app.exe'))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $SuccessEvent = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1000)
      $SuccessEvent | Should -HaveCount 1
      $SuccessEvent[0].EntryType | Should -BeExactly 'Information'
      $SuccessEvent[0].LogName | Should -BeExactly 'Application'
      $SuccessEvent[0].Source | Should -BeExactly 'PDQ Repository Sync'
      $SuccessEvent[0].Message | Should -BeExactly '{"changed":true,"fetched":1,"removed":0,"skipped":0,"swept":0,"present":1}'
    }

    It 'preserves the original failure when its failure event cannot be written' {
      $Global:RepositorySyncFailEventId = 1002
      $Missing = Join-Path -Path:$Script:Sandbox -ChildPath:'NoSuchVolume'
      [void](New-AnsibleContext)
      $Thrown = { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Missing -Region:$Script:Region } | Should -Throw -PassThru
      $Thrown.Exception.Message | Should -BeLike '*repository directory is not there*'
    }

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

  Context 'part scheduling and retries' {

    It '[T2] downloads two 8 MiB parts and a tail through exact inclusive ranges' {
      $Key = 'Large/two-parts-and-tail.bin'
      $Size = 2 * 8MB + 37
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$Key -Size:$Size))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      @($Global:RepositorySyncCalls | ForEach-Object -Process:({ '{0}-{1}' -f $PSItem.Start, $PSItem.End })) |
        Should -BeExactly @('0-8388607', '8388608-16777215', '16777216-16777252')
      @($Global:RepositorySyncCalls | Where-Object -Property:'Unranged' -EQ -Value:$True) | Should -HaveCount 0
      $Local = Join-Path -Path:$Script:Repository -ChildPath:$Key
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$Local).Hash.ToLowerInvariant() |
        Should -BeExactly ([RepositorySyncFixture]::ContentHash($Size))
    }

    It '[T3] promotes a zero-byte object after one unranged request' {
      $Key = 'Empty/zero.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$Key -Size:0))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Global:RepositorySyncCalls | Should -HaveCount 1
      $Global:RepositorySyncCalls[0].Unranged | Should -BeTrue
      $Global:RepositorySyncCalls[0].Start | Should -Be 0
      $Global:RepositorySyncCalls[0].End | Should -Be -1
      (Get-Item -LiteralPath:(Join-Path -Path:$Script:Repository -ChildPath:$Key)).Length | Should -Be 0
    }

    It '[T4] holds a FIFO at ten in flight and overlaps an object boundary' {
      $FirstKey = 'Queue/first.bin'
      $SecondKey = 'Queue/second.bin'
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$FirstKey -Size:(6 * 8MB)),
        (New-S3Entry -Key:$SecondKey -Size:(6 * 8MB))
      )
      $Global:RepositorySyncTestState = [PSCustomObject]@{
        Active  = 0
        Gates   = [System.Collections.Generic.List[System.Object]]::new()
        Peak    = 0
        Released = $False
      }
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        $Length = [System.Int32]($Call.End - $Call.Start + 1)
        $Owner = [RepositorySyncOwner]::new(
          $Length,
          [System.IO.MemoryStream]::new([RepositorySyncFixture]::ContentBytes($Length, $Call.Start), $False),
          $Call,
          { [void]($Global:RepositorySyncTestState.Active--); $False }
        )
        $Global:RepositorySyncTestState.Active++
        $Global:RepositorySyncTestState.Peak = [System.Math]::Max(
          $Global:RepositorySyncTestState.Peak,
          $Global:RepositorySyncTestState.Active
        )
        If (-not $Global:RepositorySyncTestState.Released) {
          $Source = [System.Threading.Tasks.TaskCompletionSource[System.Object]]::new()
          [void]$Global:RepositorySyncTestState.Gates.Add([PSCustomObject]@{ Owner = $Owner; Source = $Source })
          If ($Global:RepositorySyncTestState.Gates.Count -eq 10) {
            $Global:RepositorySyncTestState.Released = $True
            ForEach ($Gate In $Global:RepositorySyncTestState.Gates) {
              [void]$Gate.Source.SetResult([System.Object]$Gate.Owner)
            }
          }
          $Source.Task
        } Else {
          [System.Threading.Tasks.Task[System.Object]]::FromResult([System.Object]$Owner)
        }
      }
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Global:RepositorySyncTestState.Peak | Should -Be 10
      @($Global:RepositorySyncCalls | ForEach-Object -Process:({ '{0}|{1}|{2}' -f $PSItem.Key, $PSItem.Start, $PSItem.End })) |
        Should -BeExactly @(
          "$FirstKey|0|8388607",
          "$FirstKey|8388608|16777215",
          "$FirstKey|16777216|25165823",
          "$FirstKey|25165824|33554431",
          "$FirstKey|33554432|41943039",
          "$FirstKey|41943040|50331647",
          "$SecondKey|0|8388607",
          "$SecondKey|8388608|16777215",
          "$SecondKey|16777216|25165823",
          "$SecondKey|25165824|33554431",
          "$SecondKey|33554432|41943039",
          "$SecondKey|41943040|50331647"
        )
    }

    It '[T4b] sends four older ready ranges before a requeued retry' {
      $FirstKey = 'Queue/retry-first.bin'
      $SecondKey = 'Queue/retry-second.bin'
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$FirstKey -Size:(7 * 8MB)),
        (New-S3Entry -Key:$SecondKey -Size:(8 * 8MB))
      )
      $Global:RepositorySyncTestState = [PSCustomObject]@{
        Gates    = [System.Collections.Generic.List[System.Object]]::new()
        Released = $False
      }
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        If ($Call.Key -eq $FirstKey -and $Call.Start -eq 0 -and $Call.Attempt -eq 1) {
          [System.Threading.Tasks.Task]::FromException([System.IO.IOException]::new('fake immediate request failure'))
        } ElseIf (-not $Global:RepositorySyncTestState.Released -and $Global:RepositorySyncCalls.Count -le 10) {
          $Length = [System.Int32]($Call.End - $Call.Start + 1)
          $Owner = [RepositorySyncOwner]::new(
            $Length,
            [System.IO.MemoryStream]::new([RepositorySyncFixture]::ContentBytes($Length, $Call.Start), $False),
            $Call,
            $Null
          )
          $Source = [System.Threading.Tasks.TaskCompletionSource[System.Object]]::new()
          [void]$Global:RepositorySyncTestState.Gates.Add([PSCustomObject]@{ Owner = $Owner; Source = $Source })
          $Source.Task
        } ElseIf (-not $Global:RepositorySyncTestState.Released) {
          [void][System.Threading.Tasks.Task]::Delay(3000).GetAwaiter().GetResult()
          $Global:RepositorySyncTestState.Released = $True
          ForEach ($Gate In $Global:RepositorySyncTestState.Gates) {
            [void]$Gate.Source.SetResult([System.Object]$Gate.Owner)
          }
          [RepositorySyncFixture]::DefaultPartTask($Call)
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $RetryIndex = [System.Array]::FindIndex(
        [System.Object[]]$Global:RepositorySyncCalls.ToArray(),
        [System.Predicate[System.Object]]{ Param ($Call) $Call.Key -eq $FirstKey -and $Call.Start -eq 0 -and $Call.Attempt -eq 2 }
      )
      $RetryIndex | Should -Be 15
      @($Global:RepositorySyncCalls)[11..14] | ForEach-Object -Process:({ '{0}|{1}|{2}' -f $PSItem.Key, $PSItem.Start, $PSItem.End }) |
        Should -BeExactly @(
          "$SecondKey|33554432|41943039",
          "$SecondKey|41943040|50331647",
          "$SecondKey|50331648|58720255",
          "$SecondKey|58720256|67108863"
        )
      ForEach ($Entry In $Global:RepositorySyncEntries.Values) {
        $Local = Join-Path -Path:$Script:Repository -ChildPath:($Entry.Key)
        (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$Local).Hash.ToLowerInvariant() |
          Should -BeExactly ([RepositorySyncFixture]::ContentHash([System.Int32]$Entry.Size))
      }
    }

    It '[T5] retries a wrong declared length as a request-stage failure' {
      $Key = 'Retry/wrong-length.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$Key -Size:4096))
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        If ($Call.Attempt -eq 1) {
          [RepositorySyncFixture]::PartTask(
            $Call,
            1,
            [System.IO.MemoryStream]::new([System.Byte[]]::new(1), $False),
            $Null
          )
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Retry = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001)
      $Retry | Should -HaveCount 1
      $Retry[0].Message | Should -BeLike "*$Key*bytes=0-4095*request*attempt 2*"
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:(Join-Path -Path:$Script:Repository -ChildPath:$Key)).Hash.ToLowerInvariant() |
        Should -BeExactly ([RepositorySyncFixture]::ContentHash(4096))
    }

    It '[T6] retries a short returned body as a body-stage failure' {
      $Key = 'Retry/short-body.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$Key -Size:4096))
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        $Length = [System.Int32]($Call.End - $Call.Start + 1)
        If ($Call.Attempt -eq 1) {
          [RepositorySyncFixture]::PartTask(
            $Call,
            $Length,
            [System.IO.MemoryStream]::new([System.Byte[]]::new($Length - 1), $False),
            $Null
          )
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Retry = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001)
      $Retry | Should -HaveCount 1
      $Retry[0].Message | Should -BeLike "*$Key*bytes=0-4095*body*attempt 2*"
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:(Join-Path -Path:$Script:Repository -ChildPath:$Key)).Hash.ToLowerInvariant() |
        Should -BeExactly ([RepositorySyncFixture]::ContentHash(4096))
    }

    It '[T7] recovers after a request fault and a mid-body stream fault' {
      $Key = 'Retry/two-stages.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$Key -Size:(2MB)))
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        $Length = [System.Int32]($Call.End - $Call.Start + 1)
        If ($Call.Attempt -eq 1) {
          [System.Threading.Tasks.Task]::FromException([System.IO.IOException]::new('fake request fault'))
        } ElseIf ($Call.Attempt -eq 2) {
          [RepositorySyncFixture]::PartTask(
            $Call,
            $Length,
            [RepositorySyncFaultStream]::new([RepositorySyncFixture]::ContentBytes($Length, 0), 1MB),
            $Null
          )
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Retry = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001)
      $Retry | Should -HaveCount 2
      $Retry[0].Message | Should -BeLike "*$Key*bytes=0-2097151*request*attempt 2*"
      $Retry[1].Message | Should -BeLike "*$Key*bytes=0-2097151*body*attempt 3*"
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:(Join-Path -Path:$Script:Repository -ChildPath:$Key)).Hash.ToLowerInvariant() |
        Should -BeExactly ([RepositorySyncFixture]::ContentHash(2MB))
    }

    It '[T8] exhausts one part while another object completes and preserves a stale destination' {
      $FailedKey = 'Failure/exhausted.bin'
      $OtherKey = 'Failure/completes.bin'
      $FailedSize = 8MB + 1
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$FailedKey -Size:$FailedSize),
        (New-S3Entry -Key:$OtherKey -Size:1024)
      )
      $FailedLocal = Set-LocalCopy -Key:$FailedKey -Size:$FailedSize -Written:([System.DateTime]::UtcNow.AddDays(-7))
      $BeforeHash = (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$FailedLocal).Hash
      $BeforeTime = (Get-Item -LiteralPath:$FailedLocal).LastWriteTimeUtc
      $Temp = $FailedLocal + '.sync-part'
      $Global:RepositorySyncTestState = [PSCustomObject]@{
        SiblingOwner  = $Null
        SiblingSource = $Null
      }
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        If ($Call.Key -eq $FailedKey -and $Call.Start -eq 0) {
          If ($Call.Attempt -eq 5) {
            [void]$Global:RepositorySyncTestState.SiblingSource.SetResult(
              [System.Object]$Global:RepositorySyncTestState.SiblingOwner
            )
          }
          [RepositorySyncFixture]::PartTask(
            $Call,
            1,
            [System.IO.MemoryStream]::new([System.Byte[]]::new(1), $False),
            $Null
          )
        } ElseIf ($Call.Key -eq $FailedKey) {
          If ($Null -eq $Global:RepositorySyncTestState.SiblingSource) {
            $Length = [System.Int32]($Call.End - $Call.Start + 1)
            $ObservePath = [System.String]$Temp
            $Global:RepositorySyncTestState.SiblingOwner = [RepositorySyncOwner]::new(
              $Length,
              [System.IO.MemoryStream]::new([RepositorySyncFixture]::ContentBytes($Length, $Call.Start), $False),
              $Call,
              { [System.IO.File]::Exists($ObservePath) }.GetNewClosure()
            )
            $Global:RepositorySyncTestState.SiblingSource = [System.Threading.Tasks.TaskCompletionSource[System.Object]]::new()
          }
          $Global:RepositorySyncTestState.SiblingSource.Task
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      $Thrown = { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -PassThru
      $Thrown.Exception.Message | Should -BeLike "*$FailedKey*response length 1, expected 8388608*5 attempts exhausted*"
      (Join-Path -Path:$Script:Repository -ChildPath:$OtherKey) | Should -Exist
      $Temp | Should -Not -Exist
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$FailedLocal).Hash | Should -BeExactly $BeforeHash
      (Get-Item -LiteralPath:$FailedLocal).LastWriteTimeUtc | Should -BeExactly $BeforeTime
      $FailedCalls = @($Global:RepositorySyncCalls | Where-Object -Property:'Key' -EQ -Value:$FailedKey |
          Where-Object -Property:'Start' -EQ -Value:0)
      $FailedCalls | Should -HaveCount 5
      $Nominal = @(2, 4, 8, 16)
      For ($GapIndex = 0; $GapIndex -lt 4; $GapIndex++) {
        $Gap = ($FailedCalls[$GapIndex + 1].Time - $FailedCalls[$GapIndex].Time).TotalSeconds
        $Gap | Should -BeGreaterOrEqual ($Nominal[$GapIndex] - 0.1)
        $Gap | Should -BeLessThan ($Nominal[$GapIndex] + 3)
      }
      $Retries = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001 |
          Where-Object -Property:'Message' -Like -Value:"*$FailedKey*")
      $Retries | Should -HaveCount 4
      $Retries.Message | Should -BeLike '*request*'
      @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1002) | Should -HaveCount 1
      @($Global:RepositorySyncDisposals | Where-Object -Property:'ObservePathExists' -EQ -Value:$True) |
        Should -HaveCount 1
    }

    It '[T9] classifies status-code and error-code 412 exception chains without retrying' {
      $StatusKey = 'Precondition/status.bin'
      $CodeKey = 'Precondition/code.bin'
      $OtherKey = 'Precondition/completes.bin'
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$StatusKey),
        (New-S3Entry -Key:$CodeKey),
        (New-S3Entry -Key:$OtherKey)
      )
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        If ($Call.Key -eq $StatusKey) {
          $Inner = [System.Exception]::new('status-bearing exception')
          $Inner | Add-Member -Force -MemberType:'NoteProperty' -Name:'StatusCode' -Value:([System.Net.HttpStatusCode]::PreconditionFailed)
          [System.Threading.Tasks.Task]::FromException([System.Exception]::new('outer status wrapper', $Inner))
        } ElseIf ($Call.Key -eq $CodeKey) {
          $Inner = [System.Exception]::new('code-bearing exception')
          $Inner | Add-Member -Force -MemberType:'NoteProperty' -Name:'ErrorCode' -Value:'PreconditionFailed'
          [System.Threading.Tasks.Task]::FromException([System.Exception]::new('outer code wrapper', $Inner))
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      $Thrown = { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -PassThru
      $Thrown.Exception.Message | Should -BeLike "*$StatusKey*PreconditionFailed*status-bearing exception*"
      $Thrown.Exception.Message | Should -BeLike "*$CodeKey*PreconditionFailed*code-bearing exception*"
      @($Global:RepositorySyncCalls | Where-Object -Property:'Key' -EQ -Value:$StatusKey) | Should -HaveCount 1
      @($Global:RepositorySyncCalls | Where-Object -Property:'Key' -EQ -Value:$CodeKey) | Should -HaveCount 1
      @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001) | Should -HaveCount 0
      (Join-Path -Path:$Script:Repository -ChildPath:$OtherKey) | Should -Exist
    }

    It '[T10] reports promotion and precondition failures together' {
      $PromotionKey = 'Combined/promotion.bin'
      $PreconditionKey = 'Combined/precondition.bin'
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$PromotionKey),
        (New-S3Entry -Key:$PreconditionKey)
      )
      $PromotionLocal = Set-LocalCopy -Key:$PromotionKey -Written:([System.DateTime]::UtcNow.AddDays(-7))
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        If ($Call.Key -eq $PromotionKey) {
          Remove-Item -Force -LiteralPath:$PromotionLocal
          [void](New-Item -ItemType:'Directory' -Path:$PromotionLocal)
          [RepositorySyncFixture]::DefaultPartTask($Call)
        } Else {
          $Inner = [System.Exception]::new('object replaced during listing')
          $Inner | Add-Member -Force -MemberType:'NoteProperty' -Name:'StatusCode' -Value:([System.Net.HttpStatusCode]::PreconditionFailed)
          [System.Threading.Tasks.Task]::FromException([System.Exception]::new('outer wrapper', $Inner))
        }
      }
      [void](New-AnsibleContext)
      $Thrown = { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -PassThru
      $Thrown.Exception.Message | Should -BeLike "*$PromotionKey*promotion failed*"
      $Thrown.Exception.Message | Should -BeLike "*$PreconditionKey*PreconditionFailed*"
    }

    It '[T11] disposes every received owner exactly once across all completion paths' {
      $SuccessKey = 'Ownership/success.bin'
      $LengthKey = 'Ownership/length.bin'
      $CopyKey = 'Ownership/copy.bin'
      $SiblingKey = 'Ownership/sibling-412.bin'
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$SuccessKey -Size:1024),
        (New-S3Entry -Key:$LengthKey -Size:1024),
        (New-S3Entry -Key:$CopyKey -Size:(2MB)),
        (New-S3Entry -Key:$SiblingKey -Size:(8MB + 1))
      )
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        $Length = [System.Int32]($Call.End - $Call.Start + 1)
        If ($Call.Key -eq $LengthKey -and $Call.Attempt -eq 1) {
          [RepositorySyncFixture]::PartTask(
            $Call,
            1,
            [System.IO.MemoryStream]::new([System.Byte[]]::new(1), $False),
            $Null
          )
        } ElseIf ($Call.Key -eq $CopyKey -and $Call.Attempt -eq 1) {
          [RepositorySyncFixture]::PartTask(
            $Call,
            $Length,
            [RepositorySyncFaultStream]::new([RepositorySyncFixture]::ContentBytes($Length, 0), 1MB),
            $Null
          )
        } ElseIf ($Call.Key -eq $SiblingKey -and $Call.Start -eq 0) {
          $Inner = [System.Exception]::new('sibling object changed')
          $Inner | Add-Member -Force -MemberType:'NoteProperty' -Name:'ErrorCode' -Value:'PreconditionFailed'
          [System.Threading.Tasks.Task]::FromException([System.Exception]::new('outer sibling wrapper', $Inner))
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } | Should -Throw
      $Global:RepositorySyncDisposals.Count | Should -Be $Global:RepositorySyncOwnerNumber
      @($Global:RepositorySyncDisposals.Id | Select-Object -Unique) | Should -HaveCount $Global:RepositorySyncOwnerNumber
      @($Global:RepositorySyncCalls | Where-Object -Property:'Key' -EQ -Value:$SiblingKey) | Should -HaveCount 2
    }

    It '[T11b] retries a synchronous fetcher throw without inventing an owner' {
      $Key = 'Ownership/synchronous-throw.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$Key -Size:1024))
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        If ($Call.Attempt -eq 1) {
          Throw ([System.IO.IOException]::new('fake synchronous fetcher throw'))
        }
        [RepositorySyncFixture]::DefaultPartTask($Call)
      }
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Global:RepositorySyncOwnerNumber | Should -Be 1
      $Global:RepositorySyncDisposals | Should -HaveCount 1
      $Retry = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001 |
          Where-Object -Property:'Message' -Like -Value:"*$Key*")
      $Retry | Should -HaveCount 1
      $Retry[0].Message | Should -BeLike '*request*attempt 2*'
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:(Join-Path -Path:$Script:Repository -ChildPath:$Key)).Hash.ToLowerInvariant() |
        Should -BeExactly ([RepositorySyncFixture]::ContentHash(1024))
    }
  }

  Context 'promotion and reporting invariants' {

    It '[T12] preserves LastModified after both move and replacement promotion' {
      $MoveKey = 'Timestamp/move.bin'
      $ReplaceKey = 'Timestamp/replace.bin'
      $MoveTime = [System.DateTime]::new(2024, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
      $ReplaceTime = [System.DateTime]::new(2024, 2, 3, 4, 5, 6, [System.DateTimeKind]::Utc)
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$MoveKey -Modified:$MoveTime),
        (New-S3Entry -Key:$ReplaceKey -Modified:$ReplaceTime)
      )
      [void](Set-LocalCopy -Key:$ReplaceKey -Written:([System.DateTime]::new(2023, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)))
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      (Get-Item -LiteralPath:(Join-Path -Path:$Script:Repository -ChildPath:$MoveKey)).LastWriteTimeUtc |
        Should -BeExactly $MoveTime
      (Get-Item -LiteralPath:(Join-Path -Path:$Script:Repository -ChildPath:$ReplaceKey)).LastWriteTimeUtc |
        Should -BeExactly $ReplaceTime
    }

    It '[T14] skips archived objects honestly and still downloads GLACIER_IR' {
      $AbsentKey = 'Archive/absent.bin'
      $StaleKey = 'Archive/stale.bin'
      $CurrentKey = 'Archive/current.bin'
      $InstantKey = 'Archive/instant.bin'
      $CurrentTime = [System.DateTime]::UtcNow.AddDays(-1)
      $AbsentLocal = Join-Path -Path:$Script:Repository -ChildPath:$AbsentKey
      $StaleLocal = Set-LocalCopy -Key:$StaleKey -Size:3 -Written:([System.DateTime]::UtcNow.AddDays(-7))
      [System.IO.File]::WriteAllBytes($StaleLocal, [System.Byte[]]@(1, 2, 3))
      $CurrentLocal = Set-LocalCopy -Key:$CurrentKey -Size:4 -Written:$CurrentTime
      [System.IO.File]::WriteAllBytes($CurrentLocal, [System.Byte[]]@(4, 3, 2, 1))
      $StaleHash = (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$StaleLocal).Hash
      $CurrentHash = (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$CurrentLocal).Hash
      $StandardKey = 'Archive/standard-current.bin'
      [void](Set-LocalCopy -Key:$StandardKey -Size:5 -Written:$CurrentTime)
      Set-FakeBucket -Entry:@(
        (New-S3Entry -Key:$AbsentKey -Size:2 -StorageClass:'GLACIER'),
        (New-S3Entry -Key:$StaleKey -Size:9 -StorageClass:'DEEP_ARCHIVE'),
        (New-S3Entry -Key:$CurrentKey -Modified:$CurrentTime -Size:4 -StorageClass:'GLACIER'),
        (New-S3Entry -Key:$InstantKey -Size:6 -StorageClass:'GLACIER_IR'),
        (New-S3Entry -Key:$StandardKey -Modified:$CurrentTime -Size:5)
      )
      $First = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $First.Result.skipped | Should -Be 3
      $First.Result.changed | Should -BeTrue
      $First.Result.msg | Should -BeLike '*1 of 5*object(s) fetched*; 3 archived object(s) skipped'
      @($Global:RepositorySyncCalls).Key | Should -BeExactly @($InstantKey)
      $AbsentLocal | Should -Not -Exist
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$StaleLocal).Hash | Should -BeExactly $StaleHash
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$CurrentLocal).Hash | Should -BeExactly $CurrentHash
      @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1003) | Should -HaveCount 3

      $Global:RepositorySyncCalls.Clear()
      $Global:RepositorySyncEventLog.Clear()
      $Second = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Second.Result.changed | Should -BeFalse
      $Second.Result.msg | Should -BeLike '2 object(s) already current*; 3 archived object(s) skipped'
      $Global:RepositorySyncCalls | Should -HaveCount 0
      $AbsentLocal | Should -Not -Exist
      @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1003) | Should -HaveCount 3

      $ArchiveRepository = Join-Path -Path:$Script:Sandbox -ChildPath:'ArchiveOnly'
      [void](New-Item -ItemType:'Directory' -Path:$ArchiveRepository)
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$AbsentKey -Size:2 -StorageClass:'GLACIER'))
      $ArchiveOnly = New-AnsibleContext
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$ArchiveRepository -Region:$Script:Region
      $ArchiveOnly.Result.changed | Should -BeFalse
      $ArchiveOnly.Result.msg | Should -BeLike '0 object(s) already current*; 1 archived object(s) skipped'
      (Join-Path -Path:$ArchiveRepository -ChildPath:$AbsentKey) | Should -Not -Exist
    }

    It '[T15] reports the complete plan without touching the repository in dry run' {
      $FirstKey = 'Dry/first.bin'
      $SecondKey = 'Dry/Nested/second.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$FirstKey), (New-S3Entry -Key:$SecondKey))
      $Rogue = Join-Path -Path:$Script:Repository -ChildPath:'rogue.txt'
      Set-Content -LiteralPath:$Rogue -Value:'keep during dry run'
      $BeforeHash = (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$Rogue).Hash
      $Ctx = New-AnsibleContext -CheckMode
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Global:RepositorySyncCalls | Should -HaveCount 0
      (Join-Path -Path:$Script:Repository -ChildPath:$FirstKey) | Should -Not -Exist
      (Join-Path -Path:$Script:Repository -ChildPath:'Dry') | Should -Not -Exist
      $Rogue | Should -Exist
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$Rogue).Hash | Should -BeExactly $BeforeHash
      $Ctx.Result.changed | Should -BeTrue
      $Ctx.Result.check_mode | Should -BeTrue
      $Ctx.Result.fetched | Should -BeExactly @($FirstKey, $SecondKey)
      $Ctx.Result.msg | Should -BeLike '*2 of 2 object(s) fetched*1 local file(s) removed*'
      $Success = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1000)
      ($Success[0].Message | ConvertFrom-Json).fetched | Should -Be 2
    }

    It '[T16] removes a killed-run temp and fetches its object' {
      $Key = 'Recovery/leftover.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$Key -Size:1024))
      $Local = Join-Path -Path:$Script:Repository -ChildPath:$Key
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$Local -Parent) -Force)
      $Temp = $Local + '.sync-part'
      Set-Content -LiteralPath:$Temp -Value:'killed run'
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Temp | Should -Not -Exist
      $Local | Should -Exist
      $Global:RepositorySyncCalls | Should -HaveCount 1
    }
  }

  Context 'local part failures' {

    It '[T18] isolates repeated temp-creation failures while another object completes' {
      $FailedKey = 'LocalFailure/cannot-create.bin'
      $OtherKey = 'LocalFailure/completes.bin'
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$FailedKey), (New-S3Entry -Key:$OtherKey))
      $FailedLocal = Join-Path -Path:$Script:Repository -ChildPath:$FailedKey
      [void](New-Item -ItemType:'Directory' -Path:(Split-Path -Path:$FailedLocal -Parent) -Force)
      [void](New-Item -ItemType:'Directory' -Path:($FailedLocal + '.sync-part'))
      [void](New-AnsibleContext)
      $Thrown = { & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region } |
        Should -Throw -PassThru
      $Thrown.Exception.Message | Should -BeLike "*$FailedKey*5 attempts exhausted*"
      $Thrown.Exception.Message | Should -Not -BeLike "*$OtherKey*"
      (Join-Path -Path:$Script:Repository -ChildPath:$OtherKey) | Should -Exist
      @($Global:RepositorySyncCalls | Where-Object -Property:'Key' -EQ -Value:$FailedKey) | Should -HaveCount 0
      $Retries = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001 |
          Where-Object -Property:'Message' -Like -Value:"*$FailedKey*")
      $Retries | Should -HaveCount 4
      $Retries.Message | Should -BeLike '*local*'
    }

    It '[T18b] retries a locked pre-sized temp after disposing its owner once' {
      $LockedKey = 'LocalFailure/locked.bin'
      $OtherKey = 'LocalFailure/other.bin'
      $Size = 4096
      Set-FakeBucket -Entry:@((New-S3Entry -Key:$LockedKey -Size:$Size), (New-S3Entry -Key:$OtherKey))
      $Local = Join-Path -Path:$Script:Repository -ChildPath:$LockedKey
      $Temp = $Local + '.sync-part'
      $Global:RepositorySyncBehavior = {
        $Call = $Global:RepositorySyncCurrentCall
        If ($Call.Key -eq $LockedKey -and $Call.Attempt -eq 1) {
          $Temp | Should -Exist
          (Get-Item -LiteralPath:$Temp).Length | Should -Be $Size
          $Lock = [System.IO.FileStream]::new(
            $Temp,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete)
          )
          $Held = $Temp + '.held'
          $RestorePath = [System.String]$Temp
          [System.IO.File]::Move($Temp, $Held)
          [void](New-Item -ItemType:'Directory' -Path:$Temp)
          $OnDispose = {
            $Lock.Dispose()
            Remove-Item -Force -LiteralPath:$RestorePath
            [System.IO.File]::Move($Held, $RestorePath)
            $False
          }.GetNewClosure()
          [RepositorySyncFixture]::PartTask(
            $Call,
            $Size,
            [System.IO.MemoryStream]::new([RepositorySyncFixture]::ContentBytes($Size, 0), $False),
            $OnDispose
          )
        } Else {
          [RepositorySyncFixture]::DefaultPartTask($Call)
        }
      }
      [void](New-AnsibleContext)
      & $Script:ScriptPath -Bucket:$Script:Bucket -Path:$Script:Repository -Region:$Script:Region
      $Retries = @($Global:RepositorySyncEventLog | Where-Object -Property:'EventId' -EQ -Value:1001 |
          Where-Object -Property:'Message' -Like -Value:"*$LockedKey*")
      $Retries | Should -HaveCount 1
      $Retries[0].Message | Should -BeLike '*local*attempt 2*'
      @($Global:RepositorySyncDisposals.Id | Group-Object | Where-Object -Property:'Count' -NE -Value:1) |
        Should -HaveCount 0
      (Get-FileHash -Algorithm:'SHA256' -LiteralPath:$Local).Hash.ToLowerInvariant() |
        Should -BeExactly ([RepositorySyncFixture]::ContentHash($Size))
      (Join-Path -Path:$Script:Repository -ChildPath:$OtherKey) | Should -Exist
    }
  }
}
