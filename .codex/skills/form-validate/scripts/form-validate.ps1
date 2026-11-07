# form-validate v1.39 — Validate 1C managed form
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory, Position=0)]
	[Alias('Path')]
	[string]$FormPath,

	[switch]$Detailed,

	[int]$MaxErrors = 30
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---
# A: Directory → Ext/Form.xml
if (Test-Path $FormPath -PathType Container) {
	$FormPath = Join-Path (Join-Path $FormPath "Ext") "Form.xml"
}
# B1: Missing Ext/ (e.g. Forms/Форма/Form.xml → Forms/Форма/Ext/Form.xml)
if (-not (Test-Path $FormPath)) {
	$fn = [System.IO.Path]::GetFileName($FormPath)
	if ($fn -eq "Form.xml") {
		$c = Join-Path (Join-Path (Split-Path $FormPath) "Ext") $fn
		if (Test-Path $c) { $FormPath = $c }
	}
}
# B2: Descriptor (Forms/Форма.xml → Forms/Форма/Ext/Form.xml)
if (-not (Test-Path $FormPath) -and $FormPath.EndsWith(".xml")) {
	$stem = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
	$dir = Split-Path $FormPath
	$c = Join-Path (Join-Path (Join-Path $dir $stem) "Ext") "Form.xml"
	if (Test-Path $c) { $FormPath = $c }
}

# --- Load XML ---

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
try {
	$xmlDoc.Load((Resolve-Path $FormPath).ProviderPath)
} catch {
	Write-Host "[ERROR] XML parse error: $($_.Exception.Message)"
	Write-Host ""
	Write-Host "---"
	Write-Host "Errors: 1, Warnings: 0"
	exit 1
}

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("f", "http://v8.1c.ru/8.3/xcf/logform")
$nsMgr.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$nsMgr.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

$root = $xmlDoc.DocumentElement

# Корень автономной внешней обработки/отчёта. Копия общего эталона (семья
# support-guard: is_external_root, авторитет — cf-edit).
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

# Штамп версии формата — атрибут version КОРНЕВОГО элемента файла. Копия общего эталона (семья
# root_version, авторитет — meta-validate).
function Get-RootVersion([string]$xmlPath) {
	if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) { return $null }
	$buf = New-Object byte[] 4096
	$fs = [System.IO.File]::OpenRead($xmlPath)
	try { $len = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
	$head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $len)
	$m = [regex]::Match($head, '<[A-Za-z_][\w.:-]*(\s[^>]*)?/?>')
	if (-not $m.Success) { return $null }
	$v = [regex]::Match($m.Groups[1].Value, '(?:^|\s)version="([^"]*)"')
	if ($v.Success) { return $v.Groups[1].Value }
	return $null
}

# Якорь выгрузки: корень автономной EPF/ERF либо Configuration.xml, ближайший вверх. Копия общего
# эталона (семья find_dump_anchor, авторитет — meta-validate).
function Find-DumpAnchor([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 15 -and $d; $i++) {
		if (Test-ExternalObjectRoot "$d.xml") { return "$d.xml" }
		$cfg = Join-Path $d "Configuration.xml"
		if (Test-Path $cfg) { return $cfg }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if (-not $parent -or $parent -eq $d) { break }
		$d = $parent
	}
	return $null
}

# Владелец тела X/Ext/<файл>.xml — дескриптор X.xml рядом с каталогом X. У тел конфигурации (и
# расширения) соседа-дескриптора нет, владелец — Configuration.xml внутри X. Иначе — не определён.
function Get-ExtBodyOwner([string]$bodyPath) {
	$extDir = [System.IO.Path]::GetDirectoryName($bodyPath)
	if ([System.IO.Path]::GetFileName($extDir) -cne "Ext") { return $null }
	$objDir = [System.IO.Path]::GetDirectoryName($extDir)
	if (Test-Path -LiteralPath "$objDir.xml" -PathType Leaf) { return "$objDir.xml" }
	$cfg = Join-Path $objDir "Configuration.xml"
	if (Test-Path -LiteralPath $cfg -PathType Leaf) { return $cfg }
	return $null
}

# --- Detect context: config vs EPF/ERF ---
# Ближайший якорь выгрузки вверх от формы. Configuration.xml → конфигурация; корень EPF/ERF → внешняя
# обработка/отчёт. Ближайший побеждает: автономная обработка остаётся автономной, даже если её
# исходники лежат внутри дерева с Configuration.xml (типовая раскладка проекта: src/cf рядом с
# src/epf). Иначе её собственные External*-типы считались бы ошибкой.
$script:dumpAnchor = Find-DumpAnchor (Split-Path (Resolve-Path $FormPath).ProviderPath -Parent)
$script:isConfigContext = [bool]($script:dumpAnchor -and [System.IO.Path]::GetFileName($script:dumpAnchor) -eq "Configuration.xml")

# --- Counters ---

$errors = 0
$warnings = 0
$stopped = $false
$script:okCount = 0

function Report-OK {
	param([string]$msg)
	$script:okCount++
	if ($Detailed) { Write-Host "[OK]    $msg" }
}

function Report-Error {
	param([string]$msg)
	$script:errors++
	Write-Host "[ERROR] $msg"
	if ($script:errors -ge $MaxErrors) {
		$script:stopped = $true
	}
}

function Report-Warn {
	param([string]$msg)
	$script:warnings++
	Write-Host "[WARN]  $msg"
}

# --- Format version ---
# Проверенный диапазон версий формата выгрузки: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница —
# docs/1c-configuration-spec.md, «Лестница версий». Версию задаёт платформа ВЫГРУЗКИ, а не режим
# совместимости конфигурации. Версии ниже 2.17 (платформы 8.3.23 и старше) существуют, но навыки
# на них не проверялись — это предупреждение о непокрытии, а не о некорректности файла.
$formatVerifiedMin = "2.17"
$formatVerifiedMax = "2.21"
# Версия формата как число: "2.20" → 220. Строковое сравнение неверно ("2.9" > "2.17").
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

# --- Form name from path ---

$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
$parentDir = [System.IO.Path]::GetDirectoryName($FormPath)
if ($parentDir) {
	$extDir = [System.IO.Path]::GetFileName($parentDir)
	if ($extDir -eq "Ext") {
		$formDir = [System.IO.Path]::GetDirectoryName($parentDir)
		if ($formDir) { $formName = [System.IO.Path]::GetFileName($formDir) }
	}
}

if ($Detailed) {
	Write-Host "=== Validation: $formName ==="
	Write-Host ""
}

# Early BaseForm detection (used in Check 5 to skip base element DataPath validation)
$hasBaseForm = ($root.SelectSingleNode("f:BaseForm", $nsMgr) -ne $null)

# --- Check 1: Root element and version ---

if ($root.LocalName -ne "Form") {
	Report-Error "Root element is '$($root.LocalName)', expected 'Form'"
} else {
	$version = $root.GetAttribute("version")
	$versionRank = Get-FormatRank $version
	if (-not $version) {
		Report-Warn "Form version attribute missing"
	} elseif ($versionRank -eq 0) {
		Report-Error "Malformed version '$version' (expected N.N)"
	} elseif ($versionRank -lt (Get-FormatRank $formatVerifiedMin)) {
		Report-Warn "Format version '$version' is below the tested range $formatVerifiedMin-$formatVerifiedMax — skills were not verified on it"
	} elseif ($versionRank -gt (Get-FormatRank $formatVerifiedMax)) {
		Report-Warn "Format version '$version' is above the tested range $formatVerifiedMin-$formatVerifiedMax — skills were not verified on it"
	} else {
		Report-OK "Root element: Form version=$version"
	}
}

# --- Check 2: AutoCommandBar ---

if (-not $stopped) {
	$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($acb) {
		$acbName = $acb.GetAttribute("name")
		$acbId = $acb.GetAttribute("id")
		# id=-1 — соглашение, а не требование: в корпусе УТ/БП/ERP так у 21 094 форм из 21 097,
		# но три формы платформа выгружает с обычным id и грузит их без нареканий. Поэтому
		# предупреждение; ошибка — только если id вовсе не число.
		if ($acbId -eq "-1") {
			Report-OK "AutoCommandBar: name='$acbName', id=$acbId"
		} elseif ($acbId -match '^-?\d+$') {
			Report-Warn "AutoCommandBar id='$acbId', usually '-1'"
		} else {
			Report-Error "AutoCommandBar id='$acbId' is not a number"
		}
	} else {
		Report-Error "AutoCommandBar element missing"
	}
}

# --- Collect all elements with IDs ---

$elementIds = @{}    # id -> name (element ID pool)
$elementNames = @{}  # name -> id (имена элементов уникальны в пределах формы)
$allElements = @() # @{Name; Tag; Id; ParentName; Node}

function Collect-Elements {
	param($node, [string]$parentName)

	foreach ($child in $node.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }

		$name = $child.GetAttribute("name")
		$id = $child.GetAttribute("id")

		if ($name -and $id) {
			$tag = $child.LocalName

			$script:allElements += @{
				Name       = $name
				Tag        = $tag
				Id         = $id
				ParentName = $parentName
				Node       = $child
			}

			# Track element IDs (skip AutoCommandBar which has -1)
			if ($id -ne "-1") {
				if ($elementIds.ContainsKey($id)) {
					Report-Error "Duplicate element id=${id}: '$name' and '$($elementIds[$id])'"
				} else {
					$elementIds[$id] = $name
				}

				# Имена элементов уникальны (требование 1С)
				if ($elementNames.ContainsKey($name)) {
					Report-Error "Duplicate element name '$name': id=${id} and id=$($elementNames[$name])"
				} else {
					$elementNames[$name] = $id
				}
			}

			# Recurse into ChildItems
			$childItems = $child.SelectSingleNode("f:ChildItems", $nsMgr)
			if ($childItems) {
				Collect-Elements -node $childItems -parentName $name
			}
		}
	}
}

# Collect from ChildItems
$childItemsRoot = $root.SelectSingleNode("f:ChildItems", $nsMgr)
if ($childItemsRoot) {
	Collect-Elements -node $childItemsRoot -parentName "(root)"
}

# Also collect from AutoCommandBar's ChildItems
$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
if ($acb) {
	$acbChildren = $acb.SelectSingleNode("f:ChildItems", $nsMgr)
	if ($acbChildren) {
		Collect-Elements -node $acbChildren -parentName "ФормаКоманднаяПанель"
	}
}

# --- Check 3: Unique element IDs ---

if (-not $stopped) {
	$dupCount = ($allElements | Group-Object { $_.Id } | Where-Object { $_.Count -gt 1 -and $_.Name -ne "-1" }).Count
	if ($dupCount -eq 0) {
		Report-OK "Unique element IDs: $($elementIds.Count) elements"
	}
}

# --- Collect attributes (separate ID pool) ---

$attrMap = @{}    # name -> node
$attrIds = @{}    # id -> name
$attrNodes = $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)
foreach ($attr in $attrNodes) {
	$attrName = $attr.GetAttribute("name")
	$attrId = $attr.GetAttribute("id")
	if ($attrName) {
		# Имена реквизитов уникальны среди реквизитов (отдельный неймспейс от элементов)
		if ($attrMap.ContainsKey($attrName)) {
			Report-Error "Duplicate attribute name '$attrName': id=${attrId} and id=$($attrMap[$attrName].GetAttribute('id'))"
		}
		$attrMap[$attrName] = $attr
	}
	if ($attrId -and $attrId -ne "") {
		if ($attrIds.ContainsKey($attrId)) {
			Report-Error "Duplicate attribute id=${attrId}: '$attrName' and '$($attrIds[$attrId])'"
		} else {
			$attrIds[$attrId] = $attrName
		}
	}

	# Column IDs are a separate sub-pool per attribute — check uniqueness within parent
	$colIds = @{}
	$colNames = @{}  # имена колонок уникальны в пределах своего реквизита
	foreach ($col in $attr.SelectNodes("f:Columns/f:Column", $nsMgr)) {
		$colId = $col.GetAttribute("id")
		$colName = $col.GetAttribute("name")
		if ($colId -and $colId -ne "") {
			if ($colIds.ContainsKey($colId)) {
				Report-Error "Duplicate column id=${colId} in '$attrName': '$colName' and '$($colIds[$colId])'"
			} else {
				$colIds[$colId] = $colName
			}
		}
		if ($colName) {
			if ($colNames.ContainsKey($colName)) {
				Report-Error "Duplicate column name '$colName' in '$attrName': id=${colId} and id=$($colNames[$colName])"
			} else {
				$colNames[$colName] = $colId
			}
		}
	}
}

if (-not $stopped) {
	$attrDupCount = ($attrIds.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 }).Count
	if ($attrDupCount -eq 0 -and $attrIds.Count -gt 0) {
		Report-OK "Unique attribute IDs: $($attrIds.Count) entries"
	}
}

# --- Collect commands (separate ID pool) ---

$cmdMap = @{}   # name -> node
$cmdIds = @{}   # id -> name
$cmdNodes = $root.SelectNodes("f:Commands/f:Command", $nsMgr)
foreach ($cmd in $cmdNodes) {
	$cmdName = $cmd.GetAttribute("name")
	$cmdId = $cmd.GetAttribute("id")
	if ($cmdName) {
		# Имена команд уникальны среди команд (отдельный неймспейс)
		if ($cmdMap.ContainsKey($cmdName)) {
			Report-Error "Duplicate command name '$cmdName': id=${cmdId} and id=$($cmdMap[$cmdName].GetAttribute('id'))"
		}
		$cmdMap[$cmdName] = $cmd
	}
	if ($cmdId -and $cmdId -ne "") {
		if ($cmdIds.ContainsKey($cmdId)) {
			Report-Error "Duplicate command id=${cmdId}: '$cmdName' and '$($cmdIds[$cmdId])'"
		} else {
			$cmdIds[$cmdId] = $cmdName
		}
	}
}

