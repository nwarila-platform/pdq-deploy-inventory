#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Reconciles the PDQ service account's explicit Windows LAPS read permissions.

    .DESCRIPTION
        Ownership is every explicit ACE on the declared OUs whose identity resolves to the
        declared account SID. Present state replaces that complete set with the five declared
        Windows LAPS read ACEs; absent state removes it. Every ACE belonging to every other
        principal is fingerprinted as a multiset before and after the write and must be unchanged.

        An inherited LAPS ACE for the target account is refused. Its owning ancestor is outside
        this script's declared mutation boundary, so attempting to compensate locally would hide
        rather than remove the permission.

    .PARAMETER DebugLevel
        Three-digit control string configuring ErrorActionPreference, Set-PSDebug and
        Set-StrictMode. Default 103 means stop on error, tracing off and strict mode 3.

    .PARAMETER LogLevel
        Six-digit control string setting Verbose, Debug, Information, Warning, Error and Fatal
        stream preferences in that order.

    .PARAMETER State
        Present reconciles the target account's explicit ACEs to the five declared permissions.
        Absent removes every explicit ACE belonging to the target account.

    .PARAMETER AccountIdentity
        An identity accepted by Get-ADUser. It is resolved once to the SID used for every match.

    .PARAMETER OrganizationalUnit
        The complete set of OUs on which this role owns the target account's explicit ACEs.

    .OUTPUTS
        One object carrying state, changed, check_mode and the per-OU target ACE counts.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.Void])]
Param (
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String] $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String] $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateSet('present', 'absent')]
  [System.String] $State,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String] $AccountIdentity,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String[]] $OrganizationalUnit
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

$WhatIfPreference = $false

New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)

For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

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
  Set-StrictMode -Version:([System.Int32]::Parse($DebugLevel.Substring(2, 1)))
}

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

  If ($Null -ne (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')) {
    $Ansible.Failed = $True
  }
  Break
}

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

#region ------ [ Functions ] ----------------------------------------------------------------- #

Function Resolve-RuleSid {
  Param (
    [System.Security.Principal.IdentityReference] $Identity
  )

  Try {
    Return [System.Security.Principal.SecurityIdentifier](
      $Identity.Translate([System.Security.Principal.SecurityIdentifier])
    )
  } Catch [System.Security.Principal.IdentityNotMappedException] {
    Return $Null
  }
}

Function Get-RuleFingerprint {
  Param (
    [System.DirectoryServices.ActiveDirectoryAccessRule] $Rule
  )

  $Sid = Resolve-RuleSid -Identity:$Rule.IdentityReference
  $Principal = If ($Null -eq $Sid) {
    'UNRESOLVED:{0}' -f $Rule.IdentityReference.Value
  } Else {
    $Sid.Value
  }

  Return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f @(
      $Principal
      [System.Int32]$Rule.AccessControlType
      [System.Int32]$Rule.ActiveDirectoryRights
      [System.Int32]$Rule.InheritanceType
      $Rule.ObjectType.ToString('D')
      $Rule.InheritedObjectType.ToString('D')
      [System.Boolean]$Rule.IsInherited
      [System.Int32]$Rule.InheritanceFlags
      [System.Int32]$Rule.PropagationFlags
    ))
}

