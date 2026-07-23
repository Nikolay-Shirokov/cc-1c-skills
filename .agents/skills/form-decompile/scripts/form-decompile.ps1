# form-decompile v0.147 — Decompile 1C managed Form.xml to JSON DSL (draft)
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

# Второй документ с сохранением whitespace — только для восстановления ТОЧНОГО числа пробелов
# в whitespace-only <v8:content> (декорации-распорки без width: число пробелов = ширина). Основной
# парс (PreserveWhitespace=false) не трогаем; элементная структура обоих документов идентична →
# навигация по индекс-пути элементов (Resolve-WS). Загрузка лениво-безопасная.
$script:xmlDocWS = $null
try { $script:xmlDocWS = New-Object System.Xml.XmlDocument; $script:xmlDocWS.PreserveWhitespace = $true; $script:xmlDocWS.Load($FormPath) } catch { $script:xmlDocWS = $null }

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
$NS_APP    = "http://v8.1c.ru/8.2/managed-application/core"

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("lf", $NS_LF)
$ns.AddNamespace("v8", $NS_V8)
$ns.AddNamespace("xr", $NS_XR)
$ns.AddNamespace("xsi", $NS_XSI)
$ns.AddNamespace("dcsset", $NS_DCSSET)
$ns.AddNamespace("dcssch", $NS_DCSSCH)
$ns.AddNamespace("dcscor", $NS_DCSCOR)
$ns.AddNamespace("v8ui", $NS_V8UI)
$ns.AddNamespace("app", $NS_APP)

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

