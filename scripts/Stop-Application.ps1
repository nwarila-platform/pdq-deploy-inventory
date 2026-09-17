#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Stops services and processes running from an application's install
        directories.

    .DESCRIPTION
        Stops each running service whose executable is contained by one of the
        declared application directories, then stops matching processes from
        those same directories. Process names are an optional exact-match
        filter; paths and names are compared case-insensitively without
        substring matching.

        The script runs directly on a PDQ target. It emits one JSON result and
        exits zero on success or nonzero on failure. A converged target, where
        nothing qualifying is running, reports no change and performs no stop.

        Application directories are normalized to full paths with a trailing
        directory separator before comparison. A filesystem root is refused so
        a caller cannot turn an application stop into a machine-wide stop.

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging
        functions, one digit each. First digit: ErrorActionPreference
        (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire, 4 Ignore,
        5 Suspend). Second digit: Set-PSDebug (0 off, 1 trace 1, 2 trace 2,
        3 trace 1 + step, 4 trace 2 + step). Third digit: Set-StrictMode
        (0 off, 1-3 that version). Default '103': stop on error, no tracing,
        strict mode 3.0.

    .PARAMETER Directories
        Absolute application install directories. An executable qualifies only
        when its normalized full path begins with one of these normalized paths
        at a directory boundary.

    .PARAMETER LogLevel
        Six-digit control string mapping the Verbose, Debug, Information,
        Warning, Error, and Fatal streams (in that order) to an
        ActionPreference value per digit (0 SilentlyContinue, 1 Stop,
        2 Continue, 3 Inquire, 4 Ignore, 5 Suspend). Default '002223'.

    .PARAMETER ProcessNames
        Optional executable names to stop. Each name is compared exactly and
        case-insensitively; for example, Slack.exe does not match NotSlack.exe.
        When omitted, every process under the declared directories qualifies.

    .EXAMPLE
        PS> ./Stop-Application.ps1 -Directories @('C:\Program Files\Google\Chrome\Application') -ProcessNames @('chrome.exe')

    .OUTPUTS
        One object carrying changed, directories, failed, msg, processes and
        services, serialized as JSON for the PDQ step.
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
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String[]]
  $Directories,

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
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [AllowEmptyCollection()]
  [System.String[]]
  $ProcessNames = @()
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# Initialize the custom stream preferences; the built-in ones already exist.
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)

# Configure log levels based on the LogLevel parameter.
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

# Configure the debug levels: first digit ErrorActionPreference, second digit
# Set-PSDebug, third digit Set-StrictMode.
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

$NormalizedDirectories = @()
$NormalizedProcessNames = @()
$StoppedProcesses = [System.Collections.Generic.List[System.Object]]::new()
$StoppedServices = [System.Collections.Generic.List[System.Object]]::new()

# This target-side script owns its exit code. The trap publishes the stops that
# completed before a refusal, then exits nonzero so PDQ cannot report success.
Trap {
  $FailureMessage = [System.String]$PSItem.Exception.Message
  Try {
    If ($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') {
      Write-Debug -Message:(
        'Failed to execute command: {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
      )
    }

    Write-Warning -Message:(
      '[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        $FailureMessage
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      )
    )
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }

  $Result = [PSCustomObject]@{
    changed     = ($StoppedServices.Count + $StoppedProcesses.Count) -gt 0
    directories = $NormalizedDirectories
    failed      = $True
    msg         = 'Application stop failed: {0}' -f $FailureMessage
    processes   = $StoppedProcesses.ToArray()
    services    = $StoppedServices.ToArray()
  }
  $Result | ConvertTo-Json -Depth:4
  Exit 1
}

$DirectorySeparators = [System.Char[]]@(
  [System.IO.Path]::DirectorySeparatorChar
  [System.IO.Path]::AltDirectorySeparatorChar
)

