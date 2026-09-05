# xdto-validate v1.4 — Validate a 1C XDTO package (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import sys

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


XS_NS = "http://www.w3.org/2001/XMLSchema"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
MD_NS = "http://v8.1c.ru/8.3/MDClasses"

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-PackagePath", "-Path", required=True)
parser.add_argument("-ConfigDir", default="")
parser.add_argument("-Detailed", action="store_true")
parser.add_argument("-MaxErrors", type=int, default=20)
parser.add_argument("-OutFile", default="")
args = ci_parse_args(parser)

package_path = os.path.abspath(args.PackagePath)
detailed = args.Detailed
max_errors = args.MaxErrors
out_file = args.OutFile

# ── reporting ────────────────────────────────────────────────

state = {"errors": 0, "warnings": 0, "ok": 0, "stopped": False}
output = []


def out_line(s):
    output.append(s)


def report_ok(msg):
    state["ok"] += 1
    if detailed:
        out_line(f"[OK]    {msg}")


def report_error(msg):
    state["errors"] += 1
    out_line(f"[ERROR] {msg}")
    if state["errors"] >= max_errors:
        state["stopped"] = True


def report_warn(msg):
    state["warnings"] += 1
    out_line(f"[WARN]  {msg}")


# ── resolve paths ────────────────────────────────────────────

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
    print(f"[ERROR] Не найден Ext/Package.bin для пути: {package_path}")
    sys.exit(1)

file_name = os.path.basename(os.path.dirname(os.path.dirname(bin_path)))

config_dir = args.ConfigDir
if not config_dir:
    # .../XDTOPackages/<Имя>/Ext/Package.bin -> .../XDTOPackages -> корень
    config_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(bin_path))))


def finalize():
    checks = state["ok"] + state["errors"] + state["warnings"]
    if state["errors"] == 0 and state["warnings"] == 0 and not detailed:
        result = f"=== Validation OK: {file_name} ({checks} checks) ==="
    else:
        out_line("")
        out_line(f"=== Result: {state['errors']} errors, {state['warnings']} warnings ({checks} checks) ===")
        result = "\n".join(output)
    print(result)
    if out_file:
        with open(out_file, "w", encoding="utf-8-sig", newline="") as f:
            f.write("\n".join(output))


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


# ── 1. well-formedness ───────────────────────────────────────

try:
    doc = _parse_xml(bin_path)
except Exception as e:  # noqa: BLE001
    report_error(f"Package.bin не является корректным XML: {e}")
    finalize()
    sys.exit(1)

pkg = doc.getroot()
if local(pkg) != "package":
    report_error(f"Ожидался корневой <package>, найден <{local(pkg)}>")
    finalize()
    sys.exit(1)
report_ok("Package.bin: корректный XML, корень <package>")

target_ns = pkg.get("targetNamespace")
if not target_ns:
    report_error("У <package> не задан targetNamespace")
else:
    report_ok(f"targetNamespace: {target_ns}")

# ── 2. encoding ──────────────────────────────────────────────

with open(bin_path, "rb") as f:
    head = f.read(3)
if head != b"\xef\xbb\xbf":
    report_warn("Package.bin без BOM UTF-8 — платформа пишет файл с BOM")
else:
    report_ok("Кодировка: UTF-8 с BOM")

# ── 3. declarations ──────────────────────────────────────────

imports = []
local_types = set()
object_type_names = set()
value_type_names = set()
global_props = set()
top_sequence = []

for n in pkg:
    if not isinstance(n.tag, str):
        continue
    ln = local(n)
    top_sequence.append(ln)
    if ln == "import":
        imports.append(n.get("namespace"))
    elif ln == "objectType":
        local_types.add(n.get("name"))
        object_type_names.add(n.get("name"))
    elif ln == "valueType":
        local_types.add(n.get("name"))
        value_type_names.add(n.get("name"))
    elif ln == "property" and n.get("name"):
        global_props.add(n.get("name"))

