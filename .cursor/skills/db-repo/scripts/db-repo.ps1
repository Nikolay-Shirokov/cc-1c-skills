# db-repo v1.14 — 1C configuration repository operations
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: движок только 1cv8 — ibcmd работу с хранилищем не поддерживает (нет такого режима).
<#
.SYNOPSIS
    Работа с хранилищем конфигурации 1С

.DESCRIPTION
    Захват и помещение объектов, получение изменений, подключение базы к хранилищу,
    история версий, администрирование хранилища.

.PARAMETER Command
    Подкоманда: lock, unlock, commit, update, connect, disconnect, report, dump-cfg,
    create, add-user, copy-users, set-label, optimize, clear-cache

.PARAMETER Objects
    Список объектов через запятую: "Справочник.Номенклатура,Документ.Заказ"

.PARAMETER ObjectsFile
    Путь к файлу со списком объектов (одно имя на строку)

.PARAMETER WithChildren
    Захватывать объект вместе с подчинёнными (формы, макеты, команды)

.EXAMPLE
    .\db-repo.ps1 -Command lock -InfoBasePath "C:\Bases\MyDB" -Objects "Справочник.Номенклатура"

.EXAMPLE
    .\db-repo.ps1 -Command commit -InfoBasePath "C:\Bases\MyDB" -Objects "Справочник.Номенклатура" -Comment "Артикул"
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
    [string]$RepositoryPath,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryUser,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryPassword,

    [Parameter(Mandatory=$false)]
    [string]$Extension,

    [Parameter(Mandatory=$false)]
    [string]$Objects,

    [Parameter(Mandatory=$false)]
    [string]$ObjectsFile,

    [Parameter(Mandatory=$false)]
    [switch]$WithChildren,

    # Операция над ВСЕЙ конфигурацией. Отдельный флаг, а не умолчание при забытом -Objects:
    # захват всей конфигурации на большой базе идёт долго и блокирует работу всей команде.
    [Parameter(Mandatory=$false)]
    [switch]$All,

    [Parameter(Mandatory=$false)]
    [string]$Comment,

    [Parameter(Mandatory=$false)]
    [switch]$KeepLocked,

    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [switch]$Revised,

    [Parameter(Mandatory=$false)]
    [string]$Version,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    # --- report ---
    [Parameter(Mandatory=$false)]
    [string]$NBegin,

    [Parameter(Mandatory=$false)]
    [string]$NEnd,

    [Parameter(Mandatory=$false)]
    [string]$DateBegin,

    [Parameter(Mandatory=$false)]
    [string]$DateEnd,

    [Parameter(Mandatory=$false)]
    [switch]$GroupByObject,

    [Parameter(Mandatory=$false)]
    [switch]$GroupByComment,

    [Parameter(Mandatory=$false)]
    [ValidateSet("txt", "mxl")]
    [string]$ReportFormat = "txt",

    # --- users ---
    [Parameter(Mandatory=$false)]
    [string]$NewUser,

    [Parameter(Mandatory=$false)]
    [string]$NewUserPassword,

    [Parameter(Mandatory=$false)]
    [ValidateSet("ReadOnly", "LockObjects", "ManageConfigurationVersions", "Administration")]
    [string]$Rights,

    [Parameter(Mandatory=$false)]
    [switch]$RestoreDeletedUser,

    [Parameter(Mandatory=$false)]
    [string]$SourcePath,

    [Parameter(Mandatory=$false)]
    [string]$SourceUser,

    [Parameter(Mandatory=$false)]
    [string]$SourcePassword,

    # --- create / connect ---
    [Parameter(Mandatory=$false)]
    [switch]$NoBind,

    [Parameter(Mandatory=$false)]
    [switch]$AllowConfigurationChanges,

    [Parameter(Mandatory=$false)]
    [ValidateSet("ObjectNotEditable", "ObjectIsEditableSupportEnabled", "ObjectNotSupported")]
    [string]$ChangesAllowedRule,

    [Parameter(Mandatory=$false)]
    [ValidateSet("ObjectNotEditable", "ObjectIsEditableSupportEnabled", "ObjectNotSupported")]
    [string]$ChangesNotRecommendedRule,

    [Parameter(Mandatory=$false)]
    [switch]$ForceReplaceCfg,

    [Parameter(Mandatory=$false)]
    [switch]$ForceBindAlreadyBindedUser,

    [Parameter(Mandatory=$false)]
    [string]$Label,

    [Parameter(Mandatory=$false)]
    [ValidateSet("local", "global", "db")]
    [string]$CacheScope = "local",

    [Parameter(Mandatory=$false)]
    [string[]]$AdditionalV8Arguments = @()
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

# --- Platform output decoding ---
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


