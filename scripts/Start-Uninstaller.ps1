#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Removes selected machine registrations from one product family.

    .DESCRIPTION
        Reads both machine uninstall roots, loads the properties required for
        identity, removal, and declared filters, and synthesizes ParentKey and
        AppArch. Family matches DisplayName. Every Filter tuple narrows the
        selection, and any matching Exclude tuple retains a registration.
        Conforming MSI registrations are retained unless RemoveConforming is
        supplied. MaxRemovals limits the selected registrations before any
        process is launched.

        A selected MSI registration is removed through msiexec with its
        synthesized ParentKey. Other selected registrations use their recorded
        QuietUninstallString, or their UninstallString plus the supplied silent
        switch.

        A bare UninstallString is never guessed at: when no quiet command and
        no silent switch are available, the registration is refused and the
        script fails. An MSI registration whose UninstallString does not name
        msiexec is also refused. After all attempts, the uninstall roots are
        read again. Any path selected by the first read that still exists, or
        any registration selected by the second read, fails the script.

        The result reports registration identities and outcomes, never the
        recorded command lines. The script does not remove anything outside the
        declared family or user data.

    .PARAMETER DebugLevel
        Three-digit control string configuring ErrorActionPreference,
        Set-PSDebug, and Set-StrictMode. Default '103'.

    .PARAMETER Exclude
        Tuples naming a property, matching method, and query. A registration
        matching any tuple is retained.

    .PARAMETER Family
        One tuple with Method and Query keys matching DisplayName.

    .PARAMETER Filter
        Tuples naming a property, matching method, and query. A registration
        must match every tuple to be selected.

    .PARAMETER LogLevel
        Six-digit control string mapping Verbose, Debug, Information, Warning,
        Error, and Fatal streams to ActionPreference values.

    .PARAMETER MaxRemovals
        Maximum registrations the call may select. Defaults to one.

    .PARAMETER RemoveConforming
        Also select conforming MSI registrations for removal. Without this
        switch, conforming MSI registrations are retained.

    .PARAMETER SilentSwitch
        Silent argument appended only when a matching registration has no
        QuietUninstallString and its UninstallString must be used.

    .PARAMETER SuccessExitCode
        Exit codes accepted from an uninstaller. Defaults to the conventional
        success, reboot-initiated, and reboot-required codes.

    .EXAMPLE
        PS> $Family = @{ Method = 'Simple'; Query = '7-Zip*' }
        PS> ./Start-Uninstaller.ps1 -Family $Family -MaxRemovals 3 -SilentSwitch '/S'

    .EXAMPLE
        PS> $Family = @{ Method = 'Exact'; Query = 'Google Chrome' }
        PS> $Keep = @{ Property = 'ParentKey'; Method = 'Exact'; Query = '{00000000-0000-0000-0000-000000000000}' }
        PS> ./Start-Uninstaller.ps1 -Family $Family -Exclude $Keep -RemoveConforming

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
  [System.Object]
  $Family,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [AllowEmptyCollection()]
  [System.Object[]]
  $Exclude,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [AllowEmptyCollection()]
  [System.Object[]]
  $Filter,

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
  [System.Int32]
  $MaxRemovals = 1,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Management.Automation.SwitchParameter]
  $RemoveConforming = $False,

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
  'Start-Uninstaller.CheckMode'       = 'Check mode: would process {0} selected registration(s) matching {1}; {2} unsafe command(s) were refused.'
  'Start-Uninstaller.CheckModeFilter' = 'Check mode: would process {0} selected registration(s) matching {1}; {2} unsafe command(s) were refused.'
  'Start-Uninstaller.Converged'       = 'Removed {0} selected registration(s) matching {1}; retained {2} registration(s) outside the selection.'
  'Start-Uninstaller.ConvergedFilter' = 'Removed {0} selected registration(s) matching {1}; retained {2} registration(s) outside the selection.'
  'Start-Uninstaller.Failed'          = 'Removal did not converge for {0}: {1} selected registration(s) survived and {2} command failure(s) were recorded.'
  'Start-Uninstaller.FailedFilter'    = 'Removal did not converge for {0}: {1} selected registration(s) survived and {2} command failure(s) were recorded.'
  'Start-Uninstaller.InvalidCommand'  = '{0}: the recorded uninstall command does not identify an executable.'
  'Start-Uninstaller.NoCommand'       = '{0}: no QuietUninstallString or UninstallString is recorded; refusing to invent an uninstall command.'
  'Start-Uninstaller.NoSilentCommand' = '{0}: no QuietUninstallString exists and no silent switch was supplied; refusing the interactive uninstall command.'
  'Start-Uninstaller.ProcessFailed'   = '{0}: the uninstaller could not be started ({1}).'
  'Start-Uninstaller.ProcessResult'   = '{0}: the uninstaller exited with unaccepted code {1}.'
  'Start-Uninstaller.RegistryData'    = '{0}: property {1} has unsupported registry value type {2}.'
  'Start-Uninstaller.RegistryFailed'  = 'Registry data refused removal for {0}: {1} unsupported value(s) were found.'
  'Start-Uninstaller.SelectionLimit'  = '{0}: selected while MaxRemovals is {1}; refusing every removal in this call.'
  'Start-Uninstaller.SelectionFailed' = 'Selected {0} registration(s) matching {1}, exceeding MaxRemovals {2}; no removal was attempted.'
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

