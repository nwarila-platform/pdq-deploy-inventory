#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Makes a complete set of PDQ Inventory collection definitions authoritative.

    .DESCRIPTION
        The definitions ARE the declaration: each exported XML document names one collection the
        product is required to hold. Anything else outside the product's built-in set, shipped
        Collection Library and directory-sync-owned tree is removed, including its children.

        The product's export is both the comparison and the verify oracle. Every declared name is
        read in one ExportCollections launch, passing each name as a separate argument and a
        staging directory for the resulting files. Only definitions that differ are imported.
        After mutation the complete declared set is read in one more launch and must match, so
        anything the product accepted but did not store is named and fails the run. A converged
        host pays for one export and writes nothing.

        Comparison ignores where the console FILED the collection: the row id, parent, path and
        the library-or-not type marker never survive a round trip (measured 2026-08-26 against
        PDQ Inventory 20.1.8.0 -- an import lands at the top level and comes back as its own
        DynamicCollection whatever the source said). Everything else, the filter logic and the
        timestamps included, exports back byte-for-byte, so any remaining difference is a real
        difference in the collection. The byte-order mark, line endings and trailing whitespace
        are normalised for the same reason as everywhere else: Ansible strips trailing whitespace
        from the declaration on its way in.

        The export writes one file per requested collection into a staging directory. Every file
        is read whole and the directory is removed. A collection definition carries no secrets.

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
        The complete set of collection definitions, as the product's own export writes them.
        Required even when empty, so owning nothing is an explicit declaration.

    .PARAMETER BuiltIn
        Top-level collections the pinned product ships outside the Collection Library. These are
        product-owned furniture and are never pruned.

    .PARAMETER CliPath
        Full path to PDQInventory.exe. Collections are an Inventory concept; Deploy has no
        equivalent, so this script serves the one product.

    .EXAMPLE
        .\Set-PdqCollection.ps1 -Definition @((Get-Content -Raw '.\Chrome Below Pinned Version.xml')) -BuiltIn @('Servers', 'Workstations') -CliPath 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'

    .OUTPUTS
        One object carrying applied, removed, unchanged, ignored, changed, check_mode and msg.
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
  [AllowEmptyCollection()]
  [System.String[]]
  $BuiltIn,

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

# The command line selects a collection by PATTERN: -Name reads * and ? as wildcards, and its help
# reserves commas as selection syntax. Multiple names are passed as separate arguments, but a name
# carrying any of those characters still cannot be addressed unambiguously as itself.
New-Variable -Force -Name:'NAME_PATTERN' -Option:('Private', 'ReadOnly') -Value:(
  [System.Text.RegularExpressions.Regex]::new('^[^*?,]+$')
)

