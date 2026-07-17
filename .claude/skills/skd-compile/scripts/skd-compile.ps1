# skd-compile v1.108 — Compile 1C DCS from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[string]$DefinitionFile,
	[string]$Value,
	[Parameter(Mandatory)]
	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
function Test-ExternalObjectRoot([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $false }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { return @('ExternalDataProcessor','ExternalReport') -contains $el.LocalName }
	} catch {}
	return $false
}
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
function Get-EditMode([string]$cfgDir) {
	try {
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $hm.Success) { return }
		$G = [int]$hm.Groups[1].Value
		$K = [int]$hm.Groups[2].Value
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch { return }
}

# --- 1. Load and validate JSON ---

if ($DefinitionFile -and $Value) {
	Write-Error "Cannot use both -DefinitionFile and -Value"
	exit 1
}
if (-not $DefinitionFile -and -not $Value) {
	Write-Error "Either -DefinitionFile or -Value is required"
	exit 1
}

if ($DefinitionFile) {
	if (-not [System.IO.Path]::IsPathRooted($DefinitionFile)) {
		$DefinitionFile = Join-Path (Get-Location).Path $DefinitionFile
	}
	if (-not (Test-Path $DefinitionFile)) {
		Write-Error "Definition file not found: $DefinitionFile"
		exit 1
	}
	$json = Get-Content -Raw -Encoding UTF8 $DefinitionFile
} else {
	$json = $Value
}

$def = $json | ConvertFrom-Json

# --- Sentinel check: refuse to compile if JSON contains skd-decompile sentinels ---
# These mark places the decompiler couldn't reverse cleanly; user must resolve
# them manually before compile (see <basename>.warnings.md alongside the JSON).
$script:foundSentinels = @()
function Scan-Sentinels {
	param($obj, [string]$path)
	if ($null -eq $obj) { return }
	if ($obj -is [System.Collections.IDictionary]) {
		foreach ($k in @($obj.Keys)) {
			if ($k -eq '__unsupported__') {
				$u = $obj[$k]
				$id = $u.id; $kind = $u.kind; $loc = $u.loc
				$script:foundSentinels += "  $id [$kind] at $path → $loc"
			} else {
				Scan-Sentinels -obj $obj[$k] -path "$path/$k"
			}
		}
	} elseif ($obj -is [System.Management.Automation.PSCustomObject]) {
		foreach ($p in $obj.PSObject.Properties) {
			if ($p.Name -eq '__unsupported__') {
				$u = $p.Value
				$id = $u.id; $kind = $u.kind; $loc = $u.loc
				$script:foundSentinels += "  $id [$kind] at $path → $loc"
			} else {
				Scan-Sentinels -obj $p.Value -path "$path/$($p.Name)"
			}
		}
	} elseif ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
		$i = 0
		foreach ($item in $obj) { Scan-Sentinels -obj $item -path "$path[$i]"; $i++ }
	}
}
Scan-Sentinels -obj $def -path ''
if ($script:foundSentinels.Count -gt 0) {
	[Console]::Error.WriteLine("skd-compile: JSON содержит __unsupported__ маркеры от skd-decompile.")
	[Console]::Error.WriteLine("Это конструкции, которые декомпиляция не смогла обратить — нужно разрешить вручную перед компиляцией.")
	[Console]::Error.WriteLine("См. <basename>.warnings.md рядом с JSON. Найдено:")
	foreach ($s in $script:foundSentinels) { [Console]::Error.WriteLine($s) }
	exit 4
}

if (-not $def.dataSets -or $def.dataSets.Count -eq 0) {
	Write-Error "JSON must have at least one entry in 'dataSets'"
	exit 1
}

# Base directory for resolving @file references in query
$script:queryBaseDir = if ($DefinitionFile) { [System.IO.Path]::GetDirectoryName($DefinitionFile) } else { (Get-Location).Path }

# --- 2. XML helpers ---

$script:xml = New-Object System.Text.StringBuilder 16384

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

function Resolve-QueryValue {
	param([string]$val, [string]$baseDir)
	if (-not $val.StartsWith("@")) { return $val }
	$filePath = $val.Substring(1)
	if ([System.IO.Path]::IsPathRooted($filePath)) {
		$candidates = @($filePath)
	} else {
		$candidates = @(
			(Join-Path $baseDir $filePath),
			(Join-Path (Get-Location).Path $filePath)
		)
	}
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			return (Get-Content -Raw -Encoding UTF8 $c).TrimEnd()
		}
	}
	Write-Error "Query file not found: $filePath (searched: $($candidates -join ', '))"
	exit 1
}

function Emit-MLText {
	param([string]$tag, $text, [string]$indent, [switch]$NoXsiType)
	# Empty value → self-closing tag (matches platform output)
	if ($null -eq $text -or ($text -is [string] -and $text -eq '')) {
		if ($NoXsiType) {
			X "$indent<$tag/>"
		} else {
			X "$indent<$tag xsi:type=`"v8:LocalStringType`"/>"
		}
		return
	}
	if ($NoXsiType) {
		X "$indent<$tag>"
	} else {
		X "$indent<$tag xsi:type=`"v8:LocalStringType`">"
	}
	# Multi-lang: object form { ru: "...", en: "..." } → one <v8:item> per language
	if ($text -is [System.Management.Automation.PSCustomObject] -or $text -is [hashtable] -or $text -is [System.Collections.IDictionary]) {
		$props = if ($text -is [System.Management.Automation.PSCustomObject]) { $text.PSObject.Properties } else { $text.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } } }
		foreach ($p in $props) {
			$lang = if ($p -is [hashtable]) { $p.Name } else { $p.Name }
			$content = if ($p -is [hashtable]) { $p.Value } else { $p.Value }
			X "$indent`t<v8:item>"
			X "$indent`t`t<v8:lang>$(Esc-Xml "$lang")</v8:lang>"
			X "$indent`t`t<v8:content>$(Esc-Xml "$content")</v8:content>"
			X "$indent`t</v8:item>"
		}
	} else {
		X "$indent`t<v8:item>"
		X "$indent`t`t<v8:lang>ru</v8:lang>"
		X "$indent`t`t<v8:content>$(Esc-Xml "$text")</v8:content>"
		X "$indent`t</v8:item>"
	}
	X "$indent</$tag>"
}

function New-Guid-String {
	return [System.Guid]::NewGuid().ToString()
}

# --- 3. Resolve defaults ---

# DataSources
$dataSources = @()
if ($def.dataSources) {
	foreach ($ds in $def.dataSources) {
		$dataSources += @{
			name = "$($ds.name)"
			type = if ($ds.type) { "$($ds.type)" } else { "Local" }
		}
	}
} else {
	$dataSources += @{ name = "ИсточникДанных1"; type = "Local" }
}

$defaultSource = $dataSources[0].name

# Auto-name dataSets
$dsIndex = 1
foreach ($ds in $def.dataSets) {
	if (-not $ds.name) {
		$ds | Add-Member -NotePropertyName "name" -NotePropertyValue "НаборДанных$dsIndex" -Force
	}
	$dsIndex++
}

# --- 4. Type system ---

# Type synonyms — normalize Russian/common names to canonical DSL types
# Use case-sensitive hashtable to avoid PS 5.1 DuplicateKeyInHashLiteral
$script:typeSynonyms = New-Object System.Collections.Hashtable
# Russian names (case doesn't matter — we'll also do case-insensitive lookup)
$script:typeSynonyms["число"] = "decimal"
$script:typeSynonyms["строка"] = "string"
$script:typeSynonyms["булево"] = "boolean"
$script:typeSynonyms["дата"] = "date"
$script:typeSynonyms["датавремя"] = "dateTime"
$script:typeSynonyms["время"] = "time"
$script:typeSynonyms["стандартныйпериод"] = "StandardPeriod"
# English canonical (lowercase for lookup)
$script:typeSynonyms["bool"] = "boolean"
$script:typeSynonyms["str"] = "string"
$script:typeSynonyms["int"] = "decimal"
$script:typeSynonyms["integer"] = "decimal"
$script:typeSynonyms["number"] = "decimal"
$script:typeSynonyms["num"] = "decimal"
# Reference synonyms (Russian, lowercase)
$script:typeSynonyms["справочникссылка"] = "CatalogRef"
$script:typeSynonyms["документссылка"] = "DocumentRef"
$script:typeSynonyms["перечислениессылка"] = "EnumRef"
$script:typeSynonyms["плансчетовссылка"] = "ChartOfAccountsRef"
$script:typeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	# Check for parameterized types: число(15,2), строка(100), etc.
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]

		# Resolve base name (case-insensitive via .ToLower())
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }

		return $typeStr
	}

	# Check for reference types: СправочникСсылка.Организации → CatalogRef.Организации
	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)  # includes the dot
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	# Simple name lookup (case-insensitive)
	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }

	return $typeStr
}

function Emit-ValueType {
	param($typeStr, [string]$indent)

	if (-not $typeStr) { return }

	# Multi-type: iterate and emit each type with its qualifiers
	if ($typeStr -is [array] -or $typeStr -is [System.Collections.IList]) {
		foreach ($t in $typeStr) { Emit-SingleValueType -typeStr "$t" -indent $indent }
		return
	}

	Emit-SingleValueType -typeStr "$typeStr" -indent $indent
}

function Emit-SingleValueType {
	param([string]$typeStr, [string]$indent)

	if (-not $typeStr) { return }

	# Resolve synonyms first
	$typeStr = Resolve-TypeStr $typeStr

	# boolean
	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"
		return
	}

	# string, string(N), string(N,fix) — fix → AllowedLength=Fixed
	if ($typeStr -match '^string(\((\d+)(,(fix|fixed))?\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		$al = if ($Matches[4]) { "Fixed" } else { "Variable" }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>$al</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"
		return
	}

	# decimal forms (defaults — bare decimal = money 10,2; decimal(N) = integer N,0):
	#   decimal                       → 10,2,Any
	#   decimal(N)                    → N,0,Any
	#   decimal(N,nonneg)             → N,0,Nonnegative
	#   decimal(N,M)                  → N,M,Any
	#   decimal(N,M,nonneg)           → N,M,Nonnegative
	if ($typeStr -match '^decimal(\((\d+)(,(\d+))?(,nonneg)?\))?$') {
		if (-not $Matches[1]) {
			$digits = "10"; $fraction = "2"; $sign = "Any"
		} else {
			$digits = $Matches[2]
			$fraction = if ($Matches[4]) { $Matches[4] } else { "0" }
			$sign = if ($Matches[5]) { "Nonnegative" } else { "Any" }
		}
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>$digits</v8:Digits>"
		X "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"
		return
	}

	# date / dateTime / time — all use xs:dateTime, differ only in DateFractions
	if ($typeStr -match '^(date|dateTime|time)$') {
		$fractions = switch ($typeStr) {
			"date"     { "Date" }
			"dateTime" { "DateTime" }
			"time"     { "Time" }
		}
		X "$indent<v8:Type>xs:dateTime</v8:Type>"
		X "$indent<v8:DateQualifiers>"
		X "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		X "$indent</v8:DateQualifiers>"
		return
	}

	# StandardPeriod
	if ($typeStr -eq "StandardPeriod") {
		X "$indent<v8:Type>v8:StandardPeriod</v8:Type>"
		return
	}

	# Reference types: CatalogRef.XXX, DocumentRef.XXX, EnumRef.XXX, etc.
	# Real DCS files use inline namespace d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config"
	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.') {
		X "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return
	}

	# TypeSet (композитный тип-набор): голое имя без точки, типа DocumentRef / CatalogRef /
	# EnumRef / ChartOfAccountsRef / etc. (все ссылки указанного класса).
	# Эмитим <v8:TypeSet xmlns:dN="..."> вместо <v8:Type>.
	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef|InformationRegisterRef|AnyRef)$') {
		X "$indent<v8:TypeSet xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:TypeSet>"
		return
	}

	# Fallback — assume dot-qualified types are also config references
	if ($typeStr.Contains('.')) {
		X "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return
	}

	X "$indent<v8:Type>$(Esc-Xml $typeStr)</v8:Type>"
}

# --- 5. Field shorthand parser ---

function Parse-FieldShorthand {
	param([string]$s)

	$result = @{
		dataPath = ""; field = ""; title = ""; type = ""
		roles = @(); restrict = @(); appearance = [ordered]@{}
		roleExtras = [ordered]@{}
	}

	# Extract @roles
	$roleMatches = [regex]::Matches($s, '@(\w+)')
	foreach ($m in $roleMatches) {
		$result.roles += $m.Groups[1].Value
	}
	$s = [regex]::Replace($s, '\s*@\w+', '')

	# Extract #restrictions
	$restrictMatches = [regex]::Matches($s, '#(\w+)')
	foreach ($m in $restrictMatches) {
		$result.restrict += $m.Groups[1].Value
	}
	$s = [regex]::Replace($s, '\s*#\w+', '')

	# Extract role kv=value (e.g. balanceGroupName=Сумма balanceType=OpeningBalance)
	$kvMatches = [regex]::Matches($s, '(\w+)=(\S+)')
	foreach ($m in $kvMatches) { $result.roleExtras[$m.Groups[1].Value] = $m.Groups[2].Value }
	$s = [regex]::Replace($s, '\s*\w+=\S+', '')

	# Split name: type
	$s = $s.Trim()
	if ($s.Contains(':')) {
		$parts = $s -split ':', 2
		$result.dataPath = $parts[0].Trim()
		$result.type = Resolve-TypeStr ($parts[1].Trim())
	} else {
		$result.dataPath = $s
	}

	$result.field = $result.dataPath
	return $result
}

# Universal role spec parser: string / array / object / null
# Returns @{ tokens = @(...); extras = [ordered]@{...} }
function Parse-RoleSpec {
	param($spec)
	$tokens = @()
	$extras = [ordered]@{}

	if ($null -ne $spec) {
		if ($spec -is [string]) {
			if ($spec -notmatch '\s' -and $spec -notmatch '=') {
				$tokens += $spec
			} else {
				$s = $spec.Trim()
				foreach ($m in [regex]::Matches($s, '@(\w+)')) { $tokens += $m.Groups[1].Value }
				$s = [regex]::Replace($s, '\s*@\w+', '').Trim()
				foreach ($m in [regex]::Matches($s, '(\w+)=(\S+)')) { $extras[$m.Groups[1].Value] = $m.Groups[2].Value }
			}
		} elseif ($spec -is [array] -or $spec -is [System.Collections.IList]) {
			foreach ($t in $spec) { $tokens += "$t" }
		} elseif ($spec.PSObject -and $spec.PSObject.Properties) {
			foreach ($prop in $spec.PSObject.Properties) {
				$val = $prop.Value
				if ($val -is [bool]) {
					if ($val) { $tokens += $prop.Name }
				} elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [string]) {
					$extras[$prop.Name] = "$val"
				}
			}
		} elseif ($spec -is [hashtable] -or $spec -is [System.Collections.IDictionary]) {
			foreach ($k in $spec.Keys) {
				$val = $spec[$k]
				if ($val -is [bool]) {
					if ($val) { $tokens += "$k" }
				} elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [string]) {
					$extras["$k"] = "$val"
				}
			}
		}
	}

	# Deprecated alias: balanceGroup → balanceGroupName (старое имя в коде compile, в реальном XML — Name)
	if ($extras.Contains('balanceGroup') -and -not $extras.Contains('balanceGroupName')) {
		$extras['balanceGroupName'] = $extras['balanceGroup']
		$extras.Remove('balanceGroup')
	}

	return @{ tokens = $tokens; extras = $extras }
}

# --- 6. Total field shorthand parser ---

function Parse-TotalShorthand {
	param([string]$s)

	# "DataPath: Func" or "DataPath: Func(expr)"
	$parts = $s -split ':', 2
	$dataPath = $parts[0].Trim()
	$funcPart = $parts[1].Trim()

	# Known DCS aggregate functions (ru + en)
	$aggFuncs = @('Сумма','Количество','Минимум','Максимум','Среднее',
	              'Sum','Count','Min','Max','Avg',
	              'Minimum','Maximum','Average')

	if ($funcPart -match '^\w+\(') {
		# Already has expression form: Func(expr)
		return @{ dataPath = $dataPath; expression = $funcPart }
	} elseif ($funcPart -in $aggFuncs) {
		# Short: Func → Func(DataPath)
		return @{ dataPath = $dataPath; expression = "$funcPart($dataPath)" }
	} else {
		# Identity or custom expression — use as-is
		return @{ dataPath = $dataPath; expression = $funcPart }
	}
}

# --- 7. Parameter shorthand parser ---

function Split-ValueListCsv {
	# Split on top-level commas (respecting 'single'/"double" quotes), strip quotes,
	# drop empties. No ':' handling — values may contain colons (dateTime).
	param([string]$s)
	$result = @()
	if ($null -eq $s) { return ,$result }
	$items = @()
	$buf = New-Object System.Text.StringBuilder
	$inQuote = $null
	for ($i = 0; $i -lt $s.Length; $i++) {
		$ch = $s[$i]
		if ($inQuote) { [void]$buf.Append($ch); if ($ch -eq $inQuote) { $inQuote = $null } }
		elseif ($ch -eq "'" -or $ch -eq '"') { $inQuote = $ch; [void]$buf.Append($ch) }
		elseif ($ch -eq ',') { $items += $buf.ToString(); [void]$buf.Clear() }
		else { [void]$buf.Append($ch) }
	}
	if ($buf.Length -gt 0) { $items += $buf.ToString() }
	foreach ($raw in $items) {
		$t = $raw.Trim()
		if ($t.Length -ge 2 -and (($t[0] -eq "'" -and $t[-1] -eq "'") -or ($t[0] -eq '"' -and $t[-1] -eq '"'))) { $t = $t.Substring(1, $t.Length - 2) }
		if ($t -ne "") { $result += $t }
	}
	return ,$result
}

function Parse-ParamShorthand {
	param([string]$s)

	$result = @{ name = ""; type = ""; value = $null; autoDates = $false; title = $null }

	# Extract @autoDates flag
	if ($s -match '@autoDates') {
		$result.autoDates = $true
		$s = $s -replace '\s*@autoDates', ''
	}

	# Extract @valueList flag
	if ($s -match '@valueList') {
		$result.valueListAllowed = $true
		$s = $s -replace '\s*@valueList', ''
	}

	# Extract @hidden flag
	if ($s -match '@hidden') {
		$result.hidden = $true
		$s = $s -replace '\s*@hidden', ''
	}

	# Extract optional [Title] (mirrors Parse-FieldShorthand)
	if ($s -match '\[([^\]]*)\]') {
		$result.title = $Matches[1].Trim()
		$s = ($s -replace '\s*\[[^\]]*\]\s*', ' ').Trim()
	}

	# Split "Name: Type = Value" — RHS may be empty (`= ` / `=`) → treated as empty value
	if ($s -match '^([^:]+):\s*(\S+)(\s*=\s*(.*))?$') {
		$result.name = $Matches[1].Trim()
		$result.type = Resolve-TypeStr ($Matches[2].Trim())
		if ($Matches[4]) {
			$rhs = $Matches[4].Trim()
			$items = Split-ValueListCsv $rhs
			if ($items.Count -ge 2) {
				# Multi-value default → list; valueListAllowed implied
				$result.value = $items
				$result.valueListAllowed = $true
			} elseif ($items.Count -eq 1) {
				$result.value = $items[0]
			} else {
				$result.value = $rhs
			}
		}
	} else {
		$result.name = $s.Trim()
	}

	return $result
}

