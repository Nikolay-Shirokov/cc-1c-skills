# mxl-decompile v1.31 — Decompile 1C spreadsheet to JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$TemplatePath,

	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load and parse XML ---

if (-not (Test-Path $TemplatePath)) {
	Write-Error "File not found: $TemplatePath"
	exit 1
}

$xmlDoc = New-Object System.Xml.XmlDocument
# PreserveWhitespace = $false схлопывает узел из одних пробелов в пустой, и текст ячейки
# вида "  " терялся молча (25 макетов пилота). Значащие пробелы в тексте надписи есть.
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load((Resolve-Path $TemplatePath).Path)

$root = $xmlDoc.DocumentElement
$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("d", "http://v8.1c.ru/8.2/data/spreadsheet")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui", "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

# Тип значения каждого тега формата — выведен из корпуса, а не выписан на глаз.
# line — ссылка в палитру <line>; color — #RRGGBB / style: / web: / win:
# ml — многоязычная строка; enum — замкнутый список.
# containsValue / valueType / controlType сюда НЕ входят: это свойства конкретной ячейки,
# а стиль — сущность общая, один на многие ячейки.
function Get-FormatTagKind {
	return @{
		'autoIndent' = 'int'; 'autoMarkIncomplete' = 'bool'; 'autoWidthCalculation' = 'bool'
		'backColor' = 'color'; 'border' = 'line'; 'borderColor' = 'color'
		'bottomBorder' = 'line'; 'bySelectedColumns' = 'bool'; 'columnSizeChange' = 'enum'
		'detailsUse' = 'enum'; 'drawingBorder' = 'line'
		'drawingHaveBottomBorder' = 'bool'; 'drawingHaveLeftBorder' = 'bool'
		'drawingHaveRightBorder' = 'bool'; 'drawingHaveTopBorder' = 'bool'
		'editFormat' = 'ml'; 'fillType' = 'enum'; 'font' = 'int'; 'format' = 'ml'
		'height' = 'int'; 'hidden' = 'bool'; 'horizontalAlignment' = 'enum'
		'hyperLink' = 'bool'; 'indent' = 'int'; 'leftBorder' = 'line'
		'markNegatives' = 'bool'; 'mask' = 'ml'; 'pattern' = 'enum'; 'patternColor' = 'color'
		'picHorizontalAlignment' = 'enum'; 'picIndex' = 'int'; 'picVerticalAlignment' = 'enum'
		'pictureSizeMode' = 'enum'; 'print' = 'bool'; 'protection' = 'bool'
		'rightBorder' = 'line'; 'textColor' = 'color'; 'textOrientation' = 'int'
		'textPlacement' = 'enum'; 'textPosition' = 'enum'; 'topBorder' = 'line'
		'verticalAlignment' = 'enum'; 'width' = 'int'; 'widthWeightFactor' = 'int'
	}
}

$RU_NAME = 'Русский'

# Теги, значение которых — многоязычная строка (<v8:item> на язык), а не скаляр.
function Get-FormatMlTags {
	return @{ 'format' = $true; 'editFormat' = $true; 'mask' = $true }
}

# Цвет платформа хранит значением с префиксом пространства имён. style: объявлен в корне
# документа и читается как есть; web/win объявлены прямо на узле сгенерированным префиксом
# (d3p1), поэтому его надо разрешить в URI и вернуть привычное web:/win:.
function ConvertTo-DslColor {
	param($node, [string]$val)
	if ($val -notlike '*:*' -or $val -like 'style:*') { return $val }
	$prefix = $val.Substring(0, $val.IndexOf(':'))
	$name = $val.Substring($val.IndexOf(':') + 1)
	# get_*(): XML-адаптер PowerShell перекрывает .NET-члены одноимёнными атрибутами узла.
	$uri = $node.GetNamespaceOfPrefix($prefix)
	if ($uri -ceq 'http://v8.1c.ru/8.1/data/ui/colors/web') { return "web:$name" }
	if ($uri -ceq 'http://v8.1c.ru/8.1/data/ui/colors/windows') { return "win:$name" }
	return $val
}

$CFG_NS = 'http://v8.1c.ru/8.1/data/enterprise/current-config'

# Элемент управления ячейки: в выгрузке это GUID, имён у платформы в XML нет.
$valueControlNames = @{
	'381ed624-9217-4e63-85db-c4c3cb87daae' = 'input'
	'35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26' = 'checkbox'
}

# Обратная функция к эмиттеру типа компилятора: <valueType> → строка DSL в КРАТЧАЙШЕЙ форме
# (Boolean, String, String(10,fixed), Number(15,3,nonneg), DateTime, CatalogRef.X, AnyRef),
# из которой компилятор восстановит тот же XML. Пустой тег → пустая строка: «содержит
# значение» без указания типа — самостоятельное состояние.
# Префикс ссылочного типа разрешаем по URI, а не по имени: локальное объявление платформа
# называет сгенерированным dNpM. Чужое пространство имён оставляем как есть.
# Значение ячейки-поля ввода → литерал DSL. Тип значения выражается самим литералом:
# число → числом, булево → true/false, строка и дата → строкой. Пустое значение пишем
# как есть (0, false, пустая дата), а не схлопываем: так оно собирается обратно тем же
# типом независимо от того, какой тип объявлен у ячейки.
function ConvertTo-DslValue {
	param([string]$xsiType, [string]$text)
	if ($null -eq $text) { $text = '' }
	if ($xsiType -ceq 'xs:boolean') { return ($text.Trim() -ceq 'true') }
	if ($xsiType -ceq 'xs:decimal') {
		$s = $text.Trim()
		$i = 0; $d = 0.0
		if ($s -notlike '*.*' -and [int]::TryParse($s, [ref]$i)) { return $i }
		if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float,
				[System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
		return $s
	}
	return $text
}

function Get-ValueQualifier {
	param($quals, [string]$kind, [string]$name, [string]$default = '')
	if (-not $quals.ContainsKey($kind)) { return $default }
	$sub = $quals[$kind].SelectSingleNode("v8:$name", $ns)
	if ($sub -and $sub.InnerText) { return $sub.InnerText.Trim() }
	return $default
}

function ConvertFrom-ValueTypeNode {
	param($node)
	$types = @()
	$quals = @{}
	foreach ($child in $node.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		$tag = $child.get_LocalName()
		if ($tag -ceq 'Type' -or $tag -ceq 'TypeSet') {
			$types += ,@($child, $child.InnerText.Trim())
		} elseif ($tag -like '*Qualifiers') {
			$quals[$tag.Substring(0, $tag.Length - 'Qualifiers'.Length)] = $child
		}
	}

	$parts = @()
	foreach ($t in $types) {
		$child = $t[0]
		$val = $t[1]
		if ($val -like '*:*') {
			$prefix = $val.Substring(0, $val.IndexOf(':'))
			$name = $val.Substring($val.IndexOf(':') + 1)
			# get_*(): XML-адаптер PowerShell перекрывает .NET-члены одноимёнными атрибутами узла.
			$uri = $child.GetNamespaceOfPrefix($prefix)
			if ($uri -ceq $CFG_NS) { $val = $name }
			elseif ($uri -ceq 'http://www.w3.org/2001/XMLSchema') { $val = "xs:$name" }
		}
		if ($val -ceq 'xs:boolean') {
			$parts += 'Boolean'
		} elseif ($val -ceq 'xs:string') {
			$length = Get-ValueQualifier $quals 'String' 'Length' '0'
			$fixed = (Get-ValueQualifier $quals 'String' 'AllowedLength' 'Variable') -ceq 'Fixed'
			if ($fixed) { $parts += "String($length,fixed)" }
			elseif ($length -ne '0') { $parts += "String($length)" }
			else { $parts += 'String' }
		} elseif ($val -ceq 'xs:decimal') {
			$digits = Get-ValueQualifier $quals 'Number' 'Digits' '0'
			$fraction = Get-ValueQualifier $quals 'Number' 'FractionDigits' '0'
			$nonneg = (Get-ValueQualifier $quals 'Number' 'AllowedSign' 'Any') -ceq 'Nonnegative'
			if ($nonneg) { $parts += "Number($digits,$fraction,nonneg)" }
			elseif ($digits -ne '0' -or $fraction -ne '0') { $parts += "Number($digits,$fraction)" }
			else { $parts += 'Number' }
		} elseif ($val -ceq 'xs:dateTime') {
			$parts += (Get-ValueQualifier $quals 'Date' 'DateFractions' 'DateTime')
		} else {
			$parts += $val
		}
	}
	return ($parts -join ' + ')
}

# --- 2. Extract font palette ---

# Размер шрифта бывает дробным (8.3, 11.3 — в корпусе ERP это треть макетов). [int] его
# ТИХО округлял, а py-порт падал на int(). Читаем инвариантной культурой и держим целым,
# когда дробной части нет, — иначе "10" превратилось бы в "10.0".
function ConvertTo-FontSize {
	param($raw)
	$s = [string]$raw
	if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
	$d = 0.0
	if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return 0 }
	if ($d -eq [math]::Floor($d)) { return [int]$d }
	return $d
}

$rawFonts = @()
foreach ($fNode in $root.SelectNodes("d:font", $ns)) {
	$rawFonts += @{
		# Шрифт бывает ссылкой на элемент стиля (style:) или системный шрифт (sys:) —
		# тогда своих атрибутов у него нет, и без этого он превращался в пустую запись.
		Ref       = $fNode.GetAttribute("ref")
		Face      = $fNode.GetAttribute("faceName")
		Size      = ConvertTo-FontSize $fNode.GetAttribute("height")
		Bold      = $fNode.GetAttribute("bold") -eq "true"
		Italic    = $fNode.GetAttribute("italic") -eq "true"
		Underline = $fNode.GetAttribute("underline") -eq "true"
		Strikeout = $fNode.GetAttribute("strikeout") -eq "true"
	}
}

# --- 3. Extract line palette ---

$rawLines = @()
foreach ($lNode in $root.SelectNodes("d:line", $ns)) {
	$st = $lNode.SelectSingleNode("v8ui:style", $ns)
	$rawLines += @{
		Width = [int]$lNode.GetAttribute("width")
		Gap   = $lNode.GetAttribute("gap")
		Style = if ($st) { $st.InnerText } else { "Solid" }
	}
}

# --- 4. Extract format palette ---
# Формат читаем целиком — «тег → значение», а не выборочные девять полей. Тип значения
# берём из общей таблицы, она же у компилятора.
$formatKinds = Get-FormatTagKind
$formatMl = Get-FormatMlTags

