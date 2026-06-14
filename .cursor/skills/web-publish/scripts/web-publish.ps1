# web-publish v1.2 — Publish 1C infobase via Apache
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Публикация информационной базы 1С через Apache HTTP Server

.DESCRIPTION
    Генерирует default.vrd и настраивает httpd.conf для веб-доступа
    к информационной базе 1С. При необходимости скачивает portable Apache.
    Идемпотентный — повторный вызов обновляет конфигурацию.

.PARAMETER V8Path
    Путь к каталогу bin платформы (для wsap24.dll)

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

.PARAMETER AppName
    Имя публикации (по умолчанию из имени каталога базы)

.PARAMETER ApachePath
    Корень Apache (по умолчанию tools\apache24)

.PARAMETER Port
    Порт (по умолчанию 8081)

.PARAMETER Manual
    Не скачивать Apache — только проверить и дать инструкцию

.EXAMPLE
    .\web-publish.ps1 -InfoBasePath "C:\Bases\MyDB"

.EXAMPLE
    .\web-publish.ps1 -InfoBasePath "C:\Bases\MyDB" -AppName "mydb" -Port 9090

.EXAMPLE
    .\web-publish.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -Manual
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

    [Parameter(Mandatory=$false)]
    [string]$AppName,

    [Parameter(Mandatory=$false)]
    [string]$ApachePath,

    [Parameter(Mandatory=$false)]
    [int]$Port = 8081,

    [Parameter(Mandatory=$false)]
    [switch]$Manual
)

# --- Encoding ---
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve V8Path ---
if (-not $V8Path) {
    $found = Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) {
        $V8Path = Split-Path $found.FullName -Parent
    } else {
        Write-Host "Error: платформа 1С не найдена. Укажите -V8Path" -ForegroundColor Red
        exit 1
    }
} elseif (Test-Path $V8Path -PathType Leaf) {
    $V8Path = Split-Path $V8Path -Parent
}

# Validate wsap24.dll
$wsapDll = Join-Path $V8Path "wsap24.dll"
if (-not (Test-Path $wsapDll)) {
    Write-Host "Error: wsap24.dll не найден в $V8Path" -ForegroundColor Red
    exit 1
}

# --- Validate connection ---
if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    Write-Host "Error: укажите -InfoBasePath или -InfoBaseServer + -InfoBaseRef" -ForegroundColor Red
    exit 1
}

# --- Resolve ApachePath ---
if (-not $ApachePath) {
    $projectRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $ApachePath = Join-Path $projectRoot "tools\apache24"
}
# Ensure absolute path (agent may pass relative like "tools/apache24")
if (-not [System.IO.Path]::IsPathRooted($ApachePath)) {
    $ApachePath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ApachePath))
}

# --- Check / Install Apache ---
$httpdExe = Join-Path (Join-Path $ApachePath "bin") "httpd.exe"

