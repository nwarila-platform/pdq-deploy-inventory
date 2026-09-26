#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Mirrors the application repository from S3 onto the local repository volume.

.DESCRIPTION
    The repository is the host's copy of the application repository bucket: the installers PDQ
    deploys and the installers PDQ runs are the same kind of object, so they come from the same
    place. The host reads the bucket itself rather than being handed each file, because the
    repository is measured in gigabytes and a deployment runner is the wrong thing to push that
    through.

    The mirror is DETERMINISTIC: after a run, the volume holds what the bucket holds and nothing
    else. A local file with no object behind it is removed, because the bucket is the only place
    that decides what the repository contains. Rollback lives in the bucket, where a superseded
    version stays addressable until it is pruned there -- not in whatever happens to be left on
    a particular volume.

    That is what makes this repeatable. A volume that accumulated local-only files would drift
    away from every other host running the same deployment, and the drift would be invisible
    until something read a file that only existed in one place. The deployment role publishes to
    the bucket and then runs this, so anything that reaches a target has been through the bucket.

    An object is fetched when the local copy is absent, a different size, or older than the object
    -- the comparison the vendor's own sync makes. A converge that finds the repository already
    current fetches nothing, removes nothing, and reports no change, so this can run on every
    deployment.
    Object fetches use parallel 8 MiB ranged requests, with up to ten requests in flight.

    Nothing here carries a credential: the host reads the bucket through the instance profile it
    was launched with.

    The bucket is listed through AWS.Tools.S3 where the host has it, and otherwise through
    AWSPowerShell, the monolithic module stock Windows Server 2019 carries instead; Get-S3Object
    takes the same parameters in both. Object bodies are downloaded through the SDK client the
    selected module provides. With neither installed, the run fails naming both.

.PARAMETER Bucket
    The application repository bucket, without a scheme or prefix.

.PARAMETER DebugLevel
    Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

.PARAMETER LogLevel
    Six digits, one per stream, in the order the LOG_LEVELS table names them.

.PARAMETER PartFetcher
    Hidden seam that starts one part request for the spec.

.PARAMETER Path
    The local repository directory the bucket is mirrored into.

.PARAMETER Region
    The region the bucket lives in.

.OUTPUTS
    One object carrying changed, check_mode, bucket, path, fetched, removed, skipped, swept,
    present and msg. Run outside the module, it is written as one line of JSON.
#>

