# xdto-compile v1.15 — Build a 1C XDTO package from an XML Schema (XSD) (Python port) (+support-guard: общая реализация вместо урезанной)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid
import xml.etree.ElementTree as ET

from lxml import etree

# Эти пространства имён предоставляет сама платформа — пакетов в конфигурации
# для них нет и быть не должно (выведено по корпусу)
PLATFORM_NS = {
    "http://v8.1c.ru/8.1/data/core",
    "http://v8.1c.ru/8.1/data/enterprise",
    "http://v8.1c.ru/8.1/data/enterprise/current-config",
    "http://v8.1c.ru/8.1/data-composition-system/settings",
    "http://v8.1c.ru/8.3/data/ext",
    "http://www.w3.org/2001/XMLSchema",
}


sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

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


XDTO_NS = "http://v8.1c.ru/8.1/xdto"
XS_NS = "http://www.w3.org/2001/XMLSchema"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
MD_NS = "http://v8.1c.ru/8.3/MDClasses"

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-XsdPath", "-Path", default="")
parser.add_argument("-Xsd", default="")
parser.add_argument("-OutputDir", required=True)
parser.add_argument("-Name", default="")
parser.add_argument("-Synonym", default="")
parser.add_argument("-Comment", default="")
parser.add_argument("-Force", action="store_true")
args = ci_parse_args(parser)


def _parse_xml(source, from_string=False):
    """Разбор с узким отступлением для не-URI пространств имён.

    Платформа допускает в targetNamespace произвольную строку (в выгрузке БП есть
    пакет с кириллическим «ДопФайлУниверсальный»), .NET такое принимает, а libxml2
    отвергает. Откатываемся на восстанавливающий разбор ТОЛЬКО на этой ошибке,
    иначе по-настоящему битый XML перестал бы отличаться от корректного.
    """
    try:
        return (etree.fromstring(source) if from_string else etree.parse(source))
    except etree.XMLSyntaxError as e:
        if "is not a valid URI" not in str(e):
            raise
        p = etree.XMLParser(recover=True)
        return (etree.fromstring(source, p) if from_string else etree.parse(source, p))

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


def detect_format_version(d):
    while d:
        # Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
        # корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
        ext_path = d + ".xml"
        if os.path.isfile(ext_path):
            with open(ext_path, "r", encoding="utf-8-sig") as f:
                ext_head = f.read(2000)
            if re.search(r'<(ExternalDataProcessor|ExternalReport)[ >]', ext_head):
                m = re.search(r'<MetaDataObject[^>]+version="(\d+\.\d+)"', ext_head)
                if m:
                    return m.group(1)
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


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


# ── load the schema ──────────────────────────────────────────

if args.Xsd:
    xsd_bytes = args.Xsd.encode("utf-8")
    default_name = "Package"
elif args.XsdPath:
    if not os.path.isfile(args.XsdPath):
        print(f"Файл XSD не найден: {args.XsdPath}", file=sys.stderr)
        sys.exit(1)
    with open(args.XsdPath, "rb") as f:
        xsd_bytes = f.read()
    default_name = os.path.splitext(os.path.basename(args.XsdPath))[0]
else:
    print("Укажите -XsdPath или -Xsd", file=sys.stderr)
    sys.exit(1)

try:
    schema = _parse_xml(xsd_bytes, from_string=True)
except Exception as e:  # noqa: BLE001
    print(f"Не удалось разобрать XSD: {e}", file=sys.stderr)
    sys.exit(1)


def local(el):
    return etree.QName(el).localname


if local(schema) != "schema" or etree.QName(schema).namespace != XS_NS:
    print(f"Ожидался корневой <xs:schema> в пространстве имён {XS_NS}", file=sys.stderr)
    sys.exit(1)

target_ns = schema.get("targetNamespace") or ""

# ── emit-tree primitives ─────────────────────────────────────


class Node:
    __slots__ = ("tag", "attrs", "children", "text", "prefix", "declare_ns")

    def __init__(self, tag):
        self.tag = tag
        self.attrs = []       # список dict: name, value | (ns, local) | list
        self.children = []
        self.text = None
        self.prefix = None
        self.declare_ns = None


def add_attr(node, name, value):
    if value is None:
        return
    node.attrs.append({"name": name, "value": str(value)})


def add_qattr(node, name, ns, loc):
    if loc is None:
        return
    node.attrs.append({"name": name, "ns": ns, "local": loc})


def add_qlist_attr(node, name, pairs, clark):
    if not pairs:
        return
    node.attrs.append({"name": name, "list": pairs, "clark": clark})


# Канонический порядок атрибутов — топологическая сортировка по корпусу 8.3.24
# (acc + erp, 760 пакетов), см. docs/1c-xdto-spec.md.
ATTR_ORDER = {
    "package": ["targetNamespace", "elementFormQualified", "attributeFormQualified"],
    "import": ["namespace"],
    "objectType": ["name", "base", "open", "abstract", "mixed", "ordered", "sequenced"],
    "property": ["name", "ref", "type", "lowerBound", "upperBound", "nillable",
                 "fixed", "default", "form", "localName", "qualified"],
    "valueType": ["name", "base", "variety", "itemType", "length", "memberTypes",
                  "minExclusive", "maxExclusive", "minInclusive", "maxInclusive",
                  "minLength", "maxLength", "totalDigits", "fractionDigits", "whiteSpace"],
    "typeDef": ["xsi:type", "base", "mixed", "open", "ordered", "sequenced", "variety",
                "itemType", "length", "memberTypes", "minExclusive", "maxExclusive",
                "minInclusive", "maxInclusive", "minLength", "maxLength",
                "totalDigits", "fractionDigits", "whiteSpace"],
    "enumeration": ["xsi:type"],
}