# --- 8. Calculated field shorthand parser ---

function Parse-CalcShorthand {
	param([string]$s)

	# Pattern: "Name [Title]: type = Expression #noField #noFilter ...".
	# - `[Title]` is extracted only from the LHS of '=' so that `[...]` inside
	#   an expression (e.g. index access) isn't interpreted as a title.
	# - `#restrict` flags use a known-names pattern and are extracted globally —
	#   the docs put them after `=`, and the closed flag set avoids matching
	#   `#word` that happens to appear inside a string literal.
	$restrictPattern = '#(noField|noFilter|noCondition|noGroup|noOrder)\b'

	$restrict = @()
	foreach ($m in [regex]::Matches($s, $restrictPattern)) {
		$restrict += $m.Groups[1].Value
	}
	$s = [regex]::Replace($s, "\s*$restrictPattern", '')

	$eqIdx = $s.IndexOf('=')
	if ($eqIdx -gt 0) {
		$lhs = $s.Substring(0, $eqIdx)
		$rhs = $s.Substring($eqIdx + 1).Trim()
	} else {
		$lhs = $s
		$rhs = ""
	}

	$title = ""
	if ($lhs -match '\[([^\]]+)\]') {
		$title = $Matches[1]
		$lhs = $lhs -replace '\s*\[[^\]]+\]', ''
	}
	$lhs = $lhs.Trim()

	$type = ""
	$dataPath = $lhs
	if ($lhs.Contains(':')) {
		$parts = $lhs -split ':', 2
		$dataPath = $parts[0].Trim()
		$type = Resolve-TypeStr ($parts[1].Trim())
	}

	return @{
		dataPath = $dataPath
		expression = $rhs
		type = $type
		title = $title
		restrict = $restrict
	}
}

# --- 8b. DataParameter shorthand parser ---
# Formats: "Период = LastMonth @user", "Организация @off @user", "Период @user"
function Parse-DataParamShorthand {
	param([string]$s)

	$result = @{ parameter = ""; value = $null; use = $true; userSettingID = $null; viewMode = $null }

	# Extract @flags
	if ($s -match '@user') {
		$result.userSettingID = "auto"
		$s = $s -replace '\s*@user', ''
	}
	if ($s -match '@off') {
		$result.use = $false
		$s = $s -replace '\s*@off', ''
	}
	if ($s -match '@quickAccess') {
		$result.viewMode = "QuickAccess"
		$s = $s -replace '\s*@quickAccess', ''
	}
	if ($s -match '@normal') {
		$result.viewMode = "Normal"
		$s = $s -replace '\s*@normal', ''
	}

	$s = $s.Trim()

	# Split "Name = Value"
	if ($s -match '^([^=]+)=\s*(.+)$') {
		$result.parameter = $Matches[1].Trim()
		$valStr = $Matches[2].Trim()

		# Detect StandardPeriod variants
		$periodVariants = @("Custom","Today","ThisWeek","ThisTenDays","ThisMonth","ThisQuarter","ThisHalfYear","ThisYear","FromBeginningOfThisWeek","FromBeginningOfThisTenDays","FromBeginningOfThisMonth","FromBeginningOfThisQuarter","FromBeginningOfThisHalfYear","FromBeginningOfThisYear","LastWeek","LastTenDays","LastMonth","LastQuarter","LastHalfYear","LastYear","NextDay","NextWeek","NextTenDays","NextMonth","NextQuarter","NextHalfYear","NextYear","TillEndOfThisWeek","TillEndOfThisTenDays","TillEndOfThisMonth","TillEndOfThisQuarter","TillEndOfThisHalfYear","TillEndOfThisYear")
		if ($periodVariants -contains $valStr) {
			$result.value = @{ variant = $valStr }
		} elseif ($valStr -match '^\d{4}-\d{2}-\d{2}T') {
			$result.value = $valStr
		} elseif ($valStr -eq "true" -or $valStr -eq "false") {
			$result.value = [bool]($valStr -eq "true")
		} else {
			$result.value = $valStr
		}
	} else {
		$result.parameter = $s
	}

	return $result
}

# --- 8c. Filter item shorthand parser ---
# Formats: "Организация = _ @off @user", "Дата >= 2024-01-01T00:00:00", "Статус filled"
function Parse-FilterShorthand {
	param([string]$s)

	$result = @{ field = ""; op = "Equal"; value = $null; use = $true; userSettingID = $null; viewMode = $null; presentation = $null }

	# Extract @flags
	if ($s -match '@user') {
		$result.userSettingID = "auto"
		$s = $s -replace '\s*@user', ''
	}
	if ($s -match '@off') {
		$result.use = $false
		$s = $s -replace '\s*@off', ''
	}
	if ($s -match '@quickAccess') {
		$result.viewMode = "QuickAccess"
		$s = $s -replace '\s*@quickAccess', ''
	}
	if ($s -match '@normal') {
		$result.viewMode = "Normal"
		$s = $s -replace '\s*@normal', ''
	}
	if ($s -match '@inaccessible') {
		$result.viewMode = "Inaccessible"
		$s = $s -replace '\s*@inaccessible', ''
	}

	$s = $s.Trim()

	# Try to match: Field op Value, or Field op (no value for filled/notFilled)
	# Operators sorted longest first to match >= before >
	$opPatterns = @('<>', '>=', '<=', '=', '>', '<',
		'notIn\b', 'in\b', 'inHierarchy\b', 'inListByHierarchy\b',
		'notContains\b', 'contains\b', 'notBeginsWith\b', 'beginsWith\b',
		'notFilled\b', 'filled\b')
	$opJoined = $opPatterns -join '|'

	if ($s -match "^(.+?)\s+($opJoined)\s*(.*)?$") {
		$result.field = $Matches[1].Trim()
		$opRaw = $Matches[2].Trim()
		$valPart = if ($Matches[3]) { $Matches[3].Trim() } else { "" }

		# Map op
		$opMap = @{
			"=" = "Equal"; "<>" = "NotEqual"; ">" = "Greater"; ">=" = "GreaterOrEqual"
			"<" = "Less"; "<=" = "LessOrEqual"; "in" = "InList"; "notIn" = "NotInList"
			"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
			"contains" = "Contains"; "notContains" = "NotContains"
			"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
			"filled" = "Filled"; "notFilled" = "NotFilled"
		}
		$mapped = $opMap[$opRaw]
		if ($mapped) { $result.op = $opRaw } else { $result.op = $opRaw }

		# Parse value (skip "_" which means empty/placeholder)
		if ($valPart -and $valPart -ne "_") {
			if ($valPart -eq "true" -or $valPart -eq "false") {
				$result.value = [bool]($valPart -eq "true")
				$result["valueType"] = "xs:boolean"
			} elseif ($valPart -match '^\d{4}-\d{2}-\d{2}T') {
				$result.value = $valPart
				$result["valueType"] = "xs:dateTime"
			} elseif ($valPart -match '^\d+(\.\d+)?$') {
				$result.value = $valPart
				$result["valueType"] = "xs:decimal"
			} elseif ($valPart -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.') {
				$result.value = $valPart
				$result["valueType"] = "dcscor:DesignTimeValue"
			} else {
				$result.value = $valPart
				$result["valueType"] = "xs:string"
			}
		}
	} else {
		# No operator found — just a field name
		$result.field = $s
	}

	return $result
}

# --- 9. Comparison type mapper ---

$script:comparisonTypes = @{
	"=" = "Equal"; "<>" = "NotEqual"
	">" = "Greater"; ">=" = "GreaterOrEqual"
	"<" = "Less"; "<=" = "LessOrEqual"
	"in" = "InList"; "notIn" = "NotInList"
	"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
	"contains" = "Contains"; "notContains" = "NotContains"
	"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
	"filled" = "Filled"; "notFilled" = "NotFilled"
}

# --- 10. Output parameter type detection ---

$script:outputParamTypes = @{
	"Заголовок" = "mltext"
	"ВыводитьЗаголовок" = "dcsset:DataCompositionTextOutputType"
	"ВыводитьПараметрыДанных" = "dcsset:DataCompositionTextOutputType"
	"ВыводитьОтбор" = "dcsset:DataCompositionTextOutputType"
	"МакетОформления" = "xs:string"
	"РасположениеПолейГруппировки" = "dcsset:DataCompositionGroupFieldsPlacement"
	"РасположениеРеквизитов" = "dcsset:DataCompositionAttributesPlacement"
	"ГоризонтальноеРасположениеОбщихИтогов" = "dcscor:DataCompositionTotalPlacement"
	"ВертикальноеРасположениеОбщихИтогов" = "dcscor:DataCompositionTotalPlacement"
	"РасположениеОбщихИтогов" = "dcscor:DataCompositionTotalPlacement"
	"РасположениеИтогов" = "dcscor:DataCompositionTotalPlacement"
	"РасположениеГруппировки" = "dcsset:DataCompositionFieldGroupPlacement"
	"РасположениеРесурсов" = "dcsset:DataCompositionResourcesPlacement"
	"ТипМакета" = "dcsset:DataCompositionGroupTemplateType"
}

# --- 11. Emit sections ---

# === DataSources ===
function Emit-DataSources {
	foreach ($ds in $dataSources) {
		X "`t<dataSource>"
		X "`t`t<name>$(Esc-Xml $ds.name)</name>"
		X "`t`t<dataSourceType>$(Esc-Xml $ds.type)</dataSourceType>"
		X "`t</dataSource>"
	}
}

# === Fields ===
function Has-JsonProp {
	param($obj, [string]$name)
	if ($null -eq $obj) { return $false }
	if ($obj.PSObject -and $obj.PSObject.Properties) {
		return $null -ne $obj.PSObject.Properties[$name]
	}
	if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
	return $false
}

function Emit-InputParameters {
	param($ip, [string]$indent)
	if ($null -eq $ip) { return }
	$items = @($ip)
	if ($items.Count -eq 0) { return }
	X "$indent<inputParameters>"
	foreach ($item in $items) {
		X "$indent`t<dcscor:item>"
		if ((Has-JsonProp $item 'use') -and $null -ne $item.use -and -not $item.use) {
			X "$indent`t`t<dcscor:use>false</dcscor:use>"
		}
		X "$indent`t`t<dcscor:parameter>$(Esc-Xml "$($item.parameter)")</dcscor:parameter>"
		if (Has-JsonProp $item 'choiceParameters') {
			$cp = $item.choiceParameters
			$cpItems = if ($null -ne $cp) { @($cp) } else { @() }
			if ($cpItems.Count -eq 0) {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameters`"/>"
			} else {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameters`">"
				foreach ($cpItem in $cpItems) {
					X "$indent`t`t`t<dcscor:item>"
					X "$indent`t`t`t`t<dcscor:choiceParameter>$(Esc-Xml "$($cpItem.name)")</dcscor:choiceParameter>"
					foreach ($v in @($cpItem.values)) {
						if ($v -is [bool]) {
							$vStr = if ($v) { 'true' } else { 'false' }
							X "$indent`t`t`t`t<dcscor:value xsi:type=`"xs:boolean`">$vStr</dcscor:value>"
						} elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
							X "$indent`t`t`t`t<dcscor:value xsi:type=`"xs:decimal`">$v</dcscor:value>"
						} else {
							X "$indent`t`t`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml "$v")</dcscor:value>"
						}
					}
					X "$indent`t`t`t</dcscor:item>"
				}
				X "$indent`t`t</dcscor:value>"
			}
		} elseif (Has-JsonProp $item 'choiceParameterLinks') {
			$cpl = $item.choiceParameterLinks
			$cplItems = if ($null -ne $cpl) { @($cpl) } else { @() }
			if ($cplItems.Count -eq 0) {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameterLinks`"/>"
			} else {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameterLinks`">"
				foreach ($cplItem in $cplItems) {
					X "$indent`t`t`t<dcscor:item>"
					X "$indent`t`t`t`t<dcscor:choiceParameter>$(Esc-Xml "$($cplItem.name)")</dcscor:choiceParameter>"
					X "$indent`t`t`t`t<dcscor:value>$(Esc-Xml "$($cplItem.value)")</dcscor:value>"
					$mode = if ($cplItem.mode) { "$($cplItem.mode)" } else { 'Auto' }
					X "$indent`t`t`t`t<dcscor:mode xmlns:d8p1=`"http://v8.1c.ru/8.1/data/enterprise`" xsi:type=`"d8p1:LinkedValueChangeMode`">$mode</dcscor:mode>"
					X "$indent`t`t`t</dcscor:item>"
				}
				X "$indent`t`t</dcscor:value>"
			}
		} elseif (Has-JsonProp $item 'value') {
			# Simple typed value — определяем xsi:type из JSON-типа
			$val = $item.value
			# Явный кастомный type из decompile: {uri, name} → <value xmlns:dN="uri" xsi:type="dN:name">
			$customType = $null
			if (Has-JsonProp $item 'valueType') {
				$vtSrc = $item.valueType
				$uri = $null; $tName = $null
				if ($vtSrc -is [PSCustomObject]) {
					if ($vtSrc.PSObject.Properties['uri']) { $uri = "$($vtSrc.uri)" }
					if ($vtSrc.PSObject.Properties['name']) { $tName = "$($vtSrc.name)" }
				} elseif ($vtSrc -is [System.Collections.IDictionary]) {
					if ($vtSrc.Contains('uri')) { $uri = "$($vtSrc['uri'])" }
					if ($vtSrc.Contains('name')) { $tName = "$($vtSrc['name'])" }
				}
				if ($uri -and $tName) { $customType = @{ uri = $uri; name = $tName } }
			}
			if ($customType) {
				X "$indent`t`t<dcscor:value xmlns:dN=`"$($customType.uri)`" xsi:type=`"dN:$($customType.name)`">$(Esc-Xml "$val")</dcscor:value>"
			} elseif ($val -is [bool]) {
				$vStr = if ($val) { 'true' } else { 'false' }
				X "$indent`t`t<dcscor:value xsi:type=`"xs:boolean`">$vStr</dcscor:value>"
			} elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:decimal`">$val</dcscor:value>"
			} elseif ($val -is [hashtable] -or $val -is [System.Collections.IDictionary] -or $val -is [PSCustomObject]) {
				# Multilang dict {ru, en, ...} → LocalStringType
				Emit-MLText -tag "dcscor:value" -text $val -indent "$indent`t`t"
			} else {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$val")</dcscor:value>"
			}
		}
		X "$indent`t</dcscor:item>"
	}
	X "$indent</inputParameters>"
}

