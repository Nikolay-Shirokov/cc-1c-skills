# skd-decompile v0.90 — Decompile 1C DCS Template.xml to JSON DSL (draft)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$TemplatePath,

	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 0. Resolve and validate input ---

if (-not (Test-Path $TemplatePath)) {
	Write-Error "Template not found: $TemplatePath"
	exit 1
}

$TemplatePath = (Resolve-Path $TemplatePath).Path

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load($TemplatePath)

$root = $xmlDoc.DocumentElement

# Ring 3: not a DataCompositionSchema → fail-fast
if ($root.LocalName -ne 'DataCompositionSchema') {
	[Console]::Error.WriteLine("skd-decompile: корневой элемент <$($root.LocalName)> не <DataCompositionSchema> — это не схема СКД (возможно, табличный документ — используй /mxl-decompile).")
	exit 2
}

# --- 1. Namespace manager ---

$NS_SCHEMA = "http://v8.1c.ru/8.1/data-composition-system/schema"
$NS_COM    = "http://v8.1c.ru/8.1/data-composition-system/common"
$NS_COR    = "http://v8.1c.ru/8.1/data-composition-system/core"
$NS_SET    = "http://v8.1c.ru/8.1/data-composition-system/settings"
$NS_AT     = "http://v8.1c.ru/8.1/data-composition-system/area-template"
$NS_V8     = "http://v8.1c.ru/8.1/data/core"
$NS_V8UI   = "http://v8.1c.ru/8.1/data/ui"
$NS_XS     = "http://www.w3.org/2001/XMLSchema"
$NS_XSI    = "http://www.w3.org/2001/XMLSchema-instance"
$NS_CFG    = "http://v8.1c.ru/8.1/data/enterprise/current-config"

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("r",      $NS_SCHEMA)
$ns.AddNamespace("dcscom", $NS_COM)
$ns.AddNamespace("dcscor", $NS_COR)
$ns.AddNamespace("dcsset", $NS_SET)
$ns.AddNamespace("dcsat",  $NS_AT)
$ns.AddNamespace("v8",     $NS_V8)
$ns.AddNamespace("v8ui",   $NS_V8UI)
$ns.AddNamespace("xs",     $NS_XS)
$ns.AddNamespace("xsi",    $NS_XSI)

# --- 1b. Ring 3 scan: bail out on unsupported constructs ---

function Fail-Ring3 {
	param([string]$kind, [string]$loc)
	[Console]::Error.WriteLine("skd-decompile: декомпиляция не поддерживает $kind (path: $loc)")
	[Console]::Error.WriteLine("Для точечной работы с этим отчётом используй /skd-edit.")
	exit 3
}

# Picture cells in templates
foreach ($el in $xmlDoc.SelectNodes("//*[local-name()='item']")) {
	$xsi = $el.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	if ($xsi -match 'Picture$' -and $el.NamespaceURI -eq "http://v8.1c.ru/8.1/data-composition-system/area-template") {
		Fail-Ring3 -kind "Picture cell в шаблоне" -loc "template/.../item[@xsi:type=Picture]"
	}
}

# ValueStorage parameter type
foreach ($vt in $xmlDoc.SelectNodes("//*[local-name()='Type']")) {
	$inner = $vt.InnerText
	if ($inner -match '^v8:ValueStorage$|:ValueStorage$') {
		Fail-Ring3 -kind "параметр типа ХранилищеЗначения" -loc "valueType[v8:Type=ValueStorage]"
	}
}

# templateCondition (variant templates) — top-level <template> with <templateCondition>
foreach ($t in $xmlDoc.SelectNodes("//*[local-name()='templateCondition']")) {
	Fail-Ring3 -kind "templateCondition (вариативные шаблоны)" -loc "template/templateCondition"
}

# nestedSchema — DCS внутри DCS со своими dataSet/parameters/templates
foreach ($ns_el in $xmlDoc.SelectNodes("//*[local-name()='nestedSchema']")) {
	Fail-Ring3 -kind "nestedSchema (вложенные подсхемы)" -loc "nestedSchema"
}

# Пустые dataSets — отчёт без источника данных (только settingsVariant с outputParameters).
# Такие отчёты валидны (динамическое заполнение из кода), но compile требует ≥1 dataSet,
# и весь DSL заточен под data-driven отчёты — fail-fast.
if ($xmlDoc.SelectNodes("//*[local-name()='dataSet']").Count -eq 0) {
	Fail-Ring3 -kind "отчёт без dataSet (служебный шаблон-обёртка)" -loc "DataCompositionSchema/dataSet"
}

# --- 2. Warnings accumulator ---

$script:warnings = @()
$script:warningCounter = 0

function Add-Warning {
	param([string]$kind, [string]$loc, [string]$detail)
	$script:warningCounter++
	$id = "W{0:D3}" -f $script:warningCounter
	$script:warnings += [ordered]@{ id = $id; kind = $kind; loc = $loc; detail = $detail }
	return $id
}

function New-Sentinel {
	param([string]$kind, [string]$loc, [string]$detail)
	$id = Add-Warning -kind $kind -loc $loc -detail $detail
	return [ordered]@{ '__unsupported__' = [ordered]@{ id = $id; kind = $kind; loc = $loc } }
}

# --- 3. Helpers ---

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

function Get-Text {
	param($node, [string]$xpath)
	if (-not $node) { return $null }
	if ([string]::IsNullOrEmpty($xpath)) { return $node.InnerText }
	$n = $node.SelectSingleNode($xpath, $ns)
	if ($n) { return $n.InnerText } else { return $null }
}

# Extract LocalStringType (multilingual title) → string (if only ru) or hashtable
function Get-MLText {
	param($node)
	if (-not $node) { return $null }
	$items = $node.SelectNodes("v8:item", $ns)
	if ($items.Count -eq 0) { return $null }
	$dict = [ordered]@{}
	foreach ($it in $items) {
		$lang = Get-Text $it "v8:lang"
		$content = Get-Text $it "v8:content"
		if ($lang) { $dict[$lang] = if ($content) { $content } else { "" } }
	}
	if ($dict.Count -eq 1 -and $dict.Contains('ru')) { return $dict['ru'] }
	return $dict
}

# Strip namespace prefix from xsi:type value (e.g. "dcsset:Foo" → "Foo")
function Get-LocalXsiType {
	param($node)
	if (-not $node) { return $null }
	$t = $node.GetAttribute("type", $NS_XSI)
	if ($t -match ':(.+)$') { return $matches[1] }
	return $t
}

# Convert one <v8:Type> element + sibling qualifiers → shorthand type string
function Get-OneTypeShorthand {
	param($typeNode, $qualNumber, $qualString, $qualDate)
	$raw = $typeNode.InnerText.Trim()
	# Strip namespace prefix; check if it's d5p1: (config refs)
	$local = $raw
	if ($raw -match '^([^:]+):(.+)$') {
		$prefix = $matches[1]
		$local  = $matches[2]
		# Resolve prefix → namespace URI
		$uri = $typeNode.GetNamespaceOfPrefix($prefix)
		if ($uri -eq $NS_CFG) {
			return $local   # CatalogRef.X, DocumentRef.X, etc.
		}
		if ($uri -eq $NS_XS) {
			switch ($local) {
				'string'   {
					if ($qualString) {
						$len = [int](Get-Text $qualString "v8:Length")
						$allowed = Get-Text $qualString "v8:AllowedLength"
						if ($len -eq 0) { return 'string' }
						if ($allowed -eq 'Fixed') { return "string($len,fix)" }
						return "string($len)"
					}
					return 'string'
				}
				'boolean'  { return 'boolean' }
				'decimal'  {
					if ($qualNumber) {
						$d = [int](Get-Text $qualNumber "v8:Digits")
						$f = [int](Get-Text $qualNumber "v8:FractionDigits")
						$sign = Get-Text $qualNumber "v8:AllowedSign"
						$signSuf = ''
						if ($sign -eq 'Nonnegative') { $signSuf = ',nonneg' }
						# Always explicit (D,F) — JSON readable, no surprise from default folding
						if ($f -eq 0) { return "decimal($d$signSuf)" }
						if ($signSuf) { return "decimal($d,$f$signSuf)" }
						return "decimal($d,$f)"
					}
					return 'decimal'
				}
				'dateTime' {
					$frac = if ($qualDate) { Get-Text $qualDate "v8:DateFractions" } else { 'DateTime' }
					switch ($frac) {
						'Date'     { return 'date' }
						'Time'     { return 'time' }
						default    { return 'dateTime' }
					}
				}
				default    { return $local }
			}
		}
		if ($uri -eq $NS_V8) {
			# v8:StandardPeriod, etc.
			return $local
		}
	}
	return $local
}

# valueType → string shorthand OR array of shorthands (composite)
function Get-ValueTypeShorthand {
	param($valueTypeNode)
	if (-not $valueTypeNode) { return $null }
	$types = $valueTypeNode.SelectNodes("v8:Type", $ns)
	$typeSets = $valueTypeNode.SelectNodes("v8:TypeSet", $ns)
	if ($types.Count -eq 0 -and $typeSets.Count -eq 0) { return $null }
	$qualN = $valueTypeNode.SelectSingleNode("v8:NumberQualifiers", $ns)
	$qualS = $valueTypeNode.SelectSingleNode("v8:StringQualifiers", $ns)
	$qualD = $valueTypeNode.SelectSingleNode("v8:DateQualifiers", $ns)
	$shorts = @()
	foreach ($t in $types) { $shorts += (Get-OneTypeShorthand -typeNode $t -qualNumber $qualN -qualString $qualS -qualDate $qualD) }
	# TypeSet (композитный тип-набор) — извлекаем local-name из значения "<prefix>:Name".
	foreach ($ts in $typeSets) {
		$txt = $ts.InnerText
		if ($txt -match ':(.+)$') { $shorts += $matches[1] }
		else { $shorts += $txt }
	}
	if ($shorts.Count -eq 1) { return $shorts[0] }
	return ,$shorts
}

# <role> → @{ tokens, extras }
#   tokens — список @-флагов (boolean dcscom children); @period — sugar для periodNumber=1+periodType=Main
#   extras — любые dcscom:KEY со строковым значением (balanceGroupName/balanceType/parentDimension/...).
# compile/skd-edit принимают произвольные KV — никакого whitelist'а.
function Get-RoleInfo {
	param($roleNode, [string]$loc)
	if (-not $roleNode) { return $null }
	$tokens = @()
	$extras = [ordered]@{}
	$hasComplex = $false
	# Сначала проверяем @period sugar: periodNumber=1 + periodType=Main
	$pnNode = $roleNode.SelectSingleNode("dcscom:periodNumber", $ns)
	$ptNode = $roleNode.SelectSingleNode("dcscom:periodType", $ns)
	$periodHandled = $false
	if ($pnNode -and $ptNode -and $pnNode.InnerText -eq '1' -and $ptNode.InnerText -eq 'Main') {
		$tokens += '@period'
		$periodHandled = $true
	}
	foreach ($child in $roleNode.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		if ($child.NamespaceURI -ne $NS_COM) { $hasComplex = $true; continue }
		# Skip periodNumber/periodType if уже свернули в @period
		if ($periodHandled -and ($child.LocalName -eq 'periodNumber' -or $child.LocalName -eq 'periodType')) { continue }
		$txt = $child.InnerText
		if ($txt -eq 'true') {
			$tokens += '@' + $child.LocalName
		} elseif ($txt -eq 'false' -or -not $txt) {
			# Игнорируем явный false (дефолт)
		} else {
			# Любая строка → extra (без whitelist — compile эмитит любой ключ)
			$extras[$child.LocalName] = $txt
		}
	}
	if ($hasComplex) {
		$null = New-Sentinel -kind 'ComplexRole' -loc $loc -detail 'Роль с не-dcscom-атрибутами не сворачивается в DSL'
	}
	return [ordered]@{ tokens = $tokens; extras = $extras }
}

# Render role into shorthand string (если все extras "простые") или object form.
# Returns hashtable @{ value = <string|object|array>; isString = $true|$false } or $null если роль пустая.
function Render-Role {
	param($tokens, $extras)
	$hasExtras = $extras -and $extras.Count -gt 0
	$hasTokens = $tokens -and $tokens.Count -gt 0
	if (-not $hasExtras -and -not $hasTokens) { return $null }
	if (-not $hasExtras) {
		# Только флаги: одиночный — без @ (back-compat), множественный — "@a @b" string.
		$plain = @($tokens | ForEach-Object { $_ -replace '^@','' })
		if ($plain.Count -eq 1) { return @{ value = $plain[0]; isString = $true } }
		$withAt = @($plain | ForEach-Object { "@$_" })
		return @{ value = ($withAt -join ' '); isString = $true }
	}
	# Есть extras — проверяем, все ли значения "простые" (без пробелов и кавычек)
	$allSimple = $true
	foreach ($v in $extras.Values) {
		if ("$v" -notmatch '^[\w\.\-]+$') { $allSimple = $false; break }
	}
	if ($allSimple) {
		# Shorthand: "@flag1 @flag2 K=V K=V"
		$parts = @()
		foreach ($t in $tokens) { $parts += $t }
		foreach ($k in $extras.Keys) { $parts += "$k=$($extras[$k])" }
		return @{ value = ($parts -join ' '); isString = $true }
	}
	# Object form
	$obj = [ordered]@{}
	foreach ($t in $tokens) { $obj[($t -replace '^@','')] = $true }
	foreach ($k in $extras.Keys) { $obj[$k] = $extras[$k] }
	return @{ value = $obj; isString = $false }
}

# <useRestriction> → array of #tokens
function Get-RestrictionTokens {
	param($urNode)
	if (-not $urNode) { return @() }
	$tokens = @()
	$map = @{ 'field' = '#noField'; 'condition' = '#noFilter'; 'group' = '#noGroup'; 'order' = '#noOrder' }
	foreach ($key in 'field','condition','group','order') {
		$v = Get-Text $urNode "r:$key"
		if ($v -eq 'true') { $tokens += $map[$key] }
	}
	return $tokens
}

# <appearance> → hashtable {param: value}
function Get-FontValue {
	param($valNode)
	# Шрифт: <dcscor:value xsi:type="v8ui:Font" ref=... faceName=... height=... bold=... .../>
	# Сохраняем все атрибуты как объект {@type:Font, ...}, чтобы compile мог восстановить bit-perfect.
	$f = [ordered]@{ '@type' = 'Font' }
	foreach ($attrName in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
		$a = $valNode.Attributes[$attrName]
		if ($null -ne $a) { $f[$attrName] = $a.Value }
	}
	return $f
}

function Get-AppearanceDict {
	param($appNode)
	if (-not $appNode) { return $null }
	$dict = [ordered]@{}
	$items = $appNode.SelectNodes("dcscor:item", $ns)
	foreach ($it in $items) {
		$p = Get-Text $it "dcscor:parameter"
		$valNode = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $p -or -not $valNode) { continue }
		# Value can be xs:string, v8ui:HorizontalAlign, v8:LocalStringType, v8ui:Font, etc.
		$valType = Get-LocalXsiType $valNode
		if ($valType -eq 'LocalStringType') {
			$rawVal = Get-MLText $valNode
		} elseif ($valType -eq 'Font') {
			$rawVal = Get-FontValue $valNode
		} else {
			$rawVal = $valNode.InnerText
		}
		# <dcscor:use>false</...> → wrapper {value, use: false}
		$useV = Get-Text $it "dcscor:use"
		if ($useV -eq 'false') {
			$dict[$p] = [ordered]@{ value = $rawVal; use = $false }
		} else {
			$dict[$p] = $rawVal
		}
	}
	return $dict
}

