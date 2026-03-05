# meta-validate v1.0 — Validate 1C metadata object structure (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import re
import sys

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# ── arg parsing ──────────────────────────────────────────────

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-ObjectPath", required=True)
parser.add_argument("-MaxErrors", type=int, default=30)
parser.add_argument("-OutFile", default="")
args = parser.parse_args()

object_path = args.ObjectPath
max_errors = args.MaxErrors
out_file = args.OutFile

# ── resolve path ─────────────────────────────────────────────

if not os.path.isabs(object_path):
    object_path = os.path.join(os.getcwd(), object_path)

if os.path.isdir(object_path):
    dir_name = os.path.basename(object_path)
    candidate = os.path.join(object_path, f"{dir_name}.xml")
    sibling = os.path.join(os.path.dirname(object_path), f"{dir_name}.xml")
    if os.path.exists(candidate):
        object_path = candidate
    elif os.path.exists(sibling):
        object_path = sibling
    else:
        xml_files = [f for f in os.listdir(object_path) if f.endswith(".xml")]
        if xml_files:
            object_path = os.path.join(object_path, xml_files[0])
        else:
            print(f"[ERROR] No XML file found in directory: {object_path}")
            sys.exit(1)

# File not found -- check Dir/Name/Name.xml -> Dir/Name.xml
if not os.path.exists(object_path):
    file_name = os.path.splitext(os.path.basename(object_path))[0]
    parent_dir = os.path.dirname(object_path)
    parent_dir_name = os.path.basename(parent_dir)
    if file_name == parent_dir_name:
        candidate = os.path.join(os.path.dirname(parent_dir), f"{file_name}.xml")
        if os.path.exists(candidate):
            object_path = candidate

if not os.path.exists(object_path):
    print(f"[ERROR] File not found: {object_path}")
    sys.exit(1)

resolved_path = os.path.abspath(object_path)

# ── output infrastructure ────────────────────────────────────

errors = 0
warnings = 0
stopped = False
output_lines = []


def out_line(msg):
    output_lines.append(msg)


def report_ok(msg):
    out_line(f"[OK]    {msg}")


def report_error(msg):
    global errors, stopped
    errors += 1
    out_line(f"[ERROR] {msg}")
    if errors >= max_errors:
        stopped = True


def report_warn(msg):
    global warnings
    warnings += 1
    out_line(f"[WARN]  {msg}")


def finalize():
    out_line("")
    out_line(f"=== Result: {errors} errors, {warnings} warnings ===")
    result = "\n".join(output_lines)
    print(result)
    if out_file:
        with open(out_file, "w", encoding="utf-8-sig") as f:
            f.write(result)
        print(f"Written to: {out_file}")


# ── Reference tables ─────────────────────────────────────────

guid_pattern = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
ident_pattern = re.compile(r'^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_][A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$')

valid_types = (
    "Catalog", "Document", "Enum", "Constant",
    "InformationRegister", "AccumulationRegister", "AccountingRegister", "CalculationRegister",
    "ChartOfAccounts", "ChartOfCharacteristicTypes", "ChartOfCalculationTypes",
    "BusinessProcess", "Task", "ExchangePlan", "DocumentJournal",
    "Report", "DataProcessor",
    "CommonModule", "ScheduledJob", "EventSubscription",
    "HTTPService", "WebService", "DefinedType",
)

# GeneratedType categories by type
generated_type_categories = {
    "Catalog":                    ["Object", "Ref", "Selection", "List", "Manager"],
    "Document":                   ["Object", "Ref", "Selection", "List", "Manager"],
    "Enum":                       ["Ref", "Manager", "List"],
    "Constant":                   ["Manager", "ValueManager", "ValueKey"],
    "InformationRegister":        ["Record", "Manager", "Selection", "List", "RecordSet", "RecordKey", "RecordManager"],
    "AccumulationRegister":       ["Record", "Manager", "Selection", "List", "RecordSet", "RecordKey"],
    "AccountingRegister":         ["Record", "Manager", "Selection", "List", "RecordSet", "RecordKey", "ExtDimensions"],
    "CalculationRegister":        ["Record", "Manager", "Selection", "List", "RecordSet", "RecordKey", "Recalcs"],
    "ChartOfAccounts":            ["Object", "Ref", "Selection", "List", "Manager", "ExtDimensionTypes", "ExtDimensionTypesRow"],
    "ChartOfCharacteristicTypes": ["Object", "Ref", "Selection", "List", "Manager", "Characteristic"],
    "ChartOfCalculationTypes":    ["Object", "Ref", "Selection", "List", "Manager", "DisplacingCalculationTypes", "DisplacingCalculationTypesRow", "BaseCalculationTypes", "BaseCalculationTypesRow", "LeadingCalculationTypes", "LeadingCalculationTypesRow"],
    "BusinessProcess":            ["Object", "Ref", "Selection", "List", "Manager", "RoutePointRef"],
    "Task":                       ["Object", "Ref", "Selection", "List", "Manager"],
    "ExchangePlan":               ["Object", "Ref", "Selection", "List", "Manager"],
    "DocumentJournal":            ["Selection", "List", "Manager"],
    "Report":                     ["Object", "Manager"],
    "DataProcessor":              ["Object", "Manager"],
    "DefinedType":                ["DefinedType"],
}

