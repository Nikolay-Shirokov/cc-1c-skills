#!/usr/bin/env python3
# cfe-init v1.1 — Create 1C configuration extension scaffold (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Generates minimal XML source files for a 1C configuration extension."""
import sys, os, argparse, uuid
from xml.etree import ElementTree as ET

def esc_xml(s):
    return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

def new_uuid():
    return str(uuid.uuid4())

def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Create 1C configuration extension scaffold', allow_abbrev=False)
    parser.add_argument('-Name', dest='Name', required=True)
    parser.add_argument('-Synonym', dest='Synonym', default=None)
    parser.add_argument('-NamePrefix', dest='NamePrefix', default=None)
    parser.add_argument('-OutputDir', dest='OutputDir', default='src')
    parser.add_argument('-Purpose', dest='Purpose', default='Customization', choices=['Patch','Customization','AddOn'])
    parser.add_argument('-Version', dest='Version', default='')
    parser.add_argument('-Vendor', dest='Vendor', default='')
    parser.add_argument('-CompatibilityMode', dest='CompatibilityMode', default='Version8_3_24')
    parser.add_argument('-ConfigPath', dest='ConfigPath', default=None)
    parser.add_argument('-NoRole', dest='NoRole', action='store_true')
    args = parser.parse_args()

    name = args.Name
    synonym = args.Synonym if args.Synonym else name
    name_prefix = args.NamePrefix if args.NamePrefix else f"{name}_"
    output_dir = args.OutputDir
    purpose = args.Purpose
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

    # --- Resolve ConfigPath ---
    base_lang_uuid = "00000000-0000-0000-0000-000000000000"
    if args.ConfigPath:
        config_path = args.ConfigPath
        if not os.path.isabs(config_path):
            config_path = os.path.join(os.getcwd(), config_path)
        if os.path.isdir(config_path):
            candidate = os.path.join(config_path, "Configuration.xml")
            if os.path.exists(candidate):
                config_path = candidate
            else:
                print(f"No Configuration.xml in config directory: {config_path}", file=sys.stderr)
                sys.exit(1)
        if not os.path.exists(config_path):
            print(f"Config file not found: {config_path}", file=sys.stderr)
            sys.exit(1)
        cfg_dir = os.path.dirname(os.path.abspath(config_path))

        # Read Language UUID from base config
        base_lang_file = os.path.join(cfg_dir, "Languages", "Русский.xml")
        if os.path.exists(base_lang_file):
            try:
                base_tree = ET.parse(base_lang_file)
                base_root = base_tree.getroot()
                for child in base_root:
                    if child.tag.endswith('}Language') or child.tag == 'Language':
                        base_lang_uuid = child.get('uuid', base_lang_uuid)
                        print(f"[INFO] Base config Language UUID: {base_lang_uuid}")
                        break
            except Exception:
                print(f"[WARN] Could not parse {base_lang_file}")
        else:
            print(f"[WARN] Base config language not found: {base_lang_file}")

        # Read CompatibilityMode and InterfaceCompatibilityMode from base config
        try:
            base_cfg_tree = ET.parse(os.path.abspath(config_path))
            base_cfg_root = base_cfg_tree.getroot()
            ns = {'md': 'http://v8.1c.ru/8.3/MDClasses'}
            compat_node = base_cfg_root.find('.//md:Configuration/md:Properties/md:CompatibilityMode', ns)
            if compat_node is not None and compat_node.text:
                compat = compat_node.text.strip()
                print(f"[INFO] Base config CompatibilityMode: {compat}")
            else:
                print(f"[WARN] CompatibilityMode not found in base config, using default: {compat}")
            ifc_node = base_cfg_root.find('.//md:Configuration/md:Properties/md:InterfaceCompatibilityMode', ns)
            if ifc_node is not None and ifc_node.text:
                ifc_mode = ifc_node.text.strip()
                print(f"[INFO] Base config InterfaceCompatibilityMode: {ifc_mode}")
            else:
                ifc_mode = "TaxiEnableVersion8_2"
                print(f"[WARN] InterfaceCompatibilityMode not found in base config, using default: {ifc_mode}")
        except Exception:
            print(f"[WARN] Could not parse base config, using default CompatibilityMode: {compat}")
            ifc_mode = "TaxiEnableVersion8_2"
    else:
        ifc_mode = "TaxiEnableVersion8_2"
        print("[WARN] Language ExtendedConfigurationObject set to zeros. Use -ConfigPath to auto-resolve from base config, or fix manually before loading.")

    # --- Generate UUIDs ---
    uuid_cfg = new_uuid()
    uuid_lang = new_uuid()
    uuid_role = new_uuid()
    co = [new_uuid() for _ in range(7)]

    # --- Synonym XML ---
    synonym_xml = ""
    if synonym:
        synonym_xml = f"\r\n\t\t\t\t<v8:item>\r\n\t\t\t\t\t<v8:lang>ru</v8:lang>\r\n\t\t\t\t\t<v8:content>{esc_xml(synonym)}</v8:content>\r\n\t\t\t\t</v8:item>\r\n\t\t\t"

    vendor_xml = esc_xml(vendor) if vendor else ""
    version_xml = esc_xml(version) if version else ""

    # --- Role name ---
    role_name = f"{name_prefix}ОсновнаяРоль"

    # --- DefaultRoles XML ---
    default_roles_xml = ""
    if not args.NoRole:
        default_roles_xml = f'\r\n\t\t\t\t<xr:Item xsi:type="xr:MDObjectRef">Role.{role_name}</xr:Item>\r\n\t\t\t'

    # --- ChildObjects ---
    child_objects_xml = f"\r\n\t\t\t<Language>Русский</Language>"
    if not args.NoRole:
        child_objects_xml += f"\r\n\t\t\t<Role>{role_name}</Role>"
    child_objects_xml += "\r\n\t\t"

    class_ids = [
        "9cd510cd-abfc-11d4-9434-004095e12fc7",
        "9fcd25a0-4822-11d4-9414-008048da11f9",
        "e3687481-0a87-462c-a166-9f34594f9bba",
        "9de14907-ec23-4a07-96f0-85521cb6b53b",
        "51f2d5d8-ea4d-4064-8892-82951750031e",
        "e68182ea-4237-4383-967f-90c1e3370bc7",
        "fb282519-d103-4dd3-bc12-cb271d631dfc",
    ]

    contained_objects = ""
    for i in range(7):
        contained_objects += f"""\t\t\t<xr:ContainedObject>
\t\t\t\t<xr:ClassId>{class_ids[i]}</xr:ClassId>
\t\t\t\t<xr:ObjectId>{co[i]}</xr:ObjectId>
\t\t\t</xr:ContainedObject>\n"""

    cfg_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
