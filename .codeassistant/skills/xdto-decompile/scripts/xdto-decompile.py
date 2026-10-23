# xdto-decompile v1.3 — Convert 1C XDTO package to XML Schema (XSD) (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import re
import sys

from lxml import etree

# newline="" — иначе Windows транслирует \n и CRLF схемы удваивается в \r\r\n
sys.stdout.reconfigure(encoding="utf-8", newline="")
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
V8_NS = "http://v8.1c.ru/8.1/data/core"

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-PackagePath", "-Path", required=True)
parser.add_argument("-OutFile", default="")
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

# ── resolve paths ────────────────────────────────────────────

package_path = args.PackagePath
bin_path = None
md_path = None

if os.path.isfile(package_path):
    if os.path.basename(package_path) == "Package.bin":
        bin_path = package_path
        pkg_dir = os.path.dirname(os.path.dirname(package_path))
        if os.path.exists(pkg_dir + ".xml"):
            md_path = pkg_dir + ".xml"
    elif package_path.endswith(".xml"):
        md_path = package_path
        stem = os.path.join(os.path.dirname(package_path),
                            os.path.splitext(os.path.basename(package_path))[0])
        c = os.path.join(stem, "Ext", "Package.bin")
        if os.path.exists(c):
            bin_path = c
elif os.path.isdir(package_path):
    c = os.path.join(package_path, "Ext", "Package.bin")
    if os.path.exists(c):
        bin_path = c
        m = package_path.rstrip("\\/") + ".xml"
        if os.path.exists(m):
            md_path = m

if not bin_path:
    print(f"Не найден Ext/Package.bin для пути: {package_path}")
    sys.exit(1)

doc = _parse_xml(bin_path)
pkg = doc.getroot()


def local(el):
    return etree.QName(el).localname


if local(pkg) != "package":
    print(f"Ожидался корневой <package>, получен <{local(pkg)}>")
    sys.exit(1)

target_ns = pkg.get("targetNamespace")

# ── namespace -> prefix map for the emitted schema ───────────

ns_prefix = {XS_NS: "xs"}
if target_ns:
    ns_prefix[target_ns] = "tns"

imports = []
for imp in pkg:
    if isinstance(imp.tag, str) and local(imp) == "import":
        ns = imp.get("namespace")
        imports.append(ns)
        if ns not in ns_prefix:
            ns_prefix[ns] = "ns" + str(len(ns_prefix))


def register_ns(ns):
    if ns and ns not in ns_prefix:
        ns_prefix[ns] = "ns" + str(len(ns_prefix))


# ── output buffer ────────────────────────────────────────────

lines = []


def X(line):
    lines.append(line)


def esc(s):
    if s is None:
        return ""
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def esc_text(s):
    if s is None:
        return ""
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── QName conversion: bin prefix -> schema prefix ────────────

def convert_qname(el, qname):
    if not qname:
        return None
    # Нотация Кларка {ns}local — так записаны почти все memberTypes
    if qname.startswith("{"):
        close = qname.find("}")
        if close > 0:
            ns = qname[1:close]
            loc = qname[close + 1:]
            if not ns:
                return loc
            register_ns(ns)
            return f"{ns_prefix[ns]}:{loc}"
    parts = qname.split(":")
    if len(parts) == 2:
        ns = el.nsmap.get(parts[0])
        loc = parts[1]
    else:
        ns = el.nsmap.get(None)
        loc = parts[0]
    if not ns:
        return qname
    register_ns(ns)
    return f"{ns_prefix[ns]}:{loc}"


def convert_qname_list(el, lst):
    if not lst:
        return None
    return " ".join(convert_qname(el, q) for q in lst.split() if q)


def attrs(pairs):
    out = ""
    for i in range(0, len(pairs), 2):
        v = pairs[i + 1]
        if v is not None:
            out += f' {pairs[i]}="{esc(v)}"'
    return out


# ── xdto: mirror attributes ──────────────────────────────────

state = {"uses_xdto": False}