[System.String]$Private:NormalizedSilentSwitch = $SilentSwitch.Trim()
[System.Boolean]$Private:HasCriteria = (
  $PSBoundParameters.ContainsKey('Filter') -or
  $PSBoundParameters.ContainsKey('Exclude')
)
[System.Collections.Generic.List[System.String]]$Private:LoadedProperty = (
  [System.Collections.Generic.List[System.String]]::new()
)
[System.Collections.Generic.HashSet[System.String]]$Private:LoadedPropertyName = (
  [System.Collections.Generic.HashSet[System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
)
[System.Collections.Generic.List[System.Object]]$Private:NormalizedExclude = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[PSCustomObject]$Private:NormalizedFamily = $Null
[System.Collections.Generic.List[System.Object]]$Private:NormalizedFilter = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.String[]]$Private:RequiredProperty = @(
  'DisplayName'
  'ParentKey'
  'QuietUninstallString'
  'UninstallString'
  'AppArch'
)
[System.Object]$Private:TupleMethod = $Null
[System.String]$Private:TupleMethodKey = [System.String]::Empty
[System.String]$Private:TupleName = [System.String]::Empty
[System.Object]$Private:TupleProperty = $Null
[System.String]$Private:TuplePropertyKey = [System.String]::Empty
[System.Object]$Private:TupleQuery = $Null
[System.String]$Private:TupleQueryKey = [System.String]::Empty
[System.Text.RegularExpressions.Regex]$Private:TupleRegex = $Null

If ($MaxRemovals -le 0) {
  Throw 'MaxRemovals must be a positive integer.'
}
If ($Family -isnot [System.Collections.Hashtable]) {
  Throw 'Family must be a hashtable tuple.'
}

$TupleMethodKey = [System.String]::Empty
$TupleQueryKey = [System.String]::Empty
ForEach ($TupleKey In $Family.Keys) {
  If ($TupleKey -isnot [System.String]) {
    Continue
  }
  If ([System.String]$TupleKey -ieq 'Method') {
    $TupleMethodKey = [System.String]$TupleKey
  } ElseIf ([System.String]$TupleKey -ieq 'Query') {
    $TupleQueryKey = [System.String]$TupleKey
  }
}
If (
  $Family.Count -ne 2 -or
  [System.String]::IsNullOrEmpty($TupleMethodKey) -or
  [System.String]::IsNullOrEmpty($TupleQueryKey)
) {
  Throw 'Family must contain exactly the keys Method and Query.'
}

$TupleMethod = $Family[$TupleMethodKey]
$TupleQuery = $Family[$TupleQueryKey]
If (
  $TupleMethod -isnot [System.String] -or
  @('Exact', 'Simple', 'Regex') -inotcontains [System.String]$TupleMethod
) {
  Throw 'Family Method must be Exact, Simple, or Regex.'
}
If (
  $TupleQuery -isnot [System.String] -or
  [System.String]::IsNullOrWhiteSpace([System.String]$TupleQuery)
) {
  Throw 'Family Query must be a non-whitespace string.'
}
$TupleRegex = $Null
If ([System.String]$TupleMethod -ieq 'Regex') {
  Try {
    $TupleRegex = [System.Text.RegularExpressions.Regex]::new(
      [System.String]$TupleQuery,
      (
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
      )
    )
  } Catch {
    Throw 'Family Query is not a valid regular expression.'
  }
}
$NormalizedFamily = [PSCustomObject]@{
  method = [System.String]$TupleMethod
  query  = [System.String]$TupleQuery
  regex  = $TupleRegex
}

ForEach ($PropertyName In $RequiredProperty) {
  If ($LoadedPropertyName.Add($PropertyName)) {
    $LoadedProperty.Add($PropertyName)
  }
}

ForEach ($CriterionName In @('Filter', 'Exclude')) {
  If (-not $PSBoundParameters.ContainsKey($CriterionName)) {
    Continue
  }

  [System.Object[]]$Private:CriterionTuple = @(
    If ($CriterionName -eq 'Filter') {
      $Filter
    } Else {
      $Exclude
    }
  )
  If ($CriterionTuple.Count -eq 0) {
    Throw ('{0} must contain at least one tuple.' -f $CriterionName)
  }

  For ($TupleIndex = 0; $TupleIndex -lt $CriterionTuple.Count; $TupleIndex++) {
    $TupleName = '{0}[{1}]' -f @($CriterionName, $TupleIndex)
    [System.Object]$Private:RawTuple = $CriterionTuple[$TupleIndex]
    If ($RawTuple -isnot [System.Collections.Hashtable]) {
      Throw ('{0} must be a hashtable tuple.' -f $TupleName)
    }

    $TupleMethodKey = [System.String]::Empty
    $TuplePropertyKey = [System.String]::Empty
    $TupleQueryKey = [System.String]::Empty
    ForEach ($TupleKey In $RawTuple.Keys) {
      If ($TupleKey -isnot [System.String]) {
        Continue
      }
      Switch ([System.String]$TupleKey) {
        { $PSItem -ieq 'Method' } {
          $TupleMethodKey = [System.String]$TupleKey
          Break
        }
        { $PSItem -ieq 'Property' } {
          $TuplePropertyKey = [System.String]$TupleKey
          Break
        }
        { $PSItem -ieq 'Query' } {
          $TupleQueryKey = [System.String]$TupleKey
          Break
        }
      }
    }
    If (
      $RawTuple.Count -ne 3 -or
      [System.String]::IsNullOrEmpty($TupleMethodKey) -or
      [System.String]::IsNullOrEmpty($TuplePropertyKey) -or
      [System.String]::IsNullOrEmpty($TupleQueryKey)
    ) {
      Throw ('{0} must contain exactly the keys Property, Method, and Query.' -f $TupleName)
    }

    $TupleMethod = $RawTuple[$TupleMethodKey]
    $TupleProperty = $RawTuple[$TuplePropertyKey]
    $TupleQuery = $RawTuple[$TupleQueryKey]
    If (
      $TupleProperty -isnot [System.String] -or
      [System.String]::IsNullOrWhiteSpace([System.String]$TupleProperty)
    ) {
      Throw ('{0} Property must be a non-whitespace string.' -f $TupleName)
    }
    If (
      $TupleMethod -isnot [System.String] -or
      @('Exact', 'Simple', 'Regex') -inotcontains [System.String]$TupleMethod
    ) {
      Throw ('{0} Method must be Exact, Simple, or Regex.' -f $TupleName)
    }
    If (
      $TupleQuery -isnot [System.String] -or
      [System.String]::IsNullOrWhiteSpace([System.String]$TupleQuery)
    ) {
      Throw ('{0} Query must be a non-whitespace string.' -f $TupleName)
    }

    $TupleRegex = $Null
    If ([System.String]$TupleMethod -ieq 'Regex') {
      Try {
        $TupleRegex = [System.Text.RegularExpressions.Regex]::new(
          [System.String]$TupleQuery,
          (
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
          )
        )
      } Catch {
        Throw ('{0} Query is not a valid regular expression.' -f $TupleName)
      }
    }

    [PSCustomObject]$Private:NormalizedTuple = [PSCustomObject]@{
      method   = [System.String]$TupleMethod
      property = [System.String]$TupleProperty
      query    = [System.String]$TupleQuery
      regex    = $TupleRegex
    }
    If ($CriterionName -eq 'Filter') {
      $NormalizedFilter.Add($NormalizedTuple)
    } Else {
      $NormalizedExclude.Add($NormalizedTuple)
    }
    If ($LoadedPropertyName.Add([System.String]$TupleProperty)) {
      $LoadedProperty.Add([System.String]$TupleProperty)
    }
  }
}

[PSCustomObject[]]$Private:FilterTuple = [PSCustomObject[]]$NormalizedFilter.ToArray()
[PSCustomObject[]]$Private:ExcludeTuple = [PSCustomObject[]]$NormalizedExclude.ToArray()
[System.String[]]$Private:Property = [System.String[]]$LoadedProperty.ToArray()

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

Function Test-SelectorValue {
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
    [PSCustomObject]
    $Tuple,

    [Parameter(
      DontShow = $False,
      Mandatory = $False,
      ParameterSetName = 'default',
      ValueFromPipeline = $False,
      ValueFromPipelineByPropertyName = $False
    )]
    [AllowNull()]
    [System.Object]
    $Value
  )
  Write-Debug -Message:'[Test-SelectorValue] Entering'

  If ($Null -eq $Value) {
    Return $False
  }
  If (
    $Value -isnot [System.String] -and
    $Value -isnot [System.Int32] -and
    $Value -isnot [System.Int64]
  ) {
    Return $False
  }

  [System.String]$Private:Text = [System.Convert]::ToString(
    $Value,
    [System.Globalization.CultureInfo]::InvariantCulture
  )
  [System.Boolean]$Private:Result = Switch ($Tuple.method) {
    { $PSItem -ieq 'Exact' } {
      $Text.Equals(
        $Tuple.query,
        [System.StringComparison]::OrdinalIgnoreCase
      )
      Break
    }
    { $PSItem -ieq 'Simple' } {
      $Text -like $Tuple.query
      Break
    }
    { $PSItem -ieq 'Regex' } {
      $Tuple.regex.IsMatch($Text)
      Break
    }
  }

  Write-Debug -Message:'[Test-SelectorValue] Exiting'
  $Result
}

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
    [PSCustomObject]
    $Family,

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
  [System.Object]$Private:DisplayNameValue = $Null
  [System.Guid]$Private:Guid = [System.Guid]::Empty
  [System.Boolean]$Private:IsConforming = $False
  [System.Collections.Hashtable]$Private:Loaded = $Null
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

      $DisplayNameProperty = $Null
      ForEach ($RawProperty In $RawRegistration.PSObject.Properties) {
        If ($RawProperty.Name -ieq 'DisplayName') {
          $DisplayNameProperty = $RawProperty
          Break
        }
      }
      $DisplayNameValue = If ($Null -eq $DisplayNameProperty) {
        $Null
      } Else {
        $DisplayNameProperty.Value
      }
      If (
        $Null -eq $DisplayNameProperty -or
        [System.String]::IsNullOrEmpty([System.String]$DisplayNameValue) -or
        -not (Test-SelectorValue -Tuple:$Family -Value:$DisplayNameValue)
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

      $Loaded = [System.Collections.Hashtable]::new(
        [System.StringComparer]::OrdinalIgnoreCase
      )
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
            $ValueProperty = $Null
            ForEach ($RawProperty In $RawRegistration.PSObject.Properties) {
              If ($RawProperty.Name -ieq $PropertyName) {
                $ValueProperty = $RawProperty
                Break
              }
            }
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
          properties             = $Loaded
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

Function Test-RegistrationTuple {
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
    [PSCustomObject]
    $Tuple,

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
  Write-Debug -Message:'[Test-RegistrationTuple] Entering'

  [System.Object]$Private:ActualValue = $Null
  If ($Registration.properties.ContainsKey([System.String]$Tuple.property)) {
    $ActualValue = $Registration.properties[[System.String]$Tuple.property]
  }

  [System.Boolean]$Private:Result = Test-SelectorValue `
    -Tuple:$Tuple `
    -Value:$ActualValue

  Write-Debug -Message:'[Test-RegistrationTuple] Exiting'
  $Result
}

Function Test-RegistrationSelected {
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
    [AllowEmptyCollection()]
    [PSCustomObject[]]
    $ExcludeTuple,

    [Parameter(
      DontShow = $False,
      Mandatory = $True,
      ParameterSetName = 'default',
      ValueFromPipeline = $False,
      ValueFromPipelineByPropertyName = $False
    )]
    [AllowEmptyCollection()]
    [PSCustomObject[]]
    $FilterTuple,

    [Parameter(
      DontShow = $False,
      Mandatory = $True,
      ParameterSetName = 'default',
      ValueFromPipeline = $False,
      ValueFromPipelineByPropertyName = $False
    )]
    [System.Boolean]
    $RemoveConforming,

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
  Write-Debug -Message:'[Test-RegistrationSelected] Entering'

  If ($Registration.is_conforming -and -not $RemoveConforming) {
    Return $False
  }
  ForEach ($Tuple In $FilterTuple) {
    If (-not (Test-RegistrationTuple -Tuple:$Tuple -Registration:$Registration)) {
      Return $False
    }
  }
  ForEach ($Tuple In $ExcludeTuple) {
    If (Test-RegistrationTuple -Tuple:$Tuple -Registration:$Registration) {
      Return $False
    }
  }

  Write-Debug -Message:'[Test-RegistrationSelected] Exiting'
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
[System.Boolean]$Private:IsSelected = $False
[System.String]$Private:OutcomeMessage = [System.String]::Empty
[System.String]$Private:OutcomeMessageKey = [System.String]::Empty
[System.Object]$Private:Process = $Null
[PSCustomObject]$Private:PublicRegistration = $Null
[System.Collections.Generic.HashSet[System.String]]$Private:ReferencedProperty = (
  [System.Collections.Generic.HashSet[System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
)
[System.Boolean]$Private:Refused = $False
[System.Collections.Generic.List[System.Object]]$Private:Removed = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.Collections.Generic.List[System.Object]]$Private:Retained = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[PSCustomObject]$Private:Result = $Null
[System.Collections.Generic.List[System.Object]]$Private:Selected = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.Int32]$Private:SelectedCount = 0
[System.Collections.Generic.HashSet[System.String]]$Private:SelectedPath = (
  [System.Collections.Generic.HashSet[System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
)
[System.Collections.Generic.List[System.Object]]$Private:Survived = (
  [System.Collections.Generic.List[System.Object]]::new()
)
[System.Object]$Private:TypedValue = $Null
[System.String[]]$Private:UninstallRoots = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$Before = @(
  Get-FamilyRegistration `
    -Family:$NormalizedFamily `
    -Property:$Property `
    -UninstallRoot:$UninstallRoots
)

ForEach ($Tuple In @($FilterTuple + $ExcludeTuple)) {
  $Null = $ReferencedProperty.Add([System.String]$Tuple.property)
}
ForEach ($Registration In $Before) {
  ForEach ($PropertyName In $ReferencedProperty) {
    $TypedValue = $Registration.properties[$PropertyName]
    If (
      $Null -ne $TypedValue -and
      $TypedValue -isnot [System.String] -and
      $TypedValue -isnot [System.Int32] -and
      $TypedValue -isnot [System.Int64]
    ) {
      $Failure.Add($Script:Message['Start-Uninstaller.RegistryData'] -f @(
          $Registration.display_name
          $PropertyName
          $TypedValue.GetType().FullName
        ))
    }
  }
}

If ($Failure.Count -gt 0) {
  $Refused = $True
  $Failed = $True
  ForEach ($Registration In $Before) {
    $Retained.Add([PSCustomObject]@{
        display_name  = $Registration.display_name
        key_name      = $Registration.key_name
        registry_path = $Registration.registry_path
      })
  }
  $OutcomeMessage = $Script:Message['Start-Uninstaller.RegistryFailed'] -f @(
    $NormalizedFamily.query
    $Failure.Count
  )
}

If (-not $Refused) {
  ForEach ($Registration In $Before) {
    $IsSelected = Test-RegistrationSelected `
      -ExcludeTuple:$ExcludeTuple `
      -FilterTuple:$FilterTuple `
      -RemoveConforming:$RemoveConforming.IsPresent `
      -Registration:$Registration
    If ($IsSelected) {
      $Selected.Add($Registration)
    }
  }
  $SelectedCount = $Selected.Count
}

If (-not $Refused -and $SelectedCount -gt $MaxRemovals) {
  $Refused = $True
  $Failed = $True
  ForEach ($Registration In $Before) {
    $PublicRegistration = [PSCustomObject]@{
      display_name  = $Registration.display_name
      key_name      = $Registration.key_name
      registry_path = $Registration.registry_path
    }
    If ($Selected.Contains($Registration)) {
      $Failure.Add($Script:Message['Start-Uninstaller.SelectionLimit'] -f @(
          $Registration.display_name
          $MaxRemovals
        ))
      $Survived.Add($PublicRegistration)
    } Else {
      $Retained.Add($PublicRegistration)
    }
  }
  $OutcomeMessage = $Script:Message['Start-Uninstaller.SelectionFailed'] -f @(
    $SelectedCount
    $NormalizedFamily.query
    $MaxRemovals
  )
}

If (-not $Refused) {
  ForEach ($Registration In $Selected) {
    $Null = $SelectedPath.Add($Registration.registry_path)
    If (-not (Test-Path -LiteralPath:$Registration.registry_path)) {
      Continue
    }
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
      -Family:$NormalizedFamily `
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
    $IsSelected = $SelectedPath.Contains($Registration.registry_path) -or (
      Test-RegistrationSelected `
        -ExcludeTuple:$ExcludeTuple `
        -FilterTuple:$FilterTuple `
        -RemoveConforming:$RemoveConforming.IsPresent `
        -Registration:$Registration
    )
    If ($IsSelected) {
      $Survived.Add($PublicRegistration)
    } Else {
      $Retained.Add($PublicRegistration)
    }
  }

  ForEach ($Registration In $Before) {
    If (-not $SelectedPath.Contains($Registration.registry_path)) {
      Continue
    }
    If (-not (Test-Path -LiteralPath:$Registration.registry_path)) {
      $Removed.Add([PSCustomObject]@{
          display_name  = $Registration.display_name
          key_name      = $Registration.key_name
          registry_path = $Registration.registry_path
        })
    } ElseIf (-not $AfterPath.Contains($Registration.registry_path)) {
      $Survived.Add([PSCustomObject]@{
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
      $NormalizedFamily.query
      $Failure.Count
    )
  } ElseIf ($Failed) {
    $OutcomeMessageKey = If ($HasCriteria) {
      'Start-Uninstaller.FailedFilter'
    } Else {
      'Start-Uninstaller.Failed'
    }
    $OutcomeMessage = $Script:Message[$OutcomeMessageKey] -f @(
      $NormalizedFamily.query
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
      $NormalizedFamily.query
      $Retained.Count
    )
  }
}

$Result = [PSCustomObject]@{
  changed       = [System.Boolean](
    $(If ($Refused) {
        $False
      } ElseIf ($CheckMode) {
        $SelectedCount -gt 0
      } Else {
        $Removed.Count -gt 0
      })
  )
  check_mode    = $CheckMode
  failures      = [System.String[]]$Failure.ToArray()
  matched_count = $(If ($Refused) { $Before.Count } Else { $After.Count })
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
