#!/usr/bin/env python3
# cfe-borrow v1.3 — Borrow objects from configuration into extension (CFE)
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
    "DefinedType": [
        {"prefix": "DefinedType", "category": "DefinedType"},
    ],
}

TYPES_WITH_CHILD_OBJECTS = [
    "Catalog", "Document", "ExchangePlan", "ChartOfAccounts",
    "ChartOfCharacteristicTypes", "ChartOfCalculationTypes",
    "BusinessProcess", "Task", "Enum",
    "InformationRegister", "AccumulationRegister", "AccountingRegister", "CalculationRegister",
]

COMMON_MODULE_PROPS = ["Global", "ClientManagedApplication", "Server", "ExternalConnection", "ClientOrdinaryApplication", "ServerCall"]

# Standard system fields to skip when collecting DataPath references
STANDARD_FIELDS = [
    "Code", "Description", "Ref", "Parent", "DeletionMark",
    "Predefined", "IsFolder", "LineNumber", "RowsCount", "PredefinedDataName",
]

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
    xml_bytes = xml_bytes.replace(b"<?xml version='1.0' encoding='UTF-8'?>", b'<?xml version="1.0" encoding="utf-8"?>')
    if not xml_bytes.endswith(b"\n"):
        xml_bytes += b"\n"
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
    parser.add_argument("-BorrowMainAttribute", nargs="?", const="Form", default=None)
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

    format_version = detect_format_version(ext_dir)

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

    # Module-level list for borrowed files (used by both main loop and borrow_main_attribute)
    borrowed_files = []

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
        lines.append(f'<MetaDataObject {XMLNS_DECL} version="{format_version}">')
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

    # --- 11b. Collect DataPath references from source Form.xml ---
    def collect_form_data_paths(form_xml_path):
        with open(form_xml_path, "r", encoding="utf-8-sig") as fh:
            content = fh.read()

        first_level = {}
        deep_paths = []

        for m in re.finditer(r'<DataPath>[^<]*\b\u041e\u0431\u044a\u0435\u043a\u0442\.(\w+(?:\.\w+)*)</DataPath>', content):
            path = m.group(1)
            segments = path.split(".")
            seg0 = segments[0]
            if seg0 in STANDARD_FIELDS:
                continue
            first_level[seg0] = True
            if len(segments) >= 2:
                seg1 = segments[1]
                if seg1 in STANDARD_FIELDS:
                    continue
                deep_paths.append({"ObjectAttr": seg0, "SubAttr": seg1})

        # Also collect from TitleDataPath
        for m in re.finditer(r'<TitleDataPath>[^<]*\b\u041e\u0431\u044a\u0435\u043a\u0442\.(\w+(?:\.\w+)*)</TitleDataPath>', content):
            path = m.group(1)
            segments = path.split(".")
            seg0 = segments[0]
            if seg0 in STANDARD_FIELDS:
                continue
            first_level[seg0] = True

        # Deduplicate deep paths
        seen = set()
        unique_deep = []
        for dp in deep_paths:
            key = f"{dp['ObjectAttr']}.{dp['SubAttr']}"
            if key not in seen:
                seen.add(key)
                unique_deep.append(dp)

        return {"FirstLevel": first_level, "DeepPaths": unique_deep}

    # --- 11c. Resolve source attributes and tabular sections ---
    def resolve_source_attributes(type_name, obj_name, first_level_names):
        # first_level_names: dict of names, or None for "all"
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        src_file = os.path.join(cfg_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(src_file):
            print(f"Source object not found: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_parser = etree.XMLParser(remove_blank_text=True)
        src_tree = etree.parse(src_file, src_parser)
        src_root = src_tree.getroot()

        ns_strip = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')

        src_el = None
        for c in src_root:
            if isinstance(c.tag, str):
                src_el = c
                break
        if src_el is None:
            print(f"No metadata element in source: {src_file}", file=sys.stderr)
            sys.exit(1)

        child_objs = src_el.find(f"{{{MD_NS}}}ChildObjects")
        if child_objs is None:
            return {"Attributes": [], "TabularSections": [], "ExtraProps": {}}

        attrs = []
        tab_sections = []

        for child in child_objs:
            if not isinstance(child.tag, str):
                continue
            ln = localname(child)

            if ln == "Attribute":
                name_node = child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
                if name_node is None:
                    continue
                attr_name = (name_node.text or "").strip()
                if first_level_names is not None and attr_name not in first_level_names:
                    continue

                attr_uuid = child.get("uuid", "")
                type_node = child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Type")
                type_xml = ""
                if type_node is not None:
                    type_xml = etree.tostring(type_node, encoding="unicode")
                    type_xml = ns_strip.sub("", type_xml)

                attrs.append({"Name": attr_name, "Uuid": attr_uuid, "TypeXml": type_xml})

            elif ln == "TabularSection":
                name_node = child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
                if name_node is None:
                    continue
                ts_name = (name_node.text or "").strip()
                if first_level_names is not None and ts_name not in first_level_names:
                    continue

                ts_uuid = child.get("uuid", "")

                # Extract GeneratedTypes from InternalInfo
                ts_gen_types = []
                ii_node = child.find(f"{{{MD_NS}}}InternalInfo")
                if ii_node is not None:
                    for gt in ii_node:
                        if isinstance(gt.tag, str) and localname(gt) == "GeneratedType":
                            gt_name = gt.get("name", "")
                            gt_category = gt.get("category", "")
                            tid_el = gt.find(f"{{{XR_NS}}}TypeId")
                            vid_el = gt.find(f"{{{XR_NS}}}ValueId")
                            ts_gen_types.append({
                                "Name": gt_name,
                                "Category": gt_category,
                                "TypeId": (tid_el.text or "") if tid_el is not None else "",
                                "ValueId": (vid_el.text or "") if vid_el is not None else "",
                            })

                # Extract ALL child attributes of TabularSection
                ts_attrs = []
                ts_child_objs = child.find(f"{{{MD_NS}}}ChildObjects")
                if ts_child_objs is not None:
                    for ts_child in ts_child_objs:
                        if not isinstance(ts_child.tag, str) or localname(ts_child) != "Attribute":
                            continue
                        ts_attr_name_el = ts_child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
                        if ts_attr_name_el is None:
                            continue
                        ts_attr_uuid = ts_child.get("uuid", "")
                        ts_type_node = ts_child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Type")
                        ts_type_xml = ""
                        if ts_type_node is not None:
                            ts_type_xml = etree.tostring(ts_type_node, encoding="unicode")
                            ts_type_xml = ns_strip.sub("", ts_type_xml)
                        ts_attrs.append({
                            "Name": (ts_attr_name_el.text or "").strip(),
                            "Uuid": ts_attr_uuid,
                            "TypeXml": ts_type_xml,
                        })

                tab_sections.append({
                    "Name": ts_name, "Uuid": ts_uuid,
                    "GeneratedTypes": ts_gen_types, "Attributes": ts_attrs,
                })

        # Extract extra Properties for main object enrichment
        extra_props = {}
        props_node = src_el.find(f"{{{MD_NS}}}Properties")
        if props_node is not None:
            props_to_extract = [
                "Hierarchical", "FoldersOnTop", "CodeLength", "DescriptionLength",
                "CodeType", "CodeAllowedLength", "NumberType", "NumberLength",
                "NumberAllowedLength", "NumberPeriodicity",
            ]
            for p_name in props_to_extract:
                p_node = props_node.find(f"{{{MD_NS}}}{p_name}")
                if p_node is not None:
                    extra_props[p_name] = (p_node.text or "").strip()

        return {"Attributes": attrs, "TabularSections": tab_sections, "ExtraProps": extra_props}

    # --- 11d. Build adopted attribute XML ---
    def build_adopted_attribute_xml(name, source_uuid, type_xml, indent):
        new_uuid_val = new_guid()
        lines = [
            f'{indent}<Attribute uuid="{new_uuid_val}">',
            f'{indent}\t<InternalInfo/>',
            f'{indent}\t<Properties>',
            f'{indent}\t\t<ObjectBelonging>Adopted</ObjectBelonging>',
            f'{indent}\t\t<Name>{name}</Name>',
            f'{indent}\t\t<Comment/>',
            f'{indent}\t\t<ExtendedConfigurationObject>{source_uuid}</ExtendedConfigurationObject>',
            f'{indent}\t\t{type_xml}',
            f'{indent}\t</Properties>',
            f'{indent}</Attribute>',
        ]
        return "\n".join(lines)

    # --- 11e. Build adopted tabular section XML ---
    def build_adopted_tabular_section_xml(ts_name, source_uuid, generated_types, child_attrs, indent):
        new_uuid_val = new_guid()
        lines = [f'{indent}<TabularSection uuid="{new_uuid_val}">']

        # InternalInfo with GeneratedTypes (new UUIDs, referencing source names)
        if generated_types:
            lines.append(f'{indent}\t<InternalInfo>')
            for gt in generated_types:
                new_tid = new_guid()
                new_vid = new_guid()
                lines.append(f'{indent}\t\t<xr:GeneratedType name="{gt["Name"]}" category="{gt["Category"]}">')
                lines.append(f'{indent}\t\t\t<xr:TypeId>{new_tid}</xr:TypeId>')
                lines.append(f'{indent}\t\t\t<xr:ValueId>{new_vid}</xr:ValueId>')
                lines.append(f'{indent}\t\t</xr:GeneratedType>')
            lines.append(f'{indent}\t</InternalInfo>')
        else:
            lines.append(f'{indent}\t<InternalInfo/>')

        lines.append(f'{indent}\t<Properties>')
        lines.append(f'{indent}\t\t<ObjectBelonging>Adopted</ObjectBelonging>')
        lines.append(f'{indent}\t\t<Name>{ts_name}</Name>')
        lines.append(f'{indent}\t\t<Comment/>')
        lines.append(f'{indent}\t\t<ExtendedConfigurationObject>{source_uuid}</ExtendedConfigurationObject>')
        lines.append(f'{indent}\t</Properties>')

        # ChildObjects with all attributes
        if child_attrs:
            lines.append(f'{indent}\t<ChildObjects>')
            for ca in child_attrs:
                ca_xml = build_adopted_attribute_xml(ca["Name"], ca["Uuid"], ca["TypeXml"], f"{indent}\t\t")
                lines.append(ca_xml)
            lines.append(f'{indent}\t</ChildObjects>')
        else:
            lines.append(f'{indent}\t<ChildObjects/>')

        lines.append(f'{indent}</TabularSection>')
        return "\n".join(lines)

    # --- 11f. Collect reference types from attribute Type XML strings ---
    def collect_reference_types(type_xmls):
        result = {}
        for type_xml in type_xmls:
            # cfg:CatalogRef.XXX, cfg:EnumRef.XXX, cfg:DocumentRef.XXX, etc.
            for m in re.finditer(r'cfg:(\w+)Ref\.(\w+)', type_xml):
                ref_prefix = m.group(1)
                obj_n = m.group(2)
                key = f"{ref_prefix}.{obj_n}"
                if key not in result:
                    result[key] = {"TypeName": ref_prefix, "ObjName": obj_n}
            # cfg:DefinedType.XXX
            for m in re.finditer(r'cfg:DefinedType\.(\w+)', type_xml):
                dt_name = m.group(1)
                key = f"DefinedType.{dt_name}"
                if key not in result:
                    result[key] = {"TypeName": "DefinedType", "ObjName": dt_name}
        return list(result.values())

    # --- 11g. Merge adopted attributes into existing extension object XML ---
    def merge_attributes_into_object(type_name, obj_name, attrs_to_add):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(obj_file):
            warn(f"Cannot merge attributes: {obj_file} not found")
            return

        with open(obj_file, "r", encoding="utf-8-sig") as fh:
            obj_content = fh.read()

        # Collect existing attribute names for dedup (text-based)
        existing_names = set()
        for m in re.finditer(r'<Name>(\w+)</Name>', obj_content):
            existing_names.add(m.group(1))

        all_attr_xml = ""
        added = 0
        for attr in attrs_to_add:
            if attr["Name"] in existing_names:
                continue
            all_attr_xml += "\r\n" + build_adopted_attribute_xml(attr["Name"], attr["Uuid"], attr["TypeXml"], "\t\t\t")
            added += 1

        if added > 0:
            # Insert attributes — handle both <ChildObjects/> and <ChildObjects>...</ChildObjects>
            if re.search(r'<ChildObjects\s*/>', obj_content):
                obj_content = re.sub(r'<ChildObjects\s*/>', f"<ChildObjects>{all_attr_xml}\r\n\t\t</ChildObjects>", obj_content)
            else:
                obj_content = obj_content.replace("</ChildObjects>", f"{all_attr_xml}\r\n\t\t</ChildObjects>")
            save_text_bom(obj_file, obj_content)
            info(f"  Merged {added} attribute(s) into: {obj_file}")

    # --- 11h. Borrow main attribute orchestrator ---
    def borrow_main_attribute(type_name, obj_name, form_name, mode):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        info(f"Borrowing main attribute for {type_name}.{obj_name} (mode: {mode})...")

        # Step 1: Collect DataPaths (Form mode) or take all (All mode)
        first_level_names = None
        deep_paths = []
        if mode == "Form":
            src_form_xml_path = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml")
            if not os.path.isfile(src_form_xml_path):
                print(f"Source Form.xml not found: {src_form_xml_path}", file=sys.stderr)
                sys.exit(1)
            dp = collect_form_data_paths(src_form_xml_path)
            first_level_names = dp["FirstLevel"]
            deep_paths = dp["DeepPaths"]
            info(f"  Collected {len(first_level_names)} first-level DataPath references, {len(deep_paths)} deep paths")
        else:
            info("  Mode All: borrowing all attributes and tabular sections")

        # Step 2: Resolve source attributes
        resolved = resolve_source_attributes(type_name, obj_name, first_level_names)
        src_attrs = resolved["Attributes"]
        src_ts = resolved["TabularSections"]
        extra_props = resolved["ExtraProps"]
        info(f"  Resolved: {len(src_attrs)} attributes, {len(src_ts)} tabular section(s)")

        # Identify which FirstLevel names are TabularSections (for deep path filtering)
        ts_names = {ts["Name"]: True for ts in src_ts}

        # Step 3: Build the adopted content and insert into main object XML
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")

        # Generate full object XML with attributes and TS
        content_parts = []
        for attr in src_attrs:
            attr_xml = build_adopted_attribute_xml(attr["Name"], attr["Uuid"], attr["TypeXml"], "\t\t\t")
            content_parts.append(attr_xml)
        for ts in src_ts:
            ts_xml = build_adopted_tabular_section_xml(ts["Name"], ts["Uuid"], ts["GeneratedTypes"], ts["Attributes"], "\t\t\t")
            content_parts.append(ts_xml)
        adopted_content = "\n".join(content_parts).rstrip()

        # Read existing object XML and inject
        with open(obj_file, "r", encoding="utf-8-sig") as fh:
            obj_content = fh.read()

        # Inject extra properties after ExtendedConfigurationObject
        if extra_props:
            props_xml = ""
            for p_name, p_val in extra_props.items():
                props_xml += f"\r\n\t\t\t<{p_name}>{p_val}</{p_name}>"
            obj_content = obj_content.replace("</ExtendedConfigurationObject>", f"</ExtendedConfigurationObject>{props_xml}")

        # Replace empty ChildObjects with adopted content
        if adopted_content:
            # Handle <ChildObjects/> (self-closing)
            if re.search(r'<ChildObjects\s*/>', obj_content):
                obj_content = re.sub(r'<ChildObjects\s*/>', f"<ChildObjects>\r\n{adopted_content}\r\n\t\t</ChildObjects>", obj_content)
            # Handle <ChildObjects>...</ChildObjects> (may already have Form entry)
            elif re.search(r'(?s)<ChildObjects>(.*?)</ChildObjects>', obj_content):
                m = re.search(r'(?s)<ChildObjects>(.*?)</ChildObjects>', obj_content)
                existing_inner = m.group(1)
                obj_content = obj_content.replace(
                    f"<ChildObjects>{existing_inner}</ChildObjects>",
                    f"<ChildObjects>{existing_inner}\r\n{adopted_content}\r\n\t\t</ChildObjects>"
                )

        save_text_bom(obj_file, obj_content)
        info(f"  Enriched object: {obj_file}")

        # Step 4: Collect all reference types and borrow as shells
        all_type_xmls = []
        for a in src_attrs:
            all_type_xmls.append(a["TypeXml"])
        for ts in src_ts:
            for tsa in ts["Attributes"]:
                all_type_xmls.append(tsa["TypeXml"])
        ref_types = collect_reference_types(all_type_xmls)
        info(f"  Reference types to borrow: {len(ref_types)}")

        for rt in ref_types:
            if rt["TypeName"] not in CHILD_TYPE_DIR_MAP:
                warn(f"  Unknown reference type: {rt['TypeName']}.{rt['ObjName']}")
                continue
            if test_object_borrowed(rt["TypeName"], rt["ObjName"]):
                info(f"  Already borrowed: {rt['TypeName']}.{rt['ObjName']}")
                continue
            rt_src_file = os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[rt["TypeName"]], f"{rt['ObjName']}.xml")
            if not os.path.isfile(rt_src_file):
                warn(f"  Source not found: {rt['TypeName']}.{rt['ObjName']}")
                continue
            src = read_source_object(rt["TypeName"], rt["ObjName"])
            borrowed_xml = build_borrowed_object_xml(rt["TypeName"], rt["ObjName"], src["Uuid"], src["Properties"])
            target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[rt["TypeName"]])
            os.makedirs(target_dir, exist_ok=True)
            target_file = os.path.join(target_dir, f"{rt['ObjName']}.xml")
            save_text_bom(target_file, borrowed_xml)
            add_to_child_objects(rt["TypeName"], rt["ObjName"])
            borrowed_files.append(target_file)
            info(f"  Auto-borrowed: {rt['TypeName']}.{rt['ObjName']}")

        # Step 5: Handle deep paths (Form mode only)
        if mode == "Form" and deep_paths:
            # Filter out deep paths where ObjectAttr is a TabularSection
            real_deep = [dp for dp in deep_paths if dp["ObjectAttr"] not in ts_names]

            if real_deep:
                info(f"  Processing {len(real_deep)} deep path(s)...")

                # Group by ObjectAttr -> target catalog
                deep_by_attr = {}
                for dp in real_deep:
                    if dp["ObjectAttr"] not in deep_by_attr:
                        deep_by_attr[dp["ObjectAttr"]] = []
                    deep_by_attr[dp["ObjectAttr"]].append(dp["SubAttr"])

                for attr_name, sub_attr_names in deep_by_attr.items():
                    # Find the attribute's type to determine target catalog
                    attr_info = None
                    for a in src_attrs:
                        if a["Name"] == attr_name:
                            attr_info = a
                            break
                    if not attr_info:
                        continue

                    # Extract catalog name from type: cfg:CatalogRef.XXX
                    cat_match = re.search(r'cfg:(\w+)Ref\.(\w+)', attr_info["TypeXml"])
                    if not cat_match:
                        continue

                    target_type_name = cat_match.group(1)
                    target_obj_name = cat_match.group(2)

                    # Ensure target is borrowed
                    if not test_object_borrowed(target_type_name, target_obj_name):
                        t_src = read_source_object(target_type_name, target_obj_name)
                        t_borrowed_xml = build_borrowed_object_xml(target_type_name, target_obj_name, t_src["Uuid"], t_src["Properties"])
                        t_target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[target_type_name])
                        os.makedirs(t_target_dir, exist_ok=True)
                        t_target_file = os.path.join(t_target_dir, f"{target_obj_name}.xml")
                        save_text_bom(t_target_file, t_borrowed_xml)
                        add_to_child_objects(target_type_name, target_obj_name)
                        borrowed_files.append(t_target_file)
                        info(f"  Auto-borrowed for deep path: {target_type_name}.{target_obj_name}")

                    # Resolve sub-attributes in target catalog
                    sub_names = {sn: True for sn in sub_attr_names}
                    sub_resolved = resolve_source_attributes(target_type_name, target_obj_name, sub_names)

                    if sub_resolved["Attributes"]:
                        merge_attributes_into_object(target_type_name, target_obj_name, sub_resolved["Attributes"])

                        # Collect and borrow ref types from deep attributes
                        sub_type_xmls = [sa["TypeXml"] for sa in sub_resolved["Attributes"]]
                        sub_ref_types = collect_reference_types(sub_type_xmls)
                        for srt in sub_ref_types:
                            if srt["TypeName"] not in CHILD_TYPE_DIR_MAP:
                                continue
                            if test_object_borrowed(srt["TypeName"], srt["ObjName"]):
                                continue
                            s_src_file = os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[srt["TypeName"]], f"{srt['ObjName']}.xml")
                            if not os.path.isfile(s_src_file):
                                continue
                            s_src = read_source_object(srt["TypeName"], srt["ObjName"])
                            s_borrowed_xml = build_borrowed_object_xml(srt["TypeName"], srt["ObjName"], s_src["Uuid"], s_src["Properties"])
                            s_target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[srt["TypeName"]])
                            os.makedirs(s_target_dir, exist_ok=True)
                            s_target_file = os.path.join(s_target_dir, f"{srt['ObjName']}.xml")
                            save_text_bom(s_target_file, s_borrowed_xml)
                            add_to_child_objects(srt["TypeName"], srt["ObjName"])
                            borrowed_files.append(s_target_file)
                            info(f"  Auto-borrowed (deep): {srt['TypeName']}.{srt['ObjName']}")

        info("  Main attribute borrowing complete")

    def borrow_form(type_name, obj_name, form_name, borrow_main_attr=False):
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
            f'<MetaDataObject {XMLNS_DECL} version="{format_version}">',
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

        form_version = src_form_el.get("version", format_version)

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
            if ln in ("ChildItems", "Events", "Attributes", "Commands", "Parameters", "CommandSet"):
                reached_visual = True
                continue
            if not reached_visual:
                # Form-level properties before AutoCommandBar (WindowOpeningMode, AutoFillCheck, etc.)
                form_props.append(etree.tostring(fc, encoding="unicode"))

        ns_strip_pattern = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')

        # AutoCommandBar: keep ChildItems (buttons with CommandName->0), Autofill->false
        auto_cmd_xml = ""
        if src_auto_cmd is not None:
            auto_cmd_xml = etree.tostring(src_auto_cmd, encoding="unicode")
            auto_cmd_xml = ns_strip_pattern.sub("", auto_cmd_xml)
            auto_cmd_xml = re.sub(r'<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>', auto_cmd_xml)
            auto_cmd_xml = auto_cmd_xml.replace('<Autofill>true</Autofill>', '<Autofill>false</Autofill>')
            # Strip ExcludedCommand (references to standard commands invalid in extension)
            auto_cmd_xml = re.sub(r'\s*<ExcludedCommand>[^<]*</ExcludedCommand>', '', auto_cmd_xml)
            # Strip DataPath in AutoCommandBar buttons
            if borrow_main_attr:
                # Keep only Объект.* DataPaths
                auto_cmd_xml = re.sub(r'\s*<DataPath>(?!\u041e\u0431\u044a\u0435\u043a\u0442\.)[^<]*</DataPath>', '', auto_cmd_xml)
            else:
                auto_cmd_xml = re.sub(r'\s*<DataPath>[^<]*</DataPath>', '', auto_cmd_xml)

        # ChildItems: copy full tree, clean up base-config references
        child_items_xml = ""
        src_child_items = None
        for fc in src_form_el:
            if isinstance(fc.tag, str) and localname(fc) == "ChildItems":
                src_child_items = fc
                break

        if src_child_items is not None:
            child_items_xml = etree.tostring(src_child_items, encoding="unicode")
            child_items_xml = ns_strip_pattern.sub("", child_items_xml)
            # Replace all CommandName values with 0
            child_items_xml = re.sub(r'<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>', child_items_xml)
            # Strip DataPath / TitleDataPath / RowPictureDataPath
            if borrow_main_attr:
                # Keep only Объект.* DataPaths — strip form-attribute DataPaths (not borrowed)
                child_items_xml = re.sub(r'\s*<DataPath>(?!\u041e\u0431\u044a\u0435\u043a\u0442\.)[^<]*</DataPath>', '', child_items_xml)
                child_items_xml = re.sub(r'\s*<TitleDataPath>(?!\u041e\u0431\u044a\u0435\u043a\u0442\.)[^<]*</TitleDataPath>', '', child_items_xml)
                child_items_xml = re.sub(r'\s*<RowPictureDataPath>[^<]*</RowPictureDataPath>', '', child_items_xml)
            else:
                child_items_xml = re.sub(r'\s*<DataPath>[^<]*</DataPath>', '', child_items_xml)
                child_items_xml = re.sub(r'\s*<TitleDataPath>[^<]*</TitleDataPath>', '', child_items_xml)
                child_items_xml = re.sub(r'\s*<RowPictureDataPath>[^<]*</RowPictureDataPath>', '', child_items_xml)
            # Strip ExcludedCommand in nested AutoCommandBars (references to standard commands invalid in extension)
            child_items_xml = re.sub(r'\s*<ExcludedCommand>[^<]*</ExcludedCommand>', '', child_items_xml)
            # Strip TypeLink blocks with human-readable DataPath (Items.XXX)
            child_items_xml = re.sub(r'\s*<TypeLink>\s*<xr:DataPath>Items\.[^<]*</xr:DataPath>.*?</TypeLink>', '', child_items_xml, flags=re.DOTALL)
            # Strip element-level Events
            child_items_xml = re.sub(r'\s*<Events>.*?</Events>', '', child_items_xml, flags=re.DOTALL)

            # Collect CommonPicture references from ChildItems and AutoCommandBar
            referenced_pictures = {}
            for name in re.findall(r'<xr:Ref>CommonPicture\.(\w+)</xr:Ref>', child_items_xml):
                referenced_pictures[name] = True
            if auto_cmd_xml:
                for name in re.findall(r'<xr:Ref>CommonPicture\.(\w+)</xr:Ref>', auto_cmd_xml):
                    referenced_pictures[name] = True

            # Auto-borrow referenced CommonPictures
            auto_borrowed_pics = []
            for pic_name in referenced_pictures:
                if not test_object_borrowed("CommonPicture", pic_name):
                    pic_src_file = os.path.join(cfg_dir, "CommonPictures", f"{pic_name}.xml")
                    if os.path.isfile(pic_src_file):
                        src = read_source_object("CommonPicture", pic_name)
                        borrowed_xml = build_borrowed_object_xml("CommonPicture", pic_name, src["Uuid"], src["Properties"])
                        target_dir = os.path.join(ext_dir, "CommonPictures")
                        os.makedirs(target_dir, exist_ok=True)
                        target_file = os.path.join(target_dir, f"{pic_name}.xml")
                        save_text_bom(target_file, borrowed_xml)
                        add_to_child_objects("CommonPicture", pic_name)
                        auto_borrowed_pics.append(pic_name)
                        borrowed_files.append(target_file)
                        info(f"  Auto-borrowed: CommonPicture.{pic_name}")
                    else:
                        warn(f"  CommonPicture.{pic_name} not found in source config — will strip from form")

            # Collect all borrowed CommonPictures for Picture stripping
            borrowed_pic_set = set()
            for co_child in child_objs_el:
                if isinstance(co_child.tag, str) and localname(co_child) == "CommonPicture":
                    borrowed_pic_set.add((co_child.text or "").strip())

            # Strip <Picture> blocks referencing non-borrowed CommonPictures (reverse order)
            pic_block_pattern = re.compile(r'\s*<Picture>\s*<xr:Ref>CommonPicture\.(\w+)</xr:Ref>.*?</Picture>', re.DOTALL)
            pic_matches = list(pic_block_pattern.finditer(child_items_xml))
            for pm in reversed(pic_matches):
                cp_name = pm.group(1)
                if cp_name not in borrowed_pic_set:
                    child_items_xml = child_items_xml[:pm.start()] + child_items_xml[pm.end():]
            # Strip StdPicture blocks (except Print)
            child_items_xml = re.sub(r'\s*<Picture>\s*<xr:Ref>StdPicture\.(?!Print\b)\w+</xr:Ref>.*?</Picture>', '', child_items_xml, flags=re.DOTALL)

            # Same Picture strip for AutoCommandBar
            if auto_cmd_xml:
                ac_pic_matches = list(pic_block_pattern.finditer(auto_cmd_xml))
                for pm in reversed(ac_pic_matches):
                    cp_name = pm.group(1)
                    if cp_name not in borrowed_pic_set:
                        auto_cmd_xml = auto_cmd_xml[:pm.start()] + auto_cmd_xml[pm.end():]
                auto_cmd_xml = re.sub(r'\s*<Picture>\s*<xr:Ref>StdPicture\.(?!Print\b)\w+</xr:Ref>.*?</Picture>', '', auto_cmd_xml, flags=re.DOTALL)

            # Auto-borrow StyleItems referenced in ChildItems
            referenced_styles = set()
            for m in re.finditer(r'ref="style:(\w+)"[^>]*kind="StyleItem"', child_items_xml):
                referenced_styles.add(m.group(1))
            for m in re.finditer(r'>style:(\w+)</\w+>', child_items_xml):
                referenced_styles.add(m.group(1))

            for style_name in referenced_styles:
                if not test_object_borrowed("StyleItem", style_name):
                    style_src_file = os.path.join(cfg_dir, "StyleItems", f"{style_name}.xml")
                    if os.path.isfile(style_src_file):
                        src = read_source_object("StyleItem", style_name)
                        borrowed_xml = build_borrowed_object_xml("StyleItem", style_name, src["Uuid"], src["Properties"])
                        target_dir = os.path.join(ext_dir, "StyleItems")
                        os.makedirs(target_dir, exist_ok=True)
                        target_file = os.path.join(target_dir, f"{style_name}.xml")
                        save_text_bom(target_file, borrowed_xml)
                        add_to_child_objects("StyleItem", style_name)
                        borrowed_files.append(target_file)
                        info(f"  Auto-borrowed: StyleItem.{style_name}")
                    else:
                        warn(f"  StyleItem.{style_name} not found in source config")

            # Auto-borrow Enums + EnumValues referenced via DesignTimeRef
            referenced_enum_values = {}  # enum_name -> set of value_names
            for m in re.finditer(r'xr:DesignTimeRef">Enum\.(\w+)\.EnumValue\.(\w+)', child_items_xml):
                e_name, ev_name = m.group(1), m.group(2)
                if e_name not in referenced_enum_values:
                    referenced_enum_values[e_name] = set()
                referenced_enum_values[e_name].add(ev_name)

            for enum_name, needed_values in referenced_enum_values.items():
                if not test_object_borrowed("Enum", enum_name):
                    enum_src_file = os.path.join(cfg_dir, "Enums", f"{enum_name}.xml")
                    if os.path.isfile(enum_src_file):
                        # Read source Enum to find EnumValue UUIDs
                        src_enum_tree = etree.parse(enum_src_file, etree.XMLParser(remove_blank_text=False))
                        src_enum_root = src_enum_tree.getroot()
                        src_enum_el = None
                        for cn in src_enum_root:
                            if isinstance(cn.tag, str):
                                src_enum_el = cn
                                break

                        # Find needed EnumValues
                        ev_xmls = []
                        for ev_node in src_enum_el.iter():
                            if isinstance(ev_node.tag, str) and localname(ev_node) == "EnumValue":
                                ev_uuid = ev_node.get("uuid", "")
                                name_el = None
                                for props in ev_node:
                                    if isinstance(props.tag, str) and localname(props) == "Properties":
                                        for prop in props:
                                            if isinstance(prop.tag, str) and localname(prop) == "Name":
                                                name_el = prop
                                                break
                                if name_el is not None and (name_el.text or "").strip() in needed_values:
                                    new_ev_uuid = str(uuid.uuid4())
                                    ev_xmls.append(
                                        f'\t\t\t<EnumValue uuid="{new_ev_uuid}">\n'
                                        f'\t\t\t\t<InternalInfo/>\n'
                                        f'\t\t\t\t<Properties>\n'
                                        f'\t\t\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>\n'
                                        f'\t\t\t\t\t<Name>{name_el.text.strip()}</Name>\n'
                                        f'\t\t\t\t\t<Comment/>\n'
                                        f'\t\t\t\t\t<ExtendedConfigurationObject>{ev_uuid}</ExtendedConfigurationObject>\n'
                                        f'\t\t\t\t</Properties>\n'
                                        f'\t\t\t</EnumValue>'
                                    )

                        # Build borrowed Enum with EnumValues
                        src_obj = read_source_object("Enum", enum_name)
                        borrowed_xml = build_borrowed_object_xml("Enum", enum_name, src_obj["Uuid"], src_obj["Properties"])
                        if ev_xmls:
                            ev_block = "\n".join(ev_xmls)
                            borrowed_xml = borrowed_xml.replace("<ChildObjects/>", f"<ChildObjects>\n{ev_block}\n\t\t</ChildObjects>")

                        target_dir = os.path.join(ext_dir, "Enums")
                        os.makedirs(target_dir, exist_ok=True)
                        target_file = os.path.join(target_dir, f"{enum_name}.xml")
                        save_text_bom(target_file, borrowed_xml)
                        add_to_child_objects("Enum", enum_name)
                        borrowed_files.append(target_file)
                        info(f"  Auto-borrowed: Enum.{enum_name} (with {len(ev_xmls)} EnumValue(s))")
                    else:
                        warn(f"  Enum.{enum_name} not found in source config")

        # Extract the <Form ...> opening tag from source text
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

        # Part 1: form properties + AutoCommandBar + ChildItems
        for prop_xml in form_props:
            prop_xml_clean = ns_strip_pattern.sub("", prop_xml)
            parts.append(f"\t{prop_xml_clean}\r\n")
        if auto_cmd_xml:
            parts.append(f"\t{auto_cmd_xml}\r\n")
        if child_items_xml:
            parts.append(f"\t{child_items_xml}\r\n")

        # Attributes: empty or with MainAttribute when borrow_main_attr
        if borrow_main_attr:
            obj_type_prefix = ""
            gt_list = GENERATED_TYPES.get(type_name, [])
            for g in gt_list:
                if g["category"] == "Object":
                    obj_type_prefix = g["prefix"]
                    break
            main_attr_type = f"cfg:{obj_type_prefix}.{obj_name}"
            parts.append("\t<Attributes>\r\n")
            parts.append('\t\t<Attribute name="\u041e\u0431\u044a\u0435\u043a\u0442" id="1000001">\r\n')
            parts.append(f"\t\t\t<Type><v8:Type>{main_attr_type}</v8:Type></Type>\r\n")
            parts.append("\t\t\t<MainAttribute>true</MainAttribute>\r\n")
            parts.append("\t\t\t<SavedData>true</SavedData>\r\n")
            parts.append("\t\t</Attribute>\r\n")
            parts.append("\t</Attributes>")
        else:
            parts.append("\t<Attributes/>")
        parts.append("\r\n")

        # BaseForm: same content, indented one more level
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
        if child_items_xml:
            ci_lines = child_items_xml.split("\n")
            for li, line in enumerate(ci_lines):
                if li == 0:
                    parts.append(f"\t\t{line}")
                else:
                    parts.append(f"\t{line}")
                parts.append("\r\n")

        # BaseForm Attributes: same as main section
        if borrow_main_attr:
            parts.append("\t\t<Attributes>\r\n")
            parts.append('\t\t\t<Attribute name="\u041e\u0431\u044a\u0435\u043a\u0442" id="1000001">\r\n')
            parts.append(f"\t\t\t\t<Type><v8:Type>{main_attr_type}</v8:Type></Type>\r\n")
            parts.append("\t\t\t\t<MainAttribute>true</MainAttribute>\r\n")
            parts.append("\t\t\t\t<SavedData>true</SavedData>\r\n")
            parts.append("\t\t\t</Attribute>\r\n")
            parts.append("\t\t</Attributes>")
        else:
            parts.append("\t\t<Attributes/>")
        parts.append("\r\n")
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

    # --- 9b. Validate -BorrowMainAttribute ---
    borrow_main_attribute_mode = args.BorrowMainAttribute
    if borrow_main_attribute_mode is not None:
        if borrow_main_attribute_mode not in ("Form", "All"):
            print("-BorrowMainAttribute accepts 'Form' or 'All' (default: Form)", file=sys.stderr)
            sys.exit(1)
        # Validate: only with .Form. pattern
        has_form = any(".Form." in item for item in items)
        if not has_form:
            print("-BorrowMainAttribute requires a form in -Object (e.g. 'Catalog.X.Form.Y')", file=sys.stderr)
            sys.exit(1)

    # --- 10. Process each item ---
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

            has_bma = borrow_main_attribute_mode is not None
            form_files = borrow_form(type_name, obj_name, form_name, borrow_main_attr=has_bma)
            borrowed_files.extend(form_files)
            borrowed_count += 1

            # Borrow main attribute if requested
            if has_bma:
                borrow_main_attribute(type_name, obj_name, form_name, borrow_main_attribute_mode)
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
