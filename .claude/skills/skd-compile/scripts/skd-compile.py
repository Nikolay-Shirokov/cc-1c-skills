#!/usr/bin/env python3
# skd-compile v1.108 — Compile 1C DCS from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid

from lxml import etree


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


def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

def fmt_dec(v):
    """Format decimal: 30.0 → '30', 16.625 → '16.625' (match PS1 output)."""
    return str(int(v)) if v == int(v) else str(v)


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


def emit_mltext(lines, indent, tag, text, no_xsi_type=False):
    # Empty value → self-closing tag (matches platform output)
    if text is None or (isinstance(text, str) and text == ''):
        if no_xsi_type:
            lines.append(f"{indent}<{tag}/>")
        else:
            lines.append(f'{indent}<{tag} xsi:type="v8:LocalStringType"/>')
        return
    if not text:
        lines.append(f"{indent}<{tag}/>")
        return
    if no_xsi_type:
        lines.append(f"{indent}<{tag}>")
    else:
        lines.append(f'{indent}<{tag} xsi:type="v8:LocalStringType">')
    # Multi-lang: object form { ru: "...", en: "..." } -- one <v8:item> per language
    if isinstance(text, dict):
        for lang, content in text.items():
            lines.append(f"{indent}\t<v8:item>")
            lines.append(f"{indent}\t\t<v8:lang>{esc_xml(str(lang))}</v8:lang>")
            lines.append(f"{indent}\t\t<v8:content>{esc_xml(str(content))}</v8:content>")
            lines.append(f"{indent}\t</v8:item>")
    else:
        lines.append(f"{indent}\t<v8:item>")
        lines.append(f"{indent}\t\t<v8:lang>ru</v8:lang>")
        lines.append(f"{indent}\t\t<v8:content>{esc_xml(str(text))}</v8:content>")
        lines.append(f"{indent}\t</v8:item>")
    lines.append(f"{indent}</{tag}>")


def new_uuid():
    return str(uuid.uuid4())


def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


# --- Type system ---

TYPE_SYNONYMS = {
    # Russian names (lowercase)
    "\u0447\u0438\u0441\u043b\u043e": "decimal",
    "\u0441\u0442\u0440\u043e\u043a\u0430": "string",
    "\u0431\u0443\u043b\u0435\u0432\u043e": "boolean",
    "\u0434\u0430\u0442\u0430": "date",
    "\u0434\u0430\u0442\u0430\u0432\u0440\u0435\u043c\u044f": "dateTime",
    "\u0432\u0440\u0435\u043c\u044f": "time",
    "\u0441\u0442\u0430\u043d\u0434\u0430\u0440\u0442\u043d\u044b\u0439\u043f\u0435\u0440\u0438\u043e\u0434": "StandardPeriod",
    # English canonical (lowercase)
    "bool": "boolean",
    "str": "string",
    "int": "decimal",
    "integer": "decimal",
    "number": "decimal",
    "num": "decimal",
    # Reference synonyms (Russian, lowercase)
    "\u0441\u043f\u0440\u0430\u0432\u043e\u0447\u043d\u0438\u043a\u0441\u0441\u044b\u043b\u043a\u0430": "CatalogRef",
    "\u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0441\u0441\u044b\u043b\u043a\u0430": "DocumentRef",
    "\u043f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u0438\u0435\u0441\u0441\u044b\u043b\u043a\u0430": "EnumRef",
    "\u043f\u043b\u0430\u043d\u0441\u0447\u0435\u0442\u043e\u0432\u0441\u0441\u044b\u043b\u043a\u0430": "ChartOfAccountsRef",
    "\u043f\u043b\u0430\u043d\u0432\u0438\u0434\u043e\u0432\u0445\u0430\u0440\u0430\u043a\u0442\u0435\u0440\u0438\u0441\u0442\u0438\u043a\u0441\u0441\u044b\u043b\u043a\u0430": "ChartOfCharacteristicTypesRef",
}


def resolve_type_str(type_str):
    if not type_str:
        return type_str

    # Check for parameterized types: число(15,2), строка(100), etc.
    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = TYPE_SYNONYMS.get(base_name.lower())
        if resolved:
            return f"{resolved}({params})"
        return type_str

    # Check for reference types: СправочникСсылка.Организации -> CatalogRef.Организации
    if '.' in type_str:
        dot_idx = type_str.index('.')
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]  # includes the dot
        resolved = TYPE_SYNONYMS.get(prefix.lower())
        if resolved:
            return f"{resolved}{suffix}"
        return type_str

    # Simple name lookup (case-insensitive)
    resolved = TYPE_SYNONYMS.get(type_str.lower())
    if resolved:
        return resolved

    return type_str


def emit_value_type(lines, type_spec, indent):
    if not type_spec:
        return

    # Multi-type: iterate and emit each type with its qualifiers
    if isinstance(type_spec, list):
        for t in type_spec:
            emit_single_value_type(lines, str(t), indent)
        return

    emit_single_value_type(lines, str(type_spec), indent)


def emit_single_value_type(lines, type_str, indent):
    if not type_str:
        return

    # Resolve synonyms first
    type_str = resolve_type_str(type_str)

    # boolean
    if type_str == 'boolean':
        lines.append(f'{indent}<v8:Type>xs:boolean</v8:Type>')
        return

    # string, string(N), string(N,fix) — fix → AllowedLength=Fixed
    m = re.match(r'^string(\((\d+)(,(fix|fixed))?\))?$', type_str)
    if m:
        length = m.group(2) if m.group(2) else '0'
        al = 'Fixed' if m.group(4) else 'Variable'
        lines.append(f'{indent}<v8:Type>xs:string</v8:Type>')
        lines.append(f'{indent}<v8:StringQualifiers>')
        lines.append(f'{indent}\t<v8:Length>{length}</v8:Length>')
        lines.append(f'{indent}\t<v8:AllowedLength>{al}</v8:AllowedLength>')
        lines.append(f'{indent}</v8:StringQualifiers>')
        return

    # decimal forms (defaults — bare decimal = money 10,2; decimal(N) = integer N,0):
    #   decimal                       → 10,2,Any
    #   decimal(N)                    → N,0,Any
    #   decimal(N,nonneg)             → N,0,Nonnegative
    #   decimal(N,M)                  → N,M,Any
    #   decimal(N,M,nonneg)           → N,M,Nonnegative
    m = re.match(r'^decimal(\((\d+)(,(\d+))?(,nonneg)?\))?$', type_str)
    if m:
        if not m.group(1):
            digits, fraction, sign = '10', '2', 'Any'
        else:
            digits = m.group(2)
            fraction = m.group(4) if m.group(4) else '0'
            sign = 'Nonnegative' if m.group(5) else 'Any'
        lines.append(f'{indent}<v8:Type>xs:decimal</v8:Type>')
        lines.append(f'{indent}<v8:NumberQualifiers>')
        lines.append(f'{indent}\t<v8:Digits>{digits}</v8:Digits>')
        lines.append(f'{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>')
        lines.append(f'{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>')
        lines.append(f'{indent}</v8:NumberQualifiers>')
        return

    # date / dateTime / time — all use xs:dateTime, differ only in DateFractions
    m = re.match(r'^(date|dateTime|time)$', type_str)
    if m:
        fractions_map = {'date': 'Date', 'dateTime': 'DateTime', 'time': 'Time'}
        fractions = fractions_map[type_str]
        lines.append(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
        lines.append(f'{indent}<v8:DateQualifiers>')
        lines.append(f'{indent}\t<v8:DateFractions>{fractions}</v8:DateFractions>')
        lines.append(f'{indent}</v8:DateQualifiers>')
        return

    # StandardPeriod
    if type_str == 'StandardPeriod':
        lines.append(f'{indent}<v8:Type>v8:StandardPeriod</v8:Type>')
        return

    # Reference types: CatalogRef.XXX, DocumentRef.XXX, EnumRef.XXX, etc.
    if re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.', type_str):
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return

    # TypeSet (композитный тип-набор): голое имя без точки.
    if re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef|InformationRegisterRef|AnyRef)$', type_str):
        lines.append(f'{indent}<v8:TypeSet xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:TypeSet>')
        return

    # Fallback -- assume dot-qualified types are also config references
    if '.' in type_str:
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return

    lines.append(f'{indent}<v8:Type>{esc_xml(type_str)}</v8:Type>')


# --- Field shorthand parser ---

def parse_field_shorthand(s):
    result = {
        'dataPath': '', 'field': '', 'title': '', 'type': '',
        'roles': [], 'restrict': [], 'appearance': {},
        'roleExtras': {},
    }

    # Extract @roles
    role_matches = re.findall(r'@(\w+)', s)
    for m in role_matches:
        result['roles'].append(m)
    s = re.sub(r'\s*@\w+', '', s)

    # Extract #restrictions
    restrict_matches = re.findall(r'#(\w+)', s)
    for m in restrict_matches:
        result['restrict'].append(m)
    s = re.sub(r'\s*#\w+', '', s)

    # Extract role kv=value (e.g. balanceGroupName=Сумма)
    for m in re.finditer(r'(\w+)=(\S+)', s):
        result['roleExtras'][m.group(1)] = m.group(2)
    s = re.sub(r'\s*\w+=\S+', '', s)

    # Split name: type
    s = s.strip()
    if ':' in s:
        parts = s.split(':', 1)
        result['dataPath'] = parts[0].strip()
        result['type'] = resolve_type_str(parts[1].strip())
    else:
        result['dataPath'] = s

    result['field'] = result['dataPath']
    return result


# Universal role spec parser: string / list / dict / None
# Returns {'tokens': [...], 'extras': {...}}
def parse_role_spec(spec):
    tokens = []
    extras = {}

    if spec is None:
        pass
    elif isinstance(spec, str):
        if ' ' not in spec and '=' not in spec:
            tokens.append(spec)
        else:
            s = spec.strip()
            for m in re.finditer(r'@(\w+)', s):
                tokens.append(m.group(1))
            s = re.sub(r'\s*@\w+', '', s).strip()
            for m in re.finditer(r'(\w+)=(\S+)', s):
                extras[m.group(1)] = m.group(2)
    elif isinstance(spec, list):
        for t in spec:
            tokens.append(str(t))
    elif isinstance(spec, dict):
        for k, v in spec.items():
            if isinstance(v, bool):
                if v:
                    tokens.append(k)
            elif isinstance(v, (int, float, str)):
                extras[k] = str(v)

    # Deprecated alias: balanceGroup → balanceGroupName
    if 'balanceGroup' in extras and 'balanceGroupName' not in extras:
        extras['balanceGroupName'] = extras.pop('balanceGroup')

    return {'tokens': tokens, 'extras': extras}


# --- Total field shorthand parser ---

def parse_total_shorthand(s):
    parts = s.split(':', 1)
    data_path = parts[0].strip()
    func_part = parts[1].strip()

    # Known DCS aggregate functions (ru + en)
    _agg_funcs = {'Сумма','Количество','Минимум','Максимум','Среднее',
                  'Sum','Count','Min','Max','Avg',
                  'Minimum','Maximum','Average'}

    if re.match(r'^\w+\(', func_part):
        return {'dataPath': data_path, 'expression': func_part}
    elif func_part in _agg_funcs:
        return {'dataPath': data_path, 'expression': f'{func_part}({data_path})'}
    else:
        # Identity or custom expression — use as-is
        return {'dataPath': data_path, 'expression': func_part}


# --- Parameter shorthand parser ---

def split_value_list_csv(s):
    """Split on top-level commas (respecting single/double quotes), strip quotes,
    drop empties. No ':' handling — values may contain colons (dateTime)."""
    result = []
    if s is None:
        return result
    items = []
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
    for raw in items:
        t = raw.strip()
        if len(t) >= 2 and ((t[0] == "'" and t[-1] == "'") or (t[0] == '"' and t[-1] == '"')):
            t = t[1:-1]
        if t != "":
            result.append(t)
    return result


def parse_param_shorthand(s):
    result = {'name': '', 'type': '', 'value': None, 'autoDates': False, 'title': None}

    # Extract @autoDates flag
    if '@autoDates' in s:
        result['autoDates'] = True
        s = re.sub(r'\s*@autoDates', '', s)

    # Extract @valueList flag
    if '@valueList' in s:
        result['valueListAllowed'] = True
        s = re.sub(r'\s*@valueList', '', s)

    # Extract @hidden flag
    if '@hidden' in s:
        result['hidden'] = True
        s = re.sub(r'\s*@hidden', '', s)

    # Extract optional [Title] (mirrors parse_field_shorthand)
    m = re.search(r'\[([^\]]*)\]', s)
    if m:
        result['title'] = m.group(1).strip()
        s = re.sub(r'\s*\[[^\]]*\]\s*', ' ', s).strip()

    # Split "Name: Type = Value" — RHS may be empty (`= ` / `=`) → treated as empty value
    m = re.match(r'^([^:]+):\s*(\S+)(\s*=\s*(.*))?$', s)
    if m:
        result['name'] = m.group(1).strip()
        result['type'] = resolve_type_str(m.group(2).strip())
        if m.group(4):
            rhs = m.group(4).strip()
            items = split_value_list_csv(rhs)
            if len(items) >= 2:
                # Multi-value default → list; valueListAllowed implied
                result['value'] = items
                result['valueListAllowed'] = True
            elif len(items) == 1:
                result['value'] = items[0]
            else:
                result['value'] = rhs
    else:
        result['name'] = s.strip()

    return result


# --- Calculated field shorthand parser ---

def parse_calc_shorthand(s):
    # Pattern: "Name [Title]: type = Expression #noField #noFilter ...".
    # - `[Title]` is extracted only from the LHS of '=' so that `[...]` inside
    #   an expression (e.g. index access) isn't interpreted as a title.
    # - `#restrict` flags use a known-names pattern and are extracted globally —
    #   the docs put them after `=`, and the closed flag set avoids matching
    #   `#word` that happens to appear inside a string literal.
    restrict_pattern = r'#(noField|noFilter|noCondition|noGroup|noOrder)\b'

    restrict = re.findall(restrict_pattern, s)
    s = re.sub(r'\s*' + restrict_pattern, '', s)

    eq_idx = s.find('=')
    if eq_idx > 0:
        lhs = s[:eq_idx]
        rhs = s[eq_idx + 1:].strip()
    else:
        lhs = s
        rhs = ''

    title = ''
    m = re.search(r'\[([^\]]+)\]', lhs)
    if m:
        title = m.group(1)
        lhs = re.sub(r'\s*\[[^\]]+\]', '', lhs)
    lhs = lhs.strip()

    type_str = ''
    data_path = lhs
    if ':' in lhs:
        colon_idx = lhs.index(':')
        data_path = lhs[:colon_idx].strip()
        type_str = resolve_type_str(lhs[colon_idx + 1:].strip())

    return {
        'dataPath': data_path,
        'expression': rhs,
        'type': type_str,
        'title': title,
        'restrict': restrict,
    }


# --- DataParameter shorthand parser ---

PERIOD_VARIANTS = [
    "Custom", "Today", "ThisWeek", "ThisTenDays", "ThisMonth", "ThisQuarter",
    "ThisHalfYear", "ThisYear", "FromBeginningOfThisWeek", "FromBeginningOfThisTenDays",
    "FromBeginningOfThisMonth", "FromBeginningOfThisQuarter", "FromBeginningOfThisHalfYear",
    "FromBeginningOfThisYear", "LastWeek", "LastTenDays", "LastMonth", "LastQuarter",
    "LastHalfYear", "LastYear", "NextDay", "NextWeek", "NextTenDays", "NextMonth",
    "NextQuarter", "NextHalfYear", "NextYear", "TillEndOfThisWeek", "TillEndOfThisTenDays",
    "TillEndOfThisMonth", "TillEndOfThisQuarter", "TillEndOfThisHalfYear", "TillEndOfThisYear",
]


