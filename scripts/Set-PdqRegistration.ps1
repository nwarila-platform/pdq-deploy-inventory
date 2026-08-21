#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Records the product registration the first console launch would otherwise ask for.

    .DESCRIPTION
        A licensed server still greets the first console with a registration popup: the product
        wants an email address recorded against the licence, and it stores that record in its own
        database as three rows -- the machine, the console user, and a Registration row binding
        both to the licence id with the address. Until the row exists every fresh build boots to
        a dialog, which is exactly the manual step this role exists to remove.

        The licence itself already names the address: the registry blob is base64 XML whose
        E-Mail attribute carries it, alongside the ID the Registration row references. The email
        this script is HANDED must equal the one in the licence -- a mismatch is a wrong input or
        a wrong licence, and either way writing it would record an address the vendor did not
        issue the licence to, so it throws instead.

        Rows are written exactly as the popup writes them, measured 2026-08-21: LicensedMachine
        and LicensedUser get a fresh GUID apiece when absent (lower-case names, the machine and
        its built-in administrator), and Registration is keyed on all three ids with
        ProductMode 'Server', RegistrationStatus 'Registered' and marketing declined. A row that
        already matches leaves everything untouched; after any write the row is read back and
        must equal what was asked, so a write that did not take fails the run.

        Org scripts are a single straightforward process stage: [ Initialization ], [ Main ]
        (read -> compare -> apply -> verify -> ONE result object), [ Output ]. Developed under
        scripts/ with the sibling Set-PdqRegistration.pester.ps1 spec; the role tracks only
        files/Set-PdqRegistration.ps1.stub, resolved by the build.

    .PARAMETER Email
        The registration address. Must equal the E-Mail attribute inside the installed licence.

    .EXAMPLE
        .\Set-PdqRegistration.ps1 -Email 'someone@example.com'

    .OUTPUTS
        One object carrying changed, check_mode, registered and msg.
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
  [ValidatePattern('^\S+@\S+\.\S+$')]
  [System.String]
  $Email
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The product's command line, its sqlite tool, and the registry key its licence lives under.
# Fixed, not offered: the installer ignores every documented relocation switch (measured
# 2026-08-18), so a path parameter would advertise a choice that does not exist.
New-Variable -Force -Name:'CLI_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
)
New-Variable -Force -Name:'SQLITE_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
)
New-Variable -Force -Name:'LICENSE_KEY' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'HKLM:\SOFTWARE\Admin Arsenal\PDQ Deploy'
)

# Strict mode on, stop on error -- matching the module's error_action: stop.
Set-StrictMode -Version:3
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

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

# No change is the default: a throw before the write must not inherit the transport's true.
$Ansible.Changed = $False

# The licence names both halves of the contract: the ID the Registration row references and the
# E-Mail the address must equal. Read from the registry exactly as the product left it -- a
# marker-wrapped base64 XML document -- and parsed, never pattern-matched.
$LicenseBlob = [System.String](Get-ItemProperty -LiteralPath:$LICENSE_KEY).License
$LicenseBase64 = ($LicenseBlob -replace '---\s*(START|END)\s*LICENSE\s*---', '') -replace '\s', ''
$LicenseXml = [System.Xml.XmlDocument]::new()
$LicenseXml.LoadXml([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($LicenseBase64)))
# GetAttribute, not property access: an attribute the licence does not carry comes back as an
# empty string the guards below can name, where the adapter property would throw first.
$LicenseId = [System.String]$LicenseXml.DocumentElement.GetAttribute('ID')
$LicenseEmail = [System.String]$LicenseXml.DocumentElement.GetAttribute('E-Mail')
If (-not $LicenseId) {
  Throw 'The installed licence carries no ID attribute; refusing to guess a registration key'
}
If (-not [System.String]::Equals($Email, $LicenseEmail, [System.StringComparison]::OrdinalIgnoreCase)) {
  Throw ('The email handed in does not match the one the licence was issued to ({0})' -f $LicenseEmail)
}

# Where the database lives is a deployment choice, so it is asked for rather than assumed: the
# product reports its own path and cannot be wrong about it.
$Info = & $CLI_PATH 'SystemInfo' 2>&1
If ($LASTEXITCODE -ne 0) {
  Throw ('SystemInfo failed with exit code {0}' -f $LASTEXITCODE)
}
$DatabasePath = (
  @($Info | Where-Object -FilterScript { $PSItem -match '^\s*Database\s*:' }) |
    Select-Object -First 1
) -replace '^\s*Database\s*:\s*', ''
If (-not $DatabasePath) {
  Throw 'SystemInfo did not report a database path'
}
If (-not (Test-Path -LiteralPath:$DatabasePath)) {
  Throw ('The database is not at {0}; refusing to create an empty one' -f $DatabasePath)
}

# The popup records lower-case names, measured 2026-08-21; matching its casing keeps a converged
# row byte-identical to a hand-registered one. The user is the machine's built-in administrator:
# the operator account that exists on every build and the one the popup fires for first.
$MachineName = ([System.String]$env:COMPUTERNAME).ToLowerInvariant()
$UserName = '{0}\administrator' -f $MachineName

