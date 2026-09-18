#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Makes the complete set of PDQ Deploy package definitions authoritative.

    .DESCRIPTION
        The definitions ARE the declaration: each exported XML document names one package the
        product is required to hold. Anything else is removed.

        The product's export is both the comparison and the verify oracle. Every declared name is
        read in one ExportPackages launch, passing each name as a separate argument and a staging
        directory for the resulting files. Only definitions that differ are imported, every
        undeclared package is removed, and the complete set is read back after mutation. A
        converged host pays for one batched export and writes nothing.

        Comparison ignores the byte-order mark, the line-ending style and trailing whitespace: an
        export is otherwise byte-for-byte what was imported (measured 2026-08-25 against PDQ Deploy
        20.1.8.0), so any remaining difference is a real difference in the package. Reading the
        definition through Ansible strips trailing whitespace on the way in, which is why the
        product's copy is trimmed to match rather than compared to the byte.

        ExportPackages exit 1 is a successful partial read only when every missing requested name
        has its matching not-found error and every other request wrote a valid package file. Exit
        3 is the successful empty answer when none of the requested packages exists. Presence is
        decided from each file's own Name element; filenames are presentation only.

        A package that a declared definition refers to by name cannot be pruned accidentally. The
        command line's forced delete bypasses its own nested-step prompt, so an undeclared but
        referenced package stops the run before any mutation.

        Staging files are written and read whole inside the scratch directory the module hands over
        and removes; a package definition carries no secrets.

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
        The complete set of package definitions, as the product's own export writes them. Required
        even when empty, so owning no packages is an explicit declaration.

    .PARAMETER CliPath
        Full path to PDQDeploy.exe. Packages are a Deploy concept; Inventory has no equivalent, so
        this script serves the one product.

    .EXAMPLE
        .\Set-PdqPackage.ps1 -Definition @((Get-Content -Raw '.\Google Chrome - Install.xml')) -CliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'

    .OUTPUTS
        One object carrying applied, removed, unchanged, ignored, survivors, changed, check_mode
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

# The ordinary path for native commands, so every failure names the operation that failed instead
# of surfacing the program's bare text, and every exit code is judged against a policy the caller
# states rather than a convention the reader has to infer. ExportPackages has a separate reader
# below because its stderr lines are part of the partial-success contract and must remain distinct.
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

