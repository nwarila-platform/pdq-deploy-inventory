#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Applies a set of PDQ settings in one pass and proves each one took.

    .DESCRIPTION
        PDQ keeps its settings behind a command line that writes them one at a time, and a
        key-value store that accepts ANY name whether the product reads it or not. Setting a name
        the product does not read reports success, inserts a row, and changes nothing -- measured
        2026-08-20 with RepositorySettings.Path, which the product reads from a system variable
        instead. A caller that trusts the exit code cannot tell the difference.

        This script closes that gap by treating the product's own export as the only account of
        what is configured. It exports once to learn the current values, writes only the settings
        that differ, exports again, and verifies every requested setting now reads back as asked.
        A setting that did not take is reported as ignored and fails the run rather than being
        counted as applied.

        Doing it here rather than task-by-task also collapses one round trip per setting into two
        exports and N writes, which matters when a deployment declares dozens.

        The product can only export to a FILE -- there is no stdout or in-memory form -- so each
        export is read into memory and deleted immediately, leaving it on disk for the write plus
        one read. Nothing secret is in it: the export carries user names for mail, proxy and
        integrations, and no password, token or secret element of any kind.

        WHAT IS SETTABLE, and how, is the SETTINGS table below rather than a parameter apiece.
        The table is the whole contract: which names exist, what type each takes, which values an
        enumerated one allows, and which of them lives in the product's database instead of on
        its command line. Declaring the surface as data rather than as sixty-odd parameter
        attributes keeps the file readable in one pass and small enough for the transport to log,
        and the caller's experience is unchanged -- it passes the same map of names to values
        either way.

        Only the families the product's SERVICE reads are offered. The console-side pages --
        alerts, interface, printing, log verbosity, target filters -- live in a per-user registry
        hive that no converge can reach, so a name for them here would be a promise the product
        does not keep.

        Org scripts are a single straightforward process stage in the org script template's
        architecture: one [ Script ] region carrying [ Initialization ] (strict mode, transport
        detection, input normalization), [ Main ] (read -> act -> verify -> build ONE result
        object), and [ Output ] (the same object to $Ansible or as JSON).

        Shipped by the org three-file convention: developed under scripts/ with its sibling
        Set-PdqSetting.pester.ps1 spec, while the pdq_deploy role carries
        files/Set-PdqSetting.ps1.stub, which the build resolves by dropping this file into the
        role.

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

    .PARAMETER Setting
        The settings to apply, as a map of NAME to desired value, where every name is one of the
        Param entries in the SETTINGS table. A name absent from the map is not managed -- which
        is a different thing from one set to the product's default -- so a deployment states only
        what it means to own. A name the table does not carry is a typo and fails the run: it
        would otherwise be a silent no-op that looks like success.

        Values keep the types the caller supplied. Ansible's win_powershell passes this map
        through as a Hashtable with numbers, strings and booleans intact (measured 2026-08-20),
        so a setting typed Int32 in the table is checked against an actual integer rather than a
        re-parsed string.

    .EXAMPLE
        .\Set-PdqSetting.ps1 -Setting @{ DeploymentCleanupDays = 45; PerformanceCopyMode = 'Pull' }

    .OUTPUTS
        One object carrying applied, unchanged, ignored, changed and msg.
#>

[CmdletBinding()]
[OutputType([System.Void])]
Param (
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String] $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String] $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [System.Collections.IDictionary] $Setting
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# The product's command line, its sqlite tool, and where its export is staged. All fixed, not
# offered: the installer ignores every documented way to relocate the product -- INSTALLLOCATION,
# APPLICATIONFOLDER and /p were each measured accepted and ignored on 2026-08-18 -- so a path
# parameter would advertise a choice that does not exist.
New-Variable -Force -Name:'CLI_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
)
New-Variable -Force -Name:'SQLITE_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
)
New-Variable -Force -Name:'EXPORT_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Windows\Temp\pdq-settings-export.xml'
)