function Emit-Field {
	param($fieldDef, [string]$indent)

	if ($fieldDef -is [string]) {
		$f = Parse-FieldShorthand $fieldDef
	} else {
		$f = @{
			dataPath = if ($fieldDef.dataPath) { "$($fieldDef.dataPath)" } elseif ($fieldDef.field) { "$($fieldDef.field)" } else { "" }
			field = if ($fieldDef.field) { "$($fieldDef.field)" } else { "$($fieldDef.dataPath)" }
			title = if ($fieldDef.title) { $fieldDef.title } else { "" }
			type = if ($fieldDef.type) {
				if ($fieldDef.type -is [array] -or $fieldDef.type -is [System.Collections.IList]) {
					@($fieldDef.type | ForEach-Object { Resolve-TypeStr "$_" })
				} else {
					Resolve-TypeStr "$($fieldDef.type)"
				}
			} else { "" }
			roles = @()
			restrict = @()
			appearance = [ordered]@{}
			roleExtras = [ordered]@{}
		}
		# Parse role (string shorthand / array / object — единый формат с /skd-edit set-field-role)
		if ($fieldDef.role) {
			$parsed = Parse-RoleSpec $fieldDef.role
			$f.roles = $parsed.tokens
			$f.roleExtras = $parsed.extras
		}
		# Parse restrictions
		if ($fieldDef.restrict) {
			$f.restrict = @($fieldDef.restrict)
		}
		# Parse appearance (сохраняем значение как есть — может быть string или multilang dict)
		if ($fieldDef.appearance) {
			foreach ($prop in $fieldDef.appearance.PSObject.Properties) {
				$f.appearance[$prop.Name] = $prop.Value
			}
		}
		if ($fieldDef.presentationExpression) {
			$f["presentationExpression"] = "$($fieldDef.presentationExpression)"
		}
		# attrRestrict
		if ($fieldDef.attrRestrict) {
			$f["attrRestrict"] = @($fieldDef.attrRestrict)
		}
		# availableValues — array of {value, presentation}
		if ($fieldDef.availableValues) {
			$f["availableValues"] = $fieldDef.availableValues
		}
		# orderExpression — {expression, orderType, autoOrder}
		if ($fieldDef.orderExpression) {
			$f["orderExpression"] = $fieldDef.orderExpression
		}
		# inputParameters — массив элементов, типизированных по форме value
		if ($null -ne $fieldDef.inputParameters) {
			$f["inputParameters"] = $fieldDef.inputParameters
		}
		# folder: true → DataSetFieldFolder (поле-папка для UI-группировки, только dataPath+title)
		if ($fieldDef.folder -eq $true) {
			$f["folder"] = $true
		}
	}

	# DataSetFieldFolder — только dataPath + title (для UI-группировки полей в композиторе)
	if ($f["folder"]) {
		X "$indent<field xsi:type=`"DataSetFieldFolder`">"
		X "$indent`t<dataPath>$(Esc-Xml $f.dataPath)</dataPath>"
		if ($f.title) { Emit-MLText -tag "title" -text $f.title -indent "$indent`t" }
		X "$indent</field>"
		return
	}

	X "$indent<field xsi:type=`"DataSetFieldField`">"
	X "$indent`t<dataPath>$(Esc-Xml $f.dataPath)</dataPath>"
	X "$indent`t<field>$(Esc-Xml $f.field)</field>"

	# Title
	if ($f.title) {
		Emit-MLText -tag "title" -text $f.title -indent "$indent`t"
	}

	# UseRestriction
	$restrictMap = @{
		"noField" = "field"; "noFilter" = "condition"; "noCondition" = "condition"
		"noGroup" = "group"; "noOrder" = "order"
	}
	if ($f.restrict.Count -gt 0) {
		X "$indent`t<useRestriction>"
		foreach ($r in $f.restrict) {
			$xmlName = $restrictMap["$r"]
			if ($xmlName) {
				X "$indent`t`t<$xmlName>true</$xmlName>"
			}
		}
		X "$indent`t</useRestriction>"
	}

	# AttributeUseRestriction
	if ($f["attrRestrict"] -and $f["attrRestrict"].Count -gt 0) {
		X "$indent`t<attributeUseRestriction>"
		foreach ($r in $f["attrRestrict"]) {
			$xmlName = $restrictMap["$r"]
			if ($xmlName) {
				X "$indent`t`t<$xmlName>true</$xmlName>"
			}
		}
		X "$indent`t</attributeUseRestriction>"
	}

	# Role
	$hasExtras = $f["roleExtras"] -and $f["roleExtras"].Count -gt 0
	if ($f.roles.Count -gt 0 -or $hasExtras) {
		X "$indent`t<role>"
		foreach ($role in $f.roles) {
			if ($role -eq "period") {
				# @period — sugar для periodNumber=1 + periodType=Main; extras могут переопределить.
				$pnInExtras = $hasExtras -and $f["roleExtras"].Contains('periodNumber')
				$ptInExtras = $hasExtras -and $f["roleExtras"].Contains('periodType')
				if (-not $pnInExtras) { X "$indent`t`t<dcscom:periodNumber>1</dcscom:periodNumber>" }
				if (-not $ptInExtras) { X "$indent`t`t<dcscom:periodType>Main</dcscom:periodType>" }
			} else {
				X "$indent`t`t<dcscom:$role>true</dcscom:$role>"
			}
		}
		if ($hasExtras) {
			foreach ($k in $f["roleExtras"].Keys) {
				X "$indent`t`t<dcscom:$k>$(Esc-Xml "$($f["roleExtras"][$k])")</dcscom:$k>"
			}
		}
		X "$indent`t</role>"
	}

	# OrderExpression — после role, до valueType. Допустим массив (multi-sort).
	if ($f["orderExpression"]) {
		$oeRaw = $f["orderExpression"]
		if ($oeRaw -is [System.Collections.IDictionary]) {
			$oeList = @($oeRaw)
		} elseif ($oeRaw -is [System.Collections.IList]) {
			$oeList = $oeRaw
		} else {
			$oeList = @($oeRaw)
		}
		foreach ($oe in $oeList) {
			$expr = if ($oe.expression) { "$($oe.expression)" } else { '' }
			$oType = if ($oe.orderType) { "$($oe.orderType)" } else { 'Asc' }
			$autoOrder = if ($null -ne $oe.autoOrder) { $(if ($oe.autoOrder) { 'true' } else { 'false' }) } else { 'false' }
			X "$indent`t<orderExpression>"
			X "$indent`t`t<dcscom:expression>$(Esc-Xml $expr)</dcscom:expression>"
			X "$indent`t`t<dcscom:orderType>$oType</dcscom:orderType>"
			X "$indent`t`t<dcscom:autoOrder>$autoOrder</dcscom:autoOrder>"
			X "$indent`t</orderExpression>"
		}
	}

	# ValueType
	if ($f.type) {
		X "$indent`t<valueType>"
		Emit-ValueType -typeStr $f.type -indent "$indent`t`t"
		X "$indent`t</valueType>"
	}

	# AvailableValues — list of allowed values with optional multilang presentation
	if ($f["availableValues"]) {
		foreach ($av in $f["availableValues"]) {
			X "$indent`t<availableValue>"
			$avVal = $av.value
			$avType = if ($av.valueType) { "$($av.valueType)" } else { '' }
			if (-not $avType) {
				if ($avVal -is [bool]) { $avType = 'xs:boolean' }
				elseif ($avVal -is [int] -or $avVal -is [long] -or $avVal -is [double]) { $avType = 'xs:decimal' }
				elseif ("$avVal" -match '^\d{4}-\d{2}-\d{2}T') { $avType = 'xs:dateTime' }
				else { $avType = 'xs:string' }
			}
			$avStr = if ($avVal -is [bool]) { "$avVal".ToLower() } else { Esc-Xml "$avVal" }
			X "$indent`t`t<value xsi:type=`"$avType`">$avStr</value>"
			if ($av.presentation) {
				Emit-MLText -tag "presentation" -text $av.presentation -indent "$indent`t`t"
			}
			X "$indent`t</availableValue>"
		}
	}

	# Appearance
	if ($f.appearance -and $f.appearance.Count -gt 0) {
		X "$indent`t<appearance>"
		foreach ($key in $f.appearance.Keys) {
			$val = $f.appearance[$key]
			# ГоризонтальноеПоложение требует специального xsi:type (v8ui:HorizontalAlign), не строка
			if ($key -eq "ГоризонтальноеПоложение" -and -not ($val -is [hashtable] -or $val -is [System.Collections.IDictionary] -or $val -is [PSCustomObject])) {
				X "$indent`t`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
				X "$indent`t`t`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"
				X "$indent`t`t`t<dcscor:value xsi:type=`"v8ui:HorizontalAlign`">$(Esc-Xml "$val")</dcscor:value>"
				X "$indent`t`t</dcscor:item>"
			} else {
				Emit-AppearanceValue -key $key -val $val -indent "$indent`t`t"
			}
		}
		X "$indent`t</appearance>"
	}

	# PresentationExpression
	if ($f["presentationExpression"]) {
		X "$indent`t<presentationExpression>$(Esc-Xml $f["presentationExpression"])</presentationExpression>"
	}

	# InputParameters — в конце field
	if ($f["inputParameters"]) {
		Emit-InputParameters -ip $f["inputParameters"] -indent "$indent`t"
	}

	X "$indent</field>"
}

# === DataSets ===
function Emit-DataSet {
	param($ds, [string]$indent, [string]$tagName = "dataSet")

	# Determine type
	if ($ds.items) {
		$dsType = "DataSetUnion"
	} elseif ($ds.objectName) {
		$dsType = "DataSetObject"
	} else {
		$dsType = "DataSetQuery"
	}

	X "$indent<$tagName xsi:type=`"$dsType`">"
	X "$indent`t<name>$(Esc-Xml "$($ds.name)")</name>"

	# Fields
	if ($ds.fields) {
		foreach ($f in $ds.fields) {
			Emit-Field -fieldDef $f -indent "$indent`t"
		}
	}

	# DataSource (not for Union)
	if ($dsType -ne "DataSetUnion") {
		$src = if ($ds.source) { "$($ds.source)" } else { $defaultSource }
		X "$indent`t<dataSource>$(Esc-Xml $src)</dataSource>"
	}

	# Type-specific content
	if ($dsType -eq "DataSetQuery") {
		$queryText = Resolve-QueryValue "$($ds.query)" $script:queryBaseDir
		X "$indent`t<query>$(Esc-Xml $queryText)</query>"
		if ($ds.autoFillFields -eq $false) {
			X "$indent`t<autoFillFields>false</autoFillFields>"
		}
	} elseif ($dsType -eq "DataSetObject") {
		X "$indent`t<objectName>$(Esc-Xml "$($ds.objectName)")</objectName>"
	} elseif ($dsType -eq "DataSetUnion") {
		foreach ($item in $ds.items) {
			# Union inner items are wrapped as <item xsi:type="...">
			Emit-DataSet -ds $item -indent "$indent`t" -tagName "item" | Out-Null
		}
	}

	X "$indent</$tagName>"
}

function Emit-DataSets {
	foreach ($ds in $def.dataSets) {
		Emit-DataSet -ds $ds -indent "`t"
	}
}

# === DataSetLinks ===
function Emit-DataSetLinks {
	if (-not $def.dataSetLinks) { return }
	foreach ($link in $def.dataSetLinks) {
		X "`t<dataSetLink>"
		$srcDS = if ($link.source) { "$($link.source)" } elseif ($link.sourceDataSet) { "$($link.sourceDataSet)" } else { "" }
		$dstDS = if ($link.dest) { "$($link.dest)" } elseif ($link.destinationDataSet) { "$($link.destinationDataSet)" } else { "" }
		$srcEx = if ($link.sourceExpr) { "$($link.sourceExpr)" } elseif ($link.sourceExpression) { "$($link.sourceExpression)" } else { "" }
		$dstEx = if ($link.destExpr) { "$($link.destExpr)" } elseif ($link.destinationExpression) { "$($link.destinationExpression)" } else { "" }
		X "`t`t<sourceDataSet>$(Esc-Xml $srcDS)</sourceDataSet>"
		X "`t`t<destinationDataSet>$(Esc-Xml $dstDS)</destinationDataSet>"
		X "`t`t<sourceExpression>$(Esc-Xml $srcEx)</sourceExpression>"
		X "`t`t<destinationExpression>$(Esc-Xml $dstEx)</destinationExpression>"
		if ($link.parameter) {
			X "`t`t<parameter>$(Esc-Xml "$($link.parameter)")</parameter>"
		}
		if ($link.PSObject.Properties.Match('parameterListAllowed').Count -gt 0 -and $link.parameterListAllowed) {
			X "`t`t<parameterListAllowed>true</parameterListAllowed>"
		}
		if ($link.PSObject.Properties.Match('startExpression').Count -gt 0 -and $null -ne $link.startExpression) {
			X "`t`t<startExpression>$(Esc-Xml "$($link.startExpression)")</startExpression>"
		}
		if ($link.PSObject.Properties.Match('linkConditionExpression').Count -gt 0 -and $null -ne $link.linkConditionExpression) {
			X "`t`t<linkConditionExpression>$(Esc-Xml "$($link.linkConditionExpression)")</linkConditionExpression>"
		}
		X "`t</dataSetLink>"
	}
}

# === CalculatedFields ===
function Emit-CalcFields {
	if (-not $def.calculatedFields) { return }
	$restrictMap = @{
		"noField" = "field"; "noFilter" = "condition"; "noCondition" = "condition"
		"noGroup" = "group"; "noOrder" = "order"
	}
	foreach ($cf in $def.calculatedFields) {
		# Collect dataPath/expression/title/type/restrict/appearance from either
		# shorthand string or object form. Object form accepts dataPath/field/name
		# as synonyms; useRestriction/restrict accepts object, array, or flag string.
		$title = ""
		$typeStr = ""
		$restrictTokens = @()
		$restrictObj = $null
		$appearance = $null

		if ($cf -is [string]) {
			$parsed = Parse-CalcShorthand $cf
			$dataPath = "$($parsed.dataPath)"
			$expression = "$($parsed.expression)"
			$title = $parsed.title
			$typeStr = "$($parsed.type)"
			if ($parsed.restrict) { $restrictTokens = @($parsed.restrict) }
		} else {
			$dataPath = if ($cf.dataPath) { "$($cf.dataPath)" }
				elseif ($cf.field) { "$($cf.field)" }
				else { "$($cf.name)" }
			$expression = "$($cf.expression)"
			if ($cf.title) { $title = $cf.title }
			if ($cf.type) { $typeStr = Resolve-TypeStr "$($cf.type)" }

			$restrictVal = if ($cf.restrict) { $cf.restrict } elseif ($cf.useRestriction) { $cf.useRestriction } else { $null }
			if ($restrictVal) {
				if ($restrictVal -is [System.Management.Automation.PSCustomObject] -or $restrictVal -is [hashtable]) {
					$restrictObj = $restrictVal
				} elseif ($restrictVal -is [string]) {
					# Flag-string form: "#noField #noFilter #noGroup #noOrder" (or without `#`)
					foreach ($tok in ($restrictVal -split '\s+')) {
						$t = $tok.Trim().TrimStart('#')
						if ($t) { $restrictTokens += $t }
					}
				} else {
					# Array form: ["noField", "noFilter", ...]
					foreach ($r in $restrictVal) { $restrictTokens += "$r" }
				}
			}
			if ($cf.appearance) { $appearance = $cf.appearance }
		}

		X "`t<calculatedField>"
		X "`t`t<dataPath>$(Esc-Xml $dataPath)</dataPath>"
		X "`t`t<expression>$(Esc-Xml $expression)</expression>"

		if ($title) {
			Emit-MLText -tag "title" -text $title -indent "`t`t"
		}
		if ($typeStr) {
			X "`t`t<valueType>"
			Emit-ValueType -typeStr $typeStr -indent "`t`t`t"
			X "`t`t</valueType>"
		}
		if ($restrictObj -or $restrictTokens.Count -gt 0) {
			X "`t`t<useRestriction>"
			if ($restrictObj) {
				foreach ($prop in $restrictObj.PSObject.Properties) {
					if ($prop.Value -eq $true) {
						X "`t`t`t<$($prop.Name)>true</$($prop.Name)>"
					}
				}
			} else {
				foreach ($r in $restrictTokens) {
					$xmlName = $restrictMap["$r"]
					if ($xmlName) { X "`t`t`t<$xmlName>true</$xmlName>" }
				}
			}
			X "`t`t</useRestriction>"
		}
		if ($appearance) {
			X "`t`t<appearance>"
			foreach ($prop in $appearance.PSObject.Properties) {
				# ГоризонтальноеПоложение — особый xsi:type (если не multilang)
				if ($prop.Name -eq "ГоризонтальноеПоложение" -and -not ($prop.Value -is [hashtable] -or $prop.Value -is [System.Collections.IDictionary] -or $prop.Value -is [PSCustomObject])) {
					X "`t`t`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
					X "`t`t`t`t<dcscor:parameter>$(Esc-Xml $prop.Name)</dcscor:parameter>"
					X "`t`t`t`t<dcscor:value xsi:type=`"v8ui:HorizontalAlign`">$(Esc-Xml "$($prop.Value)")</dcscor:value>"
					X "`t`t`t</dcscor:item>"
				} else {
					Emit-AppearanceValue -key $prop.Name -val $prop.Value -indent "`t`t`t"
				}
			}
			X "`t`t</appearance>"
		}

		X "`t</calculatedField>"
	}
}

# === TotalFields ===
function Emit-TotalFields {
	if (-not $def.totalFields) { return }
	foreach ($tf in $def.totalFields) {
		if ($tf -is [string]) {
			$parsed = Parse-TotalShorthand $tf
		} else {
			$parsed = @{
				dataPath = "$($tf.dataPath)"
				expression = "$($tf.expression)"
			}
			if ($tf.group) { $parsed.groups = @($tf.group) }
		}

		X "`t<totalField>"
		X "`t`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
		X "`t`t<expression>$(Esc-Xml $parsed.expression)</expression>"
		if ($parsed.groups) {
			foreach ($g in $parsed.groups) {
				X "`t`t<group>$(Esc-Xml "$g")</group>"
			}
		}
		X "`t</totalField>"
	}
}

# === Parameters ===

function Emit-SingleParam {
	param($p, $parsed)

	X "`t<parameter>"
	X "`t`t<name>$(Esc-Xml $parsed.name)</name>"

	# Title (from parsed first, then from object form; accept `presentation` as
	# a synonym — 1C UI labels a parameter's caption "Представление").
	$title = ""
	if ($parsed.title) {
		$title = $parsed.title
	} elseif ($p -isnot [string] -and $p.title) {
		$title = $p.title
	} elseif ($p -isnot [string] -and $p.presentation) {
		$title = $p.presentation
	}
	if ($title) {
		Emit-MLText -tag "title" -text $title -indent "`t`t"
	}

	# ValueType
	if ($parsed.type) {
		X "`t`t<valueType>"
		Emit-ValueType -typeStr $parsed.type -indent "`t`t`t"
		X "`t`t</valueType>"
	}

	# Value — for valueListAllowed params Designer omits <value> when empty
	$vla = [bool]$parsed.valueListAllowed
	# Multi-value (массив значений по умолчанию для valueListAllowed-параметра) — эмитим
	# каждый отдельным <value>. Различаем массив значений от composite type (тоже array,
	# но в parsed.type).
	$valIsArray = ($parsed.value -is [array]) -or ($parsed.value -is [System.Collections.IList] -and $parsed.value -isnot [string])
	if ($parsed.type -is [array] -or $parsed.type -is [System.Collections.IList]) {
		# Composite type — Designer writes xsi:nil for any empty composite;
		# non-empty composite values are uncommon and would need per-type tagging.
		if (Test-EmptyValue $parsed.value) {
			if (-not $vla) { X "`t`t<value xsi:nil=`"true`"/>" }
		}
	} elseif ($parsed.nilValue -eq $true) {
		# Принудительный xsi:nil даже когда тип известен (для bit-perfect round-trip).
		if (-not $vla) { X "`t`t<value xsi:nil=`"true`"/>" }
	} elseif ($valIsArray) {
		foreach ($v in @($parsed.value)) {
			Emit-ParamValue -type $parsed.type -val $v -indent "`t`t" -valueListAllowed $false
		}
	} else {
		Emit-ParamValue -type $parsed.type -val $parsed.value -indent "`t`t" -valueListAllowed $vla
	}

	# Hidden implies useRestriction=true + availableAsField=false
	if ($parsed.hidden -eq $true) {
		$parsed.availableAsField = $false
		$parsed.useRestriction = $true
	}

	# UseRestriction — платформа всегда эмитит этот тег у параметра (true/false)
	$urEmit = $false
	if ($parsed.useRestriction -eq $true) { $urEmit = $true }
	elseif ($p -isnot [string] -and $p.useRestriction -eq $true) { $urEmit = $true }
	X ("`t`t<useRestriction>" + $(if ($urEmit) { 'true' } else { 'false' }) + "</useRestriction>")

	# Expression
	if ($parsed.expression) {
		X "`t`t<expression>$(Esc-Xml $parsed.expression)</expression>"
	}

	# AvailableAsField
	if ($parsed.availableAsField -eq $false) {
		X "`t`t<availableAsField>false</availableAsField>"
	}

	# ValueListAllowed
	if ($parsed.valueListAllowed -eq $true) {
		X "`t`t<valueListAllowed>true</valueListAllowed>"
	}

	# AvailableValues
	if ($p -isnot [string] -and $p.availableValues) {
		foreach ($av in $p.availableValues) {
			X "`t`t<availableValue>"
			if (Test-EmptyValue $av.value) {
				Emit-EmptyValue -type $parsed.type -indent "`t`t`t" -tagPrefix "" -valueListAllowed $false
			} else {
				$av_v = $av.value
				if ($av_v -is [bool]) {
					$bv = "$av_v".ToLower()
					X "`t`t`t<value xsi:type=`"xs:boolean`">$bv</value>"
				} elseif ($av_v -is [int] -or $av_v -is [long] -or $av_v -is [double]) {
					X "`t`t`t<value xsi:type=`"xs:decimal`">$av_v</value>"
				} else {
					$avVal = "$av_v"
					$avType = "xs:string"
					if ($avVal -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.') {
						$avType = "dcscor:DesignTimeValue"
					}
					X "`t`t`t<value xsi:type=`"$avType`">$(Esc-Xml $avVal)</value>"
				}
			}
			# `title` accepted as synonym of `presentation` — both map to the same UI label.
			$avPres = if ($av.presentation) { $av.presentation } elseif ($av.title) { $av.title } else { "" }
			if ($avPres) {
				Emit-MLText -tag "presentation" -text $avPres -indent "`t`t`t"
			}
			X "`t`t</availableValue>"
		}
	}

	# DenyIncompleteValues
	$deny = $parsed.denyIncompleteValues -eq $true -or (
		$null -ne $p -and $p -isnot [string] -and $p.denyIncompleteValues -eq $true)
	if ($deny) {
		X "`t`t<denyIncompleteValues>true</denyIncompleteValues>"
	}

	# Use — object form wins, else parsed (set by @autoDates default)
	$useVal = $null
	if ($null -ne $p -and $p -isnot [string] -and $p.use) { $useVal = "$($p.use)" }
	elseif ($parsed.use) { $useVal = "$($parsed.use)" }
	if ($useVal) {
		X "`t`t<use>$(Esc-Xml $useVal)</use>"
	}

	# InputParameters на параметре (ФорматРедактирования и т.п.)
	if ($null -ne $p -and $p -isnot [string] -and $p.inputParameters) {
		Emit-InputParameters -ip $p.inputParameters -indent "`t`t"
	}

	X "`t</parameter>"
}

$script:allParams = @()

function Emit-Parameters {
	if (-not $def.parameters) { return }
	foreach ($p in $def.parameters) {
		if ($p -is [string]) {
			$parsed = Parse-ParamShorthand $p
		} else {
			# Composite type: ["string(10,fix)", "CatalogRef.X"] → array of resolved
			# strings; emit-valueType handles arrays, empty value falls through to nil.
			$resolvedType = ""
			if ($p.type) {
				if ($p.type -is [array] -or $p.type -is [System.Collections.IList]) {
					$resolvedType = @($p.type | ForEach-Object { Resolve-TypeStr "$_" })
				} else {
					$resolvedType = Resolve-TypeStr "$($p.type)"
				}
			}
			$parsed = @{
				name = "$($p.name)"
				type = $resolvedType
				value = $p.value
				autoDates = $false
			}
			if ($p.expression) { $parsed.expression = "$($p.expression)" }
			if ($p.availableAsField -eq $false) { $parsed.availableAsField = $false }
			if ($p.valueListAllowed -eq $true) { $parsed.valueListAllowed = $true }
			if ($p.hidden -eq $true) { $parsed.hidden = $true }
			if ($p.autoDates -eq $true) { $parsed.autoDates = $true }
			if ($p.nilValue -eq $true) { $parsed.nilValue = $true }
		}

		# @autoDates implies use=Always + denyIncompleteValues=true by default
		# (derived &НачалоПериода/&КонецПериода need a populated period).
		# Explicit values in object form override these defaults.
		if ($parsed.autoDates) {
			$isObj = ($p -isnot [string]) -and ($null -ne $p)
			if (-not ($isObj -and $null -ne $p.use)) { $parsed.use = 'Always' }
			if (-not ($isObj -and $null -ne $p.denyIncompleteValues)) { $parsed.denyIncompleteValues = $true }
		}

		Emit-SingleParam -p $p -parsed $parsed

		# Track parameter for auto dataParameters
		$script:allParams += @{ name = $parsed.name; hidden = [bool]$parsed.hidden; type = "$($parsed.type)"; value = $parsed.value }

		# @autoDates: auto-generate НачалоПериода and КонецПериода (canonical БСП pattern).
		# type=dateTime + DateFractions=DateTime — иначе КонецПериода обрезается до 00:00:00
		# и запрос `Дата МЕЖДУ &НачалоПериода И &КонецПериода` теряет данные за последний день.
		if ($parsed.autoDates) {
			$paramName = $parsed.name
			$beginParsed = @{
				name = "НачалоПериода"; title = "Начало периода"
				type = "dateTime"; value = "0001-01-01T00:00:00"
				useRestriction = $true
				expression = "&$paramName.ДатаНачала"
			}
			Emit-SingleParam -p $null -parsed $beginParsed
			$endParsed = @{
				name = "КонецПериода"; title = "Конец периода"
				type = "dateTime"; value = "0001-01-01T00:00:00"
				useRestriction = $true
				expression = "&$paramName.ДатаОкончания"
			}
			Emit-SingleParam -p $null -parsed $endParsed
		}
	}
}

function Test-EmptyValue {
	param($v)
	if ($null -eq $v) { return $true }
	$s = "$v".Trim()
	if ($s -eq "") { return $true }
	if ($s -eq "_") { return $true }
	if ($s.ToLowerInvariant() -eq "null") { return $true }
	return $false
}

function Emit-EmptyValue {
	param([string]$type, [string]$indent, [string]$tagPrefix = "", [bool]$valueListAllowed = $false)

	if ($valueListAllowed) { return }
	$t = if ($null -eq $type) { "" } else { "$type" }
	# Нормализация: убираем префикс xs: (валидный для valueType из decompile/DSL)
	$tBare = if ($t -match '^xs:(.+)$') { $matches[1] } else { $t }
	$pf = $tagPrefix

	if ($t -eq "") {
		X "$indent<${pf}value xsi:nil=`"true`"/>"
	} elseif ($t -eq "StandardPeriod") {
		X "$indent<${pf}value xsi:type=`"v8:StandardPeriod`">"
		X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">Custom</v8:variant>"
		X "$indent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
		X "$indent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
		X "$indent</${pf}value>"
	} elseif ($tBare -match '^string') {
		X "$indent<${pf}value xsi:type=`"xs:string`"/>"
	} elseif ($tBare -match '^(date|time)') {
		X "$indent<${pf}value xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</${pf}value>"
	} elseif ($tBare -match '^decimal') {
		X "$indent<${pf}value xsi:type=`"xs:decimal`">0</${pf}value>"
	} elseif ($tBare -eq "boolean") {
		X "$indent<${pf}value xsi:type=`"xs:boolean`">false</${pf}value>"
	} else {
		# Ref types or unknown — safe nil
		X "$indent<${pf}value xsi:nil=`"true`"/>"
	}
}

function Emit-ParamValue {
	param([string]$type, $val, [string]$indent, [bool]$valueListAllowed = $false)

	if (Test-EmptyValue $val) {
		Emit-EmptyValue -type $type -indent $indent -tagPrefix "" -valueListAllowed $valueListAllowed
		return
	}

	# val может быть строкой (variant only) или объектом {variant, startDate?, endDate?}.
	$valIsDict = ($val -is [hashtable]) -or ($val -is [System.Collections.IDictionary]) -or ($val -is [PSCustomObject])
	$variantStr = $null
	$sdStr = $null
	$edStr = $null
	if ($valIsDict) {
		if ($val -is [PSCustomObject]) {
			if ($val.PSObject.Properties['variant'])   { $variantStr = "$($val.variant)" }
			if ($val.PSObject.Properties['startDate']) { $sdStr = "$($val.startDate)" }
			if ($val.PSObject.Properties['endDate'])   { $edStr = "$($val.endDate)" }
		} else {
			if ($val.Contains('variant'))   { $variantStr = "$($val['variant'])" }
			if ($val.Contains('startDate')) { $sdStr = "$($val['startDate'])" }
			if ($val.Contains('endDate'))   { $edStr = "$($val['endDate'])" }
		}
	}
	$valStr = if ($variantStr) { $variantStr } else { "$val" }

	if ($type -eq "StandardPeriod") {
		# Platform-pattern: startDate/endDate эмитятся ТОЛЬКО для variant=Custom.
		# Для всех остальных вариантов (ThisMonth, LastYear, Today, ...) — без дат.
		X "$indent<value xsi:type=`"v8:StandardPeriod`">"
		X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $valStr)</v8:variant>"
		if ($valStr -eq 'Custom') {
			$sdOut = if ($sdStr) { $sdStr } else { '0001-01-01T00:00:00' }
			$edOut = if ($edStr) { $edStr } else { '0001-01-01T00:00:00' }
			X "$indent`t<v8:startDate>$(Esc-Xml $sdOut)</v8:startDate>"
			X "$indent`t<v8:endDate>$(Esc-Xml $edOut)</v8:endDate>"
		}
		X "$indent</value>"
	} elseif ($type -match '^date') {
		X "$indent<value xsi:type=`"xs:dateTime`">$(Esc-Xml $valStr)</value>"
	} elseif ($type -eq "boolean") {
		X "$indent<value xsi:type=`"xs:boolean`">$(Esc-Xml $valStr)</value>"
	} elseif ($type -match '^decimal') {
		X "$indent<value xsi:type=`"xs:decimal`">$(Esc-Xml $valStr)</value>"
	} elseif ($type -match '^string') {
		X "$indent<value xsi:type=`"xs:string`">$(Esc-Xml $valStr)</value>"
	} elseif ($type -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef)\.') {
		X "$indent<value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml $valStr)</value>"
	} else {
		# Guess from value
		if ($valStr -match '^\d{4}-\d{2}-\d{2}T') {
			X "$indent<value xsi:type=`"xs:dateTime`">$(Esc-Xml $valStr)</value>"
		} elseif ($valStr -eq "true" -or $valStr -eq "false") {
			X "$indent<value xsi:type=`"xs:boolean`">$(Esc-Xml $valStr)</value>"
		} elseif ($valStr -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or $valStr -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') {
			X "$indent<value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml $valStr)</value>"
		} else {
			X "$indent<value xsi:type=`"xs:string`">$(Esc-Xml $valStr)</value>"
		}
	}
}

# === AreaTemplate DSL ===

# Built-in style presets
$script:areaStylePresets = @{
	none = @{
		font = $null; fontSize = $null; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = $null; textColor = $null
		borderColor = $null; borders = $false
	}
	data = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = 'style:ReportGroup1BackColor'; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	header = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = 'Center'; vAlign = $null; wrap = $true
		bgColor = 'style:ReportHeaderBackColor'; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	subheader = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = 'Center'; vAlign = $null; wrap = $true
		bgColor = $null; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	total = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = $null; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
}

# Load user presets from skd-styles.json
# Search order (first found wins): 1) definition dir, 2) cwd, 3) scan-up from OutputPath for presets/skills/skd/
$script:userStylesLoaded = $false
$searchPaths = @(
	(Join-Path $script:queryBaseDir "skd-styles.json"),
	(Join-Path (Get-Location).Path "skd-styles.json")
)
$outResolved = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location).Path $OutputPath }
$scanDir = [System.IO.Path]::GetDirectoryName($outResolved)
while ($scanDir) {
	$searchPaths += Join-Path (Join-Path (Join-Path (Join-Path $scanDir "presets") "skills") "skd") "skd-styles.json"
	$parentDir = Split-Path $scanDir -Parent
	if ($parentDir -eq $scanDir) { break }
	$scanDir = $parentDir
}
foreach ($stylesFile in $searchPaths) {
	if (Test-Path $stylesFile) {
		$userStyles = Get-Content -Raw -Encoding UTF8 $stylesFile | ConvertFrom-Json
		foreach ($prop in $userStyles.PSObject.Properties) {
			$preset = @{}
			# Start from 'data' defaults
			foreach ($k in $script:areaStylePresets['data'].Keys) {
				$preset[$k] = $script:areaStylePresets['data'][$k]
			}
			# If overriding existing preset, start from it instead
			if ($script:areaStylePresets.ContainsKey($prop.Name)) {
				foreach ($k in $script:areaStylePresets[$prop.Name].Keys) {
					$preset[$k] = $script:areaStylePresets[$prop.Name][$k]
				}
			}
			# Apply user overrides
			foreach ($up in $prop.Value.PSObject.Properties) {
				$preset[$up.Name] = $up.Value
			}
			$script:areaStylePresets[$prop.Name] = $preset
		}
		$script:userStylesLoaded = $true
		break
	}
}

function Emit-ColorValue {
	param([string]$color, [string]$indent)
	# Префиксы style:/web:/win: → соответствующий xmlns + dN:Name
	$colorPrefixToUri = @{
		'style:' = 'http://v8.1c.ru/8.1/data/ui/style'
		'web:'   = 'http://v8.1c.ru/8.1/data/ui/colors/web'
		'win:'   = 'http://v8.1c.ru/8.1/data/ui/colors/windows'
	}
	foreach ($pfx in $colorPrefixToUri.Keys) {
		if ($color.StartsWith($pfx)) {
			$name = $color.Substring($pfx.Length)
			$uri = $colorPrefixToUri[$pfx]
			X "$indent<dcscor:value xmlns:d8p1=`"$uri`" xsi:type=`"v8ui:Color`">d8p1:$name</dcscor:value>"
			return
		}
	}
	X "$indent<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $color)</dcscor:value>"
}

function Emit-CellAppearance {
	param($style, [double]$width = 0, [bool]$vMerge = $false, [bool]$hMerge = $false, [double]$minHeight = 0, $extraItems = @())
	$ind = "`t`t`t`t`t`t"
	# Если ничего внутри appearance не будет — не эмитим блок вовсе
	# (оригинал платформы для cells без атрибутов не пишет <appearance></appearance>).
	$hasContent = $style.bgColor -or $style.textColor -or $style.borders -or $style.font -or `
		$style.hAlign -or $style.vAlign -or $style.wrap -or `
		($width -gt 0) -or ($minHeight -gt 0) -or $vMerge -or $hMerge -or `
		($extraItems -and @($extraItems).Count -gt 0)
	if (-not $hasContent) { return }
	X "`t`t`t`t`t<dcsat:appearance>"
	# Background color
	if ($style.bgColor) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ЦветФона</dcscor:parameter>"
		Emit-ColorValue $style.bgColor "$ind`t"
		X "$ind</dcscor:item>"
	}
	# Text color
	if ($style.textColor) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ЦветТекста</dcscor:parameter>"
		Emit-ColorValue $style.textColor "$ind`t"
		X "$ind</dcscor:item>"
	}
	# Border color + border style (4 sides)
	if ($style.borders) {
		if ($style.borderColor) {
			X "$ind<dcscor:item>"
			X "$ind`t<dcscor:parameter>ЦветГраницы</dcscor:parameter>"
			Emit-ColorValue $style.borderColor "$ind`t"
			X "$ind</dcscor:item>"
		}
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>СтильГраницы</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"v8ui:Line`" width=`"0`" gap=`"false`">"
		X "$ind`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">None</v8ui:style>"
		X "$ind`t</dcscor:value>"
		foreach ($side in @('Слева','Сверху','Справа','Снизу')) {
			X "$ind`t<dcscor:item>"
			X "$ind`t`t<dcscor:parameter>СтильГраницы.$side</dcscor:parameter>"
			X "$ind`t`t<dcscor:value xsi:type=`"v8ui:Line`" width=`"1`" gap=`"false`">"
			X "$ind`t`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">Solid</v8ui:style>"
			X "$ind`t`t</dcscor:value>"
			X "$ind`t</dcscor:item>"
		}
		X "$ind</dcscor:item>"
	}
	# Font (skip if style has no font configured — for "none" preset)
	if ($style.font) {
		$boldStr = if ($style.bold) { "true" } else { "false" }
		$italicStr = if ($style.italic) { "true" } else { "false" }
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>Шрифт</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"v8ui:Font`" faceName=`"$($style.font)`" height=`"$($style.fontSize)`" bold=`"$boldStr`" italic=`"$italicStr`" underline=`"false`" strikeout=`"false`" kind=`"Absolute`" scale=`"100`"/>"
		X "$ind</dcscor:item>"
	}
	# Horizontal alignment
	if ($style.hAlign) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ГоризонтальноеПоложение</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"v8ui:HorizontalAlign`">$(Esc-Xml $style.hAlign)</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Vertical alignment
	if ($style.vAlign) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ВертикальноеПоложение</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"v8ui:VerticalAlign`">$(Esc-Xml $style.vAlign)</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Text placement (wrap)
	if ($style.wrap) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>Размещение</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"dcscor:DataCompositionTextPlacementType`">Wrap</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Width
	if ($width -gt 0) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>МинимальнаяШирина</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:decimal`">$width</dcscor:value>"
		X "$ind</dcscor:item>"
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>МаксимальнаяШирина</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:decimal`">$width</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Min height
	if ($minHeight -gt 0) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>МинимальнаяВысота</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:decimal`">$minHeight</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Vertical merge
	if ($vMerge) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ОбъединятьПоВертикали</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:boolean`">true</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Horizontal merge
	if ($hMerge) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ОбъединятьПоГоризонтали</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:boolean`">true</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Extra appearance items (e.g. drilldown Расшифровка)
	foreach ($ei in $extraItems) { X $ei }
	X "`t`t`t`t`t</dcsat:appearance>"
}

# Cell может быть string ("text"/"{param}"/"|"/">"/null) или объектом {value, style}.
# Helpers извлекают значение и эффективный стиль ячейки.
function Get-CellValue {
	param($cell)
	if ($null -eq $cell) { return $null }
	if ($cell -is [string]) { return $cell }
	if ($cell -is [hashtable] -or $cell -is [System.Collections.IDictionary]) {
		if ($cell.Contains('value')) { return $cell['value'] }
		return $cell  # multilang dict без обёртки
	}
	if ($cell.PSObject -and $cell.PSObject.Properties['value']) { return $cell.value }
	# PSCustomObject без 'value' — это multilang dict ({ru, en, ...}), отдаём как есть
	if ($cell -is [PSCustomObject]) { return $cell }
	return $null
}

function Get-CellStyleOrDefault {
	param($cell, $defaultStyle)
	if ($null -ne $cell -and -not ($cell -is [string]) -and $cell.PSObject -and $cell.PSObject.Properties['style']) {
		$sName = "$($cell.style)"
		if ($script:areaStylePresets.ContainsKey($sName)) {
			return $script:areaStylePresets[$sName]
		}
		Write-Warning "Unknown cell style preset '$sName', falling back to template default"
	}
	return $defaultStyle
}

function Emit-AreaTemplateDSL {
	param($t)
	$styleName = if ($t.style) { "$($t.style)" } else { "data" }
	if (-not $script:areaStylePresets.ContainsKey($styleName)) {
		Write-Warning "Unknown area style preset '$styleName', falling back to 'data'"
		$styleName = "data"
	}
	$style = $script:areaStylePresets[$styleName]

	$rows = @($t.rows)
	# PS-quirk: if-expression unwraps single-element @() результат
	# (`$x = if (...) { @($arr) }` даёт скаляр при одном элементе).
	# Используем обычный if вместо if-expression.
	$widths = @()
	if ($t.widths) { $widths = @($t.widths) }
	$minHeight = if ($t.minHeight) { [double]$t.minHeight } else { 0 }
	$colCount = if ($widths.Count -gt 0) { $widths.Count } else { $rows[0].Count }

	# Build vertical merge map: vMerge[row][col] = $true if cell is merged with above
	$vMerge = @{}
	for ($r = $rows.Count - 1; $r -ge 1; $r--) {
		$vMerge[$r] = @{}
		for ($c = 0; $c -lt $colCount; $c++) {
			$cellValStr = Get-CellValue $rows[$r][$c]
			if ($cellValStr -eq '|') { $vMerge[$r][$c] = $true }
		}
	}
	if (-not $vMerge.ContainsKey(0)) { $vMerge[0] = @{} }

	# Build horizontal merge map: hMerge[row][col] = $true if cell is merged with left
	$hMerge = @{}
	for ($r = 0; $r -lt $rows.Count; $r++) {
		$hMerge[$r] = @{}
		for ($c = 0; $c -lt $colCount; $c++) {
			$cellValStr = Get-CellValue $rows[$r][$c]
			if ($cellValStr -eq '>') { $hMerge[$r][$c] = $true }
		}
	}

	# Build drilldown map: param_name -> drilldown_value (только для shortcut-формы — drilldown:string).
	# Форма C (drilldown:object) — DetailsAreaTemplateParameter с произвольным именем, в map не идёт.
	$drilldownMap = @{}
	if ($t.parameters) {
		foreach ($tp in $t.parameters) {
			if ($tp.drilldown -and ($tp.drilldown -is [string])) {
				$drilldownMap["$($tp.name)"] = "$($tp.drilldown)"
			}
		}
	}

	X "`t<template>"
	X "`t`t<name>$(Esc-Xml "$($t.name)")</name>"
	X "`t`t<template xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:AreaTemplate`">"

	for ($r = 0; $r -lt $rows.Count; $r++) {
		X "`t`t`t<dcsat:item xsi:type=`"dcsat:TableRow`">"
		for ($c = 0; $c -lt $colCount; $c++) {
			$cellRaw = $rows[$r][$c]
			$cellVal = Get-CellValue $cellRaw
			$cellStyle = Get-CellStyleOrDefault $cellRaw $style
			$w = if ($c -lt $widths.Count) { [double]$widths[$c] } else { 0 }
			$isVMerged = $vMerge[$r][$c] -eq $true
			$isHMerged = $hMerge[$r][$c] -eq $true
			X "`t`t`t`t<dcsat:tableCell>"
			if ($isVMerged) {
				# Vertically merged cell — only appearance with vMerge flag + width
				Emit-CellAppearance $cellStyle $w $true
			} elseif ($isHMerged) {
				# Horizontally merged cell — only appearance with hMerge flag + width
				Emit-CellAppearance $cellStyle $w $false $true
			} else {
				# Cell value
				$cellIsDict = ($cellVal -is [hashtable]) -or ($cellVal -is [System.Collections.IDictionary]) -or ($cellVal -is [PSCustomObject])
				if ($cellIsDict) {
					# Multilang static text — эмитим напрямую с lwsTitle-подобной структурой
					X "`t`t`t`t`t<dcsat:item xsi:type=`"dcsat:Field`">"
					Emit-MLText -tag "dcsat:value" -text $cellVal -indent "`t`t`t`t`t`t"
					X "`t`t`t`t`t</dcsat:item>"
					$cellExtraItems = @()
				} elseif ($null -ne $cellVal -and $cellVal -ne '') {
					$cellStr = "$cellVal"
					# Unescape \| and \>
					if ($cellStr -eq '\|') { $cellStr = '|' }
					elseif ($cellStr -eq '\>') { $cellStr = '>' }
					if ($cellStr -match '^\{(.+)\}$') {
						# Parameter reference
						$paramName = $Matches[1]
						X "`t`t`t`t`t<dcsat:item xsi:type=`"dcsat:Field`">"
						X "`t`t`t`t`t`t<dcsat:value xsi:type=`"dcscor:Parameter`">$(Esc-Xml $paramName)</dcsat:value>"
						X "`t`t`t`t`t</dcsat:item>"
						# Build drilldown appearance extra items.
						# Приоритет: per-cell override (cell={value, drilldown}) → drilldownMap (shortcut form B).
						$cellExtraItems = @()
						$cellDrillOverride = $null
						if ($cellRaw -is [PSCustomObject] -and $cellRaw.PSObject.Properties['drilldown']) {
							$cellDrillOverride = "$($cellRaw.drilldown)"
						} elseif (($cellRaw -is [hashtable] -or $cellRaw -is [System.Collections.IDictionary]) -and $cellRaw.Contains('drilldown')) {
							$cellDrillOverride = "$($cellRaw['drilldown'])"
						}
						$ddTarget = $null
						if ($cellDrillOverride) {
							$ddTarget = $cellDrillOverride
						} elseif ($drilldownMap.ContainsKey($paramName)) {
							$ddTarget = "Расшифровка_$($drilldownMap[$paramName])"
						}
						if ($ddTarget) {
							$cellExtraItems += "`t`t`t`t`t`t<dcscor:item>"
							$cellExtraItems += "`t`t`t`t`t`t`t<dcscor:parameter>Расшифровка</dcscor:parameter>"
							$cellExtraItems += "`t`t`t`t`t`t`t<dcscor:value xsi:type=`"dcscor:Parameter`">$(Esc-Xml $ddTarget)</dcscor:value>"
							$cellExtraItems += "`t`t`t`t`t`t</dcscor:item>"
						}
					} else {
						# Static text
						X "`t`t`t`t`t<dcsat:item xsi:type=`"dcsat:Field`">"
						Emit-MLText -tag "dcsat:value" -text $cellStr -indent "`t`t`t`t`t`t"
						X "`t`t`t`t`t</dcsat:item>"
					}
				}
				# Appearance
				$h = if ($r -eq 0) { $minHeight } else { 0 }
				if (-not $cellExtraItems) { $cellExtraItems = @() }
				Emit-CellAppearance $cellStyle $w $false $false $h $cellExtraItems
				$cellExtraItems = @()
			}
			X "`t`t`t`t</dcsat:tableCell>"
		}
		X "`t`t`t</dcsat:item>"
	}

	X "`t`t</template>"
	# Parameters (reuse existing logic)
	if ($t.parameters) {
		foreach ($tp in $t.parameters) {
			Emit-AreaTemplateParameter -tp $tp -indent "`t`t"
		}
	}
	X "`t</template>"
}