def mirror(name, value):
    if value is None:
        return ""
    state["uses_xdto"] = True
    return f' xdto:{name}="{esc(value)}"'


DNPM = re.compile(r"^d\d+p\d+$")


def ns_decls_of(el):
    """Локальные объявления xmlns на самом узле, как (префикс, uri)."""
    parent_map = el.getparent().nsmap if el.getparent() is not None else {}
    for px, uri in el.nsmap.items():
        if px is None:
            continue
        if parent_map.get(px) == uri:
            continue
        yield px, uri


def mirror_prefix(el):
    # Обычно префиксы генерируются схемой dNpM, но изредка узел несёт осмысленный
    # префикс (например dcsset) — его надо сохранить, иначе round-trip не сойдётся.
    for px, _uri in ns_decls_of(el):
        if DNPM.match(px):
            continue
        return mirror("prefix", px)
    return ""


FACET_ATTRS = ["length", "minLength", "maxLength", "totalDigits", "fractionDigits",
               "minInclusive", "maxInclusive", "minExclusive", "maxExclusive", "whiteSpace"]


def emit_facets(el, indent):
    for f in FACET_ATTRS:
        v = el.get(f)
        if v is not None:
            X(f'{indent}<xs:{f} value="{esc(v)}"/>')
    for child in el:
        if not isinstance(child.tag, str):
            continue
        ln = local(child)
        if ln == "pattern":
            X(f'{indent}<xs:pattern value="{esc(child.text or "")}"/>')
        elif ln == "enumeration":
            xsi_type = child.get(f"{{{XSI_NS}}}type")
            m = mirror("type", convert_qname(child, xsi_type)) if xsi_type else ""
            X(f'{indent}<xs:enumeration value="{esc(child.text or "")}"{m}/>')


def has_simple_content(el):
    for c in el:
        if isinstance(c.tag, str) and local(c) in ("pattern", "enumeration"):
            return True
    return any(el.get(f) is not None for f in FACET_ATTRS)


# ── simple type body (valueType / typeDef xsi:type=ValueType) ─

def emit_simple_type_body(el, indent):
    variety = el.get("variety")
    base = convert_qname(el, el.get("base"))
    item_type = convert_qname(el, el.get("itemType"))
    member_types = convert_qname_list(el, el.get("memberTypes"))

    mv = mirror("variety", variety)

    raw_members = el.get("memberTypes")
    if raw_members is not None and not raw_members.startswith("{"):
        mv += mirror("memberTypesForm", "prefixed")
    # При нотации Кларка объявление xmlns:dNpM иногда присутствует, иногда нет —
    # из значения это не выводится (зависит от состояния сериализатора), зеркалим факт
    if raw_members is not None and raw_members.startswith("{"):
        for px, uri in ns_decls_of(el):
            if DNPM.match(px):
                mv += mirror("declareNs", uri)
                break

    if variety == "List" or item_type:
        X(f'{indent}<xs:list{attrs(["itemType", item_type])}{mv}/>')
        return
    if variety == "Union" or member_types:
        anon = [c for c in el if isinstance(c.tag, str) and local(c) == "typeDef"]
        if not anon:
            X(f'{indent}<xs:union{attrs(["memberTypes", member_types])}{mv}/>')
        else:
            X(f'{indent}<xs:union{attrs(["memberTypes", member_types])}{mv}>')
            for c in anon:
                X(f"{indent}\t<xs:simpleType>")
                emit_simple_type_body(c, indent + "\t\t")
                X(f"{indent}\t</xs:simpleType>")
            X(f"{indent}</xs:union>")
        return

    # Базовый тип может быть задан не атрибутом base, а вложенным анонимным typeDef
    anon_base = next((c for c in el if isinstance(c.tag, str) and local(c) == "typeDef"), None)

    if has_simple_content(el) or anon_base is not None:
        X(f'{indent}<xs:restriction{attrs(["base", base])}{mv}>')
        if anon_base is not None:
            X(f"{indent}\t<xs:simpleType>")
            emit_simple_type_body(anon_base, indent + "\t\t")
            X(f"{indent}\t</xs:simpleType>")
        emit_facets(el, indent + "\t")
        X(f"{indent}</xs:restriction>")
    else:
        X(f'{indent}<xs:restriction{attrs(["base", base])}{mv}/>')


