# meta-compile v1.35 — Compile 1C metadata object from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputDir
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load and validate JSON ---

if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$json = Get-Content -Raw -Encoding UTF8 $JsonPath
$def = $json | ConvertFrom-Json

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
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
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

Assert-EditAllowed $OutputDir 'editable'

# --- Batch mode: JSON array of objects ---
if ($def -is [array] -or ($null -ne $def -and $def.GetType().BaseType.Name -eq 'Array')) {
	$batchOk = 0
	$batchFail = 0
	$idx = 0
	foreach ($item in $def) {
		$idx++
		$tmpJson = Join-Path ([System.IO.Path]::GetTempPath()) "meta-compile-batch-$idx.json"
		try {
			$item | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $tmpJson
			$proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -File `"$PSCommandPath`" -JsonPath `"$tmpJson`" -OutputDir `"$OutputDir`"" -NoNewWindow -Wait -PassThru
			if ($proc.ExitCode -eq 0) { $batchOk++ } else { $batchFail++ }
		} finally {
			Remove-Item $tmpJson -Force -ErrorAction SilentlyContinue
		}
	}
	Write-Host ""
	Write-Host "=== Batch: $idx objects, $batchOk compiled, $batchFail failed ==="
	if ($batchFail -gt 0) { exit 1 }
	exit 0
}

# Normalize field synonyms: accept "objectType" as alias for "type"
if (-not $def.type -and $def.objectType) {
	$def | Add-Member -NotePropertyName "type" -NotePropertyValue $def.objectType
}

# Object type synonyms (Russian → English)
$script:objectTypeSynonyms = @{
	"Справочник"              = "Catalog"
	"Каталог"                 = "Catalog"
	"Документ"                = "Document"
	"Перечисление"            = "Enum"
	"Константа"               = "Constant"
	"РегистрСведений"         = "InformationRegister"
	"РегистрНакопления"       = "AccumulationRegister"
	"РегистрБухгалтерии"      = "AccountingRegister"
	"РегистрРасчёта"          = "CalculationRegister"
	"РегистрРасчета"          = "CalculationRegister"
	"ПланСчетов"              = "ChartOfAccounts"
	"ПланВидовХарактеристик"  = "ChartOfCharacteristicTypes"
	"ПланВидовРасчёта"        = "ChartOfCalculationTypes"
	"ПланВидовРасчета"        = "ChartOfCalculationTypes"
	"БизнесПроцесс"           = "BusinessProcess"
	"Задача"                  = "Task"
	"ПланОбмена"              = "ExchangePlan"
	"ЖурналДокументов"        = "DocumentJournal"
	"Отчёт"                   = "Report"
	"Отчет"                   = "Report"
	"Обработка"               = "DataProcessor"
	"ОбщийМодуль"             = "CommonModule"
	"РегламентноеЗадание"     = "ScheduledJob"
	"ПодпискаНаСобытие"       = "EventSubscription"
	"HTTPСервис"              = "HTTPService"
	"ВебСервис"               = "WebService"
	"ОпределяемыйТип"         = "DefinedType"
}

# Enum property value synonyms — model often gets these slightly wrong
$script:enumValueAliases = @{
	# RegisterType (AccumulationRegister)
	"Balances"  = "Balance";  "Остатки" = "Balance";  "Обороты" = "Turnovers"
	# WriteMode (InformationRegister)
	"RecordSubordinate" = "RecorderSubordinate"; "Subordinate" = "RecorderSubordinate"
	"ПодчинениеРегистратору" = "RecorderSubordinate"; "Независимый" = "Independent"
	# DependenceOnCalculationTypes (ChartOfCalculationTypes)
	"NotDependOnCalculationTypes" = "DontUse"; "NoDependence" = "DontUse"; "NotUsed" = "DontUse"
	"Depend" = "OnActionPeriod"; "ПоПериодуДействия" = "OnActionPeriod"
	# InformationRegisterPeriodicity
	"None" = "Nonperiodical"; "Daily" = "Day"; "Monthly" = "Month"
	"Quarterly" = "Quarter"; "Yearly" = "Year"
	"Непериодический" = "Nonperiodical"; "Секунда" = "Second"; "День" = "Day"
	"Месяц" = "Month"; "Квартал" = "Quarter"; "Год" = "Year"
	"ПозицияРегистратора" = "RecorderPosition"
	# DataLockControlMode
	"Автоматический" = "Automatic"; "Управляемый" = "Managed"
	# FullTextSearch
	"Использовать" = "Use"; "НеИспользовать" = "DontUse"
	# Posting
	"Разрешить" = "Allow"; "Запретить" = "Deny"
	# EditType
	"ВДиалоге" = "InDialog"; "ВСписке" = "InList"; "ОбаСпособа" = "BothWays"
	# DefaultPresentation
	"ВВидеНаименования" = "AsDescription"; "ВВидеКода" = "AsCode"
	# FillChecking
	"НеПроверять" = "DontCheck"; "Ошибка" = "ShowError"; "Предупреждение" = "ShowWarning"
	# Indexing
	"НеИндексировать" = "DontIndex"; "Индексировать" = "Index"
	"ИндексироватьСДопУпорядочиванием" = "IndexWithAdditionalOrder"
}

# Valid enum values per property (from meta-validate)
$script:validEnumValues = @{
	"RegisterType"                   = @("Balance","Turnovers")
	"WriteMode"                      = @("Independent","RecorderSubordinate")
	"InformationRegisterPeriodicity" = @("Nonperiodical","Second","Day","Month","Quarter","Year","RecorderPosition")
	"DependenceOnCalculationTypes"   = @("DontUse","OnActionPeriod")
	"DataLockControlMode"            = @("Automatic","Managed")
	"FullTextSearch"                 = @("Use","DontUse")
	"DataHistory"                    = @("Use","DontUse")
	"DefaultPresentation"            = @("AsDescription","AsCode")
	"Posting"                        = @("Allow","Deny")
	"RealTimePosting"                = @("Allow","Deny")
	"EditType"                       = @("InDialog","InList","BothWays")
	"HierarchyType"                  = @("HierarchyFoldersAndItems","HierarchyOfItems")
	"CodeType"                       = @("String","Number")
	"CodeAllowedLength"              = @("Variable","Fixed")
	"NumberType"                     = @("String","Number")
	"NumberAllowedLength"            = @("Variable","Fixed")
	"RegisterRecordsDeletion"        = @("AutoDelete","AutoDeleteOnUnpost","AutoDeleteOff")
	"RegisterRecordsWritingOnPost"   = @("WriteModified","WriteSelected","WriteAll")
	"ReturnValuesReuse"              = @("DontUse","DuringRequest","DuringSession")
	"ReuseSessions"                  = @("DontUse","AutoUse")
	"FillChecking"                   = @("DontCheck","ShowError","ShowWarning")
	"Indexing"                       = @("DontIndex","Index","IndexWithAdditionalOrder")
	"SubordinationUse"               = @("ToItems","ToFolders","ToFoldersAndItems")
	"CodeSeries"                     = @("WholeCatalog","WithinSubordination","WithinOwnerSubordination","WholeCharacteristicKind")
	"ChoiceMode"                     = @("BothWays","QuickChoice","FromForm")
	"CreateOnInput"                  = @("Auto","Use","DontUse")
	"ChoiceHistoryOnInput"           = @("Auto","DontUse")
	"PredefinedDataUpdate"           = @("Auto","DontAutoUpdate","AutoUpdate")
	"SearchStringModeOnInputByString"= @("Begin","AnyPart")
}

function Normalize-EnumValue {
	param([string]$propName, [string]$value)
	# 1. Check alias dictionary — silent auto-correct
	if ($script:enumValueAliases.ContainsKey($value)) {
		return $script:enumValueAliases[$value]
	}
	# 2. Case-insensitive match against valid values — silent
	$valid = $script:validEnumValues[$propName]
	if ($valid) {
		foreach ($v in $valid) {
			if ($v -ieq $value) { return $v }
		}
		# 3. Known property, unknown value — error with hint
		Write-Error "Invalid value '$value' for property '$propName'. Valid values: $($valid -join ', ')"
		exit 1
	}
	# 4. Unknown property — pass-through (no validation data)
	return $value
}

# Helper: read enum property from $def with default and normalization
function Get-EnumProp {
	param([string]$propName, [string]$fieldName, [string]$default)
	$val = $def.$fieldName
	$raw = if ($val) { "$val" } else { $default }
	return (Normalize-EnumValue $propName $raw)
}

# Bool object-свойство: presence-aware (иначе false-значение спутать с отсутствием). Прощаем строки.
function Get-BoolProp {
	param([string]$fieldName, [bool]$default)
	$val = $def.$fieldName
	if ($null -eq $val) { return $default }
	if ($val -is [bool]) { return $val }
	return ("$val" -match '^(true|1|да|истина)$')
}

# Прощающая нормализация ссылки на форму: рус корень (Справочник→Catalog), сегмент Форма→Form,
# короткая запись "Тип.Объект.ИмяФормы" (без Form) → вставка Form. Уже канон англ. → без изменений.
function Normalize-FormRef {
	param([string]$s)
	if (-not $s) { return $s }
	$parts = $s -split '\.'
	if ($parts.Count -lt 3) { return $s }
	$root = $script:fillRefRoots[$parts[0].ToLower()]
	if ($root) { $parts[0] = $root }
	for ($k = 1; $k -lt $parts.Count; $k++) { if ($parts[$k] -ieq 'Форма') { $parts[$k] = 'Form' } }
	if (($parts -notcontains 'Form') -and $parts.Count -eq 3) { $parts = @($parts[0], $parts[1], 'Form', $parts[2]) }
	return ($parts -join '.')
}

# Ссылка на форму по умолчанию: непустая → <Tag>значение</Tag>, иначе <Tag/>.
function Emit-FormRef {
	param([string]$i, [string]$tag, $val)
	if ($val) { X "$i<$tag>$(Esc-Xml (Normalize-FormRef "$val"))</$tag>" } else { X "$i<$tag/>" }
}

if (-not $def.type) {
	Write-Error "JSON must have 'type' field"
	exit 1
}

# Resolve type synonym
$objType = "$($def.type)"
if ($script:objectTypeSynonyms.ContainsKey($objType)) {
	$objType = $script:objectTypeSynonyms[$objType]
}

$validTypes = @("Catalog","Document","Enum","Constant","InformationRegister","AccumulationRegister",
	"AccountingRegister","CalculationRegister","ChartOfAccounts","ChartOfCharacteristicTypes",
	"ChartOfCalculationTypes","BusinessProcess","Task","ExchangePlan","DocumentJournal",
	"Report","DataProcessor","CommonModule","ScheduledJob","EventSubscription",
	"HTTPService","WebService","DefinedType")
if ($objType -notin $validTypes) {
	Write-Error "Unsupported type: $objType. Valid: $($validTypes -join ', ')"
	exit 1
}

if (-not $def.name) {
	Write-Error "JSON must have 'name' field"
	exit 1
}

$objName = "$($def.name)"

# --- 2. XML helpers ---

$script:xml = New-Object System.Text.StringBuilder 32768

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}
# Эскейп ТЕКСТА элемента: только & < > (кавычки в тексте 1С держит raw, экранирование только для атрибутов).
function Esc-XmlText {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# ML-значение: строка → один <v8:item> ru; объект {lang: content} → item на язык (в порядке ключей).
function Emit-MLItems {
	param([string]$indent, $val)
	if ($val -is [System.Collections.IDictionary]) {
		foreach ($k in $val.Keys) {
			X "$indent<v8:item>"; X "$indent`t<v8:lang>$k</v8:lang>"; X "$indent`t<v8:content>$(Esc-XmlText "$($val[$k])")</v8:content>"; X "$indent</v8:item>"
		}
	} elseif ($val -is [System.Management.Automation.PSCustomObject]) {
		foreach ($p in $val.PSObject.Properties) {
			X "$indent<v8:item>"; X "$indent`t<v8:lang>$($p.Name)</v8:lang>"; X "$indent`t<v8:content>$(Esc-XmlText "$($p.Value)")</v8:content>"; X "$indent</v8:item>"
		}
	} else {
		X "$indent<v8:item>"; X "$indent`t<v8:lang>ru</v8:lang>"; X "$indent`t<v8:content>$(Esc-XmlText "$val")</v8:content>"; X "$indent</v8:item>"
	}
}
function Emit-MLText {
	param([string]$indent, [string]$tag, $text)
	# Пусто (null / пустая строка) → самозакрывающийся тег.
	if (($null -eq $text) -or (($text -is [string]) -and ($text -eq ''))) {
		X "$indent<$tag/>"
		return
	}
	X "$indent<$tag>"
	Emit-MLItems "$indent`t" $text
	X "$indent</$tag>"
}

function New-Guid-String {
	return [System.Guid]::NewGuid().ToString()
}

# --- 3. CamelCase splitter ---

function Split-CamelCase {
	param([string]$name)
	if (-not $name) { return $name }
	# Insert space before uppercase that follows lowercase (Cyrillic + Latin)
	$result = [regex]::Replace($name, '([а-яё])([А-ЯЁ])', '$1 $2')
	$result = [regex]::Replace($result, '([a-z])([A-Z])', '$1 $2')
	# Lowercase all but first character of the result
	if ($result.Length -gt 1) {
		$result = $result.Substring(0,1) + $result.Substring(1).ToLower()
	}
	return $result
}

# Auto-synonym. Проброс без стрингификации (строка ИЛИ {ru,en} — мультиязычный синоним объекта).
$synonym = if ($null -ne $def.synonym) { $def.synonym } else { Split-CamelCase $objName }
$comment = if ($def.comment) { "$($def.comment)" } else { "" }

# --- 4. Type system ---

$script:typeSynonyms = New-Object System.Collections.Hashtable
$script:typeSynonyms["число"]    = "Number"
$script:typeSynonyms["строка"]   = "String"
$script:typeSynonyms["булево"]   = "Boolean"
$script:typeSynonyms["дата"]     = "Date"
$script:typeSynonyms["датавремя"]= "DateTime"
$script:typeSynonyms["время"]    = "Time"
$script:typeSynonyms["time"]     = "Time"
$script:typeSynonyms["number"]   = "Number"
$script:typeSynonyms["string"]   = "String"
$script:typeSynonyms["boolean"]  = "Boolean"
$script:typeSynonyms["date"]     = "Date"
$script:typeSynonyms["datetime"] = "DateTime"
$script:typeSynonyms["bool"]     = "Boolean"
# ValueStorage / UUID — прощающий ввод (модель может написать base64Binary / рус. форму → канон).
$script:typeSynonyms["valuestorage"]         = "ValueStorage"
$script:typeSynonyms["base64binary"]         = "ValueStorage"
$script:typeSynonyms["хранилищезначений"]    = "ValueStorage"
$script:typeSynonyms["хранилищезначения"]    = "ValueStorage"
$script:typeSynonyms["uuid"]                 = "UUID"
$script:typeSynonyms["уникальныйидентификатор"] = "UUID"
# Reference synonyms (Russian, lowercase)
$script:typeSynonyms["справочникссылка"]             = "CatalogRef"
$script:typeSynonyms["документссылка"]               = "DocumentRef"
$script:typeSynonyms["перечислениессылка"]            = "EnumRef"
$script:typeSynonyms["плансчетовссылка"]              = "ChartOfAccountsRef"
$script:typeSynonyms["планвидовхарактеристикссылка"]  = "ChartOfCharacteristicTypesRef"
$script:typeSynonyms["планвидоврасчётассылка"]         = "ChartOfCalculationTypesRef"
$script:typeSynonyms["планвидоврасчетассылка"]         = "ChartOfCalculationTypesRef"
$script:typeSynonyms["планобменассылка"]               = "ExchangePlanRef"
$script:typeSynonyms["бизнеспроцессссылка"]            = "BusinessProcessRef"
$script:typeSynonyms["задачассылка"]                   = "TaskRef"
$script:typeSynonyms["определяемыйтип"]              = "DefinedType"
$script:typeSynonyms["definedtype"]                   = "DefinedType"
# English lowercase ref synonyms
$script:typeSynonyms["catalogref"]                    = "CatalogRef"
$script:typeSynonyms["documentref"]                   = "DocumentRef"
$script:typeSynonyms["enumref"]                       = "EnumRef"

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	# Check for parameterized types: Number(15,2), Строка(100), etc.
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]
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

	# Simple name lookup
	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }

	return $typeStr
}

function Emit-TypeContent {
	param([string]$indent, [string]$typeStr)
	if (-not $typeStr) { return }

	# Composite type: "Type1 + Type2 + Type3"
	if ($typeStr.Contains(' + ')) {
		$parts = $typeStr -split '\s*\+\s*'
		foreach ($part in $parts) {
			Emit-TypeContent $indent $part.Trim()
		}
		return
	}

	$typeStr = Resolve-TypeStr $typeStr

	# Boolean
	if ($typeStr -eq "Boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"
		return
	}

	# String or String(N) or String(N,fixed|variable) — AllowedLength: Variable дефолт / Fixed (фикс. длина).
	if ($typeStr -match '^String(\((\d+)(\s*,\s*(fixed|variable))?\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "10" }
		$al = if ($Matches[4] -and $Matches[4].ToLower() -eq 'fixed') { 'Fixed' } else { 'Variable' }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>$al</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"
		return
	}

	# Number without params → Number(10,0)
	if ($typeStr -eq "Number") {
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>10</v8:Digits>"
		X "$indent`t<v8:FractionDigits>0</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>Any</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"
		return
	}

	# Number(D,F) or Number(D,F,nonneg)
	if ($typeStr -match '^Number\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]
		$fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>$digits</v8:Digits>"
		X "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"
		return
	}

	# Date / DateTime / Time — общая структура xs:dateTime + DateFractions (различаются лишь составом).
	if ($typeStr -match '^(Date|DateTime|Time)$') {
		X "$indent<v8:Type>xs:dateTime</v8:Type>"
		X "$indent<v8:DateQualifiers>"
		X "$indent`t<v8:DateFractions>$typeStr</v8:DateFractions>"
		X "$indent</v8:DateQualifiers>"
		return
	}

	# TypeSet — тип-множество: ОпределяемыйТип (DefinedType) ИЛИ Характеристика ПВХ (Characteristic).
	if ($typeStr -match '^(DefinedType|Characteristic)\.(.+)$') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}
	# Голый метатип-категория (CatalogRef/DocumentRef/…/AnyRef/AnyIBRef без имени объекта) — множество
	# «любой объект категории» → TypeSet (а не конкретный Type с именем).
	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef|AnyRef|AnyIBRef)$') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}

	# ValueStorage (ХранилищеЗначения) — канон v8:ValueStorage (не xs:base64Binary, хоть 1С и принимает оба).
	if ($typeStr -eq "ValueStorage") {
		X "$indent<v8:Type>v8:ValueStorage</v8:Type>"
		return
	}
	# UUID (УникальныйИдентификатор)
	if ($typeStr -eq "UUID") {
		X "$indent<v8:Type>v8:UUID</v8:Type>"
		return
	}

	# Reference types — use local xmlns declaration for 1C compatibility
	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef)\.(.+)$') {
		X "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$typeStr</v8:Type>"
		return
	}

	# Fallback — emit as-is
	X "$indent<v8:Type>$typeStr</v8:Type>"
}

function Emit-ValueType {
	param([string]$indent, [string]$typeStr)
	X "$indent<Type>"
	Emit-TypeContent "$indent`t" $typeStr
	X "$indent</Type>"
}

# --- FillValue (значение заполнения реквизита) ---
# Пара FillFromFillingValue+FillValue — единый блок «заполнения» (недоступен у реквизитов ТЧ).
# Форма пустого FillValue зависит от типа реквизита (то же значение по умолчанию, что и «пустое»
# значение типа): String→typed-empty, Number→0, всё остальное (Boolean/Date/Ref/составной/TypeSet)→nil.
# Реальное значение задаётся ключом `fillValue` (интерпретация по типу реквизита; см. §4.2 spec).

# Категория типа реквизита для выбора формы FillValue.
function Get-FillTypeCategory {
	param([string]$typeStr)
	if (-not $typeStr) { return 'String' }        # реквизит без типа → неквалифиц. строка
	if ($typeStr -match '\+') { return 'Other' }  # составной тип → nil-дефолт
	$t = Resolve-TypeStr $typeStr
	if ($t -match '^Boolean$')          { return 'Boolean' }
	if ($t -match '^String(\(|$)')      { return 'String' }
	if ($t -match '^Number(\(|$)')      { return 'Number' }
	if ($t -match '^(Date|DateTime)$')  { return 'Date' }
	return 'Other'                                 # ссылки, TypeSet, ValueStorage, … → nil-дефолт
}

# Прощающий ввод для ссылочных путей DTR: рус/англ корни, ПустаяСсылка/EmptyRef, ЗначениеПеречисления/EnumValue.
$script:fillRefRoots = @{
	'перечисление'='Enum'; 'справочник'='Catalog'; 'документ'='Document';
	'плансчетов'='ChartOfAccounts'; 'планвидовхарактеристик'='ChartOfCharacteristicTypes';
	'планвидоврасчета'='ChartOfCalculationTypes'; 'планвидоврасчёта'='ChartOfCalculationTypes';
	'планобмена'='ExchangePlan'; 'бизнеспроцесс'='BusinessProcess'; 'задача'='Task';
	'enum'='Enum'; 'catalog'='Catalog'; 'document'='Document'; 'chartofaccounts'='ChartOfAccounts';
	'chartofcharacteristictypes'='ChartOfCharacteristicTypes'; 'chartofcalculationtypes'='ChartOfCalculationTypes';
	'exchangeplan'='ExchangePlan'; 'businessprocess'='BusinessProcess'; 'task'='Task'
}
$script:fillEmptyRefWords = @('emptyref','пустаяссылка')
$script:fillEnumValWords  = @('enumvalue','значениеперечисления')
$script:fillBoolTrue  = @('true','истина','да')
$script:fillBoolFalse = @('false','ложь','нет')
# XxxRef (тип реквизита) → корень DTR-пути (для разворота короткой записи значения).
$script:fillRefKindRoot = @{
	'catalogref'='Catalog'; 'documentref'='Document'; 'enumref'='Enum';
	'chartofaccountsref'='ChartOfAccounts'; 'chartofcharacteristictypesref'='ChartOfCharacteristicTypes';
	'chartofcalculationtypesref'='ChartOfCalculationTypes'; 'exchangeplanref'='ExchangePlan';
	'businessprocessref'='BusinessProcess'; 'taskref'='Task'
}

# Короткая запись значения ссылочного реквизита (без точки): имя разворачиваем по типу реквизита.
# "EmptyRef"/"ПустаяСсылка" → <Root>.<Тип>.EmptyRef; для Enum — EnumValue; прочие — предопределённое.
# $null, если развернуть нельзя (тип не одиночный ссылочный).
function Expand-FillShortRef {
	param([string]$s, [string]$typeStr)
	if (-not $typeStr) { return $null }
	if ($typeStr -match '\+') { return $null }   # составной тип — короткая форма неоднозначна
	$t = Resolve-TypeStr $typeStr
	if ($t -notmatch '^(\w+Ref)\.(.+)$') { return $null }
	$root = $script:fillRefKindRoot[$Matches[1].ToLower()]
	if (-not $root) { return $null }
	$typeName = $Matches[2]
	if ($script:fillEmptyRefWords -contains $s.ToLower()) { return "$root.$typeName.EmptyRef" }
	if ($root -eq 'Enum') { return "Enum.$typeName.EnumValue.$s" }
	return "$root.$typeName.$s"
}

