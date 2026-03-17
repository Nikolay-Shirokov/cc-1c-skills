# skd-edit v1.2 — Atomic 1C DCS editor (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import re
import sys
import uuid

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# ── arg parsing ──────────────────────────────────────────────

VALID_OPS = [
    "add-field", "add-total", "add-calculated-field", "add-parameter", "add-filter",
    "add-dataParameter", "add-order", "add-selection", "add-dataSetLink",
    "add-dataSet", "add-variant", "add-conditionalAppearance",
    "set-query", "set-outputParameter", "set-structure",
    "modify-field", "modify-filter", "modify-dataParameter",
    "clear-selection", "clear-order", "clear-filter",
    "remove-field", "remove-total", "remove-calculated-field", "remove-parameter", "remove-filter",
]

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-TemplatePath", required=True)
parser.add_argument("-Operation", required=True, choices=VALID_OPS)
parser.add_argument("-Value", required=True)
parser.add_argument("-DataSet", default="")
parser.add_argument("-Variant", default="")
parser.add_argument("-NoSelection", action="store_true")
args = parser.parse_args()

template_path = args.TemplatePath
operation = args.Operation
value_arg = args.Value
data_set_arg = args.DataSet
variant_arg = args.Variant
no_selection = args.NoSelection

# ── namespaces ───────────────────────────────────────────────

SCH_NS = "http://v8.1c.ru/8.1/data-composition-system/schema"
SET_NS = "http://v8.1c.ru/8.1/data-composition-system/settings"
COR_NS = "http://v8.1c.ru/8.1/data-composition-system/core"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
V8_NS = "http://v8.1c.ru/8.1/data/core"

NS_MAP = {
    "sch": SCH_NS,
    "dcsset": SET_NS,
    "dcscor": COR_NS,
    "xsi": XSI_NS,
    "v8": V8_NS,
}

WRAPPER_NS = (
    f'xmlns="{SCH_NS}"'
    f' xmlns:xsi="{XSI_NS}"'
    f' xmlns:v8="{V8_NS}"'
    ' xmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"'
    f' xmlns:dcscor="{COR_NS}"'
    f' xmlns:dcsset="{SET_NS}"'
    ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
)

XSI_TYPE = f"{{{XSI_NS}}}type"


def local_name(node):
    return etree.QName(node.tag).localname


# ── helpers ──────────────────────────────────────────────────

def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def resolve_query_value(val, base_dir):
    if not val.startswith("@"):
        return val
    file_path = val[1:]
    if os.path.isabs(file_path):
        candidates = [file_path]
    else:
        candidates = [
            os.path.join(base_dir, file_path),
            os.path.join(os.getcwd(), file_path),
        ]
    for c in candidates:
        if os.path.exists(c):
            with open(c, 'r', encoding='utf-8-sig') as f:
                return f.read().rstrip()
    print(f"Query file not found: {file_path} (searched: {', '.join(candidates)})", file=sys.stderr)
    sys.exit(1)


def new_uuid():
    return str(uuid.uuid4())


# ── 1. Resolve path ─────────────────────────────────────────

if not template_path.endswith(".xml"):
    candidate = os.path.join(template_path, "Ext", "Template.xml")
    if os.path.exists(candidate):
        template_path = candidate

if not os.path.exists(template_path):
    print(f"File not found: {template_path}", file=sys.stderr)
    sys.exit(1)

resolved_path = os.path.abspath(template_path)
query_base_dir = os.path.dirname(resolved_path)

# ── 2. Type system ──────────────────────────────────────────

type_synonyms = {
    "\u0447\u0438\u0441\u043b\u043e": "decimal",
    "\u0441\u0442\u0440\u043e\u043a\u0430": "string",
    "\u0431\u0443\u043b\u0435\u0432\u043e": "boolean",
    "\u0434\u0430\u0442\u0430": "date",
    "\u0434\u0430\u0442\u0430\u0432\u0440\u0435\u043c\u044f": "dateTime",
    "\u0441\u0442\u0430\u043d\u0434\u0430\u0440\u0442\u043d\u044b\u0439\u043f\u0435\u0440\u0438\u043e\u0434": "StandardPeriod",
    "bool": "boolean",
    "str": "string",
    "int": "decimal",
    "integer": "decimal",
    "number": "decimal",
    "num": "decimal",
    "\u0441\u043f\u0440\u0430\u0432\u043e\u0447\u043d\u0438\u043a\u0441\u0441\u044b\u043b\u043a\u0430": "CatalogRef",
    "\u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0441\u0441\u044b\u043b\u043a\u0430": "DocumentRef",
    "\u043f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u0438\u0435\u0441\u0441\u044b\u043b\u043a\u0430": "EnumRef",
    "\u043f\u043b\u0430\u043d\u0441\u0447\u0435\u0442\u043e\u0432\u0441\u0441\u044b\u043b\u043a\u0430": "ChartOfAccountsRef",
    "\u043f\u043b\u0430\u043d\u0432\u0438\u0434\u043e\u0432\u0445\u0430\u0440\u0430\u043a\u0442\u0435\u0440\u0438\u0441\u0442\u0438\u043a\u0441\u0441\u044b\u043b\u043a\u0430": "ChartOfCharacteristicTypesRef",
}

output_param_types = {
    "\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a": "mltext",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a": "dcsset:DataCompositionTextOutputType",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b\u0414\u0430\u043d\u043d\u044b\u0445": "dcsset:DataCompositionTextOutputType",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u041e\u0442\u0431\u043e\u0440": "dcsset:DataCompositionTextOutputType",
    "\u041c\u0430\u043a\u0435\u0442\u041e\u0444\u043e\u0440\u043c\u043b\u0435\u043d\u0438\u044f": "xs:string",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041f\u043e\u043b\u0435\u0439\u0413\u0440\u0443\u043f\u043f\u0438\u0440\u043e\u0432\u043a\u0438": "dcsset:DataCompositionGroupFieldsPlacement",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u043e\u0432": "dcsset:DataCompositionAttributesPlacement",
    "\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041e\u0431\u0449\u0438\u0445\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
    "\u0412\u0435\u0440\u0442\u0438\u043a\u0430\u043b\u044c\u043d\u043e\u0435\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041e\u0431\u0449\u0438\u0445\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
}


def resolve_type_str(type_str):
    if not type_str:
        return type_str

    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = type_synonyms.get(base_name.lower())
        if resolved:
            return f"{resolved}({params})"
        return type_str

    if "." in type_str:
        dot_idx = type_str.index(".")
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]
        resolved = type_synonyms.get(prefix.lower())
        if resolved:
            return f"{resolved}{suffix}"
        return type_str

    resolved = type_synonyms.get(type_str.lower())
    if resolved:
        return resolved
    return type_str


# ── 3. Parsers ──────────────────────────────────────────────

def parse_field_shorthand(s):
    result = {"dataPath": "", "field": "", "title": "", "type": "", "roles": [], "restrict": []}

    m = re.search(r'\[([^\]]+)\]', s)
    if m:
        result["title"] = m.group(1)
        s = re.sub(r'\s*\[[^\]]+\]', '', s)

    role_matches = re.findall(r'@(\w+)', s)
    result["roles"] = role_matches
    s = re.sub(r'\s*@\w+', '', s)

    restrict_matches = re.findall(r'#(\w+)', s)
    result["restrict"] = restrict_matches
    s = re.sub(r'\s*#\w+', '', s)

    s = s.strip()
    if ":" in s:
        parts = s.split(":", 1)
        result["dataPath"] = parts[0].strip()
        result["type"] = resolve_type_str(parts[1].strip())
    else:
        result["dataPath"] = s

    result["field"] = result["dataPath"]
    return result


def read_field_properties(field_el):
    props = {"dataPath": "", "field": "", "title": "", "type": "", "roles": [], "restrict": [], "_rawTypeText": ""}

    for ch in field_el:
        if not isinstance(ch.tag, str):
            continue
        ln = local_name(ch)
        if ln == "dataPath":
            props["dataPath"] = (ch.text or "").strip()
        elif ln == "field":
            props["field"] = (ch.text or "").strip()
        elif ln == "title":
            for item in ch:
                if isinstance(item.tag, str) and local_name(item) == "item":
                    for gc in item:
                        if isinstance(gc.tag, str) and local_name(gc) == "content":
                            props["title"] = (gc.text or "").strip()
        elif ln == "valueType":
            for gc in ch:
                if isinstance(gc.tag, str) and local_name(gc) == "Type":
                    props["_rawTypeText"] = (gc.text or "").strip()
                    break
        elif ln == "role":
            for gc in ch:
                if isinstance(gc.tag, str):
                    gcn = local_name(gc)
                    if gcn == "periodNumber":
                        props["roles"].append("period")
                    elif (gc.text or "").strip() == "true":
                        props["roles"].append(gcn)
        elif ln == "useRestriction":
            rev_map = {"field": "noField", "condition": "noFilter", "group": "noGroup", "order": "noOrder"}
            for gc in ch:
                if isinstance(gc.tag, str) and (gc.text or "").strip() == "true":
                    mapped = rev_map.get(local_name(gc))
                    if mapped:
                        props["restrict"].append(mapped)
    return props