def sort_attrs(node):
    order = ATTR_ORDER.get(node.tag)
    if not order:
        return node.attrs
    res = []
    for n in order:
        res.extend(a for a in node.attrs if a["name"] == n)
    res.extend(a for a in node.attrs if a["name"] not in order)
    return res


def esc(s):
    if s is None:
        return ""
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def esc_text(s):
    if s is None:
        return ""
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── serializer with the dNpM prefix scheme ───────────────────

out = []


def serialize_node(node, depth, inherited):
    indent = "\t" * (depth - 1)
    attrs_sorted = sort_attrs(node)

    # Объявляем здесь только те ns, которых ещё нет в области видимости:
    # сериализатор платформы объявляет префикс на первом нуждающемся узле,
    # а потомки переиспользуют — отсюда d2p1 у property внутри objectType.
    local_ns = []

    def need_prefix(ns):
        if not ns or ns in (XS_NS, XSI_NS):
            return
        if ns in inherited:
            return
        if ns not in local_ns:
            local_ns.append(ns)

    for a in attrs_sorted:
        if "list" in a:
            # Нотация Кларка несёт ns в значении и префикса не требует
            if not a["clark"]:
                for p in a["list"]:
                    need_prefix(p[0])
        elif a.get("ns"):
            need_prefix(a["ns"])

    has_qualified = any(a["name"] == "qualified" for a in attrs_sorted)
    if has_qualified:
        need_prefix(XDTO_NS)
    if node.declare_ns:
        need_prefix(node.declare_ns)

    prefix_of = dict(inherited)
    ns_decls = ""
    for i, ns in enumerate(local_ns):
        # Осмысленный префикс из исходника (зеркало xdto:prefix) имеет приоритет
        px = node.prefix if (i == 0 and node.prefix) else f"d{depth}p{i + 1}"
        prefix_of[ns] = px
        ns_decls += f' xmlns:{px}="{esc(ns)}"'

    def qval(ns, loc):
        if not ns:
            return loc
        if ns == XS_NS:
            return f"xs:{loc}"
        if ns == XSI_NS:
            return f"xsi:{loc}"
        return f"{prefix_of[ns]}:{loc}"

    attr_text = ""
    for a in attrs_sorted:
        if "list" in a:
            vals = []
            for ns, loc in a["list"]:
                vals.append((f"{{{ns}}}{loc}" if ns else loc) if a["clark"] else qval(ns, loc))
            attr_text += f' {a["name"]}="{esc(" ".join(vals))}"'
        elif a.get("ns") or a.get("local"):
            attr_text += f' {a["name"]}="{esc(qval(a.get("ns"), a["local"]))}"'
        elif a["name"] == "qualified":
            attr_text += f' {prefix_of[XDTO_NS]}:qualified="{esc(a["value"])}"'
        else:
            attr_text += f' {a["name"]}="{esc(a["value"])}"'

    tag_name = f"{prefix_of[XDTO_NS]}:{node.tag}" if has_qualified else node.tag

    has_children = bool(node.children)
    # Пустое значение пишется самозакрывающимся тегом: <enumeration/>
    has_text = node.text is not None and node.text != ""

    if not has_children and not has_text:
        out.append(f"{indent}<{tag_name}{ns_decls}{attr_text}/>\r\n")
        return
    if has_text and not has_children:
        out.append(f"{indent}<{tag_name}{ns_decls}{attr_text}>{esc_text(node.text)}</{tag_name}>\r\n")
        return
    out.append(f"{indent}<{tag_name}{ns_decls}{attr_text}>\r\n")
    for c in node.children:
        serialize_node(c, depth + 1, prefix_of)
    out.append(f"{indent}</{tag_name}>\r\n")


# ── XSD reading helpers ──────────────────────────────────────

# Предупреждения о том, что XSD выражает, а модель XDTO — нет. Молча ронять
# такие конструкции нельзя: пакет соберётся, а половина свойств исчезнет.
warnings_list = []


def warn(msg):
    if msg not in warnings_list:
        warnings_list.append(msg)


GROUPS = {}
ATTR_GROUPS = {}


def MA(el, name):
    # xdto: mirror attribute — литеральное значение для Package.bin.
    # Ищем по namespace, а не по строке префикса.
    return el.get(f"{{{XDTO_NS}}}{name}")


def xchildren(el, name):
    return [c for c in el if isinstance(c.tag, str)
            and etree.QName(c).namespace == XS_NS and local(c) == name]


def xfirst(el, name):
    r = xchildren(el, name)
    return r[0] if r else None


def split_qname(el, qname):
    if not qname:
        return None
    parts = qname.split(":")
    if len(parts) == 2:
        ns = el.nsmap.get(parts[0])
        loc = parts[1]
    else:
        # Прощающий ввод: голое имя типа — тип целевого пространства имён
        ns = el.nsmap.get(None) or target_ns
        loc = parts[0]
    return (ns, loc)


def split_qname_list(el, lst):
    if not lst:
        return []
    return [split_qname(el, q) for q in lst.split() if q]


FACETS = ["length", "minLength", "maxLength", "totalDigits", "fractionDigits",
          "minInclusive", "maxInclusive", "minExclusive", "maxExclusive", "whiteSpace"]


# ── simpleType -> valueType / typeDef(ValueType) ─────────────

