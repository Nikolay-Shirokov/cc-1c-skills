# form-validate v1.18 — Validate 1C managed form
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
	$xmlDoc.Load((Resolve-Path $FormPath).Path)
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

# --- Detect context: config vs EPF/ERF ---
# Walk up from FormPath looking for Configuration.xml → config context
# No Configuration.xml → external data processor / report (EPF/ERF)
$script:isConfigContext = $false
$walkDir = Split-Path (Resolve-Path $FormPath) -Parent
for ($i = 0; $i -lt 15; $i++) {
	if (-not $walkDir -or $walkDir -eq (Split-Path $walkDir)) { break }
	# Порядок проверок тот же, что у Detect-FormatVersion: сначала корень автономной обработки,
	# потом Configuration.xml — иначе форма внутри EPF, лежащей в дереве конфигурации, взяла бы
	# версию конфигурации.
	$extRoot = "$walkDir.xml"
	if (-not $script:versionAnchor) {
		if (Test-ExternalObjectRoot $extRoot) {
			# Ближайший якорь побеждает: автономная обработка остаётся автономной, даже если её
			# исходники лежат внутри дерева с Configuration.xml (типовая раскладка проекта:
			# src/cf рядом с src/epf). Иначе её собственные External*-типы считались бы ошибкой.
			$script:versionAnchor = $extRoot
			break
		}
	}
	if (Test-Path (Join-Path $walkDir "Configuration.xml")) {
		$script:isConfigContext = $true
		$script:configXmlPath = Join-Path $walkDir "Configuration.xml"
		if (-not $script:versionAnchor) { $script:versionAnchor = $script:configXmlPath }
		break
	}
	$walkDir = Split-Path $walkDir
}