def parse_total_shorthand(s):
    parts = s.split(":", 1)
    data_path = parts[0].strip()
    func_part = parts[1].strip()
    if re.match(r'^\w+\(', func_part):
        return {"dataPath": data_path, "expression": func_part}
    else:
        return {"dataPath": data_path, "expression": f"{func_part}({data_path})"}


def parse_calc_shorthand(s):
    title = ""
    m = re.search(r'\[([^\]]+)\]', s)
    if m:
        title = m.group(1)
        s = re.sub(r'\s*\[[^\]]+\]', '', s)

    eq_idx = s.find("=")
    if eq_idx > 0:
        left = s[:eq_idx].strip()
        expression = s[eq_idx + 1:].strip()
        if ":" in left:
            colon_idx = left.index(":")
            data_path = left[:colon_idx].strip()
            type_str = resolve_type_str(left[colon_idx + 1:].strip())
            return {"dataPath": data_path, "expression": expression, "type": type_str, "title": title}
        return {"dataPath": left, "expression": expression, "type": "", "title": title}
    return {"dataPath": s.strip(), "expression": "", "type": "", "title": title}


def parse_param_shorthand(s):
    result = {"name": "", "type": "", "value": None, "autoDates": False}

    if re.search(r'@autoDates', s):
        result["autoDates"] = True
        s = re.sub(r'\s*@autoDates', '', s)

    m = re.match(r'^([^:]+):\s*(\S+)(\s*=\s*(.+))?$', s)
    if m:
        result["name"] = m.group(1).strip()
        result["type"] = resolve_type_str(m.group(2).strip())
        if m.group(4):
            result["value"] = m.group(4).strip()
    else:
        result["name"] = s.strip()

    return result


def parse_filter_shorthand(s):
    result = {"field": "", "op": "Equal", "value": None, "use": True, "userSettingID": None, "viewMode": None}

    if re.search(r'@user', s):
        result["userSettingID"] = "auto"
        s = re.sub(r'\s*@user', '', s)
    if re.search(r'@off', s):
        result["use"] = False
        s = re.sub(r'\s*@off', '', s)
    if re.search(r'@quickAccess', s):
        result["viewMode"] = "QuickAccess"
        s = re.sub(r'\s*@quickAccess', '', s)
    if re.search(r'@normal', s):
        result["viewMode"] = "Normal"
        s = re.sub(r'\s*@normal', '', s)
    if re.search(r'@inaccessible', s):
        result["viewMode"] = "Inaccessible"
        s = re.sub(r'\s*@inaccessible', '', s)

    s = s.strip()

    op_patterns = [r'<>', r'>=', r'<=', r'=', r'>', r'<',
                   r'notIn\b', r'in\b', r'inHierarchy\b', r'inListByHierarchy\b',
                   r'notContains\b', r'contains\b', r'notBeginsWith\b', r'beginsWith\b',
                   r'notFilled\b', r'filled\b']
    op_joined = "|".join(op_patterns)

    m = re.match(rf'^(.+?)\s+({op_joined})\s*(.*)?$', s)
    if m:
        result["field"] = m.group(1).strip()
        op_raw = m.group(2).strip()
        val_part = (m.group(3) or "").strip()

        op_map = {
            "=": "Equal", "<>": "NotEqual", ">": "Greater", ">=": "GreaterOrEqual",
            "<": "Less", "<=": "LessOrEqual", "in": "InList", "notIn": "NotInList",
            "inHierarchy": "InHierarchy", "inListByHierarchy": "InListByHierarchy",
            "contains": "Contains", "notContains": "NotContains",
            "beginsWith": "BeginsWith", "notBeginsWith": "NotBeginsWith",
            "filled": "Filled", "notFilled": "NotFilled",
        }
        result["op"] = op_map.get(op_raw, op_raw)

        if val_part and val_part != "_":
            if val_part in ("true", "false"):
                result["value"] = val_part
                result["valueType"] = "xs:boolean"
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', val_part):
                result["value"] = val_part
                result["valueType"] = "xs:dateTime"
            elif re.match(r'^\d+(\.\d+)?$', val_part):
                result["value"] = val_part
                result["valueType"] = "xs:decimal"
            else:
                result["value"] = val_part
                result["valueType"] = "xs:string"
    else:
        result["field"] = s

    return result


def parse_data_param_shorthand(s):
    result = {"parameter": "", "value": None, "use": True, "userSettingID": None, "viewMode": None}

    if re.search(r'@user', s):
        result["userSettingID"] = "auto"
        s = re.sub(r'\s*@user', '', s)
    if re.search(r'@off', s):
        result["use"] = False
        s = re.sub(r'\s*@off', '', s)
    if re.search(r'@quickAccess', s):
        result["viewMode"] = "QuickAccess"
        s = re.sub(r'\s*@quickAccess', '', s)
    if re.search(r'@normal', s):
        result["viewMode"] = "Normal"
        s = re.sub(r'\s*@normal', '', s)

    s = s.strip()

    m = re.match(r'^([^=]+)=\s*(.+)$', s)
    if m:
        result["parameter"] = m.group(1).strip()
        val_str = m.group(2).strip()

        period_variants = [
            "Custom", "Today", "ThisWeek", "ThisTenDays", "ThisMonth", "ThisQuarter", "ThisHalfYear", "ThisYear",
            "FromBeginningOfThisWeek", "FromBeginningOfThisTenDays", "FromBeginningOfThisMonth",
            "FromBeginningOfThisQuarter", "FromBeginningOfThisHalfYear", "FromBeginningOfThisYear",
            "LastWeek", "LastTenDays", "LastMonth", "LastQuarter", "LastHalfYear", "LastYear",
            "NextDay", "NextWeek", "NextTenDays", "NextMonth", "NextQuarter", "NextHalfYear", "NextYear",
            "TillEndOfThisWeek", "TillEndOfThisTenDays", "TillEndOfThisMonth",
            "TillEndOfThisQuarter", "TillEndOfThisHalfYear", "TillEndOfThisYear",
        ]
        if val_str in period_variants:
            result["value"] = {"variant": val_str}
        else:
            result["value"] = val_str
    else:
        result["parameter"] = s

    return result


def parse_order_shorthand(s):
    s = s.strip()
    if s == "Auto":
        return {"field": "Auto", "direction": ""}
    parts = s.split(None, 1)
    field = parts[0]
    direction = "Asc"
    if len(parts) > 1 and re.match(r'(?i)^desc$', parts[1]):
        direction = "Desc"
    return {"field": field, "direction": direction}


def parse_data_set_link_shorthand(s):
    result = {"source": "", "dest": "", "sourceExpr": "", "destExpr": "", "parameter": ""}

    m = re.search(r'\[param\s+([^\]]+)\]', s)
    if m:
        result["parameter"] = m.group(1).strip()
        s = re.sub(r'\s*\[param\s+[^\]]+\]', '', s)

    m = re.match(r'^(.+?)\s*>\s*(.+?)\s+on\s+(.+?)\s*=\s*(.+)$', s)
    if m:
        result["source"] = m.group(1).strip()
        result["dest"] = m.group(2).strip()
        result["sourceExpr"] = m.group(3).strip()
        result["destExpr"] = m.group(4).strip()
    else:
        print(f"Invalid dataSetLink shorthand: {s}. Expected: 'Source > Dest on FieldA = FieldB [param Name]'", file=sys.stderr)
        sys.exit(1)

    return result


def parse_data_set_shorthand(s):
    s = s.strip()
    m = re.match(r'^(\S+):\s(.+)$', s)
    if m:
        return {"name": m.group(1), "query": m.group(2)}
    return {"name": "", "query": s}


def parse_variant_shorthand(s):
    presentation = ""
    m = re.search(r'\[([^\]]+)\]', s)
    if m:
        presentation = m.group(1)
        s = re.sub(r'\s*\[[^\]]+\]', '', s)
    name = s.strip()
    if not presentation:
        presentation = name
    return {"name": name, "presentation": presentation}


def parse_conditional_appearance_shorthand(s):
    result = {"param": "", "value": "", "filter": None, "fields": []}

    when_idx = s.find(" when ")
    for_idx = s.find(" for ")

    main_end = len(s)
    if when_idx >= 0 and for_idx >= 0:
        main_end = min(when_idx, for_idx)
    elif when_idx >= 0:
        main_end = when_idx
    elif for_idx >= 0:
        main_end = for_idx

    if for_idx >= 0:
        for_end = len(s)
        if when_idx > for_idx:
            for_end = when_idx
        for_part = s[for_idx + 5:for_end].strip()
        result["fields"] = [f.strip() for f in for_part.split(",") if f.strip()]

    if when_idx >= 0:
        when_end = len(s)
        if for_idx > when_idx:
            when_end = for_idx
        when_part = s[when_idx + 6:when_end].strip()
        result["filter"] = parse_filter_shorthand(when_part)

    main_part = s[:main_end].strip()
    eq_idx = main_part.find("=")
    if eq_idx > 0:
        result["param"] = main_part[:eq_idx].strip()
        result["value"] = main_part[eq_idx + 1:].strip()
    else:
        result["param"] = main_part

    return result


