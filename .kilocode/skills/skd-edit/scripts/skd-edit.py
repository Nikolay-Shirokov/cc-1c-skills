# skd-edit v1.30 — Atomic 1C DCS editor (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# Dirty flag — set to True by every successful mutation. If still False at save time,
# the file is left untouched (NO-OP operations like [WARN] not found don't rewrite).
dirty = False

# ── arg parsing ──────────────────────────────────────────────

VALID_OPS = [
    "add-field", "add-total", "add-calculated-field", "add-parameter", "add-filter",
    "add-dataParameter", "add-order", "add-selection", "add-dataSetLink",
    "add-dataSet", "add-variant", "add-conditionalAppearance", "add-drilldown",
    "set-query", "patch-query", "set-outputParameter", "set-structure",
    "modify-field", "modify-filter", "modify-dataParameter", "modify-parameter", "modify-structure", "set-field-role",
    "rename-parameter", "reorder-parameters",
    "clear-selection", "clear-order", "clear-filter", "clear-conditionalAppearance",
    "remove-field", "remove-total", "remove-calculated-field", "remove-parameter", "remove-filter",
]

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-TemplatePath", "-Path", required=True)
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
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


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


# ============================================================
# Support guard (Ext/ParentConfigurations.bin) — see docs/1c-support-state-spec.md
# Blocks edits of vendor objects "на замке" / read-only configs. Trigger = bin
# present; reaction from .v8-project.json editingAllowedCheck (deny|warn|off,
# default deny). Never throws (except sys.exit on deny) — errors degrade to allow.
# ============================================================

def _sg_root_uuid(xml_path):
    if not os.path.isfile(xml_path):
        return None
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str) and child.get("uuid"):
                return child.get("uuid")
    except Exception:
        return None
    return None


def _sg_is_external_root(xml_path):
    if not os.path.isfile(xml_path):
        return False
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str):
                return child.tag.split("}")[-1] in ("ExternalDataProcessor", "ExternalReport")
    except Exception:
        return False
    return False

def _sg_find_v8project(start_dir):
    d = start_dir
    for _ in range(20):
        if not d:
            break
        pj = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pj):
            return pj
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def _sg_get_edit_mode(cfg_dir):
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(cfg_dir)
        if not pj:
            return "deny"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir)).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src:
                src_full = os.path.normcase(os.path.abspath(src)).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    if db.get("editingAllowedCheck"):
                        return db["editingAllowedCheck"]
        if proj.get("editingAllowedCheck"):
            return proj["editingAllowedCheck"]
        return "deny"
    except Exception:
        return "deny"


def assert_edit_allowed(target_path, require):
    try:
        rp = os.path.abspath(target_path)
        # Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
        if _sg_is_external_root(rp):
            return
        elem_uuid = _sg_root_uuid(rp)
        cfg_dir = None
        bin_path = None
        d = rp if os.path.isdir(rp) else os.path.dirname(rp)
        for _ in range(12):
            if not d:
                break
            if _sg_is_external_root(d + ".xml"):
                return
            if not elem_uuid:
                elem_uuid = _sg_root_uuid(d + ".xml")
            if not cfg_dir:
                cand = os.path.join(d, "Ext", "ParentConfigurations.bin")
                if os.path.exists(cand) or os.path.exists(os.path.join(d, "Configuration.xml")):
                    cfg_dir = d
                    bin_path = cand
            if elem_uuid and cfg_dir:
                break
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
        if not elem_uuid and cfg_dir:
            elem_uuid = _sg_root_uuid(os.path.join(cfg_dir, "Configuration.xml"))
        if not bin_path or not os.path.exists(bin_path):
            return
        data = open(bin_path, "rb").read()
        if len(data) <= 32:
            return
        if data[:3] == b"\xef\xbb\xbf":
            data = data[3:]
        text = data.decode("utf-8", "replace")
        h = re.match(r"\{6,(\d+),(\d+),", text)
        if not h:
            return
        g = int(h.group(1))
        k = int(h.group(2))
        if k == 0:
            return
        best = None
        if elem_uuid:
            for m in re.finditer(r"([0-2]),0," + re.escape(elem_uuid.lower()), text):
                f1 = int(m.group(1))
                if best is None or f1 < best:
                    best = f1
        blocked = False
        code = ""
        reason = ""
        if g == 1:
            blocked = True
            code = "capability-off"
            reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)"
        elif require == "removed":
            if best is not None and best != 2:
                blocked = True
                code = "not-removed"
                reason = "объект не снят с поддержки — удаление сломает обновления"
        else:
            if best is not None and best == 0:
                blocked = True
                code = "locked"
                reason = "объект на замке — редактирование сломает обновления"
        if not blocked:
            return
        mode = _sg_get_edit_mode(cfg_dir)
        if mode == "off":
            return
        if mode == "warn":
            sys.stderr.write(f"[support-guard] ПРЕДУПРЕЖДЕНИЕ: {reason}. Цель: {rp}\n")
            return
        head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
        cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
        off_note = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
        if code == "capability-off":
            state = f"Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «{rp}» редактировать нельзя."
            fix = (
                "Либо снять защиту явно (навык support-edit, два шага):\n"
                f'  1. support-edit -Path "{cfg_dir}" -Capability on — включить возможность изменения (объекты пока остаются на замке);\n'
                f'  2. support-edit -Path "{rp}" -Set editable — открыть этот объект для редактирования.\n'
                "  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
            )
        elif code == "not-removed":
            state = f"Состояние: объект «{rp}» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
            fix = (
                "Либо сначала снять объект с поддержки, затем удалять:\n"
                f'  support-edit -Path "{rp}" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно.'
            )
        else:
            state = f"Состояние: объект «{rp}» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
            fix = (
                "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):\n"
                f'  support-edit -Path "{rp}" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);\n'
                f'  support-edit -Path "{rp}" -Set off-support — снять с поддержки: обновления по объекту больше не приходят.'
            )
        sys.stderr.write(head + "\n" + state + "\n" + cfe + "\n" + fix + "\n" + off_note + "\n")
        sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        return


assert_edit_allowed(resolved_path, "editable")

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
    props = {"dataPath": "", "field": "", "title": "", "type": "", "roles": [], "restrict": [], "_rawTypeText": "",
             "_rawTitle": None, "_unknownChildren": []}

    for ch in field_el:
        if not isinstance(ch.tag, str):
            continue
        ln = local_name(ch)
        if ln == "dataPath":
            props["dataPath"] = (ch.text or "").strip()
        elif ln == "field":
            props["field"] = (ch.text or "").strip()
        elif ln == "title":
            # Preserve full multi-lang title OuterXml; also extract ru content for compat.
            raw = etree.tostring(ch, encoding="unicode", with_tail=False)
            raw = re.sub(r' xmlns(?::\w+)?="[^"]*"', "", raw)
            props["_rawTitle"] = raw
            for item in ch:
                if isinstance(item.tag, str) and local_name(item) == "item":
                    lang = None
                    content = None
                    for gc in item:
                        if isinstance(gc.tag, str) and local_name(gc) == "lang":
                            lang = (gc.text or "").strip()
                        if isinstance(gc.tag, str) and local_name(gc) == "content":
                            content = (gc.text or "").strip()
                    if lang == "ru" and content is not None:
                        props["title"] = content
        elif ln == "valueType":
            # Preserve full <valueType> serialization so rebuild can re-emit qualifiers
            # (StringQualifiers, NumberQualifiers, DateQualifiers, …) that aren't
            # expressible via shorthand. Strip xmlns declarations that lxml re-emits when
            # serializing a sub-element (parent context already provides them).
            raw = etree.tostring(ch, encoding="unicode", with_tail=False)
            raw = re.sub(r' xmlns(?::\w+)?="[^"]*"', "", raw)
            props["_rawValueType"] = raw
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
        else:
            # Defense in depth: preserve OuterXml of unknown children so rebuild
            # doesn't silently drop them (custom <editFormat>, <appearance>, etc.).
            raw = etree.tostring(ch, encoding="unicode", with_tail=False)
            raw = re.sub(r' xmlns(?::\w+)?="[^"]*"', "", raw)
            props["_unknownChildren"].append(raw)
    return props


def parse_total_shorthand(s):
    # "DataPath: Func" or "DataPath: Func(expr)" or "DataPath: ИмяРесурса" (identity)
    parts = s.split(":", 1)
    data_path = parts[0].strip()
    func_part = parts[1].strip()

    agg_funcs = {'Сумма', 'Количество', 'Минимум', 'Максимум', 'Среднее',
                 'Sum', 'Count', 'Min', 'Max', 'Avg',
                 'Minimum', 'Maximum', 'Average'}

    if re.match(r'^\w+\(', func_part):
        return {"dataPath": data_path, "expression": func_part}
    elif func_part in agg_funcs:
        return {"dataPath": data_path, "expression": f"{func_part}({data_path})"}
    else:
        return {"dataPath": data_path, "expression": func_part}


def parse_calc_shorthand(s):
    # Pattern: "Name [Title]: type = Expression #noField #noFilter ...".
    # - `[Title]` is extracted only from the LHS of '=' so that `[...]` inside
    #   an expression (e.g. index access) isn't interpreted as a title.
    # - `#restrict` flags use a known-names pattern and are extracted globally —
    #   the docs put them after `=`, and the closed flag set avoids matching
    #   `#word` that happens to appear inside a string literal.
    restrict_pattern = r'#(noField|noFilter|noCondition|noGroup|noOrder)\b'

    restrict_matches = re.findall(restrict_pattern, s)
    s = re.sub(r'\s*' + restrict_pattern, '', s)

    eq_idx = s.find("=")
    if eq_idx > 0:
        lhs = s[:eq_idx]
        rhs = s[eq_idx + 1:].strip()
        has_rhs = True
    else:
        lhs = s
        rhs = ""
        has_rhs = False

    title = ""
    m = re.search(r'\[([^\]]+)\]', lhs)
    if m:
        title = m.group(1)
        lhs = re.sub(r'\s*\[[^\]]+\]', '', lhs)
    lhs = lhs.strip()

    if has_rhs:
        if ":" in lhs:
            colon_idx = lhs.index(":")
            data_path = lhs[:colon_idx].strip()
            type_str = resolve_type_str(lhs[colon_idx + 1:].strip())
            return {"dataPath": data_path, "expression": rhs, "type": type_str, "title": title, "restrict": restrict_matches}
        return {"dataPath": lhs, "expression": rhs, "type": "", "title": title, "restrict": restrict_matches}
    return {"dataPath": lhs, "expression": "", "type": "", "title": title, "restrict": restrict_matches}


