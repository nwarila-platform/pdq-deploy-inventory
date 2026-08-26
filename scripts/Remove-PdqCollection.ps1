#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Removes every PDQ Inventory collection this repository owns that the declaration does not
        name, and proves the shipped ones were not touched.

    .DESCRIPTION
        Ownership is by name, at the top level. The product's own furniture is declared to this
        script rather than assumed: the shipped Collection Library announces itself on every row
        (Type = LibraryCollection, measured 2026-08-26), and the handful of collections a fresh
        install carries OUTSIDE the library -- Servers, Workstations and their kin -- arrive in
        -BuiltIn from the role, which pins them as the measured furniture of the pinned product
        version. Everything else at the top level is either declared in -Definition or drift, and
        drift is removed together with its children: a role that states an end state and then
        leaves strangers standing has not stated the end state.

        The command line can import a collection and list them all, but has no verb that deletes
        one, so removal goes through the product's own database tooling -- the sqlite3.exe the
        vendor ships beside the command line, against the database path the product itself
        reports -- with the discipline the variable pruner proved: the table is read as row id
        plus hex-encoded name, no raw name ever enters SQL, each DELETE binds the row's whole
        identity, and the batch is one immediate transaction under a busy timeout.

        Two readings precede any mutation. The table is the authority; the command line's own
        listing is read as well, and every top-level name the table holds must appear in it, so a
        stale or misparsed table read is refused. The check runs one way only, because the listing
        also carries synthetic entries -- All Computers -- that no table row backs (measured). A
        collection referenced by a scan profile or an auto report is refused rather than removed,
        and a name carrying a backslash is refused because the listing separates levels with one.

        Afterwards the table is read again: every stranger gone, every declared and built-in name
        still standing, and the library holding EXACTLY as many collections as before -- the
        proof, on every converge, that removal never reached what the vendor ships.

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
        The COMPLETE set of declared collection definitions, as exported. Their Name elements are
        the collections this repository owns, and no others. Required, and required even when
        empty, so owning nothing is something a caller states rather than something it forgets to
        pass.

    .PARAMETER BuiltIn
        The top-level collections the pinned product ships OUTSIDE its Collection Library -- the
        furniture a fresh install carries. Owned by the vendor, never by this repository, and
        therefore never removed. Stated by the role rather than discovered, so a product upgrade
        that changes the furniture changes a reviewed file instead of silently widening what may
        be deleted.

    .PARAMETER CliPath
        Full path to PDQInventory.exe. Collections are an Inventory concept; Deploy has no
        equivalent, so this script serves the one product.

    .EXAMPLE
        .\Remove-PdqCollection.ps1 -Definition @() -BuiltIn @('Servers', 'Workstations') -CliPath $InventoryCliPath

    .OUTPUTS
        One object carrying removed, kept, declared, library, changed, check_mode and msg.
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
  [System.String[]] $Definition,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [AllowEmptyCollection()]
  [System.String[]] $BuiltIn,

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
  Throw ('The PDQ Inventory command line is not at ''{0}''' -f $CliPath)
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

# The declaration, read once: each definition's own Name element is a collection this repository
# owns. Matched case-insensitively, agreeing with the import step's by-name matching.
$DeclaredSet = [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::OrdinalIgnoreCase)
ForEach ($Text In $Definition) {
  $Document = [System.Xml.XmlDocument]::new()
  Try {
    $Document.LoadXml($Text.TrimStart([System.Char]0xFEFF))
  } Catch {
    Throw ('A definition is not valid XML ({0})' -f $PSItem.Exception.GetBaseException().Message)
  }
  $NameNode = $Document.SelectSingleNode('/AdminArsenal.Export/Collection/Name')
  If ($Null -eq $NameNode -or [System.String]::IsNullOrWhiteSpace($NameNode.InnerText)) {
    Throw 'A definition does not name a collection'
  }
  $Null = $DeclaredSet.Add($NameNode.InnerText)
}
$BuiltInSet = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.String[]]$BuiltIn, [System.StringComparer]::OrdinalIgnoreCase
)

# The command line has no verb that deletes a collection, so removal goes through the vendor's own
# database tooling, with the discipline the variable pruner proved on this same product family.
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
If (-not (Test-Path -LiteralPath:$DatabasePath)) {
  Throw ('The database is not at {0}' -f $DatabasePath)
}

