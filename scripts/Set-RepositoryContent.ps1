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

    Nothing here carries a credential: the host reads the bucket through the instance profile it
    was launched with.

.PARAMETER Bucket
    The application repository bucket, without a scheme or prefix.

.PARAMETER DebugLevel
    Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

.PARAMETER LogLevel
    Six digits, one per stream, in the order the LOG_LEVELS table names them.

.PARAMETER Path
    The local repository directory the bucket is mirrored into.

.PARAMETER Region
    The region the bucket lives in.

.OUTPUTS
    One object carrying changed, check_mode, bucket, path, fetched, removed, swept, present and msg.
#>

[CmdletBinding(
  ConfirmImpact = 'Medium',
  DefaultParameterSetName = 'default',
  HelpUri = 'https://github.com/nwarila-platform/pdq-deploy-inventory',
  PositionalBinding = $False,
  SupportsPaging = $False,
  SupportsShouldProcess = $True
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

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. This script decides check mode from $Ansible.CheckMode, so -WhatIf is
# neutralised here; left on, it would suppress the New-Variable setup below.
#
# It is captured first. A person running this directly reaches for -WhatIf expecting it to mean
# change nothing, and this script deletes files -- so the request is honoured below rather than
# discarded with the preference.
$RequestedWhatIf = [System.Boolean]$WhatIfPreference
$WhatIfPreference = $false

# Log level names, by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# An S3 key always separates with '/'. Translating to the platform's own separator is what lets
# this script's spec run on the Linux CI leg as well as on the host it deploys to.
New-Variable -Force -Name:'PATH_SEPARATOR' -Option:('Private', 'ReadOnly') -Value:(
  [System.String][System.IO.Path]::DirectorySeparatorChar
)

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

# Universal trap: log diagnostics, rethrow so the task fails honestly. Wrapped so a partial
# error record can never replace the original failure with a StrictMode property error.
Trap {
  Try {
    If ($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') {
      Write-Debug -Message:(
        'Failed to execute command: {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
      )
    }
    Write-Warning -Message:(
      '[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      )
    )
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }

  Break
}

# Standalone (a dev shell or spec) has no transport-provided $Ansible; stub it faithfully.
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

#endregion --- [ Initialization ] ----------------------------------------------------------- #

#region ------ [ Main ] --------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

Import-Module -Name:'AWS.Tools.S3' -ErrorAction:'Stop'

# The repository lives on a volume of its own, so a missing directory means that volume is not
# mounted. Filling the same path on the system disk instead would hide the fault behind a drive
# that silently fills up.
If (-not (Test-Path -LiteralPath:$Path -PathType:'Container')) {
  Throw ('The repository directory is not there: {0}. The volume holding it is not mounted.' -f $Path)
}

$Objects = @(Get-S3Object -BucketName:$Bucket -Region:$Region)

# A key ending in '/' is the console's way of drawing a folder. It carries no content, and the
# directories are made below from the keys that do.
$Content = @($Objects | Where-Object -FilterScript { -not $PSItem.Key.EndsWith('/') })

# Resolved once, so every comparison below is against one spelling of the root. The joined paths
# are canonicalised individually too; both are needed for a path the caller did not normalise.
$Root = (Get-Item -LiteralPath:$Path -ErrorAction:'Stop').FullName

# Everything the bucket says this volume should hold. Compared case-insensitively because the
# filesystem is: two keys differing only in case cannot both exist here, and treating them as
# distinct would delete whichever arrived second on every run.
$Expected = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)

$Pending = [System.Collections.Generic.List[System.Object]]::new()
ForEach ($Object In $Content) {
  # GetFullPath collapses what the filesystem collapses. A key carrying '//', '/./' or '/../'
  # names a file the filesystem will call something shorter, and holding the longer spelling here
  # would mark the bucket's own object surplus on the next run -- deleting it, refetching it, and
  # never converging. Key-building code that interpolates a prefix produces exactly that.
  $Local = [System.IO.Path]::GetFullPath(
    (Join-Path -Path:$Root -ChildPath:$Object.Key.Replace('/', $PATH_SEPARATOR))
  )

  # Collapsing '/../' can land outside the repository entirely. This script is the one place a
  # key from the bucket becomes a local path, so containment is checked here or nowhere: a key
  # that escapes would be written beside the volume, as the account a deployment runs as, and
  # never seen again by a sync that only looks inside the root.
  If (-not $Local.StartsWith($Root + $PATH_SEPARATOR, [System.StringComparison]::OrdinalIgnoreCase)) {
    Throw ('The key {0} resolves outside the repository: {1}' -f $Object.Key, $Local)
  }

  [void]$Expected.Add($Local)
  $Existing = Get-Item -LiteralPath:$Local -ErrorAction:'SilentlyContinue'
  $Current = (
    $Null -ne $Existing -and
    $Existing.Length -eq $Object.Size -and
    $Existing.LastWriteTimeUtc -ge $Object.LastModified.ToUniversalTime()
  )
  If (-not $Current) {
    [void]$Pending.Add([PSCustomObject]@{ Key = [System.String]$Object.Key; Local = [System.String]$Local })
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
$Surplus = [System.Collections.Generic.List[System.String]]::new()
$Directories = [System.Collections.Generic.List[System.String]]::new()
$Unvisited = [System.Collections.Generic.Stack[System.String]]::new()
$Unvisited.Push($Root)

While ($Unvisited.Count -gt 0) {
  $Current = $Unvisited.Pop()
  ForEach ($Entry In @(Get-ChildItem -Force -LiteralPath:$Current -ErrorAction:'Stop')) {
    If ($Entry.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
      Throw ('The repository holds a reparse point: {0}. Remove it before syncing.' -f $Entry.FullName)
    }
    If ($Entry.PSIsContainer) {
      [void]$Directories.Add([System.String]$Entry.FullName)
      $Unvisited.Push($Entry.FullName)
    }
    ElseIf (-not $Expected.Contains($Entry.FullName)) {
      [void]$Surplus.Add([System.String]$Entry.FullName)
    }
  }
}

# Directories emptied by this run or left by an earlier one. Counted into 'changed' because a
# run that removes one has changed the volume, and reporting otherwise makes the next reader
# trust a converged result that is not.
$Removable = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Directory In @($Directories | Sort-Object -Descending -Property:{ $PSItem.Length })) {
  $Remaining = @(Get-ChildItem -Force -LiteralPath:$Directory -ErrorAction:'Stop' |
      Where-Object -FilterScript { $Surplus -notcontains $PSItem.FullName -and $Removable -notcontains $PSItem.FullName })
  If (-not $Remaining) {
    [void]$Removable.Add([System.String]$Directory)
  }
}

$Changed = [System.Boolean](($Pending.Count + $Surplus.Count + $Removable.Count) -gt 0)

# Either source of "change nothing": the module's check mode, or a -WhatIf a person typed.
$DryRun = [System.Boolean]($Ansible.CheckMode -or $RequestedWhatIf)

If (-not $DryRun) {
  # Removal runs BEFORE the fetch. A surplus file sitting where a key needs a directory otherwise
  # wedges the host: creating the directory over it is a silent no-op, the fetch then fails, and
  # the file that caused it is never reached because the fetch threw first -- so every later run
  # fails the same way. Surplus and expected are disjoint by construction, so removing first is
  # equally safe, and it frees the volume of superseded installers before new ones arrive.
  ForEach ($Remove In $Surplus) {
    Remove-Item -Force -LiteralPath:$Remove -ErrorAction:'Stop'
  }

  ForEach ($Fetch In $Pending) {
    $Parent = Split-Path -Path:$Fetch.Local -Parent
    If (-not (Test-Path -LiteralPath:$Parent -PathType:'Container')) {
      [void](New-Item -Force -ItemType:'Directory' -Path:$Parent)
    }
    Read-S3Object -BucketName:$Bucket -File:$Fetch.Local -Key:$Fetch.Key -Region:$Region | Out-Null
  }

  # Deepest-first, so a parent emptied by its own child's removal goes in the same pass. The
  # repository root is never a candidate: the walk starts inside it, and removing the mount point
  # would hide an unmounted volume behind the missing directory this script checks for first.
  #
  # Emptiness is re-read here rather than taken from the list computed earlier. The fetch runs
  # between the two, and it recreates directories -- so a folder that was empty when the list
  # was built can hold a freshly fetched object by the time the sweep reaches it.
  ForEach ($Directory In @($Removable | Sort-Object -Descending -Property:{ $PSItem.Length })) {
    If (Test-Path -LiteralPath:$Directory -PathType:'Container') {
      If (-not @(Get-ChildItem -Force -LiteralPath:$Directory -ErrorAction:'Stop')) {
        Remove-Item -Force -LiteralPath:$Directory -ErrorAction:'Stop'
      }
    }
  }
}

#endregion --- [ Main ] --------------------------------------------------------------------- #

#region ------ [ Output ] ------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Result = [PSCustomObject]@{
  bucket     = [System.String]$Bucket
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$DryRun
  fetched    = [System.String[]]@($Pending | ForEach-Object { $PSItem.Key })
  msg        = If ($Changed) {
    '{0} of {1} object(s) fetched from {2}, {3} local file(s) removed' -f
    $Pending.Count, $Content.Count, $Bucket, $Surplus.Count
  } Else {
    '{0} object(s) already current from {1}' -f $Content.Count, $Bucket
  }
  path       = [System.String]$Path
  present    = [System.Int32]$Content.Count
  removed    = [System.String[]]@($Surplus)
  swept      = [System.String[]]@($Removable)
}

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] ------------------------------------------------------------------- #

#endregion --- [ Script ] ------------------------------------------------------------------- #