# Types that have NO InternalInfo / GeneratedType
types_without_internal_info = ("CommonModule", "ScheduledJob", "EventSubscription")

# StandardAttributes by type
standard_attributes_by_type = {
    "Catalog":                    ["PredefinedDataName", "Predefined", "Ref", "DeletionMark", "IsFolder", "Owner", "Parent", "Description", "Code"],
    "Document":                   ["Posted", "Ref", "DeletionMark", "Date", "Number"],
    "Enum":                       ["Order", "Ref"],
    "InformationRegister":        ["Active", "LineNumber", "Recorder", "Period"],
    "AccumulationRegister":       ["Active", "LineNumber", "Recorder", "Period", "RecordType"],
    "AccountingRegister":         ["Active", "Period", "Recorder", "LineNumber", "Account"],
    "CalculationRegister":        ["Active", "Recorder", "LineNumber", "RegistrationPeriod", "CalculationType", "ReversingEntry", "ActionPeriod", "BegOfActionPeriod", "EndOfActionPeriod", "BegOfBasePeriod", "EndOfBasePeriod"],
    "ChartOfAccounts":            ["PredefinedDataName", "Predefined", "Ref", "DeletionMark", "Description", "Code", "Parent", "Order", "Type", "OffBalance"],
    "ChartOfCharacteristicTypes": ["PredefinedDataName", "Predefined", "Ref", "DeletionMark", "Description", "Code", "Parent", "IsFolder", "ValueType"],
    "ChartOfCalculationTypes":    ["PredefinedDataName", "Predefined", "Ref", "DeletionMark", "Description", "Code", "ActionPeriodIsBasic"],
    "BusinessProcess":            ["Ref", "DeletionMark", "Date", "Number", "Started", "Completed", "HeadTask"],
    "Task":                       ["Ref", "DeletionMark", "Date", "Number", "Executed", "Description", "RoutePoint", "BusinessProcess"],
    "ExchangePlan":               ["Ref", "DeletionMark", "Code", "Description", "ThisNode", "SentNo", "ReceivedNo"],
    "DocumentJournal":            ["Type", "Ref", "Date", "Posted", "DeletionMark", "Number"],
}

# Types that have StandardAttributes block
types_with_std_attrs = (
    "Catalog", "Document", "Enum",
    "InformationRegister", "AccumulationRegister", "AccountingRegister", "CalculationRegister",
    "ChartOfAccounts", "ChartOfCharacteristicTypes", "ChartOfCalculationTypes",
    "BusinessProcess", "Task", "ExchangePlan", "DocumentJournal",
)

# ChildObjects rules
child_object_rules = {
    "Catalog":                    ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "Document":                   ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "ExchangePlan":               ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "ChartOfAccounts":            ["Attribute", "TabularSection", "Form", "Template", "Command", "AccountingFlag", "ExtDimensionAccountingFlag"],
    "ChartOfCharacteristicTypes": ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "ChartOfCalculationTypes":    ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "BusinessProcess":            ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "Task":                       ["Attribute", "TabularSection", "Form", "Template", "Command", "AddressingAttribute"],
    "Report":                     ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "DataProcessor":              ["Attribute", "TabularSection", "Form", "Template", "Command"],
    "Enum":                       ["EnumValue", "Form", "Template", "Command"],
    "InformationRegister":        ["Dimension", "Resource", "Attribute", "Form", "Template", "Command"],
    "AccumulationRegister":       ["Dimension", "Resource", "Attribute", "Form", "Template", "Command"],
    "AccountingRegister":         ["Dimension", "Resource", "Attribute", "Form", "Template", "Command"],
    "CalculationRegister":        ["Dimension", "Resource", "Attribute", "Form", "Template", "Command", "Recalculation"],
    "DocumentJournal":            ["Column", "Form", "Template", "Command"],
    "HTTPService":                ["URLTemplate"],
    "WebService":                 ["Operation"],
    "Constant":                   ["Form"],
    "DefinedType":                [],
    "CommonModule":               [],
    "ScheduledJob":               [],
    "EventSubscription":          [],
}