def parse_param_shorthand(s):
    result = {"name": "", "type": "", "value": None, "autoDates": False, "title": None, "hidden": False, "always": False, "availableValues": [], "valueListAllowed": False}

    # Extract availableValue=... (must be before main parse — captures to end of string)
    m_av = re.search(r'\s*availableValue=(.+)$', s)
    if m_av:
        result["availableValues"] = parse_available_value_list(m_av.group(1).strip())
        s = re.sub(r'\s*availableValue=.+$', '', s).strip()

    if re.search(r'@autoDates', s):
        result["autoDates"] = True
        s = re.sub(r'\s*@autoDates', '', s)

    if re.search(r'@valueList\b', s):
        result["valueListAllowed"] = True
        s = re.sub(r'\s*@valueList\b', '', s)

    if re.search(r'@hidden\b', s):
        result["hidden"] = True
        s = re.sub(r'\s*@hidden\b', '', s)

    if re.search(r'@always\b', s):
        result["always"] = True
        s = re.sub(r'\s*@always\b', '', s)

    # Extract optional [Title] (mirrors parse_field_shorthand)
    m = re.search(r'\[([^\]]*)\]', s)
    if m:
        result["title"] = m.group(1).strip()
        s = re.sub(r'\s*\[[^\]]*\]\s*', ' ', s).strip()

    # Allow empty RHS (`= ` / `=`) as empty-value sentinel
    m = re.match(r'^([^:]+):\s*(\S+)(\s*=\s*(.*))?$', s)
    if m:
        result["name"] = m.group(1).strip()
        result["type"] = resolve_type_str(m.group(2).strip())
        if m.group(3) is not None:
            rhs = m.group(4)
            if rhs and rhs.strip():
                items = parse_value_list(rhs.strip())
                if len(items) >= 2:
                    # Multi-value default → list; valueListAllowed implied
                    result["value"] = items
                    result["valueListAllowed"] = True
                else:
                    # Scalar (single item, quotes stripped) or empty sentinel
                    result["value"] = items[0] if len(items) == 1 else ""
            else:
                result["value"] = ""
    else:
        result["name"] = s.strip()

    return result


def parse_filter_shorthand(s):
    # use is tristate: None = not specified (modify-* won't touch),
    # False = @off (explicit), True = @on (explicit). add-* writes <use>false</use> only when False.
    result = {"field": "", "op": "Equal", "value": None, "use": None, "userSettingID": None, "viewMode": None}

    if re.search(r'@user', s):
        result["userSettingID"] = "auto"
        s = re.sub(r'\s*@user', '', s)
    if re.search(r'@off', s):
        result["use"] = False
        s = re.sub(r'\s*@off', '', s)
    if re.search(r'@on\b', s):
        result["use"] = True
        s = re.sub(r'\s*@on\b', '', s)
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
            elif re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.', val_part):
                result["value"] = val_part
                result["valueType"] = "dcscor:DesignTimeValue"
            else:
                result["value"] = val_part
                result["valueType"] = "xs:string"
    else:
        result["field"] = s

    return result


def parse_data_param_shorthand(s):
    # use is tristate: None = not specified (modify-* won't touch),
    # False = @off (explicit), True = @on (explicit). add-* writes <use>false</use> only when False.
    result = {"parameter": "", "value": None, "use": None, "userSettingID": None, "viewMode": None}

    if re.search(r'@user', s):
        result["userSettingID"] = "auto"
        s = re.sub(r'\s*@user', '', s)
    if re.search(r'@off', s):
        result["use"] = False
        s = re.sub(r'\s*@off', '', s)
    if re.search(r'@on\b', s):
        result["use"] = True
        s = re.sub(r'\s*@on\b', '', s)
    if re.search(r'@quickAccess', s):
        result["viewMode"] = "QuickAccess"
        s = re.sub(r'\s*@quickAccess', '', s)
    if re.search(r'@normal', s):
        result["viewMode"] = "Normal"
        s = re.sub(r'\s*@normal', '', s)

    s = s.strip()

    m = re.match(r'^([^=]+)=\s*(.*)$', s)
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
        # Empty / sentinel — record as "" so caller emits xsi:nil
        if val_str == "" or val_str == "_" or val_str.lower() == "null":
            result["value"] = ""
        elif val_str in period_variants:
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
    if len(parts) > 1 and re.match(r'^desc$', parts[1], re.IGNORECASE):
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
        or_parts = re.split(r'\s+or\s+', when_part)
        if len(or_parts) > 1:
            result["filter"] = [parse_filter_shorthand(p.strip()) for p in or_parts]
        else:
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

        name_m = re.search(r'@name=(?:"([^"]+)"|\'([^\']+)\'|(\S+))', seg)
        if name_m:
            raw_name = name_m.group(1) or name_m.group(2) or name_m.group(3)
            group["name"] = raw_name.strip()
            seg = re.sub(r'\s*@name=(?:"[^"]+"|\'[^\']+\'|\S+)', '', seg).strip()

        if re.match(r'^(details|\u0434\u0435\u0442\u0430\u043b\u0438)$', seg, re.IGNORECASE):
            group["groupBy"] = []
        else:
            fields = [f.strip() for f in re.split(r'\s*,\s*', seg) if f.strip()]
            group["groupBy"] = fields

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


def split_quoted_csv(s):
    """Split on top-level commas, respecting single/double quoted spans.
    Returns raw (un-stripped) item spans. Shared by availableValue and value-list parsing."""
    items = []
    if s is None:
        return items
    buf = []
    in_quote = None
    for ch in s:
        if in_quote:
            buf.append(ch)
            if ch == in_quote:
                in_quote = None
        elif ch in ("'", '"'):
            in_quote = ch
            buf.append(ch)
        elif ch == ',':
            items.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        items.append("".join(buf))
    return items


def strip_quotes(t):
    """Strip a single surrounding pair of matching quotes; trims first."""
    t = t.strip()
    if len(t) >= 2 and ((t[0] == "'" and t[-1] == "'") or (t[0] == '"' and t[-1] == '"')):
        return t[1:-1]
    return t


def parse_value_list(s):
    """Return list of value strings (quotes stripped) split by top-level commas.
    No ':' handling — values may contain colons (e.g. dateTime 2024-01-01T12:30:00)."""
    if s is None:
        return []
    result = []
    for raw in split_quoted_csv(s):
        v = strip_quotes(raw)
        if v != "":
            result.append(v)
    return result


def parse_available_value_list(s):
    """Returns list of {value, presentation} from comma-separated list.
    Items can use single/double quotes (stripped). Quoted spans preserve commas/colons."""
    if not s:
        return []

    items = split_quoted_csv(s)

    result = []
    for raw in items:
        item = raw.strip()
        if not item:
            continue
        # Find first ':' outside quotes
        colon_idx = -1
        q = None
        for j, c in enumerate(item):
            if q:
                if c == q:
                    q = None
            elif c in ("'", '"'):
                q = c
            elif c == ':':
                colon_idx = j
                break
        if colon_idx >= 0:
            val_part = item[:colon_idx]
            pres_part = item[colon_idx + 1:]
            result.append({"value": strip_quotes(val_part), "presentation": strip_quotes(pres_part)})
        else:
            result.append({"value": strip_quotes(item), "presentation": ""})
    return result


def build_available_value_fragment(item, declared_type, indent):
    """Return XML lines for a single <availableValue> block."""
    lines = [f"{indent}<availableValue>"]
    if is_empty_value(item.get("value")):
        empty_xml = build_empty_value_xml(declared_type, f"{indent}\t", "", "value", False)
        if empty_xml:
            lines.append(empty_xml)
    else:
        for vl in build_param_value_xml(declared_type, item["value"], f"{indent}\t"):
            lines.append(vl)
    if item.get("presentation"):
        lines.append(f'{indent}\t<presentation xsi:type="v8:LocalStringType">')
        lines.append(f"{indent}\t\t<v8:item>")
        lines.append(f"{indent}\t\t\t<v8:lang>ru</v8:lang>")
        lines.append(f"{indent}\t\t\t<v8:content>{esc_xml(item['presentation'])}</v8:content>")
        lines.append(f"{indent}\t\t</v8:item>")
        lines.append(f"{indent}\t</presentation>")
    lines.append(f"{indent}</availableValue>")
    return lines


# ── 4. Build-* functions (XML fragment generators) ──────────

def build_value_type_xml(type_str, indent):
    if not type_str:
        return ""

    # Composite: list/tuple → concatenate per-type fragments
    if isinstance(type_str, (list, tuple)):
        parts = []
        for t in type_str:
            p = build_value_type_xml(str(t), indent)
            if p:
                parts.append(p)
        return "\n".join(parts)

    type_str = resolve_type_str(str(type_str))
    lines = []

    if type_str == "boolean":
        lines.append(f"{indent}<v8:Type>xs:boolean</v8:Type>")
        return "\n".join(lines)

    # string, string(N), string(N,fix) — fix → AllowedLength=Fixed
    m = re.match(r'^string(\((\d+)(,(fix|fixed))?\))?$', type_str)
    if m:
        length = m.group(2) if m.group(2) else "0"
        al = "Fixed" if m.group(4) else "Variable"
        lines.append(f"{indent}<v8:Type>xs:string</v8:Type>")
        lines.append(f"{indent}<v8:StringQualifiers>")
        lines.append(f"{indent}\t<v8:Length>{length}</v8:Length>")
        lines.append(f"{indent}\t<v8:AllowedLength>{al}</v8:AllowedLength>")
        lines.append(f"{indent}</v8:StringQualifiers>")
        return "\n".join(lines)

    # decimal — bare = 10,2; decimal(N) = N,0
    m = re.match(r'^decimal(\((\d+)(,(\d+))?(,nonneg)?\))?$', type_str)
    if m:
        if not m.group(1):
            digits, fraction, sign = "10", "2", "Any"
        else:
            digits = m.group(2)
            fraction = m.group(4) if m.group(4) else "0"
            sign = "Nonnegative" if m.group(5) else "Any"
        lines.append(f"{indent}<v8:Type>xs:decimal</v8:Type>")
        lines.append(f"{indent}<v8:NumberQualifiers>")
        lines.append(f"{indent}\t<v8:Digits>{digits}</v8:Digits>")
        lines.append(f"{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>")
        lines.append(f"{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>")
        lines.append(f"{indent}</v8:NumberQualifiers>")
        return "\n".join(lines)

    # date / dateTime / time — all xs:dateTime
    m = re.match(r'^(date|dateTime|time)$', type_str)
    if m:
        fractions = {"date": "Date", "dateTime": "DateTime", "time": "Time"}[type_str]
        lines.append(f"{indent}<v8:Type>xs:dateTime</v8:Type>")
        lines.append(f"{indent}<v8:DateQualifiers>")
        lines.append(f"{indent}\t<v8:DateFractions>{fractions}</v8:DateFractions>")
        lines.append(f"{indent}</v8:DateQualifiers>")
        return "\n".join(lines)

    if type_str == "StandardPeriod":
        lines.append(f"{indent}<v8:Type>v8:StandardPeriod</v8:Type>")
        return "\n".join(lines)

    if re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.', type_str):
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return "\n".join(lines)

    if "." in type_str:
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return "\n".join(lines)

    lines.append(f"{indent}<v8:Type>{esc_xml(type_str)}</v8:Type>")
    return "\n".join(lines)


def is_empty_value(v):
    """Empty sentinel — None / '' / '_' / 'null' (case-insensitive)."""
    if v is None:
        return True
    s = str(v).strip()
    if s == "":
        return True
    if s == "_":
        return True
    if s.lower() == "null":
        return True
    return False