if (-not (Test-Path $httpdExe)) {
    if ($Manual) {
        Write-Host "Apache не найден: $ApachePath" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Установите Apache вручную:" -ForegroundColor Cyan
        Write-Host "  1. Скачайте Apache Lounge (x64) с https://www.apachelounge.com/download/"
        Write-Host "  2. Распакуйте содержимое Apache24\ в: $ApachePath"
        Write-Host "  3. Запустите скрипт повторно"
        exit 1
    }

    Write-Host "Apache не найден. Скачиваю..." -ForegroundColor Cyan
    $tmpZip = Join-Path $env:TEMP "apache24.zip"
    $tmpDir = Join-Path $env:TEMP "apache24_extract"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient

        # Parse Apache Lounge download page for latest Win64 zip URL
        $downloadPage = "https://www.apachelounge.com/download/"
        Write-Host "Определяю актуальную версию с $downloadPage ..."
        $html = $wc.DownloadString($downloadPage)
        # Links are typically relative (/download/...), try that first
        $match = [regex]::Match($html, '(?i)href="(/download/[^"]*?httpd-[^"]*?Win64[^"]*?\.zip)"')
        if (-not $match.Success) {
            $match = [regex]::Match($html, '(?i)href="(https://[^"]*?httpd-[^"]*?Win64[^"]*?\.zip)"')
        }

        if ($match.Success) {
            $zipUrl = $match.Groups[1].Value
            if ($zipUrl.StartsWith('/')) {
                $zipUrl = "https://www.apachelounge.com$zipUrl"
            }
            Write-Host "Найдено: $zipUrl" -ForegroundColor Green
        } else {
            Write-Host "Не удалось определить ссылку автоматически." -ForegroundColor Yellow
            Write-Host "Скачайте вручную: $downloadPage" -ForegroundColor Yellow
            exit 1
        }

        $wc.DownloadFile($zipUrl, $tmpZip)
    } catch {
        Write-Host "Error: не удалось скачать Apache: $_" -ForegroundColor Red
        Write-Host "Скачайте вручную: https://www.apachelounge.com/download/" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Распаковка..."
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

    # Move Apache24 contents up to ApachePath
    $innerDir = Join-Path $tmpDir "Apache24"
    if (-not (Test-Path $innerDir)) {
        # Try to find Apache24 in nested folder
        $innerDir = Get-ChildItem $tmpDir -Directory -Recurse -Filter "Apache24" | Select-Object -First 1
        if ($innerDir) { $innerDir = $innerDir.FullName } else {
            Write-Host "Error: каталог Apache24 не найден в архиве" -ForegroundColor Red
            exit 1
        }
    }

    if (-not (Test-Path $ApachePath)) {
        New-Item -ItemType Directory -Path $ApachePath -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $innerDir "*") -Destination $ApachePath -Recurse -Force

    # Cleanup
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    # Patch ServerRoot in httpd.conf
    $confFile = Join-Path (Join-Path $ApachePath "conf") "httpd.conf"
    if (Test-Path $confFile) {
        $apachePathFwd = $ApachePath -replace '\\','/'
        $confContent = [System.IO.File]::ReadAllText($confFile)
        $confContent = $confContent -replace '(?m)^Define SRVROOT .*$', "Define SRVROOT `"$apachePathFwd`""
        [System.IO.File]::WriteAllText($confFile, $confContent)
        Write-Host "ServerRoot обновлён: $apachePathFwd" -ForegroundColor Green
    }

    Write-Host "Apache установлен: $ApachePath" -ForegroundColor Green
}

# --- Derive AppName ---
if (-not $AppName) {
    if ($InfoBasePath) {
        $AppName = (Split-Path $InfoBasePath -Leaf) -replace '[^\w]',''
    } else {
        $AppName = $InfoBaseRef -replace '[^\w]',''
    }
    $AppName = $AppName.ToLower()
}
$AppName = $AppName.ToLower()

if (-not $AppName) {
    Write-Host "Error: не удалось определить имя публикации. Укажите -AppName" -ForegroundColor Red
    exit 1
}

Write-Host "Публикация: $AppName" -ForegroundColor Cyan

# --- Create publish directory ---
$publishDir = Join-Path (Join-Path $ApachePath "publish") $AppName
if (-not (Test-Path $publishDir)) {
    New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
}

# --- Generate default.vrd ---
$vrdPath = Join-Path $publishDir "default.vrd"

$ibParts = @()
if ($InfoBaseServer -and $InfoBaseRef) {
    $ibParts += "Srvr=&quot;$InfoBaseServer&quot;"
    $ibParts += "Ref=&quot;$InfoBaseRef&quot;"
} else {
    $ibParts += "File=&quot;$InfoBasePath&quot;"
}
if ($UserName) { $ibParts += "Usr=&quot;$UserName&quot;" }
if ($Password) { $ibParts += "Pwd=&quot;$Password&quot;" }
$ibString = ($ibParts -join ";") + ";"

$vrdContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system"
       xmlns:xs="http://www.w3.org/2001/XMLSchema"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       base="/$AppName"
       ib="$ibString"
       enableStandardOdata="true">
    <ws pointEnableCommon="true"/>
    <httpServices publishByDefault="true"/>
</point>
"@

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($vrdPath, $vrdContent, $utf8Bom)
Write-Host "default.vrd: $vrdPath" -ForegroundColor Green

# --- Update httpd.conf ---
$confFile = Join-Path (Join-Path $ApachePath "conf") "httpd.conf"
if (-not (Test-Path $confFile)) {
    Write-Host "Error: httpd.conf не найден: $confFile" -ForegroundColor Red
    exit 1
}

$confContent = [System.IO.File]::ReadAllText($confFile)
$apachePathFwd = $ApachePath -replace '\\','/'
$wsapDllFwd = $wsapDll -replace '\\','/'
$publishDirFwd = $publishDir -replace '\\','/'
$vrdPathFwd = $vrdPath -replace '\\','/'

# --- Global block (Listen + LoadModule) ---
$globalMarkerStart = "# --- 1C: global ---"
$globalMarkerEnd = "# --- End: global ---"
$globalBlock = @"
$globalMarkerStart
Listen $Port
LoadModule _1cws_module "$wsapDllFwd"
$globalMarkerEnd
"@

if ($confContent -match [regex]::Escape($globalMarkerStart)) {
    # Replace existing global block
    $pattern = [regex]::Escape($globalMarkerStart) + '[\s\S]*?' + [regex]::Escape($globalMarkerEnd)
    $confContent = [regex]::Replace($confContent, $pattern, $globalBlock)
} else {
    # Comment out default Listen to avoid port conflict
    $confContent = $confContent -replace '(?m)^(Listen\s+\d+)', '#$1  # commented by web-publish'
    # Append global block
    $confContent = $confContent.TrimEnd() + "`n`n" + $globalBlock + "`n"
}

# --- Publication block ---
$pubMarkerStart = "# --- 1C Publication: $AppName ---"
$pubMarkerEnd = "# --- End: $AppName ---"
$pubBlock = @"
$pubMarkerStart
Alias "/$AppName" "$publishDirFwd"
<Directory "$publishDirFwd">
    AllowOverride All
    Require all granted
    SetHandler 1c-application
    ManagedApplicationDescriptor "$vrdPathFwd"
</Directory>
$pubMarkerEnd
"@

if ($confContent -match [regex]::Escape($pubMarkerStart)) {
    # Replace existing publication block
    $pattern = [regex]::Escape($pubMarkerStart) + '[\s\S]*?' + [regex]::Escape($pubMarkerEnd)
    $confContent = [regex]::Replace($confContent, $pattern, $pubBlock)
} else {
    # Append publication block
    $confContent = $confContent.TrimEnd() + "`n`n" + $pubBlock + "`n"
}

[System.IO.File]::WriteAllText($confFile, $confContent)
Write-Host "httpd.conf обновлён" -ForegroundColor Green

# --- Helper: filter httpd processes by our ApachePath ---
function Get-OurHttpd {
    $httpdExeNorm = (Resolve-Path $httpdExe -ErrorAction SilentlyContinue).Path
    Get-Process httpd -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $httpdExeNorm } catch { $false }
    }
}

