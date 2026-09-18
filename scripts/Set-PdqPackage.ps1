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
        directory for the resulting files. An export can append a package's nested dependencies;
        its first package alone answers the request. Only definitions that differ are imported,
        every undeclared package is removed, and the complete set is read back after mutation. A
        converged host pays for one batched export and writes nothing.

        Comparison uses that first package and ignores the byte-order mark, line-ending style,
        trailing whitespace, export MinimumVersion, console filing and console-derived values.
        The remaining XML is otherwise what was imported (measured 2026-08-25 against PDQ Deploy
        20.1.8.0), so any difference is a real difference in the package. Reading the definition
        through Ansible strips trailing whitespace on the way in, which is why the product's copy
        is trimmed to match rather than compared to the byte.

        ExportPackages exit 1 is a successful partial read only when every missing requested name
        has its matching not-found error and every other request wrote a valid package file. Exit
        3 is the successful empty answer when none of the requested packages exists. Presence is
        decided from each file's own Name element; filenames are presentation only.

        A collection condition's id and a scan step's profile id belong to the console that
        exported them. Both are resolved from a NAME against this console's own tables. Current
        condition rows are repaired whenever their id differs, even when their package needs no
        import, because the deployment runner resolves membership by id alone. A scan profile id
        is written into the document that is imported, because that one does travel. Both are read
        back after a write and must name what the declaration asked for. A name that resolves to
        nothing stops the run: a package gated on a collection this console does not hold imports
        quietly and then fails every deployment before its first step.

        A nested step's target id and name are also console output; its target path declares the
        package it means. Every target must name another declaration, dependencies are imported
        before the packages that nest them, and a cycle stops the run before mutation. After an
        import, the export must prove that each declared nested reference survived the write.

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

    .PARAMETER ScanProfile
        The PDQ Inventory scan profile every scan step in a package runs, by package name. A
        package's export carries only the profile's numeric id, which is local to the console that
        wrote it, so the name is declared here instead. A package with no scan step has no entry,
        and a scan step whose package is not named stops the run.

    .PARAMETER CliPath
        Full path to PDQDeploy.exe. Packages are a Deploy concept; Inventory has no equivalent, so
        this script serves the one product.

    .PARAMETER InventoryCliPath
        Full path to PDQInventory.exe, which is asked where the collections are kept. Read only
        when a declared package gates a step on a collection.

    .EXAMPLE
        .\Set-PdqPackage.ps1 -Definition @((Get-Content -Raw '.\Google Chrome - Install.xml')) -ScanProfile @{} -CliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe' -InventoryCliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'

    .OUTPUTS
        One object carrying applied, repaired, removed, unchanged, ignored, survivors, changed,
        check_mode and msg.
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
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $InventoryCliPath,

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
  $ScanProfile
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

# The two ids a definition carries that belong to the CONSOLE it was exported from rather than to
# the package. Both are resolved from their names and rewritten on arrival, so comparing them would
# report a change on every converge -- against the very values this script had just made correct.
# Not Private: the comparison function below is a child scope and has to read it.
New-Variable -Force -Name:'LOCAL_ID_ELEMENTS' -Option:'ReadOnly' -Value:(
  [System.String[]]@(
    "//PackageStepCondition[TypeName='Collection']/InventoryCollectionId"
    "//PackageStep[TypeName='ScanStep']/InventoryScanProfileId"
  )
)