def build_empty_value_xml(type_str, indent, tag_prefix="", tag_name="value", value_list_allowed=False):
    """Type-aware empty <value> fragment. Returns None when valueListAllowed (omit)."""
    if value_list_allowed:
        return None
    t = "" if type_str is None else str(type_str)
    # Strip well-known XML schema prefixes so callers can pass raw <v8:Type> text
    t = re.sub(r'^xs:', '', t)
    t = re.sub(r'^v8:', '', t)
    t = re.sub(r'^d\d+p\d+:', '', t)
    pf, tn = tag_prefix, tag_name
    lines = []
    if t == "":
        lines.append(f'{indent}<{pf}{tn} xsi:nil="true"/>')
    elif t == "StandardPeriod":
        lines.append(f'{indent}<{pf}{tn} xsi:type="v8:StandardPeriod">')
        lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">Custom</v8:variant>')
        lines.append(f'{indent}\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>')
        lines.append(f'{indent}\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>')
        lines.append(f'{indent}</{pf}{tn}>')
    elif re.match(r'^string', t):
        lines.append(f'{indent}<{pf}{tn} xsi:type="xs:string"/>')
    elif re.match(r'^(date|time)', t):
        lines.append(f'{indent}<{pf}{tn} xsi:type="xs:dateTime">0001-01-01T00:00:00</{pf}{tn}>')
    elif re.match(r'^decimal', t):
        lines.append(f'{indent}<{pf}{tn} xsi:type="xs:decimal">0</{pf}{tn}>')
    elif t == "boolean":
        lines.append(f'{indent}<{pf}{tn} xsi:type="xs:boolean">false</{pf}{tn}>')
    else:
        lines.append(f'{indent}<{pf}{tn} xsi:nil="true"/>')
    return "\n".join(lines)


def build_mltext_xml(tag, text, indent):
    lines = [
        f'{indent}<{tag} xsi:type="v8:LocalStringType">',
        f"{indent}\t<v8:item>",
        f"{indent}\t\t<v8:lang>ru</v8:lang>",
        f"{indent}\t\t<v8:content>{esc_xml(text)}</v8:content>",
        f"{indent}\t</v8:item>",
        f"{indent}</{tag}>",
    ]
    return "\n".join(lines)


def patch_mltext_ru(raw_outer_xml, new_ru_text, indent):
    """Patch the ru <v8:content> within an existing multi-lang title OuterXml,
    preserving en/uk/etc. siblings. Mirrors PS Patch-MLTextRu."""
    escaped = esc_xml(new_ru_text)
    ru_item_pat = r"(<v8:item>\s*<v8:lang>ru</v8:lang>\s*<v8:content>)[^<]*(</v8:content>\s*</v8:item>)"
    if re.search(ru_item_pat, raw_outer_xml):
        return re.sub(ru_item_pat, lambda m: m.group(1) + escaped + m.group(2), raw_outer_xml)
    prep = f"{indent}\t<v8:item>\n{indent}\t\t<v8:lang>ru</v8:lang>\n{indent}\t\t<v8:content>{escaped}</v8:content>\n{indent}\t</v8:item>"
    if "<v8:item>" in raw_outer_xml:
        return re.sub(r"(\s*)<v8:item>", lambda m: "\n" + prep + m.group(1) + "<v8:item>", raw_outer_xml, count=1)
    return re.sub(r"(<(?:\w+:)?title[^>]*>)", lambda m: m.group(1) + "\n" + prep + "\n" + indent, raw_outer_xml, count=1)


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
    return "\n".join(lines)


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
    return "\n".join(lines)


def build_field_fragment(parsed, indent):
    i = indent
    lines = [f'{i}<field xsi:type="DataSetFieldField">']
    lines.append(f"{i}\t<dataPath>{esc_xml(parsed['dataPath'])}</dataPath>")
    lines.append(f"{i}\t<field>{esc_xml(parsed['field'])}</field>")

    # Title: prefer raw multi-lang OuterXml (preserves en/uk/etc.). When shorthand
    # provides a new ru text different from existing, patch the ru content. Otherwise
    # emit raw as-is or build ru-only from shorthand if there was no prior title.
    if parsed.get("_rawTitle"):
        if parsed.get("title") and parsed["title"] != parsed.get("_existingTitleRu"):
            lines.append(f"{i}\t" + patch_mltext_ru(parsed["_rawTitle"], parsed["title"], f"{i}\t"))
        else:
            lines.append(f"{i}\t" + parsed["_rawTitle"])
    elif parsed.get("title"):
        lines.append(build_mltext_xml("title", parsed["title"], f"{i}\t"))

    if parsed.get("restrict"):
        lines.append(build_restriction_xml(parsed["restrict"], f"{i}\t"))

    role_xml = build_role_xml(parsed.get("roles"), f"{i}\t")
    if role_xml:
        lines.append(role_xml)

    if parsed.get("rawValueType"):
        # Preserve original <valueType> verbatim — keeps qualifiers (StringQualifiers,
        # NumberQualifiers, DateQualifiers, …) that aren't expressible via shorthand.
        lines.append(f"{i}\t" + parsed["rawValueType"])
    elif parsed.get("type"):
        lines.append(f"{i}\t<valueType>")
        lines.append(build_value_type_xml(parsed["type"], f"{i}\t\t"))
        lines.append(f"{i}\t</valueType>")

    # Defense in depth: re-emit OuterXml of unknown children captured by Read.
    for raw in (parsed.get("_unknownChildren") or []):
        lines.append(f"{i}\t" + raw)

    lines.append(f"{i}</field>")
    return "\n".join(lines)


def build_total_fragment(parsed, indent):
    i = indent
    lines = [
        f"{i}<totalField>",
        f"{i}\t<dataPath>{esc_xml(parsed['dataPath'])}</dataPath>",
        f"{i}\t<expression>{esc_xml(parsed['expression'])}</expression>",
        f"{i}</totalField>",
    ]
    return "\n".join(lines)


def build_calc_field_fragment(parsed, indent):
    i = indent
    lines = [
        f"{i}<calculatedField>",
        f"{i}\t<dataPath>{esc_xml(parsed['dataPath'])}</dataPath>",
        f"{i}\t<expression>{esc_xml(parsed['expression'])}</expression>",
    ]
    if parsed.get("title"):
        lines.append(build_mltext_xml("title", parsed["title"], f"{i}\t"))
    if parsed.get("restrict"):
        lines.append(build_restriction_xml(parsed["restrict"], f"{i}\t"))
    if parsed.get("type"):
        lines.append(f"{i}\t<valueType>")
        lines.append(build_value_type_xml(parsed["type"], f"{i}\t\t"))
        lines.append(f"{i}\t</valueType>")
    lines.append(f"{i}</calculatedField>")
    return "\n".join(lines)


