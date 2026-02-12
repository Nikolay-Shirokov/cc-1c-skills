# meta-info v1.0 — Compact summary of 1C metadata object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory=$true)][string]$ObjectPath,
	[ValidateSet("overview","brief","full")]
	[string]$Mode = "overview",
	[string]$Name,
	[int]$Limit = 150,
	[int]$Offset = 0,
	[string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Output helper (always collect, paginate at the end) ---
$script:lines = @()
function Out([string]$text) { $script:lines += $text }

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($ObjectPath)) {
	$ObjectPath = Join-Path (Get-Location).Path $ObjectPath
}

# Directory -> find XML inside
if (Test-Path $ObjectPath -PathType Container) {
	$dirName = Split-Path $ObjectPath -Leaf
	$candidate = Join-Path $ObjectPath "$dirName.xml"
	if (Test-Path $candidate) {
		$ObjectPath = $candidate
	} else {
		$xmlFiles = @(Get-ChildItem $ObjectPath -Filter "*.xml" -File | Select-Object -First 1)
		if ($xmlFiles.Count -gt 0) {
			$ObjectPath = $xmlFiles[0].FullName
		} else {
			Write-Host "[ERROR] No XML file found in directory: $ObjectPath"
			exit 1
		}
	}
}

if (-not (Test-Path $ObjectPath)) {
	Write-Host "[ERROR] File not found: $ObjectPath"
	exit 1
}

# --- Load XML ---
[xml]$xmlDoc = Get-Content -Path $ObjectPath -Encoding UTF8
$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("cfg", "http://v8.1c.ru/8.1/data/enterprise/current-config")
$ns.AddNamespace("app", "http://v8.1c.ru/8.2/managed-application/core")

$mdRoot = $xmlDoc.SelectSingleNode("/md:MetaDataObject", $ns)
if (-not $mdRoot) {
	Write-Host "[ERROR] Not a valid 1C metadata XML file"
	exit 1
}

# --- Detect object type ---
$typeNode = $null
$mdType = ""
foreach ($child in $mdRoot.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.NamespaceURI -eq "http://v8.1c.ru/8.3/MDClasses") {
		$typeNode = $child
		$mdType = $child.LocalName
		break
	}
}

if (-not $typeNode) {
	Write-Host "[ERROR] Cannot detect metadata type"
	exit 1
}

# --- Type name maps ---
$typeNameMap = @{
	"Catalog"="Справочник"; "Document"="Документ"; "Enum"="Перечисление"
	"Constant"="Константа"; "InformationRegister"="Регистр сведений"
	"AccumulationRegister"="Регистр накопления"; "AccountingRegister"="Регистр бухгалтерии"
	"CalculationRegister"="Регистр расчёта"; "ChartOfAccounts"="План счетов"
	"ChartOfCharacteristicTypes"="План видов характеристик"
	"ChartOfCalculationTypes"="План видов расчёта"; "BusinessProcess"="Бизнес-процесс"
	"Task"="Задача"; "ExchangePlan"="План обмена"; "DocumentJournal"="Журнал документов"
	"Report"="Отчёт"; "DataProcessor"="Обработка"
}

$refTypeMap = @{
	"CatalogRef"="СправочникСсылка"; "DocumentRef"="ДокументСсылка"
	"EnumRef"="ПеречислениеСсылка"; "ChartOfAccountsRef"="ПланСчетовСсылка"
	"ChartOfCharacteristicTypesRef"="ПВХСсылка"; "ChartOfCalculationTypesRef"="ПВРСсылка"
	"ExchangePlanRef"="ПланОбменаСсылка"; "BusinessProcessRef"="БизнесПроцессСсылка"
	"TaskRef"="ЗадачаСсылка"
}

$regTypeMap = @{
	"AccumulationRegister"="РН"; "AccountingRegister"="РБ"; "CalculationRegister"="РР"
	"InformationRegister"="РС"
}

$periodMap = @{
	"Nonperiodical"="Непериодический"; "Day"="День"; "Month"="Месяц"
	"Quarter"="Квартал"; "Year"="Год"; "Second"="Секунда"
}