# Where a console FILED a collection is a fact about that console, not about the collection. An
# import lands at the top level as its own row whatever the source said, so the first five never
# survive a round trip: compared, they would report a change on every converge and then fail the
# verification that follows it. Measured 2026-08-26 -- Id 4431 -> 5765, ParentId 4430 -> null,
# Path to the bare name, Type LibraryCollection -> DynamicCollection, and a LibraryCollectionId
# the declaration never carried came back as value="null"; TypeName, the filter logic and even
# the timestamps came back byte-identical.
#
# CustomVariables is different in kind but equally derived: the export EMBEDS a snapshot of every
# referenced custom variable's CURRENT value (measured -- a filter naming the pinned browser
# version came back carrying the version string of the day). The variable store is the source of
# truth for those values and is itself reconciled by this repository, so the snapshot is not part
# of the collection's declaration and would otherwise dirty every collection each time a pin
# moves. Matched under // because a collection nests its children as Collection elements.
# Not Private: the comparison function below is a child scope and has to read it.
New-Variable -Force -Name:'PLACEMENT_ELEMENTS' -Option:'ReadOnly' -Value:(
  [System.String[]]@(
    '//Collection/Id'
    '//Collection/ParentId'
    '//Collection/Path'
    '//Collection/Type'
    '//Collection/LibraryCollectionId'
    '//Collection/CustomVariables'
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
  Throw ('The PDQ Inventory command line is not at ''{0}''' -f $CliPath)
}

# What the product varies between writes of the same collection, plus the trailing whitespace Ansible
# has already stripped from the declaration on its way here.
Function ConvertTo-ComparableText {
  Param ([System.String] $Text)
  Return $Text.TrimStart([System.Char]0xFEFF).Replace("`r`n", "`n").TrimEnd()
}

# What gets COMPARED: the same document with the console's filing removed, so two products holding
# the same collection in different folders agree. Both sides go through it, so encoding and formatting
# cannot differ either -- this compares the document, not the bytes that happened to carry it.
Function ConvertTo-ComparableCollection {
  Param ([System.String] $Text)
  If ([System.String]::IsNullOrWhiteSpace($Text)) {
    Return [System.String]::Empty
  }
  $Document = [System.Xml.XmlDocument]::new()
  Try {
    $Document.LoadXml((ConvertTo-ComparableText -Text:$Text))
  } Catch {
    Throw ('A collection definition is not valid XML ({0})' -f $PSItem.Exception.GetBaseException().Message)
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

# Read every declared name in one ExportCollections launch. Exit 3 means none of the requested
# names exist. A successful batch must yield exactly one file per requested name, and each file's
# own Name element decides which request it answers; filenames are product presentation only.
Function Get-CollectionMap {
  Param ([System.String[]] $Name)
  $Current = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  If ($Name.Count -eq 0) {
    Return , $Current
  }

  $Requested = [System.Collections.Generic.HashSet[System.String]]::new(
    $Name, [System.StringComparer]::OrdinalIgnoreCase
  )
  $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-collection-export'
  If (Test-Path -LiteralPath:$Staged) {
    Remove-Item -LiteralPath:$Staged -Recurse -Force
  }
  $Null = New-Item -ItemType:'Directory' -Path:$Staged
  Try {
    [System.String[]]$Argument = @('ExportCollections', '-Name') + $Name + @(
      '-Path', $Staged, '-Overwrite'
    )
    $Export = Invoke-NativeCommand -FilePath:$CliPath `
      -Operation:'Exporting the declared collections' `
      -SuccessExitCode:@(0, 1, 2, 3, 4) -Argument:$Argument
    Switch ($Export.Exit) {
      1 { Throw 'ExportCollections reported that one or more requested collections failed to export' }
      2 { Throw 'ExportCollections was cancelled' }
      3 { Return , $Current }
      4 { Throw 'ExportCollections skipped one or more requested collections because an export file already existed' }
    }
    $Files = @(Get-ChildItem -LiteralPath:$Staged -File)
    If ($Files.Count -ne $Requested.Count) {
      Throw ('ExportCollections reported success for {0} requested collection(s) but wrote {1} export file(s)' -f @(
          $Requested.Count, $Files.Count
        ))
    }
    ForEach ($File In $Files) {
      Try {
        $Text = ConvertTo-ComparableText -Text:(Get-Content -LiteralPath:$File.FullName -Raw)
        $Document = [System.Xml.XmlDocument]::new()
        $Document.LoadXml($Text)
      } Catch {
        Throw ('Reading the collection export at ''{0}'': {1}' -f @(
            $File.FullName, $PSItem.Exception.GetBaseException().Message
          ))
      }
      If (@($Document.SelectNodes('/AdminArsenal.Export/Collection')).Count -ne 1) {
        Throw ('The collection export at ''{0}'' does not carry exactly one top-level collection' -f $File.FullName)
      }
      $NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Collection/Name')
      If ($Null -eq $NameNode -or -not $Requested.Contains($NameNode.InnerText)) {
        Throw ('The collection export at ''{0}'' does not answer a requested name' -f $File.FullName)
      }
      If ($Current.ContainsKey($NameNode.InnerText)) {
        Throw ('ExportCollections wrote more than one definition for {0}' -f $NameNode.InnerText)
      }
      $Current.Add($NameNode.InnerText, $Text)
    }
  } Finally {
    Remove-Item -LiteralPath:$Staged -Recurse -Force -ErrorAction:'SilentlyContinue'
  }
  Return , $Current
}

# Parse the complete declaration before any product read. Each name has exactly one owner, is
# addressable by the batch export, and cannot overlap the product furniture protected below.
$BuiltInSet = [System.Collections.Generic.HashSet[System.String]]::new(
  $BuiltIn, [System.StringComparer]::OrdinalIgnoreCase
)
$Declared = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
$DeclaredKey = [System.Collections.Generic.Dictionary[System.String, System.String]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
ForEach ($Text In $Definition) {
  $Normal = ConvertTo-ComparableText -Text:$Text
  $Document = [System.Xml.XmlDocument]::new()
  Try {
    $Document.LoadXml($Normal)
  } Catch {
    Throw ('A definition is not valid XML ({0})' -f $PSItem.Exception.GetBaseException().Message)
  }
  If (@($Document.SelectNodes('/AdminArsenal.Export/Collection')).Count -ne 1) {
    Throw 'A definition must carry exactly one top-level collection'
  }
  $NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Collection/Name')
  If ($Null -eq $NameNode -or [System.String]::IsNullOrWhiteSpace($NameNode.InnerText)) {
    Throw 'A definition does not name a collection'
  }
  $Name = [System.String]$NameNode.InnerText
  If ($Name.Contains('\')) {
    Throw ('{0} holds a backslash, which the product''s listing reads as a level separator' -f $Name)
  }
  If (-not $NAME_PATTERN.IsMatch($Name)) {
    Throw ('{0} cannot be addressed by the command line, which reads *, ? and , as selection syntax' -f $Name)
  }
  If ($BuiltInSet.Contains($Name)) {
    Throw ('{0} is both declared and listed as the product''s own furniture; one name cannot have two owners' -f $Name)
  }
  If ($Declared.ContainsKey($Name)) {
    Throw ('{0} is declared more than once; two definitions cannot own one name' -f $Name)
  }
  $Declared.Add($Name, $Normal)
  $DeclaredKey.Add($Name, (ConvertTo-ComparableCollection -Text:$Normal))
}

$Initial = Get-CollectionMap -Name:@($Declared.Keys)
$ToImport = [System.Collections.Generic.List[System.String]]::new()
$Unchanged = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Name In $Declared.Keys) {
  If ($Initial.ContainsKey($Name) -and
    (ConvertTo-ComparableCollection -Text:$Initial[$Name]) -ceq $DeclaredKey[$Name]) {
    $Unchanged.Add($Name)
  } Else {
    $ToImport.Add($Name)
  }
}

# The former pruner's established transaction remains intact: the product has no collection
# delete verb, so the shipped sqlite3 is used only for that already-ratified DELETE. All state
# comparison, import and post-write definition verification stays on PDQInventory.exe.
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

Function Read-CollectionRow {
  $Rows = [System.Collections.Generic.List[System.Object]]::new()
  ForEach ($Line In (Invoke-NativeCommand -Operation:'Reading the collection table' -FilePath:$Sqlite `
        -Argument:@($DatabasePath, "SELECT CollectionId, IFNULL(ParentId, ''), IFNULL(Type, ''), hex(Name), hex(IFNULL(ADDistinguishedName, '')) FROM Collections;")).Output) {
    $Parts = ([System.String]$Line).Split('|')
    If ($Parts.Count -ne 5 -or $Parts[0] -notmatch '^[0-9]+$' -or
      $Parts[1] -notmatch '^[0-9]*$' -or $Parts[3] -notmatch '^([0-9A-Fa-f]{2})*$' -or
      $Parts[4] -notmatch '^([0-9A-Fa-f]{2})*$') {
      Throw ('The collection table did not read back as id, parent, type, hex name and hex AD distinguished name: {0}' -f $Line)
    }
    $Bytes = [System.Byte[]]::new($Parts[3].Length / 2)
    For ($B = 0; $B -lt $Bytes.Length; $B++) {
      $Bytes[$B] = [System.Convert]::ToByte($Parts[3].Substring($B * 2, 2), 16)
    }
    $Rows.Add([PSCustomObject]@{
        Id                   = $Parts[0]
        Parent               = $Parts[1]
        Type                 = $Parts[2]
        Hex                  = $Parts[3]
        Name                 = [System.Text.Encoding]::UTF8.GetString($Bytes)
        ADDistinguishedHex   = $Parts[4]
        ActiveDirectoryOwned = $Parts[2] -ceq 'ActiveDirectoryCollection' -or $Parts[4].Length -gt 0
      })
  }
  Return , $Rows
}

$Rows = Read-CollectionRow
$TopLevel = @($Rows | Where-Object { $PSItem.Parent -eq '' })
$LibraryRows = @($Rows | Where-Object { $PSItem.Type -ceq 'LibraryCollection' })
$LibraryIdentity = @($LibraryRows | ForEach-Object { '{0}|{1}' -f $PSItem.Id, $PSItem.Hex } |
    Sort-Object) -join "`n"
$ActiveDirectoryRows = @($Rows | Where-Object { $PSItem.ActiveDirectoryOwned })
$ActiveDirectoryIdentity = @($ActiveDirectoryRows |
    ForEach-Object { '{0}|{1}' -f $PSItem.Id, $PSItem.Hex } | Sort-Object) -join "`n"
$ActiveDirectoryNames = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.String[]]@($ActiveDirectoryRows | ForEach-Object Name),
  [System.StringComparer]::OrdinalIgnoreCase
)
$ClaimedActiveDirectory = @($Declared.Keys | Where-Object {
    $ActiveDirectoryNames.Contains($PSItem)
  })
If ($ClaimedActiveDirectory.Count -gt 0) {
  Throw ('{0} is declared but owned by Active Directory sync; one name cannot have two owners' -f `
    ($ClaimedActiveDirectory -join ', '))
}

$Folded = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
ForEach ($Row In $TopLevel) {
  If ($Row.Type -cne 'LibraryCollection' -and -not $Row.ActiveDirectoryOwned -and
    -not $Folded.Add($Row.Name)) {
    Throw ('The product holds more than one top-level collection named {0} (differing only by case); resolve that by hand first' -f $Row.Name)
  }
}

$SyntheticNames = [System.String[]]@('All Computers')
$Listing = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.String[]]@((Invoke-NativeCommand -Operation:'Listing the collections' `
        -FilePath:$CliPath -Argument:@('GetAllCollections')).Output |
      ForEach-Object { ([System.String]$PSItem).TrimEnd([System.Char]13, [System.Char]10) } |
      Where-Object { $PSItem.Length -gt 0 }),
  [System.StringComparer]::Ordinal
)
ForEach ($Row In @($TopLevel | Where-Object {
      $PSItem.Type -cne 'LibraryCollection' -and -not $PSItem.ActiveDirectoryOwned
    })) {
  If ($Row.Name.Contains('\')) {
    Throw ('{0} holds a backslash, which the listing reads as a level separator; it cannot be corroborated' -f $Row.Name)
  }
  If ($SyntheticNames -contains $Row.Name) {
    Throw ('{0} wears the name of an entry the listing invents; it cannot be corroborated' -f $Row.Name)
  }
  If (-not $Listing.Contains($Row.Name)) {
    Throw ('The table holds the top-level collection {0} but the product''s listing does not' -f $Row.Name)
  }
}

$TopNames = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.String[]]@($TopLevel | ForEach-Object Name), [System.StringComparer]::OrdinalIgnoreCase
)
$Vanished = @($BuiltIn | Where-Object { -not $TopNames.Contains($PSItem) })
If ($Vanished.Count -gt 0) {
  Throw ('The product does not hold the built-in collection(s) {0}; refusing to prune' -f ($Vanished -join ', '))
}

$Strangers = @($TopLevel | Where-Object {
    $PSItem.Type -cne 'LibraryCollection' -and
    -not $PSItem.ActiveDirectoryOwned -and
    -not $BuiltInSet.Contains($PSItem.Name) -and
    -not $Declared.ContainsKey($PSItem.Name)
  })
$Doomed = [System.Collections.Generic.List[System.Object]]::new()
ForEach ($Root In $Strangers) {
  $Queue = [System.Collections.Generic.Queue[System.Object]]::new()
  $Queue.Enqueue($Root)
  While ($Queue.Count -gt 0) {
    $Current = $Queue.Dequeue()
    $Doomed.Add($Current)
    ForEach ($Child In @($Rows | Where-Object { $PSItem.Parent -eq $Current.Id })) {
      $Queue.Enqueue($Child)
    }
  }
}
ForEach ($Dead In $Doomed) {
  If ($Dead.Type -ceq 'LibraryCollection') {
    Throw ('{0} sits under an undeclared collection but belongs to the Collection Library' -f $Dead.Name)
  }
  # Refuse the whole subtree: deleting its ancestor would detach directory-sync-owned state, so
  # skipping only this row would still damage the product's hierarchy.
  If ($Dead.ActiveDirectoryOwned) {
    Throw ('{0} sits under an undeclared collection but belongs to Active Directory sync' -f $Dead.Name)
  }
}

If ($Doomed.Count -gt 0) {
  $DoomedId = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]@($Doomed | ForEach-Object Id), [System.StringComparer]::Ordinal
  )
  $Referenced = (Invoke-NativeCommand -Operation:'Reading the collection references' -FilePath:$Sqlite `
      -Argument:@($DatabasePath, "SELECT IFNULL(CollectionId, '') FROM ScanProfileCollections UNION SELECT IFNULL(CollectionSourceId, '') FROM AutoReports;")).Output
  ForEach ($Reference In $Referenced) {
    If ($DoomedId.Contains(([System.String]$Reference).Trim())) {
      $Holder = @($Doomed | Where-Object { $PSItem.Id -eq ([System.String]$Reference).Trim() })[0]
      Throw ('{0} is not declared, but a scan profile or auto report refers to it' -f $Holder.Name)
    }
  }
}

$Applied = [System.Collections.Generic.List[System.String]]::new()
$Removed = [System.Collections.Generic.List[System.String]]::new()
$Ignored = [System.Collections.Generic.List[System.String]]::new()
$Survivors = [System.Collections.Generic.List[System.String]]::new()
$Changed = $ToImport.Count -gt 0 -or $Strangers.Count -gt 0

If ($Ansible.CheckMode) {
  $Applied.AddRange($ToImport)
  $Removed.AddRange([System.String[]]@($Strangers | ForEach-Object Name))
} Else {
  ForEach ($Name In $ToImport) {
    $Staged = Join-Path -Path:$Ansible.Tmpdir -ChildPath:'pdq-collection-import.xml'
    Try {
      Set-Content -LiteralPath:$Staged -Value:$Declared[$Name] -Encoding:'utf8' -NoNewline
      $Null = Invoke-NativeCommand -FilePath:$CliPath `
        -Operation:('Importing the collection ''{0}''' -f $Name) `
        -Argument:@('ImportCollections', '-Path', $Staged, '-Overwrite')
    } Finally {
      Remove-Item -LiteralPath:$Staged -Force -ErrorAction:'SilentlyContinue'
    }
  }

  If ($Doomed.Count -gt 0) {
    $Statements = [System.Collections.Generic.List[System.String]]::new()
    $Statements.Add('PRAGMA busy_timeout = 5000;')
    $Statements.Add('BEGIN IMMEDIATE;')
    For ($D = $Doomed.Count - 1; $D -ge 0; $D--) {
      $TypeHex = -join ([System.Text.Encoding]::UTF8.GetBytes($Doomed[$D].Type) |
          ForEach-Object { $PSItem.ToString('X2') })
      $Predicate = "DELETE FROM Collections WHERE CollectionId = {0} AND hex(Name) = '{1}' AND IFNULL(ParentId, '') = '{2}' AND hex(IFNULL(Type, '')) = '{3}' AND hex(IFNULL(ADDistinguishedName, '')) = '{4}'" -f @(
        $Doomed[$D].Id, $Doomed[$D].Hex, $Doomed[$D].Parent, $TypeHex,
        $Doomed[$D].ADDistinguishedHex
      )
      $Statements.Add($Predicate `
          + ' AND CollectionId NOT IN (SELECT CollectionId FROM ScanProfileCollections)' `
          + ' AND CollectionId NOT IN (SELECT IFNULL(CollectionSourceId, -1) FROM AutoReports);')
    }
    $Statements.Add('COMMIT;')
    $Null = Invoke-NativeCommand -Operation:'Removing the undeclared collections' -FilePath:$Sqlite `
      -Argument:@($DatabasePath, ($Statements -join ' '))
  }

  $Final = If ($Changed) { Get-CollectionMap -Name:@($Declared.Keys) } Else { $Initial }
  ForEach ($Name In $ToImport) {
    If ($Final.ContainsKey($Name) -and
      (ConvertTo-ComparableCollection -Text:$Final[$Name]) -ceq $DeclaredKey[$Name]) {
      $Applied.Add($Name)
    } Else {
      $Ignored.Add($Name)
    }
  }
  ForEach ($Name In $Declared.Keys) {
    If (-not $Final.ContainsKey($Name) -or
      (ConvertTo-ComparableCollection -Text:$Final[$Name]) -cne $DeclaredKey[$Name]) {
      If (-not $Ignored.Contains($Name)) {
        $Ignored.Add($Name)
      }
    }
  }

  If ($Changed) {
    $After = Read-CollectionRow
    $AfterIdentity = [System.Collections.Generic.HashSet[System.String]]::new(
      [System.StringComparer]::Ordinal
    )
    ForEach ($Row In $After) {
      $Null = $AfterIdentity.Add(('{0}|{1}' -f $Row.Id, $Row.Hex))
    }
    ForEach ($Dead In $Doomed) {
      If ($AfterIdentity.Contains(('{0}|{1}' -f $Dead.Id, $Dead.Hex))) {
        $Survivors.Add($Dead.Name)
      }
    }
    ForEach ($Root In $Strangers) {
      If (-not $AfterIdentity.Contains(('{0}|{1}' -f $Root.Id, $Root.Hex))) {
        $Removed.Add($Root.Name)
      }
    }
    $AfterTop = @($After | Where-Object { $PSItem.Parent -eq '' })
    $AfterNames = [System.Collections.Generic.HashSet[System.String]]::new(
      [System.String[]]@($AfterTop | ForEach-Object Name), [System.StringComparer]::OrdinalIgnoreCase
    )
    $MissingProtected = @(@($Declared.Keys) + @($BuiltIn) |
        Where-Object { -not $AfterNames.Contains($PSItem) })
    If ($MissingProtected.Count -gt 0) {
      Throw ('The product does not hold the declared or built-in collection(s) {0}' -f `
        ($MissingProtected -join ', '))
    }
    $LibraryAfter = @($After | Where-Object { $PSItem.Type -ceq 'LibraryCollection' } |
        ForEach-Object { '{0}|{1}' -f $PSItem.Id, $PSItem.Hex } | Sort-Object) -join "`n"
    If ($LibraryAfter -cne $LibraryIdentity) {
      Throw 'The Collection Library does not hold the same rows it held before this run'
    }
    $ActiveDirectoryAfter = @($After | Where-Object { $PSItem.ActiveDirectoryOwned } |
        ForEach-Object { '{0}|{1}' -f $PSItem.Id, $PSItem.Hex } | Sort-Object) -join "`n"
    If ($ActiveDirectoryAfter -cne $ActiveDirectoryIdentity) {
      Throw 'Active Directory sync does not hold the same collection rows it held before this run'
    }
  }
}

$KeptCount = @($TopLevel | Where-Object {
    $PSItem.Type -cne 'LibraryCollection' -and -not $PSItem.ActiveDirectoryOwned
  }).Count - $Strangers.Count
$Result = [PSCustomObject]@{
  applied    = [System.String[]]$Applied
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  declared   = [System.Int32]$Declared.Count
  ignored    = [System.String[]]$Ignored
  kept       = [System.Int32]$KeptCount
  library    = [System.Int32]$LibraryRows.Count
  msg        = If ($Ansible.CheckMode) {
    'Would apply: {0}; would remove: {1}' -f ($Applied -join ', '), ($Removed -join ', ')
  } ElseIf ($Ignored.Count -gt 0 -or $Survivors.Count -gt 0) {
    'The declared collection set did not settle (missing or different: {0}; undeclared still held: {1})' -f ($Ignored -join ', '), ($Survivors -join ', ')
  } ElseIf (-not $Changed) {
    'No collection changes; {0} already correct, {1} built-in kept, library untouched' -f $Unchanged.Count, $BuiltInSet.Count
  } Else {
    'Applied: {0}; removed: {1}; already correct: {2}' -f ($Applied -join ', '), ($Removed -join ', '), $Unchanged.Count
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

# The result is published either way, so a caller can see every collection that failed to settle.
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