def build_param_value_xml(type_str, value, indent, tag_name="value", tag_ns=""):
    """Return list of XML lines for <value xsi:type=...>...</value>."""
    val_str = "" if value is None else str(value)
    open_tag = f"{tag_ns}:{tag_name}" if tag_ns else tag_name
    lines = []

    if type_str == "StandardPeriod":
        lines.append(f'{indent}<{open_tag} xsi:type="v8:StandardPeriod">')
        lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(val_str)}</v8:variant>')
        lines.append(f"{indent}\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>")
        lines.append(f"{indent}\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>")
        lines.append(f"{indent}</{open_tag}>")
        return lines

    t = type_str or ""
    xsi = None
    if t.startswith("date"):
        xsi = "xs:dateTime"
    elif t == "boolean":
        xsi = "xs:boolean"
    elif t.startswith("decimal"):
        xsi = "xs:decimal"
    elif t.startswith("string"):
        xsi = "xs:string"
    elif re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef)\.', t):
        xsi = "dcscor:DesignTimeValue"
    else:
        if re.match(r'^\d{4}-\d{2}-\d{2}T', val_str):
            xsi = "xs:dateTime"
        elif val_str in ("true", "false"):
            xsi = "xs:boolean"
        elif re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.', val_str) or \
             re.match(r'^(Catalog|Document|Enum|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', val_str):
            xsi = "dcscor:DesignTimeValue"
        else:
            xsi = "xs:string"

    lines.append(f'{indent}<{open_tag} xsi:type="{xsi}">{esc_xml(val_str)}</{open_tag}>')
    return lines


def build_param_fragment(parsed, indent):
    i = indent
    fragments = []

    lines = [f"{i}<parameter>", f"{i}\t<name>{esc_xml(parsed['name'])}</name>"]

    if parsed.get("title"):
        lines.append(build_mltext_xml("title", parsed["title"], f"{i}\t"))

    if parsed.get("type"):
        lines.append(f"{i}\t<valueType>")
        lines.append(build_value_type_xml(parsed["type"], f"{i}\t\t"))
        lines.append(f"{i}\t</valueType>")

    vla = bool(parsed.get("valueListAllowed"))
    if isinstance(parsed["value"], list):
        # Multi-value default (value-list): one <value> per item
        for v in parsed["value"]:
            for vl in build_param_value_xml(parsed.get("type", ""), v, f"{i}\t"):
                lines.append(vl)
    elif parsed["value"] is not None:
        if is_empty_value(parsed["value"]):
            empty_xml = build_empty_value_xml(parsed.get("type", ""), f"{i}\t", "", "value", vla)
            if empty_xml:
                lines.append(empty_xml)
        else:
            for vl in build_param_value_xml(parsed.get("type", ""), parsed["value"], f"{i}\t"):
                lines.append(vl)

    if parsed.get("hidden"):
        lines.append(f"{i}\t<useRestriction>true</useRestriction>")
        lines.append(f"{i}\t<availableAsField>false</availableAsField>")

    if vla:
        lines.append(f"{i}\t<valueListAllowed>true</valueListAllowed>")

    for av in parsed.get("availableValues", []) or []:
        for l in build_available_value_fragment(av, parsed.get("type", ""), f"{i}\t"):
            lines.append(l)

    if parsed.get("always"):
        lines.append(f"{i}\t<use>Always</use>")

    lines.append(f"{i}</parameter>")
    fragments.append("\n".join(lines))

    if parsed.get("autoDates"):
        param_name = parsed["name"]
        # Canonical БСП pattern: title + valueType + value + useRestriction + expression
        # NB: expr автодат собираем в переменную (не в f-string): бэкслеш в \uXXXX
        # внутри {} f-строки — SyntaxError на python < 3.12 (PEP 701). Совместимость с 3.9.
        expr_start = esc_xml('&' + param_name + '.\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430')
        b_lines = [
            f"{i}<parameter>",
            f"{i}\t<name>\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430</name>",
            build_mltext_xml("title", "\u041d\u0430\u0447\u0430\u043b\u043e \u043f\u0435\u0440\u0438\u043e\u0434\u0430", f"{i}\t"),
            f"{i}\t<valueType>",
            build_value_type_xml("date", f"{i}\t\t"),
            f"{i}\t</valueType>",
            f'{i}\t<value xsi:type="xs:dateTime">0001-01-01T00:00:00</value>',
            f"{i}\t<useRestriction>true</useRestriction>",
            f"{i}\t<expression>{expr_start}</expression>",
            f"{i}</parameter>",
        ]
        fragments.append("\n".join(b_lines))

        expr_end = esc_xml('&' + param_name + '.\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f')
        e_lines = [
            f"{i}<parameter>",
            f"{i}\t<name>\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f</name>",
            build_mltext_xml("title", "\u041a\u043e\u043d\u0435\u0446 \u043f\u0435\u0440\u0438\u043e\u0434\u0430", f"{i}\t"),
            f"{i}\t<valueType>",
            build_value_type_xml("date", f"{i}\t\t"),
            f"{i}\t</valueType>",
            f'{i}\t<value xsi:type="xs:dateTime">0001-01-01T00:00:00</value>',
            f"{i}\t<useRestriction>true</useRestriction>",
            f"{i}\t<expression>{expr_end}</expression>",
            f"{i}</parameter>",
        ]
        fragments.append("\n".join(e_lines))

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
    return "\n".join(lines)


def build_selection_item_fragment(field_name, indent):
    i = indent
    if field_name == "Auto":
        return f'{i}<dcsset:item xsi:type="dcsset:SelectedItemAuto"/>'
    m = re.match(r'^Folder\((.+)\)$', field_name)
    if m:
        inner = m.group(1)
        colon_idx = inner.find(':')
        if colon_idx > 0:
            title = inner[:colon_idx].strip()
            items = [x.strip() for x in inner[colon_idx + 1:].split(',') if x.strip()]
        else:
            title = ""
            items = [x.strip() for x in inner.split(',') if x.strip()]
        lines = [f'{i}<dcsset:item xsi:type="dcsset:SelectedItemFolder">']
        if title:
            lines.append(f"{i}\t<dcsset:lwsTitle>")
            lines.append(f"{i}\t\t<v8:item>")
            lines.append(f"{i}\t\t\t<v8:lang>ru</v8:lang>")
            lines.append(f"{i}\t\t\t<v8:content>{esc_xml(title)}</v8:content>")
            lines.append(f"{i}\t\t</v8:item>")
            lines.append(f"{i}\t</dcsset:lwsTitle>")
        for item in items:
            lines.append(f'{i}\t<dcsset:item xsi:type="dcsset:SelectedItemField">')
            lines.append(f"{i}\t\t<dcsset:field>{esc_xml(item)}</dcsset:field>")
            lines.append(f"{i}\t</dcsset:item>")
        lines.append(f"{i}\t<dcsset:placement>Auto</dcsset:placement>")
        lines.append(f"{i}</dcsset:item>")
        return "\n".join(lines)
    lines = [
        f'{i}<dcsset:item xsi:type="dcsset:SelectedItemField">',
        f"{i}\t<dcsset:field>{esc_xml(field_name)}</dcsset:field>",
        f"{i}</dcsset:item>",
    ]
    return "\n".join(lines)


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
            lines.append(f"{i}\t\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>")
            lines.append(f"{i}\t\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>")
            lines.append(f"{i}\t</dcscor:value>")
        elif is_empty_value(val):
            lines.append(f'{i}\t<dcscor:value xsi:nil="true"/>')
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
    return "\n".join(lines)


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
    return "\n".join(lines)


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
    return "\n".join(lines)


def build_data_set_query_fragment(parsed, indent):
    i = indent
    lines = [
        f'{i}<dataSet xsi:type="DataSetQuery">',
        f"{i}\t<name>{esc_xml(parsed['name'])}</name>",
        f"{i}\t<dataSource>{esc_xml(parsed['dataSource'])}</dataSource>",
        f"{i}\t<query>{esc_xml(parsed['query'])}</query>",
        f"{i}</dataSet>",
    ]
    return "\n".join(lines)


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
    return "\n".join(lines)


def _emit_filter_comparison(lines, f, indent):
    lines.append(f'{indent}<dcsset:item xsi:type="dcsset:FilterItemComparison">')
    lines.append(f'{indent}\t<dcsset:left xsi:type="dcscor:Field">{esc_xml(f["field"])}</dcsset:left>')
    lines.append(f"{indent}\t<dcsset:comparisonType>{esc_xml(f['op'])}</dcsset:comparisonType>")
    if f.get("value") is not None:
        vt = f.get("valueType", "xs:string")
        lines.append(f'{indent}\t<dcsset:right xsi:type="{vt}">{esc_xml(str(f["value"]))}</dcsset:right>')
    lines.append(f"{indent}</dcsset:item>")


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
        flt = parsed["filter"]
        lines.append(f"{i}\t<dcsset:filter>")
        if isinstance(flt, list):
            # OrGroup
            lines.append(f'{i}\t\t<dcsset:item xsi:type="dcsset:FilterItemGroup">')
            lines.append(f"{i}\t\t\t<dcsset:groupType>OrGroup</dcsset:groupType>")
            for f in flt:
                _emit_filter_comparison(lines, f, f"{i}\t\t\t")
            lines.append(f"{i}\t\t</dcsset:item>")
        else:
            _emit_filter_comparison(lines, flt, f"{i}\t\t")
        lines.append(f"{i}\t</dcsset:filter>")
    else:
        lines.append(f"{i}\t<dcsset:filter/>")

    # appearance
    lines.append(f"{i}\t<dcsset:appearance>")
    val = parsed["value"]
    lines.append(f'{i}\t\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
    lines.append(f"{i}\t\t\t<dcscor:parameter>{esc_xml(parsed['param'])}</dcscor:parameter>")

    if re.match(r'^(web|style|win):', val):
        lines.append(f'{i}\t\t\t<dcscor:value xsi:type="v8ui:Color">{esc_xml(val)}</dcscor:value>')
    elif val in ("true", "false"):
        lines.append(f'{i}\t\t\t<dcscor:value xsi:type="xs:boolean">{esc_xml(val)}</dcscor:value>')
    elif parsed["param"] in ("Формат", "Текст", "Заголовок"):
        lines.append(f'{i}\t\t\t<dcscor:value xsi:type="v8:LocalStringType">')
        lines.append(f"{i}\t\t\t\t<v8:item>")
        lines.append(f"{i}\t\t\t\t\t<v8:lang>ru</v8:lang>")
        lines.append(f"{i}\t\t\t\t\t<v8:content>{esc_xml(val)}</v8:content>")
        lines.append(f"{i}\t\t\t\t</v8:item>")
        lines.append(f"{i}\t\t\t</dcscor:value>")
    else:
        lines.append(f'{i}\t\t\t<dcscor:value xsi:type="xs:string">{esc_xml(val)}</dcscor:value>')

    lines.append(f"{i}\t\t</dcscor:item>")
    lines.append(f"{i}\t</dcsset:appearance>")

    lines.append(f"{i}</dcsset:item>")
    return "\n".join(lines)


def build_structure_item_fragment(item, indent):
    i = indent
    lines = [f'{i}<dcsset:item xsi:type="dcsset:StructureItemGroup">']

    if item.get("name"):
        lines.append(f"{i}\t<dcsset:name>{esc_xml(item['name'])}</dcsset:name>")

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
    return "\n".join(lines)


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
    return "\n".join(lines)


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


def get_all_data_sets():
    return [c for c in xml_doc
            if isinstance(c.tag, str) and local_name(c) == "dataSet" and etree.QName(c.tag).namespace == SCH_NS]


def normalize_line_endings(s):
    if s is None:
        return s
    return s.replace("\r\n", "\n").replace("\r", "\n")


def escape_whitespace(s):
    out = []
    for ch in s:
        code = ord(ch)
        if ch == "\n": out.append("\\n")
        elif ch == "\r": out.append("\\r")
        elif ch == "\t": out.append("\\t")
        elif code < 32 or code == 0xA0 or (0x2000 <= code <= 0x200F) or code == 0xFEFF:
            out.append(f"\\u{code:04X}")
        else:
            out.append(ch)
    return "".join(out)


def collapse_whitespace(s):
    return re.sub(r"[\s ]+", " ", s).strip()


def find_longest_prefix_match(haystack, needle):
    """Binary search: largest L such that needle[:L] is a substring of haystack."""
    if not needle or not haystack:
        return (0, -1)
    first_idx = haystack.find(needle[0])
    if first_idx < 0:
        return (0, -1)
    lo, hi = 1, len(needle)
    best_len, best_off = 1, first_idx
    while lo <= hi:
        mid = (lo + hi) // 2
        idx = haystack.find(needle[:mid])
        if idx >= 0:
            best_len, best_off = mid, idx
            lo = mid + 1
        else:
            hi = mid - 1
    return (best_len, best_off)


def format_patch_query_not_found(old_str, query_text, current_ds_node, ds_name):
    lines = [f"Substring not found in query of dataset '{ds_name}'."]

    # Step 1 — cross-dataset probe
    for ds in get_all_data_sets():
        if ds is current_ds_node:
            continue
        q = find_first_element(ds, ["query"], SCH_NS)
        if q is None:
            continue
        qt = normalize_line_endings(q.text or "")
        if old_str in qt:
            other = get_data_set_name(ds)
            lines.append(f"Found in dataset '{other}' instead — wrong -DataSet?")
            return "\n".join(lines)

    # Step 2 — tolerant probe
    norm_needle = collapse_whitespace(old_str)
    norm_hay = collapse_whitespace(query_text)
    tolerant = bool(norm_needle) and (norm_needle in norm_hay)

    # Step 3 — divergence
    matched, off = find_longest_prefix_match(query_text, old_str)
    divergence = None
    if 0 < matched < len(old_str):
        query_pos = off + matched
        before_len = min(20, matched)
        divergence = {
            "matched": matched,
            "total": len(old_str),
            "before": old_str[matched - before_len:matched],
            "search_char": old_str[matched],
            "query_char": query_text[query_pos] if query_pos < len(query_text) else None,
        }

    if tolerant:
        lines.append("Not found exactly, but would match with whitespace normalized (tabs/spaces/NBSP).")
        if divergence:
            lines.append(f"Diverged at offset {divergence['matched']} of {divergence['total']}:")
            lines.append(f"  before:    '{escape_whitespace(divergence['before'])}'")
            sc = divergence['search_char']
            lines.append(f"  in search: '{escape_whitespace(sc)}' (U+{ord(sc):04X})")
            qc = divergence['query_char']
            if qc is not None:
                lines.append(f"  in query:  '{escape_whitespace(qc)}' (U+{ord(qc):04X})")
        return "\n".join(lines)

    if matched == 0:
        lines.append(f"No common prefix with query. Check -DataSet (current: '{ds_name}').")
        return "\n".join(lines)

    lines.append(f"Matched first {divergence['matched']} of {divergence['total']} chars, then diverged:")
    lines.append(f"  before:    '{escape_whitespace(divergence['before'])}'")
    sc = divergence['search_char']
    lines.append(f"  in search: '{escape_whitespace(sc)}' (U+{ord(sc):04X})")
    qc = divergence['query_char']
    if qc is not None:
        lines.append(f"  in query:  '{escape_whitespace(qc)}' (U+{ord(qc):04X})")
    else:
        lines.append("  in query:  (end of query)")
    return "\n".join(lines)


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
        if sv is None:
            print(f"Variant '{variant_arg}' not found", file=sys.stderr)
            sys.exit(1)
    else:
        for child in root_el:
            if isinstance(child.tag, str) and local_name(child) == "settingsVariant" and etree.QName(child.tag).namespace == SCH_NS:
                sv = child
                break
        if sv is None:
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

# Capture raw original BEFORE parse — needed at save time to restore exact root
# <DataCompositionSchema xmlns=...> opening tag (lxml's tostring() collapses multi-line
# xmlns into one line) and to detect NO-OP via byte-equality as a safety net.
with open(resolved_path, "rb") as _f:
    raw_original_bytes = _f.read()
raw_original_text = raw_original_bytes.lstrip(b"\xef\xbb\xbf").decode("utf-8")
_root_open_m = re.search(r"<DataCompositionSchema\b[^>]*>", raw_original_text, re.DOTALL)
raw_root_opening = _root_open_m.group(0) if _root_open_m else None

# Detect line ending convention so save can normalize back to whatever the source used.
line_ending = "\r\n" if "\r\n" in raw_original_text else "\n"
# Round-trip: сохранить BOM / регистр encoding / финальный перенос как в оригинале.
_skd_had_bom = raw_original_bytes.startswith(b"\xef\xbb\xbf")
_skd_body = raw_original_bytes[3:] if _skd_had_bom else raw_original_bytes
_skd_enc_m = re.search(rb'encoding="([^"]+)"', _skd_body[:200])
_skd_enc = _skd_enc_m.group(1).decode("ascii") if _skd_enc_m else "utf-8"
_skd_final_nl = _skd_body.endswith(b"\n")

xml_parser = etree.XMLParser(remove_blank_text=False)
tree = etree.parse(resolved_path, xml_parser)
xml_doc = tree.getroot()

# ── 7. Batch value splitting ────────────────────────────────

if operation in ("set-query", "set-structure", "modify-structure", "add-dataSet"):
    values = [value_arg]
elif operation == "patch-query":
    values = [v.strip() for v in value_arg.split(";;") if v.strip()]
elif operation == "add-drilldown":
    if ";;" in value_arg:
        values = [v.strip() for v in value_arg.split(";;") if v.strip()]
    else:
        values = [v.strip() for v in value_arg.split(",") if v.strip()]
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

        dirty = True; print(f'[OK] Field "{parsed["dataPath"]}" added to dataset "{ds_name}"')

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
                dirty = True; print(f'[OK] Field "{parsed["dataPath"]}" added to selection of variant "{var_name}"')

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

        dirty = True; print(f'[OK] TotalField "{parsed["dataPath"]}" = {parsed["expression"]} added')

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

        dirty = True; print(f'[OK] CalculatedField "{parsed["dataPath"]}" = {parsed["expression"]} added')

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
                dirty = True; print(f'[OK] Field "{parsed["dataPath"]}" added to selection of variant "{var_name}"')

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

        dirty = True; print(f'[OK] Parameter "{parsed["name"]}" added')
        if parsed.get("autoDates"):
            dirty = True; print('[OK] Auto-parameters "\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430", "\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f" added')

elif operation == "modify-parameter":
    for val in values:
        # Extract optional [Title] first (mirrors parse_field_shorthand)
        title_val = None
        m_title = re.search(r'\[([^\]]*)\]', val)
        if m_title:
            title_val = m_title.group(1).strip()
            val = re.sub(r'\s*\[[^\]]*\]\s*', ' ', val).strip()

        parts = val.split(None, 1)
        param_name = parts[0].strip()
        rest = parts[1].strip() if len(parts) > 1 else ""

        flag_hidden = False
        flag_always = False
        if re.search(r'@hidden\b', rest):
            flag_hidden = True
            rest = re.sub(r'\s*@hidden\b', '', rest).strip()
        if re.search(r'@always\b', rest):
            flag_always = True
            rest = re.sub(r'\s*@always\b', '', rest).strip()

        param_el = find_element_by_child_value(xml_doc, "parameter", "name", param_name, SCH_NS)
        if param_el is None:
            print(f'[WARN] Parameter "{param_name}" not found -- skipped')
            continue

        child_indent = get_child_indent(param_el)

        # Set/replace title (must come right after <name>, before <valueType>)
        if title_val is not None:
            existing_title = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "title"), None)
            # If existing title is multi-lang (has >1 <v8:item>), patch ru content
            # while preserving other languages. Otherwise rebuild as ru-only.
            title_frag = None
            if existing_title is not None:
                raw_title = etree.tostring(existing_title, encoding="unicode", with_tail=False)
                raw_title = re.sub(r' xmlns(?::\w+)?="[^"]*"', "", raw_title)
                if raw_title.count("<v8:item>") > 1:
                    title_frag = child_indent + patch_mltext_ru(raw_title, title_val, child_indent)
                remove_node_with_whitespace(existing_title)
            if title_frag is None:
                title_frag = build_mltext_xml("title", title_val, child_indent)
            # Insert before the first child after <name>
            title_ref = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) != "name"), None)
            for node in import_fragment(xml_doc, title_frag):
                insert_before_element(param_el, node, title_ref, child_indent)
            dirty = True; print(f'[OK] Parameter "{param_name}": title set to "{title_val}"')

        # Separate availableValue=... from simple kv pairs
        simple_rest = rest
        av_part = None
        av_idx = rest.find("availableValue=")
        if av_idx >= 0:
            simple_rest = rest[:av_idx].strip()
            av_part = rest[av_idx:]

        # Separate a multi-value value=... (list) — kv-regex below grabs only a single
        # \S+ token, so a comma-separated list (with spaces) wouldn't be captured.
        value_list_items = None
        vl_idx = simple_rest.find("value=")
        if vl_idx >= 0:
            vl_rhs = simple_rest[vl_idx + len("value="):]
            cand = parse_value_list(vl_rhs)
            if len(cand) >= 2:
                value_list_items = cand
                simple_rest = simple_rest[:vl_idx].strip()

        # Process simple key=value pairs (use, denyIncompleteValues, etc.)
        if simple_rest:
            for m in re.finditer(r'(\w+)=(\S+)', simple_rest):
                key, value = m.group(1), m.group(2)
                existing = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == key and etree.QName(ch.tag).namespace == SCH_NS), None)

                if key == "value":
                    # Rebuild <value> with correct xsi:type from <valueType>
                    declared_type = ""
                    vt_el = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "valueType" and etree.QName(ch.tag).namespace == SCH_NS), None)
                    if vt_el is not None:
                        for tnode in vt_el:
                            if isinstance(tnode.tag, str) and local_name(tnode) == "Type":
                                declared_type = re.sub(r'^d\d+p\d+:', '', (tnode.text or "").strip())
                                break
                    # Detect valueListAllowed — empty value should be omitted when set
                    vla_set = False
                    vla_el = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "valueListAllowed" and etree.QName(ch.tag).namespace == SCH_NS), None)
                    if vla_el is not None and (vla_el.text or "").strip() == "true":
                        vla_set = True
                    if is_empty_value(value):
                        frag_xml = build_empty_value_xml(declared_type, child_indent, "", "value", vla_set)
                    else:
                        value_lines = build_param_value_xml(declared_type, value, child_indent)
                        frag_xml = "\n".join(value_lines)
                    # Collect ALL existing <value> (a param may carry a value-list) — scalar
                    # value= collapses them to one, so remove every <value>, not just the first.
                    all_value_els = [ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "value" and etree.QName(ch.tag).namespace == SCH_NS]
                    was_existing = len(all_value_els) > 0
                    if was_existing:
                        last_idx = list(param_el).index(all_value_els[-1])
                        ref_node = param_el[last_idx + 1] if last_idx + 1 < len(param_el) else None
                        for ve in all_value_els:
                            remove_node_with_whitespace(ve)
                    else:
                        ref_node = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) in ("useRestriction", "availableValue", "denyIncompleteValues", "use")), None)
                    if frag_xml:
                        nodes = import_fragment(xml_doc, frag_xml)
                        for node in nodes:
                            insert_before_element(param_el, node, ref_node, child_indent)
                    verb = "updated" if was_existing else "added"
                    dirty = True; print(f'[OK] Parameter "{param_name}": value {verb} to {value}')
                elif existing is not None:
                    existing.text = value
                    dirty = True; print(f'[OK] Parameter "{param_name}": {key} updated to {value}')
                else:
                    # Schema order: ...value, useRestriction, availableValue*, denyIncompleteValues, use
                    ref_node = None
                    if key == "denyIncompleteValues":
                        ref_node = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "use"), None)
                    frag_xml = f"{child_indent}<{key}>{esc_xml(value)}</{key}>"
                    nodes = import_fragment(xml_doc, frag_xml)
                    for node in nodes:
                        insert_before_element(param_el, node, ref_node, child_indent)
                    dirty = True; print(f'[OK] Parameter "{param_name}": {key}={value} added')

        # Process multi-value list (value=v1, v2, ...) — replace ALL <value>, ensure valueListAllowed=true
        if value_list_items:
            declared_type = ""
            vt_el = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "valueType" and etree.QName(ch.tag).namespace == SCH_NS), None)
            if vt_el is not None:
                for tnode in vt_el:
                    if isinstance(tnode.tag, str) and local_name(tnode) == "Type":
                        declared_type = re.sub(r'^d\d+p\d+:', '', (tnode.text or "").strip())
                        break
            # Remove ALL existing <value>; capture insertion ref after the last one
            value_els = [ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "value" and etree.QName(ch.tag).namespace == SCH_NS]
            if value_els:
                last_idx = list(param_el).index(value_els[-1])
                ref_node = param_el[last_idx + 1] if last_idx + 1 < len(param_el) else None
                for ve in value_els:
                    remove_node_with_whitespace(ve)
            else:
                ref_node = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) in ("useRestriction", "availableValue", "denyIncompleteValues", "use")), None)
            for v in value_list_items:
                frag_xml = "\n".join(build_param_value_xml(declared_type, v, child_indent))
                for node in import_fragment(xml_doc, frag_xml):
                    insert_before_element(param_el, node, ref_node, child_indent)
            # Ensure <valueListAllowed>true</valueListAllowed> (schema order: after useRestriction, before availableValue/use)
            vla_el = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "valueListAllowed" and etree.QName(ch.tag).namespace == SCH_NS), None)
            if vla_el is not None:
                if (vla_el.text or "").strip() != "true":
                    vla_el.text = "true"
            else:
                ref_vla = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) in ("availableValue", "denyIncompleteValues", "use")), None)
                for node in import_fragment(xml_doc, f"{child_indent}<valueListAllowed>true</valueListAllowed>"):
                    insert_before_element(param_el, node, ref_vla, child_indent)
            dirty = True; print(f'[OK] Parameter "{param_name}": value set to list of {len(value_list_items)} item(s)')

        # Process availableValue
        if av_part:
            av_rest = av_part[len("availableValue="):].strip()
            av_items = parse_available_value_list(av_rest)

            # Prefer declared <valueType> of the parameter; fall back to value pattern
            declared_type = ""
            vt_el = None
            for ch in param_el:
                if isinstance(ch.tag, str) and local_name(ch) == "valueType" and etree.QName(ch.tag).namespace == SCH_NS:
                    vt_el = ch
                    break
            if vt_el is not None:
                for tnode in vt_el:
                    if isinstance(tnode.tag, str) and local_name(tnode) == "Type":
                        declared_type = re.sub(r'^d\d+p\d+:', '', (tnode.text or "").strip())
                        break

            # Remove all existing <availableValue>
            to_remove = [ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "availableValue" and etree.QName(ch.tag).namespace == SCH_NS]
            for el in to_remove:
                remove_node_with_whitespace(el)

            # Insert each new <availableValue> before (denyIncompleteValues, use)
            ref_node = None
            for child in param_el:
                if isinstance(child.tag, str) and local_name(child) in ("denyIncompleteValues", "use"):
                    ref_node = child
                    break
            for av in av_items:
                av_lines = build_available_value_fragment(av, declared_type, child_indent)
                frag_xml = "\n".join(av_lines)
                nodes = import_fragment(xml_doc, frag_xml)
                for node in nodes:
                    insert_before_element(param_el, node, ref_node, child_indent)
            dirty = True; print(f'[OK] Parameter "{param_name}": availableValue set to {len(av_items)} item(s)')

        if flag_hidden:
            ur_el = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "useRestriction" and etree.QName(ch.tag).namespace == SCH_NS), None)
            if ur_el is not None:
                if (ur_el.text or "").strip() != "true":
                    ur_el.text = "true"
            else:
                ref_node = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) in ("expression", "availableAsField", "availableValue", "denyIncompleteValues", "use")), None)
                for node in import_fragment(xml_doc, f"{child_indent}<useRestriction>true</useRestriction>"):
                    insert_before_element(param_el, node, ref_node, child_indent)

            af_el = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "availableAsField" and etree.QName(ch.tag).namespace == SCH_NS), None)
            if af_el is not None:
                if (af_el.text or "").strip() != "false":
                    af_el.text = "false"
            else:
                ref_node = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) in ("availableValue", "denyIncompleteValues", "use")), None)
                for node in import_fragment(xml_doc, f"{child_indent}<availableAsField>false</availableAsField>"):
                    insert_before_element(param_el, node, ref_node, child_indent)

            dirty = True; print(f'[OK] Parameter "{param_name}": @hidden applied')

        if flag_always:
            use_el = next((ch for ch in param_el if isinstance(ch.tag, str) and local_name(ch) == "use" and etree.QName(ch.tag).namespace == SCH_NS), None)
            if use_el is not None:
                if (use_el.text or "").strip() != "Always":
                    use_el.text = "Always"
            else:
                for node in import_fragment(xml_doc, f"{child_indent}<use>Always</use>"):
                    insert_before_element(param_el, node, None, child_indent)
            dirty = True; print(f'[OK] Parameter "{param_name}": @always applied')