# Read <r:inputParameters> → JSON array. Returns $null если отсутствует или пустой.
function Read-InputParameters {
	param($parentNode)
	$ip = $parentNode.SelectSingleNode("r:inputParameters", $ns)
	if (-not $ip) { return $null }
	$result = @()
	foreach ($it in $ip.SelectNodes("dcscor:item", $ns)) {
		$entry = [ordered]@{}
		$useText = Get-Text $it "dcscor:use"
		$pName = Get-Text $it "dcscor:parameter"
		$entry['parameter'] = $pName
		if ($useText -eq 'false') { $entry['use'] = $false }
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if ($val) {
			$vType = Get-LocalXsiType $val
			if ($vType -eq 'ChoiceParameters') {
				$cp = @()
				foreach ($cpItem in $val.SelectNodes("dcscor:item", $ns)) {
					$cpEntry = [ordered]@{ name = Get-Text $cpItem "dcscor:choiceParameter" }
					$values = @()
					foreach ($v in $cpItem.SelectNodes("dcscor:value", $ns)) {
						$vXsi = Get-LocalXsiType $v
						$vTxt = $v.InnerText
						if ($vXsi -eq 'boolean') {
							$values += ($vTxt -eq 'true')
						} elseif ($vXsi -eq 'decimal') {
							if ($vTxt -match '^-?\d+$') { $values += [int]$vTxt }
							else { $values += [double]$vTxt }
						} else {
							$values += $vTxt
						}
					}
					$cpEntry['values'] = $values
					$cp += $cpEntry
				}
				$entry['choiceParameters'] = $cp
			} elseif ($vType -eq 'ChoiceParameterLinks') {
				$cpl = @()
				foreach ($cplItem in $val.SelectNodes("dcscor:item", $ns)) {
					$cplEntry = [ordered]@{
						name = Get-Text $cplItem "dcscor:choiceParameter"
						value = Get-Text $cplItem "dcscor:value"
					}
					$mode = Get-Text $cplItem "dcscor:mode"
					if ($mode) { $cplEntry['mode'] = $mode }
					$cpl += $cplEntry
				}
				$entry['choiceParameterLinks'] = $cpl
			} elseif ($vType -eq 'LocalStringType') {
				# Multilang dict {ru, en, ...}
				$ml = Get-MLText $val
				if ($ml) { $entry['value'] = $ml } else { $entry['value'] = '' }
			} else {
				# Simple typed value
				$txt = $val.InnerText
				if ($vType -eq 'boolean') {
					$entry['value'] = ($txt -eq 'true')
				} elseif ($vType -eq 'decimal') {
					if ($txt -match '^-?\d+$') { $entry['value'] = [int]$txt }
					else { $entry['value'] = [double]$txt }
				} else {
					$entry['value'] = $txt
					# Сохраняем кастомный xsi:type (например, "d6p1:FoldersAndItemsUse" с локальным xmlns).
					# Не сохраняем xs:* (string/dateTime/etc) — compile auto-detect.
					$ta = $val.Attributes['xsi:type']
					if ($ta -and $ta.Value -notmatch '^xs:') {
						$prefix = ($ta.Value -split ':', 2)[0]
						$localName = ($ta.Value -split ':', 2)[1]
						$uri = $val.GetNamespaceOfPrefix($prefix)
						if ($uri) {
							$entry['valueType'] = [ordered]@{ uri = $uri; name = $localName }
						}
					}
				}
			}
		}
		$result += $entry
	}
	if ($result.Count -eq 0) { return $null }
	return ,$result
}

# Build a field JSON entry (shorthand if possible, object form otherwise)
function Build-Field {
	param($fieldNode, [string]$loc)
	# inputParameters теперь поддерживается в DSL — читается ниже в needsObject
	$inputParameters = Read-InputParameters -parentNode $fieldNode
	# orderExpression теперь поддерживается в DSL — читается ниже в needsObject.
	# На одном поле может быть несколько <orderExpression> (multi-sort fallback),
	# в этом случае сохраняем массив; единичный — как объект (back-compat).
	$orderExprNodes = $fieldNode.SelectNodes("r:orderExpression", $ns)
	$orderExpression = $null
	$orderExpressionList = @()
	foreach ($oeN in $orderExprNodes) {
		$oeExpr = Get-Text $oeN "dcscom:expression"
		$oeType = Get-Text $oeN "dcscom:orderType"
		$oeAuto = Get-Text $oeN "dcscom:autoOrder"
		$oe = [ordered]@{}
		if ($oeExpr) { $oe['expression'] = $oeExpr }
		if ($oeType) { $oe['orderType'] = $oeType }
		if ($oeAuto -eq 'true') { $oe['autoOrder'] = $true }
		elseif ($oeAuto -eq 'false') { $oe['autoOrder'] = $false }
		$orderExpressionList += ,$oe
	}
	if ($orderExpressionList.Count -eq 1) {
		$orderExpression = $orderExpressionList[0]
	} elseif ($orderExpressionList.Count -gt 1) {
		$orderExpression = $orderExpressionList
	}
	$dataPath = Get-Text $fieldNode "r:dataPath"
	$fieldName = Get-Text $fieldNode "r:field"
	$titleNode = $fieldNode.SelectSingleNode("r:title", $ns)
	$title = Get-MLText $titleNode
	$valueTypeNode = $fieldNode.SelectSingleNode("r:valueType", $ns)
	$typeShort = Get-ValueTypeShorthand $valueTypeNode
	$roleInfo = Get-RoleInfo $fieldNode.SelectSingleNode("r:role", $ns) "$loc/role"
	$roleTokens = if ($roleInfo) { $roleInfo.tokens } else { @() }
	$roleExtras = if ($roleInfo) { $roleInfo.extras } else { [ordered]@{} }
	$roleRendered = Render-Role -tokens $roleTokens -extras $roleExtras
	$restrictTokens = Get-RestrictionTokens $fieldNode.SelectSingleNode("r:useRestriction", $ns)
	# <attributeUseRestriction> — те же 4 флага, но для атрибутов ссылочного поля
	$attrRestrictTokens = Get-RestrictionTokens $fieldNode.SelectSingleNode("r:attributeUseRestriction", $ns)
	$appNode = $fieldNode.SelectSingleNode("r:appearance", $ns)
	$appearance = Get-AppearanceDict $appNode
	$presExpr = Get-Text $fieldNode "r:presentationExpression"
	# availableValues on dataset field
	$avNodes = $fieldNode.SelectNodes("r:availableValue", $ns)
	$availableValues = @()
	foreach ($av in $avNodes) {
		$avVN = $av.SelectSingleNode("r:value", $ns)
		$avPN = $av.SelectSingleNode("r:presentation", $ns)
		$avEntry = [ordered]@{}
		if ($avVN) {
			$avType = Get-LocalXsiType $avVN
			$avText = $avVN.InnerText
			if ($avType -eq 'boolean') { $avEntry['value'] = ($avText -eq 'true') }
			elseif ($avType -eq 'decimal') {
				if ($avText -match '^-?\d+$') { $avEntry['value'] = [int]$avText }
				else { $avEntry['value'] = [double]$avText }
			}
			else { $avEntry['value'] = $avText }
		}
		if ($avPN) {
			$avPres = Get-MLText $avPN
			if ($avPres) { $avEntry['presentation'] = $avPres }
		}
		$availableValues += $avEntry
	}

	# Можно ли роль положить в shorthand-строку?
	$roleInString = $roleRendered -and $roleRendered.isString
	$needsObject = $title -or $appearance -or $presExpr -or ($typeShort -is [array]) -or ($roleRendered -and -not $roleInString) -or $orderExpression -or $inputParameters -or ($availableValues.Count -gt 0) -or ($attrRestrictTokens -and $attrRestrictTokens.Count -gt 0)

	if (-not $needsObject) {
		# shorthand: "Name: type @role K=V #restrict"
		$s = $fieldName
		if ($typeShort) { $s = "$fieldName`: $typeShort" }
		if ($roleInString) {
			# Если значение — одиночный флаг (без @ и без =) — добавляем как @flag.
			# Если уже содержит @ или K=V — добавляем как есть.
			$rv = $roleRendered.value
			if ($rv -match '@' -or $rv -match '=' -or $rv -match '\s') {
				$s += ' ' + $rv
			} else {
				$s += " @$rv"
			}
		}
		if ($restrictTokens) { $s += ' ' + ($restrictTokens -join ' ') }
		# dataPath ≠ field — fall back to object form
		if (-not ($dataPath -and $dataPath -ne $fieldName)) {
			return $s
		}
	}

	$obj = [ordered]@{ field = $fieldName }
	if ($dataPath -and $dataPath -ne $fieldName) { $obj['dataPath'] = $dataPath }
	if ($title) { $obj['title'] = $title }
	if ($typeShort) { $obj['type'] = $typeShort }
	if ($roleRendered) { $obj['role'] = $roleRendered.value }
	if ($orderExpression) { $obj['orderExpression'] = $orderExpression }
	if ($inputParameters) { $obj['inputParameters'] = $inputParameters }
	if ($restrictTokens) { $obj['restrict'] = ($restrictTokens | ForEach-Object { $_ -replace '^#','' }) }
	if ($attrRestrictTokens -and $attrRestrictTokens.Count -gt 0) {
		$obj['attrRestrict'] = ($attrRestrictTokens | ForEach-Object { $_ -replace '^#','' })
	}
	if ($presExpr) { $obj['presentationExpression'] = $presExpr }
	if ($availableValues.Count -gt 0) { $obj['availableValues'] = $availableValues }
	if ($appearance) { $obj['appearance'] = $appearance }
	return $obj
}

# Build calculatedField → shorthand string or object form
function Build-CalcField {
	param($cfNode, [string]$loc)
	$dataPath = Get-Text $cfNode "r:dataPath"
	$expression = Get-Text $cfNode "r:expression"
	$titleNode = $cfNode.SelectSingleNode("r:title", $ns)
	$title = Get-MLText $titleNode
	$valueTypeNode = $cfNode.SelectSingleNode("r:valueType", $ns)
	$typeShort = Get-ValueTypeShorthand $valueTypeNode
	$restrictTokens = Get-RestrictionTokens $cfNode.SelectSingleNode("r:useRestriction", $ns)
	$appNode = $cfNode.SelectSingleNode("r:appearance", $ns)
	$appearance = Get-AppearanceDict $appNode

	# multilingual title (non-ru) → object form
	$titleNeedsObject = ($title -is [System.Collections.IDictionary]) -or ($typeShort -is [array])
	$needsObject = $appearance -or $titleNeedsObject

	if (-not $needsObject) {
		# shorthand: "Name [Title]: type = expression #restrict"
		$s = $dataPath
		if ($title) { $s += " [$title]" }
		if ($typeShort) { $s += ": $typeShort" }
		if ($expression) { $s += " = $expression" }
		if ($restrictTokens) { $s += ' ' + ($restrictTokens -join ' ') }
		return $s
	}

	$obj = [ordered]@{ name = $dataPath }
	if ($title) { $obj['title'] = $title }
	if ($typeShort) { $obj['type'] = $typeShort }
	if ($expression) { $obj['expression'] = $expression }
	if ($restrictTokens) { $obj['restrict'] = ($restrictTokens | ForEach-Object { $_ -replace '^#','' }) }
	if ($appearance) { $obj['appearance'] = $appearance }
	return $obj
}

# Build totalField → shorthand or object form
function Build-TotalField {
	param($tfNode)
	$dataPath = Get-Text $tfNode "r:dataPath"
	$expression = Get-Text $tfNode "r:expression"
	$groupNodes = $tfNode.SelectNodes("r:group", $ns)
	$hasGroups = $groupNodes -and $groupNodes.Count -gt 0

	# Object form — только если есть group или expression многострочный
	if ($hasGroups -or ($expression -match "[`r`n]")) {
		$obj = [ordered]@{ dataPath = $dataPath; expression = $expression }
		if ($hasGroups) {
			$groups = @()
			foreach ($g in $groupNodes) { $groups += $g.InnerText }
			$obj['group'] = $groups
		}
		return $obj
	}

	# Shorthand: "Func(dataPath)" → "name: Func" (агрегат с очевидным аргументом)
	if ($expression -match '^(\w+)\((\w+)\)$' -and $matches[2] -eq $dataPath) {
		return "$dataPath`: $($matches[1])"
	}
	# Любой другой однострочный expression → "name: expression" (compile берёт всё после ":" как expression)
	return "$dataPath`: $expression"
}

# Detect StandardPeriod variant from <value> node
function Get-StandardPeriodVariant {
	param($valueNode)
	if (-not $valueNode) { return $null }
	$variant = Get-Text $valueNode "v8:variant"
	if ($variant) { return $variant }
	return $null
}

# Build parameter → shorthand or object form
function Build-Parameter {
	param($pNode, [string]$loc)
	$name = Get-Text $pNode "r:name"
	$titleNode = $pNode.SelectSingleNode("r:title", $ns)
	$title = Get-MLText $titleNode
	$valueTypeNode = $pNode.SelectSingleNode("r:valueType", $ns)
	$typeShort = Get-ValueTypeShorthand $valueTypeNode

	# value — может быть несколько (valueListAllowed: список значений по умолчанию).
	$valueNodes = $pNode.SelectNodes("r:value", $ns)
	$valueDisplay = $null
	$valueIsNil = $false
	if ($valueNodes.Count -gt 1) {
		# Multi-value (список значений по умолчанию для параметра-списка)
		$valueArr = @()
		foreach ($vn in $valueNodes) {
			$vt = Get-LocalXsiType $vn
			$vTxt = $vn.InnerText
			if ($vt -eq 'boolean') { $valueArr += ($vTxt -eq 'true') }
			elseif ($vt -eq 'decimal') {
				if ($vTxt -match '^-?\d+$') { $valueArr += [int]$vTxt }
				else { $valueArr += [double]$vTxt }
			} else { $valueArr += $vTxt }
		}
		$valueDisplay = $valueArr
	}
	elseif ($valueNodes.Count -eq 1) {
		$valueNode = $valueNodes[0]
		$nil = $valueNode.GetAttribute("nil", $NS_XSI)
		if ($nil -eq 'true') { $valueIsNil = $true }
		else {
			$vType = Get-LocalXsiType $valueNode
			if ($vType -eq 'StandardPeriod') {
				$variant = Get-Text $valueNode "v8:variant"
				$sd = Get-Text $valueNode "v8:startDate"
				$ed = Get-Text $valueNode "v8:endDate"
				$hasExplicitDates = ($sd -and $sd -ne '0001-01-01T00:00:00') -or ($ed -and $ed -ne '0001-01-01T00:00:00')
				if ($hasExplicitDates) {
					# Custom с явными датами → object form {variant, startDate, endDate}
					$valueDisplay = [ordered]@{ variant = $variant }
					if ($sd) { $valueDisplay['startDate'] = $sd }
					if ($ed) { $valueDisplay['endDate'] = $ed }
				} elseif ($variant -and $variant -ne 'Custom') {
					$valueDisplay = $variant
				}
				# Custom без явных дат — valueDisplay = null, compile подставит 0001-01-01.
			} elseif ($vType -eq 'DesignTimeValue') {
				$valueDisplay = $valueNode.InnerText
			} elseif ($vType -eq 'LocalStringType') {
				$valueDisplay = Get-MLText $valueNode
			} else {
				$txt = $valueNode.InnerText
				if ($txt) { $valueDisplay = $txt }
			}
		}
	}

	$valueListAllowed = (Get-Text $pNode "r:valueListAllowed") -eq 'true'
	$availableAsField = Get-Text $pNode "r:availableAsField"
	$denyIncomplete = (Get-Text $pNode "r:denyIncompleteValues") -eq 'true'
	$useAttr = Get-Text $pNode "r:use"
	$useRestriction = (Get-Text $pNode "r:useRestriction") -eq 'true'
	$expression = Get-Text $pNode "r:expression"
	$inputParameters = Read-InputParameters -parentNode $pNode
	# hidden — combo: availableAsField=false + useRestriction=true (как эмитит compile @hidden)
	$notAField = ($availableAsField -eq 'false')
	$hidden = $notAField -and $useRestriction

	# availableValues
	$avNodes = $pNode.SelectNodes("r:availableValue", $ns)
	$availableValues = @()
	foreach ($av in $avNodes) {
		$avValNode = $av.SelectSingleNode("r:value", $ns)
		$avPresNode = $av.SelectSingleNode("r:presentation", $ns)
		$avEntry = [ordered]@{}
		if ($avValNode) {
			$avType = Get-LocalXsiType $avValNode
			$avText = $avValNode.InnerText
			if ($avType -eq 'boolean') { $avEntry['value'] = ($avText -eq 'true') }
			elseif ($avType -eq 'decimal') {
				if ($avText -match '^-?\d+$') { $avEntry['value'] = [int]$avText }
				else { $avEntry['value'] = [double]$avText }
			}
			else { $avEntry['value'] = $avText }
		}
		if ($avPresNode) { $avEntry['presentation'] = Get-MLText $avPresNode }
		$availableValues += $avEntry
	}

	$flags = @()

	$result = [ordered]@{
		name = $name
		title = $title
		typeShort = $typeShort
		valueDisplay = $valueDisplay
		valueIsNil = $valueIsNil
		valueListAllowed = $valueListAllowed
		hidden = $hidden
		notAField = ($notAField -and -not $hidden)  # availableAsField=false без useRestriction
		denyIncomplete = $denyIncomplete
		useAttr = $useAttr
		useRestriction = $useRestriction
		expression = $expression
		availableValues = $availableValues
		inputParameters = $inputParameters
	}
	return $result
}

