# xdto-info v1.2 — Analyze 1C XDTO package structure (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import re
import sys

from lxml import etree

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


XS_NS = "http://www.w3.org/2001/XMLSchema"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-PackagePath", "-Path", required=True)
parser.add_argument("-Package", default="")
parser.add_argument("-Namespace", default="")
parser.add_argument("-Name", default="")
parser.add_argument("-Mode", default="auto", choices=["auto", "used-by"])
parser.add_argument("-Depth", type=int, default=1)
parser.add_argument("-RequiredOnly", action="store_true")
parser.add_argument("-Limit", type=int, default=150)
parser.add_argument("-Offset", type=int, default=0)
parser.add_argument("-OutFile", default="")
args = ci_parse_args(parser)

LIMIT, OFFSET, DEPTH = args.Limit, args.Offset, args.Depth

lines = []


def O(line=""):
    lines.append(line)


def flush_output():
    text = "\n".join(lines).rstrip()
    if args.OutFile:
        d = os.path.dirname(args.OutFile)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(args.OutFile, "wb") as f:
            f.write(b"\xef\xbb\xbf" + (text + "\r\n").encode("utf-8"))
        print(f"✓ Записано: {args.OutFile}")
    else:
        print(text)


def die(msg):
    # Отрицательный результат поиска — не исключение: сообщение и код 1,
    # без трассировки
    print(msg)
    sys.exit(1)


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


def local(el):
    return etree.QName(el).localname


# ── resolve path ─────────────────────────────────────────────

package_path = os.path.abspath(args.PackagePath)
if not os.path.exists(package_path):
    die(f"Путь не найден: {package_path}")

config_root = None
direct_pkg_dir = None

if os.path.exists(os.path.join(package_path, "Configuration.xml")):
    config_root = package_path
elif os.path.basename(package_path.rstrip("\\/")) == "XDTOPackages":
    config_root = os.path.dirname(package_path.rstrip("\\/"))
elif os.path.exists(os.path.join(package_path, "Ext", "Package.bin")):
    direct_pkg_dir = package_path
    config_root = os.path.dirname(os.path.dirname(package_path))
elif os.path.isfile(package_path) and os.path.basename(package_path) == "Package.bin":
    direct_pkg_dir = os.path.dirname(os.path.dirname(package_path))
    config_root = os.path.dirname(os.path.dirname(direct_pkg_dir))
elif package_path.endswith(".xml"):
    stem = os.path.join(os.path.dirname(package_path),
                        os.path.splitext(os.path.basename(package_path))[0])
    if os.path.exists(os.path.join(stem, "Ext", "Package.bin")):
        direct_pkg_dir = stem
        config_root = os.path.dirname(os.path.dirname(stem))

if not config_root and not direct_pkg_dir:
    die(f"Не удалось определить пакет или конфигурацию по пути: {package_path}")


# ── package index ────────────────────────────────────────────

class Pkg:
    __slots__ = ("Name", "Dir", "Namespace", "Root", "Imports", "Types", "GlobalProps")


def read_package(pkg_dir):
    b = os.path.join(pkg_dir, "Ext", "Package.bin")
    if not os.path.exists(b):
        return None
    try:
        root = _parse_xml(b).getroot()
    except Exception:  # noqa: BLE001
        return None
    if local(root) != "package":
        return None
    p = Pkg()
    p.Name = os.path.basename(pkg_dir.rstrip("\\/"))
    p.Dir = pkg_dir
    p.Namespace = root.get("targetNamespace")
    p.Root = root
    p.Imports = []
    p.Types = {}
    p.GlobalProps = []
    for n in root:
        if not isinstance(n.tag, str):
            continue
        ln = local(n)
        if ln == "import":
            p.Imports.append(n.get("namespace"))
        elif ln in ("objectType", "valueType"):
            p.Types[n.get("name")] = n
        elif ln == "property":
            p.GlobalProps.append(n)
    return p


packages = []
by_namespace = {}

if config_root and os.path.isdir(os.path.join(config_root, "XDTOPackages")):
    base = os.path.join(config_root, "XDTOPackages")
    for dn in sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d))):
        p = read_package(os.path.join(base, dn))
        if p:
            packages.append(p)
            by_namespace.setdefault(p.Namespace, p)
