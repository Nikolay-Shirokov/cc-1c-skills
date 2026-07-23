# skd-edit v1.30 — Atomic 1C DCS editor
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: парный .py собирает выражения автодат вне f-string ради совместимости с python 3.9 (PEP 701).
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$TemplatePath,

	[Parameter(Mandatory)]
	[ValidateSet(
		"add-field","add-total","add-calculated-field","add-parameter","add-filter",
		"add-dataParameter","add-order","add-selection","add-dataSetLink",
		"add-dataSet","add-variant","add-conditionalAppearance","add-drilldown",
		"set-query","patch-query","set-outputParameter","set-structure",
		"modify-field","modify-filter","modify-dataParameter","modify-parameter","modify-structure","set-field-role",
		"rename-parameter","reorder-parameters",
		"clear-selection","clear-order","clear-filter","clear-conditionalAppearance",
		"remove-field","remove-total","remove-calculated-field","remove-parameter","remove-filter")]
	[string]$Operation,

	[Parameter(Mandatory)]
	[string]$Value,

	[string]$DataSet,
	[string]$Variant,
	[switch]$NoSelection
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Dirty flag — set to $true by every successful mutation. If still $false at save time,
# the file is left untouched (NO-OP operations like [WARN] not found don't rewrite).
$script:Dirty = $false

# --- 1. Resolve path ---

if (-not $TemplatePath.EndsWith(".xml")) {
	$candidate = Join-Path (Join-Path $TemplatePath "Ext") "Template.xml"
	if (Test-Path $candidate) {
		$TemplatePath = $candidate
	}
}

if (-not (Test-Path $TemplatePath)) {
	Write-Error "File not found: $TemplatePath"
	exit 1
}

$resolvedPath = (Resolve-Path $TemplatePath).Path

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

Assert-EditAllowed $resolvedPath 'editable'

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

$script:queryBaseDir = [System.IO.Path]::GetDirectoryName($resolvedPath)

# --- 2. Type system (copied from skd-compile) ---

$script:typeSynonyms = New-Object System.Collections.Hashtable
$script:typeSynonyms["число"] = "decimal"
$script:typeSynonyms["строка"] = "string"
$script:typeSynonyms["булево"] = "boolean"
$script:typeSynonyms["дата"] = "date"
$script:typeSynonyms["датавремя"] = "dateTime"
$script:typeSynonyms["стандартныйпериод"] = "StandardPeriod"
$script:typeSynonyms["bool"] = "boolean"
$script:typeSynonyms["str"] = "string"
$script:typeSynonyms["int"] = "decimal"
$script:typeSynonyms["integer"] = "decimal"
$script:typeSynonyms["number"] = "decimal"
$script:typeSynonyms["num"] = "decimal"
$script:typeSynonyms["справочникссылка"] = "CatalogRef"
$script:typeSynonyms["документссылка"] = "DocumentRef"
$script:typeSynonyms["перечислениессылка"] = "EnumRef"
$script:typeSynonyms["плансчетовссылка"] = "ChartOfAccountsRef"
$script:typeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"

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
}

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }
		return $typeStr
	}

	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }
	return $typeStr
}

# --- 3. Parsers ---

function Parse-FieldShorthand {
	param([string]$s)

	$result = @{
		dataPath = ""; field = ""; title = ""; type = ""
		roles = @(); restrict = @()
	}

	# Extract [Title]
	if ($s -match '\[([^\]]+)\]') {
		$result.title = $Matches[1]
		$s = $s -replace '\s*\[[^\]]+\]', ''
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

function Read-FieldProperties($fieldEl) {
	$props = @{
		dataPath = ""; field = ""; title = ""; type = ""
		roles = @(); restrict = @()
		_rawTitle = $null
		_unknownChildren = @()
	}

	foreach ($ch in $fieldEl.ChildNodes) {
		if ($ch.NodeType -ne 'Element') { continue }
		switch ($ch.LocalName) {
			"dataPath" { $props.dataPath = $ch.InnerText.Trim() }
			"field" { $props.field = $ch.InnerText.Trim() }
			"title" {
				# Preserve full multi-lang title OuterXml — used to keep en/uk/etc.
				# siblings when shorthand overrides only the ru content. Strip xmlns
				# redeclarations that OuterXml adds for sub-elements.
				$raw = $ch.OuterXml
				$raw = [regex]::Replace($raw, ' xmlns(?::\w+)?="[^"]*"', '')
				$props._rawTitle = $raw
				# Also extract ru content as plain string (backward compat — used by
				# external consumers reading $existing.title).
				foreach ($item in $ch.ChildNodes) {
					if ($item.NodeType -eq 'Element' -and $item.LocalName -eq 'item') {
						$lang = $null; $content = $null
						foreach ($gc in $item.ChildNodes) {
							if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'lang') { $lang = $gc.InnerText.Trim() }
							if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'content') { $content = $gc.InnerText.Trim() }
						}
						if ($lang -eq 'ru' -and $null -ne $content) { $props.title = $content }
					}
				}
			}
			"valueType" {
				# Preserve the entire <valueType> OuterXml so rebuild can re-emit qualifiers
				# (StringQualifiers, NumberQualifiers, DateQualifiers, etc.) that would
				# otherwise be lost. Also extract Type string for type-override shorthand.
				$raw = $ch.OuterXml
				# .NET OuterXml re-declares xmlns on every element where the prefix is in
				# scope (because the fragment is treated as standalone). Strip these since
				# the parent context at insertion point already provides them.
				$raw = [regex]::Replace($raw, ' xmlns(?::\w+)?="[^"]*"', '')
				$props["_rawValueType"] = $raw
				$typeEl = $null
				foreach ($gc in $ch.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'Type') {
						$typeEl = $gc; break
					}
				}
				if ($typeEl) {
					$props["_rawTypeText"] = $typeEl.InnerText.Trim()
				}
			}
			"role" {
				foreach ($gc in $ch.ChildNodes) {
					if ($gc.NodeType -eq 'Element') {
						if ($gc.LocalName -eq 'periodNumber') {
							$props.roles += "period"
						} elseif ($gc.InnerText.Trim() -eq 'true') {
							$props.roles += $gc.LocalName
						}
					}
				}
			}
			"useRestriction" {
				$revMap = @{ "field" = "noField"; "condition" = "noFilter"; "group" = "noGroup"; "order" = "noOrder" }
				foreach ($gc in $ch.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.InnerText.Trim() -eq 'true') {
						$mapped = $revMap[$gc.LocalName]
						if ($mapped) { $props.restrict += $mapped }
					}
				}
			}
			default {
				# Defense in depth: preserve OuterXml of unknown children so rebuild
				# doesn't silently drop them (custom <editFormat>, <appearance>, etc.).
				$raw = $ch.OuterXml
				$raw = [regex]::Replace($raw, ' xmlns(?::\w+)?="[^"]*"', '')
				$props._unknownChildren += $raw
			}
		}
	}
	return $props
}

function Parse-TotalShorthand {
	param([string]$s)

	# "DataPath: Func" or "DataPath: Func(expr)" or "DataPath: ИмяРесурса" (identity)
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
		$rhs = $null
	}

	$title = ""
	if ($lhs -match '\[([^\]]+)\]') {
		$title = $Matches[1]
		$lhs = $lhs -replace '\s*\[[^\]]+\]', ''
	}
	$lhs = $lhs.Trim()

	if ($null -ne $rhs) {
		if ($lhs.Contains(':')) {
			$colonIdx = $lhs.IndexOf(':')
			$dataPath = $lhs.Substring(0, $colonIdx).Trim()
			$type = Resolve-TypeStr ($lhs.Substring($colonIdx + 1).Trim())
			return @{ dataPath = $dataPath; expression = $rhs; type = $type; title = $title; restrict = $restrict }
		}
		return @{ dataPath = $lhs; expression = $rhs; type = ""; title = $title; restrict = $restrict }
	}
	return @{ dataPath = $lhs; expression = ""; type = ""; title = $title; restrict = $restrict }
}

function Parse-ParamShorthand {
	param([string]$s)

	$result = @{ name = ""; type = ""; value = $null; autoDates = $false; title = $null; hidden = $false; always = $false; availableValues = @(); valueListAllowed = $false }

	# Extract availableValue=... (must be before main parse — captures to end of string)
	if ($s -match '\s*availableValue=(.+)$') {
		$result.availableValues = Parse-AvailableValueList $Matches[1].Trim()
		$s = ($s -replace '\s*availableValue=.+$', '').Trim()
	}

	if ($s -match '@autoDates') {
		$result.autoDates = $true
		$s = $s -replace '\s*@autoDates', ''
	}

	if ($s -match '@valueList\b') {
		$result.valueListAllowed = $true
		$s = $s -replace '\s*@valueList\b', ''
	}

	if ($s -match '@hidden\b') {
		$result.hidden = $true
		$s = $s -replace '\s*@hidden\b', ''
	}

	if ($s -match '@always\b') {
		$result.always = $true
		$s = $s -replace '\s*@always\b', ''
	}

	# Extract optional [Title] (mirrors Parse-FieldShorthand)
	if ($s -match '\[([^\]]*)\]') {
		$result.title = $Matches[1].Trim()
		$s = ($s -replace '\s*\[[^\]]*\]\s*', ' ').Trim()
	}

	# Split "Name: Type = Value" — RHS may be empty (`= ` / `=`) → treated as empty-value sentinel
	if ($s -match '^([^:]+):\s*(\S+)(\s*=\s*(.*))?$') {
		$result.name = $Matches[1].Trim()
		$result.type = Resolve-TypeStr ($Matches[2].Trim())
		$hasEq = $null -ne $Matches[3]
		$rhs = $Matches[4]
		if ($hasEq) {
			if ($rhs -and $rhs.Trim()) {
				$items = Parse-ValueList $rhs.Trim()
				if ($items.Count -ge 2) {
					# Multi-value default → list; valueListAllowed implied
					$result.value = $items
					$result.valueListAllowed = $true
				} else {
					# Scalar (single item, quotes stripped) or empty sentinel
					$result.value = if ($items.Count -eq 1) { $items[0] } else { "" }
				}
			} else {
				$result.value = ""
			}
		}
	} else {
		$result.name = $s.Trim()
	}

	return $result
}