def parse_data_param_shorthand(s):
    result = {'parameter': '', 'value': None, 'use': True, 'userSettingID': None, 'viewMode': None}

    # Extract @flags
    if '@user' in s:
        result['userSettingID'] = 'auto'
        s = re.sub(r'\s*@user', '', s)
    if '@off' in s:
        result['use'] = False
        s = re.sub(r'\s*@off', '', s)
    if '@quickAccess' in s:
        result['viewMode'] = 'QuickAccess'
        s = re.sub(r'\s*@quickAccess', '', s)
    if '@normal' in s:
        result['viewMode'] = 'Normal'
        s = re.sub(r'\s*@normal', '', s)

    s = s.strip()

    # Split "Name = Value"
    m = re.match(r'^([^=]+)=\s*(.+)$', s)
    if m:
        result['parameter'] = m.group(1).strip()
        val_str = m.group(2).strip()

        if val_str in PERIOD_VARIANTS:
            result['value'] = {'variant': val_str}
        elif re.match(r'^\d{4}-\d{2}-\d{2}T', val_str):
            result['value'] = val_str
        elif val_str == 'true' or val_str == 'false':
            result['value'] = val_str == 'true'
        else:
            result['value'] = val_str
    else:
        result['parameter'] = s

    return result


# --- Filter item shorthand parser ---

def parse_filter_shorthand(s):
    result = {'field': '', 'op': 'Equal', 'value': None, 'use': True,
              'userSettingID': None, 'viewMode': None, 'presentation': None}

    # Extract @flags
    if '@user' in s:
        result['userSettingID'] = 'auto'
        s = re.sub(r'\s*@user', '', s)
    if '@off' in s:
        result['use'] = False
        s = re.sub(r'\s*@off', '', s)
    if '@quickAccess' in s:
        result['viewMode'] = 'QuickAccess'
        s = re.sub(r'\s*@quickAccess', '', s)
    if '@normal' in s:
        result['viewMode'] = 'Normal'
        s = re.sub(r'\s*@normal', '', s)
    if '@inaccessible' in s:
        result['viewMode'] = 'Inaccessible'
        s = re.sub(r'\s*@inaccessible', '', s)

    s = s.strip()

    # Operators sorted longest first
    op_patterns = [
        '<>', '>=', '<=', '=', '>', '<',
        r'notIn\b', r'in\b', r'inHierarchy\b', r'inListByHierarchy\b',
        r'notContains\b', r'contains\b', r'notBeginsWith\b', r'beginsWith\b',
        r'notFilled\b', r'filled\b',
    ]
    op_joined = '|'.join(op_patterns)

    m = re.match(rf'^(.+?)\s+({op_joined})\s*(.*)?$', s)
    if m:
        result['field'] = m.group(1).strip()
        op_raw = m.group(2).strip()
        val_part = m.group(3).strip() if m.group(3) else ''

        # Parse value (skip "_" which means empty/placeholder)
        if val_part and val_part != '_':
            if val_part == 'true' or val_part == 'false':
                result['value'] = val_part == 'true'
                result['valueType'] = 'xs:boolean'
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', val_part):
                result['value'] = val_part
                result['valueType'] = 'xs:dateTime'
            elif re.match(r'^\d+(\.\d+)?$', val_part):
                result['value'] = val_part
                result['valueType'] = 'xs:decimal'
            elif re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.', val_part):
                result['value'] = val_part
                result['valueType'] = 'dcscor:DesignTimeValue'
            else:
                result['value'] = val_part
                result['valueType'] = 'xs:string'

        result['op'] = op_raw
    else:
        result['field'] = s

    return result


# --- Comparison type mapper ---

COMPARISON_TYPES = {
    '=': 'Equal', '<>': 'NotEqual',
    '>': 'Greater', '>=': 'GreaterOrEqual',
    '<': 'Less', '<=': 'LessOrEqual',
    'in': 'InList', 'notIn': 'NotInList',
    'inHierarchy': 'InHierarchy', 'inListByHierarchy': 'InListByHierarchy',
    'contains': 'Contains', 'notContains': 'NotContains',
    'beginsWith': 'BeginsWith', 'notBeginsWith': 'NotBeginsWith',
    'filled': 'Filled', 'notFilled': 'NotFilled',
}

# --- Output parameter type detection ---

OUTPUT_PARAM_TYPES = {
    "\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a": "mltext",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a": "dcsset:DataCompositionTextOutputType",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b\u0414\u0430\u043d\u043d\u044b\u0445": "dcsset:DataCompositionTextOutputType",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u041e\u0442\u0431\u043e\u0440": "dcsset:DataCompositionTextOutputType",
    "\u041c\u0430\u043a\u0435\u0442\u041e\u0444\u043e\u0440\u043c\u043b\u0435\u043d\u0438\u044f": "xs:string",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041f\u043e\u043b\u0435\u0439\u0413\u0440\u0443\u043f\u043f\u0438\u0440\u043e\u0432\u043a\u0438": "dcsset:DataCompositionGroupFieldsPlacement",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u043e\u0432": "dcsset:DataCompositionAttributesPlacement",
    "\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041e\u0431\u0449\u0438\u0445\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
    "\u0412\u0435\u0440\u0442\u0438\u043a\u0430\u043b\u044c\u043d\u043e\u0435\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041e\u0431\u0449\u0438\u0445\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041e\u0431\u0449\u0438\u0445\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u0413\u0440\u0443\u043f\u043f\u0438\u0440\u043e\u0432\u043a\u0438": "dcsset:DataCompositionFieldGroupPlacement",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u0420\u0435\u0441\u0443\u0440\u0441\u043e\u0432": "dcsset:DataCompositionResourcesPlacement",
    "\u0422\u0438\u043f\u041c\u0430\u043a\u0435\u0442\u0430": "dcsset:DataCompositionGroupTemplateType",
}


# ===== Emit sections =====

def emit_data_sources(lines, data_sources):
    for ds in data_sources:
        lines.append('\t<dataSource>')
        lines.append(f'\t\t<name>{esc_xml(ds["name"])}</name>')
        lines.append(f'\t\t<dataSourceType>{esc_xml(ds["type"])}</dataSourceType>')
        lines.append('\t</dataSource>')


# === Fields ===

def emit_input_parameters(lines, ip, indent):
    if not ip:
        return
    items = list(ip)
    if len(items) == 0:
        return
    lines.append(f'{indent}<inputParameters>')
    for item in items:
        lines.append(f'{indent}\t<dcscor:item>')
        if 'use' in item and item['use'] is False:
            lines.append(f'{indent}\t\t<dcscor:use>false</dcscor:use>')
        lines.append(f'{indent}\t\t<dcscor:parameter>{esc_xml(str(item.get("parameter", "")))}</dcscor:parameter>')
        if 'choiceParameters' in item:
            cp_items = list(item['choiceParameters']) if item['choiceParameters'] else []
            if len(cp_items) == 0:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameters"/>')
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameters">')
                for cp in cp_items:
                    lines.append(f'{indent}\t\t\t<dcscor:item>')
                    lines.append(f'{indent}\t\t\t\t<dcscor:choiceParameter>{esc_xml(str(cp.get("name", "")))}</dcscor:choiceParameter>')
                    for v in cp.get('values', []) or []:
                        if isinstance(v, bool):
                            vs = 'true' if v else 'false'
                            lines.append(f'{indent}\t\t\t\t<dcscor:value xsi:type="xs:boolean">{vs}</dcscor:value>')
                        elif isinstance(v, (int, float)):
                            lines.append(f'{indent}\t\t\t\t<dcscor:value xsi:type="xs:decimal">{v}</dcscor:value>')
                        else:
                            lines.append(f'{indent}\t\t\t\t<dcscor:value xsi:type="dcscor:DesignTimeValue">{esc_xml(str(v))}</dcscor:value>')
                    lines.append(f'{indent}\t\t\t</dcscor:item>')
                lines.append(f'{indent}\t\t</dcscor:value>')
        elif 'choiceParameterLinks' in item:
            cpl_items = list(item['choiceParameterLinks']) if item['choiceParameterLinks'] else []
            if len(cpl_items) == 0:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameterLinks"/>')
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameterLinks">')
                for cpl in cpl_items:
                    lines.append(f'{indent}\t\t\t<dcscor:item>')
                    lines.append(f'{indent}\t\t\t\t<dcscor:choiceParameter>{esc_xml(str(cpl.get("name", "")))}</dcscor:choiceParameter>')
                    lines.append(f'{indent}\t\t\t\t<dcscor:value>{esc_xml(str(cpl.get("value", "")))}</dcscor:value>')
                    mode = cpl.get('mode') or 'Auto'
                    lines.append(f'{indent}\t\t\t\t<dcscor:mode xmlns:d8p1="http://v8.1c.ru/8.1/data/enterprise" xsi:type="d8p1:LinkedValueChangeMode">{mode}</dcscor:mode>')
                    lines.append(f'{indent}\t\t\t</dcscor:item>')
                lines.append(f'{indent}\t\t</dcscor:value>')
        elif 'value' in item:
            val = item['value']
            # Явный кастомный type из decompile: {uri, name}
            vt_src = item.get('valueType')
            custom_uri = None; custom_name = None
            if isinstance(vt_src, dict):
                custom_uri = vt_src.get('uri')
                custom_name = vt_src.get('name')
            if custom_uri and custom_name:
                lines.append(f'{indent}\t\t<dcscor:value xmlns:dN="{custom_uri}" xsi:type="dN:{custom_name}">{esc_xml(str(val))}</dcscor:value>')
            elif isinstance(val, bool):
                vstr = 'true' if val else 'false'
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:boolean">{vstr}</dcscor:value>')
            elif isinstance(val, (int, float)):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:decimal">{val}</dcscor:value>')
            elif isinstance(val, dict):
                # Multilang dict {ru, en, ...} → LocalStringType
                emit_mltext(lines, f'{indent}\t\t', 'dcscor:value', val)
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')
        lines.append(f'{indent}\t</dcscor:item>')
    lines.append(f'{indent}</inputParameters>')


