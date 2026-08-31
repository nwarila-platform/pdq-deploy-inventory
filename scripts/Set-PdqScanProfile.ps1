#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Reconciles every PDQ Inventory scan profile in one database transaction.

    .DESCRIPTION
        Each definition owns the whole named profile: scalar fields, schedule triggers, zero
        collection targets, and the complete scanner multiset. A declared name is applied even
        when it is built in. An undeclared built-in is untouched; every other profile is removed
        with its owned graph and gathered data unless a reference, default status, or shared
        scanner makes removal unsafe.

        Definitions and the complete graph are read before one BEGIN IMMEDIATE. Every refusal is
        revalidated against the transaction's pre-mutation state, creations and in-place updates
        run before removals, and one COMMIT publishes the entire reconcile. A failure before that
        commit rolls everything back. Only a post-commit re-read can produce the sanitized recap.

    .PARAMETER DebugLevel
        Three-digit control string configuring ErrorActionPreference, command tracing, and strict
        mode. Default '103' means stop on error, no tracing, strict mode 3.

    .PARAMETER LogLevel
        Six-digit control string setting Verbose, Debug, Information, Warning, Error, and Fatal
        stream preferences.

    .PARAMETER Definition
        The complete scan-profile export texts. The script processes the list internally so one
        remote PowerShell launch applies the whole declaration.

    .PARAMETER BuiltIn
        Product-shipped profile names to preserve when they are not declared.

    .PARAMETER CliPath
        Full path to PDQInventory.exe. Its SystemInfo output locates the Inventory database, and
        sqlite3.exe is taken from beside it.

    .PARAMETER DeployCliPath
        Full path to PDQDeploy.exe for cross-database reference checks. Empty means Deploy is not
        installed on this host.

    .OUTPUTS
        One object carrying changed, check_mode, definition, ignored, msg, and sanitized recap.
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
  [System.String] $CliPath,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [AllowEmptyString()]
  [System.String] $DeployCliPath
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

$WhatIfPreference = $False