$rawFormats = @()
foreach ($fmtNode in $root.SelectNodes("d:format", $ns)) {
	# Совместимость с прежними полями: ими пользуются ширина колонки, высота строки и
	# признак заполнения — они не часть стиля.
	$fmt = @{
		FontIdx = -1; Width = 0; Height = 0; FillType = ""
		Props = [ordered]@{}
	}

	foreach ($child in $fmtNode.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		$tag = $child.get_LocalName()
		if ($formatMl.ContainsKey($tag)) {
			$item = $child.SelectSingleNode("v8:item/v8:content", $ns)
			if ($item -and $item.InnerText) { $fmt.Props[$tag] = $item.InnerText }
			continue
		}
		# Тип значения ячейки — единственный тег со СВОЕЙ структурой: разбираем его до обеих
		# отсечек ниже. Пустой <valueType/> тоже значим — это «содержит значение» без
		# указания типа.
		if ($tag -ceq 'valueType') {
			$fmt.Props[$tag] = ConvertFrom-ValueTypeNode $child
			continue
		}
		# Вложенный элемент скаляром не является: InnerText склеил бы всё поддерево вместе
		# с переводами строк. py-порт брал .text и получал пустоту — отсюда расхождение портов.
		if ($child.SelectNodes('*').Count -gt 0) { continue }
		$val = $child.InnerText
		if ([string]::IsNullOrWhiteSpace($val)) { continue }
		if ($formatKinds[$tag] -ceq 'color') { $val = ConvertTo-DslColor $child $val }
		$fmt.Props[$tag] = $val
	}

	if ($fmt.Props.Contains('font')) { $fmt.FontIdx = [int]$fmt.Props['font'] }
	if ($fmt.Props.Contains('width')) { $fmt.Width = [int]$fmt.Props['width'] }
	if ($fmt.Props.Contains('height')) { $fmt.Height = [int]$fmt.Props['height'] }
	if ($fmt.Props.Contains('fillType')) { $fmt.FillType = $fmt.Props['fillType'] }

	$rawFormats += $fmt
}

function Get-Format {
	param([int]$idx)
	if ($idx -le 0 -or $idx -gt $rawFormats.Count) { return $null }
	return $rawFormats[$idx - 1]
}

# --- 4-bis. Палитра картинок и рисунки ---
# Картинка хранится ссылкой на библиотеку либо данными base64; ссылки на палитру (у рисунка
# pictureIndex, у ячейки picIndex) — 1-based, сам <index> — 0-based.
$picturesOut = [ordered]@{}
$pictureKey = @{}
$picI = 0
foreach ($picNode in $root.SelectNodes("d:picture", $ns)) {
	$inner = $picNode.SelectSingleNode("d:picture", $ns)
	if (-not $inner) { continue }
	$picI++
	$name = "pic$picI"
	$entry = [ordered]@{}
	if ($inner.GetAttribute('ref')) {
		$entry["ref"] = $inner.GetAttribute('ref')
	} elseif (($inner.InnerText).Trim()) {
		# System.Xml переводы строк в тексте не нормализует, а lxml нормализует: без этой
		# замены порты дали бы разный JSON на одном и том же файле.
		$entry["data"] = ($inner.InnerText -replace "`r`n", "`n").Trim()
	}
	# Прозрачность живёт и у ссылочной картинки (в БП 8.3.27 таких записей 67), поэтому
	# читаем её вне ветвления. Пиксель прозрачного цвета — координата внутри картинки.
	if ($entry.Count -gt 0 -and $inner.HasAttribute('t')) {
		$entry["transparent"] = ($inner.GetAttribute('t') -ceq 'true')
	}
	if ($entry.Count -gt 0 -and $inner.HasAttribute('tx')) {
		$entry["transparent"] = [ordered]@{
			x = [int]$inner.GetAttribute('tx')
			y = [int]$inner.GetAttribute('ty')
		}
	}
	$picturesOut[$name] = $entry
	$pictureKey[$picI] = $name
}