# Valid enum property values
valid_property_values = {
    "CodeType":                     ["String", "Number"],
    "CodeAllowedLength":            ["Variable", "Fixed"],
    "NumberType":                   ["String", "Number"],
    "NumberAllowedLength":          ["Variable", "Fixed"],
    "Posting":                      ["Allow", "Deny"],
    "RealTimePosting":              ["Allow", "Deny"],
    "RegisterRecordsDeletion":      ["AutoDelete", "AutoDeleteOnUnpost", "AutoDeleteOff"],
    "RegisterRecordsWritingOnPost": ["WriteModified", "WriteSelected", "WriteAll"],
    "DataLockControlMode":          ["Automatic", "Managed"],
    "FullTextSearch":               ["Use", "DontUse"],
    "DefaultPresentation":          ["AsDescription", "AsCode"],
    "HierarchyType":                ["HierarchyFoldersAndItems", "HierarchyItemsOnly"],
    "EditType":                     ["InDialog", "InList", "BothWays"],
    "WriteMode":                    ["Independent", "RecorderSubordinate"],
    "InformationRegisterPeriodicity": ["Nonperiodical", "Second", "Day", "Month", "Quarter", "Year", "RecorderPosition"],
    "RegisterType":                 ["Balance", "Turnovers"],
    "ReturnValuesReuse":            ["DontUse", "DuringRequest", "DuringSession"],
    "ReuseSessions":                ["DontUse", "AutoUse"],
    "FillChecking":                 ["DontCheck", "ShowError", "ShowWarning"],
    "Indexing":                     ["DontIndex", "Index", "IndexWithAdditionalOrder"],
    "DataHistory":                  ["Use", "DontUse"],
}

# ── Namespaces ───────────────────────────────────────────────

NS = {
    "md":  "http://v8.1c.ru/8.3/MDClasses",
    "v8":  "http://v8.1c.ru/8.1/data/core",
    "xr":  "http://v8.1c.ru/8.3/xcf/readable",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "xs":  "http://www.w3.org/2001/XMLSchema",
    "cfg": "http://v8.1c.ru/8.1/data/enterprise/current-config",
}

MD_NS = NS["md"]


def local_name(node):
    return etree.QName(node.tag).localname


def find(parent, xpath):
    r = parent.xpath(xpath, namespaces=NS)
    return r[0] if r else None


def find_all(parent, xpath):
    return parent.xpath(xpath, namespaces=NS)


def inner_text(node):
    if node is None:
        return ""
    return node.text or ""


def text_of(node):
    if node is None:
        return ""
    return (node.text or "").strip()


# ── 1. Parse XML ─────────────────────────────────────────────

out_line("")

tree = None
try:
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(resolved_path, parser_xml)
except Exception as e:
    out_line("=== Validation: (parse failed) ===")
    out_line("")
    report_error(f"1. XML parse failed: {e}")
    finalize()
    sys.exit(1)

root = tree.getroot()

# ── Check 1: Root structure ──────────────────────────────────

check1_ok = True

if local_name(root) != "MetaDataObject":
    report_error(f"1. Root element is '{local_name(root)}', expected 'MetaDataObject'")
    finalize()
    sys.exit(1)

expected_ns = "http://v8.1c.ru/8.3/MDClasses"
root_ns = etree.QName(root.tag).namespace or ""
if root_ns != expected_ns:
    report_error(f"1. Root namespace is '{root_ns}', expected '{expected_ns}'")
    check1_ok = False

# Version attribute
version = root.get("version", "")
if not version:
    report_warn("1. Missing version attribute on MetaDataObject")
elif version not in ("2.17", "2.20"):
    report_warn(f"1. Unusual version '{version}' (expected 2.17 or 2.20)")

