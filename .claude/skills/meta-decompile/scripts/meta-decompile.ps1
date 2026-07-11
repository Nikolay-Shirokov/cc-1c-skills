# meta-decompile v0.54 — XML объекта метаданных 1С → JSON-черновик формата meta-compile
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
#
# Поддержаны: Catalog, ExchangePlan, ChartOfCharacteristicTypes, ChartOfAccounts, ChartOfCalculationTypes, Document,
# InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister, BusinessProcess, Task, Enum. Инверс meta-compile (omit-on-default: ключ эмитим только
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
$doc.PreserveWhitespace = $true
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

if ($objType -notin @('Catalog', 'ExchangePlan', 'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes', 'Document', 'InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister', 'BusinessProcess', 'Task', 'Enum', 'Report', 'DataProcessor', 'Constant', 'DefinedType', 'FunctionalOption', 'DocumentJournal', 'Sequence', 'FilterCriterion', 'DocumentNumerator', 'SettingsStorage', 'CommonModule', 'EventSubscription', 'ScheduledJob', 'CommonForm', 'SessionParameter', 'CommonCommand', 'CommandGroup', 'CommonAttribute', 'FunctionalOptionsParameter', 'WSReference', 'CommonPicture', 'CommonTemplate')) {
	[Console]::Error.WriteLine("meta-decompile: тип '$objType' пока не поддержан (…, CommonPicture, CommonTemplate)"); exit 3
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
	# HE-эвристика (зеркало Split-CamelCase компилятора): сохраняем прогон заглавных >=2, если сразу за ним
	# НЕ буква (пробел/цифра/спецсимвол/конец); прилипшие предлоги/бренды перед буквой → лоуэркейз. Первый символ — как есть.
	if ($result.Length -gt 1) {
		$chars = $result.ToCharArray()
		$n = $chars.Length
		$keep = New-Object 'bool[]' $n
		$i = 0
		while ($i -lt $n) {
			if ([char]::IsUpper($chars[$i])) {
				$j = $i
				while ($j -lt $n -and [char]::IsUpper($chars[$j])) { $j++ }
				$afterBoundary = ($j -eq $n) -or (-not [char]::IsLetter($chars[$j]))
				if (($j - $i) -ge 2 -and $afterBoundary) { for ($k = $i; $k -lt $j; $k++) { $keep[$k] = $true } }
				$i = $j
			} else { $i++ }
		}
		$sb = New-Object System.Text.StringBuilder
		for ($idx = 0; $idx -lt $n; $idx++) {
			$c = $chars[$idx]
			if ($idx -eq 0 -or $keep[$idx]) { [void]$sb.Append($c) }
			elseif ([char]::IsUpper($c)) { [void]$sb.Append([char]::ToLower($c)) }
			else { [void]$sb.Append($c) }
		}
		$result = $sb.ToString()
	}
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
					$len = '10'; $al = ''
					$sq = if ($next -and $next.LocalName -eq 'StringQualifiers') { $next } else { $typeNode.SelectSingleNode('v8:StringQualifiers', $nsm) }
					if ($sq) {
						$l = $sq.SelectSingleNode('v8:Length', $nsm); if ($l) { $len = $l.InnerText }
						$aln = $sq.SelectSingleNode('v8:AllowedLength', $nsm); if ($aln -and $aln.InnerText -eq 'Fixed') { $al = ',fixed' }
					}
					$parts += "String($len$al)"; break
				}
				'(^|:)decimal$'    {
					$d = '10'; $f = '0'; $sign = ''
					$nq = if ($next -and $next.LocalName -eq 'NumberQualifiers') { $next } else { $typeNode.SelectSingleNode('v8:NumberQualifiers', $nsm) }
					if ($nq) {
						$dn = $nq.SelectSingleNode('v8:Digits', $nsm); if ($dn) { $d = $dn.InnerText }
						$fn = $nq.SelectSingleNode('v8:FractionDigits', $nsm); if ($fn) { $f = $fn.InnerText }
						$sn = $nq.SelectSingleNode('v8:AllowedSign', $nsm); if ($sn -and $sn.InnerText -eq 'Nonnegative') { $sign = ',nonneg' }
					}
					$parts += "Number($d,$f$sign)"; break
				}
				'(^|:)dateTime$'   {
					$fr = 'DateTime'
					$dq = if ($next -and $next.LocalName -eq 'DateQualifiers') { $next } else { $typeNode.SelectSingleNode('v8:DateQualifiers', $nsm) }
					if ($dq) { $dn = $dq.SelectSingleNode('v8:DateFractions', $nsm); if ($dn) { $fr = $dn.InnerText } }
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
		return ,$arr   # унарная запятая: PS иначе разворачивает 1-элементную коллекцию при return → FixedArray станет скаляром
	}
	return Convert-ChScalarNode $valNode
}

