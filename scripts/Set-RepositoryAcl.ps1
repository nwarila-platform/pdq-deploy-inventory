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

        The descriptor is handled as its SDDL string from end to end. The desired form is
        supplied by the caller: protected (no inheritance from the volume root), SYSTEM and Administrators at
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

    .PARAMETER Path
        The directory whose DACL is enforced.

    .PARAMETER Sddl
        The desired DACL as its NORMALISED SDDL string -- the form Windows reads back after
        applying, so a converged directory compares equal. The role owns the model per folder;
        the repository is SYSTEM and Administrators full, Users read-and-execute, inheritance
        severed. Only the DACL section is ever read or written; owner, group and audit are left.

    .EXAMPLE
        .\Set-RepositoryAcl.ps1 -Path 'F:\PDQ Repository' -Sddl 'D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'

    .OUTPUTS
        One object carrying changed, check_mode, path, before, after and msg.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.Void])]
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
  $Path,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^D:P')]
  [System.String]
  $Sddl
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'


# Strict mode on, stop on error -- matching the module's error_action: stop.
Set-StrictMode -Version:3
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

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



#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# The descriptor travels as a string: read the DACL section, compare to the constant, and only
# touch the directory when they differ. Everything platform-bound goes through Get-Acl/Set-Acl,
# which is also what lets the spec exercise this file on a build host with no NTFS.
# No change is the default: a throw in the read below must not inherit the transport's true.
$Ansible.Changed = $False
$Before = (Get-Acl -LiteralPath:$Path).GetSecurityDescriptorSddlForm('Access')
$Changed = $False
$After = $Before

If ($Before -cne $Sddl) {
  $Changed = $True
  If (-not $Ansible.CheckMode) {
    $Descriptor = Get-Acl -LiteralPath:$Path
    # 'Access' on BOTH read and write: the one-argument overload means AccessControlSections.All,
    # which stamps a DACL-only string over the owner, group and AUDIT sections and would clear an
    # existing SACL. Only the DACL is this script's business.
    $Descriptor.SetSecurityDescriptorSddlForm($Sddl, [System.Security.AccessControl.AccessControlSections]::Access)
    Set-Acl -LiteralPath:$Path -AclObject:$Descriptor
    # Prove the write took. A descriptor the platform silently adjusted into some OTHER shape
    # would otherwise report changed on every converge -- the exact defect this script replaces.
    $After = (Get-Acl -LiteralPath:$Path).GetSecurityDescriptorSddlForm('Access')
    If ($After -cne $Sddl) {
      Throw ('The DACL on {0} read back as {1} after applying {2}' -f $Path, $After, $Sddl)
    }
  }
}

$Result = [PSCustomObject]@{
  after      = [System.String]$After
  before     = [System.String]$Before
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  msg        = If ($Changed -and $Ansible.CheckMode) {
    'DACL would be enforced on {0}' -f $Path
  } ElseIf ($Changed) {
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
