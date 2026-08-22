# db-run v1.9 — Launch 1C:Enterprise
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

.PARAMETER AdditionalV8Arguments
    Дополнительные аргументы запуска 1cv8.exe (например /UseHwLicenses+)

.PARAMETER AdditionalIbcmdArguments
    Дополнительные аргументы запуска ibcmd (форма --ключ=значение)

.EXAMPLE
    .\db-run.ps1 -InfoBasePath "C:\Bases\MyDB"

.EXAMPLE
    .\db-run.ps1 -InfoBasePath "C:\Bases\MyDB" -Execute "C:\epf\МояОбработка.epf"

.EXAMPLE
    .\db-run.ps1 -InfoBasePath "C:\Bases\MyDB" -CParam "ЗапуститьОбновление"
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

    [Parameter(Mandatory=$false)]
    [string]$Execute,

    [Parameter(Mandatory=$false)]
    [string]$CParam,

    [Parameter(Mandatory=$false)]
    [string]$URL,

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
$Execute = ConvertTo-CleanPath $Execute '-Execute'

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

# --- Resolve additional arguments ---
# 1C:Enterprise is always launched by 1cv8 — ibcmd has no interactive mode.
$engine = "1cv8"
$argHints = @{ '/F' = '-InfoBasePath'; '/S' = '-InfoBaseServer + -InfoBaseRef'; '/N' = '-UserName'; '/P' = '-Password'; '/Execute' = '-Execute'; '/C' = '-CParam'; '/URL' = '-URL' }
$extraArgs = @(Resolve-ExtraArgs $engine $AdditionalV8Arguments $AdditionalIbcmdArguments $argHints)

function Format-ArgToken {
    # ShellExecute re-joins the argument string, so quote each extra token that needs it.
    param([string]$Token)
    if ($Token -match '[\s"]') { return ' "' + ($Token -replace '"', '\"') + '"' }
    return " $Token"
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

# The display string is built from the same tokens with secret-prone values redacted.
$displayString = $argString
foreach ($tok in $extraArgs) { $argString += (Format-ArgToken $tok) }
foreach ($tok in (Format-ArgsForDisplay $extraArgs $engine)) { $displayString += (Format-ArgToken $tok) }

# --- Execute (background) ---
# Redact the password/user before printing the command line — never leak secrets.
$displayArg = Protect-Secrets $displayString @($Password, $UserName)
Write-Host "Running: 1cv8.exe $displayArg"
$proc = Start-Process -FilePath $V8Path -ArgumentList $argString -PassThru

# --- Bounded early-exit check ---
# The launch is a background GUI process, so we don't wait for completion. But a process
# that dies within the first ~1.5s never really started (bad base, no display, license) —
# report that honestly instead of a blind "launched".
$deadline = (Get-Date).AddMilliseconds(1500)
while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
    Start-Sleep -Milliseconds 200
}
if ($proc.HasExited) {
    Write-Host "Error: 1C:Enterprise exited immediately (code: $($proc.ExitCode))" -ForegroundColor Red
    if ($proc.ExitCode -ne 0) { exit $proc.ExitCode } else { exit 1 }
}
Write-Host "PID: $($proc.Id)"
Write-Host "1C:Enterprise launched" -ForegroundColor Green
