#!/usr/bin/env python3
# form-add v1.3 — Add managed form to 1C config object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
import uuid

from lxml import etree

NSMAP = {
    "md": "http://v8.1c.ru/8.3/MDClasses",
    "v8": "http://v8.1c.ru/8.1/data/core",
}


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
    parser = argparse.ArgumentParser(description="Add managed form to 1C config object", allow_abbrev=False)
    parser.add_argument("-ObjectPath", required=True)
    parser.add_argument("-FormName", required=True)
    parser.add_argument("-Synonym", default=None)
    parser.add_argument("-Purpose", default="Object")
    parser.add_argument("-SetDefault", action="store_true")
    args = parser.parse_args()

    object_path = args.ObjectPath
    form_name = args.FormName
    synonym = args.Synonym if args.Synonym is not None else form_name
    purpose = args.Purpose
    set_default = args.SetDefault

    # --- Phase 1: Determine object type ---

    # Resolve ObjectPath (directory → .xml)
    if not os.path.isabs(object_path):
        object_path = os.path.join(os.getcwd(), object_path)
    if os.path.isdir(object_path):
        dir_name = os.path.basename(object_path.rstrip("/\\"))
        candidate = os.path.join(object_path, dir_name + ".xml")
        sibling = os.path.join(os.path.dirname(object_path.rstrip("/\\")), dir_name + ".xml")
        if os.path.isfile(candidate):
            object_path = candidate
        elif os.path.isfile(sibling):
            object_path = sibling
    if not os.path.isfile(object_path):
        print(f"Файл объекта не найден: {object_path}", file=sys.stderr)
        sys.exit(1)

    object_xml_full = os.path.abspath(object_path)
    format_version = detect_format_version(os.path.dirname(object_xml_full))

    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(object_xml_full, parser_xml)
    root = tree.getroot()

    supported_types = [
        "Document", "Catalog", "DataProcessor", "Report",
        "ExternalDataProcessor", "ExternalReport",
        "InformationRegister", "ChartOfAccounts", "ChartOfCharacteristicTypes",
        "ExchangePlan", "BusinessProcess", "Task",
    ]

    object_type = None
    object_node = None
    for t in supported_types:
        node = root.find(f".//md:{t}", NSMAP)
        if node is not None:
            object_type = t
            object_node = node
            break

    if object_type is None:
        print(f"Не удалось определить тип объекта. Поддерживаемые типы: {', '.join(supported_types)}", file=sys.stderr)
        sys.exit(1)

    # Object name from Properties/Name
    name_node = root.find(f".//md:{object_type}/md:Properties/md:Name", NSMAP)
    if name_node is None or not name_node.text:
        print("Не удалось определить имя объекта из Properties/Name", file=sys.stderr)
        sys.exit(1)
    object_name = name_node.text

    print()
    print("=== form-add ===")
    print()
    print(f"Object: {object_type}.{object_name}")

    # --- Phase 2: Validate Purpose ---

    # Normalize: capitalize first letter, lowercase rest
    purpose = purpose[0].upper() + purpose[1:].lower()

    valid_purposes = ["Object", "List", "Choice", "Record"]
    if purpose not in valid_purposes:
        print(f"Недопустимое назначение: {purpose}. Допустимые: Object, List, Choice, Record", file=sys.stderr)
        sys.exit(1)

    object_like_types = ["Document", "Catalog", "ChartOfAccounts", "ChartOfCharacteristicTypes",
                         "ExchangePlan", "BusinessProcess", "Task"]
    processor_like_types = ["DataProcessor", "Report", "ExternalDataProcessor", "ExternalReport"]

    if purpose == "List":
        if object_type == "DataProcessor":
            print("Purpose=List недопустим для DataProcessor", file=sys.stderr)
            sys.exit(1)

    elif purpose == "Choice":
        if object_type in processor_like_types or object_type == "InformationRegister":
            print(f"Purpose=Choice недопустим для {object_type}", file=sys.stderr)
            sys.exit(1)

    elif purpose == "Record":
        if object_type != "InformationRegister":
            print("Purpose=Record допустим только для InformationRegister", file=sys.stderr)
            sys.exit(1)

    # --- Phase 3: Create files ---

    object_dir = os.path.splitext(object_xml_full)[0]
    forms_dir = os.path.join(object_dir, "Forms")
    form_meta_path = os.path.join(forms_dir, f"{form_name}.xml")

    if os.path.exists(form_meta_path):
        print(f"Форма уже существует: {form_meta_path}", file=sys.stderr)
        sys.exit(1)

    form_dir = os.path.join(forms_dir, form_name)
    form_ext_dir = os.path.join(form_dir, "Ext")
    form_module_dir = os.path.join(form_ext_dir, "Form")

    os.makedirs(form_module_dir, exist_ok=True)

    # --- 3a. Form metadata ---

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
        + ('\t\t\t<ExtendedPresentation/>\n' if object_type in processor_like_types else '')
        + '\t\t</Properties>\n'
        '\t</Form>\n'
        '</MetaDataObject>'
    )

    write_text_with_bom(form_meta_path, form_meta_xml)

    # --- 3b. Form.xml ---

    form_xml_path = os.path.join(form_ext_dir, "Form.xml")

    form_ns_decl = (
        'xmlns="http://v8.1c.ru/8.3/xcf/logform"'
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
    )

    if purpose in ("List", "Choice"):
        # Dynamic list
        main_table = f"{object_type}.{object_name}"

        form_xml = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<Form {form_ns_decl} version="{format_version}">\n'
            '\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">\n'
            '\t\t<Autofill>true</Autofill>\n'
            '\t</AutoCommandBar>\n'
            '\t<Events>\n'
            '\t\t<Event name="OnCreateAtServer">\u041f\u0440\u0438\u0421\u043e\u0437\u0434\u0430\u043d\u0438\u0438\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435</Event>\n'
            '\t</Events>\n'
            '\t<ChildItems/>\n'
            '\t<Attributes>\n'
            '\t\t<Attribute name="\u0421\u043f\u0438\u0441\u043e\u043a" id="1">\n'
            '\t\t\t<Type>\n'
            '\t\t\t\t<v8:Type>cfg:DynamicList</v8:Type>\n'
            '\t\t\t</Type>\n'
            '\t\t\t<MainAttribute>true</MainAttribute>\n'
            '\t\t\t<Settings xsi:type="DynamicList">\n'
            f'\t\t\t\t<MainTable>{main_table}</MainTable>\n'
            '\t\t\t</Settings>\n'
            '\t\t</Attribute>\n'
            '\t</Attributes>\n'
            '</Form>'
        )

    elif purpose == "Record":
        # Information register record
        main_attr_name = "\u0417\u0430\u043f\u0438\u0441\u044c"
        main_attr_type = f"InformationRegisterRecordManager.{object_name}"

        form_xml = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<Form {form_ns_decl} version="{format_version}">\n'
            '\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">\n'
            '\t\t<Autofill>true</Autofill>\n'
            '\t</AutoCommandBar>\n'
            '\t<Events>\n'
            '\t\t<Event name="OnCreateAtServer">\u041f\u0440\u0438\u0421\u043e\u0437\u0434\u0430\u043d\u0438\u0438\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435</Event>\n'
            '\t</Events>\n'
            '\t<ChildItems/>\n'
            '\t<Attributes>\n'
            f'\t\t<Attribute name="{main_attr_name}" id="1">\n'
            '\t\t\t<Type>\n'
            f'\t\t\t\t<v8:Type>cfg:{main_attr_type}</v8:Type>\n'
            '\t\t\t</Type>\n'
            '\t\t\t<MainAttribute>true</MainAttribute>\n'
            '\t\t\t<SavedData>true</SavedData>\n'
            '\t\t</Attribute>\n'
            '\t</Attributes>\n'
            '</Form>'
        )

    else:
        # Object — object form
        main_attr_name = "\u041e\u0431\u044a\u0435\u043a\u0442"

        attr_type_map = {
            "Document": "DocumentObject",
            "Catalog": "CatalogObject",
            "DataProcessor": "DataProcessorObject",
            "Report": "ReportObject",
            "ExternalDataProcessor": "ExternalDataProcessorObject",
            "ExternalReport": "ExternalReportObject",
            "ChartOfAccounts": "ChartOfAccountsObject",
            "ChartOfCharacteristicTypes": "ChartOfCharacteristicTypesObject",
            "ExchangePlan": "ExchangePlanObject",
            "BusinessProcess": "BusinessProcessObject",
            "Task": "TaskObject",
            "InformationRegister": "InformationRegisterRecordManager",
        }

        main_attr_type = f"{attr_type_map[object_type]}.{object_name}"

        form_xml = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<Form {form_ns_decl} version="{format_version}">\n'
            '\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">\n'
            '\t\t<Autofill>true</Autofill>\n'
            '\t</AutoCommandBar>\n'
            '\t<Events>\n'
            '\t\t<Event name="OnCreateAtServer">\u041f\u0440\u0438\u0421\u043e\u0437\u0434\u0430\u043d\u0438\u0438\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435</Event>\n'
            '\t</Events>\n'
            '\t<ChildItems/>\n'
            '\t<Attributes>\n'
            f'\t\t<Attribute name="{main_attr_name}" id="1">\n'
            '\t\t\t<Type>\n'
            f'\t\t\t\t<v8:Type>cfg:{main_attr_type}</v8:Type>\n'
            '\t\t\t</Type>\n'
            '\t\t\t<MainAttribute>true</MainAttribute>\n'
            '\t\t\t<SavedData>true</SavedData>\n'
            '\t\t</Attribute>\n'
            '\t</Attributes>\n'
            '</Form>'
        )

    if os.path.exists(form_xml_path):
        print(f"[SKIP] Form.xml already exists: {form_xml_path} — not overwriting")
    else:
        write_text_with_bom(form_xml_path, form_xml)

    # --- 3c. Module.bsl ---

    module_path = os.path.join(form_module_dir, "Module.bsl")

    module_bsl = (
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u0421\u043e\u0431\u044b\u0442\u0438\u0439\u0424\u043e\u0440\u043c\u044b\n'
        '\n'
        '&\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435\n'
        '\u041f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u0430 \u041f\u0440\u0438\u0421\u043e\u0437\u0434\u0430\u043d\u0438\u0438\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435(\u041e\u0442\u043a\u0430\u0437, \u0421\u0442\u0430\u043d\u0434\u0430\u0440\u0442\u043d\u0430\u044f\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430)\n'
        '\n'
        '\u041a\u043e\u043d\u0435\u0446\u041f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u044b\n'
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

    if os.path.exists(module_path):
        print(f"[SKIP] Module.bsl already exists: {module_path} — not overwriting")
    else:
        write_text_with_bom(module_path, module_bsl)

    # --- Phase 4: Register in parent object ---

    ns = "http://v8.1c.ru/8.3/MDClasses"
    child_objects = root.find(f".//md:{object_type}/md:ChildObjects", NSMAP)
    if child_objects is None:
        print(f"Не найден элемент ChildObjects в {object_path}", file=sys.stderr)
        sys.exit(1)

    # Add <Form>$FormName</Form>
    form_elem = etree.Element(f"{{{ns}}}Form")
    form_elem.text = form_name

    # Find first <Template> to insert before it
    first_template = child_objects.find("md:Template", NSMAP)
    # Find first <TabularSection> to insert before it (if no Template)
    first_tabular = child_objects.find("md:TabularSection", NSMAP)

    # Determine insertion point: before Template, before TabularSection, or at end
    insert_before = None
    if first_template is not None:
        insert_before = first_template
    elif first_tabular is not None:
        insert_before = first_tabular

    if insert_before is not None:
        # Insert before the found element
        idx = list(child_objects).index(insert_before)
        child_objects.insert(idx, form_elem)
        # Whitespace: form_elem gets "\n\t\t\t" as tail (indent before insert_before)
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

    # --- SetDefault ---

    is_first_form_for_purpose = False
    default_prop_name = None
    default_value = f"{object_type}.{object_name}.Form.{form_name}"

    # Determine property name for DefaultForm
    if purpose == "Object":
        if object_type in processor_like_types:
            default_prop_name = "DefaultForm"
        else:
            default_prop_name = "DefaultObjectForm"
    elif purpose == "List":
        default_prop_name = "DefaultListForm"
    elif purpose == "Choice":
        default_prop_name = "DefaultChoiceForm"
    elif purpose == "Record":
        default_prop_name = "DefaultRecordForm"

    # Check if value is already set
    default_node = root.find(f".//md:{object_type}/md:Properties/md:{default_prop_name}", NSMAP)
    if default_node is not None:
        is_first_form_for_purpose = default_node.text is None or default_node.text.strip() == ""

    default_updated = False
    if set_default or is_first_form_for_purpose:
        if default_node is not None:
            default_node.text = default_value
            default_updated = True

    # Save with BOM
    save_xml_with_bom(tree, object_xml_full)

    # --- Phase 5: Output ---

    obj_dir_name = os.path.dirname(object_path)
    obj_base_name = os.path.splitext(os.path.basename(object_path))[0]

    print("Created:")
    print(f"  Metadata: {obj_dir_name}\\{obj_base_name}\\Forms\\{form_name}.xml")
    print(f"  Form:     {obj_dir_name}\\{obj_base_name}\\Forms\\{form_name}\\Ext\\Form.xml")
    print(f"  Module:   {obj_dir_name}\\{obj_base_name}\\Forms\\{form_name}\\Ext\\Form\\Module.bsl")
    print()
    print(f"Registered: <Form>{form_name}</Form> in ChildObjects")
    if default_updated:
        print(f"{default_prop_name}: {default_value}")
    print()


if __name__ == "__main__":
    main()