# Форма ListSettings: ordered-карта present top-level элементов (filter/order/conditionalAppearance →
# блок-мета 'v'/'u'/'vu'/''; itemsViewMode/itemsUserSettingID → $true). Возвращает $null, если форма ==
# полному каноничному скелету (компилятор регенерит сам) ИЛИ содержит неподдержанные top-level элементы
# (item/dataParameters/viewMode/userSettingID/… → fallback на канон). Иначе — дескриптор для компилятора.
function Get-ListSettingsShape {
	param($lsNode, [bool]$hasGrouping = $false)
	if (-not $lsNode) { return $null }
	$shape = [ordered]@{}
	foreach ($child in $lsNode.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		$tag = $child.LocalName
		if ($tag -in @('filter','order','conditionalAppearance')) {
			$hasVM = $null -ne $child.SelectSingleNode("dcsset:viewMode", $ns)
			$hasUS = $null -ne $child.SelectSingleNode("dcsset:userSettingID", $ns)
			$code = "$(if ($hasVM) {'v'})$(if ($hasUS) {'u'})"
			# Контейнер может нести собственный <dcsset:userSettingPresentation> (кастомная подпись
			# настройки) — сохраняем форму по xsi:type (Get-PresByType: ru-only LocalString ≠ xs:string).
			$uspNode = $child.SelectSingleNode("dcsset:userSettingPresentation", $ns)
			if ($uspNode) {
				$usp = Get-PresByType $uspNode
				$shape[$tag] = [ordered]@{ meta = $code; presentation = $usp }
			} else { $shape[$tag] = $code }
		} elseif ($tag -eq 'itemsViewMode') { $shape['itemsViewMode'] = $true }
		elseif ($tag -eq 'itemsUserSettingID') { $shape['itemsUserSettingID'] = $true }
		elseif ($tag -eq 'itemsUserSettingPresentation') { $shape['itemsUserSettingPresentation'] = Get-PresByType $child }   # items-уровневая подпись (форма по xsi:type)
		elseif ($tag -eq 'dataParameters') { $shape['dataParameters'] = $true }   # значения параметров запроса (контент в settings.dataParameters)
		elseif ($tag -eq 'item') { if ($hasGrouping) { $shape['structure'] = $true } else { return $null } }
		else { return $null }  # неизвестный top-level → канон-fallback
	}
	# Полный каноничный скелет → опускаем (компилятор регенерит)
	if ($shape.Count -eq 5 -and $shape['filter'] -eq 'vu' -and $shape['order'] -eq 'vu' -and `
		$shape['conditionalAppearance'] -eq 'vu' -and $shape['itemsViewMode'] -eq $true -and $shape['itemsUserSettingID'] -eq $true) { return $null }
	return $shape
}

# Группировка строк динамического списка: цепочка <dcsset:item StructureItemGroup> (каждый уровень =
# один groupItems-field; вложенность через дочерний <dcsset:item>). Возвращает ПЛОСКИЙ массив уровней
# (string для дефолтного поля; объект {field,groupType?,periodAdditionType?,periodAdditionBegin?,periodAdditionEnd?}
# для нестандартного) ИЛИ $null, если структура не «чистая линейная цепочка одно-польных уровней»
# (ветвление/мультиполе/доп.содержимое) → честный fallback на канон (LOST), а не тихая порча.
function Build-GroupLevel {
	param($fn)
	$field = Get-Child $fn 'field'
	$gt = Get-Child $fn 'groupType'
	$pat = Get-Child $fn 'periodAdditionType'
	$pabN = $fn.SelectSingleNode("dcsset:periodAdditionBegin", $ns)
	$paeN = $fn.SelectSingleNode("dcsset:periodAdditionEnd", $ns)
	$pab = $null; $pae = $null
	if ($pabN) { $pt = $pabN.GetAttribute("type", $NS_XSI); $pv = $pabN.InnerText; if (($pt -match 'Field$') -or ($pv -and $pv -ne '0001-01-01T00:00:00')) { $pab = $pv } }
	if ($paeN) { $pt = $paeN.GetAttribute("type", $NS_XSI); $pv = $paeN.InnerText; if (($pt -match 'Field$') -or ($pv -and $pv -ne '0001-01-01T00:00:00')) { $pae = $pv } }
	$isDefault = ((-not $gt) -or $gt -eq 'Items') -and ((-not $pat) -or $pat -eq 'None') -and (-not $pab) -and (-not $pae)
	if ($isDefault) { return $field }
	$o = [ordered]@{ field = $field }
	if ($gt -and $gt -ne 'Items') { $o['groupType'] = $gt }
	if ($pat -and $pat -ne 'None') { $o['periodAdditionType'] = $pat }
	if ($pab) { $o['periodAdditionBegin'] = $pab }
	if ($pae) { $o['periodAdditionEnd'] = $pae }
	return $o
}

function Build-ListGrouping {
	param($itemNode)
	$levels = New-Object System.Collections.ArrayList
	$cur = $itemNode
	while ($cur) {
		if (($cur.GetAttribute("type", $NS_XSI)) -notmatch 'StructureItemGroup$') { return $null }
		$gi = $null; $nested = @()
		foreach ($ch in $cur.ChildNodes) {
			if ($ch.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
			switch ($ch.LocalName) {
				'groupItems' { if ($gi) { return $null }; $gi = $ch }
				'item'       { $nested += $ch }
				default      { return $null }  # use/name/filter/order/… — здесь не поддержано
			}
		}
		if (-not $gi) { return $null }
		$fieldItems = @($gi.SelectNodes("dcsset:item", $ns))
		if ($fieldItems.Count -ne 1) { return $null }
		$fn = $fieldItems[0]
		if (($fn.GetAttribute("type", $NS_XSI)) -notmatch 'GroupItemField$') { return $null }
		[void]$levels.Add((Build-GroupLevel $fn))
		if ($nested.Count -eq 0) { break }
		if ($nested.Count -gt 1) { return $null }  # ветвление — не линейно
		$cur = $nested[0]
	}
	if ($levels.Count -eq 0) { return $null }
	return ,@($levels)
}

# --- 1b. Ring-3 scan: конструкции вне зоны поддержки (draft list) ---
function Fail-Ring3 {
	param([string]$kind, [string]$loc)
	[Console]::Error.WriteLine("form-decompile: декомпиляция пока не поддерживает $kind (path: $loc)")
	[Console]::Error.WriteLine("Для точечной работы с этой формой используй /form-edit.")
	exit 3
}
# ConditionalAppearance со scope (привязка к области) пока не воспроизводим — fail-ring3 только в этом случае.
foreach ($el in $xmlDoc.SelectNodes("//*[local-name()='ConditionalAppearance']/*[local-name()='item']/*[local-name()='scope'][node()]")) { Fail-Ring3 -kind "ConditionalAppearance со scope" -loc "form/ConditionalAppearance/item/scope" }
# Реквизит с design-time конфигурацией (<Settings> chart-типа: Диаграмма/ДиаграммаГанта/… —
# d4p1:GanttChart и т.п.). Поддержаны только TypeDescription (valueType) и DynamicList; прочие
# (встроенная конфигурация диаграммы) пока НЕ воспроизводим → честный скип, чтобы не потерять молча.
foreach ($s in $xmlDoc.SelectNodes("//*[local-name()='Attribute']/*[local-name()='Settings']")) {
	$st = $s.GetAttribute("type", $NS_XSI)
	if ($st -and $st -notmatch 'TypeDescription$' -and $st -notmatch 'DynamicList$' -and $st -notmatch 'Planner$' -and $st -notmatch 'd4p1:(Gantt)?Chart$') {
		Fail-Ring3 -kind "Attribute>Settings типа '$st' (design-time конфигурация, напр. диаграмма)" -loc "Attribute/Settings"
	}
	# Chart/GanttChart с точками/осями: типизированные значения (xsi:type), xsi:nil и ML с
	# префиксом d4p1: (а не v8:) генерик-движок не сохраняет → честный скип. Частые
	# дашборд-диаграммы/гант (серии/легенда/оформление/шкала) поддержаны.
	elseif ($st -match 'd4p1:(Gantt)?Chart$' -and ($s.OuterXml -match '<d4p1:\w+ xsi:type=' -or $s.OuterXml -match '<d4p1:\w+ xsi:nil=' -or $s.OuterXml -match '<d4p1:item[ >]')) {
		Fail-Ring3 -kind "Attribute>Settings $st с точками/осями (типизированные значения/d4p1-ML)" -loc "Attribute/Settings"
	}
}

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
# Дополнения (Search*/ViewStatus) БОЛЬШЕ не companion — декомпилируются как тип-элементы
# (кастомные в AutoCommandBar/ChildItems → commandBar.children; стандартные на уровне таблицы → карта additions).
$COMPANION_TAGS = @('ContextMenu','ExtendedTooltip','AutoCommandBar')

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

# Get-LangText с восстановлением значимого пробела: PreserveWhitespace=false стрипает
# <v8:content> </v8:content> → "" (неотличимо от суппресса). Платформа НЕ эмитит пустой
# Title/ToolTip, значит исходно был пробел → возвращаем " " (как Get-MLFormattedValue).
# Покрывает и одиночную строку (ru-only), и мультиязычную мапу (напр. декорация-разделитель
# «Пробел» с ru+en пробелами): восстанавливаем " " в каждом языке, где content-узел есть, но пуст.
# Точное число пробелов whitespace-only <v8:content> из PreserveWhitespace-документа (основной
# парс стрипает его в ""). Навигация по индекс-пути элементов (структура обоих документов идентична).
function Resolve-WS {
	param($contentNode)
	if (-not $contentNode -or -not $script:xmlDocWS) { return $null }
	$idxs = New-Object System.Collections.ArrayList
	$cur = $contentNode
	while ($cur.ParentNode -and $cur.ParentNode.NodeType -eq [System.Xml.XmlNodeType]::Element) {
		$i = 0; $sib = $cur.PreviousSibling
		while ($sib) { if ($sib.NodeType -eq [System.Xml.XmlNodeType]::Element) { $i++ }; $sib = $sib.PreviousSibling }
		[void]$idxs.Insert(0, $i)
		$cur = $cur.ParentNode
	}
	$wcur = $script:xmlDocWS.DocumentElement
	foreach ($ix in $idxs) {
		$els = @(); foreach ($ch in $wcur.ChildNodes) { if ($ch.NodeType -eq [System.Xml.XmlNodeType]::Element) { $els += $ch } }
		if ($ix -ge $els.Count) { return $null }
		$wcur = $els[$ix]
	}
	return $wcur.InnerText
}

# Точное восстановление пробела (число): whitespace-only content → реальная строка пробелов из WS-дока.
function Restore-WSContent {
	param($contentNode)
	$ws = Resolve-WS $contentNode
	if ($ws -and $ws.Trim() -eq '') { return $ws }   # только если действительно whitespace
	return ' '
}

function Get-LangTextWS {
	param($node)
	$t = Get-LangText $node
	if ($null -eq $t) { return $null }
	if ($t -is [string]) {
		$cn = $node.SelectSingleNode("v8:item/v8:content", $ns)
		if ($t -eq '' -and $cn) { return (Restore-WSContent $cn) }
		return $t
	}
	foreach ($it in @($node.SelectNodes("v8:item", $ns))) {
		$lang = $it.SelectSingleNode("v8:lang", $ns)
		$content = $it.SelectSingleNode("v8:content", $ns)
		if ($lang -and $content -and $t.Contains($lang.InnerText) -and $t[$lang.InnerText] -eq '') {
			$t[$lang.InnerText] = (Restore-WSContent $content)
		}
	}
	return $t
}

# Авто-вывод заголовка из имени — ТОЧНОЕ зеркало Title-FromName из form-compile.
# Нужен, чтобы опускать ru-only заголовки, которые компилятор воспроизведёт сам.
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
		if ($p.Length -gt 1 -and $p -ceq $p.ToUpper()) { [void]$out.Add($p) }
		else { [void]$out.Add($p.ToLower()) }
	}
	return ($out -join ' ')
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
	# Get-LangTextWS восстанавливает значимый пробел в <v8:content> </v8:content> (одиночный и
	# мультиязычный случай) — иначе декорация-разделитель «Пробел» спуталась бы с суппресс-маркером "".
	$text = Get-LangTextWS $titleNode
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

# Presentation, сохраняющий ФОРМУ по xsi:type (не схлопывает ru-only LocalStringType в строку):
# <… xsi:type="v8:LocalStringType"> → объект {lang:text} (даже один ru), иначе xs:string → плоская строка.
# Нужно, чтобы компилятор воспроизвёл точный xsi:type (LocalStringType vs xs:string). Пустой LocalStringType → $null.
function Get-PresByType {
	param($node)
	if (-not $node) { return $null }
	$xt = $node.GetAttribute("type", $NS_XSI)
	if ($xt -match 'LocalStringType$') {
		$d = [ordered]@{}
		foreach ($it in $node.SelectNodes("v8:item", $ns)) {
			$lang = Get-Text $it "v8:lang"; $content = Get-Text $it "v8:content"
			if ($lang) { $d[$lang] = $content }
		}
		if ($d.Count -gt 0) { return $d }
		return $null
	}
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

# Прочитать <dcscor:value> в JSON-значение: Font/Line/Field/multilang/raw text.
function Read-AppearanceValueNode {
	param($valNode)
	if (-not $valNode) { return $null }
	$vt = Get-LocalXsiType $valNode
	if ($vt -eq 'LocalStringType') {
		# НЕ схлопываем одноязычный в строку: значение параметра оформления различает
		# xs:string (плоская строка) и LocalStringType (локализуемый текст) — обе формы
		# одноязычно дают одну строку. Всегда объект-карта языков → компилятор эмитит LocalStringType.
		$map = [ordered]@{}
		foreach ($it in @($valNode.SelectNodes("v8:item", $ns))) {
			$lang = $it.SelectSingleNode("v8:lang", $ns); $content = $it.SelectSingleNode("v8:content", $ns)
			if ($lang) { $map[$lang.InnerText] = if ($content) { $content.InnerText } else { "" } }
		}
		return $map
	}
	if ($vt -eq 'Font') { return (Get-FontValue $valNode) }
	if ($vt -eq 'Line') { return (Get-LineValue $valNode) }
	# dcscor:Field — значение = ссылка на поле компоновки → объект {field:путь}
	if ($vt -eq 'Field') { return [ordered]@{ field = $valNode.InnerText } }
	return $valNode.InnerText
}

# Обратная карта comparisonType → короткий оператор фильтра (зеркало skd).
$script:filterOpMap = @{
	'Equal'='='; 'NotEqual'='<>'; 'Greater'='>'; 'GreaterOrEqual'='>=';
	'Less'='<'; 'LessOrEqual'='<='; 'InList'='in'; 'NotInList'='notIn';
	'InHierarchy'='inHierarchy'; 'InListByHierarchy'='inListByHierarchy';
	'Contains'='contains'; 'NotContains'='notContains';
	'BeginsWith'='beginsWith'; 'NotBeginsWith'='notBeginsWith';
	'Like'='like'; 'NotLike'='notLike';
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
	# Стандартная дата начала/окончания. Формы (от самой компактной):
	#   SBD Custom+date → голая ISO-дата без valueType (компилятор выводит SBD Custom — дефолт
	#     даты в фильтре, корпус 268 vs 2 xs:dateTime); именованный вариант → строка + valueType;
	#   SED Custom / нетипичное → объект {variant, date} + valueType. Иначе InnerText склеивал.
	if ($vType -eq 'StandardBeginningDate' -or $vType -eq 'StandardEndDate') {
		$variantN = $valNode.SelectSingleNode("v8:variant", $ns)
		$dateN = $valNode.SelectSingleNode("v8:date", $ns)
		$variantStr = if ($variantN) { $variantN.InnerText } else { '' }
		if ($dateN) {
			if ($vType -eq 'StandardBeginningDate' -and $variantStr -eq 'Custom') {
				return @{ value = $dateN.InnerText; type = $null }   # голая дата = SBD Custom шорткат
			}
			return @{ value = [ordered]@{ variant = $variantStr; date = $dateN.InnerText }; type = $rawType }
		}
		return @{ value = $variantStr; type = $rawType }   # именованный вариант
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
		if ((Get-Text $itemNode "dcsset:use") -eq 'false') { $gObj['use'] = $false }   # группа отключена (@off)
		$gPresNode = $itemNode.SelectSingleNode("dcsset:presentation", $ns)
		if ($gPresNode) {
			# Сохраняем форму по xsi:type (LocalStringType ru-only ≠ xs:string)
			$gPres = Get-PresByType $gPresNode
			if ($null -ne $gPres -and $gPres -ne '') { $gObj['presentation'] = $gPres }
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
			} elseif ($vt.type -eq 'xs:string' -and ($value -is [string]) -and ($value -match '^(-?\d+(\.\d+)?|\d{4}-\d{2}-\d{2}T)')) {
				# Значение-строка "1"/"2020-..." с xsi:type="xs:string": компилятор авто-детектит число/дату
				# (теряет xs:string). Когда авто-вывод дал бы ДРУГОЙ тип — фиксируем явный valueType.
				$valueTypeAttr = 'xs:string'
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
		# Сохраняем форму по xsi:type (LocalStringType ru-only ≠ xs:string)
		$fiPres = Get-PresByType $fiPresNode
	}

	$flags = @()
	if ($use -eq 'false') { $flags += '@off' }
	if ($userId) { $flags += '@user' }
	if ($viewMode -eq 'QuickAccess') { $flags += '@quickAccess' }
	elseif ($viewMode -eq 'Inaccessible') { $flags += '@inaccessible' }
	elseif ($viewMode -eq 'Normal') { $flags += '@normal' }

	$noValueOps = @('filled','notFilled')

	# Пустой xs:string right (<dcsset:right xsi:type="xs:string"/>) ≠ отсутствие <right>:
	# Get-FilterValueWithType маппит наличие пустого/nil right в value='_' (отсутствие → $null).
	# Shorthand `_` неоднозначен (схлопывает оба, компилятор → нет right). Пробельные значения рвут
	# shorthand-парсинг (split по пробелам). → форсим объектную форму (value='_' → self-closing;
	# пробелы — как есть в <right>).
	$valNeedsObj = $false
	if ($rightNodes.Count -eq 1 -and -not $valueIsArrayFlag -and $op -notin $noValueOps) {
		if ("$value" -eq '_') {
			# Truly-empty <right xsi:type="xs:string"/> ИЛИ whitespace-only <right>   </right>
			# (PreserveWhitespace=false стрипнул пробелы в '' → Get-FilterValueWithType вернул '_').
			# Восстанавливаем реальные пробелы из WS-дока (как у whitespace-заголовков).
			$ws = Resolve-WS $rightNodes[0]
			if ($ws -and $ws.Length -gt 0 -and $ws.Trim() -eq '') { $value = $ws }
			$valNeedsObj = $true
		}
		elseif ($null -ne $value -and "$value" -match '\s') { $valNeedsObj = $true }
	}

	if ($userPresNode -or $valueIsArrayFlag -or $valueTypeAttr -or $fiPres -or $valNeedsObj) {
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
			# Сохраняем форму по xsi:type: LocalStringType (даже ru-only) → объект → компилятор эмитит LocalStringType.
			$pres = Get-PresByType $presNode
			if ($null -ne $pres -and $pres -ne '') { $entry['presentation'] = $pres }
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
# Вызывается один раз для любого элемента. Height тут — высота элемента (<Height>),
# в т.ч. у Table; высоту в строках (<HeightInTableRows>) Table ловит отдельно в heightInTableRows.
function Add-Layout {
	param($obj, $node)
	# Общие свойства элемента (любой тип): default/drag/skip
	if ((Get-Child $node 'DefaultItem') -eq 'true') { $obj['defaultItem'] = $true }
	$soi = Get-Child $node 'SkipOnInput'; if ($null -ne $soi) { $obj['skipOnInput'] = ($soi -eq 'true') }
	# EnableStartDrag/EnableDrag — фактическое значение (платформа эмитит и явный false, напр. SpreadSheet)
	$esd = Get-Child $node 'EnableStartDrag'; if ($null -ne $esd) { $obj['enableStartDrag'] = ($esd -eq 'true') }
	$edr = Get-Child $node 'EnableDrag'; if ($null -ne $edr) { $obj['enableDrag'] = ($edr -eq 'true') }
	$fdm = Get-Child $node 'FileDragMode'; if ($fdm) { $obj['fileDragMode'] = $fdm }
	# AutoMaxWidth: компилятор додумывает false для multiLine-input без явного ключа (multiLineDefault).
	# Захват факт. значения; multiLine-input без тега → autoMaxWidth:true (суппресс эвристики).
	$amwNode = Get-Child $node 'AutoMaxWidth'
	if ($amwNode -eq 'false') { $obj['autoMaxWidth'] = $false }
	elseif ($amwNode -eq 'true') { $obj['autoMaxWidth'] = $true }
	elseif ((Get-Child $node 'MultiLine') -eq 'true') { $obj['autoMaxWidth'] = $true }
	$mw = Get-Child $node 'MaxWidth'; if ($mw) { $obj['maxWidth'] = [int]$mw }
	if ((Get-Child $node 'AutoMaxHeight') -eq 'false') { $obj['autoMaxHeight'] = $false }
	$mh = Get-Child $node 'MaxHeight'; if ($mh) { $obj['maxHeight'] = [int]$mh }
	$w = Get-Child $node 'Width'; if ($w) { $obj['width'] = [int]$w }
	$h = Get-Child $node 'Height'; if ($h) { $obj['height'] = [int]$h }
	# Stretch: захват фактического значения (true И false — платформа эмитит явное)
	$hs = Get-Child $node 'HorizontalStretch'; if ($null -ne $hs) { $obj['horizontalStretch'] = ($hs -eq 'true') }
	$vs = Get-Child $node 'VerticalStretch'; if ($null -ne $vs) { $obj['verticalStretch'] = ($vs -eq 'true') }
	$gha = Get-Child $node 'GroupHorizontalAlign'; if ($gha) { $obj['groupHorizontalAlign'] = $gha }
	$gva = Get-Child $node 'GroupVerticalAlign'; if ($gva) { $obj['groupVerticalAlign'] = $gva }
	$ha = Get-Child $node 'HorizontalAlign'; if ($ha) { $obj['horizontalAlign'] = $ha }
	# Cell-свойства поля в таблице (общие для Input/Label/Picture/CheckBox): захват «как есть»
	foreach ($p in @('ShowInHeader','ShowInFooter','AutoCellHeight')) {
		$v = Get-Child $node $p; if ($null -ne $v) { $obj[($p.Substring(0,1).ToLower()+$p.Substring(1))] = ($v -eq 'true') }
	}
	$fha = Get-Child $node 'FooterHorizontalAlign'; if ($fha) { $obj['footerHorizontalAlign'] = $fha }
	$hha = Get-Child $node 'HeaderHorizontalAlign'; if ($hha) { $obj['headerHorizontalAlign'] = $hha }
	# ColumnGroup: динамический заголовок из данных + формат заголовка (ML-текст)
	$hdp = Get-Child $node 'HeaderDataPath'; if ($hdp) { $obj['headerDataPath'] = $hdp }
	$hfNode = $node.SelectSingleNode("lf:HeaderFormat", $ns); if ($hfNode) { $hf = Get-LangText $hfNode; if ($null -ne $hf) { $obj['headerFormat'] = $hf } }
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

# Командный интерфейс формы (<CommandInterface>): панели CommandBar + NavigationPanel,
# каждая — список переопределений команд (платформа эмитит ТОЛЬКО отклонения от авто-расстановки).
# Элемент: command (verbatim, "0"=пустой) + type (Auto опускаем) + attribute/group(CommandGroup)/index +
# defaultVisible(bool) + visible(xr-flag bool/{common,roles} — тот же механизм, что userVisible).
# Голый элемент (только команда, Type=Auto) → строковый shorthand.
function Decompile-CommandInterface {
	$ciNode = $root.SelectSingleNode("lf:CommandInterface", $ns)
	if (-not $ciNode) { return $null }
	$ci = [ordered]@{}
	foreach ($panel in @(@('CommandBar','commandBar'), @('NavigationPanel','navigationPanel'))) {
		$pn = $ciNode.SelectSingleNode("lf:$($panel[0])", $ns)
		if (-not $pn) { continue }
		$items = New-Object System.Collections.ArrayList
		foreach ($it in @($pn.SelectNodes("lf:Item", $ns))) {
			$o = [ordered]@{}
			$cmd = Get-Child $it 'Command'
			$o['command'] = "$cmd"
			$ty = Get-Child $it 'Type'; if ($ty -and $ty -ne 'Auto') { $o['type'] = $ty }
			$at = Get-Child $it 'Attribute'; if ($at) { $o['attribute'] = $at }
			$cg = Get-Child $it 'CommandGroup'; if ($cg) { $o['group'] = $cg }
			$idx = Get-Child $it 'Index'; if ($null -ne $idx) { $o['index'] = [int]$idx }
			$dv = Get-Child $it 'DefaultVisible'; if ($null -ne $dv) { $o['defaultVisible'] = ($dv -eq 'true') }
			$vis = Decompile-XrFlag $it 'Visible'; if ($null -ne $vis) { $o['visible'] = $vis }
			# Голый элемент (только command) → строка-shorthand; иначе объект
			if ($o.Count -eq 1) { [void]$items.Add("$cmd") } else { [void]$items.Add($o) }
		}
		if ($items.Count -gt 0) { $ci[$panel[1]] = @($items) }
	}
	if ($ci.Count -gt 0) { return $ci }
	return $null
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
	$ctNode = $c.SelectSingleNode("lf:Title", $ns); if ($ctNode) { $t = Get-LangTextWS $ctNode; if ($null -ne $t) { $co['title'] = $t } }
	$cfc = Get-Child $c 'FillCheck'; if ($cfc) { $co['fillCheck'] = $cfc }   # проверка заполнения колонки (как у реквизита)
	$cfo = Decompile-FunctionalOptions $c; if ($cfo) { $co['functionalOptions'] = $cfo }
	# Ролевой доступ колонки (View/Edit) — xr-флаг, как у самого реквизита (bool | {common,roles})
	$cv = Decompile-XrFlag $c 'View'; if ($null -ne $cv) { $co['view'] = $cv }
	$ce = Decompile-XrFlag $c 'Edit'; if ($null -ne $ce) { $co['edit'] = $ce }
	return $co
}

# Общие свойства элемента (visible/enabled/readonly/title/events) → в hash
# Картинка-ссылка с прозрачностью (HeaderPicture/FooterPicture/ValuesPicture/Page Picture).
# Платформа ВСЕГДА эмитит <xr:LoadTransparent> (и true, и false) → дефолт DSL = false.
# Источник: <xr:Ref> (именованная/стилевая) ИЛИ <xr:Abs> (встроенная → префикс "abs:").
# Скаляр (src) при loadTransparent=false и без TransparentPixel; иначе объект
# {src, loadTransparent?, transparentPixel?}.
function Get-PictureRef {
	param($node, [string]$picTag)
	$ref = $node.SelectSingleNode("lf:$picTag/xr:Ref", $ns)
	$abs = $node.SelectSingleNode("lf:$picTag/xr:Abs", $ns)
	if (-not $ref -and -not $abs) { return $null }
	$src = if ($ref) { $ref.InnerText } else { "abs:$($abs.InnerText)" }
	$lt = $node.SelectSingleNode("lf:$picTag/xr:LoadTransparent", $ns)
	$ltTrue = ($lt -and $lt.InnerText -eq 'true')
	$tpx = $node.SelectSingleNode("lf:$picTag/xr:TransparentPixel", $ns)
	if (-not $ltTrue -and -not $tpx) { return $src }
	$o = [ordered]@{ src = $src }
	if ($ltTrue) { $o['loadTransparent'] = $true }
	if ($tpx) { $o['transparentPixel'] = [ordered]@{ x = [int]$tpx.GetAttribute('x'); y = [int]$tpx.GetAttribute('y') } }
	return $o
}

# <Picture> кнопки/попапа/команды. Дефолт LoadTransparent=true (обратная конвенция к header/values):
# фиксируем только отклонение false. Источник <xr:Ref> или <xr:Abs> (→ "abs:"). При наличии
# <xr:TransparentPixel> → объектная форма {src, loadTransparent?, transparentPixel}, иначе скаляр picture
# + отдельный loadTransparent:false.
function Set-CommandPicture {
	param($obj, $node)
	$ref = $node.SelectSingleNode("lf:Picture/xr:Ref", $ns)
	$abs = $node.SelectSingleNode("lf:Picture/xr:Abs", $ns)
	if (-not $ref -and -not $abs) { return }
	$src = if ($ref) { $ref.InnerText } else { "abs:$($abs.InnerText)" }
	$lt = $node.SelectSingleNode("lf:Picture/xr:LoadTransparent", $ns)
	$ltFalse = ($lt -and $lt.InnerText -eq 'false')
	$tpx = $node.SelectSingleNode("lf:Picture/xr:TransparentPixel", $ns)
	if ($tpx) {
		$o = [ordered]@{ src = $src }
		if ($ltFalse) { $o['loadTransparent'] = $false }
		$o['transparentPixel'] = [ordered]@{ x = [int]$tpx.GetAttribute('x'); y = [int]$tpx.GetAttribute('y') }
		$obj['picture'] = $o
	} else {
		$obj['picture'] = $src
		if ($ltFalse) { $obj['loadTransparent'] = $false }
	}
}

# Шрифт <Font ...> → строка-ref (если только ref+kind=StyleItem) или объект-атрибуты.
function Build-FontValue {
	param($f)
	$present = @()
	foreach ($a in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
		if ($f.HasAttribute($a)) { $present += $a }
	}
	# Чистый style-ref (ref + kind=StyleItem) → строка-шорткат
	if ($present.Count -eq 2 -and ($present -contains 'ref') -and $f.GetAttribute('kind') -eq 'StyleItem') {
		return $f.GetAttribute('ref')
	}
	$o = [ordered]@{}
	foreach ($k in $present) {
		$v = $f.GetAttribute($k)
		if ($k -in @('height','scale') -and $v -match '^-?\d+$') { $o[$k] = [int]$v }
		elseif ($k -in @('bold','italic','underline','strikeout')) { $o[$k] = ($v -eq 'true') }
		else { $o[$k] = $v }
	}
	return $o
}

# Граница <Border> → строка-ref (из стиля) или объект {width, style}.
function Build-BorderValue {
	param($b)
	if ($b.HasAttribute('ref')) { return $b.GetAttribute('ref') }
	$o = [ordered]@{}
	if ($b.HasAttribute('width')) { $w = $b.GetAttribute('width'); $o['width'] = if ($w -match '^-?\d+$') { [int]$w } else { $w } }
	$st = $b.SelectSingleNode("v8ui:style", $ns)
	if ($st) { $o['style'] = $st.InnerText }
	return $o
}

# Оформление элемента (цвета/шрифты/граница) → canonical DSL-ключи. Цвет — verbatim-строка.
function Add-Appearance {
	param($obj, $node)
	$colorMap = @{
		'TitleTextColor'='titleTextColor'; 'TitleBackColor'='titleBackColor'
		'FooterTextColor'='footerTextColor'; 'FooterBackColor'='footerBackColor'
		'TextColor'='textColor'; 'BackColor'='backColor'; 'BorderColor'='borderColor'
	}
	foreach ($tag in $colorMap.Keys) {
		$c = $node.SelectSingleNode("lf:$tag", $ns)
		if ($c) { $obj[$colorMap[$tag]] = $c.InnerText }
	}
	foreach ($pair in @(@('Font','font'), @('TitleFont','titleFont'), @('FooterFont','footerFont'))) {
		$f = $node.SelectSingleNode("lf:$($pair[0])", $ns)
		if ($f) { $obj[$pair[1]] = (Build-FontValue $f) }
	}
	$b = $node.SelectSingleNode("lf:Border", $ns)
	if ($b) { $obj['border'] = (Build-BorderValue $b) }
}

function Add-CommonProps {
	param($obj, $node, [string]$elName)
	Add-Appearance $obj $node
	if ((Get-Child $node 'Visible') -eq 'false') { $obj['hidden'] = $true }
	if ((Get-Child $node 'Enabled') -eq 'false') { $obj['disabled'] = $true }
	if ((Get-Child $node 'ReadOnly') -eq 'true') { $obj['readOnly'] = $true }
	$uv = Decompile-XrFlag $node 'UserVisible'; if ($null -ne $uv) { $obj['userVisible'] = $uv }
	$titleNode = $node.SelectSingleNode("lf:Title", $ns)
	if ($titleNode) {
		$t = Get-LangTextWS $titleNode   # восстановление значимого пробела (whitespace-заголовок)
		if ($null -ne $t) { $obj['title'] = $t }
		# formatted у LabelDecoration выводится компилятором из hyperlink — отдельный ключ не нужен (#16 хвост)
	}
	$ttNode = $node.SelectSingleNode("lf:ToolTip", $ns)
	if ($ttNode) { $tt = Get-LangTextWS $ttNode; if ($null -ne $tt) { $obj['tooltip'] = $tt } }
	$ttr = Get-Child $node 'ToolTipRepresentation'; if ($ttr) { $obj['tooltipRepresentation'] = $ttr }
	# Картинки заголовка/подвала колонки (любой field-тип, эмитятся платформой как column header/footer icon)
	$hp = Get-PictureRef $node 'HeaderPicture'; if ($null -ne $hp) { $obj['headerPicture'] = $hp }
	$fp = Get-PictureRef $node 'FooterPicture'; if ($null -ne $fp) { $obj['footerPicture'] = $fp }
	$ev = Get-Events $node $elName
	if ($ev) { $obj['events'] = $ev }
	# CommandSet — общий для полей (input/label/check/spreadsheet/html/formatted/picture):
	# список отключённых команд редактора. Только <ExcludedCommand>, пустого не бывает.
	$csNode = $node.SelectSingleNode("lf:CommandSet", $ns)
	if ($csNode) {
		$exc = New-Object System.Collections.ArrayList
		foreach ($ec in @($csNode.SelectNodes("lf:ExcludedCommand", $ns))) { [void]$exc.Add($ec.InnerText) }
		if ($exc.Count -gt 0) { $obj['excludedCommands'] = @($exc) }
	}
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
				$al = $typeNode.SelectSingleNode("v8:StringQualifiers/v8:AllowedLength", $ns)
				$fixed = ($al -and $al.InnerText -eq 'Fixed')   # Variable = дефолт (опускаем); Fixed — явно
				if ($len -and [int]$len.InnerText -gt 0) {
					$short = if ($fixed) { "string($($len.InnerText),fixed)" } else { "string($($len.InnerText))" }
				} else { $short = "string" }   # Length=0 → всегда Variable (корпус)
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
	# TypeId — тип, заданный глобальным стабильным GUID (<v8:TypeId>, не <v8:Type>). Платформа так
	# сериализует типы, чьё имя в этом контексте недоступно (определяемые/характеристики). GUID глобально
	# стабилен → эмитим verbatim как маркер 'typeid:GUID' (компилятор разворачивает обратно; как роль-по-GUID).
	foreach ($ti in @($typeNode.SelectNodes("v8:TypeId", $ns))) {
		[void]$parts.Add("typeid:" + $ti.InnerText.Trim())
	}
	if ($parts.Count -eq 0) { return $null }
	if ($parts.Count -eq 1) { return $parts[0] }
	return ($parts -join ' | ')
}

# Ограничения использования (useRestriction/attributeUseRestriction) → объект {field?,condition?,group?,order?}.
function Build-RestrictObj {
	param($node)
	$r = [ordered]@{}
	foreach ($k in 'field','condition','group','order') { if ((Get-Child $node $k) -eq 'true') { $r[$k] = $true } }
	return $r
}

# Вычисляемое поле DataSet динамического списка (<CalculatedField>) → объектная модель.
# Зеркало эмиссии form-compile (Emit-CalcFields). Грамматика — как skd calculatedFields,
# + форм-extras presentationExpression/orderExpression (в namespace dcscommon).
function Build-CalcField {
	param($cfNode)
	$o = [ordered]@{}
	$o['dataPath'] = Get-Child $cfNode 'dataPath'
	$o['expression'] = Get-Child $cfNode 'expression'
	$tn = $cfNode.SelectSingleNode("dcssch:title", $ns)
	if ($tn) { $t = Get-LangText $tn; if ($null -ne $t) { $o['title'] = $t } }
	$vt = $cfNode.SelectSingleNode("dcssch:valueType", $ns)
	if ($vt) { $v = Decompile-Type $vt; if ($v) { $o['valueType'] = $v } }
	$ur = $cfNode.SelectSingleNode("dcssch:useRestriction", $ns)
	if ($ur) {
		$r = [ordered]@{}
		foreach ($k in 'field','condition','group','order') { if ((Get-Child $ur $k) -eq 'true') { $r[$k] = $true } }
		if ($r.Count -gt 0) { $o['useRestriction'] = $r }
	}
	$pe = Get-Child $cfNode 'presentationExpression'
	if ($null -ne $pe -and $pe -ne '') { $o['presentationExpression'] = $pe }
	$oeNodes = @($cfNode.SelectNodes("dcssch:orderExpression", $ns))
	if ($oeNodes.Count -gt 0) {
		$oes = New-Object System.Collections.ArrayList
		foreach ($oen in $oeNodes) {
			$eo = [ordered]@{}
			$exprN = $oen.SelectSingleNode("*[local-name()='expression']")
			$otN = $oen.SelectSingleNode("*[local-name()='orderType']")
			$aoN = $oen.SelectSingleNode("*[local-name()='autoOrder']")
			$eo['expression'] = if ($exprN) { $exprN.InnerText } else { '' }
			if ($otN -and $otN.InnerText -ne 'Asc') { $eo['orderType'] = $otN.InnerText }
			if ($aoN -and $aoN.InnerText -eq 'true') { $eo['autoOrder'] = $true }
			[void]$oes.Add($eo)
		}
		$o['orderExpression'] = @($oes)
	}
	return $o
}

# Schema-параметры динамического списка (<Parameter> под <Settings>) — зеркало эмиссии
# form-compile (Emit-DLParameters). Инверсия контекстных дефолтов: useRestriction=true и
# title==Title-FromName опускаем (компилятор восстановит). Сущность = DataCompositionSchemaParameter.
function Build-DLInputParameters {
	param($ipNode)
	$items = New-Object System.Collections.ArrayList
	foreach ($it in @($ipNode.SelectNodes("dcscor:item", $ns))) {
		$io = [ordered]@{}
		$io['parameter'] = Get-Child $it 'parameter'
		$useN = $it.SelectSingleNode("dcscor:use", $ns)
		if ($useN -and $useN.InnerText -eq 'false') { $io['use'] = $false }
		$valN = $it.SelectSingleNode("dcscor:value", $ns)
		if ($valN) {
			$vt = $valN.GetAttribute("type", $NS_XSI)
			if ($vt -match 'ChoiceParameters$') {
				$cps = New-Object System.Collections.ArrayList
				foreach ($cpi in @($valN.SelectNodes("dcscor:item", $ns))) {
					$cpo = [ordered]@{}
					$cpo['name'] = Get-Child $cpi 'choiceParameter'
					$vals = New-Object System.Collections.ArrayList
					foreach ($cv in @($cpi.SelectNodes("dcscor:value", $ns))) {
						[void]$vals.Add((Convert-TypedValue -raw $cv.InnerText -xsiType ($cv.GetAttribute("type", $NS_XSI))))
					}
					$cpo['values'] = @($vals)
					[void]$cps.Add($cpo)
				}
				$io['choiceParameters'] = @($cps)
			} elseif ($vt -match 'ChoiceParameterLinks$') {
				$cpls = New-Object System.Collections.ArrayList
				foreach ($cpi in @($valN.SelectNodes("dcscor:item", $ns))) {
					$cpo = [ordered]@{}
					$cpo['name'] = Get-Child $cpi 'choiceParameter'
					$cpo['value'] = Get-Child $cpi 'value'
					$md = Get-Child $cpi 'mode'; if ($md -and $md -ne 'Auto') { $cpo['mode'] = $md }
					[void]$cpls.Add($cpo)
				}
				$io['choiceParameterLinks'] = @($cpls)
			} elseif ($vt -match 'TypeLink$') {
				# Связь по типу (dcscor:TypeLink): field + linkItem — структурное значение,
				# НЕ склеивать InnerText в строку ("СчетДт"+"1"="СчетДт1").
				$tlo = [ordered]@{}
				$tlf = Get-Child $valN 'field'; if ($null -ne $tlf) { $tlo['field'] = $tlf }
				$tli = Get-Child $valN 'linkItem'; if ($null -ne $tli) { $tlo['linkItem'] = if ($tli -match '^-?\d+$') { [int]$tli } else { $tli } }
				$io['typeLink'] = $tlo
			} else {
				if ($valN.GetAttribute("nil", $NS_XSI) -ne 'true') { $io['value'] = Convert-TypedValue -raw $valN.InnerText -xsiType $vt }
			}
		}
		[void]$items.Add($io)
	}
	return @($items)
}

# dcsset:dataParameters → массив (shorthand "Имя @off" для value-less / объект для типизированного
# значения). Грамматика зеркалит skd-compile Emit-DataParameters (form-контекст: значение опционально,
# в отличие от skd-settings). Без «auto»-компактизации (нужна машинерия сравнения с top-level).
function Build-FormDataParameters {
	param($dpNode)
	$entries = @()
	foreach ($it in @($dpNode.SelectNodes("dcscor:item", $ns))) {
		$pn = Get-Text $it "dcscor:parameter"
		$use = Get-Text $it "dcscor:use"
		$valNodes = @($it.SelectNodes("dcscor:value", $ns))
		$valNode = if ($valNodes.Count -ge 1) { $valNodes[0] } else { $null }
		$usidN = $it.SelectSingleNode("dcsset:userSettingID", $ns)
		$vmN = $it.SelectSingleNode("dcsset:viewMode", $ns)
		$uspN = $it.SelectSingleNode("dcsset:userSettingPresentation", $ns)
		if ($valNode -or $usidN -or $vmN -or $uspN) {
			$obj = [ordered]@{ parameter = $pn }
			if ($valNodes.Count -gt 1) {
				# Список значений параметра (valueListAllowed) — захватываем ВСЕ <dcscor:value> массивом
				$obj['value'] = @($valNodes | ForEach-Object { $_.InnerText })
				$vt0 = $valNodes[0].GetAttribute("type", $NS_XSI); if ($vt0) { $obj['valueType'] = $vt0 }
			} elseif ($valNode) {
				if ($valNode.GetAttribute("nil", $NS_XSI) -eq 'true') { $obj['nilValue'] = $true }
				else {
					$vType = $valNode.GetAttribute("type", $NS_XSI); $vVal = $valNode.InnerText
					if ($vType -match 'decimal$' -and $vVal -match '^-?\d+$') { $obj['value'] = [int]$vVal }
					elseif ($vType -match 'boolean$') { $obj['value'] = ($vVal -eq 'true') }
					else { $obj['value'] = $vVal }
					if ($vType) { $obj['valueType'] = $vType }
				}
			}
			if ($use -eq 'false') { $obj['use'] = $false }
			if ($usidN) { $obj['userSettingID'] = 'auto' }
			if ($vmN) { $obj['viewMode'] = $vmN.InnerText }
			if ($uspN) { $usp = Get-PresText $uspN; if ($null -ne $usp) { $obj['userSettingPresentation'] = $usp } }
			$entries += $obj
		} else {
			$s = $pn; if ($use -eq 'false') { $s += ' @off' }
			$entries += $s
		}
	}
	return ,$entries
}

function Build-DLParameter {
	param($pNode)
	$name = Get-Child $pNode 'name'
	$o = [ordered]@{}
	$o['name'] = $name
	# title — опускаем, если совпадает с авто-выводом из имени (ru-only)
	$titleNode = $pNode.SelectSingleNode("dcssch:title", $ns)
	if ($titleNode) {
		$t = Get-LangText $titleNode
		if ($null -ne $t) {
			$auto = Title-FromName -name $name
			if (-not (($t -is [string]) -and ($t -eq $auto))) { $o['title'] = $t }
		}
	}
	# valueType
	$vtNode = $pNode.SelectSingleNode("dcssch:valueType", $ns)
	$typeVal = $null
	if ($vtNode) { $typeVal = Decompile-Type $vtNode; if ($typeVal) { $o['type'] = $typeVal } }
	# value — опускаем nil (дефолт), КРОМЕ valueListAllowed+nil: платформа пишет <value xsi:nil/>
	# не всегда (корпус 27 с / 47 без), а компилятор при valueListAllowed по умолчанию его НЕ эмитит →
	# явный маркер value:null, чтобы реэмитить nil. (Различается через Has-DLProp в компиляторе.)
	$vNodes = @($pNode.SelectNodes("dcssch:value", $ns))
	if ($vNodes.Count -gt 1) {
		# valueListAllowed: список значений — захватываем ВСЕ <dcssch:value> массивом
		$o['value'] = @($vNodes | ForEach-Object { Convert-TypedValue -raw $_.InnerText -xsiType ($_.GetAttribute("type", $NS_XSI)) })
	} elseif ($vNodes.Count -eq 1) {
		$vNode = $vNodes[0]
		if ($vNode.GetAttribute("nil", $NS_XSI) -ne 'true') {
			$o['value'] = Convert-TypedValue -raw $vNode.InnerText -xsiType ($vNode.GetAttribute("type", $NS_XSI))
		} elseif ((Get-Child $pNode 'valueListAllowed') -eq 'true') {
			$o['value'] = $null
		}
	}
	# useRestriction — опускаем true (дефолт), фиксируем false
	if ((Get-Child $pNode 'useRestriction') -eq 'false') { $o['useRestriction'] = $false }
	# expression
	$expr = Get-Child $pNode 'expression'; if ($null -ne $expr -and $expr -ne '') { $o['expression'] = $expr }
	# availableValues
	$avNodes = @($pNode.SelectNodes("dcssch:availableValue", $ns))
	if ($avNodes.Count -gt 0) {
		$avs = New-Object System.Collections.ArrayList
		foreach ($avn in $avNodes) {
			$avo = [ordered]@{}
			$avv = $avn.SelectSingleNode("dcssch:value", $ns)
			if ($avv -and ($avv.GetAttribute("nil", $NS_XSI) -ne 'true')) { $avo['value'] = Convert-TypedValue -raw $avv.InnerText -xsiType ($avv.GetAttribute("type", $NS_XSI)) }
			else { $avo['value'] = $null }
			$avp = $avn.SelectSingleNode("dcssch:presentation", $ns)
			if ($avp) { $pres = Get-LangText $avp; if ($null -ne $pres) { $avo['presentation'] = $pres } }
			[void]$avs.Add($avo)
		}
		$o['availableValues'] = @($avs)
	}
	# valueListAllowed / availableAsField
	if ((Get-Child $pNode 'valueListAllowed') -eq 'true') { $o['valueListAllowed'] = $true }
	if ((Get-Child $pNode 'availableAsField') -eq 'false') { $o['availableAsField'] = $false }
	# inputParameters
	$ipNode = $pNode.SelectSingleNode("dcssch:inputParameters", $ns)
	if ($ipNode) { $ip = Build-DLInputParameters $ipNode; if (@($ip).Count -gt 0) { $o['inputParameters'] = $ip } }
	# denyIncompleteValues / use
	if ((Get-Child $pNode 'denyIncompleteValues') -eq 'true') { $o['denyIncompleteValues'] = $true }
	$use = Get-Child $pNode 'use'; if ($null -ne $use -and $use -ne '') { $o['use'] = $use }

	# Компактизация: {name} → строка "name"; {name, type} → "name: type"; иначе объект.
	$keys = @($o.Keys)
	if ($keys.Count -eq 1) { return $name }
	if ($keys.Count -eq 2 -and $o.Contains('type') -and ($typeVal -is [string])) { return ("{0}: {1}" -f $name, $typeVal) }
	return $o
}

# --- 4. Element dispatch ---
$ELEMENT_KEY = @{
	'UsualGroup'='group'; 'ColumnGroup'='columnGroup'; 'ButtonGroup'='buttonGroup'; 'InputField'='input'; 'CheckBoxField'='check';
	'RadioButtonField'='radio'; 'LabelDecoration'='label'; 'LabelField'='labelField';
	'PictureDecoration'='picture'; 'PictureField'='picField'; 'CalendarField'='calendar';
	'Table'='table'; 'Pages'='pages'; 'Page'='page'; 'Button'='button'; 'CommandBar'='cmdBar'; 'Popup'='popup';
	'SearchStringAddition'='searchString'; 'ViewStatusAddition'='viewStatus'; 'SearchControlAddition'='searchControl';
	'SpreadSheetDocumentField'='spreadsheet'; 'HTMLDocumentField'='html'; 'TextDocumentField'='textDoc';
	'FormattedDocumentField'='formattedDoc'; 'ProgressBarField'='progressBar'; 'TrackBarField'='trackBar';
	'ChartField'='chart'; 'GraphicalSchemaField'='graphicalSchema'; 'PlannerField'='planner';
	'PeriodField'='periodField'; 'DendrogramField'='dendrogram'; 'GanttChartField'='ganttChart'
}

# Простые скаляры элемента (pass-through, зеркало $script:genericScalars компилятора). kind bool/value.
$GENERIC_SCALARS = @(
	@{ Tag='VerticalAlign'; Key='verticalAlign'; Kind='value' }
	@{ Tag='ThroughAlign'; Key='throughAlign'; Kind='value' }
	@{ Tag='EnableContentChange'; Key='enableContentChange'; Kind='bool' }
	@{ Tag='PictureSize'; Key='pictureSize'; Kind='value' }
	@{ Tag='TitleHeight'; Key='titleHeight'; Kind='value' }
	@{ Tag='ChildItemsWidth'; Key='childItemsWidth'; Kind='value' }
	@{ Tag='ShowLeftMargin'; Key='showLeftMargin'; Kind='bool' }
	@{ Tag='CellHyperlink'; Key='cellHyperlink'; Kind='bool' }
	@{ Tag='ViewMode'; Key='viewMode'; Kind='value' }
	@{ Tag='VerticalScrollBar'; Key='verticalScrollBar'; Kind='value' }
	@{ Tag='RowInputMode'; Key='rowInputMode'; Kind='value' }
	@{ Tag='Mask'; Key='mask'; Kind='value' }
	@{ Tag='CreateButton'; Key='createButton'; Kind='bool' }
	@{ Tag='FixingInTable'; Key='fixingInTable'; Kind='value' }
	@{ Tag='VerticalSpacing'; Key='verticalSpacing'; Kind='value' }
	# Спец-поля (документ/датчик) — типоспец. enum/bool скаляры pass-through (зеркало компилятора)
	@{ Tag='HorizontalScrollBar'; Key='horizontalScrollBar'; Kind='value' }
	@{ Tag='ViewScalingMode'; Key='viewScalingMode'; Kind='value' }
	@{ Tag='Output'; Key='output'; Kind='value' }
	@{ Tag='SelectionShowMode'; Key='selectionShowMode'; Kind='value' }
	@{ Tag='PointerType'; Key='pointerType'; Kind='value' }
	@{ Tag='DrawingSelectionShowMode'; Key='drawingSelectionShowMode'; Kind='value' }
	@{ Tag='WarningOnEditRepresentation'; Key='warningOnEditRepresentation'; Kind='value' }
	@{ Tag='MarkingAppearance'; Key='markingAppearance'; Kind='value' }
	@{ Tag='Protection'; Key='protection'; Kind='bool' }
	@{ Tag='Edit'; Key='edit'; Kind='bool' }
	@{ Tag='ShowGrid'; Key='showGrid'; Kind='bool' }
	@{ Tag='ShowGroups'; Key='showGroups'; Kind='bool' }
	@{ Tag='ShowHeaders'; Key='showHeaders'; Kind='bool' }
	@{ Tag='ShowRowAndColumnNames'; Key='showRowAndColumnNames'; Kind='bool' }
	@{ Tag='ShowCellNames'; Key='showCellNames'; Kind='bool' }
	@{ Tag='ShowPercent'; Key='showPercent'; Kind='bool' }
	# Report-form контекст: интервал группы / представление кнопки в контекстном меню / детальное представление настройки таблицы
	@{ Tag='HorizontalSpacing'; Key='horizontalSpacing'; Kind='value' }
	@{ Tag='RepresentationInContextMenu'; Key='representationInContextMenu'; Kind='value' }
	@{ Tag='SettingsNamedItemDetailedRepresentation'; Key='settingsNamedItemDetailedRepresentation'; Kind='bool' }
	# Хвост: высота элемента списка (radio) / ширина выпадающего списка (input)
	@{ Tag='ItemHeight'; Key='itemHeight'; Kind='value' }
	@{ Tag='DropListWidth'; Key='dropListWidth'; Kind='value' }
	# Хвост CI-форм: динамический заголовок (Page/Group) / расширенное ред. (input) / высота таблицы по строкам
	@{ Tag='TitleDataPath'; Key='titleDataPath'; Kind='value' }
	@{ Tag='ExtendedEdit'; Key='extendedEdit'; Kind='bool' }
	@{ Tag='MaxRowsCount'; Key='maxRowsCount'; Kind='value' }
	@{ Tag='AutoMaxRowsCount'; Key='autoMaxRowsCount'; Kind='bool' }
	@{ Tag='HeightControlVariant'; Key='heightControlVariant'; Kind='value' }
	@{ Tag='EditTextUpdate'; Key='editTextUpdate'; Kind='value' }
	# Корпусный хвост (zеркало компилятора): свёртка группы / форма попапа / авто-добавление /
	# выделение отрицательных / нач. позиция списка / высота списка выбора / три состояния / прокрутка
	@{ Tag='ControlRepresentation'; Key='controlRepresentation'; Kind='value' }
	@{ Tag='ShapeRepresentation'; Key='shapeRepresentation'; Kind='value' }
	@{ Tag='AutoAddIncomplete'; Key='autoAddIncomplete'; Kind='bool' }
	@{ Tag='MarkNegatives'; Key='markNegatives'; Kind='bool' }
	@{ Tag='InitialListView'; Key='initialListView'; Kind='value' }
	@{ Tag='ChoiceListHeight'; Key='choiceListHeight'; Kind='value' }
	@{ Tag='ThreeState'; Key='threeState'; Kind='bool' }
	@{ Tag='ScrollOnCompress'; Key='scrollOnCompress'; Kind='bool' }
	# Сочетание клавиш — общее свойство элемента (команда — отдельный путь)
	@{ Tag='Shortcut'; Key='shortcut'; Kind='value' }
	# Батч простых скаляров (зеркало компилятора; Table HeaderHeight/FooterHeight/CurrentRowUse — отдельно)
	@{ Tag='IncompleteChoiceMode'; Key='incompleteChoiceMode'; Kind='value' }
	@{ Tag='EqualColumnsWidth'; Key='equalColumnsWidth'; Kind='bool' }
	@{ Tag='ChildrenAlign'; Key='childrenAlign'; Kind='value' }
	@{ Tag='ImageScale'; Key='imageScale'; Kind='value' }
	@{ Tag='Zoomable'; Key='zoomable'; Kind='bool' }
	@{ Tag='Shape'; Key='shape'; Kind='value' }
	@{ Tag='PictureLocation'; Key='pictureLocation'; Kind='value' }
	# Равная ширина элементов (check/radio) / высота заголовка пункта (radio)
	@{ Tag='EqualItemsWidth'; Key='equalItemsWidth'; Kind='bool' }
	@{ Tag='ItemTitleHeight'; Key='itemTitleHeight'; Kind='value' }
	# Спец-режим ввода текста (input, моб.: Email/PhoneNumber/...) — листовой enum-скаляр
	@{ Tag='SpecialTextInputMode'; Key='specialTextInputMode'; Kind='value' }
	# Ширина пункта (radio/check) / выбор нескольких значений из выпадающего (input)
	@{ Tag='ItemWidth'; Key='itemWidth'; Kind='value' }
	@{ Tag='ShowCheckBoxesInDropList'; Key='showCheckBoxesInDropList'; Kind='bool' }
	@{ Tag='MultipleValueDataPath'; Key='multipleValueDataPath'; Kind='value' }
	@{ Tag='MultipleValuePresentDataPath'; Key='multipleValuePresentDataPath'; Kind='value' }
	# Режим авто-показа кнопок открытия/очистки (input, enum)
	@{ Tag='AutoShowOpenButtonMode'; Key='autoShowOpenButtonMode'; Kind='value' }
	@{ Tag='AutoShowClearButtonMode'; Key='autoShowClearButtonMode'; Kind='value' }
	# Оформление/картинка множественного выбора (input, редко; цвета — текст-контент)
	@{ Tag='MultipleValuesTextColor'; Key='multipleValuesTextColor'; Kind='value' }
	@{ Tag='MultipleValuesBackColor'; Key='multipleValuesBackColor'; Kind='value' }
	@{ Tag='MultipleValuePictureShape'; Key='multipleValuePictureShape'; Kind='value' }
	@{ Tag='MultipleValuePictureDataPath'; Key='multipleValuePictureDataPath'; Kind='value' }
	# Хвост листовых скаляров (по 1): автокоррекция / уникальность команды / пустое множ.значение / гориз.сжатие
	@{ Tag='AutoCorrectionOnTextInput'; Key='autoCorrectionOnTextInput'; Kind='value' }
	@{ Tag='SpellCheckingOnTextInput'; Key='spellCheckingOnTextInput'; Kind='value' }
	@{ Tag='CommandUniqueness'; Key='commandUniqueness'; Kind='bool' }
	@{ Tag='AllowInputEmptyMultipleValues'; Key='allowInputEmptyMultipleValues'; Kind='bool' }
	@{ Tag='BehaviorOnHorizontalCompression'; Key='behaviorOnHorizontalCompression'; Kind='value' }
)

# Захват generic-скаляров. Специфичная обработка (если ключ уже задан) — побеждает.
function Add-GenericScalars {
	param($obj, $node)
	foreach ($s in $GENERIC_SCALARS) {
		if ($obj.Contains($s.Key)) { continue }
		$v = Get-Child $node $s.Tag
		if ($null -eq $v) { continue }
		if ($s.Kind -eq 'bool') { $obj[$s.Key] = ($v -eq 'true') } else { $obj[$s.Key] = $v }
	}
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
			if ($valNode.GetAttribute("nil", $NS_XSI) -eq 'true') {
				# nil-значение элемента choiceList — компилятор эмитит <Value xsi:nil="true"/>
				# (иначе Convert-TypedValue вернул бы "" → typed-empty xs:string).
				$ci['valueType'] = 'nil'
			} else {
				$xsiType = $valNode.GetAttribute("type", $NS_XSI)
				$ci['value'] = Convert-TypedValue $valNode.InnerText $xsiType
				# Системное перечисление (ent:*) / иной не-примитивный тип → сохраняем valueType
				# (Normalize-ChoiceValue вывела бы xs:string). DesignTimeRef обычно авто-детектится
				# компилятором по named-ref (Enum.X.Y), НО raw-ссылка по GUID (GUID.GUID) — нет → сохраняем.
				if ($xsiType -and $xsiType -notmatch '^xs:(string|decimal|boolean|dateTime)$' -and `
					($xsiType -ne 'xr:DesignTimeRef' -or "$($valNode.InnerText)" -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-')) {
					$ci['valueType'] = $xsiType
				}
			}
		}
		# Presentation: непустой → текст/мультиязык; пустой <Presentation/> → "" — суппресс-маркер,
		# подавляет авто-вывод компилятора (иначе компилятор додумает presentation из значения).
		if ($presNode) {
			$p = Get-LangTextWS $presNode   # восстановление значимого пробела (whitespace-presentation)
			if ($null -ne $p -and $p -ne '') { $ci['presentation'] = $p } else { $ci['presentation'] = '' }
		}
		[void]$items.Add($ci)
	}
	if ($items.Count -gt 0) { return ,@($items) }
	return $null
}

