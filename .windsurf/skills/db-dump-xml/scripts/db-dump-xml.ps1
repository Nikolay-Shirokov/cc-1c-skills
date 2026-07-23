# db-dump-xml v1.11 — Dump 1C configuration to XML files
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: *nix-раскладку платформы (/opt/1cv8/<ver>/1cv8, без .exe) знает только .py-порт — PS на *nix не исполняется.
<#
.SYNOPSIS
    Выгрузка конфигурации 1С в XML-файлы

.DESCRIPTION
    Выполняет выгрузку конфигурации 1С в файлы в четырёх режимах:
    - Full: полная выгрузка всей конфигурации
    - Changes: инкрементальная выгрузка изменённых объектов
    - Partial: выгрузка конкретных объектов из списка
    - UpdateInfo: обновление только ConfigDumpInfo.xml

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
    Каталог для выгрузки конфигурации

.PARAMETER Mode
    Режим выгрузки: Full, Changes, Partial, UpdateInfo (по умолчанию Changes)

.PARAMETER Objects
    Имена объектов метаданных через запятую (для режима Partial)

.PARAMETER Extension
    Имя расширения для выгрузки

.PARAMETER AllExtensions
    Выгрузить все расширения

.PARAMETER Format
    Формат выгрузки: Hierarchical или Plain (по умолчанию Hierarchical)

.EXAMPLE
    .\db-dump-xml.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Mode Full

.EXAMPLE
    .\db-dump-xml.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Mode Partial -Objects "Справочник.Номенклатура,Документ.Заказ"
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
    [ValidateSet("Full", "Changes", "Partial", "UpdateInfo")]
    [string]$Mode = "Changes",

    [Parameter(Mandatory=$false)]
    [string]$Objects,

    [Parameter(Mandatory=$false)]
    [string]$Extension,

    [Parameter(Mandatory=$false)]
    [switch]$AllExtensions,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Hierarchical", "Plain")]
    [string]$Format = "Hierarchical"
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Protect-Secrets {
    # Redact literal secret values from a display string (String.Replace is literal, not regex).
    param([string]$Text, [string[]]$Secrets)
    foreach ($s in $Secrets) { if ($s) { $Text = $Text.Replace($s, '***') } }
    return $Text
}

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

