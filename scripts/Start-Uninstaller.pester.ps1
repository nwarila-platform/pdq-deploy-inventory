#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Start-Uninstaller.ps1. The registry and process launcher
    are modeled in memory so the Windows-only behavior runs under bare Pester
    on any development host. Both uninstall roots remain owned by the script;
    the spec replaces only the platform cmdlets that are unavailable off
    Windows.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Start-Uninstaller.ps1'
  $script:Native = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  $script:Wow = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  $script:User = 'HKU:\S-1-5-21\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  $script:ProductCode = '{23170F69-40C1-2702-2602-000001000000}'
  $global:StartUninstallerNative = $script:Native
  $global:StartUninstallerWow = $script:Wow

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Function Add-FakeRegistration {
    Param (
      [Parameter(Mandatory = $True)]
      [System.String]
      $Root,

      [Parameter(Mandatory = $True)]
      [System.Collections.Hashtable]
      $Registration
    )

    $global:StartUninstallerRegistry[$Root] = @(
      $global:StartUninstallerRegistry[$Root]
      $Registration
    )
  }

  Function Test-Path {
    [CmdletBinding()]
    Param (
      [Parameter(ValueFromPipeline = $True)]
      [System.Object]
      $Path,

      [Parameter()]
      [System.String]
      $LiteralPath
    )

    If ($LiteralPath -and $LiteralPath.StartsWith('HKLM:')) {
      Return $global:StartUninstallerRegistry.Contains($LiteralPath)
    }
    Return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
  }

  Function Get-ChildItem {
    [CmdletBinding()]
    Param (
      [Parameter(ValueFromPipeline = $True)]
      [System.Object]
      $Path,

      [Parameter()]
      [System.String]
      $LiteralPath
    )

    If ($LiteralPath -and $LiteralPath.StartsWith('HKLM:')) {
      $global:StartUninstallerReadRoots.Add($LiteralPath)
      If ($global:StartUninstallerDeniedRoot -eq $LiteralPath) {
        Throw ('Registry access denied: {0}' -f $LiteralPath)
      }
      If (-not $global:StartUninstallerRegistry.Contains($LiteralPath)) {
        Return @()
      }
      Return @(
        ForEach ($Registration In @($global:StartUninstallerRegistry[$LiteralPath])) {
          [PSCustomObject]@{
            PSChildName = [System.String]$Registration.PSChildName
            PSPath      = '{0}##{1}' -f $LiteralPath, $Registration.PSChildName
          }
        }
      )
    }
    Return Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
  }

  Function Get-ItemProperty {
    [CmdletBinding()]
    Param (
      [Parameter(ValueFromPipeline = $True)]
      [System.Object]
      $Path,

      [Parameter()]
      [System.String]
      $LiteralPath
    )

    If ($LiteralPath -and $LiteralPath.StartsWith('HKLM:')) {
      $Parts = $LiteralPath -split '##', 2
      $Registration = @($global:StartUninstallerRegistry[$Parts[0]]) |
        Where-Object { $PSItem.PSChildName -eq $Parts[1] } |
        Select-Object -First 1
      Return [PSCustomObject]$Registration
    }
    Return Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
  }

  Function Start-Process {
    [CmdletBinding()]
    Param (
      [Parameter()]
      [System.String[]]
      $ArgumentList,

      [Parameter(Mandatory = $True)]
      [System.String]
      $FilePath,

      [Parameter()]
      [Switch]
      $PassThru,

      [Parameter()]
      [Switch]
      $Wait
    )

    $global:StartUninstallerProcessCalls.Add([PSCustomObject]@{
        ArgumentList = [System.String]($ArgumentList -join ' ')
        FilePath     = $FilePath
      })

    If (
      -not $global:StartUninstallerPersistRegistration -and
      $global:StartUninstallerRemovalExitCode -contains $global:StartUninstallerExitCode
    ) {
      ForEach ($Root In @($global:StartUninstallerNative, $global:StartUninstallerWow)) {
        $Remaining = [System.Collections.Generic.List[System.Object]]::new()
        $RemovedOne = $False
        ForEach ($Registration In @($global:StartUninstallerRegistry[$Root])) {
          $Quiet = If ($Registration.Contains('QuietUninstallString')) {
            [System.String]$Registration.QuietUninstallString
          } Else {
            [System.String]::Empty
          }
          $Uninstall = If ($Registration.Contains('UninstallString')) {
            [System.String]$Registration.UninstallString
          } Else {
            [System.String]::Empty
          }
          $MatchesExecutable = (
            $Quiet.IndexOf($FilePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $Uninstall.IndexOf($FilePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
          )
          If (-not $RemovedOne -and $MatchesExecutable) {
            $RemovedOne = $True
          } Else {
            $Remaining.Add($Registration)
          }
        }
        $global:StartUninstallerRegistry[$Root] = $Remaining.ToArray()
      }
    }

    [PSCustomObject]@{ ExitCode = $global:StartUninstallerExitCode }
  }
}

AfterAll {
  Remove-Variable -Name @(
    'StartUninstallerDeniedRoot'
    'StartUninstallerExitCode'
    'StartUninstallerNative'
    'StartUninstallerPersistRegistration'
    'StartUninstallerProcessCalls'
    'StartUninstallerReadRoots'
    'StartUninstallerRegistry'
    'StartUninstallerRemovalExitCode'
    'StartUninstallerWow'
  ) -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Start-Uninstaller' {
  BeforeEach {
    $global:StartUninstallerRegistry = [Ordered]@{
      $script:Native = @(
        @{
          DisplayName     = '7-Zip 26.02 (x64 edition)'
          DisplayVersion  = '26.02.00.0'
          PSChildName     = $script:ProductCode
          UninstallString = 'MsiExec.exe /X{23170F69-40C1-2702-2602-000001000000}'
        },
        @{
          DisplayName = 'Unrelated Product'
          PSChildName = 'Unrelated'
        }
      )
      $script:Wow = @()
      $script:User = @(
        @{
          DisplayName = '7-Zip 26.02 (x64)'
          PSChildName = 'PerUser7Zip'
        }
      )
    }
    $global:StartUninstallerDeniedRoot = [System.String]::Empty
    $global:StartUninstallerExitCode = 0
    $global:StartUninstallerPersistRegistration = $False
    $global:StartUninstallerProcessCalls = [System.Collections.Generic.List[System.Object]]::new()
    $global:StartUninstallerReadRoots = [System.Collections.Generic.List[System.String]]::new()
    $global:StartUninstallerRemovalExitCode = @(0, 1641, 3010)
  }

  AfterEach {
    Remove-AnsibleContext
  }

  Context 'standalone transport' {
    It 'reports NoChange when only the conforming MSI is present' {
      $Json = & $script:ScriptPath -DisplayNamePattern '7-Zip*'
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeFalse
      $Result.removed | Should -HaveCount 0
      $Result.retained | Should -HaveCount 1
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'removes quiet and fallback registrations from both roots and retains the MSI' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip 26.02 (x64)'
        PSChildName          = '7-Zip'
        QuietUninstallString = '"C:\Program Files\7-Zip\Uninstall.exe" /S'
      }
      Add-FakeRegistration -Root $script:Wow -Registration @{
        DisplayName     = '7-Zip 25.01 (x86)'
        PSChildName     = '7-Zip-legacy'
        UninstallString = 'C:\Legacy\uninstall.exe /remove'
      }

      $Json = & $script:ScriptPath -DisplayNamePattern '7-Zip*' -SilentSwitch '/S'
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeTrue
      $Result.removed | Should -HaveCount 2
      $Result.retained | Should -HaveCount 1
      $Result.survived | Should -HaveCount 0
      $global:StartUninstallerProcessCalls | Should -HaveCount 2
      $QuietCall = $global:StartUninstallerProcessCalls |
        Where-Object { $PSItem.FilePath -eq 'C:\Program Files\7-Zip\Uninstall.exe' }
      $FallbackCall = $global:StartUninstallerProcessCalls |
        Where-Object { $PSItem.FilePath -eq 'C:\Legacy\uninstall.exe' }
      $QuietCall.ArgumentList | Should -Be '/S'
      $FallbackCall.ArgumentList | Should -Be '/remove /S'
      @($global:StartUninstallerRegistry[$script:Native]).DisplayName | Should -Contain 'Unrelated Product'
      @($global:StartUninstallerRegistry[$script:User]) | Should -HaveCount 1
      $global:StartUninstallerReadRoots | Should -Not -Contain $script:User
    }

    It 'refuses a bare interactive uninstall string when no silent switch is supplied' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName     = '7-Zip 26.02 (x64)'
        PSChildName     = '7-Zip'
        UninstallString = '"C:\Program Files\7-Zip\Uninstall.exe"'
      }

      $Json = & $script:ScriptPath -DisplayNamePattern '7-Zip*'
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.changed | Should -BeFalse
      $Result.survived | Should -HaveCount 1
      $Result.failures[0] | Should -Match 'refusing the interactive uninstall command'
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'treats a bare GUID key as non-conforming because only the braced ProductCode form qualifies' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip 26.02 (x64)'
        PSChildName          = '23170F69-40C1-2702-2602-000001000000'
        QuietUninstallString = '"C:\Program Files\7-Zip\Uninstall.exe" /S'
      }

      $Json = & $script:ScriptPath -DisplayNamePattern '7-Zip*'
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be '23170F69-40C1-2702-2602-000001000000'
      $Result.retained.key_name | Should -Be $script:ProductCode
    }

    It 'fails on a real non-success exit code and reports the surviving registration' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip 26.02 (x64)'
        PSChildName          = '7-Zip'
        QuietUninstallString = '"C:\Program Files\7-Zip\Uninstall.exe" /S'
      }
      $global:StartUninstallerExitCode = 5

      $Json = & $script:ScriptPath -DisplayNamePattern '7-Zip*'
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.failures[0] | Should -Match 'unaccepted code 5'
      $Result.survived | Should -HaveCount 1
    }

    It 'fails verification when an exit-zero uninstaller leaves its registration behind' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip 26.02 (x64)'
        PSChildName          = '7-Zip'
        QuietUninstallString = '"C:\Program Files\7-Zip\Uninstall.exe" /S'
      }
      $global:StartUninstallerPersistRegistration = $True

      $Json = & $script:ScriptPath -DisplayNamePattern '7-Zip*'
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.changed | Should -BeFalse
      $Result.failures | Should -HaveCount 0
      $Result.survived | Should -HaveCount 1
      $Result.msg | Should -Match 'did not converge'
    }

    It 'fails closed when either uninstall root cannot be read' {
      $global:StartUninstallerDeniedRoot = $script:Wow

      { & $script:ScriptPath -DisplayNamePattern '7-Zip*' 2>$Null } |
        Should -Throw '*Registry access denied*'
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'rejects a whitespace family pattern before starting a process' {
      { & $script:ScriptPath -DisplayNamePattern '   ' 2>$Null } |
        Should -Throw '*must contain a non-whitespace wildcard pattern*'
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }
  }

  Context '$Ansible transport' {
    It 'honors check mode with a full read and no process start' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip 26.02 (x64)'
        PSChildName          = '7-Zip'
        QuietUninstallString = '"C:\Program Files\7-Zip\Uninstall.exe" /S'
      }
      $Context = New-AnsibleContext -CheckMode

      $Emitted = & $script:ScriptPath -DisplayNamePattern '7-Zip*'

      $Emitted | Should -BeNullOrEmpty
      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeFalse
      $Context.Result.check_mode | Should -BeTrue
      $Context.Result.survived | Should -HaveCount 1
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'reports Change only after a fresh read proves removal' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip 26.02 (x64)'
        PSChildName          = '7-Zip'
        QuietUninstallString = '"C:\Program Files\7-Zip\Uninstall.exe" /S'
      }
      $Context = New-AnsibleContext

      $Emitted = & $script:ScriptPath -DisplayNamePattern '7-Zip*'

      $Emitted | Should -BeNullOrEmpty
      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeFalse
      $Context.Result.removed | Should -HaveCount 1
      $Context.Result.survived | Should -HaveCount 0
    }
  }
}