function Parse-FilterShorthand {
	param([string]$s)

	# use is tristate: $null = not specified (modify-* won't touch),
	# $false = @off (explicit), $true = @on (explicit). add-* writes <use>false</use> only when $false.
	$result = @{ field = ""; op = "Equal"; value = $null; use = $null; userSettingID = $null; viewMode = $null }

	if ($s -match '@user') {
		$result.userSettingID = "auto"
		$s = $s -replace '\s*@user', ''
	}
	if ($s -match '@off') {
		$result.use = $false
		$s = $s -replace '\s*@off', ''
	}
	if ($s -match '@on\b') {
		$result.use = $true
		$s = $s -replace '\s*@on\b', ''
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

	$opPatterns = @('<>', '>=', '<=', '=', '>', '<',
		'notIn\b', 'in\b', 'inHierarchy\b', 'inListByHierarchy\b',
		'notContains\b', 'contains\b', 'notBeginsWith\b', 'beginsWith\b',
		'notFilled\b', 'filled\b')
	$opJoined = $opPatterns -join '|'

	if ($s -match "^(.+?)\s+($opJoined)\s*(.*)?$") {
		$result.field = $Matches[1].Trim()
		$opRaw = $Matches[2].Trim()
		$valPart = if ($Matches[3]) { $Matches[3].Trim() } else { "" }

		$opMap = @{
			"=" = "Equal"; "<>" = "NotEqual"; ">" = "Greater"; ">=" = "GreaterOrEqual"
			"<" = "Less"; "<=" = "LessOrEqual"; "in" = "InList"; "notIn" = "NotInList"
			"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
			"contains" = "Contains"; "notContains" = "NotContains"
			"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
			"filled" = "Filled"; "notFilled" = "NotFilled"
		}
		$mapped = $opMap[$opRaw]
		if ($mapped) { $result.op = $mapped } else { $result.op = $opRaw }

		if ($valPart -and $valPart -ne "_") {
			if ($valPart -eq "true" -or $valPart -eq "false") {
				$result.value = $valPart
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
		$result.field = $s
	}

	return $result
}

function Parse-DataParamShorthand {
	param([string]$s)

	# use is tristate: $null = not specified (modify-* won't touch),
	# $false = @off (explicit), $true = @on (explicit). add-* writes <use>false</use> only when $false.
	$result = @{ parameter = ""; value = $null; use = $null; userSettingID = $null; viewMode = $null }

	if ($s -match '@user') {
		$result.userSettingID = "auto"
		$s = $s -replace '\s*@user', ''
	}
	if ($s -match '@off') {
		$result.use = $false
		$s = $s -replace '\s*@off', ''
	}
	if ($s -match '@on\b') {
		$result.use = $true
		$s = $s -replace '\s*@on\b', ''
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

	if ($s -match '^([^=]+)=\s*(.*)$') {
		$result.parameter = $Matches[1].Trim()
		$valStr = $Matches[2].Trim()

		$periodVariants = @("Custom","Today","ThisWeek","ThisTenDays","ThisMonth","ThisQuarter","ThisHalfYear","ThisYear","FromBeginningOfThisWeek","FromBeginningOfThisTenDays","FromBeginningOfThisMonth","FromBeginningOfThisQuarter","FromBeginningOfThisHalfYear","FromBeginningOfThisYear","LastWeek","LastTenDays","LastMonth","LastQuarter","LastHalfYear","LastYear","NextDay","NextWeek","NextTenDays","NextMonth","NextQuarter","NextHalfYear","NextYear","TillEndOfThisWeek","TillEndOfThisTenDays","TillEndOfThisMonth","TillEndOfThisQuarter","TillEndOfThisHalfYear","TillEndOfThisYear")
		# Empty / sentinel — record as "" so caller emits xsi:nil
		if ($valStr -eq "" -or $valStr -eq "_" -or $valStr.ToLowerInvariant() -eq "null") {
			$result.value = ""
		} elseif ($periodVariants -contains $valStr) {
			$result.value = @{ variant = $valStr }
		} else {
			$result.value = $valStr
		}
	} else {
		$result.parameter = $s
	}

	return $result
}

function Parse-OrderShorthand {
	param([string]$s)
	$s = $s.Trim()
	if ($s -eq "Auto") {
		return @{ field = "Auto"; direction = "" }
	}
	$parts = $s -split '\s+', 2
	$field = $parts[0]
	$dir = "Asc"
	if ($parts.Count -gt 1 -and $parts[1] -match '(?i)^desc$') { $dir = "Desc" }
	return @{ field = $field; direction = $dir }
}

function Parse-DataSetLinkShorthand {
	param([string]$s)

	$result = @{ source = ""; dest = ""; sourceExpr = ""; destExpr = ""; parameter = "" }

	# Extract optional [param ParamName]
	if ($s -match '\[param\s+([^\]]+)\]') {
		$result.parameter = $Matches[1].Trim()
		$s = $s -replace '\s*\[param\s+[^\]]+\]', ''
	}

	# Pattern: "Source > Dest on FieldA = FieldB"
	if ($s -match '^(.+?)\s*>\s*(.+?)\s+on\s+(.+?)\s*=\s*(.+)$') {
		$result.source = $Matches[1].Trim()
		$result.dest = $Matches[2].Trim()
		$result.sourceExpr = $Matches[3].Trim()
		$result.destExpr = $Matches[4].Trim()
	} else {
		Write-Error "Invalid dataSetLink shorthand: $s. Expected: 'Source > Dest on FieldA = FieldB [param Name]'"
		exit 1
	}

	return $result
}

function Parse-DataSetShorthand {
	param([string]$s)

	$s = $s.Trim()
	# "Name: QUERY" — split on first ": " only if prefix is a single word (no spaces)
	if ($s -match '^(\S+):\s(.+)$') {
		return @{ name = $Matches[1]; query = $Matches[2] }
	}
	return @{ name = ""; query = $s }
}

function Parse-VariantShorthand {
	param([string]$s)

	$presentation = ""
	if ($s -match '\[([^\]]+)\]') {
		$presentation = $Matches[1]
		$s = $s -replace '\s*\[[^\]]+\]', ''
	}
	$name = $s.Trim()
	if (-not $presentation) { $presentation = $name }
	return @{ name = $name; presentation = $presentation }
}

function Parse-ConditionalAppearanceShorthand {
	param([string]$s)

	$result = @{ param = ""; value = ""; filter = $null; fields = @() }

	# Extract " when ..." — condition part
	$whenIdx = $s.IndexOf(' when ')
	$forIdx = $s.IndexOf(' for ')

	# Determine boundaries
	$mainEnd = $s.Length
	if ($whenIdx -ge 0 -and $forIdx -ge 0) {
		$mainEnd = [Math]::Min($whenIdx, $forIdx)
	} elseif ($whenIdx -ge 0) {
		$mainEnd = $whenIdx
	} elseif ($forIdx -ge 0) {
		$mainEnd = $forIdx
	}

	# Parse "for" fields
	if ($forIdx -ge 0) {
		$forEnd = $s.Length
		if ($whenIdx -gt $forIdx) { $forEnd = $whenIdx }
		$forPart = $s.Substring($forIdx + 5, $forEnd - $forIdx - 5).Trim()
		$result.fields = @($forPart -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	}

	# Parse "when" filter (supports " or " for OrGroup)
	if ($whenIdx -ge 0) {
		$whenEnd = $s.Length
		if ($forIdx -gt $whenIdx) { $whenEnd = $forIdx }
		$whenPart = $s.Substring($whenIdx + 6, $whenEnd - $whenIdx - 6).Trim()
		$orParts = $whenPart -split '\s+or\s+'
		if ($orParts.Count -gt 1) {
			$result.filter = @($orParts | ForEach-Object { Parse-FilterShorthand $_.Trim() })
		} else {
			$result.filter = Parse-FilterShorthand $whenPart
		}
	}

	# Parse main part: "Param = Value"
	$mainPart = $s.Substring(0, $mainEnd).Trim()
	$eqIdx = $mainPart.IndexOf('=')
	if ($eqIdx -gt 0) {
		$result.param = $mainPart.Substring(0, $eqIdx).Trim()
		$result.value = $mainPart.Substring($eqIdx + 1).Trim()
	} else {
		$result.param = $mainPart
	}

	return $result
}

function Parse-StructureShorthand {
	param([string]$s)

	$segments = $s -split '\s*>\s*'
	$result = @()

	$innermost = $null
	for ($i = $segments.Count - 1; $i -ge 0; $i--) {
		$seg = $segments[$i].Trim()
		$group = @{ type = "group" }

		if ($seg -match '@name=(?:"([^"]+)"|''([^'']+)''|(\S+))') {
			$rawName = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { $Matches[3] }
			$group["name"] = $rawName.Trim()
			$seg = ($seg -replace '\s*@name=(?:"[^"]+"|''[^'']+''|\S+)', '').Trim()
		}

		if ($seg -match '^(?i)(details|детали)$') {
			$group["groupBy"] = @()
		} else {
			$fields = @($seg -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
			$group["groupBy"] = $fields
		}

		if ($null -ne $innermost) {
			$group["children"] = @($innermost)
		}
		$innermost = $group
	}

	if ($innermost) { $result += $innermost }
	return ,$result
}

function Parse-OutputParamShorthand {
	param([string]$s)
	$idx = $s.IndexOf('=')
	if ($idx -gt 0) {
		return @{
			key = $s.Substring(0, $idx).Trim()
			value = $s.Substring($idx + 1).Trim()
		}
	}
	return @{ key = $s.Trim(); value = "" }
}

function Split-QuotedCsv {
	# Splits on top-level commas, respecting 'single' and "double" quoted spans.
	# Returns raw (un-stripped, un-trimmed) item spans. Used by both availableValue
	# (value:presentation) and value-list (values only) parsing.
	param([string]$s)
	$items = @()
	if ($null -eq $s) { return ,$items }
	$buf = New-Object System.Text.StringBuilder
	$inQuote = $null
	for ($i = 0; $i -lt $s.Length; $i++) {
		$ch = $s[$i]
		if ($inQuote) {
			[void]$buf.Append($ch)
			if ($ch -eq $inQuote) { $inQuote = $null }
		} elseif ($ch -eq "'" -or $ch -eq '"') {
			$inQuote = $ch
			[void]$buf.Append($ch)
		} elseif ($ch -eq ',') {
			$items += $buf.ToString()
			[void]$buf.Clear()
		} else {
			[void]$buf.Append($ch)
		}
	}
	if ($buf.Length -gt 0) { $items += $buf.ToString() }
	return ,$items
}

function Strip-Quotes {
	# Strips a single surrounding pair of matching quotes; trims first.
	param([string]$t)
	$t = $t.Trim()
	if ($t.Length -ge 2 -and (($t[0] -eq "'" -and $t[-1] -eq "'") -or ($t[0] -eq '"' -and $t[-1] -eq '"'))) {
		return $t.Substring(1, $t.Length - 2)
	}
	return $t
}

function Parse-ValueList {
	# Returns array of value strings (quotes stripped) split by top-level commas.
	# No ':' handling — values may contain colons (e.g. dateTime 2024-01-01T12:30:00).
	param([string]$s)
	$result = @()
	if ($null -eq $s) { return ,$result }
	foreach ($raw in (Split-QuotedCsv $s)) {
		$v = Strip-Quotes $raw
		if ($v -ne "") { $result += $v }
	}
	return ,$result
}

function Parse-AvailableValueList {
	# Returns array of @{ value=...; presentation=... } from comma-separated list.
	# Items can use 'single' or "double" quotes (stripped). Quoted spans preserve commas/colons.
	param([string]$s)

	$result = @()
	if (-not $s) { return ,$result }

	$items = Split-QuotedCsv $s
	$stripQuotes = { param($t) Strip-Quotes $t }

	foreach ($raw in $items) {
		$item = $raw.Trim()
		if (-not $item) { continue }

		# Find first ':' outside quotes
		$colonIdx = -1
		$q = $null
		for ($j = 0; $j -lt $item.Length; $j++) {
			$c = $item[$j]
			if ($q) {
				if ($c -eq $q) { $q = $null }
			} elseif ($c -eq "'" -or $c -eq '"') {
				$q = $c
			} elseif ($c -eq ':') {
				$colonIdx = $j; break
			}
		}

		if ($colonIdx -ge 0) {
			$valPart = $item.Substring(0, $colonIdx)
			$presPart = $item.Substring($colonIdx + 1)
			$result += @{ value = (& $stripQuotes $valPart); presentation = (& $stripQuotes $presPart) }
		} else {
			$result += @{ value = (& $stripQuotes $item); presentation = "" }
		}
	}

	return ,$result
}

# --- 4. Build-* functions (XML fragment generators) ---

function Build-ValueTypeXml {
	param($typeStr, [string]$indent)

	if (-not $typeStr) { return "" }

	# Composite: array of types — concatenate per-type fragments
	if ($typeStr -is [array] -or $typeStr -is [System.Collections.IList]) {
		$parts = @()
		foreach ($t in $typeStr) {
			$p = Build-ValueTypeXml -typeStr "$t" -indent $indent
			if ($p) { $parts += $p }
		}
		return $parts -join "`n"
	}

	$typeStr = Resolve-TypeStr "$typeStr"
	$lines = @()

	if ($typeStr -eq "boolean") {
		$lines += "$indent<v8:Type>xs:boolean</v8:Type>"
		return $lines -join "`n"
	}

	# string, string(N), string(N,fix) — fix → AllowedLength=Fixed
	if ($typeStr -match '^string(\((\d+)(,(fix|fixed))?\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		$al  = if ($Matches[4]) { "Fixed" } else { "Variable" }
		$lines += "$indent<v8:Type>xs:string</v8:Type>"
		$lines += "$indent<v8:StringQualifiers>"
		$lines += "$indent`t<v8:Length>$len</v8:Length>"
		$lines += "$indent`t<v8:AllowedLength>$al</v8:AllowedLength>"
		$lines += "$indent</v8:StringQualifiers>"
		return $lines -join "`n"
	}

	# decimal forms — bare decimal = money 10,2; decimal(N) = integer N,0
	if ($typeStr -match '^decimal(\((\d+)(,(\d+))?(,nonneg)?\))?$') {
		if (-not $Matches[1]) {
			$digits = "10"; $fraction = "2"; $sign = "Any"
		} else {
			$digits = $Matches[2]
			$fraction = if ($Matches[4]) { $Matches[4] } else { "0" }
			$sign = if ($Matches[5]) { "Nonnegative" } else { "Any" }
		}
		$lines += "$indent<v8:Type>xs:decimal</v8:Type>"
		$lines += "$indent<v8:NumberQualifiers>"
		$lines += "$indent`t<v8:Digits>$digits</v8:Digits>"
		$lines += "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		$lines += "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		$lines += "$indent</v8:NumberQualifiers>"
		return $lines -join "`n"
	}

	# date / dateTime / time — all xs:dateTime, differ only in DateFractions
	if ($typeStr -match '^(date|dateTime|time)$') {
		$fractions = switch ($typeStr) {
			"date"     { "Date" }
			"dateTime" { "DateTime" }
			"time"     { "Time" }
		}
		$lines += "$indent<v8:Type>xs:dateTime</v8:Type>"
		$lines += "$indent<v8:DateQualifiers>"
		$lines += "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		$lines += "$indent</v8:DateQualifiers>"
		return $lines -join "`n"
	}

	if ($typeStr -eq "StandardPeriod") {
		$lines += "$indent<v8:Type>v8:StandardPeriod</v8:Type>"
		return $lines -join "`n"
	}

	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.') {
		$lines += "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return $lines -join "`n"
	}

	if ($typeStr.Contains('.')) {
		$lines += "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return $lines -join "`n"
	}

	$lines += "$indent<v8:Type>$(Esc-Xml $typeStr)</v8:Type>"
	return $lines -join "`n"
}

# Sentinel-normalized empty check — null / "" / "_" / "null" (case-insensitive).
function Test-EmptyValue {
	param($v)
	if ($null -eq $v) { return $true }
	$s = "$v".Trim()
	if ($s -eq "") { return $true }
	if ($s -eq "_") { return $true }
	if ($s.ToLowerInvariant() -eq "null") { return $true }
	return $false
}

# Returns XML fragment string for a type-aware empty <value>.
# Empty + valueListAllowed → omit entirely (returns $null).
# tagPrefix used for dcscor: in data parameters.
function Build-EmptyValueXml {
	param([string]$type, [string]$indent, [string]$tagPrefix = "", [string]$tagName = "value", [bool]$valueListAllowed = $false)
	if ($valueListAllowed) { return $null }
	$t = if ($null -eq $type) { "" } else { "$type" }
	# Strip well-known XML schema prefixes so callers can pass raw <v8:Type> text
	$t = $t -replace '^xs:', '' -replace '^v8:', '' -replace '^d\d+p\d+:', ''
	$pf = $tagPrefix
	$tn = $tagName
	$lines = @()
	if ($t -eq "") {
		$lines += "$indent<${pf}${tn} xsi:nil=`"true`"/>"
	} elseif ($t -eq "StandardPeriod") {
		$lines += "$indent<${pf}${tn} xsi:type=`"v8:StandardPeriod`">"
		$lines += "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">Custom</v8:variant>"
		$lines += "$indent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
		$lines += "$indent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
		$lines += "$indent</${pf}${tn}>"
	} elseif ($t -match '^string') {
		$lines += "$indent<${pf}${tn} xsi:type=`"xs:string`"/>"
	} elseif ($t -match '^(date|time)') {
		$lines += "$indent<${pf}${tn} xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</${pf}${tn}>"
	} elseif ($t -match '^decimal') {
		$lines += "$indent<${pf}${tn} xsi:type=`"xs:decimal`">0</${pf}${tn}>"
	} elseif ($t -eq "boolean") {
		$lines += "$indent<${pf}${tn} xsi:type=`"xs:boolean`">false</${pf}${tn}>"
	} else {
		# Ref types or unknown — safe nil
		$lines += "$indent<${pf}${tn} xsi:nil=`"true`"/>"
	}
	return $lines -join "`n"
}

function Build-MLTextXml {
	param([string]$tag, [string]$text, [string]$indent)
	$lines = @()
	$lines += "$indent<$tag xsi:type=`"v8:LocalStringType`">"
	$lines += "$indent`t<v8:item>"
	$lines += "$indent`t`t<v8:lang>ru</v8:lang>"
	$lines += "$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
	$lines += "$indent`t</v8:item>"
	$lines += "$indent</$tag>"
	return $lines -join "`n"
}

# Patches the ru <v8:content> within an existing multi-lang title OuterXml, preserving
# en/uk/etc. siblings. Used when modify-* operates with a title-override shorthand on a
# field/parameter that already has multi-language titles (typical in ERP/БП/ЗУП).
# If no ru item exists, one is prepended before the first existing item.
function Patch-MLTextRu {
	param([string]$rawOuterXml, [string]$newRuText, [string]$indent)
	$escaped = Esc-Xml $newRuText
	$ruItemPat = '(<v8:item>\s*<v8:lang>ru</v8:lang>\s*<v8:content>)[^<]*(</v8:content>\s*</v8:item>)'
	if ([regex]::IsMatch($rawOuterXml, $ruItemPat)) {
		return [regex]::Replace($rawOuterXml, $ruItemPat, { param($m) $m.Groups[1].Value + $escaped + $m.Groups[2].Value })
	}
	# No ru item — prepend one inside the title element, before first <v8:item>.
	$prep = "$indent`t<v8:item>`n$indent`t`t<v8:lang>ru</v8:lang>`n$indent`t`t<v8:content>$escaped</v8:content>`n$indent`t</v8:item>"
	if ($rawOuterXml -match '<v8:item>') {
		$re = New-Object System.Text.RegularExpressions.Regex('(\s*)<v8:item>')
		return $re.Replace($rawOuterXml, "`n$prep`$1<v8:item>", 1)
	}
	# Empty title — inject after opening tag.
	$re2 = New-Object System.Text.RegularExpressions.Regex('(<(?:\w+:)?title[^>]*>)')
	return $re2.Replace($rawOuterXml, "`$1`n$prep`n$indent", 1)
}

function Build-RoleXml {
	param([string[]]$roles, [string]$indent)

	if (-not $roles -or $roles.Count -eq 0) { return "" }

	$lines = @()
	$lines += "$indent<role>"
	foreach ($role in $roles) {
		if ($role -eq "period") {
			$lines += "$indent`t<dcscom:periodNumber>1</dcscom:periodNumber>"
			$lines += "$indent`t<dcscom:periodType>Main</dcscom:periodType>"
		} else {
			$lines += "$indent`t<dcscom:$role>true</dcscom:$role>"
		}
	}
	$lines += "$indent</role>"
	return $lines -join "`n"
}

function Build-RestrictionXml {
	param([string[]]$restrict, [string]$indent)

	if (-not $restrict -or $restrict.Count -eq 0) { return "" }

	$restrictMap = @{
		"noField" = "field"; "noFilter" = "condition"; "noCondition" = "condition"
		"noGroup" = "group"; "noOrder" = "order"
	}

	$lines = @()
	$lines += "$indent<useRestriction>"
	foreach ($r in $restrict) {
		$xmlName = $restrictMap["$r"]
		if ($xmlName) {
			$lines += "$indent`t<$xmlName>true</$xmlName>"
		}
	}
	$lines += "$indent</useRestriction>"
	return $lines -join "`n"
}

function Build-FieldFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<field xsi:type=`"DataSetFieldField`">"
	$lines += "$i`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
	$lines += "$i`t<field>$(Esc-Xml $parsed.field)</field>"

	# Title: prefer raw multi-lang title (preserves en/uk/etc.). When shorthand provides
	# a new ru text, patch ru content inside the raw title; otherwise emit raw as-is.
	# When no raw title exists, fall back to ru-only build from shorthand.
	if ($parsed._rawTitle) {
		if ($parsed.title -and $parsed.title -ne $parsed._existingTitleRu) {
			$lines += "$i`t" + (Patch-MLTextRu $parsed._rawTitle $parsed.title "$i`t")
		} else {
			$lines += "$i`t" + $parsed._rawTitle
		}
	} elseif ($parsed.title) {
		$lines += (Build-MLTextXml -tag "title" -text $parsed.title -indent "$i`t")
	}

	if ($parsed.restrict -and $parsed.restrict.Count -gt 0) {
		$lines += (Build-RestrictionXml -restrict $parsed.restrict -indent "$i`t")
	}

	$roleXml = Build-RoleXml -roles $parsed.roles -indent "$i`t"
	if ($roleXml) { $lines += $roleXml }

	if ($parsed.rawValueType) {
		# Preserve original <valueType> verbatim — keeps qualifiers (StringQualifiers,
		# NumberQualifiers, DateQualifiers, …) that aren't expressible via shorthand.
		$lines += "$i`t" + $parsed.rawValueType
	} elseif ($parsed.type) {
		$lines += "$i`t<valueType>"
		$lines += (Build-ValueTypeXml -typeStr $parsed.type -indent "$i`t`t")
		$lines += "$i`t</valueType>"
	}

	# Defense in depth: re-emit OuterXml of unknown children (e.g. <editFormat>,
	# <appearance>, custom extensions) that Read-FieldProperties captured.
	if ($parsed._unknownChildren) {
		foreach ($raw in $parsed._unknownChildren) {
			$lines += "$i`t" + $raw
		}
	}

	$lines += "$i</field>"
	return $lines -join "`n"
}

function Build-TotalFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<totalField>"
	$lines += "$i`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
	$lines += "$i`t<expression>$(Esc-Xml $parsed.expression)</expression>"
	$lines += "$i</totalField>"
	return $lines -join "`n"
}

function Build-CalcFieldFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<calculatedField>"
	$lines += "$i`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
	$lines += "$i`t<expression>$(Esc-Xml $parsed.expression)</expression>"

	if ($parsed.title) {
		$lines += (Build-MLTextXml -tag "title" -text $parsed.title -indent "$i`t")
	}

	if ($parsed.restrict -and $parsed.restrict.Count -gt 0) {
		$lines += (Build-RestrictionXml -restrict $parsed.restrict -indent "$i`t")
	}

	if ($parsed.type) {
		$lines += "$i`t<valueType>"
		$lines += (Build-ValueTypeXml -typeStr $parsed.type -indent "$i`t`t")
		$lines += "$i`t</valueType>"
	}

	$lines += "$i</calculatedField>"
	return $lines -join "`n"
}

function Build-ParamValueXml {
	# Returns array of XML lines for a <value xsi:type=...>...</value> element (or StandardPeriod block).
	# Selects xsi:type by declared type, then falls back to value pattern.
	param([string]$type, [string]$value, [string]$indent, [string]$tagName = "value", [string]$tagNs = "")

	$i = $indent
	$valStr = "$value"
	$open = if ($tagNs) { "$tagNs`:$tagName" } else { $tagName }
	$lines = @()

	if ($type -eq "StandardPeriod") {
		$lines += "$i<$open xsi:type=`"v8:StandardPeriod`">"
		$lines += "$i`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $valStr)</v8:variant>"
		$lines += "$i`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
		$lines += "$i`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
		$lines += "$i</$open>"
		return $lines
	}

	$xsi = $null
	if ($type -match '^date') { $xsi = "xs:dateTime" }
	elseif ($type -eq "boolean") { $xsi = "xs:boolean" }
	elseif ($type -match '^decimal') { $xsi = "xs:decimal" }
	elseif ($type -match '^string') { $xsi = "xs:string" }
	elseif ($type -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef)\.') {
		$xsi = "dcscor:DesignTimeValue"
	}
	else {
		# Type unknown or empty — guess from value
		if ($valStr -match '^\d{4}-\d{2}-\d{2}T') { $xsi = "xs:dateTime" }
		elseif ($valStr -eq "true" -or $valStr -eq "false") { $xsi = "xs:boolean" }
		elseif ($valStr -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or
		        $valStr -match '^(Catalog|Document|Enum|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') {
			$xsi = "dcscor:DesignTimeValue"
		}
		else { $xsi = "xs:string" }
	}

	$lines += "$i<$open xsi:type=`"$xsi`">$(Esc-Xml $valStr)</$open>"
	return $lines
}

function Build-AvailableValueFragment {
	# Returns XML lines (array) for a single <availableValue> block.
	param($item, [string]$declaredType, [string]$indent)

	$lines = @()
	$lines += "$indent<availableValue>"
	if (Test-EmptyValue $item.value) {
		$emptyXml = Build-EmptyValueXml -type $declaredType -indent "$indent`t" -tagPrefix "" -tagName "value" -valueListAllowed $false
		if ($emptyXml) { $lines += $emptyXml }
	} else {
		$valueLines = Build-ParamValueXml -type $declaredType -value $item.value -indent "$indent`t"
		foreach ($vl in $valueLines) { $lines += $vl }
	}
	if ($item.presentation) {
		$lines += "$indent`t<presentation xsi:type=`"v8:LocalStringType`">"
		$lines += "$indent`t`t<v8:item>"
		$lines += "$indent`t`t`t<v8:lang>ru</v8:lang>"
		$lines += "$indent`t`t`t<v8:content>$(Esc-Xml $item.presentation)</v8:content>"
		$lines += "$indent`t`t</v8:item>"
		$lines += "$indent`t</presentation>"
	}
	$lines += "$indent</availableValue>"
	return $lines
}