# ── порядок элементов верхнего уровня ────────────────────────
# Модель требует import -> property -> valueType -> objectType. Нарушение платформа
# не прощает: db-update падает с «Ошибка преобразования данных XDTO».
TOP_ORDER = ["import", "property", "valueType", "objectType"]
prev_rank = -1
order_ok = True
for t in top_sequence:
    if t not in TOP_ORDER:
        continue
    rank = TOP_ORDER.index(t)
    if rank < prev_rank:
        report_error(f"Нарушен порядок элементов верхнего уровня: <{t}> после <{TOP_ORDER[prev_rank]}>. "
                     "Модель требует import -> property -> valueType -> objectType; "
                     "платформа отвергнет пакет при обновлении конфигурации")
        order_ok = False
        break
    prev_rank = rank
if order_ok:
    report_ok("Порядок элементов верхнего уровня корректен")

# ── 4. duplicate type names ──────────────────────────────────

seen = set()
for n in pkg:
    if not isinstance(n.tag, str) or local(n) not in ("objectType", "valueType"):
        continue
    nm = n.get("name")
    if not nm:
        report_error(f"<{local(n)}> без атрибута name")
        continue
    if nm in seen:
        report_error(f"Дублирующееся имя типа: {nm}")
    else:
        seen.add(nm)
if local_types:
    report_ok(f"{len(local_types)} тип(ов), имена уникальны")

# ── 5. type references resolve ───────────────────────────────

used_namespaces = set()
any_type_props = []
REF_ATTRS = ("type", "base", "ref", "itemType")


def resolve_ref(el, attr, raw):
    if not raw:
        return
    if raw.startswith("{"):
        close = raw.find("}")
        if close < 0:
            report_error(f'Некорректная нотация Кларка в {attr}="{raw}"')
            return
        ns = raw[1:close]
        loc = raw[close + 1:]
    else:
        parts = raw.split(":")
        if len(parts) == 2:
            ns = el.nsmap.get(parts[0])
            loc = parts[1]
            if not ns:
                report_error(f'Префикс "{parts[0]}" не объявлен: {attr}="{raw}" (тип {local(el)})')
                return
        else:
            ns = None
            loc = parts[0]

    if ns in (XS_NS, XSI_NS):
        if loc == "anyType":
            any_type_props.append(el)
        return
    if ns == target_ns:
        if attr == "ref":
            if loc not in global_props:
                report_error(f'ref="{raw}" не разрешается: в пакете нет глобального свойства "{loc}"')
        elif loc not in local_types:
            report_error(f'{attr}="{raw}" не разрешается: в пакете нет типа "{loc}"')
        return
    if ns:
        used_namespaces.add(ns)
        if ns not in imports:
            report_error(f'{attr}="{raw}" ссылается на "{ns}", но <import namespace="{ns}"/> не объявлен')


node_count = 0
for el in pkg.iter():
    if not isinstance(el.tag, str):
        continue
    node_count += 1
    for a in REF_ATTRS:
        if el.get(a) is not None:
            resolve_ref(el, a, el.get(a))
    if el.get("memberTypes"):
        for m in el.get("memberTypes").split():
            resolve_ref(el, "memberTypes", m)
    if state["stopped"]:
        break
if not state["stopped"]:
    report_ok(f"{node_count} узлов: ссылки на типы разрешаются")

if state["stopped"]:
    finalize()
    sys.exit(1)

# ── 6. silent degradation to xs:anyType ──────────────────────

if any_type_props and imports:
    names = [p.get("name") for p in any_type_props if p.get("name")]
    shown = ", ".join(names[:5])
    report_warn(
        f'Свойств с type="xs:anyType": {len(any_type_props)} при объявленных импортах ({shown}). '
        "Тип не разрешён — заполнить структурно такое свойство нельзя. Обычно это след импорта XML-схемы: платформа заменяет неразрешённый "
        "чужой тип на anyType без ошибки"
    )

# ── 7. unused imports ────────────────────────────────────────