def fill_simple_type(node, st):
    restriction = xfirst(st, "restriction")
    lst = xfirst(st, "list")
    union = xfirst(st, "union")

    if lst is not None:
        it = split_qname(lst, lst.get("itemType"))
        mv = MA(lst, "variety")
        add_attr(node, "variety", mv if mv is not None else "List")
        if it:
            add_qattr(node, "itemType", it[0], it[1])
        return
    if union is not None:
        mv = MA(union, "variety")
        set_attr_value(node, "variety", mv if mv is not None else "Union")
        members = split_qname_list(union, union.get("memberTypes"))
        # По умолчанию нотация Кларка — так записано 125 из 135 memberTypes корпуса
        use_clark = MA(union, "memberTypesForm") != "prefixed"
        if members:
            add_qlist_attr(node, "memberTypes", members, use_clark)
        node.declare_ns = MA(union, "declareNs")
        for anon in xchildren(union, "simpleType"):
            # typeDef в контексте простого типа xsi:type не несёт (40 узлов корпуса)
            td = Node("typeDef")
            fill_simple_type(td, anon)
            node.children.append(td)
        return
    if restriction is not None:
        b = split_qname(restriction, restriction.get("base"))
        if b:
            add_qattr(node, "base", b[0], b[1])
        mv = MA(restriction, "variety")
        if mv is not None:
            add_attr(node, "variety", mv)
        # Анонимный базовый тип внутри xs:restriction — typeDef без xsi:type
        anon_base = xfirst(restriction, "simpleType")
        if anon_base is not None:
            td = Node("typeDef")
            fill_simple_type(td, anon_base)
            node.children.append(td)
        for f in FACETS:
            for fe in xchildren(restriction, f):
                add_attr(node, f, fe.get("value"))
        for pe in xchildren(restriction, "pattern"):
            pn = Node("pattern")
            pn.text = pe.get("value")
            node.children.append(pn)
        for en in xchildren(restriction, "enumeration"):
            enode = Node("enumeration")
            mt = MA(en, "type")
            if mt is not None:
                q = split_qname(en, mt)
                add_qattr(enode, "xsi:type", q[0], q[1])
            enode.text = en.get("value")
            node.children.append(enode)


def set_attr_value(node, name, value):
    for a in node.attrs:
        if a["name"] == name:
            a["value"] = value
            return
    add_attr(node, name, value)


def get_prop_key(p):
    for a in p.attrs:
        if a["name"] == "name":
            return a.get("value")
    for a in p.attrs:
        if a["name"] == "ref":
            return "@" + a["local"]
    return None


def reorder_properties(node, names):
    props = [c for c in node.children if c.tag == "property"]
    if len(props) < 2:
        return
    by_key = {}
    for p in props:
        k = get_prop_key(p)
        if k is not None and k not in by_key:
            by_key[k] = p
    ordered = []
    for n in names:
        if n in by_key:
            ordered.append(by_key.pop(n))
    for p in props:
        if p not in ordered:
            ordered.append(p)
    others = [c for c in node.children if c.tag != "property"]
    node.children = ordered + others


# ── element / attribute -> property ──────────────────────────

def build_property(el, is_attribute):
    p = Node("property")

    xsd_name = el.get("name")
    mirror_name = MA(el, "name")
    if mirror_name is not None:
        add_attr(p, "name", mirror_name)
        local_name = xsd_name
    else:
        add_attr(p, "name", xsd_name)
        local_name = None

    ref_q = split_qname(el, el.get("ref"))
    if ref_q:
        add_qattr(p, "ref", ref_q[0], ref_q[1])

    type_q = split_qname(el, el.get("type"))
    if type_q:
        add_qattr(p, "type", type_q[0], type_q[1])

    if is_attribute:
        add_attr(p, "lowerBound", MA(el, "lowerBound"))
        add_attr(p, "upperBound", MA(el, "upperBound"))
        add_attr(p, "nillable", MA(el, "nillable"))
    else:
        add_attr(p, "lowerBound", el.get("minOccurs"))
        max_occ = el.get("maxOccurs")
        if max_occ is not None:
            add_attr(p, "upperBound", "-1" if max_occ == "unbounded" else max_occ)
        add_attr(p, "nillable", el.get("nillable"))

    # XSD-шный fixed="V" несёт значение, в модели это fixed="true" + default="V".
    # Прощающий ввод: модельная форма через зеркало xdto:fixed тоже принимается.
    m_fixed = MA(el, "fixed")
    if m_fixed is not None:
        add_attr(p, "fixed", m_fixed)
        add_attr(p, "default", el.get("default"))
        if m_fixed == "true" and el.get("default") is None:
            warn('Свойство "' + str(el.get("name")) + '": xdto:fixed="true" без default — '
                 "платформа отвергнет пакет («Отсутствует фиксированное значение»). "
                 'Значение задаётся атрибутом default, либо пишите XSD-форму fixed="значение"')
    elif el.get("fixed") is not None:
        add_attr(p, "fixed", "true")
        add_attr(p, "default", el.get("fixed"))
    else:
        add_attr(p, "default", el.get("default"))

    if is_attribute:
        add_attr(p, "form", "Attribute")
    else:
        mf = MA(el, "form")
        if mf is not None:
            add_attr(p, "form", mf)
    add_attr(p, "localName", local_name)
    add_attr(p, "qualified", MA(el, "qualified"))
    p.prefix = MA(el, "prefix")

    anon_simple = xfirst(el, "simpleType")
    anon_complex = xfirst(el, "complexType")
    if anon_simple is not None:
        td = Node("typeDef")
        add_attr(td, "xsi:type", "ValueType")
        fill_simple_type(td, anon_simple)
        p.children.append(td)
    elif anon_complex is not None:
        td = Node("typeDef")
        add_attr(td, "xsi:type", "ObjectType")
        fill_complex_type(td, anon_complex)
        p.children.append(td)
    return p


