#!/usr/bin/env python3
# meta-edit v1.22 — Edit existing 1C metadata object XML
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import subprocess
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


# ============================================================
# Namespaces
# ============================================================

MD_NS = "http://v8.1c.ru/8.3/MDClasses"
XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
V8_NS = "http://v8.1c.ru/8.1/data/core"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
XS_NS = "http://www.w3.org/2001/XMLSchema"
CFG_NS = "http://v8.1c.ru/8.1/data/enterprise/current-config"

NSMAP_WRAPPER = {
    None: MD_NS,
    "xsi": XSI_NS,
    "v8": V8_NS,
    "xr": XR_NS,
    "cfg": CFG_NS,
    "xs": XS_NS,
}

# ============================================================
# Global state
# ============================================================

xml_tree = None   # etree._ElementTree
xml_root = None   # root <MetaDataObject>
obj_element = None  # the object type element (e.g. <Catalog>)
obj_type = ""
md_ns = ""
properties_el = None
child_objects_el = None
obj_name = ""
resolved_path = ""

add_count = 0
remove_count = 0
modify_count = 0
warn_count = 0

# ============================================================
# Utilities
# ============================================================


def info(msg):
    print(f"[INFO] {msg}")


def warn(msg):
    global warn_count
    print(f"[WARN] {msg}")
    warn_count += 1


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def localname(el):
    return etree.QName(el.tag).localname


def esc_xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


# ============================================================
# Enum value normalization (same as meta-compile)
# ============================================================

enum_value_aliases = {
    # RegisterType (AccumulationRegister)
    'Balances': 'Balance', 'Остатки': 'Balance', 'Обороты': 'Turnovers',
    # WriteMode (InformationRegister)
    'RecordSubordinate': 'RecorderSubordinate', 'Subordinate': 'RecorderSubordinate',
    'ПодчинениеРегистратору': 'RecorderSubordinate', 'Независимый': 'Independent',
    # DependenceOnCalculationTypes (ChartOfCalculationTypes)
    'NotDependOnCalculationTypes': 'DontUse', 'NoDependence': 'DontUse', 'NotUsed': 'DontUse',
    'Depend': 'OnActionPeriod', 'ПоПериодуДействия': 'OnActionPeriod',
    # InformationRegisterPeriodicity
    'None': 'Nonperiodical', 'Daily': 'Day', 'Monthly': 'Month',
    'Quarterly': 'Quarter', 'Yearly': 'Year',
    'Непериодический': 'Nonperiodical', 'Секунда': 'Second', 'День': 'Day',
    'Месяц': 'Month', 'Квартал': 'Quarter', 'Год': 'Year',
    'ПозицияРегистратора': 'RecorderPosition',
    # DataLockControlMode
    'Автоматический': 'Automatic', 'Управляемый': 'Managed',
    # FullTextSearch
    'Использовать': 'Use', 'НеИспользовать': 'DontUse',
    # Posting
    'Разрешить': 'Allow', 'Запретить': 'Deny',
    # EditType
    'ВДиалоге': 'InDialog', 'ВСписке': 'InList', 'ОбаСпособа': 'BothWays',
    # DefaultPresentation
    'ВВидеНаименования': 'AsDescription', 'ВВидеКода': 'AsCode',
    # FillChecking
    'НеПроверять': 'DontCheck', 'Ошибка': 'ShowError', 'Предупреждение': 'ShowWarning',
    # Indexing
    'НеИндексировать': 'DontIndex', 'Индексировать': 'Index',
    'ИндексироватьСДопУпорядочиванием': 'IndexWithAdditionalOrder',
}

valid_enum_values = {
    'RegisterType': ['Balance', 'Turnovers'],
    'WriteMode': ['Independent', 'RecorderSubordinate'],
    'InformationRegisterPeriodicity': ['Nonperiodical', 'Second', 'Day', 'Month', 'Quarter', 'Year', 'RecorderPosition'],
    'DependenceOnCalculationTypes': ['DontUse', 'OnActionPeriod'],
    'DataLockControlMode': ['Automatic', 'Managed'],
    'FullTextSearch': ['Use', 'DontUse'],
    'DataHistory': ['Use', 'DontUse'],
    'DefaultPresentation': ['AsDescription', 'AsCode'],
    'Posting': ['Allow', 'Deny'],
    'RealTimePosting': ['Allow', 'Deny'],
    'EditType': ['InDialog', 'InList', 'BothWays'],
    'HierarchyType': ['HierarchyFoldersAndItems', 'HierarchyOfItems'],
    'CodeType': ['String', 'Number'],
    'CodeAllowedLength': ['Variable', 'Fixed'],
    'NumberType': ['String', 'Number'],
    'NumberAllowedLength': ['Variable', 'Fixed'],
    'RegisterRecordsDeletion': ['AutoDelete', 'AutoDeleteOnUnpost', 'AutoDeleteOff'],
    'RegisterRecordsWritingOnPost': ['WriteModified', 'WriteSelected', 'WriteAll'],
    'ReturnValuesReuse': ['DontUse', 'DuringRequest', 'DuringSession'],
    'ReuseSessions': ['DontUse', 'AutoUse'],
    'FillChecking': ['DontCheck', 'ShowError', 'ShowWarning'],
    'Indexing': ['DontIndex', 'Index', 'IndexWithAdditionalOrder'],
}


def normalize_enum_value(prop_name, value):
    # 1. Check alias dictionary — silent auto-correct
    if value in enum_value_aliases:
        return enum_value_aliases[value]
    # 2. Case-insensitive match against valid values — silent
    valid = valid_enum_values.get(prop_name)
    if valid:
        for v in valid:
            if v.lower() == value.lower():
                return v
        # 3. Known property, unknown value — error with hint
        print(f"Invalid value '{value}' for property '{prop_name}'. Valid values: {', '.join(valid)}", file=sys.stderr)
        sys.exit(1)
    # 4. Unknown property — pass-through (no validation data)
    return value


def new_uuid():
    return str(uuid.uuid4())


def split_camel_case(name):
    if not name:
        return name
    # Insert space between lowercase Cyrillic and uppercase Cyrillic
    result = re.sub(r"([а-яё])([А-ЯЁ])", r"\1 \2", name)
    # Insert space between lowercase Latin and uppercase Latin
    result = re.sub(r"([a-z])([A-Z])", r"\1 \2", result)
    if len(result) > 1:
        result = result[0] + result[1:].lower()
    return result


# ============================================================
# Synonym tables
# ============================================================

operation_synonyms = {
    "add": "add", "добавить": "add",
    "remove": "remove", "удалить": "remove",
    "modify": "modify", "изменить": "modify",
}

child_type_synonyms = {
    "attributes": "attributes", "реквизиты": "attributes", "attrs": "attributes",
    "tabularsections": "tabularSections", "табличныечасти": "tabularSections", "тч": "tabularSections", "ts": "tabularSections",
    "dimensions": "dimensions", "измерения": "dimensions", "dims": "dimensions",
    "resources": "resources", "ресурсы": "resources", "res": "resources",
    "enumvalues": "enumValues", "значения": "enumValues", "values": "enumValues",
    "columns": "columns", "графы": "columns", "колонки": "columns",
    "forms": "forms", "формы": "forms",
    "templates": "templates", "макеты": "templates",
    "commands": "commands", "команды": "commands",
    "properties": "properties", "свойства": "properties",
}

type_synonyms = {
    "число": "Number",
    "строка": "String",
    "булево": "Boolean",
    "дата": "Date",
    "датавремя": "DateTime",
    "хранилищезначения": "ValueStorage",
    "number": "Number",
    "string": "String",
    "boolean": "Boolean",
    "date": "Date",
    "datetime": "DateTime",
    "valuestorage": "ValueStorage",
    "bool": "Boolean",
    # Reference synonyms
    "справочникссылка": "CatalogRef",
    "документссылка": "DocumentRef",
    "перечислениессылка": "EnumRef",
    "плансчетовссылка": "ChartOfAccountsRef",
    "планвидовхарактеристикссылка": "ChartOfCharacteristicTypesRef",
    "планвидоврасчётассылка": "ChartOfCalculationTypesRef",
    "планвидоврасчетассылка": "ChartOfCalculationTypesRef",
    "планобменассылка": "ExchangePlanRef",
    "бизнеспроцессссылка": "BusinessProcessRef",
    "задачассылка": "TaskRef",
    "определяемыйтип": "DefinedType",
    "definedtype": "DefinedType",
    "catalogref": "CatalogRef",
    "documentref": "DocumentRef",
    "enumref": "EnumRef",
}

# ============================================================
# Type system
# ============================================================


def resolve_type_str(type_str):
    if not type_str:
        return type_str

    # Parameterized: Number(15,2), Строка(100)
    m = re.match(r"^([^(]+)\((.+)\)$", type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = type_synonyms.get(base_name.lower())
        if resolved:
            return f"{resolved}({params})"
        return type_str

    # Reference: СправочникСсылка.Организации
    if "." in type_str:
        dot_idx = type_str.index(".")
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]
        resolved = type_synonyms.get(prefix.lower())
        if resolved:
            return f"{resolved}{suffix}"
        return type_str

    # Simple
    resolved = type_synonyms.get(type_str.lower())
    if resolved:
        return resolved
    return type_str


def build_type_content_xml(indent, type_str):
    if not type_str:
        return ""

    # Composite type: "Type1 + Type2 + Type3"
    if " + " in type_str:
        parts = [p.strip() for p in type_str.split("+")]
        results = []
        for part in parts:
            inner = build_type_content_xml(indent, part)
            if inner:
                results.append(inner)
        return "\r\n".join(results)

    type_str = resolve_type_str(type_str)
    lines = []

    # Boolean
    if type_str == "Boolean":
        lines.append(f"{indent}<v8:Type>xs:boolean</v8:Type>")
        return "\r\n".join(lines)

    # ValueStorage
    if type_str == "ValueStorage":
        lines.append(f"{indent}<v8:Type>xs:base64Binary</v8:Type>")
        return "\r\n".join(lines)

    # String or String(N)
    m = re.match(r"^String(\((\d+)\))?$", type_str)
    if m:
        length = m.group(2) if m.group(2) else "10"
        lines.append(f"{indent}<v8:Type>xs:string</v8:Type>")
        lines.append(f"{indent}<v8:StringQualifiers>")
        lines.append(f"{indent}\t<v8:Length>{length}</v8:Length>")
        lines.append(f"{indent}\t<v8:AllowedLength>Variable</v8:AllowedLength>")
        lines.append(f"{indent}</v8:StringQualifiers>")
        return "\r\n".join(lines)

    # Number(D,F) or Number(D,F,nonneg)
    m = re.match(r"^Number\((\d+),(\d+)(,nonneg)?\)$", type_str)
    if m:
        digits = m.group(1)
        fraction = m.group(2)
        sign = "Nonnegative" if m.group(3) else "Any"
        lines.append(f"{indent}<v8:Type>xs:decimal</v8:Type>")
        lines.append(f"{indent}<v8:NumberQualifiers>")
        lines.append(f"{indent}\t<v8:Digits>{digits}</v8:Digits>")
        lines.append(f"{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>")
        lines.append(f"{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>")
        lines.append(f"{indent}</v8:NumberQualifiers>")
        return "\r\n".join(lines)

    # Number without params -> Number(10,0)
    if type_str == "Number":
        lines.append(f"{indent}<v8:Type>xs:decimal</v8:Type>")
        lines.append(f"{indent}<v8:NumberQualifiers>")
        lines.append(f"{indent}\t<v8:Digits>10</v8:Digits>")
        lines.append(f"{indent}\t<v8:FractionDigits>0</v8:FractionDigits>")
        lines.append(f"{indent}\t<v8:AllowedSign>Any</v8:AllowedSign>")
        lines.append(f"{indent}</v8:NumberQualifiers>")
        return "\r\n".join(lines)

    # Date / DateTime
    if type_str == "Date":
        lines.append(f"{indent}<v8:Type>xs:dateTime</v8:Type>")
        lines.append(f"{indent}<v8:DateQualifiers>")
        lines.append(f"{indent}\t<v8:DateFractions>Date</v8:DateFractions>")
        lines.append(f"{indent}</v8:DateQualifiers>")
        return "\r\n".join(lines)

    if type_str == "DateTime":
        lines.append(f"{indent}<v8:Type>xs:dateTime</v8:Type>")
        lines.append(f"{indent}<v8:DateQualifiers>")
        lines.append(f"{indent}\t<v8:DateFractions>DateTime</v8:DateFractions>")
        lines.append(f"{indent}</v8:DateQualifiers>")
        return "\r\n".join(lines)

    # DefinedType
    m = re.match(r"^DefinedType\.(.+)$", type_str)
    if m:
        dt_name = m.group(1)
        lines.append(f"{indent}<v8:TypeSet>cfg:DefinedType.{dt_name}</v8:TypeSet>")
        return "\r\n".join(lines)

    # Reference types — use local xmlns declaration for 1C compatibility
    m = re.match(
        r"^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|"
        r"ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef)\.(.+)$",
        type_str,
    )
    if m:
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{type_str}</v8:Type>')
        return "\r\n".join(lines)

    # Fallback
    lines.append(f"{indent}<v8:Type>{type_str}</v8:Type>")
    return "\r\n".join(lines)


def build_value_type_xml(indent, type_str):
    inner = build_type_content_xml(f"{indent}\t", type_str)
    return f"{indent}<Type>\r\n{inner}\r\n{indent}</Type>"


def build_fill_value_xml(indent, type_str):
    if not type_str:
        return f'{indent}<FillValue xsi:nil="true"/>'
    type_str = resolve_type_str(type_str)
    if type_str == "Boolean":
        return f'{indent}<FillValue xsi:type="xs:boolean">false</FillValue>'
    if type_str.startswith("String"):
        return f'{indent}<FillValue xsi:type="xs:string"/>'
    if type_str.startswith("Number"):
        return f'{indent}<FillValue xsi:type="xs:decimal">0</FillValue>'
    return f'{indent}<FillValue xsi:nil="true"/>'


def build_mltext_xml(indent, tag, text):
    if not text:
        return f"{indent}<{tag}/>"
    lines = [
        f"{indent}<{tag}>",
        f"{indent}\t<v8:item>",
        f"{indent}\t\t<v8:lang>ru</v8:lang>",
        f"{indent}\t\t<v8:content>{esc_xml(text)}</v8:content>",
        f"{indent}\t</v8:item>",
        f"{indent}</{tag}>",
    ]
    return "\r\n".join(lines)


# ============================================================
# DOM helpers
# ============================================================


def import_fragment(xml_string):
    """Parse an XML fragment in the context of our namespace declarations, return list of elements."""
    wrapper = (
        f'<_W xmlns="{MD_NS}"'
        f' xmlns:xsi="{XSI_NS}"'
        f' xmlns:v8="{V8_NS}"'
        f' xmlns:xr="{XR_NS}"'
        f' xmlns:cfg="{CFG_NS}"'
        f' xmlns:app="http://v8.1c.ru/8.2/managed-application/core"'
        f' xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"'
        f' xmlns:xs="{XS_NS}">'
        f"{xml_string}</_W>"
    )
    parser = etree.XMLParser(remove_blank_text=False)
    frag = etree.fromstring(wrapper.encode("utf-8"), parser)
    nodes = []
    for child in frag:
        nodes.append(child)
    return nodes