if direct_pkg_dir and not packages:
    p = read_package(direct_pkg_dir)
    if p:
        packages.append(p)
        by_namespace[p.Namespace] = p
if not packages:
    die(f"Пакеты XDTO не найдены: {package_path}")

# ── type notation: XSD -> 1С ─────────────────────────────────

XS_TO_1C = {
    "string": "Строка", "normalizedString": "Строка", "token": "Строка", "NCName": "Строка",
    "Name": "Строка", "QName": "Строка", "anyURI": "Строка", "language": "Строка",
    "ID": "Строка", "IDREF": "Строка", "NMTOKEN": "Строка",
    "decimal": "Число", "integer": "Число", "int": "Число", "long": "Число", "short": "Число",
    "byte": "Число", "float": "Число", "double": "Число",
    "nonNegativeInteger": "Число", "positiveInteger": "Число", "nonPositiveInteger": "Число",
    "negativeInteger": "Число", "unsignedInt": "Число", "unsignedLong": "Число",
    "unsignedShort": "Число", "unsignedByte": "Число",
    "date": "Дата", "dateTime": "Дата", "time": "Дата",
    "boolean": "Булево",
    "base64Binary": "ДвоичныеДанные", "hexBinary": "ДвоичныеДанные",
    "anyType": "произвольный", "anySimpleType": "произвольный",
}

FACET_NAMES = ["length", "minLength", "maxLength", "totalDigits", "fractionDigits",
               "minInclusive", "maxInclusive", "minExclusive", "maxExclusive"]


def split_ref(el, raw):
    if not raw:
        return None
    if raw.startswith("{"):
        close = raw.find("}")
        if close < 0:
            return None
        return (raw[1:close], raw[close + 1:])
    parts = raw.split(":")
    if len(parts) == 2:
        return (el.nsmap.get(parts[0]), parts[1])
    return (None, parts[0])


def get_facets(t):
    res = {}
    for f in FACET_NAMES:
        v = t.get(f)
        if v:
            res[f] = v
    for c in t:
        if isinstance(c.tag, str) and local(c) == "pattern":
            res["pattern"] = c.text or ""
            break
    return res


def get_enumerations(t):
    return [(c.text or "") for c in t if isinstance(c.tag, str) and local(c) == "enumeration"]


def find_type(q, pkg):
    if not q:
        return None
    ns, loc = q
    target = None
    if not ns or (pkg and ns == pkg.Namespace):
        target = pkg
    elif ns in by_namespace:
        target = by_namespace[ns]
    if not target or loc not in target.Types:
        return None
    return (target.Types[loc], target)


def format_ref_name(q, pkg):
    if not q:
        return ""
    ns, loc = q
    if ns == XS_NS:
        return XS_TO_1C.get(loc, f"xs:{loc}")
    return loc


def resolve_scalar(t, pkg, guard=0):
    acc = {"Base1C": None, "Facets": {}, "Alias": None, "Enum": [], "Kind": "scalar"}
    if guard > 10 or t is None:
        return acc

    variety = t.get("variety")
    if variety == "List":
        it = split_ref(t, t.get("itemType"))
        acc["Kind"] = "list"
        acc["Base1C"] = "список " + (format_ref_name(it, pkg) if it else "значений")
        return acc
    if variety == "Union" or t.get("memberTypes"):
        members = []
        for m in (t.get("memberTypes") or "").split():
            q = split_ref(t, m)
            if q:
                members.append(format_ref_name(q, pkg))
        for c in t:
            if isinstance(c.tag, str) and local(c) == "typeDef":
                members.append(resolve_scalar(c, pkg, guard + 1)["Base1C"])
        acc["Kind"] = "union"
        acc["Base1C"] = "одно из (" + " | ".join(m for m in members if m) + ")"
        return acc

    acc["Facets"] = get_facets(t)
    acc["Enum"] = get_enumerations(t)

    base_q = split_ref(t, t.get("base"))
    anon_base = next((c for c in t if isinstance(c.tag, str) and local(c) == "typeDef"), None)
    if not base_q and anon_base is not None:
        inner = resolve_scalar(anon_base, pkg, guard + 1)
        acc["Base1C"] = inner["Base1C"]
        for k, v in inner["Facets"].items():
            acc["Facets"].setdefault(k, v)
        if inner["Enum"] and not acc["Enum"]:
            acc["Enum"] = inner["Enum"]
        return acc
    if not base_q:
        acc["Base1C"] = "произвольный"
        return acc

    if base_q[0] == XS_NS:
        acc["Base1C"] = XS_TO_1C.get(base_q[1], f"xs:{base_q[1]}")
        return acc

    target = find_type(base_q, pkg)
    if target and local(target[0]) == "valueType":
        inner = resolve_scalar(target[0], target[1], guard + 1)
        acc["Base1C"] = inner["Base1C"]
        for k, v in inner["Facets"].items():
            acc["Facets"].setdefault(k, v)
        if inner["Enum"] and not acc["Enum"]:
            acc["Enum"] = inner["Enum"]
        if not acc["Alias"]:
            acc["Alias"] = base_q[1]
        return acc
    acc["Base1C"] = base_q[1]
    return acc


