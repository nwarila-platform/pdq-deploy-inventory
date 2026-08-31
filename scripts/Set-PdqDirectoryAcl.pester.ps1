#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

BeforeAll {
  $ScriptPath = Join-Path -Path:$PSScriptRoot -ChildPath:'Set-PdqDirectoryAcl.ps1'
  $ScriptText = Get-Content -LiteralPath:$ScriptPath -Raw
  $ValidationPath = Join-Path -Path:$PSScriptRoot `
    -ChildPath:'../ansible/applications/pdq_ad_config/tasks/validate.yml'
  $ValidationText = Get-Content -LiteralPath:$ValidationPath -Raw
  $PresentPath = Join-Path -Path:$PSScriptRoot `
    -ChildPath:'../ansible/applications/pdq_ad_config/tasks/present_windows.yml'
  $PresentText = Get-Content -LiteralPath:$PresentPath -Raw
}

Describe 'Set-PdqDirectoryAcl contract' {
  It 'carries the required diagnostic scaffold' {
    $ScriptText | Should -Match ([Regex]::Escape("[System.String] `$DebugLevel = '103'"))
    $ScriptText | Should -Match ([Regex]::Escape("[System.String] `$LogLevel = '002223'"))
    $ScriptText | Should -Match 'Set-StrictMode'
    $ScriptText | Should -Match 'Trap \{'
  }

  It 'declares exactly the five Windows LAPS attributes' {
    $Expected = @(
      'msLAPS-Password'
      'msLAPS-EncryptedPassword'
      'msLAPS-EncryptedPasswordHistory'
      'msLAPS-CurrentPasswordVersion'
      'msLAPS-PasswordExpirationTime'
    )

    ForEach ($Name In $Expected) {
      ([Regex]::Matches($ScriptText, "Name = '$([Regex]::Escape($Name))'")).Count |
        Should -BeExactly 1
    }
  }

  It 'matches ownership through a resolved SID' {
    $ScriptText | Should -Match '\$Identity\.Translate'
    $ScriptText | Should -Match 'RuleSid\.Equals\(\$TargetSid\)'
  }

  It 'fingerprints and proves every other principal unchanged' {
    $ScriptText | Should -Match 'Get-OtherRuleFingerprint'
    $ScriptText | Should -Match 'Test-MultisetEqual -Reference:\$OtherBefore -Difference:\$OtherAfter'
    $ScriptText | Should -Match 'ACL preservation failure'
  }

  It 'removes the complete explicit target set before adding present state' {
    $RemovePosition = $ScriptText.IndexOf('$WorkingAcl.RemoveAccessRuleSpecific($Rule)')
    $AddPosition = $ScriptText.IndexOf('$WorkingAcl.AddAccessRule($Rule)')

    $RemovePosition | Should -BeGreaterThan -1
    $AddPosition | Should -BeGreaterThan $RemovePosition
    $ScriptText | Should -Match "If \(\`$State -eq 'present'\)"
  }

  It 'fails by name for an inherited target LAPS ACE' {
    $ScriptText | Should -Match 'Inherited LAPS ACE failure'
    $ScriptText | Should -Match '\$PSItem\.IsInherited -eq \$Inherited'
  }
}

Describe 'Role prerequisite contract' {
  It 'names all four LAPS prerequisite failures' {
    $ValidationText | Should -Match 'LAPS cmdlet prerequisite failed'
    $ValidationText | Should -Match 'LAPS schema prerequisite failed'
    $ValidationText | Should -Match 'LAPS SELF-write prerequisite failed'
    $ValidationText | Should -Match 'LAPS BackupDirectory prerequisite failed'
  }

  It 'requires BackupDirectory to be DWORD 2' {
    $ValidationText | Should -Match 'BackupDirectory'
    $ValidationText | Should -Match 'DWord'
    $ValidationText | Should -Match '-ne 2'
  }

  It 'does not require a computer to have stored a password' {
    $ValidationText | Should -Not -Match 'Get-LapsADPassword.*-Identity'
  }
}

Describe 'Password decision contract' {
  It 'proves every false switch form including absence' {
    $ValidationText | Should -Match "not \('false' \| bool\)"
    $ValidationText | Should -Match "not \('False' \| bool\)"
    $ValidationText | Should -Match 'not \(false \| bool\)'
    $ValidationText | Should -Match 'default\(false\) \| bool'
  }

  It 'proves every true switch form' {
    $ValidationText | Should -Match "\('true' \| bool\)"
    $ValidationText | Should -Match "\('True' \| bool\)"
    $ValidationText | Should -Match '\(true \| bool\)'
  }

  It 'always consumes the rotation switch through bool' {
    $PresentText | Should -Not -Match '(?m)^\s*when:\s*rotate_password\s*$'
    $PresentText | Should -Match 'rotate_password \| default\(false\) \| bool'
  }

  It 'generates and writes only for rows one through four' {
    ([Regex]::Matches(
        $PresentText,
        'decision_row__ \| int\) in \[ 1, 2, 3, 4 \]'
      )).Count | Should -BeGreaterThan 1
  }

  It 'selects the stored value for row six without an S3 write' {
    $PresentText | Should -Match 'else __pdq_ad_config_secret_read__\.contents'
    $PresentText | Should -Match 'mode: ''put'''
  }

  It 'places the S3 put before the directory password update' {
    $PutPosition = $PresentText.IndexOf("mode: 'put'")
    $UserPosition = $PresentText.IndexOf('microsoft.ad.user:')

    $PutPosition | Should -BeGreaterThan -1
    $UserPosition | Should -BeGreaterThan $PutPosition
  }
}
