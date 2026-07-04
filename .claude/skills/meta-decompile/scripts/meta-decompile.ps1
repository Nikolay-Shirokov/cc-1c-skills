# meta-decompile v0.17 — XML объекта метаданных 1С → JSON-черновик формата meta-compile
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
$nsm.AddNamespace('app', 'http://v8.1c.ru/8.2/managed-application/core')

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
		# Единственный ru-item: пустое содержимое ≡ отсутствие значения → $null (иначе tooltip:"" ≠ self-close).
		if ($lang -eq 'ru') { if ($content -eq '') { return $null } else { return $content } }
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

# Скалярное значение параметра выбора (<Value xsi:type=...>) → JSON-значение (bool/число/строка).
# string/dateTime/DesignTimeRef → строка (компилятор auto-детектит обратно).
function Convert-ChScalarNode {
	param($vN)
	$xt = $vN.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
	$txt = $vN.InnerText
	if ($xt -match 'boolean$') { return ($txt -eq 'true') }
	if ($xt -match 'decimal$') {
		if ($txt -match '^-?\d+$') { return [int]$txt }
		return [double]::Parse($txt, [System.Globalization.CultureInfo]::InvariantCulture)
	}
	return $txt
}
# app:value (тип прямо на узле) → значение ЛИБО массив (v8:FixedArray с детьми v8:Value).
function Get-ChoiceParamValue {
	param($valNode)
	$xt = $valNode.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
	if ($xt -match 'FixedArray$') {
		$arr = [System.Collections.ArrayList]@()
		foreach ($sub in @($valNode.SelectNodes('v8:Value', $nsm))) { [void]$arr.Add((Convert-ChScalarNode $sub)) }
		return $arr
	}
	return Convert-ChScalarNode $valNode
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

	# Синоним/подсказка (строка ru-only ИЛИ {ru,en}).
	$synVal = Get-MLValue ($ap.SelectSingleNode('md:Synonym', $nsm))
	$synCustom = $false
	if ($synVal -is [string]) { if ($synVal -ne (Split-CamelWords $nm)) { $synCustom = $true } }
	elseif ($null -ne $synVal) { $synCustom = $true }   # {ru,en} = всегда кастом
	$ttVal = Get-MLValue ($ap.SelectSingleNode('md:ToolTip', $nsm))

	# Extra-свойства реквизита (omit-on-default). Наличие любого → object-форма.
	# $en(tag) → InnerText узла или $null.
	$en = { param($tag) $n = $ap.SelectSingleNode("md:$tag", $nsm); if ($n) { $n.InnerText } else { $null } }
	$extra = [ordered]@{}
	$v = & $en 'Comment'; if ($v) { $extra['comment'] = $v }
	$v = & $en 'FullTextSearch'; if ($v -and $v -ne 'Use') { $extra['fullTextSearch'] = $v }
	$v = & $en 'FillFromFillingValue'; if ($v -eq 'true') { $extra['fillFromFillingValue'] = $true }
	$v = & $en 'CreateOnInput'; if ($v -and $v -ne 'Auto') { $extra['createOnInput'] = $v }
	$v = & $en 'QuickChoice'; if ($v -and $v -ne 'Auto') { $extra['quickChoice'] = $v }
	$v = & $en 'DataHistory'; if ($v -and $v -ne 'Use') { $extra['dataHistory'] = $v }
	$v = & $en 'Use'; if ($v -and $v -ne 'ForItem') { $extra['use'] = $v }
	$v = & $en 'PasswordMode'; if ($v -eq 'true') { $extra['passwordMode'] = $true }
	$v = & $en 'Mask'; if ($v) { $extra['mask'] = $v }
	$v = & $en 'ChoiceHistoryOnInput'; if ($v -and $v -ne 'Auto') { $extra['choiceHistoryOnInput'] = $v }
	$v = & $en 'FillChecking'; if ($v -eq 'ShowWarning') { $extra['fillChecking'] = 'ShowWarning' }
	$fmtV = Get-MLValue ($ap.SelectSingleNode('md:Format', $nsm)); if ($null -ne $fmtV) { $extra['format'] = $fmtV }
	$efmtV = Get-MLValue ($ap.SelectSingleNode('md:EditFormat', $nsm)); if ($null -ne $efmtV) { $extra['editFormat'] = $efmtV }

	# FillValue (значение заполнения). Форма по умолчанию зависит от типа реквизита: String→typed-empty,
	# Number→zero, всё остальное→nil. Эмитим `fillValue` только при отклонении от дефолта (§4.2 spec).
	# nil у String/Number → JSON null (nil-override); реальное значение → строка/bool/число/DTR-путь verbatim.
	$fvNode = $ap.SelectSingleNode('md:FillValue', $nsm)
	if ($fvNode) {
		$fcat = 'Other'
		if ($ts -match '\+') { $fcat = 'Other' }
		elseif ($ts -match '^Boolean') { $fcat = 'Boolean' }
		elseif ($ts -match '^String') { $fcat = 'String' }
		elseif ($ts -match '^Number') { $fcat = 'Number' }
		elseif ($ts -match '^(Date|DateTime)') { $fcat = 'Date' }
		$nilAttr = $fvNode.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance')
		$xsiT = $fvNode.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
		$fvText = $fvNode.InnerText
		if ($nilAttr -eq 'true') {
			if ($fcat -eq 'String' -or $fcat -eq 'Number') { $extra['fillValue'] = $null }  # nil-override
			# иначе nil — это дефолт → пропускаем
		} elseif ($xsiT -match 'boolean$') {
			$extra['fillValue'] = ($fvText -eq 'true')
		} elseif ($xsiT -match 'decimal$') {
			if (-not ($fcat -eq 'Number' -and ($fvText -eq '0' -or $fvText -eq ''))) { $extra['fillValue'] = $fvText }
		} elseif ($xsiT -match 'string$') {
			if (-not ($fcat -eq 'String' -and $fvText -eq '')) { $extra['fillValue'] = $fvText }
		} elseif ($xsiT -match 'dateTime$') {
			$extra['fillValue'] = $fvText
		} elseif ($xsiT -match 'DesignTimeRef$') {
			$extra['fillValue'] = $fvText
		}
	}

	# LinkByType (связь по типу): DataPath + LinkItem. Пусто → пропускаем. linkItem=0 → компактно строкой.
	$lbtNode = $ap.SelectSingleNode('md:LinkByType', $nsm)
	if ($lbtNode) {
		$dpN = $lbtNode.SelectSingleNode('xr:DataPath', $nsm)
		if ($dpN -and $dpN.InnerText) {
			$liN = $lbtNode.SelectSingleNode('xr:LinkItem', $nsm)
			$li = if ($liN -and $liN.InnerText) { [int]$liN.InnerText } else { 0 }
			if ($li -eq 0) { $extra['linkByType'] = $dpN.InnerText }
			else { $extra['linkByType'] = [ordered]@{ dataPath = $dpN.InnerText; linkItem = $li } }
		}
	}

	# ChoiceParameterLinks — [{name, dataPath, valueChange?}]. valueChange=Clear → компактно строкой "name=dataPath".
	$cplNode = $ap.SelectSingleNode('md:ChoiceParameterLinks', $nsm)
	if ($cplNode) {
		$links = @($cplNode.SelectNodes('xr:Link', $nsm))
		if ($links.Count -gt 0) {
			$arr = [System.Collections.ArrayList]@()
			foreach ($lk in $links) {
				$lName = $lk.SelectSingleNode('xr:Name', $nsm).InnerText
				$lDp = $lk.SelectSingleNode('xr:DataPath', $nsm).InnerText
				$vcN = $lk.SelectSingleNode('xr:ValueChange', $nsm)
				$vcv = if ($vcN) { $vcN.InnerText } else { 'Clear' }
				if ($vcv -eq 'Clear') { [void]$arr.Add("$lName=$lDp") }
				else { [void]$arr.Add([ordered]@{ name = $lName; dataPath = $lDp; valueChange = $vcv }) }
			}
			$extra['choiceParameterLinks'] = $arr
		}
	}

	# ChoiceParameters — [{name, value?}]. app:value nil → без value; иначе типизированное значение.
	$cpNode = $ap.SelectSingleNode('md:ChoiceParameters', $nsm)
	if ($cpNode) {
		$items = @($cpNode.SelectNodes('app:item', $nsm))
		if ($items.Count -gt 0) {
			$arr = [System.Collections.ArrayList]@()
			foreach ($it in $items) {
				$pName = $it.GetAttribute('name')
				$valN = $it.SelectSingleNode('app:value', $nsm)
				$nilAttr = if ($valN) { $valN.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') } else { '' }
				if (-not $valN -or $nilAttr -eq 'true') {
					[void]$arr.Add([ordered]@{ name = $pName })
				} else {
					$o = [ordered]@{ name = $pName }
					$o['value'] = Get-ChoiceParamValue $valN
					[void]$arr.Add($o)
				}
			}
			$extra['choiceParameters'] = $arr
		}
	}

	if ($synCustom -or ($null -ne $ttVal) -or $extra.Count -gt 0) {
		$o = [ordered]@{ name = $nm }
		if ($ts) { $o['type'] = $ts }
		if ($synCustom) { $o['synonym'] = $synVal }
		if ($null -ne $ttVal) { $o['tooltip'] = $ttVal }
		foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
		if ($flags.Count -gt 0) { $o['flags'] = [System.Collections.ArrayList]@($flags) }
		return $o
	}
	$head = if ($ts) { "${nm}: $ts" } else { $nm }
	if ($flags.Count -gt 0) { return "$head | " + ($flags -join ', ') }
	return $head
}

# === Сборка DSL ===
$dsl = [ordered]@{ type = 'Catalog'; name = $objName }

# Синоним объекта: строка ru-only ИЛИ {ru,en} (мультиязычно). Кастом → эмитим.
$synVal = Get-MLValue ($props.SelectSingleNode('md:Synonym', $nsm))
if ($synVal -is [string]) { if ($synVal -ne (Split-CamelWords $objName)) { $dsl['synonym'] = $synVal } }
elseif ($null -ne $synVal) { $dsl['synonym'] = $synVal }
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
Add-BoolProp 'useStandardCommands' 'UseStandardCommands' $true
Add-EnumProp 'createOnInput'     'CreateOnInput'     'Use'
Add-EnumProp 'editType'          'EditType'          'InDialog'
Add-BoolProp 'includeHelpInContents' 'IncludeHelpInContents' $false
Add-EnumProp 'choiceHistoryOnInput' 'ChoiceHistoryOnInput' 'Auto'
Add-EnumProp 'predefinedDataUpdate' 'PredefinedDataUpdate' 'Auto'
Add-EnumProp 'searchStringModeOnInputByString' 'SearchStringModeOnInputByString' 'Begin'

# Формы по умолчанию (компилятор пишет пусто → omit-on-empty; значение = ссылка на форму verbatim).
function Add-FormRef { param([string]$key, [string]$tag) $v = P $tag; if ($v) { $dsl[$key] = $v } }
Add-FormRef 'defaultObjectForm'         'DefaultObjectForm'
Add-FormRef 'defaultFolderForm'         'DefaultFolderForm'
Add-FormRef 'defaultListForm'           'DefaultListForm'
Add-FormRef 'defaultChoiceForm'         'DefaultChoiceForm'
Add-FormRef 'defaultFolderChoiceForm'   'DefaultFolderChoiceForm'
Add-FormRef 'auxiliaryObjectForm'       'AuxiliaryObjectForm'
Add-FormRef 'auxiliaryFolderForm'       'AuxiliaryFolderForm'
Add-FormRef 'auxiliaryListForm'         'AuxiliaryListForm'
Add-FormRef 'auxiliaryChoiceForm'       'AuxiliaryChoiceForm'
Add-FormRef 'auxiliaryFolderChoiceForm' 'AuxiliaryFolderChoiceForm'

# Презентации (ML, компилятор пишет пусто → omit-on-empty).
foreach ($pp in @(
	@('ObjectPresentation','objectPresentation'), @('ExtendedObjectPresentation','extendedObjectPresentation'),
	@('ListPresentation','listPresentation'), @('ExtendedListPresentation','extendedListPresentation'),
	@('Explanation','explanation'))) {
	$pv = Get-MLValue ($props.SelectSingleNode("md:$($pp[0])", $nsm))
	if ($null -ne $pv) { $dsl[$pp[1]] = $pv }
}

# --- Characteristics (привязка ПВХ). Короткая форма: поля bare/partial, filterValue без каталога, from полный.
function Shorten-CharField { param([string]$full, [string]$from)
	if ($full.StartsWith("$from.")) {
		$rest = $full.Substring($from.Length + 1)
		if ($rest -match '^StandardAttribute\.(Ref|Parent|Owner)$') { return $Matches[1] }  # ссылочные станд. → голое
		if ($rest -match '^Attribute\.(.+)$') { return $Matches[1] }                        # кастом → голое
		return $rest   # прочие StandardAttribute.X / Dimension.X / Resource.X → частичное (безопасно)
	}
	return $full
}
$charsNode = $props.SelectSingleNode('md:Characteristics', $nsm)
if ($charsNode) {
	$chList = @($charsNode.SelectNodes('xr:Characteristic', $nsm))
	if ($chList.Count -gt 0) {
		$chArr = [System.Collections.ArrayList]@()
		foreach ($ch in $chList) {
			$ct = $ch.SelectSingleNode('xr:CharacteristicTypes', $nsm)
			$cv = $ch.SelectSingleNode('xr:CharacteristicValues', $nsm)
			$tFrom = $ct.GetAttribute('from'); $vFrom = $cv.GetAttribute('from')
			$gt = { param($n, $node) $x = $node.SelectSingleNode("xr:$n", $nsm); if ($x) { $x.InnerText } else { "" } }
			$giv = { param($n, $node) $x = $node.SelectSingleNode("xr:$n", $nsm); if ($x -and $x.InnerText -ne '') { [int]$x.InnerText } else { -1 } }
			$tfvNode = $ct.SelectSingleNode('xr:TypesFilterValue', $nsm)
			$tfvNil = if ($tfvNode) { $tfvNode.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') } else { '' }
			$types = [ordered]@{
				from = $tFrom
				key = Shorten-CharField (& $gt 'KeyField' $ct) $tFrom
				filterField = Shorten-CharField (& $gt 'TypesFilterField' $ct) $tFrom
				filterValue = if ($tfvNil -eq 'true') { $null } else { Convert-ChScalarNode $tfvNode }
			}
			$dpf = & $giv 'DataPathField' $ct; if ($dpf -ne -1) { $types['dataPathField'] = $dpf }
			$mvu = & $giv 'MultipleValuesUseField' $ct; if ($mvu -ne -1) { $types['multipleValuesUseField'] = $mvu }
			$values = [ordered]@{
				from = $vFrom
				object = Shorten-CharField (& $gt 'ObjectField' $cv) $vFrom
				type = Shorten-CharField (& $gt 'TypeField' $cv) $vFrom
				value = Shorten-CharField (& $gt 'ValueField' $cv) $vFrom
			}
			$mvk = & $giv 'MultipleValuesKeyField' $cv; if ($mvk -ne -1) { $values['multipleValuesKeyField'] = $mvk }
			$mvo = & $giv 'MultipleValuesOrderField' $cv; if ($mvo -ne -1) { $values['multipleValuesOrderField'] = $mvo }
			[void]$chArr.Add([ordered]@{ types = $types; values = $values })
		}
		$dsl['characteristics'] = $chArr
	}
}

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
		# Synonym / ToolTip (профиль пуст) — строка ru | {ru,en}
		$syn = Get-MLValue ($sa.SelectSingleNode('xr:Synonym', $nsm))
		if ($null -ne $syn) { $ov['synonym'] = $syn }
		$tt = Get-MLValue ($sa.SelectSingleNode('xr:ToolTip', $nsm))
		if ($null -ne $tt) { $ov['tooltip'] = $tt }
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
			# Синоним/подсказка/комментарий ТЧ. Кастом → объектная форма {synonym?, tooltip?, comment?, attributes}.
			$tsSyn = Get-MLValue ($tsp.SelectSingleNode('md:Synonym', $nsm))
			$tsSynCustom = $false
			if ($tsSyn -is [string]) { if ($tsSyn -ne (Split-CamelWords $tsName)) { $tsSynCustom = $true } }
			elseif ($null -ne $tsSyn) { $tsSynCustom = $true }
			$tsTt = Get-MLValue ($tsp.SelectSingleNode('md:ToolTip', $nsm))
			$tsCmtN = $tsp.SelectSingleNode('md:Comment', $nsm); $tsCmt = if ($tsCmtN) { $tsCmtN.InnerText } else { '' }
			if ($tsSynCustom -or ($null -ne $tsTt) -or $tsCmt) {
				$to = [ordered]@{}
				if ($tsSynCustom) { $to['synonym'] = $tsSyn }
				if ($null -ne $tsTt) { $to['tooltip'] = $tsTt }
				if ($tsCmt) { $to['comment'] = $tsCmt }
				$to['attributes'] = $cols
				$tsMap[$tsName] = $to
			} else {
				$tsMap[$tsName] = $cols
			}
		}
		$dsl['tabularSections'] = $tsMap
	}
	# --- Commands (полноблочные <Command> в ChildObjects) → DSL commands (map имя→объект, omit-on-default).
	# Тела модулей команд (CommandModule.bsl) — вне скоупа (как ObjectModule). ---
	$cmdNodes = @($childObjs.SelectNodes('md:Command', $nsm))
	if ($cmdNodes.Count -gt 0) {
		$cmdMap = [ordered]@{}
		foreach ($cm in $cmdNodes) {
			$cp = $cm.SelectSingleNode('md:Properties', $nsm)
			$cn = ($cp.SelectSingleNode('md:Name', $nsm)).InnerText
			$o = [ordered]@{}
			$syn = Get-MLValue ($cp.SelectSingleNode('md:Synonym', $nsm))
			if ($syn -is [string]) { if ($syn -ne (Split-CamelWords $cn)) { $o['synonym'] = $syn } }
			elseif ($null -ne $syn) { $o['synonym'] = $syn }
			$cmtN = $cp.SelectSingleNode('md:Comment', $nsm); if ($cmtN -and $cmtN.InnerText) { $o['comment'] = $cmtN.InnerText }
			$grpN = $cp.SelectSingleNode('md:Group', $nsm); if ($grpN -and $grpN.InnerText) { $o['group'] = $grpN.InnerText }
			$cpt = Get-TypeShorthand ($cp.SelectSingleNode('md:CommandParameterType', $nsm)); if ($cpt) { $o['commandParameterType'] = $cpt }
			$pumN = $cp.SelectSingleNode('md:ParameterUseMode', $nsm); if ($pumN -and $pumN.InnerText -ne 'Single') { $o['parameterUseMode'] = $pumN.InnerText }
			$mdN = $cp.SelectSingleNode('md:ModifiesData', $nsm); if ($mdN -and $mdN.InnerText -eq 'true') { $o['modifiesData'] = $true }
			$repN = $cp.SelectSingleNode('md:Representation', $nsm); if ($repN -and $repN.InnerText -ne 'Auto') { $o['representation'] = $repN.InnerText }
			$ctt = Get-MLValue ($cp.SelectSingleNode('md:ToolTip', $nsm)); if ($null -ne $ctt) { $o['tooltip'] = $ctt }
			$picN = $cp.SelectSingleNode('md:Picture', $nsm); if ($picN -and $picN.InnerText) { $o['picture'] = $picN.InnerText }
			$scN = $cp.SelectSingleNode('md:Shortcut', $nsm); if ($scN -and $scN.InnerText) { $o['shortcut'] = $scN.InnerText }
			$osuN = $cp.SelectSingleNode('md:OnMainServerUnavalableBehavior', $nsm); if ($osuN -and $osuN.InnerText -ne 'Auto') { $o['onMainServerUnavalableBehavior'] = $osuN.InnerText }
			$cmdMap[$cn] = $o
		}
		$dsl['commands'] = $cmdMap
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