if (-not $stopped) {
	if ($cmdIds.Count -gt 0) {
		$cmdDupCount = ($cmdIds.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 }).Count
		if ($cmdDupCount -eq 0) {
			Report-OK "Unique command IDs: $($cmdIds.Count) entries"
		}
	}
}

# --- Collect parameters (separate name pool, без id) ---

$paramNames = @{}  # name -> $true (имена параметров уникальны среди параметров)
foreach ($param in $root.SelectNodes("f:Parameters/f:Parameter", $nsMgr)) {
	$paramName = $param.GetAttribute("name")
	if ($paramName) {
		if ($paramNames.ContainsKey($paramName)) {
			Report-Error "Duplicate parameter name '$paramName'"
		} else {
			$paramNames[$paramName] = $true
		}
	}
}

# --- Check 4: Companion elements ---

# Define required companions per element type
$companionRules = @{
	"InputField"        = @("ContextMenu", "ExtendedTooltip")
	"CheckBoxField"     = @("ContextMenu", "ExtendedTooltip")
	"LabelDecoration"   = @("ContextMenu", "ExtendedTooltip")
	"LabelField"        = @("ContextMenu", "ExtendedTooltip")
	"PictureDecoration" = @("ContextMenu", "ExtendedTooltip")
	"PictureField"      = @("ContextMenu", "ExtendedTooltip")
	"CalendarField"     = @("ContextMenu", "ExtendedTooltip")
	"UsualGroup"        = @("ExtendedTooltip")
	"Pages"             = @("ExtendedTooltip")
	"Page"              = @("ExtendedTooltip")
	"Button"            = @("ExtendedTooltip")
	"Table"             = @("ContextMenu", "AutoCommandBar", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition")
}

if (-not $stopped) {
	$companionErrors = 0
	$companionChecked = 0

	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		if (-not $companionRules.ContainsKey($tag)) { continue }

		$required = $companionRules[$tag]
		$companionChecked++

		foreach ($compTag in $required) {
			$compNode = $node.SelectSingleNode("f:$compTag", $nsMgr)
			if (-not $compNode) {
				Report-Error "[$tag] '$elName': missing companion <$compTag>"
				$companionErrors++
			}
		}
	}

	if ($companionErrors -eq 0 -and $companionChecked -gt 0) {
		Report-OK "Companion elements: $companionChecked elements checked"
	}
}

# --- Check 5: DataPath -> Attribute references ---

if (-not $stopped) {
	$pathErrors = 0
	$pathChecked = 0
	# Пути, о которых уже сказано поэлементно, — проход по прочим привязкам ниже их не повторяет
	$reportedPaths = @{}

	# All data-binding tags whose value is an attribute path (root must exist in <Attributes>).
	$bindingTags = @('DataPath','TitleDataPath','FooterDataPath','HeaderDataPath',
		'MultipleValueDataPath','MultipleValuePresentDataPath','RowPictureDataPath','MultipleValuePictureDataPath')

	# Заимствованная форма без основного реквизита: путь Объект.* на ней — ровно этот случай. Подсказка —
	# только к корню, который и был бы основным реквизитом: имя из <BaseForm>, а нет его там — обычные
	# имена основного реквизита. Опечатке в корне или чужому реквизиту она не нужна.
	$mainRootNames = @()
	if ($hasBaseForm) {
		$mainRootNames = @('Объект', 'Список', 'Запись', 'Отчет', 'НаборЗаписей', 'НаборКонстант',
			'Object', 'List', 'Record', 'Report', 'RecordSet', 'ConstantsSet')
		$mainBase = $root.SelectSingleNode("f:BaseForm/f:Attributes/f:Attribute[f:MainAttribute='true']", $nsMgr)
		if ($mainBase -and $mainBase.GetAttribute("name")) { $mainRootNames = @($mainBase.GetAttribute("name")) }
		foreach ($attr in $attrNodes) {
			$maNode = $attr.SelectSingleNode("f:MainAttribute", $nsMgr)
			if ($maNode -and $maNode.InnerText.Trim() -eq "true") { $mainRootNames = @(); break }
		}
	}
	$noMainHint = { param($r) if ($r -in $mainRootNames) { " (the borrowed form declares no MainAttribute)" } else { "" } }

	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		# Skip companion elements
		if ($tag -in @("ContextMenu", "ExtendedTooltip", "AutoCommandBar", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition")) {
			continue
		}

		# Базовые элементы заимствованной формы (id < 1000000) проверяются так же: висячую привязку
		# платформа отвергает и на них — «Неверный путь к данным».
		foreach ($bTag in $bindingTags) {
			if ($stopped) { break }
			$dpNode = $node.SelectSingleNode("f:$bTag", $nsMgr)
			if (-not $dpNode) { continue }

			$dataPath = $dpNode.InnerText.Trim()
			if (-not $dataPath) { continue }

			# Ссылки, которые Конфигуратор пишет номерами, по Form.xml не разрешить: «10», «1/0:<uuid>»,
			# «306:<uuid>/8:<uuid>», «1/-5». Имя реквизита с цифры не начинается.
			if ($dataPath -match '^\d') {
				continue
			}

			$pathChecked++

			# Extract root segment of path, strip array indices like [0]
			$cleanPath = $dataPath -replace '\[\d+\]', ''
			# Strip leading '~' (current row of DynamicList: ~Список.Поле)
			if ($cleanPath.StartsWith('~')) { $cleanPath = $cleanPath.Substring(1) }
			$segments = $cleanPath -split '\.'
			$rootAttr = $segments[0]

			# Resolve Items.<TableName>.CurrentData.<Field>... — table element, not attribute.
			# Разрешаем ЦЕПОЧКОЙ: таблица во вложенной таблице сама привязана через Items.*, и один
			# шаг оставлял корнем литерал «Items» — форма платформы объявлялась битой (типовые
			# НастройкаПравилОбработкиЗаявокСотрудников в БП и ERP).
			$itemsHops = 0
			$itemsBroken = $false
			while ($rootAttr -eq 'Items') {
				$itemsHops++
				if ($itemsHops -gt 10) { $itemsBroken = $true; break }   # страховка от кольца ссылок
				if ($segments.Count -lt 3 -or $segments[2] -ne 'CurrentData') {
					Report-Warn "[$tag] '$elName': $bTag='$dataPath' — unknown Items.* shape, expected Items.<Table>.CurrentData.*"
					$itemsBroken = $true
					break
				}
				$tableName = $segments[1]
				$tableEl = $null
				foreach ($candidate in $allElements) {
					if ($candidate.Tag -eq 'Table' -and $candidate.Name -eq $tableName) {
						$tableEl = $candidate
						break
					}
				}
				if (-not $tableEl) {
					Report-Error "[$tag] '$elName': $bTag='$dataPath' — table element '$tableName' not found"
					$pathErrors++
					$itemsBroken = $true
					break
				}
				$tableDpNode = $tableEl.Node.SelectSingleNode("f:DataPath", $nsMgr)
				if (-not $tableDpNode -or -not $tableDpNode.InnerText.Trim()) {
					# Table without DataPath — can't resolve further, accept silently
					$itemsBroken = $true
					break
				}
				$tableDp = $tableDpNode.InnerText.Trim() -replace '\[\d+\]', ''
				if ($tableDp.StartsWith('~')) { $tableDp = $tableDp.Substring(1) }
				$segments = $tableDp -split '\.'
				$rootAttr = $segments[0]
			}
			if ($itemsBroken) { continue }

			if (-not $attrMap.ContainsKey($rootAttr)) {
				Report-Error "[$tag] '$elName': $bTag='$dataPath' — attribute '$rootAttr' not found$(& $noMainHint $rootAttr)"
				$pathErrors++
				$reportedPaths[$dataPath] = $true
			}
		}
	}

	# Прочие привязки — <xr:DataPath> в <ChoiceParameterLinks>/<TypeLink> и любой *DataPath вне тегов
	# выше: корень тоже должен быть реквизитом формы. Только своя часть: <BaseForm> — снимок исходной
	# формы, его платформа разрешает по конфигурации. Items.* и номерные ссылки — как выше.
	$ownText = ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $FormPath).ProviderPath, [System.Text.Encoding]::UTF8) -split '<BaseForm', 2)[0]
	# Порядок корней — как в файле: одинаков в обоих портах
	$undeclared = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)
	foreach ($m in [regex]::Matches($ownText, '<(?:\w+:)?\w*DataPath[^>]*>([^<]+)</(?:\w+:)?\w*DataPath>')) {
		$dp = $m.Groups[1].Value.Trim()
		if (-not $dp -or $dp -match '^\d' -or $reportedPaths.ContainsKey($dp)) { continue }
		$rootAttr = ((($dp -replace '\[\d+\]', '') -replace '^~', '') -split '\.', 2)[0]
		if ($rootAttr -eq 'Items' -or $attrMap.ContainsKey($rootAttr)) { continue }
		if (-not $undeclared.Contains($rootAttr)) { $undeclared[$rootAttr] = New-Object System.Collections.Generic.List[string] }
		if (-not $undeclared[$rootAttr].Contains($dp)) { $undeclared[$rootAttr].Add($dp) }
	}
	foreach ($rootAttr in @($undeclared.Keys)) {
		if ($stopped) { break }
		$shown = $undeclared[$rootAttr]
		$sample = ($shown | Select-Object -First 3) -join ", "
		$suffix = if ($shown.Count -gt 3) { " (and $($shown.Count - 3) more)" } else { "" }
		Report-Error "Path(s) rooted at '${rootAttr}' — attribute '${rootAttr}' not found$(& $noMainHint $rootAttr): $sample$suffix"
		$pathErrors++
	}

	if ($pathErrors -eq 0 -and $pathChecked -gt 0) {
		Report-OK "Data bindings: $pathChecked paths checked"
	} elseif ($pathErrors -eq 0) {
		Report-OK "Data bindings: none"
	}
}

# --- Check 6: Button command references ---

if (-not $stopped) {
	$cmdErrors = 0
	$cmdChecked = 0

	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		if ($tag -ne "Button") { continue }

		$cmdNode = $node.SelectSingleNode("f:CommandName", $nsMgr)
		if (-not $cmdNode) { continue }

		$cmdRef = $cmdNode.InnerText.Trim()
		if (-not $cmdRef) { continue }

		# Form.Command.XXX -> check command XXX exists
		if ($cmdRef -match '^Form\.Command\.(.+)$') {
			$cmdName = $Matches[1]
			$cmdChecked++
			if (-not $cmdMap.ContainsKey($cmdName)) {
				Report-Error "[Button] '$elName': CommandName='$cmdRef' — command '$cmdName' not found in Commands"
				$cmdErrors++
			}
		}
		# Form.StandardCommand.XXX — skip, standard commands always exist
	}

	if ($cmdErrors -eq 0 -and $cmdChecked -gt 0) {
		Report-OK "Command references: $cmdChecked buttons checked"
	} elseif ($cmdChecked -eq 0) {
		Report-OK "Command references: none"
	}
}

# --- Check 7: Events have handler names ---

if (-not $stopped) {
	$eventErrors = 0
	$eventChecked = 0

	# Form-level events
	$formEvents = $root.SelectSingleNode("f:Events", $nsMgr)
	if ($formEvents) {
		foreach ($evt in $formEvents.SelectNodes("f:Event", $nsMgr)) {
			$evtName = $evt.GetAttribute("name")
			$handler = $evt.InnerText.Trim()
			$eventChecked++
			if (-not $handler) {
				Report-Error "Form event '$evtName': empty handler name"
				$eventErrors++
			}
		}
	}

	# Element-level events
	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		$eventsNode = $node.SelectSingleNode("f:Events", $nsMgr)
		if (-not $eventsNode) { continue }

		foreach ($evt in $eventsNode.SelectNodes("f:Event", $nsMgr)) {
			$evtName = $evt.GetAttribute("name")
			$handler = $evt.InnerText.Trim()
			$eventChecked++
			if (-not $handler) {
				Report-Error "[$tag] '$elName' event '$evtName': empty handler name"
				$eventErrors++
			}
		}
	}

	if ($eventErrors -eq 0 -and $eventChecked -gt 0) {
		Report-OK "Event handlers: $eventChecked events checked"
	} elseif ($eventChecked -eq 0) {
		Report-OK "Event handlers: none"
	}
}

# --- Check 8: Command actions ---

if (-not $stopped) {
	$actionErrors = 0
	$actionChecked = 0

	# Предупреждение, а не ошибка: <Action> может назначаться в рантайме
	# (`Команда.Действие = "Подключаемый_…"` в ПриСозданииНаСервере) — приём типовых конфигураций
	# там, где обработчик существует не во всякой сборке. Назначать может и чужой модуль
	# (переопределяемый слой, подключаемые команды), так что по одному Form.xml не решить.
	# Корпус УТ/БП/ERP: 406 таких команд на 275 формах, произведённых платформой.
	foreach ($cmd in $cmdNodes) {
		if ($stopped) { break }
		$cmdName = $cmd.GetAttribute("name")
		$actionNode = $cmd.SelectSingleNode("f:Action", $nsMgr)
		$actionChecked++
		if (-not $actionNode -or -not $actionNode.InnerText.Trim()) {
			Report-Warn "Command '$cmdName': no Action — handler must be assigned at runtime, otherwise the command does nothing"
			$actionErrors++
		}
	}

	if ($actionErrors -eq 0 -and $actionChecked -gt 0) {
		Report-OK "Command actions: $actionChecked commands checked"
	} elseif ($actionChecked -eq 0) {
		Report-OK "Command actions: none"
	}
}

# --- Check 9: MainAttribute count ---

if (-not $stopped) {
	$mainCount = 0
	foreach ($attr in $attrNodes) {
		$mainNode = $attr.SelectSingleNode("f:MainAttribute", $nsMgr)
		if ($mainNode -and $mainNode.InnerText -eq "true") {
			$mainCount++
		}
	}

	if ($mainCount -le 1) {
		$mainInfo = if ($mainCount -eq 1) { "1 main attribute" } else { "no main attribute" }
		Report-OK "MainAttribute: $mainInfo"
	} else {
		Report-Error "Multiple MainAttribute=true ($mainCount found, expected 0 or 1)"
	}
}

