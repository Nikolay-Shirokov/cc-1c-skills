# db-load-dt v1.3 — Load 1C information base from DT file
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Загрузка информационной базы 1С из DT-файла

.DESCRIPTION
    Загружает информационную базу целиком (конфигурация + данные) из DT-файла.
    ВНИМАНИЕ: операция полностью перезаписывает базу.

.PARAMETER V8Path
    Путь к каталогу bin платформы или к 1cv8.exe

.PARAMETER InfoBasePath
    Путь к файловой информационной базе

.PARAMETER InfoBaseServer
    Сервер 1С (для серверной базы)

.PARAMETER InfoBaseRef
    Имя базы на сервере

.PARAMETER UserName
    Имя пользователя 1С

.PARAMETER Password
    Пароль пользователя

.PARAMETER InputFile
    Путь к DT-файлу для загрузки

.PARAMETER JobsCount
    Количество фоновых заданий для загрузки (0 = по числу процессоров)

.PARAMETER UnlockCode
    Код разблокировки базы (/UC) — если заблокировано начало сеансов

.EXAMPLE
    .\db-load-dt.ps1 -InfoBasePath "C:\Bases\MyDB" -InputFile "backup.dt"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$V8Path,

    [Parameter(Mandatory=$false)]
    [string]$InfoBasePath,

    [Parameter(Mandatory=$false)]
    [string]$InfoBaseServer,

    [Parameter(Mandatory=$false)]
    [string]$InfoBaseRef,

    [Parameter(Mandatory=$false)]
    [string]$UserName,

    [Parameter(Mandatory=$false)]
    [string]$Password,

    [Parameter(Mandatory=$true)]
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [int]$JobsCount = 0,

    [Parameter(Mandatory=$false)]
    [string]$UnlockCode
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve V8Path ---
function Find-ProjectV8Path {
    $dir = (Get-Location).Path
    while ($dir) {
        $pf = Join-Path $dir ".v8-project.json"
        if (Test-Path $pf) {
            try {
                $j = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.v8path) { return [string]$j.v8path }
            } catch {}
            return $null
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

if (-not $V8Path) {
    $V8Path = Find-ProjectV8Path
}
if (-not $V8Path) {
    $found = Get-ChildItem @("C:\Program Files\1cv8\*\bin\1cv8.exe", "C:\Program Files (x86)\1cv8\*\bin\1cv8.exe") -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Directory.Parent.Name } catch { [version]"0.0" } } -Descending |
        Select-Object -First 1
    if ($found) {
        $V8Path = $found.FullName
        Write-Host "Auto-selected platform $($found.Directory.Parent.Name): $V8Path" -ForegroundColor Yellow
    } else {
        Write-Host "Error: 1cv8.exe not found. Specify -V8Path" -ForegroundColor Red
        exit 1
    }
}
if (Test-Path $V8Path -PathType Container) {
    $V8Path = Join-Path $V8Path "1cv8.exe"
}

if (-not (Test-Path $V8Path)) {
    Write-Host "Error: 1cv8.exe not found at $V8Path" -ForegroundColor Red
    exit 1
}

# --- Detect engine (ibcmd vs 1cv8) by exe name ---
$engine = if ((Split-Path $V8Path -Leaf) -match '^ibcmd') { "ibcmd" } else { "1cv8" }

# --- Validate connection ---
if ($engine -eq "ibcmd") {
    if (-not $InfoBasePath) {
        Write-Host "Error: ibcmd supports file infobases only (use -InfoBasePath)" -ForegroundColor Red
        exit 1
    }
} elseif (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    Write-Host "Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef" -ForegroundColor Red
    exit 1
}

# --- Validate input file ---
if (-not (Test-Path $InputFile)) {
    Write-Host "Error: input file not found: $InputFile" -ForegroundColor Red
    exit 1
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "db_load_dt_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    if ($engine -eq "ibcmd") {
        # --- ibcmd branch (file infobase only) ---
        $arguments = @("infobase", "restore", "--db-path=$InfoBasePath")
        if (-not (Test-Path (Join-Path $InfoBasePath "1Cv8.1CD"))) { $arguments += "--create-database" }
        if ($UserName) { $arguments += "--user=$UserName" }
        if ($Password) { $arguments += "--password=$Password" }
        $arguments += "$InputFile"

        $arguments += "--data=$tempDir"
        Write-Host "Running: ibcmd $($arguments -join ' ')"
        $output = & $V8Path @arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host "Information base restored successfully from: $InputFile" -ForegroundColor Green
        } else {
            Write-Host "Error restoring information base (code: $exitCode)" -ForegroundColor Red
        }
        if ($output) { Write-Host ($output | Out-String) }
        exit $exitCode
    }

    # --- 1cv8 branch ---
    # --- Build arguments ---
    $arguments = @("DESIGNER")

    if ($InfoBaseServer -and $InfoBaseRef) {
        $arguments += "/S", "`"$InfoBaseServer/$InfoBaseRef`""
    } else {
        $arguments += "/F", "`"$InfoBasePath`""
    }

    if ($UserName) { $arguments += "/N`"$UserName`"" }
    if ($Password) { $arguments += "/P`"$Password`"" }
    if ($UnlockCode) { $arguments += "/UC`"$UnlockCode`"" }

    $arguments += "/RestoreIB", "`"$InputFile`""
    if ($JobsCount -gt 0) { $arguments += "-JobsCount", "$JobsCount" }

    # --- Output ---
    $outFile = Join-Path $tempDir "load_dt_log.txt"
    $arguments += "/Out", "`"$outFile`""
    $arguments += "/DisableStartupDialogs"

    # --- Execute ---
    Write-Host "Running: 1cv8.exe $($arguments -join ' ')"
    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Result ---
    if ($exitCode -eq 0) {
        Write-Host "Information base restored successfully from: $InputFile" -ForegroundColor Green
    } else {
        Write-Host "Error restoring information base (code: $exitCode)" -ForegroundColor Red
    }

    if (Test-Path $outFile) {
        $logContent = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        if ($logContent) {
            Write-Host "--- Log ---"
            Write-Host $logContent
            Write-Host "--- End ---"
        }
    }

    exit $exitCode

} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
