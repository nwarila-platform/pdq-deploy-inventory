#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Removes selected machine registrations from one product family.

    .DESCRIPTION
        Reads both machine uninstall roots, loads the requested registry
        properties by name, and synthesizes ParentKey and AppArch. The
        DisplayName wildcard remains the product-family matcher; Include and
        Exclude criteria select registrations from that family by wildcard
        matching against the loaded properties.

        With no criteria, a registration whose uninstall subkey is a braced
        GUID is retained as conforming, exactly as in the legacy default path.
        Supplying Exclude opts into considering conforming registrations for
        removal; matching exclusions are retained and every other selected
        registration is removed. Include alone narrows the non-conforming
        registrations considered by the default path.

        A selected MSI registration is removed through msiexec with its
        synthesized ParentKey. Other selected registrations use their recorded
        QuietUninstallString, or their UninstallString plus the supplied silent
        switch.

        A bare UninstallString is never guessed at: when no quiet command and
        no silent switch are available, the registration is refused and the
        script fails. An MSI registration whose UninstallString does not name
        msiexec is also refused. After all attempts, the uninstall roots are
        read again; any surviving selected registration fails the script.

        The result reports registration identities and outcomes, never the
        recorded command lines. The script does not remove anything outside the
        family pattern or user data.

    .PARAMETER DebugLevel
        Three-digit control string configuring ErrorActionPreference,
        Set-PSDebug, and Set-StrictMode. Default '103'.

    .PARAMETER DisplayNamePattern
        PowerShell wildcard pattern matching the product family's Add/Remove
        Programs DisplayName values.

    .PARAMETER Exclude
        Property names and wildcard values that retain a registration when all
        entries match. Every named property must be present in Property and
        every value must be a non-empty string. Supplying Exclude opts into
        considering conforming MSI registrations; without it, they are retained.

    .PARAMETER Include
        Property names and wildcard values that select a registration when all
        entries match. Every named property must be present in Property and
        every value must be a non-empty string.

    .PARAMETER LogLevel
        Six-digit control string mapping Verbose, Debug, Information, Warning,
        Error, and Fatal streams to ActionPreference values.

    .PARAMETER Property
        Registry value names to load for every family registration. ParentKey
        and AppArch are synthesized rather than read from the registry. The
        properties required to identify and uninstall registrations must remain
        in the list; additional registry values can be added for criteria.

    .PARAMETER SilentSwitch
        Silent argument appended only when a matching registration has no
        QuietUninstallString and its UninstallString must be used.

    .PARAMETER SuccessExitCode
        Exit codes accepted from an uninstaller. Defaults to the conventional
        success, reboot-initiated, and reboot-required codes.

    .EXAMPLE
        PS> ./Start-Uninstaller.ps1 -DisplayNamePattern '7-Zip*' -SilentSwitch '/S'

    .EXAMPLE
        PS> $Keep = @{ ParentKey = '{00000000-0000-0000-0000-000000000000}' }
        PS> ./Start-Uninstaller.ps1 -DisplayNamePattern 'Google Chrome*' -Exclude $Keep

    .OUTPUTS
        One JSON result object when run standalone; the same object through
        the Ansible transport when that transport is present.
    #>
