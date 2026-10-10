# cfe-borrow v1.46 — Borrow objects from configuration into extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)][string]$ExtensionPath,
	[Parameter(Mandatory)][string]$ConfigPath,
	[Parameter(Mandatory)][string]$Object,
	[string]$BorrowMainAttribute,
	[string]$Module
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Info([string]$msg) { Write-Host "[INFO] $msg" }
function Warn([string]$msg) { Write-Host "[WARN] $msg" }

# Form data-binding tags (value = attribute path). A binding survives only if its root
# attribute is borrowed into the form's <Attributes>; otherwise it must be stripped or the
# platform rejects the form with "Неверный путь к данным" on load.
# RowPictureDataPath тоже путь к данным («Объект.Товары.РасхождениеЗаказ», «Список.DefaultPicture»),
# а не индекс картинки: эталон Конфигуратора сохраняет его с заимствованным основным реквизитом
# и выбрасывает без него — то же правило, что у остальных путей.
$script:formBindingDataTags = @('DataPath','TitleDataPath','FooterDataPath','HeaderDataPath','MultipleValueDataPath','MultipleValuePresentDataPath','RowPictureDataPath')
# Picture-path binding tags (value = picture index path, never a data attribute) — always stripped in the skeleton.
$script:formBindingPictureTags = @('MultipleValuePictureDataPath')

# Пути ссылок параметров выбора, которые пришлось вырезать (для предупреждения в конце)
$script:droppedLinks = @()

# id основного реквизита в заимствованной форме — как у Конфигуратора
$script:mainAttrId = "1000001"

# Виды дочерних объектов, которые заимствуются в оболочку поимённо (табличные части — отдельно)
$script:childObjectKinds = @('Attribute','Dimension','Resource','AddressingAttribute')

# Прямые дети <Form>, которые в заимствованную форму не переносятся.
# Структурные секции: AutoCommandBar и ChildItems забираются отдельно, остальные выбрасываются целиком.
$script:formStructuralSections = @('Events','Attributes','Commands','Parameters','CommandInterface')
# Свойства формы, значение которых — имя реквизита формы (реквизиты не заимствуются, ссылка повиснет).
$script:formAttributeRefProps = @('ReportResult','DetailsData','VariantAppearance','GroupList')

# Strip data-binding tags whose root attribute isn't borrowed.
# $mainAttrName задан (BorrowMainAttribute): оставить привязки от его имени, остальные снять.
# Пусто (скелет без основного реквизита): снять все. Картиночные пути снимаются всегда.
function Strip-FormBindings {
	param([string]$xml, [string]$mainAttrName)
	foreach ($tag in $script:formBindingDataTags) {
		if ($mainAttrName) {
			# Оставить и «Список.Поле», и путь ровно на сам реквизит («Список» у таблицы формы)
			$root = [regex]::Escape($mainAttrName)
			$xml = [regex]::Replace($xml, "\s*<$tag>(?!$root(\.|<))[^<]*</$tag>", '')
		} else {
			$xml = [regex]::Replace($xml, "\s*<$tag>[^<]*</$tag>", '')
		}
	}
	foreach ($tag in $script:formBindingPictureTags) {
		$xml = [regex]::Replace($xml, "\s*<$tag>[^<]*</$tag>", '')
	}
	return $xml
}

# Сдвиг блока на уровень вглубь для <BaseForm>; $firstIndent — отступ первой строки.
# Таб добавляется только в пробельные промежутки между тегами: строки продолжения многострочного
# текста (<v8:content>, текст запроса) — часть значения. Со сдвигом снимок расходился с формой,
# и Конфигуратор показывал такой текст изменённым в расширении. Пробельный промежуток между
# открывающим и закрывающим тегом одного элемента — тоже значение, его не сдвигаем.
function Get-BaseFormIndented {
	param([string]$xml, [string]$firstIndent)
	$parts = [regex]::Split($xml, '(<(?:[^>"'']|"[^"]*"|''[^'']*'')*>)')
	for ($i = 0; $i -lt $parts.Count; $i += 2) {
		$seg = $parts[$i]
		if (-not $seg.Contains("`n") -or $seg.Trim()) { continue }
		$prevTag = if ($i -gt 0) { $parts[$i - 1] } else { '' }
		$nextTag = if ($i + 1 -lt $parts.Count) { $parts[$i + 1] } else { '' }
		$m = [regex]::Match($prevTag, '^<([\w:.-]+)[^>]*(?<!/)>$')
		if ($m.Success -and $nextTag -ceq "</$($m.Groups[1].Value)>") { continue }
		$parts[$i] = $seg.Replace("`n", "`n`t")
	}
	return $firstIndent + ($parts -join '')
}

# Связи формы — параметров выбора (<ChoiceParameterLinks>/<xr:Link>) и по типу (<TypeLink>) —
# хранят путь в <xr:DataPath>, обычным стриппингом он не снимается. Путь — внутренняя ссылка
# платформы: в выгрузке она пишет имя, а если имя в контексте формы не разрешается — код.
# Текстовое имя в расширении разрешается, только если его корень объявлен в <Attributes> самой
# заимствованной формы; иначе платформа отвергает загрузку — «Неверный путь к полю - X».
# Конфигуратор поэтому пишет текст там, где он разрешается, и код — где нет.
# Грамматика кода (оракул «код в форму конфигурации → загрузка → выгрузка → имя», 8.3.27; эталоны
# Конфигуратора УТ и Issue66Example4-7, JR2433, JR2976, JR49904):
#   первый сегмент  <id>                — реквизит ИСХОДНОЙ формы (в расширении реквизиты
#                                         перенумерованы в 1000000+, ссылка остаётся в нумерации базы);
#                   <id>:<CurrentData>  — элемент-таблица исходной формы, её текущая строка;
#   дальше          0:<uuid>            — реквизит/ТЧ/измерение/ресурс метаданных источника;
#                   <id>                — колонка реквизита формы;
#                   <id>:<AddColumn>    — колонка AdditionalColumns;
#                   -<k>                — стандартный реквизит, код по виду объекта ($script:stdFieldCodes).
# В расширении платформа код обратно в имя не переводит, а висячий код грузит молча — ошибка
# кодирования не упадёт, а тихо не сработает. Поэтому кодируется только измеренное; прочее
# вырезается с предупреждением: связь — удобство подбора, без неё форма работает, с неверной
# текстовой — не грузится вовсе.
$script:linkCurrentData = '02023637-7868-4a5f-8576-835a76e0c9ba'
$script:linkAddColumn = '5bdad865-f2c5-434b-8041-ba4aad3b6687'
# Коды стандартных реквизитов — свой порядок у каждого вида (оракул 8.3.27; в XML объекта
# полного списка нет). Незамеренное (-1, скрытые поля, колонки ExtDimensionTypes) — не кодируем.
$script:stdFieldCodes = @{
	'Catalog' = @{ Code=-2; Description=-3; Parent=-4; Owner=-5; IsFolder=-6; DeletionMark=-7; Ref=-8; DataVersion=-9; Predefined=-10; PredefinedDataName=-13 }
	'Document' = @{ Number=-2; Date=-3; DeletionMark=-4; Ref=-5; DataVersion=-6; Posted=-7; RegisterRecords=-8 }
	'ChartOfCharacteristicTypes' = @{ Ref=-2; DataVersion=-3; DeletionMark=-4; Predefined=-5; Parent=-6; IsFolder=-7; Code=-8; Description=-9; ValueType=-11; PredefinedDataName=-14 }
	'ChartOfAccounts' = @{ Ref=-2; DataVersion=-3; DeletionMark=-4; Predefined=-5; Parent=-6; Code=-7; Description=-8; Type=-10; OffBalance=-11; ExtDimensionTypes=-12; Order=-17; PredefinedDataName=-28 }
	'ChartOfCalculationTypes' = @{ Code=-2; Description=-3; ActionPeriodIsBasic=-4; DeletionMark=-5; Ref=-6; DataVersion=-7; Predefined=-8; PredefinedDataName=-11; DisplacingCalculationTypes=-20; LeadingCalculationTypes=-30 }
	'ExchangePlan' = @{ Code=-2; Description=-3; DeletionMark=-4; Ref=-6; DataVersion=-7; SentNo=-9; ReceivedNo=-10; ThisNode=-13; ExchangeDate=-14 }
	'BusinessProcess' = @{ Number=-2; Date=-3; DeletionMark=-4; Ref=-5; DataVersion=-6; Completed=-7; HeadTask=-8; Started=-9 }
	'Task' = @{ Number=-2; Date=-3; DeletionMark=-4; Ref=-5; DataVersion=-6; BusinessProcess=-7; RoutePoint=-8; Description=-9; Executed=-10 }
	'InformationRegisterRecord' = @{ Period=-2; Recorder=-3; LineNumber=-4; Active=-5 }
	'AccumulationRegisterRow' = @{ Period=-2; Recorder=-3; LineNumber=-4; Active=-5; RecordType=-9; SecondPeriod=-10; MinutePeriod=-11; HourPeriod=-12; DayPeriod=-13; WeekPeriod=-14; TenDaysPeriod=-15 }
	'TabularSectionRow' = @{ LineNumber=-2 }
}
# Тип основного реквизита → вид для таблицы стандартных кодов (запись РС — сам реквизит,
# набор записей РН — строка таблицы на нём)
$script:mainAttrKinds = @{
	'CatalogObject'='Catalog'; 'DocumentObject'='Document'; 'ChartOfCharacteristicTypesObject'='ChartOfCharacteristicTypes'
	'ChartOfAccountsObject'='ChartOfAccounts'; 'ChartOfCalculationTypesObject'='ChartOfCalculationTypes'
	'ExchangePlanObject'='ExchangePlan'; 'BusinessProcessObject'='BusinessProcess'; 'TaskObject'='Task'
	'InformationRegisterRecordManager'='InformationRegisterRecord'; 'AccumulationRegisterRecordSet'='AccumulationRegisterRow'
	'ConstantsSet'='ConstantsSet'
}

# Путь связи → текст (разрешается в расширении), код или $null (вырезать).
# $ctx: MainName, MainId, MainBorrowed, MainKind, BorrowedNames (реквизиты объекта в расширении;
# $null — все), AttrUuids (имя/«ТЧ.Реквизит» → uuid),
# FormAttrIds, FormAttrCols («Реквизит.Колонка» → id), AddCols («<путь таблицы>.Колонка» → id),
# Tables (имя элемента-таблицы → @{ Id; Path }).
function Resolve-LinkDataPath {
	param([string]$path, $ctx)

	# Уже код (форма-источник сама из расширения, или висячая ссылка в типовой) — как есть
	if ($path -match '^-?\d') { return $path }
	$main = $ctx.MainName

	# Текущая строка элемента-таблицы
	$cd = [regex]::Match($path, '^Items\.([^.]+)\.CurrentData\.([^.]+)$')
	if ($cd.Success) {
		$tbl = $ctx.Tables[$cd.Groups[1].Value]
		$field = $cd.Groups[2].Value
		if (-not $tbl) { return $null }
		$tp = $tbl.Path
		$prefix = "$($tbl.Id):$($script:linkCurrentData)"
		if ($main -and ($tp -ceq $main -or $tp.StartsWith("$main.", [StringComparison]::Ordinal))) {
			# Таблица на основном реквизите: с заимствованным — текст разрешается (эталоны 7_1, УТ)
			if ($ctx.MainBorrowed) { return $path }
			if ($tp -ceq $main) {
				# Строки самого основного реквизита — набор записей регистра накопления
				if ($ctx.MainKind -ne 'AccumulationRegisterRow') { return $null }
				if ($ctx.AttrUuids.ContainsKey($field)) { return "$prefix/0:$($ctx.AttrUuids[$field])" }
				$code = $script:stdFieldCodes['AccumulationRegisterRow'][$field]
				if ($code) { return "$prefix/$code" }
				return $null
			}
			$ts = $tp.Substring($main.Length + 1)
			if ($ts.Contains('.')) { return $null }
			if ($ctx.AttrUuids.ContainsKey("$ts.$field")) { return "$prefix/0:$($ctx.AttrUuids["$ts.$field"])" }
			if ($ctx.AddCols.ContainsKey("$tp.$field")) { return "$prefix/$($ctx.AddCols["$tp.$field"]):$($script:linkAddColumn)" }
			$code = $script:stdFieldCodes['TabularSectionRow'][$field]
			if ($code) { return "$prefix/$code" }
			return $null
		}
		# Таблица на реквизите формы: реквизиты формы не заимствуются никогда — только код
		# (текст платформа отвергает и с заимствованным основным реквизитом, оракул 8.3.27)
		if ($ctx.FormAttrIds.ContainsKey($tp) -and $ctx.FormAttrCols.ContainsKey("$tp.$field")) {
			return "$prefix/$($ctx.FormAttrCols["$tp.$field"])"
		}
		return $null
	}

	# Путь от основного реквизита формы
	if ($main -and $path.StartsWith("$main.", [StringComparison]::Ordinal)) {
		$rest = $path.Substring($main.Length + 1)
		if ($ctx.MainBorrowed) {
			# Заимствованный реквизит объекта разрешается текстом и остаётся читаемым. Стандартное
			# поле («Объект.Owner», «Объект.Date») и реквизит, который в расширение не попал (в режиме
			# Form заимствуется только используемое формой) — нет: платформа отвергает «Неверный путь
			# к полю». Конфигуратор в обоих случаях ставит ссылку на сам основной реквизит (эталоны
			# Issue66Example7_1 и УТ Претензии.ФормаЭлементаСамообслуживание).
			$borrowed = $null -eq $ctx.BorrowedNames -or $ctx.BorrowedNames.ContainsKey($rest.Split('.')[0])
			if ($borrowed -and $ctx.AttrUuids.ContainsKey($rest)) { return $path }
			return $ctx.MainId
		}
		# Код пути на константу набора не измерен — такую связь вырезаем, а не кодируем наугад
		if ($ctx.MainKind -eq 'ConstantsSet') { return $null }
		$segs = $rest.Split('.')
		if ($segs.Count -eq 1) {
			if ($ctx.AttrUuids.ContainsKey($rest)) { return "$($ctx.MainId)/0:$($ctx.AttrUuids[$rest])" }
			$codes = if ($ctx.MainKind) { $script:stdFieldCodes[$ctx.MainKind] } else { $null }
			if ($codes -and $codes.ContainsKey($rest)) { return "$($ctx.MainId)/$($codes[$rest])" }
			return $null
		}
		if ($segs.Count -eq 2 -and $ctx.AttrUuids.ContainsKey($segs[0]) -and $ctx.AttrUuids.ContainsKey($rest)) {
			return "$($ctx.MainId)/0:$($ctx.AttrUuids[$segs[0]])/0:$($ctx.AttrUuids[$rest])"
		}
		return $null
	}

	# Путь от реквизита формы — только по id исходной формы, в обоих режимах
	$segs = $path.Split('.')
	if ($ctx.FormAttrIds.ContainsKey($segs[0])) {
		$attrId = $ctx.FormAttrIds[$segs[0]]
		if ($segs.Count -eq 1) { return $attrId }
		if ($segs.Count -eq 2 -and $ctx.FormAttrCols.ContainsKey($path)) { return "$attrId/$($ctx.FormAttrCols[$path])" }
		return $null
	}

	# Прочее: с заимствованным основным реквизитом текст может разрешиться, без него — нет
	if ($ctx.MainBorrowed) { return $path }
	return $null
}

# Путь в <xr:DataPath> блока связи → разрешённый; неразрешимый блок вырезается целиком
function Rewrite-LinkBlocks {
	param([string]$xml, [string]$blockPattern, $ctx)

	return [regex]::Replace($xml, $blockPattern, {
		param($m)
		$link = $m.Value
		$dp = [regex]::Match($link, '<xr:DataPath[^>]*>([^<]+)</xr:DataPath>')
		if (-not $dp.Success) { return $link }
		$path = $dp.Groups[1].Value
		$resolved = Resolve-LinkDataPath $path $ctx
		if ($null -eq $resolved) {
			$script:droppedLinks += $path
			return ''
		}
		if ($resolved -ceq $path) { return $link }
		return $link.Substring(0, $dp.Groups[1].Index) + $resolved + $link.Substring($dp.Groups[1].Index + $dp.Groups[1].Length)
	})
}

function Rewrite-ChoiceParameterLinks {
	param([string]$xml, $ctx)

	if ($xml -notmatch '<ChoiceParameterLinks>') { return $xml }
	$xml = Rewrite-LinkBlocks $xml '(?s)\s*<xr:Link>.*?</xr:Link>' $ctx
	# Опустевший контейнер платформе не нужен
	$xml = [regex]::Replace($xml, '(?s)\s*<ChoiceParameterLinks>\s*</ChoiceParameterLinks>', '')
	return $xml
}

# Связь по типу — тот же путь и то же правило (эталоны УТ ВводОстатков.ФормаРасчетыМеждуОрганизациями:
# без основного реквизита — код, с ним — текст)
function Rewrite-TypeLinks {
	param([string]$xml, $ctx)

	if ($xml -notmatch '<TypeLink>') { return $xml }
	return Rewrite-LinkBlocks $xml '(?s)\s*<TypeLink>.*?</TypeLink>' $ctx
}

# Имена ПРЯМЫХ детей собственного <ChildObjects> объекта — для дедупа при повторном
# заимствовании. Текстом это не снять: regex «первый <ChildObjects> до первого </ChildObjects>»
# у объекта с табличными частями обрывается на закрытии первой ТЧ, забирает имена её колонок и
# теряет то, что идёт после неё.
function Get-OwnChildObjectNames {
	param([string]$objFile)

	$names = @{}
	if (-not (Test-Path -LiteralPath $objFile)) { return $names }
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $false
	try { $doc.Load($objFile) } catch { return $names }
	$objEl = $null
	foreach ($c in $doc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $objEl = $c; break }
	}
	if (-not $objEl) { return $names }
	$childObjs = $objEl.SelectSingleNode("*[local-name()='ChildObjects']")
	if (-not $childObjs) { return $names }
	foreach ($child in $childObjs.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$nameNode = $child.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
		if ($nameNode) { $names[$nameNode.InnerText.Trim()] = $true }
	}
	return $names
}

# Вставка в СОБСТВЕННЫЙ <ChildObjects> объекта. Свой контейнер закрывается в файле последним:
# объект в файле один, а вложенные <ChildObjects> табличных частей закрываются раньше. Замена по
# всем вхождениям раскидывала реквизиты по каждой ТЧ — ps1 рвал XML, py прятал ТЧ внутрь ТЧ.
function Insert-IntoOwnChildObjects {
	param([string]$text, [string]$content)

	$closeIdx = $text.LastIndexOf('</ChildObjects>')
	if ($closeIdx -ge 0) {
		return $text.Substring(0, $closeIdx) + "${content}`r`n`t`t" + $text.Substring($closeIdx)
	}
	# Своего закрывающего тега нет — значит контейнер самозакрытый (детей у него нет, вложенных тоже)
	$selfMatches = [regex]::Matches($text, '<ChildObjects\s*/>')
	if ($selfMatches.Count -eq 0) { return $text }
	$m = $selfMatches[$selfMatches.Count - 1]
	return $text.Substring(0, $m.Index) + "<ChildObjects>${content}`r`n`t`t</ChildObjects>" + $text.Substring($m.Index + $m.Length)
}

# --- 1. Resolve paths ---
if (-not [System.IO.Path]::IsPathRooted($ExtensionPath)) {
	$ExtensionPath = Join-Path (Get-Location).Path $ExtensionPath
}
if (Test-Path $ExtensionPath -PathType Container) {
	$candidate = Join-Path $ExtensionPath "Configuration.xml"
	if (Test-Path $candidate) { $ExtensionPath = $candidate }
	else { Write-Error "No Configuration.xml in extension directory: $ExtensionPath"; exit 1 }
}
if (-not (Test-Path $ExtensionPath)) { Write-Error "Extension file not found: $ExtensionPath"; exit 1 }
$extResolvedPath = (Resolve-Path $ExtensionPath).Path
$extDir = Split-Path $extResolvedPath -Parent

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
	$ConfigPath = Join-Path (Get-Location).Path $ConfigPath
}
if (Test-Path $ConfigPath -PathType Container) {
	$candidate = Join-Path $ConfigPath "Configuration.xml"
	if (Test-Path $candidate) { $ConfigPath = $candidate }
	else { Write-Error "No Configuration.xml in config directory: $ConfigPath"; exit 1 }
}
if (-not (Test-Path $ConfigPath)) { Write-Error "Config file not found: $ConfigPath"; exit 1 }
$cfgResolvedPath = (Resolve-Path $ConfigPath).Path
$cfgDir = Split-Path $cfgResolvedPath -Parent