# Значение Параметра выбора (<lf:Value>): скаляр через Convert-TypedValue, либо
# v8:FixedArray → массив скаляров (каждый — FormChoiceListDesTimeValue с внутренним lf:Value).
function Convert-ChoiceParamValue {
	param($valNode)
	$vt = $valNode.GetAttribute("type", $NS_XSI)
	if ($vt -match 'FixedArray$') {
		$arr = New-Object System.Collections.ArrayList
		foreach ($it in @($valNode.SelectNodes("v8:Value", $ns))) {
			$inner = $it.SelectSingleNode("lf:Value", $ns)
			if ($inner) { [void]$arr.Add((Convert-TypedValue -raw $inner.InnerText -xsiType ($inner.GetAttribute("type", $NS_XSI)))) }
		}
		return ,@($arr)
	}
	return Convert-TypedValue -raw $valNode.InnerText -xsiType $vt
}

# Инверсия Emit-ChoiceParameters: <ChoiceParameters><app:item name="X"><app:value><Value…> → [{name, value}].
function Decompile-ChoiceParameters {
	param($node)
	$cpn = $node.SelectSingleNode("lf:ChoiceParameters", $ns)
	if (-not $cpn) { return $null }
	$items = New-Object System.Collections.ArrayList
	foreach ($it in @($cpn.SelectNodes("app:item", $ns))) {
		$o = [ordered]@{}
		$o['name'] = $it.GetAttribute("name")
		$valNode = $it.SelectSingleNode("app:value/lf:Value", $ns)
		if ($valNode) { $o['value'] = Convert-ChoiceParamValue $valNode }
		[void]$items.Add($o)
	}
	if ($items.Count -gt 0) { return ,@($items) }
	return $null
}