[CmdletBinding(
  ConfirmImpact = 'Medium',
  DefaultParameterSetName = 'default',
  HelpUri = '',
  PositionalBinding = $False,
  RemotingCapability = 'PowerShell',
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
  [System.String]
  $DisplayNamePattern,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Collections.Hashtable]
  $Exclude,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Collections.Hashtable]
  $Include,

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
  [ValidateNotNullOrEmpty()]
  [System.String[]]
  $Property = @(
    'DisplayName'
    'ParentKey'
    'QuietUninstallString'
    'UninstallString'
    'AppArch'
  ),

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [AllowEmptyString()]
  [System.String]
  $SilentSwitch = [System.String]::Empty,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.Int32[]]
  $SuccessExitCode = @(0, 1641, 3010)
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Messages ] ------------------------------------------------------------------ #
[System.Collections.Hashtable]$Script:Message = @{
  'Start-Uninstaller.CheckMode'       = 'Check mode: would process {0} non-conforming registration(s) matching {1}; {2} unsafe command(s) were refused.'
  'Start-Uninstaller.CheckModeFilter' = 'Check mode: would process {0} selected registration(s) matching {1}; {2} unsafe command(s) were refused.'
  'Start-Uninstaller.Converged'       = 'Removed {0} non-conforming registration(s) matching {1}; retained {2} conforming registration(s).'
  'Start-Uninstaller.ConvergedFilter' = 'Removed {0} selected registration(s) matching {1}; retained {2} registration(s) outside the selection.'
  'Start-Uninstaller.Failed'          = 'Removal did not converge for {0}: {1} non-conforming registration(s) survived and {2} command failure(s) were recorded.'
  'Start-Uninstaller.FailedFilter'    = 'Removal did not converge for {0}: {1} selected registration(s) survived and {2} command failure(s) were recorded.'
  'Start-Uninstaller.InvalidCommand'  = '{0}: the recorded uninstall command does not identify an executable.'
  'Start-Uninstaller.NoCommand'       = '{0}: no QuietUninstallString or UninstallString is recorded; refusing to invent an uninstall command.'
  'Start-Uninstaller.NoSilentCommand' = '{0}: no QuietUninstallString exists and no silent switch was supplied; refusing the interactive uninstall command.'
  'Start-Uninstaller.ProcessFailed'   = '{0}: the uninstaller could not be started ({1}).'
  'Start-Uninstaller.ProcessResult'   = '{0}: the uninstaller exited with unaccepted code {1}.'
  'Start-Uninstaller.ShouldProcess'   = 'Run the registration''s recorded silent uninstall command'
  'Start-Uninstaller.TrapCommand'     = 'Failed to execute command: {0}'
  'Start-Uninstaller.TrapRecord'      = '[{0:0000}] {1} [{2}]'
  'Start-Uninstaller.TrapUnavailable' = 'Trap diagnostics unavailable for this error record.'
  'Start-Uninstaller.UnsupportedMsi'  = '{0}: the MSI registration does not record an msiexec uninstall command.'
}
#endregion --- [ Messages ] ------------------------------------------------------------------ #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

[System.String[]]$Private:LogLevels = @(
  'Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal'
)
[System.Management.Automation.ActionPreference]$Private:ErrorPreference = (
  [System.Management.Automation.ActionPreference]::Stop
)
[System.Management.Automation.ActionPreference]$Private:FatalPreference = (
  [System.Management.Automation.ActionPreference]::Stop
)
Write-Debug -Message:('Custom stream preferences: Error={0}; Fatal={1}.' -f @(
    $ErrorPreference
    $FatalPreference
  ))

For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LogLevels[$L]) -Value:(
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
      Write-Debug -Message:($Script:Message['Start-Uninstaller.TrapCommand'] -f @(
          [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
        ))
    }

    Write-Warning -Message:($Script:Message['Start-Uninstaller.TrapRecord'] -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      ))
  } Catch {
    Write-Debug -Message:($Script:Message['Start-Uninstaller.TrapUnavailable'])
  }

  Break
}