def parse_structure_shorthand(s):
    segments = [seg.strip() for seg in s.split(">")]
    result = []
    innermost = None

    for i in range(len(segments) - 1, -1, -1):
        seg = segments[i].strip()
        group = {"type": "group"}

        if re.match(r'^(?i)(details|\u0434\u0435\u0442\u0430\u043b\u0438)$', seg):
            group["groupBy"] = []
        else:
            group["groupBy"] = [seg]

        if innermost is not None:
            group["children"] = [innermost]
        innermost = group

    if innermost:
        result.append(innermost)
    return result


def parse_output_param_shorthand(s):
    idx = s.find("=")
    if idx > 0:
        return {"key": s[:idx].strip(), "value": s[idx + 1:].strip()}
    return {"key": s.strip(), "value": ""}


# ── 4. Build-* functions (XML fragment generators) ──────────

def build_value_type_xml(type_str, indent):
    if not type_str:
        return ""
    type_str = resolve_type_str(type_str)
    lines = []

    if type_str == "boolean":
        lines.append(f"{indent}<v8:Type>xs:boolean</v8:Type>")
        return "\r\n".join(lines)

    m = re.match(r'^string(\((\d+)\))?$', type_str)
    if m:
        length = m.group(2) if m.group(2) else "0"
        lines.append(f"{indent}<v8:Type>xs:string</v8:Type>")
        lines.append(f"{indent}<v8:StringQualifiers>")
        lines.append(f"{indent}\t<v8:Length>{length}</v8:Length>")
        lines.append(f"{indent}\t<v8:AllowedLength>Variable</v8:AllowedLength>")
        lines.append(f"{indent}</v8:StringQualifiers>")
        return "\r\n".join(lines)

    m = re.match(r'^decimal\((\d+),(\d+)(,nonneg)?\)$', type_str)
    if m:
        digits, fraction = m.group(1), m.group(2)
        sign = "Nonnegative" if m.group(3) else "Any"
        lines.append(f"{indent}<v8:Type>xs:decimal</v8:Type>")
        lines.append(f"{indent}<v8:NumberQualifiers>")
        lines.append(f"{indent}\t<v8:Digits>{digits}</v8:Digits>")
        lines.append(f"{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>")
        lines.append(f"{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>")
        lines.append(f"{indent}</v8:NumberQualifiers>")
        return "\r\n".join(lines)

    m = re.match(r'^(date|dateTime)$', type_str)
    if m:
        fractions = "Date" if type_str == "date" else "DateTime"
        lines.append(f"{indent}<v8:Type>xs:dateTime</v8:Type>")
        lines.append(f"{indent}<v8:DateQualifiers>")
        lines.append(f"{indent}\t<v8:DateFractions>{fractions}</v8:DateFractions>")
        lines.append(f"{indent}</v8:DateQualifiers>")
        return "\r\n".join(lines)

    if type_str == "StandardPeriod":
        lines.append(f"{indent}<v8:Type>v8:StandardPeriod</v8:Type>")
        return "\r\n".join(lines)

    if re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.', type_str):
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return "\r\n".join(lines)

    if "." in type_str:
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return "\r\n".join(lines)

    lines.append(f"{indent}<v8:Type>{esc_xml(type_str)}</v8:Type>")
    return "\r\n".join(lines)


def build_mltext_xml(tag, text, indent):
    lines = [
        f'{indent}<{tag} xsi:type="v8:LocalStringType">',
        f"{indent}\t<v8:item>",
        f"{indent}\t\t<v8:lang>ru</v8:lang>",
        f"{indent}\t\t<v8:content>{esc_xml(text)}</v8:content>",
        f"{indent}\t</v8:item>",
        f"{indent}</{tag}>",
    ]
    return "\r\n".join(lines)


def build_role_xml(roles, indent):
    if not roles:
        return ""
    lines = [f"{indent}<role>"]
    for role in roles:
        if role == "period":
            lines.append(f"{indent}\t<dcscom:periodNumber>1</dcscom:periodNumber>")
            lines.append(f"{indent}\t<dcscom:periodType>Main</dcscom:periodType>")
        else:
            lines.append(f"{indent}\t<dcscom:{role}>true</dcscom:{role}>")
    lines.append(f"{indent}</role>")
    return "\r\n".join(lines)


def build_restriction_xml(restrict, indent):
    if not restrict:
        return ""
    restrict_map = {"noField": "field", "noFilter": "condition", "noCondition": "condition", "noGroup": "group", "noOrder": "order"}
    lines = [f"{indent}<useRestriction>"]
    for r in restrict:
        xml_name = restrict_map.get(r)
        if xml_name:
            lines.append(f"{indent}\t<{xml_name}>true</{xml_name}>")
    lines.append(f"{indent}</useRestriction>")
    return "\r\n".join(lines)


def build_field_fragment(parsed, indent):
    i = indent
    lines = [f'{i}<field xsi:type="DataSetFieldField">']
    lines.append(f"{i}\t<dataPath>{esc_xml(parsed['dataPath'])}</dataPath>")
    lines.append(f"{i}\t<field>{esc_xml(parsed['field'])}</field>")

    if parsed.get("title"):
        lines.append(build_mltext_xml("title", parsed["title"], f"{i}\t"))

    if parsed.get("restrict"):
        lines.append(build_restriction_xml(parsed["restrict"], f"{i}\t"))

    role_xml = build_role_xml(parsed.get("roles"), f"{i}\t")
    if role_xml:
        lines.append(role_xml)

    if parsed.get("type"):
        lines.append(f"{i}\t<valueType>")
        lines.append(build_value_type_xml(parsed["type"], f"{i}\t\t"))
        lines.append(f"{i}\t</valueType>")

    lines.append(f"{i}</field>")
    return "\r\n".join(lines)


def build_total_fragment(parsed, indent):
    i = indent
    lines = [
        f"{i}<totalField>",
        f"{i}\t<dataPath>{esc_xml(parsed['dataPath'])}</dataPath>",
        f"{i}\t<expression>{esc_xml(parsed['expression'])}</expression>",
        f"{i}</totalField>",
    ]
    return "\r\n".join(lines)


def build_calc_field_fragment(parsed, indent):
    i = indent
    lines = [
        f"{i}<calculatedField>",
        f"{i}\t<dataPath>{esc_xml(parsed['dataPath'])}</dataPath>",
        f"{i}\t<expression>{esc_xml(parsed['expression'])}</expression>",
    ]
    if parsed.get("title"):
        lines.append(build_mltext_xml("title", parsed["title"], f"{i}\t"))
    if parsed.get("type"):
        lines.append(f"{i}\t<valueType>")
        lines.append(build_value_type_xml(parsed["type"], f"{i}\t\t"))
        lines.append(f"{i}\t</valueType>")
    lines.append(f"{i}</calculatedField>")
    return "\r\n".join(lines)


def build_param_fragment(parsed, indent):
    i = indent
    fragments = []

    lines = [f"{i}<parameter>", f"{i}\t<name>{esc_xml(parsed['name'])}</name>"]
    if parsed.get("type"):
        lines.append(f"{i}\t<valueType>")
        lines.append(build_value_type_xml(parsed["type"], f"{i}\t\t"))
        lines.append(f"{i}\t</valueType>")

    if parsed["value"] is not None:
        val_str = str(parsed["value"])
        if parsed.get("type") == "StandardPeriod":
            lines.append(f'{i}\t<value xsi:type="v8:StandardPeriod">')
            lines.append(f'{i}\t\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(val_str)}</v8:variant>')
            lines.append(f"{i}\t</value>")
        elif parsed.get("type", "").startswith("date"):
            lines.append(f'{i}\t<value xsi:type="xs:dateTime">{esc_xml(val_str)}</value>')
        elif parsed.get("type") == "boolean":
            lines.append(f'{i}\t<value xsi:type="xs:boolean">{esc_xml(val_str)}</value>')
        elif parsed.get("type", "").startswith("decimal"):
            lines.append(f'{i}\t<value xsi:type="xs:decimal">{esc_xml(val_str)}</value>')
        else:
            lines.append(f'{i}\t<value xsi:type="xs:string">{esc_xml(val_str)}</value>')

    lines.append(f"{i}</parameter>")
    fragments.append("\r\n".join(lines))

    if parsed.get("autoDates"):
        param_name = parsed["name"]
        b_lines = [
            f"{i}<parameter>",
            f"{i}\t<name>\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430</name>",
            f"{i}\t<valueType>",
            build_value_type_xml("date", f"{i}\t\t"),
            f"{i}\t</valueType>",
            f"{i}\t<expression>{esc_xml('&' + param_name + '.\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430')}</expression>",
            f"{i}\t<availableAsField>false</availableAsField>",
            f"{i}</parameter>",
        ]
        fragments.append("\r\n".join(b_lines))

        e_lines = [
            f"{i}<parameter>",
            f"{i}\t<name>\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f</name>",
            f"{i}\t<valueType>",
            build_value_type_xml("date", f"{i}\t\t"),
            f"{i}\t</valueType>",
            f"{i}\t<expression>{esc_xml('&' + param_name + '.\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f')}</expression>",
            f"{i}\t<availableAsField>false</availableAsField>",
            f"{i}</parameter>",
        ]
        fragments.append("\r\n".join(e_lines))

    return fragments