# Инверсия Emit-ChoiceParameterLinks: <ChoiceParameterLinks><xr:Link><xr:Name><xr:DataPath><xr:ValueChange> →
# [{name, dataPath, valueChange?}]. valueChange дефолт Clear → опускаем (компилятор восстановит).
function Decompile-ChoiceParameterLinks {
	param($node)
	$cln = $node.SelectSingleNode("lf:ChoiceParameterLinks", $ns)
	if (-not $cln) { return $null }
	$items = New-Object System.Collections.ArrayList
	foreach ($lk in @($cln.SelectNodes("xr:Link", $ns))) {
		$o = [ordered]@{}
		$o['name'] = Get-Text $lk "xr:Name"
		$o['dataPath'] = Get-Text $lk "xr:DataPath"
		$vc = Get-Text $lk "xr:ValueChange"
		if ($vc -and $vc -ne 'Clear') { $o['valueChange'] = $vc }
		[void]$items.Add($o)
	}
	if ($items.Count -gt 0) { return ,@($items) }
	return $null
}

# Инверсия Emit-TypeLink: <TypeLink><xr:DataPath><xr:LinkItem> → {dataPath, linkItem}.
function Decompile-TypeLink {
	param($node)
	$tn = $node.SelectSingleNode("lf:TypeLink", $ns)
	if (-not $tn) { return $null }
	$o = [ordered]@{}
	$o['dataPath'] = Get-Text $tn "xr:DataPath"
	$li = Get-Text $tn "xr:LinkItem"
	if ($null -ne $li -and $li -ne '') { $o['linkItem'] = [int]$li }
	return $o
}