def emit_field(lines, field_def, indent):
    if isinstance(field_def, str):
        f = parse_field_shorthand(field_def)
    else:
        f = {
            'dataPath': str(field_def.get('dataPath', '')) or str(field_def.get('field', '')),
            'field': str(field_def.get('field', '')) or str(field_def.get('dataPath', '')),
            'title': field_def.get('title') if field_def.get('title') else '',
            'type': (
                [resolve_type_str(str(t)) for t in field_def['type']]
                if isinstance(field_def['type'], list)
                else resolve_type_str(str(field_def['type']))
            ) if field_def.get('type') else '',
            'roles': [],
            'restrict': [],
            'appearance': {},
            'roleExtras': {},
        }
        # Parse role (string shorthand / list / dict — единый формат с /skd-edit set-field-role)
        if field_def.get('role') is not None:
            parsed = parse_role_spec(field_def['role'])
            f['roles'] = parsed['tokens']
            f['roleExtras'] = parsed['extras']
        # Parse restrictions
        if field_def.get('restrict'):
            f['restrict'] = list(field_def['restrict'])
        # Parse appearance (сохраняем значение как есть — может быть string или multilang dict)
        if field_def.get('appearance'):
            for k, v in field_def['appearance'].items():
                f['appearance'][k] = v
        if field_def.get('presentationExpression'):
            f['presentationExpression'] = str(field_def['presentationExpression'])
        # attrRestrict
        if field_def.get('attrRestrict'):
            f['attrRestrict'] = list(field_def['attrRestrict'])
        # availableValues — array of {value, presentation}
        if field_def.get('availableValues'):
            f['availableValues'] = field_def['availableValues']
        # orderExpression — {expression, orderType, autoOrder}
        if field_def.get('orderExpression'):
            f['orderExpression'] = field_def['orderExpression']
        # inputParameters — массив элементов, типизированных по форме value
        if field_def.get('inputParameters') is not None:
            f['inputParameters'] = field_def['inputParameters']
        # folder: true → DataSetFieldFolder
        if field_def.get('folder') is True:
            f['folder'] = True

    # DataSetFieldFolder — только dataPath + title
    if f.get('folder'):
        lines.append(f'{indent}<field xsi:type="DataSetFieldFolder">')
        lines.append(f'{indent}\t<dataPath>{esc_xml(f["dataPath"])}</dataPath>')
        if f.get('title'):
            emit_mltext(lines, f'{indent}\t', 'title', f['title'])
        lines.append(f'{indent}</field>')
        return

    lines.append(f'{indent}<field xsi:type="DataSetFieldField">')
    lines.append(f'{indent}\t<dataPath>{esc_xml(f["dataPath"])}</dataPath>')
    lines.append(f'{indent}\t<field>{esc_xml(f["field"])}</field>')

    # Title
    if f.get('title'):
        emit_mltext(lines, f'{indent}\t', 'title', f['title'])

    # UseRestriction
    restrict_map = {
        'noField': 'field', 'noFilter': 'condition', 'noCondition': 'condition',
        'noGroup': 'group', 'noOrder': 'order',
    }
    if f.get('restrict') and len(f['restrict']) > 0:
        lines.append(f'{indent}\t<useRestriction>')
        for r in f['restrict']:
            xml_name = restrict_map.get(str(r))
            if xml_name:
                lines.append(f'{indent}\t\t<{xml_name}>true</{xml_name}>')
        lines.append(f'{indent}\t</useRestriction>')

    # AttributeUseRestriction
    if f.get('attrRestrict') and len(f['attrRestrict']) > 0:
        lines.append(f'{indent}\t<attributeUseRestriction>')
        for r in f['attrRestrict']:
            xml_name = restrict_map.get(str(r))
            if xml_name:
                lines.append(f'{indent}\t\t<{xml_name}>true</{xml_name}>')
        lines.append(f'{indent}\t</attributeUseRestriction>')

    # Role
    extras = f.get('roleExtras') or {}
    has_extras = len(extras) > 0
    if (f.get('roles') and len(f['roles']) > 0) or has_extras:
        lines.append(f'{indent}\t<role>')
        for role in f.get('roles', []):
            if role == 'period':
                # @period — sugar для periodNumber=1 + periodType=Main; extras могут переопределить.
                if 'periodNumber' not in extras:
                    lines.append(f'{indent}\t\t<dcscom:periodNumber>1</dcscom:periodNumber>')
                if 'periodType' not in extras:
                    lines.append(f'{indent}\t\t<dcscom:periodType>Main</dcscom:periodType>')
            else:
                lines.append(f'{indent}\t\t<dcscom:{role}>true</dcscom:{role}>')
        for k, v in extras.items():
            lines.append(f'{indent}\t\t<dcscom:{k}>{esc_xml(str(v))}</dcscom:{k}>')
        lines.append(f'{indent}\t</role>')

    # OrderExpression — после role, до valueType
    if f.get('orderExpression'):
        oe_raw = f['orderExpression']
        oe_list = oe_raw if isinstance(oe_raw, list) else [oe_raw]
        for oe in oe_list:
            expr = str(oe.get('expression', ''))
            o_type = str(oe.get('orderType', 'Asc'))
            auto = oe.get('autoOrder', False)
            auto_str = 'true' if auto else 'false'
            lines.append(f'{indent}\t<orderExpression>')
            lines.append(f'{indent}\t\t<dcscom:expression>{esc_xml(expr)}</dcscom:expression>')
            lines.append(f'{indent}\t\t<dcscom:orderType>{o_type}</dcscom:orderType>')
            lines.append(f'{indent}\t\t<dcscom:autoOrder>{auto_str}</dcscom:autoOrder>')
            lines.append(f'{indent}\t</orderExpression>')

    # ValueType
    if f.get('type'):
        lines.append(f'{indent}\t<valueType>')
        emit_value_type(lines, f['type'], f'{indent}\t\t')
        lines.append(f'{indent}\t</valueType>')

    # AvailableValues — list of allowed values with optional multilang presentation
    if f.get('availableValues'):
        for av in f['availableValues']:
            lines.append(f'{indent}\t<availableValue>')
            av_val = av.get('value')
            av_type = str(av.get('valueType', '')) if av.get('valueType') else ''
            if not av_type:
                if isinstance(av_val, bool):
                    av_type = 'xs:boolean'
                elif isinstance(av_val, (int, float)):
                    av_type = 'xs:decimal'
                elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(av_val)):
                    av_type = 'xs:dateTime'
                else:
                    av_type = 'xs:string'
            av_str = str(av_val).lower() if isinstance(av_val, bool) else esc_xml(str(av_val))
            lines.append(f'{indent}\t\t<value xsi:type="{av_type}">{av_str}</value>')
            if av.get('presentation'):
                emit_mltext(lines, f'{indent}\t\t', 'presentation', av['presentation'])
            lines.append(f'{indent}\t</availableValue>')

    # Appearance
    if f.get('appearance') and len(f['appearance']) > 0:
        lines.append(f'{indent}\t<appearance>')
        for key, val in f['appearance'].items():
            # \u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u041f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435 \u0442\u0440\u0435\u0431\u0443\u0435\u0442 \u0441\u043f\u0435\u0446\u0438\u0430\u043b\u044c\u043d\u043e\u0433\u043e xsi:type, \u043d\u0435 \u0441\u0442\u0440\u043e\u043a\u0430
            if key == '\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u041f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435' and not isinstance(val, dict):
                lines.append(f'{indent}\t\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
                lines.append(f'{indent}\t\t\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')
                lines.append(f'{indent}\t\t\t<dcscor:value xsi:type="v8ui:HorizontalAlign">{esc_xml(str(val))}</dcscor:value>')
                lines.append(f'{indent}\t\t</dcscor:item>')
            else:
                emit_appearance_value(lines, key, val, f'{indent}\t\t')
        lines.append(f'{indent}\t</appearance>')

    # PresentationExpression
    if f.get('presentationExpression'):
        lines.append(f'{indent}\t<presentationExpression>{esc_xml(f["presentationExpression"])}</presentationExpression>')

    # InputParameters — в конце field
    if f.get('inputParameters'):
        emit_input_parameters(lines, f['inputParameters'], f'{indent}\t')

    lines.append(f'{indent}</field>')


# === DataSets ===

def emit_data_set(lines, ds, indent, default_source, tag_name='dataSet'):
    # Determine type
    if ds.get('items'):
        ds_type = 'DataSetUnion'
    elif ds.get('objectName'):
        ds_type = 'DataSetObject'
    else:
        ds_type = 'DataSetQuery'

    lines.append(f'{indent}<{tag_name} xsi:type="{ds_type}">')
    lines.append(f'{indent}\t<name>{esc_xml(str(ds.get("name", "")))}</name>')

    # Fields
    if ds.get('fields'):
        for f in ds['fields']:
            emit_field(lines, f, f'{indent}\t')

    # DataSource (not for Union)
    if ds_type != 'DataSetUnion':
        src = str(ds['source']) if ds.get('source') else default_source
        lines.append(f'{indent}\t<dataSource>{esc_xml(src)}</dataSource>')

    # Type-specific content
    if ds_type == 'DataSetQuery':
        query_text = resolve_query_value(str(ds.get("query", "")), query_base_dir)
        lines.append(f'{indent}\t<query>{esc_xml(query_text)}</query>')
        if ds.get('autoFillFields') is False:
            lines.append(f'{indent}\t<autoFillFields>false</autoFillFields>')
    elif ds_type == 'DataSetObject':
        lines.append(f'{indent}\t<objectName>{esc_xml(str(ds["objectName"]))}</objectName>')
    elif ds_type == 'DataSetUnion':
        for item in ds['items']:
            # Union inner items are wrapped as <item xsi:type="...">
            emit_data_set(lines, item, f'{indent}\t', default_source, tag_name='item')

    lines.append(f'{indent}</{tag_name}>')


def emit_data_sets(lines, defn, default_source):
    for ds in defn['dataSets']:
        emit_data_set(lines, ds, '\t', default_source)


# === DataSetLinks ===

def emit_data_set_links(lines, defn):
    if not defn.get('dataSetLinks'):
        return
    for link in defn['dataSetLinks']:
        lines.append('\t<dataSetLink>')
        src_ds = str(link.get('source') or link.get('sourceDataSet') or '')
        dst_ds = str(link.get('dest') or link.get('destinationDataSet') or '')
        src_ex = str(link.get('sourceExpr') or link.get('sourceExpression') or '')
        dst_ex = str(link.get('destExpr') or link.get('destinationExpression') or '')
        lines.append(f'\t\t<sourceDataSet>{esc_xml(src_ds)}</sourceDataSet>')
        lines.append(f'\t\t<destinationDataSet>{esc_xml(dst_ds)}</destinationDataSet>')
        lines.append(f'\t\t<sourceExpression>{esc_xml(src_ex)}</sourceExpression>')
        lines.append(f'\t\t<destinationExpression>{esc_xml(dst_ex)}</destinationExpression>')
        if link.get('parameter'):
            lines.append(f'\t\t<parameter>{esc_xml(str(link["parameter"]))}</parameter>')
        if link.get('parameterListAllowed'):
            lines.append('\t\t<parameterListAllowed>true</parameterListAllowed>')
        if link.get('startExpression') is not None:
            lines.append(f'\t\t<startExpression>{esc_xml(str(link["startExpression"]))}</startExpression>')
        if link.get('linkConditionExpression') is not None:
            lines.append(f'\t\t<linkConditionExpression>{esc_xml(str(link["linkConditionExpression"]))}</linkConditionExpression>')
        lines.append('\t</dataSetLink>')


# === CalculatedFields ===

def emit_calc_fields(lines, defn):
    if not defn.get('calculatedFields'):
        return
    restrict_map = {
        'noField': 'field', 'noFilter': 'condition', 'noCondition': 'condition',
        'noGroup': 'group', 'noOrder': 'order',
    }
    for cf in defn['calculatedFields']:
        # Collect dataPath/expression/title/type/restrict/appearance from either
        # shorthand string or object form. Object form accepts dataPath/field/name
        # as synonyms; useRestriction/restrict accepts object, array, or flag string.
        title = ''
        type_str = ''
        restrict_tokens = []
        restrict_obj = None
        appearance = None

        if isinstance(cf, str):
            parsed = parse_calc_shorthand(cf)
            data_path = parsed['dataPath']
            expression = parsed['expression']
            title = parsed.get('title', '') or ''
            type_str = parsed.get('type', '') or ''
            restrict_tokens = list(parsed.get('restrict') or [])
        else:
            data_path = str(cf.get('dataPath') or cf.get('field') or cf.get('name') or '')
            expression = str(cf.get('expression', ''))
            if cf.get('title'):
                title = cf['title']
            if cf.get('type'):
                type_str = resolve_type_str(str(cf['type']))

            restrict_val = cf.get('restrict') if cf.get('restrict') is not None else cf.get('useRestriction')
            if restrict_val:
                if isinstance(restrict_val, dict):
                    restrict_obj = restrict_val
                elif isinstance(restrict_val, str):
                    # Flag-string form: "#noField #noFilter #noGroup #noOrder" (or without `#`)
                    for tok in restrict_val.split():
                        t = tok.strip().lstrip('#')
                        if t:
                            restrict_tokens.append(t)
                else:
                    # Array form: ["noField", "noFilter", ...]
                    for r in restrict_val:
                        restrict_tokens.append(str(r))
            appearance = cf.get('appearance')

        lines.append('\t<calculatedField>')
        lines.append(f'\t\t<dataPath>{esc_xml(data_path)}</dataPath>')
        lines.append(f'\t\t<expression>{esc_xml(expression)}</expression>')

        if title:
            emit_mltext(lines, '\t\t', 'title', title)
        if type_str:
            lines.append('\t\t<valueType>')
            emit_value_type(lines, type_str, '\t\t\t')
            lines.append('\t\t</valueType>')
        if restrict_obj or restrict_tokens:
            lines.append('\t\t<useRestriction>')
            if restrict_obj:
                for xml_name, flag in restrict_obj.items():
                    if flag:
                        lines.append(f'\t\t\t<{esc_xml(str(xml_name))}>true</{esc_xml(str(xml_name))}>')
            else:
                for r in restrict_tokens:
                    xml_name = restrict_map.get(str(r))
                    if xml_name:
                        lines.append(f'\t\t\t<{xml_name}>true</{xml_name}>')
            lines.append('\t\t</useRestriction>')
        if appearance:
            lines.append('\t\t<appearance>')
            for k, v in appearance.items():
                if k == 'ГоризонтальноеПоложение' and not isinstance(v, dict):
                    lines.append('\t\t\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
                    lines.append(f'\t\t\t\t<dcscor:parameter>{esc_xml(k)}</dcscor:parameter>')
                    lines.append(f'\t\t\t\t<dcscor:value xsi:type="v8ui:HorizontalAlign">{esc_xml(str(v))}</dcscor:value>')
                    lines.append('\t\t\t</dcscor:item>')
                else:
                    emit_appearance_value(lines, k, v, '\t\t\t')
            lines.append('\t\t</appearance>')

        lines.append('\t</calculatedField>')


# === TotalFields ===

def emit_total_fields(lines, defn):
    if not defn.get('totalFields'):
        return
    for tf in defn['totalFields']:
        if isinstance(tf, str):
            parsed = parse_total_shorthand(tf)
            groups = None
        else:
            parsed = {
                'dataPath': str(tf.get('dataPath', '')),
                'expression': str(tf.get('expression', '')),
            }
            groups = tf.get('group')

        lines.append('\t<totalField>')
        lines.append(f'\t\t<dataPath>{esc_xml(parsed["dataPath"])}</dataPath>')
        lines.append(f'\t\t<expression>{esc_xml(parsed["expression"])}</expression>')
        if groups:
            if isinstance(groups, list):
                for g in groups:
                    lines.append(f'\t\t<group>{esc_xml(str(g))}</group>')
            else:
                lines.append(f'\t\t<group>{esc_xml(str(groups))}</group>')
        lines.append('\t</totalField>')


# === Parameters ===

def is_empty_value(v):
    if v is None:
        return True
    s = str(v).strip()
    if s == '':
        return True
    if s == '_':
        return True
    if s.lower() == 'null':
        return True
    return False


def emit_empty_value(lines, type_str, indent, tag_prefix='', value_list_allowed=False):
    if value_list_allowed:
        return
    t = type_str or ''
    # Нормализация: убираем префикс xs: (валидный для valueType из decompile/DSL)
    t_bare = t[3:] if t.startswith('xs:') else t
    pf = tag_prefix

    if t == '':
        lines.append(f'{indent}<{pf}value xsi:nil="true"/>')
    elif t == 'StandardPeriod':
        lines.append(f'{indent}<{pf}value xsi:type="v8:StandardPeriod">')
        lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">Custom</v8:variant>')
        lines.append(f'{indent}\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>')
        lines.append(f'{indent}\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>')
        lines.append(f'{indent}</{pf}value>')
    elif re.match(r'^string', t_bare):
        lines.append(f'{indent}<{pf}value xsi:type="xs:string"/>')
    elif re.match(r'^(date|time)', t_bare):
        lines.append(f'{indent}<{pf}value xsi:type="xs:dateTime">0001-01-01T00:00:00</{pf}value>')
    elif re.match(r'^decimal', t_bare):
        lines.append(f'{indent}<{pf}value xsi:type="xs:decimal">0</{pf}value>')
    elif t_bare == 'boolean':
        lines.append(f'{indent}<{pf}value xsi:type="xs:boolean">false</{pf}value>')
    else:
        # Ref types or unknown — safe nil
        lines.append(f'{indent}<{pf}value xsi:nil="true"/>')


def emit_param_value(lines, type_str, val, indent, value_list_allowed=False):
    if is_empty_value(val):
        emit_empty_value(lines, type_str, indent, '', value_list_allowed)
        return

    # val может быть строкой (variant only) или dict {variant, startDate?, endDate?}.
    variant_str = None
    sd_str = None
    ed_str = None
    if isinstance(val, dict):
        variant_str = str(val.get('variant')) if val.get('variant') is not None else None
        sd_str = str(val['startDate']) if 'startDate' in val else None
        ed_str = str(val['endDate']) if 'endDate' in val else None
    val_str = variant_str if variant_str else str(val)

    if type_str == 'StandardPeriod':
        # Platform-pattern: startDate/endDate ТОЛЬКО для variant=Custom.
        lines.append(f'{indent}<value xsi:type="v8:StandardPeriod">')
        lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(val_str)}</v8:variant>')
        if val_str == 'Custom':
            sd_out = sd_str if sd_str else '0001-01-01T00:00:00'
            ed_out = ed_str if ed_str else '0001-01-01T00:00:00'
            lines.append(f'{indent}\t<v8:startDate>{esc_xml(sd_out)}</v8:startDate>')
            lines.append(f'{indent}\t<v8:endDate>{esc_xml(ed_out)}</v8:endDate>')
        lines.append(f'{indent}</value>')
    elif type_str and re.match(r'^date', type_str):
        lines.append(f'{indent}<value xsi:type="xs:dateTime">{esc_xml(val_str)}</value>')
    elif type_str == 'boolean':
        lines.append(f'{indent}<value xsi:type="xs:boolean">{esc_xml(val_str)}</value>')
    elif type_str and re.match(r'^decimal', type_str):
        lines.append(f'{indent}<value xsi:type="xs:decimal">{esc_xml(val_str)}</value>')
    elif type_str and re.match(r'^string', type_str):
        lines.append(f'{indent}<value xsi:type="xs:string">{esc_xml(val_str)}</value>')
    elif type_str and re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef)\.', type_str):
        lines.append(f'{indent}<value xsi:type="dcscor:DesignTimeValue">{esc_xml(val_str)}</value>')
    else:
        # Guess from value
        if re.match(r'^\d{4}-\d{2}-\d{2}T', val_str):
            lines.append(f'{indent}<value xsi:type="xs:dateTime">{esc_xml(val_str)}</value>')
        elif val_str == 'true' or val_str == 'false':
            lines.append(f'{indent}<value xsi:type="xs:boolean">{esc_xml(val_str)}</value>')
        elif re.match(r'^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', val_str):
            lines.append(f'{indent}<value xsi:type="dcscor:DesignTimeValue">{esc_xml(val_str)}</value>')
        else:
            lines.append(f'{indent}<value xsi:type="xs:string">{esc_xml(val_str)}</value>')


def emit_single_param(lines, p, parsed):
    lines.append('\t<parameter>')
    lines.append(f'\t\t<name>{esc_xml(parsed["name"])}</name>')

    # Title (from parsed first, then from object form; accept `presentation` as
    # a synonym — 1C UI labels a parameter's caption "Представление").
    title = ''
    if parsed.get('title'):
        title = parsed['title']
    elif p is not None and not isinstance(p, str) and p.get('title'):
        title = p['title']
    elif p is not None and not isinstance(p, str) and p.get('presentation'):
        title = p['presentation']
    if title:
        emit_mltext(lines, '\t\t', 'title', title)

    # ValueType
    if parsed.get('type'):
        lines.append('\t\t<valueType>')
        emit_value_type(lines, parsed['type'], '\t\t\t')
        lines.append('\t\t</valueType>')

    # Value — for valueListAllowed params Designer omits <value> when empty
    vla = bool(parsed.get('valueListAllowed'))
    p_type = parsed.get('type', '')
    if isinstance(p_type, (list, tuple)):
        # Composite type — Designer writes xsi:nil for any empty composite;
        # non-empty composite values are uncommon and would need per-type tagging.
        if is_empty_value(parsed.get('value')):
            if not vla:
                lines.append('\t\t<value xsi:nil="true"/>')
    elif parsed.get('nilValue') is True:
        # Принудительный xsi:nil даже когда тип известен (для bit-perfect round-trip).
        if not vla:
            lines.append('\t\t<value xsi:nil="true"/>')
    elif isinstance(parsed.get('value'), list):
        # Multi-value (массив значений по умолчанию для valueListAllowed-параметра).
        for v in parsed['value']:
            emit_param_value(lines, p_type, v, '\t\t', False)
    else:
        emit_param_value(lines, p_type, parsed.get('value'), '\t\t', vla)

    # Hidden implies useRestriction=true + availableAsField=false
    if parsed.get('hidden') is True:
        parsed['availableAsField'] = False
        parsed['useRestriction'] = True

    # UseRestriction — платформа всегда эмитит этот тег у параметра (true/false)
    ur_emit = (
        parsed.get('useRestriction') is True
        or (p is not None and not isinstance(p, str) and p.get('useRestriction') is True)
    )
    lines.append(f'\t\t<useRestriction>{"true" if ur_emit else "false"}</useRestriction>')

    # Expression
    if parsed.get('expression'):
        lines.append(f'\t\t<expression>{esc_xml(parsed["expression"])}</expression>')
    if parsed.get('hidden'):
        parsed['availableAsField'] = False

    # AvailableAsField
    if parsed.get('availableAsField') is False:
        lines.append('\t\t<availableAsField>false</availableAsField>')

    # ValueListAllowed
    if parsed.get('valueListAllowed'):
        lines.append('\t\t<valueListAllowed>true</valueListAllowed>')

    # AvailableValues
    if p is not None and not isinstance(p, str) and p.get('availableValues'):
        for av in p['availableValues']:
            lines.append('\t\t<availableValue>')
            if is_empty_value(av.get('value')):
                emit_empty_value(lines, parsed.get('type', ''), '\t\t\t', '', False)
            else:
                av_v = av['value']
                if isinstance(av_v, bool):
                    lines.append(f'\t\t\t<value xsi:type="xs:boolean">{str(av_v).lower()}</value>')
                elif isinstance(av_v, (int, float)):
                    lines.append(f'\t\t\t<value xsi:type="xs:decimal">{av_v}</value>')
                else:
                    av_val = str(av_v)
                    av_type = 'xs:string'
                    if re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.', av_val):
                        av_type = 'dcscor:DesignTimeValue'
                    lines.append(f'\t\t\t<value xsi:type="{av_type}">{esc_xml(av_val)}</value>')
            # `title` accepted as synonym of `presentation` — both map to the same UI label.
            av_pres = av.get('presentation') or av.get('title') or ''
            if av_pres:
                emit_mltext(lines, '\t\t\t', 'presentation', av_pres)
            lines.append('\t\t</availableValue>')

    # DenyIncompleteValues
    deny = parsed.get('denyIncompleteValues') is True or (
        p is not None and not isinstance(p, str) and p.get('denyIncompleteValues') is True)
    if deny:
        lines.append('\t\t<denyIncompleteValues>true</denyIncompleteValues>')

    # Use
    use_val = None
    if p is not None and not isinstance(p, str) and p.get('use'):
        use_val = str(p['use'])
    elif parsed.get('use'):
        use_val = str(parsed['use'])
    if use_val:
        lines.append(f'\t\t<use>{esc_xml(use_val)}</use>')

    # InputParameters на параметре (ФорматРедактирования и т.п.)
    if p is not None and not isinstance(p, str) and p.get('inputParameters'):
        emit_input_parameters(lines, p['inputParameters'], '\t\t')

    lines.append('\t</parameter>')


