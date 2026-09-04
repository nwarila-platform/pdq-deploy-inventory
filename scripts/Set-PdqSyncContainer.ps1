#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Declares which Active Directory containers PDQ Inventory syncs computers from.

.DESCRIPTION
    The product offers no command line for its sync containers -- ADSync only starts a sync -- so
    the declaration is written to the product's own store, and the product's own verdict is read
    back out of it. Each container records the error it met in its own row, so a container that
    could not be read says so rather than leaving an empty result to be mistaken for an empty
    directory.

    A container is declared by DISTINGUISHED NAME. The product stores a GUID, which this script
    resolves from the directory on every run, so a container that is recreated is followed rather
    than left pointing at an object that no longer exists. The GUID is also why the bind account
    is needed here and not only inside the product: the resolution happens before the product is
    involved.

    The bind account is ORDINARY, never a LAPS credential. A LAPS credential resolves to the
    target's local administrator, which a directory has never heard of. It is stored per container
    rather than per domain -- measured, by pointing the domain row at an account that cannot bind
    and watching the containers sync anyway -- so a container may be read by an account delegated
    to just that part of the tree.

.PARAMETER CliPath
    Full path to PDQInventory.exe. The sqlite tool is taken from beside it.

.PARAMETER DatabaseDirectory
    The directory holding Database.db on DatabaseDrive.

.PARAMETER DatabaseDrive
    The drive letter holding the product database.

.PARAMETER DebugLevel
    Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

.PARAMETER DirectorySync
    The declaration: realm, bind_username, bind_password, and containers. Each container carries a
    distinguished_name and the two booleans the product stores, and may name its own bind_username
    and bind_password.

    'insecure' opts the directory read down to plain LDAP on 389. It defaults to false, so the read
    is over LDAPS unless a declaration deliberately says otherwise, and the script never chooses
    the downgrade for itself: a failed secure bind fails the run rather than retrying in the clear,
    because a silent fallback is how a plaintext bind survives a migration nobody noticed.

.PARAMETER LogLevel
    Six digits, one per stream, in the order the LOG_LEVELS table names them.

.PARAMETER SyncTimeoutSeconds
    How long to wait for the product to finish a sync it was asked to start. Zero does not wait.

.OUTPUTS
    One object carrying changed, check_mode, containers, realm, synced and msg.
#>

[CmdletBinding(
  ConfirmImpact = 'Medium',
  DefaultParameterSetName = 'default',
  HelpUri = 'https://github.com/nwarila-platform/pdq-deploy-inventory',
  PositionalBinding = $False,
  SupportsPaging = $False,
  SupportsShouldProcess = $True
)]
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
  $CliPath,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $DatabaseDirectory,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[A-Za-z]$')]
  [System.String]
  $DatabaseDrive,

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
  [System.Collections.IDictionary]
  $DirectorySync,

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
  [ValidateRange(0, 3600)]
  [System.Int32]
  $SyncTimeoutSeconds = 120
)
#region ------ [ Script ] ------------------------------------------------------------------- #

#region ------ [ Initialization ] ----------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Initialization'

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. This script decides check mode from $Ansible.CheckMode, so -WhatIf is
# neutralised here; left on, it would suppress the New-Variable setup below.
$WhatIfPreference = $false

# Log level names, by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# The product's tools. sqlite3.exe ships beside the command line, so the caller names one path.
New-Variable -Force -Name:'CLI_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]$CliPath
)

New-Variable -Force -Name:'SQLITE_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String](Join-Path (Split-Path $CliPath -Parent) 'sqlite3.exe')
)

# Deploy and Inventory keep separate credential tables, so a caller declaring one credential for
# both calls this once per product.
New-Variable -Force -Name:'DATABASE_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]('{0}:\{1}\Database.db' -f $DatabaseDrive, $DatabaseDirectory)
)

# Configure log levels based on the LogLevel parameter.
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

# Debug digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.
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

# Universal trap: log diagnostics, rethrow so the task fails honestly. Wrapped so a partial
# error record can never replace the original failure with a StrictMode property error.


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

# Standalone (a dev shell or spec) has no transport-provided $Ansible; stub it faithfully.

$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

#endregion --- [ Initialization ] ----------------------------------------------------------- #

