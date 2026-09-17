#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Makes one PDQ product's credential store equal its declaration.

    .DESCRIPTION
        The declaration is the complete credential set. Every declared credential is written,
        every credential whose exact username is absent is removed, and a non-empty declaration
        settles exactly one default. An empty declaration empties the store.

        A credential is either ORDINARY -- it authenticates as the account it names -- or LAPS,
        where the product resolves each target's local administrator password from Active
        Directory at connect time using a domain account authorised to read it. The declaration
        chooses LAPS by carrying laps_user.

        UpdateScanCredential and UpdateDeployCredential own the secret because the Password
        column holds product ciphertext that must not be reproduced outside the product. Each
        password is passed to that command on stdin, never as an argument. The command line has no
        words for the LAPS fields, description, default, or removal, so after it has stored every
        secret this script makes the complete non-secret state authoritative in one immediate
        database transaction. A fresh read after commit must equal the declaration.

    .PARAMETER CliPath
        Full path to the product command line. sqlite3.exe is taken from beside it.

    .PARAMETER CredentialDeclarations
        The complete credential list. Each entry carries:
          username     the account the credential names
          password     its password
          laps_user    optional managed local administrator; present makes this LAPS
          description  optional console description
          is_default   true for exactly one entry in a non-empty declaration

    .PARAMETER DatabaseDirectory
        Directory on DatabaseDrive holding Database.db.

    .PARAMETER DatabaseDrive
        Drive letter the product database lives on.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per preference in Verbose, Debug, Information, Warning, Error, Fatal order.

    .PARAMETER Product
        Deploy or Inventory. Each keeps its own credential store.

    .OUTPUTS
        One object carrying changed, check_mode, credentials, declared, removed, msg and product.
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
  [AllowEmptyCollection()]
  [System.Collections.IDictionary[]]
  $CredentialDeclarations,

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
  [ValidateSet('Deploy', 'Inventory')]
  [System.String]
  $Product
)

#region ------ [ Script ] ------------------------------------------------------------------- #

#region ------ [ Initialization ] ----------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Initialization'

# The module injects -WhatIf in check mode. This script takes check mode from $Ansible, so leave
# setup and reads active and explicitly withhold the writes below.
$WhatIfPreference = $false

New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)
New-Variable -Force -Name:'CLI_PATH' -Option:'ReadOnly' -Value:(
  [System.String]$CliPath
)
New-Variable -Force -Name:'SQLITE_PATH' -Option:'ReadOnly' -Value:(
  [System.String](Join-Path (Split-Path $CliPath -Parent) 'sqlite3.exe')
)
New-Variable -Force -Name:'DATABASE_PATH' -Option:'ReadOnly' -Value:(
  [System.String]('{0}:\{1}\Database.db' -f $DatabaseDrive, $DatabaseDirectory)
)
New-Variable -Force -Name:'LAPS_AUTHENTICATION_TYPE' -Option:'ReadOnly' -Value:(
  [System.String]'LAPS'
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

If (-not (Test-Path -LiteralPath:$CLI_PATH -PathType:'Leaf')) {
  Throw ('The PDQ {0} command line is not at ''{1}''' -f $Product, $CLI_PATH)
}
If (-not (Test-Path -LiteralPath:$SQLITE_PATH -PathType:'Leaf')) {
  Throw ('The product database tool is not at ''{0}''' -f $SQLITE_PATH)
}
If (-not (Test-Path -LiteralPath:$DATABASE_PATH -PathType:'Leaf')) {
  Throw ('The database is not at ''{0}''' -f $DATABASE_PATH)
}

$Utf8 = [System.Text.UTF8Encoding]::new($False, $True)

Function ConvertTo-TextHex {
  Param ([System.String]$Value)
  Return -join ($Utf8.GetBytes($Value) | ForEach-Object { $PSItem.ToString('X2') })
}

Function ConvertFrom-TextHex {
  Param ([System.String]$Value, [System.String]$Field)
  If ($Value -notmatch '^(?:[0-9A-Fa-f]{2})*$') {
    Throw ('A credential {0} did not read back as even hex: {1}' -f $Field, $Value)
  }
  $Bytes = [System.Byte[]]::new($Value.Length / 2)
  For ($B = 0; $B -lt $Bytes.Length; $B++) {
    $Bytes[$B] = [System.Convert]::ToByte($Value.Substring($B * 2, 2), 16)
  }
  Try {
    Return $Utf8.GetString($Bytes)
  } Catch {
    Throw ('A credential {0} is not UTF-8' -f $Field)
  }
}

Function Read-CredentialRow {
  $Query = @'
SELECT CredentialsId,
       hex(UserName),
       COALESCE(IsDefault, 0),
       hex(CASE WHEN COALESCE(AuthenticationType, '') IN ('', 'None') THEN '' ELSE AuthenticationType END),
       hex(COALESCE(LAPSUser, '')),
       hex(COALESCE(Description, ''))
FROM Credentials
ORDER BY CredentialsId;
'@.Trim()
  $Answer = Invoke-NativeCommand -Operation:'Reading the credential store' -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, $Query)
  $Rows = [System.Collections.Generic.List[System.Object]]::new()
  $Names = [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::Ordinal)
  ForEach ($Line In $Answer.Output) {
    $Parts = ([System.String]$Line).Split('|')
    If ($Parts.Count -ne 6 -or $Parts[0] -notmatch '^[0-9]+$' -or $Parts[2] -notmatch '^[01]$') {
      Throw ('The credential store did not read back in the expected six-field shape: {0}' -f $Line)
    }
    $Name = ConvertFrom-TextHex -Value:$Parts[1] -Field:'username'
    If (-not $Names.Add($Name)) {
      Throw ('The product holds more than one credential with the exact username {0}; resolve the duplicate first' -f $Name)
    }
    $Rows.Add([PSCustomObject]@{
        Id                 = $Parts[0]
        Hex                = $Parts[1].ToUpperInvariant()
        Name               = $Name
        IsDefault          = $Parts[2]
        AuthenticationType = ConvertFrom-TextHex -Value:$Parts[3] -Field:'authentication type'
        LapsUser           = ConvertFrom-TextHex -Value:$Parts[4] -Field:'LAPS user'
        Description        = ConvertFrom-TextHex -Value:$Parts[5] -Field:'description'
      })
  }
  Return $Rows.ToArray()
}

