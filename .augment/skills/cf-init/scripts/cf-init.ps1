# cf-init v1.15 — Create empty 1C configuration scaffold (+write_xml_file/write_utf8_bom: общий эталон записи)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[string]$Name,
	[string]$Synonym = $Name,
	[string]$OutputDir = "src",
	[string]$Version,
	[string]$Vendor,
	[string]$CompatibilityMode = "Version8_3_24",
	# Версия формата выгрузки (MDClasses). Её задаёт ПЛАТФОРМА, которой выгружают, и от режима
	# совместимости она не зависит. Дефолт 2.17 — нижняя граница проверенного диапазона.
	[string]$FormatVersion = "2.17"
)

$ErrorActionPreference = "Stop"

# --- Format version ---
# Проверенный диапазон: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница — docs/1c-configuration-spec.md,
# «Лестница версий». Версии ниже 2.17 (платформы 8.3.23 и старше) реальны, поэтому запретом их не
# закрываем: за пределами диапазона — ПРЕДУПРЕЖДЕНИЕ, скаффолд всё равно выпускается. Ошибка — только
# на нечисловое значение: это опечатка, а не версия.
$formatVerifiedMin = "2.17"
$formatVerifiedMax = "2.21"
# Версия формата как число: "2.20" → 220. Строковое сравнение неверно ("2.9" > "2.17").
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}
$formatRank = Get-FormatRank $FormatVersion

