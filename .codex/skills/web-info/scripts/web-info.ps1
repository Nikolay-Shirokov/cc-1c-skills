# web-info v1.0 — Apache & 1C publication status
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Статус Apache и публикаций 1С

.DESCRIPTION
    Показывает состояние Apache HTTP Server, список опубликованных баз
    и последние ошибки из error.log.

.PARAMETER ApachePath
    Корень Apache (по умолчанию tools\apache24)

.EXAMPLE
    .\web-info.ps1

.EXAMPLE
    .\web-info.ps1 -ApachePath "C:\tools\apache24"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ApachePath
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve ApachePath ---
if (-not $ApachePath) {
    $projectRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $ApachePath = Join-Path $projectRoot "tools\apache24"
}

# --- Check Apache installation ---
$httpdExe = Join-Path (Join-Path $ApachePath "bin") "httpd.exe"

Write-Host "=== Apache Web Server ===" -ForegroundColor Cyan

if (-not (Test-Path $httpdExe)) {
    Write-Host "Status: Не установлен" -ForegroundColor Red
    Write-Host "Path:   $ApachePath (не найден)"
    Write-Host ""
    Write-Host "Используйте /web-publish для установки Apache." -ForegroundColor Yellow
    exit 0
}

# --- Check process (only our Apache) ---
$httpdExeNorm = (Resolve-Path $httpdExe -ErrorAction SilentlyContinue).Path
$ourProc = Get-Process httpd -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $httpdExeNorm } catch { $false }
}
$foreignProc = Get-Process httpd -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -ne $httpdExeNorm } catch { $true }
}
if ($ourProc) {
    $pids = ($ourProc | ForEach-Object { $_.Id }) -join ", "
    Write-Host "Status: Запущен (PID: $pids)" -ForegroundColor Green
} else {
    Write-Host "Status: Остановлен" -ForegroundColor Yellow
}
if ($foreignProc) {
    $fpid = ($foreignProc | Select-Object -First 1).Id
    $fpath = try { ($foreignProc | Select-Object -First 1).Path } catch { "?" }
    Write-Host "[WARN] Обнаружен сторонний Apache (PID: $fpid, $fpath)" -ForegroundColor Yellow
}

Write-Host "Path:   $ApachePath"

# --- Parse httpd.conf ---
$confFile = Join-Path (Join-Path $ApachePath "conf") "httpd.conf"
if (-not (Test-Path $confFile)) {
    Write-Host "Config: httpd.conf не найден" -ForegroundColor Red
    exit 0
}

$confContent = [System.IO.File]::ReadAllText($confFile)

# Extract port from global block
$port = "—"
if ($confContent -match '(?m)^Listen\s+(\d+)') {
    $port = $Matches[1]
}
Write-Host "Port:   $port"

# Extract wsap24 path
if ($confContent -match 'LoadModule\s+_1cws_module\s+"([^"]+)"') {
    Write-Host "Module: $($Matches[1])"
}

# --- Publications ---
Write-Host ""
Write-Host "=== Опубликованные базы ===" -ForegroundColor Cyan

$pubPattern = '# --- 1C Publication: (.+?) ---'
$pubMatches = [regex]::Matches($confContent, $pubPattern)

if ($pubMatches.Count -eq 0) {
    Write-Host "(нет публикаций)" -ForegroundColor Yellow
} else {
    foreach ($match in $pubMatches) {
        $appName = $match.Groups[1].Value

        # Read default.vrd for this publication
        $vrdPath = Join-Path (Join-Path (Join-Path $ApachePath "publish") $appName) "default.vrd"
        $ibInfo = "—"
        if (Test-Path $vrdPath) {
            $vrdContent = [System.IO.File]::ReadAllText($vrdPath)
            if ($vrdContent -match 'ib="([^"]*)"') {
                $ibInfo = $Matches[1] -replace '&quot;','"'
            }
        }

        # Detect published services
        $svcTags = @()
        if (Test-Path $vrdPath) {
            if ($vrdContent -match '<ws\s') { $svcTags += "WS" }
            if ($vrdContent -match '<httpServices\s') { $svcTags += "HTTP" }
            if ($vrdContent -match 'enableStandardOdata\s*=\s*"true"') { $svcTags += "OData" }
        }
        $svcLabel = if ($svcTags.Count -gt 0) { "   [" + ($svcTags -join " ") + "]" } else { "" }

        $url = "http://localhost:$port/$appName"
        Write-Host "  $appName" -ForegroundColor White -NoNewline
        Write-Host "   $url" -ForegroundColor Gray -NoNewline
        Write-Host "   $ibInfo" -ForegroundColor DarkGray -NoNewline
        Write-Host $svcLabel -ForegroundColor DarkCyan
    }
}

# --- Error log ---
Write-Host ""
Write-Host "=== Последние ошибки ===" -ForegroundColor Cyan

$errorLog = Join-Path (Join-Path $ApachePath "logs") "error.log"
if (Test-Path $errorLog) {
    $lines = Get-Content $errorLog -Tail 5 -ErrorAction SilentlyContinue
    if ($lines -and $lines.Count -gt 0) {
        foreach ($line in $lines) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "(пусто)" -ForegroundColor Green
    }
} else {
    Write-Host "(нет файла)" -ForegroundColor Green
}