# Render parameter (after autoDates folding) → shorthand or object form
function Render-Parameter {
	param($p)
	$name = $p.name
	$title = $p.title
	$typeShort = $p.typeShort
	$valueDisplay = $p.valueDisplay
	$valueIsNil = $p.valueIsNil
	$flags = @()
	if ($p.autoDates)          { $flags += '@autoDates' }
	if ($p.valueListAllowed)   { $flags += '@valueList' }
	if ($p.hidden)             { $flags += '@hidden' }

	$titleNeedsObject = ($title -is [System.Collections.IDictionary])
	$typeIsArray = ($typeShort -is [array])
	$valueIsDict = ($valueDisplay -is [System.Collections.IDictionary])

	# Object form needed if: availableValues, multilingual title, composite type,
	# explicit denyIncomplete/use without @autoDates, useRestriction without autoDates, expression set
	$needsObject = $false
	if ($p.availableValues -and $p.availableValues.Count -gt 0) { $needsObject = $true }
	if ($p.inputParameters) { $needsObject = $true }
	if ($titleNeedsObject) { $needsObject = $true }
	if ($typeIsArray) { $needsObject = $true }
	if ($valueIsDict) { $needsObject = $true }
	if (-not $p.autoDates) {
		# @autoDates implies use=Always + denyIncomplete=true defaults — only object form if NOT autoDates
		if ($p.denyIncomplete) { $needsObject = $true }
		if ($p.useAttr) { $needsObject = $true }
	}
	# useRestriction=true non-hidden non-autoDates требует object form — иначе shorthand
	# теряет этот атрибут (compile эмитит default useRestriction=false).
	if ($p.useRestriction -and -not $p.hidden -and -not $p.autoDates) { $needsObject = $true }
	if ($p.expression) { $needsObject = $true }
	if ($p.notAField) { $needsObject = $true }

	# valueIsNil на non-композитном типе требует object form, чтобы compile
	# знал что вместо xs:string/xs:decimal-default нужно эмитить xsi:nil="true".
	# Для ref-типов compile в любом случае эмитит nil, шорткод покрывает.
	$refTypePattern = '^(Catalog|Document|Enum|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan|CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|InformationRegisterRef|ExchangePlanRef|AnyRef)'
	$typeIsRef = $false
	if ($typeShort -is [string] -and $typeShort -match $refTypePattern) { $typeIsRef = $true }
	$nilNeedsObject = $valueIsNil -and -not $typeIsRef -and $typeShort -and -not ($typeShort -is [array])
	if ($nilNeedsObject) { $needsObject = $true }

	if (-not $needsObject) {
		$s = $name
		if ($title) { $s += " [$title]" }
		if ($typeShort) { $s += ": $typeShort" }
		if (-not $valueIsNil -and $null -ne $valueDisplay -and $valueDisplay -ne '') { $s += " = $valueDisplay" }
		if ($flags) { $s += ' ' + ($flags -join ' ') }
		return $s
	}

	$obj = [ordered]@{ name = $name }
	if ($title) { $obj['title'] = $title }
	if ($typeShort) { $obj['type'] = $typeShort }
	if (-not $valueIsNil -and $null -ne $valueDisplay -and $valueDisplay -ne '') { $obj['value'] = $valueDisplay }
	if ($nilNeedsObject) { $obj['nilValue'] = $true }
	if ($p.useAttr -and -not $p.autoDates) { $obj['use'] = $p.useAttr }
	if ($p.denyIncomplete -and -not $p.autoDates) { $obj['denyIncompleteValues'] = $true }
	if ($p.hidden) { $obj['hidden'] = $true }
	if ($p.notAField) { $obj['availableAsField'] = $false }
	if ($p.valueListAllowed) { $obj['valueListAllowed'] = $true }
	if ($p.autoDates) { $obj['autoDates'] = $true }
	if ($p.expression) { $obj['expression'] = $p.expression }
	# useRestriction явно эмитится только если: true И НЕ покрыт hidden/autoDates (compile auto-emit).
	if ($p.useRestriction -and -not $p.hidden -and -not $p.autoDates) { $obj['useRestriction'] = $true }
	if ($p.availableValues -and $p.availableValues.Count -gt 0) { $obj['availableValues'] = $p.availableValues }
	if ($p.inputParameters) { $obj['inputParameters'] = $p.inputParameters }
	return $obj
}

# --- 3b. Built-in style presets (preset-shape: 11 полей) ---

# Имена 5 встроенных стилей. Совпадает с compile presets.
$script:builtinPresetNames = @('none','data','header','subheader','total')

# Преобразовать compile-style preset hashtable в наш canonical preset shape.
# Canonical поля: font, fontSize, bold, italic, hAlign, vAlign, wrap, bgColor, textColor, borderColor, borders.
$script:builtinPresets = @{
	'none' = @{
		font = $null; fontSize = $null; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = $null; textColor = $null
		borderColor = $null; borders = $false
	}
	'data' = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = 'style:ReportGroup1BackColor'; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	'header' = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = 'Center'; vAlign = $null; wrap = $true
		bgColor = 'style:ReportHeaderBackColor'; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	'subheader' = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = 'Center'; vAlign = $null; wrap = $true
		bgColor = $null; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	'total' = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = $null; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
}

# effectivePresets = built-in + любые user-переопределения, загруженные из skd-styles.json
$script:effectivePresets = @{}
foreach ($k in $script:builtinPresets.Keys) {
	$copy = @{}
	foreach ($f in $script:builtinPresets[$k].Keys) { $copy[$f] = $script:builtinPresets[$k][$f] }
	$script:effectivePresets[$k] = $copy
}

# existingUserPresetsRaw — копия загруженного skd-styles.json (PSCustomObject) для merge при записи.
$script:existingUserPresetsRaw = $null

# Аккумулятор внешних SQL-файлов для записи рядом с outputPath: @{name = "filename.sql"; text = "...sql text..."}
$script:queryFilesAccumulator = @()
$script:queryFileNamesUsed = @{}

# Если запрос ≥3 строк и есть outputPath — вынести в отдельный
# `<outputBasename>-<datasetName>.sql` (префикс защищает от коллизий имён при batch-decompile).
# Иначе — оставить inline.
function Maybe-ExternalizeQuery {
	param([string]$queryText, [string]$datasetName)
	if (-not $queryText) { return $queryText }
	if (-not $script:outputDir) { return $queryText }
	# Считаем строки — \r\n или \n
	$lineCount = ([regex]::Matches($queryText, "`n")).Count + 1
	if ($lineCount -lt 3) { return $queryText }
	# Уникализация имени файла: prefix = basename outputPath (без расширения)
	$safeDs = ($datasetName -replace '[^\w\-]', '_')
	if (-not $safeDs) { $safeDs = 'query' }
	$prefix = if ($script:outputBasename) { "$($script:outputBasename)-" } else { '' }
	$fileName = "$prefix$safeDs.sql"
	$suffix = 1
	while ($script:queryFileNamesUsed.ContainsKey($fileName)) {
		$suffix++
		$fileName = "$prefix$safeDs`_$suffix.sql"
	}
	$script:queryFileNamesUsed[$fileName] = $true
	$script:queryFilesAccumulator += [ordered]@{ fileName = $fileName; text = $queryText }
	return "@$fileName"
}

# Записать все накопленные .sql файлы рядом с outputPath.
function Save-QueryFiles {
	if ($script:queryFilesAccumulator.Count -eq 0) { return }
	if (-not $script:outputDir) { return }
	$enc = New-Object System.Text.UTF8Encoding($false)
	foreach ($qf in $script:queryFilesAccumulator) {
		$path = Join-Path $script:outputDir $qf.fileName
		[System.IO.File]::WriteAllText($path, $qf.text, $enc)
	}
	[Console]::Error.WriteLine("Saved $($script:queryFilesAccumulator.Count) external query file(s)")
}

# customStylesAccumulator — новые customN, накопленные в текущем прогоне, для записи в skd-styles.json.
$script:customStylesAccumulator = [ordered]@{}

# Счётчик customN
$script:customStyleCounter = 0

# Normalize color value: 'd8p1:ReportHeaderBackColor' → 'style:ReportHeaderBackColor'
function Normalize-Color {
	param($valNode)
	if (-not $valNode) { return $null }
	$txt = $valNode.InnerText
	# Префикс xsi:type или value — резолвим в URI и выбираем DSL-префикс.
	if ($txt -match '^([^:]+):(.+)$') {
		$pfx = $matches[1]
		$name = $matches[2]
		$uri = $valNode.GetNamespaceOfPrefix($pfx)
		switch ($uri) {
			'http://v8.1c.ru/8.1/data/ui/style'          { return 'style:' + $name }
			'http://v8.1c.ru/8.1/data/ui/colors/web'     { return 'web:' + $name }
			'http://v8.1c.ru/8.1/data/ui/colors/windows' { return 'win:' + $name }
		}
	}
	return $txt
}

# Build preset hashtable (11 полей) из <dcsat:appearance>.
# Возвращает $null если у ячейки нет ни одного стилевого атрибута (только per-cell).
function Extract-CellPreset {
	param($appNode)
	if (-not $appNode) { return $null }
	$preset = @{
		font = $null; fontSize = $null; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = $null; textColor = $null
		borderColor = $null; borders = $false
	}
	$hasAnyStyle = $false
	foreach ($it in $appNode.SelectNodes("dcscor:item", $ns)) {
		$pName = Get-Text $it "dcscor:parameter"
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $pName) { continue }
		if ($pName -in @('МинимальнаяШирина','МаксимальнаяШирина','МинимальнаяВысота','ОбъединятьПоВертикали','ОбъединятьПоГоризонтали','Расшифровка')) { continue }
		switch ($pName) {
			'Шрифт' {
				if ($val) {
					$preset.font = $val.GetAttribute("faceName")
					$h = $val.GetAttribute("height")
					if ($h) { $preset.fontSize = [int]$h }
					$preset.bold = ($val.GetAttribute("bold") -eq 'true')
					$preset.italic = ($val.GetAttribute("italic") -eq 'true')
					$hasAnyStyle = $true
				}
			}
			'ЦветФона'    { if ($val) { $preset.bgColor = Normalize-Color $val; $hasAnyStyle = $true } }
			'ЦветТекста'  { if ($val) { $preset.textColor = Normalize-Color $val; $hasAnyStyle = $true } }
			'ЦветГраницы' { if ($val) { $preset.borderColor = Normalize-Color $val; $hasAnyStyle = $true } }
			'СтильГраницы' {
				# borders = true если есть sub-items для 4 сторон со style=Solid
				$sidesFound = 0
				foreach ($sub in $it.SelectNodes("dcscor:item", $ns)) {
					$subName = Get-Text $sub "dcscor:parameter"
					if ($subName -match '^СтильГраницы\.(Слева|Сверху|Справа|Снизу)$') { $sidesFound++ }
				}
				if ($sidesFound -gt 0) { $preset.borders = $true; $hasAnyStyle = $true }
			}
			'ГоризонтальноеПоложение' { if ($val) { $preset.hAlign = $val.InnerText; $hasAnyStyle = $true } }
			'ВертикальноеПоложение'   { if ($val) { $preset.vAlign = $val.InnerText; $hasAnyStyle = $true } }
			'Размещение' { if ($val -and $val.InnerText -eq 'Wrap') { $preset.wrap = $true; $hasAnyStyle = $true } }
		}
	}
	if (-not $hasAnyStyle) { return $null }
	return $preset
}

# Deep-equality двух preset hashtables (11 полей).
function Compare-Preset {
	param($a, $b)
	foreach ($key in @('font','fontSize','bold','italic','hAlign','vAlign','wrap','bgColor','textColor','borderColor','borders')) {
		if ($a[$key] -ne $b[$key]) { return $false }
	}
	return $true
}

# Найти имя preset'а в effectivePresets по shape. Возвращает имя или $null.
function Match-PresetByShape {
	param($cellPreset)
	if (-not $cellPreset) { return $null }
	foreach ($name in $script:effectivePresets.Keys) {
		if (Compare-Preset $cellPreset $script:effectivePresets[$name]) { return $name }
	}
	return $null
}

# Аллокация customN для нового, не-matched preset'а. Регистрирует в effectivePresets+accumulator.
function Allocate-CustomStyle {
	param($cellPreset)
	# Поиск свободного customN
	$script:customStyleCounter++
	$name = "custom$($script:customStyleCounter)"
	while ($script:effectivePresets.ContainsKey($name)) {
		$script:customStyleCounter++
		$name = "custom$($script:customStyleCounter)"
	}
	$script:effectivePresets[$name] = $cellPreset
	$script:customStylesAccumulator[$name] = $cellPreset
	return $name
}

# Загрузка skd-styles.json рядом с outputPath (если есть) и наслоение на effectivePresets.
function Load-UserStyles {
	param([string]$dirPath)
	if (-not $dirPath) { return }
	$stylesPath = Join-Path $dirPath 'skd-styles.json'
	if (-not (Test-Path $stylesPath)) { return }
	$raw = Get-Content -Raw -Encoding UTF8 $stylesPath | ConvertFrom-Json
	$script:existingUserPresetsRaw = $raw
	foreach ($prop in $raw.PSObject.Properties) {
		# Compile-логика: data defaults → built-in if name match → user keys
		$preset = @{}
		foreach ($k in $script:builtinPresets['data'].Keys) { $preset[$k] = $script:builtinPresets['data'][$k] }
		if ($script:builtinPresets.ContainsKey($prop.Name)) {
			foreach ($k in $script:builtinPresets[$prop.Name].Keys) { $preset[$k] = $script:builtinPresets[$prop.Name][$k] }
		}
		foreach ($up in $prop.Value.PSObject.Properties) {
			$preset[$up.Name] = $up.Value
		}
		$script:effectivePresets[$prop.Name] = $preset
	}
}

# Запись skd-styles.json: preserved existing user presets + новые customN.
function Save-UserStyles {
	param([string]$dirPath)
	if (-not $dirPath) { return }
	if ($script:customStylesAccumulator.Count -eq 0 -and -not $script:existingUserPresetsRaw) { return }
	$stylesPath = Join-Path $dirPath 'skd-styles.json'
	$out = [ordered]@{}
	# Сначала existing (preserve порядок и значения)
	if ($script:existingUserPresetsRaw) {
		foreach ($prop in $script:existingUserPresetsRaw.PSObject.Properties) {
			$out[$prop.Name] = $prop.Value
		}
	}
	# Потом новые customN
	foreach ($name in $script:customStylesAccumulator.Keys) {
		if ($out.Contains($name)) { continue }
		$out[$name] = $script:customStylesAccumulator[$name]
	}
	if ($out.Count -eq 0) { return }
	$json = ConvertTo-CompactJson -obj $out
	$enc = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($stylesPath, $json, $enc)
	[Console]::Error.WriteLine("Saved skd-styles.json (custom styles: $($script:customStylesAccumulator.Count))")
}

# Extract per-cell width/minHeight/merge from appearance.
function Get-CellPerCellAttrs {
	param($appNode)
	# drilldown — суффикс X из имени Расшифровка_X (только shortcut form B).
	# drilldownTarget — полное имя target-параметра как есть (любая форма).
	$attrs = @{ width = $null; height = $null; mergeV = $false; mergeH = $false; drilldown = $null; drilldownTarget = $null }
	if (-not $appNode) { return $attrs }
	foreach ($it in $appNode.SelectNodes("dcscor:item", $ns)) {
		$pName = Get-Text $it "dcscor:parameter"
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $pName) { continue }
		switch ($pName) {
			'МинимальнаяШирина'        { if ($val) { $attrs.width = $val.InnerText } }
			'МинимальнаяВысота'        { if ($val) { $attrs.height = $val.InnerText } }
			'ОбъединятьПоВертикали'    { if ($val -and $val.InnerText -eq 'true') { $attrs.mergeV = $true } }
			'ОбъединятьПоГоризонтали'  { if ($val -and $val.InnerText -eq 'true') { $attrs.mergeH = $true } }
			'Расшифровка'              {
				# value xsi:type=dcscor:Parameter pointing to <X> или Расшифровка_<X>
				if ($val) {
					$paramRef = $val.InnerText
					$attrs.drilldownTarget = $paramRef
					if ($paramRef -match '^Расшифровка_(.+)$') { $attrs.drilldown = $matches[1] }
				}
			}
		}
	}
	return $attrs
}