# The settable surface, as data. Param is the name a caller uses; Name is the product's own,
# which the export publishes as an element and its parent joined by a dot. Type is checked
# against what the caller actually passed. Allowed, where present, is the complete set of legal
# values. Variable marks the settings the command line cannot reach at all: those are system
# VARIABLES, and the product's variable commands carry CUSTOM ones only, so they are written
# into its database instead -- honoured with the service running and effective at once (measured
# 2026-08-20). Names flagged inferred were derived from the export's shape rather than proven by
# writing one; the verification pass is what decides, so a wrong guess fails loudly instead of
# passing quietly.
New-Variable -Force -Name:'SETTINGS' -Option:('Private', 'ReadOnly') -Value:(
  [System.Collections.Hashtable[]]@(
    @{ Param = 'PackageLibraryAutoDeployDefaultApprovalMode'           ; Name = 'AutoDeployDefaultSettings.ApprovalMode'              ; Type = 'String' }
    @{ Param = 'PackageLibraryAutoDeployDefaultDelayedApprovalTimeSpan'; Name = 'AutoDeployDefaultSettings.DelayedApprovalTimeSpan'   ; Type = 'String' }   # inferred
    @{ Param = 'PackageLibraryAutoDeployDefaultIsEnabled'              ; Name = 'AutoDeployDefaultSettings.IsEnabled'                 ; Type = 'Boolean' }   # inferred
    @{ Param = 'PackageLibraryAutoDownloadArchiveCopiesToKeep'         ; Name = 'AutoDownloadArchiveSettings.CopiesToKeep'            ; Type = 'Int32' }
    @{ Param = 'PackageLibraryAutoDownloadArchiveIsArchiving'          ; Name = 'AutoDownloadArchiveSettings.IsArchiving'             ; Type = 'Boolean' }   # inferred
    @{ Param = 'DatabaseDatabaseBackupBackupDirectory'                 ; Name = 'DatabaseBackupSettings.BackupDirectory'              ; Type = 'String' }
    @{ Param = 'DatabaseDatabaseBackupCompress'                        ; Name = 'DatabaseBackupSettings.Compress'                     ; Type = 'Boolean' }   # inferred
    @{ Param = 'DatabaseDatabaseBackupIsEnabled'                       ; Name = 'DatabaseBackupSettings.IsEnabled'                    ; Type = 'Boolean' }   # inferred
    @{ Param = 'DatabaseDatabaseBackupKeep'                            ; Name = 'DatabaseBackupSettings.Keep'                         ; Type = 'Int32' }
    @{ Param = 'DeploymentCleanupDays'                                 ; Name = 'DeploymentSettings.CleanupDays'                      ; Type = 'Int32' }
    @{ Param = 'DeploymentComputerTimeout'                             ; Name = 'DeploymentSettings.ComputerTimeout'                  ; Type = 'Int32' }
    @{ Param = 'DeploymentInventoryScanProfileId'                      ; Name = 'DeploymentSettings.InventoryScanProfileId'           ; Type = 'String' }   # inferred
    @{ Param = 'DeploymentRunAs'                                       ; Name = 'DeploymentSettings.RunAs'                            ; Type = 'String' }   # inferred
    @{ Param = 'DeploymentScanAfterDeployment'                         ; Name = 'DeploymentSettings.ScanAfterDeployment'              ; Type = 'Boolean' }   # inferred
    @{ Param = 'DeploymentOfflineRetryMaxTries'                        ; Name = 'OfflineSettings.RetryMaxTries'                       ; Type = 'Int32' }
    @{ Param = 'DeploymentOfflineUsePing'                              ; Name = 'OfflineSettings.UsePing'                             ; Type = 'Boolean' }   # inferred
    @{ Param = 'DeploymentOfflineTryWol'                               ; Name = 'OfflineSettings.TryWol'                              ; Type = 'Boolean' }   # inferred
    @{ Param = 'DeploymentOfflineIsRetryEnabled'                       ; Name = 'OfflineSettings.IsRetryEnabled'                      ; Type = 'Boolean' }   # inferred
    @{ Param = 'DeploymentOfflineRetryInterval'                        ; Name = 'OfflineSettings.RetryInterval'                       ; Type = 'String' }   # inferred
    @{ Param = 'LoggingSentryCanSendAnonymousExceptionData'            ; Name = 'SentrySettings.CanSendAnonymousExceptionData'        ; Type = 'Boolean' }   # inferred
    @{ Param = 'LoggingAuditLogMinDaysRecordsKept'                     ; Name = 'AuditLogSettings.MinDaysRecordsKept'                 ; Type = 'Int32' }   # inferred
    @{ Param = 'LoggingAuditLogMaxDaysRecordsKept'                     ; Name = 'AuditLogSettings.MaxDaysRecordsKept'                 ; Type = 'Int32' }   # inferred
    @{ Param = 'LoggingAuditLogMinNumArchivedFiles'                    ; Name = 'AuditLogSettings.MinNumArchivedFiles'                ; Type = 'Int32' }   # inferred
    @{ Param = 'LoggingAuditLogMaxNumArchivedFiles'                    ; Name = 'AuditLogSettings.MaxNumArchivedFiles'                ; Type = 'Int32' }   # inferred
    @{ Param = 'LoggingAuditLogVerboseFileName'                        ; Name = 'AuditLogSettings.VerboseFileName'                    ; Type = 'String' }   # inferred
    @{ Param = 'LoggingAuditLogDaysRecordsKept'                        ; Name = 'AuditLogSettings.DaysRecordsKept'                    ; Type = 'Int32' }
    @{ Param = 'LoggingAuditLogWriteVerboseFile'                       ; Name = 'AuditLogSettings.WriteVerboseFile'                   ; Type = 'Boolean' }   # inferred
    @{ Param = 'LoggingAuditLogLoadCustomConfig'                       ; Name = 'AuditLogSettings.LoadCustomConfig'                   ; Type = 'Boolean' }   # inferred
    @{ Param = 'LoggingAuditLogVerboseFileDirectory'                   ; Name = 'AuditLogSettings.VerboseFileDirectory'               ; Type = 'String' }   # inferred
    @{ Param = 'LoggingAuditLogCustomConfigPath'                       ; Name = 'AuditLogSettings.CustomConfigPath'                   ; Type = 'String' }   # inferred
    @{ Param = 'LoggingAuditLogNumArchivedFiles'                       ; Name = 'AuditLogSettings.NumArchivedFiles'                   ; Type = 'Int32' }   # inferred
    @{ Param = 'LoggingAuditLogArchiveSchedule'                        ; Name = 'AuditLogSettings.ArchiveSchedule'                    ; Type = 'String' }   # inferred
    @{ Param = 'MailServerEnableSSL'                                   ; Name = 'MailServerSettings.EnableSSL'                        ; Type = 'Boolean' }   # inferred
    @{ Param = 'MailServerHost'                                        ; Name = 'MailServerSettings.Host'                             ; Type = 'String' }
    @{ Param = 'MailServerSender'                                      ; Name = 'MailServerSettings.Sender'                           ; Type = 'String' }   # inferred
    @{ Param = 'MailServerUser'                                        ; Name = 'MailServerSettings.User'                             ; Type = 'String' }   # inferred
    @{ Param = 'MailServerOAuth2ClientId'                              ; Name = 'MailServerSettings.OAuth2ClientId'                   ; Type = 'String' }   # inferred
    @{ Param = 'MailServerOAuth2TenantId'                              ; Name = 'MailServerSettings.OAuth2TenantId'                   ; Type = 'String' }   # inferred
    @{ Param = 'MailServerOAuth2RedirectUri'                           ; Name = 'MailServerSettings.OAuth2RedirectUri'                ; Type = 'String' }   # inferred
    @{ Param = 'MailServerOAuth2Provider'                              ; Name = 'MailServerSettings.OAuth2Provider'                   ; Type = 'String' }   # inferred
    @{ Param = 'MailServerOAuth2Sender'                                ; Name = 'MailServerSettings.OAuth2Sender'                     ; Type = 'String' }   # inferred
    @{ Param = 'MailServerMSGraphAPIClientId'                          ; Name = 'MailServerSettings.MSGraphAPIClientId'               ; Type = 'String' }   # inferred
    @{ Param = 'MailServerMSGraphAPITenantId'                          ; Name = 'MailServerSettings.MSGraphAPITenantId'               ; Type = 'String' }   # inferred
    @{ Param = 'MailServerMSGraphAPICloudHostUrl'                      ; Name = 'MailServerSettings.MSGraphAPICloudHostUrl'           ; Type = 'String' }   # inferred
    @{ Param = 'MailServerMSGraphAPISender'                            ; Name = 'MailServerSettings.MSGraphAPISender'                 ; Type = 'String' }   # inferred
    @{ Param = 'PerformanceBandwidthLimitPercent'                      ; Name = 'PerformanceSettings.BandwidthLimitPercent'           ; Type = 'Int32' }   # inferred
    @{ Param = 'PerformanceCopyMode'                                   ; Name = 'PerformanceSettings.CopyMode'                        ; Type = 'String'; Allowed = @('Push', 'Pull') }
    @{ Param = 'PerformanceMaxDeploymentThreads'                       ; Name = 'PerformanceSettings.MaxDeploymentThreads'            ; Type = 'Int32' }
    @{ Param = 'PerformanceMaxServerThreads'                           ; Name = 'PerformanceSettings.MaxServerThreads'                ; Type = 'Int32' }   # inferred
    @{ Param = 'PerformanceCredentialBatchSize'                        ; Name = 'PerformanceSettings.CredentialBatchSize'             ; Type = 'Int32' }   # inferred
    @{ Param = 'PerformanceIntegrationMessageTimeoutSeconds'           ; Name = 'PerformanceSettings.IntegrationMessageTimeoutSeconds'; Type = 'Int32' }   # inferred
    @{ Param = 'ProxyHostName'                                         ; Name = 'ProxySettings.HostName'                              ; Type = 'String' }   # inferred
    @{ Param = 'ProxyPort'                                             ; Name = 'ProxySettings.Port'                                  ; Type = 'Int32' }
    @{ Param = 'ProxyUserName'                                         ; Name = 'ProxySettings.UserName'                              ; Type = 'String' }   # inferred
    @{ Param = 'ProxyUseSystemHost'                                    ; Name = 'ProxySettings.UseSystemHost'                         ; Type = 'Boolean' }   # inferred
    @{ Param = 'RepositoryEnableUnusedFilesWarning'                    ; Name = 'RepositorySettings.EnableUnusedFilesWarning'         ; Type = 'Boolean' }
    @{ Param = 'RepositoryExclusions'                                  ; Name = 'RepositorySettings.Exclusions'                       ; Type = 'String' }   # inferred
    @{ Param = 'RepositoryPath'                                        ; Name = 'RepositorySettings.Path'                             ; Type = 'String'; Variable = 'Repository' }   # inferred
    @{ Param = 'SpiceworksHostName'                                    ; Name = 'SpiceworksSettings.HostName'                         ; Type = 'String' }   # inferred
    @{ Param = 'SpiceworksIsEnabled'                                   ; Name = 'SpiceworksSettings.IsEnabled'                        ; Type = 'Boolean' }   # inferred
    @{ Param = 'SpiceworksPort'                                        ; Name = 'SpiceworksSettings.Port'                             ; Type = 'Int32' }
    @{ Param = 'SpiceworksSyncInterval'                                ; Name = 'SpiceworksSettings.SyncInterval'                     ; Type = 'String' }   # inferred
    @{ Param = 'SpiceworksUserName'                                    ; Name = 'SpiceworksSettings.UserName'                         ; Type = 'String' }   # inferred
    @{ Param = 'SpiceworksUseSSL'                                      ; Name = 'SpiceworksSettings.UseSSL'                           ; Type = 'Boolean' }   # inferred
    @{ Param = 'TargetServiceRemoteDirectory'                          ; Name = 'TargetServiceSettings.RemoteDirectory'               ; Type = 'String' }
    @{ Param = 'TargetServiceSharePath'                                ; Name = 'TargetServiceSettings.SharePath'                     ; Type = 'String' }   # inferred
    @{ Param = 'AnalyticsCollectAnalyticsUsage'                        ; Name = 'AnalyticsSettings.CollectAnalyticsUsage'             ; Type = 'Boolean' }
    @{ Param = 'AnalyticsAlertFirstTimeAnalyticsDialog'                ; Name = 'AnalyticsSettings.AlertFirstTimeAnalyticsDialog'     ; Type = 'Boolean' }
  )
)