def build_filter_item_fragment(parsed, indent):
    i = indent
    lines = [f'{i}<dcsset:item xsi:type="dcsset:FilterItemComparison">']

    if parsed.get("use") is False:
        lines.append(f"{i}\t<dcsset:use>false</dcsset:use>")

    lines.append(f'{i}\t<dcsset:left xsi:type="dcscor:Field">{esc_xml(parsed["field"])}</dcsset:left>')
    lines.append(f"{i}\t<dcsset:comparisonType>{esc_xml(parsed['op'])}</dcsset:comparisonType>")

    if parsed.get("value") is not None:
        vt = parsed.get("valueType", "xs:string")
        lines.append(f'{i}\t<dcsset:right xsi:type="{vt}">{esc_xml(str(parsed["value"]))}</dcsset:right>')

    if parsed.get("viewMode"):
        lines.append(f"{i}\t<dcsset:viewMode>{esc_xml(parsed['viewMode'])}</dcsset:viewMode>")

    if parsed.get("userSettingID"):
        uid = new_uuid() if parsed["userSettingID"] == "auto" else parsed["userSettingID"]
        lines.append(f"{i}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>")

    lines.append(f"{i}</dcsset:item>")
    return "\r\n".join(lines)


def build_selection_item_fragment(field_name, indent):
    i = indent
    if field_name == "Auto":
        return f'{i}<dcsset:item xsi:type="dcsset:SelectedItemAuto"/>'
    lines = [
        f'{i}<dcsset:item xsi:type="dcsset:SelectedItemField">',
        f"{i}\t<dcsset:field>{esc_xml(field_name)}</dcsset:field>",
        f"{i}</dcsset:item>",
    ]
    return "\r\n".join(lines)


def build_data_param_fragment(parsed, indent):
    i = indent
    lines = [f'{i}<dcscor:item xsi:type="dcsset:SettingsParameterValue">']

    if parsed.get("use") is False:
        lines.append(f"{i}\t<dcscor:use>false</dcscor:use>")

    lines.append(f"{i}\t<dcscor:parameter>{esc_xml(parsed['parameter'])}</dcscor:parameter>")

    if parsed.get("value") is not None:
        val = parsed["value"]
        if isinstance(val, dict) and val.get("variant"):
            lines.append(f'{i}\t<dcscor:value xsi:type="v8:StandardPeriod">')
            lines.append(f'{i}\t\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(val["variant"])}</v8:variant>')
            lines.append(f"{i}\t</dcscor:value>")
        elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(val)):
            lines.append(f'{i}\t<dcscor:value xsi:type="xs:dateTime">{esc_xml(str(val))}</dcscor:value>')
        elif str(val) in ("true", "false"):
            lines.append(f'{i}\t<dcscor:value xsi:type="xs:boolean">{esc_xml(str(val))}</dcscor:value>')
        else:
            lines.append(f'{i}\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')

    if parsed.get("viewMode"):
        lines.append(f"{i}\t<dcsset:viewMode>{esc_xml(parsed['viewMode'])}</dcsset:viewMode>")

    if parsed.get("userSettingID"):
        uid = new_uuid() if parsed["userSettingID"] == "auto" else parsed["userSettingID"]
        lines.append(f"{i}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>")

    lines.append(f"{i}</dcscor:item>")
    return "\r\n".join(lines)


def build_order_item_fragment(parsed, indent):
    i = indent
    if parsed["field"] == "Auto":
        return f'{i}<dcsset:item xsi:type="dcsset:OrderItemAuto"/>'
    lines = [
        f'{i}<dcsset:item xsi:type="dcsset:OrderItemField">',
        f"{i}\t<dcsset:field>{esc_xml(parsed['field'])}</dcsset:field>",
        f"{i}\t<dcsset:orderType>{parsed['direction']}</dcsset:orderType>",
        f"{i}</dcsset:item>",
    ]
    return "\r\n".join(lines)


def build_data_set_link_fragment(parsed, indent):
    i = indent
    lines = [
        f"{i}<dataSetLink>",
        f"{i}\t<sourceDataSet>{esc_xml(parsed['source'])}</sourceDataSet>",
        f"{i}\t<destinationDataSet>{esc_xml(parsed['dest'])}</destinationDataSet>",
        f"{i}\t<sourceExpression>{esc_xml(parsed['sourceExpr'])}</sourceExpression>",
        f"{i}\t<destinationExpression>{esc_xml(parsed['destExpr'])}</destinationExpression>",
    ]
    if parsed.get("parameter"):
        lines.append(f"{i}\t<parameter>{esc_xml(parsed['parameter'])}</parameter>")
    lines.append(f"{i}</dataSetLink>")
    return "\r\n".join(lines)


def build_data_set_query_fragment(parsed, indent):
    i = indent
    lines = [
        f'{i}<dataSet xsi:type="DataSetQuery">',
        f"{i}\t<name>{esc_xml(parsed['name'])}</name>",
        f"{i}\t<dataSource>{esc_xml(parsed['dataSource'])}</dataSource>",
        f"{i}\t<query>{esc_xml(parsed['query'])}</query>",
        f"{i}</dataSet>",
    ]
    return "\r\n".join(lines)


def build_variant_fragment(parsed, indent):
    i = indent
    lines = [
        f"{i}<settingsVariant>",
        f"{i}\t<dcsset:name>{esc_xml(parsed['name'])}</dcsset:name>",
        build_mltext_xml("dcsset:presentation", parsed["presentation"], f"{i}\t"),
        f'{i}\t<dcsset:settings xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows">',
        f"{i}\t\t<dcsset:selection>",
        f'{i}\t\t\t<dcsset:item xsi:type="dcsset:SelectedItemAuto"/>',
        f"{i}\t\t</dcsset:selection>",
        f'{i}\t\t<dcsset:item xsi:type="dcsset:StructureItemGroup">',
        f"{i}\t\t\t<dcsset:groupItems/>",
        f"{i}\t\t\t<dcsset:order>",
        f'{i}\t\t\t\t<dcsset:item xsi:type="dcsset:OrderItemAuto"/>',
        f"{i}\t\t\t</dcsset:order>",
        f"{i}\t\t\t<dcsset:selection>",
        f'{i}\t\t\t\t<dcsset:item xsi:type="dcsset:SelectedItemAuto"/>',
        f"{i}\t\t\t</dcsset:selection>",
        f"{i}\t\t</dcsset:item>",
        f"{i}\t</dcsset:settings>",
        f"{i}</settingsVariant>",
    ]
    return "\r\n".join(lines)