# ── complexType -> objectType / typeDef(ObjectType) ──────────

def resolve_group(el, kind):
    ref = el.get("ref")
    if not ref:
        return None
    q = split_qname(el, ref)
    if not q:
        return None
    m = GROUPS if kind == "group" else ATTR_GROUPS
    return m.get(q[1])


# Модель XDTO знает только плоский список свойств: вложенные частицы уплощаются.
# Каждое уплощение — предупреждение, потому что меняется смысл схемы.
def collect_particle(particle, elem_list, open_flag, type_name, depth, optionalize=False):
    if depth > 20:
        return
    for c in particle:
        if not isinstance(c.tag, str) or etree.QName(c).namespace != XS_NS:
            continue
        ln = local(c)
        if ln == "element":
            prop = build_property(c, False)
            # Ветка уплощённого xs:choice обязана стать необязательной: иначе
            # «одно из двух» превращается в «оба сразу», и тип нельзя заполнить
            if optionalize:
                set_attr_value(prop, "lowerBound", "0")
            elem_list.append(prop)
        elif ln == "any":
            open_flag[0] = True
        elif ln == "sequence":
            warn(type_name + " : вложенная xs:sequence уплощена — модель XDTO хранит плоский список свойств")
            collect_particle(c, elem_list, open_flag, type_name, depth + 1, optionalize)
        elif ln == "choice":
            branches = [b.get("name") for b in c
                        if isinstance(b.tag, str) and etree.QName(b).namespace == XS_NS and b.get("name")]
            lst = (" (" + ", ".join(branches) + ")") if branches else ""
            warn(type_name + " : вложенная xs:choice уплощена — ветки" + lst + " сделаны необязательными. "
                 "Выбор одного из вариантов не сохранён: модель не запретит заполнить "
                 "сразу несколько или ни одного")
            collect_particle(c, elem_list, open_flag, type_name, depth + 1, True)
        elif ln == "all":
            warn(type_name + " : xs:all трактуется как последовательность")
            collect_particle(c, elem_list, open_flag, type_name, depth + 1, optionalize)
        elif ln == "group":
            g = resolve_group(c, "group")
            if g is not None:
                for gc in g:
                    if isinstance(gc.tag, str) and etree.QName(gc).namespace == XS_NS \
                            and local(gc) in ("sequence", "choice", "all"):
                        collect_particle(gc, elem_list, open_flag, type_name, depth + 1, optionalize)
            else:
                warn(type_name + " : не найдена группа " + str(c.get("ref")) + " — её свойства в пакет не попали")
        if ln in ("sequence", "choice", "all", "group"):
            if c.get("maxOccurs") is not None or c.get("minOccurs") is not None:
                warn(type_name + " : кратность на вложенной частице (<xs:" + ln +
                     " minOccurs/maxOccurs>) не выражается в модели XDTO")


def set_type_flags(node, ct, is_open, choice):
    m_open = MA(ct, "open")
    if m_open is not None:
        add_attr(node, "open", m_open)
    elif is_open:
        add_attr(node, "open", "true")

    m_ordered = MA(ct, "ordered")
    if m_ordered is not None:
        add_attr(node, "ordered", m_ordered)
    elif choice is not None:
        add_attr(node, "ordered", "false")

    m_seq = MA(ct, "sequenced")
    if m_seq is not None:
        add_attr(node, "sequenced", m_seq)

    m_abstract = MA(ct, "abstract")
    if m_abstract is not None:
        add_attr(node, "abstract", m_abstract)
    elif ct.get("abstract") == "true":
        add_attr(node, "abstract", "true")

    m_mixed = MA(ct, "mixed")
    if m_mixed is not None:
        add_attr(node, "mixed", m_mixed)
    elif ct.get("mixed") == "true":
        add_attr(node, "mixed", "true")