$NormalizedDirectories = @(
  @(
    ForEach ($Directory In $Directories) {
      If ([System.String]::IsNullOrWhiteSpace($Directory)) {
        Throw 'Directories cannot contain an empty path.'
      }

      $ExpandedDirectory = [System.Environment]::ExpandEnvironmentVariables($Directory.Trim())
      If (-not [System.IO.Path]::IsPathRooted($ExpandedDirectory)) {
        Throw ('Application directory must be absolute: {0}' -f $Directory)
      }

      $FullDirectory = [System.IO.Path]::GetFullPath($ExpandedDirectory)
      $RootDirectory = [System.IO.Path]::GetPathRoot($FullDirectory)
      $FullDirectory = $FullDirectory.TrimEnd($DirectorySeparators)
      $RootDirectory = $RootDirectory.TrimEnd($DirectorySeparators)
      If ([System.String]::Equals($FullDirectory, $RootDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw ('Application directory cannot be a filesystem root: {0}' -f $Directory)
      }

      '{0}{1}' -f $FullDirectory, [System.IO.Path]::DirectorySeparatorChar
    }
  ) | Sort-Object -Unique
)

$NormalizedProcessNames = @(
  @(
    ForEach ($ProcessName In $ProcessNames) {
      If ([System.String]::IsNullOrWhiteSpace($ProcessName)) {
        Throw 'ProcessNames cannot contain an empty name.'
      }
      $ProcessName.Trim()
    }
  ) | Sort-Object -Unique
)

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$Services = @(
  Get-CimInstance -ClassName:'Win32_Service' -ErrorAction:'Stop' |
    Sort-Object -Property:'Name'
)
ForEach ($Service In $Services) {
  If ($Service.State -ne 'Running' -or [System.String]::IsNullOrWhiteSpace($Service.PathName)) {
    Continue
  }

  $ServiceCommand = [System.Environment]::ExpandEnvironmentVariables(([System.String]$Service.PathName).Trim())
  If ($ServiceCommand.StartsWith('"')) {
    $ClosingQuote = $ServiceCommand.IndexOf('"', 1)
    If ($ClosingQuote -lt 2) {
      Throw ('Running service {0} has an invalid executable path: {1}' -f $Service.Name, $Service.PathName)
    }
    $ExecutablePath = $ServiceCommand.Substring(1, $ClosingQuote - 1)
  } ElseIf ($ServiceCommand -match '^(?<Executable>.+?\.exe)(?:\s|$)') {
    $ExecutablePath = $Matches['Executable']
  } Else {
    $ExecutablePath = $ServiceCommand
  }

  $ExecutablePath = [System.IO.Path]::GetFullPath($ExecutablePath)
  $IsContained = $False
  ForEach ($ApplicationDirectory In $NormalizedDirectories) {
    If ($ExecutablePath.StartsWith($ApplicationDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
      $IsContained = $True
      Break
    }
  }
  If (-not $IsContained) {
    Continue
  }

  If ($PSCmdlet.ShouldProcess(('service {0} ({1})' -f $Service.Name, $ExecutablePath), 'Stop')) {
    Stop-Service -Name:$Service.Name -Force:$False -Confirm:$False -ErrorAction:'Stop'
    [void]$StoppedServices.Add([PSCustomObject]@{
        name = [System.String]$Service.Name
        path = $ExecutablePath
      })
  }
}

# Re-read the process table after services stop because a service stop may have
# ended its owning process. Only still-running processes are candidates.
$Processes = @(
  Get-CimInstance -ClassName:'Win32_Process' -ErrorAction:'Stop' |
    Sort-Object -Property:@('Name', 'ProcessId')
)
ForEach ($Process In $Processes) {
  $NameMatches = $NormalizedProcessNames.Count -eq 0
  ForEach ($ProcessName In $NormalizedProcessNames) {
    If ([System.String]::Equals($Process.Name, $ProcessName, [System.StringComparison]::OrdinalIgnoreCase)) {
      $NameMatches = $True
      Break
    }
  }
  If (-not $NameMatches) {
    Continue
  }

  If ([System.String]::IsNullOrWhiteSpace($Process.ExecutablePath)) {
    If ($NormalizedProcessNames.Count -gt 0) {
      Throw ('Cannot read the executable path for matching process {0} ({1}).' -f $Process.Name, $Process.ProcessId)
    }
    Continue
  }

  $ExecutablePath = [System.IO.Path]::GetFullPath(
    [System.Environment]::ExpandEnvironmentVariables(([System.String]$Process.ExecutablePath).Trim())
  )
  $IsContained = $False
  ForEach ($ApplicationDirectory In $NormalizedDirectories) {
    If ($ExecutablePath.StartsWith($ApplicationDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
      $IsContained = $True
      Break
    }
  }
  If (-not $IsContained) {
    Continue
  }

  If ($PSCmdlet.ShouldProcess(('process {0} ({1})' -f $Process.Name, $Process.ProcessId), 'Stop')) {
    Stop-Process -Id:$Process.ProcessId -Force:$False -Confirm:$False -ErrorAction:'Stop'
    [void]$StoppedProcesses.Add([PSCustomObject]@{
        id   = [System.UInt32]$Process.ProcessId
        name = [System.String]$Process.Name
        path = $ExecutablePath
      })
  }
}

$Result = [PSCustomObject]@{
  changed     = ($StoppedServices.Count + $StoppedProcesses.Count) -gt 0
  directories = $NormalizedDirectories
  failed      = $False
  msg         = 'Stopped {0} service(s) and {1} process(es) from the declared application directories.' -f $StoppedServices.Count, $StoppedProcesses.Count
  processes   = $StoppedProcesses.ToArray()
  services    = $StoppedServices.ToArray()
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Result | ConvertTo-Json -Depth:4

Write-Debug -Message:'Exiting Script'
Exit 0
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
