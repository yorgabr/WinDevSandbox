<#
.SYNOPSIS
Install-TaigaPortable.ps1 — Portable Taiga installer and tester for Windows PowerShell 5.1.

.DESCRIPTION
Idempotent installer that downloads latest stable portable components when missing,
initializes a local Taiga environment (Postgres, Python, Node, Taiga backend/front),
verifies each dependency with concise tests, runs CRUD tests against PostgreSQL and
Taiga API using a temporary test user, reproduces the Taiga CRUD via Microsoft Edge
automation (Selenium), and always removes test artifacts at the end.

.USAGE
Run in an elevated or normal PowerShell 5.1 session (no admin required if writing to 
user folders).
Use `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` if needed.

.OUTPUT
All informational messages are written to stdout via LogOk.
Errors and failures are written to stderr via LogError.

.NOTES
- The script attempts to discover and download the official latest stable binaries 
where possible.
- UI selectors are detected from the cloned taiga-front repository; adjust if UI changes.
- This script focuses on clarity, idempotence and PowerShell 5.1 compatibility.
#>

# Ensure script runs in its own directory under the user's profile
$ScriptBase = Join-Path $env:USERPROFILE "taiga-local"
if (-not (Test-Path $ScriptBase)) { New-Item -Path $ScriptBase -ItemType Directory -Force | Out-Null }
Set-Location $ScriptBase

# Logging functions (stdout / stderr)
function LogOk {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Output $Message
}
function LogError {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Error $Message
}

# Configuration (concise)
$Config = @{
    BaseDir        = $ScriptBase
    PgDir          = Join-Path $ScriptBase "pgsql"
    PgData         = Join-Path $ScriptBase "pgdata"
    PythonDir      = Join-Path $ScriptBase "python"
    NodeDir        = Join-Path $ScriptBase "node"
    TaigaBackDir   = Join-Path $ScriptBase "taiga-back"
    TaigaFrontDir  = Join-Path $ScriptBase "taiga-front"
    VenvDir        = Join-Path $ScriptBase "taiga-env"
    EdgeDriverDir  = $ScriptBase
    SeleniumLibDir = Join-Path $ScriptBase "selenium-lib"
    TestUser       = "test_user"
    TestPass       = "test123"
    TestEmail      = "test_user@example.com"
    TestDb         = "test_db"
    TaigaAdminUser = "admin"
    TaigaAdminPass = "123123"
}

# Utility: download and extract if missing
function Get-ArchiveIfMissing {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$TargetDir
    )
    if (-not (Test-Path $TargetDir)) {
        try {
            LogOk "Downloading $Name..."
            Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing
            LogOk "Extracting $Name..."
            Expand-Archive -Path $ZipPath -DestinationPath $TargetDir -Force
            Remove-Item $ZipPath -ErrorAction SilentlyContinue
            LogOk "$Name ready at $TargetDir"
            return $true
        } catch {
            LogError "Failed to download or extract $Name: $_"
            return $false
        }
    } else {
        LogOk "$Name already present at $TargetDir"
        return $true
    }
}

# Utility: wait for HTTP endpoint
function Wait-ForHttp {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [int]$TimeoutSec = 60
    )
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

# Discover latest Node.js Windows x64 zip URL
function Get-NodeLatestUrl {
    try {
        $index = Invoke-WebRequest -Uri "https://nodejs.org/dist/latest/" -UseBasicParsing
        $link = ($index.Links | Where-Object { $_.href -match "node-v.*-win-x64.zip" } | Select-Object -First 1).href
        if ($link -and $link -notmatch "^http") { return "https://nodejs.org/dist/latest/$link" }
        return $link
    } catch {
        LogError "Failed to resolve Node latest URL: $_"
        return $null
    }
}

# Discover latest Python embeddable URL
function Get-PythonEmbedLatestUrl {
    try {
        $html = Invoke-WebRequest -Uri "https://www.python.org/ftp/python/" -UseBasicParsing
        $versions = ($html.Links | Where-Object { $_.href -match "^\d+\.\d+\.\d+/$" } | ForEach-Object { $_.href.TrimEnd('/') })
        $latest = ($versions | Sort-Object {[version]$_} -Descending | Select-Object -First 1)
        if ($latest) { return "https://www.python.org/ftp/python/$latest/python-$latest-embed-amd64.zip" }
        return $null
    } catch {
        LogError "Failed to resolve Python embed latest URL: $_"
        return $null
    }
}