# --- Check 10: Title must be multilingual XML (not plain text) ---

if (-not $stopped) {
	$titleNode = $root.SelectSingleNode("f:Title", $nsMgr)
	if ($titleNode) {
		$v8items = $titleNode.SelectNodes("v8:item", $nsMgr)
		if ($v8items.Count -eq 0 -and $titleNode.InnerText.Trim() -ne "") {
			Report-Error "Form Title is plain text ('$($titleNode.InnerText.Trim())') — must be multilingual XML (<v8:item>). Use top-level 'title' key in form-compile DSL."
		} else {
			Report-OK "Title: multilingual XML"
		}
	}
}

# --- Check 11: Extension-specific validations ---

$baseFormNode = $root.SelectSingleNode("f:BaseForm", $nsMgr)
$isExtension = ($baseFormNode -ne $null)

if (-not $stopped -and $isExtension) {
	# 11a. BaseForm version
	$bfVersion = $baseFormNode.GetAttribute("version")
	if ($bfVersion) {
		Report-OK "BaseForm: version=$bfVersion"
	} else {
		Report-Warn "BaseForm: version attribute missing"
	}

	# 11b. callType values validation (Before, After, Override)
	$validCallTypes = @("Before", "After", "Override")
	$ctErrors = 0
	$ctChecked = 0

	# Check form-level events
	$formEventsNode = $root.SelectSingleNode("f:Events", $nsMgr)
	if ($formEventsNode) {
		foreach ($evt in $formEventsNode.SelectNodes("f:Event", $nsMgr)) {
			$ct = $evt.GetAttribute("callType")
			if ($ct) {
				$ctChecked++
				if ($validCallTypes -notcontains $ct) {
					Report-Error "Form event '$($evt.GetAttribute('name'))': invalid callType='$ct' (expected: Before, After, Override)"
					$ctErrors++
				}
			}
		}
	}

	# Check element-level events
	foreach ($el in $allElements) {
		if ($stopped) { break }
		$eventsNode = $el.Node.SelectSingleNode("f:Events", $nsMgr)
		if (-not $eventsNode) { continue }
		foreach ($evt in $eventsNode.SelectNodes("f:Event", $nsMgr)) {
			$ct = $evt.GetAttribute("callType")
			if ($ct) {
				$ctChecked++
				if ($validCallTypes -notcontains $ct) {
					Report-Error "[$($el.Tag)] '$($el.Name)' event '$($evt.GetAttribute('name'))': invalid callType='$ct'"
					$ctErrors++
				}
			}
		}
	}

	# Check command actions
	foreach ($cmd in $cmdNodes) {
		if ($stopped) { break }
		$cmdName = $cmd.GetAttribute("name")
		foreach ($action in $cmd.SelectNodes("f:Action", $nsMgr)) {
			$ct = $action.GetAttribute("callType")
			if ($ct) {
				$ctChecked++
				if ($validCallTypes -notcontains $ct) {
					Report-Error "Command '$cmdName' Action: invalid callType='$ct'"
					$ctErrors++
				}
			}
		}
	}

	if (-not $stopped -and $ctErrors -eq 0 -and $ctChecked -gt 0) {
		Report-OK "callType values: $ctChecked checked"
	}

	# 11c. Extension ID ranges — warn if extension-added attrs/commands have id < 1000000
	# Collect BaseForm attribute names to distinguish added ones
	$baseAttrNames = @{}
	$baseCmdNames = @{}
	$bfNs = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
	$bfNs.AddNamespace("f", "http://v8.1c.ru/8.3/xcf/logform")
	foreach ($bAttr in $baseFormNode.SelectNodes("f:Attributes/f:Attribute", $bfNs)) {
		$baName = $bAttr.GetAttribute("name")
		if ($baName) { $baseAttrNames[$baName] = $true }
	}
	foreach ($bCmd in $baseFormNode.SelectNodes("f:Commands/f:Command", $bfNs)) {
		$bcName = $bCmd.GetAttribute("name")
		if ($bcName) { $baseCmdNames[$bcName] = $true }
	}

	$idWarnCount = 0
	foreach ($attr in $attrNodes) {
		$aName = $attr.GetAttribute("name")
		$aId = $attr.GetAttribute("id")
		if ($aName -and -not $baseAttrNames.ContainsKey($aName) -and $aId) {
			try {
				$intId = [int]$aId
				if ($intId -lt 1000000) {
					Report-Warn "Attribute '$aName' (id=$aId): extension-added attribute has id < 1000000"
					$idWarnCount++
				}
			} catch {}
		}
	}

	foreach ($cmd in $cmdNodes) {
		$cName = $cmd.GetAttribute("name")
		$cId = $cmd.GetAttribute("id")
		if ($cName -and -not $baseCmdNames.ContainsKey($cName) -and $cId) {
			try {
				$intId = [int]$cId
				if ($intId -lt 1000000) {
					Report-Warn "Command '$cName' (id=$cId): extension-added command has id < 1000000"
					$idWarnCount++
				}
			} catch {}
		}
	}

	if (-not $stopped -and $idWarnCount -eq 0) {
		$extAttrCount = ($attrNodes | Where-Object { -not $baseAttrNames.ContainsKey($_.GetAttribute("name")) }).Count
		$extCmdCount = ($cmdNodes | Where-Object { -not $baseCmdNames.ContainsKey($_.GetAttribute("name")) }).Count
		if (($extAttrCount + $extCmdCount) -gt 0) {
			Report-OK "Extension ID ranges: $extAttrCount attr(s), $extCmdCount cmd(s) — all >= 1000000"
		}
	}
}

# Check callType without BaseForm (structural warning)
if (-not $stopped -and -not $isExtension) {
	$callTypeWithoutBase = $false
	$feNode = $root.SelectSingleNode("f:Events", $nsMgr)
	if ($feNode) {
		foreach ($evt in $feNode.SelectNodes("f:Event", $nsMgr)) {
			if ($evt.GetAttribute("callType")) { $callTypeWithoutBase = $true; break }
		}
	}
	if (-not $callTypeWithoutBase) {
		foreach ($cmd in $cmdNodes) {
			foreach ($action in $cmd.SelectNodes("f:Action", $nsMgr)) {
				if ($action.GetAttribute("callType")) { $callTypeWithoutBase = $true; break }
			}
			if ($callTypeWithoutBase) { break }
		}
	}
	if ($callTypeWithoutBase) {
		Report-Warn "callType attributes found but no BaseForm — possible incorrect structure"
	}
}

# --- Check 12: Type values validation ---

$knownInvalidTypes = @(
	"FormDataStructure","FormDataCollection","FormDataTree","FormDataTreeItem","FormDataCollectionItem"
	"FormGroup","FormField","FormButton","FormDecoration","FormTable"
)
$validClosedTypes = @(
	"xs:boolean","xs:string","xs:decimal","xs:dateTime","xs:binary"
	"v8:FillChecking","v8:Null","v8:StandardPeriod","v8:StandardBeginningDate","v8:Type"
	"v8:TypeDescription","v8:UUID","v8:ValueListType","v8:ValueTable","v8:ValueTree"
	"v8:Universal","v8:FixedArray","v8:FixedStructure"
	"v8ui:Color","v8ui:Font","v8ui:FormattedString","v8ui:HorizontalAlign"
	"v8ui:Picture","v8ui:SizeChangeMode","v8ui:VerticalAlign"
	"dcsset:DataCompositionComparisonType","dcsset:DataCompositionFieldPlacement"
	"dcsset:Filter","dcsset:SettingsComposer","dcsset:DataCompositionSettings"
	"dcssch:DataCompositionSchema"
	"dcscor:DataCompositionComparisonType","dcscor:DataCompositionGroupType"
	"dcscor:DataCompositionPeriodAdditionType","dcscor:DataCompositionSortDirection","dcscor:Field"
	"ent:AccountType","ent:AccumulationRecordType","ent:AccountingRecordType"
)
$validCfgPrefixes = @(
	"AccountingRegisterRecordSet","AccumulationRegisterRecordSet"
	"BusinessProcessObject","BusinessProcessRef"
	"CatalogObject","CatalogRef"
	"ChartOfAccountsObject","ChartOfAccountsRef"
	"ChartOfCalculationTypesObject","ChartOfCalculationTypesRef"
	"ChartOfCharacteristicTypesObject","ChartOfCharacteristicTypesRef"
	"ConstantsSet","DataProcessorObject","DocumentObject","DocumentRef"
	"DynamicList","EnumRef","ExchangePlanObject","ExchangePlanRef"
	"ExternalDataProcessorObject","ExternalReportObject"
	"ExternalDataSourceTableObject","ExternalDataSourceTableRecordManager"
	"ExternalDataSourceTableRef"
	"InformationRegisterRecordManager","InformationRegisterRecordSet"
	"ReportObject","TaskObject","TaskRef"
)

if (-not $stopped) {
	$typeNodes = $root.SelectNodes("//v8:Type", $nsMgr)
	$typeOk = $true
	$typeChecked = 0
	$typeInvalid = 0
	foreach ($tn in $typeNodes) {
		$tv = $tn.InnerText.Trim()
		if (-not $tv) { continue }
		$typeChecked++
		if ($tv -in $knownInvalidTypes) {
			Report-Error "12. Type '$tv': invalid runtime/UI type (not valid in XDTO schema)"
			$typeOk = $false; $typeInvalid++
			continue
		}
		if ($tv -in $validClosedTypes) { continue }
		if ($tv -match '^cfg:(.+)$') {
			$cfgVal = $Matches[1]
			# Тип без имени объекта: динамический список, набор констант, любой отчёт — ровно те три,
			# что встречаются в формах корпуса (УТ, ERP, БП, УНФ); иное без имени — вероятная опечатка
			if ($cfgVal -cin @("DynamicList", "ConstantsSet", "ReportObject")) { continue }
			if ($cfgVal -match '^([^.]+)\.') {
				$pfx = $Matches[1]
				if ($pfx -in $validCfgPrefixes) {
					# ExternalDataProcessorObject/ExternalReportObject valid only for EPF/ERF, not config
					if ($script:isConfigContext -and ($pfx -eq "ExternalDataProcessorObject" -or $pfx -eq "ExternalReportObject")) {
						Report-Error "12. Type '$tv': External* type in configuration context (use DataProcessorObject/ReportObject instead)"
						$typeOk = $false; $typeInvalid++
					}
					continue
				}
			}
			Report-Warn "12. Type '$tv': unrecognized cfg prefix"
			$typeOk = $false
			continue
		}
		if ($tv -match ':') { continue }
		Report-Warn "12. Type '$tv': bare type without namespace prefix"
		$typeOk = $false
	}
	if ($typeChecked -eq 0) {
		Report-OK "12. Types: no type values to check"
	} elseif ($typeOk) {
		Report-OK "12. Types: $typeChecked values, all valid"
	}
}

# --- Check 13: префиксы в значениях объявлены в самом файле ---
# `cfg:DataProcessorObject.X` в <v8:Type> при незадекларированном xmlns:cfg — валидный XML, который
# платформа не читает вовсе: «Исключение XDTO произошло при чтении файла». Ошибка типична для
# рукописного XML: префикс скопирован из чужой формы, а объявление в корне забыто. Область видимости
# считаем по узлу (GetNamespaceOfPrefix), а не по корню: локальная xmlns на элементе законна.

if (-not $stopped) {
	$prefixErrors = 0
	$prefixChecked = 0

	$prefixPattern = '^([A-Za-z_][A-Za-z0-9_.-]*):.+$'
	# Значения, где префикс обязан резолвиться: тип реквизита/колонки и xsi:type
	# Только листовые узлы: под local-name()='Type' подходит и обёртка <Type>, и вложенный <v8:Type>,
	# а InnerText обёртки — то же значение, иначе одна ошибка сообщалась бы дважды.
	foreach ($node in $xmlDoc.SelectNodes("//*[local-name()='Type' or local-name()='TypeSet']", $nsMgr)) {
		if ($node.SelectSingleNode("*")) { continue }
		$val = $node.InnerText.Trim()
		if (-not $val) { continue }
		$m = [regex]::Match($val, $prefixPattern)
		if (-not $m.Success) { continue }
		$prefixChecked++
		$pfx = $m.Groups[1].Value
		if (-not $node.GetNamespaceOfPrefix($pfx)) {
			Report-Error "13. Type '$val': namespace prefix '${pfx}:' is not declared — the platform cannot read the file (XDTO)"
			$prefixErrors++
		}
	}
	foreach ($node in $xmlDoc.SelectNodes("//*[@xsi:type]", $nsMgr)) {
		$val = $node.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
		$m = [regex]::Match($val, $prefixPattern)
		if (-not $m.Success) { continue }
		$prefixChecked++
		$pfx = $m.Groups[1].Value
		if (-not $node.GetNamespaceOfPrefix($pfx)) {
			Report-Error "13. xsi:type='$val': namespace prefix '${pfx}:' is not declared — the platform cannot read the file (XDTO)"
			$prefixErrors++
		}
	}

	if ($prefixChecked -eq 0) {
		Report-OK "13. Namespace prefixes: nothing to check"
	} elseif ($prefixErrors -eq 0) {
		Report-OK "13. Namespace prefixes: $prefixChecked values, all declared"
	}
}

# --- Check 14: версия формата формы — как у её дескриптора; сверка с выгрузкой ---
# Тело формы и дескриптор Forms/<Имя>.xml (у общей формы — CommonForms/<Имя>.xml) платформа загружает
# только в одной версии: «Версия формата загружаемого файла … отличается от версии формата ранее
# загруженных файлов». С остальной выгрузкой форма может расходиться — платформа такое грузит, это
# лишь неоднородность выгрузки (типично после мержа веток, выгруженных разными платформами).