# Захват <Format>/<EditFormat> (LocalStringType) → format/editFormat (строка или {ru,en}).
function Add-FormatProps {
	param($obj, $node)
	$fmt = $node.SelectSingleNode("lf:Format", $ns); if ($fmt) { $t = Get-LangText $fmt; if ($null -ne $t -and $t -ne '') { $obj['format'] = $t } }
	$efmt = $node.SelectSingleNode("lf:EditFormat", $ns); if ($efmt) { $t = Get-LangText $efmt; if ($null -ne $t -and $t -ne '') { $obj['editFormat'] = $t } }
}

# Ядро дополнения: source + общие свойства (Add-CommonProps) + horizontalLocation.
# Layout (Add-Layout) добавляется ОТДЕЛЬНО (в Decompile-Element — пост-обработкой, в standalone — явно).
function Add-AdditionCore {
	param($obj, $node, [string]$elName)
	$src = $node.SelectSingleNode("lf:AdditionSource/lf:Item", $ns); if ($src) { $obj['source'] = $src.InnerText }
	Add-CommonProps $obj $node $elName
	$hl = Get-Child $node 'HorizontalLocation'; if ($hl) { $obj['horizontalLocation'] = $hl.ToLower() }
}

# Стандартные дополнения уровня таблицы (прямые дети <Table>): извлечь ТОЛЬКО отклонения в карту
# { тип: {свойства} }. Имя (=tableName+suffix) и source (=tableName) — дефолтные, опускаем.
function Decompile-TableAdditions {
	param($tableNode, [string]$tableName)
	$tagToKey = @{ 'SearchStringAddition'='searchString'; 'ViewStatusAddition'='viewStatus'; 'SearchControlAddition'='searchControl' }
	$map = [ordered]@{}
	foreach ($child in $tableNode.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		if (-not $tagToKey.ContainsKey($child.LocalName)) { continue }
		$key = $tagToKey[$child.LocalName]
		$nm = $child.GetAttribute("name")
		$o = [ordered]@{}; $o[$key] = $nm
		Add-AdditionCore $o $child $nm
		Add-Layout $o $child
		$o.Remove($key)                                                          # имя авто
		if ($o.Contains('source') -and $o['source'] -eq $tableName) { $o.Remove('source') }  # source=таблица дефолт
		if ($o.Count -gt 0) { $map[$key] = $o }
	}
	if ($map.Count -gt 0) { return $map }
	return $null
}

# Спец-поля «документ/датчик» — общий скелет поля (имя/path/CommonProps/TitleLocation/editMode).
# Типоспец. enum/bool скаляры ловит пост-switch Add-GenericScalars; layout/companions — общий хвост.
function Decompile-SimpleField {
	param($obj, $node, [string]$name, [string]$key)
	$obj[$key] = $name
	$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
	Add-CommonProps $obj $node $name
	$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
	$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
}

# Числовые скаляры датчиков (ProgressBar/TrackBar) — без xsi:type (≠ типизированных InputField).
function Add-GaugeScalars {
	param($obj, $node, $tags)
	foreach ($p in $tags) {
		$v = Get-Child $node $p
		if ($null -eq $v) { continue }
		$key = $p.Substring(0,1).ToLower() + $p.Substring(1)
		if ($v -match '^-?\d+$') { $obj[$key] = [int]$v } else { $obj[$key] = $v }
	}
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
			# group = направление (<Group>). Нет тега → '' (тип-маркер сохраняется, направление
			# не эмитим). Платформа явно пишет Vertical в большинстве случаев, поэтому '' ≠ 'vertical'
			# — иначе компилятор додумает <Group>Vertical</Group> там, где его нет.
			$g = Get-Child $node 'Group'
			$gmap = @{ 'Horizontal'='horizontal'; 'Vertical'='vertical'; 'AlwaysHorizontal'='alwaysHorizontal'; 'AlwaysVertical'='alwaysVertical'; 'HorizontalIfPossible'='horizontalIfPossible' }
			if ($g -and $gmap.ContainsKey($g)) { $obj[$key] = $gmap[$g] } else { $obj[$key] = '' }
			$behavior = Get-Child $node 'Behavior'
			if ($behavior) {
				$bmap = @{ 'Usual'='usual'; 'Collapsible'='collapsible'; 'PopUp'='popup' }
				if ($bmap.ContainsKey($behavior)) { $obj['behavior'] = $bmap[$behavior] } else { $obj['behavior'] = $behavior }
			}
			$obj['name'] = $name
			Add-CommonProps $obj $node $name
			$rep = Get-Child $node 'Representation'
			if ($rep) { $repmap=@{'None'='none';'NormalSeparation'='normal';'WeakSeparation'='weak';'StrongSeparation'='strong'}; if ($repmap.ContainsKey($rep)) { $obj['representation']=$repmap[$rep] } else { $obj['representation']=$rep } }
			$st = Get-Child $node 'ShowTitle'; if ($null -ne $st) { $obj['showTitle'] = ($st -eq 'true') }  # факт. значение (явный true тоже)
			$cru = Get-Child $node 'CurrentRowUse'; if ($cru) { $obj['currentRowUse'] = $cru }   # использование текущей строки группы
			$crt = $node.SelectSingleNode("lf:CollapsedRepresentationTitle", $ns); if ($crt) { $ct = Get-LangText $crt; if ($null -ne $ct -and $ct -ne '') { $obj['collapsedTitle'] = $ct } }
			if ((Get-Child $node 'United') -eq 'false') { $obj['united'] = $false }
			if ((Get-Child $node 'Collapsed') -eq 'true') { $obj['collapsed'] = $true }
			# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath группы)
			Add-FormatProps $obj $node
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'ColumnGroup' {
			# columnGroup = направление (<Group>). Нет тега → '' (тип-маркер сохраняется, направление
			# не эмитим). Иначе компилятор додумает <Group>Horizontal</Group> там, где его нет.
			$g = Get-Child $node 'Group'
			$gmap = @{ 'Horizontal'='horizontal'; 'Vertical'='vertical'; 'InCell'='inCell' }
			if ($g -and $gmap.ContainsKey($g)) { $obj[$key] = $gmap[$g] } else { $obj[$key] = '' }
			$obj['name'] = $name
			Add-CommonProps $obj $node $name
			$st = Get-Child $node 'ShowTitle'; if ($null -ne $st) { $obj['showTitle'] = ($st -eq 'true') }  # факт. значение (явный true тоже)
			$sih = Get-Child $node 'ShowInHeader'; if ($null -ne $sih) { $obj['showInHeader'] = (To-Bool $sih) }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'InputField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			# MultiLine: факт. значение (платформа эмитит и явный false — 425 в корпусе; ≠ «if true»)
			$mlIn = Get-Child $node 'MultiLine'; if ($null -ne $mlIn) { $obj['multiLine'] = ($mlIn -eq 'true') }
			# PasswordMode: факт. значение (платформа эмитит и false — 349/504 в корпусе; ≠ «if true»)
			$pmIn = Get-Child $node 'PasswordMode'; if ($null -ne $pmIn) { $obj['passwordMode'] = ($pmIn -eq 'true') }
			$mi = Get-Child $node 'AutoMarkIncomplete'; if ($null -ne $mi) { $obj['markIncomplete'] = ($mi -eq 'true') }
			$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
			$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
			$ih = $node.SelectSingleNode("lf:InputHint", $ns); if ($ih) { $t = Get-LangTextWS $ih; if ($t) { $obj['inputHint'] = $t } }
			$woe = $node.SelectSingleNode("lf:WarningOnEdit", $ns); if ($woe) { $t = Get-LangTextWS $woe; if ($null -ne $t) { $obj['warningOnEdit'] = $t } }
			$ftxt = $node.SelectSingleNode("lf:FooterText", $ns); if ($ftxt) { $t = Get-LangTextWS $ftxt; if ($null -ne $t) { $obj['footerText'] = $t } }
			foreach ($p in @('ChoiceButton','ClearButton','SpinButton','DropListButton','ChoiceListButton')) {
				$v = Get-Child $node $p; if ($null -ne $v) { $obj[($p.Substring(0,1).ToLower()+$p.Substring(1))] = (To-Bool $v) }
			}
			# InputField-специфичные bool-скаляры (захват «как есть»)
			foreach ($p in @('Wrap','OpenButton','ListChoiceMode','ExtendedEditMultipleValues','ChooseType','QuickChoice','AutoChoiceIncomplete')) {
				$v = Get-Child $node $p; if ($null -ne $v) { $obj[($p.Substring(0,1).ToLower()+$p.Substring(1))] = (To-Bool $v) }
			}
			# InputField-специфичные value-скаляры (захват «как есть»)
			foreach ($p in @('ChoiceForm','ChoiceHistoryOnInput','ChoiceFoldersAndItems','FooterDataPath')) {
				$v = Get-Child $node $p; if ($null -ne $v) { $obj[($p.Substring(0,1).ToLower()+$p.Substring(1))] = $v }
			}
			# MinValue/MaxValue — типизированное (<MinValue xsi:type="xs:decimal">N). Тип кодируем в JSON-тип:
			# xs:decimal/int → число (компилятор → xs:decimal), иначе → строка (компилятор → xs:string).
			foreach ($p in @('MinValue','MaxValue')) {
				$mn = $node.SelectSingleNode("lf:$p", $ns)
				if ($mn) {
					$xt = $mn.GetAttribute("type", $NS_XSI); $txt = $mn.InnerText
					$key = $p.Substring(0,1).ToLower() + $p.Substring(1)
					if ($xt -match 'decimal|int') {
						if ($txt -match '^-?\d+$') { $obj[$key] = [int]$txt } elseif ($txt -match '^-?\d+\.\d+$') { $obj[$key] = [decimal]$txt } else { $obj[$key] = $txt }
					} else { $obj[$key] = $txt }
				}
			}
			# Ограничение доступных типов (поле на составном/характеристика-типе): домен типов + явный набор.
			# availableTypes — тот же формат типа, что у реквизитов (§type), захват через Decompile-Type.
			$tde = Get-Child $node 'TypeDomainEnabled'; if ($null -ne $tde) { $obj['typeDomainEnabled'] = (To-Bool $tde) }
			$atNode = $node.SelectSingleNode("lf:AvailableTypes", $ns); if ($atNode) { $at = Decompile-Type $atNode; if ($at) { $obj['availableTypes'] = $at } }
			$cbr = Get-Child $node 'ChoiceButtonRepresentation'; if ($cbr) { $obj['choiceButtonRepresentation'] = $cbr }
			$cbp = Get-PictureRef $node 'ChoiceButtonPicture'; if ($null -ne $cbp) { $obj['choiceButtonPicture'] = $cbp }
			if ((Get-Child $node 'TextEdit') -eq 'false') { $obj['textEdit'] = $false }
			$cl = Decompile-ChoiceList $node; if ($cl) { $obj['choiceList'] = $cl }
			Add-FormatProps $obj $node
			# Параметры выбора / Связи параметров выбора / Связь по типу
			$cp = Decompile-ChoiceParameters $node; if ($cp) { $obj['choiceParameters'] = $cp }
			$cpl = Decompile-ChoiceParameterLinks $node; if ($cpl) { $obj['choiceParameterLinks'] = $cpl }
			$tlk = Decompile-TypeLink $node; if ($tlk) { $obj['typeLink'] = $tlk }
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
			$woe = $node.SelectSingleNode("lf:WarningOnEdit", $ns); if ($woe) { $t = Get-LangTextWS $woe; if ($null -ne $t) { $obj['warningOnEdit'] = $t } }
			# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
			$fdp = Get-Child $node 'FooterDataPath'; if ($fdp) { $obj['footerDataPath'] = $fdp }
			$ftxt = $node.SelectSingleNode("lf:FooterText", $ns); if ($ftxt) { $t = Get-LangTextWS $ftxt; if ($null -ne $t) { $obj['footerText'] = $t } }
			Add-FormatProps $obj $node
		}
		'RadioButtonField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			Add-TitleLocation $obj $node 'None'
			$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
			$rbt = Get-Child $node 'RadioButtonType'; if ($rbt) { $obj['radioButtonType'] = $rbt }
			$cc = Get-Child $node 'ColumnsCount'; if ($cc) { $obj['columnsCount'] = [int]$cc }
			$woe = $node.SelectSingleNode("lf:WarningOnEdit", $ns); if ($woe) { $t = Get-LangTextWS $woe; if ($null -ne $t) { $obj['warningOnEdit'] = $t } }
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
			# PasswordMode на LabelField — платформа эмитит явный false (редко); захват факт. значения
			$pm = Get-Child $node 'PasswordMode'; if ($null -ne $pm) { $obj['passwordMode'] = ($pm -eq 'true') }
			$woe = $node.SelectSingleNode("lf:WarningOnEdit", $ns); if ($woe) { $t = Get-LangTextWS $woe; if ($null -ne $t) { $obj['warningOnEdit'] = $t } }
			# FooterDataPath / FooterText — общие cell-свойства колонки (как у input), не только input
			$fdp = Get-Child $node 'FooterDataPath'; if ($fdp) { $obj['footerDataPath'] = $fdp }
			$ftxt = $node.SelectSingleNode("lf:FooterText", $ns); if ($ftxt) { $t = Get-LangTextWS $ftxt; if ($null -ne $t) { $obj['footerText'] = $t } }
			Add-FormatProps $obj $node
		}
		'PictureDecoration' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			# title декорации — единая ML-text форма с formatted (атрибут <Title formatted> у PictureDecoration)
			$tiNode = $node.SelectSingleNode("lf:Title", $ns)
			if ($tiNode) { $tv = Get-MLFormattedValue $tiNode; if ($null -ne $tv) { $obj['title'] = $tv } }
			$npt = $node.SelectSingleNode("lf:NonselectedPictureText", $ns); if ($npt) { $t = Get-LangTextWS $npt; if ($null -ne $t) { $obj['nonselectedPictureText'] = $t } }
			$ref = $node.SelectSingleNode("lf:Picture/xr:Ref", $ns)
			$abs = $node.SelectSingleNode("lf:Picture/xr:Abs", $ns)
			if ($ref) { $obj['src'] = $ref.InnerText } elseif ($abs) { $obj['src'] = "abs:$($abs.InnerText)" }  # встроенная картинка → префикс abs:
			$lt = $node.SelectSingleNode("lf:Picture/xr:LoadTransparent", $ns); if ($lt -and $lt.InnerText -eq 'true') { $obj['loadTransparent'] = $true }
			# Прозрачный пиксель картинки (<xr:TransparentPixel x y/>) — координаты фона прозрачности
			$tpx = $node.SelectSingleNode("lf:Picture/xr:TransparentPixel", $ns)
			if ($tpx) { $obj['transparentPixel'] = [ordered]@{ x = [int]$tpx.GetAttribute('x'); y = [int]$tpx.GetAttribute('y') } }
			if ((Get-Child $node 'Hyperlink') -eq 'true') { $obj['hyperlink'] = $true }
		}
		'PictureField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
			$tl = Get-Child $node 'TitleLocation'; if ($tl) { $obj['titleLocation'] = $tl.ToLower() }
			if ((Get-Child $node 'Hyperlink') -eq 'true') { $obj['hyperlink'] = $true }
			$vp = Get-PictureRef $node 'ValuesPicture'; if ($null -ne $vp) { $obj['valuesPicture'] = $vp }
			$npt = $node.SelectSingleNode("lf:NonselectedPictureText", $ns); if ($npt) { $t = Get-LangTextWS $npt; if ($null -ne $t) { $obj['nonselectedPictureText'] = $t } }
			# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
			$fdp = Get-Child $node 'FooterDataPath'; if ($fdp) { $obj['footerDataPath'] = $fdp }
			$ftxt = $node.SelectSingleNode("lf:FooterText", $ns); if ($ftxt) { $t = Get-LangTextWS $ftxt; if ($null -ne $t) { $obj['footerText'] = $t } }
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
			# enableDrag — теперь общий (Add-Layout, фактическое значение)
			if ($node.SelectSingleNode("lf:RowFilter", $ns)) { $obj['rowFilter'] = $null }
			if ((Get-Child $node 'Header') -eq 'false') { $obj['header'] = $false }
			if ((Get-Child $node 'Footer') -eq 'true') { $obj['footer'] = $true }
			# Высота в строках — отдельный ключ heightInTableRows (≠ height = <Height>, его ловит Add-Layout)
			$htr = Get-Child $node 'HeightInTableRows'; if ($htr) { $obj['heightInTableRows'] = [int]$htr }
			# Высота шапки/подвала таблицы в строках (pass-through; компилятор эмитит в Emit-Table)
			$hh = Get-Child $node 'HeaderHeight'; if ($null -ne $hh) { $obj['headerHeight'] = [int]$hh }
			$fh = Get-Child $node 'FooterHeight'; if ($null -ne $fh) { $obj['footerHeight'] = [int]$fh }
			# Использование текущей строки (Table-уровень; ≠ command-level CurrentRowUse) — pass-through
			$cru = Get-Child $node 'CurrentRowUse'; if ($cru) { $obj['currentRowUse'] = $cru }
			# Запрос обновления дин-списка (всегда PullFromTop в корпусе) — pass-through
			$rr = Get-Child $node 'RefreshRequest'; if ($rr) { $obj['refreshRequest'] = $rr }
			# CommandBarLocation: для дин-список-таблицы компилятор авто-инжектит "None" → инвертируем
			# (нет тега → суппресс-маркер ""; "None" → опускаем = авто-дефолт; иначе → захват).
			$cbl = Get-Child $node 'CommandBarLocation'
			if (Has-Child $node 'UpdateOnDataChange') {
				if ($null -eq $cbl) { $obj['commandBarLocation'] = '' }
				elseif ($cbl -ne 'None') { $obj['commandBarLocation'] = $cbl }
			} elseif ($cbl) { $obj['commandBarLocation'] = $cbl }
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
			# Скаляры таблицы (захват «как есть»). Autofill — СВОЁ свойство таблицы (≠ AutoCommandBar autofill).
			$taf = Get-Child $node 'Autofill'; if ($null -ne $taf) { $obj['autofill'] = ($taf -eq 'true') }
			if ((Get-Child $node 'MultipleChoice') -eq 'true') { $obj['multipleChoice'] = $true }
			$soin = Get-Child $node 'SearchOnInput'; if ($soin) { $obj['searchOnInput'] = $soin }
			$mi = Get-Child $node 'AutoMarkIncomplete'; if ($null -ne $mi) { $obj['markIncomplete'] = ($mi -eq 'true') }
			$itv = Get-Child $node 'InitialTreeView'; if ($itv) { $obj['initialTreeView'] = $itv }
			# RowsPicture — конвенция ValuesPicture (Ref/Abs + LoadTransparent дефолт false + TransparentPixel)
			$rp = Get-PictureRef $node 'RowsPicture'; if ($null -ne $rp) { $obj['rowsPicture'] = $rp }
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
				$usg = Get-Child $node 'UserSettingsGroup'
				if ($usg) { if ($usg -match '^\d+:[0-9a-fA-F]{8}-') { [Console]::Error.WriteLine("form-decompile: UserSettingsGroup '$usg' ($name) — ссылка по id, не воспроизводима, опущена") } else { $obj['userSettingsGroup'] = $usg } }
			} elseif ($rpdp) { $obj['rowPictureDataPath'] = $rpdp }
			$csNode = $node.SelectSingleNode("lf:CommandSet", $ns)
			if ($csNode) {
				$exc = New-Object System.Collections.ArrayList
				foreach ($ec in @($csNode.SelectNodes("lf:ExcludedCommand", $ns))) { [void]$exc.Add($ec.InnerText) }
				if ($exc.Count -gt 0) { $obj['excludedCommands'] = @($exc) }
			}
			$cols = Decompile-Children $node
			if ($cols) { $obj['columns'] = $cols }
			# Стандартные дополнения уровня таблицы (прямые дети) → карта отклонений additions
			$addMap = Decompile-TableAdditions $node $name
			if ($addMap) { $obj['additions'] = $addMap }
		}
		'Pages' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$pr = Get-Child $node 'PagesRepresentation'; if ($pr) { $obj['pagesRepresentation'] = $pr }
			$cru = Get-Child $node 'CurrentRowUse'; if ($cru) { $obj['currentRowUse'] = $cru }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'Page' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$g = Get-Child $node 'Group'
			$gmap = @{ 'Horizontal'='horizontal'; 'Vertical'='vertical'; 'AlwaysHorizontal'='alwaysHorizontal'; 'AlwaysVertical'='alwaysVertical'; 'HorizontalIfPossible'='horizontalIfPossible' }
			if ($g -and $gmap.ContainsKey($g)) { $obj['group'] = $gmap[$g] }
			# Картинка страницы (иконка вкладки) — конвенция ValuesPicture (дефолт LoadTransparent=false)
			$pp = Get-PictureRef $node 'Picture'; if ($null -ne $pp) { $obj['picture'] = $pp }
			$st = Get-Child $node 'ShowTitle'; if ($null -ne $st) { $obj['showTitle'] = ($st -eq 'true') }  # факт. значение (явный true тоже)
			# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath страницы)
			Add-FormatProps $obj $node
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
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			# Parameter команды: xr:MDObjectRef (объект метаданных, строка) или v8:TypeDescription (тип → {type})
			$btnParam = $node.SelectSingleNode("lf:Parameter", $ns)
			if ($btnParam) {
				$pxt = $btnParam.GetAttribute("type", $NS_XSI)
				if ($pxt -match 'TypeDescription$') { $pt = Decompile-Type $btnParam; if ($pt) { $obj['parameter'] = [ordered]@{ type = $pt } } }
				elseif ($btnParam.InnerText) { $obj['parameter'] = $btnParam.InnerText }
			}
			Add-CommonProps $obj $node $name
			$type = Get-Child $node 'Type'
			if ($type) { $tmap=@{'CommandBarButton'='commandBar';'UsualButton'='usual';'Hyperlink'='hyperlink';'CommandBarHyperlink'='hyperlink'}; if ($tmap.ContainsKey($type)) { $obj['type']=$tmap[$type] } else { $obj['type']=$type } }
			if ((Get-Child $node 'DefaultButton') -eq 'true') { $obj['defaultButton'] = $true }
			if ((Get-Child $node 'Check') -eq 'true') { $obj['checked'] = $true }
			Set-CommandPicture $obj $node
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			$lic = Get-Child $node 'LocationInCommandBar'; if ($lic) { $obj['locationInCommandBar'] = $lic }
		}
		'ButtonGroup' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$cs = Get-Child $node 'CommandSource'
			if ($cs) { if ($cs -match '^\d+:[0-9a-fA-F]{8}-') { [Console]::Error.WriteLine("form-decompile: CommandSource '$cs' ($name) — ссылка по id, не воспроизводима, опущена") } else { $obj['commandSource'] = $cs } }
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'CommandBar' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$cs = Get-Child $node 'CommandSource'
			if ($cs) { if ($cs -match '^\d+:[0-9a-fA-F]{8}-') { [Console]::Error.WriteLine("form-decompile: CommandSource '$cs' ($name) — ссылка по id, не воспроизводима, опущена") } else { $obj['commandSource'] = $cs } }
			$hl = Get-Child $node 'HorizontalLocation'; if ($hl) { $obj['horizontalLocation'] = $hl.ToLower() }
			if ((Get-Child $node 'Autofill') -eq 'true') { $obj['autofill'] = $true }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'Popup' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			Set-CommandPicture $obj $node
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			# Источник команд попапа (Form / FormCommandPanelGlobalCommands / Item.X) — как у ButtonGroup/CommandBar
			$cs = Get-Child $node 'CommandSource'
			if ($cs) { if ($cs -match '^\d+:[0-9a-fA-F]{8}-') { [Console]::Error.WriteLine("form-decompile: CommandSource '$cs' ($name) — ссылка по id, не воспроизводима, опущена") } else { $obj['commandSource'] = $cs } }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'SearchStringAddition'  { $obj[$key] = $name; Add-AdditionCore $obj $node $name }
		'ViewStatusAddition'    { $obj[$key] = $name; Add-AdditionCore $obj $node $name }
		'SearchControlAddition' { $obj[$key] = $name; Add-AdditionCore $obj $node $name }
		'SpreadSheetDocumentField' { Decompile-SimpleField $obj $node $name $key }
		'HTMLDocumentField'        { Decompile-SimpleField $obj $node $name $key }
		'TextDocumentField'        { Decompile-SimpleField $obj $node $name $key }
		'FormattedDocumentField'   { Decompile-SimpleField $obj $node $name $key }
		'ProgressBarField'         { Decompile-SimpleField $obj $node $name $key; Add-GaugeScalars $obj $node @('MinValue','MaxValue') }
		'TrackBarField'            { Decompile-SimpleField $obj $node $name $key; Add-GaugeScalars $obj $node @('MinValue','MaxValue','LargeStep','MarkingStep','Step') }
		'ChartField'               { Decompile-SimpleField $obj $node $name $key }
		'GraphicalSchemaField'     { Decompile-SimpleField $obj $node $name $key }
		'PlannerField'             { Decompile-SimpleField $obj $node $name $key }
		'PeriodField'              { Decompile-SimpleField $obj $node $name $key }
		'DendrogramField'          { Decompile-SimpleField $obj $node $name $key }
		'GanttChartField' {
			Decompile-SimpleField $obj $node $name $key
			# Вложенная <Table> (полноценная таблица) — переиспользуем общий Decompile-Element.
			# Ключ ganttTable (не 'table' — во избежание коллизии с тип-ключом таблицы в диспетчере).
			$tblNode = $node.SelectSingleNode("lf:Table", $ns)
			if ($tblNode) { $obj['ganttTable'] = Decompile-Element $tblNode }
		}
	}
	# DisplayImportance — атрибут открывающего тега (адаптивная важность отображения), захват «как есть».
	$di = $node.GetAttribute("DisplayImportance"); if ($di) { $obj['displayImportance'] = $di }
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
	Add-GenericScalars $obj $node
	# extendedTooltip: companion <ExtendedTooltip> (это LabelDecoration). Текст-форма (только <Title>) →
	# строка/{text,formatted}. Own-content (layout/оформление/флаги/hyperlink/events) → объект { text?, … }.
	$etNode = $node.SelectSingleNode("lf:ExtendedTooltip", $ns)
	if ($etNode) {
		$etTitle = $etNode.SelectSingleNode("lf:Title", $ns)
		$textVal = if ($etTitle) { Get-MLFormattedValue $etTitle } else { $null }
		$etObj = [ordered]@{}
		Add-Layout $etObj $etNode
		Add-GenericScalars $etObj $etNode
		Add-Appearance $etObj $etNode
		# ToolTip самого компаньона (подсказка расширенной подсказки) — реальный текст (ML), не пустой Title
		$etTT = $etNode.SelectSingleNode("lf:ToolTip", $ns)
		if ($etTT) { $ttVal = Get-LangText $etTT; if ($null -ne $ttVal) { $etObj['tooltip'] = $ttVal } }
		if ((Get-Child $etNode 'Visible') -eq 'false') { $etObj['hidden'] = $true }
		if ((Get-Child $etNode 'Enabled') -eq 'false') { $etObj['disabled'] = $true }
		if ((Get-Child $etNode 'Hyperlink') -eq 'true') { $etObj['hyperlink'] = $true }
		# События компаньона (напр. URLProcessing у hyperlink-подсказки) — переиспользуем механизм событий элемента
		$etEv = Get-Events $etNode $name; if ($etEv) { $etObj['events'] = $etEv }
		if ($etObj.Count -gt 0) {
			if ($null -ne $textVal) {
				if ($textVal -is [System.Collections.IDictionary] -and $textVal.Contains('text')) { $etObj['text'] = $textVal['text']; if ($textVal['formatted']) { $etObj['formatted'] = $true } }
				else { $etObj['text'] = $textVal }
				# formatted ЯВНО из атрибута Title — компилятор не re-детектит markup на мультиязычном тексте
				if (-not $etObj.Contains('formatted') -and $etTitle -and $etTitle.GetAttribute('formatted') -eq 'true') { $etObj['formatted'] = $true }
			}
			$obj['extendedTooltip'] = $etObj
		} elseif ($null -ne $textVal) {
			$obj['extendedTooltip'] = $textVal
		}
	}
	# companion-панели с контентом: AutoCommandBar → commandBar, ContextMenu → contextMenu (любой элемент)
	$isDynListTable = ($tag -eq 'Table') -and (Has-Child $node 'UpdateOnDataChange')
	$cb = Decompile-CompanionPanel $node 'AutoCommandBar' $isDynListTable
	if ($null -ne $cb) { $obj['commandBar'] = $cb }
	$cm = Decompile-CompanionPanel $node 'ContextMenu'
	if ($null -ne $cm) { $obj['contextMenu'] = $cm }
	return $obj
}