def format_scalar(res):
    t, f = res["Base1C"], res["Facets"]
    if t == "Строка":
        if "length" in f:
            t = f'Строка({f["length"]})'
        elif "maxLength" in f:
            t = f'Строка({f["maxLength"]})'
    elif t == "Число":
        if "totalDigits" in f:
            t = f'Число({f["totalDigits"]},{f.get("fractionDigits", "0")})'
    return t


def format_notes(res):
    notes = []
    if res["Alias"]:
        notes.append("← " + res["Alias"])
    if "pattern" in res["Facets"]:
        p = res["Facets"]["pattern"]
        if len(p) > 40:
            p = p[:40] + "…"
        notes.append("шаблон " + p)
    for k in ("minInclusive", "maxInclusive", "minExclusive", "maxExclusive"):
        if k in res["Facets"]:
            notes.append(f'{k} {res["Facets"][k]}')
    return notes


# ── property rendering ───────────────────────────────────────

def get_prop_rows(type_el, pkg, depth, indent, seen):
    rows = []
    for p in type_el:
        if not isinstance(p.tag, str) or local(p) != "property":
            continue

        pname = p.get("name")
        if not pname:
            ref_q = split_ref(p, p.get("ref"))
            pname = ref_q[1] if ref_q else "(без имени)"
        lower, upper = p.get("lowerBound"), p.get("upperBound")
        flags = []
        # В модели умолчание lowerBound = 1; помечаем обязательные, как в meta-info
        if lower != "0":
            flags.append("обязательный")
        if upper == "-1":
            flags.append("список")
        elif upper and upper != "1":
            flags.append("до " + upper)
        if p.get("form") == "Text":
            flags.append("значение элемента")

        notes = []
        type_text = ""
        children = None
        child_pkg = pkg
        # Именованный вложенный тип берётся так же, как корневой; окольный путь
        # через свойство владельца нужен только анонимному — имени у него нет
        obj_name = None
        obj_ns = None

        anon = next((c for c in p if isinstance(c.tag, str) and local(c) == "typeDef"), None)

        if anon is not None:
            if anon.get(f"{{{XSI_NS}}}type") == "ObjectType":
                type_text = "объект (анонимный)"
                obj_name = "(анонимный)"
                children = anon   # анонимные раскрываем всегда: смотреть отдельно негде
            else:
                res = resolve_scalar(anon, pkg)
                type_text = format_scalar(res)
                notes += format_notes(res)
                if res["Enum"]:
                    notes.append("значения: " + ", ".join(res["Enum"][:8]))
        else:
            q = split_ref(p, p.get("type"))
            if not q:
                type_text = "произвольный"
            elif q[0] == XS_NS:
                type_text = XS_TO_1C.get(q[1], f"xs:{q[1]}")
            else:
                target = find_type(q, pkg)
                if not target:
                    type_text = "объект " + q[1]
                    notes.append(f"(пакет не найден: {q[0]})")
                elif local(target[0]) == "objectType":
                    type_text = "объект " + q[1]
                    if target[1].Namespace != pkg.Namespace:
                        type_text += " · " + target[1].Name
                    obj_name = q[1]
                    obj_ns = target[1].Namespace
                    children = target[0]
                    child_pkg = target[1]
                else:
                    res = resolve_scalar(target[0], target[1])
                    type_text = format_scalar(res)
                    notes.append("← " + q[1])
                    notes += [n for n in format_notes(res) if not n.startswith("←")]
                    if res["Enum"]:
                        notes.append("значения: " + ", ".join(res["Enum"][:8]))

        rows.append({"Indent": indent, "Name": pname, "Type": type_text,
                     "Flags": flags, "Notes": [n for n in notes if n],
                     "ObjName": obj_name, "ObjNs": obj_ns})

        if children is not None:
            cname = children.get("name")
            key = f"{child_pkg.Namespace}#{cname}"
            is_anon = not cname
            if not is_anon and key in seen:
                rows.append({"Indent": indent + 1, "Name": "(раскрыт выше)", "Type": "",
                             "Flags": [], "Notes": [], "ObjName": None, "ObjNs": None})
            elif is_anon or depth > 1:
                next_seen = set(seen)
                if not is_anon:
                    next_seen.add(key)
                next_depth = depth if is_anon else depth - 1
                rows += get_prop_rows(children, child_pkg, next_depth, indent + 1, next_seen)
    return rows