# Эмиссия одного параметра шаблона. Различает три формы:
#   A. { name, expression }                                  → ExpressionAreaTemplateParameter
#   B. { name, expression, drilldown: "X" }                  → Expression + Details(Расшифровка_X, ИмяРесурса, DrillDown) [shortcut]
#   C. { name, drilldown: { field, expression, action? } }   → DetailsAreaTemplateParameter с произвольным name
function Emit-AreaTemplateParameter {
	param($tp, [string]$indent)
	# Определяем форму C: drilldown — объект с полем field или expression.
	$dd = $tp.drilldown
	$ddIsObject = $false
	if ($null -ne $dd) {
		if ($dd -is [hashtable] -or $dd -is [System.Collections.IDictionary]) { $ddIsObject = $true }
		elseif ($dd -is [PSCustomObject]) { $ddIsObject = $true }
	}
	if ($ddIsObject) {
		# Форма C
		$ddField = if ($dd -is [PSCustomObject]) { "$($dd.field)" } else { "$($dd['field'])" }
		$ddExpr  = if ($dd -is [PSCustomObject]) { "$($dd.expression)" } else { "$($dd['expression'])" }
		$ddActV  = $null
		if ($dd -is [PSCustomObject] -and $dd.PSObject.Properties['action']) { $ddActV = "$($dd.action)" }
		elseif (($dd -is [hashtable] -or $dd -is [System.Collections.IDictionary]) -and $dd.Contains('action')) { $ddActV = "$($dd['action'])" }
		$ddAct = if ($ddActV) { $ddActV } else { 'DrillDown' }
		X "$indent<parameter xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:DetailsAreaTemplateParameter`">"
		X "$indent`t<dcsat:name>$(Esc-Xml "$($tp.name)")</dcsat:name>"
		X "$indent`t<dcsat:fieldExpression>"
		X "$indent`t`t<dcsat:field>$(Esc-Xml $ddField)</dcsat:field>"
		X "$indent`t`t<dcsat:expression>$(Esc-Xml $ddExpr)</dcsat:expression>"
		X "$indent`t</dcsat:fieldExpression>"
		X "$indent`t<dcsat:mainAction>$(Esc-Xml $ddAct)</dcsat:mainAction>"
		X "$indent</parameter>"
		return
	}
	# Форма A или B
	X "$indent<parameter xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:ExpressionAreaTemplateParameter`">"
	X "$indent`t<dcsat:name>$(Esc-Xml "$($tp.name)")</dcsat:name>"
	X "$indent`t<dcsat:expression>$(Esc-Xml "$($tp.expression)")</dcsat:expression>"
	X "$indent</parameter>"
	if ($dd -and ($dd -is [string])) {
		# Форма B: shortcut Расшифровка_<X> + ИмяРесурса + DrillDown
		$ddVal = "$dd"
		X "$indent<parameter xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:DetailsAreaTemplateParameter`">"
		X "$indent`t<dcsat:name>Расшифровка_$(Esc-Xml $ddVal)</dcsat:name>"
		X "$indent`t<dcsat:fieldExpression>"
		X "$indent`t`t<dcsat:field>ИмяРесурса</dcsat:field>"
		X "$indent`t`t<dcsat:expression>`"$(Esc-Xml $ddVal)`"</dcsat:expression>"
		X "$indent`t</dcsat:fieldExpression>"
		X "$indent`t<dcsat:mainAction>DrillDown</dcsat:mainAction>"
		X "$indent</parameter>"
	}
}

