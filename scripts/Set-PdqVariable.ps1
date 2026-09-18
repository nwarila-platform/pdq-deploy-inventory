#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Applies a set of PDQ custom variables in one pass and proves each one took.

    .DESCRIPTION
        PDQ shares one custom-variable model across Deploy and Inventory, each reached through its
        OWN command line, so this script takes the product's CLI path and serves either. The
        command line creates or overwrites a variable by name (CreateCustomVariable -Force); the
        product's export is the verify oracle -- a variable that does not read back with the
        requested value fails the run.

        The map is the complete declaration. One export decides which variables differ and which
        held names are undeclared. Only those differences are written, every undeclared variable
        is removed, and a second export after mutation proves the complete state settled. A
        converged host therefore reads once, writes nothing and reports unchanged.

        The export is a FILE only, read whole and deleted at once; it carries no secrets.

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

    .PARAMETER Variable
        The complete desired custom-variable map. Names follow the product's own rule --
        non-empty, and free of @, $, ( and ) -- and values are strings. A name absent from the map
        is removed. A null value is unmanaged and therefore absent from the desired set.

    .PARAMETER CliPath
        Full path to the product's command line (PDQInventory.exe or PDQDeploy.exe). The same
        custom-variable model answers on both, so one script serves each product.

    .EXAMPLE
        .\Set-PdqVariable.ps1 -Variable @{ 'Google-LLC_Google-Chrome' = '147.0.7727.56' } -CliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'

    .OUTPUTS
        One object carrying applied, removed, unchanged, ignored, requested, changed, check_mode
        and msg.
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
  [System.Collections.IDictionary]
  $Variable
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. This script decides check mode from $Ansible.CheckMode, so -WhatIf is
# neutralised here; left on, it would suppress the New-Variable setup below and the cleanups.
$WhatIfPreference = $false

# Log level names, by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# Export staging: the product writes every custom variable here, this reads it whole and deletes it.
New-Variable -Force -Name:'EXPORT_PATH' -Option:'ReadOnly' -Value:(
  [System.String]'C:\Windows\Temp\pdq-variables-export.xml'
)