# --- 2. Load extension Configuration.xml ---
$script:xmlDoc = New-Object System.Xml.XmlDocument
$script:xmlDoc.PreserveWhitespace = $true
$script:xmlDoc.Load($extResolvedPath)

$script:mdNs = "http://v8.1c.ru/8.3/MDClasses"
$script:xrNs = "http://v8.1c.ru/8.3/xcf/readable"
$script:xsiNs = "http://www.w3.org/2001/XMLSchema-instance"
$script:v8Ns = "http://v8.1c.ru/8.1/data/core"

$root = $script:xmlDoc.DocumentElement

$script:cfgEl = $null
foreach ($child in $root.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Configuration") {
		$script:cfgEl = $child; break
	}
}
if (-not $script:cfgEl) { Write-Error "No <Configuration> element found in extension"; exit 1 }

$script:propsEl = $null
$script:childObjsEl = $null
foreach ($child in $script:cfgEl.ChildNodes) {
	if ($child.NodeType -ne 'Element') { continue }
	if ($child.LocalName -eq "Properties") { $script:propsEl = $child }
	if ($child.LocalName -eq "ChildObjects") { $script:childObjsEl = $child }
}

if (-not $script:propsEl) { Write-Error "No <Properties> element found in extension"; exit 1 }
if (-not $script:childObjsEl) { Write-Error "No <ChildObjects> element found in extension"; exit 1 }

# --- 3. Extract NamePrefix ---
$script:namePrefix = ""
foreach ($child in $script:propsEl.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "NamePrefix") {
		$script:namePrefix = $child.InnerText.Trim(); break
	}
}
Info "Extension NamePrefix: $($script:namePrefix)"

# --- 4. Type mappings ---
$childTypeDirMap = @{
	"Catalog"="Catalogs"; "Document"="Documents"; "Enum"="Enums"
	"CommonModule"="CommonModules"; "CommonPicture"="CommonPictures"
	"CommonCommand"="CommonCommands"; "CommonTemplate"="CommonTemplates"
	"ExchangePlan"="ExchangePlans"; "Report"="Reports"; "DataProcessor"="DataProcessors"
	"InformationRegister"="InformationRegisters"; "AccumulationRegister"="AccumulationRegisters"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfAccounts"="ChartsOfAccounts"; "AccountingRegister"="AccountingRegisters"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"; "CalculationRegister"="CalculationRegisters"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"
	"Subsystem"="Subsystems"; "Role"="Roles"; "Constant"="Constants"
	"FunctionalOption"="FunctionalOptions"; "DefinedType"="DefinedTypes"
	"FunctionalOptionsParameter"="FunctionalOptionsParameters"
	"CommonForm"="CommonForms"; "DocumentJournal"="DocumentJournals"
	"SessionParameter"="SessionParameters"; "StyleItem"="StyleItems"
	"EventSubscription"="EventSubscriptions"; "ScheduledJob"="ScheduledJobs"
	"SettingsStorage"="SettingsStorages"; "FilterCriterion"="FilterCriteria"
	"CommandGroup"="CommandGroups"; "DocumentNumerator"="DocumentNumerators"
	"Sequence"="Sequences"; "ExternalDataSource"="ExternalDataSources"; "IntegrationService"="IntegrationServices"
	"XDTOPackage"="XDTOPackages"; "WebService"="WebServices"
	"HTTPService"="HTTPServices"; "WSReference"="WSReferences"
	"CommonAttribute"="CommonAttributes"; "Style"="Styles"; "Bot"="Bots"; "PaletteColor"="PaletteColors"; "Language"="Languages"
}

# --- 4a. Модули заимствованных объектов ---
# Порядок внутри значения — порядок выгрузки Конфигуратора: сначала «объектный» модуль
# (ObjectModule / RecordSetModule / ValueManagerModule), затем ManagerModule.
$script:moduleKindsByType = @{
	"CommonModule"=@("Module"); "HTTPService"=@("Module"); "WebService"=@("Module")
	"Catalog"=@("ObjectModule","ManagerModule"); "Document"=@("ObjectModule","ManagerModule")
	"Report"=@("ObjectModule","ManagerModule"); "DataProcessor"=@("ObjectModule","ManagerModule")
	"ExchangePlan"=@("ObjectModule","ManagerModule")
	"ChartOfCharacteristicTypes"=@("ObjectModule","ManagerModule")
	"ChartOfAccounts"=@("ObjectModule","ManagerModule")
	"ChartOfCalculationTypes"=@("ObjectModule","ManagerModule")
	"BusinessProcess"=@("ObjectModule","ManagerModule"); "Task"=@("ObjectModule","ManagerModule")
	"InformationRegister"=@("RecordSetModule","ManagerModule")
	"AccumulationRegister"=@("RecordSetModule","ManagerModule")
	"AccountingRegister"=@("RecordSetModule","ManagerModule")
	"CalculationRegister"=@("RecordSetModule","ManagerModule")
	"Sequence"=@("RecordSetModule","ManagerModule")
	"Constant"=@("ValueManagerModule","ManagerModule")
	"Enum"=@("ManagerModule"); "DocumentJournal"=@("ManagerModule")
	"FilterCriterion"=@("ManagerModule")
}
# Типы с ЕДИНСТВЕННЫМ модулем: ради него объект и заимствуют, поэтому файл создаётся молча.
# Отказ — `-Module None`.
$script:autoModuleTypes = @("CommonModule", "HTTPService", "WebService")
$script:moduleKindNames = @("Module", "ObjectModule", "ManagerModule", "RecordSetModule", "ValueManagerModule")

# --- 4b. Russian synonym → English type ---
$synonymMap = @{
	"Справочник"="Catalog"; "Документ"="Document"; "Перечисление"="Enum"
	"ОбщийМодуль"="CommonModule"; "ОбщаяКартинка"="CommonPicture"
	"ОбщаяКоманда"="CommonCommand"; "ОбщийМакет"="CommonTemplate"
	"ПланОбмена"="ExchangePlan"; "Отчет"="Report"; "Отчёт"="Report"
	"Обработка"="DataProcessor"; "РегистрСведений"="InformationRegister"
	"РегистрНакопления"="AccumulationRegister"
	"ПланВидовХарактеристик"="ChartOfCharacteristicTypes"
	"ПланСчетов"="ChartOfAccounts"; "РегистрБухгалтерии"="AccountingRegister"
	"ПланВидовРасчета"="ChartOfCalculationTypes"; "РегистрРасчета"="CalculationRegister"
	"БизнесПроцесс"="BusinessProcess"; "Задача"="Task"
	"Подсистема"="Subsystem"; "Роль"="Role"; "Константа"="Constant"
	"ФункциональнаяОпция"="FunctionalOption"; "ОпределяемыйТип"="DefinedType"
	"ОбщаяФорма"="CommonForm"; "ЖурналДокументов"="DocumentJournal"
	"ПараметрСеанса"="SessionParameter"; "ГруппаКоманд"="CommandGroup"
	"ПодпискаНаСобытие"="EventSubscription"; "РегламентноеЗадание"="ScheduledJob"
	"ОбщийРеквизит"="CommonAttribute"; "ПакетXDTO"="XDTOPackage"
	"HTTPСервис"="HTTPService"; "СервисИнтеграции"="IntegrationService"
}

# --- 5. Canonical type order (46 types) ---
$script:typeOrder = @(
	"Language","Subsystem","StyleItem","Style",
	"CommonPicture","SessionParameter","Role","CommonTemplate",
	"FilterCriterion","CommonModule","CommonAttribute","ExchangePlan",
	"XDTOPackage","WebService","HTTPService","WSReference",
	"EventSubscription","ScheduledJob","SettingsStorage","FunctionalOption",
	"FunctionalOptionsParameter","DefinedType","Bot","PaletteColor","CommonCommand","CommandGroup",
	"Constant","CommonForm","Catalog","Document",
	"DocumentNumerator","Sequence","DocumentJournal","Enum",
	"Report","DataProcessor","InformationRegister","AccumulationRegister",
	"ChartOfCharacteristicTypes","ChartOfAccounts","AccountingRegister",
	"ChartOfCalculationTypes","CalculationRegister",
	"BusinessProcess","Task","ExternalDataSource","IntegrationService"
)

# --- 6. GeneratedType patterns per type ---
$script:generatedTypes = @{
	"Catalog" = @(
		@{ prefix = "CatalogObject";    category = "Object" }
		@{ prefix = "CatalogRef";       category = "Ref" }
		@{ prefix = "CatalogSelection"; category = "Selection" }
		@{ prefix = "CatalogList";      category = "List" }
		@{ prefix = "CatalogManager";   category = "Manager" }
	)
	"Document" = @(
		@{ prefix = "DocumentObject";    category = "Object" }
		@{ prefix = "DocumentRef";       category = "Ref" }
		@{ prefix = "DocumentSelection"; category = "Selection" }
		@{ prefix = "DocumentList";      category = "List" }
		@{ prefix = "DocumentManager";   category = "Manager" }
	)
	"Enum" = @(
		@{ prefix = "EnumRef";     category = "Ref" }
		@{ prefix = "EnumManager"; category = "Manager" }
		@{ prefix = "EnumList";    category = "List" }
	)
	"Constant" = @(
		@{ prefix = "ConstantManager";      category = "Manager" }
		@{ prefix = "ConstantValueManager"; category = "ValueManager" }
		@{ prefix = "ConstantValueKey";     category = "ValueKey" }
	)
	"InformationRegister" = @(
		@{ prefix = "InformationRegisterRecord";        category = "Record" }
		@{ prefix = "InformationRegisterManager";       category = "Manager" }
		@{ prefix = "InformationRegisterSelection";     category = "Selection" }
		@{ prefix = "InformationRegisterList";          category = "List" }
		@{ prefix = "InformationRegisterRecordSet";     category = "RecordSet" }
		@{ prefix = "InformationRegisterRecordKey";     category = "RecordKey" }
		@{ prefix = "InformationRegisterRecordManager"; category = "RecordManager" }
	)
	"AccumulationRegister" = @(
		@{ prefix = "AccumulationRegisterRecord";    category = "Record" }
		@{ prefix = "AccumulationRegisterManager";   category = "Manager" }
		@{ prefix = "AccumulationRegisterSelection"; category = "Selection" }
		@{ prefix = "AccumulationRegisterList";      category = "List" }
		@{ prefix = "AccumulationRegisterRecordSet"; category = "RecordSet" }
		@{ prefix = "AccumulationRegisterRecordKey"; category = "RecordKey" }
	)
	"AccountingRegister" = @(
		@{ prefix = "AccountingRegisterRecord";        category = "Record" }
		@{ prefix = "AccountingRegisterExtDimensions"; category = "ExtDimensions" }
		@{ prefix = "AccountingRegisterManager";   category = "Manager" }
		@{ prefix = "AccountingRegisterSelection"; category = "Selection" }
		@{ prefix = "AccountingRegisterList";      category = "List" }
		@{ prefix = "AccountingRegisterRecordSet"; category = "RecordSet" }
		@{ prefix = "AccountingRegisterRecordKey"; category = "RecordKey" }
	)
	"CalculationRegister" = @(
		@{ prefix = "CalculationRegisterRecord";    category = "Record" }
		@{ prefix = "CalculationRegisterManager";   category = "Manager" }
		@{ prefix = "CalculationRegisterSelection"; category = "Selection" }
		@{ prefix = "CalculationRegisterList";      category = "List" }
		@{ prefix = "CalculationRegisterRecordSet"; category = "RecordSet" }
		@{ prefix = "CalculationRegisterRecordKey"; category = "RecordKey" }
		@{ prefix = "RecalculationsManager";        category = "Recalcs" }
	)
	"ChartOfAccounts" = @(
		@{ prefix = "ChartOfAccountsObject";    category = "Object" }
		@{ prefix = "ChartOfAccountsRef";       category = "Ref" }
		@{ prefix = "ChartOfAccountsSelection"; category = "Selection" }
		@{ prefix = "ChartOfAccountsList";      category = "List" }
		@{ prefix = "ChartOfAccountsManager";   category = "Manager" }
		@{ prefix = "ChartOfAccountsExtDimensionTypes";    category = "ExtDimensionTypes" }
		@{ prefix = "ChartOfAccountsExtDimensionTypesRow"; category = "ExtDimensionTypesRow" }
	)
	"ChartOfCharacteristicTypes" = @(
		@{ prefix = "ChartOfCharacteristicTypesObject";    category = "Object" }
		@{ prefix = "ChartOfCharacteristicTypesRef";       category = "Ref" }
		@{ prefix = "ChartOfCharacteristicTypesSelection"; category = "Selection" }
		@{ prefix = "ChartOfCharacteristicTypesList";      category = "List" }
		@{ prefix = "Characteristic";                      category = "Characteristic" }
		@{ prefix = "ChartOfCharacteristicTypesManager";   category = "Manager" }
	)
	"ChartOfCalculationTypes" = @(
		@{ prefix = "ChartOfCalculationTypesObject";    category = "Object" }
		@{ prefix = "ChartOfCalculationTypesRef";       category = "Ref" }
		@{ prefix = "ChartOfCalculationTypesSelection"; category = "Selection" }
		@{ prefix = "ChartOfCalculationTypesList";      category = "List" }
		@{ prefix = "ChartOfCalculationTypesManager";   category = "Manager" }
		@{ prefix = "DisplacingCalculationTypes";       category = "DisplacingCalculationTypes" }
		@{ prefix = "DisplacingCalculationTypesRow";    category = "DisplacingCalculationTypesRow" }
		@{ prefix = "BaseCalculationTypes";             category = "BaseCalculationTypes" }
		@{ prefix = "BaseCalculationTypesRow";          category = "BaseCalculationTypesRow" }
		@{ prefix = "LeadingCalculationTypes";          category = "LeadingCalculationTypes" }
		@{ prefix = "LeadingCalculationTypesRow";       category = "LeadingCalculationTypesRow" }
	)
	"BusinessProcess" = @(
		@{ prefix = "BusinessProcessObject";    category = "Object" }
		@{ prefix = "BusinessProcessRef";       category = "Ref" }
		@{ prefix = "BusinessProcessSelection"; category = "Selection" }
		@{ prefix = "BusinessProcessList";      category = "List" }
		@{ prefix = "BusinessProcessManager";   category = "Manager" }
		@{ prefix = "BusinessProcessRoutePointRef"; category = "RoutePointRef" }
	)
	"Task" = @(
		@{ prefix = "TaskObject";    category = "Object" }
		@{ prefix = "TaskRef";       category = "Ref" }
		@{ prefix = "TaskSelection"; category = "Selection" }
		@{ prefix = "TaskList";      category = "List" }
		@{ prefix = "TaskManager";   category = "Manager" }
	)
	"ExchangePlan" = @(
		@{ prefix = "ExchangePlanObject";    category = "Object" }
		@{ prefix = "ExchangePlanRef";       category = "Ref" }
		@{ prefix = "ExchangePlanSelection"; category = "Selection" }
		@{ prefix = "ExchangePlanList";      category = "List" }
		@{ prefix = "ExchangePlanManager";   category = "Manager" }
	)
	"DocumentJournal" = @(
		@{ prefix = "DocumentJournalSelection"; category = "Selection" }
		@{ prefix = "DocumentJournalList";      category = "List" }
		@{ prefix = "DocumentJournalManager";   category = "Manager" }
	)
	"Report" = @(
		@{ prefix = "ReportObject";  category = "Object" }
		@{ prefix = "ReportManager"; category = "Manager" }
	)
	"DataProcessor" = @(
		@{ prefix = "DataProcessorObject";  category = "Object" }
		@{ prefix = "DataProcessorManager"; category = "Manager" }
	)
	"DefinedType" = @(
		@{ prefix = "DefinedType"; category = "DefinedType" }
	)
	"ExternalDataSource" = @(
		@{ prefix = "ExternalDataSourceManager";       category = "Manager" }
		@{ prefix = "ExternalDataSourceTablesManager"; category = "TablesManager" }
		@{ prefix = "ExternalDataSourceCubesManager";  category = "CubesManager" }
	)
	"Sequence" = @(
		@{ prefix = "SequenceRecord";    category = "Record" }
		@{ prefix = "SequenceManager";   category = "Manager" }
		@{ prefix = "SequenceRecordSet"; category = "RecordSet" }
	)
	"FilterCriterion" = @(
		@{ prefix = "FilterCriterionManager"; category = "Manager" }
		@{ prefix = "FilterCriterionList";    category = "List" }
	)
	"SettingsStorage" = @(
		@{ prefix = "SettingsStorageManager"; category = "Manager" }
	)
	"IntegrationService" = @(
		@{ prefix = "IntegrationServiceManager"; category = "Manager" }
	)
	"WSReference" = @(
		@{ prefix = "WSReferenceManager"; category = "Manager" }
	)
}

# Types that need ChildObjects element — fallback when the source object cannot be probed.
# The platform emits <ChildObjects> for every container type even when empty, and rejects
# the file without it ("ожидаемое ChildObjects"); primary signal is the source object itself.
$typesWithChildObjects = @(
	"Catalog","Document","ExchangePlan","ChartOfAccounts",
	"ChartOfCharacteristicTypes","ChartOfCalculationTypes",
	"BusinessProcess","Task","Enum",
	"InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister",
	"DataProcessor","Report","DocumentJournal","FilterCriterion","SettingsStorage",
	"Sequence","HTTPService","WebService","IntegrationService","Subsystem"
)

# CommonModule properties to copy from source
$commonModuleProps = @("Global","ClientManagedApplication","Server","ExternalConnection","ClientOrdinaryApplication","ServerCall")

# Свойства объекта, от которых зависит существование стандартного поля: без них платформа
# отвергает загрузку — «Неверный путь к данным». Конфигуратор переносит ровно их (эталоны
# Issue66Example7_1 и Issue66Example2). Проверено сплошным прогоном по типам: у регистра сведений
# без InformationRegisterPeriodicity не разрешается «Запись.Period».
# Тем же путём переносится код языка: платформа принимает заимствованный язык и без него, но
# конфигуратор пишет LanguageCode у любого заимствованного языка, основного и неосновного (замер 8.3.24).
$script:typeGateProps = @{
	"InformationRegister" = @("InformationRegisterPeriodicity","WriteMode")
	"Language" = @("LanguageCode")
}
# Владельцы справочника — список <xr:Item>, а не скаляр: переносится фрагментом, как __TypeXml
$script:typesWithOwners = @("Catalog","ChartOfCharacteristicTypes")

# Standard system fields to skip when collecting DataPath references
$script:standardFields = @("Code","Description","Ref","Parent","DeletionMark","Predefined","IsFolder","LineNumber","RowsCount","PredefinedDataName")

# --- 7. XML manipulation helpers (from cf-edit) ---
function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			if ($child.Value -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($child.Value -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	$depth = 0; $current = $container
	while ($current -and $current -ne $script:xmlDoc.DocumentElement) { $depth++; $current = $current.ParentNode }
	return "`t" * ($depth + 1)
}

function Insert-BeforeElement($container, $newNode, $refNode, $childIndent) {
	$ws = $script:xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $ws) | Out-Null
	} else {
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$container.InsertBefore($ws, $trailing) | Out-Null
			$container.InsertBefore($newNode, $trailing) | Out-Null
		} else {
			$container.AppendChild($ws) | Out-Null
			$container.AppendChild($newNode) | Out-Null
			$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
			$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
			$container.AppendChild($closeWs) | Out-Null
		}
	}
}