elif operation == "rename-parameter":
    root = xml_doc
    for val in values:
        m_rn = re.match(r'^\s*(.+?)\s*=>\s*(.+?)\s*$', val)
        if not m_rn:
            print(f'[WARN] rename-parameter expects "OldName => NewName", got: {val}')
            continue
        old_name = m_rn.group(1).strip()
        new_name = m_rn.group(2).strip()

        if old_name == new_name:
            print('[WARN] rename-parameter: old and new names are equal -- skipped')
            continue

        # 1. Rename <parameter><name>OldName</name>
        param_el = find_element_by_child_value(root, "parameter", "name", old_name, SCH_NS)
        if param_el is None:
            print(f'[WARN] Parameter "{old_name}" not found -- skipped')
            continue
        for ch in param_el:
            if isinstance(ch.tag, str) and local_name(ch) == "name" and etree.QName(ch.tag).namespace == SCH_NS:
                ch.text = new_name
                break

        # 2. Update <expression> in other <parameter> elements.
        # Regex matches "&OldName" only when followed by a non-identifier char (or end),
        # so "&Период" matches "&Период.ДатаНачала" but NOT "&ПериодОтчета".
        esc_old = re.escape(old_name)
        expr_regex = re.compile(rf'&{esc_old}(?=[^\w\u0400-\u04FF]|$)')
        expr_updated = 0
        for ch in root:
            if not (isinstance(ch.tag, str) and local_name(ch) == "parameter" and etree.QName(ch.tag).namespace == SCH_NS):
                continue
            for gc in ch:
                if isinstance(gc.tag, str) and local_name(gc) == "expression" and etree.QName(gc.tag).namespace == SCH_NS:
                    old_expr = gc.text or ""
                    new_expr = expr_regex.sub(f'&{new_name}', old_expr)
                    if new_expr != old_expr:
                        gc.text = new_expr
                        expr_updated += 1

        # 3. Update <dcscor:parameter>OldName</dcscor:parameter> in dataParameters of all variants.
        dp_updated = 0
        for variant_node in root:
            if not (isinstance(variant_node.tag, str) and local_name(variant_node) == "settingsVariant" and etree.QName(variant_node.tag).namespace == SCH_NS):
                continue
            settings_node = find_first_element(variant_node, ["settings"], SET_NS)
            if settings_node is None:
                continue
            dp_el = find_first_element(settings_node, ["dataParameters"], SET_NS)
            if dp_el is None:
                continue
            for item in dp_el:
                if not (isinstance(item.tag, str) and local_name(item) == "item"):
                    continue
                for gc in item:
                    if isinstance(gc.tag, str) and local_name(gc) == "parameter" and etree.QName(gc.tag).namespace == COR_NS:
                        if (gc.text or "").strip() == old_name:
                            gc.text = new_name
                            dp_updated += 1

        dirty = True; print(f'[OK] Parameter renamed: "{old_name}" => "{new_name}" (expressions updated: {expr_updated}, dataParameters updated: {dp_updated})')