$writeModeMap = @{
	"Independent"="независимая"; "RecorderSubordinate"="подчинение регистратору"
}

$numberPeriodMap = @{
	"Year"="по году"; "Quarter"="по кварталу"; "Month"="по месяцу"; "Day"="по дню"
	"WholeCatalog"="сквозная"
}

$ruTypeName = if ($typeNameMap.ContainsKey($mdType)) { $typeNameMap[$mdType] } else { $mdType }

# --- Helpers ---

function Get-MLText($node) {
	if (-not $node) { return "" }
	$c = $node.SelectSingleNode("v8:item[v8:lang='ru']/v8:content", $ns)
	if ($c) { return $c.InnerText }
	$c = $node.SelectSingleNode("v8:item/v8:content", $ns)
	if ($c) { return $c.InnerText }
	$text = $node.InnerText.Trim()
	if ($text) { return $text }
	return ""
}

function Format-Type($typeNode) {
	if (-not $typeNode) { return "" }
	$types = @()
	foreach ($t in $typeNode.SelectNodes("v8:Type", $ns)) {
		$raw = $t.InnerText
		$types += Format-SingleType $raw $typeNode
	}
	foreach ($t in $typeNode.SelectNodes("v8:TypeSet", $ns)) {
		$raw = $t.InnerText
		if ($raw -match '^cfg:DefinedType\.(.+)$') {
			$types += "ОпределяемыйТип.$($Matches[1])"
		} else {
			$types += $raw
		}
	}
	if ($types.Count -eq 0) { return "" }
	if ($types.Count -eq 1) { return $types[0] }
	return ($types -join " | ")
}

function Format-SingleType([string]$raw, $parentNode) {
	switch -Wildcard ($raw) {
		"xs:string" {
			$sq = $parentNode.SelectSingleNode("v8:StringQualifiers/v8:Length", $ns)
			$len = if ($sq) { $sq.InnerText } else { "" }
			if ($len) { return "Строка($len)" } else { return "Строка" }
		}
		"xs:decimal" {
			$dg = $parentNode.SelectSingleNode("v8:NumberQualifiers/v8:Digits", $ns)
			$fr = $parentNode.SelectSingleNode("v8:NumberQualifiers/v8:FractionDigits", $ns)
			$d = if ($dg) { $dg.InnerText } else { "" }
			$f = if ($fr) { $fr.InnerText } else { "0" }
			if ($d) { return "Число($d,$f)" } else { return "Число" }
		}
		"xs:boolean" { return "Булево" }
		"xs:dateTime" {
			$dq = $parentNode.SelectSingleNode("v8:DateQualifiers/v8:DateFractions", $ns)
			if ($dq) {
				switch ($dq.InnerText) {
					"Date" { return "Дата" }
					"Time" { return "Время" }
					"DateTime" { return "ДатаВремя" }
					default { return "Дата" }
				}
			}
			return "ДатаВремя"
		}
		"v8:ValueStorage" { return "ХранилищеЗначения" }
		"v8:UUID" { return "УникальныйИдентификатор" }
		"v8:Null" { return "Null" }
		default {
			# cfg:CatalogRef.Xxx -> СправочникСсылка.Xxx
			if ($raw -match '^cfg:(\w+)Ref\.(.+)$') {
				$prefix = "$($Matches[1])Ref"
				$objn = $Matches[2]
				if ($refTypeMap.ContainsKey($prefix)) {
					return "$($refTypeMap[$prefix]).$objn"
				}
			}
			# cfg:EnumRef.Xxx
			if ($raw -match '^cfg:EnumRef\.(.+)$') {
				return "ПеречислениеСсылка.$($Matches[1])"
			}
			# cfg:DefinedType.Xxx
			if ($raw -match '^cfg:DefinedType\.(.+)$') {
				return "ОпределяемыйТип.$($Matches[1])"
			}
			# Strip cfg: prefix for unknown
			if ($raw -match '^cfg:(.+)$') {
				return $Matches[1]
			}
			return $raw
		}
	}
}