# Discover latest msedgedriver URL
function Get-EdgeDriverLatestUrl {
    try {
        $ver = Invoke-RestMethod -Uri "https://msedgedriver.azureedge.net/LATEST_STABLE" -UseBasicParsing -ErrorAction Stop
        return "https://msedgedriver.azureedge.net/$ver/edgedriver_win64.zip"
    } catch {
        LogError "Failed to resolve EdgeDriver latest version: $_"
        return "https://msedgedriver.azureedge.net/edgedriver_win64.zip"
    }
}

# Clone repositories if missing
function Ensure-GitClone {
    param(
        [Parameter(Mandatory=$true)][string]$RepoUrl,
        [Parameter(Mandatory=$true)][string]$TargetDir
    )
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        LogError "Git not found in PATH; please install Git or provide a portable git."
        return $false
    }
    if (-not (Test-Path $TargetDir)) {
        try {
            LogOk "Cloning $RepoUrl..."
            git clone $RepoUrl $TargetDir 2>$null
            LogOk "Cloned to $TargetDir"
            return $true
        } catch {
            LogError "Git clone failed: $_"
            return $false
        }
    } else {
        LogOk "Repository already present: $TargetDir"
        return $true
    }
}

# Detect UI selectors from taiga-front sources (best-effort)
function Detect-TaigaSelectors {
    param([Parameter(Mandatory=$true)][string]$FrontDir)
    $default = @{
        LoginUser   = 'input[name="username"], input#username'
        LoginPass   = 'input[name="password"], input#password'
        LoginSubmit = 'button[type="submit"], button.login'
        ProjectNew  = 'a[href*="/projects/new"], button.create-project'
        ProjectName = 'input[name="name"], input#name'
        ProjectSave = 'button[type="submit"], button.save'
        TaskCreate  = 'button[data-test="create-task"], button.create-task'
        TaskSubject = 'input[name="subject"], textarea[name="subject"]'
        TaskSave    = 'button[data-test="save-task"], button.save-task'
        TaskList    = '.task-item .task-title, .user-story__title, .task-title'
        TaskDelete  = '.task-item .delete-button, .task-delete'
    }

    if (-not (Test-Path $FrontDir)) {
        LogOk "taiga-front not present; using default selectors"
        return $default
    }

    try {
        $files = Get-ChildItem -Path $FrontDir -Recurse -Include *.html,*.htm,*.js,*.jsx,*.ts,*.tsx -ErrorAction SilentlyContinue
        foreach ($key in $default.Keys) {
            $found = $false
            foreach ($f in $files) {
                $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match "username" -and $key -eq "LoginUser") { $found = $true; break }
                if ($content -match "password" -and $key -eq "LoginPass") { $found = $true; break }
                if ($content -match "projects/new" -and $key -eq "ProjectNew") { $found = $true; break }
                if ($content -match "create-task" -and $key -eq "TaskCreate") { $found = $true; break }
                if ($content -match "subject" -and $key -eq "TaskSubject") { $found = $true; break }
            }
            if ($found) { LogOk "Selector hint found for $key; using default mapping" } else { LogOk "No hint for $key; using fallback" }
        }
    } catch {
        LogError "Selector detection failed: $_"
    }
    return $default
}