# Строка → нормализованный DTR-путь ("Catalog.X.EmptyRef" / "Enum.X.EnumValue.Y" / GUID.GUID) ЛИБО $null (не ссылка).
function Normalize-FillRef {
	param([string]$s)
	if ([string]::IsNullOrEmpty($s)) { return $null }
	# Raw-ссылка по паре GUID (метаданные.значение) — всегда ссылка.
	if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F-]+$') { return $s }
	$parts = $s -split '\.'
	if ($parts.Count -lt 2) { return $null }
	$root = $script:fillRefRoots[$parts[0].ToLower()]
	if (-not $root) { return $null }
	$typeName = $parts[1]
	if ($root -eq 'Enum') {
		if ($parts.Count -eq 2) { return $null }   # "Enum.X" — не значение
		if ($parts.Count -eq 3) {
			if ($script:fillEmptyRefWords -contains $parts[2].ToLower()) { return "Enum.$typeName.EmptyRef" }
			return "Enum.$typeName.EnumValue.$($parts[2])"
		}
		$member = $parts[2]
		if ($script:fillEnumValWords -contains $member.ToLower()) { $rest = $parts[3..($parts.Count-1)] -join '.' }
		else { $rest = $parts[2..($parts.Count-1)] -join '.' }
		return "Enum.$typeName.EnumValue.$rest"
	}
	# Прочие корни: переводим корень, ПустаяСсылка→EmptyRef в хвосте.
	$tail = @($parts[1..($parts.Count-1)])
	for ($i = 0; $i -lt $tail.Count; $i++) {
		if ($script:fillEmptyRefWords -contains $tail[$i].ToLower()) { $tail[$i] = 'EmptyRef' }
	}
	return "$root." + ($tail -join '.')
}

# Строковый spec → @{ XsiType; Text }. Интерпретация по типу реквизита ($typeStr).
function Resolve-FillValueSpec {
	param([string]$s, [string]$typeStr)
	$cat = Get-FillTypeCategory $typeStr
	if ($s -eq '') { return @{ XsiType='xs:string'; Text='' } }
	# String-реквизит: значение заполнения — всегда строковый литерал (без ref/date-детекции).
	if ($cat -eq 'String') { return @{ XsiType='xs:string'; Text=$s } }
	# Булевы слова (для Boolean-реквизита ИЛИ явное истина/ложь).
	if ($cat -eq 'Boolean' -or ($script:fillBoolTrue -contains $s.ToLower()) -or ($script:fillBoolFalse -contains $s.ToLower())) {
		if ($script:fillBoolTrue  -contains $s.ToLower()) { return @{ XsiType='xs:boolean'; Text='true' } }
		if ($script:fillBoolFalse -contains $s.ToLower()) { return @{ XsiType='xs:boolean'; Text='false' } }
	}
	if ($cat -eq 'Number') { return @{ XsiType='xs:decimal'; Text=$s } }
	# Дата: явный Date-реквизит ИЛИ ISO-паттерн. "2020-01-01" → добавить время.
	if ($cat -eq 'Date' -or $s -match '^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$') {
		if ($s -match '^\d{4}-\d{2}-\d{2}$') { $s = "${s}T00:00:00" }
		return @{ XsiType='xs:dateTime'; Text=$s }
	}
	# Полный ссылочный путь DTR (с точкой: "Catalog.X.EmptyRef", "Enum.X.EnumValue.Y", GUID.GUID).
	$ref = Normalize-FillRef $s
	if ($ref) { return @{ XsiType='xr:DesignTimeRef'; Text=$ref } }
	# Короткая запись значения ссылочного реквизита (одно имя — разворачиваем по типу).
	$short = Expand-FillShortRef $s $typeStr
	if ($short) { return @{ XsiType='xr:DesignTimeRef'; Text=$short } }
	# Фолбэк — строковый литерал.
	return @{ XsiType='xs:string'; Text=$s }
}

