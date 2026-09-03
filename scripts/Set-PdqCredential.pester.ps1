#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqCredential.ps1 (org pair convention: every script ships
    with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg
    per pair).

    Runs anywhere, Linux CI included. The script drives two external programs at
    a caller-selected path and one derived beside it, so this file registers
    FUNCTIONS named with those path strings: PowerShell resolves a path-shaped
    command to a function of that name before it looks on disk. The stubs set
    $LASTEXITCODE, because a function does not and the script reads it.

    Stub state lives in $global: variables because inside a function called from
    a child SCRIPT, $script: resolves to that child's scope, not this file's.

    $global:FakeCredentials is the product's credential store, keyed by user
    name. It deliberately holds no password: the product stores the secret as
    ciphertext behind an '(encrypted)' marker and nothing can read it back,
    which is the whole reason the script splits the work -- the command line
    owns the secret, the database owns the three fields that make the row a
    LAPS credential. $global:FakeStdin records what was piped to the command
    line, so a test can prove the password never travelled as an argument.

    Both transports are asserted: the standalone JSON emission and the $Ansible
    path via the inline context below (pairs are self-contained; no imports).
    Its Changed defaults to $True exactly like win_powershell -- so every test
    proves the script SETS Changed rather than inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PdqCredential.ps1'

  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe'
  $script:WindowsSqlitePath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\sqlite3.exe'
  $script:DatabasePath = 'E:\PDQ Deploy\Database.db'

  # The context every call carries. The script derives the sqlite tool from CliPath and the
  # database from the drive and directory, so these three fix all three paths.
  $script:Ctx = @{
    CliPath           = $script:CliPath
    DatabaseDrive     = 'E'
    DatabaseDirectory = 'PDQ Deploy'
    Product           = 'Deploy'
  }

  # The declaration under test: the account PDQ authenticates as, and the local account on the
  # target whose LAPS password the product should fetch.
  $script:Declaration = @{
    reader_username = 'tcn\svc-pdq'
    reader_password = 'a-secret-that-must-not-be-an-argument'
    laps_user       = 'Administrator'
    description     = 'PDQ LAPS reader'
  }

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
    Remove-Variable -Name 'Ansible' -Scope 'Global' -ErrorAction 'SilentlyContinue'
  }

  # The row the declaration asks for, in the pipe-joined shape sqlite prints.
  Function Get-DeclaredRow {
    '1|LAPS|{0}|{1}' -f $script:Declaration.laps_user, $script:Declaration.description
  }
}