def fill_complex_type(node, ct):
    body = ct
    content = xfirst(ct, "complexContent")
    if content is not None:
        ext = xfirst(content, "extension")
        if ext is not None:
            b = split_qname(ext, ext.get("base"))
            if b:
                add_qattr(node, "base", b[0], b[1])
            body = ext

    # xs:simpleContent -> свойство "Text", хранящее значение самого элемента
    simple = xfirst(ct, "simpleContent")
    if simple is not None:
        ext = xfirst(simple, "extension")
        if ext is not None:
            for a in xchildren(ext, "attribute"):
                node.children.append(build_property(a, True))
            tp = Node("property")
            t_name = MA(ext, "textName")
            add_attr(tp, "name", t_name if t_name is not None else "__content")
            b = split_qname(ext, ext.get("base"))
            if b:
                add_qattr(tp, "type", b[0], b[1])
            add_attr(tp, "lowerBound", MA(ext, "textlowerBound"))
            add_attr(tp, "upperBound", MA(ext, "textupperBound"))
            add_attr(tp, "nillable", MA(ext, "textnillable"))
            add_attr(tp, "form", "Text")
            node.children.append(tp)
            # xs:simpleContent не отменяет флаги самого xs:complexType
            set_type_flags(node, ct, False, None)
            return

    seq = xfirst(body, "sequence")
    cho = xfirst(body, "choice")
    all_ = xfirst(body, "all")
    grp = xfirst(body, "group")
    particle = seq if seq is not None else (cho if cho is not None else (all_ if all_ is not None else grp))
    open_flag = [False]

    # Порядок в XDTO: сначала form="Attribute", потом остальные (96.5% типов корпуса)
    elem_props = []
    type_name = ct.get("name") or "(анонимный тип)"
    if particle is not None:
        if all_ is not None:
            warn(type_name + " : xs:all трактуется как последовательность")
        if grp is not None and seq is None and cho is None and all_ is None:
            # Корневая частица задана ссылкой на группу — раскрываем её содержимое
            g = resolve_group(grp, "group")
            if g is not None:
                for gc in g:
                    if isinstance(gc.tag, str) and etree.QName(gc).namespace == XS_NS \
                            and local(gc) in ("sequence", "choice", "all"):
                        collect_particle(gc, elem_props, open_flag, type_name, 1)
            else:
                warn(type_name + " : не найдена группа " + str(grp.get("ref")) + " — её свойства в пакет не попали")
        else:
            collect_particle(particle, elem_props, open_flag, type_name, 0)
    is_open = open_flag[0]
    for a in xchildren(body, "attribute"):
        node.children.append(build_property(a, True))
    # xs:attributeGroup раскрываем по ссылке
    for ag in xchildren(body, "attributeGroup"):
        g = resolve_group(ag, "attributeGroup")
        if g is not None:
            for a in xchildren(g, "attribute"):
                node.children.append(build_property(a, True))
        else:
            warn("Не найдена группа атрибутов " + str(ag.get("ref")) + " — её атрибуты в пакет не попали")
    node.children.extend(elem_props)
    if xchildren(body, "anyAttribute"):
        is_open = True

    m_order = MA(ct, "order")
    if m_order is not None:
        reorder_properties(node, m_order.split("|"))

    set_type_flags(node, ct, is_open, cho)


# ── build the package tree ───────────────────────────────────

pkg_node = Node("package")
add_attr(pkg_node, "targetNamespace", target_ns)

efq_mirror = MA(schema, "elementFormQualified")
afq_mirror = MA(schema, "attributeFormQualified")
efd = schema.get("elementFormDefault")
afd = schema.get("attributeFormDefault")
if efq_mirror is not None:
    add_attr(pkg_node, "elementFormQualified", efq_mirror)
elif efd is not None:
    add_attr(pkg_node, "elementFormQualified", "true" if efd == "qualified" else "false")
if afq_mirror is not None:
    add_attr(pkg_node, "attributeFormQualified", afq_mirror)
elif afd is not None:
    add_attr(pkg_node, "attributeFormQualified", "true" if afd == "qualified" else "false")

meta_name = meta_comment = None
meta_synonym = []
ann = xfirst(schema, "annotation")
if ann is not None:
    appinfo = xfirst(ann, "appinfo")
    if appinfo is not None:
        for pk in appinfo:
            if not isinstance(pk.tag, str) or etree.QName(pk).namespace != XDTO_NS:
                continue
            for f in pk:
                if not isinstance(f.tag, str):
                    continue
                ln = local(f)
                if ln == "name":
                    meta_name = f.text or ""
                elif ln == "comment":
                    meta_comment = f.text or ""
                elif ln == "synonym":
                    meta_synonym.append({"Lang": f.get("lang") or "", "Content": f.text or ""})

# Реестр глобальных групп — нужен до обхода, чтобы раскрывать ссылки
for node in schema:
    if not isinstance(node.tag, str) or etree.QName(node).namespace != XS_NS:
        continue
    nm = node.get("name")
    if local(node) == "group" and nm:
        GROUPS[nm] = node
    if local(node) == "attributeGroup" and nm:
        ATTR_GROUPS[nm] = node

# Конструкции XSD, которым в модели XDTO нет соответствия
for sg in schema.iter():
    if isinstance(sg.tag, str) and local(sg) == "element" and sg.get("substitutionGroup"):
        warn("Подстановочные группы (substitutionGroup) не поддерживаются моделью XDTO — объявление "
             + str(sg.get("name")) + " сохранено как обычное")
for idc in ("key", "keyref", "unique"):
    if any(isinstance(e.tag, str) and local(e) == idc for e in schema.iter()):
        warn("Ограничения целостности (xs:" + idc + ") в модели XDTO не хранятся — отброшены")
if any(isinstance(e.tag, str) and local(e) == "redefine" for e in schema.iter()):
    warn("xs:redefine не поддерживается — переопределения проигнорированы")
if any(isinstance(e.tag, str) and local(e) == "include" for e in schema.iter()):
    warn("xs:include проигнорирован: модель XDTO разрешает зависимости только по namespace. "
         "Соберите включаемую схему отдельным пакетом и добавьте <xs:import>")

for node in schema:
    if not isinstance(node.tag, str) or etree.QName(node).namespace != XS_NS:
        continue
    ln = local(node)
    if ln == "import":
        n = Node("import")
        add_attr(n, "namespace", node.get("namespace"))
        pkg_node.children.append(n)
    elif ln in ("annotation", "include", "group", "attributeGroup", "notation"):
        continue
    elif ln == "element":
        pkg_node.children.append(build_property(node, False))
    elif ln == "attribute":
        pkg_node.children.append(build_property(node, True))
    elif ln == "simpleType":
        n = Node("valueType")
        add_attr(n, "name", node.get("name"))
        fill_simple_type(n, node)
        pkg_node.children.append(n)
    elif ln == "complexType":
        n = Node("objectType")
        add_attr(n, "name", node.get("name"))
        fill_complex_type(n, node)
        pkg_node.children.append(n)

# ── serialize Package.bin ────────────────────────────────────