# Оставить только обязательные свойства. Ребёнок необязательного объекта тоже
# уходит: он лежит под необязательной веткой и заполнять его не обязательно.
def select_required(rows):
    res = []
    cut_from = -1
    for r in rows:
        if cut_from >= 0 and r["Indent"] > cut_from:
            continue
        cut_from = -1
        if "обязательный" not in r["Flags"]:
            cut_from = r["Indent"]
            continue
        res.append(r)
    return res


def write_rows(rows):
    if not rows:
        O("  (нет свойств)")
        return
    shown = rows
    if OFFSET > 0 or len(rows) > LIMIT:
        shown = rows[OFFSET:OFFSET + LIMIT]
    w_name = max((len("  " * r["Indent"] + r["Name"]) for r in shown), default=0)
    w_type = max((len(r["Type"]) for r in shown), default=0)
    for r in shown:
        n = "  " * r["Indent"] + r["Name"]
        line = "  " + n.ljust(w_name + 2) + r["Type"].ljust(w_type + 2)
        if r["Flags"]:
            line += "[" + ", ".join(r["Flags"]) + "]  "
        if r["Notes"]:
            line += ", ".join(r["Notes"])
        O(line.rstrip())
    if len(rows) > len(shown):
        O(f"  … показано {len(shown)} из {len(rows)}; листать через -Offset/-Limit")


# ── modes ────────────────────────────────────────────────────

def show_package_list():
    O(f"=== Пакеты XDTO: {len(packages)} ===")
    O("")
    shown = packages
    if OFFSET > 0 or len(packages) > LIMIT:
        shown = packages[OFFSET:OFFSET + LIMIT]
    wn = max((len(p.Name) for p in shown), default=0)
    for p in shown:
        O("  " + p.Name.ljust(wn + 2) + str(len(p.Types)).rjust(4) + "  " + p.Namespace)
    if len(packages) > len(shown):
        O("")
        O(f"  … показано {len(shown)} из {len(packages)}; листать через -Offset/-Limit")
    O("")
    O("Колонки: имя пакета, число типов, namespace.")
    O("Следующий шаг: -Package <имя> или -Namespace <URI> — состав пакета; "
      "-Name <Тип> — поиск типа по всем пакетам")


def show_package_overview(pkg):
    O(f"=== Пакет XDTO: {pkg.Name} ===")
    O(f"Namespace: {pkg.Namespace}")
    if pkg.Imports:
        O("")
        O(f"Импорты ({len(pkg.Imports)}):")
        for i in pkg.Imports:
            dep = by_namespace[i].Name if i in by_namespace else "(пакет не найден)"
            O(f"  {i}  →  {dep}")
    if not pkg.GlobalProps:
        O("")
        O("Точки входа: нет — пакет не объявляет корневых элементов документа")
    else:
        O("")
        O(f"Точки входа ({len(pkg.GlobalProps)}) — корневые элементы документа:")
        for gp in pkg.GlobalProps:
            q = split_ref(gp, gp.get("type"))
            tn = format_ref_name(q, pkg) if q else "произвольный"
            form = "  (атрибут)" if gp.get("form") == "Attribute" else ""
            O(f'  <{gp.get("name")}>  →  {tn}{form}')
    objs = [k for k in sorted(pkg.Types) if local(pkg.Types[k]) == "objectType"]
    vals = [k for k in sorted(pkg.Types) if local(pkg.Types[k]) == "valueType"]
    if objs:
        O("")
        O(f"Объектные типы ({len(objs)}):")
        for n in objs:
            cnt = sum(1 for c in pkg.Types[n] if isinstance(c.tag, str) and local(c) == "property")
            base = split_ref(pkg.Types[n], pkg.Types[n].get("base"))
            suffix = f"  ← {base[1]}" if base else ""
            O("  " + n.ljust(40) + f"свойств: {cnt}" + suffix)
    if vals:
        O("")
        O(f"Типы значений ({len(vals)}):")
        for n in vals:
            res = resolve_scalar(pkg.Types[n], pkg)
            line = "  " + n.ljust(40) + format_scalar(res)
            if res["Enum"]:
                line += "  значения: " + ", ".join(res["Enum"][:6])
            O(line)
    O("")
    O("Следующий шаг: -Name <Тип> — структура типа для заполнения")