[System.Boolean]$Private:StandaloneRun = $Null -eq (
  Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue'
)
If ($StandaloneRun) {
  [PSCustomObject]$Private:Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

[System.String]$Private:NormalizedDisplayNamePattern = $DisplayNamePattern.Trim()
[System.String]$Private:NormalizedSilentSwitch = $SilentSwitch.Trim()
If ([System.String]::IsNullOrWhiteSpace($NormalizedDisplayNamePattern)) {
  Throw 'DisplayNamePattern must contain a non-whitespace wildcard pattern.'
}

[System.Boolean]$Private:HasCriteria = (
  $PSBoundParameters.ContainsKey('Include') -or
  $PSBoundParameters.ContainsKey('Exclude')
)
[System.Collections.Generic.HashSet[System.String]]$Private:LoadedPropertyName = (
  [System.Collections.Generic.HashSet[System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
)
[System.String[]]$Private:RequiredProperty = @(
  'DisplayName'
  'ParentKey'
  'QuietUninstallString'
  'UninstallString'
  'AppArch'
)

ForEach ($PropertyName In $Property) {
  If ([System.String]::IsNullOrWhiteSpace($PropertyName)) {
    Throw 'Property must contain only non-whitespace property names.'
  }
  If (-not $LoadedPropertyName.Add($PropertyName)) {
    Throw ('Property contains the duplicate name {0}.' -f $PropertyName)
  }
}
ForEach ($PropertyName In $RequiredProperty) {
  If (-not $LoadedPropertyName.Contains($PropertyName)) {
    Throw ('Property must include the script-required property {0}.' -f $PropertyName)
  }
}

ForEach ($CriterionName In @('Include', 'Exclude')) {
  If (-not $PSBoundParameters.ContainsKey($CriterionName)) {
    Continue
  }

  [System.Collections.Hashtable]$Private:Criterion = Get-Variable `
    -Name:$CriterionName `
    -ValueOnly
  If ($Null -eq $Criterion -or $Criterion.Count -eq 0) {
    Throw ('{0} must contain at least one property criterion.' -f $CriterionName)
  }

  ForEach ($CriterionProperty In $Criterion.Keys) {
    If (
      $CriterionProperty -isnot [System.String] -or
      [System.String]::IsNullOrWhiteSpace([System.String]$CriterionProperty)
    ) {
      Throw ('{0} property names must be non-whitespace strings.' -f $CriterionName)
    }
    If (-not $LoadedPropertyName.Contains([System.String]$CriterionProperty)) {
      Throw ('{0} names unloaded property {1}.' -f @(
          $CriterionName
          $CriterionProperty
        ))
    }

    [System.Object]$Private:CriterionValue = $Criterion[$CriterionProperty]
    If (
      $CriterionValue -isnot [System.String] -or
      [System.String]::IsNullOrWhiteSpace([System.String]$CriterionValue)
    ) {
      Throw ('{0} criterion {1} must be a non-whitespace string.' -f @(
          $CriterionName
          $CriterionProperty
        ))
    }
    Try {
      $Null = [System.Management.Automation.WildcardPattern]::new(
        [System.String]$CriterionValue
      ).IsMatch([System.String]::Empty)
    } Catch {
      Throw ('{0} criterion {1} is not a valid wildcard pattern.' -f @(
          $CriterionName
          $CriterionProperty
        ))
    }
  }
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

Function Get-FamilyRegistration {
  [CmdletBinding(
    ConfirmImpact = 'None',
    DefaultParameterSetName = 'default',
    HelpUri = '',
    PositionalBinding = $False,
    SupportsPaging = $False,
    SupportsShouldProcess = $False
  )]
  [OutputType([PSCustomObject[]])]
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
    $DisplayNamePattern,

    [Parameter(
      DontShow = $False,
      Mandatory = $True,
      ParameterSetName = 'default',
      ValueFromPipeline = $False,
      ValueFromPipelineByPropertyName = $False
    )]
    [ValidateNotNullOrEmpty()]
    [System.String[]]
    $Property,

    [Parameter(
      DontShow = $False,
      Mandatory = $True,
      ParameterSetName = 'default',
      ValueFromPipeline = $False,
      ValueFromPipelineByPropertyName = $False
    )]
    [ValidateNotNullOrEmpty()]
    [System.String[]]
    $UninstallRoot
  )
  Write-Debug -Message:'[Get-FamilyRegistration] Entering'

  [System.Management.Automation.PSPropertyInfo]$Private:DisplayNameProperty = $Null
  [System.Guid]$Private:Guid = [System.Guid]::Empty
  [System.Boolean]$Private:IsConforming = $False
  [System.Collections.Specialized.OrderedDictionary]$Private:Loaded = $Null
  [System.String]$Private:LoadedAppArch = [System.String]::Empty
  [System.Object]$Private:LoadedValue = $Null
  [PSCustomObject]$Private:RawRegistration = $Null
  [System.Collections.Generic.List[System.Object]]$Private:Registrations = (
    [System.Collections.Generic.List[System.Object]]::new()
  )
  [PSCustomObject[]]$Private:Result = @()
  [System.Management.Automation.PSPropertyInfo]$Private:ValueProperty = $Null

  ForEach ($Root In $UninstallRoot) {
    If (-not (Test-Path -LiteralPath:$Root)) {
      Write-Debug -Message:('Skipping absent uninstall root: {0}' -f $Root)
      Continue
    }

    ForEach ($Key In (Get-ChildItem -LiteralPath:$Root -ErrorAction:'Stop')) {
      $RawRegistration = Get-ItemProperty -LiteralPath:$Key.PSPath -ErrorAction:'Stop'
      If ($Null -eq $RawRegistration) {
        Continue
      }

      $DisplayNameProperty = $RawRegistration.PSObject.Properties['DisplayName']
      If (
        $Null -eq $DisplayNameProperty -or
        [System.String]$DisplayNameProperty.Value -notlike $DisplayNamePattern
      ) {
        Continue
      }

      $Guid = [System.Guid]::Empty
      $IsConforming = [System.Guid]::TryParseExact(
        [System.String]$Key.PSChildName,
        'B',
        [Ref]$Guid
      )

      If (
        $Root -eq $UninstallRoot[0] -and
        [System.Environment]::Is64BitOperatingSystem
      ) {
        $LoadedAppArch = 'x64'
      } Else {
        $LoadedAppArch = 'x86'
      }

      $Loaded = [Ordered]@{}
      ForEach ($PropertyName In $Property) {
        $LoadedValue = $Null
        Switch ($PropertyName) {
          'ParentKey' {
            $LoadedValue = [System.String]$Key.PSChildName
            Break
          }
          'AppArch' {
            $LoadedValue = $LoadedAppArch
            Break
          }
          Default {
            $ValueProperty = $RawRegistration.PSObject.Properties[$PropertyName]
            If ($Null -ne $ValueProperty) {
              $LoadedValue = $ValueProperty.Value
            }
          }
        }
        $Loaded[$PropertyName] = $LoadedValue
      }

      $Registrations.Add([PSCustomObject]@{
          display_name           = [System.String]$Loaded['DisplayName']
          is_conforming          = $IsConforming
          key_name               = [System.String]$Loaded['ParentKey']
          properties             = [PSCustomObject]$Loaded
          quiet_uninstall_string = [System.String]$Loaded['QuietUninstallString']
          registry_path          = [System.String]$Key.PSPath
          uninstall_string       = [System.String]$Loaded['UninstallString']
        })
    }
  }

  [PSCustomObject[]]$Result = @(
    $Registrations.ToArray() | Sort-Object -Property:@('display_name', 'registry_path')
  )
  $Result

  Write-Debug -Message:'[Get-FamilyRegistration] Exiting'
}

Function Test-RegistrationCriterion {
  [CmdletBinding(
    ConfirmImpact = 'None',
    DefaultParameterSetName = 'default',
    HelpUri = '',
    PositionalBinding = $False,
    SupportsPaging = $False,
    SupportsShouldProcess = $False
  )]
  [OutputType([System.Boolean])]
  Param (
    [Parameter(
      DontShow = $False,
      Mandatory = $True,
      ParameterSetName = 'default',
      ValueFromPipeline = $False,
      ValueFromPipelineByPropertyName = $False
    )]
    [System.Collections.Hashtable]
    $Criterion,

    [Parameter(
      DontShow = $False,
      Mandatory = $True,
      ParameterSetName = 'default',
      ValueFromPipeline = $False,
      ValueFromPipelineByPropertyName = $False
    )]
    [PSCustomObject]
    $Registration
  )
  Write-Debug -Message:'[Test-RegistrationCriterion] Entering'

  [System.Object]$Private:ActualValue = $Null
  [System.Management.Automation.PSPropertyInfo]$Private:LoadedProperty = $Null

  ForEach ($CriterionProperty In $Criterion.Keys) {
    $LoadedProperty = $Registration.properties.PSObject.Properties[[System.String]$CriterionProperty]
    $ActualValue = $LoadedProperty.Value
    If ([System.String]$ActualValue -notlike [System.String]$Criterion[$CriterionProperty]) {
      Return $False
    }
  }

  Write-Debug -Message:'[Test-RegistrationCriterion] Exiting'
  $True
}

[PSCustomObject[]]$Private:After = @()
[System.Collections.Generic.HashSet[System.String]]$Private:AfterPath = (
  [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::OrdinalIgnoreCase)
)
[System.String]$Private:Arguments = [System.String]::Empty
[PSCustomObject[]]$Private:Before = @()
[System.Boolean]$Private:CheckMode = [System.Boolean](
  $Ansible.CheckMode -or $WhatIfPreference
)
[System.String]$Private:CommandLine = [System.String]::Empty
[System.Text.RegularExpressions.Match]$Private:CommandMatch = $Null
[System.Int32]$Private:ClosingQuote = -1
[System.String]$Private:Executable = [System.String]::Empty
[System.Int32]$Private:ExitCode = 0
[System.Collections.Generic.List[System.String]]$Private:Failure = (
  [System.Collections.Generic.List[System.String]]::new()
)
[System.Boolean]$Private:Failed = $False
[System.Boolean]$Private:HasExcludeCriterion = $PSBoundParameters.ContainsKey('Exclude')
[System.Boolean]$Private:HasIncludeCriterion = $PSBoundParameters.ContainsKey('Include')
[System.String]$Private:OutcomeMessage = [System.String]::Empty
[System.String]$Private:OutcomeMessageKey = [System.String]::Empty
[System.Object]$Private:Process = $Null
[PSCustomObject]$Private:PublicRegistration = $Null
[System.Collections.Generic.List[System.Object]]$Private:Removed = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.Collections.Generic.List[System.Object]]$Private:Retained = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[PSCustomObject]$Private:Result = $Null
[System.Int32]$Private:SelectedCount = 0
[System.Collections.Generic.HashSet[System.String]]$Private:SelectedPath = (
  [System.Collections.Generic.HashSet[System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
)
[System.Collections.Generic.List[System.Object]]$Private:Survived = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.String[]]$Private:UninstallRoots = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$Before = @(
  Get-FamilyRegistration `
    -DisplayNamePattern:$NormalizedDisplayNamePattern `
    -Property:$Property `
    -UninstallRoot:$UninstallRoots
)

ForEach ($Registration In $Before) {
  If ($Registration.is_conforming -and -not $HasExcludeCriterion) {
    Continue
  }
  If (
    $HasIncludeCriterion -and
    -not (Test-RegistrationCriterion -Criterion:$Include -Registration:$Registration)
  ) {
    Continue
  }
  If (
    $HasExcludeCriterion -and
    (Test-RegistrationCriterion -Criterion:$Exclude -Registration:$Registration)
  ) {
    Continue
  }

  $SelectedCount++
  $Null = $SelectedPath.Add($Registration.registry_path)
  $CommandLine = [System.String]::Empty
  If ($Registration.is_conforming) {
    If ([System.String]::IsNullOrWhiteSpace($Registration.uninstall_string)) {
      $Failure.Add($Script:Message['Start-Uninstaller.NoCommand'] -f @(
          $Registration.display_name
        ))
      Continue
    }
    $CommandLine = $Registration.uninstall_string.Trim()
  } ElseIf (-not [System.String]::IsNullOrWhiteSpace(
      $Registration.quiet_uninstall_string
    )) {
    $CommandLine = $Registration.quiet_uninstall_string.Trim()
  } ElseIf (
    -not [System.String]::IsNullOrWhiteSpace($Registration.uninstall_string) -and
    -not [System.String]::IsNullOrWhiteSpace($NormalizedSilentSwitch)
  ) {
    $CommandLine = '{0} {1}' -f @(
      $Registration.uninstall_string.Trim()
      $NormalizedSilentSwitch
    )
  } ElseIf ([System.String]::IsNullOrWhiteSpace($Registration.uninstall_string)) {
    $Failure.Add($Script:Message['Start-Uninstaller.NoCommand'] -f @(
        $Registration.display_name
      ))
    Continue
  } Else {
    $Failure.Add($Script:Message['Start-Uninstaller.NoSilentCommand'] -f @(
        $Registration.display_name
      ))
    Continue
  }

  $Arguments = [System.String]::Empty
  $Executable = [System.String]::Empty
  If ($CommandLine.StartsWith('"', [System.StringComparison]::Ordinal)) {
    $ClosingQuote = $CommandLine.IndexOf('"', 1)
    If ($ClosingQuote -gt 1) {
      $Executable = $CommandLine.Substring(1, $ClosingQuote - 1)
      $Arguments = $CommandLine.Substring($ClosingQuote + 1).Trim()
    }
  } Else {
    $CommandMatch = [System.Text.RegularExpressions.Regex]::Match(
      $CommandLine,
      '^(?<Executable>.+?\.exe)(?:\s+(?<Arguments>.*))?$',
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    If ($CommandMatch.Success) {
      $Executable = $CommandMatch.Groups['Executable'].Value.Trim()
      $Arguments = $CommandMatch.Groups['Arguments'].Value.Trim()
    }
  }

  If ([System.String]::IsNullOrWhiteSpace($Executable)) {
    $Failure.Add($Script:Message['Start-Uninstaller.InvalidCommand'] -f @(
        $Registration.display_name
      ))
    Continue
  }
  If ($Registration.is_conforming) {
    If ($Executable -notmatch '(^|[\\/])msiexec(?:\.exe)?$') {
      $Failure.Add($Script:Message['Start-Uninstaller.UnsupportedMsi'] -f @(
          $Registration.display_name
        ))
      Continue
    }
    $Executable = '{0}\System32\msiexec.exe' -f $ENV:WINDIR
    $Arguments = '/x {0} /qn /norestart' -f $Registration.key_name
  } Else {
    $Executable = [System.Environment]::ExpandEnvironmentVariables($Executable)
  }

  If ($CheckMode) {
    Continue
  }
  If (-not $PSCmdlet.ShouldProcess(
      $Registration.display_name,
      $Script:Message['Start-Uninstaller.ShouldProcess']
    )) {
    Continue
  }

  Try {
    If ([System.String]::IsNullOrWhiteSpace($Arguments)) {
      $Process = Start-Process `
        -FilePath:$Executable `
        -PassThru `
        -Wait `
        -ErrorAction:'Stop'
    } Else {
      $Process = Start-Process `
        -FilePath:$Executable `
        -ArgumentList:$Arguments `
        -PassThru `
        -Wait `
        -ErrorAction:'Stop'
    }
    $ExitCode = [System.Int32]$Process.ExitCode
    If ($SuccessExitCode -notcontains $ExitCode) {
      $Failure.Add($Script:Message['Start-Uninstaller.ProcessResult'] -f @(
          $Registration.display_name
          $ExitCode
        ))
    }
  } Catch {
    $Failure.Add($Script:Message['Start-Uninstaller.ProcessFailed'] -f @(
        $Registration.display_name
        $PSItem.Exception.GetBaseException().GetType().FullName
      ))
  }
}

$After = @(
  Get-FamilyRegistration `
    -DisplayNamePattern:$NormalizedDisplayNamePattern `
    -Property:$Property `
    -UninstallRoot:$UninstallRoots
)

ForEach ($Registration In $After) {
  $Null = $AfterPath.Add($Registration.registry_path)
  $PublicRegistration = [PSCustomObject]@{
    display_name  = $Registration.display_name
    key_name      = $Registration.key_name
    registry_path = $Registration.registry_path
  }
  If ($SelectedPath.Contains($Registration.registry_path)) {
    $Survived.Add($PublicRegistration)
  } Else {
    $Retained.Add($PublicRegistration)
  }
}

ForEach ($Registration In $Before) {
  If (
    $SelectedPath.Contains($Registration.registry_path) -and
    -not $AfterPath.Contains($Registration.registry_path)
  ) {
    $Removed.Add([PSCustomObject]@{
        display_name  = $Registration.display_name
        key_name      = $Registration.key_name
        registry_path = $Registration.registry_path
      })
  }
}

$Failed = -not $CheckMode -and (
  $Survived.Count -gt 0 -or
  $Failure.Count -gt 0
)
If ($CheckMode) {
  $OutcomeMessageKey = If ($HasCriteria) {
    'Start-Uninstaller.CheckModeFilter'
  } Else {
    'Start-Uninstaller.CheckMode'
  }
  $OutcomeMessage = $Script:Message[$OutcomeMessageKey] -f @(
    $SelectedCount
    $NormalizedDisplayNamePattern
    $Failure.Count
  )
} ElseIf ($Failed) {
  $OutcomeMessageKey = If ($HasCriteria) {
    'Start-Uninstaller.FailedFilter'
  } Else {
    'Start-Uninstaller.Failed'
  }
  $OutcomeMessage = $Script:Message[$OutcomeMessageKey] -f @(
    $NormalizedDisplayNamePattern
    $Survived.Count
    $Failure.Count
  )
} Else {
  $OutcomeMessageKey = If ($HasCriteria) {
    'Start-Uninstaller.ConvergedFilter'
  } Else {
    'Start-Uninstaller.Converged'
  }
  $OutcomeMessage = $Script:Message[$OutcomeMessageKey] -f @(
    $Removed.Count
    $NormalizedDisplayNamePattern
    $Retained.Count
  )
}

$Result = [PSCustomObject]@{
  changed       = [System.Boolean](
    $(If ($CheckMode) { $SelectedCount -gt 0 } Else { $Removed.Count -gt 0 })
  )
  check_mode    = $CheckMode
  failures      = [System.String[]]$Failure.ToArray()
  matched_count = $After.Count
  msg           = $OutcomeMessage
  removed       = [System.Object[]]$Removed.ToArray()
  retained      = [System.Object[]]$Retained.ToArray()
  survived      = [System.Object[]]$Survived.ToArray()
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Failed = $Failed
$Ansible.Result = $Result
If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:5
  If ($Failed) {
    Exit 1
  }
  Exit 0
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
