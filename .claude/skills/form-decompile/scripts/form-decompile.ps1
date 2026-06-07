# form-decompile v0.38 — Decompile 1C managed Form.xml to JSON DSL (draft)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# ВНИМАНИЕ: раундтрип не гарантируется. Навык исключён из авто-использования моделью.
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$FormPath,

	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 0. Resolve and validate input ---
if (-not (Test-Path $FormPath)) {
	Write-Error "Form not found: $FormPath"
	exit 1
}
$FormPath = (Resolve-Path $FormPath).Path

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load($FormPath)
$root = $xmlDoc.DocumentElement

# Ring 2: not a managed Form
if ($root.LocalName -ne 'Form') {
	[Console]::Error.WriteLine("form-decompile: корневой элемент <$($root.LocalName)> не <Form> — это не управляемая форма.")
	exit 2
}

# --- 1. Namespaces ---
$NS_LF  = "http://v8.1c.ru/8.3/xcf/logform"
$NS_V8  = "http://v8.1c.ru/8.1/data/core"
$NS_XR  = "http://v8.1c.ru/8.3/xcf/readable"
$NS_XSI = "http://www.w3.org/2001/XMLSchema-instance"

$NS_DCSSET = "http://v8.1c.ru/8.1/data-composition-system/settings"
$NS_DCSSCH = "http://v8.1c.ru/8.1/data-composition-system/schema"
$NS_DCSCOR = "http://v8.1c.ru/8.1/data-composition-system/core"
$NS_V8UI   = "http://v8.1c.ru/8.1/data/ui"

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("lf", $NS_LF)
$ns.AddNamespace("v8", $NS_V8)
$ns.AddNamespace("xr", $NS_XR)
$ns.AddNamespace("xsi", $NS_XSI)
$ns.AddNamespace("dcsset", $NS_DCSSET)
$ns.AddNamespace("dcssch", $NS_DCSSCH)
$ns.AddNamespace("dcscor", $NS_DCSCOR)
$ns.AddNamespace("v8ui", $NS_V8UI)

# Каноничные GUID пустых контейнеров ListSettings (умолчание платформы, ~90% форм).
# Если ListSettings = пустой скелет с этими GUID → декомпилятор опускает настройки вовсе,
# компилятор регенерит тот же скелет → чистый раундтрип.
$CANON_FILTER_ID = 'dfcece9d-5077-440b-b6b3-45a5cb4538eb'
$CANON_ORDER_ID  = '88619765-ccb3-46c6-ac52-38e9c992ebd4'
$CANON_CA_ID     = 'b75fecce-942b-4aed-abc9-e6a02e460fb3'
$CANON_ITEMS_ID  = '911b6018-f537-43e8-a417-da56b22f9aec'

# --- Вынос запроса динсписка в .sql рядом с output (зеркало skd-decompile) ---
$script:outputDir = $null
$script:outputBasename = $null
if ($OutputPath) {
	$od = Split-Path -Parent $OutputPath
	if (-not $od) { $od = (Get-Location).Path }
	$script:outputDir = $od
	$script:outputBasename = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
}
$script:queryFilesAccumulator = @()
$script:queryFileNamesUsed = @{}

# Запрос ≥3 строк + есть outputDir → вынести в `<basename>-<listName>.sql`, вернуть "@file".
function Maybe-ExternalizeQuery {
	param([string]$queryText, [string]$listName)
	if (-not $queryText) { return $queryText }
	if (-not $script:outputDir) { return $queryText }
	$lineCount = ([regex]::Matches($queryText, "`n")).Count + 1
	if ($lineCount -lt 3) { return $queryText }
	$safe = ($listName -replace '[^\w\-]', '_'); if (-not $safe) { $safe = 'query' }
	$prefix = if ($script:outputBasename) { "$($script:outputBasename)-" } else { '' }
	$fileName = "$prefix$safe.sql"
	$suffix = 1
	while ($script:queryFileNamesUsed.ContainsKey($fileName)) { $suffix++; $fileName = "$prefix$safe`_$suffix.sql" }
	$script:queryFileNamesUsed[$fileName] = $true
	$script:queryFilesAccumulator += [ordered]@{ fileName = $fileName; text = $queryText }
	return "@$fileName"
}
function Save-QueryFiles {
	if ($script:queryFilesAccumulator.Count -eq 0) { return }
	if (-not $script:outputDir) { return }
	$enc = New-Object System.Text.UTF8Encoding($false)
	foreach ($qf in $script:queryFilesAccumulator) {
		[System.IO.File]::WriteAllText((Join-Path $script:outputDir $qf.fileName), $qf.text, $enc)
	}
	[Console]::Error.WriteLine("Saved $($script:queryFilesAccumulator.Count) external query file(s)")
}

# Есть ли в ListSettings содержательные настройки (реальные items фильтра/порядка/
# условного оформления/параметров)? Пустой скелет (только viewMode+GUID) → false:
# декомпилятор опускает настройки, компилятор регенерит каноничный скелет, harness
# нормализует GUID → чистый раундтрип. true → контент захватывается (см. ниже).
function Test-ListSettingsHasContent {
	param($lsNode)
	if (-not $lsNode) { return $false }
	foreach ($cont in @('filter','order','conditionalAppearance','dataParameters')) {
		$cn = $lsNode.SelectSingleNode("dcsset:$cont", $ns)
		if ($cn -and $cn.SelectSingleNode("dcsset:item", $ns)) { return $true }
	}
	return $false
}

# --- 1b. Ring-3 scan: конструкции вне зоны поддержки (draft list) ---
function Fail-Ring3 {
	param([string]$kind, [string]$loc)
	[Console]::Error.WriteLine("form-decompile: декомпиляция пока не поддерживает $kind (path: $loc)")
	[Console]::Error.WriteLine("Для точечной работы с этой формой используй /form-edit.")
	exit 3
}
foreach ($el in $xmlDoc.SelectNodes("//*[local-name()='CommandInterface']")) { Fail-Ring3 -kind "CommandInterface" -loc "form/CommandInterface" }
foreach ($el in $xmlDoc.SelectNodes("//*[local-name()='ConditionalAppearance']")) { Fail-Ring3 -kind "ConditionalAppearance" -loc "form/ConditionalAppearance" }

# --- 1c. Compact JSON serializer (созвучно skd-decompile: 2-проб. indent, inline в пределах lineLimit) ---
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
	param($obj, [int]$depth = 0, [string]$indentUnit = '  ', [int]$lineLimit = 120)
	$indent = $indentUnit * $depth
	$childIndent = $indentUnit * ($depth + 1)
	if ($null -eq $obj) { return 'null' }
	if ($obj -is [bool]) { if ($obj) { return 'true' } else { return 'false' } }
	if ($obj -is [string]) { return (Convert-StringToJsonLiteral $obj) }
	if ($obj -is [int] -or $obj -is [long]) { return "$obj" }
	if ($obj -is [double] -or $obj -is [single] -or $obj -is [decimal]) {
		return ([System.Convert]::ToString($obj, [System.Globalization.CultureInfo]::InvariantCulture))
	}
	$isContainer = ($obj -is [System.Collections.IDictionary]) -or ($obj -is [array]) -or ($obj -is [System.Collections.IList])
	if ($isContainer) {
		$inlineAttempt = Try-InlineJson $obj
		if ($null -ne $inlineAttempt -and ($indent.Length + $inlineAttempt.Length) -le $lineLimit) { return $inlineAttempt }
	}
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
	if ($obj -is [array] -or $obj -is [System.Collections.IList]) {
		$items = @($obj)
		if ($items.Count -eq 0) { return '[]' }
		$parts = @($items | ForEach-Object { "$childIndent$(ConvertTo-CompactJson -obj $_ -depth ($depth + 1) -indentUnit $indentUnit -lineLimit $lineLimit)" })
		return "[`n" + ($parts -join ",`n") + "`n$indent]"
	}
	return (Convert-StringToJsonLiteral "$obj")
}

# --- 2. Helpers ---

# Companion-элементы (авто-генерируемые компилятором) — пропускаем при обходе детей.
$COMPANION_TAGS = @('ContextMenu','ExtendedTooltip','AutoCommandBar','SearchStringAddition','ViewStatusAddition','SearchControlAddition')

# Извлечь мультиязычный Title/Presentation → string (ru) или ordered hash {ru,en,...}
function Get-LangText {
	param($node)
	if ($null -eq $node) { return $null }
	$items = @($node.SelectNodes("v8:item", $ns))
	if ($items.Count -eq 0) { return $null }
	$map = [ordered]@{}
	foreach ($it in $items) {
		$lang = $it.SelectSingleNode("v8:lang", $ns)
		$content = $it.SelectSingleNode("v8:content", $ns)
		if ($lang) { $map[$lang.InnerText] = if ($content) { $content.InnerText } else { "" } }
	}
	if ($map.Count -eq 1 -and $map.Contains('ru')) { return $map['ru'] }
	return $map
}

# Детектор «настоящей» inline-разметки форматированного текста (идентичен form-compile!).
$script:fmtMarkupRe = '</>|<\s*(?:link|b|i|u|s|color|colorStyle|bgColor|bgColorStyle|font|fontSize|fontStyle|img)(?:\s|>)'
function Test-HasRealMarkup {
	param($text)
	if ($null -eq $text) { return $false }
	$vals = if ($text -is [System.Collections.IDictionary]) { @($text.Values) } else { @("$text") }
	foreach ($v in $vals) { if ("$v" -match $script:fmtMarkupRe) { return $true } }
	return $false
}
# Title-узел → DSL-значение ML-поля (гибрид): строка/мапа когда авто-детект formatted
# совпал с атрибутом; иначе явный {text, formatted}.
function Get-MLFormattedValue {
	param($titleNode)
	if (-not $titleNode) { return $null }
	$text = Get-LangText $titleNode
	if ($null -eq $text) { return $null }
	$fmtAttr = ($titleNode.GetAttribute('formatted') -eq 'true')
	if ($fmtAttr -eq (Test-HasRealMarkup $text)) { return $text }
	$o = [ordered]@{}; $o['text'] = $text; $o['formatted'] = $fmtAttr; return $o
}

