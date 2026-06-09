#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for src/Bootstrap-WinDevSandbox.ps1.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:ScriptPath  = Resolve-Path "$PSScriptRoot\..\src\Bootstrap-WinDevSandbox.ps1"
    $script:SandboxRoot = Resolve-Path "$PSScriptRoot\..\src"
}

function Set-CommonMocks {
    Mock Import-Module             {}
    Mock Invoke-BusterConnectivity { @{ Success = $true; Mode = 'Direct' } }
    Mock Unblock-File              {}
    Mock Write-Host                {}
    Mock Write-Warning             {}
}

Describe 'Bootstrap-WinDevSandbox' {

    # -----------------------------------------------------------------------
    Context 'Happy path - toolchain only, all installers skipped' {
    # -----------------------------------------------------------------------

        It 'completes without throwing' {
            Set-CommonMocks
            { . $script:ScriptPath -SandboxRoot $script:SandboxRoot -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer } |
                Should -Not -Throw
        }

        It 'calls Unblock-File at least once' {
            Set-CommonMocks
            . $script:ScriptPath -SandboxRoot $script:SandboxRoot -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer
            Should -Invoke Unblock-File -Times 1 -Scope It
        }

        It 'imports BusterMyConnection' {
            Set-CommonMocks
            . $script:ScriptPath -SandboxRoot $script:SandboxRoot -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer
            Should -Invoke Import-Module -ParameterFilter { $Name -like '*BusterMyConnection*' } -Exactly 1
        }

        It 'calls Invoke-BusterConnectivity with -Silent' {
            Set-CommonMocks
            . $script:ScriptPath -SandboxRoot $script:SandboxRoot -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer
            Should -Invoke Invoke-BusterConnectivity -ParameterFilter { $Silent -eq $true } -Exactly 1
        }
    }

    # -----------------------------------------------------------------------
    Context 'Auto-update - SharedScriptsPath supplied and exists' {
    # -----------------------------------------------------------------------

        BeforeAll {
            # Real empty temp folder - Install-UserScripts will find 0 scripts and exit 0
            $script:FakeShare = Join-Path $env:TEMP "WDS_Share_$(New-Guid)"
            New-Item -ItemType Directory -Path $script:FakeShare | Out-Null
        }
        AfterAll {
            Remove-Item $script:FakeShare -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'reaches the Install-UserScripts path check' {
            Set-CommonMocks
            # Don't mock Test-Path for the installer - the real file exists at src/installers/
            # The script runs with an empty source dir and exits 0 cleanly (no scripts found).
            {
                . $script:ScriptPath `
                    -SandboxRoot       $script:SandboxRoot `
                    -SharedScriptsPath $script:FakeShare   `
                    -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer
            } | Should -Not -Throw
        }

        It 'throws when the shared path does not exist' {
            Set-CommonMocks
            {
                . $script:ScriptPath `
                    -SandboxRoot       $script:SandboxRoot `
                    -SharedScriptsPath 'C:\WDS_NonExistent_Share_99999' `
                    -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer
            } | Should -Throw '*Shared scripts path not found*'
        }
    }

    # -----------------------------------------------------------------------
    Context 'Auto-update - SkipUserScripts suppresses the step' {
    # -----------------------------------------------------------------------

        It 'does not check the installer path when -SkipUserScripts is set' {
            Set-CommonMocks
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*Install-UserScripts.ps1' }

            . $script:ScriptPath `
                -SandboxRoot       $script:SandboxRoot `
                -SharedScriptsPath '\\server\share'    `
                -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer `
                -SkipUserScripts

            Should -Invoke Test-Path -ParameterFilter { $LiteralPath -like '*Install-UserScripts.ps1' } -Exactly 0
        }
    }

    # -----------------------------------------------------------------------
    Context 'Auto-update - SharedScriptsPath empty (default)' {
    # -----------------------------------------------------------------------

        It 'skips Install-UserScripts silently' {
            Set-CommonMocks
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*Install-UserScripts.ps1' }

            . $script:ScriptPath -SandboxRoot $script:SandboxRoot -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer

            Should -Invoke Test-Path -ParameterFilter { $LiteralPath -like '*Install-UserScripts.ps1' } -Exactly 0
        }
    }

    # -----------------------------------------------------------------------
    Context 'Error paths' {
    # -----------------------------------------------------------------------

        It 'throws when Buster module is not found' {
            Mock Import-Module {}; Mock Unblock-File {}; Mock Write-Host {}; Mock Write-Warning {}
            { . $script:ScriptPath -SandboxRoot 'C:\DoesNotExist\Fake' -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer } |
                Should -Throw '*Buster module not found*'
        }

        It 'throws when network connectivity fails' {
            Set-CommonMocks
            Mock Invoke-BusterConnectivity { @{ Success = $false; Mode = 'None' } }
            { . $script:ScriptPath -SandboxRoot $script:SandboxRoot -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer } |
                Should -Throw '*Network bootstrap failed*'
        }

        It 'throws when a toolchain installer is missing' {
            Set-CommonMocks
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -match '\\installers\\' }
            { . $script:ScriptPath -SandboxRoot $script:SandboxRoot } |
                Should -Throw '*Installer not found*'
        }
    }
}
