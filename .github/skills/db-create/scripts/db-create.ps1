# db-create v1.0 — Create 1C information base
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Создание информационной базы 1С

.DESCRIPTION
    Создаёт новую информационную базу 1С (файловую или серверную).
    Поддерживает создание из шаблона и добавление в список баз.

.PARAMETER V8Path
    Путь к каталогу bin платформы или к 1cv8.exe

.PARAMETER InfoBasePath
    Путь к файловой информационной базе

.PARAMETER InfoBaseServer
    Сервер 1С (для серверной базы)

.PARAMETER InfoBaseRef
    Имя базы на сервере

.PARAMETER UseTemplate
    Путь к файлу шаблона (.cf или .dt)

.PARAMETER AddToList
    Добавить в список баз 1С

.PARAMETER ListName
    Имя базы в списке

.EXAMPLE
    .\db-create.ps1 -InfoBasePath "C:\Bases\NewDB"

.EXAMPLE
    .\db-create.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Test"

.EXAMPLE
    .\db-create.ps1 -InfoBasePath "C:\Bases\NewDB" -UseTemplate "C:\Templates\config.cf" -AddToList -ListName "Новая база"
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
    [string]$UseTemplate,

    [Parameter(Mandatory=$false)]
    [switch]$AddToList,

    [Parameter(Mandatory=$false)]
    [string]$ListName
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

# --- Validate template ---
if ($UseTemplate -and -not (Test-Path $UseTemplate)) {
    Write-Host "Error: template file not found: $UseTemplate" -ForegroundColor Red
    exit 1
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "db_create_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # --- Build arguments ---
    $arguments = @("CREATEINFOBASE")

    if ($InfoBaseServer -and $InfoBaseRef) {
        $arguments += "Srvr=`"$InfoBaseServer`";Ref=`"$InfoBaseRef`""
    } else {
        $arguments += "File=`"$InfoBasePath`""
    }

    # --- Template ---
    if ($UseTemplate) {
        $arguments += "/UseTemplate", "`"$UseTemplate`""
    }

    # --- Add to list ---
    if ($AddToList) {
        if ($ListName) {
            $arguments += "/AddToList", "`"$ListName`""
        } else {
            $arguments += "/AddToList"
        }
    }

    # --- Output ---
    $outFile = Join-Path $tempDir "create_log.txt"
    $arguments += "/Out", "`"$outFile`""
    $arguments += "/DisableStartupDialogs"

    # --- Execute ---
    Write-Host "Running: 1cv8.exe $($arguments -join ' ')"
    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Result ---
    if ($exitCode -eq 0) {
        if ($InfoBaseServer -and $InfoBaseRef) {
            Write-Host "Information base created successfully: $InfoBaseServer/$InfoBaseRef" -ForegroundColor Green
        } else {
            Write-Host "Information base created successfully: $InfoBasePath" -ForegroundColor Green
        }
    } else {
        Write-Host "Error creating information base (code: $exitCode)" -ForegroundColor Red
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
