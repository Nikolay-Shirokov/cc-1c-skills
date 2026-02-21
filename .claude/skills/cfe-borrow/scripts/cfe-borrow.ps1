# cfe-borrow v1.0 — Borrow objects from configuration into extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)][string]$ExtensionPath,
	[Parameter(Mandatory)][string]$ConfigPath,
	[Parameter(Mandatory)][string]$Object
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
	param([string]$typeName, [string]$objName, [string]$formName)

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
	$formMetaSb.AppendLine("<MetaDataObject $($script:xmlnsDecl) version=`"2.17`">") | Out-Null
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
	if (-not $formVersion) { $formVersion = "2.17" }

	# Find direct children: AutoCommandBar, ChildItems (visual elements only)
	$srcAutoCmd = $null
	$srcChildItems = $null
	foreach ($fc in $srcFormEl.ChildNodes) {
		if ($fc.NodeType -ne 'Element') { continue }
		if ($fc.LocalName -eq 'AutoCommandBar' -and -not $srcAutoCmd) { $srcAutoCmd = $fc }
		elseif ($fc.LocalName -eq 'ChildItems' -and -not $srcChildItems) { $srcChildItems = $fc }
	}

	# Get OuterXml and strip redundant namespace redeclarations (they're on root <Form>)
	$nsStripPattern = '\s+xmlns(?::\w+)?="[^"]*"'

	$autoCmdXml = ""
	if ($srcAutoCmd) {
		$autoCmdXml = $srcAutoCmd.OuterXml
		$autoCmdXml = [regex]::Replace($autoCmdXml, $nsStripPattern, '')
		# Replace all CommandName values with 0 (base form buttons lose command refs)
		$autoCmdXml = [regex]::Replace($autoCmdXml, '<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>')
		# Replace Autofill true → false
		$autoCmdXml = $autoCmdXml -replace '<Autofill>true</Autofill>', '<Autofill>false</Autofill>'
	}

	$childItemsXml = ""
	if ($srcChildItems) {
		$childItemsXml = $srcChildItems.OuterXml
		$childItemsXml = [regex]::Replace($childItemsXml, $nsStripPattern, '')
		# Replace all CommandName values with 0 in ChildItems too
		$childItemsXml = [regex]::Replace($childItemsXml, '<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>')
	} else {
		$childItemsXml = "<ChildItems/>"
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

	# Part 1: visual elements (add leading tab to first line of each block)
	if ($autoCmdXml) {
		$formXmlSb.Append("`t$autoCmdXml") | Out-Null
		$formXmlSb.Append("`r`n") | Out-Null
	}
	$formXmlSb.Append("`t$childItemsXml") | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null
	$formXmlSb.Append("`t<Attributes/>") | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null

	# BaseForm: same visual elements, indented one more level
	$formXmlSb.Append("`t<BaseForm version=`"${formVersion}`">") | Out-Null
	$formXmlSb.Append("`r`n") | Out-Null

	if ($autoCmdXml) {
		# Reindent for BaseForm: first line gets 2 tabs, other lines get +1 tab
		$acLines = $autoCmdXml -split "`r`n"
		for ($li = 0; $li -lt $acLines.Count; $li++) {
			if ($li -eq 0) { $formXmlSb.Append("`t`t$($acLines[$li])") | Out-Null }
			else { $formXmlSb.Append("`t$($acLines[$li])") | Out-Null }
			$formXmlSb.Append("`r`n") | Out-Null
		}
	}

	$ciLines = $childItemsXml -split "`r`n"
	for ($li = 0; $li -lt $ciLines.Count; $li++) {
		if ($li -eq 0) { $formXmlSb.Append("`t`t$($ciLines[$li])") | Out-Null }
		else { $formXmlSb.Append("`t$($ciLines[$li])") | Out-Null }
		$formXmlSb.Append("`r`n") | Out-Null
	}

	$formXmlSb.Append("`t`t<Attributes/>") | Out-Null
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
	$sb.AppendLine("<MetaDataObject $($script:xmlnsDecl) version=`"2.17`">") | Out-Null
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
$borrowedFiles = @()
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
			$borrowedFiles += $targetFile
		}

		# Borrow the form
		$formFiles = Borrow-Form $typeName $objName $formName
		$borrowedFiles += $formFiles
		$borrowedCount++
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

		$borrowedFiles += $targetFile
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
foreach ($f in $borrowedFiles) {
	Write-Host "    - $f"
}
exit 0
