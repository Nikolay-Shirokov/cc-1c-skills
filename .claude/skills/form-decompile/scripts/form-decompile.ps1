# form-decompile v0.12 — Decompile 1C managed Form.xml to JSON DSL (draft)
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

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("lf", $NS_LF)
$ns.AddNamespace("v8", $NS_V8)
$ns.AddNamespace("xr", $NS_XR)
$ns.AddNamespace("xsi", $NS_XSI)

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

# Общие layout-свойства → в $obj (симметрично Emit-Layout компилятора).
# Вызывается один раз для любого элемента. Height тут — пиксельная высота
# (<Height>); Table хранит высоту в строках (<HeightInTableRows>) и ловит её сам.
function Add-Layout {
	param($obj, $node)
	if ((Get-Child $node 'SkipOnInput') -eq 'true') { $obj['skipOnInput'] = $true }
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

# Общие свойства элемента (visible/enabled/readonly/title/events) → в hash
function Add-CommonProps {
	param($obj, $node, [string]$elName)
	if ((Get-Child $node 'Visible') -eq 'false') { $obj['hidden'] = $true }
	if ((Get-Child $node 'Enabled') -eq 'false') { $obj['disabled'] = $true }
	if ((Get-Child $node 'ReadOnly') -eq 'true') { $obj['readOnly'] = $true }
	$titleNode = $node.SelectSingleNode("lf:Title", $ns)
	if ($titleNode) {
		$t = Get-LangText $titleNode
		if ($null -ne $t) { $obj['title'] = $t }
		# formatted у LabelDecoration выводится компилятором из hyperlink — отдельный ключ не нужен (#16 хвост)
	}
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
		switch -regex ($raw) {
			'^xs:string$' {
				$len = $typeNode.SelectSingleNode("v8:StringQualifiers/v8:Length", $ns)
				if ($len -and [int]$len.InnerText -gt 0) { $short = "string($($len.InnerText))" } else { $short = "string" }
			}
			'^xs:decimal$' {
				$d = $typeNode.SelectSingleNode("v8:NumberQualifiers/v8:Digits", $ns)
				$f = $typeNode.SelectSingleNode("v8:NumberQualifiers/v8:FractionDigits", $ns)
				$sgn = $typeNode.SelectSingleNode("v8:NumberQualifiers/v8:AllowedSign", $ns)
				$dd = if ($d) { $d.InnerText } else { '0' }
				$ff = if ($f) { $f.InnerText } else { '0' }
				if ($sgn -and $sgn.InnerText -eq 'Nonnegative') { $short = "decimal($dd,$ff,nonneg)" } else { $short = "decimal($dd,$ff)" }
			}
			'^xs:boolean$' { $short = "boolean" }
			'^xs:dateTime$' {
				$df = $typeNode.SelectSingleNode("v8:DateQualifiers/v8:DateFractions", $ns)
				$dfv = if ($df) { $df.InnerText } else { 'DateTime' }
				switch ($dfv) { 'Date' { $short = 'date' } 'Time' { $short = 'time' } default { $short = 'dateTime' } }
			}
			'^v8:ValueListType$' { $short = 'ValueList' }
			'^(v8|v8ui|cfg):(.+)$' { $short = $matches[2] }
			default { $short = $raw }
		}
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
			$g = Get-Child $node 'Group'
			$gmap = @{ 'Horizontal'='horizontal'; 'Vertical'='vertical'; 'AlwaysHorizontal'='alwaysHorizontal'; 'AlwaysVertical'='alwaysVertical' }
			$behavior = Get-Child $node 'Behavior'
			if ($behavior -eq 'Collapsible') { $obj[$key] = 'collapsible' }
			elseif ($g -and $gmap.ContainsKey($g)) { $obj[$key] = $gmap[$g] }
			else { $obj[$key] = 'vertical' }
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
			$cl = $node.SelectSingleNode("lf:ChoiceList", $ns)
			if ($cl) {
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
				if ($items.Count -gt 0) { $obj['choiceList'] = @($items) }
			}
		}
		'LabelDecoration' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			if ((Get-Child $node 'Hyperlink') -eq 'true') { $obj['hyperlink'] = $true }
		}
		'LabelField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$em = Get-Child $node 'EditMode'; if ($em) { $obj['editMode'] = $em }
			# LabelField: тег <Hiperlink> (опечатка платформы), не <Hyperlink>
			if ((Get-Child $node 'Hiperlink') -eq 'true') { $obj['hyperlink'] = $true }
		}
		'PictureDecoration' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
			$ref = $node.SelectSingleNode("lf:Picture/xr:Ref", $ns); if ($ref) { $obj['src'] = $ref.InnerText }
			$lt = $node.SelectSingleNode("lf:Picture/xr:LoadTransparent", $ns); if ($lt -and $lt.InnerText -eq 'true') { $obj['loadTransparent'] = $true }
			if ((Get-Child $node 'Hyperlink') -eq 'true') { $obj['hyperlink'] = $true }
		}
		'PictureField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$ref = $node.SelectSingleNode("lf:ValuesPicture/xr:Ref", $ns); if ($ref) { $obj['valuesPicture'] = $ref.InnerText }
		}
		'CalendarField' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
		}
		'Table' {
			$obj[$key] = $name
			$dp = Get-Child $node 'DataPath'; if ($dp) { $obj['path'] = $dp }
			Add-CommonProps $obj $node $name
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			if ((Get-Child $node 'ChangeRowSet') -eq 'true') { $obj['changeRowSet'] = $true }
			if ((Get-Child $node 'ChangeRowOrder') -eq 'true') { $obj['changeRowOrder'] = $true }
			if ((Get-Child $node 'Header') -eq 'false') { $obj['header'] = $false }
			if ((Get-Child $node 'Footer') -eq 'true') { $obj['footer'] = $true }
			$htr = Get-Child $node 'HeightInTableRows'; if ($htr) { $obj['height'] = [int]$htr }
			$cbl = Get-Child $node 'CommandBarLocation'; if ($cbl) { $obj['commandBarLocation'] = $cbl }
			$ssl = Get-Child $node 'SearchStringLocation'; if ($ssl) { $obj['searchStringLocation'] = $ssl }
			$vsl = Get-Child $node 'ViewStatusLocation'; if ($vsl) { $obj['viewStatusLocation'] = $vsl }
			$scl = Get-Child $node 'SearchControlLocation'; if ($scl) { $obj['searchControlLocation'] = $scl }
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
				else { $obj['command'] = $cmd }
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
			$rep = Get-Child $node 'Representation'; if ($rep) { $obj['representation'] = $rep }
			$kids = Decompile-Children $node
			if ($kids) { $obj['children'] = $kids }
		}
		'CommandBar' {
			$obj[$key] = $name
			Add-CommonProps $obj $node $name
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
		elseif ($tag -eq 'Button') { $autoTitle = -not ($obj.Contains('command') -or $obj.Contains('stdCommand')) }
		elseif ($tag -in @('InputField','CheckBoxField','RadioButtonField','LabelField','Table','CalendarField')) { $autoTitle = -not $obj.Contains('path') }
		if ($autoTitle) { $obj['title'] = '' }
	}
	Add-Layout $obj $node
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