[CmdletBinding(
  ConfirmImpact = 'Medium',
  DefaultParameterSetName = 'default',
  HelpUri = 'https://github.com/nwarila-platform/pdq-deploy-inventory',
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
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Bucket,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(
    DontShow = $True,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNull()]
  [System.Management.Automation.ScriptBlock]
  $PartFetcher,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Path,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Region
)
#region ------ [ Script ] ------------------------------------------------------------------- #

#region ------ [ Initialization ] ----------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Initialization'

# Every user-facing message, in one table. Declared before anything that can fail, because the
# trap below reports every failure through it.
[System.String]$Script:EventLogName = 'Application'
[System.String]$Script:EventSource = 'PDQ Repository Sync'
[System.Collections.Hashtable]$Script:Message = @{
  'Set-RepositoryContent.ArchiveSkipped'   = 'Skipping {0}: storage class {1} must be restored before it can be downloaded.'
  'Set-RepositoryContent.ArchiveSummary'   = '; {0} archived object(s) skipped'
  'Set-RepositoryContent.Changed'          = '{0} of {1} object(s) fetched from {2}, {3} local file(s) removed'
  'Set-RepositoryContent.Current'          = '{0} object(s) already current from {1}'
  'Set-RepositoryContent.Failure'          = '[{0:0000}] {1} [{2}]'
  'Set-RepositoryContent.FetchFailed'      = 'Object download failed: {0}'
  'Set-RepositoryContent.FetchFailedItem'  = '{0}: {1}'
  'Set-RepositoryContent.FetchRetry'       = 'Fetching {0} ({1}) failed during {2} ({3}); attempt {4} of 5 follows.'
  'Set-RepositoryContent.KeyOutsideRoot'   = 'The key {0} resolves outside the repository: {1}'
  'Set-RepositoryContent.NoS3Module'       = 'Neither AWS.Tools.S3 nor AWSPowerShell is installed, and the bucket is read through one of them.'
  'Set-RepositoryContent.PartCleanup'      = '{0}; deleting the temporary file also failed: {1}'
  'Set-RepositoryContent.PartCopied'       = 'copied {0} byte(s), expected {1}'
  'Set-RepositoryContent.PartExhausted'    = '{0}: {1} (5 attempts exhausted)'
  'Set-RepositoryContent.PartLength'       = 'response length {0}, expected {1}'
  'Set-RepositoryContent.PartPrecondition' = '{0}: object changed since listing (HTTP 412 PreconditionFailed): {1}'
  'Set-RepositoryContent.PromotionFailed'  = 'promotion failed: {0}'
  'Set-RepositoryContent.ReparsePoint'     = 'The repository holds a reparse point: {0}. Remove it before syncing.'
  'Set-RepositoryContent.VolumeNotMounted' = 'The repository directory is not there: {0}. The volume holding it is not mounted.'
}

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. This script decides check mode from $Ansible.CheckMode, so -WhatIf is
# neutralised here; left on, it would suppress the Set-Variable setup below.
#
# It is captured first. A person running this directly reaches for -WhatIf expecting it to mean
# change nothing, and this script deletes files -- so the request is honoured below rather than
# discarded with the preference.
[System.Boolean]$Private:RequestedWhatIf = [System.Boolean]$WhatIfPreference
$WhatIfPreference = $False

# Log level names, by LogLevel digit position.
[System.String[]]$Private:LOG_LEVELS = [System.String[]]@(
  'Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal'
)

# An S3 key always separates with '/'. Translating to the platform's own separator is what lets
# this script's spec run on the Linux CI leg as well as on the host it deploys to.
[System.String]$Private:PATH_SEPARATOR = [System.String][System.IO.Path]::DirectorySeparatorChar
[System.Int64]$Private:PART_SIZE = 8MB
[System.Int32]$Private:TRANSFER_CONCURRENCY = 10

# Configure log levels based on the LogLevel parameter.
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

# Debug digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse($DebugLevel.Substring(0, 1))
Switch ($DebugLevel.Substring(1, 1)) {
  '0' { Set-PSDebug -Off }
  '1' { Set-PSDebug -Trace:1 }
  '2' { Set-PSDebug -Trace:2 }
  '3' { Set-PSDebug -Trace:1 -Step }
  '4' { Set-PSDebug -Trace:2 -Step }
}
If ($DebugLevel.Substring(2, 1) -eq '0') {
  Set-StrictMode -Off
} Else {
  Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1))
}

