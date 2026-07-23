#!/usr/bin/env python3
# erf-init v1.1 — Init 1C external report scaffold
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Generates minimal XML source files for a 1C external report."""
import sys, os, argparse, uuid

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
    parser = argparse.ArgumentParser(description='Init 1C external report scaffold', allow_abbrev=False)
    parser.add_argument('-Name', dest='Name', required=True)
    parser.add_argument('-Synonym', dest='Synonym', default=None)
    parser.add_argument('-SrcDir', dest='SrcDir', default='src')
    parser.add_argument('-WithSKD', dest='WithSKD', action='store_true')
    args = parser.parse_args()

    name = args.Name
    synonym = args.Synonym if args.Synonym else name
    src_dir = args.SrcDir

    uuid1 = new_uuid()
    uuid2 = new_uuid()
    uuid3 = new_uuid()
    uuid4 = new_uuid()

    # --- Properties ---
    main_dcs_value = ""
    child_objects_content = ""

    if args.WithSKD:
        main_dcs_value = f"ExternalReport.{name}.Template.ОсновнаяСхемаКомпоновкиДанных"
        child_objects_content = f"\n\t\t\t<Template>ОсновнаяСхемаКомпоновкиДанных</Template>\n"

    main_dcs_element = f"<MainDataCompositionSchema>{main_dcs_value}</MainDataCompositionSchema>" if main_dcs_value else "<MainDataCompositionSchema/>"
    child_objects_xml = f"<ChildObjects>{child_objects_content}\t\t</ChildObjects>" if child_objects_content else "<ChildObjects/>"

    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
\t<ExternalReport uuid="{uuid1}">
\t\t<InternalInfo>
\t\t\t<xr:ContainedObject>
\t\t\t\t<xr:ClassId>e41aff26-25cf-4bb6-b6c1-3f478a75f374</xr:ClassId>
\t\t\t\t<xr:ObjectId>{uuid2}</xr:ObjectId>
\t\t\t</xr:ContainedObject>
\t\t\t<xr:GeneratedType name="ExternalReportObject.{name}" category="Object">
\t\t\t\t<xr:TypeId>{uuid3}</xr:TypeId>
\t\t\t\t<xr:ValueId>{uuid4}</xr:ValueId>
\t\t\t</xr:GeneratedType>
\t\t</InternalInfo>
\t\t<Properties>
\t\t\t<Name>{esc_xml(name)}</Name>
\t\t\t<Synonym>
\t\t\t\t<v8:item>
\t\t\t\t\t<v8:lang>ru</v8:lang>
\t\t\t\t\t<v8:content>{esc_xml(synonym)}</v8:content>
\t\t\t\t</v8:item>
\t\t\t</Synonym>
\t\t\t<Comment/>
\t\t\t<DefaultForm/>
\t\t\t<AuxiliaryForm/>
\t\t\t{main_dcs_element}
\t\t\t<DefaultSettingsForm/>
\t\t\t<AuxiliarySettingsForm/>
\t\t\t<DefaultVariantForm/>
\t\t\t<VariantsStorage/>
\t\t\t<SettingsStorage/>
\t\t</Properties>
\t\t{child_objects_xml}
\t</ExternalReport>
</MetaDataObject>'''

    root_file = os.path.join(src_dir, f"{name}.xml")
    report_dir = os.path.join(src_dir, name)

    if os.path.exists(root_file):
        print(f"Файл уже существует: {root_file}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(src_dir, exist_ok=True)
    ext_dir = os.path.join(report_dir, "Ext")
    os.makedirs(ext_dir, exist_ok=True)

    write_utf8_bom(os.path.join(os.path.abspath(src_dir), f"{name}.xml"), xml)

    # --- Модуль объекта ---
    module_bsl = """\
#Область ОписаниеПеременных

#КонецОбласти

#Область ПрограммныйИнтерфейс

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

#КонецОбласти"""

    module_path = os.path.join(ext_dir, "ObjectModule.bsl")
    write_utf8_bom(module_path, module_bsl)

    print(f"[OK] Создан отчёт: {root_file}")
    print(f"     Каталог: {report_dir}")
    print(f"     Модуль:  {module_path}")

    # --- СКД-макет ---
    if args.WithSKD:
        templates_dir = os.path.join(report_dir, "Templates")
        skd_name = "ОсновнаяСхемаКомпоновкиДанных"
        skd_meta_path = os.path.join(templates_dir, f"{skd_name}.xml")
        skd_ext_dir = os.path.join(templates_dir, skd_name, "Ext")
        os.makedirs(skd_ext_dir, exist_ok=True)

        skd_uuid = new_uuid()

        skd_meta_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
\t<Template uuid="{skd_uuid}">
\t\t<Properties>
\t\t\t<Name>{skd_name}</Name>
\t\t\t<Synonym>
\t\t\t\t<v8:item>
\t\t\t\t\t<v8:lang>ru</v8:lang>
\t\t\t\t\t<v8:content>Основная схема компоновки данных</v8:content>
\t\t\t\t</v8:item>
\t\t\t</Synonym>
\t\t\t<Comment/>
\t\t\t<TemplateType>DataCompositionSchema</TemplateType>
\t\t</Properties>
\t</Template>
</MetaDataObject>'''

        write_utf8_bom(skd_meta_path, skd_meta_xml)

        skd_content = '''<?xml version="1.0" encoding="UTF-8"?>
<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"
\t\txmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"
\t\txmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
\t\txmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
\t\txmlns:v8="http://v8.1c.ru/8.1/data/core"
\t\txmlns:v8ui="http://v8.1c.ru/8.1/data/ui"
\t\txmlns:xs="http://www.w3.org/2001/XMLSchema"
\t\txmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
\t<dataSource>
\t\t<name>ИсточникДанных1</name>
\t\t<dataSourceType>Local</dataSourceType>
\t</dataSource>
</DataCompositionSchema>'''

        skd_file_path = os.path.join(skd_ext_dir, "Template.xml")
        write_utf8_bom(skd_file_path, skd_content)

        print(f"     СКД:     {skd_meta_path}")
        print(f"     Тело:    {skd_file_path}")

if __name__ == '__main__':
    main()