# ExportPackages is unusual: exit 1 can be a complete, trustworthy read when every failure is the
# ordinary not-found answer for a requested package. The shared helper deliberately turns stderr
# into one warning, so this reader preserves its lines for the caller to account for individually.
Function Invoke-PackageExport {
  Param ([System.String[]] $Argument)
  $Previous = $ErrorActionPreference
  Try {
    $ErrorActionPreference = 'Continue'
    $Captured = & $CliPath @Argument 2>&1
    $Exit = $LASTEXITCODE
  } Catch {
    Throw [System.Management.Automation.RuntimeException]::new(
      ('Exporting the declared packages: ''{0}'' could not be run ({1})' -f `
        $CliPath, $PSItem.Exception.Message),
      $PSItem.Exception
    )
  } Finally {
    $ErrorActionPreference = $Previous
  }

  $Said = [System.Collections.Generic.List[System.String]]::new()
  ForEach ($Line In $Captured) {
    If ($Line -is [System.Management.Automation.ErrorRecord]) {
      $Said.Add(([System.String]$Line).Trim())
    }
  }
  Return [PSCustomObject]@{
    Error = $Said.ToArray()
    Exit  = [System.Int32]$Exit
  }
}

# Read every declared name in one launch. Separate name arguments and a directory are required for
# a batch. Each file's Name element decides which request it answers; filenames decide nothing.
Function Get-PackageMap {
  Param ([System.String[]] $Name)
  $Current = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
    [System.StringComparer]::Ordinal
  )
  If ($Name.Count -eq 0) {
    Return , $Current
  }

  $Requested = [System.Collections.Generic.HashSet[System.String]]::new(
    $Name, [System.StringComparer]::Ordinal
  )
  $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-package-export'
  If (Test-Path -LiteralPath:$Staged) {
    Remove-Item -LiteralPath:$Staged -Recurse -Force
  }
  $Null = New-Item -ItemType:'Directory' -Path:$Staged
  Try {
    [System.String[]]$Argument = @('ExportPackages', '-Name') + $Name + @(
      '-Path', $Staged, '-Overwrite'
    )
    $Export = Invoke-PackageExport -Argument:$Argument
    Switch ($Export.Exit) {
      2 { Throw 'ExportPackages was cancelled' }
      4 { Throw 'ExportPackages skipped one or more requested packages because an export file already existed' }
    }
    If (@(0, 1, 3) -notcontains $Export.Exit) {
      Throw ('ExportPackages exited {0}{1}' -f @(
          $Export.Exit
          $(If ($Export.Error.Count -gt 0) { ' -- ' + ($Export.Error -join '; ') } Else { '' })
        ))
    }

    ForEach ($File In @(Get-ChildItem -LiteralPath:$Staged -File)) {
      Try {
        $Text = ConvertTo-ComparableText -Text:(Get-Content -LiteralPath:$File.FullName -Raw)
        $Document = [System.Xml.XmlDocument]::new()
        $Document.LoadXml($Text)
      } Catch {
        Throw ('Reading the package export at ''{0}'': {1}' -f @(
            $File.FullName, $PSItem.Exception.GetBaseException().Message
          ))
      }
      If (@($Document.SelectNodes('/AdminArsenal.Export/Package')).Count -ne 1) {
        Throw ('The package export at ''{0}'' does not carry exactly one package' -f $File.FullName)
      }
      $NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Package/Name')
      If ($Null -eq $NameNode -or -not $Requested.Contains($NameNode.InnerText)) {
        Throw ('The package export at ''{0}'' does not answer a requested name' -f $File.FullName)
      }
      If ($Current.ContainsKey($NameNode.InnerText)) {
        Throw ('ExportPackages wrote more than one definition for {0}' -f $NameNode.InnerText)
      }
      $Current.Add($NameNode.InnerText, $Text)
    }

    $Missing = [System.String[]]@($Name | Where-Object { -not $Current.ContainsKey($PSItem) })
    $ExpectedError = [System.Collections.Generic.HashSet[System.String]]::new(
      [System.StringComparer]::Ordinal
    )
    ForEach ($MissingName In $Missing) {
      $Null = $ExpectedError.Add(('Error: Package "{0}" not found.' -f $MissingName))
    }
    $Accounted = [System.Collections.Generic.HashSet[System.String]]::new(
      [System.StringComparer]::Ordinal
    )
    $UnexpectedError = [System.Collections.Generic.List[System.String]]::new()
    ForEach ($ErrorLine In $Export.Error) {
      If (-not $ExpectedError.Contains($ErrorLine) -or -not $Accounted.Add($ErrorLine)) {
        $UnexpectedError.Add($ErrorLine)
      }
    }
    $Unreported = [System.String[]]@($ExpectedError | Where-Object {
        -not $Accounted.Contains($PSItem)
      })

    Switch ($Export.Exit) {
      0 {
        If ($Missing.Count -gt 0 -or $Export.Error.Count -gt 0) {
          Throw ('ExportPackages reported success for {0} requested package(s) but wrote {1} export file(s){2}' -f @(
              $Requested.Count
              $Current.Count
              $(If ($Export.Error.Count -gt 0) { ' -- ' + ($Export.Error -join '; ') } Else { '' })
            ))
        }
      }
      1 {
        If ($Missing.Count -eq 0 -or $Unreported.Count -gt 0 -or $UnexpectedError.Count -gt 0) {
          Throw ('ExportPackages exited 1 without an exact not-found error for every missing package{0}' -f `
            $(If ($Export.Error.Count -gt 0) { ' -- ' + ($Export.Error -join '; ') } Else { '' }))
        }
      }
      3 {
        If ($Current.Count -gt 0 -or $UnexpectedError.Count -gt 0) {
          Throw ('ExportPackages exited 3 but did not report an empty package set{0}' -f `
            $(If ($Export.Error.Count -gt 0) { ' -- ' + ($Export.Error -join '; ') } Else { '' }))
        }
      }
    }
  } Finally {
    Remove-Item -LiteralPath:$Staged -Recurse -Force -ErrorAction:'SilentlyContinue'
  }
  Return , $Current
}

# What the product holds, read the only way it offers: one bare name per line. Only line endings
# are stripped; trimming the name itself could cause a later delete to address a different package.
Function Get-HeldPackageName {
  $Listing = Invoke-NativeCommand -FilePath:$CliPath -Operation:'Listing the packages' `
    -Argument:@('GetPackageNames')
  $Names = [System.Collections.Generic.List[System.String]]::new()
  ForEach ($Line In $Listing.Output) {
    $Text = ([System.String]$Line).TrimEnd([System.Char]13, [System.Char]10)
    If ($Text.Length -gt 0) {
      $Names.Add($Text)
    }
  }
  Return , $Names.ToArray()
}

# Parse the whole declaration before any product read. Names are exact and unique, every package
# is addressable, and every leaf value is retained for the nested-package deletion safeguard.
$Declared = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
  [System.StringComparer]::Ordinal
)
$DeclaredKey = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
  [System.StringComparer]::Ordinal
)
$DeclaredName = [System.Collections.Generic.List[System.String]]::new()
$Referenced = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.StringComparer]::Ordinal
)
ForEach ($Text In $Definition) {
  $Normal = ConvertTo-ComparableText -Text:$Text
  $Document = [System.Xml.XmlDocument]::new()
  Try {
    $Document.LoadXml($Normal)
  } Catch {
    Throw ('A definition is not valid XML ({0})' -f $PSItem.Exception.GetBaseException().Message)
  }
  If (@($Document.SelectNodes('/AdminArsenal.Export/Package')).Count -ne 1) {
    Throw 'A definition must carry exactly one package'
  }
  $NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Package/Name')
  If ($Null -eq $NameNode -or [System.String]::IsNullOrWhiteSpace($NameNode.InnerText)) {
    Throw 'A definition does not name a package'
  }
  $Name = [System.String]$NameNode.InnerText
  If (-not $NAME_PATTERN.IsMatch($Name)) {
    Throw ('{0} cannot be addressed by the command line, which reads *, ? and , as selection syntax' -f $Name)
  }
  If ($Declared.ContainsKey($Name)) {
    Throw ('{0} is declared more than once; two definitions cannot own one name' -f $Name)
  }
  $Declared.Add($Name, $Normal)
  $DeclaredKey.Add($Name, (ConvertTo-ComparablePackage -Text:$Normal))
  $DeclaredName.Add($Name)
  ForEach ($Node In $Document.SelectNodes('//*')) {
    If ($Node.ChildNodes.Count -eq 1 -and
      $Node.FirstChild.NodeType -eq [System.Xml.XmlNodeType]::Text) {
      $Null = $Referenced.Add($Node.InnerText)
    }
  }
}

