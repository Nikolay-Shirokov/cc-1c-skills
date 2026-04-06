# cfe-borrow v1.3 — Borrow objects from configuration into extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)][string]$ExtensionPath,
	[Parameter(Mandatory)][string]$ConfigPath,
	[Parameter(Mandatory)][string]$Object,
	[string]$BorrowMainAttribute
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Info([string]$msg) { Write-Host "[INFO] $msg" }
function Warn([string]$msg) { Write-Host "[WARN] $msg" }

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
	"Sequence"="Sequences"; "IntegrationService"="IntegrationServices"
	"XDTOPackage"="XDTOPackages"; "WebService"="WebServices"
	"HTTPService"="HTTPServices"; "WSReference"="WSReferences"
	"CommonAttribute"="CommonAttributes"; "Style"="Styles"
}

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

# --- 5. Canonical type order (44 types) ---
$script:typeOrder = @(
	"Language","Subsystem","StyleItem","Style",
	"CommonPicture","SessionParameter","Role","CommonTemplate",
	"FilterCriterion","CommonModule","CommonAttribute","ExchangePlan",
	"XDTOPackage","WebService","HTTPService","WSReference",
	"EventSubscription","ScheduledJob","SettingsStorage","FunctionalOption",
	"FunctionalOptionsParameter","DefinedType","CommonCommand","CommandGroup",
	"Constant","CommonForm","Catalog","Document",
	"DocumentNumerator","Sequence","DocumentJournal","Enum",
	"Report","DataProcessor","InformationRegister","AccumulationRegister",
	"ChartOfCharacteristicTypes","ChartOfAccounts","AccountingRegister",
	"ChartOfCalculationTypes","CalculationRegister",
	"BusinessProcess","Task","IntegrationService"
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
		@{ prefix = "AccountingRegisterRecord";    category = "Record" }
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
	)
	"ChartOfAccounts" = @(
		@{ prefix = "ChartOfAccountsObject";    category = "Object" }
		@{ prefix = "ChartOfAccountsRef";       category = "Ref" }
		@{ prefix = "ChartOfAccountsSelection"; category = "Selection" }
		@{ prefix = "ChartOfAccountsList";      category = "List" }
		@{ prefix = "ChartOfAccountsManager";   category = "Manager" }
	)
	"ChartOfCharacteristicTypes" = @(
		@{ prefix = "ChartOfCharacteristicTypesObject";    category = "Object" }
		@{ prefix = "ChartOfCharacteristicTypesRef";       category = "Ref" }
		@{ prefix = "ChartOfCharacteristicTypesSelection"; category = "Selection" }
		@{ prefix = "ChartOfCharacteristicTypesList";      category = "List" }
		@{ prefix = "ChartOfCharacteristicTypesManager";   category = "Manager" }
	)
	"ChartOfCalculationTypes" = @(
		@{ prefix = "ChartOfCalculationTypesObject";    category = "Object" }
		@{ prefix = "ChartOfCalculationTypesRef";       category = "Ref" }
		@{ prefix = "ChartOfCalculationTypesSelection"; category = "Selection" }
		@{ prefix = "ChartOfCalculationTypesList";      category = "List" }
		@{ prefix = "ChartOfCalculationTypesManager";   category = "Manager" }
		@{ prefix = "DisplacingCalculationTypes";       category = "DisplacingCalculationTypes" }
		@{ prefix = "BaseCalculationTypes";             category = "BaseCalculationTypes" }
		@{ prefix = "LeadingCalculationTypes";          category = "LeadingCalculationTypes" }
	)
	"BusinessProcess" = @(
		@{ prefix = "BusinessProcessObject";    category = "Object" }
		@{ prefix = "BusinessProcessRef";       category = "Ref" }
		@{ prefix = "BusinessProcessSelection"; category = "Selection" }
		@{ prefix = "BusinessProcessList";      category = "List" }
		@{ prefix = "BusinessProcessManager";   category = "Manager" }
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
}

# Types that need ChildObjects element
$typesWithChildObjects = @(
	"Catalog","Document","ExchangePlan","ChartOfAccounts",
	"ChartOfCharacteristicTypes","ChartOfCalculationTypes",
	"BusinessProcess","Task","Enum",
	"InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister"
)

# CommonModule properties to copy from source
$commonModuleProps = @("Global","ClientManagedApplication","Server","ExternalConnection","ClientOrdinaryApplication","ServerCall")

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

$script:formatVersion = Detect-FormatVersion $extDir