# Detect type element -- exactly one child element in md namespace
type_node = None
md_type = ""
child_elements = []
for child in root:
    if isinstance(child.tag, str) and etree.QName(child.tag).namespace == expected_ns:
        child_elements.append(child)

if len(child_elements) == 0:
    report_error("1. No metadata type element found inside MetaDataObject")
    finalize()
    sys.exit(1)
elif len(child_elements) > 1:
    names = [local_name(c) for c in child_elements]
    report_error(f"1. Multiple type elements found: {names}")
    check1_ok = False

type_node = child_elements[0]
md_type = local_name(type_node)

if md_type not in valid_types:
    report_error(f"1. Unrecognized metadata type: {md_type}")
    finalize()
    sys.exit(1)

# UUID on type element
type_uuid = type_node.get("uuid", "")
if not type_uuid:
    report_error(f"1. Missing uuid on <{md_type}> element")
    check1_ok = False
elif not guid_pattern.match(type_uuid):
    report_error(f"1. Invalid uuid '{type_uuid}' on <{md_type}>")
    check1_ok = False

# Get object name early for header
props_node = find(type_node, "md:Properties")
name_node = find(props_node, "md:Name") if props_node is not None else None
obj_name = inner_text(name_node) if name_node is not None and inner_text(name_node) else "(unknown)"

# Now emit header — insert at beginning
output_lines.insert(0, f"=== Validation: {md_type}.{obj_name} ===")

if check1_ok:
    report_ok(f"1. Root structure: MetaDataObject/{md_type}, version {version}")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 2: InternalInfo ────────────────────────────────────

internal_info = find(type_node, "md:InternalInfo")

if md_type in types_without_internal_info:
    if internal_info is not None:
        gen_types = find_all(internal_info, "xr:GeneratedType")
        if len(gen_types) > 0:
            report_warn(f"2. InternalInfo: {md_type} should not have GeneratedType entries, found {len(gen_types)}")
        else:
            report_ok(f"2. InternalInfo: absent or empty (correct for {md_type})")
    else:
        report_ok(f"2. InternalInfo: absent (correct for {md_type})")
elif md_type in generated_type_categories:
    expected_categories = generated_type_categories[md_type]
    if internal_info is None:
        report_error(f"2. InternalInfo: missing (expected {len(expected_categories)} GeneratedType)")
    else:
        gen_types = find_all(internal_info, "xr:GeneratedType")
        check2_ok = True
        found_categories = []

        for gt in gen_types:
            gt_name = gt.get("name", "")
            gt_category = gt.get("category", "")
            found_categories.append(gt_category)

            # Validate name format
            if gt_name and obj_name != "(unknown)":
                if not gt_name.endswith(f".{obj_name}"):
                    report_error(f"2. GeneratedType name '{gt_name}' does not end with '.{obj_name}'")
                    check2_ok = False

            # Validate category
            if gt_category not in expected_categories:
                report_warn(f"2. Unexpected GeneratedType category '{gt_category}' for {md_type}")

            # Validate TypeId and ValueId UUIDs
            type_id = find(gt, "xr:TypeId")
            value_id = find(gt, "xr:ValueId")
            if type_id is not None and not guid_pattern.match(inner_text(type_id)):
                report_error(f"2. Invalid TypeId UUID in GeneratedType '{gt_category}'")
                check2_ok = False
            if value_id is not None and not guid_pattern.match(inner_text(value_id)):
                report_error(f"2. Invalid ValueId UUID in GeneratedType '{gt_category}'")
                check2_ok = False

        # ExchangePlan: check for ThisNode
        if md_type == "ExchangePlan":
            this_node = find(internal_info, "xr:ThisNode")
            if this_node is None:
                report_warn("2. ExchangePlan missing xr:ThisNode in InternalInfo")
            elif not guid_pattern.match(inner_text(this_node)):
                report_error("2. ExchangePlan xr:ThisNode has invalid UUID")
                check2_ok = False

        # Check count mismatch
        missing_cats = [c for c in expected_categories if c not in found_categories]
        if missing_cats:
            report_warn(f"2. Missing GeneratedType categories: {', '.join(missing_cats)}")

        if check2_ok:
            cat_list = ", ".join(sorted(found_categories))
            report_ok(f"2. InternalInfo: {len(gen_types)} GeneratedType ({cat_list})")
else:
    report_ok(f"2. InternalInfo: N/A for {md_type}")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 3: Properties -- Name, Synonym ─────────────────────

