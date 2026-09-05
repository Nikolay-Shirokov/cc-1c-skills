#!/usr/bin/env python3
# subsystem-compile v1.32 — Create 1C subsystem from JSON definition
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from lxml import etree

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.

def parse_json_input(text, source, expected=None, inline=False):
    """Разбор пользовательского JSON: одна строка в stderr вместо traceback (issue #80).

    expected заполняем только для полиморфного входа: у файла подсказка
    была бы наполнителем — имя файла и текст парсера самодостаточны. inline печатает ещё и то,
    что доехало: у файла такого вопроса нет, он лежит на диске и его видно целиком.

    Импорты внутри тела: копия функции живёт в навыках с разными именами модулей
    (skd-decompile импортирует json локально как _json), а тело обязано быть одинаковым.
    """
    import json as _pj
    import sys as _psys
    try:
        if not str(text).strip():
            raise ValueError("input is empty")
        return _pj.loads(text)
    except ValueError as exc:
        what = "%s expects %s" % (source, expected) if expected else "Invalid JSON in %s" % source
        if inline:
            got = " ".join(str(text).split())
            label = "got"
            if not got:
                got = "(empty)"
            elif len(got) > 60:
                label = "got (first 60 chars)"
                got = got[:60]
            what = "%s, %s: %s" % (what, label, got)
        print("[ERROR] %s (%s)" % (what, exc), file=_psys.stderr)
        _psys.exit(1)


def read_json_file(path):
    """Чтение входного JSON-файла с кодировкой из BOM (issue #80).

    BOM — объявление самого файла, поэтому ему верим; без BOM ждём строгий UTF-8. Кодовую
    страницу не подбираем: угаданное имя уехало бы в метаданные молча.
    """
    import os as _pos
    import sys as _psys
    if not _pos.path.exists(path):
        print("[ERROR] File not found: %s" % path, file=_psys.stderr)
        _psys.exit(1)
    if _pos.path.isdir(path):
        print("[ERROR] Expected a JSON file, got a directory: %s" % path, file=_psys.stderr)
        _psys.exit(1)
    with open(path, "rb") as _fh:
        data = _fh.read()
    if data[:3] == b"\xef\xbb\xbf":
        return data[3:].decode("utf-8")
    if data[:2] == b"\xff\xfe":
        return data[2:].decode("utf-16-le")
    if data[:2] == b"\xfe\xff":
        return data[2:].decode("utf-16-be")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        print("[ERROR] %s is not valid UTF-8: %s - save the file as UTF-8, or add a BOM if it is UTF-16"
              % (path, exc), file=_psys.stderr)
        _psys.exit(1)


class CIDict(dict):
    # Ключи храним КАК ЕСТЬ: часть из них — имена объектов (табличные части, стандартные
    # реквизиты), они попадают в XML. Регистронезависим только поиск. Порядок вставки
    # сохраняется — от него зависит порядок эмиссии.
    def _actual(self, key):
        if not isinstance(key, str) or dict.__contains__(self, key):
            return key
        ci = self.__dict__.get('_ci')
        if ci is None or len(ci) != len(self):
            ci = {k.lower(): k for k in self if isinstance(k, str)}
            self.__dict__['_ci'] = ci
        return ci.get(key.lower(), key)

    def __getitem__(self, key):
        return dict.__getitem__(self, self._actual(key))

    def __contains__(self, key):
        return dict.__contains__(self, self._actual(key))

    def get(self, key, default=None):
        return dict.get(self, self._actual(key), default)

    def pop(self, key, *default):
        return dict.pop(self, self._actual(key), *default)

    def __setitem__(self, key, value):
        # запись по ключу, отличающемуся регистром, обновляет существующий, а не плодит дубль
        dict.__setitem__(self, self._actual(key), value)

def ci_json(obj):
    """Рекурсивно оборачивает разобранный JSON: словари → CIDict, списки обходятся."""
    if isinstance(obj, dict):
        return CIDict((k, ci_json(v)) for k, v in obj.items())
    if isinstance(obj, list):
        return [ci_json(v) for v in obj]
    return obj

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



def detect_eol(text):
    # Перевод строки ВСТАВКИ берём из самого файла: канон CRLF относится к файлам,
    # которые мы создаём, а правка существующего сохраняет его стиль (#44/#46/#47).
    # Семантика та же, что у _detect_xml_style в остальных портах: есть CRLF → CRLF.
    # Мажоритарное правило здесь было расхождением — на смешанном входе оно давало
    # другой ответ, чем канон, при том же назначении.
    return '\r\n' if '\r\n' in text else '\n'

