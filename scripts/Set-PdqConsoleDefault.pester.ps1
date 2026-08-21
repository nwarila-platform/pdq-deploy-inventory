#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqConsoleDefault.ps1 (org pair convention: every
    script ships with a sibling <Name>.pester.ps1; the pester-matrix workflow
    runs one leg per pair).

    Runs anywhere, Linux CI included: the script touches the platform through
    reg.exe (a FUNCTION named with its literal path, because the call operator
    resolves a path-shaped string to a function first) and the item cmdlets,
    stubbed here over an in-memory hive. The stubs THROW when the hive is not
    loaded, which is what proves the script's ordering: nothing reads or
    writes outside the load/unload bracket, and the unload happens even when a
    write fails mid-flight.

    Stub state lives in $global: variables because inside a function called
    from a child SCRIPT, $script: resolves to the child script's own scope,
    not this file's.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PdqConsoleDefault.ps1'
  $script:Startup = 'Registry::HKEY_USERS\PdqDefaultSeed\Software\Admin Arsenal\PDQ Deploy Console\Settings\Startup'
  $script:Checker = 'Registry::HKEY_USERS\PdqDefaultSeed\Software\Admin Arsenal\PDQ Deploy\AutoUpdateChecker'

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Function Assert-HiveLoaded {
    Param ([System.String]$At)
    # HKCU is the caller's own always-mounted hive; only the transient mount is gated.
    If ($At -notlike 'HKCU:*' -and -not $global:FakeHiveLoaded) { Throw 'hive is not loaded' }
  }

  # reg.exe: load flips the gate open, unload flips it shut. The load can be
  # told to fail, which must stop the run before any hive access. Created on the
  # function: drive because the name is path-shaped; container scope, like every
  # stub here, so nothing outlives the run -- the global: variant outlived it,
  # and broke whatever the shared session ran next.
  New-Item -Force -Path 'function:C:\Windows\System32\reg.exe' -Value {
    $global:RegCalls += , @($args)
    If ($args[0] -eq 'load') {
      If ($global:FakeLoadFails) { $global:LASTEXITCODE = 1; Return }
      $global:FakeHiveLoaded = $True
    } ElseIf ($args[0] -eq 'unload') {
      $global:FakeHiveLoaded = $False
    }
    $global:LASTEXITCODE = 0
  } | Out-Null

  Function Test-Path {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    Assert-HiveLoaded -At:$LiteralPath
    $global:FakeHive.Contains($LiteralPath)
  }

  Function Get-ItemProperty {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    Assert-HiveLoaded -At:$LiteralPath
    If (-not $global:FakeHive.Contains($LiteralPath)) { Return $Null }
    [PSCustomObject]$global:FakeHive[$LiteralPath]
  }

  Function New-Item {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$Path, [Switch]$Force)
    Assert-HiveLoaded -At:$Path
    If (-not $global:FakeHive.Contains($Path)) { $global:FakeHive[$Path] = @{} }
  }

  Function New-ItemProperty {
    [CmdletBinding()]
    Param (
      [Parameter()] [System.String]$LiteralPath,
      [Parameter()] [System.String]$Name,
      [Parameter()] [System.Object]$Value,
      [Parameter()] [System.String]$PropertyType,
      [Switch]$Force
    )
    Assert-HiveLoaded -At:$LiteralPath
    $global:WriteCalls += 1
    If (-not $global:FakeWriteIgnored) { $global:FakeHive[$LiteralPath][$Name] = $Value }
  }
}

Describe 'Set-PdqConsoleDefault' {
  BeforeEach {
    $global:FakeHive = @{}
    $global:FakeHiveLoaded = $False
    $global:FakeLoadFails = $False
    $global:FakeWriteIgnored = $False
    $global:RegCalls = @()
    $global:WriteCalls = 0
    Remove-AnsibleContext
  }

  It 'seeds the three update and splash values and unloads the hive' {
    $Result = & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False |
      ConvertFrom-Json
    $Result.changed | Should -BeTrue
    $global:FakeHive[$script:Startup]['Disable Splash Screen'] | Should -Be 1
    $global:FakeHive[$script:Checker]['Auto Check Enabled'] | Should -Be 0
    $global:FakeHive[$script:Checker]['Show Webcast Alerts'] | Should -Be 0
    $global:FakeHiveLoaded | Should -BeFalse
    @($global:RegCalls)[-1][0] | Should -Be 'unload'
  }

  It 'stamps the connection account only where the product has never written' {
    $Own = 'HKCU:\Software\Admin Arsenal\PDQ Deploy Console\Settings\Startup'
    $global:FakeHive[$Own] = @{ 'Disable Splash Screen' = 0 }
    $Null = & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False
    # the saved 0 is somebody's choice and stays; the never-written checker values arrive
    $global:FakeHive[$Own]['Disable Splash Screen'] | Should -Be 0
    $global:FakeHive['HKCU:\Software\Admin Arsenal\PDQ Deploy\AutoUpdateChecker']['Auto Check Enabled'] | Should -Be 0
  }

  It 'writes the theme and the channel only when asked for' {
    $Null = & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False
    $global:FakeHive[$script:Startup].Contains('Color Theme') | Should -BeFalse
    $global:FakeHive[$script:Checker].Contains('ReleaseChannel') | Should -BeFalse
    $Null = & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False -ColorTheme 'Win11Dark' -ReleaseChannel 'Beta'
    $global:FakeHive[$script:Startup]['Color Theme'] | Should -Be 'Win11Dark'
    $global:FakeHive[$script:Checker]['ReleaseChannel'] | Should -Be 'Beta'
  }

  It 'changes nothing and writes nothing the second time' {
    $Null = & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False
    $global:WriteCalls = 0
    $Result = & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False |
      ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:WriteCalls | Should -Be 0
  }

  It 'stops before touching the hive when the load fails' {
    $global:FakeLoadFails = $True
    { & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False 2>$null } |
      Should -Throw '*exit code 1*'
    $global:WriteCalls | Should -Be 0
  }

  It 'unloads the hive even when a write does not take' {
    $global:FakeWriteIgnored = $True
    { & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False 2>$null } |
      Should -Throw '*did not read back*'
    $global:FakeHiveLoaded | Should -BeFalse
    @($global:RegCalls)[-1][0] | Should -Be 'unload'
  }

  Context '$Ansible transport' {
    AfterEach { Remove-AnsibleContext }

    It 'sets Changed=$False explicitly when the seed is already present' {
      $Null = & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False
      $Context = New-AnsibleContext
      & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False
      $Context.Changed | Should -BeFalse
    }

    It 'reports the would-be change in check mode, writes nothing, still unloads' {
      $Null = New-AnsibleContext -CheckMode
      & $script:ScriptPath -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False
      $global:Ansible.Changed | Should -BeTrue
      $global:WriteCalls | Should -Be 0
      $global:FakeHiveLoaded | Should -BeFalse
    }
  }
}