function Build-ParamFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$fragments = @()

	$lines = @()
	$lines += "$i<parameter>"
	$lines += "$i`t<name>$(Esc-Xml $parsed.name)</name>"

	if ($parsed.title) {
		$lines += (Build-MLTextXml -tag "title" -text $parsed.title -indent "$i`t")
	}

	if ($parsed.type) {
		$lines += "$i`t<valueType>"
		$lines += (Build-ValueTypeXml -typeStr $parsed.type -indent "$i`t`t")
		$lines += "$i`t</valueType>"
	}

	$vla = [bool]$parsed.valueListAllowed
	$valIsArray = ($parsed.value -is [array]) -or ($parsed.value -is [System.Collections.IList] -and $parsed.value -isnot [string])
	if ($valIsArray) {
		# Multi-value default (value-list): one <value> per item
		foreach ($v in $parsed.value) {
			$valueLines = Build-ParamValueXml -type $parsed.type -value $v -indent "$i`t"
			foreach ($vl in $valueLines) { $lines += $vl }
		}
	} elseif ($null -ne $parsed.value) {
		if (Test-EmptyValue $parsed.value) {
			$emptyXml = Build-EmptyValueXml -type $parsed.type -indent "$i`t" -tagPrefix "" -tagName "value" -valueListAllowed $vla
			if ($emptyXml) { $lines += $emptyXml }
		} else {
			$valueLines = Build-ParamValueXml -type $parsed.type -value $parsed.value -indent "$i`t"
			foreach ($vl in $valueLines) { $lines += $vl }
		}
	}

	if ($parsed.hidden) {
		$lines += "$i`t<useRestriction>true</useRestriction>"
		$lines += "$i`t<availableAsField>false</availableAsField>"
	}

	if ($vla) {
		$lines += "$i`t<valueListAllowed>true</valueListAllowed>"
	}

	if ($parsed.availableValues -and $parsed.availableValues.Count -gt 0) {
		foreach ($av in $parsed.availableValues) {
			$avLines = Build-AvailableValueFragment -item $av -declaredType $parsed.type -indent "$i`t"
			foreach ($l in $avLines) { $lines += $l }
		}
	}

	if ($parsed.always) {
		$lines += "$i`t<use>Always</use>"
	}

	$lines += "$i</parameter>"
	$fragments += ($lines -join "`n")

	if ($parsed.autoDates) {
		$paramName = $parsed.name

		# Canonical БСП pattern: title + valueType + value + useRestriction + expression
		$bLines = @()
		$bLines += "$i<parameter>"
		$bLines += "$i`t<name>ДатаНачала</name>"
		$bLines += (Build-MLTextXml -tag "title" -text "Начало периода" -indent "$i`t")
		$bLines += "$i`t<valueType>"
		$bLines += (Build-ValueTypeXml -typeStr "date" -indent "$i`t`t")
		$bLines += "$i`t</valueType>"
		$bLines += "$i`t<value xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</value>"
		$bLines += "$i`t<useRestriction>true</useRestriction>"
		$bLines += "$i`t<expression>$(Esc-Xml "&$paramName.ДатаНачала")</expression>"
		$bLines += "$i</parameter>"
		$fragments += ($bLines -join "`n")

		$eLines = @()
		$eLines += "$i<parameter>"
		$eLines += "$i`t<name>ДатаОкончания</name>"
		$eLines += (Build-MLTextXml -tag "title" -text "Конец периода" -indent "$i`t")
		$eLines += "$i`t<valueType>"
		$eLines += (Build-ValueTypeXml -typeStr "date" -indent "$i`t`t")
		$eLines += "$i`t</valueType>"
		$eLines += "$i`t<value xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</value>"
		$eLines += "$i`t<useRestriction>true</useRestriction>"
		$eLines += "$i`t<expression>$(Esc-Xml "&$paramName.ДатаОкончания")</expression>"
		$eLines += "$i</parameter>"
		$fragments += ($eLines -join "`n")
	}

	return ,$fragments
}

function Build-FilterItemFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"

	if ($parsed.use -eq $false) {
		$lines += "$i`t<dcsset:use>false</dcsset:use>"
	}

	$lines += "$i`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-Xml $parsed.field)</dcsset:left>"
	$lines += "$i`t<dcsset:comparisonType>$(Esc-Xml $parsed.op)</dcsset:comparisonType>"

	if ($null -ne $parsed.value) {
		$vt = if ($parsed["valueType"]) { $parsed["valueType"] } else { "xs:string" }
		$lines += "$i`t<dcsset:right xsi:type=`"$vt`">$(Esc-Xml "$($parsed.value)")</dcsset:right>"
	}

	if ($parsed.viewMode) {
		$lines += "$i`t<dcsset:viewMode>$(Esc-Xml $parsed.viewMode)</dcsset:viewMode>"
	}

	if ($parsed.userSettingID) {
		$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
		$lines += "$i`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}

	$lines += "$i</dcsset:item>"
	return $lines -join "`n"
}

function Build-SelectionItemFragment {
	param([string]$fieldName, [string]$indent)

	$i = $indent
	$lines = @()
	if ($fieldName -eq "Auto") {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	} elseif ($fieldName -match '^Folder\((.+)\)$') {
		$inner = $Matches[1]
		$colonIdx = $inner.IndexOf(':')
		if ($colonIdx -gt 0) {
			$title = $inner.Substring(0, $colonIdx).Trim()
			$items = $inner.Substring($colonIdx + 1) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
		} else {
			$title = ""
			$items = $inner -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
		}
		$lines += "$i<dcsset:item xsi:type=`"dcsset:SelectedItemFolder`">"
		if ($title) {
			$lines += "$i`t<dcsset:lwsTitle>"
			$lines += "$i`t`t<v8:item>"
			$lines += "$i`t`t`t<v8:lang>ru</v8:lang>"
			$lines += "$i`t`t`t<v8:content>$(Esc-Xml $title)</v8:content>"
			$lines += "$i`t`t</v8:item>"
			$lines += "$i`t</dcsset:lwsTitle>"
		}
		foreach ($item in $items) {
			$lines += "$i`t<dcsset:item xsi:type=`"dcsset:SelectedItemField`">"
			$lines += "$i`t`t<dcsset:field>$(Esc-Xml $item)</dcsset:field>"
			$lines += "$i`t</dcsset:item>"
		}
		$lines += "$i`t<dcsset:placement>Auto</dcsset:placement>"
		$lines += "$i</dcsset:item>"
	} else {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:SelectedItemField`">"
		$lines += "$i`t<dcsset:field>$(Esc-Xml $fieldName)</dcsset:field>"
		$lines += "$i</dcsset:item>"
	}
	return $lines -join "`n"
}

function Build-DataParamFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"

	if ($parsed.use -eq $false) {
		$lines += "$i`t<dcscor:use>false</dcscor:use>"
	}

	$lines += "$i`t<dcscor:parameter>$(Esc-Xml $parsed.parameter)</dcscor:parameter>"

	if ($null -ne $parsed.value) {
		if ($parsed.value -is [hashtable] -and $parsed.value.variant) {
			$lines += "$i`t<dcscor:value xsi:type=`"v8:StandardPeriod`">"
			$lines += "$i`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $parsed.value.variant)</v8:variant>"
			$lines += "$i`t`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
			$lines += "$i`t`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
			$lines += "$i`t</dcscor:value>"
		} elseif (Test-EmptyValue $parsed.value) {
			$lines += "$i`t<dcscor:value xsi:nil=`"true`"/>"
		} elseif ("$($parsed.value)" -match '^\d{4}-\d{2}-\d{2}T') {
			$lines += "$i`t<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
		} elseif ("$($parsed.value)" -eq "true" -or "$($parsed.value)" -eq "false") {
			$lines += "$i`t<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
		} else {
			$lines += "$i`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
		}
	}

	if ($parsed.viewMode) {
		$lines += "$i`t<dcsset:viewMode>$(Esc-Xml $parsed.viewMode)</dcsset:viewMode>"
	}

	if ($parsed.userSettingID) {
		$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
		$lines += "$i`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}

	$lines += "$i</dcscor:item>"
	return $lines -join "`n"
}

function Build-OrderItemFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	if ($parsed.field -eq "Auto") {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
	} else {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
		$lines += "$i`t<dcsset:field>$(Esc-Xml $parsed.field)</dcsset:field>"
		$lines += "$i`t<dcsset:orderType>$($parsed.direction)</dcsset:orderType>"
		$lines += "$i</dcsset:item>"
	}
	return $lines -join "`n"
}

function Build-DataSetLinkFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dataSetLink>"
	$lines += "$i`t<sourceDataSet>$(Esc-Xml $parsed.source)</sourceDataSet>"
	$lines += "$i`t<destinationDataSet>$(Esc-Xml $parsed.dest)</destinationDataSet>"
	$lines += "$i`t<sourceExpression>$(Esc-Xml $parsed.sourceExpr)</sourceExpression>"
	$lines += "$i`t<destinationExpression>$(Esc-Xml $parsed.destExpr)</destinationExpression>"
	if ($parsed.parameter) {
		$lines += "$i`t<parameter>$(Esc-Xml $parsed.parameter)</parameter>"
	}
	$lines += "$i</dataSetLink>"
	return $lines -join "`n"
}

function Build-DataSetQueryFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dataSet xsi:type=`"DataSetQuery`">"
	$lines += "$i`t<name>$(Esc-Xml $parsed.name)</name>"
	$lines += "$i`t<dataSource>$(Esc-Xml $parsed.dataSource)</dataSource>"
	$lines += "$i`t<query>$(Esc-Xml $parsed.query)</query>"
	$lines += "$i</dataSet>"
	return $lines -join "`n"
}

function Build-VariantFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<settingsVariant>"
	$lines += "$i`t<dcsset:name>$(Esc-Xml $parsed.name)</dcsset:name>"
	$lines += (Build-MLTextXml -tag "dcsset:presentation" -text $parsed.presentation -indent "$i`t")
	$lines += "$i`t<dcsset:settings xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`">"
	$lines += "$i`t`t<dcsset:selection>"
	$lines += "$i`t`t`t<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	$lines += "$i`t`t</dcsset:selection>"
	$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"
	$lines += "$i`t`t`t<dcsset:groupItems/>"
	$lines += "$i`t`t`t<dcsset:order>"
	$lines += "$i`t`t`t`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
	$lines += "$i`t`t`t</dcsset:order>"
	$lines += "$i`t`t`t<dcsset:selection>"
	$lines += "$i`t`t`t`t<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	$lines += "$i`t`t`t</dcsset:selection>"
	$lines += "$i`t`t</dcsset:item>"
	$lines += "$i`t</dcsset:settings>"
	$lines += "$i</settingsVariant>"
	return $lines -join "`n"
}

function Emit-FilterComparison {
	param($f, [string]$indent)
	$lines = @()
	$lines += "$indent<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"
	$lines += "$indent`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-Xml $f.field)</dcsset:left>"
	$lines += "$indent`t<dcsset:comparisonType>$(Esc-Xml $f.op)</dcsset:comparisonType>"
	if ($null -ne $f.value) {
		$vt = if ($f["valueType"]) { $f["valueType"] } else { "xs:string" }
		$lines += "$indent`t<dcsset:right xsi:type=`"$vt`">$(Esc-Xml "$($f.value)")</dcsset:right>"
	}
	$lines += "$indent</dcsset:item>"
	return $lines
}

function Build-ConditionalAppearanceItemFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcsset:item>"

	# selection
	if ($parsed.fields -and $parsed.fields.Count -gt 0) {
		$lines += "$i`t<dcsset:selection>"
		foreach ($fld in $parsed.fields) {
			$lines += "$i`t`t<dcsset:item>"
			$lines += "$i`t`t`t<dcsset:field>$(Esc-Xml $fld)</dcsset:field>"
			$lines += "$i`t`t</dcsset:item>"
		}
		$lines += "$i`t</dcsset:selection>"
	} else {
		$lines += "$i`t<dcsset:selection/>"
	}

	# filter
	if ($parsed.filter) {
		$lines += "$i`t<dcsset:filter>"
		if ($parsed.filter -is [array]) {
			# OrGroup
			$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:FilterItemGroup`">"
			$lines += "$i`t`t`t<dcsset:groupType>OrGroup</dcsset:groupType>"
			foreach ($f in $parsed.filter) {
				$lines += Emit-FilterComparison $f "$i`t`t`t"
			}
			$lines += "$i`t`t</dcsset:item>"
		} else {
			$lines += Emit-FilterComparison $parsed.filter "$i`t`t"
		}
		$lines += "$i`t</dcsset:filter>"
	} else {
		$lines += "$i`t<dcsset:filter/>"
	}

	# appearance
	$lines += "$i`t<dcsset:appearance>"

	$val = $parsed.value
	$lines += "$i`t`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
	$lines += "$i`t`t`t<dcscor:parameter>$(Esc-Xml $parsed.param)</dcscor:parameter>"

	if ($val -match '^(web|style|win):') {
		$lines += "$i`t`t`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $val)</dcscor:value>"
	} elseif ($val -eq "true" -or $val -eq "false") {
		$lines += "$i`t`t`t<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml $val)</dcscor:value>"
	} elseif ($parsed.param -eq "Формат" -or $parsed.param -eq "Текст" -or $parsed.param -eq "Заголовок") {
		$lines += "$i`t`t`t<dcscor:value xsi:type=`"v8:LocalStringType`">"
		$lines += "$i`t`t`t`t<v8:item>"
		$lines += "$i`t`t`t`t`t<v8:lang>ru</v8:lang>"
		$lines += "$i`t`t`t`t`t<v8:content>$(Esc-Xml $val)</v8:content>"
		$lines += "$i`t`t`t`t</v8:item>"
		$lines += "$i`t`t`t</dcscor:value>"
	} else {
		$lines += "$i`t`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml $val)</dcscor:value>"
	}

	$lines += "$i`t`t</dcscor:item>"
	$lines += "$i`t</dcsset:appearance>"

	$lines += "$i</dcsset:item>"
	return $lines -join "`n"
}