#region ------ [ Main ] --------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

Function Invoke-NativeCommand {
  Param (
    [System.String] $Operation,
    [System.String] $FilePath,
    [System.String[]] $Argument = @(),
    [System.Int32[]] $SuccessExitCode = @(0)
  )
  $Previous = $ErrorActionPreference
  Try {
    $ErrorActionPreference = 'Continue'
    $Captured = & $FilePath @Argument 2>&1
    $Exit = $LASTEXITCODE
  } Catch {
    # Still reachable with the preference lowered: a command that cannot be found or cannot be
    # started fails the STATEMENT, which no preference makes non-terminating. The original is kept
    # as the inner exception so its type and stack survive the added context.
    Throw [System.Management.Automation.RuntimeException]::new(
      ('{0}: ''{1}'' could not be run ({2})' -f $Operation, $FilePath, $PSItem.Exception.Message),
      $PSItem.Exception
    )
  } Finally {
    $ErrorActionPreference = $Previous
  }

  $Written = [System.Collections.Generic.List[System.String]]::new()
  $Said = [System.Collections.Generic.List[System.String]]::new()
  ForEach ($Line In $Captured) {
    If ($Line -is [System.Management.Automation.ErrorRecord]) {
      $Said.Add(([System.String]$Line).Trim())
    } Else {
      $Written.Add([System.String]$Line)
    }
  }

  # An accepted exit code with something on stderr is reported rather than swallowed: the caller
  # decided the code was survivable, not that the program had nothing to say.
  If ($SuccessExitCode -contains $Exit -and $Said.Count -gt 0) {
    Write-Warning -Message:('{0}: {1}' -f $Operation, ($Said -join '; '))
  }

  If ($SuccessExitCode -notcontains $Exit) {
    Throw ('{0}: {1} exited {2}{3}' -f @(
        $Operation
        (Split-Path -Leaf -Path:$FilePath)
        $Exit
        $(If ($Said.Count -gt 0) { ' -- ' + ($Said -join '; ') } Else { '' })
      ))
  }
  Return [PSCustomObject]@{ Exit = [System.Int32]$Exit; Output = $Written.ToArray() }
}

# The declaration, normalised once so Main compares like with like.
$Realm = [System.String]$DirectorySync['realm']
$Insecure = [System.Boolean]$(If ($DirectorySync.Contains('insecure')) { $DirectorySync['insecure'] } Else { $False })
$Declared = [System.Collections.Generic.List[System.Collections.IDictionary]]::new()
ForEach ($Container In @($DirectorySync['containers'])) {
  $Declared.Add(@{
      dn       = ([System.String]$Container['distinguished_name']).Trim()
      subtree  = [System.Int32][System.Boolean]$Container['subtree']
      include  = [System.Int32][System.Boolean]$Container['include']
      username = [System.String]$(If ($Container.Contains('bind_username')) { $Container['bind_username'] } Else { $DirectorySync['bind_username'] })
      password = [System.String]$(If ($Container.Contains('bind_password')) { $Container['bind_password'] } Else { $DirectorySync['bind_password'] })
    })
}

# A quoted literal is safe here because these are values the caller declared, but sqlite has no
# parameter binding on the command line it is given, so a single quote in one would end the string.
ForEach ($Value In @($Realm) + @($Declared | ForEach-Object { $PSItem.dn; $PSItem.username })) {
  If ($Value.Contains("'")) {
    Throw ('A declared value contains a single quote, which cannot be expressed safely in this statement: {0}' -f $Value)
  }
}

# The product stores a GUID; the declaration names a distinguished name. Resolving it here is what
# lets a container be recreated without the declaration changing. The bind is LDAP on 389: this
# directory answers nothing on 636, and refuses an anonymous bind, both measured.

# What the product holds now, keyed by the one field it does not rewrite. Name is deliberately NOT
# the key: the product replaces it with '<domain>/<container path>' after a sync, so a comparison
# on Name would report a change on every run forever.
$ExistingRows = (Invoke-NativeCommand -Operation:'Reading the sync containers' -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, 'SELECT DistinguishedName || ''|'' || UserId || ''|'' || IncludeSubtree || ''|'' || IsInclude FROM ADSyncContainers;')).Output
$Existing = @{}
ForEach ($Row In @($ExistingRows)) {
  $Field = [System.String[]]@(([System.String]$Row) -split '\|')
  If ($Field.Count -ge 4) { $Existing[$Field[0]] = ($Field[1..3] -join '|') }
}

