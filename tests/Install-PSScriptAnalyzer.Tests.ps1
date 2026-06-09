#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for src/installers/Install-PSScriptAnalyzer.ps1.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:ScriptPath = Resolve-Path "$PSScriptRoot\..\src\installers\Install-PSScriptAnalyzer.ps1"

    # Force early-return to get helper functions into scope without real side-effects
    Mock Test-Path     { $true }
    Mock Import-Module {}

    . $script:ScriptPath -Quiet
}

AfterAll {
    foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') {
        [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
    }
}

Describe 'Install-PSScriptAnalyzer - idempotency' {

    Context 'Already installed and importable' {

        It 'does not download the package' {
            # Must register Invoke-WebRequest mock BEFORE asserting on it
            Mock Invoke-WebRequest {}
            Mock Test-Path         { $true }
            Mock Import-Module     {}

            { . $script:ScriptPath -Quiet } | Should -Not -Throw

            Should -Invoke Import-Module     -Times 1  -Scope It
            Should -Invoke Invoke-WebRequest -Exactly 0
        }

        It 'does not throw with -Quiet' {
            Mock Test-Path     { $true }
            Mock Import-Module {}
            { . $script:ScriptPath -Quiet } | Should -Not -Throw
        }
    }
}

Describe 'Get-ProxyFromEnvironment' {

    AfterEach {
        foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') {
            [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
        }
    }

    It 'returns HTTPS proxy for https URL when HTTPS_PROXY is set' {
        $env:HTTPS_PROXY = 'http://proxy.corp:3128'
        $proxy = Get-ProxyFromEnvironment -TargetUrl 'https://example.com'
        $proxy | Should -Not -BeNullOrEmpty
        $proxy.Address.ToString() | Should -BeLike '*3128*'
    }

    It 'returns HTTP proxy when HTTP_PROXY is set' {
        $env:HTTP_PROXY = 'http://proxy.corp:8080'
        Get-ProxyFromEnvironment -TargetUrl 'http://example.com' | Should -Not -BeNullOrEmpty
    }

    It 'returns ALL_PROXY when only ALL_PROXY is set' {
        $env:ALL_PROXY = 'http://proxy.corp:8888'
        Get-ProxyFromEnvironment -TargetUrl 'http://example.com' | Should -Not -BeNullOrEmpty
    }

    It 'returns $null when no proxy vars are set' {
        Get-ProxyFromEnvironment -TargetUrl 'https://example.com' | Should -BeNullOrEmpty
    }
}

Describe 'Validate-FileHash' {

    It 'does not throw when hashes match' {
        Mock Get-FileHash { [PSCustomObject]@{ Hash = 'ABCDEF1234' } }
        { Validate-FileHash -Path 'fake.nupkg' -Algorithm 'SHA256' -Expected 'ABCDEF1234' } | Should -Not -Throw
    }

    It 'throws when hashes differ' {
        Mock Get-FileHash { [PSCustomObject]@{ Hash = 'REALAAAA' } }
        { Validate-FileHash -Path 'fake.nupkg' -Algorithm 'SHA256' -Expected 'WRONGBBB' } | Should -Throw '*Integrity verification failed*'
    }

    It 'does not throw when no expected hash (log-only)' {
        Mock Get-FileHash { [PSCustomObject]@{ Hash = 'ANYTHING' } }
        { Validate-FileHash -Path 'fake.nupkg' -Algorithm 'SHA256' -Expected '' } | Should -Not -Throw
    }

    It 'comparison is case-insensitive' {
        Mock Get-FileHash { [PSCustomObject]@{ Hash = 'abcdef' } }
        { Validate-FileHash -Path 'fake.nupkg' -Algorithm 'SHA256' -Expected 'ABCDEF' } | Should -Not -Throw
    }
}

Describe 'Test-ModuleStructure' {

    Context 'Both required files present' {
        It 'returns $true' {
            Mock Test-Path { $true }
            Mock Import-PowerShellDataFile { @{ ModuleVersion = '1.24.0' } }
            Test-ModuleStructure -Root 'C:\FakeRoot' | Should -BeTrue
        }
    }

    Context 'psd1 missing' {
        It 'returns $false' {
            Mock Test-Path { $false } -ParameterFilter { $Path -like '*.psd1' }
            Mock Test-Path { $true  }
            Test-ModuleStructure -Root 'C:\FakeRoot' | Should -BeFalse
        }
    }

    Context 'DLL missing' {
        It 'returns $false' {
            Mock Test-Path { $true  } -ParameterFilter { $Path -like '*.psd1' }
            Mock Test-Path { $false } -ParameterFilter { $Path -like '*.dll'  }
            Mock Import-PowerShellDataFile { @{ ModuleVersion = '1.24.0' } }
            Test-ModuleStructure -Root 'C:\FakeRoot' | Should -BeFalse
        }
    }
}

Describe 'Sign-ModuleFiles' {

    It 'does not throw when cert is $null' {
        { Sign-ModuleFiles -TargetDir 'C:\FakeDir' -Cert $null } | Should -Not -Throw
    }

    It 'calls Set-AuthenticodeSignature for each PS file when cert is supplied' {
        # Use New-MockObject to create a properly typed X509Certificate2 instance
        # without triggering the "Thumbprint is ReadOnly" cast error that occurs
        # when passing a plain PSCustomObject to the typed [X509Certificate2] param.
        $fakeCert = New-MockObject -Type System.Security.Cryptography.X509Certificates.X509Certificate2
        Mock Get-ChildItem {
            @(
                [PSCustomObject]@{ FullName='C:\Fake\M.psm1'; Name='M.psm1' },
                [PSCustomObject]@{ FullName='C:\Fake\M.psd1'; Name='M.psd1' }
            )
        }
        Mock Set-AuthenticodeSignature { [PSCustomObject]@{ Status = 'Valid' } }

        Sign-ModuleFiles -TargetDir 'C:\FakeDir' -Cert $fakeCert

        Should -Invoke Set-AuthenticodeSignature -Exactly 2
    }

    It 'does not throw when no PS files found' {
        $fakeCert = New-MockObject -Type System.Security.Cryptography.X509Certificates.X509Certificate2
        Mock Get-ChildItem { @() }
        { Sign-ModuleFiles -TargetDir 'C:\FakeDir' -Cert $fakeCert } | Should -Not -Throw
    }
}
