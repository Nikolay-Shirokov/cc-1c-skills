# db-load-xml v1.3 — Load 1C configuration from XML files
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Загрузка конфигурации 1С из XML-файлов

.DESCRIPTION
    Загружает конфигурацию в информационную базу из XML-файлов.
    Поддерживает полную и частичную загрузку.

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

.PARAMETER ConfigDir
    Каталог XML-исходников конфигурации

.PARAMETER Mode
    Режим загрузки: Full или Partial (по умолчанию Full)

.PARAMETER Files
    Относительные пути файлов через запятую (для режима Partial)

.PARAMETER ListFile
    Путь к файлу со списком файлов (альтернатива -Files, для режима Partial)

.PARAMETER Extension
    Имя расширения для загрузки

.PARAMETER AllExtensions
    Загрузить все расширения

.PARAMETER Format
    Формат файлов: Hierarchical или Plain (по умолчанию Hierarchical)

.EXAMPLE
    .\db-load-xml.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Mode Full

.EXAMPLE
    .\db-load-xml.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Mode Partial -Files "Catalogs/Номенклатура.xml,Catalogs/Номенклатура/Ext/ObjectModule.bsl"
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
    [string]$ConfigDir,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Full", "Partial")]
    [string]$Mode = "Full",

    [Parameter(Mandatory=$false)]
    [string]$Files,

    [Parameter(Mandatory=$false)]
    [string]$ListFile,

    [Parameter(Mandatory=$false)]
    [string]$Extension,

    [Parameter(Mandatory=$false)]
    [switch]$AllExtensions,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Hierarchical", "Plain")]
    [string]$Format = "Hierarchical",

    [Parameter(Mandatory=$false)]
    [switch]$UpdateDB,

    [Parameter(Mandatory=$false)]
    [switch]$StrictLog
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

# --- Validate connection ---
if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    Write-Host "Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef" -ForegroundColor Red
    exit 1
}

# --- Validate config dir ---
if (-not (Test-Path $ConfigDir)) {
    Write-Host "Error: config directory not found: $ConfigDir" -ForegroundColor Red
    exit 1
}

# --- Validate Partial mode ---
if ($Mode -eq "Partial" -and -not $Files -and -not $ListFile) {
    Write-Host "Error: -Files or -ListFile required for Partial mode" -ForegroundColor Red
    exit 1
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "db_load_xml_$(Get-Random)"
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

    $arguments += "/LoadConfigFromFiles", "`"$ConfigDir`""

    if ($Mode -eq "Full") {
        Write-Host "Executing full configuration load..."
    } else {
        Write-Host "Executing partial configuration load..."

        # Build list file
        $generatedListFile = $null
        if ($ListFile) {
            # Use provided list file
            if (-not (Test-Path $ListFile)) {
                Write-Host "Error: list file not found: $ListFile" -ForegroundColor Red
                exit 1
            }
            $generatedListFile = $ListFile
        } else {
            # Generate from -Files parameter
            $fileList = $Files -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $generatedListFile = Join-Path $tempDir "load_list.txt"
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllLines($generatedListFile, $fileList, $utf8Bom)

            Write-Host "Files to load: $($fileList.Count)"
            foreach ($f in $fileList) { Write-Host "  $f" }
        }

        $arguments += "-listFile", "`"$generatedListFile`""
        $arguments += "-partial"
        $arguments += "-updateConfigDumpInfo"
    }

    $arguments += "-Format", $Format

    # --- Extensions ---
    if ($Extension) {
        $arguments += "-Extension", "`"$Extension`""
    } elseif ($AllExtensions) {
        $arguments += "-AllExtensions"
    }

    # --- UpdateDB ---
    if ($UpdateDB) {
        $arguments += "/UpdateDBCfg"
    }

    # --- Output ---
    $outFile = Join-Path $tempDir "load_log.txt"
    $arguments += "/Out", "`"$outFile`""
    $arguments += "/DisableStartupDialogs"

    # --- Execute ---
    Write-Host "Running: 1cv8.exe $($arguments -join ' ')"
    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Read log ---
    $logContent = $null
    if (Test-Path $outFile) {
        $logContent = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    }

    # --- Scan log for silent rejections ---
    # Platform often writes load-time rejections into /Out but exits with code 0.
    # These patterns flag cases where metadata was dropped or rejected silently.
    $fatalLogPatterns = @(
        'Неверное свойство объекта метаданных',
        'не входит в состав объекта метаданных',
        'Неизвестное имя типа',
        'Неизвестный объект метаданных',
        'Ни один из документов не является регистратором для регистра',
        'Неверное значение перечисления',
        'не может быть приведен к типу'
    )
    $silentFailures = @()
    if ($logContent) {
        foreach ($line in ($logContent -split "`r?`n")) {
            foreach ($pat in $fatalLogPatterns) {
                if ($line -match [regex]::Escape($pat)) {
                    $silentFailures += $line.Trim()
                    break
                }
            }
        }
    }

    # --- Result ---
    # Default: mirror platform's verdict via exit code. Log content (including any
    # rejection warnings) is always printed to stdout for visibility. With -StrictLog,
    # elevate exit code to 1 when rejection patterns are found even if platform said 0.
    if ($exitCode -eq 0) {
        Write-Host "Load completed successfully" -ForegroundColor Green
    } else {
        Write-Host "Error loading configuration (code: $exitCode)" -ForegroundColor Red
    }

    if ($logContent) {
        Write-Host "--- Log ---"
        Write-Host $logContent
        Write-Host "--- End ---"
    }

    if ($silentFailures.Count -gt 0) {
        $msg = "[warning] log contains $($silentFailures.Count) rejection(s) — platform loaded config but dropped properties/refs"
        if (-not $StrictLog) { $msg += " (pass -StrictLog to treat as error)" }
        Write-Host $msg -ForegroundColor Yellow
        foreach ($f in $silentFailures) { Write-Host "  $f" -ForegroundColor Yellow }
        if ($StrictLog -and $exitCode -eq 0) { $exitCode = 1 }
    }

    exit $exitCode

} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
