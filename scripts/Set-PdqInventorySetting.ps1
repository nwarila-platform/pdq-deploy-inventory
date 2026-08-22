#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Applies a set of PDQ Inventory settings in one pass and proves each one took.

    .DESCRIPTION
        PDQ's command line accepts ANY setting name -- a dead row still reports success -- so
        an exit code proves nothing. Three proven legs close the gap: the SETTINGS table kills
        typos before anything runs, the settle poll outwaits the service's asynchronous drain,
        and the product's export is the verify oracle -- what does not read back fails the run.

        The export is a FILE only, read whole and deleted at once; it carries no secrets.

        One process stage (read -> act -> verify -> one result); shipped by the org three-file
        convention (the scripts/ pair plus the role's .stub).

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
        each holding that page's settings under the labels the page shows. Names the script
        does not own are set aside for the tasks that do; a name the table does not carry fails
        the run. Absent means unmanaged; values keep the caller's types (measured 2026-08-22).

    .PARAMETER DatabaseDrive
        Drive letter the database lives on; anchors the derived backup and log locations.

    .PARAMETER DatabaseDirectory
        Database folder on that drive; the derived locations sit beside it.

    .EXAMPLE
        .\Set-PdqInventorySetting.ps1 -Preference @{ scanning = @{ cleanup_log_days = 21 } } -DatabaseDrive 'D' -DatabaseDirectory 'PDQ Inventory'

    .OUTPUTS
        One object carrying applied, unchanged, ignored, requested, changed, check_mode,
        open_consoles and msg.
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
  [System.Collections.IDictionary] $Preference,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z]$')]
  [System.String] $DatabaseDrive,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String] $DatabaseDirectory
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

# The product's tools and export staging. Fixed: the installer ignores every documented
# relocation switch (measured 2026-08-22).
New-Variable -Force -Name:'CLI_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
)
New-Variable -Force -Name:'SQLITE_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe'
)
New-Variable -Force -Name:'EXPORT_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Windows\Temp\pdq-inventory-settings-export.xml'
)