function Expand-SelfClosingElement($container, $parentIndent) {
	if (-not $container.HasChildNodes -or $container.IsEmpty) {
		$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
}

# --- 7b. Detect format version ---

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		# Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
		# корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
		$extPath = "$d.xml"
		if (Test-Path $extPath) {
			$extText = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
			$extHead = $extText.Substring(0, [Math]::Min(2000, $extText.Length))
			if ($extHead -match '<(ExternalDataProcessor|ExternalReport)[ >]' -and $extHead -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
			# Длину среза берём по СТРОКЕ, а не по размеру файла: размер в БАЙТАХ, Substring считает
			# СИМВОЛЫ, и на кириллице байт больше — короткий Configuration.xml ронял навык исключением.
			$head = $cfgText.Substring(0, [Math]::Min(2000, $cfgText.Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

$script:formatVersion = Detect-FormatVersion $extDir

# --- 8. Namespaces declaration for object XML ---
$script:xmlnsDecl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

# Версия формата как число для сравнений: "2.20" → 220, "2.9" → 209.
# Строковое сравнение здесь неверно ("2.9" > "2.17" лексикографически) — известная ловушка.
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

# 2.21 (8.5) добавила в шапку пространство палитры — ради <Color> у значений перечисления.
# Вставляем НА МЕСТО (после lf, перед style): платформа держит объявления по алфавиту,
# дописать в конец нельзя.
if ((Get-FormatRank $script:formatVersion) -ge 221) {
	$script:xmlnsDecl = $script:xmlnsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}

# --- 9. Parse -Object into items ---
$items = @()
foreach ($part in $Object.Split(";;")) {
	$trimmed = $part.Trim()
	if ($trimmed) { $items += $trimmed }
}

if ($items.Count -eq 0) {
	Write-Error "No objects specified in -Object"
	exit 1
}

# --- 9b. Validate -BorrowMainAttribute ---
if ($BorrowMainAttribute) {
	if ($BorrowMainAttribute -notin @("Form","All")) {
		Write-Error "-BorrowMainAttribute accepts 'Form' or 'All' (default: Form)"
		exit 1
	}
	# Validate: only with a form — .Form. pattern or a common form
	$hasForm = $false
	foreach ($item in $items) { if ($item -match '\.Form\.' -or $item -match '^(CommonForm|ОбщаяФорма)\.') { $hasForm = $true; break } }
	if (-not $hasForm) {
		Write-Error "-BorrowMainAttribute requires a form in -Object (e.g. 'Catalog.X.Form.Y')"
		exit 1
	}
}

# --- 9c. Validate -Module ---
$script:requestedModules = @()
$script:noModule = $false
if ($Module) {
	foreach ($raw in ($Module -split '[,;]')) {
		$kind = $raw.Trim()
		if (-not $kind) { continue }
		# Сравнение РЕГИСТРОНЕЗАВИСИМОЕ явно (-ieq): в py-порте это отдельная ветка, и молчаливое
		# расхождение портов на «none» ловится только глазами.
		if ($kind -ieq "None") { $script:noModule = $true; continue }
		$canon = @($script:moduleKindNames | Where-Object { $_ -ieq $kind })
		if ($canon.Count -eq 0) {
			Write-Error "Неизвестный вид модуля '$kind'. Допустимо: $($script:moduleKindNames -join ', '), None"
			exit 1
		}
		$script:requestedModules += $canon[0]
	}
	if ($script:noModule -and $script:requestedModules.Count -gt 0) {
		Write-Error "-Module None нельзя сочетать с видами модулей"
		exit 1
	}
}

# Какие модули создать для объекта. Тип с единственным модулем получает его всегда — уточнять
# там нечего; -Module разбирает только неоднозначные типы. Иначе батч смешанных типов
# (`CommonModule.X ;; Catalog.Y`) не выражался бы одним вызовом.
function Resolve-ModuleKinds {
	param([string]$typeName)

	if ($script:noModule) { return @() }
	$allowed = @($script:moduleKindsByType[$typeName])
	if ($allowed.Count -eq 0) { return @() }

	if ($script:autoModuleTypes -contains $typeName) { return @($allowed[0]) }
	if ($script:requestedModules.Count -eq 0) { return @() }

	# Порядок берём из таблицы типа, а не из порядка ключей в -Module.
	$selected = @($allowed | Where-Object { $script:requestedModules -contains $_ })
	if ($selected.Count -eq 0) {
		Warn "  Тип $typeName не имеет запрошенных модулей — пропущено. Допустимо: $($allowed -join ', ')"
	}
	return $selected
}

# --- 10. Helper: read source object XML ---
# Имена реквизитов исходного объекта → uuid: реквизиты, ТЧ, измерения и ресурсы регистра, реквизиты
# ТЧ — ключом «ТЧ.Реквизит». Нужны для кода пути в связях формы (см. Resolve-LinkDataPath).
function Get-SourceAttributeUuids {
	param([string]$typeName, [string]$objName)

	$result = @{}
	$dirName = $childTypeDirMap[$typeName]
	if (-not $dirName) { return $result }
	$srcFile = Join-Path (Join-Path $cfgDir $dirName) "${objName}.xml"
	if (-not (Test-Path $srcFile)) { return $result }

	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $false
	$doc.Load($srcFile)
	$objEl = $null
	foreach ($c in $doc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $objEl = $c; break }
	}
	if (-not $objEl) { return $result }
	$childObjects = $objEl.SelectSingleNode("*[local-name()='ChildObjects']")
	if (-not $childObjects) { return $result }
	foreach ($child in $childObjects.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		if ($child.LocalName -notin @('Attribute','TabularSection','Dimension','Resource')) { continue }
		$uuid = $child.GetAttribute("uuid")
		$nameNode = $child.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
		if (-not ($uuid -and $nameNode)) { continue }
		$name = $nameNode.InnerText.Trim()
		$result[$name] = $uuid
		if ($child.LocalName -ne 'TabularSection') { continue }
		foreach ($tsAttr in @($child.SelectNodes("*[local-name()='ChildObjects']/*[local-name()='Attribute']"))) {
			$tsUuid = $tsAttr.GetAttribute("uuid")
			$tsName = $tsAttr.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
			if ($tsUuid -and $tsName) { $result["$name.$($tsName.InnerText.Trim())"] = $tsUuid }
		}
	}
	return $result
}

function Read-SourceObject {
	param([string]$typeName, [string]$objName)

	$dirName = $childTypeDirMap[$typeName]
	if (-not $dirName) {
		Write-Error "Unknown type '$typeName'"
		exit 1
	}

	$srcFile = Join-Path (Join-Path $cfgDir $dirName) "${objName}.xml"
	if (-not (Test-Path $srcFile)) {
		Write-Error "Source object not found: $srcFile"
		exit 1
	}

	$srcDoc = New-Object System.Xml.XmlDocument
	$srcDoc.PreserveWhitespace = $false
	$srcDoc.Load($srcFile)

	$srcNs = New-Object System.Xml.XmlNamespaceManager($srcDoc.NameTable)
	$srcNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
	$srcNs.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")

	# Find the type element (e.g. <Catalog uuid="...">)
	$srcRoot = $srcDoc.DocumentElement
	$srcEl = $null
	foreach ($c in $srcRoot.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $srcEl = $c; break }
	}
	if (-not $srcEl) {
		Write-Error "No metadata element found in ${dirName}/${objName}.xml"
		exit 1
	}

	# Extract uuid
	$srcUuid = $srcEl.GetAttribute("uuid")
	if (-not $srcUuid) {
		Write-Error "No uuid attribute on source element in ${dirName}/${objName}.xml"
		exit 1
	}

	# Extract properties for CommonModule
	$srcProps = @{}
	$propsNode = $srcEl.SelectSingleNode("md:Properties", $srcNs)
	if ($propsNode) {
		foreach ($propName in $commonModuleProps) {
			$propNode = $propsNode.SelectSingleNode("md:${propName}", $srcNs)
			if ($propNode) {
				$srcProps[$propName] = $propNode.InnerText.Trim()
			}
		}
		# DefinedType: carry the <Type> definition. A type alias is meaningless as a bare shell —
		# the platform needs its underlying type (e.g. to know a column is a summable Number for totals).
		if ($typeName -eq "DefinedType") {
			$typeNode = $propsNode.SelectSingleNode("md:Type", $srcNs)
			if ($typeNode) {
				$srcProps["__TypeXml"] = [regex]::Replace($typeNode.OuterXml, '\s+xmlns(?::\w+)?="[^"]*"', '')
			}
		}
		# Владельцы: стандартное поле «Owner» появляется у справочника, только если задан Owners
		if ($script:typesWithOwners -ccontains $typeName) {
			$ownersNode = $propsNode.SelectSingleNode("md:Owners", $srcNs)
			if ($ownersNode -and $ownersNode.HasChildNodes) {
				$srcProps["__OwnersXml"] = [regex]::Replace($ownersNode.OuterXml, '\s+xmlns(?::\w+)?="[^"]*"', '')
			}
		}
		# Скалярные свойства, включающие стандартные поля своего типа
		foreach ($gp in @($script:typeGateProps[$typeName])) {
			if (-not $gp) { continue }
			$gpNode = $propsNode.SelectSingleNode("md:${gp}", $srcNs)
			if ($gpNode) { $srcProps[$gp] = $gpNode.InnerText.Trim() }
		}
	}

	# Whether the platform emits <ChildObjects> for this type — the source object is the ground truth
	$srcProps["__HasChildObjects"] = ($srcEl.SelectSingleNode("md:ChildObjects", $srcNs) -ne $null)

	return @{
		Uuid = $srcUuid
		Properties = $srcProps
		Element = $srcEl
		NsManager = $srcNs
	}
}

# --- 10b. Helper: read source form UUID ---
function Read-SourceFormUuid {
	param([string]$typeName, [string]$objName, [string]$formName)

	$dirName = $childTypeDirMap[$typeName]
	# Общая форма — сама объект конфигурации: её описание лежит рядом с другими, а не в Forms владельца
	$srcFile = if ($typeName -eq 'CommonForm') { Join-Path (Join-Path $cfgDir $dirName) "${objName}.xml" }
		else { Join-Path (Join-Path (Join-Path (Join-Path $cfgDir $dirName) $objName) "Forms") "${formName}.xml" }
	if (-not (Test-Path $srcFile)) {
		Write-Error "Source form not found: $srcFile"
		exit 1
	}

	$srcDoc = New-Object System.Xml.XmlDocument
	$srcDoc.PreserveWhitespace = $false
	$srcDoc.Load($srcFile)

	$srcEl = $null
	foreach ($c in $srcDoc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $srcEl = $c; break }
	}
	if (-not $srcEl) {
		Write-Error "No metadata element found in source form: $srcFile"
		exit 1
	}

	$srcUuid = $srcEl.GetAttribute("uuid")
	if (-not $srcUuid) {
		Write-Error "No uuid attribute on source form element: $srcFile"
		exit 1
	}

	return $srcUuid
}

# --- 10c. Helper: borrow a form ---
function Borrow-Form {
	param([string]$typeName, [string]$objName, [string]$formName, [switch]$BorrowMainAttr)

	$dirName = $childTypeDirMap[$typeName]
	$enc = New-Object System.Text.UTF8Encoding($true)

	# Общая форма — сама объект конфигурации: описание CommonForms/<Имя>.xml с корнем <CommonForm>,
	# тело CommonForms/<Имя>/Ext/Form.xml, регистрация в Configuration.xml. Форма объекта — в Forms
	# владельца. Остальное (скелет, BaseForm, связи, оформление, картинки) одинаково (эталон УТ link).
	$isCommonForm = $typeName -eq 'CommonForm'
	# Уже заимствованная общая форма (в т.ч. оболочкой от прежних версий навыка) в Configuration.xml
	# уже есть — повторно не регистрируем
	$commonFormRegistered = $isCommonForm -and (Test-ObjectBorrowed $typeName $objName)
	if ($isCommonForm) {
		$srcFormDir = Join-Path (Join-Path $cfgDir $dirName) $objName
		$formMetaFile = Join-Path (Join-Path $extDir $dirName) "${objName}.xml"
		$extFormDir = Join-Path (Join-Path $extDir $dirName) $objName
		$formMetaTag = 'CommonForm'
	} else {
		$srcFormDir = Join-Path (Join-Path (Join-Path (Join-Path $cfgDir $dirName) $objName) "Forms") $formName
		$formMetaFile = Join-Path (Join-Path (Join-Path (Join-Path $extDir $dirName) $objName) "Forms") "${formName}.xml"
		$extFormDir = Join-Path (Join-Path (Join-Path (Join-Path $extDir $dirName) $objName) "Forms") $formName
		$formMetaTag = 'Form'
	}

	# 1. Read source form UUID
	$formUuid = Read-SourceFormUuid $typeName $objName $formName
	Info "  Source form UUID: $formUuid"

	# 2. Read source Form.xml content
	$srcFormXmlPath = Join-Path $srcFormDir "Ext/Form.xml"
	if (-not (Test-Path $srcFormXmlPath)) {
		Write-Error "Source Form.xml not found: $srcFormXmlPath"
		exit 1
	}
	$srcFormContent = [System.IO.File]::ReadAllText($srcFormXmlPath, $enc)

	# 3. Generate form metadata XML (ФормаЭлемента.xml).
	# If the wrapper was already borrowed, reuse its uuid so re-borrow is idempotent
	# (regenerating it would churn the form's identity on every rerun).
	$newFormUuid = ""
	if (Test-Path $formMetaFile) {
		try {
			$existingDoc = New-Object System.Xml.XmlDocument
			$existingDoc.Load($formMetaFile)
			$existingFormNode = $existingDoc.DocumentElement.SelectSingleNode("*[local-name()='$formMetaTag']")
			if ($existingFormNode) {
				$existingUuid = $existingFormNode.GetAttribute("uuid")
				if ($existingUuid) { $newFormUuid = $existingUuid }
			}
		} catch { }
	}
	if (-not $newFormUuid) { $newFormUuid = [guid]::NewGuid().ToString() }
	$formMetaSb = New-Object System.Text.StringBuilder
	$formMetaSb.AppendLine("<?xml version=`"1.0`" encoding=`"UTF-8`"?>") | Out-Null
	$formMetaSb.AppendLine("<MetaDataObject $($script:xmlnsDecl) version=`"$($script:formatVersion)`">") | Out-Null
	$formMetaSb.AppendLine("`t<$formMetaTag uuid=`"${newFormUuid}`">") | Out-Null
	$formMetaSb.AppendLine("`t`t<InternalInfo/>") | Out-Null
	$formMetaSb.AppendLine("`t`t<Properties>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<ObjectBelonging>Adopted</ObjectBelonging>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<Name>${formName}</Name>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<Comment/>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<ExtendedConfigurationObject>${formUuid}</ExtendedConfigurationObject>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<FormType>Managed</FormType>") | Out-Null
	$formMetaSb.AppendLine("`t`t</Properties>") | Out-Null
	$formMetaSb.AppendLine("`t</$formMetaTag>") | Out-Null
	$formMetaSb.Append("</MetaDataObject>") | Out-Null

	# 4. Create directories
	$formMetaDir = Split-Path $formMetaFile -Parent
	if (-not (Test-Path $formMetaDir)) {
		New-Item -ItemType Directory -Path $formMetaDir -Force | Out-Null
	}

	# Write form metadata
	[System.IO.File]::WriteAllText($formMetaFile, $formMetaSb.ToString(), $enc)
	Info "  Created: $formMetaFile"

	# 5. Generate Form.xml with BaseForm (visual elements only)
	# Parse source Form.xml as XmlDocument
	$srcFormDoc = New-Object System.Xml.XmlDocument
	$srcFormDoc.PreserveWhitespace = $true
	$srcFormDoc.Load($srcFormXmlPath)
	$srcFormEl = $srcFormDoc.DocumentElement

	# Borrowed form must use the extension's format version (not the source form's), so the whole
	# extension stays uniform — otherwise the platform rejects the import on a version mismatch
	# (e.g. a 2.13 form inside a 2.17 extension). The platform itself upgrades the form to the root version.
	$formVersion = $script:formatVersion

	# Find direct children: form properties, AutoCommandBar, ChildItems.
	# Секции формы отбираются по имени, а не по позиции: свойства лежат и до, и после <CommandSet>
	# (корпусная проверка: у всех 794 форм документов ERP с CommandSet он стоит раньше AutoCommandBar,
	# а AutoTime/UsePostingMode/RepostOnWrite — после него). Позиционная отсечка теряла весь хвост,
	# и платформа молча подставляла дефолты вместо потерянных свойств.
	$srcAutoCmd = $null
	$srcChildItems = $null
	$formProps = @()
	foreach ($fc in $srcFormEl.ChildNodes) {
		if ($fc.NodeType -ne 'Element') { continue }
		if ($fc.LocalName -eq 'AutoCommandBar' -and -not $srcAutoCmd) {
			$srcAutoCmd = $fc; continue
		}
		if ($fc.LocalName -eq 'ChildItems' -and -not $srcChildItems) {
			$srcChildItems = $fc; continue
		}
		# Структурные секции: в расширении их содержимое недействительно (обработчики, команды и
		# параметры базовой формы, ссылки командного интерфейса на команды базовой конфигурации).
		if ($script:formStructuralSections -ccontains $fc.LocalName) { continue }
		# Свойства, значение которых — имя реквизита формы. Реквизиты в заимствованную форму не
		# переносятся, поэтому Конфигуратор такие свойства выбрасывает (проверено на форме отчёта:
		# ReportResult и DetailsData выброшены, CustomSettingsFolder — имя элемента — сохранён).
		if ($script:formAttributeRefProps -ccontains $fc.LocalName) { continue }
		$formProps += $fc.OuterXml
	}

	# Get OuterXml and strip redundant namespace redeclarations (they're on root <Form>)
	$nsStripPattern = '\s+xmlns(?::\w+)?="[^"]*"'

	# Основной реквизит исходной формы: его имя — корень путей к данным, которые нужно сохранить
	# («Объект.» у формы объекта, «Список.» у формы списка, «Запись.» у формы записи регистра)
	# Имя основного реквизита источника нужно в обоих режимах: по нему опознаётся корень путей
	# в ссылках параметров выбора. А $mainAttrName управляет вырезанием привязок и потому остаётся
	# пустым в скелетном режиме — там привязки снимаются все.
	$srcMainInfo = Get-MainAttributeInfo $srcFormEl $nsStripPattern
	$srcMainAttrName = if ($srcMainInfo) { $srcMainInfo.Name } else { "" }
	$formAttrIds = Get-FormAttributeIds $srcFormEl
	# Условное оформление формы Конфигуратор копирует как есть в обе части, внутрь <Attributes>
	# после реквизитов — и без основного реквизита тоже; ссылки на незаимствованные реквизиты формы
	# платформа принимает (эталоны УТ StdPic, StdPic_WithMain, CAStyle, УНФ Номенклатура)
	$srcCondAppearance = $srcFormEl.SelectSingleNode("*[local-name()='Attributes']/*[local-name()='ConditionalAppearance']")
	$srcCondAppearanceXml = if ($srcCondAppearance) { [regex]::Replace($srcCondAppearance.OuterXml, $nsStripPattern, '') } else { "" }
	$mainAttrInfo = if ($BorrowMainAttr) { $srcMainInfo } else { $null }
	$mainAttrName = if ($mainAttrInfo) { $mainAttrInfo.Name } else { "" }
	if ($BorrowMainAttr -and -not $mainAttrInfo) {
		Warn "  У формы нет основного реквизита — -BorrowMainAttribute проигнорирован"
	}

	# Имена реквизитов объекта нужны в обоих режимах: без заимствования — для кода пути в связях
	# формы, с заимствованием — чтобы отличить реквизит (разрешается текстом) от стандартного поля
	# У общей формы реквизиты берутся у владельца, выведенного из типа основного реквизита;
	# у набора констант — ничего: код пути на константу не измерен, связь без основного реквизита
	# вырезается с предупреждением, с ним — остаётся текстом
	if ($isCommonForm) {
		$cfOwner = Resolve-CommonFormOwner $srcFormEl
		$srcAttrUuids = @{}
		if ($cfOwner -and $cfOwner.Kind -eq 'Object') {
			$srcAttrUuids = Get-SourceAttributeUuids $cfOwner.TypeName $cfOwner.ObjName
		} elseif ($cfOwner -and $cfOwner.Kind -eq 'Constants') {
			# Константы, на которые есть пути: с основным реквизитом путь на заимствованную — текстом
			foreach ($cName in @((Collect-FormDataPaths $srcFormXmlPath $cfOwner.MainName).FirstLevel.Keys)) {
				$cFile = Join-Path (Join-Path $cfgDir "Constants") "${cName}.xml"
				if (-not (Test-Path $cFile)) { continue }
				$cm = [regex]::Match([System.IO.File]::ReadAllText($cFile), '<Constant uuid="([^"]+)"')
				if ($cm.Success) { $srcAttrUuids[$cName] = $cm.Groups[1].Value }
			}
		}
	} else {
		$srcAttrUuids = Get-SourceAttributeUuids $typeName $objName
	}
	# Реквизиты объекта, которые попадут в расширение: в режиме Form — только используемые формой
	# (тот же сбор, что в Borrow-MainAttribute), в режиме All — все ($null)
	$borrowedNames = $null
	if ($mainAttrInfo -and $BorrowMainAttribute -eq 'Form') {
		$borrowedNames = (Collect-FormDataPaths $srcFormXmlPath $srcMainAttrName).FirstLevel
	}
	$linkCtx = Get-LinkContext $srcFormEl $srcMainAttrName ([bool]$mainAttrInfo) $borrowedNames $srcAttrUuids $formAttrIds

	# AutoCommandBar: keep ChildItems (buttons with CommandName→0), Autofill→false
	$autoCmdXml = ""
	if ($srcAutoCmd) {
		$autoCmdXml = $srcAutoCmd.OuterXml
		$autoCmdXml = [regex]::Replace($autoCmdXml, $nsStripPattern, '')
		$autoCmdXml = [regex]::Replace($autoCmdXml, '<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>')
		$autoCmdXml = $autoCmdXml -replace '<Autofill>true</Autofill>', '<Autofill>false</Autofill>'
		# Вложенный CommandSet выбрасывается целиком, а не опустошается: Конфигуратор в заимствованной
		# форме оставляет только корневой (тот идёт свойством формы, здесь его нет).
		$autoCmdXml = [regex]::Replace($autoCmdXml, '(?s)\s*<CommandSet>.*?</CommandSet>', '')
		$autoCmdXml = [regex]::Replace($autoCmdXml, '\s*<CommandSet/>', '')
		# Strip data-binding tags whose root attribute isn't borrowed
		$autoCmdXml = Strip-FormBindings $autoCmdXml $mainAttrName
		$autoCmdXml = Rewrite-ChoiceParameterLinks $autoCmdXml $linkCtx
	}

	# Картинка декорации в заимствованную форму не переносится: Конфигуратор выбрасывает <Picture>
	# у PictureDecoration из обеих частей формы при любом виде картинки (своя, общая, стандартная)
	# и не тянет за ней ни файл, ни общую картинку. Замер 8.3.27: 10 декораций в 5 формах УТ.
	# Картинки кнопок, таблиц и полей картинки остаются — вместе с файлами, см. копирование ниже.
	if ($srcChildItems) {
		foreach ($decoPic in @($srcChildItems.SelectNodes(".//*[local-name()='PictureDecoration']/*[local-name()='Picture']"))) {
			$prevWs = $decoPic.PreviousSibling
			if ($prevWs -and ($prevWs.NodeType -eq 'Whitespace' -or $prevWs.NodeType -eq 'SignificantWhitespace')) {
				$decoPic.ParentNode.RemoveChild($prevWs) | Out-Null
			}
			$decoPic.ParentNode.RemoveChild($decoPic) | Out-Null
		}
	}

	# ChildItems: copy full tree, clean up base-config references
	$childItemsXml = ""
	if ($srcChildItems) {
		$childItemsXml = $srcChildItems.OuterXml
		$childItemsXml = [regex]::Replace($childItemsXml, $nsStripPattern, '')
		# Replace all CommandName values with 0
		$childItemsXml = [regex]::Replace($childItemsXml, '<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>')
		# Strip data-binding tags whose root attribute isn't borrowed
		# (DataPath/TitleDataPath/FooterDataPath/HeaderDataPath/MultipleValue*/RowPicture*)
		$childItemsXml = Strip-FormBindings $childItemsXml $mainAttrName
		$childItemsXml = Rewrite-ChoiceParameterLinks $childItemsXml $linkCtx
		# Вложенные CommandSet (у таблиц, полей табличного документа и т.п.) — целиком, см. выше.
		# Исключение — набор таблицы самого основного реквизита, когда он заимствован: его команды
		# (Find/CancelSearch динамического списка) снова разрешимы, и Конфигуратор набор оставляет
		# (эталоны УТ CommonMain/ФайлыВТоме, StdPic_WithMain/ЖурналСкладскихАктов; без основного
		# реквизита и у прочих элементов — выброшен во всех эталонах).
		$keptCmdSets = [ordered]@{}
		if ($mainAttrName) {
			$mainTablePat = '(?s)(<Table name="[^"]+" id="\d+">(?:(?!<ChildItems>|</Table>|<CommandSet>).)*?<DataPath>' +
				[regex]::Escape($mainAttrName) + '</DataPath>(?:(?!<ChildItems>|</Table>|<CommandSet>).)*?)(<CommandSet>.*?</CommandSet>)'
			$childItemsXml = [regex]::Replace($childItemsXml, $mainTablePat, {
				param($m)
				$key = "@@KEPTCMDSET$($keptCmdSets.Count)@@"
				$keptCmdSets[$key] = $m.Groups[2].Value
				$m.Groups[1].Value + $key
			})
		}
		$childItemsXml = [regex]::Replace($childItemsXml, '(?s)\s*<CommandSet>.*?</CommandSet>', '')
		$childItemsXml = [regex]::Replace($childItemsXml, '\s*<CommandSet/>', '')
		foreach ($key in $keptCmdSets.Keys) { $childItemsXml = $childItemsXml.Replace($key, $keptCmdSets[$key]) }
		$childItemsXml = Rewrite-TypeLinks $childItemsXml $linkCtx
		# Strip element-level Events (base form handlers not in extension)
		$childItemsXml = [regex]::Replace($childItemsXml, '(?s)\s*<Events>.*?</Events>', '')

		# Collect CommonPicture references from ChildItems and AutoCommandBar
		$referencedPictures = @{}
		$picRefs = [regex]::Matches($childItemsXml, '<xr:Ref>CommonPicture\.(\w+)</xr:Ref>')
		foreach ($m in $picRefs) { $referencedPictures[$m.Groups[1].Value] = $true }
		if ($autoCmdXml) {
			$picRefs2 = [regex]::Matches($autoCmdXml, '<xr:Ref>CommonPicture\.(\w+)</xr:Ref>')
			foreach ($m in $picRefs2) { $referencedPictures[$m.Groups[1].Value] = $true }
		}

		# Auto-borrow referenced CommonPictures (if not already borrowed)
		$autoBorrowedPics = @()
		foreach ($picName in $referencedPictures.Keys) {
			if (-not (Test-ObjectBorrowed "CommonPicture" $picName)) {
				$picSrcFile = Join-Path (Join-Path $cfgDir "CommonPictures") "${picName}.xml"
				if (Test-Path $picSrcFile) {
					$src = Read-SourceObject "CommonPicture" $picName
					$borrowedXml = Build-BorrowedObjectXml "CommonPicture" $picName $src.Uuid $src.Properties
					$targetDir = Join-Path $extDir "CommonPictures"
					if (-not (Test-Path $targetDir)) {
						New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
					}
					$targetFile = Join-Path $targetDir "${picName}.xml"
					$encBom = New-Object System.Text.UTF8Encoding($true)
					[System.IO.File]::WriteAllText($targetFile, $borrowedXml, $encBom)
					Add-ToChildObjects "CommonPicture" $picName
					$autoBorrowedPics += $picName
					$script:borrowedFiles += $targetFile
					Info "  Auto-borrowed: CommonPicture.${picName}"
				} else {
					Warn "  CommonPicture.${picName} not found in source config — will strip from form"
				}
			}
		}

		# Collect all borrowed CommonPictures (including previously borrowed)
		$borrowedPicSet = @{}
		$nsMgr2 = New-Object System.Xml.XmlNamespaceManager($script:xmlDoc.NameTable)
		$nsMgr2.AddNamespace("md", $script:mdNs)
		$picNodes = $script:xmlDoc.SelectNodes("//md:ChildObjects/md:CommonPicture", $nsMgr2)
		foreach ($pn in $picNodes) { $borrowedPicSet[$pn.InnerText] = $true }

		# Strip <Picture> blocks referencing non-borrowed CommonPictures
		$picBlockPattern = '(?s)\s*<Picture>\s*<xr:Ref>CommonPicture\.(\w+)</xr:Ref>.*?</Picture>'
		$picMatches = [regex]::Matches($childItemsXml, $picBlockPattern)
		# Process in reverse order to preserve positions
		for ($mi = $picMatches.Count - 1; $mi -ge 0; $mi--) {
			$pm = $picMatches[$mi]
			$cpName = $pm.Groups[1].Value
			if (-not $borrowedPicSet.ContainsKey($cpName)) {
				$childItemsXml = $childItemsXml.Remove($pm.Index, $pm.Length)
			}
		}
		# Стандартные картинки (StdPicture.*) не вырезаются: Конфигуратор оставляет их у кнопок, подменю
		# и страниц в обеих частях формы (эталоны 8.3.27, 26 элементов в 3 формах).

		# Same Picture strip for AutoCommandBar
		if ($autoCmdXml) {
			$acPicMatches = [regex]::Matches($autoCmdXml, $picBlockPattern)
			for ($mi = $acPicMatches.Count - 1; $mi -ge 0; $mi--) {
				$pm = $acPicMatches[$mi]
				$cpName = $pm.Groups[1].Value
				if (-not $borrowedPicSet.ContainsKey($cpName)) {
					$autoCmdXml = $autoCmdXml.Remove($pm.Index, $pm.Length)
				}
			}
		}

		# Auto-borrow Enums + EnumValues referenced via DesignTimeRef in ChoiceParameters
		# Collect Enum -> [EnumValue names] map
		$dtRefs = [regex]::Matches($childItemsXml, 'xr:DesignTimeRef">Enum\.(\w+)\.EnumValue\.(\w+)')
		$referencedEnumValues = @{}
		foreach ($m in $dtRefs) {
			$eName = $m.Groups[1].Value
			$evName = $m.Groups[2].Value
			if (-not $referencedEnumValues.ContainsKey($eName)) { $referencedEnumValues[$eName] = @{} }
			$referencedEnumValues[$eName][$evName] = $true
		}

		foreach ($enumName in $referencedEnumValues.Keys) {
			if (-not (Test-ObjectBorrowed "Enum" $enumName)) {
				$enumSrcFile = Join-Path (Join-Path $cfgDir "Enums") "${enumName}.xml"
				if (Test-Path $enumSrcFile) {
					# Read source Enum to get UUID and EnumValue UUIDs
					$srcParser = New-Object System.Xml.XmlDocument
					$srcParser.PreserveWhitespace = $true
					$srcParser.Load($enumSrcFile)
					$srcEnumEl = $null
					foreach ($cn in $srcParser.DocumentElement.ChildNodes) {
						if ($cn.NodeType -eq 'Element') { $srcEnumEl = $cn; break }
					}
					$srcEnumUuid = $srcEnumEl.GetAttribute("uuid")

					# Find source EnumValues by name
					$enumValueXmls = @()
					$neededValues = $referencedEnumValues[$enumName]
					$srcNsMgr = New-Object System.Xml.XmlNamespaceManager($srcParser.NameTable)
					$srcNsMgr.AddNamespace("md", $script:mdNs)
					$srcEvNodes = $srcEnumEl.SelectNodes("md:ChildObjects/md:EnumValue", $srcNsMgr)
					foreach ($evNode in $srcEvNodes) {
						$evUuid = $evNode.GetAttribute("uuid")
						$evNameNode = $evNode.SelectSingleNode("md:Properties/md:Name", $srcNsMgr)
						if ($evNameNode -and $neededValues.ContainsKey($evNameNode.InnerText)) {
							$newEvUuid = [guid]::NewGuid().ToString()
							$enumValueXmls += @"
			<EnumValue uuid="${newEvUuid}">
				<InternalInfo/>
				<Properties>
					<ObjectBelonging>Adopted</ObjectBelonging>
					<Name>$($evNameNode.InnerText)</Name>
					<Comment/>
					<ExtendedConfigurationObject>${evUuid}</ExtendedConfigurationObject>
				</Properties>
			</EnumValue>
"@
						}
					}

					# Build borrowed Enum with EnumValues in ChildObjects
					$src = Read-SourceObject "Enum" $enumName
					$borrowedXml = Build-BorrowedObjectXml "Enum" $enumName $src.Uuid $src.Properties
					if ($enumValueXmls.Count -gt 0) {
						$evBlock = ($enumValueXmls -join "`r`n")
						$borrowedXml = $borrowedXml -replace '<ChildObjects/>', "<ChildObjects>`r`n${evBlock}`r`n`t`t</ChildObjects>"
					}

					$targetDir = Join-Path $extDir "Enums"
					if (-not (Test-Path $targetDir)) {
						New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
					}
					$targetFile = Join-Path $targetDir "${enumName}.xml"
					$encBom = New-Object System.Text.UTF8Encoding($true)
					[System.IO.File]::WriteAllText($targetFile, $borrowedXml, $encBom)
					Add-ToChildObjects "Enum" $enumName
					$script:borrowedFiles += $targetFile
					Info "  Auto-borrowed: Enum.${enumName} (with $($enumValueXmls.Count) EnumValue(s))"
				} else {
					Warn "  Enum.${enumName} not found in source config"
				}
			}
		}
	}

	# Вне блока ChildItems: стили нужны и оформлению формы без элементов
	# Auto-borrow StyleItems referenced in ChildItems and in the form's conditional appearance
	# (стиль только из оформления Конфигуратор тоже заимствует — эталон УТ CAStyle)
	# Pattern 1: <Font ref="style:XXX" kind="StyleItem"/>, <TitleFont ref="style:XXX" ... kind="StyleItem"/>
	# Pattern 2: <BackColor>style:XXX</BackColor>, <TextColor>style:XXX</TextColor>, etc.
	# Порядок первого упоминания — как в Python-порте (от него зависит порядок в ChildObjects)
	$styleScanXml = $childItemsXml + $srcCondAppearanceXml
	$referencedStyles = [ordered]@{}
	$styleRefs1 = [regex]::Matches($styleScanXml, 'ref="style:(\w+)"[^>]*kind="StyleItem"')
	foreach ($m in $styleRefs1) { $referencedStyles[$m.Groups[1].Value] = $true }
	# Закрывающий тег может быть с префиксом: в оформлении значение — <dcscor:value>style:X</dcscor:value>
	$styleRefs2 = [regex]::Matches($styleScanXml, '>style:(\w+)</[\w:]+>')
	foreach ($m in $styleRefs2) { $referencedStyles[$m.Groups[1].Value] = $true }

	foreach ($styleName in $referencedStyles.Keys) {
		if (-not (Test-ObjectBorrowed "StyleItem" $styleName)) {
			$styleSrcFile = Join-Path (Join-Path $cfgDir "StyleItems") "${styleName}.xml"
			if (Test-Path $styleSrcFile) {
				$src = Read-SourceObject "StyleItem" $styleName
				$borrowedXml = Build-BorrowedObjectXml "StyleItem" $styleName $src.Uuid $src.Properties
				$targetDir = Join-Path $extDir "StyleItems"
				if (-not (Test-Path $targetDir)) {
					New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
				}
				$targetFile = Join-Path $targetDir "${styleName}.xml"
				$encBom = New-Object System.Text.UTF8Encoding($true)
				[System.IO.File]::WriteAllText($targetFile, $borrowedXml, $encBom)
				Add-ToChildObjects "StyleItem" $styleName
				$script:borrowedFiles += $targetFile
				Info "  Auto-borrowed: StyleItem.${styleName}"
			}
			# Файла нет — встроенный стиль платформы (ImportantColor, AccentColor…): заимствовать
			# нечего, пропускаем молча. Пользовательский стиль, на который ссылается форма, в
			# валидном источнике существует всегда — предупреждение было только шумом.
		}
	}
	# Открывающий тег <Form ...> берём из исходной формы — ради её объявлений пространств имён,
	# но version подставляем СВОЮ: форма обязана нести версию расширения, иначе платформа
	# отвергает импорт (форма 2.13 внутри расширения 2.17). Раньше тег копировался целиком,
	# и версия источника молча побеждала.
	$xmlDecl = '<?xml version="1.0" encoding="UTF-8"?>'
	$formTag = "<Form version=`"${formVersion}`">"
	if ($srcFormContent -match '(?s)^(<\?xml[^?]*\?>)') { $xmlDecl = $Matches[1] }
	if ($srcFormContent -match '(<Form[^>]*>)') {
		$srcTag = $Matches[1]
		$srcNs = $srcTag -replace '^<Form\s*', '' -replace '\s*/?>$', '' -replace '\s*version="[^"]*"', ''
		# 2.21 (8.5): пространство палитры. Место строгое — после lf, перед style.
		if ((Get-FormatRank $formVersion) -ge 221 -and $srcNs -notmatch 'xmlns:pal=') {
			$srcNs = $srcNs -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
		}
		$formTag = if ($srcNs) { "<Form $srcNs version=`"${formVersion}`">" } else { "<Form version=`"${formVersion}`">" }
	}

	# Build output Form.xml
	$formXmlSb = New-Object System.Text.StringBuilder
	$formXmlSb.Append($xmlDecl) | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null
	$formXmlSb.Append($formTag) | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null

	# Part 1: form properties + AutoCommandBar + ChildItems
	foreach ($propXml in $formProps) {
		$propXml = [regex]::Replace($propXml, $nsStripPattern, '')
		$formXmlSb.Append("`t$propXml`r`n") | Out-Null
	}
	if ($autoCmdXml) {
		$formXmlSb.Append("`t$autoCmdXml") | Out-Null
		$formXmlSb.Append("`r`n") | Out-Null
	}
	if ($childItemsXml) {
		$formXmlSb.Append("`t$childItemsXml") | Out-Null
		$formXmlSb.Append("`r`n") | Out-Null
	}
	# Attributes: основной реквизит (с -BorrowMainAttribute) и условное оформление формы — после него
	$withMainAttr = $BorrowMainAttr -and $mainAttrInfo
	if ($withMainAttr -or $srcCondAppearanceXml) {
		$formXmlSb.Append("`t<Attributes>`r`n") | Out-Null
		if ($withMainAttr) { $formXmlSb.Append("`t`t$($mainAttrInfo.Xml)`r`n") | Out-Null }
		if ($srcCondAppearanceXml) { $formXmlSb.Append("`t`t$srcCondAppearanceXml`r`n") | Out-Null }
		$formXmlSb.Append("`t</Attributes>") | Out-Null
	} else {
		$formXmlSb.Append("`t<Attributes/>") | Out-Null
	}
	$formXmlSb.Append("`r`n") | Out-Null

	# BaseForm: same content, indented one more level (многострочный текст не сдвигается)
	$formXmlSb.Append("`t<BaseForm version=`"${formVersion}`">") | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null

	foreach ($propXml in $formProps) {
		$propXml = [regex]::Replace($propXml, $nsStripPattern, '')
		$formXmlSb.Append((Get-BaseFormIndented $propXml "`t`t") + "`r`n") | Out-Null
	}
	if ($autoCmdXml) {
		$formXmlSb.Append((Get-BaseFormIndented $autoCmdXml "`t`t") + "`r`n") | Out-Null
	}
	if ($childItemsXml) {
		$formXmlSb.Append((Get-BaseFormIndented $childItemsXml "`t`t") + "`r`n") | Out-Null
	}

	# BaseForm Attributes: same as main section
	if ($withMainAttr -or $srcCondAppearanceXml) {
		$formXmlSb.Append("`t`t<Attributes>`r`n") | Out-Null
		# В BaseForm та же секция на уровень глубже — сдвиг тот же, что у ChildItems
		if ($withMainAttr) { $formXmlSb.Append((Get-BaseFormIndented $mainAttrInfo.Xml "`t`t`t") + "`r`n") | Out-Null }
		if ($srcCondAppearanceXml) { $formXmlSb.Append((Get-BaseFormIndented $srcCondAppearanceXml "`t`t`t") + "`r`n") | Out-Null }
		$formXmlSb.Append("`t`t</Attributes>") | Out-Null
	} else {
		$formXmlSb.Append("`t`t<Attributes/>") | Out-Null
	}
	$formXmlSb.Append("`r`n") | Out-Null
	$formXmlSb.Append("`t</BaseForm>") | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null
	$formXmlSb.Append("</Form>") | Out-Null

	# Динамический список с ручным запросом: в расширении его запрос компилируется в контексте
	# расширения, и любой объект запроса, которого там нет, делает невалидными все поля списка
	# («Неверный путь к данным»). Конфигуратор такие пути пишет с тильдой — платформа разрешает их
	# после наложения на основную конфигурацию; путь, разрешимый и так, она при загрузке разрешает
	# и выгружает уже без тильды (замер 8.3.24). Поэтому тильда — без разбора запроса — всем
	# привязкам к полям списка, которые платформа проверяет при загрузке: *DataPath элементов
	# (DataPath, FooterDataPath, RowPictureDataPath…) и <Field> в UseAlways реквизита. Сам список
	# (DataPath без поля) — как есть; пути отбора и оформления (dcsset:/dcscor:) при загрузке не
	# проверяются, их не трогаем.
	$formXmlText = $formXmlSb.ToString()
	if ($withMainAttr -and $mainAttrInfo.Xml -match '<ManualQuery>true</ManualQuery>') {
		$dlFieldPat = '(<(?:\w*DataPath|Field)>)(?=' + [regex]::Escape($mainAttrInfo.Name) + '\.)'
		$script:dlCount = 0
		$formXmlText = [regex]::Replace($formXmlText, $dlFieldPat, { param($m) $script:dlCount++; $m.Groups[1].Value + '~' })
		if ($script:dlCount -gt 0) {
			Info "  Поля динамического списка с ручным запросом: пути с тильдой ($($script:dlCount)) — разрешатся после наложения"
		}
	}

	# Write Form.xml
	$formXmlDir = Join-Path $extFormDir "Ext"
	if (-not (Test-Path $formXmlDir)) {
		New-Item -ItemType Directory -Path $formXmlDir -Force | Out-Null
	}
	$formXmlFile = Join-Path $formXmlDir "Form.xml"
	# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
	# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
	# поэтому они идут первыми ветками альтернации и возвращаются как есть.
	# Здесь источник не XmlWriter, а OuterXml исходного документа — спацовывает так же.
	$formXmlText = [regex]::Replace($formXmlText, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
	# Файл создаём мы — канон выгрузки: CRLF в разделителях строк.
	$formXmlText = ($formXmlText -replace "`r`n", "`n") -replace "`n", "`r`n"
	[System.IO.File]::WriteAllText($formXmlFile, $formXmlText, $enc)
	Info "  Created: $formXmlFile"
	if ($script:droppedLinks.Count -gt 0) {
		$uniq = @($script:droppedLinks | Sort-Object -Unique)
		Warn "  Вырезано связей формы: $($uniq.Count) — путь не разрешается в расширении: $($uniq -join ', ')"
		$script:droppedLinks = @()
	}

	# 6. Create empty Module.bsl — but NEVER overwrite an existing one (re-borrow must
	# not clobber user code added to the form module).
	$moduleDir = Join-Path $formXmlDir "Form"
	if (-not (Test-Path $moduleDir)) {
		New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
	}
	$moduleBslFile = Join-Path $moduleDir "Module.bsl"
	if (Test-Path $moduleBslFile) {
		Info "  Preserved existing Module.bsl"
	} else {
		[System.IO.File]::WriteAllText($moduleBslFile, "", $enc)
		Info "  Created: $moduleBslFile"
	}

	# 6b. Встроенные картинки элементов. Form.xml ссылается на них как <xr:Abs>Файл</xr:Abs>, а сам файл
	# лежит в Ext/Form/Items/<Элемент>/<Файл>; без него платформа отвергает расширение («Файл не найден»).
	# Конфигуратор копирует их байт в байт. Берём ровно то, на что ссылается скелет (картинки декораций
	# выброшены выше). Уже лежащий файл не перезаписываем: его могли заменить в расширении.
	$picFiles = @()
	$srcItemsDir = Join-Path (Join-Path (Split-Path $srcFormXmlPath -Parent) "Form") "Items"
	$picRels = New-Object System.Collections.Generic.List[string]
	foreach ($sect in @($srcAutoCmd, $srcChildItems)) {
		if (-not $sect) { continue }
		foreach ($absNode in @($sect.SelectNodes(".//*[local-name()='Abs' and namespace-uri()='http://v8.1c.ru/8.3/xcf/readable']"))) {
			$picOwner = $absNode.ParentNode.ParentNode
			$picElName = $picOwner.GetAttribute("name")
			$picFileName = $absNode.InnerText.Trim()
			if (-not $picElName -or -not $picFileName) { continue }
			# Платформа пишет сюда голое имя файла. Иное (путь, «..») — не наша выгрузка: мимо Items не ходим.
			if ($picElName -match '[\\/]' -or $picFileName -match '[\\/]' -or
				$picElName -match '^\.\.?$' -or $picFileName -match '^\.\.?$') {
				Warn "  Картинка элемента пропущена — не имя файла: $picElName / $picFileName"
				continue
			}
			$rel = "$picElName/$picFileName"
			if (-not $picRels.Contains($rel)) { $picRels.Add($rel) }
		}
	}
	$picRelArr = $picRels.ToArray()
	[Array]::Sort($picRelArr, [System.StringComparer]::Ordinal)
	foreach ($rel in $picRelArr) {
		$picParts = $rel.Split('/')
		$srcPic = Join-Path (Join-Path $srcItemsDir $picParts[0]) $picParts[1]
		$dstPicDir = Join-Path (Join-Path $moduleDir "Items") $picParts[0]
		$dstPic = Join-Path $dstPicDir $picParts[1]
		if (Test-Path -LiteralPath $dstPic) {
			Info "  Preserved existing: $dstPic"
			continue
		}
		if (-not (Test-Path -LiteralPath $srcPic -PathType Leaf)) {
			Warn "  Картинка элемента не найдена в источнике: $srcPic"
			continue
		}
		if (-not (Test-Path -LiteralPath $dstPicDir)) { New-Item -ItemType Directory -Path $dstPicDir -Force | Out-Null }
		Copy-Item -LiteralPath $srcPic -Destination $dstPic
		$picFiles += $dstPic
		Info "  Copied: $dstPic"
	}

	# 7. Register form: общая форма — в Configuration.xml, форма объекта — в ChildObjects владельца
	if ($isCommonForm) {
		if (-not $commonFormRegistered) { Add-ToChildObjects $typeName $objName }
	} else {
		Register-FormInObject $typeName $objName $formName
	}

	return @($formMetaFile, $formXmlFile, $moduleBslFile) + $picFiles
}

# --- 10d. Helper: register form in parent object's ChildObjects ---
function Register-FormInObject {
	param([string]$typeName, [string]$objName, [string]$formName)

	$dirName = $childTypeDirMap[$typeName]
	$objFile = Join-Path (Join-Path $extDir $dirName) "${objName}.xml"

	if (-not (Test-Path $objFile)) {
		Warn "Parent object file not found: $objFile — form not registered in ChildObjects"
		return
	}

	$objDoc = New-Object System.Xml.XmlDocument
	$objDoc.PreserveWhitespace = $true
	$objDoc.Load($objFile)

	$objNs = New-Object System.Xml.XmlNamespaceManager($objDoc.NameTable)
	$objNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

	# Find the type element
	$objEl = $null
	foreach ($c in $objDoc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $objEl = $c; break }
	}
	if (-not $objEl) {
		Warn "No type element in $objFile — form not registered"
		return
	}

	# Find or create ChildObjects
	$childObjs = $objEl.SelectSingleNode("md:ChildObjects", $objNs)
	if (-not $childObjs) {
		# Create ChildObjects element
		$childObjs = $objDoc.CreateElement("ChildObjects", "http://v8.1c.ru/8.3/MDClasses")
		$objEl.AppendChild($objDoc.CreateWhitespace("`r`n`t`t")) | Out-Null
		$objEl.AppendChild($childObjs) | Out-Null
		$objEl.AppendChild($objDoc.CreateWhitespace("`r`n`t")) | Out-Null
	}

	# Check dedup
	foreach ($c in $childObjs.ChildNodes) {
		if ($c.NodeType -eq 'Element' -and $c.LocalName -eq "Form" -and $c.InnerText -eq $formName) {
			Warn "Form '$formName' already in ChildObjects of ${typeName}.${objName}"
			return
		}
	}

	# Expand self-closing if needed
	if (-not $childObjs.HasChildNodes -or $childObjs.IsEmpty) {
		$closeWs = $objDoc.CreateWhitespace("`r`n`t`t")
		$childObjs.AppendChild($closeWs) | Out-Null
	}

	# Add <Form>formName</Form>
	$formEl = $objDoc.CreateElement("Form", "http://v8.1c.ru/8.3/MDClasses")
	$formEl.InnerText = $formName

	$trailing = $childObjs.LastChild
	$ws = $objDoc.CreateWhitespace("`r`n`t`t`t")
	if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
		$childObjs.InsertBefore($ws, $trailing) | Out-Null
		$childObjs.InsertBefore($formEl, $trailing) | Out-Null
	} else {
		$childObjs.AppendChild($ws) | Out-Null
		$childObjs.AppendChild($formEl) | Out-Null
	}

	# Save object XML
	# Стиль исходника снимаем ДО записи: правка чужого файла наследует его BOM/EOL/заголовок
	# (#44/#46/#47), новый файл получает канон выгрузки. Зеркало _detect_xml_style в py-порту.
	$style2 = Detect-XmlStyle $objFile
	$settings2 = New-Object System.Xml.XmlWriterSettings
	$settings2.Encoding = New-Object System.Text.UTF8Encoding($true)
	$settings2.Indent = $false
	$settings2.NewLineHandling = [System.Xml.NewLineHandling]::None
	$memStream2 = New-Object System.IO.MemoryStream
	$writer2 = [System.Xml.XmlWriter]::Create($memStream2, $settings2)
	$objDoc.Save($writer2)
	$writer2.Flush(); $writer2.Close()
	$text2 = [System.Text.Encoding]::UTF8.GetString($memStream2.ToArray())
	$memStream2.Close()
	$text2 = Finalize-XmlText $text2 $style2
	$writeBom2 = ($null -eq $style2) -or $style2.bom
	[System.IO.File]::WriteAllText($objFile, $text2, (New-Object System.Text.UTF8Encoding($writeBom2)))
	Info "  Registered form in: $objFile"
}