$Held = Get-HeldPackageName
$DeclaredSet = [System.Collections.Generic.HashSet[System.String]]::new(
  $DeclaredName, [System.StringComparer]::Ordinal
)
$Extra = [System.String[]]@($Held | Where-Object { -not $DeclaredSet.Contains($PSItem) })

# Judge every delete before any import or delete. Forced deletion bypasses the product's own
# nested-package prompt, so the declaration has to prove that no survivor refers to the target.
ForEach ($Name In $Extra) {
  If (-not $NAME_PATTERN.IsMatch($Name)) {
    Throw ('{0} cannot be addressed by the command line, which reads *, ? and , as selection syntax' -f $Name)
  }
  If ($Referenced.Contains($Name)) {
    Throw ('{0} is not declared, but a declared package refers to it; declare it or stop referring to it' -f $Name)
  }
}

$Initial = Get-PackageMap -Name:$DeclaredName.ToArray()
$ToImport = [System.Collections.Generic.List[System.String]]::new()
$InitiallyUnchanged = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Name In $DeclaredName) {
  If ($Initial.ContainsKey($Name) -and
    (ConvertTo-ComparablePackage -Text:$Initial[$Name]) -ceq $DeclaredKey[$Name]) {
    $InitiallyUnchanged.Add($Name)
  } Else {
    $ToImport.Add($Name)
  }
}

