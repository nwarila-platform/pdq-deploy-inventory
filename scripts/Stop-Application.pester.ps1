#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Stop-Application.ps1. The service control manager and the
    process table are modeled in memory, so the Windows-only behavior runs under
    bare Pester on any development host. The model keeps the relationships the
    script depends on: a stopping service reports Stop Pending with no process id
    before it reports Stopped, a host process exits only when the last service it
    hosts stops, and a service is refused while a service depending on it runs.
    A pending service reports no process id or a stale one, as Windows allows; a
    service can also start late or be replaced by a watchdog, and a driver entry
    never has a process.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Stop-Application.ps1'
  $script:EnvironmentNames = @(
    'CommonProgramFiles'
    'CommonProgramFiles(x86)'
    'CommonProgramW6432'
    'ProgramData'
    'ProgramFiles'
    'ProgramFiles(x86)'
    'ProgramW6432'
    'SystemDrive'
    'SystemRoot'
  )
  $script:SavedEnvironment = @{}
  ForEach ($Name In $script:EnvironmentNames) {
    $script:SavedEnvironment[$Name] = [System.Environment]::GetEnvironmentVariable($Name)
  }

  Function Set-WindowsEnvironment {
    [System.Environment]::SetEnvironmentVariable('CommonProgramFiles', 'C:\Program Files\Common Files')
    [System.Environment]::SetEnvironmentVariable('CommonProgramFiles(x86)', 'C:\Program Files (x86)\Common Files')
    [System.Environment]::SetEnvironmentVariable('CommonProgramW6432', 'C:\Program Files\Common Files')
    [System.Environment]::SetEnvironmentVariable('ProgramData', 'C:\ProgramData')
    [System.Environment]::SetEnvironmentVariable('ProgramFiles', 'C:\Program Files')
    [System.Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)')
    [System.Environment]::SetEnvironmentVariable('ProgramW6432', 'C:\Program Files')
    [System.Environment]::SetEnvironmentVariable('SystemDrive', 'C:')
    [System.Environment]::SetEnvironmentVariable('SystemRoot', 'C:\Windows')
  }

  Function Add-FakeProcess {
    Param ([System.UInt32]$Id, [System.String]$Path)
    $global:StopApplicationProcesses.Add(@{
        ExecutablePath = $Path
        Name           = Split-Path -Path $Path -Leaf
        ProcessId      = $Id
      })
  }

  Function Add-FakeService {
    Param (
      [System.String]$Name,
      [System.UInt32]$HostId,
      [System.String[]]$DependsOn = @(),
      [System.String]$State = 'Running',
      [System.UInt32]$PendingId = 0,
      [System.String]$ServiceType = 'Own Process'
    )
    $global:StopApplicationServices.Add(@{
        DependsOn   = $DependsOn
        Name        = $Name
        PendingId   = $PendingId
        ProcessId   = $HostId
        ServiceType = $ServiceType
        State       = $State
      })
  }

  Function Remove-FakeProcess {
    Param ([System.UInt32]$Id)
    $Remaining = @($global:StopApplicationProcesses | Where-Object { $PSItem.ProcessId -ne $Id })
    $global:StopApplicationProcesses.Clear()
    ForEach ($Process In $Remaining) { $global:StopApplicationProcesses.Add($Process) }
  }

  Function Get-FakeService {
    Param ([System.String]$Name)
    $global:StopApplicationServices | Where-Object { $PSItem.Name -eq $Name }
  }

  Function Invoke-StopApplication {
    Param ([System.String[]]$Root, [Switch]$WhatIf)
    $Output = & $script:ScriptPath -ExecutableRoot $Root -WhatIf:$WhatIf.IsPresent
    [PSCustomObject]@{
      ExitCode = $LASTEXITCODE
      Result   = ($Output -join [System.Environment]::NewLine) | ConvertFrom-Json
    }
  }

  Function Test-Path {
    [CmdletBinding()]
    Param (
      [Parameter()]
      [System.String]
      $LiteralPath,

      [Parameter()]
      [System.String]
      $PathType = 'Any'
    )

    If ($PathType -eq 'Container') {
      Return $global:StopApplicationDirectories -contains $LiteralPath
    }
    Return (
      $global:StopApplicationDirectories -contains $LiteralPath -or
      $global:StopApplicationFiles -contains $LiteralPath
    )
  }

  Function Get-CimInstance {
    [CmdletBinding()]
    Param ([Parameter()][System.String]$ClassName)

    $global:StopApplicationReads.Add($ClassName)
    If ($ClassName -eq 'Win32_Process') {
      Return @(
        ForEach ($Process In $global:StopApplicationProcesses) { [PSCustomObject]$Process }
      )
    }

    $Snapshot = @(
      ForEach ($Service In $global:StopApplicationServices) {
        $Reported = [PSCustomObject]@{
          Name        = $Service.Name
          ProcessId   = $Service.ProcessId
          ServiceType = $Service.ServiceType
          State       = $Service.State
        }
        If ($Service.State -match '^(Start|Stop) Pending$') {
          $Reported.ProcessId = $Service.PendingId
        }
        $Reported
      }
    )
    $global:StopApplicationServiceReads++

    # A service that is still starting becomes Running once its pending reads are spent.
    ForEach ($Service In $global:StopApplicationServices) {
      If ($Service.State -ne 'Start Pending') {
        Continue
      }
      If ($global:StopApplicationPendingReads[$Service.Name] -gt 0) {
        $global:StopApplicationPendingReads[$Service.Name]--
        Continue
      }
      $Service.State = 'Running'
    }

    # A late service starts, with a new host process, after the configured number of reads.
    ForEach ($Late In @($global:StopApplicationLateStarts)) {
      If ($global:StopApplicationServiceReads -eq $Late.AfterReads) {
        Add-FakeProcess -Id $Late.HostId -Path $Late.Path
        (Get-FakeService -Name $Late.Name).ProcessId = $Late.HostId
        (Get-FakeService -Name $Late.Name).State = 'Running'
      }
    }

    # Stop Pending lasts for the configured number of reads, then the service stops.
    ForEach ($Service In $global:StopApplicationServices) {
      If ($Service.State -ne 'Stop Pending') {
        Continue
      }
      If ($global:StopApplicationPendingReads[$Service.Name] -gt 0) {
        $global:StopApplicationPendingReads[$Service.Name]--
        Continue
      }
      $Service.State = 'Stopped'
      $HostId = $Service.ProcessId
      If ($global:StopApplicationRestartOnce -contains $Service.Name) {
        $global:StopApplicationRestartOnce = @($global:StopApplicationRestartOnce | Where-Object { $PSItem -ne $Service.Name })
        $Path = ($global:StopApplicationProcesses | Where-Object { $PSItem.ProcessId -eq $HostId }).ExecutablePath
        $Service.ProcessId = $HostId + 1000
        $Service.State = 'Running'
        Add-FakeProcess -Id $Service.ProcessId -Path $Path
      }
      $StillHosting = @($global:StopApplicationServices | Where-Object {
          $PSItem.ProcessId -eq $HostId -and $PSItem.State -ne 'Stopped'
        })
      If ($StillHosting.Count -eq 0) {
        Remove-FakeProcess -Id $HostId
      }
    }
    Return $Snapshot
  }

  Function Stop-Service {
    [CmdletBinding()]
    Param (
      [Parameter()][Switch]$Confirm,
      [Parameter()][Switch]$Force,
      [Parameter()][System.String]$Name,
      [Parameter()][Switch]$NoWait
    )

    $Name = [System.Management.Automation.WildcardPattern]::Unescape($Name)

    $global:StopApplicationCalls.Add([PSCustomObject]@{
        Force     = $Force.IsPresent
        Kind      = 'service'
        NoWait    = $NoWait.IsPresent
        RawName   = $PSBoundParameters['Name']
        Target    = $Name
        Unsettled = 0
      })
    $Service = Get-FakeService -Name $Name
    $Running = @($global:StopApplicationServices | Where-Object {
        $PSItem.DependsOn -contains $Name -and $PSItem.State -ne 'Stopped'
      })
    If ($Running.Count -gt 0) {
      Throw ('Cannot stop service ''{0}'' because it has dependent services.' -f $Name)
    }
    If ($global:StopApplicationRefuse -contains $Name) {
      Throw ('Service ''{0}'' cannot be stopped.' -f $Name)
    }
    $Service.State = 'Stop Pending'
  }

  Function Stop-Process {
    [CmdletBinding()]
    Param (
      [Parameter()][Switch]$Confirm,
      [Parameter()][Switch]$Force,
      [Parameter()][System.Int32]$Id
    )

    $global:StopApplicationCalls.Add([PSCustomObject]@{
        Force     = $Force.IsPresent
        Kind      = 'process'
        NoWait    = $False
        RawName   = $Null
        Target    = [System.String]$Id
        Unsettled = @($global:StopApplicationServices | Where-Object { $PSItem.State -match '^(Start|Stop) Pending$' }).Count
      })
    If ($global:StopApplicationUnkillable -contains $Id) {
      Throw ('Access is denied: process {0}.' -f $Id)
    }
    If ($global:StopApplicationKillFailures[$Id] -gt 0) {
      $global:StopApplicationKillFailures[$Id]--
      Throw ('Access is denied: process {0}.' -f $Id)
    }
    If ($global:StopApplicationLinger -contains $Id) {
      Return
    }
    $Path = ($global:StopApplicationProcesses | Where-Object { $PSItem.ProcessId -eq $Id }).ExecutablePath
    Remove-FakeProcess -Id $Id
    If ($global:StopApplicationRespawn.ContainsKey($Id)) {
      Add-FakeProcess -Id $global:StopApplicationRespawn[$Id] -Path $Path
      $global:StopApplicationRespawn.Remove($Id)
    }
  }

  Function Start-Sleep {
    [CmdletBinding()]
    Param ([Parameter()][System.Int32]$Seconds)
    $global:StopApplicationSleeps++
  }
}

