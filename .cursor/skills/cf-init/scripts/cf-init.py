#!/usr/bin/env python3
# cf-init v1.8 — Create empty 1C configuration scaffold
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Generates minimal XML source files for a 1C configuration."""
import sys, os, argparse, re, uuid

def esc_xml(s):
    return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

def new_uuid():
    return str(uuid.uuid4())

def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)

def write_xml_file(path, content):
    """XML в каноне выгрузки Конфигуратора: CRLF в разделителях, без перевода в конце.

    Копия этой функции есть в каждом навыке-эмиттере (навыки автономны). Держать
    копии одинаковыми — сознательно: разошедшиеся копии сводят на нет весь смысл.
    """
    text = content.replace('\r\n', '\n').replace('\n', '\r\n').rstrip('\r\n')
    write_utf8_bom(path, text)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Create empty 1C configuration scaffold', allow_abbrev=False)
    parser.add_argument('-Name', dest='Name', required=True)
    parser.add_argument('-Synonym', dest='Synonym', default=None)
    parser.add_argument('-OutputDir', dest='OutputDir', default='src')
    parser.add_argument('-Version', dest='Version', default='')
    parser.add_argument('-Vendor', dest='Vendor', default='')
    parser.add_argument('-CompatibilityMode', dest='CompatibilityMode', default='Version8_3_24')
    # Версия формата выгрузки (MDClasses) — её задаёт ПЛАТФОРМА, а не режим совместимости:
    # 8.3.20-8.3.24 пишут 2.17, 8.3.25 — 2.18, 8.3.26 — 2.19, 8.3.27 — 2.20.
    # Дефолт консервативный: 2.17 читается всеми платформами.
    parser.add_argument('-FormatVersion', dest='FormatVersion', default='2.17',
                        choices=['2.17', '2.18', '2.19', '2.20', '2.21'])
    args = parser.parse_args()

    name = args.Name
    synonym = args.Synonym if args.Synonym else name
    output_dir = args.OutputDir
    version = args.Version
    vendor = args.Vendor
    compat = args.CompatibilityMode

    # --- Resolve output dir ---
    if not os.path.isabs(output_dir):
        output_dir = os.path.join(os.getcwd(), output_dir)

    # --- Check existing ---
    cfg_file = os.path.join(output_dir, "Configuration.xml")
    if os.path.exists(cfg_file):
        print(f"Configuration.xml already exists: {cfg_file}", file=sys.stderr)
        sys.exit(1)

    # --- Generate UUIDs ---
    uuid_cfg = new_uuid()
    uuid_lang = new_uuid()
    co = [new_uuid() for _ in range(7)]

    # --- Mobile functionalities ---
    # Версия формата как число — по ней ниже включаются вставки 2.21.
    _fm = re.match(r'^(\d+)\.(\d+)$', args.FormatVersion)
    is_221 = bool(_fm) and int(_fm.group(1)) * 100 + int(_fm.group(2)) >= 221

    mobile_funcs = [
        ("Biometrics","true"), ("Location","false"), ("BackgroundLocation","false"),
        ("BluetoothPrinters","false"), ("WiFiPrinters","false"), ("Contacts","false"),
        ("Calendars","false"), ("PushNotifications","false"), ("LocalNotifications","false"),
        ("InAppPurchases","false"), ("PersonalComputerFileExchange","false"), ("Ads","false"),
        ("NumberDialing","false"), ("CallProcessing","false"), ("CallLog","false"),
        ("AutoSendSMS","false"), ("ReceiveSMS","false"), ("SMSLog","false"),
        ("Camera","false"), ("Microphone","false"), ("MusicLibrary","false"),
        ("PictureAndVideoLibraries","false"), ("AudioPlaybackAndVibration","false"),
        ("BackgroundAudioPlaybackAndVibration","false"), ("InstallPackages","false"),
        ("OSBackup","true"), ("ApplicationUsageStatistics","false"),
        ("BarcodeScanning","false"), ("BackgroundAudioRecording","false"),
        ("AllFilesAccess","false"), ("Videoconferences","false"), ("NFC","false"),
        ("DocumentScanning","false"), ("SpeechToText","false"), ("Geofences","false"),
        ("IncomingShareRequests","false"), ("AllIncomingShareRequestsTypesProcessing","false"),
    ]
    # TextToSpeech — возможность мобильного приложения, добавленная форматом 2.21 (8.5),
    # последней в списке. На младших форматах платформа её не пишет.
    if is_221:
        mobile_funcs.append(("TextToSpeech", "false"))

    mobile_xml = ""
    for func_name, func_use in mobile_funcs:
        mobile_xml += f"\r\n\t\t\t\t<app:functionality>\r\n\t\t\t\t\t<app:functionality>{func_name}</app:functionality>\r\n\t\t\t\t\t<app:use>{func_use}</app:use>\r\n\t\t\t\t</app:functionality>"

    # --- Synonym XML ---
    synonym_xml = ""
    if synonym:
        synonym_xml = f"\r\n\t\t\t\t<v8:item>\r\n\t\t\t\t\t<v8:lang>ru</v8:lang>\r\n\t\t\t\t\t<v8:content>{esc_xml(synonym)}</v8:content>\r\n\t\t\t\t</v8:item>\r\n\t\t\t"

    # Элемент целиком, а не значение внутри пары: при пустом значении Конфигуратор
    # пишет <Vendor/>, а не <Vendor></Vendor>.
    vendor_el = f"<Vendor>{esc_xml(vendor)}</Vendor>" if vendor else "<Vendor/>"
    version_el = f"<Version>{esc_xml(version)}</Version>" if version else "<Version/>"

    class_ids = [
        "9cd510cd-abfc-11d4-9434-004095e12fc7",
        "9fcd25a0-4822-11d4-9414-008048da11f9",
        "e3687481-0a87-462c-a166-9f34594f9bba",
        "9de14907-ec23-4a07-96f0-85521cb6b53b",
        "51f2d5d8-ea4d-4064-8892-82951750031e",
        "e68182ea-4237-4383-967f-90c1e3370bc7",
        "fb282519-d103-4dd3-bc12-cb271d631dfc",
    ]

    # Свойства и пространство имён формата 2.21 (платформа 8.5). Значения и ПОЗИЦИИ сняты
    # с выгрузки 8.5.1 (debug/fmt221/dump_v851): те же исходники, выгруженные с 8.3.27 и
    # с 8.5.1, различаются ровно этим. Порядок важен — вставки идут на своё место.
    pal_ns = ""
    f221_aux_forms = f221_window_variant = f221_open_variant = f221_captions = f221_migration = ""
    if is_221:
        pal_ns = ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette"'
        f221_aux_forms = "\r\n" + "\r\n".join(
            f"\t\t\t{t}" for t in (
                "<AuxiliaryReportForm/>", "<AuxiliaryReportVariantForm/>", "<AuxiliaryReportSettingsForm/>",
                "<AuxiliaryDynamicListSettingsForm/>", "<AuxiliaryDataHistoryChangeHistoryForm/>",
                "<AuxiliaryDataHistoryVersionDataForm/>", "<AuxiliaryDataHistoryVersionDifferencesForm/>",
                "<AuxiliaryCollaborationSystemUsersChoiceForm/>"))
        f221_window_variant = ("\r\n\t\t\t<MainClientApplicationWindowInterfaceVariant>NavigationLeft"
                               "</MainClientApplicationWindowInterfaceVariant>"
                               "\r\n\t\t\t<ClientApplicationTheme>Auto</ClientApplicationTheme>")
        f221_open_variant = ("\r\n\t\t\t<ClientApplicationWindowsOpenVariant>OpenDataInDialogs"
                             "</ClientApplicationWindowsOpenVariant>")
        f221_captions = "\r\n\t\t\t<Caption/>\r\n\t\t\t<ShortCaption/>"
        f221_migration = ("\r\n\t\t\t<Version85InterfaceMigrationMode>DontUse"
                          "</Version85InterfaceMigrationMode>")

    contained_objects = ""
    for i in range(7):
        contained_objects += f"""\t\t\t<xr:ContainedObject>
