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
  $script:ScriptPath = If ([System.String]::IsNullOrWhiteSpace(
      $env:START_UNINSTALLER_SOURCE_UNDER_TEST
    )) {
    Join-Path -Path $PSScriptRoot -ChildPath 'Start-Uninstaller.ps1'
  } Else {
    $env:START_UNINSTALLER_SOURCE_UNDER_TEST
  }
  $script:Native = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  $script:Wow = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  $script:User = 'HKU:\S-1-5-21\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  $script:ProductCode = '{23170F69-40C1-2702-2602-000001000000}'
  $script:WrongProductCode = '{00000000-0000-0000-0000-000000000000}'
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
      If ($LiteralPath.Contains('##')) {
        $Parts = $LiteralPath -split '##', 2
        If (-not $global:StartUninstallerRegistry.Contains($Parts[0])) {
          Return $False
        }
        Return @(
          $global:StartUninstallerRegistry[$Parts[0]] |
            Where-Object { $PSItem.PSChildName -eq $Parts[1] }
        ).Count -gt 0
      }
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
        $ProductCodeMatch = [System.Text.RegularExpressions.Regex]::Match(
          [System.String]($ArgumentList -join ' '),
          '\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}'
        )
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
          $MatchesProductCode = (
            $ProductCodeMatch.Success -and
            [System.String]$Registration.PSChildName -ieq $ProductCodeMatch.Value
          )
          $RemovesCollateral = (
            $global:StartUninstallerCollateralRemoval -contains
            [System.String]$Registration.PSChildName
          )
          If (
            (-not $RemovedOne -and ($MatchesExecutable -or $MatchesProductCode)) -or
            $RemovesCollateral
          ) {
            If ($MatchesExecutable -or $MatchesProductCode) {
              $RemovedOne = $True
            }
          } Else {
            $Remaining.Add($Registration)
          }
        }
        $global:StartUninstallerRegistry[$Root] = $Remaining.ToArray()
      }
      If ($Null -ne $global:StartUninstallerReplacementRegistration) {
        Add-FakeRegistration `
          -Root $global:StartUninstallerNative `
          -Registration $global:StartUninstallerReplacementRegistration
        $global:StartUninstallerReplacementRegistration = $Null
      }
    }

    If (
      $Null -ne $global:StartUninstallerSurvivorMutation -and
      $global:StartUninstallerRemovalExitCode -contains $global:StartUninstallerExitCode
    ) {
      ForEach ($Root In @($global:StartUninstallerNative, $global:StartUninstallerWow)) {
        ForEach ($Registration In @($global:StartUninstallerRegistry[$Root])) {
          If (
            [System.String]$Registration.PSChildName -eq
            [System.String]$global:StartUninstallerSurvivorMutation.PSChildName
          ) {
            ForEach ($Entry In $global:StartUninstallerSurvivorMutation.Values.GetEnumerator()) {
              $Registration[$Entry.Key] = $Entry.Value
            }
          }
        }
      }
    }

    [PSCustomObject]@{ ExitCode = $global:StartUninstallerExitCode }
  }
}