def build_conditional_appearance_item_fragment(parsed, indent):
    i = indent
    lines = [f"{i}<dcsset:item>"]

    if parsed.get("fields"):
        lines.append(f"{i}\t<dcsset:selection>")
        for fld in parsed["fields"]:
            lines.append(f"{i}\t\t<dcsset:item>")
            lines.append(f"{i}\t\t\t<dcsset:field>{esc_xml(fld)}</dcsset:field>")
            lines.append(f"{i}\t\t</dcsset:item>")
        lines.append(f"{i}\t</dcsset:selection>")
    else:
        lines.append(f"{i}\t<dcsset:selection/>")

    if parsed.get("filter"):
        f = parsed["filter"]
        lines.append(f"{i}\t<dcsset:filter>")
        lines.append(f'{i}\t\t<dcsset:item xsi:type="dcsset:FilterItemComparison">')
        lines.append(f'{i}\t\t\t<dcsset:left xsi:type="dcscor:Field">{esc_xml(f["field"])}</dcsset:left>')
        lines.append(f"{i}\t\t\t<dcsset:comparisonType>{esc_xml(f['op'])}</dcsset:comparisonType>")
        if f.get("value") is not None:
            vt = f.get("valueType", "xs:string")
            lines.append(f'{i}\t\t\t<dcsset:right xsi:type="{vt}">{esc_xml(str(f["value"]))}</dcsset:right>')
        lines.append(f"{i}\t\t</dcsset:item>")
        lines.append(f"{i}\t</dcsset:filter>")
    else:
        lines.append(f"{i}\t<dcsset:filter/>")

    # appearance
    lines.append(f"{i}\t<dcsset:appearance>")
    val = parsed["value"]
    val_type = "xs:string"
    if re.match(r'^(web|style|win):', val):
        val_type = "v8ui:Color"
    elif val in ("true", "false"):
        val_type = "xs:boolean"

    lines.append(f'{i}\t\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
    lines.append(f"{i}\t\t\t<dcscor:parameter>{esc_xml(parsed['param'])}</dcscor:parameter>")
    lines.append(f'{i}\t\t\t<dcscor:value xsi:type="{val_type}">{esc_xml(val)}</dcscor:value>')
    lines.append(f"{i}\t\t</dcscor:item>")
    lines.append(f"{i}\t</dcsset:appearance>")

    lines.append(f"{i}</dcsset:item>")
    return "\r\n".join(lines)


def build_structure_item_fragment(item, indent):
    i = indent
    lines = [f'{i}<dcsset:item xsi:type="dcsset:StructureItemGroup">']

    group_by = item.get("groupBy", [])
    if not group_by:
        lines.append(f"{i}\t<dcsset:groupItems/>")
    else:
        lines.append(f"{i}\t<dcsset:groupItems>")
        for field in group_by:
            lines.append(f'{i}\t\t<dcsset:item xsi:type="dcsset:GroupItemField">')
            lines.append(f"{i}\t\t\t<dcsset:field>{esc_xml(field)}</dcsset:field>")
            lines.append(f"{i}\t\t\t<dcsset:groupType>Items</dcsset:groupType>")
            lines.append(f"{i}\t\t\t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>")
            lines.append(f'{i}\t\t\t<dcsset:periodAdditionBegin xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionBegin>')
            lines.append(f'{i}\t\t\t<dcsset:periodAdditionEnd xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionEnd>')
            lines.append(f"{i}\t\t</dcsset:item>")
        lines.append(f"{i}\t</dcsset:groupItems>")

    lines.append(f"{i}\t<dcsset:order>")
    lines.append(f'{i}\t\t<dcsset:item xsi:type="dcsset:OrderItemAuto"/>')
    lines.append(f"{i}\t</dcsset:order>")
    lines.append(f"{i}\t<dcsset:selection>")
    lines.append(f'{i}\t\t<dcsset:item xsi:type="dcsset:SelectedItemAuto"/>')
    lines.append(f"{i}\t</dcsset:selection>")

    if item.get("children"):
        for child in item["children"]:
            lines.append(build_structure_item_fragment(child, f"{i}\t"))

    lines.append(f"{i}</dcsset:item>")
    return "\r\n".join(lines)


def build_output_param_fragment(parsed, indent):
    i = indent
    key = parsed["key"]
    val = parsed["value"]
    ptype = output_param_types.get(key, "xs:string")

    lines = [f'{i}<dcscor:item xsi:type="dcsset:SettingsParameterValue">']
    lines.append(f"{i}\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>")

    if ptype == "mltext":
        lines.append(f'{i}\t<dcscor:value xsi:type="v8:LocalStringType">')
        lines.append(f"{i}\t\t<v8:item>")
        lines.append(f"{i}\t\t\t<v8:lang>ru</v8:lang>")
        lines.append(f"{i}\t\t\t<v8:content>{esc_xml(val)}</v8:content>")
        lines.append(f"{i}\t\t</v8:item>")
        lines.append(f"{i}\t</dcscor:value>")
    else:
        lines.append(f'{i}\t<dcscor:value xsi:type="{ptype}">{esc_xml(val)}</dcscor:value>')

    lines.append(f"{i}</dcscor:item>")
    return "\r\n".join(lines)


# ── 5. XML helpers ──────────────────────────────────────────

def import_fragment(doc_root, xml_string):
    wrapper = f"<_W {WRAPPER_NS}>{xml_string}</_W>"
    frag_parser = etree.XMLParser(remove_blank_text=False)
    frag = etree.fromstring(wrapper.encode("utf-8"), frag_parser)
    nodes = []
    for child in frag:
        if isinstance(child.tag, str):
            nodes.append(child)
    return nodes


def get_child_indent(container):
    for i, child in enumerate(container):
        txt = container.text if i == 0 else container[i - 1].tail
        if txt:
            m = re.search(r'\n(\t+)$', txt)
            if m:
                return m.group(1)
    # Fallback: count depth
    depth = 0
    current = container
    while current is not None:
        parent = current.getparent()
        if parent is None:
            break
        depth += 1
        current = parent
    return "\t" * (depth + 1)


def insert_before_element(container, new_node, ref_node, child_indent):
    if ref_node is not None:
        idx = list(container).index(ref_node)
        if idx == 0:
            prev_text = container.text or ""
            container.text = prev_text.rstrip("\n\t") + "\n" + child_indent
            container.insert(idx, new_node)
            new_node.tail = "\n" + child_indent
        else:
            prev = container[idx - 1]
            prev.tail = (prev.tail or "").rstrip("\n\t") + "\n" + child_indent
            container.insert(idx, new_node)
            new_node.tail = "\n" + child_indent
    else:
        # Append at end
        children = list(container)
        if children:
            last = children[-1]
            last.tail = (last.tail or "").rstrip("\n\t") + "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent
        else:
            container.text = "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent


def clear_container_children(container):
    to_remove = [ch for ch in container if isinstance(ch.tag, str)]
    for el in to_remove:
        remove_node_with_whitespace(el)


def remove_node_with_whitespace(node):
    parent = node.getparent()
    idx = list(parent).index(node)
    # Remove the node and adjust whitespace
    if idx > 0:
        prev = parent[idx - 1]
        # Preserve the tail of the removed node's predecessor
        prev.tail = node.tail
    elif idx == 0:
        parent.text = node.tail
    parent.remove(node)


def find_first_element(container, local_names, ns_uri=None):
    for child in container:
        if not isinstance(child.tag, str):
            continue
        ln = local_name(child)
        if ln in local_names:
            if not ns_uri or etree.QName(child.tag).namespace == ns_uri:
                return child
    return None


def find_last_element(container, ln_name, ns_uri=None):
    last = None
    for child in container:
        if not isinstance(child.tag, str):
            continue
        if local_name(child) == ln_name:
            if not ns_uri or etree.QName(child.tag).namespace == ns_uri:
                last = child
    return last


def find_element_by_child_value(container, elem_name, child_name, child_value, ns_uri=None):
    for child in container:
        if not isinstance(child.tag, str):
            continue
        if local_name(child) != elem_name:
            continue
        if ns_uri and etree.QName(child.tag).namespace != ns_uri:
            continue
        for gc in child:
            if isinstance(gc.tag, str) and local_name(gc) == child_name and (gc.text or "").strip() == child_value:
                return child
    return None


def set_or_create_child_element(parent, ln, ns_uri, value, indent):
    existing = None
    for ch in parent:
        if isinstance(ch.tag, str) and local_name(ch) == ln and etree.QName(ch.tag).namespace == ns_uri:
            existing = ch
            break
    if existing is not None:
        existing.text = value
    else:
        prefix = None
        for p, uri in parent.nsmap.items():
            if uri == ns_uri:
                prefix = p
                break
        qual_name = f"{prefix}:{ln}" if prefix else ln
        frag_xml = f"{indent}<{qual_name}>{esc_xml(value)}</{qual_name}>"
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(parent, node, None, indent)


def set_or_create_child_element_with_attr(parent, ln, ns_uri, value, xsi_type, indent):
    existing = None
    for ch in parent:
        if isinstance(ch.tag, str) and local_name(ch) == ln and etree.QName(ch.tag).namespace == ns_uri:
            existing = ch
            break
    if existing is not None:
        existing.text = value
        if xsi_type:
            existing.set(XSI_TYPE, xsi_type)
    else:
        prefix = None
        for p, uri in parent.nsmap.items():
            if uri == ns_uri:
                prefix = p
                break
        qual_name = f"{prefix}:{ln}" if prefix else ln
        type_attr = f' xsi:type="{xsi_type}"' if xsi_type else ""
        frag_xml = f"{indent}<{qual_name}{type_attr}>{esc_xml(value)}</{qual_name}>"
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(parent, node, None, indent)


def resolve_data_set():
    root_el = xml_doc

    if data_set_arg:
        for child in root_el:
            if isinstance(child.tag, str) and local_name(child) == "dataSet" and etree.QName(child.tag).namespace == SCH_NS:
                for gc in child:
                    if isinstance(gc.tag, str) and local_name(gc) == "name" and etree.QName(gc.tag).namespace == SCH_NS:
                        if gc.text == data_set_arg:
                            return child
        print(f"DataSet '{data_set_arg}' not found", file=sys.stderr)
        sys.exit(1)

    for child in root_el:
        if isinstance(child.tag, str) and local_name(child) == "dataSet" and etree.QName(child.tag).namespace == SCH_NS:
            return child
    print("No dataSet found in DCS", file=sys.stderr)
    sys.exit(1)


def resolve_variant_settings():
    root_el = xml_doc
    sv = None

    if variant_arg:
        for child in root_el:
            if isinstance(child.tag, str) and local_name(child) == "settingsVariant" and etree.QName(child.tag).namespace == SCH_NS:
                for gc in child:
                    if isinstance(gc.tag, str) and local_name(gc) == "name" and etree.QName(gc.tag).namespace == SET_NS:
                        if gc.text == variant_arg:
                            sv = child
                            break
                if sv:
                    break
        if not sv:
            print(f"Variant '{variant_arg}' not found", file=sys.stderr)
            sys.exit(1)
    else:
        for child in root_el:
            if isinstance(child.tag, str) and local_name(child) == "settingsVariant" and etree.QName(child.tag).namespace == SCH_NS:
                sv = child
                break
        if not sv:
            print("No settingsVariant found in DCS", file=sys.stderr)
            sys.exit(1)

    for gc in sv:
        if isinstance(gc.tag, str) and local_name(gc) == "settings" and etree.QName(gc.tag).namespace == SET_NS:
            return gc

    print("No <dcsset:settings> found in variant", file=sys.stderr)
    sys.exit(1)


def ensure_settings_child(settings, child_name, after_siblings):
    el = find_first_element(settings, [child_name], SET_NS)
    if el is not None:
        return el

    indent = get_child_indent(settings)
    frag_xml = f"{indent}<dcsset:{child_name}/>"
    nodes = import_fragment(xml_doc, frag_xml)

    ref_node = None
    for sib_name in after_siblings:
        sib = find_first_element(settings, [sib_name], SET_NS)
        if sib is not None:
            # Get next element sibling
            found = False
            for ch in settings:
                if found and isinstance(ch.tag, str):
                    ref_node = ch
                    break
                if ch is sib:
                    found = True
            break

    for node in nodes:
        insert_before_element(settings, node, ref_node, indent)

    return find_first_element(settings, [child_name], SET_NS)


def get_variant_name():
    if variant_arg:
        return variant_arg
    root_el = xml_doc
    for child in root_el:
        if isinstance(child.tag, str) and local_name(child) == "settingsVariant" and etree.QName(child.tag).namespace == SCH_NS:
            for gc in child:
                if isinstance(gc.tag, str) and local_name(gc) == "name" and etree.QName(gc.tag).namespace == SET_NS:
                    return gc.text or "(unknown)"
    return "(unknown)"


def get_data_set_name(ds_node):
    for gc in ds_node:
        if isinstance(gc.tag, str) and local_name(gc) == "name" and etree.QName(gc.tag).namespace == SCH_NS:
            return gc.text or "(unknown)"
    return "(unknown)"


def get_container_child_indent(container):
    has_elements = any(isinstance(ch.tag, str) for ch in container)
    if has_elements:
        return get_child_indent(container)
    else:
        parent_indent = get_child_indent(container.getparent())
        return parent_indent + "\t"


# ── 6. Load XML ─────────────────────────────────────────────

xml_parser = etree.XMLParser(remove_blank_text=False)
tree = etree.parse(resolved_path, xml_parser)
xml_doc = tree.getroot()

# ── 7. Batch value splitting ────────────────────────────────

if operation in ("set-query", "set-structure", "add-dataSet"):
    values = [value_arg]
else:
    values = [v.strip() for v in value_arg.split(";;") if v.strip()]

# ── 8. Main logic ───────────────────────────────────────────

if operation == "add-field":
    ds_node = resolve_data_set()
    ds_name = get_data_set_name(ds_node)

    for val in values:
        parsed = parse_field_shorthand(val)
        child_indent = get_child_indent(ds_node)

        existing = find_element_by_child_value(ds_node, "field", "dataPath", parsed["dataPath"], SCH_NS)
        if existing is not None:
            print(f'[WARN] Field "{parsed["dataPath"]}" already exists in dataset "{ds_name}" -- skipped')
            continue

        frag_xml = build_field_fragment(parsed, child_indent)
        nodes = import_fragment(xml_doc, frag_xml)

        ref_node = find_first_element(ds_node, ["dataSource"], SCH_NS)
        for node in nodes:
            insert_before_element(ds_node, node, ref_node, child_indent)

        print(f'[OK] Field "{parsed["dataPath"]}" added to dataset "{ds_name}"')

        if not no_selection:
            settings = resolve_variant_settings()
            var_name = get_variant_name()
            selection = ensure_settings_child(settings, "selection", [])
            existing_sel = find_element_by_child_value(selection, "item", "field", parsed["dataPath"], SET_NS)
            if existing_sel is not None:
                print(f'[INFO] Field "{parsed["dataPath"]}" already in selection -- skipped')
            else:
                sel_indent = get_container_child_indent(selection)
                sel_xml = build_selection_item_fragment(parsed["dataPath"], sel_indent)
                sel_nodes = import_fragment(xml_doc, sel_xml)
                for node in sel_nodes:
                    insert_before_element(selection, node, None, sel_indent)
                print(f'[OK] Field "{parsed["dataPath"]}" added to selection of variant "{var_name}"')

elif operation == "add-total":
    for val in values:
        parsed = parse_total_shorthand(val)
        child_indent = get_child_indent(xml_doc)

        existing = find_element_by_child_value(xml_doc, "totalField", "dataPath", parsed["dataPath"], SCH_NS)
        if existing is not None:
            print(f'[WARN] TotalField "{parsed["dataPath"]}" already exists -- skipped')
            continue

        frag_xml = build_total_fragment(parsed, child_indent)
        nodes = import_fragment(xml_doc, frag_xml)

        last_total = find_last_element(xml_doc, "totalField", SCH_NS)
        if last_total is not None:
            # Insert after last totalField - find next element
            ref_node = None
            found = False
            for ch in xml_doc:
                if found and isinstance(ch.tag, str):
                    ref_node = ch
                    break
                if ch is last_total:
                    found = True
        else:
            ref_node = find_first_element(xml_doc, ["parameter", "template", "groupTemplate", "settingsVariant"], SCH_NS)

        for node in nodes:
            insert_before_element(xml_doc, node, ref_node, child_indent)

        print(f'[OK] TotalField "{parsed["dataPath"]}" = {parsed["expression"]} added')

elif operation == "add-calculated-field":
    for val in values:
        parsed = parse_calc_shorthand(val)
        child_indent = get_child_indent(xml_doc)

        existing = find_element_by_child_value(xml_doc, "calculatedField", "dataPath", parsed["dataPath"], SCH_NS)
        if existing is not None:
            print(f'[WARN] CalculatedField "{parsed["dataPath"]}" already exists -- skipped')
            continue

        frag_xml = build_calc_field_fragment(parsed, child_indent)
        nodes = import_fragment(xml_doc, frag_xml)

        last_calc = find_last_element(xml_doc, "calculatedField", SCH_NS)
        if last_calc is not None:
            ref_node = None
            found = False
            for ch in xml_doc:
                if found and isinstance(ch.tag, str):
                    ref_node = ch
                    break
                if ch is last_calc:
                    found = True
        else:
            ref_node = find_first_element(xml_doc, ["totalField", "parameter", "template", "groupTemplate", "settingsVariant"], SCH_NS)

        for node in nodes:
            insert_before_element(xml_doc, node, ref_node, child_indent)

        print(f'[OK] CalculatedField "{parsed["dataPath"]}" = {parsed["expression"]} added')

        if not no_selection:
            settings = resolve_variant_settings()
            var_name = get_variant_name()
            selection = ensure_settings_child(settings, "selection", [])
            existing_sel = find_element_by_child_value(selection, "item", "field", parsed["dataPath"], SET_NS)
            if existing_sel is not None:
                print(f'[INFO] Field "{parsed["dataPath"]}" already in selection -- skipped')
            else:
                sel_indent = get_container_child_indent(selection)
                sel_xml = build_selection_item_fragment(parsed["dataPath"], sel_indent)
                sel_nodes = import_fragment(xml_doc, sel_xml)
                for node in sel_nodes:
                    insert_before_element(selection, node, None, sel_indent)
                print(f'[OK] Field "{parsed["dataPath"]}" added to selection of variant "{var_name}"')

elif operation == "add-parameter":
    for val in values:
        parsed = parse_param_shorthand(val)
        child_indent = get_child_indent(xml_doc)

        existing = find_element_by_child_value(xml_doc, "parameter", "name", parsed["name"], SCH_NS)
        if existing is not None:
            print(f'[WARN] Parameter "{parsed["name"]}" already exists -- skipped')
            continue

        fragments = build_param_fragment(parsed, child_indent)

        last_param = find_last_element(xml_doc, "parameter", SCH_NS)
        if last_param is not None:
            ref_node = None
            found = False
            for ch in xml_doc:
                if found and isinstance(ch.tag, str):
                    ref_node = ch
                    break
                if ch is last_param:
                    found = True
        else:
            ref_node = find_first_element(xml_doc, ["template", "groupTemplate", "settingsVariant"], SCH_NS)

        for frag_xml in fragments:
            nodes = import_fragment(xml_doc, frag_xml)
            for node in nodes:
                insert_before_element(xml_doc, node, ref_node, child_indent)

        print(f'[OK] Parameter "{parsed["name"]}" added')
        if parsed.get("autoDates"):
            print('[OK] Auto-parameters "\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430", "\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f" added')

elif operation == "add-filter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        parsed = parse_filter_shorthand(val)
        filter_el = ensure_settings_child(settings, "filter", ["selection"])
        filter_indent = get_container_child_indent(filter_el)
        frag_xml = build_filter_item_fragment(parsed, filter_indent)
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(filter_el, node, None, filter_indent)
        print(f'[OK] Filter "{parsed["field"]} {parsed["op"]}" added to variant "{var_name}"')

elif operation == "add-dataParameter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        parsed = parse_data_param_shorthand(val)
        dp_el = ensure_settings_child(settings, "dataParameters", ["outputParameters", "conditionalAppearance", "order", "filter", "selection"])
        dp_indent = get_container_child_indent(dp_el)
        frag_xml = build_data_param_fragment(parsed, dp_indent)
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(dp_el, node, None, dp_indent)
        print(f'[OK] DataParameter "{parsed["parameter"]}" added to variant "{var_name}"')

elif operation == "add-order":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        parsed = parse_order_shorthand(val)
        order_el = ensure_settings_child(settings, "order", ["filter", "selection"])
        order_indent = get_container_child_indent(order_el)

        if parsed["field"] == "Auto":
            is_dup = False
            for ch in order_el:
                if isinstance(ch.tag, str) and local_name(ch) == "item":
                    type_attr = ch.get(XSI_TYPE, "")
                    if "OrderItemAuto" in type_attr:
                        is_dup = True
                        break
            if is_dup:
                print(f'[WARN] OrderItemAuto already exists in variant "{var_name}" -- skipped')
                continue
        else:
            existing_ord = find_element_by_child_value(order_el, "item", "field", parsed["field"], SET_NS)
            if existing_ord is not None:
                print(f'[WARN] Order "{parsed["field"]}" already exists in variant "{var_name}" -- skipped')
                continue

        frag_xml = build_order_item_fragment(parsed, order_indent)
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(order_el, node, None, order_indent)

        desc = "Auto" if parsed["field"] == "Auto" else f"{parsed['field']} {parsed['direction']}"
        print(f'[OK] Order "{desc}" added to variant "{var_name}"')

elif operation == "add-selection":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        field_name = val.strip()
        selection = ensure_settings_child(settings, "selection", [])
        sel_indent = get_container_child_indent(selection)
        sel_xml = build_selection_item_fragment(field_name, sel_indent)
        sel_nodes = import_fragment(xml_doc, sel_xml)
        for node in sel_nodes:
            insert_before_element(selection, node, None, sel_indent)
        print(f'[OK] Selection "{field_name}" added to variant "{var_name}"')

elif operation == "set-query":
    ds_node = resolve_data_set()
    ds_name = get_data_set_name(ds_node)
    query_el = find_first_element(ds_node, ["query"], SCH_NS)
    if query_el is None:
        print(f"No <query> element found in dataset '{ds_name}'", file=sys.stderr)
        sys.exit(1)
    query_el.text = resolve_query_value(value_arg, query_base_dir)
    print(f'[OK] Query replaced in dataset "{ds_name}"')

elif operation == "set-outputParameter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        parsed = parse_output_param_shorthand(val)
        output_el = ensure_settings_child(settings, "outputParameters", ["conditionalAppearance", "order", "filter", "selection"])
        output_indent = get_container_child_indent(output_el)

        existing_param = find_element_by_child_value(output_el, "item", "parameter", parsed["key"], COR_NS)
        if existing_param is not None:
            remove_node_with_whitespace(existing_param)
            print(f'[OK] Replaced outputParameter "{parsed["key"]}" in variant "{var_name}"')
        else:
            print(f'[OK] OutputParameter "{parsed["key"]}" added to variant "{var_name}"')

        frag_xml = build_output_param_fragment(parsed, output_indent)
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(output_el, node, None, output_indent)

elif operation == "set-structure":
    settings = resolve_variant_settings()
    var_name = get_variant_name()

    to_remove = [ch for ch in settings if isinstance(ch.tag, str) and local_name(ch) == "item" and etree.QName(ch.tag).namespace == SET_NS]
    for el in to_remove:
        remove_node_with_whitespace(el)

    struct_items = parse_structure_shorthand(value_arg)
    settings_indent = get_child_indent(settings)

    ref_node = find_first_element(settings, ["outputParameters", "dataParameters", "conditionalAppearance", "order", "filter", "selection", "item"], SET_NS)

    for struct_item in struct_items:
        frag_xml = build_structure_item_fragment(struct_item, settings_indent)
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(settings, node, ref_node, settings_indent)

    print(f'[OK] Structure set in variant "{var_name}": {value_arg}')

elif operation == "add-dataSetLink":
    for val in values:
        parsed = parse_data_set_link_shorthand(val)
        child_indent = get_child_indent(xml_doc)

        frag_xml = build_data_set_link_fragment(parsed, child_indent)
        nodes = import_fragment(xml_doc, frag_xml)

        last_link = find_last_element(xml_doc, "dataSetLink", SCH_NS)
        if last_link is not None:
            ref_node = None
            found = False
            for ch in xml_doc:
                if found and isinstance(ch.tag, str):
                    ref_node = ch
                    break
                if ch is last_link:
                    found = True
        else:
            ref_node = find_first_element(xml_doc, ["calculatedField", "totalField", "parameter", "template", "groupTemplate", "settingsVariant"], SCH_NS)

        for node in nodes:
            insert_before_element(xml_doc, node, ref_node, child_indent)

        desc = f"{parsed['source']} > {parsed['dest']} on {parsed['sourceExpr']} = {parsed['destExpr']}"
        if parsed.get("parameter"):
            desc += f" [param {parsed['parameter']}]"
        print(f'[OK] DataSetLink "{desc}" added')

elif operation == "add-dataSet":
    child_indent = get_child_indent(xml_doc)
    parsed = parse_data_set_shorthand(value_arg)
    parsed["query"] = resolve_query_value(parsed["query"], query_base_dir)

    if not parsed["name"]:
        count = sum(1 for ch in xml_doc if isinstance(ch.tag, str) and local_name(ch) == "dataSet" and etree.QName(ch.tag).namespace == SCH_NS)
        parsed["name"] = f"\u041d\u0430\u0431\u043e\u0440\u0414\u0430\u043d\u043d\u044b\u0445{count + 1}"

    existing = find_element_by_child_value(xml_doc, "dataSet", "name", parsed["name"], SCH_NS)
    if existing is not None:
        print(f'[WARN] DataSet "{parsed["name"]}" already exists -- skipped')
    else:
        ds_source_el = find_first_element(xml_doc, ["dataSource"], SCH_NS)
        ds_source_name = "\u0418\u0441\u0442\u043e\u0447\u043d\u0438\u043a\u0414\u0430\u043d\u043d\u044b\u04451"
        if ds_source_el is not None:
            name_el = find_first_element(ds_source_el, ["name"], SCH_NS)
            if name_el is not None:
                ds_source_name = (name_el.text or "").strip()
        parsed["dataSource"] = ds_source_name

        frag_xml = build_data_set_query_fragment(parsed, child_indent)
        nodes = import_fragment(xml_doc, frag_xml)

        last_ds = find_last_element(xml_doc, "dataSet", SCH_NS)
        if last_ds is not None:
            ref_node = None
            found = False
            for ch in xml_doc:
                if found and isinstance(ch.tag, str):
                    ref_node = ch
                    break
                if ch is last_ds:
                    found = True
        else:
            ref_node = find_first_element(xml_doc, ["dataSetLink", "calculatedField", "totalField", "parameter", "template", "groupTemplate", "settingsVariant"], SCH_NS)

        for node in nodes:
            insert_before_element(xml_doc, node, ref_node, child_indent)

        print(f'[OK] DataSet "{parsed["name"]}" added (dataSource={ds_source_name})')

elif operation == "add-variant":
    child_indent = get_child_indent(xml_doc)
    for val in values:
        parsed = parse_variant_shorthand(val)

        is_dup = False
        for ch in xml_doc:
            if isinstance(ch.tag, str) and local_name(ch) == "settingsVariant" and etree.QName(ch.tag).namespace == SCH_NS:
                for gc in ch:
                    if isinstance(gc.tag, str) and local_name(gc) == "name" and etree.QName(gc.tag).namespace == SET_NS and gc.text == parsed["name"]:
                        is_dup = True
                        break
                if is_dup:
                    break
        if is_dup:
            print(f'[WARN] Variant "{parsed["name"]}" already exists -- skipped')
            continue

        frag_xml = build_variant_fragment(parsed, child_indent)
        nodes = import_fragment(xml_doc, frag_xml)

        last_sv = find_last_element(xml_doc, "settingsVariant", SCH_NS)
        if last_sv is not None:
            ref_node = None
            found = False
            for ch in xml_doc:
                if found and isinstance(ch.tag, str):
                    ref_node = ch
                    break
                if ch is last_sv:
                    found = True
        else:
            ref_node = None

        for node in nodes:
            insert_before_element(xml_doc, node, ref_node, child_indent)

        print(f'[OK] Variant "{parsed["name"]}" ["{parsed["presentation"]}"] added')

elif operation == "add-conditionalAppearance":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        parsed = parse_conditional_appearance_shorthand(val)
        ca_el = ensure_settings_child(settings, "conditionalAppearance", ["outputParameters", "order", "filter", "selection"])
        ca_indent = get_container_child_indent(ca_el)
        frag_xml = build_conditional_appearance_item_fragment(parsed, ca_indent)
        nodes = import_fragment(xml_doc, frag_xml)
        for node in nodes:
            insert_before_element(ca_el, node, None, ca_indent)

        desc = f"{parsed['param']} = {parsed['value']}"
        if parsed.get("filter"):
            desc += f" when {parsed['filter']['field']} {parsed['filter']['op']}"
        if parsed.get("fields"):
            desc += f" for {', '.join(parsed['fields'])}"
        print(f'[OK] ConditionalAppearance "{desc}" added to variant "{var_name}"')

elif operation == "clear-selection":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    selection = find_first_element(settings, ["selection"], SET_NS)
    if selection is not None:
        clear_container_children(selection)
        print(f'[OK] Selection cleared in variant "{var_name}"')
    else:
        print(f'[INFO] No selection section in variant "{var_name}"')

elif operation == "clear-order":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    order_el = find_first_element(settings, ["order"], SET_NS)
    if order_el is not None:
        clear_container_children(order_el)
        print(f'[OK] Order cleared in variant "{var_name}"')
    else:
        print(f'[INFO] No order section in variant "{var_name}"')

elif operation == "clear-filter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    filter_el = find_first_element(settings, ["filter"], SET_NS)
    if filter_el is not None:
        clear_container_children(filter_el)
        print(f'[OK] Filter cleared in variant "{var_name}"')
    else:
        print(f'[INFO] No filter section in variant "{var_name}"')

elif operation == "modify-filter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        parsed = parse_filter_shorthand(val)
        filter_el = find_first_element(settings, ["filter"], SET_NS)
        if filter_el is None:
            print(f'[WARN] No filter section in variant "{var_name}"')
            continue

        filter_item = find_element_by_child_value(filter_el, "item", "left", parsed["field"], SET_NS)
        if filter_item is None:
            print(f'[WARN] Filter for "{parsed["field"]}" not found in variant "{var_name}"')
            continue

        item_indent = get_child_indent(filter_item)
        set_or_create_child_element(filter_item, "comparisonType", SET_NS, parsed["op"], item_indent)

        if parsed.get("value") is not None:
            vt = parsed.get("valueType", "xs:string")
            set_or_create_child_element_with_attr(filter_item, "right", SET_NS, str(parsed["value"]), vt, item_indent)

        if parsed.get("use") is False:
            set_or_create_child_element(filter_item, "use", SET_NS, "false", item_indent)
        else:
            for ch in filter_item:
                if isinstance(ch.tag, str) and local_name(ch) == "use" and etree.QName(ch.tag).namespace == SET_NS:
                    if (ch.text or "").strip() == "false":
                        remove_node_with_whitespace(ch)
                    break

        if parsed.get("viewMode"):
            set_or_create_child_element(filter_item, "viewMode", SET_NS, parsed["viewMode"], item_indent)

        if parsed.get("userSettingID"):
            uid = new_uuid() if parsed["userSettingID"] == "auto" else parsed["userSettingID"]
            set_or_create_child_element(filter_item, "userSettingID", SET_NS, uid, item_indent)

        print(f'[OK] Filter "{parsed["field"]}" modified in variant "{var_name}"')

elif operation == "modify-dataParameter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        parsed = parse_data_param_shorthand(val)
        dp_el = find_first_element(settings, ["dataParameters"], SET_NS)
        if dp_el is None:
            print(f'[WARN] No dataParameters section in variant "{var_name}"')
            continue

        dp_item = find_element_by_child_value(dp_el, "item", "parameter", parsed["parameter"], COR_NS)
        if dp_item is None:
            print(f'[WARN] DataParameter "{parsed["parameter"]}" not found in variant "{var_name}"')
            continue

        item_indent = get_child_indent(dp_item)

        if parsed.get("value") is not None:
            existing_val = None
            for ch in dp_item:
                if isinstance(ch.tag, str) and local_name(ch) == "value" and etree.QName(ch.tag).namespace == COR_NS:
                    existing_val = ch
                    break
            if existing_val is not None:
                remove_node_with_whitespace(existing_val)

            val_lines = []
            pv = parsed["value"]
            if isinstance(pv, dict) and pv.get("variant"):
                val_lines.append(f'{item_indent}<dcscor:value xsi:type="v8:StandardPeriod">')
                val_lines.append(f'{item_indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(pv["variant"])}</v8:variant>')
                val_lines.append(f"{item_indent}</dcscor:value>")
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(pv)):
                val_lines.append(f'{item_indent}<dcscor:value xsi:type="xs:dateTime">{esc_xml(str(pv))}</dcscor:value>')
            elif str(pv) in ("true", "false"):
                val_lines.append(f'{item_indent}<dcscor:value xsi:type="xs:boolean">{esc_xml(str(pv))}</dcscor:value>')
            else:
                val_lines.append(f'{item_indent}<dcscor:value xsi:type="xs:string">{esc_xml(str(pv))}</dcscor:value>')

            val_xml = "\r\n".join(val_lines)
            val_nodes = import_fragment(xml_doc, val_xml)
            for node in val_nodes:
                insert_before_element(dp_item, node, None, item_indent)

        if parsed.get("use") is False:
            set_or_create_child_element(dp_item, "use", COR_NS, "false", item_indent)
        else:
            for ch in dp_item:
                if isinstance(ch.tag, str) and local_name(ch) == "use" and etree.QName(ch.tag).namespace == COR_NS:
                    if (ch.text or "").strip() == "false":
                        remove_node_with_whitespace(ch)
                    break

        if parsed.get("viewMode"):
            set_or_create_child_element(dp_item, "viewMode", SET_NS, parsed["viewMode"], item_indent)

        if parsed.get("userSettingID"):
            uid = new_uuid() if parsed["userSettingID"] == "auto" else parsed["userSettingID"]
            set_or_create_child_element(dp_item, "userSettingID", SET_NS, uid, item_indent)

        print(f'[OK] DataParameter "{parsed["parameter"]}" modified in variant "{var_name}"')

