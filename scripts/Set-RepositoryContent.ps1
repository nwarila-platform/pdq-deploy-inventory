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

    The mirror is ADDITIVE. An object missing from the bucket is left on disk, which is what keeps
    a superseded version available for a rollback, so this script never deletes.

    An object is fetched when the local copy is absent, a different size, or older than the object
    -- the comparison the vendor's own sync makes. A converge that finds the repository already
    current fetches nothing and reports no change, so this can run on every deployment.

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
    One object carrying changed, check_mode, bucket, path, fetched, present and msg.
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

$Pending = [System.Collections.Generic.List[System.Object]]::new()
ForEach ($Object In $Content) {
  $Local = Join-Path -Path:$Path -ChildPath:$Object.Key.Replace('/', $PATH_SEPARATOR)
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

$Changed = [System.Boolean]($Pending.Count -gt 0)

If ($Changed -and -not $Ansible.CheckMode) {
  ForEach ($Fetch In $Pending) {
    $Parent = Split-Path -Path:$Fetch.Local -Parent
    If (-not (Test-Path -LiteralPath:$Parent -PathType:'Container')) {
      [void](New-Item -Force -ItemType:'Directory' -Path:$Parent)
    }
    Read-S3Object -BucketName:$Bucket -File:$Fetch.Local -Key:$Fetch.Key -Region:$Region | Out-Null
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
    '{0} of {1} object(s) fetched from {2}' -f $Pending.Count, $Content.Count, $Bucket
  } Else {
    '{0} object(s) already current from {1}' -f $Content.Count, $Bucket
  }
  path       = [System.String]$Path
  present    = [System.Int32]$Content.Count
}

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] ------------------------------------------------------------------- #

#endregion --- [ Script ] ------------------------------------------------------------------- #