if props_node is None:
    report_error("3. Properties block missing")
else:
    check3_ok = True

    # Name
    if name_node is None or not inner_text(name_node):
        report_error("3. Properties: Name is missing or empty")
        check3_ok = False
    else:
        name_val = inner_text(name_node)
        if not ident_pattern.match(name_val):
            report_error(f"3. Properties: Name '{name_val}' is not a valid 1C identifier")
            check3_ok = False
        if len(name_val) > 80:
            report_warn(f"3. Properties: Name '{name_val}' is longer than 80 characters ({len(name_val)})")

    # Synonym
    syn_node = find(props_node, "md:Synonym")
    syn_present = False
    if syn_node is not None:
        syn_item = find(syn_node, "v8:item")
        if syn_item is not None:
            syn_content = find(syn_item, "v8:content")
            if syn_content is not None and inner_text(syn_content):
                syn_present = True

    if check3_ok:
        syn_info = "Synonym present" if syn_present else "no Synonym"
        report_ok(f'3. Properties: Name="{obj_name}", {syn_info}')

if stopped:
    finalize()
    sys.exit(1)

# ── Check 4: Property values -- enum properties ──────────────

if props_node is not None:
    enum_checked = 0
    check4_ok = True

    for prop_name, allowed in valid_property_values.items():
        prop_node = find(props_node, f"md:{prop_name}")
        if prop_node is not None and inner_text(prop_node):
            val = inner_text(prop_node)
            if val not in allowed:
                report_error(f"4. Property '{prop_name}' has invalid value '{val}' (allowed: {', '.join(allowed)})")
                check4_ok = False
            enum_checked += 1

    if check4_ok:
        report_ok(f"4. Property values: {enum_checked} enum properties checked")
else:
    report_warn("4. No Properties block to check")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 5: StandardAttributes ──────────────────────────────

if md_type in types_with_std_attrs:
    std_attr_node = find(props_node, "md:StandardAttributes")
    if std_attr_node is None:
        report_ok(f"5. StandardAttributes: absent (optional for {md_type})")
    else:
        std_attrs = find_all(std_attr_node, "xr:StandardAttribute")
        expected_std_attrs = standard_attributes_by_type.get(md_type, [])
        check5_ok = True

        found_names = []
        for sa in std_attrs:
            sa_name = sa.get("name", "")
            if sa_name:
                found_names.append(sa_name)
                if sa_name not in expected_std_attrs:
                    # AccountingRegister has dynamic attrs
                    is_dynamic = (md_type == "AccountingRegister" and
                                  (re.match(r'^ExtDimension\d+$', sa_name) or
                                   re.match(r'^ExtDimensionType\d+$', sa_name) or
                                   sa_name == "PeriodAdjustment"))
                    # CalculationRegister has conditional period attrs
                    is_calc_dynamic = (md_type == "CalculationRegister" and
                                       sa_name in ("ActionPeriod", "BegOfActionPeriod", "EndOfActionPeriod",
                                                    "BegOfBasePeriod", "EndOfBasePeriod"))
                    if not is_dynamic and not is_calc_dynamic:
                        report_warn(f"5. Unexpected StandardAttribute '{sa_name}' for {md_type}")
            else:
                report_error("5. StandardAttribute without 'name' attribute")
                check5_ok = False

        if expected_std_attrs:
            missing_attrs = [a for a in expected_std_attrs if a not in found_names]
            if missing_attrs:
                report_warn(f"5. Missing StandardAttributes: {', '.join(missing_attrs)}")

        if check5_ok:
            report_ok(f"5. StandardAttributes: {len(std_attrs)} entries")
else:
    report_ok(f"5. StandardAttributes: N/A for {md_type}")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 6: ChildObjects -- allowed element types ───────────

child_obj_node = find(type_node, "md:ChildObjects")
allowed_children = child_object_rules.get(md_type, [])

if child_obj_node is not None:
    check6_ok = True
    child_counts = {}

    for child in child_obj_node:
        if not isinstance(child.tag, str):
            continue
        child_tag = local_name(child)

        if child_tag not in allowed_children:
            report_error(f"6. ChildObjects: disallowed element '{child_tag}' for {md_type}")
            check6_ok = False

        child_counts[child_tag] = child_counts.get(child_tag, 0) + 1

    if check6_ok:
        summary = ", ".join(f"{k}({v})" for k, v in sorted(child_counts.items()))
        if summary:
            report_ok(f"6. ChildObjects types: {summary}")
        else:
            report_ok(f"6. ChildObjects: empty (valid for {md_type})")