# elements (+ форменный AutoCommandBar как autoCmdBar-элемент, если у него есть содержимое)
$elemList = New-Object System.Collections.ArrayList
$acb = $root.SelectSingleNode("lf:AutoCommandBar", $ns)
if ($acb) {
	$haln = Get-Child $acb 'HorizontalAlign'
	$acbAutofill = Get-Child $acb 'Autofill'
	$acbKids = Decompile-Children $acb
	if ($haln -or ($acbAutofill -eq 'false') -or $acbKids) {
		$acbObj = [ordered]@{}
		$acbObj['autoCmdBar'] = $acb.GetAttribute("name")
		if ($haln) { $acbObj['horizontalAlign'] = $haln }
		if ($acbAutofill -eq 'false') { $acbObj['autofill'] = $false }
		if ($acbKids) { $acbObj['children'] = $acbKids }
		[void]$elemList.Add($acbObj)
	}
}
$elements = Decompile-Children $root
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
		$tNode = $a.SelectSingleNode("lf:Title", $ns); if ($tNode) { $t = Get-LangText $tNode; if ($null -ne $t) { $ao['title'] = $t } }
		if ((Get-Child $a 'SavedData') -eq 'true') { $ao['savedData'] = $true }
		$fc = Get-Child $a 'FillChecking'; if ($fc) { $ao['fillChecking'] = $fc }
		$colsNode = $a.SelectSingleNode("lf:Columns", $ns)
		if ($colsNode) {
			$cols = New-Object System.Collections.ArrayList
			foreach ($c in @($colsNode.SelectNodes("lf:Column", $ns))) {
				$co = [ordered]@{}; $co['name'] = $c.GetAttribute("name")
				$cty = Decompile-Type ($c.SelectSingleNode("lf:Type", $ns)); if ($cty) { $co['type'] = $cty }
				$ctNode = $c.SelectSingleNode("lf:Title", $ns); if ($ctNode) { $t = Get-LangText $ctNode; if ($null -ne $t) { $co['title'] = $t } }
				[void]$cols.Add($co)
			}
			if ($cols.Count -gt 0) { $ao['columns'] = @($cols) }
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
	Write-Host "form-decompile: $OutputPath"
} else {
	Write-Output $json
}
