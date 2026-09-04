#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-PdqSyncContainer.ps1 (org pair convention: every script ships
    with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script drives one external program -- the
    product's sqlite tool, at a path derived from the command line it is given -- so
    this file registers a FUNCTION named with that path string: PowerShell resolves a
    path-shaped command to a function of that name before it looks on disk. The stub
    sets $LASTEXITCODE, because a function does not and the script reads it.

    The directory read is the other outside edge. The script makes exactly one
    New-Object call, for a DirectoryEntry, so a global New-Object shim intercepts that
    one type and hands back a fake entry; every other type is passed to the real
    cmdlet. That shim is what lets the LDAPS branch be exercised at all: this
    directory cannot serve LDAPS, which the script records as a PROOF GAP at the
    branch itself. These tests prove the script ASKS for a secure bind and refuses to
    retry in the clear -- not that a real controller answers one.

    Stub state lives in $global: variables because inside a function called from a
    child SCRIPT, $script: resolves to that child's scope, not this file's.

    $global:FakeRows is the product's container table, keyed as the script keys it: by
    distinguished name, never by Name. The product REWRITES Name to
    '<domain>/<container path>' after a sync, so a stub that let a Name comparison pass
    would hide the drift that keying would cause forever.

    Both transports are asserted: the standalone JSON emission and the $Ansible path
    via the inline context below (pairs are self-contained; no imports). Its Changed
    defaults to $True exactly like win_powershell -- so every test proves the script
    SETS Changed rather than inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PdqSyncContainer.ps1'
  $script:CliPath = 'C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\PDQInventory.exe'
  $script:Realm = 'tcn.trinitytechnicalservices.com'
  $script:RootDn = 'DC=tcn,DC=trinitytechnicalservices,DC=com'
  $script:WksDn = 'OU=Domain Workstations,DC=tcn,DC=trinitytechnicalservices,DC=com'

  $script:Ctx = @{
    CliPath           = $script:CliPath
    DatabaseDrive     = 'D'
    DatabaseDirectory = 'PDQ Inventory'
  }

  Function New-Declaration {
    Param ([System.Object[]]$Container, [Switch]$Insecure)
    @{
      realm         = $script:Realm
      bind_username = 'TCN\svc-pdq'
      bind_password = 'not-a-real-password'
      insecure      = $Insecure.IsPresent
      containers    = $Container
    }
  }

  Function New-Container {
    Param ([System.String]$Dn, [System.String]$BindUsername)
    $c = @{ distinguished_name = $Dn; include = $True; subtree = $True }
    If ($BindUsername) { $c['bind_username'] = $BindUsername; $c['bind_password'] = 'not-a-real-password' }
    $c
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
}