elif len(allowed_children) == 0:
    report_ok(f"6. ChildObjects: absent (correct for {md_type})")
else:
    report_ok("6. ChildObjects: absent")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 7: Child elements -- UUID, Name, Type ──────────────


def check_child_element(node, kind, require_type):
    uuid = node.get("uuid", "")
    if not uuid:
        report_error(f"7. {kind} missing uuid")
        return False
    if not guid_pattern.match(uuid):
        report_error(f"7. {kind} has invalid uuid '{uuid}'")
        return False

    el_props = find(node, "md:Properties")
    if el_props is None:
        report_error(f"7. {kind} (uuid={uuid}) missing Properties")
        return False

    el_name = find(el_props, "md:Name")
    if el_name is None or not inner_text(el_name):
        report_error(f"7. {kind} (uuid={uuid}) missing or empty Name")
        return False

    name_val = inner_text(el_name)
    if not ident_pattern.match(name_val):
        report_error(f"7. {kind} '{name_val}' has invalid identifier")
        return False

    if require_type:
        type_el = find(el_props, "md:Type")
        if type_el is None:
            report_error(f"7. {kind} '{name_val}' missing Type block")
            return False
        v8_types = find_all(type_el, "v8:Type")
        v8_type_sets = find_all(type_el, "v8:TypeSet")
        if len(v8_types) == 0 and len(v8_type_sets) == 0:
            report_error(f"7. {kind} '{name_val}' Type block has no v8:Type or v8:TypeSet")
            return False

    return True


if child_obj_node is not None:
    check7_ok = True
    check7_count = 0
    element_kinds = ("Attribute", "Dimension", "Resource", "EnumValue", "Column")

    for kind in element_kinds:
        elements = find_all(child_obj_node, f"md:{kind}")
        require_type = kind not in ("EnumValue", "Column")
        for el in elements:
            if stopped:
                break
            ok = check_child_element(el, kind, require_type)
            if not ok:
                check7_ok = False
            check7_count += 1

    if check7_ok and check7_count > 0:
        report_ok(f"7. Child elements: {check7_count} items checked (UUID, Name, Type)")
    elif check7_count == 0:
        report_ok("7. Child elements: none to check")
else:
    report_ok("7. Child elements: N/A (no ChildObjects)")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 8: Name uniqueness ─────────────────────────────────


def check_uniqueness(nodes, kind):
    names = {}
    has_dupes = False
    for node in nodes:
        el_props = find(node, "md:Properties")
        if el_props is None:
            continue
        el_name = find(el_props, "md:Name")
        if el_name is None or not inner_text(el_name):
            continue
        name_val = inner_text(el_name)
        if name_val in names:
            report_error(f"8. Duplicate {kind} name: '{name_val}'")
            has_dupes = True
        else:
            names[name_val] = True
    return not has_dupes


if child_obj_node is not None:
    check8_ok = True

    # Attributes
    attrs = find_all(child_obj_node, "md:Attribute")
    if len(attrs) > 0:
        if not check_uniqueness(attrs, "Attribute"):
            check8_ok = False

    # TabularSections
    tss = find_all(child_obj_node, "md:TabularSection")
    if len(tss) > 0:
        if not check_uniqueness(tss, "TabularSection"):
            check8_ok = False

    # Dimensions
    dims = find_all(child_obj_node, "md:Dimension")
    if len(dims) > 0:
        if not check_uniqueness(dims, "Dimension"):
            check8_ok = False

    # Resources
    ress = find_all(child_obj_node, "md:Resource")
    if len(ress) > 0:
        if not check_uniqueness(ress, "Resource"):
            check8_ok = False

    # EnumValues
    evs = find_all(child_obj_node, "md:EnumValue")
    if len(evs) > 0:
        if not check_uniqueness(evs, "EnumValue"):
            check8_ok = False

    # Columns (DocumentJournal)
    cols = find_all(child_obj_node, "md:Column")
    if len(cols) > 0:
        if not check_uniqueness(cols, "Column"):
            check8_ok = False

    # URLTemplates (HTTPService)
    url_ts = find_all(child_obj_node, "md:URLTemplate")
    if len(url_ts) > 0:
        if not check_uniqueness(url_ts, "URLTemplate"):
            check8_ok = False

    # Operations (WebService)
    ops = find_all(child_obj_node, "md:Operation")
    if len(ops) > 0:
        if not check_uniqueness(ops, "Operation"):
            check8_ok = False

    if check8_ok:
        report_ok("8. Name uniqueness: all names unique")