# Сам по себе неиспользуемый импорт безвреден и встречается в четверти пакетов
# типовых конфигураций. Сигналом он становится только вместе с anyType.
unused = [i for i in imports if i not in used_namespaces]
if unused and any_type_props:
    report_warn(f'Импорт(ы) без единого использованного типа: {", ".join(unused)} — '
                "вместе с anyType это признак неразрешённой зависимости")
if imports and not unused:
    report_ok(f"{len(imports)} импорт(ов) — все используются")

# ── 8. nillable on attribute-form properties ─────────────────

nill_attrs = [p.get("name") for p in pkg.iter()
              if isinstance(p.tag, str) and local(p) == "property"
              and p.get("form") == "Attribute" and p.get("nillable") == "true"]
if nill_attrs:
    report_warn(
        f'Свойств с nillable="true" и form="Attribute": {len(nill_attrs)} ({", ".join(nill_attrs[:5])}). '
        "Спецификация XSD не допускает nillable у атрибутов — экспорт XML-схемы в Конфигураторе их потеряет"
    )

# ── 9. facet consistency ─────────────────────────────────────

facet_checked = 0
for t in pkg.iter():
    if not isinstance(t.tag, str) or local(t) not in ("valueType", "typeDef"):
        continue
    if local(t) == "typeDef" and t.get(f"{{{XSI_NS}}}type") == "ObjectType":
        continue
    facet_checked += 1
    nm = t.get("name") or "(анонимный тип)"

    if t.get("length") and (t.get("minLength") or t.get("maxLength")):
        # Спецификация XSD это запрещает, но платформа такие типы хранит — предупреждение, не ошибка
        report_warn(f"{nm} : length задан вместе с minLength/maxLength — "
                    "спецификация XSD считает их взаимоисключающими")
    min_l, max_l = t.get("minLength"), t.get("maxLength")
    if min_l and max_l and int(min_l) > int(max_l):
        report_error(f"{nm} : minLength ({min_l}) больше maxLength ({max_l})")
    td, fd = t.get("totalDigits"), t.get("fractionDigits")
    if td and fd and int(fd) > int(td):
        report_error(f"{nm} : fractionDigits ({fd}) больше totalDigits ({td})")
    ws = t.get("whiteSpace")
    if ws and ws not in ("preserve", "replace", "collapse"):
        report_error(f'{nm} : недопустимое whiteSpace="{ws}"')
    var = t.get("variety")
    if var and var not in ("Atomic", "List", "Union"):
        report_error(f'{nm} : недопустимое variety="{var}"')
    if var == "List" and t.get("itemType") is None:
        report_warn(f'{nm} : variety="List" без itemType')
    if state["stopped"]:
        break
if facet_checked and not state["stopped"]:
    report_ok(f"{facet_checked} простых тип(ов): фасеты согласованы")

if state["stopped"]:
    finalize()
    sys.exit(1)

# ── 10. property form / bounds ───────────────────────────────

for p in pkg.iter():
    if not isinstance(p.tag, str) or local(p) != "property":
        continue
    form = p.get("form")
    if form and form not in ("Element", "Attribute", "Text"):
        report_error(f'Свойство "{p.get("name")}": недопустимое form="{form}"')
    ub = p.get("upperBound")
    if ub and ub != "-1" and int(ub) < 1:
        report_error(f'Свойство "{p.get("name")}": upperBound="{ub}" (допустимы -1 или число ≥ 1)')
    lb = p.get("lowerBound")
    if lb and ub and ub != "-1" and int(lb) > int(ub):
        report_error(f'Свойство "{p.get("name")}": lowerBound ({lb}) больше upperBound ({ub})')
    if p.get("name") is None and p.get("ref") is None:
        report_error("Свойство без name и без ref")
    # В модели XDTO fixed — булев признак, само значение лежит в default.
    # В XML-схеме наоборот: fixed="V" совмещает признак и значение.
    fx = p.get("fixed")
    if fx is not None:
        p_name = p.get("name") if p.get("name") is not None else p.get("ref")
        if fx not in ("true", "false"):
            report_error(
                f'Свойство "{p_name}": fixed="{fx}" — в модели это булев признак, '
                "значение задаётся в default (в XML-схеме признак и значение совмещены в fixed)"
            )
        elif fx == "true" and p.get("default") is None:
            report_error(
                f"Отсутствует фиксированное значение свойства '{p_name}': "
                'есть fixed="true", нет default'
            )
    if state["stopped"]:
        break