$Applied = [System.Collections.Generic.List[System.String]]::new()
$Removed = [System.Collections.Generic.List[System.String]]::new()
$Unchanged = [System.Collections.Generic.List[System.String]]::new()
$Ignored = [System.Collections.Generic.List[System.String]]::new()
$Survivors = [System.Collections.Generic.List[System.String]]::new()
$Changed = $ToImport.Count -gt 0 -or $Extra.Count -gt 0

If ($Ansible.CheckMode) {
  $Applied.AddRange($ToImport.ToArray())
  $Removed.AddRange($Extra)
  $Unchanged.AddRange($InitiallyUnchanged.ToArray())
} Else {
  ForEach ($Name In $ToImport) {
    $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-package-import.xml'
    Try {
      Try {
        Set-Content -LiteralPath:$Staged -Value:$Declared[$Name] -Encoding:'utf8' -NoNewline
      } Catch {
        Throw ('Importing the package ''{0}'': it could not be staged at ''{1}'' ({2})' -f @(
            $Name, $Staged, $PSItem.Exception.Message
          ))
      }
      $Null = Invoke-NativeCommand -FilePath:$CliPath `
        -Operation:('Importing the package ''{0}''' -f $Name) `
        -Argument:@('ImportPackages', '-Path', $Staged, '-Overwrite')
    } Finally {
      Remove-Item -LiteralPath:$Staged -Force -ErrorAction:'SilentlyContinue'
    }
  }

  ForEach ($Name In $Extra) {
    $Null = Invoke-NativeCommand -FilePath:$CliPath `
      -Operation:('Removing the package ''{0}''' -f $Name) `
      -Argument:@('DeletePackages', '-Name', $Name, '-Force')
  }

  $Final = If ($Changed) {
    Get-PackageMap -Name:$DeclaredName.ToArray()
  } Else {
    $Initial
  }
  $Remaining = If ($Changed) { Get-HeldPackageName } Else { $Held }
  $RemainingSet = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]$Remaining, [System.StringComparer]::Ordinal
  )

  ForEach ($Name In $DeclaredName) {
    If ($RemainingSet.Contains($Name) -and $Final.ContainsKey($Name) -and
      (ConvertTo-ComparablePackage -Text:$Final[$Name]) -ceq $DeclaredKey[$Name]) {
      If ($ToImport.Contains($Name)) {
        $Applied.Add($Name)
      } Else {
        $Unchanged.Add($Name)
      }
    } Else {
      $Ignored.Add($Name)
    }
  }
  ForEach ($Name In $Extra) {
    If (-not $RemainingSet.Contains($Name)) {
      $Removed.Add($Name)
    }
  }
  ForEach ($Name In $Remaining) {
    If (-not $DeclaredSet.Contains($Name)) {
      $Survivors.Add($Name)
    }
  }
}

$Result = [PSCustomObject]@{
  applied    = [System.String[]]$Applied
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  declared   = [System.Int32]$Declared.Count
  ignored    = [System.String[]]$Ignored
  msg        = If ($Ansible.CheckMode) {
    'Would apply: {0}; would remove: {1}; already correct: {2}' -f @(
      ($Applied -join ', '), ($Removed -join ', '), $Unchanged.Count
    )
  } ElseIf ($Ignored.Count -gt 0 -or $Survivors.Count -gt 0) {
    'The declared package set did not settle (missing or different: {0}; undeclared still held: {1})' -f @(
      ($Ignored -join ', '), ($Survivors -join ', ')
    )
  } ElseIf (-not $Changed) {
    'No package changes; {0} already correct' -f $Unchanged.Count
  } Else {
    'Applied: {0}; removed: {1}; already correct: {2}' -f @(
      ($Applied -join ', '), ($Removed -join ', '), $Unchanged.Count
    )
  }
  removed    = [System.String[]]$Removed
  survivors  = [System.String[]]$Survivors
  unchanged  = [System.String[]]$Unchanged
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

# The result is published either way, so a caller can see every package that failed to settle.
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
