# db-load-git v1.21 — Load Git changes into 1C database
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

.PARAMETER AdditionalV8Arguments
    Дополнительные аргументы запуска 1cv8.exe (например /UseHwLicenses+)

.PARAMETER AdditionalIbcmdArguments
    Дополнительные аргументы запуска ibcmd (форма --ключ=значение)

.EXAMPLE
    .\db-load-git.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Source All

.EXAMPLE
    .\db-load-git.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -Source Commit -CommitRange "HEAD~3..HEAD"

.EXAMPLE
    .\db-load-git.ps1 -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\src" -DryRun
#>

[CmdletBinding(PositionalBinding=$false)]
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
    [switch]$UpdateDB,

    [Parameter(Mandatory=$false)]
    # Ключ для регрессов и верификации снапшотов, не для повседневного вызова: в SKILL.md
    # намеренно не выносится. Поднимает код возврата, если платформа отчиталась об успехе,
    # но в логе есть отбраковка.
    [switch]$StrictLog,

    [Parameter(Mandatory=$false)]
    [string[]]$AdditionalV8Arguments = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$AdditionalIbcmdArguments = @()
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Protect-Secrets {
    # Redact literal secret values from a display string (String.Replace is literal, not regex).
    param([string]$Text, [string[]]$Secrets)
    foreach ($s in $Secrets) { if ($s) { $Text = $Text.Replace($s, '***') } }
    return $Text
}

# --- Additional platform arguments ---
$script:V8OwnedKeys = @(
    'DESIGNER', 'ENTERPRISE', 'CREATEINFOBASE', 'CONFIG',
    '/F', '/S', '/N', '/P', '/Out', '/DisableStartupDialogs',
    '/UseTemplate', '/AddToList', '/Execute', '/C', '/URL', '/UC',
    '/DumpIB', '/RestoreIB', '/DumpCfg', '/LoadCfg',
    '/DumpConfigToFiles', '/LoadConfigFromFiles', '/UpdateDBCfg',
    '/DumpExternalDataProcessorOrReportToFiles', '/LoadExternalDataProcessorOrReportFromFiles'
)
$script:IbcmdOwnedKeys = @(
    '--db-path', '--data', '--out', '--file', '--load', '--restore',
    '--import', '--export', '--apply', '--force', '--create-database',
    '--user', '--password'
)
$script:V8SecretKeys = @('/P', '/UC', '/WSP', '/AWSP')
$script:IbcmdSecretKeys = @('--password', '--token', '--db-pwd')

