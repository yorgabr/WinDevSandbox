#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for src/util/Install-UserScripts.ps1.
#>
Set-StrictMode -Version Latest

BeforeAll {
    # The standalone version lives in util/; the installer copy is in installers/
    $script:ScriptPath = Resolve-Path "$PSScriptRoot\..\src\util\Install-UserScripts.ps1"

    $script:TempSrc  = Join-Path $env:TEMP "WDS_TestSrc_$(New-Guid)"
    $script:TempDest = Join-Path $env:TEMP "WDS_TestDest_$(New-Guid)"
    New-Item -ItemType Directory -Path $script:TempSrc  | Out-Null
    New-Item -ItemType Directory -Path $script:TempDest | Out-Null

    Set-Content -Path (Join-Path $script:TempSrc 'Deploy-Tool.ps1') -Value @'
param(
    [Parameter(Mandatory=$false)]
    [string]$Env,
    [Parameter(Mandatory=$false)]
    [int]$Retries
)
Write-Host "Deploying to $Env"
'@

    Mock Copy-Item   {}
    Mock New-Item    {} -ParameterFilter { $ItemType -eq 'Directory' }
    Mock Set-Content {}
    Mock Add-Content {}

    . $script:ScriptPath -SourcePath $script:TempSrc -DestPath $script:TempDest -NoPathUpdate
}

AfterAll {
    Remove-Item $script:TempSrc  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:TempDest -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Auto-update end-to-end (dot-source)' {
    It 'copies Deploy-Tool.ps1 from source to destination' {
        Should -Invoke Copy-Item -ParameterFilter { $LiteralPath -like '*Deploy-Tool.ps1' } -Times 1 -Scope Describe
    }
}

Describe 'Get-Platform' {
    It 'returns Windows under PS 5.1 Desktop' { Get-Platform | Should -Be 'Windows' }
}

Describe 'Get-DefaultDestPath' {
    It 'returns a path under LOCALAPPDATA for Windows' { Get-DefaultDestPath -Platform 'Windows' | Should -BeLike "$env:LOCALAPPDATA*" }
    It 'returns ~/.local/bin for Linux'                { Get-DefaultDestPath -Platform 'Linux'   | Should -BeLike '*.local*bin*' }
    It 'returns ~/.local/bin for MacOS'                { Get-DefaultDestPath -Platform 'MacOS'   | Should -BeLike '*.local*bin*' }
}

Describe 'Get-ShellProfilePath' {
    It 'returns a non-empty path for Windows' { Get-ShellProfilePath -Platform 'Windows' | Should -Not -BeNullOrEmpty }
}

Describe 'Test-PathInEnvironment' {
    It 'returns $true when path is in Windows user PATH' {
        $fake = 'C:\WDS_FakeBin'
        $orig = [System.Environment]::GetEnvironmentVariable('PATH','User')
        try {
            [System.Environment]::SetEnvironmentVariable('PATH',"$orig;$fake",'User')
            Test-PathInEnvironment -PathToCheck $fake -Platform 'Windows' | Should -BeTrue
        } finally {
            [System.Environment]::SetEnvironmentVariable('PATH',$orig,'User')
        }
    }

    It 'returns $false when path is absent' {
        Test-PathInEnvironment -PathToCheck 'C:\WDS_Absent_999' -Platform 'Windows' | Should -BeFalse
    }
}