# The product's own name rule: non-empty and free of the reference punctuation (measured 2026-08-22,
# CreateCustomVariable rejects @, $, ( and ) with exit 2).
New-Variable -Force -Name:'NAME_PATTERN' -Option:('Private', 'ReadOnly') -Value:(
  [System.Text.RegularExpressions.Regex]::new('^[^@$()]+$')
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

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

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

# Validate and normalise the request in one pass: every name must satisfy the product's rule and
# every value must be a string, so a bad request fails before anything is read or written.
$Desired = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
ForEach ($Name In @($Variable.Keys)) {
  $Value = $Variable[$Name]
  If ($Null -eq $Value) {
    # Declared without a value is declared without being managed, which the Ansible side spells
    # as omit and a bare YAML key spells as null.
    Continue
  }
  $Text = [System.String]$Name
  If ([System.String]::IsNullOrEmpty($Text) -or -not $NAME_PATTERN.IsMatch($Text)) {
    Throw ('{0} is not a valid PDQ variable name (non-empty, and free of @, $, ( and ) )' -f $Text)
  }
  If ($Value -isnot [System.String]) {
    Throw ('{0} takes a String value, not a {1}' -f $Text, $Value.GetType().Name)
  }
  $Desired[$Text] = [System.String]$Value
}

# Read the whole variable store in one command-line launch. Exit 3 is a fresh, empty store. A
# success that writes no file is not empty -- it is a failed read, and a pruner must never confuse
# those two states.
Function Get-VariableMap {
  If (Test-Path -LiteralPath:$EXPORT_PATH) {
    Remove-Item -LiteralPath:$EXPORT_PATH -Force
  }
  $Export = Invoke-NativeCommand -Operation:'Exporting the custom variables' -FilePath:$CliPath `
    -SuccessExitCode:@(0, 3) -Argument:@('ExportVariables', '-Path', $EXPORT_PATH, '-Overwrite')
  $Current = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  If ($Export.Exit -eq 3) {
    Return , $Current
  }
  If (-not (Test-Path -LiteralPath:$EXPORT_PATH -PathType:'Leaf')) {
    Throw 'ExportVariables reported success and wrote no file'
  }
  Try {
    $Document = [System.Xml.XmlDocument]::new()
    $Document.LoadXml((Get-Content -LiteralPath:$EXPORT_PATH -Raw))
  } Catch {
    Throw ('Reading the exported variables at ''{0}'': {1}' -f @(
        $EXPORT_PATH, $PSItem.Exception.GetBaseException().Message
      ))
  } Finally {
    Remove-Item -LiteralPath:$EXPORT_PATH -Force -ErrorAction:'SilentlyContinue'
  }
  ForEach ($Node In @($Document.SelectNodes('//CustomVariable'))) {
    $NameNode = $Node.SelectSingleNode('Name')
    $ValueNode = $Node.SelectSingleNode('Value')
    If ($Null -eq $NameNode) {
      Continue
    }
    If ($Current.ContainsKey($NameNode.InnerText)) {
      Throw ('The product holds more than one variable named {0} (differing only by case); resolve that by hand first' -f $NameNode.InnerText)
    }
    $Current.Add(
      $NameNode.InnerText,
      $(If ($Null -ne $ValueNode) { $ValueNode.InnerText } Else { [System.String]::Empty })
    )
  }
  Return , $Current
}

$Initial = Get-VariableMap
$ToWrite = [System.Collections.Generic.List[System.String]]::new()
$Unchanged = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Name In $Desired.Keys) {
  If ($Initial.ContainsKey($Name) -and $Initial[$Name] -ceq $Desired[$Name]) {
    $Unchanged.Add($Name)
  } Else {
    $ToWrite.Add($Name)
  }
}
$Strangers = @($Initial.Keys | Where-Object { -not $Desired.ContainsKey($PSItem) })

# Prepare the existing, already-ratified prune before any write. The product has no delete verb,
# so this retains the former pruner's exact transaction: corroborate export names against the
# vendor table, then bind every delete to the row identity read here. No raw name enters SQL.
$Sqlite = $Null
$DatabasePath = $Null
$RowByName = $Null
If ($Strangers.Count -gt 0) {
  $Sqlite = Join-Path -Path (Split-Path -Path $CliPath -Parent) -ChildPath 'sqlite3.exe'
  If (-not (Test-Path -LiteralPath:$Sqlite -PathType:'Leaf')) {
    Throw ('The product database tool is not at ''{0}''' -f $Sqlite)
  }
  $Info = (Invoke-NativeCommand -Operation:'Reading the product system information' `
      -FilePath:$CliPath -Argument:@('SystemInfo')).Output
  $DatabasePath = (
    @($Info | Where-Object -FilterScript { $PSItem -match '^\s*Database\s*:' }) |
      Select-Object -First 1
  ) -replace '^\s*Database\s*:\s*', ''
  If (-not $DatabasePath) {
    Throw 'SystemInfo did not report a database path'
  }
  If (-not (Test-Path -LiteralPath:$DatabasePath -PathType:'Leaf')) {
    Throw ('The database is not at {0}' -f $DatabasePath)
  }

  $RowByName = [System.Collections.Generic.Dictionary[System.String, System.Object]]::new(
    [System.StringComparer]::Ordinal
  )
  ForEach ($Row In (Invoke-NativeCommand -Operation:'Reading the variable table' -FilePath:$Sqlite `
        -Argument:@($DatabasePath, 'SELECT CustomVariableId, hex(Name) FROM CustomVariables;')).Output) {
    $Parts = ([System.String]$Row).Split('|')
    If ($Parts.Count -ne 2 -or $Parts[0] -notmatch '^[0-9]+$' -or $Parts[1] -notmatch '^([0-9A-Fa-f]{2})*$') {
      Throw ('The variable table did not read back as id and hex name: {0}' -f $Row)
    }
    $Bytes = [System.Byte[]]::new($Parts[1].Length / 2)
    For ($B = 0; $B -lt $Bytes.Length; $B++) {
      $Bytes[$B] = [System.Convert]::ToByte($Parts[1].Substring($B * 2, 2), 16)
    }
    $RowByName.Add(
      [System.Text.Encoding]::UTF8.GetString($Bytes),
      [PSCustomObject]@{ Id = $Parts[0]; Hex = $Parts[1] }
    )
  }
  $InitialSet = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]$Initial.Keys, [System.StringComparer]::Ordinal
  )
  $NotInTable = @($Initial.Keys | Where-Object { -not $RowByName.ContainsKey($PSItem) })
  $NotInExport = @($RowByName.Keys | Where-Object { -not $InitialSet.Contains($PSItem) })
  If ($NotInTable.Count -gt 0 -or $NotInExport.Count -gt 0) {
    Throw ('The export and the variable table disagree (export only: {0}; table only: {1}); refusing to prune a product whose readings disagree' -f `
      ($NotInTable -join ', '), ($NotInExport -join ', '))
  }
}

