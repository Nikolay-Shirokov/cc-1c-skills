# skd-decompile v0.8 — Decompile 1C DCS Template.xml to JSON DSL (draft)
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

function Get-Text {
	param($node, [string]$xpath)
	if (-not $node) { return $null }
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
	if ($types.Count -eq 0) { return $null }
	$qualN = $valueTypeNode.SelectSingleNode("v8:NumberQualifiers", $ns)
	$qualS = $valueTypeNode.SelectSingleNode("v8:StringQualifiers", $ns)
	$qualD = $valueTypeNode.SelectSingleNode("v8:DateQualifiers", $ns)
	$shorts = @()
	foreach ($t in $types) { $shorts += (Get-OneTypeShorthand -typeNode $t -qualNumber $qualN -qualString $qualS -qualDate $qualD) }
	if ($shorts.Count -eq 1) { return $shorts[0] }
	return ,$shorts
}

# <role> → array of @tokens; if non-simple — null + sentinel via $script:roleSentinel
function Get-RoleTokens {
	param($roleNode, [string]$loc)
	if (-not $roleNode) { return $null }
	$tokens = @()
	$hasComplex = $false
	foreach ($child in $roleNode.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		if ($child.NamespaceURI -ne $NS_COM) { $hasComplex = $true; continue }
		switch ($child.LocalName) {
			'dimension' { if ($child.InnerText -eq 'true') { $tokens += '@dimension' } }
			'account'   { if ($child.InnerText -eq 'true') { $tokens += '@account' } }
			'balance'   { if ($child.InnerText -eq 'true') { $tokens += '@balance' } }
			'periodNumber' {
				# Expect periodNumber=1 + periodType=Main → @period
				$pType = Get-Text $roleNode "dcscom:periodType"
				if ($child.InnerText -eq '1' -and $pType -eq 'Main') { $tokens += '@period' } else { $hasComplex = $true }
			}
			'periodType' { } # handled with periodNumber above
			default {
				$hasComplex = $true
			}
		}
	}
	if ($hasComplex) {
		# emit sentinel separately so caller can attach it to field obj
		$null = New-Sentinel -kind 'ComplexRole' -loc $loc -detail 'Роль с дополнительными атрибутами не сворачивается в @-флаг'
	}
	return $tokens
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
function Get-AppearanceDict {
	param($appNode)
	if (-not $appNode) { return $null }
	$dict = [ordered]@{}
	$items = $appNode.SelectNodes("dcscor:item", $ns)
	foreach ($it in $items) {
		$p = Get-Text $it "dcscor:parameter"
		$valNode = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $p -or -not $valNode) { continue }
		# Value can be xs:string, v8ui:HorizontalAlign, v8:LocalStringType, etc.
		$valType = Get-LocalXsiType $valNode
		if ($valType -eq 'LocalStringType') {
			$dict[$p] = Get-MLText $valNode
		} else {
			$dict[$p] = $valNode.InnerText
		}
	}
	return $dict
}

