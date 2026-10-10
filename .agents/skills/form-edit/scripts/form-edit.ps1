# form-edit v1.29 — Edit 1C managed form elements
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$FormPath,

	[Parameter(Mandatory)]
	[string]$JsonPath
)

$ErrorActionPreference = "Stop"

# --- Разбор пользовательского JSON ---
# Одна строка в stderr вместо дампа исключения ConvertFrom-Json (issue #80): агент по стектрейсу
# идёт чинить скрипт, а не свой вызов. $source — файл или параметр. $expected заполняем только
# для полиморфного входа: у файла подсказка была бы наполнителем. -Inline печатает ещё и то,
# что доехало: у файла такого вопроса нет — путь назван, позицию дал парсер, файл на диске.
# Возврат через -NoEnumerate: без него одноэлементный
# JSON-массив разворачивался бы в скаляр вторым анруллингом.
function ConvertFrom-JsonInput([string]$text, [string]$source, [string]$expected, [switch]$Inline) {
	try {
		# PS 5.1 на пустой строке отдаёт $null, а не ошибку — навык уходил дальше с $null,
		# тогда как py-порт падал. Проверяем сами, чтобы порты вели себя одинаково.
		if ([string]::IsNullOrWhiteSpace($text)) { throw 'input is empty' }
		$parsed = $text | ConvertFrom-Json
	} catch {
		$what = if ($expected) { "$source expects $expected" } else { "Invalid JSON in $source" }
		if ($Inline) {
			$got = ($text -replace '\s+', ' ').Trim()
			$label = 'got'
			if (-not $got) { $got = '(empty)' }
			elseif ($got.Length -gt 60) { $label = 'got (first 60 chars)'; $got = $got.Substring(0, 60) }
			$what = "${what}, ${label}: ${got}"
		}
		[Console]::Error.WriteLine("[ERROR] ${what} ($($_.Exception.Message))")
		exit 1
	}
	Write-Output -NoEnumerate $parsed
}

# --- Чтение входного JSON-файла ---
# Кодировку берём из BOM — это объявление самого файла, а не догадка. Без BOM ждём строгий UTF-8:
# Get-Content -Encoding UTF8 на файле в cp1251 тихо меняет кириллицу на U+FFFD, JSON после этого
# разбирается успешно, и в конфигурацию уезжает имя из «замен». Кодовую страницу не подбираем:
# угаданное имя уйдёт в метаданные так же молча.
function Read-JsonInputFile([string]$path) {
	# Проверка здесь, а не по навыкам: часть навыков проверяла путь сама, часть — нет, и один и тот
	# же промах давал то внятную строку, то дамп MethodInvocationException. Навыки со своей
	# проверкой срабатывают раньше и сохраняют свой текст.
	if (-not (Test-Path -LiteralPath $path)) {
		[Console]::Error.WriteLine("[ERROR] File not found: $path")
		exit 1
	}
	if (Test-Path -LiteralPath $path -PathType Container) {
		[Console]::Error.WriteLine("[ERROR] Expected a JSON file, got a directory: $path")
		exit 1
	}
	$bytes = [System.IO.File]::ReadAllBytes($path)
	if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
		return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
		return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
		return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	try {
		return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
	} catch {
		$detail = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
		[Console]::Error.WriteLine("[ERROR] ${path} is not valid UTF-8: ${detail} - save the file as UTF-8, or add a BOM if it is UTF-16")
		exit 1
	}
}
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

# === 1. Load Form.xml ===

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}
if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$resolvedFormPath = (Resolve-Path $FormPath).Path
Assert-EditAllowed $resolvedFormPath 'editable'
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
try {
	$xmlDoc.Load($resolvedFormPath)
} catch {
	Write-Host "[ERROR] XML parse error: $($_.Exception.Message)"
	exit 1
}

$formNs = "http://v8.1c.ru/8.3/xcf/logform"
$v8Ns = "http://v8.1c.ru/8.1/data/core"
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("f", $formNs)
$nsMgr.AddNamespace("v8", $v8Ns)

$root = $xmlDoc.DocumentElement

# === 2. Load JSON ===

$def = ConvertFrom-JsonInput (Read-JsonInputFile $JsonPath) $JsonPath

# === 3. Form name + header ===

$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
$parentDir = [System.IO.Path]::GetDirectoryName($resolvedFormPath)
if ($parentDir) {
	$extDir = [System.IO.Path]::GetFileName($parentDir)
	if ($extDir -eq "Ext") {
		$formDir = [System.IO.Path]::GetDirectoryName($parentDir)
		if ($formDir) { $formName = [System.IO.Path]::GetFileName($formDir) }
	}
}

Write-Host "=== form-edit: $formName ==="
Write-Host ""

# === 4. Scan max IDs per pool ===

$script:nextElemId = 0
$script:nextAttrId = 0
$script:nextCmdId = 0

# Scan ALL element IDs via XPath (includes companions like ExtendedTooltip, ContextMenu)
$rootCI = $root.SelectSingleNode("f:ChildItems", $nsMgr)
if ($rootCI) {
	foreach ($elem in $rootCI.SelectNodes(".//*[@id]")) {
		$id = $elem.GetAttribute("id")
		if ($id -and $id -ne "-1") {
			try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
		}
	}
}
# Командная панель формы: сама (id=-1) и её кнопки — из того же пула, что и элементы
$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
if ($acb) {
	$acbIds = New-Object System.Collections.ArrayList
	[void]$acbIds.Add($acb.GetAttribute("id"))
	foreach ($elem in $acb.SelectNodes(".//*[@id]")) { [void]$acbIds.Add($elem.GetAttribute("id")) }
	foreach ($id in $acbIds) {
		if ($id -and $id -ne "-1") {
			try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
		}
	}
}

# Scan attribute IDs (including column IDs — same pool)
foreach ($attr in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
	$id = $attr.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextAttrId) { $script:nextAttrId = $intId } } catch {}
	}
	# Column IDs are in the same pool as attribute IDs
	foreach ($col in $attr.SelectNodes("f:Columns/f:Column", $nsMgr)) {
		$colId = $col.GetAttribute("id")
		if ($colId) {
			try { $intColId = [int]$colId; if ($intColId -gt $script:nextAttrId) { $script:nextAttrId = $intColId } } catch {}
		}
	}
}

# Scan command IDs
foreach ($cmd in $root.SelectNodes("f:Commands/f:Command", $nsMgr)) {
	$id = $cmd.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextCmdId) { $script:nextCmdId = $intId } } catch {}
	}
}

$script:nextElemId++
$script:nextAttrId++
$script:nextCmdId++

# --- 4b. Auto-detect extension mode (BaseForm present) ---
$script:isExtension = $false
$baseForm = $root.SelectSingleNode("f:BaseForm", $nsMgr)
if ($baseForm) {
	$script:isExtension = $true
	if ($script:nextAttrId -lt 1000000) { $script:nextAttrId = 1000000 }
	if ($script:nextCmdId -lt 1000000) { $script:nextCmdId = 1000000 }
	if ($script:nextElemId -lt 1000000) { $script:nextElemId = 1000000 }
}

function New-ElemId { $id = $script:nextElemId; $script:nextElemId++; return $id }
function New-AttrId { $id = $script:nextAttrId; $script:nextAttrId++; return $id }
function New-CmdId { $id = $script:nextCmdId; $script:nextCmdId++; return $id }

# For element emitters, New-Id = New-ElemId
function New-Id { return New-ElemId }

# === 5. Fragment helpers (StringBuilder + Emit-* from form-compile) ===

$script:xml = New-Object System.Text.StringBuilder 4096

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}


# --- Type emitter ---

$script:formTypeSynonyms = New-Object System.Collections.Hashtable
$script:formTypeSynonyms["строка"]   = "string"
$script:formTypeSynonyms["число"]    = "decimal"
$script:formTypeSynonyms["булево"]   = "boolean"
$script:formTypeSynonyms["дата"]     = "date"
$script:formTypeSynonyms["датавремя"]= "dateTime"
$script:formTypeSynonyms["number"]   = "decimal"
$script:formTypeSynonyms["bool"]     = "boolean"
$script:formTypeSynonyms["справочникссылка"]            = "CatalogRef"
$script:formTypeSynonyms["справочникобъект"]            = "CatalogObject"
$script:formTypeSynonyms["документссылка"]              = "DocumentRef"
$script:formTypeSynonyms["документобъект"]              = "DocumentObject"
$script:formTypeSynonyms["перечислениессылка"]           = "EnumRef"
$script:formTypeSynonyms["плансчетовссылка"]             = "ChartOfAccountsRef"
$script:formTypeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"
$script:formTypeSynonyms["планвидоврасчётассылка"]        = "ChartOfCalculationTypesRef"
$script:formTypeSynonyms["планвидоврасчетассылка"]        = "ChartOfCalculationTypesRef"
$script:formTypeSynonyms["планобменассылка"]              = "ExchangePlanRef"
$script:formTypeSynonyms["бизнеспроцессссылка"]           = "BusinessProcessRef"
$script:formTypeSynonyms["задачассылка"]                  = "TaskRef"
$script:formTypeSynonyms["определяемыйтип"]             = "DefinedType"

# Алиас на локальный словарь: тело Resolve-TypeStr ниже — общая реализация,
# одинаковая во всех навыках (реестр в tests/skills/check-inline-drift.mjs).
$script:typeSynonyms = $script:formTypeSynonyms


# --- Event handler name generator ---


# --- Element helpers ---


# Уникальность имён внутри JSON-определения (1С: своя коллекция — свой неймспейс).
function Assert-EditUnique {
	param([string]$name, [hashtable]$seen, [string]$ctx)
	if ($seen.ContainsKey($name)) {
		Write-Host "[ERROR] Duplicate $ctx '$name' in JSON definition — names must be unique in 1C form"
		exit 1
	}
	$seen[$name] = $true
}


# --- Element emitters ---


# --- Element dispatcher ---


# === 5b. Эмиттер элементов — общий с form-compile (эталон там; копии держит check-inline-drift) ===

$script:queryBaseDir = if ($JsonPath) { [System.IO.Path]::GetDirectoryName((Resolve-Path $JsonPath).Path) } else { (Get-Location).Path }

$script:fmtMarkupRe = '</>|<\s*(?:link|b|i|u|s|color|colorStyle|bgColor|bgColorStyle|font|fontSize|fontStyle|img)(?:\s|>)'

$script:CANON_FILTER_ID = 'dfcece9d-5077-440b-b6b3-45a5cb4538eb'

$script:CANON_ORDER_ID  = '88619765-ccb3-46c6-ac52-38e9c992ebd4'

$script:CANON_CA_ID     = 'b75fecce-942b-4aed-abc9-e6a02e460fb3'

$script:CANON_ITEMS_ID  = '911b6018-f537-43e8-a417-da56b22f9aec'

$script:comparisonTypes = @{
	"=" = "Equal"; "<>" = "NotEqual"
	">" = "Greater"; ">=" = "GreaterOrEqual"
	"<" = "Less"; "<=" = "LessOrEqual"
	"in" = "InList"; "notIn" = "NotInList"
	"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
	"contains" = "Contains"; "notContains" = "NotContains"
	"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
	"like" = "Like"; "notLike" = "NotLike"
	"подобно" = "Like"; "неподобно" = "NotLike"   # рус. синоним (хэш регистронезависим: ПОДОБНО=подобно)
	"filled" = "Filled"; "notFilled" = "NotFilled"
}

$script:calcRestrictMap = @{ 'noField'='field'; 'noFilter'='condition'; 'noCondition'='condition'; 'noGroup'='group'; 'noOrder'='order' }

$script:dcsCommonNs = 'http://v8.1c.ru/8.1/data-composition-system/common'

$script:knownInvalidTypes = @{
	"FormDataStructure"     = "Runtime type. Use object type without cfg: prefix (e.g. CatalogObject.Контрагенты, DocumentObject.Приход)"
	"FormDataCollection"    = "Runtime type. Use ValueTable"
	"FormDataTree"          = "Runtime type. Use ValueTree"
	"FormDataTreeItem"      = "Runtime type, not valid in XML"
	"FormDataCollectionItem"= "Runtime type, not valid in XML"
	"FormGroup"             = "UI element type, not a data type"
	"FormField"             = "UI element type, not a data type"
	"FormButton"            = "UI element type, not a data type"
	"FormDecoration"        = "UI element type, not a data type"
	"FormTable"             = "UI element type, not a data type"
}

$script:typeSynonyms = $script:formTypeSynonyms

$script:eventSuffixMap = @{
	"OnChange"             = "ПриИзменении"
	"StartChoice"          = "НачалоВыбора"
	"ChoiceProcessing"     = "ОбработкаВыбора"
	"AutoComplete"         = "АвтоПодбор"
	"Clearing"             = "Очистка"
	"Opening"              = "Открытие"
	"Click"                = "Нажатие"
	"OnActivateRow"        = "ПриАктивизацииСтроки"
	"BeforeAddRow"         = "ПередНачаломДобавления"
	"BeforeDeleteRow"      = "ПередУдалением"
	"BeforeRowChange"      = "ПередНачаломИзменения"
	"OnStartEdit"          = "ПриНачалеРедактирования"
	"OnEditEnd"            = "ПриОкончанииРедактирования"
	"Selection"            = "ВыборСтроки"
	"OnCurrentPageChange"  = "ПриСменеСтраницы"
	"TextEditEnd"          = "ОкончаниеВводаТекста"
	"URLProcessing"        = "ОбработкаНавигационнойСсылки"
	"DragStart"            = "НачалоПеретаскивания"
	"Drag"                 = "Перетаскивание"
	"DragCheck"            = "ПроверкаПеретаскивания"
	"Drop"                 = "Помещение"
	"AfterDeleteRow"       = "ПослеУдаления"
}

$script:knownEvents = @{
	"input"     = @("OnChange","StartChoice","ChoiceProcessing","AutoComplete","TextEditEnd","Clearing","Creating","EditTextChange")
	"check"     = @("OnChange")
	"radio"     = @("OnChange")
	"label"     = @("Click","URLProcessing")
	"labelField"= @("OnChange","StartChoice","ChoiceProcessing","Click","URLProcessing","Clearing")
	"table"     = @("Selection","BeforeAddRow","AfterDeleteRow","BeforeDeleteRow","OnActivateRow","OnEditEnd","OnStartEdit","BeforeRowChange","BeforeEditEnd","ValueChoice","OnActivateCell","OnActivateField","Drag","DragStart","DragCheck","DragEnd","OnGetDataAtServer","BeforeLoadUserSettingsAtServer","OnUpdateUserSettingSetAtServer","OnChange")
	"pages"     = @("OnCurrentPageChange")
	"page"      = @("OnCurrentPageChange")
	"button"    = @("Click")
	"picField"  = @("OnChange","StartChoice","ChoiceProcessing","Click","Clearing")
	"calendar"  = @("OnChange","OnActivate")
	"picture"   = @("Click")
	"cmdBar"    = @()
	"popup"     = @()
	"group"     = @()
}

$script:knownFormEvents = @("OnCreateAtServer","OnOpen","BeforeClose","OnClose","NotificationProcessing","ChoiceProcessing","OnReadAtServer","AfterWriteAtServer","BeforeWriteAtServer","AfterWrite","BeforeWrite","OnWriteAtServer","FillCheckProcessingAtServer","OnLoadDataFromSettingsAtServer","BeforeLoadDataFromSettingsAtServer","OnSaveDataInSettingsAtServer","ExternalEvent","OnReopen","Opening")

$script:companionStructKeys = @(
	'width','autoMaxWidth','maxWidth','height','autoMaxHeight','maxHeight','verticalAlign','titleHeight',
	'horizontalStretch','verticalStretch','horizontalAlign','groupHorizontalAlign','groupVerticalAlign',
	'visible','hidden','enabled','disabled','hyperlink','events','tooltip',
	'textColor','backColor','borderColor','font','border','цветтекста','цветфона','цветрамки','шрифт','рамка'
)

$script:additionTypeMap = [ordered]@{
	'searchString'  = @{ Tag = 'SearchStringAddition';  Type = 'SearchStringRepresentation'; Suffix = 'СтрокаПоиска' }
	'viewStatus'    = @{ Tag = 'ViewStatusAddition';    Type = 'ViewStatusRepresentation';   Suffix = 'СостояниеПросмотра' }
	'searchControl' = @{ Tag = 'SearchControlAddition'; Type = 'SearchControl';               Suffix = 'УправлениеПоиском' }
}

$script:additionKeySynonyms = @{
	'searchString'  = @('SearchStringAddition','SearchStringRepresentation','строкаПоиска','отображениеСтрокиПоиска')
	'viewStatus'    = @('ViewStatusAddition','ViewStatusRepresentation','состояниеПросмотра')
	'searchControl' = @('SearchControlAddition','SearchControl','управлениеПоиском')
}

$script:elementTypeStrOnlyKeys = @('commandBar','autoCommandBar','КоманднаяПанель')

$script:elementTypeSynonyms = @{
	"commandBar"        = "cmdBar"
	"autoCommandBar"    = "autoCmdBar"
	"КоманднаяПанель"   = "cmdBar"
	"InputField"        = "input"
	"ПолеВвода"         = "input"
	"CheckBoxField"     = "check"
	"ПолеФлажка"        = "check"
	"RadioButtonField"  = "radio"
	"ПолеПереключателя" = "radio"
	"radioButton"       = "radio"
	"PictureField"      = "picField"
	"ПолеКартинки"      = "picField"
	"LabelField"        = "labelField"
	"ПолеНадписи"       = "labelField"
	"CalendarField"     = "calendar"
	"ПолеКалендаря"     = "calendar"
	"LabelDecoration"   = "label"
	"Надпись"           = "label"
	"PictureDecoration" = "picture"
	"Картинка"          = "picture"
	"UsualGroup"        = "group"
	"Группа"            = "group"
	"ОбычнаяГруппа"     = "group"
	"ColumnGroup"       = "columnGroup"
	"ГруппаКолонок"     = "columnGroup"
	"Pages"             = "pages"
	"ГруппаСтраниц"     = "pages"
	"Page"              = "page"
	"Страница"          = "page"
	"Table"             = "table"
	"Таблица"           = "table"
	"Button"            = "button"
	"Кнопка"            = "button"
	"Popup"             = "popup"
	"ВсплывающееМеню"   = "popup"
	# Дополнения командной панели таблицы (тип-как-ключ) — forgiving: XML-тег/Type/рус.имя → канон
	"SearchStringAddition"       = "searchString"
	"SearchStringRepresentation" = "searchString"
	"строкаПоиска"               = "searchString"
	"отображениеСтрокиПоиска"    = "searchString"
	"Отображение строки поиска"  = "searchString"
	"ViewStatusAddition"         = "viewStatus"
	"ViewStatusRepresentation"   = "viewStatus"
	"состояниеПросмотра"         = "viewStatus"
	"Состояние просмотра"        = "viewStatus"
	"SearchControlAddition"      = "searchControl"
	"SearchControl"              = "searchControl"
	"управлениеПоиском"          = "searchControl"
	"Управление поиском"         = "searchControl"
	# Спец-поля (документ/датчик) — XML-имя/рус. → канон
	"SpreadSheetDocumentField"   = "spreadsheet"
	"ПолеТабличногоДокумента"    = "spreadsheet"
	"HTMLDocumentField"          = "html"
	"ПолеHTMLДокумента"          = "html"
	"TextDocumentField"          = "textDoc"
	"ПолеТекстовогоДокумента"    = "textDoc"
	"FormattedDocumentField"     = "formattedDoc"
	"ПолеФорматированногоДокумента" = "formattedDoc"
	"ProgressBarField"           = "progressBar"
	"ПолеИндикатора"             = "progressBar"
	"TrackBarField"              = "trackBar"
	"ПолеПолосыРегулирования"    = "trackBar"
	"ChartField"                 = "chart"
	"ПолеДиаграммы"              = "chart"
	"GanttChartField"            = "ganttChart"
	"ПолеДиаграммыГанта"         = "ganttChart"
	"GraphicalSchemaField"       = "graphicalSchema"
	"ПолеГрафическойСхемы"       = "graphicalSchema"
	"PlannerField"               = "planner"
	"ПолеПланировщика"           = "planner"
	"PeriodField"                = "periodField"
	"ПолеПериода"                = "periodField"
	"DendrogramField"            = "dendrogram"
	"ПолеДендрограммы"           = "dendrogram"
}

$script:validEnumValues = @{
	"AppearanceInCard" = @("Auto","Extended")
	"AppearanceMode" = @("Auto","CommandBar","UsualGroup")
	"AutoAddIncomplete" = @("true","false","auto")
	"AutoCapitalizationOnTextInput" = @("Auto","None","Words","Sentences","AllCharacters")
	"AutoChoiceIncomplete" = @("true","false","auto")
	"AutoCorrectionOnTextInput" = @("Auto","Use","DontUse")
	"AutoMarkIncomplete" = @("true","false","auto")
	"AutoSaveDataInSettings" = @("DontUse","Use")
	"AutoShowClearButtonMode" = @("Auto","Always","FilledOnly")
	"AutoShowOpenButtonMode" = @("Auto","Always","FilledOnly")
	"AutoShowState" = @("Auto","DontShow","Show","ShowOnComposition")
	"AutoTime" = @("DontUse","Last","First","CurrentOrLast","CurrentOrFirst")
	"AutoWidthInTable" = @("Auto","ByData","None","ByDataAndTitle")
	"AutofillHint" = @("DontUse","FullName","GivenName","FamilyName","MiddleName","NamePrefix","NameSuffix","Street","City","Region","Country","PostalCode","UserName","Password","NewPassword","OneTimeCode","Email","PhoneNumber","CreditCardNumber")
	"BackPictureEffect" = @("Auto","None","Semitransparency","SemitransparencyAndBlur")
	"BackgroundShowMode" = @("Auto","DontShow","ShowAndIncreaseSize","ShowAndDontIncreaseSize")
	"Behavior" = @("Usual","Collapsible","PopUp","Auto")
	"BehaviorOnHorizontalCompression" = @("Auto","HideItemsByImportance","MoveItemsByImportance")
	"ButtonImportance" = @("Main","Normal","Supplementary")
	"CardBehaviorOnVerticalCompression" = @("Auto","MoveItemsToSwipeablePages","HideItems")
	"CardPictureAndTitleAlign" = @("Auto","LeftHorizontallySidesVertically","CenterHorizontallySidesVertically","CenterHorizontallyCenterVertically")
	"CardRepresentationType" = @("Usual","Group")
	"CellActionsButtonViewMode" = @("Auto","DontShow","ShowOnHover")
	"CellHyperlinkDisplayVariant" = @("Auto","Always","OnRowHover")
	"CellHyperlinkRepresentation" = @("Auto","Show","DontShow")
	"CellHyperlinksRepresentation" = @("Auto","AutoForSingle","ForAll","DontShow")
	"CellMark" = @("None","ShapeUnderTextOval","IconCircle")
	"CheckBoxType" = @("Auto","CheckBox","Tumbler","Switcher")
	"ChildItemsTitleLocation" = @("Auto","Left","LeftIfPossible","Top")
	"ChildItemsWidth" = @("Auto","Equal","LeftWide","LeftWidest","LeftNarrow","LeftNarrowest")
	"ChildrenAlign" = @("Auto","None","ItemsLeftTitlesLeft","ItemsRightTitlesLeft","ItemsLeftTitlesRight","ItemsRightTitlesRight","TitlesLeftDataLeft","TitlesLeftDataRight","TitlesRightDataLeft","TitlesRightDataRight","TitlesLeftDataAuto")
	"ChoiceButton" = @("true","false","auto")
	"ChoiceButtonRepresentation" = @("Auto","ShowInDropList","ShowInDropListAndInInputField","ShowInInputField")
	"InputField.ChoiceFoldersAndItems" = @("Items","Folders","FoldersAndItems","Auto")
	"Table.ChoiceFoldersAndItems" = @("Items","Folders","FoldersAndItems")
	"ChoiceHistoryOnInput" = @("Auto","DontUse")
	"ChoiceListButton" = @("true","false","auto")
	"ClearButton" = @("true","false","auto")
	"CollapseItemsByImportanceVariant" = @("Auto","Use","DontUse")
	"CommandBarLocation" = @("None","Auto","Top","Bottom")
	"ComplexSettingsViewMode" = @("Show","DontShow")
	"ControlRepresentation" = @("TitleHyperlink","Picture","Button","ButtonInParentElement")
	"ConversationsRepresentation" = @("Auto","Show","DontShow")
	"CreateButton" = @("true","false","auto")
	"Pages.CurrentRowUse" = @("Use","DontUse","Auto")
	"Table.CurrentRowUse" = @("Auto","Choice","SelectionPresentation","SelectionPresentationAndChoice")
	"UsualGroup.CurrentRowUse" = @("Use","DontUse","Auto")
	"DisplayImportance" = @("Auto","VeryHigh","High","Usual","Low","VeryLow")
	"DrawingSelectionShowMode" = @("Show","DontShow","Auto")
	"DropListButton" = @("true","false","auto")
	"EditMode" = @("Directly","Enter","EnterOnInput","Auto")
	"EditTextUpdate" = @("Auto","DontUse","OnValueChange","Always")
	"EnterKeyBehavior" = @("ControlNavigation","DefaultButton")
	"EqualColumnsWidth" = @("true","false","auto")
	"EqualItemsWidth" = @("true","false","auto")
	"ExtendedEdit" = @("true","false","auto")
	"FileDragMode" = @("AsFile","AsFileRef")
	"FixInCard" = @("true","false","auto")
	"FixingInTable" = @("None","Left","Right")
	"FooterHorizontalAlign" = @("Left","Center","Right","Auto")
	"ColumnGroup.Group" = @("Horizontal","Vertical","InCell")
	"Form.Group" = @("Horizontal","Vertical","HorizontalIfPossible","AlwaysHorizontal","Auto","AutoScreenTypeSensitive")
	"Page.Group" = @("Horizontal","Vertical","HorizontalIfPossible","AlwaysHorizontal","Auto","AutoScreenTypeSensitive")
	"UsualGroup.Group" = @("Horizontal","Vertical","HorizontalIfPossible","AlwaysHorizontal","Auto","AutoScreenTypeSensitive")
	"GroupHorizontalAlign" = @("Left","Center","Right","Auto")
	"GroupVerticalAlign" = @("Top","Center","Bottom","Auto")
	"HeaderHorizontalAlign" = @("Left","Center","Right","Auto")
	"InputField.HeightControlVariant" = @("Auto","UseHeightInFormRows","UseContentHeight")
	"Table.HeightControlVariant" = @("Auto","UseHeightInFormRows","UseHeightInTableRows","UseContentHeight")
	"HierarchyPanelLocation" = @("Auto","None")
	"HorizontalAlign" = @("Left","Center","Right","Auto")
	"HorizontalLinesBWA" = @("true","false","auto")
	"HorizontalLocation" = @("Left","Center","Right","Auto")
	"Table.HorizontalScrollBar" = @("DontUse","UseAlways","AutoUse")
	"HorizontalSpacing" = @("Auto","None","Half","Single","OneAndHalf","Double")
	"AutoCommandBar.HorizontalStretch" = @("true","false","auto")
	"ButtonGroup.HorizontalStretch" = @("true","false","auto")
	"CheckBoxField.HorizontalStretch" = @("true","false","auto")
	"ColumnGroup.HorizontalStretch" = @("true","false","auto")
	"CommandBar.HorizontalStretch" = @("true","false","auto")
	"ContextMenu.HorizontalStretch" = @("true","false","auto")
	"InputField.HorizontalStretch" = @("true","false","auto")
	"LabelDecoration.HorizontalStretch" = @("true","false","auto")
	"LabelField.HorizontalStretch" = @("true","false","auto")
	"Page.HorizontalStretch" = @("true","false","auto")
	"Pages.HorizontalStretch" = @("true","false","auto")
	"PictureDecoration.HorizontalStretch" = @("true","false","auto")
	"Popup.HorizontalStretch" = @("true","false","auto")
	"RadioButtonField.HorizontalStretch" = @("true","false","auto")
	"UsualGroup.HorizontalStretch" = @("true","false","auto")
	"Importance" = @("Main","Normal","Supplementary")
	"IncompleteChoiceMode" = @("OnEnterPressed","OnActivate")
	"InitialListView" = @("Beginning","End","Auto")
	"InitialRowActivation" = @("Auto","Activate","NoActivate")
	"InitialTreeView" = @("NoExpand","ExpandTopLevel","ExpandAllLevels")
	"IntervalsSelectionMode" = @("Auto","Multiple","Single","None")
	"LocationInCommandBar" = @("Auto","InAdditionalSubmenu","InCommandBar","InCommandBarAndInAdditionalSubmenu")
	"MarkNegatives" = @("true","false","auto")
	"MarkRequiredComplete" = @("true","false","auto")
	"MarkingAppearance" = @("DontShow","TopLeft","BottomRight","BothSides")
	"MobileDeviceTableType" = @("Auto","List","Cards")
	"MultiLine" = @("true","false","auto")
	"MultipleValuePictureShape" = @("Auto","Rect","Circle","Square")
	"MultipleValuePictureSize" = @("Auto","Small","Medium","Large")
	"MultipleValuesHyperlink" = @("true","false","auto")
	"OnMainServerUnavalableBehavior" = @("Auto","MakeDisable","DontChangeBehavior")
	"OnScreenKeyboardReturnKeyText" = @("Auto","Return","Go","Join","Next","Search","Send","Done","Continue")
	"OnlyInAllActions" = @("true","false","auto")
	"OpenButton" = @("true","false","auto")
	"Orientation" = @("Horizontal","Vertical","HorizontalIfPossible")
	"Output" = @("Auto","Enable","Disable")
	"PagesRepresentation" = @("None","TabsOnTop","TabsOnBottom","TabsOnLeftHorizontal","TabsOnRightHorizontal","Swipe","Auto")
	"PasswordMode" = @("true","false","auto")
	"PictureLocation" = @("Auto","Left","Right","Top","Bottom")
	"PictureSize" = @("RealSize","Stretch","Proportionally","Tile","AutoSize","RealSizeIgnoreScale","AutoSizeIgnoreScale","ByFontSize")
	"PlacementArea" = @("mainCmdsLeft","autoCmds","userCmds","mainCmdsRight")
	"PointerType" = @("Special","Regular")
	"QuickChoice" = @("true","false","auto")
	"RadioButtonType" = @("Auto","RadioButtons","Tumbler")
	"RefreshRequest" = @("None","PullFromTop","PullFromBottom","PullFromTopOrBottom")
	"ReportFormType" = @("Main","Settings","Variant")
	"ReportResultViewMode" = @("Auto","Default","Compact")
	"Button.Representation" = @("Text","Picture","PictureAndText","Auto")
	"ButtonGroup.Representation" = @("Auto","Usual","Compact")
	"Popup.Representation" = @("Text","Picture","PictureAndText","Auto")
	"ProgressBarField.Representation" = @("Smooth","Broken","BrokenTilt")
	"Table.Representation" = @("List","HierarchicalList","Tree")
	"UsualGroup.Representation" = @("Auto","None","StrongSeparation","WeakSeparation","NormalSeparation","GroupBox","Line","Margin")
	"RepresentationInContextMenu" = @("None","AdditionalInContextMenu","OnlyInContextMenu","Auto")
	"RowActionsShowType" = @("Auto","DontShow","ShowOnHover","ShowAlways")
	"RowInputMode" = @("EndOfList","EndOfWindow","AfterCurrentRow","BeforeCurrentRow")
	"RowSelectionMode" = @("Auto","Cell","Row")
	"SaveColors" = @("Auto","ForUser","ByKeyForUser","DontUse")
	"SaveDataInSettings" = @("DontUse","UseList")
	"ScaleVariant" = @("Auto","Normal","Compact","NormalIfPossible")
	"ScalingMode" = @("Auto","Normal","Compact")
	"Page.ScrollOnCompress" = @("true","false","auto")
	"UsualGroup.ScrollOnCompress" = @("true","false","auto")
	"SearchControlLocation" = @("Auto","None","CommandBar")
	"SearchOnInput" = @("Use","DontUse","Auto")
	"SearchStringLocation" = @("Auto","None","CommandBar","Top","Bottom","FormCaption","PullFromTop")
	"CalendarField.SelectionMode" = @("Single","Multiple","Interval")
	"Table.SelectionMode" = @("SingleRow","MultiRow")
	"SelectionShowMode" = @("WhenActive","Always","DontShow","WhenMultipleCellsSelected","WhenMultipleCellsSelectedWhenActive")
	"Shape" = @("Auto","Usual","Oval")
	"ShapeRepresentation" = @("Auto","Always","WhenActive","None")
	"ShowCheckBoxesInDropList" = @("true","false","auto")
	"ShowCommandBar" = @("true","false","auto")
	"ShowHorizontalLinesFlag" = @("true","false","auto")
	"ColumnGroup.ShowTitle" = @("true","false","auto")
	"Form.ShowTitle" = @("true","false","auto")
	"Page.ShowTitle" = @("true","false","auto")
	"UsualGroup.ShowTitle" = @("true","false","auto")
	"ShowTitleInCard" = @("true","false","auto")
	"ShowVerticalLinesFlag" = @("true","false","auto")
	"SkipOnInput" = @("true","false","auto")
	"SpecialTextInputMode" = @("Auto","None","DigitsAndPunctuation","URL","Email","PhoneNumber","Digits")
	"SpellCheckingOnTextInput" = @("Auto","Use","DontUse")
	"SpinButton" = @("true","false","auto")
	"SpreadsheetDocumentMultipleSelectionPanelViewMode" = @("Auto","DontShow","ShowOnMultipleSelection","ShowAlways")
	"TableLocation" = @("Auto","Left","Right","None")
	"TextSize" = @("Enlarged","Normal","Reduced")
	"ThroughAlign" = @("Use","DontUse","Auto")
	"TimeChoiceMode" = @("Auto","DontChoose","CustomTime","Interval1Minute","Interval5Minutes","Interval10Minutes","Interval15Minutes","Interval15And20Minutes","Interval20Minutes","Interval30Minutes","Interval60Minutes")
	"TitleLocation" = @("None","Auto","Left","Top","Right","Bottom")
	"ToolTipRepresentation" = @("Auto","None","Balloon","Button","ShowAuto","ShowTop","ShowLeft","ShowBottom","ShowRight")
	"TumblerRepresentation" = @("Text","Picture","Auto")
	"Type" = @("CommandBarButton","UsualButton","Hyperlink","CommandBarHyperlink")
	"UpdateOnDataChange" = @("Auto","DontUpdate")
	"UseAlternationRowColorBWA" = @("true","false","auto")
	"UseCopy" = @("true","false","auto")
	"UseForFoldersAndItems" = @("Items","Folders","FoldersAndItems")
	"UsePostingMode" = @("Regular","RealTime","Ask","Auto")
	"ValuesSelectionMode" = @("Auto","Multiple","Single","None")
	"VerticalAlign" = @("Top","Center","Bottom","Auto")
	"VerticalLinesBWA" = @("true","false","auto")
	"VerticalScroll" = @("auto","use","useIfNecessary","useWithoutStretch")
	"Table.VerticalScrollBar" = @("DontUse","UseAlways","AutoUse")
	"VerticalSpacing" = @("Auto","None","Half","Single","OneAndHalf","Double")
	"AutoCommandBar.VerticalStretch" = @("true","false","auto")
	"ButtonGroup.VerticalStretch" = @("true","false","auto")
	"ColumnGroup.VerticalStretch" = @("true","false","auto")
	"CommandBar.VerticalStretch" = @("true","false","auto")
	"ContextMenu.VerticalStretch" = @("true","false","auto")
	"InputField.VerticalStretch" = @("true","false","auto")
	"LabelDecoration.VerticalStretch" = @("true","false","auto")
	"LabelField.VerticalStretch" = @("true","false","auto")
	"Page.VerticalStretch" = @("true","false","auto")
	"Pages.VerticalStretch" = @("true","false","auto")
	"PictureDecoration.VerticalStretch" = @("true","false","auto")
	"Popup.VerticalStretch" = @("true","false","auto")
	"UsualGroup.VerticalStretch" = @("true","false","auto")
	"ViewMode" = @("All","QuickAccess")
	"ViewModeApplicationOnSetReportResult" = @("Auto","Apply","DontApply")
	"ViewScalingMode" = @("Auto","Normal","Large")
	"ViewStatusLocation" = @("Auto","None","Top","Bottom")
	"WarningOnEditRepresentation" = @("Show","DontShow","Auto")
	"WidthInCard" = @("Auto","Full","Half")
	"WindowOpeningMode" = @("Auto","DontBlock","LockOwner","LockWholeInterface","Independent","LockOwnerWindow")
}

$script:enumValueAliases = @{
	"TitlesLeftDataLeft" = "ItemsLeftTitlesLeft"
	"TitlesLeftDataRight" = "ItemsRightTitlesLeft"
	"TitlesRightDataLeft" = "ItemsLeftTitlesRight"
	"TitlesRightDataRight" = "ItemsRightTitlesRight"
	"GroupBox" = "StrongSeparation"
	"Margin" = "NormalSeparation"
	"Square" = "Rect"
}

$script:enumDefaultValues = @{
	"AutoCommandBar.GroupHorizontalAlign" = "Auto"
	"AutoCommandBar.GroupVerticalAlign" = "Auto"
	"AutoCommandBar.HorizontalAlign" = "Left"
	"AutoCommandBar.HorizontalStretch" = "auto"
	"AutoCommandBar.ToolTipRepresentation" = "Auto"
	"AutoCommandBar.VerticalStretch" = "auto"
	"Button.GroupHorizontalAlign" = "Auto"
	"Button.GroupVerticalAlign" = "Auto"
	"Button.LocationInCommandBar" = "Auto"
	"Button.OnMainServerUnavalableBehavior" = "Auto"
	"Button.PictureLocation" = "Auto"
	"Button.PlacementArea" = "userCmds"
	"Button.Representation" = "Auto"
	"Button.RepresentationInContextMenu" = "Auto"
	"Button.Shape" = "Auto"
	"Button.ShapeRepresentation" = "Auto"
	"Button.SkipOnInput" = "auto"
	"Button.ToolTipRepresentation" = "Auto"
	"ButtonGroup.GroupHorizontalAlign" = "Auto"
	"ButtonGroup.GroupVerticalAlign" = "Auto"
	"ButtonGroup.HorizontalStretch" = "auto"
	"ButtonGroup.PlacementArea" = "userCmds"
	"ButtonGroup.Representation" = "Auto"
	"ButtonGroup.ToolTipRepresentation" = "Auto"
	"ButtonGroup.VerticalStretch" = "auto"
	"CalendarField.EditMode" = "Enter"
	"CalendarField.FixingInTable" = "None"
	"CalendarField.FooterHorizontalAlign" = "Auto"
	"CalendarField.GroupHorizontalAlign" = "Auto"
	"CalendarField.GroupVerticalAlign" = "Auto"
	"CalendarField.HeaderHorizontalAlign" = "Left"
	"CalendarField.HorizontalAlign" = "Auto"
	"CalendarField.OnMainServerUnavalableBehavior" = "Auto"
	"CalendarField.SelectionMode" = "Single"
	"CalendarField.SkipOnInput" = "auto"
	"CalendarField.TitleLocation" = "Auto"
	"CalendarField.ToolTipRepresentation" = "Auto"
	"CalendarField.VerticalAlign" = "Auto"
	"CalendarField.WarningOnEditRepresentation" = "Auto"
	"ChartField.EditMode" = "Enter"
	"ChartField.FixingInTable" = "None"
	"ChartField.FooterHorizontalAlign" = "Auto"
	"ChartField.GroupHorizontalAlign" = "Auto"
	"ChartField.GroupVerticalAlign" = "Auto"
	"ChartField.HeaderHorizontalAlign" = "Left"
	"ChartField.HorizontalAlign" = "Auto"
	"ChartField.OnMainServerUnavalableBehavior" = "Auto"
	"ChartField.SkipOnInput" = "auto"
	"ChartField.TitleLocation" = "Auto"
	"ChartField.ToolTipRepresentation" = "Auto"
	"ChartField.VerticalAlign" = "Auto"
	"ChartField.WarningOnEditRepresentation" = "Auto"
	"CheckBoxField.EditMode" = "Enter"
	"CheckBoxField.EqualItemsWidth" = "auto"
	"CheckBoxField.FixingInTable" = "None"
	"CheckBoxField.FooterHorizontalAlign" = "Auto"
	"CheckBoxField.GroupHorizontalAlign" = "Auto"
	"CheckBoxField.GroupVerticalAlign" = "Auto"
	"CheckBoxField.HeaderHorizontalAlign" = "Left"
	"CheckBoxField.HorizontalAlign" = "Auto"
	"CheckBoxField.OnMainServerUnavalableBehavior" = "Auto"
	"CheckBoxField.SkipOnInput" = "auto"
	"CheckBoxField.TitleLocation" = "Auto"
	"CheckBoxField.ToolTipRepresentation" = "Auto"
	"CheckBoxField.VerticalAlign" = "Auto"
	"CheckBoxField.WarningOnEditRepresentation" = "Auto"
	"ColumnGroup.FixingInTable" = "None"
	"ColumnGroup.Group" = "Vertical"
	"ColumnGroup.GroupHorizontalAlign" = "Auto"
	"ColumnGroup.GroupVerticalAlign" = "Auto"
	"ColumnGroup.HeaderHorizontalAlign" = "Auto"
	"ColumnGroup.HorizontalStretch" = "auto"
	"ColumnGroup.ToolTipRepresentation" = "Auto"
	"ColumnGroup.VerticalStretch" = "auto"
	"CommandBar.GroupHorizontalAlign" = "Auto"
	"CommandBar.GroupVerticalAlign" = "Auto"
	"CommandBar.HorizontalLocation" = "Left"
	"CommandBar.HorizontalStretch" = "auto"
	"CommandBar.ToolTipRepresentation" = "Auto"
	"CommandBar.VerticalStretch" = "auto"
	"ContextMenu.GroupHorizontalAlign" = "Auto"
	"ContextMenu.GroupVerticalAlign" = "Auto"
	"ContextMenu.HorizontalStretch" = "auto"
	"ContextMenu.ToolTipRepresentation" = "Auto"
	"ContextMenu.VerticalStretch" = "auto"
	"Form.AutoSaveDataInSettings" = "DontUse"
	"Form.ChildItemsWidth" = "Auto"
	"Form.ChildrenAlign" = "Auto"
	"Form.CollapseItemsByImportanceVariant" = "Auto"
	"Form.CommandBarLocation" = "Auto"
	"Form.ConversationsRepresentation" = "Auto"
	"Form.EnterKeyBehavior" = "ControlNavigation"
	"Form.Group" = "Vertical"
	"Form.HorizontalAlign" = "Auto"
	"Form.HorizontalSpacing" = "Auto"
	"Form.SaveDataInSettings" = "DontUse"
	"Form.ScalingMode" = "Auto"
	"Form.VerticalAlign" = "Auto"
	"Form.VerticalScroll" = "auto"
	"Form.VerticalSpacing" = "Auto"
	"Form.WindowOpeningMode" = "Independent"
	"FormattedDocumentField.EditMode" = "Enter"
	"FormattedDocumentField.FixingInTable" = "None"
	"FormattedDocumentField.FooterHorizontalAlign" = "Auto"
	"FormattedDocumentField.GroupHorizontalAlign" = "Auto"
	"FormattedDocumentField.GroupVerticalAlign" = "Auto"
	"FormattedDocumentField.HeaderHorizontalAlign" = "Left"
	"FormattedDocumentField.HorizontalAlign" = "Auto"
	"FormattedDocumentField.OnMainServerUnavalableBehavior" = "Auto"
	"FormattedDocumentField.Output" = "Auto"
	"FormattedDocumentField.SkipOnInput" = "auto"
	"FormattedDocumentField.TitleLocation" = "Auto"
	"FormattedDocumentField.ToolTipRepresentation" = "Auto"
	"FormattedDocumentField.VerticalAlign" = "Auto"
	"FormattedDocumentField.WarningOnEditRepresentation" = "Auto"
	"GraphicalSchemaField.EditMode" = "Enter"
	"GraphicalSchemaField.FixingInTable" = "None"
	"GraphicalSchemaField.FooterHorizontalAlign" = "Auto"
	"GraphicalSchemaField.GroupHorizontalAlign" = "Auto"
	"GraphicalSchemaField.GroupVerticalAlign" = "Auto"
	"GraphicalSchemaField.HeaderHorizontalAlign" = "Left"
	"GraphicalSchemaField.HorizontalAlign" = "Auto"
	"GraphicalSchemaField.OnMainServerUnavalableBehavior" = "Auto"
	"GraphicalSchemaField.Output" = "Auto"
	"GraphicalSchemaField.SkipOnInput" = "auto"
	"GraphicalSchemaField.TitleLocation" = "Auto"
	"GraphicalSchemaField.ToolTipRepresentation" = "Auto"
	"GraphicalSchemaField.VerticalAlign" = "Auto"
	"GraphicalSchemaField.WarningOnEditRepresentation" = "Auto"
	"HTMLDocumentField.EditMode" = "Enter"
	"HTMLDocumentField.FixingInTable" = "None"
	"HTMLDocumentField.FooterHorizontalAlign" = "Auto"
	"HTMLDocumentField.GroupHorizontalAlign" = "Auto"
	"HTMLDocumentField.GroupVerticalAlign" = "Auto"
	"HTMLDocumentField.HeaderHorizontalAlign" = "Left"
	"HTMLDocumentField.HorizontalAlign" = "Auto"
	"HTMLDocumentField.OnMainServerUnavalableBehavior" = "Auto"
	"HTMLDocumentField.Output" = "Auto"
	"HTMLDocumentField.SkipOnInput" = "auto"
	"HTMLDocumentField.TitleLocation" = "Auto"
	"HTMLDocumentField.ToolTipRepresentation" = "Auto"
	"HTMLDocumentField.VerticalAlign" = "Auto"
	"HTMLDocumentField.WarningOnEditRepresentation" = "Auto"
	"InputField.AutoCapitalizationOnTextInput" = "Auto"
	"InputField.AutoChoiceIncomplete" = "auto"
	"InputField.AutoCorrectionOnTextInput" = "Auto"
	"InputField.AutoMarkIncomplete" = "auto"
	"InputField.AutoShowClearButtonMode" = "Auto"
	"InputField.AutoShowOpenButtonMode" = "Auto"
	"InputField.AutofillHint" = "DontUse"
	"InputField.ChoiceButton" = "auto"
	"InputField.ChoiceButtonRepresentation" = "Auto"
	"InputField.ChoiceFoldersAndItems" = "Auto"
	"InputField.ChoiceHistoryOnInput" = "Auto"
	"InputField.ChoiceListButton" = "auto"
	"InputField.ClearButton" = "auto"
	"InputField.CreateButton" = "auto"
	"InputField.DropListButton" = "auto"
	"InputField.EditMode" = "Enter"
	"InputField.EditTextUpdate" = "Auto"
	"InputField.ExtendedEdit" = "auto"
	"InputField.FixingInTable" = "None"
	"InputField.FooterHorizontalAlign" = "Auto"
	"InputField.GroupHorizontalAlign" = "Auto"
	"InputField.GroupVerticalAlign" = "Auto"
	"InputField.HeaderHorizontalAlign" = "Left"
	"InputField.HeightControlVariant" = "Auto"
	"InputField.HorizontalAlign" = "Auto"
	"InputField.HorizontalStretch" = "auto"
	"InputField.IncompleteChoiceMode" = "OnEnterPressed"
	"InputField.MarkNegatives" = "auto"
	"InputField.MultiLine" = "auto"
	"InputField.MultipleValuePictureShape" = "Auto"
	"InputField.MultipleValuePictureSize" = "Auto"
	"InputField.MultipleValuesHyperlink" = "auto"
	"InputField.OnMainServerUnavalableBehavior" = "Auto"
	"InputField.OnScreenKeyboardReturnKeyText" = "Auto"
	"InputField.OpenButton" = "auto"
	"InputField.PasswordMode" = "auto"
	"InputField.QuickChoice" = "auto"
	"InputField.ShowCheckBoxesInDropList" = "auto"
	"InputField.SkipOnInput" = "auto"
	"InputField.SpecialTextInputMode" = "Auto"
	"InputField.SpellCheckingOnTextInput" = "Auto"
	"InputField.SpinButton" = "auto"
	"InputField.TitleLocation" = "Auto"
	"InputField.ToolTipRepresentation" = "Auto"
	"InputField.VerticalAlign" = "Auto"
	"InputField.VerticalStretch" = "auto"
	"InputField.WarningOnEditRepresentation" = "Auto"
	"LabelDecoration.GroupHorizontalAlign" = "Auto"
	"LabelDecoration.GroupVerticalAlign" = "Auto"
	"LabelDecoration.HorizontalAlign" = "Left"
	"LabelDecoration.HorizontalStretch" = "auto"
	"LabelDecoration.OnMainServerUnavalableBehavior" = "Auto"
	"LabelDecoration.SkipOnInput" = "auto"
	"LabelDecoration.ToolTipRepresentation" = "Auto"
	"LabelDecoration.VerticalAlign" = "Auto"
	"LabelDecoration.VerticalStretch" = "auto"
	"LabelField.EditMode" = "Enter"
	"LabelField.FixingInTable" = "None"
	"LabelField.FooterHorizontalAlign" = "Auto"
	"LabelField.GroupHorizontalAlign" = "Auto"
	"LabelField.GroupVerticalAlign" = "Auto"
	"LabelField.HeaderHorizontalAlign" = "Left"
	"LabelField.HorizontalAlign" = "Auto"
	"LabelField.HorizontalStretch" = "auto"
	"LabelField.MarkNegatives" = "auto"
	"LabelField.OnMainServerUnavalableBehavior" = "Auto"
	"LabelField.PasswordMode" = "auto"
	"LabelField.SkipOnInput" = "auto"
	"LabelField.TitleLocation" = "Auto"
	"LabelField.ToolTipRepresentation" = "Auto"
	"LabelField.VerticalAlign" = "Auto"
	"LabelField.VerticalStretch" = "auto"
	"LabelField.WarningOnEditRepresentation" = "Auto"
	"Page.ChildItemsWidth" = "Auto"
	"Page.ChildrenAlign" = "Auto"
	"Page.Group" = "Vertical"
	"Page.GroupHorizontalAlign" = "Auto"
	"Page.GroupVerticalAlign" = "Auto"
	"Page.HorizontalAlign" = "Auto"
	"Page.HorizontalSpacing" = "Auto"
	"Page.HorizontalStretch" = "auto"
	"Page.ToolTipRepresentation" = "Auto"
	"Page.VerticalAlign" = "Auto"
	"Page.VerticalSpacing" = "Auto"
	"Page.VerticalStretch" = "auto"
	"Pages.CurrentRowUse" = "Auto"
	"Pages.GroupHorizontalAlign" = "Auto"
	"Pages.GroupVerticalAlign" = "Auto"
	"Pages.HorizontalStretch" = "auto"
	"Pages.PagesRepresentation" = "Auto"
	"Pages.ToolTipRepresentation" = "Auto"
	"Pages.VerticalStretch" = "auto"
	"PeriodField.EditMode" = "Enter"
	"PeriodField.FixingInTable" = "None"
	"PeriodField.FooterHorizontalAlign" = "Auto"
	"PeriodField.GroupHorizontalAlign" = "Auto"
	"PeriodField.GroupVerticalAlign" = "Auto"
	"PeriodField.HeaderHorizontalAlign" = "Left"
	"PeriodField.HorizontalAlign" = "Auto"
	"PeriodField.OnMainServerUnavalableBehavior" = "Auto"
	"PeriodField.SkipOnInput" = "auto"
	"PeriodField.TitleLocation" = "Auto"
	"PeriodField.ToolTipRepresentation" = "Auto"
	"PeriodField.VerticalAlign" = "Auto"
	"PeriodField.WarningOnEditRepresentation" = "Auto"
	"PictureDecoration.FileDragMode" = "AsFileRef"
	"PictureDecoration.GroupHorizontalAlign" = "Auto"
	"PictureDecoration.GroupVerticalAlign" = "Auto"
	"PictureDecoration.HorizontalStretch" = "auto"
	"PictureDecoration.OnMainServerUnavalableBehavior" = "Auto"
	"PictureDecoration.PictureSize" = "RealSize"
	"PictureDecoration.SkipOnInput" = "auto"
	"PictureDecoration.ToolTipRepresentation" = "Auto"
	"PictureDecoration.VerticalStretch" = "auto"
	"PictureField.EditMode" = "Enter"
	"PictureField.FileDragMode" = "AsFileRef"
	"PictureField.FixingInTable" = "None"
	"PictureField.FooterHorizontalAlign" = "Auto"
	"PictureField.GroupHorizontalAlign" = "Auto"
	"PictureField.GroupVerticalAlign" = "Auto"
	"PictureField.HeaderHorizontalAlign" = "Left"
	"PictureField.HorizontalAlign" = "Auto"
	"PictureField.OnMainServerUnavalableBehavior" = "Auto"
	"PictureField.PictureSize" = "RealSize"
	"PictureField.SkipOnInput" = "auto"
	"PictureField.TitleLocation" = "Auto"
	"PictureField.ToolTipRepresentation" = "Auto"
	"PictureField.VerticalAlign" = "Auto"
	"PictureField.WarningOnEditRepresentation" = "Auto"
	"PlannerField.EditMode" = "Enter"
	"PlannerField.FixingInTable" = "None"
	"PlannerField.FooterHorizontalAlign" = "Auto"
	"PlannerField.GroupHorizontalAlign" = "Auto"
	"PlannerField.GroupVerticalAlign" = "Auto"
	"PlannerField.HeaderHorizontalAlign" = "Left"
	"PlannerField.HorizontalAlign" = "Auto"
	"PlannerField.OnMainServerUnavalableBehavior" = "Auto"
	"PlannerField.SkipOnInput" = "auto"
	"PlannerField.TitleLocation" = "Auto"
	"PlannerField.ToolTipRepresentation" = "Auto"
	"PlannerField.VerticalAlign" = "Auto"
	"PlannerField.WarningOnEditRepresentation" = "Auto"
	"Popup.GroupHorizontalAlign" = "Auto"
	"Popup.GroupVerticalAlign" = "Auto"
	"Popup.HorizontalStretch" = "auto"
	"Popup.PlacementArea" = "userCmds"
	"Popup.Representation" = "Auto"
	"Popup.Shape" = "Auto"
	"Popup.ShapeRepresentation" = "Auto"
	"Popup.ToolTipRepresentation" = "Auto"
	"Popup.VerticalStretch" = "auto"
	"ProgressBarField.EditMode" = "Enter"
	"ProgressBarField.FixingInTable" = "None"
	"ProgressBarField.FooterHorizontalAlign" = "Auto"
	"ProgressBarField.GroupHorizontalAlign" = "Auto"
	"ProgressBarField.GroupVerticalAlign" = "Auto"
	"ProgressBarField.HeaderHorizontalAlign" = "Left"
	"ProgressBarField.HorizontalAlign" = "Auto"
	"ProgressBarField.OnMainServerUnavalableBehavior" = "Auto"
	"ProgressBarField.Orientation" = "Horizontal"
	"ProgressBarField.Representation" = "Smooth"
	"ProgressBarField.SkipOnInput" = "auto"
	"ProgressBarField.TitleLocation" = "Auto"
	"ProgressBarField.ToolTipRepresentation" = "Auto"
	"ProgressBarField.VerticalAlign" = "Auto"
	"ProgressBarField.WarningOnEditRepresentation" = "Auto"
	"RadioButtonField.EditMode" = "Enter"
	"RadioButtonField.EqualColumnsWidth" = "auto"
	"RadioButtonField.FixingInTable" = "None"
	"RadioButtonField.FooterHorizontalAlign" = "Auto"
	"RadioButtonField.GroupHorizontalAlign" = "Auto"
	"RadioButtonField.GroupVerticalAlign" = "Auto"
	"RadioButtonField.HeaderHorizontalAlign" = "Left"
	"RadioButtonField.HorizontalAlign" = "Auto"
	"RadioButtonField.OnMainServerUnavalableBehavior" = "Auto"
	"RadioButtonField.SkipOnInput" = "auto"
	"RadioButtonField.TitleLocation" = "Auto"
	"RadioButtonField.ToolTipRepresentation" = "Auto"
	"RadioButtonField.VerticalAlign" = "Auto"
	"RadioButtonField.WarningOnEditRepresentation" = "Auto"
	"SpreadSheetDocumentField.DrawingSelectionShowMode" = "Auto"
	"SpreadSheetDocumentField.EditMode" = "Enter"
	"SpreadSheetDocumentField.FixingInTable" = "None"
	"SpreadSheetDocumentField.FooterHorizontalAlign" = "Auto"
	"SpreadSheetDocumentField.GroupHorizontalAlign" = "Auto"
	"SpreadSheetDocumentField.GroupVerticalAlign" = "Auto"
	"SpreadSheetDocumentField.HeaderHorizontalAlign" = "Left"
	"SpreadSheetDocumentField.HorizontalAlign" = "Auto"
	"SpreadSheetDocumentField.OnMainServerUnavalableBehavior" = "Auto"
	"SpreadSheetDocumentField.Output" = "Auto"
	"SpreadSheetDocumentField.PointerType" = "Special"
	"SpreadSheetDocumentField.SelectionShowMode" = "Always"
	"SpreadSheetDocumentField.SkipOnInput" = "auto"
	"SpreadSheetDocumentField.TitleLocation" = "Auto"
	"SpreadSheetDocumentField.ToolTipRepresentation" = "Auto"
	"SpreadSheetDocumentField.VerticalAlign" = "Auto"
	"SpreadSheetDocumentField.ViewScalingMode" = "Auto"
	"SpreadSheetDocumentField.WarningOnEditRepresentation" = "Auto"
	"Table.AutoAddIncomplete" = "auto"
	"Table.AutoMarkIncomplete" = "auto"
	"Table.BehaviorOnHorizontalCompression" = "Auto"
	"Table.CommandBarLocation" = "Auto"
	"Table.CurrentRowUse" = "Auto"
	"Table.FileDragMode" = "AsFileRef"
	"Table.GroupHorizontalAlign" = "Auto"
	"Table.GroupVerticalAlign" = "Auto"
	"Table.HeightControlVariant" = "Auto"
	"Table.HorizontalScrollBar" = "AutoUse"
	"Table.InitialListView" = "Auto"
	"Table.InitialTreeView" = "NoExpand"
	"Table.OnMainServerUnavalableBehavior" = "Auto"
	"Table.Output" = "Auto"
	"Table.RefreshRequest" = "None"
	"Table.Representation" = "HierarchicalList"
	"Table.RowInputMode" = "EndOfList"
	"Table.RowSelectionMode" = "Cell"
	"Table.SearchControlLocation" = "Auto"
	"Table.SearchOnInput" = "Auto"
	"Table.SearchStringLocation" = "Auto"
	"Table.SelectionMode" = "MultiRow"
	"Table.SkipOnInput" = "auto"
	"Table.TitleLocation" = "None"
	"Table.ToolTipRepresentation" = "Auto"
	"Table.VerticalScrollBar" = "AutoUse"
	"Table.ViewStatusLocation" = "Auto"
	"TextDocumentField.EditMode" = "Enter"
	"TextDocumentField.FixingInTable" = "None"
	"TextDocumentField.FooterHorizontalAlign" = "Auto"
	"TextDocumentField.GroupHorizontalAlign" = "Auto"
	"TextDocumentField.GroupVerticalAlign" = "Auto"
	"TextDocumentField.HeaderHorizontalAlign" = "Left"
	"TextDocumentField.HorizontalAlign" = "Auto"
	"TextDocumentField.OnMainServerUnavalableBehavior" = "Auto"
	"TextDocumentField.Output" = "Auto"
	"TextDocumentField.SkipOnInput" = "auto"
	"TextDocumentField.TitleLocation" = "Auto"
	"TextDocumentField.ToolTipRepresentation" = "Auto"
	"TextDocumentField.VerticalAlign" = "Auto"
	"TextDocumentField.WarningOnEditRepresentation" = "Auto"
	"TrackBarField.EditMode" = "Enter"
	"TrackBarField.FixingInTable" = "None"
	"TrackBarField.FooterHorizontalAlign" = "Auto"
	"TrackBarField.GroupHorizontalAlign" = "Auto"
	"TrackBarField.GroupVerticalAlign" = "Auto"
	"TrackBarField.HeaderHorizontalAlign" = "Left"
	"TrackBarField.HorizontalAlign" = "Auto"
	"TrackBarField.MarkingAppearance" = "BottomRight"
	"TrackBarField.OnMainServerUnavalableBehavior" = "Auto"
	"TrackBarField.Orientation" = "Horizontal"
	"TrackBarField.SkipOnInput" = "auto"
	"TrackBarField.TitleLocation" = "Auto"
	"TrackBarField.ToolTipRepresentation" = "Auto"
	"TrackBarField.VerticalAlign" = "Auto"
	"TrackBarField.WarningOnEditRepresentation" = "Auto"
	"UsualGroup.Behavior" = "Auto"
	"UsualGroup.ChildItemsWidth" = "Auto"
	"UsualGroup.ChildrenAlign" = "Auto"
	"UsualGroup.ControlRepresentation" = "TitleHyperlink"
	"UsualGroup.CurrentRowUse" = "Auto"
	"UsualGroup.Group" = "HorizontalIfPossible"
	"UsualGroup.GroupHorizontalAlign" = "Auto"
	"UsualGroup.GroupVerticalAlign" = "Auto"
	"UsualGroup.HorizontalAlign" = "Auto"
	"UsualGroup.HorizontalSpacing" = "Auto"
	"UsualGroup.HorizontalStretch" = "auto"
	"UsualGroup.Representation" = "WeakSeparation"
	"UsualGroup.ThroughAlign" = "Auto"
	"UsualGroup.ToolTipRepresentation" = "Auto"
	"UsualGroup.VerticalAlign" = "Auto"
	"UsualGroup.VerticalSpacing" = "Auto"
	"UsualGroup.VerticalStretch" = "auto"
}

$script:objType = $null

$script:childTagOrder = @{
	'AutoCommandBar' = 'HorizontalAlign Autofill ChildItems'
	'Button' = 'Type Visible TitleHeight UserVisible Representation DefaultButton SkipOnInput Enabled DefaultItem Width AutoMaxWidth MaxWidth Height AutoMaxHeight HorizontalStretch MaxHeight VerticalStretch GroupHorizontalAlign Check GroupVerticalAlign CommandName Parameter DataPath TextColor BackColor BorderColor Font Picture Title Shape ToolTipRepresentation RepresentationInContextMenu ShapeRepresentation PictureLocation LocationInCommandBar CommandUniqueness ExtendedTooltip'
	'ButtonGroup' = 'EnableContentChange Visible Title GroupVerticalAlign ToolTip HorizontalStretch GroupHorizontalAlign ToolTipRepresentation CommandSource Representation VerticalStretch ExtendedTooltip ChildItems'
	'CalendarField' = 'DataPath SkipOnInput Title TitleLocation ToolTip ToolTipRepresentation Width AutoMaxWidth Height HorizontalStretch SelectionMode ShowCurrentDate ShowMonthsPanel WidthInMonths HeightInMonths ContextMenu ExtendedTooltip Events'
	'ChartField' = 'DataPath Enabled Title TitleFont Visible TitleLocation GroupHorizontalAlign Width AutoMaxWidth MaxHeight MaxWidth Height AutoMaxHeight HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Events'
	'CheckBoxField' = 'DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip FooterHorizontalAlign HorizontalAlign ToolTipRepresentation Shortcut GroupHorizontalAlign VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode AutoCellHeight CellHyperlink FixingInTable ShowInHeader FooterDataPath HeaderPicture HeaderHorizontalAlign ShowInFooter CheckBoxType EditFormat ItemHeight ItemTitleHeight ItemWidth EqualItemsWidth ThreeState ContextMenu ExtendedTooltip Events'
	'ColumnGroup' = 'Visible Enabled ReadOnly UserVisible EnableContentChange Title GroupVerticalAlign TitleFont TitleTextColor ToolTip ToolTipRepresentation Width Height HorizontalStretch GroupHorizontalAlign VerticalStretch Group ShowTitle ShowInHeader HeaderDataPath HeaderHorizontalAlign HeaderFormat HeaderPicture FixingInTable ExtendedTooltip ChildItems'
	'CommandBar' = 'Enabled Visible EnableContentChange Title ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign HorizontalLocation CommandSource ExtendedTooltip ChildItems'
	'FormattedDocumentField' = 'DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleLocation CommandSet Font ToolTip EditMode Width AutoMaxWidth Height AutoMaxHeight BorderColor HorizontalStretch MaxWidth ContextMenu ExtendedTooltip Events'
	'GanttChartField' = 'DataPath DefaultItem TitleLocation Width Height HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Table Events'
	'GraphicalSchemaField' = 'DataPath DefaultItem ReadOnly Title TitleLocation WarningOnEditRepresentation Width Height Edit ContextMenu ExtendedTooltip Events'
	'HTMLDocumentField' = 'DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation ToolTipRepresentation Visible WarningOnEditRepresentation Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch Output BorderColor ContextMenu ExtendedTooltip Events'
	'InputField' = 'DataPath Visible UserVisible DefaultItem Enabled ReadOnly SkipOnInput Title TitleBackColor TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation WarningOnEditRepresentation WarningOnEdit Shortcut HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign EditMode CellHyperlink FixingInTable AutoCellHeight ShowInHeader HeaderHorizontalAlign HeaderPicture ShowInFooter FooterDataPath FooterText FooterTextColor FooterFont FooterHorizontalAlign FooterPicture Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch AllowInputEmptyMultipleValues MultipleValuesFont MultipleValuesTextColor MultipleValuesBackColor VerticalStretch Wrap MarkNegatives PasswordMode MultiLine ExtendedEdit DropListButton ChoiceButton ChoiceButtonRepresentation ClearButton SpinButton OpenButton CreateButton Mask ListChoiceMode ExtendedEditMultipleValues AutoChoiceIncomplete Format MultipleValuePictureShape QuickChoice ChoiceFoldersAndItems EditFormat AutoMarkIncomplete ChooseType AutoShowOpenButtonMode IncompleteChoiceMode ShowCheckBoxesInDropList MultipleValueDataPath MultipleValuePictureDataPath MultipleValuePresentDataPath SpellCheckingOnTextInput TypeDomainEnabled TextEdit AvailableTypes ChoiceForm ChoiceParameterLinks ChoiceParameters EditTextUpdate MinValue ChoiceButtonPicture MaxValue ChoiceList AutoCorrectionOnTextInput AutoShowClearButtonMode ChoiceListButton ChoiceListHeight DropListWidth TextColor BackColor BorderColor Font HeightControlVariant SpecialTextInputMode InputHint ChoiceHistoryOnInput TypeLink ContextMenu ExtendedTooltip Events'
	'LabelDecoration' = 'UserVisible Visible Enabled Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Shortcut Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink HorizontalAlign VerticalAlign BackColor BorderColor Border TitleHeight ContextMenu ExtendedTooltip Events'
	'LabelField' = 'DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode FixingInTable CellHyperlink AutoCellHeight FooterText ShowInHeader HeaderHorizontalAlign FooterDataPath HeaderPicture ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch MarkNegatives VerticalStretch Format Border BorderColor Hiperlink PasswordMode TextColor BackColor Font ContextMenu ExtendedTooltip Events'
	'Page' = 'Visible Enabled ReadOnly EnableContentChange UserVisible Title GroupVerticalAlign Shortcut TitleTextColor TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch ChildrenAlign Picture Format Group ChildItemsWidth HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign ShowTitle BackColor TitleDataPath ScrollOnCompress ExtendedTooltip ChildItems'
	'Pages' = 'Enabled ReadOnly EnableContentChange UserVisible Visible Title TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign PagesRepresentation CurrentRowUse ExtendedTooltip Events ChildItems'
	'PeriodField' = 'DataPath TitleLocation ContextMenu ExtendedTooltip'
	'PictureDecoration' = 'Enabled Visible Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink PictureSize Zoomable ImageScale NonselectedPictureText EnableStartDrag EnableDrag Picture BorderColor Border FileDragMode ContextMenu ExtendedTooltip Events'
	'PictureField' = 'DataPath TitleBackColor UserVisible Visible Enabled ReadOnly SkipOnInput Title TitleTextColor TitleLocation TitleHeight ToolTip GroupHorizontalAlign GroupVerticalAlign Shortcut ToolTipRepresentation HorizontalAlign WarningOnEditRepresentation EditMode AutoCellHeight FixingInTable CellHyperlink ShowInHeader FooterDataPath HeaderPicture FooterText HeaderHorizontalAlign ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch PictureSize Zoomable Hyperlink NonselectedPictureText EnableDrag TextColor ValuesPicture BorderColor Border Font FileDragMode ContextMenu ExtendedTooltip Events'
	'PlannerField' = 'DataPath TitleLocation ContextMenu ExtendedTooltip Events'
	'Popup' = 'UserVisible Visible EnableContentChange Title Shape TitleTextColor TitleFont ToolTip ToolTipRepresentation VerticalStretch Width HorizontalStretch Picture CommandSource Representation BackColor ShapeRepresentation BorderColor ExtendedTooltip ChildItems'
	'ProgressBarField' = 'DataPath Title Visible ReadOnly TitleLocation ToolTip ToolTipRepresentation Width AutoMaxHeight AutoMaxWidth HorizontalStretch MaxValue ShowPercent ContextMenu ExtendedTooltip'
	'RadioButtonField' = 'DataPath DefaultItem Enabled SkipOnInput UserVisible Visible ReadOnly Title TitleTextColor TitleFont TitleLocation FooterHorizontalAlign TitleHeight ToolTip ToolTipRepresentation EditMode GroupHorizontalAlign Shortcut VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit RadioButtonType ItemHeight ItemTitleHeight ItemWidth ColumnsCount EqualColumnsWidth ChoiceList Font TextColor ContextMenu ExtendedTooltip Events'
	'SpreadSheetDocumentField' = 'DataPath Enabled ReadOnly SkipOnInput UserVisible Visible DefaultItem Title TitleLocation DrawingSelectionShowMode FooterHorizontalAlign GroupHorizontalAlign ToolTip ToolTipRepresentation CommandSet Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch ShowGrid ShowHeaders VerticalScrollBar HorizontalScrollBar Protection SelectionShowMode Edit Output PointerType ShowGroups EnableStartDrag EnableDrag BorderColor ShowCellNames ShowRowAndColumnNames ViewScalingMode ContextMenu ExtendedTooltip Events'
	'Table' = 'Representation Visible UserVisible TitleLocation CommandBarLocation Autofill Enabled TitleHeight ReadOnly SkipOnInput DefaultItem ChangeRowSet ChangeRowOrder Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HeightInTableRows HeightControlVariant AutoMaxRowsCount MaxRowsCount ChoiceMode MultipleChoice RowInputMode SelectionMode RowSelectionMode Header FooterHeight HeaderHeight Footer HorizontalScrollBar VerticalScrollBar HorizontalLines VerticalLines UseAlternationRowColor AutoInsertNewRow AutoAddIncomplete AutoMarkIncomplete SearchOnInput InitialListView InitialTreeView HorizontalStretch Output VerticalStretch EnableStartDrag EnableDrag FileDragMode DataPath Font RowPictureDataPath RowsPicture BackColor BorderColor TextColor Title BehaviorOnHorizontalCompression GroupVerticalAlign Shortcut TitleTextColor TitleFont CommandSet ToolTip ToolTipRepresentation SearchStringLocation ViewStatusLocation SearchControlLocation GroupHorizontalAlign CurrentRowUse RefreshRequest AutoRefresh AutoRefreshPeriod Period ChoiceFoldersAndItems RestoreCurrentRow RowFilter TopLevelParent ShowRoot AllowRootChoice UpdateOnDataChange UserSettingsGroup AllowGettingCurrentRowURL ViewMode SettingsNamedItemDetailedRepresentation ContextMenu AutoCommandBar ExtendedTooltip SearchStringAddition ViewStatusAddition SearchControlAddition Events ChildItems'
	'TextDocumentField' = 'DataPath DefaultItem ReadOnly Title TitleFont TitleLocation EditMode ToolTip Width AutoMaxWidth Font MaxWidth Height AutoMaxHeight ContextMenu ExtendedTooltip Events'
	'TrackBarField' = 'DataPath Title TitleLocation HorizontalAlign ToolTip ToolTipRepresentation Width AutoMaxWidth HorizontalStretch MaxWidth Height AutoMaxHeight MinValue MarkingAppearance MaxValue LargeStep Step MarkingStep ContextMenu ExtendedTooltip Events'
	'UsualGroup' = 'UserVisible Visible Enabled ReadOnly EnableContentChange Title TitleTextColor TitleFont ToolTip ToolTipRepresentation Shortcut Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign Group ChildrenAlign HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign Behavior CollapsedRepresentationTitle Collapsed ControlRepresentation Representation CurrentRowUse Format ShowLeftMargin United ChildItemsWidth ShowTitle BackColor ThroughAlign TitleDataPath ExtendedTooltip ChildItems'
}

$script:childRank = $null

$script:appearanceSpec = @{
	titleTextColor  = @{ tag='TitleTextColor';  kind='color' }
	titleBackColor  = @{ tag='TitleBackColor';  kind='color' }
	titleFont       = @{ tag='TitleFont';       kind='font'  }
	footerTextColor = @{ tag='FooterTextColor'; kind='color' }
	footerBackColor = @{ tag='FooterBackColor'; kind='color' }
	footerFont      = @{ tag='FooterFont';      kind='font'  }
	textColor       = @{ tag='TextColor';       kind='color' }
	backColor       = @{ tag='BackColor';       kind='color' }
	borderColor     = @{ tag='BorderColor';     kind='color' }
	border          = @{ tag='Border';          kind='border'}
	font            = @{ tag='Font';            kind='font'  }
}

$script:appearanceSynonyms = @{
	'цветтекста'='textColor'; 'цветфона'='backColor'; 'цветрамки'='borderColor'
	'цветтекстазаголовка'='titleTextColor'; 'цветфоназаголовка'='titleBackColor'; 'шрифтзаголовка'='titleFont'
	'цветтекстаподвала'='footerTextColor'; 'цветфонаподвала'='footerBackColor'; 'шрифтподвала'='footerFont'
	'шрифт'='font'; 'рамка'='border'
}

$script:propSynonyms = @{
	'пометка'='checked'
	'кнопкавыбора'='choiceButton'; 'кнопкаочистки'='clearButton'; 'кнопкарегулирования'='spinButton'
	'кнопкавыпадающегосписка'='dropListButton'; 'кнопкасписковоговыбора'='choiceListButton'
	'кнопкаоткрытия'='openButton'; 'кнопкапоумолчанию'='defaultButton'
	'быстрыйвыбор'='quickChoice'; 'формавыбора'='choiceForm'; 'историявыборапривводе'='choiceHistoryOnInput'
	'выборгруппиэлементов'='choiceFoldersAndItems'; 'фиксациявтаблице'='fixingInTable'
	'путькданнымподвала'='footerDataPath'; 'автоотметканезаполненного'='markIncomplete'
	'многострочныйрежим'='multiLine'; 'режимпароля'='passwordMode'; 'переноспословам'='wrap'
	'расположениезаголовка'='titleLocation'; 'пропускатьпривводе'='skipOnInput'
	'заголовок'='title'; 'ширина'='width'; 'высота'='height'; 'подсказкаввода'='inputHint'
}

$script:appOrderField      = @('titleTextColor','titleBackColor','titleFont','footerTextColor','footerBackColor','footerFont','textColor','backColor','borderColor','border','font')

$script:appOrderDecoration = @('textColor','font','backColor','borderColor','border')

$script:appOrderButton     = @('textColor','backColor','borderColor','font')

$script:genericScalars = @(
	@{ Tag='VerticalAlign';       Key='verticalAlign';       Kind='value' }
	@{ Tag='ThroughAlign';        Key='throughAlign';        Kind='value' }
	@{ Tag='EnableContentChange'; Key='enableContentChange'; Kind='bool'  }
	@{ Tag='PictureSize';         Key='pictureSize';         Kind='value' }
	@{ Tag='TitleHeight';         Key='titleHeight';         Kind='value' }
	@{ Tag='ChildItemsWidth';     Key='childItemsWidth';     Kind='value' }
	@{ Tag='ShowLeftMargin';      Key='showLeftMargin';      Kind='bool'  }
	@{ Tag='CellHyperlink';       Key='cellHyperlink';       Kind='bool'  }
	@{ Tag='ViewMode';            Key='viewMode';            Kind='value' }
	@{ Tag='VerticalScrollBar';   Key='verticalScrollBar';   Kind='value' }
	@{ Tag='RowInputMode';        Key='rowInputMode';        Kind='value' }
	@{ Tag='Mask';                Key='mask';                Kind='value' }
	@{ Tag='CreateButton';        Key='createButton';        Kind='bool'  }
	@{ Tag='FixingInTable';       Key='fixingInTable';       Kind='value' }
	@{ Tag='VerticalSpacing';     Key='verticalSpacing';     Kind='value' }
	# Спец-поля (документ/датчик) — типоспец. enum/bool скаляры pass-through
	@{ Tag='HorizontalScrollBar'; Key='horizontalScrollBar'; Kind='value' }
	@{ Tag='ViewScalingMode';     Key='viewScalingMode';     Kind='value' }
	@{ Tag='Output';              Key='output';              Kind='value' }
	@{ Tag='SelectionShowMode';   Key='selectionShowMode';   Kind='value' }
	@{ Tag='PointerType';         Key='pointerType';         Kind='value' }
	@{ Tag='DrawingSelectionShowMode'; Key='drawingSelectionShowMode'; Kind='value' }
	@{ Tag='WarningOnEditRepresentation'; Key='warningOnEditRepresentation'; Kind='value' }
	@{ Tag='MarkingAppearance';   Key='markingAppearance';   Kind='value' }
	@{ Tag='Protection';          Key='protection';          Kind='bool'  }
	@{ Tag='Edit';                Key='edit';                Kind='bool'  }
	@{ Tag='ShowGrid';            Key='showGrid';            Kind='bool'  }
	@{ Tag='ShowGroups';          Key='showGroups';          Kind='bool'  }
	@{ Tag='ShowHeaders';         Key='showHeaders';         Kind='bool'  }
	@{ Tag='ShowRowAndColumnNames'; Key='showRowAndColumnNames'; Kind='bool' }
	@{ Tag='ShowCellNames';       Key='showCellNames';       Kind='bool'  }
	@{ Tag='ShowPercent';         Key='showPercent';         Kind='bool'  }
	# Report-form контекст: интервал группы / представление кнопки в контекстном меню / детальное представление настройки таблицы
	@{ Tag='HorizontalSpacing';   Key='horizontalSpacing';   Kind='value' }
	@{ Tag='RepresentationInContextMenu'; Key='representationInContextMenu'; Kind='value' }
	@{ Tag='SettingsNamedItemDetailedRepresentation'; Key='settingsNamedItemDetailedRepresentation'; Kind='bool' }
	# Хвост: высота элемента списка (radio) / ширина выпадающего списка (input)
	@{ Tag='ItemHeight';          Key='itemHeight';          Kind='value' }
	@{ Tag='DropListWidth';       Key='dropListWidth';       Kind='value' }
	# Хвост CI-форм: динамический заголовок (Page/Group) / расширенное ред. (input) / высота таблицы по строкам
	@{ Tag='TitleDataPath';       Key='titleDataPath';       Kind='value' }
	@{ Tag='ExtendedEdit';        Key='extendedEdit';        Kind='bool'  }
	@{ Tag='MaxRowsCount';        Key='maxRowsCount';        Kind='value' }
	@{ Tag='AutoMaxRowsCount';    Key='autoMaxRowsCount';    Kind='bool'  }
	@{ Tag='HeightControlVariant'; Key='heightControlVariant'; Kind='value' }
	@{ Tag='EditTextUpdate';      Key='editTextUpdate';      Kind='value' }
	# Корпусный хвост: представление управления свёрткой группы / форма кнопки-попапа /
	# авто-добавление незаполненной строки / выделение отрицательных / нач. позиция списка /
	# высота списка выбора / три состояния флажка / прокрутка страницы при сжатии
	@{ Tag='ControlRepresentation'; Key='controlRepresentation'; Kind='value' }
	@{ Tag='ShapeRepresentation';   Key='shapeRepresentation';   Kind='value' }
	@{ Tag='AutoAddIncomplete';     Key='autoAddIncomplete';     Kind='bool'  }
	@{ Tag='MarkNegatives';         Key='markNegatives';         Kind='bool'  }
	@{ Tag='InitialListView';       Key='initialListView';       Kind='value' }
	@{ Tag='ChoiceListHeight';      Key='choiceListHeight';      Kind='value' }
	@{ Tag='ThreeState';            Key='threeState';            Kind='bool'  }
	@{ Tag='ScrollOnCompress';      Key='scrollOnCompress';      Kind='bool'  }
	# Сочетание клавиш — общее свойство (input/group/radio/page/picField/label/table/check; команда — отд. путь, §7)
	@{ Tag='Shortcut';              Key='shortcut';              Kind='value' }
	# Батч простых скаляров (input/radio/group/picDecoration/button): режим выбора незаполненного,
	# равная ширина колонок, выравнивание детей, масштаб/зум картинки, форма/положение картинки кнопки.
	# (Table HeaderHeight/FooterHeight/CurrentRowUse — НЕ здесь, а в Emit-Table: pass-through,
	#  1С толерантна к порядку детей Table — в корпусе те же теги встречаются в разных позициях.)
	@{ Tag='IncompleteChoiceMode';  Key='incompleteChoiceMode';  Kind='value' }
	@{ Tag='EqualColumnsWidth';     Key='equalColumnsWidth';     Kind='bool'  }
	@{ Tag='ChildrenAlign';         Key='childrenAlign';         Kind='value' }
	@{ Tag='ImageScale';            Key='imageScale';            Kind='value' }
	@{ Tag='Zoomable';              Key='zoomable';              Kind='bool'  }
	@{ Tag='Shape';                 Key='shape';                 Kind='value' }
	@{ Tag='PictureLocation';       Key='pictureLocation';       Kind='value' }
	# Равная ширина элементов (check/radio) / высота заголовка пункта (radio)
	@{ Tag='EqualItemsWidth';       Key='equalItemsWidth';       Kind='bool'  }
	@{ Tag='ItemTitleHeight';       Key='itemTitleHeight';       Kind='value' }
	# Спец-режим ввода текста (input, моб.: Email/PhoneNumber/...) — листовой enum-скаляр
	@{ Tag='SpecialTextInputMode';  Key='specialTextInputMode';  Kind='value' }
	# Ширина пункта (radio/check) / выбор нескольких значений из выпадающего (input)
	@{ Tag='ItemWidth';                    Key='itemWidth';                    Kind='value' }
	@{ Tag='ShowCheckBoxesInDropList';     Key='showCheckBoxesInDropList';     Kind='bool'  }
	@{ Tag='MultipleValueDataPath';        Key='multipleValueDataPath';        Kind='value' }
	@{ Tag='MultipleValuePresentDataPath'; Key='multipleValuePresentDataPath'; Kind='value' }
	# Режим авто-показа кнопок открытия/очистки (input, enum Auto/Always/FilledOnly/…)
	@{ Tag='AutoShowOpenButtonMode';       Key='autoShowOpenButtonMode';       Kind='value' }
	@{ Tag='AutoShowClearButtonMode';      Key='autoShowClearButtonMode';      Kind='value' }
	# Оформление/картинка множественного выбора (input, редко; цвета — текст-контент, не атрибуты)
	@{ Tag='MultipleValuesTextColor';      Key='multipleValuesTextColor';      Kind='value' }
	@{ Tag='MultipleValuesBackColor';      Key='multipleValuesBackColor';      Kind='value' }
	@{ Tag='MultipleValuePictureShape';    Key='multipleValuePictureShape';    Kind='value' }
	@{ Tag='MultipleValuePictureDataPath'; Key='multipleValuePictureDataPath'; Kind='value' }
	# Хвост листовых скаляров (по 1 в корпусе): автокоррекция ввода (input) / уникальность команды
	# (button) / допуск пустого множ. значения (input) / поведение при гориз. сжатии (table)
	@{ Tag='AutoCorrectionOnTextInput';    Key='autoCorrectionOnTextInput';    Kind='value' }
	@{ Tag='SpellCheckingOnTextInput';     Key='spellCheckingOnTextInput';     Kind='value' }
	@{ Tag='CommandUniqueness';            Key='commandUniqueness';            Kind='bool'  }
	@{ Tag='AllowInputEmptyMultipleValues';Key='allowInputEmptyMultipleValues';Kind='bool'  }
	@{ Tag='BehaviorOnHorizontalCompression'; Key='behaviorOnHorizontalCompression'; Kind='value' }
)

$script:PLANNER_NS = 'http://v8.1c.ru/8.3/data/planner'

$script:CHART_NS   = 'http://v8.1c.ru/8.2/data/chart'

$script:CHART_ML_FIELDS = @{ 'title'=1;'lbFormat'=1;'lbpFormat'=1;'vsFormat'=1;'dtFormat'=1;'dataSourceDescription'=1;'labelFormat'=1;'text'=1 }

$script:CHART_ATTR_FIELDS = @{ 'gaugeQualityBands'=1 }

$script:CHART_FONT_KEYS = @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')

$script:refRootSynonyms = @{
	"Перечисление"            = "Enum"
	"Справочник"              = "Catalog"
	"Документ"                = "Document"
	"ПланСчетов"              = "ChartOfAccounts"
	"ПланВидовХарактеристик"  = "ChartOfCharacteristicTypes"
	"ПланВидовРасчета"        = "ChartOfCalculationTypes"
	"ПланВидовРасчёта"        = "ChartOfCalculationTypes"
	"ПланОбмена"              = "ExchangePlan"
	"БизнесПроцесс"           = "BusinessProcess"
	"Задача"                  = "Task"
	"РегистрСведений"         = "InformationRegister"
	"РегистрНакопления"       = "AccumulationRegister"
	"РегистрБухгалтерии"      = "AccountingRegister"
	"РегистрРасчета"          = "CalculationRegister"
	"РегистрРасчёта"          = "CalculationRegister"
	"ЖурналДокументов"        = "DocumentJournal"
	"КритерийОтбора"          = "FilterCriterion"
}

$script:enumValueSynonyms = @("EnumValue","ЗначениеПеречисления")

$script:formRootTagOrder = 'Title Width Height WindowOpeningMode EnterKeyBehavior AutoSaveDataInSettings SaveDataInSettings SaveWindowSettings SettingsStorage AutoTitle AutoURL Group HorizontalAlign ChildItemsWidth VerticalAlign HorizontalSpacing VerticalSpacing AutoFillCheck Customizable Enabled ChildrenAlign CommandBarLocation VerticalScroll ScalingMode ConversationsRepresentation MobileDeviceCommandBarContent CommandSet AutoTime UsePostingMode RepostOnWrite ReportResult DetailsData ReportFormType ShowTitle ShowCloseButton GroupList CollapseItemsByImportanceVariant UseForFoldersAndItems VariantAppearance AutoShowState CustomSettingsFolder ReportResultViewMode ViewModeApplicationOnSetReportResult Scale AutoCommandBar Events ChildItems Attributes Commands Parameters CommandInterface BaseForm'

function Resolve-TextFromFile {
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
	Write-Error "Файл значения не найден: $filePath (искали: $($candidates -join ', '))"
	exit 1
}

function Assert-UniqueName {
	param([string]$name, [hashtable]$seen, [string]$kind)
	if ($seen.ContainsKey($name)) {
		Write-Error "Duplicate $kind name '$name' — names must be unique within their collection in a 1C form (set a unique 'name')"
		exit 1
	}
	$seen[$name] = $true
}

function Esc-Xml {
	param([string]$s)
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	# Экранирование ТЕКСТА элемента (<v8:content>, <Value>): только & < > .
	# Кавычки/апострофы в тексте экранировать НЕ нужно (1С их не экранирует — пишет литерально);
	# &quot; ломал бы раундтрип. Кавычки спецсимвольны лишь в значениях атрибутов.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

function Emit-MLItems {
	param($val, [string]$indent)
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
	param([string]$tag, $text, [string]$indent, [string]$xsiType)
	$attr = if ($xsiType) { " xsi:type=`"$xsiType`"" } else { "" }
	X "$indent<$tag$attr>"
	Emit-MLItems -val $text -indent "$indent`t"
	X "$indent</$tag>"
}

function Emit-USPresentation {
	param($val, [string]$tag, [string]$indent)
	if ($null -eq $val) { return }
	if ($val -is [string]) {
		X "$indent<$tag xsi:type=`"xs:string`">$(Esc-XmlText $val)</$tag>"
	} else {
		Emit-MLText -tag $tag -text $val -indent $indent -xsiType "v8:LocalStringType"
	}
}

function Test-HasRealMarkup {
	param($text)
	if ($null -eq $text) { return $false }
	$vals = if ($text -is [System.Collections.IDictionary]) { @($text.Values) }
		elseif ($text -is [System.Management.Automation.PSCustomObject]) { @($text.PSObject.Properties.Value) }
		else { @("$text") }
	foreach ($v in $vals) { if ("$v" -match $script:fmtMarkupRe) { return $true } }
	return $false
}

function Resolve-MLFormatted {
	param($val)
	$hasText = $false
	if ($val -is [System.Management.Automation.PSCustomObject]) { $hasText = [bool]$val.PSObject.Properties['text'] }
	elseif ($val -is [System.Collections.IDictionary]) { $hasText = $val.Contains('text') }
	if ($hasText) {
		$t = if ($val -is [System.Collections.IDictionary]) { $val['text'] } else { $val.text }
		$f = if ($val -is [System.Collections.IDictionary]) { $val['formatted'] } else { $val.formatted }
		return @{ text = $t; formatted = [bool]$f }
	}
	return @{ text = $val; formatted = (Test-HasRealMarkup $val) }
}

function New-Guid-String { return [System.Guid]::NewGuid().ToString() }

function Parse-FilterShorthand {
	param([string]$s)
	$result = @{ field = ""; op = "Equal"; value = $null; use = $true; userSettingID = $null; viewMode = $null; presentation = $null }
	if ($s -match '@user') { $result.userSettingID = "auto"; $s = $s -replace '\s*@user', '' }
	if ($s -match '@off') { $result.use = $false; $s = $s -replace '\s*@off', '' }
	if ($s -match '@quickAccess') { $result.viewMode = "QuickAccess"; $s = $s -replace '\s*@quickAccess', '' }
	if ($s -match '@normal') { $result.viewMode = "Normal"; $s = $s -replace '\s*@normal', '' }
	if ($s -match '@inaccessible') { $result.viewMode = "Inaccessible"; $s = $s -replace '\s*@inaccessible', '' }
	$s = $s.Trim()
	$opPatterns = @('<>', '>=', '<=', '=', '>', '<',
		'notIn\b', 'in\b', 'inHierarchy\b', 'inListByHierarchy\b',
		'notContains\b', 'contains\b', 'notBeginsWith\b', 'beginsWith\b',
		'notLike\b', 'like\b', 'неподобно\b', 'подобно\b',
		'notFilled\b', 'filled\b')
	$opJoined = $opPatterns -join '|'
	if ($s -match "^(.+?)\s+($opJoined)\s*(.*)?$") {
		$result.field = $Matches[1].Trim()
		$result.op = $Matches[2].Trim()
		$valPart = if ($Matches[3]) { $Matches[3].Trim() } else { "" }
		if ($valPart -and $valPart -ne "_") {
			if ($valPart -eq "true" -or $valPart -eq "false") { $result.value = [bool]($valPart -eq "true"); $result["valueType"] = "xs:boolean" }
			elseif ($valPart -match '^\d{4}-\d{2}-\d{2}T') { $result.value = $valPart }  # дата без valueType → Emit-FilterItem выведет StandardBeginningDate Custom (дефолт даты в фильтре)
			elseif ($valPart -match '^\d+(\.\d+)?$') { $result.value = $valPart; $result["valueType"] = "xs:decimal" }
			elseif ($valPart -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.') { $result.value = $valPart; $result["valueType"] = "dcscor:DesignTimeValue" }
			else { $result.value = $valPart; $result["valueType"] = "xs:string" }
		}
	} else { $result.field = $s }
	return $result
}

function Get-ValueTypeNsAttr {
	param([string]$valueType, [string]$value)
	if ($valueType -eq 'v8:Type' -and "$value" -match '^([A-Za-z]\w*):') {
		$pref = $Matches[1]
		if ($pref -notin @('xs','cfg','v8','v8ui','ent','dcscor','dcsset','dcssch')) {
			return " xmlns:$pref=`"http://v8.1c.ru/8.2/data/types`""
		}
	}
	return ""
}

function Emit-FilterItem {
	param($item, [string]$indent)
	if ($item.group) {
		$groupType = switch ("$($item.group)") { "And" { "AndGroup" } "Or" { "OrGroup" } "Not" { "NotGroup" } default { "$($item.group)Group" } }
		X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemGroup`">"
		if ($item.use -eq $false) { X "$indent`t<dcsset:use>false</dcsset:use>" }   # группа отключена (перед groupType, порядок исходника)
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
		if ($item.presentation) { Emit-USPresentation -val $item.presentation -tag "dcsset:presentation" -indent "$indent`t" }
		if ($item.viewMode) { X "$indent`t<dcsset:viewMode>$(Esc-XmlText "$($item.viewMode)")</dcsset:viewMode>" }
		if ($item.userSettingID) {
			$guid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
			X "$indent`t<dcsset:userSettingID>$(Esc-XmlText $guid)</dcsset:userSettingID>"
		}
		if ($item.userSettingPresentation) { Emit-USPresentation -val $item.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
		X "$indent</dcsset:item>"
		return
	}
	X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"
	if ($item.use -eq $false) { X "$indent`t<dcsset:use>false</dcsset:use>" }
	X "$indent`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-XmlText "$($item.field)")</dcsset:left>"
	$compType = $script:comparisonTypes["$($item.op)"]
	if (-not $compType) { $compType = "$($item.op)" }
	X "$indent`t<dcsset:comparisonType>$(Esc-XmlText $compType)</dcsset:comparisonType>"
	$valIsArray = ($item.value -is [array]) -or ($item.value -is [System.Collections.IList] -and $item.value -isnot [string])
	if ($valIsArray) {
		if (@($item.value).Count -eq 0) {
			X "$indent`t<dcsset:right xsi:type=`"v8:ValueListType`">"
			X "$indent`t`t<v8:valueType/>"
			X "$indent`t`t<v8:lastId xsi:type=`"xs:decimal`">-1</v8:lastId>"
			X "$indent`t</dcsset:right>"
		} else {
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
				$vStr = if ($v -is [bool]) { "$v".ToLower() } else { Esc-XmlText "$v" }
				$nsAttr = Get-ValueTypeNsAttr -valueType $vt -value "$v"
				X "$indent`t<dcsset:right$nsAttr xsi:type=`"$vt`">$vStr</dcsset:right>"
			}
		}
	} elseif ($null -ne $item.value -and (
			"$($item.valueType)" -match 'Standard(Beginning|End)Date$' -or
			(-not $item.valueType -and "$($item.value)" -match '^\d{4}-\d{2}-\d{2}T'))) {
		# Стандартная дата начала/окончания. Формы значения:
		#   объект {variant, date?} — полная (Custom несёт <v8:date>);
		#   строка-вариант "BeginningOfThisDay" — именованный вариант без даты;
		#   голая ISO-дата без valueType — шорткат для Custom+date (дата в фильтре платформой
		#   почти всегда хранится как StandardBeginningDate Custom, корпус 268 vs 2 xs:dateTime;
		#   явный valueType="xs:dateTime" → плоская дата, ветка ниже).
		$sdType = if ($item.valueType) { "$($item.valueType)" -replace '^v8:','' } else { 'StandardBeginningDate' }
		$sv = $item.value
		if (($sv -is [PSCustomObject]) -or ($sv -is [System.Collections.IDictionary])) {
			$variant = if ($sv -is [PSCustomObject]) { "$($sv.variant)" } else { "$($sv['variant'])" }
			$hasDate = if ($sv -is [PSCustomObject]) { [bool]$sv.PSObject.Properties['date'] } else { $sv.Contains('date') }
			$dateV = if ($hasDate) { if ($sv -is [PSCustomObject]) { "$($sv.date)" } else { "$($sv['date'])" } } else { $null }
		} elseif ("$sv" -match '^\d{4}-\d{2}-\d{2}T') {
			$variant = 'Custom'; $hasDate = $true; $dateV = "$sv"
		} else {
			$variant = "$sv"; $hasDate = $false; $dateV = $null
		}
		X "$indent`t<dcsset:right xsi:type=`"v8:$sdType`">"
		X "$indent`t`t<v8:variant xsi:type=`"v8:${sdType}Variant`">$(Esc-XmlText $variant)</v8:variant>"
		if ($hasDate) { X "$indent`t`t<v8:date>$(Esc-XmlText $dateV)</v8:date>" }
		X "$indent`t</dcsset:right>"
	} elseif ("$($item.value)" -eq '_') {
		# "_" — маркер пустого значения: платформа эмитит пустой self-closing <dcsset:right>
		# (напр. <dcsset:right xsi:type="dcscor:Field"/> — сравнение с незаданным полем).
		$vt = if ($item.valueType) { "$($item.valueType)" } else { 'xs:string' }
		X "$indent`t<dcsset:right xsi:type=`"$vt`"/>"
	} elseif ($null -ne $item.value) {
		$vt = if ($item.valueType) { "$($item.valueType)" } else { "" }
		if (-not $vt) {
			$v = $item.value
			if ($v -is [bool]) { $vt = "xs:boolean" }
			elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { $vt = "xs:decimal" }
			elseif ("$v" -match '^\d{4}-\d{2}-\d{2}T') { $vt = "xs:dateTime" }
			elseif ("$v" -match '^-?\d+(\.\d+)?$') { $vt = "xs:decimal" }
			elseif ("$v" -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { $vt = "dcscor:DesignTimeValue" }
			else { $vt = "xs:string" }
		}
		$vStr = if ($item.value -is [bool]) { "$($item.value)".ToLower() } else { Esc-XmlText "$($item.value)" }
		$nsAttr = Get-ValueTypeNsAttr -valueType $vt -value "$($item.value)"
		X "$indent`t<dcsset:right$nsAttr xsi:type=`"$vt`">$vStr</dcsset:right>"
	}
	if ($item.presentation) { Emit-USPresentation -val $item.presentation -tag "dcsset:presentation" -indent "$indent`t" }
	if ($item.viewMode) { X "$indent`t<dcsset:viewMode>$(Esc-XmlText "$($item.viewMode)")</dcsset:viewMode>" }
	if ($item.userSettingID) {
		$uid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
		X "$indent`t<dcsset:userSettingID>$(Esc-XmlText $uid)</dcsset:userSettingID>"
	}
	if ($item.userSettingPresentation) { Emit-USPresentation -val $item.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
	X "$indent</dcsset:item>"
}

function Emit-Filter {
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null, $blockUserSettingPresentation = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID) -or ($null -ne $blockUserSettingPresentation)
	if (-not $hasItems -and -not $hasBlockMeta) { return }
	X "$indent<dcsset:filter>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			$parsed = Parse-FilterShorthand $item
			$obj = @{ field = $parsed.field; op = $parsed.op }
			if ($parsed.use -eq $false) { $obj.use = $false }
			if ($null -ne $parsed.value) { $obj.value = $parsed.value }
			if ($parsed["valueType"]) { $obj.valueType = $parsed["valueType"] }
			if ($parsed.userSettingID) { $obj.userSettingID = $parsed.userSettingID }
			if ($parsed.viewMode) { $obj.viewMode = $parsed.viewMode }
			Emit-FilterItem -item ([pscustomobject]$obj) -indent "$indent`t"
		} else { Emit-FilterItem -item $item -indent "$indent`t" }
	}
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-XmlText "$blockViewMode")</dcsset:viewMode>" }
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-XmlText $uid)</dcsset:userSettingID>"
	}
	if ($null -ne $blockUserSettingPresentation) { Emit-USPresentation -val $blockUserSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
	X "$indent</dcsset:filter>"
}

function Emit-Order {
	param($items, [string]$indent, [switch]$skipAuto, $blockViewMode = $null, $blockUserSettingID = $null, $blockUserSettingPresentation = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID) -or ($null -ne $blockUserSettingPresentation)
	if (-not $hasItems -and -not $hasBlockMeta) { return }
	X "$indent<dcsset:order>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			if ($item -eq "Auto") { if (-not $skipAuto) { X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>" } }
			else {
				$parts = $item -split '\s+'
				$field = $parts[0]
				$dir = "Asc"
				if ($parts.Count -gt 1 -and $parts[1] -match '^(?i)(desc|убыв)') { $dir = "Desc" }
				elseif ($parts.Count -gt 1 -and $parts[1] -match '^(?i)(asc|возр)') { $dir = "Asc" }
				X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
				X "$indent`t`t<dcsset:field>$(Esc-XmlText $field)</dcsset:field>"
				X "$indent`t`t<dcsset:orderType>$dir</dcsset:orderType>"
				X "$indent`t</dcsset:item>"
			}
		} else {
			if ($item.field -eq "Auto" -or $item.type -eq "auto") { if (-not $skipAuto) { X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>" }; continue }
			$dir = if ($item.direction) { "$($item.direction)" } else { "Asc" }
			if ($dir -match '^(?i)(desc|убыв)') { $dir = "Desc" } elseif ($dir -match '^(?i)(asc|возр)') { $dir = "Asc" }
			X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
			if ($item.use -eq $false) { X "$indent`t`t<dcsset:use>false</dcsset:use>" }
			X "$indent`t`t<dcsset:field>$(Esc-XmlText "$($item.field)")</dcsset:field>"
			X "$indent`t`t<dcsset:orderType>$dir</dcsset:orderType>"
			if ($item.viewMode) { X "$indent`t`t<dcsset:viewMode>$(Esc-XmlText "$($item.viewMode)")</dcsset:viewMode>" }
			X "$indent`t</dcsset:item>"
		}
	}
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-XmlText "$blockViewMode")</dcsset:viewMode>" }
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-XmlText $uid)</dcsset:userSettingID>"
	}
	if ($null -ne $blockUserSettingPresentation) { Emit-USPresentation -val $blockUserSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
	X "$indent</dcsset:order>"
}

function Emit-AppearanceValue {
	param([string]$key, $val, [string]$indent)
	X "$indent<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
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
	$isTopLevelLine = (_HasKey $val '@type') -and ("$(_Get $val '@type')" -eq 'Line')
	$useWrapper = $false
	$innerVal = $val
	$nestedItems = $null
	if ($isTopLevelLine) {
		if ((_HasKey $val 'use') -and ((_Get $val 'use') -eq $false)) { $useWrapper = $true }
		if (_HasKey $val 'items') { $nestedItems = (_Get $val 'items') }
	} elseif ((_HasKey $val 'value') -and (($val -is [PSCustomObject]) -or ($val -is [System.Collections.IDictionary]))) {
		$innerVal = (_Get $val 'value')
		if ((_HasKey $val 'use') -and ((_Get $val 'use') -eq $false)) { $useWrapper = $true }
		if (_HasKey $val 'items') { $nestedItems = (_Get $val 'items') }
	}
	if ($useWrapper) { X "$indent`t<dcscor:use>false</dcscor:use>" }
	X "$indent`t<dcscor:parameter>$(Esc-XmlText $key)</dcscor:parameter>"
	$isFontDict = $false
	if ($innerVal -is [PSCustomObject]) {
		$tProp = $innerVal.PSObject.Properties['@type']
		if ($tProp -and "$($tProp.Value)" -eq 'Font') { $isFontDict = $true }
	} elseif ($innerVal -is [System.Collections.IDictionary]) {
		if ($innerVal.Contains('@type') -and "$($innerVal['@type'])" -eq 'Font') { $isFontDict = $true }
	}
	$isLineDict = $false
	if (_HasKey $innerVal '@type') { $isLineDict = ("$(_Get $innerVal '@type')" -eq 'Line') }
	$isDict = ($innerVal -is [hashtable]) -or ($innerVal -is [System.Collections.IDictionary]) -or ($innerVal -is [PSCustomObject])
	if ($isLineDict) {
		$lw = if (_HasKey $innerVal 'width') { _Get $innerVal 'width' } else { 0 }
		$lg = if (_HasKey $innerVal 'gap') { if ((_Get $innerVal 'gap')) { 'true' } else { 'false' } } else { 'false' }
		$ls = if (_HasKey $innerVal 'style') { "$(_Get $innerVal 'style')" } else { 'None' }
		X "$indent`t<dcscor:value xsi:type=`"v8ui:Line`" width=`"$lw`" gap=`"$lg`">"
		X "$indent`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">$(Esc-XmlText $ls)</v8ui:style>"
		X "$indent`t</dcscor:value>"
	} elseif ($isFontDict) {
		$attrParts = @()
		foreach ($attrName in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
			$av = $null
			if ($innerVal -is [PSCustomObject]) { $ap = $innerVal.PSObject.Properties[$attrName]; if ($ap) { $av = $ap.Value } }
			else { if ($innerVal.Contains($attrName)) { $av = $innerVal[$attrName] } }
			if ($null -ne $av) { $attrParts += "$attrName=`"$(Esc-Xml "$av")`"" }
		}
		X "$indent`t<dcscor:value xsi:type=`"v8ui:Font`" $($attrParts -join ' ')/>"
	} elseif ($isDict -and (_HasKey $innerVal 'field')) {
		# Ссылка на поле (dcscor:Field) — значение параметра оформления = поле компоновки
		X "$indent`t<dcscor:value xsi:type=`"dcscor:Field`">$(Esc-XmlText "$(_Get $innerVal 'field')")</dcscor:value>"
	} elseif ($isDict) {
		# Локализуемый текст параметра оформления: платформа объявляет xsi:type на dcscor:value
		Emit-MLText -tag "dcscor:value" -text $innerVal -indent "$indent`t" -xsiType "v8:LocalStringType"
	} else {
		$actualVal = "$innerVal"
		$keyTypeMap = @{
			'Размещение'           = 'dcscor:DataCompositionTextPlacementType'
			'ГоризонтальноеПоложение' = 'v8ui:HorizontalAlign'
			'ВертикальноеПоложение' = 'v8ui:VerticalAlign'
			'ОриентацияТекста'     = 'xs:decimal'
			'РасположениеИтогов'   = 'dcscor:DataCompositionTotalPlacement'
			'ТипМакета'            = 'dcsset:DataCompositionGroupTemplateType'
		}
		$keyType = $keyTypeMap[$key]
		if ($keyType) { X "$indent`t<dcscor:value xsi:type=`"$keyType`">$(Esc-XmlText $actualVal)</dcscor:value>" }
		elseif ($actualVal -match '^(style|web|win):') { X "$indent`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-XmlText $actualVal)</dcscor:value>" }
		elseif ($actualVal -eq "true" -or $actualVal -eq "false") { X "$indent`t<dcscor:value xsi:type=`"xs:boolean`">$actualVal</dcscor:value>" }
		elseif ($key -eq "Текст" -or $key -eq "Заголовок" -or $key -eq "Формат") {
			# Текст/Заголовок/Формат: голая строка = плоский xs:string (так платформа хранит
			# нелокализованный литерал). Локализуемый текст → объект {ru,en} (ветка isDict выше).
			# Пустая строка → самозакрывающийся тег (как у платформы).
			if ($actualVal -eq '') { X "$indent`t<dcscor:value xsi:type=`"xs:string`"/>" }
			else { X "$indent`t<dcscor:value xsi:type=`"xs:string`">$(Esc-XmlText $actualVal)</dcscor:value>" }
		}
		elseif ($actualVal -match '^-?\d+(\.\d+)?$') { X "$indent`t<dcscor:value xsi:type=`"xs:decimal`">$actualVal</dcscor:value>" }
		elseif ($key -eq 'ЦветТекста' -or $key -eq 'ЦветФона' -or $key -eq 'ЦветГраницы') { X "$indent`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-XmlText $actualVal)</dcscor:value>" }
		else { X "$indent`t<dcscor:value xsi:type=`"xs:string`">$(Esc-XmlText $actualVal)</dcscor:value>" }
	}
	if ($nestedItems) {
		$niProps = if ($nestedItems -is [PSCustomObject]) { $nestedItems.PSObject.Properties } else { $null }
		if ($niProps) { foreach ($np in $niProps) { Emit-AppearanceValue -key $np.Name -val $np.Value -indent "$indent`t" } }
		elseif ($nestedItems -is [System.Collections.IDictionary]) { foreach ($nk in $nestedItems.Keys) { Emit-AppearanceValue -key $nk -val $nestedItems[$nk] -indent "$indent`t" } }
	}
	X "$indent</dcscor:item>"
}

function Emit-ConditionalAppearance {
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null, [string]$wrapTag = 'dcsset:conditionalAppearance', $blockUserSettingPresentation = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID) -or ($null -ne $blockUserSettingPresentation)
	if (-not $hasItems -and -not $hasBlockMeta) { return }
	X "$indent<$wrapTag>"
	foreach ($ca in $items) {
		X "$indent`t<dcsset:item>"
		if ($ca.use -eq $false) { X "$indent`t`t<dcsset:use>false</dcsset:use>" }
		if ($ca.selection -and $ca.selection.Count -gt 0) {
			X "$indent`t`t<dcsset:selection>"
			foreach ($sel in $ca.selection) {
				X "$indent`t`t`t<dcsset:item>"
				X "$indent`t`t`t`t<dcsset:field>$(Esc-XmlText "$sel")</dcsset:field>"
				X "$indent`t`t`t</dcsset:item>"
			}
			X "$indent`t`t</dcsset:selection>"
		} else { X "$indent`t`t<dcsset:selection/>" }
		if ($ca.filter -and $ca.filter.Count -gt 0) { Emit-Filter -items $ca.filter -indent "$indent`t`t" }
		else { X "$indent`t`t<dcsset:filter/>" }
		if ($ca.appearance) {
			X "$indent`t`t<dcsset:appearance>"
			foreach ($prop in $ca.appearance.PSObject.Properties) { Emit-AppearanceValue -key $prop.Name -val $prop.Value -indent "$indent`t`t`t" }
			X "$indent`t`t</dcsset:appearance>"
		}
		if ($ca.presentation) {
			if ($ca.presentation -is [hashtable] -or $ca.presentation -is [System.Collections.IDictionary] -or $ca.presentation -is [PSCustomObject]) {
				# Мультиязык → LocalStringType (платформа объявляет тип у локализованного presentation)
				X "$indent`t`t<dcsset:presentation xsi:type=`"v8:LocalStringType`">"
				Emit-MLItems -val $ca.presentation -indent "$indent`t`t`t"
				X "$indent`t`t</dcsset:presentation>"
			}
			else { X "$indent`t`t<dcsset:presentation xsi:type=`"xs:string`">$(Esc-XmlText "$($ca.presentation)")</dcsset:presentation>" }
		}
		if ($ca.viewMode) { X "$indent`t`t<dcsset:viewMode>$(Esc-XmlText "$($ca.viewMode)")</dcsset:viewMode>" }
		if ($ca.userSettingID) {
			$uid = if ("$($ca.userSettingID)" -eq "auto") { New-Guid-String } else { "$($ca.userSettingID)" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-XmlText $uid)</dcsset:userSettingID>"
		}
		if ($ca.userSettingPresentation) { Emit-USPresentation -val $ca.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t`t" }
		if ($ca.useInDontUse -and $ca.useInDontUse.Count -gt 0) {
			$useInOrder = @('group','hierarchicalGroup','overall','fieldsHeader','header','parameters','filter','resourceFieldsHeader','overallHeader','overallResourceFieldsHeader')
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
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-XmlText "$blockViewMode")</dcsset:viewMode>" }
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-XmlText $uid)</dcsset:userSettingID>"
	}
	if ($null -ne $blockUserSettingPresentation) { Emit-USPresentation -val $blockUserSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
	X "$indent</$wrapTag>"
}

function Get-ListGroupingValue {
	param($st)
	foreach ($k in 'grouping','structure','группировка') {
		if ($st.PSObject.Properties[$k] -and $st.$k) { return $st.$k }
	}
	return $null
}

function Parse-ListGrouping {
	param($grouping)
	# Шорткат "A > B > C" → массив имён; массив строк/объектов → как есть.
	# Unary comma: иначе PS разворачивает одноэлементный массив при return → строка → индексация даёт char.
	if (-not $grouping) { return ,@() }
	if ($grouping -is [string]) { return ,@($grouping -split '\s*>\s*' | Where-Object { "$_" -ne '' }) }
	return ,@($grouping)
}

function Emit-GroupItemField {
	param($level, [string]$indent)
	if ($level -is [string]) {
		$field = $level; $gt = 'Items'; $pat = 'None'; $pab = '0001-01-01T00:00:00'; $pae = '0001-01-01T00:00:00'
	} else {
		$field = "$($level.field)"
		$gt  = if ($level.groupType) { "$($level.groupType)" } else { 'Items' }
		$pat = if ($level.periodAdditionType) { "$($level.periodAdditionType)" } else { 'None' }
		$pab = if ($level.periodAdditionBegin) { "$($level.periodAdditionBegin)" } else { '0001-01-01T00:00:00' }
		$pae = if ($level.periodAdditionEnd)   { "$($level.periodAdditionEnd)"   } else { '0001-01-01T00:00:00' }
	}
	X "$indent<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
	X "$indent`t<dcsset:field>$(Esc-XmlText $field)</dcsset:field>"
	X "$indent`t<dcsset:groupType>$(Esc-XmlText $gt)</dcsset:groupType>"
	X "$indent`t<dcsset:periodAdditionType>$(Esc-XmlText $pat)</dcsset:periodAdditionType>"
	# Авто-детект: ISO-дата → xs:dateTime, иначе путь → dcscor:Field.
	$pabT = if ($pab -match '^\d{4}-\d{2}-\d{2}T') { 'xs:dateTime' } else { 'dcscor:Field' }
	$paeT = if ($pae -match '^\d{4}-\d{2}-\d{2}T') { 'xs:dateTime' } else { 'dcscor:Field' }
	X "$indent`t<dcsset:periodAdditionBegin xsi:type=`"$pabT`">$(Esc-XmlText $pab)</dcsset:periodAdditionBegin>"
	X "$indent`t<dcsset:periodAdditionEnd xsi:type=`"$paeT`">$(Esc-XmlText $pae)</dcsset:periodAdditionEnd>"
	X "$indent</dcsset:item>"
}

function Emit-ListGroupingLevels {
	param($levels, [int]$i, [string]$indent)
	X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"
	X "$indent`t<dcsset:groupItems>"
	Emit-GroupItemField $levels[$i] "$indent`t`t"
	X "$indent`t</dcsset:groupItems>"
	if ($i -lt $levels.Count - 1) { Emit-ListGroupingLevels $levels ($i + 1) "$indent`t" }
	X "$indent</dcsset:item>"
}

function Emit-ListGrouping {
	param($grouping, [string]$indent)
	$levels = Parse-ListGrouping $grouping
	if ($levels.Count -eq 0) { return }
	Emit-ListGroupingLevels $levels 0 $indent
}

function Parse-CalcShorthand {
	param([string]$s)
	$restrict = @()
	foreach ($m in [regex]::Matches($s, '#(noField|noFilter|noCondition|noGroup|noOrder)\b')) { $restrict += $m.Groups[1].Value }
	$s = [regex]::Replace($s, '\s*#(noField|noFilter|noCondition|noGroup|noOrder)\b', '')
	$eq = $s.IndexOf('=')
	if ($eq -gt 0) { $lhs = $s.Substring(0, $eq); $rhs = $s.Substring($eq + 1).Trim() } else { $lhs = $s; $rhs = '' }
	$title = ''
	if ($lhs -match '\[([^\]]+)\]') { $title = $Matches[1]; $lhs = $lhs -replace '\s*\[[^\]]+\]', '' }
	$lhs = $lhs.Trim()
	$type = ''; $dataPath = $lhs
	if ($lhs.Contains(':')) { $parts = $lhs -split ':', 2; $dataPath = $parts[0].Trim(); $type = Resolve-TypeStr ($parts[1].Trim()) }
	return @{ dataPath = $dataPath; expression = $rhs; type = $type; title = $title; restrict = $restrict }
}

function Emit-CalcFields {
	param($calcFields, [string]$indent)
	if (-not $calcFields) { return }
	foreach ($cf in $calcFields) {
		$pres = $null; $orderExpr = $null; $restrict = @()
		if ($cf -is [string]) {
			$p = Parse-CalcShorthand $cf
			$dataPath = "$($p.dataPath)"; $expression = "$($p.expression)"; $title = $p.title; $typeStr = "$($p.type)"
			foreach ($r in $p.restrict) { if ($script:calcRestrictMap[$r]) { $restrict += $script:calcRestrictMap[$r] } }
		} else {
			$dataPath = if ($cf.dataPath) { "$($cf.dataPath)" } elseif ($cf.field) { "$($cf.field)" } else { "$($cf.name)" }
			$expression = "$($cf.expression)"
			$title = $cf.title
			$typeStr = if ($cf.valueType) { "$($cf.valueType)" } elseif ($cf.type) { "$($cf.type)" } else { '' }
			$ur = if ($cf.useRestriction) { $cf.useRestriction } elseif ($cf.restrict) { $cf.restrict } else { $null }
			if ($ur -is [System.Management.Automation.PSCustomObject] -or $ur -is [hashtable]) {
				foreach ($k in 'field','condition','group','order') { if ($ur.$k -eq $true) { $restrict += $k } }
			} elseif ($ur -is [string]) {
				foreach ($tok in ($ur -split '\s+')) { $t = $tok.Trim().TrimStart('#'); if ($t) { $restrict += $(if ($script:calcRestrictMap[$t]) { $script:calcRestrictMap[$t] } else { $t }) } }
			} elseif ($ur) {
				foreach ($r in $ur) { $rr = "$r"; $restrict += $(if ($script:calcRestrictMap[$rr]) { $script:calcRestrictMap[$rr] } else { $rr }) }
			}
			$pres = $cf.presentationExpression
			$orderExpr = $cf.orderExpression
		}
		$ci = "$indent`t"
		X "$indent<CalculatedField>"
		X "$ci<dcssch:dataPath>$(Esc-XmlText $dataPath)</dcssch:dataPath>"
		X "$ci<dcssch:expression>$(Esc-XmlText $expression)</dcssch:expression>"
		if ($title) { Emit-MLText -tag 'dcssch:title' -text $title -indent $ci -xsiType 'v8:LocalStringType' }
		if ($restrict.Count -gt 0) {
			X "$ci<dcssch:useRestriction>"
			foreach ($r in @('field','condition','group','order')) { if ($restrict -contains $r) { X "$ci`t<dcssch:$r>true</dcssch:$r>" } }
			X "$ci</dcssch:useRestriction>"
		}
		if ($pres) { X "$ci<dcssch:presentationExpression>$(Esc-XmlText "$pres")</dcssch:presentationExpression>" }
		if ($orderExpr) {
			$oeList = if ($orderExpr -is [System.Collections.IList]) { $orderExpr } else { @($orderExpr) }
			foreach ($oe in $oeList) {
				if ($oe -is [string]) { $exprV = $oe; $oType = 'Asc'; $auto = 'false' }
				else { $exprV = "$($oe.expression)"; $oType = if ($oe.orderType) { "$($oe.orderType)" } else { 'Asc' }; $auto = if ($oe.autoOrder) { 'true' } else { 'false' } }
				X "$ci<dcssch:orderExpression>"
				X "$ci`t<expression xmlns=`"$($script:dcsCommonNs)`">$(Esc-XmlText $exprV)</expression>"
				X "$ci`t<orderType xmlns=`"$($script:dcsCommonNs)`">$oType</orderType>"
				X "$ci`t<autoOrder xmlns=`"$($script:dcsCommonNs)`">$auto</autoOrder>"
				X "$ci</dcssch:orderExpression>"
			}
		}
		if ($typeStr) { Emit-DLValueType -typeStr $typeStr -indent $ci }
		X "$indent</CalculatedField>"
	}
}

function Get-RestrictList {
	param($ur)
	$out = @()
	if (-not $ur) { return ,$out }
	if ($ur -is [System.Management.Automation.PSCustomObject] -or $ur -is [hashtable]) {
		foreach ($k in 'field','condition','group','order') { if ($ur.$k -eq $true) { $out += $k } }
	} elseif ($ur -is [string]) {
		foreach ($tok in ($ur -split '\s+')) { $t = $tok.Trim().TrimStart('#'); if ($t) { $out += $(if ($script:calcRestrictMap[$t]) { $script:calcRestrictMap[$t] } else { $t }) } }
	} else {
		foreach ($r in $ur) { $rr = "$r"; $out += $(if ($script:calcRestrictMap[$rr]) { $script:calcRestrictMap[$rr] } else { $rr }) }
	}
	return ,$out
}

function Emit-RestrictBlock {
	param([string]$tag, $ur, [string]$indent)
	$r = Get-RestrictList $ur
	if ($r.Count -eq 0) { return }
	X "$indent<dcssch:$tag>"
	foreach ($k in @('field','condition','group','order')) { if ($r -contains $k) { X "$indent`t<dcssch:$k>true</dcssch:$k>" } }
	X "$indent</dcssch:$tag>"
}

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	# Прощающий ввод: ведущий префикс приходит копипастой из выгрузки. Без срезания он ломает
	# поиск в словаре — русское имя типа остаётся непереведённым, и платформа отвечает
	# «Неизвестное имя типа». cfg: снимаем всегда — он однозначно означает текущую конфигурацию.
	# Сгенерированный dNpM: (в корпусе на этом URI встречаются d4p1, d5p1, d6p1 — имя префикса
	# платформа выдаёт по порядку объявления) снимаем ТОЛЬКО у ссылочных типов, с точкой:
	# сам по себе префикс многозначен — в формах d5p1:Chart, d5p1:TextDocument,
	# d5p1:GeographicalSchema адресуют чужие пространства имён, и там он часть значения.
	if ($typeStr.StartsWith('cfg:')) {
		$typeStr = $typeStr.Substring(4)
	} elseif ($typeStr.Contains('.') -and $typeStr -match '^d\d+p\d+:') {
		$typeStr = $typeStr.Substring($typeStr.IndexOf(':') + 1)
	}

	# Хвосты, которые дописывает вывод meta-info к множествам типов: суффикс обобщённого метатипа
	# и счётчик состава. Копипаста строки оттуда — обычный путь, поэтому хвост снимаем молча.
	# Срезаем ТОЛЬКО эти известные формы: круглые скобки заняты параметризованными типами
	# (Число(15,2)), слепой срез скобок сломал бы их.
	$typeStr = ($typeStr -replace '\s*\((?:все|all)\)\s*$', '').Trim()
	$typeStr = ($typeStr -replace '\s*[—-]\s*(?:типов|types):\s*\d+\s*$', '').Trim()
	$typeStr = ($typeStr -replace '\s*\((?:типов|types):\s*\d+\)\s*$', '').Trim()

	# Параметризованные типы: Number(15,2), Строка(100)
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }
		return $typeStr
	}

	# Ссылочные типы: СправочникСсылка.Организации → CatalogRef.Организации
	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)  # includes the dot
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	# Простое имя
	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }
	return $typeStr
}

function Emit-Type {
	# $tag/$tagAttrs — обёртка (по умолчанию <Type>); для уточнения типа значений ValueList
	# вызывается с tag="Settings", tagAttrs=' xsi:type="v8:TypeDescription"'.
	param($typeStr, [string]$indent, [string]$tag = "Type", [string]$tagAttrs = "")

	if (-not $typeStr) {
		X "$indent<$tag$tagAttrs/>"
		return
	}

	$typeString = "$typeStr"

	# Composite type: "Type1 | Type2" or "Type1 + Type2"
	$parts = $typeString -split '\s*[|+]\s*'

	X "$indent<$tag$tagAttrs>"
	foreach ($part in $parts) {
		$part = $part.Trim()
		Emit-SingleType -typeStr $part -indent "$indent`t"
	}
	X "$indent</$tag>"
}

function Emit-SingleType {
	param([string]$typeStr, [string]$indent)

	$typeStr = Resolve-TypeStr $typeStr

	# TypeId — тип, заданный глобальным стабильным GUID (<v8:TypeId>, не <v8:Type>). Платформа так
	# сериализует типы, чьё имя в этом контексте недоступно (определяемые/характеристики). GUID
	# глобально стабилен → эмитим verbatim (как роль-по-GUID). Маркер декомпилятора: 'typeid:GUID'.
	if ($typeStr -match '^typeid:([0-9a-fA-F-]{36})$') {
		X "$indent<v8:TypeId>$($Matches[1])</v8:TypeId>"
		return
	}

	# boolean
	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"
		return
	}

	# string or string(N) or string(N,fixed) (AllowedLength: Variable дефолт / Fixed)
	if ($typeStr -match '^string(\((\d+)(\s*,\s*(fixed|variable))?\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		$al = if ($Matches[4] -and $Matches[4].ToLower() -eq 'fixed') { 'Fixed' } else { 'Variable' }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>$al</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"
		return
	}

	# decimal(D,F) or decimal(D,F,nonneg)
	if ($typeStr -match '^decimal\((\d+),(\d+)(,nonneg)?\)$') {
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

	# date / dateTime / time
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

	# ValueTable, ValueTree, ValueList, etc.
	$v8Types = @{
		"ValueTable"       = "v8:ValueTable"
		"ValueTree"        = "v8:ValueTree"
		"ValueList"        = "v8:ValueListType"
		"TypeDescription"  = "v8:TypeDescription"
		"Universal"        = "v8:Universal"
		"FixedArray"       = "v8:FixedArray"
		"FixedStructure"   = "v8:FixedStructure"
	}
	if ($v8Types.ContainsKey($typeStr)) {
		X "$indent<v8:Type>$($v8Types[$typeStr])</v8:Type>"
		return
	}

	# UI types
	$uiTypes = @{
		"FormattedString" = "v8ui:FormattedString"
		"Picture"         = "v8ui:Picture"
		"Color"           = "v8ui:Color"
		"Font"            = "v8ui:Font"
	}
	if ($uiTypes.ContainsKey($typeStr)) {
		X "$indent<v8:Type>$($uiTypes[$typeStr])</v8:Type>"
		return
	}

	# DCS types
	if ($typeStr -match '^DataComposition') {
		$dcsMap = @{
			"DataCompositionSettings"      = "dcsset:DataCompositionSettings"
			"DataCompositionSchema"        = "dcssch:DataCompositionSchema"
			"DataCompositionComparisonType" = "dcscor:DataCompositionComparisonType"
		}
		if ($dcsMap.ContainsKey($typeStr)) {
			X "$indent<v8:Type>$($dcsMap[$typeStr])</v8:Type>"
			return
		}
	}

	# Голые конфигурационные типы (cfg: без .Имя): дин-список, набор констант, общий объект отчёта.
	# Корпус (acc+erp 8.3.24): DynamicList 5205, ConstantsSet 103, ReportObject 10. (Дотированные формы
	# ConstantsSet.X / ReportObject.X ловит общий cfg:-regex ниже.)
	if ($typeStr -in @("DynamicList","ConstantsSet","ReportObject")) {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
		return
	}

	# TypeSet (набор типов) → <v8:TypeSet>: определяемый тип / характеристика (именованные)
	# + «любая ссылка вида» (голый ref-вид без .Имя). Развязка с обычным типом — по наличию точки.
	if ($typeStr -match '^(DefinedType|Characteristic)\.') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}
	if ($typeStr -match '^(AnyRef|AnyIBRef|CatalogRef|DocumentRef|EnumRef|ExchangePlanRef|TaskRef|BusinessProcessRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef)$') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}

	# cfg: references (CatalogRef.XXX, DocumentObject.XXX, etc.)
	if ($typeStr -match '^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfAccountsObject|ChartOfCharacteristicTypesRef|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesRef|ChartOfCalculationTypesObject|ExchangePlanRef|ExchangePlanObject|BusinessProcessRef|BusinessProcessObject|TaskRef|TaskObject|InformationRegisterRecordSet|InformationRegisterRecordManager|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|ConstantsSet|DataProcessorObject|ReportObject)\.') {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
		return
	}

	# Спец-типы платформы с собственным namespace (объявляется ЛОКАЛЬНО на <v8:Type>).
	# Префикс d5p1 неоднозначен (5 разных URI), поэтому маппинг по полному значению типа.
	# К таким типам привязаны спец-поля: mxl→SpreadSheetDocumentField, fd→FormattedDocumentField,
	# d5p1:TextDocument→TextDocumentField, pdfdoc→PDF, pl→Planner, chart/geo/graphscheme/data-analysis.
	$specialTypeNs = @{
		"mxl:SpreadsheetDocument"               = "http://v8.1c.ru/8.2/data/spreadsheet"
		"fd:FormattedDocument"                  = "http://v8.1c.ru/8.2/data/formatted-document"
		"d5p1:TextDocument"                     = "http://v8.1c.ru/8.1/data/txtedt"
		"d5p1:Chart"                            = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:GanttChart"                       = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:Dendrogram"                       = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:FlowchartContextType"             = "http://v8.1c.ru/8.2/data/graphscheme"
		"d5p1:DataAnalysisTimeIntervalUnitType" = "http://v8.1c.ru/8.2/data/data-analysis"
		"d5p1:GeographicalSchema"               = "http://v8.1c.ru/8.2/data/geo"
		"pdfdoc:PDFDocument"                    = "http://v8.1c.ru/8.3/data/pdf"
		"pl:Planner"                            = "http://v8.1c.ru/8.3/data/planner"
	}
	if ($specialTypeNs.ContainsKey($typeStr)) {
		$pref = $typeStr.Substring(0, $typeStr.IndexOf(':'))
		X "$indent<v8:Type xmlns:$pref=`"$($specialTypeNs[$typeStr])`">$typeStr</v8:Type>"
		return
	}

	# Fallback with validation
	if ($script:knownInvalidTypes.ContainsKey($typeStr)) {
		throw "Invalid form attribute type '$typeStr': $($script:knownInvalidTypes[$typeStr])"
	}
	# Платформенный тип с префиксом (v8:/v8ui:/xs:/dcs*:) — эмитим verbatim (напр. v8:UUID, v8:StandardPeriod).
	if ($typeStr -match '^(v8|v8ui|xs|ent|style|sys|web|win|dcs\w*):') {
		X "$indent<v8:Type>$typeStr</v8:Type>"
	} elseif ($typeStr.Contains('.')) {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
	} else {
		Write-Warning "Unrecognized bare type '$typeStr' — will be emitted without namespace prefix"
		X "$indent<v8:Type>$typeStr</v8:Type>"
	}
}

function Get-HandlerName {
	param([string]$elementName, [string]$eventName)
	$suffix = $script:eventSuffixMap[$eventName]
	if ($suffix) {
		return "$elementName$suffix"
	}
	return "$elementName$eventName"
}

function Get-ElementName {
	param($el, [string]$typeKey)
	if ($el.name) { return "$($el.name)" }
	return "$($el.$typeKey)"
}

function Get-EventPairs {
	param($el, [string]$elementName)
	$pairs = New-Object System.Collections.ArrayList
	if ($el.events) {
		foreach ($p in $el.events.PSObject.Properties) {
			# Значение — имя обработчика; null — имя по шаблону; объект { handler, callType } или массив
			# таких объектов (в расширении на одно событие вешают и Before, и After)
			$vals = @($p.Value)   # массив — как есть, одно значение (в т.ч. null) — один элемент
			foreach ($v in $vals) {
				$h = ""; $ct = ""
				if ($v -is [System.Management.Automation.PSCustomObject]) { $h = "$($v.handler)"; $ct = Normalize-CallType "$($v.callType)" $elementName $p.Name } else { $h = "$v" }
				if ([string]::IsNullOrEmpty($h)) { $h = Get-HandlerName -elementName $elementName -eventName $p.Name }
				[void]$pairs.Add([pscustomobject]@{ name = $p.Name; handler = $h; callType = $ct })
			}
		}
	} elseif ($el.on) {
		foreach ($evt in $el.on) {
			if ($evt -is [System.Management.Automation.PSCustomObject]) {
				$evtName = "$($evt.event)"; $h = "$($evt.handler)"; $ct = Normalize-CallType "$($evt.callType)" $elementName $evtName
			} else {
				$evtName = "$evt"; $h = ""; $ct = ""
			}
			if (-not $h) { $h = if ($el.handlers -and $el.handlers.$evtName) { "$($el.handlers.$evtName)" } else { Get-HandlerName -elementName $elementName -eventName $evtName } }
			[void]$pairs.Add([pscustomobject]@{ name = $evtName; handler = $h; callType = $ct })
		}
	}
	return $pairs
}

function Normalize-CallType([string]$raw, [string]$elementName, [string]$eventName) {
	if ([string]::IsNullOrEmpty($raw)) { return '' }
	foreach ($v in @('Before','After','Override')) { if ($raw -eq $v) { return $v } }
	Write-Error "Element '$elementName', event '$eventName': callType '$raw' — expected Before, After or Override"
	exit 1
}

function Emit-Events {
	param($el, [string]$elementName, [string]$indent, [string]$typeKey)

	$pairs = Get-EventPairs -el $el -elementName $elementName
	if ($pairs.Count -eq 0) { return }

	# Validate event names
	if ($typeKey -and $script:knownEvents.ContainsKey($typeKey)) {
		$allowed = $script:knownEvents[$typeKey]
		foreach ($pr in $pairs) {
			if ($allowed.Count -gt 0 -and $allowed -notcontains "$($pr.name)") {
				Write-Host "[WARN] Unknown event '$($pr.name)' for $typeKey '$elementName'. Known: $($allowed -join ', ')"
			}
		}
	}

	X "$indent<Events>"
	foreach ($pr in $pairs) {
		$ctAttr = if ($pr.callType) { " callType=`"$($pr.callType)`"" } else { "" }
		X "$indent`t<Event name=`"$($pr.name)`"$ctAttr>$($pr.handler)</Event>"
	}
	X "$indent</Events>"
}

function Test-CompanionStructured {
	param($content)
	if (-not (($content -is [System.Collections.IDictionary]) -or ($content -is [System.Management.Automation.PSCustomObject]))) { return $false }
	foreach ($k in $script:companionStructKeys) {
		$present = if ($content -is [System.Collections.IDictionary]) { $content.Contains($k) } else { [bool]$content.PSObject.Properties[$k] }
		if ($present) { return $true }
	}
	return $false
}

function Emit-CompanionTitle {
	param($content, [string]$indent)
	$r = Resolve-MLFormatted $content
	$fmt = if ($r.formatted) { 'true' } else { 'false' }
	X "$indent<Title formatted=`"$fmt`">"
	Emit-MLItems -val $r.text -indent "$indent`t"
	X "$indent</Title>"
}

function DI-Attr {
	param($el)
	if ($null -ne $el -and $el.displayImportance) { return " DisplayImportance=`"$(Esc-Xml "$($el.displayImportance)")`"" }
	return ""
}

function Emit-Companion {
	param([string]$tag, [string]$name, [string]$indent, $content = $null)
	$id = New-Id
	$hasContent = $null -ne $content -and -not ($content -is [string] -and "$content" -eq '')
	if (-not $hasContent) {
		X "$indent<$tag name=`"$name`" id=`"$id`"/>"
		return
	}
	$inner = "$indent`t"
	# DI-Attr берём от СОБСТВЕННОГО объекта компаньона ($content), НЕ от ambient $el родителя
	# (PowerShell dynamic scope — иначе companion наследует DisplayImportance владельца: баг).
	X "$indent<$tag name=`"$name`" id=`"$id`"$(DI-Attr $content)>"
	if (Test-CompanionStructured $content) {
		# структурированная форма (own-content). Порядок как у платформы: own-content (флаги/hyperlink/
		# layout/оформление) ПЕРЕД Title (в корпусе layout-first 582 vs 10).
		$txtPresent = if ($content -is [System.Collections.IDictionary]) { $content.Contains('text') } else { [bool]$content.PSObject.Properties['text'] }
		Emit-CommonFlags -el $content -indent $inner
		if ($content.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
		Emit-Layout -el $content -indent $inner
		Emit-Appearance -el $content -indent $inner -profile 'decoration'
		if ($txtPresent) { Emit-CompanionTitle -content $content -indent $inner }
		# ToolTip компаньона (подсказка самой расширенной подсказки) — после Title (порядок схемы LabelDecoration)
		if ($content.tooltip) { Emit-MLText -tag "ToolTip" -text $content.tooltip -indent $inner }
		# События компаньона (ExtendedTooltip = LabelDecoration: напр. URLProcessing у hyperlink-подсказки)
		Emit-Events -el $content -elementName $name -indent $inner -typeKey 'label'
	} else {
		Emit-CompanionTitle -content $content -indent $inner
	}
	X "$indent</$tag>"
}

function Emit-CompanionPanel {
	param([string]$tag, [string]$name, [string]$indent, $panel)
	$id = New-Id
	$autofill = $null
	$children = $null
	$halign = $null
	if ($panel -is [array]) {
		$children = $panel
	} elseif ($null -ne $panel) {
		if ($null -ne $panel.PSObject.Properties['autofill'] -and $null -ne $panel.autofill) { $autofill = [bool]$panel.autofill }
		if ($null -ne $panel.PSObject.Properties['horizontalAlign'] -and "$($panel.horizontalAlign)" -ne '') { $halign = "$($panel.horizontalAlign)" }
		$children = $panel.children
	}
	$hasChildren = $children -and @($children).Count -gt 0
	# Платформа пишет <Autofill> только при false; true = дефолт (тег опускается).
	$emitAfFalse = ($autofill -eq $false)
	if (-not $emitAfFalse -and -not $hasChildren -and -not $halign) {
		X "$indent<$tag name=`"$name`" id=`"$id`"/>"
		return
	}
	X "$indent<$tag name=`"$name`" id=`"$id`"$(DI-Attr $panel)>"
	if ($halign) { X "$indent`t<HorizontalAlign>$halign</HorizontalAlign>" }
	if ($emitAfFalse) { X "$indent`t<Autofill>false</Autofill>" }
	if ($hasChildren) {
		X "$indent`t<ChildItems>"
		foreach ($c in @($children)) { Emit-Element -el $c -indent "$indent`t`t" -inCmdBar $true }
		X "$indent`t</ChildItems>"
	}
	X "$indent</$tag>"
}

function Get-HLocation {
	param($el)
	$v = if ($el -and $el.PSObject.Properties['horizontalLocation']) { $el.horizontalLocation } else { $null }
	if (-not $v) { return $null }
	switch -Regex ("$v".ToLower()) {
		'^(auto|авто)$'          { return $null }    # дефолт — не эмитим
		'^(left|слева|лево)$'    { return 'Left' }
		'^(right|справа|право)$'  { return 'Right' }
		'^(center|центр|по центру)$' { return 'Center' }
		default                  { return "$v" }
	}
}

function Emit-AdditionBody {
	param($props, [string]$source, [string]$srcType, [string]$addName, [string]$indent)
	$inner = "$indent`t"
	X "$inner<AdditionSource>"
	X "$inner`t<Item>$source</Item>"
	X "$inner`t<Type>$srcType</Type>"
	X "$inner</AdditionSource>"
	if ($props) {
		if ($props.PSObject.Properties['title'] -and $props.title) { Emit-MLText -tag "Title" -text $props.title -indent $inner }
		Emit-CommonFlags -el $props -indent $inner
		if ($props.tooltip) { Emit-MLText -tag "ToolTip" -text $props.tooltip -indent $inner }
		if ($props.tooltipRepresentation) { X "$inner<ToolTipRepresentation>$($props.tooltipRepresentation)</ToolTipRepresentation>" }
		$hl = Get-HLocation $props; if ($hl) { X "$inner<HorizontalLocation>$hl</HorizontalLocation>" }
		Emit-Layout -el $props -indent $inner
		Emit-Appearance -el $props -indent $inner -profile 'field'
	}
	Emit-Companion -tag "ContextMenu" -name "${addName}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${addName}РасширеннаяПодсказка" -indent $inner
}

function Emit-Addition {
	param($el, [string]$name, [int]$id, [string]$typeKey, [string]$indent)
	$map = $script:additionTypeMap[$typeKey]
	$source = if ($el.source) { "$($el.source)" } elseif ($script:currentTableName) { $script:currentTableName } else { '' }
	X "$indent<$($map.Tag) name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	Emit-AdditionBody -props $el -source $source -srcType $map.Type -addName $name -indent $indent
	X "$indent</$($map.Tag)>"
}

function Emit-TableAddition {
	param([string]$typeKey, [string]$tableName, [string]$indent, $override = $null)
	$map = $script:additionTypeMap[$typeKey]
	$addName = "$tableName$($map.Suffix)"
	$id = New-Id
	X "$indent<$($map.Tag) name=`"$addName`" id=`"$id`">"
	Emit-AdditionBody -props $override -source $tableName -srcType $map.Type -addName $addName -indent $indent
	X "$indent</$($map.Tag)>"
}

function Get-AdditionOverride {
	param($additions, [string]$typeKey)
	if ($null -eq $additions) { return $null }
	foreach ($k in @($typeKey) + $script:additionKeySynonyms[$typeKey]) {
		$p = $additions.PSObject.Properties[$k]
		if ($p) { return $p.Value }
	}
	return $null
}

function Normalize-ElementTypeSynonyms {
	param($el)
	foreach ($pair in $script:elementTypeSynonyms.GetEnumerator()) {
		if ($null -ne $el.PSObject.Properties[$pair.Key] -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			if ($script:elementTypeStrOnlyKeys -contains $pair.Key -and -not ($el.($pair.Key) -is [string])) { continue }
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}
}

function Normalize-EnumValue {
	param([string]$propName, [string]$value)
	$valid = $script:validEnumValues["$script:objType.$propName"]
	if (-not $valid) { $valid = $script:validEnumValues[$propName] }
	# 1. Check alias dictionary — silent auto-correct. Словарь общий для всех свойств: у свойства со
	# списком алиас берётся, только если его результат в списке (иначе «None» дало бы Nonperiodical везде)
	if ($script:enumValueAliases.ContainsKey($value)) {
		$aliased = $script:enumValueAliases[$value]
		if (-not $valid -or $valid -ccontains $aliased) { return $aliased }
	}
	# 2. Case-insensitive match against valid values — silent. Список вида объекта — раньше общего.
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

function Normalize-EnumTags([string]$text, [string]$rootType = '', [bool]$keepDefaults = $false) {
	$crlf = $text.Contains("`r`n")
	$lines = $text.Replace("`r`n", "`n") -split "`n"
	$stack = New-Object System.Collections.ArrayList
	$drop = @{}
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$line = $lines[$i]
		if ($line -cmatch '^\t*</([A-Za-z_][\w.:-]*)>$') {
			if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Name -ceq $Matches[1]) { $stack.RemoveAt($stack.Count - 1) }
			continue
		}
		if ($line -cmatch '^(\t*)<([A-Za-z_][\w.:-]*)(\s[^>]*)?>$' -and -not $line.EndsWith('/>')) {
			[void]$stack.Add(@{ Name = $Matches[2]; Ind = $Matches[1].Length })
			continue
		}
		if ($stack.Count -eq 0) { continue }
		$m = [regex]::Match($line, '^(\t*)<([A-Za-z]\w*)>([^<]+)</([A-Za-z]\w*)>$')
		if (-not $m.Success -or $m.Groups[2].Value -cne $m.Groups[4].Value) { continue }
		$top = $stack[$stack.Count - 1]
		if ($m.Groups[1].Value.Length -ne $top.Ind + 1) { continue }
		$ptype = if ($stack.Count -eq 1) { if ($top.Name -ceq 'Form') { 'Form' } else { $rootType } } else { $top.Name }
		if (-not $ptype -or ($ptype -cne 'Form' -and -not $script:childTagOrder.ContainsKey($ptype))) { continue }
		$script:objType = $ptype
		$tag = $m.Groups[2].Value
		$v = Normalize-EnumValue $tag $m.Groups[3].Value
		if (-not $keepDefaults -and $script:enumDefaultValues.ContainsKey("$ptype.$tag") -and $script:enumDefaultValues["$ptype.$tag"] -ceq $v) { $drop[$i] = $true; continue }
		if ($v -cne $m.Groups[3].Value) { $lines[$i] = "$($m.Groups[1].Value)<$tag>$v</$tag>" }
	}
	# Строки-умолчания пропускаются по номеру: $null в строковом массиве PS 5.1 становится пустой строкой
	$keep = New-Object System.Collections.Generic.List[string]
	for ($i = 0; $i -lt $lines.Count; $i++) { if (-not $drop.ContainsKey($i)) { $keep.Add($lines[$i]) } }
	$out = $keep -join "`n"
	if ($crlf) { $out = $out.Replace("`n", "`r`n") }
	return $out
}

function Get-ChildRank([string]$parentTag, [string]$childTag) {
	if ($null -eq $script:childRank) {
		$script:childRank = @{}
		foreach ($t in $script:childTagOrder.Keys) {
			$idx = @{}; $i = 0
			foreach ($c in ($script:childTagOrder[$t] -split ' ')) { $idx[$c] = $i; $i++ }
			$script:childRank[$t] = $idx
		}
	}
	$idx = $script:childRank[$parentTag]
	if ($idx -and $idx.ContainsKey($childTag)) { return $idx[$childTag] }
	return -1
}

function Sort-ElementTagOrder([string]$text) {
	$crlf = $text.Contains("`r`n")
	$lines = New-Object System.Collections.Generic.List[string]
	$lines.AddRange([string[]]($text.Replace("`r`n", "`n") -split "`n"))
	Sort-TagBlocks $lines 0 $lines.Count ''
	$out = $lines -join "`n"
	if ($crlf) { $out = $out.Replace("`n", "`r`n") }
	return $out
}

function Get-TagBlockEnd($lines, [int]$i, [string]$ind, [string]$name) {
	$line = $lines[$i]
	if ($line.EndsWith('/>') -and -not $line.Contains('</')) { return $i + 1 }
	if ($line.EndsWith("</$name>")) { return $i + 1 }
	if ($line -cmatch ('^\t*<' + [regex]::Escape($name) + '(\s[^>]*)?>$')) {
		$close = "$ind</$name>"
		$j = $i + 1
		while ($j -lt $lines.Count -and $lines[$j] -cne $close) { $j++ }
		return $j + 1
	}
	# многострочный текст — до строки, которая кончается закрывающим тегом
	$j = $i + 1
	while ($j -lt $lines.Count -and -not $lines[$j - 1].EndsWith("</$name>")) { $j++ }
	return $j
}

function Sort-TagBlocks($lines, [int]$lo, [int]$hi, [string]$parent) {
	$ind = $null
	for ($i = $lo; $i -lt $hi; $i++) {
		if ($lines[$i] -cmatch '^(\t*)<[A-Za-z_]') { $ind = $Matches[1]; break }
	}
	if ($null -eq $ind) { return }
	$blocks = New-Object System.Collections.ArrayList
	$i = $lo
	while ($i -lt $hi) {
		$m = [regex]::Match($lines[$i], '^(\t*)<([A-Za-z_][\w.:-]*)(?=[\s/>])')
		if ($m.Success -and $m.Groups[1].Value -ceq $ind) {
			$e = Get-TagBlockEnd $lines $i $ind $m.Groups[2].Value
			[void]$blocks.Add(@{ Name = $m.Groups[2].Value; S = $i; E = $e })
			$i = $e
		} else { $i++ }
	}
	foreach ($b in $blocks) {
		if ($b.E - $b.S -gt 2 -and $lines[$b.S] -cmatch ('^\t*<' + [regex]::Escape($b.Name) + '(\s[^>]*)?>$')) {
			Sort-TagBlocks $lines ($b.S + 1) ($b.E - 1) $b.Name
		}
	}
	if ($blocks.Count -lt 2 -or -not $parent) { return }
	$ptag = ($parent -split ':')[-1]
	if (-not $script:childTagOrder.ContainsKey($ptag)) { return }
	$total = 0
	foreach ($b in $blocks) { $total += $b.E - $b.S }
	$a = $blocks[0].S; $z = $blocks[$blocks.Count - 1].E
	if ($total -ne $z - $a) { return }   # между детьми есть посторонние строки — не трогаем
	$last = -1
	$keyed = New-Object System.Collections.ArrayList
	for ($k = 0; $k -lt $blocks.Count; $k++) {
		$r = Get-ChildRank $ptag (($blocks[$k].Name -split ':')[-1])
		if ($r -lt 0) { $r = $last }
		$last = $r
		[void]$keyed.Add([pscustomobject]@{ Key = ($r + 1) * 100000 + $k; K = $k })
	}
	$sorted = @($keyed | Sort-Object Key)
	$same = $true
	for ($k = 0; $k -lt $sorted.Count; $k++) { if ($sorted[$k].K -ne $k) { $same = $false; break } }
	if ($same) { return }
	$seq = New-Object System.Collections.Generic.List[string]
	foreach ($s in $sorted) { $b = $blocks[$s.K]; for ($x = $b.S; $x -lt $b.E; $x++) { $seq.Add($lines[$x]) } }
	$lines.RemoveRange($a, $z - $a)
	$lines.InsertRange($a, $seq)
}

function Emit-Element {
	param($el, [string]$indent, [bool]$inCmdBar = $false)

	# Companion-панели (объект/массив-значение) → commandBar/contextMenu, до тип-синонимов.
	Normalize-PanelSynonyms $el

	# Синонимы типа (XML-имя, русское имя) → канонический ключ DSL
	Normalize-ElementTypeSynonyms $el

	# Синонимы ключей-свойств (русские имена 1С → канон. англ.). Case/space-insensitive.
	# Канон побеждает: если задан и русский, и англ. ключ — англ. остаётся, русский отбрасываем.
	foreach ($pn in @($el.PSObject.Properties.Name)) {
		$norm = ($pn -replace '\s','').ToLower()
		$canon = $script:propSynonyms[$norm]
		if ($canon -and $pn -ne $canon) {
			if ($null -eq $el.PSObject.Properties[$canon]) {
				$val = $el.($pn)
				$el | Add-Member -NotePropertyName $canon -NotePropertyValue $val -Force
			}
			$el.PSObject.Properties.Remove($pn) | Out-Null
		}
	}

	# Determine element type from key
	$typeKey = $null
	$xmlTag = $null

	# picture/picField — НИЗКИЙ приоритет: 'picture' это и тип (PictureDecoration), и свойство-иконка
	# у popup/button/cmdBar. Тип-ключ владельца (popup/button/…) должен выиграть.
	# pages/page ПЕРЕД group: у Page/Pages ключ 'group' — это направление раскладки детей
	# (<Group>Horizontal</Group>), а не тип UsualGroup. Реальная UsualGroup ключа page/pages не несёт.
	foreach ($key in @("columnGroup","buttonGroup","pages","page","group","input","check","radio","label","labelField","table","button","calendar","cmdBar","popup","searchString","viewStatus","searchControl","picField","picture","spreadsheet","html","textDoc","formattedDoc","progressBar","trackBar","chart","ganttChart","graphicalSchema","planner","periodField","dendrogram")) {
		if ($el.$key -ne $null) {
			$typeKey = $key
			break
		}
	}

	if (-not $typeKey) {
		Write-Warning "Unknown element type, skipping"
		return
	}

	# Validate known keys — warn about typos and unknown properties
	$knownKeys = @{
		# type keys
		"group"=1;"columnGroup"=1;"buttonGroup"=1;"input"=1;"check"=1;"radio"=1;"label"=1;"labelField"=1;"table"=1;"pages"=1;"page"=1
		"button"=1;"picture"=1;"picField"=1;"calendar"=1;"cmdBar"=1;"popup"=1
		# спец-поля (документ/датчик/диаграмма) — тип-ключи + типоспец. скаляры
		"spreadsheet"=1;"html"=1;"textDoc"=1;"formattedDoc"=1;"progressBar"=1;"trackBar"=1
		"chart"=1;"ganttChart"=1;"graphicalSchema"=1;"planner"=1;"periodField"=1;"dendrogram"=1;"ganttTable"=1
		"showPercent"=1;"largeStep"=1;"markingStep"=1;"step"=1
		"horizontalScrollBar"=1;"viewScalingMode"=1;"output"=1;"selectionShowMode"=1;"protection"=1
		"edit"=1;"showGrid"=1;"showGroups"=1;"showHeaders"=1;"showRowAndColumnNames"=1;"showCellNames"=1
		"pointerType"=1;"drawingSelectionShowMode"=1;"warningOnEditRepresentation"=1;"markingAppearance"=1
		# report-form контекст (generic-скаляры элементов)
		"horizontalSpacing"=1;"representationInContextMenu"=1;"settingsNamedItemDetailedRepresentation"=1
		# хвост: высота элемента списка / ширина выпадающего списка / картинка кнопки выбора / прозрачный пиксель
		"itemHeight"=1;"dropListWidth"=1;"choiceButtonPicture"=1;"transparentPixel"=1
		# хвост CI-форм: динамический заголовок / расширенное редактирование / высота таблицы
		"titleDataPath"=1;"extendedEdit"=1;"maxRowsCount"=1;"autoMaxRowsCount"=1;"heightControlVariant"=1
		"warningOnEdit"=1;"nonselectedPictureText"=1;"editTextUpdate"=1;"footerText"=1
		# columnGroup-specific
		"showInHeader"=1
		# radio-specific
		"radioButtonType"=1;"choiceList"=1;"columnsCount"=1;"checkBoxType"=1;"editMode"=1
		# naming & binding
		"name"=1;"path"=1;"title"=1;"tooltip"=1;"tooltipRepresentation"=1;"extendedTooltip"=1
		# companion-панели (свойства): командная панель + контекстное меню
		"commandBar"=1;"contextMenu"=1
		# источник команд группы/панели (ButtonGroup/CommandBar)
		"commandSource"=1
		# visibility & state
		"visible"=1;"hidden"=1;"enabled"=1;"disabled"=1;"readOnly"=1;"userVisible"=1
		# events ("events" — основной формат; on/handlers — legacy, принимаются ради совместимости)
		"events"=1;"on"=1;"handlers"=1
		# layout
		"titleLocation"=1;"representation"=1;"width"=1;"height"=1
		"horizontalStretch"=1;"verticalStretch"=1;"autoMaxWidth"=1;"autoMaxHeight"=1
		"maxWidth"=1;"maxHeight"=1
		"groupHorizontalAlign"=1;"groupVerticalAlign"=1;"horizontalAlign"=1
		# input-specific
		"multiLine"=1;"passwordMode"=1;"choiceButton"=1;"clearButton"=1
		"spinButton"=1;"dropListButton"=1;"markIncomplete"=1;"skipOnInput"=1;"inputHint"=1
		"textEdit"=1
		"wrap"=1;"openButton"=1;"listChoiceMode"=1;"showInFooter"=1
		"extendedEditMultipleValues"=1;"chooseType"=1;"autoCellHeight"=1
		"choiceButtonRepresentation"=1;"footerHorizontalAlign"=1;"headerHorizontalAlign"=1
		"headerDataPath"=1;"headerFormat"=1;"currentRowUse"=1
		"format"=1;"editFormat"=1;"choiceParameters"=1;"choiceParameterLinks"=1;"typeLink"=1
		# label/hyperlink
		"hyperlink"=1;"formatted"=1
		# group-specific
		"collapsedTitle"=1;"showTitle"=1;"united"=1;"collapsed"=1;"behavior"=1
		# hierarchy
		"children"=1;"columns"=1
		# table-specific
		"changeRowSet"=1;"changeRowOrder"=1;"autoInsertNewRow"=1;"rowFilter"=1;"header"=1;"footer"=1
		"commandBarLocation"=1;"searchStringLocation"=1;"viewStatusLocation"=1;"searchControlLocation"=1
		"excludedCommands"=1
		"choiceMode"=1;"initialTreeView"=1;"enableDrag"=1;"enableStartDrag"=1
		"rowPictureDataPath"=1;"tableAutofill"=1;"heightInTableRows"=1
		"multipleChoice"=1;"searchOnInput"=1;"shortcut"=1
		"rowSelectionMode"=1;"verticalLines"=1;"horizontalLines"=1
		# dynamic-list table block
		"defaultItem"=1;"useAlternationRowColor"=1;"fileDragMode"=1;"autoRefresh"=1
		"autoRefreshPeriod"=1;"choiceFoldersAndItems"=1;"restoreCurrentRow"=1;"showRoot"=1
		"allowRootChoice"=1;"updateOnDataChange"=1;"allowGettingCurrentRowURL"=1
		"userSettingsGroup"=1;"rowsPicture"=1
		# calendar-specific
		"selectionMode"=1;"showCurrentDate"=1;"widthInMonths"=1;"heightInMonths"=1;"showMonthsPanel"=1
		# pages-specific
		"pagesRepresentation"=1
		# button-specific
		"type"=1;"command"=1;"commandName"=1;"stdCommand"=1;"parameter"=1;"defaultButton"=1;"locationInCommandBar"=1;"displayImportance"=1
		# picture/decoration
		"src"=1;"valuesPicture"=1;"loadTransparent"=1;"headerPicture"=1;"footerPicture"=1
		# cmdBar-specific
		"autofill"=1
		# AutoCommandBar-маркер (autofill heuristic) на элементе/таблице
		"autoCmdBar"=1
		# дополнения командной панели таблицы (тип-ключи + свойства)
		"searchString"=1;"viewStatus"=1;"searchControl"=1;"source"=1;"horizontalLocation"=1;"additions"=1
		# generic-скаляры (pass-through) + точечные
		"verticalAlign"=1;"throughAlign"=1;"enableContentChange"=1;"pictureSize"=1;"titleHeight"=1
		"childItemsWidth"=1;"showLeftMargin"=1;"cellHyperlink"=1;"viewMode"=1;"verticalScrollBar"=1
		"rowInputMode"=1;"mask"=1;"createButton"=1;"fixingInTable"=1;"verticalSpacing"=1
		# InputField choice-скаляры
		"choiceListButton"=1;"quickChoice"=1;"autoChoiceIncomplete"=1
		"choiceForm"=1;"choiceHistoryOnInput"=1;"footerDataPath"=1;"minValue"=1;"maxValue"=1
		# Button — пометка toggle-кнопки (ключ 'checked', не 'check' — во избежание конфликта с типом)
		"checked"=1
	}
	# Оформление (цвета/шрифты/граница) — авто-регистрация из самих структур, чтобы allowlist
	# не дрейфовал при добавлении новых ключей/синонимов. Канонические + forgiving-синонимы.
	foreach ($k in $script:appearanceSpec.Keys)     { $knownKeys[$k] = 1 }
	foreach ($k in $script:appearanceSynonyms.Keys) { $knownKeys[$k] = 1 }
	foreach ($k in $script:propSynonyms.Keys)       { $knownKeys[$k] = 1 }
	# Простые скаляры (pass-through) — тоже из своей таблицы: компилятор их выводит, значит, они известны
	foreach ($g in $script:genericScalars)          { $knownKeys[$g.Key] = 1 }
	foreach ($p in $el.PSObject.Properties) {
		if ($p.Name -like '_*') { continue }  # внутренние маркеры (напр. _dynList)
		if (-not $knownKeys.ContainsKey($p.Name)) {
			Write-Warning "Element '$($el.$typeKey)': unknown key '$($p.Name)' — ignored. Check SKILL.md for valid keys."
		}
	}

	$name = Get-ElementName -el $el -typeKey $typeKey
	Assert-UniqueName -name $name -seen $script:seenElementNames -kind 'element'
	$id = New-Id

	switch ($typeKey) {
		"group"    { Emit-Group -el $el -name $name -id $id -indent $indent }
		"columnGroup" { Emit-ColumnGroup -el $el -name $name -id $id -indent $indent }
		"buttonGroup" { Emit-ButtonGroup -el $el -name $name -id $id -indent $indent }
		"input"    { Emit-Input -el $el -name $name -id $id -indent $indent }
		"check"    { Emit-Check -el $el -name $name -id $id -indent $indent }
		"radio"    { Emit-Radio -el $el -name $name -id $id -indent $indent }
		"label"    { Emit-Label -el $el -name $name -id $id -indent $indent }
		"labelField" { Emit-LabelField -el $el -name $name -id $id -indent $indent }
		"table"    { Emit-Table -el $el -name $name -id $id -indent $indent }
		"pages"    { Emit-Pages -el $el -name $name -id $id -indent $indent }
		"page"     { Emit-Page -el $el -name $name -id $id -indent $indent }
		"button"   { Emit-Button -el $el -name $name -id $id -indent $indent -inCmdBar $inCmdBar }
		"picture"  { Emit-PictureDecoration -el $el -name $name -id $id -indent $indent }
		"searchString"  { Emit-Addition -el $el -name $name -typeKey "searchString"  -id $id -indent $indent }
		"viewStatus"    { Emit-Addition -el $el -name $name -typeKey "viewStatus"    -id $id -indent $indent }
		"searchControl" { Emit-Addition -el $el -name $name -typeKey "searchControl" -id $id -indent $indent }
		"picField" { Emit-PictureField -el $el -name $name -id $id -indent $indent }
		"calendar" { Emit-Calendar -el $el -name $name -id $id -indent $indent }
		"cmdBar"   { Emit-CommandBar -el $el -name $name -id $id -indent $indent }
		"popup"    { Emit-Popup -el $el -name $name -id $id -indent $indent }
		"spreadsheet"  { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "SpreadSheetDocumentField" -typeKey "spreadsheet" }
		"html"         { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "HTMLDocumentField" -typeKey "html" }
		"textDoc"      { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "TextDocumentField" -typeKey "textDoc" }
		"formattedDoc" { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "FormattedDocumentField" -typeKey "formattedDoc" }
		"progressBar"  { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "ProgressBarField" -typeKey "progressBar" }
		"trackBar"     { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "TrackBarField" -typeKey "trackBar" }
		"chart"           { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "ChartField" -typeKey "chart" }
		"graphicalSchema" { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "GraphicalSchemaField" -typeKey "graphicalSchema" }
		"planner"         { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "PlannerField" -typeKey "planner" }
		"periodField"     { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "PeriodField" -typeKey "periodField" }
		"dendrogram"      { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "DendrogramField" -typeKey "dendrogram" }
		"ganttChart"      { Emit-GanttChart -el $el -name $name -id $id -indent $indent }
	}
}

function Emit-XrFlag {
	param([string]$tag, $val, [string]$indent)
	if ($null -eq $val) { return }
	if ($val -is [bool]) {
		X "$indent<$tag>"
		X "$indent`t<xr:Common>$(if ($val){'true'}else{'false'})</xr:Common>"
		X "$indent</$tag>"
		return
	}
	# объектная форма { common, roles }
	$common = if ($null -ne $val.common) { [bool]$val.common } else { $false }
	X "$indent<$tag>"
	X "$indent`t<xr:Common>$(if ($common){'true'}else{'false'})</xr:Common>"
	if ($val.roles) {
		foreach ($r in $val.roles.PSObject.Properties) {
			# Forgiving: принимаем имя без префикса, с "Role." или кириллическим "Роль." → нормализуем в "Role.".
			# Роль по GUID (заимствованная/расширение — name="<guid>" без префикса) эмитим как есть.
			$rname = "$($r.Name)" -replace '^(Role|Роль)\.', ''
			if ($rname -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $rname = "Role.$rname" }
			$rval = if ([bool]$r.Value) { 'true' } else { 'false' }
			X "$indent`t<xr:Value name=`"$rname`">$rval</xr:Value>"
		}
	}
	X "$indent</$tag>"
}

function Emit-CommonFlags {
	param($el, [string]$indent)
	if ($el.visible -eq $false -or $el.hidden -eq $true) { X "$indent<Visible>false</Visible>" }
	if ($null -ne $el.userVisible) { Emit-XrFlag -tag 'UserVisible' -val $el.userVisible -indent $indent }
	if ($el.enabled -eq $false -or $el.disabled -eq $true) { X "$indent<Enabled>false</Enabled>" }
	if ($el.readOnly -eq $true) { X "$indent<ReadOnly>true</ReadOnly>" }
}

function Emit-CommonElementProps {
	param($el, [string]$indent)
	if ($el.defaultItem -eq $true) { X "$indent<DefaultItem>true</DefaultItem>" }
	if ($el.PSObject.Properties['skipOnInput'] -and $null -ne $el.skipOnInput) {
		$siv = if ($el.skipOnInput -eq $true) { 'true' } else { 'false' }
		X "$indent<SkipOnInput>$siv</SkipOnInput>"
	}
	# EnableStartDrag — фактическое значение (платформа эмитит и явный false, напр. SpreadSheet)
	if ($null -ne $el.enableStartDrag) { X "$indent<EnableStartDrag>$(if ($el.enableStartDrag){'true'}else{'false'})</EnableStartDrag>" }
	if ($el.fileDragMode) { X "$indent<FileDragMode>$($el.fileDragMode)</FileDragMode>" }
	# Cell-свойства поля в таблице (общие для Input/Label/Picture/CheckBox): захват «как есть»
	foreach ($p in @(@('showInHeader','ShowInHeader'), @('showInFooter','ShowInFooter'), @('autoCellHeight','AutoCellHeight'))) {
		if ($null -ne $el.($p[0])) { X "$indent<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	# Динамический заголовок колонки-группы из данных (HeaderDataPath) — перед HeaderHorizontalAlign (порядок XSD)
	if ($el.headerDataPath) { X "$indent<HeaderDataPath>$(Esc-XmlText "$($el.headerDataPath)")</HeaderDataPath>" }
	if ($el.footerHorizontalAlign) { X "$indent<FooterHorizontalAlign>$($el.footerHorizontalAlign)</FooterHorizontalAlign>" }
	if ($el.headerHorizontalAlign) { X "$indent<HeaderHorizontalAlign>$($el.headerHorizontalAlign)</HeaderHorizontalAlign>" }
	# Формат заголовка колонки-группы (ML-текст) — после HeaderHorizontalAlign (порядок XSD)
	if ($el.headerFormat) { Emit-MLText -tag "HeaderFormat" -text $el.headerFormat -indent $indent }
}

function Emit-PictureRef {
	param($val, [string]$picTag, [string]$indent)
	if (-not $val) { return }
	$src = $null; $lt = $false; $tpx = $null
	if ($val -is [string]) { $src = $val }
	else { $src = $val.src; if ($val.loadTransparent -eq $true) { $lt = $true }; $tpx = $val.transparentPixel }
	if (-not $src) { return }
	$srcStr = "$src"
	X "$indent<$picTag>"
	if ($srcStr -match '^abs:(.*)$') { X "$indent`t<xr:Abs>$(Esc-XmlText $matches[1])</xr:Abs>" }
	else { X "$indent`t<xr:Ref>$(Esc-XmlText $srcStr)</xr:Ref>" }
	X "$indent`t<xr:LoadTransparent>$(if ($lt) { 'true' } else { 'false' })</xr:LoadTransparent>"
	if ($tpx) { X "$indent`t<xr:TransparentPixel x=`"$($tpx.x)`" y=`"$($tpx.y)`"/>" }
	X "$indent</$picTag>"
}

function Emit-ColumnPics {
	param($el, [string]$indent)
	Emit-PictureRef -val $el.headerPicture -picTag 'HeaderPicture' -indent $indent
	Emit-PictureRef -val $el.footerPicture -picTag 'FooterPicture' -indent $indent
}

function Emit-CommandPicture {
	param($pic, $elemLt, [string]$indent)
	if (-not $pic) { return }
	$src = $null; $lt = $null; $tpx = $null
	if ($pic -is [string]) { $src = $pic }
	else { $src = $pic.src; if ($null -ne $pic.loadTransparent) { $lt = [bool]$pic.loadTransparent }; $tpx = $pic.transparentPixel }
	if (-not $src) { return }
	if ($null -eq $lt -and $null -ne $elemLt) { $lt = [bool]$elemLt }
	$srcStr = "$src"
	X "$indent<Picture>"
	if ($srcStr -match '^abs:(.*)$') { X "$indent`t<xr:Abs>$(Esc-XmlText $matches[1])</xr:Abs>" }
	else { X "$indent`t<xr:Ref>$(Esc-XmlText $srcStr)</xr:Ref>" }
	X "$indent`t<xr:LoadTransparent>$(if ($lt -eq $false) { 'false' } else { 'true' })</xr:LoadTransparent>"
	if ($tpx) { X "$indent`t<xr:TransparentPixel x=`"$($tpx.x)`" y=`"$($tpx.y)`"/>" }
	X "$indent</Picture>"
}

function Emit-GenericScalars {
	param($el, [string]$indent)
	if ($null -eq $el) { return }
	foreach ($s in $script:genericScalars) {
		$p = $el.PSObject.Properties[$s.Key]
		if (-not $p -or $null -eq $p.Value) { continue }
		if ($s.Kind -eq 'bool') {
			X "$indent<$($s.Tag)>$(if ($p.Value){'true'}else{'false'})</$($s.Tag)>"
		} else {
			$v = "$($p.Value)"; if ($v -eq '') { continue }
			X "$indent<$($s.Tag)>$(Esc-XmlText $v)</$($s.Tag)>"
		}
	}
}

function Get-AppearanceValue {
	param($el, [string]$canonical)
	if ($null -eq $el) { return $null }
	$p = $el.PSObject.Properties[$canonical]
	if ($p) { return $p.Value }
	foreach ($syn in $script:appearanceSynonyms.Keys) {
		if ($script:appearanceSynonyms[$syn] -eq $canonical) {
			$pp = $el.PSObject.Properties[$syn]
			if ($pp) { return $pp.Value }
		}
	}
	return $null
}

function Emit-FontTag {
	param([string]$tag, $val, [string]$indent)
	if ($val -is [string]) {
		X "$indent<$tag ref=`"$(Esc-Xml $val)`" kind=`"StyleItem`"/>"
		return
	}
	$attrs = @()
	foreach ($a in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
		$pp = $val.PSObject.Properties[$a]
		if ($pp -and $null -ne $pp.Value) {
			$v = $pp.Value
			if ($v -is [bool]) { $v = if ($v) {'true'} else {'false'} }
			$attrs += "$a=`"$(Esc-Xml "$v")`""
		}
	}
	X "$indent<$tag $($attrs -join ' ')/>"
}

function Emit-BorderTag {
	param($val, [string]$indent)
	if ($val -is [string]) { X "$indent<Border ref=`"$(Esc-Xml $val)`"/>"; return }
	$refP = $val.PSObject.Properties['ref']
	if ($refP -and $refP.Value) { X "$indent<Border ref=`"$(Esc-Xml "$($refP.Value)")`"/>"; return }
	$width = if ($val.PSObject.Properties['width'] -and $null -ne $val.width) { $val.width } else { 1 }
	$style = if ($val.PSObject.Properties['style']) { "$($val.style)" } else { $null }
	X "$indent<Border width=`"$width`">"
	if ($style) { X "$indent`t<v8ui:style xsi:type=`"v8ui:ControlBorderType`">$(Esc-XmlText $style)</v8ui:style>" }
	X "$indent</Border>"
}

function PL-Get {
	param($o, [string]$k, $def = $null)
	if ($null -ne $o -and $o.PSObject.Properties[$k] -and $null -ne $o.$k) { return $o.$k }
	return $def
}

function PL-Bool {
	param($v)
	if ($v -is [bool]) { if ($v) { 'true' } else { 'false' } }
	elseif ("$v" -eq 'True') { 'true' }
	elseif ("$v" -eq 'False') { 'false' }
	else { "$v" }
}

function Emit-PlannerColor {
	param([string]$tag, $o, [string]$key, [string]$ind)
	X "$ind<pl:$tag>$(Esc-XmlText "$(PL-Get $o $key 'auto')")</pl:$tag>"
}

function Emit-PlannerText {
	param([string]$tag, $v, [string]$ind)
	if ([string]::IsNullOrEmpty("$v")) { X "$ind<pl:$tag/>" }
	else { X "$ind<pl:$tag>$(Esc-XmlText "$v")</pl:$tag>" }
}

function Test-PlannerRef {
	param([string]$v)
	return ($v -match '^(Enum|Catalog|Document|ChartOfAccounts|ChartOfCalculationTypes|ChartOfCharacteristicTypes|ExchangePlan|BusinessProcess|Task)\.' -or `
		$v -match '\.EnumValue\.' -or $v -match 'EmptyRef$' -or `
		$v -match '^(Перечисление|Справочник|Документ|ПланСчетов|ПланВидовХарактеристик|ПланВидовРасчета|ПланОбмена|БизнесПроцесс|Задача)\.')
}

function Emit-PlannerValue {
	param($v, [string]$ind)
	if ($null -eq $v -or "$v" -eq '') { X "$ind<pl:value xsi:nil=`"true`"/>"; return }
	$t = if (Test-PlannerRef "$v") { 'xr:DesignTimeRef' } else { 'xs:string' }
	X "$ind<pl:value xsi:type=`"$t`">$(Esc-XmlText "$v")</pl:value>"
}

function Emit-PlannerFont {
	param($o, [string]$ind)
	$f = PL-Get $o 'font' $null
	if ($null -eq $f) { X "$ind<pl:font kind=`"AutoFont`"/>"; return }
	Emit-FontTag -tag 'pl:font' -val $f -indent $ind
}

function Emit-PlannerBorder {
	param($o, [string]$ind, [string]$key = 'border')
	$b = PL-Get $o $key $null
	$bw = if ($b) { PL-Get $b 'width' 1 } else { 1 }
	$bs = if ($b) { PL-Get $b 'style' 'Single' } else { 'Single' }
	X "$ind<pl:border width=`"$bw`">"
	X "$ind`t<v8ui:style xsi:type=`"v8ui:ControlBorderType`">$(Esc-XmlText "$bs")</v8ui:style>"
	X "$ind</pl:border>"
}

function Emit-PlannerLevel {
	param($lv, [string]$cns, [string]$ind)
	$li = "$ind`t"
	X "$ind<level xmlns=`"$cns`">"
	X "$li<measure>$(Esc-XmlText "$(PL-Get $lv 'measure' 'Hour')")</measure>"
	X "$li<interval>$(PL-Get $lv 'interval' 1)</interval>"
	X "$li<show>$(PL-Bool (PL-Get $lv 'show' $true))</show>"
	$line = PL-Get $lv 'line' $null
	$lw  = if ($line) { PL-Get $line 'width' 1 } else { 1 }
	$lg  = if ($line) { PL-Get $line 'gap' $false } else { $false }
	$lst = if ($line) { PL-Get $line 'style' 'Solid' } else { 'Solid' }
	X "$li<line width=`"$lw`" gap=`"$(PL-Bool $lg)`">"
	X "$li`t<v8ui:style xsi:type=`"v8ui:ChartLineType`">$(Esc-XmlText "$lst")</v8ui:style>"
	X "$li</line>"
	X "$li<scaleColor>$(Esc-XmlText "$(PL-Get $lv 'scaleColor' 'auto')")</scaleColor>"
	X "$li<dayFormatRule>$(Esc-XmlText "$(PL-Get $lv 'dayFormatRule' 'MonthDayWeekDay')")</dayFormatRule>"
	$fmt = PL-Get $lv 'format' $null
	if ($null -eq $fmt) { $fmt = [ordered]@{ '#' = 'DF="HH:mm"'; 'ru' = 'DF="HH:mm"' } }
	X "$li<format>"
	Emit-MLItems -val $fmt -indent "$li`t"
	X "$li</format>"
	$labels = PL-Get $lv 'labels' $null
	$ticks  = if ($labels) { PL-Get $labels 'ticks' 0 } else { 0 }
	X "$li<labels>"
	X "$li`t<ticks>$ticks</ticks>"
	X "$li</labels>"
	X "$li<backColor>$(Esc-XmlText "$(PL-Get $lv 'backColor' 'auto')")</backColor>"
	X "$li<textColor>$(Esc-XmlText "$(PL-Get $lv 'textColor' 'auto')")</textColor>"
	X "$li<showPereodicalLabels>$(PL-Bool (PL-Get $lv 'showPereodicalLabels' $true))</showPereodicalLabels>"
	X "$ind</level>"
}

function Emit-PlannerTimeScale {
	param($ts, [string]$ind)
	$cns = $script:CHART_NS
	$ci = "$ind`t"
	X "$ind<pl:timeScale>"
	X "$ci<placement xmlns=`"$cns`">$(Esc-XmlText "$(if ($ts) { PL-Get $ts 'placement' 'Left' } else { 'Left' })")</placement>"
	$levels = if ($ts) { @(PL-Get $ts 'levels' @()) } else { @() }
	if (@($levels).Count -eq 0) { $levels = @($null) }   # один уровень-дефолт
	foreach ($lv in $levels) { Emit-PlannerLevel $lv $cns $ci }
	$transp = if ($ts) { PL-Get $ts 'transparent' $false } else { $false }
	X "$ci<transparent xmlns=`"$cns`">$(PL-Bool $transp)</transparent>"
	X "$ci<backColor xmlns=`"$cns`">$(Esc-XmlText "$(if ($ts) { PL-Get $ts 'backColor' 'auto' } else { 'auto' })")</backColor>"
	X "$ci<textColor xmlns=`"$cns`">$(Esc-XmlText "$(if ($ts) { PL-Get $ts 'textColor' 'auto' } else { 'auto' })")</textColor>"
	X "$ci<currentLevel xmlns=`"$cns`">$(if ($ts) { PL-Get $ts 'currentLevel' 0 } else { 0 })</currentLevel>"
	X "$ind</pl:timeScale>"
}

function Emit-PlannerItem {
	param($it, [string]$ind)
	X "$ind<pl:item>"
	$ii = "$ind`t"
	Emit-PlannerValue (PL-Get $it 'value' $null) $ii
	Emit-PlannerText 'text' (PL-Get $it 'text' '') $ii
	Emit-PlannerText 'tooltip' (PL-Get $it 'tooltip' '') $ii
	X "$ii<pl:begin>$(PL-Get $it 'begin' '0001-01-01T00:00:00')</pl:begin>"
	X "$ii<pl:end>$(PL-Get $it 'end' '0001-01-01T00:00:00')</pl:end>"
	Emit-PlannerColor 'borderColor' $it 'borderColor' $ii
	Emit-PlannerColor 'backColor'   $it 'backColor'   $ii
	Emit-PlannerColor 'textColor'   $it 'textColor'   $ii
	Emit-PlannerFont $it $ii
	X "$ii<pl:dimensionValues/>"
	X "$ii<pl:replacementDate>$(PL-Get $it 'replacementDate' '0001-01-01T00:00:00')</pl:replacementDate>"
	X "$ii<pl:deleted>$(PL-Bool (PL-Get $it 'deleted' $false))</pl:deleted>"
	$id = PL-Get $it 'id' $null
	if ($null -eq $id) { $id = [guid]::NewGuid().ToString() }
	X "$ii<pl:id>$id</pl:id>"
	X "$ii<pl:textFormatted>$(PL-Bool (PL-Get $it 'textFormatted' $false))</pl:textFormatted>"
	Emit-PlannerBorder $it $ii 'border'
	X "$ii<pl:editMode>$(Esc-XmlText "$(PL-Get $it 'editMode' 'EnableEdit')")</pl:editMode>"
	X "$ind</pl:item>"
}

function Emit-PlannerDimElement {
	param($el, [string]$ind)
	X "$ind<pl:item>"
	$ii = "$ind`t"
	Emit-PlannerValue (PL-Get $el 'value' $null) $ii
	Emit-PlannerText 'text' (PL-Get $el 'text' '') $ii
	Emit-PlannerColor 'borderColor' $el 'borderColor' $ii
	Emit-PlannerColor 'backColor'   $el 'backColor'   $ii
	Emit-PlannerColor 'textColor'   $el 'textColor'   $ii
	Emit-PlannerFont $el $ii
	foreach ($sub in @(PL-Get $el 'elements' @())) { Emit-PlannerDimElement $sub $ii }
	X "$ii<pl:showOnlySubordinatesAreas>$(PL-Bool (PL-Get $el 'showOnlySubordinatesAreas' $true))</pl:showOnlySubordinatesAreas>"
	X "$ii<pl:textFormatted>$(PL-Bool (PL-Get $el 'textFormatted' $false))</pl:textFormatted>"
	X "$ind</pl:item>"
}

function Emit-PlannerDimension {
	param($d, [string]$ind)
	X "$ind<pl:dimension>"
	$di = "$ind`t"
	Emit-PlannerValue (PL-Get $d 'value' $null) $di
	Emit-PlannerText 'text' (PL-Get $d 'text' '') $di
	Emit-PlannerColor 'borderColor' $d 'borderColor' $di
	Emit-PlannerColor 'backColor'   $d 'backColor'   $di
	Emit-PlannerColor 'textColor'   $d 'textColor'   $di
	Emit-PlannerFont $d $di
	foreach ($el in @(PL-Get $d 'elements' @())) { Emit-PlannerDimElement $el $di }
	X "$di<pl:textFormatted>$(PL-Bool (PL-Get $d 'textFormatted' $false))</pl:textFormatted>"
	X "$ind</pl:dimension>"
}

function Emit-PlannerSettings {
	param($pl, [string]$ind)
	X "$ind<Settings xmlns:pl=`"$($script:PLANNER_NS)`" xsi:type=`"pl:Planner`">"
	$si = "$ind`t"
	foreach ($it in @(PL-Get $pl 'items' @())) { Emit-PlannerItem $it $si }
	foreach ($d in @(PL-Get $pl 'dimensions' @())) { Emit-PlannerDimension $d $si }
	Emit-PlannerColor 'borderColor' $pl 'borderColor' $si
	Emit-PlannerColor 'backColor'   $pl 'backColor'   $si
	Emit-PlannerColor 'textColor'   $pl 'textColor'   $si
	Emit-PlannerColor 'lineColor'   $pl 'lineColor'   $si
	Emit-PlannerFont $pl $si
	X "$si<pl:beginOfRepresentationPeriod>$(PL-Get $pl 'beginOfRepresentationPeriod' '0001-01-01T00:00:00')</pl:beginOfRepresentationPeriod>"
	X "$si<pl:endOfRepresentationPeriod>$(PL-Get $pl 'endOfRepresentationPeriod' '0001-01-01T00:00:00')</pl:endOfRepresentationPeriod>"
	X "$si<pl:alignElementsOfTimeScale>$(PL-Bool (PL-Get $pl 'alignElementsOfTimeScale' $true))</pl:alignElementsOfTimeScale>"
	X "$si<pl:displayTimeScaleWrapHeaders>$(PL-Bool (PL-Get $pl 'displayTimeScaleWrapHeaders' $true))</pl:displayTimeScaleWrapHeaders>"
	X "$si<pl:displayWrapHeaders>$(PL-Bool (PL-Get $pl 'displayWrapHeaders' $true))</pl:displayWrapHeaders>"
	$wfmt = PL-Get $pl 'timeScaleWrapHeadersFormat' $null
	if ($null -eq $wfmt) { $wfmt = [ordered]@{ '#' = 'DLF="DD"'; 'ru' = 'DLF="DD"' } }
	Emit-MLText -tag 'pl:timeScaleWrapHeadersFormat' -text $wfmt -indent $si
	X "$si<pl:periodicVariantUnit>$(Esc-XmlText "$(PL-Get $pl 'periodicVariantUnit' 'Day')")</pl:periodicVariantUnit>"
	X "$si<pl:periodicVariantRepetition>$(PL-Get $pl 'periodicVariantRepetition' 1)</pl:periodicVariantRepetition>"
	X "$si<pl:timeScaleWrapBeginIndent>$(PL-Get $pl 'timeScaleWrapBeginIndent' 0)</pl:timeScaleWrapBeginIndent>"
	X "$si<pl:timeScaleWrapEndIndent>$(PL-Get $pl 'timeScaleWrapEndIndent' 0)</pl:timeScaleWrapEndIndent>"
	Emit-PlannerTimeScale (PL-Get $pl 'timeScale' $null) $si
	$period = PL-Get $pl 'period' $null
	if ($period) {
		X "$si<pl:period>"
		X "$si`t<pl:begin>$(PL-Get $period 'begin' '0001-01-01T00:00:00')</pl:begin>"
		X "$si`t<pl:end>$(PL-Get $period 'end' '0001-01-01T00:00:00')</pl:end>"
		X "$si</pl:period>"
	}
	X "$si<pl:displayCurrentDate>$(PL-Bool (PL-Get $pl 'displayCurrentDate' $true))</pl:displayCurrentDate>"
	X "$si<pl:itemsTimeRepresentation>$(Esc-XmlText "$(PL-Get $pl 'itemsTimeRepresentation' 'BeginTime')")</pl:itemsTimeRepresentation>"
	X "$si<pl:itemsBehaviorWhenSpaceInsufficient>$(Esc-XmlText "$(PL-Get $pl 'itemsBehaviorWhenSpaceInsufficient' 'CollapseItems')")</pl:itemsBehaviorWhenSpaceInsufficient>"
	X "$si<pl:autoMinColumnWidth>$(PL-Bool (PL-Get $pl 'autoMinColumnWidth' $true))</pl:autoMinColumnWidth>"
	X "$si<pl:autoMinRowHeight>$(PL-Bool (PL-Get $pl 'autoMinRowHeight' $true))</pl:autoMinRowHeight>"
	X "$si<pl:minColumnWidth>$(PL-Get $pl 'minColumnWidth' 0)</pl:minColumnWidth>"
	X "$si<pl:minRowHeight>$(PL-Get $pl 'minRowHeight' 0)</pl:minRowHeight>"
	X "$si<pl:fixDimensionsHeader>$(Esc-XmlText "$(PL-Get $pl 'fixDimensionsHeader' 'auto')")</pl:fixDimensionsHeader>"
	X "$si<pl:fixTimeScaleHeader>$(Esc-XmlText "$(PL-Get $pl 'fixTimeScaleHeader' 'auto')")</pl:fixTimeScaleHeader>"
	Emit-PlannerBorder $pl $si 'border'
	X "$si<pl:newItemsTextType>$(Esc-XmlText "$(PL-Get $pl 'newItemsTextType' 'String')")</pl:newItemsTextType>"
	X "$ind</Settings>"
}

function Get-Keys { param($o) if ($o -is [System.Collections.IDictionary]) { return @($o.Keys) } else { return @($o.PSObject.Properties.Name) } }

function Get-Prop { param($o, [string]$k) if ($o -is [System.Collections.IDictionary]) { return $o[$k] } else { $p = $o.PSObject.Properties[$k]; if ($p) { return $p.Value } else { return $null } } }

function Emit-ChartNode {
	param([string]$name, $val, [string]$ind)
	if ($script:CHART_ML_FIELDS.Contains($name)) {
		if ($null -eq $val -or "$val" -eq '') { X "$ind<d4p1:$name/>"; return }
		X "$ind<d4p1:$name>"; Emit-MLItems -val $val -indent "$ind`t"; X "$ind</d4p1:$name>"; return
	}
	if (($val -is [System.Collections.IList]) -and ($val -isnot [string])) {
		foreach ($e in $val) { Emit-ChartNode $name $e $ind }
		return
	}
	if (($val -is [System.Management.Automation.PSCustomObject]) -or ($val -is [System.Collections.IDictionary])) {
		$keys = Get-Keys $val
		if ($script:CHART_ATTR_FIELDS.Contains($name)) {
			$attrs = @(); foreach ($k in $keys) { $v = Get-Prop $val $k; if ($v -is [bool]) { $v = PL-Bool $v }; $attrs += "$k=`"$(Esc-Xml "$v")`"" }
			X "$ind<d4p1:$name $($attrs -join ' ')/>"; return
		}
		if ($keys -contains 'gap') {
			$w = Get-Prop $val 'width'; $g = Get-Prop $val 'gap'; $st = Get-Prop $val 'style'
			X "$ind<d4p1:$name width=`"$w`" gap=`"$(PL-Bool $g)`">"
			X "$ind`t<v8ui:style xsi:type=`"v8ui:ChartLineType`">$(Esc-XmlText "$st")</v8ui:style>"
			X "$ind</d4p1:$name>"; return
		}
		if (($keys -contains 'style') -and ($keys -contains 'width')) {
			$w = Get-Prop $val 'width'; $st = Get-Prop $val 'style'
			X "$ind<d4p1:$name width=`"$w`">"
			X "$ind`t<v8ui:style xsi:type=`"v8ui:ControlBorderType`">$(Esc-XmlText "$st")</v8ui:style>"
			X "$ind</d4p1:$name>"; return
		}
		$isFont = $false; foreach ($fk in $script:CHART_FONT_KEYS) { if ($keys -contains $fk) { $isFont = $true; break } }
		if ($isFont) {
			$attrs = @(); foreach ($fk in $script:CHART_FONT_KEYS) { if ($keys -contains $fk) { $v = Get-Prop $val $fk; if ($v -is [bool]) { $v = PL-Bool $v }; $attrs += "$fk=`"$(Esc-Xml "$v")`"" } }
			X "$ind<d4p1:$name $($attrs -join ' ')/>"; return
		}
		if (@($keys).Count -eq 0) { X "$ind<d4p1:$name/>"; return }
		X "$ind<d4p1:$name>"
		foreach ($k in $keys) { Emit-ChartNode $k (Get-Prop $val $k) "$ind`t" }
		X "$ind</d4p1:$name>"
		return
	}
	if ($null -eq $val -or "$val" -eq '') { X "$ind<d4p1:$name/>"; return }
	if ($val -is [bool]) { X "$ind<d4p1:$name>$(PL-Bool $val)</d4p1:$name>"; return }
	X "$ind<d4p1:$name>$(Esc-XmlText "$val")</d4p1:$name>"
}

function Emit-ChartSettings {
	param($chart, [string]$ind, [string]$ctype = 'd4p1:Chart')
	X "$ind<Settings xmlns:d4p1=`"$($script:CHART_NS)`" xsi:type=`"$ctype`">"
	foreach ($k in (Get-Keys $chart)) { Emit-ChartNode $k (Get-Prop $chart $k) "$ind`t" }
	X "$ind</Settings>"
}

function Emit-Appearance {
	param($el, [string]$indent, [string]$profile = 'field')
	if ($null -eq $el) { return }
	$order = switch ($profile) {
		'decoration' { $script:appOrderDecoration }
		'button'     { $script:appOrderButton }
		default      { $script:appOrderField }
	}
	foreach ($key in $order) {
		$val = Get-AppearanceValue -el $el -canonical $key
		if ($null -eq $val -or ($val -is [string] -and $val -eq '')) { continue }
		$spec = $script:appearanceSpec[$key]
		switch ($spec.kind) {
			'color'  { X "$indent<$($spec.tag)>$(Esc-XmlText "$val")</$($spec.tag)>" }
			'font'   { Emit-FontTag -tag $spec.tag -val $val -indent $indent }
			'border' { Emit-BorderTag -val $val -indent $indent }
		}
	}
}

function Emit-Layout {
	param($el, [string]$indent, [switch]$skipHeight, [bool]$multiLineDefault = $false)
	# CommandSet (отключённые команды редактора) — общее свойство поля (input/label/check/
	# spreadsheet/html/formatted/picture); в схеме рано (после TitleLocation, перед скалярами).
	if ($el.excludedCommands -and @($el.excludedCommands).Count -gt 0) {
		X "$indent<CommandSet>"
		foreach ($cmd in $el.excludedCommands) { X "$indent`t<ExcludedCommand>$cmd</ExcludedCommand>" }
		X "$indent</CommandSet>"
	}
	Emit-CommonElementProps -el $el -indent $indent
	$amwExplicit = ($el.PSObject.Properties.Name -contains 'autoMaxWidth')
	if ($amwExplicit) {
		if ($el.autoMaxWidth -eq $false) { X "$indent<AutoMaxWidth>false</AutoMaxWidth>" }
	} elseif ($multiLineDefault) {
		X "$indent<AutoMaxWidth>false</AutoMaxWidth>"
	}
	if ($null -ne $el.maxWidth) { X "$indent<MaxWidth>$($el.maxWidth)</MaxWidth>" }
	if ($el.autoMaxHeight -eq $false) { X "$indent<AutoMaxHeight>false</AutoMaxHeight>" }
	if ($null -ne $el.maxHeight) { X "$indent<MaxHeight>$($el.maxHeight)</MaxHeight>" }
	if ($el.width) { X "$indent<Width>$($el.width)</Width>" }
	if (-not $skipHeight -and $el.height) { X "$indent<Height>$($el.height)</Height>" }
	if ($null -ne $el.horizontalStretch) { X "$indent<HorizontalStretch>$(if ($el.horizontalStretch){'true'}else{'false'})</HorizontalStretch>" }
	if ($null -ne $el.verticalStretch) { X "$indent<VerticalStretch>$(if ($el.verticalStretch){'true'}else{'false'})</VerticalStretch>" }
	if ($el.groupHorizontalAlign) { X "$indent<GroupHorizontalAlign>$($el.groupHorizontalAlign)</GroupHorizontalAlign>" }
	if ($el.groupVerticalAlign) { X "$indent<GroupVerticalAlign>$($el.groupVerticalAlign)</GroupVerticalAlign>" }
	if ($el.horizontalAlign) { X "$indent<HorizontalAlign>$($el.horizontalAlign)</HorizontalAlign>" }
	Emit-GenericScalars -el $el -indent $indent
}

function Title-FromName {
	param([string]$name)
	if (-not $name) { return '' }
	$s = [regex]::Replace($name, '([А-ЯA-Z])([А-ЯA-Z][а-яa-z])', '$1 $2')
	$s = [regex]::Replace($s, '([а-яa-z0-9])([А-ЯA-Z])', '$1 $2')
	$parts = $s -split ' '
	if ($parts.Count -eq 0) { return $s }
	$out = New-Object System.Collections.ArrayList
	[void]$out.Add($parts[0])
	for ($i = 1; $i -lt $parts.Count; $i++) {
		$p = $parts[$i]
		if ($p.Length -gt 1 -and $p -ceq $p.ToUpper()) {
			[void]$out.Add($p)
		} else {
			[void]$out.Add($p.ToLower())
		}
	}
	return ($out -join ' ')
}

function Emit-Title {
	# Нет ключа title → авто-вывод из имени (помощь модели).
	# Явный title: "" (или null) → подавить (заголовок не эмитим).
	# Явный непустой → эмитим как есть.
	param($el, [string]$name, [string]$indent, [switch]$auto)
	$hasKey = $null -ne $el.PSObject.Properties['title']
	if ($hasKey) {
		if ($el.title) { Emit-MLText -tag "Title" -text $el.title -indent $indent }
	} elseif ($auto -and $name) {
		Emit-MLText -tag "Title" -text (Title-FromName -name $name) -indent $indent
	}
	# ToolTip элемента (всплывающая подсказка) — по схеме сразу после Title.
	if ($el.tooltip) { Emit-MLText -tag "ToolTip" -text $el.tooltip -indent $indent }
	# ToolTipRepresentation — режим показа подсказки (None/Button/ShowBottom/…), после ToolTip.
	if ($el.tooltipRepresentation) { X "$indent<ToolTipRepresentation>$($el.tooltipRepresentation)</ToolTipRepresentation>" }
}

function Map-TitleLoc {
	param([string]$v)
	switch ("$v".ToLower()) {
		"none"   { "None" }
		"left"   { "Left" }
		"right"  { "Right" }
		"top"    { "Top" }
		"bottom" { "Bottom" }
		"auto"   { "Auto" }
		default  { "$v" }
	}
}

function Emit-TitleLocation {
	param($el, [string]$indent, [string]$smartDefault)
	if ($null -ne $el.PSObject.Properties['titleLocation']) {
		if ($el.titleLocation) { X "$indent<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	} elseif ($smartDefault) {
		X "$indent<TitleLocation>$smartDefault</TitleLocation>"
	}
}

function Warn-Unrecognized {
	# drop-on-miss enum: значение не распознано → тег не эмитится. Громко, чтобы автор увидел потерю.
	param([string]$key, $raw, [string[]]$valid, [string]$owner)
	Write-Warning "Unrecognized $key '$raw' on '$owner'. Valid values: $($valid -join ', '). Value ignored."
}

function Emit-Group {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<UsualGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation (направление). Legacy: group:'collapsible' = Vertical + behavior collapsible.
	$groupVal = "$($el.group)".ToLower()
	$orientation = switch ($groupVal) {
		"horizontal"       { "Horizontal" }
		"vertical"         { "Vertical" }
		"alwayshorizontal" { "AlwaysHorizontal" }
		"alwaysvertical"   { "Vertical" }   # старое написание; у группы такого значения нет
		"horizontalifpossible" { "HorizontalIfPossible" }
		"collapsible"      { "Vertical" }
		default            { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }
	elseif ($groupVal) { Warn-Unrecognized 'group orientation' $el.group @('vertical','horizontalIfPossible','alwaysHorizontal') $name }

	# Behavior: ключ behavior (usual/collapsible/popup) → <Behavior>; отсутствие = Авто (не эмитим).
	# Legacy: group:'collapsible' эквивалентно behavior:'collapsible'.
	$behaviorVal = if ($el.behavior) { "$($el.behavior)".ToLower() } elseif ($groupVal -eq "collapsible") { "collapsible" } else { $null }
	$bmap = @{ "usual"="Usual"; "collapsible"="Collapsible"; "popup"="PopUp" }
	if ($behaviorVal -and $bmap.ContainsKey($behaviorVal)) {
		X "$inner<Behavior>$($bmap[$behaviorVal])</Behavior>"
	} elseif ($el.behavior -and -not $bmap.ContainsKey($behaviorVal)) {
		Warn-Unrecognized 'behavior' $el.behavior @('collapsible','popup') $name
	}
	# Collapsed — у Collapsible и PopUp (не привязано к одному behavior)
	if ($el.collapsed -eq $true) { X "$inner<Collapsed>true</Collapsed>" }

	# Representation
	if ($el.representation) {
		$repr = switch ("$($el.representation)") {
			"none"             { "None" }
			"normal"           { "NormalSeparation" }
			"weak"             { "WeakSeparation" }
			"strong"           { "StrongSeparation" }
			default            { "$($el.representation)" }
		}
		X "$inner<Representation>$repr</Representation>"
	}

	# Использование текущей строки группы (после Representation, порядок XSD)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }

	# ShowTitle
	# ShowTitle=true — умолчание платформы (в корпусе только false): пишем лишь false
	if ($null -ne $el.showTitle -and -not $el.showTitle) { X "$inner<ShowTitle>false</ShowTitle>" }
	# Заголовок свёрнутого представления (collapsible/popup) — мультиязычный текст
	if ($el.collapsedTitle) { Emit-MLText -tag "CollapsedRepresentationTitle" -text $el.collapsedTitle -indent $inner }

	# United
	if ($el.united -eq $false) { X "$inner<United>false</United>" }

	# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath группы)
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</UsualGroup>"
}

function Emit-ColumnGroup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<ColumnGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation (horizontal / vertical / inCell — последнее только здесь)
	$groupVal = "$($el.columnGroup)"
	$orientation = switch ($groupVal) {
		"horizontal" { "Horizontal" }
		"vertical"   { "Vertical" }
		"inCell"     { "InCell" }
		default      { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }
	elseif ($groupVal) { Warn-Unrecognized 'columnGroup orientation' $el.columnGroup @('vertical','horizontal','inCell') $name }

	# ShowTitle=true — умолчание платформы (в корпусе только false): пишем лишь false
	if ($null -ne $el.showTitle -and -not $el.showTitle) { X "$inner<ShowTitle>false</ShowTitle>" }
	# showInHeader эмитится общим Emit-CommonElementProps (через Emit-Layout)

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Картинка заголовка колонки-группы (после ShowInHeader/Layout, перед оформлением — порядок XSD)
	Emit-ColumnPics -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</ColumnGroup>"
}

function Emit-Input {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<InputField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }

	if ($null -ne $el.multiLine) { X "$inner<MultiLine>$(if ($el.multiLine){'true'}else{'false'})</MultiLine>" }
	if ($null -ne $el.passwordMode) { X "$inner<PasswordMode>$(if ($el.passwordMode){'true'}else{'false'})</PasswordMode>" }
	# ChoiceButton — захват «как есть» (платформа эмитит явное значение; ref-поля выводят сама,
	# декомпилятор фиксирует факт. значение). Нет ключа → не эмитим (не додумываем по событию).
	if ($null -ne $el.choiceButton) { X "$inner<ChoiceButton>$(if ($el.choiceButton){'true'}else{'false'})</ChoiceButton>" }
	# Кнопки поля ввода — захват «как есть» (платформа эмитит явное значение, в т.ч. false)
	if ($null -ne $el.clearButton)    { X "$inner<ClearButton>$(if ($el.clearButton){'true'}else{'false'})</ClearButton>" }
	if ($null -ne $el.spinButton)     { X "$inner<SpinButton>$(if ($el.spinButton){'true'}else{'false'})</SpinButton>" }
	if ($null -ne $el.dropListButton) { X "$inner<DropListButton>$(if ($el.dropListButton){'true'}else{'false'})</DropListButton>" }
	if ($null -ne $el.choiceListButton) { X "$inner<ChoiceListButton>$(if ($el.choiceListButton){'true'}else{'false'})</ChoiceListButton>" }
	if ($null -ne $el.markIncomplete) { X "$inner<AutoMarkIncomplete>$(if ($el.markIncomplete){'true'}else{'false'})</AutoMarkIncomplete>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	if ($el.textEdit -eq $false) { X "$inner<TextEdit>false</TextEdit>" }
	# InputField-специфичные скаляры (захват «как есть»: платформа эмитит явное не-дефолтное значение)
	foreach ($p in @(
		@('wrap','Wrap'), @('openButton','OpenButton'), @('listChoiceMode','ListChoiceMode'),
		@('extendedEditMultipleValues','ExtendedEditMultipleValues'), @('chooseType','ChooseType'),
		@('quickChoice','QuickChoice'), @('autoChoiceIncomplete','AutoChoiceIncomplete')
	)) {
		if ($null -ne $el.($p[0])) { X "$inner<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	# Ограничение доступных типов (поле на составном типе): домен типов + явный набор.
	# availableTypes — формат типа реквизита (§type); Emit-Type сам разбирает мультитип "a | b".
	if ($null -ne $el.typeDomainEnabled) { X "$inner<TypeDomainEnabled>$(if ($el.typeDomainEnabled){'true'}else{'false'})</TypeDomainEnabled>" }
	if ($el.availableTypes) { Emit-Type -typeStr $el.availableTypes -indent $inner -tag 'AvailableTypes' }
	# InputField-специфичные value-скаляры
	foreach ($p in @(
		@('choiceForm','ChoiceForm'), @('choiceHistoryOnInput','ChoiceHistoryOnInput'),
		@('choiceFoldersAndItems','ChoiceFoldersAndItems'), @('footerDataPath','FooterDataPath')
	)) {
		if ($el.($p[0])) { X "$inner<$($p[1])>$(Esc-XmlText "$($el.($p[0]))")</$($p[1])>" }
	}
	# MinValue/MaxValue — типизированное. JSON-число → xs:decimal, строка → xs:string (тип сохранён декомпилятором).
	foreach ($p in @(@('minValue','MinValue'), @('maxValue','MaxValue'))) {
		if ($null -ne $el.($p[0])) {
			$mvt = if ($el.($p[0]) -is [string]) { 'xs:string' } else { 'xs:decimal' }
			X "$inner<$($p[1]) xsi:type=`"$mvt`">$(Esc-XmlText "$($el.($p[0]))")</$($p[1])>"
		}
	}
	if ($el.choiceButtonRepresentation) { X "$inner<ChoiceButtonRepresentation>$($el.choiceButtonRepresentation)</ChoiceButtonRepresentation>" }
	Emit-PictureRef -val $el.choiceButtonPicture -picTag 'ChoiceButtonPicture' -indent $inner
	Emit-Layout -el $el -indent $inner -multiLineDefault ([bool]($el.multiLine -eq $true))

	if ($el.inputHint) {
		Emit-MLText -tag "InputHint" -text $el.inputHint -indent $inner
	}
	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	Emit-ChoiceList -el $el -indent $inner

	# Связи по типу / связи параметров выбора / параметры выбора
	Emit-TypeLink -el $el -indent $inner
	Emit-ChoiceParameterLinks -el $el -indent $inner
	Emit-ChoiceParameters -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "input"

	X "$indent</InputField>"
}

function Emit-Check {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CheckBoxField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	# CheckBoxType: нет ключа → умный дефолт Auto; "" → подавить; значение → маппинг
	if ($null -ne $el.PSObject.Properties['checkBoxType']) {
		if ($el.checkBoxType) {
			$cbt = switch ("$($el.checkBoxType)".ToLower()) { 'auto' {'Auto'} 'checkbox' {'CheckBox'} 'switcher' {'Switcher'} 'tumbler' {'Tumbler'} default {"$($el.checkBoxType)"} }
			X "$inner<CheckBoxType>$cbt</CheckBoxType>"
		}
	} else { X "$inner<CheckBoxType>Auto</CheckBoxType>" }

	Emit-TitleLocation -el $el -indent $inner -smartDefault "Right"

	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-XmlText "$($el.footerDataPath)")</FooterDataPath>" }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "check"

	X "$indent</CheckBoxField>"
}

function Normalize-MetaTypeRef {
	param([string]$ref)
	if ([string]::IsNullOrEmpty($ref)) { return $ref }
	$dot = $ref.IndexOf('.')
	if ($dot -lt 1) { return $ref }
	$root = $ref.Substring(0, $dot)
	if ($script:refRootSynonyms.ContainsKey($root)) {
		return $script:refRootSynonyms[$root] + $ref.Substring($dot)
	}
	return $ref
}

function Normalize-ChoiceValue {
	param($value)

	# Booleans
	if ($value -is [bool]) {
		return @{ XsiType = "xs:boolean"; Text = if ($value) { "true" } else { "false" } }
	}
	# Numbers (int / decimal / double)
	if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
		return @{ XsiType = "xs:decimal"; Text = "$value" }
	}

	$s = "$value"
	if ([string]::IsNullOrEmpty($s)) {
		return @{ XsiType = "xs:string"; Text = "" }
	}

	# ISO datetime ("2020-01-01T00:00:00") → xs:dateTime
	if ($s -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') {
		return @{ XsiType = "xs:dateTime"; Text = $s }
	}

	# Raw-ссылка по GUID (метаданные.значение, оба GUID): "GUID.GUID" → xr:DesignTimeRef
	# (всегда ссылка, не строка; named-ссылки Enum.X.Y детектятся ниже).
	if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F]{8}-[0-9a-fA-F-]+$') {
		return @{ XsiType = "xr:DesignTimeRef"; Text = $s }
	}

	# Try to detect typed reference path: "<Root>.<Type>[.<Member>.<Value>]"
	$parts = $s -split '\.'
	if ($parts.Count -ge 2) {
		$root = $parts[0]
		$canonRoot = $null
		if ($script:refRootSynonyms.ContainsKey($root)) { $canonRoot = $script:refRootSynonyms[$root] }
		elseif ($script:refRootSynonyms.Values -contains $root) { $canonRoot = $root }

		if ($canonRoot) {
			$typeName = $parts[1]
			$normalized = $null

			if ($canonRoot -eq "Enum") {
				if ($parts.Count -eq 2) {
					# "Enum.X" alone — not a value, treat as string
				} elseif ($parts.Count -eq 3) {
					# "Enum.X.Y" — insert .EnumValue. ("EmptyRef" — пустая ссылка, БЕЗ вставки)
					if ($parts[2] -eq 'EmptyRef') { $normalized = "Enum.$typeName.EmptyRef" }
					else { $normalized = "Enum.$typeName.EnumValue.$($parts[2])" }
				} else {
					# "Enum.X.<member>.Y..."  — replace member with EnumValue (handles ЗначениеПеречисления too)
					$member = $parts[2]
					if ($script:enumValueSynonyms -contains $member) {
						$rest = $parts[3..($parts.Count-1)] -join '.'
						$normalized = "Enum.$typeName.EnumValue.$rest"
					} else {
						$rest = $parts[2..($parts.Count-1)] -join '.'
						$normalized = "Enum.$typeName.EnumValue.$rest"
					}
				}
			} else {
				# Other ref roots: just translate root, keep tail as-is
				if ($parts.Count -ge 3) {
					$tail = $parts[1..($parts.Count-1)] -join '.'
					$normalized = "$canonRoot.$tail"
				}
			}

			if ($normalized) {
				return @{ XsiType = "xr:DesignTimeRef"; Text = $normalized }
			}
		}
	}

	return @{ XsiType = "xs:string"; Text = $s }
}

function Emit-ChoicePresentation {
	param($pres, [string]$indent)
	if ($null -eq $pres -or ($pres -is [string] -and [string]::IsNullOrEmpty($pres))) {
		X "$indent<Presentation/>"
		return
	}

	$pairs = @()
	if ($pres -is [string]) {
		$pairs += ,@("ru", $pres)
	} elseif ($pres -is [hashtable] -or $pres -is [System.Collections.IDictionary]) {
		foreach ($k in $pres.Keys) { $pairs += ,@("$k", "$($pres[$k])") }
	} elseif ($pres.PSObject -and $pres.PSObject.Properties) {
		foreach ($p in $pres.PSObject.Properties) { $pairs += ,@("$($p.Name)", "$($p.Value)") }
	} else {
		$pairs += ,@("ru", "$pres")
	}

	X "$indent<Presentation>"
	foreach ($pair in $pairs) {
		X "$indent`t<v8:item>"
		X "$indent`t`t<v8:lang>$($pair[0])</v8:lang>"
		X "$indent`t`t<v8:content>$(Esc-XmlText $pair[1])</v8:content>"
		X "$indent`t</v8:item>"
	}
	X "$indent</Presentation>"
}

function Get-ChoiceValueTag {
	param($norm)
	if ([string]::IsNullOrEmpty($norm.Text)) { return "<Value xsi:type=`"$($norm.XsiType)`"/>" }
	return "<Value xsi:type=`"$($norm.XsiType)`">$(Esc-XmlText $norm.Text)</Value>"
}

function Emit-ChoiceList {
	param($el, [string]$indent)
	if (-not $el.choiceList -or $el.choiceList.Count -eq 0) { return }
	X "$indent<ChoiceList>"
	$itemIndent = "$indent`t"
	foreach ($item in $el.choiceList) {
		# value (+ рус. синоним "значение")
		$valRaw = $null
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("value")) { $valRaw = $item["value"] }
			elseif ($item.Contains("значение")) { $valRaw = $item["значение"] }
		} else {
			if ($item.PSObject.Properties["value"])    { $valRaw = $item.value }
			elseif ($item.PSObject.Properties["значение"]) { $valRaw = $item."значение" }
		}

		# presentation (presentation OR title синоним)
		$presRaw = $null
		$hasPres = $false
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("presentation")) { $presRaw = $item["presentation"]; $hasPres = $true }
			elseif ($item.Contains("представление")) { $presRaw = $item["представление"]; $hasPres = $true }
			elseif ($item.Contains("title")) { $presRaw = $item["title"]; $hasPres = $true }
		} else {
			if ($item.PSObject.Properties["presentation"]) { $presRaw = $item.presentation; $hasPres = $true }
			elseif ($item.PSObject.Properties["представление"]) { $presRaw = $item."представление"; $hasPres = $true }
			elseif ($item.PSObject.Properties["title"]) { $presRaw = $item.title; $hasPres = $true }
		}

		# valueType: явный xsi:type значения (системное перечисление ent:*, иной не-примитив) —
		# переопределяет авто-детект (Normalize-ChoiceValue вывела бы xs:string).
		$vtRaw = $null
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("valueType")) { $vtRaw = "$($item["valueType"])" }
		} elseif ($item.PSObject.Properties["valueType"]) { $vtRaw = "$($item.valueType)" }

		if ($vtRaw -eq 'nil') { $norm = @{ XsiType = $null; Text = $null; Nil = $true } }
		elseif ($vtRaw) { $norm = @{ XsiType = $vtRaw; Text = "$valRaw" } }
		else { $norm = Normalize-ChoiceValue -value $valRaw }

		# авто-вывод presentation, если не задан
		if (-not $hasPres) {
			if ($norm.XsiType -eq "xr:DesignTimeRef") {
				$tail = ($norm.Text -split '\.')[-1]
				$presRaw = Title-FromName -name $tail
			} else {
				$presRaw = $norm.Text
			}
		}

		X "$itemIndent<xr:Item>"
		$valIndent = "$itemIndent`t"
		X "$valIndent<xr:Presentation/>"
		X "$valIndent<xr:CheckState>0</xr:CheckState>"
		X "$valIndent<xr:Value xsi:type=`"FormChoiceListDesTimeValue`">"
		Emit-ChoicePresentation -pres $presRaw -indent "$valIndent`t"
		X "$valIndent`t$(if ($norm.Nil) { '<Value xsi:nil="true"/>' } else { Get-ChoiceValueTag $norm })"
		X "$valIndent</xr:Value>"
		X "$itemIndent</xr:Item>"
	}
	X "$indent</ChoiceList>"
}

function Get-ElProp {
	param($obj, [string[]]$names)
	if ($null -eq $obj) { return $null }
	foreach ($n in $names) {
		if ($obj -is [System.Collections.IDictionary]) {
			if ($obj.Contains($n)) { return $obj[$n] }
		} elseif ($obj.PSObject -and $obj.PSObject.Properties[$n]) {
			return $obj.PSObject.Properties[$n].Value
		}
	}
	return $null
}

function ConvertTo-ScalarLiteral {
	param([string]$s)
	$t = "$s".Trim()
	if ($t -match '^(?i:true)$')  { return $true }
	if ($t -match '^(?i:false)$') { return $false }
	if ($t -match '^-?\d+$')       { return [int]$t }
	if ($t -match '^-?\d+\.\d+$')  { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) }
	return $t
}

function ConvertFrom-ChoiceParamShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$name = $s.Substring(0, $eq).Trim()
	$rest = $s.Substring($eq + 1)
	if ($rest -match ',') {
		$vals = @()
		foreach ($part in ($rest -split ',')) { $vals += ,(ConvertTo-ScalarLiteral $part) }
		return @{ name = $name; value = $vals }
	}
	return @{ name = $name; value = (ConvertTo-ScalarLiteral $rest) }
}

function ConvertFrom-ChoiceParamLinkShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$o = @{ name = $s.Substring(0, $eq).Trim() }
	$rest = $s.Substring($eq + 1).Trim()
	if ($rest -match '^(.*):(?i:(Clear|DontChange|очистить|неизменять))$') {
		$o['dataPath'] = $matches[1].Trim(); $o['valueChange'] = $matches[2]
	} else {
		$o['dataPath'] = $rest
	}
	return $o
}

function ConvertFrom-TypeLinkShorthand {
	param([string]$s)
	if ($s -match '^(.*)#(\d+)$') { return @{ dataPath = $matches[1].Trim(); linkItem = [int]$matches[2] } }
	return @{ dataPath = "$s".Trim() }
}

function Emit-ChoiceParamValue {
	# $isArray передаётся ЯВНО из вызывающего кода: PowerShell разворачивает одноэлементный массив
	# при биндинге параметра ($value становится скаляром), поэтому определять массив тут — ненадёжно
	# (1-элементный список `["X"]` эмитился бы скаляром вместо FixedArray). foreach по скаляру = 1 итерация.
	param($value, [string]$indent, [bool]$isArray)
	X "$indent<Presentation/>"
	if ($isArray) {
		X "$indent<Value xsi:type=`"v8:FixedArray`">"
		foreach ($v in $value) {
			$norm = Normalize-ChoiceValue -value $v
			X "$indent`t<v8:Value xsi:type=`"FormChoiceListDesTimeValue`">"
			X "$indent`t`t<Presentation/>"
			X "$indent`t`t$(Get-ChoiceValueTag $norm)"
			X "$indent`t</v8:Value>"
		}
		X "$indent</Value>"
	} else {
		$norm = Normalize-ChoiceValue -value $value
		X "$indent$(Get-ChoiceValueTag $norm)"
	}
}

function Emit-ChoiceParameters {
	param($el, [string]$indent)
	$cp = $el.choiceParameters
	if (-not $cp -or @($cp).Count -eq 0) { return }
	X "$indent<ChoiceParameters>"
	foreach ($item in @($cp)) {
		if ($item -is [string]) { $item = ConvertFrom-ChoiceParamShorthand $item }
		$name = Get-ElProp $item @('name','имя')
		# Наличие ключа value (≠ значения) + ПРЯМОЙ доступ к значению (без Get-ElProp): его return
		# разворачивает 1-элементный массив (PS unwrap), теряя массив-ность → FixedArray не эмитится.
		# Индексер/member-доступ массив сохраняет; if-выражение/функция-return — нет.
		$hasVal = $false; $val = $null
		if ($item -is [System.Collections.IDictionary]) {
			if ($item.Contains('value')) { $hasVal = $true; $val = $item['value'] }
			elseif ($item.Contains('значение')) { $hasVal = $true; $val = $item['значение'] }
		} else {
			if ($item.PSObject.Properties['value']) { $hasVal = $true; $val = $item.PSObject.Properties['value'].Value }
			elseif ($item.PSObject.Properties['значение']) { $hasVal = $true; $val = $item.PSObject.Properties['значение'].Value }
		}
		$valIsArray = ($val -is [System.Array]) -or ($val -is [System.Collections.IList] -and $val -isnot [string])
		X "$indent`t<app:item name=`"$(Esc-Xml "$name")`">"
		# Параметр выбора без значения → <app:value xsi:nil="true"/> (платформа, 13 в корпусе);
		# со значением (в т.ч. пустой строкой) → FormChoiceListDesTimeValue.
		if (-not $hasVal) {
			X "$indent`t`t<app:value xsi:nil=`"true`"/>"
		} else {
			X "$indent`t`t<app:value xsi:type=`"FormChoiceListDesTimeValue`">"
			Emit-ChoiceParamValue -value $val -indent "$indent`t`t`t" -isArray $valIsArray
			X "$indent`t`t</app:value>"
		}
		X "$indent`t</app:item>"
	}
	X "$indent</ChoiceParameters>"
}

function Emit-ChoiceParameterLinks {
	param($el, [string]$indent)
	$cpl = $el.choiceParameterLinks
	if (-not $cpl -or @($cpl).Count -eq 0) { return }
	X "$indent<ChoiceParameterLinks>"
	foreach ($lk in @($cpl)) {
		if ($lk -is [string]) { $lk = ConvertFrom-ChoiceParamLinkShorthand $lk }
		$name = Get-ElProp $lk @('name','имя')
		$dp = Get-ElProp $lk @('dataPath','path','путь')
		$vcRaw = Get-ElProp $lk @('valueChange','режимИзменения')
		$vc = "Clear"
		if ($vcRaw) {
			$vc = switch -Regex ("$vcRaw".ToLower()) {
				'^(clear|очистить|очистка)$'             { "Clear"; break }
				'^(dontchange|неизменять|неменять|нет)$' { "DontChange"; break }
				default                                  { "$vcRaw" }
			}
		}
		X "$indent`t<xr:Link>"
		X "$indent`t`t<xr:Name>$(Esc-XmlText "$name")</xr:Name>"
		X "$indent`t`t<xr:DataPath xsi:type=`"xs:string`">$(Esc-XmlText "$dp")</xr:DataPath>"
		X "$indent`t`t<xr:ValueChange>$vc</xr:ValueChange>"
		X "$indent`t</xr:Link>"
	}
	X "$indent</ChoiceParameterLinks>"
}

function Emit-TypeLink {
	param($el, [string]$indent)
	$tl = $el.typeLink
	if (-not $tl) { return }
	if ($tl -is [string]) { $tl = ConvertFrom-TypeLinkShorthand $tl }
	$dp = Get-ElProp $tl @('dataPath','path','путь')
	$li = Get-ElProp $tl @('linkItem','элементСвязи')
	if ($null -eq $li) { $li = 0 }
	X "$indent<TypeLink>"
	X "$indent`t<xr:DataPath>$(Esc-XmlText "$dp")</xr:DataPath>"
	X "$indent`t<xr:LinkItem>$li</xr:LinkItem>"
	X "$indent</TypeLink>"
}

function Emit-Radio {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<RadioButtonField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-TitleLocation -el $el -indent $inner -smartDefault "None"

	# RadioButtonType: Auto | RadioButtons | Tumbler. Accept synonyms.
	$rbtRaw = if ($el.radioButtonType) { "$($el.radioButtonType)".Trim() } else { "Auto" }
	$rbt = switch -Regex ($rbtRaw.ToLower()) {
		'^(auto|авто)$'                        { "Auto"; break }
		'^(radiobuttons?|переключатель|радио)$' { "RadioButtons"; break }
		'^(tumbler|тумблер)$'                  { "Tumbler"; break }
		default                                { $rbtRaw }
	}
	X "$inner<RadioButtonType>$rbt</RadioButtonType>"

	if ($null -ne $el.columnsCount) {
		X "$inner<ColumnsCount>$($el.columnsCount)</ColumnsCount>"
	}

	Emit-ChoiceList -el $el -indent $inner

	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "radio"

	X "$indent</RadioButtonField>"
}

function Emit-DecorationTitle {
	param($el, [string]$name, [string]$indent, [switch]$auto)
	$hasKey = $null -ne $el.PSObject.Properties['title']
	$titleVal = if ($hasKey) { $el.title } elseif ($auto -and $name) { Title-FromName -name $name } else { $null }
	if ($titleVal) {
		$r = Resolve-MLFormatted $titleVal
		$fmt = if ($null -ne $el.PSObject.Properties['formatted']) { [bool]$el.formatted } else { $r.formatted }
		X "$indent<Title formatted=`"$(if ($fmt) { 'true' } else { 'false' })`">"
		Emit-MLItems -val $r.text -indent "$indent`t"
		X "$indent</Title>"
	}
	if ($el.tooltip) { Emit-MLText -tag "ToolTip" -text $el.tooltip -indent $indent }
	if ($el.tooltipRepresentation) { X "$indent<ToolTipRepresentation>$($el.tooltipRepresentation)</ToolTipRepresentation>" }
}

function Emit-Label {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelDecoration name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	# Порядок как у платформы: own-content (флаги/hyperlink/layout/оформление) ПЕРЕД Title
	# (корпус layout-first 16970 vs 44 — заодно убирает шум атрибуции харнесса на многострочном Title).
	Emit-CommonFlags -el $el -indent $inner
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner
	Emit-Appearance -el $el -indent $inner -profile 'decoration'

	Emit-DecorationTitle -el $el -name $name -indent $inner -auto

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "label"

	X "$indent</LabelDecoration>"
}

function Emit-LabelField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	# FooterDataPath — путь данных подвала колонки (общий cell-prop, как у input); после EditMode
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-XmlText "$($el.footerDataPath)")</FooterDataPath>" }
	# PasswordMode на LabelField — платформа эмитит явный false (редко); факт. значение
	if ($null -ne $el.passwordMode) { X "$inner<PasswordMode>$(if ($el.passwordMode){'true'}else{'false'})</PasswordMode>" }
	Emit-ColumnPics -el $el -indent $inner
	# ВНИМАНИЕ: у LabelField платформенный тег именно <Hiperlink> (опечатка 1С), не <Hyperlink>.
	if ($el.hyperlink -eq $true) { X "$inner<Hiperlink>true</Hiperlink>" }
	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	# Оформление (цвета/шрифты/граница + header/footer) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "labelField"

	X "$indent</LabelField>"
}

function Emit-DynListTableBlock {
	param($el, [string]$indent)
	# (useAlternationRowColor — общее свойство таблицы, эмитится в Emit-Table)
	# Group A (гарант. блок, n=5079): дефолт + override
	$ar = if ($el.autoRefresh -eq $true) { "true" } else { "false" }
	X "$indent<AutoRefresh>$ar</AutoRefresh>"
	$arp = if ($el.PSObject.Properties["autoRefreshPeriod"] -and $null -ne $el.autoRefreshPeriod) { $el.autoRefreshPeriod } else { 60 }
	X "$indent<AutoRefreshPeriod>$arp</AutoRefreshPeriod>"
	X "$indent<Period>"
	X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">Custom</v8:variant>"
	X "$indent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
	X "$indent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
	X "$indent</Period>"
	$cfi = if ($el.choiceFoldersAndItems) { $el.choiceFoldersAndItems } else { "Items" }
	X "$indent<ChoiceFoldersAndItems>$cfi</ChoiceFoldersAndItems>"
	$rcr = if ($el.restoreCurrentRow -eq $true) { "true" } else { "false" }
	X "$indent<RestoreCurrentRow>$rcr</RestoreCurrentRow>"
	X "$indent<TopLevelParent xsi:nil=`"true`"/>"
	$sr = if ($el.showRoot -eq $false) { "false" } else { "true" }
	X "$indent<ShowRoot>$sr</ShowRoot>"
	$arc = if ($el.allowRootChoice -eq $true) { "true" } else { "false" }
	X "$indent<AllowRootChoice>$arc</AllowRootChoice>"
	$uodc = if ($el.updateOnDataChange) { $el.updateOnDataChange } else { "Auto" }
	X "$indent<UpdateOnDataChange>$uodc</UpdateOnDataChange>"
	if ($el.userSettingsGroup) { X "$indent<UserSettingsGroup>$($el.userSettingsGroup)</UserSettingsGroup>" }
	$agcru = if ($el.allowGettingCurrentRowURL -eq $false) { "false" } else { "true" }
	X "$indent<AllowGettingCurrentRowURL>$agcru</AllowGettingCurrentRowURL>"
}

function Emit-Table {
	param($el, [string]$name, [int]$id, [string]$indent)

	$script:currentTableName = $name   # дефолт source для кастомных дополнений в commandBar
	X "$indent<Table name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	# ChangeRowSet/Order — эмитим явное значение (в т.ч. false: платформа пишет его на ValueTable)
	if ($el.PSObject.Properties['changeRowSet'] -and $null -ne $el.changeRowSet) {
		X "$inner<ChangeRowSet>$(if ($el.changeRowSet -eq $true){'true'}else{'false'})</ChangeRowSet>"
	}
	if ($el.PSObject.Properties['changeRowOrder'] -and $null -ne $el.changeRowOrder) {
		X "$inner<ChangeRowOrder>$(if ($el.changeRowOrder -eq $true){'true'}else{'false'})</ChangeRowOrder>"
	}
	if ($el.autoInsertNewRow -eq $true) { X "$inner<AutoInsertNewRow>true</AutoInsertNewRow>" }
	# RowFilter — nil-плейсхолдер (всегда пустой); ключ присутствует → эмитим
	if ($el.PSObject.Properties['rowFilter']) { X "$inner<RowFilter xsi:nil=`"true`"/>" }
	# Высота в строках таблицы (<HeightInTableRows>) — отдельное свойство от <Height> (высота элемента,
	# эмитится generic-ом Emit-Layout ниже). Таблица может нести оба (237 в корпусе).
	if ($el.heightInTableRows) { X "$inner<HeightInTableRows>$($el.heightInTableRows)</HeightInTableRows>" }
	if ($el.header -eq $false) { X "$inner<Header>false</Header>" }
	if ($el.footer -eq $true) { X "$inner<Footer>true</Footer>" }

	if ($el.commandBarLocation) {
		X "$inner<CommandBarLocation>$($el.commandBarLocation)</CommandBarLocation>"
	}
	if ($el.searchStringLocation) {
		X "$inner<SearchStringLocation>$($el.searchStringLocation)</SearchStringLocation>"
	}
	if ($el.choiceMode -eq $true) { X "$inner<ChoiceMode>true</ChoiceMode>" }
	# Скаляры таблицы (захват «как есть»). Autofill — СВОЁ свойство таблицы (≠ AutoCommandBar autofill = tableAutofill).
	if ($null -ne $el.autofill) { X "$inner<Autofill>$(if ($el.autofill){'true'}else{'false'})</Autofill>" }
	if ($el.multipleChoice -eq $true) { X "$inner<MultipleChoice>true</MultipleChoice>" }
	if ($el.searchOnInput) { X "$inner<SearchOnInput>$($el.searchOnInput)</SearchOnInput>" }
	if ($null -ne $el.markIncomplete) { X "$inner<AutoMarkIncomplete>$(if ($el.markIncomplete){'true'}else{'false'})</AutoMarkIncomplete>" }
	# Высота шапки/подвала в строках (pass-through; 1С толерантна к порядку детей Table)
	if ($null -ne $el.headerHeight) { X "$inner<HeaderHeight>$($el.headerHeight)</HeaderHeight>" }
	if ($null -ne $el.footerHeight) { X "$inner<FooterHeight>$($el.footerHeight)</FooterHeight>" }
	if ($el.useAlternationRowColor -eq $true) { X "$inner<UseAlternationRowColor>true</UseAlternationRowColor>" }
	if ($el.selectionMode) { X "$inner<SelectionMode>$($el.selectionMode)</SelectionMode>" }
	if ($el.rowSelectionMode) { X "$inner<RowSelectionMode>$($el.rowSelectionMode)</RowSelectionMode>" }
	if ($el.verticalLines -eq $false) { X "$inner<VerticalLines>false</VerticalLines>" }
	if ($el.horizontalLines -eq $false) { X "$inner<HorizontalLines>false</HorizontalLines>" }
	if ($el.initialTreeView) { X "$inner<InitialTreeView>$($el.initialTreeView)</InitialTreeView>" }
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }
	if ($el.rowPictureDataPath) { X "$inner<RowPictureDataPath>$($el.rowPictureDataPath)</RowPictureDataPath>" }
	# RowsPicture — та же конвенция, что ValuesPicture (дефолт LoadTransparent=false; abs/TransparentPixel)
	Emit-PictureRef -val $el.rowsPicture -picTag 'RowsPicture' -indent $inner
	# Использование текущей строки таблицы (pass-through; в корпусе соседствует с блоком дин-списка)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }
	# Запрос обновления дин-списка (pass-through; в корпусе всегда PullFromTop)
	if ($el.refreshRequest) { X "$inner<RefreshRequest>$($el.refreshRequest)</RefreshRequest>" }
	# Блок свойств дин-список-таблицы (помечена эвристикой 11b.4)
	if ($el.PSObject.Properties["_dynList"] -and $el._dynList) { Emit-DynListTableBlock -el $el -indent $inner }
	if ($el.viewStatusLocation) { X "$inner<ViewStatusLocation>$($el.viewStatusLocation)</ViewStatusLocation>" }
	if ($el.searchControlLocation) { X "$inner<SearchControlLocation>$($el.searchControlLocation)</SearchControlLocation>" }
	Emit-Layout -el $el -indent $inner

	# CommandSet таблицы эмитится через Emit-Layout (общий механизм поля)

	# Оформление (цвета/граница таблицы) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	# AutoCommandBar: приоритет commandBar-свойства (контент); иначе tableAutofill-shorthand; иначе пусто.
	if ($null -ne $el.commandBar) {
		Emit-CompanionPanel -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner -panel $el.commandBar
	} elseif ($null -ne $el.tableAutofill) {
		$acbId = New-Id
		X "$inner<AutoCommandBar name=`"${name}КоманднаяПанель`" id=`"$acbId`">"
		$afVal = if ($el.tableAutofill) { "true" } else { "false" }
		X "$inner`t<Autofill>$afVal</Autofill>"
		X "$inner</AutoCommandBar>"
	} else {
		Emit-Companion -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner
	}
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip
	$adds = $el.additions
	Emit-TableAddition -typeKey 'searchString'  -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'searchString')
	Emit-TableAddition -typeKey 'viewStatus'    -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'viewStatus')
	Emit-TableAddition -typeKey 'searchControl' -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'searchControl')

	# Columns
	if ($el.columns -and $el.columns.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($col in $el.columns) {
			Emit-Element -el $col -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "table"

	X "$indent</Table>"
}

function Emit-Pages {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Pages name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.pagesRepresentation) {
		X "$inner<PagesRepresentation>$($el.pagesRepresentation)</PagesRepresentation>"
	}
	# Использование текущей строки (после PagesRepresentation, порядок XSD)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) заголовка группы страниц — TitleFont/TitleTextColor/… (как у Page)
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "pages"

	# Children (pages)
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Pages>"
}

function Emit-Page {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Page name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	# Картинка страницы (иконка вкладки): после Title/флагов, перед Group (порядок XSD).
	# Конвенция как у ValuesPicture (дефолт LoadTransparent=false): скаляр-Ref/'abs:X' или объект.
	Emit-PictureRef -val $el.picture -picTag 'Picture' -indent $inner

	if ($el.group) {
		# Доступные значения страницы/обычной группы: Vertical / HorizontalIfPossible / AlwaysHorizontal
		# (InCell — только у columnGroup). Horizontal и старое alwaysVertical (→ Vertical) — прощающий ввод.
		$orientation = switch ("$($el.group)") {
			"horizontal"          { "Horizontal" }
			"vertical"            { "Vertical" }
			"alwaysHorizontal"    { "AlwaysHorizontal" }
			"alwaysVertical"      { "Vertical" }   # старое написание; у страницы такого значения нет
			"horizontalIfPossible" { "HorizontalIfPossible" }
			default               { $null }
		}
		if ($orientation) { X "$inner<Group>$orientation</Group>" }
		else { Warn-Unrecognized 'page group orientation' $el.group @('vertical','horizontalIfPossible','alwaysHorizontal') $name }
	}
	# ShowTitle=true — умолчание платформы (в корпусе только false): пишем лишь false
	if ($null -ne $el.showTitle -and -not $el.showTitle) { X "$inner<ShowTitle>false</ShowTitle>" }
	# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath страницы)
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }
	Emit-Layout -el $el -indent $inner

	# Оформление страницы (BackColor / TitleTextColor / TitleFont) — после ShowTitle, перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Page>"
}

function Emit-Button {
	param($el, [string]$name, [int]$id, [string]$indent, [bool]$inCmdBar = $false)

	X "$indent<Button name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"
	# (общие свойства — через Emit-Layout ниже; отдельный вызов был бы двойной эмиссией)

	# Type — context-aware:
	# Inside command bar (cmdBar/autoCmdBar/popup) only CommandBarButton/CommandBarHyperlink are valid.
	# UsualButton/Hyperlink would be silently ignored by 1C.
	$btnType = $null
	if ($el.type) {
		$rawType = "$($el.type)"
		if ($inCmdBar) {
			# Be forgiving: any "ordinary button" hint resolves to CommandBarButton,
			# any "hyperlink" hint resolves to CommandBarHyperlink. The model can pass
			# either DSL ("usual"/"hyperlink") or XML names — all map to the right kind.
			switch ($rawType) {
				"usual"                { $btnType = "CommandBarButton" }
				"UsualButton"          { $btnType = "CommandBarButton" }
				"commandBar"           { $btnType = "CommandBarButton" }
				"CommandBarButton"     { $btnType = "CommandBarButton" }
				"hyperlink"            { $btnType = "CommandBarHyperlink" }
				"Hyperlink"            { $btnType = "CommandBarHyperlink" }
				"CommandBarHyperlink"  { $btnType = "CommandBarHyperlink" }
				default                { $btnType = $rawType }
			}
		} else {
			# Symmetric: any "ordinary button" hint → UsualButton, any "hyperlink" → Hyperlink.
			switch ($rawType) {
				"usual"                { $btnType = "UsualButton" }
				"UsualButton"          { $btnType = "UsualButton" }
				"commandBar"           { $btnType = "UsualButton" }
				"CommandBarButton"     { $btnType = "UsualButton" }
				"hyperlink"            { $btnType = "Hyperlink" }
				"Hyperlink"            { $btnType = "Hyperlink" }
				"CommandBarHyperlink"  { $btnType = "Hyperlink" }
				default                { $btnType = $rawType }
			}
		}
	} elseif ($inCmdBar) {
		$btnType = "CommandBarButton"
	}
	if ($btnType) {
		X "$inner<Type>$btnType</Type>"
	}

	# CommandName
	if ($el.command) {
		X "$inner<CommandName>Form.Command.$($el.command)</CommandName>"
	}
	# commandName — глобальная команда «как есть» (CommonCommand.X, Catalog.X.Command.Y …), без обёртки Form.
	if ($el.commandName -and -not $el.command) {
		X "$inner<CommandName>$($el.commandName)</CommandName>"
	}
	if ($el.stdCommand) {
		$sc = "$($el.stdCommand)"
		if ($sc -match '^(.+)\.(.+)$') {
			X "$inner<CommandName>Form.Item.$($Matches[1]).StandardCommand.$($Matches[2])</CommandName>"
		} else {
			X "$inner<CommandName>Form.StandardCommand.$sc</CommandName>"
		}
	}
	# Parameter команды (после CommandName): строка → xr:MDObjectRef (объект метаданных);
	# объект {type} → v8:TypeDescription (грамматика типа). Forgiving-синоним 'параметр'.
	$btnParam = if ($null -ne $el.PSObject.Properties['parameter']) { $el.parameter } elseif ($null -ne $el.PSObject.Properties['параметр']) { $el.параметр } else { $null }
	if ($null -ne $btnParam) {
		if (($btnParam -is [System.Management.Automation.PSCustomObject] -or $btnParam -is [hashtable]) -and $btnParam.type) {
			Emit-Type -typeStr "$($btnParam.type)" -indent $inner -tag "Parameter" -tagAttrs ' xsi:type="v8:TypeDescription"'
		} else {
			X "$inner<Parameter xsi:type=`"xr:MDObjectRef`">$(Esc-XmlText "$btnParam")</Parameter>"
		}
	}
	# DataPath — привязка команды кнопки к контексту (Объект.Ref, Items.X.CurrentData.Поле)
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	$btnAuto = -not ($el.command -or $el.commandName -or $el.stdCommand)
	Emit-Title -el $el -name $name -indent $inner -auto:$btnAuto
	Emit-CommonFlags -el $el -indent $inner

	if ($el.defaultButton -eq $true) { X "$inner<DefaultButton>true</DefaultButton>" }
	# Check (пометка toggle-кнопки командной панели) — платформа эмитит только true.
	# Ключ 'checked' (не 'check': 'check' — тип-ключ CheckBoxField, был бы конфликт диспетчера типов)
	if ($el.checked -eq $true) { X "$inner<Check>true</Check>" }

	# Picture
	Emit-CommandPicture -pic $el.picture -elemLt $el.loadTransparent -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}

	if ($el.locationInCommandBar) {
		X "$inner<LocationInCommandBar>$($el.locationInCommandBar)</LocationInCommandBar>"
	}
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифт/граница) — перед компаньоном (профиль кнопки)
	Emit-Appearance -el $el -indent $inner -profile 'button'

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "button"

	X "$indent</Button>"
}

function Emit-PictureDecoration {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureDecoration name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-DecorationTitle -el $el -name $name -indent $inner
	# Текст при невыбранной картинке (NonselectedPictureText) — после Title (порядок корпуса)
	if ($null -ne $el.nonselectedPictureText) { Emit-MLText -tag "NonselectedPictureText" -text $el.nonselectedPictureText -indent $inner }
	Emit-CommonFlags -el $el -indent $inner

	# Источник картинки — ТОЛЬКО $el.src (у PictureDecoration ключ 'picture' = тип/имя элемента, не источник).
	# Префикс "abs:" → встроенная картинка <xr:Abs>; иначе именованная/стилевая <xr:Ref>.
	if ($el.src) {
		$srcStr = "$($el.src)"
		$lt = if ($el.loadTransparent -eq $true) { "true" } else { "false" }
		X "$inner<Picture>"
		if ($srcStr -match '^abs:(.*)$') { X "$inner`t<xr:Abs>$(Esc-XmlText $matches[1])</xr:Abs>" }
		else { X "$inner`t<xr:Ref>$(Esc-XmlText $srcStr)</xr:Ref>" }
		X "$inner`t<xr:LoadTransparent>$lt</xr:LoadTransparent>"
		if ($el.transparentPixel) { X "$inner`t<xr:TransparentPixel x=`"$($el.transparentPixel.x)`" y=`"$($el.transparentPixel.y)`"/>" }
		X "$inner</Picture>"
	}

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner
	# EnableDrag — фактическое значение (декорация-картинка перетаскиваема; декомпилятор ловит generic-ом)
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# Оформление (цвета/шрифт/граница) — профиль декорации (1С толерантна к порядку appearance)
	Emit-Appearance -el $el -indent $inner -profile 'decoration'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picture"

	X "$indent</PictureDecoration>"
}

function Emit-PictureField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }

	Emit-Layout -el $el -indent $inner
	# EnableDrag — фактическое значение (поле картинки перетаскиваемо; декомпилятор ловит generic-ом)
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-XmlText "$($el.footerDataPath)")</FooterDataPath>" }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# ValuesPicture — picture (collection) used to render the field's value.
	# Required for a Boolean-bound PictureField to actually show an icon.
	# Скаляр (Ref) или объект {src, loadTransparent}; LoadTransparent эмитится всегда.
	Emit-PictureRef -val $el.valuesPicture -picTag 'ValuesPicture' -indent $inner
	if ($null -ne $el.nonselectedPictureText) { Emit-MLText -tag "NonselectedPictureText" -text $el.nonselectedPictureText -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picField"

	X "$indent</PictureField>"
}

function Emit-Calendar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CalendarField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) {
		$loc = Map-TitleLoc "$($el.titleLocation)"
		X "$inner<TitleLocation>$loc</TitleLocation>"
	}

	Emit-Layout -el $el -indent $inner

	# Календарно-специфичные свойства (порядок схемы: после layout, до companions)
	if ($el.selectionMode) { X "$inner<SelectionMode>$($el.selectionMode)</SelectionMode>" }
	if ($null -ne $el.showCurrentDate) { $v = if ($el.showCurrentDate) { "true" } else { "false" }; X "$inner<ShowCurrentDate>$v</ShowCurrentDate>" }
	if ($null -ne $el.widthInMonths) { X "$inner<WidthInMonths>$($el.widthInMonths)</WidthInMonths>" }
	if ($null -ne $el.heightInMonths) { X "$inner<HeightInMonths>$($el.heightInMonths)</HeightInMonths>" }
	if ($null -ne $el.showMonthsPanel) { $v = if ($el.showMonthsPanel) { "true" } else { "false" }; X "$inner<ShowMonthsPanel>$v</ShowMonthsPanel>" }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "calendar"

	X "$indent</CalendarField>"
}

function Emit-SimpleField {
	param($el, [string]$name, [int]$id, [string]$indent, [string]$xmlTag, [string]$typeKey)

	X "$indent<$xmlTag name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }

	Emit-Layout -el $el -indent $inner

	# EnableDrag — фактическое значение (SpreadSheet; платформа эмитит явный false). enableStartDrag — через Emit-Layout.
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# Датчики (ProgressBar/TrackBar) — числовые скаляры (без xsi:type)
	foreach ($p in @(@('minValue','MinValue'), @('maxValue','MaxValue'), @('largeStep','LargeStep'), @('markingStep','MarkingStep'), @('step','Step'))) {
		if ($null -ne $el.($p[0])) { X "$inner<$($p[1])>$($el.($p[0]))</$($p[1])>" }
	}

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey $typeKey

	X "$indent</$xmlTag>"
}

function Emit-GanttChart {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<GanttChartField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	Emit-Layout -el $el -indent $inner
	Emit-Appearance -el $el -indent $inner -profile 'field'
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip
	# Вложенная таблица диаграммы Ганта (стандартный Table — переиспользуем Emit-Element)
	if ($el.ganttTable) { Emit-Element -el $el.ganttTable -indent $inner }
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "ganttChart"
	X "$indent</GanttChartField>"
}

function Emit-CommandBar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CommandBar name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	if ($el.autofill -eq $true) { X "$inner<Autofill>true</Autofill>" }

	# CommandBar хранит HorizontalLocation фактически (включая Auto — декомпилятор ловит только при наличии);
	# ≠ дополнениям, где Auto = умолчание-скип (Get-HLocation).
	if ($el.horizontalLocation) {
		$hlv = switch ("$($el.horizontalLocation)".ToLower()) { 'auto' {'Auto'} 'left' {'Left'} 'right' {'Right'} 'center' {'Center'} default {"$($el.horizontalLocation)"} }
		X "$inner<HorizontalLocation>$hlv</HorizontalLocation>"
	}
	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</CommandBar>"
}

function Emit-ButtonGroup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<ButtonGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children (кнопки в контексте командной панели)
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</ButtonGroup>"
}

function Emit-Popup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Popup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	# Источник команд попапа (после Title/ToolTip, перед компаньоном) — как у ButtonGroup/CommandBar
	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	Emit-CommandPicture -pic $el.picture -elemLt $el.loadTransparent -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	Emit-Layout -el $el -indent $inner

	# Оформление попапа (TitleTextColor / TitleFont) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Popup>"
}

function Emit-FunctionalOptions {
	param($fo, [string]$indent)
	if (-not $fo -or @($fo).Count -eq 0) { return }
	X "$indent<FunctionalOptions>"
	foreach ($opt in @($fo)) {
		$v = "$opt"
		if ($v -match '^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$') { }          # GUID — как есть
		elseif ($v -match '^FunctionalOption\.') { }                     # уже с префиксом
		else { $v = "FunctionalOption.$v" }
		X "$indent`t<Item>$v</Item>"
	}
	X "$indent</FunctionalOptions>"
}

function Emit-AttrColumn {
	param($col, [string]$indent)
	$colId = New-Id
	X "$indent<Column name=`"$($col.name)`" id=`"$colId`">"
	if ($col.title) { Emit-MLText -tag "Title" -text $col.title -indent "$indent`t" }
	Emit-Type -typeStr "$($col.type)" -indent "$indent`t"
	# Проверка заполнения колонки → <FillCheck> (как у реквизита; bool true→ShowError / строка verbatim)
	$cfcRaw = if ($null -ne $col.PSObject.Properties['fillCheck']) { $col.fillCheck } elseif ($null -ne $col.PSObject.Properties['fillChecking']) { $col.fillChecking } else { $null }
	if ($null -ne $cfcRaw) { $cfcv = if ($cfcRaw -is [bool]) { if ($cfcRaw) { 'ShowError' } else { $null } } else { "$cfcRaw" }; if ($cfcv) { X "$indent`t<FillCheck>$cfcv</FillCheck>" } }
	Emit-FunctionalOptions -fo $col.functionalOptions -indent "$indent`t"
	# Ролевой доступ колонки (View/Edit) — xr-флаг, как у самого реквизита
	if ($null -ne $col.view) { Emit-XrFlag -tag 'View' -val $col.view -indent "$indent`t" }
	if ($null -ne $col.edit) { Emit-XrFlag -tag 'Edit' -val $col.edit -indent "$indent`t" }
	X "$indent</Column>"
}

function Emit-DLMLText {
	param([string]$tag, $text, [string]$indent)
	X "$indent<$tag xsi:type=`"v8:LocalStringType`">"
	Emit-MLItems -val $text -indent "$indent`t"
	X "$indent</$tag>"
}

function Has-DLProp {
	param($obj, [string]$name)
	if ($null -eq $obj) { return $false }
	if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
	if ($obj.PSObject -and $obj.PSObject.Properties[$name]) { return $true }
	return $false
}

function Split-DLValueListCsv {
	param([string]$s)
	$result = @()
	if ($null -eq $s) { return ,$result }
	$items = @(); $buf = New-Object System.Text.StringBuilder; $inQuote = $null
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

function Parse-DLParamShorthand {
	param([string]$s)
	$result = @{ name = ""; type = ""; value = $null; title = $null }
	if ($s -match '@valueList') { $result.valueListAllowed = $true; $s = $s -replace '\s*@valueList', '' }
	if ($s -match '@hidden')    { $result.hidden = $true; $s = $s -replace '\s*@hidden', '' }
	if ($s -match '\[([^\]]*)\]') { $result.title = $Matches[1].Trim(); $s = ($s -replace '\s*\[[^\]]*\]\s*', ' ').Trim() }
	# Тип может быть СОСТАВНЫМ (A | B | C — с пробелами); значение — после '=' (тип '=' не содержит).
	if ($s -match '^([^:]+):\s*([^=]+?)(\s*=\s*(.*))?$') {
		$result.name = $Matches[1].Trim()
		$typeRaw = $Matches[2].Trim()
		if ($typeRaw -match '[|+]') {
			$result.type = (($typeRaw -split '\s*[|+]\s*') | ForEach-Object { Resolve-TypeStr ($_.Trim()) }) -join ' | '
		} else {
			$result.type = Resolve-TypeStr $typeRaw
		}
		if ($Matches[4]) {
			$rhs = $Matches[4].Trim()
			$items = Split-DLValueListCsv $rhs
			if ($items.Count -ge 2) { $result.value = $items; $result.valueListAllowed = $true }
			elseif ($items.Count -eq 1) { $result.value = $items[0] }
			else { $result.value = $rhs }
		}
	} else { $result.name = $s.Trim() }
	return $result
}

function Test-DLEmptyValue {
	param($v)
	if ($null -eq $v) { return $true }
	$s = "$v".Trim()
	if ($s -eq "" -or $s -eq "_" -or $s.ToLowerInvariant() -eq "null") { return $true }
	return $false
}

function Emit-DLValue {
	param([string]$type, $val, [string]$indent, [bool]$valueListAllowed = $false)
	if (Test-DLEmptyValue $val) {
		# Дин-список: пустое значение платформа ВСЕГДА пишет как xsi:nil, даже при известном
		# типе (в отличие от типизированного пустого в параметрах отчёта СКД).
		if ($valueListAllowed) { return }
		X "$indent<dcssch:value xsi:nil=`"true`"/>"
		return
	}
	$valStr = if ($val -is [bool]) { if ($val) { 'true' } else { 'false' } } else { "$val" }
	if ($type -match '^(date|dateTime|time)') { X "$indent<dcssch:value xsi:type=`"xs:dateTime`">$(Esc-XmlText $valStr)</dcssch:value>" }
	elseif ($type -eq "boolean") { X "$indent<dcssch:value xsi:type=`"xs:boolean`">$(Esc-XmlText $valStr)</dcssch:value>" }
	elseif ($type -eq 'v8:Type') { $nsAttr = Get-ValueTypeNsAttr -valueType 'v8:Type' -value $valStr; X "$indent<dcssch:value$nsAttr xsi:type=`"v8:Type`">$(Esc-XmlText $valStr)</dcssch:value>" }
	elseif ($type -match '^ent:') { X "$indent<dcssch:value xsi:type=`"$type`">$(Esc-XmlText $valStr)</dcssch:value>" }   # системное перечисление (ent:X) — value несёт тот же xsi:type
	elseif ($type -match '^decimal') { X "$indent<dcssch:value xsi:type=`"xs:decimal`">$(Esc-XmlText $valStr)</dcssch:value>" }
	elseif ($type -match '^string') { X "$indent<dcssch:value xsi:type=`"xs:string`">$(Esc-XmlText $valStr)</dcssch:value>" }
	elseif ($type -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef)\.') { X "$indent<dcssch:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-XmlText $valStr)</dcssch:value>" }
	else {
		if ($valStr -match '^\d{4}-\d{2}-\d{2}T') { X "$indent<dcssch:value xsi:type=`"xs:dateTime`">$(Esc-XmlText $valStr)</dcssch:value>" }
		elseif ($valStr -eq "true" -or $valStr -eq "false") { X "$indent<dcssch:value xsi:type=`"xs:boolean`">$(Esc-XmlText $valStr)</dcssch:value>" }
		elseif ($valStr -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or $valStr -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { X "$indent<dcssch:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-XmlText $valStr)</dcssch:value>" }
		else { X "$indent<dcssch:value xsi:type=`"xs:string`">$(Esc-XmlText $valStr)</dcssch:value>" }
	}
}

function Emit-DLValueType {
	param($typeStr, [string]$indent)
	if (-not $typeStr) { return }
	X "$indent<dcssch:valueType>"
	$parts = "$typeStr" -split '\s*[|+]\s*'
	foreach ($part in $parts) { Emit-SingleType -typeStr $part.Trim() -indent "$indent`t" }
	X "$indent</dcssch:valueType>"
}

function Emit-DLAvailableValue {
	param($av, [string]$type, [string]$indent)
	X "$indent<dcssch:availableValue>"
	$avVal = if (Has-DLProp $av 'value') { $av.value } else { $null }
	Emit-DLValue -type $type -val $avVal -indent "$indent`t" -valueListAllowed $false
	$pres = if ($av.presentation) { $av.presentation } elseif ($av.title) { $av.title } else { $null }
	if ($pres) { Emit-DLMLText -tag "dcssch:presentation" -text $pres -indent "$indent`t" }
	X "$indent</dcssch:availableValue>"
}

function Emit-DLInputParameters {
	param($ip, [string]$indent)
	if ($null -eq $ip) { return }
	$items = @($ip)
	if ($items.Count -eq 0) { return }
	X "$indent<dcssch:inputParameters>"
	foreach ($item in $items) {
		X "$indent`t<dcscor:item>"
		if ((Has-DLProp $item 'use') -and $null -ne $item.use -and -not $item.use) { X "$indent`t`t<dcscor:use>false</dcscor:use>" }
		X "$indent`t`t<dcscor:parameter>$(Esc-XmlText "$($item.parameter)")</dcscor:parameter>"
		if (Has-DLProp $item 'choiceParameters') {
			$cpItems = if ($null -ne $item.choiceParameters) { @($item.choiceParameters) } else { @() }
			if ($cpItems.Count -eq 0) { X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameters`"/>" }
			else {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameters`">"
				foreach ($cpItem in $cpItems) {
					X "$indent`t`t`t<dcscor:item>"
					X "$indent`t`t`t`t<dcscor:choiceParameter>$(Esc-XmlText "$($cpItem.name)")</dcscor:choiceParameter>"
					foreach ($v in @($cpItem.values)) {
						if ($v -is [bool]) { X "$indent`t`t`t`t<dcscor:value xsi:type=`"xs:boolean`">$(if ($v) { 'true' } else { 'false' })</dcscor:value>" }
						elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { X "$indent`t`t`t`t<dcscor:value xsi:type=`"xs:decimal`">$v</dcscor:value>" }
						else { X "$indent`t`t`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-XmlText "$v")</dcscor:value>" }
					}
					X "$indent`t`t`t</dcscor:item>"
				}
				X "$indent`t`t</dcscor:value>"
			}
		} elseif (Has-DLProp $item 'choiceParameterLinks') {
			$cplItems = if ($null -ne $item.choiceParameterLinks) { @($item.choiceParameterLinks) } else { @() }
			if ($cplItems.Count -eq 0) { X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameterLinks`"/>" }
			else {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameterLinks`">"
				foreach ($cplItem in $cplItems) {
					X "$indent`t`t`t<dcscor:item>"
					X "$indent`t`t`t`t<dcscor:choiceParameter>$(Esc-XmlText "$($cplItem.name)")</dcscor:choiceParameter>"
					X "$indent`t`t`t`t<dcscor:value>$(Esc-XmlText "$($cplItem.value)")</dcscor:value>"
					$mode = if ($cplItem.mode) { "$($cplItem.mode)" } else { 'Auto' }
					X "$indent`t`t`t`t<dcscor:mode xmlns:d8p1=`"http://v8.1c.ru/8.1/data/enterprise`" xsi:type=`"d8p1:LinkedValueChangeMode`">$mode</dcscor:mode>"
					X "$indent`t`t`t</dcscor:item>"
				}
				X "$indent`t`t</dcscor:value>"
			}
		} elseif (Has-DLProp $item 'typeLink') {
			# Связь по типу (dcscor:TypeLink) — field + linkItem (структурное значение параметра).
			$tl = $item.typeLink
			X "$indent`t`t<dcscor:value xsi:type=`"dcscor:TypeLink`">"
			$tlf = Get-Prop $tl 'field'; if ($null -ne $tlf) { X "$indent`t`t`t<dcscor:field>$(Esc-XmlText "$tlf")</dcscor:field>" }
			$tli = Get-Prop $tl 'linkItem'; if ($null -ne $tli) { X "$indent`t`t`t<dcscor:linkItem>$(Esc-XmlText "$tli")</dcscor:linkItem>" }
			X "$indent`t`t</dcscor:value>"
		} elseif (Has-DLProp $item 'value') {
			$val = $item.value
			if ($val -is [bool]) { X "$indent`t`t<dcscor:value xsi:type=`"xs:boolean`">$(if ($val) { 'true' } else { 'false' })</dcscor:value>" }
			elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) { X "$indent`t`t<dcscor:value xsi:type=`"xs:decimal`">$val</dcscor:value>" }
			elseif ($val -is [hashtable] -or $val -is [System.Collections.IDictionary] -or $val -is [PSCustomObject]) { Emit-DLMLText -tag "dcscor:value" -text $val -indent "$indent`t`t" }
			else { X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-XmlText "$val")</dcscor:value>" }
		}
		X "$indent`t</dcscor:item>"
	}
	X "$indent</dcssch:inputParameters>"
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
	$tBare = if ($t -match '^xs:(.+)$') { $matches[1] } else { $t }
	$pf = $tagPrefix
	if ($t -eq "") { X "$indent<${pf}value xsi:nil=`"true`"/>" }
	elseif ($t -eq "StandardPeriod") {
		X "$indent<${pf}value xsi:type=`"v8:StandardPeriod`">"
		X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">Custom</v8:variant>"
		X "$indent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
		X "$indent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
		X "$indent</${pf}value>"
	}
	elseif ($tBare -match '^string') { X "$indent<${pf}value xsi:type=`"xs:string`"/>" }
	elseif ($tBare -match '^(date|time)') { X "$indent<${pf}value xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</${pf}value>" }
	elseif ($tBare -match '^decimal') { X "$indent<${pf}value xsi:type=`"xs:decimal`">0</${pf}value>" }
	elseif ($tBare -eq "boolean") { X "$indent<${pf}value xsi:type=`"xs:boolean`">false</${pf}value>" }
	else { X "$indent<${pf}value xsi:nil=`"true`"/>" }
}

function Parse-DataParamShorthand {
	param([string]$s)
	$result = @{ parameter = ""; value = $null; use = $true; userSettingID = $null; viewMode = $null }
	if ($s -match '@user') { $result.userSettingID = "auto"; $s = $s -replace '\s*@user', '' }
	if ($s -match '@off') { $result.use = $false; $s = $s -replace '\s*@off', '' }
	if ($s -match '@quickAccess') { $result.viewMode = "QuickAccess"; $s = $s -replace '\s*@quickAccess', '' }
	if ($s -match '@normal') { $result.viewMode = "Normal"; $s = $s -replace '\s*@normal', '' }
	$s = $s.Trim()
	if ($s -match '^([^=]+)=\s*(.+)$') {
		$result.parameter = $Matches[1].Trim()
		$valStr = $Matches[2].Trim()
		$periodVariants = @("Custom","Today","ThisWeek","ThisTenDays","ThisMonth","ThisQuarter","ThisHalfYear","ThisYear","FromBeginningOfThisWeek","FromBeginningOfThisTenDays","FromBeginningOfThisMonth","FromBeginningOfThisQuarter","FromBeginningOfThisHalfYear","FromBeginningOfThisYear","LastWeek","LastTenDays","LastMonth","LastQuarter","LastHalfYear","LastYear","NextDay","NextWeek","NextTenDays","NextMonth","NextQuarter","NextHalfYear","NextYear","TillEndOfThisWeek","TillEndOfThisTenDays","TillEndOfThisMonth","TillEndOfThisQuarter","TillEndOfThisHalfYear","TillEndOfThisYear")
		if ($periodVariants -contains $valStr) { $result.value = @{ variant = $valStr } }
		elseif ($valStr -match '^\d{4}-\d{2}-\d{2}T') { $result.value = $valStr }
		elseif ($valStr -eq "true" -or $valStr -eq "false") { $result.value = [bool]($valStr -eq "true") }
		else { $result.value = $valStr }
	} else { $result.parameter = $s }
	return $result
}

function Emit-DataParameters {
	param($items, [string]$indent, $blockViewMode = $null)
	if (-not $items -or @($items).Count -eq 0) { return }
	X "$indent<dcsset:dataParameters>"
	foreach ($dp in @($items)) {
		if ($dp -is [string]) {
			$parsed = Parse-DataParamShorthand $dp
			$dpObj = New-Object PSObject
			$dpObj | Add-Member -NotePropertyName "parameter" -NotePropertyValue $parsed.parameter
			if ($null -ne $parsed.value) { $dpObj | Add-Member -NotePropertyName "value" -NotePropertyValue $parsed.value }
			if ($parsed.use -eq $false) { $dpObj | Add-Member -NotePropertyName "use" -NotePropertyValue $false }
			if ($parsed.userSettingID) { $dpObj | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue $parsed.userSettingID }
			if ($parsed.viewMode) { $dpObj | Add-Member -NotePropertyName "viewMode" -NotePropertyValue $parsed.viewMode }
			$dp = $dpObj
		}
		X "$indent`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
		if ($dp.use -eq $false) { X "$indent`t`t<dcscor:use>false</dcscor:use>" }
		X "$indent`t`t<dcscor:parameter>$(Esc-XmlText "$($dp.parameter)")</dcscor:parameter>"
		$dpValIsArr = ($dp.value -is [array]) -or ($dp.value -is [System.Collections.IList] -and $dp.value -isnot [string])
		if ($dpValIsArr) {
			# Список значений параметра (valueListAllowed) — отдельный <dcscor:value> на каждое.
			$avtype = "$($dp.valueType)"
			foreach ($v in @($dp.value)) {
				$vStr = if ($v -is [bool]) { "$v".ToLower() } else { "$v" }
				if ($avtype -match '^[a-zA-Z]+:') { X "$indent`t`t<dcscor:value xsi:type=`"$avtype`">$(Esc-XmlText $vStr)</dcscor:value>" }
				elseif ("$vStr" -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or "$vStr" -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { X "$indent`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-XmlText $vStr)</dcscor:value>" }
				else { X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-XmlText $vStr)</dcscor:value>" }
			}
		} elseif ($dp.nilValue -eq $true) {
			X "$indent`t`t<dcscor:value xsi:nil=`"true`"/>"
		} elseif ((Test-EmptyValue $dp.value) -and $dp.valueType) {
			# Явный типизированный пустой (xs:string-плейсхолдер и т.п.)
			Emit-EmptyValue -type "$($dp.valueType)" -indent "$indent`t`t" -tagPrefix "dcscor:" -valueListAllowed $false
		} elseif (Test-EmptyValue $dp.value) {
			# Нет значения и нет valueType → НЕ эмитим value-узел (form дин-список: use=false плейсхолдер).
			# (В отличие от skd-settings, где значение всегда присутствует.)
		} elseif ($null -ne $dp.value) {
			$vtype = "$($dp.valueType)"
			if (($dp.value -is [PSCustomObject] -or $dp.value -is [hashtable] -or $dp.value -is [System.Collections.IDictionary]) -and ($dp.value.variant)) {
				$_hasDate = $false; $_hasSD = $false
				if ($dp.value -is [PSCustomObject]) { $_hasDate = [bool]$dp.value.PSObject.Properties['date']; $_hasSD = [bool]$dp.value.PSObject.Properties['startDate'] }
				else { $_hasDate = $dp.value.Contains('date'); $_hasSD = $dp.value.Contains('startDate') }
				$_variantStr = "$($dp.value.variant)"
				$_isSBD = $_hasDate -or (-not $_hasSD -and $_variantStr -like 'BeginningOf*')
				if ($_isSBD) {
					$_d = $null
					if ($dp.value -is [PSCustomObject] -and $dp.value.PSObject.Properties['date']) { $_d = "$($dp.value.date)" }
					elseif (($dp.value -is [System.Collections.IDictionary]) -and $dp.value.Contains('date')) { $_d = "$($dp.value['date'])" }
					X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardBeginningDate`">"
					X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardBeginningDateVariant`">$(Esc-XmlText $_variantStr)</v8:variant>"
					if ($_variantStr -eq 'Custom') { if (-not $_d) { $_d = '0001-01-01T00:00:00' }; X "$indent`t`t`t<v8:date>$(Esc-XmlText $_d)</v8:date>" }
					X "$indent`t`t</dcscor:value>"
				} else {
					$_sd = $null; $_ed = $null
					if ($dp.value -is [PSCustomObject]) { if ($dp.value.PSObject.Properties['startDate']) { $_sd = "$($dp.value.startDate)" }; if ($dp.value.PSObject.Properties['endDate']) { $_ed = "$($dp.value.endDate)" } }
					else { if ($dp.value.Contains('startDate')) { $_sd = "$($dp.value['startDate'])" }; if ($dp.value.Contains('endDate')) { $_ed = "$($dp.value['endDate'])" } }
					X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardPeriod`">"
					X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-XmlText $_variantStr)</v8:variant>"
					if ($_variantStr -eq 'Custom') { if (-not $_sd) { $_sd = '0001-01-01T00:00:00' }; if (-not $_ed) { $_ed = '0001-01-01T00:00:00' }; X "$indent`t`t`t<v8:startDate>$(Esc-XmlText $_sd)</v8:startDate>"; X "$indent`t`t`t<v8:endDate>$(Esc-XmlText $_ed)</v8:endDate>" }
					X "$indent`t`t</dcscor:value>"
				}
			} elseif ($vtype -match '^[a-zA-Z]+:') {
				$vStr = if ($dp.value -is [bool]) { "$($dp.value)".ToLower() } else { "$($dp.value)" }
				X "$indent`t`t<dcscor:value xsi:type=`"$vtype`">$(Esc-XmlText $vStr)</dcscor:value>"
			} elseif ($vtype -eq 'boolean' -or $dp.value -is [bool]) {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:boolean`">$(Esc-XmlText ("$($dp.value)".ToLower()))</dcscor:value>"
			} elseif ($vtype -match '^date' -or "$($dp.value)" -match '^\d{4}-\d{2}-\d{2}T') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-XmlText "$($dp.value)")</dcscor:value>"
			} elseif ($vtype -match '^decimal') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:decimal`">$(Esc-XmlText "$($dp.value)")</dcscor:value>"
			} elseif ($vtype -match '^string') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-XmlText "$($dp.value)")</dcscor:value>"
			} elseif ("$($dp.value)" -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or "$($dp.value)" -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-XmlText "$($dp.value)")</dcscor:value>"
			} else {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-XmlText "$($dp.value)")</dcscor:value>"
			}
		}
		if ($dp.viewMode) { X "$indent`t`t<dcsset:viewMode>$(Esc-XmlText "$($dp.viewMode)")</dcsset:viewMode>" }
		if ($dp.userSettingID) { $uid = if ("$($dp.userSettingID)" -eq "auto") { New-Guid-String } else { "$($dp.userSettingID)" }; X "$indent`t`t<dcsset:userSettingID>$(Esc-XmlText $uid)</dcsset:userSettingID>" }
		if ($dp.userSettingPresentation) { Emit-USPresentation -val $dp.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t`t" }
		X "$indent`t</dcscor:item>"
	}
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-XmlText "$blockViewMode")</dcsset:viewMode>" }
	X "$indent</dcsset:dataParameters>"
}

function Emit-DLParameter {
	param($p, $parsed, [string]$indent)
	X "$indent<Parameter>"
	$ci = "$indent`t"
	X "$ci<dcssch:name>$(Esc-XmlText $parsed.name)</dcssch:name>"
	# Title: явный override (shorthand [..] / объект title/presentation) или авто из имени.
	$title = $null
	if ($parsed.title) { $title = $parsed.title }
	elseif ($p -isnot [string] -and (Has-DLProp $p 'title') -and $p.title) { $title = $p.title }
	elseif ($p -isnot [string] -and (Has-DLProp $p 'presentation') -and $p.presentation) { $title = $p.presentation }
	if ($null -eq $title -or ($title -is [string] -and $title -eq '')) { $title = Title-FromName -name $parsed.name }
	Emit-DLMLText -tag "dcssch:title" -text $title -indent $ci
	# valueType
	if ($parsed.type) { Emit-DLValueType -typeStr $parsed.type -indent $ci }
	# value (дефолт nil; при valueListAllowed пустое — опускаем)
	$vla = [bool]$parsed.valueListAllowed
	$valIsArray = ($parsed.value -is [array]) -or ($parsed.value -is [System.Collections.IList] -and $parsed.value -isnot [string])
	if ($valIsArray) {
		foreach ($v in @($parsed.value)) { Emit-DLValue -type $parsed.type -val $v -indent $ci -valueListAllowed $false }
	} elseif ($parsed.valueExplicit -and ($null -ne $parsed.value) -and ("$($parsed.value)" -eq '') -and (("$($parsed.type)" -eq '') -or ("$($parsed.type)" -match '^string'))) {
		# Явный пустой СТРОКОВЫЙ параметр (value:"" от декомпилятора) → типизированный пустой
		# <dcssch:value xsi:type="xs:string"/>, НЕ nil. Решается ФОРМОЙ value (""→typed-empty,
		# null/отсутствие→nil), независимо от valueListAllowed; декомпилятор различает ""/null
		# (Convert-TypedValue пустого xs:string → "", nil → value опущен/null). Корпус: 26 xs:string.
		X "$ci<dcssch:value xsi:type=`"xs:string`"/>"
	} elseif ($vla -and (Test-DLEmptyValue $parsed.value) -and $parsed.valueExplicit) {
		# valueListAllowed + явный пустой (value:null от декомпилятора) → платформа здесь пишет nil
		X "$ci<dcssch:value xsi:nil=`"true`"/>"
	} else {
		Emit-DLValue -type $parsed.type -val $parsed.value -indent $ci -valueListAllowed $vla
	}
	# useRestriction — ВСЕГДА; дефолт true; false только при явном useRestriction:false.
	$ur = $true
	if ($p -isnot [string] -and (Has-DLProp $p 'useRestriction')) { $ur = [bool]$p.useRestriction }
	X "$ci<dcssch:useRestriction>$(if ($ur) { 'true' } else { 'false' })</dcssch:useRestriction>"
	# expression
	$expr = $null
	if ($p -isnot [string] -and (Has-DLProp $p 'expression') -and $p.expression) { $expr = "$($p.expression)" }
	if ($expr) { X "$ci<dcssch:expression>$(Esc-XmlText $expr)</dcssch:expression>" }
	# availableValues
	if ($p -isnot [string] -and (Has-DLProp $p 'availableValues') -and $p.availableValues) {
		foreach ($av in @($p.availableValues)) { Emit-DLAvailableValue -av $av -type $parsed.type -indent $ci }
	}
	# valueListAllowed
	if ($vla) { X "$ci<dcssch:valueListAllowed>true</dcssch:valueListAllowed>" }
	# availableAsField=false (hidden или явный)
	$aaf = $null
	if ($parsed.hidden -eq $true) { $aaf = $false }
	if ($p -isnot [string] -and (Has-DLProp $p 'availableAsField')) { $aaf = [bool]$p.availableAsField }
	if ($aaf -eq $false) { X "$ci<dcssch:availableAsField>false</dcssch:availableAsField>" }
	# inputParameters
	if ($p -isnot [string] -and (Has-DLProp $p 'inputParameters') -and $p.inputParameters) { Emit-DLInputParameters -ip $p.inputParameters -indent $ci }
	# denyIncompleteValues
	if ($p -isnot [string] -and (Has-DLProp $p 'denyIncompleteValues') -and $p.denyIncompleteValues -eq $true) { X "$ci<dcssch:denyIncompleteValues>true</dcssch:denyIncompleteValues>" }
	# use
	$useVal = $null
	if ($p -isnot [string] -and (Has-DLProp $p 'use') -and $p.use) { $useVal = "$($p.use)" }
	if ($useVal) { X "$ci<dcssch:use>$(Esc-XmlText $useVal)</dcssch:use>" }
	X "$indent</Parameter>"
}

function Emit-DLParameters {
	param($params, [string]$indent)
	if (-not $params) { return }
	foreach ($p in @($params)) {
		if ($p -is [string]) {
			$parsed = Parse-DLParamShorthand $p
		} else {
			$resolvedType = ""
			if ((Has-DLProp $p 'type') -and $p.type) {
				if ($p.type -is [array] -or ($p.type -is [System.Collections.IList] -and $p.type -isnot [string])) {
					$resolvedType = (@($p.type | ForEach-Object { Resolve-TypeStr "$_" })) -join ' | '
				} else { $resolvedType = Resolve-TypeStr "$($p.type)" }
			} elseif ((Has-DLProp $p 'valueType') -and $p.valueType) {
				$resolvedType = Resolve-TypeStr "$($p.valueType)"
			}
			$parsed = @{ name = "$($p.name)"; type = $resolvedType; value = $(if (Has-DLProp $p 'value') { $p.value } else { $null }); valueExplicit = (Has-DLProp $p 'value'); title = $null }
			if ((Has-DLProp $p 'valueListAllowed') -and $p.valueListAllowed -eq $true) { $parsed.valueListAllowed = $true }
			if ((Has-DLProp $p 'hidden') -and $p.hidden -eq $true) { $parsed.hidden = $true }
		}
		Emit-DLParameter -p $p -parsed $parsed -indent $indent
	}
}

function Emit-Attributes {
	param($attrs, [string]$indent, $conditionalAppearance = $null)

	$hasCA = $conditionalAppearance -and @($conditionalAppearance).Count -gt 0
	# Платформа ВСЕГДА эмитит <Attributes> (100% корпуса; 162 формы — пустой <Attributes/>).
	if ((-not $attrs -or $attrs.Count -eq 0) -and -not $hasCA) { X "$indent<Attributes/>"; return }
	if (-not $attrs -or $attrs.Count -eq 0) {
		# Нет реквизитов, но есть условное оформление (последний child <Attributes>)
		X "$indent<Attributes>"
		Emit-ConditionalAppearance -items $conditionalAppearance -indent "$indent`t" -wrapTag 'ConditionalAppearance'
		X "$indent</Attributes>"
		return
	}

	X "$indent<Attributes>"
	$seenAttrs = @{}
	foreach ($attr in $attrs) {
		$attrId = New-Id
		$attrName = "$($attr.name)"
		Assert-UniqueName -name $attrName -seen $seenAttrs -kind 'attribute'

		X "$indent`t<Attribute name=`"$attrName`" id=`"$attrId`">"
		$inner = "$indent`t`t"

		# Title атрибута (зеркало Emit-Title): нет ключа → авто-вывод из имени (кроме main);
		# title "" → подавить; непустой → эмитить как есть.
		$hasTitleKey = $null -ne $attr.PSObject.Properties['title']
		if ($hasTitleKey) {
			if ($attr.title) { Emit-MLText -tag "Title" -text $attr.title -indent $inner }
		} elseif ($attr.main -ne $true) {
			Emit-MLText -tag "Title" -text (Title-FromName -name $attrName) -indent $inner
		}

		# Type
		if ($attr.type) {
			Emit-Type -typeStr "$($attr.type)" -indent $inner
		} else {
			X "$inner<Type/>"
		}
		# valueType: уточнение типа значений ValueList → <Settings xsi:type="v8:TypeDescription">
		# (та же грамматика типа, что и Type, включая составной "A | B"). Forgiving-синонимы.
		# Три состояния: нет ключа → нет Settings; "" → пустой <Settings…/>; тип → с типом.
		$vtSpec = $null; $hasVt = $false
		foreach ($k in @('valueType','typeDescription','описаниеТипов','типЗначений')) {
			if ($attr.PSObject.Properties[$k]) { $vtSpec = $attr.$k; $hasVt = $true; break }
		}
		if ($hasVt) {
			Emit-Type -typeStr "$vtSpec" -indent $inner -tag "Settings" -tagAttrs ' xsi:type="v8:TypeDescription"'
		}
		# Planner design-time <Settings xsi:type="pl:Planner"> (встроенный конфиг планировщика).
		# Идёт сразу после <Type> (как valueType/DynamicList Settings — взаимоисключающи).
		if ($attr.PSObject.Properties['planner'] -and $null -ne $attr.planner) {
			Emit-PlannerSettings -pl $attr.planner -ind $inner
		}
		# Chart/GanttChart design-time <Settings xsi:type="d4p1:Chart"/"d4p1:GanttChart">.
		# Тип Settings выводится из типа реквизита (d5p1:GanttChart → d4p1:GanttChart).
		if ($attr.PSObject.Properties['chart'] -and $null -ne $attr.chart) {
			$ctype = if ("$($attr.type)" -match 'GanttChart') { 'd4p1:GanttChart' } else { 'd4p1:Chart' }
			Emit-ChartSettings -chart $attr.chart -ind $inner -ctype $ctype
		}

		if ($attr.main -eq $true) {
			X "$inner<MainAttribute>true</MainAttribute>"
		}
		# Доступ по ролям: просмотр/редактирование (порядок схемы: View → Edit, после MainAttribute)
		if ($null -ne $attr.view) { Emit-XrFlag -tag 'View' -val $attr.view -indent $inner }
		if ($null -ne $attr.edit) { Emit-XrFlag -tag 'Edit' -val $attr.edit -indent $inner }
		$mainSaved = $false
		if ($attr.main -eq $true -and $attr.type) {
			$mainSaved = ("$($attr.type)") -match '^(CatalogObject|DocumentObject|ChartOfAccountsObject|ChartOfCalculationTypesObject|ChartOfCharacteristicTypesObject|ExchangePlanObject|BusinessProcessObject|TaskObject)\.' -or ("$($attr.type)") -match 'RecordManager\.'
		}
		# Явный ключ savedData побеждает (в т.ч. false → суппресс авто-вывода $mainSaved); нет ключа → авто.
		$emitSaved = if ($null -ne $attr.PSObject.Properties['savedData']) { $attr.savedData -eq $true } else { $mainSaved }
		if ($emitSaved) {
			X "$inner<SavedData>true</SavedData>"
		}
		# Save: сохранение значения реквизита в пользовательских настройках. true → <Field>имя</Field>;
		# строка/массив → под-поля с авто-префиксом "имя." (путь с точкой / UUID / =имя — как есть).
		# Нет ключа или false → не эмитим.
		if ($null -ne $attr.PSObject.Properties['save'] -and $null -ne $attr.save) {
			$saveFields = New-Object System.Collections.ArrayList
			if ($attr.save -is [bool]) {
				if ($attr.save) { [void]$saveFields.Add($attrName) }
			} else {
				foreach ($e in @($attr.save)) {
					$fld = "$e"
					if ([string]::IsNullOrEmpty($fld)) { continue }
					if ($fld -ne $attrName -and $fld -notmatch '\.' -and $fld -notmatch '^\d+/\d+') { $fld = "$attrName.$fld" }
					if (-not $saveFields.Contains($fld)) { [void]$saveFields.Add($fld) }
				}
			}
			if ($saveFields.Count -gt 0) {
				X "$inner<Save>"
				foreach ($f in $saveFields) { X "$inner`t<Field>$(Esc-XmlText $f)</Field>" }
				X "$inner</Save>"
			}
		}
		# Проверка заполнения реквизита → <FillCheck> (реальный тег; <FillChecking> в схеме нет).
		# bool true → ShowError (единственное значение в корпусе); строка → verbatim. Синоним fillChecking.
		$fcRaw = if ($null -ne $attr.PSObject.Properties['fillCheck']) { $attr.fillCheck } elseif ($null -ne $attr.PSObject.Properties['fillChecking']) { $attr.fillChecking } else { $null }
		if ($fcRaw) {
			$fcv = if ($fcRaw -is [bool]) { 'ShowError' } else { "$fcRaw" }
			X "$inner<FillCheck>$fcv</FillCheck>"
		}

		# UseAlways: поля, всегда читаемые (дин-список/таблица). Две формы DSL сливаются:
		#  attr.useAlways[] (короткие имена) + columns с useAlways:true → <Field>ИмяРеквизита.Поле</Field>.
		$uaFields = New-Object System.Collections.ArrayList
		if ($attr.useAlways) {
			foreach ($e in @($attr.useAlways)) {
				$fld = "$e"
				# Префикс "ИмяРеквизита." добавляем к коротким именам. Поля дин-списка с маркером "~"
				# (query-поля, ~13% корпуса) — префикс ставится ПОСЛЕ "~": ~Остановлен → ~Список.Остановлен.
				# Полная форма (~Список.Остановлен / Список.Остановлен) — verbatim (forgiving ввод).
				if ($fld.StartsWith('~')) {
					$bare = $fld.Substring(1)
					if ($bare -notmatch "^$([regex]::Escape($attrName))\.") { $bare = "$attrName.$bare" }
					$fld = "~$bare"
				} elseif ($fld -notmatch "^$([regex]::Escape($attrName))\." -and $fld -notmatch '^\d+/\d+') {
					# UUID-ссылка (1/0:GUID) — НЕ префиксуем (платформа хранит её без "имя.")
					$fld = "$attrName.$fld"
				}
				if (-not $uaFields.Contains($fld)) { [void]$uaFields.Add($fld) }
			}
		}
		if ($attr.columns) {
			foreach ($col in $attr.columns) {
				if ($col.useAlways -eq $true) {
					$fld = "$attrName.$($col.name)"
					if (-not $uaFields.Contains($fld)) { [void]$uaFields.Add($fld) }
				}
			}
		}
		if ($uaFields.Count -gt 0) {
			X "$inner<UseAlways>"
			foreach ($f in $uaFields) { X "$inner`t<Field>$f</Field>" }
			X "$inner</UseAlways>"
		}

		Emit-FunctionalOptions -fo $attr.functionalOptions -indent $inner

		# Columns: прямые <Column> (ValueTable/Tree) + <AdditionalColumns table="X"> (доп. колонки
		# табличных частей объекта). Порядок схемы: прямые сначала, затем AdditionalColumns-группы.
		# Для дин-списка (есть settings) прямые колонки НЕ эмитим (служат лишь для UseAlways).
		$hasDirectCols = $attr.columns -and $attr.columns.Count -gt 0 -and -not $attr.settings
		$hasAddCols = $attr.additionalColumns -and @($attr.additionalColumns).Count -gt 0
		if ($hasDirectCols -or $hasAddCols) {
			X "$inner<Columns>"
			if ($hasDirectCols) {
				$seenCols = @{}  # колонки уникальны в пределах своего реквизита
				foreach ($col in $attr.columns) {
					Assert-UniqueName -name "$($col.name)" -seen $seenCols -kind "column of '$attrName'"
					Emit-AttrColumn -col $col -indent "$inner`t"
				}
			}
			if ($hasAddCols) {
				foreach ($ac in @($attr.additionalColumns)) {
					# Пустой список колонок задаётся ЯВНО (`"columns": []`) — это законная форма,
					# платформа так пишет таблицу, у которой доп. колонок нет. А вот отсутствие ключа
					# — недосказанность автора: «доп. колонки есть», а какие, не указано. Раньше на
					# этом PS падал с «Не удается индексировать в массив NULL» (@($null).Count = 1).
					if ($null -eq $ac.PSObject.Properties['columns'] -or $null -eq $ac.columns) {
						Write-Error "additionalColumns group for table '$($ac.table)': key 'columns' is missing — list the columns, or pass an empty array for a table without extra columns"
						exit 1
					}
					$acCols = @($ac.columns)
					if ($acCols.Count -eq 0) {
						# Явно пустая группа → self-closing (как платформа)
						X "$inner`t<AdditionalColumns table=`"$($ac.table)`"/>"
						continue
					}
					X "$inner`t<AdditionalColumns table=`"$($ac.table)`">"
					$seenAcCols = @{}  # уникальность в пределах группы AdditionalColumns
					foreach ($col in $acCols) {
						Assert-UniqueName -name "$($col.name)" -seen $seenAcCols -kind "column of '$attrName'"
						Emit-AttrColumn -col $col -indent "$inner`t`t"
					}
					X "$inner`t</AdditionalColumns>"
				}
			}
			X "$inner</Columns>"
		}

		# Settings (динамический список)
		if ($attr.settings) {
			$st = $attr.settings
			X "$inner<Settings xsi:type=`"DynamicList`">"
			$si = "$inner`t"
			# Порядок платформы: AutoFillAvailableFields, ManualQuery, DynamicDataRead, QueryText, Field*, MainTable, ListSettings
			# AutoFillAvailableFields — дефолт true; эмитим только при заданном ключе (отклонение).
			if ($null -ne $st.autoFillAvailableFields) { X "$si<AutoFillAvailableFields>$(if ($st.autoFillAvailableFields){'true'}else{'false'})</AutoFillAvailableFields>" }
			$hasQuery = $st.query -and "$($st.query)".Trim()
			# Явный ключ manualQuery (в т.ч. false) ПОБЕЖДАЕТ эвристику hasQuery (платформа изредка
			# хранит QueryText при ManualQuery=false — декомпилятор фиксирует это отклонение).
			$hasMQKey = ($st.PSObject.Properties['manualQuery']) -and ($null -ne $st.manualQuery)
			$mq = if ($hasMQKey) { if ($st.manualQuery) { "true" } else { "false" } } elseif ($hasQuery) { "true" } else { "false" }
			X "$si<ManualQuery>$mq</ManualQuery>"
			# DynamicDataRead: дефолт true; false только при явном отключении
			$ddr = if ($st.dynamicDataRead -eq $false) { "false" } else { "true" }
			X "$si<DynamicDataRead>$ddr</DynamicDataRead>"
			if ($hasQuery) {
				$qtext = Resolve-TextFromFile "$($st.query)" $script:queryBaseDir
				X "$si<QueryText>$(Esc-XmlText $qtext)</QueryText>"
			}
			# Явные поля набора (редко): override title/dataPath
			if ($st.fields) {
				foreach ($fld in $st.fields) {
					# Тип поля набора: DataSetFieldField (дефолт) vs DataSetFieldNestedDataSet
					# (поле-вложенный набор = реквизит табличной части; маркер nested).
					# folder = папка-группировка полей (DataSetFieldFolder, без <field>); nested = вложенный набор.
					$isFolder = [bool](Get-Prop $fld 'folder')
					$ftype = if ($fld.nested) { "DataSetFieldNestedDataSet" } elseif ($isFolder) { "DataSetFieldFolder" } else { "DataSetFieldField" }
					X "$si<Field xsi:type=`"dcssch:$ftype`">"
					# dataPath: явный (включая пустой "" → self-closing <dcssch:dataPath/>) побеждает; иначе fallback на field.
					if ($null -ne (Get-Prop $fld 'dataPath')) { $dp = "$($fld.dataPath)" }
					elseif ($isFolder) { $dp = "" }
					else { $dp = "$($fld.field)" }
					if ($dp -eq "") { X "$si`t<dcssch:dataPath/>" } else { X "$si`t<dcssch:dataPath>$(Esc-XmlText "$dp")</dcssch:dataPath>" }
					if (-not $isFolder) { X "$si`t<dcssch:field>$(Esc-XmlText "$($fld.field)")</dcssch:field>" }
					if ($fld.title) {
						X "$si`t<dcssch:title xsi:type=`"v8:LocalStringType`">"
						Emit-MLItems -val $fld.title -indent "$si`t`t"
						X "$si`t</dcssch:title>"
					}
					# Ограничения использования поля — после title, перед presentationExpression (порядок исходника)
					Emit-RestrictBlock 'useRestriction' $fld.useRestriction "$si`t"
					Emit-RestrictBlock 'attributeUseRestriction' $fld.attributeUseRestriction "$si`t"
					# presentationExpression поля — перед valueType (порядок исходника)
					if ($fld.presentationExpression) { X "$si`t<dcssch:presentationExpression>$(Esc-XmlText "$($fld.presentationExpression)")</dcssch:presentationExpression>" }
					# valueType поля набора (тип значения; вычисляемые/кастомные поля)
					if ($fld.valueType) { Emit-DLValueType -typeStr "$($fld.valueType)" -indent "$si`t" }
					# appearance поля (формат/оформление) — после valueType (порядок исходника)
					if ($fld.appearance) {
						X "$si`t<dcssch:appearance>"
						foreach ($prop in $fld.appearance.PSObject.Properties) { Emit-AppearanceValue -key $prop.Name -val $prop.Value -indent "$si`t`t" }
						X "$si`t</dcssch:appearance>"
					}
					# inputParameters поля (связь по параметрам выбора) — в конце
					if ($fld.inputParameters) { Emit-DLInputParameters -ip $fld.inputParameters -indent "$si`t" }
					X "$si</Field>"
				}
			}
			# Вычисляемые поля DataSet (<CalculatedField>) — после Field*, до Parameter*.
			Emit-CalcFields -calcFields $st.calculatedFields -indent $si
			# Schema-параметры дин-списка (DataCompositionSchemaParameter) — после Field*, до MainTable.
			Emit-DLParameters -params $st.parameters -indent $si
			# Ключ набора (query-based список без MainTable): KeyType (RowNumber/FieldValue/RowKey)
			# + KeyField* — после Parameter*, до MainTable. Захват/эмит факт. значений.
			if ($st.keyType) { X "$si<KeyType>$(Esc-XmlText "$($st.keyType)")</KeyType>" }
			if ($st.keyFields) { foreach ($kf in @($st.keyFields)) { X "$si<KeyField>$(Esc-XmlText "$kf")</KeyField>" } }
			if ($st.mainTable) { X "$si<MainTable>$(Normalize-MetaTypeRef "$($st.mainTable)")</MainTable>" }
			# GetInvisibleFieldPresentations — после MainTable (дефолт true; эмитим только при заданном ключе = отклонении false).
			if ($null -ne $st.getInvisibleFieldPresentations) { X "$si<GetInvisibleFieldPresentations>$(if ($st.getInvisibleFieldPresentations){'true'}else{'false'})</GetInvisibleFieldPresentations>" }
			# AutoSaveUserSettings — после MainTable (дефолт true; эмитим только при заданном ключе = отклонении).
			if ($null -ne $st.autoSaveUserSettings) { X "$si<AutoSaveUserSettings>$(if ($st.autoSaveUserSettings){'true'}else{'false'})</AutoSaveUserSettings>" }
			# ListSettings: filter/order/conditionalAppearance (skd-грамматика) + каноничные блок-GUID.
			# Нет items → контейнеры всё равно эмитятся (blockMeta) = каноничный пустой скелет платформы.
			$lsi = "$si`t"
			$lsOpenLen = $script:xml.Length
			X "$si<ListSettings>"
			$lsAfterOpenLen = $script:xml.Length  # для self-closing, если внутри ничего не эмитнётся
			if ($st.PSObject.Properties['listSettings'] -and $null -ne $st.listSettings) {
				# Частичная/минимальная форма скелета — эмитим ТОЛЬКО указанные части с их блок-метой.
				# meta: 'v'=viewMode, 'u'=userSettingID (контейнеры); itemsViewMode/itemsUserSettingID → present.
				foreach ($prop in $st.listSettings.PSObject.Properties) {
					$tag = $prop.Name; $pv = $prop.Value
					# Значение дескриптора: строка-код "vu" ИЛИ объект { meta:"vu", presentation:<текст/ML> }
					# (контейнер несёт собственный userSettingPresentation — кастомную подпись настройки).
					if (($pv -is [PSCustomObject]) -or ($pv -is [System.Collections.IDictionary])) {
						$meta = "$(Get-Prop $pv 'meta')"; $bpres = Get-Prop $pv 'presentation'
					} else { $meta = "$pv"; $bpres = $null }
					$bvm = if ($meta -match 'v') { 'Normal' } else { $null }
					switch ($tag) {
						'filter'                { $bus = if ($meta -match 'u') { $script:CANON_FILTER_ID } else { $null }; Emit-Filter -items $st.filter -indent $lsi -blockViewMode $bvm -blockUserSettingID $bus -blockUserSettingPresentation $bpres }
						'order'                 { $bus = if ($meta -match 'u') { $script:CANON_ORDER_ID } else { $null }; Emit-Order -items $st.order -indent $lsi -blockViewMode $bvm -blockUserSettingID $bus -blockUserSettingPresentation $bpres }
						'conditionalAppearance' { $bus = if ($meta -match 'u') { $script:CANON_CA_ID } else { $null }; Emit-ConditionalAppearance -items $st.conditionalAppearance -indent $lsi -blockViewMode $bvm -blockUserSettingID $bus -blockUserSettingPresentation $bpres }
						'itemsViewMode'         { X "$lsi<dcsset:itemsViewMode>Normal</dcsset:itemsViewMode>" }
						'itemsUserSettingID'    { X "$lsi<dcsset:itemsUserSettingID>$($script:CANON_ITEMS_ID)</dcsset:itemsUserSettingID>" }
						'itemsUserSettingPresentation' { Emit-USPresentation -val $pv -tag "dcsset:itemsUserSettingPresentation" -indent $lsi }
						'dataParameters'        { Emit-DataParameters -items $st.dataParameters -indent $lsi }
						'structure'             { Emit-ListGrouping (Get-ListGroupingValue $st) $lsi }
					}
				}
			} else {
				# Полный каноничный скелет (умолчание, ~93% форм) — без изменений.
				Emit-Filter -items $st.filter -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_FILTER_ID
				# dataParameters — после filter, до order (XSD-порядок ListSettings)
				if ($st.PSObject.Properties['dataParameters']) { Emit-DataParameters -items $st.dataParameters -indent $lsi }
				Emit-Order -items $st.order -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_ORDER_ID
				Emit-ConditionalAppearance -items $st.conditionalAppearance -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_CA_ID
				# Группировка строк списка (авторинг без round-trip дескриптора) — после CA, до itemsViewMode
				Emit-ListGrouping (Get-ListGroupingValue $st) $lsi
				X "$lsi<dcsset:itemsViewMode>Normal</dcsset:itemsViewMode>"
				X "$lsi<dcsset:itemsUserSettingID>$($script:CANON_ITEMS_ID)</dcsset:itemsUserSettingID>"
			}
			if ($script:xml.Length -eq $lsAfterOpenLen) {
				# Пустой дескриптор listSettings:{} (оригинал = <ListSettings/>) → зеркалим self-closing.
				$script:xml.Length = $lsOpenLen
				X "$si<ListSettings/>"
			} else {
				X "$si</ListSettings>"
			}
			X "$inner</Settings>"
		}

		X "$indent`t</Attribute>"
	}
	# Условное оформление формы — последний child <Attributes> (та же DCS-грамматика, что settings CA)
	Emit-ConditionalAppearance -items $conditionalAppearance -indent "$indent`t" -wrapTag 'ConditionalAppearance'
	X "$indent</Attributes>"
}

function Emit-Parameters {
	param($params, [string]$indent)

	if (-not $params -or $params.Count -eq 0) { return }

	X "$indent<Parameters>"
	$seenParams = @{}
	foreach ($param in $params) {
		Assert-UniqueName -name "$($param.name)" -seen $seenParams -kind 'parameter'
		X "$indent`t<Parameter name=`"$($param.name)`">"
		$inner = "$indent`t`t"

		Emit-Type -typeStr "$($param.type)" -indent $inner

		if ($param.key -eq $true) {
			X "$inner<KeyParameter>true</KeyParameter>"
		}

		X "$indent`t</Parameter>"
	}
	X "$indent</Parameters>"
}

function Emit-Commands {
	param($cmds, [string]$indent)

	if (-not $cmds -or $cmds.Count -eq 0) { return }

	X "$indent<Commands>"
	$seenCmds = @{}
	foreach ($cmd in $cmds) {
		$cmdId = New-Id
		Assert-UniqueName -name "$($cmd.name)" -seen $seenCmds -kind 'command'
		X "$indent`t<Command name=`"$($cmd.name)`" id=`"$cmdId`">"
		$inner = "$indent`t`t"

		# Заголовок команды (зеркало Emit-Title): ключ есть+непустой → эмитим; ключ есть+"" → суппресс
		# (в оригинале <Title> нет — не додумывать); ключ отсутствует → авто-вывод из имени (помощь модели).
		if ($null -ne $cmd.PSObject.Properties['title']) {
			if ($cmd.title) { Emit-MLText -tag "Title" -text $cmd.title -indent $inner }
		} else {
			$cmdTitle = Title-FromName -name "$($cmd.name)"
			if ($cmdTitle) { Emit-MLText -tag "Title" -text $cmdTitle -indent $inner }
		}

		if ($cmd.tooltip) {
			Emit-MLText -tag "ToolTip" -text $cmd.tooltip -indent $inner
		}

		# Доступность команды по ролям (после ToolTip, до Action)
		if ($null -ne $cmd.use) { Emit-XrFlag -tag 'Use' -val $cmd.use -indent $inner }

		# Обработчик; в расширении — с видом вызова (callType), или несколько: actions [{handler, callType}]
		if ($cmd.actions) {
			foreach ($act in @($cmd.actions)) {
				$ct = Normalize-CallType "$($act.callType)" "$($cmd.name)" 'Action'
				$ctAttr = if ($ct) { " callType=`"$ct`"" } else { "" }
				X "$inner<Action$ctAttr>$($act.handler)</Action>"
			}
		} elseif ($cmd.action) {
			$ct = Normalize-CallType "$($cmd.callType)" "$($cmd.name)" 'Action'
			$ctAttr = if ($ct) { " callType=`"$ct`"" } else { "" }
			X "$inner<Action$ctAttr>$($cmd.action)</Action>"
		}

		if ($cmd.modifiesSavedData -eq $true) { X "$inner<ModifiesSavedData>true</ModifiesSavedData>" }

		Emit-FunctionalOptions -fo $cmd.functionalOptions -indent $inner

		if ($cmd.currentRowUse) {
			X "$inner<CurrentRowUse>$($cmd.currentRowUse)</CurrentRowUse>"
		}

		# Используемая таблица — имя элемента-таблицы (xsi:type обязателен).
		# Forgiving-ключи: table / associatedTableElementId (XML-тег) / ИспользуемаяТаблица (рус., регистр-незав.)
		$cmdTable = $cmd.table
		if (-not $cmdTable) { $cmdTable = $cmd.associatedTableElementId }
		if (-not $cmdTable) { $cmdTable = $cmd.используемаяТаблица }
		if ($cmdTable) {
			X "$inner<AssociatedTableElementId xsi:type=`"xs:string`">$(Esc-XmlText "$cmdTable")</AssociatedTableElementId>"
		}

		if ($cmd.shortcut) {
			X "$inner<Shortcut>$($cmd.shortcut)</Shortcut>"
		}

		Emit-CommandPicture -pic $cmd.picture -elemLt $cmd.loadTransparent -indent $inner

		if ($cmd.representation) {
			X "$inner<Representation>$($cmd.representation)</Representation>"
		}

		X "$indent`t</Command>"
	}
	X "$indent</Commands>"
}

function Resolve-CommandGroupKey {
	param([string]$key, [string]$panelTag)
	$k = ($key -replace '\s','').ToLower()
	if ($panelTag -eq 'NavigationPanel') {
		switch ($k) {
			'important' { return 'FormNavigationPanelImportant' }
			'важное'    { return 'FormNavigationPanelImportant' }
			'goto'      { return 'FormNavigationPanelGoTo' }
			'перейти'   { return 'FormNavigationPanelGoTo' }
			'seealso'   { return 'FormNavigationPanelSeeAlso' }
			'смтакже'   { return 'FormNavigationPanelSeeAlso' }
		}
	} else {
		switch ($k) {
			'important'          { return 'FormCommandBarImportant' }
			'важное'             { return 'FormCommandBarImportant' }
			'createbasedon'      { return 'FormCommandBarCreateBasedOn' }
			'создатьнаосновании' { return 'FormCommandBarCreateBasedOn' }
		}
	}
	return $key  # verbatim
}

function Emit-CommandInterface {
	param($ci, [string]$indent)
	if (-not $ci) { return }
	$inner = "$indent`t"
	$panels = @(
		# Порядок панелей — как в выгрузке: панель навигации раньше командной (607 из 607 форм корпуса)
		@{ Tag='NavigationPanel'; Syns=@('navigationPanel','панельНавигации','ПанельНавигации') },
		@{ Tag='CommandBar';      Syns=@('commandBar','команднаяПанель','КоманднаяПанель') }
	)
	$present = @()
	foreach ($p in $panels) {
		$items = $null
		foreach ($syn in $p.Syns) { if ($null -ne $ci.PSObject.Properties[$syn]) { $items = $ci.($syn); break } }
		if ($null -ne $items) { $present += ,@{ Tag=$p.Tag; Items=$items } }
	}
	if ($present.Count -eq 0) { return }
	X "$indent<CommandInterface>"
	foreach ($p in $present) {
		X "$inner<$($p.Tag)>"
		# Нормализация: плоский список пар (элемент, group-из-дерева). Объект → дерево.
		$flat = New-Object System.Collections.ArrayList
		if ($p.Items -is [System.Management.Automation.PSCustomObject]) {
			foreach ($prop in $p.Items.PSObject.Properties) {
				$grpFromTree = Resolve-CommandGroupKey -key $prop.Name -panelTag $p.Tag
				foreach ($it in @($prop.Value)) { [void]$flat.Add(@{ item=$it; treeGroup=$grpFromTree }) }
			}
		} else {
			foreach ($it in @($p.Items)) { [void]$flat.Add(@{ item=$it; treeGroup=$null }) }
		}
		foreach ($fi in $flat) {
			$item = $fi.item; $treeGroup = $fi.treeGroup
			if ($item -is [string]) {
				$cmd = $item; $type = 'Auto'; $attr = $null; $grp = $null; $idx = $null; $dv = $null; $vis = $null
			} else {
				$cmd  = Get-ElProp $item @('command','команда')
				$type = Get-ElProp $item @('type','тип'); if (-not $type) { $type = 'Auto' }
				$attr = Get-ElProp $item @('attribute','реквизит')
				$grp  = Get-ElProp $item @('group','группа','группаКоманд')
				$idx  = Get-ElProp $item @('index','индекс')
				$dv   = Get-ElProp $item @('defaultVisible','видимость','видимостьПоУмолчанию')
				$vis  = Get-ElProp $item @('visible','видимостьПоРолям','настройкаВидимости')
			}
			# group из дерева побеждает (если задан и непустой); явный group элемента — фолбэк
			if ($treeGroup) { $grp = $treeGroup }
			X "$inner`t<Item>"
			X "$inner`t`t<Command>$(Esc-XmlText "$cmd")</Command>"
			X "$inner`t`t<Type>$type</Type>"
			if ($attr) { X "$inner`t`t<Attribute>$(Esc-XmlText "$attr")</Attribute>" }
			if ($grp)  { X "$inner`t`t<CommandGroup>$(Esc-XmlText "$grp")</CommandGroup>" }
			if ($null -ne $idx) { X "$inner`t`t<Index>$idx</Index>" }
			if ($null -ne $dv)  { X "$inner`t`t<DefaultVisible>$(if ($dv){'true'}else{'false'})</DefaultVisible>" }
			if ($null -ne $vis) { Emit-XrFlag -tag 'Visible' -val $vis -indent "$inner`t`t" }
			X "$inner`t</Item>"
		}
		X "$inner</$($p.Tag)>"
	}
	X "$indent</CommandInterface>"
}

function Get-FormRootRank([string]$tag) {
	$i = [array]::IndexOf(($script:formRootTagOrder -split ' '), $tag)
	if ($i -lt 0) { return [array]::IndexOf(($script:formRootTagOrder -split ' '), 'AutoCommandBar') - 0.5 }
	return $i
}

function Warn-UnknownFormEvent([string]$name) {
	if ($script:knownFormEvents -notcontains $name) {
		Write-Host "[WARN] Unknown form event '$name'. Known: $($script:knownFormEvents -join ', ')"
	}
}

function Emit-Properties {
	param($props, [string]$indent)

	if (-not $props) { return }

	# camelCase -> PascalCase mapping for known properties
	$propMap = @{
		"autoTitle"              = "AutoTitle"
		"windowOpeningMode"      = "WindowOpeningMode"
		"commandBarLocation"     = "CommandBarLocation"
		"saveDataInSettings"     = "SaveDataInSettings"
		"autoSaveDataInSettings" = "AutoSaveDataInSettings"
		"autoTime"               = "AutoTime"
		"usePostingMode"         = "UsePostingMode"
		"repostOnWrite"          = "RepostOnWrite"
		"autoURL"                = "AutoURL"
		"autoFillCheck"          = "AutoFillCheck"
		"customizable"           = "Customizable"
		"enterKeyBehavior"       = "EnterKeyBehavior"
		"verticalScroll"         = "VerticalScroll"
		"scalingMode"            = "ScalingMode"
		"useForFoldersAndItems"  = "UseForFoldersAndItems"
		"reportResult"           = "ReportResult"
		"detailsData"            = "DetailsData"
		"reportFormType"         = "ReportFormType"
		"autoShowState"          = "AutoShowState"
		"width"                  = "Width"
		"height"                 = "Height"
		"group"                  = "Group"
	}

	foreach ($p in $props.PSObject.Properties) {
		$xmlName = if ($propMap.ContainsKey($p.Name)) { $propMap[$p.Name] } else {
			# Auto PascalCase: first letter uppercase
			$p.Name.Substring(0,1).ToUpper() + $p.Name.Substring(1)
		}
		# Convert boolean to lowercase string (PS renders as True/False)
		$val = $p.Value
		# Пустая строка = суппресс-маркер (напр. autoTitle:"" — не эмитить и не додумывать)
		if ($val -is [string] -and $val -eq '') { continue }
		if ($val -is [bool]) {
			$val = if ($val) { "true" } else { "false" }
		}
		X "$indent<$xmlName>$(Esc-XmlText "$val")</$xmlName>"
	}
}

function Normalize-PanelSynonyms {
	param($el)
	if ($null -eq $el) { return }
	$panelSyns = @{
		'commandBar' = @('commandBar','autoCommandBar','AutoCommandBar','autoCmdBar','cmdBar','КоманднаяПанель')
		'contextMenu' = @('contextMenu','ContextMenu','КонтекстноеМеню')
	}
	foreach ($canon in $panelSyns.Keys) {
		foreach ($syn in $panelSyns[$canon]) {
			$p = $el.PSObject.Properties[$syn]
			if ($null -ne $p -and ($p.Value -is [array] -or $p.Value -is [System.Management.Automation.PSCustomObject])) {
				if ($syn -ne $canon -and $null -eq $el.PSObject.Properties[$canon]) {
					$v = $p.Value
					$el.PSObject.Properties.Remove($syn) | Out-Null
					$el | Add-Member -NotePropertyName $canon -NotePropertyValue $v -Force
				}
				break
			}
		}
	}
}

function Normalize-ElementSynonyms {
	param($el)
	if ($null -eq $el) { return }
	Normalize-PanelSynonyms $el
	# Тип-синонимы (commandBar/autoCommandBar → элемент-тип) применяем ТОЛЬКО к строковому
	# значению (имя элемента); объект/массив уже отнесён к панель-свойству выше.
	$typeSyn = @{ "commandBar" = "cmdBar"; "autoCommandBar" = "autoCmdBar" }
	foreach ($pair in $typeSyn.GetEnumerator()) {
		$src = $el.PSObject.Properties[$pair.Key]
		if ($null -ne $src -and ($src.Value -is [string]) -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}
	if ($el.PSObject.Properties["extTooltip"] -and $null -eq $el.PSObject.Properties["extendedTooltip"]) {
		$val = $el.extTooltip
		$el.PSObject.Properties.Remove("extTooltip") | Out-Null
		$el | Add-Member -NotePropertyName "extendedTooltip" -NotePropertyValue $val -Force
	}
	# Рекурсия в детей панелей (commandBar/contextMenu) — нормализуем кнопки/группы внутри
	foreach ($pk in @('commandBar','contextMenu')) {
		$pp = $el.PSObject.Properties[$pk]
		if ($null -ne $pp) {
			$kids = if ($pp.Value -is [array]) { $pp.Value } elseif ($null -ne $pp.Value) { $pp.Value.children } else { $null }
			if ($kids) { foreach ($child in $kids) { Normalize-ElementSynonyms $child } }
		}
	}
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { Normalize-ElementSynonyms $child }
	}
	if ($el.PSObject.Properties["columns"] -and $el.columns) {
		foreach ($child in $el.columns) { Normalize-ElementSynonyms $child }
	}
}

function ApplyDynamicListTableHeuristic {
	param($el, [string]$listName, [bool]$hasMainTable)
	if ($null -eq $el) { return }
	if ($el.PSObject.Properties["table"] -and $null -ne $el.table -and "$($el.path)" -eq $listName) {
		# Маркер дин-список-таблицы → Emit-Table эмитит блок свойств (Group A defaults)
		$el | Add-Member -NotePropertyName "_dynList" -NotePropertyValue $true -Force
		if ($null -eq $el.PSObject.Properties["tableAutofill"]) {
			$el | Add-Member -NotePropertyName "tableAutofill" -NotePropertyValue $false -Force
		}
		if ($null -eq $el.PSObject.Properties["commandBarLocation"]) {
			$el | Add-Member -NotePropertyName "commandBarLocation" -NotePropertyValue "None" -Force
		}
		# RowPictureDataPath: умный дефолт <Список>.DefaultPicture, если ключ ОТСУТСТВУЕТ.
		# Декомпилятор опускает ключ при rpdp == smart-default (ждёт реинъекции); реальное отсутствие
		# фиксирует ""-маркером (НЕ перезатирается). Гейт hasMainTable снят: дин-список без mainTable
		# (напр. query-based) тоже несёт RowPictureDataPath.
		if ($null -eq $el.PSObject.Properties["rowPictureDataPath"]) {
			$el | Add-Member -NotePropertyName "rowPictureDataPath" -NotePropertyValue "$listName.DefaultPicture" -Force
		}
	}
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { ApplyDynamicListTableHeuristic $child $listName $hasMainTable }
	}
}

# === 6. Find element by name recursively ===

function Find-Element($startNode, [string]$targetName) {
	foreach ($child in $startNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childName = $child.GetAttribute("name")
		if ($childName -eq $targetName) { return $child }
		$ci = $child.SelectSingleNode("f:ChildItems", $nsMgr)
		if ($ci) {
			$found = Find-Element $ci $targetName
			if ($found) { return $found }
		}
	}
	return $null
}

# === 7. Detect indent level of a container's children ===

function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			$text = $child.Value
			if ($text -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($text -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	# Fallback: count depth from root
	$depth = 0
	$current = $container
	while ($current -and $current -ne $xmlDoc.DocumentElement) {
		$depth++
		$current = $current.ParentNode
	}
	return "`t" * ($depth + 1)
}

# === 8. Insert node into container ===

function Insert-IntoContainer($container, $newNode, $afterName, $childIndent) {
	$refNode = $null

	if ($afterName) {
		# Find the after-element, then insert after it
		$afterElem = $null
		foreach ($child in $container.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.GetAttribute("name") -eq $afterName) {
				$afterElem = $child
				break
			}
		}
		if ($afterElem) {
			$refNode = $afterElem.NextSibling
		} else {
			Write-Host "[WARN] after='$afterName' not found in target container, appending at end"
		}
	}

	if (-not $refNode) {
		# Append at end: insert before trailing whitespace
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$refNode = $trailing
		}
	}

	$ws = $xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $refNode) | Out-Null
	} else {
		# Container is empty (self-closing) — add framing whitespace
		$container.AppendChild($ws) | Out-Null
		$container.AppendChild($newNode) | Out-Null
		$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
		$closeWs = $xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
}

# === 9. Generate fragment, parse, import nodes ===

# Все пространства имён корня формы — эмиттер пишет xsi:type, ent:, style: и др.
$allNsDecl = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

function Parse-Fragment([string]$xmlText) {
	$fragDoc = New-Object System.Xml.XmlDocument
	$fragDoc.PreserveWhitespace = $true
	$fragDoc.LoadXml($xmlText)
	return $fragDoc
}

function Import-ElementNodes($fragDoc) {
	$nodes = @()
	foreach ($child in $fragDoc.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $xmlDoc.ImportNode($child, $true)
		}
	}
	return $nodes
}

# === 9c. Помощники операций над деревом элементов ===

function Fail([string]$msg) {
	Write-Host "[ERROR] $msg"
	exit 1
}

function Same($a, $b) { return [object]::ReferenceEquals($a, $b) }

function Test-IsWs($n) {
	return ($null -ne $n -and ($n.NodeType -eq 'Whitespace' -or $n.NodeType -eq 'SignificantWhitespace'))
}

function Get-NextElementSibling($n) {
	$s = $n.NextSibling
	while ($null -ne $s -and $s.NodeType -ne 'Element') { $s = $s.NextSibling }
	return $s
}

function Get-FirstElementChild($n) {
	foreach ($c in $n.ChildNodes) { if ($c.NodeType -eq 'Element') { return $c } }
	return $null
}

function Get-ContainerLabel($c) {
	if (Same $c $root) { return "корень формы" }
	return $c.GetAttribute("name")
}

# Вставка узла в контейнер: перед $ref или в конец. Перевод строки с отступом идёт перед каждым
# дочерним узлом, у пустого контейнера — ещё и закрывающий с отступом родителя.
function Insert-NodeAt($container, $node, $ref, [string]$indent) {
	if ($null -ne $ref) {
		$container.InsertBefore($node, $ref) | Out-Null
		$container.InsertBefore($xmlDoc.CreateWhitespace("`r`n$indent"), $ref) | Out-Null
		return
	}
	$trailing = $container.LastChild
	if (Test-IsWs $trailing) {
		$container.InsertBefore($xmlDoc.CreateWhitespace("`r`n$indent"), $trailing) | Out-Null
		$container.InsertBefore($node, $trailing) | Out-Null
	} else {
		$container.AppendChild($xmlDoc.CreateWhitespace("`r`n$indent")) | Out-Null
		$container.AppendChild($node) | Out-Null
		$parentIndent = if ($indent.Length -gt 0) { $indent.Substring(0, $indent.Length - 1) } else { "" }
		$container.AppendChild($xmlDoc.CreateWhitespace("`r`n$parentIndent")) | Out-Null
	}
}

# Дочерний узел элемента — на его каноническое место (см. 9b). Неизвестный тег — в конец.
function Insert-ChildCanonical($parent, $child) {
	$rank = Get-ChildRank $parent.LocalName $child.LocalName
	$ref = $null
	if ($rank -ge 0) {
		foreach ($c in $parent.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			if ((Get-ChildRank $parent.LocalName $c.LocalName) -gt $rank) { $ref = $c; break }
		}
	}
	Insert-NodeAt $parent $child $ref (Get-ChildIndent $parent)
}

# Узел вместе с переводом строки перед ним.
function Remove-NodeWithWs($node) {
	$parent = $node.ParentNode
	$prev = $node.PreviousSibling
	if (Test-IsWs $prev) { $parent.RemoveChild($prev) | Out-Null }
	$parent.RemoveChild($node) | Out-Null
}

# Пустой ChildItems платформа не пишет никогда: у группы без элементов тега просто нет.
function Remove-IfEmptyChildItems($ci) {
	if ($null -ne (Get-FirstElementChild $ci)) { return }
	Remove-NodeWithWs $ci
	if (Same $ci $script:rootCI) { $script:rootCI = $null }
}

$script:rootAfterChildItems = @('Attributes','Parameters','Commands','CommandInterface','ConditionalAppearance','BaseForm')

function Get-OrCreateChildItems($container) {
	$ci = $container.SelectSingleNode("f:ChildItems", $nsMgr)
	if ($null -ne $ci) { return $ci }
	$ci = $xmlDoc.CreateElement("ChildItems", $formNs)
	if (Same $container $root) {
		# ChildItems формы — после Events или AutoCommandBar, иначе перед первой из следующих секций
		$insertAfter = $root.SelectSingleNode("f:Events", $nsMgr)
		if ($null -eq $insertAfter) { $insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr) }
		$ref = $null
		if ($null -ne $insertAfter) {
			$ref = Get-NextElementSibling $insertAfter
		} else {
			foreach ($c in $root.ChildNodes) {
				if ($c.NodeType -eq 'Element' -and $script:rootAfterChildItems -contains $c.LocalName) { $ref = $c; break }
			}
		}
		Insert-NodeAt $root $ci $ref "`t"
		$script:rootCI = $ci
	} else {
		Insert-ChildCanonical $container $ci
	}
	return $ci
}

function Get-NodeIndent($node) {
	$prev = $node.PreviousSibling
	if ((Test-IsWs $prev) -and $prev.Value -match '\n(\t*)$') { return $Matches[1] }
	return ""
}

# Сдвиг отступов поддерева при смене глубины: каждый перевод строки внутри узла начинается с отступа
# старого места — меняем этот префикс на новый.
function Set-SubtreeIndent($node, [string]$oldIndent, [string]$newIndent) {
	if ($oldIndent -eq $newIndent) { return }
	foreach ($c in $node.ChildNodes) {
		if (Test-IsWs $c) {
			if ($c.Value -match '^(\r?\n)(\t*)$' -and $Matches[2].StartsWith($oldIndent)) {
				$c.Value = $Matches[1] + $newIndent + $Matches[2].Substring($oldIndent.Length)
			}
		} elseif ($c.NodeType -eq 'Element') {
			Set-SubtreeIndent $c $oldIndent $newIndent
		}
	}
}

# Элемент формы по имени: дерево ChildItems и командная панель формы (с кнопками). BaseForm,
# реквизиты и команды не просматриваются. Имена в 1С регистронезависимы.
function Find-FormElement([string]$name) {
	$scopes = @()
	if ($null -ne $script:rootCI) { $scopes += $script:rootCI }
	$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($null -ne $acb) {
		if ($acb.GetAttribute("name") -eq $name) { return $acb }
		$scopes += $acb
	}
	# Элементы — узлы ChildItems и служебные узлы элемента (для внятного отказа); <Event name=…> и
	# прочие именованные свойства — не элементы.
	foreach ($s in $scopes) {
		foreach ($n in $s.SelectNodes(".//*[@name]")) {
			if ($n.NamespaceURI -ne $formNs -or $n.GetAttribute("name") -ne $name) { continue }
			if ($n.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $n.LocalName) { return $n }
		}
	}
	return $null
}

function Get-NearestTable($node, [bool]$inclusive) {
	$cur = if ($inclusive) { $node } else { $node.ParentNode }
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($cur.LocalName -eq 'Table') { return $cur }
		$cur = $cur.ParentNode
	}
	return $null
}

function Test-IsInside($node, $anc) {
	$cur = $node
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if (Same $cur $anc) { return $true }
		$cur = $cur.ParentNode
	}
	return $false
}

# Позиция операции: контейнер + узел, перед которым вставлять ($null — в конец).
# after/before — контейнер якоря; into — в конец (first — в начало); first без into — начало формы.
function Resolve-Position($op, [string]$ctx, [bool]$required) {
	$after = $op.after; $before = $op.before; $into = $op.into
	if ($null -ne $op.PSObject.Properties['first'] -and -not ($op.first -is [bool])) { Fail "${ctx}: first — true или false" }
	$first = ($op.first -is [bool] -and $op.first)
	if ($after -and $before) { Fail "${ctx}: укажи что-то одно — after или before" }
	$anchorName = if ($after) { "$after" } elseif ($before) { "$before" } else { $null }
	if ($first -and $anchorName) { Fail "${ctx}: first — это начало контейнера, вместе с after/before не задаётся" }
	$intoEl = $null
	if ($into) {
		$intoEl = Find-FormElement "$into"
		if ($null -eq $intoEl) { Fail "${ctx}: контейнер '$into' не найден в форме" }
	}
	if ($anchorName) {
		$anchor = Find-FormElement $anchorName
		if ($null -eq $anchor) { Fail "${ctx}: элемент '$anchorName' не найден в форме" }
		$ci = $anchor.ParentNode
		if ($ci.LocalName -ne 'ChildItems') { Fail "${ctx}: '$anchorName' — служебный узел ($($anchor.LocalName)), рядом с ним ставить нельзя" }
		$container = $ci.ParentNode
		if ($null -ne $intoEl -and -not (Same $intoEl $container)) {
			Fail "${ctx}: '$anchorName' лежит в '$(Get-ContainerLabel $container)', а не в '$into'"
		}
		if ($after) {
			return @{ Container = $container; Ref = (Get-NextElementSibling $anchor); Anchor = $anchor; Desc = "$(Get-ContainerLabel $container), после $anchorName" }
		}
		return @{ Container = $container; Ref = $anchor; Anchor = $anchor; Desc = "$(Get-ContainerLabel $container), перед $anchorName" }
	}
	if ($null -eq $intoEl -and $first) { $intoEl = $root }
	if ($null -ne $intoEl) {
		$ref = $null
		if ($first) {
			$ci = $intoEl.SelectSingleNode("f:ChildItems", $nsMgr)
			if ($null -ne $ci) { $ref = Get-FirstElementChild $ci }
		}
		$where = if ($first) { "первым" } else { "в конец" }
		return @{ Container = $intoEl; Ref = $ref; Anchor = $null; Desc = "$(Get-ContainerLabel $intoEl), $where" }
	}
	if ($required) { Fail "${ctx}: не указано, куда — нужен after, before или into" }
	return $null
}

$script:containerTags = @('UsualGroup','Page','Pages','Table','ColumnGroup','CommandBar','AutoCommandBar','ButtonGroup','Popup','ContextMenu')
$script:barTags = @('CommandBar','AutoCommandBar','ButtonGroup','Popup','ContextMenu')
$script:barItemTags = @('Button','ButtonGroup','Popup')
$script:additionTags = @('SearchStringAddition','ViewStatusAddition','SearchControlAddition')
$script:tableItemTags = @('InputField','CheckBoxField','LabelField','PictureField','ColumnGroup')
$script:companionTags = @('ContextMenu','ExtendedTooltip','AutoCommandBar','SearchStringAddition','ViewStatusAddition','SearchControlAddition')
$script:dslTagMap = @{
	"radio"="RadioButtonField"; "columnGroup"="ColumnGroup"; "buttonGroup"="ButtonGroup"
	"searchString"="SearchStringAddition"; "viewStatus"="ViewStatusAddition"; "searchControl"="SearchControlAddition"
	"spreadsheet"="SpreadSheetDocumentField"; "html"="HTMLDocumentField"; "textDoc"="TextDocumentField"
	"formattedDoc"="FormattedDocumentField"; "progressBar"="ProgressBarField"; "trackBar"="TrackBarField"
	"chart"="ChartField"; "ganttChart"="GanttChartField"; "graphicalSchema"="GraphicalSchemaField"
	"planner"="PlannerField"; "periodField"="PeriodField"; "dendrogram"="DendrogramField"
	"group"="UsualGroup"; "input"="InputField"; "check"="CheckBoxField"; "label"="LabelDecoration"
	"labelField"="LabelField"; "table"="Table"; "pages"="Pages"; "page"="Page"; "button"="Button"
	"picture"="PictureDecoration"; "picField"="PictureField"; "calendar"="CalendarField"; "cmdBar"="CommandBar"; "popup"="Popup"
}

# Может ли элемент типа $nt лечь в $container. $node — переносимый узел (у добавления $null).
function Assert-Placement([string]$nt, [string]$name, $node, $container, [string]$ctx) {
	$isRoot = Same $container $root
	$ct = if ($isRoot) { "Form" } else { $container.LocalName }
	$cl = Get-ContainerLabel $container
	if (-not $isRoot -and $script:containerTags -notcontains $ct) { Fail "${ctx}: '$cl' ($ct) не контейнер — в него нельзя положить элемент" }
	if ($null -ne $node -and (Test-IsInside $container $node)) { Fail "${ctx}: '$name' нельзя перенести внутрь самого себя — '$cl' лежит внутри '$name'" }
	if ($nt -eq 'Page' -and $ct -ne 'Pages') { Fail "${ctx}: страница '$name' может лежать только в группе страниц (Pages), а '$cl' — $ct" }
	if ($ct -eq 'Pages' -and $nt -ne 'Page') { Fail "${ctx}: в группе страниц '$cl' лежат только страницы (Page), а '$name' — $nt" }
	if ($script:barTags -contains $ct -and $script:barItemTags -notcontains $nt -and $script:additionTags -notcontains $nt) { Fail "${ctx}: в командной панели '$cl' лежат только кнопки, группы кнопок, подменю и дополнения таблицы, а '$name' — $nt" }
	# Группа кнопок и подменю — только внутри командной панели, меню, подменю или группы кнопок (по корпусу)
	if (@('ButtonGroup','Popup') -contains $nt -and $script:barTags -notcontains $ct) { Fail "${ctx}: '$name' ($nt) лежит только в командной панели, контекстном меню, подменю или группе кнопок, а '$cl' — $ct" }
	if ($nt -eq 'ColumnGroup' -and $null -eq (Get-NearestTable $container $true)) { Fail "${ctx}: группа колонок '$name' может лежать только внутри таблицы" }
	# Колонки таблицы — только поля и группы колонок (по корпусу других типов там нет);
	# командная панель и контекстное меню таблицы — свои правила выше.
	$inTable = if ($isRoot) { $null } else { Get-NearestTable $container $true }
	if ($null -ne $inTable -and $script:barTags -notcontains $ct -and $script:tableItemTags -notcontains $nt) {
		Fail "${ctx}: в таблице '$($inTable.GetAttribute('name'))' лежат только колонки (поля и группы колонок), а '$name' — $nt"
	}
	# Граница таблицы: колонки и поля табличной части привязаны к своей таблице. Кнопки — нет
	# (стандартная команда таблицы законно стоит и в командной панели формы).
	if ($null -ne $node -and $script:barItemTags -notcontains $nt) {
		$from = Get-NearestTable $node $false
		$to = if ($isRoot) { $null } else { Get-NearestTable $container $true }
		if (-not (Same $from $to)) {
			if ($null -ne $from) { Fail "${ctx}: '$name' принадлежит таблице '$($from.GetAttribute('name'))' — вынести его за её пределы или в другую таблицу нельзя" }
			Fail "${ctx}: '$name' не принадлежит таблице — внутрь таблицы '$($to.GetAttribute('name'))' его перенести нельзя"
		}
	}
}

function Assert-OpKeys($op, [string[]]$allowed, [string]$ctx) {
	foreach ($p in $op.PSObject.Properties) {
		if ($allowed -notcontains $p.Name) { Fail "${ctx}: неизвестный ключ '$($p.Name)'; допустимы: $($allowed -join ', ')" }
	}
}

# --- Добавление ---

$script:chainNode = $null
$script:defaultPos = $null

function Invoke-Add($op, [string]$typeKey, [int]$idx) {
	$name = Get-ElementName -el $op -typeKey $typeKey
	$ctx = "elements[$idx] $typeKey '$name'"
	# Имя уже есть в форме — на момент этой операции (удалённое раньше в списке — свободно)
	$existing = Find-FormElement $name
	if ($null -ne $existing) {
		Write-Host "[ERROR] Element '$name' already exists in form (id=$($existing.GetAttribute('id'))) — element names must be unique"
		exit 1
	}
	$pos = Resolve-Position $op $ctx $false
	if ($null -eq $pos) {
		# Без своей позиции — как раньше: верхние into/after, следующие встают за предыдущим.
		if ($null -ne $script:chainNode) {
			$c = $script:chainNode.ParentNode.ParentNode
			$pos = @{ Container = $c; Ref = (Get-NextElementSibling $script:chainNode); Anchor = $null; Desc = "$(Get-ContainerLabel $c), после $($script:chainNode.GetAttribute('name'))" }
		} else {
			if ($null -eq $script:defaultPos) {
				$script:defaultPos = Resolve-Position $def "elements (верхние into/after)" $false
				if ($null -eq $script:defaultPos) { $script:defaultPos = @{ Container = $root; Ref = $null; Anchor = $null; Desc = "корень формы, в конец" } }
			}
			$pos = $script:defaultPos
		}
		$chained = $true
	} else {
		$chained = $false
	}
	Assert-Placement $script:dslTagMap[$typeKey] $name $null $pos.Container $ctx

	# Эмиттеру — копия элемента без ключей позиции (это не свойства элемента)
	$el = ($op | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json) | Select-Object -Property * -ExcludeProperty into, after, before, first
	Normalize-ElementSynonyms $el
	# Таблица динамического списка получает поведение списка, как в form-compile
	foreach ($a in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
		$t = $a.SelectSingleNode("f:Type/v8:Type", $nsMgr)
		if ($null -ne $t -and $t.InnerText.Trim() -eq 'cfg:DynamicList') { ApplyDynamicListTableHeuristic $el $a.GetAttribute('name') $true }
	}
	# Пул имён эмиттера — имена элементов формы на момент операции (без узлов событий)
	$script:seenElementNames = @{}
	foreach ($sc in (Get-ElementScopes)) {
		foreach ($n in $sc.SelectNodes(".//*[@name]")) {
			if ($n.NamespaceURI -eq $formNs -and ($n.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $n.LocalName)) {
				$script:seenElementNames[$n.GetAttribute('name')] = $true
			}
		}
	}
	$script:currentTableName = $null
	# Дополнение таблицы: источник — source или таблица, внутри которой оно лежит
	if ($script:additionTags -contains $script:dslTagMap[$typeKey]) {
		if ($el.source) {
			$src = Find-FormElement "$($el.source)"
			if ($null -eq $src -or $src.LocalName -ne 'Table') { Fail "${ctx}: source '$($el.source)' — нет такой таблицы в форме" }
			$el.source = $src.GetAttribute('name')
		} else {
			$tbl = if (Same $pos.Container $root) { $null } else { Get-NearestTable $pos.Container $true }
			if ($null -eq $tbl) { Fail "${ctx}: укажите source — таблицу, к которой относится дополнение" }
			$script:currentTableName = $tbl.GetAttribute('name')
		}
	}

	$ci = Get-OrCreateChildItems $pos.Container
	$indent = Get-ChildIndent $ci
	$script:xml = New-Object System.Text.StringBuilder 4096
	# Внутри командной панели, меню, подменю или группы кнопок кнопка — кнопка панели
	$inBar = $false
	$cur = $pos.Container
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($script:barTags -contains $cur.LocalName) { $inBar = $true; break }
		$cur = $cur.ParentNode
	}
	X "<_F $allNsDecl>"
	Emit-Element -el $el -indent $indent -inCmdBar $inBar
	X "</_F>"
	$node = @(Import-ElementNodes (Parse-Fragment (Sort-ElementTagOrder (Normalize-EnumTags $script:xml.ToString()))))[0]
	Insert-NodeAt $ci $node $pos.Ref $indent
	if ($chained) { $script:chainNode = $node }

	$pathStr = if ($op.path) { " -> $($op.path)" } else { "" }
	$evtNames = @($node.SelectNodes("f:Events/f:Event", $nsMgr) | ForEach-Object { $_.GetAttribute('name') })
	$evtStr = if ($evtNames.Count -gt 0) { " {$($evtNames -join ', ')}" } else { "" }
	$script:opLog += "  + [$($node.LocalName)] $name$pathStr$evtStr → $($pos.Desc)"
	$script:addedCount++
}

# --- Командная панель формы (autoCmdBar, как в form-compile) ---

# Кнопки из children — в командную панель формы (в конец, по порядку); autofill и horizontalAlign — её свойства.
function Invoke-AutoCmdBar($op, [int]$idx) {
	$ctx = "elements[$idx] autoCmdBar"
	$acbNode = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($null -eq $acbNode) { Fail "${ctx}: у формы нет командной панели" }
	Assert-OpKeys $op @('autoCmdBar','children','autofill','horizontalAlign') $ctx
	if ($null -ne $op.PSObject.Properties['autofill']) {
		if (-not ($op.autofill -is [bool])) { Fail "${ctx}: autofill — true или false" }
		Set-ValueTag $acbNode 'Autofill' $(if ($op.autofill) { 'true' } else { 'false' })
		$script:opLog += "  * $($acbNode.GetAttribute('name')): autofill=$($op.autofill.ToString().ToLower()) → Autofill"
		$script:changedCount++
	}
	if ($op.horizontalAlign) {
		Set-SimpleTag $acbNode 'HorizontalAlign' "$($op.horizontalAlign)"
		$script:opLog += "  * $($acbNode.GetAttribute('name')): horizontalAlign=$($op.horizontalAlign) → HorizontalAlign"
		$script:changedCount++
	}
	foreach ($child in @($op.children)) {
		if ($null -eq $child) { continue }
		if (-not ($child -is [System.Management.Automation.PSCustomObject])) { Fail "${ctx}: в children — не элемент (нужна кнопка, группа кнопок или подменю)" }
		foreach ($pk in @('into','after','before','first')) {
			if ($null -ne $child.PSObject.Properties[$pk]) { Fail "${ctx}: у кнопок в children нет позиции — они встают в конец панели по порядку; для места укажите кнопку отдельным элементом с into и after/before" }
		}
		Normalize-ElementTypeSynonyms $child
		$tk = $null
		foreach ($k in $elemTypeKeys) { if ($null -ne $child.PSObject.Properties[$k]) { $tk = $k; break } }
		if ($null -eq $tk) { Fail "${ctx}: в children — не элемент (нужна кнопка, группа кнопок или подменю)" }
		$c = $child | Select-Object -Property *
		$c | Add-Member -NotePropertyName 'into' -NotePropertyValue $acbNode.GetAttribute('name') -Force
		Invoke-Add $c $tk $idx
	}
}

# --- Перенос ---

function Invoke-Move($op, [int]$idx) {
	$ctx = "elements[$idx] move"
	Assert-OpKeys $op @('move','after','before','into','first') $ctx
	$names = @(@($op.move) | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($names.Count -eq 0) { Fail "${ctx}: укажи имя элемента или список имён" }
	$nodes = @()
	$seen = @{}
	foreach ($n in $names) {
		if ($seen.ContainsKey($n)) { Fail "${ctx}: '$n' указан дважды" }
		$seen[$n] = $true
		$node = Find-FormElement $n
		if ($null -eq $node) { Fail "${ctx}: элемент '$n' не найден в форме" }
		if ($node.ParentNode.LocalName -ne 'ChildItems' -or $script:companionTags -contains $node.LocalName) {
			Fail "${ctx}: '$n' — служебный узел ($($node.LocalName)) своего элемента, переносится только вместе с ним"
		}
		$nodes += $node
	}
	$pos = Resolve-Position $op $ctx $true
	foreach ($node in $nodes) {
		if (Same $node $pos.Anchor) { Fail "${ctx}: '$($node.GetAttribute('name'))' не может быть якорем собственного переноса" }
		Assert-Placement $node.LocalName $node.GetAttribute('name') $node $pos.Container $ctx
	}

	$ref = $pos.Ref
	$desc = $pos.Desc
	$prev = $null
	foreach ($node in $nodes) {
		$name = $node.GetAttribute('name')
		if ($null -ne $prev) {
			$ref = Get-NextElementSibling $prev
			$desc = "$(Get-ContainerLabel $pos.Container), после $($prev.GetAttribute('name'))"
		}
		$fromCI = $node.ParentNode
		$targetCI = $pos.Container.SelectSingleNode("f:ChildItems", $nsMgr)
		if ((Same $fromCI $targetCI) -and ((Same $ref $node) -or (Same $ref (Get-NextElementSibling $node)))) {
			$script:opLog += "  = ${name}: уже на месте ($desc)"
			$prev = $node
			continue
		}
		$fromLabel = Get-ContainerLabel $fromCI.ParentNode
		# Отступ цели — до отцепления: если узел был в ней единственным, после отцепления
		# первым пробельным узлом окажется закрывающий с отступом родителя.
		$newIndent = if ($null -ne $targetCI) { Get-ChildIndent $targetCI } else { $null }
		$oldIndent = Get-NodeIndent $node
		Remove-NodeWithWs $node
		$ci = Get-OrCreateChildItems $pos.Container
		if ($null -eq $newIndent) { $newIndent = Get-ChildIndent $ci }
		Insert-NodeAt $ci $node $ref $newIndent
		Set-SubtreeIndent $node $oldIndent $newIndent
		if (-not (Same $fromCI $ci)) { Remove-IfEmptyChildItems $fromCI }
		$script:opLog += "  ~ ${name}: $fromLabel → $desc"
		$script:movedCount++
		$prev = $node
	}
}

# --- Изменение свойств ---

# Умолчания платформы: в корпусе эти теги встречаются только с противоположным значением —
# значение по умолчанию платформа не пишет, и set его не пишет, а убирает тег.
$script:tagDefaults = @{
	'Visible'='true'; 'Enabled'='true'; 'ReadOnly'='false'; 'ShowTitle'='true'; 'United'='true'; 'Collapsed'='false'
	'AutoMaxWidth'='true'; 'AutoMaxHeight'='true'; 'Hyperlink'='false'; 'Hiperlink'='false'
}
# Умолчания перечислений зависят от типа элемента: значение из области, которого в корпусе нет ни
# разу у этого типа (у таблицы TitleLocation=Auto пишется явно — там правило не действует).
$script:enumDefaults = @{
	'UsualGroup/Group'='HorizontalIfPossible'; 'Page/Group'='Vertical'; 'ColumnGroup/Group'='Vertical'
	'UsualGroup/Representation'='WeakSeparation'; 'Button/Representation'='Auto'; 'Popup/Representation'='Auto'
	'AutoCommandBar/Autofill'='true'
}

function Get-TagDefault([string]$nt, [string]$tag) {
	if ($script:tagDefaults.ContainsKey($tag)) { return $script:tagDefaults[$tag] }
	if ($script:enumDefaults.ContainsKey("$nt/$tag")) { return $script:enumDefaults["$nt/$tag"] }
	if ($script:enumDefaultValues.ContainsKey("$nt.$tag")) { return $script:enumDefaultValues["$nt.$tag"] }
	if ($tag -eq 'TitleLocation' -and $nt -ne 'Table') { return 'Auto' }
	return $null
}

# Значение по умолчанию платформа не пишет — и set его не пишет, а убирает тег.
# Значение перечисления — к виду платформы (как эмиттер: Normalize-EnumValue по типу элемента)
function Get-NormalizedEnumValue($node, [string]$tag, [string]$text) {
	if (-not $text -or -not $script:childTagOrder.ContainsKey($node.LocalName)) { return $text }
	$script:objType = $node.LocalName
	return (Normalize-EnumValue $tag $text)
}

function Set-ValueTag($node, [string]$tag, [string]$text) {
	$text = Get-NormalizedEnumValue $node $tag $text
	if ((Get-TagDefault $node.LocalName $tag) -ceq $text) {
		$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
		if ($null -ne $existing) { Remove-NodeWithWs $existing }
		return
	}
	Set-SimpleTag $node $tag $text
}

$script:titleLocMap = @{ 'none'='None'; 'left'='Left'; 'right'='Right'; 'top'='Top'; 'bottom'='Bottom'; 'auto'='Auto' }
# Ключи — словарь form-compile; Tags — кандидаты по типу элемента (у LabelField платформа пишет Hiperlink).
$script:setProps = [ordered]@{
	'title'=@{ Tags=@('Title'); Kind='ml' }
	'tooltip'=@{ Tags=@('ToolTip'); Kind='ml' }
	'inputHint'=@{ Tags=@('InputHint'); Kind='ml' }
	'visible'=@{ Tags=@('Visible'); Kind='bool' }
	'hidden'=@{ Tags=@('Visible'); Kind='bool'; Invert=$true }
	'enabled'=@{ Tags=@('Enabled'); Kind='bool' }
	'disabled'=@{ Tags=@('Enabled'); Kind='bool'; Invert=$true }
	'readOnly'=@{ Tags=@('ReadOnly'); Kind='bool' }
	'skipOnInput'=@{ Tags=@('SkipOnInput'); Kind='bool' }
	'titleLocation'=@{ Tags=@('TitleLocation'); Kind='enum'; Map=$script:titleLocMap }
	'width'=@{ Tags=@('Width'); Kind='num' }
	'height'=@{ Tags=@('HeightInTableRows','Height'); Kind='num' }
	'maxWidth'=@{ Tags=@('MaxWidth'); Kind='num' }
	'maxHeight'=@{ Tags=@('MaxHeight'); Kind='num' }
	'autoMaxWidth'=@{ Tags=@('AutoMaxWidth'); Kind='bool' }
	'autoMaxHeight'=@{ Tags=@('AutoMaxHeight'); Kind='bool' }
	'horizontalStretch'=@{ Tags=@('HorizontalStretch'); Kind='bool' }
	'verticalStretch'=@{ Tags=@('VerticalStretch'); Kind='bool' }
	'multiLine'=@{ Tags=@('MultiLine'); Kind='bool' }
	'passwordMode'=@{ Tags=@('PasswordMode'); Kind='bool' }
	'choiceButton'=@{ Tags=@('ChoiceButton'); Kind='bool' }
	'clearButton'=@{ Tags=@('ClearButton'); Kind='bool' }
	'spinButton'=@{ Tags=@('SpinButton'); Kind='bool' }
	'dropListButton'=@{ Tags=@('DropListButton'); Kind='bool' }
	'markIncomplete'=@{ Tags=@('AutoMarkIncomplete'); Kind='bool' }
	'hyperlink'=@{ Tags=@('Hyperlink','Hiperlink'); Kind='bool' }
	'group'=@{ Tags=@('Group'); Kind='enum'; Map=@{ 'vertical'='Vertical'; 'horizontal'='Horizontal'; 'horizontalifpossible'='HorizontalIfPossible'; 'alwayshorizontal'='AlwaysHorizontal'; 'alwaysvertical'='Vertical'; 'incell'='InCell' } }
	'behavior'=@{ Tags=@('Behavior'); Kind='enum'; Map=@{ 'usual'='Usual'; 'collapsible'='Collapsible'; 'popup'='PopUp' } }
	'collapsed'=@{ Tags=@('Collapsed'); Kind='bool' }
	'representation'=@{ Tags=@('Representation'); Kind='repr' }
	'showTitle'=@{ Tags=@('ShowTitle'); Kind='bool' }
	'united'=@{ Tags=@('United'); Kind='bool' }
}
# Значения Representation — свои у каждого типа (по корпусу); ключи — как в form-compile.
$script:reprMaps = @{
	'UsualGroup' = @{ 'none'='None'; 'normal'='NormalSeparation'; 'weak'='WeakSeparation'; 'strong'='StrongSeparation' }
	'Table' = @{ 'list'='List'; 'tree'='Tree'; 'hierarchicallist'='HierarchicalList' }
	'Button' = @{ 'auto'='Auto'; 'text'='Text'; 'picture'='Picture'; 'pictureandtext'='PictureAndText' }
	'Popup' = @{ 'auto'='Auto'; 'text'='Text'; 'picture'='Picture'; 'pictureandtext'='PictureAndText' }
	'ButtonGroup' = @{ 'usual'='Usual'; 'compact'='Compact' }
}
$script:xmlTagToDsl = @{}
foreach ($k in $script:dslTagMap.Keys) { $script:xmlTagToDsl[$script:dslTagMap[$k]] = $k }

function Get-PropTag($spec, [string]$nt) {
	foreach ($t in $spec.Tags) { if ((Get-ChildRank $nt $t) -ge 0) { return $t } }
	return $null
}

function Get-ApplicableSetKeys([string]$nt) {
	$keys = @()
	foreach ($k in $script:setProps.Keys) {
		if ($k -in @('hidden','disabled')) { continue }
		if ($null -ne (Get-PropTag $script:setProps[$k] $nt)) { $keys += $k }
	}
	if ((Get-ChildRank $nt 'Events') -ge 0) { $keys += 'on' }
	return $keys
}

function Set-SimpleTag($node, [string]$tag, [string]$text) {
	$text = Get-NormalizedEnumValue $node $tag $text
	$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
	if ($null -ne $existing) { $existing.InnerText = $text; return }
	$el = $xmlDoc.CreateElement($tag, $formNs)
	$el.InnerText = $text
	Insert-ChildCanonical $node $el
}

function Set-MLTag($node, [string]$tag, $value) {
	$indent = Get-ChildIndent $node
	$script:xml = New-Object System.Text.StringBuilder 512
	X "<_F $allNsDecl>"
	X "$indent<$tag>"
	if ($value -is [string]) {
		# Строка меняет только русский текст: переводы на другие языки остаются как были
		$items = @()
		$prevEl = $node.SelectSingleNode("f:$tag", $nsMgr)
		$hasRu = $false
		if ($null -ne $prevEl) {
			foreach ($it in $prevEl.SelectNodes("v8:item", $nsMgr)) {
				$lang = $it.SelectSingleNode("v8:lang", $nsMgr).InnerText
				if ($lang -eq 'ru') { $items += @{ Lang = 'ru'; Text = $value }; $hasRu = $true }
				else { $items += @{ Lang = $lang; Text = $it.SelectSingleNode("v8:content", $nsMgr).InnerText } }
			}
		}
		if (-not $hasRu) { $items = @(@{ Lang = 'ru'; Text = $value }) + $items }
	} else {
		$items = @($value.PSObject.Properties | ForEach-Object { @{ Lang = $_.Name; Text = "$($_.Value)" } })
	}
	foreach ($it in $items) {
		X "$indent`t<v8:item>"
		X "$indent`t`t<v8:lang>$($it.Lang)</v8:lang>"
		X "$indent`t`t<v8:content>$(Esc-XmlText $it.Text)</v8:content>"
		X "$indent`t</v8:item>"
	}
	X "$indent</$tag>"
	X "</_F>"
	$newEl = @(Import-ElementNodes (Parse-Fragment $script:xml.ToString()))[0]
	$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
	if ($null -ne $existing) {
		# Атрибуты узла (formatted у заголовка надписи) переживают замену текста
		foreach ($a in @($existing.Attributes)) { $newEl.SetAttribute($a.LocalName, $a.Value) }
		$node.ReplaceChild($newEl, $existing) | Out-Null
		return
	}
	if ($tag -eq 'Title' -and $node.LocalName -eq 'LabelDecoration') { $newEl.SetAttribute('formatted', 'false') }
	Insert-ChildCanonical $node $newEl
}

function Add-ElementEvents($node, $on, $handlers, [string]$ctx) {
	$nt = $node.LocalName
	$name = $node.GetAttribute('name')
	if ((Get-ChildRank $nt 'Events') -lt 0) { Fail "${ctx}: у $nt '$name' событий нет" }
	$dsl = $script:xmlTagToDsl[$nt]
	$allowed = if ($dsl -and $script:knownEvents.ContainsKey($dsl)) { $script:knownEvents[$dsl] } else { @() }
	$events = $node.SelectSingleNode("f:Events", $nsMgr)
	foreach ($evt in @($on)) {
		if ($evt -is [string] -or -not $evt.event) {
			$evtName = "$evt"; $callType = ""
			$handler = if ($handlers -and $handlers.$evtName) { "$($handlers.$evtName)" } else { Get-HandlerName -elementName $name -eventName $evtName }
		} else {
			$evtName = "$($evt.event)"; $callType = Normalize-CallType "$($evt.callType)" $name $evtName
			$handler = if ($evt.handler) { "$($evt.handler)" } elseif ($handlers -and $handlers.$evtName) { "$($handlers.$evtName)" } else { Get-HandlerName -elementName $name -eventName $evtName }
		}
		# В форме расширения обработчик без callType платформа читает как Before и так и пишет
		if (-not $callType -and $script:isExtension) { $callType = 'Before' }
		if ($allowed.Count -gt 0 -and $allowed -notcontains $evtName) {
			Write-Host "[WARN] Unknown event '$evtName' for $dsl '$name'. Known: $($allowed -join ', ')"
		}
		$ctStr = if ($callType) { "[$callType]" } else { "" }
		if ($null -ne $events) {
			$dup = $null
			foreach ($e in $events.SelectNodes("f:Event", $nsMgr)) {
				if ($e.GetAttribute('name') -eq $evtName -and $e.GetAttribute('callType') -eq $callType) { $dup = $e; break }
			}
			if ($null -ne $dup) {
				if ($dup.InnerText -eq $handler) { $script:opLog += "  = ${name}: событие $evtName$ctStr -> $handler уже есть"; continue }
				Fail "${ctx}: у '$name' событие $evtName$ctStr уже обрабатывает '$($dup.InnerText)' — второй обработчик не повесить"
			}
		}
		if ($null -eq $events) {
			$events = $xmlDoc.CreateElement("Events", $formNs)
			Insert-ChildCanonical $node $events
		}
		$ev = $xmlDoc.CreateElement("Event", $formNs)
		$ev.SetAttribute('name', $evtName)
		if ($callType) { $ev.SetAttribute('callType', $callType) }
		$ev.InnerText = $handler
		Insert-NodeAt $events $ev $null (Get-ChildIndent $events)
		$script:opLog += "  * ${name}: событие $evtName$ctStr -> $handler"
		$script:changedCount++
	}
}

function Invoke-Set($op, [int]$idx) {
	$ctx = "elements[$idx] set"
	$names = @(@($op.set) | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($names.Count -eq 0) { Fail "${ctx}: укажи имя элемента или список имён" }
	$props = @($op.PSObject.Properties | Where-Object { $_.Name -ne 'set' })
	if ($props.Count -eq 0) { Fail "${ctx}: не указано, что менять" }
	$forbidden = @('name','path','children','columns')
	foreach ($n in $names) {
		$node = Find-FormElement $n
		if ($null -eq $node) { Fail "${ctx}: элемент '$n' не найден в форме" }
		$nt = $node.LocalName
		$c = "$ctx '$n'"
		$probeProps = [ordered]@{}
		foreach ($p in $props) {
			$key = $p.Name
			if ($key -eq 'handlers') { if (-not $op.on) { Fail "${c}: handlers задаются вместе с on" }; continue }
			if ($key -eq 'on') { Add-ElementEvents $node $p.Value $op.handlers $c; continue }
			if ($key -eq 'events') {
				if (-not ($p.Value -is [System.Management.Automation.PSCustomObject])) { Fail "${c}: events — объект { Событие: обработчик }" }
				$on = @(Get-EventPairs -el $op -elementName $n | ForEach-Object { [pscustomobject]@{ event = $_.name; handler = $_.handler; callType = $_.callType } })
				Add-ElementEvents $node $on $null $c
				continue
			}
			if ($forbidden -contains $key -or ($key -eq $script:xmlTagToDsl[$nt] -and $key -ne 'group')) {
				Fail "${c}: '$key' через set не меняется (имя и привязку не трогаем — на них ссылаются модуль и расширения; состав — через move)"
			}
			if (@('into','after','before','first') -contains $key) { Fail "${c}: '$key' — место элемента меняет move, не set" }
			if (-not $script:setProps.Contains($key)) {
				# Остальные ключи элемента — как в form-compile, через общий эмиттер
				$probeProps[$key] = $p.Value
				continue
			}
			$spec = $script:setProps[$key]
			$tag = Get-PropTag $spec $nt
			if ($null -eq $tag) { Fail "${c}: свойство '$key' к $nt не применимо; доступно: $((Get-ApplicableSetKeys $nt) -join ', ') и остальные ключи элемента из form-compile" }
			$v = $p.Value
			if ($null -eq $v) {
				$existing = $node.SelectSingleNode("f:$tag", $nsMgr)
				if ($null -ne $existing) { Remove-NodeWithWs $existing }
				$script:opLog += "  * ${n}: $key сброшено"
				$script:changedCount++
				continue
			}
			switch ($spec.Kind) {
				'ml' {
					$mlOk = ($v -is [string]) -or (($v -is [System.Management.Automation.PSCustomObject]) -and @($v.PSObject.Properties).Count -gt 0 -and -not (@($v.PSObject.Properties) | Where-Object { -not ($_.Value -is [string]) }))
					if (-not $mlOk) { Fail "${c}: $key — строка или объект {ru, en, ...} со строковыми значениями" }
					Set-MLTag $node $tag $v
					$shown = if ($v -is [string]) { $v } else { ($v.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' ' }
					$script:opLog += "  * ${n}: $key=`"$shown`" → $tag"
				}
				'bool' {
					if (-not ($v -is [bool])) { Fail "${c}: $key — true или false" }
					if ($spec.Invert) { $v = -not $v }
					$text = if ($v) { 'true' } else { 'false' }
					Set-ValueTag $node $tag $text
					$script:opLog += "  * ${n}: $key=$("$($p.Value)".ToLower()) → $tag=$text"
				}
				'num' {
					if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 0) { Fail "${c}: $key — целое неотрицательное число" }
					Set-SimpleTag $node $tag "$v"
					$script:opLog += "  * ${n}: $key=$v → $tag=$v"
				}
				'enum' {
					$mapped = $spec.Map["$v".ToLower()]
					if (-not $mapped) { Fail "${c}: $key='$v' — допустимо: $(($spec.Map.Keys | Sort-Object) -join ', ')" }
					Set-ValueTag $node $tag $mapped
					$script:opLog += "  * ${n}: $key=$v → $tag=$mapped"
				}
				'repr' {
					$rmap = $script:reprMaps[$nt]
					if ($null -eq $rmap) { Fail "${c}: свойство '$key' к $nt не применимо; доступно: $((Get-ApplicableSetKeys $nt) -join ', ') и остальные ключи элемента из form-compile" }
					$text = $rmap["$v".ToLower()]
					if (-not $text) { Fail "${c}: representation='$v' — допустимо: $(($rmap.Keys | Sort-Object) -join ', ')" }
					Set-ValueTag $node $tag $text
					$script:opLog += "  * ${n}: $key=$v → $tag=$text"
				}
			}
			$script:changedCount++
		}
		if ($probeProps.Count -gt 0) {
			# Контекст пробы — все свойства операции: от них зависит, как эмиттер пишет остальные
			$context = [ordered]@{}
			foreach ($p in $props) {
				if (@('on','handlers','events') -notcontains $p.Name -and $null -ne $p.Value -and -not $probeProps.Contains($p.Name)) { $context[$p.Name] = $p.Value }
			}
			Invoke-SetByEmitter $node $probeProps $context $op $c
		}
	}
}

# --- set: ключи элемента вне таблицы выше — через общий эмиттер form-compile ---
# Элемент эмитится без свойства и с ним; что различается, то свойство и пишет в XML. Так set знает
# все ключи form-compile и пишет их ровно так же, как при создании формы.

$script:probeTypeValues = @{ 'group'='vertical'; 'columnGroup'='vertical' }

function Invoke-SetProbe($node, $props) {
	$nt = $node.LocalName
	$dsl = $script:xmlTagToDsl[$nt]
	$name = $node.GetAttribute('name')
	$h = [ordered]@{}
	$h[$dsl] = if ($script:probeTypeValues.ContainsKey($dsl)) { $script:probeTypeValues[$dsl] } else { $name }
	$h['name'] = $name
	$dp = $node.SelectSingleNode("f:DataPath", $nsMgr)
	if ($null -ne $dp) { $h['path'] = $dp.InnerText }
	foreach ($k in $props.Keys) { $h[$k] = $props[$k] }
	$el = [pscustomobject]$h | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json
	Normalize-ElementSynonyms $el
	foreach ($a in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
		$t = $a.SelectSingleNode("f:Type/v8:Type", $nsMgr)
		if ($null -ne $t -and $t.InnerText.Trim() -eq 'cfg:DynamicList') { ApplyDynamicListTableHeuristic $el $a.GetAttribute('name') $true }
	}
	$saveId = $script:nextElemId
	$script:seenElementNames = @{}
	$tbl = Get-NearestTable $node $false
	$script:currentTableName = if ($null -ne $tbl) { $tbl.GetAttribute('name') } else { $null }
	$inBar = $false
	$cur = $node.ParentNode
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($script:barTags -contains $cur.LocalName) { $inBar = $true; break }
		$cur = $cur.ParentNode
	}
	$script:xml = New-Object System.Text.StringBuilder 4096
	X "<_F $allNsDecl>"
	$msgs = @(& { Emit-Element -el $el -indent (Get-NodeIndent $node) -inCmdBar $inBar } 3>&1 6>&1 |
		Where-Object { $_ -is [System.Management.Automation.WarningRecord] -or $_ -is [System.Management.Automation.InformationRecord] } |
		ForEach-Object { "$_" })
	X "</_F>"
	$script:nextElemId = $saveId
	$frag = Parse-Fragment (Sort-ElementTagOrder (Normalize-EnumTags $script:xml.ToString() '' $true))
	$pe = $null
	foreach ($ch in $frag.DocumentElement.ChildNodes) { if ($ch.NodeType -eq 'Element') { $pe = $ch; break } }
	return @{ El = $pe; Messages = $msgs }
}

# Свойства узла: дочерние теги (без состава и событий) и атрибуты; спутники (меню, подсказка,
# панель) — отдельно, их свойства сравниваются так же.
function Get-ProbeParts($e) {
	$tags = [ordered]@{}; $comps = @{}; $attrs = @{}
	foreach ($ch in $e.ChildNodes) {
		if ($ch.NodeType -ne 'Element') { continue }
		$ln = $ch.LocalName
		if ($ln -eq 'Events') { continue }
		if ($ln -eq 'ChildItems') { $comps['#items'] = ($ch.OuterXml -replace ' id="-?\d+"', '') -replace '\s+', ' '; continue }
		if ($script:companionTags -contains $ln -and $ch.HasAttribute('name')) { $comps[$ln] = $ch; continue }
		$t = ($ch.OuterXml -replace ' id="-?\d+"', '') -replace '\s+', ' '
		if ($tags.Contains($ln)) { $tags[$ln] += $t } else { $tags[$ln] = $t }
	}
	foreach ($a in $e.Attributes) {
		if ($a.Name -ne 'name' -and $a.Name -ne 'id' -and -not $a.Name.StartsWith('xmlns')) { $attrs[$a.Name] = $a.Value }
	}
	return @{ Tags = $tags; Comps = $comps; Attrs = $attrs }
}

function Get-ProbeDiff($b, $p) {
	$pb = Get-ProbeParts $b; $pp = Get-ProbeParts $p
	$d = @{ Tags = @(); Attrs = @(); Comps = @(); Items = $false }
	foreach ($t in @($pb.Tags.Keys) + @($pp.Tags.Keys) | Select-Object -Unique) {
		if ($pb.Tags[$t] -cne $pp.Tags[$t]) { $d.Tags += $t }
	}
	foreach ($a in @($pb.Attrs.Keys) + @($pp.Attrs.Keys) | Sort-Object -Unique) {
		if ($pb.Attrs[$a] -cne $pp.Attrs[$a]) { $d.Attrs += $a }
	}
	if ($pb.Comps['#items'] -cne $pp.Comps['#items']) { $d.Items = $true }
	foreach ($cn in @($pp.Comps.Keys | Where-Object { $_ -ne '#items' } | Sort-Object)) {
		if ($null -eq $pb.Comps[$cn]) { continue }
		$sub = Get-ProbeDiff $pb.Comps[$cn] $pp.Comps[$cn]
		# Состав спутника (кнопки меню, панели) — тоже состав
		if ($sub.Items) { $d.Items = $true }
		if (Test-ProbeDiff $sub) { $d.Comps += @{ Tag = $cn; Diff = $sub } }
	}
	return $d
}

function Test-ProbeDiff($d) {
	return ($d.Tags.Count + $d.Attrs.Count + $d.Comps.Count) -gt 0 -or $d.Items
}

# Есть ли в узле хоть что-то из того, что описывает разница (для сброса к умолчанию).
function Test-ProbeDiffPresent($target, $d) {
	foreach ($t in $d.Tags) { if ($null -ne $target.SelectSingleNode("f:$t", $nsMgr)) { return $true } }
	foreach ($a in $d.Attrs) { if ($target.HasAttribute($a)) { return $true } }
	foreach ($cd in $d.Comps) {
		$tc = $target.SelectSingleNode("f:$($cd.Tag)", $nsMgr)
		if ($null -ne $tc -and (Test-ProbeDiffPresent $tc $cd.Diff)) { return $true }
	}
	return $false
}

function Get-ProbeDiffLabel($d) {
	$parts = @($d.Tags) + @($d.Attrs | ForEach-Object { "@$_" })
	foreach ($cd in $d.Comps) { $parts += @(Get-ProbeDiffLabel $cd.Diff | ForEach-Object { "$($cd.Tag)/$_" }) }
	return $parts
}

# Перенести в узел то, что различается: теги пробы заменяют свои (нет в пробе — тег убирается).
function Apply-ProbeDiff($target, $probeEl, $d, [bool]$removeOnly) {
	foreach ($t in $d.Tags) {
		foreach ($x in @($target.SelectNodes("f:$t", $nsMgr))) { Remove-NodeWithWs $x }
		if ($removeOnly) { continue }
		foreach ($pn in @($probeEl.SelectNodes("f:$t", $nsMgr))) {
			$imp = $xmlDoc.ImportNode($pn, $true)
			if ((Get-ChildRank $target.LocalName $t) -ge 0) { Insert-ChildCanonical $target $imp; continue }
			# Тега нет в корпусном порядке — встаёт перед первым следующим за ним в пробе тегом узла
			$ref = $null
			$sib = $pn.NextSibling
			while ($null -ne $sib -and $null -eq $ref) {
				if ($sib.NodeType -eq 'Element') { $ref = $target.SelectSingleNode("f:$($sib.LocalName)", $nsMgr) }
				$sib = $sib.NextSibling
			}
			Insert-NodeAt $target $imp $ref (Get-ChildIndent $target)
		}
	}
	foreach ($a in $d.Attrs) {
		if (-not $removeOnly -and $probeEl.HasAttribute($a)) { $target.SetAttribute($a, $probeEl.GetAttribute($a)) }
		else { $target.RemoveAttribute($a) }
	}
	foreach ($cd in $d.Comps) {
		$tc = $target.SelectSingleNode("f:$($cd.Tag)", $nsMgr)
		$pc = if ($null -ne $probeEl) { $probeEl.SelectSingleNode("f:$($cd.Tag)", $nsMgr) } else { $null }
		if ($null -ne $tc) { Apply-ProbeDiff $tc $pc $cd.Diff $removeOnly }
		elseif (-not $removeOnly) { Fail "у '$($target.GetAttribute('name'))' нет $($cd.Tag) — свойство некуда записать" }
	}
}

function Get-ProbeOwnerTags([string]$key) {
	foreach ($g in $script:genericScalars) { if ($g.Key -eq $key) { return @($g.Tag) } }
	if ($script:appearanceSpec.ContainsKey($key)) { return @($script:appearanceSpec[$key].tag) }
	return @()
}

# Теги, которые set через эмиттер не трогает: привязка и тип. Теги ручной таблицы (Title, ToolTip…)
# проба переписывает, только если их ключ задан в той же операции, — иначе эмиттер, не зная их
# значения, затёр бы его своим.
$script:probeLockedTags = @('DataPath','CommandName','Type')

function Assert-ProbeTags($d, [string]$k, $op, [string]$c) {
	foreach ($t in $d.Tags) {
		if ($script:probeLockedTags -contains $t) { Fail "${c}: '$k' меняет $t — привязка и тип элемента через set не меняются" }
	}
	foreach ($t in $d.Tags) {
		$owners = @($script:setProps.Keys | Where-Object { $script:setProps[$_].Tags -contains $t })
		if ($owners.Count -gt 0 -and -not ($owners | Where-Object { $null -ne $op.PSObject.Properties[$_] })) {
			Fail "${c}: '$k' меняет и $t — укажите в той же операции $($owners -join ' или ')"
		}
	}
}

function Invoke-SetByEmitter($node, $props, $context, $op, [string]$c) {
	$n = $node.GetAttribute('name')
	$nt = $node.LocalName
	if (-not $script:xmlTagToDsl.ContainsKey($nt)) { Fail "${c}: у $nt меняются только: $((Get-ApplicableSetKeys $nt) -join ', ')" }
	$set = [ordered]@{}
	foreach ($k in $context.Keys) { $set[$k] = $context[$k] }
	foreach ($k in $props.Keys) { if ($null -ne $props[$k]) { $set[$k] = $props[$k] } }
	$full = Invoke-SetProbe $node $set
	if ($full.El.LocalName -ne $nt) {
		$tk = @($props.Keys | Where-Object { $script:dslTagMap.ContainsKey($_) })
		Fail "${c}: '$($tk -join ', ')' — ключ типа элемента; тип через set не меняется"
	}
	$removals = @()
	$applies = @()
	foreach ($k in $props.Keys) {
		$v = $props[$k]
		$rest = [ordered]@{}
		foreach ($k2 in $set.Keys) { if ($k2 -ne $k) { $rest[$k2] = $set[$k2] } }
		$without = Invoke-SetProbe $node $rest
		if ($null -eq $v) {
			# Сброс: убрать то, что ключ пишет при любом значении
			$owned = @(Get-ProbeOwnerTags $k)
			$d = @{ Tags = $owned; Attrs = @(); Comps = @(); Items = $false }
			if ($owned.Count -eq 0) {
				foreach ($alt in @($true, $false)) {
					$wa = [ordered]@{}; foreach ($k2 in $rest.Keys) { $wa[$k2] = $rest[$k2] }; $wa[$k] = $alt
					$pa = Invoke-SetProbe $node $wa
					if (@($pa.Messages | Where-Object { $_ -match "unknown key '" }).Count -gt 0) { break }
					$da = Get-ProbeDiff $without.El $pa.El
					if (Test-ProbeDiff $da) { $d = $da; break }
				}
			}
			if (-not (Test-ProbeDiff $d)) { Fail "${c}: '$k' сбросить нельзя — неизвестное свойство или у него нет значения по умолчанию; укажите значение" }
			Assert-ProbeTags $d $k $op $c
			if (Test-ProbeDiffPresent $node $d) {
				$removals += $d
				$script:opLog += "  * ${n}: $k сброшено"
				$script:changedCount++
			} else {
				$script:opLog += "  = ${n}: $k — уже по умолчанию"
			}
			continue
		}
		$d = Get-ProbeDiff $without.El $full.El
		if (Test-ProbeDiff $d) {
			if ($d.Items) { Fail "${c}: '$k' меняет состав '$n' — элементы добавляются отдельными операциями" }
			Assert-ProbeTags $d $k $op $c
			$applies += $d
			$shown = if ($v -is [bool]) { "=$("$v".ToLower())" } elseif ($v -is [string] -or $v -is [int] -or $v -is [long]) { "=$v" } else { "" }
			$script:opLog += "  * ${n}: $k$shown → $((Get-ProbeDiffLabel $d) -join ', ')"
			$script:changedCount++
			continue
		}
		# Разницы нет: ключ неизвестен, значение не распознано или совпадает с умолчанием платформы
		$msgs = @($full.Messages)
		if (@($msgs | Where-Object { $_ -match "unknown key '$([regex]::Escape($k))'" }).Count -gt 0) {
			Fail "${c}: неизвестное свойство '$k' — ключи те же, что у элемента в form-compile"
		}
		$vv = @($msgs | ForEach-Object { if ($_ -match 'Valid values: (.*?)\. Value ignored') { $Matches[1] } })
		if ($vv.Count -gt 0) { Fail "${c}: $k='$v' — значение не распознано; допустимо: $($vv[0])" }
		if ($v -is [bool]) {
			$wa = [ordered]@{}; foreach ($k2 in $rest.Keys) { $wa[$k2] = $rest[$k2] }; $wa[$k] = -not $v
			$pa = Invoke-SetProbe $node $wa
			$da = Get-ProbeDiff $without.El $pa.El
			if (Test-ProbeDiff $da) {
				Assert-ProbeTags $da $k $op $c
				if (Test-ProbeDiffPresent $node $da) {
					$removals += $da
					$script:opLog += "  * ${n}: $k=$("$v".ToLower()) — умолчание платформы, $((Get-ProbeDiffLabel $da) -join ', ') не пишется"
					$script:changedCount++
				} else {
					$script:opLog += "  = ${n}: $k=$("$v".ToLower()) — уже по умолчанию"
				}
				continue
			}
		}
		Fail "${c}: '$k' к $nt не применимо или значение совпадает с умолчанием (чтобы вернуть умолчание — null)"
	}
	foreach ($r in $removals) { Apply-ProbeDiff $node $null $r $true }
	foreach ($a in $applies) { Apply-ProbeDiff $node $full.El $a $false }
	# Значение-умолчание платформа не пишет — перенесённый тег с ним убирается
	# (не $c: это параметр [string] функции — PS привёл бы к нему каждый узел цикла)
	foreach ($ch in @($node.ChildNodes)) {
		if ($ch.NodeType -ne 'Element' -or $ch.SelectSingleNode("*")) { continue }
		if ($script:enumDefaultValues.ContainsKey("$($node.LocalName).$($ch.LocalName)") -and $script:enumDefaultValues["$($node.LocalName).$($ch.LocalName)"] -ceq $ch.InnerText) { Remove-NodeWithWs $ch }
	}
}

# --- Удаление ---

$dcsSetNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
$nsMgr.AddNamespace("dcsset", $dcsSetNs)
$script:removeLog = @()
$script:removedCount = 0
$script:leftHandlers = @()
$script:moduleScan = $null

# Модуль формы — рядом с Form.xml: <...>/Ext/Form/Module.bsl. Сканер BSL: строковые литералы (с "" и
# многострочными продолжениями «|») и комментарии // отделяются от кода, номера строк сохраняются.
function Get-ModuleScan {
	if ($null -ne $script:moduleScan) { return $script:moduleScan }
	$scan = @{ Exists = $false; Raw = ""; Lines = @(); Code = @(); Literals = @() }
	$path = Join-Path ([System.IO.Path]::GetDirectoryName($resolvedFormPath)) "Form/Module.bsl"
	if (Test-Path -LiteralPath $path) {
		$scan.Exists = $true
		$scan.Raw = [System.IO.File]::ReadAllText($path)
		$lines = $scan.Raw -replace "`r", "" -split "`n"
		$code = New-Object System.Collections.ArrayList
		$lits = New-Object System.Collections.ArrayList
		$inStr = $false; $cur = $null; $curLine = 0; $curPrefix = ""
		for ($i = 0; $i -lt $lines.Count; $i++) {
			$line = $lines[$i]
			$sb = New-Object System.Text.StringBuilder
			$j = 0
			if ($inStr) {
				# продолжение многострочного литерала: пробелы, затем «|»
				while ($j -lt $line.Length -and ($line[$j] -eq ' ' -or $line[$j] -eq "`t")) { $j++ }
				if ($j -lt $line.Length -and $line[$j] -eq '|') { $j++ }
				$cur += "`n"
			}
			while ($j -lt $line.Length) {
				$c = $line[$j]
				if ($inStr) {
					if ($c -eq '"') {
						if ($j + 1 -lt $line.Length -and $line[$j + 1] -eq '"') { $cur += '"'; $j += 2; continue }
						$inStr = $false
						[void]$lits.Add(@{ Line = $curLine; Text = $cur; Prefix = $curPrefix })
						[void]$sb.Append('""')
						$j++
						continue
					}
					$cur += $c; $j++; continue
				}
				if ($c -eq '/' -and $j + 1 -lt $line.Length -and $line[$j + 1] -eq '/') { break }
				if ($c -eq '"') { $inStr = $true; $cur = ""; $curLine = $i + 1; $curPrefix = $sb.ToString(); $j++; continue }
				[void]$sb.Append($c); $j++
			}
			[void]$code.Add($sb.ToString())
		}
		$scan.Lines = $lines
		$scan.Code = $code.ToArray()
		$scan.Literals = $lits.ToArray()
	}
	$script:moduleScan = $scan
	return $scan
}

# Где имя элемента/команды передают строкой: Найти("X"), ПолеКомпоновкиДанных("X"), ПутьКДанным = "X",
# УстановитьСвойствоЭлементаФормы(Элементы, "X", …); реквизита — ещё РеквизитФормыВЗначение("X") и
# ЗначениеВРеквизитФормы(…, "X").
$script:itemLiteralContext = '((?<!\w)(Найти|Find|ПолеКомпоновкиДанных|DataCompositionField)\s*\(\s*|(?<!\w)(ПутьКДанным|DataPath)\s*=\s*|(?<!\w)(Элементы|Items)\s*,\s*)$'
$script:attrLiteralContext = '((?<!\w)(ПолеКомпоновкиДанных|DataCompositionField|РеквизитФормыВЗначение|FormAttributeToValue)\s*\(\s*|(?<!\w)(ЗначениеВРеквизитФормы|ValueToFormAttribute)\s*\(.*,\s*|(?<!\w)(ПутьКДанным|DataPath)\s*=\s*)$'

# Номера строк модуля, где есть ссылка на имя. Kind: element | command | attribute.
function Find-ModuleRefs([string]$name, [string]$kind) {
	$scan = Get-ModuleScan
	$hits = New-Object System.Collections.Generic.SortedSet[int]
	if (-not $scan.Exists) { return @() }
	$n = [regex]::Escape($name)
	$opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
	for ($i = 0; $i -lt $scan.Code.Count; $i++) {
		$code = $scan.Code[$i]
		if ($kind -eq 'element') {
			if ([regex]::IsMatch($code, "(?<!\w)(Элементы|Items|ПодчиненныеЭлементы|ChildItems)\s*\.\s*$n(?!\w)", $opt)) { [void]$hits.Add($i + 1) }
		} elseif ($kind -eq 'command') {
			if ([regex]::IsMatch($code, "(?<!\w)(Команды|Commands)\s*\.\s*$n(?!\w)", $opt)) { [void]$hits.Add($i + 1) }
		} elseif ($kind -eq 'parameter') {
			if ([regex]::IsMatch($code, "(?<!\w)(Параметры|Parameters)\s*\.\s*$n(?!\w)", $opt)) { [void]$hits.Add($i + 1) }
		} else {
			# Реквизит формы: имя целым словом не после точки; после точки — только ЭтаФорма./ЭтотОбъект.
			foreach ($m in [regex]::Matches($code, "(?<!\w)$n(?!\w)", $opt)) {
				$before = $code.Substring(0, $m.Index)
				if ($before -match '\.\s*$') {
					if ([regex]::IsMatch($before, '(?<![\w.])(ЭтаФорма|ЭтотОбъект|ThisForm|ThisObject)\s*\.\s*$', $opt)) { [void]$hits.Add($i + 1) }
				} else {
					[void]$hits.Add($i + 1)
				}
			}
		}
	}
	# Строкой имя передают только в узком наборе вызовов (по корпусу) — остальные литералы
	# (параметры запроса, ключи структур) с именем совпадают случайно и ссылкой не считаются.
	$ctxPat = if ($kind -eq 'attribute') { $script:attrLiteralContext } else { $script:itemLiteralContext }
	foreach ($lit in $scan.Literals) {
		$t = $lit.Text
		$match = ($t -eq $name -or ($kind -eq 'attribute' -and $t.StartsWith("$name.", [System.StringComparison]::OrdinalIgnoreCase)))
		if ($match -and [regex]::IsMatch($lit.Prefix, $ctxPat, $opt)) { [void]$hits.Add($lit.Line) }
	}
	return @($hits)
}

function Format-ModuleRefs([int[]]$lines) {
	$scan = Get-ModuleScan
	$out = @()
	foreach ($l in ($lines | Select-Object -First 5)) { $out += "  Module.bsl:${l}: $($scan.Lines[$l - 1].Trim())" }
	if ($lines.Count -gt 5) { $out += "  … и ещё $($lines.Count - 5)" }
	return ($out -join "`n")
}

# Обработчики удаляемого, которые есть процедурами в модуле, — в отчёт: мёртвый код, решает автор.
function Add-LeftHandlers([string[]]$handlers) {
	$scan = Get-ModuleScan
	if (-not $scan.Exists) { return }
	foreach ($h in $handlers) {
		if (-not $h -or $script:leftHandlers -contains $h) { continue }
		$pat = "(?im)^\s*((Асинх|Async)\s+)?(Процедура|Функция|Procedure|Function)\s+$([regex]::Escape($h))\s*\("
		if ([regex]::IsMatch($scan.Raw, $pat)) { $script:leftHandlers += $h }
	}
}

function Test-Borrowed([string]$name, [string]$kind) {
	if (-not $script:isExtension) { return $false }
	$bf = $root.SelectSingleNode("f:BaseForm", $nsMgr)
	$xp = switch ($kind) {
		'element' { ".//*[@name]" }
		'command' { "f:Commands/f:Command" }
		'attribute' { "f:Attributes/f:Attribute" }
	}
	foreach ($n in $bf.SelectNodes($xp, $nsMgr)) {
		if ($n.NamespaceURI -eq $formNs -and $n.GetAttribute("name") -eq $name) {
			if ($kind -ne 'element' -or $n.ParentNode.LocalName -eq 'ChildItems') { return $true }
		}
	}
	return $false
}

# Ближайший именованный элемент формы, которому принадлежит узел.
function Get-OwnerElement($node) {
	$cur = $node
	while ($null -ne $cur -and $cur.NodeType -eq 'Element') {
		if ($cur.NamespaceURI -eq $formNs -and $cur.HasAttribute("name") -and ($cur.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $cur.LocalName)) { return $cur }
		$cur = $cur.ParentNode
	}
	return $null
}

function Get-ElementScopes {
	$scopes = @()
	if ($null -ne $script:rootCI) { $scopes += $script:rootCI }
	$acbNode = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($null -ne $acbNode) { $scopes += $acbNode }
	return $scopes
}

function Get-NamedInSubtree($node) {
	$names = @($node.GetAttribute("name"))
	foreach ($d in $node.SelectNodes(".//*[@name]")) {
		if ($d.NamespaceURI -eq $formNs -and ($d.ParentNode.LocalName -eq 'ChildItems' -or $script:companionTags -contains $d.LocalName)) { $names += $d.GetAttribute("name") }
	}
	return $names
}

# Общий удалитель элементов: каскад зависимых кнопок и дополнений поиска, отказ при ссылках из
# модуля и из привязанных полей, чистка условного оформления. $roots — узлы, $reasons — подпись.
function Remove-FormElements($roots, [string]$ctx, [string]$reason) {
	# Вложенные в другие удаляемые — поглощаются
	$set = New-Object System.Collections.ArrayList
	foreach ($r in $roots) {
		$inside = $false
		foreach ($o in $roots) { if (-not (Same $o $r) -and (Test-IsInside $r $o)) { $inside = $true; break } }
		if (-not $inside) { [void]$set.Add($r) }
	}
	$items = New-Object System.Collections.ArrayList   # @{ Node; Reason }
	foreach ($r in $set) { [void]$items.Add(@{ Node = $r; Reason = $reason }) }
	foreach ($r in $set) {
		foreach ($nm in (Get-NamedInSubtree $r)) {
			if (Test-Borrowed $nm 'element') { Fail "${ctx}: '$nm' — заимствованный элемент, платформа не даёт удалять его в расширении; чтобы скрыть — {""set"": ""$nm"", ""visible"": false}" }
		}
	}

	# Каскад: кнопки, дополнения поиска; отказ: прочие привязки Items.X…
	$changed = $true
	while ($changed) {
		$changed = $false
		$removedNames = @{}
		foreach ($it in $items) { foreach ($nm in (Get-NamedInSubtree $it.Node)) { $removedNames[$nm] = $nm } }
		$blockers = @()
		foreach ($s in (Get-ElementScopes)) {
			foreach ($t in $s.SelectNodes(".//*")) {
				$ln = $t.LocalName
				if (-not ($ln -eq 'CommandName' -or $ln -eq 'CommandSource' -or $ln.EndsWith('DataPath') -or ($ln -eq 'Item' -and $t.ParentNode.LocalName -eq 'AdditionSource'))) { continue }
				$txt = $t.InnerText.Trim()
				$target = $null
				if ($txt -match '^Form\.Item\.([^.]+)\.') { $target = $Matches[1] }
				elseif ($ln -eq 'CommandSource' -and $txt -match '^Item\.([^.]+)$') { $target = $Matches[1] }
				elseif ($txt -match '^Items\.([^.]+)\.') { $target = $Matches[1] }
				elseif ($ln -eq 'Item') { $target = $txt }
				if (-not $target -or -not $removedNames.ContainsKey($target)) { continue }
				$owner = Get-OwnerElement $t
				if ($null -eq $owner) { continue }
				$inRemoved = $false
				foreach ($it in $items) { if (Test-IsInside $owner $it.Node) { $inRemoved = $true; break } }
				if ($inRemoved) { continue }
				$ol = $owner.LocalName
				if ($ol -in @('Button','ButtonGroup','Popup','CommandBar','SearchStringAddition','ViewStatusAddition','SearchControlAddition')) {
					[void]$items.Add(@{ Node = $owner; Reason = "зависел от удалённого $($removedNames[$target])" })
					$changed = $true
					break
				}
				$blockers += "$($owner.GetAttribute('name')) ($ol, $ln = $txt)"
			}
			if ($changed) { break }
		}
	}
	if ($blockers.Count -gt 0) {
		Fail "${ctx}: на удаляемое ссылаются элементы, которые остаются: $(($blockers | Select-Object -Unique) -join '; ') — удали их в том же remove или перепривяжи"
	}

	# Заимствованное и ссылки из модуля — по всем удаляемым именам
	$allNames = @()
	foreach ($it in $items) { $allNames += Get-NamedInSubtree $it.Node }
	$allNames = @($allNames | Select-Object -Unique)
	foreach ($nm in $allNames) {
		if (Test-Borrowed $nm 'element') { Fail "${ctx}: '$nm' — заимствованный элемент, платформа не даёт удалять его в расширении; чтобы скрыть — {""set"": ""$nm"", ""visible"": false}" }
	}
	foreach ($nm in $allNames) {
		$refs = Find-ModuleRefs $nm 'element'
		if ($refs.Count -gt 0) { Fail "${ctx}: на элемент '$nm' ссылается модуль формы — сначала убери обращения из кода:`n$(Format-ModuleRefs $refs)" }
	}

	# Командный интерфейс формы: пункт с параметром из текущей строки удаляемого — каскадом
	$cif = $root.SelectSingleNode("f:CommandInterface", $nsMgr)
	if ($null -ne $cif) {
		$lowerNames = @{}; foreach ($nm in $allNames) { $lowerNames[$nm.ToLower()] = $true }
		foreach ($a in @($cif.SelectNodes(".//f:Item/f:Attribute", $nsMgr))) {
			if ($a.InnerText.Trim() -match '^~?Items\.([^.]+)(\.|$)' -and $lowerNames.ContainsKey($Matches[1].ToLower())) {
				$item = $a.ParentNode
				$parent = $item.ParentNode
				Remove-NodeWithWs $item
				while (-not (Same $parent $root) -and $null -eq (Get-FirstElementChild $parent)) {
					$up = $parent.ParentNode
					Remove-NodeWithWs $parent
					$parent = $up
				}
				$script:removeLog += "  - командный интерфейс: пункт с параметром $($a.InnerText.Trim())"
			}
		}
	}

	# Обработчики событий удаляемого
	$handlers = @()
	foreach ($it in $items) {
		foreach ($ev in $it.Node.SelectNodes(".//f:Event", $nsMgr)) { $handlers += $ev.InnerText.Trim() }
	}
	Add-LeftHandlers $handlers

	# Условное оформление: поле удаляемого элемента — из списка оформляемых; пустой список
	# означал бы «вся форма», поэтому такое правило уходит целиком.
	$ca = $root.SelectSingleNode("f:Attributes/f:ConditionalAppearance", $nsMgr)
	if ($null -ne $ca) {
		$lower = @{}; foreach ($nm in $allNames) { $lower[$nm.ToLower()] = $true }
		foreach ($rule in @($ca.SelectNodes("dcsset:item", $nsMgr))) {
			$sel = $rule.SelectSingleNode("dcsset:selection", $nsMgr)
			if ($null -eq $sel) { continue }
			$hit = $false
			foreach ($si in @($sel.SelectNodes("dcsset:item", $nsMgr))) {
				$f = $si.SelectSingleNode("dcsset:field", $nsMgr)
				if ($null -ne $f -and $lower.ContainsKey($f.InnerText.Trim().ToLower())) {
					$script:removeLog += "  - условное оформление: поле $($f.InnerText.Trim()) убрано из правила"
					Remove-NodeWithWs $si
					$hit = $true
				}
			}
			if ($hit -and $null -eq (Get-FirstElementChild $sel)) {
				Remove-NodeWithWs $rule
				$script:removeLog += "  - условное оформление: правило без оформляемых полей удалено"
			}
		}
		if ($null -eq (Get-FirstElementChild $ca)) { Remove-NodeWithWs $ca }
	}

	foreach ($it in $items) {
		$node = $it.Node
		$name = $node.GetAttribute("name")
		# вложенные элементы для отчёта — без служебных узлов
		$shown = @()
		foreach ($d in $node.SelectNodes(".//*[@name]")) {
			if ($d.NamespaceURI -eq $formNs -and $d.ParentNode.LocalName -eq 'ChildItems') { $shown += $d.GetAttribute("name") }
		}
		$tail = ""
		if ($shown.Count -gt 0) {
			$list = ($shown | Select-Object -First 10) -join ', '
			if ($shown.Count -gt 10) { $list += ", … и ещё $($shown.Count - 10)" }
			$tail = " (+ $list)"
		}
		$why = if ($it.Reason) { " — $($it.Reason)" } else { "" }
		$ci = $node.ParentNode
		$holder = $ci.ParentNode
		Remove-NodeWithWs $node
		Remove-IfEmptyChildItems $ci
		# Опустевшая командная панель или меню — пустым тегом, как пишет платформа
		if ($null -ne $holder -and $script:companionTags -contains $holder.LocalName -and $null -eq (Get-FirstElementChild $holder)) {
			while ($holder.HasChildNodes) { $holder.RemoveChild($holder.FirstChild) | Out-Null }
			$holder.IsEmpty = $true
		}
		$script:removeLog += "  - $name [$($node.LocalName)]$tail$why"
		$script:removedCount++
	}
}

function Invoke-Remove($op, [int]$idx) {
	$ctx = "elements[$idx] remove"
	Assert-OpKeys $op @('remove') $ctx
	$names = @(@($op.remove) | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($names.Count -eq 0) { Fail "${ctx}: укажи имя элемента или список имён" }
	$nodes = @()
	$seen = @{}
	foreach ($n in $names) {
		if ($seen.ContainsKey($n)) { Fail "${ctx}: '$n' указан дважды" }
		$seen[$n] = $true
		$node = Find-FormElement $n
		if ($null -eq $node) { Fail "${ctx}: элемент '$n' не найден в форме" }
		if ($node.ParentNode.LocalName -ne 'ChildItems' -or $script:companionTags -contains $node.LocalName) {
			Fail "${ctx}: '$n' — служебный узел ($($node.LocalName)) своего элемента, удаляется только вместе с ним"
		}
		$nodes += $node
	}
	Remove-FormElements $nodes $ctx ""
}

function Remove-FormCommand($op, [int]$idx) {
	$ctx = "commands[$idx] remove"
	Assert-OpKeys $op @('remove') $ctx
	$name = "$($op.remove)"
	$sec = $root.SelectSingleNode("f:Commands", $nsMgr)
	$cmd = $null
	if ($null -ne $sec) { foreach ($c in $sec.SelectNodes("f:Command", $nsMgr)) { if ($c.GetAttribute("name") -eq $name) { $cmd = $c; break } } }
	if ($null -eq $cmd) { Fail "${ctx}: команда '$name' не найдена в форме" }
	$name = $cmd.GetAttribute("name")
	if (Test-Borrowed $name 'command') { Fail "${ctx}: '$name' — заимствованная команда, платформа не даёт удалять её в расширении" }
	$refs = Find-ModuleRefs $name 'command'
	if ($refs.Count -gt 0) { Fail "${ctx}: на команду '$name' ссылается модуль формы — сначала убери обращения из кода:`n$(Format-ModuleRefs $refs)" }

	# Кнопки команды — через общий удалитель (их имена тоже проверяются по модулю)
	$buttons = @()
	foreach ($s in (Get-ElementScopes)) {
		foreach ($cn in $s.SelectNodes(".//f:CommandName", $nsMgr)) {
			if ($cn.InnerText.Trim() -eq "Form.Command.$name") {
				$b = Get-OwnerElement $cn
				if ($null -ne $b) { $buttons += $b }
			}
		}
	}
	if ($buttons.Count -gt 0) { Remove-FormElements $buttons $ctx "кнопка удалённой команды $name" }

	# Пункты командного интерфейса формы
	$ci = $root.SelectSingleNode("f:CommandInterface", $nsMgr)
	if ($null -ne $ci) {
		foreach ($c in @($ci.SelectNodes(".//f:Item/f:Command", $nsMgr))) {
			if ($c.InnerText.Trim() -ne "Form.Command.$name") { continue }
			$item = $c.ParentNode
			$parent = $item.ParentNode
			Remove-NodeWithWs $item
			while (-not (Same $parent $root) -and $null -eq (Get-FirstElementChild $parent)) {
				$up = $parent.ParentNode
				Remove-NodeWithWs $parent
				$parent = $up
			}
			$script:removeLog += "  - командный интерфейс: пункт команды $name"
		}
	}

	Add-LeftHandlers @($cmd.SelectNodes("f:Action", $nsMgr) | ForEach-Object { $_.InnerText.Trim() })
	Remove-NodeWithWs $cmd
	if ($null -eq (Get-FirstElementChild $sec)) { Remove-NodeWithWs $sec }
	$script:removeLog += "  - команда $name"
	$script:removedCount++
}

function Remove-FormAttribute($op, [int]$idx) {
	$ctx = "attributes[$idx] remove"
	Assert-OpKeys $op @('remove') $ctx
	$name = "$($op.remove)"
	$sec = $root.SelectSingleNode("f:Attributes", $nsMgr)
	$attr = $null
	if ($null -ne $sec) { foreach ($a in $sec.SelectNodes("f:Attribute", $nsMgr)) { if ($a.GetAttribute("name") -eq $name) { $attr = $a; break } } }
	if ($null -eq $attr) { Fail "${ctx}: реквизит '$name' не найден в форме" }
	$name = $attr.GetAttribute("name")
	$main = $attr.SelectSingleNode("f:MainAttribute", $nsMgr)
	if ($null -ne $main -and $main.InnerText.Trim() -eq 'true') { Fail "${ctx}: '$name' — основной реквизит формы, он не удаляется" }
	if (Test-Borrowed $name 'attribute') { Fail "${ctx}: '$name' — заимствованный реквизит, платформа не даёт удалять его в расширении" }
	$refs = Find-ModuleRefs $name 'attribute'
	if ($refs.Count -gt 0) { Fail "${ctx}: к реквизиту '$name' обращается модуль формы — сначала убери обращения из кода:`n$(Format-ModuleRefs $refs)" }

	# Привязки в форме: пути данных элементов и поля условного оформления
	$users = @()
	$isPath = { param($t) $t -eq $name -or $t.StartsWith("$name.", [System.StringComparison]::OrdinalIgnoreCase) }
	foreach ($s in (Get-ElementScopes)) {
		foreach ($t in $s.SelectNodes(".//*")) {
			if (-not $t.LocalName.EndsWith('DataPath')) { continue }
			if (& $isPath $t.InnerText.Trim()) {
				$o = Get-OwnerElement $t
				if ($null -ne $o) { $users += "$($o.GetAttribute('name')) ($($t.LocalName))" }
			}
		}
	}
	$ca = $root.SelectSingleNode("f:Attributes/f:ConditionalAppearance", $nsMgr)
	if ($null -ne $ca) {
		foreach ($t in $ca.SelectNodes(".//dcsset:left | .//dcsset:right", $nsMgr)) {
			$xt = $t.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
			if ($xt.EndsWith(':Field') -and (& $isPath $t.InnerText.Trim())) { $users += "условное оформление (отбор по $($t.InnerText.Trim()))" }
		}
	}
	$cif = $root.SelectSingleNode("f:CommandInterface", $nsMgr)
	if ($null -ne $cif) {
		foreach ($a in $cif.SelectNodes(".//f:Item/f:Attribute", $nsMgr)) {
			$at = $a.InnerText.Trim().TrimStart('~')
			if (& $isPath $at) { $users += "командный интерфейс (параметр $($a.InnerText.Trim()))" }
		}
	}
	if ($users.Count -gt 0) {
		Fail "${ctx}: к реквизиту '$name' привязаны: $(($users | Select-Object -Unique) -join '; ') — удали или перепривяжи их раньше (elements выполняются до attributes)"
	}
	Remove-NodeWithWs $attr
	if ($null -eq (Get-FirstElementChild $sec)) {
		while ($sec.HasChildNodes) { $sec.RemoveChild($sec.FirstChild) | Out-Null }
		$sec.IsEmpty = $true
	}
	$script:removeLog += "  - реквизит $name"
	$script:removedCount++
}

# === 9e. Секции формы ===

# Узел-секция корня формы; нет — создаётся на своём месте (порядок корня — по корпусу).
function Get-OrCreateRootSection([string]$tag) {
	$sec = $root.SelectSingleNode("f:$tag", $nsMgr)
	if ($null -ne $sec) { return $sec }
	$sec = $xmlDoc.CreateElement($tag, $formNs)
	Insert-RootChild $sec
	return $sec
}

function Insert-RootChild($node) {
	$rank = Get-FormRootRank $node.LocalName
	$ref = $null
	foreach ($c in $root.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		if ((Get-FormRootRank $c.LocalName) -gt $rank) { $ref = $c; break }
	}
	Insert-NodeAt $root $node $ref (Get-ChildIndent $root)
}

# Вывод эмиттера form-compile во фрагмент: блок пишет через X; результат — узлы верхнего уровня.
function Invoke-SectionEmit([scriptblock]$emit, [string]$rootType = '') {
	$saveId = $script:nextElemId
	$script:xml = New-Object System.Text.StringBuilder 2048
	X "<_F $allNsDecl>"
	. $emit
	X "</_F>"
	$script:nextElemId = $saveId
	$text = $script:xml.ToString()
	if ($rootType) { $text = Normalize-EnumTags $text $rootType }
	return @(Import-ElementNodes (Parse-Fragment $text))
}

# Свойство формы: значение — как в form-compile; null — убрать.
function Set-FormProperty([string]$key, $value) {
	if ($null -ne $value -and -not ($value -is [string] -or $value -is [bool] -or $value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal])) {
		Fail "properties.${key}: значение — строка, число или true/false"
	}
	$probe = New-Object PSObject
	$probe | Add-Member -NotePropertyName $key -NotePropertyValue $(if ($null -eq $value -or "$value" -eq '') { 'x' } else { $value })
	$node = @(Invoke-SectionEmit { Emit-Properties -props $probe -indent "`t" } $(if ($null -eq $value -or "$value" -eq '') { '' } else { 'Form' }))[0]
	$tag = $node.LocalName
	$existing = $root.SelectSingleNode("f:$tag", $nsMgr)
	if ($null -eq $value -or "$value" -eq '') {
		if ($null -ne $existing) { Remove-NodeWithWs $existing; $script:formLog += "  * $tag убрано"; $script:formChanged++ }
		return
	}
	if ($null -ne $existing) { $root.ReplaceChild($node, $existing) | Out-Null } else { Insert-RootChild $node }
	$script:formLog += "  * ${tag}=$($node.InnerText)"
	$script:formChanged++
}

# События формы: { Событие: обработчик | { handler, callType } | [ … ] } — как events элемента.
function Add-FormEventsDsl($events) {
	if (-not ($events -is [System.Management.Automation.PSCustomObject])) { Fail "events — объект { Событие: обработчик }" }
	$sec = $null
	foreach ($p in $events.PSObject.Properties) {
		Warn-UnknownFormEvent $p.Name
		foreach ($v in @($p.Value)) {
			$h = ""; $ct = ""
			if ($v -is [System.Management.Automation.PSCustomObject]) { $h = "$($v.handler)"; $ct = Normalize-CallType "$($v.callType)" 'Form' $p.Name } else { $h = "$v" }
			if (-not $ct -and $script:isExtension) { $ct = 'Before' }
			if (-not $h) { Fail "events: у события формы $($p.Name) укажите имя обработчика" }
			$ctStr = if ($ct) { "[$ct]" } else { "" }
			if ($null -eq $sec) { $sec = $root.SelectSingleNode("f:Events", $nsMgr) }
			if ($null -ne $sec) {
				$dup = $null
				foreach ($e in $sec.SelectNodes("f:Event", $nsMgr)) {
					if ($e.GetAttribute('name') -eq $p.Name -and $e.GetAttribute('callType') -eq $ct) { $dup = $e; break }
				}
				if ($null -ne $dup) {
					if ($dup.InnerText -eq $h) { $script:formLog += "  = событие $($p.Name)$ctStr -> $h уже есть"; continue }
					Fail "events: событие формы $($p.Name)$ctStr уже обрабатывает '$($dup.InnerText)' — второй обработчик не повесить"
				}
			}
			if ($null -eq $sec) { $sec = Get-OrCreateRootSection 'Events' }
			$ev = $xmlDoc.CreateElement("Event", $formNs)
			$ev.SetAttribute('name', $p.Name)
			if ($ct) { $ev.SetAttribute('callType', $ct) }
			$ev.InnerText = $h
			Insert-NodeAt $sec $ev $null (Get-ChildIndent $sec)
			$script:formLog += "  + событие $($p.Name)$ctStr -> $h"
			$script:formChanged++
		}
	}
}

# Исключённые команды: список имён — исключить; { remove: [...] } — вернуть.
function Update-ExcludedCommands($spec) {
	if ($spec -is [System.Management.Automation.PSCustomObject]) {
		Assert-OpKeys $spec @('remove') "excludedCommands"
		$sec = $root.SelectSingleNode("f:CommandSet", $nsMgr)
		foreach ($n in @(@($spec.remove) | ForEach-Object { "$_" })) {
			$hit = $null
			if ($null -ne $sec) { foreach ($e in $sec.SelectNodes("f:ExcludedCommand", $nsMgr)) { if ($e.InnerText.Trim() -eq $n) { $hit = $e; break } } }
			if ($null -eq $hit) { Fail "excludedCommands: команда '$n' не исключена в форме" }
			Remove-NodeWithWs $hit
			$script:formLog += "  - исключение команды $n"
			$script:formChanged++
		}
		if ($null -ne $sec -and $null -eq (Get-FirstElementChild $sec)) { Remove-NodeWithWs $sec }
		return
	}
	$sec = $null
	foreach ($n in @(@($spec) | ForEach-Object { "$_" } | Where-Object { $_ })) {
		if ($null -eq $sec) { $sec = Get-OrCreateRootSection 'CommandSet' }
		$dup = $false
		foreach ($e in $sec.SelectNodes("f:ExcludedCommand", $nsMgr)) { if ($e.InnerText.Trim() -eq $n) { $dup = $true; break } }
		if ($dup) { $script:formLog += "  = команда $n уже исключена"; continue }
		$e = $xmlDoc.CreateElement("ExcludedCommand", $formNs)
		$e.InnerText = $n
		Insert-NodeAt $sec $e $null (Get-ChildIndent $sec)
		$script:formLog += "  + исключена команда $n"
		$script:formChanged++
	}
}

# Параметры формы: определения — как в form-compile; { remove: имя | [...] } — удалить.
function Update-FormParameters($list) {
	$adds = @()
	$i = 0
	foreach ($p in @($list)) {
		if ($null -ne $p.PSObject.Properties['remove']) {
			Assert-OpKeys $p @('remove') "parameters[$i] remove"
			foreach ($n in @(@($p.remove) | ForEach-Object { "$_" })) {
				$sec = $root.SelectSingleNode("f:Parameters", $nsMgr)
				$hit = $null
				if ($null -ne $sec) { foreach ($e in $sec.SelectNodes("f:Parameter", $nsMgr)) { if ($e.GetAttribute('name') -eq $n) { $hit = $e; break } } }
				if ($null -eq $hit) { Fail "parameters[$i] remove: параметр '$n' не найден в форме" }
				$refs = Find-ModuleRefs $n 'parameter'
				if ($refs.Count -gt 0) { Fail "parameters[$i] remove: к параметру '$n' обращается модуль формы — сначала убери обращения из кода:`n$(Format-ModuleRefs $refs)" }
				Remove-NodeWithWs $hit
				if ($null -eq (Get-FirstElementChild $sec)) { Remove-NodeWithWs $sec }
				$script:formLog += "  - параметр $n"
				$script:formChanged++
			}
		} else { $adds += $p }
		$i++
	}
	if ($adds.Count -eq 0) { return }
	$sec = Get-OrCreateRootSection 'Parameters'
	$seen = @{}
	foreach ($p in $adds) {
		Assert-EditUnique -name "$($p.name)" -seen $seen -ctx 'parameter name'
		foreach ($e in $sec.SelectNodes("f:Parameter", $nsMgr)) {
			if ($e.GetAttribute('name') -eq "$($p.name)") { Fail "parameters: параметр '$($p.name)' уже есть в форме" }
		}
	}
	$wrap = @(Invoke-SectionEmit { Emit-Parameters -params $adds -indent "`t" })[0]
	foreach ($node in @($wrap.SelectNodes("f:Parameter", $nsMgr))) {
		$wrap.RemoveChild($node) | Out-Null
		Insert-NodeAt $sec $node $null (Get-ChildIndent $sec)
		$script:formLog += "  + параметр $($node.GetAttribute('name'))"
		$script:formChanged++
	}
}

# Условное оформление: правила — как в form-compile; добавляются в конец оформления формы.
function Add-FormConditionalAppearance($items) {
	$items = @($items)
	if ($items.Count -eq 0) { return }
	$attrs = Get-OrCreateRootSection 'Attributes'
	if ($attrs.IsEmpty) { $attrs.IsEmpty = $false }
	$ca = $attrs.SelectSingleNode("f:ConditionalAppearance", $nsMgr)
	$wrap = @(Invoke-SectionEmit { Emit-ConditionalAppearance -items $items -indent "`t`t" -wrapTag 'ConditionalAppearance' })[0]
	if ($null -eq $ca) {
		Insert-NodeAt $attrs $wrap $null (Get-ChildIndent $attrs)
		$n = @($wrap.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }).Count
	} else {
		$n = 0
		foreach ($r in @($wrap.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
			$wrap.RemoveChild($r) | Out-Null
			Insert-NodeAt $ca $r $null (Get-ChildIndent $ca)
			$n++
		}
	}
	$script:formLog += "  + условное оформление: правил $n"
	$script:formChanged += $n
}

# Командный интерфейс: пункты панелей — как в form-compile; добавляются в конец своей панели.
function Add-FormCommandInterface($ci) {
	$wrap = @(Invoke-SectionEmit { Emit-CommandInterface -ci $ci -indent "`t" })
	if ($wrap.Count -eq 0) { return }
	$wrap = $wrap[0]
	$sec = $root.SelectSingleNode("f:CommandInterface", $nsMgr)
	if ($null -eq $sec) {
		Insert-RootChild $wrap
		foreach ($pn in @($wrap.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
			$script:formLog += "  + командный интерфейс, $($pn.LocalName): пунктов $(@($pn.SelectNodes('f:Item', $nsMgr)).Count)"
			$script:formChanged++
		}
		return
	}
	foreach ($pn in @($wrap.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
		$target = $sec.SelectSingleNode("f:$($pn.LocalName)", $nsMgr)
		if ($null -eq $target) {
			$wrap.RemoveChild($pn) | Out-Null
			# Как в выгрузке: панель навигации раньше командной панели
			$ref = if ($pn.LocalName -eq 'NavigationPanel') { $sec.SelectSingleNode("f:CommandBar", $nsMgr) } else { $null }
			Insert-NodeAt $sec $pn $ref (Get-ChildIndent $sec)
			$cnt = @($pn.SelectNodes('f:Item', $nsMgr)).Count
		} else {
			$cnt = 0
			foreach ($it in @($pn.SelectNodes("f:Item", $nsMgr))) {
				$pn.RemoveChild($it) | Out-Null
				Insert-NodeAt $target $it $null (Get-ChildIndent $target)
				$cnt++
			}
		}
		$script:formLog += "  + командный интерфейс, $($pn.LocalName): пунктов $cnt"
		$script:formChanged++
	}
}

# Обработчики, которые были в форме до правки: callType по умолчанию ставится только новым
$script:preexistingHandlers = New-Object 'System.Collections.Generic.HashSet[System.Xml.XmlNode]'
foreach ($n in $root.SelectNodes("//f:Event | //f:Action", $nsMgr)) { [void]$script:preexistingHandlers.Add($n) }

# === 10. Elements: добавление, перенос, изменение, удаление — по порядку ===

$script:opLog = @()
$script:addedCount = 0
$script:movedCount = 0
$script:changedCount = 0
$companionCount = 0

# Ключи типов — в порядке form-compile: ключ, который бывает и свойством (group у страницы,
# picture у кнопки), проверяется после типа, у которого он свойство.
$elemTypeKeys = @("columnGroup","buttonGroup","pages","page","group","input","check","radio","label","labelField","table","button","calendar","cmdBar","popup","searchString","viewStatus","searchControl","picField","picture","spreadsheet","html","textDoc","formattedDoc","progressBar","trackBar","chart","ganttChart","graphicalSchema","planner","periodField","dendrogram")

if ($def.elements -and @($def.elements).Count -gt 0) {
	$ops = @($def.elements)

	# Вид каждой операции: ключ типа — добавление, move/set — над существующим элементом.
	$opKinds = @()
	for ($i = 0; $i -lt $ops.Count; $i++) {
		$op = $ops[$i]
		$kinds = @()
		foreach ($k in @('move','set','remove')) { if ($null -ne $op.PSObject.Properties[$k]) { $kinds += $k } }
		# Тип элемента XML-именем или по-русски (InputField, ПолеВвода) → канонический ключ
		if ($kinds.Count -eq 0 -and $op -is [System.Management.Automation.PSCustomObject]) { Normalize-ElementTypeSynonyms $op }
		# У set ключ типа — свойство (group — ориентация); остальные ключи типа set отвергнет сам.
		if ($kinds -notcontains 'set') {
			if ($null -ne $op.PSObject.Properties['autoCmdBar']) { $kinds += 'autoCmdBar' }
			else { foreach ($k in $elemTypeKeys) { if ($null -ne $op.PSObject.Properties[$k]) { $kinds += $k; break } } }
		}
		if ($kinds.Count -eq 0) { Fail "elements[$i]: не понять действие — нужен тип элемента (input, group, …), move, set или remove" }
		if ($kinds.Count -gt 1) { Fail "elements[$i]: одна запись — одно действие, а здесь $($kinds -join ' и ')" }
		$opKinds += $kinds[0]
	}

	# Имена добавляемых элементов уникальны (требование 1С): внутри JSON (рекурсивно по
	# children/columns) и против уже существующих элементов формы.
	function Walk-ElemNames($el, [hashtable]$seen) {
		$tk = $null
		foreach ($k in $elemTypeKeys) { if ($el.$k -ne $null) { $tk = $k; break } }
		if ($tk) { Assert-EditUnique -name (Get-ElementName -el $el -typeKey $tk) -seen $seen -ctx 'element name' }
		if ($el.children) { foreach ($c in $el.children) { Walk-ElemNames $c $seen } }
		if ($el.columns)  { foreach ($c in $el.columns)  { Walk-ElemNames $c $seen } }
	}
	$dslElemNames = @{}
	for ($i = 0; $i -lt $ops.Count; $i++) {
		if ($opKinds[$i] -in @('move','set','remove','autoCmdBar')) { continue }
		Walk-ElemNames $ops[$i] $dslElemNames
	}

	$startElemId = $script:nextElemId
	for ($i = 0; $i -lt $ops.Count; $i++) {
		switch ($opKinds[$i]) {
			'move' { Invoke-Move $ops[$i] $i }
			'set'  { Invoke-Set $ops[$i] $i }
			'remove' { Invoke-Remove $ops[$i] $i }
			'autoCmdBar' { Invoke-AutoCmdBar $ops[$i] $i }
			default { Invoke-Add $ops[$i] $opKinds[$i] $i }
		}
	}
	$companionCount = ($script:nextElemId - $startElemId) - $script:addedCount
}

# === 11. Add attributes ===

$addedAttrs = @()

# Удаления (запись с ключом remove) — по порядку, до добавлений
$attrAdds = @()
if ($def.attributes) {
	$attrOps = @($def.attributes)
	for ($i = 0; $i -lt $attrOps.Count; $i++) {
		if ($null -ne $attrOps[$i].PSObject.Properties['remove']) {
			Assert-OpKeys $attrOps[$i] @('remove') "attributes[$i] remove"
			foreach ($rn in @(@($attrOps[$i].remove) | ForEach-Object { "$_" })) { Remove-FormAttribute ([pscustomobject]@{ remove = $rn }) $i }
		} else { $attrAdds += $attrOps[$i] }
	}
}

if ($attrAdds.Count -gt 0) {
	$attrsSection = Get-OrCreateRootSection 'Attributes'
	$attrChildIndent = Get-ChildIndent $attrsSection

	# Уникальность имён реквизитов: внутри JSON-определения (+ колонки в пределах реквизита) и
	# против уже существующих реквизитов формы.
	$dslAttrNames = @{}
	foreach ($attr in $attrAdds) {
		Assert-EditUnique -name "$($attr.name)" -seen $dslAttrNames -ctx 'attribute name'
		if ($attr.columns) {
			$dslColNames = @{}
			foreach ($col in $attr.columns) { Assert-EditUnique -name "$($col.name)" -seen $dslColNames -ctx "column name of '$($attr.name)'" }
		}
		foreach ($a in $attrsSection.SelectNodes("f:Attribute", $nsMgr)) {
			if ($a.GetAttribute('name') -eq "$($attr.name)") {
				Write-Host "[ERROR] Attribute '$($attr.name)' already exists in form — attribute names must be unique"
				exit 1
			}
		}
		if ($attr.main -eq $true) {
			foreach ($m in $attrsSection.SelectNodes("f:Attribute/f:MainAttribute", $nsMgr)) {
				if ($m.InnerText.Trim() -eq 'true') { Fail "attributes: '$($attr.name)' — у формы уже есть основной реквизит '$($m.ParentNode.GetAttribute('name'))'" }
			}
		}
	}

	# Реквизиты пишет эмиттер form-compile (все его ключи); id — из пулов формы
	$wrap = @(Invoke-SectionEmit { Emit-Attributes -attrs $attrAdds -indent "`t" })[0]
	foreach ($node in @($wrap.SelectNodes("f:Attribute", $nsMgr))) {
		$attrId = New-AttrId
		$node.SetAttribute('id', "$attrId")
		$colId = 1
		foreach ($col in $node.SelectNodes(".//f:Column", $nsMgr)) { $col.SetAttribute('id', "$colId"); $colId++ }
		$wrap.RemoveChild($node) | Out-Null
		# Условное оформление — последнее в Attributes: реквизит встаёт перед ним
		$caNode = $attrsSection.SelectSingleNode("f:ConditionalAppearance", $nsMgr)
		if ($null -ne $caNode) { Insert-NodeAt $attrsSection $node $caNode $attrChildIndent }
		else { Insert-IntoContainer -container $attrsSection -newNode $node -afterName $null -childIndent $attrChildIndent }
		$t = $node.SelectSingleNode("f:Type/v8:Type", $nsMgr)
		$typeStr = if ($null -ne $t) { $t.InnerText } else { "(no type)" }
		$addedAttrs += "  + $($node.GetAttribute('name')): $typeStr (id=$attrId)"
	}
}

# === 12. Add commands ===

$addedCmds = @()

# Удаления (запись с ключом remove) — по порядку, до добавлений
$cmdAdds = @()
if ($def.commands) {
	$cmdOps = @($def.commands)
	for ($i = 0; $i -lt $cmdOps.Count; $i++) {
		if ($null -ne $cmdOps[$i].PSObject.Properties['remove']) {
			Assert-OpKeys $cmdOps[$i] @('remove') "commands[$i] remove"
			foreach ($rn in @(@($cmdOps[$i].remove) | ForEach-Object { "$_" })) { Remove-FormCommand ([pscustomobject]@{ remove = $rn }) $i }
		} else { $cmdAdds += $cmdOps[$i] }
	}
}

if ($cmdAdds.Count -gt 0) {
	$cmdsSection = Get-OrCreateRootSection 'Commands'
	$cmdChildIndent = Get-ChildIndent $cmdsSection

	# Уникальность имён команд: внутри JSON-определения и против существующих команд формы.
	$dslCmdNames = @{}
	foreach ($cmd in $cmdAdds) {
		Assert-EditUnique -name "$($cmd.name)" -seen $dslCmdNames -ctx 'command name'
		foreach ($c in $cmdsSection.SelectNodes("f:Command", $nsMgr)) {
			if ($c.GetAttribute('name') -eq "$($cmd.name)") {
				Write-Host "[ERROR] Command '$($cmd.name)' already exists in form — command names must be unique"
				exit 1
			}
		}
	}

	# Команды пишет эмиттер form-compile (все его ключи); id — из пула формы
	$wrap = @(Invoke-SectionEmit { Emit-Commands -cmds $cmdAdds -indent "`t" })[0]
	foreach ($node in @($wrap.SelectNodes("f:Command", $nsMgr))) {
		$cmdId = New-CmdId
		$node.SetAttribute('id', "$cmdId")
		$wrap.RemoveChild($node) | Out-Null
		Insert-IntoContainer -container $cmdsSection -newNode $node -afterName $null -childIndent $cmdChildIndent
		$acts = @($node.SelectNodes("f:Action", $nsMgr))
		$actionStr = if ($acts.Count -eq 1) { " -> $($acts[0].InnerText)" } elseif ($acts.Count -gt 1) { " -> $($acts.Count) action(s)" } else { "" }
		$addedCmds += "  + $($node.GetAttribute('name'))${actionStr} (id=$cmdId)"
	}
}

# === 12b. Add form-level events ===

$addedFormEvents = @()

if ($def.formEvents -and $def.formEvents.Count -gt 0) {
	$eventsSection = $root.SelectSingleNode("f:Events", $nsMgr)
	if (-not $eventsSection) {
		# Create Events section — insert after AutoCommandBar or at the beginning
		$eventsSection = $xmlDoc.CreateElement("Events", $formNs)
		$insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
		if ($insertAfter) {
			# Insert after AutoCommandBar (Events come after AutoCommandBar in 1C)
			$ws1 = $xmlDoc.CreateWhitespace("`r`n`t")
			$ws2 = $xmlDoc.CreateWhitespace("`r`n`t")
			if ($insertAfter.NextSibling) {
				$root.InsertBefore($ws1, $insertAfter.NextSibling) | Out-Null
				$root.InsertBefore($eventsSection, $ws1) | Out-Null
				$root.InsertBefore($ws2, $eventsSection) | Out-Null
			} else {
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
				$root.AppendChild($eventsSection) | Out-Null
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n")) | Out-Null
			}
		} else {
			$firstChild = $root.FirstChild
			if ($firstChild) {
				$ws = $xmlDoc.CreateWhitespace("`r`n`t")
				$root.InsertBefore($eventsSection, $firstChild) | Out-Null
				$root.InsertBefore($ws, $eventsSection) | Out-Null
			} else {
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
				$root.AppendChild($eventsSection) | Out-Null
			}
		}
	}

	$evtChildIndent = Get-ChildIndent $eventsSection
	if (-not $evtChildIndent -or $evtChildIndent -eq "") { $evtChildIndent = "`t`t" }

	# Generate event fragments
	$script:xml = New-Object System.Text.StringBuilder 512
	X "<_F $allNsDecl>"
	foreach ($fe in $def.formEvents) {
		$feName = "$($fe.name)"
		$feHandler = "$($fe.handler)"
		$callTypeAttr = if ($fe.callType) { " callType=`"$($fe.callType)`"" } else { "" }
		X "$evtChildIndent<Event name=`"$feName`"$callTypeAttr>$feHandler</Event>"
		$ctStr = if ($fe.callType) { "[$($fe.callType)]" } else { "" }
		$addedFormEvents += "  + $feName${ctStr} -> $feHandler"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedEvents = Import-ElementNodes $fragDoc

	foreach ($node in $importedEvents) {
		Insert-IntoContainer -container $eventsSection -newNode $node -afterName $null -childIndent $evtChildIndent
	}
}

# === 12c. Add element-level events ===

$addedElemEvents = @()

if ($def.elementEvents -and $def.elementEvents.Count -gt 0) {
	if (-not $rootCI) {
		$rootCI = $root.SelectSingleNode("f:ChildItems", $nsMgr)
	}

	foreach ($ee in $def.elementEvents) {
		$targetName = "$($ee.element)"
		$targetEl = Find-Element $rootCI $targetName
		if (-not $targetEl) {
			Write-Host "[WARN] Element '$targetName' not found — skipping elementEvent"
			continue
		}

		# Find or create Events element within the target
		$targetEvents = $targetEl.SelectSingleNode("f:Events", $nsMgr)
		if (-not $targetEvents) {
			$targetEvents = $xmlDoc.CreateElement("Events", $formNs)
			# Insert Events before closing tag (after last property, before ChildItems if any)
			$ciNode = $targetEl.SelectSingleNode("f:ChildItems", $nsMgr)
			if ($ciNode) {
				$ws = $xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))
				$targetEl.InsertBefore($ws, $ciNode) | Out-Null
				$targetEl.InsertBefore($targetEvents, $ciNode) | Out-Null
			} else {
				$trailing = $targetEl.LastChild
				if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
					$ws = $xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))
					$targetEl.InsertBefore($ws, $trailing) | Out-Null
					$targetEl.InsertBefore($targetEvents, $trailing) | Out-Null
				} else {
					$targetEl.AppendChild($xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))) | Out-Null
					$targetEl.AppendChild($targetEvents) | Out-Null
				}
			}
		}

		$eeChildIndent = Get-ChildIndent $targetEvents
		if (-not $eeChildIndent -or $eeChildIndent -eq "") {
			$parentIndent = Get-ChildIndent $targetEl
			$eeChildIndent = "$parentIndent`t"
		}

		# Create Event element
		$eeName = "$($ee.name)"
		$eeHandler = "$($ee.handler)"
		$callTypeAttr = if ($ee.callType) { " callType=`"$($ee.callType)`"" } else { "" }

		$script:xml = New-Object System.Text.StringBuilder 256
		X "<_F $allNsDecl>"
		X "$eeChildIndent<Event name=`"$eeName`"$callTypeAttr>$eeHandler</Event>"
		X "</_F>"

		$fragDoc = Parse-Fragment $script:xml.ToString()
		$importedEE = Import-ElementNodes $fragDoc

		foreach ($node in $importedEE) {
			Insert-IntoContainer -container $targetEvents -newNode $node -afterName $null -childIndent $eeChildIndent
		}

		$ctStr = if ($ee.callType) { "[$($ee.callType)]" } else { "" }
		$addedElemEvents += "  + $targetName.$eeName${ctStr} -> $eeHandler"
	}
}

# === 12d. Форма: заголовок, свойства, события, исключённые команды, параметры, оформление, интерфейс ===

$script:formLog = @()
$script:formChanged = 0

# Заголовок формы. Новый заголовок без AutoTitle в форме — AutoTitle=false (как в form-compile:
# иначе платформа допишет к нему синоним объекта).
$formTitleVal = $null; $hasFormTitle = $false
$propsTitle = $def.properties -and $def.properties -is [System.Management.Automation.PSCustomObject] -and $null -ne $def.properties.PSObject.Properties['title']
if ($null -ne $def.PSObject.Properties['title']) {
	if ($propsTitle) { Fail "заголовок формы задан дважды — в title и в properties.title" }
	$formTitleVal = $def.title; $hasFormTitle = $true
}
elseif ($propsTitle) { $formTitleVal = $def.properties.title; $hasFormTitle = $true }
$autoGiven = $def.properties -and $def.properties -is [System.Management.Automation.PSCustomObject] -and $null -ne $def.properties.PSObject.Properties['autoTitle']
if ($hasFormTitle) {
	$tNode = $root.SelectSingleNode("f:Title", $nsMgr)
	if ($null -eq $formTitleVal -or ($formTitleVal -is [string] -and $formTitleVal -eq '')) {
		if ($null -ne $tNode) { Remove-NodeWithWs $tNode; $script:formLog += "  * заголовок убран"; $script:formChanged++ }
		# Без своего заголовка форма берёт синоним объекта — AutoTitle=false оставил бы её без заголовка
		$at = $root.SelectSingleNode("f:AutoTitle", $nsMgr)
		if (-not $autoGiven -and $null -ne $at -and $at.InnerText.Trim() -eq 'false') { Set-FormProperty 'autoTitle' $null }
	} else {
		if ($null -eq $tNode) {
			$tNode = $xmlDoc.CreateElement("Title", $formNs)
			Insert-RootChild $tNode
		}
		Set-MLTag $root 'Title' $formTitleVal
		$shown = if ($formTitleVal -is [string]) { $formTitleVal } else { ($formTitleVal.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' ' }
		$script:formLog += "  * заголовок `"$shown`""
		$script:formChanged++
		if (-not $autoGiven -and $null -eq $root.SelectSingleNode("f:AutoTitle", $nsMgr)) { Set-FormProperty 'autoTitle' $false }
	}
}

if ($def.properties) {
	if (-not ($def.properties -is [System.Management.Automation.PSCustomObject])) { Fail "properties — объект { свойство: значение }" }
	foreach ($p in $def.properties.PSObject.Properties) {
		if ($p.Name -eq 'title') { continue }
		Set-FormProperty $p.Name $p.Value
	}
}

if ($null -ne $def.PSObject.Properties['events']) { Add-FormEventsDsl $def.events }

if ($null -ne $def.PSObject.Properties['excludedCommands']) { Update-ExcludedCommands $def.excludedCommands }

if ($null -ne $def.PSObject.Properties['parameters']) { Update-FormParameters $def.parameters }

if ($null -ne $def.PSObject.Properties['conditionalAppearance']) { Add-FormConditionalAppearance $def.conditionalAppearance }

if ($null -ne $def.PSObject.Properties['commandInterface']) { Add-FormCommandInterface $def.commandInterface }

# В форме расширения обработчик без callType платформа читает как Before и так и пишет (замер на стенде) —
# новым обработчикам вне BaseForm ставим его сразу, чтобы выгрузка не переписывала файл
if ($script:isExtension) {
	foreach ($n in $root.SelectNodes("//f:Event | //f:Action", $nsMgr)) {
		if ($script:preexistingHandlers.Contains($n) -or $n.HasAttribute('callType')) { continue }
		if ($null -ne $n.SelectSingleNode("ancestor::f:BaseForm", $nsMgr)) { continue }
		$n.SetAttribute('callType', 'Before')
	}
}

# Вид вызова обработчика (callType) бывает только в форме расширения
if (-not $script:isExtension) {
	$ctNode = $root.SelectSingleNode("//*[@callType]")
	if ($null -ne $ctNode) { Fail "callType '$($ctNode.GetAttribute('callType'))' у '$($ctNode.InnerText)' — вид вызова обработчика задаётся только в форме расширения" }
}

# === 13. Save ===

$content = $xmlDoc.OuterXml
# Ensure encoding declaration is uppercase UTF-8
$content = $content -replace '^<\?xml version="1.0" encoding="utf-8"\?>', '<?xml version="1.0" encoding="UTF-8"?>'
# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
# поэтому они идут первыми ветками альтернации и возвращаются как есть.
$content = [regex]::Replace($content, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })

# BOM — как у файла-назначения: правка не меняет того, о чём не просили (#44/#46/#47).
# Выгрузка платформы всегда с BOM; без BOM — только файл, созданный не платформой.
$targetBom = $true
if (Test-Path -LiteralPath $resolvedFormPath) {
	$head = [System.IO.File]::ReadAllBytes($resolvedFormPath)
	$targetBom = ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
}
$enc = New-Object System.Text.UTF8Encoding($targetBom)
# Целевой перевод строки: стиль файла-назначения — правка наследует его (#44/#46/#47),
# новый файл получает канон выгрузки CRLF. Зеркало _detect_xml_style в py-порту.
$targetEol = if ((Test-Path -LiteralPath $resolvedFormPath) -and ([System.IO.File]::ReadAllText($resolvedFormPath) -notmatch "`r`n")) { "`n" } else { "`r`n" }
$content = ($content -replace "`r`n", "`n") -replace "`n", $targetEol
[System.IO.File]::WriteAllText($resolvedFormPath, $content, $enc)

# === 14. Summary ===

if ($script:isExtension) {
	Write-Host "[EXTENSION] BaseForm detected — IDs start at 1000000+"
	Write-Host ""
}

if ($addedFormEvents.Count -gt 0) {
	Write-Host "Added form events:"
	foreach ($line in $addedFormEvents) { Write-Host $line }
	Write-Host ""
}

if ($addedElemEvents.Count -gt 0) {
	Write-Host "Added element events:"
	foreach ($line in $addedElemEvents) { Write-Host $line }
	Write-Host ""
}

if ($script:opLog.Count -gt 0) {
	Write-Host "Elements:"
	foreach ($line in $script:opLog) { Write-Host $line }
	Write-Host ""
}

if ($script:removeLog.Count -gt 0) {
	Write-Host "Removed:"
	foreach ($line in $script:removeLog) { Write-Host $line }
	Write-Host ""
}

if ($script:leftHandlers.Count -gt 0) {
	Write-Host "Handlers left in module (delete if unused):"
	foreach ($h in $script:leftHandlers) { Write-Host "  $h" }
	Write-Host ""
}

if ($script:formLog.Count -gt 0) {
	Write-Host "Form:"
	foreach ($line in $script:formLog) { Write-Host $line }
	Write-Host ""
}

if ($addedAttrs.Count -gt 0) {
	Write-Host "Added attributes:"
	foreach ($line in $addedAttrs) { Write-Host $line }
	Write-Host ""
}

if ($addedCmds.Count -gt 0) {
	Write-Host "Added commands:"
	foreach ($line in $addedCmds) { Write-Host $line }
	Write-Host ""
}

Write-Host "---"
$totalParts = @()
if ($addedFormEvents.Count -gt 0) { $totalParts += "$($addedFormEvents.Count) form event(s)" }
if ($addedElemEvents.Count -gt 0) { $totalParts += "$($addedElemEvents.Count) element event(s)" }
if ($script:addedCount -gt 0) {
	$compStr = if ($companionCount -gt 0) { " (+$companionCount companions)" } else { "" }
	$totalParts += "$($script:addedCount) element(s)$compStr"
}
if ($script:movedCount -gt 0) { $totalParts += "$($script:movedCount) moved" }
if ($script:changedCount -gt 0) { $totalParts += "$($script:changedCount) property change(s)" }
if ($script:removedCount -gt 0) { $totalParts += "$($script:removedCount) removed" }
if ($addedAttrs.Count -gt 0) { $totalParts += "$($addedAttrs.Count) attribute(s)" }
if ($addedCmds.Count -gt 0) { $totalParts += "$($addedCmds.Count) command(s)" }
if ($script:formChanged -gt 0) { $totalParts += "$($script:formChanged) form change(s)" }
if ($totalParts.Count -eq 0) { $totalParts += "no changes" }
Write-Host "Total: $($totalParts -join ', ')"
Write-Host "Run /form-validate to verify."