# --- Additional platform arguments ---
# Свои ключи: доп. аргументами нельзя ни подсунуть вторую пакетную операцию, ни подменить
# реквизиты хранилища. Список команд перечислен поимённо — Test-ArgKeyMatch считает совпадением
# только точное имя или имя с не-буквой следом, поэтому общий префикс ключи не покрыл бы.
$script:V8OwnedKeys = @(
    'DESIGNER', 'ENTERPRISE', 'CREATEINFOBASE', 'CONFIG',
    '/F', '/S', '/N', '/P', '/Out', '/DisableStartupDialogs', '/DisableStartupMessages',
    '/ConfigurationRepositoryF', '/ConfigurationRepositoryN', '/ConfigurationRepositoryP',
    '/ConfigurationRepositoryLock', '/ConfigurationRepositoryUnlock',
    '/ConfigurationRepositoryCommit', '/ConfigurationRepositoryUpdateCfg',
    '/ConfigurationRepositoryBindCfg', '/ConfigurationRepositoryUnbindCfg',
    '/ConfigurationRepositoryDumpCfg', '/ConfigurationRepositoryReport',
    '/ConfigurationRepositoryCreate', '/ConfigurationRepositoryAddUser',
    '/ConfigurationRepositoryCopyUsers', '/ConfigurationRepositorySetLabel',
    '/ConfigurationRepositoryOptimizeData', '/ConfigurationRepositoryClearCache',
    '/ConfigurationRepositoryClearLocalCache', '/ConfigurationRepositoryClearGlobalCache'
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

$script:IbcmdOwnedKeys = @()
$script:V8SecretKeys = @('/P', '/UC', '/WSP', '/AWSP', '/ConfigurationRepositoryP', '-Pwd')
$script:IbcmdSecretKeys = @()

# Известные ключи хранилища — всё, что начинается с /ConfigurationRepository и не совпало с ними,
# это опечатка или усечение. Отдельная проверка нужна потому, что усечённый ключ платформа НЕ
# считает ошибкой: она открывает конфигуратор интерактивно и висит вечно (в /Out только BOM).
$script:RepoKnownKeys = @($script:V8OwnedKeys | Where-Object { $_ -like '/ConfigurationRepository*' })

function Assert-NoTruncatedRepoKeys {
    param([string[]]$ArgList)
    foreach ($tok in $ArgList) {
        if (-not $tok.StartsWith('/ConfigurationRepository', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $ok = $false
        foreach ($k in $script:RepoKnownKeys) { if (Test-ArgKeyMatch $tok $k) { $ok = $true; break } }
        if (-not $ok) {
            Write-Host "Error: unknown configuration repository key '$tok' — the platform would open the Designer interactively and hang instead of failing" -ForegroundColor Red
            exit 1
        }
    }
}

function Resolve-ExtraArgs {
    # Движок только 1cv8, поэтому ветки ibcmd (в остальных db-* она есть) здесь нет.
    param([string[]]$V8Extra, [hashtable]$Hints)
    # powershell.exe -File — how skills are invoked — cannot bind an array parameter:
    # space-separated values spill into positional ones, a comma-joined list arrives as a
    # single token. So accept the repo's list convention (comma-separated) and split here.
    $V8Extra = @($V8Extra | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
    $extra = @(Get-ProjectExtraArgs 'v8args') + @($V8Extra)
    if ($extra.Count -gt 0) {
        Assert-ExtraArgs $extra '1cv8' $Hints
        Assert-NoTruncatedRepoKeys $extra
    }
    return $extra
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

# --- Список объектов ---
# Наружу — один формат: плоский список имён, как у db-dump-xml -Mode Partial -Objects.
# Платформенный XML (http://v8.1c.ru/8.3/config/objects) генерируется здесь и модели не показывается.
#
# Нормализовать имена не нужно: платформа принимает и русские, и английские имена типов
# (Catalog.Склады → «Объект захвачен: Справочник.Склады») и подчинённые пути в обеих раскладках.
$script:ConfigRootAliases = @('Конфигурация', 'Configuration')

function ConvertTo-XmlAttr {
    param([string]$Value)
    return $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-RequestedObjects {
    # Плоский список имён из -Objects и/или -ObjectsFile. Пустой список = вся конфигурация.
    $list = @()
    if ($Objects) {
        $list += @($Objects -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($ObjectsFile) {
        if (-not (Test-Path $ObjectsFile)) {
            Write-Host "Error: -ObjectsFile not found: $ObjectsFile" -ForegroundColor Red
            exit 1
        }
        $lines = [System.IO.File]::ReadAllLines($ObjectsFile, [System.Text.Encoding]::UTF8)
        $list += @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    return @($list | Select-Object -Unique)
}

# Подчинённые сущности, которые НЕ являются объектами хранилища: в XML владельца они записаны
# вложенным определением, своего файла и UUID у них нет — захватывать нечего. Отдельными объектами
# регистрируются только те, кто записан ССЫЛКОЙ по имени: форма, макет, команда.
# Платформа на такой запрос отвечает «Загруженный список объектов пуст» — без имени и без причины.
$script:InlineChildKinds = @(
    'Реквизит', 'Attribute',
    'СтандартныйРеквизит', 'StandardAttribute',
    'РеквизитАдресации', 'AddressingAttribute',
    'ТабличнаяЧасть', 'TabularSection',
    'Измерение', 'Dimension',
    'Ресурс', 'Resource',
    'Графа', 'Column',
    'ЗначениеПеречисления', 'EnumValue',
    'ПризнакУчета', 'ПризнакУчёта', 'AccountingFlag',
    'ПризнакУчетаСубконто', 'ПризнакУчётаСубконто', 'ExtDimensionAccountingFlag'
)

function Resolve-LockableObjects {
    # Заменяет части объекта на сам объект. Это не сужение и не расширение запроса: владелец —
    # минимально возможная единица захвата для того, что просили.
    param([string[]]$Names)
    $out = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Names) {
        $segs = $n -split '\.'
        $resolved = $n
        if ($segs.Count -ge 3 -and $script:InlineChildKinds -contains $segs[2]) {
            $resolved = "$($segs[0]).$($segs[1])"
            $notes.Add("$n -> $resolved")
        }
        if (-not $out.Contains($resolved)) { $out.Add($resolved) }
    }
    if ($notes.Count -gt 0) {
        Write-Host "[note] части объекта отдельно не захватываются — взят объект-владелец:" -ForegroundColor Yellow
        foreach ($x in $notes) { Write-Host "  $x" -ForegroundColor Yellow }
    }
    return $out.ToArray()
}

function New-ObjectsListXml {
    # Пишет платформенный XML со списком объектов, возвращает путь к файлу.
    param([string[]]$Names, [string]$Path)
    $child = if ($WithChildren) { 'true' } else { 'false' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<Objects xmlns="http://v8.1c.ru/8.3/config/objects" version="1.0">')
    foreach ($n in $Names) {
        if ($script:ConfigRootAliases -contains $n) {
            # Корень конфигурации — отдельный элемент. Нужен, чтобы добавить или удалить объект:
            # без захвата корня частичная загрузка нового объекта не проходит.
            [void]$sb.AppendLine("    <Configuration includeChildObjects=`"$child`"/>")
            continue
        }
        $esc = ConvertTo-XmlAttr $n
        $isSubsystem = $n -match '^(Подсистема|Subsystem)\.'
        if ($isSubsystem -and $WithChildren) {
            # includeChildObjects у подсистемы означает вложенные ПОДСИСТЕМЫ, а её состав
            # подтягивает только вложенный <Subsystem> — поэтому под -WithChildren нужны оба.
            [void]$sb.AppendLine("    <Object fullName=`"$esc`" includeChildObjects=`"true`">")
            [void]$sb.AppendLine("        <Subsystem includeObjectsFromSubordinateSubsystems=`"true`"/>")
            [void]$sb.AppendLine("    </Object>")
        } else {
            [void]$sb.AppendLine("    <Object fullName=`"$esc`" includeChildObjects=`"$child`"/>")
        }
    }
    [void]$sb.AppendLine('</Objects>')
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $utf8Bom)
    return $Path
}

# --- Разбор лога операции ---
# Платформа отчитывается ПОСТРОЧНО, и код возврата про фактический результат не говорит:
# захват не атомарен (код 1 при реально захваченном объекте), а все no-op'ы дают код 0.
function Read-RepoLog {
    param([string]$LogText)
    $r = @{
        Locked = @(); LockedByOther = @(); Received = @(); Committed = @()
        Unchanged = @(); Unlocked = @(); NotLocked = @(); Modified = @(); Missing = @()
        HasOperationBlock = $false; Raw = $LogText
    }
    if (-not $LogText) { return $r }
    $inMissing = $false
    foreach ($rawLine in ($LogText -split "`r?`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { $inMissing = $false; continue }
        if ($line -match '^-+\s*Начало операции с хранилищем') { $r.HasOperationBlock = $true; $inMissing = $false; continue }
        if ($line -match '^-+\s*Операция с хранилищем') { $inMissing = $false; continue }
        if ($line -match '^Объекты, отсутствующие в обеих конфигурациях') { $inMissing = $true; continue }
        if ($inMissing) { $r.Missing += $line; continue }
        if ($line -match '^Объект захвачен для редактирования другим пользователем:\s*(.+?)\s*\((.+?)\)\s*$') {
            $r.LockedByOther += [pscustomobject]@{ Name = $Matches[1]; Holder = $Matches[2] }
        }
        elseif ($line -match '^Объект захвачен для редактирования:\s*(.+)$') { $r.Locked += $Matches[1].Trim() }
        elseif ($line -match '^Объект получен из хранилища:\s*(.+)$')        { $r.Received += $Matches[1].Trim() }
        elseif ($line -match '^Объект помещен в хранилище:\s*(.+)$')         { $r.Committed += $Matches[1].Trim() }
        elseif ($line -match '^Объект не был изменен:\s*(.+)$')              { $r.Unchanged += $Matches[1].Trim() }
        elseif ($line -match '^Захват объекта отменен:\s*(.+)$')             { $r.Unlocked += $Matches[1].Trim() }
        elseif ($line -match '^Объект не захвачен для редактирования:\s*(.+)$') { $r.NotLocked += $Matches[1].Trim() }
        elseif ($line -match "^Объект '(.+?)' был изменен")                  { $r.Modified += $Matches[1] }
    }
    return $r
}

# --- Полученные объекты → готовая команда перевыгрузки ---
# Захват и обновление МОЛЧА подтягивают свежие версии в локальную конфигурацию. Если после этого
# загрузить старые исходники, чужие изменения откатятся без единой ошибки. Выгрузку не делаем сами
# (она затрёт локальные правки) — печатаем готовую команду.
function Get-OwnerObjects {
    param([string[]]$Names)
    $owners = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Names) {
        $parts = $n -split '\.'
        if ($parts.Count -eq 1) { continue }   # корень конфигурации: частично по имени не выгружается
        $owner = if ($parts.Count -gt 2) { "$($parts[0]).$($parts[1])" } else { $n }
        if (-not $owners.Contains($owner)) { $owners.Add($owner) }
    }
    return @($owners)
}

function Write-ReceivedWarning {
    param([string[]]$Received)
    if (-not $Received -or $Received.Count -eq 0) { return }
    Write-Host ""
    Write-Host "[warning] локальная конфигурация изменена, получено объектов из хранилища: $($Received.Count)" -ForegroundColor Yellow
    $recvLimit = [Math]::Min($Received.Count, $script:ListLimit)
    foreach ($n in $Received[0..($recvLimit - 1)]) { Write-Host "  $n" -ForegroundColor Yellow }
    if ($Received.Count -gt $script:ListLimit) {
        Write-Host "  … и ещё $($Received.Count - $script:ListLimit)" -ForegroundColor Yellow
    }
    $owners = Get-OwnerObjects $Received
    $hasRoot = @($Received | Where-Object { ($_ -split '\.').Count -eq 1 }).Count -gt 0
    if ($owners.Count -gt 0) {
        $listPath = Join-Path $env:TEMP "db-repo-received.txt"
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllLines($listPath, $owners, $utf8Bom)
        Write-Host "Исходники в проекте устарели по этим объектам. Перевыгрузите их ПЕРЕД правкой," -ForegroundColor Yellow
        Write-Host "иначе частичная загрузка старых исходников молча откатит чужие изменения:" -ForegroundColor Yellow
        Write-Host "  /db-dump-xml <база> <каталог> -Mode Partial -ObjectsFile `"$listPath`""
    }
    if ($hasRoot) {
        Write-Host "Получен корень конфигурации — по имени он частично не выгружается," -ForegroundColor Yellow
        Write-Host "используйте /db-dump-xml -Mode Changes." -ForegroundColor Yellow
    }
}

# --- Подкоманды ---
# Ключ выбирается по таблице: произвольный ключ задать нельзя. Неизвестная подкоманда — ошибка,
# а не проброс: платформа на неизвестный ключ открывает конфигуратор и висит.
$script:CommandKeys = @{
    'lock'        = '/ConfigurationRepositoryLock'
    'unlock'      = '/ConfigurationRepositoryUnlock'
    'commit'      = '/ConfigurationRepositoryCommit'
    'update'      = '/ConfigurationRepositoryUpdateCfg'
    'connect'     = '/ConfigurationRepositoryBindCfg'
    'disconnect'  = '/ConfigurationRepositoryUnbindCfg'
    'report'      = '/ConfigurationRepositoryReport'
    'dump-cfg'    = '/ConfigurationRepositoryDumpCfg'
    'create'      = '/ConfigurationRepositoryCreate'
    'add-user'    = '/ConfigurationRepositoryAddUser'
    'copy-users'  = '/ConfigurationRepositoryCopyUsers'
    'set-label'   = '/ConfigurationRepositorySetLabel'
    'optimize'    = '/ConfigurationRepositoryOptimizeData'
    'clear-cache' = '/ConfigurationRepositoryClearCache'
}

# Прощающий ввод: синонимы намеренно НЕ документируются, в SKILL.md одна каноничная форма.
$script:CommandAliases = @{
    'capture' = 'lock'; 'захватить' = 'lock'
    'release' = 'unlock'; 'отменить-захват' = 'unlock'
    'put' = 'commit'; 'поместить' = 'commit'
    'pull' = 'update'; 'получить' = 'update'; 'update-cfg' = 'update'
    'bind' = 'connect'
    'dumpcfg' = 'dump-cfg'; 'dump' = 'dump-cfg'
    'adduser' = 'add-user'; 'copyusers' = 'copy-users'; 'setlabel' = 'set-label'
    'clearcache' = 'clear-cache'; 'optimize-data' = 'optimize'
}

function Resolve-Command {
    param([string]$Raw)
    $c = $Raw.Trim().ToLowerInvariant()
    # unbind отличается от unlock одной буквой, а последствия разные: отмена захвата против
    # отключения базы от хранилища. Молча угадывать нельзя.
    if ($c -eq 'unbind') {
        Write-Host "Error: 'unbind' is ambiguous — did you mean 'unlock' (release captured objects) or 'disconnect' (detach the base from the repository)?" -ForegroundColor Red
        exit 1
    }
    if ($script:CommandAliases.ContainsKey($c)) { $c = $script:CommandAliases[$c] }
    if (-not $script:CommandKeys.ContainsKey($c)) {
        Write-Host "Error: unknown command '$Raw'. Known: $(($script:CommandKeys.Keys | Sort-Object) -join ', ')" -ForegroundColor Red
        exit 1
    }
    return $c
}

# --- Вердикт ---
# Код возврата платформы про фактический результат не говорит: захват и помещение НЕ атомарны
# (код 1 при реально захваченном объекте), а все no-op'ы дают код 0. Меряем не «изменилось ли»,
# а «достигнуто ли запрошенное»: достигнуто, в том числе уже было — 0; частично — 0 с поимённым
# предупреждением; не достигнуто ничего — 1.
function Get-ObjectKey {
    # Ключ для сопоставления запрошенного с тем, что назвала платформа. Имена типов в паре
    # «запрос ↔ лог» бывают на разных языках: платформа ПРИНИМАЕТ Catalog.Номенклатура, а
    # ОТВЕЧАЕТ всегда Справочник.Номенклатура. Поэтому сравниваем только собственные имена —
    # нечётные сегменты пути; они в обеих раскладках одинаковы, и карта типов не нужна.
    # Цена приёма: Справочник.Х и Документ.Х дают один ключ. Влияет только на формулировку
    # вердикта, не на выполненную операцию.
    param([string]$Name)
    $segs = $Name -split '\.'
    $own = @()
    for ($i = 1; $i -lt $segs.Count; $i += 2) { $own += $segs[$i] }
    if ($own.Count -eq 0) { $own = @($segs[0]) }
    return ($own -join '.').ToLowerInvariant()
}

# Операция над всей конфигурацией перечисляет тысячи объектов. Печатаем начало списка,
# остальное кладём в файл: модели нужен факт и путь, а не простыня.
$script:ListLimit = 20

function Save-ObjectList {
    param([string[]]$Names, [string]$Key)
    if (-not $Key) { $Key = 'objects' }
    $path = Join-Path $env:TEMP "db-repo-$Key.txt"
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($path, $Names, $utf8Bom)
    return $path
}

function Write-RepoObjects {
    param([string]$Title, [string[]]$Names, [string]$Color = 'Green', [string]$FileKey = 'objects')
    if (-not $Names -or $Names.Count -eq 0) { return }
    Write-Host "$Title ($($Names.Count)):" -ForegroundColor $Color
    $limit = [Math]::Min($Names.Count, $script:ListLimit)
    foreach ($n in $Names[0..($limit - 1)]) { Write-Host "  $n" }
    if ($Names.Count -gt $script:ListLimit) {
        $path = Save-ObjectList $Names $FileKey
        Write-Host "  … и ещё $($Names.Count - $script:ListLimit); полный список: $path" -ForegroundColor Yellow
    }
}

function Write-RepoVerdict {
    param([string]$Cmd, [hashtable]$Log, [int]$PlatformExit, [string[]]$Requested = @())

    if ($Log.Missing.Count -gt 0) {
        Write-Host "Error: objects not found in the configuration:" -ForegroundColor Red
        $missLimit = [Math]::Min($Log.Missing.Count, $script:ListLimit)
        foreach ($n in $Log.Missing[0..($missLimit - 1)]) { Write-Host "  $n" -ForegroundColor Red }
        if ($Log.Missing.Count -gt $script:ListLimit) {
            Write-Host "  … и ещё $($Log.Missing.Count - $script:ListLimit); полный список: $(Save-ObjectList $Log.Missing 'missing')" -ForegroundColor Red
        }
        Write-Host "Возможные причины:" -ForegroundColor Yellow
        Write-Host "  - опечатка в имени. Принимаются обе формы: Справочник.Номенклатура и Catalog.Номенклатура" -ForegroundColor Yellow
        Write-Host "  - база отстала от хранилища, объект появился позже — выполните /db-repo update" -ForegroundColor Yellow
        Write-Host "  - это не объект хранилища: реквизиты, табличные части, измерения и ресурсы" -ForegroundColor Yellow
        Write-Host "    отдельно не захватываются — указывайте объект-владельца" -ForegroundColor Yellow
        return 1
    }

    switch ($Cmd) {
        'lock' {
            # Порядок вывода: факты, затем вердикт, и только потом совет. Совет длинный, и
            # между фактами и вердиктом он прятал бы главную строку.
            Write-RepoObjects "Захвачено" $Log.Locked 'Green' 'locked'
            if ($Log.LockedByOther.Count -gt 0) {
                Write-Host "Не удалось захватить ($($Log.LockedByOther.Count)):" -ForegroundColor Yellow
                $blockedLimit = [Math]::Min($Log.LockedByOther.Count, $script:ListLimit)
                foreach ($o in $Log.LockedByOther[0..($blockedLimit - 1)]) { Write-Host "  $($o.Name) — держит $($o.Holder)" -ForegroundColor Yellow }
                if ($Log.LockedByOther.Count -gt $script:ListLimit) {
                    $blockedPath = Save-ObjectList @($Log.LockedByOther | ForEach-Object { "$($_.Name) — $($_.Holder)" }) 'blocked'
                    Write-Host "  … и ещё $($Log.LockedByOther.Count - $script:ListLimit); полный список: $blockedPath" -ForegroundColor Yellow
                }
            }
            if ($Log.Locked.Count -eq 0 -and $Log.LockedByOther.Count -gt 0) {
                # «Уже захвачено мной» платформа не печатает вовсе, поэтому отличить его от
                # «не захвачено» по логу нельзя — сверяем с тем, что просили. Заняты ВСЕ
                # запрошенные объекты только тогда, когда каждый из них назван занятым.
                $blockedKeys = @($Log.LockedByOther | ForEach-Object { Get-ObjectKey $_.Name })
                $requestedKeys = @($Requested | ForEach-Object { Get-ObjectKey $_ })
                $allBlocked = ($requestedKeys.Count -eq 0) -or
                    (@($requestedKeys | Where-Object { $blockedKeys -notcontains $_ }).Count -eq 0)
                if ($allBlocked) {
                    Write-Host "Захват не выполнен: все запрошенные объекты заняты." -ForegroundColor Red
                    Write-ReceivedWarning $Log.Received
                    return 1
                }
                Write-Host "[warning] часть запрошенного занята другими; остальное уже было захвачено вами." -ForegroundColor Yellow
                Write-Host "          Захваченное можно править: код возврата 0 именно поэтому." -ForegroundColor Yellow
                Write-ReceivedWarning $Log.Received
                return 0
            }
            if ($Log.Locked.Count -eq 0 -and $PlatformExit -eq 0) {
                # Захват уже захваченного СОБОЙ: платформа не печатает ни блока операции, ни строк.
                Write-Host "Объекты уже захвачены вами — изменений не потребовалось." -ForegroundColor Green
                Write-ReceivedWarning $Log.Received
                return 0
            }
            if ($Log.Locked.Count -eq 0) {
                Write-Host "Захват не выполнен (код $PlatformExit)$(Get-ExitAnnotation $PlatformExit)" -ForegroundColor Red
                Write-ReceivedWarning $Log.Received
                return 1
            }
            if ($Log.LockedByOther.Count -gt 0) {
                Write-Host "[warning] захват выполнен частично — перечисленные выше объекты остались у других пользователей." -ForegroundColor Yellow
                Write-Host "          Захваченное можно править: код возврата 0 именно поэтому." -ForegroundColor Yellow
                Write-ReceivedWarning $Log.Received
                return 0
            }
            Write-ReceivedWarning $Log.Received
            return $PlatformExit
        }
        'unlock' {
            # Отмена захвата атомарна: при локальных изменениях платформа отменяет операцию целиком.
            if ($PlatformExit -ne 0) {
                if ($Log.Modified.Count -gt 0) {
                    Write-Host "Отмена захвата не выполнена: у объектов есть локальные изменения ($($Log.Modified.Count)):" -ForegroundColor Red
                    $modLimit = [Math]::Min($Log.Modified.Count, $script:ListLimit)
                    foreach ($n in $Log.Modified[0..($modLimit - 1)]) { Write-Host "  $n" -ForegroundColor Red }
                    if ($Log.Modified.Count -gt $script:ListLimit) {
                        Write-Host "  … и ещё $($Log.Modified.Count - $script:ListLimit); полный список: $(Save-ObjectList $Log.Modified 'modified')" -ForegroundColor Red
                    }
                    Write-Host "Поместите их (/db-repo commit) либо откажитесь от них: -Force перезапишет объекты версией из хранилища." -ForegroundColor Yellow
                } else {
                    Write-Host "Отмена захвата не выполнена (код $PlatformExit)$(Get-ExitAnnotation $PlatformExit)" -ForegroundColor Red
                }
                return 1
            }
            Write-RepoObjects "Захват отменён" $Log.Unlocked 'Green' 'unlocked'
            Write-RepoObjects "Не были захвачены — снимать нечего" $Log.NotLocked 'Yellow' 'not-locked'
            if ($Log.Unlocked.Count -eq 0) { Write-Host "Изменений не потребовалось." -ForegroundColor Green }
            Write-ReceivedWarning $Log.Received
            return 0
        }
        'commit' {
            if ($PlatformExit -ne 0) {
                # Платформа отдаёт голую «Ошибка помещения изменений объектов в хранилище» —
                # ни объекта, ни причины, одинаково для всех причин. Диагностику даём свою.
                Write-Host "Помещение не выполнено (код $PlatformExit)$(Get-ExitAnnotation $PlatformExit)" -ForegroundColor Red
                Write-Host "Платформа не называет причину. Проверьте:" -ForegroundColor Yellow
                Write-Host "  - захвачен ли объект вами: /db-repo lock" -ForegroundColor Yellow
                Write-Host "  - не держит ли его другой пользователь" -ForegroundColor Yellow
                Write-Host "  - есть ли у пользователя хранилища право на помещение" -ForegroundColor Yellow
                return 1
            }
            Write-RepoObjects "Помещено в хранилище" $Log.Committed 'Green' 'committed'
            Write-RepoObjects "Без изменений — не помещались" $Log.Unchanged 'Yellow' 'unchanged'
            if ($Log.Committed.Count -eq 0) {
                Write-Host "Новая версия в хранилище НЕ создана: помещать было нечего." -ForegroundColor Yellow
            }
            return 0
        }
        'update' {
            if ($PlatformExit -ne 0) {
                Write-Host "Получение изменений не выполнено (код $PlatformExit)$(Get-ExitAnnotation $PlatformExit)" -ForegroundColor Red
                return 1
            }
            if (-not $Log.HasOperationBlock) {
                # У подключённой базы лог всегда содержит блок операции — даже когда получать нечего.
                # Его отсутствие означает, что база к хранилищу НЕ подключена, а тогда эта команда
                # молча заменяет всю конфигурацию содержимым хранилища и рапортует успех.
                Write-Host "Error: the platform reported success but printed no repository operation block." -ForegroundColor Red
                Write-Host "       Похоже, база НЕ подключена к хранилищу — в этом случае команда заменяет" -ForegroundColor Red
                Write-Host "       всю конфигурацию базы содержимым хранилища. Проверьте состояние базы." -ForegroundColor Red
                return 1
            }
            Write-RepoObjects "Получено из хранилища" $Log.Received 'Green' 'received'
            if ($Log.Received.Count -eq 0) {
                Write-Host "Изменений в хранилище нет — конфигурация уже актуальна." -ForegroundColor Green
                return 0
            }
            Write-ReceivedWarning $Log.Received
            return 0
        }
        default {
            if ($PlatformExit -ne 0) {
                Write-Host "Команда '$Cmd' завершилась с ошибкой (код $PlatformExit)$(Get-ExitAnnotation $PlatformExit)" -ForegroundColor Red
                # Подключение базы, у которой конфигурация уже есть, платформа отклоняет без
                # подсказки — а действие ровно одно, и оно необратимо.
                if ($Log.Raw -match 'связанная с данным хранилищем') {
                    Write-Host "[hint] за этим пользователем хранилища уже числится другая база." -ForegroundColor Yellow
                    Write-Host "       Подключить всё равно — -ForceBindAlreadyBindedUser." -ForegroundColor Yellow
                }
                if ($Log.Raw -match 'Конфигурация не пустая') {
                    Write-Host "[hint] в базе уже есть конфигурация. Замена её конфигурацией из хранилища —" -ForegroundColor Yellow
                    Write-Host "       -ForceReplaceCfg. Операция необратима: спросите подтверждение у пользователя." -ForegroundColor Yellow
                    Write-Host "       Если база уже была подключена, понадобится ещё -ForceBindAlreadyBindedUser." -ForegroundColor Yellow
                }
                return 1
            }
            Write-Host "Команда '$Cmd' выполнена." -ForegroundColor Green
            if ($Cmd -eq 'report' -and $ReportFormat -eq 'txt' -and (Test-Path $OutputFile)) {
                $txt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($OutputFile))
                if ($txt.Length -gt 0 -and $txt[0] -eq [char]0xFEFF) { $txt = $txt.Substring(1) }
                $lines = @($txt.TrimEnd() -split "`r?`n")
                # Короткий отчёт печатаем целиком, длинный — не печатаем ВОВСЕ. Обрезанный отчёт
                # по версиям опаснее длинного: он читается как полный ответ, и по куску легко
                # заключить «объект не менялся». Список объектов при обрезке хотя бы очевидно неполон.
                if ($lines.Count -le 100) {
                    Write-Host "--- $OutputFile ---"
                    Write-Host ($lines -join [Environment]::NewLine)
                    Write-Host "--- End ---"
                } else {
                    Write-Host "Отчёт не печатается целиком (строк: $($lines.Count)): $OutputFile" -ForegroundColor Yellow
                    Write-Host "Сузьте выборку: -NBegin -1 (только последняя версия), -NBegin/-NEnd (диапазон)," -ForegroundColor Yellow
                    Write-Host "-DateBegin/-DateEnd (период), -GroupByObject (сводка по объектам)." -ForegroundColor Yellow
                }
            }
            return 0
        }
    }
}

# =============================== main ===============================

if (-not $Command) {
    Write-Host "Error: -Command is required. Known: $(($script:CommandKeys.Keys | Sort-Object) -join ', ')" -ForegroundColor Red
    exit 1
}
$cmd = Resolve-Command $Command

if (-not $InfoBasePath -and -not ($InfoBaseServer -and $InfoBaseRef)) {
    Write-Host "Error: specify -InfoBasePath, or -InfoBaseServer together with -InfoBaseRef" -ForegroundColor Red
    exit 1
}

$repo = Resolve-RepositorySettings
if (-not $repo.Path) {
    if ($Extension) {
        Write-Host "Error: repository path for extension '$Extension' is unknown — add extensions[].repository to the database record in .v8-project.json, or pass -RepositoryPath" -ForegroundColor Red
        Write-Host "       Note: an extension has its OWN repository with its own path." -ForegroundColor Yellow
    } else {
        Write-Host "Error: repository path is unknown — add repository to the database record in .v8-project.json, or pass -RepositoryPath" -ForegroundColor Red
    }
    exit 1
}

# Подтверждение деструктивных операций спрашивает модель (см. SKILL.md) — так же, как у полной
# загрузки в db-load-xml. Здесь остаётся только то, что моделью не проверяется: команда update на
# базе, про которую реестр не знает, что она подключена к хранилищу. На НЕподключённой базе
# UpdateCfg молча заменяет всю конфигурацию содержимым хранилища и рапортует успех.
if ($cmd -eq 'update' -and -not $repo.FromRegistry -and -not $RepositoryPath) {
    Write-Host "Error: the database record in .v8-project.json declares no repository — refusing to run update" -ForegroundColor Red
    Write-Host "       On a base NOT bound to a repository this command silently REPLACES the whole configuration" -ForegroundColor Yellow
    Write-Host "       with the repository content and still reports success." -ForegroundColor Yellow
    exit 1
}

$objectAware = @('lock', 'unlock', 'commit', 'update')
$requested = @(Resolve-LockableObjects (Get-RequestedObjects))
if ($requested.Count -gt 0 -and $objectAware -notcontains $cmd) {
    Write-Host "Error: -Objects/-ObjectsFile does not apply to '$cmd'" -ForegroundColor Red
    exit 1
}

# Операции над всей конфигурацией требуют явного -All. Умолчанием это быть не может: захват
# всей конфигурации на большой базе идёт долго и блокирует работу всей команде, а получается
# такой вызов от одного забытого -Objects.
$wholeConfigAware = @('lock', 'unlock', 'commit')
if ($All -and $requested.Count -gt 0) {
    Write-Host "Error: -All (whole configuration) contradicts -Objects/-ObjectsFile — pick one" -ForegroundColor Red
    exit 1
}
if ($wholeConfigAware -contains $cmd -and $requested.Count -eq 0 -and -not $All) {
    Write-Host "Error: '$cmd' without -Objects would affect the WHOLE configuration." -ForegroundColor Red
    Write-Host "       Укажите объекты: -Objects `"Справочник.Номенклатура`"" -ForegroundColor Yellow
    Write-Host "       Это и нужно — подтвердите явно: -All" -ForegroundColor Yellow
    exit 1
}
# Корень с подчинёнными — это тоже вся конфигурация, хотя выглядит как «захвачу корень».
if ($WithChildren) {
    $rootAsked = @($requested | Where-Object { $script:ConfigRootAliases -contains $_ })
    if ($rootAsked.Count -gt 0) {
        Write-Host "Error: '$($rootAsked[0])' with -WithChildren means the WHOLE configuration, not just its root." -ForegroundColor Red
        Write-Host "       Нужен только корень (чтобы добавить или удалить объект) — уберите -WithChildren." -ForegroundColor Yellow
        Write-Host "       Нужна вся конфигурация — вызовите с -All вместо -Objects." -ForegroundColor Yellow
        exit 1
    }
}

switch ($cmd) {
    'report'     {
        # Отчёт печатается в вывод, поэтому путь нужен только если его хотят сохранить.
        if (-not $OutputFile) { $OutputFile = Join-Path $env:TEMP "db-repo-report.$ReportFormat" }
    }
    'dump-cfg'   { if (-not $OutputFile) { Write-Host "Error: -OutputFile (path to the .cf file) is required for dump-cfg" -ForegroundColor Red; exit 1 } }
    'add-user'   { if (-not $NewUser -or -not $Rights) { Write-Host "Error: -NewUser and -Rights are required for add-user" -ForegroundColor Red; exit 1 } }
    'copy-users' { if (-not $SourcePath -or -not $SourceUser) { Write-Host "Error: -SourcePath and -SourceUser are required for copy-users" -ForegroundColor Red; exit 1 } }
    'set-label'  { if (-not $Label) { Write-Host "Error: -Label is required for set-label" -ForegroundColor Red; exit 1 } }
}

$extraArgs = @(Resolve-ExtraArgs $AdditionalV8Arguments @{})

$tempDir = Join-Path $env:TEMP "db_repo_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # --- Соединение ---
    $arguments = @("DESIGNER")
    if ($InfoBaseServer -and $InfoBaseRef) {
        $arguments += "/S", "`"$InfoBaseServer/$InfoBaseRef`""
    } else {
        $arguments += "/F", "`"$InfoBasePath`""
    }
    if ($UserName) { $arguments += "/N`"$UserName`"" }
    if ($Password) { $arguments += "/P`"$Password`"" }

    $arguments += Get-RepositoryArgs $repo

    # --- Команда ---
    $key = $script:CommandKeys[$cmd]
    if ($cmd -eq 'clear-cache') {
        $key = switch ($CacheScope) {
            'local'  { '/ConfigurationRepositoryClearLocalCache' }
            'global' { '/ConfigurationRepositoryClearGlobalCache' }
            'db'     { '/ConfigurationRepositoryClearCache' }
        }
    }
    $arguments += $key

    if ($cmd -eq 'dump-cfg' -or $cmd -eq 'report') { $arguments += "`"$OutputFile`"" }

    $objectsXml = $null
    if ($objectAware -contains $cmd -and $requested.Count -gt 0) {
        $objectsXml = New-ObjectsListXml $requested (Join-Path $tempDir "objects.xml")
        $arguments += "-Objects", "`"$objectsXml`""
    }

    switch ($cmd) {
        'lock' {
            if ($Revised) { $arguments += "-revised" }
        }
        'unlock' {
            if ($Force) { $arguments += "-force" }
        }
        'commit' {
            if ($Comment) {
                # Многострочный комментарий задаётся своим -comment на каждую строку.
                foreach ($line in ($Comment -split "`r?`n")) { $arguments += "-comment", "`"$line`"" }
            }
            if ($KeepLocked) { $arguments += "-keepLocked" }
            if ($Force) { $arguments += "-force" }
        }
        'update' {
            if ($Version) { $arguments += "-v", $Version }
            if ($Revised) { $arguments += "-revised" }
            if ($Force) { $arguments += "-force" }
        }
        'connect' {
            if ($ForceBindAlreadyBindedUser) { $arguments += "-forceBindAlreadyBindedUser" }
            if ($ForceReplaceCfg) { $arguments += "-forceReplaceCfg" }
        }
        'disconnect' {
            if ($Force) { $arguments += "-force" }
        }
        'dump-cfg' {
            if ($Version) { $arguments += "-v", $Version }
        }
        'report' {
            if ($NBegin) { $arguments += "-NBegin", $NBegin }
            if ($NEnd) { $arguments += "-NEnd", $NEnd }
            if ($DateBegin) { $arguments += "-DateBegin", "`"$DateBegin`"" }
            if ($DateEnd) { $arguments += "-DateEnd", "`"$DateEnd`"" }
            if ($GroupByObject) { $arguments += "-GroupByObject" }
            if ($GroupByComment) { $arguments += "-GroupByComment" }
            $arguments += "-ReportFormat", $ReportFormat
        }
        'create' {
            if ($AllowConfigurationChanges) { $arguments += "-AllowConfigurationChanges" }
            if ($ChangesAllowedRule) { $arguments += "-ChangesAllowedRule", $ChangesAllowedRule }
            if ($ChangesNotRecommendedRule) { $arguments += "-ChangesNotRecommendedRule", $ChangesNotRecommendedRule }
            if ($NoBind) { $arguments += "-NoBind" }
        }
        'add-user' {
            $arguments += "-User", "`"$NewUser`""
            if ($NewUserPassword) { $arguments += "-Pwd", "`"$NewUserPassword`"" }
            $arguments += "-Rights", $Rights
            if ($RestoreDeletedUser) { $arguments += "-RestoreDeletedUser" }
        }
        'copy-users' {
            $arguments += "-Path", "`"$SourcePath`""
            $arguments += "-User", "`"$SourceUser`""
            if ($SourcePassword) { $arguments += "-Pwd", "`"$SourcePassword`"" }
            if ($RestoreDeletedUser) { $arguments += "-RestoreDeletedUser" }
        }
        'set-label' {
            if ($Version) { $arguments += "-v", $Version }
            $arguments += "-name", "`"$Label`""
            if ($Comment) {
                foreach ($line in ($Comment -split "`r?`n")) { $arguments += "-comment", "`"$line`"" }
            }
        }
    }

    if ($Extension) { $arguments += "-Extension", "`"$Extension`"" }

    $logFile = Join-Path $tempDir "repo_log.txt"
    $arguments += "/Out", "`"$logFile`""
    $arguments += "/DisableStartupDialogs"
    $arguments += "/DisableStartupMessages"
    $arguments += $extraArgs

    $secrets = @($Password, $repo.Password, $NewUserPassword, $SourcePassword)
    Write-Host "Running: 1cv8.exe $(Protect-Secrets ((Format-ArgsForDisplay $arguments '1cv8') -join ' ') $secrets)"
    $proc = Invoke-PlatformProcess $V8Path $arguments -PreQuoted
    $exitCode = $proc.ExitCode

    $logText = ''
    if (Test-Path $logFile) {
        # /Out — всегда UTF-8 с BOM.
        $logText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($logFile))
        if ($logText.Length -gt 0 -and $logText[0] -eq [char]0xFEFF) { $logText = $logText.Substring(1) }
    }
    $log = Read-RepoLog $logText
    $verdict = Write-RepoVerdict $cmd $log $exitCode $requested
    # Разбор мог не покрыть причину (у commit её вовсе нет в логе) — при отказе показываем сырой лог.
    if ($verdict -ne 0 -and $logText.Trim()) {
        # Лог операции над всей конфигурацией — тысячи строк. Показываем хвост: итог и причина
        # отказа платформа пишет в конце.
        $logLines = @($logText.TrimEnd() -split "`r?`n")
        $logLimit = 200
        Write-Host "--- Log ---"
        if ($logLines.Count -gt $logLimit) {
            Write-Host "[... показаны последние $logLimit строк из $($logLines.Count) ...]"
            $logLines = $logLines[($logLines.Count - $logLimit)..($logLines.Count - 1)]
        }
        Write-Host ($logLines -join [Environment]::NewLine)
        Write-Host "--- End ---"
    }
    # Реестр — не формальность: без repository реквизиты придётся передавать в каждом вызове,
    # а update откажется работать вовсе. Модель об этом не вспомнит, поэтому даём готовый блок.
    # «Соединение не установлено» у сетевого хранилища означает не отсутствие реквизитов,
    # а недоступный сервер — трактовка «добавьте repository» увела бы не туда.
    if ($verdict -ne 0 -and $logText -match 'Соединение с хранилищем конфигурации не установлено') {
        if ($repo.Path -match '^tcp://') {
            Write-Host "[hint] сервер хранилища недоступен по адресу $($repo.Path)." -ForegroundColor Yellow
            Write-Host "       Проверьте, запущен ли сервер хранилища и верен ли порт (по умолчанию 1542)." -ForegroundColor Yellow
        } elseif ($repo.Path -match '^https?://') {
            Write-Host "[hint] хранилище недоступно по адресу $($repo.Path)." -ForegroundColor Yellow
            Write-Host "       Проверьте веб-сервер и публикацию хранилища." -ForegroundColor Yellow
        } else {
            Write-Host "[hint] хранилище недоступно по пути $($repo.Path) — проверьте путь и реквизиты." -ForegroundColor Yellow
        }
    }

    # Признак — что путь задали аргументом: значит в реестре его нет (или он другой).
    if ($verdict -eq 0 -and @('create', 'connect') -contains $cmd -and $RepositoryPath) {
        # В строке замены -replace обратный слэш не спецсимвол: два символа дают два слэша.
        $jsonPath = $repo.Path -replace '\\', '\\'
        Write-Host ""
        Write-Host "[note] допишите хранилище в запись базы в .v8-project.json (см. /db-list):" -ForegroundColor Yellow
        if ($Extension) {
            Write-Host "  `"extensions`": [ { `"name`": `"$Extension`", `"repository`": { `"path`": `"$jsonPath`", `"user`": `"$($repo.User)`", `"password`": `"<пароль>`" } } ]"
        } else {
            Write-Host "  `"repository`": { `"path`": `"$jsonPath`", `"user`": `"$($repo.User)`", `"password`": `"<пароль>`" }"
        }
    }
    Write-PlatformOutput $proc.Output
    exit $verdict

} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