# The whole table, read as id, parent, library-or-not type, and HEX-ENCODED name -- hex so the
# parse cannot be confused by anything a name may contain, and exactly four fields so a type that
# somehow carried the separator refuses loudly instead of parsing wrong. No busy-timeout pragma:
# its echoed value would be a malformed row to this parse, and a reader never waits on the writer
# under the write-ahead journal this database runs.
Function Read-CollectionRow {
  $Rows = [System.Collections.Generic.List[System.Object]]::new()
  ForEach ($Line In (Invoke-NativeCommand -Operation:'Reading the collection table' -FilePath:$Sqlite `
        -Argument:@($DatabasePath, "SELECT CollectionId, IFNULL(ParentId, ''), IFNULL(Type, ''), hex(Name) FROM Collections;")).Output) {
    $Parts = ([System.String]$Line).Split('|')
    If ($Parts.Count -ne 4 -or $Parts[0] -notmatch '^[0-9]+$' -or $Parts[1] -notmatch '^[0-9]*$' -or $Parts[3] -notmatch '^([0-9A-Fa-f]{2})*$') {
      Throw ('The collection table did not read back as id, parent, type and hex name: {0}' -f $Line)
    }
    $Bytes = [System.Byte[]]::new($Parts[3].Length / 2)
    For ($B = 0; $B -lt $Bytes.Length; $B++) {
      $Bytes[$B] = [System.Convert]::ToByte($Parts[3].Substring($B * 2, 2), 16)
    }
    $Rows.Add([PSCustomObject]@{
        Id     = $Parts[0]
        Parent = $Parts[1]
        Type   = $Parts[2]
        Hex    = $Parts[3]
        Name   = [System.Text.Encoding]::UTF8.GetString($Bytes)
      })
  }
  Return , $Rows
}

$Rows = Read-CollectionRow
$TopLevel = @($Rows | Where-Object { $PSItem.Parent -eq '' })
$LibraryCount = @($Rows | Where-Object { $PSItem.Type -ceq 'LibraryCollection' }).Count

# Two top-level names that are one name case-insensitively cannot be reconciled against a
# declaration that treats them as the same collection; refused before anything else.
$Folded = [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::OrdinalIgnoreCase)
ForEach ($Row In $TopLevel) {
  If ($Row.Type -cne 'LibraryCollection' -and -not $Folded.Add($Row.Name)) {
    Throw ('The product holds more than one top-level collection named {0} (differing only by case); resolve that by hand first' -f $Row.Name)
  }
}

# The second reading: the command line's own listing, one path per line, top-level collections as
# their bare names. Every top-level name the table holds IN THIS SCRIPT'S SCOPE must appear -- a
# table read the product does not corroborate is refused. Scoped to the non-library rows and run
# one way only, both for measured reasons: the listing carries synthetic entries (All Computers)
# no table row backs, and the library's own top level (Applications and kin) sits in the table
# with no parent while the listing shows it under a synthetic Collection Library root.
$Listing = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.String[]]@((Invoke-NativeCommand -Operation:'Listing the collections' `
        -FilePath:$CliPath -Argument:@('GetAllCollections')).Output |
      ForEach-Object { ([System.String]$PSItem).TrimEnd([System.Char]13, [System.Char]10) } |
      Where-Object { $PSItem.Length -gt 0 }),
  [System.StringComparer]::Ordinal
)
ForEach ($Row In @($TopLevel | Where-Object { $PSItem.Type -cne 'LibraryCollection' })) {
  If ($Row.Name.Contains('\')) {
    Throw ('{0} holds a backslash, which the listing reads as a level separator; it cannot be corroborated and is refused' -f $Row.Name)
  }
  If (-not $Listing.Contains($Row.Name)) {
    Throw ('The table holds the top-level collection {0} but the product''s own listing does not; refusing to prune a product whose readings disagree' -f $Row.Name)
  }
}

# Ownership: a top-level collection that is not the library's, not the product's own furniture,
# and not declared, is drift -- removed together with every child under it.
$Strangers = @($TopLevel | Where-Object {
    $PSItem.Type -cne 'LibraryCollection' -and
    -not $BuiltInSet.Contains($PSItem.Name) -and
    -not $DeclaredSet.Contains($PSItem.Name)
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

# A collection a scan profile scans or an auto report reads is refused rather than removed:
# deleting it would leave a dangling reference in vendor state this script does not own.
If ($Doomed.Count -gt 0) {
  $DoomedId = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]@($Doomed | ForEach-Object Id), [System.StringComparer]::Ordinal
  )
  $Referenced = (Invoke-NativeCommand -Operation:'Reading the collection references' -FilePath:$Sqlite `
      -Argument:@($DatabasePath, "SELECT IFNULL(CollectionId, '') FROM ScanProfileCollections UNION SELECT IFNULL(CollectionSourceId, '') FROM AutoReports;")).Output
  ForEach ($Reference In $Referenced) {
    If ($DoomedId.Contains(([System.String]$Reference).Trim())) {
      $Holder = @($Doomed | Where-Object { $PSItem.Id -eq ([System.String]$Reference).Trim() })[0]
      Throw ('{0} is not declared, but a scan profile or auto report refers to it; remove that reference or declare the collection' -f $Holder.Name)
    }
  }
}

$Removed = [System.Collections.Generic.List[System.String]]::new()

If (-not $Ansible.CheckMode) {
  If ($Doomed.Count -gt 0) {
    # Children before parents, and each DELETE bound to the row's whole identity -- the id and
    # the hex of the name exactly as it was read -- so a row that moved between the read and this
    # write matches nothing instead of dying for its predecessor's id. One immediate transaction
    # under a busy timeout; a failure leaves no partial prune behind.
    $Statements = [System.Collections.Generic.List[System.String]]::new()
    $Statements.Add('PRAGMA busy_timeout = 5000;')
    $Statements.Add('BEGIN IMMEDIATE;')
    For ($D = $Doomed.Count - 1; $D -ge 0; $D--) {
      $Statements.Add(("DELETE FROM Collections WHERE CollectionId = {0} AND hex(Name) = '{1}';" -f $Doomed[$D].Id, $Doomed[$D].Hex))
    }
    $Statements.Add('COMMIT;')
    $Null = Invoke-NativeCommand -Operation:'Removing the undeclared collections' -FilePath:$Sqlite `
      -Argument:@($DatabasePath, ($Statements -join ' '))
    ForEach ($Root In $Strangers) {
      $Removed.Add($Root.Name)
    }
  }

  # Read again, always: every stranger gone, every declared and built-in name still standing, and
  # the library holding exactly as many collections as before -- the standing proof that removal
  # never reached what the vendor ships.
  $After = Read-CollectionRow
  $AfterTop = @($After | Where-Object { $PSItem.Parent -eq '' })
  $Survivors = @($AfterTop | Where-Object {
      $PSItem.Type -cne 'LibraryCollection' -and
      -not $BuiltInSet.Contains($PSItem.Name) -and
      -not $DeclaredSet.Contains($PSItem.Name)
    })
  If ($Survivors.Count -gt 0) {
    Throw ('The product still holds the undeclared collection(s) {0}' -f (@($Survivors | ForEach-Object Name) -join ', '))
  }
  $AfterNames = [System.Collections.Generic.HashSet[System.String]]::new(
    [System.String[]]@($AfterTop | ForEach-Object Name), [System.StringComparer]::OrdinalIgnoreCase
  )
  $Missing = @(@($DeclaredSet) + @($BuiltInSet) | Where-Object { -not $AfterNames.Contains($PSItem) })
  If ($Missing.Count -gt 0) {
    Throw ('The product does not hold the declared or built-in collection(s) {0}' -f ($Missing -join ', '))
  }
  $AfterLibrary = @($After | Where-Object { $PSItem.Type -ceq 'LibraryCollection' }).Count
  If ($AfterLibrary -ne $LibraryCount) {
    Throw ('The Collection Library held {0} collections before this run and {1} after; nothing here may touch it' -f $LibraryCount, $AfterLibrary)
  }
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]($Strangers.Count -gt 0)
  check_mode = [System.Boolean]$Ansible.CheckMode
  declared   = [System.Int32]$DeclaredSet.Count
  kept       = [System.Int32]($TopLevel.Count - $Strangers.Count)
  library    = [System.Int32]$LibraryCount
  msg        = If ($Strangers.Count -eq 0) {
    'No undeclared collections; {0} kept, the library''s {1} untouched' -f ($TopLevel.Count), $LibraryCount
  } ElseIf ($Ansible.CheckMode) {
    'Would remove {0}' -f (@($Strangers | ForEach-Object Name) -join ', ')
  } Else {
    'Removed {0}' -f ($Removed -join ', ')
  }
  removed    = [System.String[]]$(If ($Ansible.CheckMode) { @($Strangers | ForEach-Object Name) } Else { $Removed })
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
