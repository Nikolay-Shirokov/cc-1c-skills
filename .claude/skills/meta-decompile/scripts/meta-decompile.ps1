# meta-decompile v0.5 — XML объекта метаданных 1С → JSON-черновик формата meta-compile
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
#
# Пилот: только Catalog. Инверс meta-compile (omit-on-default: ключ эмитим только
# когда значение в XML отличается от умолчания компилятора). Неподдерживаемый тип / не-MetaDataObject
# root → exit 3 (ring3, как form-decompile).
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$ObjectPath,

	[string]$OutputPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $ObjectPath)) {
	[Console]::Error.WriteLine("meta-decompile: файл не найден: $ObjectPath"); exit 2
}

# --- JSON-эмиттер (контроль порядка/массивов/кириллицы) ---
function ConvertTo-CompactJson {
	param($node, [int]$depth = 0)
	$pad = "  " * $depth
	$pad1 = "  " * ($depth + 1)
	if ($null -eq $node) { return "null" }
	if ($node -is [bool]) { return $(if ($node) { "true" } else { "false" }) }
	if ($node -is [int] -or $node -is [long] -or $node -is [double]) { return "$node" }
	if ($node -is [System.Collections.IDictionary]) {
		if ($node.Count -eq 0) { return "{}" }
		$items = @()
		foreach ($k in $node.Keys) {
			$items += "$pad1$(Quote-Json ([string]$k)): $(ConvertTo-CompactJson $node[$k] ($depth + 1))"
		}
		return "{`n" + ($items -join ",`n") + "`n$pad}"
	}
	if ($node -is [System.Collections.IList]) {
		if ($node.Count -eq 0) { return "[]" }
		# Массив скаляров-строк — компактно в строку; массив объектов — по строкам.
		$allScalar = $true
		foreach ($e in $node) { if ($e -is [System.Collections.IDictionary] -or $e -is [System.Collections.IList]) { $allScalar = $false; break } }
		if ($allScalar) {
			$items = @(); foreach ($e in $node) { $items += (ConvertTo-CompactJson $e ($depth + 1)) }
			return "[" + ($items -join ", ") + "]"
		}
		$items = @(); foreach ($e in $node) { $items += "$pad1$(ConvertTo-CompactJson $e ($depth + 1))" }
		return "[`n" + ($items -join ",`n") + "`n$pad]"
	}
	return Quote-Json ([string]$node)
}
function Quote-Json {
	param([string]$s)
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.Append('"')
	foreach ($ch in $s.ToCharArray()) {
		switch ($ch) {
			'"'  { [void]$sb.Append('\"') }
			'\'  { [void]$sb.Append('\\') }
			"`n" { [void]$sb.Append('\n') }
			"`r" { [void]$sb.Append('\r') }
			"`t" { [void]$sb.Append('\t') }
			default {
				if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
				else { [void]$sb.Append($ch) }
			}
		}
	}
	[void]$sb.Append('"')
	return $sb.ToString()
}

# --- XML загрузка + namespace manager ---
$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $false
$doc.Load((Resolve-Path -LiteralPath $ObjectPath).Path)
$nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$nsm.AddNamespace('md',  'http://v8.1c.ru/8.3/MDClasses')
$nsm.AddNamespace('v8',  'http://v8.1c.ru/8.1/data/core')
$nsm.AddNamespace('xr',  'http://v8.1c.ru/8.3/xcf/readable')
$nsm.AddNamespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')

$rootEl = $doc.DocumentElement
if ($rootEl.LocalName -ne 'MetaDataObject') {
	[Console]::Error.WriteLine("meta-decompile: ожидался root <MetaDataObject>, получен <$($rootEl.LocalName)>"); exit 3
}
# Первый элемент-потомок MetaDataObject = объект; его LocalName = тип.
$objNode = $null
foreach ($c in $rootEl.ChildNodes) { if ($c.NodeType -eq 'Element') { $objNode = $c; break } }
if (-not $objNode) { [Console]::Error.WriteLine("meta-decompile: пустой MetaDataObject"); exit 3 }
$objType = $objNode.LocalName

if ($objType -ne 'Catalog') {
	[Console]::Error.WriteLine("meta-decompile: тип '$objType' пока не поддержан (пилот — только Catalog)"); exit 3
}

