# epf-dump v1.0 — Dump external data processor or report (EPF/ERF) to XML sources
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Разборка внешней обработки/отчёта 1С в XML-исходники

.DESCRIPTION
    Разбирает EPF/ERF-файл во XML-исходники с помощью платформы 1С.
    Общий скрипт для epf-dump и erf-dump.

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
    Путь к EPF/ERF-файлу

.PARAMETER OutputDir
    Каталог для выгрузки исходников

.PARAMETER Format
    Формат выгрузки: Hierarchical или Plain (по умолчанию Hierarchical)

.EXAMPLE
    .\epf-dump.ps1 -InfoBasePath "C:\Bases\MyDB" -InputFile "build\МояОбработка.epf" -OutputDir "src"

.EXAMPLE
    .\epf-dump.ps1 -InfoBasePath "C:\Bases\MyDB" -InputFile "build\МойОтчёт.erf" -OutputDir "src"
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

    [Parameter(Mandatory=$true)]
    [string]$OutputDir,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Hierarchical", "Plain")]
    [string]$Format = "Hierarchical"
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

# --- Validate database connection ---
if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    Write-Host "Error: database connection required. Specify -InfoBasePath or -InfoBaseServer/-InfoBaseRef" -ForegroundColor Red
    Write-Host "Dump in an empty database loses reference types (CatalogRef, DocumentRef, etc.) irreversibly." -ForegroundColor Yellow
    exit 1
}

# --- Validate input file ---
if (-not (Test-Path $InputFile)) {
    Write-Host "Error: input file not found: $InputFile" -ForegroundColor Red
    exit 1
}

# --- Ensure output directory exists ---
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "epf_dump_$(Get-Random)"
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

    $arguments += "/DumpExternalDataProcessorOrReportToFiles", "`"$OutputDir`"", "`"$InputFile`""
    $arguments += "-Format", $Format

    # --- Output ---
    $outFile = Join-Path $tempDir "dump_log.txt"
    $arguments += "/Out", "`"$outFile`""
    $arguments += "/DisableStartupDialogs"

    # --- Execute ---
    Write-Host "Running: 1cv8.exe $($arguments -join ' ')"
    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Result ---
    if ($exitCode -eq 0) {
        Write-Host "Dump completed successfully to: $OutputDir" -ForegroundColor Green
    } else {
        Write-Host "Error dumping (code: $exitCode)" -ForegroundColor Red
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