# === Templates ===
function Emit-Templates {
	if (-not $def.templates) { return }
	foreach ($t in $def.templates) {
		if ($t.rows) {
			# Compact DSL mode
			Emit-AreaTemplateDSL $t
		} else {
			# Raw XML mode
			X "`t<template>"
			X "`t`t<name>$(Esc-Xml "$($t.name)")</name>"
			if ($t.template) {
				X "`t`t$($t.template)"
			}
			if ($t.parameters) {
				foreach ($tp in $t.parameters) {
					Emit-AreaTemplateParameter -tp $tp -indent "`t`t"
				}
			}
			X "`t</template>"
		}
	}
}

# === FieldTemplates ===
# Привязка <fieldTemplate><field/><template/></fieldTemplate> поля к именованному area-template.
# DSL: "fieldTemplates": [{ "field": "X", "template": "Макет1" }, ...]
function Emit-FieldTemplates {
	if (-not $def.fieldTemplates) { return }
	foreach ($ft in $def.fieldTemplates) {
		X "`t<fieldTemplate>"
		X "`t`t<field>$(Esc-Xml "$($ft.field)")</field>"
		X "`t`t<template>$(Esc-Xml "$($ft.template)")</template>"
		X "`t</fieldTemplate>"
	}
}

# === GroupTemplates ===
function Emit-GroupTemplates {
	if (-not $def.groupTemplates) { return }
	foreach ($gt in $def.groupTemplates) {
		$ttype = if ($gt.templateType) { "$($gt.templateType)" } else { "Header" }
		$isHeader = ($ttype -eq 'GroupHeader')
		$tag = if ($isHeader) { 'groupHeaderTemplate' } else { 'groupTemplate' }
		$xmlTType = if ($isHeader) { 'Header' } else { $ttype }

		X "`t<$tag>"
		if ($gt.groupName) {
			X "`t`t<groupName>$(Esc-Xml "$($gt.groupName)")</groupName>"
		} elseif ($gt.groupField) {
			X "`t`t<groupField>$(Esc-Xml "$($gt.groupField)")</groupField>"
		}
		X "`t`t<templateType>$(Esc-Xml $xmlTType)</templateType>"
		X "`t`t<template>$(Esc-Xml "$($gt.template)")</template>"
		X "`t</$tag>"
	}
}

# === Settings Variants ===

function Emit-SelectionItem {
	param($item, [string]$indent)
	if ($item -is [string]) {
		if ($item -eq "Auto") {
			X "$indent<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
		} else {
			X "$indent<dcsset:item xsi:type=`"dcsset:SelectedItemField`">"
			X "$indent`t<dcsset:field>$(Esc-Xml $item)</dcsset:field>"
			X "$indent</dcsset:item>"
		}
		return
	}
	# Object form: { auto: true, use: false } — отключённый Auto в selection
	if ($item.auto -eq $true) {
		X "$indent<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`">"
		if ($item.use -eq $false) { X "$indent`t<dcsset:use>false</dcsset:use>" }
		X "$indent</dcsset:item>"
		return
	}
	if ($item.folder -or (Has-JsonProp $item 'folder')) {
		X "$indent<dcsset:item xsi:type=`"dcsset:SelectedItemFolder`">"
		# Optional <dcsset:field> на folder (редкий случай, для round-trip-целостности)
		if ($item.field) {
			X "$indent`t<dcsset:field>$(Esc-Xml "$($item.field)")</dcsset:field>"
		}
		Emit-MLText -tag "dcsset:lwsTitle" -text $item.folder -indent "$indent`t" -NoXsiType
		foreach ($sub in $item.items) {
			Emit-SelectionItem -item $sub -indent "$indent`t"
		}
		$pl = if ($item.placement) { "$($item.placement)" } else { 'Auto' }
		X "$indent`t<dcsset:placement>$(Esc-Xml $pl)</dcsset:placement>"
		X "$indent</dcsset:item>"
		return
	}
	# field with optional title / use=false / viewMode
	X "$indent<dcsset:item xsi:type=`"dcsset:SelectedItemField`">"
	if ($item.use -eq $false) {
		X "$indent`t<dcsset:use>false</dcsset:use>"
	}
	X "$indent`t<dcsset:field>$(Esc-Xml "$($item.field)")</dcsset:field>"
	if ($item.title) {
		Emit-MLText -tag "dcsset:lwsTitle" -text $item.title -indent "$indent`t" -NoXsiType
	}
	if ($item.viewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
	}
	X "$indent</dcsset:item>"
}

function Emit-Selection {
	param($items, [string]$indent, [switch]$skipAuto, $blockViewMode = $null, $blockUserSettingID = $null)

	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID)
	if (-not $hasItems -and -not $hasBlockMeta) { return }

	X "$indent<dcsset:selection>"
	foreach ($item in $items) {
		if ($skipAuto -and ($item -is [string]) -and $item -eq 'Auto') { continue }
		Emit-SelectionItem -item $item -indent "$indent`t"
	}
	if ($null -ne $blockViewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>"
	}
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	X "$indent</dcsset:selection>"
}

function Emit-FilterItem {
	param($item, [string]$indent)

	if ($item.group) {
		# FilterItemGroup
		$groupType = switch ("$($item.group)") {
			"And" { "AndGroup" }
			"Or"  { "OrGroup" }
			"Not" { "NotGroup" }
			default { "$($item.group)Group" }
		}
		X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemGroup`">"
		X "$indent`t<dcsset:groupType>$groupType</dcsset:groupType>"
		if ($item.items) {
			foreach ($sub in $item.items) {
				if ($sub -is [string]) {
					$parsed = Parse-FilterShorthand $sub
					$obj = @{ field = $parsed.field; op = $parsed.op }
					if ($parsed.use -eq $false) { $obj.use = $false }
					if ($null -ne $parsed.value) { $obj.value = $parsed.value }
					if ($parsed["valueType"]) { $obj.valueType = $parsed["valueType"] }
					if ($parsed.userSettingID) { $obj.userSettingID = $parsed.userSettingID }
					if ($parsed.viewMode) { $obj.viewMode = $parsed.viewMode }
					$sub = [pscustomobject]$obj
				}
				Emit-FilterItem -item $sub -indent "$indent`t"
			}
		}
		if ($item.presentation) {
			Emit-MLText -tag "dcsset:presentation" -text $item.presentation -indent "$indent`t"
		}
		if ($item.viewMode) {
			X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
		}
		if ($item.userSettingID) {
			$guid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
			X "$indent`t<dcsset:userSettingID>$(Esc-Xml $guid)</dcsset:userSettingID>"
		}
		if ($item.userSettingPresentation) {
			Emit-MLText -tag "dcsset:userSettingPresentation" -text $item.userSettingPresentation -indent "$indent`t"
		}
		X "$indent</dcsset:item>"
		return
	}

	# FilterItemComparison
	X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"

	if ($item.use -eq $false) {
		X "$indent`t<dcsset:use>false</dcsset:use>"
	}

	X "$indent`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-Xml "$($item.field)")</dcsset:left>"

	$compType = $script:comparisonTypes["$($item.op)"]
	if (-not $compType) { $compType = "$($item.op)" }
	X "$indent`t<dcsset:comparisonType>$(Esc-Xml $compType)</dcsset:comparisonType>"

	# Right value: один, несколько (InList) или ValueListType (пустой list-placeholder)
	$valIsArray = ($item.value -is [array]) -or ($item.value -is [System.Collections.IList] -and $item.value -isnot [string])
	if ($valIsArray) {
		# Пустой массив → пустой ValueListType placeholder
		if (@($item.value).Count -eq 0) {
			X "$indent`t<dcsset:right xsi:type=`"v8:ValueListType`">"
			X "$indent`t`t<v8:valueType/>"
			X "$indent`t`t<v8:lastId xsi:type=`"xs:decimal`">-1</v8:lastId>"
			X "$indent`t</dcsset:right>"
		} else {
			# Несколько <right> подряд (multi-value InList)
			foreach ($v in $item.value) {
				$vt = if ($item.valueType) { "$($item.valueType)" } else { "" }
				if (-not $vt) {
					if ($v -is [bool]) { $vt = 'xs:boolean' }
					elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { $vt = 'xs:decimal' }
					elseif ("$v" -match '^\d{4}-\d{2}-\d{2}T') { $vt = 'xs:dateTime' }
					elseif ("$v" -match '^-?\d+(\.\d+)?$') { $vt = 'xs:decimal' }
					elseif ("$v" -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { $vt = 'dcscor:DesignTimeValue' }
					else { $vt = 'xs:string' }
				}
				$vStr = if ($v -is [bool]) { "$v".ToLower() } else { Esc-Xml "$v" }
				X "$indent`t<dcsset:right xsi:type=`"$vt`">$vStr</dcsset:right>"
			}
		}
	} elseif ($null -ne $item.value) {
		$vt = if ($item.valueType) { "$($item.valueType)" } else { "" }
		if (-not $vt) {
			$v = $item.value
			if ($v -is [bool]) {
				$vt = "xs:boolean"
			} elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) {
				$vt = "xs:decimal"
			} elseif ("$v" -match '^\d{4}-\d{2}-\d{2}T') {
				$vt = "xs:dateTime"
			} elseif ("$v" -match '^-?\d+(\.\d+)?$') {
				$vt = "xs:decimal"
			} elseif ("$v" -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') {
				$vt = "dcscor:DesignTimeValue"
			} else {
				$vt = "xs:string"
			}
		}
		$vStr = if ($item.value -is [bool]) { "$($item.value)".ToLower() } else { Esc-Xml "$($item.value)" }
		X "$indent`t<dcsset:right xsi:type=`"$vt`">$vStr</dcsset:right>"
	}

	if ($item.presentation) {
		Emit-MLText -tag "dcsset:presentation" -text $item.presentation -indent "$indent`t"
	}

	# viewMode эмитим только если явно задан — присутствие в XML контекстно
	if ($item.viewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
	}

	if ($item.userSettingID) {
		$uid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}

	if ($item.userSettingPresentation) {
		Emit-MLText -tag "dcsset:userSettingPresentation" -text $item.userSettingPresentation -indent "$indent`t"
	}

	X "$indent</dcsset:item>"
}

function Emit-Filter {
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null)

	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID)
	if (-not $hasItems -and -not $hasBlockMeta) { return }

	X "$indent<dcsset:filter>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			# Parse shorthand: "Организация = _ @off @user"
			$parsed = Parse-FilterShorthand $item
			$filterObj = New-Object PSObject
			$filterObj | Add-Member -NotePropertyName "field" -NotePropertyValue $parsed.field
			$filterObj | Add-Member -NotePropertyName "op" -NotePropertyValue $parsed.op
			if ($parsed.use -eq $false) {
				$filterObj | Add-Member -NotePropertyName "use" -NotePropertyValue $false
			}
			if ($null -ne $parsed.value) {
				$filterObj | Add-Member -NotePropertyName "value" -NotePropertyValue $parsed.value
			}
			if ($parsed["valueType"]) {
				$filterObj | Add-Member -NotePropertyName "valueType" -NotePropertyValue $parsed["valueType"]
			}
			if ($parsed.userSettingID) {
				$filterObj | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue $parsed.userSettingID
			}
			if ($parsed.viewMode) {
				$filterObj | Add-Member -NotePropertyName "viewMode" -NotePropertyValue $parsed.viewMode
			}
			Emit-FilterItem -item $filterObj -indent "$indent`t"
		} else {
			Emit-FilterItem -item $item -indent "$indent`t"
		}
	}
	if ($null -ne $blockViewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>"
	}
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	X "$indent</dcsset:filter>"
}

