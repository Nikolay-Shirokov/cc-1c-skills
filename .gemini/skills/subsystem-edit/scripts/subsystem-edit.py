#!/usr/bin/env python3
# subsystem-edit v1.2 — Edit existing 1C subsystem XML
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import subprocess
import sys
import uuid
from lxml import etree


def new_uuid():
    return str(uuid.uuid4())


def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


def write_child_subsystem_stub(child_path, child_name, format_version):
    child_uuid = new_uuid()
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(
        '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" '
        'xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
        'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" '
        'xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" '
        'xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" '
        'xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" '
        'xmlns:style="http://v8.1c.ru/8.1/data/ui/style" '
        'xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" '
        'xmlns:v8="http://v8.1c.ru/8.1/data/core" '
        'xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" '
        'xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" '
        'xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" '
        'xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" '
        'xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" '
        'xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" '
        'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        f'version="{format_version}">'
    )
    lines.append(f'\t<Subsystem uuid="{child_uuid}">')
    lines.append('\t\t<Properties>')
    lines.append(f'\t\t\t<Name>{esc_xml(child_name)}</Name>')
    lines.append('\t\t\t<Synonym/>')
    lines.append('\t\t\t<Comment/>')
    lines.append('\t\t\t<IncludeHelpInContents>true</IncludeHelpInContents>')
    lines.append('\t\t\t<IncludeInCommandInterface>true</IncludeInCommandInterface>')
    lines.append('\t\t\t<UseOneCommand>false</UseOneCommand>')
    lines.append('\t\t\t<Explanation/>')
    lines.append('\t\t\t<Picture/>')
    lines.append('\t\t\t<Content/>')
    lines.append('\t\t</Properties>')
    lines.append('\t\t<ChildObjects/>')
    lines.append('\t</Subsystem>')
    lines.append('</MetaDataObject>')
    write_utf8_bom(child_path, '\n'.join(lines) + '\n')

MD_NS = "http://v8.1c.ru/8.3/MDClasses"
XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
V8_NS = "http://v8.1c.ru/8.1/data/core"
XS_NS = "http://www.w3.org/2001/XMLSchema"

NSMAP_WRAPPER = {
    None: MD_NS,
    "xsi": XSI_NS,
    "v8": V8_NS,
    "xr": XR_NS,
    "xs": XS_NS,
}


