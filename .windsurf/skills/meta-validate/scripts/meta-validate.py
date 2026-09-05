# meta-validate v1.24 — Validate 1C metadata object structure (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import re
import sys

from lxml import etree

# В batch скрипт выполняется повторно в том же процессе, и поток может оказаться подменённым
# (у StringIO нет reconfigure) — кодировка к этому моменту уже выставлена первым прогоном.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except AttributeError:
    pass

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.
def ci_parse_args(parser, argv=None):
    """parse_args по правилам PS: имена параметров и значения choices регистронезависимы."""
    argv = list(sys.argv[1:] if argv is None else argv)
    names = {s.lower(): s for a in parser._actions for s in a.option_strings}
    for i, tok in enumerate(argv):
        if tok.startswith('-') and tok.lower() in names:
            argv[i] = names[tok.lower()]
    # choices — зеркало [ValidateSet]; канонизируем ДО разбора, иначе argparse отвергнет регистр
    choice_map = {}
    for a in parser._actions:
        if a.choices:
            for s in a.option_strings:
                choice_map[s] = {str(c).lower(): c for c in a.choices}
    for i in range(len(argv) - 1):
        m = choice_map.get(argv[i])
        if m and argv[i + 1].lower() in m:
            argv[i + 1] = m[argv[i + 1].lower()]
    return parser.parse_args(argv)


# ── arg parsing ──────────────────────────────────────────────

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-ObjectPath", "-Path", required=True)
parser.add_argument("-Detailed", action="store_true")
parser.add_argument("-MaxErrors", type=int, default=30)
parser.add_argument("-OutFile", default="")
args = ci_parse_args(parser)

detailed = args.Detailed
max_errors = args.MaxErrors
out_file = args.OutFile

# ── batch mode: pipe-separated paths ─────────────────────────

path_list = [p.strip() for p in args.ObjectPath.split('|') if p.strip()]
if len(path_list) > 1:
    # Каждый объект проверяется этим же скриптом в СВЕЖЕМ globals() — так же, как PS-порт вызывает
    # себя через & (тот же процесс, новая область видимости). Отдельный процесс на объект стоил бы
    # старта интерпретатора с импортом lxml (~146 мс) при разборе в единицы миллисекунд; здесь и
    # старт, и компиляция файла платятся один раз на весь батч.
    batch_ok = 0
    batch_fail = 0
    with open(__file__, encoding="utf-8") as _f:
        _code = compile(_f.read(), __file__, "exec")
    _saved_argv = sys.argv
    for single_path in path_list:
        argv = ["meta-validate.py", "-ObjectPath", single_path, "-MaxErrors", str(max_errors)]
        if detailed:
            argv.append("-Detailed")
        if out_file:
            base, ext = os.path.splitext(out_file)
            obj_leaf = os.path.splitext(os.path.basename(single_path))[0]
            argv += ["-OutFile", f"{base}_{obj_leaf}{ext}"]
        sys.argv = argv
        rc = 0
        try:
            exec(_code, {"__name__": "__main__", "__file__": __file__})
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else 0
        except Exception as e:
            # Падение одного объекта не должно рвать батч — в варианте с отдельным процессом
            # это обеспечивалось изоляцией процессов.
            print(f"[ERROR] {single_path}: {type(e).__name__}: {e}")
            rc = 1
        finally:
            sys.argv = _saved_argv
        if rc == 0:
            batch_ok += 1
        else:
            batch_fail += 1
    print()
    print(f"=== Batch: {len(path_list)} objects, {batch_ok} passed, {batch_fail} failed ===")
    sys.exit(1 if batch_fail > 0 else 0)

object_path = path_list[0]

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

# File not found -- прощающий ввод для плоских объектов (SessionParameter, CommonAttribute,
# DefinedType, WSReference, ... -- один .xml без папки): дописать .xml к голому имени
if not os.path.exists(object_path) and not os.path.splitext(object_path)[1]:
    if os.path.exists(object_path + ".xml"):
        object_path = object_path + ".xml"

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

# ── detect config directory (for cross-object checks) ────────

config_dir = None
probe = os.path.dirname(resolved_path)
for _ in range(4):
    if not probe:
        break
    if os.path.exists(os.path.join(probe, "Configuration.xml")):
        config_dir = probe
        break
    probe = os.path.dirname(probe)

# ── output infrastructure ────────────────────────────────────

errors = 0
warnings = 0
ok_count = 0
stopped = False
output_lines = []


def out_line(msg):
    output_lines.append(msg)


def report_ok(msg):
    global ok_count
    ok_count += 1
    if detailed:
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
    checks = ok_count + errors + warnings
    if errors == 0 and warnings == 0 and not detailed:
        result = f"=== Validation OK: {md_type}.{obj_name} ({checks} checks) ==="
    else:
        out_line("")
        out_line(f"=== Result: {errors} errors, {warnings} warnings ({checks} checks) ===")
        result = "\n".join(output_lines)
    print(result)
    if out_file:
        with open(out_file, "w", encoding="utf-8-sig") as f:
            f.write(result)
        print(f"Written to: {out_file}")


# ── Format version ───────────────────────────────────────────
# Проверенный диапазон версий формата выгрузки: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница —
# docs/1c-configuration-spec.md, «Лестница версий». Версию задаёт платформа ВЫГРУЗКИ, а не режим
# совместимости конфигурации. Версии ниже 2.17 (платформы 8.3.23 и старше) существуют, но навыки
# на них не проверялись — это предупреждение о непокрытии, а не о некорректности файла.
FORMAT_VERIFIED_MIN = "2.17"
FORMAT_VERIFIED_MAX = "2.21"


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


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

