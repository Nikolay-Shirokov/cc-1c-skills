#!/usr/bin/env python3
# cfe-borrow v1.0 — Borrow objects from configuration into extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
import uuid
from lxml import etree

MD_NS = "http://v8.1c.ru/8.3/MDClasses"
XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
V8_NS = "http://v8.1c.ru/8.1/data/core"


def localname(el):
    return etree.QName(el.tag).localname


def info(msg):
    print(f"[INFO] {msg}")


def warn(msg):
    print(f"[WARN] {msg}")


# --- Type mappings ---
CHILD_TYPE_DIR_MAP = {
    "Catalog": "Catalogs", "Document": "Documents", "Enum": "Enums",
    "CommonModule": "CommonModules", "CommonPicture": "CommonPictures",
    "CommonCommand": "CommonCommands", "CommonTemplate": "CommonTemplates",
    "ExchangePlan": "ExchangePlans", "Report": "Reports", "DataProcessor": "DataProcessors",
    "InformationRegister": "InformationRegisters", "AccumulationRegister": "AccumulationRegisters",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfAccounts": "ChartsOfAccounts", "AccountingRegister": "AccountingRegisters",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes", "CalculationRegister": "CalculationRegisters",
    "BusinessProcess": "BusinessProcesses", "Task": "Tasks",
    "Subsystem": "Subsystems", "Role": "Roles", "Constant": "Constants",
    "FunctionalOption": "FunctionalOptions", "DefinedType": "DefinedTypes",
    "FunctionalOptionsParameter": "FunctionalOptionsParameters",
    "CommonForm": "CommonForms", "DocumentJournal": "DocumentJournals",
    "SessionParameter": "SessionParameters", "StyleItem": "StyleItems",
    "EventSubscription": "EventSubscriptions", "ScheduledJob": "ScheduledJobs",
    "SettingsStorage": "SettingsStorages", "FilterCriterion": "FilterCriteria",
    "CommandGroup": "CommandGroups", "DocumentNumerator": "DocumentNumerators",
    "Sequence": "Sequences", "IntegrationService": "IntegrationServices",
    "XDTOPackage": "XDTOPackages", "WebService": "WebServices",
    "HTTPService": "HTTPServices", "WSReference": "WSReferences",
    "CommonAttribute": "CommonAttributes", "Style": "Styles",
}

SYNONYM_MAP = {
    "\u0421\u043f\u0440\u0430\u0432\u043e\u0447\u043d\u0438\u043a": "Catalog",
    "\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442": "Document",
    "\u041f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u0438\u0435": "Enum",
    "\u041e\u0431\u0449\u0438\u0439\u041c\u043e\u0434\u0443\u043b\u044c": "CommonModule",
    "\u041e\u0431\u0449\u0430\u044f\u041a\u0430\u0440\u0442\u0438\u043d\u043a\u0430": "CommonPicture",
    "\u041e\u0431\u0449\u0430\u044f\u041a\u043e\u043c\u0430\u043d\u0434\u0430": "CommonCommand",
    "\u041e\u0431\u0449\u0438\u0439\u041c\u0430\u043a\u0435\u0442": "CommonTemplate",
    "\u041f\u043b\u0430\u043d\u041e\u0431\u043c\u0435\u043d\u0430": "ExchangePlan",
    "\u041e\u0442\u0447\u0435\u0442": "Report",
    "\u041e\u0442\u0447\u0451\u0442": "Report",
    "\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430": "DataProcessor",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0421\u0432\u0435\u0434\u0435\u043d\u0438\u0439": "InformationRegister",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u041d\u0430\u043a\u043e\u043f\u043b\u0435\u043d\u0438\u044f": "AccumulationRegister",
    "\u041f\u043b\u0430\u043d\u0412\u0438\u0434\u043e\u0432\u0425\u0430\u0440\u0430\u043a\u0442\u0435\u0440\u0438\u0441\u0442\u0438\u043a": "ChartOfCharacteristicTypes",
    "\u041f\u043b\u0430\u043d\u0421\u0447\u0435\u0442\u043e\u0432": "ChartOfAccounts",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0411\u0443\u0445\u0433\u0430\u043b\u0442\u0435\u0440\u0438\u0438": "AccountingRegister",
    "\u041f\u043b\u0430\u043d\u0412\u0438\u0434\u043e\u0432\u0420\u0430\u0441\u0447\u0435\u0442\u0430": "ChartOfCalculationTypes",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0420\u0430\u0441\u0447\u0435\u0442\u0430": "CalculationRegister",
    "\u0411\u0438\u0437\u043d\u0435\u0441\u041f\u0440\u043e\u0446\u0435\u0441\u0441": "BusinessProcess",
    "\u0417\u0430\u0434\u0430\u0447\u0430": "Task",
    "\u041f\u043e\u0434\u0441\u0438\u0441\u0442\u0435\u043c\u0430": "Subsystem",
    "\u0420\u043e\u043b\u044c": "Role",
    "\u041a\u043e\u043d\u0441\u0442\u0430\u043d\u0442\u0430": "Constant",
    "\u0424\u0443\u043d\u043a\u0446\u0438\u043e\u043d\u0430\u043b\u044c\u043d\u0430\u044f\u041e\u043f\u0446\u0438\u044f": "FunctionalOption",
    "\u041e\u043f\u0440\u0435\u0434\u0435\u043b\u044f\u0435\u043c\u044b\u0439\u0422\u0438\u043f": "DefinedType",
    "\u041e\u0431\u0449\u0430\u044f\u0424\u043e\u0440\u043c\u0430": "CommonForm",
    "\u0416\u0443\u0440\u043d\u0430\u043b\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u043e\u0432": "DocumentJournal",
    "\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u0421\u0435\u0430\u043d\u0441\u0430": "SessionParameter",
    "\u0413\u0440\u0443\u043f\u043f\u0430\u041a\u043e\u043c\u0430\u043d\u0434": "CommandGroup",
    "\u041f\u043e\u0434\u043f\u0438\u0441\u043a\u0430\u041d\u0430\u0421\u043e\u0431\u044b\u0442\u0438\u0435": "EventSubscription",
    "\u0420\u0435\u0433\u043b\u0430\u043c\u0435\u043d\u0442\u043d\u043e\u0435\u0417\u0430\u0434\u0430\u043d\u0438\u0435": "ScheduledJob",
    "\u041e\u0431\u0449\u0438\u0439\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442": "CommonAttribute",
    "\u041f\u0430\u043a\u0435\u0442XDTO": "XDTOPackage",
    "HTTP\u0421\u0435\u0440\u0432\u0438\u0441": "HTTPService",
    "\u0421\u0435\u0440\u0432\u0438\u0441\u0418\u043d\u0442\u0435\u0433\u0440\u0430\u0446\u0438\u0438": "IntegrationService",
}

