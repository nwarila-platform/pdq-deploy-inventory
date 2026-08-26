#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Applies one PDQ Deploy package definition and proves it took.

    .DESCRIPTION
        The definition IS the declaration: the exported XML the caller hands over is the package
        the product is required to hold, and the package's own Name element says which one, so
        nothing names it twice.

        The product's export is both the comparison and the verify oracle. The package is imported
        only when the product does not hold it or holds it differently, so a converged host writes
        nothing and reports unchanged. After a write the package is exported again and must match,
        so a package the product accepted and did not store is reported and fails the run.

        Comparison ignores the byte-order mark, the line-ending style and trailing whitespace: an
        export is otherwise byte-for-byte what was imported (measured 2026-08-25 against PDQ Deploy
        20.1.8.0), so any remaining difference is a real difference in the package. Reading the
        definition through Ansible strips trailing whitespace on the way in, which is why the
        product's copy is trimmed to match rather than compared to the byte.

        This script adds and updates; it never deletes, so a package the product holds but no
        definition declares is left alone.

        Both files it touches are staging only, written and read whole inside the scratch directory
        the module hands over and removes; a package definition carries no secrets.

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
        The package definition, as the product's own export writes it. The caller reads one
        definition file and hands over its text; this script owns every file it needs from there.

    .PARAMETER CliPath
        Full path to PDQDeploy.exe. Packages are a Deploy concept; Inventory has no equivalent, so
        this script serves the one product.

    .EXAMPLE
        .\Set-PdqPackage.ps1 -Definition (Get-Content -Raw '.\Google Chrome - Install.xml') -CliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'

    .OUTPUTS
        One object carrying name, definition, changed, check_mode, ignored and msg.
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
  [ValidateNotNullOrEmpty()]
  [System.String] $Definition,

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

# The command line selects a package by PATTERN: -Name reads * and ? as wildcards and a comma as a
# separator (the product's own Help, 20.1.8.0), so a name carrying one of those cannot be addressed
# as itself.
New-Variable -Force -Name:'NAME_PATTERN' -Option:('Private', 'ReadOnly') -Value:(
  [System.Text.RegularExpressions.Regex]::new('^[^*?,]+$')
)

