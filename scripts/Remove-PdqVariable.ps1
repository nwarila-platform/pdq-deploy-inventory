#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Removes every PDQ custom variable the declaration does not name.

    .DESCRIPTION
        The declaration is COMPLETE. The names in -Name are the custom variables the product is
        required to hold, and anything else it holds is drift. Removing it is not an option the
        caller turns on: a role that states an end state and then leaves strangers standing has
        not stated the end state. Declaring nothing declares that the product holds none, which is
        the same promise read in the other direction, not a special case.

        The command line can create a variable and read them all back, but has no verb that
        deletes one, so removal goes through the product's OWN database tooling: the sqlite3.exe
        the vendor ships beside the command line, against the database path the product itself
        reports through SystemInfo -- the same path, tool and transaction discipline the
        registration script already uses to write this database. Each undeclared name is deleted
        in one immediate transaction under a busy timeout, so a lock waits rather than fails and
        a mid-batch failure leaves no partial prune behind.

        The product's own export is the verify oracle on both sides of the write: what it holds
        decides what is removed, and the export is read AGAIN afterwards, so a delete the database
        accepted and did not perform -- or one the service undid -- fails the run rather than
        reporting a removal that did not happen.

        Names are matched case-insensitively, agreeing with the import script, which treats a
        name differing only by case as the same variable. Matching exactly here would delete a
        variable the import had just accepted as satisfying the declaration.

        One process stage (read -> act -> verify -> one result); shipped by the org three-file
        convention (the scripts/ pair plus each role's .stub).

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

    .PARAMETER Name
        The COMPLETE set of declared variable names. Required, and required even when empty, so
        emptying the product is something a caller states rather than something it forgets to
        pass. Values play no part here: what a variable should say is the import script's
        business, and whether it may exist at all is this one's.

    .PARAMETER CliPath
        Full path to the product's command line -- PDQDeploy.exe or PDQInventory.exe. Both
        products keep their own variable store and ship the same tooling beside the executable,
        so one script serves either.

    .EXAMPLE
        .\Remove-PdqVariable.ps1 -Name @('GoogleLlc_GoogleChrome') -CliPath $DeployCliPath

    .OUTPUTS
        One object carrying removed, kept, declared, changed, check_mode and msg.
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
  [AllowEmptyCollection()]
  [System.String[]] $Name,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String] $CliPath
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. This script decides check mode from $Ansible.CheckMode, so -WhatIf is
# neutralised here; left on, it would suppress the New-Variable setup below.
$WhatIfPreference = $false

# Log level names, by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# Export staging: the product writes every custom variable here, this reads it whole and deletes
# it. Its own filename, so an interleaved run of the import script can never hand this one a stale
# file.
# ReadOnly but NOT Private: Private blocks the read from inside Get-ExportedVariableName, which
# runs in a child scope.
New-Variable -Force -Name:'EXPORT_PATH' -Option:'ReadOnly' -Value:(
  [System.String]'C:\Windows\Temp\pdq-variables-prune.xml'
)

# Custom stream preferences; built-ins already exist.
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

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# The command line is the one thing this script cannot do without, so a wrong path says so here
# rather than as a failure to run some particular operation later.
If (-not (Test-Path -LiteralPath:$CliPath -PathType:'Leaf')) {
  Throw ('The PDQ command line is not at ''{0}''' -f $CliPath)
}

# The ONE place a native command is run, so every failure names the operation that failed instead
# of surfacing the program's bare text, and every exit code is judged against a policy the caller
# states rather than a convention the reader has to infer.
#
# ErrorActionPreference is lowered across the call, and that part is load-bearing. Under Windows
# PowerShell 5.1 a native command's stderr is raised as a TERMINATING error while the preference is
# Stop -- redirected, discarded, or not -- so the call throws before its exit code can be read.
# Measured on the target 2026-08-25: bare, 2>$null and 2>&1 all threw at Stop; all three completed
# with the preference lowered. That matters because the product writes to stderr on ORDINARY paths:
# "not found" alongside exit 3 is how it says a thing is ABSENT, which is the answer the caller
# wants. The assignment is function-scoped, so it governs this call and dies at return -- the
# caller's preference is never altered, and the restore below simply ends the window early rather
# than letting it cover the rest of this function.
#
# Merging stderr and separating it back out is NOT required for the run to succeed -- measured, the
# task passes either way -- and is done for two smaller reasons: an unmerged record lands in the
# module's error output on every ordinary absent-check, which would leave that channel meaning
# nothing, and what the program said is worth quoting when an exit code IS rejected.
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