$props = $objNode.SelectSingleNode('md:Properties', $nsm)
function P { param([string]$tag) $n = $props.SelectSingleNode("md:$tag", $nsm); if ($n) { return $n.InnerText } else { return $null } }

# --- Synonym (ru) ---
function Get-MLru {
	param($node)
	if (-not $node) { return $null }
	$it = $node.SelectSingleNode("v8:item[v8:lang='ru']/v8:content", $nsm)
	if ($it) { return $it.InnerText }
	return $null
}
# ML-значение → строка (если единственный item ru) ЛИБО [ordered]{lang:content} (мультиязычно, порядок из XML).
# null если контента нет. Компактная строка для ru-only, объект для мультиязычных.
function Get-MLValue {
	param($node)
	if (-not $node) { return $null }
	$items = @($node.SelectNodes('v8:item', $nsm))
	if ($items.Count -eq 0) { return $null }
	if ($items.Count -eq 1) {
		$lang = $items[0].SelectSingleNode('v8:lang', $nsm).InnerText
		$content = $items[0].SelectSingleNode('v8:content', $nsm).InnerText
		if ($lang -eq 'ru') { return $content }
	}
	$o = [ordered]@{}
	foreach ($it in $items) {
		$l = $it.SelectSingleNode('v8:lang', $nsm).InnerText
		$c = $it.SelectSingleNode('v8:content', $nsm).InnerText
		$o[$l] = $c
	}
	return $o
}
# Авто-синоним: точное зеркало Split-CamelCase из meta-compile (стр.354). Совпало → ключ опускаем.
# ВАЖНО: логика должна совпадать байт-в-байт с компилятором, иначе ложные «синоним==авто» → диффы.
function Split-CamelWords {
	param([string]$name)
	if (-not $name) { return $name }
	$result = [regex]::Replace($name, '([а-яё])([А-ЯЁ])', '$1 $2')
	$result = [regex]::Replace($result, '([a-z])([A-Z])', '$1 $2')
	if ($result.Length -gt 1) { $result = $result.Substring(0,1) + $result.Substring(1).ToLower() }
	return $result
}

$objName = P 'Name'