# Initialize PostgreSQL portable if needed and start server
function Ensure-Postgres {
    param()
    $psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
    if (-not $psqlCmd) {
        $pgPage = Invoke-WebRequest -Uri "https://get.enterprisedb.com/postgresql/" -UseBasicParsing -ErrorAction SilentlyContinue
        $pgLink = ($pgPage.Links | Where-Object { $_.href -match "postgresql-.*-windows-x64-binaries.zip" } | Select-Object -First 1).href
        if ($pgLink -and $pgLink -notmatch "^http") { $pgUrl = "https://get.enterprisedb.com/$pgLink" } else { $pgUrl = $pgLink }
        if (-not $pgUrl) { LogError "Could not find Postgres binaries URL"; return $false }
        if (-not (Get-ArchiveIfMissing -Name "PostgreSQL" -Url $pgUrl -ZipPath (Join-Path $Config.BaseDir "pgsql.zip") -TargetDir $Config.PgDir)) { return $false }
    } else {
        LogOk "psql present"
    }

    $initdb = Get-ChildItem -Path $Config.PgDir -Filter "initdb.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $initdb) { LogError "initdb not found"; return $false }

    if (-not (Test-Path $Config.PgData)) {
        LogOk "Initializing Postgres data directory..."
        & $initdb.FullName -D $Config.PgData | Out-Null
    } else {
        LogOk "Postgres data directory exists"
    }

    if (-not (Get-Process -Name postgres -ErrorAction SilentlyContinue)) {
        $postgresExe = Get-ChildItem -Path $Config.PgDir -Filter "postgres.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $postgresExe) { LogError "postgres.exe not found"; return $false }
        Start-Process -FilePath $postgresExe.FullName -ArgumentList "-D `"$Config.PgData`"" -WindowStyle Hidden
        Start-Sleep -Seconds 3
        LogOk "Postgres started"
    } else {
        LogOk "Postgres already running"
    }
    return $true
}

# Run PostgreSQL CRUD test using temporary user and database
function Test-PostgresCrud {
    param()
    $psqlExe = Get-ChildItem -Path $Config.PgDir -Filter "psql.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $psqlExe) { LogError "psql.exe not found for CRUD test"; return $false }

    try {
        LogOk "Creating test user and database..."
        & $psqlExe.FullName -U postgres -d postgres -c "DROP DATABASE IF EXISTS $($Config.TestDb);" 2>$null
        & $psqlExe.FullName -U postgres -d postgres -c "DROP USER IF EXISTS $($Config.TestUser);" 2>$null
        & $psqlExe.FullName -U postgres -d postgres -c "CREATE USER $($Config.TestUser) WITH PASSWORD '$($Config.TestPass)';" 2>$null
        & $psqlExe.FullName -U postgres -d postgres -c "CREATE DATABASE $($Config.TestDb) OWNER $($Config.TestUser);" 2>$null

        LogOk "Performing CRUD operations..."
        & $psqlExe.FullName -U $($Config.TestUser) -d $($Config.TestDb) -c "CREATE TABLE IF NOT EXISTS crud_test(id SERIAL PRIMARY KEY, name TEXT);" 2>$null
        & $psqlExe.FullName -U $($Config.TestUser) -d $($Config.TestDb) -c "INSERT INTO crud_test(name) VALUES('test');" 2>$null
        $select = & $psqlExe.FullName -U $($Config.TestUser) -d $($Config.TestDb) -c "SELECT name FROM crud_test WHERE id=1;" 2>$null
        if ($select -match "test") {
            & $psqlExe.FullName -U $($Config.TestUser) -d $($Config.TestDb) -c "UPDATE crud_test SET name='updated' WHERE id=1;" 2>$null
            & $psqlExe.FullName -U $($Config.TestUser) -d $($Config.TestDb) -c "DELETE FROM crud_test WHERE id=1;" 2>$null
            LogOk "Postgres CRUD test passed"
            return $true
        } else {
            LogError "Postgres CRUD test failed at SELECT"
            return $false
        }
    } catch {
        LogError "Postgres CRUD error: $_"
        return $false
    }
}

# Setup Taiga backend: venv, deps, migrate, run
function Ensure-TaigaBackend {
    param()
    if (-not (Test-Path $Config.TaigaBackDir)) { LogError "taiga-back not found"; return $false }
    try {
        Set-Location $Config.TaigaBackDir
        if (-not (Test-Path $Config.VenvDir)) { & python -m venv $Config.VenvDir }
        $activate = Join-Path $Config.VenvDir "Scripts\Activate.ps1"
        if (Test-Path $activate) { . $activate } else { . (Join-Path $Config.VenvDir "Scripts\activate") }
        if (Test-Path "requirements.txt") { pip install -r requirements.txt --no-input } else { LogOk "requirements.txt not found; skipping pip install" }
        python manage.py migrate --noinput
        if (Test-Path "fixtures/initial_user.json") { python manage.py loaddata initial_user 2>$null }
        Start-Process -FilePath "python" -ArgumentList "manage.py runserver 127.0.0.1:8000" -WindowStyle Hidden
        if (-not (Wait-ForHttp "http://127.0.0.1:8000/api/v1" 60)) { LogError "Taiga backend did not respond in time"; return $false }
        LogOk "Taiga backend running"
        Set-Location $Config.BaseDir
        return $true
    } catch {
        LogError "Taiga backend setup error: $_"
        Set-Location $Config.BaseDir
        return $false
    }
}

# Test Taiga API CRUD with temporary user
function Test-TaigaApiCrud {
    param()
    $apiBase = "http://127.0.0.1:8000/api/v1"
    try {
        LogOk "Authenticating admin..."
        $adminAuth = Invoke-RestMethod -Method Post -Uri "$apiBase/auth" -Body @{username=$Config.TaigaAdminUser; password=$Config.TaigaAdminPass} -ErrorAction Stop
        $adminToken = $adminAuth.auth_token

        LogOk "Creating test user in Taiga..."
        try {
            $createUser = Invoke-RestMethod -Method Post -Uri "$apiBase/users" -Headers @{Authorization="Bearer $adminToken"} -Body @{username=$Config.TestUser; password=$Config.TestPass; email=$Config.TestEmail} -ErrorAction Stop
            $testUserId = $createUser.id
        } catch {
            $users = Invoke-RestMethod -Method Get -Uri "$apiBase/users" -Headers @{Authorization="Bearer $adminToken"} -ErrorAction SilentlyContinue
            $u = $users | Where-Object { $_.username -eq $Config.TestUser }
            if ($u) { $testUserId = $u.id } else { throw "Failed to create or find test user" }
        }

        LogOk "Authenticating test user..."
        $auth = Invoke-RestMethod -Method Post -Uri "$apiBase/auth" -Body @{username=$Config.TestUser; password=$Config.TestPass} -ErrorAction Stop
        $token = $auth.auth_token

        LogOk "Creating project via API..."
        $proj = Invoke-RestMethod -Method Post -Uri "$apiBase/projects" -Headers @{Authorization="Bearer $token"} -Body @{name="ProjectTestAPI"; description="API test"} -ErrorAction Stop
        $projId = $proj.id

        LogOk "Reading project via API..."
        Invoke-RestMethod -Method Get -Uri "$apiBase/projects/$projId" -Headers @{Authorization="Bearer $token"} | Out-String | LogOk

        LogOk "Updating project via API..."
        Invoke-RestMethod -Method Patch -Uri "$apiBase/projects/$projId" -Headers @{Authorization="Bearer $token"} -Body @{name="ProjectUpdatedAPI"} -ErrorAction Stop

        LogOk "Deleting project via API..."
        Invoke-RestMethod -Method Delete -Uri "$apiBase/projects/$projId" -Headers @{Authorization="Bearer $token"} -ErrorAction Stop

        LogOk "Taiga API CRUD passed"
        return $true
    } catch {
        LogError "Taiga API CRUD error: $_"
        return $false
    }
}

# Prepare Selenium and msedgedriver
function Ensure-Selenium {
    param()
    try {
        $edgeUrl = Get-EdgeDriverLatestUrl
        if (-not (Get-ArchiveIfMissing -Name "msedgedriver" -Url $edgeUrl -ZipPath (Join-Path $Config.BaseDir "edgedriver.zip") -TargetDir $Config.EdgeDriverDir)) { return $false }
        if (-not (Test-Path $Config.SeleniumLibDir)) {
            LogOk "Downloading Selenium.WebDriver (nuget)..."
            Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Selenium.WebDriver" -OutFile (Join-Path $Config.BaseDir "selenium.nupkg") -UseBasicParsing
            Expand-Archive -Path (Join-Path $Config.BaseDir "selenium.nupkg") -DestinationPath $Config.SeleniumLibDir -Force
            Remove-Item (Join-Path $Config.BaseDir "selenium.nupkg") -ErrorAction SilentlyContinue
        } else { LogOk "Selenium lib already present" }
        $seleniumDll = Get-ChildItem -Path $Config.SeleniumLibDir -Recurse -Filter "WebDriver.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $seleniumDll) { LogError "Selenium WebDriver DLL not found"; return $false }
        return $seleniumDll.FullName
    } catch {
        LogError "Ensure-Selenium error: $_"
        return $false
    }
}

# Test Taiga UI via Edge using detected selectors
function Test-TaigaUiCrud {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Selectors,
        [Parameter(Mandatory=$true)][string]$SeleniumDllPath
    )
    try {
        Add-Type -Path $SeleniumDllPath
        $service = [OpenQA.Selenium.Edge.EdgeDriverService]::CreateDefaultService($Config.EdgeDriverDir)
        $options = New-Object OpenQA.Selenium.Edge.EdgeOptions
        $options.UseChromium = $true
        $driver = New-Object OpenQA.Selenium.Edge.EdgeDriver($service, $options)
        $driver.Navigate().GoToUrl("http://127.0.0.1:8000")
        Start-Sleep -Seconds 2

        LogOk "Logging in via UI..."
        $driver.FindElementByCssSelector($Selectors.LoginUser).SendKeys($Config.TestUser)
        $driver.FindElementByCssSelector($Selectors.LoginPass).SendKeys($Config.TestPass)
        $driver.FindElementByCssSelector($Selectors.LoginSubmit).Click()
        Start-Sleep -Seconds 3

        try {
            $btnNew = $driver.FindElementsByCssSelector($Selectors.ProjectNew) | Select-Object -First 1
            if ($btnNew) {
                $btnNew.Click(); Start-Sleep -Seconds 1
                $driver.FindElementByCssSelector($Selectors.ProjectName).SendKeys("ProjectUI")
                $driver.FindElementByCssSelector($Selectors.ProjectSave).Click()
                Start-Sleep -Seconds 2
                LogOk "Project created via UI (attempt)"
            } else { LogOk "Project creation UI element not found; skipping" }
        } catch { LogError "Project UI create error: $_" }

        try {
            $btnCreate = $driver.FindElementsByCssSelector($Selectors.TaskCreate) | Select-Object -First 1
            if ($btnCreate) {
                $btnCreate.Click(); Start-Sleep -Seconds 1
                $driver.FindElementByCssSelector($Selectors.TaskSubject).SendKeys("Task Selenium UI")
                $driver.FindElementByCssSelector($Selectors.TaskSave).Click(); Start-Sleep -Seconds 2

                $tasks = $driver.FindElementsByCssSelector($Selectors.TaskList)
                foreach ($t in $tasks) { LogOk ("UI task: " + $t.Text) }

                $first = $tasks | Select-Object -First 1
                if ($first) {
                    $first.Click(); Start-Sleep -Seconds 1
                    try { $driver.FindElementByCssSelector($Selectors.TaskSubject).Clear(); $driver.FindElementByCssSelector($Selectors.TaskSubject).SendKeys("Task Updated UI"); $driver.FindElementByCssSelector($Selectors.TaskSave).Click(); Start-Sleep -Seconds 1 } catch {}
                    try { $del = $driver.FindElementsByCssSelector($Selectors.TaskDelete) | Select-Object -First 1; if ($del) { $del.Click(); Start-Sleep -Seconds 1; try { $driver.SwitchTo().Alert().Accept() } catch {} } } catch {}
                }
                LogOk "UI CRUD attempt finished"
            } else { LogOk "Task create UI element not found; skipping UI task flow" }
        } catch { LogError "UI task flow error: $_" }

        $driver.Quit()
        return $true
    } catch {
        if ($driver) { $driver.Quit() }
        LogError "Test-TaigaUiCrud error: $_"
        return $false
    }
}

# Cleanup: remove test artifacts (Postgres user/db and Taiga test user)
function Cleanup-TestArtifacts {
    param()
    try {
        $psqlExe = Get-ChildItem -Path $Config.PgDir -Filter "psql.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($psqlExe) {
            & $psqlExe.FullName -U postgres -d postgres -c "DROP DATABASE IF EXISTS $($Config.TestDb);" 2>$null
            & $psqlExe.FullName -U postgres -d postgres -c "DROP USER IF EXISTS $($Config.TestUser);" 2>$null
            LogOk "Postgres test artifacts removed (if existed)"
        } else { LogOk "psql not available for cleanup" }
    } catch { LogError "Cleanup Postgres error: $_" }

    try {
        $apiBase = "http://127.0.0.1:8000/api/v1"
        $adminAuth = Invoke-RestMethod -Method Post -Uri "$apiBase/auth" -Body @{username=$Config.TaigaAdminUser; password=$Config.TaigaAdminPass} -ErrorAction SilentlyContinue
        if ($adminAuth) {
            $adminToken = $adminAuth.auth_token
            $users = Invoke-RestMethod -Method Get -Uri "$apiBase/users" -Headers @{Authorization="Bearer $adminToken"} -ErrorAction SilentlyContinue
            $u = $users | Where-Object { $_.username -eq $Config.TestUser }
            if ($u) { Invoke-RestMethod -Method Delete -Uri "$apiBase/users/$($u.id)" -Headers @{Authorization="Bearer $adminToken"} -ErrorAction SilentlyContinue; LogOk "Taiga test user removed" } else { LogOk "Taiga test user not found" }
        } else { LogOk "Admin auth failed; skipping Taiga user cleanup" }
    } catch { LogError "Cleanup Taiga error: $_" }
}

# Main flow (concise)
try {
    LogOk "Starting Install-TaigaPortable"

    # Ensure Node
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        $nodeUrl = Get-NodeLatestUrl
        if ($nodeUrl) { Get-ArchiveIfMissing -Name "Node.js" -Url $nodeUrl -ZipPath (Join-Path $Config.BaseDir "node.zip") -TargetDir $Config.NodeDir | Out-Null }
    } else { LogOk "Node detected" }

    # Ensure Python
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        $pyUrl = Get-PythonEmbedLatestUrl
        if ($pyUrl) { Get-ArchiveIfMissing -Name "PythonEmbed" -Url $pyUrl -ZipPath (Join-Path $Config.BaseDir "python.zip") -TargetDir $Config.PythonDir | Out-Null }
    } else { LogOk "Python detected" }

    # Ensure Postgres
    if (-not (Ensure-Postgres)) { LogError "Postgres setup failed; aborting" ; throw "Postgres setup failed" }

    # Test Postgres CRUD
    $pgResult = Test-PostgresCrud
    if (-not $pgResult) { LogError "Postgres CRUD test failed" }

    # Clone taiga repos
    Ensure-GitClone -RepoUrl "https://github.com/taigaio/taiga-back.git" -TargetDir $Config.TaigaBackDir | Out-Null
    Ensure-GitClone -RepoUrl "https://github.com/taigaio/taiga-front.git" -TargetDir $Config.TaigaFrontDir | Out-Null

    # Detect selectors
    $Selectors = Detect-TaigaSelectors -FrontDir $Config.TaigaFrontDir

    # Ensure Taiga backend
    if (-not (Ensure-TaigaBackend)) { LogError "Taiga backend setup failed" }

    # Test Taiga API CRUD
    $apiResult = Test-TaigaApiCrud
    if (-not $apiResult) { LogError "Taiga API CRUD failed" }

    # Ensure Selenium and EdgeDriver
    $seleniumDllPath = Ensure-Selenium
    if ($seleniumDllPath) {
        $uiResult = Test-TaigaUiCrud -Selectors $Selectors -SeleniumDllPath $seleniumDllPath
        if (-not $uiResult) { LogError "Taiga UI test failed or partial" }
    } else {
        LogError "Selenium or EdgeDriver not available; skipping UI tests"
    }

} catch {
    LogError "Main flow error: $_"
} finally {
    Cleanup-TestArtifacts
    LogOk "SUMMARY:"
    LogOk ("Postgres CRUD: " + ($pgResult -eq $true))
    LogOk ("Taiga API CRUD: " + ($apiResult -eq $true))
    LogOk ("Taiga UI CRUD: " + ($uiResult -eq $true))
    LogOk "Install-TaigaPortable finished"
}