# Universal trap: log diagnostics, rethrow so the task fails honestly. The warning comes first
# and reads only the failing record, so no diagnostic after it can silence it: a background
# run's Error event is the durable place its cause is kept. An error PowerShell raises itself -- a Throw,
# a provider error -- carries no inner invocation, so the diagnostic reads one only where it
# exists. Wrapped so a partial error record can never replace the original failure with a
# StrictMode property error.
Trap {
  Try {
    [System.String]$Private:Failure = $Script:Message['Set-RepositoryContent.Failure'] -f @(
      [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
      [System.String]$PSItem.Exception.Message
      [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
    )
    Write-Warning -Message:$Failure
    [void](Write-EventLog -EntryType:'Error' -EventId:1002 -LogName:$Script:EventLogName -Message:$Failure -Source:$Script:EventSource)
    If (
      $PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord' -and
      $Null -ne $PSItem.Exception.ErrorRecord.InvocationInfo
    ) {
      Write-Debug -Message:(
        'Failed to execute command: {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
      )
    }
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }

  Break
}

# Standalone (a dev shell or spec) has no transport-provided $Ansible; stub it faithfully.
[System.Boolean]$Private:StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  [PSCustomObject]$Private:Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

#endregion --- [ Initialization ] ----------------------------------------------------------- #

#region ------ [ Main ] --------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# Initialize Variable(s)
[System.Boolean]$Private:Changed = $False
[System.Object]$Private:Client = $Null
[System.Object[]]$Private:Content = @()
[System.String]$Private:Current = [System.String]::Empty
[System.Int32]$Private:CurrentCount = 0
[System.Collections.Generic.List[System.String]]$Private:Directories = [System.Collections.Generic.List[System.String]]::new()
[System.Boolean]$Private:DryRun = $False
[System.IO.FileSystemInfo]$Private:Existing = $Null
[System.Collections.Generic.List[System.String]]$Private:Fetched = [System.Collections.Generic.List[System.String]]::new()
# Everything the bucket says this volume should hold. Compared case-insensitively because the
# filesystem is: two keys differing only in case cannot both exist here, and treating them as
# distinct would delete whichever arrived second on every run.
[System.Collections.Generic.HashSet[System.String]]$Private:Expected = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
[System.Boolean]$Private:IsCurrent = $False
[System.String]$Private:LocalPath = [System.String]::Empty
[System.Object[]]$Private:Objects = @()
[System.String]$Private:Parent = [System.String]::Empty
[System.Collections.Generic.List[System.Object]]$Private:Pending = [System.Collections.Generic.List[System.Object]]::new()
[System.Object[]]$Private:Refilled = @()
[System.Object[]]$Private:Remaining = @()
[System.Collections.Generic.List[System.String]]$Private:Removable = [System.Collections.Generic.List[System.String]]::new()
[PSCustomObject]$Private:Result = $Null
[System.String]$Private:Root = [System.String]::Empty
[System.Collections.Generic.List[System.String]]$Private:Skipped = [System.Collections.Generic.List[System.String]]::new()
[System.String]$Private:StorageClass = [System.String]::Empty
[System.String]$Private:Summary = [System.String]::Empty
[System.Collections.Generic.List[System.String]]$Private:Surplus = [System.Collections.Generic.List[System.String]]::new()
[System.Collections.Generic.Stack[System.String]]$Private:Unvisited = [System.Collections.Generic.Stack[System.String]]::new()

If (Get-Module -ListAvailable -Name:'AWS.Tools.S3') {
  Import-Module -Name:'AWS.Tools.S3' -ErrorAction:'Stop'
} ElseIf (Get-Module -ListAvailable -Name:'AWSPowerShell') {
  Import-Module -Name:'AWSPowerShell' -ErrorAction:'Stop'
} Else {
  Throw ($Script:Message['Set-RepositoryContent.NoS3Module'])
}

# Set before the first S3 call: .NET Framework otherwise fixes the service point at its default
# of two connections, while the ranged download runs ten parts at once.
[System.Net.ServicePointManager]::DefaultConnectionLimit = $TRANSFER_CONCURRENCY

# The repository lives on a volume of its own, so a missing directory means that volume is not
# mounted. Filling the same path on the system disk instead would hide the fault behind a drive
# that silently fills up.
If (-not (Test-Path -LiteralPath:$Path -PathType:'Container')) {
  Throw ($Script:Message['Set-RepositoryContent.VolumeNotMounted'] -f $Path)
}

$Objects = @(Get-S3Object -BucketName:$Bucket -Region:$Region)

# A key ending in '/' is the console's way of drawing a folder. It carries no content, and the
# directories are made below from the keys that do.
$Content = @($Objects | Where-Object -FilterScript:({ -not $PSItem.Key.EndsWith('/') }))

# Resolved once, so every comparison below is against one spelling of the root. The joined paths
# are canonicalised individually too; both are needed for a path the caller did not normalise.
$Root = (Get-Item -LiteralPath:$Path -ErrorAction:'Stop').FullName

ForEach ($Object In $Content) {
  # GetFullPath collapses what the filesystem collapses. A key carrying '//', '/./' or '/../'
  # names a file the filesystem will call something shorter, and holding the longer spelling here
  # would mark the bucket's own object surplus on the next run -- deleting it, refetching it, and
  # never converging. Key-building code that interpolates a prefix produces exactly that.
  $LocalPath = [System.IO.Path]::GetFullPath(
    (Join-Path -Path:$Root -ChildPath:($Object.Key.Replace('/', $PATH_SEPARATOR)))
  )

  # Collapsing '/../' can land outside the repository entirely. This script is the one place a
  # key from the bucket becomes a local path, so containment is checked here or nowhere: a key
  # that escapes would be written beside the volume, as the account a deployment runs as, and
  # never seen again by a sync that only looks inside the root.
  If (-not $LocalPath.StartsWith($Root + $PATH_SEPARATOR, [System.StringComparison]::OrdinalIgnoreCase)) {
    Throw ($Script:Message['Set-RepositoryContent.KeyOutsideRoot'] -f $Object.Key, $LocalPath)
  }

  [void]$Expected.Add($LocalPath)
  $StorageClass = [System.String]$Object.StorageClass
  If ($StorageClass -in @('GLACIER', 'DEEP_ARCHIVE')) {
    [void]$Skipped.Add([System.String]$Object.Key)
    [System.String]$Private:ArchiveSkipped = $Script:Message['Set-RepositoryContent.ArchiveSkipped'] -f
    $Object.Key, $StorageClass
    Write-Warning -Message:$ArchiveSkipped
    [void](Write-EventLog -EntryType:'Warning' -EventId:1003 -LogName:$Script:EventLogName -Message:$ArchiveSkipped -Source:$Script:EventSource)
    Continue
  }

  $Existing = Get-Item -LiteralPath:$LocalPath -ErrorAction:'SilentlyContinue'
  $IsCurrent = (
    $Null -ne $Existing -and
    $Existing.Length -eq $Object.Size -and
    $Existing.LastWriteTimeUtc -ge $Object.LastModified.ToUniversalTime()
  )
  If (-not $IsCurrent) {
    [void]$Pending.Add([PSCustomObject]@{
        ETag         = [System.String]$Object.ETag
        Key          = [System.String]$Object.Key
        LastModified = [System.DateTime]$Object.LastModified.ToUniversalTime()
        Local        = [System.String]$LocalPath
        Size         = [System.Int64]$Object.Size
      })
  }
}

# One descent, reading each directory before entering it. The guard and the enumeration are the
# same walk on purpose: separate passes let them disagree, and the first version of this checked
# only the top level while the enumeration recursed past that into anything deeper.
#
# A reparse point is refused rather than walked. Windows PowerShell follows directory junctions
# when it recurses, so one here would present files living on another volume as surplus and this
# script would delete them -- outside the repository, as the account a deployment runs as. Nothing
# in this role creates a junction, so finding one means something this lifecycle did not do, and
# stopping to name it is more use than guessing which side of the link was meant.
$Unvisited.Push($Root)

While ($Unvisited.Count -gt 0) {
  $Current = $Unvisited.Pop()
  ForEach ($Entry In @(Get-ChildItem -Force -LiteralPath:$Current -ErrorAction:'Stop')) {
    If ($Entry.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
      Throw ($Script:Message['Set-RepositoryContent.ReparsePoint'] -f $Entry.FullName)
    }
    If ($Entry.PSIsContainer) {
      [void]$Directories.Add([System.String]$Entry.FullName)
      $Unvisited.Push($Entry.FullName)
    } ElseIf (-not $Expected.Contains($Entry.FullName)) {
      [void]$Surplus.Add([System.String]$Entry.FullName)
    }
  }
}

# Directories emptied by this run or left by an earlier one. Counted into 'changed' because a
# run that removes one has changed the volume, and reporting otherwise makes the next reader
# trust a converged result that is not. A directory the fetch is about to fill is not one.
ForEach ($Directory In @($Directories | Sort-Object -Descending -Property:'Length')) {
  $Remaining = @(Get-ChildItem -Force -LiteralPath:$Directory -ErrorAction:'Stop' |
      Where-Object -FilterScript:({ $Surplus -notcontains $PSItem.FullName -and $Removable -notcontains $PSItem.FullName }))
  $Refilled = @($Pending | Where-Object -FilterScript:({
        $PSItem.Local.StartsWith($Directory + $PATH_SEPARATOR, [System.StringComparison]::OrdinalIgnoreCase)
      }))
  If (-not $Remaining -and -not $Refilled) {
    [void]$Removable.Add([System.String]$Directory)
  }
}

$Changed = [System.Boolean](($Pending.Count + $Surplus.Count + $Removable.Count) -gt 0)

# Either source of "change nothing": the module's check mode, or a -WhatIf a person typed.
$DryRun = [System.Boolean]($Ansible.CheckMode -or $RequestedWhatIf)

If ($DryRun) {
  ForEach ($Fetch In $Pending) {
    [void]$Fetched.Add([System.String]$Fetch.Key)
  }
}

If (-not $DryRun) {
  # Removal runs BEFORE the fetch. A surplus file sitting where a key needs a directory otherwise
  # wedges the host: creating the directory over it is a silent no-op, the fetch then fails, and
  # the file that caused it is never reached because the fetch threw first -- so every later run
  # fails the same way. Surplus and expected are disjoint by construction, so removing first is
  # equally safe, and it frees the volume of superseded installers before new ones arrive.
  ForEach ($Remove In $Surplus) {
    Remove-Item -Force -LiteralPath:$Remove -ErrorAction:'Stop'
  }

  If ($Pending.Count -gt 0) {
    # One FIFO holds every object's parts in listing order. A retry returns to its tail with a
    # ready-at time, so other ready work can use the ten transfer slots during its backoff.
    [System.Collections.Generic.Queue[System.Object]]$Private:PartQueue = [System.Collections.Generic.Queue[System.Object]]::new()
    [System.Collections.Generic.List[System.Object]]$Private:DownloadStates = [System.Collections.Generic.List[System.Object]]::new()
    ForEach ($Fetch In $Pending) {
      [System.Int32]$Private:PartCount = If ($Fetch.Size -eq 0) {
        1
      } Else {
        [System.Int32][System.Math]::Ceiling([System.Double]$Fetch.Size / [System.Double]$PART_SIZE)
      }
      [PSCustomObject]$Private:DownloadState = [PSCustomObject]@{
        Cause        = [System.String]::Empty
        Cleaned      = $False
        Created      = $False
        ETag         = [System.String]$Fetch.ETag
        Failed       = $False
        InFlight     = 0
        Key          = [System.String]$Fetch.Key
        LastModified = [System.DateTime]$Fetch.LastModified
        Local        = [System.String]$Fetch.Local
        Size         = [System.Int64]$Fetch.Size
        Succeeded    = 0
        Temp         = [System.String]($Fetch.Local + '.sync-part')
        Total        = [System.Int32]$PartCount
      }
      [void]$DownloadStates.Add($DownloadState)

      For ([System.Int32]$Private:PartIndex = 0; $PartIndex -lt $PartCount; $PartIndex++) {
        [System.Int64]$Private:PartStart = [System.Int64]$PartIndex * $PART_SIZE
        [System.Int64]$Private:PartEnd = If ($Fetch.Size -eq 0) {
          -1
        } Else {
          [System.Math]::Min([System.Int64]$Fetch.Size, $PartStart + $PART_SIZE) - 1
        }
        [System.Int64]$Private:PartLength = If ($Fetch.Size -eq 0) { 0 } Else { $PartEnd - $PartStart + 1 }
        [System.String]$Private:PartRange = If ($Fetch.Size -eq 0) {
          'unranged'
        } Else {
          'bytes={0}-{1}' -f $PartStart, $PartEnd
        }
        $PartQueue.Enqueue([PSCustomObject]@{
            Attempt  = 0
            End      = [System.Int64]$PartEnd
            Length   = [System.Int64]$PartLength
            Range    = [System.String]$PartRange
            ReadyAt  = [System.DateTime]::MinValue
            Start    = [System.Int64]$PartStart
            State    = $DownloadState
            Unranged = [System.Boolean]($Fetch.Size -eq 0)
          })
      }
    }

    # A failed request either makes its object terminal or goes back to the common queue. The
    # timestamp, rather than a sleep, provides the 2/4/8/16-second retry schedule.
    [ScriptBlock]$Private:FailPart = {
      Param (
        [Parameter(
          DontShow = $False,
          Mandatory = $True,
          ParameterSetName = 'default',
          ValueFromPipeline = $False,
          ValueFromPipelineByPropertyName = $False
        )]
        [System.Exception]
        $Failure,

        [Parameter(
          DontShow = $False,
          Mandatory = $True,
          ParameterSetName = 'default',
          ValueFromPipeline = $False,
          ValueFromPipelineByPropertyName = $False
        )]
        [System.Object]
        $FailedPart,

        [Parameter(
          DontShow = $False,
          Mandatory = $True,
          ParameterSetName = 'default',
          ValueFromPipeline = $False,
          ValueFromPipelineByPropertyName = $False
        )]
        [ValidateSet('body', 'local', 'request')]
        [System.String]
        $Stage
      )

      If ($FailedPart.State.Failed) { Return }

      [System.Exception]$Private:ClassifiedFailure = $Null
      [System.Exception]$Private:CurrentFailure = $Failure
      [System.Int32]$Private:StatusCode = 0
      [System.String]$Private:ErrorCode = [System.String]::Empty
      While ($Null -ne $CurrentFailure -and $Null -eq $ClassifiedFailure) {
        If (
          $CurrentFailure.PSObject.Properties.Name -contains 'StatusCode' -or
          $CurrentFailure.PSObject.Properties.Name -contains 'ErrorCode'
        ) {
          $ClassifiedFailure = $CurrentFailure
        } Else {
          $CurrentFailure = $CurrentFailure.InnerException
        }
      }
      [System.Exception]$Private:ReportedFailure = If ($Null -ne $ClassifiedFailure) {
        $ClassifiedFailure
      } Else {
        $Failure.GetBaseException()
      }
      If ($ReportedFailure.PSObject.Properties.Name -contains 'StatusCode') {
        $StatusCode = [System.Int32]$ReportedFailure.StatusCode
      }
      If ($ReportedFailure.PSObject.Properties.Name -contains 'ErrorCode') {
        $ErrorCode = [System.String]$ReportedFailure.ErrorCode
      }

      If (
        $StatusCode -eq [System.Int32][System.Net.HttpStatusCode]::PreconditionFailed -or
        $ErrorCode -eq 'PreconditionFailed'
      ) {
        $FailedPart.State.Failed = $True
        $FailedPart.State.Cause = $Script:Message['Set-RepositoryContent.PartPrecondition'] -f
        $FailedPart.Range, $ReportedFailure.Message
      } ElseIf ($FailedPart.Attempt -ge 5) {
        $FailedPart.State.Failed = $True
        $FailedPart.State.Cause = $Script:Message['Set-RepositoryContent.PartExhausted'] -f
        $FailedPart.Range, $ReportedFailure.Message
      } Else {
        [System.String]$Private:FetchRetry = $Script:Message['Set-RepositoryContent.FetchRetry'] -f
        $FailedPart.State.Key, $FailedPart.Range, $Stage, $ReportedFailure.Message, ($FailedPart.Attempt + 1)
        Write-Warning -Message:$FetchRetry
        [void](Write-EventLog -EntryType:'Warning' -EventId:1001 -LogName:$Script:EventLogName -Message:$FetchRetry -Source:$Script:EventSource)
        $FailedPart.ReadyAt = [System.DateTime]::UtcNow.AddSeconds(
          [System.Math]::Pow(2, [System.Double]$FailedPart.Attempt)
        )
        $PartQueue.Enqueue($FailedPart)
      }
    }

    # A failed object's file cannot be removed until its already-dispatched parts have closed
    # their streams. Remaining queued parts are discarded by the dispatcher below.
    [ScriptBlock]$Private:CleanFailed = {
      ForEach ($FailedState In $DownloadStates) {
        If ($FailedState.Failed -and $FailedState.InFlight -eq 0 -and -not $FailedState.Cleaned) {
          Try {
            If ([System.IO.File]::Exists($FailedState.Temp)) {
              Remove-Item -Force -LiteralPath:($FailedState.Temp) -ErrorAction:'Stop'
            }
          } Catch {
            $FailedState.Cause = $Script:Message['Set-RepositoryContent.PartCleanup'] -f
            $FailedState.Cause, $PSItem.Exception.Message
          }
          $FailedState.Cleaned = $True
        }
      }
    }

    [System.Collections.Generic.List[System.Object]]$Private:InFlight = [System.Collections.Generic.List[System.Object]]::new()
    [System.Collections.Generic.List[System.Threading.Tasks.Task]]$Private:WaitTasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    If ($Null -eq $PartFetcher) {
      $Client = [Amazon.S3.AmazonS3Client]::new([Amazon.RegionEndpoint]::GetBySystemName($Region))
    }
    Try {
      While ($PartQueue.Count -gt 0 -or $InFlight.Count -gt 0) {
        [System.DateTime]$Private:NextReady = [System.DateTime]::MaxValue
        [System.Int32]$Private:DispatchScan = $PartQueue.Count
        While ($InFlight.Count -lt $TRANSFER_CONCURRENCY -and $DispatchScan -gt 0) {
          [System.Object]$Private:Part = $PartQueue.Dequeue()
          $DispatchScan--
          If ($Part.State.Failed) { Continue }
          If ($Part.ReadyAt -gt [System.DateTime]::UtcNow) {
            If ($Part.ReadyAt -lt $NextReady) { $NextReady = $Part.ReadyAt }
            $PartQueue.Enqueue($Part)
            Continue
          }

          $Part.Attempt++
          [System.IO.FileStream]$Private:CreateStream = $Null
          [System.String]$Private:DispatchStage = 'local'
          Try {
            # Creation is deliberately coupled to the first dispatch, rather than queue setup.
            If (-not $Part.State.Created) {
              $Parent = Split-Path -Path:($Part.State.Local) -Parent
              If (-not (Test-Path -LiteralPath:$Parent -PathType:'Container')) {
                [void](New-Item -Force -ItemType:'Directory' -Path:$Parent)
              }
              $CreateStream = [System.IO.FileStream]::new(
                $Part.State.Temp,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
              )
              $CreateStream.SetLength([System.Int64]$Part.State.Size)
              $Part.State.Created = $True
            }

            $DispatchStage = 'request'
            [System.Threading.Tasks.Task]$Private:GetTask = If ($Null -ne $PartFetcher) {
              & $PartFetcher -Bucket:$Bucket -End:($Part.End) -ETag:($Part.State.ETag) -Key:($Part.State.Key) -Start:($Part.Start) -Unranged:($Part.Unranged)
            } Else {
              [Amazon.S3.Model.GetObjectRequest]$Private:GetRequest = [Amazon.S3.Model.GetObjectRequest]::new()
              $GetRequest.BucketName = $Bucket
              $GetRequest.Key = $Part.State.Key
              $GetRequest.EtagToMatch = $Part.State.ETag
              If (-not $Part.Unranged) {
                $GetRequest.ByteRange = [Amazon.S3.Model.ByteRange]::new($Part.Start, $Part.End)
              }
              $Client.GetObjectAsync($GetRequest)
            }
            $Part.State.InFlight++
            [void]$InFlight.Add([PSCustomObject]@{
                File     = $Null
                Part     = $Part
                Response = $Null
                Stage    = 'get'
                Task     = $GetTask
              })
          } Catch {
            [System.Exception]$Private:DispatchFailure = $PSItem.Exception
            . $FailPart -Failure:$DispatchFailure -FailedPart:$Part -Stage:$DispatchStage
          } Finally {
            If ($Null -ne $CreateStream) { $CreateStream.Dispose() }
          }
        }

        . $CleanFailed

        $WaitTasks.Clear()
        ForEach ($Transfer In $InFlight) {
          [void]$WaitTasks.Add([System.Threading.Tasks.Task]$Transfer.Task)
        }
        If ($InFlight.Count -lt $TRANSFER_CONCURRENCY -and $NextReady -ne [System.DateTime]::MaxValue) {
          [System.Int32]$Private:DelayMilliseconds = [System.Math]::Max(
            1,
            [System.Int32][System.Math]::Ceiling(($NextReady - [System.DateTime]::UtcNow).TotalMilliseconds)
          )
          [void]$WaitTasks.Add([System.Threading.Tasks.Task]::Delay($DelayMilliseconds))
        }
        If ($WaitTasks.Count -eq 0) { Continue }

        [System.Int32]$Private:CompletedIndex = [System.Threading.Tasks.Task]::WaitAny($WaitTasks.ToArray())
        If ($CompletedIndex -ge $InFlight.Count) { Continue }

        [System.Object]$Private:Completed = $InFlight[$CompletedIndex]
        [System.Exception]$Private:PartFailure = $Null
        If ($Completed.Stage -eq 'get') {
          [System.Object]$Private:PartResponse = $Null
          [System.IO.FileStream]$Private:PartFile = $Null
          [System.String]$Private:GetFailureStage = 'request'
          Try {
            $PartResponse = $Completed.Task.GetAwaiter().GetResult()
            If ([System.Int64]$PartResponse.ContentLength -ne [System.Int64]$Completed.Part.Length) {
              Throw ([System.IO.InvalidDataException]::new(
                  ($Script:Message['Set-RepositoryContent.PartLength'] -f $PartResponse.ContentLength, $Completed.Part.Length)
                ))
            }
            $GetFailureStage = 'local'
            $PartFile = [System.IO.FileStream]::new(
              $Completed.Part.State.Temp,
              [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Write,
              [System.IO.FileShare]::ReadWrite,
              1MB,
              $True
            )
            $PartFile.Position = $Completed.Part.Start
            $GetFailureStage = 'body'
            $Completed.Response = $PartResponse
            $Completed.File = $PartFile
            $Completed.Stage = 'copy'
            $Completed.Task = $PartResponse.ResponseStream.CopyToAsync($PartFile, 1MB)
            $PartResponse = $Null
            $PartFile = $Null
          } Catch {
            $PartFailure = $PSItem.Exception
          } Finally {
            If ($Null -ne $PartFile) { $PartFile.Dispose() }
            If ($Null -ne $PartResponse) { $PartResponse.Dispose() }
          }

          If ($Null -eq $PartFailure) { Continue }

          $Completed.Part.State.InFlight--
          $InFlight.RemoveAt($CompletedIndex)
          . $FailPart -Failure:$PartFailure -FailedPart:($Completed.Part) -Stage:$GetFailureStage
          . $CleanFailed
          Continue
        }

        [System.Int64]$Private:Copied = 0
        Try {
          [void]$Completed.Task.GetAwaiter().GetResult()
          $Copied = [System.Int64]$Completed.File.Position - [System.Int64]$Completed.Part.Start
          If ($Copied -ne [System.Int64]$Completed.Part.Length) {
            Throw ([System.IO.InvalidDataException]::new(
                ($Script:Message['Set-RepositoryContent.PartCopied'] -f $Copied, $Completed.Part.Length)
              ))
          }
        } Catch {
          $PartFailure = $PSItem.Exception
        } Finally {
          If ($Null -ne $Completed.File) { $Completed.File.Dispose() }
          If ($Null -ne $Completed.Response) { $Completed.Response.Dispose() }
        }

        $Completed.Part.State.InFlight--
        $InFlight.RemoveAt($CompletedIndex)
        If ($Null -ne $PartFailure) {
          . $FailPart -Failure:$PartFailure -FailedPart:($Completed.Part) -Stage:'body'
        } ElseIf (-not $Completed.Part.State.Failed) {
          $Completed.Part.State.Succeeded++
          If ($Completed.Part.State.Succeeded -eq $Completed.Part.State.Total) {
            Try {
              [System.IO.File]::SetLastWriteTimeUtc(
                $Completed.Part.State.Temp,
                [System.DateTime]$Completed.Part.State.LastModified
              )
              If ([System.IO.File]::Exists($Completed.Part.State.Local)) {
                [System.IO.File]::Replace(
                  $Completed.Part.State.Temp,
                  $Completed.Part.State.Local,
                  [System.Management.Automation.Language.NullString]::Value
                )
              } Else {
                [System.IO.File]::Move($Completed.Part.State.Temp, $Completed.Part.State.Local)
              }
              [void]$Fetched.Add([System.String]$Completed.Part.State.Key)
            } Catch {
              $Completed.Part.State.Failed = $True
              $Completed.Part.State.Cause = $Script:Message['Set-RepositoryContent.PromotionFailed'] -f
              $PSItem.Exception.Message
            }
          }
        }
        . $CleanFailed
      }
    } Finally {
      # Normal completions dispose at their stage boundary; this protects the same resources if
      # diagnostics or local I/O aborts the coordinator itself.
      ForEach ($Transfer In $InFlight) {
        If ($Null -ne $Transfer.File) { $Transfer.File.Dispose() }
        If ($Null -ne $Transfer.Response) { $Transfer.Response.Dispose() }
      }
      If ($Null -ne $Client) { $Client.Dispose() }
    }

    [System.Object[]]$Private:FailedStates = @($DownloadStates | Where-Object -FilterScript:({ $PSItem.Failed }))
    If ($FailedStates.Count -gt 0) {
      [System.String[]]$Private:FailedItems = @($FailedStates | ForEach-Object -Process:({
            $Script:Message['Set-RepositoryContent.FetchFailedItem'] -f $PSItem.Key, $PSItem.Cause
          }))
      Throw ($Script:Message['Set-RepositoryContent.FetchFailed'] -f ($FailedItems -join '; '))
    }
  }

  # Deepest-first, so a parent emptied by its own child's removal goes in the same pass. The
  # repository root is never a candidate: the walk starts inside it, and removing the mount point
  # would hide an unmounted volume behind the missing directory this script checks for first.
  ForEach ($Directory In @($Removable | Sort-Object -Descending -Property:'Length')) {
    Remove-Item -Force -LiteralPath:$Directory -ErrorAction:'Stop'
  }
}

#endregion --- [ Main ] --------------------------------------------------------------------- #

#region ------ [ Output ] ------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$CurrentCount = [System.Int32]($Content.Count - $Skipped.Count)
$Summary = If ($Changed) {
  $Script:Message['Set-RepositoryContent.Changed'] -f
  $Fetched.Count, $Content.Count, $Bucket, $Surplus.Count
} Else {
  $Script:Message['Set-RepositoryContent.Current'] -f $CurrentCount, $Bucket
}
If ($Skipped.Count -gt 0) {
  $Summary += $Script:Message['Set-RepositoryContent.ArchiveSummary'] -f $Skipped.Count
}

$Result = [PSCustomObject]@{
  bucket     = [System.String]$Bucket
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$DryRun
  fetched    = [System.String[]]@($Fetched)
  msg        = [System.String]$Summary
  path       = [System.String]$Path
  present    = [System.Int32]$Content.Count
  removed    = [System.String[]]@($Surplus)
  skipped    = [System.Int32]$Skipped.Count
  swept      = [System.String[]]@($Removable)
}

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

[void](Write-EventLog -EntryType:'Information' -EventId:1000 -LogName:$Script:EventLogName -Message:(
    [PSCustomObject]@{
      changed = [System.Boolean]$Result.changed
      fetched = [System.Int32]$Fetched.Count
      removed = [System.Int32]$Surplus.Count
      skipped = [System.Int32]$Skipped.Count
      swept   = [System.Int32]$Removable.Count
      present = [System.Int32]$Content.Count
    } | ConvertTo-Json -Compress
  ) -Source:$Script:EventSource)
# One line, so a standalone caller receives the whole result as one object.
If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4 -Compress
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] ------------------------------------------------------------------- #

#endregion --- [ Script ] ------------------------------------------------------------------- #