elif operation == "reorder-parameters":
    root = xml_doc
    for val in values:
        order = [s.strip() for s in val.split(",") if s.strip()]
        if not order:
            print('[WARN] reorder-parameters: empty list -- skipped')
            continue

        all_params = []
        for ch in root:
            if isinstance(ch.tag, str) and local_name(ch) == "parameter" and etree.QName(ch.tag).namespace == SCH_NS:
                all_params.append(ch)
        if not all_params:
            print('[WARN] reorder-parameters: no parameters in schema')
            continue

        child_indent = get_child_indent(root)

        by_name = {}
        for pe in all_params:
            for gc in pe:
                if isinstance(gc.tag, str) and local_name(gc) == "name" and etree.QName(gc.tag).namespace == SCH_NS:
                    by_name[(gc.text or "").strip()] = pe
                    break

        new_order = []
        used = set()
        for name in order:
            if name in by_name:
                new_order.append(by_name[name])
                used.add(name)
            else:
                print(f'[WARN] reorder-parameters: parameter "{name}" not found -- skipped')

        for pe in all_params:
            pe_name = None
            for gc in pe:
                if isinstance(gc.tag, str) and local_name(gc) == "name" and etree.QName(gc.tag).namespace == SCH_NS:
                    pe_name = (gc.text or "").strip()
                    break
            if pe_name and pe_name not in used:
                new_order.append(pe)

        # Anchor: element right after the last parameter in original order
        last_param = all_params[-1]
        anchor = last_param.getnext()

        # Remove all parameters with surrounding whitespace
        for pe in all_params:
            remove_node_with_whitespace(pe)

        # Re-insert in new order before anchor
        for pe in new_order:
            insert_before_element(root, pe, anchor, child_indent)

        dirty = True; print(f'[OK] Parameters reordered ({len(all_params)} total, {len(order)} explicit)')

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
        dirty = True; print(f'[OK] Filter "{parsed["field"]} {parsed["op"]}" added to variant "{var_name}"')

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
        dirty = True; print(f'[OK] DataParameter "{parsed["parameter"]}" added to variant "{var_name}"')

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
        dirty = True; print(f'[OK] Order "{desc}" added to variant "{var_name}"')

elif operation == "add-selection":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    for val in values:
        field_name = val.strip()
        group_name = None

        # Extract @group=Name
        gm = re.search(r'\s*@group=(\S+)', field_name)
        if gm:
            group_name = gm.group(1)
            field_name = re.sub(r'\s*@group=\S+', '', field_name).strip()

        if group_name:
            # Find named StructureItemGroup
            target_el = None
            for item in settings.iter(f"{{{SET_NS}}}item"):
                xsi_type = item.get(f"{{{XSI_NS}}}type", "")
                if "StructureItemGroup" in xsi_type:
                    name_el = item.find(f"{{{SET_NS}}}name")
                    if name_el is not None and name_el.text == group_name:
                        target_el = item
                        break
            if target_el is None:
                print(f'[WARN] StructureItemGroup "{group_name}" not found -- adding to variant level')
                target_el = settings
        else:
            target_el = settings

        selection = ensure_settings_child(target_el, "selection", [])

        # Dedup: skip if SelectedItemAuto already exists
        if field_name == "Auto":
            is_dup = False
            for ch in selection:
                if isinstance(ch.tag, str) and local_name(ch) == "item":
                    type_attr = ch.get(XSI_TYPE, "")
                    if "SelectedItemAuto" in type_attr:
                        is_dup = True
                        break
            if is_dup:
                target = f'group "{group_name}"' if group_name else f'variant "{var_name}"'
                print(f'[WARN] SelectedItemAuto already exists in {target} -- skipped')
                continue

        sel_indent = get_container_child_indent(selection)
        sel_xml = build_selection_item_fragment(field_name, sel_indent)
        sel_nodes = import_fragment(xml_doc, sel_xml)
        for node in sel_nodes:
            insert_before_element(selection, node, None, sel_indent)
        target = f'group "{group_name}"' if group_name else f'variant "{var_name}"'
        dirty = True; print(f'[OK] Selection "{field_name}" added to {target}')

elif operation == "set-query":
    ds_node = resolve_data_set()
    ds_name = get_data_set_name(ds_node)
    query_el = find_first_element(ds_node, ["query"], SCH_NS)
    if query_el is None:
        print(f"No <query> element found in dataset '{ds_name}'", file=sys.stderr)
        sys.exit(1)
    query_el.text = resolve_query_value(value_arg, query_base_dir)
    dirty = True; print(f'[OK] Query replaced in dataset "{ds_name}"')