Describe 'Set-PdqSyncContainer' {

  BeforeEach {
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    $script:MountedDrive = $Null
    If (-not (Get-PSDrive -Name 'C' -ErrorAction 'SilentlyContinue')) {
      New-PSDrive -Name 'C' -PSProvider 'FileSystem' -Root $script:Sandbox -Scope 'Global' | Out-Null
      $script:MountedDrive = 'C'
    }
    $script:SqlitePath = Join-Path (Split-Path $script:CliPath -Parent) 'sqlite3.exe'

    # The product's tables, as the stub models them.
    $global:FakeRows = @{}          # dn -> @{ UserId; IncludeSubtree; IsInclude }
    # Ordinal, deliberately: the product held 'TCN\svc-pdq' (ordinary) and 'tcn\svc-pdq' (LAPS)
    # as separate rows differing only in case, which a default PowerShell hashtable cannot express.
    $global:FakeCredentials = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $global:FakeCredentials['TCN\svc-pdq'] = @{ Id = 5; Auth = 'None' }
    $global:FakeCredentials['tcn\svc-pdq'] = @{ Id = 3; Auth = 'LAPS' }
    $global:FakeSqlCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeCliCalls = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeBindAuth = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeBindPath = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeBindFails = $False
    $global:FakeSyncError = ''
    $global:FakeLastSync = 'never'

    New-Item -Force -Path ('function:global:' + $script:SqlitePath) -Value {
      $sql = $args[-1]
      $global:FakeSqlCalls.Add($sql)
      If ($sql -like 'SELECT DistinguishedName ||*') {
        ForEach ($k In @($global:FakeRows.Keys)) {
          $r = $global:FakeRows[$k]
          '{0}|{1}|{2}|{3}' -f $k, $r.UserId, $r.IncludeSubtree, $r.IsInclude
        }
        $global:LASTEXITCODE = 0; Return
      }
      If ($sql -match "SELECT CredentialsId FROM Credentials WHERE UserName = '(?<u>[^']*)'") {
        $u = $Matches['u']
        # The script's own filter excludes LAPS rows; the stub honours it so a LAPS
        # account looks ABSENT, exactly as the product would report it.
        If ($global:FakeCredentials.ContainsKey($u) -and $global:FakeCredentials[$u].Auth -ne 'LAPS') {
          $global:FakeCredentials[$u].Id
        }
        $global:LASTEXITCODE = 0; Return
      }
      If ($sql -like '*ActiveDirectorySettings.LastSync*') {
        $global:FakeLastSync
        $global:LASTEXITCODE = 0; Return
      }
      If ($sql -like '*SELECT DistinguishedName FROM ADSyncContainers WHERE COALESCE(Error*') {
        If ($global:FakeSyncError) { $global:FakeSyncError }
        $global:LASTEXITCODE = 0; Return
      }
      If ($sql -match "DELETE FROM ADSyncContainers WHERE DistinguishedName = '(?<d>[^']*)'") {
        $global:FakeRows.Remove($Matches['d'])
      }
      If ($sql -match "INSERT INTO ADSyncContainers .*VALUES \('[^']*', '[^']*', '[^']*', (?<c>\d+), (?<s>\d+), (?<i>\d+), '(?<d>[^']*)'\)") {
        $global:FakeRows[$Matches['d']] = @{ UserId = $Matches['c']; IncludeSubtree = $Matches['s']; IsInclude = $Matches['i'] }
      }
      $global:LASTEXITCODE = 0
    } | Out-Null

    New-Item -Force -Path ('function:global:' + $script:CliPath) -Value {
      $global:FakeCliCalls.Add($args -join ' ')
      # A real sync stamps LastSync when it finishes; the stub does the same so the script's
      # wait ends the way it would in the product rather than on its timeout.
      $global:FakeLastSync = [System.Guid]::NewGuid().ToString()
      $global:LASTEXITCODE = 0
    } | Out-Null

    # The script makes exactly one New-Object call, for the directory entry. Anything else
    # is handed to the real cmdlet so this shim cannot change unrelated behaviour.
    Function global:New-Object {
      [CmdletBinding()]
      Param ([Parameter(Position = 0)][System.String]$TypeName, [Parameter(Position = 1)][System.Object[]]$ArgumentList)
      If ($TypeName -ne 'System.DirectoryServices.DirectoryEntry') {
        Return Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
      }
      $global:FakeBindPath.Add([System.String]$ArgumentList[0])
      $global:FakeBindAuth.Add([System.String]$ArgumentList[3])
      # A real DirectoryEntry is lazy: construction touches nothing and the bind happens on the
      # first access, so a refused bind must surface from RefreshCache, not from the constructor.
      [PSCustomObject]@{ Guid = '9cfbf891-c5ca-4a9a-8e36-ec13d911d250' } |
        Add-Member -MemberType ScriptMethod -Name 'RefreshCache' -Value {
          Param($p)
          If ($global:FakeBindFails) { Throw 'The server is not operational.' }
        } -PassThru |
        Add-Member -MemberType ScriptMethod -Name 'Dispose' -Value { } -PassThru
    }
  }

  AfterEach {
    Remove-AnsibleContext
    Remove-Item -LiteralPath 'function:global:New-Object' -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:CliPath) -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -LiteralPath ('function:global:' + $script:SqlitePath) -Force -ErrorAction 'SilentlyContinue'
    If ($script:MountedDrive) { Remove-PSDrive -Name $script:MountedDrive -Force -ErrorAction 'SilentlyContinue' }
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

  Context 'deciding what to write' {

    It 'declares a container the product does not hold' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)) -Insecure)
      $Ctx.Changed | Should -BeTrue
      $global:FakeRows.Keys | Should -Contain $script:WksDn
    }

    It 'reports no change when every container already reads back as declared' {
      $decl = New-Declaration -Container @((New-Container $script:WksDn)) -Insecure
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync $decl
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync $decl
      $Ctx.Changed | Should -BeFalse
      $Ctx.Result.msg | Should -BeLike '*already read back*'
    }

    It 'keys on the distinguished name, so the name the product rewrites cannot cause drift' {
      $decl = New-Declaration -Container @((New-Container $script:WksDn)) -Insecure
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync $decl
      # The product renames a container to '<domain>/<path>' after a sync. The stub does the
      # same, and the second run must still converge.
      $global:FakeRows[$script:WksDn]['Name'] = '{0}/Domain Workstations' -f $script:Realm
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync $decl
      $Ctx.Changed | Should -BeFalse
    }

    It 'removes a container the declaration does not name' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn), (New-Container $script:RootDn)) -Insecure)
      $global:FakeRows.Keys | Should -HaveCount 2
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)) -Insecure)
      $Ctx.Changed | Should -BeTrue
      $global:FakeRows.Keys | Should -HaveCount 1
      $global:FakeRows.Keys | Should -Not -Contain $script:RootDn
    }

    It 'lets a container name its own bind account' {
      $global:FakeCredentials['TCN\svc-other'] = @{ Id = 9; Auth = 'None' }
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @(
          (New-Container $script:WksDn),
          (New-Container $script:RootDn 'TCN\svc-other')) -Insecure)
      $global:FakeRows[$script:WksDn].UserId | Should -Be '5'
      $global:FakeRows[$script:RootDn].UserId | Should -Be '9'
    }
  }

  Context 'the directory read' {

    It 'asks for a secure bind by default' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)))
      $global:FakeBindAuth | Should -Contain 'Secure, SecureSocketsLayer'
    }

    It 'asks for a plain bind only when the declaration says insecure' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)) -Insecure)
      $global:FakeBindAuth | Should -Contain 'Secure'
      $global:FakeBindAuth | Should -Not -Contain 'Secure, SecureSocketsLayer'
    }

    It 'qualifies the path with the realm, because a serverless bind has no directory context' {
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)) -Insecure)
      $global:FakeBindPath | Should -Contain ('LDAP://{0}/{1}' -f $script:Realm, $script:WksDn)
    }

    It 'fails rather than retrying in the clear when the secure bind is refused' {
      $global:FakeBindFails = $True
      $Ctx = New-AnsibleContext
      { & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn))) } |
        Should -Throw -ExpectedMessage '*over LDAPS*'
      # The point of the test: no second attempt was made without the SSL bit.
      $global:FakeBindAuth | Should -Not -Contain 'Secure'
    }
  }

  Context 'what it refuses' {

    It 'refuses a LAPS credential as the bind account, naming it' {
      $Ctx = New-AnsibleContext
      { & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn 'tcn\svc-pdq')) -Insecure) } |
        Should -Throw -ExpectedMessage '*not an ordinary credential*'
    }

    It 'refuses an account the product does not hold' {
      $Ctx = New-AnsibleContext
      { & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn 'TCN\nobody')) -Insecure) } |
        Should -Throw -ExpectedMessage '*not an ordinary credential*'
    }

    It 'refuses a declared value carrying a single quote rather than building another statement' {
      $Ctx = New-AnsibleContext
      { & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container "OU=Bad',DC=tcn")) -Insecure) } |
        Should -Throw -ExpectedMessage '*single quote*'
      $global:FakeSqlCalls | Should -Not -BeLike '*OU=Bad*'
    }

    It 'fails when the product reports it could not read a container' {
      $global:FakeSyncError = $script:WksDn
      $Ctx = New-AnsibleContext
      { & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)) -Insecure) } |
        Should -Throw -ExpectedMessage '*could not read these containers*'
    }
  }

  Context '$Ansible transport' {

    It 'reports the would-be change in check mode and writes nothing' {
      $Ctx = New-AnsibleContext -CheckMode
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)) -Insecure)
      $Ctx.Changed | Should -BeTrue
      $Ctx.Result.check_mode | Should -BeTrue
      $global:FakeRows.Keys | Should -HaveCount 0
      $global:FakeCliCalls | Should -HaveCount 0
    }

    It 'starts a sync only when something changed' {
      $decl = New-Declaration -Container @((New-Container $script:WksDn)) -Insecure
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync $decl
      ($global:FakeCliCalls -join ' ') | Should -BeLike '*ADSync -StartSync*'
      $global:FakeCliCalls.Clear()
      $Ctx = New-AnsibleContext
      & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync $decl
      $global:FakeCliCalls | Should -HaveCount 0
    }

    It 'emits the result as JSON when nothing provides an $Ansible context' {
      Remove-AnsibleContext
      $Json = & $script:ScriptPath @script:Ctx -SyncTimeoutSeconds 0 -DirectorySync (New-Declaration -Container @((New-Container $script:WksDn)) -Insecure) | Out-String
      $Parsed = $Json | ConvertFrom-Json
      $Parsed.realm | Should -Be $script:Realm
      $Parsed.protocol | Should -Be 'ldap'
      $Parsed.containers | Should -Contain $script:WksDn
    }
  }
}
