#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Applies a set of PDQ preferences in one pass and proves each one took.

    .DESCRIPTION
        PDQ keeps its preferences behind a command line that writes them one at
        a time, and a key-value store that accepts ANY name whether the product
        reads it or not. Setting a name the product does not read reports
        success, inserts a row, and changes nothing -- measured 2026-08-18 with
        RepositorySettings.Path, which the product reads from a system variable
        instead. A caller that trusts the exit code cannot tell the difference.

        A few settings are not reachable that way at all. The repository is a
        built-in system variable, and the command line has no surface for
        built-ins, so it is written into the product's own database instead.
        Which mechanism a setting needs is data, not a special case, and the
        proof afterwards is the same for both.

        This script closes that gap by treating the product's own export as the
        only account of what is configured. It exports once to learn the current
        values, writes only the settings that differ, exports again, and
        verifies every requested setting now reads back as asked. A setting that
        did not take is reported as ignored and fails the run rather than being
        counted as applied.

        Doing it here rather than task-by-task also collapses one round trip per
        setting into two exports and N writes, which matters when a deployment
        declares dozens.

        The product can only export to a FILE -- there is no stdout or in-memory
        form -- so each export is read into memory and deleted immediately,
        leaving it on disk for the write plus one read. Nothing secret is in it:
        the export carries user names for mail, proxy and integrations, and no
        password, token or secret element of any kind.

        Org scripts are a single straightforward process stage in the org script
        template's architecture: one [ Script ] region carrying
        [ Initialization ] (strict mode, transport detection, input
        normalization), [ Main ] (read -> act -> verify -> build ONE result
        object), and [ Output ] (the same object to $Ansible or as JSON).

        One parameter per setting, all optional. A parameter the caller does not
        pass is not managed -- which is a different thing from one set to the
        product's default -- so a deployment states only what it means to own.
        Ansible expresses the same idea with default(omit).

        Run 'PDQDeploy ExportSettings -Path settings.xml' on a configured host
        to see every name the product publishes; adding one here is a parameter
        and a row in SETTING_NAMES.

        Shipped by the org three-file convention: developed under scripts/ with
        its sibling Set-PdqSetting.pester.ps1 spec, while the pdq_deploy role
        carries files/Set-PdqSetting.ps1.stub, which the build resolves by
        dropping this file into the role.

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging
        functions, one digit each. First digit: ErrorActionPreference
        (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire, 4 Ignore,
        5 Suspend). Second digit: Set-PSDebug (0 off, 1 trace 1, 2 trace 2,
        3 trace 1 + step, 4 trace 2 + step). Third digit: Set-StrictMode
        (0 off, 1-3 that version). Default '103': stop on error, no tracing,
        strict mode 3.

    .PARAMETER LogLevel
        Six-digit control string setting the preference for each stream, in
        the order Verbose, Debug, Information, Warning, Error, Fatal. Each
        digit is an ActionPreference (0 SilentlyContinue, 1 Stop, 2 Continue,
        3 Inquire, 4 Ignore, 5 Suspend).

    .PARAMETER PackageLibraryAutoDeployDefaultApprovalMode
        Package Library. Product setting AutoDeployDefaultSettings.ApprovalMode.

    .PARAMETER PackageLibraryAutoDeployDefaultDelayedApprovalTimeSpan
        Package Library. Product setting AutoDeployDefaultSettings.DelayedApprovalTimeSpan. Name inferred from the export, not yet proven.

    .PARAMETER PackageLibraryAutoDeployDefaultIsEnabled
        Package Library. Product setting AutoDeployDefaultSettings.IsEnabled. Name inferred from the export, not yet proven.

    .PARAMETER PackageLibraryAutoDownloadArchiveCopiesToKeep
        Package Library. Product setting AutoDownloadArchiveSettings.CopiesToKeep.

    .PARAMETER PackageLibraryAutoDownloadArchiveIsArchiving
        Package Library. Product setting AutoDownloadArchiveSettings.IsArchiving. Name inferred from the export, not yet proven.

    .PARAMETER DatabaseDatabaseBackupBackupDirectory
        Database. Product setting DatabaseBackupSettings.BackupDirectory.

    .PARAMETER DatabaseDatabaseBackupCompress
        Database. Product setting DatabaseBackupSettings.Compress. Name inferred from the export, not yet proven.

    .PARAMETER DatabaseDatabaseBackupIsEnabled
        Database. Product setting DatabaseBackupSettings.IsEnabled. Name inferred from the export, not yet proven.

    .PARAMETER DatabaseDatabaseBackupKeep
        Database. Product setting DatabaseBackupSettings.Keep.

    .PARAMETER DeploymentCleanupDays
        Deployment. Product setting DeploymentSettings.CleanupDays.

    .PARAMETER DeploymentComputerTimeout
        Deployment. Product setting DeploymentSettings.ComputerTimeout.

    .PARAMETER DeploymentInventoryScanProfileId
        Deployment. Product setting DeploymentSettings.InventoryScanProfileId. Name inferred from the export, not yet proven.

    .PARAMETER DeploymentRunAs
        Deployment. Product setting DeploymentSettings.RunAs. Name inferred from the export, not yet proven.

    .PARAMETER DeploymentScanAfterDeployment
        Deployment. Product setting DeploymentSettings.ScanAfterDeployment. Name inferred from the export, not yet proven.

    .PARAMETER DeploymentOfflineRetryMaxTries
        Deployment. Product setting OfflineSettings.RetryMaxTries.

    .PARAMETER DeploymentOfflineUsePing
        Deployment. Product setting OfflineSettings.UsePing. Name inferred from the export, not yet proven.

    .PARAMETER DeploymentOfflineTryWol
        Deployment. Product setting OfflineSettings.TryWol. Name inferred from the export, not yet proven.

    .PARAMETER DeploymentOfflineIsRetryEnabled
        Deployment. Product setting OfflineSettings.IsRetryEnabled. Name inferred from the export, not yet proven.

    .PARAMETER DeploymentOfflineRetryInterval
        Deployment. Product setting OfflineSettings.RetryInterval. Name inferred from the export, not yet proven.

    .PARAMETER LoggingSentryCanSendAnonymousExceptionData
        Logging. Product setting SentrySettings.CanSendAnonymousExceptionData. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogMinDaysRecordsKept
        Logging. Product setting AuditLogSettings.MinDaysRecordsKept. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogMaxDaysRecordsKept
        Logging. Product setting AuditLogSettings.MaxDaysRecordsKept. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogMinNumArchivedFiles
        Logging. Product setting AuditLogSettings.MinNumArchivedFiles. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogMaxNumArchivedFiles
        Logging. Product setting AuditLogSettings.MaxNumArchivedFiles. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogVerboseFileName
        Logging. Product setting AuditLogSettings.VerboseFileName. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogDaysRecordsKept
        Logging. Product setting AuditLogSettings.DaysRecordsKept.

    .PARAMETER LoggingAuditLogWriteVerboseFile
        Logging. Product setting AuditLogSettings.WriteVerboseFile. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogLoadCustomConfig
        Logging. Product setting AuditLogSettings.LoadCustomConfig. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogVerboseFileDirectory
        Logging. Product setting AuditLogSettings.VerboseFileDirectory. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogCustomConfigPath
        Logging. Product setting AuditLogSettings.CustomConfigPath. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogNumArchivedFiles
        Logging. Product setting AuditLogSettings.NumArchivedFiles. Name inferred from the export, not yet proven.

    .PARAMETER LoggingAuditLogArchiveSchedule
        Logging. Product setting AuditLogSettings.ArchiveSchedule. Name inferred from the export, not yet proven.

    .PARAMETER MailServerEnableSSL
        Mail Server. Product setting MailServerSettings.EnableSSL. Name inferred from the export, not yet proven.

    .PARAMETER MailServerHost
        Mail Server. Product setting MailServerSettings.Host.

    .PARAMETER MailServerSender
        Mail Server. Product setting MailServerSettings.Sender. Name inferred from the export, not yet proven.

    .PARAMETER MailServerUser
        Mail Server. Product setting MailServerSettings.User. Name inferred from the export, not yet proven.

    .PARAMETER MailServerOAuth2ClientId
        Mail Server. Product setting MailServerSettings.OAuth2ClientId. Name inferred from the export, not yet proven.

    .PARAMETER MailServerOAuth2TenantId
        Mail Server. Product setting MailServerSettings.OAuth2TenantId. Name inferred from the export, not yet proven.

    .PARAMETER MailServerOAuth2RedirectUri
        Mail Server. Product setting MailServerSettings.OAuth2RedirectUri. Name inferred from the export, not yet proven.

    .PARAMETER MailServerOAuth2Provider
        Mail Server. Product setting MailServerSettings.OAuth2Provider. Name inferred from the export, not yet proven.

    .PARAMETER MailServerOAuth2Sender
        Mail Server. Product setting MailServerSettings.OAuth2Sender. Name inferred from the export, not yet proven.

    .PARAMETER MailServerMSGraphAPIClientId
        Mail Server. Product setting MailServerSettings.MSGraphAPIClientId. Name inferred from the export, not yet proven.

    .PARAMETER MailServerMSGraphAPITenantId
        Mail Server. Product setting MailServerSettings.MSGraphAPITenantId. Name inferred from the export, not yet proven.

    .PARAMETER MailServerMSGraphAPICloudHostUrl
        Mail Server. Product setting MailServerSettings.MSGraphAPICloudHostUrl. Name inferred from the export, not yet proven.

    .PARAMETER MailServerMSGraphAPISender
        Mail Server. Product setting MailServerSettings.MSGraphAPISender. Name inferred from the export, not yet proven.

    .PARAMETER PerformanceBandwidthLimitPercent
        Performance. Product setting PerformanceSettings.BandwidthLimitPercent. Name inferred from the export, not yet proven.

    .PARAMETER PerformanceCopyMode
        Performance. Product setting PerformanceSettings.CopyMode.

    .PARAMETER PerformanceMaxDeploymentThreads
        Performance. Product setting PerformanceSettings.MaxDeploymentThreads.

    .PARAMETER PerformanceMaxServerThreads
        Performance. Product setting PerformanceSettings.MaxServerThreads. Name inferred from the export, not yet proven.

    .PARAMETER PerformanceCredentialBatchSize
        Performance. Product setting PerformanceSettings.CredentialBatchSize. Name inferred from the export, not yet proven.

    .PARAMETER PerformanceIntegrationMessageTimeoutSeconds
        Performance. Product setting PerformanceSettings.IntegrationMessageTimeoutSeconds. Name inferred from the export, not yet proven.

    .PARAMETER ProxyHostName
        Proxy. Product setting ProxySettings.HostName. Name inferred from the export, not yet proven.

    .PARAMETER ProxyPort
        Proxy. Product setting ProxySettings.Port.

    .PARAMETER ProxyUserName
        Proxy. Product setting ProxySettings.UserName. Name inferred from the export, not yet proven.

    .PARAMETER ProxyUseSystemHost
        Proxy. Product setting ProxySettings.UseSystemHost. Name inferred from the export, not yet proven.

    .PARAMETER RepositoryEnableUnusedFilesWarning
        Repository. Product setting RepositorySettings.EnableUnusedFilesWarning.

    .PARAMETER RepositoryExclusions
        Repository. Product setting RepositorySettings.Exclusions. Name inferred from the export, not yet proven.

    .PARAMETER RepositoryPath
        Repository. Product setting RepositorySettings.Path. Written to the product database, not the command line; see DATABASE_SETTINGS.

    .PARAMETER SpiceworksHostName
        Spiceworks. Product setting SpiceworksSettings.HostName. Name inferred from the export, not yet proven.

    .PARAMETER SpiceworksIsEnabled
        Spiceworks. Product setting SpiceworksSettings.IsEnabled. Name inferred from the export, not yet proven.

    .PARAMETER SpiceworksPort
        Spiceworks. Product setting SpiceworksSettings.Port.

    .PARAMETER SpiceworksSyncInterval
        Spiceworks. Product setting SpiceworksSettings.SyncInterval. Name inferred from the export, not yet proven.

    .PARAMETER SpiceworksUserName
        Spiceworks. Product setting SpiceworksSettings.UserName. Name inferred from the export, not yet proven.

    .PARAMETER SpiceworksUseSSL
        Spiceworks. Product setting SpiceworksSettings.UseSSL. Name inferred from the export, not yet proven.

    .PARAMETER TargetServiceRemoteDirectory
        Target Service. Product setting TargetServiceSettings.RemoteDirectory.

    .PARAMETER TargetServiceSharePath
        Target Service. Product setting TargetServiceSettings.SharePath. Name inferred from the export, not yet proven.

    .PARAMETER AnalyticsCollectAnalyticsUsage
        Analytics. Product setting AnalyticsSettings.CollectAnalyticsUsage.

    .PARAMETER AnalyticsAlertFirstTimeAnalyticsDialog
        Analytics. Product setting AnalyticsSettings.AlertFirstTimeAnalyticsDialog.

    .EXAMPLE
        .\Set-PdqSetting.ps1 -DeploymentCleanupDays 45 -PerformanceCopyMode 'Pull'

    .OUTPUTS
        One object carrying applied, unchanged, ignored, changed and msg.