Describe 'Get-ScriptFiles' {
    It 'finds .ps1 as PowerShell type'                { (Get-ScriptFiles -SourceDirectory $script:TempSrc | Where-Object { $_.Type -eq 'PowerShell' }) | Should -Not -BeNullOrEmpty }
    It 'preserves filename as DestName for .ps1'      { (Get-ScriptFiles -SourceDirectory $script:TempSrc | Where-Object { $_.Type -eq 'PowerShell' } | Select-Object -First 1).DestName | Should -Be 'Deploy-Tool.ps1' }

    It 'returns empty for a directory with no scripts' {
        $empty = Join-Path $env:TEMP "WDS_Empty_$(New-Guid)"
        New-Item -ItemType Directory -Path $empty | Out-Null
        try { (Get-ScriptFiles -SourceDirectory $empty).Count | Should -Be 0 }
        finally { Remove-Item $empty -Force -ErrorAction SilentlyContinue }
    }

    It 'strips .sh extension for shell scripts' {
        $shDir = Join-Path $env:TEMP "WDS_Sh_$(New-Guid)"
        New-Item -ItemType Directory -Path $shDir | Out-Null
        Set-Content -Path (Join-Path $shDir 'run.sh') -Value '#!/bin/bash'
        try {
            (Get-ScriptFiles -SourceDirectory $shDir | Where-Object { $_.Type -eq 'Shell' } | Select-Object -First 1).DestName | Should -Be 'run'
        } finally { Remove-Item $shDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Install-Script' {
    BeforeAll {
        $script:FakeInfo = @{ Source=(Join-Path $script:TempSrc 'Deploy-Tool.ps1'); Name='Deploy-Tool.ps1'; Type='PowerShell'; DestName='Deploy-Tool.ps1' }
    }

    It 'returns $true on success' {
        Mock Copy-Item {}
        Install-Script -ScriptInfo $script:FakeInfo -DestinationDirectory $script:TempDest -Force | Should -BeTrue
    }

    It 'calls Copy-Item with correct LiteralPath' {
        Mock Copy-Item {}
        Install-Script -ScriptInfo $script:FakeInfo -DestinationDirectory $script:TempDest -Force
        Should -Invoke Copy-Item -ParameterFilter { $LiteralPath -like '*Deploy-Tool.ps1' } -Exactly 1
    }

    It 'returns $false when file exists and -Force is omitted' {
        $dest = Join-Path $script:TempDest 'Deploy-Tool.ps1'
        New-Item -ItemType File -Path $dest -Force -ErrorAction SilentlyContinue | Out-Null
        try { Install-Script -ScriptInfo $script:FakeInfo -DestinationDirectory $script:TempDest | Should -BeFalse }
        finally { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
    }

    It 'overwrites with -Force (auto-update scenario)' {
        $dest = Join-Path $script:TempDest 'Deploy-Tool.ps1'
        New-Item -ItemType File -Path $dest -Force -ErrorAction SilentlyContinue | Out-Null
        Mock Copy-Item {}
        try { Install-Script -ScriptInfo $script:FakeInfo -DestinationDirectory $script:TempDest -Force | Should -BeTrue }
        finally { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Generate-PowerShellCompletion' {
    It 'returns $null for a plain script with no [Parameter] blocks' {
        $plain = Join-Path $env:TEMP "WDS_Plain_$(New-Guid).ps1"
        Set-Content $plain 'Write-Host "hi"'
        try { Generate-PowerShellCompletion -ScriptPath $plain -ScriptName 'Plain.ps1' | Should -BeNullOrEmpty }
        finally { Remove-Item $plain -Force -ErrorAction SilentlyContinue }
    }

    It 'generates a Register-ArgumentCompleter block for a parameterised script' {
        $result = Generate-PowerShellCompletion -ScriptPath (Join-Path $script:TempSrc 'Deploy-Tool.ps1') -ScriptName 'Deploy-Tool.ps1'
        $result | Should -Not -BeNullOrEmpty
        $result | Should -BeLike '*Register-ArgumentCompleter*'
    }
}

Describe 'Add-PathToEnvironment' {
    It 'adds a new entry to Windows user PATH' {
        $newPath = "C:\WDS_NewBin_$(New-Guid)"
        $orig = [System.Environment]::GetEnvironmentVariable('PATH','User')
        try {
            Add-PathToEnvironment -NewPath $newPath -Platform 'Windows' -ProfilePath ''
            [System.Environment]::GetEnvironmentVariable('PATH','User') | Should -BeLike "*$newPath*"
        } finally { [System.Environment]::SetEnvironmentVariable('PATH',$orig,'User') }
    }

    It 'returns $true after adding' {
        $newPath = "C:\WDS_NewBin2_$(New-Guid)"
        $orig = [System.Environment]::GetEnvironmentVariable('PATH','User')
        try {
            Add-PathToEnvironment -NewPath $newPath -Platform 'Windows' -ProfilePath '' | Should -BeTrue
        } finally { [System.Environment]::SetEnvironmentVariable('PATH',$orig,'User') }
    }

    It 'does not duplicate an already-present entry' {
        $existingPath = "C:\WDS_Existing_$(New-Guid)"
        $orig = [System.Environment]::GetEnvironmentVariable('PATH','User')
        try {
            [System.Environment]::SetEnvironmentVariable('PATH',"$orig;$existingPath",'User')
            Add-PathToEnvironment -NewPath $existingPath -Platform 'Windows' -ProfilePath ''
            $updated = [System.Environment]::GetEnvironmentVariable('PATH','User')
            ($updated -split ';' | Where-Object { $_ -eq $existingPath }).Count | Should -Be 1
        } finally { [System.Environment]::SetEnvironmentVariable('PATH',$orig,'User') }
    }
}