# --- 10e. Helper: check if object is already borrowed in extension ---
function Test-ObjectBorrowed {
	param([string]$typeName, [string]$objName)

	$dirName = $childTypeDirMap[$typeName]
	$objFile = Join-Path (Join-Path $extDir $dirName) "${objName}.xml"
	return (Test-Path $objFile)
}

# --- 10f. Helper: пометка расширенного свойства (<xr:PropertyState>) ---
# Свойство появилось в формате 2.19 (8.3.26): на 2.18 и ниже платформа молча выбрасывает элемент
# при загрузке. С 2.19 Конфигуратор ставит его сам при выгрузке — эмитим, чтобы исходники навыка
# совпадали с эталоном. Имя свойства = базовое имя файла модуля (Module / ObjectModule / …),
# у заимствованной формы — Form. Ставит тот, кто создал файл модуля (или форму).
function Build-PropertyStateXml {
	param([string]$propertyName, [string]$indent)

	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("${indent}<xr:PropertyState>") | Out-Null
	$sb.AppendLine("${indent}`t<xr:Property>${propertyName}</xr:Property>") | Out-Null
	$sb.AppendLine("${indent}`t<xr:State>Extended</xr:State>") | Out-Null
	$sb.Append("${indent}</xr:PropertyState>") | Out-Null
	return $sb.ToString()
}