function Build-StructureItemFragment {
	param($item, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"

	# name
	if ($item["name"]) {
		$lines += "$i`t<dcsset:name>$(Esc-Xml $item["name"])</dcsset:name>"
	}

	# groupItems
	$groupBy = $item["groupBy"]
	if (-not $groupBy -or $groupBy.Count -eq 0) {
		$lines += "$i`t<dcsset:groupItems/>"
	} else {
		$lines += "$i`t<dcsset:groupItems>"
		foreach ($field in $groupBy) {
			$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
			$lines += "$i`t`t`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
			$lines += "$i`t`t`t<dcsset:groupType>Items</dcsset:groupType>"
			$lines += "$i`t`t`t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>"
			$lines += "$i`t`t`t<dcsset:periodAdditionBegin xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionBegin>"
			$lines += "$i`t`t`t<dcsset:periodAdditionEnd xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionEnd>"
			$lines += "$i`t`t</dcsset:item>"
		}
		$lines += "$i`t</dcsset:groupItems>"
	}

	# order (Auto)
	$lines += "$i`t<dcsset:order>"
	$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
	$lines += "$i`t</dcsset:order>"

	# selection (Auto)
	$lines += "$i`t<dcsset:selection>"
	$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	$lines += "$i`t</dcsset:selection>"

	# Recursive children
	if ($item["children"]) {
		foreach ($child in $item["children"]) {
			$childXml = Build-StructureItemFragment -item $child -indent "$i`t"
			$lines += $childXml
		}
	}

	$lines += "$i</dcsset:item>"
	return $lines -join "`n"
}

function Build-OutputParamFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$key = $parsed.key
	$val = $parsed.value
	$ptype = $script:outputParamTypes[$key]
	if (-not $ptype) { $ptype = "xs:string" }

	$lines = @()
	$lines += "$i<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
	$lines += "$i`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"

	if ($ptype -eq "mltext") {
		$lines += "$i`t<dcscor:value xsi:type=`"v8:LocalStringType`">"
		$lines += "$i`t`t<v8:item>"
		$lines += "$i`t`t`t<v8:lang>ru</v8:lang>"
		$lines += "$i`t`t`t<v8:content>$(Esc-Xml $val)</v8:content>"
		$lines += "$i`t`t</v8:item>"
		$lines += "$i`t</dcscor:value>"
	} else {
		$lines += "$i`t<dcscor:value xsi:type=`"$ptype`">$(Esc-Xml $val)</dcscor:value>"
	}

	$lines += "$i</dcscor:item>"
	return $lines -join "`n"
}

# --- 5. XML helpers ---

function Import-Fragment($doc, [string]$xmlString) {
	$wrapper = @"
<_W xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"
    xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
    xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
    xmlns:v8ui="http://v8.1c.ru/8.1/data/ui">$xmlString</_W>
"@
	$frag = New-Object System.Xml.XmlDocument
	$frag.PreserveWhitespace = $true
	$frag.LoadXml($wrapper)
	$nodes = @()
	foreach ($child in $frag.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $doc.ImportNode($child, $true)
		}
	}
	return ,$nodes
}

function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			$text = $child.Value
			if ($text -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($text -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	$depth = 0
	$current = $container
	while ($current -and $current -ne $xmlDoc.DocumentElement) {
		$depth++
		$current = $current.ParentNode
	}
	return "`t" * ($depth + 1)
}

function Insert-BeforeElement($container, $newNode, $refNode, $childIndent) {
	# LF line endings — 1С DCS files use LF consistently; CRLF causes idempotency
	# leaks when modify-* removes one whitespace and inserts a different-style one.
	$ws = $xmlDoc.CreateWhitespace("`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $ws) | Out-Null
	} else {
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$container.InsertBefore($ws, $trailing) | Out-Null
			$container.InsertBefore($newNode, $trailing) | Out-Null
		} else {
			$container.AppendChild($ws) | Out-Null
			$container.AppendChild($newNode) | Out-Null
			$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
			$closeWs = $xmlDoc.CreateWhitespace("`n$parentIndent")
			$container.AppendChild($closeWs) | Out-Null
		}
	}
}

function Clear-ContainerChildren($container) {
	$toRemove = @()
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$toRemove += $child
		}
	}
	foreach ($el in $toRemove) {
		Remove-NodeWithWhitespace $el
	}
}

function Remove-NodeWithWhitespace($node) {
	$parent = $node.ParentNode
	$prev = $node.PreviousSibling
	$next = $node.NextSibling

	if ($prev -and ($prev.NodeType -eq 'Whitespace' -or $prev.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($prev) | Out-Null
	} elseif ($next -and ($next.NodeType -eq 'Whitespace' -or $next.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($next) | Out-Null
	}
	$parent.RemoveChild($node) | Out-Null
}

function Find-FirstElement($container, [string[]]$localNames, [string]$nsUri) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			foreach ($name in $localNames) {
				if ($child.LocalName -eq $name) {
					if (-not $nsUri -or $child.NamespaceURI -eq $nsUri) {
						return $child
					}
				}
			}
		}
	}
	return $null
}

function Find-LastElement($container, [string]$localName, [string]$nsUri) {
	$last = $null
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $localName) {
			if (-not $nsUri -or $child.NamespaceURI -eq $nsUri) {
				$last = $child
			}
		}
	}
	return $last
}

function Find-ElementByChildValue($container, [string]$elemName, [string]$childName, [string]$childValue, [string]$nsUri) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		if ($child.LocalName -ne $elemName) { continue }
		if ($nsUri -and $child.NamespaceURI -ne $nsUri) { continue }

		foreach ($gc in $child.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq $childName -and $gc.InnerText.Trim() -eq $childValue) {
				return $child
			}
		}
	}
	return $null
}

function Set-OrCreateChildElement($parent, [string]$localName, [string]$nsUri, [string]$value, [string]$indent) {
	$existing = $null
	foreach ($ch in $parent.ChildNodes) {
		if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq $localName -and $ch.NamespaceURI -eq $nsUri) {
			$existing = $ch
			break
		}
	}
	if ($existing) {
		$existing.InnerText = $value
	} else {
		$prefix = $parent.GetPrefixOfNamespace($nsUri)
		$qualName = if ($prefix) { "${prefix}:$localName" } else { $localName }
		$fragXml = "$indent<$qualName>$(Esc-Xml $value)</$qualName>"
		$nodes = Import-Fragment $xmlDoc $fragXml
		foreach ($node in $nodes) {
			Insert-BeforeElement $parent $node $null $indent
		}
	}
}

function Set-OrCreateChildElementWithAttr($parent, [string]$localName, [string]$nsUri, [string]$value, [string]$xsiType, [string]$indent) {
	$existing = $null
	foreach ($ch in $parent.ChildNodes) {
		if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq $localName -and $ch.NamespaceURI -eq $nsUri) {
			$existing = $ch
			break
		}
	}
	if ($existing) {
		$existing.InnerText = $value
		if ($xsiType) {
			$existing.SetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance", $xsiType) | Out-Null
		}
	} else {
		$prefix = $parent.GetPrefixOfNamespace($nsUri)
		$qualName = if ($prefix) { "${prefix}:$localName" } else { $localName }
		$typeAttr = if ($xsiType) { " xsi:type=`"$xsiType`"" } else { "" }
		$fragXml = "$indent<$qualName$typeAttr>$(Esc-Xml $value)</$qualName>"
		$nodes = Import-Fragment $xmlDoc $fragXml
		foreach ($node in $nodes) {
			Insert-BeforeElement $parent $node $null $indent
		}
	}
}

function Get-AllDataSets {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$root = $xmlDoc.DocumentElement
	$result = @()
	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'dataSet' -and $child.NamespaceURI -eq $schNs) {
			$result += $child
		}
	}
	return ,$result
}

function Normalize-LineEndings([string]$s) {
	if ($null -eq $s) { return $s }
	return $s.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Escape-Whitespace([string]$s) {
	$sb = New-Object System.Text.StringBuilder
	foreach ($c in $s.ToCharArray()) {
		$code = [int]$c
		if ($c -eq "`n") { [void]$sb.Append('\n') }
		elseif ($c -eq "`r") { [void]$sb.Append('\r') }
		elseif ($c -eq "`t") { [void]$sb.Append('\t') }
		elseif ($code -lt 32 -or $code -eq 0xA0 -or ($code -ge 0x2000 -and $code -le 0x200F) -or $code -eq 0xFEFF) {
			[void]$sb.AppendFormat('\u{0:X4}', $code)
		} else {
			[void]$sb.Append($c)
		}
	}
	return $sb.ToString()
}

function Collapse-Whitespace([string]$s) {
	return ([regex]::Replace($s, "[\s ]+", " ")).Trim()
}

function Find-LongestPrefixMatch([string]$haystack, [string]$needle) {
	# Binary search: largest L such that needle.Substring(0, L) is a substring of haystack.
	# Monotonic — if length L matches at position P, then length L-1 (prefix) also matches at P.
	if ($needle.Length -eq 0 -or $haystack.Length -eq 0) {
		return @{ Length = 0; Offset = -1 }
	}
	if ($haystack.IndexOf([string]$needle[0]) -lt 0) {
		return @{ Length = 0; Offset = -1 }
	}
	$lo = 1; $hi = $needle.Length
	$bestLen = 1; $bestOffset = $haystack.IndexOf([string]$needle[0])
	while ($lo -le $hi) {
		$mid = [int](($lo + $hi) / 2)
		$idx = $haystack.IndexOf($needle.Substring(0, $mid))
		if ($idx -ge 0) { $bestLen = $mid; $bestOffset = $idx; $lo = $mid + 1 }
		else { $hi = $mid - 1 }
	}
	return @{ Length = $bestLen; Offset = $bestOffset }
}

function Format-PatchQueryNotFound([string]$oldStr, [string]$queryText, $currentDsNode, [string]$dsName) {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$lines = @("Substring not found in query of dataset '$dsName'.")

	# Step 1 — cross-dataset probe
	foreach ($ds in (Get-AllDataSets)) {
		if ($ds -eq $currentDsNode) { continue }
		$q = Find-FirstElement $ds @("query") $schNs
		if (-not $q) { continue }
		$qt = Normalize-LineEndings $q.InnerText
		if ($qt.Contains($oldStr)) {
			$otherName = Get-DataSetName $ds
			$lines += "Found in dataset '$otherName' instead — wrong -DataSet?"
			return ($lines -join "`n")
		}
	}

	# Step 2 — tolerant probe (whitespace + NBSP collapsed)
	$normNeedle = Collapse-Whitespace $oldStr
	$normHay = Collapse-Whitespace $queryText
	$tolerant = ($normNeedle.Length -gt 0 -and $normHay.Contains($normNeedle))

	# Step 3 — prefix divergence (used by both Step 2 reporting and standalone Step 3)
	$prefix = Find-LongestPrefixMatch -haystack $queryText -needle $oldStr
	$divergence = $null
	if ($prefix.Length -gt 0 -and $prefix.Length -lt $oldStr.Length) {
		$queryPos = $prefix.Offset + $prefix.Length
		$searchChar = $oldStr[$prefix.Length]
		$beforeLen = [Math]::Min(20, $prefix.Length)
		$before = $oldStr.Substring($prefix.Length - $beforeLen, $beforeLen)
		$divergence = [ordered]@{
			matched = $prefix.Length
			total = $oldStr.Length
			before = $before
			searchChar = $searchChar
			queryChar = $(if ($queryPos -lt $queryText.Length) { $queryText[$queryPos] } else { $null })
		}
	}

	if ($tolerant) {
		$lines += "Not found exactly, but would match with whitespace normalized (tabs/spaces/NBSP)."
		if ($divergence) {
			$lines += "Diverged at offset $($divergence.matched) of $($divergence.total):"
			$lines += "  before:    '$(Escape-Whitespace $divergence.before)'"
			$lines += "  in search: '$(Escape-Whitespace ([string]$divergence.searchChar))' (U+$('{0:X4}' -f [int]$divergence.searchChar))"
			if ($null -ne $divergence.queryChar) {
				$lines += "  in query:  '$(Escape-Whitespace ([string]$divergence.queryChar))' (U+$('{0:X4}' -f [int]$divergence.queryChar))"
			}
		}
		return ($lines -join "`n")
	}

	# Step 3 standalone
	if ($prefix.Length -eq 0) {
		$lines += "No common prefix with query. Check -DataSet (current: '$dsName')."
		return ($lines -join "`n")
	}
	$lines += "Matched first $($divergence.matched) of $($divergence.total) chars, then diverged:"
	$lines += "  before:    '$(Escape-Whitespace $divergence.before)'"
	$lines += "  in search: '$(Escape-Whitespace ([string]$divergence.searchChar))' (U+$('{0:X4}' -f [int]$divergence.searchChar))"
	if ($null -ne $divergence.queryChar) {
		$lines += "  in query:  '$(Escape-Whitespace ([string]$divergence.queryChar))' (U+$('{0:X4}' -f [int]$divergence.queryChar))"
	} else {
		$lines += "  in query:  (end of query)"
	}
	return ($lines -join "`n")
}

function Resolve-DataSet {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$root = $xmlDoc.DocumentElement

	if ($DataSet) {
		foreach ($child in $root.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'dataSet' -and $child.NamespaceURI -eq $schNs) {
				$nameEl = $null
				foreach ($gc in $child.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $schNs) {
						$nameEl = $gc
						break
					}
				}
				if ($nameEl -and $nameEl.InnerText -eq $DataSet) {
					return $child
				}
			}
		}
		Write-Error "DataSet '$DataSet' not found"
		exit 1
	}

	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'dataSet' -and $child.NamespaceURI -eq $schNs) {
			return $child
		}
	}
	Write-Error "No dataSet found in DCS"
	exit 1
}

function Resolve-VariantSettings {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$setNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
	$root = $xmlDoc.DocumentElement

	$sv = $null
	if ($Variant) {
		foreach ($child in $root.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'settingsVariant' -and $child.NamespaceURI -eq $schNs) {
				$nameEl = $null
				foreach ($gc in $child.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $setNs) {
						$nameEl = $gc
						break
					}
				}
				if ($nameEl -and $nameEl.InnerText -eq $Variant) {
					$sv = $child
					break
				}
			}
		}
		if (-not $sv) {
			Write-Error "Variant '$Variant' not found"
			exit 1
		}
	} else {
		foreach ($child in $root.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'settingsVariant' -and $child.NamespaceURI -eq $schNs) {
				$sv = $child
				break
			}
		}
		if (-not $sv) {
			Write-Error "No settingsVariant found in DCS"
			exit 1
		}
	}

	foreach ($gc in $sv.ChildNodes) {
		if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'settings' -and $gc.NamespaceURI -eq $setNs) {
			return $gc
		}
	}

	Write-Error "No <dcsset:settings> found in variant"
	exit 1
}

function Ensure-SettingsChild($settings, [string]$childName, [string[]]$afterSiblings) {
	$el = Find-FirstElement $settings @($childName) $setNs
	if ($el) { return $el }

	$indent = Get-ChildIndent $settings
	$fragXml = "$indent<dcsset:$childName/>"
	$nodes = Import-Fragment $xmlDoc $fragXml

	$refNode = $null
	foreach ($sibName in $afterSiblings) {
		$sib = Find-FirstElement $settings @($sibName) $setNs
		if ($sib) {
			$refNode = $sib.NextSibling
			while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
				$refNode = $refNode.NextSibling
			}
			break
		}
	}

	foreach ($node in $nodes) {
		Insert-BeforeElement $settings $node $refNode $indent
	}

	return Find-FirstElement $settings @($childName) $setNs
}

function Get-VariantName {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$setNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
	$root = $xmlDoc.DocumentElement

	if ($Variant) { return $Variant }

	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'settingsVariant' -and $child.NamespaceURI -eq $schNs) {
			foreach ($gc in $child.ChildNodes) {
				if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $setNs) {
					return $gc.InnerText
				}
			}
		}
	}
	return "(unknown)"
}

function Get-DataSetName($dsNode) {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	foreach ($gc in $dsNode.ChildNodes) {
		if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $schNs) {
			return $gc.InnerText
		}
	}
	return "(unknown)"
}

function Get-ContainerChildIndent($container) {
	$hasElements = $false
	foreach ($ch in $container.ChildNodes) {
		if ($ch.NodeType -eq 'Element') { $hasElements = $true; break }
	}
	if ($hasElements) {
		return Get-ChildIndent $container
	} else {
		$parentIndent = Get-ChildIndent $container.ParentNode
		return $parentIndent + "`t"
	}
}

# --- 6. Load XML ---