if not state["stopped"]:
    report_ok("Свойства: form, кратности и фиксированные значения корректны")

# ── 10b. structural consistency ──────────────────────────────

struct_ok = True
for t in pkg.iter():
    if not isinstance(t.tag, str) or local(t) not in ("objectType", "typeDef"):
        continue
    if local(t) == "typeDef" and t.get(f"{{{XSI_NS}}}type") != "ObjectType":
        continue
    tn = t.get("name") or "(анонимный тип)"
    prop_names = set()
    for c in t:
        if not isinstance(c.tag, str) or local(c) != "property":
            continue
        pn = c.get("name")
        if pn:
            if pn in prop_names:
                report_error(f'{tn} : дублирующееся имя свойства "{pn}"')
                struct_ok = False
            prop_names.add(pn)
    if state["stopped"]:
        break

for p_ in pkg.iter():
    if not isinstance(p_.tag, str) or local(p_) != "property":
        continue
    pn = p_.get("name") or p_.get("ref")
    if p_.get("name") is not None and p_.get("ref") is not None:
        report_error(f'Свойство "{pn}": заданы одновременно name и ref — допустимо только одно')
        struct_ok = False
    inline = next((c for c in p_ if isinstance(c.tag, str) and local(c) == "typeDef"), None)
    if inline is not None and p_.get("type") is not None:
        report_error(f'Свойство "{pn}": заданы одновременно type и вложенный <typeDef> — допустимо только одно')
        struct_ok = False
    if inline is not None and inline.get(f"{{{XSI_NS}}}type") is None:
        report_error(f'Свойство "{pn}": у вложенного <typeDef> не задан xsi:type (ValueType или ObjectType)')
        struct_ok = False
    if state["stopped"]:
        break

# Анонимный тип внутри valueType задаёт базовый тип и xsi:type не несёт
for vt in pkg.iter():
    if not isinstance(vt.tag, str) or local(vt) != "valueType":
        continue
    for c in vt:
        if isinstance(c.tag, str) and local(c) == "typeDef" and c.get(f"{{{XSI_NS}}}type") is not None:
            report_warn(f'{vt.get("name")} : у <typeDef> внутри <valueType> задан xsi:type — '
                        "платформа его здесь не пишет")

# Род базового типа должен совпадать
for t in pkg.iter():
    if not isinstance(t.tag, str) or t.get("base") is None:
        continue
    kind = local(t)
    if kind not in ("objectType", "valueType"):
        continue
    parts = t.get("base").split(":")
    if len(parts) != 2:
        continue
    if t.nsmap.get(parts[0]) != target_ns:
        continue
    if kind == "objectType" and parts[1] in value_type_names:
        report_error(f'{t.get("name")} : base="{t.get("base")}" ссылается на valueType, '
                     "а objectType может наследоваться только от objectType")
        struct_ok = False
    if kind == "valueType" and parts[1] in object_type_names:
        report_error(f'{t.get("name")} : base="{t.get("base")}" ссылается на objectType, '
                     "а valueType может строиться только на простом типе")
        struct_ok = False

# Union без состава
for t in pkg.iter():
    if not isinstance(t.tag, str) or local(t) not in ("valueType", "typeDef"):
        continue
    if t.get("variety") != "Union" or t.get("memberTypes") is not None:
        continue
    if not any(isinstance(c.tag, str) and local(c) == "typeDef" for c in t):
        tn = t.get("name") or "(анонимный тип)"
        report_warn(f'{tn} : variety="Union" без memberTypes и без вложенных типов — состав объединения пуст')