function Set-PropertyStateFlag {
	param([string]$objFile, [string]$propertyName, [string]$formatVersion)

	if ((Get-FormatRank $formatVersion) -lt 219) { return }
	if (-not (Test-Path $objFile)) { return }

	$enc = New-Object System.Text.UTF8Encoding($true)
	$text = [System.IO.File]::ReadAllText($objFile, $enc)
	$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }

	# ПЕРВЫЙ <InternalInfo> в файле — собственный у объекта: у реквизитов и подобъектов свои,
	# но они лежат ниже, внутри <ChildObjects>.
	$empty = [regex]::Match($text, '([ \t]*)<InternalInfo\s*/>')
	$open = [regex]::Match($text, '(?s)([ \t]*)<InternalInfo>(.*?)</InternalInfo>')

	if ($empty.Success -and (-not $open.Success -or $empty.Index -lt $open.Index)) {
		$ind = $empty.Groups[1].Value
		$block = Build-PropertyStateXml $propertyName ($ind + "`t")
		$replacement = "${ind}<InternalInfo>${nl}${block}${nl}${ind}</InternalInfo>"
		$text = $text.Remove($empty.Index, $empty.Length).Insert($empty.Index, $replacement)
	} elseif ($open.Success) {
		if ($open.Groups[2].Value -match "<xr:Property>$([regex]::Escape($propertyName))</xr:Property>") { return }
		$ind = $open.Groups[1].Value
		$block = Build-PropertyStateXml $propertyName ($ind + "`t")
		# Дописываем в КОНЕЦ InternalInfo: у Конфигуратора PropertyState идёт после GeneratedType.
		$closeAt = $open.Index + $open.Length - "</InternalInfo>".Length - $ind.Length
		$text = $text.Insert($closeAt, "${block}${nl}")
	} else {
		return
	}

	[System.IO.File]::WriteAllText($objFile, $text, $enc)
}

# --- 10g. Helper: пустой модуль заимствованного объекта ---
function New-BorrowedModuleFile {
	param([string]$typeName, [string]$objName, [string]$moduleKind)

	$dirName = $childTypeDirMap[$typeName]
	$objDir = Join-Path (Join-Path $extDir $dirName) $objName
	$moduleDir = Join-Path $objDir "Ext"
	if (-not (Test-Path $moduleDir)) { New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null }

	# NEVER overwrite an existing one: повторное заимствование не должно затирать дописанный код
	# (то же правило, что у модуля формы).
	$moduleFile = Join-Path $moduleDir "${moduleKind}.bsl"
	if (Test-Path $moduleFile) {
		Info "  Preserved existing ${moduleKind}.bsl"
	} else {
		$enc = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($moduleFile, "", $enc)
		Info "  Created: $moduleFile"
	}

	# Флаг ставим и для уже существовавшего файла: состояние объекта должно отражать факт модуля.
	Set-PropertyStateFlag (Join-Path (Join-Path $extDir $dirName) "${objName}.xml") $moduleKind $script:formatVersion
	return $moduleFile
}