# A nested target's path is its declaration-owned resolver; its id and name are console-derived
# output, so only the path participates in comparison.
New-Variable -Force -Name:'NESTED_OUTPUT_ELEMENTS' -Option:'ReadOnly' -Value:(
  [System.String[]]@(
    '//NestedPackageStep/TargetPackageId'
    '//NestedPackageStep/TargetPackageName'
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

# The export envelope's MinimumVersion is product-derived, so the envelope cannot participate in
# comparison. Placement is stripped so two consoles holding the same package filed differently
# agree.
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
  ForEach ($Element In ($PLACEMENT_ELEMENTS + $LOCAL_ID_ELEMENTS + $NESTED_OUTPUT_ELEMENTS)) {
    ForEach ($Node In @($Document.SelectNodes($Element))) {
      $Null = $Node.ParentNode.RemoveChild($Node)
    }
  }
  Return $Document.SelectSingleNode('/AdminArsenal.Export/Package').OuterXml
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
# a batch. Each file's first package names the request it answers; filenames decide nothing.
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
      $Packages = @($Document.SelectNodes('/AdminArsenal.Export/Package'))
      If ($Packages.Count -eq 0) {
        Throw ('The package export at ''{0}'' does not carry a package' -f $File.FullName)
      }
      $NameNode = $Packages[0].SelectSingleNode('Name')
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

# Text the product owns, carried as hex both ways: a name is free text, and the command line's own
# row and column separators, its quoting and anything non-ASCII all survive the round trip.
Function ConvertFrom-HexText {
  Param ([System.String] $Hex)
  $Bytes = [System.Byte[]]::new($Hex.Length / 2)
  For ($B = 0; $B -lt $Bytes.Length; $B++) {
    $Bytes[$B] = [System.Convert]::ToByte($Hex.Substring($B * 2, 2), 16)
  }
  Return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

# Which part of a package a reference belongs to, said the way the console says it. A condition
# sits either under the step it gates or under the package's own condition list.
Function Get-StepLabel {
  Param ([System.Xml.XmlNode] $Node)
  $Ancestor = $Node
  While ($Null -ne $Ancestor) {
    $Title = $Ancestor.SelectSingleNode('Title')
    If ($Null -ne $Title -and -not [System.String]::IsNullOrWhiteSpace($Title.InnerText)) {
      Return ('the step ''{0}''' -f $Title.InnerText)
    }
    $Ancestor = $Ancestor.ParentNode
  }
  Return 'the package itself'
}

Function Add-PackageDependencyOrder {
  Param (
    [System.String] $Name,
    [System.Collections.IDictionary] $Dependency,
    [System.Collections.Generic.HashSet[System.String]] $Complete,
    [System.Collections.Generic.List[System.String]] $Trail,
    [System.Collections.Generic.List[System.String]] $Order
  )
  If ($Complete.Contains($Name)) {
    Return
  }
  $CycleStart = $Trail.IndexOf($Name)
  If ($CycleStart -ge 0) {
    $Cycle = [System.Collections.Generic.List[System.String]]::new()
    For ($C = $CycleStart; $C -lt $Trail.Count; $C++) {
      $Cycle.Add($Trail[$C])
    }
    $Cycle.Add($Name)
    Throw ('The declared packages carry a nested-package reference cycle: {0}' -f `
      ($Cycle -join ' -> '))
  }

  $Trail.Add($Name)
  ForEach ($Target In $Dependency[$Name]) {
    Add-PackageDependencyOrder -Name:$Target -Dependency:$Dependency -Complete:$Complete `
      -Trail:$Trail -Order:$Order
  }
  $Trail.RemoveAt($Trail.Count - 1)
  $Null = $Complete.Add($Name)
  $Order.Add($Name)
}

# Where a product keeps its database, asked of the product rather than assumed from where it was
# installed: the two products keep theirs on different volumes here.
Function Get-DatabasePath {
  Param ([System.String] $Path, [System.String] $Product)
  $Info = (Invoke-NativeCommand -FilePath:$Path -Argument:@('SystemInfo') `
      -Operation:('Reading the {0} system information' -f $Product)).Output
  $Database = (
    @($Info | Where-Object -FilterScript { $PSItem -match '^\s*Database\s*:' }) |
      Select-Object -First 1
  ) -replace '^\s*Database\s*:\s*', ''
  If (-not $Database) {
    Throw ('{0} did not report a database path' -f $Product)
  }
  If (-not (Test-Path -LiteralPath:$Database -PathType:'Leaf')) {
    Throw ('The {0} database is not at ''{1}''' -f $Product, $Database)
  }
  Return $Database
}

# One of the product's own name-to-id tables. A name the table holds twice is recorded rather than
# rejected here: only a name a declaration actually refers to has to be unambiguous.
Function Get-NameToId {
  Param ([System.String] $Database, [System.String] $Operation, [System.String] $Statement)
  $Id = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
    [System.StringComparer]::Ordinal
  )
  $Ambiguous = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.StringComparer]::Ordinal
  )
  ForEach ($Line In (Invoke-NativeCommand -FilePath:$Sqlite -Operation:$Operation `
        -Argument:@($Database, $Statement)).Output) {
    $Parts = ([System.String]$Line).Split('|')
    If ($Parts.Count -ne 2 -or $Parts[0] -notmatch '^[0-9]+$' -or
      $Parts[1] -notmatch '^([0-9A-Fa-f]{2})*$') {
      Throw ('{0}: the table did not read back as id and hex name: {1}' -f $Operation, $Line)
    }
    $Name = ConvertFrom-HexText -Hex:$Parts[1]
    If ($Id.ContainsKey($Name)) {
      $Null = $Ambiguous.Add($Name)
    } Else {
      $Id.Add($Name, $Parts[0])
    }
  }
  Return [PSCustomObject]@{ Ambiguous = $Ambiguous; Id = $Id }
}

# Every current package's collection condition, with the row identity a write has to be bound to.
# Historical definitions have no current Packages.PackageDefinitionId owner and are not reconciled.
Function Read-ConditionRow {
  $Rows = [System.Collections.Generic.List[System.Object]]::new()
  ForEach ($Line In (Invoke-NativeCommand -FilePath:$Sqlite `
        -Operation:'Reading the collection conditions' -Argument:@(
        $Database
        ("SELECT c.rowid, IFNULL(c.InventoryCollectionId, ''), " +
        "hex(IFNULL(c.InventoryCollectionName, '')), hex(p.Name) " +
        'FROM PackageStepConditionCollection c ' +
        'JOIN PackageStepConditions pc ' +
        'ON pc.PackageStepConditionId = c.PackageStepConditionId ' +
        'LEFT JOIN PackageSteps s ON s.PackageStepId = pc.PackageStepId ' +
        'JOIN PackageDefinitions d ON d.PackageDefinitionId = ' +
        'COALESCE(s.PackageDefinitionId, pc.PackageDefinitionId) ' +
        'JOIN Packages p ON p.PackageDefinitionId = d.PackageDefinitionId;')
      )).Output) {
    $Parts = ([System.String]$Line).Split('|')
    If ($Parts.Count -ne 4 -or $Parts[0] -notmatch '^[0-9]+$' -or $Parts[1] -notmatch '^[0-9]*$' -or
      $Parts[2] -notmatch '^([0-9A-Fa-f]{2})*$' -or
      $Parts[3] -notmatch '^([0-9A-Fa-f]{2})+$') {
      Throw ('The collection conditions did not read back as row, id, hex name and hex package: {0}' -f $Line)
    }
    $Rows.Add([PSCustomObject]@{
        Hex     = $Parts[2].ToUpperInvariant()
        Id      = $Parts[1]
        Name    = ConvertFrom-HexText -Hex:$Parts[2]
        Package = ConvertFrom-HexText -Hex:$Parts[3]
        Row     = $Parts[0]
      })
  }
  Return , $Rows
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
$CollectionReference = [System.Collections.Generic.List[System.Object]]::new()
$ScanReference = [System.Collections.Generic.List[System.Object]]::new()
$NestedReference = [System.Collections.Generic.List[System.Object]]::new()
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

  # What this definition points at that only THIS console can name. A condition carries the
  # collection's name as well as its id, so the declaration says which collection it means; a scan
  # step carries the id alone, so its profile is named in the declaration instead.
  ForEach ($Node In $Document.SelectNodes("//PackageStepCondition[TypeName='Collection']")) {
    $Collection = $Node.SelectSingleNode('InventoryCollectionName')
    If ($Null -ne $Collection -and
      -not [System.String]::IsNullOrWhiteSpace($Collection.InnerText)) {
      $CollectionReference.Add([PSCustomObject]@{
          Collection = [System.String]$Collection.InnerText
          Package    = $Name
          Step       = Get-StepLabel -Node:$Node
        })
    }
  }
  ForEach ($Node In $Document.SelectNodes("//PackageStep[TypeName='ScanStep']")) {
    If (-not $ScanProfile.Contains($Name) -or
      [System.String]::IsNullOrWhiteSpace([System.String]$ScanProfile[$Name])) {
      Throw ('{0} carries {1}, which runs a scan profile no declaration names' -f @(
          $Name, (Get-StepLabel -Node:$Node)
        ))
    }
    $ScanReference.Add([PSCustomObject]@{
        Package = $Name
        Profile = [System.String]$ScanProfile[$Name]
        Step    = Get-StepLabel -Node:$Node
      })
  }

  ForEach ($Node In $Document.SelectNodes("//NestedPackageStep[TypeName='NestedPackage']")) {
    $Target = $Node.SelectSingleNode('TargetPackagePath')
    $Step = Get-StepLabel -Node:$Node
    If ($Null -eq $Target -or [System.String]::IsNullOrWhiteSpace($Target.InnerText)) {
      Throw ('{0} carries {1} with an empty TargetPackagePath' -f $Name, $Step)
    }
    $NestedReference.Add([PSCustomObject]@{
        Package = $Name
        Step    = $Step
        Target  = [System.String]$Target.InnerText
      })
  }

  ForEach ($Node In $Document.SelectNodes('//*')) {
    If ($Node.ChildNodes.Count -eq 1 -and
      $Node.FirstChild.NodeType -eq [System.Xml.XmlNodeType]::Text) {
      $Null = $Referenced.Add($Node.InnerText)
    }
  }
}

$Orphan = [System.String[]]@($ScanProfile.Keys | Where-Object {
    -not $Declared.ContainsKey([System.String]$PSItem)
  })
If ($Orphan.Count -gt 0) {
  Throw ('A scan profile is declared for {0}, which no definition names' -f ($Orphan -join ', '))
}

$DeclaredSet = [System.Collections.Generic.HashSet[System.String]]::new(
  $DeclaredName, [System.StringComparer]::Ordinal
)
# TargetPackagePath resolves against bare names only while imports discard FolderId and
# Packages\ paths.
ForEach ($Reference In $NestedReference) {
  If (-not $DeclaredSet.Contains($Reference.Target)) {
    Throw ('{0} carries {1}, which nests ''{2}'', but no declaration names that target' -f @(
        $Reference.Package, $Reference.Step, $Reference.Target
      ))
  }
}

$Dependency = [System.Collections.Generic.Dictionary[System.String, System.Object]]::new(
  [System.StringComparer]::Ordinal
)
ForEach ($Name In $DeclaredName) {
  $Dependency.Add($Name, [System.Collections.Generic.List[System.String]]::new())
}
ForEach ($Reference In $NestedReference) {
  If (-not $Dependency[$Reference.Package].Contains($Reference.Target)) {
    $Dependency[$Reference.Package].Add($Reference.Target)
  }
}
$DependencyOrder = [System.Collections.Generic.List[System.String]]::new()
$Complete = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.StringComparer]::Ordinal
)
$Trail = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Name In $DeclaredName) {
  Add-PackageDependencyOrder -Name:$Name -Dependency:$Dependency -Complete:$Complete `
    -Trail:$Trail -Order:$DependencyOrder
}

$Held = Get-HeldPackageName
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
$NeedsImport = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.StringComparer]::Ordinal
)
$InitiallyUnchanged = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Name In $DeclaredName) {
  If ($Initial.ContainsKey($Name) -and
    (ConvertTo-ComparablePackage -Text:$Initial[$Name]) -ceq $DeclaredKey[$Name]) {
    $InitiallyUnchanged.Add($Name)
  } Else {
    $Null = $NeedsImport.Add($Name)
  }
}
$ToImport = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Name In $DependencyOrder) {
  If ($NeedsImport.Contains($Name)) {
    $ToImport.Add($Name)
  }
}

# Resolve every reference before anything is written. A package gated on a collection this console
# does not hold is broken on arrival, and saying so costs one read, where importing it costs a
# deployment that fails before its first step. A declaration that refers to neither a collection
# nor a scan profile reads no database at all.
$Localized = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
  [System.StringComparer]::Ordinal
)
ForEach ($Name In $DeclaredName) {
  $Localized.Add($Name, $Declared[$Name])
}

