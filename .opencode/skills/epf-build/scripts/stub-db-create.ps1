# stub-db-create v1.0 — Create temp 1C infobase with metadata stubs for EPF/ERF build
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$SourceDir,

	[Parameter(Mandatory)]
	[string]$V8Path,

	[string]$TempBasePath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Scan XML files for reference types ---

$typeMap = @{}  # MetadataType -> @(Name1, Name2, ...)

$xmlFiles = Get-ChildItem -Path $SourceDir -Filter "*.xml" -Recurse -File
foreach ($f in $xmlFiles) {
	$content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)

	# Ref types: cfg:CatalogRef.XXX or d5p1:CatalogRef.XXX (and similar depth prefixes d4p1, d3p1, etc.)
	$refPattern = '(?:cfg:|d\dp1:)(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef)\.([A-Za-z\u0400-\u04FF\d_]+)'
	foreach ($m in [regex]::Matches($content, $refPattern)) {
		$prefix = $m.Groups[1].Value
		$name   = $m.Groups[2].Value
		$metaType = switch ($prefix) {
			"CatalogRef"                      { "Catalog" }
			"DocumentRef"                     { "Document" }
			"EnumRef"                         { "Enum" }
			"ChartOfAccountsRef"              { "ChartOfAccounts" }
			"ChartOfCharacteristicTypesRef"   { "ChartOfCharacteristicTypes" }
			"ChartOfCalculationTypesRef"      { "ChartOfCalculationTypes" }
			"ExchangePlanRef"                 { "ExchangePlan" }
			"BusinessProcessRef"              { "BusinessProcess" }
			"TaskRef"                         { "Task" }
		}
		if (-not $typeMap.ContainsKey($metaType)) { $typeMap[$metaType] = @{} }
		$typeMap[$metaType][$name] = $true
	}

	# Object types: cfg:CatalogObject.XXX etc.
	$objPattern = '(?:cfg:|d\dp1:)(CatalogObject|DocumentObject|ChartOfAccountsObject|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesObject|ExchangePlanObject|BusinessProcessObject|TaskObject)\.([A-Za-z\u0400-\u04FF\d_]+)'
	foreach ($m in [regex]::Matches($content, $objPattern)) {
		$prefix = $m.Groups[1].Value
		$name   = $m.Groups[2].Value
		$metaType = switch ($prefix) {
			"CatalogObject"                      { "Catalog" }
			"DocumentObject"                     { "Document" }
			"ChartOfAccountsObject"              { "ChartOfAccounts" }
			"ChartOfCharacteristicTypesObject"   { "ChartOfCharacteristicTypes" }
			"ChartOfCalculationTypesObject"      { "ChartOfCalculationTypes" }
			"ExchangePlanObject"                 { "ExchangePlan" }
			"BusinessProcessObject"              { "BusinessProcess" }
			"TaskObject"                         { "Task" }
		}
		if (-not $typeMap.ContainsKey($metaType)) { $typeMap[$metaType] = @{} }
		$typeMap[$metaType][$name] = $true
	}

	# RecordSet types: cfg:InformationRegisterRecordSet.XXX etc.
	$rsPattern = '(?:cfg:|d\dp1:)(InformationRegisterRecordSet|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|CalculationRegisterRecordSet)\.([A-Za-z\u0400-\u04FF\d_]+)'
	foreach ($m in [regex]::Matches($content, $rsPattern)) {
		$prefix = $m.Groups[1].Value
		$name   = $m.Groups[2].Value
		$metaType = switch ($prefix) {
			"InformationRegisterRecordSet"   { "InformationRegister" }
			"AccumulationRegisterRecordSet"  { "AccumulationRegister" }
			"AccountingRegisterRecordSet"    { "AccountingRegister" }
			"CalculationRegisterRecordSet"   { "CalculationRegister" }
		}
		if (-not $typeMap.ContainsKey($metaType)) { $typeMap[$metaType] = @{} }
		$typeMap[$metaType][$name] = $true
	}

	# Characteristic TypeSet: cfg:Characteristic.XXX
	$charPattern = 'cfg:Characteristic\.([A-Za-z\u0400-\u04FF\d_]+)'
	foreach ($m in [regex]::Matches($content, $charPattern)) {
		$name = $m.Groups[1].Value
		if (-not $typeMap.ContainsKey("ChartOfCharacteristicTypes")) { $typeMap["ChartOfCharacteristicTypes"] = @{} }
		$typeMap["ChartOfCharacteristicTypes"][$name] = $true
	}

	# DefinedType TypeSet: cfg:DefinedType.XXX
	$dtPattern = 'cfg:DefinedType\.([A-Za-z\u0400-\u04FF\d_]+)'
	foreach ($m in [regex]::Matches($content, $dtPattern)) {
		$name = $m.Groups[1].Value
		if (-not $typeMap.ContainsKey("DefinedType")) { $typeMap["DefinedType"] = @{} }
		$typeMap["DefinedType"][$name] = $true
	}
}

# --- 1b. Scan Form.xml for register record set columns ---
# When a form attribute has type like InformationRegisterRecordSet.XXX,
# the form references columns via DataPath "AttrName.ColumnName".
# We need to create matching dimensions/resources/attributes in stub registers.

$registerColumns = @{}  # "RegisterType.RegisterName" -> @{ col1=$true; col2=$true }

# Standard attributes that don't need explicit declaration
$stdRegCols = @("LineNumber","Period","Recorder","Active","RecordType")