# Модель XDTO требует строгой последовательности элементов верхнего уровня:
# import → property → valueType → objectType. Порядок объявлений в XSD произвольный,
# поэтому пересортировываем — иначе платформа отвергает пакет с «Ошибка преобразования
# данных XDTO». Все 760 пакетов корпуса этому порядку удовлетворяют.
TOP_ORDER = ["import", "property", "valueType", "objectType"]
pkg_node.children = (
    [c for t in TOP_ORDER for c in pkg_node.children if c.tag == t]
    + [c for c in pkg_node.children if c.tag not in TOP_ORDER]
)

root_attr_text = "".join(f' {a["name"]}="{esc(a["value"])}"' for a in sort_attrs(pkg_node))
out.append(f'<package xmlns="{XDTO_NS}" xmlns:xs="{XS_NS}" xmlns:xsi="{XSI_NS}"{root_attr_text}>\r\n')
for c in pkg_node.children:
    serialize_node(c, 2, {})
out.append("</package>")

bin_text = "".join(out)

# ── resolve the package name ─────────────────────────────────

name = args.Name or meta_name or default_name
name = re.sub(r"[^\wЀ-ӿ]", "_", name, flags=re.UNICODE)
if re.match(r"^\d", name):
    name = "_" + name

assert_edit_allowed(args.OutputDir, "editable")

format_version = detect_format_version(os.path.abspath(args.OutputDir))

# Объявления пространств имён — одной переменной: место эмиссии её только подставляет.
# Правки шапки (как xmlns:pal в формате 2.21) делаются здесь, в одном месте.
xmlns_decl = (
    'xmlns="http://v8.1c.ru/8.3/MDClasses"'
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
)

# 2.21 (8.5) добавила в шапку пространство палитры — ради <Color> у значений перечисления.
# Вставляем НА МЕСТО (после lf, перед style): платформа держит объявления по алфавиту,
# дописать в конец нельзя.
if format_rank(format_version) >= 221:
    xmlns_decl = xmlns_decl.replace(
        ' xmlns:style=',
        ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')

pkg_root = os.path.join(args.OutputDir, "XDTOPackages")
pkg_dir = os.path.join(pkg_root, name)
ext_dir = os.path.join(pkg_dir, "Ext")
md_file = os.path.join(pkg_root, name + ".xml")
bin_file = os.path.join(ext_dir, "Package.bin")

if os.path.exists(bin_file) and not args.Force:
    print(f"Пакет уже существует: {bin_file}. Используйте -Force для перезаписи.", file=sys.stderr)
    sys.exit(1)
os.makedirs(ext_dir, exist_ok=True)

with open(bin_file, "wb") as f:
    f.write(b"\xef\xbb\xbf" + bin_text.encode("utf-8"))

# ── metadata object file ─────────────────────────────────────

if not args.Synonym and meta_synonym:
    syn_items = meta_synonym
elif args.Synonym:
    syn_items = [{"Lang": "ru", "Content": args.Synonym}]
else:
    syn_items = [{"Lang": "ru", "Content": name}]
comment = args.Comment or meta_comment or ""

md_lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    f'<MetaDataObject {xmlns_decl} version="{format_version}">',
    f'\t<XDTOPackage uuid="{uuid.uuid4()}">',
    "\t\t<Properties>",
    f"\t\t\t<Name>{esc_text(name)}</Name>",
    "\t\t\t<Synonym>",
]
for s in syn_items:
    md_lines += [
        "\t\t\t\t<v8:item>",
        f'\t\t\t\t\t<v8:lang>{esc_text(s["Lang"])}</v8:lang>',
        f'\t\t\t\t\t<v8:content>{esc_text(s["Content"])}</v8:content>',
        "\t\t\t\t</v8:item>",
    ]
md_lines.append("\t\t\t</Synonym>")
md_lines.append(f"\t\t\t<Comment>{esc_text(comment)}</Comment>" if comment else "\t\t\t<Comment/>")
md_lines.append(f"\t\t\t<Namespace>{esc_text(target_ns)}</Namespace>")
md_lines += ["\t\t</Properties>", "\t</XDTOPackage>", "</MetaDataObject>"]

with open(md_file, "wb") as f:
    f.write(b"\xef\xbb\xbf" + "\r\n".join(md_lines).encode("utf-8"))

# ── register in Configuration.xml ────────────────────────────

# Ранняя диагностика: отказ платформы при db-update дешевле поймать на сборке
xdto_root_dir = os.path.join(args.OutputDir, "XDTOPackages")
declared_imports = [a["value"] for c in pkg_node.children if c.tag == "import"
                    for a in c.attrs if a["name"] == "namespace"]
if declared_imports and os.path.isdir(xdto_root_dir):
    known_ns = set()
    for other in sorted(os.listdir(xdto_root_dir)):
        ob = os.path.join(xdto_root_dir, other, "Ext", "Package.bin")
        if not os.path.exists(ob):
            continue
        try:
            known_ns.add(_parse_xml(ob).getroot().get("targetNamespace"))
        except Exception:  # noqa: BLE001
            pass
    for imp in declared_imports:
        if imp not in known_ns and imp not in PLATFORM_NS:
            warn(f'Импорт "{imp}" не разрешается: пакета с таким namespace в конфигурации нет. '
                 "Платформа отвергнет пакет при обновлении — соберите зависимость первой")

def esc_xml_text(s):
    # Эскейп ТЕКСТА элемента: только & < > (кавычки в тексте 1С держит raw).
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def write_utf8_bom(path, content):
    # newline='' — без трансляции: иначе текстовый режим Python дал бы CRLF на Windows
    # и LF на macOS, то есть вывод навыка зависел бы от ОС.
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