# --- 11. Helper: generate InternalInfo XML ---
function Build-InternalInfoXml {
	param([string]$typeName, [string]$objName, [string]$indent)

	$types = $script:generatedTypes[$typeName]
	if (-not $types -or $types.Count -eq 0) {
		return "${indent}<InternalInfo/>"
	}

	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("${indent}<InternalInfo>") | Out-Null

	# ExchangePlan: ThisNode UUID before GeneratedTypes
	if ($typeName -eq "ExchangePlan") {
		$thisNodeUuid = [guid]::NewGuid().ToString()
		$sb.AppendLine("${indent}`t<xr:ThisNode>${thisNodeUuid}</xr:ThisNode>") | Out-Null
	}

	foreach ($gt in $types) {
		$fullName = "$($gt.prefix).${objName}"
		$typeId = [guid]::NewGuid().ToString()
		$valueId = [guid]::NewGuid().ToString()
		$sb.AppendLine("${indent}`t<xr:GeneratedType name=`"${fullName}`" category=`"$($gt.category)`">") | Out-Null
		$sb.AppendLine("${indent}`t`t<xr:TypeId>${typeId}</xr:TypeId>") | Out-Null
		$sb.AppendLine("${indent}`t`t<xr:ValueId>${valueId}</xr:ValueId>") | Out-Null
		$sb.AppendLine("${indent}`t</xr:GeneratedType>") | Out-Null
	}

	$sb.Append("${indent}</InternalInfo>") | Out-Null
	return $sb.ToString()
}

# --- 11b. Collect DataPath references from source Form.xml ---
# --- 11b1. Основной реквизит исходной формы ---
# Переносится ЦЕЛИКОМ, а не собирается из констант: имя, тип и состав детей зависят от вида формы.
# У формы объекта это «Объект»/<Тип>Object + SavedData/UseAlways/Columns, у формы списка —
# «Список»/DynamicList + Settings, у формы записи регистра — «Запись»/RecordManager + SavedData.
# Синтез фиксированного набора давал для необъектных форм «Исключение XDTO» при загрузке.
# Конфигуратор меняет у скопированного реквизита только id (эталоны Issue64UtB, Issue66Example2).
# Имена реквизитов ИСХОДНОЙ формы → их id. Ссылки параметров выбора адресуют реквизит формы
# именно по id базовой формы (см. Rewrite-ChoiceParameterLinks).
function Get-FormAttributeIds {
	param($formEl)

	$result = @{}
	$attrs = $formEl.SelectSingleNode("*[local-name()='Attributes']")
	if (-not $attrs) { return $result }
	foreach ($a in $attrs.ChildNodes) {
		if ($a.NodeType -ne 'Element' -or $a.LocalName -ne 'Attribute') { continue }
		$nm = $a.GetAttribute("name"); $id = $a.GetAttribute("id")
		if ($nm -and $id) { $result[$nm] = $id }
	}
	return $result
}

# Контекст разрешения путей в связях формы (см. Resolve-LinkDataPath) — всё по ИСХОДНОЙ форме:
# колонки реквизитов формы, колонки AdditionalColumns, элементы-таблицы и вид основного реквизита.
function Get-LinkContext {
	param($formEl, [string]$mainName, [bool]$mainBorrowed, $borrowedNames, $attrUuids, $formAttrIds)

	$cols = @{}; $addCols = @{}; $tables = @{}; $kind = $null
	$attrs = $formEl.SelectSingleNode("*[local-name()='Attributes']")
	if ($attrs) {
		foreach ($a in $attrs.ChildNodes) {
			if ($a.NodeType -ne 'Element' -or $a.LocalName -ne 'Attribute') { continue }
			$nm = $a.GetAttribute("name")
			$columns = $a.SelectSingleNode("*[local-name()='Columns']")
			if ($columns) {
				foreach ($c in $columns.ChildNodes) {
					if ($c.NodeType -ne 'Element') { continue }
					if ($c.LocalName -eq 'Column') {
						$cols["$nm.$($c.GetAttribute('name'))"] = $c.GetAttribute('id')
					} elseif ($c.LocalName -eq 'AdditionalColumns') {
						$tblPath = $c.GetAttribute('table')
						foreach ($ac in @($c.SelectNodes("*[local-name()='Column']"))) {
							$addCols["$tblPath.$($ac.GetAttribute('name'))"] = $ac.GetAttribute('id')
						}
					}
				}
			}
			if ($mainName -and $nm -ceq $mainName) {
				$typeNode = $a.SelectSingleNode("*[local-name()='Type']/*[local-name()='Type']")
				if ($typeNode) {
					# Тип без имени объекта (cfg:ConstantsSet) — тоже вид
					$tm = [regex]::Match($typeNode.InnerText.Trim(), '^(?:\w+:)?(\w+)(?:\.|$)')
					if ($tm.Success -and $script:mainAttrKinds.ContainsKey($tm.Groups[1].Value)) { $kind = $script:mainAttrKinds[$tm.Groups[1].Value] }
				}
			}
		}
	}
	$items = $formEl.SelectSingleNode("*[local-name()='ChildItems']")
	if ($items) {
		foreach ($t in @($items.SelectNodes(".//*[local-name()='Table']"))) {
			$dp = $t.SelectSingleNode("*[local-name()='DataPath']")
			if ($dp) { $tables[$t.GetAttribute('name')] = @{ Id = $t.GetAttribute('id'); Path = $dp.InnerText.Trim() } }
		}
	}
	$mainId = if ($mainName -and $formAttrIds.ContainsKey($mainName)) { $formAttrIds[$mainName] } else { "1" }
	return @{
		MainName = $mainName; MainId = $mainId; MainBorrowed = $mainBorrowed; MainKind = $kind; BorrowedNames = $borrowedNames
		AttrUuids = $attrUuids; FormAttrIds = $formAttrIds; FormAttrCols = $cols; AddCols = $addCols; Tables = $tables
	}
}

function Get-MainAttributeInfo {
	param($formEl, [string]$nsStripPattern)

	$mainAttr = $formEl.SelectSingleNode("*[local-name()='Attributes']/*[local-name()='Attribute'][*[local-name()='MainAttribute']='true']")
	if (-not $mainAttr) { return $null }
	$xml = [regex]::Replace($mainAttr.OuterXml, $nsStripPattern, '')
	# id заменяется только в открывающем теге самого реквизита — у вложенных элементов свои
	$xml = [regex]::Replace($xml, '^(<Attribute\s[^>]*?)id="[^"]*"', "`${1}id=`"$script:mainAttrId`"")
	return @{ Name = $mainAttr.GetAttribute("name"); Xml = $xml }
}

function Collect-FormDataPaths {
	param([string]$formXmlPath, [string]$mainAttrName)

	# Корень путей — имя основного реквизита формы: «Объект» у формы объекта, «Список» у формы
	# списка, «Запись» у формы записи регистра. Зашитый «Объект» не находил ничего у необъектных
	# форм, и в оболочку не заимствовалось ни одного дочернего объекта.
	$root = [regex]::Escape($mainAttrName)

	$enc = New-Object System.Text.UTF8Encoding($true)
	$content = [System.IO.File]::ReadAllText($formXmlPath, $enc)

	$firstLevel = @{}
	$deepPaths = @()

	# Scan every data-binding tag (DataPath/TitleDataPath/FooterDataPath/HeaderDataPath/MultipleValue*)
	# for Объект.* references — picture-path tags carry picture indices, not data attributes.
	foreach ($tag in $script:formBindingDataTags) {
		$bms = [regex]::Matches($content, "<$tag>[^<]*\b$root\.(\w+(?:\.\w+)*)</$tag>")
		foreach ($m in $bms) {
			$path = $m.Groups[1].Value
			$segments = $path.Split(".")
			$seg0 = $segments[0]
			if ($script:standardFields -contains $seg0) { continue }
			$firstLevel[$seg0] = $true
			if ($segments.Count -ge 2) {
				$seg1 = $segments[1]
				if ($script:standardFields -contains $seg1) { continue }
				$seg2 = if ($segments.Count -ge 3) { $segments[2] } else { $null }
				$deepPaths += @{ ObjectAttr = $seg0; SubAttr = $seg1; SubSubAttr = $seg2 }
			}
		}
	}

	# Also scan <Field>Объект.X</Field> — object attributes referenced by filter/conditional-appearance
	# fields (and dynamic lists), not via a *DataPath binding (e.g. УдалитьЮрФизЛицо). Designer borrows these too.
	$fieldMatches = [regex]::Matches($content, "<Field>[^<]*\b$root\.(\w+(?:\.\w+)*)</Field>")
	foreach ($m in $fieldMatches) {
		$path = $m.Groups[1].Value
		$segments = $path.Split(".")
		$seg0 = $segments[0]
		if ($script:standardFields -contains $seg0) { continue }
		$firstLevel[$seg0] = $true
		if ($segments.Count -ge 2) {
			$seg1 = $segments[1]
			if ($script:standardFields -contains $seg1) { continue }
			$deepPaths += @{ ObjectAttr = $seg0; SubAttr = $seg1 }
		}
	}

	# Also scan <AdditionalColumns table="Объект.X"> — доп. колонки табличной части, объявленные в
	# самой форме (напр. Объект.Товары.Артикул). Такая ТЧ может больше нигде на форме не встречаться,
	# и без её заимствования платформа отвергает форму: «Неверный путь к данным».
	$acMatches = [regex]::Matches($content, "<AdditionalColumns table=`"$root\.(\w+)`"")
	foreach ($m in $acMatches) {
		$seg0 = $m.Groups[1].Value
		if ($script:standardFields -contains $seg0) { continue }
		$firstLevel[$seg0] = $true
	}

	# Текст запроса динамического списка — такое же место ссылки на реквизиты объекта, как DataPath.
	# Конфигуратор заимствует всё, что упомянуто в запросе: на эталоне Issue66Example2 это 21 из 27
	# дочерних объектов, совпадение с ним точное в обе стороны. У списка без ручного запроса
	# (<QueryText> нет) заимствуется только видимое на форме — эталон Issue66Example3.
	# Разбирать язык запросов не нужно: имена-кандидаты отфильтрует Resolve-SourceAttributes по
	# реальному составу объекта, поэтому лишние слова из запроса безвредны.
	foreach ($qm in [regex]::Matches($content, '(?s)<QueryText>(.*?)</QueryText>')) {
		foreach ($w in [regex]::Matches($qm.Groups[1].Value, '[\w]+')) {
			$word = $w.Value
			if ($script:standardFields -contains $word) { continue }
			$firstLevel[$word] = $true
		}
	}

	# Deduplicate deep paths
	$seen = @{}
	$uniqueDeep = @()
	foreach ($dp in $deepPaths) {
		$key = "$($dp.ObjectAttr).$($dp.SubAttr).$($dp.SubSubAttr)"
		if (-not $seen.ContainsKey($key)) {
			$seen[$key] = $true
			$uniqueDeep += $dp
		}
	}

	return @{ FirstLevel = $firstLevel; DeepPaths = $uniqueDeep }
}

# --- 11c. Resolve source attributes and tabular sections ---
function Resolve-SourceAttributes {
	param([string]$typeName, [string]$objName, $firstLevelNames)
	# $firstLevelNames: hashtable of names, or $null for "all"

	$dirName = $childTypeDirMap[$typeName]
	$srcFile = Join-Path (Join-Path $cfgDir $dirName) "${objName}.xml"
	if (-not (Test-Path $srcFile)) {
		Write-Error "Source object not found: $srcFile"
		exit 1
	}

	$srcDoc = New-Object System.Xml.XmlDocument
	$srcDoc.PreserveWhitespace = $false
	$srcDoc.Load($srcFile)

	$srcNs = New-Object System.Xml.XmlNamespaceManager($srcDoc.NameTable)
	$srcNs.AddNamespace("md", $script:mdNs)
	$srcNs.AddNamespace("xr", $script:xrNs)
	$srcNs.AddNamespace("v8", $script:v8Ns)

	$srcEl = $null
	foreach ($c in $srcDoc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $srcEl = $c; break }
	}
	if (-not $srcEl) { Write-Error "No metadata element in source: $srcFile"; exit 1 }

	$childObjs = $srcEl.SelectSingleNode("md:ChildObjects", $srcNs)
	if (-not $childObjs) { return @{ Attributes = @(); TabularSections = @(); ExtraProps = @{} } }

	$attrs = @()
	$tabSections = @()

	foreach ($child in $childObjs.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }

		# Реквизит объекта, измерение и ресурс регистра — один и тот же вид дочернего объекта с
		# точки зрения заимствования, различается только имя элемента. Конфигуратор переносит их
		# своим видом (эталон Issue66Example2: у регистра <Dimension> x3 и <Resource>), поэтому вид
		# запоминается и выпускается как есть — иначе измерение уехало бы в файл как <Attribute>.
		if ($script:childObjectKinds -ccontains $child.LocalName) {
			$nameNode = $child.SelectSingleNode("md:Properties/md:Name", $srcNs)
			if (-not $nameNode) { continue }
			$attrName = $nameNode.InnerText
			if ($null -ne $firstLevelNames -and -not $firstLevelNames.ContainsKey($attrName)) { continue }

			$uuid = $child.GetAttribute("uuid")
			$typeNode = $child.SelectSingleNode("md:Properties/md:Type", $srcNs)
			$typeXml = if ($typeNode) { $typeNode.OuterXml } else { "" }
			# Strip namespace declarations from Type
			$typeXml = [regex]::Replace($typeXml, '\s+xmlns(?::\w+)?="[^"]*"', '')

			$attrs += @{ Name = $attrName; Uuid = $uuid; TypeXml = $typeXml; Kind = $child.LocalName }
		}
		elseif ($child.LocalName -eq 'TabularSection') {
			$nameNode = $child.SelectSingleNode("md:Properties/md:Name", $srcNs)
			if (-not $nameNode) { continue }
			$tsName = $nameNode.InnerText
			if ($null -ne $firstLevelNames -and -not $firstLevelNames.ContainsKey($tsName)) { continue }

			$tsUuid = $child.GetAttribute("uuid")

			# Extract GeneratedTypes from InternalInfo
			$tsGenTypes = @()
			$iiNode = $child.SelectSingleNode("md:InternalInfo", $srcNs)
			if ($iiNode) {
				$gtNodes = $iiNode.SelectNodes("xr:GeneratedType", $srcNs)
				foreach ($gt in $gtNodes) {
					$tsGenTypes += @{
						Name     = $gt.GetAttribute("name")
						Category = $gt.GetAttribute("category")
						TypeId   = $gt.SelectSingleNode("xr:TypeId", $srcNs).InnerText
						ValueId  = $gt.SelectSingleNode("xr:ValueId", $srcNs).InnerText
					}
				}
			}

			# Extract ALL child attributes of TabularSection
			$tsAttrs = @()
			$tsChildObjs = $child.SelectSingleNode("md:ChildObjects", $srcNs)
			if ($tsChildObjs) {
				foreach ($tsChild in $tsChildObjs.ChildNodes) {
					if ($tsChild.NodeType -ne 'Element' -or $tsChild.LocalName -ne 'Attribute') { continue }
					$tsAttrName = $tsChild.SelectSingleNode("md:Properties/md:Name", $srcNs)
					if (-not $tsAttrName) { continue }
					$tsAttrUuid = $tsChild.GetAttribute("uuid")
					$tsTypeNode = $tsChild.SelectSingleNode("md:Properties/md:Type", $srcNs)
					$tsTypeXml = if ($tsTypeNode) { $tsTypeNode.OuterXml } else { "" }
					$tsTypeXml = [regex]::Replace($tsTypeXml, '\s+xmlns(?::\w+)?="[^"]*"', '')
					$tsAttrs += @{ Name = $tsAttrName.InnerText; Uuid = $tsAttrUuid; TypeXml = $tsTypeXml }
				}
			}

			$tabSections += @{ Name = $tsName; Uuid = $tsUuid; GeneratedTypes = $tsGenTypes; Attributes = $tsAttrs }
		}
	}

	# Extract extra Properties for main object enrichment (Hierarchical, CodeLength, etc.)
	# Ordered so PS emits the same property order as the Python port (dict preserves insertion order).
	$extraProps = [ordered]@{}
	$propsNode = $srcEl.SelectSingleNode("md:Properties", $srcNs)
	if ($propsNode) {
		# NumberPeriodicity сюда НЕ входит: платформа считает его модификацией настроек нумерации и
		# тогда требует объявить ещё и <Numerator/>, иначе /UpdateDBCfg падает — «отключать
		# контролируемость свойства "Нумератор" недопустимо». Конфигуратор его не переносит
		# (эталон заимствования документа: NumberType/NumberLength/NumberAllowedLength и всё).
		# Загрузку это не ломает, ошибка вылезает только на обновлении конфигурации БД.
		# FoldersOnTop сюда НЕ входит: платформа его у заимствованной оболочки не хранит — при
		# загрузке молча выбрасывает (проверено раундтрипом: записали, выгрузили обратно, свойства
		# нет). Конфигуратор его тоже не переносит. Остальные из списка сохраняются.
		$propsToExtract = @("Hierarchical","CodeLength","DescriptionLength","CodeType","CodeAllowedLength",
			"NumberType","NumberLength","NumberAllowedLength")
		foreach ($pName in $propsToExtract) {
			$pNode = $propsNode.SelectSingleNode("md:${pName}", $srcNs)
			if ($pNode) { $extraProps[$pName] = $pNode.InnerText }
		}
	}

	return @{ Attributes = $attrs; TabularSections = $tabSections; ExtraProps = $extraProps }
}