function Format-Flags($propsNode, [bool]$isDimension = $false) {
	$flags = @()
	$fc = $propsNode.SelectSingleNode("md:FillChecking", $ns)
	if ($fc -and $fc.InnerText -eq "ShowError") { $flags += "обязательный" }

	$idx = $propsNode.SelectSingleNode("md:Indexing", $ns)
	if ($idx) {
		switch ($idx.InnerText) {
			"Index" { $flags += "индекс" }
			"IndexWithAdditionalOrder" { $flags += "индекс+доп" }
		}
	}

	if ($isDimension) {
		$master = $propsNode.SelectSingleNode("md:Master", $ns)
		if ($master -and $master.InnerText -eq "true") { $flags += "ведущее" }
	}

	$ml = $propsNode.SelectSingleNode("md:MultiLine", $ns)
	if ($ml -and $ml.InnerText -eq "true") { $flags += "многострочный" }

	$use = $propsNode.SelectSingleNode("md:Use", $ns)
	if ($use) {
		switch ($use.InnerText) {
			"ForFolder" { $flags += "для папок" }
			"ForFolderAndItem" { $flags += "для папок и элементов" }
		}
	}

	if ($flags.Count -eq 0) { return "" }
	return "  [$($flags -join ', ')]"
}

function Get-Attributes($parentNode, [string]$childTag = "Attribute", [bool]$isDimension = $false) {
	$result = @()
	foreach ($attr in $parentNode.SelectNodes("md:$childTag", $ns)) {
		$aprops = $attr.SelectSingleNode("md:Properties", $ns)
		if (-not $aprops) { continue }
		$attrName = $aprops.SelectSingleNode("md:Name", $ns).InnerText
		$typeStr = Format-Type $aprops.SelectSingleNode("md:Type", $ns)
		$aflags = Format-Flags $aprops $isDimension
		$result += @{ Name=$attrName; Type=$typeStr; Flags=$aflags; Props=$aprops }
	}
	return $result
}

function Get-TabularSections($parentNode) {
	$result = @()
	foreach ($ts in $parentNode.SelectNodes("md:TabularSection", $ns)) {
		$tprops = $ts.SelectSingleNode("md:Properties", $ns)
		$tsName = $tprops.SelectSingleNode("md:Name", $ns).InnerText
		$tchildObjs = $ts.SelectSingleNode("md:ChildObjects", $ns)
		$cols = @()
		if ($tchildObjs) { $cols = @(Get-Attributes $tchildObjs) }
		$result += @{ Name=$tsName; Columns=$cols; ColCount=$cols.Count }
	}
	return $result
}

function Format-AttrLine([hashtable]$attr, [int]$maxNameLen = 30) {
	$padded = $attr.Name.PadRight($maxNameLen)
	return "  $padded $($attr.Type)$($attr.Flags)"
}

function Get-MaxNameLen($attrs) {
	$max = 10
	foreach ($a in $attrs) {
		if ($a.Name.Length -gt $max) { $max = $a.Name.Length }
	}
	return [Math]::Min($max + 2, 40)
}

function Get-SimpleChildren($parentNode, [string]$tag) {
	$result = @()
	foreach ($child in $parentNode.SelectNodes("md:$tag", $ns)) {
		$result += $child.InnerText
	}
	return $result
}

function Decline-Cols([int]$n) {
	$m = $n % 10
	$h = $n % 100
	if ($h -ge 11 -and $h -le 19) { return "колонок" }
	if ($m -eq 1) { return "колонка" }
	if ($m -ge 2 -and $m -le 4) { return "колонки" }
	return "колонок"
}

# --- Extract metadata ---
$props = $typeNode.SelectSingleNode("md:Properties", $ns)
$childObjs = $typeNode.SelectSingleNode("md:ChildObjects", $ns)
$objName = $props.SelectSingleNode("md:Name", $ns).InnerText
$synNode = $props.SelectSingleNode("md:Synonym", $ns)
$synonym = Get-MLText $synNode