If ($CollectionReference.Count -gt 0 -or $ScanReference.Count -gt 0) {
  $Sqlite = Join-Path -Path:(Split-Path -Path:$CliPath -Parent) -ChildPath:'sqlite3.exe'
  If (-not (Test-Path -LiteralPath:$Sqlite -PathType:'Leaf')) {
    Throw ('The product database tool is not at ''{0}''' -f $Sqlite)
  }
  $Database = Get-DatabasePath -Path:$CliPath -Product:'PDQ Deploy'
}

If ($CollectionReference.Count -gt 0) {
  # Deploy holds the condition; Inventory holds the collection and mints the id both agree on.
  If (-not (Test-Path -LiteralPath:$InventoryCliPath -PathType:'Leaf')) {
    Throw ('The PDQ Inventory command line is not at ''{0}''' -f $InventoryCliPath)
  }
  $InventoryDatabase = Get-DatabasePath -Path:$InventoryCliPath -Product:'PDQ Inventory'
  $CollectionTable = Get-NameToId -Database:$InventoryDatabase `
    -Operation:'Reading the collections' -Statement:'SELECT CollectionId, hex(Name) FROM Collections;'
  ForEach ($Reference In $CollectionReference) {
    If ($CollectionTable.Ambiguous.Contains($Reference.Collection)) {
      Throw ('{0} gates {1} on the collection ''{2}'', which PDQ Inventory holds more than once' -f @(
          $Reference.Package, $Reference.Step, $Reference.Collection
        ))
    }
    If (-not $CollectionTable.Id.ContainsKey($Reference.Collection)) {
      Throw ('{0} gates {1} on the collection ''{2}'', which PDQ Inventory does not hold' -f @(
          $Reference.Package, $Reference.Step, $Reference.Collection
        ))
    }
  }
}

If ($ScanReference.Count -gt 0) {
  # Deploy mirrors Inventory's scan profiles under ids of its own, so a step's profile is resolved
  # against the product the step runs in.
  $ProfileTable = Get-NameToId -Database:$Database -Operation:'Reading the scan profiles' `
    -Statement:'SELECT InventoryScanProfileId, hex(Name) FROM InventoryScanProfiles;'
  ForEach ($Reference In $ScanReference) {
    If ($ProfileTable.Ambiguous.Contains($Reference.Profile)) {
      Throw ('{0} runs the scan profile ''{1}'' at {2}, which PDQ Deploy holds more than once' -f @(
          $Reference.Package, $Reference.Profile, $Reference.Step
        ))
    }
    If (-not $ProfileTable.Id.ContainsKey($Reference.Profile)) {
      Throw ('{0} runs the scan profile ''{1}'' at {2}, which PDQ Deploy does not hold' -f @(
          $Reference.Package, $Reference.Profile, $Reference.Step
        ))
    }
  }

  # This id survives the import, so it is written into the document the product is given rather
  # than into the row the product writes from it.
  ForEach ($Name In [System.String[]]@($ScanReference | ForEach-Object Package |
        Select-Object -Unique)) {
    $Document = [System.Xml.XmlDocument]::new()
    $Document.PreserveWhitespace = $True
    $Document.LoadXml($Declared[$Name])
    ForEach ($Node In $Document.SelectNodes(
        "//PackageStep[TypeName='ScanStep']/InventoryScanProfileId")) {
      $Node.SetAttribute('value', $ProfileTable.Id[[System.String]$ScanProfile[$Name]])
    }
    $Localized[$Name] = $Document.OuterXml
  }
}