# --- 11d. Build adopted attribute XML ---
function Build-AdoptedAttributeXml {
	param([string]$name, [string]$sourceUuid, [string]$typeXml, [string]$indent, [string]$kind = "Attribute")

	$newUuid = [guid]::NewGuid().ToString()
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("${indent}<${kind} uuid=`"${newUuid}`">") | Out-Null
	$sb.AppendLine("${indent}`t<InternalInfo/>") | Out-Null
	$sb.AppendLine("${indent}`t<Properties>") | Out-Null
	$sb.AppendLine("${indent}`t`t<ObjectBelonging>Adopted</ObjectBelonging>") | Out-Null
	$sb.AppendLine("${indent}`t`t<Name>${name}</Name>") | Out-Null
	$sb.AppendLine("${indent}`t`t<Comment/>") | Out-Null
	$sb.AppendLine("${indent}`t`t<ExtendedConfigurationObject>${sourceUuid}</ExtendedConfigurationObject>") | Out-Null
	$sb.AppendLine("${indent}`t`t${typeXml}") | Out-Null
	$sb.AppendLine("${indent}`t</Properties>") | Out-Null
	$sb.Append("${indent}</${kind}>") | Out-Null
	return $sb.ToString()
}

# --- 11e. Build adopted tabular section XML ---
function Build-AdoptedTabularSectionXml {
	param([string]$tsName, [string]$sourceUuid, $generatedTypes, $childAttrs, [string]$indent)

	$newUuid = [guid]::NewGuid().ToString()
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("${indent}<TabularSection uuid=`"${newUuid}`">") | Out-Null

	# InternalInfo with GeneratedTypes (new UUIDs, referencing source names)
	if ($generatedTypes -and $generatedTypes.Count -gt 0) {
		$sb.AppendLine("${indent}`t<InternalInfo>") | Out-Null
		foreach ($gt in $generatedTypes) {
			$newTid = [guid]::NewGuid().ToString()
			$newVid = [guid]::NewGuid().ToString()
			$sb.AppendLine("${indent}`t`t<xr:GeneratedType name=`"$($gt.Name)`" category=`"$($gt.Category)`">") | Out-Null
			$sb.AppendLine("${indent}`t`t`t<xr:TypeId>${newTid}</xr:TypeId>") | Out-Null
			$sb.AppendLine("${indent}`t`t`t<xr:ValueId>${newVid}</xr:ValueId>") | Out-Null
			$sb.AppendLine("${indent}`t`t</xr:GeneratedType>") | Out-Null
		}
		$sb.AppendLine("${indent}`t</InternalInfo>") | Out-Null
	} else {
		$sb.AppendLine("${indent}`t<InternalInfo/>") | Out-Null
	}

	$sb.AppendLine("${indent}`t<Properties>") | Out-Null
	$sb.AppendLine("${indent}`t`t<ObjectBelonging>Adopted</ObjectBelonging>") | Out-Null
	$sb.AppendLine("${indent}`t`t<Name>${tsName}</Name>") | Out-Null
	$sb.AppendLine("${indent}`t`t<Comment/>") | Out-Null
	$sb.AppendLine("${indent}`t`t<ExtendedConfigurationObject>${sourceUuid}</ExtendedConfigurationObject>") | Out-Null
	$sb.AppendLine("${indent}`t</Properties>") | Out-Null

	# ChildObjects with all attributes
	if ($childAttrs -and $childAttrs.Count -gt 0) {
		$sb.AppendLine("${indent}`t<ChildObjects>") | Out-Null
		foreach ($ca in $childAttrs) {
			$caXml = Build-AdoptedAttributeXml $ca.Name $ca.Uuid $ca.TypeXml "${indent}`t`t"
			$sb.AppendLine($caXml) | Out-Null
		}
		$sb.AppendLine("${indent}`t</ChildObjects>") | Out-Null
	} else {
		$sb.AppendLine("${indent}`t<ChildObjects/>") | Out-Null
	}

	$sb.Append("${indent}</TabularSection>") | Out-Null
	return $sb.ToString()
}

# --- 11f. Collect reference types from attribute Type XML strings ---
function Collect-ReferenceTypes {
	param([string[]]$typeXmls)

	# Порядок первого упоминания: от него зависит порядок заимствования в ChildObjects
	$result = [ordered]@{}
	foreach ($typeXml in $typeXmls) {
		# cfg:CatalogRef.XXX, cfg:EnumRef.XXX, cfg:DocumentRef.XXX, etc.
		$refMatches = [regex]::Matches($typeXml, 'cfg:(\w+)Ref\.(\w+)')
		foreach ($m in $refMatches) {
			$refPrefix = $m.Groups[1].Value  # e.g. "Catalog", "Enum", "Document"
			$objName = $m.Groups[2].Value
			$key = "${refPrefix}.${objName}"
			if (-not $result.Contains($key)) {
				$result[$key] = @{ TypeName = $refPrefix; ObjName = $objName }
			}
		}
		# cfg:DefinedType.XXX (via v8:TypeSet or v8:Type)
		$dtMatches = [regex]::Matches($typeXml, 'cfg:DefinedType\.(\w+)')
		foreach ($m in $dtMatches) {
			$dtName = $m.Groups[1].Value
			$key = "DefinedType.${dtName}"
			if (-not $result.Contains($key)) {
				$result[$key] = @{ TypeName = "DefinedType"; ObjName = $dtName }
			}
		}
	}
	return @($result.Values)
}

# --- 11g. Merge adopted attributes into existing extension object XML ---
function Merge-AttributesIntoObject {
	param([string]$typeName, [string]$objName, $attrsToAdd)

	$dirName = $childTypeDirMap[$typeName]
	$objFile = Join-Path (Join-Path $extDir $dirName) "${objName}.xml"
	if (-not (Test-Path $objFile)) {
		Warn "Cannot merge attributes: $objFile not found"
		return
	}

	$objDoc = New-Object System.Xml.XmlDocument
	$objDoc.PreserveWhitespace = $true
	$objDoc.Load($objFile)

	$objNs = New-Object System.Xml.XmlNamespaceManager($objDoc.NameTable)
	$objNs.AddNamespace("md", $script:mdNs)

	$objEl = $null
	foreach ($c in $objDoc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $objEl = $c; break }
	}
	if (-not $objEl) { Warn "No type element in $objFile"; return }

	$childObjs = $objEl.SelectSingleNode("md:ChildObjects", $objNs)
	if (-not $childObjs) {
		$childObjs = $objDoc.CreateElement("ChildObjects", $script:mdNs)
		$objEl.AppendChild($objDoc.CreateWhitespace("`r`n`t`t")) | Out-Null
		$objEl.AppendChild($childObjs) | Out-Null
		$objEl.AppendChild($objDoc.CreateWhitespace("`r`n`t")) | Out-Null
	}

	# Collect existing attribute names for dedup
	$existingNames = @{}
	foreach ($c in $childObjs.ChildNodes) {
		if ($c.NodeType -ne 'Element' -or $c.LocalName -ne 'Attribute') { continue }
		$nameNode = $c.SelectSingleNode("md:Properties/md:Name", $objNs)
		if ($nameNode) { $existingNames[$nameNode.InnerText] = $true }
	}

	$added = 0
	foreach ($attr in $attrsToAdd) {
		if ($existingNames.ContainsKey($attr.Name)) { continue }
		$added++
	}

	if ($added -gt 0) {
		# Build all adopted attributes as text and do string-level insertion
		$allAttrXml = ""
		foreach ($attr in $attrsToAdd) {
			if ($existingNames.ContainsKey($attr.Name)) { continue }
			$kind = if ($attr.Kind) { $attr.Kind } else { "Attribute" }
			$allAttrXml += "`r`n" + (Build-AdoptedAttributeXml $attr.Name $attr.Uuid $attr.TypeXml "`t`t`t" $kind)
		}

		# Save via text manipulation to avoid namespace issues with InnerXml
		# Стиль исходника снимаем ДО записи: правка чужого файла наследует его BOM/EOL/заголовок
		# (#44/#46/#47), новый файл получает канон выгрузки. Зеркало _detect_xml_style в py-порту.
		$style3 = Detect-XmlStyle $objFile
		$settings3 = New-Object System.Xml.XmlWriterSettings
		$settings3.Encoding = New-Object System.Text.UTF8Encoding($true)
		$settings3.Indent = $false
		$settings3.NewLineHandling = [System.Xml.NewLineHandling]::None
		$memStream3 = New-Object System.IO.MemoryStream
		$writer3 = [System.Xml.XmlWriter]::Create($memStream3, $settings3)
		$objDoc.Save($writer3)
		$writer3.Flush(); $writer3.Close()
		$text3 = [System.Text.Encoding]::UTF8.GetString($memStream3.ToArray())
		$memStream3.Close()
		# Самозакрытый элемент раскрывается текстом, а не пробельным узлом в DOM: тот давал
		# лишнюю строку с табуляцией перед первым <Attribute> (у Конфигуратора пустых строк нет).
		# Стоит ДО Finalize-XmlText, чтобы схлопывание пустых тегов накрыло и вставленные реквизиты.
		$text3 = Insert-IntoOwnChildObjects $text3 $allAttrXml
		$text3 = Finalize-XmlText $text3 $style3
		$writeBom3 = ($null -eq $style3) -or $style3.bom
		[System.IO.File]::WriteAllText($objFile, $text3, (New-Object System.Text.UTF8Encoding($writeBom3)))
		Info "  Merged $added attribute(s) into: $objFile"
	}
}

# --- 11h. Borrow-MainAttribute orchestrator ---
# Ссылочные типы → объекты-оболочки в расширении (кто уже заимствован — пропускается)
function Borrow-ReferenceTypeShells {
	param([string[]]$typeXmls)

	$encBom = New-Object System.Text.UTF8Encoding($true)
	$refTypes = Collect-ReferenceTypes $typeXmls
	Info "  Reference types to borrow: $($refTypes.Count)"

	foreach ($rt in $refTypes) {
		if (-not $childTypeDirMap.ContainsKey($rt.TypeName)) {
			Warn "  Unknown reference type: $($rt.TypeName).$($rt.ObjName)"
			continue
		}
		if (Test-ObjectBorrowed $rt.TypeName $rt.ObjName) {
			Info "  Already borrowed: $($rt.TypeName).$($rt.ObjName)"
			continue
		}
		$rtSrcFile = Join-Path (Join-Path $cfgDir $childTypeDirMap[$rt.TypeName]) "$($rt.ObjName).xml"
		if (-not (Test-Path $rtSrcFile)) {
			Warn "  Source not found: $($rt.TypeName).$($rt.ObjName)"
			continue
		}
		$src = Read-SourceObject $rt.TypeName $rt.ObjName
		$borrowedXml = Build-BorrowedObjectXml $rt.TypeName $rt.ObjName $src.Uuid $src.Properties
		$targetDir = Join-Path $extDir $childTypeDirMap[$rt.TypeName]
		if (-not (Test-Path $targetDir)) {
			New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
		}
		$targetFile = Join-Path $targetDir "$($rt.ObjName).xml"
		[System.IO.File]::WriteAllText($targetFile, $borrowedXml, $encBom)
		Add-ToChildObjects $rt.TypeName $rt.ObjName
		$script:borrowedFiles += $targetFile
		Info "  Auto-borrowed: $($rt.TypeName).$($rt.ObjName)"
	}
}

# Владелец общей формы — из ТИПА её основного реквизита (эталон УТ CommonMain):
# <Вид>Object.Имя / <Вид>RecordManager.Имя → объект; DynamicList → объект из <MainTable>;
# ConstantsSet → константы по путям формы. Примитив, тип без имени (ReportObject — любой отчёт),
# список без MainTable → владельца нет: в расширение идёт только сам реквизит формы.
$script:commonFormOwnerKinds = [ordered]@{
	'CatalogObject'='Catalog'; 'DocumentObject'='Document'; 'DataProcessorObject'='DataProcessor'; 'ReportObject'='Report'
	'ChartOfCharacteristicTypesObject'='ChartOfCharacteristicTypes'; 'ChartOfAccountsObject'='ChartOfAccounts'
	'ChartOfCalculationTypesObject'='ChartOfCalculationTypes'; 'ExchangePlanObject'='ExchangePlan'
	'BusinessProcessObject'='BusinessProcess'; 'TaskObject'='Task'
	'InformationRegisterRecordManager'='InformationRegister'; 'InformationRegisterRecordSet'='InformationRegister'
	'AccumulationRegisterRecordSet'='AccumulationRegister'
}
function Resolve-CommonFormOwner {
	param($formEl)

	$mainAttr = $formEl.SelectSingleNode("*[local-name()='Attributes']/*[local-name()='Attribute'][*[local-name()='MainAttribute']='true']")
	if (-not $mainAttr) { return $null }
	$typeNode = $mainAttr.SelectSingleNode("*[local-name()='Type']/*[local-name()='Type']")
	$typeText = if ($typeNode) { $typeNode.InnerText.Trim() } else { "" }
	if ($typeText -ceq 'cfg:ConstantsSet') { return @{ Kind = 'Constants'; MainName = $mainAttr.GetAttribute("name") } }
	$m = [regex]::Match($typeText, '^cfg:(\w+)\.(\w+)$')
	if ($m.Success -and $script:commonFormOwnerKinds.Contains($m.Groups[1].Value)) {
		return @{ Kind = 'Object'; TypeName = $script:commonFormOwnerKinds[$m.Groups[1].Value]; ObjName = $m.Groups[2].Value }
	}
	if ($typeText -ceq 'cfg:DynamicList') {
		$mt = $mainAttr.SelectSingleNode(".//*[local-name()='MainTable']")
		if ($mt) {
			$mtm = [regex]::Match($mt.InnerText.Trim(), '^(\w+)\.(\w+)$')
			if ($mtm.Success -and $childTypeDirMap.ContainsKey($mtm.Groups[1].Value)) {
				return @{ Kind = 'Object'; TypeName = $mtm.Groups[1].Value; ObjName = $mtm.Groups[2].Value }
			}
		}
	}
	return $null
}

# Набор констант как основной реквизит общей формы: заимствуются константы, пути на которые есть
# в форме (<Реквизит>.<Константа>), — с типом как в источнике; их ссылочные типы — оболочками
# (эталон УТ CommonMain: НастройкаПереводаТекста → две константы + перечисление из типа).
function Borrow-FormConstants {
	param([string]$srcFormXmlPath, [string]$mainName)

	Info "Borrowing constants for main attribute ${mainName} (ConstantsSet)..."
	$names = (Collect-FormDataPaths $srcFormXmlPath $mainName).FirstLevel
	$encBom = New-Object System.Text.UTF8Encoding($true)
	$typeXmls = @()
	foreach ($cName in @($names.Keys)) {
		$cSrcFile = Join-Path (Join-Path $cfgDir "Constants") "${cName}.xml"
		if (-not (Test-Path $cSrcFile)) { continue }
		$cDoc = New-Object System.Xml.XmlDocument
		# С пробелами: вложенные отступы типа в источнике — ровно та же глубина, что в расширении
		$cDoc.PreserveWhitespace = $true
		$cDoc.Load($cSrcFile)
		$cTypeNode = $cDoc.SelectSingleNode("//*[local-name()='Constant']/*[local-name()='Properties']/*[local-name()='Type']")
		$cTypeXml = if ($cTypeNode) { ([regex]::Replace($cTypeNode.OuterXml, '\s+xmlns(?::\w+)?="[^"]*"', '') -replace "`r?`n", "`r`n") } else { "" }
		if ($cTypeXml) { $typeXmls += $cTypeXml }
		# Тип — последним свойством, после ExtendedConfigurationObject (как у Конфигуратора)
		$addType = {
			param([string]$xml)
			([regex]'(?<ind>[ \t]*)<ExtendedConfigurationObject>[^<]*</ExtendedConfigurationObject>').Replace($xml, {
				param($mm) $mm.Value + "`r`n" + $mm.Groups['ind'].Value + $cTypeXml
			}, 1)
		}
		if (Test-ObjectBorrowed "Constant" $cName) {
			# Заимствованная раньше оболочкой (-Object Constant.X) — без типа: дописываем, как при
			# слиянии реквизитов в уже заимствованный объект
			$extCFile = Join-Path (Join-Path $extDir "Constants") "${cName}.xml"
			$extCText = [System.IO.File]::ReadAllText($extCFile, $encBom)
			if ($cTypeXml -and $extCText -cnotmatch '<Type>') {
				[System.IO.File]::WriteAllText($extCFile, (& $addType $extCText), $encBom)
				Info "  Added type: Constant.${cName}"
			} else {
				Info "  Already borrowed: Constant.${cName}"
			}
			continue
		}
		$src = Read-SourceObject "Constant" $cName
		$borrowedXml = Build-BorrowedObjectXml "Constant" $cName $src.Uuid $src.Properties
		if ($cTypeXml) { $borrowedXml = & $addType $borrowedXml }
		$targetDir = Join-Path $extDir "Constants"
		if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
		$targetFile = Join-Path $targetDir "${cName}.xml"
		[System.IO.File]::WriteAllText($targetFile, $borrowedXml, $encBom)
		Add-ToChildObjects "Constant" $cName
		$script:borrowedFiles += $targetFile
		Info "  Borrowed: Constant.${cName}"
	}
	Borrow-ReferenceTypeShells $typeXmls
}

function Borrow-MainAttribute {
	param([string]$typeName, [string]$objName, [string]$formName, [string]$mode, [string]$srcFormXmlPath = "")

	$dirName = $childTypeDirMap[$typeName]
	Info "Borrowing main attribute for ${typeName}.${objName} (mode: $mode)..."
	# Путь к исходной форме: у общей формы его передают явно (владелец выведен из типа реквизита)
	if (-not $srcFormXmlPath) {
		$srcFormXmlPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $cfgDir $dirName) $objName) "Forms") $formName) "Ext/Form.xml"
	}

	# Step 1: Collect DataPaths (Form mode) or take all (All mode)
	$firstLevelNames = $null
	$deepPaths = @()
	if ($mode -eq "Form") {
		if (-not (Test-Path $srcFormXmlPath)) {
			Write-Error "Source Form.xml not found: $srcFormXmlPath"
			exit 1
		}
		# Имя основного реквизита исходной формы — корень путей, которые надо собрать
		$dpDoc = New-Object System.Xml.XmlDocument
		$dpDoc.PreserveWhitespace = $true
		$dpDoc.Load($srcFormXmlPath)
		$dpInfo = Get-MainAttributeInfo $dpDoc.DocumentElement '\s+xmlns(?::\w+)?="[^"]*"'
		if (-not $dpInfo) {
			Warn "  У формы нет основного реквизита — заимствовать нечего"
			return
		}
		$dp = Collect-FormDataPaths $srcFormXmlPath $dpInfo.Name
		$firstLevelNames = $dp.FirstLevel
		$deepPaths = $dp.DeepPaths
		Info "  Collected $($firstLevelNames.Count) first-level DataPath references, $($deepPaths.Count) deep paths"
	} else {
		Info "  Mode All: borrowing all attributes and tabular sections"
	}

	# Step 2: Resolve source attributes
	$resolved = Resolve-SourceAttributes $typeName $objName $firstLevelNames
	$srcAttrs = $resolved.Attributes
	$srcTS = $resolved.TabularSections
	$extraProps = $resolved.ExtraProps
	Info "  Resolved: $($srcAttrs.Count) attributes, $($srcTS.Count) tabular section(s)"

	# Identify which FirstLevel names are TabularSections (for deep path filtering)
	$tsNames = @{}
	foreach ($ts in $srcTS) { $tsNames[$ts.Name] = $true }

	# Step 3: Build the adopted content and insert into main object XML
	$objFile = Join-Path (Join-Path $extDir $dirName) "${objName}.xml"

	# Read existing object XML (needed for dedup + enrichment)
	$objContent = [System.IO.File]::ReadAllText($objFile, (New-Object System.Text.UTF8Encoding($true)))

	# Dedup: skip attributes/TS already present in object's ChildObjects (idempotent re-borrow)
	$existingChildNames = Get-OwnChildObjectNames $objFile
	$insertAttrs = @($srcAttrs | Where-Object { -not $existingChildNames.ContainsKey($_.Name) })
	$insertTS = @($srcTS | Where-Object { -not $existingChildNames.ContainsKey($_.Name) })

	# Generate full object XML with attributes and TS
	$contentSb = New-Object System.Text.StringBuilder
	foreach ($attr in $insertAttrs) {
		$attrKind = if ($attr.Kind) { $attr.Kind } else { "Attribute" }
		$attrXml = Build-AdoptedAttributeXml $attr.Name $attr.Uuid $attr.TypeXml "`t`t`t" $attrKind
		$contentSb.AppendLine($attrXml) | Out-Null
	}
	foreach ($ts in $insertTS) {
		$tsXml = Build-AdoptedTabularSectionXml $ts.Name $ts.Uuid $ts.GeneratedTypes $ts.Attributes "`t`t`t"
		$contentSb.AppendLine($tsXml) | Out-Null
	}
	$adoptedContent = $contentSb.ToString().TrimEnd()

	# Inject extra properties into the object's OWN Properties only — idempotent and anchored to the
	# first ExtendedConfigurationObject (the object's). On re-borrow, adopted attributes each have their
	# own ExtendedConfigurationObject; a global replace would push object props inside every <Attribute>.
	if ($extraProps.Count -gt 0) {
		$objPropsBlock = ""
		if ($objContent -match '(?s)<Properties>(.*?)</Properties>') { $objPropsBlock = $Matches[1] }
		$propsSb = New-Object System.Text.StringBuilder
		foreach ($pName in $extraProps.Keys) {
			if ($objPropsBlock -match "<$pName>") { continue }
			$propsSb.Append("`r`n`t`t`t<${pName}>$($extraProps[$pName])</${pName}>") | Out-Null
		}
		if ($propsSb.Length -gt 0) {
			$objContent = ([regex]'</ExtendedConfigurationObject>').Replace($objContent, "</ExtendedConfigurationObject>$($propsSb.ToString())", 1)
		}
	}

	# Добавить заимствованное содержимое в ChildObjects объекта (там уже может лежать <Form>)
	if ($adoptedContent) {
		$objContent = Insert-IntoOwnChildObjects $objContent "`r`n${adoptedContent}"
	}

	$encBom = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($objFile, $objContent, $encBom)
	Info "  Enriched object: $objFile"

	# Step 4: Collect all reference types and borrow as shells
	$allTypeXmls = @()
	foreach ($a in $srcAttrs) { $allTypeXmls += $a.TypeXml }
	foreach ($ts in $srcTS) {
		foreach ($tsa in $ts.Attributes) { $allTypeXmls += $tsa.TypeXml }
	}
	# Типы из <Columns> основного реквизита формы: колонку мы переносим (Borrow-Form), значит и её
	# тип должен быть заимствован — иначе колонка ссылается на DefinedType/справочник, которого в
	# расширении нет. Конфигуратор поступает так же (эталон: DefinedTypes/Артикул при заимствовании
	# формы заказа поставщику).
	$srcFormForCols = $srcFormXmlPath
	if (Test-Path $srcFormForCols) {
		$colsDoc = New-Object System.Xml.XmlDocument
		$colsDoc.PreserveWhitespace = $true
		$colsDoc.Load($srcFormForCols)
		$colsInfo = Get-MainAttributeInfo $colsDoc.DocumentElement '\s+xmlns(?::\w+)?="[^"]*"'
		if ($colsInfo) {
			foreach ($m in [regex]::Matches($colsInfo.Xml, '(?s)<Columns>.*?</Columns>')) { $allTypeXmls += $m.Value }
		}
	}

	Borrow-ReferenceTypeShells $allTypeXmls

	# Step 5: Handle deep paths (Form mode only)
	if ($mode -eq "Form" -and $deepPaths.Count -gt 0) {
		# Top-level ref deep paths: Объект.<Ref>.<Sub> — borrow the ref attribute's catalog with the sub-attribute
		$deepByAttr = @{}
		foreach ($dp in $deepPaths) {
			if ($tsNames.ContainsKey($dp.ObjectAttr)) { continue }
			if (-not $deepByAttr.ContainsKey($dp.ObjectAttr)) { $deepByAttr[$dp.ObjectAttr] = @() }
			if ($deepByAttr[$dp.ObjectAttr] -notcontains $dp.SubAttr) { $deepByAttr[$dp.ObjectAttr] += $dp.SubAttr }
		}
		if ($deepByAttr.Count -gt 0) {
			Info "  Processing $($deepByAttr.Count) deep path attribute(s)..."
			foreach ($attrName in $deepByAttr.Keys) {
				$attrInfo = $srcAttrs | Where-Object { $_.Name -eq $attrName } | Select-Object -First 1
				if (-not $attrInfo) { continue }
				$catMatch = [regex]::Match($attrInfo.TypeXml, 'cfg:(\w+)Ref\.(\w+)')
				if (-not $catMatch.Success) { continue }
				Borrow-DeepTargetAttrs $catMatch.Groups[1].Value $catMatch.Groups[2].Value $deepByAttr[$attrName]
			}
		}

		# Tabular-section deep paths: Объект.<ТЧ>.<Колонка>.<Sub> — borrow the column's catalog with the sub-attribute
		$tsDeepByCol = @{}
		foreach ($dp in $deepPaths) {
			if (-not $tsNames.ContainsKey($dp.ObjectAttr)) { continue }
			if (-not $dp.SubSubAttr) { continue }
			if ($script:standardFields -contains $dp.SubSubAttr) { continue }
			$k = "$($dp.ObjectAttr)|$($dp.SubAttr)"
			if (-not $tsDeepByCol.ContainsKey($k)) { $tsDeepByCol[$k] = @() }
			if ($tsDeepByCol[$k] -notcontains $dp.SubSubAttr) { $tsDeepByCol[$k] += $dp.SubSubAttr }
		}
		if ($tsDeepByCol.Count -gt 0) {
			Info "  Processing $($tsDeepByCol.Count) tabular-section deep path(s)..."
			foreach ($k in $tsDeepByCol.Keys) {
				$parts = $k.Split("|")
				$tsName = $parts[0]; $colName = $parts[1]
				$tsInfo = $srcTS | Where-Object { $_.Name -eq $tsName } | Select-Object -First 1
				if (-not $tsInfo) { continue }
				$colInfo = $tsInfo.Attributes | Where-Object { $_.Name -eq $colName } | Select-Object -First 1
				if (-not $colInfo) { continue }
				$catMatch = [regex]::Match($colInfo.TypeXml, 'cfg:(\w+)Ref\.(\w+)')
				if (-not $catMatch.Success) { continue }
				Borrow-DeepTargetAttrs $catMatch.Groups[1].Value $catMatch.Groups[2].Value $tsDeepByCol[$k]
			}
		}
	}

	Info "  Main attribute borrowing complete"
}

# --- 11i. Helper: borrow a deep-path target catalog together with the referenced sub-attributes ---
# Used for both Объект.<Ref>.<Sub> (top-level ref attr) and Объект.<ТЧ>.<Колонка>.<Sub> (tabular-section
# column ref). Mirrors Designer: the referenced catalog is adopted WITH the sub-attributes the form shows,
# otherwise the platform rejects the deep DataPath ("Неверный путь к данным").
function Borrow-DeepTargetAttrs {
	param([string]$targetTypeName, [string]$targetObjName, $subAttrNames)

	$encBomLocal = New-Object System.Text.UTF8Encoding($true)

	# Ensure target is borrowed (shell)
	if (-not (Test-ObjectBorrowed $targetTypeName $targetObjName)) {
		$tSrc = Read-SourceObject $targetTypeName $targetObjName
		$tBorrowedXml = Build-BorrowedObjectXml $targetTypeName $targetObjName $tSrc.Uuid $tSrc.Properties
		$tTargetDir = Join-Path $extDir $childTypeDirMap[$targetTypeName]
		if (-not (Test-Path $tTargetDir)) { New-Item -ItemType Directory -Path $tTargetDir -Force | Out-Null }
		$tTargetFile = Join-Path $tTargetDir "${targetObjName}.xml"
		[System.IO.File]::WriteAllText($tTargetFile, $tBorrowedXml, $encBomLocal)
		Add-ToChildObjects $targetTypeName $targetObjName
		$script:borrowedFiles += $tTargetFile
		Info "  Auto-borrowed for deep path: ${targetTypeName}.${targetObjName}"
	}

	# Resolve sub-attributes in target catalog and merge them in
	$subNames = @{}
	foreach ($sn in $subAttrNames) { $subNames[$sn] = $true }
	$subResolved = Resolve-SourceAttributes $targetTypeName $targetObjName $subNames
	if ($subResolved.Attributes.Count -gt 0) {
		Merge-AttributesIntoObject $targetTypeName $targetObjName $subResolved.Attributes

		# Borrow ref types referenced by the sub-attributes
		$subTypeXmls = @()
		foreach ($sa in $subResolved.Attributes) { $subTypeXmls += $sa.TypeXml }
		$subRefTypes = Collect-ReferenceTypes $subTypeXmls
		foreach ($srt in $subRefTypes) {
			if (-not $childTypeDirMap.ContainsKey($srt.TypeName)) { continue }
			if (Test-ObjectBorrowed $srt.TypeName $srt.ObjName) { continue }
			$sSrcFile = Join-Path (Join-Path $cfgDir $childTypeDirMap[$srt.TypeName]) "$($srt.ObjName).xml"
			if (-not (Test-Path $sSrcFile)) { continue }
			$sSrc = Read-SourceObject $srt.TypeName $srt.ObjName
			$sBorrowedXml = Build-BorrowedObjectXml $srt.TypeName $srt.ObjName $sSrc.Uuid $sSrc.Properties
			$sTargetDir = Join-Path $extDir $childTypeDirMap[$srt.TypeName]
			if (-not (Test-Path $sTargetDir)) { New-Item -ItemType Directory -Path $sTargetDir -Force | Out-Null }
			$sTargetFile = Join-Path $sTargetDir "$($srt.ObjName).xml"
			[System.IO.File]::WriteAllText($sTargetFile, $sBorrowedXml, $encBomLocal)
			Add-ToChildObjects $srt.TypeName $srt.ObjName
			$script:borrowedFiles += $sTargetFile
			Info "  Auto-borrowed (deep): $($srt.TypeName).$($srt.ObjName)"
		}
	}
}