# Валидные типы метаданных без глубоких правил валидации — раньше падали как "Unrecognized"
# (ложная ошибка на валидном объекте). Для них выполняется базовая структурная проверка (root/uuid/Name).
structural_only_types = (
    "Subsystem", "Role", "CommonForm", "CommonCommand", "CommandGroup", "CommonAttribute",
    "CommonTemplate", "CommonPicture", "SessionParameter", "SettingsStorage", "FilterCriterion",
    "IntegrationService", "Bot",
    "FunctionalOption", "FunctionalOptionsParameter", "Language", "Style", "StyleItem",
    "WSReference", "XDTOPackage", "DocumentNumerator", "Sequence",
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
    "AccountingRegister":         ["Active", "Period", "Recorder", "LineNumber", "Account", "PeriodAdjustment", "RecordType"],
    "CalculationRegister":        ["Active", "Recorder", "LineNumber", "RegistrationPeriod", "CalculationType", "ReversingEntry", "ActionPeriod", "BegOfActionPeriod", "EndOfActionPeriod", "BegOfBasePeriod", "EndOfBasePeriod"],
    "ChartOfAccounts":            ["PredefinedDataName", "Predefined", "Ref", "DeletionMark", "Description", "Code", "Parent", "Order", "Type", "OffBalance"],
    "ChartOfCharacteristicTypes": ["PredefinedDataName", "Predefined", "Ref", "DeletionMark", "Description", "Code", "Parent", "IsFolder", "ValueType"],
    "ChartOfCalculationTypes":    ["PredefinedDataName", "Predefined", "Ref", "DeletionMark", "Description", "Code", "ActionPeriodIsBasic"],
    "BusinessProcess":            ["Ref", "DeletionMark", "Date", "Number", "Started", "Completed", "HeadTask"],
    "Task":                       ["Ref", "DeletionMark", "Date", "Number", "Executed", "Description", "RoutePoint", "BusinessProcess"],
    "ExchangePlan":               ["Ref", "DeletionMark", "Code", "Description", "ThisNode", "SentNo", "ReceivedNo", "ExchangeDate"],
    "DocumentJournal":            ["Type", "Ref", "Date", "Posted", "DeletionMark", "Number"],
}

# Стандартные реквизиты, присутствие которых зависит от свойств объекта: у бухрегистра
# PeriodAdjustment — от длины периода корректировки, RecordType — от корреспонденции; у регистра
# накопления RecordType — от вида регистра. Их отсутствие законно, в «Missing» не попадают.
std_attr_conditional_names = {
    "AccountingRegister":   ("PeriodAdjustment", "RecordType"),
    "AccumulationRegister": ("RecordType",),
    # ExchangeDate — легаси-реквизит, объявлен лишь у части планов обмена: допустим, но не обязателен.
    "ExchangePlan":         ("ExchangeDate",),
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

# Группы командного интерфейса (зеркало meta-compile): раздела — без commandParameterType; формы — с параметром.
SECTION_COMMAND_GROUPS = ["NavigationPanelImportant", "NavigationPanelOrdinary", "NavigationPanelSeeAlso",
                          "ActionsPanelCreate", "ActionsPanelReports", "ActionsPanelTools"]
FORM_COMMAND_GROUPS = ["FormCommandBarImportant", "FormCommandBarCreateBasedOn",
                       "FormNavigationPanelImportant", "FormNavigationPanelGoTo", "FormNavigationPanelSeeAlso"]
VALID_COMMAND_GROUPS = SECTION_COMMAND_GROUPS + FORM_COMMAND_GROUPS

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
    "HierarchyType":                ["HierarchyFoldersAndItems", "HierarchyOfItems"],
    "EditType":                     ["InDialog", "InList", "BothWays"],
    "WriteMode":                    ["Independent", "RecorderSubordinate"],
    "InformationRegisterPeriodicity": ["Nonperiodical", "Second", "Day", "Month", "Quarter", "Year", "RecorderPosition"],
    "RegisterType":                 ["Balance", "Turnovers"],
    "ReturnValuesReuse":            ["DontUse", "DuringRequest", "DuringSession"],
    "ReuseSessions":                ["DontUse", "Use", "AutoUse"],
    "FillChecking":                 ["DontCheck", "ShowError", "ShowWarning"],
    "Indexing":                     ["DontIndex", "Index", "IndexWithAdditionalOrder"],
    "DataHistory":                  ["Use", "DontUse"],
    "DependenceOnCalculationTypes": ["DontUse", "OnActionPeriod"],
}