# ─────────────────────────────────────────────────────────────────────────────
# Planner design-time <Settings xsi:type="pl:Planner"> → объект planner на реквизите.
# Полный захват каждого поля (раундтрип бит-в-бит); зеркало Emit-PlannerSettings.
function PLD-Bool { param($v) if ($null -eq $v) { return $null } return ($v -eq 'true') }
function PLD-Int  { param($v) if ($null -eq $v) { return $null } return [int]$v }
# <pl:value> → текст (тип xr:DesignTimeRef/xs:string выводится компилятором из вида значения); nil → $null.
function Get-PlannerValue {
	param($node)
	if (-not $node) { return $null }
	if ($node.GetAttribute('nil', $NS_XSI) -eq 'true') { return $null }
	if ($node.InnerText) { return $node.InnerText } else { return $null }
}
function Build-PlannerFont {
	param($node)
	if (-not $node) { return $null }
	$o = [ordered]@{}
	foreach ($a in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
		$av = $node.GetAttribute($a); if ($av -ne '') { $o[$a] = $av }
	}
	if ($o.Count -eq 0) { return $null }
	return $o
}
function Build-PlannerBorder {
	param($node)
	if (-not $node) { return $null }
	$o = [ordered]@{}
	$w = $node.GetAttribute('width'); if ($w -ne '') { $o['width'] = [int]$w }
	$st = $node.SelectSingleNode("*[local-name()='style']"); if ($st) { $o['style'] = $st.InnerText }
	return $o
}
function Build-PlannerItem {
	param($itn)
	$o = [ordered]@{}
	$valNode = $itn.SelectSingleNode("*[local-name()='value']")
	if ($valNode -and $valNode.GetAttribute('nil', $NS_XSI) -ne 'true' -and $valNode.InnerText) { $o['value'] = $valNode.InnerText }
	$o['text'] = (Get-Child $itn 'text')
	$tt = Get-Child $itn 'tooltip'; if ($tt) { $o['tooltip'] = $tt }
	$o['begin'] = (Get-Child $itn 'begin')
	$o['end'] = (Get-Child $itn 'end')
	$o['borderColor'] = (Get-Child $itn 'borderColor')
	$o['backColor'] = (Get-Child $itn 'backColor')
	$o['textColor'] = (Get-Child $itn 'textColor')
	$fnt = Build-PlannerFont ($itn.SelectSingleNode("*[local-name()='font']")); if ($fnt) { $o['font'] = $fnt }
	$o['replacementDate'] = (Get-Child $itn 'replacementDate')
	$o['deleted'] = (PLD-Bool (Get-Child $itn 'deleted'))
	$o['id'] = (Get-Child $itn 'id')
	$o['textFormatted'] = (PLD-Bool (Get-Child $itn 'textFormatted'))
	$brd = Build-PlannerBorder ($itn.SelectSingleNode("*[local-name()='border']")); if ($brd) { $o['border'] = $brd }
	$o['editMode'] = (Get-Child $itn 'editMode')
	return $o
}
function Build-PlannerDimElement {
	param($eln)
	$o = [ordered]@{}
	$v = Get-PlannerValue ($eln.SelectSingleNode("*[local-name()='value']")); if ($null -ne $v) { $o['value'] = $v }
	$o['text'] = (Get-Child $eln 'text')
	$o['borderColor'] = (Get-Child $eln 'borderColor')
	$o['backColor'] = (Get-Child $eln 'backColor')
	$o['textColor'] = (Get-Child $eln 'textColor')
	$fnt = Build-PlannerFont ($eln.SelectSingleNode("*[local-name()='font']")); if ($fnt) { $o['font'] = $fnt }
	$subs = New-Object System.Collections.ArrayList
	foreach ($s in @($eln.SelectNodes("*[local-name()='item']"))) { [void]$subs.Add((Build-PlannerDimElement $s)) }
	if ($subs.Count -gt 0) { $o['elements'] = @($subs) }
	$sos = Get-Child $eln 'showOnlySubordinatesAreas'; if ($null -ne $sos) { $o['showOnlySubordinatesAreas'] = ($sos -eq 'true') }
	$o['textFormatted'] = (PLD-Bool (Get-Child $eln 'textFormatted'))
	return $o
}
function Build-PlannerDimension {
	param($dn)
	$o = [ordered]@{}
	$v = Get-PlannerValue ($dn.SelectSingleNode("*[local-name()='value']")); if ($null -ne $v) { $o['value'] = $v }
	$o['text'] = (Get-Child $dn 'text')
	$o['borderColor'] = (Get-Child $dn 'borderColor')
	$o['backColor'] = (Get-Child $dn 'backColor')
	$o['textColor'] = (Get-Child $dn 'textColor')
	$fnt = Build-PlannerFont ($dn.SelectSingleNode("*[local-name()='font']")); if ($fnt) { $o['font'] = $fnt }
	$els = New-Object System.Collections.ArrayList
	foreach ($e in @($dn.SelectNodes("*[local-name()='item']"))) { [void]$els.Add((Build-PlannerDimElement $e)) }
	if ($els.Count -gt 0) { $o['elements'] = @($els) }
	$o['textFormatted'] = (PLD-Bool (Get-Child $dn 'textFormatted'))
	return $o
}
function Build-PlannerLevel {
	param($lvn)
	$o = [ordered]@{}
	$o['measure'] = (Get-Child $lvn 'measure')
	$o['interval'] = (PLD-Int (Get-Child $lvn 'interval'))
	$o['show'] = (PLD-Bool (Get-Child $lvn 'show'))
	$lineNode = $lvn.SelectSingleNode("*[local-name()='line']")
	if ($lineNode) {
		$ln = [ordered]@{}
		$w = $lineNode.GetAttribute('width'); if ($w -ne '') { $ln['width'] = [int]$w }
		$g = $lineNode.GetAttribute('gap'); if ($g -ne '') { $ln['gap'] = ($g -eq 'true') }
		$st = $lineNode.SelectSingleNode("*[local-name()='style']"); if ($st) { $ln['style'] = $st.InnerText }
		$o['line'] = $ln
	}
	$o['scaleColor'] = (Get-Child $lvn 'scaleColor')
	$o['dayFormatRule'] = (Get-Child $lvn 'dayFormatRule')
	$fmtNode = $lvn.SelectSingleNode("*[local-name()='format']")
	if ($fmtNode) { $f = Get-LangText $fmtNode; if ($null -ne $f) { $o['format'] = $f } }
	$labelsNode = $lvn.SelectSingleNode("*[local-name()='labels']")
	if ($labelsNode) { $o['labels'] = [ordered]@{ ticks = (PLD-Int (Get-Child $labelsNode 'ticks')) } }
	$o['backColor'] = (Get-Child $lvn 'backColor')
	$o['textColor'] = (Get-Child $lvn 'textColor')
	$o['showPereodicalLabels'] = (PLD-Bool (Get-Child $lvn 'showPereodicalLabels'))
	return $o
}
function Build-PlannerTimeScale {
	param($tsn)
	$o = [ordered]@{}
	$o['placement'] = (Get-Child $tsn 'placement')
	$levels = New-Object System.Collections.ArrayList
	foreach ($lvn in @($tsn.SelectNodes("*[local-name()='level']"))) { [void]$levels.Add((Build-PlannerLevel $lvn)) }
	$o['levels'] = @($levels)
	$o['transparent'] = (PLD-Bool (Get-Child $tsn 'transparent'))
	$o['backColor'] = (Get-Child $tsn 'backColor')
	$o['textColor'] = (Get-Child $tsn 'textColor')
	$o['currentLevel'] = (PLD-Int (Get-Child $tsn 'currentLevel'))
	return $o
}
function Build-PlannerSettings {
	param($setNode)
	$pl = [ordered]@{}
	$itemNodes = @($setNode.SelectNodes("*[local-name()='item']"))
	if ($itemNodes.Count -gt 0) {
		$items = New-Object System.Collections.ArrayList
		foreach ($itn in $itemNodes) { [void]$items.Add((Build-PlannerItem $itn)) }
		$pl['items'] = @($items)
	}
	$dimNodes = @($setNode.SelectNodes("*[local-name()='dimension']"))
	if ($dimNodes.Count -gt 0) {
		$dims = New-Object System.Collections.ArrayList
		foreach ($dn in $dimNodes) { [void]$dims.Add((Build-PlannerDimension $dn)) }
		$pl['dimensions'] = @($dims)
	}
	$pl['borderColor'] = (Get-Child $setNode 'borderColor')
	$pl['backColor'] = (Get-Child $setNode 'backColor')
	$pl['textColor'] = (Get-Child $setNode 'textColor')
	$pl['lineColor'] = (Get-Child $setNode 'lineColor')
	$fnt = Build-PlannerFont ($setNode.SelectSingleNode("*[local-name()='font']")); if ($fnt) { $pl['font'] = $fnt }
	$pl['beginOfRepresentationPeriod'] = (Get-Child $setNode 'beginOfRepresentationPeriod')
	$pl['endOfRepresentationPeriod'] = (Get-Child $setNode 'endOfRepresentationPeriod')
	$pl['alignElementsOfTimeScale'] = (PLD-Bool (Get-Child $setNode 'alignElementsOfTimeScale'))
	$pl['displayTimeScaleWrapHeaders'] = (PLD-Bool (Get-Child $setNode 'displayTimeScaleWrapHeaders'))
	$pl['displayWrapHeaders'] = (PLD-Bool (Get-Child $setNode 'displayWrapHeaders'))
	$wfNode = $setNode.SelectSingleNode("*[local-name()='timeScaleWrapHeadersFormat']")
	if ($wfNode) { $wf = Get-LangText $wfNode; if ($null -ne $wf) { $pl['timeScaleWrapHeadersFormat'] = $wf } }
	$pl['periodicVariantUnit'] = (Get-Child $setNode 'periodicVariantUnit')
	$pl['periodicVariantRepetition'] = (PLD-Int (Get-Child $setNode 'periodicVariantRepetition'))
	$pl['timeScaleWrapBeginIndent'] = (PLD-Int (Get-Child $setNode 'timeScaleWrapBeginIndent'))
	$pl['timeScaleWrapEndIndent'] = (PLD-Int (Get-Child $setNode 'timeScaleWrapEndIndent'))
	$tsNode = $setNode.SelectSingleNode("*[local-name()='timeScale']")
	if ($tsNode) { $pl['timeScale'] = (Build-PlannerTimeScale $tsNode) }
	$perNode = $setNode.SelectSingleNode("*[local-name()='period']")
	if ($perNode) { $pl['period'] = [ordered]@{ begin = (Get-Child $perNode 'begin'); end = (Get-Child $perNode 'end') } }
	$pl['displayCurrentDate'] = (PLD-Bool (Get-Child $setNode 'displayCurrentDate'))
	$pl['itemsTimeRepresentation'] = (Get-Child $setNode 'itemsTimeRepresentation')
	$pl['itemsBehaviorWhenSpaceInsufficient'] = (Get-Child $setNode 'itemsBehaviorWhenSpaceInsufficient')
	$pl['autoMinColumnWidth'] = (PLD-Bool (Get-Child $setNode 'autoMinColumnWidth'))
	$pl['autoMinRowHeight'] = (PLD-Bool (Get-Child $setNode 'autoMinRowHeight'))
	$pl['minColumnWidth'] = (PLD-Int (Get-Child $setNode 'minColumnWidth'))
	$pl['minRowHeight'] = (PLD-Int (Get-Child $setNode 'minRowHeight'))
	$pl['fixDimensionsHeader'] = (Get-Child $setNode 'fixDimensionsHeader')
	$pl['fixTimeScaleHeader'] = (Get-Child $setNode 'fixTimeScaleHeader')
	$brd = Build-PlannerBorder ($setNode.SelectSingleNode("*[local-name()='border']")); if ($brd) { $pl['border'] = $brd }
	$pl['newItemsTextType'] = (Get-Child $setNode 'newItemsTextType')
	return $pl
}