if struct_ok and not state["stopped"]:
    report_ok("Структура типов и свойств согласована")

if state["stopped"]:
    finalize()
    sys.exit(1)

# ── 11. metadata object ──────────────────────────────────────

if md_path:
    md = _parse_xml(md_path)
    md_name = md.find(f".//{{{MD_NS}}}XDTOPackage/{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
    md_ns = md.find(f".//{{{MD_NS}}}XDTOPackage/{{{MD_NS}}}Properties/{{{MD_NS}}}Namespace")
    if md_name is None:
        report_error("В объекте метаданных не задано <Name>")
    elif (md_name.text or "") != file_name:
        report_error(f'<Name>{md_name.text}</Name> не совпадает с именем каталога "{file_name}"')
    else:
        report_ok(f"Объект метаданных: Name = {md_name.text}")
    if md_ns is not None and (md_ns.text or "") != target_ns:
        report_error(f"<Namespace>{md_ns.text}</Namespace> не совпадает с targetNamespace пакета ({target_ns})")
    elif md_ns is not None:
        report_ok("Namespace объекта метаданных совпадает с targetNamespace")
else:
    report_warn("Файл объекта метаданных <Имя>.xml не найден рядом с каталогом пакета")

# ── 12. registration + namespace uniqueness ──────────────────

config_xml = os.path.join(config_dir, "Configuration.xml")
if os.path.exists(config_xml):
    cfg = _parse_xml(config_xml)
    registered = any((e.text or "") == file_name
                     for e in cfg.iterfind(f".//{{{MD_NS}}}Configuration/{{{MD_NS}}}ChildObjects/{{{MD_NS}}}XDTOPackage"))
    if registered:
        report_ok("Зарегистрирован в Configuration.xml")
    else:
        report_error(f"<XDTOPackage>{file_name}</XDTOPackage> отсутствует в ChildObjects файла "
                     "Configuration.xml — платформа пакет не увидит")

    pkg_root = os.path.join(config_dir, "XDTOPackages")
    if os.path.isdir(pkg_root):
        clash = []
        for other in sorted(os.listdir(pkg_root)):
            if other == file_name:
                continue
            ob = os.path.join(pkg_root, other, "Ext", "Package.bin")
            if not os.path.exists(ob):
                continue
            try:
                if _parse_xml(ob).getroot().get("targetNamespace") == target_ns:
                    clash.append(other)
            except Exception:  # noqa: BLE001
                pass
        # Платформа отвергает пакет, если импортируемого namespace нет в конфигурации:
        # «Ошибка проверки модели XDTO: xdto-package-3.3 … не определен»
        known_ns = {}
        for other in sorted(os.listdir(pkg_root)):
            ob = os.path.join(pkg_root, other, "Ext", "Package.bin")
            if not os.path.exists(ob):
                continue
            try:
                known_ns[_parse_xml(ob).getroot().get("targetNamespace")] = other
            except Exception:  # noqa: BLE001
                pass
        missing_imports = [i for i in imports if i not in known_ns and i not in PLATFORM_NS]
        if missing_imports:
            report_error("Импортируемые пакеты не определены в конфигурации: "
                         + ", ".join(missing_imports)
                         + ". Платформа отвергнет пакет при обновлении конфигурации — "
                           "соберите зависимости первыми")
        elif imports:
            report_ok("Все импорты разрешаются в пакеты конфигурации")

        if clash:
            report_warn(f'targetNamespace "{target_ns}" объявлен также в пакет(ах): {", ".join(clash)}. '
                        "Платформа это допускает, но <import> на это пространство имён становится неоднозначным")
        else:
            report_ok("targetNamespace уникален в конфигурации")
else:
    report_warn(f"Configuration.xml не найден ({config_dir}) — проверки регистрации и уникальности namespace пропущены")

finalize()
sys.exit(1 if state["errors"] > 0 else 0)
