#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for src/util/Copy-ProjectArtifacts.ps1.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:ScriptPath = Resolve-Path "$PSScriptRoot\..\src\util\Copy-ProjectArtifacts.ps1"

    $script:Root = Join-Path $env:TEMP "WDS_CPA_$(New-Guid)"
    New-Item -ItemType Directory -Path $script:Root | Out-Null

    # Mock Set-Clipboard globally; use $global: so mock closures can assign
    $global:WDS_CPA = $null
    Mock Set-Clipboard { $global:WDS_CPA = $Value }
}

AfterAll {
    Remove-Item $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name WDS_CPA -Scope Global -ErrorAction SilentlyContinue
}

# Helper: reset and capture
function Invoke-Script {
    param([string]$RootPath)
    $global:WDS_CPA = $null
    & $script:ScriptPath -RootPath $RootPath
}

Describe 'Copy-ProjectArtifacts - path not found' {

    It 'exits with code 1' {
        $proc = Start-Process powershell.exe `
            -ArgumentList '-NoProfile','-NonInteractive','-File',
                          $script:ScriptPath, '-RootPath','C:\WDS_NE_99999' `
            -Wait -PassThru -WindowStyle Hidden
        $proc.ExitCode | Should -Be 1
    }
}

Describe 'Copy-ProjectArtifacts - empty directory' {

    BeforeAll {
        $script:EmptyDir = Join-Path $script:Root 'empty'
        New-Item -ItemType Directory -Path $script:EmptyDir | Out-Null
    }

    It 'reports no text files found' {
        Invoke-Script $script:EmptyDir | Should -Match 'No text files'
    }

    It 'does not call Set-Clipboard' {
        Invoke-Script $script:EmptyDir
        Should -Invoke Set-Clipboard -Exactly 0
    }
}

Describe 'Copy-ProjectArtifacts - typical project tree (LLM feed scenario)' {

    BeforeAll {
        $script:ProjDir = Join-Path $script:Root 'project'
        New-Item -ItemType Directory -Path $script:ProjDir | Out-Null
        Set-Content (Join-Path $script:ProjDir 'main.ps1')   'Write-Host "main"'
        Set-Content (Join-Path $script:ProjDir 'helper.ps1') 'function Add { $args[0] + $args[1] }'
        Set-Content (Join-Path $script:ProjDir 'README.md')  '# My Tool'
    }

    It 'reports success'              { Invoke-Script $script:ProjDir | Should -Match 'Success' }
    It 'calls Set-Clipboard once'     { Invoke-Script $script:ProjDir; Should -Invoke Set-Clipboard -Exactly 1 }

    It 'clipboard includes file headers' {
        Invoke-Script $script:ProjDir
        $global:WDS_CPA | Should -Match '=== main\.ps1 ==='
    }

    It 'clipboard includes file content' {
        Invoke-Script $script:ProjDir
        $global:WDS_CPA | Should -Match 'Write-Host'
    }
}

Describe 'Copy-ProjectArtifacts - binary file detection' {

    BeforeAll {
        $script:BinDir = Join-Path $script:Root 'binary'
        New-Item -ItemType Directory -Path $script:BinDir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:BinDir 'tool.exe'), [byte[]](77,90,0,1))
        Set-Content (Join-Path $script:BinDir 'readme.txt') 'This is text'
    }

    It 'skips binary, still succeeds (text file present)' {
        Invoke-Script $script:BinDir | Should -Match 'Success'
    }

    It 'clipboard does not include binary filename' {
        Invoke-Script $script:BinDir
        $global:WDS_CPA | Should -Not -Match 'tool\.exe'
    }
}

Describe 'Copy-ProjectArtifacts - zero-length file (treated as text)' {

    BeforeAll {
        $script:ZeroDir = Join-Path $script:Root 'zero'
        New-Item -ItemType Directory -Path $script:ZeroDir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:ZeroDir 'empty.txt'), [byte[]]@())
    }

    It 'includes empty file and reports success' {
        Invoke-Script $script:ZeroDir | Should -Match 'Success'
    }
}

Describe 'Copy-ProjectArtifacts - .gitignore filtering' {

    BeforeAll {
        $script:GitDir = Join-Path $script:Root 'gitignore'
        New-Item -ItemType Directory -Path $script:GitDir | Out-Null
        Set-Content (Join-Path $script:GitDir '.gitignore') '*.secret'
        Set-Content (Join-Path $script:GitDir 'creds.secret') 'PASSWORD=hunter2'
        Set-Content (Join-Path $script:GitDir 'notes.txt')    'Public notes'
    }

    It 'excludes ignored files from clipboard' {
        Invoke-Script $script:GitDir
        $global:WDS_CPA | Should -Not -Match 'PASSWORD'
    }

    It 'includes non-ignored files in clipboard' {
        Invoke-Script $script:GitDir
        $global:WDS_CPA | Should -Match 'Public notes'
    }
}

Describe 'Copy-ProjectArtifacts - .git/ always excluded' {

    BeforeAll {
        $script:DotGitDir = Join-Path $script:Root 'dotgit'
        New-Item -ItemType Directory -Path $script:DotGitDir | Out-Null
        $gitSub = Join-Path $script:DotGitDir '.git'
        New-Item -ItemType Directory -Path $gitSub | Out-Null
        Set-Content (Join-Path $gitSub 'HEAD')              'ref: refs/heads/main'
        Set-Content (Join-Path $script:DotGitDir 'app.ps1') 'Write-Host "app"'
    }

    It 'excludes .git/ internals from clipboard' {
        Invoke-Script $script:DotGitDir
        $global:WDS_CPA | Should -Not -Match 'refs/heads/main'
    }

    It 'includes regular project files' {
        Invoke-Script $script:DotGitDir
        $global:WDS_CPA | Should -Match 'app\.ps1'
    }
}