elif operation == "patch-query":
    ds_node = resolve_data_set()
    ds_name = get_data_set_name(ds_node)
    query_el = find_first_element(ds_node, ["query"], SCH_NS)
    if query_el is None:
        print(f"No <query> element found in dataset '{ds_name}'", file=sys.stderr)
        sys.exit(1)
    for val in values:
        once = False
        if re.search(r'@once\b', val):
            once = True
            val = re.sub(r'\s*@once\b', '', val).strip()

        sep_idx = val.find(" => ")
        if sep_idx < 0:
            print("patch-query value must contain ' => ' separator: old => new", file=sys.stderr)
            sys.exit(1)
        old_str = normalize_line_endings(val[:sep_idx])
        new_str = normalize_line_endings(val[sep_idx + 4:])
        query_text = normalize_line_endings(query_el.text or "")

        count = query_text.count(old_str)
        if count == 0:
            print(format_patch_query_not_found(old_str, query_text, ds_node, ds_name), file=sys.stderr)
            sys.exit(1)
        if once and count != 1:
            print(f"@once: expected 1 occurrence of '{old_str}' in dataset '{ds_name}', found {count}", file=sys.stderr)
            sys.exit(1)

        query_el.text = query_text.replace(old_str, new_str)
        suffix = " (1 occurrence)" if once else f" ({count} occurrence(s))"
        dirty = True; print(f'[OK] Query patched in dataset "{ds_name}": replaced \'{old_str}\'{suffix}')

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
            dirty = True; print(f'[OK] Replaced outputParameter "{parsed["key"]}" in variant "{var_name}"')
        else:
            dirty = True; print(f'[OK] OutputParameter "{parsed["key"]}" added to variant "{var_name}"')

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

    dirty = True; print(f'[OK] Structure set in variant "{var_name}": {value_arg}')

elif operation == "modify-structure":
    settings = resolve_variant_settings()
    var_name = get_variant_name()

    struct_items = parse_structure_shorthand(value_arg)

    # Flatten parsed tree into (name, groupBy) targets
    targets = []
    stack = list(struct_items)
    while stack:
        it = stack.pop()
        if it.get("name"):
            targets.append({"name": it["name"], "groupBy": it.get("groupBy", [])})
        for ch in it.get("children", []) or []:
            stack.append(ch)

    if not targets:
        print(f"modify-structure requires @name= for at least one group: {value_arg}", file=sys.stderr)
        sys.exit(1)

    ns = {"dcsset": SET_NS, "xsi": XSI_NS}

    for t in targets:
        xpath = f".//dcsset:item[@xsi:type='dcsset:StructureItemGroup'][dcsset:name='{t['name']}']"
        group_el = settings.find(xpath, ns)
        if group_el is None:
            print(f'[WARN] Group with @name="{t["name"]}" not found — skipped')
            continue

        gi_el = None
        for ch in group_el:
            if isinstance(ch.tag, str) and local_name(ch) == "groupItems" and etree.QName(ch.tag).namespace == SET_NS:
                gi_el = ch
                break

        group_indent = get_child_indent(group_el)
        if gi_el is None:
            # Insert <groupItems> after <name>, before first non-name sibling
            ref_after_name = None
            saw_name = False
            for ch in group_el:
                if not isinstance(ch.tag, str):
                    continue
                if local_name(ch) == "name" and etree.QName(ch.tag).namespace == SET_NS:
                    saw_name = True
                elif saw_name:
                    ref_after_name = ch
                    break
            gi_frag = f"{group_indent}<dcsset:groupItems></dcsset:groupItems>"
            for node in import_fragment(xml_doc, gi_frag):
                insert_before_element(group_el, node, ref_after_name, group_indent)
            for ch in group_el:
                if isinstance(ch.tag, str) and local_name(ch) == "groupItems" and etree.QName(ch.tag).namespace == SET_NS:
                    gi_el = ch
                    break

        to_remove = [ch for ch in gi_el if isinstance(ch.tag, str)]
        for el in to_remove:
            remove_node_with_whitespace(el)

        item_indent = group_indent + "\t"

        for field in t["groupBy"]:
            lines = [
                f'{item_indent}<dcsset:item xsi:type="dcsset:GroupItemField">',
                f'{item_indent}\t<dcsset:field>{esc_xml(field)}</dcsset:field>',
                f'{item_indent}\t<dcsset:groupType>Items</dcsset:groupType>',
                f'{item_indent}\t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>',
                f'{item_indent}\t<dcsset:periodAdditionBegin xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionBegin>',
                f'{item_indent}\t<dcsset:periodAdditionEnd xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionEnd>',
                f'{item_indent}</dcsset:item>',
            ]
            frag_xml = "\n".join(lines)
            for node in import_fragment(xml_doc, frag_xml):
                insert_before_element(gi_el, node, None, item_indent)

        desc = "details" if not t["groupBy"] else ", ".join(t["groupBy"])
        dirty = True; print(f'[OK] Group "{t["name"]}" groupItems updated: {desc}')

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
        dirty = True; print(f'[OK] DataSetLink "{desc}" added')

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

        dirty = True; print(f'[OK] DataSet "{parsed["name"]}" added (dataSource={ds_source_name})')

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

        dirty = True; print(f'[OK] Variant "{parsed["name"]}" ["{parsed["presentation"]}"] added')

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
            flt = parsed["filter"]
            if isinstance(flt, list):
                desc += f" when OrGroup({len(flt)} conditions)"
            else:
                desc += f" when {flt['field']} {flt['op']}"
        if parsed.get("fields"):
            desc += f" for {', '.join(parsed['fields'])}"
        dirty = True; print(f'[OK] ConditionalAppearance "{desc}" added to variant "{var_name}"')

elif operation == "clear-selection":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    selection = find_first_element(settings, ["selection"], SET_NS)
    if selection is not None:
        clear_container_children(selection)
        dirty = True; print(f'[OK] Selection cleared in variant "{var_name}"')
    else:
        print(f'[INFO] No selection section in variant "{var_name}"')

elif operation == "clear-order":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    order_el = find_first_element(settings, ["order"], SET_NS)
    if order_el is not None:
        clear_container_children(order_el)
        dirty = True; print(f'[OK] Order cleared in variant "{var_name}"')
    else:
        print(f'[INFO] No order section in variant "{var_name}"')

elif operation == "clear-filter":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    filter_el = find_first_element(settings, ["filter"], SET_NS)
    if filter_el is not None:
        clear_container_children(filter_el)
        dirty = True; print(f'[OK] Filter cleared in variant "{var_name}"')
    else:
        print(f'[INFO] No filter section in variant "{var_name}"')

elif operation == "clear-conditionalAppearance":
    settings = resolve_variant_settings()
    var_name = get_variant_name()
    ca_el = find_first_element(settings, ["conditionalAppearance"], SET_NS)
    if ca_el is not None:
        clear_container_children(ca_el)
        dirty = True; print(f'[OK] ConditionalAppearance cleared in variant "{var_name}"')
    else:
        print(f'[INFO] No conditionalAppearance section in variant "{var_name}"')

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

        # Update use (only when explicitly set via @off / @on)
        if parsed.get("use") is False:
            set_or_create_child_element(filter_item, "use", SET_NS, "false", item_indent)
        elif parsed.get("use") is True:
            # @on: remove existing use=false if any
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

        dirty = True; print(f'[OK] Filter "{parsed["field"]}" modified in variant "{var_name}"')

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
                val_lines.append(f"{item_indent}\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>")
                val_lines.append(f"{item_indent}\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>")
                val_lines.append(f"{item_indent}</dcscor:value>")
            elif is_empty_value(pv):
                val_lines.append(f'{item_indent}<dcscor:value xsi:nil="true"/>')
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(pv)):
                val_lines.append(f'{item_indent}<dcscor:value xsi:type="xs:dateTime">{esc_xml(str(pv))}</dcscor:value>')
            elif str(pv) in ("true", "false"):
                val_lines.append(f'{item_indent}<dcscor:value xsi:type="xs:boolean">{esc_xml(str(pv))}</dcscor:value>')
            else:
                val_lines.append(f'{item_indent}<dcscor:value xsi:type="xs:string">{esc_xml(str(pv))}</dcscor:value>')

            val_xml = "\n".join(val_lines)
            val_nodes = import_fragment(xml_doc, val_xml)
            for node in val_nodes:
                insert_before_element(dp_item, node, None, item_indent)

        # Update use (only when explicitly set via @off / @on)
        if parsed.get("use") is False:
            set_or_create_child_element(dp_item, "use", COR_NS, "false", item_indent)
        elif parsed.get("use") is True:
            # @on: remove existing use=false if any
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

        dirty = True; print(f'[OK] DataParameter "{parsed["parameter"]}" modified in variant "{var_name}"')

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
            # Preserve raw <valueType> only when user did NOT override type via shorthand.
            "rawValueType": None if parsed.get("type") else existing.get("_rawValueType"),
            # Preserve raw multi-lang title; pass existing ru content for change detection.
            "_rawTitle": existing.get("_rawTitle"),
            "_existingTitleRu": existing.get("title"),
            # Pass-through unknown children (e.g. <editFormat>, <appearance>, custom extensions).
            "_unknownChildren": existing.get("_unknownChildren"),
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

        dirty = True; print(f'[OK] Field "{field_name}" modified in dataset "{ds_name}"')

elif operation == "set-field-role":
    ds_node = resolve_data_set()
    ds_name = get_data_set_name(ds_node)

    for val in values:
        s = val.strip()

        flags = []
        for m in re.finditer(r'@(\w+)', s):
            flags.append(m.group(1))
        s = re.sub(r'\s*@\w+', '', s).strip()

        kv = []
        for m in re.finditer(r'(\w+)=(\S+)', s):
            kv.append((m.group(1), m.group(2)))
        s = re.sub(r'\s*\w+=\S+', '', s).strip()

        data_path = s
        if not data_path:
            print(f'[WARN] set-field-role: empty dataPath in "{val}"')
            continue

        field_el = find_element_by_child_value(ds_node, "field", "dataPath", data_path, SCH_NS)
        if field_el is None:
            print(f'[WARN] Field "{data_path}" not found in dataset "{ds_name}"')
            continue

        field_indent = get_child_indent(field_el)

        # Remove existing <role> — but first capture OuterXml of sub-children that the
        # rebuild won't re-emit (custom <dcscom:groupFields>, <dcscom:addition>, etc.).
        old_role = next((ch for ch in field_el if isinstance(ch.tag, str) and local_name(ch) == "role" and etree.QName(ch.tag).namespace == SCH_NS), None)
        known_role_children = {"periodNumber", "periodType", "dimension", "ignoreNullsInGroups",
                               "balance", "account", "accountTypeExpression", "additionType", "addition"}
        kv_keys = {k for k, _ in kv}
        preserved_role_children = []
        if old_role is not None:
            for gc in old_role:
                if not isinstance(gc.tag, str):
                    continue
                ln = local_name(gc)
                if ln in known_role_children:
                    continue
                if ln in kv_keys:
                    continue
                raw = etree.tostring(gc, encoding="unicode", with_tail=False)
                raw = re.sub(r' xmlns(?::\w+)?="[^"]*"', "", raw)
                preserved_role_children.append(raw)
            remove_node_with_whitespace(old_role)

        # Empty spec — remove only
        if not flags and not kv:
            dirty = True; print(f'[OK] Field "{data_path}" role cleared')
            continue

        # Build new <role>
        lines = [f"{field_indent}<role>"]
        for flag in flags:
            if flag == "period":
                lines.append(f"{field_indent}\t<dcscom:periodNumber>1</dcscom:periodNumber>")
                lines.append(f"{field_indent}\t<dcscom:periodType>Main</dcscom:periodType>")
            else:
                lines.append(f"{field_indent}\t<dcscom:{flag}>true</dcscom:{flag}>")
        for k, v in kv:
            lines.append(f"{field_indent}\t<dcscom:{k}>{esc_xml(v)}</dcscom:{k}>")
        for raw in preserved_role_children:
            lines.append(f"{field_indent}\t" + raw)
        lines.append(f"{field_indent}</role>")
        frag_xml = "\n".join(lines)

        ref_node = next((ch for ch in field_el if isinstance(ch.tag, str) and local_name(ch) in ("valueType", "inputParameters") and etree.QName(ch.tag).namespace == SCH_NS), None)
        for node in import_fragment(xml_doc, frag_xml):
            insert_before_element(field_el, node, ref_node, field_indent)

        parts = []
        if flags:
            parts.append(" ".join(f"@{f}" for f in flags))
        if kv:
            parts.append(" ".join(f"{k}={v}" for k, v in kv))
        dirty = True; print(f'[OK] Field "{data_path}" role set: {" ".join(parts)}')

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
        dirty = True; print(f'[OK] Field "{field_name}" removed from dataset "{ds_name}"')

        try:
            settings = resolve_variant_settings()
            var_name = get_variant_name()
            selection = find_first_element(settings, ["selection"], SET_NS)
            if selection is not None:
                sel_item = find_element_by_child_value(selection, "item", "field", field_name, SET_NS)
                if sel_item is not None:
                    remove_node_with_whitespace(sel_item)
                    dirty = True; print(f'[OK] Field "{field_name}" removed from selection of variant "{var_name}"')
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
        dirty = True; print(f'[OK] TotalField "{data_path}" removed')