# The settable surface, as data. Param is the caller's name; Name is the product's own, as the
# export publishes it (its last two path segments). Type and Allowed gate the value. Store marks
# the few families the command line writes under a different name than the export publishes.
# Names were proven by a live write-and-read-back campaign, 2026-08-22: the export is the oracle,
# because the command line reports success for a name nothing reads.
New-Variable -Force -Name:'SETTINGS' -Option:('Private', 'ReadOnly') -Value:(
  [System.Collections.Hashtable[]]@(
    @{ Param = 'database.enable_automatic_backups'; Name = 'DatabaseBackupSettings.IsEnabled'; Type = 'Boolean' }
    @{ Param = 'database.backups_to_keep'; Name = 'DatabaseBackupSettings.Keep'; Type = 'Int32' }
    @{ Param = 'database.compress_backups'; Name = 'DatabaseBackupSettings.Compress'; Type = 'Boolean' }
    @{ Param = 'database.backup_location'; Name = 'DatabaseBackupSettings.BackupDirectory'; Type = 'String' }
    # An interface toggle the product stores in its database but does NOT publish in its export
    # (measured 2026-08-22): the export is no oracle for it, so Unexported marks it verified against
    # its database ROW instead. The command line reaches it under the InterfaceSettings name.
    @{ Param = 'interface.show_collection_item_counts'; Name = 'InterfaceSettings.ShowCollectionItemCounts'; Type = 'Boolean'; Unexported = $True }
    @{ Param = 'active_directory.create_ad_collections'; Name = 'ActiveDirectorySettings.CreateADCollections'; Type = 'Boolean' }
    @{ Param = 'active_directory.create_group_collections'; Name = 'ActiveDirectorySettings.CreateGroupCollections'; Type = 'Boolean' }
    @{ Param = 'active_directory.delete_mode'; Name = 'ActiveDirectorySettings.DeleteMode'; Type = 'String' }
    @{ Param = 'active_directory.sync_interval'; Name = 'ActiveDirectorySettings.Interval'; Type = 'String' }
    @{ Param = 'active_directory.enable_sync'; Name = 'ActiveDirectorySettings.IsEnabled'; Type = 'Boolean' }
    @{ Param = 'active_directory.sync_disabled'; Name = 'ActiveDirectorySettings.SyncDisabled'; Type = 'Boolean' }
    @{ Param = 'scanning.ping_before_scan'; Name = 'ScanSettings.UsePing'; Type = 'Boolean' }
    @{ Param = 'scanning.wake_on_lan'; Name = 'ScanSettings.TryWol'; Type = 'Boolean' }
    @{ Param = 'scanning.cleanup_log_days'; Name = 'ScanSettings.CleanupLogDays'; Type = 'Int32' }
    @{ Param = 'scanning.max_stored_scan_output_size'; Name = 'ScanSettings.MaxStoredScanOutputSize'; Type = 'Int32' }
    @{ Param = 'performance.total_concurrent_targets'; Name = 'PerformanceSettings.MaxServerThreads'; Type = 'Int32' }
    @{ Param = 'performance.scan_timeout_minutes'; Name = 'PerformanceSettings.ScanTimeoutMinutes'; Type = 'Int32' }
    @{ Param = 'performance.wmi_timeout_seconds'; Name = 'PerformanceSettings.WmiTimeoutSeconds'; Type = 'Int32' }
    @{ Param = 'logging.send_anonymous_exception_data'; Name = 'SentrySettings.CanSendAnonymousExceptionData'; Type = 'Boolean' }
    @{ Param = 'logging.audit_keep_days'; Name = 'AuditLogSettings.DaysRecordsKept'; Type = 'Int32' }
    @{ Param = 'logging.verbose_log_to_file'; Name = 'AuditLogSettings.WriteVerboseFile'; Type = 'Boolean' }
    @{ Param = 'logging.verbose_log_directory'; Name = 'AuditLogSettings.VerboseFileDirectory'; Type = 'String' }
    @{ Param = 'logging.archive_log_every'; Name = 'AuditLogSettings.ArchiveSchedule'; Type = 'String' }
    @{ Param = 'logging.archived_logs_to_keep'; Name = 'AuditLogSettings.NumArchivedFiles'; Type = 'Int32' }
    @{ Param = 'logging.use_logging_configuration_file'; Name = 'AuditLogSettings.LoadCustomConfig'; Type = 'Boolean' }
    @{ Param = 'logging.logging_configuration_file'; Name = 'AuditLogSettings.CustomConfigPath'; Type = 'String' }
    @{ Param = 'pdq_deploy.cleanup_history'; Name = 'PDQDeploySettings.Cleanup'; Type = 'Boolean' }
    @{ Param = 'pdq_deploy.cleanup_history_days'; Name = 'PDQDeploySettings.CleanupDays'; Type = 'Int32' }
    @{ Param = 'heartbeat.auto_heartbeat_enabled'; Name = 'NetworkSettings.AutoHeartbeatEnabled'; Type = 'Boolean' }
    @{ Param = 'heartbeat.heartbeat_interval_seconds'; Name = 'NetworkSettings.HeartbeatIntervalSeconds'; Type = 'Int32' }
    @{ Param = 'mail_server.enable_ssl'; Name = 'MailServerSettings.EnableSSL'; Type = 'Boolean' }
    @{ Param = 'mail_server.smtp_server'; Name = 'MailServerSettings.Host'; Type = 'String' }
    @{ Param = 'mail_server.sender_address'; Name = 'MailServerSettings.Sender'; Type = 'String' }
    @{ Param = 'mail_server.smtp_user'; Name = 'MailServerSettings.User'; Type = 'String' }
    @{ Param = 'mail_server.oauth2_client_id'; Name = 'MailServerSettings.OAuth2ClientId'; Type = 'String' }
    @{ Param = 'mail_server.oauth2_tenant_id'; Name = 'MailServerSettings.OAuth2TenantId'; Type = 'String' }
    @{ Param = 'mail_server.oauth2_redirect_uri'; Name = 'MailServerSettings.OAuth2RedirectUri'; Type = 'String' }
    @{ Param = 'mail_server.oauth2_provider'; Name = 'MailServerSettings.OAuth2Provider'; Type = 'String' }
    @{ Param = 'mail_server.oauth2_sender'; Name = 'MailServerSettings.OAuth2Sender'; Type = 'String' }
    @{ Param = 'mail_server.graph_client_id'; Name = 'MailServerSettings.MSGraphAPIClientId'; Type = 'String' }
    @{ Param = 'mail_server.graph_tenant_id'; Name = 'MailServerSettings.MSGraphAPITenantId'; Type = 'String' }
    @{ Param = 'mail_server.graph_cloud'; Name = 'MailServerSettings.MSGraphAPICloudHostUrl'; Type = 'String' }
    @{ Param = 'mail_server.graph_sender'; Name = 'MailServerSettings.MSGraphAPISender'; Type = 'String' }
    # Printing stores under ProductPrintingSettings.* while the export publishes PrintingSettings.*
    # -- the Store field carries the difference (measured 2026-08-22, the same quirk as PDQ Deploy).
    @{ Param = 'printing.footer_alignment'; Name = 'PrintingSettings.FooterAlignment'; Type = 'String'; Store = 'ProductPrintingSettings.FooterAlignment' }
    @{ Param = 'printing.footer_text'; Name = 'PrintingSettings.FooterText'; Type = 'String'; Store = 'ProductPrintingSettings.FooterText' }
    @{ Param = 'printing.header_alignment'; Name = 'PrintingSettings.HeaderAlignment'; Type = 'String'; Store = 'ProductPrintingSettings.HeaderAlignment' }
    @{ Param = 'printing.header_text'; Name = 'PrintingSettings.HeaderText'; Type = 'String'; Store = 'ProductPrintingSettings.HeaderText' }
    @{ Param = 'printing.in_color'; Name = 'PrintingSettings.IsInColor'; Type = 'Boolean'; Store = 'ProductPrintingSettings.IsInColor' }
    @{ Param = 'printing.margin_bottom'; Name = 'PrintingSettings.MarginBottom'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginBottom' }
    @{ Param = 'printing.margin_left'; Name = 'PrintingSettings.MarginLeft'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginLeft' }
    @{ Param = 'printing.margin_right'; Name = 'PrintingSettings.MarginRight'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginRight' }
    @{ Param = 'printing.margin_top'; Name = 'PrintingSettings.MarginTop'; Type = 'Int32'; Store = 'ProductPrintingSettings.MarginTop' }
    @{ Param = 'proxy_server.host_name'; Name = 'ProxySettings.HostName'; Type = 'String' }
    @{ Param = 'proxy_server.port'; Name = 'ProxySettings.Port'; Type = 'Int32' }
    @{ Param = 'proxy_server.username'; Name = 'ProxySettings.UserName'; Type = 'String' }
    @{ Param = 'proxy_server.use_system_proxy'; Name = 'ProxySettings.UseSystemHost'; Type = 'Boolean' }
    @{ Param = 'remote_control.rdp_full_screen'; Name = 'RemoteDesktopSettings.FullScreen'; Type = 'Boolean' }
    @{ Param = 'remote_control.rdp_height'; Name = 'RemoteDesktopSettings.Height'; Type = 'Int32' }
    @{ Param = 'remote_control.rdp_width'; Name = 'RemoteDesktopSettings.Width'; Type = 'Int32' }
    @{ Param = 'remote_control.rdp_port'; Name = 'RemoteDesktopSettings.Port'; Type = 'Int32' }
    @{ Param = 'remote_control.vnc_display_number'; Name = 'VncSettings.DisplayNumber'; Type = 'Int32' }
    @{ Param = 'remote_control.vnc_viewer_path'; Name = 'VncSettings.ViewerPath'; Type = 'String' }
    @{ Param = 'target_service.unc_path'; Name = 'TargetServiceSettings.RemoteDirectory'; Type = 'String' }
    @{ Param = 'target_service.local_path_of_shared_directory'; Name = 'TargetServiceSettings.SharePath'; Type = 'String' }
    @{ Param = 'software_deployment.install_dotnet_automatically'; Name = 'DotNetSettings.InstallAutomatically'; Type = 'Boolean' }
    @{ Param = 'software_deployment.dotnet_installer_path'; Name = 'DotNetSettings.InstallerPath'; Type = 'String' }
    @{ Param = 'software_deployment.dotnet_install_timeout'; Name = 'DotNetSettings.InstallTimeout'; Type = 'String' }
    @{ Param = 'usage_data.collect_usage_data'; Name = 'AnalyticsSettings.CollectAnalyticsUsage'; Type = 'Boolean' }
    @{ Param = 'usage_data.alert_first_time_analytics_dialog'; Name = 'AnalyticsSettings.AlertFirstTimeAnalyticsDialog'; Type = 'Boolean' }
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
  Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1))
}

# Universal trap: log diagnostics, rethrow so the task fails honestly. Wrapped so a partial
# error record can never replace the original failure with a StrictMode property error.
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

# Settle window and poll cadence, sized from the measured ~8s-per-edit drain; standalone runs
# keep them short for the spec's stalled fake.
New-Variable -Force -Name:'SETTLE_DEADLINE_SECONDS' -Option:('Private', 'ReadOnly') -Value:(
  [System.Int32]$(If ($StandaloneRun) { 3 } Else { 600 })
)
New-Variable -Force -Name:'SETTLE_POLL_MILLISECONDS' -Option:('Private', 'ReadOnly') -Value:(
  [System.Int32]$(If ($StandaloneRun) { 50 } Else { 5000 })
)

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# Names other tasks own -- the per-user alerts/interface pages and the logging record_* severities
# -- set aside by EXACT name so a misspelled routed key fails as an unknown setting instead of
# silently reverting to its default.
New-Variable -Force -Name:'ROUTED_NAMES' -Option:('Private', 'ReadOnly') -Value:(
  [System.Collections.Generic.HashSet[System.String]]@(
    'alerts.auto_update_check_enabled', 'alerts.show_webcast_alerts', 'alerts.release_channel',
    'interface.color_theme', 'interface.disable_splash_screen',
    'logging.record_error', 'logging.record_warning', 'logging.record_informational',
    'logging.record_debug'
  )
)
$Flat = @{}
ForEach ($PageName In @($PSBoundParameters['Preference'].Keys)) {
  $Page = $PSBoundParameters['Preference'][$PageName]
  If ($Page -is [System.Collections.IDictionary]) {
    ForEach ($Leaf In @($Page.Keys)) {
      $Dotted = '{0}.{1}' -f $PageName, $Leaf
      If ($ROUTED_NAMES.Contains($Dotted)) {
        Continue
      }
      $Flat[$Dotted] = $Page[$Leaf]
    }
  } Else {
    $Flat[$PageName] = $Page
  }
}

# Two locations are the role's to place, not the caller's to guess: the backup and verbose-log
# locations default to sitting beside the database on its dedicated drive, because both grow the
# way the database does, and a caller may still name somewhere else. Inventory has no repository
# -- it is a scanner, not a deployer -- so no derived share path is composed here.
If ([System.String]::IsNullOrEmpty([System.String]$Flat['database.backup_location'])) {
  $Flat['database.backup_location'] = '{0}:\{1}\Backups' -f $DatabaseDrive, $DatabaseDirectory
}
If ([System.String]::IsNullOrEmpty([System.String]$Flat['logging.verbose_log_directory'])) {
  $Flat['logging.verbose_log_directory'] = '{0}:\{1}\Logs' -f $DatabaseDrive, $DatabaseDirectory
}

# Validate and translate in one pass: every name is checked against the table before anything
# is read or written, so a typo fails before it can become a row nothing reads.
$Setting = @{}
$StoreName = @{}
$Unexported = @{}
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

  # The export writes booleans lower case, so the comparison is made in the product's spelling
  # rather than PowerShell's.
  $Setting[$Entry.Name] = If ($Value -is [System.Boolean]) {
    ([System.String]$Value).ToLowerInvariant()
  } Else {
    [System.String]$Value
  }
  If ($Entry.ContainsKey('Store')) {
    $StoreName[$Entry.Name] = $Entry.Store
  }
  If ($Entry.ContainsKey('Unexported')) {
    If ([System.String]::IsNullOrEmpty([System.String]$Setting[$Entry.Name])) {
      # Verified against its database ROW, an export-invisible setting stored as no row has
      # nothing to read back, so blank would fail verification forever.
      Throw ('{0} cannot be set blank: it is not published by the export' -f $Given)
    }
    $Unexported[$Entry.Name] = $True
  }
}

# Working state: the verdict lists, the queued writes the settle poll waits on.
$Applied = [System.Collections.Generic.List[System.String]]::new()
$Unchanged = [System.Collections.Generic.List[System.String]]::new()
$Ignored = [System.Collections.Generic.List[System.String]]::new()
$CliWritten = @{}
$OpenConsole = [System.Collections.Generic.List[System.String]]::new()
$DatabasePath = [System.String]::Empty

Try {
  If ($Setting.Count -gt 0) {
    # Where the database lives is a deployment choice, so it is asked for rather than assumed:
    # the product reports its own path. The settle poll and the open-console read below share it.
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

  # Two passes over the same reading code: decide, then prove.
  For ($Pass = 0; $Pass -lt 2; $Pass++) {
    If (Test-Path -LiteralPath:$EXPORT_PATH) {
      Remove-Item -LiteralPath:$EXPORT_PATH -Force
    }
    $Null = & $CLI_PATH 'ExportSettings' '-Path' $EXPORT_PATH '-Overwrite' 2>&1
    If ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath:$EXPORT_PATH)) {
      Throw ('ExportSettings failed with exit code {0}' -f $LASTEXITCODE)
    }

    # Flatten to element.parent dotted names. LocalName, never Name: grouping elements can
    # carry a 'name' ATTRIBUTE the adapter surfaces in place of the tag. Explicit stack; read
    # whole, deleted at once.
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
        # Both spellings: some sections nest under a view model; a caller should not care.
        $Trail = [System.String[]]$Item.Trail
        $Current[($Trail -join '.')] = $Value
        If ($Trail.Count -ge 2) {
          $Current[($Trail[-2..-1] -join '.')] = $Value
        }
      }
    }

    $PersistedNow = @{}
    If ($Unexported.Count -gt 0) {
      # -csv so a value holding a comma or newline survives: list mode would split it; CSV quotes
      # it and ConvertFrom-Csv reads it whole once the native lines rejoin.
      $Rows = @(& $SQLITE_PATH -csv $DatabasePath 'SELECT Name, Value FROM Settings;' 2>&1) -join "`n"
      If ($LASTEXITCODE -ne 0) {
        Throw ('Reading the settings table failed with exit code {0}' -f $LASTEXITCODE)
      }
      ForEach ($Record In @($Rows | ConvertFrom-Csv -Header:('Name', 'Value'))) {
        $PersistedNow[$Record.Name] = $Record.Value
      }
    }

    # One effective view over both stores: the few measured names the export never publishes read
    # from their database rows, everything else from the export.
    $Effective = @{}
    ForEach ($Name In @($Setting.Keys)) {
      $Effective[$Name] = If ($Unexported.ContainsKey($Name)) {
        $PersistedNow[$(If ($StoreName.ContainsKey($Name)) { $StoreName[$Name] } Else { $Name })]
      } Else {
        $Current[$Name]
      }
    }

    If ($Pass -eq 0) {
      # Decide first: a value the store already shows is unchanged, everything else queues. A
      # name neither store carries still queues -- the verify pass decides whether it counted.
      $ToWrite = [System.Collections.Generic.List[System.String]]::new()
      ForEach ($Name In @($Setting.Keys)) {
        If ($Null -ne $Effective[$Name] -and [System.String]$Effective[$Name] -ceq [System.String]$Setting[$Name]) {
          $Unchanged.Add($Name)
        } Else {
          $ToWrite.Add($Name)
        }
      }
      If ($Ansible.CheckMode) {
        $Applied.AddRange($ToWrite)
        Break
      }
      ForEach ($Name In $ToWrite) {
        $Desired = [System.String]$Setting[$Name]
        # A few families store under a different spelling than the export publishes --
        # ProductPrintingSettings vs the export's PrintingSettings, measured 2026-08-22 -- the
        # command line answers only to the STORED name, while the export stays verify oracle.
        $WriteName = If ($StoreName.ContainsKey($Name)) { $StoreName[$Name] } Else { $Name }
        If ($Desired -eq [System.String]::Empty) {
          # -Set refuses empty values; the product's way back to blank is -Reset, dropping
          # the override row. Verify still proves the result reads back blank.
          $Null = & $CLI_PATH 'Settings' '-Name' $WriteName '-Reset' 2>&1
          If ($LASTEXITCODE -ne 0) {
            Throw ('Settings -Reset failed for {0} with exit code {1}' -f $Name, $LASTEXITCODE)
          }
          $CliWritten[$WriteName] = [System.String]::Empty
        } Else {
          $Null = & $CLI_PATH 'Settings' '-Name' $WriteName '-Set' $Desired 2>&1
          If ($LASTEXITCODE -ne 0) {
            Throw ('Settings -Set failed for {0} with exit code {1}' -f $Name, $LASTEXITCODE)
          }
          $CliWritten[$WriteName] = $Desired
        }
      }

      # Edits drain through the service at ~8s apiece (measured 2026-08-22), so the run waits
      # for every queued edit's DATABASE row: applied means persisted, whatever restarts next.
      # A reset settles when its row is gone.
      If ($CliWritten.Count -gt 0) {
        $Deadline = [System.DateTime]::UtcNow.AddSeconds($SETTLE_DEADLINE_SECONDS)
        While ($True) {
          $Persisted = @{}
          $Rows = @(& $SQLITE_PATH -csv $DatabasePath 'SELECT Name, Value FROM Settings;' 2>&1) -join "`n"
          If ($LASTEXITCODE -ne 0) {
            Throw ('Reading the settings table failed with exit code {0}' -f $LASTEXITCODE)
          }
          ForEach ($Record In @($Rows | ConvertFrom-Csv -Header:('Name', 'Value'))) {
            $Persisted[$Record.Name] = $Record.Value
          }
          $Draining = @($CliWritten.Keys | Where-Object -FilterScript {
              If ($CliWritten[$PSItem] -eq [System.String]::Empty) {
                $Persisted.ContainsKey($PSItem)
              } Else {
                $Persisted[$PSItem] -cne $CliWritten[$PSItem]
              }
            })
          If ($Draining.Count -eq 0) {
            Break
          }
          If ([System.DateTime]::UtcNow -gt $Deadline) {
            Throw ('The service did not persist {0} inside the settle window' -f ($Draining -join ', '))
          }
          Start-Sleep -Milliseconds $SETTLE_POLL_MILLISECONDS
        }
      }

      # An open console's next save writes its stale page model back over anything applied
      # here (measured 2026-08-22), so writes report who has a console open.
      If ($ToWrite.Count -gt 0) {
        $Sessions = @(& $SQLITE_PATH $DatabasePath "SELECT UserName FROM ConsoleUserSessions WHERE Console <> '';" 2>&1)
        If ($LASTEXITCODE -ne 0) {
          Throw ('Reading the console sessions failed with exit code {0}' -f $LASTEXITCODE)
        }
        ForEach ($Row In $Sessions) {
          If ($Row) {
            $OpenConsole.Add([System.String]$Row)
          }
        }
      }
    } Else {
      # Prove it: anything that does not read back was accepted and unused -- the failure this
      # script exists to surface.
      ForEach ($Name In @($Setting.Keys)) {
        If ($Unchanged -contains $Name) {
          Continue
        }
        If ($Null -ne $Effective[$Name] -and [System.String]$Effective[$Name] -ceq [System.String]$Setting[$Name]) {
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
  applied       = [System.String[]]$Applied
  changed       = [System.Boolean]($Applied.Count -gt 0)
  check_mode    = [System.Boolean]$Ansible.CheckMode
  ignored       = [System.String[]]$Ignored
  msg           = If ($Ansible.CheckMode) {
    '{0} would be applied, {1} already correct' -f $Applied.Count, $Unchanged.Count
  } ElseIf ($Ignored.Count -gt 0) {
    'The product accepted but did not apply: {0}' -f ($Ignored -join ', ')
  } ElseIf ($OpenConsole.Count -gt 0) {
    '{0} applied, {1} already correct; a console is open for {2}, whose next save may overwrite them' -f @(
      $Applied.Count
      $Unchanged.Count
      (($OpenConsole | Sort-Object -Unique) -join ', ')
    )
  } Else {
    '{0} applied, {1} already correct' -f $Applied.Count, $Unchanged.Count
  }
  open_consoles = [System.String[]]@($OpenConsole | Sort-Object -Unique)
  requested     = [System.Int32]$Setting.Count
  unchanged     = [System.String[]]$Unchanged
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