# ─────────────────────────────────────────────────────────────────────────────
# Chart design-time <Settings xsi:type="d4p1:Chart"> → объект chart. Генерик-движок:
# рекурсивный захват поддерева d4p1; структуры (line/border/font/ML/области/серии)
# детектируются по форме узла. Малые name-set'ы: ML-поля (даже ru-only/пустые → ML),
# серии (всегда массив), attrs-узлы. Порядок ключей JSON = порядок XML (раундтрип).
$CHART_ML_FIELDS = @{ 'title'=1;'lbFormat'=1;'lbpFormat'=1;'vsFormat'=1;'dtFormat'=1;'dataSourceDescription'=1;'labelFormat'=1;'text'=1 }
$CHART_SERIES_FIELDS = @{ 'realSeriesData'=1;'realExSeriesData'=1;'realPointData'=1;'realDataItems'=1 }
$CHART_ATTR_FIELDS = @{ 'gaugeQualityBands'=1 }
function Conv-ChartScalar {
	param([string]$v)
	if ($v -eq 'true') { return $true }
	if ($v -eq 'false') { return $false }
	return $v
}
function Build-ChartNode {
	param($n, [string]$name)
	# ML-поле → строка/мапа/"" (даже ru-only форсим в ML на эмите по имени)
	if ($CHART_ML_FIELDS.Contains($name)) {
		$ml = Get-LangText $n
		if ($null -eq $ml) { return '' } else { return $ml }
	}
	$kids = @($n.SelectNodes("*"))
	if ($kids.Count -eq 0) {
		# лист: attrs-only (шрифт/gaugeQualityBands) или текст
		$attrs = @($n.Attributes | Where-Object { $_.Name -ne 'xmlns' -and -not $_.Name.StartsWith('xmlns:') -and $_.Name -ne 'xsi:type' -and $_.Name -ne 'xsi:nil' })
		if ($attrs.Count -gt 0) {
			$o = [ordered]@{}; foreach ($a in $attrs) { $o[$a.Name] = (Conv-ChartScalar $a.Value) }; return $o
		}
		return (Conv-ChartScalar $n.InnerText)
	}
	# line/border: дочерний v8ui:style (+ width[/gap])
	$styleChild = $n.SelectSingleNode("*[local-name()='style']")
	if ($styleChild) {
		$o = [ordered]@{}
		$w = $n.GetAttribute('width'); if ($w -ne '') { $o['width'] = [int]$w }
		$g = $n.GetAttribute('gap'); if ($g -ne '') { $o['gap'] = ($g -eq 'true') }
		$o['style'] = $styleChild.InnerText
		return $o
	}
	# вложенный объект d4p1 (область/шкала/titleArea/серия): группируем детей по имени
	$o = [ordered]@{}
	foreach ($c in $kids) {
		$ln = $c.LocalName
		$val = Build-ChartNode $c $ln
		if ($CHART_SERIES_FIELDS.Contains($ln)) {
			if (-not $o.Contains($ln)) { $o[$ln] = New-Object System.Collections.ArrayList }
			[void]$o[$ln].Add($val)
		} elseif ($o.Contains($ln)) {
			if ($o[$ln] -isnot [System.Collections.IList]) { $tmp = New-Object System.Collections.ArrayList; [void]$tmp.Add($o[$ln]); $o[$ln] = $tmp }
			[void]$o[$ln].Add($val)
		} else {
			$o[$ln] = $val
		}
	}
	# нормализуем ArrayList → @() для сериализации
	foreach ($k in @($o.Keys)) { if ($o[$k] -is [System.Collections.ArrayList]) { $o[$k] = @($o[$k]) } }
	return $o
}
function Build-ChartSettings {
	param($setNode)
	return (Build-ChartNode $setNode '')
}

# --- 5. Form-level assembly ---
$dsl = [ordered]@{}

$titleNode = $root.SelectSingleNode("lf:Title", $ns)
if ($titleNode) { $t = Get-LangText $titleNode; if ($null -ne $t) { $dsl['title'] = $t } }

# properties (прямые скаляры под <Form>, PascalCase → camelCase)
$KNOWN_FORM_PROPS = @('AutoTitle','ReportResult','DetailsData','ReportFormType','AutoShowState','ReportResultViewMode','ViewModeApplicationOnSetReportResult','WindowOpeningMode','CommandBarLocation','SaveDataInSettings','AutoSaveDataInSettings','AutoTime','UsePostingMode','RepostOnWrite','AutoURL','AutoFillCheck','Customizable','EnterKeyBehavior','VerticalScroll','Width','Height','Group','UseForFoldersAndItems','SaveWindowSettings','ScalingMode','VerticalSpacing','VariantAppearance','ShowCloseButton','HorizontalAlign','ChildrenAlign','ShowTitle','ConversationsRepresentation','CollapseItemsByImportanceVariant','GroupList','ChildItemsWidth','VerticalAlign','HorizontalSpacing','CustomSettingsFolder','SettingsStorage','Enabled','Scale')
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
# Ссылка на члена формы по id ("N:uuid") в groupList/customSettingsFolder НЕ воспроизводима: наш
# компилятор переназначает id, и ссылка указала бы не туда (либо вовсе dangling — платформа сама их
# часто не разрешает). Резолв в имя ненадёжен (N не всегда соответствует named-элементу). Игнорируем
# с предупреждением (имя задаётся вручную через form-edit). Имя-форма захватывается как есть.
foreach ($refKey in 'groupList','customSettingsFolder') {
	if ($props.Contains($refKey) -and "$($props[$refKey])" -match '^\d+:[0-9a-fA-F]{8}-') {
		[Console]::Error.WriteLine("form-decompile: $refKey = '$($props[$refKey])' — ссылка на члена формы по id, не воспроизводима (id переназначаются), опущена. Задайте по имени через form-edit.")
		$props.Remove($refKey)
	}
}
# AutoTitle при наличии title: компилятор инъектит false (~95% форм). Зеркалим:
#  - оригинал имеет AutoTitle=false → опускаем ключ (компилятор реинъектит при наличии title);
#  - оригинал НЕ имеет AutoTitle (редкие 5%, напр. вспом. формы) → суппресс-маркер "" (не инъектить).
if ($dsl.Contains('title')) {
	if (-not $props.Contains('autoTitle')) { $props['autoTitle'] = '' }
	elseif ($props['autoTitle'] -eq $false) { $props.Remove('autoTitle') }
}
if ($props.Count -gt 0) { $dsl['properties'] = $props }

