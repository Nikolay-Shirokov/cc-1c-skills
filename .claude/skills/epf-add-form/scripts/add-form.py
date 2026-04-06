#!/usr/bin/env python3
# add-form v1.1 — Add managed form to 1C external data processor
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
import uuid

from lxml import etree

NSMAP = {"md": "http://v8.1c.ru/8.3/MDClasses"}


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


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Add managed form to 1C processor", allow_abbrev=False)
    parser.add_argument("-ProcessorName", required=True)
    parser.add_argument("-FormName", required=True)
    parser.add_argument("-Synonym", default=None)
    parser.add_argument("-Main", action="store_true")
    parser.add_argument("-SrcDir", default="src")
    args = parser.parse_args()

    processor_name = args.ProcessorName
    form_name = args.FormName
    synonym = args.Synonym if args.Synonym is not None else form_name
    is_main = args.Main
    src_dir = args.SrcDir

    format_version = detect_format_version(os.path.abspath(src_dir))

    # --- Checks ---

    root_xml_path = os.path.join(src_dir, f"{processor_name}.xml")
    if not os.path.exists(root_xml_path):
        print(f"Корневой файл обработки не найден: {root_xml_path}. Сначала выполните epf-init.", file=sys.stderr)
        sys.exit(1)

    processor_dir = os.path.join(src_dir, processor_name)
    forms_dir = os.path.join(processor_dir, "Forms")
    form_meta_path = os.path.join(forms_dir, f"{form_name}.xml")

    if os.path.exists(form_meta_path):
        print(f"Форма уже существует: {form_meta_path}", file=sys.stderr)
        sys.exit(1)

    # --- Create directories ---

    form_dir = os.path.join(forms_dir, form_name)
    form_ext_dir = os.path.join(form_dir, "Ext")
    form_module_dir = os.path.join(form_ext_dir, "Form")

    os.makedirs(form_module_dir, exist_ok=True)

    # --- 1. Form metadata (Forms/<FormName>.xml) ---

    form_uuid = str(uuid.uuid4())

    form_meta_xml = (
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
        f'\t<Form uuid="{form_uuid}">\n'
        '\t\t<Properties>\n'
        f'\t\t\t<Name>{form_name}</Name>\n'
        '\t\t\t<Synonym>\n'
        '\t\t\t\t<v8:item>\n'
        '\t\t\t\t\t<v8:lang>ru</v8:lang>\n'
        f'\t\t\t\t\t<v8:content>{synonym}</v8:content>\n'
        '\t\t\t\t</v8:item>\n'
        '\t\t\t</Synonym>\n'
        '\t\t\t<Comment/>\n'
        '\t\t\t<FormType>Managed</FormType>\n'
        '\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>\n'
        '\t\t\t<UsePurposes>\n'
        '\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>\n'
        '\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>\n'
        '\t\t\t</UsePurposes>\n'
        '\t\t\t<ExtendedPresentation/>\n'
        '\t\t</Properties>\n'
        '\t</Form>\n'
        '</MetaDataObject>'
    )

    write_text_with_bom(form_meta_path, form_meta_xml)

    # --- 2. Form description (Forms/<FormName>/Ext/Form.xml) ---

    form_xml_path = os.path.join(form_ext_dir, "Form.xml")

    form_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Form xmlns="http://v8.1c.ru/8.3/xcf/logform"'
        ' xmlns:app="http://v8.1c.ru/8.2/managed-application/core"'
        ' xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"'
        ' xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"'
        ' xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"'
        ' xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"'
        ' xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"'
        ' xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
        ' xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"'
        ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
        ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
        ' xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"'
        ' xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"'
        ' xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"'
        ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
        f' version="{format_version}">\n'
        '\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">\n'
        '\t\t<Autofill>true</Autofill>\n'
        '\t</AutoCommandBar>\n'
        '\t<ChildItems/>\n'
        '\t<Attributes>\n'
        f'\t\t<Attribute name="\u041e\u0431\u044a\u0435\u043a\u0442" id="1">\n'
        '\t\t\t<Type>\n'
        f'\t\t\t\t<v8:Type>cfg:ExternalDataProcessorObject.{processor_name}</v8:Type>\n'
        '\t\t\t</Type>\n'
        '\t\t\t<MainAttribute>true</MainAttribute>\n'
        '\t\t</Attribute>\n'
        '\t</Attributes>\n'
        '</Form>'
    )

    write_text_with_bom(form_xml_path, form_xml)

    # --- 3. BSL module (Forms/<FormName>/Ext/Form/Module.bsl) ---

    module_path = os.path.join(form_module_dir, "Module.bsl")

    module_bsl = (
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u0421\u043e\u0431\u044b\u0442\u0438\u0439\u0424\u043e\u0440\u043c\u044b\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u0421\u043e\u0431\u044b\u0442\u0438\u0439\u042d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432\u0424\u043e\u0440\u043c\u044b\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u041a\u043e\u043c\u0430\u043d\u0434\u0424\u043e\u0440\u043c\u044b\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u041e\u043f\u043e\u0432\u0435\u0449\u0435\u043d\u0438\u0439\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u0421\u043b\u0443\u0436\u0435\u0431\u043d\u044b\u0435\u041f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u044b\u0418\u0424\u0443\u043d\u043a\u0446\u0438\u0438\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438'
    )

    write_text_with_bom(module_path, module_bsl)

    # --- 4. Modify root XML ---

    root_xml_full = os.path.abspath(root_xml_path)
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(root_xml_full, parser_xml)
    root = tree.getroot()

    ns = "http://v8.1c.ru/8.3/MDClasses"
    child_objects = root.find(".//md:ChildObjects", NSMAP)
    if child_objects is None:
        print(f"Не найден элемент ChildObjects в {root_xml_path}", file=sys.stderr)
        sys.exit(1)

    # Add <Form> before first <Template>, or at end
    form_elem = etree.Element(f"{{{ns}}}Form")
    form_elem.text = form_name

    first_template = child_objects.find("md:Template", NSMAP)
    if first_template is not None:
        # Insert before Template, adding newline + indent
        idx = list(child_objects).index(first_template)
        child_objects.insert(idx, form_elem)
        # Set whitespace: form_elem gets same tail pattern
        form_elem.tail = "\n\t\t\t"
    else:
        # Add to end of ChildObjects
        children = list(child_objects)
        if len(children) == 0 and (child_objects.text is None or child_objects.text.strip() == ""):
            # Empty ChildObjects (self-closing)
            child_objects.text = "\n\t\t\t"
            child_objects.append(form_elem)
            form_elem.tail = "\n\t\t"
        else:
            if len(children) > 0:
                last_child = children[-1]
                old_tail = last_child.tail
                last_child.tail = "\n\t\t\t"
                child_objects.append(form_elem)
                form_elem.tail = old_tail if old_tail else "\n\t\t"
            else:
                child_objects.text = (child_objects.text or "") + "\n\t\t\t"
                child_objects.append(form_elem)
                form_elem.tail = "\n\t\t"

    # Update DefaultForm: explicitly with -Main, or automatically if this is the first form
    existing_forms = child_objects.findall("md:Form", NSMAP)
    is_first_form = len(existing_forms) == 1

    if is_main or is_first_form:
        default_form = root.find(".//md:DefaultForm", NSMAP)
        if default_form is not None:
            default_form.text = f"ExternalDataProcessor.{processor_name}.Form.{form_name}"

    # Save with BOM
    save_xml_with_bom(tree, root_xml_full)

    print(f"[OK] Создана форма: {form_name}")
    print(f"     Метаданные: {form_meta_path}")
    print(f"     Описание:   {form_xml_path}")
    print(f"     Модуль:     {module_path}")
    if is_main or is_first_form:
        print("     DefaultForm обновлён")


if __name__ == "__main__":
    main()