def get_child_indent(container):
    """Detect indentation of children inside a container element."""
    # Check container.text (text before first child)
    if container.text and "\n" in container.text:
        after_nl = container.text.rsplit("\n", 1)[-1]
        if after_nl and not after_nl.strip():
            return after_nl
    # Check tail of child elements
    for child in container:
        if child.tail and "\n" in child.tail:
            after_nl = child.tail.rsplit("\n", 1)[-1]
            if after_nl and not after_nl.strip():
                return after_nl
    # Fallback: count depth
    depth = 0
    current = container
    while current is not None:
        parent = current.getparent()
        if parent is None:
            break
        if parent is xml_root:
            break
        depth += 1
        current = parent
    return "\t" * (depth + 1)


def insert_before_element(container, new_node, ref_node, child_indent):
    """Insert new_node into container before ref_node. If ref_node is None, append."""
    if ref_node is not None:
        # Insert before ref_node
        idx = list(container).index(ref_node)
        new_node.tail = "\r\n" + child_indent
        container.insert(idx, new_node)
    else:
        # Append: insert before closing tag
        children = list(container)
        if len(children) > 0:
            last = children[-1]
            # The last element's tail is the whitespace before </Container>
            # We set new_node.tail to what last.tail was (newline + parent indent)
            new_node.tail = last.tail
            last.tail = "\r\n" + child_indent
            container.append(new_node)
        else:
            # Container is empty (possibly self-closing)
            parent_indent = child_indent[:-1] if len(child_indent) > 0 else ""
            container.text = "\r\n" + child_indent
            new_node.tail = "\r\n" + parent_indent
            container.append(new_node)


def remove_node_with_whitespace(node):
    """Remove an element from its parent, cleaning up whitespace."""
    parent = node.getparent()
    prev = node.getprevious()
    if prev is not None:
        # Transfer tail to previous sibling
        if node.tail:
            prev.tail = node.tail
    else:
        # First child: adjust parent.text
        if node.tail:
            parent.text = node.tail
    parent.remove(node)


def find_element_by_name(container, elem_local_name, name_value):
    """Find a child element of given localname whose Properties/Name (or just Name) == name_value."""
    for child in container:
        if localname(child) != elem_local_name:
            continue
        # Look for Properties/Name or just Name child
        props_el = None
        for gc in child:
            if localname(gc) == "Properties":
                props_el = gc
                break
        search_in = props_el if props_el is not None else child
        for gc in search_in:
            if localname(gc) == "Name":
                text = (gc.text or "").strip()
                if text == name_value:
                    return child
    return None


def find_last_element_of_type(container, local_name):
    last = None
    for child in container:
        if localname(child) == local_name:
            last = child
    return last


def find_first_element_of_type(container, local_name):
    for child in container:
        if localname(child) == local_name:
            return child
    return None


def ensure_child_objects_open():
    """Ensure ChildObjects element exists and is open (not self-closing empty)."""
    global child_objects_el

    if child_objects_el is not None:
        # Check if it's empty (no child elements)
        has_elements = any(True for _ in child_objects_el)
        if not has_elements:
            # It's empty - add whitespace for proper formatting
            indent = get_child_indent(obj_element)
            child_objects_el.text = "\r\n" + indent
        return

    # No ChildObjects at all - create one after Properties
    indent = get_child_indent(obj_element)

    co_el = etree.Element(f"{{{md_ns}}}ChildObjects")
    co_el.text = "\r\n" + indent

    # Find where to insert: after Properties
    ref_node = None
    found_props = False
    for child in obj_element:
        if localname(child) == "Properties":
            found_props = True
            continue
        if found_props:
            ref_node = child
            break

    if ref_node is not None:
        # Insert before ref_node
        idx = list(obj_element).index(ref_node)
        co_el.tail = "\r\n" + indent
        obj_element.insert(idx, co_el)
    else:
        # Append
        children = list(obj_element)
        if len(children) > 0:
            last = children[-1]
            co_el.tail = last.tail
            last.tail = "\r\n" + indent
            obj_element.append(co_el)
        else:
            parent_indent = indent[:-1] if len(indent) > 0 else ""
            obj_element.text = "\r\n" + indent
            co_el.tail = "\r\n" + parent_indent
            obj_element.append(co_el)

    child_objects_el = co_el


def collapse_child_objects_if_empty():
    """Collapse ChildObjects to self-closing if empty."""
    global child_objects_el
    if child_objects_el is None:
        return
    has_elements = any(True for _ in child_objects_el)
    if not has_elements:
        child_objects_el.text = None


# ============================================================
# Fragment builders
# ============================================================


def parse_attribute_shorthand(val):
    """Parse attribute definition from string shorthand or dict object."""
    if isinstance(val, str):
        s = val
        parsed = {
            "name": "", "type": "", "synonym": "", "comment": "",
            "flags": [], "fillChecking": "", "indexing": "",
            "after": "", "before": "",
        }
        # Extract positional markers: >> after Name, << before Name
        m = re.search(r"\s*>>\s*after\s+(\S+)\s*$", s)
        if m:
            parsed["after"] = m.group(1)
            s = re.sub(r"\s*>>\s*after\s+\S+\s*$", "", s).strip()
        else:
            m = re.search(r"\s*<<\s*before\s+(\S+)\s*$", s)
            if m:
                parsed["before"] = m.group(1)
                s = re.sub(r"\s*<<\s*before\s+\S+\s*$", "", s).strip()

        # Split by | for flags
        parts = s.split("|", 1)
        main_part = parts[0].strip()
        if len(parts) > 1:
            flag_str = parts[1].strip()
            parsed["flags"] = [f.strip().lower() for f in flag_str.split(",") if f.strip()]

        # Split by : for name and type
        colon_parts = main_part.split(":", 1)
        parsed["name"] = colon_parts[0].strip()
        if len(colon_parts) > 1:
            parsed["type"] = colon_parts[1].strip()

        parsed["synonym"] = split_camel_case(parsed["name"])
        return parsed

    # Object/dict form
    name = str(val.get("name", ""))
    result = {
        "name": name,
        "type": " + ".join(str(t) for t in val["type"]) if isinstance(val.get("type"), list) else str(val.get("type", "")),
        "synonym": str(val.get("synonym", "")) if val.get("synonym") else split_camel_case(name),
        "comment": str(val.get("comment", "")),
        "flags": list(val.get("flags", [])),
        "fillChecking": normalize_enum_value("FillChecking", str(val.get("fillChecking", ""))) if val.get("fillChecking") else "",
        "indexing": normalize_enum_value("Indexing", str(val.get("indexing", ""))) if val.get("indexing") else "",
        "after": str(val.get("after", "")),
        "before": str(val.get("before", "")),
    }
    # Map flags to properties
    if "req" in result["flags"] and not result["fillChecking"]:
        result["fillChecking"] = "ShowError"
    if "index" in result["flags"] and not result["indexing"]:
        result["indexing"] = "Index"
    if "indexadditional" in result["flags"] and not result["indexing"]:
        result["indexing"] = "IndexWithAdditionalOrder"
    return result


def parse_enum_value_shorthand(val):
    """Parse enum value definition from string or dict."""
    if isinstance(val, str):
        name = val
        return {
            "name": name,
            "synonym": split_camel_case(name),
            "comment": "",
            "after": "", "before": "",
        }
    name = str(val.get("name", ""))
    return {
        "name": name,
        "synonym": str(val.get("synonym", "")) if val.get("synonym") else split_camel_case(name),
        "comment": str(val.get("comment", "")),
        "after": str(val.get("after", "")),
        "before": str(val.get("before", "")),
    }


def get_attribute_context():
    """Determine attribute context from object type."""
    if obj_type == "Catalog":
        return "catalog"
    if obj_type == "Document":
        return "document"
    if obj_type in ("InformationRegister", "AccumulationRegister", "AccountingRegister", "CalculationRegister"):
        return "register"
    if obj_type in ("DataProcessor", "Report", "ExternalDataProcessor", "ExternalReport"):
        return "processor"
    return "object"


RESERVED_ATTR_NAMES = {
    'Ref', 'DeletionMark', 'Code', 'Description', 'Date', 'Number', 'Posted',
    'Parent', 'Owner', 'IsFolder', 'Predefined', 'PredefinedDataName',
    'Recorder', 'Period', 'LineNumber', 'Active', 'Order', 'Type', 'OffBalance',
    'Started', 'Completed', 'HeadTask', 'Executed', 'RoutePoint', 'BusinessProcess',
    'ThisNode', 'SentNo', 'ReceivedNo', 'CalculationType', 'RegistrationPeriod',
    'ReversingEntry', 'Account', 'ValueType', 'ActionPeriodIsBasic',
}
RESERVED_ATTR_NAMES_RU = {
    'Ссылка', 'ПометкаУдаления', 'Код', 'Наименование',
    'Дата', 'Номер', 'Проведен', 'Родитель', 'Владелец',
    'ЭтоГруппа', 'Предопределенный', 'ИмяПредопределенныхДанных',
    'Регистратор', 'Период', 'НомерСтроки', 'Активность',
    'Порядок', 'Тип', 'Забалансовый',
    'Стартован', 'Завершен', 'ВедущаяЗадача',
    'Выполнена', 'ТочкаМаршрута', 'БизнесПроцесс',
    'ЭтотУзел', 'НомерОтправленного', 'НомерПринятого',
    'ВидРасчета', 'ПериодРегистрации', 'СторноЗапись',
    'Счет', 'ТипЗначения', 'ПериодДействияБазовый',
}


# Стандартные реквизиты по типу объекта (EN + RU). Совпадение имени реквизита с ними платформа
# не позволит — жёсткий отказ. Контексты вне карты → предупреждение по плоскому списку.
RESERVED_BY_CONTEXT = {
    'catalog': {
        'ref', 'ссылка',
        'deletionmark', 'пометкаудаления',
        'predefined', 'предопределенный',
        'predefineddataname', 'имяпредопределенныхданных',
        'code', 'код',
        'description', 'наименование',
        'owner', 'владелец',
        'parent', 'родитель',
        'isfolder', 'этогруппа',
    },
    'document': {
        'ref', 'ссылка',
        'deletionmark', 'пометкаудаления',
        'date', 'дата',
        'number', 'номер',
        'posted', 'проведен',
    },
}