# Read each table wholesale and match in memory: the tables hold a handful of rows, and matching
# here avoids baking their column names into SQL this script would then have to keep true.
$MachineId = [System.String]::Empty
$UserId = [System.String]::Empty
ForEach ($Row In @(& $SQLITE_PATH $DatabasePath 'PRAGMA busy_timeout = 5000; SELECT * FROM LicensedMachine;' 2>&1)) {
  $Parts = ([System.String]$Row).Split('|')
  If ($Parts.Count -eq 2 -and $Parts[0] -eq $MachineName) {
    $MachineId = $Parts[1]
  }
}
If ($LASTEXITCODE -ne 0) {
  Throw ('Reading LicensedMachine failed with exit code {0}' -f $LASTEXITCODE)
}
ForEach ($Row In @(& $SQLITE_PATH $DatabasePath 'PRAGMA busy_timeout = 5000; SELECT * FROM LicensedUser;' 2>&1)) {
  $Parts = ([System.String]$Row).Split('|')
  If ($Parts.Count -eq 2 -and $Parts[0] -eq $UserName) {
    $UserId = $Parts[1]
  }
}
If ($LASTEXITCODE -ne 0) {
  Throw ('Reading LicensedUser failed with exit code {0}' -f $LASTEXITCODE)
}

# The desired Registration row, in the exact column order the table declares:
# LicenseId, LicensedUserId, LicensedMachineConsoleId, EmailAddress, ProductMode,
# RegistrationStatus, AllowMarketing.
$NeedMachine = [System.String]::IsNullOrEmpty($MachineId)
$NeedUser = [System.String]::IsNullOrEmpty($UserId)
If ($NeedMachine) {
  $MachineId = [System.String][System.Guid]::NewGuid()
}
If ($NeedUser) {
  $UserId = [System.String][System.Guid]::NewGuid()
}
$Desired = '{0}|{1}|{2}|{3}|Server|Registered|0' -f $LicenseId, $UserId, $MachineId, $Email

$Existing = [System.String]::Empty
ForEach ($Row In @(& $SQLITE_PATH $DatabasePath 'PRAGMA busy_timeout = 5000; SELECT * FROM Registration;' 2>&1)) {
  $C = ([System.String]$Row).Split('|')
  If ($C.Count -ge 3 -and $C[0] -eq $LicenseId -and $C[1] -eq $UserId -and $C[2] -eq $MachineId) {
    $Existing = [System.String]$Row
  }
}
If ($LASTEXITCODE -ne 0) {
  Throw ('Reading Registration failed with exit code {0}' -f $LASTEXITCODE)
}

$Changed = $Existing -ne $Desired
If ($Changed -and -not $Ansible.CheckMode) {
  # One statement per missing row, and the Registration upsert keyed on the table's own primary
  # key -- so a re-run replaces nothing and a changed address replaces exactly one row.
  # Every value is escaped, not just the email: a machine name may legally hold an apostrophe,
  # and a pinned licence id is still safer doubled than trusted. The whole batch is one immediate
  # transaction under a busy timeout, so a lock waits rather than fails and a mid-batch failure
  # leaves no orphan machine or user row behind.
  $Esc = @{}
  ForEach ($Pair In @(
      @('m', $MachineName), @('u', $UserName), @('mid', $MachineId), @('uid', $UserId),
      @('lic', $LicenseId), @('email', $Email))) {
    $Esc[$Pair[0]] = ([System.String]$Pair[1]).Replace("'", "''")
  }
  $Statements = [System.Collections.Generic.List[System.String]]::new()
  $Statements.Add('PRAGMA busy_timeout = 5000;')
  $Statements.Add('BEGIN IMMEDIATE;')
  If ($NeedMachine) {
    $Statements.Add(("INSERT INTO LicensedMachine VALUES('{0}','{1}');" -f $Esc['m'], $Esc['mid']))
  }
  If ($NeedUser) {
    $Statements.Add(("INSERT INTO LicensedUser VALUES('{0}','{1}');" -f $Esc['u'], $Esc['uid']))
  }
  $Reg = "INSERT OR REPLACE INTO Registration VALUES('{0}','{1}','{2}','{3}','Server','Registered',0);"
  $Statements.Add(($Reg -f $Esc['lic'], $Esc['uid'], $Esc['mid'], $Esc['email']))
  $Statements.Add('COMMIT;')
  $Null = & $SQLITE_PATH $DatabasePath ($Statements -join ' ') 2>&1
  If ($LASTEXITCODE -ne 0) {
    Throw ('Writing the registration failed with exit code {0}' -f $LASTEXITCODE)
  }

  # Prove it: the row must now read back exactly as asked, or the run fails rather than
  # reporting a change that did not happen.
  $ReadBack = [System.String]::Empty
  ForEach ($Row In @(& $SQLITE_PATH $DatabasePath 'PRAGMA busy_timeout = 5000; SELECT * FROM Registration;' 2>&1)) {
    $C = ([System.String]$Row).Split('|')
    If ($C.Count -ge 3 -and $C[0] -eq $LicenseId -and $C[1] -eq $UserId -and $C[2] -eq $MachineId) {
      $ReadBack = [System.String]$Row
    }
  }
  If ($ReadBack -ne $Desired) {
    Throw 'The registration row did not read back as written'
  }
}

$Ansible.Changed = $Changed
$Result = [ordered]@{
  changed    = $Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  registered = $Email
  msg        = If ($Changed) { 'registration recorded' } Else { 'registration already present' }
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