_all_params = []


def emit_parameters(lines, defn):
    global _all_params
    _all_params = []
    if not defn.get('parameters'):
        return
    for p in defn['parameters']:
        if isinstance(p, str):
            parsed = parse_param_shorthand(p)
        else:
            # Composite type: ["string(10,fix)", "CatalogRef.X"] → list of resolved
            # strings; emit_value_type handles lists, empty value falls through to nil.
            raw_type = p.get('type')
            if isinstance(raw_type, (list, tuple)):
                resolved_type = [resolve_type_str(str(t)) for t in raw_type]
            elif raw_type:
                resolved_type = resolve_type_str(str(raw_type))
            else:
                resolved_type = ''
            parsed = {
                'name': str(p.get('name', '')),
                'type': resolved_type,
                'value': p.get('value'),
                'autoDates': False,
            }
            if p.get('expression'):
                parsed['expression'] = str(p['expression'])
            if p.get('availableAsField') is False:
                parsed['availableAsField'] = False
            if p.get('valueListAllowed') is True:
                parsed['valueListAllowed'] = True
            if p.get('hidden') is True:
                parsed['hidden'] = True
            if p.get('autoDates') is True:
                parsed['autoDates'] = True
            if p.get('nilValue') is True:
                parsed['nilValue'] = True

        # @autoDates implies use=Always + denyIncompleteValues=true by default
        # (derived &НачалоПериода/&КонецПериода need a populated period).
        # Explicit values in object form override these defaults.
        if parsed.get('autoDates'):
            is_obj = p is not None and not isinstance(p, str)
            if not (is_obj and p.get('use') is not None):
                parsed['use'] = 'Always'
            if not (is_obj and p.get('denyIncompleteValues') is not None):
                parsed['denyIncompleteValues'] = True

        emit_single_param(lines, p, parsed)

        # Track parameter for auto dataParameters
        _all_params.append({
            'name': parsed['name'],
            'hidden': bool(parsed.get('hidden')),
            'type': parsed.get('type', ''),
            'value': parsed.get('value'),
        })

        # @autoDates: auto-generate НачалоПериода and КонецПериода (canonical БСП pattern).
        # type=dateTime + DateFractions=DateTime — иначе КонецПериода обрезается до 00:00:00
        # и запрос `Дата МЕЖДУ &НачалоПериода И &КонецПериода` теряет данные за последний день.
        if parsed.get('autoDates'):
            param_name = parsed['name']
            begin_parsed = {
                'name': '\u041d\u0430\u0447\u0430\u043b\u043e\u041f\u0435\u0440\u0438\u043e\u0434\u0430',
                'title': '\u041d\u0430\u0447\u0430\u043b\u043e \u043f\u0435\u0440\u0438\u043e\u0434\u0430',
                'type': 'dateTime', 'value': '0001-01-01T00:00:00',
                'useRestriction': True,
                'expression': f'&{param_name}.\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430',
            }
            emit_single_param(lines, None, begin_parsed)
            end_parsed = {
                'name': '\u041a\u043e\u043d\u0435\u0446\u041f\u0435\u0440\u0438\u043e\u0434\u0430',
                'title': '\u041a\u043e\u043d\u0435\u0446 \u043f\u0435\u0440\u0438\u043e\u0434\u0430',
                'type': 'dateTime', 'value': '0001-01-01T00:00:00',
                'useRestriction': True,
                'expression': f'&{param_name}.\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f',
            }
            emit_single_param(lines, None, end_parsed)


# === AreaTemplate DSL ===

AREA_STYLE_PRESETS = {
    'none': {
        'font': None, 'fontSize': None, 'bold': False, 'italic': False,
        'hAlign': None, 'vAlign': None, 'wrap': False,
        'bgColor': None, 'textColor': None,
        'borderColor': None, 'borders': False,
    },
    'data': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': None, 'vAlign': None, 'wrap': False,
        'bgColor': 'style:ReportGroup1BackColor', 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
    'header': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': 'Center', 'vAlign': None, 'wrap': True,
        'bgColor': 'style:ReportHeaderBackColor', 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
    'subheader': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': 'Center', 'vAlign': None, 'wrap': True,
        'bgColor': None, 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
    'total': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': None, 'vAlign': None, 'wrap': False,
        'bgColor': None, 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
}


def load_user_styles(base_dir, output_path=None):
    # Search order (first found wins): 1) definition dir, 2) cwd, 3) scan-up from OutputPath for presets/skills/skd/
    search_paths = [
        os.path.join(base_dir, 'skd-styles.json'),
        os.path.join(os.getcwd(), 'skd-styles.json'),
    ]
    if output_path:
        scan_dir = os.path.dirname(output_path)
        while scan_dir:
            search_paths.append(os.path.join(scan_dir, 'presets', 'skills', 'skd', 'skd-styles.json'))
            parent_dir = os.path.dirname(scan_dir)
            if parent_dir == scan_dir:
                break
            scan_dir = parent_dir
    for p in search_paths:
        if os.path.isfile(p):
            with open(p, 'r', encoding='utf-8-sig') as f:
                user_styles = json.load(f)
            for name, overrides in user_styles.items():
                base = dict(AREA_STYLE_PRESETS.get(name, AREA_STYLE_PRESETS['data']))
                base.update(overrides)
                AREA_STYLE_PRESETS[name] = base
            return


def _emit_color_value(lines, color, indent):
    # Префиксы style:/web:/win: → соответствующий xmlns + dN:Name
    color_prefix_to_uri = {
        'style:': 'http://v8.1c.ru/8.1/data/ui/style',
        'web:':   'http://v8.1c.ru/8.1/data/ui/colors/web',
        'win:':   'http://v8.1c.ru/8.1/data/ui/colors/windows',
    }
    for pfx, uri in color_prefix_to_uri.items():
        if color.startswith(pfx):
            name = color[len(pfx):]
            lines.append(f'{indent}<dcscor:value xmlns:d8p1="{uri}" xsi:type="v8ui:Color">d8p1:{name}</dcscor:value>')
            return
    lines.append(f'{indent}<dcscor:value xsi:type="v8ui:Color">{esc_xml(color)}</dcscor:value>')


def _emit_cell_appearance(lines, style, width=0, v_merge=False, h_merge=False, min_height=0, extra_items=None):
    ind = '\t\t\t\t\t\t'
    # Если ничего внутри appearance не будет — не эмитим блок вовсе
    # (оригинал платформы для cells без атрибутов не пишет <appearance></appearance>).
    has_content = bool(
        style.get('bgColor') or style.get('textColor') or style.get('borders') or
        style.get('font') or style.get('hAlign') or style.get('vAlign') or style.get('wrap') or
        (width > 0) or (min_height > 0) or v_merge or h_merge or
        (extra_items and len(extra_items) > 0)
    )
    if not has_content:
        return
    lines.append('\t\t\t\t\t<dcsat:appearance>')
    # Background color
    if style.get('bgColor'):
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u0426\u0432\u0435\u0442\u0424\u043e\u043d\u0430</dcscor:parameter>')
        _emit_color_value(lines, style['bgColor'], f'{ind}\t')
        lines.append(f'{ind}</dcscor:item>')
    # Text color
    if style.get('textColor'):
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u0426\u0432\u0435\u0442\u0422\u0435\u043a\u0441\u0442\u0430</dcscor:parameter>')
        _emit_color_value(lines, style['textColor'], f'{ind}\t')
        lines.append(f'{ind}</dcscor:item>')
    # Borders
    if style.get('borders'):
        if style.get('borderColor'):
            lines.append(f'{ind}<dcscor:item>')
            lines.append(f'{ind}\t<dcscor:parameter>\u0426\u0432\u0435\u0442\u0413\u0440\u0430\u043d\u0438\u0446\u044b</dcscor:parameter>')
            _emit_color_value(lines, style['borderColor'], f'{ind}\t')
            lines.append(f'{ind}</dcscor:item>')
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u0421\u0442\u0438\u043b\u044c\u0413\u0440\u0430\u043d\u0438\u0446\u044b</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="v8ui:Line" width="0" gap="false">')
        lines.append(f'{ind}\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">None</v8ui:style>')
        lines.append(f'{ind}\t</dcscor:value>')
        for side in ['\u0421\u043b\u0435\u0432\u0430', '\u0421\u0432\u0435\u0440\u0445\u0443', '\u0421\u043f\u0440\u0430\u0432\u0430', '\u0421\u043d\u0438\u0437\u0443']:
            lines.append(f'{ind}\t<dcscor:item>')
            lines.append(f'{ind}\t\t<dcscor:parameter>\u0421\u0442\u0438\u043b\u044c\u0413\u0440\u0430\u043d\u0438\u0446\u044b.{side}</dcscor:parameter>')
            lines.append(f'{ind}\t\t<dcscor:value xsi:type="v8ui:Line" width="1" gap="false">')
            lines.append(f'{ind}\t\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">Solid</v8ui:style>')
            lines.append(f'{ind}\t\t</dcscor:value>')
            lines.append(f'{ind}\t</dcscor:item>')
        lines.append(f'{ind}</dcscor:item>')
    # Font (skip if style has no font configured \u2014 for "none" preset)
    if style.get('font'):
        bold_str = 'true' if style.get('bold') else 'false'
        italic_str = 'true' if style.get('italic') else 'false'
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u0428\u0440\u0438\u0444\u0442</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="v8ui:Font" faceName="{style["font"]}" height="{style["fontSize"]}" bold="{bold_str}" italic="{italic_str}" underline="false" strikeout="false" kind="Absolute" scale="100"/>')
        lines.append(f'{ind}</dcscor:item>')
    # Horizontal alignment
    if style.get('hAlign'):
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u041f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="v8ui:HorizontalAlign">{esc_xml(style["hAlign"])}</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
    # Vertical alignment
    if style.get('vAlign'):
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u0412\u0435\u0440\u0442\u0438\u043a\u0430\u043b\u044c\u043d\u043e\u0435\u041f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="v8ui:VerticalAlign">{esc_xml(style["vAlign"])}</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
    # Wrap
    if style.get('wrap'):
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u0420\u0430\u0437\u043c\u0435\u0449\u0435\u043d\u0438\u0435</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="dcscor:DataCompositionTextPlacementType">Wrap</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
    # Width
    if width and width > 0:
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u041c\u0438\u043d\u0438\u043c\u0430\u043b\u044c\u043d\u0430\u044f\u0428\u0438\u0440\u0438\u043d\u0430</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="xs:decimal">{fmt_dec(width)}</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u041c\u0430\u043a\u0441\u0438\u043c\u0430\u043b\u044c\u043d\u0430\u044f\u0428\u0438\u0440\u0438\u043d\u0430</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="xs:decimal">{fmt_dec(width)}</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
    # Min height
    if min_height and min_height > 0:
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u041c\u0438\u043d\u0438\u043c\u0430\u043b\u044c\u043d\u0430\u044f\u0412\u044b\u0441\u043e\u0442\u0430</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="xs:decimal">{min_height}</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
    # Vertical merge
    if v_merge:
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u041e\u0431\u044a\u0435\u0434\u0438\u043d\u044f\u0442\u044c\u041f\u043e\u0412\u0435\u0440\u0442\u0438\u043a\u0430\u043b\u0438</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="xs:boolean">true</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
    # Horizontal merge
    if h_merge:
        lines.append(f'{ind}<dcscor:item>')
        lines.append(f'{ind}\t<dcscor:parameter>\u041e\u0431\u044a\u0435\u0434\u0438\u043d\u044f\u0442\u044c\u041f\u043e\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u0438</dcscor:parameter>')
        lines.append(f'{ind}\t<dcscor:value xsi:type="xs:boolean">true</dcscor:value>')
        lines.append(f'{ind}</dcscor:item>')
    # Extra appearance items (e.g. drilldown)
    if extra_items:
        for ei in extra_items:
            lines.append(ei)
    lines.append('\t\t\t\t\t</dcsat:appearance>')


# Cell может быть string ("text"/"{param}"/"|"/">"/null) или объектом {value, style}.
def _get_cell_value(cell):
    if cell is None:
        return None
    if isinstance(cell, str):
        return cell
    if isinstance(cell, dict):
        if 'value' in cell:
            return cell['value']
        return cell  # multilang dict without wrapper
    return None


def _get_cell_style_or_default(cell, default_style):
    if isinstance(cell, dict) and 'style' in cell:
        s_name = str(cell['style'])
        if s_name in AREA_STYLE_PRESETS:
            return AREA_STYLE_PRESETS[s_name]
        print(f"Warning: Unknown cell style preset '{s_name}', falling back to template default", file=sys.stderr)
    return default_style