# Легенда едет вместе с выводом, а не живёт в инструкции: показываем только те
# обозначения, которые реально встретились, иначе она сама становится шумом.
def write_legend(rows):
    text = " ".join(r["Type"] + " " + ",".join(r["Flags"]) + " " + ",".join(r["Notes"]) for r in rows)
    items = []
    if "объект " in text:
        items.append("объект X — присвоить вложенный объект XDTO, состав раскрывает -Depth")
    if "←" in text:
        items.append("← Имя — исходный тип из схемы, слева от стрелки развёрнутое значение")
    if "список" in text:
        items.append("список — коллекция, заполняется через .Добавить()")
    if re.search(r"до \d", text):
        items.append("до N — коллекция с ограничением сверху")
    if "значение элемента" in text:
        items.append("значение элемента — собственное значение узла XML")
    if "·" in text:
        items.append("· Пакет — тип объявлен в другом пакете")
    if not items:
        return
    O("")
    O("Обозначения:")
    for i in items:
        O("  " + i)


def show_type(pkg, type_name):
    el = pkg.Types[type_name]
    if local(el) == "valueType":
        res = resolve_scalar(el, pkg)
        O(f"=== Тип значения XDTO: {type_name} ===")
        O(f"Пакет: {pkg.Name} · {pkg.Namespace}")
        O("")
        O("Значение: " + format_scalar(res))
        for n in format_notes(res):
            O("  " + n)
        if res["Enum"]:
            O("")
            O(f'Допустимые значения ({len(res["Enum"])}):')
            for v in res["Enum"]:
                O("  " + v)
        O("")
        O("Создание:")
        # Создать(<Тип>, <Значение>) принимает именно ТипЗначенияXDTO —
        # для объектного типа эта форма неприменима
        O(f'  Значение = ФабрикаXDTO.Создать(ФабрикаXDTO.Тип("{pkg.Namespace}", "{type_name}"), Значение);')
        return

    hdr = f"=== Тип XDTO: {type_name} ==="
    if DEPTH > 1:
        hdr += f"  (глубина {DEPTH})"
    O(hdr)
    O(f"Пакет: {pkg.Name} · {pkg.Namespace}")
    base = split_ref(el, el.get("base"))
    if base:
        O("Наследует: " + base[1])
    if el.get("abstract") == "true":
        O("Абстрактный — создаётся только тип-наследник")
    if el.get("open") == "true":
        O("Открытый — допускает произвольные элементы и атрибуты")
    O("")

    seen = {f"{pkg.Namespace}#{type_name}"}
    rows = get_prop_rows(el, pkg, DEPTH, 0, seen)
    own = [r for r in rows if r["Indent"] == 0]
    if args.RequiredOnly:
        total = len(rows)
        rows = select_required(rows)
        own_req = [r for r in rows if r["Indent"] == 0]
        # Фильтр обязан сообщать о себе: иначе список читается как полный
        O(f"Свойства: обязательных {len(own_req)} из {len(own)} "
          f"(-RequiredOnly; скрыто строк: {total - len(rows)})")
    else:
        O(f"Свойства ({len(own)}):")
    write_rows(rows)
    write_legend(rows)
    O("")
    O("Создание:")
    O(f'  Тип = ФабрикаXDTO.Тип("{pkg.Namespace}", "{type_name}");')
    O("  Объект = ФабрикаXDTO.Создать(Тип);")
    # Рецепты для вложенных и анонимных типов: имени у анонимного нет, через
    # ФабрикаXDTO.Тип(ns, имя) его не получить — только от свойства владельца
    named = next((r for r in rows if r.get("ObjName") and r.get("ObjName") != "(анонимный)"), None)
    if named:
        O("  // вложенный именованный тип — так же, как корневой:")
        O(f'  {named["Name"]} = ФабрикаXDTO.Создать(ФабрикаXDTO.Тип("{named["ObjNs"]}", "{named["ObjName"]}"));')
    anon_row = next((r for r in rows if r.get("ObjName") == "(анонимный)"), None)
    if anon_row:
        O("  // у анонимного типа нет имени — только через свойство владельца:")
        O(f'  {anon_row["Name"]} = ФабрикаXDTO.Создать(Тип.Свойства.Получить("{anon_row["Name"]}").Тип);')
    text_row = next((r for r in rows if "значение элемента" in r["Flags"]), None)
    if text_row:
        O(f'  // собственное значение узла лежит в свойстве {text_row["Name"]}')