CONTENT_TYPE_MAP = {
    'Catalogs': 'Catalog', 'Documents': 'Document', 'Enums': 'Enum',
    'Constants': 'Constant', 'Reports': 'Report', 'DataProcessors': 'DataProcessor',
    'InformationRegisters': 'InformationRegister', 'AccumulationRegisters': 'AccumulationRegister',
    'AccountingRegisters': 'AccountingRegister', 'CalculationRegisters': 'CalculationRegister',
    'ChartsOfAccounts': 'ChartOfAccounts', 'ChartsOfCharacteristicTypes': 'ChartOfCharacteristicTypes',
    'ChartsOfCalculationTypes': 'ChartOfCalculationTypes',
    'BusinessProcesses': 'BusinessProcess', 'Tasks': 'Task',
    'ExchangePlans': 'ExchangePlan', 'DocumentJournals': 'DocumentJournal',
    'CommonModules': 'CommonModule', 'CommonCommands': 'CommonCommand',
    'CommonForms': 'CommonForm', 'CommonPictures': 'CommonPicture',
    'CommonTemplates': 'CommonTemplate', 'CommonAttributes': 'CommonAttribute',
    'CommandGroups': 'CommandGroup', 'Roles': 'Role',
    'SessionParameters': 'SessionParameter', 'FilterCriteria': 'FilterCriterion',
    'XDTOPackages': 'XDTOPackage', 'WebServices': 'WebService',
    'HTTPServices': 'HTTPService', 'WSReferences': 'WSReference',
    'EventSubscriptions': 'EventSubscription', 'ScheduledJobs': 'ScheduledJob',
    'SettingsStorages': 'SettingsStorage', 'FunctionalOptions': 'FunctionalOption',
    'FunctionalOptionsParameters': 'FunctionalOptionsParameter',
    'DefinedTypes': 'DefinedType', 'DocumentNumerators': 'DocumentNumerator',
    'Sequences': 'Sequence', 'Subsystems': 'Subsystem',
    'StyleItems': 'StyleItem', 'IntegrationServices': 'IntegrationService',
    # Russian singular
    'Справочник': 'Catalog', 'Каталог': 'Catalog', 'Документ': 'Document',
    'Перечисление': 'Enum', 'Константа': 'Constant',
    'Отчёт': 'Report', 'Отчет': 'Report', 'Обработка': 'DataProcessor',
    'РегистрСведений': 'InformationRegister', 'РегистрНакопления': 'AccumulationRegister',
    'РегистрБухгалтерии': 'AccountingRegister',
    'РегистрРасчёта': 'CalculationRegister', 'РегистрРасчета': 'CalculationRegister',
    'ПланСчетов': 'ChartOfAccounts', 'ПланВидовХарактеристик': 'ChartOfCharacteristicTypes',
    'ПланВидовРасчёта': 'ChartOfCalculationTypes', 'ПланВидовРасчета': 'ChartOfCalculationTypes',
    'БизнесПроцесс': 'BusinessProcess', 'Задача': 'Task',
    'ПланОбмена': 'ExchangePlan', 'ЖурналДокументов': 'DocumentJournal',
    'ОбщийМодуль': 'CommonModule', 'ОбщаяКоманда': 'CommonCommand',
    'ОбщаяФорма': 'CommonForm', 'ОбщаяКартинка': 'CommonPicture',
    'ОбщийМакет': 'CommonTemplate', 'ОбщийРеквизит': 'CommonAttribute',
    'ГруппаКоманд': 'CommandGroup', 'Роль': 'Role',
    'ПараметрСеанса': 'SessionParameter', 'КритерийОтбора': 'FilterCriterion',
    'ПакетXDTO': 'XDTOPackage', 'ВебСервис': 'WebService',
    'HTTPСервис': 'HTTPService', 'WSСсылка': 'WSReference',
    'ПодпискаНаСобытие': 'EventSubscription', 'РегламентноеЗадание': 'ScheduledJob',
    'ХранилищеНастроек': 'SettingsStorage', 'ФункциональнаяОпция': 'FunctionalOption',
    'ПараметрФункциональныхОпций': 'FunctionalOptionsParameter',
    'ОпределяемыйТип': 'DefinedType', 'Подсистема': 'Subsystem',
    'ЭлементСтиля': 'StyleItem', 'СервисИнтеграции': 'IntegrationService',
    # Russian plural
    'Справочники': 'Catalog', 'Документы': 'Document', 'Перечисления': 'Enum',
    'Константы': 'Constant', 'Отчёты': 'Report', 'Отчеты': 'Report',
    'Обработки': 'DataProcessor', 'РегистрыСведений': 'InformationRegister',
    'РегистрыНакопления': 'AccumulationRegister', 'РегистрыБухгалтерии': 'AccountingRegister',
    'РегистрыРасчёта': 'CalculationRegister', 'РегистрыРасчета': 'CalculationRegister',
    'ПланыСчетов': 'ChartOfAccounts', 'ПланыВидовХарактеристик': 'ChartOfCharacteristicTypes',
    'ПланыВидовРасчёта': 'ChartOfCalculationTypes', 'ПланыВидовРасчета': 'ChartOfCalculationTypes',
    'БизнесПроцессы': 'BusinessProcess', 'Задачи': 'Task',
    'ПланыОбмена': 'ExchangePlan', 'ЖурналыДокументов': 'DocumentJournal',
    'ОбщиеМодули': 'CommonModule', 'ОбщиеКоманды': 'CommonCommand',
    'ОбщиеФормы': 'CommonForm', 'ОбщиеКартинки': 'CommonPicture',
    'ОбщиеМакеты': 'CommonTemplate', 'ОбщиеРеквизиты': 'CommonAttribute',
    'ГруппыКоманд': 'CommandGroup', 'Роли': 'Role',
    'ПараметрыСеанса': 'SessionParameter', 'КритерииОтбора': 'FilterCriterion',
    'ПакетыXDTO': 'XDTOPackage', 'ВебСервисы': 'WebService',
    'HTTPСервисы': 'HTTPService', 'WSСсылки': 'WSReference',
    'ПодпискиНаСобытия': 'EventSubscription', 'РегламентныеЗадания': 'ScheduledJob',
    'ХранилищаНастроек': 'SettingsStorage', 'ФункциональныеОпции': 'FunctionalOption',
    'ОпределяемыеТипы': 'DefinedType', 'Подсистемы': 'Subsystem',
    'ЭлементыСтиля': 'StyleItem', 'СервисыИнтеграции': 'IntegrationService',
}


