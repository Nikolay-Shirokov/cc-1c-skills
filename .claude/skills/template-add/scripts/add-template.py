#!/usr/bin/env python3
# add-template v1.3 — Add template to 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
import uuid

from lxml import etree

NSMAP = {"md": "http://v8.1c.ru/8.3/MDClasses"}

TYPE_MAP = {
    "HTML": {"TemplateType": "HTMLDocument", "Ext": ".html"},
    "Text": {"TemplateType": "TextDocument", "Ext": ".txt"},
    "SpreadsheetDocument": {"TemplateType": "SpreadsheetDocument", "Ext": ".xml"},
    "BinaryData": {"TemplateType": "BinaryData", "Ext": ".bin"},
    "DataCompositionSchema": {"TemplateType": "DataCompositionSchema", "Ext": ".xml"},
}


def save_xml_with_bom(tree, path):
    """Save XML tree to file with UTF-8 BOM."""
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    xml_bytes = xml_bytes.replace(b"<?xml version='1.0' encoding='UTF-8'?>", b'<?xml version="1.0" encoding="utf-8"?>')
    if not xml_bytes.endswith(b"\n"):
        xml_bytes += b"\n"
    with open(path, "wb") as f:
        f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


def write_text_with_bom(path, text):
    """Write text to file with UTF-8 BOM."""
    with open(path, "w", encoding="utf-8-sig") as f:
        f.write(text)


