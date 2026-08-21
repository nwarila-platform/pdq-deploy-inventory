#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Seeds the console preferences every NEW user profile starts from.

    .DESCRIPTION
        A handful of console preferences are per-user: the product writes them to the user's own
        registry hive when the preferences page is saved, and nothing else ever sets them --
        measured 2026-08-21 against a console flipping every page. A converge cannot reach into
        profiles that do not exist yet, but Windows builds every new profile from the Default
        profile's hive, so seeding that ONE file gives every future console user the deployment's
        chosen starting point. Existing profiles are deliberately untouched: a preference a user
        has already saved is that user's, not the deployment's.

        The hive is loaded from the Default profile's NTUSER.DAT under a private mount name, the
        values compared and written, the result read back, and the hive ALWAYS unloaded -- a hive
        left mounted would block every future logon from copying it. Values and key paths are the
        measured ones the console itself writes: the splash and theme under the console's Startup
        key, the update checks under the product's AutoUpdateChecker key.

        The account the build CONNECTS as is the one profile that always predates this task:
        its profile is born the moment the transport first signs in, minutes before any seeding
        runs, so it can never inherit the Default hive. Its own hive is therefore stamped too --
        but only values the product has never written there; a preference any user has saved is
        that user's, and stays.

        Org scripts are a single straightforward process stage: [ Initialization ], [ Main ]
        (read -> compare -> apply -> verify -> ONE result object), [ Output ]. Developed under
        scripts/ with the sibling Set-PdqConsoleDefault.pester.ps1 spec; the role tracks only
        files/Set-PdqConsoleDefault.ps1.stub, resolved by the build.

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging functions, one digit each.
        First digit: ErrorActionPreference (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire,
        4 Ignore, 5 Suspend). Second digit: Set-PSDebug (0 off, 1 trace 1, 2 trace 2,
        3 trace 1 + step, 4 trace 2 + step). Third digit: Set-StrictMode (0 off, 1-3 that
        version). Default '103': stop on error, no tracing, strict mode 3.

    .PARAMETER LogLevel
        Six-digit control string setting the preference for each stream, in the order Verbose,
        Debug, Information, Warning, Error, Fatal. Each digit is an ActionPreference
        (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire, 4 Ignore, 5 Suspend).

    .PARAMETER DisableSplashScreen
        Whether new users' consoles skip the splash screen. The product ships showing it.

    .PARAMETER AutoUpdateCheckEnabled
        Whether new users' consoles quietly check for product updates. The product ships checking.

    .PARAMETER ShowWebcastAlerts
        Whether new users' consoles surface vendor webcast alerts. The product ships showing them.

    .PARAMETER ColorTheme
        The console theme new users start on. Omit to leave the product's own first-run choice.

    .EXAMPLE
        .\Set-PdqConsoleDefault.ps1 -DisableSplashScreen:$True -AutoUpdateCheckEnabled:$False -ShowWebcastAlerts:$False

    .OUTPUTS
        One object carrying changed, check_mode, seeded and msg.
#>

[CmdletBinding()]
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
  [System.Boolean]
  $DisableSplashScreen,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $AutoUpdateCheckEnabled,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $ShowWebcastAlerts,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [AllowNull()]
  [AllowEmptyString()]
  [System.String]
  $ColorTheme = $Null
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# The Default profile's hive, the transient name it mounts under, and the two keys the console
# writes -- all fixed, all measured 2026-08-21 from a console saving its preferences.
New-Variable -Force -Name:'REG_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Windows\System32\reg.exe'
)
New-Variable -Force -Name:'HIVE_FILE' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Users\Default\NTUSER.DAT'
)
New-Variable -Force -Name:'MOUNT' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'HKU\PdqDefaultSeed'
)
New-Variable -Force -Name:'STARTUP_KEY' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'Registry::HKEY_USERS\PdqDefaultSeed\Software\Admin Arsenal\PDQ Deploy Console\Settings\Startup'
)
New-Variable -Force -Name:'CHECKER_KEY' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'Registry::HKEY_USERS\PdqDefaultSeed\Software\Admin Arsenal\PDQ Deploy\AutoUpdateChecker'
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

# Universal trap used to help with debugging efforts. The original template's
# Wait-Debugger/Exit are interactive-host machinery; under the Ansible
# transport the trap logs and rethrows (Break) so the task fails honestly.
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