# --- 8. Namespaces declaration for object XML ---
$script:xmlnsDecl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

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
	# PS treats -BorrowMainAttribute without value as "True"
	if ($BorrowMainAttribute -eq "True") { $BorrowMainAttribute = "Form" }
	if ($BorrowMainAttribute -notin @("Form","All")) {
		Write-Error "-BorrowMainAttribute accepts 'Form' or 'All' (default: Form)"
		exit 1
	}
	# Validate: only with .Form. pattern
	$hasForm = $false
	foreach ($item in $items) { if ($item -match '\.Form\.') { $hasForm = $true; break } }
	if (-not $hasForm) {
		Write-Error "-BorrowMainAttribute requires a form in -Object (e.g. 'Catalog.X.Form.Y')"
		exit 1
	}
}

# --- 10. Helper: read source object XML ---
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
	}

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
	$srcFile = Join-Path (Join-Path (Join-Path (Join-Path $cfgDir $dirName) $objName) "Forms") "${formName}.xml"
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

	# 1. Read source form UUID
	$formUuid = Read-SourceFormUuid $typeName $objName $formName
	Info "  Source form UUID: $formUuid"

	# 2. Read source Form.xml content
	$srcFormXmlPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $cfgDir $dirName) $objName) "Forms") $formName) "Ext/Form.xml"
	if (-not (Test-Path $srcFormXmlPath)) {
		Write-Error "Source Form.xml not found: $srcFormXmlPath"
		exit 1
	}
	$srcFormContent = [System.IO.File]::ReadAllText($srcFormXmlPath, $enc)

	# 3. Generate form metadata XML (ФормаЭлемента.xml)
	$newFormUuid = [guid]::NewGuid().ToString()
	$formMetaSb = New-Object System.Text.StringBuilder
	$formMetaSb.AppendLine("<?xml version=`"1.0`" encoding=`"UTF-8`"?>") | Out-Null
	$formMetaSb.AppendLine("<MetaDataObject $($script:xmlnsDecl) version=`"$($script:formatVersion)`">") | Out-Null
	$formMetaSb.AppendLine("`t<Form uuid=`"${newFormUuid}`">") | Out-Null
	$formMetaSb.AppendLine("`t`t<InternalInfo/>") | Out-Null
	$formMetaSb.AppendLine("`t`t<Properties>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<ObjectBelonging>Adopted</ObjectBelonging>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<Name>${formName}</Name>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<Comment/>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<ExtendedConfigurationObject>${formUuid}</ExtendedConfigurationObject>") | Out-Null
	$formMetaSb.AppendLine("`t`t`t<FormType>Managed</FormType>") | Out-Null
	$formMetaSb.AppendLine("`t`t</Properties>") | Out-Null
	$formMetaSb.AppendLine("`t</Form>") | Out-Null
	$formMetaSb.Append("</MetaDataObject>") | Out-Null

	# 4. Create directories
	$formMetaDir = Join-Path (Join-Path (Join-Path $extDir $dirName) $objName) "Forms"
	if (-not (Test-Path $formMetaDir)) {
		New-Item -ItemType Directory -Path $formMetaDir -Force | Out-Null
	}

	# Write form metadata
	$formMetaFile = Join-Path $formMetaDir "${formName}.xml"
	[System.IO.File]::WriteAllText($formMetaFile, $formMetaSb.ToString(), $enc)
	Info "  Created: $formMetaFile"

	# 5. Generate Form.xml with BaseForm (visual elements only)
	# Parse source Form.xml as XmlDocument
	$srcFormDoc = New-Object System.Xml.XmlDocument
	$srcFormDoc.PreserveWhitespace = $true
	$srcFormDoc.Load($srcFormXmlPath)
	$srcFormEl = $srcFormDoc.DocumentElement

	$formVersion = $srcFormEl.GetAttribute("version")
	if (-not $formVersion) { $formVersion = $script:formatVersion }

	# Find direct children: form properties, AutoCommandBar, ChildItems
	$srcAutoCmd = $null
	$srcChildItems = $null
	$formProps = @()
	$reachedVisual = $false
	foreach ($fc in $srcFormEl.ChildNodes) {
		if ($fc.NodeType -ne 'Element') { continue }
		if ($fc.LocalName -eq 'AutoCommandBar' -and -not $srcAutoCmd) {
			$reachedVisual = $true; $srcAutoCmd = $fc; continue
		}
		if ($fc.LocalName -eq 'ChildItems' -and -not $srcChildItems) {
			$reachedVisual = $true; $srcChildItems = $fc; continue
		}
		if ($fc.LocalName -eq 'Events' -or $fc.LocalName -eq 'Attributes' -or $fc.LocalName -eq 'Commands' -or $fc.LocalName -eq 'Parameters' -or $fc.LocalName -eq 'CommandSet') {
			$reachedVisual = $true; continue
		}
		if (-not $reachedVisual) {
			$formProps += $fc.OuterXml
		}
	}

	# Get OuterXml and strip redundant namespace redeclarations (they're on root <Form>)
	$nsStripPattern = '\s+xmlns(?::\w+)?="[^"]*"'

	# AutoCommandBar: keep ChildItems (buttons with CommandName→0), Autofill→false
	$autoCmdXml = ""
	if ($srcAutoCmd) {
		$autoCmdXml = $srcAutoCmd.OuterXml
		$autoCmdXml = [regex]::Replace($autoCmdXml, $nsStripPattern, '')
		$autoCmdXml = [regex]::Replace($autoCmdXml, '<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>')
		$autoCmdXml = $autoCmdXml -replace '<Autofill>true</Autofill>', '<Autofill>false</Autofill>'
		# Strip ExcludedCommand (references to standard commands invalid in extension)
		$autoCmdXml = [regex]::Replace($autoCmdXml, '\s*<ExcludedCommand>[^<]*</ExcludedCommand>', '')
		# Strip DataPath in AutoCommandBar buttons
		if ($BorrowMainAttr) {
			# Keep only Объект.* DataPaths
			$autoCmdXml = [regex]::Replace($autoCmdXml, '\s*<DataPath>(?!Объект\.)[^<]*</DataPath>', '')
		} else {
			$autoCmdXml = [regex]::Replace($autoCmdXml, '\s*<DataPath>[^<]*</DataPath>', '')
		}
	}

	# ChildItems: copy full tree, clean up base-config references
	$childItemsXml = ""
	if ($srcChildItems) {
		$childItemsXml = $srcChildItems.OuterXml
		$childItemsXml = [regex]::Replace($childItemsXml, $nsStripPattern, '')
		# Replace all CommandName values with 0
		$childItemsXml = [regex]::Replace($childItemsXml, '<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>')
		# Strip DataPath, TitleDataPath, RowPictureDataPath
		if ($BorrowMainAttr) {
			# Keep only Объект.* DataPaths — strip form-attribute DataPaths (not borrowed)
			$childItemsXml = [regex]::Replace($childItemsXml, '\s*<DataPath>(?!Объект\.)[^<]*</DataPath>', '')
			$childItemsXml = [regex]::Replace($childItemsXml, '\s*<TitleDataPath>(?!Объект\.)[^<]*</TitleDataPath>', '')
			$childItemsXml = [regex]::Replace($childItemsXml, '\s*<RowPictureDataPath>[^<]*</RowPictureDataPath>', '')
		} else {
			$childItemsXml = [regex]::Replace($childItemsXml, '\s*<DataPath>[^<]*</DataPath>', '')
			$childItemsXml = [regex]::Replace($childItemsXml, '\s*<TitleDataPath>[^<]*</TitleDataPath>', '')
			$childItemsXml = [regex]::Replace($childItemsXml, '\s*<RowPictureDataPath>[^<]*</RowPictureDataPath>', '')
		}
		# Strip ExcludedCommand in nested AutoCommandBars (references to standard commands invalid in extension)
		$childItemsXml = [regex]::Replace($childItemsXml, '\s*<ExcludedCommand>[^<]*</ExcludedCommand>', '')
		# Strip TypeLink blocks with human-readable DataPath (Items.XXX — can't convert to UUID)
		$childItemsXml = [regex]::Replace($childItemsXml, '(?s)\s*<TypeLink>\s*<xr:DataPath>Items\.[^<]*</xr:DataPath>.*?</TypeLink>', '')
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
		# Strip StdPicture blocks (except Print)
		$childItemsXml = [regex]::Replace($childItemsXml, '(?s)\s*<Picture>\s*<xr:Ref>StdPicture\.(?!Print\b)\w+</xr:Ref>.*?</Picture>', '')

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
			$autoCmdXml = [regex]::Replace($autoCmdXml, '(?s)\s*<Picture>\s*<xr:Ref>StdPicture\.(?!Print\b)\w+</xr:Ref>.*?</Picture>', '')
		}

		# Auto-borrow StyleItems referenced in ChildItems
		# Pattern 1: <Font ref="style:XXX" kind="StyleItem"/>, <TitleFont ref="style:XXX" ... kind="StyleItem"/>
		# Pattern 2: <BackColor>style:XXX</BackColor>, <TextColor>style:XXX</TextColor>, etc.
		$referencedStyles = @{}
		$styleRefs1 = [regex]::Matches($childItemsXml, 'ref="style:(\w+)"[^>]*kind="StyleItem"')
		foreach ($m in $styleRefs1) { $referencedStyles[$m.Groups[1].Value] = $true }
		$styleRefs2 = [regex]::Matches($childItemsXml, '>style:(\w+)</\w+>')
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
				} else {
					Warn "  StyleItem.${styleName} not found in source config"
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

	# Extract the <Form ...> opening tag from source text (preserves namespace declarations)
	$xmlDecl = '<?xml version="1.0" encoding="UTF-8"?>'
	$formTag = "<Form version=`"${formVersion}`">"
	if ($srcFormContent -match '(?s)^(<\?xml[^?]*\?>)') { $xmlDecl = $Matches[1] }
	if ($srcFormContent -match '(<Form[^>]*>)') { $formTag = $Matches[1] }

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
	# Attributes: empty or with MainAttribute when BorrowMainAttr
	if ($BorrowMainAttr) {
		$objTypePrefix = ""
		$gtList = $script:generatedTypes[$typeName]
		if ($gtList) { foreach ($g in $gtList) { if ($g.category -eq "Object") { $objTypePrefix = $g.prefix; break } } }
		$mainAttrType = "cfg:${objTypePrefix}.${objName}"
		$formXmlSb.Append("`t<Attributes>`r`n") | Out-Null
		$formXmlSb.Append("`t`t<Attribute name=`"Объект`" id=`"1000001`">`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t<Type><v8:Type>${mainAttrType}</v8:Type></Type>`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t<MainAttribute>true</MainAttribute>`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t<SavedData>true</SavedData>`r`n") | Out-Null
		$formXmlSb.Append("`t`t</Attribute>`r`n") | Out-Null
		$formXmlSb.Append("`t</Attributes>") | Out-Null
	} else {
		$formXmlSb.Append("`t<Attributes/>") | Out-Null
	}
	$formXmlSb.Append("`r`n") | Out-Null

	# BaseForm: same content, indented one more level
	$formXmlSb.Append("`t<BaseForm version=`"${formVersion}`">") | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null

	foreach ($propXml in $formProps) {
		$propXml = [regex]::Replace($propXml, $nsStripPattern, '')
		$formXmlSb.Append("`t`t$propXml`r`n") | Out-Null
	}
	if ($autoCmdXml) {
		$acLines = $autoCmdXml -split "`r?`n"
		for ($li = 0; $li -lt $acLines.Count; $li++) {
			if ($li -eq 0) { $formXmlSb.Append("`t`t$($acLines[$li])") | Out-Null }
			else { $formXmlSb.Append("`t$($acLines[$li])") | Out-Null }
			$formXmlSb.Append("`r`n") | Out-Null
		}
	}
	if ($childItemsXml) {
		# Reindent ChildItems for BaseForm (+1 tab level)
		$ciLines = $childItemsXml -split "`r?`n"
		for ($li = 0; $li -lt $ciLines.Count; $li++) {
			if ($li -eq 0) { $formXmlSb.Append("`t`t$($ciLines[$li])") | Out-Null }
			else { $formXmlSb.Append("`t$($ciLines[$li])") | Out-Null }
			$formXmlSb.Append("`r`n") | Out-Null
		}
	}

	# BaseForm Attributes: same as main section
	if ($BorrowMainAttr) {
		$formXmlSb.Append("`t`t<Attributes>`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t<Attribute name=`"Объект`" id=`"1000001`">`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t`t<Type><v8:Type>${mainAttrType}</v8:Type></Type>`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t`t<MainAttribute>true</MainAttribute>`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t`t<SavedData>true</SavedData>`r`n") | Out-Null
		$formXmlSb.Append("`t`t`t</Attribute>`r`n") | Out-Null
		$formXmlSb.Append("`t`t</Attributes>") | Out-Null
	} else {
		$formXmlSb.Append("`t`t<Attributes/>") | Out-Null
	}
	$formXmlSb.Append("`r`n") | Out-Null
	$formXmlSb.Append("`t</BaseForm>") | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null
	$formXmlSb.Append("</Form>") | Out-Null

	# Write Form.xml
	$formXmlDir = Join-Path (Join-Path $formMetaDir $formName) "Ext"
	if (-not (Test-Path $formXmlDir)) {
		New-Item -ItemType Directory -Path $formXmlDir -Force | Out-Null
	}
	$formXmlFile = Join-Path $formXmlDir "Form.xml"
	[System.IO.File]::WriteAllText($formXmlFile, $formXmlSb.ToString(), $enc)
	Info "  Created: $formXmlFile"

	# 6. Create empty Module.bsl
	$moduleDir = Join-Path $formXmlDir "Form"
	if (-not (Test-Path $moduleDir)) {
		New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
	}
	$moduleBslFile = Join-Path $moduleDir "Module.bsl"
	[System.IO.File]::WriteAllText($moduleBslFile, "", $enc)
	Info "  Created: $moduleBslFile"

	# 7. Register form in parent object ChildObjects
	Register-FormInObject $typeName $objName $formName

	return @($formMetaFile, $formXmlFile, $moduleBslFile)
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
	$settings2 = New-Object System.Xml.XmlWriterSettings
	$settings2.Encoding = New-Object System.Text.UTF8Encoding($true)
	$settings2.Indent = $false
	$settings2.NewLineHandling = [System.Xml.NewLineHandling]::None

	$memStream2 = New-Object System.IO.MemoryStream
	$writer2 = [System.Xml.XmlWriter]::Create($memStream2, $settings2)
	$objDoc.Save($writer2)
	$writer2.Flush(); $writer2.Close()

	$bytes2 = $memStream2.ToArray()
	$memStream2.Close()
	$text2 = [System.Text.Encoding]::UTF8.GetString($bytes2)
	if ($text2.Length -gt 0 -and $text2[0] -eq [char]0xFEFF) { $text2 = $text2.Substring(1) }
	$text2 = $text2.Replace('encoding="utf-8"', 'encoding="UTF-8"')

	$utf8Bom2 = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($objFile, $text2, $utf8Bom2)
	Info "  Registered form in: $objFile"
}

