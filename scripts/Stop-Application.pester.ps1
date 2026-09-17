#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Stop-Application.ps1. Platform commands are replaced with
    in-memory target state so exact path containment, stop order, idempotence,
    reporting and refusal exit codes run under Linux CI as well as Windows.

    Stub state is global because the script runs in a child script scope; a
    function called from that child resolves $script: to the child, not here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path:$PSScriptRoot -ChildPath:'Stop-Application.ps1'

  Function Get-CimInstance {
    [CmdletBinding()]
    Param (
      [Parameter(Mandatory)] [System.String]$ClassName
    )

    Switch ($ClassName) {
      'Win32_Service' { $global:StopApplicationServices }
      'Win32_Process' { $global:StopApplicationProcesses }
      Default { Throw ('Unexpected CIM class: {0}' -f $ClassName) }
    }
  }

  Function Stop-Service {
    [CmdletBinding(SupportsShouldProcess)]
    Param (
      [Parameter(Mandatory)] [System.String]$Name,
      [Parameter()] [Switch]$Force
    )

    $global:StopApplicationEvents += 'service:{0}' -f $Name
    If ($Name -eq $global:StopApplicationRefusedService) {
      Throw ('Service stop refused: {0}' -f $Name)
    }

    $Service = $global:StopApplicationServices | Where-Object { $_.Name -eq $Name }
    If ($Null -eq $Service) {
      Throw ('Service does not exist: {0}' -f $Name)
    }
    $Service.State = 'Stopped'
  }

  Function Stop-Process {
    [CmdletBinding(SupportsShouldProcess)]
    Param (
      [Parameter(Mandatory)] [System.UInt32]$Id,
      [Parameter()] [Switch]$Force
    )

    $global:StopApplicationEvents += 'process:{0}' -f $Id
    If ($Id -eq $global:StopApplicationRefusedProcess) {
      Throw ('Process stop refused: {0}' -f $Id)
    }

    $global:StopApplicationProcesses = @(
      $global:StopApplicationProcesses | Where-Object { $_.ProcessId -ne $Id }
    )
  }
}

AfterAll {
  Remove-Variable -Name:(
    'StopApplicationEvents',
    'StopApplicationProcesses',
    'StopApplicationRefusedProcess',
    'StopApplicationRefusedService',
    'StopApplicationServices'
  ) -Scope:'Global' -ErrorAction:'SilentlyContinue'
}