elif operation == "modify-field":
    ds_node = resolve_data_set()
    ds_name = get_data_set_name(ds_node)
    for val in values:
        parsed = parse_field_shorthand(val)
        field_name = parsed["dataPath"]

        field_el = find_element_by_child_value(ds_node, "field", "dataPath", field_name, SCH_NS)
        if field_el is None:
            print(f'[WARN] Field "{field_name}" not found in dataset "{ds_name}"')
            continue

        existing = read_field_properties(field_el)

        merged = {
            "dataPath": existing["dataPath"],
            "field": existing["field"],
            "title": parsed["title"] if parsed.get("title") else existing["title"],
            "type": parsed["type"] if parsed.get("type") else existing["type"],
            "roles": parsed["roles"] if parsed.get("roles") else existing["roles"],
            "restrict": parsed["restrict"] if parsed.get("restrict") else existing["restrict"],
        }

        # Find next element sibling for position
        next_sib = None
        found = False
        for ch in ds_node:
            if found and isinstance(ch.tag, str):
                next_sib = ch
                break
            if ch is field_el:
                found = True

        child_indent = get_child_indent(ds_node)
        remove_node_with_whitespace(field_el)

        frag_xml = build_field_fragment(merged, child_indent)
        nodes = import_fragment(xml_doc, frag_xml)

        for node in nodes:
            insert_before_element(ds_node, node, next_sib, child_indent)

        print(f'[OK] Field "{field_name}" modified in dataset "{ds_name}"')