# <ChoiceParameterLinks> → [{name,dataPath,valueChange?}] | строки "name=dataPath". $tag: 'md:...' (реквизит) | 'xr:...' (станд.).
function Parse-ChoiceParameterLinks {
	param($parent, [string]$tag)
	$node = $parent.SelectSingleNode($tag, $nsm)
	if (-not $node) { return $null }
	$links = @($node.SelectNodes('xr:Link', $nsm))
	if ($links.Count -eq 0) { return $null }
	$arr = [System.Collections.ArrayList]@()
	foreach ($lk in $links) {
		$lName = $lk.SelectSingleNode('xr:Name', $nsm).InnerText
		$lDp = $lk.SelectSingleNode('xr:DataPath', $nsm).InnerText
		$vcN = $lk.SelectSingleNode('xr:ValueChange', $nsm); $vcv = if ($vcN) { $vcN.InnerText } else { 'Clear' }
		if ($vcv -eq 'Clear') { [void]$arr.Add("$lName=$lDp") }
		else { [void]$arr.Add([ordered]@{ name = $lName; dataPath = $lDp; valueChange = $vcv }) }
	}
	return $arr
}
# <ChoiceParameters> → [{name,value?}]. $tag: 'md:...' | 'xr:...'.
function Parse-ChoiceParameters {
	param($parent, [string]$tag)
	$node = $parent.SelectSingleNode($tag, $nsm)
	if (-not $node) { return $null }
	$items = @($node.SelectNodes('app:item', $nsm))
	if ($items.Count -eq 0) { return $null }
	$arr = [System.Collections.ArrayList]@()
	foreach ($it in $items) {
		$pName = $it.GetAttribute('name')
		$valN = $it.SelectSingleNode('app:value', $nsm)
		$nilAttr = if ($valN) { $valN.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') } else { '' }
		if (-not $valN -or $nilAttr -eq 'true') { [void]$arr.Add([ordered]@{ name = $pName }) }
		else { $o = [ordered]@{ name = $pName }; $o['value'] = Get-ChoiceParamValue $valN; [void]$arr.Add($o) }
	}
	return $arr
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
	$synNode = $ap.SelectSingleNode('md:Synonym', $nsm)
	$synVal = Get-MLValue $synNode
	$synCustom = $false
	# Пустой <Synonym/> (узел есть, значения нет) ≠ авто-синоним из имени → явный пустой (synonym:"").
	# У Catalog-реквизитов не встречается (0/4018), у части ExchangePlan — да.
	$synEmpty = ($synNode -and $null -eq $synVal)
	if ($synVal -is [string]) { if ($synVal -cne (Split-CamelWords $nm)) { $synCustom = $true } }
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
	$v = & $en 'ExtendedEdit'; if ($v -eq 'true') { $extra['extendedEdit'] = $true }
	$v = & $en 'MarkNegatives'; if ($v -eq 'true') { $extra['markNegatives'] = $true }
	$v = & $en 'ChoiceFoldersAndItems'; if ($v -and $v -ne 'Items') { $extra['choiceFoldersAndItems'] = $v }
	$v = & $en 'ChoiceForm'; if ($v) { $extra['choiceForm'] = $v }
	# Регистро-специфика измерения (теги присутствуют только у Dimension → безвредно для прочих).
	$v = & $en 'Master'; if ($v -eq 'true') { $extra['master'] = $true }
	$v = & $en 'MainFilter'; if ($v -eq 'true') { $extra['mainFilter'] = $true }
	$v = & $en 'DenyIncompleteValues'; if ($v -eq 'true') { $extra['denyIncompleteValues'] = $true }
	$v = & $en 'UseInTotals'; if ($v -eq 'false') { $extra['useInTotals'] = $false }  # дефолт true → захват при false
	$v = & $en 'BaseDimension'; if ($v -eq 'true') { $extra['baseDimension'] = $true }
	$v = & $en 'ScheduleLink'; if ($v) { $extra['scheduleLink'] = $v }  # ссылка на измерение графика (пустой → пропуск)
	$v = & $en 'Balance'; if ($v -eq 'true') { $extra['balance'] = $true }
	$v = & $en 'AccountingFlag'; if ($v) { $extra['accountingFlag'] = $v }  # ссылка на признак учёта ПС (пустой → пропуск)
	$v = & $en 'ExtDimensionAccountingFlag'; if ($v) { $extra['extDimensionAccountingFlag'] = $v }
	$v = & $en 'AddressingDimension'; if ($v) { $extra['addressingDimension'] = $v }  # ссылка на измерение регистра исполнителей
	# MinValue/MaxValue — граница диапазона (omit при nil). Тип сохраняем: xs:string→строка, xs:decimal→число.
	foreach ($mm in @('MinValue','MaxValue')) {
		$mn = $ap.SelectSingleNode("md:$mm", $nsm)
		if (-not $mn) { continue }
		if ($mn.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') -eq 'true') { continue }
		$key = if ($mm -eq 'MinValue') { 'minValue' } else { 'maxValue' }
		$xt = $mn.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
		$txt = $mn.InnerText
		if ($xt -match 'decimal|int|double|float') {
			if ($txt -match '^-?\d+$') { $extra[$key] = [long]$txt } else { $extra[$key] = [double]$txt }
		} else { $extra[$key] = $txt }
	}
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
			# Захватываем как ЧИСЛО (не строку): на составном типе компилятор берёт xsi-тип из JSON-значения —
			# строка "0" дала бы xs:string, число 0 → xs:decimal. У плоского Number эмиссия и так type-aware.
			if (-not ($fcat -eq 'Number' -and ($fvText -eq '0' -or $fvText -eq ''))) {
				$extra['fillValue'] = if ($fvText -match '^-?\d+$') { [long]$fvText } else { [double]$fvText }
			}
		} elseif ($xsiT -match 'string$') {
			if (-not ($fcat -eq 'String' -and $fvText -eq '')) { $extra['fillValue'] = $fvText }
		} elseif ($xsiT -match 'dateTime$') {
			$extra['fillValue'] = $fvText
		} elseif ($xsiT -match 'DesignTimeRef$') {
			# Пустой DTR (ссылочный fillValue без значения) ≠ nil/xs:string → маркер emptyRef (иначе тип терялся в xs:string).
			if ($fvText -eq '') { $extra['fillValue'] = [ordered]@{ emptyRef = $true } } else { $extra['fillValue'] = $fvText }
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

	$cplArr = Parse-ChoiceParameterLinks $ap 'md:ChoiceParameterLinks'; if ($null -ne $cplArr) { $extra['choiceParameterLinks'] = $cplArr }
	$cpArr = Parse-ChoiceParameters $ap 'md:ChoiceParameters'; if ($null -ne $cpArr) { $extra['choiceParameters'] = $cpArr }

	# Пустой <Type/> (реквизит без типа / произвольный) → $ts=''. Отличаем от «дефолтного» отсутствия:
	# заставляем объектную форму с явным type:'' (компилятор без маркера подставил бы xs:string).
	$typeEmpty = ($ts -eq '')
	if ($synCustom -or $synEmpty -or ($null -ne $ttVal) -or $extra.Count -gt 0 -or $typeEmpty) {
		$o = [ordered]@{ name = $nm }
		if ($ts) { $o['type'] = $ts } elseif ($typeEmpty) { $o['type'] = '' }
		if ($synCustom) { $o['synonym'] = $synVal }
		elseif ($synEmpty) { $o['synonym'] = '' }
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
$dsl = [ordered]@{ type = $objType; name = $objName }

# Синоним объекта: строка ru-only ИЛИ {ru,en} (мультиязычно). Кастом → эмитим.
# Пустой <Synonym/> (узел есть, значения нет) ≠ авто-синоним из имени → явный synonym:"" (иначе компилятор до-генерит из имени).
$synNodeObj = $props.SelectSingleNode('md:Synonym', $nsm)
$synVal = Get-MLValue $synNodeObj
if ($synVal -is [string]) { if ($synVal -cne (Split-CamelWords $objName)) { $dsl['synonym'] = $synVal } }
elseif ($null -ne $synVal) { $dsl['synonym'] = $synVal }
elseif ($synNodeObj) { $dsl['synonym'] = '' }
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
# Тип-зависимые дефолты (компилятор задаёт их по типу — декомпилятор обязан зеркалить, иначе omit ≠ значению).
$descrLenDef  = switch ($objType) { 'ExchangePlan' { 150 } 'ChartOfCharacteristicTypes' { 100 } 'ChartOfCalculationTypes' { 100 } default { 25 } }
$codeLenDef   = if ($objType -eq 'ChartOfCalculationTypes') { 5 } else { 9 }
$createInpDef = if ($objType -in @('Catalog', 'Document')) { 'Use' } else { 'DontUse' }
$dataLockDef  = 'Managed'   # компилятор эмитит Managed по умолчанию для всех типов (авторинг); Automatic несётся в DSL явно
$codeSeriesDef = switch ($objType) { 'ChartOfCharacteristicTypes' { 'WholeCharacteristicKind' } 'ChartOfAccounts' { 'WholeChartOfAccounts' } default { 'WholeCatalog' } }
$checkUniqueDef = ($objType -in @('ChartOfCharacteristicTypes', 'ChartOfAccounts', 'Document', 'DocumentNumerator'))   # ПВХ/ПС/Документ/Нумератор дефолт true, Catalog false
$defPresDef = if ($objType -eq 'ChartOfAccounts') { 'AsCode' } else { 'AsDescription' }   # ПС по умолчанию AsCode
Add-IntProp  'codeLength'        'CodeLength'        $codeLenDef
Add-IntProp  'descriptionLength' 'DescriptionLength' $descrLenDef
Add-EnumProp 'codeType'          'CodeType'          'String'
Add-EnumProp 'codeAllowedLength' 'CodeAllowedLength' 'Variable'
Add-BoolProp 'autonumbering'     'Autonumbering'     $true
Add-BoolProp 'checkUnique'       'CheckUnique'       $checkUniqueDef
Add-EnumProp 'codeSeries'        'CodeSeries'        $codeSeriesDef
Add-EnumProp 'defaultPresentation' 'DefaultPresentation' $defPresDef
if ($objType -ne 'Constant') { Add-BoolProp 'quickChoice' 'QuickChoice' $(if ($objType -eq 'Enum') { $true } else { $false }) }   # Enum дефолт true; прочие false. Constant: QuickChoice — ENUM (Auto), не bool → ловим отдельно ниже
Add-EnumProp 'choiceMode'        'ChoiceMode'        'BothWays'
Add-EnumProp 'dataLockControlMode' 'DataLockControlMode' $dataLockDef
Add-EnumProp 'fullTextSearch'    'FullTextSearch'    'Use'
Add-BoolProp 'useStandardCommands' 'UseStandardCommands' $(if ($objType -in @('Enum', 'CommonForm')) { $false } else { $true })   # Enum/CommonForm дефолт false (корпус); прочие (вкл. Report/DataProcessor) — true
Add-EnumProp 'createOnInput'     'CreateOnInput'     $createInpDef
Add-EnumProp 'editType'          'EditType'          'InDialog'
Add-BoolProp 'includeHelpInContents' 'IncludeHelpInContents' $false
Add-EnumProp 'choiceHistoryOnInput' 'ChoiceHistoryOnInput' 'Auto'
Add-EnumProp 'predefinedDataUpdate' 'PredefinedDataUpdate' 'Auto'
Add-EnumProp 'searchStringModeOnInputByString' 'SearchStringModeOnInputByString' 'Begin'
Add-EnumProp 'fullTextSearchOnInputByString' 'FullTextSearchOnInputByString' 'DontUse'
# ExchangePlan-специфичные свойства (у Catalog этих тегов нет → блок не трогает его).
if ($objType -eq 'ExchangePlan') {
	Add-BoolProp 'distributedInfoBase' 'DistributedInfoBase' $false
	Add-BoolProp 'includeConfigurationExtensions' 'IncludeConfigurationExtensions' $false
	Add-EnumProp 'dataHistory' 'DataHistory' 'DontUse'
	Add-BoolProp 'updateDataHistoryImmediatelyAfterWrite' 'UpdateDataHistoryImmediatelyAfterWrite' $false
	Add-BoolProp 'executeAfterWriteDataHistoryVersionProcessing' 'ExecuteAfterWriteDataHistoryVersionProcessing' $false
}
# ChartOfCharacteristicTypes-специфичные свойства.
if ($objType -eq 'ChartOfCharacteristicTypes') {
	Add-EnumProp 'dataHistory' 'DataHistory' 'DontUse'
	Add-BoolProp 'updateDataHistoryImmediatelyAfterWrite' 'UpdateDataHistoryImmediatelyAfterWrite' $false
	Add-BoolProp 'executeAfterWriteDataHistoryVersionProcessing' 'ExecuteAfterWriteDataHistoryVersionProcessing' $false
	$cev = P 'CharacteristicExtValues'; if ($cev) { $dsl['characteristicExtValues'] = $cev }
	# Type — тип значения характеристики; valueType при отличии от дефолта (Boolean+String(100)+Number(15,2)+DateTime).
	$vtNode = $props.SelectSingleNode('md:Type', $nsm)
	if ($vtNode) {
		$vtStr = Get-TypeShorthand $vtNode
		if ($vtStr -and $vtStr -ne 'Boolean + String(100) + Number(15,2) + DateTime') { $dsl['valueType'] = $vtStr }
	}
}
# ChartOfAccounts-специфичные свойства (у Catalog этих тегов нет → блок его не трогает).
if ($objType -eq 'ChartOfAccounts') {
	$edt = P 'ExtDimensionTypes'; if ($edt) { $dsl['extDimensionTypes'] = $edt }
	# Дефолт зеркалит компилятор: с ПВХ — 3, без — 0 (платформа не даёт > 0 без ПВХ).
	Add-IntProp  'maxExtDimensionCount' 'MaxExtDimensionCount' $(if ($edt) { 3 } else { 0 })
	$cm = P 'CodeMask'; if ($cm) { $dsl['codeMask'] = $cm }
	Add-BoolProp 'autoOrderByCode' 'AutoOrderByCode' $true
	Add-IntProp  'orderLength' 'OrderLength' 9
	Add-EnumProp 'dataHistory' 'DataHistory' 'DontUse'
	Add-BoolProp 'updateDataHistoryImmediatelyAfterWrite' 'UpdateDataHistoryImmediatelyAfterWrite' $false
	Add-BoolProp 'executeAfterWriteDataHistoryVersionProcessing' 'ExecuteAfterWriteDataHistoryVersionProcessing' $false
}
# ChartOfCalculationTypes-специфичные свойства.
if ($objType -eq 'ChartOfCalculationTypes') {
	Add-EnumProp 'dependenceOnCalculationTypes' 'DependenceOnCalculationTypes' 'DontUse'
	Add-BoolProp 'actionPeriodUse' 'ActionPeriodUse' $false
	# BaseCalculationTypes — список ссылок на ПВР (omit-on-empty, verbatim).
	$bctNode = $props.SelectSingleNode('md:BaseCalculationTypes', $nsm)
	if ($bctNode) {
		$bctItems = @($bctNode.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
		if ($bctItems.Count -gt 0) { $dsl['baseCalculationTypes'] = [System.Collections.ArrayList]@($bctItems) }
	}
	Add-EnumProp 'dataHistory' 'DataHistory' 'DontUse'
	Add-BoolProp 'updateDataHistoryImmediatelyAfterWrite' 'UpdateDataHistoryImmediatelyAfterWrite' $false
	Add-BoolProp 'executeAfterWriteDataHistoryVersionProcessing' 'ExecuteAfterWriteDataHistoryVersionProcessing' $false
}
# Document-специфичные свойства: нумерация, проведение, движения, DataHistory-триплет.
if ($objType -eq 'Document') {
	$numRef = P 'Numerator'; if ($numRef) { $dsl['numerator'] = $numRef }
	Add-EnumProp 'numberType'          'NumberType'          'String'
	Add-IntProp  'numberLength'        'NumberLength'        11
	Add-EnumProp 'numberAllowedLength' 'NumberAllowedLength' 'Variable'
	Add-EnumProp 'numberPeriodicity'   'NumberPeriodicity'   'Year'
	# CheckUnique/Autonumbering у Document уже покрыты общим блоком (дефолты true/true совпадают).
	Add-EnumProp 'posting'                      'Posting'                      'Allow'
	Add-EnumProp 'realTimePosting'              'RealTimePosting'              'Deny'
	Add-EnumProp 'registerRecordsDeletion'      'RegisterRecordsDeletion'      'AutoDelete'
	Add-EnumProp 'registerRecordsWritingOnPost' 'RegisterRecordsWritingOnPost' 'WriteSelected'
	Add-EnumProp 'sequenceFilling'              'SequenceFilling'              'AutoFill'
	Add-BoolProp 'postInPrivilegedMode'         'PostInPrivilegedMode'         $true
	Add-BoolProp 'unpostInPrivilegedMode'       'UnpostInPrivilegedMode'       $true
	# RegisterRecords — движения (список MDObjectRef, omit-on-empty, verbatim).
	$rrNode = $props.SelectSingleNode('md:RegisterRecords', $nsm)
	if ($rrNode) {
		$rrItems = @($rrNode.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
		if ($rrItems.Count -gt 0) { $dsl['registerRecords'] = [System.Collections.ArrayList]@($rrItems) }
	}
	Add-EnumProp 'dataHistory' 'DataHistory' 'DontUse'
	Add-BoolProp 'updateDataHistoryImmediatelyAfterWrite' 'UpdateDataHistoryImmediatelyAfterWrite' $false
	Add-BoolProp 'executeAfterWriteDataHistoryVersionProcessing' 'ExecuteAfterWriteDataHistoryVersionProcessing' $false
}
# InformationRegister-специфичные свойства: периодичность, режим записи, срезы, DataHistory-триплет.
if ($objType -eq 'InformationRegister') {
	Add-EnumProp 'periodicity'       'InformationRegisterPeriodicity' 'Nonperiodical'
	Add-EnumProp 'writeMode'         'WriteMode'                      'Independent'
	Add-BoolProp 'mainFilterOnPeriod' 'MainFilterOnPeriod'            $false
	Add-BoolProp 'enableTotalsSliceFirst' 'EnableTotalsSliceFirst'    $false
	Add-BoolProp 'enableTotalsSliceLast'  'EnableTotalsSliceLast'     $false
	Add-EnumProp 'dataHistory' 'DataHistory' 'DontUse'
	Add-BoolProp 'updateDataHistoryImmediatelyAfterWrite' 'UpdateDataHistoryImmediatelyAfterWrite' $false
	Add-BoolProp 'executeAfterWriteDataHistoryVersionProcessing' 'ExecuteAfterWriteDataHistoryVersionProcessing' $false
}
# AccumulationRegister-специфичные свойства: тип регистра, разделение итогов.
if ($objType -eq 'AccumulationRegister') {
	Add-EnumProp 'registerType' 'RegisterType' 'Balance'
	Add-BoolProp 'enableTotalsSplitting' 'EnableTotalsSplitting' $true
}
# AccountingRegister-специфичные свойства: ПС-связь, корреспонденция, коррекция периода, разделение итогов.
if ($objType -eq 'AccountingRegister') {
	$coa = P 'ChartOfAccounts'; if ($coa) { $dsl['chartOfAccounts'] = $coa }
	Add-BoolProp 'correspondence' 'Correspondence' $false
	Add-IntProp  'periodAdjustmentLength' 'PeriodAdjustmentLength' 0
	Add-BoolProp 'enableTotalsSplitting' 'EnableTotalsSplitting' $true
}
# CalculationRegister-специфичные свойства: ПВР-связь, периоды расчёта, график (все ссылки/enum — verbatim).
if ($objType -eq 'CalculationRegister') {
	$cct = P 'ChartOfCalculationTypes'; if ($cct) { $dsl['chartOfCalculationTypes'] = $cct }
	Add-EnumProp 'periodicity' 'Periodicity' 'Month'
	Add-BoolProp 'actionPeriod' 'ActionPeriod' $false
	Add-BoolProp 'basePeriod' 'BasePeriod' $false
	$sch = P 'Schedule'; if ($sch) { $dsl['schedule'] = $sch }
	$schv = P 'ScheduleValue'; if ($schv) { $dsl['scheduleValue'] = $schv }
	$schd = P 'ScheduleDate'; if ($schd) { $dsl['scheduleDate'] = $schd }
}
# BusinessProcess-специфичные свойства: нумерация (Document-стиль), связь с задачей, привилегированный режим.
if ($objType -eq 'BusinessProcess') {
	Add-EnumProp 'numberType'          'NumberType'          'String'
	Add-IntProp  'numberLength'        'NumberLength'        11
	Add-EnumProp 'numberAllowedLength' 'NumberAllowedLength' 'Variable'
	Add-EnumProp 'numberPeriodicity'   'NumberPeriodicity'   'Nonperiodical'
	# CheckUnique/Autonumbering дефолт true (совпадает с компилятором → захват только при false).
	Add-BoolProp 'checkUnique'   'CheckUnique'   $true
	Add-BoolProp 'autonumbering' 'Autonumbering' $true
	$tsk = P 'Task'; if ($tsk) { $dsl['task'] = $tsk }
	Add-BoolProp 'createTaskInPrivilegedMode' 'CreateTaskInPrivilegedMode' $true
}
# Task-специфичные свойства: нумерация, адресация, текущий исполнитель.
if ($objType -eq 'Task') {
	Add-EnumProp 'numberType'          'NumberType'          'String'
	Add-IntProp  'numberLength'        'NumberLength'        14
	Add-EnumProp 'numberAllowedLength' 'NumberAllowedLength' 'Variable'
	Add-BoolProp 'checkUnique'   'CheckUnique'   $true
	Add-BoolProp 'autonumbering' 'Autonumbering' $true
	$tnap = P 'TaskNumberAutoPrefix'; if ($tnap -and $tnap -ne 'BusinessProcessNumber') { $dsl['taskNumberAutoPrefix'] = $tnap }
	Add-IntProp  'descriptionLength'   'DescriptionLength'   150
	$addr = P 'Addressing'; if ($addr) { $dsl['addressing'] = $addr }
	$maa = P 'MainAddressingAttribute'; if ($maa) { $dsl['mainAddressingAttribute'] = $maa }
	$cp = P 'CurrentPerformer'; if ($cp) { $dsl['currentPerformer'] = $cp }
	Add-EnumProp 'defaultPresentation' 'DefaultPresentation' 'AsDescription'
}
# Report-специфичные свойства: формы (плоские ref, не *ObjectForm), схема компоновки, хранилища вариантов/настроек.
if ($objType -eq 'Report') {
	$dfm = P 'DefaultForm'; if ($dfm) { $dsl['defaultForm'] = $dfm }
	$afm = P 'AuxiliaryForm'; if ($afm) { $dsl['auxiliaryForm'] = $afm }
	$mdcs = P 'MainDataCompositionSchema'; if ($mdcs) { $dsl['mainDataCompositionSchema'] = $mdcs }
	$dsf = P 'DefaultSettingsForm'; if ($dsf) { $dsl['defaultSettingsForm'] = $dsf }
	$asf = P 'AuxiliarySettingsForm'; if ($asf) { $dsl['auxiliarySettingsForm'] = $asf }
	$dvf = P 'DefaultVariantForm'; if ($dvf) { $dsl['defaultVariantForm'] = $dvf }
	$vs = P 'VariantsStorage'; if ($vs) { $dsl['variantsStorage'] = $vs }
	$ss = P 'SettingsStorage'; if ($ss) { $dsl['settingsStorage'] = $ss }
	$ep = Get-MLValue ($props.SelectSingleNode('md:ExtendedPresentation', $nsm)); if ($null -ne $ep) { $dsl['extendedPresentation'] = $ep }
}
# DataProcessor-специфичные свойства: формы (плоские ref).
if ($objType -eq 'DataProcessor') {
	$dfm = P 'DefaultForm'; if ($dfm) { $dsl['defaultForm'] = $dfm }
	$afm = P 'AuxiliaryForm'; if ($afm) { $dsl['auxiliaryForm'] = $afm }
	$ep = Get-MLValue ($props.SelectSingleNode('md:ExtendedPresentation', $nsm)); if ($null -ne $ep) { $dsl['extendedPresentation'] = $ep }
}
# DefinedType — тип-псевдоним: только Name/Synonym/Comment/Type. valueType (составной через ' + ').
if ($objType -eq 'DefinedType') {
	$vt = Get-TypeShorthand ($props.SelectSingleNode('md:Type', $nsm))
	if ($vt) { $dsl['valueType'] = $vt }
}
# FunctionalOption — функциональная опция: Location (хранилище значения) + PrivilegedGetMode + Content (зависимые объекты).
if ($objType -eq 'FunctionalOption') {
	$loc = P 'Location'; if ($loc) { $dsl['location'] = $loc }
	Add-BoolProp 'privilegedGetMode' 'PrivilegedGetMode' $true   # корпус 2864/2864 true → дефолт true, ловим false
	$contentNode = $props.SelectSingleNode('md:Content', $nsm)
	if ($contentNode) {
		$items = @($contentNode.SelectNodes('xr:Object', $nsm) | ForEach-Object { $_.InnerText })
		if ($items.Count -gt 0) { $dsl['content'] = [System.Collections.ArrayList]@($items) }
	}
}
# DocumentJournal — журнал документов: формы (плоские ref) + регистрируемые документы. Колонки → ChildObjects (ниже).
if ($objType -eq 'DocumentJournal') {
	$dfm = P 'DefaultForm'; if ($dfm) { $dsl['defaultForm'] = $dfm }
	$afm = P 'AuxiliaryForm'; if ($afm) { $dsl['auxiliaryForm'] = $afm }
	$rdNode = $props.SelectSingleNode('md:RegisteredDocuments', $nsm)
	if ($rdNode) {
		$rdItems = @($rdNode.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
		if ($rdItems.Count -gt 0) { $dsl['registeredDocuments'] = [System.Collections.ArrayList]@($rdItems) }
	}
}
# Sequence — последовательность документов: граница, документы, движения, измерения (ChildObjects ниже).
if ($objType -eq 'Sequence') {
	Add-EnumProp 'moveBoundaryOnPosting' 'MoveBoundaryOnPosting' 'DontMove'
	foreach ($ll in @(@('Documents','documents'), @('RegisterRecords','registerRecords'))) {
		$ln = $props.SelectSingleNode("md:$($ll[0])", $nsm)
		if ($ln) {
			$items = @($ln.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
			if ($items.Count -gt 0) { $dsl[$ll[1]] = [System.Collections.ArrayList]@($items) }
		}
	}
	# dataLockControlMode покрыт общим блоком (дефолт Managed для всех типов).
}
# FilterCriterion — критерий отбора: тип значения + состав (объекты отбора) + формы.
if ($objType -eq 'FilterCriterion') {
	$vt = Get-TypeShorthand ($props.SelectSingleNode('md:Type', $nsm)); if ($vt) { $dsl['valueType'] = $vt }
	$cn = $props.SelectSingleNode('md:Content', $nsm)
	if ($cn) {
		$items = @($cn.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
		if ($items.Count -gt 0) { $dsl['content'] = [System.Collections.ArrayList]@($items) }
	}
	$dfm = P 'DefaultForm'; if ($dfm) { $dsl['defaultForm'] = $dfm }
	$afm = P 'AuxiliaryForm'; if ($afm) { $dsl['auxiliaryForm'] = $afm }
}
# DocumentNumerator — нумератор документов: параметры нумерации (без InternalInfo/ChildObjects).
if ($objType -eq 'DocumentNumerator') {
	Add-EnumProp 'numberType'          'NumberType'          'String'
	Add-IntProp  'numberLength'        'NumberLength'        11
	Add-EnumProp 'numberAllowedLength' 'NumberAllowedLength' 'Variable'
	Add-EnumProp 'numberPeriodicity'   'NumberPeriodicity'   'Year'
	# checkUnique покрыт общим блоком (дефолт true для DocumentNumerator).
}
# SettingsStorage — хранилище настроек: формы сохранения/загрузки (плоские ref).
if ($objType -eq 'SettingsStorage') {
	foreach ($fp in @(@('DefaultSaveForm','defaultSaveForm'), @('DefaultLoadForm','defaultLoadForm'), @('AuxiliarySaveForm','auxiliarySaveForm'), @('AuxiliaryLoadForm','auxiliaryLoadForm'))) {
		$fv = P $fp[0]; if ($fv) { $dsl[$fp[1]] = $fv }
	}
}
# CommonModule — общий модуль: флаги контекста компиляции + повторное использование значений (тело .bsl вне скоупа).
if ($objType -eq 'CommonModule') {
	Add-BoolProp 'global'                   'Global'                   $false
	Add-BoolProp 'clientManagedApplication' 'ClientManagedApplication' $false
	Add-BoolProp 'server'                   'Server'                   $false
	Add-BoolProp 'externalConnection'       'ExternalConnection'       $false
	Add-BoolProp 'clientOrdinaryApplication' 'ClientOrdinaryApplication' $false
	Add-BoolProp 'serverCall'               'ServerCall'               $false
	Add-BoolProp 'privileged'               'Privileged'               $false
	Add-EnumProp 'returnValuesReuse'        'ReturnValuesReuse'        'DontUse'
}
# EventSubscription — подписка на событие: источники (набор типов), событие, обработчик.
if ($objType -eq 'EventSubscription') {
	$srcNode = $props.SelectSingleNode('md:Source', $nsm)
	if ($srcNode) {
		# Источник — набор v8:Type (конкретный CatalogObject.X) И/ИЛИ v8:TypeSet (голый метатип ExchangePlanObject).
		$srcTypes = @($srcNode.SelectNodes('v8:Type|v8:TypeSet', $nsm) | ForEach-Object { Strip-NsPrefix $_.InnerText.Trim() })
		if ($srcTypes.Count -gt 0) { $dsl['source'] = [System.Collections.ArrayList]@($srcTypes) }
	}
	Add-EnumProp 'event' 'Event' 'BeforeWrite'
	$h = P 'Handler'; if ($h) { $dsl['handler'] = $h }
}
# CommonForm — общая форма (метаданные; содержимое формы Ext/Form.xml вне роундтрипа, территория form-compile).
if ($objType -eq 'CommonForm') {
	Add-EnumProp 'formType' 'FormType' 'Managed'
	# UsePurposes — дефолт [PlatformApplication, MobilePlatformApplication]; захват при отличии.
	$upNode = $props.SelectSingleNode('md:UsePurposes', $nsm)
	if ($upNode) {
		$ups = @($upNode.SelectNodes('v8:Value', $nsm) | ForEach-Object { $_.InnerText })
		$def2 = @('PlatformApplication', 'MobilePlatformApplication')
		$same = ($ups.Count -eq $def2.Count); if ($same) { for ($k=0; $k -lt $ups.Count; $k++) { if ($ups[$k] -ne $def2[$k]) { $same=$false; break } } }
		if (-not $same -and $ups.Count -gt 0) { $dsl['usePurposes'] = [System.Collections.ArrayList]@($ups) }
	}
	$ep = Get-MLValue ($props.SelectSingleNode('md:ExtendedPresentation', $nsm)); if ($null -ne $ep) { $dsl['extendedPresentation'] = $ep }
}
# SessionParameter — параметр сеанса: только тип значения.
if ($objType -eq 'SessionParameter') {
	$vt = Get-TypeShorthand ($props.SelectSingleNode('md:Type', $nsm)); if ($vt) { $dsl['valueType'] = $vt }
}
# FunctionalOptionsParameter — параметр функ. опции: Use (список MDObjectRef).
if ($objType -eq 'FunctionalOptionsParameter') {
	$un = $props.SelectSingleNode('md:Use', $nsm)
	if ($un) { $items = @($un.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText }); if ($items.Count -gt 0) { $dsl['use'] = [System.Collections.ArrayList]@($items) } }
}
# WSReference — WS-ссылка: URL расположения WSDL (+InternalInfo Manager).
if ($objType -eq 'WSReference') {
	$url = P 'LocationURL'; if ($url) { $dsl['locationURL'] = $url }
}
# CommonPicture — общая картинка: доступность (содержимое Ext/Picture вне скоупа).
if ($objType -eq 'CommonPicture') {
	Add-BoolProp 'availabilityForChoice'     'AvailabilityForChoice'     $false
	Add-BoolProp 'availabilityForAppearance' 'AvailabilityForAppearance' $false
}
# CommonTemplate — общий макет: тип макета (содержимое Ext/Template.* вне скоупа).
if ($objType -eq 'CommonTemplate') {
	Add-EnumProp 'templateType' 'TemplateType' 'SpreadsheetDocument'
}
# Общий захват структурного <Picture> (зеркало Emit-CommandPicture). Пишет в $tgt ключи picture/loadTransparent.
function Get-PictureToDsl { param($propsNode, $tgt)
	$refN = $propsNode.SelectSingleNode('md:Picture/xr:Ref', $nsm)
	$absN = $propsNode.SelectSingleNode('md:Picture/xr:Abs', $nsm)
	if ($refN -or $absN) {
		$psrc = if ($refN) { $refN.InnerText } else { "abs:$($absN.InnerText)" }
		$ltN = $propsNode.SelectSingleNode('md:Picture/xr:LoadTransparent', $nsm)
		$ltFalse = ($ltN -and $ltN.InnerText -eq 'false')
		$tpxN = $propsNode.SelectSingleNode('md:Picture/xr:TransparentPixel', $nsm)
		if ($tpxN) {
			$po = [ordered]@{ src = $psrc }; if ($ltFalse) { $po['loadTransparent'] = $false }
			$po['transparentPixel'] = [ordered]@{ x = [int]$tpxN.GetAttribute('x'); y = [int]$tpxN.GetAttribute('y') }
			$tgt['picture'] = $po
		} else { $tgt['picture'] = $psrc; if ($ltFalse) { $tgt['loadTransparent'] = $false } }
	}
}
# CommandGroup — группа команд: представление, подсказка, картинка, категория.
if ($objType -eq 'CommandGroup') {
	Add-EnumProp 'representation' 'Representation' 'Auto'
	$tt = Get-MLValue ($props.SelectSingleNode('md:ToolTip', $nsm)); if ($null -ne $tt) { $dsl['tooltip'] = $tt }
	Get-PictureToDsl $props $dsl
	Add-EnumProp 'category' 'Category' 'NavigationPanel'
}
# CommonCommand — общая команда: группа, представление, подсказка, картинка, параметр, режимы.
if ($objType -eq 'CommonCommand') {
	$grp = P 'Group'; if ($grp) { $dsl['group'] = $grp }
	Add-EnumProp 'representation' 'Representation' 'Auto'
	$tt = Get-MLValue ($props.SelectSingleNode('md:ToolTip', $nsm)); if ($null -ne $tt) { $dsl['tooltip'] = $tt }
	Get-PictureToDsl $props $dsl
	$sc = P 'Shortcut'; if ($sc) { $dsl['shortcut'] = $sc }
	$cpt = Get-TypeShorthand ($props.SelectSingleNode('md:CommandParameterType', $nsm)); if ($cpt) { $dsl['commandParameterType'] = $cpt }
	Add-EnumProp 'parameterUseMode' 'ParameterUseMode' 'Single'
	Add-BoolProp 'modifiesData' 'ModifiesData' $false
	Add-EnumProp 'onMainServerUnavalableBehavior' 'OnMainServerUnavalableBehavior' 'Auto'
}
# CommonAttribute — общий реквизит: тип + value-свойства + состав объектов + свойства разделения данных.
if ($objType -eq 'CommonAttribute') {
	$vt = Get-TypeShorthand ($props.SelectSingleNode('md:Type', $nsm)); if ($vt -and $vt -ne 'String(0)') { $dsl['valueType'] = $vt }
	Add-BoolProp 'passwordMode' 'PasswordMode' $false
	foreach ($mlp in @(@('Format','format'), @('EditFormat','editFormat'), @('ToolTip','tooltip'))) {
		$mv = Get-MLValue ($props.SelectSingleNode("md:$($mlp[0])", $nsm)); if ($null -ne $mv) { $dsl[$mlp[1]] = $mv }
	}
	Add-BoolProp 'markNegatives' 'MarkNegatives' $false
	$msk = P 'Mask'; if ($msk) { $dsl['mask'] = $msk }
	Add-BoolProp 'multiLine' 'MultiLine' $false
	Add-BoolProp 'extendedEdit' 'ExtendedEdit' $false
	foreach ($mm in @(@('MinValue','minValue'), @('MaxValue','maxValue'))) {
		$mn = $props.SelectSingleNode("md:$($mm[0])", $nsm)
		if ($mn -and $mn.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') -ne 'true') {
			$mxt = $mn.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
			if ($mxt -match 'decimal$') { $dsl[$mm[1]] = if ($mn.InnerText -match '^-?\d+$') { [long]$mn.InnerText } else { [double]$mn.InnerText } } else { $dsl[$mm[1]] = $mn.InnerText }
		}
	}
	Add-BoolProp 'fillFromFillingValue' 'FillFromFillingValue' $false
	# FillValue: тип-зависимый дефолт (String→typed-empty, Number→0, прочее→nil). Захват при отклонении.
	# nil на String/Number-типе ≠ дефолт → маркер {nil:true} (напр. системный реквизит-разделитель ОбластьДанных).
	$catVt = if ($vt) { $vt } else { 'String(0)' }
	$fvN = $props.SelectSingleNode('md:FillValue', $nsm)
	if ($fvN) {
		$fvNil = ($fvN.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') -eq 'true')
		if ($fvNil) {
			if ($catVt -match '^(String|Number)') { $dsl['fillValue'] = [ordered]@{ nil = $true } }
		} else {
			$fvXt = $fvN.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
			if ($fvXt -match 'DesignTimeRef$' -and $fvN.InnerText -eq '') { $dsl['fillValue'] = [ordered]@{ emptyRef = $true } }
			elseif ($fvXt -match 'decimal$') { if ($fvN.InnerText -ne '0') { $dsl['fillValue'] = if ($fvN.InnerText -match '^-?\d+$') { [long]$fvN.InnerText } else { [double]$fvN.InnerText } } }
			elseif (-not [string]::IsNullOrEmpty($fvN.InnerText)) { $dsl['fillValue'] = $fvN.InnerText }
		}
	}
	Add-EnumProp 'fillChecking' 'FillChecking' 'DontCheck'
	Add-EnumProp 'choiceFoldersAndItems' 'ChoiceFoldersAndItems' 'Items'
	$cpl = Parse-ChoiceParameterLinks $props 'md:ChoiceParameterLinks'; if ($null -ne $cpl) { $dsl['choiceParameterLinks'] = $cpl }
	$cp = Parse-ChoiceParameters $props 'md:ChoiceParameters'; if ($null -ne $cp) { $dsl['choiceParameters'] = $cp }
	Add-EnumProp 'quickChoice' 'QuickChoice' 'Auto'
	Add-EnumProp 'createOnInput' 'CreateOnInput' 'Auto'
	$cf = P 'ChoiceForm'; if ($cf) { $dsl['choiceForm'] = $cf }
	Add-EnumProp 'choiceHistoryOnInput' 'ChoiceHistoryOnInput' 'Auto'
	# Content — объекты, к которым добавлен общий реквизит.
	$cn = $props.SelectSingleNode('md:Content', $nsm)
	if ($cn) {
		$cArr = [System.Collections.ArrayList]@()
		foreach ($it in @($cn.SelectNodes('xr:Item', $nsm))) {
			$mdN = $it.SelectSingleNode('xr:Metadata', $nsm); $mdv = if ($mdN) { $mdN.InnerText } else { '' }
			$useN = $it.SelectSingleNode('xr:Use', $nsm); $usev = if ($useN) { $useN.InnerText } else { 'Use' }
			$csN = $it.SelectSingleNode('xr:ConditionalSeparation', $nsm); $csv = if ($csN) { $csN.InnerText } else { '' }
			if ($usev -eq 'Use' -and -not $csv) { [void]$cArr.Add($mdv) }
			else { $io = [ordered]@{ metadata = $mdv }; if ($usev -ne 'Use') { $io['use'] = $usev }; if ($csv) { $io['conditionalSeparation'] = $csv }; [void]$cArr.Add($io) }
		}
		if ($cArr.Count -gt 0) { $dsl['content'] = $cArr }
	}
	Add-EnumProp 'autoUse' 'AutoUse' 'DontUse'
	Add-EnumProp 'dataSeparation' 'DataSeparation' 'DontUse'
	Add-EnumProp 'separatedDataUse' 'SeparatedDataUse' 'Independently'
	$dsv = P 'DataSeparationValue'; if ($dsv) { $dsl['dataSeparationValue'] = $dsv }
	$dsu = P 'DataSeparationUse'; if ($dsu) { $dsl['dataSeparationUse'] = $dsu }
	$cs2 = P 'ConditionalSeparation'; if ($cs2) { $dsl['conditionalSeparation'] = $cs2 }
	Add-EnumProp 'usersSeparation' 'UsersSeparation' 'DontUse'
	Add-EnumProp 'authenticationSeparation' 'AuthenticationSeparation' 'DontUse'
	Add-EnumProp 'configurationExtensionsSeparation' 'ConfigurationExtensionsSeparation' 'DontUse'
	Add-EnumProp 'indexing' 'Indexing' 'DontIndex'
	Add-EnumProp 'dataHistory' 'DataHistory' 'Use'
	# fullTextSearch покрыт общим блоком (дефолт Use).
}
# ScheduledJob — регламентное задание: метод, ключ, флаги, рестарт.
if ($objType -eq 'ScheduledJob') {
	$mn = P 'MethodName'; if ($mn) { $dsl['methodName'] = $mn }
	$descr = P 'Description'; if ($descr) { $dsl['description'] = $descr }
	$k = P 'Key'; if ($k) { $dsl['key'] = $k }
	Add-BoolProp 'use'        'Use'        $false
	Add-BoolProp 'predefined' 'Predefined' $false
	Add-IntProp  'restartCountOnFailure'    'RestartCountOnFailure'    3
	Add-IntProp  'restartIntervalOnFailure' 'RestartIntervalOnFailure' 10
}
# Constant — богатый одиночный реквизит: Type + свойства значения (как у реквизита) + object-уровень.
if ($objType -eq 'Constant') {
	$vt = Get-TypeShorthand ($props.SelectSingleNode('md:Type', $nsm))
	if ($vt) { $dsl['valueType'] = $vt } else { $dsl['valueType'] = '' }
	$dfm = P 'DefaultForm'; if ($dfm) { $dsl['defaultForm'] = $dfm }
	$ep = Get-MLValue ($props.SelectSingleNode('md:ExtendedPresentation', $nsm)); if ($null -ne $ep) { $dsl['extendedPresentation'] = $ep }
	Add-BoolProp 'passwordMode' 'PasswordMode' $false
	$fmt = Get-MLValue ($props.SelectSingleNode('md:Format', $nsm)); if ($null -ne $fmt) { $dsl['format'] = $fmt }
	$efmt = Get-MLValue ($props.SelectSingleNode('md:EditFormat', $nsm)); if ($null -ne $efmt) { $dsl['editFormat'] = $efmt }
	$tt = Get-MLValue ($props.SelectSingleNode('md:ToolTip', $nsm)); if ($null -ne $tt) { $dsl['tooltip'] = $tt }
	Add-BoolProp 'markNegatives' 'MarkNegatives' $false
	$msk = P 'Mask'; if ($msk) { $dsl['mask'] = $msk }
	Add-BoolProp 'multiLine' 'MultiLine' $false
	Add-BoolProp 'extendedEdit' 'ExtendedEdit' $false
	# MinValue/MaxValue (дефолт nil) — типизированное значение при наличии.
	foreach ($mm in @(@('MinValue','minValue'), @('MaxValue','maxValue'))) {
		$mn = $props.SelectSingleNode("md:$($mm[0])", $nsm)
		if ($mn -and $mn.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') -ne 'true') {
			$mxt = $mn.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
			if ($mxt -match 'decimal$') { $dsl[$mm[1]] = if ($mn.InnerText -match '^-?\d+$') { [long]$mn.InnerText } else { [double]$mn.InnerText } }
			else { $dsl[$mm[1]] = $mn.InnerText }
		}
	}
	Add-EnumProp 'fillChecking' 'FillChecking' 'DontCheck'
	Add-EnumProp 'choiceFoldersAndItems' 'ChoiceFoldersAndItems' 'Items'
	$cpl = Parse-ChoiceParameterLinks $props 'md:ChoiceParameterLinks'; if ($null -ne $cpl) { $dsl['choiceParameterLinks'] = $cpl }
	$cp = Parse-ChoiceParameters $props 'md:ChoiceParameters'; if ($null -ne $cp) { $dsl['choiceParameters'] = $cp }
	Add-EnumProp 'quickChoice' 'QuickChoice' 'Auto'
	$cf = P 'ChoiceForm'; if ($cf) { $dsl['choiceForm'] = $cf }
	$lbtNode = $props.SelectSingleNode('md:LinkByType', $nsm)
	if ($lbtNode) {
		$dpN = $lbtNode.SelectSingleNode('md:DataPath', $nsm)
		if ($dpN -and $dpN.InnerText) {
			$liN = $lbtNode.SelectSingleNode('md:LinkItem', $nsm)
			$li = if ($liN -and $liN.InnerText) { [int]$liN.InnerText } else { 0 }
			$dsl['linkByType'] = if ($li -eq 0) { $dpN.InnerText } else { [ordered]@{ dataPath = $dpN.InnerText; linkItem = $li } }
		}
	}
	Add-EnumProp 'dataHistory' 'DataHistory' 'DontUse'
	Add-BoolProp 'updateDataHistoryImmediatelyAfterWrite' 'UpdateDataHistoryImmediatelyAfterWrite' $false
	Add-BoolProp 'executeAfterWriteDataHistoryVersionProcessing' 'ExecuteAfterWriteDataHistoryVersionProcessing' $false
}

# Короткая форма поля: <Type>.<Name>.StandardAttribute.X / .Attribute.X → StandardAttribute.X / Attribute.X
# (Expand-DataPath компилятора разворачивает частичную форму обратно — dogfood резолвера).
function Short-Field { param([string]$full) if ($full -match '\.(StandardAttribute|Attribute)\.(.+)$') { return "$($Matches[1]).$($Matches[2])" } return $full }

# InputByString — эмитим только при отличии от выведенного дефолта [Descr при D>0]+[Code при C>0].
$ibNode = $props.SelectSingleNode('md:InputByString', $nsm)
if ($ibNode) {
	$ibActual = @($ibNode.SelectNodes('xr:Field', $nsm) | ForEach-Object { $_.InnerText })
	$clv = P 'CodeLength'; $dlv = P 'DescriptionLength'
	$cl = if ($clv -and $clv -ne '') { [int]$clv } else { 9 }
	$dl = if ($dlv -and $dlv -ne '') { [int]$dlv } else { 25 }
	$ibDef = @()
	if ($dl -gt 0) { $ibDef += "StandardAttribute.Description" }
	if ($cl -gt 0) { $ibDef += "StandardAttribute.Code" }
	$ibShort = @($ibActual | ForEach-Object { Short-Field $_ })
	$same = ($ibShort.Count -eq $ibDef.Count)
	if ($same) { for ($k = 0; $k -lt $ibShort.Count; $k++) { if ($ibShort[$k] -ne $ibDef[$k]) { $same = $false; break } } }
	if (-not $same) { $dsl['inputByString'] = [System.Collections.ArrayList]@($ibShort) }
}

# BasedOn — «ввод на основании», список MDObjectRef (omit-on-empty).
$boNode = $props.SelectSingleNode('md:BasedOn', $nsm)
if ($boNode) {
	$boItems = @($boNode.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
	if ($boItems.Count -gt 0) { $dsl['basedOn'] = [System.Collections.ArrayList]@($boItems) }
}

# DataLockFields — поля блокировки данных (omit-on-empty).
$dlfNode = $props.SelectSingleNode('md:DataLockFields', $nsm)
if ($dlfNode) {
	$dlfFields = @($dlfNode.SelectNodes('xr:Field', $nsm) | ForEach-Object { Short-Field $_.InnerText })
	if ($dlfFields.Count -gt 0) { $dsl['dataLockFields'] = [System.Collections.ArrayList]@($dlfFields) }
}

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
Add-FormRef 'defaultRecordForm'         'DefaultRecordForm'
Add-FormRef 'auxiliaryRecordForm'       'AuxiliaryRecordForm'

# Презентации (ML, компилятор пишет пусто → omit-on-empty).
foreach ($pp in @(
	@('ObjectPresentation','objectPresentation'), @('ExtendedObjectPresentation','extendedObjectPresentation'),
	@('RecordPresentation','recordPresentation'), @('ExtendedRecordPresentation','extendedRecordPresentation'),
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

# --- StandardAttributes: захватываем ОТКЛОНЕНИЯ от профиля материализованного блока (профиль компилятор
# восстановит сам). Профиль зеркалит stdAttrProfile компилятора — по типу объекта.
# Catalog: Owner{FC=ShowError,FFV=true}, Parent{FFV=true}, Description{FC=ShowError}.
# ExchangePlan: Description{FC=ShowError}, Code{FC=ShowError} (блок всегда материализован). ---
$stdProfileByType = @{
	'Catalog' = @{
		'Owner'       = @{ fillChecking = 'ShowError'; fillFromFillingValue = $true }
		'Parent'      = @{ fillFromFillingValue = $true }
		'Description'  = @{ fillChecking = 'ShowError' }
	}
	'ExchangePlan' = @{
		'Description' = @{ fillChecking = 'ShowError' }
		'Code'        = @{ fillChecking = 'ShowError' }
	}
	'ChartOfCharacteristicTypes' = @{
		'Description' = @{ fillChecking = 'ShowError' }
		'Parent'      = @{ fillFromFillingValue = $true }
	}
	'ChartOfAccounts' = @{
		'Description' = @{ fillChecking = 'ShowError' }
		'Code'        = @{ fillChecking = 'ShowError' }
		'Parent'      = @{ fillFromFillingValue = $true }
	}
	'ChartOfCalculationTypes' = @{
		'Description' = @{ fillChecking = 'ShowError' }
	}
	'Document' = @{
		'Date' = @{ fillChecking = 'ShowError' }
	}
}
$catStdProfile = if ($stdProfileByType.ContainsKey($objType)) { $stdProfileByType[$objType] } else { @{} }
# Фикс-список стандартных реквизитов типа (зеркало standardAttributesByType компилятора) — чтобы отличать
# доп./опциональные (напр. ExchangeDate у ПланОбмена), которые эмитим по факту присутствия даже all-default.
$stdFixedByType = @{
	'Catalog'      = @('PredefinedDataName','Predefined','Ref','DeletionMark','IsFolder','Owner','Parent','Description','Code')
	'ExchangePlan' = @('Ref','DeletionMark','Code','Description','ThisNode','SentNo','ReceivedNo')
	'ChartOfCharacteristicTypes' = @('PredefinedDataName','Predefined','Ref','DeletionMark','Description','Code','Parent','ValueType')
	'ChartOfAccounts' = @('PredefinedDataName','Order','OffBalance','Type','Description','Code','Parent','Predefined','DeletionMark','Ref')
	'ChartOfCalculationTypes' = @('PredefinedDataName','Predefined','Ref','DeletionMark','ActionPeriodIsBasic','Description','Code')
	'Document' = @('Ref','DeletionMark','Date','Number','Posted')
	'Enum' = @('Order','Ref')
	'DocumentJournal' = @('Type','Ref','Date','Posted','DeletionMark','Number')
}
$stdFixed = if ($stdFixedByType.ContainsKey($objType)) { $stdFixedByType[$objType] } else { @() }
# Условные типы: блок эмитим-как-триггер даже пустым (материализуется при отклонении ≥1 реквизита от schema-default;
# у ExchangePlan это почти всегда — Description/Code=ShowError; редкий all-default EP блок опускает).
$stdConditionalTypes = @('Catalog', 'ExchangePlan', 'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes', 'Document')
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
		# FillValue (дефолт nil) — DTR-путь/строка/bool. Comment/Mask/ChoiceForm (дефолт пусто).
		$fvN = $sa.SelectSingleNode('xr:FillValue', $nsm)
		if ($fvN -and $fvN.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') -ne 'true') {
			$fvXt = $fvN.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
			if ($fvXt -match 'DesignTimeRef$' -and $fvN.InnerText -eq '') { $ov['fillValue'] = [ordered]@{ emptyRef = $true } }
			elseif ($fvXt -match 'TypeDescription$' -and $fvN.InnerText -eq '') { $ov['fillValue'] = [ordered]@{ typeDescription = $true } }   # пустое типизированное (реквизит ValueType ПВХ) ≠ xs:string
			else { $ov['fillValue'] = Convert-ChScalarNode $fvN }
		}
		$saCmt = $sa.SelectSingleNode('xr:Comment', $nsm); if ($saCmt -and $saCmt.InnerText) { $ov['comment'] = $saCmt.InnerText }
		$saMsk = $sa.SelectSingleNode('xr:Mask', $nsm); if ($saMsk -and $saMsk.InnerText) { $ov['mask'] = $saMsk.InnerText }
			$saFmt = Get-MLValue ($sa.SelectSingleNode('xr:Format', $nsm)); if ($null -ne $saFmt) { $ov['format'] = $saFmt }
			$saEfmt = Get-MLValue ($sa.SelectSingleNode('xr:EditFormat', $nsm)); if ($null -ne $saEfmt) { $ov['editFormat'] = $saEfmt }
		$saCf = $sa.SelectSingleNode('xr:ChoiceForm', $nsm); if ($saCf -and $saCf.InnerText) { $ov['choiceForm'] = $saCf.InnerText }
		$saCpl = Parse-ChoiceParameterLinks $sa 'xr:ChoiceParameterLinks'; if ($null -ne $saCpl) { $ov['choiceParameterLinks'] = $saCpl }
		$saCp = Parse-ChoiceParameters $sa 'xr:ChoiceParameters'; if ($null -ne $saCp) { $ov['choiceParameters'] = $saCp }
		# LinkByType стандартного реквизита (ExtDimensionN→Account у регистра бухгалтерии). DataPath полный verbatim.
		$saLbt = $sa.SelectSingleNode('xr:LinkByType', $nsm)
		if ($saLbt) {
			$saLbtDp = $saLbt.SelectSingleNode('xr:DataPath', $nsm)
			if ($saLbtDp -and $saLbtDp.InnerText) {
				$saLbtLi = $saLbt.SelectSingleNode('xr:LinkItem', $nsm)
				$li = if ($saLbtLi -and $saLbtLi.InnerText) { [int]$saLbtLi.InnerText } else { 0 }
				$ov['linkByType'] = [ordered]@{ dataPath = $saLbtDp.InnerText; linkItem = $li }
			}
		}
		# Доп./опциональный реквизит (не в фикс-списке) — эмитим по присутствию даже без отклонений.
		if ($ov.Count -gt 0 -or ($stdFixed -notcontains $an)) { $saMap[$an] = $ov }
	}
	# Условный тип (Catalog): пустой $saMap = триггер блока. Не-условный (ExchangePlan): блок и так эмитится → пустой не пишем.
	if ($saMap.Count -gt 0 -or ($stdConditionalTypes -contains $objType)) { $dsl['standardAttributes'] = $saMap }
} elseif ($objType -in @('InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister', 'BusinessProcess', 'Task', 'Enum', 'DocumentJournal')) {
	# Регистр/БП/Задача опускают all-default блок стандартных реквизитов (правило не выводимо) — компилятор эмитит его
	# по дефолту, поэтому отсутствие фиксируем opt-out `standardAttributes:""` (дом-конвенция суппресса).
	$dsl['standardAttributes'] = ''
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
	# Enum: значения перечисления. Плоский элемент name/synonym/comment. Короткая форма — строка "Имя"
	# (синоним == авто из имени, без comment, не мультиязычный); иначе объект {name, synonym?, comment?}.
	$evNodes = @($childObjs.SelectNodes('md:EnumValue', $nsm))
	if ($evNodes.Count -gt 0) {
		$evArr = [System.Collections.ArrayList]@()
		foreach ($ev in $evNodes) {
			$evp = $ev.SelectSingleNode('md:Properties', $nsm)
			$evName = ($evp.SelectSingleNode('md:Name', $nsm)).InnerText
			$evSynNode = $evp.SelectSingleNode('md:Synonym', $nsm)
			$evSyn = Get-MLValue $evSynNode
			$evCmtN = $evp.SelectSingleNode('md:Comment', $nsm); $evCmt = if ($evCmtN) { $evCmtN.InnerText } else { '' }
			# $evSynVal: строка ≠ авто → кастом; {ru,en} → кастом; пустой `<Synonym/>` (node есть, значения нет) →
			# явный '' (≠ авто-синоним из имени, аналог object-level фикса); авто/отсутствие → $null (короткая строка).
			$evSynVal = $null
			if ($evSyn -is [string]) { if ($evSyn -cne (Split-CamelWords $evName)) { $evSynVal = $evSyn } }
			elseif ($null -ne $evSyn) { $evSynVal = $evSyn }
			elseif ($evSynNode) { $evSynVal = '' }
			if (($null -ne $evSynVal) -or $evCmt) {
				$o = [ordered]@{ name = $evName }
				if ($null -ne $evSynVal) { $o['synonym'] = $evSynVal }
				if ($evCmt) { $o['comment'] = $evCmt }
				[void]$evArr.Add($o)
			} else {
				[void]$evArr.Add($evName)
			}
		}
		$dsl['values'] = $evArr
	}
	# DocumentJournal: колонки. Каждая — object {name, synonym?, comment?, indexing?, references[]}.
	# References — список MDObjectRef-путей к реквизитам регистрируемых документов (verbatim).
	$colNodes = @($childObjs.SelectNodes('md:Column', $nsm))
	if ($colNodes.Count -gt 0) {
		$colArr = [System.Collections.ArrayList]@()
		foreach ($col in $colNodes) {
			$cp = $col.SelectSingleNode('md:Properties', $nsm)
			$cName = ($cp.SelectSingleNode('md:Name', $nsm)).InnerText
			$o = [ordered]@{ name = $cName }
			$cSynNode = $cp.SelectSingleNode('md:Synonym', $nsm)
			$cSyn = Get-MLValue $cSynNode
			if ($cSyn -is [string]) { if ($cSyn -cne (Split-CamelWords $cName)) { $o['synonym'] = $cSyn } }
			elseif ($null -ne $cSyn) { $o['synonym'] = $cSyn }
			elseif ($cSynNode) { $o['synonym'] = '' }   # пустой <Synonym/> ≠ авто-синоним → явный ''
			$cCmtN = $cp.SelectSingleNode('md:Comment', $nsm); if ($cCmtN -and $cCmtN.InnerText) { $o['comment'] = $cCmtN.InnerText }
			$cIdxN = $cp.SelectSingleNode('md:Indexing', $nsm); if ($cIdxN -and $cIdxN.InnerText -ne 'DontIndex') { $o['indexing'] = $cIdxN.InnerText }
			$cRefNode = $cp.SelectSingleNode('md:References', $nsm)
			$refs = [System.Collections.ArrayList]@()
			if ($cRefNode) { foreach ($it in @($cRefNode.SelectNodes('xr:Item', $nsm))) { [void]$refs.Add($it.InnerText) } }
			$o['references'] = $refs
			[void]$colArr.Add($o)
		}
		$dsl['columns'] = $colArr
	}
	# ChartOfAccounts: признаки учёта (AccountingFlag) и признаки учёта субконто (ExtDimensionAccountingFlag) —
	# структурно как реквизит, захватываем тем же Attr-ToDsl (тип Boolean уходит в короткую запись).
	$acctFlagNodes = @($childObjs.SelectNodes('md:AccountingFlag', $nsm))
	if ($acctFlagNodes.Count -gt 0) {
		$arr = [System.Collections.ArrayList]@()
		foreach ($a in $acctFlagNodes) { [void]$arr.Add((Attr-ToDsl $a)) }
		$dsl['accountingFlags'] = $arr
	}
	$extDimFlagNodes = @($childObjs.SelectNodes('md:ExtDimensionAccountingFlag', $nsm))
	if ($extDimFlagNodes.Count -gt 0) {
		$arr = [System.Collections.ArrayList]@()
		foreach ($a in $extDimFlagNodes) { [void]$arr.Add((Attr-ToDsl $a)) }
		$dsl['extDimensionAccountingFlags'] = $arr
	}
	# Sequence: измерения несут DocumentMap/RegisterRecordsMap (соответствие реквизитам документов/движениям) —
	# Attr-ToDsl их не знает → отдельный захват объектной формой. Прочие типы (регистры) — общий Attr-ToDsl.
	$dimNodes = @($childObjs.SelectNodes('md:Dimension', $nsm))
	if ($dimNodes.Count -gt 0 -and $objType -eq 'Sequence') {
		$arr = [System.Collections.ArrayList]@()
		foreach ($dn in $dimNodes) {
			$dp = $dn.SelectSingleNode('md:Properties', $nsm)
			$dName = ($dp.SelectSingleNode('md:Name', $nsm)).InnerText
			$o = [ordered]@{ name = $dName }
			$dSyn = Get-MLValue ($dp.SelectSingleNode('md:Synonym', $nsm))
			if ($dSyn -is [string]) { if ($dSyn -cne (Split-CamelWords $dName)) { $o['synonym'] = $dSyn } }
			elseif ($null -ne $dSyn) { $o['synonym'] = $dSyn }
			$dCmtN = $dp.SelectSingleNode('md:Comment', $nsm); if ($dCmtN -and $dCmtN.InnerText) { $o['comment'] = $dCmtN.InnerText }
			$dt = Get-TypeShorthand ($dp.SelectSingleNode('md:Type', $nsm)); if ($dt) { $o['type'] = $dt }
			foreach ($mp in @(@('DocumentMap','documentMap'), @('RegisterRecordsMap','registerRecordsMap'))) {
				$mn = $dp.SelectSingleNode("md:$($mp[0])", $nsm)
				if ($mn) {
					$mItems = @($mn.SelectNodes('xr:Item', $nsm) | ForEach-Object { $_.InnerText })
					if ($mItems.Count -gt 0) { $o[$mp[1]] = [System.Collections.ArrayList]@($mItems) }
				}
			}
			[void]$arr.Add($o)
		}
		$dsl['dimensions'] = $arr
	} elseif ($dimNodes.Count -gt 0) {
		$arr = [System.Collections.ArrayList]@()
		foreach ($a in $dimNodes) { [void]$arr.Add((Attr-ToDsl $a)) }
		$dsl['dimensions'] = $arr
	}
	$resNodes = @($childObjs.SelectNodes('md:Resource', $nsm))
	if ($resNodes.Count -gt 0) {
		$arr = [System.Collections.ArrayList]@()
		foreach ($a in $resNodes) { [void]$arr.Add((Attr-ToDsl $a)) }
		$dsl['resources'] = $arr
	}
	# Задача: реквизиты адресации (AddressingAttribute) — структурно как реквизит + AddressingDimension.
	$addrNodes = @($childObjs.SelectNodes('md:AddressingAttribute', $nsm))
	if ($addrNodes.Count -gt 0) {
		$arr = [System.Collections.ArrayList]@()
		foreach ($a in $addrNodes) { [void]$arr.Add((Attr-ToDsl $a)) }
		$dsl['addressingAttributes'] = $arr
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
			if ($tsSyn -is [string]) { if ($tsSyn -cne (Split-CamelWords $tsName)) { $tsSynCustom = $true } }
			elseif ($null -ne $tsSyn) { $tsSynCustom = $true }
			$tsTt = Get-MLValue ($tsp.SelectSingleNode('md:ToolTip', $nsm))
			$tsCmtN = $tsp.SelectSingleNode('md:Comment', $nsm); $tsCmt = if ($tsCmtN) { $tsCmtN.InnerText } else { '' }
			# FillChecking ТЧ (обязательность заполнения; omit при DontCheck).
			$tsFcN = $tsp.SelectSingleNode('md:FillChecking', $nsm); $tsFc = if ($tsFcN -and $tsFcN.InnerText -ne 'DontCheck') { $tsFcN.InnerText } else { '' }
				# Use ТЧ (иерархические Catalog/ПВХ: ForItem/ForFolder/ForFolderAndItem; omit при дефолте ForItem).
				$tsUseN = $tsp.SelectSingleNode('md:Use', $nsm); $tsUse = if ($tsUseN -and $tsUseN.InnerText -ne 'ForItem') { $tsUseN.InnerText } else { '' }
			# TS-блок стандартных реквизитов (LineNumber). Наличие блока — пер-ТЧ артефакт (~6% ТЧ его опускают,
			# правило не выводимо). Faithful roundtrip: нет блока → маркер подавления `lineNumber: ""` (дом-конвенция);
			# есть блок → захват кастомизации LineNumber (omit-on-default по свойству), all-default → без ключа.
			$lnObj = [ordered]@{}
			$saTsNode = $tsp.SelectSingleNode('md:StandardAttributes', $nsm)
			$hasBlock = ($saTsNode -and @($saTsNode.SelectNodes('xr:StandardAttribute', $nsm)).Count -gt 0)
			$lnNode = if ($hasBlock) { $saTsNode.SelectSingleNode("xr:StandardAttribute[@name='LineNumber']", $nsm) } else { $null }
			if ($lnNode) {
				$lnSyn = Get-MLValue ($lnNode.SelectSingleNode('xr:Synonym', $nsm)); if ($null -ne $lnSyn) { $lnObj['synonym'] = $lnSyn }
				$lnCmtN = $lnNode.SelectSingleNode('xr:Comment', $nsm); if ($lnCmtN -and $lnCmtN.InnerText) { $lnObj['comment'] = $lnCmtN.InnerText }
				$lnFtsN = $lnNode.SelectSingleNode('xr:FullTextSearch', $nsm); if ($lnFtsN -and $lnFtsN.InnerText -ne 'Use') { $lnObj['fullTextSearch'] = $lnFtsN.InnerText }
				$lnTt = Get-MLValue ($lnNode.SelectSingleNode('xr:ToolTip', $nsm)); if ($null -ne $lnTt) { $lnObj['tooltip'] = $lnTt }
				$lnFmt = Get-MLValue ($lnNode.SelectSingleNode('xr:Format', $nsm)); if ($null -ne $lnFmt) { $lnObj['format'] = $lnFmt }
				$lnEfmt = Get-MLValue ($lnNode.SelectSingleNode('xr:EditFormat', $nsm)); if ($null -ne $lnEfmt) { $lnObj['editFormat'] = $lnEfmt }
				$lnChiN = $lnNode.SelectSingleNode('xr:ChoiceHistoryOnInput', $nsm); if ($lnChiN -and $lnChiN.InnerText -ne 'Auto') { $lnObj['choiceHistoryOnInput'] = $lnChiN.InnerText }
				# FillValue НомерСтроки: дефолт nil; редкая аномалия xs:decimal 0 → захват числом (иначе теряется в nil).
				$lnFvN = $lnNode.SelectSingleNode('xr:FillValue', $nsm)
				if ($lnFvN -and $lnFvN.GetAttribute('nil', 'http://www.w3.org/2001/XMLSchema-instance') -ne 'true') {
					$lnFvT = $lnFvN.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
					if ($lnFvT -match 'decimal$') { $lnObj['fillValue'] = if ($lnFvN.InnerText -match '^-?\d+$') { [long]$lnFvN.InnerText } else { [double]$lnFvN.InnerText } }
				}
			}
			if ($tsSynCustom -or ($null -ne $tsTt) -or $tsCmt -or $tsFc -or $tsUse -or $lnObj.Count -gt 0 -or (-not $hasBlock)) {
				$to = [ordered]@{}
				if ($tsSynCustom) { $to['synonym'] = $tsSyn }
				if ($null -ne $tsTt) { $to['tooltip'] = $tsTt }
				if ($tsCmt) { $to['comment'] = $tsCmt }
				if ($tsFc) { $to['fillChecking'] = $tsFc }
				if ($tsUse) { $to['use'] = $tsUse }
				if (-not $hasBlock) { $to['lineNumber'] = '' } elseif ($lnObj.Count -gt 0) { $to['lineNumber'] = $lnObj }
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
			if ($syn -is [string]) { if ($syn -cne (Split-CamelWords $cn)) { $o['synonym'] = $syn } }
			elseif ($null -ne $syn) { $o['synonym'] = $syn }
			$cmtN = $cp.SelectSingleNode('md:Comment', $nsm); if ($cmtN -and $cmtN.InnerText) { $o['comment'] = $cmtN.InnerText }
			$grpN = $cp.SelectSingleNode('md:Group', $nsm); if ($grpN -and $grpN.InnerText) { $o['group'] = $grpN.InnerText }
			$cpt = Get-TypeShorthand ($cp.SelectSingleNode('md:CommandParameterType', $nsm)); if ($cpt) { $o['commandParameterType'] = $cpt }
			$pumN = $cp.SelectSingleNode('md:ParameterUseMode', $nsm); if ($pumN -and $pumN.InnerText -ne 'Single') { $o['parameterUseMode'] = $pumN.InnerText }
			$mdN = $cp.SelectSingleNode('md:ModifiesData', $nsm); if ($mdN -and $mdN.InnerText -eq 'true') { $o['modifiesData'] = $true }
			$repN = $cp.SelectSingleNode('md:Representation', $nsm); if ($repN -and $repN.InnerText -ne 'Auto') { $o['representation'] = $repN.InnerText }
			$ctt = Get-MLValue ($cp.SelectSingleNode('md:ToolTip', $nsm)); if ($null -ne $ctt) { $o['tooltip'] = $ctt }
			# <Picture> — структурный блок (зеркало form-decompile Set-CommandPicture). Дефолт LoadTransparent=true:
			# скаляр `picture` + sibling `loadTransparent:false` при отклонении; объект {src,loadTransparent?,transparentPixel} при TransparentPixel.
			$refN = $cp.SelectSingleNode('md:Picture/xr:Ref', $nsm)
			$absN = $cp.SelectSingleNode('md:Picture/xr:Abs', $nsm)
			if ($refN -or $absN) {
				$psrc = if ($refN) { $refN.InnerText } else { "abs:$($absN.InnerText)" }
				$ltN = $cp.SelectSingleNode('md:Picture/xr:LoadTransparent', $nsm)
				$ltFalse = ($ltN -and $ltN.InnerText -eq 'false')
				$tpxN = $cp.SelectSingleNode('md:Picture/xr:TransparentPixel', $nsm)
				if ($tpxN) {
					$po = [ordered]@{ src = $psrc }
					if ($ltFalse) { $po['loadTransparent'] = $false }
					$po['transparentPixel'] = [ordered]@{ x = [int]$tpxN.GetAttribute('x'); y = [int]$tpxN.GetAttribute('y') }
					$o['picture'] = $po
				} else {
					$o['picture'] = $psrc
					if ($ltFalse) { $o['loadTransparent'] = $false }
				}
			}
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
		# Type — тип значения предопределённой характеристики (ПВХ). Наличие → object-форма (в строку не влезает).
		# Наличие узла <Type> (даже пустого <Type/>) → object-форма с ключом type ('' для пустого); нет узла (Catalog) → без.
		$typeEl = $itemEl.SelectSingleNode("*[local-name()='Type']")
		$typeStr = if ($typeEl) { Get-TypeShorthand $typeEl } else { $null }
		$auto = Split-CamelWords $name

		# Компактная строка для плоских: без узла Type (Catalog) ИЛИ с непустым типом → "(Код) Имя [Наим]: Тип".
		# Пустой <Type/> в короткую не влезает (нужен явный маркер) → object-форма с type:''.
		if (-not $isFolder -and $kids.Count -eq 0 -and ($null -eq $typeStr -or $typeStr -ne '')) {
			$s = if ($code) { "($code) $name" } else { $name }
			if ($desc -eq '') { $s = "$s []" }
			elseif ($desc -cne $auto) { $s = "$s [$desc]" }
			if ($typeStr) { $s = "${s}: $typeStr" }
			return $s
		}
		# Группа/иерархия/с типом → объект.
		$o = [ordered]@{ name = $name }
		if ($code) { $o['code'] = $code }
		if ($desc -eq '') { $o['description'] = '' }
		elseif ($desc -cne $auto) { $o['description'] = $desc }
		if ($null -ne $typeStr) { $o['type'] = $typeStr }
		if ($isFolder) { $o['isFolder'] = $true }
		if ($kids.Count -gt 0) {
			$sub = [System.Collections.ArrayList]@()
			foreach ($k in $kids) { [void]$sub.Add((PredefItem-ToDsl $k)) }
			$o['childItems'] = $sub
		}
		return $o
	}
		# Предопределённые СЧЕТА Плана счетов — отдельная грамматика (AccountType/OffBalance/Order/AccountingFlags/
		# ExtDimensionTypes). Флаги: захватываем только TRUE (компилятор развернёт по def-порядку признаков плана).
		function PredefAccount-ToDsl {
			param($itemEl)
			$name = ($itemEl.SelectSingleNode("*[local-name()='Name']")).InnerText
			$codeEl = $itemEl.SelectSingleNode("*[local-name()='Code']")
			$code = if ($codeEl -and $codeEl.InnerText) { $codeEl.InnerText } else { '' }
			$descEl = $itemEl.SelectSingleNode("*[local-name()='Description']")
			$desc = if ($descEl) { $descEl.InnerText } else { '' }
			$atEl = $itemEl.SelectSingleNode("*[local-name()='AccountType']")
			$acctType = if ($atEl) { $atEl.InnerText } else { 'ActivePassive' }
			$offEl = $itemEl.SelectSingleNode("*[local-name()='OffBalance']")
			$off = ($offEl -and $offEl.InnerText -eq 'true')
			$ordEl = $itemEl.SelectSingleNode("*[local-name()='Order']")
			$order = if ($ordEl) { $ordEl.InnerText } else { '' }
			$auto = Split-CamelWords $name
			# TRUE-флаги (leaf после последней точки в ref).
			$trueFlags = @()
			foreach ($fl in @($itemEl.SelectNodes("*[local-name()='AccountingFlags']/*[local-name()='Flag']"))) {
				if ($fl.InnerText -eq 'true') { $r = $fl.GetAttribute('ref'); $trueFlags += ($r -split '\.')[-1] }
			}
			# ExtDimensionTypes → subconto. Короткая запись "Тип | Признак1, Признак2": срезаем префикс ПВХ видов субконто
			# плана (extDimensionTypes); «Только обороты» (Turnover=true) — предопределённый признак-токен `Turnover` первым
			# в списке (наравне с добавленными). Захватываем только TRUE-признаки (компилятор развернёт по def-порядку).
			$edtPfx = if ($dsl['extDimensionTypes']) { "$($dsl['extDimensionTypes'])." } else { $null }
			$subconto = [System.Collections.ArrayList]@()
			foreach ($edt in @($itemEl.SelectNodes("*[local-name()='ExtDimensionTypes']/*[local-name()='ExtDimensionType']"))) {
				$scT = $edt.GetAttribute('name')
				if ($edtPfx -and $scT.StartsWith($edtPfx)) { $scT = $scT.Substring($edtPfx.Length) }
				$tEl = $edt.SelectSingleNode("*[local-name()='Turnover']")
				$scFlagsOut = @()
				if ($tEl -and $tEl.InnerText -eq 'true') { $scFlagsOut += 'Turnover' }
				foreach ($fl in @($edt.SelectNodes("*[local-name()='AccountingFlags']/*[local-name()='Flag']"))) {
					if ($fl.InnerText -eq 'true') { $r = $fl.GetAttribute('ref'); $scFlagsOut += ($r -split '\.')[-1] }
				}
				if ($scFlagsOut.Count -gt 0) { [void]$subconto.Add("$scT | " + ($scFlagsOut -join ', ')) }
				else { [void]$subconto.Add($scT) }
			}
			$childContainer = $itemEl.SelectSingleNode("*[local-name()='ChildItems']")
			$kids = @(if ($childContainer) { $childContainer.SelectNodes("*[local-name()='Item']") } else { @() })

			$o = [ordered]@{ name = $name }
			if ($code) { $o['code'] = $code }
			# -cne (регистрочувствительно!): PS `-ne` регистронезависим → «…ОС» == «…ос» и description ошибочно
			# опускался, а компилятор регенерил lowercase (Split-CamelCase). Хвостовые аббревиатуры (ОС/НМА) теряли регистр.
			if ($desc -cne $auto) { $o['description'] = $desc }
			$o['accountType'] = $acctType
			if ($off) { $o['offBalance'] = $true }
			$o['order'] = $order
			if ($trueFlags.Count -gt 0) { $o['flags'] = [System.Collections.ArrayList]@($trueFlags) }
			if ($subconto.Count -gt 0) { $o['subconto'] = $subconto }
			if ($kids.Count -gt 0) {
				$sub = [System.Collections.ArrayList]@()
				foreach ($k in $kids) { [void]$sub.Add((PredefAccount-ToDsl $k)) }
				$o['childItems'] = $sub
			}
			return $o
		}

		# Предопределённые ВИДЫ РАСЧЁТА (плоские): Name/Code/Description/ActionPeriodIsBase. Строка при
		# ActionPeriodIsBase=false, объект — при true.
		function PredefCalcType-ToDsl {
			param($itemEl)
			$name = ($itemEl.SelectSingleNode("*[local-name()='Name']")).InnerText
			$codeEl = $itemEl.SelectSingleNode("*[local-name()='Code']"); $code = if ($codeEl -and $codeEl.InnerText) { $codeEl.InnerText } else { '' }
			$descEl = $itemEl.SelectSingleNode("*[local-name()='Description']"); $desc = if ($descEl) { $descEl.InnerText } else { '' }
			$apibEl = $itemEl.SelectSingleNode("*[local-name()='ActionPeriodIsBase']"); $apib = ($apibEl -and $apibEl.InnerText -eq 'true')
			$auto = Split-CamelWords $name
			if (-not $apib) {
				$s = if ($code) { "($code) $name" } else { $name }
				if ($desc -eq '') { $s = "$s []" } elseif ($desc -cne $auto) { $s = "$s [$desc]" }
				return $s
			}
			$o = [ordered]@{ name = $name }
			if ($code) { $o['code'] = $code }
			if ($desc -cne $auto) { $o['description'] = $desc }
			$o['actionPeriodIsBase'] = $true
			return $o
		}

	$rootItems = [System.Collections.ArrayList]@()
	if ($objType -eq 'ChartOfAccounts') {
		foreach ($it in @($pdoc.DocumentElement.SelectNodes("*[local-name()='Item']"))) { [void]$rootItems.Add((PredefAccount-ToDsl $it)) }
	} elseif ($objType -eq 'ChartOfCalculationTypes') {
		foreach ($it in @($pdoc.DocumentElement.SelectNodes("*[local-name()='Item']"))) { [void]$rootItems.Add((PredefCalcType-ToDsl $it)) }
	} else {
		foreach ($it in @($pdoc.DocumentElement.SelectNodes("*[local-name()='Item']"))) { [void]$rootItems.Add((PredefItem-ToDsl $it)) }
	}
	if ($rootItems.Count -gt 0) { $dsl['predefined'] = $rootItems }
}

# --- Состав плана обмена (соседний Ext/Content.xml) → DSL content (ExchangePlan).
# Каждый <Item>{<Metadata>MDRef</Metadata><AutoRecord>Deny|Allow</AutoRecord>}.
# Deny (дефолт) → строка "MDRef"; Allow → "MDRef: autoRecord". ---
if ($objType -eq 'ExchangePlan') {
	$contentPath = Join-Path (Join-Path (Join-Path $objDir $objName) 'Ext') 'Content.xml'
	if (Test-Path -LiteralPath $contentPath) {
		$cdoc = New-Object System.Xml.XmlDocument
		$cdoc.Load($contentPath)
		$contentItems = [System.Collections.ArrayList]@()
		foreach ($it in @($cdoc.DocumentElement.SelectNodes("*[local-name()='Item']"))) {
			$mdEl = $it.SelectSingleNode("*[local-name()='Metadata']")
			if (-not $mdEl -or -not $mdEl.InnerText) { continue }
			$ref = $mdEl.InnerText
			$arEl = $it.SelectSingleNode("*[local-name()='AutoRecord']")
			$ar = if ($arEl) { $arEl.InnerText } else { 'Deny' }
			if ($ar -eq 'Allow') { [void]$contentItems.Add("${ref}: autoRecord") } else { [void]$contentItems.Add($ref) }
		}
		if ($contentItems.Count -gt 0) { $dsl['content'] = $contentItems }
	}
}

# === Вывод ===
$json = ConvertTo-CompactJson $dsl 0
if ($OutputPath) {
	[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
} else {
	[Console]::Out.WriteLine($json)
}
