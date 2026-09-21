#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Stops every service and process an application runs from its executable roots.

    .DESCRIPTION
        Matches by path only. A service matches when the process hosting it runs an
        executable under one of the roots; a process matches when its own executable
        is under a root and no settled service names it as host. Services are
        stopped through the service control manager, never with -Force, so a running
        dependent outside the roots is refused by Windows and reported. A service
        host is never killed: matched processes are stopped only once no matched
        service remains and no service is starting, stopping, or in an unknown state,
        because such a service's reported process id cannot be trusted.

        The stops are verified against reality: the services and processes are read
        and matched again once a second for up to 30 attempts, and the script fails
        naming every survivor if they do not all stop.

        A root that does not exist is not an error, because a first install has
        nothing to stop; it is listed in the result. Drive roots, UNC paths, the
        Windows directory and the shared Program Files, Common Files, ProgramData
        and Users directories are refused before anything is read.

        Nothing prevents a scheduled task, watchdog, or service recovery action from
        starting the application again after this script returns; run the installer
        as the very next step.

    .PARAMETER DebugLevel
        Three-digit control string configuring ErrorActionPreference,
        Set-PSDebug, and Set-StrictMode. Default '103'.

    .PARAMETER ExecutableRoot
        Every directory the application runs executables from, including any
        updater or maintenance service installed outside the application directory.

    .PARAMETER LogLevel
        Six-digit control string mapping Verbose, Debug, Information, Warning,
        Error, and Fatal streams to ActionPreference values.

    .EXAMPLE
        PS> ./Stop-Application.ps1 -ExecutableRoot:'C:\Program Files\Vendor\App'

    .OUTPUTS
        One JSON result object. The script exits 0 when everything matched is
        stopped and 1 when anything survives.
    #>