# ── property classification ──────────────────────────────────

def prop_form(p):
    f = p.get("form")
    return "Element" if f is None else f


def anon_type_def(p):
    return next((c for c in p if isinstance(c.tag, str) and local(c) == "typeDef"), None)


# ── property emission ────────────────────────────────────────

def emit_property(p, indent):
    form = prop_form(p)
    name = p.get("name")
    type_ = convert_qname(p, p.get("type"))
    ref = convert_qname(p, p.get("ref"))
    local_name = p.get("localName")
    lower = p.get("lowerBound")
    upper = p.get("upperBound")
    nill = p.get("nillable")
    default = p.get("default")
    fixed = p.get("fixed")
    # В модели fixed — булев флаг, значение лежит в default; в XSD наоборот:
    # fixed="V" несёт само значение. Переводим, а не копируем.
    def_out, fix_out, fix_mirror = default, None, ""
    if fixed == "true" and default is not None:
        fix_out, def_out = default, None
    elif fixed is not None:
        fix_mirror = mirror("fixed", fixed)
    anon = anon_type_def(p)
    qual = p.get(f"{{{XDTO_NS}}}qualified")

    min_occurs = lower
    max_occurs = None
    if upper is not None:
        max_occurs = "unbounded" if upper == "-1" else upper

    xml_name = local_name if local_name is not None else name
    mirror_name = mirror("name", name) if local_name is not None else ""

    m = ""
    if form == "Attribute":
        if qual is not None:
            m += mirror("qualified", qual)
        if nill is not None:
            m += mirror("nillable", nill)
        if lower is not None:
            m += mirror("lowerBound", lower)
        if upper is not None:
            m += mirror("upperBound", upper)
        m += mirror_name
        m += fix_mirror
        body = attrs(["name", xml_name, "ref", ref, "type", type_, "default", def_out, "fixed", fix_out])
        if anon is not None:
            X(f"{indent}<xs:attribute{body}{m}>")
            X(f"{indent}\t<xs:simpleType>")
            emit_simple_type_body(anon, indent + "\t\t")
            X(f"{indent}\t</xs:simpleType>")
            X(f"{indent}</xs:attribute>")
        else:
            X(f"{indent}<xs:attribute{body}{m}/>")
        return

    if form == "Text":
        # handled by the owning complexType (xs:simpleContent)
        return

    if p.get("form") is not None:
        m += mirror("form", form)
    if qual is not None:
        m += mirror("qualified", qual)
    m += mirror_name
    m += mirror_prefix(p)
    m += fix_mirror

    body = attrs(["name", xml_name, "ref", ref, "type", type_,
                  "minOccurs", min_occurs, "maxOccurs", max_occurs,
                  "nillable", nill, "default", def_out, "fixed", fix_out])

    if anon is not None:
        X(f"{indent}<xs:element{body}{m}>")
        if anon.get(f"{{{XSI_NS}}}type") == "ObjectType":
            anon_base = convert_qname(anon, anon.get("base"))
            if anon_base:
                X(f"{indent}\t<xs:complexType{complex_type_attrs(anon)}>")
                X(f"{indent}\t\t<xs:complexContent>")
                X(f'{indent}\t\t\t<xs:extension{attrs(["base", anon_base])}>')
                emit_complex_type_body(anon, indent + "\t\t\t\t")
                X(f"{indent}\t\t\t</xs:extension>")
                X(f"{indent}\t\t</xs:complexContent>")
                X(f"{indent}\t</xs:complexType>")
            else:
                X(f"{indent}\t<xs:complexType{complex_type_attrs(anon)}>")
                emit_complex_type_body(anon, indent + "\t\t")
                X(f"{indent}\t</xs:complexType>")
        else:
            X(f"{indent}\t<xs:simpleType>")
            emit_simple_type_body(anon, indent + "\t\t")
            X(f"{indent}\t</xs:simpleType>")
        X(f"{indent}</xs:element>")
    else:
        X(f"{indent}<xs:element{body}{m}/>")