# Capture raw original BEFORE DOM parse — needed at save time to:
#   (a) restore exact root <DataCompositionSchema xmlns=...> opening tag (DOM serializer
#       collapses multi-line xmlns into a single line);
#   (b) detect NO-OP via byte-equality as an extra safety net.
$script:RawOriginal = [System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)
$rootOpenMatch = [regex]::Match($script:RawOriginal, '<DataCompositionSchema\b[^>]*>')
if ($rootOpenMatch.Success) { $script:RawRootOpening = $rootOpenMatch.Value } else { $script:RawRootOpening = $null }

# Detect line ending convention so save can normalize back to whatever the source used.
# 1С Designer writes CRLF on Windows; LF-edited files should stay LF.
$script:LineEnding = if ($script:RawOriginal.Contains("`r`n")) { "`r`n" } else { "`n" }

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($resolvedPath)

$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
$setNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
$corNs = "http://v8.1c.ru/8.1/data-composition-system/core"

# --- 7. Batch value splitting ---

if ($Operation -eq "set-query" -or $Operation -eq "set-structure" -or $Operation -eq "modify-structure" -or $Operation -eq "add-dataSet") {
	$values = @($Value)
} elseif ($Operation -eq "patch-query") {
	$values = @($Value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} elseif ($Operation -eq "add-drilldown") {
	if ($Value.Contains(';;')) {
		$values = @($Value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	} else {
		$values = @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	}
} else {
	$values = @($Value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- 8. Main logic ---

switch ($Operation) {
	"add-field" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		foreach ($val in $values) {
			$parsed = Parse-FieldShorthand $val
			$childIndent = Get-ChildIndent $dsNode

			# Duplicate check
			$existing = Find-ElementByChildValue $dsNode "field" "dataPath" $parsed.dataPath $schNs
			if ($existing) {
				Write-Host "[WARN] Field `"$($parsed.dataPath)`" already exists in dataset `"$dsName`" — skipped"
				continue
			}

			$fragXml = Build-FieldFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			$refNode = Find-FirstElement $dsNode @("dataSource") $schNs
			foreach ($node in $nodes) {
				Insert-BeforeElement $dsNode $node $refNode $childIndent
			}

			$script:Dirty = $true; Write-Host "[OK] Field `"$($parsed.dataPath)`" added to dataset `"$dsName`""

			if (-not $NoSelection) {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Ensure-SettingsChild $settings "selection" @()
				$existingSel = Find-ElementByChildValue $selection "item" "field" $parsed.dataPath $setNs
				if ($existingSel) {
					Write-Host "[INFO] Field `"$($parsed.dataPath)`" already in selection — skipped"
				} else {
					$selIndent = Get-ContainerChildIndent $selection
					$selXml = Build-SelectionItemFragment -fieldName $parsed.dataPath -indent $selIndent
					$selNodes = Import-Fragment $xmlDoc $selXml
					foreach ($node in $selNodes) {
						Insert-BeforeElement $selection $node $null $selIndent
					}
					$script:Dirty = $true; Write-Host "[OK] Field `"$($parsed.dataPath)`" added to selection of variant `"$varName`""
				}
			}
		}
	}

	"add-total" {
		foreach ($val in $values) {
			$parsed = Parse-TotalShorthand $val
			$childIndent = Get-ChildIndent $xmlDoc.DocumentElement

			# Duplicate check
			$existing = Find-ElementByChildValue $xmlDoc.DocumentElement "totalField" "dataPath" $parsed.dataPath $schNs
			if ($existing) {
				Write-Host "[WARN] TotalField `"$($parsed.dataPath)`" already exists — skipped"
				continue
			}

			$fragXml = Build-TotalFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			$root = $xmlDoc.DocumentElement
			$lastTotal = Find-LastElement $root "totalField" $schNs
			if ($lastTotal) {
				$refNode = $lastTotal.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			$script:Dirty = $true; Write-Host "[OK] TotalField `"$($parsed.dataPath)`" = $($parsed.expression) added"
		}
	}

	"add-calculated-field" {
		foreach ($val in $values) {
			$parsed = Parse-CalcShorthand $val
			$childIndent = Get-ChildIndent $xmlDoc.DocumentElement

			# Duplicate check
			$existing = Find-ElementByChildValue $xmlDoc.DocumentElement "calculatedField" "dataPath" $parsed.dataPath $schNs
			if ($existing) {
				Write-Host "[WARN] CalculatedField `"$($parsed.dataPath)`" already exists — skipped"
				continue
			}

			$fragXml = Build-CalcFieldFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			$root = $xmlDoc.DocumentElement
			$lastCalc = Find-LastElement $root "calculatedField" $schNs
			if ($lastCalc) {
				$refNode = $lastCalc.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("totalField","parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			$script:Dirty = $true; Write-Host "[OK] CalculatedField `"$($parsed.dataPath)`" = $($parsed.expression) added"

			if (-not $NoSelection) {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Ensure-SettingsChild $settings "selection" @()
				$existingSel = Find-ElementByChildValue $selection "item" "field" $parsed.dataPath $setNs
				if ($existingSel) {
					Write-Host "[INFO] Field `"$($parsed.dataPath)`" already in selection — skipped"
				} else {
					$selIndent = Get-ContainerChildIndent $selection
					$selXml = Build-SelectionItemFragment -fieldName $parsed.dataPath -indent $selIndent
					$selNodes = Import-Fragment $xmlDoc $selXml
					foreach ($node in $selNodes) {
						Insert-BeforeElement $selection $node $null $selIndent
					}
					$script:Dirty = $true; Write-Host "[OK] Field `"$($parsed.dataPath)`" added to selection of variant `"$varName`""
				}
			}
		}
	}

	"add-parameter" {
		foreach ($val in $values) {
			$parsed = Parse-ParamShorthand $val
			$childIndent = Get-ChildIndent $xmlDoc.DocumentElement

			# Duplicate check
			$existing = Find-ElementByChildValue $xmlDoc.DocumentElement "parameter" "name" $parsed.name $schNs
			if ($existing) {
				Write-Host "[WARN] Parameter `"$($parsed.name)`" already exists — skipped"
				continue
			}

			$fragments = Build-ParamFragment -parsed $parsed -indent $childIndent

			$root = $xmlDoc.DocumentElement
			$lastParam = Find-LastElement $root "parameter" $schNs
			if ($lastParam) {
				$refNode = $lastParam.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($fragXml in $fragments) {
				$nodes = Import-Fragment $xmlDoc $fragXml
				foreach ($node in $nodes) {
					Insert-BeforeElement $root $node $refNode $childIndent
				}
			}

			$script:Dirty = $true; Write-Host "[OK] Parameter `"$($parsed.name)`" added"
			if ($parsed.autoDates) {
				$script:Dirty = $true; Write-Host "[OK] Auto-parameters `"ДатаНачала`", `"ДатаОкончания`" added"
			}
		}
	}

	"modify-parameter" {
		foreach ($val in $values) {
			# Parse: "ParamName [Title] key=value key=value"
			# Extract optional [Title] first (mirrors Parse-FieldShorthand)
			$titleVal = $null
			if ($val -match '\[([^\]]*)\]') {
				$titleVal = $Matches[1].Trim()
				$val = ($val -replace '\s*\[[^\]]*\]\s*', ' ').Trim()
			}

			$parts = $val -split '\s+', 2
			$paramName = $parts[0].Trim()
			$rest = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "" }

			# Extract @hidden / @always flags
			$flagHidden = $false
			$flagAlways = $false
			if ($rest -match '@hidden\b') { $flagHidden = $true; $rest = ($rest -replace '\s*@hidden\b', '').Trim() }
			if ($rest -match '@always\b') { $flagAlways = $true; $rest = ($rest -replace '\s*@always\b', '').Trim() }

			# Find parameter element
			$paramEl = Find-ElementByChildValue $xmlDoc.DocumentElement "parameter" "name" $paramName $schNs
			if (-not $paramEl) {
				Write-Host "[WARN] Parameter `"$paramName`" not found — skipped"
				continue
			}

			$childIndent = Get-ChildIndent $paramEl

			# Set/replace title (must come right after <name>, before <valueType>)
			if ($null -ne $titleVal) {
				$existingTitle = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'title') {
						$existingTitle = $ch; break
					}
				}
				# If the existing title has multiple <v8:item> (multi-language: ru + en + …),
				# patch only the ru <v8:content> via raw-string surgery to preserve other langs.
				# Otherwise rebuild as ru-only fragment.
				$titleFrag = $null
				if ($existingTitle) {
					$rawTitle = $existingTitle.OuterXml
					$rawTitle = [regex]::Replace($rawTitle, ' xmlns(?::\w+)?="[^"]*"', '')
					# Count <v8:item> occurrences — if >1, treat as multi-lang.
					$itemCount = ([regex]::Matches($rawTitle, '<v8:item>')).Count
					if ($itemCount -gt 1) {
						$titleFrag = $childIndent + (Patch-MLTextRu $rawTitle $titleVal $childIndent)
					}
					Remove-NodeWithWhitespace $existingTitle
				}
				if (-not $titleFrag) {
					$titleFrag = Build-MLTextXml -tag "title" -text $titleVal -indent $childIndent
				}
				# Insert before first of (valueType, value, useRestriction, expression, availableAsField, ...)
				$titleRef = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -ne 'name') {
						$titleRef = $ch; break
					}
				}
				$titleNodes = Import-Fragment $xmlDoc $titleFrag
				foreach ($node in $titleNodes) {
					Insert-BeforeElement $paramEl $node $titleRef $childIndent
				}
				$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": title set to `"$titleVal`""
			}

			# Separate availableValue=... from simple kv pairs
			$simpleRest = $rest
			$avPart = $null
			$avIdx = $rest.IndexOf('availableValue=')
			if ($avIdx -ge 0) {
				$simpleRest = $rest.Substring(0, $avIdx).Trim()
				$avPart = $rest.Substring($avIdx)
			}

			# Separate a multi-value value=... (list) — kv-regex below grabs only a single
			# \S+ token, so a comma-separated list (with spaces) wouldn't be captured.
			# availableValue already peeled, so 'value=' here is the real value key.
			$valueListItems = $null
			$vlIdx = $simpleRest.IndexOf('value=')
			if ($vlIdx -ge 0) {
				$vlRhs = $simpleRest.Substring($vlIdx + 'value='.Length)
				$cand = Parse-ValueList $vlRhs
				if ($cand.Count -ge 2) {
					$valueListItems = $cand
					$simpleRest = $simpleRest.Substring(0, $vlIdx).Trim()
				}
			}

			# Process simple key=value pairs (use, denyIncompleteValues, value, etc.)
			if ($simpleRest) {
				$kvPairs = [regex]::Matches($simpleRest, '(\w+)=(\S+)')
				foreach ($kv in $kvPairs) {
					$key = $kv.Groups[1].Value
					$value = $kv.Groups[2].Value

					# Namespace-aware lookup (children live in $schNs)
					$existing = $null
					foreach ($ch in $paramEl.ChildNodes) {
						if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq $key -and $ch.NamespaceURI -eq $schNs) {
							$existing = $ch; break
						}
					}

					if ($key -eq "value") {
						# Special-case: rebuild <value> with correct xsi:type from <valueType>
						$declaredType = ""
						$vtEl = $null
						foreach ($ch in $paramEl.ChildNodes) {
							if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'valueType' -and $ch.NamespaceURI -eq $schNs) { $vtEl = $ch; break }
						}
						if ($vtEl) {
							foreach ($tnode in $vtEl.ChildNodes) {
								if ($tnode.NodeType -eq 'Element' -and $tnode.LocalName -eq 'Type') {
									$declaredType = $tnode.InnerText.Trim() -replace '^d\d+p\d+:', ''
									break
								}
							}
						}
						# Detect valueListAllowed flag on the parameter — empty value should be omitted
						$vlaSet = $false
						foreach ($ch in $paramEl.ChildNodes) {
							if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'valueListAllowed' -and $ch.NamespaceURI -eq $schNs) {
								if ($ch.InnerText.Trim() -eq 'true') { $vlaSet = $true }
								break
							}
						}
						if (Test-EmptyValue $value) {
							$fragXml = Build-EmptyValueXml -type $declaredType -indent $childIndent -tagPrefix "" -tagName "value" -valueListAllowed $vlaSet
						} else {
							$valueLines = Build-ParamValueXml -type $declaredType -value $value -indent $childIndent
							$fragXml = $valueLines -join "`n"
						}

						# Collect ALL existing <value> (a param may carry a value-list) — scalar
						# value= collapses them to one, so remove every <value>, not just the first.
						$allValueEls = @()
						foreach ($ch in $paramEl.ChildNodes) {
							if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'value' -and $ch.NamespaceURI -eq $schNs) { $allValueEls += $ch }
						}
						$wasExisting = ($allValueEls.Count -gt 0)
						if ($wasExisting) {
							# Capture position after the last existing value, then remove all
							$refNode = $allValueEls[$allValueEls.Count - 1].NextSibling
							while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
								$refNode = $refNode.NextSibling
							}
							foreach ($ve in $allValueEls) { Remove-NodeWithWhitespace $ve }
						} else {
							# Insert before useRestriction/availableValue/denyIncompleteValues/use
							$refNode = $null
							foreach ($child in $paramEl.ChildNodes) {
								if ($child.NodeType -eq 'Element' -and $child.LocalName -in @('useRestriction','availableValue','denyIncompleteValues','use')) {
									$refNode = $child; break
								}
							}
						}
						if ($fragXml) {
							$nodes = Import-Fragment $xmlDoc $fragXml
							foreach ($node in $nodes) {
								Insert-BeforeElement $paramEl $node $refNode $childIndent
							}
						}
						$verb = if ($wasExisting) { "updated" } else { "added" }
						$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": value $verb to $value"
					} elseif ($existing) {
						$existing.InnerText = $value
						$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": $key updated to $value"
					} else {
						# Schema order: ...value, useRestriction, availableValue*, denyIncompleteValues, use
						$refNode = $null
						if ($key -eq "denyIncompleteValues") {
							foreach ($child in $paramEl.ChildNodes) {
								if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'use') {
									$refNode = $child; break
								}
							}
						}
						$fragXml = "$childIndent<$key>$(Esc-Xml $value)</$key>"
						$nodes = Import-Fragment $xmlDoc $fragXml
						foreach ($node in $nodes) {
							Insert-BeforeElement $paramEl $node $refNode $childIndent
						}
						$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": $key=$value added"
					}
				}
			}

			# Process multi-value list (value=v1, v2, ...) — replace ALL <value>, ensure valueListAllowed=true
			if ($valueListItems) {
				# Declared type from <valueType>
				$declaredType = ""
				$vtEl = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'valueType' -and $ch.NamespaceURI -eq $schNs) { $vtEl = $ch; break }
				}
				if ($vtEl) {
					foreach ($tnode in $vtEl.ChildNodes) {
						if ($tnode.NodeType -eq 'Element' -and $tnode.LocalName -eq 'Type') {
							$declaredType = $tnode.InnerText.Trim() -replace '^d\d+p\d+:', ''
							break
						}
					}
				}
				# Remove ALL existing <value>; capture insertion ref after the last one
				$valueEls = @()
				foreach ($child in $paramEl.ChildNodes) {
					if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'value' -and $child.NamespaceURI -eq $schNs) { $valueEls += $child }
				}
				$refNode = $null
				if ($valueEls.Count -gt 0) {
					$refNode = $valueEls[$valueEls.Count - 1].NextSibling
					while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) { $refNode = $refNode.NextSibling }
					foreach ($ve in $valueEls) { Remove-NodeWithWhitespace $ve }
				} else {
					foreach ($child in $paramEl.ChildNodes) {
						if ($child.NodeType -eq 'Element' -and $child.LocalName -in @('useRestriction','availableValue','denyIncompleteValues','use')) { $refNode = $child; break }
					}
				}
				foreach ($v in $valueListItems) {
					$fragXml = (Build-ParamValueXml -type $declaredType -value $v -indent $childIndent) -join "`n"
					$nodes = Import-Fragment $xmlDoc $fragXml
					foreach ($node in $nodes) { Insert-BeforeElement $paramEl $node $refNode $childIndent }
				}
				# Ensure <valueListAllowed>true</valueListAllowed> (schema order: after useRestriction, before availableValue/use)
				$vlaEl = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'valueListAllowed' -and $ch.NamespaceURI -eq $schNs) { $vlaEl = $ch; break }
				}
				if ($vlaEl) {
					if ($vlaEl.InnerText.Trim() -ne 'true') { $vlaEl.InnerText = 'true' }
				} else {
					$refVla = $null
					foreach ($child in $paramEl.ChildNodes) {
						if ($child.NodeType -eq 'Element' -and $child.LocalName -in @('availableValue','denyIncompleteValues','use')) { $refVla = $child; break }
					}
					$nodes = Import-Fragment $xmlDoc "$childIndent<valueListAllowed>true</valueListAllowed>"
					foreach ($node in $nodes) { Insert-BeforeElement $paramEl $node $refVla $childIndent }
				}
				$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": value set to list of $($valueListItems.Count) item(s)"
			}

			# Process availableValue — replace whole list with new items
			if ($avPart) {
				$avRest = ($avPart -replace '^availableValue=', '').Trim()
				$avItems = Parse-AvailableValueList $avRest

				# Detect value type: prefer declared <valueType> of the parameter, else guess from value
				$declaredType = ""
				$vtEl = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'valueType' -and $ch.NamespaceURI -eq $schNs) { $vtEl = $ch; break }
				}
				if ($vtEl) {
					foreach ($tnode in $vtEl.ChildNodes) {
						if ($tnode.NodeType -eq 'Element' -and $tnode.LocalName -eq 'Type') {
							$declaredType = $tnode.InnerText.Trim() -replace '^d\d+p\d+:', ''
							break
						}
					}
				}

				# Remove all existing <availableValue> elements
				$toRemove = @()
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'availableValue' -and $ch.NamespaceURI -eq $schNs) {
						$toRemove += $ch
					}
				}
				foreach ($el in $toRemove) { Remove-NodeWithWhitespace $el }

				# Insert each new <availableValue> before (denyIncompleteValues, use)
				$refNode = $null
				foreach ($child in $paramEl.ChildNodes) {
					if ($child.NodeType -eq 'Element' -and ($child.LocalName -eq 'denyIncompleteValues' -or $child.LocalName -eq 'use')) {
						$refNode = $child; break
					}
				}
				foreach ($av in $avItems) {
					$avLines = Build-AvailableValueFragment -item $av -declaredType $declaredType -indent $childIndent
					$fragXml = $avLines -join "`n"
					$nodes = Import-Fragment $xmlDoc $fragXml
					foreach ($node in $nodes) {
						Insert-BeforeElement $paramEl $node $refNode $childIndent
					}
				}
				$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": availableValue set to $($avItems.Count) item(s)"
			}

			# Process @hidden / @always flags (idempotent)
			if ($flagHidden) {
				# useRestriction → true (insert after <value>, before <expression>/<availableAsField>/...)
				$urEl = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'useRestriction' -and $ch.NamespaceURI -eq $schNs) { $urEl = $ch; break }
				}
				if ($urEl) {
					if ($urEl.InnerText.Trim() -ne 'true') { $urEl.InnerText = 'true' }
				} else {
					$refNode = $null
					foreach ($child in $paramEl.ChildNodes) {
						if ($child.NodeType -eq 'Element' -and $child.LocalName -in @('expression','availableAsField','availableValue','denyIncompleteValues','use')) { $refNode = $child; break }
					}
					$nodes = Import-Fragment $xmlDoc "$childIndent<useRestriction>true</useRestriction>"
					foreach ($node in $nodes) { Insert-BeforeElement $paramEl $node $refNode $childIndent }
				}

				# availableAsField → false (insert after <expression>, before <availableValue>/<denyIncompleteValues>/<use>)
				$afEl = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'availableAsField' -and $ch.NamespaceURI -eq $schNs) { $afEl = $ch; break }
				}
				if ($afEl) {
					if ($afEl.InnerText.Trim() -ne 'false') { $afEl.InnerText = 'false' }
				} else {
					$refNode = $null
					foreach ($child in $paramEl.ChildNodes) {
						if ($child.NodeType -eq 'Element' -and $child.LocalName -in @('availableValue','denyIncompleteValues','use')) { $refNode = $child; break }
					}
					$nodes = Import-Fragment $xmlDoc "$childIndent<availableAsField>false</availableAsField>"
					foreach ($node in $nodes) { Insert-BeforeElement $paramEl $node $refNode $childIndent }
				}

				$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": @hidden applied"
			}

			if ($flagAlways) {
				$useEl = $null
				foreach ($ch in $paramEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'use' -and $ch.NamespaceURI -eq $schNs) { $useEl = $ch; break }
				}
				if ($useEl) {
					if ($useEl.InnerText.Trim() -ne 'Always') { $useEl.InnerText = 'Always' }
				} else {
					$nodes = Import-Fragment $xmlDoc "$childIndent<use>Always</use>"
					foreach ($node in $nodes) { Insert-BeforeElement $paramEl $node $null $childIndent }
				}
				$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`": @always applied"
			}
		}
	}

	"rename-parameter" {
		foreach ($val in $values) {
			# Shorthand: "OldName => NewName"
			if ($val -notmatch '^\s*(.+?)\s*=>\s*(.+?)\s*$') {
				Write-Host "[WARN] rename-parameter expects 'OldName => NewName', got: $val"
				continue
			}
			$oldName = $Matches[1].Trim()
			$newName = $Matches[2].Trim()

			if ($oldName -eq $newName) {
				Write-Host "[WARN] rename-parameter: old and new names are equal — skipped"
				continue
			}

			# 1. Rename <parameter><name>OldName</name>
			$root = $xmlDoc.DocumentElement
			$paramEl = Find-ElementByChildValue $root "parameter" "name" $oldName $schNs
			if (-not $paramEl) {
				Write-Host "[WARN] Parameter `"$oldName`" not found — skipped"
				continue
			}
			foreach ($ch in $paramEl.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'name' -and $ch.NamespaceURI -eq $schNs) {
					$ch.InnerText = $newName
					break
				}
			}

			# 2. Update <expression> in other <parameter> elements.
			# Regex matches "&OldName" only when followed by a non-identifier char (or end),
			# so "&Период" matches "&Период.ДатаНачала" but NOT "&ПериодОтчета".
			$escOld = [regex]::Escape($oldName)
			$exprRegex = "&$escOld(?=[^\w\u0400-\u04FF]|$)"
			$exprUpdated = 0
			foreach ($ch in $root.ChildNodes) {
				if ($ch.NodeType -ne 'Element' -or $ch.LocalName -ne 'parameter' -or $ch.NamespaceURI -ne $schNs) { continue }
				foreach ($gc in $ch.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'expression' -and $gc.NamespaceURI -eq $schNs) {
						$oldExpr = $gc.InnerText
						$newExpr = [regex]::Replace($oldExpr, $exprRegex, "&$newName")
						if ($newExpr -ne $oldExpr) {
							$gc.InnerText = $newExpr
							$exprUpdated++
						}
					}
				}
			}

			# 3. Update <dcscor:parameter>OldName</dcscor:parameter> in dataParameters of all variants.
			# Note: <settingsVariant> is in schNs, but <settings> and <dataParameters> are in setNs.
			# IMPORTANT: don't use $variant — it collides with script parameter [string]$Variant
			# (PowerShell vars are case-insensitive, and the [string] type would coerce XmlNode to "").
			$dpUpdated = 0
			foreach ($variantNode in $root.ChildNodes) {
				if ($variantNode.NodeType -ne 'Element' -or $variantNode.LocalName -ne 'settingsVariant' -or $variantNode.NamespaceURI -ne $schNs) { continue }
				$settings = Find-FirstElement $variantNode @("settings") $setNs
				if (-not $settings) { continue }
				$dpEl = Find-FirstElement $settings @("dataParameters") $setNs
				if (-not $dpEl) { continue }
				foreach ($item in $dpEl.ChildNodes) {
					if ($item.NodeType -ne 'Element' -or $item.LocalName -ne 'item') { continue }
					foreach ($gc in $item.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'parameter' -and $gc.NamespaceURI -eq $corNs) {
							if ($gc.InnerText.Trim() -eq $oldName) {
								$gc.InnerText = $newName
								$dpUpdated++
							}
						}
					}
				}
			}

			$script:Dirty = $true; Write-Host "[OK] Parameter renamed: `"$oldName`" => `"$newName`" (expressions updated: $exprUpdated, dataParameters updated: $dpUpdated)"
		}
	}

	"reorder-parameters" {
		foreach ($val in $values) {
			# Shorthand: "Name1, Name2, Name3" — partial list, listed names go first in order, rest preserve original order
			$order = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
			if ($order.Count -eq 0) {
				Write-Host "[WARN] reorder-parameters: empty list — skipped"
				continue
			}

			$root = $xmlDoc.DocumentElement

			# Collect all <parameter> in document order with their child indent
			$allParams = @()
			foreach ($ch in $root.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'parameter' -and $ch.NamespaceURI -eq $schNs) {
					$allParams += $ch
				}
			}
			if ($allParams.Count -eq 0) {
				Write-Host "[WARN] reorder-parameters: no parameters in schema"
				continue
			}

			$childIndent = Get-ChildIndent $root

			# Build name -> element map
			$byName = @{}
			foreach ($pe in $allParams) {
				foreach ($gc in $pe.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $schNs) {
						$byName[$gc.InnerText.Trim()] = $pe
						break
					}
				}
			}

			# Build new order
			$newOrder = @()
			$used = @{}
			foreach ($name in $order) {
				if ($byName.ContainsKey($name)) {
					$newOrder += $byName[$name]
					$used[$name] = $true
				} else {
					Write-Host "[WARN] reorder-parameters: parameter `"$name`" not found — skipped"
				}
			}
			foreach ($pe in $allParams) {
				$peName = $null
				foreach ($gc in $pe.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $schNs) {
						$peName = $gc.InnerText.Trim(); break
					}
				}
				if ($peName -and -not $used.ContainsKey($peName)) {
					$newOrder += $pe
				}
			}

			# Find anchor: element right after the last parameter in original order
			$lastParam = $allParams[-1]
			$anchor = $lastParam.NextSibling

			# Remove all parameters with surrounding whitespace
			foreach ($pe in $allParams) {
				Remove-NodeWithWhitespace $pe
			}

			# Re-insert in new order before anchor
			foreach ($pe in $newOrder) {
				Insert-BeforeElement $root $pe $anchor $childIndent
			}

			$script:Dirty = $true; Write-Host "[OK] Parameters reordered ($($allParams.Count) total, $($order.Count) explicit)"
		}
	}

	"add-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-FilterShorthand $val

			$filterEl = Ensure-SettingsChild $settings "filter" @("selection")
			$filterIndent = Get-ContainerChildIndent $filterEl

			$fragXml = Build-FilterItemFragment -parsed $parsed -indent $filterIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $filterEl $node $null $filterIndent
			}

			$script:Dirty = $true; Write-Host "[OK] Filter `"$($parsed.field) $($parsed.op)`" added to variant `"$varName`""
		}
	}

	"add-dataParameter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-DataParamShorthand $val

			$dpEl = Ensure-SettingsChild $settings "dataParameters" @("outputParameters","conditionalAppearance","order","filter","selection")
			$dpIndent = Get-ContainerChildIndent $dpEl

			$fragXml = Build-DataParamFragment -parsed $parsed -indent $dpIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $dpEl $node $null $dpIndent
			}

			$script:Dirty = $true; Write-Host "[OK] DataParameter `"$($parsed.parameter)`" added to variant `"$varName`""
		}
	}

	"add-order" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-OrderShorthand $val

			$orderEl = Ensure-SettingsChild $settings "order" @("filter","selection")
			$orderIndent = Get-ContainerChildIndent $orderEl

			# Duplicate check
			if ($parsed.field -eq "Auto") {
				$isDup = $false
				foreach ($ch in $orderEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'item') {
						$typeAttr = $ch.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
						if ($typeAttr -and $typeAttr.Contains("OrderItemAuto")) { $isDup = $true; break }
					}
				}
				if ($isDup) {
					Write-Host "[WARN] OrderItemAuto already exists in variant `"$varName`" — skipped"
					continue
				}
			} else {
				$existingOrd = Find-ElementByChildValue $orderEl "item" "field" $parsed.field $setNs
				if ($existingOrd) {
					Write-Host "[WARN] Order `"$($parsed.field)`" already exists in variant `"$varName`" — skipped"
					continue
				}
			}

			$fragXml = Build-OrderItemFragment -parsed $parsed -indent $orderIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $orderEl $node $null $orderIndent
			}

			$desc = if ($parsed.field -eq "Auto") { "Auto" } else { "$($parsed.field) $($parsed.direction)" }
			$script:Dirty = $true; Write-Host "[OK] Order `"$desc`" added to variant `"$varName`""
		}
	}

	"add-selection" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$fieldName = $val.Trim()
			$groupName = $null

			# Extract @group=Name
			if ($fieldName -match '\s*@group=(\S+)') {
				$groupName = $Matches[1]
				$fieldName = ($fieldName -replace '\s*@group=\S+', '').Trim()
			}

			if ($groupName) {
				# Find named StructureItemGroup
				$dcssetNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
				$xsiNs = "http://www.w3.org/2001/XMLSchema-instance"
				$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
				$nsMgr.AddNamespace("dcsset", $dcssetNs)
				$nsMgr.AddNamespace("xsi", $xsiNs)
				$groupEl = $settings.SelectSingleNode(".//dcsset:item[@xsi:type='dcsset:StructureItemGroup'][dcsset:name='$groupName']", $nsMgr)
				if (-not $groupEl) {
					Write-Host "[WARN] StructureItemGroup `"$groupName`" not found — adding to variant level"
					$targetEl = $settings
				} else {
					$targetEl = $groupEl
				}
			} else {
				$targetEl = $settings
			}

			$selection = Ensure-SettingsChild $targetEl "selection" @()

			# Dedup: skip if SelectedItemAuto already exists
			if ($fieldName -eq "Auto") {
				$isDup = $false
				foreach ($ch in $selection.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'item') {
						$typeAttr = $ch.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
						if ($typeAttr -and $typeAttr.Contains("SelectedItemAuto")) { $isDup = $true; break }
					}
				}
				if ($isDup) {
					$target = if ($groupName) { "group `"$groupName`"" } else { "variant `"$varName`"" }
					Write-Host "[WARN] SelectedItemAuto already exists in $target — skipped"
					continue
				}
			}

			$selIndent = Get-ContainerChildIndent $selection

			$selXml = Build-SelectionItemFragment -fieldName $fieldName -indent $selIndent
			$selNodes = Import-Fragment $xmlDoc $selXml
			foreach ($node in $selNodes) {
				Insert-BeforeElement $selection $node $null $selIndent
			}

			$target = if ($groupName) { "group `"$groupName`"" } else { "variant `"$varName`"" }
			$script:Dirty = $true; Write-Host "[OK] Selection `"$fieldName`" added to $target"
		}
	}

	"set-query" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		$queryEl = Find-FirstElement $dsNode @("query") $schNs
		if (-not $queryEl) {
			Write-Error "No <query> element found in dataset '$dsName'"
			exit 1
		}

		# InnerText setter handles XML escaping automatically
		$queryEl.InnerText = Resolve-QueryValue $Value $script:queryBaseDir

		$script:Dirty = $true; Write-Host "[OK] Query replaced in dataset `"$dsName`""
	}

	"patch-query" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		$queryEl = Find-FirstElement $dsNode @("query") $schNs
		if (-not $queryEl) {
			Write-Error "No <query> element found in dataset '$dsName'"
			exit 1
		}

		foreach ($val in $values) {
			$once = $false
			if ($val -match '@once\b') {
				$once = $true
				$val = ($val -replace '\s*@once\b', '').Trim()
			}

			$sepIdx = $val.IndexOf(" => ")
			if ($sepIdx -lt 0) {
				Write-Error "patch-query value must contain ' => ' separator: old => new"
				exit 1
			}
			$oldStr = Normalize-LineEndings $val.Substring(0, $sepIdx)
			$newStr = Normalize-LineEndings $val.Substring($sepIdx + 4)
			$queryText = Normalize-LineEndings $queryEl.InnerText

			$count = ([regex]::Matches($queryText, [regex]::Escape($oldStr))).Count
			if ($count -eq 0) {
				$diag = Format-PatchQueryNotFound $oldStr $queryText $dsNode $dsName
				Write-Error $diag
				exit 1
			}
			if ($once -and $count -ne 1) {
				Write-Error "@once: expected 1 occurrence of '$oldStr' in dataset '$dsName', found $count"
				exit 1
			}

			$queryEl.InnerText = $queryText.Replace($oldStr, $newStr)
			$suffix = if ($once) { " (1 occurrence)" } else { " ($count occurrence(s))" }
			$script:Dirty = $true; Write-Host "[OK] Query patched in dataset `"$dsName`": replaced '$oldStr'$suffix"
		}
	}

	"set-outputParameter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-OutputParamShorthand $val

			$outputEl = Ensure-SettingsChild $settings "outputParameters" @("conditionalAppearance","order","filter","selection")
			$outputIndent = Get-ContainerChildIndent $outputEl

			# Remove existing parameter with same key if present
			$existingParam = Find-ElementByChildValue $outputEl "item" "parameter" $parsed.key $corNs
			if ($existingParam) {
				Remove-NodeWithWhitespace $existingParam
				$script:Dirty = $true; Write-Host "[OK] Replaced outputParameter `"$($parsed.key)`" in variant `"$varName`""
			} else {
				$script:Dirty = $true; Write-Host "[OK] OutputParameter `"$($parsed.key)`" added to variant `"$varName`""
			}

			$fragXml = Build-OutputParamFragment -parsed $parsed -indent $outputIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $outputEl $node $null $outputIndent
			}
		}
	}

	"set-structure" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		# Remove all existing structure items (dcsset:item elements)
		$toRemove = @()
		foreach ($ch in $settings.ChildNodes) {
			if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'item' -and $ch.NamespaceURI -eq $setNs) {
				$toRemove += $ch
			}
		}
		foreach ($el in $toRemove) {
			Remove-NodeWithWhitespace $el
		}

		# Parse structure shorthand
		$structItems = Parse-StructureShorthand $Value
		$settingsIndent = Get-ChildIndent $settings

		# Find insertion point — before outputParameters/dataParameters/conditionalAppearance/order/filter/selection or at end
		$refNode = Find-FirstElement $settings @("outputParameters","dataParameters","conditionalAppearance","order","filter","selection","item") $setNs
		if (-not $refNode) { $refNode = $null }

		foreach ($structItem in $structItems) {
			$fragXml = Build-StructureItemFragment -item $structItem -indent $settingsIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $settings $node $refNode $settingsIndent
			}
		}

		$script:Dirty = $true; Write-Host "[OK] Structure set in variant `"$varName`": $Value"
	}

	"modify-structure" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		$structItems = Parse-StructureShorthand $Value

		# Flatten parsed tree into (name, groupBy) targets
		$targets = @()
		$stack = New-Object System.Collections.Stack
		foreach ($it in $structItems) { $stack.Push($it) }
		while ($stack.Count -gt 0) {
			$it = $stack.Pop()
			if ($it["name"]) {
				$targets += @{ name = $it["name"]; groupBy = $it["groupBy"] }
			}
			if ($it["children"]) {
				foreach ($ch in $it["children"]) { $stack.Push($ch) }
			}
		}

		if ($targets.Count -eq 0) {
			Write-Error "modify-structure requires @name= for at least one group: $Value"
			exit 1
		}

		$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
		$nsMgr.AddNamespace("dcsset", $setNs)
		$nsMgr.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

		foreach ($t in $targets) {
			$groupEl = $settings.SelectSingleNode(".//dcsset:item[@xsi:type='dcsset:StructureItemGroup'][dcsset:name='$($t.name)']", $nsMgr)
			if (-not $groupEl) {
				Write-Host "[WARN] Group with @name=`"$($t.name)`" not found — skipped"
				continue
			}

			$giEl = $null
			foreach ($ch in $groupEl.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'groupItems' -and $ch.NamespaceURI -eq $setNs) {
					$giEl = $ch; break
				}
			}
			$groupIndent = Get-ChildIndent $groupEl
			if (-not $giEl) {
				# Create <groupItems> after <name>, before <order>/<selection>/...
				$nameEl = $null
				$refAfterName = $null
				foreach ($ch in $groupEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'name' -and $ch.NamespaceURI -eq $setNs) {
						$nameEl = $ch
					} elseif ($ch.NodeType -eq 'Element' -and $nameEl -and -not $refAfterName) {
						$refAfterName = $ch; break
					}
				}
				$giFrag = "$groupIndent<dcsset:groupItems></dcsset:groupItems>"
				$nodes = Import-Fragment $xmlDoc $giFrag
				foreach ($node in $nodes) {
					Insert-BeforeElement $groupEl $node $refAfterName $groupIndent
				}
				# Re-find
				foreach ($ch in $groupEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'groupItems' -and $ch.NamespaceURI -eq $setNs) {
						$giEl = $ch; break
					}
				}
			}

			$toRemove = @()
			foreach ($ch in $giEl.ChildNodes) {
				if ($ch.NodeType -eq 'Element') { $toRemove += $ch }
			}
			foreach ($el in $toRemove) { Remove-NodeWithWhitespace $el }

			$itemIndent = "$groupIndent`t"

			foreach ($field in $t.groupBy) {
				$lines = @()
				$lines += "$itemIndent<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
				$lines += "$itemIndent`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
				$lines += "$itemIndent`t<dcsset:groupType>Items</dcsset:groupType>"
				$lines += "$itemIndent`t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>"
				$lines += "$itemIndent`t<dcsset:periodAdditionBegin xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionBegin>"
				$lines += "$itemIndent`t<dcsset:periodAdditionEnd xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionEnd>"
				$lines += "$itemIndent</dcsset:item>"
				$fragXml = $lines -join "`n"
				$nodes = Import-Fragment $xmlDoc $fragXml
				foreach ($node in $nodes) {
					Insert-BeforeElement $giEl $node $null $itemIndent
				}
			}

			$desc = if ($t.groupBy.Count -eq 0) { "details" } else { $t.groupBy -join ', ' }
			$script:Dirty = $true; Write-Host "[OK] Group `"$($t.name)`" groupItems updated: $desc"
		}
	}

	"add-dataSetLink" {
		foreach ($val in $values) {
			$parsed = Parse-DataSetLinkShorthand $val
			$root = $xmlDoc.DocumentElement
			$childIndent = Get-ChildIndent $root

			$fragXml = Build-DataSetLinkFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert after last dataSetLink, or before calculatedField/totalField/parameter/...
			$lastLink = Find-LastElement $root "dataSetLink" $schNs
			if ($lastLink) {
				$refNode = $lastLink.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("calculatedField","totalField","parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			$desc = "$($parsed.source) > $($parsed.dest) on $($parsed.sourceExpr) = $($parsed.destExpr)"
			if ($parsed.parameter) { $desc += " [param $($parsed.parameter)]" }
			$script:Dirty = $true; Write-Host "[OK] DataSetLink `"$desc`" added"
		}
	}

	"add-dataSet" {
		$root = $xmlDoc.DocumentElement
		$childIndent = Get-ChildIndent $root

		$parsed = Parse-DataSetShorthand $Value
		$parsed.query = Resolve-QueryValue $parsed.query $script:queryBaseDir

		# Auto-name if empty
		if (-not $parsed.name) {
			$count = 0
			foreach ($ch in $root.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'dataSet' -and $ch.NamespaceURI -eq $schNs) { $count++ }
			}
			$parsed.name = "НаборДанных$($count + 1)"
		}

		# Duplicate check
		$existing = Find-ElementByChildValue $root "dataSet" "name" $parsed.name $schNs
		if ($existing) {
			Write-Host "[WARN] DataSet `"$($parsed.name)`" already exists — skipped"
		} else {
			# Get dataSource name from first existing <dataSource>
			$dsSourceEl = Find-FirstElement $root @("dataSource") $schNs
			$dsSourceName = "ИсточникДанных1"
			if ($dsSourceEl) {
				$nameEl = Find-FirstElement $dsSourceEl @("name") $schNs
				if ($nameEl) { $dsSourceName = $nameEl.InnerText.Trim() }
			}
			$parsed["dataSource"] = $dsSourceName

			$fragXml = Build-DataSetQueryFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert after last <dataSet>, or after <dataSource> if none
			$lastDS = Find-LastElement $root "dataSet" $schNs
			if ($lastDS) {
				$refNode = $lastDS.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("dataSetLink","calculatedField","totalField","parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			$script:Dirty = $true; Write-Host "[OK] DataSet `"$($parsed.name)`" added (dataSource=$dsSourceName)"
		}
	}

	"add-variant" {
		$root = $xmlDoc.DocumentElement
		$childIndent = Get-ChildIndent $root

		foreach ($val in $values) {
			$parsed = Parse-VariantShorthand $val

			# Duplicate check — search for settingsVariant with matching dcsset:name
			$isDup = $false
			foreach ($ch in $root.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'settingsVariant' -and $ch.NamespaceURI -eq $schNs) {
					foreach ($gc in $ch.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $setNs -and $gc.InnerText -eq $parsed.name) {
							$isDup = $true; break
						}
					}
					if ($isDup) { break }
				}
			}
			if ($isDup) {
				Write-Host "[WARN] Variant `"$($parsed.name)`" already exists — skipped"
				continue
			}

			$fragXml = Build-VariantFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert after last <settingsVariant>
			$lastSV = Find-LastElement $root "settingsVariant" $schNs
			if ($lastSV) {
				$refNode = $lastSV.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = $null
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			$script:Dirty = $true; Write-Host "[OK] Variant `"$($parsed.name)`" [`"$($parsed.presentation)`"] added"
		}
	}

	"add-conditionalAppearance" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-ConditionalAppearanceShorthand $val

			$caEl = Ensure-SettingsChild $settings "conditionalAppearance" @("outputParameters","order","filter","selection")
			$caIndent = Get-ContainerChildIndent $caEl

			$fragXml = Build-ConditionalAppearanceItemFragment -parsed $parsed -indent $caIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $caEl $node $null $caIndent
			}

			$desc = "$($parsed.param) = $($parsed.value)"
			if ($parsed.filter) { $desc += " when $($parsed.filter.field) $($parsed.filter.op)" }
			if ($parsed.fields -and $parsed.fields.Count -gt 0) { $desc += " for $($parsed.fields -join ', ')" }
			$script:Dirty = $true; Write-Host "[OK] ConditionalAppearance `"$desc`" added to variant `"$varName`""
		}
	}

	"clear-selection" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName
		$selection = Find-FirstElement $settings @("selection") $setNs
		if ($selection) {
			Clear-ContainerChildren $selection
			$script:Dirty = $true; Write-Host "[OK] Selection cleared in variant `"$varName`""
		} else {
			Write-Host "[INFO] No selection section in variant `"$varName`""
		}
	}

	"clear-order" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName
		$orderEl = Find-FirstElement $settings @("order") $setNs
		if ($orderEl) {
			Clear-ContainerChildren $orderEl
			$script:Dirty = $true; Write-Host "[OK] Order cleared in variant `"$varName`""
		} else {
			Write-Host "[INFO] No order section in variant `"$varName`""
		}
	}

	"clear-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName
		$filterEl = Find-FirstElement $settings @("filter") $setNs
		if ($filterEl) {
			Clear-ContainerChildren $filterEl
			$script:Dirty = $true; Write-Host "[OK] Filter cleared in variant `"$varName`""
		} else {
			Write-Host "[INFO] No filter section in variant `"$varName`""
		}
	}

	"clear-conditionalAppearance" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName
		$caEl = Find-FirstElement $settings @("conditionalAppearance") $setNs
		if ($caEl) {
			Clear-ContainerChildren $caEl
			$script:Dirty = $true; Write-Host "[OK] ConditionalAppearance cleared in variant `"$varName`""
		} else {
			Write-Host "[INFO] No conditionalAppearance section in variant `"$varName`""
		}
	}

	"modify-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-FilterShorthand $val

			$filterEl = Find-FirstElement $settings @("filter") $setNs
			if (-not $filterEl) {
				Write-Host "[WARN] No filter section in variant `"$varName`""
				continue
			}

			$filterItem = Find-ElementByChildValue $filterEl "item" "left" $parsed.field $setNs
			if (-not $filterItem) {
				Write-Host "[WARN] Filter for `"$($parsed.field)`" not found in variant `"$varName`""
				continue
			}

			$itemIndent = Get-ChildIndent $filterItem

			# Update comparisonType
			Set-OrCreateChildElement $filterItem "comparisonType" $setNs $parsed.op $itemIndent

			# Update right value
			if ($null -ne $parsed.value) {
				$vt = if ($parsed["valueType"]) { $parsed["valueType"] } else { "xs:string" }
				Set-OrCreateChildElementWithAttr $filterItem "right" $setNs "$($parsed.value)" $vt $itemIndent
			}

			# Update use (only when explicitly set via @off / @on)
			if ($parsed.use -eq $false) {
				Set-OrCreateChildElement $filterItem "use" $setNs "false" $itemIndent
			} elseif ($parsed.use -eq $true) {
				# @on: remove existing use=false if any
				$useEl = $null
				foreach ($ch in $filterItem.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'use' -and $ch.NamespaceURI -eq $setNs) {
						$useEl = $ch; break
					}
				}
				if ($useEl -and $useEl.InnerText -eq 'false') {
					Remove-NodeWithWhitespace $useEl
				}
			}

			# Update viewMode
			if ($parsed.viewMode) {
				Set-OrCreateChildElement $filterItem "viewMode" $setNs $parsed.viewMode $itemIndent
			}

			# Update userSettingID
			if ($parsed.userSettingID) {
				$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
				Set-OrCreateChildElement $filterItem "userSettingID" $setNs $uid $itemIndent
			}

			$script:Dirty = $true; Write-Host "[OK] Filter `"$($parsed.field)`" modified in variant `"$varName`""
		}
	}

	"modify-dataParameter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-DataParamShorthand $val

			$dpEl = Find-FirstElement $settings @("dataParameters") $setNs
			if (-not $dpEl) {
				Write-Host "[WARN] No dataParameters section in variant `"$varName`""
				continue
			}

			$dpItem = Find-ElementByChildValue $dpEl "item" "parameter" $parsed.parameter $corNs
			if (-not $dpItem) {
				Write-Host "[WARN] DataParameter `"$($parsed.parameter)`" not found in variant `"$varName`""
				continue
			}

			$itemIndent = Get-ChildIndent $dpItem

			# Update value
			if ($null -ne $parsed.value) {
				# Remove existing value element first
				$existingVal = $null
				foreach ($ch in $dpItem.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'value' -and $ch.NamespaceURI -eq $corNs) {
						$existingVal = $ch; break
					}
				}
				if ($existingVal) {
					Remove-NodeWithWhitespace $existingVal
				}

				# Build new value fragment
				$valLines = @()
				if ($parsed.value -is [hashtable] -and $parsed.value.variant) {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"v8:StandardPeriod`">"
					$valLines += "$itemIndent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $parsed.value.variant)</v8:variant>"
					$valLines += "$itemIndent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
					$valLines += "$itemIndent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
					$valLines += "$itemIndent</dcscor:value>"
				} elseif (Test-EmptyValue $parsed.value) {
					$valLines += "$itemIndent<dcscor:value xsi:nil=`"true`"/>"
				} elseif ("$($parsed.value)" -match '^\d{4}-\d{2}-\d{2}T') {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
				} elseif ("$($parsed.value)" -eq "true" -or "$($parsed.value)" -eq "false") {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
				} else {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
				}
				$valXml = $valLines -join "`n"
				$valNodes = Import-Fragment $xmlDoc $valXml
				foreach ($node in $valNodes) {
					Insert-BeforeElement $dpItem $node $null $itemIndent
				}
			}

			# Update use (only when explicitly set via @off / @on)
			if ($parsed.use -eq $false) {
				Set-OrCreateChildElement $dpItem "use" $corNs "false" $itemIndent
			} elseif ($parsed.use -eq $true) {
				# @on: remove existing use=false if any
				$useEl = $null
				foreach ($ch in $dpItem.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'use' -and $ch.NamespaceURI -eq $corNs) {
						$useEl = $ch; break
					}
				}
				if ($useEl -and $useEl.InnerText -eq 'false') {
					Remove-NodeWithWhitespace $useEl
				}
			}

			# Update viewMode
			if ($parsed.viewMode) {
				Set-OrCreateChildElement $dpItem "viewMode" $setNs $parsed.viewMode $itemIndent
			}

			# Update userSettingID
			if ($parsed.userSettingID) {
				$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
				Set-OrCreateChildElement $dpItem "userSettingID" $setNs $uid $itemIndent
			}

			$script:Dirty = $true; Write-Host "[OK] DataParameter `"$($parsed.parameter)`" modified in variant `"$varName`""
		}
	}

	"modify-field" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		foreach ($val in $values) {
			$parsed = Parse-FieldShorthand $val
			$fieldName = $parsed.dataPath

			# Find existing field
			$fieldEl = Find-ElementByChildValue $dsNode "field" "dataPath" $fieldName $schNs
			if (-not $fieldEl) {
				Write-Host "[WARN] Field `"$fieldName`" not found in dataset `"$dsName`""
				continue
			}

			# Read existing properties
			$existing = Read-FieldProperties $fieldEl

			# Merge: parsed overrides existing for non-empty values
			$merged = @{
				dataPath = $existing.dataPath
				field = $existing.field
				title = if ($parsed.title) { $parsed.title } else { $existing.title }
				type = if ($parsed.type) { $parsed.type } else { $existing.type }
				roles = if ($parsed.roles -and $parsed.roles.Count -gt 0) { $parsed.roles } else { $existing.roles }
				restrict = if ($parsed.restrict -and $parsed.restrict.Count -gt 0) { $parsed.restrict } else { $existing.restrict }
				# Preserve raw <valueType> only when user did NOT override type via shorthand —
				# otherwise the override path rebuilds valueType from $parsed.type.
				rawValueType = if ($parsed.type) { $null } else { $existing._rawValueType }
				# Preserve raw multi-lang title; pass existing ru content for change detection.
				_rawTitle = $existing._rawTitle
				_existingTitleRu = $existing.title
				# Pass-through unknown children (e.g. <editFormat>, <appearance>, custom extensions).
				_unknownChildren = $existing._unknownChildren
			}

			# Remember position (NextSibling after whitespace)
			$nextSib = $fieldEl.NextSibling
			while ($nextSib -and ($nextSib.NodeType -eq 'Whitespace' -or $nextSib.NodeType -eq 'SignificantWhitespace')) {
				$nextSib = $nextSib.NextSibling
			}

			# Remove old field
			$childIndent = Get-ChildIndent $dsNode
			Remove-NodeWithWhitespace $fieldEl

			# Build new field fragment with merged data
			$fragXml = Build-FieldFragment -parsed $merged -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert at saved position
			foreach ($node in $nodes) {
				Insert-BeforeElement $dsNode $node $nextSib $childIndent
			}

			$script:Dirty = $true; Write-Host "[OK] Field `"$fieldName`" modified in dataset `"$dsName`""
		}
	}

	"set-field-role" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		foreach ($val in $values) {
			# Parse shorthand: "dataPath [@flag ...] [kv=value ...]"
			$s = $val.Trim()

			# Extract @flags
			$flags = @()
			$flagMatches = [regex]::Matches($s, '@(\w+)')
			foreach ($m in $flagMatches) { $flags += $m.Groups[1].Value }
			$s = [regex]::Replace($s, '\s*@\w+', '').Trim()

			# Extract kv=value (value is non-whitespace)
			$kv = [ordered]@{}
			$kvMatches = [regex]::Matches($s, '(\w+)=(\S+)')
			foreach ($m in $kvMatches) { $kv[$m.Groups[1].Value] = $m.Groups[2].Value }
			$s = [regex]::Replace($s, '\s*\w+=\S+', '').Trim()

			$dataPath = $s
			if (-not $dataPath) {
				Write-Host "[WARN] set-field-role: empty dataPath in `"$val`""
				continue
			}

			$fieldEl = Find-ElementByChildValue $dsNode "field" "dataPath" $dataPath $schNs
			if (-not $fieldEl) {
				Write-Host "[WARN] Field `"$dataPath`" not found in dataset `"$dsName`""
				continue
			}

			$fieldIndent = Get-ChildIndent $fieldEl

			# Remove existing <role> — but first capture OuterXml of any sub-children that
			# Build-RoleXml won't re-emit (e.g. <dcscom:addition>, <dcscom:groupFields>,
			# custom extension elements). Preserved across rebuild.
			$oldRole = $null
			foreach ($ch in $fieldEl.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'role' -and $ch.NamespaceURI -eq $schNs) { $oldRole = $ch; break }
			}
			$knownRoleChildren = @('periodNumber','periodType','dimension','ignoreNullsInGroups','balance','account','accountTypeExpression','additionType','addition')
			$preservedRoleChildren = @()
			if ($oldRole) {
				foreach ($gc in $oldRole.ChildNodes) {
					if ($gc.NodeType -ne 'Element') { continue }
					if ($knownRoleChildren -contains $gc.LocalName) { continue }
					# kv keys override the same-named sub-element on rebuild — don't preserve
					# what the user explicitly set.
					if ($kv.Contains($gc.LocalName)) { continue }
					$raw = $gc.OuterXml
					$raw = [regex]::Replace($raw, ' xmlns(?::\w+)?="[^"]*"', '')
					$preservedRoleChildren += $raw
				}
				Remove-NodeWithWhitespace $oldRole
			}

			# Empty spec — remove only
			if ($flags.Count -eq 0 -and $kv.Count -eq 0) {
				$script:Dirty = $true; Write-Host "[OK] Field `"$dataPath`" role cleared"
				continue
			}

			# Build new <role>
			$lines = @()
			$lines += "$fieldIndent<role>"
			foreach ($flag in $flags) {
				if ($flag -eq 'period') {
					$lines += "$fieldIndent`t<dcscom:periodNumber>1</dcscom:periodNumber>"
					$lines += "$fieldIndent`t<dcscom:periodType>Main</dcscom:periodType>"
				} else {
					$lines += "$fieldIndent`t<dcscom:$flag>true</dcscom:$flag>"
				}
			}
			foreach ($k in $kv.Keys) {
				$lines += "$fieldIndent`t<dcscom:$k>$(Esc-Xml $kv[$k])</dcscom:$k>"
			}
			foreach ($raw in $preservedRoleChildren) {
				$lines += "$fieldIndent`t" + $raw
			}
			$lines += "$fieldIndent</role>"
			$fragXml = $lines -join "`n"

			# Insert before <valueType>, else before <inputParameters>, else at end
			$refNode = $null
			foreach ($ch in $fieldEl.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -in @('valueType','inputParameters') -and $ch.NamespaceURI -eq $schNs) { $refNode = $ch; break }
			}
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $fieldEl $node $refNode $fieldIndent
			}

			$desc = @()
			if ($flags.Count -gt 0) { $desc += ($flags | ForEach-Object { "@$_" }) -join ' ' }
			if ($kv.Count -gt 0) { $desc += ($kv.Keys | ForEach-Object { "$_=$($kv[$_])" }) -join ' ' }
			$script:Dirty = $true; Write-Host "[OK] Field `"$dataPath`" role set: $($desc -join ' ')"
		}
	}

	"remove-field" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		foreach ($val in $values) {
			$fieldName = $val.Trim()

			$fieldEl = Find-ElementByChildValue $dsNode "field" "dataPath" $fieldName $schNs
			if (-not $fieldEl) {
				Write-Host "[WARN] Field `"$fieldName`" not found in dataset `"$dsName`""
				continue
			}

			Remove-NodeWithWhitespace $fieldEl
			$script:Dirty = $true; Write-Host "[OK] Field `"$fieldName`" removed from dataset `"$dsName`""

			# Also remove from selection in variant
			try {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Find-FirstElement $settings @("selection") $setNs
				if ($selection) {
					$selItem = Find-ElementByChildValue $selection "item" "field" $fieldName $setNs
					if ($selItem) {
						Remove-NodeWithWhitespace $selItem
						$script:Dirty = $true; Write-Host "[OK] Field `"$fieldName`" removed from selection of variant `"$varName`""
					}
				}
			} catch {
				# No variant — that's fine
			}
		}
	}

	"remove-total" {
		foreach ($val in $values) {
			$dataPath = $val.Trim()
			$root = $xmlDoc.DocumentElement

			$totalEl = Find-ElementByChildValue $root "totalField" "dataPath" $dataPath $schNs
			if (-not $totalEl) {
				Write-Host "[WARN] TotalField `"$dataPath`" not found"
				continue
			}

			Remove-NodeWithWhitespace $totalEl
			$script:Dirty = $true; Write-Host "[OK] TotalField `"$dataPath`" removed"
		}
	}

	"remove-calculated-field" {
		foreach ($val in $values) {
			$dataPath = $val.Trim()
			$root = $xmlDoc.DocumentElement

			$calcEl = Find-ElementByChildValue $root "calculatedField" "dataPath" $dataPath $schNs
			if (-not $calcEl) {
				Write-Host "[WARN] CalculatedField `"$dataPath`" not found"
				continue
			}

			Remove-NodeWithWhitespace $calcEl
			$script:Dirty = $true; Write-Host "[OK] CalculatedField `"$dataPath`" removed"

			# Also remove from selection
			try {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Find-FirstElement $settings @("selection") $setNs
				if ($selection) {
					$selItem = Find-ElementByChildValue $selection "item" "field" $dataPath $setNs
					if ($selItem) {
						Remove-NodeWithWhitespace $selItem
						$script:Dirty = $true; Write-Host "[OK] Field `"$dataPath`" removed from selection of variant `"$varName`""
					}
				}
			} catch { }
		}
	}

	"remove-parameter" {
		foreach ($val in $values) {
			$paramName = $val.Trim()
			$root = $xmlDoc.DocumentElement

			$paramEl = Find-ElementByChildValue $root "parameter" "name" $paramName $schNs
			if (-not $paramEl) {
				Write-Host "[WARN] Parameter `"$paramName`" not found"
				continue
			}

			Remove-NodeWithWhitespace $paramEl
			$script:Dirty = $true; Write-Host "[OK] Parameter `"$paramName`" removed"
		}
	}

	"remove-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$fieldName = $val.Trim()

			$filterEl = Find-FirstElement $settings @("filter") $setNs
			if (-not $filterEl) {
				Write-Host "[WARN] No filter section in variant `"$varName`""
				continue
			}

			$filterItem = Find-ElementByChildValue $filterEl "item" "left" $fieldName $setNs
			if (-not $filterItem) {
				Write-Host "[WARN] Filter for `"$fieldName`" not found in variant `"$varName`""
				continue
			}

			Remove-NodeWithWhitespace $filterItem
			$script:Dirty = $true; Write-Host "[OK] Filter for `"$fieldName`" removed from variant `"$varName`""
		}
	}

	"add-drilldown" {
		# String-based manipulation — templates use dcsat namespace with inline xmlns
		$rawText = [System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)
		$nl = "`r`n"
		$dcsatNsDecl = 'xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template"'

		# Find all outer <template> blocks by nesting-aware scan
		$tplStarts = [System.Collections.ArrayList]::new()
		$nameRegex = [regex]'<template>\s*<name>([^<]+)</name>'
		foreach ($m in $nameRegex.Matches($rawText)) {
			[void]$tplStarts.Add(@{ pos = $m.Index; name = $m.Groups[1].Value })
		}

		# For each start, find closing </template> at nesting depth 0
		$tplBlocks = [System.Collections.ArrayList]::new()
		foreach ($ts in $tplStarts) {
			$depth = 1
			$scanPos = $ts.pos + 10  # skip past opening <template>
			while ($depth -gt 0 -and $scanPos -lt $rawText.Length) {
				$nextOpen = $rawText.IndexOf("<template", $scanPos)
				$nextClose = $rawText.IndexOf("</template>", $scanPos)
				if ($nextClose -lt 0) { break }
				if ($nextOpen -ge 0 -and $nextOpen -lt $nextClose) {
					$depth++
					$scanPos = $nextOpen + 10
				} else {
					$depth--
					if ($depth -eq 0) {
						$endPos = $nextClose + "</template>".Length
						[void]$tplBlocks.Add(@{ name = $ts.name; start = $ts.pos; text = $rawText.Substring($ts.pos, $endPos - $ts.pos) })
					}
					$scanPos = $nextClose + 11
				}
			}
		}

		if ($tplBlocks.Count -eq 0) {
			Write-Host "[WARN] No named templates found in schema"
		}

		# Collect all insertions as (position, text) — apply in reverse order
		$insertions = [System.Collections.ArrayList]::new()

		foreach ($tplBlock in $tplBlocks) {
			$tplName = $tplBlock.name
			$tplText = $tplBlock.text
			$tplStart = $tplBlock.start

			# Build map: expression → paramName from ExpressionAreaTemplateParameter
			$exprMap = @{}
			$exprRegex = [regex]'(?s)<parameter[^>]*ExpressionAreaTemplateParameter[^>]*>\s*<dcsat:name>([^<]+)</dcsat:name>\s*<dcsat:expression>([^<]+)</dcsat:expression>\s*</parameter>'
			foreach ($em in $exprRegex.Matches($tplText)) {
				$pName = $em.Groups[1].Value
				$pExpr = $em.Groups[2].Value
				$exprMap[$pExpr] = $pName
			}

			foreach ($resource in $values) {
				$drillName = "Расшифровка_$resource"

				# Idempotency: check if already exists
				if ($tplText.Contains($drillName)) {
					Write-Host "[INFO] $drillName already exists in $tplName — skipped"
					continue
				}

				# Find ExpressionAreaTemplateParameter by expression
				$paramName = $null
				if ($exprMap.ContainsKey($resource)) {
					$paramName = $exprMap[$resource]
				} else {
					Write-Host "[WARN] Expression `"$resource`" not found in template $tplName — skipped"
					continue
				}

				$cellCount = 0

				# Step 1: Insert DetailsAreaTemplateParameter after last </parameter> in template
				$lastParamEndTag = "</parameter>"
				$lastParamPos = $tplText.LastIndexOf($lastParamEndTag)
				if ($lastParamPos -ge 0) {
					$insertPos = $tplStart + $lastParamPos + $lastParamEndTag.Length
					# Detect indent from context
					$prevNewline = $tplText.LastIndexOf("`n", $lastParamPos)
					$indent = "`t`t"
					if ($prevNewline -ge 0) {
						$lineStart = $prevNewline + 1
						$indentMatch = [regex]::Match($tplText.Substring($lineStart), '^(\s*)')
						if ($indentMatch.Success) { $indent = $indentMatch.Groups[1].Value }
					}
					$detailsXml = "$nl$indent<parameter $dcsatNsDecl xsi:type=`"dcsat:DetailsAreaTemplateParameter`">" +
						"$nl$indent`t<dcsat:name>$drillName</dcsat:name>" +
						"$nl$indent`t<dcsat:fieldExpression>" +
						"$nl$indent`t`t<dcsat:field>ИмяРесурса</dcsat:field>" +
						"$nl$indent`t`t<dcsat:expression>`"$resource`"</dcsat:expression>" +
						"$nl$indent`t</dcsat:fieldExpression>" +
						"$nl$indent`t<dcsat:mainAction>DrillDown</dcsat:mainAction>" +
						"$nl$indent</parameter>"
					[void]$insertions.Add(@{ pos = $insertPos; text = $detailsXml })
				}

				# Step 2: Insert appearance binding in cells referencing this parameter
				$cellTag = '<dcsat:value xsi:type="dcscor:Parameter">' + $paramName + '</dcsat:value>'
				$searchStart = 0
				while (($cellIdx = $tplText.IndexOf($cellTag, $searchStart)) -ge 0) {
					$cellEnd = $tplText.IndexOf("</dcsat:tableCell>", $cellIdx)
					if ($cellEnd -lt 0) { break }
					$appEnd = $tplText.LastIndexOf("</dcsat:appearance>", $cellEnd)
					if ($appEnd -lt $cellIdx) { $searchStart = $cellEnd + 1; continue }

					# Detect indent for appearance items — insert after \n, before indent of </dcsat:appearance>
					$appPrevNl = $tplText.LastIndexOf("`n", $appEnd)
					$appIndent = "`t`t`t`t`t`t"
					if ($appPrevNl -ge 0) {
						$appLineStart = $appPrevNl + 1
						$appIndentMatch = [regex]::Match($tplText.Substring($appLineStart), '^(\s*)')
						if ($appIndentMatch.Success) { $appIndent = $appIndentMatch.Groups[1].Value }
					}
					$itemIndent = $appIndent + "`t"
					$appearanceXml = "$itemIndent<dcscor:item>$nl" +
						"$itemIndent`t<dcscor:parameter>Расшифровка</dcscor:parameter>$nl" +
						"$itemIndent`t<dcscor:value xsi:type=`"dcscor:Parameter`">$drillName</dcscor:value>$nl" +
						"$itemIndent</dcscor:item>$nl"
					# Insert after \n (before indent of closing tag), not before the tag itself
					$insertAt = if ($appPrevNl -ge 0) { $tplStart + $appPrevNl + 1 } else { $tplStart + $appEnd }
					[void]$insertions.Add(@{ pos = $insertAt; text = $appearanceXml })
					$cellCount++
					$searchStart = $cellEnd + 1
				}

				$script:Dirty = $true; Write-Host "[OK] $drillName → $tplName (param + $cellCount cell(s))"
			}
		}

		# Apply insertions in reverse order to preserve offsets.
		# For same position: reverse insertion order so first resource ends up first in file.
		$idx = 0; foreach ($ins in $insertions) { $ins.seq = $idx; $idx++ }
		$sorted = $insertions | Sort-Object { $_.pos }, { $_.seq } -Descending
		foreach ($ins in $sorted) {
			$rawText = $rawText.Insert($ins.pos, $ins.text)
		}

		# Write directly — skip DOM save
		$enc = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($resolvedPath, $rawText, $enc)
		$script:Dirty = $true; Write-Host "[OK] Saved $resolvedPath"
		exit 0
	}
}

# --- 9. Save ---

if (-not $script:Dirty) {
	Write-Host "[INFO] No changes -- file untouched"
	exit 0
}

$content = $xmlDoc.OuterXml
$content = $content -replace '(?<=<\?xml[^?]*encoding=")utf-8(?=")', 'UTF-8'

# Format-preserve post-processing:
#   (1) restore the original raw <DataCompositionSchema ...> opening tag — DOM collapses
#       multi-line xmlns declarations into one line.
if ($script:RawRootOpening) {
	$content = [regex]::Replace($content, '<DataCompositionSchema\b[^>]*>', { param($m) $script:RawRootOpening })
}

#   (2) normalize self-closing tags: `.NET XmlDocument` adds a space before `/>`
#       (`<foo bar="x" />`) but 1C-Designer writes `<foo bar="x"/>`. Strip the space.
$content = [regex]::Replace($content, '(?<=\S) />', '/>')

#   (3) normalize line endings to match source — operations may mix LF (from new
#       fragments) with whatever the source used (CRLF on Windows, LF on Linux/git).
if ($script:LineEnding -eq "`r`n") {
	$content = $content -replace '(?<!\r)\n', "`r`n"
} else {
	$content = $content -replace "`r`n", "`n"
}

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($resolvedPath, $content, $enc)

Write-Host "[OK] Saved $resolvedPath"
