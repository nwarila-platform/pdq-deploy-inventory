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

        Two passes over one reading: decide which variables differ, write only those, then prove
        every requested variable reads back. Idempotent -- a variable already at its value is left
        untouched and reported unchanged. This script adds and updates; it never deletes, so a
        name the product holds but the caller omits is left alone.

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
        The desired custom variables as a map of name to value. Names follow the product's own
        rule -- non-empty, and free of @, $, ( and ) -- and values are strings. A name absent
        from the map is left as the product holds it; this script adds and updates, never deletes.

    .PARAMETER CliPath
        Full path to the product's command line (PDQInventory.exe or PDQDeploy.exe). The same
        custom-variable model answers on both, so one script serves each product.

    .EXAMPLE
        .\Set-PdqVariable.ps1 -Variable @{ 'GoogleLlc_GoogleChrome' = '129.0.6668.90' } -CliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'

    .OUTPUTS
        One object carrying applied, unchanged, ignored, requested, changed, check_mode and msg.
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
  [System.Collections.IDictionary] $Variable,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String] $CliPath
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
New-Variable -Force -Name:'EXPORT_PATH' -Option:('Private', 'ReadOnly') -Value:(
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
# Three things have to happen at once for that to work, all measured on the target 2026-08-25 under
# win_powershell with error_action stop:
#
#   1. ErrorActionPreference is lowered across the call. A native command's stderr is a TERMINATING
#      error while it is Stop -- redirected or not -- and the product writes to stderr on ORDINARY
#      paths: "not found" with exit 3 is how it says a thing is absent. The bare call raises before
#      any exit code can be read.
#   2. stderr is merged into the capture. Left on its own stream it becomes an error record, and the
#      module fails the task on any error record even when nothing threw.
#   3. those records are separated back out. They are the program's commentary, not its output, and
#      a caller reading the output would otherwise take a warning for data.
#
# What the program said on stderr is kept, so a failure can quote it rather than leaving the reader
# to guess why an exit code was what it was.
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
    Throw ('{0}: ''{1}'' could not be run ({2})' -f $Operation, $FilePath, $PSItem.Exception.Message)
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
$Desired = @{}
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

# Working state: the verdict lists.
$Applied = [System.Collections.Generic.List[System.String]]::new()
$Unchanged = [System.Collections.Generic.List[System.String]]::new()
$Ignored = [System.Collections.Generic.List[System.String]]::new()

Try {
  # Two passes over the same reading code: decide, then prove.
  For ($Pass = 0; $Pass -lt 2; $Pass++) {
    If (Test-Path -LiteralPath:$EXPORT_PATH) {
      Remove-Item -LiteralPath:$EXPORT_PATH -Force
    }
    # Export ALL custom variables. Exit 3 means the product holds none yet -- a first run against a
    # fresh install -- which is an empty current state, not a failure.
    $Null = Invoke-NativeCommand -Operation:'Exporting the custom variables' -FilePath:$CliPath `
      -SuccessExitCode:@(0, 3) -Argument:@('ExportVariables', '-Path', $EXPORT_PATH, '-Overwrite')

    # Parse <CustomVariable><Name/><Value/></CustomVariable> into a name -> value map. Explicit
    # SelectSingleNode, never the property adapter, because a child named 'Name' would otherwise
    # collide with XmlNode's own Name property.
    $Current = @{}
    If (Test-Path -LiteralPath:$EXPORT_PATH) {
      $Document = [System.Xml.XmlDocument]::new()
      Try {
        $Document.LoadXml((Get-Content -LiteralPath:$EXPORT_PATH -Raw))
      } Catch {
        Throw ('Reading the exported variables at ''{0}'': {1}' -f @(
            $EXPORT_PATH, $PSItem.Exception.GetBaseException().Message
          ))
      }
      Remove-Item -LiteralPath:$EXPORT_PATH -Force
      ForEach ($Node In @($Document.SelectNodes('//CustomVariable'))) {
        $NameNode = $Node.SelectSingleNode('Name')
        $ValueNode = $Node.SelectSingleNode('Value')
        If ($Null -ne $NameNode) {
          $Current[$NameNode.InnerText] = If ($Null -ne $ValueNode) { $ValueNode.InnerText } Else { [System.String]::Empty }
        }
      }
    }

    If ($Pass -eq 0) {
      # Decide first: a variable already at its value is unchanged; everything else queues.
      $ToWrite = [System.Collections.Generic.List[System.String]]::new()
      ForEach ($Name In @($Desired.Keys)) {
        If ($Current.ContainsKey($Name) -and [System.String]$Current[$Name] -ceq [System.String]$Desired[$Name]) {
          $Unchanged.Add($Name)
        } Else {
          $ToWrite.Add($Name)
        }
      }
      If ($Ansible.CheckMode) {
        $Applied.AddRange($ToWrite)
        Break
      }
      # Create-or-overwrite by name. -Force makes one path serve both a new name and a changed
      # value; only differing names reach here, so it never rewrites an unchanged variable.
      ForEach ($Name In $ToWrite) {
        $Null = Invoke-NativeCommand -Operation:('Writing the variable ''{0}''' -f $Name) `
          -FilePath:$CliPath `
          -Argument:@('CreateCustomVariable', '-Name', $Name, '-Value', $Desired[$Name], '-Force')
      }
    } Else {
      # Prove it: anything that does not read back with the requested value was not applied -- the
      # failure this script exists to surface.
      ForEach ($Name In @($Desired.Keys)) {
        If ($Unchanged -contains $Name) {
          Continue
        }
        If ($Current.ContainsKey($Name) -and [System.String]$Current[$Name] -ceq [System.String]$Desired[$Name]) {
          $Applied.Add($Name)
        } Else {
          $Ignored.Add($Name)
        }
      }
    }
  }
} Finally {
  If (Test-Path -LiteralPath:$EXPORT_PATH) {
    Remove-Item -LiteralPath:$EXPORT_PATH -Force -ErrorAction:'SilentlyContinue'
  }
}

$Result = [PSCustomObject]@{
  applied    = [System.String[]]$Applied
  changed    = [System.Boolean]($Applied.Count -gt 0)
  check_mode = [System.Boolean]$Ansible.CheckMode
  ignored    = [System.String[]]$Ignored
  msg        = If ($Ansible.CheckMode) {
    '{0} would be applied, {1} already correct' -f $Applied.Count, $Unchanged.Count
  } ElseIf ($Ignored.Count -gt 0) {
    'The product accepted but did not apply: {0}' -f ($Ignored -join ', ')
  } Else {
    '{0} applied, {1} already correct' -f $Applied.Count, $Unchanged.Count
  }
  requested  = [System.Int32]$Desired.Count
  unchanged  = [System.String[]]$Unchanged
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

# The result is published either way, so a caller can see WHICH variables were ignored before the
# failure is raised.
If ($Result.ignored.Count -gt 0) {
  $Ansible.Failed = $True
}

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
  If ($Result.ignored.Count -gt 0) {
    Exit 2
  }
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
