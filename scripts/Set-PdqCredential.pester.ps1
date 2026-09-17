#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqCredential.ps1. The product command line and its sqlite executable are
    represented by path-shaped functions, so the whole credential-set transaction is exercised on
    Linux CI without a product installation. Fake state deliberately holds no password; stdin is
    recorded separately so the suite can prove no secret becomes an argument or SQL literal.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path $PSScriptRoot 'Set-PdqCredential.ps1'
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
  $script:DatabasePath = 'E:\PDQ Deploy\Database.db'
  $script:SqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
  $script:Ctx = @{
    CliPath           = $script:CliPath
    DatabaseDrive     = 'E'
    DatabaseDirectory = 'PDQ Deploy'
    Product           = 'Deploy'
  }
  $script:Declarations = @(
    @{
      username    = 'tcn\svc-pdq-ws'
      password    = 'workstation-password-value'
      description = 'Workstation class'
    }
    @{
      username    = 'tcn\laps-reader'
      password    = 'reader-password-value'
      laps_user   = 'Administrator'
      description = 'LAPS reader'
      is_default  = $True
    }
  )

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    Return $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name:'Ansible' -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
  }

  Function ConvertTo-FakeHex {
    Param ([System.String]$Value)
    Return -join ([System.Text.Encoding]::UTF8.GetBytes($Value) |
        ForEach-Object { $PSItem.ToString('X2') })
  }

  Function ConvertFrom-FakeHex {
    Param ([System.String]$Value)
    $Bytes = [System.Byte[]]::new($Value.Length / 2)
    For ($B = 0; $B -lt $Bytes.Length; $B++) {
      $Bytes[$B] = [System.Convert]::ToByte($Value.Substring($B * 2, 2), 16)
    }
    Return [System.Text.Encoding]::UTF8.GetString($Bytes)
  }

  Function global:Add-FakeCredential {
    Param (
      [System.String]$Name,
      [System.String]$Default = '0',
      [System.String]$AuthenticationType = '',
      [System.String]$LapsUser = '',
      [System.String]$Description = ''
    )
    $global:FakeCredentials.Add([PSCustomObject]@{
        Id                 = [System.String]$global:FakeNextId
        Name               = $Name
        IsDefault          = $Default
        AuthenticationType = $AuthenticationType
        LapsUser           = $LapsUser
        Description        = $Description
      })
    $global:FakeNextId++
  }

  Function global:Get-FakeCredential {
    Param ([System.String]$Name)
    Return @($global:FakeCredentials | Where-Object { $PSItem.Name -ceq $Name } | Select-Object -First 1)[0]
  }
}

