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
    One object carrying changed, check_mode, bucket, path, fetched, removed, present and msg.
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

# Resolved once, before anything is compared. Get-ChildItem reports fully resolved paths and
# $Path arrives however the caller wrote it, so comparing an unresolved root against a resolved
# file matches nothing: every file looks orphaned and the first run empties the repository.
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

# Anything on the volume the bucket does not account for. Enumerated before anything is written,
# so an object this run is about to fetch is never mistaken for one nothing owns.
$Surplus = [System.Collections.Generic.List[System.String]]::new()
ForEach ($File In @(Get-ChildItem -File -Force -LiteralPath:$Root -Recurse -ErrorAction:'Stop')) {
  If (-not $Expected.Contains($File.FullName)) {
    [void]$Surplus.Add([System.String]$File.FullName)
  }
}

$Changed = [System.Boolean](($Pending.Count + $Surplus.Count) -gt 0)

If (-not $Ansible.CheckMode) {
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

  # Directories are not objects, so removing the last key under one leaves the folder behind.
  # Swept unconditionally rather than only when something else changed: a directory emptied by a
  # run that then failed would otherwise persist while every later run reported no change.
  # Deepest-first so a parent emptied by its own child's removal is cleared in the same pass. The
  # repository root is never a candidate -- Get-ChildItem -Recurse does not return it, and
  # removing the mount point would hide an unmounted volume behind a missing directory.
  ForEach ($Directory In @(
      Get-ChildItem -Directory -Force -LiteralPath:$Root -Recurse -ErrorAction:'Stop' |
        Sort-Object -Descending -Property:{ $PSItem.FullName.Length }
    )) {
    If (-not @(Get-ChildItem -Force -LiteralPath:$Directory.FullName -ErrorAction:'Stop')) {
      Remove-Item -Force -LiteralPath:$Directory.FullName -ErrorAction:'Stop'
    }
  }
}

#endregion --- [ Main ] --------------------------------------------------------------------- #

#region ------ [ Output ] ------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Result = [PSCustomObject]@{
  bucket     = [System.String]$Bucket
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
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
}

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] ------------------------------------------------------------------- #

#endregion --- [ Script ] ------------------------------------------------------------------- #