# --- Тип реквизита: <Type> → shorthand-строка ---
function Strip-NsPrefix { param([string]$s) if ($s -match ':') { return ($s -split ':', 2)[1] } else { return $s } }
function Get-TypeShorthand {
	param($typeNode)
	if (-not $typeNode) { return "" }
	$parts = @()
	$children = @($typeNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
	for ($i = 0; $i -lt $children.Count; $i++) {
		$c = $children[$i]
		$ln = $c.LocalName
		if ($ln -eq 'Type') {
			$raw = $c.InnerText.Trim()
			$next = if ($i + 1 -lt $children.Count) { $children[$i+1] } else { $null }
			switch -regex ($raw) {
				'(^|:)boolean$'    { $parts += 'Boolean'; break }
				'(^|:)string$'     {
					$len = '10'
					if ($next -and $next.LocalName -eq 'StringQualifiers') { $l = $next.SelectSingleNode('v8:Length', $nsm); if ($l) { $len = $l.InnerText } }
					$parts += "String($len)"; break
				}
				'(^|:)decimal$'    {
					$d = '10'; $f = '0'; $sign = ''
					if ($next -and $next.LocalName -eq 'NumberQualifiers') {
						$dn = $next.SelectSingleNode('v8:Digits', $nsm); if ($dn) { $d = $dn.InnerText }
						$fn = $next.SelectSingleNode('v8:FractionDigits', $nsm); if ($fn) { $f = $fn.InnerText }
						$sn = $next.SelectSingleNode('v8:AllowedSign', $nsm); if ($sn -and $sn.InnerText -eq 'Nonnegative') { $sign = ',nonneg' }
					}
					$parts += "Number($d,$f$sign)"; break
				}
				'(^|:)dateTime$'   {
					$fr = 'DateTime'
					if ($next -and $next.LocalName -eq 'DateQualifiers') { $dn = $next.SelectSingleNode('v8:DateFractions', $nsm); if ($dn) { $fr = $dn.InnerText } }
					$parts += $fr; break   # Date | DateTime
				}
				'(^|:)base64Binary$' { $parts += 'ValueStorage'; break }
				default            { $parts += (Strip-NsPrefix $raw) }   # cfg:CatalogRef.X → CatalogRef.X
			}
		} elseif ($ln -eq 'TypeSet') {
			$parts += (Strip-NsPrefix $c.InnerText.Trim())   # cfg:DefinedType.X → DefinedType.X
		}
	}
	return ($parts -join ' + ')
}

# --- Реквизит → DSL: shorthand-строка "Имя: Тип | флаги" ЛИБО object-форма при кастомном синониме.
# (Синоним ≠ авто → object {name, type, synonym, [flags]}; иначе компактный shorthand.) ---
function Attr-ToDsl {
	param($attrNode)
	$ap = $attrNode.SelectSingleNode('md:Properties', $nsm)
	$nm = ($ap.SelectSingleNode('md:Name', $nsm)).InnerText
	$ts = Get-TypeShorthand ($ap.SelectSingleNode('md:Type', $nsm))
	$flags = @()
	$fc = $ap.SelectSingleNode('md:FillChecking', $nsm); if ($fc -and $fc.InnerText -eq 'ShowError') { $flags += 'req' }
	$ix = $ap.SelectSingleNode('md:Indexing', $nsm)
	if ($ix) { if ($ix.InnerText -eq 'Index') { $flags += 'index' } elseif ($ix.InnerText -eq 'IndexWithAdditionalOrder') { $flags += 'indexAdditional' } }
	$ml = $ap.SelectSingleNode('md:MultiLine', $nsm); if ($ml -and $ml.InnerText -eq 'true') { $flags += 'multiline' }

	# Синоним/подсказка (строка ru-only ИЛИ {ru,en}). Кастомный синоним ИЛИ наличие подсказки → object-форма.
	$synVal = Get-MLValue ($ap.SelectSingleNode('md:Synonym', $nsm))
	$synCustom = $false
	if ($synVal -is [string]) { if ($synVal -ne (Split-CamelWords $nm)) { $synCustom = $true } }
	elseif ($null -ne $synVal) { $synCustom = $true }   # {ru,en} = всегда кастом
	$ttVal = Get-MLValue ($ap.SelectSingleNode('md:ToolTip', $nsm))

	if ($synCustom -or ($null -ne $ttVal)) {
		$o = [ordered]@{ name = $nm }
		if ($ts) { $o['type'] = $ts }
		if ($synCustom) { $o['synonym'] = $synVal }
		if ($null -ne $ttVal) { $o['tooltip'] = $ttVal }
		if ($flags.Count -gt 0) { $o['flags'] = [System.Collections.ArrayList]@($flags) }
		return $o
	}
	$head = if ($ts) { "${nm}: $ts" } else { $nm }
	if ($flags.Count -gt 0) { return "$head | " + ($flags -join ', ') }
	return $head
}

# === Сборка DSL ===
$dsl = [ordered]@{ type = 'Catalog'; name = $objName }

$syn = Get-MLru ($props.SelectSingleNode('md:Synonym', $nsm))
if ($syn -and $syn -ne (Split-CamelWords $objName)) { $dsl['synonym'] = $syn }
$cmt = P 'Comment'; if ($cmt) { $dsl['comment'] = $cmt }

# Свойства Catalog (omit-on-default). Порядок ключей — как удобно DSL.
function Add-BoolProp { param([string]$key, [string]$tag, [bool]$default) $v = P $tag; if ($null -ne $v) { $b = ($v -eq 'true'); if ($b -ne $default) { $dsl[$key] = $b } } }
function Add-EnumProp { param([string]$key, [string]$tag, [string]$default) $v = P $tag; if ($null -ne $v -and $v -ne '' -and $v -ne $default) { $dsl[$key] = $v } }
function Add-IntProp  { param([string]$key, [string]$tag, [int]$default) $v = P $tag; if ($null -ne $v -and $v -ne '') { $iv = [int]$v; if ($iv -ne $default) { $dsl[$key] = $iv } } }

Add-BoolProp 'hierarchical'   'Hierarchical'   $false
Add-EnumProp 'hierarchyType'  'HierarchyType'  'HierarchyFoldersAndItems'
Add-BoolProp 'limitLevelCount' 'LimitLevelCount' $false
Add-IntProp  'levelCount'     'LevelCount'     2
Add-BoolProp 'foldersOnTop'   'FoldersOnTop'   $true
# owners
$ownersNode = $props.SelectSingleNode('md:Owners', $nsm)
if ($ownersNode) {
	$items = @($ownersNode.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
	if ($items.Count -gt 0) { $dsl['owners'] = [System.Collections.ArrayList]@($items | ForEach-Object { if ($_ -match '^Catalog\.') { ($_ -split '\.', 2)[1] } else { $_ } }) }
}
Add-EnumProp 'subordinationUse' 'SubordinationUse' 'ToItems'
Add-IntProp  'codeLength'        'CodeLength'        9
Add-IntProp  'descriptionLength' 'DescriptionLength' 25
Add-EnumProp 'codeType'          'CodeType'          'String'
Add-EnumProp 'codeAllowedLength' 'CodeAllowedLength' 'Variable'
Add-BoolProp 'autonumbering'     'Autonumbering'     $true
Add-BoolProp 'checkUnique'       'CheckUnique'       $false
Add-EnumProp 'codeSeries'        'CodeSeries'        'WholeCatalog'
Add-EnumProp 'defaultPresentation' 'DefaultPresentation' 'AsDescription'
Add-BoolProp 'quickChoice'       'QuickChoice'       $false
Add-EnumProp 'choiceMode'        'ChoiceMode'        'BothWays'
Add-EnumProp 'dataLockControlMode' 'DataLockControlMode' 'Automatic'
Add-EnumProp 'fullTextSearch'    'FullTextSearch'    'Use'

# --- StandardAttributes: блок есть ⟺ кастомизация ≥1 стандартного реквизита.
# Захватываем ОТКЛОНЕНИЯ от профиля материализованного блока (профиль компилятор восстановит сам).
# Профиль Catalog: Owner{FC=ShowError,FFV=true}, Parent{FFV=true}, Description{FC=ShowError}. ---
$catStdProfile = @{
	'Owner'       = @{ fillChecking = 'ShowError'; fillFromFillingValue = $true }
	'Parent'      = @{ fillFromFillingValue = $true }
	'Description'  = @{ fillChecking = 'ShowError' }
}
$saNode = $props.SelectSingleNode('md:StandardAttributes', $nsm)
if ($saNode) {
	$saMap = [ordered]@{}
	foreach ($sa in @($saNode.SelectNodes('xr:StandardAttribute', $nsm))) {
		$an = $sa.GetAttribute('name')
		$prof = if ($catStdProfile.ContainsKey($an)) { $catStdProfile[$an] } else { @{} }
		$ov = [ordered]@{}
		# FillChecking (профиль или DontCheck)
		$fcN = $sa.SelectSingleNode('xr:FillChecking', $nsm); $fc = if ($fcN) { $fcN.InnerText } else { 'DontCheck' }
		$profFc = if ($prof.ContainsKey('fillChecking')) { $prof['fillChecking'] } else { 'DontCheck' }
		if ($fc -ne $profFc) { $ov['fillChecking'] = $fc }
		# FillFromFillingValue (профиль или false)
		$ffvN = $sa.SelectSingleNode('xr:FillFromFillingValue', $nsm); $ffv = ($ffvN -and $ffvN.InnerText -eq 'true')
		$profFfv = ($prof['fillFromFillingValue'] -eq $true)
		if ($ffv -ne $profFfv) { $ov['fillFromFillingValue'] = $ffv }
		# Synonym (профиль пуст)
		$syn = Get-MLru ($sa.SelectSingleNode('xr:Synonym', $nsm))
		if ($syn) { $ov['synonym'] = $syn }
		# FullTextSearch / DataHistory (профиль = Use)
		$ftsN = $sa.SelectSingleNode('xr:FullTextSearch', $nsm); if ($ftsN -and $ftsN.InnerText -ne 'Use') { $ov['fullTextSearch'] = $ftsN.InnerText }
		$dhN = $sa.SelectSingleNode('xr:DataHistory', $nsm); if ($dhN -and $dhN.InnerText -ne 'Use') { $ov['dataHistory'] = $dhN.InnerText }
		if ($ov.Count -gt 0) { $saMap[$an] = $ov }
	}
	$dsl['standardAttributes'] = $saMap   # даже пустой = блок есть (чистый профиль)
}

# --- ChildObjects: Attributes + TabularSections ---
$childObjs = $objNode.SelectSingleNode('md:ChildObjects', $nsm)
if ($childObjs) {
	$attrs = @($childObjs.SelectNodes('md:Attribute', $nsm))
	if ($attrs.Count -gt 0) {
		$arr = [System.Collections.ArrayList]@()
		foreach ($a in $attrs) { [void]$arr.Add((Attr-ToDsl $a)) }
		$dsl['attributes'] = $arr
	}
	$tsNodes = @($childObjs.SelectNodes('md:TabularSection', $nsm))
	if ($tsNodes.Count -gt 0) {
		$tsMap = [ordered]@{}
		foreach ($ts in $tsNodes) {
			$tsp = $ts.SelectSingleNode('md:Properties', $nsm)
			$tsName = ($tsp.SelectSingleNode('md:Name', $nsm)).InnerText
			$tco = $ts.SelectSingleNode('md:ChildObjects', $nsm)
			$cols = [System.Collections.ArrayList]@()
			if ($tco) { foreach ($ca in @($tco.SelectNodes('md:Attribute', $nsm))) { [void]$cols.Add((Attr-ToDsl $ca)) } }
			$tsMap[$tsName] = $cols
		}
		$dsl['tabularSections'] = $tsMap
	}
}

# --- Предопределённые (соседний Ext/Predefined.xml) → DSL predefined.
# Плоский элемент → строка "(Код) Имя [Наименование]" (Наименование: ==авто → опустить; '' → []; иначе [текст]).
# Группа/иерархия → object {name, [code], [description], isFolder, childItems}. codeType — из свойства каталога. ---
$objDir = Split-Path -Parent (Resolve-Path -LiteralPath $ObjectPath).Path
$predefPath = Join-Path (Join-Path (Join-Path $objDir $objName) 'Ext') 'Predefined.xml'
if (Test-Path -LiteralPath $predefPath) {
	$pdoc = New-Object System.Xml.XmlDocument
	$pdoc.Load($predefPath)
	function PredefItem-ToDsl {
		param($itemEl)
		$name = ($itemEl.SelectSingleNode("*[local-name()='Name']")).InnerText
		$codeEl = $itemEl.SelectSingleNode("*[local-name()='Code']")
		$code = if ($codeEl -and $codeEl.InnerText) { $codeEl.InnerText } else { '' }
		$descEl = $itemEl.SelectSingleNode("*[local-name()='Description']")
		$desc = if ($descEl) { $descEl.InnerText } else { '' }
		$folderEl = $itemEl.SelectSingleNode("*[local-name()='IsFolder']")
		$isFolder = ($folderEl -and $folderEl.InnerText -eq 'true')
		$childContainer = $itemEl.SelectSingleNode("*[local-name()='ChildItems']")
		# ВАЖНО: обернуть весь if в @(), иначе PS распаковывает одноэлементный @(...) из if-блока
		# обратно в узел → $kids.Count = $null → папки с ОДНИМ ребёнком теряют его.
		$kids = @(if ($childContainer) { $childContainer.SelectNodes("*[local-name()='Item']") } else { @() })
		$auto = Split-CamelWords $name

		if (-not $isFolder -and $kids.Count -eq 0) {
			# Плоский → компактная строка.
			$s = if ($code) { "($code) $name" } else { $name }
			if ($desc -eq '') { $s = "$s []" }
			elseif ($desc -ne $auto) { $s = "$s [$desc]" }
			return $s
		}
		# Группа/иерархия → объект.
		$o = [ordered]@{ name = $name }
		if ($code) { $o['code'] = $code }
		if ($desc -eq '') { $o['description'] = '' }
		elseif ($desc -ne $auto) { $o['description'] = $desc }
		if ($isFolder) { $o['isFolder'] = $true }
		if ($kids.Count -gt 0) {
			$sub = [System.Collections.ArrayList]@()
			foreach ($k in $kids) { [void]$sub.Add((PredefItem-ToDsl $k)) }
			$o['childItems'] = $sub
		}
		return $o
	}
	$rootItems = [System.Collections.ArrayList]@()
	foreach ($it in @($pdoc.DocumentElement.SelectNodes("*[local-name()='Item']"))) { [void]$rootItems.Add((PredefItem-ToDsl $it)) }
	if ($rootItems.Count -gt 0) { $dsl['predefined'] = $rootItems }
}

# === Вывод ===
$json = ConvertTo-CompactJson $dsl 0
if ($OutputPath) {
	[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
} else {
	[Console]::Out.WriteLine($json)
}