# Properties forbidden per type (would cause LoadConfigFromFiles error)
forbidden_properties = {
    "ChartOfCharacteristicTypes": ["CodeType"],
    "ChartOfAccounts":            ["Autonumbering", "Hierarchical"],
    "ChartOfCalculationTypes":    ["CheckUnique", "Autonumbering"],
    "ExchangePlan":               ["CodeType", "CheckUnique", "Autonumbering"],
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
version_rank = format_rank(version)
if not version:
    report_warn("1. Missing version attribute on MetaDataObject")
elif version_rank == 0:
    report_error(f"1. Malformed version '{version}' (expected N.N)")
elif version_rank < format_rank(FORMAT_VERIFIED_MIN):
    report_warn(f"1. Format version '{version}' is below the tested range "
                f"{FORMAT_VERIFIED_MIN}-{FORMAT_VERIFIED_MAX} — skills were not verified on it")
elif version_rank > format_rank(FORMAT_VERIFIED_MAX):
    report_warn(f"1. Format version '{version}' is above the tested range "
                f"{FORMAT_VERIFIED_MIN}-{FORMAT_VERIFIED_MAX} — skills were not verified on it")

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

if md_type not in valid_types and md_type not in structural_only_types:
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

# ── Structural-only types: базовая проверка (Name), без type-specific правил ──
if md_type in structural_only_types:
    if obj_name == "(unknown)":
        report_error("3. Properties: missing or empty Name")
    elif not ident_pattern.match(obj_name):
        report_error(f"3. Properties: Name '{obj_name}' is not a valid 1C identifier")
    else:
        report_ok(f'3. Properties: Name="{obj_name}" (базовая структурная проверка для {md_type})')
    finalize()
    sys.exit(1 if errors > 0 else 0)

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

    # Корневой <Type> (дескриптор типа значения — Константа, ПВХ) должен быть структурным:
    # <v8:Type>/<v8:TypeSet>, а не скалярный текст. Скаляр = повреждённый тип (напр. после
    # старого meta-edit modify-property Type). См. issue #42.
    root_type_el = find(props_node, "md:Type")
    if root_type_el is not None:
        scalar_text = inner_text(root_type_el).strip()
        v8_types = find_all(root_type_el, "v8:Type")
        v8_type_sets = find_all(root_type_el, "v8:TypeSet")
        if len(v8_types) == 0 and len(v8_type_sets) == 0 and scalar_text:
            report_error(f"4. Property <Type> содержит скалярный текст '{scalar_text}' без структуры типа (<v8:Type>/<v8:TypeSet>) — повреждённый дескриптор типа значения")
            check4_ok = False

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
                    # AccountingRegister: пары субконто, число которых задаётся планом счетов
                    is_dynamic = (md_type == "AccountingRegister" and
                                  (re.match(r'^ExtDimension\d+$', sa_name) or
                                   re.match(r'^ExtDimensionType\d+$', sa_name)))
                    if not is_dynamic:
                        report_warn(f"5. Unexpected StandardAttribute '{sa_name}' for {md_type}")
            else:
                report_error("5. StandardAttribute without 'name' attribute")
                check5_ok = False

        if expected_std_attrs:
            cond_names = std_attr_conditional_names.get(md_type, ())
            missing_attrs = [a for a in expected_std_attrs if a not in found_names and a not in cond_names]
            if missing_attrs:
                report_warn(f"5. Missing StandardAttributes: {', '.join(missing_attrs)}")

        if check5_ok:
            report_ok(f"5. StandardAttributes: {len(std_attrs)} entries")

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
        # Пустой <Type/> — это тип «Произвольный», штатная конструкция: в типовых так описаны
        # служебные реквизиты обработок, платформа принимает и сохраняет её без изменений
        # (проверено round-trip). Ошибкой здесь был бы отказ там, где платформа не отказывает.
        if type_el is None:
            # Блока Type нет вовсе: загрузка проходит, но платформа молча подставляет тип нового
            # реквизита — Строка(10). Загрузку это не рвёт, а замысел теряет, отсюда WARN.
            report_warn(f"7. {kind} '{name_val}' — блок Type не задан; при загрузке платформа подставит Строка(10)")

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

if stopped:
    finalize()
    sys.exit(1)

# ── Check 7b: Reserved attribute names (типозависимо: стандартные ДАННОГО типа, EN+RU) ───────
# Совпадение имени собственного реквизита со стандартным (англ. или рус.) платформа не примет → ошибка.

RESERVED_EN_RU = {
    'Ref': 'Ссылка', 'DeletionMark': 'ПометкаУдаления', 'Code': 'Код', 'Description': 'Наименование',
    'Date': 'Дата', 'Number': 'Номер', 'Posted': 'Проведен', 'Parent': 'Родитель', 'Owner': 'Владелец',
    'IsFolder': 'ЭтоГруппа', 'Predefined': 'Предопределенный', 'PredefinedDataName': 'ИмяПредопределенныхДанных',
    'Recorder': 'Регистратор', 'Period': 'Период', 'LineNumber': 'НомерСтроки', 'Active': 'Активность',
    'Order': 'Порядок', 'Type': 'Тип', 'OffBalance': 'Забалансовый', 'RecordType': 'ВидДвижения',
    'Started': 'Стартован', 'Completed': 'Завершен', 'HeadTask': 'ВедущаяЗадача',
    'Executed': 'Выполнена', 'RoutePoint': 'ТочкаМаршрута', 'BusinessProcess': 'БизнесПроцесс',
    'ThisNode': 'ЭтотУзел', 'SentNo': 'НомерОтправленного', 'ReceivedNo': 'НомерПринятого',
    'CalculationType': 'ВидРасчета', 'RegistrationPeriod': 'ПериодРегистрации', 'ReversingEntry': 'СторноЗапись',
    'Account': 'Счет', 'ValueType': 'ТипЗначения', 'ActionPeriodIsBasic': 'ПериодДействияБазовый',
}

std_for_type = standard_attributes_by_type.get(md_type)
if child_obj_node is not None and std_for_type:
    reserved_set = set()
    for en in std_for_type:
        reserved_set.add(en.lower())
        ru = RESERVED_EN_RU.get(en)
        if ru:
            reserved_set.add(ru.lower())
    check7b_ok = True
    for attr_node in find_all(child_obj_node, 'md:Attribute'):
        attr_props = find(attr_node, 'md:Properties')
        if attr_props is not None:
            attr_name_node = find(attr_props, 'md:Name')
            if attr_name_node is not None and inner_text(attr_name_node):
                an = inner_text(attr_name_node)
                if an.lower() in reserved_set:
                    report_error(f"7b. Attribute '{an}' conflicts with a standard attribute of {md_type}")
                    check7b_ok = False
    if check7b_ok:
        report_ok("7b. Reserved attribute names: no conflicts")
elif child_obj_node is not None:
    report_ok(f"7b. Reserved attribute names: no conflicts (no standard set for {md_type})")

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
    # HierarchyType платформа пишет всегда, независимо от Hierarchical, и при выключенной иерархии
    # просто его игнорирует (проверено: значение переживает round-trip). Дефолтное значение поэтому
    # ни о чём не говорит — предупреждаем только о явно заданном другом типе иерархии: это похоже
    # на "тип иерархии выбрали, а саму иерархию включить забыли".
    if (hierarchical is not None and hierarchy_type is not None and
            inner_text(hierarchical) == "false" and inner_text(hierarchy_type)
            and inner_text(hierarchy_type) != "HierarchyFoldersAndItems"):
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
        # Источник задают и наборами типов (<v8:TypeSet>cfg:CatalogObject</v8:TypeSet>) — в типовых
        # так описана каждая четвёртая подписка. Реально пустой источник платформа отвергает:
        # «ПодпискаНаСобытие.X - Источник событий должен быть задан», поэтому это ошибка.
        has_source = False
        if source is not None:
            source_types = find_all(source, "v8:Type")
            source_type_sets = find_all(source, "v8:TypeSet")
            if len(source_types) > 0 or len(source_type_sets) > 0:
                has_source = True
        if not has_source:
            report_error("10. EventSubscription: источник событий не задан — платформа отвергнет загрузку")
            check10_issues += 1

    # ScheduledJob: empty MethodName
    if md_type == "ScheduledJob":
        method = find(props_node, "md:MethodName")
        if method is None or not text_of(method):
            report_error("10. ScheduledJob: empty MethodName")
            check10_ok = False
            check10_issues += 1

    # AccountingRegister: ChartOfAccounts must not be empty
    if md_type == 'AccountingRegister':
        coa = find(props_node, 'md:ChartOfAccounts')
        if coa is None or not text_of(coa):
            report_error('10. AccountingRegister: empty ChartOfAccounts')
            check10_ok = False
            check10_issues += 1
            print('[HINT] /meta-edit -Operation modify-property -Value "ChartOfAccounts=ChartOfAccounts.XXX"')

    # CalculationRegister: ChartOfCalculationTypes must not be empty
    if md_type == 'CalculationRegister':
        coct = find(props_node, 'md:ChartOfCalculationTypes')
        if coct is None or not text_of(coct):
            report_error('10. CalculationRegister: empty ChartOfCalculationTypes')
            check10_ok = False
            check10_issues += 1
            print('[HINT] /meta-edit -Operation modify-property -Value "ChartOfCalculationTypes=ChartOfCalculationTypes.XXX"')

    # BusinessProcess: Task should not be empty
    if md_type == 'BusinessProcess':
        task_prop = find(props_node, 'md:Task')
        if task_prop is None or not text_of(task_prop):
            report_warn('10. BusinessProcess: empty Task reference')
            check10_issues += 1
            print('[HINT] /meta-edit -Operation modify-property -Value "Task=Task.XXX"')

    # CalculationRegister: ActionPeriod=true requires non-empty Schedule
    if md_type == 'CalculationRegister':
        action_period = find(props_node, 'md:ActionPeriod')
        if action_period is not None and text_of(action_period) == 'true':
            schedule = find(props_node, 'md:Schedule')
            if schedule is None or not text_of(schedule):
                report_warn('10. CalculationRegister: ActionPeriod=true but Schedule is empty — platform requires a schedule register')
                check10_issues += 1

    # DocumentJournal: RegisteredDocuments should not be empty
    if md_type == 'DocumentJournal':
        reg_docs = find(props_node, 'md:RegisteredDocuments')
        # Регистрируемые документы платформа перечисляет как <xr:Item xsi:type="xr:MDObjectRef">,
        # так же их пишет meta-compile; форма с <v8:Type> сохранена на случай иных выгрузок.
        # Пустой состав платформа отвергает: «Для журнала не заданы регистрируемые документы».
        has_reg_docs = False
        if reg_docs is not None:
            items = find_all(reg_docs, 'v8:Type')
            ref_items = find_all(reg_docs, 'xr:Item')
            if len(items) > 0 or len(ref_items) > 0:
                has_reg_docs = True
        if not has_reg_docs:
            report_error('10. DocumentJournal: регистрируемые документы не заданы — платформа отвергнет загрузку')
            check10_issues += 1

    # ChartOfAccounts: ExtDimensionTypes should be set if MaxExtDimensionCount > 0
    if md_type == 'ChartOfAccounts':
        max_ext_dim = find(props_node, 'md:MaxExtDimensionCount')
        if max_ext_dim is not None:
            try:
                med_val = int(inner_text(max_ext_dim) or '0')
            except ValueError:
                med_val = 0
            if med_val > 0:
                edt = find(props_node, 'md:ExtDimensionTypes')
                if edt is None or not text_of(edt):
                    report_warn('10. ChartOfAccounts: MaxExtDimensionCount>0 but ExtDimensionTypes is empty')
                    check10_issues += 1
                    print('[HINT] /meta-edit -Operation modify-property -Value "ExtDimensionTypes=ChartOfCharacteristicTypes.XXX"')

    # Register: must have at least one Dimension or Resource (platform rejects empty registers)
    reg_types_all = ('AccumulationRegister', 'AccountingRegister', 'CalculationRegister', 'InformationRegister')
    if md_type in reg_types_all and child_obj_node is not None:
        dims = len(find_all(child_obj_node, 'md:Dimension'))
        ress = len(find_all(child_obj_node, 'md:Resource'))
        attrs = len(find_all(child_obj_node, 'md:Attribute'))
        if dims + ress + attrs == 0:
            report_warn(f"10. {md_type}: no Dimensions, Resources, or Attributes \u2014 platform will reject")
            check10_issues += 1

    # Document: RegisterRecords references should point to existing objects in config
    if md_type == 'Document' and config_dir:
        reg_records = find(props_node, 'md:RegisterRecords')
        if reg_records is not None:
            rr_items = find_all(reg_records, 'xr:Item')
            for item in rr_items:
                ref_val = (inner_text(item) or '').strip()
                if not ref_val:
                    continue
                # Parse "AccumulationRegister.Name" -> dir AccumulationRegisters/Name
                parts = ref_val.split('.', 1)
                if len(parts) == 2:
                    ref_type, ref_name = parts
                    dir_map = {
                        'AccumulationRegister': 'AccumulationRegisters',
                        'InformationRegister': 'InformationRegisters',
                        'AccountingRegister': 'AccountingRegisters',
                        'CalculationRegister': 'CalculationRegisters',
                    }
                    ref_dir = dir_map.get(ref_type)
                    if ref_dir:
                        ref_path = os.path.join(config_dir, ref_dir, ref_name)
                        ref_xml = os.path.join(config_dir, ref_dir, ref_name + '.xml')
                        if not os.path.exists(ref_path) and not os.path.exists(ref_xml):
                            report_warn(f"10. Document.RegisterRecords references '{ref_val}' but object not found in config")
                            check10_issues += 1

    # Register: must have at least one registrar document
    register_types = ('AccumulationRegister', 'AccountingRegister', 'CalculationRegister', 'InformationRegister')
    if md_type in register_types and config_dir and obj_name != '(unknown)':
        needs_registrar = True
        # InformationRegister with WriteMode=Independent does not need a registrar
        if md_type == 'InformationRegister':
            write_mode = find(props_node, 'md:WriteMode')
            if write_mode is None or inner_text(write_mode) != 'RecorderSubordinate':
                needs_registrar = False
        if needs_registrar:
            reg_ref = f'{md_type}.{obj_name}'
            docs_dir = os.path.join(config_dir, 'Documents')
            has_registrar = False
            if os.path.isdir(docs_dir):
                for fname in os.listdir(docs_dir):
                    if not fname.endswith('.xml'):
                        continue
                    fpath = os.path.join(docs_dir, fname)
                    if not os.path.isfile(fpath):
                        continue
                    with open(fpath, 'r', encoding='utf-8-sig') as f:
                        content = f.read()
                    if reg_ref in content:
                        has_registrar = True
                        break
            if not has_registrar:
                report_warn(f"10. {md_type}: no registrar document found (none references '{reg_ref}' in RegisterRecords)")
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

if stopped:
    finalize()
    sys.exit(1)

# ── Check 12: Forbidden properties per type ──────────────────

if props_node is not None and md_type in forbidden_properties:
    forbidden = forbidden_properties[md_type]
    check12_ok = True
    for fp in forbidden:
        fp_node = find(props_node, f"md:{fp}")
        if fp_node is not None:
            report_error(f"12. Forbidden property '{fp}' present in {md_type} (will fail on LoadConfigFromFiles)")
            check12_ok = False
    if check12_ok:
        report_ok("12. Forbidden properties: none found")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 13: Method reference validation ─────────────────────

if props_node is not None and md_type in ("EventSubscription", "ScheduledJob") and config_dir:
    check13_ok = True
    method_ref = None
    prop_label = None

    if md_type == "EventSubscription":
        h_node = find(props_node, "md:Handler")
        if h_node is not None:
            method_ref = text_of(h_node)
        prop_label = "Handler"
    elif md_type == "ScheduledJob":
        m_node = find(props_node, "md:MethodName")
        if m_node is not None:
            method_ref = text_of(m_node)
        prop_label = "MethodName"

    if method_ref:
        parts = method_ref.split(".")
        # Format: CommonModule.ModuleName.ProcedureName (3 parts) or ModuleName.ProcedureName (2 parts, legacy)
        if len(parts) == 3 and parts[0] == "CommonModule":
            cm_name = parts[1]
            proc_name = parts[2]
        elif len(parts) == 2:
            cm_name = parts[0]
            proc_name = parts[1]
        else:
            report_error(f"13. {md_type}.{prop_label} = '{method_ref}': expected format 'CommonModule.ModuleName.ProcedureName'")
            check13_ok = False
            cm_name = None
            proc_name = None
        if cm_name:
            cm_xml = os.path.join(config_dir, "CommonModules", f"{cm_name}.xml")
            if not os.path.exists(cm_xml):
                report_error(f"13. {md_type}.{prop_label}: CommonModule '{cm_name}' not found (expected {cm_xml})")
                check13_ok = False
            else:
                # Check BSL file for exported procedure
                bsl_path = os.path.join(config_dir, "CommonModules", cm_name, "Ext", "Module.bsl")
                if os.path.exists(bsl_path):
                    with open(bsl_path, "r", encoding="utf-8-sig") as f:
                        bsl_content = f.read()
                    # Список параметров переносится на следующие строки, и Экспорт оказывается не на
                    # строке с именем — в типовых так объявлена каждая обработчик-процедура с длинной
                    # сигнатурой. Отсюда (?s) для содержимого скобок и \s (а не пробел) перед Экспорт.
                    export_pattern = rf"(?smi)^[ 	]*(Procedure|Function|Процедура|Функция)[ 	]+{re.escape(proc_name)}[ 	]*\([^)]*\)\s+(Export|Экспорт)"
                    if not re.search(export_pattern, bsl_content):
                        report_warn(f"13. {md_type}.{prop_label}: procedure '{proc_name}' not found as exported in CommonModule '{cm_name}'")
                        check13_ok = False
                elif os.path.exists(os.path.splitext(bsl_path)[0] + ".bin"):
                    # Модуль поставщика выгружен в двоичном виде (Module.bin) — текста нет by design,
                    # проверять нечего. Предупреждать здесь значило бы шуметь о норме.
                    pass
                else:
                    report_warn(f"13. {md_type}.{prop_label}: BSL file not found ({bsl_path}), cannot verify procedure")

    if check13_ok:
        report_ok(f"13. Method reference: {prop_label} = '{method_ref}'")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 14: DocumentJournal Column content ──────────────────

if md_type == "DocumentJournal" and child_obj_node is not None:
    columns = find_all(child_obj_node, "md:Column")
    check14_ok = True
    col_count = 0
    empty_ref_count = 0

    for col in columns:
        col_count += 1
        col_props = find(col, "md:Properties")
        col_name_node = find(col_props, "md:Name") if col_props is not None else None
        col_name = inner_text(col_name_node) if col_name_node is not None else "(unnamed)"

        refs = find(col_props, "md:References") if col_props is not None else None
        has_items = False
        if refs is not None:
            items = find_all(refs, "xr:Item")
            if len(items) > 0:
                has_items = True
        if not has_items:
            report_error(f"14. DocumentJournal Column '{col_name}': empty References (will fail on LoadConfigFromFiles)")
            check14_ok = False
            empty_ref_count += 1

    if check14_ok and col_count > 0:
        report_ok(f"14. DocumentJournal Columns: {col_count} column(s), all have References")
    elif col_count == 0:
        report_ok("14. DocumentJournal Columns: none")

if stopped:
    finalize()
    sys.exit(1)

# ── Check 15: Commands — Group обязателен/валиден; секц.группа несовместима с CommandParameterType ──

if child_obj_node is not None:
    commands = find_all(child_obj_node, "md:Command")
    check15_ok = True
    cmd_count = 0
    for cmd in commands:
        if stopped:
            break
        cmd_count += 1
        cuuid = cmd.get("uuid", "")
        cmd_props = find(cmd, "md:Properties")
        cmd_name_node = find(cmd_props, "md:Name") if cmd_props is not None else None
        cmd_name = inner_text(cmd_name_node) if (cmd_name_node is not None and inner_text(cmd_name_node)) else "(unnamed)"
        if not cuuid or not guid_pattern.match(cuuid):
            report_error(f"15. Command '{cmd_name}': missing or invalid uuid")
            check15_ok = False
        if cmd_name == "(unnamed)":
            report_error(f"15. Command (uuid={cuuid}): missing or empty Name")
            check15_ok = False
        group_node = find(cmd_props, "md:Group") if cmd_props is not None else None
        group_val = inner_text(group_node).strip() if group_node is not None else ""
        if not group_val:
            report_error(f"15. Command '{cmd_name}': не задана группа (Group) — 1С отвергает при загрузке")
            check15_ok = False
        elif group_val not in VALID_COMMAND_GROUPS and not group_val.startswith("CommandGroup."):
            report_error(f"15. Command '{cmd_name}': неизвестная группа '{group_val}'. "
                         f"Валидные: {', '.join(VALID_COMMAND_GROUPS)}; либо CommandGroup.<Имя>")
            check15_ok = False
        elif group_val in SECTION_COMMAND_GROUPS:
            cpt_node = find(cmd_props, "md:CommandParameterType") if cmd_props is not None else None
            has_cpt = cpt_node is not None and (len(find_all(cpt_node, "v8:Type")) > 0 or len(find_all(cpt_node, "v8:TypeSet")) > 0)
            if has_cpt:
                report_error(f"15. Command '{cmd_name}': тип параметра (CommandParameterType) недоступен "
                             f"для команд командного интерфейса раздела ('{group_val}')")
                check15_ok = False
    if check15_ok and cmd_count > 0:
        report_ok(f"15. Commands: {cmd_count} command(s), groups valid")

# ── Состав конфигурации (ChildObjects из Configuration.xml) ──
# Платформа судит о существовании объекта по СОСТАВУ, а не по наличию файла. Файла может не быть
# в частичной выгрузке: такой фрагмент грузится через /LoadConfigFromFiles -listFile слиянием с базой,
# и ссылка на невыгруженный объект остаётся рабочей. Отсюда два разных исхода:
#   нет в составе        -> платформа отвергнет загрузку всегда -> ERROR
#   в составе, файла нет -> полная загрузка упадёт, частичная пройдёт -> WARN
# ChildObjects конфигурации — плоский список <Вид>Имя</Вид>, поэтому ищем подстроку в границах секции
# без копирования и без разбора XML. Кэш живёт только в пределах одного объекта: в batch-режиме
# каждый следующий разбирается заново (в py — новый процесс, в PS — новая область видимости скрипта),
# так что полная карта (~100 мс) оплачивалась бы каждым объектом.

_cfg_text = None
_cfg_child_lower = None
_cfg_child_start = -1
_cfg_child_end = -1
_cfg_text_loaded = False


def _init_config_text():
    global _cfg_text, _cfg_child_start, _cfg_child_end, _cfg_text_loaded
    if _cfg_text_loaded:
        return
    _cfg_text_loaded = True
    if not config_dir:
        return
    cfg_path = os.path.join(config_dir, "Configuration.xml")
    if not os.path.exists(cfg_path):
        return
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            _cfg_text = f.read()
    except Exception:
        _cfg_text = None
        return
    s = _cfg_text.find("<ChildObjects>")
    e = _cfg_text.rfind("</ChildObjects>")
    if s >= 0 and e > s:
        _cfg_child_start = s
        _cfg_child_end = e


def config_is_extension():
    _init_config_text()
    return bool(_cfg_text) and "ConfigurationExtensionPurpose" in _cfg_text


def in_config_composition(kind, name):
    """True — объект есть в составе; False — нет; None — состав неизвестен
    (нет Configuration.xml или в нём нет ChildObjects), тогда вызывающий оставляет мягкий уровень."""
    global _cfg_child_lower
    _init_config_text()
    if _cfg_child_start < 0:
        return None
    needle = "<{0}>{1}</{0}>".format(kind, name)
    if _cfg_text.find(needle, _cfg_child_start, _cfg_child_end) >= 0:
        return True
    # Промах по точному совпадению — сверяем без учёта регистра, как это делает платформа.
    # Порядок именно такой: точный поиск на порядок дешевле, а промахи редки. Нижний регистр
    # берём от СРЕЗА и проверяем факт вхождения: смещения в lower() совпадать с оригиналом не обязаны.
    if _cfg_child_lower is None:
        _cfg_child_lower = _cfg_text[_cfg_child_start:_cfg_child_end].lower()
    return needle.lower() in _cfg_child_lower


# ── Check 16: Reference type existence — типы вида CatalogRef.X должны разрешаться в объекты конфигурации ──
# Уровень выбирается по составу конфигурации: типа нет в ChildObjects — «Неизвестное имя типа» при
# загрузке (ERROR); объект в составе есть, а файла в выгрузке нет — частичная выгрузка (WARN).
# Расширения (CFE) пропускаем — их типы ссылаются на объекты базовой конфигурации, которых в выгрузке
# расширения нет.

if config_dir:
    is_extension = config_is_extension()
    if not is_extension:
        ref_dir_map = {
            "CatalogRef": "Catalogs", "DocumentRef": "Documents", "EnumRef": "Enums",
            "ChartOfAccountsRef": "ChartsOfAccounts", "ChartOfCharacteristicTypesRef": "ChartsOfCharacteristicTypes",
            "ChartOfCalculationTypesRef": "ChartsOfCalculationTypes", "BusinessProcessRef": "BusinessProcesses",
            "ExchangePlanRef": "ExchangePlans", "TaskRef": "Tasks", "DefinedType": "DefinedTypes",
        }
        checked_refs = {}   # ref_key -> найден ли; для условия OK
        missing_refs = {}   # ref_key -> ref_dir; объект есть в составе, файла в выгрузке нет
        absent_refs = {}    # ref_key -> ref_dir; объекта нет в составе конфигурации
        unknown_refs = {}   # ref_key -> ref_dir; состав неизвестен (Configuration.xml без ChildObjects)
        for tn in find_all(root, ".//v8:Type"):
            tv = inner_text(tn).strip()
            if not tv:
                continue
            colon_idx = tv.find(":")
            if colon_idx >= 0:
                tv = tv[colon_idx + 1:]
            dot_idx = tv.find(".")
            if dot_idx < 0:
                continue
            ref_cat = tv[:dot_idx]
            ref_name = tv[dot_idx + 1:]
            ref_dir = ref_dir_map.get(ref_cat)
            if not ref_dir or not ref_name:
                continue
            ref_key = f"{ref_cat}.{ref_name}"
            if ref_key in checked_refs:
                continue
            ref_folder = os.path.join(config_dir, ref_dir, ref_name)
            ref_file = os.path.join(config_dir, ref_dir, ref_name + ".xml")
            if os.path.exists(ref_folder) or os.path.exists(ref_file):
                checked_refs[ref_key] = True
            else:
                checked_refs[ref_key] = False
                # Вид метаданных в ChildObjects — это тип без суффикса Ref (CatalogRef -> Catalog);
                # DefinedType суффикса не имеет и пишется в состав как есть.
                ref_kind_tag = ref_cat[:-3] if ref_cat.endswith("Ref") else ref_cat
                in_composition = in_config_composition(ref_kind_tag, ref_name)
                if in_composition is False:
                    absent_refs[ref_key] = ref_dir
                elif in_composition is True:
                    missing_refs[ref_key] = ref_dir
                else:
                    unknown_refs[ref_key] = ref_dir
        for ak in sorted(absent_refs):
            report_error(f"16. Ссылочный тип '{ak}' — объекта нет в составе конфигурации ({absent_refs[ak]}/) — «Неизвестное имя типа» при загрузке")
        for mk in sorted(missing_refs):
            report_warn(f"16. Ссылочный тип '{mk}' — объект есть в составе конфигурации, файла объекта в выгрузке нет ({missing_refs[mk]}/)")
        for uk in sorted(unknown_refs):
            report_warn(f"16. Ссылочный тип '{uk}' не найден в конфигурации ({unknown_refs[uk]}/)")
        if not absent_refs and not missing_refs and not unknown_refs and checked_refs:
            report_ok(f"16. Reference types: {len(checked_refs)} resolved")

# ── Check 18: свойства, появившиеся в новых версиях формата ──
# Реестр «тег → минимальная версия формата». Служит двум целям: (1) поймать свойство в файле со
# слишком старым штампом — при сборке на старой платформе оно будет молча отброшено (платформа
# рапортует успех, а свойство теряется); (2) подсказать, что конструкция требует более нового
# формата. Расширяется одной строкой на свойство — задел под 2.21 (8.5) и последующие.
versioned_props = {
    "TypeReductionMode": "2.18",   # режим приведения типов (стандартные реквизиты, измерения РС)
    "LineNumberLength": "2.20",    # длина номера строки ТЧ (5..9)
    # 2.21 (8.5): подтверждено синтетикой — одни исходники, выгрузка с 8.3.27 и с 8.5.1.
    "Color": "2.21",                            # цвет значения перечисления
    "AuxiliaryVariantForm": "2.21",             # вспомогательная форма варианта отчёта
    "UseInInterfaceCompatibilityMode": "2.21",  # использование общей формы в режиме совместимости интерфейса
}

file_rank = version_rank
if file_rank > 0:
    for vp in sorted(versioned_props):
        nodes = find_all(root, f"//md:{vp} | //xr:{vp}")
        if nodes and file_rank < format_rank(versioned_props[vp]):
            report_error(f"18. <{vp}> появился в формате {versioned_props[vp]}, а файл объявлен как {version} — на платформе этой версии свойство будет отброшено при загрузке")

# ── Check 19: LineNumberLength — допустимый диапазон 5..9 ──
# Длина номера строки ТЧ: 5 (до 99 999 строк) … 9 (до 999 999 999). Границы — из документации 1С.
for lnl in find_all(root, "//md:LineNumberLength"):
    raw = inner_text(lnl).strip()
    if not re.match(r'^\d+$', raw):
        report_error(f"19. LineNumberLength='{raw}' — должно быть целое число 5..9")
    elif int(raw) < 5 or int(raw) > 9:
        report_error(f"19. LineNumberLength={raw} вне допустимого диапазона 5..9")

# ── Check 17: MDObjectRef form — ссылка на ОБЪЕКТ метаданных, а не на тип ссылки ──
# Owners/BasedOn/RegisterRecords/RegisteredDocuments/References содержат путь вида "Catalog.Валюты".
# "CatalogRef.Валюты" — частая ошибка (тип ссылки вместо объекта): платформа отвечает
# «Неизвестный объект метаданных». Вида метаданных, оканчивающегося на Ref, не существует → ERROR.
# Неизвестный первый сегмент без Ref — только WARN (список видов может быть неполон).

md_ref_nodes = find_all(root, "//*[@xsi:type='xr:MDObjectRef']")
if md_ref_nodes:
    known_roots = tuple(valid_types) + tuple(structural_only_types)
    bad_ref_form = {}    # значение -> True (ссылочная форма, гарантированно нерабочая)
    unknown_root = {}    # значение -> корень
    for rn in md_ref_nodes:
        rv = inner_text(rn).strip()
        if not rv:
            continue
        rroot = rv.split('.')[0]
        if rroot in known_roots:
            continue
        if rroot.endswith('Ref'):
            bad_ref_form[rv] = True
        else:
            unknown_root[rv] = rroot
    for bk in sorted(bad_ref_form):
        fixed = re.sub(r'^([A-Za-z]+)Ref\.', r'\1.', bk)
        report_error(f"17. MDObjectRef '{bk}' — ссылка на ТИП, а не на объект метаданных; нужно '{fixed}' (иначе «Неизвестный объект метаданных» при загрузке)")
    for uk in sorted(unknown_root):
        report_warn(f"17. MDObjectRef '{uk}' — неизвестный вид метаданных '{unknown_root[uk]}' (опечатка?)")
    if not bad_ref_form and not unknown_root:
        report_ok(f"17. MDObjectRef form: {len(md_ref_nodes)} checked")

# ── Check 20: Default*Form / Auxiliary*Form / ChoiceForm — ссылка на существующую форму ──
# Платформа отвергает загрузку: «Неизвестный объект метаданных - Catalog.Товары.Form.НетТакойФормы».
# Две формы записи: "CommonForm.Имя" и "<Вид>.<Объект>.Form.<Форма>", причём объект может быть чужим
# (DefaultChoiceForm документа указывает на форму журнала документов). Для СВОЕГО объекта проверяем
# регистрацию формы в ChildObjects — работает и на одиночном файле; для чужого и общей формы нужна
# конфигурация. Заимствованные объекты расширения (ObjectBelonging=Adopted) пропускаем: их формы
# живут в основной конфигурации, в выгрузке расширения их нет.
#
# Уровень везде выбирается по составу, а не по наличию файла (см. in_config_composition):
# нет в ChildObjects — платформа откажет и при полной, и при частичной загрузке (ERROR);
# в составе есть, а файла в выгрузке нет — это фрагмент частичной выгрузки, и загрузится он или нет,
# зависит от состояния конфигурации БД, которого валидатору не видно (WARN).

form_owner_dir_map = {
    "Catalog": "Catalogs", "Document": "Documents", "DocumentJournal": "DocumentJournals",
    "Enum": "Enums", "Report": "Reports", "DataProcessor": "DataProcessors",
    "InformationRegister": "InformationRegisters", "AccumulationRegister": "AccumulationRegisters",
    "AccountingRegister": "AccountingRegisters", "CalculationRegister": "CalculationRegisters",
    "ChartOfAccounts": "ChartsOfAccounts", "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes", "BusinessProcess": "BusinessProcesses",
    "Task": "Tasks", "ExchangePlan": "ExchangePlans", "SettingsStorage": "SettingsStorages",
    "FilterCriterion": "FilterCriteria", "ExternalDataSource": "ExternalDataSources",
}

_belonging_node = find(type_node, "md:Properties/md:ObjectBelonging")
is_adopted = _belonging_node is not None and inner_text(_belonging_node).strip() == "Adopted"

GUID_RE_20 = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
TAG_RE_20 = re.compile(r'^(Default|Auxiliary)[A-Za-z]*Form$')


def _form_file_exists_20(base_dir, form_name):
    forms_dir = os.path.join(base_dir, "Forms")
    return (os.path.exists(os.path.join(forms_dir, form_name + ".xml"))
            or os.path.exists(os.path.join(forms_dir, form_name, "Form.xml"))
            or os.path.exists(os.path.join(forms_dir, form_name, "Ext", "Form.xml")))


if not is_adopted:
    is_extension_20 = config_is_extension()

    # формы своего объекта: имена из ChildObjects (сравнение регистронезависимое — как у платформы)
    own_forms = {}
    if child_obj_node is not None:
        for child in child_obj_node:
            if isinstance(child.tag, str) and local_name(child) == "Form":
                fn = inner_text(child).strip()
                if fn:
                    own_forms[fn.lower()] = fn
    own_dir = os.path.join(os.path.dirname(resolved_path), obj_name)

    form_refs_checked = 0
    form_ref_bad = False
    for frn in root.iter():
        if not isinstance(frn.tag, str):
            continue
        tag = local_name(frn)
        # ChoiceForm — «форма выбора» реквизита, ссылка того же вида, что и Default*Form.
        if not TAG_RE_20.match(tag) and tag != "ChoiceForm":
            continue
        ref = inner_text(frn).strip()
        if not ref:
            continue
        # Значением бывает GUID (erp: Report.СверкаДанныхОУиБУ, DefaultVariantForm) — проверить
        # его без обхода всех форм нельзя; cf-validate (Check 9) такие тоже пропускает.
        if GUID_RE_20.match(ref):
            continue
        parts = ref.split(".")
        form_refs_checked += 1

        if len(parts) == 2 and parts[0] == "CommonForm":
            if is_extension_20 or not config_dir:
                continue
            cf_dir = os.path.join(config_dir, "CommonForms", parts[1])
            cf_ok = (os.path.exists(cf_dir + ".xml")
                     or os.path.exists(os.path.join(cf_dir, "Ext", "Form.xml"))
                     or os.path.exists(os.path.join(cf_dir, "Form.xml")))
            if not cf_ok:
                if in_config_composition("CommonForm", parts[1]) is True:
                    report_warn(f"20. {tag} '{ref}' — общая форма есть в составе конфигурации, "
                                f"файла формы в выгрузке нет (CommonForms/{parts[1]})")
                else:
                    report_error(f"20. {tag} '{ref}' — общей формы нет в составе конфигурации "
                                 f"(CommonForms/{parts[1]}) — «Неизвестный объект метаданных» при загрузке")
                    form_ref_bad = True
            continue

        if len(parts) != 4 or parts[2] != "Form":
            report_warn(f"20. {tag} '{ref}' — неожиданный вид ссылки на форму "
                        f"(ожидается 'CommonForm.Имя' или '<Вид>.<Объект>.Form.<Форма>')")
            continue

        ref_kind, ref_obj, ref_form = parts[0], parts[1], parts[3]

        if ref_kind.lower() == md_type.lower() and ref_obj.lower() == obj_name.lower():
            if ref_form.lower() not in own_forms:
                known = ", ".join(sorted(own_forms.values())) if own_forms else "нет форм"
                report_error(f"20. {tag} '{ref}' — форма '{ref_form}' не зарегистрирована в "
                             f"ChildObjects объекта (есть: {known}) — «Неизвестный объект метаданных» при загрузке")
                form_ref_bad = True
            elif os.path.isdir(own_dir) and not _form_file_exists_20(own_dir, ref_form):
                # Форма в составе объекта есть, файла нет. Для дерева, претендующего на полноту
                # (рядом лежит Configuration.xml), это ошибка целостности — полная загрузка упадёт
                # на «Файл объекта не существует». Для фрагмента частичной выгрузки — норма:
                # такой файл грузится через -listFile слиянием с конфигурацией БД.
                if config_dir:
                    report_error(f"20. {tag} '{ref}' — форма зарегистрирована в ChildObjects, но файл "
                                 f"формы отсутствует ({obj_name}/Forms/{ref_form})")
                    form_ref_bad = True
                else:
                    report_warn(f"20. {tag} '{ref}' — форма есть в ChildObjects, файла формы "
                                f"в выгрузке нет ({obj_name}/Forms/{ref_form})")
            continue

        # чужой объект (например журнал документов) — нужна конфигурация
        if is_extension_20 or not config_dir:
            continue
        ref_dir_20 = form_owner_dir_map.get(ref_kind)
        if not ref_dir_20:
            report_warn(f"20. {tag} '{ref}' — неизвестный вид метаданных '{ref_kind}' (опечатка?)")
            continue
        ref_obj_xml = os.path.join(config_dir, ref_dir_20, ref_obj + ".xml")
        if not os.path.exists(ref_obj_xml):
            obj_in_composition = in_config_composition(ref_kind, ref_obj)
            if obj_in_composition is False:
                report_error(f"20. {tag} '{ref}' — объекта '{ref_kind}.{ref_obj}' нет в составе "
                             f"конфигурации ({ref_dir_20}/) — «Неизвестный объект метаданных» при загрузке")
                form_ref_bad = True
            elif obj_in_composition is True:
                report_warn(f"20. {tag} '{ref}' — объект '{ref_kind}.{ref_obj}' есть в составе "
                            f"конфигурации, файла объекта в выгрузке нет ({ref_dir_20}/)")
            else:
                report_warn(f"20. {tag} '{ref}' — объект '{ref_kind}.{ref_obj}' не найден в конфигурации ({ref_dir_20}/)")
            continue
        if not _form_file_exists_20(os.path.join(config_dir, ref_dir_20, ref_obj), ref_form):
            report_error(f"20. {tag} '{ref}' — форма '{ref_form}' не найдена у объекта "
                         f"'{ref_kind}.{ref_obj}' — «Неизвестный объект метаданных» при загрузке")
            form_ref_bad = True

    if form_refs_checked > 0 and not form_ref_bad:
        report_ok(f"20. Form refs: {form_refs_checked} resolved")

# ── Final output ──────────────────────────────────────────────

finalize()

if errors > 0:
    sys.exit(1)
sys.exit(0)