# ── complex type body ────────────────────────────────────────

def emit_complex_type_body(el, indent):
    open_ = el.get("open")
    ordered = el.get("ordered")

    props = [c for c in el if isinstance(c.tag, str) and local(c) == "property"]
    elems, attr_props, text = [], [], None
    for p in props:
        f = prop_form(p)
        if f == "Attribute":
            attr_props.append(p)
        elif f == "Text":
            text = p
        else:
            elems.append(p)

    if text is not None:
        t_type = convert_qname(text, text.get("type"))
        tm = ""
        t_name = text.get("name")
        if t_name != "__content":
            tm += mirror("textName", t_name)
        for extra in ("lowerBound", "upperBound", "nillable"):
            v = text.get(extra)
            if v is not None:
                tm += mirror("text" + extra, v)
        X(f"{indent}<xs:simpleContent>")
        X(f'{indent}\t<xs:extension{attrs(["base", t_type])}{tm}>')
        for a in attr_props:
            emit_property(a, indent + "\t\t")
        X(f"{indent}\t</xs:extension>")
        X(f"{indent}</xs:simpleContent>")
        return

    particle_tag = "xs:choice" if ordered == "false" else "xs:sequence"
    if elems or open_ == "true":
        X(f"{indent}<{particle_tag}>")
        for e in elems:
            emit_property(e, indent + "\t")
        if open_ == "true":
            X(f'{indent}\t<xs:any namespace="##any" processContents="lax" minOccurs="0" maxOccurs="unbounded"/>')
        X(f"{indent}</{particle_tag}>")

    for a in attr_props:
        emit_property(a, indent)
    if open_ == "true":
        X(f'{indent}<xs:anyAttribute namespace="##any" processContents="lax"/>')


def complex_type_attrs(el):
    open_ = el.get("open")
    ordered = el.get("ordered")
    sequenced = el.get("sequenced")
    abstract = el.get("abstract")
    mixed = el.get("mixed")

    out = ""
    if abstract == "true":
        out += ' abstract="true"'
    elif abstract is not None:
        out += mirror("abstract", abstract)
    if mixed == "true":
        out += ' mixed="true"'
    elif mixed is not None:
        out += mirror("mixed", mixed)

    # XSD требует объявлять атрибуты после частицы, поэтому исходный порядок свойств
    # восстановим как «сначала form=Attribute, потом остальные» — верно для 96.5% типов
    order, kinds = [], []
    for c in el:
        if not isinstance(c.tag, str) or local(c) != "property":
            continue
        nm = c.get("name")
        if nm is None:
            nm = "@" + (c.get("ref") or "").split(":")[-1]
        order.append(nm)
        kinds.append(0 if prop_form(c) == "Attribute" else 1)
    if len(order) > 1:
        natural = all(kinds[i] >= kinds[i - 1] for i in range(1, len(kinds)))
        if not natural:
            out += mirror("order", "|".join(order))

    if open_ is not None and open_ != "true":
        out += mirror("open", open_)
    if ordered is not None and ordered != "false":
        out += mirror("ordered", ordered)
    if sequenced is not None:
        out += mirror("sequenced", sequenced)
    return out


# ── metadata properties ──────────────────────────────────────

meta = None
if md_path and os.path.exists(md_path):
    md = _parse_xml(md_path)
    props_el = md.find(f".//{{{MD_NS}}}XDTOPackage/{{{MD_NS}}}Properties")
    if props_el is not None:
        meta = {"Name": None, "Comment": None, "Synonym": []}
        n = props_el.find(f"{{{MD_NS}}}Name")
        if n is not None:
            meta["Name"] = n.text or ""
        c = props_el.find(f"{{{MD_NS}}}Comment")
        if c is not None:
            meta["Comment"] = c.text or ""
        for item in props_el.iterfind(f"{{{MD_NS}}}Synonym/{{{V8_NS}}}item"):
            lang = item.find(f"{{{V8_NS}}}lang")
            cont = item.find(f"{{{V8_NS}}}content")
            meta["Synonym"].append({
                "Lang": (lang.text or "") if lang is not None else "",
                "Content": (cont.text or "") if cont is not None else "",
            })

