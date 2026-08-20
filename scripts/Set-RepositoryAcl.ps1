#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Holds one directory's DACL to exactly the repository model, wholesale.

    .DESCRIPTION
        The native Ansible module grants access-control entries one at a time and never removes
        one it did not write, so a hand-added grant -- Everyone with full control was the measured
        case, 2026-08-20 -- survives every converge. Enforcement means owning the WHOLE list, and
        no native module does that, which is what routes this to the role's first-class script
        convention.

        The descriptor is handled as its SDDL string from end to end. The desired form is a
        constant: protected (no inheritance from the volume root), SYSTEM and Administrators at
        full control, Users at modify, everything inheriting to children. Windows normalises an
        applied descriptor -- P comes back as PAI -- so the constant is the NORMALISED form, read
        back from a host after application, and a converged directory therefore compares equal
        byte for byte. Apply-and-verify: after a write the descriptor is read again and must equal
        the constant exactly, so a write that did not take fails the run instead of reporting a
        change that did not happen.

        The OWNER is deliberately untouched: only the DACL section of the descriptor is read,
        compared and written.

        Org scripts are a single straightforward process stage in the org script template's
        architecture: one [ Script ] region carrying [ Initialization ] (strict mode, transport
        detection, input normalization), [ Main ] (read -> compare -> apply -> verify -> build ONE
        result object), and [ Output ] (the same object to $Ansible or as JSON).

        Shipped by the org three-file convention: developed under scripts/ with its sibling
        Set-RepositoryAcl.pester.ps1 spec, while the pdq_deploy role carries
        files/Set-RepositoryAcl.ps1.stub, which the build resolves by dropping this file into
        the role.

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

    .PARAMETER Path
        The directory whose DACL is enforced.

    .EXAMPLE
        .\Set-RepositoryAcl.ps1 -Path 'F:\PDQ Repository'

    .OUTPUTS
        One object carrying changed, check_mode, path, before, after and msg.
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
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Path
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

New-Variable -Force -Name:'EXPORT_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Windows\Temp\pdq-settings-export.xml'
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
  # Diagnostics are wrapped so a partially-populated error record can never
  # replace the original failure with a StrictMode property error.
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


# The enforced DACL, as the NORMALISED SDDL Windows itself emits after application (measured on
# Windows Server 2025, 2026-08-20: 'D:P...' is stored and read back as 'D:PAI...', and the PAI
# form is byte-stable across further round trips). Protected from volume-root inheritance;
# SYSTEM and Administrators full control; Users modify (0x1301bf); every entry inherits to
# children (OICI). Well-known SIDs, so the string is identical on every host.
New-Variable -Force -Name:'DESIRED_SDDL' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;BU)'
)

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# The descriptor travels as a string: read the DACL section, compare to the constant, and only
# touch the directory when they differ. Everything platform-bound goes through Get-Acl/Set-Acl,
# which is also what lets the spec exercise this file on a build host with no NTFS.
$Before = (Get-Acl -LiteralPath:$Path).GetSecurityDescriptorSddlForm('Access')
$Changed = $False
$After = $Before

If ($Before -cne $DESIRED_SDDL) {
  $Changed = $True
  If (-not $Ansible.CheckMode) {
    $Descriptor = Get-Acl -LiteralPath:$Path
    $Descriptor.SetSecurityDescriptorSddlForm($DESIRED_SDDL)
    Set-Acl -LiteralPath:$Path -AclObject:$Descriptor
    # Prove the write took. A descriptor the platform silently adjusted into some OTHER shape
    # would otherwise report changed on every converge -- the exact defect this script replaces.
    $After = (Get-Acl -LiteralPath:$Path).GetSecurityDescriptorSddlForm('Access')
    If ($After -cne $DESIRED_SDDL) {
      Throw ('The DACL on {0} read back as {1} after applying {2}' -f $Path, $After, $DESIRED_SDDL)
    }
  }
}

$Result = [PSCustomObject]@{
  after      = [System.String]$After
  before     = [System.String]$Before
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  msg        = If ($Changed) {
    'DACL enforced on {0}' -f $Path
  } Else {
    'DACL already exact on {0}' -f $Path
  }
  path       = [System.String]$Path
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
