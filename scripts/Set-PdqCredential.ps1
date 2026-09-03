#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Declares the credential PDQ authenticates to targets with.

    .DESCRIPTION
        PDQ reaches a target over its admin share, so the identity it presents has to be a local
        administrator ON THAT MACHINE. A domain service account is not one, and the account the
        console runs as is local to the console -- which is why an undeclared deployment scans
        nothing and deploys nowhere.

        A LAPS credential resolves that: the product reads each target's LAPS-managed local
        administrator password out of Active Directory at connect time, using a domain account
        authorised to read it. One credential covers every machine, no account holds standing
        rights anywhere, and the password rotating is the point rather than a problem.

        The command line cannot express one. UpdateScanCredential and UpdateDeployCredential take
        a username and a password and nothing else, so the LAPS fields are set in the product's
        own database. The secret is NOT written that way: the command line stores it, because the
        Password column holds ciphertext behind an '(encrypted)' marker and reproducing that
        outside the product would be guessing at someone else's cryptography. So the command line
        owns the secret and the database owns the two fields the command line has no words for.

    .PARAMETER LapsCredential
        The declaration. Keys:
          reader_username  the AD account that reads LAPS passwords, DOMAIN\name
          reader_password  its password
          laps_user        the managed local administrator on each target, e.g. Administrator
          description      optional, shown in the console

    .PARAMETER Product
        'Deploy' or 'Inventory'. Each keeps its own credential store.

    .PARAMETER CliPath
        Full path to the product's command line. sqlite3.exe is taken from beside it.

    .PARAMETER DatabaseDrive
        Drive letter the product's database lives on.

    .PARAMETER DatabaseDirectory
        Directory on that drive holding Database.db.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per preference in Verbose, Debug, Information, Warning, Error, Fatal order.

    .EXAMPLE
        .\Set-PdqCredential.ps1 -Product 'Inventory' -Credential @{
            reader_username = 'TCN\svc-pdq'; reader_password = '...'; laps_user = 'Administrator'
        } -CliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe' `
          -DatabaseDrive 'D' -DatabaseDirectory 'PDQ Inventory'

    .OUTPUTS
        System.Void
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
  [System.String]
  $CliPath,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
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
  $LapsCredential,

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

# What the product records for a credential that resolves its password from LAPS at connect
# time rather than carrying one of its own.
New-Variable -Force -Name:'LAPS_AUTHENTICATION_TYPE' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'LAPS'
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
$ReaderUsername = [System.String]$LapsCredential['reader_username']
$ReaderPassword = [System.String]$LapsCredential['reader_password']
$LapsUser = [System.String]$LapsCredential['laps_user']
$Description = [System.String]$(If ($LapsCredential.Contains('description')) { $LapsCredential['description'] } Else { '' })

# What the product holds now. A quoted literal is safe here because the value is a username the
# caller declared, but sqlite has no parameter binding on this command line, so a single quote in
# it would end the string -- refuse rather than build a statement that means something else.
If ($ReaderUsername.Contains("'") -or $LapsUser.Contains("'") -or $Description.Contains("'")) {
  Throw 'A declared credential value contains a single quote, which cannot be expressed safely in this statement.'
}

$Existing = (Invoke-NativeCommand -Operation:'Reading the credential store' -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, ("SELECT IsDefault, AuthenticationType, LAPSUser, Description FROM Credentials WHERE UserName = '{0}';" -f $ReaderUsername))).Output
$Strays = (Invoke-NativeCommand -Operation:'Counting the credentials that also claim the default' -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, ("SELECT COUNT(*) FROM Credentials WHERE IsDefault = 1 AND UserName <> '{0}';" -f $ReaderUsername))).Output

# The secret is deliberately absent from this comparison: it is stored as ciphertext behind an
# '(encrypted)' marker and cannot be read back, so these fields are the whole of what 'changed'
# can honestly report on. A missing row reads as an empty string and so counts as changed.
$Declared = '1|{0}|{1}|{2}' -f $LAPS_AUTHENTICATION_TYPE, $LapsUser, $Description
$Changed = ([System.String]$Existing -ne $Declared) -or ([System.String]$Strays -ne '0')

If (-not $Ansible.CheckMode) {
  # The password is written on every run, precisely because it cannot be read back: writing it is
  # the only way for a rotation upstream to reach the product. The command line owns the secret --
  # reproducing that ciphertext outside the product would be guessing at someone else's
  # cryptography -- and takes it on stdin rather than as an argument, because this image audits
  # process creation with command lines.
  # Invoke-NativeCommand cannot express stdin, so this one call carries the same contract by
  # hand: the preference is lowered across it because a native command that writes to stderr
  # fails the STATEMENT at Stop, which is what this script runs at.
  $Verb = If ($Product -eq 'Deploy') { 'UpdateDeployCredential' } Else { 'UpdateScanCredential' }
  $Previous = $ErrorActionPreference
  Try {
    $ErrorActionPreference = 'Continue'
    $Null = $ReaderPassword | & $CLI_PATH $Verb -Username $ReaderUsername -CreateIfNotExists 2>&1
    $Exit = $LASTEXITCODE
  } Finally {
    $ErrorActionPreference = $Previous
  }
  If ($Exit -ne 0) {
    Throw ('{0} exited {1} storing the credential for {2}.' -f $Verb, $Exit, $ReaderUsername)
  }

  # That call writes an ordinary credential, so the fields that make this a LAPS one follow it
  # every run rather than only when something differs. One transaction: a row carrying a LAPS user
  # without the matching authentication type is a credential the product would try to use as an
  # ordinary one, with a password that is not its own.
  $Statements = [System.Collections.Generic.List[System.String]]::new()
  $Statements.Add('PRAGMA busy_timeout = 5000;')
  $Statements.Add('BEGIN IMMEDIATE;')
  $Statements.Add(("UPDATE Credentials SET LAPSUser = '{0}', AuthenticationType = '{1}', Description = '{2}', IsDefault = 1 WHERE UserName = '{3}';" -f `
        $LapsUser, $LAPS_AUTHENTICATION_TYPE, $Description, $ReaderUsername))
  # Exactly one default: a second would leave which credential a scan picks to insertion order.
  $Statements.Add(("UPDATE Credentials SET IsDefault = 0 WHERE UserName <> '{0}';" -f $ReaderUsername))
  $Statements.Add('COMMIT;')
  $Null = Invoke-NativeCommand -Operation:'Declaring the credential as LAPS' -FilePath:$SQLITE_PATH `
    -Argument:@($DATABASE_PATH, ($Statements -join ' '))
}

#endregion --- [ Main ] --------------------------------------------------------------------- #

#region ------ [ Output ] ------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  credential = [System.String]$ReaderUsername
  laps_user  = [System.String]$LapsUser
  msg        = If ($Changed) {
    'Declared {0} as the default LAPS credential for PDQ {1}' -f $ReaderUsername, $Product
  } Else {
    '{0} already reads back as the default LAPS credential for PDQ {1}' -f $ReaderUsername, $Product
  }
  product    = [System.String]$Product
}

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] ------------------------------------------------------------------- #

#endregion --- [ Script ] ------------------------------------------------------------------- #