# ── emit ─────────────────────────────────────────────────────
# Тело первым: при его генерации регистрируются все использованные пространства
# имён, поэтому корневой элемент может объявить полную карту префиксов.

for node in pkg:
    if not isinstance(node.tag, str):
        continue
    ln = local(node)
    if ln == "import":
        X(f'\t<xs:import namespace="{esc(node.get("namespace"))}"/>')
    elif ln == "property":
        emit_property(node, "\t")
    elif ln == "valueType":
        X(f'\t<xs:simpleType{attrs(["name", node.get("name")])}>')
        emit_simple_type_body(node, "\t\t")
        X("\t</xs:simpleType>")
    elif ln == "objectType":
        name = node.get("name")
        base = convert_qname(node, node.get("base"))
        cta = complex_type_attrs(node)
        if base:
            X(f'\t<xs:complexType{attrs(["name", name])}{cta}>')
            X("\t\t<xs:complexContent>")
            X(f'\t\t\t<xs:extension{attrs(["base", base])}>')
            emit_complex_type_body(node, "\t\t\t\t")
            X("\t\t\t</xs:extension>")
            X("\t\t</xs:complexContent>")
            X("\t</xs:complexType>")
        else:
            has_body = any(isinstance(c.tag, str) for c in node)
            if not has_body and node.get("open") != "true":
                X(f'\t<xs:complexType{attrs(["name", name])}{cta}/>')
            else:
                X(f'\t<xs:complexType{attrs(["name", name])}{cta}>')
                emit_complex_type_body(node, "\t\t")
                X("\t</xs:complexType>")

body_lines = lines
lines = []

# ── schema element ───────────────────────────────────────────

ns_decls = ""
for uri, px in sorted(ns_prefix.items(), key=lambda kv: kv[1]):
    ns_decls += f' xmlns:{px}="{esc(uri)}"'
if state["uses_xdto"]:
    ns_decls += f' xmlns:xdto="{XDTO_NS}"'

schema_attrs = ""
efq = pkg.get("elementFormQualified")
afq = pkg.get("attributeFormQualified")
if efq is not None:
    schema_attrs += f' elementFormDefault="{"qualified" if efq == "true" else "unqualified"}"'
if afq is not None:
    schema_attrs += f' attributeFormDefault="{"qualified" if afq == "true" else "unqualified"}"'

X(f'<xs:schema{ns_decls}{attrs(["targetNamespace", target_ns])}{schema_attrs}>')

if meta:
    X("\t<xs:annotation>")
    X("\t\t<xs:appinfo>")
    X(f'\t\t\t<xdto:package xmlns:xdto="{XDTO_NS}">')
    if meta["Name"] is not None:
        X(f'\t\t\t\t<xdto:name>{esc_text(meta["Name"])}</xdto:name>')
    if meta["Comment"]:
        X(f'\t\t\t\t<xdto:comment>{esc_text(meta["Comment"])}</xdto:comment>')
    for s in meta["Synonym"]:
        X(f'\t\t\t\t<xdto:synonym lang="{esc(s["Lang"])}">{esc_text(s["Content"])}</xdto:synonym>')
    X("\t\t\t</xdto:package>")
    X("\t\t</xs:appinfo>")
    X("\t</xs:annotation>")

lines.extend(body_lines)
X("</xs:schema>")

text = "\r\n".join(lines) + "\r\n"

if args.OutFile:
    d = os.path.dirname(args.OutFile)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(args.OutFile, "wb") as f:
        f.write(b"\xef\xbb\xbf" + text.encode("utf-8"))
    print(f"✓ XSD записана: {args.OutFile}")
    print(f"  targetNamespace: {target_ns}")
else:
    sys.stdout.write(text)