TYPE_ORDER = [
    "Language", "Subsystem", "StyleItem", "Style",
    "CommonPicture", "SessionParameter", "Role", "CommonTemplate",
    "FilterCriterion", "CommonModule", "CommonAttribute", "ExchangePlan",
    "XDTOPackage", "WebService", "HTTPService", "WSReference",
    "EventSubscription", "ScheduledJob", "SettingsStorage", "FunctionalOption",
    "FunctionalOptionsParameter", "DefinedType", "CommonCommand", "CommandGroup",
    "Constant", "CommonForm", "Catalog", "Document",
    "DocumentNumerator", "Sequence", "DocumentJournal", "Enum",
    "Report", "DataProcessor", "InformationRegister", "AccumulationRegister",
    "ChartOfCharacteristicTypes", "ChartOfAccounts", "AccountingRegister",
    "ChartOfCalculationTypes", "CalculationRegister",
    "BusinessProcess", "Task", "IntegrationService",
]

GENERATED_TYPES = {
    "Catalog": [
        {"prefix": "CatalogObject", "category": "Object"},
        {"prefix": "CatalogRef", "category": "Ref"},
        {"prefix": "CatalogSelection", "category": "Selection"},
        {"prefix": "CatalogList", "category": "List"},
        {"prefix": "CatalogManager", "category": "Manager"},
    ],
    "Document": [
        {"prefix": "DocumentObject", "category": "Object"},
        {"prefix": "DocumentRef", "category": "Ref"},
        {"prefix": "DocumentSelection", "category": "Selection"},
        {"prefix": "DocumentList", "category": "List"},
        {"prefix": "DocumentManager", "category": "Manager"},
    ],
    "Enum": [
        {"prefix": "EnumRef", "category": "Ref"},
        {"prefix": "EnumManager", "category": "Manager"},
        {"prefix": "EnumList", "category": "List"},
    ],
    "Constant": [
        {"prefix": "ConstantManager", "category": "Manager"},
        {"prefix": "ConstantValueManager", "category": "ValueManager"},
        {"prefix": "ConstantValueKey", "category": "ValueKey"},
    ],
    "InformationRegister": [
        {"prefix": "InformationRegisterRecord", "category": "Record"},
        {"prefix": "InformationRegisterManager", "category": "Manager"},
        {"prefix": "InformationRegisterSelection", "category": "Selection"},
        {"prefix": "InformationRegisterList", "category": "List"},
        {"prefix": "InformationRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "InformationRegisterRecordKey", "category": "RecordKey"},
        {"prefix": "InformationRegisterRecordManager", "category": "RecordManager"},
    ],
    "AccumulationRegister": [
        {"prefix": "AccumulationRegisterRecord", "category": "Record"},
        {"prefix": "AccumulationRegisterManager", "category": "Manager"},
        {"prefix": "AccumulationRegisterSelection", "category": "Selection"},
        {"prefix": "AccumulationRegisterList", "category": "List"},
        {"prefix": "AccumulationRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "AccumulationRegisterRecordKey", "category": "RecordKey"},
    ],
    "AccountingRegister": [
        {"prefix": "AccountingRegisterRecord", "category": "Record"},
        {"prefix": "AccountingRegisterManager", "category": "Manager"},
        {"prefix": "AccountingRegisterSelection", "category": "Selection"},
        {"prefix": "AccountingRegisterList", "category": "List"},
        {"prefix": "AccountingRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "AccountingRegisterRecordKey", "category": "RecordKey"},
    ],
    "CalculationRegister": [
        {"prefix": "CalculationRegisterRecord", "category": "Record"},
        {"prefix": "CalculationRegisterManager", "category": "Manager"},
        {"prefix": "CalculationRegisterSelection", "category": "Selection"},
        {"prefix": "CalculationRegisterList", "category": "List"},
        {"prefix": "CalculationRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "CalculationRegisterRecordKey", "category": "RecordKey"},
    ],
    "ChartOfAccounts": [
        {"prefix": "ChartOfAccountsObject", "category": "Object"},
        {"prefix": "ChartOfAccountsRef", "category": "Ref"},
        {"prefix": "ChartOfAccountsSelection", "category": "Selection"},
        {"prefix": "ChartOfAccountsList", "category": "List"},
        {"prefix": "ChartOfAccountsManager", "category": "Manager"},
    ],
    "ChartOfCharacteristicTypes": [
        {"prefix": "ChartOfCharacteristicTypesObject", "category": "Object"},
        {"prefix": "ChartOfCharacteristicTypesRef", "category": "Ref"},
        {"prefix": "ChartOfCharacteristicTypesSelection", "category": "Selection"},
        {"prefix": "ChartOfCharacteristicTypesList", "category": "List"},
        {"prefix": "ChartOfCharacteristicTypesManager", "category": "Manager"},
    ],
    "ChartOfCalculationTypes": [
        {"prefix": "ChartOfCalculationTypesObject", "category": "Object"},
        {"prefix": "ChartOfCalculationTypesRef", "category": "Ref"},
        {"prefix": "ChartOfCalculationTypesSelection", "category": "Selection"},
        {"prefix": "ChartOfCalculationTypesList", "category": "List"},
        {"prefix": "ChartOfCalculationTypesManager", "category": "Manager"},
        {"prefix": "DisplacingCalculationTypes", "category": "DisplacingCalculationTypes"},
        {"prefix": "BaseCalculationTypes", "category": "BaseCalculationTypes"},
        {"prefix": "LeadingCalculationTypes", "category": "LeadingCalculationTypes"},
    ],
    "BusinessProcess": [
        {"prefix": "BusinessProcessObject", "category": "Object"},
        {"prefix": "BusinessProcessRef", "category": "Ref"},
        {"prefix": "BusinessProcessSelection", "category": "Selection"},
        {"prefix": "BusinessProcessList", "category": "List"},
        {"prefix": "BusinessProcessManager", "category": "Manager"},
    ],
    "Task": [
        {"prefix": "TaskObject", "category": "Object"},
        {"prefix": "TaskRef", "category": "Ref"},
        {"prefix": "TaskSelection", "category": "Selection"},
        {"prefix": "TaskList", "category": "List"},
        {"prefix": "TaskManager", "category": "Manager"},
    ],
    "ExchangePlan": [
        {"prefix": "ExchangePlanObject", "category": "Object"},
        {"prefix": "ExchangePlanRef", "category": "Ref"},
        {"prefix": "ExchangePlanSelection", "category": "Selection"},
        {"prefix": "ExchangePlanList", "category": "List"},
        {"prefix": "ExchangePlanManager", "category": "Manager"},
    ],
    "DocumentJournal": [
        {"prefix": "DocumentJournalSelection", "category": "Selection"},
        {"prefix": "DocumentJournalList", "category": "List"},
        {"prefix": "DocumentJournalManager", "category": "Manager"},
    ],
    "Report": [
        {"prefix": "ReportObject", "category": "Object"},
        {"prefix": "ReportManager", "category": "Manager"},
    ],
    "DataProcessor": [
        {"prefix": "DataProcessorObject", "category": "Object"},
        {"prefix": "DataProcessorManager", "category": "Manager"},
    ],
}

TYPES_WITH_CHILD_OBJECTS = [
    "Catalog", "Document", "ExchangePlan", "ChartOfAccounts",
    "ChartOfCharacteristicTypes", "ChartOfCalculationTypes",
    "BusinessProcess", "Task", "Enum",
    "InformationRegister", "AccumulationRegister", "AccountingRegister", "CalculationRegister",
]

COMMON_MODULE_PROPS = ["Global", "ClientManagedApplication", "Server", "ExternalConnection", "ClientOrdinaryApplication", "ServerCall"]

XMLNS_DECL = (
    'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
    'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" '
    'xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" '
    'xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" '
    'xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" '
    'xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" '
    'xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" '
    'xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
)


def get_child_indent(container):
    if container.text and "\n" in container.text:
        after_nl = container.text.rsplit("\n", 1)[-1]
        if after_nl and not after_nl.strip():
            return after_nl
    for child in container:
        if child.tail and "\n" in child.tail:
            after_nl = child.tail.rsplit("\n", 1)[-1]
            if after_nl and not after_nl.strip():
                return after_nl
    depth = 0
    current = container
    while current is not None:
        depth += 1
        current = current.getparent()
    return "\t" * depth


def insert_before_closing(container, new_el, child_indent):
    children = list(container)
    if len(children) == 0:
        parent_indent = child_indent[:-1] if len(child_indent) > 0 else ""
        container.text = "\r\n" + child_indent
        new_el.tail = "\r\n" + parent_indent
        container.append(new_el)
    else:
        last = children[-1]
        new_el.tail = last.tail
        last.tail = "\r\n" + child_indent
        container.append(new_el)


def insert_before_ref(container, new_el, ref_el, child_indent):
    idx = list(container).index(ref_el)
    prev = ref_el.getprevious()
    if prev is not None:
        new_el.tail = prev.tail
        prev.tail = "\r\n" + child_indent
    else:
        new_el.tail = container.text
        container.text = "\r\n" + child_indent
    container.insert(idx, new_el)


def expand_self_closing(container, parent_indent):
    if len(container) == 0 and not (container.text and container.text.strip()):
        container.text = "\r\n" + parent_indent


def save_xml_bom(tree, path):
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    xml_bytes = xml_bytes.replace(b"encoding='UTF-8'", b'encoding="UTF-8"')
    with open(path, "wb") as f:
        f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


def save_text_bom(path, text):
    with open(path, "w", encoding="utf-8-sig") as fh:
        fh.write(text)


def new_guid():
    return str(uuid.uuid4())


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Borrow objects from configuration into extension", allow_abbrev=False)
    parser.add_argument("-ExtensionPath", required=True)
    parser.add_argument("-ConfigPath", required=True)
    parser.add_argument("-Object", required=True)
    args = parser.parse_args()

    # --- 1. Resolve paths ---
    ext_path = args.ExtensionPath
    if not os.path.isabs(ext_path):
        ext_path = os.path.join(os.getcwd(), ext_path)
    if os.path.isdir(ext_path):
        candidate = os.path.join(ext_path, "Configuration.xml")
        if os.path.isfile(candidate):
            ext_path = candidate
        else:
            print(f"No Configuration.xml in extension directory: {ext_path}", file=sys.stderr)
            sys.exit(1)
    if not os.path.isfile(ext_path):
        print(f"Extension file not found: {ext_path}", file=sys.stderr)
        sys.exit(1)
    ext_resolved = os.path.abspath(ext_path)
    ext_dir = os.path.dirname(ext_resolved)

    cfg_path = args.ConfigPath
    if not os.path.isabs(cfg_path):
        cfg_path = os.path.join(os.getcwd(), cfg_path)
    if os.path.isdir(cfg_path):
        candidate = os.path.join(cfg_path, "Configuration.xml")
        if os.path.isfile(candidate):
            cfg_path = candidate
        else:
            print(f"No Configuration.xml in config directory: {cfg_path}", file=sys.stderr)
            sys.exit(1)
    if not os.path.isfile(cfg_path):
        print(f"Config file not found: {cfg_path}", file=sys.stderr)
        sys.exit(1)
    cfg_resolved = os.path.abspath(cfg_path)
    cfg_dir = os.path.dirname(cfg_resolved)

    # --- 2. Load extension Configuration.xml ---
    xml_parser = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(ext_resolved, xml_parser)
    xml_root = tree.getroot()

    cfg_el = None
    for child in xml_root:
        if isinstance(child.tag, str) and localname(child) == "Configuration":
            cfg_el = child
            break
    if cfg_el is None:
        print("No <Configuration> element found in extension", file=sys.stderr)
        sys.exit(1)

    props_el = None
    child_objs_el = None
    for child in cfg_el:
        if not isinstance(child.tag, str):
            continue
        if localname(child) == "Properties":
            props_el = child
        if localname(child) == "ChildObjects":
            child_objs_el = child

    if props_el is None:
        print("No <Properties> element found in extension", file=sys.stderr)
        sys.exit(1)
    if child_objs_el is None:
        print("No <ChildObjects> element found in extension", file=sys.stderr)
        sys.exit(1)

    # --- 3. Extract NamePrefix ---
    name_prefix = ""
    for child in props_el:
        if isinstance(child.tag, str) and localname(child) == "NamePrefix":
            name_prefix = (child.text or "").strip()
            break
    info(f"Extension NamePrefix: {name_prefix}")

    # --- Helper functions ---
    def read_source_object(type_name, obj_name):
        dir_name = CHILD_TYPE_DIR_MAP.get(type_name)
        if not dir_name:
            print(f"Unknown type '{type_name}'", file=sys.stderr)
            sys.exit(1)

        src_file = os.path.join(cfg_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(src_file):
            print(f"Source object not found: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_parser = etree.XMLParser(remove_blank_text=True)
        src_tree = etree.parse(src_file, src_parser)
        src_root = src_tree.getroot()

        src_el = None
        for c in src_root:
            if isinstance(c.tag, str):
                src_el = c
                break
        if src_el is None:
            print(f"No metadata element found in {dir_name}/{obj_name}.xml", file=sys.stderr)
            sys.exit(1)

        src_uuid = src_el.get("uuid", "")
        if not src_uuid:
            print(f"No uuid attribute on source element in {dir_name}/{obj_name}.xml", file=sys.stderr)
            sys.exit(1)

        src_props = {}
        props_node = src_el.find(f"{{{MD_NS}}}Properties")
        if props_node is not None:
            for prop_name in COMMON_MODULE_PROPS:
                prop_node = props_node.find(f"{{{MD_NS}}}{prop_name}")
                if prop_node is not None:
                    src_props[prop_name] = (prop_node.text or "").strip()

        return {"Uuid": src_uuid, "Properties": src_props, "Element": src_el}

    def read_source_form_uuid(type_name, obj_name, form_name):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        src_file = os.path.join(cfg_dir, dir_name, obj_name, "Forms", f"{form_name}.xml")
        if not os.path.isfile(src_file):
            print(f"Source form not found: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_parser = etree.XMLParser(remove_blank_text=True)
        src_tree = etree.parse(src_file, src_parser)

        src_el = None
        for c in src_tree.getroot():
            if isinstance(c.tag, str):
                src_el = c
                break
        if src_el is None:
            print(f"No metadata element found in source form: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_uuid = src_el.get("uuid", "")
        if not src_uuid:
            print(f"No uuid attribute on source form element: {src_file}", file=sys.stderr)
            sys.exit(1)
        return src_uuid

    def build_internal_info_xml(type_name, obj_name, indent):
        types = GENERATED_TYPES.get(type_name)
        if not types:
            return f"{indent}<InternalInfo/>"

        lines = [f"{indent}<InternalInfo>"]

        if type_name == "ExchangePlan":
            this_node_uuid = new_guid()
            lines.append(f"{indent}\t<xr:ThisNode>{this_node_uuid}</xr:ThisNode>")

        for gt in types:
            full_name = f"{gt['prefix']}.{obj_name}"
            type_id = new_guid()
            value_id = new_guid()
            lines.append(f'{indent}\t<xr:GeneratedType name="{full_name}" category="{gt["category"]}">')
            lines.append(f"{indent}\t\t<xr:TypeId>{type_id}</xr:TypeId>")
            lines.append(f"{indent}\t\t<xr:ValueId>{value_id}</xr:ValueId>")
            lines.append(f"{indent}\t</xr:GeneratedType>")

        lines.append(f"{indent}</InternalInfo>")
        return "\n".join(lines)

    def build_borrowed_object_xml(type_name, obj_name, source_uuid, source_props):
        new_uuid_val = new_guid()
        internal_info_xml = build_internal_info_xml(type_name, obj_name, "\t\t")

        lines = []
        lines.append('<?xml version="1.0" encoding="UTF-8"?>')
        lines.append(f'<MetaDataObject {XMLNS_DECL} version="2.17">')
        lines.append(f'\t<{type_name} uuid="{new_uuid_val}">')
        lines.append(internal_info_xml)
        lines.append("\t\t<Properties>")
        lines.append("\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>")
        lines.append(f"\t\t\t<Name>{obj_name}</Name>")
        lines.append("\t\t\t<Comment/>")
        lines.append(f"\t\t\t<ExtendedConfigurationObject>{source_uuid}</ExtendedConfigurationObject>")

        if type_name == "CommonModule":
            for prop_name in COMMON_MODULE_PROPS:
                prop_val = source_props.get(prop_name, "false")
                lines.append(f"\t\t\t<{prop_name}>{prop_val}</{prop_name}>")

        lines.append("\t\t</Properties>")

        if type_name in TYPES_WITH_CHILD_OBJECTS:
            lines.append("\t\t<ChildObjects/>")

        lines.append(f"\t</{type_name}>")
        lines.append("</MetaDataObject>")
        return "\n".join(lines)

    def add_to_child_objects(type_name, obj_name):
        cfg_indent = get_child_indent(cfg_el)
        if len(child_objs_el) == 0 and not (child_objs_el.text and child_objs_el.text.strip()):
            expand_self_closing(child_objs_el, cfg_indent)
        ci = get_child_indent(child_objs_el)

        if type_name not in TYPE_ORDER:
            print(f"Unknown type '{type_name}' for ChildObjects ordering", file=sys.stderr)
            sys.exit(1)
        type_idx = TYPE_ORDER.index(type_name)

        # Dedup
        for child in child_objs_el:
            if isinstance(child.tag, str) and localname(child) == type_name and (child.text or "") == obj_name:
                warn(f"Already in ChildObjects: {type_name}.{obj_name}")
                return

        insert_before = None
        for child in child_objs_el:
            if not isinstance(child.tag, str):
                continue
            child_type_name = localname(child)
            if child_type_name not in TYPE_ORDER:
                continue
            child_type_idx = TYPE_ORDER.index(child_type_name)

            if child_type_name == type_name:
                if (child.text or "") > obj_name and insert_before is None:
                    insert_before = child
            elif child_type_idx > type_idx and insert_before is None:
                insert_before = child

        new_el = etree.Element(f"{{{MD_NS}}}{type_name}")
        new_el.text = obj_name

        if insert_before is not None:
            insert_before_ref(child_objs_el, new_el, insert_before, ci)
        else:
            insert_before_closing(child_objs_el, new_el, ci)

        info(f"Added to ChildObjects: {type_name}.{obj_name}")

    def test_object_borrowed(type_name, obj_name):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")
        return os.path.isfile(obj_file)

    def register_form_in_object(type_name, obj_name, form_name):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(obj_file):
            warn(f"Parent object file not found: {obj_file} \u2014 form not registered in ChildObjects")
            return

        obj_parser = etree.XMLParser(remove_blank_text=False)
        obj_tree = etree.parse(obj_file, obj_parser)
        obj_root = obj_tree.getroot()

        obj_el = None
        for c in obj_root:
            if isinstance(c.tag, str):
                obj_el = c
                break
        if obj_el is None:
            warn(f"No type element in {obj_file} \u2014 form not registered")
            return

        child_objs = obj_el.find(f"{{{MD_NS}}}ChildObjects")
        if child_objs is None:
            child_objs = etree.SubElement(obj_el, f"{{{MD_NS}}}ChildObjects")
            # Set proper whitespace
            prev = child_objs.getprevious()
            if prev is not None:
                child_objs.tail = "\r\n\t"
                prev_tail = prev.tail or ""
                if not prev_tail.endswith("\t\t"):
                    prev.tail = "\r\n\t\t"

        # Dedup
        for c in child_objs:
            if isinstance(c.tag, str) and localname(c) == "Form" and (c.text or "") == form_name:
                warn(f"Form '{form_name}' already in ChildObjects of {type_name}.{obj_name}")
                return

        if len(child_objs) == 0 and not (child_objs.text and child_objs.text.strip()):
            child_objs.text = "\r\n\t\t"

        form_el = etree.Element(f"{{{MD_NS}}}Form")
        form_el.text = form_name
        insert_before_closing(child_objs, form_el, "\t\t\t")

        save_xml_bom(obj_tree, obj_file)
        info(f"  Registered form in: {obj_file}")

    def borrow_form(type_name, obj_name, form_name):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]

        # 1. Read source form UUID
        form_uuid = read_source_form_uuid(type_name, obj_name, form_name)
        info(f"  Source form UUID: {form_uuid}")

        # 2. Read source Form.xml
        src_form_xml_path = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml")
        if not os.path.isfile(src_form_xml_path):
            print(f"Source Form.xml not found: {src_form_xml_path}", file=sys.stderr)
            sys.exit(1)
        with open(src_form_xml_path, "r", encoding="utf-8-sig") as fh:
            src_form_content = fh.read()

        # 3. Generate form metadata XML
        new_form_uuid = new_guid()
        form_meta_lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<MetaDataObject {XMLNS_DECL} version="2.17">',
            f'\t<Form uuid="{new_form_uuid}">',
            '\t\t<InternalInfo/>',
            '\t\t<Properties>',
            '\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>',
            f'\t\t\t<Name>{form_name}</Name>',
            '\t\t\t<Comment/>',
            f'\t\t\t<ExtendedConfigurationObject>{form_uuid}</ExtendedConfigurationObject>',
            '\t\t\t<FormType>Managed</FormType>',
            '\t\t</Properties>',
            '\t</Form>',
            '</MetaDataObject>',
        ]

        # 4. Create directories
        form_meta_dir = os.path.join(ext_dir, dir_name, obj_name, "Forms")
        os.makedirs(form_meta_dir, exist_ok=True)

        form_meta_file = os.path.join(form_meta_dir, f"{form_name}.xml")
        save_text_bom(form_meta_file, "\n".join(form_meta_lines))
        info(f"  Created: {form_meta_file}")

        # 5. Generate Form.xml with BaseForm
        src_form_parser = etree.XMLParser(remove_blank_text=False)
        src_form_tree = etree.parse(src_form_xml_path, src_form_parser)
        src_form_el = src_form_tree.getroot()

        form_version = src_form_el.get("version", "2.17")

        src_auto_cmd = None
        form_props = []
        reached_visual = False
        for fc in src_form_el:
            if not isinstance(fc.tag, str):
                continue
            ln = localname(fc)
            if ln == "AutoCommandBar" and src_auto_cmd is None:
                reached_visual = True
                src_auto_cmd = fc
                continue
            if ln in ("ChildItems", "Events", "Attributes", "Commands", "Parameters"):
                reached_visual = True
                continue
            if not reached_visual:
                # Form-level properties before AutoCommandBar (WindowOpeningMode, AutoFillCheck, etc.)
                form_props.append(etree.tostring(fc, encoding="unicode"))

        ns_strip_pattern = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')

        # AutoCommandBar: copy only properties (Autofill etc.), strip ChildItems
        auto_cmd_xml = ""
        if src_auto_cmd is not None:
            auto_cmd_xml = etree.tostring(src_auto_cmd, encoding="unicode")
            auto_cmd_xml = ns_strip_pattern.sub("", auto_cmd_xml)
            # Strip ChildItems from AutoCommandBar (buttons will appear from base form at runtime)
            auto_cmd_xml = re.sub(r'\s*<ChildItems>.*?</ChildItems>', '', auto_cmd_xml, flags=re.DOTALL)
            # Replace Autofill true -> false
            auto_cmd_xml = auto_cmd_xml.replace('<Autofill>true</Autofill>', '<Autofill>false</Autofill>')

        # Extract source form opening tag
        xml_decl = '<?xml version="1.0" encoding="UTF-8"?>'
        form_tag = f'<Form version="{form_version}">'
        m_decl = re.search(r'^(<\?xml[^?]*\?>)', src_form_content)
        if m_decl:
            xml_decl = m_decl.group(1)
        m_tag = re.search(r'(<Form[^>]*>)', src_form_content)
        if m_tag:
            form_tag = m_tag.group(1)

        # Build output
        parts = []
        parts.append(xml_decl)
        parts.append("\r\n")
        parts.append(form_tag)
        parts.append("\r\n")

        # Part 1: form properties + AutoCommandBar (no ChildItems — they come from base form at runtime)
        for prop_xml in form_props:
            prop_xml_clean = ns_strip_pattern.sub("", prop_xml)
            parts.append(f"\t{prop_xml_clean}\r\n")
        if auto_cmd_xml:
            parts.append(f"\t{auto_cmd_xml}\r\n")
        parts.append("\t<Attributes/>\r\n")

        # BaseForm: same properties + AutoCommandBar (no ChildItems)
        parts.append(f'\t<BaseForm version="{form_version}">\r\n')

        for prop_xml in form_props:
            prop_xml_clean = ns_strip_pattern.sub("", prop_xml)
            parts.append(f"\t\t{prop_xml_clean}\r\n")
        if auto_cmd_xml:
            ac_lines = auto_cmd_xml.split("\n")
            for li, line in enumerate(ac_lines):
                if li == 0:
                    parts.append(f"\t\t{line}")
                else:
                    parts.append(f"\t{line}")
                parts.append("\r\n")

        parts.append("\t\t<Attributes/>\r\n")
        parts.append("\t</BaseForm>\r\n")
        parts.append("</Form>")

        form_xml_dir = os.path.join(form_meta_dir, form_name, "Ext")
        os.makedirs(form_xml_dir, exist_ok=True)
        form_xml_file = os.path.join(form_xml_dir, "Form.xml")
        save_text_bom(form_xml_file, "".join(parts))
        info(f"  Created: {form_xml_file}")

        # 6. Create empty Module.bsl
        module_dir = os.path.join(form_xml_dir, "Form")
        os.makedirs(module_dir, exist_ok=True)
        module_bsl_file = os.path.join(module_dir, "Module.bsl")
        save_text_bom(module_bsl_file, "")
        info(f"  Created: {module_bsl_file}")

        # 7. Register form in parent object ChildObjects
        register_form_in_object(type_name, obj_name, form_name)

        return [form_meta_file, form_xml_file, module_bsl_file]

    # --- 9. Parse -Object into items ---
    items = []
    for part in args.Object.split(";;"):
        trimmed = part.strip()
        if trimmed:
            items.append(trimmed)

    if not items:
        print("No objects specified in -Object", file=sys.stderr)
        sys.exit(1)

    # --- 10. Process each item ---
    borrowed_files = []
    borrowed_count = 0

    for item in items:
        dot_idx = item.find(".")
        if dot_idx < 1:
            print(f"Invalid format '{item}', expected 'Type.Name' or 'Type.Name.Form.FormName'", file=sys.stderr)
            sys.exit(1)
        type_name = item[:dot_idx]
        remainder = item[dot_idx + 1:]

        if type_name in SYNONYM_MAP:
            type_name = SYNONYM_MAP[type_name]

        if type_name not in CHILD_TYPE_DIR_MAP:
            print(f"Unknown type '{type_name}'", file=sys.stderr)
            sys.exit(1)

        form_name = None
        form_idx = remainder.find(".Form.")
        if form_idx > 0:
            obj_name = remainder[:form_idx]
            form_name = remainder[form_idx + 6:]
        else:
            obj_name = remainder

        dir_name = CHILD_TYPE_DIR_MAP[type_name]

        if form_name:
            # --- Form borrowing ---
            info(f"Borrowing form {type_name}.{obj_name}.Form.{form_name}...")

            if not test_object_borrowed(type_name, obj_name):
                info(f"  Parent object {type_name}.{obj_name} not yet borrowed \u2014 borrowing first...")

                src = read_source_object(type_name, obj_name)
                info(f"  Source UUID: {src['Uuid']}")
                borrowed_xml = build_borrowed_object_xml(type_name, obj_name, src["Uuid"], src["Properties"])

                target_dir = os.path.join(ext_dir, dir_name)
                os.makedirs(target_dir, exist_ok=True)
                target_file = os.path.join(target_dir, f"{obj_name}.xml")
                save_text_bom(target_file, borrowed_xml)
                info(f"  Created: {target_file}")

                add_to_child_objects(type_name, obj_name)
                borrowed_files.append(target_file)

            form_files = borrow_form(type_name, obj_name, form_name)
            borrowed_files.extend(form_files)
            borrowed_count += 1
        else:
            # --- Object borrowing ---
            info(f"Borrowing {type_name}.{obj_name}...")

            src = read_source_object(type_name, obj_name)
            info(f"  Source UUID: {src['Uuid']}")

            borrowed_xml = build_borrowed_object_xml(type_name, obj_name, src["Uuid"], src["Properties"])

            target_dir = os.path.join(ext_dir, dir_name)
            os.makedirs(target_dir, exist_ok=True)

            target_file = os.path.join(target_dir, f"{obj_name}.xml")
            save_text_bom(target_file, borrowed_xml)
            info(f"  Created: {target_file}")

            add_to_child_objects(type_name, obj_name)

            borrowed_files.append(target_file)
            borrowed_count += 1

    # --- Save modified Configuration.xml ---
    save_xml_bom(tree, ext_resolved)
    info(f"Saved: {ext_resolved}")

    # --- Summary ---
    print()
    print("=== cfe-borrow summary ===")
    print(f"  Extension:  {ext_dir}")
    print(f"  Config:     {cfg_dir}")
    print(f"  Borrowed:   {borrowed_count} object(s)")
    for f in borrowed_files:
        print(f"    - {f}")
    sys.exit(0)


if __name__ == "__main__":
    main()