Function Test-MultisetEqual {
  Param (
    [System.String[]] $Reference,
    [System.String[]] $Difference
  )

  $Compared = Compare-Object -ReferenceObject:@($Reference | Sort-Object) `
    -DifferenceObject:@($Difference | Sort-Object)
  Return $Null -eq $Compared
}

Function Get-TargetRule {
  Param (
    [System.DirectoryServices.ActiveDirectorySecurity] $Acl,
    [System.Security.Principal.SecurityIdentifier] $TargetSid,
    [System.Boolean] $Inherited
  )

  Return @(
    $Acl.Access | Where-Object -FilterScript {
      $RuleSid = Resolve-RuleSid -Identity:$PSItem.IdentityReference
      $Null -ne $RuleSid -and $RuleSid.Equals($TargetSid) -and $PSItem.IsInherited -eq $Inherited
    }
  )
}

Function Get-OtherRuleFingerprint {
  Param (
    [System.DirectoryServices.ActiveDirectorySecurity] $Acl,
    [System.Security.Principal.SecurityIdentifier] $TargetSid
  )

  Return [System.String[]]@(
    $Acl.Access | Where-Object -FilterScript {
      $RuleSid = Resolve-RuleSid -Identity:$PSItem.IdentityReference
      $Null -eq $RuleSid -or -not $RuleSid.Equals($TargetSid)
    } | ForEach-Object -Process { Get-RuleFingerprint -Rule:$PSItem } | Sort-Object
  )
}

Function Get-SchemaGuid {
  Param (
    [System.String] $SchemaNamingContext,
    [System.String] $LdapDisplayName
  )

  $Object = Get-ADObject -LDAPFilter:('(lDAPDisplayName={0})' -f $LdapDisplayName) `
    -Properties:@('schemaIDGUID') -SearchBase:$SchemaNamingContext
  If ($Null -eq $Object) {
    Throw ('LAPS schema prerequisite failed: {0} is not present in the schema' -f $LdapDisplayName)
  }
  Return [System.Guid]::new([System.Byte[]]$Object.schemaIDGUID)
}

#endregion --- [ Functions ] ----------------------------------------------------------------- #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

Import-Module -Name:'ActiveDirectory' -ErrorAction:'Stop'

$Account = Get-ADUser -Identity:$AccountIdentity -Properties:@('SID')
$TargetSid = [System.Security.Principal.SecurityIdentifier]$Account.SID
$Root = Get-ADRootDSE
$ComputerGuid = Get-SchemaGuid -SchemaNamingContext:$Root.schemaNamingContext `
  -LdapDisplayName:'computer'

$Permission = [System.Collections.Generic.List[System.Object]]::new()
ForEach ($Definition In @(
    [PSCustomObject]@{ Name = 'msLAPS-Password'; Rights = 'ReadProperty, ExtendedRight' }
    [PSCustomObject]@{ Name = 'msLAPS-EncryptedPassword'; Rights = 'ReadProperty, ExtendedRight' }
    [PSCustomObject]@{ Name = 'msLAPS-EncryptedPasswordHistory'; Rights = 'ReadProperty, ExtendedRight' }
    [PSCustomObject]@{ Name = 'msLAPS-CurrentPasswordVersion'; Rights = 'ReadProperty' }
    [PSCustomObject]@{ Name = 'msLAPS-PasswordExpirationTime'; Rights = 'ReadProperty' }
  )) {
  $Permission.Add([PSCustomObject]@{
      Name   = $Definition.Name
      Guid   = Get-SchemaGuid -SchemaNamingContext:$Root.schemaNamingContext `
        -LdapDisplayName:$Definition.Name
      Rights = [System.DirectoryServices.ActiveDirectoryRights]$Definition.Rights
    })
}
$LapsGuid = [System.Collections.Generic.HashSet[System.Guid]]::new()
ForEach ($Entry In $Permission) {
  [System.Void]$LapsGuid.Add($Entry.Guid)
}

