#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Removes every PDQ Deploy package the declaration does not name.

    .DESCRIPTION
        The declaration is COMPLETE. The names in -Declared are the packages the product is
        required to hold, and anything else it holds is drift. Removing it is not an option the
        caller turns on: a role that states an end state and then leaves strangers standing has
        not stated the end state.

        That cuts both ways. Declaring nothing declares that the product holds nothing, and this
        script will empty it -- which is the same promise read in the other direction, not a
        special case.

        The product's own list is both the input and the verify oracle: what it holds is read,
        what it should not hold is removed, and the list is read again, so a delete the command
        line accepted and did not perform fails the run.

        A package that a DECLARED definition refers to by name is never removed, even when no
        definition declares it. The command line's own nested-step check cannot be used -- deleting
        without -Force waits for a confirmation a non-interactive run cannot answer (measured on
        the target 2026-08-25) -- so the check is made here instead, against the declarations, and
        it fails the run rather than quietly breaking the package that refers to it.

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

    .PARAMETER Definition
        The COMPLETE set of package definitions, as exported. Their Name elements are the packages
        the product must hold, and no others. Required, and required even when empty, so emptying
        the product is something a caller states rather than something it forgets to pass.

        The definitions rather than their names, because deciding what is safe to delete needs to
        see what the declared packages reference.

    .PARAMETER CliPath
        Full path to PDQDeploy.exe. Packages are a Deploy concept; Inventory has no equivalent, so
        this script serves the one product.

    .EXAMPLE
        .\Remove-PdqPackage.ps1 -Definition (Get-Content -Raw '.\Google Chrome - Install.xml') -CliPath $DeployCliPath

    .OUTPUTS
        One object carrying removed, kept, declared, changed, check_mode and msg.
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
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [AllowEmptyCollection()]
  [System.String[]]
  $Definition,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223'
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

# The command line selects a package by PATTERN: -Name reads * and ? as wildcards and a comma as a
# separator (the product's own Help, 20.1.8.0). A name carrying one of those cannot be addressed as
# itself, and guessing at a DELETE is not a thing this script will do.
New-Variable -Force -Name:'NAME_PATTERN' -Option:('Private', 'ReadOnly') -Value:(
  [System.Text.RegularExpressions.Regex]::new('^[^*?,]+$')
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
  Throw ('The PDQ Deploy command line is not at ''{0}''' -f $CliPath)
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

# What the product holds, read the only way it offers: one bare name per line. Only the line ending
# is stripped, never the name's own leading or trailing spaces -- trimming those would address a
# different package than the one the product named.
Function Get-HeldPackageName {
  $Listing = Invoke-NativeCommand -FilePath:$CliPath -Operation:'Listing the packages' -Argument:@('GetPackageNames')
  $Names = [System.Collections.Generic.List[System.String]]::new()
  ForEach ($Line In $Listing.Output) {
    $Text = ([System.String]$Line).TrimEnd([System.Char]13, [System.Char]10)
    If ($Text.Length -gt 0) {
      $Names.Add($Text)
    }
  }
  # Returned with a leading comma so an EMPTY list stays a list: PowerShell unrolls a bare empty
  # array out of a function as $Null, and a null list would read as "the product holds nothing" --
  # the one mistake a pruner must not make.
  Return , $Names.ToArray()
}

# The declaration, read once: each definition's own Name element is what it declares, and every
# other element value is something it refers to.
$DeclaredSet = [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::Ordinal)
$ReferencedSet = [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::Ordinal)

ForEach ($Text In $Definition) {
  $Document = [System.Xml.XmlDocument]::new()
  Try {
    $Document.LoadXml($Text.TrimStart([System.Char]0xFEFF))
  } Catch {
    Throw ('A definition is not valid XML ({0})' -f $PSItem.Exception.GetBaseException().Message)
  }
  $NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Package/Name')
  If ($Null -eq $NameNode -or [System.String]::IsNullOrWhiteSpace($NameNode.InnerText)) {
    Throw 'A definition does not name a package'
  }
  $Null = $DeclaredSet.Add($NameNode.InnerText)

  # Every leaf element value, because a nested step names the package it runs by name and this
  # script must not know the product's schema to see it. Whole values only, so a description that
  # merely mentions a word does not pin an unrelated package in place.
  ForEach ($Node In $Document.SelectNodes('//*')) {
    If ($Node.ChildNodes.Count -eq 1 -and $Node.FirstChild.NodeType -eq [System.Xml.XmlNodeType]::Text) {
      $Null = $ReferencedSet.Add($Node.InnerText)
    }
  }
}

# Matched case-SENSITIVELY, to agree with the import step, which requires a package to export back
# byte-for-byte as declared. A package stored under a different case fails there and the run never
# reaches this script, so an exact match here cannot delete something the import just wrote.
$Held = Get-HeldPackageName
$Extra = @($Held | Where-Object { -not $DeclaredSet.Contains($PSItem) })
$Kept = @($Held | Where-Object { $DeclaredSet.Contains($PSItem) })

# Every name is judged before any name is deleted, so a package that cannot be addressed, or one a
# declared package needs, stops the run with the product untouched rather than half-pruned.
ForEach ($Name In $Extra) {
  If (-not $NAME_PATTERN.IsMatch($Name)) {
    Throw ('{0} cannot be addressed by the command line, which reads *, ? and , as selection syntax' -f $Name)
  }
  If ($ReferencedSet.Contains($Name)) {
    Throw ('{0} is not declared, but a declared package refers to it; declare it or stop referring to it' -f $Name)
  }
}

$Removed = [System.Collections.Generic.List[System.String]]::new()

If (-not $Ansible.CheckMode) {
  ForEach ($Name In $Extra) {
    # -Force because the command line otherwise waits for a confirmation this run cannot answer.
    # It also waives the product's own nested-step check, which is why the declarations were
    # checked for references above.
    $Null = Invoke-NativeCommand -FilePath:$CliPath -Operation:('Removing the package ''{0}''' -f $Name) -Argument:@(
      'DeletePackages', '-Name', $Name, '-Force'
    )
    $Removed.Add($Name)
  }

  # Read again, always, because this is where the whole promise is either true or not and a promise
  # about the product's state may only be made from the product's state NOW. Reusing the earlier
  # listing would claim an exact final state from a reading taken before the deletes.
  $Remaining = Get-HeldPackageName
  $Strangers = @($Remaining | Where-Object { -not $DeclaredSet.Contains($PSItem) })
  If ($Strangers.Count -gt 0) {
    Throw ('The product still holds {0} after removing it' -f ($Strangers -join ', '))
  }
  $RemainingSet = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]$Remaining, [System.StringComparer]::Ordinal
  )
  $Missing = @($DeclaredSet | Where-Object { -not $RemainingSet.Contains($PSItem) })
  If ($Missing.Count -gt 0) {
    Throw ('The product does not hold the declared package(s) {0}' -f ($Missing -join ', '))
  }
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]($Extra.Count -gt 0)
  check_mode = [System.Boolean]$Ansible.CheckMode
  declared   = [System.Int32]$DeclaredSet.Count
  kept       = [System.String[]]$Kept
  msg        = If ($Extra.Count -eq 0) {
    'No undeclared packages; {0} kept' -f $Kept.Count
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