$drawingNames = @{}
foreach ($niNode in $root.SelectNodes("d:namedItem", $ns)) {
	if ($niNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance") -cne 'NamedItemDrawing') { continue }
	$idN = $niNode.SelectSingleNode("d:drawingID", $ns)
	$nmN = $niNode.SelectSingleNode("d:name", $ns)
	$drawingNames[$(if ($idN) { $idN.InnerText } else { '' })] = $(if ($nmN) { $nmN.InnerText } else { '' })
}

$drawingsOut = @()
$drI = 0
foreach ($dr in $root.SelectNodes("d:drawing", $ns)) {
	$drI++
	$item = [ordered]@{}
	$tN = $dr.SelectSingleNode("d:drawingType", $ns)
	$item["type"] = if ($tN) { $tN.InnerText } else { 'Picture' }
	$idN = $dr.SelectSingleNode("d:id", $ns)
	$did = if ($idN) { $idN.InnerText } else { "$drI" }
	if ($did -cne "$drI") { $item["id"] = [int]$did }
	$zN = $dr.SelectSingleNode("d:zOrder", $ns)
	$zorder = if ($zN) { $zN.InnerText } else { "$drI" }
	if ($zorder -cne "$drI") { $item["zOrder"] = [int]$zorder }
	if ($drawingNames.ContainsKey($did)) { $item["name"] = $drawingNames[$did] }
	$piN = $dr.SelectSingleNode("d:pictureIndex", $ns)
	if ($piN -and $pictureKey.ContainsKey([int]$piN.InnerText)) {
		$item["picture"] = $pictureKey[[int]$piN.InnerText]
	}
	$dpN = $dr.SelectSingleNode("d:detailParameter", $ns)
	if ($dpN -and $dpN.InnerText) { $item["detail"] = $dpN.InnerText }
	$tEl = $dr.SelectSingleNode("d:text", $ns)
	if ($tEl) {
		$byLang = [ordered]@{}
		foreach ($it in $tEl.SelectNodes("v8:item", $ns)) {
			$l = $it.SelectSingleNode("v8:lang", $ns)
			$cnt = $it.SelectSingleNode("v8:content", $ns)
			$byLang[$(if ($l) { $l.InnerText } else { '' })] = $(if ($cnt) { $cnt.InnerText } else { '' })
		}
		$item["text"] = $byLang
	}
	# Оформление разбирается позже: линию нужно развернуть в описание, а помощник для
	# этого появляется вместе с палитрой стилей.
	$fN = $dr.SelectSingleNode("d:formatIndex", $ns)
	foreach ($pair in @(@('begin', 'beginRowOffset', 'beginColumnOffset'), @('end', 'endRowOffset', 'endColumnOffset'))) {
		$prefix = $pair[0]
		$rN = $dr.SelectSingleNode("d:$($prefix)Row", $ns)
		$cN = $dr.SelectSingleNode("d:$($prefix)Column", $ns)
		$dyN = $dr.SelectSingleNode("d:$($pair[1])", $ns)
		$dxN = $dr.SelectSingleNode("d:$($pair[2])", $ns)
		$item[$prefix] = [ordered]@{
			row = $(if ($rN) { [int]$rN.InnerText } else { 0 }) + 1
			col = $(if ($cN) { [int]$cN.InnerText } else { 0 }) + 1
			dy  = $(if ($dyN) { [int]$dyN.InnerText } else { 0 })
			dx  = $(if ($dxN) { [int]$dxN.InnerText } else { 0 })
		}
	}
	$psN = $dr.SelectSingleNode("d:pictureSize", $ns)
	if ($psN -and $psN.InnerText -cne 'Stretch') { $item["pictureSize"] = $psN.InnerText }
	$item["_fmt"] = if ($fN) { [int]$fN.InnerText } else { 0 }
	$drawingsOut += , $item
}

# --- 4a. Колонтитулы и параметры печати ---
# Слот колонтитула устроен как ячейка: ссылка на формат плюс текст. Признак вывода и стартовую
# страницу читаем только у записи, где есть <height>: палитра дедуплицирована, и колонтитул без
# своих настроек ссылается на чужую запись, где <width> — ширина колонки, а не номер страницы.
function Read-HeaderPart {
	param([string]$suffix)
	$out = [ordered]@{}
	$fmtIdx = $null
	foreach ($slot in @('left', 'center', 'right')) {
		$el = $root.SelectSingleNode("d:$slot$suffix", $ns)
		if (-not $el) { continue }
		if ($null -eq $fmtIdx) {
			$fNode = $el.SelectSingleNode("d:f", $ns)
			$fmtIdx = if ($fNode) { [int]$fNode.InnerText } else { 0 }
		}
		foreach ($textTag in @('tl', 'tfl')) {
			$t = $el.SelectSingleNode("d:$textTag", $ns)
			if (-not $t) { continue }
			$byLang = [ordered]@{}
			foreach ($it in $t.SelectNodes("v8:item", $ns)) {
				$l = $it.SelectSingleNode("v8:lang", $ns)
				$cnt = $it.SelectSingleNode("v8:content", $ns)
				$byLang[$(if ($l) { $l.InnerText } else { '' })] = $(if ($cnt) { $cnt.InnerText } else { '' })
			}
			$value = Get-DslText $byLang
			$out[$slot] = if ($textTag -ceq 'tfl') { [ordered]@{ formatted = $value } } else { $value }
			break
		}
	}
	if ($out.Count -eq 0 -and $null -eq $fmtIdx) { return $null }
	$fmt = if ($fmtIdx) { Get-Format $fmtIdx } else { $null }
	if ($fmt) {
		$props = $fmt.Props
		$head = [ordered]@{}
		if ($fmt.FontIdx -ge 0) { $head["font"] = $fontNames[$fmt.FontIdx] }
		if ($props.Contains('height')) {
			if ("$($props['height'])" -ceq '-1') { $head["show"] = $false }
			$w = if ($props.Contains('width')) { [int]$props['width'] } else { 1 }
			if ($w -ne 1) { $head["startPage"] = $w }
		}
		if ($props.Contains('verticalAlignment')) { $head["verticalAlignment"] = $props['verticalAlignment'] }
		foreach ($k in $out.Keys) { $head[$k] = $out[$k] }
		$out = $head
	}
	return $out
}

$printSettings = $null
$psNode = $root.SelectSingleNode("d:printSettings", $ns)
if ($psNode) {
	$printSettings = [ordered]@{}
	foreach ($c in $psNode.ChildNodes) {
		if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		$v = $c.InnerText.Trim()
		$i = 0
		if ($v -ceq 'true') { $printSettings[$c.get_LocalName()] = $true }
		elseif ($v -ceq 'false') { $printSettings[$c.get_LocalName()] = $false }
		elseif ([int]::TryParse($v, [ref]$i)) { $printSettings[$c.get_LocalName()] = $i }
		else { $printSettings[$c.get_LocalName()] = $v }
	}
}

# --- 4b. Группировки строк и колонок ---
# Платформа хранит их плоским списком диапазонов, родитель раньше детей. Число уровней
# (<vgLevels>) не читаем: оно выводится из вложенности — совпало на всех 1797 макетах.
function Read-Groups {
	param([string]$tag, [string]$axis)
	$out = @()
	foreach ($g in $root.SelectNodes("d:$tag", $ns)) {
		$bNode = $g.SelectSingleNode("d:b", $ns)
		$b = if ($bNode) { [int]$bNode.InnerText } else { 0 }
		$eNode = $g.SelectSingleNode("d:e", $ns)
		$e = if ($eNode) { [int]$eNode.InnerText } else { $b }
		$item = [ordered]@{}
		$item[$axis] = if ($e -eq $b) { $b + 1 } else { "$($b + 1)-$($e + 1)" }
		$tEl = $g.SelectSingleNode("d:t", $ns)
		if ($tEl) {
			$byLang = [ordered]@{}
			foreach ($it in $tEl.SelectNodes("v8:item", $ns)) {
				$l = $it.SelectSingleNode("v8:lang", $ns)
				$cnt = $it.SelectSingleNode("v8:content", $ns)
				$byLang[$(if ($l) { $l.InnerText } else { '' })] = $(if ($cnt) { $cnt.InnerText } else { '' })
			}
			if ($byLang.Count -gt 0) { $item["name"] = $byLang }
		}
		$oNode = $g.SelectSingleNode("d:o", $ns)
		if ($oNode -and $oNode.InnerText.Trim() -ceq 'false') { $item["collapsed"] = $true }
		$gNode = $g.SelectSingleNode("d:g", $ns)
		if ($gNode -and $gNode.InnerText) { $item["titleLocation"] = $gNode.InnerText.Trim().ToLowerInvariant() }
		$out += $item
	}
	return @($out)
}

$rowGroups = Read-Groups 'vg' 'rows'
$colGroups = Read-Groups 'hg' 'cols'

# --- 5. Extract columns and default width ---

# Колоночная раскладка («индивидуальная ширина колонок» для группы строк) — элемент <columns>.
# Их бывает несколько: раскладка БЕЗ <id> — умолчание (ровно одна в каждом макете корпуса),
# остальные адресуются GUID из <id>, на который ссылаются строки (<row><columnsID>) и
# области (<area><columnsID>). Раньше читался только первый <columns> — отсюда терялись
# ширины и вылезал columns: 0.

$defaultFmtIdx = 0
$n = $root.SelectSingleNode("d:defaultFormatIndex", $ns)
if ($n) { $defaultFmtIdx = [int]$n.InnerText }

$defaultWidth = 10
if ($defaultFmtIdx -gt 0) {
	$defFmt = Get-Format $defaultFmtIdx
	if ($defFmt -and $defFmt.Width -gt 0) { $defaultWidth = $defFmt.Width }
}

function Read-ColumnSet {
	param($node)
	$byIdx = @{}
	foreach ($ci in $node.SelectNodes("d:columnsItem", $ns)) {
		$colIdx = [int]$ci.SelectSingleNode("d:index", $ns).InnerText
		$fmtIdx = [int]$ci.SelectSingleNode("d:column/d:formatIndex", $ns).InnerText
		$byIdx[$colIdx] = $fmtIdx
	}
	# Карта ширин (1-based колонка → ширина), только отличные от умолчания.
	$widths = [ordered]@{}
	foreach ($col0 in ($byIdx.Keys | Sort-Object)) {
		$fmt = Get-Format $byIdx[$col0]
		if ($fmt -and $fmt.Width -gt 0 -and $fmt.Width -ne $defaultWidth) {
			$widths.Add([string]($col0 + 1), $fmt.Width)
		}
	}
	# Формат колонки несёт не только ширину — имя стиля подставим ниже, когда стили
	# будут поименованы.
	$fmtIdx = [ordered]@{}
	foreach ($col0 in ($byIdx.Keys | Sort-Object)) { $fmtIdx.Add([string]($col0 + 1), $byIdx[$col0]) }
	$sizeNode = $node.SelectSingleNode("d:size", $ns)
	$idNode = $node.SelectSingleNode("d:id", $ns)
	return @{
		Id     = if ($idNode) { $idNode.InnerText } else { $null }
		Size   = if ($sizeNode) { [int]$sizeNode.InnerText } else { 0 }
		Widths = $widths
		FmtIdx = $fmtIdx
	}
}

$columnSets = @()
foreach ($cn in $root.SelectNodes("d:columns", $ns)) { $columnSets += Read-ColumnSet $cn }

$defaultSet = @($columnSets | Where-Object { -not $_.Id })[0]
if (-not $defaultSet -and $columnSets.Count -gt 0) { $defaultSet = $columnSets[0] }
$totalColumns = if ($defaultSet) { $defaultSet.Size } else { 0 }
$colWidthMap = if ($defaultSet) { $defaultSet.Widths } else { [ordered]@{} }

# --- 6. Extract merges ---

$mergeMap = @{}
foreach ($mNode in $root.SelectNodes("d:merge", $ns)) {
	$r = [int]$mNode.SelectSingleNode("d:r", $ns).InnerText
	$c = [int]$mNode.SelectSingleNode("d:c", $ns).InnerText
	$w = [int]$mNode.SelectSingleNode("d:w", $ns).InnerText
	$hNode = $mNode.SelectSingleNode("d:h", $ns)
	$h = if ($hNode) { [int]$hNode.InnerText } else { 0 }
	$mergeMap["$r,$c"] = @{ W = $w; H = $h }
}

# --- 7. Extract named items ---

# Захватываем области ВСЕХ типов. Раньше здесь стоял `if ($areaType -ne "Rows") { continue }`,
# из-за чего терялись Rectangle и Columns — а они есть у 61% макетов корпуса.
$namedAreas = @()
foreach ($niNode in $root.SelectNodes("d:namedItem", $ns)) {
	$xsiType = $niNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	if ($xsiType -ne "NamedItemCells") { continue }

	$areaNode = $niNode.SelectSingleNode("d:area", $ns)
	if (-not $areaNode) { continue }
	$getCoord = {
		param([string]$tag)
		$n = $areaNode.SelectSingleNode("d:$tag", $ns)
		if ($n) { return [int]$n.InnerText }
		return -1
	}

	$namedAreas += @{
		# Порядок в исходнике: Sort-Object в PowerShell 5.1 НЕстабилен (-Stable появился
		# в 6.2), поэтому области с одинаковыми границами получали произвольный порядок,
		# и вывод расходился с py-портом от запуска к запуску.
		Ord      = $namedAreas.Count
		Name     = $niNode.SelectSingleNode("d:name", $ns).InnerText
		Type     = $areaNode.SelectSingleNode("d:type", $ns).InnerText
		BeginRow = & $getCoord 'beginRow'
		EndRow   = & $getCoord 'endRow'
		BeginCol = & $getCoord 'beginColumn'
		EndCol   = & $getCoord 'endColumn'
		# Привязка области к колоночной раскладке: у 913 483 прямоугольных областей корпуса
		# она есть, и из накрытых строк выводится не всегда.
		ColumnsId = $(if ($areaNode.SelectSingleNode("d:columnsID", $ns)) { $areaNode.SelectSingleNode("d:columnsID", $ns).InnerText } else { '' })
	}
}

# --- 8. Extract rows ---

$rowData = @{}
# Языки, на которых в макете вообще есть текст. Порядок — первого появления.
$docLangs = [ordered]@{}
foreach ($riNode in $root.SelectNodes("d:rowsItem", $ns)) {
	$rowIdx = [int]$riNode.SelectSingleNode("d:index", $ns).InnerText
	$rowNode = $riNode.SelectSingleNode("d:row", $ns)

	$indexTo = $rowIdx
	$itNode = $riNode.SelectSingleNode("d:indexTo", $ns)
	if ($itNode) { $indexTo = [int]$itNode.InnerText }

	$rowFmtIdx = 0
	$fmtNode = $rowNode.SelectSingleNode("d:formatIndex", $ns)
	if ($fmtNode) { $rowFmtIdx = [int]$fmtNode.InnerText }

	$isEmpty = $false
	$emptyNode = $rowNode.SelectSingleNode("d:empty", $ns)
	if ($emptyNode -and $emptyNode.InnerText -eq "true") { $isEmpty = $true }

	$cells = @()
	if (-not $isEmpty) {
		$col = -1
		foreach ($cGroup in $rowNode.SelectNodes("d:c", $ns)) {
			$iNode = $cGroup.SelectSingleNode("d:i", $ns)
			if ($iNode) { $col = [int]$iNode.InnerText }
			else { $col++ }

			$cContent = $cGroup.SelectSingleNode("d:c", $ns)
			if (-not $cContent) { continue }

			$cellFmtIdx = 0
			$fNode = $cContent.SelectSingleNode("d:f", $ns)
			if ($fNode) { $cellFmtIdx = [int]$fNode.InnerText }

			$param = $null
			$pNode = $cContent.SelectSingleNode("d:parameter", $ns)
			if ($pNode) { $param = $pNode.InnerText }

			$detail = $null
			$dNode = $cContent.SelectSingleNode("d:detailParameter", $ns)
			if ($dNode) { $detail = $dNode.InnerText }

			# Имя параметра, которым подставляют картинку. Сама картинка сидит в
			# оформлении (picIndex), поэтому этот тег живёт отдельно от неё.
			$picParam = $null
			$ppNode = $cContent.SelectSingleNode("d:pictureParameter", $ns)
			if ($ppNode) { $picParam = $ppNode.InnerText }

			# Значение ячейки-поля ввода. Тип значения свой, из объявленного не выводится,
			# поэтому читаем и его.
			$value = $null
			$vNode = $cContent.SelectSingleNode("d:v", $ns)
			if ($vNode) {
				$value = @{ Type = $vNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance"); Text = $vNode.InnerText }
			}

			# Примечание к ячейке. Якоря не читаем как данные: конец — координаты самой
			# ячейки, начало — 1/1 у 1085 примечаний корпуса из 1087; остальное авторское.
			$note = $null
			$noteNode = $cContent.SelectSingleNode("d:note", $ns)
			if ($noteNode) {
				$noteText = [ordered]@{}
				$tEl = $noteNode.SelectSingleNode("d:text", $ns)
				if ($tEl) {
					foreach ($it in $tEl.SelectNodes("v8:item", $ns)) {
						$l = $it.SelectSingleNode("v8:lang", $ns)
						$cnt = $it.SelectSingleNode("v8:content", $ns)
						$noteText[$(if ($l) { $l.InnerText } else { '' })] = $(if ($cnt) { $cnt.InnerText } else { '' })
					}
				}
				$ng = @{}
				foreach ($ch in $noteNode.ChildNodes) {
					if ($ch.NodeType -eq [System.Xml.XmlNodeType]::Element) { $ng[$ch.get_LocalName()] = $ch.InnerText.Trim() }
				}
				$note = @{
					FormatIdx = [int]($(if ($ng['formatIndex']) { $ng['formatIndex'] } else { 0 }))
					Text      = $noteText
					AutoSize  = ($(if ($ng.ContainsKey('autoSize')) { $ng['autoSize'] } else { 'true' }) -ceq 'true')
					Box       = [ordered]@{
						top    = [int]($(if ($ng['beginRowOffset']) { $ng['beginRowOffset'] } else { 0 }))
						left   = [int]($(if ($ng['beginColumnOffset']) { $ng['beginColumnOffset'] } else { 0 }))
						bottom = [int]($(if ($ng['endRowOffset']) { $ng['endRowOffset'] } else { 0 }))
						right  = [int]($(if ($ng['endColumnOffset']) { $ng['endColumnOffset'] } else { 0 }))
					}
					AnchorRow = [int]($(if ($ng['beginRow']) { $ng['beginRow'] } else { 1 }))
					AnchorCol = [int]($(if ($ng['beginColumn']) { $ng['beginColumn'] } else { 1 }))
				}
			}

			# Настройки элемента управления — сериализованный base64 у самой ячейки.
			# Структуру не разбираем, возим дословно.
			$control = $null
			$ctlNode = $cContent.SelectSingleNode("d:control", $ns)
			# Переводы строк внутри блоба приводим к LF: XML-парсеры нормализуют их
			# по-разному, и без этого порты давали разный JSON на одном файле.
			if ($ctlNode -and $ctlNode.InnerText) { $control = $ctlNode.InnerText -replace "`r`n", "`n" }

			# Текст ячейки платформа хранит по элементу на язык. Раньше брался ПЕРВЫЙ, и всё
			# остальное терялось — в корпусе ERP 98% макетов держат текст и под ru, и под en.
			# Здесь собираем «язык → текст» как есть; свернётся в строку позже, когда станет
			# известен набор языков всего макета (Get-DslText).
			$text = $null
			$hasText = $false
			# Пустой <tl/> — отдельное состояние: тег текста есть, языков в нём нет. Без
			# этого ветвления такая ячейка теряла текст вовсе (1 из 15 ячеек с тегом текста).
			$tlNode = $cContent.SelectSingleNode("d:tl", $ns)
			$items = $cContent.SelectNodes("d:tl/v8:item", $ns)
			if ($tlNode -and (-not $items -or $items.Count -eq 0)) {
				$text = [ordered]@{}
				$hasText = $true
			} elseif ($items -and $items.Count -gt 0) {
				$byLang = [ordered]@{}
				foreach ($it in $items) {
					$langNode = $it.SelectSingleNode("v8:lang", $ns)
					$contentNode = $it.SelectSingleNode("v8:content", $ns)
					$lang = if ($langNode) { $langNode.InnerText } else { '' }
					$byLang[$lang] = if ($contentNode) { $contentNode.InnerText } else { '' }
					$docLangs[$lang] = $true
				}
				$text = $byLang
				# Единственный пустой русский текст содержимым не считается — такая ячейка
				# уходит в заполнители строки.
				$hasText = -not ($byLang.Count -eq 1 -and $byLang.Contains('ru') -and "$($byLang['ru'])" -eq '')
			}

			$cells += @{
				Col       = $col
				FormatIdx = $cellFmtIdx
				Param     = $param
				Detail    = $detail
				PictureParam = $picParam
				Value     = $value
				Control   = $control
				Note      = $note
				Text      = $text
				HasText   = $hasText
			}
		}
	}

	# Ссылка строки на колоночную раскладку; пусто = раскладка по умолчанию.
	$rowColumnsId = $null
	$cidNode = $rowNode.SelectSingleNode("d:columnsID", $ns)
	if ($cidNode) { $rowColumnsId = $cidNode.InnerText }

	for ($r = $rowIdx; $r -le $indexTo; $r++) {
		$rowData[$r] = @{
			FormatIdx = $rowFmtIdx
			Cells     = $cells
			Empty     = $isEmpty
			ColumnsId = $rowColumnsId
		}
	}
}

# Языки текстов макета и языки, объявленные в конфигурации, — разные вещи: у типовых они не
# совпадают. Строкой пишем текст, одинаковый на ВСЁМ наборе языков макета; остальное — объектом.
$textLanguages = @($docLangs.Keys)

function Get-DslText {
	param($byLang)
	if ($byLang -isnot [System.Collections.IDictionary]) { return $byLang }
	# Пустой текст (<tl/>) записывается в DSL пустой строкой — той же формой, что
	# авторская. Без этой ветки макет, где ДРУГОГО текста нет вовсе, отдавал $null,
	# и ячейка с пустым текстом теряла содержимое.
	if ($byLang.Count -eq 0) { return '' }
	if ($byLang.Count -ne $textLanguages.Count) { return $byLang }
	$common = $null
	foreach ($l in $textLanguages) {
		if (-not $byLang.Contains($l)) { return $byLang }
		if ($null -eq $common) { $common = "$($byLang[$l])" }
		elseif ("$($byLang[$l])" -cne $common) { return $byLang }
	}
	return $common
}

# --- 9. Build style key (ignoring fillType) ---

# Свойства формата, которые стилем НЕ являются: ширина принадлежит колонке, высота —
# строке, вид заполнения выводится из того, чем задано содержимое ячейки.
# containsValue/valueType/controlType — свойства ЗНАЧЕНИЯ ячейки, а не оформления: стиль
# общий на многие ячейки, а они индивидуальны. Компилятор таких ключей не знает, так что
# в DSL они были чистым шумом.
$nonStyleTags = @('width', 'height', 'fillType', 'font',
	'containsValue', 'valueType', 'controlType',
	# Линия рисунка и её стороны — свойства рисунка, а не общего оформления:
	# на корпусе все 2 135 записей с ними принадлежат только рисункам.
	'drawingBorder', 'drawingHaveLeftBorder', 'drawingHaveTopBorder',
	'drawingHaveRightBorder', 'drawingHaveBottomBorder')
$borderTags = @('border', 'leftBorder', 'topBorder', 'rightBorder', 'bottomBorder')

function ConvertTo-DslLine {
	# Ссылку в палитру разворачиваем в описание линии. Ширина 1 подразумевается, поэтому
	# обычная линия пишется просто именем стиля.
	param($idx)
	$i = [int]$idx
	if ($i -lt 0 -or $i -ge $rawLines.Count) { return "Solid" }
	$ln = $rawLines[$i]
	$out = [ordered]@{ style = $ln.Style }
	if ($ln.Width -ne 1) { $out['width'] = $ln.Width }
	if ($ln.Gap -ceq 'true') { $out['gap'] = $true }
	if ($out.Count -eq 1) { return $ln.Style }
	return $out
}

function Get-StyleProps {
	# Свойства формата, попадающие в стиль, — в каноническом порядке тегов.
	param($fmt)
	$out = [ordered]@{}
	if (-not $fmt) { return $out }
	foreach ($tag in $fmt.Props.Keys) {
		if ($nonStyleTags -ccontains $tag) { continue }
		$val = $fmt.Props[$tag]
		if ($borderTags -ccontains $tag) {
			$out[$tag] = ConvertTo-DslLine $val
		} elseif ($formatKinds[$tag] -ceq 'bool') {
			$out[$tag] = ($val -ceq 'true')
		} elseif ($formatKinds[$tag] -ceq 'int') {
			$out[$tag] = [int]$val
		} else {
			$out[$tag] = $val
		}
	}
	return $out
}

function Get-StyleKey {
	param($fmt)
	if (-not $fmt) { return "empty" }
	# «шрифта нет» и «шрифт с индексом 0» — разные форматы: нулевой шрифт вовсе не обязан
	# быть обычным, в макете он бывает курсивным или жирным.
	$parts = @("f=" + $(if ($fmt.FontIdx -ge 0) { "$($fmt.FontIdx)" } else { "none" }))
	$props = Get-StyleProps $fmt
	foreach ($tag in $props.Keys) {
		$v = $props[$tag]
		if ($v -is [System.Collections.IDictionary]) {
			$v = (($v.Keys | ForEach-Object { "$_=$($v[$_])" }) -join ',')
		}
		$parts += "$tag=$v"
	}
	return ($parts -join '|')
}

# --- 10. Name fonts ---

$fontNames = @{}
$fontDefs = [ordered]@{}

if ($rawFonts.Count -gt 0) {
	$fontNames[0] = "default"
	$fontDefs["default"] = $rawFonts[0]
}

function Get-FontKey {
	param($f)
	if ($f.Ref) { return "ref=$($f.Ref)" }
	return "$($f.Face)|$($f.Size)|$($f.Bold)|$($f.Italic)|$($f.Underline)|$($f.Strikeout)"
}

$fontKeyMap = @{}
$fontKeyMap[(Get-FontKey $rawFonts[0])] = "default"

for ($i = 1; $i -lt $rawFonts.Count; $i++) {
	$f = $rawFonts[$i]
	$df = $rawFonts[0]

	# Dedup: if identical font already named, reuse
	$fKey = Get-FontKey $f
	if ($fontKeyMap.ContainsKey($fKey)) {
		$fontNames[$i] = $fontKeyMap[$fKey]
		continue
	}

	$name = $null

	if ($f.Ref) {
		# Имя из ссылки: style:SmallTextFont → small-text-font-подобное читаемое имя не даёт
		# ничего сверх самой ссылки, поэтому берём часть после префикса.
		$name = ($f.Ref -replace '^[^:]+:', '').ToLowerInvariant()
	} elseif ($f.Face -eq $df.Face -and $f.Size -eq $df.Size) {
		if ($f.Bold -and -not $df.Bold -and -not $f.Italic -and -not $f.Underline -and -not $f.Strikeout) {
			$name = "bold"
		} elseif ($f.Italic -and -not $df.Italic -and -not $f.Bold) {
			$name = "italic"
		} elseif ($f.Underline -and -not $df.Underline -and -not $f.Bold -and -not $f.Italic) {
			$name = "underline"
		}
	} elseif ($f.Face -eq $df.Face -and $f.Size -gt $df.Size -and $f.Bold) {
		$name = "header"
	} elseif ($f.Face -eq $df.Face -and $f.Size -lt $df.Size) {
		$name = "small"
	}

	if (-not $name) {
		$parts = @()
		if ($f.Face -and $f.Face -ne $df.Face) { $parts += $f.Face.ToLower() }
		$parts += "$($f.Size)"
		if ($f.Bold) { $parts += "bold" }
		if ($f.Italic) { $parts += "italic" }
		if ($f.Underline) { $parts += "underline" }
		if ($f.Strikeout) { $parts += "strikeout" }
		$name = $parts -join "-"
	}

	$baseName = $name; $suffix = 2
	while ($fontDefs.Contains($name)) { $name = "$baseName$suffix"; $suffix++ }

	$fontNames[$i] = $name
	$fontDefs[$name] = $f
	$fontKeyMap[$fKey] = $name
}

# --- 11. Collect and name styles ---

$styleKeys = [ordered]@{}
$formatToStyleKey = @{}

# Обход по ВОЗРАСТАНИЮ номера строки: у обычной хэш-таблицы порядок в PowerShell не
# определён, и стили обнаруживались в порядке хэшей. Платформа же кладёт записи палитры
# в порядке документа, поэтому порядок обхода здесь — часть верности вывода.
# ([ordered] с целочисленными ключами не годится: он индексируется по позиции, а не по ключу.)
foreach ($r in ($rowData.Keys | Sort-Object { [int]$_ } | ForEach-Object { $rowData[$_] })) {
	foreach ($cell in $r.Cells) {
		$fmt = Get-Format $cell.FormatIdx
		if (-not $fmt) { continue }
		$key = Get-StyleKey $fmt
		if (-not $styleKeys.Contains($key)) { $styleKeys[$key] = $fmt }
		$formatToStyleKey[$cell.FormatIdx] = $key
		# Формат примечания живёт в той же палитре и тоже заслуживает имени: иначе
		# оформление подсказки терялось бы при обратной сборке.
		if ($cell.Note) {
			$nfmt = Get-Format $cell.Note.FormatIdx
			if ($nfmt) {
				$nkey = Get-StyleKey $nfmt
				if (-not $styleKeys.Contains($nkey)) { $styleKeys[$nkey] = $nfmt }
				$formatToStyleKey[$cell.Note.FormatIdx] = $nkey
			}
		}
	}
}

# Формат рисунка — ещё один владелец записи палитры, наравне с ячейкой, строкой, колонкой
# и примечанием: без этого оформление рисунка теряло имя и вырезалось как неиспользуемое.
foreach ($item in $drawingsOut) {
	$fi = [int]$item['_fmt']
	if ($fi -le 0) { continue }
	$dfmt = Get-Format $fi
	if (-not $dfmt) { continue }
	if ((Get-StyleProps $dfmt).Count -gt 0 -or $dfmt.FontIdx -ge 0) {
		$dkey = Get-StyleKey $dfmt
		if (-not $styleKeys.Contains($dkey)) { $styleKeys[$dkey] = $dfmt }
		$formatToStyleKey[$fi] = $dkey
	}
}

# Оформление строки без её собственных свойств: скрытие уезжает инлайном к height,
# поэтому в именованный стиль попадать не должно.
function Get-RowStyleFmt {
	param($fmt)
	if (-not $fmt) { return $null }
	$props = Get-StyleProps $fmt
	$props.Remove('hidden') | Out-Null
	# Шрифт в Get-StyleProps не входит (он адресуется именем), поэтому формат строки,
	# несущий ТОЛЬКО шрифт, здесь выглядел пустым и терялся.
	if ($props.Count -eq 0 -and $fmt.FontIdx -lt 0) { return $null }
	$reduced = [ordered]@{}
	foreach ($tag in $fmt.Props.Keys) {
		if ($tag -cne 'hidden') { $reduced[$tag] = $fmt.Props[$tag] }
	}
	return @{ FontIdx = $fmt.FontIdx; Width = 0; Height = 0; FillType = ""; Props = $reduced }
}

# Строка — тоже владелец формата: её оформление становится именованным стилем.
foreach ($rd in ($rowData.Keys | Sort-Object { [int]$_ } | ForEach-Object { $rowData[$_] })) {
	if ($rd.FormatIdx -le 0) { continue }
	$rf = Get-RowStyleFmt (Get-Format $rd.FormatIdx)
	if (-not $rf) { continue }
	$key = Get-StyleKey $rf
	if (-not $styleKeys.Contains($key)) { $styleKeys[$key] = $rf }
}

# Колонка — третий владелец формата, её оформление тоже становится именованным стилем.
foreach ($cs in $columnSets) {
	foreach ($fi in $cs.FmtIdx.Values) {
		$fmt = Get-Format $fi
		if (-not $fmt) { continue }
		if ((Get-StyleProps $fmt).Count -eq 0) { continue }
		$key = Get-StyleKey $fmt
		if (-not $styleKeys.Contains($key)) { $styleKeys[$key] = $fmt }
		$formatToStyleKey[$fi] = $key
	}
}

# Имя стиля — читаемая метка по самым заметным свойствам. Полнота тут не нужна:
# различает стили ключ, имя лишь помогает автору ориентироваться.
function Name-Style {
	param($fmt)
	if (-not $fmt) { return "default" }
	$parts = @()
	$props = Get-StyleProps $fmt

	$fi = $fmt.FontIdx
	if ($fi -ge 0 -and $fontNames.ContainsKey($fi) -and $fontNames[$fi] -ne "default") {
		$parts += $fontNames[$fi]
	}

	if ($props.Contains('border')) {
		$parts += "bordered"
	} else {
		$sides = @()
		foreach ($s in @('leftBorder', 'topBorder', 'rightBorder', 'bottomBorder')) {
			if ($props.Contains($s)) { $sides += $s.Substring(0, $s.Length - 6) }
		}
		if ($sides.Count -gt 0) { $parts += "border-$($sides -join ',')" }
	}

	if ($props['horizontalAlignment'] -ceq "Center") { $parts += "center" }
	elseif ($props['horizontalAlignment'] -ceq "Right") { $parts += "right" }
	if ($props['verticalAlignment'] -ceq "Center") { $parts += "vcenter" }
	elseif ($props['verticalAlignment'] -ceq "Top") { $parts += "vtop" }
	if ($props['textPlacement'] -ceq "Wrap") { $parts += "wrap" }
	if ($props.Contains('backColor')) { $parts += "bg" }
	if ($props.Contains('format')) { $parts += "fmt" }

	# Имя "default" зарезервировано за стилем БЕЗ свойств: под ним компилятор понимает
	# отсутствие оформления. Набор из одних неприметных свойств (отступ, защита) обязан
	# получить своё имя, иначе он потеряется.
	# Имя "default" зарезервировано за стилем БЕЗ свойств: под ним компилятор понимает
	# отсутствие оформления, и ячейка такой стиль не записывает. Набор из одних неприметных
	# свойств или из одного шрифта обязан получить своё имя, иначе он потеряется.
	if ($parts.Count -eq 0) {
		$hasContent = ($props.Count -gt 0) -or ($fmt.FontIdx -ge 0)
		return $(if ($hasContent) { "style" } else { "default" })
	}
	return ($parts -join "-")
}

$styleNames = [ordered]@{}
$styleDefs = [ordered]@{}

foreach ($key in $styleKeys.Keys) {
	$fmt = $styleKeys[$key]
	$name = Name-Style $fmt

	$baseName = $name; $suffix = 2
	while ($styleDefs.Contains($name)) { $name = "$baseName$suffix"; $suffix++ }

	$styleNames[$key] = $name

	$sDef = [ordered]@{}
	if ($fmt.FontIdx -ge 0) {
		$sDef["font"] = $(if ($fontNames.ContainsKey($fmt.FontIdx)) { $fontNames[$fmt.FontIdx] } else { "default" })
	}
	$props = Get-StyleProps $fmt
	foreach ($tag in $props.Keys) { $sDef[$tag] = $props[$tag] }

	$styleDefs[$name] = $sDef
}

function Get-StyleName {
	param([int]$fmtIdx)
	$key = $formatToStyleKey[$fmtIdx]
	if ($key -and $styleNames.Contains($key)) { return $styleNames[$key] }
	return "default"
}

# Колонки раскладки, у которых формат несёт не только ширину, — «колонка → стиль».
function Get-ColumnStyles {
	param($cs)
	$out = [ordered]@{}
	foreach ($col in $cs.FmtIdx.Keys) {
		$fi = $cs.FmtIdx[$col]
		if ($fi -eq 0) {
			# Колонка перечислена, формата у неё нет. Для авторинга бесполезно, но без
			# этого раундтрип теряет элемент целиком.
			$out[$col] = $null
			continue
		}
		$fmt = Get-Format $fi
		if ($fmt -and (Get-StyleProps $fmt).Count -gt 0) { $out[$col] = Get-StyleName $fi }
	}
	return $out
}

# Список позиционный, если позиция в нём НЕ записана: ни у одного элемента нет col.
# Прежняя проверка искала элемент-строку, поэтому строка из одних многоязычных текстов
# позиционной не признавалась и оставалась объектной.
function Test-PositionalList {
	param($cells)
	foreach ($el in $cells) {
		if ($el -is [System.Collections.IDictionary] -and $el.Contains('col')) { return $false }
	}
	return $true
}

# Custom JSON serializer — компактный, 2-пробельный indent, массивы примитивов inline.
# В отличие от ConvertTo-Json (PS5.1):
#   - не выравнивает ключи объекта по самому длинному
#   - не разворачивает массивы примитивов на отдельные строки
#   - кириллица в UTF-8 (без \uXXXX-escapes)
function Convert-StringToJsonLiteral {
	param([string]$s)
	if ($null -eq $s) { return 'null' }
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.Append('"')
	foreach ($ch in $s.ToCharArray()) {
		$code = [int]$ch
		if ($code -eq 0x22)     { [void]$sb.Append('\"') }
		elseif ($code -eq 0x5C) { [void]$sb.Append('\\') }
		elseif ($code -eq 0x08) { [void]$sb.Append('\b') }
		elseif ($code -eq 0x09) { [void]$sb.Append('\t') }
		elseif ($code -eq 0x0A) { [void]$sb.Append('\n') }
		elseif ($code -eq 0x0C) { [void]$sb.Append('\f') }
		elseif ($code -eq 0x0D) { [void]$sb.Append('\r') }
		elseif ($code -lt 0x20) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
		else { [void]$sb.Append($ch) }
	}
	[void]$sb.Append('"')
	return $sb.ToString()
}

# Попробовать сериализовать значение полностью inline (одна строка).
# Возвращает строку либо $null, если содержимое не помещается.
function Try-InlineJson {
	param($obj)
	if ($null -eq $obj) { return 'null' }
	if ($obj -is [bool]) { if ($obj) { return 'true' } else { return 'false' } }
	if ($obj -is [string]) { return (Convert-StringToJsonLiteral $obj) }
	if ($obj -is [int] -or $obj -is [long]) { return "$obj" }
	if ($obj -is [double] -or $obj -is [single] -or $obj -is [decimal]) {
		return ([System.Convert]::ToString($obj, [System.Globalization.CultureInfo]::InvariantCulture))
	}
	if ($obj -is [System.Collections.IDictionary]) {
		if ($obj.Count -eq 0) { return '{}' }
		$parts = @()
		foreach ($k in $obj.Keys) {
			$v = Try-InlineJson $obj[$k]
			if ($null -eq $v) { return $null }
			$parts += "$(Convert-StringToJsonLiteral "$k"): $v"
		}
		return '{ ' + ($parts -join ', ') + ' }'
	}
	if ($obj -is [System.Management.Automation.PSCustomObject]) {
		$props = @($obj.PSObject.Properties)
		if ($props.Count -eq 0) { return '{}' }
		$parts = @()
		foreach ($p in $props) {
			$v = Try-InlineJson $p.Value
			if ($null -eq $v) { return $null }
			$parts += "$(Convert-StringToJsonLiteral "$($p.Name)"): $v"
		}
		return '{ ' + ($parts -join ', ') + ' }'
	}
	if ($obj -is [array] -or $obj -is [System.Collections.IList]) {
		$items = @($obj)
		if ($items.Count -eq 0) { return '[]' }
		$parts = @()
		foreach ($it in $items) {
			$v = Try-InlineJson $it
			if ($null -eq $v) { return $null }
			$parts += $v
		}
		return '[' + ($parts -join ', ') + ']'
	}
	return $null
}

function ConvertTo-CompactJson {
	param($obj, [int]$depth = 0, [string]$indentUnit = '  ', [int]$lineLimit = 400)
	$indent = $indentUnit * $depth
	$childIndent = $indentUnit * ($depth + 1)

	if ($null -eq $obj) { return 'null' }
	if ($obj -is [bool]) { if ($obj) { return 'true' } else { return 'false' } }
	if ($obj -is [string]) { return (Convert-StringToJsonLiteral $obj) }
	if ($obj -is [int] -or $obj -is [long]) { return "$obj" }
	if ($obj -is [double] -or $obj -is [single] -or $obj -is [decimal]) {
		return ([System.Convert]::ToString($obj, [System.Globalization.CultureInfo]::InvariantCulture))
	}

	# Try inline для объектов и массивов с объектами — если помещается в lineLimit с учётом текущего indent.
	$isContainer = ($obj -is [System.Collections.IDictionary]) -or ($obj -is [System.Management.Automation.PSCustomObject]) -or ($obj -is [array]) -or ($obj -is [System.Collections.IList])
	if ($isContainer) {
		$inlineAttempt = Try-InlineJson $obj
		if ($null -ne $inlineAttempt -and ($indent.Length + $inlineAttempt.Length) -le $lineLimit) {
			return $inlineAttempt
		}
	}

	# Hashtable / OrderedDictionary — объект multi-line
	if ($obj -is [System.Collections.IDictionary]) {
		$keys = @($obj.Keys)
		if ($keys.Count -eq 0) { return '{}' }
		$parts = @()
		foreach ($k in $keys) {
			$val = ConvertTo-CompactJson -obj $obj[$k] -depth ($depth + 1) -indentUnit $indentUnit -lineLimit $lineLimit
			$parts += "$childIndent$(Convert-StringToJsonLiteral "$k"): $val"
		}
		return "{`n" + ($parts -join ",`n") + "`n$indent}"
	}
	if ($obj -is [System.Management.Automation.PSCustomObject]) {
		$props = @($obj.PSObject.Properties)
		if ($props.Count -eq 0) { return '{}' }
		$parts = @()
		foreach ($p in $props) {
			$val = ConvertTo-CompactJson -obj $p.Value -depth ($depth + 1) -indentUnit $indentUnit -lineLimit $lineLimit
			$parts += "$childIndent$(Convert-StringToJsonLiteral "$($p.Name)"): $val"
		}
		return "{`n" + ($parts -join ",`n") + "`n$indent}"
	}
	# Array / IList multi-line
	if ($obj -is [array] -or $obj -is [System.Collections.IList]) {
		$items = @($obj)
		if ($items.Count -eq 0) { return '[]' }
		$parts = @($items | ForEach-Object { "$childIndent$(ConvertTo-CompactJson -obj $_ -depth ($depth + 1) -indentUnit $indentUnit -lineLimit $lineLimit)" })
		return "[`n" + ($parts -join ",`n") + "`n$indent]"
	}
	# Fallback
	return (Convert-StringToJsonLiteral "$obj")
}

# Позиционная запись списка ячеек: позиция берётся из порядка, `col` не пишется.
# Ячейка, у которой кроме текста или параметра ничего нет, пишется значением; span
# раскрывается маркерами ">"; пропуск колонки — null; всё прочее — объектным элементом
# без col. Выбираем ту запись, которая КОРОЧЕ.
function ConvertTo-PositionalCells {
	param($cells)
	# Пропуск колонки — null. Выбираем ту запись, которая КОРОЧЕ: раньше позиционная форма
	# отбрасывалась, как только первая ячейка стояла не в первой колонке, хотя один-два null
	# впереди обычно короче объектной записи с `col`.
	if ($cells.Count -eq 0) { return @() }

	$out = @()
	$expected = 1
	foreach ($c in $cells) {
		$col = [int]$c["col"]
		if ($col -lt $expected) { return $cells }   # перекрытие — позиционно не выразить
		while ($expected -lt $col) { $out += $null; $expected++ }

		$span = if ($c.Contains("span")) { [int]$c["span"] } else { 1 }
		$keys = @($c.Keys | Where-Object { $_ -notin @("col", "span") })
		# Текст — единственное содержимое: пишем значением. Оно бывает строкой либо
		# объектом «язык → текст», и в позиционной записи элемент И ЕСТЬ это значение.
		$plainText = ($keys.Count -eq 1 -and $keys[0] -eq "text")
		$plainParam = ($keys.Count -eq 1 -and $keys[0] -eq "param")

		if ($plainText) { $out += , $c["text"] }
		elseif ($plainParam) { $out += "{$($c["param"])}" }
		else {
			$obj = [ordered]@{}
			foreach ($k in $c.Keys) { if ($k -ne "col") { $obj[$k] = $c[$k] } }
			$out += $obj
		}
		# span раскрываем маркерами — кроме объектного элемента, он несёт span сам.
		if (($plainText -or $plainParam) -and $span -gt 1) {
			for ($i = 1; $i -lt $span; $i++) { $out += ">" }
		}
		$expected = $col + $span
	}
	# Позиционная форма ценна компактностью: если она длиннее объектной, смысла в ней нет.
	$a = Try-InlineJson $out
	$b = Try-InlineJson $cells
	if ($null -ne $a -and $null -ne $b -and $a.Length -gt $b.Length) { return ,$cells }
	# Запятая обязательна: без неё список из одной ячейки разворачивается в саму ячейку,
	# а список из одного $null — в $null, и строка целиком уходила в пустые.
	return ,$out
}

# --- 12. Build areas ---

# Сетка нарезается на блоки: непересекающиеся области типа Rows задают границы, строки вне
# них становятся БЕЗЫМЯННЫМИ блоками. Раньше строки вне областей просто терялись — в корпусе
# такие дыры у 34% макетов, а макетов вовсе без Rows-областей 21%.
# Всё, что блоком не выражается (области не-Rows и пересекающиеся Rows), уходит в namedAreas
# координатами. Правило детерминированное — иначе раундтрип поехал бы.

$maxRowIdx = -1
foreach ($k in $rowData.Keys) { if ([int]$k -gt $maxRowIdx) { $maxRowIdx = [int]$k } }

function Get-RowColumnsId {
	param([int]$r)
	if ($rowData.ContainsKey($r)) { return $rowData[$r].ColumnsId }
	return $null
}

# Область годится в качестве области-диапазона, только если у всех её строк ОДНА раскладка:
# иначе её пришлось бы резать, а имя резать нельзя — такая уходит в координатный список.
function Test-UniformColumnSet {
	param([int]$from, [int]$to)
	$first = Get-RowColumnsId $from
	for ($r = $from + 1; $r -le $to; $r++) {
		if ((Get-RowColumnsId $r) -ne $first) { return $false }
	}
	return $true
}

$blockAreas = @()
$overlayAreas = @()
$claimed = @{}   # строка → занята областью-диапазоном
foreach ($a in @($namedAreas | Sort-Object @{ Expression = { $_.BeginRow } }, @{ Expression = { $_.EndRow } }, @{ Expression = { $_.Ord } })) {
	$fitsBlock = ($a.Type -eq 'Rows' -and $a.BeginRow -ge 0 -and $a.EndRow -ge $a.BeginRow)
	if ($fitsBlock) {
		for ($r = $a.BeginRow; $r -le $a.EndRow; $r++) {
			if ($claimed.ContainsKey($r)) { $fitsBlock = $false; break }
		}
	}
	if ($fitsBlock) { $fitsBlock = Test-UniformColumnSet $a.BeginRow $a.EndRow }
	if ($fitsBlock) {
		# Блок задаёт раскладку строкам, и область наследует её же. Когда область несёт ДРУГУЮ
		# привязку, блоком её не выразить — уводим в namedAreas, где привязка пишется явным ключом.
		$rowSet = Get-RowColumnsId $a.BeginRow
		if ($null -eq $rowSet) { $rowSet = '' }
		$fitsBlock = ($a.ColumnsId -ceq $rowSet)
	}
	if ($fitsBlock) {
		for ($r = $a.BeginRow; $r -le $a.EndRow; $r++) { $claimed[$r] = $true }
		$blockAreas += $a
	} else {
		$overlayAreas += $a
	}
}

# Безымянный промежуток режем на куски с одной раскладкой: границы наборов не совпадают
# с границами именованных областей, а у области должна быть ровно одна раскладка.
function Split-GapByColumnSet {
	param([int]$from, [int]$to)
	$out = @()
	if ($to -lt $from) { return $out }
	$runStart = $from
	$runId = Get-RowColumnsId $from
	for ($r = $from + 1; $r -le $to; $r++) {
		$id = Get-RowColumnsId $r
		if ($id -ne $runId) {
			$out += @{ Name = $null; BeginRow = $runStart; EndRow = $r - 1; ColumnsId = $runId }
			$runStart = $r; $runId = $id
		}
	}
	$out += @{ Name = $null; BeginRow = $runStart; EndRow = $to; ColumnsId = $runId }
	return $out
}

# Области в порядке строк + безымянные заполнители дыр.
$blocks = @()
$cursor = 0
foreach ($a in @($blockAreas | Sort-Object @{ Expression = { $_.BeginRow } })) {
	if ($a.BeginRow -gt $cursor) {
		$blocks += Split-GapByColumnSet $cursor ($a.BeginRow - 1)
	}
	$blocks += @{ Name = $a.Name; BeginRow = $a.BeginRow; EndRow = $a.EndRow; ColumnsId = (Get-RowColumnsId $a.BeginRow) }
	$cursor = $a.EndRow + 1
}
if ($cursor -le $maxRowIdx) {
	$blocks += Split-GapByColumnSet $cursor $maxRowIdx
}

$dslAreas = @()

foreach ($area in $blocks) {
	$areaRows = @()

	for ($globalRow = $area.BeginRow; $globalRow -le $area.EndRow; $globalRow++) {
		$rd = $rowData[$globalRow]

		if (-not $rd -or $rd.Empty) {
			$areaRows += [ordered]@{}
			continue
		}

		$dslRow = [ordered]@{}

		# Формат самой строки: высота и скрытие — её собственные свойства (у ячейки таких
		# нет), остальное — оформление, оно же может лежать и на ячейках.
		$rowFmt = if ($rd.FormatIdx -gt 0) { Get-Format $rd.FormatIdx } else { $null }
		$rowOwn = if ($rowFmt) { Get-StyleProps $rowFmt } else { [ordered]@{} }
		$rowHidden = ($rowOwn['hidden'] -eq $true)
		if ($rowFmt -and $rowFmt.Height -gt 0) { $dslRow["height"] = $rowFmt.Height }
		if ($rowHidden) { $dslRow["hidden"] = $true }

		# Separate content cells from gap-fill cells
		$contentCells = @()
		$gapCells = @()

		foreach ($cell in $rd.Cells) {
			# Ячейка-поле ввода — содержательная, даже когда ни текста, ни параметра в ней нет:
			# значение задаёт её формат. Без этого такая строка уходила бы в пустые.
			$cf = Get-Format $cell.FormatIdx
			$hasValue = ($cf -and $cf.Props['containsValue'] -ceq 'true')
			# Расшифровка сама по себе делает ячейку содержательной: в корпусе 12 653 ячейки
			# несут только её. Без этого такая ячейка уходила в заполнители и терялась.
			$hasContent = $cell.Param -or $cell.HasText -or $hasValue -or $cell.Detail -or $cell.Note -or $cell.PictureParam
			$hasMerge = $mergeMap.ContainsKey("$globalRow,$($cell.Col)")

			if ($hasContent -or $hasMerge) {
				$contentCells += $cell
			} else {
				$gapCells += $cell
			}
		}

		# Detect rowStyle
		$rowStyleName = $null
		$rowStyleKey = $null

		if ($gapCells.Count -gt 0) {
			$gapKeys = @{}
			foreach ($gc in $gapCells) {
				$fmt = Get-Format $gc.FormatIdx
				$gapKeys[(Get-StyleKey $fmt)] = $true
			}

			if ($gapKeys.Count -eq 1) {
				$rowStyleKey = @($gapKeys.Keys)[0]
				if ($styleNames.Contains($rowStyleKey)) {
					$rowStyleName = $styleNames[$rowStyleKey]
				}
			}
		}

		# Стиль строки и стиль ячеек — независимые вещи: платформа их часто, но не всегда
		# пишет одинаковыми. Один ключ с модификатором apply покрывает все три случая.
		$ownFmt = Get-RowStyleFmt $rowFmt
		$ownKey = if ($ownFmt) { Get-StyleKey $ownFmt } else { $null }
		$ownName = if ($ownKey -and $styleNames.Contains($ownKey)) { $styleNames[$ownKey] } else { $null }
		$cellsName = if ($rowStyleName -and $rowStyleName -ne "default") { $rowStyleName } else { $null }

		if ($ownName -and $cellsName -and $ownKey -ceq $rowStyleKey) {
			$dslRow["rowStyle"] = $ownName
		} elseif ($ownName -and -not $cellsName) {
			$dslRow["rowStyle"] = [ordered]@{ style = $ownName; apply = "row" }
		} elseif ($cellsName -and -not $ownName) {
			$dslRow["rowStyle"] = [ordered]@{ style = $cellsName; apply = "cells" }
		} elseif ($ownName -and $cellsName) {
			# Стили разные — строке своё, ячейкам своё; ячейкам стиль раздаётся поячеечно.
			$dslRow["rowStyle"] = [ordered]@{ style = $ownName; apply = "row" }
			$rowStyleName = $null
			$rowStyleKey = $null
			$cellsName = $null
		}

		# Build cell list
		$dslCells = @()

		foreach ($cell in ($contentCells | Sort-Object { $_.Col })) {
			$dslCell = [ordered]@{ col = $cell.Col + 1 }

			# Span/rowspan from merge
			$mk = "$globalRow,$($cell.Col)"
			if ($mergeMap.ContainsKey($mk)) {
				$m = $mergeMap[$mk]
				if ($m.W -gt 0) { $dslCell["span"] = $m.W + 1 }
				if ($m.H -gt 0) { $dslCell["rowspan"] = $m.H + 1 }
			}

			# Style
			$cellFmt = Get-Format $cell.FormatIdx
			$cellStyleKey = Get-StyleKey $cellFmt

			if ($rowStyleKey -and $cellStyleKey -eq $rowStyleKey) {
				# Inherits rowStyle
			} else {
				# Стиль пишем, только когда он отличается от того, что подставит компилятор:
				# без rowStyle умолчание и есть "default", поэтому такой ключ — шум (56% ячеек).
				# А при заданном rowStyle стиль "default" писать ОБЯЗАТЕЛЬНО: раньше здесь стояло
				# `-not $rowStyleName`, и такая ячейка теряла стиль вовсе — при обратной сборке
				# она наследовала rowStyle.
				$sn = Get-StyleName $cell.FormatIdx
				if ($sn -ne "default" -or $cellsName) {
					$dslCell["style"] = $sn
				}
			}

			# Значение (ячейка-поле ввода). Свойство живёт в формате, но принадлежит ячейке:
			# на корпусе на такие записи ссылаются только <f>.
			if ($cellFmt -and $cellFmt.Props['containsValue'] -ceq 'true') {
				$dslCell["valueType"] = if ($cellFmt.Props.Contains('valueType')) { $cellFmt.Props['valueType'] } else { "" }
				if (-not $cellFmt.Props.Contains('controlType')) {
					# Формат без <controlType> вовсе — так пишут машинно-сгенерированные макеты
					# регламентированной отчётности; компилятор такое повторит только по
					# явному указанию.
					$dslCell["controlType"] = "none"
				} else {
					$ctl = "$($cellFmt.Props['controlType'])"
					$name = if ($valueControlNames.ContainsKey($ctl.ToLowerInvariant())) { $valueControlNames[$ctl.ToLowerInvariant()] } else { $ctl }
					# input — умолчание компилятора, писать его значит шуметь на 63 629
					# форматах корпуса.
					if ($name -cne 'input') { $dslCell["controlType"] = $name }
				}
				if ($null -ne $cell.Value) {
					$dslCell["value"] = ConvertTo-DslValue $cell.Value.Type $cell.Value.Text
				}
				if ($cell.Control) { $dslCell["control"] = $cell.Control }
			}

			# Content
			$fillType = if ($cellFmt) { $cellFmt.FillType } else { "" }

			if ($cell.Param) {
				$dslCell["param"] = $cell.Param
			} elseif ($fillType -eq "Template" -and $cell.HasText) {
				$dslCell["template"] = Get-DslText $cell.Text
			} elseif ($cell.HasText) {
				$dslCell["text"] = Get-DslText $cell.Text
			}
			# Расшифровка живёт отдельно от параметра заполнения: на корпусе 20 404 ячейки
			# несут её без параметра против 8 582 с ним. Пока она читалась только вместе
			# с параметром, две трети расшифровок терялись молча.
			if ($cell.Detail) { $dslCell["detail"] = $cell.Detail }
			if ($cell.PictureParam) { $dslCell["pictureParameter"] = $cell.PictureParam }

			if ($cell.Note) {
				$n = $cell.Note
				$dslNote = [ordered]@{}
				$dslNote["text"] = Get-DslText $n.Text
				$styleName = Get-StyleName $n.FormatIdx
				if ($styleName -ne "default") { $dslNote["style"] = $styleName }
				if (-not $n.AutoSize) { $dslNote["autoSize"] = $false }
				$dslNote["box"] = $n.Box
				if ($n.AnchorRow -ne 1 -or $n.AnchorCol -ne 1) {
					$dslNote["anchor"] = [ordered]@{ row = $n.AnchorRow; col = $n.AnchorCol }
				}
				$dslCell["note"] = $dslNote
			}

			$dslCells += $dslCell
		}

		if ($dslCells.Count -gt 0) { $dslRow["cells"] = [array](ConvertTo-PositionalCells $dslCells) }
		# Самая короткая из применимых форм: если у строки нет своих свойств, а список ячеек
		# позиционный — строка пишется просто массивом, без ключа cells.
		if ($dslRow.Count -eq 1 -and $dslRow.Contains("cells") -and (Test-PositionalList $dslRow["cells"])) {
			$areaRows += ,([array]$dslRow["cells"])
		} else {
			$areaRows += $dslRow
		}
	}

	# Compress consecutive empty rows ({}) into { empty = N }
	$compressedRows = @()
	$emptyRun = 0
	foreach ($r in $areaRows) {
		if ($r.Count -eq 0) {
			$emptyRun++
		} else {
			if ($emptyRun -gt 0) {
				if ($emptyRun -eq 1) { $compressedRows += [ordered]@{} }
				else { $compressedRows += [ordered]@{ empty = $emptyRun } }
				$emptyRun = 0
			}
			# Запятая обязательна: строка-массив иначе развернётся в список строк.
			$compressedRows += ,$r
		}
	}
	if ($emptyRun -gt 0) {
		if ($emptyRun -eq 1) { $compressedRows += [ordered]@{} }
		else { $compressedRows += [ordered]@{ empty = $emptyRun } }
	}

	$dslBlock = [ordered]@{}
	# Область без имени — просто кусок сетки, ключ name у неё не пишем.
	if (-not [string]::IsNullOrEmpty($area.Name)) { $dslBlock["name"] = $area.Name }
	# Ссылка на колоночную раскладку по имени из columnSets — как style у ячейки на styles.
	# Умолчание (раскладка без id) не пишем.
	if (-not [string]::IsNullOrEmpty($area.ColumnsId)) { $dslBlock["columnSet"] = $area.ColumnsId }
	$dslBlock["rows"] = [array]$compressedRows
	$dslAreas += $dslBlock
}

# --- 13. Compress columnWidths ---

$compressedWidths = [ordered]@{}
if ($colWidthMap.Count -gt 0) {
	$grouped = $colWidthMap.Keys | Group-Object { $colWidthMap[$_] }
	foreach ($g in $grouped) {
		$width = [int]$g.Name
		$cols = @($g.Group | Sort-Object { [int]$_ })

		$ranges = @()
		$rangeStart = $cols[0]; $rangePrev = $cols[0]

		for ($i = 1; $i -lt $cols.Count; $i++) {
			if ([int]$cols[$i] -eq [int]$rangePrev + 1) {
				$rangePrev = $cols[$i]
			} else {
				if ($rangeStart -eq $rangePrev) { $ranges += "$rangeStart" }
				else { $ranges += "$rangeStart-$rangePrev" }
				$rangeStart = $cols[$i]; $rangePrev = $cols[$i]
			}
		}
		if ($rangeStart -eq $rangePrev) { $ranges += "$rangeStart" }
		else { $ranges += "$rangeStart-$rangePrev" }

		foreach ($range in $ranges) { $compressedWidths[$range] = $width }
	}
}

# --- 14. Build fonts output ---

$fontsOut = [ordered]@{}
foreach ($name in $fontDefs.Keys) {
	$f = $fontDefs[$name]
	if ($f.Ref) { $fontsOut[$name] = [ordered]@{ ref = $f.Ref }; continue }
	$fOut = [ordered]@{ face = $f.Face; size = $f.Size }
	if ($f.Bold) { $fOut["bold"] = $true }
	if ($f.Italic) { $fOut["italic"] = $true }
	if ($f.Underline) { $fOut["underline"] = $true }
	if ($f.Strikeout) { $fOut["strikeout"] = $true }
	$fontsOut[$name] = $fOut
}

# --- 15. Assemble result ---

$result = [ordered]@{
	columns      = $totalColumns
	defaultWidth = $defaultWidth
}
if ($compressedWidths.Count -gt 0) { $result["columnWidths"] = $compressedWidths }
if ($defaultSet) {
	$defaultColStyles = Get-ColumnStyles $defaultSet
	if ($defaultColStyles.Count -gt 0) { $result["columnStyles"] = $defaultColStyles }
}
# Набор языков объявляем, только если он отличается от умолчания компилятора (один ru).
if ($textLanguages.Count -gt 0 -and -not ($textLanguages.Count -eq 1 -and $textLanguages[0] -ceq 'ru')) {
	$result["textLanguages"] = [array]$textLanguages
}

# Объявление языков МАКЕТА — не то же, что языки текста: почти во всех макетах ERP объявлен
# один ru, а текст лежит и под ru, и под en. Пишем, только если отличается от умолчания.
$lsNode = $root.SelectSingleNode("d:languageSettings", $ns)
if ($lsNode) {
	$langs = @()
	foreach ($li in $lsNode.SelectNodes("d:languageInfo", $ns)) {
		$idN = $li.SelectSingleNode("d:id", $ns)
		$codeN = $li.SelectSingleNode("d:code", $ns)
		$descN = $li.SelectSingleNode("d:description", $ns)
		$langs += [ordered]@{
			id = $(if ($idN) { $idN.InnerText } else { "" })
			code = $(if ($codeN) { $codeN.InnerText } else { "" })
			description = $(if ($descN) { $descN.InnerText } else { "" })
		}
	}
	$isDefault = ($langs.Count -eq 1 -and $langs[0].id -ceq 'ru' -and
		$langs[0].code -ceq $RU_NAME -and $langs[0].description -ceq $RU_NAME)
	if (-not $isDefault) { $result["languages"] = [array]$langs }
	$curN = $lsNode.SelectSingleNode("d:currentLanguage", $ns)
	$cur = if ($curN) { $curN.InnerText } else { $null }
	if ($cur -cne 'ru') { $result["currentLanguage"] = $cur }
	$dfltN = $lsNode.SelectSingleNode("d:defaultLanguage", $ns)
	if ($dfltN -and $dfltN.InnerText -cne 'ru') { $result["defaultLanguage"] = $dfltN.InnerText }
}
# Remove empty "default" style
if ($styleDefs.Contains("default") -and $styleDefs["default"].Count -eq 0) {
	$styleDefs.Remove("default")
}

# Remove unused styles
$usedStyles = @{}
foreach ($a in $dslAreas) {
	foreach ($r in $a.rows) {
		# Строка может быть массивом (короткая форма) — у неё нет свойства cells, и без этой
		# ветки стиль, использованный только внутри такой строки, вырезался как «неиспользуемый».
		$cellList = if ($r -is [array]) { $r } else { $r.cells }
		if ($r -isnot [array] -and $r.rowStyle) {
			$rs = $r.rowStyle
			$usedStyles[$(if ($rs -is [System.Collections.IDictionary]) { $rs['style'] } else { $rs })] = $true
		}
		if ($cellList) {
			foreach ($c in $cellList) {
				if ($c -isnot [string] -and $c.style) { $usedStyles[$c.style] = $true }
				# Четвёртый владелец формата — примечание: его стиль тоже держит ссылку,
				# иначе он вырезается как неиспользуемый и ссылка остаётся висячей.
				if ($c -isnot [string] -and $c.note -and $c.note['style']) { $usedStyles[$c.note['style']] = $true }
			}
		}
	}
}
# Стиль бывает не только у ячейки и строки: колонка — третий владелец формата. Берём стили
# ИЗ САМИХ РАСКЛАДОК, а не из $result: columnSets попадает в результат ПОЗЖЕ этой проверки,
# и стиль, на который ссылается только дополнительная раскладка, был бы отсечён, а ссылка
# на него осталась бы висячей.
foreach ($cs in $columnSets) {
	foreach ($name in (Get-ColumnStyles $cs).Values) {
		if ($name) { $usedStyles[$name] = $true }
	}
}
# Рисунок — пятый владелец формата. Имя ему присваивается позже, при сборке результата,
# поэтому здесь считаем его из ссылки на палитру: иначе стиль рисунка вырежется как
# неиспользуемый, а ссылка на него останется висячей.
foreach ($item in $drawingsOut) {
	$fi = [int]$item['_fmt']
	if ($fi -le 0) { continue }
	$dname = Get-StyleName $fi
	if ($dname -cne 'default') { $usedStyles[$dname] = $true }
}
$toRemove = @($styleDefs.Keys | Where-Object { -not $usedStyles.ContainsKey($_) })
foreach ($s in $toRemove) { $styleDefs.Remove($s)
}

$result["fonts"] = $fontsOut
$result["styles"] = $styleDefs

# Колоночные раскладки помимо умолчания: ключ — идентификатор из макета, на него ссылаются
# области. Содержимое раскладку не опознаёт (в корпусе полно наборов с одинаковым
# содержимым и разными id), поэтому склейки по содержимому нет.
$extraSets = @($columnSets | Where-Object { $_.Id })
if ($extraSets.Count -gt 0) {
	$setsOut = [ordered]@{}
	foreach ($cs in $extraSets) {
		$entry = [ordered]@{ columns = $cs.Size }
		if ($cs.Widths.Count -gt 0) { $entry["columnWidths"] = $cs.Widths }
		$csStyles = Get-ColumnStyles $cs
		if ($csStyles.Count -gt 0) { $entry["columnStyles"] = $csStyles }
		$setsOut[$cs.Id] = $entry
	}
	$result["columnSets"] = $setsOut
}

# Имя группировки — та же мультиязычная строка, что текст ячейки, и сворачивается так же.
foreach ($g in ($rowGroups + $colGroups)) {
	if ($g.Contains("name")) { $g["name"] = Get-DslText $g["name"] }
}
if ($rowGroups.Count -gt 0) { $result["rowGroups"] = [array]$rowGroups }
if ($colGroups.Count -gt 0) { $result["columnGroups"] = [array]$colGroups }

# Читаем здесь, а не в разделе 4a: тексту колонтитула нужен свод языков макета, который
# становится известен только после разбора строк.
$headerPart = Read-HeaderPart 'Header'
$footerPart = Read-HeaderPart 'Footer'
# Пустой словарь в PowerShell истинен, поэтому проверяем именно наполнение: макет со ссылкой
# на общую запись палитры, но без своих настроек колонтитула, иначе получал в DSL пустой ключ.
if ($headerPart -and $headerPart.Count -gt 0) { $result["header"] = $headerPart }
if ($footerPart -and $footerPart.Count -gt 0) { $result["footer"] = $footerPart }
if ($printSettings) { $result["printSettings"] = $printSettings }

# Оформление рисунка: линия и её стороны — его собственные ключи, общее — именованный стиль.
# Порядок ключей задаём здесь же, чтобы он не зависел от того, что разбиралось раньше.
$drawingsOrdered = @()
foreach ($item in $drawingsOut) {
	$fmtIdx = [int]$item['_fmt']
	$item.Remove('_fmt')
	if ($item.Contains("text")) { $item["text"] = Get-DslText $item["text"] }
	$lineVal = $null
	$sides = [ordered]@{}
	if ($fmtIdx -gt 0) {
		$dfmt = Get-Format $fmtIdx
		$props = if ($dfmt) { $dfmt.Props } else { @{} }
		if ($props.Contains('drawingBorder')) { $lineVal = ConvertTo-DslLine ([int]$props['drawingBorder']) }
		foreach ($side in @('Left', 'Top', 'Right', 'Bottom')) {
			$tag = "drawingHave${side}Border"
			if ($props.Contains($tag)) { $sides[$side.ToLowerInvariant()] = ($props[$tag] -ceq 'true') }
		}
		$dname = Get-StyleName $fmtIdx
		if ($dname -cne 'default') { $item["style"] = $dname }
	}
	if ($null -ne $lineVal) { $item["line"] = $lineVal }
	if ($sides.Count -gt 0) { $item["sides"] = $sides }
	$outItem = [ordered]@{}
	foreach ($key in @('type', 'id', 'zOrder', 'name', 'picture', 'detail', 'text',
			'style', 'line', 'sides', 'begin', 'end', 'pictureSize')) {
		if ($item.Contains($key)) { $outItem[$key] = $item[$key] }
	}
	$drawingsOrdered += , $outItem
}
if ($picturesOut.Count -gt 0) { $result["pictures"] = $picturesOut }
if ($drawingsOrdered.Count -gt 0) { $result["drawings"] = [array]$drawingsOrdered }

$result["areas"] = [array]$dslAreas

# Именованные области, не выразимые блоком, — координатами. Тип не пишем: он выводится
# из указанных осей (как в ТабличныйДокумент.Область()). DSL 1-based, XML 0-based.
if ($overlayAreas.Count -gt 0) {
	$naOut = @()
	foreach ($a in $overlayAreas) {
		$entry = [ordered]@{ name = $a.Name }
		if ($a.BeginRow -ge 0) {
			$entry["rows"] = if ($a.EndRow -gt $a.BeginRow) { "$($a.BeginRow + 1)-$($a.EndRow + 1)" } else { $a.BeginRow + 1 }
		}
		if ($a.BeginCol -ge 0) {
			$entry["cols"] = if ($a.EndCol -gt $a.BeginCol) { "$($a.BeginCol + 1)-$($a.EndCol + 1)" } else { $a.BeginCol + 1 }
		}
		# Привязку пишем, только когда она не выводится из накрытых строк.
		$derived = ''
		if ($a.BeginRow -ge 0) {
			$covered = @()
			for ($r = $a.BeginRow; $r -le $a.EndRow; $r++) {
				$cid = Get-RowColumnsId $r
				$covered += $(if ($null -eq $cid) { '' } else { $cid })
			}
			$uniq = @($covered | Select-Object -Unique)
			if ($uniq.Count -eq 1) { $derived = $uniq[0] }
		}
		if ($a.ColumnsId -cne $derived) { $entry["columnSet"] = $a.ColumnsId }
		$naOut += $entry
	}
	$result["namedAreas"] = [array]$naOut
}

# --- 16. Convert to JSON ---


$json = ConvertTo-CompactJson $result

# --- 17. Output ---

if ($OutputPath) {
	# Путь принимаем и относительным, и абсолютным: безусловная склейка с текущим каталогом
	# давала "C:\cwd\C:\out.json" и роняла WriteAllText сообщением про формат пути.
	$outAbs = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath }
	          else { Join-Path (Get-Location).Path $OutputPath }
	$enc = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText(
		$outAbs,
		$json,
		$enc
	)
	Write-Host "[OK] Decompiled: $OutputPath"
} else {
	Write-Output $json
}

Write-Host "     Areas: $($namedAreas.Count), Rows: $($rowData.Count), Columns: $totalColumns" -ForegroundColor DarkGray
Write-Host "     Fonts: $($fontDefs.Count), Styles: $($styleDefs.Count), Merges: $($mergeMap.Count)" -ForegroundColor DarkGray