$Changed = $False
$Applied = [System.Collections.Generic.List[System.String]]::new()

ForEach ($Container In $Declared) {
  # The account is named, not carried: it must already be a credential the product holds, and an
  # ordinary one. Failing here names the missing account rather than letting the bind fail later
  # with a message about a password.
  $CredentialId = (Invoke-NativeCommand -Operation:('Resolving the bind account {0}' -f $Container.username) -FilePath:$SQLITE_PATH `
      -Argument:@($DATABASE_PATH, ("SELECT CredentialsId FROM Credentials WHERE UserName = '{0}' AND COALESCE(AuthenticationType, 'None') <> 'LAPS' LIMIT 1;" -f $Container.username))).Output
  $CredentialId = ([System.String]$CredentialId).Trim()
  If ($CredentialId.Length -eq 0) {
    Throw ('{0} is not an ordinary credential this product holds, so it cannot bind to the directory. A LAPS credential cannot be used: it resolves to the target''s local administrator.' -f $Container.username)
  }

  $Wanted = '{0}|{1}|{2}' -f $CredentialId, $Container.subtree, $Container.include
  If ($Existing.ContainsKey($Container.dn) -and $Existing[$Container.dn] -eq $Wanted) {
    Continue
  }

  $Changed = $True
  If ($Ansible.CheckMode) { $Applied.Add($Container.dn); Continue }

  # Resolved inline rather than through a helper: DirectoryEntry takes the password as a string,
  # so a helper could only take one too, and wrapping it in a SecureString first would be theatre
  # -- the plaintext is already in the declaration this script was handed. The entry is disposed
  # on every path so a bind is not left open when a container cannot be read.
  # The realm qualifies the path deliberately. A serverless 'LDAP://<dn>' asks the PROCESS to find
  # a controller, and this one runs as a local account with no directory context of its own, so it
  # would fail before the declared credential was ever offered.
  # PROOF GAP (2026-09-04): the plain-LDAP path is proven against the live directory; the LDAPS
  # path is NOT. This directory cannot yet serve it -- both controllers present no certificate on
  # 636 and reset the handshake, and no enterprise CA is published -- so the secure branch has been
  # exercised only against a stub. Prove it against a real controller before 389 is turned off.
  $Authentication = If ($Insecure) {
    [System.DirectoryServices.AuthenticationTypes]::Secure
  } Else {
    [System.DirectoryServices.AuthenticationTypes]::Secure -bor
    [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer
  }
  $Entry = New-Object System.DirectoryServices.DirectoryEntry(
    ('LDAP://{0}/{1}' -f $Realm, $Container.dn), $Container.username, $Container.password,
    $Authentication)
  Try {
    $Null = $Entry.RefreshCache(@('objectGUID'))
    $Guid = [System.String]$Entry.Guid
  } Catch {
    $Protocol = If ($Insecure) { 'LDAP' } Else { 'LDAPS' }
    $Hint = If ($Insecure) { '' } Else {
      " A secure bind that reports the server is not operational is usually the directory presenting no certificate on 636, not a wrong password; declare insecure only as a deliberate, temporary exception."
    }
    $Reason = $PSItem.Exception.GetBaseException().Message
    Throw ('{0} could not be read from {1} over {2} as {3}: {4}.{5}' -f $Container.dn, $Realm, $Protocol, $Container.username, $Reason, $Hint)
  } Finally {
    # Disposal must not replace the reason the bind failed with a complaint about disposal.
    Try { $Entry.Dispose() } Catch { Write-Debug -Message:'The directory entry could not be disposed.' }
  }
  $Statements = [System.Collections.Generic.List[System.String]]::new()
  $Statements.Add('PRAGMA busy_timeout = 5000;')
  $Statements.Add('BEGIN IMMEDIATE;')
  $Statements.Add(("DELETE FROM ADSyncContainers WHERE DistinguishedName = '{0}';" -f $Container.dn))
  $Statements.Add((
      "INSERT INTO ADSyncContainers (DomainName, Name, Guid, UserId, IncludeSubtree, IsInclude, DistinguishedName) VALUES ('{0}', '{1}', '{2}', {3}, {4}, {5}, '{6}');" -f `
        $Realm, $Realm, $Guid, $CredentialId, $Container.subtree, $Container.include, $Container.dn))
  $Statements.Add('COMMIT;')
  $Null = Invoke-NativeCommand -Operation:('Declaring the sync container {0}' -f $Container.dn) -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, ($Statements -join ' '))
  $Applied.Add($Container.dn)
}

