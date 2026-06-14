# web-unpublish v1.0 — Remove 1C web publication
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Удаление веб-публикации 1С из Apache

.DESCRIPTION
    Удаляет маркерный блок из httpd.conf и каталог публикации.
    Если Apache запущен — перезапускает для применения.
    С флагом -All удаляет все публикации и останавливает Apache.

.PARAMETER AppName
    Имя публикации (обязательный, если не указан -All)

.PARAMETER ApachePath
    Корень Apache (по умолчанию tools\apache24)

.PARAMETER All
    Удалить все публикации

.EXAMPLE
    .\web-unpublish.ps1 -AppName "mydb"

.EXAMPLE
    .\web-unpublish.ps1 -All

.EXAMPLE
    .\web-unpublish.ps1 -AppName "bpdemo" -ApachePath "C:\tools\apache24"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$AppName,

    [Parameter(Mandatory=$false)]
    [string]$ApachePath,

    [Parameter(Mandatory=$false)]
    [switch]$All
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve ApachePath ---
if (-not $ApachePath) {
    $projectRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $ApachePath = Join-Path $projectRoot "tools\apache24"
}

# --- Validate params ---
if (-not $All -and -not $AppName) {
    Write-Host "Error: укажите -AppName или -All" -ForegroundColor Red
    exit 1
}

# --- Read httpd.conf ---
$confFile = Join-Path (Join-Path $ApachePath "conf") "httpd.conf"
if (-not (Test-Path $confFile)) {
    Write-Host "Error: httpd.conf не найден: $confFile" -ForegroundColor Red
    exit 1
}

$confContent = [System.IO.File]::ReadAllText($confFile)

# --- Helper: our httpd process ---
$httpdExe = Join-Path (Join-Path $ApachePath "bin") "httpd.exe"
$httpdExeNorm = (Resolve-Path $httpdExe -ErrorAction SilentlyContinue).Path
function Get-OurHttpd {
    Get-Process httpd -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $httpdExeNorm } catch { $false }
    }
}

# --- Collect app names to remove ---
if ($All) {
    $pubPattern = '# --- 1C Publication: (.+?) ---'
    $pubMatches = [regex]::Matches($confContent, $pubPattern)
    if ($pubMatches.Count -eq 0) {
        Write-Host "Нет публикаций для удаления" -ForegroundColor Yellow
        exit 0
    }
    $appNames = @()
    foreach ($m in $pubMatches) { $appNames += $m.Groups[1].Value }
    Write-Host "Удаление всех публикаций: $($appNames -join ', ')" -ForegroundColor Cyan
} else {
    $appNames = @($AppName)
}

# --- Remove marker blocks ---
foreach ($name in $appNames) {
    $pubMarkerStart = "# --- 1C Publication: $name ---"
    $pubMarkerEnd = "# --- End: $name ---"

    if ($confContent -match [regex]::Escape($pubMarkerStart)) {
        $pattern = '\r?\n?' + [regex]::Escape($pubMarkerStart) + '[\s\S]*?' + [regex]::Escape($pubMarkerEnd) + '\r?\n?'
        $confContent = [regex]::Replace($confContent, $pattern, "`n")
        Write-Host "httpd.conf: блок публикации '$name' удалён" -ForegroundColor Green
    } else {
        Write-Host "Публикация '$name' не найдена в httpd.conf" -ForegroundColor Yellow
    }
}

# --- Check if any publications remain; if not, remove global block ---
$remainingPubs = [regex]::Matches($confContent, '# --- 1C Publication: .+? ---')
if ($remainingPubs.Count -eq 0) {
    $globalMarkerStart = "# --- 1C: global ---"
    $globalMarkerEnd = "# --- End: global ---"
    if ($confContent -match [regex]::Escape($globalMarkerStart)) {
        $globalPattern = '\r?\n?' + [regex]::Escape($globalMarkerStart) + '[\s\S]*?' + [regex]::Escape($globalMarkerEnd) + '\r?\n?'
        $confContent = [regex]::Replace($confContent, $globalPattern, "`n")
        Write-Host "httpd.conf: глобальный блок 1C удалён (нет публикаций)" -ForegroundColor Green
    }
}

[System.IO.File]::WriteAllText($confFile, $confContent)

# --- Remove publish directories ---
foreach ($name in $appNames) {
    $publishDir = Join-Path (Join-Path $ApachePath "publish") $name
    if (Test-Path $publishDir) {
        Remove-Item $publishDir -Recurse -Force
        Write-Host "Каталог удалён: $publishDir" -ForegroundColor Green
    } else {
        Write-Host "Каталог не найден: $publishDir" -ForegroundColor Yellow
    }
}

# --- Restart/Stop Apache if running (only our instance) ---
$httpdProc = Get-OurHttpd
if ($httpdProc) {
    if ($remainingPubs.Count -gt 0) {
        Write-Host "Перезапуск Apache..."
        $httpdProc | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Process -FilePath $httpdExe -WorkingDirectory $ApachePath -WindowStyle Hidden
        Start-Sleep -Seconds 2
        $check = Get-OurHttpd
        if ($check) {
            Write-Host "Apache перезапущен" -ForegroundColor Green
        } else {
            Write-Host "Error: Apache не удалось перезапустить" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "Публикаций не осталось — останавливаю Apache..."
        $httpdProc | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Write-Host "Apache остановлен" -ForegroundColor Green
    }
}

Write-Host ""
if ($All) {
    Write-Host "Все публикации удалены ($($appNames.Count) шт.)" -ForegroundColor Green
} else {
    Write-Host "Публикация '$AppName' удалена" -ForegroundColor Green
}