\t<Configuration uuid="{uuid_cfg}">
\t\t<InternalInfo>
{contained_objects}\t\t</InternalInfo>
\t\t<Properties>
\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>
\t\t\t<Name>{esc_xml(name)}</Name>
\t\t\t<Synonym>{synonym_xml}</Synonym>
\t\t\t<Comment/>
\t\t\t<ConfigurationExtensionPurpose>{purpose}</ConfigurationExtensionPurpose>
\t\t\t<KeepMappingToExtendedConfigurationObjectsByIDs>true</KeepMappingToExtendedConfigurationObjectsByIDs>
\t\t\t<NamePrefix>{esc_xml(name_prefix)}</NamePrefix>
\t\t\t<ConfigurationExtensionCompatibilityMode>{compat}</ConfigurationExtensionCompatibilityMode>
\t\t\t<DefaultRunMode>ManagedApplication</DefaultRunMode>
\t\t\t<UsePurposes>
\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
\t\t\t</UsePurposes>
\t\t\t<ScriptVariant>Russian</ScriptVariant>
\t\t\t<DefaultRoles>{default_roles_xml}</DefaultRoles>
\t\t\t<Vendor>{vendor_xml}</Vendor>
\t\t\t<Version>{version_xml}</Version>
\t\t\t<DefaultLanguage>Language.Русский</DefaultLanguage>
\t\t\t<BriefInformation/>
\t\t\t<DetailedInformation/>
\t\t\t<Copyright/>
\t\t\t<VendorInformationAddress/>
\t\t\t<ConfigurationInformationAddress/>
\t\t\t<InterfaceCompatibilityMode>{ifc_mode}</InterfaceCompatibilityMode>
\t\t</Properties>
\t\t<ChildObjects>{child_objects_xml}</ChildObjects>
\t</Configuration>
</MetaDataObject>'''

    # --- Languages/Русский.xml (adopted format) ---
    lang_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
\t<Language uuid="{uuid_lang}">
\t\t<InternalInfo/>
\t\t<Properties>
\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>
\t\t\t<Name>Русский</Name>
\t\t\t<Comment/>
\t\t\t<ExtendedConfigurationObject>{base_lang_uuid}</ExtendedConfigurationObject>
\t\t\t<LanguageCode>ru</LanguageCode>
\t\t</Properties>
\t</Language>
</MetaDataObject>'''

    # --- Role XML ---
    role_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
\t<Role uuid="{uuid_role}">
\t\t<Properties>
\t\t\t<Name>{esc_xml(role_name)}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t</Properties>
\t</Role>
</MetaDataObject>'''

    # --- Create directories ---
    os.makedirs(output_dir, exist_ok=True)
    lang_dir = os.path.join(output_dir, "Languages")
    os.makedirs(lang_dir, exist_ok=True)

    # --- Write files ---
    write_utf8_bom(cfg_file, cfg_xml)
    lang_file = os.path.join(lang_dir, "Русский.xml")
    write_utf8_bom(lang_file, lang_xml)

    # --- Role ---
    role_file = None
    if not args.NoRole:
        role_dir = os.path.join(output_dir, "Roles")
        os.makedirs(role_dir, exist_ok=True)
        role_file = os.path.join(role_dir, f"{role_name}.xml")
        write_utf8_bom(role_file, role_xml)

    # --- Output ---
    print(f"[OK] Создано расширение: {name}")
    print(f"     Каталог:            {output_dir}")
    print(f"     Назначение:         {purpose}")
    print(f"     Префикс:           {name_prefix}")
    print(f"     Совместимость:     {compat}")
    print(f"     Configuration.xml:  {cfg_file}")
    print(f"     Languages:          {lang_file}")
    if role_file:
        print(f"     Role:               {role_file}")

if __name__ == '__main__':
    main()
