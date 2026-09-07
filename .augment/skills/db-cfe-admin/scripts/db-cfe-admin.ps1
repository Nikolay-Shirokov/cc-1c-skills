# db-cfe-admin v1.0 — Configuration extensions in a 1C infobase: list, check, properties, delete
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: *nix-раскладку платформы (/opt/1cv8/<ver>/1cv8, без .exe) знает только .py-порт — PS на *nix не исполняется.
<#
.SYNOPSIS
    Расширения конфигурации в информационной базе 1С

.DESCRIPTION
    list — что за расширения в базе и в каком они состоянии
    check — применимость и синтаксический контроль
    set-properties — активность, безопасный режим, защита от опасных действий и прочие свойства
    delete — удаление расширения из базы

.PARAMETER Command
    list | check | set-properties | delete

.EXAMPLE
    .\db-cfe-admin.ps1 -Command list -InfoBasePath "C:\Bases\MyDB"

.EXAMPLE
    .\db-cfe-admin.ps1 -Command check -InfoBasePath "C:\Bases\MyDB" -Name "МоёРасширение"

.EXAMPLE
    .\db-cfe-admin.ps1 -Command set-properties -InfoBasePath "C:\Bases\MyDB" -Name "МоёРасширение" -SafeMode "-"
#>

[CmdletBinding(PositionalBinding=$false)]
param(
    # Не Mandatory: обязательный параметр PowerShell запрашивает интерактивно, а в пакетном
    # запуске это зависание. Пустое значение проверяем сами.
    [Parameter(Mandatory=$false)]
    [string]$Command,

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
    [string]$Name,

    [Parameter(Mandatory=$false)]
    [switch]$All,

    [Parameter(Mandatory=$false)]
    [string]$Checks,

    [Parameter(Mandatory=$false)]
    [string]$Context,

    # Тристабильные флаги: on включить, off выключить, не указан — не трогать.
    # Значение "-" через powershell.exe -File парсер съедает молча (проверено), поэтому
    # каноническая форма словесная; "+"/"-" принимаются, но в инструкции не значатся.
    [Parameter(Mandatory=$false)]
    [ValidateSet("on", "off", "yes", "no", "+", "-")]
    [string]$SafeMode,

    [Parameter(Mandatory=$false)]
    [ValidateSet("on", "off", "yes", "no", "+", "-")]
    [string]$Active,

    [Parameter(Mandatory=$false)]
    [ValidateSet("on", "off", "yes", "no", "+", "-")]
    [string]$UnsafeActionProtection,

    [Parameter(Mandatory=$false)]
    [ValidateSet("on", "off", "yes", "no", "+", "-")]
    [string]$UsedInDistributedInfobase,

    [Parameter(Mandatory=$false)]
    [ValidateSet("infobase", "data-separation")]
    [string]$Scope,

    [Parameter(Mandatory=$false)]
    [string]$SecurityProfile,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryPath,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryUser,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryPassword,

    [Parameter(Mandatory=$false)]
    [string[]]$AdditionalV8Arguments = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$AdditionalIbcmdArguments = @()
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Общий блок группы db-*: реквизиты хранилища, дополнительные аргументы, запуск платформы.
# Копии держит одинаковыми tests/skills/check-inline-drift.mjs — правку вносить в навык-эталон.
$Extension = $Name

# --- Реквизиты хранилища из .v8-project.json ---
# Модель их не передаёт: скрипт сопоставляет параметры соединения с записью в databases[]
# и берёт repository оттуда. Тот же приём, что в cf-edit.ps1 (сопоставление по configSrc).
function Find-V8Project([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 20 -and $d; $i++) {
		$pj = Join-Path $d ".v8-project.json"
		if (Test-Path $pj) { return $pj }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return $null
}
function Test-SamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    try {
        $na = [System.IO.Path]::GetFullPath($A).TrimEnd('\', '/')
        $nb = [System.IO.Path]::GetFullPath($B).TrimEnd('\', '/')
        return $na.Equals($nb, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Find-ProjectDatabase {
    # Запись базы в реестре, соответствующая переданному соединению. $null, если не найдена.
    $pf = Find-V8Project (Get-Location).Path
    if (-not $pf) { return $null }
    try { $proj = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $proj.databases) { return $null }
    foreach ($db in $proj.databases) {
        if ($InfoBasePath -and $db.path -and (Test-SamePath $db.path $InfoBasePath)) { return $db }
        if ($InfoBaseServer -and $InfoBaseRef -and $db.server -and $db.ref) {
            if ($db.server.Equals($InfoBaseServer, [System.StringComparison]::OrdinalIgnoreCase) -and
                $db.ref.Equals($InfoBaseRef, [System.StringComparison]::OrdinalIgnoreCase)) { return $db }
        }
    }
    return $null
}

function Resolve-RepositorySettings {
    # Возвращает @{ Path; User; Password; FromRegistry }. Явные -Repository* всегда сильнее реестра.
    $dbRec = Find-ProjectDatabase
    $rec = $null
    if ($dbRec) {
        if ($Extension) {
            # У расширения СВОЁ хранилище со своим путём (проверено): выбирается парой
            # /ConfigurationRepositoryF"<путь расширения>" + -Extension "<Имя>".
            if ($dbRec.extensions) {
                foreach ($ext in $dbRec.extensions) {
                    if ($ext.name -and $ext.name.Equals($Extension, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $rec = $ext.repository
                        break
                    }
                }
            }
        } else {
            $rec = $dbRec.repository
        }
    }
    $path = if ($RepositoryPath) { $RepositoryPath } elseif ($rec -and $rec.path) { [string]$rec.path } else { $null }
    $user = if ($RepositoryUser) { $RepositoryUser } elseif ($rec -and $rec.user) { [string]$rec.user } else { $null }
    # Пустой пароль = отсутствующий: 1С требует опускать ключ целиком, а не передавать пустое значение.
    $pwd  = if ($RepositoryPassword) { $RepositoryPassword } elseif ($rec -and $rec.password) { [string]$rec.password } else { $null }
    return @{
        Path         = if ($path) { $path.Trim().Trim('"') } else { $null }
        User         = $user
        Password     = $pwd
        FromRegistry = [bool]($rec -and $rec.path)
        DbRecord     = $dbRec
    }
}

function Get-RepositoryArgs {
    # Ключи доступа к хранилищу. Форма — кавычки ВНУТРИ токена, как у /N и /P.
    param([hashtable]$Repo)
    $a = @()
    if (-not $Repo -or -not $Repo.Path) { return $a }
    $a += "/ConfigurationRepositoryF`"$($Repo.Path)`""
    if ($Repo.User) { $a += "/ConfigurationRepositoryN`"$($Repo.User)`"" }
    if ($Repo.Password) { $a += "/ConfigurationRepositoryP`"$($Repo.Password)`"" }
    return $a
}

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
# Пакетные команды платформы. В одной командной строке DESIGNER выполняет ТОЛЬКО ПОСЛЕДНЮЮ,
# остальные молча отбрасывает (проверено на 8.3.24: /LoadConfigFromFiles вместе с
# /CheckCanApplyConfigurationExtensions завершились кодом 0 с пустым логом, и загрузка НЕ
# состоялась). Такая команда в дополнительных аргументах подменяет собой операцию навыка, а навык
# отчитывается успехом. Дополнительные аргументы — это опции, а не режимы.
$script:V8BatchKeys = @(
    '/CheckConfig', '/CheckModules', '/CheckCanApplyConfigurationExtensions',
    '/DumpDBCfgList', '/DeleteCfg', '/UpdateCfg', '/CompareCfg', '/MergeCfg',
    '/ManageCfgSupport', '/RollbackCfg', '/ConvertFiles'
)

$script:IbcmdOwnedKeys = @(
    '--db-path', '--data', '--out', '--file', '--load', '--restore',
    '--import', '--export', '--apply', '--force', '--create-database',
    '--user', '--password'
)
$script:V8SecretKeys = @('/P', '/UC', '/WSP', '/AWSP', '/ConfigurationRepositoryP')
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
        if ($Engine -ne 'ibcmd') {
            foreach ($b in $script:V8BatchKeys) {
                if (Test-ArgKeyMatch $tok $b) {
                    Write-Host "Error: $b is a batch command; passed via $paramName it would replace the skill's own operation (a command line runs only its last batch command)" -ForegroundColor Red
                    exit 1
                }
            }
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

# --- Утилиты платформы: нужны обе, выбор по команде ---
# -V8Path указывает на каталог bin либо на любой из двух исполняемых файлов; второй берётся соседом.
$binDir = Split-Path $V8Path -Parent
$exeLeaf = Split-Path $V8Path -Leaf
# Расширение файла сохраняем: на Windows это .exe, на *nix его нет, в тестах — .cmd/.sh.
$exeSuffix = [System.IO.Path]::GetExtension($V8Path)
if ($exeLeaf -match '^ibcmd') {
    $ibcmdExe = $V8Path
    $v8Exe = Join-Path $binDir ("1cv8" + $exeSuffix)
} else {
    $v8Exe = $V8Path
    $ibcmdExe = Join-Path $binDir ("ibcmd" + $exeSuffix)
}
$hasV8 = Test-Path $v8Exe
$hasIbcmd = Test-Path $ibcmdExe

# --- Разбор и проверка команды ---
$knownCommands = @('list', 'check', 'set-properties', 'delete')
$cmd = if ($Command) { $Command.Trim().ToLower() } else { '' }
if (-not $cmd) {
    Write-Host "Error: specify a command: $($knownCommands -join ' | ')" -ForegroundColor Red
    exit 1
}
if ($knownCommands -notcontains $cmd) {
    Write-Host "Error: unknown command '$Command' (expected: $($knownCommands -join ' | '))" -ForegroundColor Red
    exit 1
}

# Пустое имя платформа трактует разрушительно: /DeleteCfg -Extension "" удаляет первое расширение
# из списка и рапортует успех. Поэтому пустое значение не доходит до платформы ни в одной команде.
if ($PSBoundParameters.ContainsKey('Name') -and [string]::IsNullOrWhiteSpace($Name)) {
    Write-Host "Error: -Name is empty; omit it to address all extensions, or pass a name" -ForegroundColor Red
    exit 1
}
$hasName = -not [string]::IsNullOrWhiteSpace($Name)
if ($hasName) { $Name = $Name.Trim() }

if ($All -and $cmd -ne 'delete') {
    Write-Host "Error: -All applies to delete only (list and check address all extensions when -Name is omitted)" -ForegroundColor Red
    exit 1
}
if ($cmd -eq 'delete') {
    if ($hasName -and $All) {
        Write-Host "Error: -Name and -All are mutually exclusive - pass one or the other" -ForegroundColor Red
        exit 1
    }
    if (-not $hasName -and -not $All) {
        Write-Host "Error: specify -Name <extension> or -All (an omitted name never means all)" -ForegroundColor Red
        exit 1
    }
}
if ($cmd -eq 'set-properties' -and -not $hasName) {
    Write-Host "Error: set-properties needs -Name <extension>" -ForegroundColor Red
    exit 1
}

# --- Проверки (-Checks) и контексты (-Context) ---
$knownChecks = @('apply', 'modules', 'config')
$checkList = @()
if ($Checks) {
    $checkList = @($Checks -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    foreach ($c in $checkList) {
        if ($knownChecks -notcontains $c) {
            Write-Host "Error: unknown check '$c' (expected: $($knownChecks -join ', '))" -ForegroundColor Red
            exit 1
        }
    }
}
if ($checkList.Count -eq 0) { $checkList = @('apply', 'modules') }

$knownContexts = @('ThinClient', 'WebClient', 'MobileClient', 'MobileClientStandalone', 'MobileAppClient',
    'Server', 'MobileAppServer', 'ExternalConnection', 'ExternalConnectionServer',
    'ThickClientManagedApplication', 'ThickClientServerManagedApplication',
    'ThickClientOrdinaryApplication', 'ThickClientServerOrdinaryApplication')
$contextList = @()
if ($Context) {
    foreach ($c in @($Context -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $match = $knownContexts | Where-Object { $_.Equals($c, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if (-not $match) {
            Write-Host "Error: unknown context '$c' (expected: $($knownContexts -join ', '))" -ForegroundColor Red
            exit 1
        }
        $contextList += $match
    }
}
if ($Context -and $checkList.Count -gt 0 -and $checkList -notcontains 'modules') {
    Write-Host "Error: -Context applies to the syntax check - add 'modules' to -Checks" -ForegroundColor Red
    exit 1
}
if ($contextList.Count -eq 0) { $contextList = @('ThinClient', 'Server') }

# --- Свойства для set-properties ---
$script:propRu = @{
    'safe-mode' = 'безопасный режим'
    'active' = 'активно'
    'unsafe-action-protection' = 'защита от опасных действий'
    'used-in-distributed-infobase' = 'используется в РИБ'
    'scope' = 'область действия'
    'security-profile-name' = 'профиль безопасности'
    'purpose' = 'назначение'
    'version' = 'версия'
}
function Get-PropRu {
    param([string]$Key)
    if ($script:propRu.ContainsKey($Key)) { return $script:propRu[$Key] }
    return $Key
}

function Convert-FlagValue {
    param([string]$Value)
    if (@('on', 'yes', '+') -contains $Value.ToLower()) { return 'yes' }
    return 'no'
}

$propFlags = [ordered]@{}
if ($SafeMode) { $propFlags['safe-mode'] = (Convert-FlagValue $SafeMode) }
if ($Active) { $propFlags['active'] = (Convert-FlagValue $Active) }
if ($UnsafeActionProtection) { $propFlags['unsafe-action-protection'] = (Convert-FlagValue $UnsafeActionProtection) }
if ($UsedInDistributedInfobase) { $propFlags['used-in-distributed-infobase'] = (Convert-FlagValue $UsedInDistributedInfobase) }
if ($Scope) { $propFlags['scope'] = $Scope }
if ($PSBoundParameters.ContainsKey('SecurityProfile')) { $propFlags['security-profile-name'] = $SecurityProfile }
if ($cmd -eq 'set-properties' -and $propFlags.Count -eq 0) {
    Write-Host "Error: set-properties needs at least one property (-SafeMode, -Active, -UnsafeActionProtection, -UsedInDistributedInfobase, -Scope, -SecurityProfile)" -ForegroundColor Red
    exit 1
}

# --- Соединение ---
if (-not $InfoBasePath -and (-not $InfoBaseServer -or -not $InfoBaseRef)) {
    Write-Host "Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef" -ForegroundColor Red
    exit 1
}

# --- Дополнительные аргументы: у каждой утилиты свои ---
$argHints = @{ '/F' = '-InfoBasePath'; '/S' = '-InfoBaseServer + -InfoBaseRef'; '/N' = '-UserName'; '/P' = '-Password'; '--db-path' = '-InfoBasePath'; '--user' = '-UserName'; '--password' = '-Password' }
$v8Extra = @(Resolve-ExtraArgs '1cv8' $AdditionalV8Arguments @() $argHints)
$ibExtra = @(Resolve-ExtraArgs 'ibcmd' @() $AdditionalIbcmdArguments $argHints)
if ($AdditionalIbcmdArguments.Count -gt 0 -and @('check', 'delete') -contains $cmd) {
    Write-Host "Error: -AdditionalIbcmdArguments does not apply to '$cmd' - it runs the Designer only" -ForegroundColor Red
    exit 1
}

$script:repoSettings = Resolve-RepositorySettings
$baseLabel = if ($InfoBasePath) { $InfoBasePath } else { "$InfoBaseServer/$InfoBaseRef" }

# --- Запуск Конфигуратора: соединение, реквизиты хранилища и /Out навык держит сам ---
function Invoke-Designer {
    param([string[]]$OpArgs)
    if (-not $hasV8) {
        Write-Host "Error: 1C executable not found at $v8Exe" -ForegroundColor Red
        exit 1
    }
    $tempDir = Join-Path $env:TEMP "db_cfe_admin_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $arguments = @("DESIGNER")
        if ($InfoBaseServer -and $InfoBaseRef) {
            $arguments += "/S", "`"$InfoBaseServer/$InfoBaseRef`""
        } else {
            $arguments += "/F", "`"$InfoBasePath`""
        }
        if ($UserName) { $arguments += "/N`"$UserName`"" }
        if ($Password) { $arguments += "/P`"$Password`"" }
        # База под хранилищем не примет НИ ОДНОЙ операции конфигуратора без этих реквизитов.
        $arguments += Get-RepositoryArgs $script:repoSettings
        $arguments += $OpArgs
        $outFile = Join-Path $tempDir "out.txt"
        $arguments += "/Out", "`"$outFile`""
        $arguments += "/DisableStartupDialogs"
        $arguments += $v8Extra
        Write-Host "Running: 1cv8.exe $(Protect-Secrets ((Format-ArgsForDisplay $arguments '1cv8') -join ' ') @($Password, $UserName, $script:repoSettings.Password))"
        $res = Invoke-PlatformProcess $v8Exe $arguments -PreQuoted
        $log = ''
        if (Test-Path $outFile) {
            $raw = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
            if ($raw) { $log = $raw.Trim() }
        }
        return @{
            ExitCode = $res.ExitCode
            Log      = $log
            Output   = $res.Output
        }
    } finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Ibcmd {
    param([string[]]$OpArgs)
    $arguments = @($OpArgs)
    $arguments += "--db-path=$InfoBasePath"
    if ($UserName) { $arguments += "--user=$UserName" }
    if ($Password) { $arguments += "--password=$Password" }
    $arguments += $ibExtra
    Write-Host "Running: ibcmd $(Protect-Secrets ((Format-ArgsForDisplay $arguments 'ibcmd') -join ' ') @($Password, $UserName))"
    $res = Invoke-PlatformProcess $ibcmdExe $arguments
    return @{ ExitCode = $res.ExitCode; Output = $res.Output }
}

function Write-PlatformFailure {
    # Единый разбор неуспеха: что запускали, чем ответила платформа.
    param($Result, [string]$What)
    Write-Host "Error: $What (code: $($Result.ExitCode))$(Get-ExitAnnotation $Result.ExitCode)" -ForegroundColor Red
    if ($Result.Log) {
        Write-Host "--- Log ---"
        Write-Host $Result.Log
        Write-Host "--- End ---"
    }
    Write-PlatformOutput $Result.Output
}

# --- Свойства расширений: только ibcmd, и только для файловой базы ---
function Get-PropertiesUnavailableReason {
    if (-not $InfoBasePath) { return "свойства читает ibcmd, а он подключается к файловой базе (--db-path)" }
    if (-not $hasIbcmd) { return "рядом с 1cv8 нет ibcmd ($ibcmdExe) - эта установка платформы его не содержит" }
    return $null
}

function ConvertFrom-IbcmdRecords {
    # Вывод ibcmd: строки «ключ : значение», записи разделены пустой строкой.
    param([string]$Text)
    $records = @()
    $cur = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($cur.Count -gt 0) { $records += ,$cur; $cur = [ordered]@{} }
            continue
        }
        $idx = $line.IndexOf(':')
        if ($idx -lt 0) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim().Trim('"')
        if ($key) { $cur[$key] = $val }
    }
    if ($cur.Count -gt 0) { $records += ,$cur }
    return $records
}

function Get-ExtensionProperties {
    # Хеш «имя расширения» -> запись свойств. Пустой, если ibcmd недоступен.
    if (Get-PropertiesUnavailableReason) { return @{} }
    $r = Invoke-Ibcmd @('infobase', 'config', 'extension', 'list')
    if ($r.ExitCode -ne 0) { return @{} }
    $map = @{}
    foreach ($rec in (ConvertFrom-IbcmdRecords $r.Output)) {
        if ($rec['name']) { $map[[string]$rec['name']] = $rec }
    }
    return $map
}

function Get-ExtensionNames {
    # Имена расширений базы - Конфигуратором, чтобы работало и без ibcmd, и на серверной базе.
    $r = Invoke-Designer @('/DumpDBCfgList', '-AllExtensions')
    if ($r.ExitCode -ne 0) {
        Write-PlatformFailure $r "cannot list extensions"
        exit 1
    }
    return @($r.Log -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- Человекочитаемые значения свойств ---
$script:flagRu = @{ 'yes' = 'да'; 'no' = 'нет' }
$script:scopeRu = @{ 'infobase' = 'Информационная база'; 'data-separation' = 'Область данных' }
$script:purposeRu = @{ 'customization' = 'Адаптация'; 'add-on' = 'Дополнение'; 'patch' = 'Исправление' }

function Format-PropValue {
    param([string]$Key, $Value)
    if ($null -eq $Value -or $Value -eq '') { return '' }
    $v = [string]$Value
    if ($Key -eq 'scope' -and $script:scopeRu.ContainsKey($v)) { return $script:scopeRu[$v] }
    if ($Key -eq 'purpose' -and $script:purposeRu.ContainsKey($v)) { return $script:purposeRu[$v] }
    if ($script:flagRu.ContainsKey($v)) { return $script:flagRu[$v] }
    return $v
}

function Get-PropCell {
    # Значение свойства для таблицы: «—», когда свойства вообще не читались.
    param($Record, [string]$Key)
    if (-not $Record) { return '—' }
    if ($Record[$Key]) { return (Format-PropValue $Key $Record[$Key]) }
    return ''
}

function Write-Table {
    param([string[]]$Headers, $Rows)
    $widths = @()
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $w = $Headers[$i].Length
        foreach ($row in $Rows) { if (([string]$row[$i]).Length -gt $w) { $w = ([string]$row[$i]).Length } }
        $widths += $w
    }
    $line = '  '
    for ($i = 0; $i -lt $Headers.Count; $i++) { $line += $Headers[$i].PadRight($widths[$i] + 2) }
    Write-Host $line.TrimEnd()
    foreach ($row in $Rows) {
        $l = '  '
        for ($i = 0; $i -lt $Headers.Count; $i++) { $l += ([string]$row[$i]).PadRight($widths[$i] + 2) }
        Write-Host $l.TrimEnd()
    }
}

# ============================================================================
# Команды
# ============================================================================

if ($cmd -eq 'list') {
    $names = @(Get-ExtensionNames)
    if ($hasName) {
        $names = @($names | Where-Object { $_.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($names.Count -eq 0) {
            Write-Host "[РАСШИРЕНИЯ] $baseLabel   (0)"
            Write-Host "  расширение '$Name' в базе не найдено"
            exit 1
        }
    }
    Write-Host "[РАСШИРЕНИЯ] $baseLabel   ($($names.Count))"
    if ($names.Count -eq 0) {
        Write-Host "  расширений нет"
        exit 0
    }
    $props = Get-ExtensionProperties
    $reason = Get-PropertiesUnavailableReason
    $rows = @()
    foreach ($n in $names) {
        $rec = $props[$n]
        $rows += ,@($n,
            (Get-PropCell $rec 'purpose'),
            (Get-PropCell $rec 'active'),
            (Get-PropCell $rec 'safe-mode'),
            (Get-PropCell $rec 'unsafe-action-protection'),
            (Get-PropCell $rec 'used-in-distributed-infobase'),
            (Get-PropCell $rec 'scope'))
    }
    Write-Table @('Имя', 'Назначение', 'Активно', 'Безопасный режим', 'Защита', 'РИБ', 'Область') $rows
    if ($reason) { Write-Host "  свойства недоступны: $reason" }
    exit 0
}

if ($cmd -eq 'check') {
    # Список расширений заранее не запрашиваем: платформа сама отвечает «расширение не найдено»,
    # а лишний запуск конфигуратора стоит дороже, чем разница в формулировке.
    $target = if ($hasName) { $Name } else { $null }
    if ($target) {
        Write-Host "[ПРОВЕРКА] $baseLabel · $target"
    } else {
        Write-Host "[ПРОВЕРКА] $baseLabel · все расширения"
    }

    $failed = 0
    $done = 0
    $rows = @()

    # Тот же вопрос платформе задаёт постусловие загрузчиков (семья Invoke-ApplyCheck в
    # db-load-xml): там ответ нужен одной строкой предупреждения, здесь — строкой отчёта
    # рядом с остальными проверками, поэтому запуск идёт своим Invoke-Designer.
    if ($checkList -contains 'apply') {
        $opArgs = @('/CheckCanApplyConfigurationExtensions')
        if ($target) { $opArgs += '-Extension', "`"$target`"" }
        $r = Invoke-Designer $opArgs
        $done++
        $logLines = @($r.Log -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($r.ExitCode -eq 0) {
            $rows += ,@{ Label = 'применимость'; Status = 'ОК'; Note = ''; Lines = @() }
        } elseif ($r.ExitCode -eq 1) {
            $failed++
            $rows += ,@{ Label = 'применимость'; Status = 'ОШИБКА'; Note = ''; Lines = $logLines }
        } else {
            $failed++
            $rows += ,@{ Label = 'применимость'; Status = 'СБОЙ'; Note = "код $($r.ExitCode)$(Get-ExitAnnotation $r.ExitCode)"; Lines = $logLines }
        }
    }

    # modules и config - одна и та же команда платформы с разным набором флагов, поэтому при
    # запросе обеих делается ОДИН запуск. Без флагов контекста платформа рапортует «ошибок не
    # обнаружено» на заведомо сломанном модуле - набор всегда явный.
    $wantModules = $checkList -contains 'modules'
    $wantConfig = $checkList -contains 'config'
    if ($wantModules -or $wantConfig) {
        $opArgs = @('/CheckConfig')
        if ($wantModules) { foreach ($c in $contextList) { $opArgs += "-$c" } }
        if ($wantConfig) {
            $opArgs += '-ConfigLogIntegrity', '-IncorrectReferences', '-UnreferenceProcedures', '-HandlersExistence', '-EmptyHandlers'
        }
        if ($target) { $opArgs += '-Extension', "`"$target`"" } else { $opArgs += '-AllExtensions' }
        $r = Invoke-Designer $opArgs
        $label = if ($wantModules -and $wantConfig) { 'модули и конфигурация' } elseif ($wantModules) { 'модули' } else { 'конфигурация' }
        $done++
        $logLines = @($r.Log -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($r.ExitCode -eq 0) {
            $note = if ($wantModules) { "($($contextList -join ', '))" } else { '' }
            $rows += ,@{ Label = $label; Status = 'ОК'; Note = $note; Lines = @() }
        } elseif ($r.ExitCode -eq 1 -or $r.ExitCode -eq 101) {
            $failed++
            $rows += ,@{ Label = $label; Status = 'ОШИБКА'; Note = ''; Lines = $logLines }
        } else {
            $failed++
            $rows += ,@{ Label = $label; Status = 'СБОЙ'; Note = "код $($r.ExitCode)$(Get-ExitAnnotation $r.ExitCode)"; Lines = $logLines }
        }
    }

    # Сообщения платформы печатаются построчно под своей проверкой: они называют расширение и
    # место ошибки, и при нескольких расширениях склейка в одну строку нечитаема.
    $w = 0
    foreach ($row in $rows) { if ($row.Label.Length -gt $w) { $w = $row.Label.Length } }
    foreach ($row in $rows) {
        $l = '  ' + $row.Label.PadRight($w + 2) + $row.Status.PadRight(9)
        if ($row.Note) { $l += $row.Note }
        Write-Host $l.TrimEnd()
        foreach ($line in $row.Lines) { Write-Host ("      " + $line.Trim()) }
    }
    if ($failed -gt 0) {
        Write-Host "Итог: провалено $failed из $done"
        exit 1
    }
    Write-Host "Итог: пройдено $done из $done"
    exit 0
}

if ($cmd -eq 'set-properties') {
    $reason = Get-PropertiesUnavailableReason
    if ($reason) {
        Write-Host "Error: cannot set properties - $reason" -ForegroundColor Red
        exit 1
    }
    $before = Get-ExtensionProperties
    if (-not $before.ContainsKey($Name)) {
        Write-Host "Error: extension '$Name' not found in the infobase" -ForegroundColor Red
        exit 1
    }
    $opArgs = @('infobase', 'config', 'extension', 'update', "--name=$Name")
    foreach ($k in $propFlags.Keys) { $opArgs += "--$k=$($propFlags[$k])" }
    $r = Invoke-Ibcmd $opArgs
    if ($r.ExitCode -ne 0) {
        Write-Host "Error: cannot set properties (code: $($r.ExitCode))$(Get-ExitAnnotation $r.ExitCode)" -ForegroundColor Red
        Write-PlatformOutput $r.Output
        exit 1
    }
    # Постусловие: состояние перечитывается, а не берётся из кода возврата.
    $after = Get-ExtensionProperties
    if (-not $after.ContainsKey($Name)) {
        Write-Host "Error: extension '$Name' disappeared after the update" -ForegroundColor Red
        exit 1
    }
    Write-Host "[СВОЙСТВА] $baseLabel · $Name"
    $changed = 0
    $stale = @()
    foreach ($k in $propFlags.Keys) {
        $was = Format-PropValue $k $before[$Name][$k]
        $now = Format-PropValue $k $after[$Name][$k]
        $want = Format-PropValue $k $propFlags[$k]
        if ($was -ne $now) {
            Write-Host ('  ' + (Get-PropRu $k).PadRight(30) + "$was → $now")
            $changed++
        } elseif ($now -ne $want) {
            $stale += "$(Get-PropRu $k): просили '$want', в базе осталось '$now'"
        }
    }
    if ($stale.Count -gt 0) {
        foreach ($s in $stale) { Write-Host "  $s" -ForegroundColor Yellow }
        Write-Host "Итог: изменено $changed, не применено $($stale.Count)"
        exit 1
    }
    if ($changed -eq 0) { Write-Host "  свойства уже в этом состоянии" }
    Write-Host "Итог: изменено $changed"
    exit 0
}

if ($cmd -eq 'delete') {
    $names = @(Get-ExtensionNames)
    if ($names.Count -eq 0) {
        Write-Host "[УДАЛЕНИЕ] $baseLabel"
        Write-Host "  расширений нет - удалять нечего"
        exit 0
    }
    $targets = @()
    if ($hasName) {
        $match = @($names | Where-Object { $_.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($match.Count -eq 0) {
            Write-Host "Error: extension '$Name' not found in the infobase" -ForegroundColor Red
            exit 1
        }
        $targets = $match
    } else {
        $targets = $names
    }
    Write-Host "[УДАЛЕНИЕ] $baseLabel   (будет удалено: $($targets.Count))"
    foreach ($t in $targets) {
        # Имя непустое по построению: пустое отбито разбором параметров, список получен от платформы.
        $r = Invoke-Designer @('/DeleteCfg', '-Extension', "`"$t`"")
        if ($r.ExitCode -ne 0) {
            Write-PlatformFailure $r "cannot delete extension '$t'"
            exit 1
        }
        Write-Host "  удалено: $t"
    }
    # Постусловие: список перечитывается - код возврата платформы сам по себе ничего не доказывает.
    $rest = @(Get-ExtensionNames)
    foreach ($t in $targets) {
        if ($rest | Where-Object { $_.Equals($t, [System.StringComparison]::OrdinalIgnoreCase) }) {
            Write-Host "Error: platform reported success, but '$t' is still in the infobase" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "Итог: удалено $($targets.Count), осталось $($rest.Count)"
    exit 0
}