foreach ($f in $xmlFiles) {
	$content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)

	# Find form attributes with register record set types using XmlDocument for reliability
	$regAttrMap = @{}  # formAttrName -> "RegisterType.RegisterName"

	# Only process Form.xml files (they contain <Attributes> with <Attribute> children)
	if ($f.Name -eq "Form.xml" -and $content -match '<Attributes>') {
		try {
			$xml = New-Object System.Xml.XmlDocument
			$xml.LoadXml($content)
			$nsMgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
			$nsMgr.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
			$nsMgr.AddNamespace("f", "http://v8.1c.ru/8.3/xcf/logform")
			$attrNodes = $xml.SelectNodes("//f:Attributes/f:Attribute", $nsMgr)
			foreach ($attrNode in $attrNodes) {
				$attrName = $attrNode.GetAttribute("name")
				$typeNodes = $attrNode.SelectNodes("f:Type/v8:Type", $nsMgr)
				foreach ($tn in $typeNodes) {
					$typeText = $tn.InnerText
					$rsMatch = [regex]::Match($typeText, '^(?:cfg:|d\dp1:)(InformationRegisterRecordSet|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|CalculationRegisterRecordSet)\.(.+)$')
					if ($rsMatch.Success) {
						$rsPrefix = $rsMatch.Groups[1].Value
						$regName = $rsMatch.Groups[2].Value
						$regType = switch ($rsPrefix) {
							"InformationRegisterRecordSet"   { "InformationRegister" }
							"AccumulationRegisterRecordSet"  { "AccumulationRegister" }
							"AccountingRegisterRecordSet"    { "AccountingRegister" }
							"CalculationRegisterRecordSet"   { "CalculationRegister" }
						}
						$regKey = "$regType.$regName"
						$regAttrMap[$attrName] = $regKey
						if (-not $registerColumns.ContainsKey($regKey)) {
							$registerColumns[$regKey] = @{}
						}
					}
				}
			}
		} catch {
			# XML parse failed, skip
		}
	}

	# Now find DataPath references like "AttrName.ColumnName"
	if ($regAttrMap.Count -gt 0) {
		$dpPattern = '<DataPath>([A-Za-z\u0400-\u04FF\d_]+)\.([A-Za-z\u0400-\u04FF\d_]+)</DataPath>'
		foreach ($m in [regex]::Matches($content, $dpPattern)) {
			$attrName = $m.Groups[1].Value
			$colName = $m.Groups[2].Value
			if ($regAttrMap.ContainsKey($attrName) -and $colName -notin $stdRegCols) {
				$regKey = $regAttrMap[$attrName]
				$registerColumns[$regKey][$colName] = $true
			}
		}
	}
}

$hasRefTypes = $typeMap.Count -gt 0

# --- 2. Determine TempBasePath ---
if (-not $TempBasePath) {
	$TempBasePath = Join-Path $env:TEMP "epf_stub_db_$(Get-Random)"
}

# --- 3. If registers need a registrator, add stub document ---
$registratorTypes = @("AccumulationRegister","AccountingRegister","CalculationRegister")
$needsRegistrator = $false
foreach ($rt in $registratorTypes) {
	if ($typeMap.ContainsKey($rt) -and $typeMap[$rt].Count -gt 0) {
		$needsRegistrator = $true
		break
	}
}
if ($needsRegistrator) {
	if (-not $typeMap.ContainsKey("Document")) { $typeMap["Document"] = @{} }
	$typeMap["Document"]["ЗаглушкаРегистратора"] = $true
}

# --- 4. Generate configuration XML ---