Describe 'Set-PdqCredential' {
  BeforeEach {
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType:'Directory' -Path:$script:Sandbox -Force | Out-Null
    $script:MountedDrives = [System.Collections.Generic.List[System.String]]::new()
    ForEach ($Drive In @('C', 'E')) {
      If (-not (Get-PSDrive -Name:$Drive -ErrorAction:'SilentlyContinue')) {
        New-PSDrive -Name:$Drive -PSProvider:'FileSystem' -Root:$script:Sandbox -Scope:'Global' | Out-Null
        $script:MountedDrives.Add($Drive)
      }
    }
    $script:SqlitePath = Join-Path (Split-Path $script:CliPath -Parent) 'sqlite3.exe'
    New-Item -ItemType:'Directory' -Path:(Split-Path $script:CliPath -Parent) -Force | Out-Null
    New-Item -ItemType:'Directory' -Path:(Split-Path $script:DatabasePath -Parent) -Force | Out-Null
    Set-Content -LiteralPath:$script:CliPath -Value:'stub' -WhatIf:$False
    Set-Content -LiteralPath:$script:SqlitePath -Value:'stub' -WhatIf:$False
    Set-Content -LiteralPath:$script:DatabasePath -Value:'stub' -WhatIf:$False

    $global:FakeCredentials = [System.Collections.Generic.List[System.Object]]::new()
    $global:FakeNextId = 1
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeSqliteCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeStdin = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeCliExit = 0
    $global:FakeCliMode = 'normal'
    $global:FakeTransactionMode = 'normal'
    $global:FakeTriggers = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeTransactionCalls = 0
    $global:LASTEXITCODE = 0
    Remove-AnsibleContext

    Add-FakeCredential -Name:'tcn\undeclared' -Default:'1' -Description:'old row'

    New-Item -Force -Path:('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      $Piped = @($input)
      If ($Piped.Count -gt 0) { $global:FakeStdin.Add(($Piped -join '')) }
      If ($global:FakeCliExit -ne 0) {
        $global:LASTEXITCODE = $global:FakeCliExit
        Return
      }
      If ($args[0] -notin @('UpdateDeployCredential', 'UpdateScanCredential')) {
        $global:LASTEXITCODE = 2
        Return
      }
      $Name = [System.String]$args[[System.Array]::IndexOf($args, '-Username') + 1]
      $Row = @($global:FakeCredentials | Where-Object { $PSItem.Name -ceq $Name } | Select-Object -First 1)
      If ($Row.Count -eq 0 -and $global:FakeCliMode -ne 'skip_create') {
        Add-FakeCredential -Name:$Name -AuthenticationType:'None'
      }
      ForEach ($Present In $global:FakeCredentials) {
        If (($Present.Name -ceq $Name -or $Present.IsDefault -eq '1') -and
            $Present.AuthenticationType -cne 'LAPS') {
          $Present.AuthenticationType = 'None'
          $Present.LapsUser = ''
        }
      }
      $global:LASTEXITCODE = 0
    } | Out-Null

    New-Item -Force -Path:('function:global:' + $script:SqlitePath) -Value {
      $global:FakeSqliteCalls.Add($args -join ' ')
      $Sql = [System.String]$args[-1]

      If ($Sql -like "SELECT name FROM sqlite_master WHERE type = 'trigger'*") {
        $global:FakeTriggers | ForEach-Object { $PSItem }
        $global:LASTEXITCODE = 0
        Return
      }

      If ($Sql -like 'SELECT CredentialsId,*FROM Credentials*ORDER BY CredentialsId;') {
        ForEach ($Row In @($global:FakeCredentials | Sort-Object { [System.Int32]$PSItem.Id })) {
          '{0}|{1}|{2}|{3}|{4}|{5}' -f @(
            $Row.Id
            (ConvertTo-FakeHex $Row.Name)
            $Row.IsDefault
            (ConvertTo-FakeHex $(If ($Row.AuthenticationType -in @('', 'None')) { '' } Else { $Row.AuthenticationType }))
            (ConvertTo-FakeHex $Row.LapsUser)
            (ConvertTo-FakeHex $Row.Description)
          )
        }
        $global:LASTEXITCODE = 0
        Return
      }

      If ($args[0] -eq '-bail') {
        $global:FakeTransactionCalls++

        $LapsUpdates = [regex]::Matches($Sql, "UPDATE Credentials SET LAPSUser = CAST\(X'(?<laps>[0-9A-F]*)' AS TEXT\), AuthenticationType = 'LAPS', Description = CAST\(X'(?<description>[0-9A-F]*)' AS TEXT\), IsDefault = (?<default>[01]) WHERE CredentialsId = (?<id>[0-9]+) AND hex\(UserName\) = '(?<name>[0-9A-F]*)';")
        ForEach ($Update In $LapsUpdates) {
          $Row = @($global:FakeCredentials | Where-Object {
              $PSItem.Id -eq $Update.Groups['id'].Value -and
              (ConvertTo-FakeHex $PSItem.Name) -ceq $Update.Groups['name'].Value
            } | Select-Object -First 1)
          If ($Row.Count -eq 1 -and $global:FakeTransactionMode -ne 'ignore_update') {
            $Row[0].LapsUser = ConvertFrom-FakeHex $Update.Groups['laps'].Value
            $Row[0].AuthenticationType = 'LAPS'
            $Row[0].Description = ConvertFrom-FakeHex $Update.Groups['description'].Value
            $Row[0].IsDefault = $Update.Groups['default'].Value
          }
        }

        $OrdinaryUpdates = [regex]::Matches($Sql, "UPDATE Credentials SET LAPSUser = NULL, AuthenticationType = NULL, Description = CAST\(X'(?<description>[0-9A-F]*)' AS TEXT\), IsDefault = (?<default>[01]) WHERE CredentialsId = (?<id>[0-9]+) AND hex\(UserName\) = '(?<name>[0-9A-F]*)';")
        ForEach ($Update In $OrdinaryUpdates) {
          $Row = @($global:FakeCredentials | Where-Object {
              $PSItem.Id -eq $Update.Groups['id'].Value -and
              (ConvertTo-FakeHex $PSItem.Name) -ceq $Update.Groups['name'].Value
            } | Select-Object -First 1)
          If ($Row.Count -eq 1 -and $global:FakeTransactionMode -ne 'ignore_update') {
            $Row[0].LapsUser = ''
            $Row[0].AuthenticationType = ''
            $Row[0].Description = ConvertFrom-FakeHex $Update.Groups['description'].Value
            $Row[0].IsDefault = $Update.Groups['default'].Value
          }
        }

        $Deletes = [regex]::Matches(
          $Sql,
          "DELETE FROM Credentials WHERE CredentialsId = (?<id>[0-9]+) AND hex\(UserName\) = '(?<name>[0-9A-F]*)';"
        )
        ForEach ($Delete In $Deletes) {
          $Row = @($global:FakeCredentials | Where-Object {
              $PSItem.Id -eq $Delete.Groups['id'].Value -and
              (ConvertTo-FakeHex $PSItem.Name) -ceq $Delete.Groups['name'].Value
            } | Select-Object -First 1)
          If ($Row.Count -eq 1 -and $global:FakeTransactionMode -ne 'ignore_delete') {
            $Null = $global:FakeCredentials.Remove($Row[0])
          }
        }
        $global:LASTEXITCODE = 0
        Return
      }

      $global:LASTEXITCODE = 2
    } | Out-Null
  }

  AfterEach {
    Remove-AnsibleContext
    Remove-Item -LiteralPath:('function:global:' + $script:CliPath) -Force -ErrorAction:'SilentlyContinue'
    Remove-Item -LiteralPath:('function:global:' + $script:SqlitePath) -Force -ErrorAction:'SilentlyContinue'
    ForEach ($Drive In $script:MountedDrives) {
      Remove-PSDrive -Name:$Drive -Force -ErrorAction:'SilentlyContinue'
    }
    Remove-Item -LiteralPath:$script:Sandbox -Recurse -Force -ErrorAction:'SilentlyContinue'
  }

  AfterAll {
    Remove-Variable -Name:'FakeCredentials', 'FakeNextId', 'FakeCliCalls', 'FakeSqliteCalls',
      'FakeStdin', 'FakeCliExit', 'FakeCliMode', 'FakeTransactionMode', 'FakeTriggers',
      'FakeTransactionCalls' -Scope:'Global' -Force -ErrorAction:'SilentlyContinue'
  }

  It 'accepts a mandatory plural declaration, including an empty collection' {
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:ScriptPath, [ref]$Null, [ref]$Null
    )
    $Binding = $Ast.ParamBlock.Attributes |
      Where-Object { $PSItem.TypeName.FullName -eq 'CmdletBinding' }
    $Binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
    $Parameter = $Ast.ParamBlock.Parameters |
      Where-Object { $PSItem.Name.VariablePath.UserPath -eq 'CredentialDeclarations' }
    $Parameter.Attributes.TypeName.FullName | Should -Contain 'AllowEmptyCollection'

    $global:FakeCredentials.Clear()
    $Context = New-AnsibleContext
    { & $script:ScriptPath @script:Ctx -CredentialDeclarations @() } | Should -Not -Throw
    $Context.Result.declared | Should -Be 0
  }

  It 'empties a populated store when the declaration is empty' {
    $Context = New-AnsibleContext
    & $script:ScriptPath @script:Ctx -CredentialDeclarations @()
    $Context.Changed | Should -BeTrue
    $Context.Result.removed | Should -Be @('tcn\undeclared')
    $global:FakeCredentials | Should -HaveCount 0
  }

  It 'writes every declaration, removes every extra, and settles one default in one transaction' {
    $Context = New-AnsibleContext
    & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations

    $global:FakeCredentials.Name | Sort-Object | Should -Be @('tcn\laps-reader', 'tcn\svc-pdq-ws')
    @($global:FakeCredentials | Where-Object IsDefault -eq '1').Name |
      Should -BeExactly 'tcn\laps-reader'
    (Get-FakeCredential 'tcn\laps-reader').AuthenticationType | Should -BeExactly 'LAPS'
    (Get-FakeCredential 'tcn\laps-reader').LapsUser | Should -BeExactly 'Administrator'
    (Get-FakeCredential 'tcn\svc-pdq-ws').AuthenticationType | Should -BeExactly ''
    $global:FakeTransactionCalls | Should -Be 1
    $Transaction = @($global:FakeSqliteCalls | Where-Object { $PSItem -like '-bail *' })
    $Transaction | Should -HaveCount 1
    $Transaction[0] | Should -BeLike '*BEGIN IMMEDIATE;*'
    $Transaction[0] | Should -BeLike '*COMMIT;*'
    $Context.Result.removed | Should -Be @('tcn\undeclared')
  }

  It 'refuses a credential named twice before writing anything' {
    $Duplicate = @(
      @{ username = 'tcn\same'; password = 'first'; is_default = $True }
      @{ username = 'tcn\same'; password = 'second' }
    )
    New-AnsibleContext | Out-Null
    { & $script:ScriptPath @script:Ctx -CredentialDeclarations $Duplicate } |
      Should -Throw -ExpectedMessage '*declared more than once*'
    $global:FakeCliCalls | Should -HaveCount 0
    $global:FakeTransactionCalls | Should -Be 0
  }

  It 'refuses a non-empty declaration without exactly one default' {
    $NoDefault = @(@{ username = 'tcn\one'; password = 'value' })
    New-AnsibleContext | Out-Null
    { & $script:ScriptPath @script:Ctx -CredentialDeclarations $NoDefault } |
      Should -Throw -ExpectedMessage '*exactly one default*'
  }

  It 'passes every password on stdin and never in an argument or SQL statement' {
    New-AnsibleContext | Out-Null
    & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations
    $global:FakeStdin | Should -Be @('workstation-password-value', 'reader-password-value')
    $Calls = ($global:FakeCliCalls + $global:FakeSqliteCalls) -join ' '
    $Calls | Should -Not -BeLike '*workstation-password-value*'
    $Calls | Should -Not -BeLike '*reader-password-value*'
  }

  It 'is idempotent on the second complete declaration while still rewriting every secret' {
    New-AnsibleContext | Out-Null
    & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations
    $Second = New-AnsibleContext
    & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations
    $Second.Changed | Should -BeFalse
    $global:FakeCliCalls | Should -HaveCount 4
    $Second.Result.msg | Should -BeLike '*already read back as declared*'
  }

  It 'predicts the complete change in check mode without writing' {
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations
    $Context.Changed | Should -BeTrue
    $Context.Result.check_mode | Should -BeTrue
    $global:FakeCliCalls | Should -HaveCount 0
    $global:FakeTransactionCalls | Should -Be 0
    $global:FakeCredentials.Name | Should -Be @('tcn\undeclared')
  }

  It 'fails verification when a successful transaction leaves an undeclared row' {
    $global:FakeTransactionMode = 'ignore_delete'
    New-AnsibleContext | Out-Null
    { & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations } |
      Should -Throw -ExpectedMessage '*does not read back as declared*'
  }

  It 'fails when the command reports success without creating its row' {
    $global:FakeCliMode = 'skip_create'
    New-AnsibleContext | Out-Null
    { & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations } |
      Should -Throw -ExpectedMessage '*reported success but the credential*is absent*'
    $global:FakeTransactionCalls | Should -Be 0
  }

  It 'uses the product-specific command verb' {
    New-AnsibleContext | Out-Null
    & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations
    ($global:FakeCliCalls -join ' ') | Should -BeLike '*UpdateDeployCredential*'

    $global:FakeCredentials.Clear()
    $global:FakeCliCalls.Clear()
    $Inventory = $script:Ctx.Clone()
    $Inventory.Product = 'Inventory'
    New-AnsibleContext | Out-Null
    & $script:ScriptPath @Inventory -CredentialDeclarations $script:Declarations
    ($global:FakeCliCalls -join ' ') | Should -BeLike '*UpdateScanCredential*'
  }

  It 'fails loudly when the product command refuses a credential' {
    $global:FakeCliExit = 5
    New-AnsibleContext | Out-Null
    { & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations } |
      Should -Throw -ExpectedMessage '*UpdateDeployCredential exited 5*'
  }

  It 'refuses an unknown credential trigger before writing anything' {
    $global:FakeTriggers.Add('unexpected_trigger')
    New-AnsibleContext | Out-Null
    { & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations } |
      Should -Throw -ExpectedMessage '*Credentials table has a trigger*'
    $global:FakeCliCalls | Should -HaveCount 0
  }

  It 'emits a plural standalone result' {
    Remove-AnsibleContext
    $Json = & $script:ScriptPath @script:Ctx -CredentialDeclarations $script:Declarations | Out-String
    $Parsed = $Json | ConvertFrom-Json
    $Parsed.credentials | Should -Be @('tcn\svc-pdq-ws', 'tcn\laps-reader')
    $Parsed.declared | Should -Be 2
    $Parsed.product | Should -Be 'Deploy'
  }
}