#>

[CmdletBinding()]
[OutputType([System.Void])]
Param (
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
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $PackageLibraryAutoDeployDefaultApprovalMode,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $PackageLibraryAutoDeployDefaultDelayedApprovalTimeSpan,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $PackageLibraryAutoDeployDefaultIsEnabled,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $PackageLibraryAutoDownloadArchiveCopiesToKeep,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $PackageLibraryAutoDownloadArchiveIsArchiving,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $DatabaseDatabaseBackupBackupDirectory,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $DatabaseDatabaseBackupCompress,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $DatabaseDatabaseBackupIsEnabled,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $DatabaseDatabaseBackupKeep,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $DeploymentCleanupDays,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $DeploymentComputerTimeout,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $DeploymentInventoryScanProfileId,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $DeploymentRunAs,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $DeploymentScanAfterDeployment,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $DeploymentOfflineRetryMaxTries,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $DeploymentOfflineUsePing,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $DeploymentOfflineTryWol,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $DeploymentOfflineIsRetryEnabled,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $DeploymentOfflineRetryInterval,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $LoggingSentryCanSendAnonymousExceptionData,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $LoggingAuditLogMinDaysRecordsKept,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $LoggingAuditLogMaxDaysRecordsKept,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $LoggingAuditLogMinNumArchivedFiles,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $LoggingAuditLogMaxNumArchivedFiles,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $LoggingAuditLogVerboseFileName,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $LoggingAuditLogDaysRecordsKept,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $LoggingAuditLogWriteVerboseFile,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $LoggingAuditLogLoadCustomConfig,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $LoggingAuditLogVerboseFileDirectory,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $LoggingAuditLogCustomConfigPath,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $LoggingAuditLogNumArchivedFiles,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $LoggingAuditLogArchiveSchedule,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $MailServerEnableSSL,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerHost,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerSender,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerUser,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerOAuth2ClientId,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerOAuth2TenantId,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerOAuth2RedirectUri,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerOAuth2Provider,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerOAuth2Sender,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerMSGraphAPIClientId,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerMSGraphAPITenantId,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerMSGraphAPICloudHostUrl,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $MailServerMSGraphAPISender,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $PerformanceBandwidthLimitPercent,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateSet('Push', 'Pull')]
  [System.String]
  $PerformanceCopyMode,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $PerformanceMaxDeploymentThreads,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $PerformanceMaxServerThreads,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $PerformanceCredentialBatchSize,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $PerformanceIntegrationMessageTimeoutSeconds,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $ProxyHostName,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $ProxyPort,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $ProxyUserName,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $ProxyUseSystemHost,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $RepositoryEnableUnusedFilesWarning,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $RepositoryExclusions,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $RepositoryPath,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $SpiceworksHostName,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $SpiceworksIsEnabled,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Int32]
  $SpiceworksPort,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $SpiceworksSyncInterval,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $SpiceworksUserName,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $SpiceworksUseSSL,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $TargetServiceRemoteDirectory,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $TargetServiceSharePath,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $AnalyticsCollectAnalyticsUsage,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $AnalyticsAlertFirstTimeAnalyticsDialog
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# The product's command line, and where its export is staged. Both are fixed,
# not offered: the installer ignores every documented way to relocate the
# product -- INSTALLLOCATION, APPLICATIONFOLDER and /p were each measured
# accepted and ignored on 2026-08-18 -- so a path parameter would advertise a
# choice that does not exist.
New-Variable -Force -Name:'CLI_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
)
New-Variable -Force -Name:'EXPORT_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Windows\Temp\pdq-settings-export.xml'
)

