# form-validate v1.24 — Validate 1C managed form
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
$script:dumpAnchor = Find-DumpAnchor (Split-Path (Resolve-Path $FormPath) -Parent)
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
	$formFull = (Resolve-Path $FormPath).Path
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
	'UsualGroup' = 'UserVisible Visible Enabled ReadOnly EnableContentChange Title TitleTextColor TitleFont ToolTip ToolTipRepresentation Shortcut Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign Group ChildrenAlign HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign Behavior CollapsedRepresentationTitle Collapsed ControlRepresentation Representation CurrentRowUse Format ShowLeftMargin United ChildItemsWidth ShowTitle BackColor ThroughAlign TitleDataPath ExtendedTooltip ChildItems'
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

# Элементы формы, которые сверяются: корень и элементы известных типов (вне <BaseForm> — его пишет платформа)
function Get-EnumCheckNodes {
	$out = @(@{ Node = $root; Type = 'Form' })
	foreach ($n in $root.SelectNodes("//*[@name]")) {
		if ($n.NamespaceURI -ne 'http://v8.1c.ru/8.3/xcf/logform') { continue }
		if (-not $script:childTagOrder.ContainsKey($n.LocalName)) { continue }
		if ($null -ne $n.SelectSingleNode("ancestor::*[local-name()='BaseForm']")) { continue }
		$out += @{ Node = $n; Type = $n.LocalName }
	}
	return $out
}

# --- Check 15: значения свойств-перечислений ---
# Платформа читает перечисление по точному имени: значение в другом регистре или вне списка — ошибка
# загрузки XDTO. Старое имя (синоним) платформа примет и переведёт в современное — предупреждение.
if (-not $stopped) {
	$enumChecked = 0
	$check15Ok = $true
	foreach ($it in (Get-EnumCheckNodes)) {
		if ($stopped) { break }
		$label = if ($it.Type -eq 'Form') { 'Form' } else { "$($it.Type) '$($it.Node.GetAttribute('name'))'" }
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
					Report-Error "15. $label`: $prop has invalid value '$val' (allowed: $($allowed -join ', '))"
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
	foreach ($it in (Get-EnumCheckNodes)) {
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