AfterAll {
  ForEach ($Name In $script:EnvironmentNames) {
    [System.Environment]::SetEnvironmentVariable($Name, $script:SavedEnvironment[$Name])
  }
  Remove-Variable -Name @(
    'StopApplicationCalls'
    'StopApplicationDirectories'
    'StopApplicationFiles'
    'StopApplicationKillFailures'
    'StopApplicationLateStarts'
    'StopApplicationLinger'
    'StopApplicationPendingReads'
    'StopApplicationProcesses'
    'StopApplicationReads'
    'StopApplicationRefuse'
    'StopApplicationRespawn'
    'StopApplicationRestartOnce'
    'StopApplicationServiceReads'
    'StopApplicationServices'
    'StopApplicationSleeps'
    'StopApplicationUnkillable'
  ) -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Stop-Application' {
  BeforeEach {
    Set-WindowsEnvironment
    $global:StopApplicationCalls = [System.Collections.Generic.List[System.Object]]::new()
    $global:StopApplicationDirectories = @('C:\App', 'C:\AppData', 'C:\Program Files\Vendor\App')
    $global:StopApplicationFiles = @('C:\App\app.exe')
    $global:StopApplicationKillFailures = @{}
    $global:StopApplicationLateStarts = @()
    $global:StopApplicationLinger = @()
    $global:StopApplicationPendingReads = @{}
    $global:StopApplicationProcesses = [System.Collections.Generic.List[System.Collections.Hashtable]]::new()
    $global:StopApplicationReads = [System.Collections.Generic.List[System.String]]::new()
    $global:StopApplicationRefuse = @()
    $global:StopApplicationRespawn = @{}
    $global:StopApplicationRestartOnce = @()
    $global:StopApplicationServiceReads = 0
    $global:StopApplicationServices = [System.Collections.Generic.List[System.Collections.Hashtable]]::new()
    $global:StopApplicationSleeps = 0
    $global:StopApplicationUnkillable = @()

    Add-FakeProcess -Id 4 -Path 'C:\Windows\System32\svchost.exe'
    Add-FakeService -Name 'Dhcp' -HostId 4
  }

  Context 'matching' {
    It 'stops a service hosted under a root and leaves one outside running' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $Run.Result.stopped_services | Should -Be @('AppSvc')
      (Get-FakeService -Name 'AppSvc').State | Should -Be 'Stopped'
      (Get-FakeService -Name 'Dhcp').State | Should -Be 'Running'
      $Run.Result.changed | Should -BeTrue
    }

    It 'matches on a directory boundary, case-insensitively' {
      Add-FakeProcess -Id 100 -Path 'C:\AppData\other.exe'
      Add-FakeProcess -Id 101 -Path 'c:\app\BIN\tool.exe'
      Add-FakeProcess -Id 102 -Path 'C:\AppData\svc.exe'
      Add-FakeService -Name 'AppDataSvc' -HostId 102
      Add-FakeProcess -Id 103 -Path 'c:\APP\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 103

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($global:StopApplicationCalls.Target) | Should -Be @('AppSvc', '101')
      @($global:StopApplicationProcesses.ProcessId) | Should -Contain 100
      (Get-FakeService -Name 'AppDataSvc').State | Should -Be 'Running'
    }

    It 'stops a process under a root and leaves one outside running' {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'
      Add-FakeProcess -Id 200 -Path 'C:\Other\other.exe'

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($Run.Result.stopped_processes.process_id) | Should -Be @(100)
      @($global:StopApplicationProcesses.ProcessId) | Should -Contain 200
    }

    It 'never kills a process that hosts a service; the service stops it' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
      @($global:StopApplicationProcesses.ProcessId) | Should -Not -Contain 100
    }

    It 'stops two services sharing a host by name and never kills the host, even mid Stop Pending' {
      Add-FakeProcess -Id 100 -Path 'C:\App\host.exe'
      Add-FakeService -Name 'AppOne' -HostId 100
      Add-FakeService -Name 'AppTwo' -HostId 100
      $global:StopApplicationPendingReads['AppOne'] = 2

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($Run.Result.stopped_services) | Should -Be @('AppOne', 'AppTwo')
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
      @($global:StopApplicationProcesses.ProcessId) | Should -Not -Contain 100
    }

    It 'counts an unreadable executable path without failing' {
      $global:StopApplicationProcesses.Add(@{ ExecutablePath = $Null; Name = 'csrss.exe'; ProcessId = 8 })

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $Run.Result.unreadable | Should -Be 1
    }
  }

  Context 'stopping' {
    It 'never passes -Force to Stop-Service and always passes -NoWait' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100

      $Null = Invoke-StopApplication -Root 'C:\App'

      $Stops = @($global:StopApplicationCalls | Where-Object Kind -EQ 'service')
      $Stops | Should -HaveCount 1
      $Stops[0].Force | Should -BeFalse
      $Stops[0].NoWait | Should -BeTrue
    }

    It 'always passes -Force to Stop-Process, so another user''s process never prompts' {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'

      $Null = Invoke-StopApplication -Root 'C:\App'

      $global:StopApplicationCalls[0].Force | Should -BeTrue
    }

    It 'stops a service by its literal name even when it holds wildcard characters' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'App[1]' -HostId 100

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $global:StopApplicationCalls[0].RawName | Should -Be 'App`[1`]'
    }

    It 'attempts every matched process even after one refuses' {
      Add-FakeProcess -Id 100 -Path 'C:\App\a.exe'
      Add-FakeProcess -Id 101 -Path 'C:\App\b.exe'
      $global:StopApplicationUnkillable = @(100)

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      @($global:StopApplicationProcesses.ProcessId) | Should -Not -Contain 101
      @($Run.Result.stopped_processes.process_id) | Should -Be @(101)
    }

    It 'converges a matched dependency pair enumerated <Order>' -ForEach @(
      @{ Order = 'base first'; BaseFirst = $True }
      @{ Order = 'dependent first'; BaseFirst = $False }
    ) {
      Add-FakeProcess -Id 100 -Path 'C:\App\base.exe'
      Add-FakeProcess -Id 101 -Path 'C:\App\top.exe'
      If ($BaseFirst) {
        Add-FakeService -Name 'AppBase' -HostId 100
        Add-FakeService -Name 'AppTop' -HostId 101 -DependsOn 'AppBase'
      } Else {
        Add-FakeService -Name 'AppTop' -HostId 101 -DependsOn 'AppBase'
        Add-FakeService -Name 'AppBase' -HostId 100
      }

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      (Get-FakeService -Name 'AppBase').State | Should -Be 'Stopped'
      (Get-FakeService -Name 'AppTop').State | Should -Be 'Stopped'
    }

    It 'fails naming the survivor when an unmatched dependent keeps running, and never stops the dependent' {
      Add-FakeProcess -Id 100 -Path 'C:\App\base.exe'
      Add-FakeProcess -Id 300 -Path 'C:\Other\consumer.exe'
      Add-FakeService -Name 'AppBase' -HostId 100
      Add-FakeService -Name 'Consumer' -HostId 300 -DependsOn 'AppBase'

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      $Run.Result.failed | Should -BeTrue
      $Run.Result.survivors[0].name | Should -Be 'AppBase'
      $Run.Result.survivors[0].error | Should -Match 'dependent services'
      @($global:StopApplicationCalls.Target) | Should -Not -Contain 'Consumer'
      (Get-FakeService -Name 'Consumer').State | Should -Be 'Running'
    }

    It 'stops no process while any service is still settling' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeProcess -Id 101 -Path 'C:\App\app.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100
      $global:StopApplicationPendingReads['AppSvc'] = 3

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $Kills = @($global:StopApplicationCalls | Where-Object Kind -EQ 'process')
      $Kills | Should -HaveCount 1
      $Kills[0].Unsettled | Should -Be 0
    }

    It 'reports a stop only once it is confirmed' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100
      $global:StopApplicationPendingReads['AppSvc'] = 99

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      $Run.Result.changed | Should -BeTrue
      $Run.Result.stopped_services | Should -HaveCount 0
      @($Run.Result.survivors.name) | Should -Contain 'AppSvc'
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
    }

    It 'succeeds when a slow service stops on a later attempt' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100
      $global:StopApplicationPendingReads['AppSvc'] = 10

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $Run.Result.survivors | Should -HaveCount 0
    }

    It 'fails naming a process that never stops' {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'
      $global:StopApplicationUnkillable = @(100)

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      $Run.Result.survivors[0].kind | Should -Be 'process'
      $Run.Result.survivors[0].name | Should -Be 'app.exe (100)'
      $Run.Result.survivors[0].error | Should -Match 'Access is denied'
      $global:StopApplicationSleeps | Should -Be 29
    }

    It 'reports a kill only once the process is confirmed gone' {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'
      $global:StopApplicationLinger = @(100)

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      $Run.Result.changed | Should -BeTrue
      $Run.Result.stopped_processes | Should -HaveCount 0
      $Run.Result.survivors[0].name | Should -Be 'app.exe (100)'
    }

    It 'observes a stop issued in the last permitted round before deciding' {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'
      $global:StopApplicationKillFailures[100] = 28

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $global:StopApplicationSleeps | Should -Be 29
      $global:StopApplicationReads.Count | Should -Be 60
    }

    It 'catches a service restarted under a new process before the first clean read' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100
      $global:StopApplicationRestartOnce = @('AppSvc')

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($global:StopApplicationCalls | Where-Object Target -EQ 'AppSvc') | Should -HaveCount 2
      (Get-FakeService -Name 'AppSvc').State | Should -Be 'Stopped'
    }

    It 'discovers a replacement process under a new id before the first clean read' {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'
      $global:StopApplicationRespawn[100] = 101

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($global:StopApplicationCalls.Target) | Should -Be @('100', '101')
    }

    It 'discovers a service that starts after the first read' {
      Add-FakeService -Name 'AppLate' -HostId 0 -State 'Stopped'
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'
      $global:StopApplicationLateStarts = @(
        @{ AfterReads = 1; HostId = 200; Name = 'AppLate'; Path = 'C:\App\late.exe' }
      )

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $Run.Result.stopped_services | Should -Be @('AppLate')
      (Get-FakeService -Name 'AppLate').State | Should -Be 'Stopped'
    }

    It 'waits out a service already Stop Pending with a stale process id, killing nothing' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100 -State 'Stop Pending' -PendingId 999
      $global:StopApplicationPendingReads['AppSvc'] = 3

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $global:StopApplicationServiceReads | Should -Be 5
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
    }

    It 'never kills the host of a Start Pending service reporting a stale process id' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100 -State 'Start Pending' -PendingId 999
      $global:StopApplicationPendingReads['AppSvc'] = 2

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
      $Run.Result.stopped_services | Should -Be @('AppSvc')
    }

    It 'never kills a process while a service reports the Unknown state, whatever id it reports' {
      Add-FakeService -Name 'Odd' -HostId 999 -State 'Unknown'
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
      @($Run.Result.survivors.name) | Should -Contain 'Odd'
    }

    It 'names an unsettled service alongside a matched service that also survives' {
      Add-FakeProcess -Id 100 -Path 'C:\App\base.exe'
      Add-FakeService -Name 'Base' -HostId 100
      $global:StopApplicationRefuse = @('Base')
      Add-FakeProcess -Id 200 -Path 'C:\App\starting.exe'
      Add-FakeService -Name 'Starting' -HostId 200 -State 'Start Pending' -PendingId 999
      $global:StopApplicationPendingReads['Starting'] = 99

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      @($Run.Result.survivors.name) | Should -Contain 'Base'
      @($Run.Result.survivors.name) | Should -Contain 'Starting'
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
    }

    It 'treats <State> as settled: its host is known and never killed' -ForEach @(
      @{ State = 'Paused'; Stops = 1 }
      @{ State = 'Pause Pending'; Stops = 0 }
      @{ State = 'Continue Pending'; Stops = 0 }
    ) {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100 -State $State

      $Run = Invoke-StopApplication -Root 'C:\App'

      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'service') | Should -HaveCount $Stops
      @($Run.Result.survivors.name) + @($Run.Result.stopped_services) | Should -Contain 'AppSvc'
    }

    It 'counts a <Type> service as a process service' -ForEach @(
      @{ Type = 'Share Process' }
      @{ Type = 'Interactive Process' }
    ) {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100 -ServiceType $Type

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      $Run.Result.stopped_services | Should -Be @('AppSvc')
    }

    It 'is not held up by a starting driver entry, which never has a process' {
      Add-FakeService -Name 'Disk' -HostId 0 -ServiceType 'Kernel Driver' -State 'Start Pending'
      $global:StopApplicationPendingReads['Disk'] = 99
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($Run.Result.stopped_processes.process_id) | Should -Be @(100)
    }

    It 'never kills a process while a Start Pending service reports no process id, then stops the service' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100 -State 'Start Pending'
      $global:StopApplicationPendingReads['AppSvc'] = 2

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 0
      @($global:StopApplicationCalls | Where-Object Kind -EQ 'process') | Should -HaveCount 0
      $Run.Result.stopped_services | Should -Be @('AppSvc')
    }

    It 'fails naming a pending service that never reports its process id' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeService -Name 'Stuck' -HostId 100 -State 'Start Pending'
      $global:StopApplicationPendingReads['Stuck'] = 99

      $Run = Invoke-StopApplication -Root 'C:\App'

      $Run.ExitCode | Should -Be 1
      @($global:StopApplicationCalls) | Should -HaveCount 0
      @($Run.Result.survivors.name) | Should -Contain 'Stuck'
    }
  }

  Context 'roots' {
    It 'refuses <Root> before any read' -ForEach @(
      @{ Root = 'C:\' }
      @{ Root = '\\server\share\x' }
      @{ Root = 'C:\Windows' }
      @{ Root = 'C:\Windows\System32\x' }
      @{ Root = 'C:\Program Files' }
      @{ Root = 'C:\Program Files\' }
      @{ Root = 'C:\Program Files\Common Files' }
      @{ Root = 'C:\ProgramData' }
      @{ Root = 'C:\Users' }
      @{ Root = 'C:\App\..\Windows' }
      @{ Root = 'App' }
      @{ Root = 'C:\App\app.exe' }
    ) {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'

      { & $script:ScriptPath -ExecutableRoot $Root 3>$Null } | Should -Throw

      $global:StopApplicationReads | Should -HaveCount 0
      $global:StopApplicationCalls | Should -HaveCount 0
    }

    It 'refuses every shared parent and accepts its descendants when each variable names its own path' -ForEach @(
      @{ Name = 'CommonProgramFiles'; Value = 'D:\CPF' }
      @{ Name = 'CommonProgramFiles(x86)'; Value = 'D:\CPF86' }
      @{ Name = 'CommonProgramW6432'; Value = 'D:\CPFW' }
      @{ Name = 'ProgramData'; Value = 'D:\PD' }
      @{ Name = 'ProgramFiles'; Value = 'D:\PF' }
      @{ Name = 'ProgramFiles(x86)'; Value = 'D:\PF86' }
      @{ Name = 'ProgramW6432'; Value = 'D:\PFW' }
      @{ Name = 'SystemDrive'; Value = 'E:'; Refused = 'E:\Users' }
    ) {
      ForEach ($Other In $script:EnvironmentNames) {
        [System.Environment]::SetEnvironmentVariable($Other, $Null)
      }
      [System.Environment]::SetEnvironmentVariable($Name, $Value)
      $Parent = If ($PSItem.ContainsKey('Refused')) { $Refused } Else { $Value }

      { & $script:ScriptPath -ExecutableRoot $Parent 3>$Null } | Should -Throw
      $global:StopApplicationReads | Should -HaveCount 0

      $Run = Invoke-StopApplication -Root ('{0}\Vendor\App' -f $Parent)
      $Run.ExitCode | Should -Be 0
    }

    It 'refuses the native Common Files named only by CommonProgramW6432' {
      [System.Environment]::SetEnvironmentVariable('CommonProgramFiles', 'C:\Program Files (x86)\Common Files')

      { & $script:ScriptPath -ExecutableRoot 'C:\Program Files\Common Files' 3>$Null } | Should -Throw

      $global:StopApplicationReads | Should -HaveCount 0
    }

    It 'refuses the native Program Files named only by ProgramW6432' {
      [System.Environment]::SetEnvironmentVariable('ProgramFiles', 'C:\Program Files (x86)')
      [System.Environment]::SetEnvironmentVariable('CommonProgramFiles', 'C:\Program Files (x86)\Common Files')

      { & $script:ScriptPath -ExecutableRoot 'C:\Program Files' 3>$Null } | Should -Throw

      $global:StopApplicationReads | Should -HaveCount 0
    }

    It 'stops what runs under each of several roots' {
      Add-FakeProcess -Id 100 -Path 'C:\App\app.exe'
      Add-FakeProcess -Id 101 -Path 'C:\Program Files\Vendor\App\updater.exe'
      Add-FakeProcess -Id 102 -Path 'C:\Other\other.exe'

      $Run = Invoke-StopApplication -Root 'C:\App', 'C:\Program Files\Vendor\App'

      $Run.ExitCode | Should -Be 0
      @($Run.Result.stopped_processes.process_id | Sort-Object) | Should -Be @(100, 101)
    }

    It 'accepts an application directory under Program Files' {
      Add-FakeProcess -Id 100 -Path 'C:\Program Files\Vendor\App\app.exe'

      $Run = Invoke-StopApplication -Root 'C:\Program Files\Vendor\App'

      $Run.ExitCode | Should -Be 0
      @($Run.Result.stopped_processes.process_id) | Should -Be @(100)
    }

    It 'succeeds with nothing stopped when a root does not exist, and lists it' {
      $Run = Invoke-StopApplication -Root 'C:\NotInstalled'

      $Run.ExitCode | Should -Be 0
      $Run.Result.missing_roots | Should -Be @('C:\NotInstalled')
      $Run.Result.changed | Should -BeFalse
      $global:StopApplicationCalls | Should -HaveCount 0
    }
  }

  Context 'check mode and convergence' {
    It 'stops nothing under -WhatIf and lists what it would stop' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeProcess -Id 101 -Path 'C:\App\app.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100

      $Run = Invoke-StopApplication -Root 'C:\App' -WhatIf

      $Run.ExitCode | Should -Be 0
      $Run.Result.changed | Should -BeFalse
      $Run.Result.check_mode | Should -BeTrue
      @($Run.Result.would_stop) | Should -Be @('service AppSvc', 'process app.exe (101)')
      $global:StopApplicationCalls | Should -HaveCount 0
    }

    It 'reports no change on a second run' {
      Add-FakeProcess -Id 100 -Path 'C:\App\svc.exe'
      Add-FakeProcess -Id 101 -Path 'C:\App\app.exe'
      Add-FakeService -Name 'AppSvc' -HostId 100

      $First = Invoke-StopApplication -Root 'C:\App'
      $Second = Invoke-StopApplication -Root 'C:\App'

      $First.Result.changed | Should -BeTrue
      $Second.ExitCode | Should -Be 0
      $Second.Result.changed | Should -BeFalse
    }
  }
}
