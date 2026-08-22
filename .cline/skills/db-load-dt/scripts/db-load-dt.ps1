# db-load-dt v1.14 — Load 1C information base from DT file
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: *nix-раскладку платформы (/opt/1cv8/<ver>/1cv8, без .exe) знает только .py-порт — PS на *nix не исполняется.
<#
.SYNOPSIS
    Загрузка информационной базы 1С из DT-файла

.DESCRIPTION
    Загружает информационную базу целиком (конфигурация + данные) из DT-файла.
    ВНИМАНИЕ: операция полностью перезаписывает базу.

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

.PARAMETER InputFile
    Путь к DT-файлу для загрузки

.PARAMETER JobsCount
    Количество фоновых заданий для загрузки (0 = по числу процессоров)

.PARAMETER UnlockCode
    Код разблокировки базы (/UC) — если заблокировано начало сеансов

.PARAMETER AdditionalV8Arguments
    Дополнительные аргументы запуска 1cv8.exe (например /UseHwLicenses+)

.PARAMETER AdditionalIbcmdArguments
    Дополнительные аргументы запуска ibcmd (форма --ключ=значение)

.EXAMPLE
    .\db-load-dt.ps1 -InfoBasePath "C:\Bases\MyDB" -InputFile "backup.dt"
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
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [int]$JobsCount = 0,

    [Parameter(Mandatory=$false)]
    [string]$UnlockCode,

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

function ConvertTo-CleanPath {
    # Forgive what is unambiguous in a path the caller passed: surrounding whitespace,
    # surrounding quotes that survived shell parsing, a trailing separator. A quote left
    # inside afterwards cannot be part of a real path — reject it by name instead of letting
    # 1C answer with its opaque "Неверные или отсутствующие параметры соединения".
    param([string]$Value, [string]$ParamName)
    if (-not $Value) { return $Value }
    $v = $Value.Trim()
    if ($v.Length -ge 2 -and $v[0] -eq $v[-1] -and ($v[0] -eq '"' -or $v[0] -eq "'")) {
        $v = $v.Substring(1, $v.Length - 2).Trim()
    }
    if ($v.Length -gt 3 -and ($v[-1] -eq '\' -or $v[-1] -eq '/')) { $v = $v.Substring(0, $v.Length - 1) }
    if ($v.Contains('"')) {
        Write-Host "Error: $ParamName contains a quote character: $Value" -ForegroundColor Red
        exit 1
    }
    return $v
}

$V8Path = ConvertTo-CleanPath $V8Path '-V8Path'
$InfoBasePath = ConvertTo-CleanPath $InfoBasePath '-InfoBasePath'
$InputFile = ConvertTo-CleanPath $InputFile '-InputFile'

function Assert-InfoBaseExists {
    # These skills work on a ready infobase. Saying so up front beats the platform's
    # "Неверные или отсутствующие параметры соединения" after a launch.
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path (Join-Path $Path "1Cv8.1CD"))) {
        Write-Host "Error: information base not found at $Path (no 1Cv8.1CD)" -ForegroundColor Red
        exit 1
    }
}

Assert-InfoBaseExists $InfoBasePath

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


$engine = if ((Split-Path $V8Path -Leaf) -match '^ibcmd') { "ibcmd" } else { "1cv8" }

# --- Resolve additional arguments for the selected engine ---
$argHints = @{ '/F' = '-InfoBasePath'; '/S' = '-InfoBaseServer + -InfoBaseRef'; '/N' = '-UserName'; '/P' = '-Password'; '--db-path' = '-InfoBasePath'; '--user' = '-UserName'; '--password' = '-Password' }
$extraArgs = @(Resolve-ExtraArgs $engine $AdditionalV8Arguments $AdditionalIbcmdArguments $argHints)

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

# --- Validate input file ---
if (-not (Test-Path $InputFile)) {
    Write-Host "Error: input file not found: $InputFile" -ForegroundColor Red
    exit 1
}

# --- Temp dir ---
$tempDir = Join-Path $env:TEMP "db_load_dt_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    if ($engine -eq "ibcmd") {
        # --- ibcmd branch (file infobase only) ---
        $arguments = @("infobase", "restore", "--db-path=$InfoBasePath")
        if (-not (Test-Path (Join-Path $InfoBasePath "1Cv8.1CD"))) { $arguments += "--create-database" }
        if ($UserName) { $arguments += "--user=$UserName" }
        if ($Password) { $arguments += "--password=$Password" }
        $arguments += "$InputFile"

        $arguments += "--data=$tempDir"

        $arguments += $extraArgs
        Write-Host "Running: ibcmd $(Protect-Secrets ((Format-ArgsForDisplay $arguments $engine) -join ' ') @($Password, $UserName))"
        $__ib = Invoke-PlatformProcess $V8Path $arguments
        $output = $__ib.Output
        $exitCode = $__ib.ExitCode
        if ($exitCode -eq 0) {
            Write-Host "Information base restored successfully from: $InputFile" -ForegroundColor Green
        } else {
            Write-Host "Error restoring information base (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
        }
        Write-PlatformOutput $output
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
    if ($UnlockCode) { $arguments += "/UC`"$UnlockCode`"" }

    $arguments += "/RestoreIB", "`"$InputFile`""
    if ($JobsCount -gt 0) { $arguments += "-JobsCount", "$JobsCount" }

    # --- Output ---
    $outFile = Join-Path $tempDir "load_dt_log.txt"
    $arguments += "/Out", "`"$outFile`""
    $arguments += "/DisableStartupDialogs"
    $arguments += $extraArgs

    # --- Execute ---
    Write-Host "Running: 1cv8.exe $(Protect-Secrets ((Format-ArgsForDisplay $arguments $engine) -join ' ') @($Password, $UserName))"
    $__v8 = Invoke-PlatformProcess $V8Path $arguments -PreQuoted
    $exitCode = $__v8.ExitCode

    # --- Result ---
    if ($exitCode -eq 0) {
        Write-Host "Information base restored successfully from: $InputFile" -ForegroundColor Green
    } else {
        Write-Host "Error restoring information base (code: $exitCode)$(Get-ExitAnnotation $exitCode)" -ForegroundColor Red
    }

    if (Test-Path $outFile) {
        $logContent = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        if ($logContent) {
            Write-Host "--- Log ---"
            Write-Host $logContent
            Write-Host "--- End ---"
        }
    }
    Write-PlatformOutput $__v8.Output

    exit $exitCode

} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