$Applied = [System.Collections.Generic.List[System.String]]::new()
$Repaired = [System.Collections.Generic.List[System.String]]::new()
$Removed = [System.Collections.Generic.List[System.String]]::new()
$Unchanged = [System.Collections.Generic.List[System.String]]::new()
$Ignored = [System.Collections.Generic.List[System.String]]::new()
$Survivors = [System.Collections.Generic.List[System.String]]::new()
$Changed = $ToImport.Count -gt 0 -or $Extra.Count -gt 0

If ($Ansible.CheckMode) {
  $Applied.AddRange($ToImport.ToArray())
  $Removed.AddRange($Extra)
  $Unchanged.AddRange($InitiallyUnchanged.ToArray())
  If ($CollectionReference.Count -gt 0) {
    $RepairSet = [System.Collections.Generic.HashSet[System.String]]::new(
      [System.StringComparer]::Ordinal
    )
    ForEach ($Row In (Read-ConditionRow)) {
      $Wanted = @($CollectionReference | Where-Object {
          $PSItem.Package -ceq $Row.Package -and $PSItem.Collection -ceq $Row.Name
        })
      If ($Wanted.Count -gt 0 -and $Row.Id -cne $CollectionTable.Id[$Row.Name]) {
        $Null = $RepairSet.Add($Row.Package)
      }
    }
    ForEach ($Name In $DeclaredName) {
      If ($RepairSet.Contains($Name)) {
        $Repaired.Add($Name)
      }
    }
    If ($Repaired.Count -gt 0) {
      $Changed = $True
    }
  }
} Else {
  ForEach ($Name In $ToImport) {
    $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-package-import.xml'
    Try {
      Try {
        Set-Content -LiteralPath:$Staged -Value:$Localized[$Name] -Encoding:'utf8' -NoNewline
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

  # ImportPackages stores a condition's collection NAME and leaves its id null, while collection
  # ids can also move after a package has converged. Every statement remains bound to the row and
  # values read, and a current definition already pointing at the right collection is not written.
  $ConditionChanged = $False
  If ($CollectionReference.Count -gt 0) {
    $Statements = [System.Collections.Generic.List[System.String]]::new()
    $RepairSet = [System.Collections.Generic.HashSet[System.String]]::new(
      [System.StringComparer]::Ordinal
    )
    ForEach ($Row In (Read-ConditionRow)) {
      $Wanted = @($CollectionReference | Where-Object {
          $PSItem.Package -ceq $Row.Package -and $PSItem.Collection -ceq $Row.Name
        })
      If ($Wanted.Count -gt 0 -and $Row.Id -cne $CollectionTable.Id[$Row.Name]) {
        $Null = $RepairSet.Add($Row.Package)
        $Statements.Add(("UPDATE PackageStepConditionCollection SET InventoryCollectionId = {0} WHERE rowid = {1} AND IFNULL(CAST(InventoryCollectionId AS TEXT), '') = '{2}' AND hex(IFNULL(InventoryCollectionName, '')) = '{3}';" -f @(
              $CollectionTable.Id[$Row.Name], $Row.Row, $Row.Id, $Row.Hex
            )))
      }
    }
    If ($Statements.Count -gt 0) {
      $Statements.Insert(0, 'PRAGMA busy_timeout = 5000;')
      $Statements.Insert(1, 'BEGIN IMMEDIATE;')
      $Statements.Add('COMMIT;')
      $Null = Invoke-NativeCommand -FilePath:$Sqlite `
        -Operation:'Resolving the collection conditions' `
        -Argument:@($Database, ($Statements -join ' '))
      ForEach ($Name In $DeclaredName) {
        If ($RepairSet.Contains($Name)) {
          $Repaired.Add($Name)
        }
      }
      $ConditionChanged = $True
      $Changed = $True
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

  # An unresolved target is accepted on import and silently removed, so only the read-back proves
  # that the declared nested reference survived the write.
  ForEach ($Reference In @($NestedReference | Where-Object {
        $ToImport.Contains($PSItem.Package) -and $Final.ContainsKey($PSItem.Package)
      })) {
    $Document = [System.Xml.XmlDocument]::new()
    $Document.LoadXml($Final[$Reference.Package])
    $Package = $Document.SelectSingleNode('/AdminArsenal.Export/Package')
    $DeclaredCount = @($NestedReference | Where-Object {
        $PSItem.Package -ceq $Reference.Package -and
        $PSItem.Step -ceq $Reference.Step -and
        $PSItem.Target -ceq $Reference.Target
      }).Count
    $Resolved = @($Package.SelectNodes(".//NestedPackageStep[TypeName='NestedPackage']") |
        Where-Object {
          (Get-StepLabel -Node:$PSItem) -ceq $Reference.Step -and
          $Null -ne $PSItem.SelectSingleNode('TargetPackagePath') -and
          -not [System.String]::IsNullOrWhiteSpace(
            $PSItem.SelectSingleNode('TargetPackagePath').InnerText
          ) -and
          $PSItem.SelectSingleNode('TargetPackagePath').InnerText -ceq $Reference.Target
        })
    If ($Resolved.Count -lt $DeclaredCount) {
      Throw ('{0} does not carry {1} targeting ''{2}'' after the import' -f @(
          $Reference.Package, $Reference.Step, $Reference.Target
        ))
    }
  }

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

  # Proof against the product rather than against the write: every condition row now carries the
  # id of a collection that still answers to the declared name, and every scan step comes back out
  # of the product carrying this console's own profile id. A package the product did not settle on
  # is already named in the result, so its references are left to that.
  $Settled = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]@($Applied.ToArray() + $Unchanged.ToArray()), [System.StringComparer]::Ordinal
  )

  If (($ToImport.Count -gt 0 -or $ConditionChanged) -and $CollectionReference.Count -gt 0) {
    $ConditionAfter = Read-ConditionRow
    $CollectionAfter = Get-NameToId -Database:$InventoryDatabase `
      -Operation:'Reading the collections' `
      -Statement:'SELECT CollectionId, hex(Name) FROM Collections;'
    ForEach ($Reference In @($CollectionReference | Where-Object {
          $Settled.Contains($PSItem.Package)
        })) {
      $Resolved = $CollectionTable.Id[$Reference.Collection]
      $Rows = @($ConditionAfter | Where-Object {
          $PSItem.Package -ceq $Reference.Package -and
          $PSItem.Name -ceq $Reference.Collection
        })
      If ($Rows.Count -eq 0 -or @($Rows | Where-Object { $PSItem.Id -cne $Resolved }).Count -gt 0) {
        Throw ('{0} does not gate {1} on the collection ''{2}'' after the import' -f @(
            $Reference.Package, $Reference.Step, $Reference.Collection
          ))
      }
      If (-not $CollectionAfter.Id.ContainsKey($Reference.Collection) -or
        $CollectionAfter.Id[$Reference.Collection] -cne $Resolved) {
        Throw ('{0} gates {1} on collection {2}, which is no longer the collection named ''{3}''' -f @(
            $Reference.Package, $Reference.Step, $Resolved, $Reference.Collection
          ))
      }
    }
  }

  If ($ToImport.Count -gt 0 -and $ScanReference.Count -gt 0) {
    $ProfileAfter = Get-NameToId -Database:$Database -Operation:'Reading the scan profiles' `
      -Statement:'SELECT InventoryScanProfileId, hex(Name) FROM InventoryScanProfiles;'
    ForEach ($Reference In @($ScanReference | Where-Object {
          $Settled.Contains($PSItem.Package)
        })) {
      $Resolved = $ProfileTable.Id[$Reference.Profile]
      If (-not $ProfileAfter.Id.ContainsKey($Reference.Profile) -or
        $ProfileAfter.Id[$Reference.Profile] -cne $Resolved) {
        Throw ('{0} runs {1} on scan profile {2}, which is no longer the profile named ''{3}''' -f @(
            $Reference.Package, $Reference.Step, $Resolved, $Reference.Profile
          ))
      }
    }
    ForEach ($Name In [System.String[]]@($ScanReference | ForEach-Object Package |
          Select-Object -Unique | Where-Object { $Settled.Contains($PSItem) })) {
      $Resolved = $ProfileTable.Id[[System.String]$ScanProfile[$Name]]
      $Document = [System.Xml.XmlDocument]::new()
      $Document.LoadXml($Final[$Name])
      $Package = $Document.SelectSingleNode('/AdminArsenal.Export/Package')
      ForEach ($Node In $Package.SelectNodes(
          ".//PackageStep[TypeName='ScanStep']/InventoryScanProfileId")) {
        If ($Node.GetAttribute('value') -cne $Resolved) {
          Throw ('{0} runs {1} on scan profile {2}, but the product stored {3}' -f @(
              $Name, (Get-StepLabel -Node:$Node.ParentNode), $Resolved,
              $Node.GetAttribute('value')
            ))
        }
      }
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
    'Would apply: {0}; would remove: {1}; would repair references: {2}; already correct: {3}' -f @(
      ($Applied -join ', '), ($Removed -join ', '), ($Repaired -join ', '), $Unchanged.Count
    )
  } ElseIf ($Ignored.Count -gt 0 -or $Survivors.Count -gt 0) {
    'The declared package set did not settle (missing or different: {0}; undeclared still held: {1})' -f @(
      ($Ignored -join ', '), ($Survivors -join ', ')
    )
  } ElseIf (-not $Changed) {
    'No package changes; {0} already correct' -f $Unchanged.Count
  } ElseIf ($Applied.Count -eq 0 -and $Removed.Count -eq 0 -and $Repaired.Count -gt 0) {
    'Repaired references: {0}; already correct: {1}' -f @(
      ($Repaired -join ', '), $Unchanged.Count
    )
  } ElseIf ($Repaired.Count -gt 0) {
    'Applied: {0}; removed: {1}; repaired references: {2}; already correct: {3}' -f @(
      ($Applied -join ', '), ($Removed -join ', '), ($Repaired -join ', '), $Unchanged.Count
    )
  } Else {
    'Applied: {0}; removed: {1}; already correct: {2}' -f @(
      ($Applied -join ', '), ($Removed -join ', '), $Unchanged.Count
    )
  }
  repaired   = [System.String[]]$Repaired
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