# Формат числа-значения без привязки к культуре (точка-разделитель).
function Format-FillNum {
	param($n)
	if ($n -is [double] -or $n -is [decimal]) { return $n.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
	return "$n"
}

# $spec — значение ключа `fillValue` ($null при явном nil-override), $hasSpec — присутствует ли ключ.
function Emit-FillValue {
	param([string]$indent, [string]$typeStr, $spec, $hasSpec)
	$cat = Get-FillTypeCategory $typeStr

	if ($hasSpec -ne $true) {
		# Значение не задано — форма по умолчанию для типа.
		switch ($cat) {
			'String' { X "$indent<FillValue xsi:type=`"xs:string`"/>"; return }
			'Number' { X "$indent<FillValue xsi:type=`"xs:decimal`">0</FillValue>"; return }
			default  { X "$indent<FillValue xsi:nil=`"true`"/>"; return }
		}
	}

	if ($null -eq $spec) { X "$indent<FillValue xsi:nil=`"true`"/>"; return }   # явный nil-override
	if ($spec -is [bool]) {
		X "$indent<FillValue xsi:type=`"xs:boolean`">$(if ($spec) { 'true' } else { 'false' })</FillValue>"; return
	}
	if ($spec -is [int] -or $spec -is [long] -or $spec -is [double] -or $spec -is [decimal]) {
		X "$indent<FillValue xsi:type=`"xs:decimal`">$(Format-FillNum $spec)</FillValue>"; return
	}
	$r = Resolve-FillValueSpec "$spec" $typeStr
	if ($r.Text -eq '' -and $r.XsiType -eq 'xs:string') { X "$indent<FillValue xsi:type=`"xs:string`"/>"; return }
	X "$indent<FillValue xsi:type=`"$($r.XsiType)`">$(Esc-XmlText $r.Text)</FillValue>"
}

# --- 5. Attribute shorthand parser ---

function Build-TypeStr {
	param($obj)
	$t = if ($obj.valueType) { "$($obj.valueType)" } elseif ($obj.type) { "$($obj.type)" } else { "" }
	if ($t -and -not $t.Contains('(')) {
		if ($t -eq "String" -and $obj.length) {
			$t = "String($($obj.length))"
		} elseif ($t -eq "Number" -and $obj.length) {
			$p = if ($obj.precision) { $obj.precision } else { 0 }
			$nn = if ($obj.nonneg -or $obj.nonnegative) { ",nonneg" } else { "" }
			$t = "Number($($obj.length),$p$nn)"
		}
	}
	return $t
}

function Parse-AttributeShorthand {
	param($val)

	if ($val -is [string]) {
		$str = "$val"
		$parsed = @{
			name = ""
			type = ""
			synonym = ""
			comment = ""
			flags = @()
			hasFillValue = $false
			fillValue = $null
		}

		# Split by | for flags
		$parts = $str -split '\|', 2
		$mainPart = $parts[0].Trim()
		if ($parts.Count -gt 1) {
			$flagStr = $parts[1].Trim()
			$parsed.flags = @($flagStr -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
		}

		# Split by : for name and type
		$colonParts = $mainPart -split ':', 2
		$parsed.name = $colonParts[0].Trim()
		if ($colonParts.Count -gt 1) {
			$parsed.type = $colonParts[1].Trim()
		}

		$parsed.synonym = Split-CamelCase $parsed.name
		return $parsed
	}

	# Object form. synonym/tooltip/format/editFormat — сквозной проброс (строка ИЛИ {ru,en}), НЕ стрингифаим.
	# fillCheck — синоним fillChecking (из формы; bool true→ShowError). quickChoice — прощаем bool (true→Use, false→DontUse).
	$name = "$($val.name)"
	$fc = if ($val.fillChecking) { "$($val.fillChecking)" }
	      elseif ($null -ne $val.fillCheck) { if ($val.fillCheck -is [bool]) { if ($val.fillCheck) { 'ShowError' } else { '' } } else { "$($val.fillCheck)" } }
	      else { "" }
	$qc = if ($null -ne $val.quickChoice) { if ($val.quickChoice -is [bool]) { if ($val.quickChoice) { 'Use' } else { 'DontUse' } } else { "$($val.quickChoice)" } } else { "" }
	return @{
		name    = $name
		type    = Build-TypeStr $val
		synonym = if ($null -ne $val.synonym) { $val.synonym } else { Split-CamelCase $name }
		tooltip = $val.tooltip
		comment = if ($val.comment) { "$($val.comment)" } else { "" }
		flags   = @(if ($val.flags) { $val.flags } else { @() })
		fillChecking = $fc
		indexing = if ($val.indexing) { "$($val.indexing)" } else { "" }
		multiLine = if ($val.multiLine -eq $true) { $true } else { $false }
		choiceHistoryOnInput = if ($val.choiceHistoryOnInput) { "$($val.choiceHistoryOnInput)" } else { "" }
		fullTextSearch = if ($val.fullTextSearch) { "$($val.fullTextSearch)" } else { "" }
		fillFromFillingValue = if ($val.fillFromFillingValue -eq $true) { $true } else { $false }
		createOnInput = if ($val.createOnInput) { "$($val.createOnInput)" } else { "" }
		quickChoice = $qc
		dataHistory = if ($val.dataHistory) { "$($val.dataHistory)" } else { "" }
		use = if ($val.use) { "$($val.use)" } else { "" }
		passwordMode = if ($val.passwordMode -eq $true) { $true } else { $false }
		format = $val.format
		editFormat = $val.editFormat
		mask = if ($val.mask) { "$($val.mask)" } else { "" }
		extendedEdit = if ($val.extendedEdit -eq $true) { $true } else { $false }
		minValue = $val.minValue
		maxValue = $val.maxValue
		hasFillValue = ($val.PSObject -and $val.PSObject.Properties -and ($val.PSObject.Properties.Name -contains 'fillValue'))
		fillValue = $val.fillValue
		linkByType = $val.linkByType
		choiceParameterLinks = $val.choiceParameterLinks
		choiceParameters = $val.choiceParameters
	}
}

function Parse-EnumValueShorthand {
	param($val)

	if ($val -is [string]) {
		$name = "$val"
		return @{
			name    = $name
			synonym = Split-CamelCase $name
			comment = ""
		}
	}

	$name = "$($val.name)"
	return @{
		name    = $name
		synonym = if ($val.synonym) { "$($val.synonym)" } else { Split-CamelCase $name }
		comment = if ($val.comment) { "$($val.comment)" } else { "" }
	}
}

# --- 6. GeneratedType categories ---

$script:generatedTypes = @{
	"Catalog" = @(
		@{ prefix = "CatalogObject";    category = "Object" }
		@{ prefix = "CatalogRef";       category = "Ref" }
		@{ prefix = "CatalogSelection"; category = "Selection" }
		@{ prefix = "CatalogList";      category = "List" }
		@{ prefix = "CatalogManager";   category = "Manager" }
	)
	"Document" = @(
		@{ prefix = "DocumentObject";    category = "Object" }
		@{ prefix = "DocumentRef";       category = "Ref" }
		@{ prefix = "DocumentSelection"; category = "Selection" }
		@{ prefix = "DocumentList";      category = "List" }
		@{ prefix = "DocumentManager";   category = "Manager" }
	)
	"Enum" = @(
		@{ prefix = "EnumRef";     category = "Ref" }
		@{ prefix = "EnumManager"; category = "Manager" }
		@{ prefix = "EnumList";    category = "List" }
	)
	"Constant" = @(
		@{ prefix = "ConstantManager";      category = "Manager" }
		@{ prefix = "ConstantValueManager"; category = "ValueManager" }
		@{ prefix = "ConstantValueKey";     category = "ValueKey" }
	)
	"InformationRegister" = @(
		@{ prefix = "InformationRegisterRecord";        category = "Record" }
		@{ prefix = "InformationRegisterManager";       category = "Manager" }
		@{ prefix = "InformationRegisterSelection";     category = "Selection" }
		@{ prefix = "InformationRegisterList";          category = "List" }
		@{ prefix = "InformationRegisterRecordSet";     category = "RecordSet" }
		@{ prefix = "InformationRegisterRecordKey";     category = "RecordKey" }
		@{ prefix = "InformationRegisterRecordManager"; category = "RecordManager" }
	)
	"AccumulationRegister" = @(
		@{ prefix = "AccumulationRegisterRecord";    category = "Record" }
		@{ prefix = "AccumulationRegisterManager";   category = "Manager" }
		@{ prefix = "AccumulationRegisterSelection"; category = "Selection" }
		@{ prefix = "AccumulationRegisterList";      category = "List" }
		@{ prefix = "AccumulationRegisterRecordSet"; category = "RecordSet" }
		@{ prefix = "AccumulationRegisterRecordKey"; category = "RecordKey" }
	)
	"AccountingRegister" = @(
		@{ prefix = "AccountingRegisterRecord";         category = "Record" }
		@{ prefix = "AccountingRegisterExtDimensions";  category = "ExtDimensions" }
		@{ prefix = "AccountingRegisterRecordSet";      category = "RecordSet" }
		@{ prefix = "AccountingRegisterRecordKey";      category = "RecordKey" }
		@{ prefix = "AccountingRegisterSelection";      category = "Selection" }
		@{ prefix = "AccountingRegisterList";           category = "List" }
		@{ prefix = "AccountingRegisterManager";        category = "Manager" }
	)
	"CalculationRegister" = @(
		@{ prefix = "CalculationRegisterRecord";    category = "Record" }
		@{ prefix = "CalculationRegisterManager";   category = "Manager" }
		@{ prefix = "CalculationRegisterSelection"; category = "Selection" }
		@{ prefix = "CalculationRegisterList";      category = "List" }
		@{ prefix = "CalculationRegisterRecordSet"; category = "RecordSet" }
		@{ prefix = "CalculationRegisterRecordKey"; category = "RecordKey" }
		@{ prefix = "RecalculationsManager";        category = "Recalcs" }
	)
	"ChartOfAccounts" = @(
		@{ prefix = "ChartOfAccountsObject";              category = "Object" }
		@{ prefix = "ChartOfAccountsRef";                 category = "Ref" }
		@{ prefix = "ChartOfAccountsSelection";           category = "Selection" }
		@{ prefix = "ChartOfAccountsList";                category = "List" }
		@{ prefix = "ChartOfAccountsManager";             category = "Manager" }
		@{ prefix = "ChartOfAccountsExtDimensionTypes";   category = "ExtDimensionTypes" }
		@{ prefix = "ChartOfAccountsExtDimensionTypesRow"; category = "ExtDimensionTypesRow" }
	)
	"ChartOfCharacteristicTypes" = @(
		@{ prefix = "ChartOfCharacteristicTypesObject";         category = "Object" }
		@{ prefix = "ChartOfCharacteristicTypesRef";            category = "Ref" }
		@{ prefix = "ChartOfCharacteristicTypesSelection";      category = "Selection" }
		@{ prefix = "ChartOfCharacteristicTypesList";           category = "List" }
		@{ prefix = "Characteristic";                          category = "Characteristic" }
		@{ prefix = "ChartOfCharacteristicTypesManager";        category = "Manager" }
	)
	"ChartOfCalculationTypes" = @(
		@{ prefix = "ChartOfCalculationTypesObject";    category = "Object" }
		@{ prefix = "ChartOfCalculationTypesRef";       category = "Ref" }
		@{ prefix = "ChartOfCalculationTypesSelection"; category = "Selection" }
		@{ prefix = "ChartOfCalculationTypesList";      category = "List" }
		@{ prefix = "ChartOfCalculationTypesManager";   category = "Manager" }
		@{ prefix = "DisplacingCalculationTypes";       category = "DisplacingCalculationTypes" }
		@{ prefix = "DisplacingCalculationTypesRow";    category = "DisplacingCalculationTypesRow" }
		@{ prefix = "BaseCalculationTypes";             category = "BaseCalculationTypes" }
		@{ prefix = "BaseCalculationTypesRow";          category = "BaseCalculationTypesRow" }
		@{ prefix = "LeadingCalculationTypes";          category = "LeadingCalculationTypes" }
		@{ prefix = "LeadingCalculationTypesRow";       category = "LeadingCalculationTypesRow" }
	)
	"BusinessProcess" = @(
		@{ prefix = "BusinessProcessObject";        category = "Object" }
		@{ prefix = "BusinessProcessRef";            category = "Ref" }
		@{ prefix = "BusinessProcessSelection";      category = "Selection" }
		@{ prefix = "BusinessProcessList";           category = "List" }
		@{ prefix = "BusinessProcessManager";        category = "Manager" }
		@{ prefix = "BusinessProcessRoutePointRef";  category = "RoutePointRef" }
	)
	"Task" = @(
		@{ prefix = "TaskObject";    category = "Object" }
		@{ prefix = "TaskRef";       category = "Ref" }
		@{ prefix = "TaskSelection"; category = "Selection" }
		@{ prefix = "TaskList";      category = "List" }
		@{ prefix = "TaskManager";   category = "Manager" }
	)
	"ExchangePlan" = @(
		@{ prefix = "ExchangePlanObject";    category = "Object" }
		@{ prefix = "ExchangePlanRef";       category = "Ref" }
		@{ prefix = "ExchangePlanSelection"; category = "Selection" }
		@{ prefix = "ExchangePlanList";      category = "List" }
		@{ prefix = "ExchangePlanManager";   category = "Manager" }
	)
	"DefinedType" = @(
		@{ prefix = "DefinedType"; category = "DefinedType" }
	)
	"DocumentJournal" = @(
		@{ prefix = "DocumentJournalSelection"; category = "Selection" }
		@{ prefix = "DocumentJournalList";      category = "List" }
		@{ prefix = "DocumentJournalManager";   category = "Manager" }
	)
	"Report" = @(
		@{ prefix = "ReportObject";  category = "Object" }
		@{ prefix = "ReportManager"; category = "Manager" }
	)
	"DataProcessor" = @(
		@{ prefix = "DataProcessorObject";  category = "Object" }
		@{ prefix = "DataProcessorManager"; category = "Manager" }
	)
}

function Emit-InternalInfo {
	param([string]$indent, [string]$objectType, [string]$objectName)
	$types = $script:generatedTypes[$objectType]
	if (-not $types) { return }

	X "$indent<InternalInfo>"
	# ExchangePlan: ThisNode UUID before GeneratedTypes
	if ($objectType -eq "ExchangePlan") {
		X "$indent`t<xr:ThisNode>$(New-Guid-String)</xr:ThisNode>"
	}
	foreach ($gt in $types) {
		$fullName = "$($gt.prefix).$objectName"
		X "$indent`t<xr:GeneratedType name=`"$fullName`" category=`"$($gt.category)`">"
		X "$indent`t`t<xr:TypeId>$(New-Guid-String)</xr:TypeId>"
		X "$indent`t`t<xr:ValueId>$(New-Guid-String)</xr:ValueId>"
		X "$indent`t</xr:GeneratedType>"
	}
	X "$indent</InternalInfo>"
}

# --- 7. StandardAttributes ---

$script:standardAttributesByType = @{
	"Catalog" = @("PredefinedDataName","Predefined","Ref","DeletionMark","IsFolder","Owner","Parent","Description","Code")
	"Document" = @("Posted","Ref","DeletionMark","Date","Number")
	"Enum" = @("Order","Ref")
	"InformationRegister" = @("Active","LineNumber","Recorder","Period")
	"AccumulationRegister" = @("Active","LineNumber","Recorder","Period")
	"AccountingRegister" = @("Active","Period","Recorder","LineNumber","Account")
	"CalculationRegister" = @("Active","Recorder","LineNumber","RegistrationPeriod","CalculationType","ReversingEntry")
	"ChartOfAccounts" = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","Parent","Order","Type","OffBalance")
	"ChartOfCharacteristicTypes" = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","Parent","ValueType")
	"ChartOfCalculationTypes" = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","ActionPeriodIsBasic")
	"BusinessProcess" = @("Ref","DeletionMark","Date","Number","Started","Completed","HeadTask")
	"Task" = @("Ref","DeletionMark","Date","Number","Executed","Description","RoutePoint","BusinessProcess")
	"ExchangePlan" = @("Ref","DeletionMark","Code","Description","ThisNode","SentNo","ReceivedNo")
	"DocumentJournal" = @("Type","Ref","Date","Posted","DeletionMark","Number")
}

# Профиль материализованного блока StandardAttributes (значения, которые платформа заполняет
# автоматически при материализации блока, независимо от структуры каталога). Выведено из корпуса
# (acc+erp: Owner.FFV=true 1592/1596, Owner.FC=ShowError 1589, Parent.FFV=true 1593, Description.FC=ShowError 1467)
# и подтверждено синтетикой. Пока только Catalog (у прочих типов свои профили — добавим при их пилоте).
$script:stdAttrProfile = @{
	"Catalog" = @{
		"Owner"       = @{ FillChecking = "ShowError"; FillFromFillingValue = "true" }
		"Parent"      = @{ FillFromFillingValue = "true" }
		"Description"  = @{ FillChecking = "ShowError" }
	}
	# ExchangePlan: Наименование/Код → FillChecking=ShowError (корпус 40/38 из 41).
	"ExchangePlan" = @{
		"Description" = @{ FillChecking = "ShowError" }
		"Code"        = @{ FillChecking = "ShowError" }
	}
	# ChartOfCharacteristicTypes: Наименование → FillChecking=ShowError (21/23), Родитель → FFV=true (23/23).
	"ChartOfCharacteristicTypes" = @{
		"Description" = @{ FillChecking = "ShowError" }
		"Parent"      = @{ FillFromFillingValue = "true" }
	}
}

# $ov — hashtable переопределений (профиль + DSL) для полей: FillChecking, FillFromFillingValue,
# Synonym, FullTextSearch, DataHistory. Прочие поля — фиксированный schema-дефолт.
function Emit-StandardAttribute {
	param([string]$indent, [string]$attrName, $ov = $null)
	function OvOr { param($k, $d) if ($ov -and $ov.ContainsKey($k)) { return $ov[$k] } else { return $d } }
	$fc  = OvOr 'FillChecking' 'DontCheck'
	$ffv = OvOr 'FillFromFillingValue' 'false'
	$dh  = OvOr 'DataHistory' 'Use'
	$fts = OvOr 'FullTextSearch' 'Use'
	$syn = OvOr 'Synonym' ''
	$tt  = OvOr 'ToolTip' ''
	$cf  = OvOr 'ChoiceForm' ''
	$cmt = OvOr 'Comment' ''
	$msk = OvOr 'Mask' ''
	$fmt = OvOr 'Format' $null
	$efmt = OvOr 'EditFormat' $null
	$chi = OvOr 'ChoiceHistoryOnInput' 'Auto'
	X "$indent<xr:StandardAttribute name=`"$attrName`">"
	X "$indent`t<xr:LinkByType/>"
	X "$indent`t<xr:FillChecking>$fc</xr:FillChecking>"
	X "$indent`t<xr:MultiLine>false</xr:MultiLine>"
	X "$indent`t<xr:FillFromFillingValue>$ffv</xr:FillFromFillingValue>"
	X "$indent`t<xr:CreateOnInput>Auto</xr:CreateOnInput>"
	X "$indent`t<xr:MaxValue xsi:nil=`"true`"/>"
	Emit-MLText "$indent`t" "xr:ToolTip" $tt
	X "$indent`t<xr:ExtendedEdit>false</xr:ExtendedEdit>"
	Emit-MLText "$indent`t" "xr:Format" $fmt
	if ($cf) { X "$indent`t<xr:ChoiceForm>$(Esc-Xml "$cf")</xr:ChoiceForm>" } else { X "$indent`t<xr:ChoiceForm/>" }
	X "$indent`t<xr:QuickChoice>Auto</xr:QuickChoice>"
	X "$indent`t<xr:ChoiceHistoryOnInput>$chi</xr:ChoiceHistoryOnInput>"
	Emit-MLText "$indent`t" "xr:EditFormat" $efmt
	X "$indent`t<xr:PasswordMode>false</xr:PasswordMode>"
	X "$indent`t<xr:DataHistory>$dh</xr:DataHistory>"
	X "$indent`t<xr:MarkNegatives>false</xr:MarkNegatives>"
	X "$indent`t<xr:MinValue xsi:nil=`"true`"/>"
	Emit-MLText "$indent`t" "xr:Synonym" $syn
	if ($cmt) { X "$indent`t<xr:Comment>$(Esc-XmlText "$cmt")</xr:Comment>" } else { X "$indent`t<xr:Comment/>" }
	X "$indent`t<xr:FullTextSearch>$fts</xr:FullTextSearch>"
	Emit-ChoiceParameterLinks "$indent`t" (OvOr 'ChoiceParameterLinks' $null) 'xr:ChoiceParameterLinks'
	# FillValue: дефолт nil; override-значение → типизированное (Normalize-ChoiceValue: DTR-путь/строка/bool).
	$fvRaw = OvOr 'FillValue' $null
	if ($null -eq $fvRaw) { X "$indent`t<xr:FillValue xsi:nil=`"true`"/>" }
	else {
		$fvN = Normalize-ChoiceValue $fvRaw
		if ([string]::IsNullOrEmpty($fvN.Text)) { X "$indent`t<xr:FillValue xsi:type=`"$($fvN.XsiType)`"/>" }
		else { X "$indent`t<xr:FillValue xsi:type=`"$($fvN.XsiType)`">$(Esc-Xml $fvN.Text)</xr:FillValue>" }
	}
	if ($msk) { X "$indent`t<xr:Mask>$(Esc-XmlText "$msk")</xr:Mask>" } else { X "$indent`t<xr:Mask/>" }
	Emit-ChoiceParameters "$indent`t" (OvOr 'ChoiceParameters' $null) 'xr:ChoiceParameters'
	X "$indent</xr:StandardAttribute>"
}

# Единый эмиттер блока StandardAttributes — поведение правят ДАННЫЕ, не форк кода:
#  - stdAttrConditionalTypes: типы, где блок материализуется платформой ТОЛЬКО при кастомизации
#    ≥1 стандартного реквизита → в DSL это наличие ключа `standardAttributes`. Нет ключа → блок опущен.
#    Прочие типы (не в множестве) → блок эмитится всегда (текущее поведение, пока их правило не выведено).
#  - stdAttrProfile[тип]: профиль материализованного блока (пусто = schema-дефолт), поверх — DSL-override.
# Миграция типа = добавить его в stdAttrConditionalTypes + stdAttrProfile и переснять снэпшоты; КОД НЕ ТРОГАЕМ.
$script:stdAttrConditionalTypes = @('Catalog', 'ExchangePlan', 'ChartOfCharacteristicTypes')
function Emit-StandardAttributes {
	param([string]$indent, [string]$objectType)
	$attrs = $script:standardAttributesByType[$objectType]
	if (-not $attrs) { return }
	$conditional = $script:stdAttrConditionalTypes -contains $objectType
	$sa = $def.standardAttributes
	if ($conditional -and $null -eq $sa) { return }   # условный тип без кастомизации → блока нет
	$profile = $script:stdAttrProfile[$objectType]; if (-not $profile) { $profile = @{} }
	# Доп. (опциональные) стандартные реквизиты вне фикс-списка типа — напр. ExchangeDate у части ПланОбмена
	# (легаси, присутствие не выводится из свойств). Эмитим по факту наличия ключа в DSL, ПЕРЕД фикс-списком (их позиция).
	$extra = @()
	if ($sa) { foreach ($k in $sa.PSObject.Properties.Name) { if ($attrs -notcontains $k) { $extra += $k } } }
	X "$indent<StandardAttributes>"
	foreach ($a in ($extra + $attrs)) {
		$ov = @{}
		if ($profile.ContainsKey($a)) { foreach ($k in $profile[$a].Keys) { $ov[$k] = $profile[$a][$k] } }
		if ($sa) {   # DSL-override применяем всегда при наличии ключа (для не-условных типов тоже, напр. ExchangePlan)
			$d = $sa.$a
			if ($d) {
				if ($null -ne $d.synonym) { $ov['Synonym'] = $d.synonym }   # строка ИЛИ {ru,en}
				if ($null -ne $d.tooltip) { $ov['ToolTip'] = $d.tooltip }   # строка ИЛИ {ru,en}
				if ($d.fillChecking) { $ov['FillChecking'] = "$($d.fillChecking)" }
				if ($null -ne $d.fillFromFillingValue) { $ov['FillFromFillingValue'] = if ($d.fillFromFillingValue) { 'true' } else { 'false' } }
				if ($d.fullTextSearch) { $ov['FullTextSearch'] = "$($d.fullTextSearch)" }
				if ($d.dataHistory) { $ov['DataHistory'] = "$($d.dataHistory)" }
				if ($null -ne $d.fillValue) { $ov['FillValue'] = $d.fillValue }   # DTR-путь/строка/bool
				if ($null -ne $d.choiceParameterLinks) { $ov['ChoiceParameterLinks'] = $d.choiceParameterLinks }
				if ($null -ne $d.choiceParameters) { $ov['ChoiceParameters'] = $d.choiceParameters }
				if ($d.comment) { $ov['Comment'] = "$($d.comment)" }
				if ($d.mask) { $ov['Mask'] = "$($d.mask)" }
				if ($d.choiceForm) { $ov['ChoiceForm'] = "$($d.choiceForm)" }
			}
		}
		Emit-StandardAttribute "$indent`t" $a $ov
	}
	X "$indent</StandardAttributes>"
}

# TabularSection standard attributes (единственный — LineNumber/НомерСтроки). Блок эмитится всегда (платформа
# опускает его лишь у редкого хвоста ТЧ — правило не выведено, см. WORKFLOW). DSL `lineNumber` на объектной форме ТЧ
# переопределяет свойства (synonym/comment/fullTextSearch/tooltip/format/editFormat/choiceHistoryOnInput).
function Emit-TabularStandardAttributes {
	param([string]$indent, $lineNumber = $null)
	$ov = $null
	if ($lineNumber) {
		$ov = @{}
		if ($null -ne $lineNumber.synonym)            { $ov['Synonym'] = $lineNumber.synonym }
		if ($lineNumber.comment)                      { $ov['Comment'] = "$($lineNumber.comment)" }
		if ($lineNumber.fullTextSearch)               { $ov['FullTextSearch'] = "$($lineNumber.fullTextSearch)" }
		if ($null -ne $lineNumber.tooltip)            { $ov['ToolTip'] = $lineNumber.tooltip }
		if ($null -ne $lineNumber.format)             { $ov['Format'] = $lineNumber.format }
		if ($null -ne $lineNumber.editFormat)         { $ov['EditFormat'] = $lineNumber.editFormat }
		if ($lineNumber.choiceHistoryOnInput)         { $ov['ChoiceHistoryOnInput'] = "$($lineNumber.choiceHistoryOnInput)" }
	}
	X "$indent<StandardAttributes>"
	Emit-StandardAttribute "$indent`t" "LineNumber" $ov
	X "$indent</StandardAttributes>"
}

# --- 8. Attribute emitter ---

$script:reservedAttrNames = @{
	"Ref"="Ссылка"; "DeletionMark"="ПометкаУдаления"; "Code"="Код"; "Description"="Наименование"
	"Date"="Дата"; "Number"="Номер"; "Posted"="Проведен"; "Parent"="Родитель"; "Owner"="Владелец"
	"IsFolder"="ЭтоГруппа"; "Predefined"="Предопределенный"; "PredefinedDataName"="ИмяПредопределенныхДанных"
	"Recorder"="Регистратор"; "Period"="Период"; "LineNumber"="НомерСтроки"; "Active"="Активность"
	"Order"="Порядок"; "Type"="Тип"; "OffBalance"="Забалансовый"
	"Started"="Стартован"; "Completed"="Завершен"; "HeadTask"="ВедущаяЗадача"
	"Executed"="Выполнена"; "RoutePoint"="ТочкаМаршрута"; "BusinessProcess"="БизнесПроцесс"
	"ThisNode"="ЭтотУзел"; "SentNo"="НомерОтправленного"; "ReceivedNo"="НомерПринятого"
	"CalculationType"="ВидРасчета"; "RegistrationPeriod"="ПериодРегистрации"; "ReversingEntry"="СторноЗапись"
	"Account"="Счет"; "ValueType"="ТипЗначения"; "ActionPeriodIsBasic"="ПериодДействияБазовый"
}

# Стандартные реквизиты по типу объекта (ключи из reservedAttrNames). Имя реквизита, совпадающее
# с ними (англ. ИЛИ рус.), платформа не позволит — жёсткий отказ. Контексты вне карты → мягкое предупреждение.
$script:reservedByContext = @{
	"catalog"  = @("Ref","DeletionMark","Predefined","PredefinedDataName","Code","Description","Owner","Parent","IsFolder")
	"document" = @("Ref","DeletionMark","Date","Number","Posted")
}

# Стандартный реквизит текущего типа по имени (EN/RU) → EN-имя, либо $null (обычный/неизвестный).
function Resolve-StdAttrEn {
	param([string]$name)
	$ctx = switch ("$objType") { 'Catalog' { 'catalog' } 'Document' { 'document' } default { $null } }
	if (-not $ctx) { return $null }
	$stdSet = $script:reservedByContext[$ctx]
	foreach ($en in $stdSet) {
		$ru = $script:reservedAttrNames[$en]
		if (($name -ieq $en) -or ($ru -and $name -ieq $ru)) { return $en }
	}
	return $null
}

# Прощающий ввод пути к реквизиту САМОГО объекта (dataPath в linkByType/choiceParameterLinks):
#   "Ссылка"/"Ref"/станд. → <Тип>.<Имя>.StandardAttribute.<EN>;  обычное имя → <Тип>.<Имя>.Attribute.<Имя>;
#   частичное "StandardAttribute.X"/"Attribute.X" → префикс <Тип>.<Имя>;  полный путь → verbatim.
function Expand-DataPath {
	param([string]$dp)
	if (-not $dp) { return $dp }
	$s = "$dp"
	if ($s -match '[:/]') { return $s }   # спец-путь (напр. 0:GUID/0:GUID в зависимостях ПВХ) — не разворачиваем
	if ($s -match '^(StandardAttribute|Attribute)\.') { return "$objType.$objName.$s" }
	if (-not $s.Contains('.')) {
		$en = Resolve-StdAttrEn $s
		if ($en) { return "$objType.$objName.StandardAttribute.$en" }
		return "$objType.$objName.Attribute.$s"
	}
	return $s
}

# <LinkByType> (связь по типу — тип значения реквизита-Характеристики определяется другим реквизитом).
# Структура как <TypeLink> формы: DataPath + LinkItem. DSL `linkByType`: {dataPath, linkItem?} ИЛИ строка-путь.
# Нет ключа → <LinkByType/> (пусто).
function Emit-LinkByType {
	param([string]$indent, $spec)
	if (-not $spec) { X "$indent<LinkByType/>"; return }
	if ($spec -is [string]) { $dp = "$spec"; $li = 0 }
	else {
		$dp = if ($spec.dataPath) { "$($spec.dataPath)" } elseif ($spec.path) { "$($spec.path)" } elseif ($spec.путь) { "$($spec.путь)" } else { "" }
		$li = if ($null -ne $spec.linkItem) { $spec.linkItem } elseif ($null -ne $spec.элементСвязи) { $spec.элементСвязи } else { 0 }
	}
	if (-not $dp) { X "$indent<LinkByType/>"; return }
	$dp = Expand-DataPath $dp
	X "$indent<LinkByType>"
	X "$indent`t<xr:DataPath>$(Esc-Xml "$dp")</xr:DataPath>"
	X "$indent`t<xr:LinkItem>$li</xr:LinkItem>"
	X "$indent</LinkByType>"
}

# Есть ли ключ в $def (отличаем отсутствие от пустого массива [] = явно пусто).
function Test-DefKey { param([string]$name) return ($def.PSObject -and $def.PSObject.Properties -and ($def.PSObject.Properties.Name -contains $name)) }

# <Tag> со списком <xr:Field> (InputByString/DataLockFields). $fields — готовые полные пути. Пусто → self-close.
function Emit-FieldBlock {
	param([string]$indent, [string]$tag, $fields)
	$arr = @($fields | Where-Object { "$_" -ne '' })
	if ($arr.Count -eq 0) { X "$indent<$tag/>"; return }
	X "$indent<$tag>"
	foreach ($f in $arr) { X "$indent`t<xr:Field>$(Esc-Xml "$f")</xr:Field>" }
	X "$indent</$tag>"
}

# <BasedOn> — «ввод на основании», список MDObjectRef ("Catalog.X"/"Document.Y"). Нет ключа/пусто → self-close.
function Emit-BasedOn {
	param([string]$indent, $items)
	$arr = @($items | Where-Object { $_ })
	if ($arr.Count -eq 0) { X "$indent<BasedOn/>"; return }
	X "$indent<BasedOn>"
	foreach ($it in $arr) { X "$indent`t<xr:Item xsi:type=`"xr:MDObjectRef`">$(Esc-Xml "$it")</xr:Item>" }
	X "$indent</BasedOn>"
}

# --- Параметры/связи выбора (порт из form-compile; структура реквизита ⟷ элемента формы совпадает) ---

# Свойство из dict/PSCustomObject по списку синонимов (первый найденный, иначе $null).
function Get-ChElProp {
	param($obj, [string[]]$names)
	if ($null -eq $obj) { return $null }
	foreach ($n in $names) {
		if ($obj -is [System.Collections.IDictionary]) { if ($obj.Contains($n)) { return $obj[$n] } }
		elseif ($obj.PSObject -and $obj.PSObject.Properties[$n]) { return $obj.PSObject.Properties[$n].Value }
	}
	return $null
}

# Строковый литерал shorthand → скаляр: true/false→bool, целое/дробное→число, иначе строка.
function ConvertTo-ChScalar {
	param([string]$s)
	$t = "$s".Trim()
	if ($t -match '^(?i:true|истина)$')  { return $true }
	if ($t -match '^(?i:false|ложь)$') { return $false }
	if ($t -match '^-?\d+$')       { return [int]$t }
	if ($t -match '^-?\d+\.\d+$')  { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) }
	return $t
}

# Голое значение (без точки) + тип параметра → полный DTR-путь, либо $null. Принимает EnumRef.X / Enum.X / рус.
function Expand-ChoiceRefValue {
	param([string]$value, [string]$typeStr)
	if (-not $typeStr) { return $null }
	$t = Resolve-TypeStr $typeStr
	$root = $null; $tn = $null
	if ($t -match '^(\w+Ref)\.(.+)$') { $root = $script:fillRefKindRoot[$Matches[1].ToLower()]; $tn = $Matches[2] }
	elseif ($t -match '^([^.]+)\.(.+)$') { $root = $script:fillRefRoots[$Matches[1].ToLower()]; $tn = $Matches[2] }
	if (-not $root) { return $null }
	if ($script:fillEmptyRefWords -contains "$value".ToLower()) { return "$root.$tn.EmptyRef" }
	if ($root -eq 'Enum') { return "Enum.$tn.EnumValue.$value" }
	return "$root.$tn.$value"
}

# Значение параметра выбора → @{XsiType; Text}. $typeStr (тип параметра) разворачивает голые ref-имена.
function Normalize-ChoiceValueT {
	param($value, [string]$typeStr)
	if ($typeStr -and ($value -is [string]) -and (-not "$value".Contains('.'))) {
		$ex = Expand-ChoiceRefValue "$value" $typeStr
		if ($ex) { return @{ XsiType='xr:DesignTimeRef'; Text=$ex } }
	}
	return Normalize-ChoiceValue $value
}

# Значение параметра выбора → @{XsiType; Text}. Авто-детект по значению (без типа реквизита).
function Normalize-ChoiceValue {
	param($value)
	if ($value -is [bool]) { return @{ XsiType='xs:boolean'; Text=$(if ($value) { 'true' } else { 'false' }) } }
	if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
		return @{ XsiType='xs:decimal'; Text=(Format-FillNum $value) }
	}
	$s = "$value"
	if ($s -eq '') { return @{ XsiType='xs:string'; Text='' } }
	if ($s -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') { return @{ XsiType='xs:dateTime'; Text=$s } }
	$ref = Normalize-FillRef $s
	if ($ref) { return @{ XsiType='xr:DesignTimeRef'; Text=$ref } }
	return @{ XsiType='xs:string'; Text=$s }
}

# Shorthand "name=value" | "name=v1, v2" → {name, value}. "name=path" для links.
function ConvertFrom-ChParamShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$name = $s.Substring(0, $eq).Trim(); $rest = $s.Substring($eq + 1)
	if ($rest -match ',') {
		$vals = @(); foreach ($p in ($rest -split ',')) { $vals += ,(ConvertTo-ChScalar $p) }
		return @{ name = $name; value = $vals }
	}
	return @{ name = $name; value = (ConvertTo-ChScalar $rest) }
}
function ConvertFrom-ChLinkShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$o = @{ name = $s.Substring(0, $eq).Trim() }; $rest = $s.Substring($eq + 1).Trim()
	if ($rest -match '^(.*):(?i:(Clear|DontChange|очистить|неизменять))$') { $o['dataPath'] = $matches[1].Trim(); $o['valueChange'] = $matches[2] }
	else { $o['dataPath'] = $rest }
	return $o
}

# <ChoiceParameters> — [{name, value?}]. Значение ПРЯМО на app:value (xsi:type=тип); массив → v8:FixedArray
# с детьми v8:Value; без value → app:value nil.
function Emit-ChoiceParameters {
	param([string]$indent, $cp, [string]$tag = 'ChoiceParameters')
	if (-not $cp -or @($cp).Count -eq 0) { X "$indent<$tag/>"; return }
	X "$indent<$tag>"
	foreach ($item in @($cp)) {
		if ($item -is [string]) { $item = ConvertFrom-ChParamShorthand $item }
		$name = Get-ChElProp $item @('name','имя')
		$ptype = Get-ChElProp $item @('type','тип')
		$hasVal = $false; $val = $null
		if ($item -is [System.Collections.IDictionary]) {
			if ($item.Contains('value')) { $hasVal = $true; $val = $item['value'] }
			elseif ($item.Contains('значение')) { $hasVal = $true; $val = $item['значение'] }
		} elseif ($item.PSObject) {
			if ($item.PSObject.Properties['value']) { $hasVal = $true; $val = $item.PSObject.Properties['value'].Value }
			elseif ($item.PSObject.Properties['значение']) { $hasVal = $true; $val = $item.PSObject.Properties['значение'].Value }
		}
		$valIsArray = ($val -is [System.Array]) -or ($val -is [System.Collections.IList] -and $val -isnot [string])
		X "$indent`t<app:item name=`"$(Esc-Xml "$name")`">"
		if (-not $hasVal) {
			X "$indent`t`t<app:value xsi:nil=`"true`"/>"
		} elseif ($valIsArray) {
			X "$indent`t`t<app:value xsi:type=`"v8:FixedArray`">"
			foreach ($v in $val) {
				$norm = Normalize-ChoiceValueT $v $ptype
				if ([string]::IsNullOrEmpty($norm.Text)) { X "$indent`t`t`t<v8:Value xsi:type=`"$($norm.XsiType)`"/>" }
				else { X "$indent`t`t`t<v8:Value xsi:type=`"$($norm.XsiType)`">$(Esc-Xml $norm.Text)</v8:Value>" }
			}
			X "$indent`t`t</app:value>"
		} else {
			$norm = Normalize-ChoiceValueT $val $ptype
			if ([string]::IsNullOrEmpty($norm.Text)) { X "$indent`t`t<app:value xsi:type=`"$($norm.XsiType)`"/>" }
			else { X "$indent`t`t<app:value xsi:type=`"$($norm.XsiType)`">$(Esc-Xml $norm.Text)</app:value>" }
		}
		X "$indent`t</app:item>"
	}
	X "$indent</$tag>"
}

# <ChoiceParameterLinks> — [{name, dataPath, valueChange?}]. valueChange дефолт Clear.
function Emit-ChoiceParameterLinks {
	param([string]$indent, $cpl, [string]$tag = 'ChoiceParameterLinks')
	if (-not $cpl -or @($cpl).Count -eq 0) { X "$indent<$tag/>"; return }
	X "$indent<$tag>"
	foreach ($lk in @($cpl)) {
		if ($lk -is [string]) { $lk = ConvertFrom-ChLinkShorthand $lk }
		$name = Get-ChElProp $lk @('name','имя')
		$dp = Expand-DataPath (Get-ChElProp $lk @('dataPath','path','путь'))
		$vcRaw = Get-ChElProp $lk @('valueChange','режимИзменения')
		$vc = 'Clear'
		if ($vcRaw) {
			$vc = switch -Regex ("$vcRaw".ToLower()) {
				'^(clear|очистить|очистка)$'             { 'Clear'; break }
				'^(dontchange|неизменять|неменять|нет)$' { 'DontChange'; break }
				default                                  { "$vcRaw" }
			}
		}
		X "$indent`t<xr:Link>"
		X "$indent`t`t<xr:Name>$(Esc-Xml "$name")</xr:Name>"
		X "$indent`t`t<xr:DataPath xsi:type=`"xs:string`">$(Esc-Xml "$dp")</xr:DataPath>"
		X "$indent`t`t<xr:ValueChange>$vc</xr:ValueChange>"
		X "$indent`t</xr:Link>"
	}
	X "$indent</$tag>"
}

# --- Characteristics (привязка ПВХ «Дополнительные реквизиты и сведения») ---

# from: рус. корень (Справочник→Catalog) + член (ТабличнаяЧасть→TabularSection); короткая 3-сегментная
# "<Тип>.X.Y" → вставить TabularSection (from — всегда таблица, не реквизит). Полный путь → как есть.
function Normalize-CharFrom {
	param([string]$from)
	if (-not $from) { return $from }
	$parts = @("$from" -split '\.')
	if ($script:objectTypeSynonyms.ContainsKey($parts[0])) { $parts[0] = $script:objectTypeSynonyms[$parts[0]] }
	for ($i = 1; $i -lt $parts.Count; $i++) {
		switch -Regex ($parts[$i]) {
			'^ТабличнаяЧасть$' { $parts[$i] = 'TabularSection' }
			'^Измерение$'      { $parts[$i] = 'Dimension' }
			'^Ресурс$'         { $parts[$i] = 'Resource' }
			'^Реквизит$'       { $parts[$i] = 'Attribute' }
		}
	}
	if ($parts.Count -eq 3 -and $parts[0] -in @('Catalog','Document','ChartOfCharacteristicTypes','ChartOfCalculationTypes','ChartOfAccounts','ExchangePlan','BusinessProcess','Task')) {
		$parts = @($parts[0], $parts[1], 'TabularSection', $parts[2])
	}
	return ($parts -join '.')
}

# Стандартный реквизит ссылочного типа в полях Characteristics: Ref/Parent/Owner (по имени EN/RU).
# Прочие стандартные реквизиты редки в полях — их задают частичной формой StandardAttribute.X.
function Resolve-CharStdEn {
	param([string]$name)
	$n = "$name".ToLower()
	if ($n -eq 'ref' -or $n -eq 'ссылка') { return 'Ref' }
	if ($n -eq 'parent' -or $n -eq 'родитель') { return 'Parent' }
	if ($n -eq 'owner' -or $n -eq 'владелец') { return 'Owner' }
	return $null
}

# Поле: голое→StandardAttribute.<EN>/Attribute.<имя>; частичное Member.X→<from>.Member.X; полный путь→verbatim.
function Expand-CharField {
	param([string]$field, [string]$from)
	$s = "$field"
	if (-not $s) { return $s }
	if ($s -eq '-1') { return '-1' }   # поле не задано (empty-характеристика) — как есть
	if ($s -match '^(StandardAttribute|Attribute|Dimension|Resource)\.') { return "$from.$s" }
	if (-not $s.Contains('.')) {
		$en = Resolve-CharStdEn $s
		if ($en) { return "$from.StandardAttribute.$en" }
		return "$from.Attribute.$s"
	}
	return $s
}

# Числовое поле-флаг Characteristics (DataPathField/MultipleValues*) — дефолт -1.
function Get-CharIntField { param($obj, [string[]]$names) $v = Get-ChElProp $obj $names; if ($null -eq $v -or "$v" -eq '') { return -1 } return [int]$v }

function Emit-Characteristics {
	param([string]$indent, $chars)
	if (-not $chars -or @($chars).Count -eq 0) { X "$indent<Characteristics/>"; return }
	X "$indent<Characteristics>"
	foreach ($ch in @($chars)) {
		$types  = Get-ChElProp $ch @('types','characteristicTypes','типы')
		$values = Get-ChElProp $ch @('values','characteristicValues','значения')
		$tFrom = Normalize-CharFrom "$(Get-ChElProp $types @('from','source','источник'))"
		$vFrom = Normalize-CharFrom "$(Get-ChElProp $values @('from','source','источник'))"
		$key = Expand-CharField "$(Get-ChElProp $types @('key','keyField'))" $tFrom
		$tff = Expand-CharField "$(Get-ChElProp $types @('filterField','typesFilterField'))" $tFrom
		$obj = Expand-CharField "$(Get-ChElProp $values @('object','objectField'))" $vFrom
		$typ = Expand-CharField "$(Get-ChElProp $values @('type','typeField'))" $vFrom
		$val = Expand-CharField "$(Get-ChElProp $values @('value','valueField'))" $vFrom
		# числовые поля-флаги (обычно -1; иногда 0)
		$dpf = Get-CharIntField $types @('dataPathField')
		$mvu = Get-CharIntField $types @('multipleValuesUseField')
		$mvk = Get-CharIntField $values @('multipleValuesKeyField')
		$mvo = Get-CharIntField $values @('multipleValuesOrderField')
		X "$indent`t<xr:Characteristic>"
		X "$indent`t`t<xr:CharacteristicTypes from=`"$(Esc-Xml $tFrom)`">"
		X "$indent`t`t`t<xr:KeyField>$(Esc-Xml $key)</xr:KeyField>"
		X "$indent`t`t`t<xr:TypesFilterField>$(Esc-Xml $tff)</xr:TypesFilterField>"
		# filterValue: $null→nil; голое→xs:string, полный путь→DTR, bool→xs:boolean.
		$tfvRaw = Get-ChElProp $types @('filterValue','typesFilterValue')
		if ($null -eq $tfvRaw) { X "$indent`t`t`t<xr:TypesFilterValue xsi:nil=`"true`"/>" }
		else {
			$tfvN = Normalize-ChoiceValue $tfvRaw
			if ([string]::IsNullOrEmpty($tfvN.Text)) { X "$indent`t`t`t<xr:TypesFilterValue xsi:type=`"$($tfvN.XsiType)`"/>" }
			else { X "$indent`t`t`t<xr:TypesFilterValue xsi:type=`"$($tfvN.XsiType)`">$(Esc-Xml $tfvN.Text)</xr:TypesFilterValue>" }
		}
		X "$indent`t`t`t<xr:DataPathField>$dpf</xr:DataPathField>"
		X "$indent`t`t`t<xr:MultipleValuesUseField>$mvu</xr:MultipleValuesUseField>"
		X "$indent`t`t</xr:CharacteristicTypes>"
		X "$indent`t`t<xr:CharacteristicValues from=`"$(Esc-Xml $vFrom)`">"
		X "$indent`t`t`t<xr:ObjectField>$(Esc-Xml $obj)</xr:ObjectField>"
		X "$indent`t`t`t<xr:TypeField>$(Esc-Xml $typ)</xr:TypeField>"
		X "$indent`t`t`t<xr:ValueField>$(Esc-Xml $val)</xr:ValueField>"
		X "$indent`t`t`t<xr:MultipleValuesKeyField>$mvk</xr:MultipleValuesKeyField>"
		X "$indent`t`t`t<xr:MultipleValuesOrderField>$mvo</xr:MultipleValuesOrderField>"
		X "$indent`t`t</xr:CharacteristicValues>"
		X "$indent`t</xr:Characteristic>"
	}
	X "$indent</Characteristics>"
}

# <MinValue>/<MaxValue> — граница диапазона реквизита. Нет ключа → nil (не задано). Значение типизировано
# (зеркало form-compile): число → xs:decimal, строка → xs:string (тип сохранён декомпилятором).
function Emit-MinMaxValue {
	param([string]$indent, [string]$tag, $val)
	if ($null -eq $val) { X "$indent<$tag xsi:nil=`"true`"/>"; return }
	$t = if ($val -is [string]) { 'xs:string' } else { 'xs:decimal' }
	X "$indent<$tag xsi:type=`"$t`">$(Esc-Xml "$val")</$tag>"
}

function Emit-Attribute {
	param([string]$indent, $parsed, [string]$context)
	# $context: "catalog", "document", "object", "processor", "tabular", "processor-tabular", "register"
	$attrName = $parsed.name
	$ctxReserved = $script:reservedByContext[$context]
	if ($ctxReserved) {
		foreach ($en in $ctxReserved) {
			$ru = $script:reservedAttrNames[$en]
			if (($attrName -ieq $en) -or ($ru -and $attrName -ieq $ru)) {
				Write-Error "Имя реквизита '$attrName' зарезервировано стандартным реквизитом ($en/$ru) объекта '$context'. Выберите другое имя."
				exit 1
			}
		}
	} elseif ($context -notin @("tabular", "processor-tabular") -and
		($script:reservedAttrNames.ContainsKey($attrName) -or $script:reservedAttrNames.ContainsValue($attrName))) {
		Write-Warning "Attribute '$attrName' conflicts with a standard attribute name. This may cause errors when loading into 1C."
	}
	$uuid = New-Guid-String
	X "$indent<Attribute uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $parsed.synonym
	if ($parsed.comment) { X "$indent`t`t<Comment>$(Esc-XmlText $parsed.comment)</Comment>" } else { X "$indent`t`t<Comment/>" }

	# Type
	$typeStr = $parsed.type
	if ($typeStr) {
		Emit-ValueType "$indent`t`t" $typeStr
	} else {
		# Default: unqualified string
		X "$indent`t`t<Type>"
		X "$indent`t`t`t<v8:Type>xs:string</v8:Type>"
		X "$indent`t`t</Type>"
	}

	$pwMode = if ($parsed.passwordMode -eq $true) { "true" } else { "false" }
	X "$indent`t`t<PasswordMode>$pwMode</PasswordMode>"
	Emit-MLText "$indent`t`t" "Format" $parsed.format
	Emit-MLText "$indent`t`t" "EditFormat" $parsed.editFormat
	Emit-MLText "$indent`t`t" "ToolTip" $parsed.tooltip
	X "$indent`t`t<MarkNegatives>false</MarkNegatives>"
	if ($parsed.mask) { X "$indent`t`t<Mask>$(Esc-XmlText $parsed.mask)</Mask>" } else { X "$indent`t`t<Mask/>" }
	$multiLine = if ($parsed.multiLine -eq $true -or $parsed.flags -contains "multiline") { "true" } else { "false" }
	X "$indent`t`t<MultiLine>$multiLine</MultiLine>"
	$extEdit = if ($parsed.extendedEdit -eq $true) { "true" } else { "false" }
	X "$indent`t`t<ExtendedEdit>$extEdit</ExtendedEdit>"
	Emit-MinMaxValue "$indent`t`t" "MinValue" $parsed.minValue
	Emit-MinMaxValue "$indent`t`t" "MaxValue" $parsed.maxValue

	# FillFromFillingValue — not for tabular/processor/chart/register-other
	# (Chart*, AccumulationRegister/AccountingRegister/CalculationRegister don't support these)
	if ($context -notin @("tabular", "processor", "chart", "register-other")) {
		$ffv = if ($parsed.fillFromFillingValue -eq $true) { "true" } else { "false" }
		X "$indent`t`t<FillFromFillingValue>$ffv</FillFromFillingValue>"
	}

	# FillValue — same restriction
	if ($context -notin @("tabular", "processor", "chart", "register-other")) {
		Emit-FillValue "$indent`t`t" $typeStr $parsed.fillValue $parsed.hasFillValue
	}

	# FillChecking
	$fillChecking = "DontCheck"
	if ($parsed.flags -contains "req") { $fillChecking = "ShowError" }
	if ($parsed.fillChecking) { $fillChecking = $parsed.fillChecking }
	X "$indent`t`t<FillChecking>$fillChecking</FillChecking>"

	X "$indent`t`t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>"
	Emit-ChoiceParameterLinks "$indent`t`t" $parsed.choiceParameterLinks
	Emit-ChoiceParameters "$indent`t`t" $parsed.choiceParameters
	$qc = if ($parsed.quickChoice) { $parsed.quickChoice } else { "Auto" }
	X "$indent`t`t<QuickChoice>$qc</QuickChoice>"
	$coi = if ($parsed.createOnInput) { $parsed.createOnInput } else { "Auto" }
	X "$indent`t`t<CreateOnInput>$coi</CreateOnInput>"
	X "$indent`t`t<ChoiceForm/>"
	Emit-LinkByType "$indent`t`t" $parsed.linkByType
	$chi = if ($parsed.choiceHistoryOnInput) { $parsed.choiceHistoryOnInput } else { "Auto" }
	X "$indent`t`t<ChoiceHistoryOnInput>$chi</ChoiceHistoryOnInput>"

	# Use — only for catalog top-level attributes
	if ($context -eq "catalog") {
		$use = if ($parsed.use) { $parsed.use } else { "ForItem" }
		X "$indent`t`t<Use>$use</Use>"
	}

	# Indexing/FullTextSearch/DataHistory — not for non-stored objects (processor, processor-tabular)
	if ($context -notin @("processor", "processor-tabular")) {
		$indexing = "DontIndex"
		if ($parsed.flags -contains "index") { $indexing = "Index" }
		if ($parsed.flags -contains "indexadditional") { $indexing = "IndexWithAdditionalOrder" }
		if ($parsed.indexing) { $indexing = $parsed.indexing }
		X "$indent`t`t<Indexing>$indexing</Indexing>"

		$fts = if ($parsed.fullTextSearch) { $parsed.fullTextSearch } else { "Use" }
		X "$indent`t`t<FullTextSearch>$fts</FullTextSearch>"
		# DataHistory — not for Chart* types and non-InformationRegister register family
		if ($context -notin @("chart", "register-other")) {
			$dh = if ($parsed.dataHistory) { $parsed.dataHistory } else { "Use" }
			X "$indent`t`t<DataHistory>$dh</DataHistory>"
		}
	}

	X "$indent`t</Properties>"
	X "$indent</Attribute>"
}

# <Picture> команды — структурный блок (зеркало form-compile). Дефолт LoadTransparent=true (конвенция
# кнопки/команды): фиксируем только false. Значение: строка-ref + sibling `loadTransparent` ЛИБО объект
# {src, loadTransparent?, transparentPixel?}. src с префиксом "abs:" → <xr:Abs>, иначе <xr:Ref>. Нет → <Picture/>.
function Emit-CommandPicture {
	param([string]$indent, $cmd)
	$pic = $cmd.picture
	if (-not $pic) { X "$indent<Picture/>"; return }
	$src = $null; $lt = $true; $tpx = $null
	if ($pic -is [string]) { $src = "$pic"; if ($cmd.loadTransparent -eq $false) { $lt = $false } }
	else {
		$src = if ($pic.src) { "$($pic.src)" } elseif ($pic.ref) { "$($pic.ref)" } else { "" }
		if ($pic.loadTransparent -eq $false) { $lt = $false }
		$tpx = $pic.transparentPixel
	}
	if (-not $src) { X "$indent<Picture/>"; return }
	X "$indent<Picture>"
	if ($src -match '^abs:(.*)$') { X "$indent`t<xr:Abs>$(Esc-Xml $matches[1])</xr:Abs>" }
	else { X "$indent`t<xr:Ref>$(Esc-Xml $src)</xr:Ref>" }
	X "$indent`t<xr:LoadTransparent>$(if ($lt) { 'true' } else { 'false' })</xr:LoadTransparent>"
	if ($tpx) { X "$indent`t<xr:TransparentPixel x=`"$($tpx.x)`" y=`"$($tpx.y)`"/>" }
	X "$indent</Picture>"
}

# --- 8b. Command emitter ---
# $cmd — объект свойств команды. Поля (omit-on-default): synonym/tooltip (ML), comment, group,
# commandParameterType (тип), parameterUseMode (Single), modifiesData (false), representation (Auto),
# picture, shortcut, onMainServerUnavalableBehavior (Auto).
function Emit-Command {
	param([string]$indent, [string]$cmdName, $cmd)
	X "$indent<Command uuid=`"$(New-Guid-String)`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $cmdName)</Name>"
	$syn = if ($null -ne $cmd.synonym) { $cmd.synonym } else { Split-CamelCase $cmdName }
	Emit-MLText "$indent`t`t" "Synonym" $syn
	if ($cmd.comment) { X "$indent`t`t<Comment>$(Esc-XmlText "$($cmd.comment)")</Comment>" } else { X "$indent`t`t<Comment/>" }
	$group = if ($cmd.group) { "$($cmd.group)" } else { "" }
	X "$indent`t`t<Group>$group</Group>"
	if ($cmd.commandParameterType) {
		X "$indent`t`t<CommandParameterType>"
		Emit-TypeContent "$indent`t`t`t" "$($cmd.commandParameterType)"
		X "$indent`t`t</CommandParameterType>"
	} else {
		X "$indent`t`t<CommandParameterType/>"
	}
	$pum = if ($cmd.parameterUseMode) { "$($cmd.parameterUseMode)" } else { "Single" }
	X "$indent`t`t<ParameterUseMode>$pum</ParameterUseMode>"
	$md = if ($cmd.modifiesData -eq $true) { "true" } else { "false" }
	X "$indent`t`t<ModifiesData>$md</ModifiesData>"
	$rep = if ($cmd.representation) { "$($cmd.representation)" } else { "Auto" }
	X "$indent`t`t<Representation>$rep</Representation>"
	Emit-MLText "$indent`t`t" "ToolTip" $cmd.tooltip
	Emit-CommandPicture "$indent`t`t" $cmd
	if ($cmd.shortcut) { X "$indent`t`t<Shortcut>$(Esc-Xml "$($cmd.shortcut)")</Shortcut>" } else { X "$indent`t`t<Shortcut/>" }
	$osu = if ($cmd.onMainServerUnavalableBehavior) { "$($cmd.onMainServerUnavalableBehavior)" } else { "Auto" }
	X "$indent`t`t<OnMainServerUnavalableBehavior>$osu</OnMainServerUnavalableBehavior>"
	X "$indent`t</Properties>"
	X "$indent</Command>"
}

# --- 9. TabularSection emitter ---

function Emit-TabularSection {
	param([string]$indent, [string]$tsName, $columns, [string]$objectType, [string]$objectName, $tsSynonymArg = $null, $tsTooltip = $null, $tsComment = $null, $tsLineNumber = $null)
	$uuid = New-Guid-String
	X "$indent<TabularSection uuid=`"$uuid`">"

	# InternalInfo for TabularSection
	$typePrefix = "${objectType}TabularSection"
	$rowPrefix = "${objectType}TabularSectionRow"

	X "$indent`t<InternalInfo>"
	X "$indent`t`t<xr:GeneratedType name=`"$typePrefix.$objectName.$tsName`" category=`"TabularSection`">"
	X "$indent`t`t`t<xr:TypeId>$(New-Guid-String)</xr:TypeId>"
	X "$indent`t`t`t<xr:ValueId>$(New-Guid-String)</xr:ValueId>"
	X "$indent`t`t</xr:GeneratedType>"
	X "$indent`t`t<xr:GeneratedType name=`"$rowPrefix.$objectName.$tsName`" category=`"TabularSectionRow`">"
	X "$indent`t`t`t<xr:TypeId>$(New-Guid-String)</xr:TypeId>"
	X "$indent`t`t`t<xr:ValueId>$(New-Guid-String)</xr:ValueId>"
	X "$indent`t`t</xr:GeneratedType>"
	X "$indent`t</InternalInfo>"

	$tsSynonym = if ($null -ne $tsSynonymArg) { $tsSynonymArg } else { Split-CamelCase $tsName }

	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $tsName)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $tsSynonym
	if ($tsComment) { X "$indent`t`t<Comment>$(Esc-XmlText $tsComment)</Comment>" } else { X "$indent`t`t<Comment/>" }
	Emit-MLText "$indent`t`t" "ToolTip" $tsTooltip
	X "$indent`t`t<FillChecking>DontCheck</FillChecking>"
	Emit-TabularStandardAttributes "$indent`t`t" $tsLineNumber
	# Use=ForItem у ТЧ иерархических ссылочных типов (Catalog, ChartOfCharacteristicTypes); Document не имеет Use.
	if ($objectType -in @("Catalog", "ChartOfCharacteristicTypes")) {
		X "$indent`t`t<Use>ForItem</Use>"
	}
	X "$indent`t</Properties>"

	$tsContext = if ($objectType -in @("DataProcessor","Report")) { "processor-tabular" } else { "tabular" }
	X "$indent`t<ChildObjects>"
	foreach ($col in $columns) {
		$parsed = Parse-AttributeShorthand $col
		Emit-Attribute "$indent`t`t" $parsed $tsContext
	}
	X "$indent`t</ChildObjects>"

	X "$indent</TabularSection>"
}

# --- 10. EnumValue emitter ---

function Emit-EnumValue {
	param([string]$indent, $parsed)
	$uuid = New-Guid-String
	X "$indent<EnumValue uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $parsed.synonym
	X "$indent`t`t<Comment/>"
	X "$indent`t</Properties>"
	X "$indent</EnumValue>"
}

# --- 11. Dimension emitter ---

function Emit-Dimension {
	param([string]$indent, $parsed, [string]$registerType)
	# $registerType: "InformationRegister" or "AccumulationRegister"
	$uuid = New-Guid-String
	X "$indent<Dimension uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $parsed.synonym
	X "$indent`t`t<Comment/>"

	$typeStr = $parsed.type
	if ($typeStr) {
		Emit-ValueType "$indent`t`t" $typeStr
	} else {
		X "$indent`t`t<Type>"
		X "$indent`t`t`t<v8:Type>xs:string</v8:Type>"
		X "$indent`t`t</Type>"
	}

	X "$indent`t`t<PasswordMode>false</PasswordMode>"
	X "$indent`t`t<Format/>"
	X "$indent`t`t<EditFormat/>"
	X "$indent`t`t<ToolTip/>"
	X "$indent`t`t<MarkNegatives>false</MarkNegatives>"
	X "$indent`t`t<Mask/>"
	$multiLine = if ($parsed.multiLine -eq $true -or $parsed.flags -contains "multiline") { "true" } else { "false" }
	X "$indent`t`t<MultiLine>$multiLine</MultiLine>"
	$extEdit = if ($parsed.extendedEdit -eq $true) { "true" } else { "false" }
	X "$indent`t`t<ExtendedEdit>$extEdit</ExtendedEdit>"
	Emit-MinMaxValue "$indent`t`t" "MinValue" $parsed.minValue
	Emit-MinMaxValue "$indent`t`t" "MaxValue" $parsed.maxValue

	# InformationRegister dimensions have FillFromFillingValue
	if ($registerType -eq "InformationRegister") {
		$fillFrom = if ($parsed.flags -contains "master") { "true" } else { "false" }
		X "$indent`t`t<FillFromFillingValue>$fillFrom</FillFromFillingValue>"
		X "$indent`t`t<FillValue xsi:nil=`"true`"/>"
	}

	$fillChecking = "DontCheck"
	if ($parsed.flags -contains "req") { $fillChecking = "ShowError" }
	X "$indent`t`t<FillChecking>$fillChecking</FillChecking>"

	X "$indent`t`t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>"
	X "$indent`t`t<ChoiceParameterLinks/>"
	X "$indent`t`t<ChoiceParameters/>"
	X "$indent`t`t<QuickChoice>Auto</QuickChoice>"
	X "$indent`t`t<CreateOnInput>Auto</CreateOnInput>"
	X "$indent`t`t<ChoiceForm/>"
	X "$indent`t`t<LinkByType/>"
	X "$indent`t`t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"

	# InformationRegister dimensions: Master, MainFilter, DenyIncompleteValues
	if ($registerType -eq "InformationRegister") {
		$master = if ($parsed.flags -contains "master") { "true" } else { "false" }
		$mainFilter = if ($parsed.flags -contains "mainfilter") { "true" } else { "false" }
		$denyIncomplete = if ($parsed.flags -contains "denyincomplete") { "true" } else { "false" }
		X "$indent`t`t<Master>$master</Master>"
		X "$indent`t`t<MainFilter>$mainFilter</MainFilter>"
		X "$indent`t`t<DenyIncompleteValues>$denyIncomplete</DenyIncompleteValues>"
	}

	# AccumulationRegister dimensions: DenyIncompleteValues
	if ($registerType -eq "AccumulationRegister") {
		$denyIncomplete = if ($parsed.flags -contains "denyincomplete") { "true" } else { "false" }
		X "$indent`t`t<DenyIncompleteValues>$denyIncomplete</DenyIncompleteValues>"
	}

	$indexing = "DontIndex"
	if ($parsed.flags -contains "index") { $indexing = "Index" }
	X "$indent`t`t<Indexing>$indexing</Indexing>"

	X "$indent`t`t<FullTextSearch>Use</FullTextSearch>"

	# AccumulationRegister dimensions: UseInTotals
	if ($registerType -eq "AccumulationRegister") {
		$useInTotals = if ($parsed.flags -contains "nouseintotals") { "false" } else { "true" }
		X "$indent`t`t<UseInTotals>$useInTotals</UseInTotals>"
	}

	# InformationRegister dimensions: DataHistory
	if ($registerType -eq "InformationRegister") {
		X "$indent`t`t<DataHistory>Use</DataHistory>"
	}

	X "$indent`t</Properties>"
	X "$indent</Dimension>"
}

# --- 12. Resource emitter ---

function Emit-Resource {
	param([string]$indent, $parsed, [string]$registerType)
	$uuid = New-Guid-String
	X "$indent<Resource uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $parsed.synonym
	X "$indent`t`t<Comment/>"

	$typeStr = $parsed.type
	if ($typeStr) {
		Emit-ValueType "$indent`t`t" $typeStr
	} else {
		X "$indent`t`t<Type>"
		X "$indent`t`t`t<v8:Type>xs:decimal</v8:Type>"
		X "$indent`t`t`t<v8:NumberQualifiers>"
		X "$indent`t`t`t`t<v8:Digits>15</v8:Digits>"
		X "$indent`t`t`t`t<v8:FractionDigits>2</v8:FractionDigits>"
		X "$indent`t`t`t`t<v8:AllowedSign>Any</v8:AllowedSign>"
		X "$indent`t`t`t</v8:NumberQualifiers>"
		X "$indent`t`t</Type>"
	}

	X "$indent`t`t<PasswordMode>false</PasswordMode>"
	X "$indent`t`t<Format/>"
	X "$indent`t`t<EditFormat/>"
	X "$indent`t`t<ToolTip/>"
	X "$indent`t`t<MarkNegatives>false</MarkNegatives>"
	X "$indent`t`t<Mask/>"
	$multiLine = if ($parsed.multiLine -eq $true -or $parsed.flags -contains "multiline") { "true" } else { "false" }
	X "$indent`t`t<MultiLine>$multiLine</MultiLine>"
	$extEdit = if ($parsed.extendedEdit -eq $true) { "true" } else { "false" }
	X "$indent`t`t<ExtendedEdit>$extEdit</ExtendedEdit>"
	Emit-MinMaxValue "$indent`t`t" "MinValue" $parsed.minValue
	Emit-MinMaxValue "$indent`t`t" "MaxValue" $parsed.maxValue

	# InformationRegister resources have FillFromFillingValue, FillValue
	if ($registerType -eq "InformationRegister") {
		X "$indent`t`t<FillFromFillingValue>false</FillFromFillingValue>"
		X "$indent`t`t<FillValue xsi:nil=`"true`"/>"
	}

	$fillChecking = "DontCheck"
	if ($parsed.flags -contains "req") { $fillChecking = "ShowError" }
	X "$indent`t`t<FillChecking>$fillChecking</FillChecking>"

	X "$indent`t`t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>"
	X "$indent`t`t<ChoiceParameterLinks/>"
	X "$indent`t`t<ChoiceParameters/>"
	X "$indent`t`t<QuickChoice>Auto</QuickChoice>"
	X "$indent`t`t<CreateOnInput>Auto</CreateOnInput>"
	X "$indent`t`t<ChoiceForm/>"
	X "$indent`t`t<LinkByType/>"
	X "$indent`t`t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"

	# InformationRegister resources: Indexing, FullTextSearch, DataHistory
	if ($registerType -eq "InformationRegister") {
		X "$indent`t`t<Indexing>DontIndex</Indexing>"
		X "$indent`t`t<FullTextSearch>Use</FullTextSearch>"
		X "$indent`t`t<DataHistory>Use</DataHistory>"
	}

	# AccumulationRegister resources: FullTextSearch (no Indexing, no DataHistory)
	if ($registerType -eq "AccumulationRegister") {
		X "$indent`t`t<FullTextSearch>Use</FullTextSearch>"
	}

	X "$indent`t</Properties>"
	X "$indent</Resource>"
}

# --- 13. Property emitters per type ---

function Emit-CatalogProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	if ($def.comment) { X "$i<Comment>$(Esc-XmlText $def.comment)</Comment>" } else { X "$i<Comment/>" }

	$hierarchical = if ($def.hierarchical -eq $true) { "true" } else { "false" }
	$hierarchyType = Get-EnumProp "HierarchyType" "hierarchyType" "HierarchyFoldersAndItems"
	X "$i<Hierarchical>$hierarchical</Hierarchical>"
	X "$i<HierarchyType>$hierarchyType</HierarchyType>"
	$limitLevelCount = if ($def.limitLevelCount -eq $true) { "true" } else { "false" }
	$levelCount = if ($null -ne $def.levelCount) { "$($def.levelCount)" } else { "2" }
	$foldersOnTop = if ($def.foldersOnTop -eq $false) { "false" } else { "true" }
	X "$i<LimitLevelCount>$limitLevelCount</LimitLevelCount>"
	X "$i<LevelCount>$levelCount</LevelCount>"
	X "$i<FoldersOnTop>$foldersOnTop</FoldersOnTop>"
	$useStdCmds = if (Get-BoolProp "useStandardCommands" $true) { "true" } else { "false" }
	X "$i<UseStandardCommands>$useStdCmds</UseStandardCommands>"
	if ($def.owners -and $def.owners.Count -gt 0) {
		X "$i<Owners>"
		foreach ($ownerRef in $def.owners) {
			$fullRef = if ("$ownerRef" -match '\.') { "$ownerRef" } else { "Catalog.$ownerRef" }
			X "$i`t<xr:Item xsi:type=`"xr:MDObjectRef`">$fullRef</xr:Item>"
		}
		X "$i</Owners>"
	} else {
		X "$i<Owners/>"
	}
	$subordinationUse = Get-EnumProp "SubordinationUse" "subordinationUse" "ToItems"
	X "$i<SubordinationUse>$subordinationUse</SubordinationUse>"

	$codeLength = if ($null -ne $def.codeLength) { "$($def.codeLength)" } else { "9" }
	$descriptionLength = if ($null -ne $def.descriptionLength) { "$($def.descriptionLength)" } else { "25" }
	$codeType = Get-EnumProp "CodeType" "codeType" "String"
	$codeAllowedLength = Get-EnumProp "CodeAllowedLength" "codeAllowedLength" "Variable"
	$autonumbering = if ($def.autonumbering -eq $false) { "false" } else { "true" }
	$checkUnique = if ($def.checkUnique -eq $true) { "true" } else { "false" }

	X "$i<CodeLength>$codeLength</CodeLength>"
	X "$i<DescriptionLength>$descriptionLength</DescriptionLength>"
	X "$i<CodeType>$codeType</CodeType>"
	X "$i<CodeAllowedLength>$codeAllowedLength</CodeAllowedLength>"
	$codeSeries = Get-EnumProp "CodeSeries" "codeSeries" "WholeCatalog"
	X "$i<CodeSeries>$codeSeries</CodeSeries>"
	X "$i<CheckUnique>$checkUnique</CheckUnique>"
	X "$i<Autonumbering>$autonumbering</Autonumbering>"

	$defaultPresentation = Get-EnumProp "DefaultPresentation" "defaultPresentation" "AsDescription"
	X "$i<DefaultPresentation>$defaultPresentation</DefaultPresentation>"

	Emit-StandardAttributes $i "Catalog"
	Emit-Characteristics $i $def.characteristics
	X "$i<PredefinedDataUpdate>$(Get-EnumProp 'PredefinedDataUpdate' 'predefinedDataUpdate' 'Auto')</PredefinedDataUpdate>"
	X "$i<EditType>$(Get-EnumProp 'EditType' 'editType' 'InDialog')</EditType>"
	$quickChoice = if ($def.quickChoice -eq $true) { "true" } else { "false" }
	$choiceMode = Get-EnumProp "ChoiceMode" "choiceMode" "BothWays"
	X "$i<QuickChoice>$quickChoice</QuickChoice>"
	X "$i<ChoiceMode>$choiceMode</ChoiceMode>"
	# InputByString: override `inputByString` (массив имён, авто-резолв; [] = пусто) ЛИБО дефолт [Descr при D>0]+[Code при C>0].
	if (Test-DefKey 'inputByString') {
		$ibFields = @($def.inputByString | ForEach-Object { Expand-DataPath "$_" })
	} else {
		$ibFields = @()
		if ([int]$descriptionLength -gt 0) { $ibFields += "Catalog.$objName.StandardAttribute.Description" }
		if ([int]$codeLength -gt 0)        { $ibFields += "Catalog.$objName.StandardAttribute.Code" }
	}
	Emit-FieldBlock $i "InputByString" $ibFields
	X "$i<SearchStringModeOnInputByString>$(Get-EnumProp 'SearchStringModeOnInputByString' 'searchStringModeOnInputByString' 'Begin')</SearchStringModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	Emit-FormRef $i "DefaultObjectForm"       $def.defaultObjectForm
	Emit-FormRef $i "DefaultFolderForm"       $def.defaultFolderForm
	Emit-FormRef $i "DefaultListForm"         $def.defaultListForm
	Emit-FormRef $i "DefaultChoiceForm"       $def.defaultChoiceForm
	Emit-FormRef $i "DefaultFolderChoiceForm" $def.defaultFolderChoiceForm
	Emit-FormRef $i "AuxiliaryObjectForm"       $def.auxiliaryObjectForm
	Emit-FormRef $i "AuxiliaryFolderForm"       $def.auxiliaryFolderForm
	Emit-FormRef $i "AuxiliaryListForm"         $def.auxiliaryListForm
	Emit-FormRef $i "AuxiliaryChoiceForm"       $def.auxiliaryChoiceForm
	Emit-FormRef $i "AuxiliaryFolderChoiceForm" $def.auxiliaryFolderChoiceForm
	$inclHelp = if (Get-BoolProp "includeHelpInContents" $false) { "true" } else { "false" }
	X "$i<IncludeHelpInContents>$inclHelp</IncludeHelpInContents>"
	Emit-BasedOn $i $def.basedOn
	$dlFields = if (Test-DefKey 'dataLockFields') { @($def.dataLockFields | ForEach-Object { Expand-DataPath "$_" }) } else { @() }
	Emit-FieldBlock $i "DataLockFields" $dlFields

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<CreateOnInput>$(Get-EnumProp 'CreateOnInput' 'createOnInput' 'Use')</CreateOnInput>"
	X "$i<ChoiceHistoryOnInput>$(Get-EnumProp 'ChoiceHistoryOnInput' 'choiceHistoryOnInput' 'Auto')</ChoiceHistoryOnInput>"
	X "$i<DataHistory>DontUse</DataHistory>"
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>"
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-DocumentProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"
	X "$i<Numerator/>"

	$numberType = Get-EnumProp "NumberType" "numberType" "String"
	$numberLength = if ($null -ne $def.numberLength) { "$($def.numberLength)" } else { "11" }
	$numberAllowedLength = Get-EnumProp "NumberAllowedLength" "numberAllowedLength" "Variable"
	$numberPeriodicity = if ($def.numberPeriodicity) { "$($def.numberPeriodicity)" } else { "Year" }
	$checkUnique = if ($def.checkUnique -eq $false) { "false" } else { "true" }
	$autonumbering = if ($def.autonumbering -eq $false) { "false" } else { "true" }

	X "$i<NumberType>$numberType</NumberType>"
	X "$i<NumberLength>$numberLength</NumberLength>"
	X "$i<NumberAllowedLength>$numberAllowedLength</NumberAllowedLength>"
	X "$i<NumberPeriodicity>$numberPeriodicity</NumberPeriodicity>"
	X "$i<CheckUnique>$checkUnique</CheckUnique>"
	X "$i<Autonumbering>$autonumbering</Autonumbering>"

	Emit-StandardAttributes $i "Document"
	X "$i<Characteristics/>"

	X "$i<BasedOn/>"
	X "$i<InputByString>"
	X "$i`t<xr:Field>Document.$objName.StandardAttribute.Number</xr:Field>"
	X "$i</InputByString>"
	X "$i<CreateOnInput>DontUse</CreateOnInput>"
	X "$i<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	X "$i<DefaultObjectForm/>"
	X "$i<DefaultListForm/>"
	X "$i<DefaultChoiceForm/>"
	X "$i<AuxiliaryObjectForm/>"
	X "$i<AuxiliaryListForm/>"
	X "$i<AuxiliaryChoiceForm/>"

	$posting = Get-EnumProp "Posting" "posting" "Allow"
	$realTimePosting = Get-EnumProp "RealTimePosting" "realTimePosting" "Deny"
	$registerRecordsDeletion = Get-EnumProp "RegisterRecordsDeletion" "registerRecordsDeletion" "AutoDelete"
	$registerRecordsWritingOnPost = Get-EnumProp "RegisterRecordsWritingOnPost" "registerRecordsWritingOnPost" "WriteModified"
	$sequenceFilling = if ($def.sequenceFilling) { "$($def.sequenceFilling)" } else { "AutoFill" }
	$postInPrivilegedMode = if ($def.postInPrivilegedMode -eq $false) { "false" } else { "true" }
	$unpostInPrivilegedMode = if ($def.unpostInPrivilegedMode -eq $false) { "false" } else { "true" }

	X "$i<Posting>$posting</Posting>"
	X "$i<RealTimePosting>$realTimePosting</RealTimePosting>"
	X "$i<RegisterRecordsDeletion>$registerRecordsDeletion</RegisterRecordsDeletion>"
	X "$i<RegisterRecordsWritingOnPost>$registerRecordsWritingOnPost</RegisterRecordsWritingOnPost>"
	X "$i<SequenceFilling>$sequenceFilling</SequenceFilling>"

	# RegisterRecords
	$regRecords = @()
	if ($def.registerRecords) {
		foreach ($rr in $def.registerRecords) {
			$rrStr = "$rr"
			# Resolve Russian synonyms in register records
			if ($rrStr.Contains('.')) {
				$dotIdx = $rrStr.IndexOf('.')
				$rrPrefix = $rrStr.Substring(0, $dotIdx)
				$rrSuffix = $rrStr.Substring($dotIdx + 1)
				if ($script:objectTypeSynonyms.ContainsKey($rrPrefix)) {
					$rrPrefix = $script:objectTypeSynonyms[$rrPrefix]
				}
				$regRecords += "$rrPrefix.$rrSuffix"
			} else {
				$regRecords += $rrStr
			}
		}
	}

	if ($regRecords.Count -gt 0) {
		X "$i<RegisterRecords>"
		foreach ($rr in $regRecords) {
			X "$i`t<xr:Item xsi:type=`"xr:MDObjectRef`">$rr</xr:Item>"
		}
		X "$i</RegisterRecords>"
	} else {
		X "$i<RegisterRecords/>"
	}

	X "$i<PostInPrivilegedMode>$postInPrivilegedMode</PostInPrivilegedMode>"
	X "$i<UnpostInPrivilegedMode>$unpostInPrivilegedMode</UnpostInPrivilegedMode>"
	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"
	X "$i<DataLockFields/>"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
	X "$i<DataHistory>DontUse</DataHistory>"
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>"
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-EnumProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>false</UseStandardCommands>"

	Emit-StandardAttributes $i "Enum"
	X "$i<Characteristics/>"

	$quickChoice = if ($def.quickChoice -eq $false) { "false" } else { "true" }
	X "$i<QuickChoice>$quickChoice</QuickChoice>"
	X "$i<ChoiceMode>BothWays</ChoiceMode>"
	X "$i<DefaultListForm/>"
	X "$i<DefaultChoiceForm/>"
	X "$i<AuxiliaryListForm/>"
	X "$i<AuxiliaryChoiceForm/>"
	X "$i<ListPresentation/>"
	X "$i<ExtendedListPresentation/>"
	X "$i<Explanation/>"
	X "$i<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
}

function Emit-ConstantProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	# Type
	$valueType = Build-TypeStr $def
	if (-not $valueType) { $valueType = "String" }
	Emit-ValueType $i $valueType

	X "$i<UseStandardCommands>true</UseStandardCommands>"
	X "$i<DefaultForm/>"
	X "$i<ExtendedPresentation/>"
	X "$i<Explanation/>"
	X "$i<PasswordMode>false</PasswordMode>"
	X "$i<Format/>"
	X "$i<EditFormat/>"
	X "$i<ToolTip/>"
	X "$i<MarkNegatives>false</MarkNegatives>"
	X "$i<Mask/>"
	X "$i<MultiLine>false</MultiLine>"
	X "$i<ExtendedEdit>false</ExtendedEdit>"
	X "$i<MinValue xsi:nil=`"true`"/>"
	X "$i<MaxValue xsi:nil=`"true`"/>"
	X "$i<FillChecking>DontCheck</FillChecking>"
	X "$i<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>"
	X "$i<ChoiceParameterLinks/>"
	X "$i<ChoiceParameters/>"
	X "$i<QuickChoice>Auto</QuickChoice>"
	X "$i<ChoiceForm/>"
	X "$i<LinkByType/>"
	X "$i<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"
	X "$i<DataHistory>DontUse</DataHistory>"
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>"
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-InformationRegisterProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"
	X "$i<EditType>InDialog</EditType>"
	X "$i<DefaultRecordForm/>"
	X "$i<DefaultListForm/>"
	X "$i<AuxiliaryRecordForm/>"
	X "$i<AuxiliaryListForm/>"

	Emit-StandardAttributes $i "InformationRegister"

	$periodicity = Get-EnumProp "InformationRegisterPeriodicity" "periodicity" "Nonperiodical"
	$writeMode = Get-EnumProp "WriteMode" "writeMode" "Independent"

	# MainFilterOnPeriod: auto based on periodicity unless explicitly set
	$mainFilterOnPeriod = "false"
	if ($null -ne $def.mainFilterOnPeriod) {
		$mainFilterOnPeriod = if ($def.mainFilterOnPeriod -eq $true) { "true" } else { "false" }
	} elseif ($periodicity -ne "Nonperiodical") {
		$mainFilterOnPeriod = "true"
	}

	X "$i<InformationRegisterPeriodicity>$periodicity</InformationRegisterPeriodicity>"
	X "$i<WriteMode>$writeMode</WriteMode>"
	X "$i<MainFilterOnPeriod>$mainFilterOnPeriod</MainFilterOnPeriod>"
	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	X "$i<EnableTotalsSliceFirst>false</EnableTotalsSliceFirst>"
	X "$i<EnableTotalsSliceLast>false</EnableTotalsSliceLast>"
	X "$i<RecordPresentation/>"
	X "$i<ExtendedRecordPresentation/>"
	X "$i<ListPresentation/>"
	X "$i<ExtendedListPresentation/>"
	X "$i<Explanation/>"
	X "$i<DataHistory>DontUse</DataHistory>"
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>"
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-AccumulationRegisterProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"
	X "$i<DefaultListForm/>"
	X "$i<AuxiliaryListForm/>"

	$registerType = Get-EnumProp "RegisterType" "registerType" "Balance"
	X "$i<RegisterType>$registerType</RegisterType>"

	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"

	Emit-StandardAttributes $i "AccumulationRegister"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	$enableTotalsSplitting = if ($def.enableTotalsSplitting -eq $false) { "false" } else { "true" }
	X "$i<EnableTotalsSplitting>$enableTotalsSplitting</EnableTotalsSplitting>"

	X "$i<ListPresentation/>"
	X "$i<ExtendedListPresentation/>"
	X "$i<Explanation/>"
}

# --- 13a. Wave 1: DefinedType, CommonModule, ScheduledJob, EventSubscription ---

function Emit-DefinedTypeProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	# Type — composite type with multiple v8:Type entries (accept both valueType and valueTypes)
	$valueTypes = @()
	if ($def.valueTypes) {
		$valueTypes = @($def.valueTypes)
	} elseif ($def.valueType) {
		$valueTypes = @($def.valueType)
	}
	if ($valueTypes.Count -gt 0) {
		X "$i<Type>"
		foreach ($vt in $valueTypes) {
			$resolved = Resolve-TypeStr "$vt"
			if ($resolved -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef)\.') {
				X "$i`t<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$resolved</v8:Type>"
			} elseif ($resolved -eq "Boolean") {
				X "$i`t<v8:Type>xs:boolean</v8:Type>"
			} elseif ($resolved -match '^String') {
				X "$i`t<v8:Type>xs:string</v8:Type>"
				X "$i`t<v8:StringQualifiers>"
				X "$i`t`t<v8:Length>0</v8:Length>"
				X "$i`t`t<v8:AllowedLength>Variable</v8:AllowedLength>"
				X "$i`t</v8:StringQualifiers>"
			} else {
				X "$i`t<v8:Type>cfg:$resolved</v8:Type>"
			}
		}
		X "$i</Type>"
	} else {
		X "$i<Type/>"
	}
}

function Emit-CommonModuleProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	# Context shortcuts
	$context = if ($def.context) { "$($def.context)" } else { "" }

	$global = if ($def.global -eq $true) { "true" } else { "false" }
	$server = "false"; $serverCall = "false"; $clientManaged = "false"
	$clientOrdinary = "false"; $externalConnection = "false"; $privileged = "false"

	switch ($context) {
		"server"       { $server = "true"; $serverCall = "true" }
		"serverCall"   { $server = "true"; $serverCall = "true" }
		"client"       { $clientManaged = "true" }
		"serverClient" { $server = "true"; $clientManaged = "true" }
		default {
			if ($def.server -eq $true) { $server = "true" }
			if ($def.serverCall -eq $true) { $serverCall = "true" }
			if ($def.clientManagedApplication -eq $true) { $clientManaged = "true" }
			if ($def.clientOrdinaryApplication -eq $true) { $clientOrdinary = "true" }
			if ($def.externalConnection -eq $true) { $externalConnection = "true" }
			if ($def.privileged -eq $true) { $privileged = "true" }
		}
	}

	X "$i<Global>$global</Global>"
	X "$i<ClientManagedApplication>$clientManaged</ClientManagedApplication>"
	X "$i<Server>$server</Server>"
	X "$i<ExternalConnection>$externalConnection</ExternalConnection>"
	X "$i<ClientOrdinaryApplication>$clientOrdinary</ClientOrdinaryApplication>"
	X "$i<ServerCall>$serverCall</ServerCall>"
	X "$i<Privileged>$privileged</Privileged>"

	$returnValuesReuse = Get-EnumProp "ReturnValuesReuse" "returnValuesReuse" "DontUse"
	X "$i<ReturnValuesReuse>$returnValuesReuse</ReturnValuesReuse>"
}

function Emit-ScheduledJobProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	$methodName = if ($def.methodName) { "$($def.methodName)" } else { "" }
	# Ensure CommonModule. prefix
	if ($methodName -and -not $methodName.StartsWith("CommonModule.")) {
		$methodName = "CommonModule.$methodName"
	}
	X "$i<MethodName>$(Esc-Xml $methodName)</MethodName>"

	# $synonym может быть {ru,en}; здесь Description — плоская строка, берём ru-текст.
	$description = if ($def.description) { "$($def.description)" } elseif ($synonym -is [string]) { $synonym } else { "" }
	X "$i<Description>$(Esc-Xml $description)</Description>"

	$key = if ($def.key) { "$($def.key)" } else { "" }
	X "$i<Key>$(Esc-Xml $key)</Key>"

	$use = if ($def.use -eq $true) { "true" } else { "false" }
	X "$i<Use>$use</Use>"

	$predefined = if ($def.predefined -eq $true) { "true" } else { "false" }
	X "$i<Predefined>$predefined</Predefined>"

	$restartCount = if ($null -ne $def.restartCountOnFailure) { "$($def.restartCountOnFailure)" } else { "3" }
	$restartInterval = if ($null -ne $def.restartIntervalOnFailure) { "$($def.restartIntervalOnFailure)" } else { "10" }
	X "$i<RestartCountOnFailure>$restartCount</RestartCountOnFailure>"
	X "$i<RestartIntervalOnFailure>$restartInterval</RestartIntervalOnFailure>"
}

function Emit-EventSubscriptionProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	# Source — array of v8:Type
	$sources = @()
	if ($def.source) { $sources = @($def.source) }
	if ($sources.Count -gt 0) {
		X "$i<Source>"
		foreach ($src in $sources) {
			$resolved = Resolve-TypeStr "$src"
			X "$i`t<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$resolved</v8:Type>"
		}
		X "$i</Source>"
	} else {
		X "$i<Source/>"
	}

	$event = if ($def.event) { "$($def.event)" } else { "BeforeWrite" }
	X "$i<Event>$event</Event>"

	$handler = if ($def.handler) { "$($def.handler)" } else { "" }
	# Ensure CommonModule. prefix
	if ($handler -and -not $handler.StartsWith("CommonModule.")) {
		$handler = "CommonModule.$handler"
	}
	X "$i<Handler>$(Esc-Xml $handler)</Handler>"
}

# --- 13b. Wave 2: Report, DataProcessor ---

function Emit-ReportProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"

	$defaultForm = if ($def.defaultForm) { "$($def.defaultForm)" } else { "" }
	if ($defaultForm) { X "$i<DefaultForm>$defaultForm</DefaultForm>" } else { X "$i<DefaultForm/>" }

	$auxForm = if ($def.auxiliaryForm) { "$($def.auxiliaryForm)" } else { "" }
	if ($auxForm) { X "$i<AuxiliaryForm>$auxForm</AuxiliaryForm>" } else { X "$i<AuxiliaryForm/>" }

	$mainDCS = if ($def.mainDataCompositionSchema) { "$($def.mainDataCompositionSchema)" } else { "" }
	if ($mainDCS) { X "$i<MainDataCompositionSchema>$mainDCS</MainDataCompositionSchema>" } else { X "$i<MainDataCompositionSchema/>" }

	$defSettings = if ($def.defaultSettingsForm) { "$($def.defaultSettingsForm)" } else { "" }
	if ($defSettings) { X "$i<DefaultSettingsForm>$defSettings</DefaultSettingsForm>" } else { X "$i<DefaultSettingsForm/>" }

	$auxSettings = if ($def.auxiliarySettingsForm) { "$($def.auxiliarySettingsForm)" } else { "" }
	if ($auxSettings) { X "$i<AuxiliarySettingsForm>$auxSettings</AuxiliarySettingsForm>" } else { X "$i<AuxiliarySettingsForm/>" }

	$defVariant = if ($def.defaultVariantForm) { "$($def.defaultVariantForm)" } else { "" }
	if ($defVariant) { X "$i<DefaultVariantForm>$defVariant</DefaultVariantForm>" } else { X "$i<DefaultVariantForm/>" }

	X "$i<VariantsStorage/>"
	X "$i<SettingsStorage/>"
	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"
	X "$i<ExtendedPresentation/>"
	X "$i<Explanation/>"
}

function Emit-DataProcessorProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>false</UseStandardCommands>"

	$defaultForm = if ($def.defaultForm) { "$($def.defaultForm)" } else { "" }
	if ($defaultForm) { X "$i<DefaultForm>$defaultForm</DefaultForm>" } else { X "$i<DefaultForm/>" }

	$auxForm = if ($def.auxiliaryForm) { "$($def.auxiliaryForm)" } else { "" }
	if ($auxForm) { X "$i<AuxiliaryForm>$auxForm</AuxiliaryForm>" } else { X "$i<AuxiliaryForm/>" }

	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"
	X "$i<ExtendedPresentation/>"
	X "$i<Explanation/>"
}

# --- 13c. Wave 3: ExchangePlan, ChartOfCharacteristicTypes, DocumentJournal ---

function Emit-ExchangePlanProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	if ($def.comment) { X "$i<Comment>$(Esc-XmlText "$($def.comment)")</Comment>" } else { X "$i<Comment/>" }
	$useStdCmd = if (Get-BoolProp "useStandardCommands" $true) { "true" } else { "false" }
	X "$i<UseStandardCommands>$useStdCmd</UseStandardCommands>"

	$codeLength = if ($null -ne $def.codeLength) { "$($def.codeLength)" } else { "9" }
	$descriptionLength = if ($null -ne $def.descriptionLength) { "$($def.descriptionLength)" } else { "150" }
	$codeAllowedLength = Get-EnumProp "CodeAllowedLength" "codeAllowedLength" "Variable"

	X "$i<CodeLength>$codeLength</CodeLength>"
	X "$i<CodeAllowedLength>$codeAllowedLength</CodeAllowedLength>"
	X "$i<DescriptionLength>$descriptionLength</DescriptionLength>"
	X "$i<DefaultPresentation>$(Get-EnumProp 'DefaultPresentation' 'defaultPresentation' 'AsDescription')</DefaultPresentation>"
	X "$i<EditType>$(Get-EnumProp 'EditType' 'editType' 'InDialog')</EditType>"
	$quickChoice = if ($def.quickChoice -eq $true) { "true" } else { "false" }
	X "$i<QuickChoice>$quickChoice</QuickChoice>"
	X "$i<ChoiceMode>$(Get-EnumProp 'ChoiceMode' 'choiceMode' 'BothWays')</ChoiceMode>"

	# InputByString: override `inputByString` ЛИБО дефолт [Descr при D>0]+[Code при C>0] (prefix ExchangePlan).
	if (Test-DefKey 'inputByString') {
		$ibFields = @($def.inputByString | ForEach-Object { Expand-DataPath "$_" })
	} else {
		$ibFields = @()
		if ([int]$descriptionLength -gt 0) { $ibFields += "ExchangePlan.$objName.StandardAttribute.Description" }
		if ([int]$codeLength -gt 0)        { $ibFields += "ExchangePlan.$objName.StandardAttribute.Code" }
	}
	Emit-FieldBlock $i "InputByString" $ibFields
	X "$i<SearchStringModeOnInputByString>$(Get-EnumProp 'SearchStringModeOnInputByString' 'searchStringModeOnInputByString' 'Begin')</SearchStringModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	Emit-FormRef $i "DefaultObjectForm"   $def.defaultObjectForm
	Emit-FormRef $i "DefaultListForm"     $def.defaultListForm
	Emit-FormRef $i "DefaultChoiceForm"   $def.defaultChoiceForm
	Emit-FormRef $i "AuxiliaryObjectForm" $def.auxiliaryObjectForm
	Emit-FormRef $i "AuxiliaryListForm"   $def.auxiliaryListForm
	Emit-FormRef $i "AuxiliaryChoiceForm" $def.auxiliaryChoiceForm

	Emit-StandardAttributes $i "ExchangePlan"
	Emit-Characteristics $i $def.characteristics
	Emit-BasedOn $i $def.basedOn

	$distributed = if ($def.distributedInfoBase -eq $true) { "true" } else { "false" }
	$includeExt = if ($def.includeConfigurationExtensions -eq $true) { "true" } else { "false" }
	X "$i<DistributedInfoBase>$distributed</DistributedInfoBase>"
	X "$i<IncludeConfigurationExtensions>$includeExt</IncludeConfigurationExtensions>"

	X "$i<CreateOnInput>$(Get-EnumProp 'CreateOnInput' 'createOnInput' 'DontUse')</CreateOnInput>"
	X "$i<ChoiceHistoryOnInput>$(Get-EnumProp 'ChoiceHistoryOnInput' 'choiceHistoryOnInput' 'Auto')</ChoiceHistoryOnInput>"
	$inclHelp = if (Get-BoolProp "includeHelpInContents" $false) { "true" } else { "false" }
	X "$i<IncludeHelpInContents>$inclHelp</IncludeHelpInContents>"
	$dlFields = if (Test-DefKey 'dataLockFields') { @($def.dataLockFields | ForEach-Object { Expand-DataPath "$_" }) } else { @() }
	Emit-FieldBlock $i "DataLockFields" $dlFields
	X "$i<DataLockControlMode>$(Get-EnumProp 'DataLockControlMode' 'dataLockControlMode' 'Managed')</DataLockControlMode>"
	X "$i<FullTextSearch>$(Get-EnumProp 'FullTextSearch' 'fullTextSearch' 'Use')</FullTextSearch>"

	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<DataHistory>$(Get-EnumProp 'DataHistory' 'dataHistory' 'DontUse')</DataHistory>"
	$updDH = if (Get-BoolProp "updateDataHistoryImmediatelyAfterWrite" $false) { "true" } else { "false" }
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>$updDH</UpdateDataHistoryImmediatelyAfterWrite>"
	$execDH = if (Get-BoolProp "executeAfterWriteDataHistoryVersionProcessing" $false) { "true" } else { "false" }
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>$execDH</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-ChartOfCharacteristicTypesProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	if ($def.comment) { X "$i<Comment>$(Esc-XmlText "$($def.comment)")</Comment>" } else { X "$i<Comment/>" }
	$useStdCmd = if (Get-BoolProp "useStandardCommands" $true) { "true" } else { "false" }
	X "$i<UseStandardCommands>$useStdCmd</UseStandardCommands>"
	$inclHelp = if (Get-BoolProp "includeHelpInContents" $false) { "true" } else { "false" }
	X "$i<IncludeHelpInContents>$inclHelp</IncludeHelpInContents>"

	# CharacteristicExtValues — ссылка на справочник доп. значений характеристик (обычно пусто).
	if ($def.characteristicExtValues) { X "$i<CharacteristicExtValues>$(Esc-Xml "$($def.characteristicExtValues)")</CharacteristicExtValues>" }
	else { X "$i<CharacteristicExtValues/>" }

	# Type — тип значения характеристики (составной). DSL `valueType` строка "A + B + C" ИЛИ массив; нет ключа → дефолт.
	$vt = $def.valueType; if (-not $vt -and $def.valueTypes) { $vt = ($def.valueTypes -join ' + ') }
	if ($vt) {
		X "$i<Type>"
		Emit-TypeContent "$i`t" "$vt"
		X "$i</Type>"
	} else {
		X "$i<Type>"
		X "$i`t<v8:Type>xs:boolean</v8:Type>"
		X "$i`t<v8:Type>xs:string</v8:Type>"
		X "$i`t<v8:StringQualifiers>"
		X "$i`t`t<v8:Length>100</v8:Length>"
		X "$i`t`t<v8:AllowedLength>Variable</v8:AllowedLength>"
		X "$i`t</v8:StringQualifiers>"
		X "$i`t<v8:Type>xs:decimal</v8:Type>"
		X "$i`t<v8:NumberQualifiers>"
		X "$i`t`t<v8:Digits>15</v8:Digits>"
		X "$i`t`t<v8:FractionDigits>2</v8:FractionDigits>"
		X "$i`t`t<v8:AllowedSign>Any</v8:AllowedSign>"
		X "$i`t</v8:NumberQualifiers>"
		X "$i`t<v8:Type>xs:dateTime</v8:Type>"
		X "$i`t<v8:DateQualifiers>"
		X "$i`t`t<v8:DateFractions>DateTime</v8:DateFractions>"
		X "$i`t</v8:DateQualifiers>"
		X "$i</Type>"
	}

	$hierarchical = if ($def.hierarchical -eq $true) { "true" } else { "false" }
	X "$i<Hierarchical>$hierarchical</Hierarchical>"
	$foldersOnTop = if ($def.foldersOnTop -eq $false) { "false" } else { "true" }
	X "$i<FoldersOnTop>$foldersOnTop</FoldersOnTop>"

	$codeLength = if ($null -ne $def.codeLength) { "$($def.codeLength)" } else { "9" }
	$descriptionLength = if ($null -ne $def.descriptionLength) { "$($def.descriptionLength)" } else { "100" }
	X "$i<CodeLength>$codeLength</CodeLength>"
	X "$i<CodeAllowedLength>$(Get-EnumProp 'CodeAllowedLength' 'codeAllowedLength' 'Variable')</CodeAllowedLength>"
	X "$i<DescriptionLength>$descriptionLength</DescriptionLength>"
	X "$i<CodeSeries>$(Get-EnumProp 'CodeSeries' 'codeSeries' 'WholeCharacteristicKind')</CodeSeries>"
	$checkUnique = if ($def.checkUnique -eq $false) { "false" } else { "true" }
	X "$i<CheckUnique>$checkUnique</CheckUnique>"
	$autonumbering = if ($def.autonumbering -eq $false) { "false" } else { "true" }
	X "$i<Autonumbering>$autonumbering</Autonumbering>"
	X "$i<DefaultPresentation>$(Get-EnumProp 'DefaultPresentation' 'defaultPresentation' 'AsDescription')</DefaultPresentation>"

	Emit-StandardAttributes $i "ChartOfCharacteristicTypes"
	Emit-Characteristics $i $def.characteristics
	X "$i<PredefinedDataUpdate>$(Get-EnumProp 'PredefinedDataUpdate' 'predefinedDataUpdate' 'Auto')</PredefinedDataUpdate>"
	X "$i<EditType>$(Get-EnumProp 'EditType' 'editType' 'InDialog')</EditType>"
	$quickChoice = if ($def.quickChoice -eq $true) { "true" } else { "false" }
	X "$i<QuickChoice>$quickChoice</QuickChoice>"
	X "$i<ChoiceMode>$(Get-EnumProp 'ChoiceMode' 'choiceMode' 'BothWays')</ChoiceMode>"

	# InputByString: override ЛИБО дефолт [Descr при D>0]+[Code при C>0] (prefix ChartOfCharacteristicTypes).
	if (Test-DefKey 'inputByString') {
		$ibFields = @($def.inputByString | ForEach-Object { Expand-DataPath "$_" })
	} else {
		$ibFields = @()
		if ([int]$descriptionLength -gt 0) { $ibFields += "ChartOfCharacteristicTypes.$objName.StandardAttribute.Description" }
		if ([int]$codeLength -gt 0)        { $ibFields += "ChartOfCharacteristicTypes.$objName.StandardAttribute.Code" }
	}
	Emit-FieldBlock $i "InputByString" $ibFields
	X "$i<CreateOnInput>$(Get-EnumProp 'CreateOnInput' 'createOnInput' 'DontUse')</CreateOnInput>"
	X "$i<SearchStringModeOnInputByString>$(Get-EnumProp 'SearchStringModeOnInputByString' 'searchStringModeOnInputByString' 'Begin')</SearchStringModeOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceHistoryOnInput>$(Get-EnumProp 'ChoiceHistoryOnInput' 'choiceHistoryOnInput' 'Auto')</ChoiceHistoryOnInput>"
	Emit-FormRef $i "DefaultObjectForm"       $def.defaultObjectForm
	Emit-FormRef $i "DefaultFolderForm"       $def.defaultFolderForm
	Emit-FormRef $i "DefaultListForm"         $def.defaultListForm
	Emit-FormRef $i "DefaultChoiceForm"       $def.defaultChoiceForm
	Emit-FormRef $i "DefaultFolderChoiceForm" $def.defaultFolderChoiceForm
	Emit-FormRef $i "AuxiliaryObjectForm"       $def.auxiliaryObjectForm
	Emit-FormRef $i "AuxiliaryFolderForm"       $def.auxiliaryFolderForm
	Emit-FormRef $i "AuxiliaryListForm"         $def.auxiliaryListForm
	Emit-FormRef $i "AuxiliaryChoiceForm"       $def.auxiliaryChoiceForm
	Emit-FormRef $i "AuxiliaryFolderChoiceForm" $def.auxiliaryFolderChoiceForm
	Emit-BasedOn $i $def.basedOn
	$dlFields = if (Test-DefKey 'dataLockFields') { @($def.dataLockFields | ForEach-Object { Expand-DataPath "$_" }) } else { @() }
	Emit-FieldBlock $i "DataLockFields" $dlFields
	X "$i<DataLockControlMode>$(Get-EnumProp 'DataLockControlMode' 'dataLockControlMode' 'Managed')</DataLockControlMode>"
	X "$i<FullTextSearch>$(Get-EnumProp 'FullTextSearch' 'fullTextSearch' 'Use')</FullTextSearch>"
	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<DataHistory>$(Get-EnumProp 'DataHistory' 'dataHistory' 'DontUse')</DataHistory>"
	$updDH = if (Get-BoolProp "updateDataHistoryImmediatelyAfterWrite" $false) { "true" } else { "false" }
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>$updDH</UpdateDataHistoryImmediatelyAfterWrite>"
	$execDH = if (Get-BoolProp "executeAfterWriteDataHistoryVersionProcessing" $false) { "true" } else { "false" }
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>$execDH</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-DocumentJournalProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	$defaultForm = if ($def.defaultForm) { "$($def.defaultForm)" } else { "" }
	if ($defaultForm) { X "$i<DefaultForm>$defaultForm</DefaultForm>" } else { X "$i<DefaultForm/>" }

	$auxForm = if ($def.auxiliaryForm) { "$($def.auxiliaryForm)" } else { "" }
	if ($auxForm) { X "$i<AuxiliaryForm>$auxForm</AuxiliaryForm>" } else { X "$i<AuxiliaryForm/>" }

	X "$i<UseStandardCommands>true</UseStandardCommands>"

	# RegisteredDocuments
	$regDocs = @()
	if ($def.registeredDocuments) { $regDocs = @($def.registeredDocuments) }
	if ($regDocs.Count -gt 0) {
		X "$i<RegisteredDocuments>"
		foreach ($rd in $regDocs) {
			$rdStr = "$rd"
			# Resolve Russian synonyms: Документ.Xxx → Document.Xxx
			if ($rdStr.Contains('.')) {
				$dotIdx = $rdStr.IndexOf('.')
				$rdPrefix = $rdStr.Substring(0, $dotIdx)
				$rdSuffix = $rdStr.Substring($dotIdx + 1)
				if ($script:objectTypeSynonyms.ContainsKey($rdPrefix)) {
					$rdPrefix = $script:objectTypeSynonyms[$rdPrefix]
				}
				$rdStr = "$rdPrefix.$rdSuffix"
			}
			X "$i`t<xr:Item xsi:type=`"xr:MDObjectRef`">$rdStr</xr:Item>"
		}
		X "$i</RegisteredDocuments>"
	} else {
		X "$i<RegisteredDocuments/>"
	}

	Emit-StandardAttributes $i "DocumentJournal"

	X "$i<ListPresentation/>"
	X "$i<ExtendedListPresentation/>"
	X "$i<Explanation/>"
}

# --- 13d. Wave 4: ChartOfAccounts, AccountingRegister, ChartOfCalculationTypes, CalculationRegister ---

function Emit-ChartOfAccountsProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"

	# ExtDimensionTypes
	$extDimTypes = if ($def.extDimensionTypes) { "$($def.extDimensionTypes)" } else { "" }
	if ($extDimTypes) { X "$i<ExtDimensionTypes>$extDimTypes</ExtDimensionTypes>" }
	else { X "$i<ExtDimensionTypes/>" }

	$maxExtDim = if ($null -ne $def.maxExtDimensionCount) { "$($def.maxExtDimensionCount)" } else { "3" }
	X "$i<MaxExtDimensionCount>$maxExtDim</MaxExtDimensionCount>"

	$codeMask = if ($def.codeMask) { "$($def.codeMask)" } else { "" }
	if ($codeMask) { X "$i<CodeMask>$codeMask</CodeMask>" } else { X "$i<CodeMask/>" }

	$codeLength = if ($null -ne $def.codeLength) { "$($def.codeLength)" } else { "8" }
	$descriptionLength = if ($null -ne $def.descriptionLength) { "$($def.descriptionLength)" } else { "120" }
	$codeSeries = if ($def.codeSeries) { "$($def.codeSeries)" } else { "WholeChartOfAccounts" }
	$autoOrder = if ($def.autoOrderByCode -eq $false) { "false" } else { "true" }
	$orderLength = if ($null -ne $def.orderLength) { "$($def.orderLength)" } else { "5" }

	X "$i<CodeLength>$codeLength</CodeLength>"
	X "$i<DescriptionLength>$descriptionLength</DescriptionLength>"
	X "$i<CodeSeries>$codeSeries</CodeSeries>"
	X "$i<CheckUnique>false</CheckUnique>"
	X "$i<DefaultPresentation>AsDescription</DefaultPresentation>"
	X "$i<AutoOrderByCode>$autoOrder</AutoOrderByCode>"
	X "$i<OrderLength>$orderLength</OrderLength>"

	X "$i<EditType>InDialog</EditType>"

	Emit-StandardAttributes $i "ChartOfAccounts"

	# StandardTabularSections — ExtDimensionTypes
	X "$i<StandardTabularSections>"
	X "$i`t<xr:StandardTabularSection name=`"ExtDimensionTypes`">"
	X "$i`t`t<xr:StandardAttributes>"
	foreach ($stAttr in @("TurnoversOnly","Predefined","ExtDimensionType","LineNumber")) {
		Emit-StandardAttribute "$i`t`t`t" $stAttr
	}
	X "$i`t`t</xr:StandardAttributes>"
	X "$i`t</xr:StandardTabularSection>"
	X "$i</StandardTabularSections>"

	X "$i<Characteristics/>"
	X "$i<PredefinedDataUpdate>Auto</PredefinedDataUpdate>"
	$quickChoice = if ($def.quickChoice -eq $true) { "true" } else { "false" }
	X "$i<QuickChoice>$quickChoice</QuickChoice>"
	X "$i<ChoiceMode>BothWays</ChoiceMode>"
	X "$i<InputByString>"
	X "$i`t<xr:Field>ChartOfAccounts.$objName.StandardAttribute.Description</xr:Field>"
	X "$i`t<xr:Field>ChartOfAccounts.$objName.StandardAttribute.Code</xr:Field>"
	X "$i</InputByString>"
	X "$i<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	X "$i<DefaultObjectForm/>"
	X "$i<DefaultListForm/>"
	X "$i<DefaultChoiceForm/>"
	X "$i<AuxiliaryObjectForm/>"
	X "$i<AuxiliaryListForm/>"
	X "$i<AuxiliaryChoiceForm/>"
	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"
	X "$i<BasedOn/>"
	X "$i<DataLockFields/>"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<CreateOnInput>DontUse</CreateOnInput>"
	X "$i<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
	X "$i<DataHistory>DontUse</DataHistory>"
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>"
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-AccountingRegisterProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"
	X "$i<DefaultListForm/>"
	X "$i<AuxiliaryListForm/>"

	$chartOfAccounts = if ($def.chartOfAccounts) { "$($def.chartOfAccounts)" } else { "" }
	if ($chartOfAccounts) { X "$i<ChartOfAccounts>$chartOfAccounts</ChartOfAccounts>" }
	else { X "$i<ChartOfAccounts/>" }

	$correspondence = if ($def.correspondence -eq $true) { "true" } else { "false" }
	X "$i<Correspondence>$correspondence</Correspondence>"

	$periodAdjLen = if ($null -ne $def.periodAdjustmentLength) { "$($def.periodAdjustmentLength)" } else { "0" }
	X "$i<PeriodAdjustmentLength>$periodAdjLen</PeriodAdjustmentLength>"

	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"

	Emit-StandardAttributes $i "AccountingRegister"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	X "$i<ListPresentation/>"
	X "$i<ExtendedListPresentation/>"
	X "$i<Explanation/>"
}

function Emit-ChartOfCalculationTypesProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"

	$codeLength = if ($null -ne $def.codeLength) { "$($def.codeLength)" } else { "9" }
	$descriptionLength = if ($null -ne $def.descriptionLength) { "$($def.descriptionLength)" } else { "25" }
	$codeType = Get-EnumProp "CodeType" "codeType" "String"
	$codeAllowedLength = Get-EnumProp "CodeAllowedLength" "codeAllowedLength" "Variable"

	X "$i<CodeLength>$codeLength</CodeLength>"
	X "$i<CodeType>$codeType</CodeType>"
	X "$i<CodeAllowedLength>$codeAllowedLength</CodeAllowedLength>"
	X "$i<DescriptionLength>$descriptionLength</DescriptionLength>"
	X "$i<DefaultPresentation>AsDescription</DefaultPresentation>"

	$dependence = Get-EnumProp "DependenceOnCalculationTypes" "dependenceOnCalculationTypes" "DontUse"
	X "$i<DependenceOnCalculationTypes>$dependence</DependenceOnCalculationTypes>"

	# BaseCalculationTypes
	$baseTypes = @()
	if ($def.baseCalculationTypes) { $baseTypes = @($def.baseCalculationTypes) }
	if ($baseTypes.Count -gt 0) {
		X "$i<BaseCalculationTypes>"
		foreach ($bt in $baseTypes) {
			X "$i`t<xr:Item xsi:type=`"xr:MDObjectRef`">$bt</xr:Item>"
		}
		X "$i</BaseCalculationTypes>"
	} else {
		X "$i<BaseCalculationTypes/>"
	}

	$actionPeriodUse = if ($def.actionPeriodUse -eq $true) { "true" } else { "false" }
	X "$i<ActionPeriodUse>$actionPeriodUse</ActionPeriodUse>"

	Emit-StandardAttributes $i "ChartOfCalculationTypes"
	X "$i<Characteristics/>"
	X "$i<PredefinedDataUpdate>Auto</PredefinedDataUpdate>"
	X "$i<EditType>InDialog</EditType>"
	$quickChoice = if ($def.quickChoice -eq $true) { "true" } else { "false" }
	X "$i<QuickChoice>$quickChoice</QuickChoice>"
	X "$i<ChoiceMode>BothWays</ChoiceMode>"
	X "$i<InputByString>"
	X "$i`t<xr:Field>ChartOfCalculationTypes.$objName.StandardAttribute.Description</xr:Field>"
	X "$i`t<xr:Field>ChartOfCalculationTypes.$objName.StandardAttribute.Code</xr:Field>"
	X "$i</InputByString>"
	X "$i<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	X "$i<DefaultObjectForm/>"
	X "$i<DefaultListForm/>"
	X "$i<DefaultChoiceForm/>"
	X "$i<AuxiliaryObjectForm/>"
	X "$i<AuxiliaryListForm/>"
	X "$i<AuxiliaryChoiceForm/>"
	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"
	X "$i<BasedOn/>"
	X "$i<DataLockFields/>"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<CreateOnInput>DontUse</CreateOnInput>"
	X "$i<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
}

function Emit-CalculationRegisterProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"
	X "$i<DefaultListForm/>"
	X "$i<AuxiliaryListForm/>"

	$chartOfCalcTypes = if ($def.chartOfCalculationTypes) { "$($def.chartOfCalculationTypes)" } else { "" }
	if ($chartOfCalcTypes) { X "$i<ChartOfCalculationTypes>$chartOfCalcTypes</ChartOfCalculationTypes>" }
	else { X "$i<ChartOfCalculationTypes/>" }

	$periodicity = Get-EnumProp "InformationRegisterPeriodicity" "periodicity" "Month"
	X "$i<Periodicity>$periodicity</Periodicity>"

	$actionPeriod = if ($def.actionPeriod -eq $true) { "true" } else { "false" }
	X "$i<ActionPeriod>$actionPeriod</ActionPeriod>"

	$basePeriod = if ($def.basePeriod -eq $true) { "true" } else { "false" }
	X "$i<BasePeriod>$basePeriod</BasePeriod>"

	$schedule = if ($def.schedule) { "$($def.schedule)" } else { "" }
	if ($schedule) { X "$i<Schedule>$schedule</Schedule>" } else { X "$i<Schedule/>" }

	$scheduleValue = if ($def.scheduleValue) { "$($def.scheduleValue)" } else { "" }
	if ($scheduleValue) { X "$i<ScheduleValue>$scheduleValue</ScheduleValue>" } else { X "$i<ScheduleValue/>" }

	$scheduleDate = if ($def.scheduleDate) { "$($def.scheduleDate)" } else { "" }
	if ($scheduleDate) { X "$i<ScheduleDate>$scheduleDate</ScheduleDate>" } else { X "$i<ScheduleDate/>" }

	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"

	Emit-StandardAttributes $i "CalculationRegister"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	X "$i<ListPresentation/>"
	X "$i<ExtendedListPresentation/>"
	X "$i<Explanation/>"
}

# --- 13e. Wave 5: BusinessProcess, Task ---

function Emit-BusinessProcessProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"

	$editType = Get-EnumProp "EditType" "editType" "InDialog"
	X "$i<EditType>$editType</EditType>"

	$numberType = Get-EnumProp "NumberType" "numberType" "String"
	$numberLength = if ($null -ne $def.numberLength) { "$($def.numberLength)" } else { "11" }
	$numberAllowedLength = Get-EnumProp "NumberAllowedLength" "numberAllowedLength" "Variable"
	$checkUnique = if ($def.checkUnique -eq $false) { "false" } else { "true" }
	$autonumbering = if ($def.autonumbering -eq $false) { "false" } else { "true" }

	X "$i<NumberType>$numberType</NumberType>"
	X "$i<NumberLength>$numberLength</NumberLength>"
	X "$i<NumberAllowedLength>$numberAllowedLength</NumberAllowedLength>"
	X "$i<CheckUnique>$checkUnique</CheckUnique>"
	X "$i<Autonumbering>$autonumbering</Autonumbering>"

	Emit-StandardAttributes $i "BusinessProcess"
	X "$i<Characteristics/>"

	$task = if ($def.task) { "$($def.task)" } else { "" }
	if ($task) {
		X "$i<Task>$task</Task>"
	} else {
		X "$i<Task/>"
	}

	X "$i<BasedOn/>"
	X "$i<InputByString>"
	X "$i`t<xr:Field>BusinessProcess.$objName.StandardAttribute.Number</xr:Field>"
	X "$i</InputByString>"
	X "$i<CreateOnInput>DontUse</CreateOnInput>"
	X "$i<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	X "$i<DefaultObjectForm/>"
	X "$i<DefaultListForm/>"
	X "$i<DefaultChoiceForm/>"
	X "$i<AuxiliaryObjectForm/>"
	X "$i<AuxiliaryListForm/>"
	X "$i<AuxiliaryChoiceForm/>"
	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"
	X "$i<DataLockFields/>"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
	X "$i<DataHistory>DontUse</DataHistory>"
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>"
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

function Emit-TaskProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"
	X "$i<UseStandardCommands>true</UseStandardCommands>"

	$numberType = Get-EnumProp "NumberType" "numberType" "String"
	$numberLength = if ($null -ne $def.numberLength) { "$($def.numberLength)" } else { "14" }
	$numberAllowedLength = Get-EnumProp "NumberAllowedLength" "numberAllowedLength" "Variable"
	$checkUnique = if ($def.checkUnique -eq $false) { "false" } else { "true" }
	$autonumbering = if ($def.autonumbering -eq $false) { "false" } else { "true" }

	$taskNumberAutoPrefix = if ($def.taskNumberAutoPrefix) { "$($def.taskNumberAutoPrefix)" } else { "BusinessProcessNumber" }
	$descriptionLength = if ($null -ne $def.descriptionLength) { "$($def.descriptionLength)" } else { "150" }

	X "$i<NumberType>$numberType</NumberType>"
	X "$i<NumberLength>$numberLength</NumberLength>"
	X "$i<NumberAllowedLength>$numberAllowedLength</NumberAllowedLength>"
	X "$i<CheckUnique>$checkUnique</CheckUnique>"
	X "$i<Autonumbering>$autonumbering</Autonumbering>"
	X "$i<TaskNumberAutoPrefix>$taskNumberAutoPrefix</TaskNumberAutoPrefix>"
	X "$i<DescriptionLength>$descriptionLength</DescriptionLength>"

	# Addressing
	$addressing = if ($def.addressing) { "$($def.addressing)" } else { "" }
	if ($addressing) { X "$i<Addressing>$addressing</Addressing>" } else { X "$i<Addressing/>" }

	$mainAddressing = if ($def.mainAddressingAttribute) { "$($def.mainAddressingAttribute)" } else { "" }
	if ($mainAddressing) { X "$i<MainAddressingAttribute>$mainAddressing</MainAddressingAttribute>" } else { X "$i<MainAddressingAttribute/>" }

	$currentPerformer = if ($def.currentPerformer) { "$($def.currentPerformer)" } else { "" }
	if ($currentPerformer) { X "$i<CurrentPerformer>$currentPerformer</CurrentPerformer>" } else { X "$i<CurrentPerformer/>" }

	Emit-StandardAttributes $i "Task"
	X "$i<Characteristics/>"

	X "$i<BasedOn/>"
	X "$i<InputByString>"
	X "$i`t<xr:Field>Task.$objName.StandardAttribute.Number</xr:Field>"
	X "$i</InputByString>"
	X "$i<CreateOnInput>DontUse</CreateOnInput>"
	X "$i<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>"
	X "$i<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>"
	X "$i<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>"
	X "$i<DefaultObjectForm/>"
	X "$i<DefaultListForm/>"
	X "$i<DefaultChoiceForm/>"
	X "$i<AuxiliaryObjectForm/>"
	X "$i<AuxiliaryListForm/>"
	X "$i<AuxiliaryChoiceForm/>"
	X "$i<IncludeHelpInContents>false</IncludeHelpInContents>"
	X "$i<DataLockFields/>"

	$dataLockControlMode = Get-EnumProp "DataLockControlMode" "dataLockControlMode" "Automatic"
	X "$i<DataLockControlMode>$dataLockControlMode</DataLockControlMode>"

	$fullTextSearch = Get-EnumProp "FullTextSearch" "fullTextSearch" "Use"
	X "$i<FullTextSearch>$fullTextSearch</FullTextSearch>"

	Emit-MLText $i "ObjectPresentation" $def.objectPresentation
	Emit-MLText $i "ExtendedObjectPresentation" $def.extendedObjectPresentation
	Emit-MLText $i "ListPresentation" $def.listPresentation
	Emit-MLText $i "ExtendedListPresentation" $def.extendedListPresentation
	Emit-MLText $i "Explanation" $def.explanation
	X "$i<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
	X "$i<DataHistory>DontUse</DataHistory>"
	X "$i<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>"
	X "$i<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"
}

# --- 13f. Wave 6: HTTPService, WebService ---

function Emit-HTTPServiceProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	$rootURL = if ($def.rootURL) { "$($def.rootURL)" } else { $objName.ToLower() }
	X "$i<RootURL>$(Esc-Xml $rootURL)</RootURL>"

	$reuseSessions = Get-EnumProp "ReuseSessions" "reuseSessions" "DontUse"
	X "$i<ReuseSessions>$reuseSessions</ReuseSessions>"

	$sessionMaxAge = if ($null -ne $def.sessionMaxAge) { "$($def.sessionMaxAge)" } else { "20" }
	X "$i<SessionMaxAge>$sessionMaxAge</SessionMaxAge>"
}

function Emit-WebServiceProperties {
	param([string]$indent)
	$i = $indent

	X "$i<Name>$(Esc-Xml $objName)</Name>"
	Emit-MLText $i "Synonym" $synonym
	X "$i<Comment/>"

	$namespace = if ($def.namespace) { "$($def.namespace)" } else { "" }
	X "$i<Namespace>$(Esc-Xml $namespace)</Namespace>"

	$xdtoPackages = if ($def.xdtoPackages) { "$($def.xdtoPackages)" } else { "" }
	if ($xdtoPackages) { X "$i<XDTOPackages>$xdtoPackages</XDTOPackages>" } else { X "$i<XDTOPackages/>" }

	$reuseSessions = Get-EnumProp "ReuseSessions" "reuseSessions" "DontUse"
	X "$i<ReuseSessions>$reuseSessions</ReuseSessions>"

	$sessionMaxAge = if ($null -ne $def.sessionMaxAge) { "$($def.sessionMaxAge)" } else { "20" }
	X "$i<SessionMaxAge>$sessionMaxAge</SessionMaxAge>"
}

# --- 13g. ChildObjects emitters for new types ---

function Emit-Column {
	param([string]$indent, $colDef)
	$uuid = New-Guid-String

	$name = ""
	$synonym = ""
	$indexing = "DontIndex"
	$references = @()

	if ($colDef -is [string]) {
		$name = "$colDef"
		$synonym = Split-CamelCase $name
	} else {
		$name = "$($colDef.name)"
		$synonym = if ($colDef.synonym) { "$($colDef.synonym)" } else { Split-CamelCase $name }
		if ($colDef.indexing) { $indexing = "$($colDef.indexing)" }
		if ($colDef.references) { $references = @($colDef.references) }
	}

	X "$indent<Column uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $name)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $synonym
	X "$indent`t`t<Comment/>"
	X "$indent`t`t<Indexing>$indexing</Indexing>"
	if ($references.Count -gt 0) {
		X "$indent`t`t<References>"
		foreach ($ref in $references) {
			X "$indent`t`t`t<xr:Item xsi:type=`"xr:MDObjectRef`">$ref</xr:Item>"
		}
		X "$indent`t`t</References>"
	} else {
		X "$indent`t`t<References/>"
	}
	X "$indent`t</Properties>"
	X "$indent</Column>"
}

function Emit-AccountingFlag {
	param([string]$indent, [string]$flagName)
	$uuid = New-Guid-String
	$flagSynonym = Split-CamelCase $flagName

	X "$indent<AccountingFlag uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $flagName)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $flagSynonym
	X "$indent`t`t<Comment/>"
	X "$indent`t`t<Type>"
	X "$indent`t`t`t<v8:Type>xs:boolean</v8:Type>"
	X "$indent`t`t</Type>"
	X "$indent`t`t<PasswordMode>false</PasswordMode>"
	X "$indent`t`t<Format/>"
	X "$indent`t`t<EditFormat/>"
	X "$indent`t`t<ToolTip/>"
	X "$indent`t`t<MarkNegatives>false</MarkNegatives>"
	X "$indent`t`t<Mask/>"
	X "$indent`t`t<MultiLine>false</MultiLine>"
	X "$indent`t`t<ExtendedEdit>false</ExtendedEdit>"
	X "$indent`t`t<MinValue xsi:nil=`"true`"/>"
	X "$indent`t`t<MaxValue xsi:nil=`"true`"/>"
	X "$indent`t`t<FillChecking>DontCheck</FillChecking>"
	X "$indent`t`t<ChoiceParameterLinks/>"
	X "$indent`t`t<ChoiceParameters/>"
	X "$indent`t`t<QuickChoice>Auto</QuickChoice>"
	X "$indent`t`t<ChoiceForm/>"
	X "$indent`t`t<LinkByType/>"
	X "$indent`t`t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
	X "$indent`t</Properties>"
	X "$indent</AccountingFlag>"
}

function Emit-ExtDimensionAccountingFlag {
	param([string]$indent, [string]$flagName)
	$uuid = New-Guid-String
	$flagSynonym = Split-CamelCase $flagName

	X "$indent<ExtDimensionAccountingFlag uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $flagName)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $flagSynonym
	X "$indent`t`t<Comment/>"
	X "$indent`t`t<Type>"
	X "$indent`t`t`t<v8:Type>xs:boolean</v8:Type>"
	X "$indent`t`t</Type>"
	X "$indent`t`t<PasswordMode>false</PasswordMode>"
	X "$indent`t`t<Format/>"
	X "$indent`t`t<EditFormat/>"
	X "$indent`t`t<ToolTip/>"
	X "$indent`t`t<MarkNegatives>false</MarkNegatives>"
	X "$indent`t`t<Mask/>"
	X "$indent`t`t<MultiLine>false</MultiLine>"
	X "$indent`t`t<ExtendedEdit>false</ExtendedEdit>"
	X "$indent`t`t<MinValue xsi:nil=`"true`"/>"
	X "$indent`t`t<MaxValue xsi:nil=`"true`"/>"
	X "$indent`t`t<FillChecking>DontCheck</FillChecking>"
	X "$indent`t`t<ChoiceParameterLinks/>"
	X "$indent`t`t<ChoiceParameters/>"
	X "$indent`t`t<QuickChoice>Auto</QuickChoice>"
	X "$indent`t`t<ChoiceForm/>"
	X "$indent`t`t<LinkByType/>"
	X "$indent`t`t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"
	X "$indent`t</Properties>"
	X "$indent</ExtDimensionAccountingFlag>"
}

function Emit-URLTemplate {
	param([string]$indent, [string]$tmplName, $tmplDef)
	$uuid = New-Guid-String
	$tmplSynonym = Split-CamelCase $tmplName

	$template = ""
	$methods = @{}

	if ($tmplDef -is [string]) {
		$template = "$tmplDef"
	} else {
		$template = if ($tmplDef.template) { "$($tmplDef.template)" } else { "/$($tmplName.ToLower())" }
		if ($tmplDef.methods) {
			$tmplDef.methods.PSObject.Properties | ForEach-Object {
				$methods[$_.Name] = "$($_.Value)"
			}
		}
	}

	X "$indent<URLTemplate uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $tmplName)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $tmplSynonym
	X "$indent`t`t<Template>$(Esc-Xml $template)</Template>"
	X "$indent`t</Properties>"

	if ($methods.Count -gt 0) {
		X "$indent`t<ChildObjects>"
		foreach ($methodName in $methods.Keys) {
			$methodUuid = New-Guid-String
			$httpMethod = $methods[$methodName]
			$methodSynonym = Split-CamelCase $methodName
			$handler = "${tmplName}${methodName}"

			X "$indent`t`t<Method uuid=`"$methodUuid`">"
			X "$indent`t`t`t<Properties>"
			X "$indent`t`t`t`t<Name>$(Esc-Xml $methodName)</Name>"
			Emit-MLText "$indent`t`t`t`t" "Synonym" $methodSynonym
			X "$indent`t`t`t`t<HTTPMethod>$httpMethod</HTTPMethod>"
			X "$indent`t`t`t`t<Handler>$(Esc-Xml $handler)</Handler>"
			X "$indent`t`t`t</Properties>"
			X "$indent`t`t</Method>"
		}
		X "$indent`t</ChildObjects>"
	} else {
		X "$indent`t<ChildObjects/>"
	}

	X "$indent</URLTemplate>"
}

function Emit-Operation {
	param([string]$indent, [string]$opName, $opDef)
	$uuid = New-Guid-String
	$opSynonym = Split-CamelCase $opName

	$returnType = "xs:string"
	$nillable = "false"
	$transactioned = "false"
	$handler = $opName
	$params = @{}

	if ($opDef -is [string]) {
		$returnType = "$opDef"
	} else {
		if ($opDef.returnType) { $returnType = "$($opDef.returnType)" }
		if ($opDef.nillable -eq $true) { $nillable = "true" }
		if ($opDef.transactioned -eq $true) { $transactioned = "true" }
		if ($opDef.handler) { $handler = "$($opDef.handler)" }
		if ($opDef.parameters) {
			$opDef.parameters.PSObject.Properties | ForEach-Object {
				$params[$_.Name] = $_.Value
			}
		}
	}

	X "$indent<Operation uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $opName)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $opSynonym
	X "$indent`t`t<Comment/>"
	X "$indent`t`t<XDTOReturningValueType>$returnType</XDTOReturningValueType>"
	X "$indent`t`t<Nillable>$nillable</Nillable>"
	X "$indent`t`t<Transactioned>$transactioned</Transactioned>"
	X "$indent`t`t<ProcedureName>$(Esc-Xml $handler)</ProcedureName>"
	X "$indent`t</Properties>"

	if ($params.Count -gt 0) {
		X "$indent`t<ChildObjects>"
		foreach ($paramName in $params.Keys) {
			$paramUuid = New-Guid-String
			$paramDef = $params[$paramName]
			$paramSynonym = Split-CamelCase $paramName
			$paramType = "xs:string"
			$paramNillable = "true"
			$paramDir = "In"

			if ($paramDef -is [string]) {
				$paramType = "$paramDef"
			} else {
				if ($paramDef.type) { $paramType = "$($paramDef.type)" }
				if ($paramDef.nillable -eq $false) { $paramNillable = "false" }
				if ($paramDef.direction) { $paramDir = "$($paramDef.direction)" }
			}

			X "$indent`t`t<Parameter uuid=`"$paramUuid`">"
			X "$indent`t`t`t<Properties>"
			X "$indent`t`t`t`t<Name>$(Esc-Xml $paramName)</Name>"
			Emit-MLText "$indent`t`t`t`t" "Synonym" $paramSynonym
			X "$indent`t`t`t`t<XDTOValueType>$paramType</XDTOValueType>"
			X "$indent`t`t`t`t<Nillable>$paramNillable</Nillable>"
			X "$indent`t`t`t`t<TransferDirection>$paramDir</TransferDirection>"
			X "$indent`t`t`t</Properties>"
			X "$indent`t`t</Parameter>"
		}
		X "$indent`t</ChildObjects>"
	} else {
		X "$indent`t<ChildObjects/>"
	}

	X "$indent</Operation>"
}

function Emit-AddressingAttribute {
	param([string]$indent, $addrDef)
	$uuid = New-Guid-String

	$name = ""
	$attrSynonym = ""
	$typeStr = ""
	$addressingDimension = ""
	$indexing = "Index"

	$parsed = Parse-AttributeShorthand $addrDef
	$name = $parsed.name
	$attrSynonym = $parsed.synonym
	$typeStr = $parsed.type
	if ($addrDef -isnot [string]) {
		if ($addrDef.addressingDimension) { $addressingDimension = "$($addrDef.addressingDimension)" }
		if ($addrDef.indexing) { $indexing = "$($addrDef.indexing)" }
	}

	X "$indent<AddressingAttribute uuid=`"$uuid`">"
	X "$indent`t<Properties>"
	X "$indent`t`t<Name>$(Esc-Xml $name)</Name>"
	Emit-MLText "$indent`t`t" "Synonym" $attrSynonym
	X "$indent`t`t<Comment/>"

	if ($typeStr) {
		Emit-ValueType "$indent`t`t" $typeStr
	} else {
		X "$indent`t`t<Type>"
		X "$indent`t`t`t<v8:Type>xs:string</v8:Type>"
		X "$indent`t`t</Type>"
	}

	if ($addressingDimension) {
		X "$indent`t`t<AddressingDimension>$addressingDimension</AddressingDimension>"
	} else {
		X "$indent`t`t<AddressingDimension/>"
	}

	X "$indent`t`t<Indexing>$indexing</Indexing>"
	X "$indent`t`t<FullTextSearch>Use</FullTextSearch>"
	X "$indent`t`t<DataHistory>Use</DataHistory>"
	X "$indent`t</Properties>"
	X "$indent</AddressingAttribute>"
}

# --- 14. Namespaces ---

$script:xmlnsDecl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

# --- 14a. Detect format version from existing Configuration.xml ---

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$head = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8).Substring(0, [Math]::Min(2000, (Get-Item $cfgPath).Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

$script:formatVersion = Detect-FormatVersion $OutputDir

# --- 15. Main assembler ---

$uuid = New-Guid-String

# XML declaration
X '<?xml version="1.0" encoding="UTF-8"?>'
X "<MetaDataObject $($script:xmlnsDecl) version=`"$($script:formatVersion)`">"
X "`t<$objType uuid=`"$uuid`">"

# InternalInfo
Emit-InternalInfo "`t`t" $objType $objName

# Properties
X "`t`t<Properties>"

switch ($objType) {
	"Catalog"                    { Emit-CatalogProperties "`t`t`t" }
	"Document"                   { Emit-DocumentProperties "`t`t`t" }
	"Enum"                       { Emit-EnumProperties "`t`t`t" }
	"Constant"                   { Emit-ConstantProperties "`t`t`t" }
	"InformationRegister"        { Emit-InformationRegisterProperties "`t`t`t" }
	"AccumulationRegister"       { Emit-AccumulationRegisterProperties "`t`t`t" }
	"DefinedType"                { Emit-DefinedTypeProperties "`t`t`t" }
	"CommonModule"               { Emit-CommonModuleProperties "`t`t`t" }
	"ScheduledJob"               { Emit-ScheduledJobProperties "`t`t`t" }
	"EventSubscription"          { Emit-EventSubscriptionProperties "`t`t`t" }
	"Report"                     { Emit-ReportProperties "`t`t`t" }
	"DataProcessor"              { Emit-DataProcessorProperties "`t`t`t" }
	"ExchangePlan"               { Emit-ExchangePlanProperties "`t`t`t" }
	"ChartOfCharacteristicTypes" { Emit-ChartOfCharacteristicTypesProperties "`t`t`t" }
	"DocumentJournal"            { Emit-DocumentJournalProperties "`t`t`t" }
	"ChartOfAccounts"            { Emit-ChartOfAccountsProperties "`t`t`t" }
	"AccountingRegister"         { Emit-AccountingRegisterProperties "`t`t`t" }
	"ChartOfCalculationTypes"    { Emit-ChartOfCalculationTypesProperties "`t`t`t" }
	"CalculationRegister"        { Emit-CalculationRegisterProperties "`t`t`t" }
	"BusinessProcess"            { Emit-BusinessProcessProperties "`t`t`t" }
	"Task"                       { Emit-TaskProperties "`t`t`t" }
	"HTTPService"                { Emit-HTTPServiceProperties "`t`t`t" }
	"WebService"                 { Emit-WebServiceProperties "`t`t`t" }
}

X "`t`t</Properties>"

# ChildObjects
$hasChildren = $false

# --- Types with Attributes + TabularSections ---
$typesWithAttrTS = @("Catalog","Document","Report","DataProcessor","ExchangePlan",
	"ChartOfCharacteristicTypes","ChartOfAccounts","ChartOfCalculationTypes",
	"BusinessProcess","Task")

if ($objType -in $typesWithAttrTS) {
	$attrs = @()
	if ($def.attributes) {
		foreach ($a in $def.attributes) {
			$attrs += Parse-AttributeShorthand $a
		}
	}
	$tsSections = [ordered]@{}
	if ($def.tabularSections) {
		# Значение ТЧ: массив колонок (синоним авто) ЛИБО объект {attributes/columns, synonym, tooltip, comment}.
		# Нормализуем в $tsSections[name] = @{ columns; synonym; tooltip; comment }.
		function New-TsEntry { param($val)
			if ($val -is [array] -or $val.GetType().Name -eq 'Object[]') {
				return @{ columns = @($val); synonym = $null; tooltip = $null; comment = $null; lineNumber = $null }
			}
			$cols = if ($val.attributes) { @($val.attributes) } elseif ($val.columns) { @($val.columns) } else { @() }
			return @{ columns = $cols; synonym = $val.synonym; tooltip = $val.tooltip; comment = if ($val.comment) { "$($val.comment)" } else { $null }; lineNumber = $val.lineNumber }
		}
		if ($def.tabularSections -is [array] -or $def.tabularSections.GetType().Name -eq "Object[]") {
			foreach ($ts in $def.tabularSections) { $tsSections[$ts.name] = New-TsEntry $ts }
		} else {
			$def.tabularSections.PSObject.Properties | ForEach-Object { $tsSections[$_.Name] = New-TsEntry $_.Value }
		}
	}

	# ChartOfAccounts: AccountingFlags + ExtDimensionAccountingFlags
	$acctFlags = @()
	$extDimFlags = @()
	if ($objType -eq "ChartOfAccounts") {
		if ($def.accountingFlags) { $acctFlags = @($def.accountingFlags) }
		if ($def.extDimensionAccountingFlags) { $extDimFlags = @($def.extDimensionAccountingFlags) }
	}

	# Task: AddressingAttributes
	$addrAttrs = @()
	if ($objType -eq "Task" -and $def.addressingAttributes) {
		$addrAttrs = @($def.addressingAttributes)
	}

	# Commands (map имя→объект ИЛИ array [{name,...}]) — генерируем блок + CommandModule.bsl-заготовку.
	$commands = @()
	if ($def.commands) {
		if ($def.commands -is [array] -or $def.commands.GetType().Name -eq 'Object[]') {
			foreach ($c in $def.commands) { $commands += @{ name = "$($c.name)"; def = $c } }
		} else {
			$def.commands.PSObject.Properties | ForEach-Object { $commands += @{ name = $_.Name; def = $_.Value } }
		}
	}
	$childCount = $attrs.Count + $tsSections.Count + $acctFlags.Count + $extDimFlags.Count + $addrAttrs.Count + $commands.Count
	if ($childCount -gt 0) {
		$hasChildren = $true
		X "`t`t<ChildObjects>"
		$context = switch ($objType) {
			"Catalog"  { "catalog" }
			"Document" { "document" }
			{ $_ -in @("DataProcessor","Report") } { "processor" }
			"ChartOfCharacteristicTypes" { "catalog" }   # реквизиты ПВХ структурно как у справочника (Use/FillFromFillingValue/DataHistory)
			{ $_ -in @("ChartOfAccounts","ChartOfCalculationTypes") } { "chart" }
			default    { "object" }
		}
		foreach ($a in $attrs) {
			Emit-Attribute "`t`t`t" $a $context
		}
		foreach ($tsName in $tsSections.Keys) {
			$tsE = $tsSections[$tsName]
			Emit-TabularSection "`t`t`t" $tsName $tsE.columns $objType $objName $tsE.synonym $tsE.tooltip $tsE.comment $tsE.lineNumber
		}
		foreach ($af in $acctFlags) {
			$afName = if ($af.name) { $af.name } else { "$af" }
			Emit-AccountingFlag "`t`t`t" $afName
		}
		foreach ($edf in $extDimFlags) {
			$edfName = if ($edf.name) { $edf.name } else { "$edf" }
			Emit-ExtDimensionAccountingFlag "`t`t`t" $edfName
		}
		foreach ($aa in $addrAttrs) {
			Emit-AddressingAttribute "`t`t`t" $aa
		}
		foreach ($cmd in $commands) {
			Emit-Command "`t`t`t" $cmd.name $cmd.def
		}
		X "`t`t</ChildObjects>"
	} else {
		X "`t`t<ChildObjects/>"
	}
}

# --- Enum: enum values ---
if ($objType -eq "Enum") {
	$values = @()
	if ($def.values) {
		foreach ($v in $def.values) {
			$values += Parse-EnumValueShorthand $v
		}
	}
	if ($values.Count -gt 0) {
		$hasChildren = $true
		X "`t`t<ChildObjects>"
		foreach ($v in $values) {
			Emit-EnumValue "`t`t`t" $v
		}
		X "`t`t</ChildObjects>"
	} else {
		X "`t`t<ChildObjects/>"
	}
}

# --- Constant, DefinedType, ScheduledJob, EventSubscription: no ChildObjects ---

# --- Registers: dimensions + resources + attributes ---
if ($objType -in @("InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister")) {
	$dims = @()
	$resources = @()
	$regAttrs = @()
	if ($def.dimensions) {
		foreach ($d in $def.dimensions) {
			$dims += Parse-AttributeShorthand $d
		}
	}
	if ($def.resources) {
		foreach ($r in $def.resources) {
			$resources += Parse-AttributeShorthand $r
		}
	}
	if ($def.attributes) {
		foreach ($a in $def.attributes) {
			$regAttrs += Parse-AttributeShorthand $a
		}
	}

	if ($dims.Count -gt 0 -or $resources.Count -gt 0 -or $regAttrs.Count -gt 0) {
		$hasChildren = $true
		X "`t`t<ChildObjects>"
		foreach ($r in $resources) {
			Emit-Resource "`t`t`t" $r $objType
		}
		foreach ($d in $dims) {
			Emit-Dimension "`t`t`t" $d $objType
		}
		# InformationRegister.Attribute supports FillFromFillingValue/FillValue/DataHistory;
		# AccumulationRegister/AccountingRegister/CalculationRegister.Attribute do NOT.
		$regCtx = if ($objType -eq "InformationRegister") { "register-info" } else { "register-other" }
		foreach ($a in $regAttrs) {
			Emit-Attribute "`t`t`t" $a $regCtx
		}
		X "`t`t</ChildObjects>"
	} else {
		X "`t`t<ChildObjects/>"
	}
}

# --- DocumentJournal: columns ---
if ($objType -eq "DocumentJournal") {
	$columns = @()
	if ($def.columns) { $columns = @($def.columns) }
	if ($columns.Count -gt 0) {
		$hasChildren = $true
		X "`t`t<ChildObjects>"
		foreach ($col in $columns) {
			Emit-Column "`t`t`t" $col
		}
		X "`t`t</ChildObjects>"
	} else {
		X "`t`t<ChildObjects/>"
	}
}

# --- HTTPService: URLTemplates ---
if ($objType -eq "HTTPService") {
	$urlTemplates = @{}
	if ($def.urlTemplates) {
		$def.urlTemplates.PSObject.Properties | ForEach-Object {
			$urlTemplates[$_.Name] = $_.Value
		}
	}
	if ($urlTemplates.Count -gt 0) {
		$hasChildren = $true
		X "`t`t<ChildObjects>"
		foreach ($tmplName in $urlTemplates.Keys) {
			Emit-URLTemplate "`t`t`t" $tmplName $urlTemplates[$tmplName]
		}
		X "`t`t</ChildObjects>"
	} else {
		X "`t`t<ChildObjects/>"
	}
}

# --- WebService: Operations ---
if ($objType -eq "WebService") {
	$operations = @{}
	if ($def.operations) {
		$def.operations.PSObject.Properties | ForEach-Object {
			$operations[$_.Name] = $_.Value
		}
	}
	if ($operations.Count -gt 0) {
		$hasChildren = $true
		X "`t`t<ChildObjects>"
		foreach ($opName in $operations.Keys) {
			Emit-Operation "`t`t`t" $opName $operations[$opName]
		}
		X "`t`t</ChildObjects>"
	} else {
		X "`t`t<ChildObjects/>"
	}
}

# --- CommonModule: no ChildObjects ---

X "`t</$objType>"
X "</MetaDataObject>"

$metadataXml = $script:xml.ToString()

# --- 16. Write files ---

# Type → plural directory mapping
$script:typePluralMap = @{
	"Catalog"                   = "Catalogs"
	"Document"                  = "Documents"
	"Enum"                      = "Enums"
	"Constant"                  = "Constants"
	"InformationRegister"       = "InformationRegisters"
	"AccumulationRegister"      = "AccumulationRegisters"
	"AccountingRegister"        = "AccountingRegisters"
	"CalculationRegister"       = "CalculationRegisters"
	"ChartOfAccounts"           = "ChartsOfAccounts"
	"ChartOfCharacteristicTypes"= "ChartsOfCharacteristicTypes"
	"ChartOfCalculationTypes"   = "ChartsOfCalculationTypes"
	"BusinessProcess"           = "BusinessProcesses"
	"Task"                      = "Tasks"
	"ExchangePlan"              = "ExchangePlans"
	"DocumentJournal"           = "DocumentJournals"
	"Report"                    = "Reports"
	"DataProcessor"             = "DataProcessors"
	"CommonModule"              = "CommonModules"
	"ScheduledJob"              = "ScheduledJobs"
	"EventSubscription"         = "EventSubscriptions"
	"HTTPService"               = "HTTPServices"
	"WebService"                = "WebServices"
	"DefinedType"               = "DefinedTypes"
}

$typePlural = $script:typePluralMap[$objType]
$typeDir = Join-Path $OutputDir $typePlural

# Main XML file: {OutputDir}/{TypePlural}/{Name}.xml
$mainXmlPath = Join-Path $typeDir "$objName.xml"

# Types that don't have subdirectory structure (no Ext/, no modules)
$typesNoSubDir = @("DefinedType","ScheduledJob","EventSubscription")

# Object subdirectory: {OutputDir}/{TypePlural}/{Name}/Ext/
$objSubDir = Join-Path $typeDir $objName
# --- Predefined data (Ext/Predefined.xml) ---
# Элемент DSL: строка "(Код) Имя [Наименование]" ЛИБО объект (+ русские синонимы ключей).
# Наименование: нет [..]/ключа → авто(Split-CamelCase Имени); [] / "" → пусто; [текст]/текст → как есть.
function Resolve-PredefItem {
	param($val)
	if ($val -is [string]) {
		$m = [regex]::Match($val, '^\s*(?:\(([^)]*)\)\s*)?(\S+)(?:\s*\[(.*)\])?\s*$')
		$name = $m.Groups[2].Value
		$code = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' }
		$desc = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { Split-CamelCase $name }
		return @{ name = $name; code = $code; desc = $desc; isFolder = $false; children = @(); type = $null }
	}
	# Объектная форма + русские синонимы (прощающий ввод).
	$gv = { param($o, [string[]]$keys) foreach ($k in $keys) { if ($o.PSObject.Properties[$k]) { return $o.$k } } return $null }
	$name = "$(& $gv $val @('name','имя'))"
	$codeV = & $gv $val @('code','код')
	$code = if ($null -ne $codeV) { "$codeV" } else { '' }
	$hasDesc = $val.PSObject.Properties['description'] -or $val.PSObject.Properties['наименование']
	$descV = & $gv $val @('description','наименование')
	$desc = if ($hasDesc) { "$descV" } else { Split-CamelCase $name }   # ключа нет → авто; '' → пусто
	$folderV = & $gv $val @('isFolder','группа')
	$isFolder = ($folderV -eq $true)
	$subs = & $gv $val @('childItems','подчиненные')
	$typeV = & $gv $val @('type','тип')   # тип значения характеристики (ПВХ): строка "A + B" ИЛИ массив
	if ($typeV -is [System.Array]) { $typeV = ($typeV -join ' + ') }
	return @{ name = $name; code = $code; desc = $desc; isFolder = $isFolder; children = @(if ($subs) { $subs } else { @() }); type = $typeV }
}
function Emit-PredefItem {
	param($sb, $val, [string]$indent, [string]$codeType)
	$r = Resolve-PredefItem $val
	[void]$sb.Append("$indent<Item id=`"$(New-Guid-String)`">`n")
	[void]$sb.Append("$indent`t<Name>$(Esc-XmlText $r.name)</Name>`n")
	if (-not $r.code) { [void]$sb.Append("$indent`t<Code/>`n") }
	elseif ($codeType -eq 'Number') { [void]$sb.Append("$indent`t<Code xsi:type=`"xs:decimal`">$(Esc-XmlText $r.code)</Code>`n") }
	else { [void]$sb.Append("$indent`t<Code>$(Esc-XmlText $r.code)</Code>`n") }
	if ($r.desc -eq '') { [void]$sb.Append("$indent`t<Description/>`n") }
	else { [void]$sb.Append("$indent`t<Description>$(Esc-XmlText $r.desc)</Description>`n") }
	# Type — тип значения предопределённой характеристики (ПВХ); между Description и IsFolder.
	# type=$null → блока нет (Catalog); type='' → пустой <Type/>; type='A + B' → наполненный.
	if ($null -ne $r.type -and "$($r.type)" -eq '') { [void]$sb.Append("$indent`t<Type/>`n") }
	elseif ($r.type) {
		[void]$sb.Append("$indent`t<Type>`n")
		$tmp = New-Object System.Text.StringBuilder
		$saveXml = $script:xml; $script:xml = $tmp
		Emit-TypeContent "$indent`t`t" "$($r.type)"
		$script:xml = $saveXml
		[void]$sb.Append(($tmp.ToString() -replace "`r`n", "`n"))
		[void]$sb.Append("$indent`t</Type>`n")
	}
	[void]$sb.Append("$indent`t<IsFolder>$(if ($r.isFolder) { 'true' } else { 'false' })</IsFolder>`n")
	if ($r.children.Count -gt 0) {
		[void]$sb.Append("$indent`t<ChildItems>`n")
		foreach ($c in $r.children) { Emit-PredefItem $sb $c "$indent`t`t" $codeType }
		[void]$sb.Append("$indent`t</ChildItems>`n")
	}
	[void]$sb.Append("$indent</Item>`n")
}
function Build-PredefinedXml {
	param($items, [string]$xsiType, [string]$codeType)
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.Append("<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n")
	[void]$sb.Append("<PredefinedData xmlns=`"http://v8.1c.ru/8.3/xcf/predef`" xmlns:v8=`"http://v8.1c.ru/8.1/data/core`" xmlns:xr=`"http://v8.1c.ru/8.3/xcf/readable`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xsi:type=`"$xsiType`" version=`"$($script:formatVersion)`">`n")
	foreach ($it in $items) { Emit-PredefItem $sb $it "`t" $codeType }
	[void]$sb.Append("</PredefinedData>`n")
	return $sb.ToString()
}

$extDir = Join-Path $objSubDir "Ext"

if (-not (Test-Path $typeDir)) {
	New-Item -ItemType Directory -Path $typeDir -Force | Out-Null
}
if ($objType -notin $typesNoSubDir) {
	if (-not (Test-Path $objSubDir)) {
		New-Item -ItemType Directory -Path $objSubDir -Force | Out-Null
	}
}

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($mainXmlPath, $metadataXml, $enc)

# Module files
$modulesCreated = @()

# Helper: create Ext/ only when needed (avoids empty Ext/ for Constant, Enum, etc.)
function Ensure-ExtDir {
	if (-not (Test-Path $extDir)) {
		New-Item -ItemType Directory -Path $extDir -Force | Out-Null
	}
}

# Types with ObjectModule.bsl
$typesWithObjectModule = @("Catalog","Document","Report","DataProcessor","ExchangePlan",
	"ChartOfAccounts","ChartOfCharacteristicTypes","ChartOfCalculationTypes",
	"BusinessProcess","Task")
# Types with RecordSetModule.bsl
$typesWithRecordSetModule = @("InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister")
# Types with ManagerModule.bsl
$typesWithManagerModule = @("Report","DataProcessor","Constant","Enum")
# Types with ValueManagerModule.bsl
$typesWithValueManagerModule = @("Constant")
# Types with Module.bsl (general)
$typesWithModule = @("CommonModule","HTTPService","WebService")

if ($objType -in $typesWithObjectModule) {
	$modulePath = Join-Path $extDir "ObjectModule.bsl"
	if (-not (Test-Path $modulePath)) {
		Ensure-ExtDir
		[System.IO.File]::WriteAllText($modulePath, "", $enc)
		$modulesCreated += $modulePath
	}
}
if ($objType -in $typesWithManagerModule) {
	$modulePath = Join-Path $extDir "ManagerModule.bsl"
	if (-not (Test-Path $modulePath)) {
		Ensure-ExtDir
		[System.IO.File]::WriteAllText($modulePath, "", $enc)
		$modulesCreated += $modulePath
	}
}
if ($objType -in $typesWithValueManagerModule) {
	$modulePath = Join-Path $extDir "ValueManagerModule.bsl"
	if (-not (Test-Path $modulePath)) {
		Ensure-ExtDir
		[System.IO.File]::WriteAllText($modulePath, "", $enc)
		$modulesCreated += $modulePath
	}
}
if ($objType -in $typesWithRecordSetModule) {
	$modulePath = Join-Path $extDir "RecordSetModule.bsl"
	if (-not (Test-Path $modulePath)) {
		Ensure-ExtDir
		[System.IO.File]::WriteAllText($modulePath, "", $enc)
		$modulesCreated += $modulePath
	}
}
if ($objType -in $typesWithModule) {
	$modulePath = Join-Path $extDir "Module.bsl"
	if (-not (Test-Path $modulePath)) {
		Ensure-ExtDir
		[System.IO.File]::WriteAllText($modulePath, "", $enc)
		$modulesCreated += $modulePath
	}
}

# Special files
if ($objType -eq "ExchangePlan") {
	$contentPath = Join-Path $extDir "Content.xml"
	if (-not (Test-Path $contentPath)) {
		Ensure-ExtDir
		$contentXml = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<ExchangePlanContent xmlns=`"http://v8.1c.ru/8.3/xcf/extrnprops`" xmlns:xr=`"http://v8.1c.ru/8.3/xcf/readable`" version=`"$($script:formatVersion)`"/>`r`n"
		[System.IO.File]::WriteAllText($contentPath, $contentXml, $enc)
		$modulesCreated += $contentPath
	}
}
if ($objType -eq "BusinessProcess") {
	$flowchartPath = Join-Path $extDir "Flowchart.xml"
	if (-not (Test-Path $flowchartPath)) {
		Ensure-ExtDir
		$flowchartXml = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<Flowchart xmlns=`"http://v8.1c.ru/8.3/MDClasses`" version=`"$($script:formatVersion)`"/>`r`n"
		[System.IO.File]::WriteAllText($flowchartPath, $flowchartXml, $enc)
		$modulesCreated += $flowchartPath
	}
}

# Предопределённые элементы (Ext/Predefined.xml). Root-элемент — по типу. Пусто/нет ключа → файл не создаём.
$predefRootByType = @{ 'Catalog' = 'CatalogPredefinedItems'; 'ChartOfCharacteristicTypes' = 'PlanOfCharacteristicKindPredefinedItems' }
if ($predefRootByType.ContainsKey($objType) -and $def.predefined -and @($def.predefined).Count -gt 0) {
	Ensure-ExtDir
	$catCodeType = if ($def.codeType) { "$($def.codeType)" } else { 'String' }
	$predefXml = Build-PredefinedXml @($def.predefined) $predefRootByType[$objType] $catCodeType
	$predefPath = Join-Path $extDir "Predefined.xml"
	[System.IO.File]::WriteAllText($predefPath, $predefXml, $enc)
	$modulesCreated += $predefPath
}

# Модули команд (Commands/<Имя>/Ext/CommandModule.bsl) — заготовка обработчика.
if ($commands -and $commands.Count -gt 0) {
	$cmdModuleStub = "&НаКлиенте`r`nПроцедура ОбработкаКоманды(ПараметрКоманды, ПараметрыВыполненияКоманды)`r`n`r`n`t// Вставьте обработчик команды.`r`n`r`nКонецПроцедуры`r`n"
	foreach ($cmd in $commands) {
		$cmdDir = Join-Path (Join-Path (Join-Path $objSubDir "Commands") $cmd.name) "Ext"
		if (-not (Test-Path $cmdDir)) { New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null }
		$cmdModPath = Join-Path $cmdDir "CommandModule.bsl"
		[System.IO.File]::WriteAllText($cmdModPath, $cmdModuleStub, $enc)
		$modulesCreated += $cmdModPath
	}
}

# --- 17. Register in Configuration.xml ---

$configXmlPath = Join-Path $OutputDir "Configuration.xml"
$regResult = $null

# XML tag name for Configuration.xml ChildObjects
$childTag = $objType

if (Test-Path $configXmlPath) {
	$configDoc = New-Object System.Xml.XmlDocument
	$configDoc.PreserveWhitespace = $true
	$configDoc.Load($configXmlPath)

	$nsMgr = New-Object System.Xml.XmlNamespaceManager($configDoc.NameTable)
	$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

	$childObjects = $configDoc.SelectSingleNode("//md:Configuration/md:ChildObjects", $nsMgr)
	if ($childObjects) {
		$existing = $childObjects.SelectNodes("md:$childTag", $nsMgr)
		$alreadyExists = $false
		foreach ($e in $existing) {
			if ($e.InnerText -eq $objName) {
				$alreadyExists = $true
				break
			}
		}

		if ($alreadyExists) {
			$regResult = "already"
		} else {
			$newElem = $configDoc.CreateElement($childTag, "http://v8.1c.ru/8.3/MDClasses")
			$newElem.InnerText = $objName

			if ($existing.Count -gt 0) {
				# Insert after last existing element of same type
				$lastElem = $existing[$existing.Count - 1]
				$newWs = $configDoc.CreateWhitespace("`n`t`t`t")
				$childObjects.InsertAfter($newWs, $lastElem) | Out-Null
				$childObjects.InsertAfter($newElem, $newWs) | Out-Null
			} else {
				# No existing elements of this type — insert before closing whitespace
				$lastChild = $childObjects.LastChild
				if ($lastChild.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
					$newWs = $configDoc.CreateWhitespace("`n`t`t`t")
					$childObjects.InsertBefore($newWs, $lastChild) | Out-Null
					$childObjects.InsertBefore($newElem, $lastChild) | Out-Null
				} else {
					$childObjects.AppendChild($configDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
					$childObjects.AppendChild($newElem) | Out-Null
					$childObjects.AppendChild($configDoc.CreateWhitespace("`n`t`t")) | Out-Null
				}
			}

			# Save
			$cfgSettings = New-Object System.Xml.XmlWriterSettings
			$cfgSettings.Encoding = New-Object System.Text.UTF8Encoding($true)
			$cfgSettings.Indent = $false
			$stream = New-Object System.IO.FileStream($configXmlPath, [System.IO.FileMode]::Create)
			$writer = [System.Xml.XmlWriter]::Create($stream, $cfgSettings)
			$configDoc.Save($writer)
			$writer.Close()
			$stream.Close()

			$regResult = "added"
		}
	} else {
		$regResult = "no-childobj"
	}
} else {
	$regResult = "no-config"
}

# --- 18. Summary ---

$attrCount = 0
$tsCount = 0
$dimCount = 0
$resCount = 0
$valCount = 0
$colCount = 0

if ($def.attributes) { $attrCount = @($def.attributes).Count }
if ($def.tabularSections) {
	if ($def.tabularSections -is [array] -or $def.tabularSections.GetType().Name -eq "Object[]") {
		$tsCount = @($def.tabularSections).Count
	} else {
		$tsCount = @($def.tabularSections.PSObject.Properties).Count
	}
}
if ($def.dimensions) { $dimCount = @($def.dimensions).Count }
if ($def.resources) { $resCount = @($def.resources).Count }
if ($def.values) { $valCount = @($def.values).Count }
if ($def.columns) { $colCount = @($def.columns).Count }

Write-Host "[OK] $objType '$objName' compiled"
Write-Host "     UUID: $uuid"
Write-Host "     File: $mainXmlPath"

$details = @()
if ($attrCount -gt 0) { $details += "Attributes: $attrCount" }
if ($tsCount -gt 0)   { $details += "TabularSections: $tsCount" }
if ($dimCount -gt 0)  { $details += "Dimensions: $dimCount" }
if ($resCount -gt 0)  { $details += "Resources: $resCount" }
if ($valCount -gt 0)  { $details += "Values: $valCount" }
if ($colCount -gt 0)  { $details += "Columns: $colCount" }

if ($details.Count -gt 0) {
	Write-Host "     $($details -join ', ')"
}

foreach ($mc in $modulesCreated) {
	Write-Host "     Module: $mc"
}

switch ($regResult) {
	"added"       { Write-Host "     Configuration.xml: <$childTag>$objName</$childTag> added to ChildObjects" }
	"already"     { Write-Host "     Configuration.xml: <$childTag>$objName</$childTag> already registered" }
	"no-childobj" { Write-Warning "Configuration.xml found but <ChildObjects> not found" }
	"no-config"   { Write-Host "     Configuration.xml: not found at $configXmlPath (register manually)" }
}

# Cross-reference hints
if ($objType -eq "AccountingRegister" -and -not $def.chartOfAccounts) {
	Write-Host "[HINT] AccountingRegister requires ChartOfAccounts reference:"
	Write-Host "       /meta-edit -Operation modify-property -Value `"ChartOfAccounts=ChartOfAccounts.XXX`""
}
if ($objType -eq "CalculationRegister" -and -not $def.chartOfCalculationTypes) {
	Write-Host "[HINT] CalculationRegister requires ChartOfCalculationTypes reference:"
	Write-Host "       /meta-edit -Operation modify-property -Value `"ChartOfCalculationTypes=ChartOfCalculationTypes.XXX`""
}
if ($objType -eq "BusinessProcess" -and -not $def.task) {
	Write-Host "[HINT] BusinessProcess requires Task reference:"
	Write-Host "       /meta-edit -Operation modify-property -Value `"Task=Task.XXX`""
}
if ($objType -eq "ChartOfAccounts") {
	$maxExtDim = if ($null -ne $def.maxExtDimensionCount) { [int]$def.maxExtDimensionCount } else { 0 }
	if ($maxExtDim -gt 0 -and -not $def.extDimensionTypes) {
		Write-Host "[HINT] ChartOfAccounts with MaxExtDimensionCount>0 requires ExtDimensionTypes:"
		Write-Host "       /meta-edit -Operation modify-property -Value `"ExtDimensionTypes=ChartOfCharacteristicTypes.XXX`""
	}
}
