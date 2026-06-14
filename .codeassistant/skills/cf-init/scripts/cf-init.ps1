# cf-init v1.2 — Create empty 1C configuration scaffold
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$Name,
	[string]$Synonym = $Name,
	[string]$OutputDir = "src",
	[string]$Version,
	[string]$Vendor,
	[string]$CompatibilityMode = "Version8_3_24"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve output dir ---
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
	$OutputDir = Join-Path (Get-Location).Path $OutputDir
}

# --- Check existing ---
$cfgFile = Join-Path $OutputDir "Configuration.xml"
if (Test-Path $cfgFile) {
	Write-Error "Configuration.xml already exists: $cfgFile"
	exit 1
}

# --- Generate UUIDs ---
$uuidCfg  = [guid]::NewGuid().ToString()
$uuidLang = [guid]::NewGuid().ToString()
# 7 ContainedObject ObjectIds
$co1 = [guid]::NewGuid().ToString()
$co2 = [guid]::NewGuid().ToString()
$co3 = [guid]::NewGuid().ToString()
$co4 = [guid]::NewGuid().ToString()
$co5 = [guid]::NewGuid().ToString()
$co6 = [guid]::NewGuid().ToString()
$co7 = [guid]::NewGuid().ToString()

# --- Mobile functionalities ---
$mobileFuncs = @(
	@("Biometrics","true"), @("Location","false"), @("BackgroundLocation","false"),
	@("BluetoothPrinters","false"), @("WiFiPrinters","false"), @("Contacts","false"),
	@("Calendars","false"), @("PushNotifications","false"), @("LocalNotifications","false"),
	@("InAppPurchases","false"), @("PersonalComputerFileExchange","false"), @("Ads","false"),
	@("NumberDialing","false"), @("CallProcessing","false"), @("CallLog","false"),
	@("AutoSendSMS","false"), @("ReceiveSMS","false"), @("SMSLog","false"),
	@("Camera","false"), @("Microphone","false"), @("MusicLibrary","false"),
	@("PictureAndVideoLibraries","false"), @("AudioPlaybackAndVibration","false"),
	@("BackgroundAudioPlaybackAndVibration","false"), @("InstallPackages","false"),
	@("OSBackup","true"), @("ApplicationUsageStatistics","false"),
	@("BarcodeScanning","false"), @("BackgroundAudioRecording","false"),
	@("AllFilesAccess","false"), @("Videoconferences","false"), @("NFC","false"),
	@("DocumentScanning","false"), @("SpeechToText","false"), @("Geofences","false"),
	@("IncomingShareRequests","false"), @("AllIncomingShareRequestsTypesProcessing","false")
)

$mobileXml = ""
foreach ($mf in $mobileFuncs) {
	$mobileXml += "`r`n`t`t`t`t<app:functionality>`r`n`t`t`t`t`t<app:functionality>$($mf[0])</app:functionality>`r`n`t`t`t`t`t<app:use>$($mf[1])</app:use>`r`n`t`t`t`t</app:functionality>"
}

# --- Synonym XML ---
$synonymXml = ""
if ($Synonym) {
	$synonymXml = "`r`n`t`t`t`t<v8:item>`r`n`t`t`t`t`t<v8:lang>ru</v8:lang>`r`n`t`t`t`t`t<v8:content>$([System.Security.SecurityElement]::Escape($Synonym))</v8:content>`r`n`t`t`t`t</v8:item>`r`n`t`t`t"
}

# --- Optional properties ---
$vendorXml = if ($Vendor) { [System.Security.SecurityElement]::Escape($Vendor) } else { "" }
$versionXml = if ($Version) { [System.Security.SecurityElement]::Escape($Version) } else { "" }

