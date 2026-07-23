#!/usr/bin/env python3
# epf-init v1.1 — Init 1C external data processor scaffold
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Generates minimal XML source files for a 1C external data processor."""
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
    parser = argparse.ArgumentParser(description='Init 1C external data processor scaffold', allow_abbrev=False)
    parser.add_argument('-Name', dest='Name', required=True)
    parser.add_argument('-Synonym', dest='Synonym', default=None)
    parser.add_argument('-SrcDir', dest='SrcDir', default='src')
    args = parser.parse_args()

    name = args.Name
    synonym = args.Synonym if args.Synonym else name
    src_dir = args.SrcDir

    uuid1 = new_uuid()
    uuid2 = new_uuid()
    uuid3 = new_uuid()
    uuid4 = new_uuid()

    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
\t<ExternalDataProcessor uuid="{uuid1}">
\t\t<InternalInfo>
\t\t\t<xr:ContainedObject>
\t\t\t\t<xr:ClassId>c3831ec8-d8d5-4f93-8a22-f9bfae07327f</xr:ClassId>
\t\t\t\t<xr:ObjectId>{uuid2}</xr:ObjectId>
\t\t\t</xr:ContainedObject>
\t\t\t<xr:GeneratedType name="ExternalDataProcessorObject.{name}" category="Object">
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
\t\t</Properties>
\t\t<ChildObjects/>
\t</ExternalDataProcessor>
</MetaDataObject>'''

    root_file = os.path.join(src_dir, f"{name}.xml")
    processor_dir = os.path.join(src_dir, name)

    if os.path.exists(root_file):
        print(f"Файл уже существует: {root_file}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(src_dir, exist_ok=True)
    ext_dir = os.path.join(processor_dir, "Ext")
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

    print(f"[OK] Создана обработка: {root_file}")
    print(f"     Каталог: {processor_dir}")
    print(f"     Модуль:  {module_path}")

if __name__ == '__main__':
    main()