def esc_xml(s):
    # Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def esc_xml_text(s):
    """Экранирование ТЕКСТА элемента: только & < > . Кавычки платформа в тексте не экранирует
    (92142 сырых кавычки на корпус, ни одной &quot;); &quot; она принимает, но нормализует обратно."""
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def emit_mltext(lines, indent, tag, text):
    if not text:
        lines.append(f"{indent}<{tag}/>")
        return
    lines.append(f"{indent}<{tag}>")
    lines.append(f"{indent}\t<v8:item>")
    lines.append(f"{indent}\t\t<v8:lang>ru</v8:lang>")
    lines.append(f"{indent}\t\t<v8:content>{esc_xml_text(text)}</v8:content>")
    lines.append(f"{indent}\t</v8:item>")
    lines.append(f"{indent}</{tag}>")


def new_uuid():
    return str(uuid.uuid4())


def write_utf8_bom(path, content):
    # newline='' — без трансляции: иначе текстовый режим Python дал бы CRLF на Windows
    # и LF на macOS, то есть вывод навыка зависел бы от ОС.
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)



def split_camel_case(name):
    if not name:
        return name
    result = re.sub(r'([a-z\u0430-\u044f\u0451])([A-Z\u0410-\u042f\u0401])', r'\1 \2', name)
    if len(result) > 1:
        result = result[0] + result[1:].lower()
    return result