else:
    report_ok("8. Name uniqueness: N/A")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 9: TabularSections -- internal structure ───────────

if child_obj_node is not None:
    ts_sections = find_all(child_obj_node, "md:TabularSection")
    if len(ts_sections) > 0:
        check9_ok = True
        ts_count = 0

        for ts in ts_sections:
            if stopped:
                break
            ts_count += 1

            # UUID
            ts_uuid = ts.get("uuid", "")
            if not ts_uuid or not guid_pattern.match(ts_uuid):
                report_error(f"9. TabularSection #{ts_count}: invalid or missing uuid")
                check9_ok = False

            # Name
            ts_props = find(ts, "md:Properties")
            ts_name_node = find(ts_props, "md:Name") if ts_props is not None else None
            ts_name = inner_text(ts_name_node) if ts_name_node is not None else "(unnamed)"

            if ts_name_node is None or not inner_text(ts_name_node):
                report_error(f"9. TabularSection #{ts_count}: missing or empty Name")
                check9_ok = False

            # InternalInfo with 2 GeneratedType
            ts_int_info = find(ts, "md:InternalInfo")
            if ts_int_info is not None:
                ts_gens = find_all(ts_int_info, "xr:GeneratedType")
                if len(ts_gens) < 2:
                    report_warn(f"9. TabularSection '{ts_name}': expected 2 GeneratedType, found {len(ts_gens)}")

            # Attributes inside TS
            ts_child_obj = find(ts, "md:ChildObjects")
            if ts_child_obj is not None:
                ts_attrs = find_all(ts_child_obj, "md:Attribute")
                ts_attr_names = {}
                for ta in ts_attrs:
                    ta_ok = check_child_element(ta, f"TabularSection '{ts_name}'.Attribute", True)
                    if not ta_ok:
                        check9_ok = False

                    # Check name uniqueness within TS
                    ta_props = find(ta, "md:Properties")
                    ta_name = find(ta_props, "md:Name") if ta_props is not None else None
                    if ta_name is not None and inner_text(ta_name):
                        if inner_text(ta_name) in ts_attr_names:
                            report_error(f"9. Duplicate attribute '{inner_text(ta_name)}' in TabularSection '{ts_name}'")
                            check9_ok = False
                        else:
                            ts_attr_names[inner_text(ta_name)] = True

                # StandardAttributes of TS: expect LineNumber
                if ts_props is not None:
                    ts_std_attr = find(ts_props, "md:StandardAttributes")
                    if ts_std_attr is not None:
                        ts_std_attrs = find_all(ts_std_attr, "xr:StandardAttribute")
                        has_line_number = False
                        for tsa in ts_std_attrs:
                            if tsa.get("name") == "LineNumber":
                                has_line_number = True
                        if not has_line_number:
                            report_warn(f"9. TabularSection '{ts_name}': missing LineNumber StandardAttribute")

        if check9_ok:
            report_ok(f"9. TabularSections: {ts_count} sections, structure valid")
    else:
        report_ok("9. TabularSections: none present")
else:
    report_ok("9. TabularSections: N/A")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 10: Cross-property consistency ─────────────────────

check10_ok = True
check10_issues = 0