elif operation == "remove-field":
    ds_node = resolve_data_set()
    ds_name = get_data_set_name(ds_node)
    for val in values:
        field_name = val.strip()
        field_el = find_element_by_child_value(ds_node, "field", "dataPath", field_name, SCH_NS)
        if field_el is None:
            print(f'[WARN] Field "{field_name}" not found in dataset "{ds_name}"')
            continue
        remove_node_with_whitespace(field_el)
        print(f'[OK] Field "{field_name}" removed from dataset "{ds_name}"')

        try:
            settings = resolve_variant_settings()
            var_name = get_variant_name()
            selection = find_first_element(settings, ["selection"], SET_NS)
            if selection is not None:
                sel_item = find_element_by_child_value(selection, "item", "field", field_name, SET_NS)
                if sel_item is not None:
                    remove_node_with_whitespace(sel_item)
                    print(f'[OK] Field "{field_name}" removed from selection of variant "{var_name}"')
        except SystemExit:
            pass

elif operation == "remove-total":
    for val in values:
        data_path = val.strip()
        total_el = find_element_by_child_value(xml_doc, "totalField", "dataPath", data_path, SCH_NS)
        if total_el is None:
            print(f'[WARN] TotalField "{data_path}" not found')
            continue
        remove_node_with_whitespace(total_el)
        print(f'[OK] TotalField "{data_path}" removed')