# --- Check port availability ---
$portCheck = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
if ($portCheck) {
    $ourProc = Get-OurHttpd
    if ($ourProc) {
        # Our Apache holds the port — will restart
    } else {
        $holder = Get-Process -Id $portCheck.OwningProcess -ErrorAction SilentlyContinue
        $holderName = if ($holder) { "$($holder.ProcessName) (PID: $($holder.Id))" } else { "PID $($portCheck.OwningProcess)" }
        Write-Host "Error: порт $Port занят процессом $holderName" -ForegroundColor Red
        Write-Host "Укажите другой порт: -Port 9090" -ForegroundColor Yellow
        exit 1
    }
}

# --- Start Apache if not running ---
$httpdProc = Get-OurHttpd
if ($httpdProc) {
    Write-Host "Apache уже запущен (PID: $(($httpdProc | Select-Object -First 1).Id))" -ForegroundColor Yellow
    Write-Host "Перезапуск для применения конфигурации..."
    $httpdProc | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
} else {
    # Check if a foreign httpd holds the port
    $foreignHttpd = Get-Process httpd -ErrorAction SilentlyContinue
    if ($foreignHttpd) {
        Write-Host "[WARN] Обнаружен сторонний Apache (PID: $(($foreignHttpd | Select-Object -First 1).Id))" -ForegroundColor Yellow
        Write-Host "       Наш Apache: $httpdExe" -ForegroundColor Yellow
    }
}

Write-Host "Запуск Apache..."
Start-Process -FilePath $httpdExe -WorkingDirectory $ApachePath -WindowStyle Hidden

Start-Sleep -Seconds 2

$httpdCheck = Get-OurHttpd
if ($httpdCheck) {
    Write-Host "Apache запущен (PID: $(($httpdCheck | Select-Object -First 1).Id))" -ForegroundColor Green
} else {
    Write-Host "Apache не удалось запустить" -ForegroundColor Red
    # Run config test for diagnostics
    $testResult = & $httpdExe -t 2>&1
    if ($testResult) {
        Write-Host "--- httpd -t ---" -ForegroundColor Yellow
        $testResult | ForEach-Object { Write-Host "  $_" }
    }
    $errorLog = Join-Path (Join-Path $ApachePath "logs") "error.log"
    if (Test-Path $errorLog) {
        Write-Host "--- error.log (последние 10 строк) ---" -ForegroundColor Yellow
        Get-Content $errorLog -Tail 10
    }
    exit 1
}

# --- Result ---
Write-Host ""
Write-Host "=== Публикация готова ===" -ForegroundColor Green
Write-Host "URL:          http://localhost:$Port/$AppName" -ForegroundColor Cyan
Write-Host "OData:        http://localhost:$Port/$AppName/odata/standard.odata" -ForegroundColor Cyan
Write-Host "HTTP-сервисы: http://localhost:$Port/$AppName/hs/<RootUrl>/..." -ForegroundColor Cyan
Write-Host "Web-сервисы:  http://localhost:$Port/$AppName/ws/<Имя>?wsdl" -ForegroundColor Cyan
