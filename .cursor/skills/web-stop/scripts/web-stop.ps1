# web-stop v1.0 — Stop Apache HTTP Server
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Остановка Apache HTTP Server

.DESCRIPTION
    Останавливает Apache HTTP Server. Сначала пытается graceful shutdown,
    при неудаче — принудительная остановка.

.PARAMETER ApachePath
    Корень Apache (по умолчанию tools\apache24)

.EXAMPLE
    .\web-stop.ps1

.EXAMPLE
    .\web-stop.ps1 -ApachePath "C:\tools\apache24"
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

# --- Helper: filter httpd processes by our ApachePath ---
$httpdExe = Join-Path (Join-Path $ApachePath "bin") "httpd.exe"
$httpdExeNorm = (Resolve-Path $httpdExe -ErrorAction SilentlyContinue).Path
function Get-OurHttpd {
    Get-Process httpd -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $httpdExeNorm } catch { $false }
    }
}

# --- Check process (only our Apache) ---
$httpdProc = Get-OurHttpd
if (-not $httpdProc) {
    $foreign = Get-Process httpd -ErrorAction SilentlyContinue
    if ($foreign) {
        Write-Host "Наш Apache не запущен" -ForegroundColor Yellow
        Write-Host "[WARN] Обнаружен сторонний Apache (PID: $(($foreign | Select-Object -First 1).Id))" -ForegroundColor Yellow
    } else {
        Write-Host "Apache не запущен" -ForegroundColor Yellow
    }
    exit 0
}

$pids = ($httpdProc | ForEach-Object { $_.Id }) -join ", "
Write-Host "Останавливаю Apache (PID: $pids)..."

# --- Stop our processes ---
$httpdProc | Stop-Process -Force -ErrorAction SilentlyContinue

# --- Wait for shutdown ---
$maxWait = 5
$elapsed = 0
while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds 1
    $elapsed++
    $check = Get-OurHttpd
    if (-not $check) {
        Write-Host "Apache остановлен" -ForegroundColor Green
        Write-Host "Публикации сохранены. Перезапуск: /web-publish <база>  Удаление: /web-unpublish --all" -ForegroundColor Gray
        exit 0
    }
}

# --- Fallback: force kill ---
$remaining = Get-OurHttpd
if ($remaining) {
    Write-Host "Принудительная остановка..." -ForegroundColor Yellow
    $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $final = Get-OurHttpd
    if ($final) {
        Write-Host "Error: не удалось остановить Apache" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Apache остановлен" -ForegroundColor Green
Write-Host "Публикации сохранены. Перезапуск: /web-publish <база>  Удаление: /web-unpublish --all" -ForegroundColor Gray