def _emit_area_template_dsl(lines, t):
    style_name = str(t.get('style', '')) or 'data'
    if style_name not in AREA_STYLE_PRESETS:
        print(f"Warning: Unknown area style preset '{style_name}', falling back to 'data'", file=sys.stderr)
        style_name = 'data'
    style = AREA_STYLE_PRESETS[style_name]

    rows = list(t['rows'])
    widths = list(t.get('widths', []))
    min_height = float(t.get('minHeight', 0))
    col_count = len(widths) if widths else len(rows[0])

    # Build vertical merge map
    v_merge = {}
    for r in range(len(rows) - 1, 0, -1):
        v_merge[r] = {}
        for c in range(col_count):
            cell_val = _get_cell_value(rows[r][c]) if c < len(rows[r]) else None
            if cell_val == '|':
                v_merge[r][c] = True
    if 0 not in v_merge:
        v_merge[0] = {}

    # Build horizontal merge map
    h_merge = {}
    for r in range(len(rows)):
        h_merge[r] = {}
        for c in range(col_count):
            cell_val = _get_cell_value(rows[r][c]) if c < len(rows[r]) else None
            if cell_val == '>':
                h_merge[r][c] = True

    # Build drilldown map: param_name -> drilldown_value (только shortcut-форма: drilldown — строка).
    # Форма C (drilldown — объект) — DetailsAreaTemplateParameter с произвольным именем, в map не идёт.
    drilldown_map = {}
    if t.get('parameters'):
        for tp in t['parameters']:
            dd = tp.get('drilldown')
            if dd and isinstance(dd, str):
                drilldown_map[str(tp['name'])] = dd

    lines.append('\t<template>')
    lines.append(f'\t\t<name>{esc_xml(str(t["name"]))}</name>')
    lines.append('\t\t<template xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template" xsi:type="dcsat:AreaTemplate">')

    for r in range(len(rows)):
        lines.append('\t\t\t<dcsat:item xsi:type="dcsat:TableRow">')
        for c in range(col_count):
            cell_raw = rows[r][c] if c < len(rows[r]) else None
            cell_val = _get_cell_value(cell_raw)
            cell_style = _get_cell_style_or_default(cell_raw, style)
            w = float(widths[c]) if c < len(widths) else 0
            is_v_merged = v_merge.get(r, {}).get(c, False)
            is_h_merged = h_merge.get(r, {}).get(c, False)
            lines.append('\t\t\t\t<dcsat:tableCell>')
            if is_v_merged:
                _emit_cell_appearance(lines, cell_style, w, True)
            elif is_h_merged:
                _emit_cell_appearance(lines, cell_style, w, h_merge=True)
            else:
                cell_extra_items = []
                if isinstance(cell_val, dict):
                    # Multilang static text — эмитим напрямую
                    lines.append('\t\t\t\t\t<dcsat:item xsi:type="dcsat:Field">')
                    emit_mltext(lines, '\t\t\t\t\t\t', 'dcsat:value', cell_val)
                    lines.append('\t\t\t\t\t</dcsat:item>')
                elif cell_val is not None and str(cell_val) != '':
                    cell_str = str(cell_val)
                    # Unescape \| and \>
                    if cell_str == '\\|':
                        cell_str = '|'
                    elif cell_str == '\\>':
                        cell_str = '>'
                    m = re.match(r'^\{(.+)\}$', cell_str)
                    if m:
                        param_name = m.group(1)
                        lines.append('\t\t\t\t\t<dcsat:item xsi:type="dcsat:Field">')
                        lines.append(f'\t\t\t\t\t\t<dcsat:value xsi:type="dcscor:Parameter">{esc_xml(param_name)}</dcsat:value>')
                        lines.append('\t\t\t\t\t</dcsat:item>')
                        # Build drilldown appearance extra items.
                        # \u041f\u0440\u0438\u043e\u0440\u0438\u0442\u0435\u0442: per-cell override (cell={value, drilldown}) \u2192 drilldownMap (shortcut form B).
                        cell_drill_override = None
                        if isinstance(cell_raw, dict) and 'drilldown' in cell_raw:
                            cell_drill_override = str(cell_raw['drilldown'])
                        dd_target = None
                        if cell_drill_override:
                            dd_target = cell_drill_override
                        elif param_name in drilldown_map:
                            dd_target = f'\u0420\u0430\u0441\u0448\u0438\u0444\u0440\u043e\u0432\u043a\u0430_{drilldown_map[param_name]}'
                        if dd_target:
                            cell_extra_items.append('\t\t\t\t\t\t<dcscor:item>')
                            cell_extra_items.append(f'\t\t\t\t\t\t\t<dcscor:parameter>\u0420\u0430\u0441\u0448\u0438\u0444\u0440\u043e\u0432\u043a\u0430</dcscor:parameter>')
                            cell_extra_items.append(f'\t\t\t\t\t\t\t<dcscor:value xsi:type="dcscor:Parameter">{esc_xml(dd_target)}</dcscor:value>')
                            cell_extra_items.append('\t\t\t\t\t\t</dcscor:item>')
                    else:
                        lines.append('\t\t\t\t\t<dcsat:item xsi:type="dcsat:Field">')
                        emit_mltext(lines, '\t\t\t\t\t\t', 'dcsat:value', cell_str)
                        lines.append('\t\t\t\t\t</dcsat:item>')
                h = min_height if r == 0 else 0
                _emit_cell_appearance(lines, cell_style, w, False, False, h, cell_extra_items or None)
            lines.append('\t\t\t\t</dcsat:tableCell>')
        lines.append('\t\t\t</dcsat:item>')

    lines.append('\t\t</template>')
    if t.get('parameters'):
        for tp in t['parameters']:
            _emit_area_template_parameter(lines, tp, '\t\t')
    lines.append('\t</template>')


# \u042d\u043c\u0438\u0441\u0441\u0438\u044f \u043e\u0434\u043d\u043e\u0433\u043e \u043f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u0430 \u0448\u0430\u0431\u043b\u043e\u043d\u0430. \u0420\u0430\u0437\u043b\u0438\u0447\u0430\u0435\u0442 \u0442\u0440\u0438 \u0444\u043e\u0440\u043c\u044b:
#   A. {name, expression}                                  \u2192 ExpressionAreaTemplateParameter
#   B. {name, expression, drilldown: "X"}                  \u2192 Expression + Details(\u0420\u0430\u0441\u0448\u0438\u0444\u0440\u043e\u0432\u043a\u0430_X, \u0418\u043c\u044f\u0420\u0435\u0441\u0443\u0440\u0441\u0430, DrillDown)
#   C. {name, drilldown: {field, expression, action?}}     \u2192 DetailsAreaTemplateParameter \u0441 \u043f\u0440\u043e\u0438\u0437\u0432\u043e\u043b\u044c\u043d\u044b\u043c \u0438\u043c\u0435\u043d\u0435\u043c
def _emit_area_template_parameter(lines, tp, indent):
    dd = tp.get('drilldown')
    if isinstance(dd, dict):
        # \u0424\u043e\u0440\u043c\u0430 C
        dd_field = str(dd.get('field', ''))
        dd_expr = str(dd.get('expression', ''))
        dd_act = str(dd.get('action') or 'DrillDown')
        lines.append(f'{indent}<parameter xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template" xsi:type="dcsat:DetailsAreaTemplateParameter">')
        lines.append(f'{indent}\t<dcsat:name>{esc_xml(str(tp["name"]))}</dcsat:name>')
        lines.append(f'{indent}\t<dcsat:fieldExpression>')
        lines.append(f'{indent}\t\t<dcsat:field>{esc_xml(dd_field)}</dcsat:field>')
        lines.append(f'{indent}\t\t<dcsat:expression>{esc_xml(dd_expr)}</dcsat:expression>')
        lines.append(f'{indent}\t</dcsat:fieldExpression>')
        lines.append(f'{indent}\t<dcsat:mainAction>{esc_xml(dd_act)}</dcsat:mainAction>')
        lines.append(f'{indent}</parameter>')
        return
    # \u0424\u043e\u0440\u043c\u0430 A \u0438\u043b\u0438 B
    lines.append(f'{indent}<parameter xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template" xsi:type="dcsat:ExpressionAreaTemplateParameter">')
    lines.append(f'{indent}\t<dcsat:name>{esc_xml(str(tp["name"]))}</dcsat:name>')
    lines.append(f'{indent}\t<dcsat:expression>{esc_xml(str(tp.get("expression", "")))}</dcsat:expression>')
    lines.append(f'{indent}</parameter>')
    if dd and isinstance(dd, str):
        # \u0424\u043e\u0440\u043c\u0430 B: shortcut \u0420\u0430\u0441\u0448\u0438\u0444\u0440\u043e\u0432\u043a\u0430_<X> + \u0418\u043c\u044f\u0420\u0435\u0441\u0443\u0440\u0441\u0430 + DrillDown
        dd_val = dd
        lines.append(f'{indent}<parameter xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template" xsi:type="dcsat:DetailsAreaTemplateParameter">')
        lines.append(f'{indent}\t<dcsat:name>\u0420\u0430\u0441\u0448\u0438\u0444\u0440\u043e\u0432\u043a\u0430_{esc_xml(dd_val)}</dcsat:name>')
        lines.append(f'{indent}\t<dcsat:fieldExpression>')
        lines.append(f'{indent}\t\t<dcsat:field>\u0418\u043c\u044f\u0420\u0435\u0441\u0443\u0440\u0441\u0430</dcsat:field>')
        lines.append(f'{indent}\t\t<dcsat:expression>"{esc_xml(dd_val)}"</dcsat:expression>')
        lines.append(f'{indent}\t</dcsat:fieldExpression>')
        lines.append(f'{indent}\t<dcsat:mainAction>DrillDown</dcsat:mainAction>')
        lines.append(f'{indent}</parameter>')


# === Templates ===

def emit_templates(lines, defn):
    if not defn.get('templates'):
        return
    for t in defn['templates']:
        if t.get('rows'):
            _emit_area_template_dsl(lines, t)
        else:
            lines.append('\t<template>')
            lines.append(f'\t\t<name>{esc_xml(str(t["name"]))}</name>')
            if t.get('template'):
                lines.append(f'\t\t{t["template"]}')
            if t.get('parameters'):
                for tp in t['parameters']:
                    _emit_area_template_parameter(lines, tp, '\t\t')
            lines.append('\t</template>')


# === FieldTemplates ===
# Привязка <fieldTemplate><field/><template/></fieldTemplate> поля к именованному area-template.
# DSL: "fieldTemplates": [{ "field": "X", "template": "Макет1" }, ...]
def emit_field_templates(lines, defn):
    if not defn.get('fieldTemplates'):
        return
    for ft in defn['fieldTemplates']:
        lines.append('\t<fieldTemplate>')
        lines.append(f'\t\t<field>{esc_xml(str(ft["field"]))}</field>')
        lines.append(f'\t\t<template>{esc_xml(str(ft["template"]))}</template>')
        lines.append('\t</fieldTemplate>')


# === GroupTemplates ===

def emit_group_templates(lines, defn):
    if not defn.get('groupTemplates'):
        return
    for gt in defn['groupTemplates']:
        ttype = str(gt.get('templateType', '')) or 'Header'
        is_header = (ttype == 'GroupHeader')
        tag = 'groupHeaderTemplate' if is_header else 'groupTemplate'
        xml_ttype = 'Header' if is_header else ttype

        lines.append(f'\t<{tag}>')
        if gt.get('groupName'):
            lines.append(f'\t\t<groupName>{esc_xml(str(gt["groupName"]))}</groupName>')
        elif gt.get('groupField'):
            lines.append(f'\t\t<groupField>{esc_xml(str(gt["groupField"]))}</groupField>')
        lines.append(f'\t\t<templateType>{esc_xml(xml_ttype)}</templateType>')
        lines.append(f'\t\t<template>{esc_xml(str(gt["template"]))}</template>')
        lines.append(f'\t</{tag}>')


# === Settings Variants ===

def emit_selection_item(lines, item, indent):
    if isinstance(item, str):
        if item == 'Auto':
            lines.append(f'{indent}<dcsset:item xsi:type="dcsset:SelectedItemAuto"/>')
        else:
            lines.append(f'{indent}<dcsset:item xsi:type="dcsset:SelectedItemField">')
            lines.append(f'{indent}\t<dcsset:field>{esc_xml(item)}</dcsset:field>')
            lines.append(f'{indent}</dcsset:item>')
        return
    # Object form: { auto: true, use: false } — отключённый Auto в selection
    if item.get('auto') is True:
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:SelectedItemAuto">')
        if item.get('use') is False:
            lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')
        lines.append(f'{indent}</dcsset:item>')
        return
    if 'folder' in item:
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:SelectedItemFolder">')
        if item.get('field'):
            lines.append(f'{indent}\t<dcsset:field>{esc_xml(str(item["field"]))}</dcsset:field>')
        emit_mltext(lines, f'{indent}\t', 'dcsset:lwsTitle', item['folder'], no_xsi_type=True)
        for sub in (item.get('items') or []):
            emit_selection_item(lines, sub, f'{indent}\t')
        pl = str(item.get('placement') or 'Auto')
        lines.append(f'{indent}\t<dcsset:placement>{esc_xml(pl)}</dcsset:placement>')
        lines.append(f'{indent}</dcsset:item>')
        return
    # field with optional title / use=false / viewMode
    lines.append(f'{indent}<dcsset:item xsi:type="dcsset:SelectedItemField">')
    if item.get('use') is False:
        lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')
    lines.append(f'{indent}\t<dcsset:field>{esc_xml(str(item["field"]))}</dcsset:field>')
    if item.get('title'):
        emit_mltext(lines, f'{indent}\t', 'dcsset:lwsTitle', item['title'], no_xsi_type=True)
    if item.get('viewMode'):
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
    lines.append(f'{indent}</dcsset:item>')


def emit_selection(lines, items, indent, skip_auto=False, block_view_mode=None, block_user_setting_id=None):
    has_items = items and len(items) > 0
    has_block_meta = block_view_mode is not None or block_user_setting_id is not None
    if not has_items and not has_block_meta:
        return
    lines.append(f'{indent}<dcsset:selection>')
    for item in (items or []):
        if skip_auto and isinstance(item, str) and item == 'Auto':
            continue
        emit_selection_item(lines, item, f'{indent}\t')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    if block_user_setting_id is not None:
        uid = new_uuid() if str(block_user_setting_id) == 'auto' else str(block_user_setting_id)
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    lines.append(f'{indent}</dcsset:selection>')


def emit_filter_item(lines, item, indent):
    if item.get('group'):
        # FilterItemGroup
        group_type_map = {'And': 'AndGroup', 'Or': 'OrGroup', 'Not': 'NotGroup'}
        group_type = group_type_map.get(str(item['group']), f'{item["group"]}Group')
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:FilterItemGroup">')
        lines.append(f'{indent}\t<dcsset:groupType>{group_type}</dcsset:groupType>')
        if item.get('items'):
            for sub in item['items']:
                if isinstance(sub, str):
                    parsed = parse_filter_shorthand(sub)
                    sub = {'field': parsed['field'], 'op': parsed['op']}
                    if parsed['use'] is False:
                        sub['use'] = False
                    if parsed.get('value') is not None:
                        sub['value'] = parsed['value']
                    if parsed.get('valueType'):
                        sub['valueType'] = parsed['valueType']
                    if parsed.get('userSettingID'):
                        sub['userSettingID'] = parsed['userSettingID']
                    if parsed.get('viewMode'):
                        sub['viewMode'] = parsed['viewMode']
                emit_filter_item(lines, sub, f'{indent}\t')
        if item.get('presentation'):
            emit_mltext(lines, f'{indent}\t', 'dcsset:presentation', item['presentation'])
        if item.get('viewMode'):
            lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
        if item.get('userSettingID'):
            guid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
            lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(guid)}</dcsset:userSettingID>')
        if item.get('userSettingPresentation'):
            emit_mltext(lines, f'{indent}\t', 'dcsset:userSettingPresentation', item['userSettingPresentation'])
        lines.append(f'{indent}</dcsset:item>')
        return

    # FilterItemComparison
    lines.append(f'{indent}<dcsset:item xsi:type="dcsset:FilterItemComparison">')

    if item.get('use') is False:
        lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')

    lines.append(f'{indent}\t<dcsset:left xsi:type="dcscor:Field">{esc_xml(str(item["field"]))}</dcsset:left>')

    comp_type = COMPARISON_TYPES.get(str(item.get('op', '')), str(item.get('op', '')))
    lines.append(f'{indent}\t<dcsset:comparisonType>{esc_xml(comp_type)}</dcsset:comparisonType>')

    # Right value: один, несколько (InList) или ValueListType (пустой list-placeholder)
    val = item.get('value')
    val_is_array = isinstance(val, list)
    if val_is_array:
        if len(val) == 0:
            # Пустой массив → пустой ValueListType placeholder
            lines.append(f'{indent}\t<dcsset:right xsi:type="v8:ValueListType">')
            lines.append(f'{indent}\t\t<v8:valueType/>')
            lines.append(f'{indent}\t\t<v8:lastId xsi:type="xs:decimal">-1</v8:lastId>')
            lines.append(f'{indent}\t</dcsset:right>')
        else:
            for v in val:
                vt = str(item.get('valueType', '')) if item.get('valueType') else ''
                if not vt:
                    if isinstance(v, bool):
                        vt = 'xs:boolean'
                    elif isinstance(v, (int, float)):
                        vt = 'xs:decimal'
                    elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(v)):
                        vt = 'xs:dateTime'
                    elif re.match(r'^-?\d+(\.\d+)?$', str(v)):
                        vt = 'xs:decimal'
                    elif re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', str(v)):
                        vt = 'dcscor:DesignTimeValue'
                    else:
                        vt = 'xs:string'
                v_str = str(v).lower() if isinstance(v, bool) else esc_xml(str(v))
                lines.append(f'{indent}\t<dcsset:right xsi:type="{vt}">{v_str}</dcsset:right>')
    elif val is not None:
        vt = str(item.get('valueType', '')) if item.get('valueType') else ''
        if not vt:
            v = val
            if isinstance(v, bool):
                vt = 'xs:boolean'
            elif isinstance(v, (int, float)):
                vt = 'xs:decimal'
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(v)):
                vt = 'xs:dateTime'
            elif re.match(r'^-?\d+(\.\d+)?$', str(v)):
                vt = 'xs:decimal'
            else:
                vt = 'xs:string'
        if isinstance(val, bool):
            v_str = str(val).lower()
        else:
            v_str = esc_xml(str(val))
        lines.append(f'{indent}\t<dcsset:right xsi:type="{vt}">{v_str}</dcsset:right>')

    if item.get('presentation'):
        emit_mltext(lines, f'{indent}\t', 'dcsset:presentation', item["presentation"])

    if item.get('viewMode'):
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')

    if item.get('userSettingID'):
        uid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')

    if item.get('userSettingPresentation'):
        emit_mltext(lines, f'{indent}\t', 'dcsset:userSettingPresentation', item["userSettingPresentation"])

    lines.append(f'{indent}</dcsset:item>')