def build_attribute_fragment(parsed, context, indent):
    """Build XML fragment string for an Attribute element."""
    if not context:
        context = get_attribute_context()

    # Check reserved attribute names (типозависимо: catalog/document — отказ; прочее — предупреждение)
    attr_name = parsed['name']
    ctx_reserved = RESERVED_BY_CONTEXT.get(context)
    if ctx_reserved is not None:
        if attr_name.lower() in ctx_reserved:
            print(f"meta-edit: имя реквизита '{attr_name}' зарезервировано стандартным реквизитом объекта '{context}'. Выберите другое имя.", file=sys.stderr)
            sys.exit(1)
    elif context not in ('tabular', 'processor-tabular') and (attr_name in RESERVED_ATTR_NAMES or attr_name in RESERVED_ATTR_NAMES_RU):
        print(f"WARNING: Attribute '{attr_name}' conflicts with a standard attribute name. This may cause errors when loading into 1C.", file=sys.stderr)

    uid = new_uuid()
    lines = []

    lines.append(f'{indent}<Attribute uuid="{uid}">')
    lines.append(f"{indent}\t<Properties>")
    lines.append(f"{indent}\t\t<Name>{esc_xml(parsed['name'])}</Name>")
    lines.append(build_mltext_xml(f"{indent}\t\t", "Synonym", parsed["synonym"]))
    lines.append(f"{indent}\t\t<Comment/>")

    # Type
    type_str = parsed["type"]
    if type_str:
        lines.append(build_value_type_xml(f"{indent}\t\t", type_str))
    else:
        lines.append(f"{indent}\t\t<Type>")
        lines.append(f"{indent}\t\t\t<v8:Type>xs:string</v8:Type>")
        lines.append(f"{indent}\t\t</Type>")

    lines.append(f"{indent}\t\t<PasswordMode>false</PasswordMode>")
    lines.append(f"{indent}\t\t<Format/>")
    lines.append(f"{indent}\t\t<EditFormat/>")
    lines.append(f"{indent}\t\t<ToolTip/>")
    lines.append(f"{indent}\t\t<MarkNegatives>false</MarkNegatives>")
    lines.append(f"{indent}\t\t<Mask/>")
    lines.append(f"{indent}\t\t<MultiLine>false</MultiLine>")
    lines.append(f"{indent}\t\t<ExtendedEdit>false</ExtendedEdit>")
    lines.append(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    lines.append(f'{indent}\t\t<MaxValue xsi:nil="true"/>')

    # FillFromFillingValue/FillValue -- not for register, tabular, or processor
    if context not in ("register", "tabular", "processor"):
        lines.append(f"{indent}\t\t<FillFromFillingValue>false</FillFromFillingValue>")
        lines.append(build_fill_value_xml(f"{indent}\t\t", type_str))

    # FillChecking
    fill_checking = "DontCheck"
    if "req" in parsed["flags"]:
        fill_checking = "ShowError"
    if parsed["fillChecking"]:
        fill_checking = parsed["fillChecking"]
    lines.append(f"{indent}\t\t<FillChecking>{fill_checking}</FillChecking>")

    lines.append(f"{indent}\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>")
    lines.append(f"{indent}\t\t<ChoiceParameterLinks/>")
    lines.append(f"{indent}\t\t<ChoiceParameters/>")
    lines.append(f"{indent}\t\t<QuickChoice>Auto</QuickChoice>")
    lines.append(f"{indent}\t\t<CreateOnInput>Auto</CreateOnInput>")
    lines.append(f"{indent}\t\t<ChoiceForm/>")
    lines.append(f"{indent}\t\t<LinkByType/>")
    lines.append(f"{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>")

    # Use -- catalog only
    if context == "catalog":
        lines.append(f"{indent}\t\t<Use>ForItem</Use>")

    # Indexing/FullTextSearch/DataHistory -- not for non-stored objects
    if context not in ("processor", "processor-tabular"):
        indexing = "DontIndex"
        if "index" in parsed["flags"]:
            indexing = "Index"
        if "indexadditional" in parsed["flags"]:
            indexing = "IndexWithAdditionalOrder"
        if parsed["indexing"]:
            indexing = parsed["indexing"]
        lines.append(f"{indent}\t\t<Indexing>{indexing}</Indexing>")
        lines.append(f"{indent}\t\t<FullTextSearch>Use</FullTextSearch>")
        lines.append(f"{indent}\t\t<DataHistory>Use</DataHistory>")

    lines.append(f"{indent}\t</Properties>")
    lines.append(f"{indent}</Attribute>")
    return "\r\n".join(lines)


def build_tabular_section_fragment(ts_def, indent):
    """Build XML fragment string for a TabularSection element."""
    if isinstance(ts_def, str):
        ts_def = {"name": ts_def}
    ts_name = str(ts_def.get("name", ""))
    ts_synonym = str(ts_def.get("synonym", "")) if ts_def.get("synonym") else split_camel_case(ts_name)
    uid = new_uuid()

    type_prefix = f"{obj_type}TabularSection"
    row_prefix = f"{obj_type}TabularSectionRow"

    lines = []
    lines.append(f'{indent}<TabularSection uuid="{uid}">')

    # InternalInfo
    lines.append(f"{indent}\t<InternalInfo>")
    lines.append(f'{indent}\t\t<xr:GeneratedType name="{type_prefix}.{obj_name}.{ts_name}" category="TabularSection">')
    lines.append(f"{indent}\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>")
    lines.append(f"{indent}\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>")
    lines.append(f"{indent}\t\t</xr:GeneratedType>")
    lines.append(f'{indent}\t\t<xr:GeneratedType name="{row_prefix}.{obj_name}.{ts_name}" category="TabularSectionRow">')
    lines.append(f"{indent}\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>")
    lines.append(f"{indent}\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>")
    lines.append(f"{indent}\t\t</xr:GeneratedType>")
    lines.append(f"{indent}\t</InternalInfo>")

    # Properties
    lines.append(f"{indent}\t<Properties>")
    lines.append(f"{indent}\t\t<Name>{esc_xml(ts_name)}</Name>")
    lines.append(build_mltext_xml(f"{indent}\t\t", "Synonym", ts_synonym))
    lines.append(f"{indent}\t\t<Comment/>")
    lines.append(f"{indent}\t\t<ToolTip/>")
    lines.append(f"{indent}\t\t<FillChecking>DontCheck</FillChecking>")

    # StandardAttributes (LineNumber)
    lines.append(f"{indent}\t\t<StandardAttributes>")
    lines.append(f'{indent}\t\t\t<xr:StandardAttribute name="LineNumber">')
    lines.append(f"{indent}\t\t\t\t<xr:LinkByType/>")
    lines.append(f"{indent}\t\t\t\t<xr:FillChecking>DontCheck</xr:FillChecking>")
    lines.append(f"{indent}\t\t\t\t<xr:MultiLine>false</xr:MultiLine>")
    lines.append(f"{indent}\t\t\t\t<xr:FillFromFillingValue>false</xr:FillFromFillingValue>")
    lines.append(f"{indent}\t\t\t\t<xr:CreateOnInput>Auto</xr:CreateOnInput>")
    lines.append(f'{indent}\t\t\t\t<xr:MaxValue xsi:nil="true"/>')
    lines.append(f"{indent}\t\t\t\t<xr:ToolTip/>")
    lines.append(f"{indent}\t\t\t\t<xr:ExtendedEdit>false</xr:ExtendedEdit>")
    lines.append(f"{indent}\t\t\t\t<xr:Format/>")
    lines.append(f"{indent}\t\t\t\t<xr:ChoiceForm/>")
    lines.append(f"{indent}\t\t\t\t<xr:QuickChoice>Auto</xr:QuickChoice>")
    lines.append(f"{indent}\t\t\t\t<xr:ChoiceHistoryOnInput>Auto</xr:ChoiceHistoryOnInput>")
    lines.append(f"{indent}\t\t\t\t<xr:EditFormat/>")
    lines.append(f"{indent}\t\t\t\t<xr:PasswordMode>false</xr:PasswordMode>")
    lines.append(f"{indent}\t\t\t\t<xr:DataHistory>Use</xr:DataHistory>")
    lines.append(f"{indent}\t\t\t\t<xr:MarkNegatives>false</xr:MarkNegatives>")
    lines.append(f'{indent}\t\t\t\t<xr:MinValue xsi:nil="true"/>')
    lines.append(f"{indent}\t\t\t\t<xr:Synonym/>")
    lines.append(f"{indent}\t\t\t\t<xr:Comment/>")
    lines.append(f"{indent}\t\t\t\t<xr:FullTextSearch>Use</xr:FullTextSearch>")
    lines.append(f"{indent}\t\t\t\t<xr:ChoiceParameterLinks/>")
    lines.append(f'{indent}\t\t\t\t<xr:FillValue xsi:nil="true"/>')
    lines.append(f"{indent}\t\t\t\t<xr:Mask/>")
    lines.append(f"{indent}\t\t\t\t<xr:ChoiceParameters/>")
    lines.append(f"{indent}\t\t\t</xr:StandardAttribute>")
    lines.append(f"{indent}\t\t</StandardAttributes>")

    # Use -- catalog only
    if obj_type == "Catalog":
        lines.append(f"{indent}\t\t<Use>ForItem</Use>")

    lines.append(f"{indent}\t</Properties>")

    # ChildObjects with attrs
    columns = []
    if ts_def.get("attrs"):
        columns = list(ts_def["attrs"])
    elif ts_def.get("attributes"):
        columns = list(ts_def["attributes"])
    elif ts_def.get("реквизиты"):
        columns = list(ts_def["реквизиты"])

    ts_attr_context = "processor-tabular" if obj_type in ("DataProcessor", "Report", "ExternalDataProcessor", "ExternalReport") else "tabular"
    if columns:
        lines.append(f"{indent}\t<ChildObjects>")
        for col in columns:
            col_parsed = parse_attribute_shorthand(col)
            lines.append(build_attribute_fragment(col_parsed, ts_attr_context, f"{indent}\t\t"))
        lines.append(f"{indent}\t</ChildObjects>")
    else:
        lines.append(f"{indent}\t<ChildObjects/>")

    lines.append(f"{indent}</TabularSection>")
    return "\r\n".join(lines)


def build_dimension_fragment(parsed, register_type, indent):
    """Build XML fragment string for a Dimension element."""
    if not register_type:
        register_type = obj_type
    uid = new_uuid()
    lines = []

    lines.append(f'{indent}<Dimension uuid="{uid}">')
    lines.append(f"{indent}\t<Properties>")
    lines.append(f"{indent}\t\t<Name>{esc_xml(parsed['name'])}</Name>")
    lines.append(build_mltext_xml(f"{indent}\t\t", "Synonym", parsed["synonym"]))
    lines.append(f"{indent}\t\t<Comment/>")

    type_str = parsed["type"]
    if type_str:
        lines.append(build_value_type_xml(f"{indent}\t\t", type_str))
    else:
        lines.append(f"{indent}\t\t<Type>")
        lines.append(f"{indent}\t\t\t<v8:Type>xs:string</v8:Type>")
        lines.append(f"{indent}\t\t</Type>")

    lines.append(f"{indent}\t\t<PasswordMode>false</PasswordMode>")
    lines.append(f"{indent}\t\t<Format/>")
    lines.append(f"{indent}\t\t<EditFormat/>")
    lines.append(f"{indent}\t\t<ToolTip/>")
    lines.append(f"{indent}\t\t<MarkNegatives>false</MarkNegatives>")
    lines.append(f"{indent}\t\t<Mask/>")
    lines.append(f"{indent}\t\t<MultiLine>false</MultiLine>")
    lines.append(f"{indent}\t\t<ExtendedEdit>false</ExtendedEdit>")
    lines.append(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    lines.append(f'{indent}\t\t<MaxValue xsi:nil="true"/>')

    # InformationRegister: FillFromFillingValue, FillValue
    if register_type == "InformationRegister":
        fill_from = "true" if "master" in parsed["flags"] else "false"
        lines.append(f"{indent}\t\t<FillFromFillingValue>{fill_from}</FillFromFillingValue>")
        lines.append(f'{indent}\t\t<FillValue xsi:nil="true"/>')

    fill_checking = "DontCheck"
    if "req" in parsed["flags"]:
        fill_checking = "ShowError"
    lines.append(f"{indent}\t\t<FillChecking>{fill_checking}</FillChecking>")

    lines.append(f"{indent}\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>")
    lines.append(f"{indent}\t\t<ChoiceParameterLinks/>")
    lines.append(f"{indent}\t\t<ChoiceParameters/>")
    lines.append(f"{indent}\t\t<QuickChoice>Auto</QuickChoice>")
    lines.append(f"{indent}\t\t<CreateOnInput>Auto</CreateOnInput>")
    lines.append(f"{indent}\t\t<ChoiceForm/>")
    lines.append(f"{indent}\t\t<LinkByType/>")
    lines.append(f"{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>")

    # InformationRegister: Master, MainFilter, DenyIncompleteValues
    if register_type == "InformationRegister":
        master = "true" if "master" in parsed["flags"] else "false"
        main_filter = "true" if "mainfilter" in parsed["flags"] else "false"
        deny_incomplete = "true" if "denyincomplete" in parsed["flags"] else "false"
        lines.append(f"{indent}\t\t<Master>{master}</Master>")
        lines.append(f"{indent}\t\t<MainFilter>{main_filter}</MainFilter>")
        lines.append(f"{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>")

    # AccumulationRegister: DenyIncompleteValues
    if register_type == "AccumulationRegister":
        deny_incomplete = "true" if "denyincomplete" in parsed["flags"] else "false"
        lines.append(f"{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>")

    indexing = "DontIndex"
    if "index" in parsed["flags"]:
        indexing = "Index"
    lines.append(f"{indent}\t\t<Indexing>{indexing}</Indexing>")

    lines.append(f"{indent}\t\t<FullTextSearch>Use</FullTextSearch>")

    # AccumulationRegister: UseInTotals
    if register_type == "AccumulationRegister":
        use_in_totals = "false" if "nouseintotals" in parsed["flags"] else "true"
        lines.append(f"{indent}\t\t<UseInTotals>{use_in_totals}</UseInTotals>")

    # InformationRegister: DataHistory
    if register_type == "InformationRegister":
        lines.append(f"{indent}\t\t<DataHistory>Use</DataHistory>")

    lines.append(f"{indent}\t</Properties>")
    lines.append(f"{indent}</Dimension>")
    return "\r\n".join(lines)


def build_resource_fragment(parsed, register_type, indent):
    """Build XML fragment string for a Resource element."""
    if not register_type:
        register_type = obj_type
    uid = new_uuid()
    lines = []

    lines.append(f'{indent}<Resource uuid="{uid}">')
    lines.append(f"{indent}\t<Properties>")
    lines.append(f"{indent}\t\t<Name>{esc_xml(parsed['name'])}</Name>")
    lines.append(build_mltext_xml(f"{indent}\t\t", "Synonym", parsed["synonym"]))
    lines.append(f"{indent}\t\t<Comment/>")

    type_str = parsed["type"]
    if type_str:
        lines.append(build_value_type_xml(f"{indent}\t\t", type_str))
    else:
        # Default: Number(15,2)
        lines.append(f"{indent}\t\t<Type>")
        lines.append(f"{indent}\t\t\t<v8:Type>xs:decimal</v8:Type>")
        lines.append(f"{indent}\t\t\t<v8:NumberQualifiers>")
        lines.append(f"{indent}\t\t\t\t<v8:Digits>15</v8:Digits>")
        lines.append(f"{indent}\t\t\t\t<v8:FractionDigits>2</v8:FractionDigits>")
        lines.append(f"{indent}\t\t\t\t<v8:AllowedSign>Any</v8:AllowedSign>")
        lines.append(f"{indent}\t\t\t</v8:NumberQualifiers>")
        lines.append(f"{indent}\t\t</Type>")

    lines.append(f"{indent}\t\t<PasswordMode>false</PasswordMode>")
    lines.append(f"{indent}\t\t<Format/>")
    lines.append(f"{indent}\t\t<EditFormat/>")
    lines.append(f"{indent}\t\t<ToolTip/>")
    lines.append(f"{indent}\t\t<MarkNegatives>false</MarkNegatives>")
    lines.append(f"{indent}\t\t<Mask/>")
    lines.append(f"{indent}\t\t<MultiLine>false</MultiLine>")
    lines.append(f"{indent}\t\t<ExtendedEdit>false</ExtendedEdit>")
    lines.append(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    lines.append(f'{indent}\t\t<MaxValue xsi:nil="true"/>')

    # InformationRegister: FillFromFillingValue, FillValue
    if register_type == "InformationRegister":
        lines.append(f"{indent}\t\t<FillFromFillingValue>false</FillFromFillingValue>")
        lines.append(f'{indent}\t\t<FillValue xsi:nil="true"/>')

    fill_checking = "DontCheck"
    if "req" in parsed["flags"]:
        fill_checking = "ShowError"
    lines.append(f"{indent}\t\t<FillChecking>{fill_checking}</FillChecking>")

    lines.append(f"{indent}\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>")
    lines.append(f"{indent}\t\t<ChoiceParameterLinks/>")
    lines.append(f"{indent}\t\t<ChoiceParameters/>")
    lines.append(f"{indent}\t\t<QuickChoice>Auto</QuickChoice>")
    lines.append(f"{indent}\t\t<CreateOnInput>Auto</CreateOnInput>")
    lines.append(f"{indent}\t\t<ChoiceForm/>")
    lines.append(f"{indent}\t\t<LinkByType/>")
    lines.append(f"{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>")

    # InformationRegister: Indexing, FullTextSearch, DataHistory
    if register_type == "InformationRegister":
        lines.append(f"{indent}\t\t<Indexing>DontIndex</Indexing>")
        lines.append(f"{indent}\t\t<FullTextSearch>Use</FullTextSearch>")
        lines.append(f"{indent}\t\t<DataHistory>Use</DataHistory>")

    # AccumulationRegister: FullTextSearch
    if register_type == "AccumulationRegister":
        lines.append(f"{indent}\t\t<FullTextSearch>Use</FullTextSearch>")

    lines.append(f"{indent}\t</Properties>")
    lines.append(f"{indent}</Resource>")
    return "\r\n".join(lines)


def build_enum_value_fragment(parsed, indent):
    """Build XML fragment string for an EnumValue element."""
    uid = new_uuid()
    lines = []
    lines.append(f'{indent}<EnumValue uuid="{uid}">')
    lines.append(f"{indent}\t<Properties>")
    lines.append(f"{indent}\t\t<Name>{esc_xml(parsed['name'])}</Name>")
    lines.append(build_mltext_xml(f"{indent}\t\t", "Synonym", parsed["synonym"]))
    lines.append(f"{indent}\t\t<Comment/>")
    lines.append(f"{indent}\t</Properties>")
    lines.append(f"{indent}</EnumValue>")
    return "\r\n".join(lines)


def build_column_fragment(col_def, indent):
    """Build XML fragment string for a Column element."""
    uid = new_uuid()
    name = ""
    synonym = ""
    indexing = "DontIndex"
    references = []

    if isinstance(col_def, str):
        name = col_def
        synonym = split_camel_case(name)
    else:
        name = str(col_def.get("name", ""))
        synonym = str(col_def.get("synonym", "")) if col_def.get("synonym") else split_camel_case(name)
        if col_def.get("indexing"):
            indexing = normalize_enum_value("Indexing", str(col_def["indexing"]))
        if col_def.get("references"):
            references = list(col_def["references"])

    lines = []
    lines.append(f'{indent}<Column uuid="{uid}">')
    lines.append(f"{indent}\t<Properties>")
    lines.append(f"{indent}\t\t<Name>{esc_xml(name)}</Name>")
    lines.append(build_mltext_xml(f"{indent}\t\t", "Synonym", synonym))
    lines.append(f"{indent}\t\t<Comment/>")
    lines.append(f"{indent}\t\t<Indexing>{indexing}</Indexing>")
    if references:
        lines.append(f"{indent}\t\t<References>")
        for ref in references:
            lines.append(f'{indent}\t\t\t<xr:Item xsi:type="xr:MDObjectRef">{ref}</xr:Item>')
        lines.append(f"{indent}\t\t</References>")
    else:
        lines.append(f"{indent}\t\t<References/>")
    lines.append(f"{indent}\t</Properties>")
    lines.append(f"{indent}</Column>")
    return "\r\n".join(lines)


def build_simple_child_fragment(tag_name, name, indent):
    """Build XML fragment for Form, Template, Command -- just a name wrapper."""
    uid = new_uuid()
    synonym = split_camel_case(name)
    lines = []
    lines.append(f'{indent}<{tag_name} uuid="{uid}">')
    lines.append(f"{indent}\t<Properties>")
    lines.append(f"{indent}\t\t<Name>{esc_xml(name)}</Name>")
    lines.append(build_mltext_xml(f"{indent}\t\t", "Synonym", synonym))
    lines.append(f"{indent}\t\t<Comment/>")
    # Forms get additional properties
    if tag_name == "Form":
        lines.append(f"{indent}\t\t<FormType>Ordinary</FormType>")
        lines.append(f"{indent}\t\t<IncludeHelpInContents>false</IncludeHelpInContents>")
        lines.append(f"{indent}\t\t<UsePurposes/>")
    if tag_name == "Template":
        lines.append(f"{indent}\t\t<TemplateType>SpreadsheetDocument</TemplateType>")
    if tag_name == "Command":
        lines.append(f"{indent}\t\t<Group>FormNavigationPanelGoTo</Group>")
        lines.append(f"{indent}\t\t<Representation>Auto</Representation>")
        lines.append(f"{indent}\t\t<ToolTip/>")
        lines.append(f"{indent}\t\t<Picture/>")
        lines.append(f"{indent}\t\t<Shortcut/>")
    lines.append(f"{indent}\t</Properties>")
    lines.append(f"{indent}</{tag_name}>")
    return "\r\n".join(lines)


# ============================================================
# Name uniqueness check
# ============================================================


def get_all_child_names():
    """Get dict of all child element names -> element localname."""
    names = {}
    if child_objects_el is None:
        return names
    for child in child_objects_el:
        props_el = None
        for gc in child:
            if localname(gc) == "Properties":
                props_el = gc
                break
        if props_el is None:
            continue
        for gc in props_el:
            if localname(gc) == "Name":
                n = (gc.text or "").strip()
                if n:
                    names[n] = localname(child)
                break
    return names


# ============================================================
# Context and allowed child types
# ============================================================

valid_child_types = {
    "Catalog": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "Document": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "ExchangePlan": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "ChartOfAccounts": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "ChartOfCharacteristicTypes": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "ChartOfCalculationTypes": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "BusinessProcess": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "Task": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "Report": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "DataProcessor": ["attributes", "tabularSections", "forms", "templates", "commands"],
    "Enum": ["enumValues", "forms", "templates", "commands"],
    "InformationRegister": ["dimensions", "resources", "attributes", "forms", "templates", "commands"],
    "AccumulationRegister": ["dimensions", "resources", "attributes", "forms", "templates", "commands"],
    "AccountingRegister": ["dimensions", "resources", "attributes", "forms", "templates", "commands"],
    "CalculationRegister": ["dimensions", "resources", "attributes", "forms", "templates", "commands"],
    "DocumentJournal": ["columns", "forms", "templates", "commands"],
    "Constant": ["forms"],
}

# Canonical child order in ChildObjects
child_order = [
    "Resource", "Dimension", "Attribute", "TabularSection",
    "AccountingFlag", "ExtDimensionAccountingFlag",
    "EnumValue", "Column", "AddressingAttribute", "Recalculation",
    "Form", "Template", "Command",
]

# Map from DSL child type to XML element name
child_type_to_xml_tag = {
    "attributes": "Attribute",
    "tabularSections": "TabularSection",
    "dimensions": "Dimension",
    "resources": "Resource",
    "enumValues": "EnumValue",
    "columns": "Column",
    "forms": "Form",
    "templates": "Template",
    "commands": "Command",
}

# ============================================================
# DSL key normalization
# ============================================================


def resolve_operation_key(key):
    k = key.lower().strip()
    return operation_synonyms.get(k)


def resolve_child_type_key(key):
    k = key.lower().strip()
    return child_type_synonyms.get(k)


# ============================================================
# Inline mode converter
# ============================================================


def split_by_comma_outside_parens(s):
    result = []
    depth = 0
    current = ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            result.append(current)
            current = ""
        else:
            current += ch
    if current:
        result.append(current)
    return result


def convert_inline_to_definition(operation, value):
    """Convert inline -Operation + -Value to a definition dict."""
    op_parts = operation.split("-", 1)
    op = op_parts[0]       # add, remove, modify, set
    target = op_parts[1]   # attribute, ts, owner, owners, property, etc.

    # Complex property targets
    complex_target_map = {
        "owner": "Owners", "owners": "Owners",
        "registerRecord": "RegisterRecords", "registerRecords": "RegisterRecords",
        "basedOn": "BasedOn",
        "inputByString": "InputByString",
        "dataLockField": "DataLockFields", "dataLockFields": "DataLockFields",
        "registeredDocument": "RegisteredDocuments", "registeredDocuments": "RegisteredDocuments",
    }

    if target in complex_target_map:
        prop_name = complex_target_map[target]
        values = [v.strip() for v in value.split(";;") if v.strip()]
        # For InputByString, auto-prefix with MetaType.Name.
        if prop_name == "InputByString":
            prefix = f"{obj_type}.{obj_name}."
            meta_types = (
                "Catalog", "Document", "InformationRegister", "AccumulationRegister",
                "AccountingRegister", "CalculationRegister", "ChartOfCharacteristicTypes",
                "ChartOfCalculationTypes", "ChartOfAccounts", "ExchangePlan",
                "BusinessProcess", "Task", "Enum", "Report", "DataProcessor",
            )
            new_values = []
            for v in values:
                if "." not in v:
                    new_values.append(f"{prefix}{v}")
                elif not re.match(r"^(" + "|".join(meta_types) + r")\.", v):
                    new_values.append(f"{prefix}{v}")
                else:
                    new_values.append(v)
            values = new_values
        complex_action = "set" if op == "set" else op
        return {"_complex": [{"action": complex_action, "property": prop_name, "values": values}]}

    # Предопределённые (Ext/Predefined.xml) — отдельный файл; строим { <op>: { predefined: [...] } }.
    if target == "predefined":
        items = [v.strip() for v in value.split(";;") if v.strip()]
        return {op: {"predefined": items}}

    # TS attribute operations: dot notation "TSName.AttrDef"
    if target == "ts-attribute":
        items = [v.strip() for v in value.split(";;") if v.strip()]
        # Group by TS name
        ts_groups = {}
        ts_order = []
        for item in items:
            dot_idx = item.find(".")
            if dot_idx <= 0:
                warn(f"Invalid ts-attribute format (expected TSName.AttrDef): {item}")
                continue
            ts_name = item[:dot_idx].strip()
            rest = item[dot_idx + 1:].strip()
            if ts_name not in ts_groups:
                ts_groups[ts_name] = []
                ts_order.append(ts_name)
            ts_groups[ts_name].append(rest)

        # Build: { modify: { tabularSections: { TSName: { add/remove/modify: ... } } } }
        ts_mod_obj = {}
        for ts_name in ts_order:
            ts_changes = {}
            if op == "add":
                ts_changes["add"] = ts_groups[ts_name]
            elif op == "remove":
                ts_changes["remove"] = ts_groups[ts_name]
            elif op == "modify":
                attr_mod_obj = {}
                for elem_def in ts_groups[ts_name]:
                    colon_idx = elem_def.find(":")
                    if colon_idx <= 0:
                        warn(f"Invalid modify format (expected Name: key=val): {elem_def}")
                        continue
                    elem_name = elem_def[:colon_idx].strip()
                    changes_part = elem_def[colon_idx + 1:].strip()
                    changes_obj = {}
                    change_pairs = split_by_comma_outside_parens(changes_part)
                    for cp in change_pairs:
                        cp = cp.strip()
                        eq_idx = cp.find("=")
                        if eq_idx > 0:
                            ck = cp[:eq_idx].strip()
                            cv = cp[eq_idx + 1:].strip()
                            changes_obj[ck] = cv
                    attr_mod_obj[elem_name] = changes_obj
                ts_changes["modify"] = attr_mod_obj
            ts_mod_obj[ts_name] = ts_changes

        return {"modify": {"tabularSections": ts_mod_obj}}

    # Target -> JSON DSL child type
    target_map = {
        "attribute": "attributes",
        "ts": "tabularSections",
        "dimension": "dimensions",
        "resource": "resources",
        "enumValue": "enumValues",
        "column": "columns",
        "form": "forms",
        "template": "templates",
        "command": "commands",
        "property": "properties",
    }

    child_type = target_map.get(target)
    if not child_type:
        die(f"Unknown inline target: {target}")

    definition = {}

    if op == "add":
        items = []
        if child_type == "tabularSections":
            # TS format: "TSName: attr1_shorthand, attr2_shorthand, ..."
            ts_values = [v.strip() for v in value.split(";;") if v.strip()]
            for ts_val in ts_values:
                colon_idx = ts_val.find(":")
                if colon_idx > 0:
                    ts_name = ts_val[:colon_idx].strip()
                    attrs_part = ts_val[colon_idx + 1:].strip()
                    # Split attrs by comma (paren-aware), reassemble if part doesn't start with "Name:"
                    raw_parts = split_by_comma_outside_parens(attrs_part)
                    attr_strs = []
                    current = ""
                    for rp in raw_parts:
                        rp = rp.strip()
                        if current and re.match(r"^[А-Яа-яЁёA-Za-z_]\w*\s*:", rp):
                            attr_strs.append(current)
                            current = rp
                        elif current:
                            current += f", {rp}"
                        else:
                            current = rp
                    if current:
                        attr_strs.append(current)
                    items.append({"name": ts_name, "attrs": attr_strs})
                else:
                    # Just a name, no attrs
                    items.append(ts_val)
        else:
            # Batch split by ;;
            items = [v.strip() for v in value.split(";;") if v.strip()]
        definition["add"] = {child_type: items}

    elif op == "remove":
        items = [v.strip() for v in value.split(";;") if v.strip()]
        definition["remove"] = {child_type: items}

    elif op == "modify":
        if child_type == "properties":
            # "CodeLength=11 ;; DescriptionLength=150"
            kv_pairs = [v.strip() for v in value.split(";;") if v.strip()]
            props_obj = {}
            for kv in kv_pairs:
                eq_idx = kv.find("=")
                if eq_idx > 0:
                    k = kv[:eq_idx].strip()
                    v = kv[eq_idx + 1:].strip()
                    props_obj[k] = v
                else:
                    warn(f"Invalid property format (expected Key=Value): {kv}")
            definition["modify"] = {"properties": props_obj}
        else:
            # "ElementName: key=val, key=val ;; Element2: key=val"
            elem_defs = [v.strip() for v in value.split(";;") if v.strip()]
            child_mod_obj = {}
            for elem_def in elem_defs:
                colon_idx = elem_def.find(":")
                if colon_idx <= 0:
                    warn(f"Invalid modify format (expected Name: key=val): {elem_def}")
                    continue
                elem_name = elem_def[:colon_idx].strip()
                changes_part = elem_def[colon_idx + 1:].strip()
                changes_obj = {}
                change_pairs = split_by_comma_outside_parens(changes_part)
                for cp in change_pairs:
                    cp = cp.strip()
                    eq_idx = cp.find("=")
                    if eq_idx > 0:
                        ck = cp[:eq_idx].strip()
                        cv = cp[eq_idx + 1:].strip()
                        changes_obj[ck] = cv
                child_mod_obj[elem_name] = changes_obj
            definition["modify"] = {child_type: child_mod_obj}

    return definition


# ============================================================
# ADD operations
# ============================================================


def find_insertion_point(xml_tag, parsed):
    """Find reference node for insertion. Returns element or None (meaning append)."""
    if child_objects_el is None:
        return None

    # Positional: after/before
    after_name = parsed.get("after", "")
    before_name = parsed.get("before", "")

    if after_name:
        after_el = find_element_by_name(child_objects_el, xml_tag, after_name)
        if after_el is not None:
            # Insert after = insert before the next element sibling
            nxt = after_el.getnext()
            while nxt is not None and not isinstance(nxt.tag, str):
                nxt = nxt.getnext()
            if nxt is not None and localname(nxt) == xml_tag:
                return nxt
            return None  # append
        else:
            warn(f"after='{after_name}': element '{after_name}' not found in {xml_tag}, appending")

    if before_name:
        before_el = find_element_by_name(child_objects_el, xml_tag, before_name)
        if before_el is not None:
            return before_el
        warn(f"before='{before_name}': element '{before_name}' not found in {xml_tag}, appending")

    # Default: after last element of this type, or in canonical position
    last_of_type = find_last_element_of_type(child_objects_el, xml_tag)
    if last_of_type is not None:
        nxt = last_of_type.getnext()
        while nxt is not None and not isinstance(nxt.tag, str):
            nxt = nxt.getnext()
        return nxt  # None means append (correct: after last of type)

    # No elements of this type yet -- find canonical position
    if xml_tag in child_order:
        tag_idx = child_order.index(xml_tag)
    else:
        return None

    # Find first element of any type that comes AFTER in the canonical order
    for i in range(tag_idx + 1, len(child_order)):
        next_tag = child_order[i]
        first_of_next = find_first_element_of_type(child_objects_el, next_tag)
        if first_of_next is not None:
            return first_of_next

    return None  # append at end


def process_add(add_def):
    global add_count

    for raw_key, items in add_def.items():
        if raw_key in ('predefined', 'предопределенные', 'предопределённые'):
            add_predefined_items(items)
            continue
        child_type = resolve_child_type_key(raw_key)

        if not child_type:
            warn(f"Unknown add child type: {raw_key}")
            continue

        # Validate allowed
        allowed = valid_child_types.get(obj_type)
        if allowed and child_type not in allowed:
            warn(f"{child_type} not allowed for {obj_type}, skipping")
            continue

        xml_tag = child_type_to_xml_tag.get(child_type)
        if not xml_tag:
            warn(f"No XML tag mapping for {child_type}")
            continue

        ensure_child_objects_open()
        indent = get_child_indent(child_objects_el)
        existing_names = get_all_child_names()

        if child_type == "attributes":
            for item in items:
                parsed = parse_attribute_shorthand(item)
                if parsed["name"] in existing_names:
                    warn(f"Attribute '{parsed['name']}' already exists, skipping")
                    continue
                context = get_attribute_context()
                fragment_xml = build_attribute_fragment(parsed, context, indent)
                nodes = import_fragment(fragment_xml)
                ref_node = find_insertion_point("Attribute", parsed)
                for node in nodes:
                    insert_before_element(child_objects_el, node, ref_node, indent)
                info(f"Added attribute: {parsed['name']}")
                add_count += 1
                existing_names[parsed["name"]] = "Attribute"

        elif child_type == "tabularSections":
            for item in items:
                if isinstance(item, str):
                    ts_name = item
                    ts_def = {"name": item}
                else:
                    ts_name = str(item.get("name", ""))
                    ts_def = item
                if ts_name in existing_names:
                    warn(f"TabularSection '{ts_name}' already exists, skipping")
                    continue
                fragment_xml = build_tabular_section_fragment(ts_def, indent)
                nodes = import_fragment(fragment_xml)
                ref_node = find_insertion_point("TabularSection", {"after": "", "before": ""})
                for node in nodes:
                    insert_before_element(child_objects_el, node, ref_node, indent)
                info(f"Added tabular section: {ts_name}")
                add_count += 1
                existing_names[ts_name] = "TabularSection"

        elif child_type == "dimensions":
            for item in items:
                parsed = parse_attribute_shorthand(item)
                if parsed["name"] in existing_names:
                    warn(f"Dimension '{parsed['name']}' already exists, skipping")
                    continue
                fragment_xml = build_dimension_fragment(parsed, obj_type, indent)
                nodes = import_fragment(fragment_xml)
                ref_node = find_insertion_point("Dimension", parsed)
                for node in nodes:
                    insert_before_element(child_objects_el, node, ref_node, indent)
                info(f"Added dimension: {parsed['name']}")
                add_count += 1
                existing_names[parsed["name"]] = "Dimension"

        elif child_type == "resources":
            for item in items:
                parsed = parse_attribute_shorthand(item)
                if parsed["name"] in existing_names:
                    warn(f"Resource '{parsed['name']}' already exists, skipping")
                    continue
                fragment_xml = build_resource_fragment(parsed, obj_type, indent)
                nodes = import_fragment(fragment_xml)
                ref_node = find_insertion_point("Resource", parsed)
                for node in nodes:
                    insert_before_element(child_objects_el, node, ref_node, indent)
                info(f"Added resource: {parsed['name']}")
                add_count += 1
                existing_names[parsed["name"]] = "Resource"

        elif child_type == "enumValues":
            for item in items:
                parsed = parse_enum_value_shorthand(item)
                if parsed["name"] in existing_names:
                    warn(f"EnumValue '{parsed['name']}' already exists, skipping")
                    continue
                fragment_xml = build_enum_value_fragment(parsed, indent)
                nodes = import_fragment(fragment_xml)
                ref_node = find_insertion_point("EnumValue", parsed)
                for node in nodes:
                    insert_before_element(child_objects_el, node, ref_node, indent)
                info(f"Added enum value: {parsed['name']}")
                add_count += 1
                existing_names[parsed["name"]] = "EnumValue"

        elif child_type == "columns":
            for item in items:
                if isinstance(item, str):
                    col_name = item
                else:
                    col_name = str(item.get("name", ""))
                if col_name in existing_names:
                    warn(f"Column '{col_name}' already exists, skipping")
                    continue
                fragment_xml = build_column_fragment(item, indent)
                nodes = import_fragment(fragment_xml)
                ref_node = find_insertion_point("Column", {"after": "", "before": ""})
                for node in nodes:
                    insert_before_element(child_objects_el, node, ref_node, indent)
                info(f"Added column: {col_name}")
                add_count += 1
                existing_names[col_name] = "Column"

        elif child_type in ("forms", "templates", "commands"):
            tag_map = {"forms": "Form", "templates": "Template", "commands": "Command"}
            tag = tag_map[child_type]
            for item in items:
                if isinstance(item, str):
                    item_name = item
                else:
                    item_name = str(item.get("name", ""))
                if item_name in existing_names:
                    warn(f"{tag} '{item_name}' already exists, skipping")
                    continue
                fragment_xml = build_simple_child_fragment(tag, item_name, indent)
                nodes = import_fragment(fragment_xml)
                ref_node = find_insertion_point(tag, {"after": "", "before": ""})
                for node in nodes:
                    insert_before_element(child_objects_el, node, ref_node, indent)
                info(f"Added {tag.lower()}: {item_name}")
                add_count += 1
                existing_names[item_name] = tag


# ============================================================
# REMOVE operations
# ============================================================


def process_remove(remove_def):
    global remove_count

    for raw_key, names in remove_def.items():
        child_type = resolve_child_type_key(raw_key)

        if not child_type:
            warn(f"Unknown remove child type: {raw_key}")
            continue
        if child_type == "properties":
            warn("Cannot remove properties -- use modify instead")
            continue

        xml_tag = child_type_to_xml_tag.get(child_type)
        if not xml_tag or child_objects_el is None:
            warn(f"No ChildObjects or unknown tag for {child_type}")
            continue

        for name in names:
            name_str = str(name)
            el = find_element_by_name(child_objects_el, xml_tag, name_str)
            if el is None:
                warn(f"{xml_tag} '{name_str}' not found, skipping remove")
                continue
            remove_node_with_whitespace(el)
            info(f"Removed {xml_tag.lower()}: {name_str}")
            remove_count += 1

    # Collapse if empty
    collapse_child_objects_if_empty()


# ============================================================
# MODIFY operations
# ============================================================


def modify_properties(props_def):
    global modify_count

    for prop_name, prop_value in props_def.items():
        # Find the property element in Properties
        prop_el = None
        for child in properties_el:
            if localname(child) == prop_name:
                prop_el = child
                break

        if prop_el is None:
            # create-if-missing: известное свойство создаём (порядок 1С терпит); неизвестное → ошибка (опечатка)
            if prop_name not in known_object_props:
                print(f"meta-edit: modify-property: неизвестное свойство '{prop_name}' — нет такого свойства объекта (опечатка?)", file=sys.stderr)
                sys.exit(1)
            new_nodes = import_fragment(f"<{prop_name}/>")
            if new_nodes:
                insert_property_in_order(properties_el, new_nodes[0], None, prop_name)
                prop_el = new_nodes[0]
            else:
                warn(f"Property '{prop_name}': could not create element")
                continue

        # Complex property: Owners, RegisterRecords, BasedOn, InputByString
        if prop_name in complex_property_map:
            values_list = []
            if isinstance(prop_value, list):
                values_list = [str(v) for v in prop_value]
            else:
                values_list = [v.strip() for v in str(prop_value).split(";;") if v.strip()]
            set_complex_property(prop_name, values_list)
            continue

        # Handle boolean values
        value_str = str(prop_value)
        if isinstance(prop_value, bool):
            value_str = "true" if prop_value else "false"

        # Structural value-type property (корневой <Type> у Константы, ПВХ) —
        # перестроить дескриптор типа через build_value_type_xml (не расплющивать в скаляр)
        if prop_name == "Type":
            type_indent = get_child_indent(properties_el)
            new_type_xml = build_value_type_xml(type_indent, value_str)
            new_type_nodes = import_fragment(new_type_xml)
            if new_type_nodes:
                type_idx = list(properties_el).index(prop_el)
                new_type_nodes[0].tail = prop_el.tail
                properties_el.insert(type_idx + 1, new_type_nodes[0])
                remove_node_with_whitespace(prop_el)
                info(f"Modified property: Type = {value_str}")
                modify_count += 1
            continue

        # Guard: не расплющивать структурное свойство (с дочерними узлами) в скалярный текст —
        # это молча повредит XML. Завершаем ошибкой ДО записи файла.
        if len(list(prop_el)) > 0:
            print(f"meta-edit: modify-property: свойство '{prop_name}' структурное (содержит дочерние узлы) — установка скалярного текста повредит XML; не поддерживается", file=sys.stderr)
            sys.exit(1)

        # Set inner text — clear children first, set text
        for ch in list(prop_el):
            prop_el.remove(ch)
        prop_el.text = value_str
        info(f"Modified property: {prop_name} = {value_str}")
        modify_count += 1


def modify_child_elements(modify_def, child_type):
    global add_count, remove_count, modify_count, child_objects_el

    xml_tag = child_type_to_xml_tag.get(child_type)
    if not xml_tag or child_objects_el is None:
        warn(f"No ChildObjects or unknown tag for {child_type}")
        return

    for elem_name, changes in modify_def.items():
        el = find_element_by_name(child_objects_el, xml_tag, elem_name)
        if el is None:
            warn(f"{xml_tag} '{elem_name}' not found for modify")
            continue

        # Find Properties inside the element
        props_el = None
        for gc in el:
            if localname(gc) == "Properties":
                props_el = gc
                break
        if props_el is None:
            warn(f"{xml_tag} '{elem_name}': no Properties element found")
            continue

        for change_prop, change_value in changes.items():
            # TS child attribute operations (add/remove/modify attrs inside a TabularSection)
            if xml_tag == "TabularSection" and change_prop in ("add", "remove", "modify"):
                # Find ChildObjects inside this TS element
                ts_child_obj_el = None
                for gc in el:
                    if localname(gc) == "ChildObjects":
                        ts_child_obj_el = gc
                        break

                if change_prop == "add":
                    if ts_child_obj_el is None:
                        warn(f"TS '{elem_name}' has no ChildObjects element, cannot add attributes")
                        continue
                    # Ensure ChildObjects is open (not self-closing empty)
                    has_ts_child_elements = any(True for _ in ts_child_obj_el)
                    if not has_ts_child_elements:
                        ts_co_indent = get_child_indent(el)
                        ts_child_obj_el.text = "\r\n" + ts_co_indent
                    attr_defs = change_value if isinstance(change_value, list) else [change_value]
                    for attr_def in attr_defs:
                        parsed = parse_attribute_shorthand(attr_def)
                        existing = find_element_by_name(ts_child_obj_el, "Attribute", parsed["name"])
                        if existing is not None:
                            warn(f"Attribute '{parsed['name']}' already exists in TS '{elem_name}', skipping")
                            continue
                        ts_attr_indent = get_child_indent(ts_child_obj_el)
                        ts_attr_context = "processor-tabular" if obj_type in ("DataProcessor", "Report", "ExternalDataProcessor", "ExternalReport") else "tabular"
                        fragment_xml = build_attribute_fragment(parsed, ts_attr_context, ts_attr_indent)
                        nodes = import_fragment(fragment_xml)
                        saved_co = child_objects_el
                        child_objects_el = ts_child_obj_el
                        ref_node = find_insertion_point("Attribute", parsed)
                        child_objects_el = saved_co
                        for node in nodes:
                            insert_before_element(ts_child_obj_el, node, ref_node, ts_attr_indent)
                        info(f"Added attribute to TS '{elem_name}': {parsed['name']}")
                        add_count += 1

                elif change_prop == "remove":
                    if ts_child_obj_el is None:
                        warn(f"TS '{elem_name}' has no ChildObjects, cannot remove attributes")
                        continue
                    attr_names = change_value if isinstance(change_value, list) else [change_value]
                    for attr_name in attr_names:
                        attr_el = find_element_by_name(ts_child_obj_el, "Attribute", str(attr_name))
                        if attr_el is None:
                            warn(f"Attribute '{attr_name}' not found in TS '{elem_name}', skipping")
                            continue
                        remove_node_with_whitespace(attr_el)
                        info(f"Removed attribute from TS '{elem_name}': {attr_name}")
                        remove_count += 1

                elif change_prop == "modify":
                    if ts_child_obj_el is None:
                        warn(f"TS '{elem_name}' has no ChildObjects, cannot modify attributes")
                        continue
                    # Temporarily swap childObjectsEl and recurse
                    saved_child_obj_el = child_objects_el
                    child_objects_el = ts_child_obj_el
                    modify_child_elements(change_value, "attributes")
                    child_objects_el = saved_child_obj_el

                continue  # Skip normal property modification

            if change_prop == "name":
                # Rename
                name_el = None
                for gc in props_el:
                    if localname(gc) == "Name":
                        name_el = gc
                        break
                if name_el is not None:
                    old_name = (name_el.text or "").strip()
                    new_name = str(change_value)
                    name_el.text = new_name

                    # Update Synonym if it was auto-generated
                    old_synonym = split_camel_case(old_name)
                    syn_el = None
                    for gc in props_el:
                        if localname(gc) == "Synonym":
                            syn_el = gc
                            break
                    if syn_el is not None:
                        # Check if current synonym matches auto-generated from old name
                        current_syn = ""
                        for item_el in syn_el:
                            if localname(item_el) == "item":
                                for gc in item_el:
                                    if localname(gc) == "content":
                                        current_syn = (gc.text or "").strip()
                        if current_syn == old_synonym or not current_syn:
                            new_synonym = split_camel_case(new_name)
                            syn_indent = get_child_indent(props_el)
                            new_syn_xml = build_mltext_xml(syn_indent, "Synonym", new_synonym)
                            new_syn_nodes = import_fragment(new_syn_xml)
                            if new_syn_nodes:
                                # Insert new synonym after old, then remove old
                                syn_idx = list(props_el).index(syn_el)
                                new_syn_nodes[0].tail = syn_el.tail
                                props_el.insert(syn_idx + 1, new_syn_nodes[0])
                                remove_node_with_whitespace(syn_el)

                    info(f"Renamed {xml_tag}: {old_name} -> {new_name}")
                    modify_count += 1

            elif change_prop == "type":
                # Change type
                type_el = None
                for gc in props_el:
                    if localname(gc) == "Type":
                        type_el = gc
                        break
                new_type_str = str(change_value)
                type_indent = get_child_indent(props_el)
                new_type_xml = build_value_type_xml(type_indent, new_type_str)
                new_type_nodes = import_fragment(new_type_xml)

                if type_el is not None and new_type_nodes:
                    type_idx = list(props_el).index(type_el)
                    new_type_nodes[0].tail = type_el.tail
                    props_el.insert(type_idx + 1, new_type_nodes[0])
                    remove_node_with_whitespace(type_el)
                elif new_type_nodes:
                    # No existing Type -- insert after Comment
                    comment_el = None
                    for gc in props_el:
                        if localname(gc) == "Comment":
                            comment_el = gc
                            break
                    if comment_el is not None:
                        comment_idx = list(props_el).index(comment_el)
                        nxt = comment_el.getnext()
                        insert_before_element(props_el, new_type_nodes[0], nxt, type_indent)

                # Also update FillValue if present
                fill_val_el = None
                for gc in props_el:
                    if localname(gc) == "FillValue":
                        fill_val_el = gc
                        break
                if fill_val_el is not None:
                    fill_indent = get_child_indent(props_el)
                    new_fill_xml = build_fill_value_xml(fill_indent, new_type_str)
                    new_fill_nodes = import_fragment(new_fill_xml)
                    if new_fill_nodes:
                        fill_idx = list(props_el).index(fill_val_el)
                        new_fill_nodes[0].tail = fill_val_el.tail
                        props_el.insert(fill_idx + 1, new_fill_nodes[0])
                        remove_node_with_whitespace(fill_val_el)

                info(f"Changed type of {xml_tag} '{elem_name}': {new_type_str}")
                modify_count += 1

            elif change_prop == "synonym":
                syn_el = None
                for gc in props_el:
                    if localname(gc) == "Synonym":
                        syn_el = gc
                        break
                syn_indent = get_child_indent(props_el)
                new_syn_xml = build_mltext_xml(syn_indent, "Synonym", str(change_value))
                new_syn_nodes = import_fragment(new_syn_xml)
                if syn_el is not None and new_syn_nodes:
                    syn_idx = list(props_el).index(syn_el)
                    new_syn_nodes[0].tail = syn_el.tail
                    props_el.insert(syn_idx + 1, new_syn_nodes[0])
                    remove_node_with_whitespace(syn_el)
                info(f"Changed synonym of {xml_tag} '{elem_name}': {change_value}")
                modify_count += 1

            elif change_prop == "Format":
                if set_attr_property_element(props_el, "Format", build_mltext_xml(get_child_indent(props_el), "Format", str(change_value))):
                    info(f"Set {xml_tag} '{elem_name}'.Format")
                    modify_count += 1
            elif change_prop == "EditFormat":
                if set_attr_property_element(props_el, "EditFormat", build_mltext_xml(get_child_indent(props_el), "EditFormat", str(change_value))):
                    info(f"Set {xml_tag} '{elem_name}'.EditFormat")
                    modify_count += 1
            elif change_prop == "ToolTip":
                if set_attr_property_element(props_el, "ToolTip", build_mltext_xml(get_child_indent(props_el), "ToolTip", str(change_value))):
                    info(f"Set {xml_tag} '{elem_name}'.ToolTip")
                    modify_count += 1
            elif change_prop == "ChoiceForm":
                if set_attr_property_element(props_el, "ChoiceForm", f"<ChoiceForm>{esc_xml(str(change_value))}</ChoiceForm>"):
                    info(f"Set {xml_tag} '{elem_name}'.ChoiceForm")
                    modify_count += 1
            elif change_prop == "MinValue":
                if set_attr_property_element(props_el, "MinValue", build_min_max_value_xml("MinValue", change_value)):
                    info(f"Set {xml_tag} '{elem_name}'.MinValue")
                    modify_count += 1
            elif change_prop == "MaxValue":
                if set_attr_property_element(props_el, "MaxValue", build_min_max_value_xml("MaxValue", change_value)):
                    info(f"Set {xml_tag} '{elem_name}'.MaxValue")
                    modify_count += 1
            elif change_prop == "LinkByType":
                if set_attr_property_element(props_el, "LinkByType", build_link_by_type_xml(get_child_indent(props_el), change_value)):
                    info(f"Set {xml_tag} '{elem_name}'.LinkByType")
                    modify_count += 1
            elif change_prop == "ChoiceParameterLinks":
                if set_attr_property_element(props_el, "ChoiceParameterLinks", build_choice_parameter_links_xml(get_child_indent(props_el), change_value)):
                    info(f"Set {xml_tag} '{elem_name}'.ChoiceParameterLinks")
                    modify_count += 1
            elif change_prop == "ChoiceParameters":
                if set_attr_property_element(props_el, "ChoiceParameters", build_choice_parameters_xml(get_child_indent(props_el), change_value)):
                    info(f"Set {xml_tag} '{elem_name}'.ChoiceParameters")
                    modify_count += 1
            elif change_prop == "FillValue":
                if set_attr_property_element(props_el, "FillValue", build_fill_value_explicit_xml(get_attr_type_str_from_xml(props_el), change_value)):
                    info(f"Set {xml_tag} '{elem_name}'.FillValue")
                    modify_count += 1

            else:
                # Scalar property change (Indexing, FillChecking, Use, etc.)
                scalar_el = None
                for gc in props_el:
                    if localname(gc) == change_prop:
                        scalar_el = gc
                        break
                if scalar_el is not None:
                    value_str = str(change_value)
                    if isinstance(change_value, bool):
                        value_str = "true" if change_value else "false"
                    else:
                        value_str = normalize_enum_value(change_prop, value_str)
                    # Clear children and set text
                    for ch in list(scalar_el):
                        scalar_el.remove(ch)
                    scalar_el.text = value_str
                    info(f"Modified {xml_tag} '{elem_name}'.{change_prop} = {value_str}")
                    modify_count += 1
                else:
                    # create-if-missing: известное свойство создаём в позиции; неизвестное → ошибка (опечатка)
                    if change_prop not in known_child_props:
                        print(f"meta-edit: modify: неизвестное свойство '{change_prop}' у {xml_tag} '{elem_name}' (опечатка?)", file=sys.stderr)
                        sys.exit(1)
                    value_str = str(change_value)
                    if isinstance(change_value, bool):
                        value_str = "true" if change_value else "false"
                    else:
                        value_str = normalize_enum_value(change_prop, value_str)
                    new_nodes = import_fragment(f"<{change_prop}>{esc_xml(value_str)}</{change_prop}>")
                    if new_nodes:
                        insert_property_in_order(props_el, new_nodes[0], attr_prop_order, change_prop)
                        info(f"Created {xml_tag} '{elem_name}'.{change_prop} = {value_str}")
                        modify_count += 1


def process_modify(modify_def):
    for raw_key, value in modify_def.items():
        child_type = resolve_child_type_key(raw_key)

        if not child_type:
            warn(f"Unknown modify child type: {raw_key}")
            continue

        if child_type == "properties":
            modify_properties(value)
        else:
            modify_child_elements(value, child_type)


# ============================================================
# Complex property helpers
# ============================================================

complex_property_map = {
    "Owners": {"tag": "xr:Item", "attr": 'xsi:type="xr:MDObjectRef"'},
    "RegisterRecords": {"tag": "xr:Item", "attr": 'xsi:type="xr:MDObjectRef"'},
    "BasedOn": {"tag": "xr:Item", "attr": 'xsi:type="xr:MDObjectRef"'},
    "InputByString": {"tag": "xr:Field", "attr": None},
    "DataLockFields": {"tag": "xr:Field", "attr": None, "expand": True},
    "RegisteredDocuments": {"tag": "xr:Item", "attr": 'xsi:type="xr:MDObjectRef"'},
}

# Известные свойства объекта (union по корпусу acc+erp 8.3.24) — allowlist для modify-property.
# Известное отсутствующее свойство create-if-missing создаётся; неизвестное (опечатка) → ошибка.
known_object_props = {
    'ActionPeriod', 'ActionPeriodUse', 'Addressing', 'AutoOrderByCode', 'Autonumbering', 'AuxiliaryChoiceForm',
    'AuxiliaryFolderChoiceForm', 'AuxiliaryFolderForm', 'AuxiliaryForm', 'AuxiliaryListForm', 'AuxiliaryObjectForm',
    'AuxiliaryRecordForm', 'AuxiliarySettingsForm', 'BaseCalculationTypes', 'BasePeriod', 'BasedOn',
    'CharacteristicExtValues', 'Characteristics', 'ChartOfAccounts', 'ChartOfCalculationTypes', 'CheckUnique',
    'ChoiceDataGetModeOnInputByString', 'ChoiceFoldersAndItems', 'ChoiceForm', 'ChoiceHistoryOnInput', 'ChoiceMode',
    'ChoiceParameterLinks', 'ChoiceParameters', 'CodeAllowedLength', 'CodeLength', 'CodeMask', 'CodeSeries', 'CodeType',
    'Comment', 'Correspondence', 'CreateOnInput', 'CreateTaskInPrivilegedMode', 'CurrentPerformer', 'DataHistory',
    'DataLockControlMode', 'DataLockFields', 'DefaultChoiceForm', 'DefaultFolderChoiceForm', 'DefaultFolderForm',
    'DefaultForm', 'DefaultListForm', 'DefaultObjectForm', 'DefaultPresentation', 'DefaultRecordForm', 'DefaultSettingsForm',
    'DefaultVariantForm', 'DependenceOnCalculationTypes', 'DescriptionLength', 'DistributedInfoBase', 'EditFormat',
    'EditType', 'EnableTotalsSliceFirst', 'EnableTotalsSliceLast', 'EnableTotalsSplitting',
    'ExecuteAfterWriteDataHistoryVersionProcessing', 'Explanation', 'ExtDimensionTypes', 'ExtendedEdit',
    'ExtendedListPresentation', 'ExtendedObjectPresentation', 'ExtendedPresentation', 'ExtendedRecordPresentation',
    'FillChecking', 'FoldersOnTop', 'Format', 'FullTextSearch', 'FullTextSearchOnInputByString', 'Hierarchical',
    'HierarchyType', 'IncludeConfigurationExtensions', 'IncludeHelpInContents', 'InformationRegisterPeriodicity',
    'InputByString', 'LevelCount', 'LimitLevelCount', 'LinkByType', 'ListPresentation', 'MainAddressingAttribute',
    'MainDataCompositionSchema', 'MainFilterOnPeriod', 'MarkNegatives', 'Mask', 'MaxExtDimensionCount', 'MaxValue',
    'MinValue', 'MultiLine', 'Name', 'NumberAllowedLength', 'NumberLength', 'NumberPeriodicity', 'NumberType', 'Numerator',
    'ObjectPresentation', 'OrderLength', 'Owners', 'PasswordMode', 'PeriodAdjustmentLength', 'Periodicity',
    'PostInPrivilegedMode', 'Posting', 'PredefinedDataUpdate', 'QuickChoice', 'RealTimePosting', 'RecordPresentation',
    'RegisterRecords', 'RegisterRecordsDeletion', 'RegisterRecordsWritingOnPost', 'RegisterType', 'RegisteredDocuments',
    'Schedule', 'ScheduleDate', 'ScheduleValue', 'SearchStringModeOnInputByString', 'SequenceFilling', 'SettingsStorage',
    'StandardAttributes', 'StandardTabularSections', 'SubordinationUse', 'Synonym', 'Task', 'TaskNumberAutoPrefix',
    'ToolTip', 'Type', 'UnpostInPrivilegedMode', 'UpdateDataHistoryImmediatelyAfterWrite', 'UseStandardCommands',
    'VariantsStorage', 'WriteMode',
}

# Известные свойства дочерних элементов (union Attribute/Dimension/Resource) — allowlist default-ветки modify-child.
known_child_props = {
    'AccountingFlag', 'Balance', 'BaseDimension', 'ChoiceFoldersAndItems', 'ChoiceForm', 'ChoiceHistoryOnInput',
    'ChoiceParameterLinks', 'ChoiceParameters', 'Comment', 'CreateOnInput', 'DataHistory', 'DenyIncompleteValues',
    'DocumentMap', 'EditFormat', 'ExtDimensionAccountingFlag', 'ExtendedEdit', 'FillChecking', 'FillFromFillingValue',
    'FillValue', 'Format', 'FullTextSearch', 'Indexing', 'LinkByType', 'MainFilter', 'MarkNegatives', 'Mask', 'Master',
    'MaxValue', 'MinValue', 'MultiLine', 'Name', 'PasswordMode', 'QuickChoice', 'RegisterRecordsMap', 'ScheduleLink',
    'Synonym', 'ToolTip', 'Type', 'Use', 'UseInTotals',
}

# Канонический порядок свойств реквизита (последовательность build_attribute_fragment) — для вставки в позицию.
attr_prop_order = [
    'Name', 'Synonym', 'Comment', 'Type', 'PasswordMode', 'Format', 'EditFormat', 'ToolTip', 'MarkNegatives', 'Mask',
    'MultiLine', 'ExtendedEdit', 'MinValue', 'MaxValue', 'FillFromFillingValue', 'FillValue', 'FillChecking',
    'ChoiceFoldersAndItems', 'ChoiceParameterLinks', 'ChoiceParameters', 'QuickChoice', 'CreateOnInput', 'ChoiceForm',
    'LinkByType', 'ChoiceHistoryOnInput', 'Use', 'Indexing', 'FullTextSearch', 'DataHistory',
]


def insert_property_in_order(props_el, new_node, order_array, prop_name):
    """Вставить новое свойство в Properties в канонической позиции (по order_array); иначе append."""
    child_indent = get_child_indent(props_el)
    ref_node = None
    idx = order_array.index(prop_name) if (order_array and prop_name in order_array) else -1
    if idx >= 0:
        for ch in props_el:
            cl = localname(ch)
            if cl in order_array and order_array.index(cl) > idx:
                ref_node = ch
                break
    insert_before_element(props_el, new_node, ref_node, child_indent)


def set_attr_property_element(props_el, prop_name, fragment_xml):
    """Заменить существующий элемент свойства реквизита новым фрагментом, либо создать в позиции."""
    new_nodes = import_fragment(fragment_xml)
    if not new_nodes:
        return False
    existing = None
    for ch in props_el:
        if localname(ch) == prop_name:
            existing = ch
            break
    if existing is not None:
        idx = list(props_el).index(existing)
        new_nodes[0].tail = existing.tail
        props_el.insert(idx + 1, new_nodes[0])
        remove_node_with_whitespace(existing)
    else:
        insert_property_in_order(props_el, new_nodes[0], attr_prop_order, prop_name)
    return True


def build_min_max_value_xml(tag, val):
    """MinValue/MaxValue — типизированное значение (порт Emit-MinMaxValue): nil / xs:string / xs:decimal."""
    if val is None or str(val) == '':
        return f'<{tag} xsi:nil="true"/>'
    t = 'xs:string' if isinstance(val, str) else 'xs:decimal'
    return f'<{tag} xsi:type="{t}">{esc_xml(str(val))}</{tag}>'


# --- Порт из meta-compile: развёртка путей данных + связи выбора / тип по ссылке (structural modify) ---

def get_ch_el_prop(obj, names):
    """Свойство из dict по списку синонимов (первый найденный, иначе None)."""
    if obj is None:
        return None
    if isinstance(obj, dict):
        for n in names:
            if n in obj:
                return obj[n]
    return None


# Пары EN↔RU стандартных реквизитов Catalog/Document (для resolve_std_attr_en; py-карты плоские, восстанавливаем).
_STD_ATTR_BY_CTX = {
    'Catalog': [('Ref', 'Ссылка'), ('DeletionMark', 'ПометкаУдаления'), ('Predefined', 'Предопределенный'),
                ('PredefinedDataName', 'ИмяПредопределенныхДанных'), ('Code', 'Код'), ('Description', 'Наименование'),
                ('Owner', 'Владелец'), ('Parent', 'Родитель'), ('IsFolder', 'ЭтоГруппа')],
    'Document': [('Ref', 'Ссылка'), ('DeletionMark', 'ПометкаУдаления'), ('Date', 'Дата'),
                 ('Number', 'Номер'), ('Posted', 'Проведен')],
}


def resolve_std_attr_en(name):
    """Стандартный реквизит рус/англ → английский (Catalog/Document)."""
    pairs = _STD_ATTR_BY_CTX.get(obj_type)
    if not pairs:
        return None
    nl = str(name).lower()
    for en, ru in pairs:
        if nl == en.lower() or nl == ru.lower():
            return en
    return None


def expand_data_path(dp):
    """Прощающий ввод пути данных: короткое имя реквизита → полный путь объекта (порт Expand-DataPath)."""
    if not dp:
        return dp
    s = str(dp)
    if re.search(r'[:/]', s):
        return s
    if re.match(r'^-?\d+$', s):
        return s
    if re.match(r'^(StandardAttribute|Attribute)\.', s):
        return f"{obj_type}.{obj_name}.{s}"
    if '.' not in s:
        en = resolve_std_attr_en(s)
        if en:
            return f"{obj_type}.{obj_name}.StandardAttribute.{en}"
        return f"{obj_type}.{obj_name}.Attribute.{s}"
    return s


def convert_from_ch_link_shorthand(s):
    """Shorthand "name=path" | "name=path:Clear|DontChange" → {name, dataPath, valueChange?}."""
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    o = {'name': s[:eq].strip()}
    rest = s[eq + 1:].strip()
    m = re.match(r'^(.*):(Clear|DontChange|очистить|неизменять)$', rest, re.IGNORECASE)
    if m:
        o['dataPath'] = m.group(1).strip()
        o['valueChange'] = m.group(2)
    else:
        o['dataPath'] = rest
    return o


def build_link_by_type_xml(indent, spec):
    """LinkByType — {dataPath, linkItem?} (порт Emit-LinkByType)."""
    if not spec:
        return f"{indent}<LinkByType/>"
    if isinstance(spec, str):
        dp = spec
        li = 0
    else:
        dp = str(get_ch_el_prop(spec, ['dataPath', 'path', 'путь']) or '')
        li_raw = get_ch_el_prop(spec, ['linkItem', 'элементСвязи'])
        li = li_raw if li_raw is not None else 0
    if not dp:
        return f"{indent}<LinkByType/>"
    dp = expand_data_path(dp)
    return "\r\n".join([
        f"{indent}<LinkByType>",
        f"{indent}\t<xr:DataPath>{esc_xml(str(dp))}</xr:DataPath>",
        f"{indent}\t<xr:LinkItem>{li}</xr:LinkItem>",
        f"{indent}</LinkByType>",
    ])


def build_choice_parameter_links_xml(indent, cpl):
    """ChoiceParameterLinks — [{name, dataPath, valueChange?}] (порт Emit-ChoiceParameterLinks)."""
    items = cpl if isinstance(cpl, list) else ([cpl] if cpl else [])
    if not items:
        return f"{indent}<ChoiceParameterLinks/>"
    parts = [f"{indent}<ChoiceParameterLinks>"]
    for lk in items:
        if isinstance(lk, str):
            lk = convert_from_ch_link_shorthand(lk)
        name = get_ch_el_prop(lk, ['name', 'имя'])
        dp = expand_data_path(get_ch_el_prop(lk, ['dataPath', 'path', 'путь']))
        vc_raw = get_ch_el_prop(lk, ['valueChange', 'режимИзменения'])
        vc = 'Clear'
        if vc_raw:
            low = str(vc_raw).lower()
            if re.match(r'^(clear|очистить|очистка)$', low):
                vc = 'Clear'
            elif re.match(r'^(dontchange|неизменять|неменять|нет)$', low):
                vc = 'DontChange'
            else:
                vc = str(vc_raw)
        parts.append(f"{indent}\t<xr:Link>")
        parts.append(f"{indent}\t\t<xr:Name>{esc_xml(str(name) if name is not None else '')}</xr:Name>")
        parts.append(f'{indent}\t\t<xr:DataPath xsi:type="xs:string">{esc_xml(str(dp) if dp is not None else "")}</xr:DataPath>')
        parts.append(f"{indent}\t\t<xr:ValueChange>{vc}</xr:ValueChange>")
        parts.append(f"{indent}\t</xr:Link>")
    parts.append(f"{indent}</ChoiceParameterLinks>")
    return "\r\n".join(parts)


# --- Порт из meta-compile: значения параметров выбора (ChoiceParameters) ---

fill_ref_roots = {
    'перечисление': 'Enum', 'справочник': 'Catalog', 'документ': 'Document',
    'плансчетов': 'ChartOfAccounts', 'планвидовхарактеристик': 'ChartOfCharacteristicTypes',
    'планвидоврасчета': 'ChartOfCalculationTypes', 'планвидоврасчёта': 'ChartOfCalculationTypes',
    'планобмена': 'ExchangePlan', 'бизнеспроцесс': 'BusinessProcess', 'задача': 'Task',
    'enum': 'Enum', 'catalog': 'Catalog', 'document': 'Document', 'chartofaccounts': 'ChartOfAccounts',
    'chartofcharacteristictypes': 'ChartOfCharacteristicTypes', 'chartofcalculationtypes': 'ChartOfCalculationTypes',
    'exchangeplan': 'ExchangePlan', 'businessprocess': 'BusinessProcess', 'task': 'Task',
}
fill_empty_ref_words = {'emptyref', 'пустаяссылка'}
fill_enum_val_words = {'enumvalue', 'значениеперечисления'}
account_type_values = ('Active', 'Passive', 'ActivePassive')
fill_ref_kind_root = {
    'catalogref': 'Catalog', 'documentref': 'Document', 'enumref': 'Enum',
    'chartofaccountsref': 'ChartOfAccounts', 'chartofcharacteristictypesref': 'ChartOfCharacteristicTypes',
    'chartofcalculationtypesref': 'ChartOfCalculationTypes', 'exchangeplanref': 'ExchangePlan',
    'businessprocessref': 'BusinessProcess', 'taskref': 'Task',
}


def convert_to_ch_scalar(s):
    t = str(s).strip()
    if re.match(r'^(true|истина)$', t, re.IGNORECASE):
        return True
    if re.match(r'^(false|ложь)$', t, re.IGNORECASE):
        return False
    if re.match(r'^-?\d+$', t):
        return int(t)
    if re.match(r'^-?\d+\.\d+$', t):
        return float(t)
    return t


def format_fill_num(n):
    if isinstance(n, float):
        return str(int(n)) if n == int(n) else repr(n)
    return str(n)


def normalize_fill_ref(s):
    if not s:
        return None
    if re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F-]+$', s):
        return s
    parts = s.split('.')
    if len(parts) < 2:
        return None
    root = fill_ref_roots.get(parts[0].lower())
    if not root:
        return None
    type_name = parts[1]
    if root == 'Enum':
        if len(parts) == 2:
            return None
        if len(parts) == 3:
            if parts[2].lower() in fill_empty_ref_words:
                return f"Enum.{type_name}.EmptyRef"
            return f"Enum.{type_name}.EnumValue.{parts[2]}"
        member = parts[2]
        rest = '.'.join(parts[3:]) if member.lower() in fill_enum_val_words else '.'.join(parts[2:])
        return f"Enum.{type_name}.EnumValue.{rest}"
    tail = list(parts[1:])
    for i in range(len(tail)):
        if tail[i].lower() in fill_empty_ref_words:
            tail[i] = 'EmptyRef'
    return f"{root}." + '.'.join(tail)


def expand_choice_ref_value(value, type_str):
    if not type_str:
        return None
    t = resolve_type_str(type_str)
    root = None
    tn = None
    m = re.match(r'^(\w+Ref)\.(.+)$', t)
    if m:
        root = fill_ref_kind_root.get(m.group(1).lower())
        tn = m.group(2)
    else:
        m2 = re.match(r'^([^.]+)\.(.+)$', t)
        if m2:
            root = fill_ref_roots.get(m2.group(1).lower())
            tn = m2.group(2)
    if not root:
        return None
    if str(value).lower() in fill_empty_ref_words:
        return f"{root}.{tn}.EmptyRef"
    if root == 'Enum':
        return f"Enum.{tn}.EnumValue.{value}"
    return f"{root}.{tn}.{value}"


def normalize_choice_value(value):
    if isinstance(value, bool):
        return {'XsiType': 'xs:boolean', 'Text': 'true' if value else 'false'}
    if isinstance(value, (int, float)):
        return {'XsiType': 'xs:decimal', 'Text': format_fill_num(value)}
    s = str(value)
    if s == '':
        return {'XsiType': 'xs:string', 'Text': ''}
    if re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$', s):
        return {'XsiType': 'xs:dateTime', 'Text': s}
    ref = normalize_fill_ref(s)
    if ref:
        return {'XsiType': 'xr:DesignTimeRef', 'Text': ref}
    if s in account_type_values:
        return {'XsiType': 'ent:AccountType', 'Text': s}
    return {'XsiType': 'xs:string', 'Text': s}


def normalize_choice_value_t(value, type_str):
    if type_str and isinstance(value, str) and '.' not in str(value):
        ex = expand_choice_ref_value(value, type_str)
        if ex:
            return {'XsiType': 'xr:DesignTimeRef', 'Text': ex}
    return normalize_choice_value(value)


def convert_from_ch_param_shorthand(s):
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    name = s[:eq].strip()
    rest = s[eq + 1:]
    if ',' in rest:
        return {'name': name, 'value': [convert_to_ch_scalar(p) for p in rest.split(',')]}
    return {'name': name, 'value': convert_to_ch_scalar(rest)}


def build_choice_parameters_xml(indent, cp):
    """ChoiceParameters — [{name, type?, value?}] (порт Emit-ChoiceParameters). Требует xmlns:app в import_fragment."""
    items = cp if isinstance(cp, list) else ([cp] if cp else [])
    if not items:
        return f"{indent}<ChoiceParameters/>"
    parts = [f"{indent}<ChoiceParameters>"]
    for item in items:
        if isinstance(item, str):
            item = convert_from_ch_param_shorthand(item)
        name = get_ch_el_prop(item, ['name', 'имя'])
        ptype = get_ch_el_prop(item, ['type', 'тип'])
        has_val = False
        val = None
        if isinstance(item, dict):
            if 'value' in item:
                has_val = True
                val = item['value']
            elif 'значение' in item:
                has_val = True
                val = item['значение']
        val_is_array = isinstance(val, list)
        parts.append(f'{indent}\t<app:item name="{esc_xml(str(name) if name is not None else "")}">')
        if not has_val:
            parts.append(f'{indent}\t\t<app:value xsi:nil="true"/>')
        elif val_is_array:
            parts.append(f'{indent}\t\t<app:value xsi:type="v8:FixedArray">')
            for v in val:
                norm = normalize_choice_value_t(v, ptype)
                if not norm['Text']:
                    parts.append(f'{indent}\t\t\t<v8:Value xsi:type="{norm["XsiType"]}"/>')
                else:
                    parts.append(f'{indent}\t\t\t<v8:Value xsi:type="{norm["XsiType"]}">{esc_xml(norm["Text"])}</v8:Value>')
            parts.append(f'{indent}\t\t</app:value>')
        else:
            norm = normalize_choice_value_t(val, ptype)
            if not norm['Text']:
                parts.append(f'{indent}\t\t<app:value xsi:type="{norm["XsiType"]}"/>')
            else:
                parts.append(f'{indent}\t\t<app:value xsi:type="{norm["XsiType"]}">{esc_xml(norm["Text"])}</app:value>')
        parts.append(f'{indent}\t</app:item>')
    parts.append(f"{indent}</ChoiceParameters>")
    return "\r\n".join(parts)


# --- Порт из meta-compile: явное значение заполнения (FillValue) ---

fill_bool_true = {'true', 'истина', 'да'}
fill_bool_false = {'false', 'ложь', 'нет'}


def esc_xml_text(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def get_fill_type_category(type_str):
    if not type_str:
        return 'String'
    if '+' in type_str:
        return 'Other'
    t = resolve_type_str(type_str)
    if re.match(r'^Boolean$', t):
        return 'Boolean'
    if re.match(r'^String(\(|$)', t):
        return 'String'
    if re.match(r'^Number(\(|$)', t):
        return 'Number'
    if re.match(r'^(Date|DateTime)$', t):
        return 'Date'
    return 'Other'


def expand_fill_short_ref(s, type_str):
    if not type_str or '+' in type_str:
        return None
    t = resolve_type_str(type_str)
    m = re.match(r'^(\w+Ref)\.(.+)$', t)
    if not m:
        return None
    root = fill_ref_kind_root.get(m.group(1).lower())
    if not root:
        return None
    type_name = m.group(2)
    if s.lower() in fill_empty_ref_words:
        return f"{root}.{type_name}.EmptyRef"
    if root == 'Enum':
        return f"Enum.{type_name}.EnumValue.{s}"
    return f"{root}.{type_name}.{s}"


def resolve_fill_value_spec(s, type_str):
    cat = get_fill_type_category(type_str)
    if s == '':
        return {'XsiType': 'xs:string', 'Text': ''}
    if cat == 'String':
        return {'XsiType': 'xs:string', 'Text': s}
    if cat == 'Boolean' or s.lower() in fill_bool_true or s.lower() in fill_bool_false:
        if s.lower() in fill_bool_true:
            return {'XsiType': 'xs:boolean', 'Text': 'true'}
        if s.lower() in fill_bool_false:
            return {'XsiType': 'xs:boolean', 'Text': 'false'}
    if cat == 'Number':
        return {'XsiType': 'xs:decimal', 'Text': s}
    if cat == 'Date' or re.match(r'^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$', s):
        if re.match(r'^\d{4}-\d{2}-\d{2}$', s):
            s = s + 'T00:00:00'
        return {'XsiType': 'xs:dateTime', 'Text': s}
    ref = normalize_fill_ref(s)
    if ref:
        return {'XsiType': 'xr:DesignTimeRef', 'Text': ref}
    short = expand_fill_short_ref(s, type_str)
    if short:
        return {'XsiType': 'xr:DesignTimeRef', 'Text': short}
    return {'XsiType': 'xs:string', 'Text': s}


def get_attr_type_str_from_xml(props_el):
    """Извлечь тип реквизита из XML (<Type>/<v8:Type>) → DSL-typeStr для категоризации FillValue."""
    type_el = None
    for ch in props_el:
        if localname(ch) == 'Type':
            type_el = ch
            break
    if type_el is None:
        return ""
    mapped = []
    for ch in type_el:
        if localname(ch) == 'Type':
            t = (ch.text or '').strip()
            colon = t.find(':')
            if colon >= 0:
                t = t[colon + 1:]
            if t == 'string':
                mapped.append('String')
            elif t == 'decimal':
                mapped.append('Number')
            elif t == 'boolean':
                mapped.append('Boolean')
            elif t == 'dateTime':
                mapped.append('Date')
            else:
                mapped.append(t)
    if not mapped:
        return ""
    if len(mapped) > 1:
        return ' + '.join(mapped)
    return mapped[0]


def build_fill_value_explicit_xml(type_str, spec):
    """FillValue — явное значение (порт Emit-FillValue, ветка hasSpec)."""
    if spec is None:
        return '<FillValue xsi:nil="true"/>'
    if isinstance(spec, bool):
        return f'<FillValue xsi:type="xs:boolean">{"true" if spec else "false"}</FillValue>'
    if isinstance(spec, (int, float)):
        return f'<FillValue xsi:type="xs:decimal">{format_fill_num(spec)}</FillValue>'
    if get_ch_el_prop(spec, ['nil']) is True:
        return '<FillValue xsi:nil="true"/>'
    if get_ch_el_prop(spec, ['emptyRef', 'пустаяссылка']) is True:
        return '<FillValue xsi:type="xr:DesignTimeRef"/>'
    r = resolve_fill_value_spec(str(spec), type_str)
    if r['Text'] == '' and r['XsiType'] == 'xs:string':
        return '<FillValue xsi:type="xs:string"/>'
    return f'<FillValue xsi:type="{r["XsiType"]}">{esc_xml_text(r["Text"])}</FillValue>'


def find_property_element(prop_name):
    for child in properties_el:
        if localname(child) == prop_name:
            return child
    return None


def get_complex_property_values(prop_el):
    values = []
    for child in prop_el:
        values.append((child.text or "").strip())
    return values


def add_complex_property_item(property_name, values):
    global add_count

    map_entry = complex_property_map.get(property_name)
    if not map_entry:
        warn(f"Unknown complex property: {property_name}")
        return
    if map_entry.get("expand"):
        values = [expand_data_path(str(v)) for v in values]

    prop_el = find_property_element(property_name)
    if prop_el is None:
        warn(f"Property element '{property_name}' not found in Properties")
        return

    # Get existing values to check duplicates
    existing = get_complex_property_values(prop_el)

    indent = get_child_indent(properties_el)
    child_indent = f"{indent}\t"

    # Check if element is empty (self-closing)
    is_empty = len(list(prop_el)) == 0

    # If self-closing / empty, add closing whitespace
    if is_empty and not (prop_el.text and prop_el.text.strip()):
        prop_el.text = "\r\n" + indent

    for val in values:
        if val in existing:
            warn(f"{property_name} already contains '{val}', skipping")
            continue
        tag = map_entry["tag"]
        attr_str = map_entry["attr"]
        if attr_str:
            frag_xml = f"<{tag} {attr_str}>{esc_xml(val)}</{tag}>"
        else:
            frag_xml = f"<{tag}>{esc_xml(val)}</{tag}>"
        nodes = import_fragment(frag_xml)
        for node in nodes:
            insert_before_element(prop_el, node, None, child_indent)
        info(f"Added {property_name} item: {val}")
        add_count += 1


def remove_complex_property_item(property_name, values):
    global remove_count

    map_entry = complex_property_map.get(property_name)
    if map_entry and map_entry.get("expand"):
        values = [expand_data_path(str(v)) for v in values]
    prop_el = find_property_element(property_name)
    if prop_el is None:
        warn(f"Property element '{property_name}' not found in Properties")
        return

    for val in values:
        found = False
        for child in list(prop_el):
            if (child.text or "").strip() == val:
                remove_node_with_whitespace(child)
                info(f"Removed {property_name} item: {val}")
                remove_count += 1
                found = True
                break
        if not found:
            warn(f"{property_name} item '{val}' not found, skipping")

    # Collapse if empty
    has_elements = any(True for _ in prop_el)
    if not has_elements:
        prop_el.text = None


def set_complex_property(property_name, values):
    global modify_count

    map_entry = complex_property_map.get(property_name)
    if not map_entry:
        warn(f"Unknown complex property: {property_name}")
        return
    if map_entry.get("expand"):
        values = [expand_data_path(str(v)) for v in values]

    prop_el = find_property_element(property_name)
    if prop_el is None:
        warn(f"Property element '{property_name}' not found in Properties")
        return

    indent = get_child_indent(properties_el)
    child_indent = f"{indent}\t"

    # Remove all existing children
    for ch in list(prop_el):
        prop_el.remove(ch)
    prop_el.text = None

    if not values:
        # Leave self-closing
        info(f"Cleared {property_name}")
        modify_count += 1
        return

    # Add closing whitespace
    prop_el.text = "\r\n" + indent

    # Add each value
    for val in values:
        tag = map_entry["tag"]
        attr_str = map_entry["attr"]
        if attr_str:
            frag_xml = f"<{tag} {attr_str}>{esc_xml(val)}</{tag}>"
        else:
            frag_xml = f"<{tag}>{esc_xml(val)}</{tag}>"
        nodes = import_fragment(frag_xml)
        for node in nodes:
            insert_before_element(prop_el, node, None, child_indent)

    count = len(values)
    info(f"Set {property_name}: {count} items")
    modify_count += 1


# ============================================================
# Save helpers
# ============================================================


def _detect_xml_style(path):
    """Стиль существующего файла для round-trip-сохранения: BOM / EOL / регистр encoding /
    финальный перенос. None → файл новый (сохранить текущее поведение)."""
    try:
        raw = open(path, "rb").read()
    except OSError:
        return None
    bom = raw.startswith(b"\xef\xbb\xbf")
    body = raw[3:] if bom else raw
    crlf = b"\r\n" in body
    m = re.search(rb'encoding="([^"]+)"', body[:200])
    enc = m.group(1).decode("ascii") if m else "utf-8"
    final_nl = body.endswith(b"\n")
    return {"bom": bom, "crlf": crlf, "enc": enc, "final_nl": final_nl}


def _finalize_xml_bytes(xml_bytes, style):
    """Привести сериализованные байты к стилю оригинала (или к дефолту, если style is None)."""
    enc_decl = style["enc"] if style else "utf-8"
    xml_bytes = xml_bytes.replace(
        b"<?xml version='1.0' encoding='UTF-8'?>",
        b'<?xml version="1.0" encoding="' + enc_decl.encode("ascii") + b'"?>')
    # Канонизировать переносы к LF (убирает &#13; от \r в tail'ах)
    xml_bytes = (xml_bytes.replace(b"&#13;\n", b"\n").replace(b"&#13;", b"")
                 .replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
    # Финальный перенос — как в оригинале (новый файл → есть)
    want_final_nl = style["final_nl"] if style else True
    xml_bytes = xml_bytes.rstrip(b"\n")
    if want_final_nl:
        xml_bytes += b"\n"
    # EOL — как в оригинале (новый файл → LF, текущее поведение)
    if style and style["crlf"]:
        xml_bytes = xml_bytes.replace(b"\n", b"\r\n")
    return xml_bytes


def save_xml(tree, path):
    """Save XML tree preserving the existing file's BOM/EOL/encoding-case/final-newline."""
    style = _detect_xml_style(path)
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    # Fix d5p1 namespace declarations stripped by lxml (it treats them as unused
    # because d5p1: appears only in text content, not in element/attribute names)
    xml_bytes = re.sub(
        b'(<v8:Type)(?! xmlns:d5p1)(>d5p1:)',
        b'\\1 xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config"\\2',
        xml_bytes
    )
    xml_bytes = _finalize_xml_bytes(xml_bytes, style)
    with open(path, "wb") as f:
        if style is None or style["bom"]:
            f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


# ============================================================
# Main
# ============================================================

# ============================================================
# Predefined data (Ext/Predefined.xml) — add предопределённых (Catalog/ChartOfCharacteristicTypes).
# Существующие <Item id=GUID> сохраняются побайтово (текстовый append), новые получают свежий GUID.
# ============================================================

predef_xsi_type_by_obj = {
    'Catalog': 'CatalogPredefinedItems',
    'ChartOfCharacteristicTypes': 'PlanOfCharacteristicKindPredefinedItems',
}


def get_predefined_path():
    return os.path.join(os.path.dirname(resolved_path), obj_name, "Ext", "Predefined.xml")


def get_object_code_type():
    for ch in properties_el:
        if localname(ch) == 'CodeType':
            return (ch.text or '').strip()
    return 'String'


def resolve_predef_item(val):
    if isinstance(val, str):
        s = val
        desc_raw = None
        has_desc = False
        m = re.search(r'\[(.*)\]', s)
        if m:
            desc_raw = m.group(1)
            has_desc = True
            s = re.sub(r'\s*\[.*\]', '', s)
        mm = re.match(r'^\s*(?:\(([^)]*)\)\s*)?(\S+)\s*$', s.strip())
        name = mm.group(2) if mm else s.strip()
        code = mm.group(1) if (mm and mm.group(1) is not None) else ''
        desc = desc_raw if has_desc else split_camel_case(name)
        return {'name': name, 'code': code, 'desc': desc, 'isFolder': False, 'children': []}

    def gv(o, keys):
        for k in keys:
            if isinstance(o, dict) and k in o:
                return o[k]
        return None
    name = str(gv(val, ['name', 'имя']) or '')
    code_v = gv(val, ['code', 'код'])
    code = str(code_v) if code_v is not None else ''
    has_desc = isinstance(val, dict) and ('description' in val or 'наименование' in val)
    desc_v = gv(val, ['description', 'наименование'])
    desc = str(desc_v) if has_desc else split_camel_case(name)
    is_folder = gv(val, ['isFolder', 'группа']) is True
    subs = gv(val, ['childItems', 'подчиненные'])
    return {'name': name, 'code': code, 'desc': desc if desc is not None else '',
            'isFolder': is_folder, 'children': list(subs) if subs else []}


def build_predef_item_xml(indent, val, code_type):
    r = resolve_predef_item(val)
    parts = [f'{indent}<Item id="{new_uuid()}">']
    parts.append(f'{indent}\t<Name>{esc_xml_text(r["name"])}</Name>')
    if not r['code']:
        parts.append(f'{indent}\t<Code/>')
    elif code_type == 'Number':
        parts.append(f'{indent}\t<Code xsi:type="xs:decimal">{esc_xml_text(r["code"])}</Code>')
    else:
        parts.append(f'{indent}\t<Code>{esc_xml_text(r["code"])}</Code>')
    if r['desc'] == '':
        parts.append(f'{indent}\t<Description/>')
    else:
        parts.append(f'{indent}\t<Description>{esc_xml_text(r["desc"])}</Description>')
    parts.append(f'{indent}\t<IsFolder>{"true" if r["isFolder"] else "false"}</IsFolder>')
    if r['children']:
        parts.append(f'{indent}\t<ChildItems>')
        for c in r['children']:
            parts.append(build_predef_item_xml(indent + '\t\t', c, code_type).rstrip('\r\n'))
        parts.append(f'{indent}\t</ChildItems>')
    parts.append(f'{indent}</Item>')
    return '\r\n'.join(parts) + '\r\n'


def add_predefined_items(items):
    global add_count
    xsi_type = predef_xsi_type_by_obj.get(obj_type)
    if not xsi_type:
        print(f"add-predefined: тип объекта '{obj_type}' не поддержан (только Catalog, ChartOfCharacteristicTypes)", file=sys.stderr)
        sys.exit(1)
    code_type = get_object_code_type()
    version = xml_root.get("version")
    path = get_predefined_path()
    item_list = items if isinstance(items, list) else [items]
    items_xml = ''.join(build_predef_item_xml('\t', it, code_type) for it in item_list)
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8-sig') as f:
            text = f.read()
        text = text.replace('</PredefinedData>', items_xml + '</PredefinedData>')
    else:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        hdr = ('<?xml version="1.0" encoding="UTF-8"?>\r\n<PredefinedData xmlns="http://v8.1c.ru/8.3/xcf/predef" '
               'xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" '
               'xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
               f'xsi:type="{xsi_type}" version="{version}">\r\n')
        text = hdr + items_xml + '</PredefinedData>\r\n'
    with open(path, 'wb') as f:
        f.write(b'\xef\xbb\xbf')
        f.write(text.encode('utf-8'))
    info(f"Added {len(item_list)} predefined item(s) -> {path}")
    add_count += len(item_list)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    global xml_tree, xml_root, obj_element, obj_type, md_ns
    global properties_el, child_objects_el, obj_name, resolved_path
    global add_count, remove_count, modify_count, warn_count

    valid_operations = [
        "add-attribute", "add-ts", "add-dimension", "add-resource",
        "add-enumValue", "add-column", "add-form", "add-template", "add-command",
        "add-owner", "add-registerRecord", "add-basedOn", "add-inputByString",
        "add-dataLockField", "add-registeredDocument", "add-predefined",
        "remove-attribute", "remove-ts", "remove-dimension", "remove-resource",
        "remove-enumValue", "remove-column", "remove-form", "remove-template", "remove-command",
        "remove-owner", "remove-registerRecord", "remove-basedOn", "remove-inputByString",
        "remove-dataLockField", "remove-registeredDocument",
        "add-ts-attribute", "remove-ts-attribute", "modify-ts-attribute", "modify-ts",
        "modify-attribute", "modify-dimension", "modify-resource",
        "modify-enumValue", "modify-column",
        "modify-property",
        "set-owners", "set-registerRecords", "set-basedOn", "set-inputByString",
        "set-dataLockFields", "set-registeredDocuments",
    ]

    parser = argparse.ArgumentParser(description="Edit existing 1C metadata object XML", allow_abbrev=False)
    parser.add_argument("-DefinitionFile", default=None, help="JSON definition file")
    parser.add_argument("-ObjectPath", "-Path", required=True, help="Path to object XML or directory")
    parser.add_argument("-Operation", default=None, choices=valid_operations, help="Inline operation")
    parser.add_argument("-Value", default=None, help="Inline value")
    parser.add_argument("-NoValidate", action="store_true", help="Skip auto-validation")
    args = parser.parse_args()

    # --- Mode validation ---
    if args.DefinitionFile and args.Operation:
        die("Cannot use both -DefinitionFile and -Operation")
    if not args.DefinitionFile and not args.Operation:
        die("Either -DefinitionFile or -Operation is required")

    # --- Load JSON definition (DefinitionFile mode) ---
    definition = None
    if args.DefinitionFile:
        if not os.path.exists(args.DefinitionFile):
            die(f"Definition file not found: {args.DefinitionFile}")
        with open(args.DefinitionFile, "r", encoding="utf-8-sig") as f:
            definition = json.load(f)

    # --- Resolve object path ---
    object_path = args.ObjectPath
    if os.path.isdir(object_path):
        dir_name = os.path.basename(object_path)
        candidate = os.path.join(object_path, f"{dir_name}.xml")
        sibling = os.path.join(os.path.dirname(object_path), f"{dir_name}.xml")
        if os.path.exists(candidate):
            object_path = candidate
        elif os.path.exists(sibling):
            object_path = sibling
        else:
            die(f"Directory given but no {dir_name}.xml found inside or as sibling")

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
        die(f"Object file not found: {object_path}")

    resolved_path = os.path.abspath(object_path)

    assert_edit_allowed(resolved_path, "editable")

    # --- Load XML ---
    xml_parser = etree.XMLParser(remove_blank_text=False)
    xml_tree = etree.parse(resolved_path, xml_parser)
    xml_root = xml_tree.getroot()

    # --- Detect object type ---
    if localname(xml_root) != "MetaDataObject":
        die(f"Root element must be MetaDataObject, got: {localname(xml_root)}")

    # Find the first child element -- this is the object type element
    obj_element = None
    for child in xml_root:
        obj_element = child
        break
    if obj_element is None:
        die("No object element found under MetaDataObject")

    obj_type = localname(obj_element)
    md_ns = etree.QName(obj_element.tag).namespace or ""

    # Find Properties and ChildObjects
    properties_el = None
    child_objects_el = None
    for child in obj_element:
        ln = localname(child)
        if ln == "Properties":
            properties_el = child
        if ln == "ChildObjects":
            child_objects_el = child

    if properties_el is None:
        die(f"No <Properties> found in {obj_type}")

    # Extract object name
    obj_name = ""
    for child in properties_el:
        if localname(child) == "Name":
            obj_name = (child.text or "").strip()
            break

    info(f"Object: {obj_type}.{obj_name}")

    # --- Inline mode conversion ---
    if args.Operation:
        definition = convert_inline_to_definition(args.Operation, args.Value or "")

    if definition is None:
        die("No definition loaded")

    # --- Process complex property operations ---
    if "_complex" in definition and definition["_complex"]:
        for cop in definition["_complex"]:
            action = cop["action"]
            if action == "add":
                add_complex_property_item(cop["property"], cop["values"])
            elif action == "remove":
                remove_complex_property_item(cop["property"], cop["values"])
            elif action == "set":
                set_complex_property(cop["property"], cop["values"])

    # --- Process standard operations ---
    for prop_name, prop_value in definition.items():
        if prop_name == "_complex":
            continue
        op_key = resolve_operation_key(prop_name)
        if not op_key:
            warn(f"Unknown operation: {prop_name}")
            continue

        if op_key == "add":
            process_add(prop_value)
        elif op_key == "remove":
            process_remove(prop_value)
        elif op_key == "modify":
            process_modify(prop_value)

    # --- Save XML ---
    save_xml(xml_tree, resolved_path)
    info(f"Saved: {resolved_path}")

    # --- Auto-validate ---
    if not args.NoValidate:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        validate_script = os.path.normpath(os.path.join(script_dir, "..", "..", "meta-validate", "scripts", "meta-validate.py"))
        if os.path.exists(validate_script):
            print()
            print("--- Running meta-validate ---")
            python_exe = sys.executable
            subprocess.run([python_exe, validate_script, "-ObjectPath", resolved_path])
        else:
            print()
            print(f"[SKIP] meta-validate not found at: {validate_script}")

    # --- Summary ---
    print()
    print("=== meta-edit summary ===")
    print(f"  Object:   {obj_type}.{obj_name}")
    print(f"  Added:    {add_count}")
    print(f"  Removed:  {remove_count}")
    print(f"  Modified: {modify_count}")
    if warn_count > 0:
        print(f"  Warnings: {warn_count}")

    total_changes = add_count + remove_count + modify_count
    if total_changes == 0:
        print("  No changes applied.")

    sys.exit(0)


if __name__ == "__main__":
    main()