if (-not $stopped) {
	$formVer = $root.GetAttribute("version")
	$formFull = (Resolve-Path $FormPath).ProviderPath
	$ownerPath = Get-ExtBodyOwner $formFull
	$ownerVer = if ($ownerPath) { Get-RootVersion $ownerPath } else { $null }
	$dumpVer = if ($script:dumpAnchor) { Get-RootVersion $script:dumpAnchor } else { $null }

	# У заимствованной формы расширения второй штамп — <BaseForm version=…>; платформа сверяет с дескриптором и его.
	$baseFormEl = $null
	foreach ($ch in $root.ChildNodes) { if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'BaseForm') { $baseFormEl = $ch; break } }
	$baseFormVer = if ($baseFormEl) { $baseFormEl.GetAttribute("version") } else { "" }

	if (-not $formVer) {
		Report-OK "14. Format version: not comparable"
	} elseif ($ownerVer -and $formVer -ne $ownerVer) {
		Report-Error "14. Format version $formVer differs from the form descriptor $([System.IO.Path]::GetFileName($ownerPath)) ($ownerVer) — the platform refuses to load parts of one object in different formats"
	} elseif ($ownerVer -and $baseFormVer -and $baseFormVer -ne $ownerVer) {
		Report-Error "14. <BaseForm> format version $baseFormVer differs from the form descriptor $([System.IO.Path]::GetFileName($ownerPath)) ($ownerVer) — the platform refuses to load parts of one object in different formats"
	} elseif ($dumpVer -and $formVer -ne $dumpVer) {
		Report-Warn "14. Format version $formVer differs from the dump ($dumpVer) — the platform loads it, but the dump is no longer uniform (typical after merging branches dumped by different platforms)"
	} elseif ($ownerVer -or $dumpVer) {
		Report-OK "14. Format version: $formVer, matches the descriptor and the dump"
	}
}


# --- Перечисления свойств формы (генерируется) ---
# Значения свойств-перечислений элементов формы и корня (ключ «Тип.Свойство» или общий «Свойство»).
# Источник — XSD xcf-logform 2.10–2.21, сверено с корпусом БП/ERP 8.3.24 (17036 форм, расхождений нет)
# и загрузкой в 8.3.24. Перегенерировать: python debug/form-dsl-revision/gen_enum_table.py
$script:validEnumValues = @{
	"ActionPurpose" = @("Usual","Create","Finish")
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
	"Command.CurrentRowUse" = @("Use","DontUse","Auto")
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
	"FillCheck" = @("DontCheck","ShowError")
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
	"ExtendedTooltip.HorizontalStretch" = @("true","false","auto")
	"InputField.HorizontalStretch" = @("true","false","auto")
	"LabelDecoration.HorizontalStretch" = @("true","false","auto")
	"LabelField.HorizontalStretch" = @("true","false","auto")
	"Page.HorizontalStretch" = @("true","false","auto")
	"Pages.HorizontalStretch" = @("true","false","auto")
	"PictureDecoration.HorizontalStretch" = @("true","false","auto")
	"Popup.HorizontalStretch" = @("true","false","auto")
	"RadioButtonField.HorizontalStretch" = @("true","false","auto")
	"SearchControlAddition.HorizontalStretch" = @("true","false","auto")
	"SearchStringAddition.HorizontalStretch" = @("true","false","auto")
	"UsualGroup.HorizontalStretch" = @("true","false","auto")
	"ViewStatusAddition.HorizontalStretch" = @("true","false","auto")
	"Importance" = @("Main","Normal","Supplementary")
	"IncompleteChoiceMode" = @("OnEnterPressed","OnActivate")
	"InitialListView" = @("Beginning","End","Auto")
	"InitialRowActivation" = @("Auto","Activate","NoActivate")
	"InitialTreeView" = @("NoExpand","ExpandTopLevel","ExpandAllLevels")
	"IntervalsSelectionMode" = @("Auto","Multiple","Single","None")
	"KeyType" = @("Auto","FieldValue","RowKey","RowNumber")
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
	"Command.Representation" = @("Text","Picture","TextPicture","Auto")
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
	"SelectedRowsUse" = @("Use","DontUse","Auto")
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
	"Button.Type" = @("CommandBarButton","UsualButton","Hyperlink","CommandBarHyperlink")
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
	"ExtendedTooltip.VerticalStretch" = @("true","false","auto")
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
# Старые имена значений, которые платформа принимает и переводит в современные (замер выгрузки 8.3.24)
$script:enumValueAliases = @{
	"TitlesLeftDataLeft" = "ItemsLeftTitlesLeft"
	"TitlesLeftDataRight" = "ItemsRightTitlesLeft"
	"TitlesRightDataLeft" = "ItemsLeftTitlesRight"
	"TitlesRightDataRight" = "ItemsRightTitlesRight"
	"GroupBox" = "StrongSeparation"
	"Margin" = "NormalSeparation"
	"Square" = "Rect"
}
# Умолчания: значение, которое платформа у этого типа не пишет (выброшено при загрузке-выгрузке 8.3.24
# и ни разу не встречается в корпусе) — тег с ним не пишется
$script:enumDefaultValues = @{
	"Attribute.FillCheck" = "DontCheck"
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
	"Column.FillCheck" = "DontCheck"
	"ColumnGroup.FixingInTable" = "None"
	"ColumnGroup.Group" = "Vertical"
	"ColumnGroup.GroupHorizontalAlign" = "Auto"
	"ColumnGroup.GroupVerticalAlign" = "Auto"
	"ColumnGroup.HeaderHorizontalAlign" = "Auto"
	"ColumnGroup.HorizontalStretch" = "auto"
	"ColumnGroup.ToolTipRepresentation" = "Auto"
	"ColumnGroup.VerticalStretch" = "auto"
	"Command.CurrentRowUse" = "Auto"
	"Command.Representation" = "Auto"
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
	"ExtendedTooltip.GroupHorizontalAlign" = "Auto"
	"ExtendedTooltip.GroupVerticalAlign" = "Auto"
	"ExtendedTooltip.HorizontalAlign" = "Left"
	"ExtendedTooltip.HorizontalStretch" = "auto"
	"ExtendedTooltip.OnMainServerUnavalableBehavior" = "Auto"
	"ExtendedTooltip.SkipOnInput" = "auto"
	"ExtendedTooltip.ToolTipRepresentation" = "Auto"
	"ExtendedTooltip.VerticalAlign" = "Auto"
	"ExtendedTooltip.VerticalStretch" = "auto"
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
	"SearchControlAddition.GroupHorizontalAlign" = "Auto"
	"SearchControlAddition.GroupVerticalAlign" = "Auto"
	"SearchControlAddition.HorizontalStretch" = "auto"
	"SearchControlAddition.PlacementArea" = "userCmds"
	"SearchControlAddition.ToolTipRepresentation" = "Auto"
	"SearchStringAddition.GroupHorizontalAlign" = "Auto"
	"SearchStringAddition.GroupVerticalAlign" = "Auto"
	"SearchStringAddition.HorizontalStretch" = "auto"
	"SearchStringAddition.PlacementArea" = "userCmds"
	"SearchStringAddition.ToolTipRepresentation" = "Auto"
	"Settings.KeyType" = "Auto"
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
	"ViewStatusAddition.GroupHorizontalAlign" = "Auto"
	"ViewStatusAddition.GroupVerticalAlign" = "Auto"
	"ViewStatusAddition.HorizontalLocation" = "Auto"
	"ViewStatusAddition.HorizontalStretch" = "auto"
	"ViewStatusAddition.PlacementArea" = "userCmds"
	"ViewStatusAddition.ToolTipRepresentation" = "Auto"
}
# Узлы, у которых проверяются и приводятся значения перечислений (тег узла)
$script:enumScopeTypes = @{
	'Attribute' = $true
	'AutoCommandBar' = $true
	'Button' = $true
	'ButtonGroup' = $true
	'CalendarField' = $true
	'ChartField' = $true
	'CheckBoxField' = $true
	'Column' = $true
	'ColumnGroup' = $true
	'Command' = $true
	'CommandBar' = $true
	'ContextMenu' = $true
	'ExtendedTooltip' = $true
	'Form' = $true
	'FormattedDocumentField' = $true
	'GanttChartField' = $true
	'GraphicalSchemaField' = $true
	'HTMLDocumentField' = $true
	'InputField' = $true
	'LabelDecoration' = $true
	'LabelField' = $true
	'Page' = $true
	'Pages' = $true
	'PeriodField' = $true
	'PictureDecoration' = $true
	'PictureField' = $true
	'PlannerField' = $true
	'Popup' = $true
	'ProgressBarField' = $true
	'RadioButtonField' = $true
	'SearchControlAddition' = $true
	'SearchStringAddition' = $true
	'Settings' = $true
	'SpreadSheetDocumentField' = $true
	'Table' = $true
	'TextDocumentField' = $true
	'TrackBarField' = $true
	'UsualGroup' = $true
	'ViewStatusAddition' = $true
}
# Значение из соседнего перечисления того же свойства → значение этого типа (ввод DSL; в XML — ошибка)
$script:enumInputSynonyms = @{
	"Command.Representation" = @{ "PictureAndText" = "TextPicture" }
	"Button.Representation" = @{ "TextPicture" = "PictureAndText" }
	"Popup.Representation" = @{ "TextPicture" = "PictureAndText" }
	"Table.SelectionMode" = @{ "Single" = "SingleRow"; "Multiple" = "MultiRow" }
	"CalendarField.SelectionMode" = @{ "SingleRow" = "Single"; "MultiRow" = "Multiple" }
}
# --- /Перечисления свойств формы ---

# Порядок дочерних тегов элемента (копия form-compile; держат check-enum-drift и check-inline-drift)
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
	'UsualGroup' = 'UserVisible Visible Enabled ReadOnly EnableContentChange Title TitleTextColor TitleFont ToolTip ToolTipRepresentation Shortcut Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign Group ChildrenAlign HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign Behavior CollapsedRepresentationTitle Collapsed ControlRepresentation Representation CurrentRowUse Format ShowLeftMargin United ChildItemsWidth ShowTitle BackColor ThroughAlign TitleDataPath ExtendedTooltip Events ChildItems'
}
$script:childRank = $null

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

# Вывод эмиттера (тег на строке, вложенность — табами) — в порядок корпуса: дети каждого элемента
# переставляются целыми блоками строк, содержимое блоков не меняется. Незнакомый тег идёт за
# предыдущим знакомым.

# Узлы формы с типом из $scope (вне <BaseForm> — его пишет платформа): корень, именованные узлы и
# настройки динамического списка (без имени — подпись по реквизиту; Settings у ValueList/Planner/Chart —
# не список). Перечисления проверяются по enumScopeTypes, порядок — по childTagOrder.
function Get-EnumCheckNodes([hashtable]$scope) {
	$out = @(@{ Node = $root; Type = 'Form'; Label = 'Form' })
	foreach ($n in $root.SelectNodes("//*[@name] | //*[local-name()='Settings'][@*[local-name()='type']='DynamicList']")) {
		if ($n.NamespaceURI -ne 'http://v8.1c.ru/8.3/xcf/logform') { continue }
		if (-not $scope.ContainsKey($n.LocalName)) { continue }
		if ($null -ne $n.SelectSingleNode("ancestor::*[local-name()='BaseForm']")) { continue }
		$label = if ($n.HasAttribute('name')) { "$($n.LocalName) '$($n.GetAttribute('name'))'" } else { "$($n.LocalName) of $($n.ParentNode.LocalName) '$($n.ParentNode.GetAttribute('name'))'" }
		$out += @{ Node = $n; Type = $n.LocalName; Label = $label }
	}
	return $out
}

# --- Check 15: значения свойств-перечислений ---
# Платформа читает перечисление по точному имени: значение в другом регистре или вне списка — ошибка
# загрузки XDTO. Старое имя (синоним) платформа примет и переведёт в современное — предупреждение.
if (-not $stopped) {
	$enumChecked = 0
	$check15Ok = $true
	foreach ($it in (Get-EnumCheckNodes $script:enumScopeTypes)) {
		if ($stopped) { break }
		$label = $it.Label
		foreach ($c in $it.Node.ChildNodes) {
			if ($c.NodeType -ne 'Element' -or $c.NamespaceURI -ne 'http://v8.1c.ru/8.3/xcf/logform') { continue }
			if ($c.SelectSingleNode("*") -or -not $c.InnerText) { continue }
			$prop = $c.LocalName
			$allowed = $script:validEnumValues["$($it.Type).$prop"]
			if (-not $allowed) { $allowed = $script:validEnumValues[$prop] }
			if (-not $allowed) { continue }
			$val = $c.InnerText
			$enumChecked++
			if ($script:enumValueAliases.ContainsKey($val) -and $allowed -ccontains $script:enumValueAliases[$val] -and $allowed -ccontains $val) {
				Report-Warn "15. $label`: $prop '$val' is an old name — the platform converts it to '$($script:enumValueAliases[$val])'"
			} elseif ($allowed -cnotcontains $val) {
				$hint = @($allowed | Where-Object { $_ -ieq $val })
				if ($hint.Count -gt 0) {
					Report-Error "15. $label`: $prop '$val' — wrong case, the platform will not load it; use '$($hint[0])'"
				} else {
					# Значение из соседнего перечисления (у кнопки PictureAndText, у команды TextPicture) — подсказать замену
					$syn = $script:enumInputSynonyms["$($it.Type).$prop"]
					$use = @(if ($syn) { $syn.Keys | Where-Object { $_ -ieq $val } | ForEach-Object { $syn[$_] } })
					if ($use.Count -gt 0) {
						Report-Error "15. $label`: $prop '$val' is not valid for $($it.Type), the platform will not load it; use '$($use[0])'"
					} else {
						Report-Error "15. $label`: $prop has invalid value '$val' (allowed: $($allowed -join ', '))"
					}
				}
				$check15Ok = $false
			}
		}
	}
	if ($check15Ok) { Report-OK "15. Enum values: $enumChecked checked" }
}