# Extract cell content: string text, "{ParamName}", "|", ">", or $null
function Get-CellContent {
	param($cellNode, $perCellAttrs)
	# Check merge flags first — empty cells with these flags are "|" or ">"
	if ($perCellAttrs.mergeV) { return '|' }
	if ($perCellAttrs.mergeH) { return '>' }

	$item = $cellNode.SelectSingleNode("dcsat:item", $ns)
	if (-not $item) { return $null }
	$itemType = Get-LocalXsiType $item
	$valNode = $item.SelectSingleNode("dcsat:value", $ns)
	if (-not $valNode) { return $null }
	$valType = Get-LocalXsiType $valNode

	if ($itemType -eq 'Field' -and $valType -eq 'Parameter') {
		return '{' + $valNode.InnerText + '}'
	}
	if ($valType -eq 'LocalStringType') {
		$text = Get-MLText $valNode
		if ($text -is [System.Collections.IDictionary]) {
			# multilang in template cell — keep as-is; emit via object form (Ring 2 candidate)
			return $text
		}
		return $text
	}
	# Fallback: take inner text
	return $valNode.InnerText
}

# Build template parameter entry. Returns hashtable with `name` + `expression` (+ optional `drilldown`)
function Build-TemplateParameter {
	param($pNode)
	$pType = Get-LocalXsiType $pNode
	$obj = [ordered]@{}
	$obj['name'] = Get-Text $pNode "dcsat:name"
	if ($pType -eq 'ExpressionAreaTemplateParameter') {
		$obj['expression'] = Get-Text $pNode "dcsat:expression"
	} elseif ($pType -eq 'DetailsAreaTemplateParameter') {
		# Marker — handled by drilldown folding logic in Build-Template
		$obj['__details__'] = $true
		$obj['expression'] = Get-Text $pNode "dcsat:expression"
	}
	return $obj
}

