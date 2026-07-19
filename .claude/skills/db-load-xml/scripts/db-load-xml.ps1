# db-load-xml v1.16 — Load 1C configuration from XML files
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: *nix-раскладку платформы (/opt/1cv8/<ver>/1cv8, без .exe) знает только .py-порт — PS на *nix не исполняется.
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

function Protect-Secrets {
    # Redact literal secret values from a display string (String.Replace is literal, not regex).
    param([string]$Text, [string[]]$Secrets)
    foreach ($s in $Secrets) { if ($s) { $Text = $Text.Replace($s, '***') } }
    return $Text
}

function Get-ExitAnnotation {
    # Annotate an abnormal process exit code so a crash isn't reported as a bare number.
    # A batch DESIGNER that crashes (e.g. missing license) may leave the infobase locked or
    # half-updated — surface that instead of a plain code. (Windows exception codes only;
    # POSIX signals are handled in the .py port.)
    param([int]$Code)
    $win = @{
        -1073741819 = "0xC0000005 (access violation)"
        -1073741515 = "0xC0000135 (missing DLL)"
        -1073740791 = "0xC0000409 (stack overrun)"
    }
    if ($win.ContainsKey($Code)) {
        return " — abnormal termination, exception $($win[$Code]); the infobase may be left in an inconsistent state; verify it before retrying"
    }
    return ""
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
    if ($engine -eq "ibcmd") {
        # --- ibcmd branch (file infobase only; hierarchical full-directory import) ---
        if ($Format -eq "Plain") {
            Write-Host "Error: ibcmd config import supports hierarchical format only (use -Format Hierarchical or 1cv8)" -ForegroundColor Red
            exit 1
        }
        if ($AllExtensions) {
            $arguments = @("infobase", "config", "import", "all-extensions", "$ConfigDir", "--db-path=$InfoBasePath")
        } elseif ($Mode -eq "Partial" -or $Files -or $ListFile) {
            # partial: import specific files (relative to ConfigDir)
            $fileList = @()
            if ($ListFile) {
                if (-not (Test-Path $ListFile)) {
                    Write-Host "Error: list file not found: $ListFile" -ForegroundColor Red
                    exit 1
                }
                $fileList = @(Get-Content -Path $ListFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            } elseif ($Files) {
                $fileList = @($Files -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            if ($fileList.Count -eq 0) {
                Write-Host "Error: -Files or -ListFile required for partial import" -ForegroundColor Red
                exit 1
            }
            $arguments = @("infobase", "config", "import", "files") + $fileList
            $arguments += "--base-dir=$ConfigDir", "--db-path=$InfoBasePath"
            if ($Extension) { $arguments += "--extension=$Extension" }
        } else {
            $arguments = @("infobase", "config", "import", "--db-path=$InfoBasePath")
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
        if ($exitCode -ne 0) {
            Write-Host "Error loading configuration from files (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
            if ($output) { Write-Host ($output | Out-String) }
            exit $exitCode
        }
        Write-Host "Configuration loaded successfully from: $ConfigDir" -ForegroundColor Green
        if ($output) { Write-Host ($output | Out-String) }

        if ($UpdateDB) {
            $applyArgs = @("infobase", "config", "apply", "--db-path=$InfoBasePath", "--force")
            if ($UserName) { $applyArgs += "--user=$UserName" }
            if ($Password) { $applyArgs += "--password=$Password" }
            $applyArgs += "--data=$tempDir"
            Write-Host "Running: ibcmd $(Protect-Secrets ($applyArgs -join ' ') @($Password, $UserName))"
            $__ib = Invoke-IbcmdProcess $V8Path $applyArgs
            $applyOut = $__ib.Output
            $exitCode = $__ib.ExitCode
            if ($exitCode -eq 0) {
                Write-Host "Database configuration updated successfully" -ForegroundColor Green
            } else {
                Write-Host "Error updating database configuration (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
            }
            if ($applyOut) { Write-Host ($applyOut | Out-String) }
        }
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

    $arguments += "/LoadConfigFromFiles", "`"$ConfigDir`""

    if ($Mode -eq "Full") {
        Write-Host "Executing full configuration load..."
    } else {
        Write-Host "Executing partial configuration load..."

        # Build list file
        $rawList = @()
        if ($ListFile) {
            if (-not (Test-Path $ListFile)) {
                Write-Host "Error: list file not found: $ListFile" -ForegroundColor Red
                exit 1
            }
            $rawList = @(Get-Content -Path $ListFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else {
            $rawList = @($Files -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }

        # Support-state service files are NOT partially loadable — exclude with a hint.
        $supportRe = 'ParentConfigurations\.bin$|(^|[\\/])ConfigDumpInfo\.xml$'
        $supportFiles = @($rawList | Where-Object { $_ -match $supportRe })
        $fileList = @($rawList | Where-Object { $_ -notmatch $supportRe })
        if ($supportFiles.Count -gt 0) {
            Write-Host "[ВНИМАНИЕ] Служебные файлы состояния поддержки исключены из частичной загрузки (частично не грузятся):" -ForegroundColor Yellow
            foreach ($sf in $supportFiles) { Write-Host "  - $sf" -ForegroundColor Yellow }
            Write-Host "  Смена состояния поддержки применяется только полной загрузкой: -Mode Full." -ForegroundColor Yellow
        }
        if ($fileList.Count -eq 0) {
            Write-Host "Error: после исключения служебных файлов поддержки загружать нечего. Для смены поддержки используйте -Mode Full." -ForegroundColor Red
            exit 1
        }
        $generatedListFile = Join-Path $tempDir "load_list.txt"
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllLines($generatedListFile, $fileList, $utf8Bom)
        Write-Host "Files to load: $($fileList.Count)"
        foreach ($f in $fileList) { Write-Host "  $f" }

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
    Write-Host "Running: 1cv8.exe $(Protect-Secrets ($arguments -join ' ') @($Password, $UserName))"
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
        Write-Host "Error loading configuration (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
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