# Прочитать дочерний скаляр (по local-name, без namespace)
function Get-Child {
	param($node, [string]$name)
	$c = $node.SelectSingleNode("*[local-name()='$name']")
	if ($c) { return $c.InnerText } else { return $null }
}
function Has-Child { param($node, [string]$name) return $null -ne $node.SelectSingleNode("*[local-name()='$name']") }
function To-Bool { param([string]$v) return ($v -eq 'true') }

# Значение с учётом xsi:type → нативный JSON-тип (число/булево/строка).
# Нужно, чтобы авто-детект типа в компиляторе восстановил тот же xsi:type.
function Convert-TypedValue {
	param([string]$raw, [string]$xsiType)
	switch -regex ($xsiType) {
		'decimal$' {
			if ($raw -match '^-?\d+$') { return [int]$raw }
			return [double]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)
		}
		'boolean$' { return ($raw -eq 'true') }
		default { return $raw }
	}
}

# =====================================================================
# Захват настроек компоновщика динамического списка (ListSettings):
# filter / order / conditionalAppearance. Логика портирована из навыка
# skd-decompile (Build-FilterItem/Build-Order/Build-ConditionalAppearance
# и сериализаторы оформления). Механизм New-Sentinel/Add-Warning из skd
# заменён на запись в stderr + пропуск элемента (form-decompile — draft,
# скрипт не падает на непокрытых конструкциях).
# =====================================================================

# Прочитать дочерний скаляр по xpath (с $ns). Аналог skd Get-Text.
function Get-Text {
	param($node, [string]$xpath)
	if (-not $node) { return $null }
	if ([string]::IsNullOrEmpty($xpath)) { return $node.InnerText }
	$n = $node.SelectSingleNode($xpath, $ns)
	if ($n) { return $n.InnerText } else { return $null }
}

# Мультиязычный текст (LocalStringType) → string (ru) или ordered hash.
# Алиас на уже существующий Get-LangText (тот же контракт).
function Get-MLText { param($node) return (Get-LangText $node) }

# Презентация: либо мультиязычный LocalStringType, либо плоский xs:string.
# Get-MLText даёт $null для xs:string (нет v8:item) → откат к InnerText.
function Get-PresText {
	param($node)
	if (-not $node) { return $null }
	$ml = Get-MLText $node
	if ($null -ne $ml) { return $ml }
	if ($node.InnerText) { return $node.InnerText }
	return $null
}

# Снять namespace-префикс с xsi:type ("dcsset:Foo" → "Foo")
function Get-LocalXsiType {
	param($node)
	if (-not $node) { return $null }
	$t = $node.GetAttribute("type", $NS_XSI)
	if ($t -match ':(.+)$') { return $matches[1] }
	return $t
}

# Шрифт оформления → объект {@type:Font, ...} (bit-perfect для compile).
function Get-FontValue {
	param($valNode)
	$f = [ordered]@{ '@type' = 'Font' }
	foreach ($attrName in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
		$a = $valNode.Attributes[$attrName]
		if ($null -ne $a) { $f[$attrName] = $a.Value }
	}
	return $f
}

# Линия (граница) оформления → объект {@type:Line, width, gap, style}.
function Get-LineValue {
	param($valNode)
	$obj = [ordered]@{ '@type' = 'Line' }
	$w = $valNode.GetAttribute("width")
	$g = $valNode.GetAttribute("gap")
	if ($w -ne '') { $obj['width'] = if ($w -match '^-?\d+$') { [int]$w } else { $w } }
	if ($g -ne '') { $obj['gap']  = ($g -eq 'true') }
	$styleNode = $valNode.SelectSingleNode("v8ui:style", $ns)
	if ($styleNode) { $obj['style'] = $styleNode.InnerText }
	return $obj
}

# Прочитать <dcscor:value> в JSON-значение: Font/Line/multilang/raw text.
function Read-AppearanceValueNode {
	param($valNode)
	if (-not $valNode) { return $null }
	$vt = Get-LocalXsiType $valNode
	if ($vt -eq 'LocalStringType') { return (Get-MLText $valNode) }
	if ($vt -eq 'Font') { return (Get-FontValue $valNode) }
	if ($vt -eq 'Line') { return (Get-LineValue $valNode) }
	return $valNode.InnerText
}

# Обратная карта comparisonType → короткий оператор фильтра (зеркало skd).
$script:filterOpMap = @{
	'Equal'='='; 'NotEqual'='<>'; 'Greater'='>'; 'GreaterOrEqual'='>=';
	'Less'='<'; 'LessOrEqual'='<='; 'InList'='in'; 'NotInList'='notIn';
	'InHierarchy'='inHierarchy'; 'InListByHierarchy'='inListByHierarchy';
	'Contains'='contains'; 'NotContains'='notContains';
	'BeginsWith'='beginsWith'; 'NotBeginsWith'='notBeginsWith';
	'Filled'='filled'; 'NotFilled'='notFilled'
}

# Render filter value node → shorthand-acceptable scalar string
function Get-FilterValue {
	param($valNode)
	if (-not $valNode) { return '_' }
	$nil = $valNode.GetAttribute("nil", $NS_XSI)
	if ($nil -eq 'true') { return '_' }
	$vType = Get-LocalXsiType $valNode
	if ($vType -eq 'DesignTimeValue') { return $valNode.InnerText }
	if ($vType -eq 'LocalStringType') { return (Get-MLText $valNode) }
	$txt = $valNode.InnerText
	if (-not $txt) { return '_' }
	return $txt
}

# Get-FilterValue + xsi:type значения (для valueType, например dcscor:Field).
function Get-FilterValueWithType {
	param($valNode)
	if (-not $valNode) { return @{ value = '_'; type = $null } }
	$rawType = $valNode.GetAttribute("type", $NS_XSI)
	$nil = $valNode.GetAttribute("nil", $NS_XSI)
	if ($nil -eq 'true') { return @{ value = '_'; type = $null } }
	$vType = Get-LocalXsiType $valNode
	if ($vType -eq 'LocalStringType') {
		return @{ value = (Get-MLText $valNode); type = $rawType }
	}
	$txt = $valNode.InnerText
	if (-not $txt) { return @{ value = '_'; type = $rawType } }
	if ($vType -eq 'boolean') { return @{ value = ($txt -eq 'true'); type = $rawType } }
	if ($vType -eq 'decimal') {
		if ($txt -match '^-?\d+$') { return @{ value = [int]$txt; type = $rawType } }
		return @{ value = [double]$txt; type = $rawType }
	}
	return @{ value = $txt; type = $rawType }
}