# --- 12. Helper: build borrowed object XML ---
function Build-BorrowedObjectXml {
	param(
		[string]$typeName,
		[string]$objName,
		[string]$sourceUuid,
		[hashtable]$sourceProps
	)

	$newUuid = [guid]::NewGuid().ToString()
	$internalInfoXml = Build-InternalInfoXml $typeName $objName "`t`t"

	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("<?xml version=`"1.0`" encoding=`"UTF-8`"?>") | Out-Null
	$sb.AppendLine("<MetaDataObject $($script:xmlnsDecl) version=`"$($script:formatVersion)`">") | Out-Null
	$sb.AppendLine("`t<${typeName} uuid=`"${newUuid}`">") | Out-Null

	# InternalInfo
	$sb.AppendLine($internalInfoXml) | Out-Null

	# Properties
	$sb.AppendLine("`t`t<Properties>") | Out-Null
	$sb.AppendLine("`t`t`t<ObjectBelonging>Adopted</ObjectBelonging>") | Out-Null
	$sb.AppendLine("`t`t`t<Name>${objName}</Name>") | Out-Null
	$sb.AppendLine("`t`t`t<Comment/>") | Out-Null
	$sb.AppendLine("`t`t`t<ExtendedConfigurationObject>${sourceUuid}</ExtendedConfigurationObject>") | Out-Null

	# CommonModule: extra properties from source
	if ($typeName -eq "CommonModule") {
		foreach ($propName in $commonModuleProps) {
			$propVal = "false"
			if ($sourceProps.ContainsKey($propName)) {
				$propVal = $sourceProps[$propName]
			}
			$sb.AppendLine("`t`t`t<${propName}>${propVal}</${propName}>") | Out-Null
		}
	}

	# DefinedType: emit the carried <Type> definition (needed for the alias to resolve, e.g. totals)
	if ($typeName -eq "DefinedType" -and $sourceProps.ContainsKey("__TypeXml")) {
		$sb.AppendLine("`t`t`t$($sourceProps['__TypeXml'])") | Out-Null
	}

	# Свойства, от которых зависят стандартные поля (см. $script:typeGateProps / $script:typesWithOwners)
	foreach ($gp in @($script:typeGateProps[$typeName])) {
		if ($gp -and $sourceProps.ContainsKey($gp)) {
			$sb.AppendLine("`t`t`t<${gp}>$($sourceProps[$gp])</${gp}>") | Out-Null
		}
	}
	if ($sourceProps.ContainsKey("__OwnersXml")) {
		$sb.AppendLine("`t`t`t$($sourceProps['__OwnersXml'])") | Out-Null
	}

	$sb.AppendLine("`t`t</Properties>") | Out-Null

	# ChildObjects (for types that need it)
	if ($sourceProps["__HasChildObjects"] -or ($typesWithChildObjects -contains $typeName)) {
		$sb.AppendLine("`t`t<ChildObjects/>") | Out-Null
	}

	$sb.AppendLine("`t</${typeName}>") | Out-Null
	$sb.Append("</MetaDataObject>") | Out-Null

	return $sb.ToString()
}

# --- 13. Helper: add object to extension ChildObjects ---
# Стиль существующего файла для round-trip-сохранения: BOM / EOL / регистр encoding /
# финальный перенос. $null → файл новый (сохранить текущее поведение).
# Реестр семьи: tests/skills/check-inline-drift.mjs.
function Detect-XmlStyle([string]$path) {
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	$raw = [System.IO.File]::ReadAllBytes($path)
	$bom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
	$body = if ($bom) { [System.Text.Encoding]::UTF8.GetString($raw, 3, $raw.Length - 3) } else { [System.Text.Encoding]::UTF8.GetString($raw) }
	$head = if ($body.Length -gt 200) { $body.Substring(0, 200) } else { $body }
	$m = [regex]::Match($head, 'encoding="([^"]+)"')
	return @{
		bom = $bom
		crlf = $body.Contains("`r`n")
		enc = $(if ($m.Success) { $m.Groups[1].Value } else { "utf-8" })
		finalNl = $body.EndsWith("`n")
	}
}

# Привести текст XmlWriter к стилю оригинала; для НОВОГО файла ($null) — к канону выгрузки
# Конфигуратора: encoding="UTF-8", CRLF, без перевода строки в конце.
# Реестр семьи: tests/skills/check-inline-drift.mjs.
function Finalize-XmlText([string]$text, $style) {
	if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
	$encDecl = $(if ($style) { $style.enc } else { "UTF-8" })
	$text = $text.Replace('encoding="utf-8"', 'encoding="' + $encDecl + '"')
	# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
	# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
	# поэтому они идут первыми ветками альтернации и возвращаются как есть.
	$text = [regex]::Replace($text, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
	$text = ($text -replace "`r`n", "`n").TrimEnd("`n")
	if ($style -and $style.finalNl) { $text += "`n" }
	if (-not $style -or $style.crlf) { $text = $text -replace "`n", "`r`n" }
	return $text
}

function Find-V8Project([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 20 -and $d; $i++) {
		$pj = Join-Path $d ".v8-project.json"
		if (Test-Path $pj) { return $pj }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return $null
}

# Куда навык ставит новую запись в <ChildObjects> — настройка newObjectPosition.
# databases[].newObjectPosition базы, чей configSrc охватывает каталог родительского XML,
# иначе корневое поле, иначе end. Значения: end — после последнего объекта того же вида
# (так дописывает Конфигуратор); byName — по имени среди объектов того же вида.
# Файл ищем от рабочего каталога вверх, каталог конфигурации — запасной путь: так же
# его ищут support-guard и группа db-*, а скрипт навыка зовут по абсолютному пути, и cwd
# остаётся рабочим каталогом проекта.
# configSrc считается от каталога .v8-project.json, как задокументировано в
# docs/v8-project-guide.md. Реестр семьи: tests/skills/check-inline-drift.mjs.
function Get-NewObjectPosition([string]$cfgDir) {
	try {
		if (-not $cfgDir) { $cfgDir = "." }
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project ([System.IO.Path]::GetFullPath($cfgDir)) }
		if (-not $pj) { return "end" }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$projDir = [System.IO.Path]::GetDirectoryName($pj)
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc -and $db.newObjectPosition) {
					$src = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($projDir, $db.configSrc)).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ("$($db.newObjectPosition)" -eq "byName") { return "byName" }
						return "end"
					}
				}
			}
		}
		if ("$($proj.newObjectPosition)" -eq "byName") { return "byName" }
		return "end"
	} catch { return "end" }
}

# Виды, у которых порядок в дереве несёт смысл: автоматически их не упорядочиваем.
# CommonAttribute — исключение самого стандарта (#std467): у общих реквизитов-разделителей
# порядок в дереве задаёт порядок установки параметров сеанса. Subsystem и CommandGroup:
# пока они не перечислены в <SubsystemsOrder> / <GroupsOrder> файла Ext/CommandInterface.xml,
# порядок дерева задаёт порядок в интерфейсе, а платформа эти списки сама не заводит
# (в выгрузке ACC вне GroupsOrder 15 живых групп из 39). Language исключён из осторожности,
# без замера: языков обычно один-два, и в типовых их порядок не алфавитный.
# Явно названный вид сортируется в любом случае.
# Реестр семьи: tests/skills/check-inline-drift.mjs.
function Test-OrderSensitiveType([string]$typeName) {
	return @("CommonAttribute", "Subsystem", "CommandGroup", "Language") -ccontains $typeName
}

# Порядок имён объектов метаданных, как в дереве Конфигуратора.
# Ключ — пары «ранг+символ»: регистр не учитывается, подчёркивание раньше цифр, цифры раньше
# букв, буквы по кодам (латиница раньше кириллицы), ё на месте е. Культурные таблицы не
# используются — они разные на разных ОС и в разных рантаймах, а так оба порта сравнивают
# одинаково везде. Равные ключи разводит ordinal-сравнение исходных строк.
# Возвращает -1 | 0 | 1. Реестр семьи: tests/skills/check-inline-drift.mjs.
function Compare-MetadataNames([string]$a, [string]$b) {
	$keys = @("", "")
	$names = @($a, $b)
	for ($i = 0; $i -lt 2; $i++) {
		$sb = New-Object System.Text.StringBuilder
		foreach ($ch in $names[$i].ToLowerInvariant().ToCharArray()) {
			if ($ch -eq [char]0x0451) { $ch = [char]0x0435 }
			if ([char]::IsDigit($ch)) { [void]$sb.Append('1') }
			elseif ([char]::IsLetter($ch)) { [void]$sb.Append('2') }
			else { [void]$sb.Append('0') }
			[void]$sb.Append($ch)
		}
		$keys[$i] = $sb.ToString()
	}
	$r = [string]::CompareOrdinal($keys[0], $keys[1])
	if ($r -eq 0) { $r = [string]::CompareOrdinal($a, $b) }
	if ($r -lt 0) { return -1 }
	if ($r -gt 0) { return 1 }
	return 0
}

function Add-ToChildObjects {
	param([string]$typeName, [string]$objName)

	$cfgIndent = Get-ChildIndent $script:cfgEl

	# Expand self-closing ChildObjects if needed
	if (-not $script:childObjsEl.HasChildNodes -or $script:childObjsEl.IsEmpty) {
		Expand-SelfClosingElement $script:childObjsEl $cfgIndent
	}
	$childIndent = Get-ChildIndent $script:childObjsEl

	$typeIdx = $script:typeOrder.IndexOf($typeName)
	if ($typeIdx -lt 0) {
		Write-Error "Unknown type '$typeName' for ChildObjects ordering"
		exit 1
	}

	# Dedup check
	foreach ($child in $script:childObjsEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $typeName -and $child.InnerText -eq $objName) {
			Warn "Already in ChildObjects: ${typeName}.${objName}"
			return
		}
	}

	# Место вставки. Вид — по $script:typeOrder; внутри вида — по newObjectPosition: end
	# (по умолчанию) кладёт после последнего объекта того же вида, byName — по имени. Так же
	# заимствует Конфигуратор: в боевых выгрузках расширений ChildObjects не отсортирован.
	# Subsystem по имени не упорядочиваем никогда: порядок подсистем в дереве задаёт порядок
	# разделов в панели.
	$byName = (-not (Test-OrderSensitiveType $typeName) -and (Get-NewObjectPosition $extDir) -eq "byName")
	$insertBefore = $null
	$lastSameType = $null

	foreach ($child in $script:childObjsEl.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childTypeIdx = $script:typeOrder.IndexOf($child.LocalName)
		if ($childTypeIdx -lt 0) { continue }

		if ($child.LocalName -eq $typeName) {
			if ($byName -and -not $insertBefore -and (Compare-MetadataNames $child.InnerText $objName) -gt 0) {
				$insertBefore = $child
			}
			$lastSameType = $child
		} elseif ($childTypeIdx -gt $typeIdx -and -not $insertBefore) {
			# First element of a later type -- insert before it
			$insertBefore = $child
		}
	}

	# Create element
	$newEl = $script:xmlDoc.CreateElement($typeName, $script:mdNs)
	$newEl.InnerText = $objName

	if ($insertBefore) {
		Insert-BeforeElement $script:childObjsEl $newEl $insertBefore $childIndent
	} else {
		Insert-BeforeElement $script:childObjsEl $newEl $null $childIndent
	}

	Info "Added to ChildObjects: ${typeName}.${objName}"
}

# --- 14. Process each item ---
$script:borrowedFiles = @()
$borrowedCount = 0

foreach ($item in $items) {
	$dotIdx = $item.IndexOf(".")
	if ($dotIdx -lt 1) {
		Write-Error "Invalid format '${item}', expected 'Type.Name' or 'Type.Name.Form.FormName'"
		exit 1
	}
	$typeName = $item.Substring(0, $dotIdx)
	$remainder = $item.Substring($dotIdx + 1)

	# Resolve Russian synonym to English type name
	if ($synonymMap.ContainsKey($typeName)) { $typeName = $synonymMap[$typeName] }

	if (-not $childTypeDirMap.ContainsKey($typeName)) {
		Write-Error "Unknown type '${typeName}'"
		exit 1
	}

	# Check for .Form. pattern: Type.ObjName.Form.FormName
	$formName = $null
	$formIdx = $remainder.IndexOf(".Form.")
	if ($formIdx -gt 0) {
		$objName = $remainder.Substring(0, $formIdx)
		$formName = $remainder.Substring($formIdx + 6) # skip ".Form."
	} else {
		$objName = $remainder
	}
	# Общая форма — сама форма: «CommonForm.X» заимствуется вместе с содержимым, владельца у неё нет
	$isCommonForm = $typeName -eq 'CommonForm'
	if ($isCommonForm) {
		if ($formName) {
			Write-Error "Invalid format '${item}': общая форма задаётся как 'CommonForm.Имя'"
			exit 1
		}
		$formName = $objName
	}

	$dirName = $childTypeDirMap[$typeName]

	if ($formName) {
		# --- Form borrowing ---
		if ($isCommonForm) { Info "Borrowing common form ${typeName}.${objName}..." }
		else { Info "Borrowing form ${typeName}.${objName}.Form.${formName}..." }

		# Auto-borrow parent object if not yet borrowed
		if (-not $isCommonForm -and -not (Test-ObjectBorrowed $typeName $objName)) {
			Info "  Parent object ${typeName}.${objName} not yet borrowed — borrowing first..."

			$src = Read-SourceObject $typeName $objName
			Info "  Source UUID: $($src.Uuid)"
			$borrowedXml = Build-BorrowedObjectXml $typeName $objName $src.Uuid $src.Properties

			$targetDir = Join-Path $extDir $dirName
			if (-not (Test-Path $targetDir)) {
				New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
			}
			$targetFile = Join-Path $targetDir "${objName}.xml"
			$enc = New-Object System.Text.UTF8Encoding($true)
			[System.IO.File]::WriteAllText($targetFile, $borrowedXml, $enc)
			Info "  Created: $targetFile"

			Add-ToChildObjects $typeName $objName
			$script:borrowedFiles += $targetFile
		}

		# Borrow the form
		$hasBMA = [bool]$BorrowMainAttribute
		$formFiles = Borrow-Form $typeName $objName $formName -BorrowMainAttr:$hasBMA
		$script:borrowedFiles += $formFiles
		# Замер на 8.3.26: платформа помечает форму расширенной сразу при заимствовании,
		# даже если элементы не менялись. Флаг живёт в метаданных формы, не у владельца.
		Set-PropertyStateFlag $formFiles[0] "Form" $script:formatVersion
		$borrowedCount++

		# Borrow main attribute if requested
		if ($hasBMA -and $isCommonForm) {
			# У общей формы владельца нет — он выводится из типа основного реквизита
			$cfSrcFormXmlPath = Join-Path (Join-Path (Join-Path $cfgDir $dirName) $objName) "Ext/Form.xml"
			$cfDoc = New-Object System.Xml.XmlDocument
			$cfDoc.PreserveWhitespace = $true
			$cfDoc.Load($cfSrcFormXmlPath)
			$cfOwner = Resolve-CommonFormOwner $cfDoc.DocumentElement
			if (-not $cfOwner) {
				Info "  Основной реквизит общей формы не ссылается на объект — заимствуется только сам реквизит"
			} elseif ($cfOwner.Kind -eq 'Constants') {
				Borrow-FormConstants $cfSrcFormXmlPath $cfOwner.MainName
			} else {
				if (-not (Test-ObjectBorrowed $cfOwner.TypeName $cfOwner.ObjName)) {
					$src = Read-SourceObject $cfOwner.TypeName $cfOwner.ObjName
					$borrowedXml = Build-BorrowedObjectXml $cfOwner.TypeName $cfOwner.ObjName $src.Uuid $src.Properties
					$ownerDir = Join-Path $extDir $childTypeDirMap[$cfOwner.TypeName]
					if (-not (Test-Path $ownerDir)) { New-Item -ItemType Directory -Path $ownerDir -Force | Out-Null }
					$ownerFile = Join-Path $ownerDir "$($cfOwner.ObjName).xml"
					[System.IO.File]::WriteAllText($ownerFile, $borrowedXml, (New-Object System.Text.UTF8Encoding($true)))
					Add-ToChildObjects $cfOwner.TypeName $cfOwner.ObjName
					$script:borrowedFiles += $ownerFile
					Info "  Auto-borrowed: $($cfOwner.TypeName).$($cfOwner.ObjName)"
				}
				Borrow-MainAttribute $cfOwner.TypeName $cfOwner.ObjName $null $BorrowMainAttribute $cfSrcFormXmlPath
			}
		} elseif ($hasBMA) {
			Borrow-MainAttribute $typeName $objName $formName $BorrowMainAttribute
		}
	} else {
		# --- Object borrowing (existing logic) ---
		$targetDir = Join-Path $extDir $dirName
		$targetFile = Join-Path $targetDir "${objName}.xml"

		# Уже заимствованный объект НЕ переписываем: в его XML лежат собственные реквизиты
		# расширения, заимствованные подобъекты и состояния, которые из источника не выводятся.
		# Повторный вызов — законный способ доделать модуль (-Module), а не переиздать заготовку.
		if (Test-ObjectBorrowed $typeName $objName) {
			Info "Already borrowed: ${typeName}.${objName} — XML сохранён без изменений"
		} else {
			Info "Borrowing ${typeName}.${objName}..."

			$src = Read-SourceObject $typeName $objName
			Info "  Source UUID: $($src.Uuid)"

			$borrowedXml = Build-BorrowedObjectXml $typeName $objName $src.Uuid $src.Properties

			if (-not (Test-Path $targetDir)) {
				New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
			}

			$enc = New-Object System.Text.UTF8Encoding($true)
			[System.IO.File]::WriteAllText($targetFile, $borrowedXml, $enc)
			Info "  Created: $targetFile"
		}

		Add-ToChildObjects $typeName $objName

		$script:borrowedFiles += $targetFile
		foreach ($kind in (Resolve-ModuleKinds $typeName)) {
			$script:borrowedFiles += (New-BorrowedModuleFile $typeName $objName $kind)
		}
		$borrowedCount++
	}
}

# --- 14b. Владельцы заимствованных справочников ---
# Ссылка в <Owners> должна вести на объект, который в расширении есть: иначе платформа падает при
# загрузке (проверено — access violation, не сообщение об ошибке). Конфигуратор владельца
# заимствует (эталон Issue66Example7_1: вместе со справочником перенесён и его ПВХ-владелец).
# Проход общий и повторяется, пока находятся новые: у владельца может быть свой владелец.
$ownerPass = 0
while ($true) {
	$ownerPass++
	if ($ownerPass -gt 10) { break }
	$newOwners = @()
	foreach ($shell in (Get-ChildItem -Path $extDir -Filter "*.xml" -Recurse -File)) {
		$shellText = [System.IO.File]::ReadAllText($shell.FullName)
		if ($shellText -notmatch '<Owners>') { continue }
		foreach ($om in [regex]::Matches($shellText, '<xr:Item[^>]*>(\w+)\.(\w+)</xr:Item>')) {
			$oType = $om.Groups[1].Value; $oName = $om.Groups[2].Value
			if (-not $childTypeDirMap.ContainsKey($oType)) { continue }
			if (Test-ObjectBorrowed $oType $oName) { continue }
			if ($newOwners | Where-Object { $_.T -eq $oType -and $_.N -eq $oName }) { continue }
			$newOwners += @{ T = $oType; N = $oName }
		}
	}
	if ($newOwners.Count -eq 0) { break }
	foreach ($ow in $newOwners) {
		$owSrcFile = Join-Path (Join-Path $cfgDir $childTypeDirMap[$ow.T]) "$($ow.N).xml"
		if (-not (Test-Path $owSrcFile)) {
			Warn "  Владелец $($ow.T).$($ow.N) не найден в источнике — ссылка останется висячей"
			continue
		}
		$owSrc = Read-SourceObject $ow.T $ow.N
		$owXml = Build-BorrowedObjectXml $ow.T $ow.N $owSrc.Uuid $owSrc.Properties
		$owDir = Join-Path $extDir $childTypeDirMap[$ow.T]
		if (-not (Test-Path $owDir)) { New-Item -ItemType Directory -Path $owDir -Force | Out-Null }
		$owFile = Join-Path $owDir "$($ow.N).xml"
		$owEnc = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($owFile, $owXml, $owEnc)
		Add-ToChildObjects $ow.T $ow.N
		$script:borrowedFiles += $owFile
		Info "  Auto-borrowed owner: $($ow.T).$($ow.N)"
	}
}

# --- 15. Save modified Configuration.xml ---
# Стиль исходника снимаем ДО записи: правка чужого файла наследует его BOM/EOL/заголовок
# (#44/#46/#47), новый файл получает канон выгрузки. Зеркало _detect_xml_style в py-порту.
$style = Detect-XmlStyle $extResolvedPath
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($true)
$settings.Indent = $false
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None
$memStream = New-Object System.IO.MemoryStream
$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
$script:xmlDoc.Save($writer)
$writer.Flush(); $writer.Close()
$text = [System.Text.Encoding]::UTF8.GetString($memStream.ToArray())
$memStream.Close()
$text = Finalize-XmlText $text $style
$writeBom = ($null -eq $style) -or $style.bom
[System.IO.File]::WriteAllText($extResolvedPath, $text, (New-Object System.Text.UTF8Encoding($writeBom)))
Info "Saved: $extResolvedPath"

# --- 16. Summary ---
Write-Host ""
Write-Host "=== cfe-borrow summary ==="
Write-Host "  Extension:  $extDir"
Write-Host "  Config:     $cfgDir"
Write-Host "  Borrowed:   $borrowedCount object(s)"
foreach ($f in $script:borrowedFiles) {
	Write-Host "    - $f"
}
exit 0