$Changed = $False
$OuResult = [System.Collections.Generic.List[System.Object]]::new()
ForEach ($DeclaredOu In $OrganizationalUnit) {
  $ResolvedOu = Get-ADOrganizationalUnit -Identity:$DeclaredOu -Properties:@('DistinguishedName')
  $Path = 'AD:\{0}' -f $ResolvedOu.DistinguishedName
  # -Path, not -LiteralPath: the ActiveDirectory provider does not resolve a LiteralPath and
  # reports 'Cannot find path //RootDSE/<dn>' for an OU that plainly exists (measured 2026-08-31).
  $BeforeAcl = Get-Acl -Path:$Path
  $BeforeTarget = @(Get-TargetRule -Acl:$BeforeAcl -TargetSid:$TargetSid -Inherited:$False)
  $InheritedTarget = @(Get-TargetRule -Acl:$BeforeAcl -TargetSid:$TargetSid -Inherited:$True)
  $InheritedLaps = @($InheritedTarget | Where-Object -FilterScript { $LapsGuid.Contains($PSItem.ObjectType) })
  If ($InheritedLaps.Count -gt 0) {
    Throw ('Inherited LAPS ACE failure: {0} inherits {1} target LAPS ACE(s); correct the owning ancestor' -f @(
        $ResolvedOu.DistinguishedName
        $InheritedLaps.Count
      ))
  }

  $OtherBefore = @(Get-OtherRuleFingerprint -Acl:$BeforeAcl -TargetSid:$TargetSid)
  $WorkingAcl = $BeforeAcl
  ForEach ($Rule In $BeforeTarget) {
    [System.Void]$WorkingAcl.RemoveAccessRuleSpecific($Rule)
  }

  $DesiredRule = [System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]]::new()
  If ($State -eq 'present') {
    ForEach ($Entry In $Permission) {
      $Rule = [System.DirectoryServices.ActiveDirectoryAccessRule]::new(
        $TargetSid,
        $Entry.Rights,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $Entry.Guid,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
        $ComputerGuid
      )
      $DesiredRule.Add($Rule)
      [System.Void]$WorkingAcl.AddAccessRule($Rule)
    }
  }

  $BeforeFingerprint = [System.String[]]@($BeforeTarget | ForEach-Object -Process {
      Get-RuleFingerprint -Rule:$PSItem
    })
  $DesiredFingerprint = [System.String[]]@($DesiredRule | ForEach-Object -Process {
      Get-RuleFingerprint -Rule:$PSItem
    })
  $OuChanged = -not (Test-MultisetEqual -Reference:$BeforeFingerprint -Difference:$DesiredFingerprint)

  If ($OuChanged -and -not $Ansible.CheckMode) {
    If ($PSCmdlet.ShouldProcess($ResolvedOu.DistinguishedName, ('Reconcile target ACEs to state={0}' -f $State))) {
      Set-Acl -Path:$Path -AclObject:$WorkingAcl
    }
  }
  $Changed = $Changed -or $OuChanged

  $AfterAcl = Get-Acl -Path:$Path
  $OtherAfter = @(Get-OtherRuleFingerprint -Acl:$AfterAcl -TargetSid:$TargetSid)
  If (-not (Test-MultisetEqual -Reference:$OtherBefore -Difference:$OtherAfter)) {
    Throw ('ACL preservation failure: another principal''s ACE changed on {0}' -f $ResolvedOu.DistinguishedName)
  }

  $AfterTarget = @(Get-TargetRule -Acl:$AfterAcl -TargetSid:$TargetSid -Inherited:$False)
  If (-not $Ansible.CheckMode) {
    $AfterFingerprint = [System.String[]]@($AfterTarget | ForEach-Object -Process {
        Get-RuleFingerprint -Rule:$PSItem
      })
    If (-not (Test-MultisetEqual -Reference:$DesiredFingerprint -Difference:$AfterFingerprint)) {
      Throw ('ACL target-state failure: explicit target ACEs on {0} do not match state={1}' -f @(
          $ResolvedOu.DistinguishedName
          $State
        ))
    }
  }

  $OuResult.Add([PSCustomObject]@{
      distinguished_name = $ResolvedOu.DistinguishedName
      before_target_aces = $BeforeTarget.Count
      after_target_aces  = $(If ($Ansible.CheckMode) { $DesiredRule.Count } Else { $AfterTarget.Count })
      changed            = $OuChanged
    })
}

$Ansible.Changed = $Changed
$Ansible.Result = [PSCustomObject]@{
  state      = $State
  changed    = $Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  ous        = $OuResult.ToArray()
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

If ($StandaloneRun) {
  $Ansible.Result
  If ($Ansible.Failed) {
    Exit 1
  }
}

#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