\t\t\t\t<xr:ClassId>{class_ids[i]}</xr:ClassId>
\t\t\t\t<xr:ObjectId>{co[i]}</xr:ObjectId>
\t\t\t</xr:ContainedObject>\n"""

    cfg_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"{pal_ns} xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="{args.FormatVersion}">
\t<Configuration uuid="{uuid_cfg}">
\t\t<InternalInfo>
{contained_objects}\t\t</InternalInfo>
\t\t<Properties>
\t\t\t<Name>{esc_xml(name)}</Name>
\t\t\t<Synonym>{synonym_xml}</Synonym>
\t\t\t<Comment/>
\t\t\t<NamePrefix/>
\t\t\t<ConfigurationExtensionCompatibilityMode>{compat}</ConfigurationExtensionCompatibilityMode>
\t\t\t<DefaultRunMode>ManagedApplication</DefaultRunMode>
\t\t\t<UsePurposes>
\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
\t\t\t</UsePurposes>
\t\t\t<ScriptVariant>Russian</ScriptVariant>
\t\t\t<DefaultRoles/>
\t\t\t{vendor_el}
\t\t\t{version_el}
\t\t\t<UpdateCatalogAddress/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<UseManagedFormInOrdinaryApplication>false</UseManagedFormInOrdinaryApplication>
\t\t\t<UseOrdinaryFormInManagedApplication>false</UseOrdinaryFormInManagedApplication>
\t\t\t<AdditionalFullTextSearchDictionaries/>
\t\t\t<CommonSettingsStorage/>
\t\t\t<ReportsUserSettingsStorage/>
\t\t\t<ReportsVariantsStorage/>
\t\t\t<FormDataSettingsStorage/>
\t\t\t<DynamicListsUserSettingsStorage/>
\t\t\t<URLExternalDataStorage/>
\t\t\t<Content/>
\t\t\t<DefaultReportForm/>
\t\t\t<DefaultReportVariantForm/>
\t\t\t<DefaultReportSettingsForm/>
\t\t\t<DefaultReportAppearanceTemplate/>
\t\t\t<DefaultDynamicListSettingsForm/>
\t\t\t<DefaultSearchForm/>
\t\t\t<DefaultDataHistoryChangeHistoryForm/>
\t\t\t<DefaultDataHistoryVersionDataForm/>
\t\t\t<DefaultDataHistoryVersionDifferencesForm/>
\t\t\t<DefaultCollaborationSystemUsersChoiceForm/>{f221_aux_forms}
\t\t\t<RequiredMobileApplicationPermissions/>
\t\t\t<UsedMobileApplicationFunctionalities>{mobile_xml}
\t\t\t</UsedMobileApplicationFunctionalities>
\t\t\t<StandaloneConfigurationRestrictionRoles/>
\t\t\t<MobileApplicationURLs/>
\t\t\t<AllowedIncomingShareRequestTypes/>{f221_window_variant}
\t\t\t<MainClientApplicationWindowMode>Normal</MainClientApplicationWindowMode>{f221_open_variant}
\t\t\t<DefaultInterface/>{f221_captions}
\t\t\t<DefaultStyle/>
\t\t\t<DefaultLanguage>Language.Русский</DefaultLanguage>
\t\t\t<BriefInformation/>
\t\t\t<DetailedInformation/>
\t\t\t<Copyright/>
\t\t\t<VendorInformationAddress/>
\t\t\t<ConfigurationInformationAddress/>
\t\t\t<DataLockControlMode>Managed</DataLockControlMode>
\t\t\t<ObjectAutonumerationMode>NotAutoFree</ObjectAutonumerationMode>
\t\t\t<ModalityUseMode>DontUse</ModalityUseMode>
\t\t\t<SynchronousPlatformExtensionAndAddInCallUseMode>DontUse</SynchronousPlatformExtensionAndAddInCallUseMode>
\t\t\t<InterfaceCompatibilityMode>TaxiEnableVersion8_2</InterfaceCompatibilityMode>{f221_migration}
\t\t\t<DatabaseTablespacesUseMode>DontUse</DatabaseTablespacesUseMode>
\t\t\t<CompatibilityMode>{compat}</CompatibilityMode>
\t\t\t<DefaultConstantsForm/>
\t\t</Properties>
\t\t<ChildObjects>
\t\t\t<Language>Русский</Language>
\t\t</ChildObjects>
\t</Configuration>
</MetaDataObject>'''

    # --- Languages/Русский.xml ---
    lang_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"{pal_ns} xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="{args.FormatVersion}">
\t<Language uuid="{uuid_lang}">
\t\t<Properties>
\t\t\t<Name>Русский</Name>
\t\t\t<Synonym>
\t\t\t\t<v8:item>
\t\t\t\t\t<v8:lang>ru</v8:lang>
\t\t\t\t\t<v8:content>Русский</v8:content>
\t\t\t\t</v8:item>
\t\t\t</Synonym>
\t\t\t<Comment/>
\t\t\t<LanguageCode>ru</LanguageCode>
\t\t</Properties>
\t</Language>
</MetaDataObject>'''

    # --- Ext/ClientApplicationInterface.xml (default ERP-style panel layout) ---
    # Open panel on top, Sections panel on left; Functions/Favorites/History declared
    # via panelDef but not placed by default. Without this file the web client renders
    # section icons without labels (icon-only mode).
    open_panel_inst = new_uuid()
    sections_panel_inst = new_uuid()
    cai_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<ClientApplicationInterface xmlns="http://v8.1c.ru/8.2/managed-application/core" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="InterfaceLayouter">
\t<top>
\t\t<panel id="{open_panel_inst}">
\t\t\t<uuid>cbab57f2-a0f3-4f0a-89ea-4cb19570ab75</uuid>
\t\t</panel>
\t</top>
\t<left>
\t\t<panel id="{sections_panel_inst}">
\t\t\t<uuid>b553047f-c9aa-4157-978d-448ecad24248</uuid>
\t\t</panel>
\t</left>
\t<panelDef id="b553047f-c9aa-4157-978d-448ecad24248"/>
\t<panelDef id="13322b22-3960-4d68-93a6-fe2dd7f28ca3"/>
\t<panelDef id="c933ac92-92cd-459d-81cc-e0c8a83ced99"/>
\t<panelDef id="cbab57f2-a0f3-4f0a-89ea-4cb19570ab75"/>
\t<panelDef id="b2735bd3-d822-4430-ba59-c9e869693b24"/>
</ClientApplicationInterface>'''

    # --- Create directories ---
    os.makedirs(output_dir, exist_ok=True)
    lang_dir = os.path.join(output_dir, "Languages")
    os.makedirs(lang_dir, exist_ok=True)
    ext_dir = os.path.join(output_dir, "Ext")
    os.makedirs(ext_dir, exist_ok=True)

    # --- Write files ---
    write_xml_file(cfg_file, cfg_xml)
    lang_file = os.path.join(lang_dir, "Русский.xml")
    write_xml_file(lang_file, lang_xml)
    cai_file = os.path.join(ext_dir, "ClientApplicationInterface.xml")
    write_xml_file(cai_file, cai_xml)

    print(f"[OK] Создана конфигурация: {name}")
    print(f"     Каталог:            {output_dir}")
    print(f"     Configuration.xml:  {cfg_file}")
    print(f"     Languages:          {lang_file}")
    print(f"     Ext/CAI:            {cai_file}")

if __name__ == '__main__':
    main()