# Under win_powershell the transport provides $Ansible; standalone (a dev
# shell or a Pester spec) it does not, so the script creates a faithful stub.
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# What the seed should say, as key/name/value rows. Booleans travel as the dwords the console
# itself writes; the theme row exists only when a theme was asked for.
$Rows = [System.Collections.Generic.List[System.Object]]::new()
$Rows.Add(@{ Key = $STARTUP_KEY; Name = 'Disable Splash Screen'; Value = [System.Int32]$DisableSplashScreen })
$Rows.Add(@{ Key = $CHECKER_KEY; Name = 'Auto Check Enabled'; Value = [System.Int32]$AutoUpdateCheckEnabled })
$Rows.Add(@{ Key = $CHECKER_KEY; Name = 'Show Webcast Alerts'; Value = [System.Int32]$ShowWebcastAlerts })
If (-not [System.String]::IsNullOrEmpty($ColorTheme)) {
  $Rows.Add(@{ Key = $STARTUP_KEY; Name = 'Color Theme'; Value = [System.String]$ColorTheme })
}

# Load, work, ALWAYS unload: a Default hive left mounted blocks every future logon from copying
# it, so the unload sits in Finally and its failure is loud. The handle the provider keeps is
# released by the collector first, or the unload reports the hive busy.
$Null = & $REG_PATH 'load' $MOUNT $HIVE_FILE 2>&1
If ($LASTEXITCODE -ne 0) {
  Throw ('Loading {0} failed with exit code {1}' -f $HIVE_FILE, $LASTEXITCODE)
}
$Changed = $False
Try {
  ForEach ($Row In $Rows) {
    $Current = $Null
    If (Test-Path -LiteralPath:$Row.Key) {
      $Item = Get-ItemProperty -LiteralPath:$Row.Key -ErrorAction:'SilentlyContinue'
      If ($Null -ne $Item -and $Item.PSObject.Properties.Match($Row.Name).Count -gt 0) {
        $Current = $Item.($Row.Name)
      }
    }
    If ([System.String]$Current -eq [System.String]$Row.Value) {
      Continue
    }
    $Changed = $True
    If ($Ansible.CheckMode) {
      Continue
    }
    If (-not (Test-Path -LiteralPath:$Row.Key)) {
      $Null = New-Item -Path:$Row.Key -Force
    }
    $Type = If ($Row.Value -is [System.Int32]) { 'DWord' } Else { 'String' }
    $Null = New-ItemProperty -LiteralPath:$Row.Key -Name:$Row.Name -Value:$Row.Value -PropertyType:$Type -Force

    # Prove it: the value must read back exactly as asked, or the run fails rather than
    # reporting a change that did not happen. Probed through the property LIST first, because a
    # value that never landed has no property to read and strict mode would name that instead of
    # the real failure.
    $Written = Get-ItemProperty -LiteralPath:$Row.Key
    $ReadBack = If ($Written.PSObject.Properties.Match($Row.Name).Count -gt 0) {
      $Written.($Row.Name)
    } Else {
      $Null
    }
    If ([System.String]$ReadBack -ne [System.String]$Row.Value) {
      Throw ('{0} did not read back as written' -f $Row.Name)
    }
  }
} Finally {
  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()
  $Null = & $REG_PATH 'unload' $MOUNT 2>&1
  If ($LASTEXITCODE -ne 0) {
    Write-Warning -Message:('Unloading {0} failed with exit code {1}' -f $MOUNT, $LASTEXITCODE)
  }
}

# The connection account's own profile predates every converge, so the Default seed can never
# reach it. Stamp the same values into its live hive -- but ONLY names the product has never
# written there: presence means somebody chose, and a chosen preference is not the deployment's.
ForEach ($Row In $Rows) {
  $OwnKey = $Row.Key -replace '^Registry::HKEY_USERS\\PdqDefaultSeed', 'HKCU:'
  $Have = $Null
  If (Test-Path -LiteralPath:$OwnKey) {
    $Item = Get-ItemProperty -LiteralPath:$OwnKey -ErrorAction:'SilentlyContinue'
    If ($Null -ne $Item -and $Item.PSObject.Properties.Match($Row.Name).Count -gt 0) {
      $Have = $Item.($Row.Name)
    }
  }
  If ($Null -ne $Have) {
    Continue
  }
  $Changed = $True
  If ($Ansible.CheckMode) {
    Continue
  }
  If (-not (Test-Path -LiteralPath:$OwnKey)) {
    $Null = New-Item -Path:$OwnKey -Force
  }
  $Type = If ($Row.Value -is [System.Int32]) { 'DWord' } Else { 'String' }
  $Null = New-ItemProperty -LiteralPath:$OwnKey -Name:$Row.Name -Value:$Row.Value -PropertyType:$Type -Force
}

$Ansible.Changed = $Changed
$Result = [ordered]@{
  changed    = $Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  seeded     = @($Rows | ForEach-Object -Process { $PSItem.Name })
  msg        = If ($Changed) { 'default profile seeded' } Else { 'default profile already seeded' }
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

If ($StandaloneRun) {
  Write-Output -InputObject:([PSCustomObject]$Result | ConvertTo-Json -Depth:3)
} Else {
  $Ansible.Result = $Result
}

#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