elif operation == "remove-calculated-field":
    for val in values:
        data_path = val.strip()
        calc_el = find_element_by_child_value(xml_doc, "calculatedField", "dataPath", data_path, SCH_NS)
        if calc_el is None:
            print(f'[WARN] CalculatedField "{data_path}" not found')
            continue
        remove_node_with_whitespace(calc_el)
        dirty = True; print(f'[OK] CalculatedField "{data_path}" removed')

        try:
            settings = resolve_variant_settings()
            var_name = get_variant_name()
            selection = find_first_element(settings, ["selection"], SET_NS)
            if selection is not None:
                sel_item = find_element_by_child_value(selection, "item", "field", data_path, SET_NS)
                if sel_item is not None:
                    remove_node_with_whitespace(sel_item)
                    dirty = True; print(f'[OK] Field "{data_path}" removed from selection of variant "{var_name}"')
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
        dirty = True; print(f'[OK] Parameter "{param_name}" removed')

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
        dirty = True; print(f'[OK] Filter for "{field_name}" removed from variant "{var_name}"')

elif operation == "add-drilldown":
    # String-based manipulation — templates use dcsat namespace with inline xmlns
    with open(resolved_path, "r", encoding="utf-8-sig") as f:
        raw_text = f.read()
    nl = "\r\n"
    dcsat_ns_decl = 'xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template"'

    # Find all outer <template> blocks by nesting-aware scan
    name_regex = re.compile(r'<template>\s*<name>([^<]+)</name>')
    tpl_starts = [(m.start(), m.group(1)) for m in name_regex.finditer(raw_text)]

    # For each start, find closing </template> at nesting depth 0
    tpl_blocks = []
    for ts_pos, ts_name in tpl_starts:
        depth = 1
        scan_pos = ts_pos + 10  # skip past opening <template>
        while depth > 0 and scan_pos < len(raw_text):
            next_open = raw_text.find("<template", scan_pos)
            next_close = raw_text.find("</template>", scan_pos)
            if next_close < 0:
                break
            if next_open >= 0 and next_open < next_close:
                depth += 1
                scan_pos = next_open + 10
            else:
                depth -= 1
                if depth == 0:
                    end_pos = next_close + len("</template>")
                    tpl_blocks.append((ts_name, ts_pos, raw_text[ts_pos:end_pos]))
                scan_pos = next_close + 11

    if not tpl_blocks:
        print("[WARN] No named templates found in schema")

    # Collect all insertions as (position, text) — apply in reverse order
    insertions = []

    expr_regex = re.compile(
        r'(?s)<parameter[^>]*ExpressionAreaTemplateParameter[^>]*>\s*'
        r'<dcsat:name>([^<]+)</dcsat:name>\s*'
        r'<dcsat:expression>([^<]+)</dcsat:expression>\s*</parameter>'
    )

    for tpl_name, tpl_start, tpl_text in tpl_blocks:

        # Build map: expression → paramName from ExpressionAreaTemplateParameter
        expr_map = {}
        for em in expr_regex.finditer(tpl_text):
            p_name = em.group(1)
            p_expr = em.group(2)
            expr_map[p_expr] = p_name

        for resource in values:
            drill_name = f"Расшифровка_{resource}"

            # Idempotency: check if already exists
            if drill_name in tpl_text:
                print(f"[INFO] {drill_name} already exists in {tpl_name} — skipped")
                continue

            # Find ExpressionAreaTemplateParameter by expression
            param_name = expr_map.get(resource)
            if param_name is None:
                print(f'[WARN] Expression "{resource}" not found in template {tpl_name} — skipped')
                continue

            cell_count = 0

            # Step 1: Insert DetailsAreaTemplateParameter after last </parameter> in template
            last_param_end_tag = "</parameter>"
            last_param_pos = tpl_text.rfind(last_param_end_tag)
            if last_param_pos >= 0:
                insert_pos = tpl_start + last_param_pos + len(last_param_end_tag)
                # Detect indent from context
                prev_nl = tpl_text.rfind("\n", 0, last_param_pos)
                indent = "\t\t"
                if prev_nl >= 0:
                    line_start = prev_nl + 1
                    indent_match = re.match(r'^(\s*)', tpl_text[line_start:])
                    if indent_match:
                        indent = indent_match.group(1)
                details_xml = (
                    f'{nl}{indent}<parameter {dcsat_ns_decl} xsi:type="dcsat:DetailsAreaTemplateParameter">'
                    f'{nl}{indent}\t<dcsat:name>{drill_name}</dcsat:name>'
                    f'{nl}{indent}\t<dcsat:fieldExpression>'
                    f'{nl}{indent}\t\t<dcsat:field>ИмяРесурса</dcsat:field>'
                    f'{nl}{indent}\t\t<dcsat:expression>"{resource}"</dcsat:expression>'
                    f'{nl}{indent}\t</dcsat:fieldExpression>'
                    f'{nl}{indent}\t<dcsat:mainAction>DrillDown</dcsat:mainAction>'
                    f'{nl}{indent}</parameter>'
                )
                insertions.append((insert_pos, details_xml))

            # Step 2: Insert appearance binding in cells referencing this parameter
            cell_tag = f'<dcsat:value xsi:type="dcscor:Parameter">{param_name}</dcsat:value>'
            search_start = 0
            while True:
                cell_idx = tpl_text.find(cell_tag, search_start)
                if cell_idx < 0:
                    break
                cell_end = tpl_text.find("</dcsat:tableCell>", cell_idx)
                if cell_end < 0:
                    break
                app_end = tpl_text.rfind("</dcsat:appearance>", cell_idx, cell_end)
                if app_end < cell_idx:
                    search_start = cell_end + 1
                    continue

                # Detect indent for appearance items — insert after \n, before indent of </dcsat:appearance>
                app_prev_nl = tpl_text.rfind("\n", 0, app_end)
                app_indent = "\t\t\t\t\t\t"
                if app_prev_nl >= 0:
                    app_line_start = app_prev_nl + 1
                    app_indent_match = re.match(r'^(\s*)', tpl_text[app_line_start:])
                    if app_indent_match:
                        app_indent = app_indent_match.group(1)
                item_indent = app_indent + "\t"
                appearance_xml = (
                    f'{item_indent}<dcscor:item>{nl}'
                    f'{item_indent}\t<dcscor:parameter>Расшифровка</dcscor:parameter>{nl}'
                    f'{item_indent}\t<dcscor:value xsi:type="dcscor:Parameter">{drill_name}</dcscor:value>{nl}'
                    f'{item_indent}</dcscor:item>{nl}'
                )
                # Insert after \n (before indent of closing tag), not before the tag itself
                insert_at = (tpl_start + app_prev_nl + 1) if app_prev_nl >= 0 else (tpl_start + app_end)
                insertions.append((insert_at, appearance_xml))
                cell_count += 1
                search_start = cell_end + 1

            dirty = True; print(f"[OK] {drill_name} \u2192 {tpl_name} (param + {cell_count} cell(s))")

    # Apply insertions in reverse order to preserve offsets.
    # For same position: reverse insertion order so first resource ends up first in file.
    insertions = [(pos, text, seq) for seq, (pos, text) in enumerate(insertions)]
    insertions.sort(key=lambda x: (x[0], x[2]), reverse=True)
    for pos, text, _seq in insertions:
        raw_text = raw_text[:pos] + text + raw_text[pos:]

    # Write directly — skip lxml save
    with open(resolved_path, "wb") as f:
        f.write(b'\xef\xbb\xbf')
        f.write(raw_text.encode("utf-8"))
    dirty = True; print(f"[OK] Saved {resolved_path}")
    sys.exit(0)

# ── 9. Save ─────────────────────────────────────────────────

if not dirty:
    print("[INFO] No changes -- file untouched")
    sys.exit(0)

xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
# Round-trip: восстановить регистр encoding как в оригинале.
xml_bytes = xml_bytes.replace(
    b"<?xml version='1.0' encoding='UTF-8'?>",
    b'<?xml version="1.0" encoding="' + _skd_enc.encode("ascii") + b'"?>')

# Format-preserve post-processing (mirrors PS path):
#   (1) restore the original raw <DataCompositionSchema ...> opening tag — lxml collapses
#       multi-line xmlns into one line.
xml_text = xml_bytes.decode("utf-8")
if raw_root_opening:
    xml_text = re.sub(r"<DataCompositionSchema\b[^>]*>", lambda m: raw_root_opening, xml_text, count=1, flags=re.DOTALL)
# Normalize self-closing tags: lxml writes `<foo bar="x"/>` already (no space), but be
# defensive — strip any space before `/>` so PS and PY ports stay byte-equivalent.
xml_text = re.sub(r"(?<=\S) />", "/>", xml_text)

# Канонизировать переносы к LF (убирает возможный &#13;), затем к стилю источника.
xml_text = xml_text.replace("&#13;\n", "\n").replace("&#13;", "").replace("\r\n", "\n").replace("\r", "\n")
if line_ending == "\r\n":
    xml_text = xml_text.replace("\n", "\r\n")
xml_bytes = xml_text.encode("utf-8")

# Финальный перенос — как в оригинале.
if line_ending == "\r\n":
    xml_bytes = xml_bytes.rstrip(b"\r\n")
    if _skd_final_nl:
        xml_bytes += b"\r\n"
else:
    xml_bytes = xml_bytes.rstrip(b"\n")
    if _skd_final_nl:
        xml_bytes += b"\n"
with open(resolved_path, "wb") as f:
    if _skd_had_bom:
        f.write(b'\xef\xbb\xbf')
    f.write(xml_bytes)

print(f"[OK] Saved {resolved_path}")