# Where a console FILED a package is a fact about that console, not about the package. A product
# that has never seen the folder tree stores an imported package at the root and exports it back
# saying so, so these three never survive a round trip: compared, they would report a change on
# every converge and then fail the verification that follows it. Measured on a fresh target
# 2026-08-25 -- FolderId 4 -> null, and Path 'Packages\Google LLC\...' -> the bare name.
#
# CustomVariables is different in kind but equally derived: the export EMBEDS a snapshot of every
# referenced custom variable's CURRENT value. The variable store is the source of truth for those
# values and is itself reconciled by this repository, so the snapshot is not part of the package's
# declaration and would otherwise dirty every package each time a pin moves.
# Not Private: the comparison function below is a child scope and has to read it.
New-Variable -Force -Name:'PLACEMENT_ELEMENTS' -Option:'ReadOnly' -Value:(
  [System.String[]]@(
    '/AdminArsenal.Export/Package/FolderId'
    '/AdminArsenal.Export/Package/Path'
    '/AdminArsenal.Export/Package/PackageDisplaySettings/SortOrder'
    '/AdminArsenal.Export/Package/CustomVariables'
  )
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
    Tmpdir    = [System.IO.Path]::GetTempPath()
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

# What the product varies between writes of the same package, plus the trailing whitespace Ansible
# has already stripped from the declaration on its way here.
Function ConvertTo-ComparableText {
  Param ([System.String] $Text)
  Return $Text.TrimStart([System.Char]0xFEFF).Replace("`r`n", "`n").TrimEnd()
}

# What gets COMPARED: the same document with the console's filing removed, so two products holding
# the same package in different folders agree. Both sides go through it, so encoding and formatting
# cannot differ either -- this compares the document, not the bytes that happened to carry it.
Function ConvertTo-ComparablePackage {
  Param ([System.String] $Text)
  If ([System.String]::IsNullOrWhiteSpace($Text)) {
    Return [System.String]::Empty
  }
  $Document = [System.Xml.XmlDocument]::new()
  Try {
    $Document.LoadXml((ConvertTo-ComparableText -Text:$Text))
  } Catch {
    Throw ('A package definition is not valid XML ({0})' -f $PSItem.Exception.GetBaseException().Message)
  }
  ForEach ($Element In $PLACEMENT_ELEMENTS) {
    ForEach ($Node In @($Document.SelectNodes($Element))) {
      $Null = $Node.ParentNode.RemoveChild($Node)
    }
  }
  Return $Document.OuterXml
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

# Reading the package is the same act whether deciding or proving: export it by name and hand back
# what the product holds. Exit 3 is the product's "no packages found matching the specified
# name(s)", which is an empty current state rather than a failure; every other non-zero exit is a
# failure to READ, and a read that failed must never be mistaken for a product holding nothing.
Function Get-PackageText {
  Param ([System.String] $Name)
  $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-package-export.xml'
  If (Test-Path -LiteralPath:$Staged) {
    Remove-Item -LiteralPath:$Staged -Force
  }

  $Export = Invoke-NativeCommand -FilePath:$CliPath -Operation:('Exporting the package ''{0}''' -f $Name) -SuccessExitCode:@(0, 3) -Argument:@(
    'ExportPackages', '-Name', $Name, '-Path', $Staged, '-Overwrite'
  )
  If ($Export.Exit -eq 3) {
    Return [System.String]::Empty
  }
  If (-not (Test-Path -LiteralPath:$Staged)) {
    Throw ('Exporting the package ''{0}'': the command line reported success but wrote no file' -f $Name)
  }

  Try {
    $Text = Get-Content -LiteralPath:$Staged -Raw
  } Catch {
    Throw ('Exporting the package ''{0}'': its export at ''{1}'' could not be read ({2})' -f @(
        $Name, $Staged, $PSItem.Exception.Message
      ))
  }
  Remove-Item -LiteralPath:$Staged -Force
  Return (ConvertTo-ComparableText -Text:$Text)
}

# Read the declaration first, so a malformed definition or an unaddressable name fails before
# anything is written.
$Declared = ConvertTo-ComparableText -Text:$Definition
$Document = [System.Xml.XmlDocument]::new()
Try {
  $Document.LoadXml($Declared)
} Catch {
  Throw ('The definition is not valid XML ({0})' -f $PSItem.Exception.GetBaseException().Message)
}
# Explicit SelectSingleNode, never the property adapter, because a child named 'Name' would
# otherwise collide with XmlNode's own Name property.
$NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Package/Name')
If ($Null -eq $NameNode -or [System.String]::IsNullOrWhiteSpace($NameNode.InnerText)) {
  Throw 'The definition does not name a package'
}
$Name = [System.String]$NameNode.InnerText
$DeclaredKey = ConvertTo-ComparablePackage -Text:$Declared
If (-not $NAME_PATTERN.IsMatch($Name)) {
  Throw ('{0} cannot be addressed by the command line, which reads *, ? and , as selection syntax' -f $Name)
}

$Changed = $False
$Ignored = $False

If ((ConvertTo-ComparablePackage -Text:(Get-PackageText -Name:$Name)) -cne $DeclaredKey) {
  If ($Ansible.CheckMode) {
    $Changed = $True
  } Else {
    # The command line imports a FILE, so the declaration becomes one. -Overwrite makes one path
    # serve both a package the product does not hold and one it holds differently; a package that
    # already matches never reaches here, so it never rewrites a match.
    $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-package-import.xml'
    Try {
      Set-Content -LiteralPath:$Staged -Value:$Declared -Encoding:'utf8' -NoNewline
    } Catch {
      Throw ('Importing the package ''{0}'': it could not be staged at ''{1}'' ({2})' -f @(
          $Name, $Staged, $PSItem.Exception.Message
        ))
    }
    $Null = Invoke-NativeCommand -FilePath:$CliPath -Operation:('Importing the package ''{0}''' -f $Name) -Argument:@(
      'ImportPackages', '-Path', $Staged, '-Overwrite'
    )
    Remove-Item -LiteralPath:$Staged -Force

    # The product was told to write, so the host changed whatever the next read says. Reporting the
    # change is not a claim that it is correct -- that is the read below, taken from the product
    # rather than from the import's own report, because a package the product accepted and did not
    # store would otherwise pass as applied.
    $Changed = $True
    $Ignored = (ConvertTo-ComparablePackage -Text:(Get-PackageText -Name:$Name)) -cne $DeclaredKey
  }
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  # The declaration itself, so the caller can hand the complete set to the pruning step: deciding
  # what is safe to delete needs the definitions, not just their names.
  definition = [System.String]$Declared
  ignored    = [System.Boolean]$Ignored
  msg        = If ($Ignored) {
    '{0} does not read back as declared after import' -f $Name
  } ElseIf (-not $Changed) {
    '{0} is already correct' -f $Name
  } ElseIf ($Ansible.CheckMode) {
    '{0} would be applied' -f $Name
  } Else {
    '{0} applied' -f $Name
  }
  name       = $Name
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

# The result is published either way, so a caller can see which package failed to read back, and
# that the host was written to, before the failure is raised.
If ($Result.ignored) {
  $Ansible.Failed = $True
}

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
  If ($Result.ignored) {
    Exit 2
  }
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