if ($hasRefTypes) {
	$enc = New-Object System.Text.UTF8Encoding($true)
	$cfgDir = Join-Path $TempBasePath "cfg"
	New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null

	$ns = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17"'

	# GeneratedType definitions per metadata type
	$gtDefs = @{
		"Catalog" = @(
			@{p="CatalogObject";c="Object"},@{p="CatalogRef";c="Ref"},@{p="CatalogSelection";c="Selection"},
			@{p="CatalogList";c="List"},@{p="CatalogManager";c="Manager"}
		)
		"Document" = @(
			@{p="DocumentObject";c="Object"},@{p="DocumentRef";c="Ref"},@{p="DocumentSelection";c="Selection"},
			@{p="DocumentList";c="List"},@{p="DocumentManager";c="Manager"}
		)
		"Enum" = @(
			@{p="EnumRef";c="Ref"},@{p="EnumManager";c="Manager"},@{p="EnumList";c="List"}
		)
		"ChartOfAccounts" = @(
			@{p="ChartOfAccountsObject";c="Object"},@{p="ChartOfAccountsRef";c="Ref"},@{p="ChartOfAccountsSelection";c="Selection"},
			@{p="ChartOfAccountsList";c="List"},@{p="ChartOfAccountsManager";c="Manager"}
		)
		"ChartOfCharacteristicTypes" = @(
			@{p="ChartOfCharacteristicTypesObject";c="Object"},@{p="ChartOfCharacteristicTypesRef";c="Ref"},@{p="ChartOfCharacteristicTypesSelection";c="Selection"},
			@{p="ChartOfCharacteristicTypesList";c="List"},@{p="Characteristic";c="Characteristic"},@{p="ChartOfCharacteristicTypesManager";c="Manager"}
		)
		"ChartOfCalculationTypes" = @(
			@{p="ChartOfCalculationTypesObject";c="Object"},@{p="ChartOfCalculationTypesRef";c="Ref"},@{p="ChartOfCalculationTypesSelection";c="Selection"},
			@{p="ChartOfCalculationTypesList";c="List"},@{p="ChartOfCalculationTypesManager";c="Manager"}
		)
		"ExchangePlan" = @(
			@{p="ExchangePlanObject";c="Object"},@{p="ExchangePlanRef";c="Ref"},@{p="ExchangePlanSelection";c="Selection"},
			@{p="ExchangePlanList";c="List"},@{p="ExchangePlanManager";c="Manager"}
		)
		"BusinessProcess" = @(
			@{p="BusinessProcessObject";c="Object"},@{p="BusinessProcessRef";c="Ref"},@{p="BusinessProcessSelection";c="Selection"},
			@{p="BusinessProcessList";c="List"},@{p="BusinessProcessManager";c="Manager"}
		)
		"Task" = @(
			@{p="TaskObject";c="Object"},@{p="TaskRef";c="Ref"},@{p="TaskSelection";c="Selection"},
			@{p="TaskList";c="List"},@{p="TaskManager";c="Manager"}
		)
		"InformationRegister" = @(
			@{p="InformationRegisterRecord";c="Record"},@{p="InformationRegisterManager";c="Manager"},
			@{p="InformationRegisterSelection";c="Selection"},@{p="InformationRegisterList";c="List"},
			@{p="InformationRegisterRecordSet";c="RecordSet"},@{p="InformationRegisterRecordKey";c="RecordKey"},
			@{p="InformationRegisterRecordManager";c="RecordManager"}
		)
		"AccumulationRegister" = @(
			@{p="AccumulationRegisterRecord";c="Record"},@{p="AccumulationRegisterManager";c="Manager"},
			@{p="AccumulationRegisterSelection";c="Selection"},@{p="AccumulationRegisterList";c="List"},
			@{p="AccumulationRegisterRecordSet";c="RecordSet"},@{p="AccumulationRegisterRecordKey";c="RecordKey"}
		)
		"AccountingRegister" = @(
			@{p="AccountingRegisterRecord";c="Record"},@{p="AccountingRegisterManager";c="Manager"},
			@{p="AccountingRegisterSelection";c="Selection"},@{p="AccountingRegisterExtDimensions";c="ExtDimensions"},
			@{p="AccountingRegisterList";c="List"},@{p="AccountingRegisterRecordSet";c="RecordSet"},
			@{p="AccountingRegisterRecordKey";c="RecordKey"}
		)
		"CalculationRegister" = @(
			@{p="CalculationRegisterRecord";c="Record"},@{p="CalculationRegisterManager";c="Manager"},
			@{p="CalculationRegisterSelection";c="Selection"},@{p="CalculationRegisterList";c="List"},
			@{p="CalculationRegisterRecordSet";c="RecordSet"},@{p="CalculationRegisterRecordKey";c="RecordKey"}
		)
		"DefinedType" = @(
			@{p="DefinedType";c="DefinedType"}
		)
	}

	# Metadata type -> XML tag and directory
	$metaInfo = @{
		"Catalog"                      = @{tag="Catalog";dir="Catalogs"}
		"Document"                     = @{tag="Document";dir="Documents"}
		"Enum"                         = @{tag="Enum";dir="Enums"}
		"ChartOfAccounts"              = @{tag="ChartOfAccounts";dir="ChartsOfAccounts"}
		"ChartOfCharacteristicTypes"   = @{tag="ChartOfCharacteristicTypes";dir="ChartsOfCharacteristicTypes"}
		"ChartOfCalculationTypes"      = @{tag="ChartOfCalculationTypes";dir="ChartsOfCalculationTypes"}
		"ExchangePlan"                 = @{tag="ExchangePlan";dir="ExchangePlans"}
		"BusinessProcess"              = @{tag="BusinessProcess";dir="BusinessProcesses"}
		"Task"                         = @{tag="Task";dir="Tasks"}
		"InformationRegister"          = @{tag="InformationRegister";dir="InformationRegisters"}
		"AccumulationRegister"         = @{tag="AccumulationRegister";dir="AccumulationRegisters"}
		"AccountingRegister"           = @{tag="AccountingRegister";dir="AccountingRegisters"}
		"CalculationRegister"          = @{tag="CalculationRegister";dir="CalculationRegisters"}
		"DefinedType"                  = @{tag="DefinedType";dir="DefinedTypes"}
	}

	# StandardAttribute boilerplate
	$stdAttrXml = @'
				<xr:LinkByType/>
				<xr:FillChecking>DontCheck</xr:FillChecking>
				<xr:MultiLine>false</xr:MultiLine>
				<xr:FillFromFillingValue>false</xr:FillFromFillingValue>
				<xr:CreateOnInput>Auto</xr:CreateOnInput>
				<xr:MaxValue xsi:nil="true"/>
				<xr:ToolTip/>
				<xr:ExtendedEdit>false</xr:ExtendedEdit>
				<xr:Format/>
				<xr:ChoiceForm/>
				<xr:QuickChoice>Auto</xr:QuickChoice>
				<xr:ChoiceHistoryOnInput>Auto</xr:ChoiceHistoryOnInput>
				<xr:EditFormat/>
				<xr:PasswordMode>false</xr:PasswordMode>
				<xr:DataHistory>Use</xr:DataHistory>
				<xr:MarkNegatives>false</xr:MarkNegatives>
				<xr:MinValue xsi:nil="true"/>
				<xr:Synonym/>
				<xr:Comment/>
				<xr:FullTextSearch>Use</xr:FullTextSearch>
				<xr:ChoiceParameterLinks/>
				<xr:FillValue xsi:nil="true"/>
				<xr:Mask/>
				<xr:ChoiceParameters/>
'@

	$stdAttrsByType = @{
		"Catalog" = @("PredefinedDataName","Predefined","Ref","DeletionMark","IsFolder","Owner","Parent","Description","Code")
		"Document" = @("Posted","Ref","DeletionMark","Date","Number")
		"Enum" = @("Order","Ref")
		"ChartOfAccounts" = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","Parent","Order","Type","OffBalance")
		"ChartOfCharacteristicTypes" = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","Parent","ValueType")
		"ChartOfCalculationTypes" = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","ActionPeriodIsBasic")
		"ExchangePlan" = @("Ref","DeletionMark","Code","Description","ThisNode","SentNo","ReceivedNo")
		"BusinessProcess" = @("Ref","DeletionMark","Date","Number","Started","Completed","HeadTask")
		"Task" = @("Ref","DeletionMark","Date","Number","Executed","Description","RoutePoint","BusinessProcess")
		"InformationRegister" = @("Active","LineNumber","Recorder","Period")
		"AccumulationRegister" = @("Active","LineNumber","Recorder","Period")
		"AccountingRegister" = @("Active","Period","Recorder","LineNumber","Account")
		"CalculationRegister" = @("Active","Recorder","LineNumber","RegistrationPeriod","CalculationType","ReversingEntry")
	}

	function Build-StdAttrs([string]$metaType) {
		$attrs = $stdAttrsByType[$metaType]
		if (-not $attrs) { return "" }
		$sb = New-Object System.Text.StringBuilder
		$sb.AppendLine("`t`t`t<StandardAttributes>") | Out-Null
		foreach ($a in $attrs) {
			$sb.AppendLine("`t`t`t`t<xr:StandardAttribute name=`"$a`">") | Out-Null
			$sb.AppendLine($stdAttrXml) | Out-Null
			$sb.AppendLine("`t`t`t`t</xr:StandardAttribute>") | Out-Null
		}
		$sb.AppendLine("`t`t`t</StandardAttributes>") | Out-Null
		return $sb.ToString()
	}

	# --- 4a. Configuration.xml ---
	$uuidCfg = [guid]::NewGuid().ToString()
	$uuidLang = [guid]::NewGuid().ToString()

	$coIds = @()
	for ($i = 0; $i -lt 7; $i++) { $coIds += [guid]::NewGuid().ToString() }
	$classIds = @(
		"9cd510cd-abfc-11d4-9434-004095e12fc7",
		"9fcd25a0-4822-11d4-9414-008048da11f9",
		"e3687481-0a87-462c-a166-9f34594f9bba",
		"9de14907-ec23-4a07-96f0-85521cb6b53b",
		"51f2d5d8-ea4d-4064-8892-82951750031e",
		"e68182ea-4237-4383-967f-90c1e3370bc7",
		"fb282519-d103-4dd3-bc12-cb271d631dfc"
	)

	$coXml = ""
	for ($i = 0; $i -lt 7; $i++) {
		$coXml += "`r`n`t`t`t<xr:ContainedObject>`r`n`t`t`t`t<xr:ClassId>$($classIds[$i])</xr:ClassId>`r`n`t`t`t`t<xr:ObjectId>$($coIds[$i])</xr:ObjectId>`r`n`t`t`t</xr:ContainedObject>"
	}

	# ChildObjects entries
	$childXml = "`r`n`t`t`t<Language>Русский</Language>"
	foreach ($metaType in $typeMap.Keys) {
		if (-not $metaInfo.ContainsKey($metaType)) { continue }
		$tag = $metaInfo[$metaType].tag
		foreach ($name in $typeMap[$metaType].Keys) {
			$childXml += "`r`n`t`t`t<$tag>$name</$tag>"
		}
	}

	$cfgXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject $ns>
	<Configuration uuid="$uuidCfg">
		<InternalInfo>$coXml
		</InternalInfo>
		<Properties>
			<Name>StubConfig</Name>
			<Synonym/>
			<Comment/>
			<NamePrefix/>
			<ConfigurationExtensionCompatibilityMode>Version8_3_24</ConfigurationExtensionCompatibilityMode>
			<DefaultRunMode>ManagedApplication</DefaultRunMode>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
			</UsePurposes>
			<ScriptVariant>Russian</ScriptVariant>
			<DefaultRoles/>
			<Vendor/>
			<Version/>
			<UpdateCatalogAddress/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<UseManagedFormInOrdinaryApplication>false</UseManagedFormInOrdinaryApplication>
			<UseOrdinaryFormInManagedApplication>false</UseOrdinaryFormInManagedApplication>
			<AdditionalFullTextSearchDictionaries/>
			<CommonSettingsStorage/>
			<ReportsUserSettingsStorage/>
			<ReportsVariantsStorage/>
			<FormDataSettingsStorage/>
			<DynamicListsUserSettingsStorage/>
			<URLExternalDataStorage/>
			<Content/>
			<DefaultReportForm/>
			<DefaultReportVariantForm/>
			<DefaultReportSettingsForm/>
			<DefaultReportAppearanceTemplate/>
			<DefaultDynamicListSettingsForm/>
			<DefaultSearchForm/>
			<DefaultDataHistoryChangeHistoryForm/>
			<DefaultDataHistoryVersionDataForm/>
			<DefaultDataHistoryVersionDifferencesForm/>
			<DefaultCollaborationSystemUsersChoiceForm/>
			<RequiredMobileApplicationPermissions/>
			<UsedMobileApplicationFunctionalities/>
			<StandaloneConfigurationRestrictionRoles/>
			<MobileApplicationURLs/>
			<AllowedIncomingShareRequestTypes/>
			<MainClientApplicationWindowMode>Normal</MainClientApplicationWindowMode>
			<DefaultInterface/>
			<DefaultStyle/>
			<DefaultLanguage>Language.Русский</DefaultLanguage>
			<BriefInformation/>
			<DetailedInformation/>
			<Copyright/>
			<VendorInformationAddress/>
			<ConfigurationInformationAddress/>
			<DataLockControlMode>Managed</DataLockControlMode>
			<ObjectAutonumerationMode>NotAutoFree</ObjectAutonumerationMode>
			<ModalityUseMode>DontUse</ModalityUseMode>
			<SynchronousPlatformExtensionAndAddInCallUseMode>DontUse</SynchronousPlatformExtensionAndAddInCallUseMode>
			<InterfaceCompatibilityMode>Taxi</InterfaceCompatibilityMode>
			<DatabaseTablespacesUseMode>DontUse</DatabaseTablespacesUseMode>
			<CompatibilityMode>Version8_3_24</CompatibilityMode>
			<DefaultConstantsForm/>
		</Properties>
		<ChildObjects>$childXml
		</ChildObjects>
	</Configuration>
</MetaDataObject>
"@

	[System.IO.File]::WriteAllText((Join-Path $cfgDir "Configuration.xml"), $cfgXml, $enc)

	# --- 4b. Language ---
	$langDir = Join-Path $cfgDir "Languages"
	New-Item -ItemType Directory -Path $langDir -Force | Out-Null

	$langXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject $ns>
	<Language uuid="$uuidLang">
		<Properties>
			<Name>Русский</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>Русский</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<LanguageCode>ru</LanguageCode>
		</Properties>
	</Language>
</MetaDataObject>
"@
	[System.IO.File]::WriteAllText((Join-Path $langDir "Русский.xml"), $langXml, $enc)

	# --- 4c. Metadata object stubs ---
	foreach ($metaType in $typeMap.Keys) {
		if (-not $metaInfo.ContainsKey($metaType)) { continue }
		$info = $metaInfo[$metaType]
		$objDir = Join-Path $cfgDir $info.dir
		New-Item -ItemType Directory -Path $objDir -Force | Out-Null

		foreach ($objName in $typeMap[$metaType].Keys) {
			$uuid = [guid]::NewGuid().ToString()

			# InternalInfo with GeneratedTypes
			$internalXml = ""
			$gts = $gtDefs[$metaType]
			if ($gts) {
				$internalXml = "`r`n`t`t<InternalInfo>"
				if ($metaType -eq "ExchangePlan") {
					$internalXml += "`r`n`t`t`t<xr:ThisNode>$([guid]::NewGuid().ToString())</xr:ThisNode>"
				}
				foreach ($gt in $gts) {
					$fullName = "$($gt.p).$objName"
					$tid = [guid]::NewGuid().ToString()
					$vid = [guid]::NewGuid().ToString()
					$internalXml += "`r`n`t`t`t<xr:GeneratedType name=`"$fullName`" category=`"$($gt.c)`">"
					$internalXml += "`r`n`t`t`t`t<xr:TypeId>$tid</xr:TypeId>"
					$internalXml += "`r`n`t`t`t`t<xr:ValueId>$vid</xr:ValueId>"
					$internalXml += "`r`n`t`t`t</xr:GeneratedType>"
				}
				$internalXml += "`r`n`t`t</InternalInfo>"
			}

			# Properties + ChildObjects depending on type
			$propsXml = ""
			$childObjXml = ""

			switch ($metaType) {
				"Catalog" {
					$stdAttrs = Build-StdAttrs "Catalog"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<Hierarchical>false</Hierarchical>
			<HierarchyType>HierarchyFoldersAndItems</HierarchyType>
			<LimitLevelCount>false</LimitLevelCount>
			<LevelCount>2</LevelCount>
			<FoldersOnTop>true</FoldersOnTop>
			<UseStandardCommands>false</UseStandardCommands>
			<Owners/>
			<SubordinationUse>ToItems</SubordinationUse>
			<CodeLength>9</CodeLength>
			<DescriptionLength>25</DescriptionLength>
			<CodeType>String</CodeType>
			<CodeAllowedLength>Variable</CodeAllowedLength>
			<CodeSeries>WholeCatalog</CodeSeries>
			<CheckUnique>false</CheckUnique>
			<Autonumbering>true</Autonumbering>
			<DefaultPresentation>AsDescription</DefaultPresentation>
$stdAttrs			<Characteristics/>
			<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
			<EditType>InDialog</EditType>
			<QuickChoice>true</QuickChoice>
			<ChoiceMode>BothWays</ChoiceMode>
			<InputByString/>
			<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
			<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
			<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
			<DefaultObjectForm/>
			<DefaultFolderForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<DefaultFolderChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryFolderForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<AuxiliaryFolderChoiceForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<BasedOn/>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<CreateOnInput>DontUse</CreateOnInput>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"Document" {
					$stdAttrs = Build-StdAttrs "Document"
					$regRecordsXml = "<RegisterRecords/>"
					# If this is the stub registrator, set register records
					if ($objName -eq "ЗаглушкаРегистратора") {
						$rrLines = @()
						foreach ($rt in $registratorTypes) {
							if ($typeMap.ContainsKey($rt) -and $typeMap[$rt].Count -gt 0) {
								foreach ($rn in $typeMap[$rt].Keys) {
									$rrLines += "`t`t`t`t<xr:Item xsi:type=`"xr:MDObjectRef`">$rt.$rn</xr:Item>"
								}
							}
						}
						if ($rrLines.Count -gt 0) {
							$regRecordsXml = "<RegisterRecords>`r`n$($rrLines -join "`r`n")`r`n`t`t`t</RegisterRecords>"
						}
					}
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<Numerator/>
			<NumberType>String</NumberType>
			<NumberLength>11</NumberLength>
			<NumberAllowedLength>Variable</NumberAllowedLength>
			<NumberPeriodicity>Year</NumberPeriodicity>
			<CheckUnique>false</CheckUnique>
			<Autonumbering>true</Autonumbering>
$stdAttrs			<Characteristics/>
			<BasedOn/>
			<InputByString/>
			<CreateOnInput>DontUse</CreateOnInput>
			<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
			<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
			<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
			<DefaultObjectForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<Posting>Allow</Posting>
			<RealTimePosting>Deny</RealTimePosting>
			<RegisterRecordsDeletion>AutoDelete</RegisterRecordsDeletion>
			<RegisterRecordsWritingOnPost>WriteModified</RegisterRecordsWritingOnPost>
			<SequenceFilling>AutoFill</SequenceFilling>
			$regRecordsXml
			<PostInPrivilegedMode>true</PostInPrivilegedMode>
			<UnpostInPrivilegedMode>true</UnpostInPrivilegedMode>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"Enum" {
					$stdAttrs = Build-StdAttrs "Enum"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
$stdAttrs			<Characteristics/>
			<QuickChoice>true</QuickChoice>
			<ChoiceMode>BothWays</ChoiceMode>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
"@
				}
				"InformationRegister" {
					$stdAttrs = Build-StdAttrs "InformationRegister"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<EditType>InDialog</EditType>
			<DefaultRecordForm/>
			<DefaultListForm/>
			<AuxiliaryRecordForm/>
			<AuxiliaryListForm/>
$stdAttrs			<InformationRegisterPeriodicity>Nonperiodical</InformationRegisterPeriodicity>
			<WriteMode>Independent</WriteMode>
			<MainFilterOnPeriod>false</MainFilterOnPeriod>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<EnableTotalsSliceFirst>false</EnableTotalsSliceFirst>
			<EnableTotalsSliceLast>false</EnableTotalsSliceLast>
			<RecordPresentation/>
			<ExtendedRecordPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"AccumulationRegister" {
					$stdAttrs = Build-StdAttrs "AccumulationRegister"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<DefaultListForm/>
			<AuxiliaryListForm/>
			<RegisterType>Balance</RegisterType>
			<IncludeHelpInContents>false</IncludeHelpInContents>
$stdAttrs			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<EnableTotalsSplitting>true</EnableTotalsSplitting>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
"@
				}
				"AccountingRegister" {
					$stdAttrs = Build-StdAttrs "AccountingRegister"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<DefaultListForm/>
			<AuxiliaryListForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<ChartOfAccounts/>
			<Correspondence>false</Correspondence>
$stdAttrs			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<EnableTotalsSplitting>true</EnableTotalsSplitting>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
"@
				}
				"CalculationRegister" {
					$stdAttrs = Build-StdAttrs "CalculationRegister"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<DefaultListForm/>
			<AuxiliaryListForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<ChartOfCalculationTypes/>
$stdAttrs			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
"@
				}
				"ChartOfAccounts" {
					$stdAttrs = Build-StdAttrs "ChartOfAccounts"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<CodeMask/>
			<CodeLength>20</CodeLength>
			<DescriptionLength>100</DescriptionLength>
			<CodeSeries>WholeCatalog</CodeSeries>
			<CheckUnique>false</CheckUnique>
			<Autonumbering>true</Autonumbering>
			<DefaultPresentation>AsDescription</DefaultPresentation>
$stdAttrs			<Characteristics/>
			<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
			<EditType>InDialog</EditType>
			<QuickChoice>true</QuickChoice>
			<ChoiceMode>BothWays</ChoiceMode>
			<InputByString/>
			<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
			<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
			<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
			<DefaultObjectForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<DefaultFolderForm/>
			<DefaultFolderChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<AuxiliaryFolderForm/>
			<AuxiliaryFolderChoiceForm/>
			<AutoOrderByCode>true</AutoOrderByCode>
			<OrderLength>5</OrderLength>
			<MaxExtDimensionCount>0</MaxExtDimensionCount>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<BasedOn/>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<CreateOnInput>DontUse</CreateOnInput>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"ChartOfCharacteristicTypes" {
					$stdAttrs = Build-StdAttrs "ChartOfCharacteristicTypes"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<CodeLength>9</CodeLength>
			<CodeAllowedLength>Variable</CodeAllowedLength>
			<DescriptionLength>25</DescriptionLength>
			<CheckUnique>false</CheckUnique>
			<Autonumbering>true</Autonumbering>
			<DefaultPresentation>AsDescription</DefaultPresentation>
			<CharacteristicExtValues/>
			<Type>
				<v8:Type>xs:boolean</v8:Type>
				<v8:Type>xs:string</v8:Type>
				<v8:StringQualifiers>
					<v8:Length>0</v8:Length>
					<v8:AllowedLength>Variable</v8:AllowedLength>
				</v8:StringQualifiers>
				<v8:Type>xs:decimal</v8:Type>
				<v8:NumberQualifiers>
					<v8:Digits>15</v8:Digits>
					<v8:FractionDigits>2</v8:FractionDigits>
					<v8:AllowedSign>Any</v8:AllowedSign>
				</v8:NumberQualifiers>
				<v8:Type>xs:dateTime</v8:Type>
				<v8:DateQualifiers>
					<v8:DateFractions>DateTime</v8:DateFractions>
				</v8:DateQualifiers>
			</Type>
			<Hierarchical>false</Hierarchical>
			<FoldersOnTop>true</FoldersOnTop>
$stdAttrs			<Characteristics/>
			<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
			<EditType>InDialog</EditType>
			<QuickChoice>true</QuickChoice>
			<ChoiceMode>BothWays</ChoiceMode>
			<InputByString/>
			<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
			<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
			<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
			<DefaultObjectForm/>
			<DefaultFolderForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<DefaultFolderChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryFolderForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<AuxiliaryFolderChoiceForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<BasedOn/>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<CreateOnInput>DontUse</CreateOnInput>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"ChartOfCalculationTypes" {
					$stdAttrs = Build-StdAttrs "ChartOfCalculationTypes"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<CodeLength>9</CodeLength>
			<DescriptionLength>25</DescriptionLength>
			<CodeType>String</CodeType>
			<CodeAllowedLength>Variable</CodeAllowedLength>
			<CodeSeries>WholeCatalog</CodeSeries>
			<CheckUnique>false</CheckUnique>
			<Autonumbering>true</Autonumbering>
			<DefaultPresentation>AsDescription</DefaultPresentation>
$stdAttrs			<Characteristics/>
			<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
			<EditType>InDialog</EditType>
			<QuickChoice>true</QuickChoice>
			<ChoiceMode>BothWays</ChoiceMode>
			<InputByString/>
			<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
			<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
			<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
			<DependenceOnCalculationTypes>NotDepend</DependenceOnCalculationTypes>
			<BaseCalculationTypes/>
			<ActionPeriodUse>false</ActionPeriodUse>
			<DefaultObjectForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<BasedOn/>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<CreateOnInput>DontUse</CreateOnInput>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"ExchangePlan" {
					$stdAttrs = Build-StdAttrs "ExchangePlan"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<CodeLength>9</CodeLength>
			<DescriptionLength>25</DescriptionLength>
			<CodeAllowedLength>Variable</CodeAllowedLength>
$stdAttrs			<DefaultPresentation>AsDescription</DefaultPresentation>
			<Characteristics/>
			<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
			<EditType>InDialog</EditType>
			<QuickChoice>true</QuickChoice>
			<ChoiceMode>BothWays</ChoiceMode>
			<InputByString/>
			<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
			<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
			<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
			<DefaultObjectForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<BasedOn/>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<CreateOnInput>DontUse</CreateOnInput>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DistributedInfoBase>false</DistributedInfoBase>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"BusinessProcess" {
					$stdAttrs = Build-StdAttrs "BusinessProcess"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<Numerator/>
			<NumberType>String</NumberType>
			<NumberLength>11</NumberLength>
			<NumberAllowedLength>Variable</NumberAllowedLength>
			<NumberPeriodicity>Year</NumberPeriodicity>
			<CheckUnique>false</CheckUnique>
			<Autonumbering>true</Autonumbering>
$stdAttrs			<Characteristics/>
			<Task/>
			<CreateTaskInPrivilegedMode>false</CreateTaskInPrivilegedMode>
			<DefaultObjectForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<BasedOn/>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"Task" {
					$stdAttrs = Build-StdAttrs "Task"
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<UseStandardCommands>false</UseStandardCommands>
			<Numerator/>
			<NumberType>String</NumberType>
			<NumberLength>11</NumberLength>
			<NumberAllowedLength>Variable</NumberAllowedLength>
			<NumberPeriodicity>Year</NumberPeriodicity>
			<CheckUnique>false</CheckUnique>
			<Autonumbering>true</Autonumbering>
			<DescriptionLength>25</DescriptionLength>
$stdAttrs			<Characteristics/>
			<InputByString/>
			<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
			<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
			<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
			<DefaultObjectForm/>
			<DefaultListForm/>
			<DefaultChoiceForm/>
			<AuxiliaryObjectForm/>
			<AuxiliaryListForm/>
			<AuxiliaryChoiceForm/>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<BasedOn/>
			<DataLockFields/>
			<DataLockControlMode>Automatic</DataLockControlMode>
			<FullTextSearch>Use</FullTextSearch>
			<ObjectPresentation/>
			<ExtendedObjectPresentation/>
			<ListPresentation/>
			<ExtendedListPresentation/>
			<Explanation/>
			<Addressing/>
			<MainAddressingAttribute/>
			<CurrentUserAlias/>
			<CurrentUserValue/>
			<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
			<DataHistory>DontUse</DataHistory>
			<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
			<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>
"@
				}
				"DefinedType" {
					$propsXml = @"
			<Name>$objName</Name>
			<Synonym/>
			<Comment/>
			<Type>
				<v8:Type>xs:string</v8:Type>
				<v8:StringQualifiers>
					<v8:Length>0</v8:Length>
					<v8:AllowedLength>Variable</v8:AllowedLength>
				</v8:StringQualifiers>
			</Type>
"@
				}
			}

			$childObjLine = "`n`t`t<ChildObjects/>"
		if ($metaType -eq "DefinedType") {
			$childObjLine = ""
		} elseif ($metaType -eq "InformationRegister") {
			# Check if we have actual column names from form scanning
			$regKey = "InformationRegister.$objName"
			$cols = if ($registerColumns.ContainsKey($regKey) -and $registerColumns[$regKey].Count -gt 0) {
				$registerColumns[$regKey].Keys
			} else {
				@("Заглушка")
			}
			# First column as Dimension (for MainFilter), rest as Attributes (no index pressure)
			$dimXmlParts = @()
			$isFirst = $true
			foreach ($colName in $cols) {
				$elemUuid = [guid]::NewGuid().ToString()
				if ($isFirst) {
					$dimXmlParts += @"
			<Dimension uuid="$elemUuid">
				<Properties>
					<Name>$colName</Name>
					<Synonym/>
					<Comment/>
					<Type>
						<v8:Type>xs:string</v8:Type>
						<v8:StringQualifiers>
							<v8:Length>10</v8:Length>
							<v8:AllowedLength>Variable</v8:AllowedLength>
						</v8:StringQualifiers>
					</Type>
					<PasswordMode>false</PasswordMode>
					<Format/>
					<EditFormat/>
					<ToolTip/>
					<MarkNegatives>false</MarkNegatives>
					<Mask/>
					<MultiLine>false</MultiLine>
					<ExtendedEdit>false</ExtendedEdit>
					<MinValue xsi:nil="true"/>
					<MaxValue xsi:nil="true"/>
					<FillFromFillingValue>false</FillFromFillingValue>
					<FillValue xsi:nil="true"/>
					<FillChecking>DontCheck</FillChecking>
					<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>
					<ChoiceParameterLinks/>
					<ChoiceParameters/>
					<QuickChoice>Auto</QuickChoice>
					<CreateOnInput>Auto</CreateOnInput>
					<ChoiceForm/>
					<LinkByType/>
					<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
					<Master>false</Master>
					<MainFilter>true</MainFilter>
					<DenyIncompleteValues>false</DenyIncompleteValues>
					<Indexing>DontIndex</Indexing>
					<FullTextSearch>Use</FullTextSearch>
					<DataHistory>Use</DataHistory>
				</Properties>
			</Dimension>
"@
					$isFirst = $false
				} else {
					$dimXmlParts += @"
			<Attribute uuid="$elemUuid">
				<Properties>
					<Name>$colName</Name>
					<Synonym/>
					<Comment/>
					<Type>
						<v8:Type>xs:string</v8:Type>
						<v8:StringQualifiers>
							<v8:Length>10</v8:Length>
							<v8:AllowedLength>Variable</v8:AllowedLength>
						</v8:StringQualifiers>
					</Type>
					<PasswordMode>false</PasswordMode>
					<Format/>
					<EditFormat/>
					<ToolTip/>
					<MarkNegatives>false</MarkNegatives>
					<Mask/>
					<MultiLine>false</MultiLine>
					<ExtendedEdit>false</ExtendedEdit>
					<MinValue xsi:nil="true"/>
					<MaxValue xsi:nil="true"/>
					<FillFromFillingValue>false</FillFromFillingValue>
					<FillValue xsi:nil="true"/>
					<FillChecking>DontCheck</FillChecking>
					<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>
					<ChoiceParameterLinks/>
					<ChoiceParameters/>
					<QuickChoice>Auto</QuickChoice>
					<CreateOnInput>Auto</CreateOnInput>
					<ChoiceForm/>
					<LinkByType/>
					<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
					<FullTextSearch>Use</FullTextSearch>
				</Properties>
			</Attribute>
"@
				}
			}
			$childObjLine = "`r`n`t`t<ChildObjects>`r`n$($dimXmlParts -join "`r`n")`r`n`t`t</ChildObjects>"
		} elseif ($metaType -in @("AccumulationRegister","AccountingRegister","CalculationRegister")) {
			# Check if we have actual column names from form scanning
			$regKey = "$metaType.$objName"
			$cols = if ($registerColumns.ContainsKey($regKey) -and $registerColumns[$regKey].Count -gt 0) {
				$registerColumns[$regKey].Keys
			} else {
				@()
			}
			$childParts = @()
			# AccumulationRegister requires at least one Resource
			$stubResUuid = [guid]::NewGuid().ToString()
			$childParts += @"
			<Resource uuid="$stubResUuid">
				<Properties>
					<Name>Заглушка</Name>
					<Synonym/>
					<Comment/>
					<Type>
						<v8:Type>xs:decimal</v8:Type>
						<v8:NumberQualifiers>
							<v8:Digits>15</v8:Digits>
							<v8:FractionDigits>2</v8:FractionDigits>
							<v8:AllowedSign>Any</v8:AllowedSign>
						</v8:NumberQualifiers>
					</Type>
					<PasswordMode>false</PasswordMode>
					<Format/>
					<EditFormat/>
					<ToolTip/>
					<MarkNegatives>false</MarkNegatives>
					<Mask/>
					<MultiLine>false</MultiLine>
					<ExtendedEdit>false</ExtendedEdit>
					<MinValue xsi:nil="true"/>
					<MaxValue xsi:nil="true"/>
					<FillChecking>DontCheck</FillChecking>
					<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>
					<ChoiceParameterLinks/>
					<ChoiceParameters/>
					<QuickChoice>Auto</QuickChoice>
					<CreateOnInput>Auto</CreateOnInput>
					<ChoiceForm/>
					<LinkByType/>
					<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
					<FullTextSearch>Use</FullTextSearch>
				</Properties>
			</Resource>
"@
			# Add all form-referenced columns as Dimensions (short strings to avoid index overflow)
			foreach ($colName in $cols) {
				$dimUuid = [guid]::NewGuid().ToString()
				$childParts += @"
			<Dimension uuid="$dimUuid">
				<Properties>
					<Name>$colName</Name>
					<Synonym/>
					<Comment/>
					<Type>
						<v8:Type>xs:string</v8:Type>
						<v8:StringQualifiers>
							<v8:Length>10</v8:Length>
							<v8:AllowedLength>Variable</v8:AllowedLength>
						</v8:StringQualifiers>
					</Type>
					<PasswordMode>false</PasswordMode>
					<Format/>
					<EditFormat/>
					<ToolTip/>
					<MarkNegatives>false</MarkNegatives>
					<Mask/>
					<MultiLine>false</MultiLine>
					<ExtendedEdit>false</ExtendedEdit>
					<MinValue xsi:nil="true"/>
					<MaxValue xsi:nil="true"/>
					<FillChecking>DontCheck</FillChecking>
					<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>
					<ChoiceParameterLinks/>
					<ChoiceParameters/>
					<QuickChoice>Auto</QuickChoice>
					<CreateOnInput>Auto</CreateOnInput>
					<ChoiceForm/>
					<LinkByType/>
					<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
					<FullTextSearch>Use</FullTextSearch>
				</Properties>
			</Dimension>
"@
			}
			$childObjLine = "`r`n`t`t<ChildObjects>`r`n$($childParts -join "`r`n")`r`n`t`t</ChildObjects>"
		}
		$objXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject $ns>
	<$($info.tag) uuid="$uuid">$internalXml
		<Properties>
$propsXml		</Properties>$childObjLine
	</$($info.tag)>
</MetaDataObject>
"@
			[System.IO.File]::WriteAllText((Join-Path $objDir "$objName.xml"), $objXml, $enc)
		}
	}

	Write-Host "Generated stub configuration with $($typeMap.Count) metadata types"
	if ($registerColumns.Count -gt 0) {
		Write-Host "WARNING: Register column categories (Dimension/Resource/Attribute) are guessed. Form field bindings may not survive round-trip through a real database." -ForegroundColor Yellow
	}
}

# --- 5. Create infobase ---
Write-Host "Creating infobase: $TempBasePath"
$createArgs = "CREATEINFOBASE File=`"$TempBasePath`" /DisableStartupDialogs"
$proc = Start-Process -FilePath $V8Path -ArgumentList $createArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
	Write-Error "Failed to create infobase (code: $($proc.ExitCode))"
	exit 1
}

# --- 6. Load config and update DB if ref types exist ---
if ($hasRefTypes) {
	$cfgDir = Join-Path $TempBasePath "cfg"
	# LoadConfigFromFiles
	Write-Host "Loading configuration from files..."
	$loadLog = Join-Path $env:TEMP "stub_load_log.txt"
	$loadArgs = "DESIGNER /F`"$TempBasePath`" /LoadConfigFromFiles `"$cfgDir`" /Out `"$loadLog`" /DisableStartupDialogs"
	$proc = Start-Process -FilePath $V8Path -ArgumentList $loadArgs -NoNewWindow -Wait -PassThru
	if ($proc.ExitCode -ne 0) {
		if (Test-Path $loadLog) { Get-Content $loadLog -Raw -ErrorAction SilentlyContinue | Write-Host }
		Write-Error "Failed to load config (code: $($proc.ExitCode))"
		exit 1
	}

	# UpdateDBCfg
	Write-Host "Updating database configuration..."
	$updateLog = Join-Path $env:TEMP "stub_update_log.txt"
	$updateArgs = "DESIGNER /F`"$TempBasePath`" /UpdateDBCfg /Out `"$updateLog`" /DisableStartupDialogs"
	$proc = Start-Process -FilePath $V8Path -ArgumentList $updateArgs -NoNewWindow -Wait -PassThru
	if ($proc.ExitCode -ne 0) {
		if (Test-Path $updateLog) { Get-Content $updateLog -Raw -ErrorAction SilentlyContinue | Write-Host }
		Write-Error "Failed to update DB config (code: $($proc.ExitCode))"
		exit 1
	}

	# Cleanup cfg dir
	Remove-Item -Path $cfgDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 7. Output base path ---
Write-Host "[OK] Stub database created: $TempBasePath"
Write-Host $TempBasePath