Describe 'Stop-Application' {
  BeforeEach {
    $global:StopApplicationEvents = @()
    $global:StopApplicationProcesses = @()
    $global:StopApplicationRefusedProcess = [System.UInt32]::MaxValue
    $global:StopApplicationRefusedService = [System.String]::Empty
    $global:StopApplicationServices = @()
  }

  It 'reports NoChange and performs no stop when nothing is running' {
    $Result = & $script:ScriptPath -Directories:@('/apps/Chrome') -ProcessNames:@('chrome.exe') |
      ConvertFrom-Json

    $LASTEXITCODE | Should -Be 0
    $Result.changed | Should -BeFalse
    $Result.failed | Should -BeFalse
    $Result.services | Should -HaveCount 0
    $Result.processes | Should -HaveCount 0
    $global:StopApplicationEvents | Should -HaveCount 0
  }

  It 'stops contained services before contained processes and reports both' {
    $global:StopApplicationServices = @(
      [PSCustomObject]@{
        Name = 'ChromeElevation'; State = 'Running'; PathName = '"/apps/Chrome/Elevation Service.exe" --service'
      },
      [PSCustomObject]@{
        Name = 'OtherService'; State = 'Running'; PathName = '/apps/Other/service.exe'
      }
    )
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]101; ExecutablePath = '/apps/Chrome/chrome.exe'
      },
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]102; ExecutablePath = '/apps/Other/chrome.exe'
      }
    )

    $Result = & $script:ScriptPath -Directories:@('/apps/Chrome') -ProcessNames:@('chrome.exe') |
      ConvertFrom-Json

    $LASTEXITCODE | Should -Be 0
    $Result.changed | Should -BeTrue
    $Result.services.name | Should -Be 'ChromeElevation'
    $Result.processes.id | Should -Be 101
    $global:StopApplicationEvents | Should -Be @('service:ChromeElevation', 'process:101')
    ($global:StopApplicationServices | Where-Object Name -eq 'OtherService').State | Should -Be 'Running'
    $global:StopApplicationProcesses.ProcessId | Should -Contain 102
  }

  It 'requires a directory boundary rather than accepting a path prefix' {
    $global:StopApplicationServices = @(
      [PSCustomObject]@{
        Name = 'ChromeHelper'; State = 'Running'; PathName = '/apps/ChromeHelper/helper.exe'
      }
    )
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]201; ExecutablePath = '/apps/ChromeHelper/chrome.exe'
      }
    )

    $Result = & $script:ScriptPath -Directories:@('/apps/Chrome') | ConvertFrom-Json

    $LASTEXITCODE | Should -Be 0
    $Result.changed | Should -BeFalse
    $global:StopApplicationEvents | Should -HaveCount 0
  }

  It 'matches an optional process name exactly rather than as a substring' {
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'Slack.exe'; ProcessId = [System.UInt32]301; ExecutablePath = '/apps/Slack/Slack.exe'
      },
      [PSCustomObject]@{
        Name = 'NotSlack.exe'; ProcessId = [System.UInt32]302; ExecutablePath = '/apps/Slack/NotSlack.exe'
      }
    )

    $Result = & $script:ScriptPath -Directories:@('/apps/Slack') -ProcessNames:@('Slack.exe') |
      ConvertFrom-Json

    $Result.processes.id | Should -Be 301
    $global:StopApplicationProcesses.ProcessId | Should -Be 302
  }

  It 'stops every contained process when process names are omitted' {
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'System'; ProcessId = [System.UInt32]4; ExecutablePath = $Null
      },
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]401; ExecutablePath = '/apps/Chrome/chrome.exe'
      },
      [PSCustomObject]@{
        Name = 'crashpad.exe'; ProcessId = [System.UInt32]402; ExecutablePath = '/apps/Chrome/crashpad.exe'
      }
    )

    $Result = & $script:ScriptPath -Directories:@('/apps/Chrome') | ConvertFrom-Json

    $Result.processes | Should -HaveCount 2
    $global:StopApplicationProcesses | Should -HaveCount 1
    $global:StopApplicationProcesses.ProcessId | Should -Be 4
  }

  It 'fails closed when an exact named process has no readable executable path' {
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]451; ExecutablePath = $Null
      }
    )

    $Result = & $script:ScriptPath -Directories:@('/apps/Chrome') -ProcessNames:@('chrome.exe') 3>$Null |
      ConvertFrom-Json

    $LASTEXITCODE | Should -Be 1
    $Result.failed | Should -BeTrue
    $Result.msg | Should -Match 'Cannot read the executable path for matching process chrome.exe'
    $global:StopApplicationEvents | Should -HaveCount 0
  }

  It 'is idempotent after the qualifying service and process are stopped' {
    $global:StopApplicationServices = @(
      [PSCustomObject]@{
        Name = 'ChromeElevation'; State = 'Running'; PathName = '/apps/Chrome/elevation.exe'
      }
    )
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]501; ExecutablePath = '/apps/Chrome/chrome.exe'
      }
    )

    $First = & $script:ScriptPath -Directories:@('/apps/Chrome') | ConvertFrom-Json
    $global:StopApplicationEvents = @()
    $Second = & $script:ScriptPath -Directories:@('/apps/Chrome') | ConvertFrom-Json

    $First.changed | Should -BeTrue
    $Second.changed | Should -BeFalse
    $global:StopApplicationEvents | Should -HaveCount 0
  }

  It 'refuses a filesystem root before stopping anything' {
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'anything.exe'; ProcessId = [System.UInt32]601; ExecutablePath = '/apps/anything.exe'
      }
    )

    $Result = & $script:ScriptPath -Directories:@('/') 3>$Null | ConvertFrom-Json

    $LASTEXITCODE | Should -Be 1
    $Result.failed | Should -BeTrue
    $Result.msg | Should -Match 'cannot be a filesystem root'
    $global:StopApplicationEvents | Should -HaveCount 0
  }

  It 'returns nonzero and stops before processes when a service stop is refused' {
    $global:StopApplicationServices = @(
      [PSCustomObject]@{
        Name = 'ChromeElevation'; State = 'Running'; PathName = '/apps/Chrome/elevation.exe'
      }
    )
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]651; ExecutablePath = '/apps/Chrome/chrome.exe'
      }
    )
    $global:StopApplicationRefusedService = 'ChromeElevation'

    $Result = & $script:ScriptPath -Directories:@('/apps/Chrome') 3>$Null | ConvertFrom-Json

    $LASTEXITCODE | Should -Be 1
    $Result.failed | Should -BeTrue
    $Result.changed | Should -BeFalse
    $Result.services | Should -HaveCount 0
    $Result.processes | Should -HaveCount 0
    $Result.msg | Should -Match 'Service stop refused: ChromeElevation'
    $global:StopApplicationEvents | Should -Be @('service:ChromeElevation')
  }

  It 'returns nonzero and reports prior stops when a later process stop is refused' {
    $global:StopApplicationServices = @(
      [PSCustomObject]@{
        Name = 'ChromeElevation'; State = 'Running'; PathName = '/apps/Chrome/elevation.exe'
      }
    )
    $global:StopApplicationProcesses = @(
      [PSCustomObject]@{
        Name = 'chrome.exe'; ProcessId = [System.UInt32]701; ExecutablePath = '/apps/Chrome/chrome.exe'
      }
    )
    $global:StopApplicationRefusedProcess = [System.UInt32]701

    $Result = & $script:ScriptPath -Directories:@('/apps/Chrome') -ProcessNames:@('chrome.exe') 3>$Null |
      ConvertFrom-Json

    $LASTEXITCODE | Should -Be 1
    $Result.failed | Should -BeTrue
    $Result.changed | Should -BeTrue
    $Result.services.name | Should -Be 'ChromeElevation'
    $Result.processes | Should -HaveCount 0
    $Result.msg | Should -Match 'Process stop refused: 701'
  }
}