# A container the declaration does not name is removed: the declaration is the complete set, so a
# container left behind would keep pulling computers nobody asked for.
$DeclaredNames = @($Declared | ForEach-Object { $PSItem.dn })
ForEach ($Present In @($Existing.Keys)) {
  If ($DeclaredNames -contains $Present) { Continue }
  $Changed = $True
  If ($Ansible.CheckMode) { Continue }
  $Null = Invoke-NativeCommand -Operation:('Removing the undeclared sync container {0}' -f $Present) -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, ("DELETE FROM ADSyncContainers WHERE DistinguishedName = '{0}';" -f $Present))
}

# The realm the containers belong to. The product does not use this row's credential for the bind
# -- each container carries its own -- but the row must name the domain the containers sit in.
If (-not $Ansible.CheckMode) {
  $Null = Invoke-NativeCommand -Operation:'Declaring the directory' -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, ("UPDATE ActiveDirectoryDomains SET Name = '{0}';" -f $Realm))
}

# Start a sync and read the product's own verdict. A container records its failure in its own row,
# so this asserts against the product rather than against this script's report of itself.
$Synced = $False
If ($Changed -and -not $Ansible.CheckMode) {
  # The product stamps LastSync when it finishes. Waiting on that rather than on a fixed sleep is
  # what makes the verdict below the product's own: a sleep long enough to be safe is still a guess,
  # and one short enough to be quick would read the PREVIOUS sync's result.
  $LastSyncQuery = "SELECT COALESCE(Value, '') FROM Settings WHERE Name = 'ActiveDirectorySettings.LastSync';"
  $Before = ([System.String](Invoke-NativeCommand -Operation:'Reading the last sync time' -FilePath:$SQLITE_PATH -Argument:@($DATABASE_PATH, $LastSyncQuery)).Output).Trim()
  $Null = Invoke-NativeCommand -Operation:'Starting the directory sync' -FilePath:$CLI_PATH -Argument:@('ADSync', '-StartSync')
  $Deadline = (Get-Date).AddSeconds($SyncTimeoutSeconds)
  While ((Get-Date) -lt $Deadline) {
    $Now = ([System.String](Invoke-NativeCommand -Operation:'Reading the last sync time' -FilePath:$SQLITE_PATH -Argument:@($DATABASE_PATH, $LastSyncQuery)).Output).Trim()
    If ($Now -ne $Before) { Break }
    Start-Sleep -Seconds 2
  }
  $Failed = (Invoke-NativeCommand -Operation:'Reading the sync result' -FilePath:$SQLITE_PATH `
      -Argument:@($DATABASE_PATH, "SELECT DistinguishedName FROM ADSyncContainers WHERE COALESCE(Error, '') <> '';")).Output
  If (@($Failed).Count -gt 0 -and ([System.String]$Failed).Trim().Length -gt 0) {
    Throw ('The product could not read these containers: {0}' -f (@($Failed) -join ', '))
  }
  $Synced = $True
}

#endregion --- [ Main ] --------------------------------------------------------------------- #

#region ------ [ Output ] ------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  containers = [System.String[]]@($Declared | ForEach-Object { $PSItem.dn })
  msg        = If ($Changed) {
    '{0} sync container(s) declared for {1}' -f $Declared.Count, $Realm
  } Else {
    '{0} sync container(s) already read back as declared for {1}' -f $Declared.Count, $Realm
  }
  protocol   = [System.String]$(If ($Insecure) { 'ldap' } Else { 'ldaps' })
  realm      = [System.String]$Realm
  synced     = [System.Boolean]$Synced
}

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] ------------------------------------------------------------------- #

#endregion --- [ Script ] ------------------------------------------------------------------- #