# --- Handle -Name drill-down ---
$drillDone = $false
if ($Name -and $childObjs) {
	# Search in attributes/dimensions/resources
	$attrTags = @("Attribute","Dimension","Resource")
	foreach ($tag in $attrTags) {
		if ($drillDone) { break }
		foreach ($attr in $childObjs.SelectNodes("md:$tag", $ns)) {
			$ap = $attr.SelectSingleNode("md:Properties", $ns)
			if (-not $ap) { continue }
			$an = $ap.SelectSingleNode("md:Name", $ns).InnerText
			if ($an -eq $Name) {
				$tagRu = switch ($tag) {
					"Attribute" { "Реквизит" }
					"Dimension" { "Измерение" }
					"Resource" { "Ресурс" }
				}
				Out "$($tagRu): $an"
				$typeStr = Format-Type $ap.SelectSingleNode("md:Type", $ns)
				Out "  Тип: $typeStr"
				$fc = $ap.SelectSingleNode("md:FillChecking", $ns)
				Out "  Обязательный: $(if ($fc -and $fc.InnerText -eq 'ShowError') { 'да' } else { 'нет' })"
				$idx = $ap.SelectSingleNode("md:Indexing", $ns)
				Out "  Индексирование: $(if ($idx) { $idx.InnerText } else { 'нет' })"
				$ml = $ap.SelectSingleNode("md:MultiLine", $ns)
				if ($ml -and $ml.InnerText -eq "true") { Out "  Многострочный: да" }
				$use = $ap.SelectSingleNode("md:Use", $ns)
				if ($use -and $use.InnerText -ne "ForItem") { Out "  Использование: $($use.InnerText)" }
				$fv = $ap.SelectSingleNode("md:FillValue", $ns)
				if ($fv -and -not ($fv.GetAttribute("nil", "http://www.w3.org/2001/XMLSchema-instance") -eq "true") -and $fv.InnerText) {
					Out "  Значение заполнения: $($fv.InnerText)"
				} else {
					Out "  Значение заполнения: —"
				}
				if ($tag -eq "Dimension") {
					$master = $ap.SelectSingleNode("md:Master", $ns)
					Out "  Ведущее: $(if ($master -and $master.InnerText -eq 'true') { 'да' } else { 'нет' })"
					$mf = $ap.SelectSingleNode("md:MainFilter", $ns)
					Out "  Основной отбор: $(if ($mf -and $mf.InnerText -eq 'true') { 'да' } else { 'нет' })"
				}
				$synA = $ap.SelectSingleNode("md:Synonym", $ns)
				$synText = Get-MLText $synA
				if ($synText -and $synText -ne $an) { Out "  Синоним: $synText" }
				$drillDone = $true
				break
			}
		}
	}

	# Search in tabular sections
	if (-not $drillDone) {
		foreach ($ts in $childObjs.SelectNodes("md:TabularSection", $ns)) {
			$tp = $ts.SelectSingleNode("md:Properties", $ns)
			$tn = $tp.SelectSingleNode("md:Name", $ns).InnerText
			if ($tn -eq $Name) {
				$tsCO = $ts.SelectSingleNode("md:ChildObjects", $ns)
				$cols = @()
				if ($tsCO) { $cols = @(Get-Attributes $tsCO) }
				Out "ТЧ: $tn ($($cols.Count) $(Decline-Cols $cols.Count)):"
				if ($cols.Count -gt 0) {
					$ml = Get-MaxNameLen $cols
					foreach ($c in $cols) { Out (Format-AttrLine $c $ml) }
				}
				$drillDone = $true
				break
			}
		}
	}

	# Search in enum values
	if (-not $drillDone) {
		foreach ($ev in $childObjs.SelectNodes("md:EnumValue", $ns)) {
			$ep = $ev.SelectSingleNode("md:Properties", $ns)
			$en = $ep.SelectSingleNode("md:Name", $ns).InnerText
			if ($en -eq $Name) {
				$synE = $ep.SelectSingleNode("md:Synonym", $ns)
				$synText = Get-MLText $synE
				Out "Значение перечисления: $en"
				if ($synText) { Out "  Синоним: `"$synText`"" }
				$cm = $ep.SelectSingleNode("md:Comment", $ns)
				if ($cm -and $cm.InnerText) { Out "  Комментарий: $($cm.InnerText)" }
				$drillDone = $true
				break
			}
		}
	}

	if (-not $drillDone) {
		Write-Host "[ERROR] '$Name' not found in $objName"
		exit 1
	}
}

# --- Main output (not drill-down) ---
if (-not $drillDone) {

	# --- Build header ---
	$header = "=== $ruTypeName`: $objName"
	if ($synonym -and $synonym -ne $objName) { $header += " — `"$synonym`"" }
	$header += " ==="
	Out $header

	# --- Mode: brief ---
	if ($Mode -eq "brief") {
		# Attributes
		$attrs = @()
		if ($childObjs) { $attrs = @(Get-Attributes $childObjs) }
		if ($attrs.Count -gt 0) {
			$names = ($attrs | ForEach-Object { $_.Name }) -join ", "
			Out "Реквизиты ($($attrs.Count)): $names"
		}

		# Dimensions/Resources for registers
		if ($mdType -match "Register$") {
			$dims = @()
			if ($childObjs) { $dims = @(Get-Attributes $childObjs "Dimension" $true) }
			if ($dims.Count -gt 0) {
				$names = ($dims | ForEach-Object { $_.Name }) -join ", "
				Out "Измерения ($($dims.Count)): $names"
			}
			$res = @()
			if ($childObjs) { $res = @(Get-Attributes $childObjs "Resource") }
			if ($res.Count -gt 0) {
				$names = ($res | ForEach-Object { $_.Name }) -join ", "
				Out "Ресурсы ($($res.Count)): $names"
			}
		}

		# Tabular sections
		$tss = @()
		if ($childObjs) { $tss = @(Get-TabularSections $childObjs) }
		if ($tss.Count -gt 0) {
			$tsParts = $tss | ForEach-Object { "$($_.Name)($($_.ColCount))" }
			Out "ТЧ ($($tss.Count)): $($tsParts -join ', ')"
		}

		# Enum values
		if ($mdType -eq "Enum") {
			$vals = @()
			if ($childObjs) {
				foreach ($ev in $childObjs.SelectNodes("md:EnumValue", $ns)) {
					$ep = $ev.SelectSingleNode("md:Properties", $ns)
					$vals += $ep.SelectSingleNode("md:Name", $ns).InnerText
				}
			}
			if ($vals.Count -gt 0) {
				Out "Значения ($($vals.Count)): $($vals -join ', ')"
			}
		}
	} else {
		# --- Mode: overview / full ---

		# Document-specific header properties
		if ($mdType -eq "Document") {
			$numType = $props.SelectSingleNode("md:NumberType", $ns)
			$numLen = $props.SelectSingleNode("md:NumberLength", $ns)
			$numPer = $props.SelectSingleNode("md:NumberPeriodicity", $ns)
			$autoNum = $props.SelectSingleNode("md:Autonumbering", $ns)
			$posting = $props.SelectSingleNode("md:Posting", $ns)

			$parts = @()
			if ($numType -and $numLen) {
				$nt = if ($numType.InnerText -eq "String") { "Строка" } else { "Число" }
				$piece = "Номер: $nt($($numLen.InnerText))"
				if ($numPer) {
					$perRu = if ($numberPeriodMap.ContainsKey($numPer.InnerText)) { $numberPeriodMap[$numPer.InnerText] } else { $numPer.InnerText }
					$piece += ", $perRu"
				}
				if ($autoNum -and $autoNum.InnerText -eq "true") { $piece += ", авто" }
				$parts += $piece
			}
			if ($posting) {
				$parts += "Проведение: $(if ($posting.InnerText -eq 'Allow') { 'да' } else { 'нет' })"
			}
			if ($parts.Count -gt 0) { Out ($parts -join " | ") }
		}

		# Catalog-specific header properties
		if ($mdType -eq "Catalog") {
			$parts = @()
			$hier = $props.SelectSingleNode("md:Hierarchical", $ns)
			if ($hier -and $hier.InnerText -eq "true") {
				$ht = $props.SelectSingleNode("md:HierarchyType", $ns)
				$htText = if ($ht -and $ht.InnerText -eq "HierarchyFoldersAndItems") { "группы и элементы" } else { "элементы" }
				$parts += "Иерархический: $htText"
			}
			$codeLen = $props.SelectSingleNode("md:CodeLength", $ns)
			$descLen = $props.SelectSingleNode("md:DescriptionLength", $ns)
			if ($codeLen -and [int]$codeLen.InnerText -gt 0) { $parts += "Код($($codeLen.InnerText))" }
			if ($descLen -and [int]$descLen.InnerText -gt 0) { $parts += "Наименование($($descLen.InnerText))" }
			if ($parts.Count -gt 0) { Out ($parts -join " | ") }
		}

		# Register-specific header properties
		if ($mdType -match "Register$") {
			$parts = @()
			if ($mdType -eq "InformationRegister") {
				$per = $props.SelectSingleNode("md:InformationRegisterPeriodicity", $ns)
				if ($per) {
					$perRu = if ($periodMap.ContainsKey($per.InnerText)) { $periodMap[$per.InnerText] } else { $per.InnerText }
					$parts += "Периодичность: $perRu"
				}
				$wm = $props.SelectSingleNode("md:WriteMode", $ns)
				if ($wm) {
					$wmRu = if ($writeModeMap.ContainsKey($wm.InnerText)) { $writeModeMap[$wm.InnerText] } else { $wm.InnerText }
					$parts += "Запись: $wmRu"
				}
			}
			if ($mdType -eq "AccumulationRegister") {
				$regKind = $props.SelectSingleNode("md:RegisterType", $ns)
				if ($regKind) {
					$rkRu = switch ($regKind.InnerText) {
						"Balances" { "остатки" }
						"Turnovers" { "обороты" }
						default { $regKind.InnerText }
					}
					$parts += "Вид: $rkRu"
				}
			}
			if ($parts.Count -gt 0) { Out ($parts -join " | ") }
		}

		# --- Enum values ---
		if ($mdType -eq "Enum" -and $childObjs) {
			$vals = @()
			foreach ($ev in $childObjs.SelectNodes("md:EnumValue", $ns)) {
				$ep = $ev.SelectSingleNode("md:Properties", $ns)
				$vName = $ep.SelectSingleNode("md:Name", $ns).InnerText
				$vSyn = Get-MLText $ep.SelectSingleNode("md:Synonym", $ns)
				$vals += @{ Name=$vName; Synonym=$vSyn }
			}
			if ($vals.Count -gt 0) {
				Out ""
				Out "Значения ($($vals.Count)):"
				$ml = Get-MaxNameLen $vals
				foreach ($v in $vals) {
					$padded = $v.Name.PadRight($ml)
					$synText = if ($v.Synonym -and $v.Synonym -ne $v.Name) { "`"$($v.Synonym)`"" } else { "" }
					Out "  $padded $synText"
				}
			}
		}

		# --- Dimensions (registers) ---
		if ($mdType -match "Register$" -and $childObjs) {
			$dims = @(Get-Attributes $childObjs "Dimension" $true)
			if ($dims.Count -gt 0) {
				Out ""
				Out "Измерения ($($dims.Count)):"
				$ml = Get-MaxNameLen $dims
				foreach ($d in $dims) { Out (Format-AttrLine $d $ml) }
			}
		}

		# --- Resources (registers) ---
		if ($mdType -match "Register$" -and $childObjs) {
			$res = @(Get-Attributes $childObjs "Resource")
			if ($res.Count -gt 0) {
				Out ""
				Out "Ресурсы ($($res.Count)):"
				$ml = Get-MaxNameLen $res
				foreach ($r in $res) { Out (Format-AttrLine $r $ml) }
			}
		}

		# --- Attributes ---
		if ($childObjs -and $mdType -ne "Enum") {
			$attrs = @(Get-Attributes $childObjs)
			if ($attrs.Count -gt 0) {
				Out ""
				Out "Реквизиты ($($attrs.Count)):"
				$ml = Get-MaxNameLen $attrs
				foreach ($a in $attrs) { Out (Format-AttrLine $a $ml) }
			}
		}

		# --- Tabular sections ---
		if ($childObjs -and $mdType -ne "Enum") {
			$tss = @(Get-TabularSections $childObjs)
			if ($tss.Count -gt 0) {
				if ($Mode -eq "full") {
					foreach ($ts in $tss) {
						Out ""
						Out "ТЧ $($ts.Name) ($($ts.ColCount) $(Decline-Cols $ts.ColCount)):"
						if ($ts.ColCount -gt 0) {
							$ml = Get-MaxNameLen $ts.Columns
							foreach ($c in $ts.Columns) { Out (Format-AttrLine $c $ml) }
						}
					}
				} else {
					# overview — just names with column counts
					Out ""
					$tsParts = $tss | ForEach-Object { "$($_.Name)($($_.ColCount))" }
					Out "ТЧ ($($tss.Count)): $($tsParts -join ', ')"
				}
			}
		}

		# --- Full mode: additional sections ---
		if ($Mode -eq "full" -and $childObjs) {
			# Register records (documents)
			if ($mdType -eq "Document") {
				$regRecs = @()
				foreach ($item in $props.SelectNodes("md:RegisterRecords/xr:Item", $ns)) {
					$raw = $item.InnerText
					if ($raw -match '^(\w+)\.(.+)$') {
						$prefix = $Matches[1]
						$rname = $Matches[2]
						$short = if ($regTypeMap.ContainsKey($prefix)) { $regTypeMap[$prefix] } else { $prefix }
						$regRecs += "$short.$rname"
					} else {
						$regRecs += $raw
					}
				}
				if ($regRecs.Count -gt 0) {
					Out ""
					Out "Движения ($($regRecs.Count)): $($regRecs -join ', ')"
				}

				# BasedOn
				$basedOn = @()
				foreach ($item in $props.SelectNodes("md:BasedOn/xr:Item", $ns)) {
					$raw = $item.InnerText
					if ($raw -match '^\w+\.(.+)$') { $basedOn += $Matches[1] } else { $basedOn += $raw }
				}
				if ($basedOn.Count -gt 0) {
					Out "Ввод на основании: $($basedOn -join ', ')"
				}
			}

			# Forms
			$forms = @(Get-SimpleChildren $childObjs "Form")
			if ($forms.Count -gt 0) {
				Out "Формы: $($forms -join ', ')"
			}

			# Templates
			$templates = @(Get-SimpleChildren $childObjs "Template")
			if ($templates.Count -gt 0) {
				Out "Макеты: $($templates -join ', ')"
			}

			# Commands
			$commands = @(Get-SimpleChildren $childObjs "Command")
			if ($commands.Count -gt 0) {
				Out "Команды: $($commands -join ', ')"
			}
		}
	}
}

# --- Pagination and output ---
$totalLines = $script:lines.Count
$outLines = $script:lines

if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$outLines = $outLines[$Offset..($totalLines - 1)]
}

if ($Limit -gt 0 -and $outLines.Count -gt $Limit) {
	$shown = $outLines[0..($Limit - 1)]
	$remaining = $totalLines - $Offset - $Limit
	$shown += ""
	$shown += "[TRUNCATED] Shown $Limit of $totalLines lines. Use -Offset $($Offset + $Limit) to continue."
	$outLines = $shown
}

if ($OutFile) {
	if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
		$OutFile = Join-Path (Get-Location).Path $OutFile
	}
	$utf8 = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllLines($OutFile, $outLines, $utf8)
	Write-Host "Output written to $OutFile"
} else {
	foreach ($l in $outLines) { Write-Host $l }
}
