#!/usr/bin/env python3
# remove-template v1.1 — Remove template from 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import shutil
import sys

from lxml import etree

NSMAP = {"md": "http://v8.1c.ru/8.3/MDClasses"}


def save_xml_with_bom(tree, path):
    """Save XML tree to file with UTF-8 BOM."""
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    xml_bytes = xml_bytes.replace(b"<?xml version='1.0' encoding='UTF-8'?>", b'<?xml version="1.0" encoding="utf-8"?>')
    if not xml_bytes.endswith(b"\n"):
        xml_bytes += b"\n"
    with open(path, "wb") as f:
        f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Remove template from 1C object", allow_abbrev=False)
    parser.add_argument("-ObjectName", "-ProcessorName", required=True)
    parser.add_argument("-TemplateName", required=True)
    parser.add_argument("-SrcDir", default="src")
    args = parser.parse_args()

    object_name = args.ObjectName
    template_name = args.TemplateName
    src_dir = args.SrcDir

    # --- Checks ---

    root_xml_path = os.path.join(src_dir, f"{object_name}.xml")
    if not os.path.exists(root_xml_path):
        print(f"Корневой файл обработки не найден: {root_xml_path}", file=sys.stderr)
        sys.exit(1)

    processor_dir = os.path.join(src_dir, object_name)
    templates_dir = os.path.join(processor_dir, "Templates")
    template_meta_path = os.path.join(templates_dir, f"{template_name}.xml")
    template_dir = os.path.join(templates_dir, template_name)

    if not os.path.exists(template_meta_path):
        print(f"Метаданные макета не найдены: {template_meta_path}", file=sys.stderr)
        sys.exit(1)

    # --- Delete files ---

    if os.path.isdir(template_dir):
        shutil.rmtree(template_dir)
        print(f"[OK] Удалён каталог: {template_dir}")

    os.remove(template_meta_path)
    print(f"[OK] Удалён файл: {template_meta_path}")

    # --- Modify root XML ---

    root_xml_full = os.path.abspath(root_xml_path)
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(root_xml_full, parser_xml)
    root = tree.getroot()

    # Remove <Template>TemplateName</Template> from ChildObjects
    for node in root.findall(".//md:ChildObjects/md:Template", NSMAP):
        if node.text and node.text.strip() == template_name:
            parent = node.getparent()
            prev = node.getprevious()
            if prev is not None:
                # Whitespace is in prev.tail
                if prev.tail and prev.tail.strip() == "":
                    prev.tail = ""
            else:
                # First child — whitespace is in parent.text
                if parent.text and parent.text.strip() == "":
                    parent.text = ""
            parent.remove(node)
            break

    # Clear MainDataCompositionSchema if it pointed to this template
    main_dcs = root.find(".//md:MainDataCompositionSchema", NSMAP)
    if main_dcs is not None and main_dcs.text:
        if re.search(rf"Template\.{re.escape(template_name)}$", main_dcs.text):
            main_dcs.text = ""
            print("[OK] Очищён MainDataCompositionSchema")

    # Save with BOM
    save_xml_with_bom(tree, root_xml_full)

    print(f"[OK] Макет {template_name} удалён из {root_xml_path}")


if __name__ == "__main__":
    main()
