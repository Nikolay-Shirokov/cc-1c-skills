# db-load-git v1.15 — Load Git changes into 1C database
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: *nix-раскладку платформы (/opt/1cv8/<ver>/1cv8, без .exe) знает только .py-порт — PS на *nix не исполняется.
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
}

# --- Detect engine + validate connection (skip if DryRun) ---
$engine = "1cv8"
if (-not $DryRun) {
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
    if ($engine -eq "ibcmd") {
        if (-not $InfoBasePath) {
            Write-Host "Error: ibcmd supports file infobases only (use -InfoBasePath)" -ForegroundColor Red
            exit 1
        }
    } elseif (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
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
# Все git-вызовы для сбора путей идут через один хелпер с -c core.quotePath=false,
# иначе кириллические пути возвращаются в octal-виде и не распознаются (зеркало run_git в .py).
function Invoke-GitLines {
    param([string[]]$GitArgs)
    $out = git -c core.quotePath=false @GitArgs 2>&1
    if ($LASTEXITCODE -eq 0) { return $out }
    return @()
}

$changedFiles = @()
$ConfigDir = (Resolve-Path $ConfigDir).Path.TrimEnd('\')
$configDirNormalized = $ConfigDir.Replace('\', '/')

Push-Location $ConfigDir
try {
    switch ($Source) {
        "Staged" {
            Write-Host "Getting staged changes..."
            $changedFiles += Invoke-GitLines -GitArgs @('diff', '--cached', '--name-only', '--relative')
        }
        "Unstaged" {
            Write-Host "Getting unstaged changes..."
            $changedFiles += Invoke-GitLines -GitArgs @('diff', '--name-only', '--relative')
            $changedFiles += Invoke-GitLines -GitArgs @('ls-files', '--others', '--exclude-standard')
        }
        "Commit" {
            Write-Host "Getting changes from $CommitRange..."
            $changedFiles += Invoke-GitLines -GitArgs @('diff', '--name-only', '--relative', $CommitRange)
        }
        "All" {
            Write-Host "Getting all uncommitted changes..."
            $changedFiles += Invoke-GitLines -GitArgs @('diff', '--cached', '--name-only', '--relative')
            $changedFiles += Invoke-GitLines -GitArgs @('diff', '--name-only', '--relative')
            $changedFiles += Invoke-GitLines -GitArgs @('ls-files', '--others', '--exclude-standard')
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
$supportSkipped = @()

foreach ($file in $changedFiles) {
    $file = $file.Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($file)) { continue }

    # Skip service files (not partially loadable). Support-state files are tracked
    # to warn the user: support changes apply only via a full load.
    if ($file -match 'ParentConfigurations\.bin$') { $supportSkipped += $file; continue }
    if ($file -eq "ConfigDumpInfo.xml" -or $file -match '(^|/)ConfigDumpInfo\.xml$') { continue }

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

if ($supportSkipped.Count -gt 0) {
    Write-Host "[ВНИМАНИЕ] Состояние поддержки изменено в коммите, но частично не загружается (исключено):" -ForegroundColor Yellow
    foreach ($sf in $supportSkipped) { Write-Host "  - $sf" -ForegroundColor Yellow }
    Write-Host "  Смена состояния поддержки применяется только полной загрузкой (db-load-xml -Mode Full)." -ForegroundColor Yellow
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
    if ($engine -eq "ibcmd") {
        # --- ibcmd branch (file infobase only; import specific files) ---
        if ($Format -eq "Plain") {
            Write-Host "Error: ibcmd config import supports hierarchical format only (use -Format Hierarchical or 1cv8)" -ForegroundColor Red
            exit 1
        }
        if ($AllExtensions) {
            Write-Host "Error: ibcmd config import does not support -AllExtensions (use -Extension or 1cv8)" -ForegroundColor Red
            exit 1
        }
        $arguments = @("infobase", "config", "import", "files") + $configFiles
        $arguments += "--base-dir=$ConfigDir", "--db-path=$InfoBasePath"
        if ($Extension) { $arguments += "--extension=$Extension" }
        if ($UserName) { $arguments += "--user=$UserName" }
        if ($Password) { $arguments += "--password=$Password" }
        $arguments += "--data=$tempDir"
        Write-Host "Running: ibcmd $(Protect-Secrets ($arguments -join ' ') @($Password, $UserName))"
        $__ib = Invoke-IbcmdProcess $V8Path $arguments
        $output = $__ib.Output
        $exitCode = $__ib.ExitCode
        if ($exitCode -ne 0) {
            Write-Host "Error loading changes (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
            if ($output) { Write-Host ($output | Out-String) }
            exit $exitCode
        }
        Write-Host "Changes loaded successfully ($($configFiles.Count) files)" -ForegroundColor Green
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
    Write-Host "Running: 1cv8.exe $(Protect-Secrets ($arguments -join ' ') @($Password, $UserName))"

    $process = Start-Process -FilePath $V8Path -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode

    # --- Result ---
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "Load completed successfully" -ForegroundColor Green
    } else {
        Write-Host "Error loading configuration (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
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