[CmdletBinding(
  ConfirmImpact = 'Medium',
  DefaultParameterSetName = 'default',
  HelpUri = '',
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
  $ExecutableRoot,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223'
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

[System.String[]]$Private:LogLevels = @(
  'Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal'
)

For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Force -Verbose:$False -WhatIf:$False -Name:('{0}Preference' -f $LogLevels[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse(
  $DebugLevel.Substring(0, 1)
)
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

Trap {
  Try {
    If ($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') {
      Write-Debug -Message:('Failed to execute command: {0}' -f @(
          [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
        ))
    }

    Write-Warning -Message:('[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      ))
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }

  Break
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

[System.Boolean]$Private:Changed = $False
[System.Boolean]$Private:CheckMode = [System.Boolean]$WhatIfPreference
[System.Boolean]$Private:Converged = $False
[System.Boolean]$Private:Failed = $False
[System.Collections.Generic.HashSet[System.UInt32]]$Private:HostIds = (
  [System.Collections.Generic.HashSet[System.UInt32]]::new()
)
[System.Collections.Generic.Dictionary[System.UInt32, PSCustomObject]]$Private:KillRequested = (
  [System.Collections.Generic.Dictionary[System.UInt32, PSCustomObject]]::new()
)
[System.Collections.Generic.List[System.Object]]$Private:MatchedProcesses = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.Collections.Generic.List[System.Object]]$Private:MatchedServices = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.Int32]$Private:MaxAttempts = 30
[System.Collections.Generic.List[System.String]]$Private:MissingRoots = (
  [System.Collections.Generic.List[System.String]]::new()
)
[System.String]$Private:Normalized = [System.String]::Empty
[System.String]$Private:OutcomeMessage = [System.String]::Empty
[System.Collections.Generic.Dictionary[System.UInt32, System.String]]$Private:PathById = (
  [System.Collections.Generic.Dictionary[System.UInt32, System.String]]::new()
)
[System.Object[]]$Private:Processes = @()
[PSCustomObject]$Private:Result = $Null
[System.Collections.Generic.List[System.String]]$Private:Roots = (
  [System.Collections.Generic.List[System.String]]::new()
)
[System.Object[]]$Private:Services = @()
[System.String[]]$Private:SettledStates = @('Continue Pending', 'Pause Pending', 'Paused', 'Running')
[System.Collections.Generic.List[System.String]]$Private:SharedParents = (
  [System.Collections.Generic.List[System.String]]::new()
)
[System.Collections.Generic.Dictionary[System.String, System.String]]$Private:StopError = (
  [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
)
[System.Collections.Generic.List[System.String]]$Private:StoppedServices = (
  [System.Collections.Generic.List[System.String]]::new()
)
[System.Collections.Generic.HashSet[System.String]]$Private:StopRequested = (
  [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::OrdinalIgnoreCase)
)
[System.Collections.Generic.List[PSCustomObject]]$Private:Survivors = (
  [System.Collections.Generic.List[PSCustomObject]]::new()
)
[System.String]$Private:SystemRoot = [System.String]::Empty
[System.Collections.Generic.List[System.Object]]$Private:UnknownHosts = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.Int32]$Private:Unreadable = 0
[System.Collections.Generic.List[System.String]]$Private:WouldStop = (
  [System.Collections.Generic.List[System.String]]::new()
)

# String logic, not System.IO.Path: the test runner is Linux, where C:\App is not rooted.
ForEach ($Parent In @(
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    $env:ProgramW6432
    $env:CommonProgramFiles
    ${env:CommonProgramFiles(x86)}
    $env:CommonProgramW6432
    $env:ProgramData
    $(If ($env:SystemDrive) { '{0}\Users' -f $env:SystemDrive })
  )) {
  If (-not [System.String]::IsNullOrWhiteSpace($Parent)) {
    $SharedParents.Add(($Parent -replace '[\\/]+', '\').TrimEnd('\'))
  }
}
If (-not [System.String]::IsNullOrWhiteSpace($env:SystemRoot)) {
  $SystemRoot = ($env:SystemRoot -replace '[\\/]+', '\').TrimEnd('\')
}

ForEach ($Root In $ExecutableRoot) {
  If ($Root -notmatch '^[A-Za-z]:[\\/]') {
    Throw ('{0}: an executable root must be an absolute local drive path.' -f $Root)
  }
  $Normalized = ($Root -replace '[\\/]+', '\').TrimEnd('\')
  If ($Normalized.Split('\') -contains '..' -or $Normalized.Split('\') -contains '.') {
    Throw ('{0}: an executable root must not contain a relative segment.' -f $Root)
  }
  If ($Normalized -match '^[A-Za-z]:$') {
    Throw ('{0}: a drive root is not an application''s executable root.' -f $Root)
  }
  If (
    $SystemRoot -and (
      $Normalized -eq $SystemRoot -or
      $Normalized.StartsWith($SystemRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    )
  ) {
    Throw ('{0}: the Windows directory is not an application''s executable root.' -f $Root)
  }
  If ($SharedParents -contains $Normalized) {
    Throw ('{0}: a shared parent directory is not an application''s executable root.' -f $Root)
  }

  If (Test-Path -LiteralPath:$Normalized -PathType:'Container') {
    $Roots.Add($Normalized)
  } ElseIf (Test-Path -LiteralPath:$Normalized) {
    Throw ('{0}: an executable root must be a directory, not a file.' -f $Root)
  } Else {
    $MissingRoots.Add($Normalized)
  }
}

For ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
  $Processes = @(Get-CimInstance -ClassName:'Win32_Process' -ErrorAction:'Stop')
  $Services = @(Get-CimInstance -ClassName:'Win32_Service' -ErrorAction:'Stop')

  $PathById.Clear()
  $Unreadable = 0
  ForEach ($Process In $Processes) {
    If ([System.String]::IsNullOrEmpty($Process.ExecutablePath)) {
      $Unreadable++
    } Else {
      $PathById[[System.UInt32]$Process.ProcessId] = [System.String]$Process.ExecutablePath
    }
  }

  # A ProcessId is trusted only in the settled states. Any other process-type service that is
  # not Stopped is an unknown host: nothing it reports is used to match or exclude a process.
  $HostIds.Clear()
  $MatchedServices.Clear()
  $UnknownHosts.Clear()
  ForEach ($Service In $Services) {
    If ($Service.ServiceType -notlike '*Process*' -or $Service.State -eq 'Stopped') {
      Continue
    }
    If ($SettledStates -notcontains $Service.State) {
      $UnknownHosts.Add($Service)
      Continue
    }
    $Null = $HostIds.Add([System.UInt32]$Service.ProcessId)
    If (-not $PathById.ContainsKey([System.UInt32]$Service.ProcessId)) {
      Continue
    }
    ForEach ($Root In $Roots) {
      If ($PathById[[System.UInt32]$Service.ProcessId].StartsWith(
          $Root + '\', [System.StringComparison]::OrdinalIgnoreCase
        )) {
        $MatchedServices.Add($Service)
        Break
      }
    }
  }

  $MatchedProcesses.Clear()
  ForEach ($Process In $Processes) {
    If (
      $HostIds.Contains([System.UInt32]$Process.ProcessId) -or
      -not $PathById.ContainsKey([System.UInt32]$Process.ProcessId)
    ) {
      Continue
    }
    ForEach ($Root In $Roots) {
      If ($PathById[[System.UInt32]$Process.ProcessId].StartsWith(
          $Root + '\', [System.StringComparison]::OrdinalIgnoreCase
        )) {
        $MatchedProcesses.Add($Process)
        Break
      }
    }
  }

  If ($MatchedServices.Count -eq 0 -and $MatchedProcesses.Count -eq 0) {
    $Converged = $True
    Break
  }
  If ($CheckMode) {
    ForEach ($Service In $MatchedServices) {
      $WouldStop.Add(('service {0}' -f $Service.Name))
    }
    ForEach ($Process In $MatchedProcesses) {
      $WouldStop.Add(('process {0} ({1})' -f @($Process.Name, $Process.ProcessId)))
    }
    Break
  }
  If ($Attempt -eq $MaxAttempts) {
    Break
  }

  If ($MatchedServices.Count -gt 0) {
    ForEach ($Service In $MatchedServices) {
      If (@('Paused', 'Running') -notcontains $Service.State) {
        Continue
      }
      If (-not $PSCmdlet.ShouldProcess([System.String]$Service.Name, 'Stop service')) {
        Continue
      }
      Try {
        # Never -Force: a running dependent outside the roots must keep refusing. The name is
        # escaped because -Name takes wildcards, and a bracket in a name would widen the match.
        Stop-Service `
          -Confirm:$False `
          -ErrorAction:'Stop' `
          -Name:([System.Management.Automation.WildcardPattern]::Escape([System.String]$Service.Name)) `
          -NoWait
        $Null = $StopRequested.Add([System.String]$Service.Name)
        $Changed = $True
      } Catch {
        $StopError[[System.String]$Service.Name] = $PSItem.Exception.Message
      }
    }
  } ElseIf ($UnknownHosts.Count -gt 0) {
    # Any matched process could be the host of an unsettled service; kill nothing until it settles.
    Write-Debug -Message:('Waiting on {0} unsettled service(s).' -f $UnknownHosts.Count)
  } Else {
    ForEach ($Process In $MatchedProcesses) {
      If (-not $PSCmdlet.ShouldProcess(
          ('{0} ({1})' -f $Process.Name, $Process.ProcessId),
          'Stop process'
        )) {
        Continue
      }
      Try {
        # -Force only suppresses the prompt for another user's process; it widens no match.
        Stop-Process -Confirm:$False -ErrorAction:'Stop' -Force -Id:([System.Int32]$Process.ProcessId)
        $KillRequested[[System.UInt32]$Process.ProcessId] = [PSCustomObject]@{
          executable_path = [System.String]$Process.ExecutablePath
          name            = [System.String]$Process.Name
          process_id      = [System.UInt32]$Process.ProcessId
        }
        $Changed = $True
      } Catch {
        $StopError[[System.String]$Process.ProcessId] = $PSItem.Exception.Message
      }
    }
  }

  Start-Sleep -Seconds:1
}

# A stop is reported only once the last read confirms it: requested but still present is a survivor.
ForEach ($Service In $Services) {
  If ($StopRequested.Contains([System.String]$Service.Name) -and $Service.State -eq 'Stopped') {
    $StoppedServices.Add([System.String]$Service.Name)
  }
}
ForEach ($Process In $Processes) {
  $Null = $KillRequested.Remove([System.UInt32]$Process.ProcessId)
}

If (-not $Converged) {
  ForEach ($Service In $MatchedServices) {
    $Survivors.Add([PSCustomObject]@{
        error = $(If ($StopError.ContainsKey([System.String]$Service.Name)) {
            $StopError[[System.String]$Service.Name]
          })
        kind  = 'service'
        name  = [System.String]$Service.Name
        state = [System.String]$Service.State
      })
  }
  If ($MatchedProcesses.Count -gt 0) {
    ForEach ($Service In $UnknownHosts) {
      $Survivors.Add([PSCustomObject]@{
          error = 'Unsettled, so it could be hosted by a matched process; nothing was killed.'
          kind  = 'service'
          name  = [System.String]$Service.Name
          state = [System.String]$Service.State
        })
    }
  }
  ForEach ($Process In $MatchedProcesses) {
    $Survivors.Add([PSCustomObject]@{
        error           = $(If ($StopError.ContainsKey([System.String]$Process.ProcessId)) {
            $StopError[[System.String]$Process.ProcessId]
          })
        executable_path = [System.String]$Process.ExecutablePath
        kind            = 'process'
        name            = '{0} ({1})' -f @($Process.Name, $Process.ProcessId)
      })
  }
}

$Failed = -not $CheckMode -and -not $Converged
If ($CheckMode) {
  $OutcomeMessage = 'Check mode: would stop {0} service(s) and {1} process(es).' -f @(
    $MatchedServices.Count
    $MatchedProcesses.Count
  )
} ElseIf ($Failed) {
  $OutcomeMessage = '{0} service(s) or process(es) under the executable roots did not stop.' -f $Survivors.Count
} Else {
  $OutcomeMessage = 'Stopped {0} service(s) and {1} process(es).' -f @(
    $StoppedServices.Count
    $KillRequested.Count
  )
}

$Result = [PSCustomObject]@{
  changed           = $Changed
  check_mode        = $CheckMode
  failed            = $Failed
  missing_roots     = [System.String[]]$MissingRoots.ToArray()
  msg               = $OutcomeMessage
  stopped_processes = [System.Object[]]@($KillRequested.Values)
  stopped_services  = [System.String[]]@($StoppedServices | Sort-Object)
  survivors         = [System.Object[]]$Survivors.ToArray()
  unreadable        = $Unreadable
  would_stop        = [System.String[]]$WouldStop.ToArray()
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Result | ConvertTo-Json -Depth:5
If ($Failed) {
  Exit 1
}
Exit 0

#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