# Версия формата выгрузки. Копия общего эталона (семья detect_format_version, авторитет —
# form-compile): та же ветка для автономной EPF/ERF, где версию несёт корень обработки.
function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		# Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
		# корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
		$extPath = "$d.xml"
		if (Test-Path $extPath) {
			$extText = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
			$extHead = $extText.Substring(0, [Math]::Min(2000, $extText.Length))
			if ($extHead -match '<(ExternalDataProcessor|ExternalReport)[ >]' -and $extHead -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
			# Длину среза берём по СТРОКЕ, а не по размеру файла: размер в БАЙТАХ, Substring считает
			# СИМВОЛЫ, и на кириллице байт больше — короткий Configuration.xml ронял навык исключением.
			$head = $cfgText.Substring(0, [Math]::Min(2000, $cfgText.Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

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
	$pathBaseSkipped = 0

	# All data-binding tags whose value is an attribute path (root must exist in <Attributes>).
	$bindingTags = @('DataPath','TitleDataPath','FooterDataPath','HeaderDataPath',
		'MultipleValueDataPath','MultipleValuePresentDataPath','RowPictureDataPath','MultipleValuePictureDataPath')

	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		# Skip companion elements
		if ($tag -in @("ContextMenu", "ExtendedTooltip", "AutoCommandBar", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition")) {
			continue
		}

		# In borrowed forms, skip DataPath check for base elements (id < 1000000)
		if ($hasBaseForm -and $el.Id) {
			try { if ([int]$el.Id -lt 1000000) { $pathBaseSkipped++; continue } } catch {}
		}

		foreach ($bTag in $bindingTags) {
			if ($stopped) { break }
			$dpNode = $node.SelectSingleNode("f:$bTag", $nsMgr)
			if (-not $dpNode) { continue }

			$dataPath = $dpNode.InnerText.Trim()
			if (-not $dataPath) { continue }

			# Opaque platform-internal shapes — not validatable from Form.xml alone:
			#   - bare numeric (e.g. "10", "1000003") — internal index
			#   - "N/M:<uuid>" — metadata reference by UUID
			if ($dataPath -match '^\d+$' -or $dataPath -match '^\d+/\d+:[0-9a-fA-F-]+$') {
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
				Report-Error "[$tag] '$elName': $bTag='$dataPath' — attribute '$rootAttr' not found"
				$pathErrors++
			}
		}
	}

	$pathMsg = ""
	if ($pathChecked -gt 0) { $pathMsg = "$pathChecked paths checked" }
	if ($pathBaseSkipped -gt 0) {
		$skipNote = "$pathBaseSkipped base skipped"
		$pathMsg = if ($pathMsg) { "$pathMsg, $skipNote" } else { $skipNote }
	}
	if ($pathErrors -eq 0 -and $pathMsg) {
		Report-OK "Data bindings: $pathMsg"
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

	# 11d. Пути на основной реквизит, которого форма не объявляет.
	# Check 5 такое пропускает: у заимствованной формы он не проверяет базовые элементы (id < 1000000),
	# а привязки в <xr:Link> вообще вне его списка тегов. Между тем это ровно тот случай, на котором
	# платформа отвергает загрузку: «Неверный путь к полю - Объект.X». Правило: если основной реквизит
	# не объявлен в <Attributes> формы, любой путь с его корнем не разрешится.
	# Корень берётся из основного реквизита BaseForm: «Объект» он только у формы объекта, у формы
	# списка это «Список», у формы записи регистра «Запись». С зашитым «Объект» проверка на таких
	# формах молча не срабатывала — валидатор рапортовал «чисто» на форме, которую платформа не примет.
	$mainAttrDeclared = $false
	foreach ($attr in $attrNodes) {
		$maNode = $attr.SelectSingleNode("f:MainAttribute", $nsMgr)
		if ($maNode -and $maNode.InnerText.Trim() -eq "true") { $mainAttrDeclared = $true; break }
	}

	if (-not $mainAttrDeclared) {
		# Значения привязок ищем текстом: интересуют и обычные теги, и <xr:DataPath> внутри
		# <ChoiceParameterLinks>, а те живут в чужом пространстве имён.
		$rawForm = [System.IO.File]::ReadAllText($FormPath, [System.Text.Encoding]::UTF8)
		$mainBase = $baseFormNode.SelectSingleNode("f:Attributes/f:Attribute[f:MainAttribute='true']", $bfNs)
		$rootName = if ($mainBase -and $mainBase.GetAttribute("name")) { $mainBase.GetAttribute("name") } else { "Объект" }
		$rootPat = [regex]::Escape($rootName)
		$danglingPaths = @{}
		foreach ($m in [regex]::Matches($rawForm, "<(?:\w+:)?\w*DataPath[^>]*>(${rootPat}\.[^<]+)</(?:\w+:)?\w*DataPath>")) {
			$danglingPaths[$m.Groups[1].Value] = $true
		}
		if ($danglingPaths.Count -gt 0) {
			$shown = @($danglingPaths.Keys | Sort-Object)
			$sample = ($shown | Select-Object -First 3) -join ", "
			$suffix = if ($shown.Count -gt 3) { " (и ещё $($shown.Count - 3))" } else { "" }
			Report-Error "Path(s) rooted at '${rootName}' but the form declares no MainAttribute: $sample$suffix"
		} elseif ($mainBase) {
			Report-OK "Object paths: none dangling (MainAttribute not declared)"
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
			if ($cfgVal -eq "DynamicList") { continue }
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

# --- Check 14: версия формата формы совпадает с версией выгрузки ---
# Версию задаёт платформа, которой выгружали, и в пределах одной выгрузки она едина. Форма из
# другой версии — «Неизвестная версия формата N загружаемого файла»: платформа не читает файл,
# который новее её самой. Источник версии ищем общим helper-ом: он же покрывает автономную
# внешнюю обработку/отчёт, где Configuration.xml нет и версию несёт корень самой обработки.

if (-not $stopped -and $script:versionAnchor) {
	$formVer = $root.GetAttribute("version")
	$dumpVer = Detect-FormatVersion (Split-Path (Resolve-Path $FormPath) -Parent)

	if (-not $formVer) {
		Report-OK "14. Format version: not comparable"
	} elseif ($formVer -ne $dumpVer) {
		Report-Error "14. Format version $formVer differs from the dump ($dumpVer) — a dump carries one version, the platform refuses a file it cannot read"
	} else {
		Report-OK "14. Format version: $formVer, matches the dump"
	}
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