# --- Configuration.xml ---
$cfgXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<Configuration uuid="$uuidCfg">
		<InternalInfo>
			<xr:ContainedObject>
				<xr:ClassId>9cd510cd-abfc-11d4-9434-004095e12fc7</xr:ClassId>
				<xr:ObjectId>$co1</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>9fcd25a0-4822-11d4-9414-008048da11f9</xr:ClassId>
				<xr:ObjectId>$co2</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>e3687481-0a87-462c-a166-9f34594f9bba</xr:ClassId>
				<xr:ObjectId>$co3</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>9de14907-ec23-4a07-96f0-85521cb6b53b</xr:ClassId>
				<xr:ObjectId>$co4</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>51f2d5d8-ea4d-4064-8892-82951750031e</xr:ClassId>
				<xr:ObjectId>$co5</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>e68182ea-4237-4383-967f-90c1e3370bc7</xr:ClassId>
				<xr:ObjectId>$co6</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>fb282519-d103-4dd3-bc12-cb271d631dfc</xr:ClassId>
				<xr:ObjectId>$co7</xr:ObjectId>
			</xr:ContainedObject>
		</InternalInfo>
		<Properties>
			<Name>$([System.Security.SecurityElement]::Escape($Name))</Name>
			<Synonym>$synonymXml</Synonym>
			<Comment/>
			<NamePrefix/>
			<ConfigurationExtensionCompatibilityMode>$CompatibilityMode</ConfigurationExtensionCompatibilityMode>
			<DefaultRunMode>ManagedApplication</DefaultRunMode>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
			</UsePurposes>
			<ScriptVariant>Russian</ScriptVariant>
			<DefaultRoles/>
			<Vendor>$vendorXml</Vendor>
			<Version>$versionXml</Version>
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
			<UsedMobileApplicationFunctionalities>$mobileXml
			</UsedMobileApplicationFunctionalities>
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
			<InterfaceCompatibilityMode>TaxiEnableVersion8_2</InterfaceCompatibilityMode>
			<DatabaseTablespacesUseMode>DontUse</DatabaseTablespacesUseMode>
			<CompatibilityMode>$CompatibilityMode</CompatibilityMode>
			<DefaultConstantsForm/>
		</Properties>
		<ChildObjects>
			<Language>Русский</Language>
		</ChildObjects>
	</Configuration>
</MetaDataObject>
"@

# --- Languages/Русский.xml ---
$langXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
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

# --- Ext/ClientApplicationInterface.xml (default ERP-style panel layout) ---
# Open panel on top, Sections panel on left; Functions/Favorites/History declared
# via panelDef but not placed by default. Without this file the web client renders
# section icons without labels (icon-only mode).
$openPanelInst = [guid]::NewGuid().ToString()
$sectionsPanelInst = [guid]::NewGuid().ToString()
$caiXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<ClientApplicationInterface xmlns="http://v8.1c.ru/8.2/managed-application/core" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="InterfaceLayouter">
	<top>
		<panel id="$openPanelInst">
			<uuid>cbab57f2-a0f3-4f0a-89ea-4cb19570ab75</uuid>
		</panel>
	</top>
	<left>
		<panel id="$sectionsPanelInst">
			<uuid>b553047f-c9aa-4157-978d-448ecad24248</uuid>
		</panel>
	</left>
	<panelDef id="b553047f-c9aa-4157-978d-448ecad24248"/>
	<panelDef id="13322b22-3960-4d68-93a6-fe2dd7f28ca3"/>
	<panelDef id="c933ac92-92cd-459d-81cc-e0c8a83ced99"/>
	<panelDef id="cbab57f2-a0f3-4f0a-89ea-4cb19570ab75"/>
	<panelDef id="b2735bd3-d822-4430-ba59-c9e869693b24"/>
</ClientApplicationInterface>
"@

# --- Create directories ---
if (-not (Test-Path $OutputDir)) {
	New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$langDir = Join-Path $OutputDir "Languages"
if (-not (Test-Path $langDir)) {
	New-Item -ItemType Directory -Path $langDir -Force | Out-Null
}
$extDir = Join-Path $OutputDir "Ext"
if (-not (Test-Path $extDir)) {
	New-Item -ItemType Directory -Path $extDir -Force | Out-Null
}

# --- Write files with UTF-8 BOM ---
$enc = New-Object System.Text.UTF8Encoding($true)

[System.IO.File]::WriteAllText($cfgFile, $cfgXml, $enc)
$langFile = Join-Path $langDir "Русский.xml"
[System.IO.File]::WriteAllText($langFile, $langXml, $enc)
$caiFile = Join-Path $extDir "ClientApplicationInterface.xml"
[System.IO.File]::WriteAllText($caiFile, $caiXml, $enc)

# --- Output ---
Write-Host "[OK] Создана конфигурация: $Name"
Write-Host "     Каталог:            $OutputDir"
Write-Host "     Configuration.xml:  $cfgFile"
Write-Host "     Languages:          $langFile"
Write-Host "     Ext/CAI:            $caiFile"