# Initialize the custom stream preferences; the built-in ones already exist.
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

# Configure the debug levels: first digit ErrorActionPreference, second digit
# Set-PSDebug, third digit Set-StrictMode.
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

# Universal trap used to help with debugging efforts. The original template's
# Wait-Debugger/Exit are interactive-host machinery; under the Ansible
# transport the trap logs and rethrows (Break) so the task fails honestly.
Trap {
  # Diagnostics are wrapped so a partially-populated error record can never
  # replace the original failure with a StrictMode property error.
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

# Under win_powershell the transport provides $Ansible; standalone (a dev
# shell or a Pester spec) it does not, so the script creates a faithful stub.
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

# Validate and translate in one pass over what the caller actually asked for. Every name is
# checked against the table before anything is read or written, so a typo fails here rather than
# becoming a row the product stores and never reads.
$Setting = @{}
$DatabaseVariable = @{}
ForEach ($Given In @($PSBoundParameters['Setting'].Keys)) {
  $Known = @($SETTINGS | Where-Object -FilterScript { $PSItem.Param -eq $Given })
  If ($Known.Count -ne 1) {
    Throw ('{0} is not a setting this script can apply; see the SETTINGS table' -f $Given)
  }
  $Entry = $Known[0]
  $Value = $PSBoundParameters['Setting'][$Given]

  If ($Null -eq $Value) {
    # Declared without a value is declared without being managed, which the Ansible side spells
    # as omit and a bare YAML key spells as null.
    Continue
  }
  If ($Value.GetType().Name -ne $Entry.Type) {
    Throw ('{0} takes a {1}, not a {2}' -f $Given, $Entry.Type, $Value.GetType().Name)
  }
  If ($Entry.ContainsKey('Allowed') -and $Entry.Allowed -notcontains $Value) {
    Throw ('{0} takes one of: {1}' -f $Given, ($Entry.Allowed -join ', '))
  }

  # The export writes booleans lower case, so the comparison is made in the product's spelling
  # rather than PowerShell's.
  $Setting[$Entry.Name] = If ($Value -is [System.Boolean]) {
    ([System.String]$Value).ToLowerInvariant()
  } Else {
    [System.String]$Value
  }
  If ($Entry.ContainsKey('Variable')) {
    $DatabaseVariable[$Entry.Name] = $Entry.Variable
  }
}

$DatabasePath = [System.String]::Empty
$Applied = [System.Collections.Generic.List[System.String]]::new()
$Unchanged = [System.Collections.Generic.List[System.String]]::new()
$Ignored = [System.Collections.Generic.List[System.String]]::new()

Try {
  # Two passes over the same reading code: once to decide what to write, once to
  # prove it landed. The export is the product's own account of its
  # configuration, and the only one that cannot be satisfied by a row nothing
  # reads.
  For ($Pass = 0; $Pass -lt 2; $Pass++) {
    If (Test-Path -LiteralPath:$EXPORT_PATH) {
      Remove-Item -LiteralPath:$EXPORT_PATH -Force
    }
    $Null = & $CLI_PATH 'ExportSettings' '-Path' $EXPORT_PATH '-Overwrite' 2>&1
    If ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath:$EXPORT_PATH)) {
      Throw ('ExportSettings failed with exit code {0}' -f $LASTEXITCODE)
    }

    # Flatten the export to the names the command line uses: an element and its
    # parent joined by a dot. Walked with an explicit stack because a script is
    # one process stage and carries no functions of its own to recurse with.
    # Read it whole and delete it before parsing, so the file exists for the
    # export plus one read and no longer. The read goes through the provider
    # like the existence check and the delete beside it: one mechanism for the
    # file, rather than a raw framework call that resolves the same string
    # differently. The command line offers no way to
    # write anywhere but a file, and the export carries configuration -- mail,
    # proxy and integration USER names among it -- so the shortest life is the
    # cheapest mitigation available.
    $Current = @{}
    $Document = [System.Xml.XmlDocument]::new()
    $Document.LoadXml((Get-Content -LiteralPath:$EXPORT_PATH -Raw))
    Remove-Item -LiteralPath:$EXPORT_PATH -Force
    $Pending = [System.Collections.Stack]::new()
    ForEach ($Root In $Document.DocumentElement.ChildNodes) {
      If ($Root.NodeType -eq [System.Xml.XmlNodeType]::Element) {
        $Pending.Push([PSCustomObject]@{ Node = $Root; Trail = @($Root.Name) })
      }
    }
    While ($Pending.Count -gt 0) {
      $Item = $Pending.Pop()
      $Children = @($Item.Node.ChildNodes | Where-Object -FilterScript {
          $PSItem.NodeType -eq [System.Xml.XmlNodeType]::Element
        })
      If ($Children.Count -gt 0) {
        ForEach ($Child In $Children) {
          $Pending.Push([PSCustomObject]@{ Node = $Child; Trail = ($Item.Trail + $Child.Name) })
        }
      } Else {
        $Value = If ($Item.Node.HasAttribute('value')) {
          $Item.Node.GetAttribute('value')
        } Else {
          $Item.Node.InnerText
        }
        # Indexed under both spellings: the product's command line takes the
        # two-part name, while the export nests some sections under a view
        # model, and a caller should not have to know which.
        $Trail = [System.String[]]$Item.Trail
        $Current[($Trail -join '.')] = $Value
        If ($Trail.Count -ge 2) {
          $Current[($Trail[-2..-1] -join '.')] = $Value
        }
      }
    }

    If ($Pass -eq 0) {
      # Write only what differs. A name the export does not carry is still
      # attempted: it may be one the product stores without publishing, and the
      # second pass is what decides whether it counted.
      ForEach ($Name In @($Setting.Keys)) {
        $Desired = [System.String]$Setting[$Name]
        If ($Current.ContainsKey($Name) -and $Current[$Name] -eq $Desired) {
          $Unchanged.Add($Name)
          Continue
        }
        If ($Ansible.CheckMode) {
          $Applied.Add($Name)
          Continue
        }
        If ($DatabaseVariable.ContainsKey($Name)) {
          # Where the database lives is a deployment choice, so it is asked for rather than
          # assumed: the product reports its own path and cannot be wrong about it.
          If (-not $DatabasePath) {
            $Info = & $CLI_PATH 'SystemInfo' 2>&1
            If ($LASTEXITCODE -ne 0) {
              Throw ('SystemInfo failed with exit code {0}' -f $LASTEXITCODE)
            }
            $DatabasePath = (
              @($Info | Where-Object -FilterScript { $PSItem -match '^\s*Database\s*:' }) |
                Select-Object -First 1
            ) -replace '^\s*Database\s*:\s*', ''
            If (-not $DatabasePath) {
              Throw 'SystemInfo did not report a database path'
            }
          }
          $Statement = "UPDATE SystemVariables SET Value = '{0}', Modified = datetime('now') WHERE Name = '{1}';" -f @(
            $Desired.Replace("'", "''")
            $DatabaseVariable[$Name].Replace("'", "''")
          )
          $Null = & $SQLITE_PATH $DatabasePath $Statement 2>&1
          If ($LASTEXITCODE -ne 0) {
            Throw ('Database write failed for {0} with exit code {1}' -f $Name, $LASTEXITCODE)
          }
        } Else {
          $Null = & $CLI_PATH 'Settings' '-Name' $Name '-Set' $Desired 2>&1
          If ($LASTEXITCODE -ne 0) {
            Throw ('Settings -Set failed for {0} with exit code {1}' -f $Name, $LASTEXITCODE)
          }
        }
      }
      If ($Ansible.CheckMode) {
        Break
      }
    } Else {
      # Prove it. Anything asked for that does not read back is a setting the
      # product accepted and does not use, which is the failure this script
      # exists to surface.
      ForEach ($Name In @($Setting.Keys)) {
        If ($Unchanged -contains $Name) {
          Continue
        }
        If ($Current.ContainsKey($Name) -and $Current[$Name] -eq ([System.String]$Setting[$Name])) {
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
  msg        = If ($Ignored.Count -gt 0) {
    'The product accepted but did not apply: {0}' -f ($Ignored -join ', ')
  } Else {
    '{0} applied, {1} already correct' -f $Applied.Count, $Unchanged.Count
  }
  requested  = [System.Int32]$Setting.Count
  unchanged  = [System.String[]]$Unchanged
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

# The result is published either way, so a caller can see WHICH settings were
# ignored before the failure is raised.
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