Describe 'Set-PdqCredential' {

  BeforeEach {
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    $script:MountedDrive = $Null
    If (-not (Get-PSDrive -Name 'C' -ErrorAction 'SilentlyContinue')) {
      New-PSDrive -Name 'C' -PSProvider 'FileSystem' -Root $script:Sandbox -Scope 'Global' | Out-Null
      $script:MountedDrive = 'C'
    }
    $script:SqlitePath = Join-Path (Split-Path $script:CliPath -Parent) 'sqlite3.exe'

    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeSqliteCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeStdin = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeCliExit = 0
    # The store starts holding one unrelated credential that claims the default, so every test
    # that writes also proves the script takes the default away from it.
    $global:FakeCredentials = @{
      'tcn\someone-else' = @{ IsDefault = '1'; AuthenticationType = 'None'; LAPSUser = ''; Description = 'pre-existing' }
    }

    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      $Piped = @($input)
      If ($Piped.Count -gt 0) { $global:FakeStdin.Add(($Piped -join '')) }
      Switch ($args[0]) {
        { $PSItem -in @('UpdateDeployCredential', 'UpdateScanCredential') } {
          If ($global:FakeCliExit -ne 0) { $global:LASTEXITCODE = $global:FakeCliExit; Return }
          $Name = $args[$args.IndexOf('-Username') + 1]
          If (-not $global:FakeCredentials.ContainsKey($Name)) {
            # -CreateIfNotExists: the row appears as an ORDINARY credential. The two fields that
            # make it a LAPS one have no command-line spelling, which is why the script follows up.
            $global:FakeCredentials[$Name] = @{ IsDefault = '0'; AuthenticationType = 'None'; LAPSUser = ''; Description = '' }
          }
          $global:LASTEXITCODE = 0
        }
        Default { $global:LASTEXITCODE = 1 }
      }
    } | Out-Null

    New-Item -Force -Path ('function:global:' + $script:SqlitePath) -Value {
      $global:FakeSqliteCalls.Add($args -join ' ')
      $Sql = $args[-1]

      If ($Sql -match "SELECT IsDefault, AuthenticationType, LAPSUser, Description FROM Credentials WHERE UserName = '(?<u>[^']*)'") {
        $U = $Matches['u']
        If ($global:FakeCredentials.ContainsKey($U)) {
          $R = $global:FakeCredentials[$U]
          ('{0}|{1}|{2}|{3}' -f $R.IsDefault, $R.AuthenticationType, $R.LAPSUser, $R.Description)
        }
        $global:LASTEXITCODE = 0
        Return
      }

      If ($Sql -match "SELECT COUNT\(\*\) FROM Credentials WHERE IsDefault = 1 AND UserName <> '(?<u>[^']*)'") {
        $U = $Matches['u']
        @($global:FakeCredentials.Keys | Where-Object { $PSItem -ne $U -and $global:FakeCredentials[$PSItem].IsDefault -eq '1' }).Count
        $global:LASTEXITCODE = 0
        Return
      }

      # The write arrives as one transaction string; apply both statements in the order given.
      If ($Sql -match "UPDATE Credentials SET LAPSUser = '(?<l>[^']*)', AuthenticationType = '(?<a>[^']*)', Description = '(?<d>[^']*)', IsDefault = 1 WHERE UserName = '(?<u>[^']*)'") {
        $U = $Matches['u']
        If ($global:FakeCredentials.ContainsKey($U)) {
          $global:FakeCredentials[$U].LAPSUser = $Matches['l']
          $global:FakeCredentials[$U].AuthenticationType = $Matches['a']
          $global:FakeCredentials[$U].Description = $Matches['d']
          $global:FakeCredentials[$U].IsDefault = '1'
        }
      }
      If ($Sql -match "UPDATE Credentials SET IsDefault = 0 WHERE UserName <> '(?<u>[^']*)'") {
        $Keep = $Matches['u']
        ForEach ($K In @($global:FakeCredentials.Keys)) {
          If ($K -ne $Keep) { $global:FakeCredentials[$K].IsDefault = '0' }
        }
      }
      $global:LASTEXITCODE = 0
    } | Out-Null
  }

  AfterEach {
    Remove-AnsibleContext
    If ($script:MountedDrive) {
      Remove-PSDrive -Name $script:MountedDrive -Force -ErrorAction 'SilentlyContinue'
    }
    Remove-Item -LiteralPath ('function:global:' + $script:CliPath) -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:SqlitePath) -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction 'SilentlyContinue'
  }

  It 'declares SupportsShouldProcess so the module runs it in check mode' {
    $Attributes = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:ScriptPath, [ref]$Null, [ref]$Null
    ).ParamBlock.Attributes
    $Binding = $Attributes | Where-Object { $_.TypeName.FullName -eq 'CmdletBinding' }
    $Binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
  }

  It 'carries the same native-command helper as its siblings' {
    $Mine = (Get-Content -Raw $script:ScriptPath) -split '(?m)^Function Invoke-NativeCommand \{'
    $Theirs = (Get-Content -Raw (Join-Path $PSScriptRoot 'Set-PdqVariable.ps1')) -split '(?m)^Function Invoke-NativeCommand \{'
    $Mine.Count | Should -Be 2
    ($Mine[1] -split '(?m)^\}')[0] | Should -BeExactly ($Theirs[1] -split '(?m)^\}')[0]
  }

  Context 'deciding whether anything differs' {

    It 'reports no change when the row already reads back as declared' {
      $global:FakeCredentials[$script:Declaration.reader_username] = @{
        IsDefault = '1'; AuthenticationType = 'LAPS'
        LAPSUser = $script:Declaration.laps_user; Description = $script:Declaration.description
      }
      $global:FakeCredentials['tcn\someone-else'].IsDefault = '0'
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Ctx.Changed | Should -BeFalse
      $Ctx.Result.msg | Should -BeLike '*already reads back*'
    }

    It 'reports a change when the product holds no such credential' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Ctx.Changed | Should -BeTrue
    }

    It 'reports a change when the LAPS user differs' {
      $global:FakeCredentials[$script:Declaration.reader_username] = @{
        IsDefault = '1'; AuthenticationType = 'LAPS'
        LAPSUser = 'SomeoneElse'; Description = $script:Declaration.description
      }
      $global:FakeCredentials['tcn\someone-else'].IsDefault = '0'
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Ctx.Changed | Should -BeTrue
    }

    It 'reports a change when another credential also claims the default' {
      $global:FakeCredentials[$script:Declaration.reader_username] = @{
        IsDefault = '1'; AuthenticationType = 'LAPS'
        LAPSUser = $script:Declaration.laps_user; Description = $script:Declaration.description
      }
      # The row itself matches; the store still holds two defaults, which is not the declared state.
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Ctx.Changed | Should -BeTrue
      $global:FakeCredentials['tcn\someone-else'].IsDefault | Should -Be '0'
    }
  }

  Context 'what it writes' {

    It 'leaves the store holding exactly the declared credential, as the only default' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Row = $global:FakeCredentials[$script:Declaration.reader_username]
      ('{0}|{1}|{2}|{3}' -f $Row.IsDefault, $Row.AuthenticationType, $Row.LAPSUser, $Row.Description) |
        Should -BeExactly (Get-DeclaredRow)
      @($global:FakeCredentials.Keys | Where-Object { $global:FakeCredentials[$PSItem].IsDefault -eq '1' }) |
        Should -HaveCount 1
    }

    It 'gives the password to the command line on stdin, never as an argument' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $global:FakeStdin | Should -Contain $script:Declaration.reader_password
      ($global:FakeCliCalls -join ' ') | Should -Not -BeLike ('*' + $script:Declaration.reader_password + '*')
      ($global:FakeSqliteCalls -join ' ') | Should -Not -BeLike ('*' + $script:Declaration.reader_password + '*')
    }

    It 'writes the secret again even when the row already matches, so a rotation arrives' {
      $global:FakeCredentials[$script:Declaration.reader_username] = @{
        IsDefault = '1'; AuthenticationType = 'LAPS'
        LAPSUser = $script:Declaration.laps_user; Description = $script:Declaration.description
      }
      $global:FakeCredentials['tcn\someone-else'].IsDefault = '0'
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Ctx.Changed | Should -BeFalse
      $global:FakeStdin | Should -Contain $script:Declaration.reader_password
    }

    It 'uses the Deploy verb for Deploy and the Scan verb for Inventory' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      ($global:FakeCliCalls -join ' ') | Should -BeLike '*UpdateDeployCredential*'

      $global:FakeCliCalls.Clear()
      $Inventory = $script:Ctx.Clone()
      $Inventory.Product = 'Inventory'
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @Inventory -LapsCredential $script:Declaration
      ($global:FakeCliCalls -join ' ') | Should -BeLike '*UpdateScanCredential*'
    }

    It 'sets the LAPS fields in one transaction, after the command line has made the row' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Write = @($global:FakeSqliteCalls | Where-Object { $PSItem -like '*UPDATE Credentials*' })
      $Write | Should -HaveCount 1
      $Write[0] | Should -BeLike '*BEGIN IMMEDIATE;*'
      $Write[0] | Should -BeLike '*COMMIT;*'
    }
  }

  Context 'what it refuses' {

    It 'refuses a declared value carrying a single quote rather than building another statement' {
      $Bad = $script:Declaration.Clone()
      $Bad.laps_user = "Admin'; DROP TABLE Credentials; --"
      $Ctx = New-AnsibleContext
      { & $script:ScriptPath @script:Ctx -LapsCredential $Bad } |
        Should -Throw -ExpectedMessage '*single quote*'
      $global:FakeSqliteCalls | Should -Not -BeLike '*DROP TABLE*'
    }

    It 'fails loudly, naming the verb and the exit code, when the command line refuses' {
      $global:FakeCliExit = 5
      $Ctx = New-AnsibleContext
      { & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration } |
        Should -Throw -ExpectedMessage '*UpdateDeployCredential exited 5*'
    }
  }

  Context '$Ansible transport' {

    It 'reports the would-be change in check mode and writes nothing' {
      $Ctx = New-AnsibleContext -CheckMode
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Ctx.Changed | Should -BeTrue
      $Ctx.Result.check_mode | Should -BeTrue
      $global:FakeCliCalls | Should -HaveCount 0
      $global:FakeCredentials.ContainsKey($script:Declaration.reader_username) | Should -BeFalse
    }

    It 'sets Changed=$False explicitly rather than inheriting the default' {
      $global:FakeCredentials[$script:Declaration.reader_username] = @{
        IsDefault = '1'; AuthenticationType = 'LAPS'
        LAPSUser = $script:Declaration.laps_user; Description = $script:Declaration.description
      }
      $global:FakeCredentials['tcn\someone-else'].IsDefault = '0'
      $Ctx = New-AnsibleContext
      $Ctx.Changed | Should -BeTrue
      & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration
      $Ctx.Changed | Should -BeFalse
    }

    It 'emits the result as JSON when nothing provides an $Ansible context' {
      Remove-AnsibleContext
      $Json = & $script:ScriptPath @script:Ctx -LapsCredential $script:Declaration | Out-String
      $Parsed = $Json | ConvertFrom-Json
      $Parsed.credential | Should -Be $script:Declaration.reader_username
      $Parsed.laps_user | Should -Be $script:Declaration.laps_user
      $Parsed.product | Should -Be 'Deploy'
    }
  }
}