# --- Check 16: порядок свойств элемента ---
# Платформа пишет дочерние теги в своём порядке (таблица — по корпусу выгрузок). Чужой порядок она
# принимает и переставляет при выгрузке — предупреждение, а не ошибка.
if (-not $stopped) {
	$orderBad = 0
	foreach ($it in (Get-EnumCheckNodes $script:childTagOrder)) {
		if ($it.Type -eq 'Form') { continue }
		$prev = $null; $prevRank = -1
		foreach ($c in $it.Node.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			$r = Get-ChildRank $it.Type $c.LocalName
			if ($r -lt 0) { continue }
			if ($r -lt $prevRank) {
				Report-Warn "16. $($it.Type) '$($it.Node.GetAttribute('name'))': <$($c.LocalName)> stands after <$prev>, the platform writes it before — it reorders them on dump"
				$orderBad++
				break
			}
			$prev = $c.LocalName; $prevRank = $r
		}
	}
	if ($orderBad -eq 0) { Report-OK "16. Property order: matches the platform" }
}

# --- Check 17: настройки динамического списка в режиме совместимости ниже 8.3.19 ---
# Field / CalculatedField / Parameter списка такая конфигурация принимает при загрузке и хранит в
# базе, но в выгрузку XML не пишет — исходник с ними после выгрузки «теряет» их в диффе. Только для
# конфигурации: у внешней обработки режим базы на форму не влияет.
if (-not $stopped -and $script:isConfigContext) {
	$cfgText = [System.IO.File]::ReadAllText($script:dumpAnchor, [System.Text.Encoding]::UTF8)
	$cfgHead = $cfgText.Substring(0, [Math]::Min(65536, $cfgText.Length))
	# Расширение: своего CompatibilityMode нет, форму ведёт его собственный режим. В основной
	# конфигурации этот тег — режим для её расширений, не её собственный: только для расширения.
	$compatMode = if ($cfgHead -match '<CompatibilityMode>([^<]+)</CompatibilityMode>') { $Matches[1].Trim() }
		elseif ($cfgHead -match '<ConfigurationExtensionPurpose>' -and $cfgHead -match '<ConfigurationExtensionCompatibilityMode>([^<]+)</ConfigurationExtensionCompatibilityMode>') { $Matches[1].Trim() }
		else { '' }
	$compatRank = if ($compatMode -match '^Version(\d+)_(\d+)(?:_(\d+))?$') { [int]$Matches[1] * 10000 + [int]$Matches[2] * 100 + [int]$Matches[3] } else { 0 }
	if ($compatRank -gt 0 -and $compatRank -lt 80319) {
		$dynBad = 0
		foreach ($a in $attrNodes) {
			$st = $a.SelectSingleNode("f:Settings", $nsMgr)
			if (-not $st -or $st.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance") -ne 'DynamicList') { continue }
			if ($st.SelectSingleNode("f:Field|f:CalculatedField|f:Parameter", $nsMgr)) {
				Report-Warn "17. Dynamic list '$($a.GetAttribute('name'))': Field/CalculatedField/Parameter under compatibility mode $compatMode (< 8.3.19) are kept in the infobase but not written to the XML dump"
				$dynBad++
			}
		}
		if ($dynBad -eq 0) { Report-OK "17. Dynamic list settings: dumpable under $compatMode" }
	}
}

# --- Структура элементов формы (генерируется) ---
# Структура элементов формы: теги членов ChildItems (с версии формата), компаньоны по родителю, свойства типа.
# Источник — XSD xcf-logform 2.10–2.21, корпус БП/ERP и замер загрузки 8.3.24/8.3.27 (#130).
# Перегенерировать: python debug/form-dsl-revision/gen_structure_table.py
$script:formElementTags = @{
	'AutoCommandBar' = '2.10'
	'Button' = '2.10'
	'ButtonGroup' = '2.10'
	'CalendarField' = '2.10'
	'ChartField' = '2.10'
	'CheckBoxField' = '2.10'
	'ColumnGroup' = '2.10'
	'CommandBar' = '2.10'
	'ContextMenu' = '2.10'
	'DendrogramField' = '2.10'
	'FormattedDocumentField' = '2.10'
	'GanttChartField' = '2.10'
	'GeographicalSchemaField' = '2.10'
	'GraphicalSchemaField' = '2.10'
	'HTMLDocumentField' = '2.10'
	'InputField' = '2.10'
	'LabelDecoration' = '2.10'
	'LabelField' = '2.10'
	'PDFDocumentField' = '2.14'
	'Page' = '2.10'
	'Pages' = '2.10'
	'PeriodField' = '2.10'
	'PictureDecoration' = '2.10'
	'PictureField' = '2.10'
	'PlannerField' = '2.10'
	'Popup' = '2.10'
	'ProgressBarField' = '2.10'
	'RadioButtonField' = '2.10'
	'RowActionsPanel' = '2.21'
	'SearchControlAddition' = '2.10'
	'SearchStringAddition' = '2.10'
	'SelectedItemsActionsPanel' = '2.21'
	'SpreadSheetDocumentField' = '2.10'
	'Table' = '2.10'
	'TextDocumentField' = '2.10'
	'TrackBarField' = '2.10'
	'UsualGroup' = '2.10'
	'ViewStatusAddition' = '2.10'
}
# Опечатки XSD, которые платформа читает как каноничный тег
$script:formElementTagAliases = @{
	'LableDecoration' = 'LabelDecoration'
	'LableField' = 'LabelField'
}
$script:companionParents = @{
	'ContextMenu' = 'CalendarField ChartField CheckBoxField DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField ViewStatusAddition'
	'AutoCommandBar' = 'Table'
	'SearchStringAddition' = 'Table'
	'SearchControlAddition' = 'Table'
	'ViewStatusAddition' = 'PDFDocumentField Table'
	'RowActionsPanel' = 'AutoCommandBar Button ButtonGroup CalendarField ChartField CheckBoxField ColumnGroup CommandBar ContextMenu DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Page Pages PeriodField PictureDecoration PictureField PlannerField Popup ProgressBarField RadioButtonField RowActionsPanel SearchControlAddition SearchStringAddition SelectedItemsActionsPanel SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition'
	'SelectedItemsActionsPanel' = 'AutoCommandBar Button ButtonGroup CalendarField ChartField CheckBoxField ColumnGroup CommandBar ContextMenu DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Page Pages PeriodField PictureDecoration PictureField PlannerField Popup ProgressBarField RadioButtonField RowActionsPanel SearchControlAddition SearchStringAddition SelectedItemsActionsPanel SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition'
}
$script:containerTypes = 'AutoCommandBar ButtonGroup ColumnGroup CommandBar ContextMenu Page Pages Popup RowActionsPanel SearchControlAddition SelectedItemsActionsPanel Table UsualGroup'
# Контейнер → допустимые члены его ChildItems
$script:childItemsPlacement = @{
	'AutoCommandBar' = 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition'
	'ButtonGroup' = 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition'
	'ColumnGroup' = 'CheckBoxField ColumnGroup InputField LabelField PictureField'
	'CommandBar' = 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition'
	'ContextMenu' = 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition'
	'Form' = 'Button CalendarField ChartField CheckBoxField CommandBar DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Pages PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition'
	'Page' = 'Button CalendarField ChartField CheckBoxField CommandBar DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Pages PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition'
	'Pages' = 'Page'
	'Popup' = 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition'
	'SearchControlAddition' = 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition'
	'Table' = 'CheckBoxField ColumnGroup InputField LabelField PictureField'
	'UsualGroup' = 'Button CalendarField ChartField CheckBoxField CommandBar DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Pages PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition'
}
$script:elementPropertyTags = @{
	'AutoCommandBar' = 'AppearanceMode Autofill EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalAlign HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'Button' = 'AutoMaxHeight AutoMaxWidth BackColor BackPicture BackPictureEffect BorderColor ButtonImportance CardPictureAndTitleAlign Check CommandName CommandUniqueness DataPath DefaultButton DefaultItem Enabled Events Font GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch LocationInCommandBar MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior OnlyInAllActions Parameter Picture PictureHeight PictureLocation PlacementArea Representation RepresentationInContextMenu Shape ShapeRepresentation Shortcut ShowAsCard SkipOnInput TextColor Title TitleHeight ToolTipRepresentation Type UserVisible VerticalStretch Visible Width'
	'ButtonGroup' = 'CommandSource EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch PlacementArea ReadOnly Representation Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'CalendarField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BeginOfRepresentationPeriod Border BorderColor CalendarNavigation CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode EnableDrag EnableStartDrag Enabled EndOfRepresentationPeriod Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HeightInMonths HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly SelectionMode Shortcut ShowCurrentDate ShowInCard ShowInFooter ShowInHeader ShowMonthsPanel ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard WidthInMonths'
	'ChartField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'CheckBoxField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CheckBoxType CommandSet DataPath DefaultItem DisplayImportance EditFormat EditMode Enabled EqualItemsWidth Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture HorizontalAlign HorizontalStretch ItemHeight ItemTitleHeight ItemWidth MarkRequiredComplete OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor ThreeState Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TumblerRepresentation UserVisible VerticalAlign Visible WarningOnEdit WarningOnEditRepresentation WidthInCard'
	'ColumnGroup' = 'EnableContentChange Enabled Events FixInCard FixingInTable Group GroupHorizontalAlign GroupVerticalAlign HeaderDataPath HeaderFormat HeaderHorizontalAlign HeaderPicture Height HorizontalStretch ReadOnly Shortcut ShowInCard ShowInHeader ShowTitle ShowTitleInCard Title TitleBackColor TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'CommandBar' = 'AppearanceMode CommandSource EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalLocation HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'ContextMenu' = 'Autofill EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'DendrogramField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'FormattedDocumentField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'GanttChartField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch IntervalsSelectionMode MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowHorizontalLinesFlag ShowInCard ShowInFooter ShowInHeader ShowTitleInCard ShowVerticalLinesFlag SkipOnInput Table TableLocation Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible ValuesSelectionMode VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'GeographicalSchemaField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'GraphicalSchemaField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance Edit EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'HTMLDocumentField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'InputField' = 'AllowInputEmptyMultipleValues AllowMultipleValuesDuplicates AppearanceInCard AutoCapitalizationOnTextInput AutoCellHeight AutoChoiceIncomplete AutoCorrectionOnTextInput AutoEditMode AutoMarkIncomplete AutoMaxHeight AutoMaxWidth AutoShowClearButtonMode AutoShowOpenButtonMode AutoWidthInTable AutofillHint AvailableTypes BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark ChoiceButton ChoiceButtonPicture ChoiceButtonRepresentation ChoiceButtonTitle ChoiceFoldersAndItems ChoiceForm ChoiceHistoryOnInput ChoiceList ChoiceListButton ChoiceListHeight ChoiceParameterLinks ChoiceParameters ChooseType ClearButton CommandSet CreateButton DataPath DefaultItem DisplayImportance DropListButton DropListHint DropListWidth EditFormat EditMode EditTextUpdate Enabled Events ExtendedEdit ExtendedEditMultipleValues FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor Format GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HeightControlVariant HorizontalAlign HorizontalStretch IncompleteChoiceMode InputHint ListChoiceMode MarkNegatives MarkRequiredComplete Mask MaxHeight MaxValue MaxWidth MinValue MinWidth MultiLine MultipleValueDataPath MultipleValuePictureDataPath MultipleValuePictureShape MultipleValuePictureSize MultipleValuePresentDataPath MultipleValuesBackColor MultipleValuesFont MultipleValuesHyperlink MultipleValuesPicture MultipleValuesTextColor OnMainServerUnavalableBehavior OnScreenKeyboardReturnKeyText OpenButton PasswordMode Picture QuickChoice ReadOnly Shortcut ShowCheckBoxesInDropList ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput SpecialTextInputMode SpellCheckingOnTextInput SpinButton TextColor TextEdit TextSize TimeChoiceMode Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TypeDomainEnabled TypeLink UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard Wrap'
	'LabelDecoration' = 'AutoMaxHeight AutoMaxWidth BackColor Border BorderColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign Height HorizontalAlign HorizontalStretch Hyperlink MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Shortcut SkipOnInput TextColor Title TitleHeight ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible Width'
	'LabelField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackColor Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor Format GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height Hiperlink HorizontalAlign HorizontalStretch MarkNegatives MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior PasswordMode ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UseCopy UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'PDFDocumentField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet CurrentPageNumber DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Orientation Output ReadOnly Scale Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch ViewStatusLocation Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'Page' = 'BackColor ChildItemsTitleLocation ChildItemsWidth ChildrenAlign EnableContentChange Enabled Events Format Group GroupHorizontalAlign GroupVerticalAlign Height HorizontalAlign HorizontalSpacing HorizontalStretch Picture ReadOnly ScrollOnCompress Shortcut ShowTitle Title TitleDataPath TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalSpacing VerticalStretch Visible Width'
	'Pages' = 'AssociatedTableElementId CurrentRowUse EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch PagesRepresentation ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'PeriodField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'PictureDecoration' = 'AutoMaxHeight AutoMaxWidth BackgroundShowMode Border BorderColor EnableDrag EnableStartDrag Enabled Events FileDragMode Font GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch Hyperlink ImageScale MaxHeight MaxWidth MinWidth NonselectedPictureText OnMainServerUnavalableBehavior Picture PictureColor PictureSize Shortcut SkipOnInput TextColor Title ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width Zoomable'
	'PictureField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackgroundShowMode Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode EnableDrag EnableStartDrag Enabled Events FileDragMode FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch Hyperlink ImageScale MarkRequiredComplete MaxHeight MaxWidth MinWidth NonselectedPictureText OnMainServerUnavalableBehavior PictureColor PictureSize ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible ValuesPicture VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard Zoomable'
	'PlannerField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DimensionItemHyperlink DisplayImportance EditMode EnableDrag EnableStartDrag Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TimeScaleItemHyperlink Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard WrappedTimeScaleHeaderHyperlink'
	'Popup' = 'BackColor BorderColor CommandSource EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch Importance Picture PlacementArea ReadOnly Representation Shape ShapeRepresentation Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'ProgressBarField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxValue MaxWidth MinValue MinWidth OnMainServerUnavalableBehavior Orientation ReadOnly Representation Shortcut ShowInCard ShowInFooter ShowInHeader ShowPercent ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'RadioButtonField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark ChoiceList ColumnsCount CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled EqualColumnsWidth Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture HorizontalAlign HorizontalStretch ItemHeight ItemTitleHeight ItemWidth MarkRequiredComplete OnMainServerUnavalableBehavior Orientation RadioButtonType ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TumblerRepresentation UserVisible VerticalAlign Visible WarningOnEdit WarningOnEditRepresentation WidthInCard'
	'RowActionsPanel' = 'AppearanceMode EnableContentChange Enabled Events FillStdCommands GroupHorizontalAlign GroupVerticalAlign HAlign Height HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'SearchControlAddition' = 'AdditionSource AutoMaxWidth BackColor BorderColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign HorizontalStretch MaxWidth MinWidth PlacementArea Source TextColor Title ToolTip ToolTipRepresentation UserVisible Visible Width'
	'SearchStringAddition' = 'AdditionSource AutoMaxWidth BackColor BorderColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign HorizontalStretch MaxWidth MinWidth PlacementArea Source TextColor Title ToolTip ToolTipRepresentation UserVisible Visible Width'
	'SelectedItemsActionsPanel' = 'AppearanceMode EnableContentChange Enabled Events FillStdCommands GroupHorizontalAlign GroupVerticalAlign HAlign Height HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width'
	'SpreadSheetDocumentField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BlackAndWhiteView BorderColor CellActionsButtonViewMode CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance DrawingSelectionShowMode Edit EditMode EnableDrag EnableStartDrag Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalScrollBar HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output PointerType Protection ReadOnly SelectionShowMode Shortcut ShowCellNames ShowGrid ShowGroups ShowHeaders ShowInCard ShowInFooter ShowInHeader ShowRowAndColumnNames ShowTitleInCard SkipOnInput SpreadsheetDocumentMultipleSelectionPanelViewMode Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalScrollBar VerticalStretch ViewScalingMode Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'Table' = 'AllowGettingCurrentRowURL AllowRootChoice AutoAddIncomplete AutoInsertNewRow AutoMarkIncomplete AutoMaxCardHeight AutoMaxHeight AutoMaxRowsCount AutoMaxWidth AutoRefresh AutoRefreshPeriod Autofill BackColor BehaviorOnHorizontalCompression BorderColor CardBehaviorOnVerticalCompression CellHyperlinksRepresentation ChangeRowOrder ChangeRowSet ChoiceFoldersAndItems ChoiceMode CommandBarLocation CommandSet ComplexSettingsViewMode CurrentRowUse DataPath DefaultItem EnableDrag EnableStartDrag Enabled Events FileDragMode FixedLeft FixedRight Font Footer FooterHeight GroupHorizontalAlign GroupVerticalAlign Header HeaderHeight Height HeightControlVariant HeightInTableRows HierarchyPanelLocation HorizontalLines HorizontalLinesBWA HorizontalScrollBar HorizontalStretch IconSaveColorsKey InitialListView InitialRowActivation InitialTreeView MarkRequiredComplete MaxCardHeight MaxHeight MaxRowsCount MaxWidth MinWidth MobileDeviceTableType MultipleChoice OnMainServerUnavalableBehavior Output Period ReadOnly RefreshRequest Representation RestoreCurrentRow RowActionsShowType RowFilter RowInputMode RowPictureDataPath RowSelectionMode RowsPicture SaveColors SearchControlLocation SearchOnInput SearchStringLocation SelectionMode SettingsNamedItemDetailedRepresentation ShapeSaveColorsKey Shortcut ShowCommandBar ShowRoot SkipOnInput TextColor Title TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TopLevelParent TreeSpecialSearch UpdateOnDataChange UseAlternationRowColor UseAlternationRowColorBWA UserSettingsGroup UserVisible VerticalLines VerticalLinesBWA VerticalScrollBar VerticalStretch ViewMode ViewStatusLocation Visible Width'
	'TextDocumentField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'TrackBarField' = 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch LargeStep MarkRequiredComplete MarkingAppearance MarkingStep MaxHeight MaxValue MaxWidth MinValue MinWidth OnMainServerUnavalableBehavior Orientation ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Step Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard'
	'UsualGroup' = 'AssociatedTableElementId BackColor BackPicture BackPictureEffect Behavior CardRepresentationType ChildItemsTitleLocation ChildItemsWidth ChildrenAlign Collapsed CollapsedRepresentationItem CollapsedRepresentationTitle ControlRepresentation CurrentRowUse EnableContentChange Enabled Events Format Group GroupHorizontalAlign GroupVerticalAlign Height HiddenStateTitleBackColor HorizontalAlign HorizontalSpacing HorizontalStretch Hyperlink ReadOnly Representation ScrollOnCompress Shortcut ShowAsCard ShowLeftMargin ShowTitle ThroughAlign Title TitleDataPath TitleFont TitleTextColor ToolTip ToolTipRepresentation United UserVisible VerticalAlign VerticalSpacing VerticalStretch Visible Width'
	'ViewStatusAddition' = 'AdditionSource AutoMaxWidth BackColor Border BorderColor ButtonColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign HorizontalLocation HorizontalStretch MaxWidth MinWidth PlacementArea Source TextColor Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible Visible Width'
}
# --- /Структура элементов формы ---

# Члены ChildItems вне <BaseForm> (его пишет платформа) — элементы формы, командных панелей и меню
function Get-ChildItemsMembers {
	return @($root.SelectNodes("//f:ChildItems/*[not(ancestor::*[local-name()='BaseForm'])]", $nsMgr))
}
$script:companionTags = @($script:companionParents.Keys)
# Списки таблиц — множества с точным регистром, разобранные один раз (ключ ищется только каноничный)
function ConvertTo-SetTable([hashtable]$table) {
	$out = @{}
	foreach ($k in $table.Keys) { $out[$k] = [System.Collections.Generic.HashSet[string]]::new([string[]]($table[$k] -split ' '), [StringComparer]::Ordinal) }
	return $out
}
$companionParentSets = ConvertTo-SetTable $script:companionParents
$propertySets = ConvertTo-SetTable $script:elementPropertyTags
$placementSets = ConvertTo-SetTable $script:childItemsPlacement

# --- Check 18: тег элемента формы ---
# Тег члена ChildItems — из словаря формата (XSD logform) и не новее версии формата формы.
$members = @(if (-not $stopped) { Get-ChildItemsMembers })
$memberTypes = @{}   # узел → каноничный тег (для 19/20; незнакомые теги не проверяются дальше)
if (-not $stopped) {
	$check18Ok = $true
	$formRank = Get-FormatRank $root.GetAttribute("version")
	foreach ($m in $members) {
		if ($stopped) { break }
		$tag = $m.LocalName
		$label = if ($m.HasAttribute('name')) { "<$tag> '$($m.GetAttribute('name'))'" } elseif ($m.HasAttribute('id')) { "<$tag> id=$($m.GetAttribute('id'))" } else { "<$tag>" }
		# Без name/id платформа загружает элемент с пустым именем / id=0
		$missing = @(foreach ($a in 'name', 'id') { if (-not $m.GetAttribute($a)) { $a } })
		if ($missing.Count -gt 0) {
			Report-Error "18. $label`: missing $($missing -join ' and ') attribute$(if ($missing.Count -gt 1) { 's' })"
			$check18Ok = $false
		}
		$known = if ($script:formElementTags.Keys -ccontains $tag) { $tag } else { $null }
		$alias = if ($script:formElementTagAliases.Keys -ccontains $tag) { $tag } else { $null }
		if ($known) {
			$since = $script:formElementTags[$known]
			if ($formRank -gt 0 -and (Get-FormatRank $since) -gt $formRank) {
				Report-Error "18. $label`: not available in format $($root.GetAttribute('version')) (since $since)"
				$check18Ok = $false
			} else {
				$memberTypes[$m] = $known
			}
		} elseif ($alias) {
			Report-Warn "18. $label is an old name — the platform reads it as <$($script:formElementTagAliases[$alias])>"
			$memberTypes[$m] = $script:formElementTagAliases[$alias]
		} else {
			$hint = @($script:formElementTags.Keys | Where-Object { $_ -ieq $tag })[0]
			if (-not $hint) { $hint = @($script:formElementTagAliases.Keys | Where-Object { $_ -ieq $tag } | ForEach-Object { $script:formElementTagAliases[$_] })[0] }
			if ($hint) {
				Report-Error "18. $label`: wrong case, use <$hint>"
			} else {
				Report-Error "18. $label is not a form element type"
			}
			$check18Ok = $false
		}
	}
	if ($check18Ok) { Report-OK "18. Element types: $($members.Count) checked" }
}

# --- Check 19: компаньоны элемента ---
# Контекстное меню, командная панель и дополнения таблицы бывают только у своих типов; каждый — один.
if (-not $stopped) {
	$check19Ok = $true
	foreach ($m in $members) {
		if ($stopped) { break }
		if (-not $memberTypes.ContainsKey($m)) { continue }
		$type = $memberTypes[$m]
		$seen = @{}
		foreach ($c in $m.ChildNodes) {
			if ($c.NodeType -ne 'Element' -or $c.NamespaceURI -ne 'http://v8.1c.ru/8.3/xcf/logform') { continue }
			$ct = $c.LocalName
			if ($ct -cne 'ExtendedTooltip' -and $script:companionTags -cnotcontains $ct) { continue }
			if ($seen.ContainsKey($ct)) {
				Report-Error "19. $type '$($m.GetAttribute('name'))': duplicate <$ct>"
				$check19Ok = $false
				continue
			}
			$seen[$ct] = $true
			if ($ct -ceq 'ExtendedTooltip') { continue }
			if (-not $companionParentSets[$ct].Contains($type)) {
				Report-Error "19. $type '$($m.GetAttribute('name'))' cannot have <$ct>"
				$check19Ok = $false
			}
		}
	}
	if ($check19Ok) { Report-OK "19. Companions: match element types" }
}

# --- Check 20: свойства элемента ---
# Дочерний тег — свойство своего типа (корпус выгрузок ∪ XSD); ChildItems — только у контейнеров.
if (-not $stopped) {
	$check20Ok = $true
	$containers = $script:containerTypes -split ' '
	foreach ($m in $members) {
		if ($stopped) { break }
		if (-not $memberTypes.ContainsKey($m)) { continue }
		$type = $memberTypes[$m]
		$allowed = $propertySets[$type]
		foreach ($c in $m.ChildNodes) {
			if ($c.NodeType -ne 'Element' -or $c.NamespaceURI -ne 'http://v8.1c.ru/8.3/xcf/logform') { continue }
			$pt = $c.LocalName
			if ($pt -ceq 'ExtendedTooltip' -or $script:companionTags -ccontains $pt) { continue }
			if ($pt -ceq 'ChildItems') {
				if ($containers -cnotcontains $type) {
					Report-Error "20. $type '$($m.GetAttribute('name'))' cannot have <ChildItems>"
					$check20Ok = $false
				}
				continue
			}
			if ($null -eq $allowed -or $allowed.Contains($pt)) { continue }
			$hint = @($allowed | Where-Object { $_ -ieq $pt } | Sort-Object)
			if ($hint.Count -gt 0) {
				Report-Warn "20. $type '$($m.GetAttribute('name'))': <$pt> — wrong case, use <$($hint[0])>"
			} else {
				Report-Warn "20. $type '$($m.GetAttribute('name'))': <$pt> is not a property of $type"
			}
			$check20Ok = $false
		}
	}
	if ($check20Ok) { Report-OK "20. Element properties: match element types" }
}

# --- Check 21: размещение элемента в контейнере ---
# Что можно положить в контейнер — по правилам редактора форм (их отпечаток — корпус выгрузок):
# в Pages — только страницы, колонка таблицы — поле или группа колонок, подменю и группа кнопок —
# только в командной панели. Платформа такое загружает, поэтому предупреждение.
if (-not $stopped) {
	$check21Ok = $true
	foreach ($m in $members) {
		if ($stopped) { break }
		if (-not $memberTypes.ContainsKey($m)) { continue }
		$owner = $m.ParentNode.ParentNode
		# Владелец — элемент (каноничный тег) или компаньон (ContextMenu, AutoCommandBar) — тег как есть,
		# но только точного регистра: @{} PS регистронезависим, а владелец с неверным тегом уже ошибка 18
		$ownerType = if ($owner -eq $root) { 'Form' } elseif ($memberTypes.ContainsKey($owner)) { $memberTypes[$owner] }
			elseif ($script:childItemsPlacement.Keys -ccontains $owner.LocalName) { $owner.LocalName } else { $null }
		if (-not $ownerType -or -not $placementSets.ContainsKey($ownerType)) { continue }
		if ($placementSets[$ownerType].Contains($memberTypes[$m])) { continue }
		$where = if ($ownerType -eq 'Form') { 'the form' } else { "$ownerType '$($owner.GetAttribute('name'))'" }
		Report-Warn "21. $($memberTypes[$m]) '$($m.GetAttribute('name'))' cannot be placed in $where"
		$check21Ok = $false
	}
	if ($check21Ok) { Report-OK "21. Element placement: match containers" }
}

# --- Check 23: источник дополнения ---
# Источник строки поиска, состояния просмотра и управления поиском — таблица (у состояния просмотра
# ещё поле PDF). Несуществующий Item платформа молча выбрасывает вместе со связью; остальное загружает
# как есть, но в выгрузках такого не бывает. Отсутствие AdditionSource законно (у компаньона платформа
# восстанавливает его сама).
if (-not $stopped) {
	$check23Ok = $true
	$additionTypes = @{ 'SearchStringAddition' = 'SearchStringRepresentation'; 'ViewStatusAddition' = 'ViewStatusRepresentation'; 'SearchControlAddition' = 'SearchControl' }
	$typeByName = @{}
	# Все именованные члены: элемент с неверным тегом (ошибка 18) всё же есть в форме, его тип — $null
	foreach ($m in $members) {
		$n = $m.GetAttribute('name')
		if ($n -and -not $typeByName.ContainsKey($n)) { $typeByName[$n] = if ($memberTypes.ContainsKey($m)) { $memberTypes[$m] } else { $null } }
	}
	$additions = @(foreach ($m in $members) {
		if (-not $memberTypes.ContainsKey($m)) { continue }
		if ($additionTypes.ContainsKey($memberTypes[$m])) { @{ Node = $m; Tag = $memberTypes[$m]; Owner = $null } }
		foreach ($c in $m.ChildNodes) {
			if ($c.NodeType -ne 'Element' -or $c.NamespaceURI -ne 'http://v8.1c.ru/8.3/xcf/logform') { continue }
			if ($additionTypes.Keys -ccontains $c.LocalName) { @{ Node = $c; Tag = $c.LocalName; Owner = $m.GetAttribute('name') } }
		}
	})
	foreach ($a in $additions) {
		if ($stopped) { break }
		$src = $a.Node.SelectSingleNode("f:AdditionSource", $nsMgr)
		if (-not $src) { continue }
		$label = "$($a.Tag) '$($a.Node.GetAttribute('name'))'"
		$itemNode = $src.SelectSingleNode("f:Item", $nsMgr)
		$item = if ($itemNode) { $itemNode.InnerText.Trim() } else { '' }
		if (-not $item) {
			Report-Error "23. ${label}: source item is empty"
			$check23Ok = $false
			continue
		}
		if (-not $typeByName.ContainsKey($item)) {
			Report-Error "23. ${label}: source item '$item' not found in the form — the platform drops the link on load"
			$check23Ok = $false
			continue
		}
		$itemType = $typeByName[$item]
		$sources = if ($a.Tag -eq 'ViewStatusAddition') { @('Table', 'PDFDocumentField') } else { @('Table') }
		if ($null -ne $itemType -and $sources -cnotcontains $itemType) {
			Report-Warn "23. ${label}: source item '$item' is $itemType, expected $($sources -join ' or ')"
			$check23Ok = $false
		} elseif ($a.Owner -and $item -ne $a.Owner) {
			Report-Warn "23. ${label}: source item '$item' is not its owner '$($a.Owner)'"
			$check23Ok = $false
		}
		$typeNode = $src.SelectSingleNode("f:Type", $nsMgr)
		$srcType = if ($typeNode) { $typeNode.InnerText.Trim() } else { '' }
		if ($srcType -cne $additionTypes[$a.Tag]) {
			Report-Warn "23. ${label}: source type '$srcType' does not match the addition, expected $($additionTypes[$a.Tag])"
			$check23Ok = $false
		}
	}
	if ($check23Ok) { Report-OK "23. Addition sources: match items" }
}

# --- Check 22: обработчики — модуль формы ---
# Привязки Form.xml (события, действия команд) сверяются с процедурами модуля <каталог Form.xml>/Form/Module.bsl.
# Читается только модуль формы: общие модули, которые подключают процедуры формы по имени, не смотрим —
# поэтому процедура без привязки только предупреждение.
# Текст модуля формы; $null — модуль не в UTF-8 (с заменой символов имена процедур не найти — лучше сказать прямо)
function Read-ModuleText([string]$path) {
	try { return (New-Object System.Text.UTF8Encoding($false, $true)).GetString([System.IO.File]::ReadAllBytes($path)).TrimStart([char]0xFEFF) }
	catch { return $null }
}

# Сканер BSL: строковые литералы (с "" и многострочными продолжениями «|») и комментарии // отделяются
# от кода, номера строк сохраняются. Lines — строки текста; Code — они же без комментариев, литерал
# заменён на ""; Mask — строки той же длины, литералы и комментарии — пробелами (позиции в маске —
# позиции в тексте); Literals — @{ Line; Text; Prefix — код этой строки слева от литерала; Col — начало
# текста литерала в строке, -1 у многострочного }.
function Get-BslScan([string]$text) {
	$lines = $text -replace "`r", "" -split "`n"
	$code = New-Object System.Collections.ArrayList
	$mask = New-Object System.Collections.ArrayList
	$lits = New-Object System.Collections.ArrayList
	$inStr = $false; $cur = $null; $curLine = 0; $curPrefix = ""; $curCol = -1
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$line = $lines[$i]
		# строка без кавычек вне литерала — только отрезать комментарий (посимвольный разбор в PS медленный)
		if (-not $inStr -and $line.IndexOf('"') -lt 0) {
			$k = $line.IndexOf('//')
			[void]$code.Add($(if ($k -ge 0) { $line.Substring(0, $k) } else { $line }))
			[void]$mask.Add($(if ($k -ge 0) { $line.Substring(0, $k) + (' ' * ($line.Length - $k)) } else { $line }))
			continue
		}
		$sb = New-Object System.Text.StringBuilder
		$mk = $line.ToCharArray()
		$j = 0
		if ($inStr) {
			# продолжение многострочного литерала: пробелы, затем «|»
			while ($j -lt $line.Length -and ($line[$j] -eq ' ' -or $line[$j] -eq "`t")) { $j++ }
			# строка «//…» между строками литерала — комментарий, литерал продолжается на следующей
			if ($j + 1 -lt $line.Length -and $line[$j] -eq '/' -and $line[$j + 1] -eq '/') { [void]$code.Add(""); [void]$mask.Add(' ' * $line.Length); continue }
			if ($j -lt $line.Length -and $line[$j] -eq '|') { $mk[$j] = ' '; $j++ }
			$cur += "`n"
			$curCol = -1
		}
		while ($j -lt $line.Length) {
			$c = $line[$j]
			if ($inStr) {
				if ($c -eq '"') {
					if ($j + 1 -lt $line.Length -and $line[$j + 1] -eq '"') { $cur += '"'; $mk[$j] = ' '; $mk[$j + 1] = ' '; $j += 2; continue }
					$inStr = $false
					[void]$lits.Add(@{ Line = $curLine; Text = $cur; Prefix = $curPrefix; Col = $curCol })
					[void]$sb.Append('""')
					$j++
					continue
				}
				$cur += $c; $mk[$j] = ' '; $j++; continue
			}
			if ($c -eq '/' -and $j + 1 -lt $line.Length -and $line[$j + 1] -eq '/') { for ($q = $j; $q -lt $mk.Length; $q++) { $mk[$q] = ' ' }; break }
			if ($c -eq '"') { $inStr = $true; $cur = ""; $curLine = $i + 1; $curPrefix = $sb.ToString(); $curCol = $j + 1; $j++; continue }
			[void]$sb.Append($c); $j++
		}
		[void]$code.Add($sb.ToString())
		[void]$mask.Add([string]::new($mk))
	}
	return @{ Lines = $lines; Code = $code.ToArray(); Mask = $mask.ToArray(); Literals = $lits.ToArray() }
}

