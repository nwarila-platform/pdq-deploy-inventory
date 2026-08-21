#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Applies a set of PDQ settings in one pass and proves each one took.

    .DESCRIPTION
        PDQ keeps its settings behind a command line that writes them one at a time into a
        key-value store that accepts ANY name: a name the product does not read reports success,
        inserts a row, and changes nothing, so an exit code proves nothing.

        The product's own export is therefore the only account trusted here: export once to
        learn the current values, write only what differs, export again, and verify every
        requested setting reads back as asked. One that did not take is reported as ignored and
        fails the run rather than being counted as applied.


        The product can only export to a FILE -- there is no stdout or in-memory form -- so each
        export is read into memory and deleted immediately, leaving it on disk for the write plus
        one read. Nothing secret is in it: the export carries user names for mail, proxy and
        integrations, and no password, token or secret element of any kind.

        WHAT IS SETTABLE is the SETTINGS table below.
        The table is the whole contract: which names exist, what type each takes, which values
        an enumerated one allows, and which live in the product's database rather than behind
        its command line. Data, not sixty-odd parameters: readable in one pass and small enough
        for the transport to log.

        The tree may carry pages this script does not own -- the per-user alerts and interface
        pages, the event-log switches -- and it sets those aside for the tasks that do.

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

    .PARAMETER Preference
        The preference tree, organised as the console's Preferences window is: a map of pages,
        each holding that page's settings under the labels the page shows. Pages and names the
        script does not own (per-user pages, the record_* event-log switches) are set aside for
        the tasks that do; a name the table does not carry fails the run -- it would otherwise
        be a silent no-op that looks like success. Absent means unmanaged; values keep the types
        the caller supplied (win_powershell hands the tree over intact, measured 2026-08-20).

    .PARAMETER DatabaseDrive
        The drive letter the database lives on; anchors the derived backup and log locations.

    .PARAMETER DatabaseDirectory
        The database folder on that drive; the derived locations sit beside it.

    .PARAMETER RepositoryShareName
        The share this machine publishes; the repository path is composed from it.

    .EXAMPLE
        .\Set-PdqSetting.ps1 -Preference @{ deployments = @{ cleanup_days = 45 } } -DatabaseDrive 'E' -DatabaseDirectory 'PDQ Deploy' -RepositoryShareName 'AppRepo$'

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
  [System.Collections.IDictionary] $Preference,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z]$')]
  [System.String] $DatabaseDrive,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String] $DatabaseDirectory,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String] $RepositoryShareName
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
    @{ Param = 'auto_download.approval' ; Name = 'AutoDeployDefaultSettings.ApprovalMode' ; Type = 'String' }
    @{ Param = 'auto_download.automatic_approval_delay'; Name = 'AutoDeployDefaultSettings.DelayedApprovalTimeSpan' ; Type = 'String' }   # inferred
    @{ Param = 'auto_download.enable_auto_download' ; Name = 'AutoDeployDefaultSettings.IsEnabled' ; Type = 'Boolean' }   # inferred
    @{ Param = 'auto_download.copies_to_keep' ; Name = 'AutoDownloadArchiveSettings.CopiesToKeep' ; Type = 'Int32' }
    @{ Param = 'auto_download.save_copies_of_previous_versions' ; Name = 'AutoDownloadArchiveSettings.IsArchiving' ; Type = 'Boolean' }   # inferred
    @{ Param = 'database.backup_location' ; Name = 'DatabaseBackupSettings.BackupDirectory' ; Type = 'String' }
    @{ Param = 'database.compress_backups' ; Name = 'DatabaseBackupSettings.Compress' ; Type = 'Boolean' }   # inferred
    @{ Param = 'database.enable_automatic_backups' ; Name = 'DatabaseBackupSettings.IsEnabled' ; Type = 'Boolean' }   # inferred
    @{ Param = 'database.backups_to_keep' ; Name = 'DatabaseBackupSettings.Keep' ; Type = 'Int32' }
    @{ Param = 'deployments.cleanup_days' ; Name = 'DeploymentSettings.CleanupDays' ; Type = 'Int32' }
    @{ Param = 'deployments.timeout_minutes' ; Name = 'DeploymentSettings.ComputerTimeout' ; Type = 'Int32' }
    @{ Param = 'deployments.inventory_scan_profile_id' ; Name = 'DeploymentSettings.InventoryScanProfileId' ; Type = 'String' }   # inferred
    @{ Param = 'deployments.run_packages_as' ; Name = 'DeploymentSettings.RunAs' ; Type = 'String' }   # inferred
    @{ Param = 'deployments.scan_after_deployment' ; Name = 'DeploymentSettings.ScanAfterDeployment' ; Type = 'Boolean' }   # inferred
    @{ Param = 'deployments.allowed_retries' ; Name = 'OfflineSettings.RetryMaxTries' ; Type = 'Int32' }
    @{ Param = 'deployments.ping_before_deployment' ; Name = 'OfflineSettings.UsePing' ; Type = 'Boolean' }   # inferred
    @{ Param = 'deployments.wake_on_lan' ; Name = 'OfflineSettings.TryWol' ; Type = 'Boolean' }   # inferred
    @{ Param = 'deployments.retry_queue_enabled' ; Name = 'OfflineSettings.IsRetryEnabled' ; Type = 'Boolean' }   # inferred
    @{ Param = 'deployments.retry_interval' ; Name = 'OfflineSettings.RetryInterval' ; Type = 'String' }   # inferred
    @{ Param = 'logging.send_anonymous_exception_data' ; Name = 'SentrySettings.CanSendAnonymousExceptionData' ; Type = 'Boolean' }   # inferred
    @{ Param = 'logging.audit_keep_days_minimum' ; Name = 'AuditLogSettings.MinDaysRecordsKept' ; Type = 'Int32' }   # inferred
    @{ Param = 'logging.audit_keep_days_maximum' ; Name = 'AuditLogSettings.MaxDaysRecordsKept' ; Type = 'Int32' }   # inferred
    @{ Param = 'logging.archived_logs_minimum' ; Name = 'AuditLogSettings.MinNumArchivedFiles' ; Type = 'Int32' }   # inferred
    @{ Param = 'logging.archived_logs_maximum' ; Name = 'AuditLogSettings.MaxNumArchivedFiles' ; Type = 'Int32' }   # inferred
    @{ Param = 'logging.verbose_log_file_name' ; Name = 'AuditLogSettings.VerboseFileName' ; Type = 'String' }   # inferred
    @{ Param = 'logging.audit_keep_days' ; Name = 'AuditLogSettings.DaysRecordsKept' ; Type = 'Int32' }
    @{ Param = 'logging.verbose_log_to_file' ; Name = 'AuditLogSettings.WriteVerboseFile' ; Type = 'Boolean' }   # inferred
    @{ Param = 'logging.use_logging_configuration_file' ; Name = 'AuditLogSettings.LoadCustomConfig' ; Type = 'Boolean' }   # inferred
    @{ Param = 'logging.verbose_log_directory' ; Name = 'AuditLogSettings.VerboseFileDirectory' ; Type = 'String' }   # inferred
    @{ Param = 'logging.logging_configuration_file' ; Name = 'AuditLogSettings.CustomConfigPath' ; Type = 'String' }   # inferred
    @{ Param = 'logging.archived_logs_to_keep' ; Name = 'AuditLogSettings.NumArchivedFiles' ; Type = 'Int32' }   # inferred
    @{ Param = 'logging.archive_log_every' ; Name = 'AuditLogSettings.ArchiveSchedule' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.enable_ssl' ; Name = 'MailServerSettings.EnableSSL' ; Type = 'Boolean' }   # inferred
    @{ Param = 'mail_server.smtp_server' ; Name = 'MailServerSettings.Host' ; Type = 'String' }
    @{ Param = 'mail_server.sender_address' ; Name = 'MailServerSettings.Sender' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.smtp_user' ; Name = 'MailServerSettings.User' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.oauth2_client_id' ; Name = 'MailServerSettings.OAuth2ClientId' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.oauth2_tenant_id' ; Name = 'MailServerSettings.OAuth2TenantId' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.oauth2_redirect_uri' ; Name = 'MailServerSettings.OAuth2RedirectUri' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.oauth2_provider' ; Name = 'MailServerSettings.OAuth2Provider' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.oauth2_sender' ; Name = 'MailServerSettings.OAuth2Sender' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.graph_client_id' ; Name = 'MailServerSettings.MSGraphAPIClientId' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.graph_tenant_id' ; Name = 'MailServerSettings.MSGraphAPITenantId' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.graph_cloud' ; Name = 'MailServerSettings.MSGraphAPICloudHostUrl' ; Type = 'String' }   # inferred
    @{ Param = 'mail_server.graph_sender' ; Name = 'MailServerSettings.MSGraphAPISender' ; Type = 'String' }   # inferred
    @{ Param = 'performance.bandwidth_limit_percent' ; Name = 'PerformanceSettings.BandwidthLimitPercent' ; Type = 'Int32' }   # inferred
    @{ Param = 'performance.copy_mode' ; Name = 'PerformanceSettings.CopyMode' ; Type = 'String'; Allowed = @('Push', 'Pull') }
    @{ Param = 'performance.concurrent_targets_per_deployment' ; Name = 'PerformanceSettings.MaxDeploymentThreads' ; Type = 'Int32' }
    @{ Param = 'performance.total_concurrent_targets' ; Name = 'PerformanceSettings.MaxServerThreads' ; Type = 'Int32' }   # inferred
    @{ Param = 'performance.credential_batch_size' ; Name = 'PerformanceSettings.CredentialBatchSize' ; Type = 'Int32' }   # inferred
    @{ Param = 'performance.integration_message_timeout_seconds' ; Name = 'PerformanceSettings.IntegrationMessageTimeoutSeconds'; Type = 'Int32' }   # inferred
    # Printing stores under ProductPrintingSettings.* while the export publishes
    # PrintingSettings.* -- the Store field carries the difference (measured 2026-08-21).
    @{ Param = 'printing.footer_alignment'; Name = 'PrintingSettings.FooterAlignment'; Type = 'String'; Store = 'ProductPrintingSettings.FooterAlignment' }
    @{ Param = 'printing.footer_text'; Name = 'PrintingSettings.FooterText'; Type = 'String'; Store = 'ProductPrintingSettings.FooterText' }
    @{ Param = 'printing.header_alignment'; Name = 'PrintingSettings.HeaderAlignment'; Type = 'String'; Store = 'ProductPrintingSettings.HeaderAlignment' }
    @{ Param = 'printing.header_text'; Name = 'PrintingSettings.HeaderText'; Type = 'String'; Store = 'ProductPrintingSettings.HeaderText' }
    @{ Param = 'printing.in_color'; Name = 'PrintingSettings.IsInColor'; Type = 'Boolean'; Store = 'ProductPrintingSettings.IsInColor' }
    @{ Param = 'printing.margin_bottom'; Name = 'PrintingSettings.MarginBottom'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginBottom' }
    @{ Param = 'printing.margin_left'; Name = 'PrintingSettings.MarginLeft'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginLeft' }
    @{ Param = 'printing.margin_right'; Name = 'PrintingSettings.MarginRight'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginRight' }
    @{ Param = 'printing.margin_top'; Name = 'PrintingSettings.MarginTop'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginTop' }
    @{ Param = 'proxy_server.host_name' ; Name = 'ProxySettings.HostName' ; Type = 'String' }   # inferred
    @{ Param = 'proxy_server.port' ; Name = 'ProxySettings.Port' ; Type = 'Int32' }
    @{ Param = 'proxy_server.username' ; Name = 'ProxySettings.UserName' ; Type = 'String' }   # inferred
    @{ Param = 'proxy_server.use_system_proxy' ; Name = 'ProxySettings.UseSystemHost' ; Type = 'Boolean' }   # inferred
    @{ Param = 'repository.show_unused_files_warning' ; Name = 'RepositorySettings.EnableUnusedFilesWarning' ; Type = 'Boolean' }
    @{ Param = 'repository.cleanup_exclusions' ; Name = 'RepositorySettings.Exclusions' ; Type = 'String' }   # inferred
    @{ Param = 'repository.path' ; Name = 'RepositorySettings.Path' ; Type = 'String'; Variable = 'Repository' }   # inferred
    @{ Param = 'spiceworks.host_name' ; Name = 'SpiceworksSettings.HostName' ; Type = 'String' }   # inferred
    @{ Param = 'spiceworks.auto_sync_enabled' ; Name = 'SpiceworksSettings.IsEnabled' ; Type = 'Boolean' }   # inferred
    @{ Param = 'spiceworks.port' ; Name = 'SpiceworksSettings.Port' ; Type = 'Int32' }
    @{ Param = 'spiceworks.sync_interval' ; Name = 'SpiceworksSettings.SyncInterval' ; Type = 'String' }   # inferred
    @{ Param = 'spiceworks.email' ; Name = 'SpiceworksSettings.UserName' ; Type = 'String' }   # inferred
    @{ Param = 'spiceworks.use_ssl' ; Name = 'SpiceworksSettings.UseSSL' ; Type = 'Boolean' }   # inferred
    @{ Param = 'target_service.unc_path' ; Name = 'TargetServiceSettings.RemoteDirectory' ; Type = 'String' }
    @{ Param = 'target_service.local_path_of_shared_directory' ; Name = 'TargetServiceSettings.SharePath' ; Type = 'String' }   # inferred
    @{ Param = 'usage_data.collect_usage_data' ; Name = 'AnalyticsSettings.CollectAnalyticsUsage' ; Type = 'Boolean' }
    @{ Param = 'usage_data.alert_first_time_analytics_dialog' ; Name = 'AnalyticsSettings.AlertFirstTimeAnalyticsDialog' ; Type = 'Boolean' }
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
# The caller declares preferences the way the console shows them: a map of PAGES, each holding
# that page's settings. This is where the role's routing lives, in plain sight: the alerts and
# interface pages are per-user and belong to the profile seeding, the four record_* switches on
# the logging page are machine registry values another task writes -- so all of those are set
# aside here -- and everything else flattens to the table's page.setting names.
$Flat = @{}
ForEach ($PageName In @($PSBoundParameters['Preference'].Keys)) {
  If ($PageName -in @('alerts', 'interface')) {
    Continue
  }
  $Page = $PSBoundParameters['Preference'][$PageName]
  If ($Page -is [System.Collections.IDictionary]) {
    ForEach ($Leaf In @($Page.Keys)) {
      If ($PageName -eq 'logging' -and $Leaf -like 'record_*') {
        Continue
      }
      $Flat[('{0}.{1}' -f $PageName, $Leaf)] = $Page[$Leaf]
    }
  } Else {
    $Flat[$PageName] = $Page
  }
}

# Three values are the role's to place, not the caller's to guess. The repository is the share
# this machine publishes, so its path is composed from this machine's own name; the backup and
# verbose-log locations default to sitting beside the database on its dedicated drive, because
# both grow the way the database does, and a caller may still name somewhere else.
$Flat['repository.path'] = '\\{0}\{1}' -f $env:COMPUTERNAME, $RepositoryShareName
If ([System.String]::IsNullOrEmpty([System.String]$Flat['database.backup_location'])) {
  $Flat['database.backup_location'] = '{0}:\{1}\Backups' -f $DatabaseDrive, $DatabaseDirectory
}
If ([System.String]::IsNullOrEmpty([System.String]$Flat['logging.verbose_log_directory'])) {
  $Flat['logging.verbose_log_directory'] = '{0}:\{1}\Logs' -f $DatabaseDrive, $DatabaseDirectory
}

$Setting = @{}
$DatabaseVariable = @{}
$StoreName = @{}
ForEach ($Given In @($Flat.Keys)) {
  $Known = @($SETTINGS | Where-Object -FilterScript { $PSItem.Param -eq $Given })
  If ($Known.Count -ne 1) {
    Throw ('{0} is not a setting this script can apply; see the SETTINGS table' -f $Given)
  }
  $Entry = $Known[0]
  $Value = $Flat[$Given]

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
  If ($Entry.ContainsKey('Store')) {
    $StoreName[$Entry.Name] = $Entry.Store
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
    # parent joined by a dot. LocalName, never Name: several of the product's
    # grouping elements carry a 'name' ATTRIBUTE, and PowerShell's XML adapter
    # surfaces attributes as properties, so .Name hands back that attribute
    # instead of the tag. Measured 2026-08-21 -- it renamed nine settings'
    # parents to their view-model spelling, so each looked absent from the
    # export and the script reported the product had discarded a write it had
    # actually stored. Walked with an explicit stack because a script is
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
        $Pending.Push([PSCustomObject]@{ Node = $Root; Trail = @($Root.LocalName) })
      }
    }
    While ($Pending.Count -gt 0) {
      $Item = $Pending.Pop()
      $Children = @($Item.Node.ChildNodes | Where-Object -FilterScript {
          $PSItem.NodeType -eq [System.Xml.XmlNodeType]::Element
        })
      If ($Children.Count -gt 0) {
        ForEach ($Child In $Children) {
          $Pending.Push([PSCustomObject]@{ Node = $Child; Trail = ($Item.Trail + $Child.LocalName) })
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
        # A few families store under a different spelling than the export publishes --
        # ProductPrintingSettings against the export's PrintingSettings was the measured case,
        # 2026-08-21 -- and the command line only answers to the STORED name. The export is
        # still the oracle the verify pass reads, so the export spelling stays the row's Name
        # and the stored one travels only in the write.
        $WriteName = If ($StoreName.ContainsKey($Name)) { $StoreName[$Name] } Else { $Name }
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
        } ElseIf ($Desired -eq [System.String]::Empty) {
          # The command line refuses -Set with an empty value, and blank IS how the product
          # ships many of these. Its own way back to blank is -Reset, which deletes the
          # override row so the compiled default shows through; the verify pass still proves
          # the result reads back blank, so a compiled default that is NOT blank fails
          # honestly instead of pretending.
          $Null = & $CLI_PATH 'Settings' '-Name' $WriteName '-Reset' 2>&1
          If ($LASTEXITCODE -ne 0) {
            Throw ('Settings -Reset failed for {0} with exit code {1}' -f $Name, $LASTEXITCODE)
          }
        } Else {
          $Null = & $CLI_PATH 'Settings' '-Name' $WriteName '-Set' $Desired 2>&1
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