function Emit-Order {
	param($items, [string]$indent, [switch]$skipAuto, $blockViewMode = $null, $blockUserSettingID = $null)

	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID)
	if (-not $hasItems -and -not $hasBlockMeta) { return }

	X "$indent<dcsset:order>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			if ($item -eq "Auto") {
				if (-not $skipAuto) {
					X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
				}
			} else {
				$parts = $item -split '\s+'
				$field = $parts[0]
				$dir = "Asc"
				if ($parts.Count -gt 1 -and $parts[1] -match '^(?i)desc$') { $dir = "Desc" }
				elseif ($parts.Count -gt 1 -and $parts[1] -match '^(?i)asc$') { $dir = "Asc" }
				X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
				X "$indent`t`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
				X "$indent`t`t<dcsset:orderType>$dir</dcsset:orderType>"
				X "$indent`t</dcsset:item>"
			}
		} else {
			# Object form: { field, direction, viewMode }
			if ($item.field -eq "Auto" -or $item.type -eq "auto") {
				if (-not $skipAuto) {
					X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
				}
				continue
			}
			$dir = if ($item.direction) { "$($item.direction)" } else { "Asc" }
			if ($dir -match '^(?i)desc$') { $dir = "Desc" } elseif ($dir -match '^(?i)asc$') { $dir = "Asc" }
			X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
			if ($item.use -eq $false) {
				X "$indent`t`t<dcsset:use>false</dcsset:use>"
			}
			X "$indent`t`t<dcsset:field>$(Esc-Xml "$($item.field)")</dcsset:field>"
			X "$indent`t`t<dcsset:orderType>$dir</dcsset:orderType>"
			if ($item.viewMode) {
				X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
			}
			X "$indent`t</dcsset:item>"
		}
	}
	if ($null -ne $blockViewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>"
	}
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	X "$indent</dcsset:order>"
}

function Emit-AppearanceValue {
	param([string]$key, $val, [string]$indent)

	X "$indent<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"

	# Helper для проверки property/key на PSCustomObject/IDictionary
	function _HasKey { param($o, [string]$k)
		if ($o -is [PSCustomObject]) { return [bool]$o.PSObject.Properties[$k] }
		if ($o -is [System.Collections.IDictionary]) { return $o.Contains($k) }
		return $false
	}
	function _Get { param($o, [string]$k)
		if ($o -is [PSCustomObject]) { return $o.$k }
		if ($o -is [System.Collections.IDictionary]) { return $o[$k] }
		return $null
	}

	# Распознаём wrapper {value:..., use?:false, items?:{}}.
	# Top-level Line-value хранится плоско ({@type:Line, width, gap, style, use?, items?}) —
	# отличаем от wrapper по наличию @type на самом val.
	$isTopLevelLine = (_HasKey $val '@type') -and ("$(_Get $val '@type')" -eq 'Line')
	$useWrapper = $false
	$innerVal = $val
	$nestedItems = $null
	if ($isTopLevelLine) {
		# items/use лежат рядом с @type
		if ((_HasKey $val 'use') -and ((_Get $val 'use') -eq $false)) { $useWrapper = $true }
		if (_HasKey $val 'items') { $nestedItems = (_Get $val 'items') }
	} elseif ((_HasKey $val 'value') -and (($val -is [PSCustomObject]) -or ($val -is [System.Collections.IDictionary]))) {
		# Обычный wrapper {value, use?, items?}
		$innerVal = (_Get $val 'value')
		if ((_HasKey $val 'use') -and ((_Get $val 'use') -eq $false)) { $useWrapper = $true }
		if (_HasKey $val 'items') { $nestedItems = (_Get $val 'items') }
	}

	if ($useWrapper) { X "$indent`t<dcscor:use>false</dcscor:use>" }
	X "$indent`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"

	# Font dict ({@type: "Font", ref, faceName, height, bold, ...}) → <dcscor:value xsi:type="v8ui:Font" .../>
	$isFontDict = $false
	if ($innerVal -is [PSCustomObject]) {
		$tProp = $innerVal.PSObject.Properties['@type']
		if ($tProp -and "$($tProp.Value)" -eq 'Font') { $isFontDict = $true }
	} elseif ($innerVal -is [System.Collections.IDictionary]) {
		if ($innerVal.Contains('@type') -and "$($innerVal['@type'])" -eq 'Font') { $isFontDict = $true }
	}
	# Line dict ({@type: "Line", width, gap, style}) → <dcscor:value xsi:type="v8ui:Line" ...><v8ui:style>...
	$isLineDict = $false
	if (_HasKey $innerVal '@type') { $isLineDict = ("$(_Get $innerVal '@type')" -eq 'Line') }
	$isDict = ($innerVal -is [hashtable]) -or ($innerVal -is [System.Collections.IDictionary]) -or ($innerVal -is [PSCustomObject])
	if ($isLineDict) {
		$lw = if (_HasKey $innerVal 'width') { _Get $innerVal 'width' } else { 0 }
		$lg = if (_HasKey $innerVal 'gap') { if ((_Get $innerVal 'gap')) { 'true' } else { 'false' } } else { 'false' }
		$ls = if (_HasKey $innerVal 'style') { "$(_Get $innerVal 'style')" } else { 'None' }
		X "$indent`t<dcscor:value xsi:type=`"v8ui:Line`" width=`"$lw`" gap=`"$lg`">"
		X "$indent`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">$(Esc-Xml $ls)</v8ui:style>"
		X "$indent`t</dcscor:value>"
	} elseif ($isFontDict) {
		$attrParts = @()
		foreach ($attrName in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
			$av = $null
			if ($innerVal -is [PSCustomObject]) {
				$ap = $innerVal.PSObject.Properties[$attrName]
				if ($ap) { $av = $ap.Value }
			} else {
				if ($innerVal.Contains($attrName)) { $av = $innerVal[$attrName] }
			}
			if ($null -ne $av) { $attrParts += "$attrName=`"$(Esc-Xml "$av")`"" }
		}
		X "$indent`t<dcscor:value xsi:type=`"v8ui:Font`" $($attrParts -join ' ')/>"
	} elseif ($isDict) {
		# Multilang dict ({"ru": "...", "en": "..."}) → LocalStringType независимо от ключа.
		Emit-MLText -tag "dcscor:value" -text $innerVal -indent "$indent`t"
	} else {
		$actualVal = "$innerVal"
		# Параметр-специфичный тип для известных appearance keys
		$keyTypeMap = @{
			'Размещение'           = 'dcscor:DataCompositionTextPlacementType'
			'ГоризонтальноеПоложение' = 'v8ui:HorizontalAlign'
			'ВертикальноеПоложение' = 'v8ui:VerticalAlign'
			'ОриентацияТекста'     = 'xs:decimal'
			'РасположениеИтогов'   = 'dcscor:DataCompositionTotalPlacement'
			'ТипМакета'            = 'dcsset:DataCompositionGroupTemplateType'
		}
		$keyType = $keyTypeMap[$key]
		if ($keyType) {
			X "$indent`t<dcscor:value xsi:type=`"$keyType`">$(Esc-Xml $actualVal)</dcscor:value>"
		} elseif ($actualVal -match '^(style|web|win):') {
			# Внутри <dcsset:settings> префиксы style:/web:/win:/sys: уже объявлены на корне,
			# локальный xmlns не нужен — эмитим short form.
			X "$indent`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $actualVal)</dcscor:value>"
		} elseif ($actualVal -eq "true" -or $actualVal -eq "false") {
			X "$indent`t<dcscor:value xsi:type=`"xs:boolean`">$actualVal</dcscor:value>"
		} elseif ($key -eq "Текст" -or $key -eq "Заголовок" -or $key -eq "Формат") {
			# Строковые ключи, традиционно эмитятся как LocalStringType (даже если только ru).
			Emit-MLText -tag "dcscor:value" -text $actualVal -indent "$indent`t"
		} elseif ($actualVal -match '^-?\d+(\.\d+)?$') {
			# Number → xs:decimal (МинимальнаяШирина=40, ОриентацияТекста и т.п. — но не key-typed)
			X "$indent`t<dcscor:value xsi:type=`"xs:decimal`">$actualVal</dcscor:value>"
		} elseif ($key -eq 'ЦветТекста' -or $key -eq 'ЦветФона' -or $key -eq 'ЦветГраницы') {
			# Color без явного префикса (auto, #FFC8C8)
			X "$indent`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $actualVal)</dcscor:value>"
		} else {
			X "$indent`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml $actualVal)</dcscor:value>"
		}
	}
	# Nested SettingsParameterValue items (например СтильГраницы.Сверху/.Снизу/.Слева/.Справа).
	# Эмитим как siblings <dcscor:item> внутри родительского <dcscor:item>.
	if ($nestedItems) {
		$niProps = if ($nestedItems -is [PSCustomObject]) { $nestedItems.PSObject.Properties } else { $null }
		if ($niProps) {
			foreach ($np in $niProps) {
				Emit-AppearanceValue -key $np.Name -val $np.Value -indent "$indent`t"
			}
		} elseif ($nestedItems -is [System.Collections.IDictionary]) {
			foreach ($nk in $nestedItems.Keys) {
				Emit-AppearanceValue -key $nk -val $nestedItems[$nk] -indent "$indent`t"
			}
		}
	}
	X "$indent</dcscor:item>"
}

function Emit-ConditionalAppearance {
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null)

	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID)
	if (-not $hasItems -and -not $hasBlockMeta) { return }

	X "$indent<dcsset:conditionalAppearance>"
	foreach ($ca in $items) {
		X "$indent`t<dcsset:item>"

		# use=false — отключённое правило (эмитим до selection — XML-порядок)
		if ($ca.use -eq $false) {
			X "$indent`t`t<dcsset:use>false</dcsset:use>"
		}

		# Selection (which fields to apply to; empty = all)
		if ($ca.selection -and $ca.selection.Count -gt 0) {
			X "$indent`t`t<dcsset:selection>"
			foreach ($sel in $ca.selection) {
				X "$indent`t`t`t<dcsset:item>"
				X "$indent`t`t`t`t<dcsset:field>$(Esc-Xml "$sel")</dcsset:field>"
				X "$indent`t`t`t</dcsset:item>"
			}
			X "$indent`t`t</dcsset:selection>"
		} else {
			X "$indent`t`t<dcsset:selection/>"
		}

		# Filter (reuse existing Emit-Filter logic)
		if ($ca.filter -and $ca.filter.Count -gt 0) {
			Emit-Filter -items $ca.filter -indent "$indent`t`t"
		} else {
			# Платформа эмитит пустой <dcsset:filter/> на каждом condApp item
			X "$indent`t`t<dcsset:filter/>"
		}

		# Appearance (parameter-value pairs)
		if ($ca.appearance) {
			X "$indent`t`t<dcsset:appearance>"
			foreach ($prop in $ca.appearance.PSObject.Properties) {
				Emit-AppearanceValue -key $prop.Name -val $prop.Value -indent "$indent`t`t`t"
			}
			X "$indent`t`t</dcsset:appearance>"
		}

		# Presentation
		if ($ca.presentation) {
			# Multilang dict {ru, en, ...} → LocalStringType; иначе — xs:string
			if ($ca.presentation -is [hashtable] -or $ca.presentation -is [System.Collections.IDictionary] -or $ca.presentation -is [PSCustomObject]) {
				Emit-MLText -tag "dcsset:presentation" -text $ca.presentation -indent "$indent`t`t"
			} else {
				X "$indent`t`t<dcsset:presentation xsi:type=`"xs:string`">$(Esc-Xml "$($ca.presentation)")</dcsset:presentation>"
			}
		}

		if ($ca.viewMode) {
			X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($ca.viewMode)")</dcsset:viewMode>"
		}

		# UserSettingID
		if ($ca.userSettingID) {
			$uid = if ("$($ca.userSettingID)" -eq "auto") { New-Guid-String } else { "$($ca.userSettingID)" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
		}

		if ($ca.userSettingPresentation) {
			Emit-MLText -tag "dcsset:userSettingPresentation" -text $ca.userSettingPresentation -indent "$indent`t`t"
		}

		# useInXxx — список областей где правило НЕ применяется (DontUse).
		# Порядок имитирует платформенный (group → hierarchicalGroup → overall → ...).
		if ($ca.useInDontUse -and $ca.useInDontUse.Count -gt 0) {
			$useInOrder = @('group','hierarchicalGroup','overall',
				'fieldsHeader','header','parameters','filter',
				'resourceFieldsHeader','overallHeader','overallResourceFieldsHeader')
			$set = @{}
			foreach ($n in $ca.useInDontUse) { $set["$n"] = $true }
			foreach ($n in $useInOrder) {
				if ($set.ContainsKey($n)) {
					$tag = "useIn" + ($n.Substring(0,1).ToUpper()) + ($n.Substring(1))
					X "$indent`t`t<dcsset:$tag>DontUse</dcsset:$tag>"
				}
			}
		}

		X "$indent`t</dcsset:item>"
	}
	if ($null -ne $blockViewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>"
	}
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	X "$indent</dcsset:conditionalAppearance>"
}

# Эмиссия nested sub-item внутри SettingsParameterValue (chart-параметры типа
# ТипДиаграммы.СоединениеЗначенийПоСериям). Поддерживает use=false и valueType
# либо строкой ("xs:string", "dN:Foo" если префикс известен в корне), либо
# объектом {uri, name} — эмитим локальный xmlns на value.
function Emit-OutputParametersSubItem {
	param([string]$subName, $subWrap, [string]$indent)
	$subVal = $subWrap
	$subVT = 'xs:string'
	$subUseFalse = $false
	$subUri = $null
	$subLocalName = $null
	if ($subWrap -is [PSCustomObject]) {
		if ($subWrap.PSObject.Properties['value']) { $subVal = $subWrap.value }
		if ($subWrap.PSObject.Properties['valueType']) {
			$vt = $subWrap.valueType
			if ($vt -is [PSCustomObject] -and $vt.PSObject.Properties['uri']) {
				$subUri = "$($vt.uri)"; $subLocalName = "$($vt.name)"
			} elseif ($vt -is [System.Collections.IDictionary] -and $vt.Contains('uri')) {
				$subUri = "$($vt['uri'])"; $subLocalName = "$($vt['name'])"
			} else {
				$subVT = "$vt"
			}
		}
		if ($subWrap.PSObject.Properties['use'] -and $subWrap.use -eq $false) { $subUseFalse = $true }
	} elseif ($subWrap -is [System.Collections.IDictionary]) {
		if ($subWrap.Contains('value')) { $subVal = $subWrap['value'] }
		if ($subWrap.Contains('valueType')) {
			$vt = $subWrap['valueType']
			if ($vt -is [PSCustomObject] -and $vt.PSObject.Properties['uri']) {
				$subUri = "$($vt.uri)"; $subLocalName = "$($vt.name)"
			} elseif ($vt -is [System.Collections.IDictionary] -and $vt.Contains('uri')) {
				$subUri = "$($vt['uri'])"; $subLocalName = "$($vt['name'])"
			} else {
				$subVT = "$vt"
			}
		}
		if ($subWrap.Contains('use') -and $subWrap['use'] -eq $false) { $subUseFalse = $true }
	}
	X "$indent`t`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
	if ($subUseFalse) { X "$indent`t`t`t<dcscor:use>false</dcscor:use>" }
	X "$indent`t`t`t<dcscor:parameter>$(Esc-Xml $subName)</dcscor:parameter>"
	if ($subUri) {
		X "$indent`t`t`t<dcscor:value xmlns:dN=`"$subUri`" xsi:type=`"dN:$subLocalName`">$(Esc-Xml "$subVal")</dcscor:value>"
	} else {
		X "$indent`t`t`t<dcscor:value xsi:type=`"$subVT`">$(Esc-Xml "$subVal")</dcscor:value>"
	}
	X "$indent`t`t</dcscor:item>"
}

function Emit-OutputParameters {
	param($params, [string]$indent, $blockViewMode = $null)

	if (-not $params) { return }

	X "$indent<dcsset:outputParameters>"
	foreach ($prop in $params.PSObject.Properties) {
		$key = $prop.Name
		$rawVal = $prop.Value
		# Распознаём wrapper {value, valueType?, use?, items?, viewMode?, userSettingID?, userSettingPresentation?}
		# отличая от multilang dict ({ru, en, ...}). Wrapper всегда имеет ключ 'value'.
		$useFalse = $false
		$wrapVM = $null
		$wrapUSID = $null
		$wrapUSP = $null
		$wrapVT = $null
		$wrapItems = $null
		$hasValueKey = $false
		if ($rawVal -is [PSCustomObject] -and $rawVal.PSObject.Properties['value']) {
			$hasValueKey = $true
			if ($rawVal.PSObject.Properties['valueType']) { $wrapVT = "$($rawVal.valueType)" }
			if ($rawVal.PSObject.Properties['use'] -and $rawVal.use -eq $false) { $useFalse = $true }
			if ($rawVal.PSObject.Properties['items']) { $wrapItems = $rawVal.items }
			if ($rawVal.PSObject.Properties['viewMode']) { $wrapVM = "$($rawVal.viewMode)" }
			if ($rawVal.PSObject.Properties['userSettingID']) { $wrapUSID = "$($rawVal.userSettingID)" }
			if ($rawVal.PSObject.Properties['userSettingPresentation']) { $wrapUSP = $rawVal.userSettingPresentation }
			$rawVal = $rawVal.value
		} elseif (($rawVal -is [hashtable] -or $rawVal -is [System.Collections.IDictionary]) -and $rawVal.Contains('value')) {
			$hasValueKey = $true
			if ($rawVal.Contains('valueType')) { $wrapVT = "$($rawVal['valueType'])" }
			if ($rawVal.Contains('use') -and $rawVal['use'] -eq $false) { $useFalse = $true }
			if ($rawVal.Contains('items')) { $wrapItems = $rawVal['items'] }
			if ($rawVal.Contains('viewMode')) { $wrapVM = "$($rawVal['viewMode'])" }
			if ($rawVal.Contains('userSettingID')) { $wrapUSID = "$($rawVal['userSettingID'])" }
			if ($rawVal.Contains('userSettingPresentation')) { $wrapUSP = $rawVal['userSettingPresentation'] }
			$rawVal = $rawVal['value']
		}
		# Font dict внутри значения
		$isFontDict = $false
		if ($rawVal -is [PSCustomObject]) {
			$tProp = $rawVal.PSObject.Properties['@type']
			if ($tProp -and "$($tProp.Value)" -eq 'Font') { $isFontDict = $true }
		} elseif ($rawVal -is [System.Collections.IDictionary]) {
			if ($rawVal.Contains('@type') -and "$($rawVal['@type'])" -eq 'Font') { $isFontDict = $true }
		}
		# Приоритет: явный wrapVT > известный тип ключа > xs:string
		if ($wrapVT) { $ptype = $wrapVT }
		else {
			$ptype = $script:outputParamTypes[$key]
			if (-not $ptype) { $ptype = "xs:string" }
		}
		# Auto-promote to mltext if value is a multilang dict (но не Font/wrapper)
		if (-not $isFontDict -and ($rawVal -is [System.Management.Automation.PSCustomObject] -or $rawVal -is [hashtable] -or $rawVal -is [System.Collections.IDictionary])) {
			$ptype = "mltext"
		}

		X "$indent`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
		if ($useFalse) { X "$indent`t`t<dcscor:use>false</dcscor:use>" }
		X "$indent`t`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"
		if ($isFontDict) {
			$attrParts = @()
			foreach ($attrName in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
				$av = $null
				if ($rawVal -is [PSCustomObject]) {
					$ap = $rawVal.PSObject.Properties[$attrName]
					if ($ap) { $av = $ap.Value }
				} else {
					if ($rawVal.Contains($attrName)) { $av = $rawVal[$attrName] }
				}
				if ($null -ne $av) { $attrParts += "$attrName=`"$(Esc-Xml "$av")`"" }
			}
			X "$indent`t`t<dcscor:value xsi:type=`"v8ui:Font`" $($attrParts -join ' ')/>"
		} elseif ($ptype -eq "mltext") {
			Emit-MLText -tag "dcscor:value" -text $rawVal -indent "$indent`t`t"
		} else {
			X "$indent`t`t<dcscor:value xsi:type=`"$ptype`">$(Esc-Xml "$rawVal")</dcscor:value>"
		}
		# Nested sub-параметры (ТипДиаграммы.ВидПодписей и т.п.) — эмитим между value и extras.
		# valueType: строка → xsi:type=string, объект {uri, name} → локальный xmlns:dN + xsi:type=dN:name.
		if ($wrapItems) {
			$itemProps = if ($wrapItems -is [PSCustomObject]) { $wrapItems.PSObject.Properties } else { $null }
			if ($itemProps) {
				foreach ($ip in $itemProps) {
					Emit-OutputParametersSubItem -subName $ip.Name -subWrap $ip.Value -indent $indent
				}
			} elseif ($wrapItems -is [System.Collections.IDictionary]) {
				foreach ($k in $wrapItems.Keys) {
					Emit-OutputParametersSubItem -subName $k -subWrap $wrapItems[$k] -indent $indent
				}
			}
		}
		if ($wrapVM) { X "$indent`t`t<dcsset:viewMode>$(Esc-Xml $wrapVM)</dcsset:viewMode>" }
		if ($wrapUSID) {
			$uid = if ("$wrapUSID" -eq 'auto') { New-Guid-String } else { "$wrapUSID" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
		}
		if ($wrapUSP) {
			Emit-MLText -tag "dcsset:userSettingPresentation" -text $wrapUSP -indent "$indent`t`t"
		}
		X "$indent`t</dcscor:item>"
	}
	if ($null -ne $blockViewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>"
	}
	X "$indent</dcsset:outputParameters>"
}

function Emit-DataParameters {
	param($items, [string]$indent, $blockViewMode = $null)

	if (-not $items -or $items.Count -eq 0) { return }

	X "$indent<dcsset:dataParameters>"
	foreach ($dp in $items) {
		# Support string shorthand
		if ($dp -is [string]) {
			$parsed = Parse-DataParamShorthand $dp
			$dpObj = New-Object PSObject
			$dpObj | Add-Member -NotePropertyName "parameter" -NotePropertyValue $parsed.parameter
			if ($null -ne $parsed.value) {
				$dpObj | Add-Member -NotePropertyName "value" -NotePropertyValue $parsed.value
			}
			if ($parsed.use -eq $false) {
				$dpObj | Add-Member -NotePropertyName "use" -NotePropertyValue $false
			}
			if ($parsed.userSettingID) {
				$dpObj | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue $parsed.userSettingID
			}
			if ($parsed.viewMode) {
				$dpObj | Add-Member -NotePropertyName "viewMode" -NotePropertyValue $parsed.viewMode
			}
			$dp = $dpObj
		}

		X "$indent`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"

		if ($dp.use -eq $false) {
			X "$indent`t`t<dcscor:use>false</dcscor:use>"
		}

		X "$indent`t`t<dcscor:parameter>$(Esc-Xml "$($dp.parameter)")</dcscor:parameter>"

		# Value
		if ($dp.nilValue -eq $true) {
			X "$indent`t`t<dcscor:value xsi:nil=`"true`"/>"
		} elseif (Test-EmptyValue $dp.value) {
			Emit-EmptyValue -type "$($dp.valueType)" -indent "$indent`t`t" -tagPrefix "dcscor:" -valueListAllowed $false
		} elseif ($null -ne $dp.value) {
			$vtype = "$($dp.valueType)"
			if (($dp.value -is [PSCustomObject] -or $dp.value -is [hashtable]) -and ($dp.value.variant)) {
				# Standard{Period,BeginningDate} — различаем по форме value:
				#  {variant, date}         → SBD
				#  {variant, startDate, endDate} → SP с датами
				#  {variant} only          → инференс по имени (BeginningOf* → SBD, иначе SP)
				$_hasDate = $false; $_hasSD = $false
				if ($dp.value -is [PSCustomObject]) {
					$_hasDate = [bool]$dp.value.PSObject.Properties['date']
					$_hasSD   = [bool]$dp.value.PSObject.Properties['startDate']
				} else {
					$_hasDate = $dp.value.Contains('date')
					$_hasSD   = $dp.value.Contains('startDate')
				}
				$_variantStr = "$($dp.value.variant)"
				$_isSBD = $_hasDate -or (-not $_hasSD -and $_variantStr -like 'BeginningOf*')
				if ($_isSBD) {
					$_d = $null
					if ($dp.value -is [PSCustomObject] -and $dp.value.PSObject.Properties['date']) { $_d = "$($dp.value.date)" }
					elseif ($dp.value -is [System.Collections.IDictionary] -and $dp.value.Contains('date')) { $_d = "$($dp.value['date'])" }
					X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardBeginningDate`">"
					X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardBeginningDateVariant`">$(Esc-Xml $_variantStr)</v8:variant>"
					if ($_variantStr -eq 'Custom') {
						if (-not $_d) { $_d = '0001-01-01T00:00:00' }
						X "$indent`t`t`t<v8:date>$(Esc-Xml $_d)</v8:date>"
					}
					X "$indent`t`t</dcscor:value>"
				} else {
					# StandardPeriod — platform-pattern: startDate/endDate ТОЛЬКО для variant=Custom.
					$_sd = $null; $_ed = $null
					if ($dp.value -is [PSCustomObject]) {
						if ($dp.value.PSObject.Properties['startDate']) { $_sd = "$($dp.value.startDate)" }
						if ($dp.value.PSObject.Properties['endDate'])   { $_ed = "$($dp.value.endDate)" }
					} else {
						if ($dp.value.Contains('startDate')) { $_sd = "$($dp.value['startDate'])" }
						if ($dp.value.Contains('endDate'))   { $_ed = "$($dp.value['endDate'])" }
					}
					X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardPeriod`">"
					X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $_variantStr)</v8:variant>"
					if ($_variantStr -eq 'Custom') {
						if (-not $_sd) { $_sd = '0001-01-01T00:00:00' }
						if (-not $_ed) { $_ed = '0001-01-01T00:00:00' }
						X "$indent`t`t`t<v8:startDate>$(Esc-Xml $_sd)</v8:startDate>"
						X "$indent`t`t`t<v8:endDate>$(Esc-Xml $_ed)</v8:endDate>"
					}
					X "$indent`t`t</dcscor:value>"
				}
			} elseif ($vtype -match '^[a-zA-Z]+:') {
				# Полный xsi:type из decompile (например "xs:boolean", "dcscor:DesignTimeValue").
				$vStr = if ($dp.value -is [bool]) { "$($dp.value)".ToLower() } else { "$($dp.value)" }
				X "$indent`t`t<dcscor:value xsi:type=`"$vtype`">$(Esc-Xml $vStr)</dcscor:value>"
			} elseif ($vtype -eq 'boolean' -or $dp.value -is [bool]) {
				$bv = "$($dp.value)".ToLower()
				X "$indent`t`t<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml $bv)</dcscor:value>"
			} elseif ($vtype -match '^date' -or "$($dp.value)" -match '^\d{4}-\d{2}-\d{2}T') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} elseif ($vtype -match '^decimal') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:decimal`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} elseif ($vtype -match '^string') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} elseif ("$($dp.value)" -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or "$($dp.value)" -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} else {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			}
		}

		if ($dp.viewMode) {
			X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($dp.viewMode)")</dcsset:viewMode>"
		}

		if ($dp.userSettingID) {
			$uid = if ("$($dp.userSettingID)" -eq "auto") { New-Guid-String } else { "$($dp.userSettingID)" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
		}

		if ($dp.userSettingPresentation) {
			Emit-MLText -tag "dcsset:userSettingPresentation" -text $dp.userSettingPresentation -indent "$indent`t`t"
		}

		X "$indent`t</dcscor:item>"
	}
	if ($null -ne $blockViewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>"
	}
	X "$indent</dcsset:dataParameters>"
}