def normalize_content_ref(ref):
    if not ref or '.' not in ref:
        return ref
    dot_idx = ref.index('.')
    type_part = ref[:dot_idx]
    name_part = ref[dot_idx + 1:]
    if type_part in CONTENT_TYPE_MAP:
        type_part = CONTENT_TYPE_MAP[type_part]
    return f'{type_part}.{name_part}'


def localname(el):
    return etree.QName(el.tag).localname


def info(msg):
    print(f"[INFO] {msg}")


def warn(msg):
    print(f"[WARN] {msg}")


def get_child_indent(container):
    """Detect indentation of children inside a container element."""
    if container.text and "\n" in container.text:
        after_nl = container.text.rsplit("\n", 1)[-1]
        if after_nl and not after_nl.strip():
            return after_nl
    for child in container:
        if child.tail and "\n" in child.tail:
            after_nl = child.tail.rsplit("\n", 1)[-1]
            if after_nl and not after_nl.strip():
                return after_nl
    # Fallback: count depth
    depth = 0
    current = container
    while current is not None:
        depth += 1
        current = current.getparent()
    return "\t" * depth


def insert_before_closing(container, new_el, child_indent):
    """Insert new_el before the closing tag of container, with proper indentation."""
    children = list(container)
    if len(children) == 0:
        # Empty element: set text to newline+indent, tail of new_el to newline+parent_indent
        parent_indent = child_indent[:-1] if len(child_indent) > 0 else ""
        container.text = "\r\n" + child_indent
        new_el.tail = "\r\n" + parent_indent
        container.append(new_el)
    else:
        last = children[-1]
        new_el.tail = last.tail
        last.tail = "\r\n" + child_indent
        container.append(new_el)


def remove_with_indent(el):
    """Remove element and clean up surrounding whitespace."""
    parent = el.getparent()
    prev = el.getprevious()
    if prev is not None:
        # Transfer el.tail to prev.tail
        if el.tail and el.tail.strip() == "":
            pass  # just drop extra whitespace
        prev.tail = el.tail if el.tail and el.tail.strip() else (prev.tail or "")
        # Actually try to keep the prev's tail as the closing indent
        # Better approach: set prev.tail to what el.tail was (newline+indent of next or closing)
        if el.tail:
            prev.tail = el.tail
    else:
        # First child: adjust parent.text
        if el.tail:
            parent.text = el.tail
    parent.remove(el)


def expand_self_closing(container, parent_indent):
    """If container is self-closing (no children, no text), add closing whitespace."""
    if len(container) == 0 and not (container.text and container.text.strip()):
        container.text = "\r\n" + parent_indent


def import_fragment(xml_string, doc_root):
    """Parse an XML fragment in the MD namespace context and return elements."""
    wrapper = (
        f'<_W xmlns="{MD_NS}" xmlns:xsi="{XSI_NS}" xmlns:v8="{V8_NS}" '
        f'xmlns:xr="{XR_NS}" xmlns:xs="{XS_NS}">{xml_string}</_W>'
    )
    frag = etree.fromstring(wrapper.encode("utf-8"))
    nodes = []
    for child in frag:
        nodes.append(child)
    return nodes