# MobileDeviceCommandBarContent (form-level) → список имён командных панелей/кнопок
$mdcb = $root.SelectSingleNode("lf:MobileDeviceCommandBarContent", $ns)
if ($mdcb) {
	$names = New-Object System.Collections.ArrayList
	foreach ($it in @($mdcb.SelectNodes("xr:Item", $ns))) {
		$v = $it.SelectSingleNode("xr:Value", $ns); if ($v) { [void]$names.Add($v.InnerText) }
	}
	if ($names.Count -gt 0) { $dsl['mobileCommandBarContent'] = @($names) }
}

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
	$acbDI = $acb.GetAttribute("DisplayImportance")   # адаптивная важность форменной панели (атрибут тега)
	$acbKids = Decompile-Children $acb
	$acbObj = $null
	if ($haln -or ($acbAutofill -eq 'false') -or $acbKids -or $acbDI) {
		$acbObj = [ordered]@{}
		$acbObj['autoCmdBar'] = $acb.GetAttribute("name")
		if ($acbDI) { $acbObj['displayImportance'] = $acbDI }
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
# Объектный тип (зеркало Test-IsObjectLikeType компилятора) — кандидат на авто-main эвристики 11b.3.
function Test-IsObjectLikeTypeDec([string]$type) {
	if ([string]::IsNullOrEmpty($type)) { return $false }
	if ($type -eq 'DynamicList' -or $type -eq 'ConstantsSet') { return $true }
	return ($type -match '^(CatalogObject|DocumentObject|DataProcessorObject|ReportObject|ExternalDataProcessorObject|ExternalReportObject|BusinessProcessObject|TaskObject|ChartOfAccountsObject|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesObject|ExchangePlanObject|InformationRegisterRecordSet|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|CalculationRegisterRecordSet|InformationRegisterRecordManager)\.')
}
$attrsNode = $root.SelectSingleNode("lf:Attributes", $ns)
if ($attrsNode) {
	$attrs = New-Object System.Collections.ArrayList
	# Подавление авто-main (эвристика компилятора 11b.3): если НЕТ ни одного <MainAttribute> И ровно
	# один реквизит объектного типа — компилятор пометит его main. В оригинале он НЕ main (раз тега нет)
	# → ставим суппресс-маркер main:false. На формах с >1 объектным реквизитом / с явным main — не нужно.
	$allAttrNodes = @($attrsNode.SelectNodes("lf:Attribute", $ns))
	$anyMainAttr = $false; $objLikeNodes = @()
	foreach ($an in $allAttrNodes) {
		if ((Get-Child $an 'MainAttribute') -eq 'true') { $anyMainAttr = $true }
		$atype = Decompile-Type ($an.SelectSingleNode("lf:Type", $ns))
		if (Test-IsObjectLikeTypeDec "$atype") { $objLikeNodes += $an }
	}
	$suppressMainName = if ((-not $anyMainAttr) -and $objLikeNodes.Count -eq 1) { $objLikeNodes[0].GetAttribute("name") } else { $null }
	foreach ($a in $allAttrNodes) {
		$ao = [ordered]@{}
		$ao['name'] = $a.GetAttribute("name")
		$ty = Decompile-Type ($a.SelectSingleNode("lf:Type", $ns)); if ($ty) { $ao['type'] = $ty }
		# valueType: <Settings xsi:type="v8:TypeDescription"> — уточнение типа значений ValueList
		# (та же грамматика типа). Дин-список Settings (xsi:type="DynamicList") обрабатывается отдельно.
		$setNode = $a.SelectSingleNode("lf:Settings", $ns)
		if ($setNode -and $setNode.GetAttribute("type", $NS_XSI) -match 'TypeDescription$') {
			$vt = Decompile-Type $setNode
			$ao['valueType'] = if ($vt) { $vt } else { '' }   # пустой Settings → маркер ""
		}
		# Planner design-time <Settings xsi:type="pl:Planner"> → объект planner (полный захват).
		elseif ($setNode -and $setNode.GetAttribute("type", $NS_XSI) -match 'Planner$') {
			$ao['planner'] = Build-PlannerSettings $setNode
		}
		# Chart/GanttChart design-time <Settings xsi:type="d4p1:Chart"/"d4p1:GanttChart"> → chart (генерик).
		elseif ($setNode -and $setNode.GetAttribute("type", $NS_XSI) -match 'd4p1:(Gantt)?Chart$') {
			$ao['chart'] = Build-ChartSettings $setNode
		}
		if ((Get-Child $a 'MainAttribute') -eq 'true') { $ao['main'] = $true }
		elseif ($suppressMainName -and $ao['name'] -eq $suppressMainName) { $ao['main'] = $false }
		$vw = Decompile-XrFlag $a 'View'; if ($null -ne $vw) { $ao['view'] = $vw }
		$ed = Decompile-XrFlag $a 'Edit'; if ($null -ne $ed) { $ao['edit'] = $ed }
		# Title атрибута. Компилятор для не-main атрибута без ключа title додумывает заголовок
		# из имени. Поэтому: нет <Title> → суппресс-маркер ''; ru-only == авто-вывод → опускаем
		# ключ (компилятор воспроизведёт); иначе → явный заголовок.
		$isMain = ($ao['main'] -eq $true)   # именно true; main:false (суппресс-маркер) → не-main для Title
		$tNode = $a.SelectSingleNode("lf:Title", $ns)
		if ($tNode) {
			$t = Get-LangTextWS $tNode   # восстановление значимого пробела (whitespace-заголовок реквизита)
			if ($null -ne $t) {
				if ($isMain -or -not ($t -is [string]) -or $t -ne (Title-FromName $ao['name'])) { $ao['title'] = $t }
			}
		} elseif (-not $isMain) {
			$ao['title'] = ''
		}
		# SavedData: компилятор додумывает true для main-реквизита объектного типа (эвристика $mainSaved:
		# Catalog/Document/ChartOf*/ExchangePlan/BusinessProcess/Task Object + RecordManager). Если оригинал
		# тега не имеет — ставим суппресс-маркер savedData:false (как с MainAttribute).
		if ((Get-Child $a 'SavedData') -eq 'true') { $ao['savedData'] = $true }
		elseif ($ao['main'] -eq $true -and "$($ao['type'])" -match '^(CatalogObject|DocumentObject|ChartOfAccountsObject|ChartOfCalculationTypesObject|ChartOfCharacteristicTypesObject|ExchangePlanObject|BusinessProcessObject|TaskObject)\.|RecordManager\.') { $ao['savedData'] = $false }
		# Save: сохранение значения реквизита в пользовательских настройках. Один Field=имя → save:true;
		# иначе снимаем префикс "имя." (голое имя/UUID/прочее — как есть) → строка (1) или массив.
		$saveNode = $a.SelectSingleNode("lf:Save", $ns)
		if ($saveNode) {
			$nm = "$($ao['name'])"
			$flds = @($saveNode.SelectNodes("lf:Field", $ns) | ForEach-Object { $_.InnerText })
			if ($flds.Count -eq 1 -and $flds[0] -eq $nm) {
				$ao['save'] = $true
			} elseif ($flds.Count -gt 0) {
				# Снимаем префикс "имя." ТОЛЬКО когда остаток — простое подполе, которое компилятор
				# реинъектит (зеркало его условия: ≠имя, без точки, не UUID-ссылка ^N/M). Многоуровневый
				# путь "имя.Settings.Filter" и UUID-ссылка "имя.1/0:GUID" компилятор эмитит как есть
				# (префикс не вернёт) → храним ПОЛНЫЙ путь, иначе префикс теряется.
				$stripped = @($flds | ForEach-Object {
					if ($_ -match "^$([regex]::Escape($nm))\.([^.]+)$" -and $matches[1] -notmatch '^\d+/\d+') { $matches[1] } else { $_ }
				})
				if ($stripped.Count -eq 1) { $ao['save'] = $stripped[0] } else { $ao['save'] = $stripped }
			}
		}
		$fc = Get-Child $a 'FillCheck'; if ($fc) { $ao['fillCheck'] = $fc }
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
				# Снимаем префикс "ИмяРеквизита.". Маркер "~" (query-поле дин-списка) сохраняем,
				# префикс снимаем ПОСЛЕ него: ~Список.Остановлен → ~Остановлен (компилятор развернёт обратно).
				if ($t.StartsWith('~')) {
					$rest = $t.Substring(1)
					if ($rest.StartsWith($prefix)) { $rest = $rest.Substring($prefix.Length) }
					$t = "~$rest"
				} elseif ($t.StartsWith($prefix)) {
					$t = $t.Substring($prefix.Length)
				}
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
		# Settings динамического списка (только xsi:type=DynamicList; Planner/TypeDescription — выше)
		$setNode = $a.SelectSingleNode("lf:Settings", $ns)
		if ($setNode -and $setNode.GetAttribute("type", $NS_XSI) -match 'DynamicList$') {
			$so = [ordered]@{}
			# AutoFillAvailableFields — дефолт true, платформа эмитит только отклонение (false). Захват «как есть».
			$afaf = Get-Child $setNode 'AutoFillAvailableFields'; if ($null -ne $afaf) { $so['autoFillAvailableFields'] = ($afaf -eq 'true') }
			$mt = Get-Child $setNode 'MainTable'; if ($mt) { $so['mainTable'] = $mt }
			# GetInvisibleFieldPresentations — дефолт true, платформа эмитит только отклонение (false, корпус 20/20). Факт. значение.
			$gifp = Get-Child $setNode 'GetInvisibleFieldPresentations'; if ($null -ne $gifp) { $so['getInvisibleFieldPresentations'] = ($gifp -eq 'true') }
				# Ключ набора (query-based список): KeyType (RowNumber/FieldValue/RowKey) + KeyField* (0+).
				$kt = Get-Child $setNode 'KeyType'; if ($kt) { $so['keyType'] = $kt }
				$kfNodes = @($setNode.SelectNodes("lf:KeyField", $ns) | ForEach-Object { $_.InnerText })
				if ($kfNodes.Count -gt 0) { $so['keyFields'] = @($kfNodes) }
			# AutoSaveUserSettings — авто-сохранение польз. настроек дин-списка (в корпусе только false;
			# дефолт true → платформа эмитит отклонение). Захват факт. значения.
			$asus = Get-Child $setNode 'AutoSaveUserSettings'; if ($null -ne $asus) { $so['autoSaveUserSettings'] = ($asus -eq 'true') }
			$qtNode = $setNode.SelectSingleNode("lf:QueryText", $ns)
			$hasQ = [bool]($qtNode -and $qtNode.InnerText)
			if ($hasQ) { $so['query'] = Maybe-ExternalizeQuery -queryText $qtNode.InnerText -listName "$($ao['name'])" }
			# ManualQuery: компилятор выводит из наличия query (hasQuery → true). Платформа в редких
			# случаях (корпус 16) хранит QueryText при ManualQuery=false → фиксируем отклонение от эвристики.
			$mqV = Get-Child $setNode 'ManualQuery'
			if ($null -ne $mqV) { $mqActual = ($mqV -eq 'true'); if ($mqActual -ne $hasQ) { $so['manualQuery'] = $mqActual } }
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
					if ((Has-Child $fn 'dataPath') -and $dp -ne $fld) { $fo['dataPath'] = $dp }
					# Тип поля набора: DataSetFieldField (дефолт, компилятор хардкодит) vs
					# DataSetFieldNestedDataSet (поле-вложенный набор = реквизит табличной части). Маркер nested.
					$fTypeAttr = $fn.GetAttribute("type", $NS_XSI)
						if ($fTypeAttr -match 'NestedDataSet$') { $fo['nested'] = $true }
						elseif ($fTypeAttr -match 'Folder$') { $fo['folder'] = $true }
					$ftn = $fn.SelectSingleNode("dcssch:title", $ns)
					if ($ftn) { $t = Get-LangText $ftn; if ($null -ne $t) { $fo['title'] = $t } }
					# valueType поля набора (тип значения; вычисляемые/кастомные поля). Грамматика типа.
					$fvt = $fn.SelectSingleNode("dcssch:valueType", $ns)
					if ($fvt) { $fvtVal = Decompile-Type $fvt; if ($fvtVal) { $fo['valueType'] = $fvtVal } }
					# presentationExpression (выражение представления поля) + appearance (формат/оформление поля)
					$fpe = Get-Child $fn 'presentationExpression'
					if ($null -ne $fpe -and $fpe -ne '') { $fo['presentationExpression'] = $fpe }
					$fappNode = $fn.SelectSingleNode("dcssch:appearance", $ns)
					if ($fappNode) { $fap = Get-SettingsAppearance $fappNode; if ($fap -and $fap.Count -gt 0) { $fo['appearance'] = $fap } }
					$furNode = $fn.SelectSingleNode("dcssch:useRestriction", $ns)
					if ($furNode) { $fur = Build-RestrictObj $furNode; if ($fur.Count -gt 0) { $fo['useRestriction'] = $fur } }
					$faurNode = $fn.SelectSingleNode("dcssch:attributeUseRestriction", $ns)
					if ($faurNode) { $faur = Build-RestrictObj $faurNode; if ($faur.Count -gt 0) { $fo['attributeUseRestriction'] = $faur } }
					$fipNode = $fn.SelectSingleNode("dcssch:inputParameters", $ns)
					if ($fipNode) { $fip = Build-DLInputParameters $fipNode; if (@($fip).Count -gt 0) { $fo['inputParameters'] = $fip } }
					[void]$fields.Add($fo)
				}
				$so['fields'] = @($fields)
			}
			# Вычисляемые поля DataSet (<CalculatedField>) — после Field*, до Parameter*.
			$calcNodes = @($setNode.SelectNodes("lf:CalculatedField", $ns))
			if ($calcNodes.Count -gt 0) {
				$cfs = New-Object System.Collections.ArrayList
				foreach ($cn in $calcNodes) { [void]$cfs.Add((Build-CalcField $cn)) }
				$so['calculatedFields'] = @($cfs)
			}
			# Schema-параметры дин-списка (прямые <Parameter> под Settings, не в ListSettings)
			$paramNodes = @($setNode.SelectNodes("lf:Parameter", $ns))
			if ($paramNodes.Count -gt 0) {
				$dlPars = New-Object System.Collections.ArrayList
				foreach ($pn in $paramNodes) { [void]$dlPars.Add((Build-DLParameter $pn)) }
				$so['parameters'] = @($dlPars)
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
				# Параметры данных компоновки (dcsset:dataParameters) — значения параметров запроса в
				# настройках. Грамматика как у СКД (shorthand "Имя @off" / объект). См. Build-FormDataParameters.
				$dpNode = $lsNode.SelectSingleNode("dcsset:dataParameters", $ns)
				if ($dpNode -and $dpNode.SelectSingleNode("dcscor:item", $ns)) {
					$dp = Build-FormDataParameters $dpNode
					if (@($dp).Count -gt 0) { $so['dataParameters'] = @($dp) }
				}
				# Форма скелета ListSettings: дескриптор только для НЕ-каноничных форм (частичные/минимальные).
				# Канон → $null (компилятор регенерит полный скелет, как раньше).
				# Группировка строк списка: прямой <dcsset:item> ListSettings (не в filter/order/CA).
				$grpItemNode = $lsNode.SelectSingleNode("dcsset:item", $ns)
				$grouping = $null
				if ($grpItemNode) { $grouping = Build-ListGrouping $grpItemNode }
				if ($null -ne $grouping) { $so['grouping'] = $grouping }
				$lsShape = Get-ListSettingsShape $lsNode ($null -ne $grouping)
				if ($null -ne $lsShape) { $so['listSettings'] = $lsShape }
			}
			if ($so.Count -gt 0) { $ao['settings'] = $so }
		}
		[void]$attrs.Add($ao)
	}
	if ($attrs.Count -gt 0) { $dsl['attributes'] = @($attrs) }
}

# conditionalAppearance формы (<ConditionalAppearance> — последний child <Attributes>;
# та же DCS-грамматика, что settings.conditionalAppearance → переиспользуем Build-ConditionalAppearance)
if ($attrsNode) {
	$caNode = $attrsNode.SelectSingleNode("lf:ConditionalAppearance", $ns)
	if ($caNode) {
		$ca = Build-ConditionalAppearance -caNode $caNode -loc "form/conditionalAppearance"
		if (@($ca).Count -gt 0) { $dsl['conditionalAppearance'] = @($ca) }
	}
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
		if ((Get-Child $c 'ModifiesSavedData') -eq 'true') { $co['modifiesSavedData'] = $true }
		# Заголовок команды: есть <Title> → захват; нет → суппресс-маркер "" (иначе компилятор
		# додумает из имени — авто-вывод неверен для ~0.13% команд без заголовка в оригинале).
		$tNode = $c.SelectSingleNode("lf:Title", $ns)
		if ($tNode) { $t = Get-LangText $tNode; if ($null -ne $t) { $co['title'] = $t } }
		else { $co['title'] = '' }
		$ttNode = $c.SelectSingleNode("lf:ToolTip", $ns); if ($ttNode) { $t = Get-LangText $ttNode; if ($null -ne $t) { $co['tooltip'] = $t } }
		$us = Decompile-XrFlag $c 'Use'; if ($null -ne $us) { $co['use'] = $us }
		$cfo = Decompile-FunctionalOptions $c; if ($cfo) { $co['functionalOptions'] = $cfo }
		$cru = Get-Child $c 'CurrentRowUse'; if ($cru) { $co['currentRowUse'] = $cru }
		# Используемая таблица — ссылка по имени элемента-таблицы (<AssociatedTableElementId xsi:type="xs:string">Имя</…>)
		$ate = Get-Child $c 'AssociatedTableElementId'; if ($ate) { $co['table'] = $ate }
		$sc = Get-Child $c 'Shortcut'; if ($sc) { $co['shortcut'] = $sc }
		Set-CommandPicture $co $c
		$rep = Get-Child $c 'Representation'; if ($rep) { $co['representation'] = $rep }
		[void]$cmds.Add($co)
	}
	if ($cmds.Count -gt 0) { $dsl['commands'] = @($cmds) }
}

# commandInterface (форменный <CommandInterface> — последний дочерний Form)
$ci = Decompile-CommandInterface
if ($null -ne $ci) { $dsl['commandInterface'] = $ci }

# --- 6. Output ---
$json = ConvertTo-CompactJson -obj $dsl
if ($OutputPath) {
	[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
	Save-QueryFiles
	Write-Host "form-decompile: $OutputPath"
} else {
	Write-Output $json
}