$Applied = [System.Collections.Generic.List[System.String]]::new()
$Removed = [System.Collections.Generic.List[System.String]]::new()
$Ignored = [System.Collections.Generic.List[System.String]]::new()
$Survivors = [System.Collections.Generic.List[System.String]]::new()
$Changed = $ToWrite.Count -gt 0 -or $Strangers.Count -gt 0

If ($Ansible.CheckMode) {
  $Applied.AddRange($ToWrite)
  $Removed.AddRange([System.String[]]$Strangers)
} Else {
  Try {
    ForEach ($Name In $ToWrite) {
      $Null = Invoke-NativeCommand -Operation:('Writing the variable ''{0}''' -f $Name) `
        -FilePath:$CliPath `
        -Argument:@('CreateCustomVariable', '-Name', $Name, '-Value', $Desired[$Name], '-Force')
    }

    If ($Strangers.Count -gt 0) {
      $Statements = [System.Collections.Generic.List[System.String]]::new()
      $Statements.Add('PRAGMA busy_timeout = 5000;')
      $Statements.Add('BEGIN IMMEDIATE;')
      ForEach ($Stranger In $Strangers) {
        $Statements.Add(("DELETE FROM CustomVariables WHERE CustomVariableId = {0} AND hex(Name) = '{1}';" -f `
              $RowByName[$Stranger].Id, $RowByName[$Stranger].Hex))
      }
      $Statements.Add('COMMIT;')
      $Null = Invoke-NativeCommand -Operation:'Removing the undeclared variables' -FilePath:$Sqlite `
        -Argument:@($DatabasePath, ($Statements -join ' '))
    }

    $Final = If ($Changed) { Get-VariableMap } Else { $Initial }
    ForEach ($Name In $ToWrite) {
      If ($Final.ContainsKey($Name) -and $Final[$Name] -ceq $Desired[$Name]) {
        $Applied.Add($Name)
      } Else {
        $Ignored.Add($Name)
      }
    }
    ForEach ($Name In $Desired.Keys) {
      If (-not $Final.ContainsKey($Name) -or $Final[$Name] -cne $Desired[$Name]) {
        If (-not $Ignored.Contains($Name)) {
          $Ignored.Add($Name)
        }
      }
    }
    ForEach ($Name In $Strangers) {
      If ($Final.ContainsKey($Name)) {
        $Survivors.Add($Name)
      } Else {
        $Removed.Add($Name)
      }
    }
    ForEach ($Name In $Final.Keys) {
      If (-not $Desired.ContainsKey($Name) -and -not $Survivors.Contains($Name)) {
        $Survivors.Add($Name)
      }
    }
  } Finally {
    If (Test-Path -LiteralPath:$EXPORT_PATH) {
      Remove-Item -LiteralPath:$EXPORT_PATH -Force -ErrorAction:'SilentlyContinue'
    }
  }
}

$Result = [PSCustomObject]@{
  applied    = [System.String[]]$Applied
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  ignored    = [System.String[]]$Ignored
  msg        = If ($Ansible.CheckMode) {
    'Would apply: {0}; would remove: {1}' -f ($Applied -join ', '), ($Removed -join ', ')
  } ElseIf ($Ignored.Count -gt 0 -or $Survivors.Count -gt 0) {
    'The declared variable set did not settle (missing or different: {0}; undeclared still held: {1})' -f ($Ignored -join ', '), ($Survivors -join ', ')
  } ElseIf (-not $Changed) {
    'No variable changes; {0} already correct' -f $Unchanged.Count
  } Else {
    'Applied: {0}; removed: {1}; already correct: {2}' -f ($Applied -join ', '), ($Removed -join ', '), $Unchanged.Count
  }
  removed    = [System.String[]]$Removed
  requested  = [System.Int32]$Desired.Count
  survivors  = [System.String[]]$Survivors
  unchanged  = [System.String[]]$Unchanged
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

# The result is published either way, so a caller can see WHICH variables were ignored before the
# failure is raised.
If ($Result.ignored.Count -gt 0 -or $Result.survivors.Count -gt 0) {
  $Ansible.Failed = $True
}

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
  If ($Result.ignored.Count -gt 0 -or $Result.survivors.Count -gt 0) {
    Exit 2
  }
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