# Процедуры и функции модуля (имя, первая и последняя строка; первая — с аннотациями над заголовком)
# и области (имя, строки #Область и #КонецОбласти, вложенность). Строки нумеруются с 1.
# Заголовок — только в начале строки: продолжение литерала («|…») и комментарий заголовком не станут.
function Get-ModuleOutline([string[]]$lines) {
	$procs = New-Object System.Collections.ArrayList
	$regions = New-Object System.Collections.ArrayList
	$open = New-Object System.Collections.ArrayList
	$cur = $null
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$l = $lines[$i]
		if ($null -ne $cur) {
			# конец процедуры — в начале строки или после «;» (`Возврат Х;КонецФункции`)
			if ($l -match '(^|;)\s*(КонецПроцедуры|КонецФункции|EndProcedure|EndFunction)(?![\w])') { $cur.end = $i + 1; [void]$procs.Add($cur); $cur = $null }
			continue
		}
		$m = [regex]::Match($l, '^\s*(?:(?:Асинх|Async)\s+)?(?:Процедура|Функция|Procedure|Function)\s+(\w+)\s*\(', 'IgnoreCase')
		if ($m.Success) {
			$s = $i
			while ($s -gt 0 -and $lines[$s - 1] -match '^\s*&') { $s-- }
			$cur = [pscustomobject]@{ name = $m.Groups[1].Value; start = $s + 1; end = $i + 1 }
			continue
		}
		$m = [regex]::Match($l, '^\s*#(?:Область|Region)\s+(\S+)', 'IgnoreCase')
		if ($m.Success) { [void]$open.Add([pscustomobject]@{ name = $m.Groups[1].Value; start = $i + 1; end = 0; depth = $open.Count }); continue }
		if ($l -match '^\s*#(КонецОбласти|EndRegion)(?![\w])' -and $open.Count -gt 0) {
			$r = $open[$open.Count - 1]; $open.RemoveAt($open.Count - 1)
			$r.end = $i + 1; [void]$regions.Add($r)
		}
	}
	return @{ procs = $procs; regions = $regions }
}