def detect_format_version(d):
    while d:
        cfg_path = os.path.join(d, "Configuration.xml")
        if os.path.isfile(cfg_path):
            with open(cfg_path, "r", encoding="utf-8-sig") as f:
                head = f.read(2000)
            m = re.search(r'<MetaDataObject[^>]+version="(\d+\.\d+)"', head)
            if m:
                return m.group(1)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return "2.17"


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Add template to 1C object", allow_abbrev=False)
    parser.add_argument("-ObjectName", "-ProcessorName", required=True)
    parser.add_argument("-TemplateName", required=True)
    parser.add_argument("-TemplateType", required=True,
                        choices=["HTML", "Text", "SpreadsheetDocument", "BinaryData", "DataCompositionSchema"])
    parser.add_argument("-Synonym", default=None)
    parser.add_argument("-SrcDir", default="src")
    parser.add_argument("-SetMainSKD", action="store_true")
    args = parser.parse_args()

    object_name = args.ObjectName
    template_name = args.TemplateName
    template_type = args.TemplateType
    synonym = args.Synonym if args.Synonym is not None else template_name
    src_dir = args.SrcDir
    set_main_skd = args.SetMainSKD

    tmpl = TYPE_MAP[template_type]

    format_version = detect_format_version(os.path.abspath(src_dir))

    # --- Checks ---

    root_xml_path = os.path.join(src_dir, f"{object_name}.xml")
    if not os.path.exists(root_xml_path):
        print(f"Корневой файл объекта не найден: {root_xml_path}", file=sys.stderr)
        print(f"Ожидается: <SrcDir>/<ObjectName>/<ObjectName>.xml", file=sys.stderr)
        print(f"Подсказка: SrcDir должен указывать на папку типа объектов (например Reports), а не на корень конфигурации", file=sys.stderr)
        sys.exit(1)

    processor_dir = os.path.join(src_dir, object_name)
    templates_dir = os.path.join(processor_dir, "Templates")
    template_meta_path = os.path.join(templates_dir, f"{template_name}.xml")

    if os.path.exists(template_meta_path):
        print(f"Макет уже существует: {template_meta_path}", file=sys.stderr)
        sys.exit(1)

    # --- Create directories ---

    template_ext_dir = os.path.join(templates_dir, template_name, "Ext")
    os.makedirs(template_ext_dir, exist_ok=True)

    # --- 1. Template metadata (Templates/<TemplateName>.xml) ---

    template_uuid = str(uuid.uuid4())

    template_meta_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"'
        ' xmlns:app="http://v8.1c.ru/8.2/managed-application/core"'
        ' xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"'
        ' xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi"'
        ' xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"'
        ' xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"'
        ' xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
        ' xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"'
        ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
        ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
        ' xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"'
        ' xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"'
        ' xmlns:xen="http://v8.1c.ru/8.3/xcf/enums"'
        ' xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef"'
        ' xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"'
        ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
        f' version="{format_version}">\n'
        f'\t<Template uuid="{template_uuid}">\n'
        '\t\t<Properties>\n'
        f'\t\t\t<Name>{template_name}</Name>\n'
        '\t\t\t<Synonym>\n'
        '\t\t\t\t<v8:item>\n'
        '\t\t\t\t\t<v8:lang>ru</v8:lang>\n'
        f'\t\t\t\t\t<v8:content>{synonym}</v8:content>\n'
        '\t\t\t\t</v8:item>\n'
        '\t\t\t</Synonym>\n'
        '\t\t\t<Comment/>\n'
        f'\t\t\t<TemplateType>{tmpl["TemplateType"]}</TemplateType>\n'
        '\t\t</Properties>\n'
        '\t</Template>\n'
        '</MetaDataObject>'
    )

    write_text_with_bom(template_meta_path, template_meta_xml)

    # --- 2. Template content (Templates/<TemplateName>/Ext/Template.<ext>) ---

    template_file_path = os.path.join(template_ext_dir, f"Template{tmpl['Ext']}")

    if template_type == "HTML":
        content = (
            '<!DOCTYPE html>\n'
            '<html>\n'
            '<head>\n'
            '\t<meta charset="UTF-8">\n'
            '\t<title></title>\n'
            '</head>\n'
            '<body>\n'
            '</body>\n'
            '</html>'
        )
        write_text_with_bom(template_file_path, content)

    elif template_type == "Text":
        write_text_with_bom(template_file_path, "")

    elif template_type == "SpreadsheetDocument":
        content = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<SpreadsheetDocument xmlns="http://v8.1c.ru/spreadsheet/document"'
            ' xmlns:ss="http://v8.1c.ru/spreadsheet/document"'
            ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
            ' xmlns:xs="http://www.w3.org/2001/XMLSchema">\n'
            '</SpreadsheetDocument>'
        )
        write_text_with_bom(template_file_path, content)

    elif template_type == "BinaryData":
        with open(template_file_path, "wb") as f:
            pass  # empty file

    elif template_type == "DataCompositionSchema":
        content = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"\n'
            '\t\txmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"\n'
            '\t\txmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"\n'
            '\t\txmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"\n'
            '\t\txmlns:v8="http://v8.1c.ru/8.1/data/core"\n'
            '\t\txmlns:v8ui="http://v8.1c.ru/8.1/data/ui"\n'
            '\t\txmlns:xs="http://www.w3.org/2001/XMLSchema"\n'
            '\t\txmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
            '\t<dataSource>\n'
            '\t\t<name>ИсточникДанных1</name>\n'
            '\t\t<dataSourceType>Local</dataSourceType>\n'
            '\t</dataSource>\n'
            '</DataCompositionSchema>'
        )
        write_text_with_bom(template_file_path, content)

    # --- 3. Modify root XML ---

    root_xml_full = os.path.abspath(root_xml_path)
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(root_xml_full, parser_xml)
    root = tree.getroot()

    ns = "http://v8.1c.ru/8.3/MDClasses"
    child_objects = root.find(".//md:ChildObjects", NSMAP)
    if child_objects is None:
        print(f"Не найден элемент ChildObjects в {root_xml_path}", file=sys.stderr)
        sys.exit(1)

    # Add <Template> to end of ChildObjects
    template_elem = etree.SubElement(child_objects, f"{{{ns}}}Template")
    template_elem.text = template_name
    # Remove auto-appended element to reinsert with proper whitespace
    child_objects.remove(template_elem)

    children = list(child_objects)
    if len(children) == 0 and (child_objects.text is None or child_objects.text.strip() == ""):
        # Empty ChildObjects (self-closing)
        child_objects.text = "\n\t\t\t"
        child_objects.append(template_elem)
        template_elem.tail = "\n\t\t"
    else:
        if len(children) > 0:
            last_child = children[-1]
            # last_child.tail is the trailing whitespace before </ChildObjects>
            old_tail = last_child.tail
            last_child.tail = "\n\t\t\t"
            child_objects.append(template_elem)
            template_elem.tail = old_tail if old_tail else "\n\t\t"
        else:
            # Has text content but no element children
            child_objects.text = (child_objects.text or "") + "\n\t\t\t"
            child_objects.append(template_elem)
            template_elem.tail = "\n\t\t"

    # --- 4. MainDataCompositionSchema (for ExternalReport / Report) ---

    main_dcs_updated = False
    if template_type == "DataCompositionSchema":
        report_like_types = ["ExternalReport", "Report"]
        object_type_node = None
        object_type_name = None
        for rt in report_like_types:
            node = root.find(f".//md:{rt}", NSMAP)
            if node is not None:
                object_type_node = node
                object_type_name = rt
                break

        if object_type_node is not None:
            main_dcs = root.find(f".//md:{object_type_name}/md:Properties/md:MainDataCompositionSchema", NSMAP)
            if main_dcs is not None:
                is_empty = main_dcs.text is None or main_dcs.text.strip() == ""
                if is_empty or set_main_skd:
                    obj_name_node = root.find(f".//md:{object_type_name}/md:Properties/md:Name", NSMAP)
                    obj_name = obj_name_node.text if obj_name_node is not None else ""
                    main_dcs.text = f"{object_type_name}.{obj_name}.Template.{template_name}"
                    main_dcs_updated = True

    # Save with BOM
    save_xml_with_bom(tree, root_xml_full)

    print(f"[OK] Создан макет: {template_name} ({template_type})")
    print(f"     Метаданные: {template_meta_path}")
    print(f"     Содержимое: {template_file_path}")
    if main_dcs_updated:
        print(f"     MainDataCompositionSchema: {main_dcs.text}")


if __name__ == "__main__":
    main()
