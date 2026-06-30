# db-run v1.2 — Launch 1C:Enterprise
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: *nix-раскладку платформы (/opt/1cv8/<ver>/1cv8, без .exe) знает только .py-порт — PS на *nix не исполняется.
<#
.SYNOPSIS
    Запуск 1С:Предприятие

.DESCRIPTION
    Запускает информационную базу в режиме 1С:Предприятие (пользовательский режим).
    Запуск в фоне — не ждёт завершения процесса.

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

.PARAMETER Execute
    Путь к внешней обработке для запуска

.PARAMETER CParam
    Параметр запуска (/C)

.PARAMETER URL
    Навигационная ссылка (e1cib/...)

.EXAMPLE
    .\db-run.ps1 -InfoBasePath "C:\Bases\MyDB"

.EXAMPLE
    .\db-run.ps1 -InfoBasePath "C:\Bases\MyDB" -Execute "C:\epf\МояОбработка.epf"

.EXAMPLE
    .\db-run.ps1 -InfoBasePath "C:\Bases\MyDB" -CParam "ЗапуститьОбновление"
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
    [string]$Execute,

    [Parameter(Mandatory=$false)]
    [string]$CParam,

    [Parameter(Mandatory=$false)]
    [string]$URL
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
        Write-Host "Error: 1C executable not found. Specify -V8Path" -ForegroundColor Red
        exit 1
    }
}
if (Test-Path $V8Path -PathType Container) {
    $V8Path = Join-Path $V8Path "1cv8.exe"
}

if (-not (Test-Path $V8Path)) {
    Write-Host "Error: 1C executable not found at $V8Path" -ForegroundColor Red
    exit 1
}

# --- Validate connection ---
if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    Write-Host "Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef" -ForegroundColor Red
    exit 1
}

# --- Build arguments as single string ---
# Note: Start-Process without -NoNewWindow uses ShellExecute.
# Passing ArgumentList as array can corrupt Cyrillic when ShellExecute
# re-joins elements. Single string avoids this.
$argString = "ENTERPRISE"

if ($InfoBaseServer -and $InfoBaseRef) {
    $argString += " /S `"$InfoBaseServer/$InfoBaseRef`""
} else {
    $argString += " /F `"$InfoBasePath`""
}

if ($UserName) { $argString += " /N`"$UserName`"" }
if ($Password) { $argString += " /P`"$Password`"" }

# --- Optional params ---
if ($Execute) {
    $ext = [System.IO.Path]::GetExtension($Execute).ToLower()
    if ($ext -eq ".erf") {
        Write-Host "[WARN] /Execute не поддерживает ERF-файлы (внешние отчёты)." -ForegroundColor Yellow
        Write-Host "       Откройте отчёт через «Файл -> Открыть»: $Execute" -ForegroundColor Yellow
        Write-Host "       Запускаю базу без /Execute." -ForegroundColor Yellow
        $Execute = ""
    }
}
if ($Execute) {
    $argString += " /Execute `"$Execute`""
}
if ($CParam) {
    $argString += " /C `"$CParam`""
}
if ($URL) {
    $argString += " /URL `"$URL`""
}

$argString += " /DisableStartupDialogs"

# --- Execute (background, no wait) ---
Write-Host "Running: 1cv8.exe $argString"
Start-Process -FilePath $V8Path -ArgumentList $argString
Write-Host "1C:Enterprise launched" -ForegroundColor Green
