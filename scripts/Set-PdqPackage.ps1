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
        One object carrying name, changed, check_mode, ignored and msg.
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

# What the product varies between writes of the same package, plus the trailing whitespace Ansible
# has already stripped from the declaration on its way here.
Function ConvertTo-ComparableText {
  Param ([System.String] $Text)
  Return $Text.TrimStart([System.Char]0xFEFF).Replace("`r`n", "`n").TrimEnd()
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
  $Null = & $CliPath 'ExportPackages' '-Name' $Name '-Path' $Staged '-Overwrite' 2>&1
  $ExportExit = $LASTEXITCODE
  If ($ExportExit -eq 3) {
    Return [System.String]::Empty
  }
  If ($ExportExit -ne 0) {
    Throw ('ExportPackages failed for {0} with exit code {1}' -f $Name, $ExportExit)
  }
  If (-not (Test-Path -LiteralPath:$Staged)) {
    Throw ('ExportPackages reported success for {0} but wrote no file' -f $Name)
  }
  $Text = Get-Content -LiteralPath:$Staged -Raw
  Remove-Item -LiteralPath:$Staged -Force
  Return (ConvertTo-ComparableText -Text:$Text)
}

# Read the declaration first, so a malformed definition or an unaddressable name fails before
# anything is written.
$Declared = ConvertTo-ComparableText -Text:$Definition
$Document = [System.Xml.XmlDocument]::new()
$Document.LoadXml($Declared)
# Explicit SelectSingleNode, never the property adapter, because a child named 'Name' would
# otherwise collide with XmlNode's own Name property.
$NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Package/Name')
If ($Null -eq $NameNode -or [System.String]::IsNullOrWhiteSpace($NameNode.InnerText)) {
  Throw 'The definition does not name a package'
}
$Name = [System.String]$NameNode.InnerText
If (-not $NAME_PATTERN.IsMatch($Name)) {
  Throw ('{0} cannot be addressed by the command line, which reads *, ? and , as selection syntax' -f $Name)
}

$Changed = $False
$Ignored = $False

If ((Get-PackageText -Name:$Name) -cne $Declared) {
  If ($Ansible.CheckMode) {
    $Changed = $True
  } Else {
    # The command line imports a FILE, so the declaration becomes one. -Overwrite makes one path
    # serve both a package the product does not hold and one it holds differently; a package that
    # already matches never reaches here, so it never rewrites a match.
    $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-package-import.xml'
    Set-Content -LiteralPath:$Staged -Value:$Declared -Encoding:'utf8' -NoNewline
    $Null = & $CliPath 'ImportPackages' '-Path' $Staged '-Overwrite' 2>&1
    If ($LASTEXITCODE -ne 0) {
      Throw ('ImportPackages failed for {0} with exit code {1}' -f $Name, $LASTEXITCODE)
    }
    Remove-Item -LiteralPath:$Staged -Force

    # The product was told to write, so the host changed whatever the next read says. Reporting the
    # change is not a claim that it is correct -- that is the read below, taken from the product
    # rather than from the import's own report, because a package the product accepted and did not
    # store would otherwise pass as applied.
    $Changed = $True
    $Ignored = (Get-PackageText -Name:$Name) -cne $Declared
  }
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
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
