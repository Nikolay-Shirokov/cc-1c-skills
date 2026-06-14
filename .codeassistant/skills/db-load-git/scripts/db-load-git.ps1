# db-load-git v1.3 — Load Git changes into 1C database
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Загрузка изменений из Git в базу 1С

.DESCRIPTION
    Определяет изменённые файлы конфигурации по данным Git и выполняет
    частичную загрузку в информационную базу.

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
    Каталог XML-выгрузки конфигурации (git-репозиторий)

.PARAMETER Source
    Источник изменений: All, Staged, Unstaged, Commit (по умолчанию All)

.PARAMETER CommitRange
    Диапазон коммитов (для Source=Commit), напр. HEAD~3..HEAD

.PARAMETER Extension
    Имя расширения для загрузки

.PARAMETER AllExtensions
    Загрузить все расширения

.PARAMETER Format
    Формат файлов: Hierarchical или Plain (по умолчанию Hierarchical)

.PARAMETER DryRun
    Только показать что будет загружено (без загрузки)

.EXAMPLE
    .\db-load-git.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Source All

.EXAMPLE
    .\db-load-git.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Source Commit -CommitRange "HEAD~3..HEAD"

.EXAMPLE
    .\db-load-git.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -DryRun
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
    [ValidateSet("All", "Staged", "Unstaged", "Commit")]
    [string]$Source = "All",

    [Parameter(Mandatory=$false)]
    [string]$CommitRange,

    [Parameter(Mandatory=$false)]
    [string]$Extension,

    [Parameter(Mandatory=$false)]
    [switch]$AllExtensions,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Hierarchical", "Plain")]
    [string]$Format = "Hierarchical",

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [switch]$UpdateDB
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Helper: map sub-file path (BSL, HTML, etc.) to object XML ---
function Get-ObjectXmlFromSubFile {
    param([string]$RelativePath)

    $parts = $RelativePath -split '[\\/]'
    if ($parts.Count -ge 2) {
        return "$($parts[0])/$($parts[1]).xml"
    }
    return $null
}

# --- Resolve V8Path (skip if DryRun) ---
if (-not $DryRun) {
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
}

# --- Validate connection (skip if DryRun) ---
if (-not $DryRun) {
    if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
        Write-Host "Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef" -ForegroundColor Red
        exit 1
    }
}

# --- Validate config dir ---
if (-not (Test-Path $ConfigDir)) {
    Write-Host "Error: config directory not found: $ConfigDir" -ForegroundColor Red
    exit 1
}

# --- Validate Commit mode ---
if ($Source -eq "Commit" -and -not $CommitRange) {
    Write-Host "Error: -CommitRange required for Source=Commit" -ForegroundColor Red
    exit 1
}

# --- Check git ---
try {
    $null = git --version 2>&1
} catch {
    Write-Host "Error: git not found in PATH" -ForegroundColor Red
    exit 1
}

# --- Get changed files from Git ---
$changedFiles = @()
$ConfigDir = (Resolve-Path $ConfigDir).Path.TrimEnd('\')
$configDirNormalized = $ConfigDir.Replace('\', '/')

Push-Location $ConfigDir
try {
    switch ($Source) {
        "Staged" {
            Write-Host "Getting staged changes..."
            $raw = git diff --cached --name-only --relative 2>&1
            if ($LASTEXITCODE -eq 0) { $changedFiles += $raw }
        }
        "Unstaged" {
            Write-Host "Getting unstaged changes..."
            $raw = git diff --name-only --relative 2>&1
            if ($LASTEXITCODE -eq 0) { $changedFiles += $raw }
            $raw = git ls-files --others --exclude-standard 2>&1
            if ($LASTEXITCODE -eq 0) { $changedFiles += $raw }
        }
        "Commit" {
            Write-Host "Getting changes from $CommitRange..."
            $raw = git diff --name-only --relative $CommitRange 2>&1
            if ($LASTEXITCODE -eq 0) { $changedFiles += $raw }
        }
        "All" {
            Write-Host "Getting all uncommitted changes..."
            $raw = git diff --cached --name-only --relative 2>&1
            if ($LASTEXITCODE -eq 0) { $changedFiles += $raw }
            $raw = git diff --name-only --relative 2>&1
            if ($LASTEXITCODE -eq 0) { $changedFiles += $raw }
            $raw = git ls-files --others --exclude-standard 2>&1
            if ($LASTEXITCODE -eq 0) { $changedFiles += $raw }
        }
    }
} finally {
    Pop-Location
}

$changedFiles = $changedFiles | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

if ($changedFiles.Count -eq 0) {
    Write-Host "No changes found"
    exit 0
}

Write-Host "Git changes detected: $($changedFiles.Count) files"

# --- Filter and map to config files ---
$configFiles = @()

foreach ($file in $changedFiles) {
    $file = $file.Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($file)) { continue }

    # Skip service files
    if ($file -eq "ConfigDumpInfo.xml") { continue }

    $fullPath = Join-Path $ConfigDir $file

    if ($file -match '\.xml$') {
        # XML file — add directly if exists
        if (Test-Path $fullPath) {
            if ($configFiles -notcontains $file) {
                $configFiles += $file
            }
        }
    }
    else {
        # Non-XML (BSL, HTML, etc.) — map to parent object XML + include all Ext/ files
        $objectXml = Get-ObjectXmlFromSubFile -RelativePath $file
        if ($objectXml) {
            $fullXmlPath = Join-Path $ConfigDir $objectXml
            if (Test-Path $fullXmlPath) {
                if ($configFiles -notcontains $objectXml) {
                    $configFiles += $objectXml
                }
                if ((Test-Path $fullPath) -and $configFiles -notcontains $file) {
                    $configFiles += $file
                }

                # Add all files from Ext/ directory of the object
                $parts = $file -split '[\\/]'
                if ($parts.Count -ge 2) {
                    $extDir = Join-Path (Join-Path $ConfigDir $parts[0]) "$($parts[1])\Ext"
                    if (Test-Path $extDir) {
                        Get-ChildItem -Path $extDir -Recurse -File | ForEach-Object {
                            $extRelPath = $_.FullName.Replace("$ConfigDir\", '').Replace('\', '/')
                            if ($configFiles -notcontains $extRelPath) {
                                $configFiles += $extRelPath
                            }
                        }
                    }
                }
            }
        }
    }
}

if ($configFiles.Count -eq 0) {
    Write-Host "No configuration files found in changes"
    exit 0
}

Write-Host "Files for loading: $($configFiles.Count)"
foreach ($f in $configFiles) { Write-Host "  $f" }

# --- DryRun: stop here ---
if ($DryRun) {
    Write-Host ""
    Write-Host "DryRun mode - no changes applied"
    exit 0
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "db_load_git_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # --- Write list file (UTF-8 with BOM) ---
    $listFile = Join-Path $tempDir "load_list.txt"
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($listFile, $configFiles, $utf8Bom)

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
    $arguments += "-listFile", "`"$listFile`""
    $arguments += "-Format", $Format
    $arguments += "-partial"
    $arguments += "-updateConfigDumpInfo"

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
    Write-Host ""
    Write-Host "Executing partial configuration load..."
    Write-Host "Running: 1cv8.exe $($arguments -join ' ')"

    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Result ---
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "Load completed successfully" -ForegroundColor Green
    } else {
        Write-Host "Error loading configuration (code: $exitCode)" -ForegroundColor Red
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