def show_used_by(type_name, owner_pkg):
    O(f"=== Ссылки на тип: {type_name} ===")
    if owner_pkg:
        O(f"Объявлен в: {owner_pkg.Name} · {owner_pkg.Namespace}")
    O("")
    hits = []
    for p in packages:
        for node in p.Root.iter():
            if not isinstance(node.tag, str):
                continue
            for a in ("type", "base", "itemType", "memberTypes"):
                raw = node.get(a)
                if not raw:
                    continue
                for one in raw.split():
                    q = split_ref(node, one)
                    if not q or q[1] != type_name:
                        continue
                    if owner_pkg and q[0] and q[0] != owner_pkg.Namespace:
                        continue
                    owner = node
                    while owner is not None and local(owner) not in ("objectType", "valueType"):
                        owner = owner.getparent()
                    where = owner.get("name") if (owner is not None and owner.get("name")) else "(верхний уровень)"
                    what = node.get("name") or local(node)
                    hits.append(f"  {p.Name}.{where}.{what}  ({a})")
    if not hits:
        O("  Ссылок не найдено")
        return
    O(f"Найдено ({len(hits)}):")
    for h in sorted(set(hits)):
        O(h)


# ── dispatch ─────────────────────────────────────────────────

selected = None
if direct_pkg_dir:
    leaf = os.path.basename(direct_pkg_dir.rstrip("\\/"))
    selected = next((p for p in packages if p.Name == leaf), None)
if not selected and args.Namespace:
    selected = next((p for p in packages if p.Namespace == args.Namespace), None)
    if not selected:
        die(f'Пакет с namespace "{args.Namespace}" не найден. '
            "Список: -PackagePath <корень> без параметров")
if not selected and args.Package:
    selected = next((p for p in packages if p.Name == args.Package), None)
    if not selected:
        die(f'Пакет "{args.Package}" не найден. Список: -PackagePath <корень> без параметров')

if args.Mode == "used-by":
    if not args.Name:
        die("Режим used-by требует -Name <Тип>")
    owner = selected or next((p for p in packages if args.Name in p.Types), None)
    show_used_by(args.Name, owner)
    flush_output()
    sys.exit(0)

if args.Name:
    if not selected:
        # Тип известен, пакет — нет: ищем по всей конфигурации
        found = [p for p in packages if args.Name in p.Types]
        if not found:
            die(f'Тип "{args.Name}" не найден ни в одном пакете конфигурации')
        if len(found) > 1:
            O(f'=== Тип "{args.Name}" найден в нескольких пакетах ({len(found)}) ===')
            O("Уточните через -Namespace или -Package:")
            O("")
            for f in found:
                O(f"  {f.Name}  ·  {f.Namespace}")
            flush_output()
            sys.exit(0)
        selected = found[0]
    if args.Name not in selected.Types:
        die(f'В пакете {selected.Name} нет типа "{args.Name}". Список типов: тот же вызов без -Name')
    show_type(selected, args.Name)
    flush_output()
    sys.exit(0)

if selected:
    show_package_overview(selected)
else:
    show_package_list()
flush_output()
sys.exit(0)
