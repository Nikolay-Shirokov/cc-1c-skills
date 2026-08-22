# xdto-edit v1.7 — Point edits of a 1C XDTO package (Python port) (+support-guard: общая реализация вместо урезанной)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

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


XDTO_NS = "http://v8.1c.ru/8.1/xdto"
XS_NS = "http://www.w3.org/2001/XMLSchema"
MD_NS = "http://v8.1c.ru/8.3/MDClasses"
V8_NS = "http://v8.1c.ru/8.1/data/core"

OPS = ["add-property", "replace-property", "remove-property", "add-type", "remove-type",
       "add-enum", "add-import", "rename", "set-synonym", "set-comment", "set-namespace"]

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-PackagePath", "-Path", required=True)
parser.add_argument("-Operation", required=True, choices=OPS)
parser.add_argument("-Target", default="")
parser.add_argument("-Value", default="")
parser.add_argument("-NoValidate", action="store_true")
args = ci_parse_args(parser)


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def local(el):
    return etree.QName(el).localname


def _parse_xml(source, from_string=False):
    """Разбор с узким отступлением для не-URI пространств имён.

    Платформа допускает в targetNamespace произвольную строку, .NET такое принимает,
    а libxml2 отвергает. Откатываемся на восстанавливающий разбор ТОЛЬКО на этой ошибке.
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


# ── resolve package ──────────────────────────────────────────

package_path = os.path.abspath(args.PackagePath)
pkg_dir = None
if os.path.isdir(package_path):
    if os.path.exists(os.path.join(package_path, "Ext", "Package.bin")):
        pkg_dir = package_path
elif os.path.isfile(package_path) and os.path.basename(package_path) == "Package.bin":
    pkg_dir = os.path.dirname(os.path.dirname(package_path))
elif package_path.endswith(".xml"):
    stem = os.path.join(os.path.dirname(package_path),
                        os.path.splitext(os.path.basename(package_path))[0])
    if os.path.exists(os.path.join(stem, "Ext", "Package.bin")):
        pkg_dir = stem
if not pkg_dir:
    die(f"Не найден пакет XDTO по пути: {package_path}")

pkg_name = os.path.basename(pkg_dir.rstrip("\\/"))
xdto_root = os.path.dirname(pkg_dir)
config_root = os.path.dirname(xdto_root)
bin_file = os.path.join(pkg_dir, "Ext", "Package.bin")
md_file = os.path.join(xdto_root, pkg_name + ".xml")
config_xml = os.path.join(config_root, "Configuration.xml")

# -Value "@путь" — содержимое берётся из файла. Передавать XSD-фрагмент инлайном
# ненадёжно: вложенные кавычки схлопываются на границе процессов, и вместо понятной
# ошибки получается сырой сбой разбора XML.
if args.Value.startswith("@"):
    value_file = args.Value[1:]
    if not os.path.isabs(value_file):
        value_file = os.path.join(os.getcwd(), value_file)
    if not os.path.isfile(value_file):
        die("Файл значения не найден: " + value_file)
    with open(value_file, encoding="utf-8-sig") as f:
        args.Value = f.read().strip()

assert_edit_allowed(pkg_dir, "editable")

SKILLS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DECOMPILE = os.path.join(SKILLS, "xdto-decompile", "scripts", "xdto-decompile.py")
COMPILE = os.path.join(SKILLS, "xdto-compile", "scripts", "xdto-compile.py")
VALIDATE = os.path.join(SKILLS, "xdto-validate", "scripts", "xdto-validate.py")


# Исключение из автономности навыков, сделанное осознанно: конвертер XSD <-> модель
# нельзя скопировать буквально (xdto-compile — скрипт со сквозным потоком, не библиотека),
# а вторая его реализация разошлась бы с первой. Обещание «правка не меняет ни байта
# в нетронутом» держится именно на том, что код тот же самый.
# Проверяем комплектность заранее, чтобы не падать на середине правки.
def assert_siblings_present(operation):
    needed = {}
    if operation not in ("rename", "set-synonym", "set-comment"):
        needed["xdto-decompile"] = DECOMPILE
        needed["xdto-compile"] = COMPILE
    missing = [k for k, v in needed.items() if not os.path.exists(v)]
    if missing:
        die("Навык неработоспособен: рядом нет " + ", ".join(missing) + ".\n"
            + f'Операция "{operation}" выполняется через '
            + ("них" if len(missing) > 1 else "него") + ".\n"
            + "Ожидаются в каталоге навыков: " + SKILLS)


def invoke_sibling(script, argv, what):
    if not os.path.exists(script):
        die(f"Не найден навык {what} по пути: {script}")
    r = subprocess.run([sys.executable, script, *argv], capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        die(f"{what} завершился с ошибкой:\n{(r.stderr or '') + (r.stdout or '')}")
    return r.stdout


def save_xml(doc, path):
    raw = etree.tostring(doc, xml_declaration=True, encoding="UTF-8")
    # lxml пишет декларацию в ОДИНАРНЫХ кавычках, платформа и PS-порт — в двойных.
    raw = raw.replace(b"<?xml version='1.0' encoding='UTF-8'?>",
                      b'<?xml version="1.0" encoding="UTF-8"?>')
    # Парсер XML по спецификации схлопывает CRLF в LF, поэтому tostring отдаёт
    # LF-документ. Возвращаем EOL файла-назначения: правка существующего файла
    # сохраняет его стиль (#44/#46/#47), новый получает канон CRLF. Правило то же,
    # что у _detect_xml_style и у $targetEol в PS-порту: есть CRLF → CRLF.
    src_eol = b"\r\n"
    try:
        with open(path, "rb") as f:
            src_eol = b"\r\n" if b"\r\n" in f.read() else b"\n"
    except OSError:
        pass
    raw = raw.replace(b"\r\n", b"\n").replace(b"\n", src_eol)
    with open(path, "wb") as f:
        f.write(b"\xef\xbb\xbf" + raw)


# ── metadata object edits ────────────────────────────────────

def edit_metadata(field, new_value):
    doc = _parse_xml(md_file)
    props = doc.find(f".//{{{MD_NS}}}XDTOPackage/{{{MD_NS}}}Properties")
    if props is None:
        die("В объекте метаданных не найден блок <Properties>")

    if field in ("Name", "Namespace"):
        el = props.find(f"{{{MD_NS}}}{field}")
        if el is None:
            die(f"В объекте метаданных нет <{field}>")
        el.text = new_value
    elif field == "Comment":
        el = props.find(f"{{{MD_NS}}}Comment")
        if el is None:
            el = etree.SubElement(props, f"{{{MD_NS}}}Comment")
        el.text = new_value
    elif field == "Synonym":
        syn = props.find(f"{{{MD_NS}}}Synonym")
        if syn is None:
            syn = etree.SubElement(props, f"{{{MD_NS}}}Synonym")
        item = None
        for it in syn.iterfind(f"{{{V8_NS}}}item"):
            lg = it.find(f"{{{V8_NS}}}lang")
            if lg is not None and (lg.text or "") == "ru":
                item = it
                break
        if item is None:
            item = etree.SubElement(syn, f"{{{V8_NS}}}item")
            etree.SubElement(item, f"{{{V8_NS}}}lang").text = "ru"
            etree.SubElement(item, f"{{{V8_NS}}}content")
        item.find(f"{{{V8_NS}}}content").text = new_value
    save_xml(doc, md_file)


def rename_package(new_name):
    global pkg_name, pkg_dir
    # \w с re.UNICODE уже покрывает кириллицу; явные диапазоны только плодят ошибки
    if not re.match(r"^\w+$", new_name, re.UNICODE) or re.match(r"^\d", new_name):
        die(f'"{new_name}" не является допустимым идентификатором 1С')
    new_md = os.path.join(xdto_root, new_name + ".xml")
    new_dir = os.path.join(xdto_root, new_name)
    if os.path.exists(new_md) or os.path.exists(new_dir):
        die(f'Имя "{new_name}" уже занято другим пакетом')

    edit_metadata("Name", new_name)
    shutil.move(md_file, new_md)
    shutil.move(pkg_dir, new_dir)

    if os.path.exists(config_xml):
        cfg = _parse_xml(config_xml)
        found = False
        for e in cfg.iterfind(f".//{{{MD_NS}}}Configuration/{{{MD_NS}}}ChildObjects/{{{MD_NS}}}XDTOPackage"):
            if (e.text or "") == pkg_name:
                e.text = new_name
                found = True
                break
        if found:
            save_xml(cfg, config_xml)
            print(f"  Configuration.xml: <XDTOPackage> переименован в {new_name}")
        else:
            print(f"WARNING: В Configuration.xml не найдена запись <XDTOPackage>{pkg_name}</XDTOPackage> — "
                  "зарегистрируйте пакет вручную", file=sys.stderr)
    print(f"✓ Пакет переименован: {pkg_name} → {new_name}")
    print(f"  Перемещены: {new_name}.xml, {new_name}/")
    pkg_name = new_name
    pkg_dir = new_dir


# ── model edits through the XSD round-trip ───────────────────

def xs_children(el, name):
    return [c for c in el if isinstance(c.tag, str)
            and etree.QName(c).namespace == XS_NS and local(c) == name]


def xs_first(el, name):
    r = xs_children(el, name)
    return r[0] if r else None


def find_type_element(schema, type_name):
    for kind in ("complexType", "simpleType"):
        for t in xs_children(schema, kind):
            if t.get("name") == type_name:
                return t
    die(f'В пакете нет типа "{type_name}"')


def get_type_body(ct):
    content = xs_first(ct, "complexContent")
    if content is not None:
        ext = xs_first(content, "extension")
        if ext is not None:
            return ext
    return ct


def find_declaration(body, prop_name):
    for node in body.iter():
        if not isinstance(node.tag, str) or etree.QName(node).namespace != XS_NS:
            continue
        if local(node) in ("element", "attribute") and node.get("name") == prop_name:
            return node
    return None


def resolve_path(schema, path):
    # Точка безопасна: имена в модели XDTO — идентификаторы 1С
    segments = path.split(".")
    type_el = find_type_element(schema, segments[0])
    if len(segments) == 1:
        return (type_el, None)
    body = get_type_body(type_el)
    decl = None
    for i in range(1, len(segments)):
        decl = find_declaration(body, segments[i])
        if decl is None:
            die(f'По пути "{path}" не найдено свойство "{segments[i]}"')
        if i < len(segments) - 1:
            inner = xs_first(decl, "complexType")
            if inner is None:
                die(f'Свойство "{segments[i]}" не содержит вложенного типа — путь дальше не идёт')
            body = get_type_body(inner)
    return (type_el, decl)


def import_fragment(schema, xml):
    ns = {"xs": XS_NS, "xdto": XDTO_NS}
    tns = schema.get("targetNamespace")
    if tns:
        ns["tns"] = tns
    for px, uri in schema.nsmap.items():
        if px and px not in ns:
            ns[px] = uri
    decls = " ".join(f'xmlns:{k}="{v}"' for k, v in ns.items())
    try:
        wrapped = etree.fromstring(f"<wrap {decls}>{xml}</wrap>".encode("utf-8"))
    except etree.XMLSyntaxError as e:
        die("Не удалось разобрать -Value как фрагмент XML-схемы: " + str(e) + "\n"
            + "Получено: " + xml + "\n"
            + "Если фрагмент передан инлайном, кавычки могли схлопнуться на границе "
              'процессов — положите его в файл и укажите -Value "@путь".')
    res = [c for c in wrapped if isinstance(c.tag, str)]
    if not res:
        die(f"Во фрагменте нет ни одного элемента: {xml}")
    return res


def apply_model_operation(schema):
    op = args.Operation

    if op == "add-property":
        if not args.Target:
            die("add-property требует -Target <Тип>")
        type_el, decl = resolve_path(schema, args.Target)
        host = xs_first(decl, "complexType") if decl is not None else type_el
        body = get_type_body(host)
        for frag in import_fragment(schema, args.Value):
            kind = local(frag)
            if kind == "attribute":
                body.append(frag)
            elif kind == "element":
                # Явные is not None: пустой <xs:sequence/> в lxml ложен,
                # и через "or" мы бы создали вторую частицу
                particle = xs_first(body, "sequence")
                if particle is None:
                    particle = xs_first(body, "choice")
                if particle is None:
                    particle = xs_first(body, "all")
                if particle is None:
                    particle = etree.Element(f"{{{XS_NS}}}sequence")
                    first_attr = xs_first(body, "attribute")
                    if first_attr is not None:
                        first_attr.addprevious(particle)
                    else:
                        body.append(particle)
                particle.append(frag)
            else:
                die(f"add-property ожидает <xs:element> или <xs:attribute>, получен <xs:{kind}>")
            print(f'  + {frag.get("name")}  в тип {args.Target}')

    elif op == "replace-property":
        if not args.Target:
            die('replace-property требует -Target "Тип.Свойство"')
        _, decl = resolve_path(schema, args.Target)
        if decl is None:
            die('replace-property требует путь вида "Тип.Свойство"')
        frags = import_fragment(schema, args.Value)
        if len(frags) != 1:
            die("replace-property ожидает ровно одно объявление")
        decl.getparent().replace(decl, frags[0])
        print(f"  ~ {args.Target} заменено")

    elif op == "remove-property":
        if not args.Target:
            die('remove-property требует путь "Тип.Свойство"')
        for one in [x.strip() for x in args.Target.split(";;") if x.strip()]:
            _, decl = resolve_path(schema, one)
            if decl is None:
                die(f'remove-property требует путь вида "Тип.Свойство", получено "{one}"')
            decl.getparent().remove(decl)
            print(f"  − {one} удалено")

    elif op == "add-type":
        for frag in import_fragment(schema, args.Value):
            if local(frag) not in ("complexType", "simpleType"):
                die(f"add-type ожидает <xs:complexType> или <xs:simpleType>, получен <xs:{local(frag)}>")
            schema.append(frag)
            print(f'  + тип {frag.get("name")}')

    elif op == "remove-type":
        if not args.Target:
            die("remove-type требует -Target <Тип>")
        for one in [x.strip() for x in args.Target.split(";;") if x.strip()]:
            t = find_type_element(schema, one)
            t.getparent().remove(t)
            print(f"  − тип {one} удалён")

    elif op == "add-enum":
        if not args.Target:
            die("add-enum требует -Target <ТипЗначения>")
        t = find_type_element(schema, args.Target)
        restriction = xs_first(t, "restriction")
        if restriction is None:
            die(f'Тип "{args.Target}" не является ограничением простого типа')
        for lit in [x.strip() for x in args.Value.split(";;") if x.strip()]:
            e = etree.SubElement(restriction, f"{{{XS_NS}}}enumeration")
            e.set("value", lit)
            print(f'  + значение "{lit}" в тип {args.Target}')

    elif op == "add-import":
        for uri in [x.strip() for x in args.Value.split(";;") if x.strip()]:
            if any(i.get("namespace") == uri for i in xs_children(schema, "import")):
                print(f"  = импорт {uri} уже объявлен")
                continue
            imp = etree.Element(f"{{{XS_NS}}}import")
            imp.set("namespace", uri)
            first_other = next((c for c in schema if isinstance(c.tag, str)
                                and local(c) not in ("annotation", "import")), None)
            if first_other is not None:
                first_other.addprevious(imp)
            else:
                schema.append(imp)
            print(f"  + импорт {uri}")

    elif op == "set-namespace":
        if not args.Value:
            die("set-namespace требует -Value <URI>")
        old = schema.get("targetNamespace")
        if old == args.Value:
            # Установка того же значения не отбрасывается: пакет пересобирается вхолостую
            print(f"  = namespace уже {args.Value}, пакет пересобран без изменений")
        else:
            print(f"  ~ namespace: {old} → {args.Value}")
        # Меняем и targetNamespace, и объявление префикса, который на него указывал
        new_nsmap = {px: (args.Value if uri == old else uri) for px, uri in schema.nsmap.items()}
        rebuilt = etree.Element(schema.tag, nsmap=new_nsmap)
        for k, v in schema.attrib.items():
            rebuilt.set(k, v)
        rebuilt.set("targetNamespace", args.Value)
        rebuilt.text = schema.text
        for c in list(schema):
            rebuilt.append(c)
        return rebuilt
    return schema


# ── dispatch ─────────────────────────────────────────────────

assert_siblings_present(args.Operation)

print(f"Пакет: {pkg_name}")
old_namespace = None

if args.Operation == "rename":
    if not args.Value:
        die("rename требует -Value <НовоеИмя>")
    rename_package(args.Value)
elif args.Operation == "set-synonym":
    if not args.Value:
        die("set-synonym требует -Value <текст>")
    edit_metadata("Synonym", args.Value)
    print(f"✓ Синоним: {args.Value}")
elif args.Operation == "set-comment":
    edit_metadata("Comment", args.Value)
    print("✓ Комментарий обновлён")
else:
    tmp_dir = tempfile.mkdtemp(prefix="xdto-edit_")
    try:
        xsd_path = os.path.join(tmp_dir, "schema.xsd")
        invoke_sibling(DECOMPILE, ["-PackagePath", bin_file, "-OutFile", xsd_path], "xdto-decompile")

        doc = _parse_xml(xsd_path)
        schema = doc.getroot()
        old_namespace = schema.get("targetNamespace")
        schema = apply_model_operation(schema)

        with open(xsd_path, "wb") as f:
            f.write(etree.tostring(schema, xml_declaration=True, encoding="UTF-8"))
        invoke_sibling(COMPILE, ["-XsdPath", xsd_path, "-OutputDir", config_root,
                                 "-Name", pkg_name, "-Force"], "xdto-compile")

        if args.Operation == "set-namespace":
            edit_metadata("Namespace", args.Value)
            # Зависящие пакеты не трогаем: при версионировании они обязаны продолжать
            # смотреть на прежний namespace. Но молчать о них нельзя.
            dependents = []
            for d in sorted(os.listdir(xdto_root)):
                if d == pkg_name or not os.path.isdir(os.path.join(xdto_root, d)):
                    continue
                ob = os.path.join(xdto_root, d, "Ext", "Package.bin")
                if not os.path.exists(ob):
                    continue
                try:
                    for imp in _parse_xml(ob).getroot():
                        if isinstance(imp.tag, str) and local(imp) == "import" \
                                and imp.get("namespace") == old_namespace:
                            dependents.append(d)
                            break
                except Exception:  # noqa: BLE001
                    pass
            if dependents:
                print("")
                print(f"WARNING: Старый namespace импортируют пакеты ({len(dependents)}): "
                      + ", ".join(dependents)
                      + ". Они не изменены — при версионировании это верно; "
                        "если нет, поправьте их импорты.", file=sys.stderr)
        print(f"✓ Пакет пересобран: XDTOPackages/{pkg_name}/Ext/Package.bin")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

if not args.NoValidate:
    if os.path.exists(VALIDATE):
        print("")
        print("--- xdto-validate ---")
        subprocess.run([sys.executable, VALIDATE, "-PackagePath", os.path.join(xdto_root, pkg_name)])
    else:
        print(f"[SKIP] xdto-validate не найден: {VALIDATE}")
sys.exit(0)