def emit_filter(lines, items, indent, block_view_mode=None, block_user_setting_id=None):
    has_items = items and len(items) > 0
    has_block_meta = block_view_mode is not None or block_user_setting_id is not None
    if not has_items and not has_block_meta:
        return

    lines.append(f'{indent}<dcsset:filter>')
    for item in (items or []):
        if isinstance(item, str):
            parsed = parse_filter_shorthand(item)
            filter_obj = {
                'field': parsed['field'],
                'op': parsed['op'],
            }
            if parsed['use'] is False:
                filter_obj['use'] = False
            if parsed.get('value') is not None:
                filter_obj['value'] = parsed['value']
            if parsed.get('valueType'):
                filter_obj['valueType'] = parsed['valueType']
            if parsed.get('userSettingID'):
                filter_obj['userSettingID'] = parsed['userSettingID']
            if parsed.get('viewMode'):
                filter_obj['viewMode'] = parsed['viewMode']
            emit_filter_item(lines, filter_obj, f'{indent}\t')
        else:
            emit_filter_item(lines, item, f'{indent}\t')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    if block_user_setting_id is not None:
        uid = new_uuid() if str(block_user_setting_id) == 'auto' else str(block_user_setting_id)
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    lines.append(f'{indent}</dcsset:filter>')


def emit_order(lines, items, indent, skip_auto=False, block_view_mode=None, block_user_setting_id=None):
    has_items = items and len(items) > 0
    has_block_meta = block_view_mode is not None or block_user_setting_id is not None
    if not has_items and not has_block_meta:
        return

    lines.append(f'{indent}<dcsset:order>')
    for item in (items or []):
        if isinstance(item, str):
            if item == 'Auto':
                if not skip_auto:
                    lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemAuto"/>')
            else:
                parts = item.split()
                field = parts[0]
                direction = 'Asc'
                if len(parts) > 1 and re.match(r'(?i)^desc$', parts[1]):
                    direction = 'Desc'
                elif len(parts) > 1 and re.match(r'(?i)^asc$', parts[1]):
                    direction = 'Asc'
                lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemField">')
                lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(field)}</dcsset:field>')
                lines.append(f'{indent}\t\t<dcsset:orderType>{direction}</dcsset:orderType>')
                lines.append(f'{indent}\t</dcsset:item>')
        else:
            # Object form: { field, direction, viewMode }
            if str(item.get('field', '')) == 'Auto' or item.get('type') == 'auto':
                if not skip_auto:
                    lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemAuto"/>')
                continue
            d = str(item.get('direction', 'Asc'))
            if re.match(r'(?i)^desc$', d):
                d = 'Desc'
            elif re.match(r'(?i)^asc$', d):
                d = 'Asc'
            lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemField">')
            if item.get('use') is False:
                lines.append(f'{indent}\t\t<dcsset:use>false</dcsset:use>')
            lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(str(item["field"]))}</dcsset:field>')
            lines.append(f'{indent}\t\t<dcsset:orderType>{d}</dcsset:orderType>')
            if item.get('viewMode'):
                lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
            lines.append(f'{indent}\t</dcsset:item>')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    if block_user_setting_id is not None:
        uid = new_uuid() if str(block_user_setting_id) == 'auto' else str(block_user_setting_id)
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    lines.append(f'{indent}</dcsset:order>')


def emit_appearance_value(lines, key, val, indent):
    lines.append(f'{indent}<dcscor:item xsi:type="dcsset:SettingsParameterValue">')

    # Top-level Line \u0445\u0440\u0430\u043d\u0438\u0442\u0441\u044f \u043f\u043b\u043e\u0441\u043a\u043e ({@type: "Line", width, gap, style, use?, items?}).
    # \u041e\u0431\u044b\u0447\u043d\u044b\u0439 wrapper: {value, use?, items?}.
    is_top_level_line = isinstance(val, dict) and val.get('@type') == 'Line'
    use_wrapper = False
    inner_val = val
    nested_items = None
    if is_top_level_line:
        if val.get('use') is False:
            use_wrapper = True
        nested_items = val.get('items')
    elif isinstance(val, dict) and 'value' in val:
        inner_val = val['value']
        if val.get('use') is False:
            use_wrapper = True
        nested_items = val.get('items')

    if use_wrapper:
        lines.append(f'{indent}\t<dcscor:use>false</dcscor:use>')
    lines.append(f'{indent}\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')

    # Line dict ({@type: "Line", width, gap, style}) \u2192 <dcscor:value xsi:type="v8ui:Line" ...>
    if isinstance(inner_val, dict) and inner_val.get('@type') == 'Line':
        lw = inner_val.get('width', 0)
        lg = 'true' if inner_val.get('gap') else 'false'
        ls = str(inner_val.get('style', 'None'))
        lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Line" width="{lw}" gap="{lg}">')
        lines.append(f'{indent}\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">{esc_xml(ls)}</v8ui:style>')
        lines.append(f'{indent}\t</dcscor:value>')
    # Font dict ({@type: "Font", ref, faceName, height, bold, ...}) \u2192 <dcscor:value xsi:type="v8ui:Font" .../>
    elif isinstance(inner_val, dict) and inner_val.get('@type') == 'Font':
        attr_parts = []
        for attr_name in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
            if attr_name in inner_val:
                attr_parts.append(f'{attr_name}="{esc_xml(str(inner_val[attr_name]))}"')
        lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Font" {" ".join(attr_parts)}/>')
    elif isinstance(inner_val, dict):
        emit_mltext(lines, f'{indent}\t', 'dcscor:value', inner_val)
    else:
        actual_val = str(inner_val) if inner_val is not None else ''
        # \u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440-\u0441\u043f\u0435\u0446\u0438\u0444\u0438\u0447\u043d\u044b\u0439 \u0442\u0438\u043f \u0434\u043b\u044f \u0438\u0437\u0432\u0435\u0441\u0442\u043d\u044b\u0445 appearance keys
        key_type_map = {
            '\u0420\u0430\u0437\u043c\u0435\u0449\u0435\u043d\u0438\u0435':              'dcscor:DataCompositionTextPlacementType',
            '\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u041f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435': 'v8ui:HorizontalAlign',
            '\u0412\u0435\u0440\u0442\u0438\u043a\u0430\u043b\u044c\u043d\u043e\u0435\u041f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435':   'v8ui:VerticalAlign',
            '\u041e\u0440\u0438\u0435\u043d\u0442\u0430\u0446\u0438\u044f\u0422\u0435\u043a\u0441\u0442\u0430':        'xs:decimal',
            '\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u0418\u0442\u043e\u0433\u043e\u0432':      'dcscor:DataCompositionTotalPlacement',
            '\u0422\u0438\u043f\u041c\u0430\u043a\u0435\u0442\u0430':               'dcsset:DataCompositionGroupTemplateType',
        }
        key_type = key_type_map.get(key)
        if key_type:
            lines.append(f'{indent}\t<dcscor:value xsi:type="{key_type}">{esc_xml(actual_val)}</dcscor:value>')
        elif re.match(r'^(style|web|win):', actual_val):
            # Внутри <dcsset:settings> префиксы style:/web:/win:/sys: уже объявлены на корне,
            # локальный xmlns не нужен — эмитим short form.
            lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Color">{esc_xml(actual_val)}</dcscor:value>')
        elif actual_val == 'true' or actual_val == 'false':
            lines.append(f'{indent}\t<dcscor:value xsi:type="xs:boolean">{actual_val}</dcscor:value>')
        elif key in ('\u0422\u0435\u043a\u0441\u0442', '\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a', '\u0424\u043e\u0440\u043c\u0430\u0442'):
            emit_mltext(lines, f'{indent}\t', 'dcscor:value', actual_val)
        elif re.match(r'^-?\d+(\.\d+)?$', actual_val):
            lines.append(f'{indent}\t<dcscor:value xsi:type="xs:decimal">{actual_val}</dcscor:value>')
        elif key in ('\u0426\u0432\u0435\u0442\u0422\u0435\u043a\u0441\u0442\u0430', '\u0426\u0432\u0435\u0442\u0424\u043e\u043d\u0430', '\u0426\u0432\u0435\u0442\u0413\u0440\u0430\u043d\u0438\u0446\u044b'):
            lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Color">{esc_xml(actual_val)}</dcscor:value>')
        else:
            lines.append(f'{indent}\t<dcscor:value xsi:type="xs:string">{esc_xml(actual_val)}</dcscor:value>')
    # Nested SettingsParameterValue items (СтильГраницы.Сверху/.Снизу/.Слева/.Справа).
    if nested_items and isinstance(nested_items, dict):
        for nk, nv in nested_items.items():
            emit_appearance_value(lines, nk, nv, f'{indent}\t')
    lines.append(f'{indent}</dcscor:item>')


def emit_conditional_appearance(lines, items, indent, block_view_mode=None, block_user_setting_id=None):
    has_items = items and len(items) > 0
    has_block_meta = block_view_mode is not None or block_user_setting_id is not None
    if not has_items and not has_block_meta:
        return

    lines.append(f'{indent}<dcsset:conditionalAppearance>')
    for ca in (items or []):
        lines.append(f'{indent}\t<dcsset:item>')

        if ca.get('use') is False:
            lines.append(f'{indent}\t\t<dcsset:use>false</dcsset:use>')

        # Selection
        if ca.get('selection') and len(ca['selection']) > 0:
            lines.append(f'{indent}\t\t<dcsset:selection>')
            for sel in ca['selection']:
                lines.append(f'{indent}\t\t\t<dcsset:item>')
                lines.append(f'{indent}\t\t\t\t<dcsset:field>{esc_xml(str(sel))}</dcsset:field>')
                lines.append(f'{indent}\t\t\t</dcsset:item>')
            lines.append(f'{indent}\t\t</dcsset:selection>')
        else:
            lines.append(f'{indent}\t\t<dcsset:selection/>')

        # Filter
        if ca.get('filter') and len(ca['filter']) > 0:
            emit_filter(lines, ca['filter'], f'{indent}\t\t')
        else:
            # Платформа эмитит пустой <dcsset:filter/> на каждом condApp item
            lines.append(f'{indent}\t\t<dcsset:filter/>')

        # Appearance
        if ca.get('appearance'):
            lines.append(f'{indent}\t\t<dcsset:appearance>')
            for k, v in ca['appearance'].items():
                emit_appearance_value(lines, k, v, f'{indent}\t\t\t')
            lines.append(f'{indent}\t\t</dcsset:appearance>')

        # Presentation
        if ca.get('presentation'):
            # Multilang dict {ru, en, ...} → LocalStringType; иначе — xs:string
            if isinstance(ca['presentation'], dict):
                emit_mltext(lines, f'{indent}\t\t', 'dcsset:presentation', ca['presentation'])
            else:
                lines.append(f'{indent}\t\t<dcsset:presentation xsi:type="xs:string">{esc_xml(str(ca["presentation"]))}</dcsset:presentation>')

        if ca.get('viewMode'):
            lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(ca["viewMode"]))}</dcsset:viewMode>')

        # UserSettingID
        if ca.get('userSettingID'):
            uid = new_uuid() if str(ca['userSettingID']) == 'auto' else str(ca['userSettingID'])
            lines.append(f'{indent}\t\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')

        if ca.get('userSettingPresentation'):
            emit_mltext(lines, f'{indent}\t\t', 'dcsset:userSettingPresentation', ca['userSettingPresentation'])

        # useInXxx — список областей где правило НЕ применяется (DontUse)
        if ca.get('useInDontUse'):
            use_in_order = ['group', 'hierarchicalGroup', 'overall',
                            'fieldsHeader', 'header', 'parameters', 'filter',
                            'resourceFieldsHeader', 'overallHeader', 'overallResourceFieldsHeader']
            s = set(ca['useInDontUse'])
            for n in use_in_order:
                if n in s:
                    tag = 'useIn' + n[0].upper() + n[1:]
                    lines.append(f'{indent}\t\t<dcsset:{tag}>DontUse</dcsset:{tag}>')

        lines.append(f'{indent}\t</dcsset:item>')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    if block_user_setting_id is not None:
        uid = new_uuid() if str(block_user_setting_id) == 'auto' else str(block_user_setting_id)
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    lines.append(f'{indent}</dcsset:conditionalAppearance>')