# Build a field JSON entry (shorthand if possible, object form otherwise)
function Build-Field {
	param($fieldNode, [string]$loc)
	$dataPath = Get-Text $fieldNode "r:dataPath"
	$fieldName = Get-Text $fieldNode "r:field"
	$titleNode = $fieldNode.SelectSingleNode("r:title", $ns)
	$title = Get-MLText $titleNode
	$valueTypeNode = $fieldNode.SelectSingleNode("r:valueType", $ns)
	$typeShort = Get-ValueTypeShorthand $valueTypeNode
	$roleTokens = Get-RoleTokens $fieldNode.SelectSingleNode("r:role", $ns) "$loc/role"
	$restrictTokens = Get-RestrictionTokens $fieldNode.SelectSingleNode("r:useRestriction", $ns)
	$appNode = $fieldNode.SelectSingleNode("r:appearance", $ns)
	$appearance = Get-AppearanceDict $appNode
	$presExpr = Get-Text $fieldNode "r:presentationExpression"

	$needsObject = $title -or $appearance -or $presExpr -or ($typeShort -is [array])

	if (-not $needsObject) {
		# shorthand: "Name: type @role #restrict"
		$parts = @($fieldName)
		if ($typeShort) { $parts[0] = "$fieldName`: $typeShort" }
		if ($roleTokens) { $parts[0] += ' ' + ($roleTokens -join ' ') }
		if ($restrictTokens) { $parts[0] += ' ' + ($restrictTokens -join ' ') }
		# dataPath ≠ field — fall back to object form
		if ($dataPath -and $dataPath -ne $fieldName) {
			# unusual case; use object form
		} else {
			return $parts[0]
		}
	}

	$obj = [ordered]@{ field = $fieldName }
	if ($dataPath -and $dataPath -ne $fieldName) { $obj['dataPath'] = $dataPath }
	if ($title) { $obj['title'] = $title }
	if ($typeShort) { $obj['type'] = $typeShort }
	if ($roleTokens) {
		if ($roleTokens.Count -eq 1) { $obj['role'] = $roleTokens[0] -replace '^@','' }
		else { $obj['role'] = ($roleTokens | ForEach-Object { $_ -replace '^@','' }) }
	}
	if ($restrictTokens) { $obj['restrict'] = ($restrictTokens | ForEach-Object { $_ -replace '^#','' }) }
	if ($presExpr) { $obj['presentationExpression'] = $presExpr }
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
	# Detect Func(<dataPath>) → shorthand "name: Func"
	if ($expression -match '^(\w+)\(([^)]*)\)$') {
		$func = $matches[1]
		$inner = $matches[2].Trim()
		if ($inner -eq $dataPath) {
			return "$dataPath`: $func"
		}
		# "name: Func(expr)" form — also a valid shorthand
		return "$dataPath`: $func($inner)"
	}
	# group attachment via groupItem — Ring 2 / object form
	$groupNodes = $tfNode.SelectNodes("r:group", $ns)
	$obj = [ordered]@{ dataPath = $dataPath; expression = $expression }
	if ($groupNodes -and $groupNodes.Count -gt 0) {
		$groups = @()
		foreach ($g in $groupNodes) { $groups += $g.InnerText }
		$obj['group'] = $groups
	}
	return $obj
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

	# value
	$valueNode = $pNode.SelectSingleNode("r:value", $ns)
	$valueDisplay = $null
	$valueIsNil = $false
	if ($valueNode) {
		$nil = $valueNode.GetAttribute("nil", $NS_XSI)
		if ($nil -eq 'true') { $valueIsNil = $true }
		else {
			$vType = Get-LocalXsiType $valueNode
			if ($vType -eq 'StandardPeriod') {
				$variant = Get-Text $valueNode "v8:variant"
				if ($variant -and $variant -ne 'Custom') { $valueDisplay = $variant }
				# Custom with explicit dates → object form (handled below via needsObject)
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
	$hidden = $availableAsField -eq 'false'
	$denyIncomplete = (Get-Text $pNode "r:denyIncompleteValues") -eq 'true'
	$useAttr = Get-Text $pNode "r:use"
	$useRestriction = (Get-Text $pNode "r:useRestriction") -eq 'true'
	$expression = Get-Text $pNode "r:expression"

	# availableValues
	$avNodes = $pNode.SelectNodes("r:availableValue", $ns)
	$availableValues = @()
	foreach ($av in $avNodes) {
		$avValNode = $av.SelectSingleNode("r:value", $ns)
		$avPresNode = $av.SelectSingleNode("r:presentation", $ns)
		$avEntry = [ordered]@{}
		if ($avValNode) { $avEntry['value'] = $avValNode.InnerText }
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
		denyIncomplete = $denyIncomplete
		useAttr = $useAttr
		useRestriction = $useRestriction
		expression = $expression
		availableValues = $availableValues
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
	if ($titleNeedsObject) { $needsObject = $true }
	if ($typeIsArray) { $needsObject = $true }
	if ($valueIsDict) { $needsObject = $true }
	if (-not $p.autoDates) {
		# @autoDates implies use=Always + denyIncomplete=true defaults — only object form if NOT autoDates
		if ($p.denyIncomplete) { $needsObject = $true }
		if ($p.useAttr) { $needsObject = $true }
	}
	# useRestriction is auto-generated by compile for @hidden params; ignore as object trigger
	if ($p.expression) { $needsObject = $true }

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
	if ($p.useAttr -and -not $p.autoDates) { $obj['use'] = $p.useAttr }
	if ($p.denyIncomplete -and -not $p.autoDates) { $obj['denyIncompleteValues'] = $true }
	if ($p.hidden) { $obj['hidden'] = $true }
	if ($p.valueListAllowed) { $obj['valueListAllowed'] = $true }
	if ($p.autoDates) { $obj['autoDates'] = $true }
	if ($p.expression) { $obj['expression'] = $p.expression }
	if ($p.availableValues -and $p.availableValues.Count -gt 0) { $obj['availableValues'] = $p.availableValues }
	return $obj
}

# --- 3b. Built-in style fingerprints ---

# Fingerprints for built-in styles (header/data/subheader/total).
# Each is the set of "shape-defining" appearance items the style emits.
# Width/Height/merge flags are excluded — they're per-cell.
$script:builtinStyleFingerprints = @{
	'header' = @{
		ЦветФона                 = 'd8p1:ReportHeaderBackColor'
		ЦветГраницы              = 'd8p1:ReportLineColor'
		СтильГраницы             = 'None|0'
		'СтильГраницы.Слева'     = 'Solid|1'
		'СтильГраницы.Сверху'    = 'Solid|1'
		'СтильГраницы.Справа'    = 'Solid|1'
		'СтильГраницы.Снизу'     = 'Solid|1'
		Шрифт                    = 'Arial|10|false|false|false|false'
		ГоризонтальноеПоложение  = 'Center'
		Размещение               = 'Wrap'
	}
	'data' = @{
		ЦветФона                 = 'd8p1:ReportGroup1BackColor'
		ЦветГраницы              = 'd8p1:ReportLineColor'
		СтильГраницы             = 'None|0'
		'СтильГраницы.Слева'     = 'Solid|1'
		'СтильГраницы.Сверху'    = 'Solid|1'
		'СтильГраницы.Справа'    = 'Solid|1'
		'СтильГраницы.Снизу'     = 'Solid|1'
		Шрифт                    = 'Arial|10|false|false|false|false'
	}
	'subheader' = @{
		ЦветГраницы              = 'd8p1:ReportLineColor'
		СтильГраницы             = 'None|0'
		'СтильГраницы.Слева'     = 'Solid|1'
		'СтильГраницы.Сверху'    = 'Solid|1'
		'СтильГраницы.Справа'    = 'Solid|1'
		'СтильГраницы.Снизу'     = 'Solid|1'
		Шрифт                    = 'Arial|10|false|false|false|false'
		ГоризонтальноеПоложение  = 'Center'
	}
	'total' = @{
		ЦветГраницы              = 'd8p1:ReportLineColor'
		СтильГраницы             = 'None|0'
		'СтильГраницы.Слева'     = 'Solid|1'
		'СтильГраницы.Сверху'    = 'Solid|1'
		'СтильГраницы.Справа'    = 'Solid|1'
		'СтильГраницы.Снизу'     = 'Solid|1'
		Шрифт                    = 'Arial|10|false|false|false|false'
	}
}

# Normalize an <dcsat:appearance> node to a hashtable of "shape" keys (excluding
# per-cell items: widths, heights, merge flags, drilldown). Used for style matching.
function Get-AppearanceFingerprint {
	param($appNode)
	$fp = @{}
	if (-not $appNode) { return $fp }
	# Top-level dcscor:item children
	foreach ($it in $appNode.SelectNodes("dcscor:item", $ns)) {
		$pName = Get-Text $it "dcscor:parameter"
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $pName -or -not $val) { continue }
		# Skip per-cell keys
		if ($pName -in @('МинимальнаяШирина','МаксимальнаяШирина','МинимальнаяВысота','ОбъединятьПоВертикали','ОбъединятьПоГоризонтали','Расшифровка')) { continue }
		$valType = Get-LocalXsiType $val
		switch ($valType) {
			'Color'    { $fp[$pName] = $val.InnerText }
			'Line'     {
				$w = $val.GetAttribute("width")
				$styleNode = $val.SelectSingleNode("v8ui:style", $ns)
				$lineStyle = if ($styleNode) { $styleNode.InnerText } else { '' }
				$fp[$pName] = "$lineStyle|$w"
			}
			'Font'     {
				$face = $val.GetAttribute("faceName")
				$h = $val.GetAttribute("height")
				$b = $val.GetAttribute("bold")
				$i = $val.GetAttribute("italic")
				$u = $val.GetAttribute("underline")
				$s = $val.GetAttribute("strikeout")
				$fp[$pName] = "$face|$h|$b|$i|$u|$s"
			}
			default    { $fp[$pName] = $val.InnerText }
		}
		# Nested sub-items under СтильГраницы (left/top/right/bottom)
		foreach ($sub in $it.SelectNodes("dcscor:item", $ns)) {
			$subName = Get-Text $sub "dcscor:parameter"
			$subVal = $sub.SelectSingleNode("dcscor:value", $ns)
			if (-not $subName -or -not $subVal) { continue }
			$subType = Get-LocalXsiType $subVal
			if ($subType -eq 'Line') {
				$w = $subVal.GetAttribute("width")
				$styleNode = $subVal.SelectSingleNode("v8ui:style", $ns)
				$lineStyle = if ($styleNode) { $styleNode.InnerText } else { '' }
				$fp[$subName] = "$lineStyle|$w"
			}
		}
	}
	# Translate d8p1: colors to canonical "d8p1:Name" form (InnerText already contains prefix)
	return $fp
}

# Check if appearance fingerprint matches a built-in style.
# Returns style name or $null.
function Match-BuiltinStyle {
	param($fp)
	foreach ($styleName in $script:builtinStyleFingerprints.Keys) {
		$expected = $script:builtinStyleFingerprints[$styleName]
		$match = $true
		# All expected keys must be present with matching value
		foreach ($k in $expected.Keys) {
			if (-not $fp.ContainsKey($k) -or $fp[$k] -ne $expected[$k]) { $match = $false; break }
		}
		if (-not $match) { continue }
		# Must not have extra keys that aren't in the expected fingerprint
		$extras = @($fp.Keys | Where-Object { -not $expected.ContainsKey($_) })
		if ($extras.Count -ne 0) { continue }
		return $styleName
	}
	return $null
}

# Extract per-cell width/minHeight/merge from appearance.
function Get-CellPerCellAttrs {
	param($appNode)
	$attrs = @{ width = $null; height = $null; mergeV = $false; mergeH = $false; drilldown = $null }
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
				# value xsi:type=dcscor:Parameter pointing to Расшифровка_X
				if ($val) {
					$paramRef = $val.InnerText
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
	$detectedStyle = $null
	$styleMismatch = $false
	$drilldownByParam = @{}   # param name → field name (X from Расшифровка_X)

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

			# Style detection (skip empty cells with no appearance, and merge cells)
			if ($appNode -and -not $perCell.mergeV -and -not $perCell.mergeH) {
				$fp = Get-AppearanceFingerprint $appNode
				$matched = Match-BuiltinStyle $fp
				if ($null -eq $detectedStyle) {
					$detectedStyle = $matched
				} elseif ($matched -ne $detectedStyle) {
					$styleMismatch = $true
				}
			}

			# Drilldown attachment
			if ($content -match '^\{(.+)\}$' -and $perCell.drilldown) {
				$drilldownByParam[$matches[1]] = $perCell.drilldown
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

	# Template parameters (and drilldown folding)
	$paramNodes = $templateNode.SelectNodes("r:parameter", $ns)
	$exprParams = [ordered]@{}
	$detailParams = @{}
	foreach ($pn in $paramNodes) {
		$pType = Get-LocalXsiType $pn
		$pName = Get-Text $pn "dcsat:name"
		if ($pType -eq 'ExpressionAreaTemplateParameter') {
			$exprParams[$pName] = Get-Text $pn "dcsat:expression"
		} elseif ($pType -eq 'DetailsAreaTemplateParameter') {
			# Name format: Расшифровка_<X>
			if ($pName -match '^Расшифровка_(.+)$') {
				$detailParams[$matches[1]] = $true
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

	# Decide output form
	if ($detectedStyle -and -not $styleMismatch) {
		$tmplObj['style'] = $detectedStyle
	} elseif ($styleMismatch -or ($null -eq $detectedStyle -and $rows.Count -gt 0)) {
		# Couldn't unify style — emit sentinel
		$tmplObj['__unsupported__'] = (New-Sentinel -kind 'TemplateStyleMismatch' -loc $loc -detail 'Шаблон содержит ячейки с непокрытым/неоднородным оформлением (Кольцо 2)')['__unsupported__']
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
		return [ordered]@{ group = $groupName; items = $items }
	}
	if ($xtype -ne 'FilterItemComparison') {
		return (New-Sentinel -kind "FilterItemType:$xtype" -loc $loc -detail 'Неизвестный тип фильтра')
	}
	$leftNode = $itemNode.SelectSingleNode("dcsset:left", $ns)
	$field = if ($leftNode) { $leftNode.InnerText } else { $null }
	$ct = Get-Text $itemNode "dcsset:comparisonType"
	$op = $script:filterOpMap[$ct]
	if (-not $op) { $op = $ct }
	$rightNode = $itemNode.SelectSingleNode("dcsset:right", $ns)
	$value = Get-FilterValue $rightNode

	$use = Get-Text $itemNode "dcsset:use"
	$userId = Get-Text $itemNode "dcsset:userSettingID"
	$viewMode = Get-Text $itemNode "dcsset:viewMode"
	$userPresNode = $itemNode.SelectSingleNode("dcsset:userSettingPresentation", $ns)

	$flags = @()
	if ($use -eq 'false') { $flags += '@off' }
	if ($userId) { $flags += '@user' }
	if ($viewMode -eq 'QuickAccess') { $flags += '@quickAccess' }
	elseif ($viewMode -eq 'Normal') { $flags += '@normal' }
	elseif ($viewMode -eq 'Inaccessible') { $flags += '@inaccessible' }

	# nullity ops have no value
	$noValueOps = @('filled','notFilled')

	if ($userPresNode) {
		# object form
		$obj = [ordered]@{ field = $field; op = $op }
		if ($op -notin $noValueOps -and $null -ne $value) { $obj['value'] = $value }
		if ($use -eq 'false') { $obj['use'] = $false }
		if ($userId) { $obj['userSettingID'] = 'auto' }
		if ($viewMode) { $obj['viewMode'] = $viewMode }
		$obj['userSettingPresentation'] = Get-MLText $userPresNode
		return $obj
	}

	# shorthand
	$s = $field
	if ($op -in $noValueOps) {
		$s += " $op"
	} else {
		$s += " $op $value"
	}
	if ($flags) { $s += ' ' + ($flags -join ' ') }
	return $s
}

# Build selection items array
function Build-Selection {
	param($selNode, [string]$loc)
	if (-not $selNode) { return @() }
	$out = @()
	foreach ($it in $selNode.SelectNodes("dcsset:item", $ns)) {
		$xt = Get-LocalXsiType $it
		# Implicit SelectedItemField: <dcsset:item> without xsi:type but with <dcsset:field> child.
		# Платформа эмитит это в conditionalAppearance/selection.
		if (-not $xt) {
			$fName = Get-Text $it "dcsset:field"
			if ($fName) { $out += $fName; continue }
		}
		switch ($xt) {
			'SelectedItemAuto'   { $out += 'Auto' }
			'SelectedItemField'  { $out += (Get-Text $it "dcsset:field") }
			'SelectedItemFolder' {
				$titleNode = $it.SelectSingleNode("dcsset:lwsTitle", $ns)
				$folderTitle = Get-MLText $titleNode
				$inner = @()
				foreach ($sub in $it.SelectNodes("dcsset:item", $ns)) {
					$st = Get-LocalXsiType $sub
					if (-not $st) {
						$subF = Get-Text $sub "dcsset:field"
						if ($subF) { $inner += $subF; continue }
					}
					if ($st -eq 'SelectedItemField')      { $inner += (Get-Text $sub "dcsset:field") }
					elseif ($st -eq 'SelectedItemAuto')   { $inner += 'Auto' }
					else { $inner += (New-Sentinel -kind "SelectionInFolder:$st" -loc "$loc/folder" -detail 'Неизвестный тип элемента папки выбора') }
				}
				$out += [ordered]@{ folder = $folderTitle; items = $inner }
			}
			default {
				$out += (New-Sentinel -kind "SelectionItem:$xt" -loc $loc -detail 'Неизвестный тип элемента selection')
			}
		}
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
				if ($ot -eq 'Desc') { $out += "$fn desc" } else { $out += $fn }
			}
			default { $out += (New-Sentinel -kind "OrderItem:$xt" -loc $loc -detail 'Неизвестный тип сортировки') }
		}
	}
	return ,$out
}

# Build appearance dict from <dcsset:appearance> or <dcscor:item> list
function Get-SettingsAppearance {
	param($appNode)
	if (-not $appNode) { return $null }
	$dict = [ordered]@{}
	foreach ($it in $appNode.SelectNodes("dcscor:item", $ns)) {
		$pName = Get-Text $it "dcscor:parameter"
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $pName -or -not $val) { continue }
		$valType = Get-LocalXsiType $val
		if ($valType -eq 'LocalStringType') {
			$dict[$pName] = Get-MLText $val
		} else {
			$dict[$pName] = $val.InnerText
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
		$pres = Get-Text $it "dcsset:presentation"
		if ($pres) { $entry['presentation'] = $pres }
		$vm = Get-Text $it "dcsset:viewMode"
		if ($vm) { $entry['viewMode'] = $vm }
		$usid = Get-Text $it "dcsset:userSettingID"
		if ($usid) { $entry['userSettingID'] = 'auto' }
		$out += $entry
		$i++
	}
	return ,$out
}

# Build outputParameters dict
function Build-OutputParameters {
	param($opNode)
	if (-not $opNode) { return $null }
	$d = [ordered]@{}
	foreach ($it in $opNode.SelectNodes("dcscor:item", $ns)) {
		$pName = Get-Text $it "dcscor:parameter"
		$val = $it.SelectSingleNode("dcscor:value", $ns)
		if (-not $pName -or -not $val) { continue }
		$vType = Get-LocalXsiType $val
		if ($vType -eq 'LocalStringType') { $d[$pName] = Get-MLText $val }
		else { $d[$pName] = $val.InnerText }
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
		$use = Get-Text $it "dcsset:use"
		$tp = $visibleTop[$pn]
		$flags = @()
		if ($usid) { $flags += '@user' }
		if ($use -eq 'false') { $flags += '@off' }
		$vt = Get-LocalXsiType $valNode
		$vDisplay = $null
		if ($vt -eq 'StandardPeriod') {
			$variant = Get-Text $valNode "v8:variant"
			if ($variant -and $variant -ne 'Custom') { $vDisplay = $variant }
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
		# Build shorthand entry
		$s = $pn
		if ($null -ne $vDisplay -and $vDisplay -ne '') { $s += " = $vDisplay" }
		if ($flags) { $s += ' ' + ($flags -join ' ') }
		$entries += $s
	}
	# Check that all visible top-level params are present
	foreach ($vn in $visibleTop.Keys) { if (-not $presentNames.ContainsKey($vn)) { $canAuto = $false } }
	if ($canAuto) { return 'auto' }
	return ,$entries
}

# Read groupItems -> array of field names (with periodAddition/groupType warnings)
function Get-GroupFields {
	param($parentNode, [string]$loc)
	$gFields = @()
	$gi = $parentNode.SelectSingleNode("dcsset:groupItems", $ns)
	if (-not $gi) { return ,$gFields }
	foreach ($gItem in $gi.SelectNodes("dcsset:item", $ns)) {
		$gxt = Get-LocalXsiType $gItem
		if ($gxt -eq 'GroupItemField') {
			$gf = Get-Text $gItem "dcsset:field"
			$pat = Get-Text $gItem "dcsset:periodAdditionType"
			$gt = Get-Text $gItem "dcsset:groupType"
			if (($pat -and $pat -ne 'None') -or ($gt -and $gt -ne 'Items')) {
				$null = Add-Warning -kind 'GroupItemDetails' -loc "$loc/groupItems" -detail "Группировка $gf использует groupType=$gt, periodAdditionType=$pat — не воспроизводится в shorthand"
			}
			$gFields += $gf
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
	if ($includeName) {
		$nm = Get-Text $node "dcsset:name"
		if ($nm) { $entry['name'] = $nm }
	}
	$gf = Get-GroupFields -parentNode $node -loc $loc
	if ($gf.Count -gt 0) { $entry['groupFields'] = $gf }
	$ordNode = $node.SelectSingleNode("dcsset:order", $ns)
	$ordItems = Build-Order -ordNode $ordNode -loc "$loc/order"
	if ($ordItems.Count -gt 0 -and -not ($ordItems.Count -eq 1 -and $ordItems[0] -eq 'Auto')) {
		$entry['order'] = $ordItems
	}
	$selNode = $node.SelectSingleNode("dcsset:selection", $ns)
	$selItems = Build-Selection -selNode $selNode -loc "$loc/selection"
	if ($selItems.Count -gt 0 -and -not ($selItems.Count -eq 1 -and $selItems[0] -eq 'Auto')) {
		$entry['selection'] = $selItems
	}
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
			$items += $entry
			$idx++
			continue
		}
		if ($xt -eq 'StructureItemChart') {
			$entry = [ordered]@{ type = 'chart' }
			$nm = Get-Text $it "dcsset:name"
			if ($nm) { $entry['name'] = $nm }
			$pn = $it.SelectSingleNode("dcsset:point", $ns)
			if ($pn) { $entry['points'] = Build-TableAxisBlock -node $pn -loc "$loc/$idx/point" }
			$sn = $it.SelectSingleNode("dcsset:series", $ns)
			if ($sn) { $entry['series'] = Build-TableAxisBlock -node $sn -loc "$loc/$idx/series" }
			$selN = $it.SelectSingleNode("dcsset:selection", $ns)
			$selI = Build-Selection -selNode $selN -loc "$loc/$idx/selection"
			if ($selI.Count -gt 0 -and -not ($selI.Count -eq 1 -and $selI[0] -eq 'Auto')) {
				$entry['selection'] = $selI
			}
			$opN = $it.SelectSingleNode("dcsset:outputParameters", $ns)
			$op = Build-OutputParameters -opNode $opN
			if ($op -and $op.Count -gt 0) { $entry['outputParameters'] = $op }
			$items += $entry
			$idx++
			continue
		}
		if ($xt -ne 'StructureItemGroup') {
			$items += (New-Sentinel -kind "StructureItem:$xt" -loc $loc -detail 'Тип структуры пока не покрыт')
			$idx++
			continue
		}
		$entry = [ordered]@{}
		# Optional name
		$nm = Get-Text $it "dcsset:name"
		if ($nm) { $entry['name'] = $nm }
		# groupItems → groupFields
		$gi = $it.SelectSingleNode("dcsset:groupItems", $ns)
		$gFields = @()
		if ($gi) {
			foreach ($gItem in $gi.SelectNodes("dcsset:item", $ns)) {
				$gxt = Get-LocalXsiType $gItem
				if ($gxt -eq 'GroupItemField') {
					$gf = Get-Text $gItem "dcsset:field"
					# Look at periodAdditionType — non-None or non-default → sentinel
					$pat = Get-Text $gItem "dcsset:periodAdditionType"
					$gt = Get-Text $gItem "dcsset:groupType"
					if (($pat -and $pat -ne 'None') -or ($gt -and $gt -ne 'Items')) {
						# Non-default grouping — record but don't fail
						# We still emit the field; flag in warnings only
						$null = Add-Warning -kind 'GroupItemDetails' -loc "$loc/groupItems" -detail "Группировка $gf использует groupType=$gt, periodAdditionType=$pat — не воспроизводится в shorthand"
					}
					$gFields += $gf
				} else {
					$gFields += (New-Sentinel -kind "GroupItem:$gxt" -loc "$loc/groupItems" -detail 'Тип элемента группировки не покрыт')
				}
			}
		}
		if ($gFields.Count -gt 0) { $entry['groupFields'] = $gFields }

		# Local selection — only emit if not "[Auto]" default
		$selNode = $it.SelectSingleNode("dcsset:selection", $ns)
		$selItems = Build-Selection -selNode $selNode -loc "$loc/selection"
		if ($selItems.Count -gt 0 -and -not ($selItems.Count -eq 1 -and $selItems[0] -eq 'Auto')) {
			$entry['selection'] = $selItems
		}
		# Local order
		$ordNode = $it.SelectSingleNode("dcsset:order", $ns)
		$ordItems = Build-Order -ordNode $ordNode -loc "$loc/order"
		if ($ordItems.Count -gt 0 -and -not ($ordItems.Count -eq 1 -and $ordItems[0] -eq 'Auto')) {
			$entry['order'] = $ordItems
		}
		# Local filter
		$filterNode = $it.SelectSingleNode("dcsset:filter", $ns)
		if ($filterNode -and $filterNode.SelectNodes("dcsset:item", $ns).Count -gt 0) {
			$f = @()
			foreach ($fc in $filterNode.SelectNodes("dcsset:item", $ns)) { $f += (Build-FilterItem -itemNode $fc -loc "$loc/filter") }
			$entry['filter'] = $f
		}

		# Children — recursive
		$children = Build-Structure -node $it -loc "$loc/children"
		if ($children.Count -gt 0) { $entry['children'] = $children }

		$items += $entry
		$idx++
	}
	return ,$items
}

# Try to fold a structure tree into string shorthand "A > B > details".
# Conditions: linear chain (each level has exactly one child), each level is
# a plain group with single groupField and no local selection/order/filter.
function Try-StructureShorthand {
	param($items)
	if ($items.Count -ne 1) { return $null }
	$parts = @()
	$cur = $items[0]
	while ($null -ne $cur) {
		# Disallow extras
		if ($cur.Contains('type') -and $cur['type'] -ne 'group') { return $null }
		if ($cur.Contains('name')) { return $null }
		if ($cur.Contains('selection')) { return $null }
		if ($cur.Contains('order')) { return $null }
		if ($cur.Contains('filter')) { return $null }
		$gfs = $cur['groupFields']
		if ($null -eq $gfs -or $gfs.Count -eq 0) {
			# details level (terminal)
			$parts += 'details'
			break
		}
		if ($gfs.Count -ne 1) { return $null }
		$parts += $gfs[0]
		$children = $cur['children']
		if ($null -eq $children -or $children.Count -eq 0) { break }
		if ($children.Count -ne 1) { return $null }
		$cur = $children[0]
	}
	return ($parts -join ' > ')
}

# --- 4. dataSources ---

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
			$ds['query'] = Get-Text $dsNode "r:query"
		}
		'DataSetObject' {
			$ds['objectName'] = Get-Text $dsNode "r:objectName"
		}
		'DataSetUnion' {
			$nested = @()
			$ni = 0
			foreach ($nNode in $dsNode.SelectNodes("r:dataSet", $ns)) {
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
			if ($fxsi -ne 'DataSetFieldField') {
				$fields += (New-Sentinel -kind "FieldType:$fxsi" -loc "$loc/field[$fi]" -detail 'Тип поля не DataSetFieldField')
			} else {
				$fields += (Build-Field -fieldNode $fn -loc "$loc/field[$fi]")
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
	if ($startMatch -and $endMatch) {
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

	# selection (top-level)
	$selTop = $settingsNode.SelectSingleNode("dcsset:selection", $ns)
	$selItems = Build-Selection -selNode $selTop -loc "variant[$vi]/selection"
	if ($selItems.Count -gt 0) { $settings['selection'] = $selItems }

	# filter
	$fTop = $settingsNode.SelectSingleNode("dcsset:filter", $ns)
	if ($fTop -and $fTop.SelectNodes("dcsset:item", $ns).Count -gt 0) {
		$fa = @()
		foreach ($fc in $fTop.SelectNodes("dcsset:item", $ns)) { $fa += (Build-FilterItem -itemNode $fc -loc "variant[$vi]/filter") }
		$settings['filter'] = $fa
	}

	# order
	$ordTop = $settingsNode.SelectSingleNode("dcsset:order", $ns)
	$ordItems = Build-Order -ordNode $ordTop -loc "variant[$vi]/order"
	if ($ordItems.Count -gt 0) { $settings['order'] = $ordItems }

	# conditionalAppearance
	$caTop = $settingsNode.SelectSingleNode("dcsset:conditionalAppearance", $ns)
	if ($caTop) {
		$ca = Build-ConditionalAppearance -caNode $caTop -loc "variant[$vi]/ca"
		if ($ca.Count -gt 0) { $settings['conditionalAppearance'] = $ca }
	}

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

$json = $out | ConvertTo-Json -Depth 32

# Unescape \uXXXX → UTF-8 literals
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
	param($m)
	[char][int]("0x" + $m.Groups[1].Value)
})

if ($OutputPath) {
	if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
		$OutputPath = Join-Path (Get-Location).Path $OutputPath
	}
	$enc = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($OutputPath, $json, $enc)

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