function Esc-XmlText {
	param([string]$s)
	# Эскейп ТЕКСТА элемента: только & < > — кавычку и апостроф платформа держит сырыми.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Проверка версии — ПОСЛЕ настройки кодировки консоли: иначе em-dash в сообщении уедет в вопросы.
# Пишем прямо в stderr, а не Write-Warning: в PS 5.1 предупреждение уходит в stdout, получает
# локализованный префикс и переносится по 80 символов — подстрока в тесте перестаёт находиться.
if ($formatRank -eq 0) {
	[Console]::Error.WriteLine("Malformed -FormatVersion '$FormatVersion' (expected N.N, e.g. 2.17)")
	exit 1
}
if ($formatRank -lt (Get-FormatRank $formatVerifiedMin) -or $formatRank -gt (Get-FormatRank $formatVerifiedMax)) {
	[Console]::Error.WriteLine("WARNING: Format version '$FormatVersion' is outside the tested range $formatVerifiedMin-$formatVerifiedMax — the scaffold is emitted as requested but was not verified on that platform")
}

# «Не использовать» в Конфигураторе хранится как версия ТЕКУЩЕЙ платформы, а не как DontUse:
# свежая база получает Version8_3_<своя>, и ни одна типовая в корпусе DontUse не содержит.
# Само значение легально — платформа принимает его без ошибок, — но не выживает: замерено на
# 8.3.25 и 8.3.27, выгрузка обоих возвращает Version8_3_8. Поэтому предупреждение, а не запрет.
# Сравнение регистронезависимо ЯВНО: в PS -eq таков по умолчанию, в py — нет, и молчаливое
# расхождение портов началось бы прямо здесь.
if ($CompatibilityMode -and $CompatibilityMode.ToLowerInvariant() -eq 'dontuse') {
	[Console]::Error.WriteLine("WARNING: CompatibilityMode 'DontUse' is not `"no restrictions`" — the platform stores it as Version8_3_8. For no compatibility restrictions use the target platform version (e.g. Version8_3_27 for 8.3.27).")
}

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
# Версия формата как число — по ней ниже включаются вставки 2.21.
$is221 = ($formatRank -ge 221)
# TextToSpeech приехал раньше остальных вставок 8.5 — своей ступенью, поэтому гейт отдельный.
$is218 = ($formatRank -ge 218)

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
# TextToSpeech — возможность мобильного приложения, добавленная форматом 2.18 (8.3.25),
# последней в списке; в 2.21 список не менялся. Замерено выгрузками пустой ИБ шести платформ:
# 2.13/2.17 — 37 записей без неё, 2.18-2.21 — 38 с ней. Гейт обязателен и в обе стороны:
# на 2.17 тег ломает загрузку XDTO-ошибкой (проверено на 8.3.24), без тега на 2.18+ платформа
# подставит дефолт false и допишет его при выгрузке — то есть разойдётся роундтрип.
if ($is218) { $mobileFuncs += ,@("TextToSpeech","false") }

$mobileXml = ""
foreach ($mf in $mobileFuncs) {
	$mobileXml += "`r`n`t`t`t`t<app:functionality>`r`n`t`t`t`t`t<app:functionality>$($mf[0])</app:functionality>`r`n`t`t`t`t`t<app:use>$($mf[1])</app:use>`r`n`t`t`t`t</app:functionality>"
}

# --- Synonym XML ---
$synonymXml = ""
if ($Synonym) {
	$synonymXml = "`r`n`t`t`t`t<v8:item>`r`n`t`t`t`t`t<v8:lang>ru</v8:lang>`r`n`t`t`t`t`t<v8:content>$(Esc-XmlText ($Synonym))</v8:content>`r`n`t`t`t`t</v8:item>`r`n`t`t`t"
}

# --- Optional properties ---
# Элемент целиком, а не значение внутри пары: при пустом значении Конфигуратор
# пишет <Vendor/>, а не <Vendor></Vendor>.
$vendorEl = if ($Vendor) { "<Vendor>$(Esc-XmlText ($Vendor))</Vendor>" } else { "<Vendor/>" }
$versionEl = if ($Version) { "<Version>$(Esc-XmlText ($Version))</Version>" } else { "<Version/>" }

# --- Свойства и пространство имён формата 2.21 (платформа 8.5) ---
# Значения и ПОЗИЦИИ сняты с выгрузки 8.5.1 (debug/fmt221/dump_v851): те же исходники,
# выгруженные с 8.3.27 и с 8.5.1, различаются ровно этим. Порядок важен — вставки идут
# на своё место, а не в конец.
$nl = "`r`n"
$f221AuxForms = ""; $f221WindowVariant = ""; $f221OpenVariant = ""; $f221Captions = ""; $f221Migration = ""
$palNs = ""
if ($is221) {
	$palNs = ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette"'
	# Скобки вокруг -join обязательны: без них `$nl + (массив) -join $nl` разбирается как
	# `($nl + массив) -join $nl`, массив склеивается пробелами и все теги уезжают в одну строку.
	$f221AuxForms = $nl + ((@(
		"<AuxiliaryReportForm/>", "<AuxiliaryReportVariantForm/>", "<AuxiliaryReportSettingsForm/>",
		"<AuxiliaryDynamicListSettingsForm/>", "<AuxiliaryDataHistoryChangeHistoryForm/>",
		"<AuxiliaryDataHistoryVersionDataForm/>", "<AuxiliaryDataHistoryVersionDifferencesForm/>",
		"<AuxiliaryCollaborationSystemUsersChoiceForm/>"
	) | ForEach-Object { "`t`t`t$_" }) -join $nl)
	$f221WindowVariant = $nl + "`t`t`t<MainClientApplicationWindowInterfaceVariant>NavigationLeft</MainClientApplicationWindowInterfaceVariant>" +
		$nl + "`t`t`t<ClientApplicationTheme>Auto</ClientApplicationTheme>"
	$f221OpenVariant = $nl + "`t`t`t<ClientApplicationWindowsOpenVariant>OpenDataInDialogs</ClientApplicationWindowsOpenVariant>"
	$f221Captions = $nl + "`t`t`t<Caption/>" + $nl + "`t`t`t<ShortCaption/>"
	$f221Migration = $nl + "`t`t`t<Version85InterfaceMigrationMode>DontUse</Version85InterfaceMigrationMode>"
}

# --- Configuration.xml ---
$cfgXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"$palNs xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="$FormatVersion">
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
			<Name>$(Esc-XmlText ($Name))</Name>
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
			$vendorEl
			$versionEl
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
			<DefaultCollaborationSystemUsersChoiceForm/>$f221AuxForms
			<RequiredMobileApplicationPermissions/>
			<UsedMobileApplicationFunctionalities>$mobileXml
			</UsedMobileApplicationFunctionalities>
			<StandaloneConfigurationRestrictionRoles/>
			<MobileApplicationURLs/>
			<AllowedIncomingShareRequestTypes/>$f221WindowVariant
			<MainClientApplicationWindowMode>Normal</MainClientApplicationWindowMode>$f221OpenVariant
			<DefaultInterface/>$f221Captions
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
			<InterfaceCompatibilityMode>TaxiEnableVersion8_2</InterfaceCompatibilityMode>$f221Migration
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
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"$palNs xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="$FormatVersion">
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

# XML в каноне выгрузки Конфигуратора: CRLF в разделителях, без перевода в конце.
#
# Копия этой функции есть в каждом навыке-эмиттере (навыки автономны). Держать
# копии одинаковыми — сознательно: разошедшиеся копии сводят на нет весь смысл.
function Write-XmlFile([string]$path, [string]$text, $encoding) {
	$t = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
	[System.IO.File]::WriteAllText($path, $t.TrimEnd("`r", "`n"), $encoding)
}

Write-XmlFile $cfgFile $cfgXml $enc
$langFile = Join-Path $langDir "Русский.xml"
Write-XmlFile $langFile $langXml $enc
$caiFile = Join-Path $extDir "ClientApplicationInterface.xml"
Write-XmlFile $caiFile $caiXml $enc

# --- Output ---
Write-Host "[OK] Создана конфигурация: $Name"
Write-Host "     Каталог:            $OutputDir"
Write-Host "     Configuration.xml:  $cfgFile"
Write-Host "     Languages:          $langFile"
Write-Host "     Ext/CAI:            $caiFile"
