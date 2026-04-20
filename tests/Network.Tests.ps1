#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 test suite for network/lib/Network.psm1.

.DESCRIPTION
    Covers every branch of the four exported functions:
      - Set-ProxyEnvironment
      - Clear-ProxyEnvironment
      - Test-DirectInternet
      - Test-LocalProxy

    Real environment variables are set and cleared in AfterEach/BeforeEach
    blocks. All Invoke-WebRequest calls are mocked with -ModuleName Network
    so that no actual network traffic is ever initiated.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = Resolve-Path "$PSScriptRoot\.."
    Import-Module "$RepoRoot\network\lib\Network.psm1" -Force
}


# ===========================================================================
Describe 'Set-ProxyEnvironment' {
# ===========================================================================

    AfterEach {
        # Always restore a clean slate after each test
        foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY') {
            [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
        }
    }

    It 'sets HTTP_PROXY to the supplied URL' {
        Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'
        $env:HTTP_PROXY | Should -Be 'http://127.0.0.1:3128'
    }

    It 'sets HTTPS_PROXY to the supplied URL' {
        Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'
        $env:HTTPS_PROXY | Should -Be 'http://127.0.0.1:3128'
    }

    It 'sets ALL_PROXY to the supplied URL' {
        Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'
        $env:ALL_PROXY | Should -Be 'http://127.0.0.1:3128'
    }

    It 'sets NO_PROXY to the localhost exclusion list' {
        Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'
        $env:NO_PROXY | Should -Be 'localhost,127.0.0.1'
    }

    It 'accepts any well-formed proxy URL' {
        Set-ProxyEnvironment -ProxyUrl 'http://proxy.corp.example.com:8080'
        $env:HTTP_PROXY | Should -Be 'http://proxy.corp.example.com:8080'
    }
}


# ===========================================================================
Describe 'Clear-ProxyEnvironment' {
# ===========================================================================

    Context 'All proxy environment variables are set' {

        BeforeEach {
            [System.Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy', 'Process')
            [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy', 'Process')
            [System.Environment]::SetEnvironmentVariable('ALL_PROXY',   'http://proxy', 'Process')
            [System.Environment]::SetEnvironmentVariable('NO_PROXY',    'localhost',    'Process')
        }

        AfterEach {
            foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY') {
                [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
            }
        }

        It 'removes HTTP_PROXY' {
            Clear-ProxyEnvironment
            $env:HTTP_PROXY | Should -BeNullOrEmpty
        }

        It 'removes HTTPS_PROXY' {
            Clear-ProxyEnvironment
            $env:HTTPS_PROXY | Should -BeNullOrEmpty
        }

        It 'removes ALL_PROXY' {
            Clear-ProxyEnvironment
            $env:ALL_PROXY | Should -BeNullOrEmpty
        }

        It 'removes NO_PROXY' {
            Clear-ProxyEnvironment
            $env:NO_PROXY | Should -BeNullOrEmpty
        }
    }

    Context 'No proxy environment variables are present' {

        BeforeEach {
            foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY') {
                [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
            }
        }

        It 'does not throw when the environment is already clean' {
            { Clear-ProxyEnvironment } | Should -Not -Throw
        }
    }
}


# ===========================================================================
Describe 'Test-DirectInternet' {
# ===========================================================================

    Context 'First URL succeeds immediately' {

        BeforeAll {
            Mock -ModuleName Network Invoke-WebRequest {}
        }

        It 'returns $true' {
            Test-DirectInternet | Should -BeTrue
        }

        It 'stops after the first successful request (no extra calls)' {
            Test-DirectInternet
            # Only one URL is attempted before returning $true
            Should -Invoke -ModuleName Network Invoke-WebRequest -Exactly 1
        }

        It 'forwards TimeoutSeconds as -TimeoutSec to Invoke-WebRequest' {
            Test-DirectInternet -TimeoutSeconds 9
            Should -Invoke -ModuleName Network Invoke-WebRequest `
                -ParameterFilter { $TimeoutSec -eq 9 } -Exactly 1
        }

        It 'always uses -UseBasicParsing' {
            Test-DirectInternet
            Should -Invoke -ModuleName Network Invoke-WebRequest `
                -ParameterFilter { $UseBasicParsing -eq $true } -Exactly 1
        }
    }

    Context 'First URL fails; second URL succeeds' {

        BeforeAll {
            # Counter lives in script scope so the mock closure can mutate it
            $script:_callCount = 0
            Mock -ModuleName Network Invoke-WebRequest {
                $script:_callCount++
                if ($script:_callCount -eq 1) { throw 'simulated timeout' }
                # Second call succeeds implicitly (no throw)
            }
        }

        BeforeEach {
            $script:_callCount = 0
        }

        It 'returns $true after retrying the second URL' {
            Test-DirectInternet | Should -BeTrue
        }

        It 'calls Invoke-WebRequest exactly twice' {
            Test-DirectInternet
            Should -Invoke -ModuleName Network Invoke-WebRequest -Exactly 2
        }
    }

    Context 'All URLs fail' {

        BeforeAll {
            Mock -ModuleName Network Invoke-WebRequest { throw 'no network' }
        }

        It 'returns $false' {
            Test-DirectInternet | Should -BeFalse
        }

        It 'attempts every URL before giving up' {
            # Network.psm1 has 2 URLs in the loop
            Test-DirectInternet
            Should -Invoke -ModuleName Network Invoke-WebRequest -Exactly 2
        }
    }
}


# ===========================================================================
Describe 'Test-LocalProxy' {
# ===========================================================================

    Context 'Proxy request succeeds' {

        BeforeAll {
            Mock -ModuleName Network Invoke-WebRequest {}
        }

        It 'returns $true' {
            Test-LocalProxy | Should -BeTrue
        }

        It 'calls Invoke-WebRequest with the correct proxy URL (default port 3128)' {
            Test-LocalProxy -Port 3128
            Should -Invoke -ModuleName Network Invoke-WebRequest `
                -ParameterFilter { $Proxy -eq 'http://127.0.0.1:3128' } -Exactly 1
        }

        It 'uses -UseBasicParsing' {
            Test-LocalProxy
            Should -Invoke -ModuleName Network Invoke-WebRequest `
                -ParameterFilter { $UseBasicParsing -eq $true } -Exactly 1
        }
    }

    Context 'Proxy request throws' {

        BeforeAll {
            Mock -ModuleName Network Invoke-WebRequest { throw 'proxy unreachable' }
        }

        It 'returns $false instead of propagating the exception' {
            Test-LocalProxy | Should -BeFalse
        }
    }

    Context 'Custom Port is forwarded' {

        BeforeAll {
            Mock -ModuleName Network Invoke-WebRequest {}
        }

        It 'builds the proxy URL from the supplied Port' {
            Test-LocalProxy -Port 8080
            Should -Invoke -ModuleName Network Invoke-WebRequest `
                -ParameterFilter { $Proxy -eq 'http://127.0.0.1:8080' } -Exactly 1
        }
    }

    Context 'Custom TimeoutSeconds is forwarded' {

        BeforeAll {
            Mock -ModuleName Network Invoke-WebRequest {}
        }

        It 'passes TimeoutSeconds as -TimeoutSec to Invoke-WebRequest' {
            Test-LocalProxy -TimeoutSeconds 15
            Should -Invoke -ModuleName Network Invoke-WebRequest `
                -ParameterFilter { $TimeoutSec -eq 15 } -Exactly 1
        }
    }
}