def parse_value_list(val):
    """Parse a string or JSON array into a list of strings."""
    val = val.strip()
    if val.startswith("["):
        arr = json.loads(val)
        return [str(item) for item in arr]
    return [val]


def save_xml_bom(tree, path):
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
    parser = argparse.ArgumentParser(description="Edit existing 1C subsystem XML", allow_abbrev=False)
    parser.add_argument("-SubsystemPath", "-Path", required=True)
    parser.add_argument("-DefinitionFile", default=None)
    parser.add_argument("-Operation", default=None, choices=["add-content", "remove-content", "add-child", "remove-child", "set-property"])
    parser.add_argument("-Value", default=None)
    parser.add_argument("-NoValidate", action="store_true")
    args = parser.parse_args()

    # --- Mode validation ---
    if args.DefinitionFile and args.Operation:
        print("Cannot use both -DefinitionFile and -Operation", file=sys.stderr)
        sys.exit(1)
    if not args.DefinitionFile and not args.Operation:
        print("Either -DefinitionFile or -Operation is required", file=sys.stderr)
        sys.exit(1)

    # --- Resolve path ---
    subsystem_path = args.SubsystemPath
    if not os.path.isabs(subsystem_path):
        subsystem_path = os.path.join(os.getcwd(), subsystem_path)

    if os.path.isdir(subsystem_path):
        dir_name = os.path.basename(subsystem_path)
        candidate = os.path.join(subsystem_path, f"{dir_name}.xml")
        sibling = os.path.join(os.path.dirname(subsystem_path), f"{dir_name}.xml")
        if os.path.isfile(candidate):
            subsystem_path = candidate
        elif os.path.isfile(sibling):
            subsystem_path = sibling
        else:
            print(f"No {dir_name}.xml found in directory or as sibling", file=sys.stderr)
            sys.exit(1)

    if not os.path.isfile(subsystem_path):
        fn = os.path.splitext(os.path.basename(subsystem_path))[0]
        pd = os.path.dirname(subsystem_path)
        if fn == os.path.basename(pd):
            c = os.path.join(os.path.dirname(pd), f"{fn}.xml")
            if os.path.isfile(c):
                subsystem_path = c

    if not os.path.isfile(subsystem_path):
        print(f"File not found: {subsystem_path}", file=sys.stderr)
        sys.exit(1)

    resolved_path = os.path.abspath(subsystem_path)

    # --- Load XML ---
    xml_parser = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(resolved_path, xml_parser)
    xml_root = tree.getroot()
    format_version = xml_root.get("version") or "2.17"

    add_count = 0
    remove_count = 0
    modify_count = 0

    # --- Detect structure ---
    sub = None
    for child in xml_root:
        if isinstance(child.tag, str) and localname(child) == "Subsystem":
            sub = child
            break
    if sub is None:
        print("No <Subsystem> element found", file=sys.stderr)
        sys.exit(1)

    props_el = None
    child_objs_el = None
    for child in sub:
        if not isinstance(child.tag, str):
            continue
        if localname(child) == "Properties":
            props_el = child
        if localname(child) == "ChildObjects":
            child_objs_el = child

    obj_name = ""
    if props_el is not None:
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == "Name":
                obj_name = (child.text or "").strip()
                break
    info(f"Subsystem: {obj_name}")

    # --- Operations ---
    def do_add_content(items):
        nonlocal add_count
        content_el = None
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == "Content":
                content_el = child
                break
        if content_el is None:
            print("No <Content> element found", file=sys.stderr)
            sys.exit(1)

        existing = set()
        for child in content_el:
            if isinstance(child.tag, str) and localname(child) == "Item":
                existing.add((child.text or "").strip())

        props_indent = get_child_indent(props_el)
        if len(content_el) == 0 and not (content_el.text and content_el.text.strip()):
            expand_self_closing(content_el, props_indent)
        content_indent = get_child_indent(content_el)

        for raw_item in items:
            item = normalize_content_ref(raw_item)
            if item != raw_item:
                print(f'[NORM] Content: {raw_item} -> {item}')
            if item in existing:
                warn(f"Content already contains: {item}")
                continue
            frag_xml = f'<xr:Item xsi:type="xr:MDObjectRef">{item}</xr:Item>'
            nodes = import_fragment(frag_xml, xml_root)
            if nodes:
                insert_before_closing(content_el, nodes[0], content_indent)
                add_count += 1
                info(f"Added content: {item}")

    def do_remove_content(items):
        nonlocal remove_count
        content_el = None
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == "Content":
                content_el = child
                break
        if content_el is None:
            print("No <Content> element found", file=sys.stderr)
            sys.exit(1)

        for item in items:
            found = False
            for child in list(content_el):
                if isinstance(child.tag, str) and localname(child) == "Item" and (child.text or "").strip() == item:
                    remove_with_indent(child)
                    remove_count += 1
                    info(f"Removed content: {item}")
                    found = True
                    break
            if not found:
                warn(f"Content item not found: {item}")

    def do_add_child(child_name):
        nonlocal add_count
        if child_objs_el is None:
            print("No <ChildObjects> element found", file=sys.stderr)
            sys.exit(1)

        for child in child_objs_el:
            if isinstance(child.tag, str) and localname(child) == "Subsystem" and (child.text or "").strip() == child_name:
                warn(f"ChildObjects already contains: {child_name}")
                return

        sub_indent = get_child_indent(sub)
        if len(child_objs_el) == 0 and not (child_objs_el.text and child_objs_el.text.strip()):
            expand_self_closing(child_objs_el, sub_indent)
        ci = get_child_indent(child_objs_el)

        new_el = etree.SubElement(child_objs_el, f"{{{MD_NS}}}Subsystem")
        # Actually we need to use insert_before_closing pattern
        child_objs_el.remove(new_el)
        new_el = etree.Element(f"{{{MD_NS}}}Subsystem")
        new_el.text = child_name
        insert_before_closing(child_objs_el, new_el, ci)
        add_count += 1
        info(f"Added child subsystem: {child_name}")

        # Write stub XML for the new child if it doesn't exist yet
        parent_dir = os.path.dirname(resolved_path)
        parent_base_name = os.path.splitext(os.path.basename(resolved_path))[0]
        child_subs_dir = os.path.join(parent_dir, parent_base_name, 'Subsystems')
        if not os.path.exists(child_subs_dir):
            os.makedirs(child_subs_dir, exist_ok=True)
            info(f"Created directory: {child_subs_dir}")
        child_xml = os.path.join(child_subs_dir, f'{child_name}.xml')
        if not os.path.exists(child_xml):
            write_child_subsystem_stub(child_xml, child_name, format_version)
            info(f"Created stub: {child_xml}")

    def do_remove_child(child_name):
        nonlocal remove_count
        if child_objs_el is None:
            print("No <ChildObjects> element found", file=sys.stderr)
            sys.exit(1)

        found = False
        for child in list(child_objs_el):
            if isinstance(child.tag, str) and localname(child) == "Subsystem" and (child.text or "").strip() == child_name:
                remove_with_indent(child)
                remove_count += 1
                info(f"Removed child subsystem: {child_name}")
                found = True
                break
        if not found:
            warn(f"Child subsystem not found: {child_name}")

    def do_set_property(json_val):
        nonlocal modify_count
        prop_def = json.loads(json_val)
        prop_name = str(prop_def["name"])
        prop_value = str(prop_def.get("value", ""))

        prop_el = None
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == prop_name:
                prop_el = child
                break
        if prop_el is None:
            print(f"Property '{prop_name}' not found in Properties", file=sys.stderr)
            sys.exit(1)

        bool_props = ["IncludeInCommandInterface", "UseOneCommand", "IncludeHelpInContents"]
        if prop_name in bool_props:
            prop_el.text = prop_value.lower()
            # Clear children
            for ch in list(prop_el):
                prop_el.remove(ch)
            modify_count += 1
            info(f"Set {prop_name} = {prop_value}")
            return

        ml_props = ["Synonym", "Explanation"]
        if prop_name in ml_props:
            if not prop_value:
                # Clear - make self-closing
                for ch in list(prop_el):
                    prop_el.remove(ch)
                prop_el.text = None
                modify_count += 1
                info(f"Cleared {prop_name}")
            else:
                for ch in list(prop_el):
                    prop_el.remove(ch)
                indent = get_child_indent(props_el)

                item_el = etree.SubElement(prop_el, f"{{{V8_NS}}}item")
                lang_el = etree.SubElement(item_el, f"{{{V8_NS}}}lang")
                lang_el.text = "ru"
                content_el = etree.SubElement(item_el, f"{{{V8_NS}}}content")
                content_el.text = prop_value

                # Set whitespace
                prop_el.text = "\r\n" + indent + "\t"
                item_el.text = "\r\n" + indent + "\t\t"
                lang_el.tail = "\r\n" + indent + "\t\t"
                content_el.tail = "\r\n" + indent + "\t"
                item_el.tail = "\r\n" + indent

                modify_count += 1
                info(f'Set {prop_name} = "{prop_value}"')
            return

        if prop_name == "Comment":
            for ch in list(prop_el):
                prop_el.remove(ch)
            if not prop_value:
                prop_el.text = None
            else:
                prop_el.text = prop_value
            modify_count += 1
            info(f'Set Comment = "{prop_value}"')
            return

        if prop_name == "Picture":
            for ch in list(prop_el):
                prop_el.remove(ch)
            if not prop_value:
                prop_el.text = None
            else:
                indent = get_child_indent(props_el)
                ref_el = etree.SubElement(prop_el, f"{{{XR_NS}}}Ref")
                ref_el.text = prop_value
                load_el = etree.SubElement(prop_el, f"{{{XR_NS}}}LoadTransparent")
                load_el.text = "false"
                prop_el.text = "\r\n" + indent + "\t"
                ref_el.tail = "\r\n" + indent + "\t"
                load_el.tail = "\r\n" + indent
            modify_count += 1
            info(f'Set Picture = "{prop_value}"')
            return

        # Generic text property
        for ch in list(prop_el):
            prop_el.remove(ch)
        prop_el.text = prop_value
        modify_count += 1
        info(f'Set {prop_name} = "{prop_value}"')

    # --- Execute operations ---
    operations = []
    if args.DefinitionFile:
        def_file = args.DefinitionFile
        if not os.path.isabs(def_file):
            def_file = os.path.join(os.getcwd(), def_file)
        with open(def_file, "r", encoding="utf-8-sig") as fh:
            ops = json.loads(fh.read())
        if isinstance(ops, list):
            operations = ops
        else:
            operations = [ops]
    else:
        operations = [{"operation": args.Operation, "value": args.Value or ""}]

    for op in operations:
        op_name = op.get("operation", args.Operation or "")
        op_value = op.get("value", args.Value or "")

        if op_name == "add-content":
            do_add_content(parse_value_list(op_value))
        elif op_name == "remove-content":
            do_remove_content(parse_value_list(op_value))
        elif op_name == "add-child":
            do_add_child(op_value)
        elif op_name == "remove-child":
            do_remove_child(op_value)
        elif op_name == "set-property":
            do_set_property(op_value)
        else:
            print(f"Unknown operation: {op_name}", file=sys.stderr)
            sys.exit(1)

    # --- Save ---
    save_xml_bom(tree, resolved_path)
    info(f"Saved: {resolved_path}")

    # --- Auto-validate ---
    if not args.NoValidate:
        validate_script = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "subsystem-validate", "scripts", "subsystem-validate.py"))
        if os.path.isfile(validate_script):
            print()
            print("--- Running subsystem-validate ---")
            subprocess.run([sys.executable, validate_script, "-SubsystemPath", "-Path", resolved_path])

    # --- Summary ---
    print()
    print("=== subsystem-edit summary ===")
    print(f"  Subsystem: {obj_name}")
    print(f"  Added:     {add_count}")
    print(f"  Removed:   {remove_count}")
    print(f"  Modified:  {modify_count}")
    sys.exit(0)


if __name__ == "__main__":
    main()