# What the product holds, read the only way it offers: the export of every custom variable. Exit 3
# is the product saying it holds none -- an empty current state, not a failure -- and any OTHER
# outcome that produces no file is a read that failed, which must never be read as "holds
# nothing": that is the one mistake a pruner must not make.
Function Get-ExportedVariableName {
  If (Test-Path -LiteralPath:$EXPORT_PATH) {
    Remove-Item -LiteralPath:$EXPORT_PATH -Force
  }
  $Export = Invoke-NativeCommand -FilePath:$CliPath -Operation:'Exporting the variables' `
    -Argument:@('ExportVariables', '-Path', $EXPORT_PATH, '-Overwrite') -SuccessExitCode:@(0, 3)
  $Names = [System.Collections.Generic.List[System.String]]::new()
  If ($Export.Exit -eq 0) {
    If (-not (Test-Path -LiteralPath:$EXPORT_PATH)) {
      Throw 'ExportVariables reported success and wrote no file'
    }
    $Document = [System.Xml.XmlDocument]::new()
    $Document.LoadXml((Get-Content -LiteralPath:$EXPORT_PATH -Raw))
    Remove-Item -LiteralPath:$EXPORT_PATH -Force
    # Explicit SelectSingleNode, never the property adapter: a child named 'Name' would otherwise
    # collide with XmlNode's own Name property.
    ForEach ($Node In @($Document.SelectNodes('//CustomVariable'))) {
      $NameNode = $Node.SelectSingleNode('Name')
      If ($Null -ne $NameNode) {
        $Names.Add($NameNode.InnerText)
      }
    }
  }
  # Returned with a leading comma so an EMPTY list stays a list: PowerShell unrolls a bare empty
  # array out of a function as $Null.
  Return , $Names.ToArray()
}

# Matched case-INSENSITIVELY, to agree with the import script: its current-state lookup treats a
# name differing only by case as the same variable, so a case-variant of a declared name has
# already been accepted as satisfying the declaration. Matching exactly here would delete it.
$DeclaredSet = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.String[]]$Name, [System.StringComparer]::OrdinalIgnoreCase
)

$Held = Get-ExportedVariableName
$Extra = @($Held | Where-Object { -not $DeclaredSet.Contains($PSItem) })
$Kept = @($Held | Where-Object { $DeclaredSet.Contains($PSItem) })

$Removed = [System.Collections.Generic.List[System.String]]::new()

If (-not $Ansible.CheckMode) {
  If ($Extra.Count -gt 0) {
    # The command line has no verb that deletes a variable, so removal goes through the vendor's
    # own database tooling, exactly as the registration script already does: the sqlite3.exe
    # shipped beside the command line, against the database path the product itself reports.
    $Sqlite = Join-Path -Path (Split-Path -Path $CliPath -Parent) -ChildPath 'sqlite3.exe'
    If (-not (Test-Path -LiteralPath:$Sqlite -PathType:'Leaf')) {
      Throw ('The product database tool is not at ''{0}''' -f $Sqlite)
    }

    # Where the database lives is a deployment choice, so it is asked for rather than assumed: the
    # product reports its own path and cannot be wrong about it.
    $Info = (Invoke-NativeCommand -Operation:'Reading the product system information' `
        -FilePath:$CliPath -Argument:@('SystemInfo')).Output
    $DatabasePath = (
      @($Info | Where-Object -FilterScript { $PSItem -match '^\s*Database\s*:' }) |
        Select-Object -First 1
    ) -replace '^\s*Database\s*:\s*', ''
    If (-not $DatabasePath) {
      Throw 'SystemInfo did not report a database path'
    }
    If (-not (Test-Path -LiteralPath:$DatabasePath)) {
      Throw ('The database is not at {0}' -f $DatabasePath)
    }

    # One DELETE per name, the whole batch one immediate transaction under a busy timeout, so a
    # lock waits rather than fails and a mid-batch failure leaves no partial prune behind. Names
    # are matched exactly as the export spelled them, and every value is escaped -- a hand-added
    # name may legally hold an apostrophe.
    $Statements = [System.Collections.Generic.List[System.String]]::new()
    $Statements.Add('PRAGMA busy_timeout = 5000;')
    $Statements.Add('BEGIN IMMEDIATE;')
    ForEach ($Stranger In $Extra) {
      $Statements.Add(("DELETE FROM CustomVariables WHERE Name = '{0}';" -f $Stranger.Replace("'", "''")))
    }
    $Statements.Add('COMMIT;')
    $Null = Invoke-NativeCommand -Operation:'Removing the undeclared variables' -FilePath:$Sqlite `
      -Argument:@($DatabasePath, ($Statements -join ' '))
    $Removed.AddRange([System.String[]]$Extra)
  }

  # Read again, always, because this is where the whole promise is either true or not, and a
  # promise about the product's state may only be made from the product's state NOW. This is what
  # catches a delete the database accepted and did not perform, and equally a declared variable
  # that vanished while this script was the only thing writing.
  $Remaining = Get-ExportedVariableName
  $Strangers = @($Remaining | Where-Object { -not $DeclaredSet.Contains($PSItem) })
  If ($Strangers.Count -gt 0) {
    Throw ('The product still holds the undeclared variable(s) {0}' -f ($Strangers -join ', '))
  }
  $RemainingSet = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]$Remaining, [System.StringComparer]::OrdinalIgnoreCase
  )
  $Missing = @($Name | Where-Object { -not $RemainingSet.Contains($PSItem) })
  If ($Missing.Count -gt 0) {
    Throw ('The product does not hold the declared variable(s) {0}' -f ($Missing -join ', '))
  }
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]($Extra.Count -gt 0)
  check_mode = [System.Boolean]$Ansible.CheckMode
  declared   = [System.Int32]$DeclaredSet.Count
  kept       = [System.String[]]$Kept
  msg        = If ($Extra.Count -eq 0) {
    'No undeclared variables; {0} kept' -f $Kept.Count
  } ElseIf ($Ansible.CheckMode) {
    'Would remove {0}' -f ($Extra -join ', ')
  } Else {
    'Removed {0}' -f ($Removed -join ', ')
  }
  removed    = [System.String[]]$(If ($Ansible.CheckMode) { $Extra } Else { $Removed })
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