# --- Detect engine (ibcmd vs 1cv8) by exe name ---
function Invoke-IbcmdProcess {
    # Run ibcmd non-interactively: a closed stdin pipe (EOF) makes ibcmd's auth prompt
    # fast-fail instead of hanging. Returns @{ Output; ExitCode }. cp866 decodes ibcmd's
    # native OEM output. The 1cv8/DESIGNER branch keeps using Start-Process.
    param([string]$Exe, [string[]]$IbArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($IbArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(866)
        $psi.StandardErrorEncoding = [System.Text.Encoding]::GetEncoding(866)
    } catch {}
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($err) { $out += $err }
    return [pscustomobject]@{ Output = $out; ExitCode = $p.ExitCode }
}


function Test-DirNonEmpty {
    # Postcondition: the platform must have written files into the output directory.
    # Exit code 0 with an empty dir (broken/headless env) is a false success — reject it.
    param([string]$Path)
    return (Test-Path $Path -PathType Container) -and ([bool](Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
}

$engine = if ((Split-Path $V8Path -Leaf) -match '^ibcmd') { "ibcmd" } else { "1cv8" }

# --- Validate connection ---
if ($engine -eq "ibcmd") {
    if (-not $InfoBasePath) {
        Write-Host "Error: ibcmd supports file infobases only (use -InfoBasePath)" -ForegroundColor Red
        exit 1
    }
} elseif (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    Write-Host "Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef" -ForegroundColor Red
    exit 1
}

# --- Validate Partial mode ---
if ($Mode -eq "Partial" -and -not $Objects) {
    Write-Host "Error: -Objects required for Partial mode" -ForegroundColor Red
    exit 1
}

# --- Create output dir if needed ---
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    Write-Host "Created output directory: $ConfigDir"
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "db_dump_xml_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    if ($engine -eq "ibcmd") {
        # --- ibcmd branch (file infobase only; hierarchical Full/Changes) ---
        if ($Format -eq "Plain") {
            Write-Host "Error: ibcmd config export supports hierarchical format only (use -Format Hierarchical or 1cv8)" -ForegroundColor Red
            exit 1
        }
        if ($AllExtensions) {
            $arguments = @("infobase", "config", "export", "all-extensions", "$ConfigDir", "--db-path=$InfoBasePath")
        } elseif ($Mode -eq "UpdateInfo") {
            Write-Host "Error: ibcmd config export does not support Mode UpdateInfo; use 1cv8" -ForegroundColor Red
            exit 1
        } elseif ($Mode -eq "Partial") {
            $objList = @($Objects -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $arguments = @("infobase", "config", "export", "objects") + $objList
            $arguments += "--out=$ConfigDir", "--db-path=$InfoBasePath"
            if ($Extension) { $arguments += "--extension=$Extension" }
        } else {
            $arguments = @("infobase", "config", "export", "--db-path=$InfoBasePath")
            if ($Extension) { $arguments += "--extension=$Extension" }
            $arguments += "$ConfigDir"
        }
        if ($UserName) { $arguments += "--user=$UserName" }
        if ($Password) { $arguments += "--password=$Password" }
        $arguments += "--data=$tempDir"
        Write-Host "Running: ibcmd $(Protect-Secrets ($arguments -join ' ') @($Password, $UserName))"
        $__ib = Invoke-IbcmdProcess $V8Path $arguments
        $output = $__ib.Output
        $exitCode = $__ib.ExitCode
        $outMissing = ($exitCode -eq 0) -and -not (Test-DirNonEmpty $ConfigDir)
        if ($outMissing) { $exitCode = 1 }
        if ($exitCode -eq 0) {
            Write-Host "Configuration exported successfully to: $ConfigDir" -ForegroundColor Green
        } elseif ($outMissing) {
            Write-Host "Error: exit code 0 but no files under $ConfigDir — configuration was not exported" -ForegroundColor Red
        } else {
            Write-Host "Error exporting configuration (code: $exitCode)" -ForegroundColor Red
        }
        if ($output) { Write-Host ($output | Out-String) }
        exit $exitCode
    }

    # --- 1cv8 branch ---
    # --- Build arguments ---
    $arguments = @("DESIGNER")

    if ($InfoBaseServer -and $InfoBaseRef) {
        $arguments += "/S", "`"$InfoBaseServer/$InfoBaseRef`""
    } else {
        $arguments += "/F", "`"$InfoBasePath`""
    }

    if ($UserName) { $arguments += "/N`"$UserName`"" }
    if ($Password) { $arguments += "/P`"$Password`"" }

    $arguments += "/DumpConfigToFiles", "`"$ConfigDir`""
    $arguments += "-Format", $Format

    switch ($Mode) {
        "Full" {
            Write-Host "Executing full configuration dump..."
        }
        "Changes" {
            Write-Host "Executing incremental configuration dump..."
            $arguments += "-update"
            $arguments += "-force"
        }
        "Partial" {
            Write-Host "Executing partial configuration dump..."
            $objectList = $Objects -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

            $listFile = Join-Path $tempDir "dump_list.txt"
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllLines($listFile, $objectList, $utf8Bom)

            $arguments += "-listFile", "`"$listFile`""
            Write-Host "Objects to dump: $($objectList.Count)"
            foreach ($obj in $objectList) { Write-Host "  $obj" }
        }
        "UpdateInfo" {
            Write-Host "Updating ConfigDumpInfo.xml..."
            $arguments += "-configDumpInfoOnly"
        }
    }

    # --- Extensions ---
    if ($Extension) {
        $arguments += "-Extension", "`"$Extension`""
    } elseif ($AllExtensions) {
        $arguments += "-AllExtensions"
    }

    # --- Output ---
    $outFile = Join-Path $tempDir "dump_log.txt"
    $arguments += "/Out", "`"$outFile`""
    $arguments += "/DisableStartupDialogs"

    # --- Execute ---
    Write-Host "Running: 1cv8.exe $(Protect-Secrets ($arguments -join ' ') @($Password, $UserName))"
    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Result ---
    # Postcondition: exit 0 with an empty output directory is a false success.
    $outMissing = ($exitCode -eq 0) -and -not (Test-DirNonEmpty $ConfigDir)
    if ($outMissing) { $exitCode = 1 }
    if ($exitCode -eq 0) {
        Write-Host "Dump completed successfully" -ForegroundColor Green
        Write-Host "Configuration dumped to: $ConfigDir"
    } elseif ($outMissing) {
        Write-Host "Error: exit code 0 but no files under $ConfigDir — configuration was not dumped" -ForegroundColor Red
    } else {
        Write-Host "Error dumping configuration (code: $exitCode)" -ForegroundColor Red
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