if props_node is not None:
    # HierarchyType set but Hierarchical = false
    hierarchical = find(props_node, "md:Hierarchical")
    hierarchy_type = find(props_node, "md:HierarchyType")
    if (hierarchical is not None and hierarchy_type is not None and
            inner_text(hierarchical) == "false" and inner_text(hierarchy_type)):
        report_warn(f"10. HierarchyType='{inner_text(hierarchy_type)}' but Hierarchical=false")
        check10_issues += 1

    # CommonModule: no context enabled
    if md_type == "CommonModule":
        contexts = ("Server", "ClientManagedApplication", "ClientOrdinaryApplication",
                     "ExternalConnection", "ServerCall", "Global")
        any_enabled = False
        for ctx in contexts:
            ctx_node = find(props_node, f"md:{ctx}")
            if ctx_node is not None and inner_text(ctx_node) == "true":
                any_enabled = True
                break
        if not any_enabled:
            report_warn("10. CommonModule: no execution context enabled")
            check10_issues += 1

    # EventSubscription: empty Handler
    if md_type == "EventSubscription":
        handler = find(props_node, "md:Handler")
        if handler is None or not text_of(handler):
            report_error("10. EventSubscription: empty Handler")
            check10_ok = False
            check10_issues += 1

        # Empty Source
        source = find(props_node, "md:Source")
        has_source = False
        if source is not None:
            source_types = find_all(source, "v8:Type")
            if len(source_types) > 0:
                has_source = True
        if not has_source:
            report_warn("10. EventSubscription: no Source types specified")
            check10_issues += 1

    # ScheduledJob: empty MethodName
    if md_type == "ScheduledJob":
        method = find(props_node, "md:MethodName")
        if method is None or not text_of(method):
            report_error("10. ScheduledJob: empty MethodName")
            check10_ok = False
            check10_issues += 1

if check10_ok and check10_issues == 0:
    report_ok("10. Cross-property consistency")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 11: HTTPService/WebService nested structure ────────

if md_type == "HTTPService" and child_obj_node is not None:
    url_templates = find_all(child_obj_node, "md:URLTemplate")
    check11_ok = True
    method_count = 0

    valid_http_methods = ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "MERGE", "CONNECT")

    for ut in url_templates:
        if stopped:
            break

        ut_props = find(ut, "md:Properties")
        ut_name_node = find(ut_props, "md:Name") if ut_props is not None else None
        ut_name = inner_text(ut_name_node) if ut_name_node is not None else "(unnamed)"

        # Template property
        tpl = find(ut_props, "md:Template") if ut_props is not None else None
        if tpl is None or not text_of(tpl):
            report_error(f"11. HTTPService URLTemplate '{ut_name}': empty Template")
            check11_ok = False

        # Methods inside URLTemplate
        ut_child_obj = find(ut, "md:ChildObjects")
        if ut_child_obj is not None:
            methods = find_all(ut_child_obj, "md:Method")
            for m in methods:
                method_count += 1
                m_props = find(m, "md:Properties")
                if m_props is not None:
                    http_method = find(m_props, "md:HTTPMethod")
                    if http_method is not None and inner_text(http_method):
                        if inner_text(http_method) not in valid_http_methods:
                            report_error(f"11. HTTPService URLTemplate '{ut_name}': invalid HTTPMethod '{inner_text(http_method)}'")
                            check11_ok = False
                    else:
                        report_error(f"11. HTTPService URLTemplate '{ut_name}': Method missing HTTPMethod")
                        check11_ok = False

    if check11_ok:
        report_ok(f"11. HTTPService: {len(url_templates)} URLTemplate(s), {method_count} method(s)")

elif md_type == "WebService" and child_obj_node is not None:
    operations = find_all(child_obj_node, "md:Operation")
    check11_ok = True
    param_count = 0

    valid_directions = ("In", "Out", "InOut")

    for op in operations:
        if stopped:
            break

        op_props = find(op, "md:Properties")
        op_name_node = find(op_props, "md:Name") if op_props is not None else None
        op_name = inner_text(op_name_node) if op_name_node is not None else "(unnamed)"

        # ReturnType
        ret_type = find(op_props, "md:XDTOReturningValueType") if op_props is not None else None
        if ret_type is None or not text_of(ret_type):
            report_warn(f"11. WebService Operation '{op_name}': no XDTOReturningValueType")

        # Parameters inside Operation
        op_child_obj = find(op, "md:ChildObjects")
        if op_child_obj is not None:
            params = find_all(op_child_obj, "md:Parameter")
            for p in params:
                param_count += 1
                p_props = find(p, "md:Properties")
                if p_props is not None:
                    direction = find(p_props, "md:TransferDirection")
                    if direction is not None and inner_text(direction) and inner_text(direction) not in valid_directions:
                        report_error(f"11. WebService Operation '{op_name}': Parameter has invalid TransferDirection '{inner_text(direction)}'")
                        check11_ok = False

    if check11_ok:
        report_ok(f"11. WebService: {len(operations)} operation(s), {param_count} parameter(s)")
else:
    report_ok("11. HTTPService/WebService: N/A")

# ── Final output ──────────────────────────────────────────────

finalize()

if errors > 0:
    sys.exit(1)
sys.exit(0)