def get_new_object_position(cfg_dir):
    """Куда навык ставит новую запись в <ChildObjects> — настройка newObjectPosition.

    databases[].newObjectPosition базы, чей configSrc охватывает каталог родительского XML,
    иначе корневое поле, иначе end. Значения: end — после последнего объекта того же вида
    (так дописывает Конфигуратор); byName — по имени среди объектов того же вида.
    Файл ищем от рабочего каталога вверх, каталог конфигурации — запасной путь: так же
    его ищут support-guard и группа db-*, а скрипт навыка зовут по абсолютному пути, и cwd
    остаётся рабочим каталогом проекта.
    configSrc считается от каталога .v8-project.json, как задокументировано в
    docs/v8-project-guide.md. Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(os.path.abspath(cfg_dir or "."))
        if not pj:
            return "end"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        proj_dir = os.path.dirname(pj)
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir or ".")).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src and db.get("newObjectPosition"):
                src_full = os.path.normcase(os.path.abspath(os.path.join(proj_dir, src))).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    return "byName" if str(db["newObjectPosition"]).lower() == "byname" else "end"
        if str(proj.get("newObjectPosition") or "").lower() == "byname":
            return "byName"
        return "end"
    except Exception:
        return "end"


def is_order_sensitive_type(type_name):
    """Виды, у которых порядок в дереве несёт смысл: автоматически их не упорядочиваем.

    CommonAttribute — исключение самого стандарта (#std467): у общих реквизитов-разделителей
    порядок в дереве задаёт порядок установки параметров сеанса. Subsystem и CommandGroup:
    пока они не перечислены в <SubsystemsOrder> / <GroupsOrder> файла Ext/CommandInterface.xml,
    порядок дерева задаёт порядок в интерфейсе, а платформа эти списки сама не заводит
    (в выгрузке ACC вне GroupsOrder 15 живых групп из 39). Language исключён из осторожности,
    без замера: языков обычно один-два, и в типовых их порядок не алфавитный.
    Явно названный вид сортируется в любом случае.
    Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    return type_name in ("CommonAttribute", "Subsystem", "CommandGroup", "Language")


def compare_metadata_names(a, b):
    """Порядок имён объектов метаданных, как в дереве Конфигуратора.

    Ключ — пары «ранг+символ»: регистр не учитывается, подчёркивание раньше цифр, цифры раньше
    букв, буквы по кодам (латиница раньше кириллицы), ё на месте е. Культурные таблицы не
    используются — они разные на разных ОС и в разных рантаймах, а так оба порта сравнивают
    одинаково везде. Равные ключи разводит ordinal-сравнение исходных строк.
    Возвращает -1 | 0 | 1. Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    keys = []
    for name in (a, b):
        parts = []
        for ch in name.lower():
            if ch == "ё":
                ch = "е"
            if ch.isdigit():
                parts.append("1" + ch)
            elif ch.isalpha():
                parts.append("2" + ch)
            else:
                parts.append("0" + ch)
        keys.append("".join(parts))
    if keys[0] != keys[1]:
        return -1 if keys[0] < keys[1] else 1
    if a != b:
        return -1 if a < b else 1
    return 0


# Канонический порядок видов в <ChildObjects> — эталон в docs/1c-configuration-spec.md,
# таблица «Порядок типов в ChildObjects». Нужен, чтобы новая группа вида вставала на своё
# место: иначе платформа переставит её при первой же выгрузке и даст диф на ровном месте.
# Реестр карт: tests/skills/check-type-maps.mjs.
CHILD_OBJECT_TYPES = [
    'Language', 'Subsystem', 'StyleItem', 'Style',
    'CommonPicture', 'SessionParameter', 'Role', 'CommonTemplate',
    'FilterCriterion', 'CommonModule', 'CommonAttribute', 'ExchangePlan',
    'XDTOPackage', 'WebService', 'HTTPService', 'WSReference',
    'EventSubscription', 'ScheduledJob', 'SettingsStorage', 'FunctionalOption',
    'FunctionalOptionsParameter', 'DefinedType', 'Bot', 'PaletteColor', 'CommonCommand', 'CommandGroup',
    'Constant', 'CommonForm', 'Catalog', 'Document',
    'DocumentNumerator', 'Sequence', 'DocumentJournal', 'Enum',
    'Report', 'DataProcessor', 'InformationRegister', 'AccumulationRegister',
    'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'AccountingRegister',
    'ChartOfCalculationTypes', 'CalculationRegister',
    'BusinessProcess', 'Task', 'IntegrationService',
]


def register_in_childobjects(parent_xml_path, parent_tag, child_tag, child_name):
    """Регистрация объекта в <ChildObjects> родительского XML.

    Общая реализация: эталон — meta-compile, копии — role-compile, xdto-compile.
    Реестр семьи: tests/skills/check-inline-drift.mjs.
    Возвращает исход: added | already | no-childobj | no-config.
    """
    if not os.path.isfile(parent_xml_path):
        return 'no-config'

    # Read raw content, preserving BOM/EOL byte-for-byte (newline='' => no translation)
    with open(parent_xml_path, 'r', encoding='utf-8-sig', newline='') as f:
        config_content = f.read()

    ns = 'http://v8.1c.ru/8.3/MDClasses'
    # ET is used ONLY read-only here: to locate ChildObjects and detect a duplicate.
    # We deliberately do NOT re-serialize Configuration.xml with ElementTree.write():
    # it drops every xmlns declaration used only inside attribute VALUES (e.g.
    # xsi:type="app:ApplicationUsePurpose" in UsePurposes) because ET never sees such
    # prefixes in element/attribute names. The dropped declaration makes XDTO read the
    # value as anyType and Designer refuses to load the file (issue #38). Registration is
    # therefore done by raw-text insertion, preserving BOM, EOL and all namespaces
    # byte-for-byte (same approach as subsystem-compile).
    tree = ET.parse(parent_xml_path)
    root = tree.getroot()

    child_objects = root.find(f'{{{ns}}}{parent_tag}/{{{ns}}}ChildObjects')
    if child_objects is None:
        # Try direct path
        parent_elem = root.find(f'{{{ns}}}{parent_tag}')
        if parent_elem is not None:
            child_objects = parent_elem.find(f'{{{ns}}}ChildObjects')

    if child_objects is None:
        return 'no-childobj'

    existing = child_objects.findall(f'{{{ns}}}{child_tag}')
    if any((e.text or '').strip() == child_name for e in existing):
        return 'already'

    eol = '\r\n' if '\r\n' in config_content else '\n'
    entry = f'<{child_tag}>{esc_xml_text(child_name)}</{child_tag}>'

    block = re.search(r'<ChildObjects\s*>.*?</ChildObjects>', config_content, re.S)
    if block is None:
        # Empty self-closing <ChildObjects/> => open it with the first entry.
        empty = re.search(r'<ChildObjects\s*/>', config_content)
        if empty is None:
            return 'no-childobj'
        replacement = f'<ChildObjects>{eol}\t\t\t{entry}{eol}\t\t</ChildObjects>'
        new_content = config_content[:empty.start()] + replacement + config_content[empty.end():]
        write_utf8_bom(parent_xml_path, new_content)
        return 'added'

    # byName: перед первым объектом того же вида, чьё имя больше нового.
    # Виды с осмысленным порядком в дереве пропускаем — см. is_order_sensitive_type.
    if (not is_order_sensitive_type(child_tag)
            and get_new_object_position(os.path.dirname(os.path.abspath(parent_xml_path))) == 'byName'):
        line_rx = re.compile(rf'(?m)^([ \t]*)<{child_tag}>([^<]*)</{child_tag}>')
        for m in line_rx.finditer(config_content, block.start(), block.end()):
            if compare_metadata_names(m.group(2), child_name) > 0:
                new_content = (config_content[:m.start()]
                               + f'{m.group(1)}{entry}{eol}'
                               + config_content[m.start():])
                write_utf8_bom(parent_xml_path, new_content)
                return 'added'

    close_same = f'</{child_tag}>'
    last_same = config_content.rfind(close_same, block.start(), block.end())
    if last_same != -1:
        # After the last element of the same type (keeps them grouped).
        insert_at = last_same + len(close_same)
        new_content = (config_content[:insert_at]
                       + f'{eol}\t\t\t{entry}'
                       + config_content[insert_at:])
    else:
        # Группы своего вида ещё нет: ставим её в канонический порядок видов — перед первой
        # группой вида старше по CHILD_OBJECT_TYPES. Дописать в конец блока нельзя: платформа
        # переставит группу при первой же выгрузке и даст диф на ровном месте.
        anchor = None
        if child_tag in CHILD_OBJECT_TYPES:
            own_idx = CHILD_OBJECT_TYPES.index(child_tag)
            type_rx = re.compile(r'(?m)^([ \t]*)<(\w+)>[^<]*</\2>')
            for m in type_rx.finditer(config_content, block.start(), block.end()):
                other = m.group(2)
                if other in CHILD_OBJECT_TYPES and CHILD_OBJECT_TYPES.index(other) > own_idx:
                    anchor = m
                    break
        if anchor is not None:
            new_content = (config_content[:anchor.start()]
                           + f'{anchor.group(1)}{entry}{eol}'
                           + config_content[anchor.start():])
        else:
            # Видов старше в файле нет — новая строка перед </ChildObjects>,
            # отступ закрывающего тега переиспользуется.
            close_at = config_content.rfind('</ChildObjects>', block.start(), block.end())
            new_content = (config_content[:close_at]
                           + f'\t{entry}{eol}\t\t'
                           + config_content[close_at:])
    write_utf8_bom(parent_xml_path, new_content)
    return 'added'


config_xml = os.path.join(args.OutputDir, "Configuration.xml")
reg_result = register_in_childobjects(config_xml, "Configuration", "XDTOPackage", name)

type_count = sum(1 for c in pkg_node.children if c.tag in ("objectType", "valueType"))
print(f"✓ Пакет XDTO собран: {name}")
print(f"  Namespace: {target_ns}")
print(f"  Типов: {type_count}")
print(f"  Файлы: XDTOPackages/{name}.xml, XDTOPackages/{name}/Ext/Package.bin")
if warnings_list:
    print("")
    print("Предупреждения (" + str(len(warnings_list)) +
          ") — конструкции XSD без точного соответствия в модели XDTO:")
    for w in warnings_list:
        print("  ! " + w)
    print("")
if reg_result == "added":
    print(f"  Configuration.xml: <XDTOPackage>{name}</XDTOPackage> добавлен в ChildObjects")
elif reg_result == "already":
    print(f"  Configuration.xml: <XDTOPackage>{name}</XDTOPackage> уже зарегистрирован")
elif reg_result == "no-childobj":
    print("ПРЕДУПРЕЖДЕНИЕ: Configuration.xml найден, но <ChildObjects> не найден", file=sys.stderr)
else:
    print("  Configuration.xml не найден — регистрация пропущена")