# === Structure items (recursive) ===

function Emit-GroupItems {
	param($groupBy, [string]$indent)

	if (-not $groupBy -or $groupBy.Count -eq 0) { return }

	X "$indent<dcsset:groupItems>"
	foreach ($field in $groupBy) {
		if ($field -is [string]) {
			if ($field -eq 'Auto') {
				# Auto-группировка (по аналогии с "Auto" в selection)
				X "$indent`t<dcsset:item xsi:type=`"dcsset:GroupItemAuto`"/>"
				continue
			}
			X "$indent`t<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
			X "$indent`t`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
			X "$indent`t`t<dcsset:groupType>Items</dcsset:groupType>"
			X "$indent`t`t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>"
			X "$indent`t`t<dcsset:periodAdditionBegin xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionBegin>"
			X "$indent`t`t<dcsset:periodAdditionEnd xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionEnd>"
			X "$indent`t</dcsset:item>"
		} else {
			# Object form
			X "$indent`t<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
			X "$indent`t`t<dcsset:field>$(Esc-Xml "$($field.field)")</dcsset:field>"
			$gt = if ($field.groupType) { "$($field.groupType)" } else { "Items" }
			X "$indent`t`t<dcsset:groupType>$(Esc-Xml $gt)</dcsset:groupType>"
			$pat = if ($field.periodAdditionType) { "$($field.periodAdditionType)" } else { "None" }
			X "$indent`t`t<dcsset:periodAdditionType>$(Esc-Xml $pat)</dcsset:periodAdditionType>"
			# Auto-detect: ISO date → xs:dateTime, иначе → dcscor:Field (path).
			$pab = if ($field.periodAdditionBegin) { "$($field.periodAdditionBegin)" } else { '0001-01-01T00:00:00' }
			$pae = if ($field.periodAdditionEnd)   { "$($field.periodAdditionEnd)"   } else { '0001-01-01T00:00:00' }
			$pabT = if ($pab -match '^\d{4}-\d{2}-\d{2}T') { 'xs:dateTime' } else { 'dcscor:Field' }
			$paeT = if ($pae -match '^\d{4}-\d{2}-\d{2}T') { 'xs:dateTime' } else { 'dcscor:Field' }
			X "$indent`t`t<dcsset:periodAdditionBegin xsi:type=`"$pabT`">$(Esc-Xml $pab)</dcsset:periodAdditionBegin>"
			X "$indent`t`t<dcsset:periodAdditionEnd xsi:type=`"$paeT`">$(Esc-Xml $pae)</dcsset:periodAdditionEnd>"
			X "$indent`t</dcsset:item>"
		}
	}
	X "$indent</dcsset:groupItems>"
}

# Parse structure string shorthand: "Организация > Номенклатура > details"
function Parse-StructureShorthand {
	param([string]$s)

	$segments = $s -split '\s*>\s*'
	$result = @()

	# Build nested groups from right to left
	$innermost = $null
	for ($i = $segments.Count - 1; $i -ge 0; $i--) {
		$seg = $segments[$i].Trim()
		$group = New-Object PSObject
		$group | Add-Member -NotePropertyName "type" -NotePropertyValue "group"

		if ($seg -match '^(?i)(details|детали)$') {
			# Empty groupBy = detailed records
			$group | Add-Member -NotePropertyName "groupBy" -NotePropertyValue @()
		} elseif ($seg -match '^(.+)\[(.+)\]$') {
			# Named group: "ИмяГруппы[Поле]"
			$group | Add-Member -NotePropertyName "name" -NotePropertyValue $Matches[1].Trim()
			$group | Add-Member -NotePropertyName "groupBy" -NotePropertyValue @($Matches[2].Trim())
		} else {
			$group | Add-Member -NotePropertyName "groupBy" -NotePropertyValue @($seg)
		}

		# Платформа в каждую группировку кладёт авто-поле выбора и авто-порядок;
		# shorthand должен соответствовать ручному добавлению группировки в конфигураторе.
		$group | Add-Member -NotePropertyName "selection" -NotePropertyValue @("Auto")
		$group | Add-Member -NotePropertyName "order" -NotePropertyValue @("Auto")

		if ($null -ne $innermost) {
			$group | Add-Member -NotePropertyName "children" -NotePropertyValue @($innermost)
		}
		$innermost = $group
	}

	if ($innermost) { $result += $innermost }
	return ,$result
}

function Emit-UserFields {
	param($items, [string]$indent)
	if (-not $items -or $items.Count -eq 0) { return }
	X "$indent<dcsset:userFields>"
	foreach ($uf in $items) {
		# Type detection: cases → UserFieldCase, otherwise UserFieldExpression
		$uType = if ($uf.cases) { "UserFieldCase" } else { "UserFieldExpression" }
		X "$indent`t<dcsset:item xsi:type=`"dcsset:$uType`">"
		if ($uf.dataPath) {
			X "$indent`t`t<dcsset:dataPath>$(Esc-Xml "$($uf.dataPath)")</dcsset:dataPath>"
		}
		if ($uf.title) {
			Emit-MLText -tag "dcsset:lwsTitle" -text $uf.title -indent "$indent`t`t" -NoXsiType
		}
		if ($uType -eq "UserFieldExpression") {
			if ($uf.detail) {
				if ($uf.detail.PSObject.Properties.Match('expression').Count -gt 0) {
					$_v = "$($uf.detail.expression)"
					if ($_v) { X "$indent`t`t<dcsset:detailExpression>$(Esc-Xml $_v)</dcsset:detailExpression>" }
					else { X "$indent`t`t<dcsset:detailExpression/>" }
				}
				if ($uf.detail.PSObject.Properties.Match('presentation').Count -gt 0) {
					$_v = "$($uf.detail.presentation)"
					if ($_v) { X "$indent`t`t<dcsset:detailExpressionPresentation>$(Esc-Xml $_v)</dcsset:detailExpressionPresentation>" }
					else { X "$indent`t`t<dcsset:detailExpressionPresentation/>" }
				}
			}
			if ($uf.total) {
				if ($uf.total.PSObject.Properties.Match('expression').Count -gt 0) {
					$_v = "$($uf.total.expression)"
					if ($_v) { X "$indent`t`t<dcsset:totalExpression>$(Esc-Xml $_v)</dcsset:totalExpression>" }
					else { X "$indent`t`t<dcsset:totalExpression/>" }
				}
				if ($uf.total.PSObject.Properties.Match('presentation').Count -gt 0) {
					$_v = "$($uf.total.presentation)"
					if ($_v) { X "$indent`t`t<dcsset:totalExpressionPresentation>$(Esc-Xml $_v)</dcsset:totalExpressionPresentation>" }
					else { X "$indent`t`t<dcsset:totalExpressionPresentation/>" }
				}
			}
		} else {
			# UserFieldCase
			if ($uf.cases.Count -eq 0) {
				X "$indent`t`t<dcsset:cases/>"
			} else {
				X "$indent`t`t<dcsset:cases>"
				foreach ($c in $uf.cases) {
					X "$indent`t`t`t<dcsset:item>"
					if ($c.filter) {
						Emit-Filter -items $c.filter -indent "$indent`t`t`t`t"
					}
					if ($null -ne $c.value) {
						$cv = $c.value
						if ($cv -is [bool]) {
							X "$indent`t`t`t`t<dcsset:value xsi:type=`"xs:boolean`">$(("$cv").ToLower())</dcsset:value>"
						} elseif ($cv -is [int] -or $cv -is [long] -or $cv -is [double]) {
							X "$indent`t`t`t`t<dcsset:value xsi:type=`"xs:decimal`">$cv</dcsset:value>"
						} else {
							X "$indent`t`t`t`t<dcsset:value xsi:type=`"xs:string`">$(Esc-Xml "$cv")</dcsset:value>"
						}
					}
					if ($c.presentation) {
						Emit-MLText -tag "dcsset:lwsPresentationValue" -text $c.presentation -indent "$indent`t`t`t`t" -NoXsiType
					}
					X "$indent`t`t`t</dcsset:item>"
				}
				X "$indent`t`t</dcsset:cases>"
			}
		}
		X "$indent`t</dcsset:item>"
	}
	X "$indent</dcsset:userFields>"
}

# Shared emitter for table column/row and chart point/series.
# Emits name?, groupItems, filter, order, selection, outputParameters, viewMode?,
# userSettingID?, userSettingPresentation? — каждое условно по присутствию в JSON.
# Параметр $emitName управляет тем, эмитить ли <name> внутри блока: для row caller
# уже эмитит name отдельно (исторический порядок), для остальных — здесь.
function Emit-TableAxisBlock {
	param($block, [string]$indent, [bool]$emitName = $true)
	if ($emitName -and $block.name) {
		X "$indent<dcsset:name>$(Esc-Xml "$($block.name)")</dcsset:name>"
	}
	$gb = if ($block.groupBy) { $block.groupBy } else { $block.groupFields }
	Emit-GroupItems -groupBy $gb -indent $indent
	if ($block.filter) {
		Emit-Filter -items $block.filter -indent $indent
	}
	if ($block.order) {
		Emit-Order -items $block.order -indent $indent
	}
	if ($block.selection) {
		Emit-Selection -items $block.selection -indent $indent
	}
	if ($block.conditionalAppearance) {
		Emit-ConditionalAppearance -items $block.conditionalAppearance -indent $indent
	}
	if ($block.outputParameters) {
		Emit-OutputParameters -params $block.outputParameters -indent $indent
	}
	# nested children (StructureItemGroup внутри table row/column или chart axis).
	# Platform-pattern: items внутри row/column/points/series — ВСЕГДА short form (без xsi:type).
	if ($block.children) {
		foreach ($child in $block.children) {
			Emit-StructureItem -item $child -indent $indent -shortGroup
		}
	}
	if ($block.viewMode) {
		X "$indent<dcsset:viewMode>$(Esc-Xml "$($block.viewMode)")</dcsset:viewMode>"
	}
	if ($block.userSettingID) {
		$uid = if ("$($block.userSettingID)" -eq "auto") { New-Guid-String } else { "$($block.userSettingID)" }
		X "$indent<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	if ($block.userSettingPresentation) {
		Emit-MLText -tag "dcsset:userSettingPresentation" -text $block.userSettingPresentation -indent $indent
	}
	if ($block.itemsViewMode) {
		X "$indent<dcsset:itemsViewMode>$(Esc-Xml "$($block.itemsViewMode)")</dcsset:itemsViewMode>"
	}
}