# Объявления пространств имён — одной переменной: места эмиссии её только подставляют.
# Правки шапки (как xmlns:pal в формате 2.21) делаются в одном месте, в main.
XMLNS_DECL = (
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


def apply_pal_ns(format_version):
    """2.21 (8.5) добавила в шапку пространство палитры — ради <Color> у значений перечисления.
    Вставляем НА МЕСТО (после lf, перед style): платформа держит объявления по алфавиту,
    дописать в конец нельзя."""
    global XMLNS_DECL
    if format_rank(format_version) >= 221:
        XMLNS_DECL = XMLNS_DECL.replace(
            ' xmlns:style=',
            ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')


def write_child_subsystem_stub(child_path, child_name, format_version):
    child_uuid = new_uuid()
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(f'<MetaDataObject {XMLNS_DECL} version="{format_version}">')
    lines.append(f'\t<Subsystem uuid="{child_uuid}">')
    lines.append('\t\t<Properties>')
    lines.append(f'\t\t\t<Name>{esc_xml_text(child_name)}</Name>')
    lines.append('\t\t\t<Synonym/>')
    lines.append('\t\t\t<Comment/>')
    lines.append('\t\t\t<IncludeHelpInContents>true</IncludeHelpInContents>')
    lines.append('\t\t\t<IncludeInCommandInterface>true</IncludeInCommandInterface>')
    lines.append('\t\t\t<UseOneCommand>false</UseOneCommand>')
    lines.append('\t\t\t<Explanation/>')
    lines.append('\t\t\t<Picture/>')
    lines.append('\t\t\t<Content/>')
    lines.append('\t\t</Properties>')
    lines.append('\t\t<ChildObjects/>')
    lines.append('\t</Subsystem>')
    lines.append('</MetaDataObject>')
    write_utf8_bom(child_path, '\r\n'.join(lines))


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

    Вариант семьи: отступ берётся из самого документа, а запись дописывается в конец
    блока. Отличие от эталона (meta-compile) осознанное: родителем бывает вложенный
    Subsystem.xml произвольной глубины, где фиксированные три табуляции неверны,
    а группировать записи по типу внутри подсистемы нечего — потомок там всегда один.
    Реестр семьи: tests/skills/check-inline-drift.mjs.
    Возвращает исход: added | already | no-childobj | no-config.
    """
    if not os.path.exists(parent_xml_path):
        return 'no-config'

    # newline='' => без трансляции переводов строк: иначе CRLF молча схлопнется
    # в LF при чтении и файл будет переписан в LF.
    with open(parent_xml_path, 'r', encoding='utf-8-sig', newline='') as f:
        raw_text = f.read()

    eol = detect_eol(raw_text)
    doc = ET.ElementTree(ET.fromstring(raw_text))
    root = doc.getroot()
    md_ns = 'http://v8.1c.ru/8.3/MDClasses'

    # Find ChildObjects
    child_objects = None
    for holder in root.iter(f'{{{md_ns}}}{parent_tag}'):
        child_objects = holder.find(f'{{{md_ns}}}ChildObjects')
        break

    if child_objects is None:
        return 'no-childobj'

    for child in child_objects:
        if child.tag == f'{{{md_ns}}}{child_tag}' and child.text == child_name:
            return 'already'

    # Правку ведём по сырому тексту, а не сериализацией ET: она не сохраняет отступы
    # и теряет xmlns, объявленные только внутри значений атрибутов (#38).
    entry = f'<{child_tag}>{esc_xml_text(child_name)}</{child_tag}>'
    empty = re.search(r'<ChildObjects\s*/>', raw_text)
    if empty is not None:
        replacement = '<ChildObjects>' + eol + f'\t\t\t{entry}' + eol + '\t\t</ChildObjects>'
        raw_text = raw_text[:empty.start()] + replacement + raw_text[empty.end():]
    else:
        # В корне подсистема встаёт перед первой группой вида старше по CHILD_OBJECT_TYPES:
        # так она попадает и в канонический порядок видов, и в конец своей группы, если та уже
        # есть. Дописать в конец блока нельзя вдвойне: платформа переставит новую группу при
        # первой же выгрузке, а существующую подсистема покинула бы, уехав за виды ниже.
        # Во вложенном Subsystem.xml порядок видов неприменим — потомок там всегда один.
        anchor = None
        if parent_tag == 'Configuration' and child_tag in CHILD_OBJECT_TYPES:
            own_idx = CHILD_OBJECT_TYPES.index(child_tag)
            type_rx = re.compile(r'(?m)^([ \t]*)<(\w+)>[^<]*</\2>')
            for m in type_rx.finditer(raw_text):
                other = m.group(2)
                if other in CHILD_OBJECT_TYPES and CHILD_OBJECT_TYPES.index(other) > own_idx:
                    anchor = m
                    break
        if anchor is not None:
            raw_text = (raw_text[:anchor.start()] + anchor.group(1) + entry + eol
                        + raw_text[anchor.start():])
        else:
            # Отступ вставки берём у закрывающего тега +1 уровень: подстановка
            # по голому '</ChildObjects>' удваивала бы уже присутствующий отступ
            # строки (получалось 5 табов вместо 3 — PS-порт через DOM даёт 3).
            cm = re.search(r'([ \t]*)</ChildObjects>', raw_text)
            if cm is None:
                return 'no-childobj'
            raw_text = (raw_text[:cm.start()] + cm.group(1) + '\t' + entry + eol
                        + cm.group(1) + '</ChildObjects>' + raw_text[cm.end():])

    write_utf8_bom(parent_xml_path, raw_text)
    return 'added'


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C subsystem from JSON definition', allow_abbrev=False)
    parser.add_argument('-DefinitionFile', type=str, default=None)
    parser.add_argument('-Value', type=str, default=None)
    parser.add_argument('-OutputDir', type=str, required=True)
    parser.add_argument('-Parent', type=str, default=None)
    parser.add_argument('-NoValidate', action='store_true', default=False)
    args = ci_parse_args(parser)

    # --- 1. Load JSON ---
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
        json_text = read_json_file(def_file)
        json_source = def_file
        json_inline = False
    else:
        json_text = args.Value
        json_source = "-Value"
        json_inline = True

    defn = ci_json(parse_json_input(json_text, json_source, inline=json_inline))

    if not defn.get('name'):
        print("JSON must have 'name' field", file=sys.stderr)
        sys.exit(1)

    obj_name = str(defn['name'])

    # Resolve OutputDir
    output_dir = args.OutputDir
    if not os.path.isabs(output_dir):
        output_dir = os.path.join(os.getcwd(), output_dir)

    assert_edit_allowed(output_dir, "editable")

    # --- 2. Content type normalization (plural→singular, Russian→English) ---
    CONTENT_TYPE_MAP = {
        # Plural English → Singular
        'Catalogs': 'Catalog', 'Documents': 'Document', 'Enums': 'Enum',
        'Constants': 'Constant', 'Reports': 'Report', 'DataProcessors': 'DataProcessor',
        'InformationRegisters': 'InformationRegister', 'AccumulationRegisters': 'AccumulationRegister',
        'AccountingRegisters': 'AccountingRegister', 'CalculationRegisters': 'CalculationRegister',
        'ChartsOfAccounts': 'ChartOfAccounts', 'ChartsOfCharacteristicTypes': 'ChartOfCharacteristicTypes',
        'ChartsOfCalculationTypes': 'ChartOfCalculationTypes',
        'BusinessProcesses': 'BusinessProcess', 'Tasks': 'Task',
        'ExchangePlans': 'ExchangePlan', 'DocumentJournals': 'DocumentJournal',
        'CommonModules': 'CommonModule', 'CommonCommands': 'CommonCommand',
        'CommonForms': 'CommonForm', 'CommonPictures': 'CommonPicture',
        'CommonTemplates': 'CommonTemplate', 'CommonAttributes': 'CommonAttribute',
        'CommandGroups': 'CommandGroup', 'Roles': 'Role',
        'SessionParameters': 'SessionParameter', 'FilterCriteria': 'FilterCriterion',
        'XDTOPackages': 'XDTOPackage', 'WebServices': 'WebService',
        'HTTPServices': 'HTTPService', 'WSReferences': 'WSReference',
        'EventSubscriptions': 'EventSubscription', 'ScheduledJobs': 'ScheduledJob',
        'SettingsStorages': 'SettingsStorage', 'FunctionalOptions': 'FunctionalOption',
        'FunctionalOptionsParameters': 'FunctionalOptionsParameter',
        'DefinedTypes': 'DefinedType', 'DocumentNumerators': 'DocumentNumerator',
        'Sequences': 'Sequence', 'Subsystems': 'Subsystem',
        'StyleItems': 'StyleItem', 'IntegrationServices': 'IntegrationService',
        'Bots': 'Bot', 'Bot': 'Bot',
        # Russian singular → English
        'Справочник': 'Catalog', 'Каталог': 'Catalog', 'Документ': 'Document',
        'Перечисление': 'Enum', 'Константа': 'Constant',
        'Отчёт': 'Report', 'Отчет': 'Report', 'Обработка': 'DataProcessor',
        'РегистрСведений': 'InformationRegister', 'РегистрНакопления': 'AccumulationRegister',
        'РегистрБухгалтерии': 'AccountingRegister',
        'РегистрРасчёта': 'CalculationRegister', 'РегистрРасчета': 'CalculationRegister',
        'ПланСчетов': 'ChartOfAccounts', 'ПланВидовХарактеристик': 'ChartOfCharacteristicTypes',
        'ПланВидовРасчёта': 'ChartOfCalculationTypes', 'ПланВидовРасчета': 'ChartOfCalculationTypes',
        'БизнесПроцесс': 'BusinessProcess', 'Задача': 'Task',
        'ПланОбмена': 'ExchangePlan', 'ЖурналДокументов': 'DocumentJournal',
        'ОбщийМодуль': 'CommonModule', 'ОбщаяКоманда': 'CommonCommand',
        'ОбщаяФорма': 'CommonForm', 'ОбщаяКартинка': 'CommonPicture',
        'ОбщийМакет': 'CommonTemplate', 'ОбщийРеквизит': 'CommonAttribute',
        'ГруппаКоманд': 'CommandGroup', 'Роль': 'Role',
        'ПараметрСеанса': 'SessionParameter', 'КритерийОтбора': 'FilterCriterion',
        'ПакетXDTO': 'XDTOPackage', 'ВебСервис': 'WebService',
        'HTTPСервис': 'HTTPService', 'WSСсылка': 'WSReference',
        'ПодпискаНаСобытие': 'EventSubscription', 'РегламентноеЗадание': 'ScheduledJob',
        'ХранилищеНастроек': 'SettingsStorage', 'ФункциональнаяОпция': 'FunctionalOption',
        'ПараметрФункциональныхОпций': 'FunctionalOptionsParameter',
        'ОпределяемыйТип': 'DefinedType', 'НумераторДокументов': 'DocumentNumerator',
        'Последовательность': 'Sequence', 'Подсистема': 'Subsystem',
        'ЭлементСтиля': 'StyleItem', 'СервисИнтеграции': 'IntegrationService',
        # Russian plural → English
        'Справочники': 'Catalog', 'Документы': 'Document', 'Перечисления': 'Enum',
        'Константы': 'Constant', 'Отчёты': 'Report', 'Отчеты': 'Report',
        'Обработки': 'DataProcessor', 'РегистрыСведений': 'InformationRegister',
        'РегистрыНакопления': 'AccumulationRegister', 'РегистрыБухгалтерии': 'AccountingRegister',
        'РегистрыРасчёта': 'CalculationRegister', 'РегистрыРасчета': 'CalculationRegister',
        'ПланыСчетов': 'ChartOfAccounts', 'ПланыВидовХарактеристик': 'ChartOfCharacteristicTypes',
        'ПланыВидовРасчёта': 'ChartOfCalculationTypes', 'ПланыВидовРасчета': 'ChartOfCalculationTypes',
        'БизнесПроцессы': 'BusinessProcess', 'Задачи': 'Task',
        'ПланыОбмена': 'ExchangePlan', 'ЖурналыДокументов': 'DocumentJournal',
        'ОбщиеМодули': 'CommonModule', 'ОбщиеКоманды': 'CommonCommand',
        'ОбщиеФормы': 'CommonForm', 'ОбщиеКартинки': 'CommonPicture',
        'ОбщиеМакеты': 'CommonTemplate', 'ОбщиеРеквизиты': 'CommonAttribute',
        'ГруппыКоманд': 'CommandGroup', 'Роли': 'Role',
        'ПараметрыСеанса': 'SessionParameter', 'КритерииОтбора': 'FilterCriterion',
        'ПакетыXDTO': 'XDTOPackage', 'ВебСервисы': 'WebService',
        'HTTPСервисы': 'HTTPService', 'WSСсылки': 'WSReference',
        'ПодпискиНаСобытия': 'EventSubscription', 'РегламентныеЗадания': 'ScheduledJob',
        'ХранилищаНастроек': 'SettingsStorage', 'ФункциональныеОпции': 'FunctionalOption',
        'ОпределяемыеТипы': 'DefinedType', 'Подсистемы': 'Subsystem',
        'ЭлементыСтиля': 'StyleItem', 'СервисыИнтеграции': 'IntegrationService',
    }

    def normalize_content_ref(ref):
        if not ref or '.' not in ref:
            return ref
        dot_idx = ref.index('.')
        type_part = ref[:dot_idx]
        name_part = ref[dot_idx + 1:]
        if type_part in CONTENT_TYPE_MAP:
            type_part = CONTENT_TYPE_MAP[type_part]
        return f'{type_part}.{name_part}'

    format_version = detect_format_version(output_dir)
    apply_pal_ns(format_version)
    xmlns_decl = XMLNS_DECL

    # --- 3. Resolve defaults ---
    synonym = str(defn['synonym']) if defn.get('synonym') else split_camel_case(obj_name)
    comment = str(defn['comment']) if defn.get('comment') else ''
    include_help_in_contents = 'true'
    include_in_ci = str(defn['includeInCommandInterface']).lower() if defn.get('includeInCommandInterface') is not None else 'true'
    use_one_command = str(defn['useOneCommand']).lower() if defn.get('useOneCommand') is not None else 'false'
    explanation = str(defn['explanation']) if defn.get('explanation') else ''
    picture = str(defn['picture']) if defn.get('picture') else ''

    # Synonym: accept "objects" as alias for "content"
    if not defn.get('content') and defn.get('objects'):
        defn['content'] = defn['objects']

    content_items = []
    normalized_count = 0
    if defn.get('content'):
        for c in defn['content']:
            raw = str(c)
            normalized = normalize_content_ref(raw)
            if normalized != raw:
                print(f'[NORM] Content: {raw} -> {normalized}')
                normalized_count += 1
            content_items.append(normalized)
    if normalized_count > 0:
        print(f'[INFO] Normalized {normalized_count} content reference(s) to singular English form')

    children = []
    if defn.get('children'):
        for ch in defn['children']:
            children.append(str(ch))

    # --- 3. Build XML ---
    uid = new_uuid()
    lines = []

    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(f'<MetaDataObject {xmlns_decl} version="{format_version}">')
    lines.append(f'\t<Subsystem uuid="{uid}">')
    lines.append('\t\t<Properties>')

    # Name
    lines.append(f'\t\t\t<Name>{esc_xml_text(obj_name)}</Name>')

    # Synonym
    emit_mltext(lines, '\t\t\t', 'Synonym', synonym)

    # Comment
    if comment:
        lines.append(f'\t\t\t<Comment>{esc_xml_text(comment)}</Comment>')
    else:
        lines.append('\t\t\t<Comment/>')

    # Boolean properties
    lines.append(f'\t\t\t<IncludeHelpInContents>{include_help_in_contents}</IncludeHelpInContents>')
    lines.append(f'\t\t\t<IncludeInCommandInterface>{include_in_ci}</IncludeInCommandInterface>')
    lines.append(f'\t\t\t<UseOneCommand>{use_one_command}</UseOneCommand>')

    # Explanation
    emit_mltext(lines, '\t\t\t', 'Explanation', explanation)

    # Picture
    if picture:
        lines.append('\t\t\t<Picture>')
        lines.append(f'\t\t\t\t<xr:Ref>{picture}</xr:Ref>')
        lines.append('\t\t\t\t<xr:LoadTransparent>false</xr:LoadTransparent>')
        lines.append('\t\t\t</Picture>')
    else:
        lines.append('\t\t\t<Picture/>')

    # Content
    if len(content_items) > 0:
        lines.append('\t\t\t<Content>')
        for item in content_items:
            lines.append(f'\t\t\t\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml_text(item)}</xr:Item>')
        lines.append('\t\t\t</Content>')
    else:
        lines.append('\t\t\t<Content/>')

    lines.append('\t\t</Properties>')

    # ChildObjects
    if len(children) > 0:
        lines.append('\t\t<ChildObjects>')
        for ch in children:
            lines.append(f'\t\t\t<Subsystem>{esc_xml_text(ch)}</Subsystem>')
        lines.append('\t\t</ChildObjects>')
    else:
        lines.append('\t\t<ChildObjects/>')

    lines.append('\t</Subsystem>')
    lines.append('</MetaDataObject>')

    # --- 4. Write files ---
    parent = args.Parent

    if parent:
        # Nested subsystem
        if not os.path.isabs(parent):
            parent = os.path.join(os.getcwd(), parent)
        if not os.path.exists(parent):
            print(f"Parent subsystem not found: {parent}", file=sys.stderr)
            sys.exit(1)
        parent_dir = os.path.dirname(parent)
        parent_base_name = os.path.splitext(os.path.basename(parent))[0]
        subs_dir = os.path.join(parent_dir, parent_base_name, 'Subsystems')
    else:
        # Top-level subsystem
        subs_dir = os.path.join(output_dir, 'Subsystems')

    os.makedirs(subs_dir, exist_ok=True)

    target_xml = os.path.join(subs_dir, f'{obj_name}.xml')

    # Write XML
    xml_content = '\r\n'.join(lines)
    write_utf8_bom(target_xml, xml_content)
    print(f"[OK] Created: {target_xml}")

    # Create subdirectory and stub files for children if they exist
    if len(children) > 0:
        child_subs_dir = os.path.join(subs_dir, obj_name, 'Subsystems')
        if not os.path.exists(child_subs_dir):
            os.makedirs(child_subs_dir, exist_ok=True)
            print(f"[OK] Created directory: {child_subs_dir}")
        seen = set()
        for ch in children:
            if ch in seen:
                continue
            seen.add(ch)
            child_xml = os.path.join(child_subs_dir, f'{ch}.xml')
            if not os.path.exists(child_xml):
                write_child_subsystem_stub(child_xml, ch, format_version)
                print(f"[OK] Created stub: {child_xml}")

    # --- 5. Register in parent ---
    parent_xml_path = None
    parent_tag = 'Configuration'
    if parent:
        parent_xml_path = parent
        parent_tag = 'Subsystem'
    else:
        config_xml = os.path.join(output_dir, 'Configuration.xml')
        if os.path.exists(config_xml):
            parent_xml_path = config_xml

    if parent_xml_path:
        outcome = register_in_childobjects(parent_xml_path, parent_tag, 'Subsystem', obj_name)
        if outcome == 'added':
            print(f"[OK] Registered in: {parent_xml_path}")
        elif outcome == 'already':
            print(f"[SKIP] Already registered in: {parent_xml_path}")
        elif outcome == 'no-childobj':
            print(f"[WARN] ChildObjects not found in: {parent_xml_path}")
        else:
            print("[INFO] No parent XML to register in")
    else:
        print("[INFO] No parent XML to register in")

    # --- 6. Auto-validate ---
    if not args.NoValidate:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        validate_script = os.path.normpath(os.path.join(script_dir, '..', '..', 'subsystem-validate', 'scripts', 'subsystem-validate.py'))
        if os.path.isfile(validate_script):
            print()
            print("--- Running subsystem-validate ---")
            subprocess.run([sys.executable, validate_script, "-SubsystemPath", target_xml])

    # --- 7. Summary ---
    print()
    print("=== subsystem-compile summary ===")
    print(f"  Name:     {obj_name}")
    print(f"  UUID:     {uid}")
    print(f"  Content:  {len(content_items)} objects")
    print(f"  Children: {len(children)}")
    print(f"  File:     {target_xml}")
    sys.exit(0)


if __name__ == '__main__':
    main()
