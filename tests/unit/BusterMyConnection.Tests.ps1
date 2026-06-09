#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 test suite for BusterMyConnection.psm1.
#>
Set-StrictMode -Version Latest

BeforeAll {
    # Remove any stale copies loaded by earlier test files in this session
    Get-Module BusterMyConnection, Network -All |
        Remove-Module -Force -ErrorAction SilentlyContinue

    $RepoRoot = Resolve-Path "$PSScriptRoot\.."
    Import-Module "$RepoRoot\src\network\BusterMyConnection.psd1" -Force
    Import-Module "$RepoRoot\src\network\lib\Network.psm1"       -Force
}

Describe 'Invoke-BusterConnectivity' {

    Context 'CNTLM path exists and local proxy is reachable' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path            { $true }
            Mock -ModuleName BusterMyConnection Start-Process        {}
            Mock -ModuleName BusterMyConnection Start-Sleep          {}
            Mock -ModuleName BusterMyConnection Test-LocalProxy      { $true }
            Mock -ModuleName BusterMyConnection Set-ProxyEnvironment {}
        }

        It 'returns Mode=Proxy with Success=$true' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'Proxy'
            $r.Success | Should -BeTrue
        }

        It 'launches the CNTLM process' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Process -Exactly 1
        }

        It 'waits after launching CNTLM' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Sleep -Exactly 1
        }

        It 'activates the proxy environment' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Set-ProxyEnvironment -Exactly 1
        }

        It 'passes ProxyPort to Test-LocalProxy' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -ProxyPort 8080 -Silent
            Should -Invoke -ModuleName BusterMyConnection Test-LocalProxy `
                -ParameterFilter { $Port -eq 8080 } -Exactly 1
        }

        It 'passes TimeoutSeconds to Test-LocalProxy' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -TimeoutSeconds 15 -Silent
            Should -Invoke -ModuleName BusterMyConnection Test-LocalProxy `
                -ParameterFilter { $TimeoutSeconds -eq 15 } -Exactly 1
        }

        It 'does not call Clear-ProxyEnvironment when proxy succeeds' {
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment {}
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 0
        }
    }

    Context 'CNTLM path exists but proxy unreachable; direct succeeds' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path               { $true }
            Mock -ModuleName BusterMyConnection Start-Process           {}
            Mock -ModuleName BusterMyConnection Start-Sleep             {}
            Mock -ModuleName BusterMyConnection Test-LocalProxy         { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment  {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity { $true }
        }

        It 'returns Mode=Direct with Success=$true' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'Direct'
            $r.Success | Should -BeTrue
        }

        It 'clears proxy environment before direct fallback' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 1
        }

        It 'does not activate proxy environment' {
            Mock -ModuleName BusterMyConnection Set-ProxyEnvironment {}
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Set-ProxyEnvironment -Exactly 0
        }

        It 'passes TimeoutSeconds to Test-DirectConnectivity' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -TimeoutSeconds 20 -Silent
            Should -Invoke -ModuleName BusterMyConnection Test-DirectConnectivity `
                -ParameterFilter { $TimeoutSeconds -eq 20 } -Exactly 1
        }
    }

    Context 'CNTLM path exists, proxy fails, direct also fails' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path               { $true }
            Mock -ModuleName BusterMyConnection Start-Process           {}
            Mock -ModuleName BusterMyConnection Start-Sleep             {}
            Mock -ModuleName BusterMyConnection Test-LocalProxy         { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment  {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity { $false }
        }

        It 'returns Mode=None with Success=$false' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'None'
            $r.Success | Should -BeFalse
        }

        It 'clears proxy environment' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 1
        }
    }

    Context 'CNTLM path absent; direct succeeds' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path               { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment  {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity { $true }
        }

        It 'returns Mode=Direct with Success=$true' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'Direct'
            $r.Success | Should -BeTrue
        }

        It 'never launches the CNTLM process' {
            Mock -ModuleName BusterMyConnection Start-Process {}
            Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Process -Exactly 0
        }

        It 'never sleeps' {
            Mock -ModuleName BusterMyConnection Start-Sleep {}
            Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Sleep -Exactly 0
        }

        It 'clears proxy environment' {
            Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 1
        }
    }

    Context 'CNTLM absent and direct fails' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path               { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment  {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity { $false }
        }

        It 'returns Mode=None with Success=$false' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'None'
            $r.Success | Should -BeFalse
        }
    }

    Context 'Verbose output when -Silent is omitted' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path               { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment  {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity { $false }
        }

        It 'does not throw' {
            { Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' } | Should -Not -Throw
        }
    }
}

Describe 'Test-DirectConnectivity' {

    Context 'Test-DirectInternet returns $true' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-DirectInternet { $true }
        }

        It 'returns $true' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity } | Should -BeTrue
        }

        It 'calls Test-DirectInternet exactly once' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity }
            Should -Invoke -ModuleName BusterMyConnection Test-DirectInternet -Exactly 1
        }
    }

    Context 'Test-DirectInternet returns $false' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-DirectInternet { $false }
        }

        It 'returns $false' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity } | Should -BeFalse
        }
    }

    Context 'TimeoutSeconds is forwarded' {

        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-DirectInternet { $true }
        }

        It 'passes the specified value' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity -TimeoutSeconds 12 }
            Should -Invoke -ModuleName BusterMyConnection Test-DirectInternet `
                -ParameterFilter { $TimeoutSeconds -eq 12 } -Exactly 1
        }

        It 'defaults to 5 when not specified' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity }
            Should -Invoke -ModuleName BusterMyConnection Test-DirectInternet `
                -ParameterFilter { $TimeoutSeconds -eq 5 } -Exactly 1
        }
    }
}