# Build template entry from <template> node
function Build-Template {
	param($templateNode, [string]$loc)
	$tmplObj = [ordered]@{ name = Get-Text $templateNode "r:name" }
	$inner = $templateNode.SelectSingleNode("r:template", $ns)
	if (-not $inner) { return $tmplObj }

	# Walk rows
	$rowNodes = $inner.SelectNodes("dcsat:item[@xsi:type='dcsat:TableRow']", $ns)
	# fallback: any dcsat:item (in case xsi prefix differs)
	if ($rowNodes.Count -eq 0) {
		$allItems = $inner.SelectNodes("dcsat:item", $ns)
		$rowNodes = @()
		foreach ($n in $allItems) { if ((Get-LocalXsiType $n) -eq 'TableRow') { $rowNodes += $n } }
	}

	$rows = @()
	$widths = $null
	$minHeight = $null
	$cellStyleMap = @{}        # "r,c" → имя стиля для конкретной ячейки (null для merge/no-style)
	$cellDrilldownMap = @{}    # "r,c" → полное имя drilldown-target (для cell wrap в object-form)
	$hasAnyStyledCell = $false
	$drilldownByParam = @{}    # param name → field name (X from Расшифровка_X) — для form B fold

	$rowIdx = 0
	foreach ($rowNode in $rowNodes) {
		$cells = @()
		$cellNodes = $rowNode.SelectNodes("dcsat:tableCell", $ns)
		$colIdx = 0
		# First-row collects widths
		$rowWidths = @()
		foreach ($cellNode in $cellNodes) {
			$appNode = $cellNode.SelectSingleNode("dcsat:appearance", $ns)
			$perCell = Get-CellPerCellAttrs $appNode
			$content = Get-CellContent $cellNode $perCell

			# Style detection (skip merge cells)
			if ($appNode -and -not $perCell.mergeV -and -not $perCell.mergeH) {
				$cellPreset = Extract-CellPreset $appNode
				if ($null -ne $cellPreset) {
					$matched = Match-PresetByShape $cellPreset
					if ($null -eq $matched) {
						$matched = Allocate-CustomStyle $cellPreset
					}
					$cellStyleMap["$rowIdx,$colIdx"] = $matched
					$hasAnyStyledCell = $true
				}
			}

			# Drilldown attachment — для shortcut form B (Расшифровка_X) кладём в drilldownByParam.
			# Полное имя target сохраняем в cellDrilldownMap для последующего разрешения:
			# если target = "Расшифровка_X" и X совпадает с именем параметра ячейки {X} —
			# это shortcut и cell остаётся строкой; иначе cell wrap в {value, drilldown}.
			if ($content -match '^\{(.+)\}$' -and $perCell.drilldown) {
				$drilldownByParam[$matches[1]] = $perCell.drilldown
			}
			if ($perCell.drilldownTarget) {
				$cellDrilldownMap["$rowIdx,$colIdx"] = $perCell.drilldownTarget
			}

			# First row collects widths from any non-merge cell
			if ($rowIdx -eq 0 -and $perCell.width) { $rowWidths += $perCell.width }
			# First row collects minHeight from the first non-empty cell
			if ($rowIdx -eq 0 -and $colIdx -eq 0 -and $perCell.height) { $minHeight = $perCell.height }

			$cells += $content
			$colIdx++
		}
		if ($rowIdx -eq 0 -and $rowWidths.Count -gt 0) { $widths = $rowWidths }
		$rows += ,$cells
		$rowIdx++
	}

	# Template default = наиболее частый стиль ячеек.
	$templateDefault = $null
	if ($hasAnyStyledCell) {
		$counts = @{}
		foreach ($k in $cellStyleMap.Keys) {
			$name = $cellStyleMap[$k]
			if (-not $counts.ContainsKey($name)) { $counts[$name] = 0 }
			$counts[$name]++
		}
		$maxCount = 0
		foreach ($name in $counts.Keys) {
			if ($counts[$name] -gt $maxCount) {
				$maxCount = $counts[$name]
				$templateDefault = $name
			}
		}
	}

	# Если есть ячейки со стилем, отличным от template default — оборачиваем их в object form.
	if ($templateDefault) {
		$rowsOut = @()
		for ($r = 0; $r -lt $rows.Count; $r++) {
			$newRow = @()
			for ($c = 0; $c -lt $rows[$r].Count; $c++) {
				$key = "$r,$c"
				if ($cellStyleMap.ContainsKey($key) -and $cellStyleMap[$key] -ne $templateDefault) {
					$newRow += [ordered]@{ value = $rows[$r][$c]; style = $cellStyleMap[$key] }
				} else {
					$newRow += $rows[$r][$c]
				}
			}
			$rowsOut += ,$newRow
		}
		$rows = $rowsOut
	}

	# Template parameters (and drilldown folding)
	$paramNodes = $templateNode.SelectNodes("r:parameter", $ns)
	$exprParams = [ordered]@{}
	$detailsByName = [ordered]@{}      # name → @{ field, expression, action }
	foreach ($pn in $paramNodes) {
		$pType = Get-LocalXsiType $pn
		$pName = Get-Text $pn "dcsat:name"
		if ($pType -eq 'ExpressionAreaTemplateParameter') {
			$exprParams[$pName] = Get-Text $pn "dcsat:expression"
		} elseif ($pType -eq 'DetailsAreaTemplateParameter') {
			$feNode = $pn.SelectSingleNode("dcsat:fieldExpression", $ns)
			$detailsByName[$pName] = @{
				field      = if ($feNode) { Get-Text $feNode "dcsat:field" } else { '' }
				expression = if ($feNode) { Get-Text $feNode "dcsat:expression" } else { '' }
				action     = Get-Text $pn "dcsat:mainAction"
			}
		}
	}

	# Сворачиваем shortcut form B: каждый exprParam X с drilldownByParam[X]=Y проверяем —
	# если detailsByName["Расшифровка_Y"] существует и имеет canonical shape
	# (field=ИмяРесурса, expression="Y", action=DrillDown) → fold X.drilldown="Y" и mark detail folded.
	$foldedDetailNames = @{}
	foreach ($pname in @($drilldownByParam.Keys)) {
		$yVal = $drilldownByParam[$pname]
		$detailName = "Расшифровка_$yVal"
		if ($detailsByName.Contains($detailName)) {
			$d = $detailsByName[$detailName]
			$expectedExpr = "`"$yVal`""
			if ($d.field -eq 'ИмяРесурса' -and $d.expression -eq $expectedExpr -and $d.action -eq 'DrillDown') {
				$foldedDetailNames[$detailName] = $true
			}
		}
	}

	$templateParams = @()
	foreach ($pname in $exprParams.Keys) {
		$entry = [ordered]@{ name = $pname; expression = $exprParams[$pname] }
		if ($drilldownByParam.ContainsKey($pname)) {
			$entry['drilldown'] = $drilldownByParam[$pname]
		}
		$templateParams += $entry
	}
	# Form C: details-параметры, не свёрнутые как shortcut → отдельная запись.
	foreach ($dname in $detailsByName.Keys) {
		if ($foldedDetailNames.ContainsKey($dname)) { continue }
		$d = $detailsByName[$dname]
		$entry = [ordered]@{ name = $dname }
		$ddObj = [ordered]@{ field = $d.field; expression = $d.expression }
		if ($d.action -and $d.action -ne 'DrillDown') { $ddObj['action'] = $d.action }
		$entry['drilldown'] = $ddObj
		$templateParams += $entry
	}

	# Cell wrapping: для ячеек, у которых drilldownTarget НЕ соответствует shortcut form B
	# (то есть target ≠ "Расшифровка_X" с X = имя параметра ячейки), оборачиваем в {value, drilldown}.
	# Уже обёрнутые style-ом ячейки получают drilldown как дополнительное поле.
	if ($cellDrilldownMap.Count -gt 0) {
		for ($r = 0; $r -lt $rows.Count; $r++) {
			$newRow = @()
			for ($c = 0; $c -lt $rows[$r].Count; $c++) {
				$cellVal = $rows[$r][$c]
				$key = "$r,$c"
				$target = $cellDrilldownMap[$key]
				# Распаковка inner value если cell уже обёрнута style-ом
				$innerVal = $cellVal
				$isWrapped = $false
				if ($cellVal -is [System.Collections.IDictionary] -or $cellVal -is [hashtable]) {
					if ($cellVal.Contains('value')) {
						$innerVal = $cellVal['value']
						$isWrapped = $true
					}
				}
				$needsWrap = $false
				if ($target -and ($innerVal -is [string]) -and ($innerVal -match '^\{(.+)\}$')) {
					$cellParam = $matches[1]
					# Shortcut form B: cell param имеет drilldown "Y", target == "Расшифровка_Y".
					$expectedShortcut = $null
					if ($drilldownByParam.ContainsKey($cellParam)) {
						$expectedShortcut = "Расшифровка_$($drilldownByParam[$cellParam])"
					}
					if ($target -ne $expectedShortcut) { $needsWrap = $true }
				}
				if ($needsWrap) {
					if ($isWrapped) {
						$cellVal['drilldown'] = $target
						$newRow += $cellVal
					} else {
						$newRow += [ordered]@{ value = $innerVal; drilldown = $target }
					}
				} else {
					$newRow += $cellVal
				}
			}
			$rows[$r] = $newRow
		}
	}

	# Decide output form
	if ($templateDefault) {
		$tmplObj['style'] = $templateDefault
	} elseif ($rows.Count -gt 0) {
		# Все ячейки без стилевых атрибутов — это шаблон "без стиля"
		$tmplObj['style'] = 'none'
	}
	if ($widths)    { $tmplObj['widths']    = $widths }
	if ($minHeight) { $tmplObj['minHeight'] = $minHeight }
	$tmplObj['rows'] = $rows
	if ($templateParams.Count -gt 0) { $tmplObj['parameters'] = $templateParams }

	return $tmplObj
}

# --- 3c. Filter / settings helpers ---

$script:filterOpMap = @{
	'Equal'='='; 'NotEqual'='<>'; 'Greater'='>'; 'GreaterOrEqual'='>=';
	'Less'='<'; 'LessOrEqual'='<='; 'InList'='in'; 'NotInList'='notIn';
	'InHierarchy'='inHierarchy'; 'InListByHierarchy'='inListByHierarchy';
	'Contains'='contains'; 'NotContains'='notContains';
	'BeginsWith'='beginsWith'; 'NotBeginsWith'='notBeginsWith';
	'Filled'='filled'; 'NotFilled'='notFilled'
}

# Render a filter value node to a shorthand-acceptable scalar string
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

# Same as Get-FilterValue, но дополнительно возвращает xsi:type значения,
# чтобы caller мог сохранить valueType (например, dcscor:Field — для field-to-field
# comparison). Format: @{ value = ...; type = '<xsi-type-or-null>' }.
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
	# Конвертация по типу — compile различает [bool]/[int]/[double] для auto-detect xsi:type.
	if ($vType -eq 'boolean') { return @{ value = ($txt -eq 'true'); type = $rawType } }
	if ($vType -eq 'decimal') {
		if ($txt -match '^-?\d+$') { return @{ value = [int]$txt; type = $rawType } }
		return @{ value = [double]$txt; type = $rawType }
	}
	return @{ value = $txt; type = $rawType }
}

# Convert filter item node → shorthand string or object form
function Build-FilterItem {
	param($itemNode, [string]$loc)
	$xtype = Get-LocalXsiType $itemNode
	if ($xtype -eq 'FilterItemGroup') {
		$gt = Get-Text $itemNode "dcsset:groupType"
		$groupName = switch ($gt) { 'OrGroup' { 'Or' } 'NotGroup' { 'Not' } default { 'And' } }
		$items = @()
		foreach ($c in $itemNode.SelectNodes("dcsset:item", $ns)) {
			$items += (Build-FilterItem -itemNode $c -loc "$loc/item")
		}
		$gObj = [ordered]@{ group = $groupName; items = $items }
		$gPresNode = $itemNode.SelectSingleNode("dcsset:presentation", $ns)
		if ($gPresNode) {
			$gPres = Get-MLText $gPresNode
			if (-not $gPres) { $gPres = $gPresNode.InnerText }
			if ($gPres) { $gObj['presentation'] = $gPres }
		}
		# viewMode: сохраняем даже Normal если node присутствует (для bit-perfect)
		$gVMNode = $itemNode.SelectSingleNode("dcsset:viewMode", $ns)
		if ($gVMNode) { $gObj['viewMode'] = $gVMNode.InnerText }
		$gUSID = Get-Text $itemNode "dcsset:userSettingID"
		if ($gUSID) { $gObj['userSettingID'] = 'auto' }
		$gUSPN = $itemNode.SelectSingleNode("dcsset:userSettingPresentation", $ns)
		if ($gUSPN) {
			$gUSP = Get-MLText $gUSPN
			if ($gUSP) { $gObj['userSettingPresentation'] = $gUSP }
		}
		return $gObj
	}
	if ($xtype -ne 'FilterItemComparison') {
		return (New-Sentinel -kind "FilterItemType:$xtype" -loc $loc -detail 'Неизвестный тип фильтра')
	}
	$leftNode = $itemNode.SelectSingleNode("dcsset:left", $ns)
	$field = if ($leftNode) { $leftNode.InnerText } else { $null }
	$ct = Get-Text $itemNode "dcsset:comparisonType"
	$op = $script:filterOpMap[$ct]
	if (-not $op) { $op = $ct }

	# Чтение <right>: один, несколько (InList multi-value) или ValueListType (пустой list-placeholder)
	$rightNodes = @($itemNode.SelectNodes("dcsset:right", $ns))
	$value = $null
	$valueIsArrayFlag = $false
	$valueTypeAttr = $null  # явный xsi:type, если не дефолтный (например, dcscor:Field)
	if ($rightNodes.Count -eq 1) {
		$rn = $rightNodes[0]
		if ((Get-LocalXsiType $rn) -eq 'ValueListType') {
			# Пустой список-placeholder для пользовательских настроек InList
			$value = @()
			$valueIsArrayFlag = $true
		} else {
			$vt = Get-FilterValueWithType $rn
			$value = $vt.value
			# Сохраняем тип только если он не дефолтный (auto-detect compile вернёт xs:*).
			# DesignTimeValue для значений вида "Перечисление.X.Y" / "Справочник.X.Y" /
			# "ПланСчетов.X.Y" и т.п. также auto-detect-ится — не сохраняем.
			$autoDetectsDTV = ($vt.type -eq 'dcscor:DesignTimeValue') -and `
				("$($vt.value)" -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.')
			if ($vt.type -and $vt.type -notmatch '^xs:' -and -not $autoDetectsDTV) {
				$valueTypeAttr = $vt.type
			}
		}
	} elseif ($rightNodes.Count -gt 1) {
		# Несколько значений → массив (InList с конкретными значениями)
		$arr = @()
		$rawTypes = @()
		foreach ($rn in $rightNodes) {
			$arr += (Get-FilterValue $rn)
			$rawTypes += $rn.GetAttribute("type", $NS_XSI)
		}
		$value = $arr
		$valueIsArrayFlag = $true
		# Сохраняем raw xsi:type если все одинаковые — compile будет использовать
		# как явный valueType (иначе авто-detect выберет DesignTimeValue для строк
		# "Перечисление.*", но оригинал может хранить как xs:string).
		# DesignTimeValue для значений-ref-литералов сам авто-detect-ится — не сохраняем.
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
	# viewMode: detect presence (даже = 'Normal') чтобы compile сделал bit-perfect
	$vmNode = $itemNode.SelectSingleNode("dcsset:viewMode", $ns)
	$viewMode = if ($vmNode) { $vmNode.InnerText } else { $null }
	$userPresNode = $itemNode.SelectSingleNode("dcsset:userSettingPresentation", $ns)
	# presentation (multilang or string) на самом filter item
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
	# Normal: явное присутствие <viewMode>Normal</viewMode> в XML сохраняется
	# через shorthand-флаг @normal (отсутствие — без флага). Это эквивалентно
	# object form "viewMode": "Normal" но компактнее.
	elseif ($viewMode -eq 'Normal') { $flags += '@normal' }

	# nullity ops have no value
	$noValueOps = @('filled','notFilled')

	# Переход в object form:
	# - userSettingPresentation,
	# - massivное value (multi-right или пустой ValueList),
	# - явный valueType (например, dcscor:Field — field-to-field comparison),
	# - presentation на item (multilang или просто текст)
	if ($userPresNode -or $valueIsArrayFlag -or $valueTypeAttr -or $fiPres) {
		$obj = [ordered]@{ field = $field; op = $op }
		if ($op -notin $noValueOps -and $null -ne $value) {
			if ($valueIsArrayFlag) {
				# Принудительный массив (для empty ValueList тоже)
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
		if ($userPresNode) { $obj['userSettingPresentation'] = Get-MLText $userPresNode }
		return $obj
	}

	# shorthand
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

# Recursive helper для одного элемента selection. Возвращает либо строку (имя поля / "Auto"),
# либо ordered hashtable ({field, title} / {folder, items: [...]} / sentinel).
function Build-SelectionItem {
	param($item, [string]$loc)
	$xt = Get-LocalXsiType $item
	# Implicit SelectedItemField: <item> без xsi:type, но с <field>
	if (-not $xt) {
		$fName = Get-Text $item "dcsset:field"
		if ($fName) { return $fName }
		# Пустой <field/> → wildcard (apply to all) — эквивалентно Auto
		$fieldEl = $item.SelectSingleNode("dcsset:field", $ns)
		if ($fieldEl) { return 'Auto' }
	}
	switch ($xt) {
		'SelectedItemAuto' {
			# Auto может иметь <use>false</use> — отключённый Auto-элемент в selection.
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
				$inner += (Build-SelectionItem -item $sub -loc "$loc/folder")
			}
			$entry = [ordered]@{ folder = $folderTitle; items = $inner }
			# folder может также иметь свой <dcsset:field> (редко, но встречается)
			$folderField = Get-Text $item "dcsset:field"
			if ($folderField) { $entry['field'] = $folderField }
			$plN = $item.SelectSingleNode("dcsset:placement", $ns)
			if ($plN -and $plN.InnerText -and $plN.InnerText -ne 'Auto') {
				$entry['placement'] = $plN.InnerText
			}
			return $entry
		}
		default {
			return (New-Sentinel -kind "SelectionItem:$xt" -loc $loc -detail 'Неизвестный тип элемента selection')
		}
	}
}

# Build selection items array
function Build-Selection {
	param($selNode, [string]$loc)
	if (-not $selNode) { return @() }
	$out = @()
	foreach ($it in $selNode.SelectNodes("dcsset:item", $ns)) {
		$out += (Build-SelectionItem -item $it -loc $loc)
	}
	return ,$out
}

# Build order items array
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
			default { $out += (New-Sentinel -kind "OrderItem:$xt" -loc $loc -detail 'Неизвестный тип сортировки') }
		}
	}
	return ,$out
}

# Прочитать <dcscor:value xsi:type="v8ui:Line"> в объект {@type:Line, width, gap, style}.
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
# Возвращает то значение которое идёт в "value" slot.
function Read-AppearanceValueNode {
	param($valNode)
	if (-not $valNode) { return $null }
	$vt = Get-LocalXsiType $valNode
	if ($vt -eq 'LocalStringType') { return (Get-MLText $valNode) }
	if ($vt -eq 'Font') { return (Get-FontValue $valNode) }
	if ($vt -eq 'Line') { return (Get-LineValue $valNode) }
	return $valNode.InnerText
}

# Build appearance dict from <dcsset:appearance> or <dcscor:item> list.
# Поддерживает Line-значения (граница) и nested SettingsParameterValue items
# (например СтильГраницы.Сверху). DSL form B (см. docs/skd-dsl-spec.md):
#   - top-level Line: { "@type": "Line", "width", "gap", "style", "use"?, "items"? }
#   - nested item: { "value": <значение>, "use"?: false }
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
		# Nested dcscor:item внутри этого item — wrap form {value, use?}.
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
		# Определяем форму вывода
		$valIsLine = ($rawVal -is [System.Collections.IDictionary]) -and $rawVal.Contains('@type') -and ($rawVal['@type'] -eq 'Line')
		if ($valIsLine) {
			# top-level Line — атрибуты inline + опц. use/items
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

# Build conditionalAppearance array
function Build-ConditionalAppearance {
	param($caNode, [string]$loc)
	if (-not $caNode) { return @() }
	$out = @()
	$i = 0
	foreach ($it in $caNode.SelectNodes("dcsset:item", $ns)) {
		$entry = [ordered]@{}
		# Silent-drop: scope (fields/groups/overall) — не воспроизводится в DSL
		$scopeNode = $it.SelectSingleNode("dcsset:scope", $ns)
		if ($scopeNode -and $scopeNode.HasChildNodes) {
			$null = Add-Warning -kind 'SilentDrop:scope' -loc "$loc/$i/scope" -detail "conditionalAppearance item имеет scope — не воспроизводится в DSL"
		}
		$selNode = $it.SelectSingleNode("dcsset:selection", $ns)
		if ($selNode -and $selNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
			$entry['selection'] = Build-Selection -selNode $selNode -loc "$loc/$i/selection"
		}
		$filterNode = $it.SelectSingleNode("dcsset:filter", $ns)
		if ($filterNode -and $filterNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
			$f = @()
			foreach ($fc in $filterNode.SelectNodes("dcsset:item", $ns)) {
				$f += (Build-FilterItem -itemNode $fc -loc "$loc/$i/filter")
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
			$usp = Get-MLText $uspN
			if ($usp) { $entry['userSettingPresentation'] = $usp }
		}
		# use=false на самом condAppearance item
		$useV = Get-Text $it "dcsset:use"
		if ($useV -eq 'false') { $entry['use'] = $false }
		# useInXxx — управляет где применяется правило оформления
		# (group, hierarchicalGroup, overall, fieldsHeader, header, parameters,
		#  filter, resourceFieldsHeader, overallHeader, overallResourceFieldsHeader)
		$useInDontUse = @()
		foreach ($ch in $it.ChildNodes) {
			if ($ch.NodeType -ne 'Element' -or $ch.NamespaceURI -ne 'http://v8.1c.ru/8.1/data-composition-system/settings') { continue }
			if ($ch.LocalName -match '^useIn(.+)$' -and $ch.InnerText -eq 'DontUse') {
				# Преобразуем useInGroup → group, useInFieldsHeader → fieldsHeader
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

# Build outputParameters dict
# Зеркало $script:outputParamTypes из skd-compile — для known keys compile auto-detect-ит
# тип по имени параметра, поэтому valueType в DSL не нужен (избыточный шум).
$script:outputParamTypesKnown = @{
	'Заголовок'                              = 'mltext'
	'ВыводитьЗаголовок'                      = 'dcsset:DataCompositionTextOutputType'
	'ВыводитьПараметрыДанных'                = 'dcsset:DataCompositionTextOutputType'
	'ВыводитьОтбор'                          = 'dcsset:DataCompositionTextOutputType'
	'МакетОформления'                        = 'xs:string'
	'РасположениеПолейГруппировки'           = 'dcsset:DataCompositionGroupFieldsPlacement'
	'РасположениеРеквизитов'                 = 'dcsset:DataCompositionAttributesPlacement'
	'ГоризонтальноеРасположениеОбщихИтогов'  = 'dcscor:DataCompositionTotalPlacement'
	'ВертикальноеРасположениеОбщихИтогов'    = 'dcscor:DataCompositionTotalPlacement'
	'РасположениеОбщихИтогов'                = 'dcscor:DataCompositionTotalPlacement'
	'РасположениеИтогов'                     = 'dcscor:DataCompositionTotalPlacement'
	'РасположениеГруппировки'                = 'dcsset:DataCompositionFieldGroupPlacement'
	'РасположениеРесурсов'                   = 'dcsset:DataCompositionResourcesPlacement'
	'ТипМакета'                              = 'dcsset:DataCompositionGroupTemplateType'
}

function Build-OutputParameters {
	param($opNode)
	if (-not $opNode) { return $null }
	$d = [ordered]@{}
	foreach ($it in $opNode.SelectNodes("dcscor:item", $ns)) {
		$pName = Get-Text $it "dcscor:parameter"
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $pName -or -not $val) { continue }
		$vType = Get-LocalXsiType $val
		# Полный xsi:type (с префиксом) — нужен compile для bit-perfect, если ключ не в outputParamTypes.
		$fullType = $null
		$ta = $val.Attributes['xsi:type']
		if ($ta) { $fullType = $ta.Value }
		if ($vType -eq 'LocalStringType') { $rawVal = Get-MLText $val }
		elseif ($vType -eq 'Font') { $rawVal = Get-FontValue $val }
		else { $rawVal = $val.InnerText }
		# Nested dcscor:items (sub-параметры типа ТипДиаграммы.ВидПодписей)
		$nestedItems = [ordered]@{}
		foreach ($sub in $it.SelectNodes("dcscor:item", $ns)) {
			$subName = Get-Text $sub "dcscor:parameter"
			$subVal = $sub.SelectSingleNode("dcscor:value", $ns)
			if (-not $subName -or -not $subVal) { continue }
			$subType = Get-LocalXsiType $subVal
			$subFull = $null
			$subTA = $subVal.Attributes['xsi:type']
			if ($subTA) { $subFull = $subTA.Value }
			if ($subType -eq 'LocalStringType') { $subRaw = Get-MLText $subVal }
			elseif ($subType -eq 'Font') { $subRaw = Get-FontValue $subVal }
			else { $subRaw = $subVal.InnerText }
			# Резолвим prefix → URI: если URI не из стандартных корневых xmlns —
			# сохраняем как объект {uri, name} чтобы compile эмитил xmlns локально.
			$subTypeField = $subFull
			if ($subFull -and $subFull -match '^([^:]+):(.+)$') {
				$pfx = $matches[1]; $localName = $matches[2]
				$uri = $subVal.GetNamespaceOfPrefix($pfx)
				if ($uri -and $uri -notin @(
					'http://www.w3.org/2001/XMLSchema',
					'http://www.w3.org/2001/XMLSchema-instance',
					'http://v8.1c.ru/8.1/data-composition-system/schema',
					'http://v8.1c.ru/8.1/data-composition-system/settings',
					'http://v8.1c.ru/8.1/data-composition-system/core',
					'http://v8.1c.ru/8.1/data-composition-system/common',
					'http://v8.1c.ru/8.1/data/core',
					'http://v8.1c.ru/8.1/data/ui'
				)) {
					$subTypeField = [ordered]@{ uri = $uri; name = $localName }
				}
			}
			$entry = [ordered]@{ value = $subRaw; valueType = $subTypeField }
			$subUse = Get-Text $sub "dcscor:use"
			if ($subUse -eq 'false') { $entry['use'] = $false }
			$nestedItems[$subName] = $entry
		}
		# Extras (use=false / viewMode / userSettingID / userSettingPresentation / nested items) → wrapper.
		$useV = Get-Text $it "dcscor:use"
		$vmN = $it.SelectSingleNode("dcsset:viewMode", $ns)
		$usidV = Get-Text $it "dcsset:userSettingID"
		$uspN = $it.SelectSingleNode("dcsset:userSettingPresentation", $ns)
		# Если xsi:type — кастомный (dcsset:XXX, v8ui:XXX, и т.п., не xs:* и не LocalStringType/Font),
		# нужен wrap чтобы compile сохранил тип через valueType (default — xs:string).
		# typeIsCustom: тип не покрыт auto-detect (compile сам сделает default).
		# Если ключ — known (есть в outputParamTypesKnown) И значение xsi:type совпадает с map —
		# auto-detect compile вернёт тот же тип → valueType в DSL не нужен.
		$typeAutoDetected = $false
		if ($script:outputParamTypesKnown.ContainsKey($pName)) {
			$mapType = $script:outputParamTypesKnown[$pName]
			# mltext в map ≡ LocalStringType в XML
			if ($mapType -eq 'mltext' -and $vType -eq 'LocalStringType') { $typeAutoDetected = $true }
			elseif ($fullType -eq $mapType) { $typeAutoDetected = $true }
		}
		$typeIsCustom = $fullType -and ($fullType -notmatch '^xs:') -and ($vType -ne 'LocalStringType') -and ($vType -ne 'Font') -and -not $typeAutoDetected
		$hasExtras = ($useV -eq 'false') -or $vmN -or $usidV -or $uspN -or ($nestedItems.Count -gt 0) -or $typeIsCustom
		if ($hasExtras) {
			$wrap = [ordered]@{ value = $rawVal }
			if ($fullType -and -not (($vType -eq 'LocalStringType') -or ($vType -eq 'Font')) -and -not $typeAutoDetected) {
				$wrap['valueType'] = $fullType
			}
			if ($useV -eq 'false') { $wrap['use'] = $false }
			if ($nestedItems.Count -gt 0) { $wrap['items'] = $nestedItems }
			if ($vmN) { $wrap['viewMode'] = $vmN.InnerText }
			if ($usidV) { $wrap['userSettingID'] = 'auto' }
			if ($uspN) { $wrap['userSettingPresentation'] = Get-MLText $uspN }
			$d[$pName] = $wrap
		} else {
			$d[$pName] = $rawVal
		}
	}
	return $d
}

# Build dataParameters — return "auto" if every non-hidden top-level param appears
# with userSettingID and value matches default; otherwise return explicit list.
function Build-DataParameters {
	param($dpNode, $topParams)
	if (-not $dpNode) { return $null }
	$items = $dpNode.SelectNodes("dcscor:item", $ns)
	if ($items.Count -eq 0) { return $null }
	# Build a quick map name → top-level rawParam
	$visibleTop = @{}
	foreach ($tp in $topParams) {
		if (-not $tp.hidden -and -not $script:autoDatesCompanions.ContainsKey($tp.name)) {
			$visibleTop[$tp.name] = $tp
		}
	}
	$canAuto = $true
	$presentNames = @{}
	$entries = @()
	foreach ($it in $items) {
		$pn = Get-Text $it "dcscor:parameter"
		$presentNames[$pn] = $true
		$usid = Get-Text $it "dcsset:userSettingID"
		if (-not $usid) { $canAuto = $false }
		# Compare value to top-level param value
		$valNode = $it.SelectSingleNode("dcscor:value", $ns)
		# use на dataParameter item — это <dcscor:use> (не dcsset)
		$use = Get-Text $it "dcscor:use"
		if ($use -eq 'false') { $canAuto = $false }
		# viewMode / userSettingPresentation на dataParameter item — это dcsset:* (после value)
		$vmN = $it.SelectSingleNode("dcsset:viewMode", $ns)
		$uspN = $it.SelectSingleNode("dcsset:userSettingPresentation", $ns)
		if ($vmN -or $uspN) { $canAuto = $false }
		$tp = $visibleTop[$pn]
		$flags = @()
		if ($usid) { $flags += '@user' }
		if ($use -eq 'false') { $flags += '@off' }
		$vt = Get-LocalXsiType $valNode
		$vDisplay = $null
		$stdPeriodObj = $null
		if ($vt -eq 'StandardPeriod') {
			# Shape inference в compile: {variant, startDate, endDate} → SP с датами,
			# {variant} only с SP-вариантом (ThisMonth/Custom/etc) → SP без дат.
			$variant = Get-Text $valNode "v8:variant"
			$sd = Get-Text $valNode "v8:startDate"
			$ed = Get-Text $valNode "v8:endDate"
			$hasExplicitDates = ($sd -and $sd -ne '0001-01-01T00:00:00') -or ($ed -and $ed -ne '0001-01-01T00:00:00')
			if ($hasExplicitDates) {
				$stdPeriodObj = [ordered]@{ variant = $variant }
				if ($sd) { $stdPeriodObj['startDate'] = $sd }
				if ($ed) { $stdPeriodObj['endDate'] = $ed }
				$canAuto = $false
			} elseif ($variant) {
				$vDisplay = $variant
				if ($vmN -or $uspN) {
					$stdPeriodObj = [ordered]@{ variant = $variant }
				}
			}
		} elseif ($vt -eq 'StandardBeginningDate') {
			# Shape inference в compile: {variant, date} → SBD, либо variant начинается с BeginningOf*.
			$variant = Get-Text $valNode "v8:variant"
			$d = Get-Text $valNode "v8:date"
			$hasExplicitDate = $d -and $d -ne '0001-01-01T00:00:00'
			if ($hasExplicitDate) {
				$stdPeriodObj = [ordered]@{ variant = $variant; date = $d }
				$canAuto = $false
			} elseif ($variant) {
				$stdPeriodObj = [ordered]@{ variant = $variant }
				$canAuto = $false
			}
		} elseif ($vt -eq 'DesignTimeValue') {
			$vDisplay = $valNode.InnerText
		} elseif ($vt -eq 'LocalStringType') {
			$vDisplay = Get-MLText $valNode
		} else {
			if ($valNode) { $vDisplay = $valNode.InnerText }
		}
		# Compare to top-level default
		if ($tp -and $tp.valueDisplay -ne $vDisplay) { $canAuto = $false }
		if (-not $tp) { $canAuto = $false }   # extra param not in top-level
		# Empty xs:string + use=false — оригинальный placeholder для disabled-параметра
		# (используется для типа DateTime в settings; см. АнализПлановыхНачислений @1506).
		# Сохраняем явный valueType чтобы compile эмитил <value xsi:type="xs:string"/>
		# вместо xsi:nil.
		$isEmptyStringPlaceholder = ($vt -eq 'string') -and (-not $valNode.InnerText) -and ($use -eq 'false')
		if ($isEmptyStringPlaceholder) { $canAuto = $false }
		# Object form требуется если есть viewMode / userSettingPresentation / StandardPeriod-с-датами / xs:string-placeholder
		if ($stdPeriodObj -or $vmN -or $uspN -or $isEmptyStringPlaceholder) {
			$obj = [ordered]@{ parameter = $pn }
			if ($stdPeriodObj) {
				$obj['value'] = $stdPeriodObj
				# valueType не нужен — compile определит StandardPeriod по value.variant
			} elseif ($isEmptyStringPlaceholder) {
				$obj['value'] = ''
				$obj['valueType'] = 'xs:string'
			} elseif ($null -ne $vDisplay -and $vDisplay -ne '') {
				# Конвертация для типизированных значений (compile различает по типу JSON)
				if ($vt -eq 'boolean') { $obj['value'] = ($vDisplay -eq 'true') }
				elseif ($vt -eq 'decimal') {
					if ($vDisplay -match '^-?\d+$') { $obj['value'] = [int]$vDisplay }
					else { $obj['value'] = [double]$vDisplay }
				}
				else { $obj['value'] = $vDisplay }
				# Сохраняем полный xsi:type для bit-perfect эмиссии
				$ta = $valNode.Attributes['xsi:type']
				if ($ta) { $obj['valueType'] = $ta.Value }
			}
			if ($use -eq 'false') { $obj['use'] = $false }
			if ($usid) { $obj['userSettingID'] = 'auto' }
			if ($vmN) { $obj['viewMode'] = $vmN.InnerText }
			if ($uspN) {
				$uspV = Get-MLText $uspN
				if ($uspV) { $obj['userSettingPresentation'] = $uspV }
			}
			$entries += $obj
		} else {
			# Build shorthand entry
			$s = $pn
			if ($null -ne $vDisplay -and $vDisplay -ne '') { $s += " = $vDisplay" }
			if ($flags) { $s += ' ' + ($flags -join ' ') }
			$entries += $s
		}
	}
	# Check that all visible top-level params are present
	foreach ($vn in $visibleTop.Keys) { if (-not $presentNames.ContainsKey($vn)) { $canAuto = $false } }
	if ($canAuto) { return 'auto' }
	return ,$entries
}

# Read groupItems → array. Простые поля → string. С нестандартным groupType/periodAdditionType
# → object form {field, groupType?, periodAdditionType?} (compile принимает оба варианта).
function Get-GroupFields {
	param($parentNode, [string]$loc)
	$gFields = @()
	$gi = $parentNode.SelectSingleNode("dcsset:groupItems", $ns)
	if (-not $gi) { return ,$gFields }
	foreach ($gItem in $gi.SelectNodes("dcsset:item", $ns)) {
		$gxt = Get-LocalXsiType $gItem
		if ($gxt -eq 'GroupItemAuto') {
			$gFields += 'Auto'
		} elseif ($gxt -eq 'GroupItemField') {
			$gf = Get-Text $gItem "dcsset:field"
			$pat = Get-Text $gItem "dcsset:periodAdditionType"
			$gt = Get-Text $gItem "dcsset:groupType"
			# periodAdditionBegin/End: non-default = либо dcscor:Field (path), либо
			# date ≠ 0001-01-01T00:00:00. Сохраняем строкой — compile auto-detect тип.
			$pabN = $gItem.SelectSingleNode("dcsset:periodAdditionBegin", $ns)
			$paeN = $gItem.SelectSingleNode("dcsset:periodAdditionEnd", $ns)
			$pab = $null; $pae = $null
			if ($pabN) {
				$pt = Get-LocalXsiType $pabN
				$pv = $pabN.InnerText
				if ($pt -eq 'Field' -or ($pv -and $pv -ne '0001-01-01T00:00:00')) { $pab = $pv }
			}
			if ($paeN) {
				$pt = Get-LocalXsiType $paeN
				$pv = $paeN.InnerText
				if ($pt -eq 'Field' -or ($pv -and $pv -ne '0001-01-01T00:00:00')) { $pae = $pv }
			}
			$isDefault = (-not $pat -or $pat -eq 'None') -and (-not $gt -or $gt -eq 'Items') -and (-not $pab) -and (-not $pae)
			if ($isDefault) {
				$gFields += $gf
			} else {
				$obj = [ordered]@{ field = $gf }
				if ($gt -and $gt -ne 'Items') { $obj['groupType'] = $gt }
				if ($pat -and $pat -ne 'None') { $obj['periodAdditionType'] = $pat }
				if ($pab) { $obj['periodAdditionBegin'] = $pab }
				if ($pae) { $obj['periodAdditionEnd'] = $pae }
				$gFields += $obj
			}
		} else {
			$gFields += (New-Sentinel -kind "GroupItem:$gxt" -loc "$loc/groupItems" -detail 'Тип элемента группировки не покрыт')
		}
	}
	return ,$gFields
}

# Read a {groupItems, order, selection} sub-block (for table column/row, chart point/series).
# Skips Auto-only order/selection (they are platform defaults).
function Build-TableAxisBlock {
	param($node, [string]$loc, [bool]$includeName = $false)
	$entry = [ordered]@{}
	# name доступен на любой оси (column/row/point/series): убираем флаг includeName
	$nm = Get-Text $node "dcsset:name"
	if ($nm) { $entry['name'] = $nm }
	$gf = Get-GroupFields -parentNode $node -loc $loc
	if ($gf.Count -gt 0) { $entry['groupFields'] = $gf }
	# filter block on column/row/point/series
	$fNode = $node.SelectSingleNode("dcsset:filter", $ns)
	if ($fNode -and $fNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
		$fa = @()
		foreach ($fc in $fNode.SelectNodes("dcsset:item", $ns)) { $fa += (Build-FilterItem -itemNode $fc -loc "$loc/filter") }
		$entry['filter'] = $fa
	}
	# order — preserve presence (even [Auto]) for bit-perfect round-trip
	$ordNode = $node.SelectSingleNode("dcsset:order", $ns)
	if ($ordNode) {
		$ordItems = Build-Order -ordNode $ordNode -loc "$loc/order"
		if ($ordItems.Count -gt 0) { $entry['order'] = $ordItems }
	}
	# selection — preserve presence (even [Auto])
	$selNode = $node.SelectSingleNode("dcsset:selection", $ns)
	if ($selNode) {
		$selItems = Build-Selection -selNode $selNode -loc "$loc/selection"
		if ($selItems.Count -gt 0) { $entry['selection'] = $selItems }
	}
	# conditionalAppearance block
	$caN = $node.SelectSingleNode("dcsset:conditionalAppearance", $ns)
	if ($caN) {
		$ca = Build-ConditionalAppearance -caNode $caN -loc "$loc/ca"
		if ($ca.Count -gt 0) { $entry['conditionalAppearance'] = $ca }
	}
	# outputParameters block
	$opNode = $node.SelectSingleNode("dcsset:outputParameters", $ns)
	$op = Build-OutputParameters -opNode $opNode
	if ($op -and $op.Count -gt 0) { $entry['outputParameters'] = $op }
	# nested children (StructureItemGroup внутри table row/column или chart axis)
	$children = Build-Structure -node $node -loc "$loc/children"
	if ($children.Count -gt 0) { $entry['children'] = $children }
	# user-settings on the axis itself
	# viewMode: сохраняем даже Normal если node присутствует
	$avmNode = $node.SelectSingleNode("dcsset:viewMode", $ns)
	if ($avmNode) { $entry['viewMode'] = $avmNode.InnerText }
	$ausid = Get-Text $node "dcsset:userSettingID"
	if ($ausid) { $entry['userSettingID'] = 'auto' }
	$ausPresNode = $node.SelectSingleNode("dcsset:userSettingPresentation", $ns)
	if ($ausPresNode) {
		$ausPres = Get-MLText $ausPresNode
		if ($ausPres) { $entry['userSettingPresentation'] = $ausPres }
	}
	# itemsViewMode на axis (column/row/point/series)
	$aivmNode = $node.SelectSingleNode("dcsset:itemsViewMode", $ns)
	if ($aivmNode) { $entry['itemsViewMode'] = $aivmNode.InnerText }
	return $entry
}

# Build structure recursively. Returns array of structure items (object form).
# Caller can later try to fold linear chain into string shorthand.
function Build-Structure {
	param($node, [string]$loc)
	if (-not $node) { return @() }
	$items = @()
	$idx = 0
	foreach ($it in $node.SelectNodes("dcsset:item", $ns)) {
		$xt = Get-LocalXsiType $it
		if ($xt -eq 'StructureItemTable') {
			$entry = [ordered]@{ type = 'table' }
			$nm = Get-Text $it "dcsset:name"
			if ($nm) { $entry['name'] = $nm }
			$cols = @()
			foreach ($cn in $it.SelectNodes("dcsset:column", $ns)) {
				$cols += (Build-TableAxisBlock -node $cn -loc "$loc/$idx/column")
			}
			if ($cols.Count -gt 0) { $entry['columns'] = $cols }
			$rows = @()
			foreach ($rn in $it.SelectNodes("dcsset:row", $ns)) {
				$rows += (Build-TableAxisBlock -node $rn -loc "$loc/$idx/row" -includeName $true)
			}
			if ($rows.Count -gt 0) { $entry['rows'] = $rows }
			# top-level selection / outputParameters / conditionalAppearance на самой
			# таблице (отдельно от row/column)
			$tSelN = $it.SelectSingleNode("dcsset:selection", $ns)
			if ($tSelN) {
				$tSelI = Build-Selection -selNode $tSelN -loc "$loc/$idx/selection"
				if ($tSelI.Count -gt 0) { $entry['selection'] = $tSelI }
			}
			$tOpN = $it.SelectSingleNode("dcsset:outputParameters", $ns)
			$tOp = Build-OutputParameters -opNode $tOpN
			if ($tOp -and $tOp.Count -gt 0) { $entry['outputParameters'] = $tOp }
			$tCaN = $it.SelectSingleNode("dcsset:conditionalAppearance", $ns)
			if ($tCaN) {
				$tCa = Build-ConditionalAppearance -caNode $tCaN -loc "$loc/$idx/ca"
				if ($tCa.Count -gt 0) { $entry['conditionalAppearance'] = $tCa }
			}
			# use=false на самой таблице — отключённая ветка
			$tUse = Get-Text $it "dcsset:use"
			if ($tUse -eq 'false') { $entry['use'] = $false }
			# viewMode / userSettingID / userSettingPresentation / itemsViewMode / rowsViewMode / columnsViewMode на самой таблице
			foreach ($ch in $it.ChildNodes) {
				if ($ch.NodeType -ne 'Element' -or $ch.NamespaceURI -ne 'http://v8.1c.ru/8.1/data-composition-system/settings') { continue }
				if ($ch.LocalName -eq 'viewMode' -and -not $entry.Contains('viewMode')) { $entry['viewMode'] = $ch.InnerText }
				elseif ($ch.LocalName -eq 'userSettingID' -and -not $entry.Contains('userSettingID')) { $entry['userSettingID'] = 'auto' }
				elseif ($ch.LocalName -eq 'userSettingPresentation' -and -not $entry.Contains('userSettingPresentation')) {
					$uspV = Get-MLText $ch
					if ($uspV) { $entry['userSettingPresentation'] = $uspV }
				}
				elseif ($ch.LocalName -eq 'itemsViewMode' -and -not $entry.Contains('itemsViewMode')) { $entry['itemsViewMode'] = $ch.InnerText }
				elseif ($ch.LocalName -eq 'columnsViewMode' -and -not $entry.Contains('columnsViewMode')) { $entry['columnsViewMode'] = $ch.InnerText }
				elseif ($ch.LocalName -eq 'rowsViewMode' -and -not $entry.Contains('rowsViewMode')) { $entry['rowsViewMode'] = $ch.InnerText }
			}
			$items += $entry
			$idx++
			continue
		}
		if ($xt -eq 'StructureItemNestedObject') {
			$entry = [ordered]@{ type = 'nestedObject' }
			$objID = Get-Text $it "dcsset:objectID"
			if ($objID) { $entry['objectID'] = $objID }
			$settingsNode = $it.SelectSingleNode("dcsset:settings", $ns)
			if ($settingsNode) {
				$nestedSettings = [ordered]@{}
				$selNode = $settingsNode.SelectSingleNode("dcsset:selection", $ns)
				$selI = Build-Selection -selNode $selNode -loc "$loc/$idx/nested/selection"
				if ($selI.Count -gt 0) { $nestedSettings['selection'] = $selI }
				$fNode = $settingsNode.SelectSingleNode("dcsset:filter", $ns)
				if ($fNode -and $fNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
					$fa = @()
					foreach ($fc in $fNode.SelectNodes("dcsset:item", $ns)) { $fa += (Build-FilterItem -itemNode $fc -loc "$loc/$idx/nested/filter") }
					$nestedSettings['filter'] = $fa
				}
				$oNode = $settingsNode.SelectSingleNode("dcsset:order", $ns)
				$oI = Build-Order -ordNode $oNode -loc "$loc/$idx/nested/order"
				if ($oI.Count -gt 0) { $nestedSettings['order'] = $oI }
				$caNode = $settingsNode.SelectSingleNode("dcsset:conditionalAppearance", $ns)
				if ($caNode) {
					$ca = Build-ConditionalAppearance -caNode $caNode -loc "$loc/$idx/nested/ca"
					if ($ca.Count -gt 0) { $nestedSettings['conditionalAppearance'] = $ca }
				}
				$opNode = $settingsNode.SelectSingleNode("dcsset:outputParameters", $ns)
				$op = Build-OutputParameters -opNode $opNode
				if ($op -and $op.Count -gt 0) { $nestedSettings['outputParameters'] = $op }
				$entry['settings'] = $nestedSettings
			}
			$items += $entry
			$idx++
			continue
		}
		if ($xt -eq 'StructureItemChart') {
			$entry = [ordered]@{ type = 'chart' }
			$nm = Get-Text $it "dcsset:name"
			if ($nm) { $entry['name'] = $nm }
			# point/series — может быть несколько (multi-series диаграмма).
			# Single → сохраняем как object (backward-compat); >1 → массив.
			$pnList = $it.SelectNodes("dcsset:point", $ns)
			if ($pnList.Count -eq 1) {
				$entry['points'] = Build-TableAxisBlock -node $pnList[0] -loc "$loc/$idx/point"
			} elseif ($pnList.Count -gt 1) {
				$pArr = @()
				$pi = 0
				foreach ($p in $pnList) { $pArr += (Build-TableAxisBlock -node $p -loc "$loc/$idx/point[$pi]"); $pi++ }
				$entry['points'] = $pArr
			}
			$snList = $it.SelectNodes("dcsset:series", $ns)
			if ($snList.Count -eq 1) {
				$entry['series'] = Build-TableAxisBlock -node $snList[0] -loc "$loc/$idx/series"
			} elseif ($snList.Count -gt 1) {
				$sArr = @()
				$si = 0
				foreach ($s in $snList) { $sArr += (Build-TableAxisBlock -node $s -loc "$loc/$idx/series[$si]"); $si++ }
				$entry['series'] = $sArr
			}
			# Selection (chart values) — сохраняем даже [Auto] для bit-perfect presence
			$selN = $it.SelectSingleNode("dcsset:selection", $ns)
			if ($selN) {
				$selI = Build-Selection -selNode $selN -loc "$loc/$idx/selection"
				if ($selI.Count -gt 0) { $entry['selection'] = $selI }
			}
			$opN = $it.SelectSingleNode("dcsset:outputParameters", $ns)
			$op = Build-OutputParameters -opNode $opN
			if ($op -and $op.Count -gt 0) { $entry['outputParameters'] = $op }
			# use=false на самой диаграмме — отключённая ветка
			$chUse = Get-Text $it "dcsset:use"
			if ($chUse -eq 'false') { $entry['use'] = $false }
			# viewMode / userSettingID / userSettingPresentation / itemsViewMode / pointsViewMode / seriesViewMode на chart
			foreach ($ch in $it.ChildNodes) {
				if ($ch.NodeType -ne 'Element' -or $ch.NamespaceURI -ne 'http://v8.1c.ru/8.1/data-composition-system/settings') { continue }
				if ($ch.LocalName -eq 'viewMode' -and -not $entry.Contains('viewMode')) { $entry['viewMode'] = $ch.InnerText }
				elseif ($ch.LocalName -eq 'userSettingID' -and -not $entry.Contains('userSettingID')) { $entry['userSettingID'] = 'auto' }
				elseif ($ch.LocalName -eq 'userSettingPresentation' -and -not $entry.Contains('userSettingPresentation')) {
					$uspV = Get-MLText $ch
					if ($uspV) { $entry['userSettingPresentation'] = $uspV }
				}
				elseif ($ch.LocalName -eq 'itemsViewMode' -and -not $entry.Contains('itemsViewMode')) { $entry['itemsViewMode'] = $ch.InnerText }
				elseif ($ch.LocalName -eq 'pointsViewMode' -and -not $entry.Contains('pointsViewMode')) { $entry['pointsViewMode'] = $ch.InnerText }
				elseif ($ch.LocalName -eq 'seriesViewMode' -and -not $entry.Contains('seriesViewMode')) { $entry['seriesViewMode'] = $ch.InnerText }
			}
			$items += $entry
			$idx++
			continue
		}
		# <dcsset:item> без xsi:type → StructureItemGroup (default form, встречается
		# во вложенных children внутри table row / structure group)
		if ($xt -and $xt -ne 'StructureItemGroup') {
			$items += (New-Sentinel -kind "StructureItem:$xt" -loc $loc -detail 'Тип структуры пока не покрыт')
			$idx++
			continue
		}
		$entry = [ordered]@{}
		# use=false на самой группе — отключённая ветка структуры
		$gUse = Get-Text $it "dcsset:use"
		if ($gUse -eq 'false') { $entry['use'] = $false }
		# Optional name
		$nm = Get-Text $it "dcsset:name"
		if ($nm) { $entry['name'] = $nm }
		# groupItems → groupFields (через общий Get-GroupFields с object form поддержкой)
		$gFields = Get-GroupFields -parentNode $it -loc $loc
		if ($gFields.Count -gt 0) { $entry['groupFields'] = $gFields }

		# Local selection — preserve presence (even [Auto]) for bit-perfect round-trip
		$selNode = $it.SelectSingleNode("dcsset:selection", $ns)
		if ($selNode) {
			$selItems = Build-Selection -selNode $selNode -loc "$loc/selection"
			if ($selItems.Count -gt 0) { $entry['selection'] = $selItems }
		}
		# Local order — same
		$ordNode = $it.SelectSingleNode("dcsset:order", $ns)
		if ($ordNode) {
			$ordItems = Build-Order -ordNode $ordNode -loc "$loc/order"
			if ($ordItems.Count -gt 0) { $entry['order'] = $ordItems }
			# Block-level viewMode/userSettingID на <dcsset:order>
			foreach ($ch in $ordNode.ChildNodes) {
				if ($ch.NodeType -ne 'Element' -or $ch.NamespaceURI -ne 'http://v8.1c.ru/8.1/data-composition-system/settings') { continue }
				if ($ch.LocalName -eq 'viewMode') { $entry['orderViewMode'] = $ch.InnerText }
				elseif ($ch.LocalName -eq 'userSettingID') { $entry['orderUserSettingID'] = 'auto' }
			}
		}
		# Local filter
		$filterNode = $it.SelectSingleNode("dcsset:filter", $ns)
		if ($filterNode -and $filterNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
			$f = @()
			foreach ($fc in $filterNode.SelectNodes("dcsset:item", $ns)) { $f += (Build-FilterItem -itemNode $fc -loc "$loc/filter") }
			$entry['filter'] = $f
		}
		# Local conditionalAppearance
		$caNode = $it.SelectSingleNode("dcsset:conditionalAppearance", $ns)
		if ($caNode) {
			$ca = Build-ConditionalAppearance -caNode $caNode -loc "$loc/ca"
			if ($ca.Count -gt 0) { $entry['conditionalAppearance'] = $ca }
		}
		# Local outputParameters
		$opNode = $it.SelectSingleNode("dcsset:outputParameters", $ns)
		$op = Build-OutputParameters -opNode $opNode
		if ($op -and $op.Count -gt 0) { $entry['outputParameters'] = $op }

		# Children — recursive
		$children = Build-Structure -node $it -loc "$loc/children"
		if ($children.Count -gt 0) { $entry['children'] = $children }

		# viewMode / itemsViewMode / userSettingID / userSettingPresentation
		# на самой группе. Читаем direct-child <dcsset:*> (избегаем item-level
		# vars из selection/filter/order).
		$gvm = $null; $givm = $null; $gusid = $null; $guspNode = $null
		foreach ($ch in $it.ChildNodes) {
			if ($ch.NodeType -ne 'Element' -or $ch.NamespaceURI -ne 'http://v8.1c.ru/8.1/data-composition-system/settings') { continue }
			if ($ch.LocalName -eq 'viewMode' -and $null -eq $gvm) { $gvm = $ch.InnerText }
			elseif ($ch.LocalName -eq 'itemsViewMode' -and $null -eq $givm) { $givm = $ch.InnerText }
			elseif ($ch.LocalName -eq 'userSettingID' -and $null -eq $gusid) { $gusid = $ch.InnerText }
			elseif ($ch.LocalName -eq 'userSettingPresentation' -and $null -eq $guspNode) { $guspNode = $ch }
		}
		# Preserve explicit values (even Normal) so compile bit-perfect roundtrip works:
		# platform emits viewMode on some StructureItemGroup shapes but not others.
		if ($null -ne $gvm) { $entry['viewMode'] = $gvm }
		if ($null -ne $givm) { $entry['itemsViewMode'] = $givm }
		if ($gusid) { $entry['userSettingID'] = 'auto' }
		if ($guspNode) {
			$gusp = Get-MLText $guspNode
			if ($gusp) { $entry['userSettingPresentation'] = $gusp }
		}

		$items += $entry
		$idx++
	}
	return ,$items
}

# True when selection/order is just the single auto element ("Auto") that the
# compiler adds by default to every shorthand group — folding such a group back
# to shorthand is bit-perfect (Parse-StructureShorthand re-adds it on compile).
# Disabled auto ({auto,use}), mixed lists ("Поле","Auto") and explicit fields
# are objects / non-singleton lists and won't match → those keep object form.
function Is-AutoOnly($val) {
	if ($null -eq $val) { return $false }
	$arr = @($val)
	if ($arr.Count -ne 1) { return $false }
	return ($arr[0] -is [string]) -and ($arr[0] -eq 'Auto')
}

# Try to fold a structure tree into string shorthand "A > B > details".
# Conditions: linear chain (each level has exactly one child), each level is
# a plain group with single groupField and no local filter; selection/order are
# allowed only when they are the default single "Auto" element (see Is-AutoOnly).
function Try-StructureShorthand {
	param($items)
	if ($items.Count -ne 1) { return $null }
	$parts = @()
	$cur = $items[0]
	while ($null -ne $cur) {
		# Disallow extras
		if ($cur.Contains('type') -and $cur['type'] -ne 'group') { return $null }
		if ($cur.Contains('name')) { return $null }
		if ($cur.Contains('selection') -and -not (Is-AutoOnly $cur['selection'])) { return $null }
		if ($cur.Contains('order') -and -not (Is-AutoOnly $cur['order'])) { return $null }
		if ($cur.Contains('filter')) { return $null }
		if ($cur.Contains('viewMode')) { return $null }
		if ($cur.Contains('itemsViewMode')) { return $null }
		if ($cur.Contains('userSettingID')) { return $null }
		if ($cur.Contains('userSettingPresentation')) { return $null }
		if ($cur.Contains('use')) { return $null }
		if ($cur.Contains('conditionalAppearance')) { return $null }
		if ($cur.Contains('outputParameters')) { return $null }
		$gfs = $cur['groupFields']
		if ($null -eq $gfs -or $gfs.Count -eq 0) {
			# details level (terminal)
			$parts += 'details'
			break
		}
		if ($gfs.Count -ne 1) { return $null }
		# Только простые имена-строки сворачиваем в shorthand
		if ($gfs[0] -isnot [string]) { return $null }
		$parts += $gfs[0]
		$children = $cur['children']
		if ($null -eq $children -or $children.Count -eq 0) { break }
		if ($children.Count -ne 1) { return $null }
		$cur = $children[0]
	}
	return ($parts -join ' > ')
}

# --- 4. dataSources ---

# Резолв outputPath и загрузка user-стилей до обработки шаблонов
$script:outputDir = $null
$script:outputBasename = $null
if ($OutputPath) {
	if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
		$OutputPath = Join-Path (Get-Location).Path $OutputPath
	}
	$script:outputDir = [System.IO.Path]::GetDirectoryName($OutputPath)
	$script:outputBasename = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
	Load-UserStyles -dirPath $script:outputDir
}

$dataSources = @()
$dsourceNodes = $root.SelectNodes("r:dataSource", $ns)
foreach ($dsn in $dsourceNodes) {
	$nm = Get-Text $dsn "r:name"
	$tp = Get-Text $dsn "r:dataSourceType"
	$dataSources += [ordered]@{ name = $nm; type = $tp }
}
# Default: single ИсточникДанных1/Local → omit from output
$emitDataSources = $true
if ($dataSources.Count -eq 1 -and $dataSources[0].name -eq 'ИсточникДанных1' -and $dataSources[0].type -eq 'Local') {
	$emitDataSources = $false
}

# --- 5. dataSets ---

function Build-DataSet {
	param($dsNode, [string]$loc)
	$xsiType = Get-LocalXsiType $dsNode
	$name = Get-Text $dsNode "r:name"
	$ds = [ordered]@{ name = $name }

	switch ($xsiType) {
		'DataSetQuery' {
			$queryText = Get-Text $dsNode "r:query"
			$ds['query'] = Maybe-ExternalizeQuery -queryText $queryText -datasetName $name
		}
		'DataSetObject' {
			$ds['objectName'] = Get-Text $dsNode "r:objectName"
		}
		'DataSetUnion' {
			$nested = @()
			$ni = 0
			# Inner Union datasets are wrapped as <item xsi:type="..."> in real 1C output.
			# Accept <dataSet> too for backward compatibility with older builds.
			$innerNodes = @($dsNode.SelectNodes("r:item", $ns)) + @($dsNode.SelectNodes("r:dataSet", $ns))
			foreach ($nNode in $innerNodes) {
				$nested += (Build-DataSet -dsNode $nNode -loc "$loc/items[$ni]")
				$ni++
			}
			$ds['items'] = $nested
		}
		default {
			$ds['__unsupported__'] = (New-Sentinel -kind "DataSetType:$xsiType" -loc $loc -detail "Неизвестный тип набора данных")['__unsupported__']
		}
	}

	# Fields (Query, Object, and Union itself can all have fields)
	$fieldNodes = $dsNode.SelectNodes("r:field", $ns)
	if ($fieldNodes.Count -gt 0) {
		$fields = @()
		$fi = 0
		foreach ($fn in $fieldNodes) {
			$fxsi = Get-LocalXsiType $fn
			if ($fxsi -eq 'DataSetFieldField') {
				$fields += (Build-Field -fieldNode $fn -loc "$loc/field[$fi]")
			} elseif ($fxsi -eq 'DataSetFieldFolder') {
				# Поле-папка для UI-группировки (только dataPath+title, без типа/роли)
				$folderObj = [ordered]@{
					field = (Get-Text $fn "r:dataPath")
					folder = $true
				}
				$titleNode = $fn.SelectSingleNode("r:title", $ns)
				$title = Get-MLText $titleNode
				if ($title) { $folderObj['title'] = $title }
				$fields += $folderObj
			} else {
				$fields += (New-Sentinel -kind "FieldType:$fxsi" -loc "$loc/field[$fi]" -detail 'Тип поля не DataSetFieldField/Folder')
			}
			$fi++
		}
		$ds['fields'] = $fields
	}

	# dataSource attachment — omit if matches default (Union has no dataSource)
	if ($xsiType -ne 'DataSetUnion') {
		$dsSrc = Get-Text $dsNode "r:dataSource"
		if ($emitDataSources -and $dsSrc) { $ds['dataSource'] = $dsSrc }
	}

	return $ds
}

$dataSets = @()
$dsNodes = $root.SelectNodes("r:dataSet", $ns)
$dsi = 0
foreach ($dsNode in $dsNodes) {
	$dataSets += (Build-DataSet -dsNode $dsNode -loc "dataSet[$dsi]")
	$dsi++
}

# --- 5a-bis. dataSetLinks ---

$dataSetLinks = @()
$dslNodes = $root.SelectNodes("r:dataSetLink", $ns)
foreach ($dslNode in $dslNodes) {
	$link = [ordered]@{}
	$link['sourceDataSet']         = Get-Text $dslNode.SelectSingleNode("r:sourceDataSet", $ns)
	$link['destinationDataSet']    = Get-Text $dslNode.SelectSingleNode("r:destinationDataSet", $ns)
	$link['sourceExpression']      = Get-Text $dslNode.SelectSingleNode("r:sourceExpression", $ns)
	$link['destinationExpression'] = Get-Text $dslNode.SelectSingleNode("r:destinationExpression", $ns)
	$pNode = $dslNode.SelectSingleNode("r:parameter", $ns)
	if ($pNode) { $link['parameter'] = Get-Text $pNode }
	$plaNode = $dslNode.SelectSingleNode("r:parameterListAllowed", $ns)
	if ($plaNode -and ((Get-Text $plaNode) -eq 'true')) { $link['parameterListAllowed'] = $true }
	$seNode = $dslNode.SelectSingleNode("r:startExpression", $ns)
	if ($seNode) { $link['startExpression'] = Get-Text $seNode }
	$lceNode = $dslNode.SelectSingleNode("r:linkConditionExpression", $ns)
	if ($lceNode) { $link['linkConditionExpression'] = Get-Text $lceNode }
	$dataSetLinks += $link
}

# --- 5b. calculatedFields ---

$calculatedFields = @()
$cfNodes = $root.SelectNodes("r:calculatedField", $ns)
$ci = 0
foreach ($cf in $cfNodes) {
	$calculatedFields += (Build-CalcField -cfNode $cf -loc "calculatedField[$ci]")
	$ci++
}

# --- 5c. totalFields ---

$totalFields = @()
$tfNodes = $root.SelectNodes("r:totalField", $ns)
foreach ($tf in $tfNodes) { $totalFields += (Build-TotalField -tfNode $tf) }

# --- 5d. parameters with autoDates folding ---

$script:autoDatesCompanions = @{}

$paramsRaw = @()
$pi = 0
$pNodes = $root.SelectNodes("r:parameter", $ns)
foreach ($p in $pNodes) {
	$paramsRaw += (Build-Parameter -pNode $p -loc "parameter[$pi]")
	$pi++
}

# Detect autoDates: for each StandardPeriod parameter P, look for two siblings with
# expression "&P.ДатаНачала" and "&P.ДатаОкончания". If both found, mark P with @autoDates
# and remove the companions.
$paramByName = @{}
foreach ($p in $paramsRaw) { $paramByName[$p.name] = $p }

$removedNames = @{}
$script:autoDatesCompanions = @{}
foreach ($p in $paramsRaw) {
	if ($p.typeShort -ne 'StandardPeriod') { continue }
	$parentName = $p.name
	$startExpr = '&' + $parentName + '.ДатаНачала'
	$endExpr   = '&' + $parentName + '.ДатаОкончания'
	$startMatch = $null
	$endMatch = $null
	foreach ($q in $paramsRaw) {
		if ($q.name -eq $parentName) { continue }
		if ($q.expression -eq $startExpr) { $startMatch = $q.name }
		elseif ($q.expression -eq $endExpr) { $endMatch = $q.name }
	}
	# Fold ТОЛЬКО если companion-имена точно "НачалоПериода"/"КонецПериода" БЕЗ суффикса.
	# Иначе compile (который генерирует именно эти имена + type=date + DateFractions=Date)
	# не сможет вернуть bit-perfect для отчётов с шаблоном "Период<X>" → "НачалоПериода<X>"/
	# "КонецПериода<X>" + DateFractions=DateTime. Оставляем как явные параметры.
	# Также НЕ сворачиваем если companions имеют availableAsField=false — compile
	# auto-gen не передаёт этот атрибут (ERP-стиль без него; БСП-стиль с ним —
	# вариативность не выразима через @autoDates флаг, пусть companions останутся явными).
	$beginP = if ($startMatch) { $paramByName[$startMatch] } else { $null }
	$endP   = if ($endMatch)   { $paramByName[$endMatch]   } else { $null }
	$hasNotAField = ($beginP -and $beginP.notAField) -or ($endP -and $endP.notAField)
	if ($startMatch -eq 'НачалоПериода' -and $endMatch -eq 'КонецПериода' -and -not $hasNotAField) {
		$p['autoDates'] = $true
		$removedNames[$startMatch] = $true
		$removedNames[$endMatch] = $true
		$script:autoDatesCompanions[$startMatch] = $true
		$script:autoDatesCompanions[$endMatch]   = $true
	}
}

$parameters = @()
foreach ($p in $paramsRaw) {
	if ($removedNames.ContainsKey($p.name)) { continue }
	$parameters += (Render-Parameter -p $p)
}

# --- 6. Build top-level JSON object ---

$out = [ordered]@{}
if ($emitDataSources) { $out['dataSources'] = $dataSources }
$out['dataSets'] = $dataSets
if ($dataSetLinks.Count -gt 0) { $out['dataSetLinks'] = $dataSetLinks }
if ($calculatedFields.Count -gt 0) { $out['calculatedFields'] = $calculatedFields }
if ($totalFields.Count -gt 0)      { $out['totalFields'] = $totalFields }
if ($parameters.Count -gt 0)       { $out['parameters'] = $parameters }

# --- 5e. templates ---

$templates = @()
$tNodes = $root.SelectNodes("r:template", $ns)
$ti = 0
foreach ($tn in $tNodes) {
	$templates += (Build-Template -templateNode $tn -loc "template[$ti]")
	$ti++
}
if ($templates.Count -gt 0) { $out['templates'] = $templates }

# --- 5e2. fieldTemplates ---
# Привязка <fieldTemplate><field/><template/></fieldTemplate> поля к именованному area-template.

$fieldTemplates = @()
foreach ($ftn in $root.SelectNodes("r:fieldTemplate", $ns)) {
	$ftField = Get-Text $ftn "r:field"
	$ftTempl = Get-Text $ftn "r:template"
	$fieldTemplates += [ordered]@{ field = $ftField; template = $ftTempl }
}
if ($fieldTemplates.Count -gt 0) { $out['fieldTemplates'] = $fieldTemplates }

# --- 5f. groupTemplates ---

$groupTemplates = @()
# <groupHeaderTemplate> → templateType = "GroupHeader"
foreach ($ght in $root.SelectNodes("r:groupHeaderTemplate", $ns)) {
	$entry = [ordered]@{}
	$gn = Get-Text $ght "r:groupName"
	$gf = Get-Text $ght "r:groupField"
	if ($gn) { $entry['groupName'] = $gn }
	if ($gf) { $entry['groupField'] = $gf }
	$entry['templateType'] = 'GroupHeader'
	$entry['template'] = Get-Text $ght "r:template"
	$groupTemplates += $entry
}
# <groupTemplate> → templateType from inner <templateType>
foreach ($gt in $root.SelectNodes("r:groupTemplate", $ns)) {
	$entry = [ordered]@{}
	$gn = Get-Text $gt "r:groupName"
	$gf = Get-Text $gt "r:groupField"
	if ($gn) { $entry['groupName'] = $gn }
	if ($gf) { $entry['groupField'] = $gf }
	$entry['templateType'] = Get-Text $gt "r:templateType"
	$entry['template'] = Get-Text $gt "r:template"
	$groupTemplates += $entry
}
if ($groupTemplates.Count -gt 0) { $out['groupTemplates'] = $groupTemplates }

# --- 5g. settingsVariants ---

$settingsVariants = @()
$svNodes = $root.SelectNodes("r:settingsVariant", $ns)
$vi = 0
foreach ($sv in $svNodes) {
	$vname = Get-Text $sv "dcsset:name"
	$presNode = $sv.SelectSingleNode("dcsset:presentation", $ns)
	$presentation = Get-MLText $presNode

	$settingsNode = $sv.SelectSingleNode("dcsset:settings", $ns)
	$settings = [ordered]@{}

	# Helper: read block-level <dcsset:viewMode> (direct child, not item-level)
	function Get-BlockVM($node) {
		if (-not $node) { return $null }
		foreach ($child in $node.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'viewMode' -and $child.NamespaceURI -eq 'http://v8.1c.ru/8.1/data-composition-system/settings') {
				return $child.InnerText
			}
		}
		return $null
	}

	# Block-level userSettingID (direct child of selection/filter/order/conditionalAppearance).
	function Get-BlockUSID($node) {
		if (-not $node) { return $null }
		foreach ($child in $node.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'userSettingID' -and $child.NamespaceURI -eq 'http://v8.1c.ru/8.1/data-composition-system/settings') {
				return $child.InnerText
			}
		}
		return $null
	}

	# userFields — пользовательские вычисляемые поля (Expression / Case)
	$ufNode = $settingsNode.SelectSingleNode("dcsset:userFields", $ns)
	if ($ufNode) {
		$ufList = @()
		$ufi = 0
		foreach ($ufItem in $ufNode.SelectNodes("dcsset:item", $ns)) {
			$uxt = Get-LocalXsiType $ufItem
			$entry = [ordered]@{}
			$dp = Get-Text $ufItem "dcsset:dataPath"
			if ($dp) { $entry['dataPath'] = $dp }
			$titleN = $ufItem.SelectSingleNode("dcsset:lwsTitle", $ns)
			$titleV = Get-MLText $titleN
			if ($titleV) { $entry['title'] = $titleV }
			if ($uxt -eq 'UserFieldExpression') {
				$dExN = $ufItem.SelectSingleNode("dcsset:detailExpression", $ns)
				$dEpN = $ufItem.SelectSingleNode("dcsset:detailExpressionPresentation", $ns)
				$tExN = $ufItem.SelectSingleNode("dcsset:totalExpression", $ns)
				$tEpN = $ufItem.SelectSingleNode("dcsset:totalExpressionPresentation", $ns)
				if ($dExN -or $dEpN) {
					$d = [ordered]@{}
					if ($dExN) { $d['expression'] = $dExN.InnerText }
					if ($dEpN) { $d['presentation'] = $dEpN.InnerText }
					$entry['detail'] = $d
				}
				if ($tExN -or $tEpN) {
					$t = [ordered]@{}
					if ($tExN) { $t['expression'] = $tExN.InnerText }
					if ($tEpN) { $t['presentation'] = $tEpN.InnerText }
					$entry['total'] = $t
				}
			} elseif ($uxt -eq 'UserFieldCase') {
				$casesNode = $ufItem.SelectSingleNode("dcsset:cases", $ns)
				$casesArr = @()
				if ($casesNode) {
					foreach ($caseItem in $casesNode.SelectNodes("dcsset:item", $ns)) {
						$ce = [ordered]@{}
						$cfNode = $caseItem.SelectSingleNode("dcsset:filter", $ns)
						if ($cfNode -and $cfNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
							$cfa = @()
							foreach ($cfi in $cfNode.SelectNodes("dcsset:item", $ns)) { $cfa += (Build-FilterItem -itemNode $cfi -loc "variant[$vi]/userField/case/filter") }
							$ce['filter'] = $cfa
						}
						$cvNode = $caseItem.SelectSingleNode("dcsset:value", $ns)
						if ($cvNode) {
							$cvType = Get-LocalXsiType $cvNode
							$cvText = $cvNode.InnerText
							if ($cvType -eq 'boolean') { $ce['value'] = ($cvText -eq 'true') }
							elseif ($cvType -eq 'decimal') {
								if ($cvText -match '^-?\d+$') { $ce['value'] = [int]$cvText }
								else { $ce['value'] = [double]$cvText }
							}
							else { $ce['value'] = $cvText }
						}
						$cpNode = $caseItem.SelectSingleNode("dcsset:lwsPresentationValue", $ns)
						$cpV = Get-MLText $cpNode
						if ($cpV) { $ce['presentation'] = $cpV }
						$casesArr += $ce
					}
				}
				$entry['cases'] = $casesArr
			} else {
				$entry['__unsupported__'] = (New-Sentinel -kind "UserField:$uxt" -loc "variant[$vi]/userField[$ufi]" -detail 'Неизвестный тип пользовательского поля')['__unsupported__']
			}
			$ufList += $entry
			$ufi++
		}
		if ($ufList.Count -gt 0) { $settings['userFields'] = $ufList }
	}

	# selection (top-level)
	$selTop = $settingsNode.SelectSingleNode("dcsset:selection", $ns)
	$selItems = Build-Selection -selNode $selTop -loc "variant[$vi]/selection"
	if ($selItems.Count -gt 0) { $settings['selection'] = $selItems }
	# Block-level viewMode/userSettingID: preserve exact presence (even Normal) for bit-perfect
	$svm = Get-BlockVM $selTop
	if ($null -ne $svm) { $settings['selectionViewMode'] = $svm }
	$susid = Get-BlockUSID $selTop
	if ($susid) { $settings['selectionUserSettingID'] = 'auto' }

	# filter
	$fTop = $settingsNode.SelectSingleNode("dcsset:filter", $ns)
	if ($fTop -and $fTop.SelectNodes("dcsset:item", $ns).Count -gt 0) {
		$fa = @()
		foreach ($fc in $fTop.SelectNodes("dcsset:item", $ns)) { $fa += (Build-FilterItem -itemNode $fc -loc "variant[$vi]/filter") }
		$settings['filter'] = $fa
	}
	$fvm = Get-BlockVM $fTop
	if ($null -ne $fvm) { $settings['filterViewMode'] = $fvm }
	$fusid = Get-BlockUSID $fTop
	if ($fusid) { $settings['filterUserSettingID'] = 'auto' }

	# order
	$ordTop = $settingsNode.SelectSingleNode("dcsset:order", $ns)
	$ordItems = Build-Order -ordNode $ordTop -loc "variant[$vi]/order"
	if ($ordItems.Count -gt 0) { $settings['order'] = $ordItems }
	$ovm = Get-BlockVM $ordTop
	if ($null -ne $ovm) { $settings['orderViewMode'] = $ovm }
	$ousid = Get-BlockUSID $ordTop
	if ($ousid) { $settings['orderUserSettingID'] = 'auto' }

	# conditionalAppearance
	$caTop = $settingsNode.SelectSingleNode("dcsset:conditionalAppearance", $ns)
	if ($caTop) {
		$ca = Build-ConditionalAppearance -caNode $caTop -loc "variant[$vi]/ca"
		if ($ca.Count -gt 0) { $settings['conditionalAppearance'] = $ca }
	}
	$cavm = Get-BlockVM $caTop
	if ($null -ne $cavm) { $settings['conditionalAppearanceViewMode'] = $cavm }
	$causid = Get-BlockUSID $caTop
	if ($causid) { $settings['conditionalAppearanceUserSettingID'] = 'auto' }

	# outputParameters
	$opTop = $settingsNode.SelectSingleNode("dcsset:outputParameters", $ns)
	$op = Build-OutputParameters -opNode $opTop
	if ($op -and $op.Count -gt 0) { $settings['outputParameters'] = $op }

	# dataParameters
	$dpTop = $settingsNode.SelectSingleNode("dcsset:dataParameters", $ns)
	$dp = Build-DataParameters -dpNode $dpTop -topParams $paramsRaw
	if ($null -ne $dp) { $settings['dataParameters'] = $dp }

	# structure — top-level <dcsset:item> children of <dcsset:settings>
	$structItems = Build-Structure -node $settingsNode -loc "variant[$vi]/structure"
	if ($structItems.Count -gt 0) {
		$short = Try-StructureShorthand $structItems
		if ($short) { $settings['structure'] = $short }
		else        { $settings['structure'] = $structItems }
	}

	# <dcsset:itemsViewMode> on settings — preserve presence (even Normal)
	$sivmNode = $settingsNode.SelectSingleNode("dcsset:itemsViewMode", $ns)
	if ($sivmNode) { $settings['itemsViewMode'] = $sivmNode.InnerText }

	# <dcsset:additionalProperties> — key→value свойства варианта (URL, имя, GUID и т.п.)
	$apNode = $settingsNode.SelectSingleNode("dcsset:additionalProperties", $ns)
	if ($apNode) {
		$apDict = [ordered]@{}
		foreach ($prop in $apNode.SelectNodes("v8:Property", $ns)) {
			$pName = $prop.GetAttribute("name")
			$valEl = $prop.SelectSingleNode("v8:Value", $ns)
			if ($pName -and $valEl) { $apDict[$pName] = $valEl.InnerText }
		}
		if ($apDict.Count -gt 0) { $settings['additionalProperties'] = $apDict }
	}

	# Skip pure-default variants: settings contains only "details" structure (or nothing) +
	# name=Основной + no distinctive title.
	$nonStructKeys = @($settings.Keys | Where-Object { $_ -ne 'structure' })
	$structOnlyDetails = (-not $settings.Contains('structure')) -or ($settings['structure'] -eq 'details')
	$isDefault = ($nonStructKeys.Count -eq 0) -and $structOnlyDetails -and ($vname -eq 'Основной') -and (-not $presentation -or $presentation -eq $vname)
	if (-not $isDefault) {
		$entry = [ordered]@{ name = $vname }
		if ($presentation -and $presentation -ne $vname) { $entry['title'] = $presentation }
		$entry['settings'] = $settings
		$settingsVariants += $entry
	}
	$vi++
}
if ($settingsVariants.Count -gt 0) { $out['settingsVariants'] = $settingsVariants }

# --- 7. Serialize ---

$json = ConvertTo-CompactJson -obj $out

if ($OutputPath) {
	$enc = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($OutputPath, $json, $enc)
	Save-UserStyles -dirPath $script:outputDir
	Save-QueryFiles

	if ($script:warnings.Count -gt 0) {
		$wPath = [System.IO.Path]::ChangeExtension($OutputPath, $null).TrimEnd('.') + '.warnings.md'
		$sb = New-Object System.Text.StringBuilder
		[void]$sb.AppendLine("# skd-decompile warnings")
		[void]$sb.AppendLine("")
		[void]$sb.AppendLine("Source: $TemplatePath")
		[void]$sb.AppendLine("")
		foreach ($w in $script:warnings) {
			$wId = $w.id; $wKind = $w.kind; $wLoc = $w.loc; $wDetail = $w.detail
			[void]$sb.AppendLine("- **$wId** ($wKind) at $wLoc — $wDetail")
		}
		[System.IO.File]::WriteAllText($wPath, $sb.ToString(), $enc)
		Write-Host "Warnings: $wPath ($($script:warnings.Count) issue(s))" -ForegroundColor Yellow
	}

	[Console]::Error.WriteLine("Decompiled: dataSets=$($dataSets.Count), calc=$($calculatedFields.Count), totals=$($totalFields.Count), params=$($parameters.Count), templates=$($templates.Count), groupTemplates=$($groupTemplates.Count), variants=$($settingsVariants.Count), warnings=$($script:warnings.Count)")
} else {
	Write-Output $json
	if ($script:warnings.Count -gt 0) {
		[Console]::Error.WriteLine("Warnings ($($script:warnings.Count)):")
		foreach ($w in $script:warnings) {
			[Console]::Error.WriteLine("  $($w.id) [$($w.kind)] $($w.loc): $($w.detail)")
		}
	}
}