New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)
New-Variable -Force -Name:'LocalizedData' -Option:'ReadOnly' -Value:(
  [System.Collections.Hashtable]@{
    CliMissing          = 'The PDQ Inventory command line is not at ''{0}''.'
    DeployCliMissing    = 'The PDQ Deploy command line is not at ''{0}''.'
    SqliteMissing       = 'The product database tool is not at ''{0}''.'
    SystemInfoMissing   = '''{0}'' SystemInfo did not report a database path.'
    DatabaseMissing     = 'The {0} database is not at ''{1}''.'
    NativeStart         = '{0}: ''{1}'' could not be run ({2}).'
    NativeExit          = '{0}: {1} exited {2}{3}.'
    DefinitionXml       = 'A scan-profile definition is not valid XML ({0}).'
    DefinitionShape     = 'A definition must carry exactly one top-level ScanProfile.'
    DefinitionName      = 'A scan-profile definition does not carry a non-empty Name.'
    DefinitionDuplicate = '''{0}'' is declared more than once; one name cannot have two definitions.'
    CollectionsNonEmpty = '''{0}'' declares collection targets; non-empty Collections is not supported.'
    ScannerTypeMissing  = 'A scanner in ''{0}'' does not carry a TypeName.'
    ScannerTypeInvalid  = '''{0}'' carries unsupported configuration for the bare scanner type ''{1}''.'
    ScalarInvalid       = '''{0}'' in ''{1}'' is not a valid {2} value.'
    DatabaseRead        = '{0} did not read back in the expected {1}-field shape: {2}.'
    DatabaseDuplicate   = 'The database holds more than one profile named ''{0}''.'
    ScannerSubtype      = 'Scanner {0} of ''{1}'' has no readable {2} row.'
    SharedScanner       = '''{0}'' cannot be applied because its {1} scanner is also referenced by ''{2}''.'
    DefaultProfile      = '''{0}'' is the product default scan profile and cannot be removed.'
    InventoryReference  = '''{0}'' is undeclared but is referenced by Inventory {1}.'
    DeployReference     = '''{0}'' is undeclared but is referenced by Deploy {1}.'
    ProductDisagreement = 'The scan-profile table and GetAllScanProfiles disagree: {0}.'
    ApplyFailed         = '''{0}'' does not read back as declared after the reconcile committed.'
    RemovalFailed       = '''{0}'' left profile-owned rows behind after the reconcile committed: {1}.'
  }
)

New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)

For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

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

#region ------ [ Functions ] ----------------------------------------------------------------- #

Function ThrowError {
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
  [CmdletBinding()]
  Param (
    [System.String] $ErrorId,
    [System.Management.Automation.ErrorCategory] $ErrorCategory,
    [System.String] $ExceptionName,
    [AllowNull()]
    [System.Exception] $ExceptionObject,
    [System.String] $ExceptionMessage
  )
  Write-Debug -Message:'Entering Function: ThrowError'
  New-Variable -Force -Option:'Private' -Name:'Exception' -Value:(
    [System.Management.Automation.RuntimeException]::new($ExceptionMessage, $ExceptionObject)
  )
  $Exception.Data['ExceptionName'] = $ExceptionName
  New-Variable -Force -Option:'Private' -Name:'Record' -Value:(
    [System.Management.Automation.ErrorRecord]::new($Exception, $ErrorId, $ErrorCategory, $Null)
  )
  $PSCmdlet.ThrowTerminatingError($Record)
  Write-Debug -Message:'Exiting Function: ThrowError'
}

Function Invoke-NativeCommand {
  Param (
    [System.String] $Operation,
    [System.String] $FilePath,
    [System.String[]] $Argument = @(),
    [System.Int32[]] $SuccessExitCode = @(0)
  )
  Write-Debug -Message:'Entering Function: Invoke-NativeCommand'
  New-Variable -Force -Option:'Private' -Name:'Previous' -Value:(
    [System.Management.Automation.ActionPreference]$ErrorActionPreference
  )
  New-Variable -Force -Option:'Private' -Name:'Captured' -Value:([System.Object[]]@())
  New-Variable -Force -Option:'Private' -Name:'Exit' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'Written' -Value:(
    [System.Collections.Generic.List[System.String]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Said' -Value:(
    [System.Collections.Generic.List[System.String]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Line' -Value:([System.Object]$Null)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.Object]$Null)

  Try {
    $ErrorActionPreference = 'Continue'
    Set-Variable -Name:'Captured' -Value:([System.Object[]]@(& $FilePath @Argument 2>&1))
    Set-Variable -Name:'Exit' -Value:([System.Int32]$LASTEXITCODE)
  } Catch {
    ThrowError -ErrorId:'NativeStart' -ErrorCategory:'OpenError' `
      -ExceptionName:'RuntimeException' -ExceptionObject:$PSItem.Exception `
      -ExceptionMessage:($LocalizedData.NativeStart -f $Operation, $FilePath, $PSItem.Exception.Message)
  } Finally {
    $ErrorActionPreference = $Previous
  }

  ForEach ($Line In $Captured) {
    If ($Line -is [System.Management.Automation.ErrorRecord]) {
      $Said.Add(([System.String]$Line).Trim())
    } Else {
      $Written.Add([System.String]$Line)
    }
  }
  If ($SuccessExitCode -contains $Exit -and $Said.Count -gt 0) {
    Write-Warning -Message:('{0}: {1}' -f $Operation, ($Said -join '; '))
  }
  If ($SuccessExitCode -notcontains $Exit) {
    ThrowError -ErrorId:'NativeExit' -ErrorCategory:'InvalidResult' `
      -ExceptionName:'RuntimeException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.NativeExit -f @(
          $Operation
          (Split-Path -Leaf -Path:$FilePath)
          $Exit
          $(If ($Said.Count -gt 0) { ' -- ' + ($Said -join '; ') } Else { '' })
        ))
  }
  Set-Variable -Name:'Result' -Value:([PSCustomObject]@{
      Exit   = [System.Int32]$Exit
      Output = [System.String[]]$Written.ToArray()
    })
  $Result
  Write-Debug -Message:'Exiting Function: Invoke-NativeCommand'
  Remove-Variable -Name:'Operation', 'FilePath', 'Argument', 'SuccessExitCode', 'Previous',
    'Captured', 'Exit', 'Written', 'Said', 'Line', 'Result' -Force
}

Function Invoke-Sqlite {
  Param (
    [System.String] $Operation,
    [System.String] $Statement,
    [System.String] $DatabasePath,
    [System.String] $SqlitePath
  )
  Write-Debug -Message:'Entering Function: Invoke-Sqlite'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String[]]@())
  Set-Variable -Name:'Result' -Value:([System.String[]]@(
      (Invoke-NativeCommand -Operation:$Operation -FilePath:$SqlitePath `
        -Argument:@($DatabasePath, $Statement)).Output
    ))
  $Result
  Write-Debug -Message:'Exiting Function: Invoke-Sqlite'
  Remove-Variable -Name:'Operation', 'Statement', 'DatabasePath', 'SqlitePath', 'Result' -Force
}

Function ConvertTo-SqlText {
  Param ([AllowNull()] [System.String] $Value)
  Write-Debug -Message:'Entering Function: ConvertTo-SqlText'
  New-Variable -Force -Option:'Private' -Name:'Hex' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]"''")
  If ($Null -ne $Value) {
    Set-Variable -Name:'Hex' -Value:([System.String](-join (
        [System.Text.Encoding]::UTF8.GetBytes($Value) |
          ForEach-Object { $PSItem.ToString('X2') }
      )))
    If ($Hex.Length -gt 0) {
      Set-Variable -Name:'Result' -Value:([System.String]("CAST(x'{0}' AS TEXT)" -f $Hex))
    }
  }
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-SqlText'
  Remove-Variable -Name:'Value', 'Hex', 'Result' -Force
}

Function ConvertFrom-HexText {
  Param (
    [System.String] $Hex,
    [System.String] $Operation
  )
  Write-Debug -Message:'Entering Function: ConvertFrom-HexText'
  New-Variable -Force -Option:'Private' -Name:'Bytes' -Value:([System.Byte[]]@())
  New-Variable -Force -Option:'Private' -Name:'Index' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  If ($Hex -notmatch '^([0-9A-Fa-f]{2})*$') {
    ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' `
      -ExceptionName:'FormatException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.DatabaseRead -f $Operation, 'hex-text', $Hex)
  }
  Set-Variable -Name:'Bytes' -Value:([System.Byte[]]::new($Hex.Length / 2))
  For ($Index = 0; $Index -lt $Bytes.Length; $Index++) {
    $Bytes[$Index] = [System.Convert]::ToByte($Hex.Substring($Index * 2, 2), 16)
  }
  Set-Variable -Name:'Result' -Value:([System.String][System.Text.Encoding]::UTF8.GetString($Bytes))
  $Result
  Write-Debug -Message:'Exiting Function: ConvertFrom-HexText'
  Remove-Variable -Name:'Hex', 'Operation', 'Bytes', 'Index', 'Result' -Force
}

Function ConvertTo-CanonicalDateTime {
  Param (
    [AllowEmptyString()]
    [System.String] $Value,
    [System.String] $Field,
    [System.String] $ProfileRow
  )
  Write-Debug -Message:'Entering Function: ConvertTo-CanonicalDateTime'
  New-Variable -Force -Option:'Private' -Name:'Parsed' -Value:([System.DateTimeOffset]::MinValue)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  If ($Value.Length -gt 0) {
    If (-not [System.DateTimeOffset]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$Parsed
      )) {
      ThrowError -ErrorId:'ScalarInvalid' -ErrorCategory:'InvalidData' `
        -ExceptionName:'FormatException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.ScalarInvalid -f $Field, $ProfileRow, 'date-time')
    }
    Set-Variable -Name:'Result' -Value:([System.String]$Parsed.ToUniversalTime().ToString(
        'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture
      ))
  }
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-CanonicalDateTime'
  Remove-Variable -Name:'Value', 'Field', 'ProfileRow', 'Parsed', 'Result' -Force
}

Function ConvertTo-CanonicalLineText {
  Param ([AllowEmptyString()] [System.String] $Value)
  Write-Debug -Message:'Entering Function: ConvertTo-CanonicalLineText'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  Set-Variable -Name:'Result' -Value:([System.String]$Value.Replace("`r`n", "`n").Replace("`r", "`n"))
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-CanonicalLineText'
  Remove-Variable -Name:'Value', 'Result' -Force
}

Function Get-XmlScalar {
  Param (
    [System.Xml.XmlNode] $Parent,
    [System.String] $Name,
    [ValidateSet('String', 'Boolean', 'Integer', 'DateTime')]
    [System.String] $Kind,
    [System.String] $ProfileRow
  )
  Write-Debug -Message:'Entering Function: Get-XmlScalar'
  New-Variable -Force -Option:'Private' -Name:'Node' -Value:([System.Xml.XmlNode]$Null)
  New-Variable -Force -Option:'Private' -Name:'Value' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.Object][System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'Number' -Value:([System.Int32]0)
  Set-Variable -Name:'Node' -Value:([System.Xml.XmlNode]$Parent.SelectSingleNode($Name))
  If ($Null -ne $Node) {
    If ($Null -ne $Node.Attributes['value']) {
      Set-Variable -Name:'Value' -Value:([System.String]$Node.Attributes['value'].Value)
    } Else {
      Set-Variable -Name:'Value' -Value:([System.String]$Node.InnerText)
    }
  }
  If ($Value -ceq 'null') {
    Set-Variable -Name:'Value' -Value:([System.String]::Empty)
  }
  Switch ($Kind) {
    'String' {
      Set-Variable -Name:'Result' -Value:([System.String]$Value)
    }
    'DateTime' {
      Set-Variable -Name:'Result' -Value:([System.String](ConvertTo-CanonicalDateTime `
          -Value:$Value -Field:$Name -Profile:$ProfileRow))
    }
    'Boolean' {
      If ($Value.Length -eq 0) {
        Set-Variable -Name:'Result' -Value:([System.String]::Empty)
      } ElseIf ($Value -in @('true', 'True', '1')) {
        Set-Variable -Name:'Result' -Value:([System.Int32]1)
      } ElseIf ($Value -in @('false', 'False', '0')) {
        Set-Variable -Name:'Result' -Value:([System.Int32]0)
      } Else {
        ThrowError -ErrorId:'ScalarInvalid' -ErrorCategory:'InvalidData' `
          -ExceptionName:'FormatException' -ExceptionObject:$Null `
          -ExceptionMessage:($LocalizedData.ScalarInvalid -f $Name, $ProfileRow, 'boolean')
      }
    }
    'Integer' {
      If ($Value.Length -eq 0) {
        Set-Variable -Name:'Result' -Value:([System.String]::Empty)
      } ElseIf ([System.Int32]::TryParse($Value, [ref]$Number)) {
        Set-Variable -Name:'Result' -Value:([System.Int32]$Number)
      } Else {
        ThrowError -ErrorId:'ScalarInvalid' -ErrorCategory:'InvalidData' `
          -ExceptionName:'FormatException' -ExceptionObject:$Null `
          -ExceptionMessage:($LocalizedData.ScalarInvalid -f $Name, $ProfileRow, 'integer')
      }
    }
  }
  $Result
  Write-Debug -Message:'Exiting Function: Get-XmlScalar'
  Remove-Variable -Name:'Parent', 'Name', 'Kind', 'ProfileRow', 'Node', 'Value', 'Result', 'Number' -Force
}

Function Get-XmlList {
  Param (
    [System.Xml.XmlNode] $Parent,
    [System.String] $Name
  )
  Write-Debug -Message:'Entering Function: Get-XmlList'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:(
    [System.Collections.Generic.List[System.String]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Node' -Value:([System.Xml.XmlNode]$Null)
  ForEach ($Node In @($Parent.SelectNodes(('{0}/item' -f $Name)))) {
    $Result.Add([System.String]$Node.InnerText)
  }
  $Result.ToArray()
  Write-Debug -Message:'Exiting Function: Get-XmlList'
  Remove-Variable -Name:'Parent', 'Name', 'Result', 'Node' -Force
}

Function ConvertTo-ScannerModel {
  Param (
    [System.String] $Type,
    [PSCustomObject] $Payload
  )
  Write-Debug -Message:'Entering Function: ConvertTo-ScannerModel'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([PSCustomObject][ordered]@{
      type    = [System.String]$Type
      payload = [PSCustomObject]$Payload
    })
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-ScannerModel'
  Remove-Variable -Name:'Type', 'Payload', 'Result' -Force
}

Function ConvertTo-CanonicalScanner {
  Param ([PSCustomObject] $Scanner)
  Write-Debug -Message:'Entering Function: ConvertTo-CanonicalScanner'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  Set-Variable -Name:'Result' -Value:([System.String]($Scanner | ConvertTo-Json -Compress -Depth:8))
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-CanonicalScanner'
  Remove-Variable -Name:'Scanner', 'Result' -Force
}

Function ConvertTo-SortedScannerModel {
  Param ([System.Object[]] $Scanner)
  Write-Debug -Message:'Entering Function: ConvertTo-SortedScannerModel'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.Object[]]@())
  Set-Variable -Name:'Result' -Value:([System.Object[]]@(
      $Scanner | Sort-Object -Property:(
        @{ Expression = { $PSItem.type } },
        @{ Expression = { ConvertTo-CanonicalScanner -Scanner:$PSItem } }
      )
    ))
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-SortedScannerModel'
  Remove-Variable -Name:'Scanner', 'Result' -Force
}

Function Get-ScannerIdentity {
  Param ([PSCustomObject] $Scanner)
  Write-Debug -Message:'Entering Function: Get-ScannerIdentity'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  Switch ($Scanner.type) {
    'PowerShell' { Set-Variable -Name:'Result' -Value:([System.String]$Scanner.payload.uid) }
    'WMI' { Set-Variable -Name:'Result' -Value:([System.String]$Scanner.payload.name) }
    'Files' { Set-Variable -Name:'Result' -Value:([System.String](ConvertTo-CanonicalScanner -Scanner:$Scanner)) }
    'Registry' { Set-Variable -Name:'Result' -Value:([System.String](ConvertTo-CanonicalScanner -Scanner:$Scanner)) }
    Default { Set-Variable -Name:'Result' -Value:([System.String]$Scanner.type) }
  }
  $Result
  Write-Debug -Message:'Exiting Function: Get-ScannerIdentity'
  Remove-Variable -Name:'Scanner', 'Result' -Force
}

Function ConvertTo-CanonicalProfile {
  Param ([PSCustomObject] $ProfileRow)
  Write-Debug -Message:'Entering Function: ConvertTo-CanonicalProfile'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  Set-Variable -Name:'Result' -Value:([System.String]($ProfileRow | ConvertTo-Json -Compress -Depth:10))
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-CanonicalProfile'
  Remove-Variable -Name:'ProfileRow', 'Result' -Force
}

Function ConvertFrom-Definition {
  Param ([System.String] $Text)
  Write-Debug -Message:'Entering Function: ConvertFrom-Definition'
  New-Variable -Force -Option:'Private' -Name:'Document' -Value:([System.Xml.XmlDocument]::new())
  New-Variable -Force -Option:'Private' -Name:'ProfileNode' -Value:([System.Xml.XmlNode]$Null)
  New-Variable -Force -Option:'Private' -Name:'Name' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'ScannerModels' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'TriggerModels' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'ScannerNode' -Value:([System.Xml.XmlNode]$Null)
  New-Variable -Force -Option:'Private' -Name:'TriggerNode' -Value:([System.Xml.XmlNode]$Null)
  New-Variable -Force -Option:'Private' -Name:'Type' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'Payload' -Value:([PSCustomObject]@{})
  New-Variable -Force -Option:'Private' -Name:'ConfiguredNodeCount' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([PSCustomObject]$Null)

  Try {
    $Document.LoadXml($Text.TrimStart([System.Char]0xFEFF))
  } Catch {
    ThrowError -ErrorId:'DefinitionXml' -ErrorCategory:'InvalidData' `
      -ExceptionName:'XmlException' -ExceptionObject:$PSItem.Exception `
      -ExceptionMessage:($LocalizedData.DefinitionXml -f $PSItem.Exception.GetBaseException().Message)
  }
  If (@($Document.SelectNodes('/AdminArsenal.Export/ScanProfile')).Count -ne 1) {
    ThrowError -ErrorId:'DefinitionShape' -ErrorCategory:'InvalidData' `
      -ExceptionName:'FormatException' -ExceptionObject:$Null `
      -ExceptionMessage:$LocalizedData.DefinitionShape
  }
  Set-Variable -Name:'ProfileNode' -Value:([System.Xml.XmlNode]$Document.SelectSingleNode(
      '/AdminArsenal.Export/ScanProfile'
    ))
  Set-Variable -Name:'Name' -Value:([System.String](Get-XmlScalar `
      -Parent:$ProfileNode -Name:'Name' -Kind:'String' -Profile:'definition'))
  If ([System.String]::IsNullOrWhiteSpace($Name)) {
    ThrowError -ErrorId:'DefinitionName' -ErrorCategory:'InvalidData' `
      -ExceptionName:'FormatException' -ExceptionObject:$Null `
      -ExceptionMessage:$LocalizedData.DefinitionName
  }
  If (@($ProfileNode.SelectNodes('Collections/*')).Count -gt 0) {
    ThrowError -ErrorId:'CollectionsNonEmpty' -ErrorCategory:'InvalidData' `
      -ExceptionName:'NotSupportedException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.CollectionsNonEmpty -f $Name)
  }

  ForEach ($ScannerNode In @($ProfileNode.SelectNodes('Scanners/Scanner'))) {
    Set-Variable -Name:'Type' -Value:([System.String](Get-XmlScalar `
        -Parent:$ScannerNode -Name:'TypeName' -Kind:'String' -Profile:$Name))
    If ([System.String]::IsNullOrWhiteSpace($Type)) {
      ThrowError -ErrorId:'ScannerTypeMissing' -ErrorCategory:'InvalidData' `
        -ExceptionName:'FormatException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.ScannerTypeMissing -f $Name)
    }
    Switch ($Type) {
      'PowerShell' {
        Set-Variable -Name:'Payload' -Value:([PSCustomObject][ordered]@{
            name             = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'Name' -Kind:'String' -Profile:$Name)
            uid              = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'UID' -Kind:'String' -Profile:$Name)
            script           = [System.String](ConvertTo-CanonicalLineText -Value:(Get-XmlScalar -Parent:$ScannerNode -Name:'Script' -Kind:'String' -Profile:$Name))
            file_name        = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'FileName' -Kind:'String' -Profile:$Name)
            parameters       = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'Parameters' -Kind:'String' -Profile:$Name)
            additional_files = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'AdditionalFiles' -Kind:'String' -Profile:$Name)
            row_limit        = Get-XmlScalar -Parent:$ScannerNode -Name:'RowLimit' -Kind:'Integer' -Profile:$Name
          })
      }
      'WMI' {
        Set-Variable -Name:'Payload' -Value:([PSCustomObject][ordered]@{
            name                    = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'Name' -Kind:'String' -Profile:$Name)
            wmi_class_name          = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'WMIClassName' -Kind:'String' -Profile:$Name)
            namespace               = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'Namespace' -Kind:'String' -Profile:$Name)
            wql                     = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'WQL' -Kind:'String' -Profile:$Name)
            timeout                 = Get-XmlScalar -Parent:$ScannerNode -Name:'Timeout' -Kind:'Integer' -Profile:$Name
            use_preferences_timeout = Get-XmlScalar -Parent:$ScannerNode -Name:'UsePreferencesTimeout' -Kind:'Boolean' -Profile:$Name
            row_limit               = Get-XmlScalar -Parent:$ScannerNode -Name:'RowLimit' -Kind:'Integer' -Profile:$Name
          })
      }
      'Files' {
        Set-Variable -Name:'Payload' -Value:([PSCustomObject][ordered]@{
            file_scan_type       = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'FileScanType' -Kind:'String' -Profile:$Name)
            include_pattern_text = [System.String](ConvertTo-CanonicalLineText -Value:(Get-XmlScalar -Parent:$ScannerNode -Name:'IncludePatternText' -Kind:'String' -Profile:$Name))
            exclude_pattern_text = [System.String](ConvertTo-CanonicalLineText -Value:(Get-XmlScalar -Parent:$ScannerNode -Name:'ExcludePatternText' -Kind:'String' -Profile:$Name))
            include_patterns     = [System.String[]]@(Get-XmlList -Parent:$ScannerNode -Name:'IncludePatterns')
            exclude_patterns     = [System.String[]]@(Get-XmlList -Parent:$ScannerNode -Name:'ExcludePatterns')
            row_limit            = Get-XmlScalar -Parent:$ScannerNode -Name:'RowLimit' -Kind:'Integer' -Profile:$Name
          })
      }
      'Registry' {
        Set-Variable -Name:'Payload' -Value:([PSCustomObject][ordered]@{
            hive            = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'Hive' -Kind:'String' -Profile:$Name)
            include_pattern = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'IncludePattern' -Kind:'String' -Profile:$Name)
            exclude_pattern = [System.String](Get-XmlScalar -Parent:$ScannerNode -Name:'ExcludePattern' -Kind:'String' -Profile:$Name)
            row_limit       = Get-XmlScalar -Parent:$ScannerNode -Name:'RowLimit' -Kind:'Integer' -Profile:$Name
          })
      }
      Default {
        Set-Variable -Name:'ConfiguredNodeCount' -Value:([System.Int32]@(
            $ScannerNode.ChildNodes | Where-Object {
              $PSItem.Name -notin @('TypeName', 'SourceScannerId', 'DateCreated', 'DateModified', 'ModifiedDate')
            }
          ).Count)
        If ($ConfiguredNodeCount -gt 0) {
          ThrowError -ErrorId:'ScannerTypeInvalid' -ErrorCategory:'InvalidData' `
            -ExceptionName:'NotSupportedException' -ExceptionObject:$Null `
            -ExceptionMessage:($LocalizedData.ScannerTypeInvalid -f $Name, $Type)
        }
        Set-Variable -Name:'Payload' -Value:([PSCustomObject][ordered]@{})
      }
    }
    $ScannerModels.Add((ConvertTo-ScannerModel -Type:$Type -Payload:$Payload))
  }

  ForEach ($TriggerNode In @($ProfileNode.SelectNodes('ScheduleTriggerSet/Triggers/ScheduleTrigger'))) {
    $TriggerModels.Add([PSCustomObject][ordered]@{
        trigger_type                  = [System.String](Get-XmlScalar -Parent:$TriggerNode -Name:'TriggerType' -Kind:'String' -Profile:$Name)
        scan_age                      = [System.String](Get-XmlScalar -Parent:$TriggerNode -Name:'ScanAge' -Kind:'String' -Profile:$Name)
        is_enabled                    = Get-XmlScalar -Parent:$TriggerNode -Name:'IsEnabled' -Kind:'Boolean' -Profile:$Name
        start_date_time               = [System.String](Get-XmlScalar -Parent:$TriggerNode -Name:'StartDateTime' -Kind:'DateTime' -Profile:$Name)
        end_date_time                 = [System.String](Get-XmlScalar -Parent:$TriggerNode -Name:'EndDateTime' -Kind:'DateTime' -Profile:$Name)
        end_date_time_is_enabled      = Get-XmlScalar -Parent:$TriggerNode -Name:'EndDateTimeIsEnabled' -Kind:'Boolean' -Profile:$Name
        time_of_day_is_enabled        = Get-XmlScalar -Parent:$TriggerNode -Name:'TimeOfDayIsEnabled' -Kind:'Boolean' -Profile:$Name
        trigger_time_frame_is_enabled = Get-XmlScalar -Parent:$TriggerNode -Name:'TriggerTimeFrameIsEnabled' -Kind:'Boolean' -Profile:$Name
        enable_trigger_start_time     = [System.String](Get-XmlScalar -Parent:$TriggerNode -Name:'EnableTriggerStartTime' -Kind:'String' -Profile:$Name)
        enable_trigger_end_time       = [System.String](Get-XmlScalar -Parent:$TriggerNode -Name:'EnableTriggerEndTime' -Kind:'String' -Profile:$Name)
        description                   = [System.String](Get-XmlScalar -Parent:$TriggerNode -Name:'Description' -Kind:'String' -Profile:$Name)
      })
  }

  Set-Variable -Name:'Result' -Value:([PSCustomObject]@{
      text  = [System.String]$Text.TrimStart([System.Char]0xFEFF).TrimEnd()
      model = [PSCustomObject][ordered]@{
        name        = [System.String]$Name
        description = [System.String](Get-XmlScalar -Parent:$ProfileNode -Name:'Description' -Kind:'String' -Profile:$Name)
        scan_as     = [System.String](Get-XmlScalar -Parent:$ProfileNode -Name:'ScanAs' -Kind:'String' -Profile:$Name)
        triggers    = [System.Object[]]$TriggerModels.ToArray()
        scanners    = [System.Object[]]@(ConvertTo-SortedScannerModel -Scanner:$ScannerModels.ToArray())
      }
    })
  $Result
  Write-Debug -Message:'Exiting Function: ConvertFrom-Definition'
  Remove-Variable -Name:'Text', 'Document', 'ProfileNode', 'Name', 'ScannerModels',
    'TriggerModels', 'ScannerNode', 'TriggerNode', 'Type', 'Payload', 'ConfiguredNodeCount',
    'Result' -Force
}

Function Split-DatabaseRow {
  Param (
    [System.String] $Line,
    [System.Int32] $Count,
    [System.String] $Operation
  )
  Write-Debug -Message:'Entering Function: Split-DatabaseRow'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String[]]@())
  Set-Variable -Name:'Result' -Value:([System.String[]]$Line.Split('|'))
  If ($Result.Count -ne $Count) {
    ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' `
      -ExceptionName:'FormatException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.DatabaseRead -f $Operation, $Count, $Line)
  }
  $Result
  Write-Debug -Message:'Exiting Function: Split-DatabaseRow'
  Remove-Variable -Name:'Line', 'Count', 'Operation', 'Result' -Force
}

Function ConvertFrom-DatabaseInteger {
  Param (
    [System.String] $Value,
    [System.String] $Operation
  )
  Write-Debug -Message:'Entering Function: ConvertFrom-DatabaseInteger'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.Int32]0)
  If ($Value -notmatch '^-?[0-9]+$') {
    ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' `
      -ExceptionName:'FormatException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.DatabaseRead -f $Operation, 'integer', $Value)
  }
  Set-Variable -Name:'Result' -Value:([System.Int32]::Parse($Value))
  $Result
  Write-Debug -Message:'Exiting Function: ConvertFrom-DatabaseInteger'
  Remove-Variable -Name:'Value', 'Operation', 'Result' -Force
}

Function Get-DatabaseLocation {
  Param (
    [System.String] $Product,
    [System.String] $CommandPath
  )
  Write-Debug -Message:'Entering Function: Get-DatabaseLocation'
  New-Variable -Force -Option:'Private' -Name:'Info' -Value:([System.String[]]@())
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  Set-Variable -Name:'Info' -Value:([System.String[]](
      Invoke-NativeCommand -Operation:("Reading {0} system information" -f $Product) `
        -FilePath:$CommandPath -Argument:@('SystemInfo')
    ).Output)
  Set-Variable -Name:'Result' -Value:([System.String](
      @($Info | Where-Object -FilterScript { $PSItem -match '^\s*Database\s*:' }) |
        Select-Object -First 1
    ) -replace '^\s*Database\s*:\s*', '')
  If (-not $Result) {
    ThrowError -ErrorId:'SystemInfoMissing' -ErrorCategory:'InvalidData' `
      -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.SystemInfoMissing -f $Product)
  }
  If (-not (Test-Path -LiteralPath:$Result -PathType:'Leaf')) {
    ThrowError -ErrorId:'DatabaseMissing' -ErrorCategory:'ObjectNotFound' `
      -ExceptionName:'FileNotFoundException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.DatabaseMissing -f $Product, $Result)
  }
  $Result
  Write-Debug -Message:'Exiting Function: Get-DatabaseLocation'
  Remove-Variable -Name:'Product', 'CommandPath', 'Info', 'Result' -Force
}

Function Read-ProfileGraph {
  Param (
    [System.String] $DatabasePath,
    [System.String] $SqlitePath,
    [AllowEmptyString()]
    [System.String] $DeployDatabasePath
  )
  Write-Debug -Message:'Entering Function: Read-ProfileGraph'
  New-Variable -Force -Option:'Private' -Name:'Statement' -Value:(
    [System.Collections.Generic.List[System.String]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Rows' -Value:([System.String[]]@())
  New-Variable -Force -Option:'Private' -Name:'Part' -Value:([System.String[]]@())
  New-Variable -Force -Option:'Private' -Name:'Line' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'Id' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'ProfileId' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'ScannerId' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'TriggerSetId' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'Name' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'Type' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'PatternText' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'ProfileRow' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Scanner' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'ProfilesById' -Value:(
    [System.Collections.Generic.Dictionary[System.Int32, System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'ProfilesByName' -Value:(
    [System.Collections.Generic.Dictionary[System.String, System.Object]]::new(
      [System.StringComparer]::OrdinalIgnoreCase
    )
  )
  New-Variable -Force -Option:'Private' -Name:'ScannersById' -Value:(
    [System.Collections.Generic.Dictionary[System.Int32, System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'TriggerOwner' -Value:(
    [System.Collections.Generic.Dictionary[System.Int32, System.Int32]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'ScannerOwners' -Value:(
    [System.Collections.Generic.Dictionary[System.Int32, System.Collections.Generic.List[System.Int32]]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'TriggerSets' -Value:(
    [System.Collections.Generic.HashSet[System.Int32]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'TriggerRows' -Value:(
    [System.Collections.Generic.HashSet[System.Int32]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'TypedScannerIds' -Value:(
    [System.Collections.Generic.HashSet[System.Int32]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'ProfileRelations' -Value:([System.Collections.Hashtable]@{
      ScanProfileCollections = [System.Collections.Generic.HashSet[System.Int32]]::new()
      ScanProfileComputers   = [System.Collections.Generic.HashSet[System.Int32]]::new()
      ComputerScans          = [System.Collections.Generic.HashSet[System.Int32]]::new()
    })
  New-Variable -Force -Option:'Private' -Name:'ScannerRelations' -Value:([System.Collections.Hashtable]@{
      ScannerFiles           = [System.Collections.Generic.HashSet[System.Int32]]::new()
      ScannerRegistryEntries = [System.Collections.Generic.HashSet[System.Int32]]::new()
    })
  New-Variable -Force -Option:'Private' -Name:'ModelScanners' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Shared' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'OwnerId' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'Owner' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([PSCustomObject]$Null)

  If ($DeployDatabasePath.Length -gt 0) {
    $Statement.Add("ATTACH DATABASE $(ConvertTo-SqlText -Value:$DeployDatabasePath) AS DeployRead;")
  }
  $Statement.Add(
    "SELECT 'P', ScanProfileId, ScheduleTriggerSetId, hex(IFNULL(Name, '')), " +
    "hex(IFNULL(Description, '')), hex(IFNULL(ScanAs, '')), IFNULL(IsDefault, 0) " +
    'FROM ScanProfiles ORDER BY ScanProfileId;'
  )
  $Statement.Add("SELECT 'TS', ScheduleTriggerSetId FROM ScheduleTriggerSets ORDER BY ScheduleTriggerSetId;")
  $Statement.Add(
    "SELECT 'T', ScheduleTriggerSetId, IFNULL(Sequence, ''), hex(IFNULL(TriggerType, '')), " +
    "hex(IFNULL(ScanAge, '')), IFNULL(IsEnabled, ''), hex(IFNULL(StartDateTime, '')), " +
    "hex(IFNULL(EndDateTime, '')), IFNULL(EndDateTimeIsEnabled, ''), " +
    "IFNULL(TimeOfDayIsEnabled, ''), IFNULL(TriggerTimeFrameIsEnabled, ''), " +
    "hex(IFNULL(EnableTriggerStartTime, '')), hex(IFNULL(EnableTriggerEndTime, '')), " +
    "hex(IFNULL(Description, '')) FROM ScheduleTriggers " +
    'ORDER BY ScheduleTriggerSetId, Sequence, ScheduleTriggerId;'
  )
  $Statement.Add("SELECT 'S', ScannerId, hex(IFNULL(Name, '')) FROM Scanners ORDER BY ScannerId;")
  $Statement.Add(
    "SELECT 'PS', ScannerId, hex(IFNULL(Name, '')), hex(IFNULL(UID, '')), " +
    "hex(IFNULL(Script, '')), hex(IFNULL(FileName, '')), hex(IFNULL(Parameters, '')), " +
    "hex(IFNULL(AdditionalFiles, '')), IFNULL(RowLimit, '') FROM PowerShellScanners ORDER BY ScannerId;"
  )
  $Statement.Add(
    "SELECT 'W', ScannerId, hex(IFNULL(Name, '')), hex(IFNULL(WMIClassName, '')), " +
    "hex(IFNULL(Namespace, '')), hex(IFNULL(WQL, '')), IFNULL(Timeout, ''), " +
    "IFNULL(UsePreferencesTimeout, ''), IFNULL(RowLimit, '') FROM WMIScanners ORDER BY ScannerId;"
  )
  $Statement.Add(
    "SELECT 'F', ScannerId, hex(IFNULL(FileScanType, '')), hex(IFNULL(IncludePatterns, '')), " +
    "hex(IFNULL(ExcludePatterns, '')), IFNULL(RowLimit, '') FROM FileScanners ORDER BY ScannerId;"
  )
  $Statement.Add(
    "SELECT 'R', ScannerId, hex(IFNULL(Hive, '')), hex(IFNULL(IncludePattern, '')), " +
    "hex(IFNULL(ExcludePattern, '')), IFNULL(RowLimit, '') FROM RegistryScanners ORDER BY ScannerId;"
  )
  $Statement.Add(
    "SELECT 'J', ScanProfileId, ScannerId FROM ScanProfileScanner ORDER BY ScanProfileId, ScannerId;"
  )
  $Statement.Add(
    "SELECT 'C', p.ScanProfileId, count(c.ScanProfileId) FROM ScanProfiles p " +
    'LEFT JOIN ScanProfileCollections c ON c.ScanProfileId = p.ScanProfileId GROUP BY p.ScanProfileId;'
  )
  $Statement.Add("SELECT 'PC', ScanProfileId FROM ScanProfileComputers GROUP BY ScanProfileId;")
  $Statement.Add("SELECT 'CS', ScanProfileId FROM ComputerScans GROUP BY ScanProfileId;")
  $Statement.Add("SELECT 'SF', ScannerId FROM ScannerFiles GROUP BY ScannerId;")
  $Statement.Add("SELECT 'SR', ScannerId FROM ScannerRegistryEntries GROUP BY ScannerId;")
  $Statement.Add(
    "SELECT 'IR', ScanProfileId, 'CustomTools' FROM CustomTools WHERE ScanProfileId IS NOT NULL " +
    "UNION ALL SELECT 'IR', ScanProfileId, 'RemoteCommands' FROM RemoteCommands WHERE ScanProfileId IS NOT NULL " +
    "UNION ALL SELECT 'IR', ScanProfileId, 'RemoteCommandHistory' FROM RemoteCommandHistory " +
    'WHERE ScanProfileId IS NOT NULL;'
  )
  If ($DeployDatabasePath.Length -gt 0) {
    $Statement.Add(
      "SELECT 'DR', InventoryScanProfileId, 'Schedules' FROM DeployRead.Schedules WHERE InventoryScanProfileId IS NOT NULL " +
      "UNION ALL SELECT 'DR', InventoryScanProfileId, 'Deployments' FROM DeployRead.Deployments WHERE InventoryScanProfileId IS NOT NULL " +
      "UNION ALL SELECT 'DR', InventoryScanProfileId, 'ScanSteps' FROM DeployRead.ScanSteps WHERE InventoryScanProfileId IS NOT NULL " +
      "UNION ALL SELECT 'DR', InventoryScanProfileId, 'PackageDefinitions' FROM DeployRead.PackageDefinitions WHERE InventoryScanProfileId IS NOT NULL " +
      "UNION ALL SELECT 'DR', InventoryScanProfileId, 'InventoryScanProfiles' FROM DeployRead.InventoryScanProfiles " +
      'WHERE InventoryScanProfileId IS NOT NULL;'
    )
  }
  Set-Variable -Name:'Rows' -Value:([System.String[]]@(
      (Invoke-NativeCommand -Operation:'Reading the complete scan-profile graph' `
        -FilePath:$SqlitePath -Argument:@($DatabasePath, ($Statement -join ' '))).Output
    ))

  ForEach ($Line In $Rows) {
    Set-Variable -Name:'Part' -Value:([System.String[]]$Line.Split('|'))
    Switch ($Part[0]) {
      'P' {
        If ($Part.Count -ne 7) {
          ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' `
            -ExceptionName:'FormatException' -ExceptionObject:$Null `
            -ExceptionMessage:($LocalizedData.DatabaseRead -f 'scan profile', 7, $Line)
        }
        Set-Variable -Name:'ProfileId' -Value:([System.Int32](ConvertFrom-DatabaseInteger `
            -Value:$Part[1] -Operation:'profile id'))
        Set-Variable -Name:'TriggerSetId' -Value:([System.Int32](ConvertFrom-DatabaseInteger `
            -Value:$Part[2] -Operation:'trigger-set id'))
        Set-Variable -Name:'Name' -Value:([System.String](ConvertFrom-HexText `
            -Hex:$Part[3] -Operation:'profile name'))
        If ($ProfilesByName.ContainsKey($Name)) {
          ThrowError -ErrorId:'DatabaseDuplicate' -ErrorCategory:'InvalidData' `
            -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
            -ExceptionMessage:($LocalizedData.DatabaseDuplicate -f $Name)
        }
        Set-Variable -Name:'ProfileRow' -Value:([PSCustomObject]@{
            id               = [System.Int32]$ProfileId
            trigger_set_id   = [System.Int32]$TriggerSetId
            is_default       = [System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[6] -Operation:'default status')
            collection_count = [System.Int32]0
            scanner_ids      = [System.Collections.Generic.List[System.Int32]]::new()
            triggers         = [System.Collections.Generic.List[System.Object]]::new()
            inventory_refs   = [System.Collections.Generic.List[System.String]]::new()
            deploy_refs      = [System.Collections.Generic.List[System.String]]::new()
            shared           = [System.Collections.Generic.List[System.Object]]::new()
            model            = [PSCustomObject][ordered]@{
              name        = [System.String]$Name
              description = [System.String](ConvertFrom-HexText -Hex:$Part[4] -Operation:'profile description')
              scan_as     = [System.String](ConvertFrom-HexText -Hex:$Part[5] -Operation:'profile scan-as')
              triggers    = [System.Object[]]@()
              scanners    = [System.Object[]]@()
            }
          })
        $ProfilesById.Add($ProfileId, $ProfileRow)
        $ProfilesByName.Add($Name, $ProfileRow)
        $TriggerOwner.Add($TriggerSetId, $ProfileId)
      }
      'TS' {
        If ($Part.Count -ne 2) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'trigger set', 2, $Line) }
        $Null = $TriggerSets.Add((ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'trigger-set id'))
      }
      'T' {
        If ($Part.Count -ne 14) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'schedule trigger', 14, $Line) }
        Set-Variable -Name:'TriggerSetId' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'trigger-set id'))
        $Null = $TriggerRows.Add($TriggerSetId)
        If ($TriggerOwner.ContainsKey($TriggerSetId)) {
          Set-Variable -Name:'ProfileRow' -Value:([PSCustomObject]$ProfilesById[$TriggerOwner[$TriggerSetId]])
          $ProfileRow.triggers.Add([PSCustomObject]@{
              sequence = [System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[2] -Operation:'trigger sequence')
              value    = [PSCustomObject][ordered]@{
                trigger_type                  = [System.String](ConvertFrom-HexText -Hex:$Part[3] -Operation:'trigger type')
                scan_age                      = [System.String](ConvertFrom-HexText -Hex:$Part[4] -Operation:'scan age')
                is_enabled                    = If ($Part[5].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[5] -Operation:'trigger enabled' }
                start_date_time               = [System.String](ConvertTo-CanonicalDateTime -Value:(ConvertFrom-HexText -Hex:$Part[6] -Operation:'trigger start') -Field:'StartDateTime' -Profile:$ProfileRow.model.name)
                end_date_time                 = [System.String](ConvertTo-CanonicalDateTime -Value:(ConvertFrom-HexText -Hex:$Part[7] -Operation:'trigger end') -Field:'EndDateTime' -Profile:$ProfileRow.model.name)
                end_date_time_is_enabled      = If ($Part[8].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[8] -Operation:'trigger end enabled' }
                time_of_day_is_enabled        = If ($Part[9].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[9] -Operation:'trigger time-of-day enabled' }
                trigger_time_frame_is_enabled = If ($Part[10].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[10] -Operation:'trigger time-frame enabled' }
                enable_trigger_start_time     = [System.String](ConvertFrom-HexText -Hex:$Part[11] -Operation:'trigger frame start')
                enable_trigger_end_time       = [System.String](ConvertFrom-HexText -Hex:$Part[12] -Operation:'trigger frame end')
                description                   = [System.String](ConvertFrom-HexText -Hex:$Part[13] -Operation:'trigger description')
              }
            })
        }
      }
      'S' {
        If ($Part.Count -ne 3) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'scanner', 3, $Line) }
        Set-Variable -Name:'ScannerId' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'scanner id'))
        Set-Variable -Name:'Type' -Value:([System.String](ConvertFrom-HexText -Hex:$Part[2] -Operation:'scanner type'))
        $ScannersById.Add($ScannerId, [PSCustomObject]@{
            id    = [System.Int32]$ScannerId
            model = [PSCustomObject][ordered]@{ type = [System.String]$Type; payload = [PSCustomObject][ordered]@{} }
          })
        $ScannerOwners.Add($ScannerId, [System.Collections.Generic.List[System.Int32]]::new())
      }
      { $PSItem -in @('PS', 'W', 'F', 'R') } {
        Set-Variable -Name:'ScannerId' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'typed scanner id'))
        If (-not $ScannersById.ContainsKey($ScannerId)) {
          ThrowError -ErrorId:'ScannerSubtype' -ErrorCategory:'InvalidData' -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.ScannerSubtype -f $ScannerId, '(orphan)', $Part[0])
        }
        Set-Variable -Name:'Scanner' -Value:([PSCustomObject]$ScannersById[$ScannerId])
        $Null = $TypedScannerIds.Add($ScannerId)
        Switch ($Part[0]) {
          'PS' {
            If ($Part.Count -ne 9) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'PowerShell scanner', 9, $Line) }
            $Scanner.model.payload = [PSCustomObject][ordered]@{
              name             = [System.String](ConvertFrom-HexText -Hex:$Part[2] -Operation:'PowerShell name')
              uid              = [System.String](ConvertFrom-HexText -Hex:$Part[3] -Operation:'PowerShell UID')
              script           = [System.String](ConvertTo-CanonicalLineText -Value:(ConvertFrom-HexText -Hex:$Part[4] -Operation:'PowerShell script'))
              file_name        = [System.String](ConvertFrom-HexText -Hex:$Part[5] -Operation:'PowerShell file name')
              parameters       = [System.String](ConvertFrom-HexText -Hex:$Part[6] -Operation:'PowerShell parameters')
              additional_files = [System.String](ConvertFrom-HexText -Hex:$Part[7] -Operation:'PowerShell additional files')
              row_limit        = If ($Part[8].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[8] -Operation:'PowerShell row limit' }
            }
          }
          'W' {
            If ($Part.Count -ne 9) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'WMI scanner', 9, $Line) }
            $Scanner.model.payload = [PSCustomObject][ordered]@{
              name                    = [System.String](ConvertFrom-HexText -Hex:$Part[2] -Operation:'WMI name')
              wmi_class_name          = [System.String](ConvertFrom-HexText -Hex:$Part[3] -Operation:'WMI class')
              namespace               = [System.String](ConvertFrom-HexText -Hex:$Part[4] -Operation:'WMI namespace')
              wql                     = [System.String](ConvertFrom-HexText -Hex:$Part[5] -Operation:'WMI query')
              timeout                 = If ($Part[6].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[6] -Operation:'WMI timeout' }
              use_preferences_timeout = If ($Part[7].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[7] -Operation:'WMI preferences timeout' }
              row_limit               = If ($Part[8].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[8] -Operation:'WMI row limit' }
            }
          }
          'F' {
            If ($Part.Count -ne 6) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'Files scanner', 6, $Line) }
            Set-Variable -Name:'PatternText' -Value:([System.String](ConvertTo-CanonicalLineText -Value:(ConvertFrom-HexText -Hex:$Part[3] -Operation:'Files include patterns')))
            $Scanner.model.payload = [PSCustomObject][ordered]@{
              file_scan_type       = [System.String](ConvertFrom-HexText -Hex:$Part[2] -Operation:'Files scan type')
              include_pattern_text = [System.String]$PatternText
              exclude_pattern_text = [System.String](ConvertTo-CanonicalLineText -Value:(ConvertFrom-HexText -Hex:$Part[4] -Operation:'Files exclude patterns'))
              include_patterns     = [System.String[]]$(If ($PatternText.Length -eq 0) { @() } Else { @($PatternText.Split("`n")) })
              exclude_patterns     = [System.String[]]@(
                Set-Variable -Name:'PatternText' -Value:([System.String](ConvertTo-CanonicalLineText -Value:(ConvertFrom-HexText -Hex:$Part[4] -Operation:'Files exclude patterns')))
                If ($PatternText.Length -gt 0) { $PatternText.Split("`n") }
              )
              row_limit            = If ($Part[5].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[5] -Operation:'Files row limit' }
            }
          }
          'R' {
            If ($Part.Count -ne 6) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'Registry scanner', 6, $Line) }
            $Scanner.model.payload = [PSCustomObject][ordered]@{
              hive            = [System.String](ConvertFrom-HexText -Hex:$Part[2] -Operation:'Registry hive')
              include_pattern = [System.String](ConvertFrom-HexText -Hex:$Part[3] -Operation:'Registry include pattern')
              exclude_pattern = [System.String](ConvertFrom-HexText -Hex:$Part[4] -Operation:'Registry exclude pattern')
              row_limit       = If ($Part[5].Length -eq 0) { '' } Else { ConvertFrom-DatabaseInteger -Value:$Part[5] -Operation:'Registry row limit' }
            }
          }
        }
      }
      'J' {
        If ($Part.Count -ne 3) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'scanner membership', 3, $Line) }
        Set-Variable -Name:'ProfileId' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'profile id'))
        Set-Variable -Name:'ScannerId' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[2] -Operation:'scanner id'))
        If (-not $ProfilesById.ContainsKey($ProfileId) -or -not $ScannersById.ContainsKey($ScannerId)) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'scanner membership', 'owned', $Line) }
        $ProfilesById[$ProfileId].scanner_ids.Add($ScannerId)
        $ScannerOwners[$ScannerId].Add($ProfileId)
      }
      'C' {
        If ($Part.Count -ne 3) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'collection count', 3, $Line) }
        Set-Variable -Name:'ProfileId' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'profile id'))
        $ProfilesById[$ProfileId].collection_count = [System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[2] -Operation:'collection count')
        If ($ProfilesById[$ProfileId].collection_count -gt 0) { $Null = $ProfileRelations.ScanProfileCollections.Add($ProfileId) }
      }
      { $PSItem -in @('PC', 'CS', 'SF', 'SR') } {
        If ($Part.Count -ne 2) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'owned relation', 2, $Line) }
        Set-Variable -Name:'Id' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'owned relation id'))
        Switch ($Part[0]) {
          'PC' { $Null = $ProfileRelations.ScanProfileComputers.Add($Id) }
          'CS' { $Null = $ProfileRelations.ComputerScans.Add($Id) }
          'SF' { $Null = $ScannerRelations.ScannerFiles.Add($Id) }
          'SR' { $Null = $ScannerRelations.ScannerRegistryEntries.Add($Id) }
        }
      }
      { $PSItem -in @('IR', 'DR') } {
        If ($Part.Count -ne 3) { ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'profile reference', 3, $Line) }
        Set-Variable -Name:'ProfileId' -Value:([System.Int32](ConvertFrom-DatabaseInteger -Value:$Part[1] -Operation:'referenced profile id'))
        If ($ProfilesById.ContainsKey($ProfileId)) {
          If ($Part[0] -ceq 'IR') { $ProfilesById[$ProfileId].inventory_refs.Add($Part[2]) } Else { $ProfilesById[$ProfileId].deploy_refs.Add($Part[2]) }
        }
      }
      Default {
        ThrowError -ErrorId:'DatabaseRead' -ErrorCategory:'InvalidData' -ExceptionName:'FormatException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.DatabaseRead -f 'complete graph', 'known-tag', $Line)
      }
    }
  }

  ForEach ($ProfileRow In $ProfilesById.Values) {
    Set-Variable -Name:'ModelScanners' -Value:([System.Collections.Generic.List[System.Object]]::new())
    Set-Variable -Name:'Shared' -Value:([System.Collections.Generic.List[System.Object]]::new())
    ForEach ($ScannerId In $ProfileRow.scanner_ids) {
      Set-Variable -Name:'Scanner' -Value:([PSCustomObject]$ScannersById[$ScannerId])
      If ($Scanner.model.type -in @('PowerShell', 'WMI', 'Files', 'Registry') -and -not $TypedScannerIds.Contains($ScannerId)) {
        ThrowError -ErrorId:'ScannerSubtype' -ErrorCategory:'InvalidData' -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null -ExceptionMessage:($LocalizedData.ScannerSubtype -f $ScannerId, $ProfileRow.model.name, $Scanner.model.type)
      }
      $ModelScanners.Add($Scanner.model)
      ForEach ($OwnerId In $ScannerOwners[$ScannerId]) {
        If ($OwnerId -ne $ProfileRow.id) {
          Set-Variable -Name:'Owner' -Value:([PSCustomObject]$ProfilesById[$OwnerId])
          $Shared.Add([PSCustomObject]@{ type = [System.String]$Scanner.model.type; profile = [System.String]$Owner.model.name })
        }
      }
    }
    $ProfileRow.model.triggers = [System.Object[]]@($ProfileRow.triggers | Sort-Object -Property:'sequence' | ForEach-Object { $PSItem.value })
    $ProfileRow.model.scanners = [System.Object[]]@(ConvertTo-SortedScannerModel -Scanner:$ModelScanners.ToArray())
    $ProfileRow.shared = $Shared
  }
  Set-Variable -Name:'Result' -Value:([PSCustomObject]@{
      profiles_by_id   = $ProfilesById
      profiles_by_name = $ProfilesByName
      scanners_by_id   = $ScannersById
      trigger_sets     = $TriggerSets
      trigger_rows     = $TriggerRows
      typed_scanners   = $TypedScannerIds
      profile_relation = $ProfileRelations
      scanner_relation = $ScannerRelations
    })
  $Result
  Write-Debug -Message:'Exiting Function: Read-ProfileGraph'
  Remove-Variable -Name:'DatabasePath', 'SqlitePath', 'DeployDatabasePath', 'Statement', 'Rows',
    'Part', 'Line', 'Id', 'ProfileId', 'ScannerId', 'TriggerSetId', 'Name', 'Type',
    'PatternText', 'ProfileRow', 'Scanner', 'ProfilesById', 'ProfilesByName', 'ScannersById',
    'TriggerOwner', 'ScannerOwners', 'TriggerSets', 'TriggerRows', 'TypedScannerIds', 'ProfileRelations',
    'ScannerRelations', 'ModelScanners', 'Shared', 'OwnerId', 'Owner', 'Result' -Force
}

Function Assert-ProductListing {
  Param (
    [PSCustomObject] $Graph,
    [System.String] $CliPath
  )
  Write-Debug -Message:'Entering Function: Assert-ProductListing'
  New-Variable -Force -Option:'Private' -Name:'Listed' -Value:(
    [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::Ordinal)
  )
  New-Variable -Force -Option:'Private' -Name:'DatabaseNames' -Value:(
    [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::Ordinal)
  )
  New-Variable -Force -Option:'Private' -Name:'Line' -Value:([System.String]::Empty)
  New-Variable -Force -Option:'Private' -Name:'Difference' -Value:([System.String[]]@())
  ForEach ($Line In (Invoke-NativeCommand -Operation:'Listing the scan profiles' `
      -FilePath:$CliPath -Argument:@('GetAllScanProfiles')).Output) {
    If (-not [System.String]::IsNullOrWhiteSpace($Line)) {
      $Null = $Listed.Add($Line.Trim())
    }
  }
  ForEach ($Line In $Graph.profiles_by_name.Keys) {
    $Null = $DatabaseNames.Add($Line)
  }
  Set-Variable -Name:'Difference' -Value:([System.String[]]@(
      @($DatabaseNames | Where-Object { -not $Listed.Contains($PSItem) } |
          ForEach-Object { "table-only: $PSItem" }) +
      @($Listed | Where-Object { -not $DatabaseNames.Contains($PSItem) } |
          ForEach-Object { "listing-only: $PSItem" }) | Sort-Object
    ))
  If ($Difference.Count -gt 0) {
    ThrowError -ErrorId:'ProductDisagreement' -ErrorCategory:'InvalidData' `
      -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.ProductDisagreement -f ($Difference -join ', '))
  }
  Write-Debug -Message:'Exiting Function: Assert-ProductListing'
  Remove-Variable -Name:'Graph', 'CliPath', 'Listed', 'DatabaseNames', 'Line',
    'Difference' -Force
}

Function Get-ReconcileAction {
  Param (
    [System.Object[]] $Declaration,
    [PSCustomObject] $Graph,
    [System.String[]] $BuiltIn
  )
  Write-Debug -Message:'Entering Function: Get-ReconcileAction'
  New-Variable -Force -Option:'Private' -Name:'DeclaredSet' -Value:(
    [System.Collections.Generic.HashSet[System.String]]::new([System.StringComparer]::OrdinalIgnoreCase)
  )
  New-Variable -Force -Option:'Private' -Name:'BuiltInSet' -Value:(
    [System.Collections.Generic.HashSet[System.String]]::new(
      [System.String[]]$BuiltIn, [System.StringComparer]::OrdinalIgnoreCase
    )
  )
  New-Variable -Force -Option:'Private' -Name:'Create' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Update' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Keep' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Remove' -Value:(
    [System.Collections.Generic.List[System.Object]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Each' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Current' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([PSCustomObject]$Null)
  ForEach ($Each In $Declaration) {
    $Null = $DeclaredSet.Add($Each.model.name)
    If (-not $Graph.profiles_by_name.ContainsKey($Each.model.name)) {
      $Create.Add([PSCustomObject]@{ declaration = $Each; current = $Null })
    } Else {
      Set-Variable -Name:'Current' -Value:([PSCustomObject]$Graph.profiles_by_name[$Each.model.name])
      If ($Current.collection_count -ne 0 -or
        (ConvertTo-CanonicalProfile -Profile:$Current.model) -cne
        (ConvertTo-CanonicalProfile -Profile:$Each.model)) {
        $Update.Add([PSCustomObject]@{ declaration = $Each; current = $Current })
      } Else {
        $Keep.Add([PSCustomObject]@{ declaration = $Each; current = $Current })
      }
    }
  }
  ForEach ($Current In $Graph.profiles_by_id.Values) {
    If (-not $DeclaredSet.Contains($Current.model.name) -and
      -not $BuiltInSet.Contains($Current.model.name)) {
      $Remove.Add($Current)
    }
  }
  Set-Variable -Name:'Result' -Value:([PSCustomObject]@{
      create = [System.Object[]]$Create.ToArray()
      update = [System.Object[]]$Update.ToArray()
      keep   = [System.Object[]]$Keep.ToArray()
      remove = [System.Object[]]@($Remove.ToArray() | Sort-Object -Property:'id')
    })
  $Result
  Write-Debug -Message:'Exiting Function: Get-ReconcileAction'
  Remove-Variable -Name:'Declaration', 'Graph', 'BuiltIn', 'DeclaredSet', 'BuiltInSet',
    'Create', 'Update', 'Keep', 'Remove', 'Each', 'Current', 'Result' -Force
}

Function Assert-ReconcileRefusal {
  Param ([PSCustomObject] $Action)
  Write-Debug -Message:'Entering Function: Assert-ReconcileRefusal'
  New-Variable -Force -Option:'Private' -Name:'Entry' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'ProfileRow' -Value:([PSCustomObject]$Null)
  ForEach ($Entry In $Action.update) {
    If ($Entry.current.shared.Count -gt 0) {
      ThrowError -ErrorId:'SharedScanner' -ErrorCategory:'ResourceBusy' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.SharedScanner -f @(
            $Entry.current.model.name, $Entry.current.shared[0].type,
            $Entry.current.shared[0].profile
          ))
    }
  }
  ForEach ($ProfileRow In $Action.remove) {
    If ($ProfileRow.is_default -eq 1) {
      ThrowError -ErrorId:'DefaultProfile' -ErrorCategory:'PermissionDenied' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.DefaultProfile -f $ProfileRow.model.name)
    }
    If ($ProfileRow.inventory_refs.Count -gt 0) {
      ThrowError -ErrorId:'InventoryReference' -ErrorCategory:'ResourceBusy' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.InventoryReference -f @(
            $ProfileRow.model.name, $ProfileRow.inventory_refs[0]
          ))
    }
    If ($ProfileRow.deploy_refs.Count -gt 0) {
      ThrowError -ErrorId:'DeployReference' -ErrorCategory:'ResourceBusy' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.DeployReference -f @(
            $ProfileRow.model.name, $ProfileRow.deploy_refs[0]
          ))
    }
    If ($ProfileRow.shared.Count -gt 0) {
      ThrowError -ErrorId:'SharedScanner' -ErrorCategory:'ResourceBusy' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.SharedScanner -f @(
            $ProfileRow.model.name, $ProfileRow.shared[0].type, $ProfileRow.shared[0].profile
          ))
    }
  }
  Write-Debug -Message:'Exiting Function: Assert-ReconcileRefusal'
  Remove-Variable -Name:'Action', 'Entry', 'ProfileRow' -Force
}

Function ConvertTo-SqlScalar {
  Param ([AllowNull()] [System.Object] $Value)
  Write-Debug -Message:'Entering Function: ConvertTo-SqlScalar'
  New-Variable -Force -Option:'Private' -Name:'Result' -Value:([System.String]::Empty)
  If ($Value -is [System.Int16] -or $Value -is [System.Int32] -or $Value -is [System.Int64]) {
    Set-Variable -Name:'Result' -Value:([System.String]$Value)
  } Else {
    Set-Variable -Name:'Result' -Value:([System.String](ConvertTo-SqlText -Value:([System.String]$Value)))
  }
  $Result
  Write-Debug -Message:'Exiting Function: ConvertTo-SqlScalar'
  Remove-Variable -Name:'Value', 'Result' -Force
}

Function Add-ScannerInsert {
  Param (
    [System.Collections.Generic.List[System.String]] $Statement,
    [PSCustomObject] $Scanner
  )
  Write-Debug -Message:'Entering Function: Add-ScannerInsert'
  $Statement.Add("INSERT INTO Scanners (Name) VALUES ($(ConvertTo-SqlText -Value:$Scanner.type));")
  $Statement.Add('DELETE FROM CurrentScanner;')
  $Statement.Add('INSERT INTO CurrentScanner VALUES (last_insert_rowid());')
  Switch ($Scanner.type) {
    'PowerShell' {
      $Statement.Add(
        "INSERT INTO PowerShellScanners (ScannerId, Name, UID, Script, FileName, Parameters, AdditionalFiles, ModifiedDate, RowLimit) " +
        "SELECT Id, $(ConvertTo-SqlText -Value:$Scanner.payload.name), $(ConvertTo-SqlText -Value:$Scanner.payload.uid), " +
        "$(ConvertTo-SqlText -Value:$Scanner.payload.script), $(ConvertTo-SqlText -Value:$Scanner.payload.file_name), " +
        "$(ConvertTo-SqlText -Value:$Scanner.payload.parameters), $(ConvertTo-SqlText -Value:$Scanner.payload.additional_files), " +
        "datetime('now'), $(ConvertTo-SqlScalar -Value:$Scanner.payload.row_limit) FROM CurrentScanner;"
      )
    }
    'WMI' {
      $Statement.Add(
        "INSERT INTO WMIScanners (ScannerId, Name, Namespace, RowLimit, Timeout, WQL, UsePreferencesTimeout, ModifiedDate, WMIClassName) " +
        "SELECT Id, $(ConvertTo-SqlText -Value:$Scanner.payload.name), $(ConvertTo-SqlText -Value:$Scanner.payload.namespace), " +
        "$(ConvertTo-SqlScalar -Value:$Scanner.payload.row_limit), $(ConvertTo-SqlScalar -Value:$Scanner.payload.timeout), " +
        "$(ConvertTo-SqlText -Value:$Scanner.payload.wql), $(ConvertTo-SqlScalar -Value:$Scanner.payload.use_preferences_timeout), " +
        "datetime('now'), $(ConvertTo-SqlText -Value:$Scanner.payload.wmi_class_name) FROM CurrentScanner;"
      )
    }
    'Files' {
      $Statement.Add(
        "INSERT INTO FileScanners (ScannerId, DateCreated, DateModified, IncludePatterns, ExcludePatterns, RowLimit, FileScanType) " +
        "SELECT Id, datetime('now'), datetime('now'), " +
        "$(ConvertTo-SqlText -Value:([System.String]($Scanner.payload.include_patterns -join "`r`n"))), " +
        "$(ConvertTo-SqlText -Value:([System.String]($Scanner.payload.exclude_patterns -join "`r`n"))), " +
        "$(ConvertTo-SqlScalar -Value:$Scanner.payload.row_limit), " +
        "$(ConvertTo-SqlText -Value:$Scanner.payload.file_scan_type) FROM CurrentScanner;"
      )
    }
    'Registry' {
      $Statement.Add(
        "INSERT INTO RegistryScanners (ScannerId, Hive, IncludePattern, ExcludePattern, RowLimit) " +
        "SELECT Id, $(ConvertTo-SqlText -Value:$Scanner.payload.hive), " +
        "$(ConvertTo-SqlText -Value:$Scanner.payload.include_pattern), " +
        "$(ConvertTo-SqlText -Value:$Scanner.payload.exclude_pattern), " +
        "$(ConvertTo-SqlScalar -Value:$Scanner.payload.row_limit) FROM CurrentScanner;"
      )
    }
  }
  $Statement.Add('INSERT INTO ScanProfileScanner (ScanProfileId, ScannerId) SELECT p.Id, s.Id FROM CurrentProfile p, CurrentScanner s;')
  Write-Debug -Message:'Exiting Function: Add-ScannerInsert'
  Remove-Variable -Name:'Statement', 'Scanner' -Force
}

Function Add-TriggerInsert {
  Param (
    [System.Collections.Generic.List[System.String]] $Statement,
    [PSCustomObject] $Trigger,
    [System.Int32] $Sequence
  )
  Write-Debug -Message:'Entering Function: Add-TriggerInsert'
  $Statement.Add(
    "INSERT INTO ScheduleTriggers (ScheduleTriggerSetId, StartDateTime, EndDateTimeIsEnabled, EndDateTime, " +
    "IsEnabled, Description, Sequence, TriggerType, EnableTriggerStartTime, EnableTriggerEndTime, " +
    "TriggerTimeFrameIsEnabled, ScanAge, TimeOfDayIsEnabled) SELECT Id, " +
    "$(ConvertTo-SqlText -Value:$Trigger.start_date_time), $(ConvertTo-SqlScalar -Value:$Trigger.end_date_time_is_enabled), " +
    "$(ConvertTo-SqlText -Value:$Trigger.end_date_time), $(ConvertTo-SqlScalar -Value:$Trigger.is_enabled), " +
    "$(ConvertTo-SqlText -Value:$Trigger.description), $Sequence, $(ConvertTo-SqlText -Value:$Trigger.trigger_type), " +
    "$(ConvertTo-SqlText -Value:$Trigger.enable_trigger_start_time), $(ConvertTo-SqlText -Value:$Trigger.enable_trigger_end_time), " +
    "$(ConvertTo-SqlScalar -Value:$Trigger.trigger_time_frame_is_enabled), $(ConvertTo-SqlText -Value:$Trigger.scan_age), " +
    "$(ConvertTo-SqlScalar -Value:$Trigger.time_of_day_is_enabled) FROM CurrentTriggerSet;"
  )
  Write-Debug -Message:'Exiting Function: Add-TriggerInsert'
  Remove-Variable -Name:'Statement', 'Trigger', 'Sequence' -Force
}

Function Add-ProfileBody {
  Param (
    [System.Collections.Generic.List[System.String]] $Statement,
    [PSCustomObject] $Declaration
  )
  Write-Debug -Message:'Entering Function: Add-ProfileBody'
  New-Variable -Force -Option:'Private' -Name:'Scanner' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Trigger' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Sequence' -Value:([System.Int32]0)
  ForEach ($Trigger In $Declaration.triggers) {
    Add-TriggerInsert -Statement:$Statement -Trigger:$Trigger -Sequence:$Sequence
    Set-Variable -Name:'Sequence' -Value:([System.Int32]($Sequence + 1))
  }
  ForEach ($Scanner In $Declaration.scanners) {
    Add-ScannerInsert -Statement:$Statement -Scanner:$Scanner
  }
  Write-Debug -Message:'Exiting Function: Add-ProfileBody'
  Remove-Variable -Name:'Statement', 'Declaration', 'Scanner', 'Trigger', 'Sequence' -Force
}

Function Invoke-ReconcileTransaction {
  Param (
    [PSCustomObject] $Action,
    [System.String] $DatabasePath,
    [System.String] $SqlitePath,
    [AllowEmptyString()]
    [System.String] $DeployDatabasePath
  )
  Write-Debug -Message:'Entering Function: Invoke-ReconcileTransaction'
  New-Variable -Force -Option:'Private' -Name:'Statement' -Value:(
    [System.Collections.Generic.List[System.String]]::new()
  )
  New-Variable -Force -Option:'Private' -Name:'Entry' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'ProfileRow' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Declaration' -Value:([PSCustomObject]$Null)

  If ($DeployDatabasePath.Length -gt 0) {
    $Statement.Add("ATTACH DATABASE $(ConvertTo-SqlText -Value:$DeployDatabasePath) AS DeployGuard;")
  }
  $Statement.Add('PRAGMA busy_timeout = 5000;')
  $Statement.Add('BEGIN IMMEDIATE;')
  $Statement.Add('CREATE TEMP TABLE IdentityGuard (Value INTEGER CONSTRAINT IdentityGuard CHECK (Value = 0));')
  $Statement.Add('CREATE TEMP TABLE SharedScannerGuard (Value INTEGER CONSTRAINT SharedScannerGuard CHECK (Value = 0));')
  $Statement.Add('CREATE TEMP TABLE DefaultProfileGuard (Value INTEGER CONSTRAINT DefaultProfileGuard CHECK (Value = 0));')
  $Statement.Add('CREATE TEMP TABLE InventoryReferenceGuard (Value INTEGER CONSTRAINT InventoryReferenceGuard CHECK (Value = 0));')
  $Statement.Add('CREATE TEMP TABLE DeployReferenceGuard (Value INTEGER CONSTRAINT DeployReferenceGuard CHECK (Value = 0));')
  $Statement.Add('CREATE TEMP TABLE CurrentProfile (Id INTEGER);')
  $Statement.Add('CREATE TEMP TABLE CurrentTriggerSet (Id INTEGER);')
  $Statement.Add('CREATE TEMP TABLE CurrentScanner (Id INTEGER);')
  $Statement.Add('CREATE TEMP TABLE DoomedScanner (Id INTEGER PRIMARY KEY);')

  # Every refusal is restated before the first product row is mutated. The earlier checks name a
  # refusal clearly; these constraints close the race between the read and this write lock.
  ForEach ($Entry In $Action.create) {
    Set-Variable -Name:'Declaration' -Value:([PSCustomObject]$Entry.declaration.model)
    $Statement.Add(
      "INSERT INTO IdentityGuard SELECT count(*) FROM ScanProfiles WHERE Name = " +
      "$(ConvertTo-SqlText -Value:$Declaration.name) COLLATE NOCASE;"
    )
  }
  ForEach ($Entry In $Action.update) {
    Set-Variable -Name:'ProfileRow' -Value:([PSCustomObject]$Entry.current)
    $Statement.Add(
      "INSERT INTO IdentityGuard SELECT CASE WHEN count(*) = 1 THEN 0 ELSE 1 END FROM ScanProfiles " +
      "WHERE ScanProfileId = $($ProfileRow.id) AND ScheduleTriggerSetId = $($ProfileRow.trigger_set_id) " +
      "AND Name = $(ConvertTo-SqlText -Value:$ProfileRow.model.name);"
    )
    $Statement.Add(
      "INSERT INTO SharedScannerGuard SELECT count(*) FROM ScanProfileScanner own " +
      "JOIN ScanProfileScanner other ON other.ScannerId = own.ScannerId " +
      "AND other.ScanProfileId <> own.ScanProfileId WHERE own.ScanProfileId = $($ProfileRow.id);"
    )
  }
  ForEach ($ProfileRow In $Action.remove) {
    $Statement.Add(
      "INSERT INTO IdentityGuard SELECT CASE WHEN count(*) = 1 THEN 0 ELSE 1 END FROM ScanProfiles " +
      "WHERE ScanProfileId = $($ProfileRow.id) AND ScheduleTriggerSetId = $($ProfileRow.trigger_set_id) " +
      "AND Name = $(ConvertTo-SqlText -Value:$ProfileRow.model.name);"
    )
    $Statement.Add(
      "INSERT INTO DefaultProfileGuard SELECT count(*) FROM ScanProfiles " +
      "WHERE ScanProfileId = $($ProfileRow.id) AND IFNULL(IsDefault, 0) = 1;"
    )
    $Statement.Add(
      "INSERT INTO SharedScannerGuard SELECT count(*) FROM ScanProfileScanner own " +
      "JOIN ScanProfileScanner other ON other.ScannerId = own.ScannerId " +
      "AND other.ScanProfileId <> own.ScanProfileId WHERE own.ScanProfileId = $($ProfileRow.id);"
    )
    $Statement.Add(
      "INSERT INTO InventoryReferenceGuard SELECT " +
      "(SELECT count(*) FROM CustomTools WHERE ScanProfileId = $($ProfileRow.id)) + " +
      "(SELECT count(*) FROM RemoteCommands WHERE ScanProfileId = $($ProfileRow.id)) + " +
      "(SELECT count(*) FROM RemoteCommandHistory WHERE ScanProfileId = $($ProfileRow.id));"
    )
    If ($DeployDatabasePath.Length -gt 0) {
      $Statement.Add(
        "INSERT INTO DeployReferenceGuard SELECT " +
        "(SELECT count(*) FROM DeployGuard.Schedules WHERE InventoryScanProfileId = $($ProfileRow.id)) + " +
        "(SELECT count(*) FROM DeployGuard.Deployments WHERE InventoryScanProfileId = $($ProfileRow.id)) + " +
        "(SELECT count(*) FROM DeployGuard.ScanSteps WHERE InventoryScanProfileId = $($ProfileRow.id)) + " +
        "(SELECT count(*) FROM DeployGuard.PackageDefinitions WHERE InventoryScanProfileId = $($ProfileRow.id)) + " +
        "(SELECT count(*) FROM DeployGuard.InventoryScanProfiles WHERE InventoryScanProfileId = $($ProfileRow.id));"
      )
    }
  }

  ForEach ($Entry In $Action.create) {
    Set-Variable -Name:'Declaration' -Value:([PSCustomObject]$Entry.declaration.model)
    $Statement.Add('DELETE FROM CurrentProfile;')
    $Statement.Add('DELETE FROM CurrentTriggerSet;')
    $Statement.Add('INSERT INTO ScheduleTriggerSets DEFAULT VALUES;')
    $Statement.Add('INSERT INTO CurrentTriggerSet VALUES (last_insert_rowid());')
    $Statement.Add(
      "INSERT INTO ScanProfiles (ScheduleTriggerSetId, Name, Description, IsDefault, ScanAs) " +
      "SELECT Id, $(ConvertTo-SqlText -Value:$Declaration.name), " +
      "$(ConvertTo-SqlText -Value:$Declaration.description), 0, " +
      "$(ConvertTo-SqlText -Value:$Declaration.scan_as) FROM CurrentTriggerSet;"
    )
    $Statement.Add('INSERT INTO CurrentProfile VALUES (last_insert_rowid());')
    Add-ProfileBody -Statement:$Statement -Declaration:$Declaration
  }
  ForEach ($Entry In $Action.update) {
    Set-Variable -Name:'ProfileRow' -Value:([PSCustomObject]$Entry.current)
    Set-Variable -Name:'Declaration' -Value:([PSCustomObject]$Entry.declaration.model)
    $Statement.Add('DELETE FROM CurrentProfile;')
    $Statement.Add('DELETE FROM CurrentTriggerSet;')
    $Statement.Add('DELETE FROM DoomedScanner;')
    $Statement.Add("INSERT INTO CurrentProfile VALUES ($($ProfileRow.id));")
    $Statement.Add("INSERT INTO CurrentTriggerSet VALUES ($($ProfileRow.trigger_set_id));")
    $Statement.Add("INSERT INTO DoomedScanner SELECT ScannerId FROM ScanProfileScanner WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add("DELETE FROM ScanProfileCollections WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add('DELETE FROM PowerShellScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM WMIScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM FileScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM RegistryScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM ScannerFiles WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM ScannerRegistryEntries WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add("DELETE FROM ScanProfileScanner WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add('DELETE FROM Scanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add("DELETE FROM ScheduleTriggers WHERE ScheduleTriggerSetId = $($ProfileRow.trigger_set_id);")
    $Statement.Add(
      "UPDATE ScanProfiles SET Name = $(ConvertTo-SqlText -Value:$Declaration.name), " +
      "Description = $(ConvertTo-SqlText -Value:$Declaration.description), " +
      "ScanAs = $(ConvertTo-SqlText -Value:$Declaration.scan_as) " +
      "WHERE ScanProfileId = $($ProfileRow.id) AND Name = $(ConvertTo-SqlText -Value:$ProfileRow.model.name);"
    )
    Add-ProfileBody -Statement:$Statement -Declaration:$Declaration
  }

  # Removals are last, after every creation and update that was decided from the same pre-state.
  ForEach ($ProfileRow In $Action.remove) {
    $Statement.Add('DELETE FROM DoomedScanner;')
    $Statement.Add("INSERT INTO DoomedScanner SELECT ScannerId FROM ScanProfileScanner WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add("DELETE FROM ScanProfileCollections WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add("DELETE FROM ScanProfileComputers WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add("DELETE FROM ComputerScans WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add('DELETE FROM PowerShellScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM WMIScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM FileScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM RegistryScanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM ScannerFiles WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add('DELETE FROM ScannerRegistryEntries WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add("DELETE FROM ScanProfileScanner WHERE ScanProfileId = $($ProfileRow.id);")
    $Statement.Add('DELETE FROM Scanners WHERE ScannerId IN (SELECT Id FROM DoomedScanner);')
    $Statement.Add("DELETE FROM ScheduleTriggers WHERE ScheduleTriggerSetId = $($ProfileRow.trigger_set_id);")
    $Statement.Add("DELETE FROM ScheduleTriggerSets WHERE ScheduleTriggerSetId = $($ProfileRow.trigger_set_id);")
    $Statement.Add(
      "DELETE FROM ScanProfiles WHERE ScanProfileId = $($ProfileRow.id) " +
      "AND Name = $(ConvertTo-SqlText -Value:$ProfileRow.model.name);"
    )
  }
  $Statement.Add('COMMIT;')
  $Null = Invoke-NativeCommand -Operation:'Reconciling the scan profiles' -FilePath:$SqlitePath `
    -Argument:@($DatabasePath, ($Statement -join ' '))
  Write-Debug -Message:'Exiting Function: Invoke-ReconcileTransaction'
  Remove-Variable -Name:'Action', 'DatabasePath', 'SqlitePath', 'DeployDatabasePath',
    'Statement', 'Entry', 'ProfileRow', 'Declaration' -Force
}

Function Assert-CommittedState {
  Param (
    [System.Object[]] $Declaration,
    [PSCustomObject[]] $Removed,
    [PSCustomObject] $Graph
  )
  Write-Debug -Message:'Entering Function: Assert-CommittedState'
  New-Variable -Force -Option:'Private' -Name:'Each' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'Current' -Value:([PSCustomObject]$Null)
  New-Variable -Force -Option:'Private' -Name:'ScannerId' -Value:([System.Int32]0)
  New-Variable -Force -Option:'Private' -Name:'Left' -Value:(
    [System.Collections.Generic.List[System.String]]::new()
  )
  ForEach ($Each In $Declaration) {
    If (-not $Graph.profiles_by_name.ContainsKey($Each.model.name)) {
      ThrowError -ErrorId:'ApplyFailed' -ErrorCategory:'InvalidResult' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.ApplyFailed -f $Each.model.name)
    }
    Set-Variable -Name:'Current' -Value:([PSCustomObject]$Graph.profiles_by_name[$Each.model.name])
    If ($Current.collection_count -ne 0 -or
      (ConvertTo-CanonicalProfile -Profile:$Current.model) -cne
      (ConvertTo-CanonicalProfile -Profile:$Each.model)) {
      ThrowError -ErrorId:'ApplyFailed' -ErrorCategory:'InvalidResult' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.ApplyFailed -f $Each.model.name)
    }
  }
  ForEach ($Each In $Removed) {
    $Left.Clear()
    If ($Graph.profiles_by_id.ContainsKey($Each.id)) { $Left.Add('ScanProfiles') }
    If ($Graph.trigger_sets.Contains($Each.trigger_set_id)) { $Left.Add('ScheduleTriggerSets') }
    If ($Graph.trigger_rows.Contains($Each.trigger_set_id)) { $Left.Add('ScheduleTriggers') }
    If ($Graph.profile_relation.ScanProfileCollections.Contains($Each.id)) { $Left.Add('ScanProfileCollections') }
    If ($Graph.profile_relation.ScanProfileComputers.Contains($Each.id)) { $Left.Add('ScanProfileComputers') }
    If ($Graph.profile_relation.ComputerScans.Contains($Each.id)) { $Left.Add('ComputerScans') }
    ForEach ($ScannerId In $Each.scanner_ids) {
      If ($Graph.scanners_by_id.ContainsKey($ScannerId)) { $Left.Add('Scanners') }
      If ($Graph.typed_scanners.Contains($ScannerId)) { $Left.Add('typed scanner table') }
      If ($Graph.scanner_relation.ScannerFiles.Contains($ScannerId)) { $Left.Add('ScannerFiles') }
      If ($Graph.scanner_relation.ScannerRegistryEntries.Contains($ScannerId)) { $Left.Add('ScannerRegistryEntries') }
    }
    If ($Left.Count -gt 0) {
      ThrowError -ErrorId:'RemovalFailed' -ErrorCategory:'InvalidResult' `
        -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
        -ExceptionMessage:($LocalizedData.RemovalFailed -f @(
            $Each.model.name, (@($Left | Sort-Object -Unique) -join ', ')
          ))
    }
  }
  Write-Debug -Message:'Exiting Function: Assert-CommittedState'
  Remove-Variable -Name:'Declaration', 'Removed', 'Graph', 'Each', 'Current',
    'ScannerId', 'Left' -Force
}

#endregion --- [ Functions ] ----------------------------------------------------------------- #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

If (-not (Test-Path -LiteralPath:$CliPath -PathType:'Leaf')) {
  ThrowError -ErrorId:'CliMissing' -ErrorCategory:'ObjectNotFound' `
    -ExceptionName:'FileNotFoundException' -ExceptionObject:$Null `
    -ExceptionMessage:($LocalizedData.CliMissing -f $CliPath)
}
$SqlitePath = Join-Path -Path:(Split-Path -Path:$CliPath -Parent) -ChildPath:'sqlite3.exe'
If (-not (Test-Path -LiteralPath:$SqlitePath -PathType:'Leaf')) {
  ThrowError -ErrorId:'SqliteMissing' -ErrorCategory:'ObjectNotFound' `
    -ExceptionName:'FileNotFoundException' -ExceptionObject:$Null `
    -ExceptionMessage:($LocalizedData.SqliteMissing -f $SqlitePath)
}
If ($DeployCliPath.Length -gt 0 -and
  -not (Test-Path -LiteralPath:$DeployCliPath -PathType:'Leaf')) {
  ThrowError -ErrorId:'DeployCliMissing' -ErrorCategory:'ObjectNotFound' `
    -ExceptionName:'FileNotFoundException' -ExceptionObject:$Null `
    -ExceptionMessage:($LocalizedData.DeployCliMissing -f $DeployCliPath)
}

# Definitions are parsed completely before any product state is read or any transaction begins.
$Declarations = [System.Collections.Generic.List[System.Object]]::new()
$DeclaredNames = [System.Collections.Generic.HashSet[System.String]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
ForEach ($Text In $Definition) {
  $Declaration = ConvertFrom-Definition -Text:$Text
  If (-not $DeclaredNames.Add($Declaration.model.name)) {
    ThrowError -ErrorId:'DefinitionDuplicate' -ErrorCategory:'InvalidData' `
      -ExceptionName:'InvalidOperationException' -ExceptionObject:$Null `
      -ExceptionMessage:($LocalizedData.DefinitionDuplicate -f $Declaration.model.name)
  }
  $Declarations.Add($Declaration)
}

$DatabasePath = Get-DatabaseLocation -Product:'Inventory' -CommandPath:$CliPath
$DeployDatabasePath = [System.String]::Empty
If ($DeployCliPath.Length -gt 0) {
  $DeployDatabasePath = Get-DatabaseLocation -Product:'Deploy' -CommandPath:$DeployCliPath
}
$Graph = Read-ProfileGraph -DatabasePath:$DatabasePath -SqlitePath:$SqlitePath `
  -DeployDatabasePath:$DeployDatabasePath
Assert-ProductListing -Graph:$Graph -CliPath:$CliPath

# The complete action set is fixed before the write lock. Refusals are named from this read and
# then restated inside the transaction before the first product row is mutated.
$Action = Get-ReconcileAction -Declaration:$Declarations.ToArray() -Graph:$Graph -BuiltIn:$BuiltIn
Assert-ReconcileRefusal -Action:$Action
$Changed = [System.Boolean](
  $Action.create.Count + $Action.update.Count + $Action.remove.Count -gt 0
)

If (-not $Ansible.CheckMode) {
  Invoke-ReconcileTransaction -Action:$Action -DatabasePath:$DatabasePath `
    -SqlitePath:$SqlitePath -DeployDatabasePath:$DeployDatabasePath
  $CommittedGraph = Read-ProfileGraph -DatabasePath:$DatabasePath -SqlitePath:$SqlitePath `
    -DeployDatabasePath:$DeployDatabasePath
  Assert-ProductListing -Graph:$CommittedGraph -CliPath:$CliPath
  Assert-CommittedState -Declaration:$Declarations.ToArray() `
    -Removed:$Action.remove -Graph:$CommittedGraph
}

# Nothing is reported as successful until the commit and its independent read-back have both
# succeeded. Check mode reports the same action set without opening a write transaction.
$Recap = [System.Collections.Generic.List[System.String]]::new()
ForEach ($Entry In $Action.keep) {
  $Recap.Add(('{0}: already correct' -f $Entry.declaration.model.name))
}
ForEach ($Entry In $Action.create) {
  $ScannerTypes = [System.String[]]@(
    $Entry.declaration.model.scanners | ForEach-Object { $PSItem.type } | Sort-Object -Unique
  )
  $Recap.Add(('{0}: {1}; scanner types: {2}' -f @(
        $Entry.declaration.model.name,
        $(If ($Ansible.CheckMode) { 'would be created' } Else { 'created' }),
        $(If ($ScannerTypes.Count -eq 0) { '(none)' } Else { $ScannerTypes -join ', ' })
      )))
}
ForEach ($Entry In $Action.update) {
  $ScannerTypes = [System.String[]]@(
    @($Entry.current.model.scanners | ForEach-Object { $PSItem.type }) +
    @($Entry.declaration.model.scanners | ForEach-Object { $PSItem.type }) |
      Sort-Object -Unique
  )
  $Recap.Add(('{0}: {1}; scanner rows replaced and gathered data removed: {2}' -f @(
        $Entry.declaration.model.name,
        $(If ($Ansible.CheckMode) { 'would be applied' } Else { 'applied' }),
        $(If ($ScannerTypes.Count -eq 0) { '(none)' } Else { $ScannerTypes -join ', ' })
      )))
}
ForEach ($ProfileRow In $Action.remove) {
  $ScannerTypes = [System.String[]]@(
    $ProfileRow.model.scanners | ForEach-Object { $PSItem.type } | Sort-Object -Unique
  )
  $Recap.Add(('{0}: {1} with gathered data; scanner types: {2}' -f @(
        $ProfileRow.model.name,
        $(If ($Ansible.CheckMode) { 'would be removed' } Else { 'removed' }),
        $(If ($ScannerTypes.Count -eq 0) { '(none)' } Else { $ScannerTypes -join ', ' })
      )))
}
If ($Action.remove.Count -eq 0) {
  $Recap.Add('No undeclared scan profiles')
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  ignored    = [System.Boolean]$False
  msg        = If ($Changed) {
    '{0} creation(s), {1} update(s), and {2} removal(s) required' -f @(
      $Action.create.Count, $Action.update.Count, $Action.remove.Count
    )
  } Else {
    'Every scan profile is already reconciled'
  }
  recap      = [System.String[]]$Recap.ToArray()
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:6
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