AfterAll {
  Remove-Variable -Name @(
    'StartUninstallerDeniedRoot'
    'StartUninstallerCollateralRemoval'
    'StartUninstallerExitCode'
    'StartUninstallerNative'
    'StartUninstallerPersistRegistration'
    'StartUninstallerProcessCalls'
    'StartUninstallerReadRoots'
    'StartUninstallerRegistry'
    'StartUninstallerReplacementRegistration'
    'StartUninstallerRemovalExitCode'
    'StartUninstallerSurvivorMutation'
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
    $global:StartUninstallerCollateralRemoval = @()
    $global:StartUninstallerExitCode = 0
    $global:StartUninstallerPersistRegistration = $False
    $global:StartUninstallerProcessCalls = [System.Collections.Generic.List[System.Object]]::new()
    $global:StartUninstallerReadRoots = [System.Collections.Generic.List[System.String]]::new()
    $global:StartUninstallerReplacementRegistration = $Null
    $global:StartUninstallerRemovalExitCode = @(0, 1641, 3010)
    $global:StartUninstallerSurvivorMutation = $Null
  }

  AfterEach {
    Remove-AnsibleContext
  }

  Context 'selector contract' -Tag 'WatchedFailure' {
    It 'uses Exact for the Chrome family without selecting adjacent or localized names' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Google Chrome'
          PSChildName          = 'Chrome'
          QuietUninstallString = 'C:\Chrome\uninstall.exe --silent'
        },
        @{
          DisplayName          = 'google chrome'
          PSChildName          = 'ChromeCaseVariant'
          QuietUninstallString = 'C:\ChromeCase\uninstall.exe --silent'
        },
        @{
          DisplayName          = 'Google Chrome Beta'
          PSChildName          = 'ChromeBeta'
          QuietUninstallString = 'C:\ChromeBeta\uninstall.exe --silent'
        },
        @{
          DisplayName          = 'Google Chrome for Testing'
          PSChildName          = 'ChromeTesting'
          QuietUninstallString = 'C:\ChromeTesting\uninstall.exe --silent'
        },
        @{
          DisplayName          = 'Google Chrome (français)'
          PSChildName          = 'ChromeLocalized'
          QuietUninstallString = 'C:\ChromeLocalized\uninstall.exe --silent'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = 'Google Chrome' } `
        -MaxRemovals 2
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed | Should -HaveCount 2
      $Result.removed.key_name | Should -Contain 'Chrome'
      $Result.removed.key_name | Should -Contain 'ChromeCaseVariant'
      @($global:StartUninstallerRegistry[$script:Native]).PSChildName |
        Should -Contain 'ChromeBeta'
      @($global:StartUninstallerRegistry[$script:Native]).PSChildName |
        Should -Contain 'ChromeTesting'
      @($global:StartUninstallerRegistry[$script:Native]).PSChildName |
        Should -Contain 'ChromeLocalized'
      $global:StartUninstallerProcessCalls | Should -HaveCount 2
    }

    It 'uses Simple for native WOW and MSI 7-Zip registration forms' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = '7-Zip 26.02 (x64)'
          PSChildName          = 'Native7Zip'
          QuietUninstallString = 'C:\Native7Zip\uninstall.exe /S'
        },
        @{
          DisplayName     = '7-Zip 26.02 (x64 edition)'
          PSChildName     = $script:ProductCode
          UninstallString = 'MsiExec.exe /X{23170F69-40C1-2702-2602-000001000000}'
        }
      )
      $global:StartUninstallerRegistry[$script:Wow] = @(
        @{
          DisplayName          = '7-Zip 25.01 (x86)'
          PSChildName          = 'Wow7Zip'
          QuietUninstallString = 'C:\Wow7Zip\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -MaxRemovals 3 `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed | Should -HaveCount 3
      $Result.removed.key_name | Should -Contain 'Native7Zip'
      $Result.removed.key_name | Should -Contain 'Wow7Zip'
      $Result.removed.key_name | Should -Contain $script:ProductCode
      $global:StartUninstallerProcessCalls | Should -HaveCount 3
    }

    It 'uses an anchored Regex family for ESR and maintenance without selecting release' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Mozilla Firefox ESR (x64 en-US)'
          PSChildName          = 'FirefoxEsr'
          QuietUninstallString = 'C:\FirefoxEsr\helper.exe /S'
        },
        @{
          DisplayName          = 'Mozilla Maintenance Service'
          PSChildName          = 'MozillaMaintenance'
          QuietUninstallString = 'C:\MozillaMaintenance\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Mozilla Firefox (x64 en-US)'
          PSChildName          = 'FirefoxRelease'
          QuietUninstallString = 'C:\FirefoxRelease\helper.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{
          Method = 'Regex'
          Query  = '^(?:Mozilla Firefox ESR \(x64 en-US\)|Mozilla Maintenance Service)$'
        } `
        -MaxRemovals 2
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Contain 'FirefoxEsr'
      $Result.removed.key_name | Should -Contain 'MozillaMaintenance'
      @($global:StartUninstallerRegistry[$script:Native]).PSChildName |
        Should -Contain 'FirefoxRelease'
      $global:StartUninstallerProcessCalls | Should -HaveCount 2
    }

    It 'requires every filter tuple to match' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Scoped Product selected'
          DisplayVersion       = '2.4.1'
          PSChildName          = 'SelectedProduct'
          Publisher            = 'Scoped Publisher'
          QuietUninstallString = 'C:\Selected\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Scoped Product wrong version'
          DisplayVersion       = '1.9.0'
          PSChildName          = 'WrongVersion'
          Publisher            = 'Scoped Publisher'
          QuietUninstallString = 'C:\WrongVersion\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Scoped Product wrong publisher'
          DisplayVersion       = '2.4.1'
          PSChildName          = 'WrongPublisher'
          Publisher            = 'Other Publisher'
          QuietUninstallString = 'C:\WrongPublisher\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Scoped Product*' } `
        -Filter @(
          @{ Property = 'Publisher'; Method = 'Exact'; Query = 'Scoped Publisher' }
          @{ Property = 'DisplayVersion'; Method = 'Regex'; Query = '^2\.' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'SelectedProduct'
      $Result.retained.key_name | Should -Contain 'WrongVersion'
      $Result.retained.key_name | Should -Contain 'WrongPublisher'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'resolves tuple keys methods and duplicate property names case-insensitively' -Tag 'CaseResolutionWatch' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Case Product selected'
          PSChildName          = 'CaseSelected'
          Publisher            = 'Selected Publisher'
          QuietUninstallString = 'C:\CaseSelected\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Case Product retained'
          PSChildName          = 'CaseRetained'
          Publisher            = 'Selected Other'
          QuietUninstallString = 'C:\CaseRetained\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ METHOD = 'simple'; QUERY = 'case product*' } `
        -Filter @(
          @{ PROPERTY = 'publisher'; METHOD = 'SIMPLE'; QUERY = 'selected*' }
          @{ Property = 'PUBLISHER'; Method = 'regex'; Query = '^selected publisher$' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'CaseSelected'
      $Result.retained.key_name | Should -Contain 'CaseRetained'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'lets any matching exclusion beat inclusion' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Excluded Product'
          PSChildName          = 'ExcludedProduct'
          Publisher            = 'Selected Publisher'
          QuietUninstallString = 'C:\Excluded\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = 'Excluded Product' } `
        -Filter @(
          @{ Property = 'Publisher'; Method = 'Simple'; Query = 'Selected*' }
        ) `
        -Exclude @(
          @{ Property = 'Publisher'; Method = 'Exact'; Query = 'Selected Publisher' }
          @{ Property = 'Publisher'; Method = 'Exact'; Query = 'Not This Publisher' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeFalse
      $Result.removed | Should -HaveCount 0
      $Result.retained.key_name | Should -Be 'ExcludedProduct'
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'treats absent and null properties as no match for filters and excludes' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Property Product absent'
          PSChildName          = 'AbsentProperty'
          QuietUninstallString = 'C:\Absent\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Property Product null'
          OptionalValue        = $Null
          PSChildName          = 'NullProperty'
          QuietUninstallString = 'C:\Null\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Property Product selected'
          OptionalValue        = 'Present'
          PSChildName          = 'PresentProperty'
          QuietUninstallString = 'C:\Present\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Property Product*' } `
        -Filter @(
          @{ Property = 'OptionalValue'; Method = 'Simple'; Query = '*' }
        ) `
        -Exclude @(
          @{ Property = 'MissingValue'; Method = 'Simple'; Query = '*' }
          @{ Property = 'OptionalValue'; Method = 'Exact'; Query = 'Never' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'PresentProperty'
      $Result.retained.key_name | Should -Contain 'AbsentProperty'
      $Result.retained.key_name | Should -Contain 'NullProperty'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'converges honestly when a filter property is globally absent' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Absent Product one'
          PSChildName          = 'AbsentOne'
          QuietUninstallString = 'C:\AbsentOne\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Absent Product two'
          PSChildName          = 'AbsentTwo'
          QuietUninstallString = 'C:\AbsentTwo\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Absent Product*' } `
        -Filter @(
          @{ Property = 'NeverPresent'; Method = 'Simple'; Query = '*' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeFalse
      $Result.removed | Should -HaveCount 0
      $Result.retained | Should -HaveCount 2
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'compares DWORD and QWORD values as invariant text' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Numeric Product'
          EstimatedSize        = [System.Int64]4294967296
          PSChildName          = 'NumericProduct'
          QuietUninstallString = 'C:\Numeric\uninstall.exe /S'
          WindowsInstaller     = [System.Int32]1
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = 'Numeric Product' } `
        -Filter @(
          @{ Property = 'WindowsInstaller'; Method = 'Exact'; Query = '1' }
          @{ Property = 'EstimatedSize'; Method = 'Regex'; Query = '^4294967296$' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'NumericProduct'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'resolves synthesized property names case-insensitively' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Synthesized Product'
          PSChildName          = 'SynthesizedKey'
          QuietUninstallString = 'C:\Synthesized\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = 'Synthesized Product' } `
        -Filter @(
          @{ Property = 'parentkey'; Method = 'Exact'; Query = 'synthesizedkey' }
          @{ Property = 'apparch'; Method = 'Regex'; Query = '^x(?:64|86)$' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'SynthesizedKey'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'does not trim queries or admit an empty display name as a registration' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = ' Spaced Product '
          PSChildName          = 'SpacedProduct'
          QuietUninstallString = 'C:\Spaced\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Spaced Product'
          PSChildName          = 'TrimmedProduct'
          QuietUninstallString = 'C:\Trimmed\uninstall.exe /S'
        },
        @{
          DisplayName          = ''
          PSChildName          = 'EmptyName'
          QuietUninstallString = 'C:\Empty\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = ' Spaced Product ' }
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'SpacedProduct'
      @($global:StartUninstallerRegistry[$script:Native]).PSChildName |
        Should -Contain 'TrimmedProduct'
      @($global:StartUninstallerRegistry[$script:Native]).PSChildName |
        Should -Contain 'EmptyName'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }
  }

  Context 'registry-data refusals' -Tag 'WatchedFailure' {
    It 'refuses an unsupported value type after the full family read and before launch' -Tag 'RegistryDataWatch' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          BinaryValue          = [System.Byte[]]@(1, 2)
          DisplayName          = 'Typed Product first'
          PSChildName          = 'TypedFirst'
          Publisher            = 'Other Publisher'
          QuietUninstallString = 'C:\TypedFirst\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Typed Product second'
          MultiValue           = [System.String[]]@('one', 'two')
          PSChildName          = 'TypedSecond'
          Publisher            = 'Selected Publisher'
          QuietUninstallString = 'C:\TypedSecond\uninstall.exe /S'
        },
        @{
          BinaryValue          = [System.Byte[]]@(3, 4)
          DisplayName          = 'Typed Product selected'
          MultiValue           = [System.String[]]@('three', 'four')
          PSChildName          = 'TypedSelected'
          Publisher            = 'Selected Publisher'
          QuietUninstallString = 'C:\TypedSelected\uninstall.exe /S'
        }
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Typed Product*' } `
        -Filter @(
          @{ Property = 'Publisher'; Method = 'Exact'; Query = 'Selected Publisher' }
          @{ Property = 'MultiValue'; Method = 'Simple'; Query = '*' }
          @{ Property = 'BinaryValue'; Method = 'Simple'; Query = '*' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $global:StartUninstallerProcessCalls | Should -HaveCount 0
      $ExitCode | Should -Be 1
      $Result.changed | Should -BeFalse
      $Result.failures -join ' ' | Should -Match 'MultiValue'
      $Result.failures -join ' ' | Should -Match 'Typed Product second'
      $Result.failures -join ' ' | Should -Match 'BinaryValue'
      $Result.failures -join ' ' | Should -Match 'Typed Product first'
      $global:StartUninstallerReadRoots | Should -HaveCount 2
    }

    It 'reports an unsupported value type through the transport in check mode' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Typed Check Product'
          MultiValue           = [System.String[]]@('one', 'two')
          PSChildName          = 'TypedCheck'
          QuietUninstallString = 'C:\TypedCheck\uninstall.exe /S'
        }
      )
      $Context = New-AnsibleContext -CheckMode

      $Emitted = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = 'Typed Check Product' } `
        -Filter @(
          @{ Property = 'MultiValue'; Method = 'Simple'; Query = '*' }
        )

      $Emitted | Should -BeNullOrEmpty
      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeTrue
      $Context.Result.failures[0] | Should -Match 'MultiValue'
      $Context.Result.failures[0] | Should -Match 'Typed Check Product'
      $global:StartUninstallerReadRoots | Should -HaveCount 2
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }
  }

  Context 'selection ceiling' -Tag 'WatchedFailure' {
    BeforeEach {
      $global:StartUninstallerRegistry[$script:Native] = @(
        @{
          DisplayName          = 'Ceiling Product one'
          PSChildName          = 'CeilingOne'
          QuietUninstallString = 'C:\CeilingOne\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Ceiling Product two'
          PSChildName          = 'CeilingTwo'
          QuietUninstallString = 'C:\CeilingTwo\uninstall.exe /S'
        },
        @{
          DisplayName          = 'Ceiling Product three'
          PSChildName          = 'CeilingThree'
          QuietUninstallString = 'C:\CeilingThree\uninstall.exe /S'
        }
      )
    }

    It 'refuses two selections when MaxRemovals is omitted' -Tag 'CeilingWatch' {
      $global:StartUninstallerRegistry[$script:Native] = @(
        $global:StartUninstallerRegistry[$script:Native] | Select-Object -First 2
      )

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Ceiling Product*' }
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $global:StartUninstallerProcessCalls | Should -HaveCount 0
      $ExitCode | Should -Be 1
      $Result.changed | Should -BeFalse
      $Result.failures | Should -HaveCount 2
      $Result.failures -join ' ' | Should -Match 'Ceiling Product one'
      $Result.failures -join ' ' | Should -Match 'Ceiling Product two'
      $global:StartUninstallerReadRoots | Should -HaveCount 2
    }

    It 'refuses three selections when MaxRemovals is two' -Tag 'CeilingWatch' {
      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Ceiling Product*' } `
        -MaxRemovals 2
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $global:StartUninstallerProcessCalls | Should -HaveCount 0
      $ExitCode | Should -Be 1
      $Result.changed | Should -BeFalse
      $Result.failures | Should -HaveCount 3
      $Result.failures -join ' ' | Should -Match 'Ceiling Product one'
      $Result.failures -join ' ' | Should -Match 'Ceiling Product two'
      $Result.failures -join ' ' | Should -Match 'Ceiling Product three'
      $global:StartUninstallerReadRoots | Should -HaveCount 2
    }

    It 'reports a ceiling refusal through the transport in check mode' {
      $Context = New-AnsibleContext -CheckMode

      $Emitted = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Ceiling Product*' } `
        -MaxRemovals 2

      $Emitted | Should -BeNullOrEmpty
      $Context.Changed | Should -BeFalse
      $Context.Failed | Should -BeTrue
      $Context.Result.failures | Should -HaveCount 3
      $global:StartUninstallerReadRoots | Should -HaveCount 2
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }
  }

  Context 'declaration refusals' -Tag 'WatchedFailure' {
    It 'rejects <Name> before a registry read or process launch' -ForEach @(
      @{
        Arguments = @{ Family = @{ Method = 'Exact' } }
        Name      = 'a Family missing Query'
      }
      @{
        Arguments = @{ Family = @{ Method = 'Exact'; Query = 'Product'; Extra = 'x' } }
        Name      = 'an extra Family key'
      }
      @{
        Arguments = @{ Family = 'not a tuple' }
        Name      = 'a non-hashtable Family'
      }
      @{
        Arguments = @{ Family = @{ Method = 'Exact'; Query = 1 } }
        Name      = 'a non-string Family Query'
      }
      @{
        Arguments = @{ Family = @{ Method = 'Exact'; Query = '' } }
        Name      = 'an empty Family Query'
      }
      @{
        Arguments = @{ Family = @{ Method = 'Exact'; Query = '   ' } }
        Name      = 'a whitespace Family Query'
      }
      @{
        Arguments = @{ Family = @{ Method = 'Unknown'; Query = 'Product' } }
        Name      = 'an unknown Family Method'
      }
      @{
        Arguments = @{ Family = @{ Method = 'Regex'; Query = '[invalid' } }
        Name      = 'an invalid Family Regex'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Method = 'Exact'; Query = 'Value' })
        }
        Name = 'a Filter missing Property'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 'Publisher'; Query = 'Value' })
        }
        Name = 'a Filter missing Method'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 'Publisher'; Method = 'Exact' })
        }
        Name = 'a Filter missing Query'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{
              Property = 'Publisher'
              Method   = 'Exact'
              Query    = 'Value'
              Extra    = 'x'
            })
        }
        Name = 'an extra Filter key'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @('not a tuple')
        }
        Name = 'a non-hashtable Filter element'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 1; Method = 'Exact'; Query = 'Value' })
        }
        Name = 'a non-string Filter Property'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = ''; Method = 'Exact'; Query = 'Value' })
        }
        Name = 'an empty Filter Property'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = '   '; Method = 'Exact'; Query = 'Value' })
        }
        Name = 'a whitespace Filter Property'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 'Publisher'; Method = 'Exact'; Query = 1 })
        }
        Name = 'a non-string Filter Query'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 'Publisher'; Method = 'Exact'; Query = '' })
        }
        Name = 'an empty Filter Query'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 'Publisher'; Method = 'Exact'; Query = '   ' })
        }
        Name = 'a whitespace Filter Query'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 'Publisher'; Method = 'Unknown'; Query = 'Value' })
        }
        Name = 'an unknown Filter Method'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @(@{ Property = 'Publisher'; Method = 'Regex'; Query = '[invalid' })
        }
        Name = 'an invalid Filter Regex'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Method = 'Exact'; Query = 'Value' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an Exclude missing Property'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 'Publisher'; Query = 'Value' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an Exclude missing Method'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 'Publisher'; Method = 'Exact' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an Exclude missing Query'
      }
      @{
        Arguments = @{
          Exclude = @(@{
              Property = 'Publisher'
              Method   = 'Exact'
              Query    = 'Value'
              Extra    = 'x'
            })
          Family = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an extra Exclude key'
      }
      @{
        Arguments = @{
          Exclude = @('not a tuple')
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'a non-hashtable Exclude element'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 1; Method = 'Exact'; Query = 'Value' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'a non-string Exclude Property'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = ''; Method = 'Exact'; Query = 'Value' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an empty Exclude Property'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = '   '; Method = 'Exact'; Query = 'Value' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'a whitespace Exclude Property'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 'Publisher'; Method = 'Exact'; Query = 1 })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'a non-string Exclude Query'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 'Publisher'; Method = 'Exact'; Query = '' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an empty Exclude Query'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 'Publisher'; Method = 'Exact'; Query = '   ' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'a whitespace Exclude Query'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 'Publisher'; Method = 'Unknown'; Query = 'Value' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an unknown Exclude Method'
      }
      @{
        Arguments = @{
          Exclude = @(@{ Property = 'Publisher'; Method = 'Regex'; Query = '[invalid' })
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an invalid Exclude Regex'
      }
      @{
        Arguments = @{
          Family = @{ Method = 'Exact'; Query = 'Product' }
          Filter = @()
        }
        Name = 'an explicitly empty Filter'
      }
      @{
        Arguments = @{
          Exclude = @()
          Family  = @{ Method = 'Exact'; Query = 'Product' }
        }
        Name = 'an explicitly empty Exclude'
      }
      @{
        Arguments = @{
          Family     = @{ Method = 'Exact'; Query = 'Product' }
          MaxRemovals = 0
        }
        Name = 'zero MaxRemovals'
      }
      @{
        Arguments = @{
          Family     = @{ Method = 'Exact'; Query = 'Product' }
          MaxRemovals = -1
        }
        Name = 'negative MaxRemovals'
      }
    ) {
      $global:StartUninstallerDeniedRoot = $script:Native

      { & $script:ScriptPath @Arguments 2>$Null } | Should -Throw
      $global:StartUninstallerReadRoots | Should -HaveCount 0
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }
  }

  Context 'standalone transport' {
    It 'reports NoChange when only the conforming MSI is present' {
      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' }
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeFalse
      $Result.removed | Should -HaveCount 0
      $Result.retained | Should -HaveCount 1
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'removes a conforming MSI registration when RemoveConforming is supplied' {
      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeTrue
      $Result.removed.key_name | Should -Be $script:ProductCode
      $Result.retained | Should -HaveCount 0
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'reports NoChange when no registration matches' {
      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'No Such Product*' }
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeFalse
      $Result.matched_count | Should -Be 0
      $Result.removed | Should -HaveCount 0
      $Result.retained | Should -HaveCount 0
      $Result.survived | Should -HaveCount 0
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'removes the only matching registration and reports an empty second read' {
      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Exclude @(
          @{ Property = 'ParentKey'; Method = 'Exact'; Query = 'No matching product code' }
        ) `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeTrue
      $Result.matched_count | Should -Be 0
      $Result.removed | Should -HaveCount 1
      $Result.retained | Should -HaveCount 0
      $Result.survived | Should -HaveCount 0
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
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

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -MaxRemovals 2 `
        -SilentSwitch '/S'
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

    It 'reports both selected registrations removed after the first launch removes both' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = 'Duplicate Product native'
        PSChildName          = 'DuplicateProductNative'
        QuietUninstallString = 'C:\Duplicate\Native\uninstall.exe /S'
      }
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = 'Duplicate Product sibling'
        PSChildName          = 'DuplicateProductSibling'
        QuietUninstallString = 'C:\Duplicate\Sibling\uninstall.exe /S'
      }
      $global:StartUninstallerCollateralRemoval = @('DuplicateProductSibling')

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Duplicate Product*' } `
        -MaxRemovals 2
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeTrue
      $Result.removed | Should -HaveCount 2
      $Result.removed.key_name | Should -Contain 'DuplicateProductNative'
      $Result.removed.key_name | Should -Contain 'DuplicateProductSibling'
      $Result.survived | Should -HaveCount 0
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'skips validation for a selected registration removed by an earlier launch' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = 'Collateral Product primary'
        PSChildName          = 'CollateralProductPrimary'
        QuietUninstallString = 'C:\Collateral\Primary\uninstall.exe /S'
      }
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName     = 'Collateral Product sibling'
        PSChildName     = $script:WrongProductCode
        UninstallString = 'C:\Collateral\Sibling\uninstall.exe /S'
      }
      $global:StartUninstallerCollateralRemoval = @($script:WrongProductCode)

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = 'Collateral Product*' } `
        -MaxRemovals 2 `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeTrue
      $Result.failures | Should -HaveCount 0
      $Result.removed | Should -HaveCount 2
      $Result.removed.key_name | Should -Contain 'CollateralProductPrimary'
      $Result.removed.key_name | Should -Contain $script:WrongProductCode
      $Result.survived | Should -HaveCount 0
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'refuses a bare interactive uninstall string when no silent switch is supplied' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName     = '7-Zip 26.02 (x64)'
        PSChildName     = '7-Zip'
        UninstallString = '"C:\Program Files\7-Zip\Uninstall.exe"'
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' }
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

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' }
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

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' }
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

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' }
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.changed | Should -BeFalse
      $Result.failures | Should -HaveCount 0
      $Result.survived | Should -HaveCount 1
      $Result.msg | Should -Match 'did not converge'
    }

    It 'fails verification when a selected registration survives after its criterion property stops matching' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = 'Legacy Product'
        PSChildName          = 'LegacyProduct'
        Publisher            = 'Legacy'
        QuietUninstallString = 'C:\Legacy\uninstall.exe /S'
      }
      $global:StartUninstallerPersistRegistration = $True
      $global:StartUninstallerSurvivorMutation = @{
        PSChildName = 'LegacyProduct'
        Values      = @{ Publisher = 'Current' }
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = 'Legacy Product' } `
        -Filter @(
          @{ Property = 'Publisher'; Method = 'Exact'; Query = 'Legacy' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.failures | Should -HaveCount 0
      $Result.removed | Should -HaveCount 0
      $Result.retained | Should -HaveCount 0
      $Result.survived.key_name | Should -Be 'LegacyProduct'
    }

    It 'fails verification when a selected registration survives after leaving the display-name family' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = 'Legacy Product'
        PSChildName          = 'LegacyProduct'
        QuietUninstallString = 'C:\Legacy\uninstall.exe /S'
      }
      $global:StartUninstallerPersistRegistration = $True
      $global:StartUninstallerSurvivorMutation = @{
        PSChildName = 'LegacyProduct'
        Values      = @{ DisplayName = 'Unrelated Product' }
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Exact'; Query = 'Legacy Product' }
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.failures | Should -HaveCount 0
      $Result.removed | Should -HaveCount 0
      $Result.survived.key_name | Should -Be 'LegacyProduct'
    }

    It 'fails when a selected registration is replaced under a new key before verification' {
      $global:StartUninstallerReplacementRegistration = @{
        DisplayName          = '7-Zip 26.02 replacement'
        PSChildName          = 'Replacement7Zip'
        QuietUninstallString = 'C:\Replacement\uninstall.exe /S'
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Exclude @(
          @{ Property = 'ParentKey'; Method = 'Exact'; Query = 'No matching product code' }
        ) `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.removed.key_name | Should -Be $script:ProductCode
      $Result.retained | Should -HaveCount 0
      $Result.survived.key_name | Should -Be 'Replacement7Zip'
      $Result.msg | Should -Match 'did not converge'
    }

    It 'fails closed when either uninstall root cannot be read' {
      $global:StartUninstallerDeniedRoot = $script:Wow

      {
        & $script:ScriptPath `
          -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
          2>$Null
      } |
        Should -Throw '*Registry access denied*'
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'rejects a whitespace family pattern before starting a process' {
      { & $script:ScriptPath -Family @{ Method = 'Simple'; Query = '   ' } 2>$Null } |
        Should -Throw '*Query must be a non-whitespace string*'
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'retains a conforming registration whose exclusion matches' {
      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Exclude @(
          @{ Property = 'ParentKey'; Method = 'Exact'; Query = $script:ProductCode }
        ) `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeFalse
      $Result.removed | Should -HaveCount 0
      $Result.retained.key_name | Should -Be $script:ProductCode
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'removes a conforming registration whose exclusion does not match' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName     = '7-Zip 25.01 (x64 edition)'
        PSChildName     = $script:WrongProductCode
        UninstallString = 'MsiExec.exe /X{00000000-0000-0000-0000-000000000000}'
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Exclude @(
          @{ Property = 'ParentKey'; Method = 'Exact'; Query = $script:ProductCode }
        ) `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeTrue
      $Result.removed.key_name | Should -Be $script:WrongProductCode
      $Result.retained.key_name | Should -Be $script:ProductCode
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
      $global:StartUninstallerProcessCalls[0].ArgumentList |
        Should -Be ('/x {0} /qn /norestart' -f $script:WrongProductCode)
    }

    It 'uses an included loaded registry property to narrow the selected registrations' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip selected'
        PSChildName          = 'Selected7Zip'
        Publisher            = 'Selected Publisher'
        QuietUninstallString = 'C:\Selected\uninstall.exe /S'
      }
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip retained'
        PSChildName          = 'Retained7Zip'
        Publisher            = 'Other Publisher'
        QuietUninstallString = 'C:\Retained\uninstall.exe /S'
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Filter @(
          @{ Property = 'Publisher'; Method = 'Simple'; Query = 'Selected*' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'Selected7Zip'
      $Result.retained.key_name | Should -Contain 'Retained7Zip'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'uses synthesized AppArch as an inclusion filter' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName          = '7-Zip native'
        PSChildName          = 'Native7Zip'
        QuietUninstallString = 'C:\Native\uninstall.exe /S'
      }
      Add-FakeRegistration -Root $script:Wow -Registration @{
        DisplayName          = '7-Zip WOW64'
        PSChildName          = 'Wow7Zip'
        QuietUninstallString = 'C:\Wow\uninstall.exe /S'
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Filter @(
          @{ Property = 'AppArch'; Method = 'Exact'; Query = 'x86' }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.removed.key_name | Should -Be 'Wow7Zip'
      $Result.retained.key_name | Should -Contain 'Native7Zip'
      $global:StartUninstallerProcessCalls | Should -HaveCount 1
    }

    It 'rejects a malformed criterion before starting a process' {
      {
        & $script:ScriptPath `
          -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
          -Exclude @(
            @{ Property = 'ParentKey'; Method = 'Regex'; Query = '[invalid' }
          ) `
          2>$Null
      } | Should -Throw '*Query is not a valid regular expression*'
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'converges when a criterion names a property that is not present' {
      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Filter @(
          @{ Property = 'ProductCode'; Method = 'Exact'; Query = $script:ProductCode }
        )
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 0
      $Result.changed | Should -BeFalse
      $Result.removed | Should -HaveCount 0
      $Result.retained.key_name | Should -Be $script:ProductCode
      $global:StartUninstallerProcessCalls | Should -HaveCount 0
    }

    It 'refuses a selected MSI registration whose uninstall command is not msiexec' {
      Add-FakeRegistration -Root $script:Native -Registration @{
        DisplayName     = '7-Zip foreign MSI'
        PSChildName     = $script:WrongProductCode
        UninstallString = 'C:\Vendor\uninstall.exe /S'
      }

      $Json = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' } `
        -Exclude @(
          @{ Property = 'ParentKey'; Method = 'Exact'; Query = $script:ProductCode }
        ) `
        -RemoveConforming
      $ExitCode = $LASTEXITCODE
      $Result = $Json | ConvertFrom-Json

      $ExitCode | Should -Be 1
      $Result.failures[0] | Should -Match 'does not record an msiexec uninstall command'
      $Result.survived.key_name | Should -Be $script:WrongProductCode
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

      $Emitted = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' }

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

      $Emitted = & $script:ScriptPath `
        -Family @{ Method = 'Simple'; Query = '7-Zip*' }

      $Emitted | Should -BeNullOrEmpty
      $Context.Changed | Should -BeTrue
      $Context.Failed | Should -BeFalse
      $Context.Result.removed | Should -HaveCount 1
      $Context.Result.survived | Should -HaveCount 0
    }
  }
}
