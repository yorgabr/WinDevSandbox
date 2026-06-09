#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 test suite for network/lib/Network.psm1.
#>
Set-StrictMode -Version Latest

BeforeAll {
    # Remove any stale copies loaded by earlier test files in this session
    Get-Module Network -All | Remove-Module -Force -ErrorAction SilentlyContinue

    $RepoRoot = Resolve-Path "$PSScriptRoot\.."
    Import-Module "$RepoRoot\src\network\lib\Network.psm1" -Force
}

Describe 'Set-ProxyEnvironment' {

    AfterEach {
        foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
            [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
        }
    }

    It 'sets HTTP_PROXY'  { Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'; $env:HTTP_PROXY  | Should -Be 'http://127.0.0.1:3128' }
    It 'sets HTTPS_PROXY' { Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'; $env:HTTPS_PROXY | Should -Be 'http://127.0.0.1:3128' }
    It 'sets ALL_PROXY'   { Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'; $env:ALL_PROXY   | Should -Be 'http://127.0.0.1:3128' }
    It 'sets NO_PROXY to localhost exclusion list' { Set-ProxyEnvironment -ProxyUrl 'http://127.0.0.1:3128'; $env:NO_PROXY | Should -Be 'localhost,127.0.0.1' }
    It 'accepts any well-formed URL' { Set-ProxyEnvironment -ProxyUrl 'http://proxy.corp:8080'; $env:HTTP_PROXY | Should -Be 'http://proxy.corp:8080' }
}

Describe 'Clear-ProxyEnvironment' {

    Context 'All proxy vars are set' {

        BeforeEach {
            foreach ($k in @{HTTP_PROXY='http://p';HTTPS_PROXY='http://p';ALL_PROXY='http://p';NO_PROXY='localhost'}.GetEnumerator()) {
                [System.Environment]::SetEnvironmentVariable($k.Key, $k.Value, 'Process')
            }
        }
        AfterEach {
            foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
                [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
            }
        }

        It 'removes HTTP_PROXY'  { Clear-ProxyEnvironment; $env:HTTP_PROXY  | Should -BeNullOrEmpty }
        It 'removes HTTPS_PROXY' { Clear-ProxyEnvironment; $env:HTTPS_PROXY | Should -BeNullOrEmpty }
        It 'removes ALL_PROXY'   { Clear-ProxyEnvironment; $env:ALL_PROXY   | Should -BeNullOrEmpty }
        It 'removes NO_PROXY'    { Clear-ProxyEnvironment; $env:NO_PROXY    | Should -BeNullOrEmpty }
    }

    Context 'No proxy vars present' {

        BeforeEach {
            foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
                [System.Environment]::SetEnvironmentVariable($k, $null, 'Process')
            }
        }

        It 'does not throw' { { Clear-ProxyEnvironment } | Should -Not -Throw }
    }
}

Describe 'Test-DirectInternet' {

    Context 'First URL succeeds' {

        BeforeAll {
            Mock -ModuleName Network Invoke-WebRequest {}
        }

        It 'returns $true'                             { Test-DirectInternet | Should -BeTrue }
        It 'stops after first success (1 call)'        { Test-DirectInternet; Should -Invoke -ModuleName Network Invoke-WebRequest -Exactly 1 }
        It 'forwards TimeoutSeconds as -TimeoutSec'    { Test-DirectInternet -TimeoutSeconds 9; Should -Invoke -ModuleName Network Invoke-WebRequest -ParameterFilter { $TimeoutSec -eq 9 } -Exactly 1 }
        It 'always uses -UseBasicParsing'              { Test-DirectInternet; Should -Invoke -ModuleName Network Invoke-WebRequest -ParameterFilter { $UseBasicParsing -eq $true } -Exactly 1 }
    }

    Context 'First URL fails; second succeeds' {

        BeforeAll {
            $script:_n = 0
            Mock -ModuleName Network Invoke-WebRequest {
                $script:_n++
                if ($script:_n -eq 1) { throw 'timeout' }
            }
        }
        BeforeEach { $script:_n = 0 }

        It 'returns $true'            { Test-DirectInternet | Should -BeTrue }
        It 'calls Invoke-WebRequest twice' { Test-DirectInternet; Should -Invoke -ModuleName Network Invoke-WebRequest -Exactly 2 }
    }

    Context 'All URLs fail' {

        BeforeAll { Mock -ModuleName Network Invoke-WebRequest { throw 'no net' } }

        It 'returns $false'                    { Test-DirectInternet | Should -BeFalse }
        It 'tries every URL before giving up'  { Test-DirectInternet; Should -Invoke -ModuleName Network Invoke-WebRequest -Exactly 2 }
    }
}

Describe 'Test-LocalProxy' {

    Context 'Request succeeds' {

        BeforeAll { Mock -ModuleName Network Invoke-WebRequest {} }

        It 'returns $true'                              { Test-LocalProxy | Should -BeTrue }
        It 'builds proxy URL from default port 3128'    { Test-LocalProxy -Port 3128; Should -Invoke -ModuleName Network Invoke-WebRequest -ParameterFilter { $Proxy -eq 'http://127.0.0.1:3128' } -Exactly 1 }
        It 'uses -UseBasicParsing'                      { Test-LocalProxy; Should -Invoke -ModuleName Network Invoke-WebRequest -ParameterFilter { $UseBasicParsing -eq $true } -Exactly 1 }
    }

    Context 'Request throws' {

        BeforeAll { Mock -ModuleName Network Invoke-WebRequest { throw 'unreachable' } }

        It 'returns $false (no exception)' { Test-LocalProxy | Should -BeFalse }
    }

    Context 'Custom Port' {

        BeforeAll { Mock -ModuleName Network Invoke-WebRequest {} }

        It 'builds proxy URL from custom port' { Test-LocalProxy -Port 8080; Should -Invoke -ModuleName Network Invoke-WebRequest -ParameterFilter { $Proxy -eq 'http://127.0.0.1:8080' } -Exactly 1 }
    }

    Context 'Custom TimeoutSeconds' {

        BeforeAll { Mock -ModuleName Network Invoke-WebRequest {} }

        It 'passes TimeoutSeconds as -TimeoutSec' { Test-LocalProxy -TimeoutSeconds 15; Should -Invoke -ModuleName Network Invoke-WebRequest -ParameterFilter { $TimeoutSec -eq 15 } -Exactly 1 }
    }
}