function Emit-StructureItem {
	param($item, [string]$indent, [switch]$shortGroup)

	$type = if ($item.type) { "$($item.type)" } else { "group" }

	if ($type -eq "group") {
		# Platform пишет короткую форму (без xsi:type) для groups внутри table row/column,
		# explicit StructureItemGroup в остальных случаях.
		if ($shortGroup) {
			X "$indent<dcsset:item>"
		} else {
			X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"
		}

		# use=false — отключённая ветка структуры
		if ($item.use -eq $false) {
			X "$indent`t<dcsset:use>false</dcsset:use>"
		}

		if ($item.name) {
			X "$indent`t<dcsset:name>$(Esc-Xml "$($item.name)")</dcsset:name>"
		}

		$gb = if ($item.groupBy) { $item.groupBy } else { $item.groupFields }
		Emit-GroupItems -groupBy $gb -indent "$indent`t"

		# Emit order/selection only if specified — platform doesn't always emit them on group
		if ($item.order) {
			Emit-Order -items $item.order -indent "$indent`t" -blockViewMode $item.orderViewMode -blockUserSettingID $item.orderUserSettingID
		}
		if ($item.selection) {
			Emit-Selection -items $item.selection -indent "$indent`t"
		}

		Emit-Filter -items $item.filter -indent "$indent`t"

		if ($item.conditionalAppearance) {
			Emit-ConditionalAppearance -items $item.conditionalAppearance -indent "$indent`t"
		}

		if ($item.outputParameters) {
			Emit-OutputParameters -params $item.outputParameters -indent "$indent`t"
		}

		# Nested children — наследуем shortGroup от родителя (если родитель в short form,
		# то и дети остаются short, как делает platform внутри row/column).
		if ($item.children) {
			foreach ($child in $item.children) {
				if ($shortGroup) {
					Emit-StructureItem -item $child -indent "$indent`t" -shortGroup
				} else {
					Emit-StructureItem -item $child -indent "$indent`t"
				}
			}
		}

		# viewMode/itemsViewMode/userSettingID/userSettingPresentation on
		# StructureItemGroup are context-dependent — emit only when explicitly set.
		if ($item.viewMode) {
			X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
		}
		if ($item.userSettingID) {
			$gid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
			X "$indent`t<dcsset:userSettingID>$(Esc-Xml $gid)</dcsset:userSettingID>"
		}
		if ($item.userSettingPresentation) {
			Emit-MLText -tag "dcsset:userSettingPresentation" -text $item.userSettingPresentation -indent "$indent`t"
		}
		if ($item.itemsViewMode) {
			X "$indent`t<dcsset:itemsViewMode>$(Esc-Xml "$($item.itemsViewMode)")</dcsset:itemsViewMode>"
		}

		X "$indent</dcsset:item>"
	}
	elseif ($type -eq "table") {
		X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemTable`">"

		# use=false — отключённая таблица
		if ($item.use -eq $false) {
			X "$indent`t<dcsset:use>false</dcsset:use>"
		}

		if ($item.name) {
			X "$indent`t<dcsset:name>$(Esc-Xml "$($item.name)")</dcsset:name>"
		}

		# Columns
		if ($item.columns) {
			foreach ($col in $item.columns) {
				X "$indent`t<dcsset:column>"
				Emit-TableAxisBlock -block $col -indent "$indent`t`t"
				X "$indent`t</dcsset:column>"
			}
		}

		# Rows
		if ($item.rows) {
			foreach ($row in $item.rows) {
				X "$indent`t<dcsset:row>"
				Emit-TableAxisBlock -block $row -indent "$indent`t`t"
				X "$indent`t</dcsset:row>"
			}
		}

		# Top-level: selection / conditionalAppearance / outputParameters на самой таблице
		if ($item.selection) {
			Emit-Selection -items $item.selection -indent "$indent`t"
		}
		if ($item.conditionalAppearance) {
			Emit-ConditionalAppearance -items $item.conditionalAppearance -indent "$indent`t"
		}
		if ($item.outputParameters) {
			Emit-OutputParameters -params $item.outputParameters -indent "$indent`t"
		}
		# columnsViewMode / rowsViewMode — axis-level режим доступности (после rows/columns)
		if ($item.columnsViewMode) {
			X "$indent`t<dcsset:columnsViewMode>$(Esc-Xml "$($item.columnsViewMode)")</dcsset:columnsViewMode>"
		}
		if ($item.rowsViewMode) {
			X "$indent`t<dcsset:rowsViewMode>$(Esc-Xml "$($item.rowsViewMode)")</dcsset:rowsViewMode>"
		}
		# viewMode / userSettingID / userSettingPresentation / itemsViewMode на самой таблице
		if ($item.viewMode) {
			X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
		}
		if ($item.userSettingID) {
			$gid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
			X "$indent`t<dcsset:userSettingID>$(Esc-Xml $gid)</dcsset:userSettingID>"
		}
		if ($item.userSettingPresentation) {
			Emit-MLText -tag "dcsset:userSettingPresentation" -text $item.userSettingPresentation -indent "$indent`t"
		}
		if ($item.itemsViewMode) {
			X "$indent`t<dcsset:itemsViewMode>$(Esc-Xml "$($item.itemsViewMode)")</dcsset:itemsViewMode>"
		}

		X "$indent</dcsset:item>"
	}
	elseif ($type -eq "chart") {
		X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemChart`">"

		# use=false — отключённая диаграмма
		if ($item.use -eq $false) {
			X "$indent`t<dcsset:use>false</dcsset:use>"
		}

		if ($item.name) {
			X "$indent`t<dcsset:name>$(Esc-Xml "$($item.name)")</dcsset:name>"
		}

		# Points — single object или массив (multi-series диаграмма)
		if ($item.points) {
			$pBlocks = if ($item.points -is [array] -or ($item.points -is [System.Collections.IList] -and $item.points -isnot [string])) {
				@($item.points)
			} else { @($item.points) }
			# Эвристика: если это массив объектов (а не одиночный объект-с-полями) → multi.
			$isPointsArray = ($item.points -is [array]) -or ($item.points -is [System.Collections.IList] -and $item.points -isnot [string] -and $item.points -isnot [System.Collections.IDictionary] -and $item.points -isnot [PSCustomObject])
			if ($isPointsArray) {
				foreach ($pb in $pBlocks) {
					X "$indent`t<dcsset:point>"
					Emit-TableAxisBlock -block $pb -indent "$indent`t`t"
					X "$indent`t</dcsset:point>"
				}
			} else {
				X "$indent`t<dcsset:point>"
				Emit-TableAxisBlock -block $item.points -indent "$indent`t`t"
				X "$indent`t</dcsset:point>"
			}
		}

		# Series — single object или массив
		if ($item.series) {
			$isSeriesArray = ($item.series -is [array]) -or ($item.series -is [System.Collections.IList] -and $item.series -isnot [string] -and $item.series -isnot [System.Collections.IDictionary] -and $item.series -isnot [PSCustomObject])
			if ($isSeriesArray) {
				foreach ($sb in @($item.series)) {
					X "$indent`t<dcsset:series>"
					Emit-TableAxisBlock -block $sb -indent "$indent`t`t"
					X "$indent`t</dcsset:series>"
				}
			} else {
				X "$indent`t<dcsset:series>"
				Emit-TableAxisBlock -block $item.series -indent "$indent`t`t"
				X "$indent`t</dcsset:series>"
			}
		}

		# Selection (chart values)
		Emit-Selection -items $item.selection -indent "$indent`t"

		if ($item.outputParameters) {
			Emit-OutputParameters -params $item.outputParameters -indent "$indent`t"
		}

		# pointsViewMode / seriesViewMode — axis-level режим доступности (после points/series)
		if ($item.pointsViewMode) {
			X "$indent`t<dcsset:pointsViewMode>$(Esc-Xml "$($item.pointsViewMode)")</dcsset:pointsViewMode>"
		}
		if ($item.seriesViewMode) {
			X "$indent`t<dcsset:seriesViewMode>$(Esc-Xml "$($item.seriesViewMode)")</dcsset:seriesViewMode>"
		}
		# viewMode / userSettingID / userSettingPresentation / itemsViewMode на самой диаграмме
		if ($item.viewMode) {
			X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
		}
		if ($item.userSettingID) {
			$gid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
			X "$indent`t<dcsset:userSettingID>$(Esc-Xml $gid)</dcsset:userSettingID>"
		}
		if ($item.userSettingPresentation) {
			Emit-MLText -tag "dcsset:userSettingPresentation" -text $item.userSettingPresentation -indent "$indent`t"
		}
		if ($item.itemsViewMode) {
			X "$indent`t<dcsset:itemsViewMode>$(Esc-Xml "$($item.itemsViewMode)")</dcsset:itemsViewMode>"
		}

		X "$indent</dcsset:item>"
	}
	elseif ($type -eq "nestedObject") {
		X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemNestedObject`">"
		if ($item.objectID) { X "$indent`t<dcsset:objectID>$(Esc-Xml "$($item.objectID)")</dcsset:objectID>" }
		X "$indent`t<dcsset:settings>"
		$s = $item.settings
		if ($s) {
			if ($s.selection)             { Emit-Selection -items $s.selection -indent "$indent`t`t" }
			if ($s.filter)                { Emit-Filter -items $s.filter -indent "$indent`t`t" }
			if ($s.order)                 { Emit-Order -items $s.order -indent "$indent`t`t" }
			if ($s.conditionalAppearance) { Emit-ConditionalAppearance -items $s.conditionalAppearance -indent "$indent`t`t" }
			if ($s.outputParameters)      { Emit-OutputParameters -params $s.outputParameters -indent "$indent`t`t" }
		}
		X "$indent`t</dcsset:settings>"
		X "$indent</dcsset:item>"
	}
}

function Emit-SettingsVariants {
	$variants = $def.settingsVariants

	# Default variant if none specified
	if (-not $variants -or $variants.Count -eq 0) {
		$variants = @(@{
			name = "Основной"
			presentation = "Основной"
			settings = @{
				selection = @("Auto")
				structure = @(@{
					type = "group"
					order = @("Auto")
					selection = @("Auto")
				})
			}
		})
		# Convert to PSCustomObject-like structure
		$variants = @($variants | ForEach-Object {
			$v = New-Object PSObject
			$v | Add-Member -NotePropertyName "name" -NotePropertyValue $_.name
			$v | Add-Member -NotePropertyName "presentation" -NotePropertyValue $_.presentation
			$settingsObj = New-Object PSObject
			$settingsObj | Add-Member -NotePropertyName "selection" -NotePropertyValue $_.settings.selection
			$structItem = New-Object PSObject
			$structItem | Add-Member -NotePropertyName "type" -NotePropertyValue "group"
			$structItem | Add-Member -NotePropertyName "order" -NotePropertyValue @("Auto")
			$structItem | Add-Member -NotePropertyName "selection" -NotePropertyValue @("Auto")
			$settingsObj | Add-Member -NotePropertyName "structure" -NotePropertyValue @($structItem)
			$v | Add-Member -NotePropertyName "settings" -NotePropertyValue $settingsObj
			$v
		})
	}

	foreach ($v in $variants) {
		X "`t<settingsVariant>"
		X "`t`t<dcsset:name>$(Esc-Xml "$($v.name)")</dcsset:name>"

		$pres = if ($v.presentation) { $v.presentation } elseif ($v.title) { $v.title } else { "$($v.name)" }
		Emit-MLText -tag "dcsset:presentation" -text $pres -indent "`t`t"

		X "`t`t<dcsset:settings xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`">"

		$s = $v.settings

		# Helper: resolve XViewMode/XUserSettingID from settings — emit only if explicitly set
		function Get-BlockVM([string]$key) {
			$prop = "${key}ViewMode"
			if ($s.PSObject.Properties[$prop]) { return "$($s.$prop)" }
			return $null
		}
		function Get-BlockUSID([string]$key) {
			$prop = "${key}UserSettingID"
			if ($s.PSObject.Properties[$prop]) { return "$($s.$prop)" }
			return $null
		}

		# userFields — пользовательские вычисляемые поля (Expression / Case)
		if ($s.userFields -and $s.userFields.Count -gt 0) {
			Emit-UserFields -items $s.userFields -indent "`t`t`t"
		}

		# Selection — эмитим даже если items пустые, но есть block-level viewMode/userSettingID.
		# Platform может содержать Auto-items на top-level (вместе с явными полями).
		$svm = Get-BlockVM 'selection';  $susid = Get-BlockUSID 'selection'
		if ($s.selection -or $null -ne $svm -or $null -ne $susid) {
			Emit-Selection -items $s.selection -indent "`t`t`t" -blockViewMode $svm -blockUserSettingID $susid
		}

		# Filter
		$fvm = Get-BlockVM 'filter';  $fusid = Get-BlockUSID 'filter'
		if ($s.filter -or $null -ne $fvm -or $null -ne $fusid) {
			Emit-Filter -items $s.filter -indent "`t`t`t" -blockViewMode $fvm -blockUserSettingID $fusid
		}

		# Order
		$ovm = Get-BlockVM 'order';  $ousid = Get-BlockUSID 'order'
		if ($s.order -or $null -ne $ovm -or $null -ne $ousid) {
			Emit-Order -items $s.order -indent "`t`t`t" -blockViewMode $ovm -blockUserSettingID $ousid
		}

		# ConditionalAppearance
		$cavm = Get-BlockVM 'conditionalAppearance';  $causid = Get-BlockUSID 'conditionalAppearance'
		if ($s.conditionalAppearance -or $null -ne $cavm -or $null -ne $causid) {
			Emit-ConditionalAppearance -items $s.conditionalAppearance -indent "`t`t`t" -blockViewMode $cavm -blockUserSettingID $causid
		}

		# OutputParameters (platform does NOT emit <viewMode> on this block)
		if ($s.outputParameters) {
			Emit-OutputParameters -params $s.outputParameters -indent "`t`t`t"
		}

		# DataParameters
		if ($s.dataParameters -eq 'auto') {
			# Auto-generate dataParameters for all non-hidden params.
			# Pattern follows 1C Designer / ERP persistence:
			#   - value set (non-default)     → emit value, use=true (implicit)
			#   - value missing / Custom period → <use>false</use> + <value xsi:nil="true"/>
			$autoDP = @()
			foreach ($ap in $script:allParams) {
				if ($ap.hidden) { continue }
				$dpItem = New-Object PSObject
				$dpItem | Add-Member -NotePropertyName "parameter" -NotePropertyValue $ap.name
				$dpItem | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue "auto"

				$hasMeaningfulValue = $false

				if ($ap.type -eq 'StandardPeriod') {
					# Inherit variant; Custom is treated as "empty"
					$variant = 'Custom'
					$av = $ap.value
					if ($null -ne $av) {
						if (($av -is [PSCustomObject] -or $av -is [hashtable]) -and $av.variant) {
							$variant = "$($av.variant)"
						} elseif ("$av") {
							$variant = "$av"
						}
					}
					$dpItem | Add-Member -NotePropertyName "value" -NotePropertyValue @{ variant = $variant }
					if ($variant -ne 'Custom') { $hasMeaningfulValue = $true }
				} elseif (-not (Test-EmptyValue $ap.value)) {
					$dpItem | Add-Member -NotePropertyName "value" -NotePropertyValue $ap.value
					$dpItem | Add-Member -NotePropertyName "valueType" -NotePropertyValue "$($ap.type)"
					$hasMeaningfulValue = $true
				} else {
					$dpItem | Add-Member -NotePropertyName "nilValue" -NotePropertyValue $true
				}

				if (-not $hasMeaningfulValue) {
					$dpItem | Add-Member -NotePropertyName "use" -NotePropertyValue $false
				}

				$autoDP += $dpItem
			}
			if ($autoDP.Count -gt 0) {
				Emit-DataParameters -items $autoDP -indent "`t`t`t"
			}
		} elseif ($s.dataParameters) {
			Emit-DataParameters -items $s.dataParameters -indent "`t`t`t"
		}

		# Structure (supports string shorthand: "Организация > details")
		if ($s.structure) {
			$structItems = $s.structure
			if ($structItems -is [string]) {
				$structItems = Parse-StructureShorthand $structItems
			}
			foreach ($item in $structItems) {
				Emit-StructureItem -item $item -indent "`t`t`t"
			}
		}

		# <dcsset:itemsViewMode> on <dcsset:settings> — emit only if explicitly set
		if ($s.itemsViewMode) {
			X "`t`t`t<dcsset:itemsViewMode>$(Esc-Xml "$($s.itemsViewMode)")</dcsset:itemsViewMode>"
		}

		# <dcsset:additionalProperties> — key/value свойства варианта
		if ($s.additionalProperties) {
			X "`t`t`t<dcsset:additionalProperties>"
			foreach ($prop in $s.additionalProperties.PSObject.Properties) {
				X "`t`t`t`t<v8:Property name=`"$(Esc-Xml $prop.Name)`">"
				X "`t`t`t`t`t<v8:Value xsi:type=`"xs:string`">$(Esc-Xml "$($prop.Value)")</v8:Value>"
				X "`t`t`t`t</v8:Property>"
			}
			X "`t`t`t</dcsset:additionalProperties>"
		}

		X "`t`t</dcsset:settings>"
		X "`t</settingsVariant>"
	}
}

# --- 12. Assemble XML ---

X "<?xml version=`"1.0`" encoding=`"UTF-8`"?>"
X ("<DataCompositionSchema xmlns=`"http://v8.1c.ru/8.1/data-composition-system/schema`"" +
	" xmlns:dcscom=`"http://v8.1c.ru/8.1/data-composition-system/common`"" +
	" xmlns:dcscor=`"http://v8.1c.ru/8.1/data-composition-system/core`"" +
	" xmlns:dcsset=`"http://v8.1c.ru/8.1/data-composition-system/settings`"" +
	" xmlns:v8=`"http://v8.1c.ru/8.1/data/core`"" +
	" xmlns:v8ui=`"http://v8.1c.ru/8.1/data/ui`"" +
	" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`"" +
	" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">")

Emit-DataSources
Emit-DataSets
Emit-DataSetLinks
Emit-CalcFields
Emit-TotalFields
Emit-Parameters
Emit-Templates
Emit-FieldTemplates
Emit-GroupTemplates
Emit-SettingsVariants

X '</DataCompositionSchema>'

# --- 13. Write output ---

Assert-EditAllowed $OutputPath 'editable'

$parentDir = [System.IO.Path]::GetDirectoryName($OutputPath)
if ($parentDir -and -not (Test-Path $parentDir)) {
	New-Item -ItemType Directory -Force $parentDir | Out-Null
}

$content = $script:xml.ToString()
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($OutputPath, $content, $utf8Bom)

# --- 14. Statistics ---

$dsCount = $def.dataSets.Count
$fieldCount = 0
foreach ($ds in $def.dataSets) {
	if ($ds.fields) { $fieldCount += $ds.fields.Count }
}
$calcCount = if ($def.calculatedFields) { $def.calculatedFields.Count } else { 0 }
$totalCount = if ($def.totalFields) { $def.totalFields.Count } else { 0 }
$paramCount = if ($def.parameters) { $def.parameters.Count } else { 0 }
$variantCount = if ($def.settingsVariants) { $def.settingsVariants.Count } else { 1 }
$fileSize = (Get-Item $OutputPath).Length

Write-Host "OK  $OutputPath"
Write-Host "    DataSets: $dsCount  Fields: $fieldCount  Calculated: $calcCount  Totals: $totalCount  Params: $paramCount  Variants: $variantCount"
Write-Host "    Size: $fileSize bytes"