elif operation == "remove-calculated-field":
    for val in values:
        data_path = val.strip()
        calc_el = find_element_by_child_value(xml_doc, "calculatedField", "dataPath", data_path, SCH_NS)
        if calc_el is None:
            print(f'[WARN] CalculatedField "{data_path}" not found')
            continue
        remove_node_with_whitespace(calc_el)
        print(f'[OK] CalculatedField "{data_path}" removed')

        try:
            settings = resolve_variant_settings()
            var_name = get_variant_name()
            selection = find_first_element(settings, ["selection"], SET_NS)
            if selection is not None:
                sel_item = find_element_by_child_value(selection, "item", "field", data_path, SET_NS)
                if sel_item is not None:
                    remove_node_with_whitespace(sel_item)
                    print(f'[OK] Field "{data_path}" removed from selection of variant "{var_name}"')
        except SystemExit:
            pass

elif operation == "remove-parameter":
    for val in values:
        param_name = val.strip()
        param_el = find_element_by_child_value(xml_doc, "parameter", "name", param_name, SCH_NS)
        if param_el is None:
            print(f'[WARN] Parameter "{param_name}" not found')
            continue
        remove_node_with_whitespace(param_el)
        print(f'[OK] Parameter "{param_name}" removed')

elif operation == "remove-filter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        field_name = val.strip()
        filter_el = find_first_element(settings, ["filter"], SET_NS)
        if filter_el is None:
            print(f'[WARN] No filter section in variant "{var_name}"')
            continue
        filter_item = find_element_by_child_value(filter_el, "item", "left", field_name, SET_NS)
        if filter_item is None:
            print(f'[WARN] Filter for "{field_name}" not found in variant "{var_name}"')
            continue
        remove_node_with_whitespace(filter_item)
        print(f'[OK] Filter for "{field_name}" removed from variant "{var_name}"')

# ── 9. Save ─────────────────────────────────────────────────

xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
xml_bytes = xml_bytes.replace(b"encoding='UTF-8'", b'encoding="UTF-8"')
with open(resolved_path, "wb") as f:
    f.write(b'\xef\xbb\xbf')
    f.write(xml_bytes)

print(f"[OK] Saved {resolved_path}")