function Test-ArgKeyMatch {
    # A token matches a key when it equals the key, or starts with it and the next
    # character is not a letter — catches glued /N"user" and --password=x, while
    # keeping /ClearCache distinct from /C.
    param([string]$Token, [string]$Key)
    if ($Token.Length -lt $Key.Length) { return $false }
    if (-not $Token.Substring(0, $Key.Length).Equals($Key, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($Token.Length -eq $Key.Length) { return $true }
    return -not [char]::IsLetter($Token[$Key.Length])
}

function Get-ProjectExtraArgs {
    # v8args / ibcmdargs from .v8-project.json — same upward walk as v8path.
    param([string]$Name)
    $dir = (Get-Location).Path
    while ($dir) {
        $pf = Join-Path $dir ".v8-project.json"
        if (Test-Path $pf) {
            try {
                $j = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.$Name) { return @($j.$Name | ForEach-Object { [string]$_ }) }
            } catch {}
            return @()
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return @()
}

function Assert-ExtraArgs {
    # The platform accepts only one batch operation, and a duplicate connection or
    # output key fails with an opaque 1C error — reject what the skill owns itself.
    param([string[]]$ExtraArgs, [string]$Engine, [hashtable]$Hints)
    $paramName = if ($Engine -eq 'ibcmd') { '-AdditionalIbcmdArguments' } else { '-AdditionalV8Arguments' }
    $owned = if ($Engine -eq 'ibcmd') { $script:IbcmdOwnedKeys } else { $script:V8OwnedKeys }
    foreach ($tok in $ExtraArgs) {
        if ($Engine -eq 'ibcmd' -and $tok -notmatch '^-') {
            Write-Host "Error: '$tok' is a positional token — pass values as --key=value ($paramName cannot extend the ibcmd command)" -ForegroundColor Red
            exit 1
        }
        foreach ($k in $owned) {
            if (Test-ArgKeyMatch $tok $k) {
                $hint = ''
                if ($Hints -and $Hints.ContainsKey($k)) { $hint = " (use $($Hints[$k]))" }
                Write-Host "Error: $k is controlled by the skill and cannot be passed via $paramName$hint" -ForegroundColor Red
                exit 1
            }
        }
    }
}

function Resolve-ExtraArgs {
    # Pick the argument list for the selected engine and validate it. An explicitly passed
    # parameter for the other engine is an error; the same keys coming from .v8-project.json
    # simply do not apply — a project may describe both engines.
    param([string]$Engine, [string[]]$V8Extra, [string[]]$IbcmdExtra, [hashtable]$Hints)
    # powershell.exe -File — how skills are invoked — cannot bind an array parameter:
    # space-separated values spill into positional ones, a comma-joined list arrives as a
    # single token. So accept the repo's list convention (comma-separated) and split here;
    # a native array call keeps working. A value containing a comma is not supported.
    $V8Extra = @($V8Extra | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
    $IbcmdExtra = @($IbcmdExtra | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
    if ($Engine -eq 'ibcmd' -and $V8Extra.Count -gt 0) {
        Write-Host "Error: -AdditionalV8Arguments applies to 1cv8 only; the selected engine is ibcmd (use -AdditionalIbcmdArguments)" -ForegroundColor Red
        exit 1
    }
    if ($Engine -ne 'ibcmd' -and $IbcmdExtra.Count -gt 0) {
        Write-Host "Error: -AdditionalIbcmdArguments applies to ibcmd only; the selected engine is 1cv8 (use -AdditionalV8Arguments)" -ForegroundColor Red
        exit 1
    }
    if ($Engine -eq 'ibcmd') {
        $extra = @(Get-ProjectExtraArgs 'ibcmdargs') + @($IbcmdExtra)
    } else {
        $extra = @(Get-ProjectExtraArgs 'v8args') + @($V8Extra)
    }
    if ($extra.Count -gt 0) { Assert-ExtraArgs $extra $Engine $Hints }
    # Plain return, no comma trick: the caller re-collects with @(...), and ,@() there
    # would nest the array — the tokens would then be glued into one argument.
    return $extra
}

function Format-ArgsForDisplay {
    # Redact values of secret-prone keys in glued, =-joined and separate forms.
    # Matching here is a plain prefix (no letter rule): over-masking costs nothing,
    # a leaked password does.
    param([string[]]$ArgList, [string]$Engine)
    $keys = if ($Engine -eq 'ibcmd') { $script:IbcmdSecretKeys } else { $script:V8SecretKeys }
    $res = @()
    $maskNext = $false
    foreach ($tok in $ArgList) {
        if ($maskNext) { $res += '***'; $maskNext = $false; continue }
        $hit = $null
        foreach ($k in $keys) {
            if ($tok.Length -ge $k.Length -and $tok.Substring(0, $k.Length).Equals($k, [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $k; break }
        }
        if (-not $hit) { $res += $tok; continue }
        if ($tok.Length -eq $hit.Length) { $res += $tok; $maskNext = $true }
        elseif ($tok[$hit.Length] -eq '=') { $res += ($hit + '=***') }
        else { $res += ($hit + '***') }
    }
    return ,$res
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
function ConvertFrom-PlatformBytes {
    # ibcmd writes UTF-8 (checked on 8.3.24, 8.3.27, 8.5), a crashing 1cv8 may still emit
    # OEM text. Decode strictly as UTF-8 and fall back to cp866 on invalid bytes — guessing
    # one of them outright mangles Cyrillic.
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($Bytes)
    } catch {
        return [System.Text.Encoding]::GetEncoding(866).GetString($Bytes)
    }
}

function Invoke-PlatformProcess {
    # Run the platform non-interactively and capture its console output. A closed stdin pipe
    # (EOF) makes an auth prompt fast-fail instead of hanging; capturing keeps the child's
    # text out of our stream until we print it labelled (and out of the wrong encoding).
    # Returns @{ Output; ExitCode }.
    #
    # Quoting differs by engine, so the caller says which it built:
    #   ibcmd    — tokens are bare (--db-path=C:\a b), the whole token gets quoted here;
    #   1cv8     — -PreQuoted: the caller already put quotes inside the token (File="C:\a b"),
    #              which is where 1C's own parser expects them; quoting again breaks the value.
    param([string]$Exe, [string[]]$ProcArgs, [switch]$PreQuoted)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = if ($PreQuoted) {
        $ProcArgs -join ' '
    } else {
        ($ProcArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    # stderr is drained in parallel: reading the streams one after another deadlocks
    # as soon as the other one fills its pipe buffer.
    $errMs = New-Object System.IO.MemoryStream
    $errTask = $p.StandardError.BaseStream.CopyToAsync($errMs)
    $outMs = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($outMs)
    $errTask.Wait()
    $p.WaitForExit()
    $out = ConvertFrom-PlatformBytes $outMs.ToArray()
    $err = ConvertFrom-PlatformBytes $errMs.ToArray()
    if ($err) { $out += $err }
    return [pscustomobject]@{ Output = $out; ExitCode = $p.ExitCode }
}

function Write-PlatformOutput {
    # Print what the platform wrote to the console as its own labelled block. Silence stays
    # silent: in batch mode 1cv8 reports through /Out and prints nothing here.
    param([string]$Text)
    if (-not $Text) { return }
    $t = $Text.TrimEnd()
    if (-not $t) { return }
    $limit = 65536
    if ($t.Length -gt $limit) {
        $t = "[... обрезано, показаны последние $limit символов ...]`r`n" + $t.Substring($t.Length - $limit)
    }
    Write-Host "--- Вывод платформы ---"
    Write-Host $t
    Write-Host "--- End ---"
}

# Строки лога, о которых платформа сообщает, НЕ поднимая код возврата: метаданные отброшены или
# конфигурация нерабочая, а операция при этом «успешна». Возвращает подошедшие строки.
#
# Копия этой функции есть в каждом навыке, который читает /Out-лог загрузки (навыки автономны).
# Держать копии одинаковыми — сознательно: разошедшиеся копии сводят на нет весь смысл.
function Find-SilentRejections {
    param([string]$LogText)
    $patterns = @(
        'Неверное свойство объекта метаданных',
        'не входит в состав объекта метаданных',
        'Неизвестное имя типа',
        'Неизвестный объект метаданных',
        'Ни один из документов не является регистратором для регистра',
        'Неверное значение перечисления',
        'не может быть приведен к типу',
        # Режим совместимости выше платформы: объекты в базу не попадают, отказ приходит в рантайме.
        # Обрезано до инвариантной части — конкретная версия в сообщении меняется.
        'Для работы с конфигурацией необходима версия платформы не меньше'
    )
    $found = @()
    if ($LogText) {
        foreach ($line in ($LogText -split "`r?`n")) {
            foreach ($pat in $patterns) {
                if ($line -match [regex]::Escape($pat)) {
                    $found += $line.Trim()
                    break
                }
            }
        }
    }
    # Возвращаем массив БЕЗ запятой-обёртки: вызывающий берёт результат в @(), а `return ,$found`
    # дал бы массив из одного пустого массива — фантомное срабатывание на чистом логе.
    return $found
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

# --- Resolve additional arguments for the selected engine ---
$argHints = @{ '/F' = '-InfoBasePath'; '/S' = '-InfoBaseServer + -InfoBaseRef'; '/N' = '-UserName'; '/P' = '-Password'; '--db-path' = '-InfoBasePath'; '--user' = '-UserName'; '--password' = '-Password' }
$extraArgs = @(Resolve-ExtraArgs $engine $AdditionalV8Arguments $AdditionalIbcmdArguments $argHints)

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
        $arguments += $extraArgs
        Write-Host "Running: ibcmd $(Protect-Secrets ((Format-ArgsForDisplay $arguments $engine) -join ' ') @($Password, $UserName))"
        $__ib = Invoke-PlatformProcess $V8Path $arguments
        $output = $__ib.Output
        $exitCode = $__ib.ExitCode
        if ($exitCode -ne 0) {
            Write-Host "Error loading changes (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
            Write-PlatformOutput $output
            exit $exitCode
        }
        Write-Host "Changes loaded successfully ($($configFiles.Count) files)" -ForegroundColor Green
        Write-PlatformOutput $output
        if ($UpdateDB) {
            $applyArgs = @("infobase", "config", "apply", "--db-path=$InfoBasePath", "--force")
            if ($UserName) { $applyArgs += "--user=$UserName" }
            if ($Password) { $applyArgs += "--password=$Password" }
            $applyArgs += "--data=$tempDir"
            $applyArgs += $extraArgs
            Write-Host "Running: ibcmd $(Protect-Secrets ((Format-ArgsForDisplay $applyArgs $engine) -join ' ') @($Password, $UserName))"
            $__ib = Invoke-PlatformProcess $V8Path $applyArgs
            $applyOut = $__ib.Output
            $exitCode = $__ib.ExitCode
            if ($exitCode -eq 0) {
                Write-Host "Database configuration updated successfully" -ForegroundColor Green
            } else {
                Write-Host "Error updating database configuration (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
            }
            Write-PlatformOutput $applyOut
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
    $arguments += $extraArgs

    # --- Execute ---
    Write-Host ""
    Write-Host "Executing partial configuration load..."
    Write-Host "Running: 1cv8.exe $(Protect-Secrets ((Format-ArgsForDisplay $arguments $engine) -join ' ') @($Password, $UserName))"

    $__v8 = Invoke-PlatformProcess $V8Path $arguments -PreQuoted
    $exitCode = $__v8.ExitCode

    # --- Result ---
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "Load completed successfully" -ForegroundColor Green
    } else {
        Write-Host "Error loading configuration (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
    }

    $logContent = $null
    if (Test-Path $outFile) {
        $logContent = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        if ($logContent) {
            Write-Host "--- Log ---"
            Write-Host $logContent
            Write-Host "--- End ---"
        }
    }
    Write-PlatformOutput $__v8.Output

    # Причину не называем: строки лога печатаются следом и говорят за себя, а класс проблемы
    # разный — от отброшенного свойства до нерабочей на этой платформе конфигурации. Подсказку
    # про -StrictLog не даём: операция уже выполнена, повторять её ради того же текста незачем.
    $silentFailures = @(Find-SilentRejections $logContent)
    if ($silentFailures.Count -gt 0) {
        Write-Host "[warning] platform reported success, but the log contains $($silentFailures.Count) problem(s):" -ForegroundColor Yellow
        foreach ($f in $silentFailures) { Write-Host "  $f" -ForegroundColor Yellow }
        if ($StrictLog -and $exitCode -eq 0) { $exitCode = 1 }
    }

    exit $exitCode

} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