# --- 10e. Helper: check if object is already borrowed in extension ---
function Test-ObjectBorrowed {
	param([string]$typeName, [string]$objName)

	$dirName = $childTypeDirMap[$typeName]
	$objFile = Join-Path (Join-Path $extDir $dirName) "${objName}.xml"
	return (Test-Path $objFile)
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
function Collect-FormDataPaths {
	param([string]$formXmlPath)

	$enc = New-Object System.Text.UTF8Encoding($true)
	$content = [System.IO.File]::ReadAllText($formXmlPath, $enc)

	$firstLevel = @{}
	$deepPaths = @()

	$matches2 = [regex]::Matches($content, '<DataPath>[^<]*\bОбъект\.(\w+(?:\.\w+)*)</DataPath>')
	foreach ($m in $matches2) {
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

	# Also collect from TitleDataPath
	$matches3 = [regex]::Matches($content, '<TitleDataPath>[^<]*\bОбъект\.(\w+(?:\.\w+)*)</TitleDataPath>')
	foreach ($m in $matches3) {
		$path = $m.Groups[1].Value
		$segments = $path.Split(".")
		$seg0 = $segments[0]
		if ($script:standardFields -contains $seg0) { continue }
		$firstLevel[$seg0] = $true
	}

	# Deduplicate deep paths
	$seen = @{}
	$uniqueDeep = @()
	foreach ($dp in $deepPaths) {
		$key = "$($dp.ObjectAttr).$($dp.SubAttr)"
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

		if ($child.LocalName -eq 'Attribute') {
			$nameNode = $child.SelectSingleNode("md:Properties/md:Name", $srcNs)
			if (-not $nameNode) { continue }
			$attrName = $nameNode.InnerText
			if ($null -ne $firstLevelNames -and -not $firstLevelNames.ContainsKey($attrName)) { continue }

			$uuid = $child.GetAttribute("uuid")
			$typeNode = $child.SelectSingleNode("md:Properties/md:Type", $srcNs)
			$typeXml = if ($typeNode) { $typeNode.OuterXml } else { "" }
			# Strip namespace declarations from Type
			$typeXml = [regex]::Replace($typeXml, '\s+xmlns(?::\w+)?="[^"]*"', '')

			$attrs += @{ Name = $attrName; Uuid = $uuid; TypeXml = $typeXml }
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
	$extraProps = @{}
	$propsNode = $srcEl.SelectSingleNode("md:Properties", $srcNs)
	if ($propsNode) {
		$propsToExtract = @("Hierarchical","FoldersOnTop","CodeLength","DescriptionLength","CodeType","CodeAllowedLength",
			"NumberType","NumberLength","NumberAllowedLength","NumberPeriodicity")
		foreach ($pName in $propsToExtract) {
			$pNode = $propsNode.SelectSingleNode("md:${pName}", $srcNs)
			if ($pNode) { $extraProps[$pName] = $pNode.InnerText }
		}
	}

	return @{ Attributes = $attrs; TabularSections = $tabSections; ExtraProps = $extraProps }
}

# --- 11d. Build adopted attribute XML ---
function Build-AdoptedAttributeXml {
	param([string]$name, [string]$sourceUuid, [string]$typeXml, [string]$indent)

	$newUuid = [guid]::NewGuid().ToString()
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("${indent}<Attribute uuid=`"${newUuid}`">") | Out-Null
	$sb.AppendLine("${indent}`t<InternalInfo/>") | Out-Null
	$sb.AppendLine("${indent}`t<Properties>") | Out-Null
	$sb.AppendLine("${indent}`t`t<ObjectBelonging>Adopted</ObjectBelonging>") | Out-Null
	$sb.AppendLine("${indent}`t`t<Name>${name}</Name>") | Out-Null
	$sb.AppendLine("${indent}`t`t<Comment/>") | Out-Null
	$sb.AppendLine("${indent}`t`t<ExtendedConfigurationObject>${sourceUuid}</ExtendedConfigurationObject>") | Out-Null
	$sb.AppendLine("${indent}`t`t${typeXml}") | Out-Null
	$sb.AppendLine("${indent}`t</Properties>") | Out-Null
	$sb.Append("${indent}</Attribute>") | Out-Null
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

	$result = @{}
	foreach ($typeXml in $typeXmls) {
		# cfg:CatalogRef.XXX, cfg:EnumRef.XXX, cfg:DocumentRef.XXX, etc.
		$refMatches = [regex]::Matches($typeXml, 'cfg:(\w+)Ref\.(\w+)')
		foreach ($m in $refMatches) {
			$refPrefix = $m.Groups[1].Value  # e.g. "Catalog", "Enum", "Document"
			$objName = $m.Groups[2].Value
			$key = "${refPrefix}.${objName}"
			if (-not $result.ContainsKey($key)) {
				$result[$key] = @{ TypeName = $refPrefix; ObjName = $objName }
			}
		}
		# cfg:DefinedType.XXX (via v8:TypeSet or v8:Type)
		$dtMatches = [regex]::Matches($typeXml, 'cfg:DefinedType\.(\w+)')
		foreach ($m in $dtMatches) {
			$dtName = $m.Groups[1].Value
			$key = "DefinedType.${dtName}"
			if (-not $result.ContainsKey($key)) {
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
		$attrXml = Build-AdoptedAttributeXml $attr.Name $attr.Uuid $attr.TypeXml "`t`t`t"

		# Expand self-closing ChildObjects if needed
		if (-not $childObjs.HasChildNodes -or $childObjs.IsEmpty) {
			$closeWs = $objDoc.CreateWhitespace("`r`n`t`t")
			$childObjs.AppendChild($closeWs) | Out-Null
		}

		$added++
	}

	if ($added -gt 0) {
		# Build all adopted attributes as text and do string-level insertion
		$allAttrXml = ""
		foreach ($attr in $attrsToAdd) {
			if ($existingNames.ContainsKey($attr.Name)) { continue }
			$allAttrXml += "`r`n" + (Build-AdoptedAttributeXml $attr.Name $attr.Uuid $attr.TypeXml "`t`t`t")
		}

		# Save via text manipulation to avoid namespace issues with InnerXml
		$settings3 = New-Object System.Xml.XmlWriterSettings
		$settings3.Encoding = New-Object System.Text.UTF8Encoding($true)
		$settings3.Indent = $false
		$settings3.NewLineHandling = [System.Xml.NewLineHandling]::None
		$memStream3 = New-Object System.IO.MemoryStream
		$writer3 = [System.Xml.XmlWriter]::Create($memStream3, $settings3)
		$objDoc.Save($writer3)
		$writer3.Flush(); $writer3.Close()
		$bytes3 = $memStream3.ToArray()
		$memStream3.Close()
		$text3 = [System.Text.Encoding]::UTF8.GetString($bytes3)
		if ($text3.Length -gt 0 -and $text3[0] -eq [char]0xFEFF) { $text3 = $text3.Substring(1) }
		$text3 = $text3.Replace('encoding="utf-8"', 'encoding="UTF-8"')

		# Insert attributes before </ChildObjects>
		$text3 = $text3 -replace '</ChildObjects>', "${allAttrXml}`r`n`t`t</ChildObjects>"

		$utf8Bom3 = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($objFile, $text3, $utf8Bom3)
		Info "  Merged $added attribute(s) into: $objFile"
	}
}

# --- 11h. Borrow-MainAttribute orchestrator ---
function Borrow-MainAttribute {
	param([string]$typeName, [string]$objName, [string]$formName, [string]$mode)

	$dirName = $childTypeDirMap[$typeName]
	Info "Borrowing main attribute for ${typeName}.${objName} (mode: $mode)..."

	# Step 1: Collect DataPaths (Form mode) or take all (All mode)
	$firstLevelNames = $null
	$deepPaths = @()
	if ($mode -eq "Form") {
		$srcFormXmlPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $cfgDir $dirName) $objName) "Forms") $formName) "Ext/Form.xml"
		if (-not (Test-Path $srcFormXmlPath)) {
			Write-Error "Source Form.xml not found: $srcFormXmlPath"
			exit 1
		}
		$dp = Collect-FormDataPaths $srcFormXmlPath
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

	# Generate full object XML with attributes and TS
	$contentSb = New-Object System.Text.StringBuilder
	foreach ($attr in $srcAttrs) {
		$attrXml = Build-AdoptedAttributeXml $attr.Name $attr.Uuid $attr.TypeXml "`t`t`t"
		$contentSb.AppendLine($attrXml) | Out-Null
	}
	foreach ($ts in $srcTS) {
		$tsXml = Build-AdoptedTabularSectionXml $ts.Name $ts.Uuid $ts.GeneratedTypes $ts.Attributes "`t`t`t"
		$contentSb.AppendLine($tsXml) | Out-Null
	}
	$adoptedContent = $contentSb.ToString().TrimEnd()

	# Read existing object XML and inject
	$objContent = [System.IO.File]::ReadAllText($objFile, (New-Object System.Text.UTF8Encoding($true)))

	# Inject extra properties after ExtendedConfigurationObject
	if ($extraProps.Count -gt 0) {
		$propsSb = New-Object System.Text.StringBuilder
		foreach ($pName in $extraProps.Keys) {
			$propsSb.Append("`r`n`t`t`t<${pName}>$($extraProps[$pName])</${pName}>") | Out-Null
		}
		$objContent = $objContent -replace '(</ExtendedConfigurationObject>)', "`$1$($propsSb.ToString())"
	}

	# Replace empty ChildObjects with adopted content
	if ($adoptedContent) {
		# Handle <ChildObjects/> (self-closing)
		if ($objContent -match '<ChildObjects\s*/>') {
			$objContent = $objContent -replace '<ChildObjects\s*/>', "<ChildObjects>`r`n${adoptedContent}`r`n`t`t</ChildObjects>"
		}
		# Handle <ChildObjects>...</ChildObjects> (may already have Form entry)
		elseif ($objContent -match '(?s)<ChildObjects>(.*?)</ChildObjects>') {
			$existingInner = $Matches[1]
			$objContent = $objContent -replace '(?s)<ChildObjects>(.*?)</ChildObjects>', "<ChildObjects>${existingInner}`r`n${adoptedContent}`r`n`t`t</ChildObjects>"
		}
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
	$refTypes = Collect-ReferenceTypes $allTypeXmls
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

	# Step 5: Handle deep paths (Form mode only)
	if ($mode -eq "Form" -and $deepPaths.Count -gt 0) {
		# Filter out deep paths where ObjectAttr is a TabularSection (those are TS column refs, not deep attribute refs)
		$realDeep = @()
		foreach ($dp in $deepPaths) {
			if (-not $tsNames.ContainsKey($dp.ObjectAttr)) { $realDeep += $dp }
		}

		if ($realDeep.Count -gt 0) {
			Info "  Processing $($realDeep.Count) deep path(s)..."

			# Group by ObjectAttr → target catalog
			$deepByAttr = @{}
			foreach ($dp in $realDeep) {
				if (-not $deepByAttr.ContainsKey($dp.ObjectAttr)) { $deepByAttr[$dp.ObjectAttr] = @() }
				$deepByAttr[$dp.ObjectAttr] += $dp.SubAttr
			}

			foreach ($attrName in $deepByAttr.Keys) {
				# Find the attribute's type to determine target catalog
				$attrInfo = $srcAttrs | Where-Object { $_.Name -eq $attrName } | Select-Object -First 1
				if (-not $attrInfo) { continue }

				# Extract catalog name from type: cfg:CatalogRef.XXX
				$catMatch = [regex]::Match($attrInfo.TypeXml, 'cfg:(\w+)Ref\.(\w+)')
				if (-not $catMatch.Success) { continue }

				$targetTypeName = $catMatch.Groups[1].Value
				$targetObjName = $catMatch.Groups[2].Value

				# Ensure target is borrowed
				if (-not (Test-ObjectBorrowed $targetTypeName $targetObjName)) {
					$tSrc = Read-SourceObject $targetTypeName $targetObjName
					$tBorrowedXml = Build-BorrowedObjectXml $targetTypeName $targetObjName $tSrc.Uuid $tSrc.Properties
					$tTargetDir = Join-Path $extDir $childTypeDirMap[$targetTypeName]
					if (-not (Test-Path $tTargetDir)) {
						New-Item -ItemType Directory -Path $tTargetDir -Force | Out-Null
					}
					$tTargetFile = Join-Path $tTargetDir "${targetObjName}.xml"
					[System.IO.File]::WriteAllText($tTargetFile, $tBorrowedXml, $encBom)
					Add-ToChildObjects $targetTypeName $targetObjName
					$script:borrowedFiles += $tTargetFile
					Info "  Auto-borrowed for deep path: ${targetTypeName}.${targetObjName}"
				}

				# Resolve sub-attributes in target catalog
				$subNames = @{}
				foreach ($sn in $deepByAttr[$attrName]) { $subNames[$sn] = $true }
				$subResolved = Resolve-SourceAttributes $targetTypeName $targetObjName $subNames

				if ($subResolved.Attributes.Count -gt 0) {
					Merge-AttributesIntoObject $targetTypeName $targetObjName $subResolved.Attributes

					# Collect and borrow ref types from deep attributes
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
						if (-not (Test-Path $sTargetDir)) {
							New-Item -ItemType Directory -Path $sTargetDir -Force | Out-Null
						}
						$sTargetFile = Join-Path $sTargetDir "$($srt.ObjName).xml"
						[System.IO.File]::WriteAllText($sTargetFile, $sBorrowedXml, $encBom)
						Add-ToChildObjects $srt.TypeName $srt.ObjName
						$script:borrowedFiles += $sTargetFile
						Info "  Auto-borrowed (deep): $($srt.TypeName).$($srt.ObjName)"
					}
				}
			}
		}
	}

	Info "  Main attribute borrowing complete"
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

	$sb.AppendLine("`t`t</Properties>") | Out-Null

	# ChildObjects (for types that need it)
	if ($typesWithChildObjects -contains $typeName) {
		$sb.AppendLine("`t`t<ChildObjects/>") | Out-Null
	}

	$sb.AppendLine("`t</${typeName}>") | Out-Null
	$sb.Append("</MetaDataObject>") | Out-Null

	return $sb.ToString()
}

# --- 13. Helper: add object to extension ChildObjects ---
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

	# Find insertion point: after last element of same type, or before first element of later type
	$insertBefore = $null
	$lastSameType = $null

	foreach ($child in $script:childObjsEl.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childTypeIdx = $script:typeOrder.IndexOf($child.LocalName)
		if ($childTypeIdx -lt 0) { continue }

		if ($child.LocalName -eq $typeName) {
			# Same type -- check alphabetical order
			if ($child.InnerText -gt $objName -and -not $insertBefore) {
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

	$dirName = $childTypeDirMap[$typeName]

	if ($formName) {
		# --- Form borrowing ---
		Info "Borrowing form ${typeName}.${objName}.Form.${formName}..."

		# Auto-borrow parent object if not yet borrowed
		if (-not (Test-ObjectBorrowed $typeName $objName)) {
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
		$borrowedCount++

		# Borrow main attribute if requested
		if ($hasBMA) {
			Borrow-MainAttribute $typeName $objName $formName $BorrowMainAttribute
		}
	} else {
		# --- Object borrowing (existing logic) ---
		Info "Borrowing ${typeName}.${objName}..."

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
		$borrowedCount++
	}
}

# --- 15. Save modified Configuration.xml ---
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($true)
$settings.Indent = $false
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None

$memStream = New-Object System.IO.MemoryStream
$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
$script:xmlDoc.Save($writer)
$writer.Flush(); $writer.Close()

$bytes = $memStream.ToArray()
$memStream.Close()
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
$text = $text.Replace('encoding="utf-8"', 'encoding="UTF-8"')

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($extResolvedPath, $text, $utf8Bom)
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