def emit_output_parameters(lines, params, indent):
    if not params:
        return

    lines.append(f'{indent}<dcsset:outputParameters>')
    for key, val in params.items():
        # wrapper {value, valueType?, use?, items?, viewMode?, userSettingID?, userSettingPresentation?}
        use_false = False
        wrap_vm = None
        wrap_usid = None
        wrap_usp = None
        wrap_vt = None
        wrap_items = None
        if isinstance(val, dict) and 'value' in val:
            wrap_vt = val.get('valueType')
            if val.get('use') is False: use_false = True
            wrap_items = val.get('items')
            wrap_vm = val.get('viewMode')
            wrap_usid = val.get('userSettingID')
            wrap_usp = val.get('userSettingPresentation')
            val = val['value']
        is_font_dict = isinstance(val, dict) and val.get('@type') == 'Font'
        if wrap_vt:
            ptype = wrap_vt
        else:
            ptype = OUTPUT_PARAM_TYPES.get(key, 'xs:string')
        # Auto-promote to mltext if value is a multilang dict (but not Font)
        if not is_font_dict and isinstance(val, dict):
            ptype = 'mltext'

        lines.append(f'{indent}\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
        if use_false:
            lines.append(f'{indent}\t\t<dcscor:use>false</dcscor:use>')
        lines.append(f'{indent}\t\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')
        if is_font_dict:
            attr_parts = []
            for attr_name in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
                if attr_name in val:
                    attr_parts.append(f'{attr_name}="{esc_xml(str(val[attr_name]))}"')
            lines.append(f'{indent}\t\t<dcscor:value xsi:type="v8ui:Font" {" ".join(attr_parts)}/>')
        elif ptype == 'mltext':
            emit_mltext(lines, f'{indent}\t\t', 'dcscor:value', val)
        else:
            lines.append(f'{indent}\t\t<dcscor:value xsi:type="{ptype}">{esc_xml(str(val))}</dcscor:value>')
        # Nested sub-параметры (ТипДиаграммы.ВидПодписей и т.п.).
        # valueType: строка → xsi:type=string, объект {uri, name} → локальный xmlns:dN.
        if wrap_items and isinstance(wrap_items, dict):
            for sub_name, sub_wrap in wrap_items.items():
                sub_val = sub_wrap
                sub_vt = 'xs:string'
                sub_use_false = False
                sub_uri = None
                sub_local_name = None
                if isinstance(sub_wrap, dict):
                    if 'value' in sub_wrap:
                        sub_val = sub_wrap['value']
                    if 'valueType' in sub_wrap:
                        vt = sub_wrap['valueType']
                        if isinstance(vt, dict) and 'uri' in vt:
                            sub_uri = str(vt['uri'])
                            sub_local_name = str(vt['name'])
                        else:
                            sub_vt = str(vt)
                    if sub_wrap.get('use') is False:
                        sub_use_false = True
                lines.append(f'{indent}\t\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
                if sub_use_false:
                    lines.append(f'{indent}\t\t\t<dcscor:use>false</dcscor:use>')
                lines.append(f'{indent}\t\t\t<dcscor:parameter>{esc_xml(sub_name)}</dcscor:parameter>')
                if sub_uri:
                    lines.append(f'{indent}\t\t\t<dcscor:value xmlns:dN="{sub_uri}" xsi:type="dN:{sub_local_name}">{esc_xml(str(sub_val))}</dcscor:value>')
                else:
                    lines.append(f'{indent}\t\t\t<dcscor:value xsi:type="{sub_vt}">{esc_xml(str(sub_val))}</dcscor:value>')
                lines.append(f'{indent}\t\t</dcscor:item>')
        if wrap_vm:
            lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(wrap_vm))}</dcsset:viewMode>')
        if wrap_usid:
            uid = new_uuid() if str(wrap_usid) == 'auto' else str(wrap_usid)
            lines.append(f'{indent}\t\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
        if wrap_usp:
            emit_mltext(lines, f'{indent}\t\t', 'dcsset:userSettingPresentation', wrap_usp)
        lines.append(f'{indent}\t</dcscor:item>')
    lines.append(f'{indent}</dcsset:outputParameters>')


def emit_data_parameters(lines, items, indent):
    if not items or len(items) == 0:
        return

    lines.append(f'{indent}<dcsset:dataParameters>')
    for dp in items:
        # Support string shorthand
        if isinstance(dp, str):
            parsed = parse_data_param_shorthand(dp)
            dp = {
                'parameter': parsed['parameter'],
            }
            if parsed.get('value') is not None:
                dp['value'] = parsed['value']
            if parsed['use'] is False:
                dp['use'] = False
            if parsed.get('userSettingID'):
                dp['userSettingID'] = parsed['userSettingID']
            if parsed.get('viewMode'):
                dp['viewMode'] = parsed['viewMode']

        lines.append(f'{indent}\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')

        if dp.get('use') is False:
            lines.append(f'{indent}\t\t<dcscor:use>false</dcscor:use>')

        lines.append(f'{indent}\t\t<dcscor:parameter>{esc_xml(str(dp["parameter"]))}</dcscor:parameter>')

        # Value
        if dp.get('nilValue') is True:
            lines.append(f'{indent}\t\t<dcscor:value xsi:nil="true"/>')
        elif is_empty_value(dp.get('value')):
            emit_empty_value(lines, str(dp.get('valueType') or ''), f'{indent}\t\t', 'dcscor:', False)
        elif dp.get('value') is not None:
            val = dp['value']
            vtype = str(dp.get('valueType') or '')
            if isinstance(val, dict) and val.get('variant'):
                # Standard{Period,BeginningDate} — различаем по форме value:
                #  {variant, date}                → SBD
                #  {variant, startDate, endDate}  → SP с датами
                #  {variant} only                 → инференс по имени (BeginningOf* → SBD, иначе SP)
                variant_str = str(val['variant'])
                has_date = 'date' in val
                has_sd = 'startDate' in val
                is_sbd = has_date or (not has_sd and variant_str.startswith('BeginningOf'))
                if is_sbd:
                    lines.append(f'{indent}\t\t<dcscor:value xsi:type="v8:StandardBeginningDate">')
                    lines.append(f'{indent}\t\t\t<v8:variant xsi:type="v8:StandardBeginningDateVariant">{esc_xml(variant_str)}</v8:variant>')
                    if variant_str == 'Custom':
                        d = str(val.get('date') or '0001-01-01T00:00:00')
                        lines.append(f'{indent}\t\t\t<v8:date>{esc_xml(d)}</v8:date>')
                    lines.append(f'{indent}\t\t</dcscor:value>')
                else:
                    # StandardPeriod — platform-pattern: startDate/endDate ТОЛЬКО для variant=Custom.
                    lines.append(f'{indent}\t\t<dcscor:value xsi:type="v8:StandardPeriod">')
                    lines.append(f'{indent}\t\t\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(variant_str)}</v8:variant>')
                    if variant_str == 'Custom':
                        sd = str(val.get('startDate') or '0001-01-01T00:00:00')
                        ed = str(val.get('endDate') or '0001-01-01T00:00:00')
                        lines.append(f'{indent}\t\t\t<v8:startDate>{esc_xml(sd)}</v8:startDate>')
                        lines.append(f'{indent}\t\t\t<v8:endDate>{esc_xml(ed)}</v8:endDate>')
                    lines.append(f'{indent}\t\t</dcscor:value>')
            elif re.match(r'^[a-zA-Z]+:', vtype):
                # Полный xsi:type из decompile (например "xs:boolean", "dcscor:DesignTimeValue").
                v_str = str(val).lower() if isinstance(val, bool) else str(val)
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="{vtype}">{esc_xml(v_str)}</dcscor:value>')
            elif vtype == 'boolean' or isinstance(val, bool):
                bv = str(val).lower()
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:boolean">{esc_xml(bv)}</dcscor:value>')
            elif re.match(r'^date', vtype) or re.match(r'^\d{4}-\d{2}-\d{2}T', str(val)):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:dateTime">{esc_xml(str(val))}</dcscor:value>')
            elif re.match(r'^decimal', vtype):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:decimal">{esc_xml(str(val))}</dcscor:value>')
            elif re.match(r'^string', vtype):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')
            elif re.match(r'^(\u041f\u043b\u0430\u043d\u0421\u0447\u0435\u0442\u043e\u0432|\u0421\u043f\u0440\u0430\u0432\u043e\u0447\u043d\u0438\u043a|\u041f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u0438\u0435|\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442|\u041f\u043b\u0430\u043d\u0412\u0438\u0434\u043e\u0432\u0425\u0430\u0440\u0430\u043a\u0442\u0435\u0440\u0438\u0441\u0442\u0438\u043a|\u041f\u043b\u0430\u043d\u0412\u0438\u0434\u043e\u0432\u0420\u0430\u0441\u0447\u0435\u0442\u0430|\u0411\u0438\u0437\u043d\u0435\u0441\u041f\u0440\u043e\u0446\u0435\u0441\u0441|\u0417\u0430\u0434\u0430\u0447\u0430|\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0421\u0432\u0435\u0434\u0435\u043d\u0438\u0439|\u041f\u043b\u0430\u043d\u041e\u0431\u043c\u0435\u043d\u0430)\.', str(val)) or re.match(r'^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', str(val)):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:DesignTimeValue">{esc_xml(str(val))}</dcscor:value>')
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')

        if dp.get('viewMode'):
            lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(dp["viewMode"]))}</dcsset:viewMode>')

        if dp.get('userSettingID'):
            uid = new_uuid() if str(dp['userSettingID']) == 'auto' else str(dp['userSettingID'])
            lines.append(f'{indent}\t\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')

        if dp.get('userSettingPresentation'):
            emit_mltext(lines, f'{indent}\t\t', 'dcsset:userSettingPresentation', dp["userSettingPresentation"])

        lines.append(f'{indent}\t</dcscor:item>')
    lines.append(f'{indent}</dcsset:dataParameters>')


# === Structure items (recursive) ===

def emit_group_items(lines, group_by, indent):
    if not group_by or len(group_by) == 0:
        return

    lines.append(f'{indent}<dcsset:groupItems>')
    for field in group_by:
        if isinstance(field, str):
            if field == 'Auto':
                lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:GroupItemAuto"/>')
                continue
            lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:GroupItemField">')
            lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(field)}</dcsset:field>')
            lines.append(f'{indent}\t\t<dcsset:groupType>Items</dcsset:groupType>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionBegin xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionBegin>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionEnd xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionEnd>')
            lines.append(f'{indent}\t</dcsset:item>')
        else:
            lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:GroupItemField">')
            lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(str(field["field"]))}</dcsset:field>')
            gt = str(field.get('groupType', 'Items'))
            lines.append(f'{indent}\t\t<dcsset:groupType>{esc_xml(gt)}</dcsset:groupType>')
            pat = str(field.get('periodAdditionType', 'None'))
            lines.append(f'{indent}\t\t<dcsset:periodAdditionType>{esc_xml(pat)}</dcsset:periodAdditionType>')
            # Auto-detect: ISO date → xs:dateTime, иначе → dcscor:Field (path).
            pab = str(field.get('periodAdditionBegin', '0001-01-01T00:00:00'))
            pae = str(field.get('periodAdditionEnd', '0001-01-01T00:00:00'))
            pab_t = 'xs:dateTime' if re.match(r'^\d{4}-\d{2}-\d{2}T', pab) else 'dcscor:Field'
            pae_t = 'xs:dateTime' if re.match(r'^\d{4}-\d{2}-\d{2}T', pae) else 'dcscor:Field'
            lines.append(f'{indent}\t\t<dcsset:periodAdditionBegin xsi:type="{pab_t}">{esc_xml(pab)}</dcsset:periodAdditionBegin>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionEnd xsi:type="{pae_t}">{esc_xml(pae)}</dcsset:periodAdditionEnd>')
            lines.append(f'{indent}\t</dcsset:item>')
    lines.append(f'{indent}</dcsset:groupItems>')


def parse_structure_shorthand(s):
    segments = re.split(r'\s*>\s*', s)
    innermost = None
    for i in range(len(segments) - 1, -1, -1):
        seg = segments[i].strip()
        group = {'type': 'group'}

        if re.match(r'(?i)^(details|\u0434\u0435\u0442\u0430\u043b\u0438)$', seg):
            group['groupBy'] = []
        else:
            # Named group: "ИмяГруппы[Поле]"
            m_named = re.match(r'^(.+)\[(.+)\]$', seg)
            if m_named:
                group['name'] = m_named.group(1).strip()
                group['groupBy'] = [m_named.group(2).strip()]
            else:
                group['groupBy'] = [seg]

        # Платформа в каждую группировку кладёт авто-поле выбора и авто-порядок;
        # shorthand должен соответствовать ручному добавлению группировки в конфигураторе.
        group['selection'] = ['Auto']
        group['order'] = ['Auto']

        if innermost is not None:
            group['children'] = [innermost]
        innermost = group

    if innermost:
        return [innermost]
    return []


def emit_user_fields(lines, items, indent):
    if not items or len(items) == 0:
        return
    lines.append(f'{indent}<dcsset:userFields>')
    for uf in items:
        u_type = 'UserFieldCase' if uf.get('cases') is not None else 'UserFieldExpression'
        lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:{u_type}">')
        if uf.get('dataPath'):
            lines.append(f'{indent}\t\t<dcsset:dataPath>{esc_xml(str(uf["dataPath"]))}</dcsset:dataPath>')
        if uf.get('title'):
            emit_mltext(lines, f'{indent}\t\t', 'dcsset:lwsTitle', uf['title'], no_xsi_type=True)
        if u_type == 'UserFieldExpression':
            d = uf.get('detail')
            if d is not None:
                if 'expression' in d:
                    v = str(d['expression'])
                    lines.append(f'{indent}\t\t<dcsset:detailExpression>{esc_xml(v)}</dcsset:detailExpression>' if v else f'{indent}\t\t<dcsset:detailExpression/>')
                if 'presentation' in d:
                    v = str(d['presentation'])
                    lines.append(f'{indent}\t\t<dcsset:detailExpressionPresentation>{esc_xml(v)}</dcsset:detailExpressionPresentation>' if v else f'{indent}\t\t<dcsset:detailExpressionPresentation/>')
            t = uf.get('total')
            if t is not None:
                if 'expression' in t:
                    v = str(t['expression'])
                    lines.append(f'{indent}\t\t<dcsset:totalExpression>{esc_xml(v)}</dcsset:totalExpression>' if v else f'{indent}\t\t<dcsset:totalExpression/>')
                if 'presentation' in t:
                    v = str(t['presentation'])
                    lines.append(f'{indent}\t\t<dcsset:totalExpressionPresentation>{esc_xml(v)}</dcsset:totalExpressionPresentation>' if v else f'{indent}\t\t<dcsset:totalExpressionPresentation/>')
        else:
            cases = uf.get('cases') or []
            if len(cases) == 0:
                lines.append(f'{indent}\t\t<dcsset:cases/>')
            else:
                lines.append(f'{indent}\t\t<dcsset:cases>')
                for c in cases:
                    lines.append(f'{indent}\t\t\t<dcsset:item>')
                    if c.get('filter'):
                        emit_filter(lines, c['filter'], f'{indent}\t\t\t\t')
                    if c.get('value') is not None:
                        cv = c['value']
                        if isinstance(cv, bool):
                            lines.append(f'{indent}\t\t\t\t<dcsset:value xsi:type="xs:boolean">{str(cv).lower()}</dcsset:value>')
                        elif isinstance(cv, (int, float)):
                            lines.append(f'{indent}\t\t\t\t<dcsset:value xsi:type="xs:decimal">{cv}</dcsset:value>')
                        else:
                            lines.append(f'{indent}\t\t\t\t<dcsset:value xsi:type="xs:string">{esc_xml(str(cv))}</dcsset:value>')
                    if c.get('presentation'):
                        emit_mltext(lines, f'{indent}\t\t\t\t', 'dcsset:lwsPresentationValue', c['presentation'], no_xsi_type=True)
                    lines.append(f'{indent}\t\t\t</dcsset:item>')
                lines.append(f'{indent}\t\t</dcsset:cases>')
        lines.append(f'{indent}\t</dcsset:item>')
    lines.append(f'{indent}</dcsset:userFields>')