Function Assert-NoCredentialTrigger {
  $Trigger = (Invoke-NativeCommand -Operation:'Reading the credential triggers' -FilePath:$SQLITE_PATH `
      -Argument:@($DATABASE_PATH, "SELECT name FROM sqlite_master WHERE type = 'trigger' AND lower(tbl_name) = lower('Credentials');")).Output
  If (@($Trigger).Count -gt 0) {
    Throw 'The Credentials table has a trigger; its side effects are not declared and reconciliation is refused.'
  }
}

Function Test-CredentialState {
  Param (
    [System.Object[]]$Row,
    [System.Collections.IDictionary[]]$Declaration
  )
  If ($Row.Count -ne $Declaration.Count) { Return $False }
  $ByName = [System.Collections.Generic.Dictionary[System.String, System.Object]]::new([System.StringComparer]::Ordinal)
  ForEach ($Present In $Row) { $ByName.Add($Present.Name, $Present) }
  ForEach ($Wanted In $Declaration) {
    If (-not $ByName.ContainsKey($Wanted.username)) { Return $False }
    $Present = $ByName[$Wanted.username]
    If ($Present.IsDefault -ne [System.String]$Wanted.is_default -or
        $Present.AuthenticationType -cne $Wanted.authentication_type -or
        $Present.LapsUser -cne $Wanted.laps_user -or
        $Present.Description -cne $Wanted.description) {
      Return $False
    }
  }
  Return $True
}

$Declared = [System.Collections.Generic.List[System.Collections.IDictionary]]::new()
$DeclaredNames = [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::Ordinal)
$DefaultCount = 0
ForEach ($Credential In @($CredentialDeclarations)) {
  If ($Null -eq $Credential -or -not $Credential.Contains('username') -or
      [System.String]::IsNullOrWhiteSpace([System.String]$Credential['username'])) {
    Throw 'A credential declaration carried no username.'
  }
  $Username = [System.String]$Credential['username']
  If (-not $DeclaredNames.Add($Username)) {
    Throw ('{0} is declared more than once; two declarations cannot own one credential' -f $Username)
  }
  $IsDefault = [System.Boolean]$(If ($Credential.Contains('is_default')) { $Credential['is_default'] } Else { $False })
  If ($IsDefault) { $DefaultCount++ }
  $LapsUser = [System.String]$(If ($Credential.Contains('laps_user')) { $Credential['laps_user'] } Else { '' })
  $Declared.Add(@{
      username            = $Username
      username_hex        = ConvertTo-TextHex -Value:$Username
      password            = [System.String]$(If ($Credential.Contains('password')) { $Credential['password'] } Else { '' })
      laps_user           = $LapsUser
      laps_user_hex       = ConvertTo-TextHex -Value:$LapsUser
      authentication_type = [System.String]$(If ($LapsUser.Length -gt 0) { $LAPS_AUTHENTICATION_TYPE } Else { '' })
      description         = [System.String]$(If ($Credential.Contains('description')) { $Credential['description'] } Else { '' })
      is_default          = [System.String][System.Int32]$IsDefault
    })
  $Declared[$Declared.Count - 1]['description_hex'] = ConvertTo-TextHex -Value:$Declared[$Declared.Count - 1].description
}
If (($Declared.Count -eq 0 -and $DefaultCount -ne 0) -or
    ($Declared.Count -gt 0 -and $DefaultCount -ne 1)) {
  Throw ('A non-empty credential declaration must name exactly one default; {0} of {1} did.' -f $DefaultCount, $Declared.Count)
}

$Before = @(Read-CredentialRow)
Assert-NoCredentialTrigger
$Changed = -not (Test-CredentialState -Row:$Before -Declaration:$Declared.ToArray())
$Removed = [System.String[]]@($Before | Where-Object { -not $DeclaredNames.Contains($PSItem.Name) } | ForEach-Object Name)

If (-not $Ansible.CheckMode) {
  $Verb = If ($Product -eq 'Deploy') { 'UpdateDeployCredential' } Else { 'UpdateScanCredential' }
  ForEach ($Credential In $Declared) {
    # The secret is written on every run because its ciphertext cannot be read back. Rewriting is
    # the only way an upstream rotation reaches the product, and does not by itself make the
    # non-secret comparison report a change.
    $Previous = $ErrorActionPreference
    Try {
      $ErrorActionPreference = 'Continue'
      $Null = $Credential.password | & $CLI_PATH $Verb -Username $Credential.username -CreateIfNotExists 2>&1
      $Exit = $LASTEXITCODE
    } Finally {
      $ErrorActionPreference = $Previous
    }
    If ($Exit -ne 0) {
      Throw ('{0} exited {1} storing the credential for {2}.' -f $Verb, $Exit, $Credential.username)
    }
  }

  # The command line may have created rows and may have normalised an ordinary row while writing
  # another. Snapshot after every secret is stored, then bind every direct database mutation to
  # that exact identity inside one transaction.
  $Ready = @(Read-CredentialRow)
  $ReadyByName = [System.Collections.Generic.Dictionary[System.String, System.Object]]::new([System.StringComparer]::Ordinal)
  ForEach ($Row In $Ready) { $ReadyByName.Add($Row.Name, $Row) }
  ForEach ($Credential In $Declared) {
    If (-not $ReadyByName.ContainsKey($Credential.username)) {
      Throw ('{0} reported success but the credential for {1} is absent.' -f $Verb, $Credential.username)
    }
  }

  $Statements = [System.Collections.Generic.List[System.String]]::new()
  $Statements.Add('PRAGMA foreign_keys=OFF;')
  $Statements.Add('PRAGMA busy_timeout=5000;')
  $Statements.Add('BEGIN IMMEDIATE;')
  $Statements.Add('CREATE TEMP TABLE ExpectedCredential (CredentialsId INTEGER NOT NULL PRIMARY KEY, UserNameHex TEXT NOT NULL);')
  $Statements.Add(@'
CREATE TEMP TABLE DeclaredCredential (
  UserNameHex TEXT NOT NULL PRIMARY KEY,
  IsDefault INTEGER NOT NULL,
  AuthenticationTypeHex TEXT NOT NULL,
  LAPSUserHex TEXT NOT NULL,
  DescriptionHex TEXT NOT NULL
);
'@.Trim())
  $Statements.Add(@'
CREATE TEMP TABLE CredentialGuard (
  SnapshotOk INTEGER CONSTRAINT credential_snapshot_changed CHECK (SnapshotOk = 1),
  TriggerOk INTEGER CONSTRAINT credential_trigger_present CHECK (TriggerOk = 1),
  EffectOk INTEGER CONSTRAINT credential_write_effect CHECK (EffectOk = 1),
  FinalOk INTEGER CONSTRAINT credential_final_mismatch CHECK (FinalOk = 1)
);
'@.Trim())
  ForEach ($Row In $Ready) {
    $Statements.Add(("INSERT INTO ExpectedCredential (CredentialsId, UserNameHex) VALUES ({0}, '{1}');" -f $Row.Id, $Row.Hex))
  }
  ForEach ($Credential In $Declared) {
    $Statements.Add(("INSERT INTO DeclaredCredential (UserNameHex, IsDefault, AuthenticationTypeHex, LAPSUserHex, DescriptionHex) VALUES ('{0}', {1}, '{2}', '{3}', '{4}');" -f @(
          $Credential.username_hex
          $Credential.is_default
          (ConvertTo-TextHex -Value:$Credential.authentication_type)
          $Credential.laps_user_hex
          $Credential.description_hex
        )))
  }
  $Statements.Add(@'
INSERT INTO CredentialGuard (SnapshotOk)
VALUES (CASE WHEN
  (SELECT COUNT(*) FROM Credentials) = (SELECT COUNT(*) FROM ExpectedCredential)
  AND NOT EXISTS (
    SELECT 1 FROM Credentials AS C
    LEFT JOIN ExpectedCredential AS E
      ON E.CredentialsId = C.CredentialsId AND E.UserNameHex = hex(C.UserName)
    WHERE E.CredentialsId IS NULL
  )
  AND NOT EXISTS (
    SELECT 1 FROM ExpectedCredential AS E
    LEFT JOIN Credentials AS C
      ON C.CredentialsId = E.CredentialsId AND hex(C.UserName) = E.UserNameHex
    WHERE C.CredentialsId IS NULL
  )
THEN 1 ELSE 0 END);
'@.Trim())
  $Statements.Add(@'
INSERT INTO CredentialGuard (TriggerOk)
VALUES (CASE WHEN NOT EXISTS (
  SELECT 1 FROM sqlite_master
  WHERE type = 'trigger' AND lower(tbl_name) = lower('Credentials')
) THEN 1 ELSE 0 END);
'@.Trim())
  ForEach ($Credential In $Declared) {
    $Row = $ReadyByName[$Credential.username]
    $Kind = If ($Credential.authentication_type -eq $LAPS_AUTHENTICATION_TYPE) {
      "LAPSUser = CAST(X'{0}' AS TEXT), AuthenticationType = 'LAPS'" -f $Credential.laps_user_hex
    } Else {
      'LAPSUser = NULL, AuthenticationType = NULL'
    }
    $Statements.Add(("UPDATE Credentials SET {0}, Description = CAST(X'{1}' AS TEXT), IsDefault = {2} WHERE CredentialsId = {3} AND hex(UserName) = '{4}';" -f @(
          $Kind
          $Credential.description_hex
          $Credential.is_default
          $Row.Id
          $Row.Hex
        )))
    $Statements.Add('INSERT INTO CredentialGuard (EffectOk) VALUES (changes());')
  }
  ForEach ($Row In $Ready) {
    If ($DeclaredNames.Contains($Row.Name)) { Continue }
    $Statements.Add(("DELETE FROM Credentials WHERE CredentialsId = {0} AND hex(UserName) = '{1}';" -f $Row.Id, $Row.Hex))
    $Statements.Add('INSERT INTO CredentialGuard (EffectOk) VALUES (changes());')
  }
  $Statements.Add(@'
INSERT INTO CredentialGuard (FinalOk)
VALUES (CASE WHEN
  (SELECT COUNT(*) FROM Credentials) = (SELECT COUNT(*) FROM DeclaredCredential)
  AND NOT EXISTS (
    SELECT 1 FROM Credentials AS C
    LEFT JOIN DeclaredCredential AS D ON D.UserNameHex = hex(C.UserName)
    WHERE D.UserNameHex IS NULL
       OR COALESCE(C.IsDefault, 0) <> D.IsDefault
       OR hex(CASE WHEN COALESCE(C.AuthenticationType, '') IN ('', 'None') THEN '' ELSE C.AuthenticationType END) <> D.AuthenticationTypeHex
       OR hex(COALESCE(C.LAPSUser, '')) <> D.LAPSUserHex
       OR hex(COALESCE(C.Description, '')) <> D.DescriptionHex
  )
  AND NOT EXISTS (
    SELECT 1 FROM DeclaredCredential AS D
    WHERE NOT EXISTS (SELECT 1 FROM Credentials AS C WHERE hex(C.UserName) = D.UserNameHex)
  )
THEN 1 ELSE 0 END);
'@.Trim())
  $Statements.Add('COMMIT;')

  $Null = Invoke-NativeCommand -Operation:'Making the credential declaration authoritative' `
    -FilePath:$SQLITE_PATH -Argument:@('-bail', $DATABASE_PATH, ($Statements -join ' '))

  $After = @(Read-CredentialRow)
  If (-not (Test-CredentialState -Row:$After -Declaration:$Declared.ToArray())) {
    Throw 'The credential store does not read back as declared after the transaction committed.'
  }
}

$Message = If ($Changed) {
  If ($Ansible.CheckMode) {
    'Would declare {0} credential(s) as the complete PDQ {1} set' -f $Declared.Count, $Product
  } Else {
    'Declared {0} credential(s) as the complete PDQ {1} set' -f $Declared.Count, $Product
  }
} Else {
  '{0} PDQ {1} credential(s) already read back as declared' -f $Declared.Count, $Product
}

$Result = [PSCustomObject]@{
  changed     = [System.Boolean]$Changed
  check_mode  = [System.Boolean]$Ansible.CheckMode
  credentials = [System.String[]]@($Declared | ForEach-Object username)
  declared    = [System.Int32]$Declared.Count
  removed     = $Removed
  msg         = [System.String]$Message
  product     = [System.String]$Product
}

#endregion --- [ Main ] --------------------------------------------------------------------- #

#region ------ [ Output ] ------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] ------------------------------------------------------------------- #

#endregion --- [ Script ] ------------------------------------------------------------------- #