# The product ships the sqlite tool it uses on its own database.
New-Variable -Force -Name:'SQLITE_PATH' -Option:('Private', 'ReadOnly') -Value:(
  [System.String]'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
)

# A few settings are system VARIABLES rather than settings, and the command line has no surface
# for built-in ones: its variable commands carry custom variables only, which is why exporting
# them on a host with thirteen system variables reports none found. Measured 2026-08-20, writing
# the row directly is honoured with the service running and takes effect at once. Mapped here
# rather than special-cased in the flow, so the difference is one row of data.
New-Variable -Force -Name:'DATABASE_SETTINGS' -Option:('Private', 'ReadOnly') -Value:(
  [System.Collections.Hashtable]@{
    'RepositorySettings.Path' = 'Repository'
  }
)

# Each parameter names one product setting. The product spells them with a dot
# and a section that sometimes carries a view model; the parameters do not, so
# the two are joined here rather than derived by a rule that would eventually
# meet a name that breaks it. Adding a setting is a parameter and a row.
New-Variable -Force -Name:'SETTING_NAMES' -Option:('Private', 'ReadOnly') -Value:(
  [System.Collections.Hashtable]@{
    'PackageLibraryAutoDeployDefaultApprovalMode'            = 'AutoDeployDefaultSettings.ApprovalMode'
    'PackageLibraryAutoDeployDefaultDelayedApprovalTimeSpan' = 'AutoDeployDefaultSettings.DelayedApprovalTimeSpan'
    'PackageLibraryAutoDeployDefaultIsEnabled'               = 'AutoDeployDefaultSettings.IsEnabled'
    'PackageLibraryAutoDownloadArchiveCopiesToKeep'          = 'AutoDownloadArchiveSettings.CopiesToKeep'
    'PackageLibraryAutoDownloadArchiveIsArchiving'           = 'AutoDownloadArchiveSettings.IsArchiving'
    'DatabaseDatabaseBackupBackupDirectory'                  = 'DatabaseBackupSettings.BackupDirectory'
    'DatabaseDatabaseBackupCompress'                         = 'DatabaseBackupSettings.Compress'
    'DatabaseDatabaseBackupIsEnabled'                        = 'DatabaseBackupSettings.IsEnabled'
    'DatabaseDatabaseBackupKeep'                             = 'DatabaseBackupSettings.Keep'
    'DeploymentCleanupDays'                                  = 'DeploymentSettings.CleanupDays'
    'DeploymentComputerTimeout'                              = 'DeploymentSettings.ComputerTimeout'
    'DeploymentInventoryScanProfileId'                       = 'DeploymentSettings.InventoryScanProfileId'
    'DeploymentRunAs'                                        = 'DeploymentSettings.RunAs'
    'DeploymentScanAfterDeployment'                          = 'DeploymentSettings.ScanAfterDeployment'
    'DeploymentOfflineRetryMaxTries'                         = 'OfflineSettings.RetryMaxTries'
    'DeploymentOfflineUsePing'                               = 'OfflineSettings.UsePing'
    'DeploymentOfflineTryWol'                                = 'OfflineSettings.TryWol'
    'DeploymentOfflineIsRetryEnabled'                        = 'OfflineSettings.IsRetryEnabled'
    'DeploymentOfflineRetryInterval'                         = 'OfflineSettings.RetryInterval'
    'LoggingSentryCanSendAnonymousExceptionData'             = 'SentrySettings.CanSendAnonymousExceptionData'
    'LoggingAuditLogMinDaysRecordsKept'                      = 'AuditLogSettings.MinDaysRecordsKept'
    'LoggingAuditLogMaxDaysRecordsKept'                      = 'AuditLogSettings.MaxDaysRecordsKept'
    'LoggingAuditLogMinNumArchivedFiles'                     = 'AuditLogSettings.MinNumArchivedFiles'
    'LoggingAuditLogMaxNumArchivedFiles'                     = 'AuditLogSettings.MaxNumArchivedFiles'
    'LoggingAuditLogVerboseFileName'                         = 'AuditLogSettings.VerboseFileName'
    'LoggingAuditLogDaysRecordsKept'                         = 'AuditLogSettings.DaysRecordsKept'
    'LoggingAuditLogWriteVerboseFile'                        = 'AuditLogSettings.WriteVerboseFile'
    'LoggingAuditLogLoadCustomConfig'                        = 'AuditLogSettings.LoadCustomConfig'
    'LoggingAuditLogVerboseFileDirectory'                    = 'AuditLogSettings.VerboseFileDirectory'
    'LoggingAuditLogCustomConfigPath'                        = 'AuditLogSettings.CustomConfigPath'
    'LoggingAuditLogNumArchivedFiles'                        = 'AuditLogSettings.NumArchivedFiles'
    'LoggingAuditLogArchiveSchedule'                         = 'AuditLogSettings.ArchiveSchedule'
    'MailServerEnableSSL'                                    = 'MailServerSettings.EnableSSL'
    'MailServerHost'                                         = 'MailServerSettings.Host'
    'MailServerSender'                                       = 'MailServerSettings.Sender'
    'MailServerUser'                                         = 'MailServerSettings.User'
    'MailServerOAuth2ClientId'                               = 'MailServerSettings.OAuth2ClientId'
    'MailServerOAuth2TenantId'                               = 'MailServerSettings.OAuth2TenantId'
    'MailServerOAuth2RedirectUri'                            = 'MailServerSettings.OAuth2RedirectUri'
    'MailServerOAuth2Provider'                               = 'MailServerSettings.OAuth2Provider'
    'MailServerOAuth2Sender'                                 = 'MailServerSettings.OAuth2Sender'
    'MailServerMSGraphAPIClientId'                           = 'MailServerSettings.MSGraphAPIClientId'
    'MailServerMSGraphAPITenantId'                           = 'MailServerSettings.MSGraphAPITenantId'
    'MailServerMSGraphAPICloudHostUrl'                       = 'MailServerSettings.MSGraphAPICloudHostUrl'
    'MailServerMSGraphAPISender'                             = 'MailServerSettings.MSGraphAPISender'
    'PerformanceBandwidthLimitPercent'                       = 'PerformanceSettings.BandwidthLimitPercent'
    'PerformanceCopyMode'                                    = 'PerformanceSettings.CopyMode'
    'PerformanceMaxDeploymentThreads'                        = 'PerformanceSettings.MaxDeploymentThreads'
    'PerformanceMaxServerThreads'                            = 'PerformanceSettings.MaxServerThreads'
    'PerformanceCredentialBatchSize'                         = 'PerformanceSettings.CredentialBatchSize'
    'PerformanceIntegrationMessageTimeoutSeconds'            = 'PerformanceSettings.IntegrationMessageTimeoutSeconds'
    'ProxyHostName'                                          = 'ProxySettings.HostName'
    'ProxyPort'                                              = 'ProxySettings.Port'
    'ProxyUserName'                                          = 'ProxySettings.UserName'
    'ProxyUseSystemHost'                                     = 'ProxySettings.UseSystemHost'
    'RepositoryEnableUnusedFilesWarning'                     = 'RepositorySettings.EnableUnusedFilesWarning'
    'RepositoryExclusions'                                   = 'RepositorySettings.Exclusions'
    'RepositoryPath'                                         = 'RepositorySettings.Path'
    'SpiceworksHostName'                                     = 'SpiceworksSettings.HostName'
    'SpiceworksIsEnabled'                                    = 'SpiceworksSettings.IsEnabled'
    'SpiceworksPort'                                         = 'SpiceworksSettings.Port'
    'SpiceworksSyncInterval'                                 = 'SpiceworksSettings.SyncInterval'
    'SpiceworksUserName'                                     = 'SpiceworksSettings.UserName'
    'SpiceworksUseSSL'                                       = 'SpiceworksSettings.UseSSL'
    'TargetServiceRemoteDirectory'                           = 'TargetServiceSettings.RemoteDirectory'
    'TargetServiceSharePath'                                 = 'TargetServiceSettings.SharePath'
    'AnalyticsCollectAnalyticsUsage'                         = 'AnalyticsSettings.CollectAnalyticsUsage'
    'AnalyticsAlertFirstTimeAnalyticsDialog'                 = 'AnalyticsSettings.AlertFirstTimeAnalyticsDialog'
  }
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

# Only the parameters the caller actually passed are managed: an unbound one is
# a setting this deployment does not speak to, which is different from one it
# wants left at the default. The Ansible side expresses that with omit.
$Setting = @{}
ForEach ($Bound In @($PSBoundParameters.Keys)) {
  If ($SETTING_NAMES.ContainsKey($Bound)) {
    $Given = $PSBoundParameters[$Bound]
    # The export writes booleans lower case, so the comparison is made in the
    # product's spelling rather than PowerShell's.
    $Setting[$SETTING_NAMES[$Bound]] = If ($Given -is [System.Boolean]) {
      ([System.String]$Given).ToLowerInvariant()
    } Else {
      [System.String]$Given
    }
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
        If ($DATABASE_SETTINGS.ContainsKey($Name)) {
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
            $DATABASE_SETTINGS[$Name].Replace("'", "''")
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