# Литерал в позиции имени обработчика, собранного склейкой: ПодключитьОбработчикОжидания(X, …),
# Новый ОписаниеОповещения(X, …), УстановитьДействие(Событие, X), .Действие = X — по коду строки слева от литерала.
$script:handlerArgPrefix = '(?:(?:ПодключитьОбработчикОжидания|AttachIdleHandler|ОписаниеОповещения|NotifyDescription)\s*\((?<a>[^,]*)|(?:УстановитьДействие|SetAction)\s*\([^,]*,(?<a>[^,]*)|\.(?:Действие|Action)\s*=(?<a>[^;]*))$'

if (-not $stopped) {
	$modulePath = Join-Path (Split-Path (Resolve-Path $FormPath).ProviderPath -Parent) "Form/Module.bsl"
	$moduleText = if (Test-Path -LiteralPath $modulePath) { Read-ModuleText $modulePath } else { $null }
	if (-not (Test-Path -LiteralPath $modulePath)) {
		Report-OK "22. Form module handlers: no module — skipped"
	} elseif ($null -eq $moduleText) {
		Report-Warn "22. Form module is not UTF-8 — handlers are not checked"
	} else {
		$bsl = Get-BslScan $moduleText
		$outline = Get-ModuleOutline $bsl.Code
		# @{} регистронезависим — как имена в BSL
		$procs = @{}
		foreach ($p in $outline.procs) { if (-not $procs.ContainsKey($p.name)) { $procs[$p.name] = $p } }
		$bound = @{}
		$check22Ok = $true
		$guidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

		# Привязка без процедуры. Событие с GUID вместо имени — событие объекта, которого у основного реквизита
		# формы нет: платформа его хранит, но не вызывает. В форме расширения привязка без callType — исходной
		# формы, её процедура в модуле конфигурации.
		foreach ($evt in $root.SelectNodes(".//f:Events/f:Event[not(ancestor::f:BaseForm)]", $nsMgr)) {
			if ($stopped) { break }
			$h = $evt.InnerText.Trim()
			if (-not $h) { continue }
			$bound[$h] = $true
			$evtName = $evt.GetAttribute('name')
			if ($evtName -match $guidRx) { continue }
			if ($hasBaseForm -and -not $evt.GetAttribute('callType')) { continue }
			if ($procs.ContainsKey($h)) { continue }
			$owner = $evt.ParentNode.ParentNode
			$what = if ($owner -eq $root) { "Form event '$evtName'" } else { "Event '$evtName' of $($owner.LocalName) '$($owner.GetAttribute('name'))'" }
			Report-Error "22. ${what}: handler '$h' not found in the form module"
			$check22Ok = $false
		}
		foreach ($cmd in $cmdNodes) {
			if ($stopped) { break }
			foreach ($act in $cmd.SelectNodes("f:Action", $nsMgr)) {
				$h = $act.InnerText.Trim()
				if (-not $h) { continue }
				$bound[$h] = $true
				if ($hasBaseForm -and -not $act.GetAttribute('callType')) { continue }
				if ($procs.ContainsKey($h)) { continue }
				Report-Error "22. Command '$($cmd.GetAttribute('name'))': action '$h' not found in the form module"
				$check22Ok = $false
			}
		}

		# Процедура без привязки. Не висячая: экспортная, с аннотацией расширения, Подключаемый_* (их подключает
		# БСП), имя в коде модуля или равно литералу, имя оканчивается куском склейки в позиции обработчика.
		$lits = @{}
		$tails = New-Object System.Collections.ArrayList
		foreach ($l in $bsl.Literals) {
			$t = "$($l.Text)".Trim()
			if (-not $t) { continue }
			$lits[$t] = $true
			$m = [regex]::Match($l.Prefix, $script:handlerArgPrefix, 'IgnoreCase')
			if ($m.Success -and $m.Groups['a'].Value.Contains('+')) { [void]$tails.Add($t) }
		}
		# слова кода — один проход: поиск имени по всему модулю для каждой процедуры на больших модулях долог
		$wordCount = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
		foreach ($w in [regex]::Split(($bsl.Code -join "`n"), '\W+')) {
			if (-not $w) { continue }
			$c = 0; [void]$wordCount.TryGetValue($w, [ref]$c); $wordCount[$w] = $c + 1
		}
		foreach ($p in $outline.procs) {
			if ($stopped) { break }
			$n = $p.name
			if ($bound.ContainsKey($n) -or $lits.ContainsKey($n)) { continue }
			if ($n.StartsWith('Подключаемый_', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
			$k = $p.start - 1
			$ann = @()
			while ($k -lt $p.end - 1 -and $bsl.Code[$k] -match '^\s*&') { $ann += $bsl.Code[$k]; $k++ }
			$hdr = $bsl.Code[$k]
			$e = $k
			while ($hdr -notmatch '\)' -and $e + 1 -lt $p.end) { $e++; $hdr += ' ' + $bsl.Code[$e] }
			if ($hdr -match '\)\s*(Экспорт|Export)(?!\w)') { continue }
			if (@($ann | Where-Object { $_ -match '^\s*&\s*(Перед|После|Вместо|ИзменениеИКонтроль|Before|After|Around|ChangeAndValidate)\s*\(' }).Count -gt 0) { continue }
			# имя в коде, кроме самого заголовка
			$c = 0; [void]$wordCount.TryGetValue($n, [ref]$c)
			if ($c -gt 1) { continue }
			$tail = $false
			foreach ($t in $tails) { if ($n.EndsWith($t, [System.StringComparison]::OrdinalIgnoreCase)) { $tail = $true; break } }
			if ($tail) { continue }
			Report-Warn "22. Procedure '$n' (Module.bsl:$($k + 1)) is not bound in Form.xml and not referenced in the form module — dead code, unless a common module attaches it by name"
			$check22Ok = $false
		}
		if ($check22Ok) { Report-OK "22. Form module handlers: bindings match procedures" }
	}
}

# Объявления Перем по операторам (в строке их может быть несколько, оператор — на несколько строк):
# имя и строка, где оно стоит
function Get-VarDeclarations([string[]]$mask) {
	$text = $mask -join "`n"
	$starts = New-Object int[] $mask.Count
	$acc = 0
	for ($k = 0; $k -lt $mask.Count; $k++) { $starts[$k] = $acc; $acc += $mask[$k].Length + 1 }
	$out = @()
	foreach ($m in [regex]::Matches($text, '(?im)(?:^|;)\s*(?:&[^\s;]+\s+)*(?:Перем|Var)\s+([^;]*)')) {
		$off = $m.Groups[1].Index
		foreach ($part in ($m.Groups[1].Value -split ',')) {
			$nm = ($part -replace '\s+(Экспорт|Export)\s*$', '').Trim()
			if ($nm) {
				$pos = $off + $part.IndexOf($nm)
				$b = [array]::BinarySearch($starts, $pos)
				$out += [pscustomobject]@{ Name = $nm; Line = $(if ($b -ge 0) { $b + 1 } else { -bnot $b }) }
			}
			$off += $part.Length + 1
		}
	}
	return $out
}

# Реквизиты формы по имени (@{} регистронезависим — как имена в 1С). В форме расширения — и реквизиты
# исходной формы (<BaseForm>): их видит модуль и на них ссылаются пути. Своя копия заимствованного
# реквизита побеждает — в ней изменения расширения (добавленные колонки).
function Get-FormAttributeMap {
	$map = @{}
	foreach ($a in $root.SelectNodes("f:Attributes/f:Attribute | f:BaseForm/f:Attributes/f:Attribute", $nsMgr)) {
		$n = $a.GetAttribute('name')
		if (-not $map.ContainsKey($n)) { $map[$n] = $a }
	}
	return $map
}

# --- Check 24: переменные модуля против реквизитов формы ---
# Переменная модуля (Перем вне процедур) с именем реквизита формы — модуль не компилируется: «Переменная
# с указанным именем уже определена». Загрузка XML и обновление конфигурации этого не показывают — ошибка
# всплывает при первом обращении к форме. Локальная Перем в процедуре реквизит перекрывает, это допустимо.
if (-not $stopped) {
	$modulePath = Join-Path (Split-Path (Resolve-Path $FormPath).ProviderPath -Parent) "Form/Module.bsl"
	if (-not (Test-Path -LiteralPath $modulePath)) {
		Report-OK "24. Module variables: no module — skipped"
	} else {
		$moduleText = Read-ModuleText $modulePath
		if ($null -eq $moduleText) {
			Report-Warn "24. Form module is not UTF-8 — module variables are not checked"
		} else {
			$bsl = Get-BslScan $moduleText
			$outline = Get-ModuleOutline $bsl.Code
			$inProc = New-Object bool[] ($bsl.Code.Count + 1)
			foreach ($p in $outline.procs) { for ($k = $p.start; $k -le $p.end -and $k -le $bsl.Code.Count; $k++) { $inProc[$k] = $true } }
			# В форме расширения модуль видит и реквизиты исходной формы — замер на 8.3.24
			$formAttrs = Get-FormAttributeMap
			$check24Ok = $true
			foreach ($v in (Get-VarDeclarations $bsl.Mask)) {
				if ($inProc[$v.Line] -or -not $formAttrs.ContainsKey($v.Name)) { continue }
				Report-Error "24. Module variable '$($v.Name)' (Module.bsl:$($v.Line)) has the same name as form attribute '$($formAttrs[$v.Name].GetAttribute('name'))' — the platform will not compile the module: `"Переменная с указанным именем уже определена`""
				$check24Ok = $false
			}
			if ($check24Ok) { Report-OK "24. Module variables: no clash with form attributes" }
		}
	}
}

# --- Check 25: поля условного оформления формы ---
# Поле отбора условного оформления — путь от реквизита формы. Устаревший путь (реквизит или колонку
# переименовали, удалили) платформа принимает молча — правило просто не срабатывает (замер 8.3.24/8.3.27).
# Глубже корня проверяются только колонки таблиц значений: поля объекта и динамического списка — в метаданных.
if (-not $stopped) {
	$caNode = $root.SelectSingleNode("f:Attributes/f:ConditionalAppearance", $nsMgr)
	if ($null -eq $caNode) {
		Report-OK "25. Conditional appearance fields: none"
	} else {
		$caNs = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
		$caNs.AddNamespace("dcsset", "http://v8.1c.ru/8.1/data-composition-system/settings")
		$caAttrs = Get-FormAttributeMap
		$caCols = @{}
		$check25Ok = $true
		$seen25 = @{}
		foreach ($t in $caNode.SelectNodes(".//dcsset:left | .//dcsset:right", $caNs)) {
			if (-not $t.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance").EndsWith(':Field')) { continue }
			$path = $t.InnerText.Trim()
			if (-not $path -or $seen25.ContainsKey($path)) { continue }
			$seen25[$path] = $true
			$segs = @($path -split '\.')
			$attr = $caAttrs[$segs[0]]
			if ($null -eq $attr) {
				Report-Warn "25. Conditional appearance: filter field '$path' — the form has no attribute '$($segs[0])' — a stale path, the platform accepts it without error"
				$check25Ok = $false
				continue
			}
			$ts = @($attr.SelectNodes("f:Type/v8:Type", $nsMgr) | ForEach-Object { $_.InnerText.Trim() })
			if ($segs.Count -lt 2 -or $ts.Count -ne 1 -or @('v8:ValueTable','v8:ValueTree') -notcontains $ts[0]) { continue }
			# Второй сегмент — своя колонка таблицы (AdditionalColumns у неё — колонки вложенных таблиц, уровнем ниже)
			$an = $attr.GetAttribute('name')
			if (-not $caCols.ContainsKey($an)) {
				$cols = @{}
				foreach ($c in $attr.SelectNodes("f:Columns/f:Column", $nsMgr)) { $cols[$c.GetAttribute('name')] = $true }
				$caCols[$an] = $cols
			}
			if (-not $caCols[$an].ContainsKey($segs[1])) {
				Report-Warn "25. Conditional appearance: filter field '$path' — attribute '$($segs[0])' has no column '$($segs[1])' — a stale path, the platform accepts it without error"
				$check25Ok = $false
			}
		}
		if ($check25Ok) { Report-OK "25. Conditional appearance fields: rooted at form attributes" }
	}
}

# --- Check 26: значение ссылки в отборе/параметре (dcscor:DesignTimeValue) ---
# Вид "Enum.X.EnumValue.Y" (формат списка выбора) платформа здесь не разрешает: загрузка проходит,
# значение остаётся строкой, и условие с ним никогда не выполняется (замер 8.3.24).
if (-not $stopped) {
	$check26Ok = $true
	foreach ($n in $xmlDoc.SelectNodes("//*[@xsi:type]", $nsMgr)) {
		if (-not $n.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance").EndsWith(':DesignTimeValue')) { continue }
		$v = $n.InnerText.Trim()
		if ($v -match '^(Enum|Перечисление)\.([^.]+)\.(EnumValue|ЗначениеПеречисления)\.(.+)$') {
			$fixed = "Перечисление." + $Matches[2] + "." + $Matches[4]
			Report-Error "26. Design-time value '$v' — the platform does not resolve the EnumValue form here, the condition never matches; write '$fixed'"
			$check26Ok = $false
		}
	}
	if ($check26Ok) { Report-OK "26. Design-time values: resolvable" }
}

# --- Check 27: имена цветов web:/win: — из палитры платформы ---
# Палитры — таблицы платформы (core83/core85.dll, одинаковы 8.3.20…8.5). Имя вне палитры — загрузка
# отвергает Form.xml целиком («Исключение XDTO»). Регистр платформа не различает (web:red → web:Red).
$script:webColors = @(
	'AliceBlue','AntiqueWhite','Aqua','Aquamarine','Azure','Beige','Bisque','Black','BlanchedAlmond','Blue',
	'BlueViolet','Brown','BurlyWood','CadetBlue','Chartreuse','Chocolate','Coral','CornFlowerBlue','CornSilk','Cream',
	'Crimson','Cyan','DarkBlue','DarkCyan','DarkGoldenRod','DarkGray','DarkGreen','DarkKhaki','DarkMagenta','DarkOliveGreen',
	'DarkOrange','DarkOrchid','DarkRed','DarkSalmon','DarkSeaGreen','DarkSlateBlue','DarkSlateGray','DarkTurquoise','DarkViolet','DeepPink',
	'DeepSkyBlue','DimGray','DodgerBlue','FireBrick','FloralWhite','ForestGreen','Fuchsia','Gainsboro','GhostWhite','Gold',
	'Goldenrod','Gray','Green','GreenYellow','HoneyDew','HotPink','IndianRed','Indigo','Ivory','Khaki',
	'Lavender','LavenderBlush','LawnGreen','LemonChiffon','LightBlue','LightCoral','LightCyan','LightGoldenRod','LightGoldenRodYellow','LightGray',
	'LightGreen','LightPink','LightSalmon','LightSeaGreen','LightSkyBlue','LightSlateGray','LightSlateBlue','LightSteelBlue','LightYellow','Lime',
	'LimeGreen','Linen','Magenta','Maroon','MediumAquaMarine','MediumBlue','MediumGray','MediumGreen','MediumOrchid','MediumPurple',
	'MediumSeaGreen','MediumSlateBlue','MediumSpringGreen','MediumTurquoise','MediumVioletRed','MidnightBlue','MintCream','MistyRose','Moccasin','NavajoWhite',
	'Navy','OldLace','Olive','Olivedrab','Orange','OrangeRed','Orchid','PaleGoldenrod','PaleGreen','PaleTurquoise',
	'PaleVioletRed','PapayaWhip','PeachPuff','Peru','Pink','Plum','PowderBlue','Purple','Red','RosyBrown',
	'RoyalBlue','SaddleBrown','Salmon','SandyBrown','Seagreen','SeaShell','Sienna','Silver','SkyBlue','SlateBlue',
	'SlateGray','Snow','SpringGreen','SteelBlue','Tan','Teal','Thistle','Tomato','Turquoise','Violet',
	'VioletRed','Wheat','White','WhiteSmoke','Yellow','YellowGreen'
)
$script:winColors = @(
	'ScrollBar','Desktop','ActiveTitleBar','InactiveTitleBar','MenuBar','WindowBackground','WindowFrame','MenuItemText','WindowText','ActiveTitleBarText',
	'ActiveBorder','InactiveBorder','ApplicationWorkspace','Highlight','HighlightText','ButtonFace','ButtonShadow','DisabledText','ButtonText','InactiveTitleBarText',
	'ButtonHighlight','ButtonDarkShadow','ButtonLightShadow','ToolTipText','ToolTip','HotLight','GradientActiveCaption','GradientInactiveCaption','MiddleGradientActiveCaption','MiddleGradientInactiveCaption'
)
if (-not $stopped) {
	$check27Ok = $true
	$seen27 = @{}
	foreach ($n in $xmlDoc.SelectNodes("//*[not(*)]", $nsMgr)) {
		$xt = $n.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
		if (-not ($xt.EndsWith(':Color') -or $n.LocalName.EndsWith('Color'))) { continue }
		$v = $n.InnerText.Trim()
		if ($v -notmatch '^(web|win):(\w+)$' -or $seen27.ContainsKey($v)) { continue }
		$seen27[$v] = $true
		$palette = if ($Matches[1] -eq 'web') { $script:webColors } else { $script:winColors }
		if ($palette -notcontains $Matches[2]) {
			$hint = if ($Matches[1] -eq 'win' -and $Matches[2] -eq 'GrayText') { " (the platform name is win:DisabledText)" } else { "" }
			Report-Error "27. Color '$v' is not in the platform $($Matches[1]): palette$hint — the platform rejects the whole form on load"
			$check27Ok = $false
		}
	}
	if ($check27Ok) { Report-OK "27. Color names: in platform palettes" }
}

# --- Summary ---

$checks = $script:okCount + $errors + $warnings

if ($errors -eq 0 -and $warnings -eq 0 -and -not $Detailed) {
	Write-Host "=== Validation OK: Form.$formName ($checks checks) ==="
} else {
	Write-Host ""
	if ($Detailed) {
		Write-Host "---"
		Write-Host "Total: $($allElements.Count) elements, $($attrNodes.Count) attributes, $($cmdNodes.Count) commands"
	}

	if ($stopped) {
		Write-Host "Stopped after $MaxErrors errors. Fix and re-run."
	}

	Write-Host "=== Result: $errors errors, $warnings warnings ($checks checks) ==="
}

if ($errors -gt 0) {
	exit 1
} else {
	exit 0
}
