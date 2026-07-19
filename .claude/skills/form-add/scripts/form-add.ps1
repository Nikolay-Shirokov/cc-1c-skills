# form-add v1.10 — Add managed form to 1C config object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ObjectPath,

	[Parameter(Mandatory)]
	[string]$FormName,

	[string]$Synonym = $FormName,

	[string]$Purpose = "Object",

	[switch]$SetDefault
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
function Test-ExternalObjectRoot([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $false }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { return @('ExternalDataProcessor','ExternalReport') -contains $el.LocalName }
	} catch {}
	return $false
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
function Get-EditMode([string]$cfgDir) {
	try {
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $hm.Success) { return }
		$G = [int]$hm.Groups[1].Value
		$K = [int]$hm.Groups[2].Value
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch { return }
}

# --- Detect XML format version ---

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$head = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8).Substring(0, [Math]::Min(2000, (Get-Item $cfgPath).Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

# --- Фаза 1: Определение типа объекта ---

# Resolve ObjectPath (directory → .xml)
if (-not [System.IO.Path]::IsPathRooted($ObjectPath)) {
	$ObjectPath = Join-Path (Get-Location).Path $ObjectPath
}
if (Test-Path $ObjectPath -PathType Container) {
	$dirName = Split-Path $ObjectPath -Leaf
	$candidate = Join-Path $ObjectPath "$dirName.xml"
	$sibling = Join-Path (Split-Path $ObjectPath) "$dirName.xml"
	if (Test-Path $candidate) { $ObjectPath = $candidate }
	elseif (Test-Path $sibling) { $ObjectPath = $sibling }
}

if (-not (Test-Path $ObjectPath)) {
	Write-Error "Файл объекта не найден: $ObjectPath"
	exit 1
}

$objectXmlFull = Resolve-Path $ObjectPath
Assert-EditAllowed $objectXmlFull.Path 'editable'
$script:formatVersion = Detect-FormatVersion (Split-Path $objectXmlFull.Path -Parent)

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($objectXmlFull.Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$nsMgr.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")

# Определяем тип объекта по корневому тегу внутри MetaDataObject
$metaDataObject = $xmlDoc.SelectSingleNode("//md:MetaDataObject", $nsMgr)
if (-not $metaDataObject) {
	# Пробуем без namespace (fallback)
	$metaDataObject = $xmlDoc.DocumentElement
}

$supportedTypes = @(
	"Document", "Catalog", "DataProcessor", "Report",
	"ExternalDataProcessor", "ExternalReport",
	"InformationRegister", "AccumulationRegister", "ChartOfAccounts", "ChartOfCharacteristicTypes",
	"ExchangePlan", "BusinessProcess", "Task", "DocumentJournal"
)

$objectType = $null
$objectNode = $null
foreach ($t in $supportedTypes) {
	$node = $xmlDoc.SelectSingleNode("//md:$t", $nsMgr)
	if ($node) {
		$objectType = $t
		$objectNode = $node
		break
	}
}

if (-not $objectType) {
	Write-Error "Не удалось определить тип объекта. Поддерживаемые типы: $($supportedTypes -join ', ')"
	exit 1
}

# Имя объекта из Properties/Name
$objectName = $xmlDoc.SelectSingleNode("//md:${objectType}/md:Properties/md:Name", $nsMgr).InnerText
if (-not $objectName) {
	Write-Error "Не удалось определить имя объекта из Properties/Name"
	exit 1
}

Write-Host ""
Write-Host "=== form-add ==="
Write-Host ""
Write-Host "Object: $objectType.$objectName"

# --- Фаза 2: Валидация Purpose ---

$Purpose = $Purpose.Substring(0,1).ToUpper() + $Purpose.Substring(1).ToLower()
# Нормализация
switch ($Purpose) {
	"Object" { }
	"List"   { }
	"Choice" { }
	"Record" { }
	default {
		Write-Error "Недопустимое назначение: $Purpose. Допустимые: Object, List, Choice, Record"
		exit 1
	}
}

$objectLikeTypes = @("Document", "Catalog", "ChartOfAccounts", "ChartOfCharacteristicTypes", "ExchangePlan", "BusinessProcess", "Task")
$processorLikeTypes = @("DataProcessor", "Report", "ExternalDataProcessor", "ExternalReport")

switch ($Purpose) {
	"Object" {
		# допустимо для всех типов
	}
	"List" {
		if ($objectType -eq "DataProcessor") {
			Write-Error "Purpose=List недопустим для DataProcessor"
			exit 1
		}
	}
	"Choice" {
		if ($objectType -in $processorLikeTypes -or $objectType -eq "InformationRegister") {
			Write-Error "Purpose=Choice недопустим для $objectType"
			exit 1
		}
	}
	"Record" {
		if ($objectType -ne "InformationRegister") {
			Write-Error "Purpose=Record допустим только для InformationRegister"
			exit 1
		}
	}
}

# --- Фаза 3: Создание файлов ---

$objectDir = [System.IO.Path]::ChangeExtension($objectXmlFull.Path, $null).TrimEnd('.')
$formsDir = Join-Path $objectDir "Forms"
$formMetaPath = Join-Path $formsDir "$FormName.xml"

if (Test-Path $formMetaPath) {
	Write-Error "Форма уже существует: $formMetaPath"
	exit 1
}

$formDir = Join-Path $formsDir $FormName
$formExtDir = Join-Path $formDir "Ext"
$formModuleDir = Join-Path $formExtDir "Form"

New-Item -ItemType Directory -Path $formModuleDir -Force | Out-Null

$encBom = New-Object System.Text.UTF8Encoding($true)

# --- 3a. Метаданные формы ---

$formUuid = [guid]::NewGuid().ToString()

# ExtendedPresentation — only for DataProcessor, Report, ExternalDataProcessor, ExternalReport forms
$extPresentationLine = ""
if ($objectType -in $processorLikeTypes) {
	$extPresentationLine = "`n`t`t`t<ExtendedPresentation/>"
}

$formMetaXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="$($script:formatVersion)">
	<Form uuid="$formUuid">
		<Properties>
			<Name>$FormName</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>$Synonym</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<FormType>Managed</FormType>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
				<v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>
			</UsePurposes>$extPresentationLine
		</Properties>
	</Form>
</MetaDataObject>
"@

[System.IO.File]::WriteAllText($formMetaPath, $formMetaXml, $encBom)

# --- 3b. Form.xml ---

$formXmlPath = Join-Path $formExtDir "Form.xml"

$formNsDecl = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

if ($Purpose -eq "List" -or $Purpose -eq "Choice") {
	# Динамический список
	# MainTable: тип.имя
	$mainTable = "$objectType.$objectName"

	$formXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Form $formNsDecl version="$($script:formatVersion)">
	<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
		<Autofill>true</Autofill>
	</AutoCommandBar>
	<ChildItems/>
	<Attributes>
		<Attribute name="Список" id="1">
			<Type>
				<v8:Type>cfg:DynamicList</v8:Type>
			</Type>
			<MainAttribute>true</MainAttribute>
			<Settings xsi:type="DynamicList">
				<MainTable>$mainTable</MainTable>
			</Settings>
		</Attribute>
	</Attributes>
</Form>
"@
} elseif ($Purpose -eq "Record") {
	# Запись регистра сведений
	$mainAttrName = "Запись"
	$mainAttrType = "InformationRegisterRecordManager.$objectName"

	$formXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Form $formNsDecl version="$($script:formatVersion)">
	<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
		<Autofill>true</Autofill>
	</AutoCommandBar>
	<ChildItems/>
	<Attributes>
		<Attribute name="$mainAttrName" id="1">
			<Type>
				<v8:Type>cfg:$mainAttrType</v8:Type>
			</Type>
			<MainAttribute>true</MainAttribute>
			<SavedData>true</SavedData>
		</Attribute>
	</Attributes>
</Form>
"@
} else {
	# Object — форма объекта
	$mainAttrName = "Объект"

	# Маппинг типа объекта на тип реквизита
	$attrTypeMap = @{
		"Document"                    = "DocumentObject"
		"Catalog"                     = "CatalogObject"
		"DataProcessor"               = "DataProcessorObject"
		"Report"                      = "ReportObject"
		"ExternalDataProcessor"       = "ExternalDataProcessorObject"
		"ExternalReport"              = "ExternalReportObject"
		"ChartOfAccounts"             = "ChartOfAccountsObject"
		"ChartOfCharacteristicTypes"  = "ChartOfCharacteristicTypesObject"
		"ExchangePlan"                = "ExchangePlanObject"
		"BusinessProcess"             = "BusinessProcessObject"
		"Task"                        = "TaskObject"
		"InformationRegister"         = "InformationRegisterRecordManager"
		"AccumulationRegister"        = "AccumulationRegisterRecordSet"
	}

	$mainAttrType = "$($attrTypeMap[$objectType]).$objectName"

	# SavedData: standard for Catalog/Document/etc, but not for processor-like (DataProcessor/Report/External*)
	$savedDataLine = ""
	if ($objectType -notin $processorLikeTypes) {
		$savedDataLine = "`n`t`t`t<SavedData>true</SavedData>"
	}

	$formXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Form $formNsDecl version="$($script:formatVersion)">
	<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
		<Autofill>true</Autofill>
	</AutoCommandBar>
	<ChildItems/>
	<Attributes>
		<Attribute name="$mainAttrName" id="1">
			<Type>
				<v8:Type>cfg:$mainAttrType</v8:Type>
			</Type>
			<MainAttribute>true</MainAttribute>$savedDataLine
		</Attribute>
	</Attributes>
</Form>
"@
}

if (Test-Path $formXmlPath) {
	Write-Host "[SKIP] Form.xml already exists: $formXmlPath — not overwriting"
} else {
	[System.IO.File]::WriteAllText($formXmlPath, $formXml, $encBom)
}

# --- 3c. Module.bsl ---

$modulePath = Join-Path $formModuleDir "Module.bsl"

$moduleBsl = @"
#Область ОбработчикиСобытийФормы

#КонецОбласти

#Область ОбработчикиСобытийЭлементовФормы

#КонецОбласти

#Область ОбработчикиКомандФормы

#КонецОбласти

#Область ОбработчикиОповещений

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

#КонецОбласти
"@

if (Test-Path $modulePath) {
	Write-Host "[SKIP] Module.bsl already exists: $modulePath — not overwriting"
} else {
	[System.IO.File]::WriteAllText($modulePath, $moduleBsl, $encBom)
}

# --- Фаза 4: Регистрация в родительском объекте ---

$childObjects = $xmlDoc.SelectSingleNode("//md:${objectType}/md:ChildObjects", $nsMgr)
if (-not $childObjects) {
	Write-Error "Не найден элемент ChildObjects в $ObjectPath"
	exit 1
}

# Добавить <Form>$FormName</Form>
$formElem = $xmlDoc.CreateElement("Form", "http://v8.1c.ru/8.3/MDClasses")
$formElem.InnerText = $FormName

# Ищем первый <Template> для вставки перед ним
$firstTemplate = $childObjects.SelectSingleNode("md:Template", $nsMgr)
# Ищем первую <TabularSection> для вставки перед ней (если нет Template)
$firstTabular = $childObjects.SelectSingleNode("md:TabularSection", $nsMgr)

# Определяем точку вставки: перед Template, перед TabularSection, или в конец
$insertBefore = $null
if ($firstTemplate) {
	$insertBefore = $firstTemplate
} elseif ($firstTabular) {
	$insertBefore = $firstTabular
}

if ($insertBefore) {
	# Вставить перед найденным элементом, с переносом строки
	$whitespace = $xmlDoc.CreateWhitespace("`n`t`t`t")
	$childObjects.InsertBefore($formElem, $insertBefore) | Out-Null
	$childObjects.InsertBefore($whitespace, $formElem) | Out-Null
	# Переставляем: whitespace перед formElem — неправильный порядок
	# Правильно: formElem, затем whitespace перед insertBefore
	# InsertBefore возвращает вставленный узел, порядок: ... formElem whitespace insertBefore ...
	# На самом деле нам нужно: ... \n\t\t\tformElem \n\t\t\tinsertBefore
	# Удалим и вставим правильно
	$childObjects.RemoveChild($whitespace) | Out-Null
	$childObjects.RemoveChild($formElem) | Out-Null

	$childObjects.InsertBefore($formElem, $insertBefore) | Out-Null
	# Whitespace нужен ДО formElem (перенос строки + отступ)
	# Но перед insertBefore уже должен быть whitespace от предыдущего элемента
	# Нам нужно добавить whitespace ПОСЛЕ formElem (перед insertBefore)
	$ws = $xmlDoc.CreateWhitespace("`n`t`t`t")
	$childObjects.InsertBefore($ws, $insertBefore) | Out-Null
} else {
	# Добавить в конец ChildObjects
	if ($childObjects.ChildNodes.Count -eq 0) {
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
		$childObjects.AppendChild($formElem) | Out-Null
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
	} else {
		$lastChild = $childObjects.LastChild
		if ($lastChild.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
			$childObjects.InsertBefore($xmlDoc.CreateWhitespace("`n`t`t`t"), $lastChild) | Out-Null
			$childObjects.InsertBefore($formElem, $lastChild) | Out-Null
		} else {
			$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
			$childObjects.AppendChild($formElem) | Out-Null
			$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
		}
	}
}

# --- SetDefault ---

$existingForms = $childObjects.SelectNodes("md:Form", $nsMgr)
$isFirstFormForPurpose = $false
$defaultPropName = $null
$defaultValue = "$objectType.$objectName.Form.$FormName"

# Определяем имя свойства для DefaultForm
switch ($Purpose) {
	"Object" {
		if ($objectType -in $processorLikeTypes) {
			$defaultPropName = "DefaultForm"
		} else {
			$defaultPropName = "DefaultObjectForm"
		}
	}
	"List"   { $defaultPropName = "DefaultListForm" }
	"Choice" { $defaultPropName = "DefaultChoiceForm" }
	"Record" { $defaultPropName = "DefaultRecordForm" }
}

# Проверяем, установлено ли уже значение
$defaultNode = $xmlDoc.SelectSingleNode("//md:${objectType}/md:Properties/md:$defaultPropName", $nsMgr)
if ($defaultNode) {
	$isFirstFormForPurpose = [string]::IsNullOrWhiteSpace($defaultNode.InnerText)
}

$defaultUpdated = $false
if ($SetDefault -or $isFirstFormForPurpose) {
	if ($defaultNode) {
		$defaultNode.InnerText = $defaultValue
		$defaultUpdated = $true
	}
}

# Сохранить с BOM
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = $encBom
$settings.Indent = $false

$stream = New-Object System.IO.FileStream($objectXmlFull.Path, [System.IO.FileMode]::Create)
$writer = [System.Xml.XmlWriter]::Create($stream, $settings)
$xmlDoc.Save($writer)
$writer.Close()
$stream.Close()

# --- Фаза 5: Вывод ---

# Относительные пути для вывода
$basePath = Split-Path $objectXmlFull.Path -Parent
# Определяем корень (ищем родительский каталог типа Documents, Catalogs и т.д.)
$relFormMeta = $formMetaPath.Replace($basePath, "").TrimStart("\", "/")
$relFormXml = $formXmlPath.Replace($basePath, "").TrimStart("\", "/")
$relModule = $modulePath.Replace($basePath, "").TrimStart("\", "/")

$objFileName = [System.IO.Path]::GetFileName($ObjectPath)
$objDirName = Split-Path $ObjectPath -Parent
$objBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ObjectPath)

Write-Host "Created:"
Write-Host "  Metadata: $objDirName\$objBaseName\Forms\$FormName.xml"
Write-Host "  Form:     $objDirName\$objBaseName\Forms\$FormName\Ext\Form.xml"
Write-Host "  Module:   $objDirName\$objBaseName\Forms\$FormName\Ext\Form\Module.bsl"
Write-Host ""
Write-Host "Registered: <Form>$FormName</Form> in ChildObjects"
if ($defaultUpdated) {
	Write-Host "${defaultPropName}: $defaultValue"
}
Write-Host ""