# Convert filter item node → shorthand string или object form (рекурсивно для групп).
function Build-FilterItem {
	param($itemNode, [string]$loc)
	$xtype = Get-LocalXsiType $itemNode
	if ($xtype -eq 'FilterItemGroup') {
		$gt = Get-Text $itemNode "dcsset:groupType"
		$groupName = switch ($gt) { 'OrGroup' { 'Or' } 'NotGroup' { 'Not' } default { 'And' } }
		$items = @()
		foreach ($c in $itemNode.SelectNodes("dcsset:item", $ns)) {
			$bi = (Build-FilterItem -itemNode $c -loc "$loc/item")
			if ($null -ne $bi) { $items += $bi }
		}
		$gObj = [ordered]@{ group = $groupName; items = $items }
		$gPresNode = $itemNode.SelectSingleNode("dcsset:presentation", $ns)
		if ($gPresNode) {
			$gPres = Get-MLText $gPresNode
			if (-not $gPres) { $gPres = $gPresNode.InnerText }
			if ($gPres) { $gObj['presentation'] = $gPres }
		}
		$gVMNode = $itemNode.SelectSingleNode("dcsset:viewMode", $ns)
		if ($gVMNode) { $gObj['viewMode'] = $gVMNode.InnerText }
		$gUSID = Get-Text $itemNode "dcsset:userSettingID"
		if ($gUSID) { $gObj['userSettingID'] = 'auto' }
		$gUSPN = $itemNode.SelectSingleNode("dcsset:userSettingPresentation", $ns)
		if ($gUSPN) {
			$gUSP = Get-PresText $gUSPN
			if ($gUSP) { $gObj['userSettingPresentation'] = $gUSP }
		}
		return $gObj
	}
	if ($xtype -ne 'FilterItemComparison') {
		[Console]::Error.WriteLine("form-decompile: пропущен фильтр неизвестного типа '$xtype' (path: $loc)")
		return $null
	}
	$leftNode = $itemNode.SelectSingleNode("dcsset:left", $ns)
	$field = if ($leftNode) { $leftNode.InnerText } else { $null }
	$ct = Get-Text $itemNode "dcsset:comparisonType"
	$op = $script:filterOpMap[$ct]
	if (-not $op) { $op = $ct }

	$rightNodes = @($itemNode.SelectNodes("dcsset:right", $ns))
	$value = $null
	$valueIsArrayFlag = $false
	$valueTypeAttr = $null
	if ($rightNodes.Count -eq 1) {
		$rn = $rightNodes[0]
		if ((Get-LocalXsiType $rn) -eq 'ValueListType') {
			$value = @()
			$valueIsArrayFlag = $true
		} else {
			$vt = Get-FilterValueWithType $rn
			$value = $vt.value
			$autoDetectsDTV = ($vt.type -eq 'dcscor:DesignTimeValue') -and `
				("$($vt.value)" -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.')
			if ($vt.type -and $vt.type -notmatch '^xs:' -and -not $autoDetectsDTV) {
				$valueTypeAttr = $vt.type
			}
		}
	} elseif ($rightNodes.Count -gt 1) {
		$arr = @()
		$rawTypes = @()
		foreach ($rn in $rightNodes) {
			$arr += (Get-FilterValue $rn)
			$rawTypes += $rn.GetAttribute("type", $NS_XSI)
		}
		$value = $arr
		$valueIsArrayFlag = $true
		$uniqTypes = @($rawTypes | Sort-Object -Unique)
		if ($uniqTypes.Count -eq 1 -and $uniqTypes[0]) {
			$autoDetectsDTV = ($uniqTypes[0] -eq 'dcscor:DesignTimeValue') -and `
				($arr.Count -gt 0) -and `
				(@($arr | Where-Object { "$_" -notmatch '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.' }).Count -eq 0)
			if (-not $autoDetectsDTV) {
				$valueTypeAttr = $uniqTypes[0]
			}
		}
	}

	$use = Get-Text $itemNode "dcsset:use"
	$userId = Get-Text $itemNode "dcsset:userSettingID"
	$vmNode = $itemNode.SelectSingleNode("dcsset:viewMode", $ns)
	$viewMode = if ($vmNode) { $vmNode.InnerText } else { $null }
	$userPresNode = $itemNode.SelectSingleNode("dcsset:userSettingPresentation", $ns)
	$fiPresNode = $itemNode.SelectSingleNode("dcsset:presentation", $ns)
	$fiPres = $null
	if ($fiPresNode) {
		$fiPres = Get-MLText $fiPresNode
		if (-not $fiPres) { $fiPres = $fiPresNode.InnerText }
	}

	$flags = @()
	if ($use -eq 'false') { $flags += '@off' }
	if ($userId) { $flags += '@user' }
	if ($viewMode -eq 'QuickAccess') { $flags += '@quickAccess' }
	elseif ($viewMode -eq 'Inaccessible') { $flags += '@inaccessible' }
	elseif ($viewMode -eq 'Normal') { $flags += '@normal' }

	$noValueOps = @('filled','notFilled')

	if ($userPresNode -or $valueIsArrayFlag -or $valueTypeAttr -or $fiPres) {
		$obj = [ordered]@{ field = $field; op = $op }
		if ($op -notin $noValueOps -and $null -ne $value) {
			if ($valueIsArrayFlag) {
				$arrAsList = New-Object System.Collections.ArrayList
				foreach ($vv in @($value)) { [void]$arrAsList.Add($vv) }
				$obj['value'] = $arrAsList
			} else {
				$obj['value'] = $value
			}
		}
		if ($valueTypeAttr) { $obj['valueType'] = $valueTypeAttr }
		if ($use -eq 'false') { $obj['use'] = $false }
		if ($userId) { $obj['userSettingID'] = 'auto' }
		if ($fiPres) { $obj['presentation'] = $fiPres }
		if ($viewMode) { $obj['viewMode'] = $viewMode }
		if ($userPresNode) { $obj['userSettingPresentation'] = Get-PresText $userPresNode }
		return $obj
	}

	$s = $field
	if ($op -in $noValueOps) {
		$s += " $op"
	} else {
		$vDisplay = '_'
		if ($null -ne $value) {
			if ($value -is [bool]) { $vDisplay = if ($value) { 'true' } else { 'false' } }
			elseif ("$value" -ne '') { $vDisplay = "$value" }
		}
		$s += " $op $vDisplay"
	}
	if ($flags) { $s += ' ' + ($flags -join ' ') }
	return $s
}

# Рекурсивный хелпер одного элемента selection (для conditionalAppearance).
function Build-SelectionItem {
	param($item, [string]$loc)
	$xt = Get-LocalXsiType $item
	if (-not $xt) {
		$fName = Get-Text $item "dcsset:field"
		if ($fName) { return $fName }
		$fieldEl = $item.SelectSingleNode("dcsset:field", $ns)
		if ($fieldEl) { return 'Auto' }
	}
	switch ($xt) {
		'SelectedItemAuto' {
			$useV = Get-Text $item "dcsset:use"
			if ($useV -eq 'false') {
				return [ordered]@{ auto = $true; use = $false }
			}
			return 'Auto'
		}
		'SelectedItemField' {
			$fName = Get-Text $item "dcsset:field"
			$titleNode = $item.SelectSingleNode("dcsset:lwsTitle", $ns)
			$title = Get-MLText $titleNode
			$vmN = $item.SelectSingleNode("dcsset:viewMode", $ns)
			$useV = Get-Text $item "dcsset:use"
			$useFalse = ($useV -eq 'false')
			if ($title -or $vmN -or $useFalse) {
				$obj = [ordered]@{ field = $fName }
				if ($useFalse) { $obj['use'] = $false }
				if ($title) { $obj['title'] = $title }
				if ($vmN) { $obj['viewMode'] = $vmN.InnerText }
				return $obj
			}
			return $fName
		}
		'SelectedItemFolder' {
			$titleNode = $item.SelectSingleNode("dcsset:lwsTitle", $ns)
			$folderTitle = Get-MLText $titleNode
			$inner = @()
			foreach ($sub in $item.SelectNodes("dcsset:item", $ns)) {
				$bi = (Build-SelectionItem -item $sub -loc "$loc/folder")
				if ($null -ne $bi) { $inner += $bi }
			}
			$entry = [ordered]@{ folder = $folderTitle; items = $inner }
			$folderField = Get-Text $item "dcsset:field"
			if ($folderField) { $entry['field'] = $folderField }
			$plN = $item.SelectSingleNode("dcsset:placement", $ns)
			if ($plN -and $plN.InnerText -and $plN.InnerText -ne 'Auto') {
				$entry['placement'] = $plN.InnerText
			}
			return $entry
		}
		default {
			[Console]::Error.WriteLine("form-decompile: пропущен элемент selection неизвестного типа '$xt' (path: $loc)")
			return $null
		}
	}
}

# Build selection items array (для conditionalAppearance).
function Build-Selection {
	param($selNode, [string]$loc)
	if (-not $selNode) { return @() }
	$out = @()
	foreach ($it in $selNode.SelectNodes("dcsset:item", $ns)) {
		$bi = (Build-SelectionItem -item $it -loc $loc)
		if ($null -ne $bi) { $out += $bi }
	}
	return ,$out
}

# Build order items array.
function Build-Order {
	param($ordNode, [string]$loc)
	if (-not $ordNode) { return @() }
	$out = @()
	foreach ($it in $ordNode.SelectNodes("dcsset:item", $ns)) {
		$xt = Get-LocalXsiType $it
		switch ($xt) {
			'OrderItemAuto'  { $out += 'Auto' }
			'OrderItemField' {
				$fn = Get-Text $it "dcsset:field"
				$ot = Get-Text $it "dcsset:orderType"
				$vmN = $it.SelectSingleNode("dcsset:viewMode", $ns)
				$useV = Get-Text $it "dcsset:use"
				$useFalse = ($useV -eq 'false')
				if ($vmN -or $useFalse) {
					$obj = [ordered]@{ field = $fn }
					if ($useFalse) { $obj['use'] = $false }
					if ($ot -eq 'Desc') { $obj['direction'] = 'desc' }
					if ($vmN) { $obj['viewMode'] = $vmN.InnerText }
					$out += $obj
				} else {
					if ($ot -eq 'Desc') { $out += "$fn desc" } else { $out += $fn }
				}
			}
			default {
				[Console]::Error.WriteLine("form-decompile: пропущен элемент сортировки неизвестного типа '$xt' (path: $loc)")
			}
		}
	}
	return ,$out
}

# Build appearance dict из <dcsset:appearance> (Line/Font/multilang/nested items).
function Get-SettingsAppearance {
	param($appNode)
	if (-not $appNode) { return $null }
	$dict = [ordered]@{}
	foreach ($it in $appNode.SelectNodes("dcscor:item", $ns)) {
		$pName = Get-Text $it "dcscor:parameter"
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $pName -or -not $val) { continue }
		$rawVal = Read-AppearanceValueNode $val
		$useV = Get-Text $it "dcscor:use"
		$nestedItems = [ordered]@{}
		foreach ($sub in $it.SelectNodes("dcscor:item", $ns)) {
			$subName = Get-Text $sub "dcscor:parameter"
			$subVal = $sub.SelectSingleNode("dcscor:value", $ns)
			if (-not $subName) { continue }
			$subRaw = Read-AppearanceValueNode $subVal
			$subUse = Get-Text $sub "dcscor:use"
			$subEntry = [ordered]@{ value = $subRaw }
			if ($subUse -eq 'false') { $subEntry['use'] = $false }
			$nestedItems[$subName] = $subEntry
		}
		$valIsLine = ($rawVal -is [System.Collections.IDictionary]) -and $rawVal.Contains('@type') -and ($rawVal['@type'] -eq 'Line')
		if ($valIsLine) {
			if ($useV -eq 'false') { $rawVal['use'] = $false }
			if ($nestedItems.Count -gt 0) { $rawVal['items'] = $nestedItems }
			$dict[$pName] = $rawVal
		} elseif (($useV -eq 'false') -or ($nestedItems.Count -gt 0)) {
			$wrap = [ordered]@{ value = $rawVal }
			if ($useV -eq 'false') { $wrap['use'] = $false }
			if ($nestedItems.Count -gt 0) { $wrap['items'] = $nestedItems }
			$dict[$pName] = $wrap
		} else {
			$dict[$pName] = $rawVal
		}
	}
	return $dict
}

# Build conditionalAppearance array.
function Build-ConditionalAppearance {
	param($caNode, [string]$loc)
	if (-not $caNode) { return @() }
	$out = @()
	$i = 0
	foreach ($it in $caNode.SelectNodes("dcsset:item", $ns)) {
		$entry = [ordered]@{}
		$scopeNode = $it.SelectSingleNode("dcsset:scope", $ns)
		if ($scopeNode -and $scopeNode.HasChildNodes) {
			[Console]::Error.WriteLine("form-decompile: conditionalAppearance item имеет scope — не воспроизводится в DSL (path: $loc/$i/scope)")
		}
		$selNode = $it.SelectSingleNode("dcsset:selection", $ns)
		if ($selNode -and $selNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
			$entry['selection'] = Build-Selection -selNode $selNode -loc "$loc/$i/selection"
		}
		$filterNode = $it.SelectSingleNode("dcsset:filter", $ns)
		if ($filterNode -and $filterNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
			$f = @()
			foreach ($fc in $filterNode.SelectNodes("dcsset:item", $ns)) {
				$bi = (Build-FilterItem -itemNode $fc -loc "$loc/$i/filter")
				if ($null -ne $bi) { $f += $bi }
			}
			$entry['filter'] = $f
		}
		$appNode = $it.SelectSingleNode("dcsset:appearance", $ns)
		$ap = Get-SettingsAppearance $appNode
		if ($ap -and $ap.Count -gt 0) { $entry['appearance'] = $ap }
		$presNode = $it.SelectSingleNode("dcsset:presentation", $ns)
		if ($presNode) {
			$pres = Get-MLText $presNode
			if (-not $pres) { $pres = $presNode.InnerText }
			if ($pres) { $entry['presentation'] = $pres }
		}
		$vmN = $it.SelectSingleNode("dcsset:viewMode", $ns)
		if ($vmN) { $entry['viewMode'] = $vmN.InnerText }
		$usid = Get-Text $it "dcsset:userSettingID"
		if ($usid) { $entry['userSettingID'] = 'auto' }
		$uspN = $it.SelectSingleNode("dcsset:userSettingPresentation", $ns)
		if ($uspN) {
			$usp = Get-PresText $uspN
			if ($usp) { $entry['userSettingPresentation'] = $usp }
		}
		$useV = Get-Text $it "dcsset:use"
		if ($useV -eq 'false') { $entry['use'] = $false }
		$useInDontUse = @()
		foreach ($ch in $it.ChildNodes) {
			if ($ch.NodeType -ne 'Element' -or $ch.NamespaceURI -ne $NS_DCSSET) { continue }
			if ($ch.LocalName -match '^useIn(.+)$' -and $ch.InnerText -eq 'DontUse') {
				$shortName = ($matches[1]).Substring(0, 1).ToLower() + ($matches[1]).Substring(1)
				$useInDontUse += $shortName
			}
		}
		if ($useInDontUse.Count -gt 0) { $entry['useInDontUse'] = $useInDontUse }
		$out += $entry
		$i++
	}
	return ,$out
}

# Общие layout-свойства → в $obj (симметрично Emit-Layout компилятора).
# Вызывается один раз для любого элемента. Height тут — пиксельная высота
# (<Height>); Table хранит высоту в строках (<HeightInTableRows>) и ловит её сам.
function Add-Layout {
	param($obj, $node)
	# Общие свойства элемента (любой тип): default/drag/skip
	if ((Get-Child $node 'DefaultItem') -eq 'true') { $obj['defaultItem'] = $true }
	$soi = Get-Child $node 'SkipOnInput'; if ($null -ne $soi) { $obj['skipOnInput'] = ($soi -eq 'true') }
	if ((Get-Child $node 'EnableStartDrag') -eq 'true') { $obj['enableStartDrag'] = $true }
	$fdm = Get-Child $node 'FileDragMode'; if ($fdm) { $obj['fileDragMode'] = $fdm }
	if ((Get-Child $node 'AutoMaxWidth') -eq 'false') { $obj['autoMaxWidth'] = $false }
	$mw = Get-Child $node 'MaxWidth'; if ($mw) { $obj['maxWidth'] = [int]$mw }
	if ((Get-Child $node 'AutoMaxHeight') -eq 'false') { $obj['autoMaxHeight'] = $false }
	$mh = Get-Child $node 'MaxHeight'; if ($mh) { $obj['maxHeight'] = [int]$mh }
	$w = Get-Child $node 'Width'; if ($w) { $obj['width'] = [int]$w }
	$h = Get-Child $node 'Height'; if ($h) { $obj['height'] = [int]$h }
	if ((Get-Child $node 'HorizontalStretch') -eq 'true') { $obj['horizontalStretch'] = $true }
	if ((Get-Child $node 'VerticalStretch') -eq 'true') { $obj['verticalStretch'] = $true }
	$gha = Get-Child $node 'GroupHorizontalAlign'; if ($gha) { $obj['groupHorizontalAlign'] = $gha }
	$gva = Get-Child $node 'GroupVerticalAlign'; if ($gva) { $obj['groupVerticalAlign'] = $gva }
	$ha = Get-Child $node 'HorizontalAlign'; if ($ha) { $obj['horizontalAlign'] = $ha }
}

# TitleLocation у check/radio (зеркало Emit-TitleLocation):
#   тега нет → "" (дефолт платформы); значение = умный дефолт → опускаем; иначе пишем.
function Add-TitleLocation {
	param($obj, $node, [string]$smartDefault)
	$tl = Get-Child $node 'TitleLocation'
	if ($null -eq $tl) { $obj['titleLocation'] = '' }
	elseif ($tl -ne $smartDefault) { $obj['titleLocation'] = $tl.ToLower() }
}

# Разобрать <Events> элемента → упорядоченная мапа { ИмяСобытия: ИмяОбработчика }
# в порядке документа. Имена обработчиков всегда явные (как у событий формы) —
# единый, консистентный с form-level формат. Legacy on/handlers больше не эмитим.
function Get-Events {
	param($node, [string]$elName)
	$ev = $node.SelectSingleNode("lf:Events", $ns)
	if (-not $ev) { return $null }
	$events = [ordered]@{}
	foreach ($e in @($ev.SelectNodes("lf:Event", $ns))) {
		$events[$e.GetAttribute("name")] = $e.InnerText
	}
	if ($events.Count -eq 0) { return $null }
	return $events
}

# Инверсия Emit-XrFlag: role-adjustable boolean (UserVisible/View/Edit/Use).
# <TAG><xr:Common/>[<xr:Value name="Role.X"/>…]</TAG> → скаляр bool (без ролей) или объект { common, roles:{Имя:bool} }.
# Имя роли отдаём без префикса "Role.". Возвращает $null, если тег отсутствует.
function Decompile-XrFlag {
	param($node, [string]$tag)
	$el = $node.SelectSingleNode("*[local-name()='$tag']")
	if (-not $el) { return $null }
	$commonNode = $el.SelectSingleNode("*[local-name()='Common']")
	$common = ($commonNode -and $commonNode.InnerText -eq 'true')
	$valNodes = @($el.SelectNodes("*[local-name()='Value']"))
	if ($valNodes.Count -eq 0) { return $common }
	$roles = [ordered]@{}
	foreach ($v in $valNodes) {
		$rn = $v.GetAttribute("name")
		if ($rn -match '^Role\.') { $rn = $rn.Substring(5) }
		$roles[$rn] = ($v.InnerText -eq 'true')
	}
	$o = [ordered]@{}
	$o['common'] = $common
	$o['roles'] = $roles
	return $o
}

# <FunctionalOptions><Item>FunctionalOption.X</Item>…> → массив строк (префикс FunctionalOption. снят; GUID — как есть).
function Decompile-FunctionalOptions {
	param($node)
	$foNode = $node.SelectSingleNode("lf:FunctionalOptions", $ns)
	if (-not $foNode) { return $null }
	$opts = New-Object System.Collections.ArrayList
	foreach ($it in @($foNode.SelectNodes("lf:Item", $ns))) {
		$t = $it.InnerText.Trim() -replace '^FunctionalOption\.', ''
		[void]$opts.Add($t)
	}
	if ($opts.Count -gt 0) { return ,@($opts) }
	return $null
}

# Колонка реквизита (прямая или внутри AdditionalColumns): name/type/title/functionalOptions.
function Decompile-AttrColumn {
	param($c)
	$co = [ordered]@{}; $co['name'] = $c.GetAttribute("name")
	$cty = Decompile-Type ($c.SelectSingleNode("lf:Type", $ns)); if ($cty) { $co['type'] = $cty }
	$ctNode = $c.SelectSingleNode("lf:Title", $ns); if ($ctNode) { $t = Get-LangText $ctNode; if ($null -ne $t) { $co['title'] = $t } }
	$cfo = Decompile-FunctionalOptions $c; if ($cfo) { $co['functionalOptions'] = $cfo }
	return $co
}

# Общие свойства элемента (visible/enabled/readonly/title/events) → в hash
function Add-CommonProps {
	param($obj, $node, [string]$elName)
	if ((Get-Child $node 'Visible') -eq 'false') { $obj['hidden'] = $true }
	if ((Get-Child $node 'Enabled') -eq 'false') { $obj['disabled'] = $true }
	if ((Get-Child $node 'ReadOnly') -eq 'true') { $obj['readOnly'] = $true }
	$uv = Decompile-XrFlag $node 'UserVisible'; if ($null -ne $uv) { $obj['userVisible'] = $uv }
	$titleNode = $node.SelectSingleNode("lf:Title", $ns)
	if ($titleNode) {
		$t = Get-LangText $titleNode
		if ($null -ne $t) { $obj['title'] = $t }
		# formatted у LabelDecoration выводится компилятором из hyperlink — отдельный ключ не нужен (#16 хвост)
	}
	$ttNode = $node.SelectSingleNode("lf:ToolTip", $ns)
	if ($ttNode) { $tt = Get-LangText $ttNode; if ($null -ne $tt) { $obj['tooltip'] = $tt } }
	$ttr = Get-Child $node 'ToolTipRepresentation'; if ($ttr) { $obj['tooltipRepresentation'] = $ttr }
	$ev = Get-Events $node $elName
	if ($ev) { $obj['events'] = $ev }
}

# --- 3. Type decompile (inverse of Emit-Type) ---
function Decompile-Type {
	param($typeNode)
	if (-not $typeNode) { return $null }
	$parts = New-Object System.Collections.ArrayList
	foreach ($vt in @($typeNode.SelectNodes("v8:Type", $ns))) {
		$raw = $vt.InnerText.Trim()
		$short = $raw
		# break обязателен: иначе общий case ^(v8|v8ui|cfg): перетирает специфичные (напр. v8:ValueListType → ValueList).
		switch -regex ($raw) {
			'^xs:string$' {
				$len = $typeNode.SelectSingleNode("v8:StringQualifiers/v8:Length", $ns)
				if ($len -and [int]$len.InnerText -gt 0) { $short = "string($($len.InnerText))" } else { $short = "string" }
				break
			}
			'^xs:decimal$' {
				$d = $typeNode.SelectSingleNode("v8:NumberQualifiers/v8:Digits", $ns)
				$f = $typeNode.SelectSingleNode("v8:NumberQualifiers/v8:FractionDigits", $ns)
				$sgn = $typeNode.SelectSingleNode("v8:NumberQualifiers/v8:AllowedSign", $ns)
				$dd = if ($d) { $d.InnerText } else { '0' }
				$ff = if ($f) { $f.InnerText } else { '0' }
				if ($sgn -and $sgn.InnerText -eq 'Nonnegative') { $short = "decimal($dd,$ff,nonneg)" } else { $short = "decimal($dd,$ff)" }
				break
			}
			'^xs:boolean$' { $short = "boolean"; break }
			'^xs:dateTime$' {
				$df = $typeNode.SelectSingleNode("v8:DateQualifiers/v8:DateFractions", $ns)
				$dfv = if ($df) { $df.InnerText } else { 'DateTime' }
				switch ($dfv) { 'Date' { $short = 'date' } 'Time' { $short = 'time' } default { $short = 'dateTime' } }
				break
			}
			'^cfg:(.+)$' { $short = $matches[1]; break }
			'^(v8|v8ui):' {
				# Платформенный тип: friendly-шорткат если есть, иначе оставляем с префиксом
				# (компилятор эмитит verbatim) — чтобы не терять v8:UUID и прочий хвост.
				$rev = @{
					'v8:ValueTable'='ValueTable'; 'v8:ValueTree'='ValueTree'; 'v8:ValueListType'='ValueList'
					'v8:TypeDescription'='TypeDescription'; 'v8:Universal'='Universal'
					'v8:FixedArray'='FixedArray'; 'v8:FixedStructure'='FixedStructure'
					'v8ui:FormattedString'='FormattedString'; 'v8ui:Picture'='Picture'; 'v8ui:Color'='Color'; 'v8ui:Font'='Font'
				}
				if ($rev.ContainsKey($raw)) { $short = $rev[$raw] } else { $short = $raw }
				break
			}
			default { $short = $raw }
		}
		[void]$parts.Add($short)
	}
	# TypeSet (набор типов): определяемый тип / характеристика / «любая ссылка вида».
	# Префикс cfg:/v8: снимаем — обратный роутинг в компиляторе по форме токена.
	foreach ($ts in @($typeNode.SelectNodes("v8:TypeSet", $ns))) {
		$raw = $ts.InnerText.Trim()
		$short = $raw -replace '^(v8ui|v8|cfg):', ''
		[void]$parts.Add($short)
	}
	if ($parts.Count -eq 0) { return $null }
	if ($parts.Count -eq 1) { return $parts[0] }
	return ($parts -join ' | ')
}

# --- 4. Element dispatch ---
$ELEMENT_KEY = @{
	'UsualGroup'='group'; 'ColumnGroup'='columnGroup'; 'ButtonGroup'='buttonGroup'; 'InputField'='input'; 'CheckBoxField'='check';
	'RadioButtonField'='radio'; 'LabelDecoration'='label'; 'LabelField'='labelField';
	'PictureDecoration'='picture'; 'PictureField'='picField'; 'CalendarField'='calendar';
	'Table'='table'; 'Pages'='pages'; 'Page'='page'; 'Button'='button'; 'CommandBar'='cmdBar'; 'Popup'='popup'
}

function Decompile-Children {
	param($parentNode, [string]$childContainer = 'ChildItems')
	$container = $parentNode.SelectSingleNode("lf:$childContainer", $ns)
	if (-not $container) { return $null }
	$list = New-Object System.Collections.ArrayList
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		if ($COMPANION_TAGS -contains $child.LocalName) { continue }
		$el = Decompile-Element $child
		if ($el) { [void]$list.Add($el) }
	}
	if ($list.Count -eq 0) { return $null }
	return ,@($list)
}

# Инверсия Emit-CompanionPanel: companion-командная-панель (ContextMenu/AutoCommandBar) с контентом
# → { autofill?, horizontalAlign?, children?[] } либо $null, если companion пустой (self-closing).
# Дин-список-таблица: компилятор-эвристика додумывает Autofill=false. Выражаем только ОТКЛОНЕНИЕ:
#   autofill=false (нет детей) → совпадает с дефолтом → молчим;
#   голый <AutoCommandBar/> (autofill=true по умолчанию) → маркер { autofill: true } (панель не скрыта).
function Decompile-CompanionPanel {
	param($node, [string]$tag, [bool]$isDynListTable = $false)
	$p = $node.SelectSingleNode("lf:$tag", $ns)
	if (-not $p) { return $null }
	$autofillRaw = Get-Child $p 'Autofill'
	$halign = Get-Child $p 'HorizontalAlign'
	$kids = Decompile-Children $p
	$hasKids = $kids -and @($kids).Count -gt 0
	if ($isDynListTable -and $tag -eq 'AutoCommandBar' -and -not $hasKids -and -not $halign) {
		if ($autofillRaw -eq 'false') { return $null }            # = дефолт эвристики → молчим
		return [ordered]@{ autofill = $true }                      # голая панель → отклонение
	}
	if (-not $hasKids -and $null -eq $autofillRaw -and -not $halign) { return $null }
	$o = [ordered]@{}
	if ($halign) { $o['horizontalAlign'] = $halign }
	if ($autofillRaw -eq 'false') { $o['autofill'] = $false }
	elseif ($autofillRaw -eq 'true') { $o['autofill'] = $true }
	if ($hasKids) { $o['children'] = $kids }
	return $o
}

# Инверсия Emit-ChoiceList: <ChoiceList><xr:Item>… → [ { value, presentation? } ] либо $null.
# У RadioButtonField и InputField.
function Decompile-ChoiceList {
	param($node)
	$cl = $node.SelectSingleNode("lf:ChoiceList", $ns)
	if (-not $cl) { return $null }
	$items = New-Object System.Collections.ArrayList
	foreach ($it in @($cl.SelectNodes("xr:Item", $ns))) {
		$valNode = $it.SelectSingleNode("xr:Value/lf:Value", $ns)
		$presNode = $it.SelectSingleNode("xr:Value/lf:Presentation", $ns)
		$ci = [ordered]@{}
		if ($valNode) {
			$xsiType = $valNode.GetAttribute("type", $NS_XSI)
			$ci['value'] = Convert-TypedValue $valNode.InnerText $xsiType
		}
		if ($presNode) { $p = Get-LangText $presNode; if ($p) { $ci['presentation'] = $p } }
		[void]$items.Add($ci)
	}
	if ($items.Count -gt 0) { return ,@($items) }
	return $null
}

function Decompile-Element {
	param($node)
	$tag = $node.LocalName
	if (-not $ELEMENT_KEY.ContainsKey($tag)) {
		Fail-Ring3 -kind "элемент <$tag>" -loc "ChildItems/$tag"
	}
	$key = $ELEMENT_KEY[$tag]
	$name = $node.GetAttribute("name")
	$obj = [ordered]@{}

	switch ($tag) {
		'UsualGroup' {
			# group = направление (<Group>); behavior = <Behavior> (Авто = нет тега → ключ опускаем).
			$g = Get-Child $node 'Group'
			$gmap = @{ 'Horizontal'='horizontal'; 'Vertical'='vertical'; 'AlwaysHorizontal'='alwaysHorizontal'; 'AlwaysVertical'='alwaysVertical' }
			if ($g -and $gmap.ContainsKey($g)) { $obj[$key] = $gmap[$g] } else { $obj[$key] = 'vertical' }
			$behavior = Get-Child $node 'Behavior'
			if ($behavior) {
				$bmap = @{ 'Usual'='usual'; 'Collapsible'='collapsible'; 'PopUp'='popup' }
				if ($bmap.ContainsKey($behavior)) { $obj['behavior'] = $bmap[$behavior] } else { $obj['behavior'] = $behavior }
			}
			$obj['name'] = $name
			Add-CommonProps $obj $node $name
			$rep = Get-Child $node 'Representation'
			if ($rep) { $repmap=@{'None'='none';'NormalSeparation'='normal';'WeakSeparation'='weak';'StrongSeparation'='strong'}; if ($repmap.ContainsKey($rep)) { $obj['representation']=$repmap[$rep] } else { $obj['representation']=$rep } }
			if ((Get-Child $node 'ShowTitle') -eq 'false') { $obj['showTitle'] = $false }
			if ((Get-Child $node 'United') -eq 'false') { $obj['united'] = $false }
			if ((Get-Child $node 'Collapsed') -eq 'true') { $obj['collapsed'] = $true }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'ColumnGroup' {
			$g = Get-Child $node 'Group'
			$gmap = @{ 'Horizontal'='horizontal'; 'Vertical'='vertical'; 'InCell'='inCell' }
			if ($g -and $gmap.ContainsKey($g)) { $obj[$key] = $gmap[$g] } else { $obj[$key] = 'horizontal' }
			$obj['name'] = $name
			Add-CommonProps $obj $node $name
			if ((Get-Child $node 'ShowTitle') -eq 'false') { $obj['showTitle'] = $false }
			$sih = Get-Child $node 'ShowInHeader'; if ($null -ne $sih) { $obj['showInHeader'] = (To-Bool $sih) }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'InputField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			if ((Get-Child $node 'MultiLine') -eq 'true') { $obj['multiLine'] = $true }
			if ((Get-Child $node 'PasswordMode') -eq 'true') { $obj['passwordMode'] = $true }
			if ((Get-Child $node 'AutoMarkIncomplete') -eq 'true') { $obj['markIncomplete'] = $true }
			$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
			$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
			$ih = $node.SelectSingleNode("lf:InputHint", $ns); if ($ih) { $t = Get-LangText $ih; if ($t) { $obj['inputHint'] = $t } }
			foreach ($p in @('ChoiceButton','ClearButton','SpinButton','DropListButton')) {
				$v = Get-Child $node $p; if ($null -ne $v) { $obj[($p.Substring(0,1).ToLower()+$p.Substring(1))] = (To-Bool $v) }
			}
			$cl = Decompile-ChoiceList $node; if ($cl) { $obj['choiceList'] = $cl }
		}
		'CheckBoxField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
			# CheckBoxType: Auto = умный дефолт → опустить; нет тега → ""; иначе значение
			$cbt = Get-Child $node 'CheckBoxType'
			if ($null -eq $cbt) { $obj['checkBoxType'] = '' }
			elseif ($cbt -ne 'Auto') { $obj['checkBoxType'] = $cbt.Substring(0,1).ToLower() + $cbt.Substring(1) }
			Add-TitleLocation $obj $node 'Right'
		}
		'RadioButtonField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			Add-TitleLocation $obj $node 'None'
			$rbt = Get-Child $node 'RadioButtonType'; if ($rbt) { $obj['radioButtonType'] = $rbt }
			$cc = Get-Child $node 'ColumnsCount'; if ($cc) { $obj['columnsCount'] = [int]$cc }
			$cl = Decompile-ChoiceList $node; if ($cl) { $obj['choiceList'] = $cl }
		}
		'LabelDecoration' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			if ((Get-Child $node 'Hyperlink') -eq 'true') { $obj['hyperlink'] = $true }
			# title декорации — единая ML-text форма с авто-детектом formatted (как extendedTooltip)
			$tiNode = $node.SelectSingleNode("lf:Title", $ns)
			if ($tiNode) { $tv = Get-MLFormattedValue $tiNode; if ($null -ne $tv) { $obj['title'] = $tv } }
		}
		'LabelField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
			$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
			# LabelField: тег <Hiperlink> (опечатка платформы), не <Hyperlink>
			if ((Get-Child $node 'Hiperlink') -eq 'true') { $obj['hyperlink'] = $true }
		}
		'PictureDecoration' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			# title декорации — единая ML-text форма с formatted (атрибут <Title formatted> у PictureDecoration)
			$tiNode = $node.SelectSingleNode("lf:Title", $ns)
			if ($tiNode) { $tv = Get-MLFormattedValue $tiNode; if ($null -ne $tv) { $obj['title'] = $tv } }
			$ref = $node.SelectSingleNode("lf:Picture/xr:Ref", $ns); if ($ref) { $obj['src'] = $ref.InnerText }
			$lt = $node.SelectSingleNode("lf:Picture/xr:LoadTransparent", $ns); if ($lt -and $lt.InnerText -eq 'true') { $obj['loadTransparent'] = $true }
			if ((Get-Child $node 'Hyperlink') -eq 'true') { $obj['hyperlink'] = $true }
		}
		'PictureField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
			$ref = $node.SelectSingleNode("lf:ValuesPicture/xr:Ref", $ns); if ($ref) { $obj['valuesPicture'] = $ref.InnerText }
		}
		'CalendarField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
			$sm = Get-Child $node 'SelectionMode'; if ($sm) { $obj['selectionMode'] = $sm }
			$scd = Get-Child $node 'ShowCurrentDate'; if ($null -ne $scd) { $obj['showCurrentDate'] = ($scd -eq 'true') }
			$wim = Get-Child $node 'WidthInMonths'; if ($null -ne $wim) { $obj['widthInMonths'] = [int]$wim }
			$him = Get-Child $node 'HeightInMonths'; if ($null -ne $him) { $obj['heightInMonths'] = [int]$him }
			$smp = Get-Child $node 'ShowMonthsPanel'; if ($null -ne $smp) { $obj['showMonthsPanel'] = ($smp -eq 'true') }
		}
		'Table' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			$crs = Get-Child $node 'ChangeRowSet'; if ($null -ne $crs) { $obj['changeRowSet'] = ($crs -eq 'true') }
			$cro = Get-Child $node 'ChangeRowOrder'; if ($null -ne $cro) { $obj['changeRowOrder'] = ($cro -eq 'true') }
			if ((Get-Child $node 'AutoInsertNewRow') -eq 'true') { $obj['autoInsertNewRow'] = $true }
			if ((Get-Child $node 'EnableDrag') -eq 'true') { $obj['enableDrag'] = $true }
			if ($node.SelectSingleNode("lf:RowFilter", $ns)) { $obj['rowFilter'] = $null }
			if ((Get-Child $node 'Header') -eq 'false') { $obj['header'] = $false }
			if ((Get-Child $node 'Footer') -eq 'true') { $obj['footer'] = $true }
			$htr = Get-Child $node 'HeightInTableRows'; if ($htr) { $obj['height'] = [int]$htr }
			$cbl = Get-Child $node 'CommandBarLocation'; if ($cbl) { $obj['commandBarLocation'] = $cbl }
			$ssl = Get-Child $node 'SearchStringLocation'; if ($ssl) { $obj['searchStringLocation'] = $ssl }
			$vsl = Get-Child $node 'ViewStatusLocation'; if ($vsl) { $obj['viewStatusLocation'] = $vsl }
			$scl = Get-Child $node 'SearchControlLocation'; if ($scl) { $obj['searchControlLocation'] = $scl }
			# --- Общие свойства таблицы (любой тип таблицы, не только динсписок) ---
			if ((Get-Child $node 'ChoiceMode') -eq 'true') { $obj['choiceMode'] = $true }
			$selm = Get-Child $node 'SelectionMode'; if ($selm) { $obj['selectionMode'] = $selm }
			$rsm = Get-Child $node 'RowSelectionMode'; if ($rsm) { $obj['rowSelectionMode'] = $rsm }
			if ((Get-Child $node 'VerticalLines') -eq 'false') { $obj['verticalLines'] = $false }
			if ((Get-Child $node 'HorizontalLines') -eq 'false') { $obj['horizontalLines'] = $false }
			if ((Get-Child $node 'UseAlternationRowColor') -eq 'true') { $obj['useAlternationRowColor'] = $true }
			$itv = Get-Child $node 'InitialTreeView'; if ($itv) { $obj['initialTreeView'] = $itv }
			$rpRef = $node.SelectSingleNode("lf:RowsPicture/xr:Ref", $ns); if ($rpRef) { $obj['rowsPicture'] = $rpRef.InnerText }
			$rpdp = Get-Child $node 'RowPictureDataPath'
			# --- Блок дин-список-таблицы (признак: дочерний <UpdateOnDataChange>) ---
			if (Has-Child $node 'UpdateOnDataChange') {
				if ((Get-Child $node 'AutoRefresh') -eq 'true') { $obj['autoRefresh'] = $true }
				$arp = Get-Child $node 'AutoRefreshPeriod'; if ($arp -and $arp -ne '60') { $obj['autoRefreshPeriod'] = [int]$arp }
				$cfi = Get-Child $node 'ChoiceFoldersAndItems'; if ($cfi -and $cfi -ne 'Items') { $obj['choiceFoldersAndItems'] = $cfi }
				if ((Get-Child $node 'RestoreCurrentRow') -eq 'true') { $obj['restoreCurrentRow'] = $true }
				if ((Get-Child $node 'ShowRoot') -eq 'false') { $obj['showRoot'] = $false }
				if ((Get-Child $node 'AllowRootChoice') -eq 'true') { $obj['allowRootChoice'] = $true }
				$uodc = Get-Child $node 'UpdateOnDataChange'; if ($uodc -and $uodc -ne 'Auto') { $obj['updateOnDataChange'] = $uodc }
				if ((Get-Child $node 'AllowGettingCurrentRowURL') -eq 'false') { $obj['allowGettingCurrentRowURL'] = $false }
				# RowPictureDataPath: инверсия умного дефолта <Список>.DefaultPicture
				if ($null -eq $rpdp) { $obj['rowPictureDataPath'] = '' }
				elseif ($rpdp -ne "$($obj['path']).DefaultPicture") { $obj['rowPictureDataPath'] = $rpdp }
				$usg = Get-Child $node 'UserSettingsGroup'; if ($usg) { $obj['userSettingsGroup'] = $usg }
			} elseif ($rpdp) { $obj['rowPictureDataPath'] = $rpdp }
			$csNode = $node.SelectSingleNode("lf:CommandSet", $ns)
			if ($csNode) {
				$exc = New-Object System.Collections.ArrayList
				foreach ($ec in @($csNode.SelectNodes("lf:ExcludedCommand", $ns))) { [void]$exc.Add($ec.InnerText) }
				if ($exc.Count -gt 0) { $obj['excludedCommands'] = @($exc) }
			}
			$cols = Decompile-Children $node
			if ($cols) { $obj['columns'] = $cols }
		}
		'Pages' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$pr = Get-Child $node 'PagesRepresentation'; if ($pr) { $obj['pagesRepresentation'] = $pr }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'Page' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$g = Get-Child $node 'Group'
			$gmap = @{ 'Horizontal'='horizontal'; 'Vertical'='vertical'; 'AlwaysHorizontal'='alwaysHorizontal'; 'AlwaysVertical'='alwaysVertical' }
			if ($g -and $gmap.ContainsKey($g)) { $obj['group'] = $gmap[$g] }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'Button' {
			$obj[$key] = $name
			$cmd = Get-Child $node 'CommandName'
			if ($cmd) {
				if ($cmd -match '^Form\.Command\.(.+)$') { $obj['command'] = $matches[1] }
				elseif ($cmd -match '^Form\.StandardCommand\.(.+)$') { $obj['stdCommand'] = $matches[1] }
				elseif ($cmd -match '^Form\.Item\.(.+)\.StandardCommand\.(.+)$') { $obj['stdCommand'] = "$($matches[1]).$($matches[2])" }
				else { $obj['commandName'] = $cmd }
			}
			Add-CommonProps $obj $node $name
			$type = Get-Child $node 'Type'
			if ($type) { $tmap=@{'CommandBarButton'='commandBar';'UsualButton'='usual';'Hyperlink'='hyperlink';'CommandBarHyperlink'='hyperlink'}; if ($tmap.ContainsKey($type)) { $obj['type']=$tmap[$type] } else { $obj['type']=$type } }
			if ((Get-Child $node 'DefaultButton') -eq 'true') { $obj['defaultButton'] = $true }
			$ref = $node.SelectSingleNode("lf:Picture/xr:Ref", $ns); if ($ref) { $obj['picture'] = $ref.InnerText }
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			$lic = Get-Child $node 'LocationInCommandBar'; if ($lic) { $obj['locationInCommandBar'] = $lic }
		}
		'ButtonGroup' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$cs = Get-Child $node 'CommandSource'; if ($cs) { $obj['commandSource'] = $cs }
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'CommandBar' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$cs = Get-Child $node 'CommandSource'; if ($cs) { $obj['commandSource'] = $cs }
			if ((Get-Child $node 'Autofill') -eq 'true') { $obj['autofill'] = $true }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'Popup' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$ref = $node.SelectSingleNode("lf:Picture/xr:Ref", $ns); if ($ref) { $obj['picture'] = $ref.InnerText }
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
	}
	# title: "" — подавление авто-вывода: для типов, где компилятор вывел бы
	# заголовок из имени, а в оригинале <Title> отсутствует.
	if (-not $obj.Contains('title')) {
		$autoTitle = $false
		if ($tag -in @('LabelDecoration','Page','Popup')) { $autoTitle = $true }
		elseif ($tag -eq 'Button') { $autoTitle = -not ($obj.Contains('command') -or $obj.Contains('commandName') -or $obj.Contains('stdCommand')) }
		elseif ($tag -in @('InputField','CheckBoxField','RadioButtonField','LabelField','Table','CalendarField')) { $autoTitle = -not $obj.Contains('path') }
		if ($autoTitle) { $obj['title'] = '' }
	}
	Add-Layout $obj $node
	# extendedTooltip: контент companion <ExtendedTooltip><Title> (любой элемент)
	$etTitle = $node.SelectSingleNode("lf:ExtendedTooltip/lf:Title", $ns)
	if ($etTitle) { $et = Get-MLFormattedValue $etTitle; if ($null -ne $et) { $obj['extendedTooltip'] = $et } }
	# companion-панели с контентом: AutoCommandBar → commandBar, ContextMenu → contextMenu (любой элемент)
	$isDynListTable = ($tag -eq 'Table') -and (Has-Child $node 'UpdateOnDataChange')
	$cb = Decompile-CompanionPanel $node 'AutoCommandBar' $isDynListTable
	if ($null -ne $cb) { $obj['commandBar'] = $cb }
	$cm = Decompile-CompanionPanel $node 'ContextMenu'
	if ($null -ne $cm) { $obj['contextMenu'] = $cm }
	return $obj
}

# --- 5. Form-level assembly ---
$dsl = [ordered]@{}

$titleNode = $root.SelectSingleNode("lf:Title", $ns)
if ($titleNode) { $t = Get-LangText $titleNode; if ($null -ne $t) { $dsl['title'] = $t } }

# properties (прямые скаляры под <Form>, PascalCase → camelCase)
$KNOWN_FORM_PROPS = @('AutoTitle','WindowOpeningMode','CommandBarLocation','SaveDataInSettings','AutoSaveDataInSettings','AutoTime','UsePostingMode','RepostOnWrite','AutoURL','AutoFillCheck','Customizable','EnterKeyBehavior','VerticalScroll','Width','Height','Group','UseForFoldersAndItems')
$props = [ordered]@{}
foreach ($pn in $KNOWN_FORM_PROPS) {
	$v = Get-Child $root $pn
	if ($null -ne $v) {
		$camel = $pn.Substring(0,1).ToLower() + $pn.Substring(1)
		if ($v -eq 'true') { $props[$camel] = $true }
		elseif ($v -eq 'false') { $props[$camel] = $false }
		elseif ($v -match '^\d+$') { $props[$camel] = [int]$v }
		else { $props[$camel] = $v }
	}
}
# autoTitle=false при наличии title — это инъекция компилятора, опускаем (валидируем раундтрипом)
if ($dsl.Contains('title') -and $props.Contains('autoTitle') -and $props['autoTitle'] -eq $false) { $props.Remove('autoTitle') }
if ($props.Count -gt 0) { $dsl['properties'] = $props }

# excludedCommands (form-level <CommandSet>)
$csForm = $root.SelectSingleNode("lf:CommandSet", $ns)
if ($csForm) {
	$excForm = New-Object System.Collections.ArrayList
	foreach ($ec in @($csForm.SelectNodes("lf:ExcludedCommand", $ns))) { [void]$excForm.Add($ec.InnerText) }
	if ($excForm.Count -gt 0) { $dsl['excludedCommands'] = @($excForm) }
}

# events (form-level)
$evForm = Get-Events $root $null
if ($evForm) {
	# form-level: компилятор хранит как {Event: handler} напрямую
	$evMap = [ordered]@{}
	$evNode = $root.SelectSingleNode("lf:Events", $ns)
	foreach ($e in @($evNode.SelectNodes("lf:Event", $ns))) { $evMap[$e.GetAttribute("name")] = $e.InnerText }
	if ($evMap.Count -gt 0) { $dsl['events'] = $evMap }
}

# Зеркало компилятор-эвристики B3 (Compute-MainAcbAutofill): наличие cmdBar-элемента где-либо
# в дереве → форменный AutoCommandBar autofill=false. Нужно, чтобы предсказать вывод и выразить
# отклонение (голый корень при наличии cmdBar).
function Test-AnyCmdBar {
	param($list)
	if (-not $list) { return $false }
	foreach ($e in $list) {
		if ($e -is [System.Collections.IDictionary] -and $e.Contains('cmdBar')) { return $true }
		if ($e -is [System.Collections.IDictionary]) {
			if ($e.Contains('children') -and (Test-AnyCmdBar $e['children'])) { return $true }
			if ($e.Contains('columns') -and (Test-AnyCmdBar $e['columns'])) { return $true }
		}
	}
	return $false
}

# elements (+ форменный AutoCommandBar как autoCmdBar-элемент, если у него есть содержимое/отклонение)
$elemList = New-Object System.Collections.ArrayList
$elements = Decompile-Children $root
$formHasCmdBar = Test-AnyCmdBar $elements
$acb = $root.SelectSingleNode("lf:AutoCommandBar", $ns)
if ($acb) {
	$haln = Get-Child $acb 'HorizontalAlign'
	$acbAutofill = Get-Child $acb 'Autofill'
	$acbKids = Decompile-Children $acb
	$acbObj = $null
	if ($haln -or ($acbAutofill -eq 'false') -or $acbKids) {
		$acbObj = [ordered]@{}
		$acbObj['autoCmdBar'] = $acb.GetAttribute("name")
		if ($haln) { $acbObj['horizontalAlign'] = $haln }
		if ($acbAutofill -eq 'false') { $acbObj['autofill'] = $false }
		if ($acbKids) { $acbObj['children'] = $acbKids }
	} elseif ($formHasCmdBar -and $null -eq $acbAutofill) {
		# Корень голый (autofill=true по умолчанию), но эвристика B3 дала бы false (есть cmdBar) → маркер
		$acbObj = [ordered]@{}
		$acbObj['autoCmdBar'] = $acb.GetAttribute("name")
		$acbObj['autofill'] = $true
	}
	if ($acbObj) { [void]$elemList.Add($acbObj) }
}
if ($elements) { foreach ($e in $elements) { [void]$elemList.Add($e) } }
if ($elemList.Count -gt 0) { $dsl['elements'] = @($elemList) }

# attributes
$attrsNode = $root.SelectSingleNode("lf:Attributes", $ns)
if ($attrsNode) {
	$attrs = New-Object System.Collections.ArrayList
	foreach ($a in @($attrsNode.SelectNodes("lf:Attribute", $ns))) {
		$ao = [ordered]@{}
		$ao['name'] = $a.GetAttribute("name")
		$ty = Decompile-Type ($a.SelectSingleNode("lf:Type", $ns)); if ($ty) { $ao['type'] = $ty }
		if ((Get-Child $a 'MainAttribute') -eq 'true') { $ao['main'] = $true }
		$vw = Decompile-XrFlag $a 'View'; if ($null -ne $vw) { $ao['view'] = $vw }
		$ed = Decompile-XrFlag $a 'Edit'; if ($null -ne $ed) { $ao['edit'] = $ed }
		$tNode = $a.SelectSingleNode("lf:Title", $ns); if ($tNode) { $t = Get-LangText $tNode; if ($null -ne $t) { $ao['title'] = $t } }
		if ((Get-Child $a 'SavedData') -eq 'true') { $ao['savedData'] = $true }
		$fc = Get-Child $a 'FillChecking'; if ($fc) { $ao['fillChecking'] = $fc }
		$afo = Decompile-FunctionalOptions $a; if ($afo) { $ao['functionalOptions'] = $afo }
		$colsNode = $a.SelectSingleNode("lf:Columns", $ns)
		if ($colsNode) {
			$cols = New-Object System.Collections.ArrayList
			foreach ($c in @($colsNode.SelectNodes("lf:Column", $ns))) { [void]$cols.Add((Decompile-AttrColumn $c)) }
			if ($cols.Count -gt 0) { $ao['columns'] = @($cols) }
			# AdditionalColumns: доп. колонки табличных частей объекта (группа на табличную часть)
			$addNodes = @($colsNode.SelectNodes("lf:AdditionalColumns", $ns))
			if ($addNodes.Count -gt 0) {
				$addList = New-Object System.Collections.ArrayList
				foreach ($an in $addNodes) {
					$acObj = [ordered]@{}; $acObj['table'] = $an.GetAttribute("table")
					$acCols = New-Object System.Collections.ArrayList
					foreach ($c in @($an.SelectNodes("lf:Column", $ns))) { [void]$acCols.Add((Decompile-AttrColumn $c)) }
					$acObj['columns'] = @($acCols)
					[void]$addList.Add($acObj)
				}
				$ao['additionalColumns'] = @($addList)
			}
		}
		# UseAlways: поля, всегда читаемые. Префикс "ИмяРеквизита." снимаем.
		# ValueTable (есть columns): useAlways:true на совпавшей колонке; остальные → массив атрибута.
		# Дин-список/прочие (нет columns): массив useAlways на атрибуте.
		$uaNode = $a.SelectSingleNode("lf:UseAlways", $ns)
		if ($uaNode) {
			$prefix = "$($ao['name'])."
			$shorts = New-Object System.Collections.ArrayList
			foreach ($fn in @($uaNode.SelectNodes("lf:Field", $ns))) {
				$t = $fn.InnerText.Trim()
				if ($t.StartsWith($prefix)) { $t = $t.Substring($prefix.Length) }
				[void]$shorts.Add($t)
			}
			if ($ao.Contains('columns')) {
				$rest = New-Object System.Collections.ArrayList
				foreach ($s in $shorts) {
					$col = $ao['columns'] | Where-Object { $_['name'] -eq $s } | Select-Object -First 1
					if ($col) { $col['useAlways'] = $true } else { [void]$rest.Add($s) }
				}
				if ($rest.Count -gt 0) { $ao['useAlways'] = @($rest) }
			} elseif ($shorts.Count -gt 0) {
				$ao['useAlways'] = @($shorts)
			}
		}
		# Settings динамического списка
		$setNode = $a.SelectSingleNode("lf:Settings", $ns)
		if ($setNode) {
			$so = [ordered]@{}
			$mt = Get-Child $setNode 'MainTable'; if ($mt) { $so['mainTable'] = $mt }
			$qtNode = $setNode.SelectSingleNode("lf:QueryText", $ns)
			if ($qtNode -and $qtNode.InnerText) { $so['query'] = Maybe-ExternalizeQuery -queryText $qtNode.InnerText -listName "$($ao['name'])" }
			# DynamicDataRead: дефолт true → эмитим только false
			if ((Get-Child $setNode 'DynamicDataRead') -eq 'false') { $so['dynamicDataRead'] = $false }
			# Явные поля набора (редко, ~4.5%) — захват только при наличии Field
			$fieldNodes = @($setNode.SelectNodes("lf:Field", $ns))
			if ($fieldNodes.Count -gt 0) {
				$fields = New-Object System.Collections.ArrayList
				foreach ($fn in $fieldNodes) {
					$fo = [ordered]@{}
					$fld = Get-Child $fn 'field'
					$dp  = Get-Child $fn 'dataPath'
					if ($fld) { $fo['field'] = $fld }
					if ($dp -and $dp -ne $fld) { $fo['dataPath'] = $dp }
					$ftn = $fn.SelectSingleNode("dcssch:title", $ns)
					if ($ftn) { $t = Get-LangText $ftn; if ($null -ne $t) { $fo['title'] = $t } }
					[void]$fields.Add($fo)
				}
				$so['fields'] = @($fields)
			}
			# ListSettings: пустой скелет (только viewMode+GUID) опускаем — компилятор
			# регенерит каноничный скелет. Захватываем только контейнеры с реальными
			# dcsset:item (filter/order/conditionalAppearance) в формат компилятора.
			$lsNode = $setNode.SelectSingleNode("lf:ListSettings", $ns)
			if ($lsNode) {
				$fNode = $lsNode.SelectSingleNode("dcsset:filter", $ns)
				if ($fNode -and $fNode.SelectSingleNode("dcsset:item", $ns)) {
					$flt = @()
					foreach ($fc in $fNode.SelectNodes("dcsset:item", $ns)) {
						$bi = (Build-FilterItem -itemNode $fc -loc "settings/filter")
						if ($null -ne $bi) { $flt += $bi }
					}
					if ($flt.Count -gt 0) { $so['filter'] = @($flt) }
				}
				$oNode = $lsNode.SelectSingleNode("dcsset:order", $ns)
				if ($oNode -and $oNode.SelectSingleNode("dcsset:item", $ns)) {
					$ord = Build-Order -ordNode $oNode -loc "settings/order"
					if (@($ord).Count -gt 0) { $so['order'] = @($ord) }
				}
				$caNode = $lsNode.SelectSingleNode("dcsset:conditionalAppearance", $ns)
				if ($caNode -and $caNode.SelectSingleNode("dcsset:item", $ns)) {
					$ca = Build-ConditionalAppearance -caNode $caNode -loc "settings/conditionalAppearance"
					if (@($ca).Count -gt 0) { $so['conditionalAppearance'] = @($ca) }
				}
			}
			if ($so.Count -gt 0) { $ao['settings'] = $so }
		}
		[void]$attrs.Add($ao)
	}
	if ($attrs.Count -gt 0) { $dsl['attributes'] = @($attrs) }
}

# parameters
$parsNode = $root.SelectSingleNode("lf:Parameters", $ns)
if ($parsNode) {
	$pars = New-Object System.Collections.ArrayList
	foreach ($p in @($parsNode.SelectNodes("lf:Parameter", $ns))) {
		$po = [ordered]@{}; $po['name'] = $p.GetAttribute("name")
		$ty = Decompile-Type ($p.SelectSingleNode("lf:Type", $ns)); if ($ty) { $po['type'] = $ty }
		if ((Get-Child $p 'KeyParameter') -eq 'true') { $po['key'] = $true }
		[void]$pars.Add($po)
	}
	if ($pars.Count -gt 0) { $dsl['parameters'] = @($pars) }
}

# commands
$cmdsNode = $root.SelectSingleNode("lf:Commands", $ns)
if ($cmdsNode) {
	$cmds = New-Object System.Collections.ArrayList
	foreach ($c in @($cmdsNode.SelectNodes("lf:Command", $ns))) {
		$co = [ordered]@{}; $co['name'] = $c.GetAttribute("name")
		$act = Get-Child $c 'Action'; if ($act) { $co['action'] = $act }
		$tNode = $c.SelectSingleNode("lf:Title", $ns); if ($tNode) { $t = Get-LangText $tNode; if ($null -ne $t) { $co['title'] = $t } }
		$ttNode = $c.SelectSingleNode("lf:ToolTip", $ns); if ($ttNode) { $t = Get-LangText $ttNode; if ($null -ne $t) { $co['tooltip'] = $t } }
		$us = Decompile-XrFlag $c 'Use'; if ($null -ne $us) { $co['use'] = $us }
		$cfo = Decompile-FunctionalOptions $c; if ($cfo) { $co['functionalOptions'] = $cfo }
		$cru = Get-Child $c 'CurrentRowUse'; if ($cru) { $co['currentRowUse'] = $cru }
		$sc = Get-Child $c 'Shortcut'; if ($sc) { $co['shortcut'] = $sc }
		$ref = $c.SelectSingleNode("lf:Picture/xr:Ref", $ns); if ($ref) { $co['picture'] = $ref.InnerText }
		$rep = Get-Child $c 'Representation'; if ($rep) { $co['representation'] = $rep }
		[void]$cmds.Add($co)
	}
	if ($cmds.Count -gt 0) { $dsl['commands'] = @($cmds) }
}

# --- 6. Output ---
$json = ConvertTo-CompactJson -obj $dsl
if ($OutputPath) {
	[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
	Save-QueryFiles
	Write-Host "form-decompile: $OutputPath"
} else {
	Write-Output $json
}
