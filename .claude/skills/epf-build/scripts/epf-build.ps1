# epf-build v1.0 — Build external data processor or report (EPF/ERF) from XML sources
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Сборка внешней обработки/отчёта 1С из XML-исходников

.DESCRIPTION
    Собирает EPF/ERF-файл из XML-исходников с помощью платформы 1С.
    Общий скрипт для epf-build и erf-build.

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

.PARAMETER SourceFile
    Путь к корневому XML-файлу исходников

.PARAMETER OutputFile
    Путь к выходному EPF/ERF-файлу

.EXAMPLE
    .\epf-build.ps1 -InfoBasePath "C:\Bases\MyDB" -SourceFile "src\МояОбработка.xml" -OutputFile "build\МояОбработка.epf"

.EXAMPLE
    .\epf-build.ps1 -InfoBasePath "C:\Bases\MyDB" -SourceFile "src\МойОтчёт.xml" -OutputFile "build\МойОтчёт.erf"
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
    [string]$SourceFile,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve V8Path ---
if (-not $V8Path) {
    $found = Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) {
        $V8Path = $found.FullName
    } else {
        Write-Host "Error: 1cv8.exe not found. Specify -V8Path" -ForegroundColor Red
        exit 1
    }
} elseif (Test-Path $V8Path -PathType Container) {
    $V8Path = Join-Path $V8Path "1cv8.exe"
}

if (-not (Test-Path $V8Path)) {
    Write-Host "Error: 1cv8.exe not found at $V8Path" -ForegroundColor Red
    exit 1
}

# --- Auto-create stub database if no connection specified ---
$autoCreatedBase = $null
if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    $sourceDir = Split-Path $SourceFile -Parent
    $autoBasePath = Join-Path $env:TEMP "epf_stub_db_$(Get-Random)"
    $stubScript = Join-Path $PSScriptRoot "stub-db-create.ps1"
    Write-Host "No database specified. Creating temporary stub database..."
    $stubArgs = "-SourceDir `"$sourceDir`" -V8Path `"$V8Path`" -TempBasePath `"$autoBasePath`""
    $stubProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -File `"$stubScript`" $stubArgs" -NoNewWindow -Wait -PassThru
    if ($stubProc.ExitCode -ne 0) {
        Write-Host "Error: failed to create stub database" -ForegroundColor Red
        exit 1
    }
    $InfoBasePath = $autoBasePath
    $autoCreatedBase = $autoBasePath
}

# --- Validate source file ---
if (-not (Test-Path $SourceFile)) {
    Write-Host "Error: source file not found: $SourceFile" -ForegroundColor Red
    exit 1
}

# --- Ensure output directory exists ---
$outDir = Split-Path $OutputFile -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "epf_build_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # --- Build arguments ---
    $arguments = @("DESIGNER")

    if ($InfoBaseServer -and $InfoBaseRef) {
        $arguments += "/S", "`"$InfoBaseServer/$InfoBaseRef`""
    } else {
        $arguments += "/F", "`"$InfoBasePath`""
    }

    if ($UserName) { $arguments += "/N`"$UserName`"" }
    if ($Password) { $arguments += "/P`"$Password`"" }

    $arguments += "/LoadExternalDataProcessorOrReportFromFiles", "`"$SourceFile`"", "`"$OutputFile`""

    # --- Output ---
    $outFile = Join-Path $tempDir "build_log.txt"
    $arguments += "/Out", "`"$outFile`""
    $arguments += "/DisableStartupDialogs"

    # --- Execute ---
    Write-Host "Running: 1cv8.exe $($arguments -join ' ')"
    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Result ---
    if ($exitCode -eq 0) {
        Write-Host "Build completed successfully: $OutputFile" -ForegroundColor Green
    } else {
        Write-Host "Error building (code: $exitCode)" -ForegroundColor Red
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
    if ($autoCreatedBase -and (Test-Path $autoCreatedBase)) {
        Remove-Item -Path $autoCreatedBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}