def emit_table_axis_block(lines, block, indent, emit_name=True):
    """Shared emitter for table column/row and chart point/series.

    Emits name?, groupItems, filter, order, selection, outputParameters,
    viewMode?, userSettingID?, userSettingPresentation? — each conditional on
    presence in JSON.
    """
    if emit_name and block.get('name'):
        lines.append(f'{indent}<dcsset:name>{esc_xml(str(block["name"]))}</dcsset:name>')
    gb = block.get('groupBy') or block.get('groupFields')
    emit_group_items(lines, gb, indent)
    if block.get('filter'):
        emit_filter(lines, block['filter'], indent)
    if block.get('order'):
        emit_order(lines, block['order'], indent)
    if block.get('selection'):
        emit_selection(lines, block['selection'], indent)
    if block.get('conditionalAppearance'):
        emit_conditional_appearance(lines, block['conditionalAppearance'], indent)
    if block.get('outputParameters'):
        emit_output_parameters(lines, block['outputParameters'], indent)
    # nested children (StructureItemGroup внутри table row/column или chart axis).
    # Platform-pattern: items внутри row/column/points/series — ВСЕГДА short form (без xsi:type).
    if block.get('children'):
        for child in block['children']:
            emit_structure_item(lines, child, indent, short_group=True)
    if block.get('viewMode'):
        lines.append(f'{indent}<dcsset:viewMode>{esc_xml(str(block["viewMode"]))}</dcsset:viewMode>')
    if block.get('userSettingID'):
        uid = new_uuid() if str(block['userSettingID']) == 'auto' else str(block['userSettingID'])
        lines.append(f'{indent}<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    if block.get('userSettingPresentation'):
        emit_mltext(lines, indent, 'dcsset:userSettingPresentation', block['userSettingPresentation'])
    if block.get('itemsViewMode'):
        lines.append(f'{indent}<dcsset:itemsViewMode>{esc_xml(str(block["itemsViewMode"]))}</dcsset:itemsViewMode>')


def emit_structure_item(lines, item, indent, short_group=False):
    item_type = str(item.get('type', 'group'))

    if item_type == 'group':
        # Platform пишет короткую форму (без xsi:type) для groups внутри table row/column,
        # explicit StructureItemGroup в остальных случаях.
        if short_group:
            lines.append(f'{indent}<dcsset:item>')
        else:
            lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemGroup">')

        if item.get('use') is False:
            lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')

        if item.get('name'):
            lines.append(f'{indent}\t<dcsset:name>{esc_xml(str(item["name"]))}</dcsset:name>')

        emit_group_items(lines, item.get('groupBy') or item.get('groupFields'), f'{indent}\t')

        # Emit order/selection only if specified — platform doesn't always emit them on group
        if item.get('order'):
            emit_order(lines, item['order'], f'{indent}\t', block_view_mode=item.get('orderViewMode'), block_user_setting_id=item.get('orderUserSettingID'))
        if item.get('selection'):
            emit_selection(lines, item['selection'], f'{indent}\t')

        emit_filter(lines, item.get('filter'), f'{indent}\t')

        if item.get('conditionalAppearance'):
            emit_conditional_appearance(lines, item['conditionalAppearance'], f'{indent}\t')

        if item.get('outputParameters'):
            emit_output_parameters(lines, item['outputParameters'], f'{indent}\t')

        # Nested children — наследуем short_group от родителя.
        if item.get('children'):
            for child in item['children']:
                emit_structure_item(lines, child, f'{indent}\t', short_group=short_group)

        # viewMode/itemsViewMode/userSettingID/userSettingPresentation — context-dependent
        if item.get('viewMode'):
            lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
        if item.get('userSettingID'):
            gid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
            lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(gid)}</dcsset:userSettingID>')
        if item.get('userSettingPresentation'):
            emit_mltext(lines, f'{indent}\t', 'dcsset:userSettingPresentation', item['userSettingPresentation'])
        if item.get('itemsViewMode'):
            lines.append(f'{indent}\t<dcsset:itemsViewMode>{esc_xml(str(item["itemsViewMode"]))}</dcsset:itemsViewMode>')

        lines.append(f'{indent}</dcsset:item>')

    elif item_type == 'table':
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemTable">')

        # use=false — отключённая таблица
        if item.get('use') is False:
            lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')

        if item.get('name'):
            lines.append(f'{indent}\t<dcsset:name>{esc_xml(str(item["name"]))}</dcsset:name>')

        # Columns
        if item.get('columns'):
            for col in item['columns']:
                lines.append(f'{indent}\t<dcsset:column>')
                emit_table_axis_block(lines, col, f'{indent}\t\t')
                lines.append(f'{indent}\t</dcsset:column>')

        # Rows
        if item.get('rows'):
            for row in item['rows']:
                lines.append(f'{indent}\t<dcsset:row>')
                emit_table_axis_block(lines, row, f'{indent}\t\t')
                lines.append(f'{indent}\t</dcsset:row>')

        # Top-level: selection / conditionalAppearance / outputParameters на самой таблице
        if item.get('selection'):
            emit_selection(lines, item['selection'], f'{indent}\t')
        if item.get('conditionalAppearance'):
            emit_conditional_appearance(lines, item['conditionalAppearance'], f'{indent}\t')
        if item.get('outputParameters'):
            emit_output_parameters(lines, item['outputParameters'], f'{indent}\t')
        # columnsViewMode / rowsViewMode — axis-level режим доступности
        if item.get('columnsViewMode'):
            lines.append(f'{indent}\t<dcsset:columnsViewMode>{esc_xml(str(item["columnsViewMode"]))}</dcsset:columnsViewMode>')
        if item.get('rowsViewMode'):
            lines.append(f'{indent}\t<dcsset:rowsViewMode>{esc_xml(str(item["rowsViewMode"]))}</dcsset:rowsViewMode>')
        # viewMode / userSettingID / userSettingPresentation / itemsViewMode на самой таблице
        if item.get('viewMode'):
            lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
        if item.get('userSettingID'):
            gid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
            lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(gid)}</dcsset:userSettingID>')
        if item.get('userSettingPresentation'):
            emit_mltext(lines, f'{indent}\t', 'dcsset:userSettingPresentation', item['userSettingPresentation'])
        if item.get('itemsViewMode'):
            lines.append(f'{indent}\t<dcsset:itemsViewMode>{esc_xml(str(item["itemsViewMode"]))}</dcsset:itemsViewMode>')

        lines.append(f'{indent}</dcsset:item>')

    elif item_type == 'chart':
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemChart">')

        # use=false — отключённая диаграмма
        if item.get('use') is False:
            lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')

        if item.get('name'):
            lines.append(f'{indent}\t<dcsset:name>{esc_xml(str(item["name"]))}</dcsset:name>')

        # Points — single object или массив (multi-series диаграмма)
        pts = item.get('points')
        if pts:
            pts_list = pts if isinstance(pts, list) else [pts]
            for pb in pts_list:
                lines.append(f'{indent}\t<dcsset:point>')
                emit_table_axis_block(lines, pb, f'{indent}\t\t')
                lines.append(f'{indent}\t</dcsset:point>')

        # Series — single object или массив
        srs = item.get('series')
        if srs:
            srs_list = srs if isinstance(srs, list) else [srs]
            for sb in srs_list:
                lines.append(f'{indent}\t<dcsset:series>')
                emit_table_axis_block(lines, sb, f'{indent}\t\t')
                lines.append(f'{indent}\t</dcsset:series>')

        # Selection (chart values)
        emit_selection(lines, item.get('selection'), f'{indent}\t')

        if item.get('outputParameters'):
            emit_output_parameters(lines, item['outputParameters'], f'{indent}\t')

        # pointsViewMode / seriesViewMode — axis-level режим доступности
        if item.get('pointsViewMode'):
            lines.append(f'{indent}\t<dcsset:pointsViewMode>{esc_xml(str(item["pointsViewMode"]))}</dcsset:pointsViewMode>')
        if item.get('seriesViewMode'):
            lines.append(f'{indent}\t<dcsset:seriesViewMode>{esc_xml(str(item["seriesViewMode"]))}</dcsset:seriesViewMode>')
        # viewMode / userSettingID / userSettingPresentation / itemsViewMode на самой диаграмме
        if item.get('viewMode'):
            lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
        if item.get('userSettingID'):
            gid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
            lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(gid)}</dcsset:userSettingID>')
        if item.get('userSettingPresentation'):
            emit_mltext(lines, f'{indent}\t', 'dcsset:userSettingPresentation', item['userSettingPresentation'])
        if item.get('itemsViewMode'):
            lines.append(f'{indent}\t<dcsset:itemsViewMode>{esc_xml(str(item["itemsViewMode"]))}</dcsset:itemsViewMode>')

        lines.append(f'{indent}</dcsset:item>')

    elif item_type == 'nestedObject':
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemNestedObject">')
        if item.get('objectID'):
            lines.append(f'{indent}\t<dcsset:objectID>{esc_xml(str(item["objectID"]))}</dcsset:objectID>')
        lines.append(f'{indent}\t<dcsset:settings>')
        s = item.get('settings') or {}
        if s.get('selection'):             emit_selection(lines, s['selection'], f'{indent}\t\t')
        if s.get('filter'):                emit_filter(lines, s['filter'], f'{indent}\t\t')
        if s.get('order'):                 emit_order(lines, s['order'], f'{indent}\t\t')
        if s.get('conditionalAppearance'): emit_conditional_appearance(lines, s['conditionalAppearance'], f'{indent}\t\t')
        if s.get('outputParameters'):      emit_output_parameters(lines, s['outputParameters'], f'{indent}\t\t')
        lines.append(f'{indent}\t</dcsset:settings>')
        lines.append(f'{indent}</dcsset:item>')


def emit_settings_variants(lines, defn):
    variants = defn.get('settingsVariants')

    # Default variant if none specified
    if not variants or len(variants) == 0:
        variants = [{
            'name': '\u041e\u0441\u043d\u043e\u0432\u043d\u043e\u0439',
            'presentation': '\u041e\u0441\u043d\u043e\u0432\u043d\u043e\u0439',
            'settings': {
                'selection': ['Auto'],
                'structure': [{
                    'type': 'group',
                    'order': ['Auto'],
                    'selection': ['Auto'],
                }],
            },
        }]

    for v in variants:
        lines.append('\t<settingsVariant>')
        lines.append(f'\t\t<dcsset:name>{esc_xml(str(v["name"]))}</dcsset:name>')

        pres = v.get('presentation') or v.get('title') or v['name']
        emit_mltext(lines, '\t\t', 'dcsset:presentation', pres)

        lines.append('\t\t<dcsset:settings xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows">')

        s = v.get('settings', {})

        # Helper: resolve XViewMode/XUserSettingID from settings — emit only if explicitly set
        def _block_usid(key):
            prop = f'{key}UserSettingID'
            return str(s[prop]) if prop in s else None
        def _block_vm(key):
            prop = f'{key}ViewMode'
            if prop in s:
                return str(s[prop])
            return None

        # userFields — пользовательские вычисляемые поля (Expression / Case)
        if s.get('userFields'):
            emit_user_fields(lines, s['userFields'], '\t\t\t')

        # Selection/Filter/Order/CA — эмитим даже если items пустые, но есть
        # block-level viewMode/userSettingID. Platform может содержать Auto-items
        # на top-level (вместе с явными полями), поэтому не skip_auto.
        svm, susid = _block_vm('selection'), _block_usid('selection')
        if s.get('selection') or svm is not None or susid is not None:
            emit_selection(lines, s.get('selection'), '\t\t\t', block_view_mode=svm, block_user_setting_id=susid)

        fvm, fusid = _block_vm('filter'), _block_usid('filter')
        if s.get('filter') or fvm is not None or fusid is not None:
            emit_filter(lines, s.get('filter'), '\t\t\t', block_view_mode=fvm, block_user_setting_id=fusid)

        ovm, ousid = _block_vm('order'), _block_usid('order')
        if s.get('order') or ovm is not None or ousid is not None:
            emit_order(lines, s.get('order'), '\t\t\t', block_view_mode=ovm, block_user_setting_id=ousid)

        cavm, causid = _block_vm('conditionalAppearance'), _block_usid('conditionalAppearance')
        if s.get('conditionalAppearance') or cavm is not None or causid is not None:
            emit_conditional_appearance(lines, s.get('conditionalAppearance'), '\t\t\t', block_view_mode=cavm, block_user_setting_id=causid)

        # OutputParameters (platform does NOT emit <viewMode> on this block)
        if s.get('outputParameters'):
            emit_output_parameters(lines, s['outputParameters'], '\t\t\t')

        # DataParameters
        if s.get('dataParameters') == 'auto':
            # Auto-generate dataParameters for all non-hidden params.
            # Pattern follows 1C Designer / ERP persistence:
            #   value set (non-default) → emit value, use=true (implicit)
            #   value missing / Custom period → <use>false</use> + <value xsi:nil="true"/>
            auto_dp = []
            for ap in _all_params:
                if ap['hidden']:
                    continue
                item = {
                    'parameter': ap['name'],
                    'userSettingID': 'auto',
                }
                has_meaningful_value = False

                if ap.get('type') == 'StandardPeriod':
                    variant = 'Custom'
                    av = ap.get('value')
                    if av is not None:
                        if isinstance(av, dict) and av.get('variant'):
                            variant = str(av['variant'])
                        elif str(av):
                            variant = str(av)
                    item['value'] = {'variant': variant}
                    if variant != 'Custom':
                        has_meaningful_value = True
                elif not is_empty_value(ap.get('value')):
                    item['value'] = ap['value']
                    item['valueType'] = str(ap.get('type') or '')
                    has_meaningful_value = True
                else:
                    item['nilValue'] = True

                if not has_meaningful_value:
                    item['use'] = False

                auto_dp.append(item)
            if auto_dp:
                emit_data_parameters(lines, auto_dp, '\t\t\t')
        elif s.get('dataParameters'):
            emit_data_parameters(lines, s['dataParameters'], '\t\t\t')

        # Structure (supports string shorthand)
        if s.get('structure'):
            struct_items = s['structure']
            if isinstance(struct_items, str):
                struct_items = parse_structure_shorthand(struct_items)
            elif isinstance(struct_items, dict):
                struct_items = [struct_items]
            for item in struct_items:
                emit_structure_item(lines, item, '\t\t\t')

        # <dcsset:itemsViewMode> on settings — emit only if explicitly set
        if s.get('itemsViewMode'):
            lines.append(f'\t\t\t<dcsset:itemsViewMode>{esc_xml(str(s["itemsViewMode"]))}</dcsset:itemsViewMode>')

        # <dcsset:additionalProperties> — key/value свойства варианта
        if s.get('additionalProperties'):
            lines.append('\t\t\t<dcsset:additionalProperties>')
            for k, v in s['additionalProperties'].items():
                lines.append(f'\t\t\t\t<v8:Property name="{esc_xml(str(k))}">')
                lines.append(f'\t\t\t\t\t<v8:Value xsi:type="xs:string">{esc_xml(str(v))}</v8:Value>')
                lines.append('\t\t\t\t</v8:Property>')
            lines.append('\t\t\t</dcsset:additionalProperties>')

        lines.append('\t\t</dcsset:settings>')
        lines.append('\t</settingsVariant>')


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C DCS from JSON', allow_abbrev=False)
    parser.add_argument('-DefinitionFile', type=str, default=None)
    parser.add_argument('-Value', type=str, default=None)
    parser.add_argument('-OutputPath', type=str, required=True)
    args = parser.parse_args()

    # --- 1. Load and validate JSON ---
    if args.DefinitionFile and args.Value:
        print("Cannot use both -DefinitionFile and -Value", file=sys.stderr)
        sys.exit(1)
    if not args.DefinitionFile and not args.Value:
        print("Either -DefinitionFile or -Value is required", file=sys.stderr)
        sys.exit(1)

    if args.DefinitionFile:
        def_file = args.DefinitionFile
        if not os.path.isabs(def_file):
            def_file = os.path.join(os.getcwd(), def_file)
        if not os.path.exists(def_file):
            print(f"Definition file not found: {def_file}", file=sys.stderr)
            sys.exit(1)
        with open(def_file, 'r', encoding='utf-8-sig') as f:
            json_text = f.read()
    else:
        json_text = args.Value

    defn = json.loads(json_text)

    if not defn.get('dataSets') or len(defn['dataSets']) == 0:
        print("JSON must have at least one entry in 'dataSets'", file=sys.stderr)
        sys.exit(1)

    # Base directory for resolving @file references in query
    global query_base_dir
    query_base_dir = os.path.dirname(def_file) if args.DefinitionFile else os.getcwd()

    # Load user style presets
    out_path_resolved = args.OutputPath if os.path.isabs(args.OutputPath) else os.path.join(os.getcwd(), args.OutputPath)
    load_user_styles(query_base_dir, out_path_resolved)

    # --- 2. Resolve defaults ---

    # DataSources
    data_sources = []
    if defn.get('dataSources'):
        for ds in defn['dataSources']:
            data_sources.append({
                'name': str(ds['name']),
                'type': str(ds.get('type', 'Local')),
            })
    else:
        data_sources.append({'name': '\u0418\u0441\u0442\u043e\u0447\u043d\u0438\u043a\u0414\u0430\u043d\u043d\u044b\u04451', 'type': 'Local'})

    default_source = data_sources[0]['name']

    # Auto-name dataSets
    ds_index = 1
    for ds in defn['dataSets']:
        if not ds.get('name'):
            ds['name'] = f'\u041d\u0430\u0431\u043e\u0440\u0414\u0430\u043d\u043d\u044b\u0445{ds_index}'
        ds_index += 1

    # --- 3. Assemble XML ---
    lines = []

    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(
        '<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"'
        ' xmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"'
        ' xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"'
        ' xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"'
        ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
        ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
        ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    )

    emit_data_sources(lines, data_sources)
    emit_data_sets(lines, defn, default_source)
    emit_data_set_links(lines, defn)
    emit_calc_fields(lines, defn)
    emit_total_fields(lines, defn)
    emit_parameters(lines, defn)
    emit_templates(lines, defn)
    emit_field_templates(lines, defn)
    emit_group_templates(lines, defn)
    emit_settings_variants(lines, defn)

    lines.append('</DataCompositionSchema>')

    # --- 4. Write output ---
    output_path = args.OutputPath
    if not os.path.isabs(output_path):
        output_path = os.path.join(os.getcwd(), output_path)

    assert_edit_allowed(output_path, "editable")

    parent_dir = os.path.dirname(output_path)
    if parent_dir and not os.path.exists(parent_dir):
        os.makedirs(parent_dir, exist_ok=True)

    content = '\n'.join(lines) + '\n'
    write_utf8_bom(output_path, content)

    # --- 5. Statistics ---
    ds_count = len(defn['dataSets'])
    field_count = 0
    for ds in defn['dataSets']:
        if ds.get('fields'):
            field_count += len(ds['fields'])
    calc_count = len(defn['calculatedFields']) if defn.get('calculatedFields') else 0
    total_count = len(defn['totalFields']) if defn.get('totalFields') else 0
    param_count = len(defn['parameters']) if defn.get('parameters') else 0
    variant_count = len(defn['settingsVariants']) if defn.get('settingsVariants') else 1
    file_size = os.path.getsize(output_path)

    print(f"OK  {args.OutputPath}")
    print(f"    DataSets: {ds_count}  Fields: {field_count}  Calculated: {calc_count}  Totals: {total_count}  Params: {param_count}  Variants: {variant_count}")
    print(f"    Size: {file_size} bytes")


if __name__ == '__main__':
    main()
