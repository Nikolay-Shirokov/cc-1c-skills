#!/usr/bin/env python3
# mxl-compile v1.55 — Compile 1C spreadsheet from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import hashlib
import json
import math
import os
import re
import sys

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


def esc_xml(s):
    # Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def esc_xml_text(s):
    """Экранирование ТЕКСТА элемента: только & < > . Кавычки платформа в тексте не экранирует
    (92142 сырых кавычки на корпус, ни одной &quot;); &quot; она принимает, но нормализует обратно."""
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def write_utf8_bom(path, content):
    # newline='' — без трансляции: иначе текстовый режим Python дал бы CRLF на Windows
    # и LF на macOS, то есть вывод навыка зависел бы от ОС.
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)



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


def to_font_size(raw):
    """Размер шрифта бывает дробным (8.3, 11.3). int() на таком падал, ps1 ТИХО округлял.
    Целое держим целым, иначе "10" превратилось бы в "10.0"."""
    s = str(raw).strip() if raw is not None else ''
    if not s:
        return 0
    try:
        d = float(s)
    except (TypeError, ValueError):
        return 0
    return int(d) if d == int(d) else d


def parse_col_value(val):
    """Позиция колонки как целое, иначе None. Аналог [int]::TryParse в ps1:
    целое из JSON приходит int, "3" — строкой, 3.0 — float (ps1 печатает такое как "3")."""
    if isinstance(val, bool) or val is None:
        return None
    if isinstance(val, int):
        return val
    if isinstance(val, float):
        return int(val) if val.is_integer() else None
    try:
        return int(str(val).strip())
    except (TypeError, ValueError):
        return None


def format_tag_order():
    """Канонический порядок тегов внутри <format>. Снят с корпуса: 766 960 форматов, ни один
    его не нарушает — платформа пишет теги строго в этой последовательности, и от неё
    зависит побайтовое совпадение с выгрузкой."""
    return [
        'print', 'drawingBorder',
        'drawingHaveLeftBorder', 'drawingHaveTopBorder', 'drawingHaveRightBorder', 'drawingHaveBottomBorder',
        'font', 'leftBorder', 'topBorder', 'rightBorder', 'bottomBorder', 'border',
        'height', 'borderColor', 'width', 'autoWidthCalculation', 'widthWeightFactor',
        'horizontalAlignment', 'verticalAlignment', 'textColor', 'backColor',
        'patternColor', 'pattern', 'textPlacement', 'fillType', 'protection', 'hidden',
        'textOrientation', 'detailsUse', 'bySelectedColumns', 'markNegatives',
        'containsValue', 'valueType', 'format', 'controlType', 'hyperLink',
        'autoMarkIncomplete', 'indent', 'autoIndent', 'editFormat', 'columnSizeChange',
        'mask', 'picIndex', 'pictureSizeMode', 'picHorizontalAlignment',
        'picVerticalAlignment', 'textPosition',
    ]


def format_ml_tags():
    """Теги, значение которых — многоязычная строка (<v8:item> на язык), а не скаляр."""
    return {'format': True, 'editFormat': True, 'mask': True}


def format_tag_kind():
    """Тип значения каждого тега — выведен из корпуса, а не выписан на глаз.
    line — ссылка в палитру <line>; color — #RRGGBB / style: / web: / win:
    ml — многоязычная строка; enum — замкнутый список (см. format_enum_values).
    containsValue / valueType / controlType сюда НЕ входят: это свойства конкретной ячейки,
    а стиль — сущность общая, один на многие ячейки. По той же причине здесь нет линии рисунка
    (drawingBorder, drawingHave*Border): на корпусе все 2 135 записей с ними принадлежат только
    рисункам, у ячейки такого свойства не бывает — они задаются ключами самого рисунка."""
    return {
        'autoIndent': 'int', 'autoMarkIncomplete': 'bool', 'autoWidthCalculation': 'bool',
        'backColor': 'color', 'border': 'line', 'borderColor': 'color',
        'bottomBorder': 'line', 'bySelectedColumns': 'bool', 'columnSizeChange': 'enum',
        'detailsUse': 'enum',
        'editFormat': 'ml', 'fillType': 'enum', 'font': 'int', 'format': 'ml',
        'height': 'int', 'hidden': 'bool', 'horizontalAlignment': 'enum',
        'hyperLink': 'bool', 'indent': 'int', 'leftBorder': 'line',
        'markNegatives': 'bool', 'mask': 'ml', 'pattern': 'enum', 'patternColor': 'color',
        'picHorizontalAlignment': 'enum', 'picIndex': 'int', 'picVerticalAlignment': 'enum',
        'pictureSizeMode': 'enum', 'print': 'bool', 'protection': 'bool',
        'rightBorder': 'line', 'textColor': 'color', 'textOrientation': 'int',
        'textPlacement': 'enum', 'textPosition': 'enum', 'topBorder': 'line',
        'verticalAlignment': 'enum', 'width': 'int', 'widthWeightFactor': 'int',
    }


def format_enum_values():
    """Допустимые значения перечислений — тоже сняты с корпуса."""
    return {
        'columnSizeChange': ['Normal', 'QuickChange'],
        'detailsUse': ['Cell', 'Row', 'WithoutProcessing'],
        'fillType': ['Parameter', 'Template', 'Text'],
        'horizontalAlignment': ['Auto', 'Center', 'Justify', 'Left', 'Right'],
        # Узоры платформа нумерует подряд, без семантических имён: «Узор 1» … «Узор 17».
        'pattern': ['WithoutPattern', 'Solid', 'Pattern1', 'Pattern2', 'Pattern3', 'Pattern4', 'Pattern5', 'Pattern6', 'Pattern7', 'Pattern8', 'Pattern9', 'Pattern10', 'Pattern11', 'Pattern12', 'Pattern13', 'Pattern14', 'Pattern15', 'Pattern16', 'Pattern17'],
        'picHorizontalAlignment': ['Auto', 'Center', 'Left', 'Right'],
        'picVerticalAlignment': ['Bottom', 'Center', 'Top'],
        'pictureSizeMode': ['AutoSize', 'Proportionally', 'RealSize'],
        'textPlacement': ['Auto', 'Block', 'Cut', 'Wrap'],
        'textPosition': ['Auto', 'Bottom', 'Right', 'Top'],
        'verticalAlignment': ['Bottom', 'Center', 'Top'],
    }


def style_key_synonyms():
    """Прощающий ввод: ключ стиля, написанный иначе, чем тег платформы. Канон побеждает —
    если заданы оба, синоним отбрасывается. Ключи карты нормализованы (lower, без пробелов).
    Инвертированных синонимов (visible для hidden) НЕ заводим — это баг семантики, не удобство."""
    return {
        'align': 'horizontalAlignment', 'textalign': 'horizontalAlignment',
        'halign': 'horizontalAlignment', 'горизонтальноеположение': 'horizontalAlignment',
        'valign': 'verticalAlignment', 'verticalalign': 'verticalAlignment',
        'вертикальноеположение': 'verticalAlignment',
        'background': 'backColor', 'bgcolor': 'backColor', 'цветфона': 'backColor',
        'color': 'textColor', 'forecolor': 'textColor', 'цветтекста': 'textColor',
        'цветрамки': 'borderColor', 'цветузора': 'patternColor',
        'borderleft': 'leftBorder', 'border-left': 'leftBorder',
        'bordertop': 'topBorder', 'border-top': 'topBorder',
        'borderright': 'rightBorder', 'border-right': 'rightBorder',
        'borderbottom': 'bottomBorder', 'border-bottom': 'bottomBorder',
        'protected': 'protection', 'защита': 'protection',
        'отступ': 'indent', 'узор': 'pattern', 'гиперссылка': 'hyperLink',
        'ориентациятекста': 'textOrientation', 'размещениетекста': 'textPlacement',
        'переноспословам': 'wrap',
    }


def line_styles():
    """Палитра линий одна на документ, а Конфигуратор предлагает РАЗНЫЕ наборы: у рамки
    ячейки свой (сплошная, точечная, штриховые, двойная), у линии рисунка свой
    (пунктирная, пунктирно-точечная, точечно-пунктирно-точечная). Домен — объединение:
    перечень, снятый только с корпуса, отвергал стили рисунков."""
    return ['None', 'Solid', 'Dashed', 'Dotted', 'DashDotted', 'DashDottedDotted', 'ThinDashed', 'LargeDashed', 'ThickDashed', 'Double']


def color_namespace(val):
    """Цвет — значение с префиксом пространства имён (нотация платформы). style: объявлен
    в корне документа, web/win — нет, поэтому платформа дописывает объявление прямо на узел."""
    if val.startswith('web:'):
        return 'http://v8.1c.ru/8.1/data/ui/colors/web'
    if val.startswith('win:'):
        return 'http://v8.1c.ru/8.1/data/ui/colors/windows'
    return ''


def get_format_key(props):
    parts = []
    for tag in format_tag_order():
        if tag in props:
            parts.append(f'{tag}={props[tag]}')
    return '|'.join(parts)


# --- Ячейка-поле ввода: тип значения и элемент управления ---
# containsValue/valueType/controlType платформа держит в записи палитры формата, но принадлежат
# они конкретной ЯЧЕЙКЕ: на корпусе ERP 370 197 ссылок на такие записи — все из <f>, ни одной
# из строки, колонки или defaultFormatIndex. Поэтому в DSL это ключи ячейки, а не стиля.

# Прощающий ввод типа — общая семья resolve_type_str (эталон meta-compile). Словарь синонимов
# у каждого навыка свой: здесь только то, что бывает значением ячейки макета.
TYPE_SYNONYMS = {
    'число': 'Number', 'строка': 'String', 'булево': 'Boolean',
    'дата': 'Date', 'датавремя': 'DateTime', 'время': 'Time',
    'number': 'Number', 'string': 'String', 'boolean': 'Boolean', 'bool': 'Boolean',
    'date': 'Date', 'datetime': 'DateTime', 'time': 'Time',
    'справочникссылка': 'CatalogRef',
    'документссылка': 'DocumentRef',
    'перечислениессылка': 'EnumRef',
    'плансчетовссылка': 'ChartOfAccountsRef',
    'планвидовхарактеристикссылка': 'ChartOfCharacteristicTypesRef',
    'планвидоврасчётассылка': 'ChartOfCalculationTypesRef',
    'планвидоврасчетассылка': 'ChartOfCalculationTypesRef',
    'планобменассылка': 'ExchangePlanRef',
    'бизнеспроцессссылка': 'BusinessProcessRef',
    'задачассылка': 'TaskRef',
    'любаяссылка': 'AnyRef',
    'catalogref': 'CatalogRef', 'documentref': 'DocumentRef', 'enumref': 'EnumRef',
    'anyref': 'AnyRef',
    'определяемыйтип': 'DefinedType', 'definedtype': 'DefinedType',
}

# Голые метатипы-категории («любой объект категории») — множество, а не тип: <v8:TypeSet>.
VALUE_TYPE_SETS = ('CatalogRef', 'DocumentRef', 'EnumRef', 'ChartOfAccountsRef',
                   'ChartOfCharacteristicTypesRef', 'ChartOfCalculationTypesRef', 'ExchangePlanRef',
                   'BusinessProcessRef', 'TaskRef', 'AnyRef', 'AnyIBRef')
# Категории ссылочных типов с именем объекта — <v8:Type>.
VALUE_REF_KINDS = ('CatalogRef', 'DocumentRef', 'EnumRef', 'ChartOfAccountsRef',
                   'ChartOfCharacteristicTypesRef', 'ChartOfCalculationTypesRef', 'ExchangePlanRef',
                   'BusinessProcessRef', 'BusinessProcessRoutePointRef', 'TaskRef')

# Элемент управления. В выгрузке — GUID, имён у платформы в XML нет вовсе, поэтому канон DSL
# придуман: input и checkbox. Умолчание платформы — поле ввода для ВСЕХ типов, включая Булево
# (корпус: 63 629 форматов против 7 у флажка), поэтому input не пишем в XML как «по умолчанию»,
# а эмитим всегда — так делает платформа.
VALUE_CONTROL_GUIDS = {
    'input': '381ed624-9217-4e63-85db-c4c3cb87daae',
    'checkbox': '35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26',
}
VALUE_CONTROL_SYNONYMS = {
    # Ключи нормализованы: без пробелов, в нижнем регистре («Поле ввода» → «полеввода»).
    'полеввода': 'input', 'inputfield': 'input',
    'полефлажка': 'checkbox', 'флажок': 'checkbox', 'checkboxfield': 'checkbox',
}

CFG_NS = 'http://v8.1c.ru/8.1/data/enterprise/current-config'


def resolve_type_str(type_str):
    if not type_str:
        return type_str

    # Прощающий ввод: ведущий префикс приходит копипастой из выгрузки. Без срезания он ломает
    # поиск в словаре — русское имя типа остаётся непереведённым, и платформа отвечает
    # «Неизвестное имя типа». cfg: снимаем всегда — он однозначно означает текущую конфигурацию.
    # Сгенерированный dNpM: (в корпусе на этом URI встречаются d4p1, d5p1, d6p1 — имя префикса
    # платформа выдаёт по порядку объявления) снимаем ТОЛЬКО у ссылочных типов, с точкой:
    # сам по себе префикс многозначен — в формах d5p1:Chart, d5p1:TextDocument,
    # d5p1:GeographicalSchema адресуют чужие пространства имён, и там он часть значения.
    if type_str.startswith('cfg:'):
        type_str = type_str[4:]
    elif '.' in type_str and re.match(r'^d\d+p\d+:', type_str):
        type_str = type_str[type_str.index(':') + 1:]

    # Параметризованные типы: Number(15,2), Строка(100)
    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = TYPE_SYNONYMS.get(base_name.lower())
        if resolved:
            return f'{resolved}({params})'
        return type_str

    # Ссылочные типы: СправочникСсылка.Организации → CatalogRef.Организации
    if '.' in type_str:
        dot_idx = type_str.index('.')
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]   # includes the dot
        resolved = TYPE_SYNONYMS.get(prefix.lower())
        if resolved:
            return f'{resolved}{suffix}'
        return type_str

    # Простое имя
    resolved = TYPE_SYNONYMS.get(type_str.lower())
    if resolved:
        return resolved
    return type_str


def canon_value_type(type_str, where):
    """Канон типа: развёрнутая запись со всеми умолчаниями. Она же ложится в ключ дедупликации
    палитры, поэтому «Число(15,3)» и «Number(15,3)» обязаны дать ОДНУ запись формата — иначе
    палитра распухнет на дубли и все ссылки <f> уедут.
    Умолчания здесь ПЛАТФОРМЕННЫЕ, а не как у реквизита метаданных: голая строка — безлимитная
    (Length 0), голое число — 0,0 (проверено на макетах, собранных Конфигуратором)."""
    parts = []
    seen = set()
    for raw in re.split(r'[+|]', type_str):
        p = resolve_type_str(raw.strip())
        if not p:
            continue
        m_str = re.match(r'^String(\((\d+)(\s*,\s*(fixed|variable))?\))?$', p)
        m_num = re.match(r'^Number(\((\d+)(\s*,\s*(\d+))?(\s*,\s*(nonneg|any))?\))?$', p)
        if p == 'Boolean':
            canon, kind = 'Boolean', 'Boolean'
        elif m_str:
            length = m_str.group(2) if m_str.group(2) else '0'
            al = 'fixed' if (m_str.group(4) and m_str.group(4).lower() == 'fixed') else 'variable'
            canon, kind = f'String({length},{al})', 'String'
        elif m_num:
            digits = m_num.group(2) if m_num.group(2) else '0'
            fraction = m_num.group(4) if m_num.group(4) else '0'
            sign = 'nonneg' if (m_num.group(6) and m_num.group(6).lower() == 'nonneg') else 'any'
            canon, kind = f'Number({digits},{fraction},{sign})', 'Number'
        elif p in ('Date', 'DateTime', 'Time'):
            canon, kind = p, 'Date'
        elif re.match(r'^(DefinedType|Characteristic)\.(.+)$', p):
            canon, kind = p, f'set:{p}'
        elif '.' in p:
            kind_name = p[:p.index('.')]
            if kind_name in VALUE_REF_KINDS:
                canon, kind = p, f'ref:{p}'
            else:
                print(f'Unknown value type "{raw.strip()}" ({where}).'
                      f' Reference kinds: {", ".join(VALUE_REF_KINDS)}', file=sys.stderr)
                sys.exit(1)
        elif ':' in p:
            # Чужое пространство имён — пишем как есть: калечить его мы не вправе.
            canon, kind = p, f'raw:{p}'
        elif p in VALUE_TYPE_SETS:
            canon, kind = p, f'set:{p}'
        else:
            print(f'Unknown value type "{raw.strip()}" ({where}). Expected: Boolean, String(N),'
                  f' Number(D,F), Date, <Kind>Ref.<Name> or a bare metatype', file=sys.stderr)
            sys.exit(1)
        # Повтор одного вида в составном типе платформа выразить не может: блок квалификаторов
        # внутри <valueType> один на вид.
        if kind in seen:
            print(f'Duplicate type "{canon}" in composite value type ({where})', file=sys.stderr)
            sys.exit(1)
        seen.add(kind)
        parts.append(canon)
    if not parts:
        print(f'Empty value type ({where})', file=sys.stderr)
        sys.exit(1)
    return ' + '.join(parts)


def emit_value_type_content(lines, indent, canon_type):
    """Содержимое <valueType> по КАНОНУ — умолчаний здесь нет, они уже развёрнуты. Порядок снят
    с платформы: сначала ВСЕ <v8:Type>/<v8:TypeSet> в порядке источника, затем блоки
    квалификаторов Number → String → Date. Ссылочные типы несут ЛОКАЛЬНОЕ объявление xmlns
    на каждом узле — в макете префикс current-config всегда d4p1."""
    type_lines = []
    quals = {}
    for p in canon_type.split(' + '):
        m_str = re.match(r'^String\((\d+),(fixed|variable)\)$', p)
        m_num = re.match(r'^Number\((\d+),(\d+),(nonneg|any)\)$', p)
        if p == 'Boolean':
            type_lines.append(f'{indent}<v8:Type>xs:boolean</v8:Type>')
        elif m_str:
            al = 'Fixed' if m_str.group(2) == 'fixed' else 'Variable'
            type_lines.append(f'{indent}<v8:Type>xs:string</v8:Type>')
            quals['String'] = [
                f'{indent}<v8:StringQualifiers>',
                f'{indent}\t<v8:Length>{m_str.group(1)}</v8:Length>',
                f'{indent}\t<v8:AllowedLength>{al}</v8:AllowedLength>',
                f'{indent}</v8:StringQualifiers>']
        elif m_num:
            sign = 'Nonnegative' if m_num.group(3) == 'nonneg' else 'Any'
            type_lines.append(f'{indent}<v8:Type>xs:decimal</v8:Type>')
            quals['Number'] = [
                f'{indent}<v8:NumberQualifiers>',
                f'{indent}\t<v8:Digits>{m_num.group(1)}</v8:Digits>',
                f'{indent}\t<v8:FractionDigits>{m_num.group(2)}</v8:FractionDigits>',
                f'{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>',
                f'{indent}</v8:NumberQualifiers>']
        elif p in ('Date', 'DateTime', 'Time'):
            type_lines.append(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
            quals['Date'] = [
                f'{indent}<v8:DateQualifiers>',
                f'{indent}\t<v8:DateFractions>{p}</v8:DateFractions>',
                f'{indent}</v8:DateQualifiers>']
        elif re.match(r'^(DefinedType|Characteristic)\.', p):
            type_lines.append(f'{indent}<v8:TypeSet xmlns:d4p1="{CFG_NS}">d4p1:{p}</v8:TypeSet>')
        elif '.' in p:
            type_lines.append(f'{indent}<v8:Type xmlns:d4p1="{CFG_NS}">d4p1:{p}</v8:Type>')
        elif ':' in p:
            type_lines.append(f'{indent}<v8:Type>{p}</v8:Type>')
        else:
            type_lines.append(f'{indent}<v8:TypeSet xmlns:d4p1="{CFG_NS}">d4p1:{p}</v8:TypeSet>')
    lines.extend(type_lines)
    for q in ('Number', 'String', 'Date'):
        if q in quals:
            lines.extend(quals[q])


# Примечание к ячейке. Из четырнадцати тегов, которые пишет платформа, настоящей информации
# несут пять: текст, стиль, признак авторазмера и четыре смещения окошка. Остальное — константы
# (drawingType, pictureSize, id) либо выводится: якорь конца это координаты самой ячейки
# (1087 примечаний корпуса, без исключений), якорь начала — 1/1 (1085 из 1087).
NOTE_KEYS = ('text', 'style', 'box', 'autoSize', 'anchor')
# Стиль подсказки, который даёт Конфигуратор: 926 примечаний корпуса из 1087.
NOTE_DEFAULT_STYLE = {
    'verticalAlignment': 'Top',
    'textColor': 'style:ToolTipTextColor',
    'backColor': 'style:ToolTipBackColor',
}
# Размер окошка платформа подбирает по тексту, и вычислить его мы не можем. Пишем самый
# частый набор корпуса; при autoSize он всё равно пересчитывается при показе.
NOTE_DEFAULT_BOX = {'top': -21, 'left': 21, 'bottom': 51, 'right': 408}


def is_note_object(el):
    return any(k in el for k in NOTE_KEYS)


def cell_note(cell, where):
    """Как у текста ячейки: строка — текст, объект трактуется по ключам. Ключи примечания
    и идентификаторы языков не пересекаются."""
    raw = cell.get('note')
    if raw is None:
        return None
    text = raw
    style = None
    auto_size = True
    box = dict(NOTE_DEFAULT_BOX)
    anchor = {'row': 1, 'col': 1}

    if isinstance(raw, dict) and is_note_object(raw):
        text = raw.get('text')
        if text is None:
            text = ''
        if raw.get('style'):
            style = str(raw.get('style'))
        if raw.get('autoSize') is not None:
            auto_size = raw.get('autoSize') is True or str(raw.get('autoSize')).lower() == 'true'
        raw_box = raw.get('box') or {}
        for side in ('top', 'left', 'bottom', 'right'):
            if raw_box.get(side) is not None:
                box[side] = int(raw_box.get(side))
        raw_anchor = raw.get('anchor') or {}
        for k in ('row', 'col'):
            if raw_anchor.get(k) is not None:
                anchor[k] = int(raw_anchor.get(k))

    return {'Text': text, 'Style': style, 'AutoSize': auto_size, 'Box': box, 'Anchor': anchor}


def cell_value(cell, canon_type, where):
    """Значение ячейки-поля ввода — тег САМОЙ ячейки (<v>), а не запись палитры: у двух ячеек
    с одинаковым оформлением значения разные, и в дедупликацию формата оно не входит.
    Тип значения берём из литерала JSON и приведения НЕ делаем: платформа хранит значение с его
    собственным типом, и совпадать с объявленным он не обязан (ссылочный и составной тип она
    держит строкой, а при смене типа ячейки прежнее значение не переписывает)."""
    if 'value' not in cell:
        return None
    v = cell.get('value')
    if v is None:
        return None
    if isinstance(v, bool):
        return {'Type': 'xs:boolean', 'Text': 'true' if v else 'false'}
    if isinstance(v, (int, float)):
        # 8.0 обязано дать "8", как в PS-порту: там Convert.ToString инвариантной культурой
        # хвостовой .0 не пишет, а str() в py — пишет.
        text = str(int(v)) if (isinstance(v, float) and v.is_integer()) else str(v)
        return {'Type': 'xs:decimal', 'Text': text}

    s = str(v)
    if s != '':
        # Дата литералом JSON не выражается, поэтому едет строкой. Читаем её как дату только
        # у ячейки, объявленной датой: там платформа других значений не держит.
        if canon_type in ('Date', 'DateTime', 'Time') and re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$', s):
            return {'Type': 'xs:dateTime', 'Text': s}
        return {'Type': 'xs:string', 'Text': s}

    # Пустая строка — пустое значение ОБЪЯВЛЕННОГО типа: платформа так и пишет, когда текст
    # ячейки к типу не привёлся. Ссылочный и составной тип пустого значения своего вида не
    # имеют — там остаётся пустая строка.
    if canon_type == 'Boolean':
        return {'Type': 'xs:boolean', 'Text': 'false'}
    if canon_type.startswith('Number('):
        return {'Type': 'xs:decimal', 'Text': '0'}
    if canon_type in ('Date', 'DateTime', 'Time'):
        return {'Type': 'xs:dateTime', 'Text': '0001-01-01T00:00:00'}
    return {'Type': 'xs:string', 'Text': ''}


def cell_value_props(cell, where):
    """Свойства значения ячейки — пустой набор, если ячейка обычная. Считаются ОДНОЙ функцией:
    пре-проход регистрации палитры и генерация обязаны получить один и тот же набор, иначе
    состав палитры разойдётся и все ссылки <f> сдвинутся."""
    props = {}
    vt = cell.get('valueType')
    ctl = cell.get('controlType')
    if vt is None:
        if ctl is not None and str(ctl) != '':
            print(f"Cell 'controlType' requires 'valueType' ({where})", file=sys.stderr)
            sys.exit(1)
        if cell.get('value') is not None:
            print(f"Cell 'value' requires 'valueType' ({where})", file=sys.stderr)
            sys.exit(1)
        if cell.get('control'):
            print(f"Cell 'control' requires 'valueType' ({where})", file=sys.stderr)
            sys.exit(1)
        return props
    # Ячейка, содержащая значение, текста не несёт: платформа этого не допускает, и в корпусе
    # нет ни одной такой ячейки из 370 197.
    if cell.get('text') is not None or cell.get('template') is not None:
        print(f"Cell with 'valueType' cannot have 'text' or 'template' ({where})", file=sys.stderr)
        sys.exit(1)
    props['containsValue'] = 'true'
    # Пустая строка — третье состояние: <containsValue> есть, тип не задан (<valueType/>).
    props['valueType'] = '' if str(vt) == '' else canon_value_type(str(vt), where)

    name = 'input'
    if ctl is not None and str(ctl) != '':
        norm = re.sub(r'\s', '', str(ctl)).lower()
        norm = VALUE_CONTROL_SYNONYMS.get(norm, norm)
        name = norm
    if name == 'none':
        return props        # формат вовсе без <controlType>
    if name in VALUE_CONTROL_GUIDS:
        props['controlType'] = VALUE_CONTROL_GUIDS[name]
    elif re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', name):
        # Неизвестный элемент управления сохраняем как есть — терять его нельзя.
        props['controlType'] = name
    else:
        print(f'Unknown \'controlType\' value "{ctl}" ({where}).'
              f' Allowed: input, checkbox, none or a GUID', file=sys.stderr)
        sys.exit(1)
    return props


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C spreadsheet from JSON', allow_abbrev=False)
    parser.add_argument('-JsonPath', type=str, required=True)
    parser.add_argument('-OutputPath', type=str, required=True)
    args = ci_parse_args(parser)

    # --- Detect XML format version ---
    # У корня <document> нет атрибута version, поэтому версию берём из конфигурации, в дерево
    # которой пишем макет. Вне конфигурации (автономный .xml, исходники EPF) остаётся 2.17.
    out_path_resolved = args.OutputPath if os.path.isabs(args.OutputPath) else os.path.join(os.getcwd(), args.OutputPath)
    format_version = detect_format_version(os.path.dirname(out_path_resolved))

    # --- 1. Load and validate JSON ---
    json_path = args.JsonPath
    if not os.path.exists(json_path):
        print(f"File not found: {json_path}", file=sys.stderr)
        sys.exit(1)

    defn = ci_json(parse_json_input(read_json_file(json_path), json_path))

    # Проверяем НАЛИЧИЕ ключа, а не истинность значения: `columns: 0` — осмысленная величина
    # (раскладка по умолчанию пустая, все строки живут в именованных раскладках), а пустой
    # список областей встречается у макета без строк. Прежняя проверка объявляла и то
    # и другое отсутствующим.
    if 'columns' not in defn or defn.get('columns') is None:
        print("Required field 'columns' is missing", file=sys.stderr)
        sys.exit(1)
    if 'areas' not in defn or defn.get('areas') is None:
        print("Required field 'areas' is missing", file=sys.stderr)
        sys.exit(1)

    total_columns = int(defn['columns'])
    default_width = int(defn['defaultWidth']) if defn.get('defaultWidth') else 10

    # --- 2. Build font palette ---
    font_map = {}   # name -> 0-based index
    font_entries = []  # list of dicts

    def font_ref_kind(ref):
        """Шрифт бывает не собственным, а ссылкой: на элемент стиля конфигурации (style:)
        или на системный шрифт (sys:). Вид ссылки определяет kind, он выводится из префикса."""
        return 'WindowsFont' if ref.startswith('sys:') else 'StyleItem'

    def add_font(name, font_def):
        if font_def and font_def.get('ref'):
            ref = str(font_def['ref'])
            font_map[name] = len(font_entries)
            font_entries.append({'Ref': ref, 'Kind': font_ref_kind(ref)})
            return
        face = font_def.get('face', 'Arial') if font_def else 'Arial'
        size = to_font_size(font_def.get('size', 10)) if font_def else 10
        bold = 'true' if font_def and font_def.get('bold') is True else 'false'
        italic = 'true' if font_def and font_def.get('italic') is True else 'false'
        underline = 'true' if font_def and font_def.get('underline') is True else 'false'
        strikeout = 'true' if font_def and font_def.get('strikeout') is True else 'false'

        idx = len(font_entries)
        font_map[name] = idx
        font_entries.append({
            'Face': face,
            'Size': size,
            'Bold': bold,
            'Italic': italic,
            'Underline': underline,
            'Strikeout': strikeout,
        })

    # Add user-defined fonts
    has_default = False
    if defn.get('fonts'):
        for fname, fdef in defn['fonts'].items():
            if fname == 'default':
                has_default = True
            add_font(fname, fdef)

    # Ensure default font exists
    if not has_default:
        add_font('default', {'face': 'Arial', 'size': 10})

    # --- 3. Line palette ---
    # Рамка хранится не в формате, а в палитре <line>: формат ссылается на запись индексом.
    # Запись — тройка (стиль, ширина, gap); в корпусе gap всегда false, но тег платформа пишет.
    line_registry = []

    def register_line(ln):
        # Запись палитры линий типизирована: у рамки ячейки xsi:type Cell, у линии рисунка
        # Drawing. Вид входит в ключ, иначе одинаковые по стилю линии двух видов слились бы.
        key = (ln['Style'], str(ln['Width']), ln['Gap'], ln.get('Kind', 'Cell'))
        for i, existing in enumerate(line_registry):
            if (existing['Style'], str(existing['Width']), existing['Gap'],
                    existing.get('Kind', 'Cell')) == key:
                return i
        line_registry.append(ln)
        return len(line_registry) - 1

    # --- 4. Parse column width specs ---
    def parse_column_spec(spec):
        cols = []
        for part in spec.split(','):
            part = part.strip()
            m = re.match(r'^(\d+)-(\d+)$', part)
            if m:
                from_col = int(m.group(1))
                to_col = int(m.group(2))
                for i in range(from_col, to_col + 1):
                    cols.append(i)
            else:
                cols.append(int(part))
        return cols

    # --- 4a. Auto-calculate defaultWidth from page format ---
    page_targets = {
        'A4-landscape': 780,
        'A4-portrait': 540,
    }

    page_name = None
    target_width = None
    if defn.get('page'):
        page_name = str(defn['page'])

        if re.match(r'^\d+$', page_name):
            target_width = int(page_name)
        elif page_name in page_targets:
            target_width = page_targets[page_name]
        else:
            print(f"WARNING: Unknown page format '{page_name}'. Known: {', '.join(page_targets.keys())}, or a number.", file=sys.stderr)

        if target_width:
            total_units = 0.0
            absolute_sum = 0
            specified_cols = {}

            if defn.get('columnWidths'):
                for prop_name, prop_value in defn['columnWidths'].items():
                    val = str(prop_value)
                    cols = parse_column_spec(prop_name)
                    for c in cols:
                        specified_cols[int(c)] = True
                        m = re.match(r'^([0-9.]+)x$', val)
                        if m:
                            total_units += float(m.group(1))
                        else:
                            absolute_sum += int(val)

            for c in range(1, total_columns + 1):
                if c not in specified_cols:
                    total_units += 1.0

            if total_units > 0:
                default_width = round((target_width - absolute_sum) / total_units)

    # Build column width map: 1-based col -> width
    def build_col_width_map(widths):
        out = {}
        if widths:
            for prop_name, prop_value in widths.items():
                val = str(prop_value)
                m = re.match(r'^([0-9.]+)x$', val)
                width = round(float(m.group(1)) * default_width) if m else int(val)
                for c in parse_column_spec(prop_name):
                    out[c] = width
        return out

    col_width_map = build_col_width_map(defn.get('columnWidths'))

    # Стиль колонки — тот же именованный стиль, что у ячейки и строки: колонка третий
    # владелец формата, и своих свойств у неё нет. Ключи те же, что у columnWidths.
    def build_col_style_map(styles):
        out = {}
        if styles:
            for prop_name, prop_value in styles.items():
                # Пустое значение = колонка перечислена, формата у неё нет. Записи для
                # авторинга в этом смысла нет, поэтому в описании DSL её не показываем —
                # она нужна декомпилятору, чтобы раундтрип не терял байты.
                v = None if prop_value is None else str(prop_value)
                for c in parse_column_spec(prop_name):
                    out[c] = v
        return out

    col_style_map = build_col_style_map(defn.get('columnStyles'))

    # Колоночные раскладки: документные columns/columnWidths — раскладка по умолчанию (в XML
    # элемент <columns> БЕЗ <id>, он всегда идёт первым). Дополнительные объявляются в
    # columnSets, ключ — идентификатор, на него ссылается область ключом columnSet.
    # Склейки по содержимому нет: в корпусе полно раскладок с одинаковым содержимым и разными
    # идентификаторами, поэтому опознаёт раскладку только идентификатор.
    def to_layout_id(name):
        """Платформа хранит идентификатор раскладки как UUID и другой не принимает. Имя,
        полученное декомпиляцией, уже UUID — оставляем как есть, иначе раундтрип перестал бы
        совпадать. Читаемое имя автора превращаем в UUID ДЕТЕРМИНИРОВАННО (из хэша имени),
        чтобы повторная компиляция давала тот же файл."""
        if re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
                    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', name):
            return name
        # UUID версии 3 (имя + MD5, RFC 4122): биты версии и варианта проставляются, иначе это
        # не UUID, а просто шестнадцатеричная строка нужной формы.
        b = bytearray(hashlib.md5(name.encode('utf-8')).digest())
        b[6] = (b[6] & 0x0F) | 0x30   # версия 3
        b[8] = (b[8] & 0x3F) | 0x80   # вариант RFC 4122
        h = b.hex()
        return f'{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}'

    column_layouts = [{'Id': None, 'Name': None, 'Size': total_columns,
                       'Widths': col_width_map, 'Styles': col_style_map}]
    for set_name, cs in (defn.get('columnSets') or {}).items():
        size = int(cs['columns']) if cs.get('columns') is not None else total_columns
        column_layouts.append({
            'Id': to_layout_id(set_name),
            'Name': set_name,
            'Size': size,
            'Widths': build_col_width_map(cs.get('columnWidths')),
            'Styles': build_col_style_map(cs.get('columnStyles')),
        })

    # --- 5. Style resolver ---
    def to_line_value(val, where):
        """Значение рамки: строка стиля ("Dotted") либо объект { style, width, gap }.
        Прежняя запись borderWidth: thin/thick — это ширина 1 и 2."""
        style, width, gap = 'Solid', 1, 'false'
        if isinstance(val, dict):
            if val.get('style') is not None:
                style = str(val['style'])
            if val.get('width') is not None:
                width = val['width']
            if val.get('gap') is not None:
                gap = 'true' if val['gap'] is True else 'false'
        else:
            style = str(val)
        if style == 'thin':
            style, width = 'Solid', 1
        elif style == 'thick':
            style, width = 'Solid', 2
        canon = next((s for s in line_styles() if s.lower() == style.lower()), None)
        if not canon:
            print(f'Unknown border style "{style}" ({where}). Allowed: {", ".join(line_styles())}',
                  file=sys.stderr)
            sys.exit(1)
        return {'Style': canon, 'Width': width, 'Gap': gap}

    def row_style_spec(val, where):
        """Стиль строки: имя строкой либо объект { style, apply }. apply — куда лёг стиль:
        "both" (умолчание) — и в формат строки, и в форматы ячеек, как пишет платформа, когда
        автор оформляет строку целиком; "row" — только строке (так хранится, например,
        скрытие); "cells" — только ячейкам. Модификатор нужен раундтрипу, в описании DSL его нет."""
        if val is None:
            return None, 'both'
        if not isinstance(val, dict):
            return str(val), 'both'
        name = str(val.get('style') or '')
        apply_to = str(val.get('apply') or 'both').lower()
        if apply_to not in ('both', 'row', 'cells'):
            print(f"Unknown 'apply' value \"{val.get('apply')}\" ({where})."
                  f" Allowed: both, row, cells", file=sys.stderr)
            sys.exit(1)
        if not name:
            print(f"rowStyle object requires 'style' ({where})", file=sys.stderr)
            sys.exit(1)
        return name, apply_to

    def row_format_props(row):
        """Формат самой строки: собственные свойства строки (высота, скрытие) плюс стиль
        строки, если он ложится на строку. Пустой набор = у строки формата нет."""
        props = {}
        name, apply_to = row_style_spec(row.get('rowStyle'), 'row')
        if name and apply_to != 'cells':
            props = resolve_style(name, '')
        if row.get('height'):
            props['height'] = int(row['height'])
        if row.get('hidden') is True:
            props['hidden'] = 'true'
        return props

    def resolve_style(style_name, fill_type):
        # Набор свойств формата — «тег платформы → значение», только заданные. Порядок вставки
        # роли не играет: и ключ дедупликации, и эмиссия идут по каноническому порядку тегов.
        # <font> пишем только когда стиль задал шрифт: треть форматов корпуса (23 003 из
        # 69 581) обходится без него, а мы раньше подставляли шрифт по умолчанию всегда.
        props = {}

        if style_name and defn.get('styles'):
            style = defn['styles'].get(style_name)
            if style:
                kinds = format_tag_kind()
                enums = format_enum_values()
                synonyms = style_key_synonyms()
                where = f'style "{style_name}"'
                side_keys = {'left': 'leftBorder', 'top': 'topBorder',
                             'right': 'rightBorder', 'bottom': 'bottomBorder'}

                # Прежняя запись рамки: стороны строкой + borderWidth. Разворачиваем в
                # посторонние ключи ДО общего разбора, чтобы дальше был один путь.
                legacy = style.get('border')
                legacy_sides = (isinstance(legacy, str) and legacy
                                and not any(s.lower() == legacy.lower() for s in line_styles()))
                if legacy_sides:
                    idx = register_line(to_line_value(
                        {'style': 'Solid', 'width': 2 if str(style.get('borderWidth')) == 'thick' else 1},
                        where))
                    for side in legacy.split(','):
                        s = side.strip().lower()
                        if s == 'none':
                            continue
                        if s == 'all':
                            for k in side_keys.values():
                                props[k] = idx
                        elif s in side_keys:
                            props[side_keys[s]] = idx
                        else:
                            print(f'Unknown border side "{side.strip()}" ({where}).'
                                  f' Allowed: all, left, top, right, bottom, none', file=sys.stderr)
                            sys.exit(1)

                for raw, val in style.items():
                    # Синонимы: канон побеждает, сравнение без регистра и пробелов.
                    norm = re.sub(r'\s', '', raw).lower()
                    tag = synonyms.get(norm, raw)
                    if tag == 'borderWidth':
                        continue
                    if tag == 'border' and legacy_sides:
                        continue
                    if val is None or (isinstance(val, str) and val == ''):
                        continue

                    if tag == 'font':
                        if str(val) in font_map:
                            props['font'] = font_map[str(val)]
                        continue
                    # wrap — не имя, а сокращение: булево вместо перечисления textPlacement.
                    if tag == 'wrap':
                        if val is True or str(val) == 'true':
                            props['textPlacement'] = 'Wrap'
                        continue
                    if tag not in kinds:
                        print(f"Warning: unknown style key '{raw}' ({where}) — ignored.", file=sys.stderr)
                        continue
                    kind = kinds[tag]
                    if kind == 'line':
                        ln_val = to_line_value(val, where)
                        ln_val['Kind'] = 'Drawing' if tag == 'drawingBorder' else 'Cell'
                        props[tag] = register_line(ln_val)
                    elif kind == 'bool':
                        props[tag] = 'true' if (val is True or str(val) == 'true') else 'false'
                    elif kind == 'int':
                        props[tag] = int(val)
                    elif kind == 'enum':
                        allowed = enums[tag]
                        canon = next((a for a in allowed if a.lower() == str(val).lower()), None)
                        if not canon:
                            print(f'Unknown \'{tag}\' value "{val}" ({where}).'
                                  f' Allowed: {", ".join(allowed)}', file=sys.stderr)
                            sys.exit(1)
                        props[tag] = canon
                    else:
                        props[tag] = str(val)

        if fill_type:
            props['fillType'] = fill_type

        # Одинаковые четыре стороны платформа пишет одним <border>. Правило проверено на корпусе:
        # 70 265 свёрнутых форматов, 36 783 записанных по сторонам — и среди вторых нет ни одного
        # с четырьмя совпадающими значениями.
        sides = ['leftBorder', 'topBorder', 'rightBorder', 'bottomBorder']
        if all(s in props for s in sides) and len({props[s] for s in sides}) == 1:
            val = props[sides[0]]
            for s in sides:
                del props[s]
            props['border'] = val
        return props

    # --- 6. Format palette builder ---
    format_registry = {}   # key -> props
    format_order = []       # ordered keys for index assignment

    def register_format(props):
        key = get_format_key(props)
        if key not in format_registry:
            format_registry[key] = props
            format_order.append(key)
        # Return 1-based index
        return format_order.index(key) + 1

    # 6a. Default width format
    # Формат по умолчанию платформа кладёт в палитру ПОСЛЕДНИМ: на корпусе он последний
    # в 8285 макетах из 10 863, первым — в 25. Поэтому регистрируем его после всех остальных,
    # уже за пре-проходом; здесь только запоминаем ширину.

    # 6b. Column formats — по одной карте на каждую колоночную раскладку.
    # У колонки бывает и ширина, и оформление: формат один, свойства складываются.
    for layout in column_layouts:
        fmap = {}  # 1-based col -> format index
        for col in sorted({int(c) for c in list(layout['Widths']) + list(layout['Styles'])}):
            style_name = layout['Styles'].get(col)
            # Колонка перечислена без формата вовсе (<formatIndex>0</formatIndex>): в корпусе
            # так бывает у 4% макетов. Ноль — не индекс записи, а «формата нет».
            if col not in layout['Widths'] and not style_name:
                fmap[col] = 0
                continue
            props = {}
            if style_name:
                # Шрифт по умолчанию колонке не навязываем: формат колонки без оформления —
                # это ровно <width>, как пишет платформа.
                props = resolve_style(style_name, '')
            if col in layout['Widths']:
                props['width'] = layout['Widths'][col]
            fmap[col] = register_format(props)
        layout['FormatMap'] = fmap
    col_format_map = column_layouts[0]['FormatMap']

    # 6c. Helper: determine fillType from cell content
    # Текст ячейки платформа хранит по элементу на язык. Конвенция ML-значений (та же, что у
    # synonym/tooltip/title в метаданных и формах): объект — по элементу на язык В ПОРЯДКЕ
    # КЛЮЧЕЙ, строка — один и тот же текст на всех языках макета (textLanguages, по умолчанию
    # только ru).
    text_languages = [str(x) for x in (defn.get('textLanguages') or []) if str(x)]
    if not text_languages:
        text_languages = ['ru']

    def emit_cell_text(lines, value):
        if isinstance(value, dict):
            pairs = [(str(k), str(v)) for k, v in value.items()]
        else:
            pairs = [(lang, str(value)) for lang in text_languages]
        # Пустой текст платформа хранит ТОЛЬКО самозакрывающимся тегом: в корпусе ERP таких
        # 1 224 460, а из 780 934 непустых блоков ни одного со всеми пустыми языками нет.
        # Поэтому и пустая строка, и пустой объект дают одну и ту же запись.
        if not pairs or all(content == '' for _, content in pairs):
            lines.append('\t\t\t\t\t<tl/>')
            return
        lines.append('\t\t\t\t\t<tl>')
        for lang, content in pairs:
            lines.append('\t\t\t\t\t\t<v8:item>')
            lines.append(f'\t\t\t\t\t\t\t<v8:lang>{lang}</v8:lang>')
            lines.append(f'\t\t\t\t\t\t\t<v8:content>{esc_xml_text(content)}</v8:content>')
            lines.append('\t\t\t\t\t\t</v8:item>')
        lines.append('\t\t\t\t\t</tl>')

    def get_fill_type(cell):
        """Text НЕ эмитим: платформа его практически не пишет — на выборке корпуса 344 981
        текстовая ячейка из 348 023 (99,1%) ссылается на формат БЕЗ fillType. Наличие <tl>
        и так означает текст. Parameter и Template платформа пишет — их оставляем."""
        if cell.get('param'):
            return 'Parameter'
        if cell.get('template'):
            return 'Template'
        return ''

    # Формат примечания — обычная запись палитры: без своего стиля берём канонический стиль подсказки.
    def register_note_format(note):
        props = resolve_style(note['Style'], '') if note['Style'] else dict(NOTE_DEFAULT_STYLE)
        return register_format(props)

    def emit_cell_note(lines, note, fmt_idx, row, col):
        """Порядок тегов внутри <note> снят с корпуса: у всех 1087 примечаний он один и тот же,
        и все четырнадцать тегов присутствуют всегда."""
        lines.append('\t\t\t\t\t<note>')
        lines.append('\t\t\t\t\t\t<drawingType>Comment</drawingType>')
        lines.append('\t\t\t\t\t\t<id>0</id>')
        lines.append(f'\t\t\t\t\t\t<formatIndex>{fmt_idx}</formatIndex>')
        value = note['Text']
        if isinstance(value, dict):
            pairs = [(str(k), str(v)) for k, v in value.items()]
        else:
            pairs = [(lang, str(value)) for lang in text_languages]
        if not pairs:
            lines.append('\t\t\t\t\t\t<text/>')
        else:
            lines.append('\t\t\t\t\t\t<text>')
            for lang, content in pairs:
                lines.append('\t\t\t\t\t\t\t<v8:item>')
                lines.append(f'\t\t\t\t\t\t\t\t<v8:lang>{lang}</v8:lang>')
                lines.append(f'\t\t\t\t\t\t\t\t<v8:content>{esc_xml_text(content)}</v8:content>')
                lines.append('\t\t\t\t\t\t\t</v8:item>')
            lines.append('\t\t\t\t\t\t</text>')
        box = note['Box']
        lines.append(f'\t\t\t\t\t\t<beginRow>{note["Anchor"]["row"]}</beginRow>')
        lines.append(f'\t\t\t\t\t\t<beginRowOffset>{box["top"]}</beginRowOffset>')
        lines.append(f'\t\t\t\t\t\t<endRow>{row}</endRow>')
        lines.append(f'\t\t\t\t\t\t<endRowOffset>{box["bottom"]}</endRowOffset>')
        lines.append(f'\t\t\t\t\t\t<beginColumn>{note["Anchor"]["col"]}</beginColumn>')
        lines.append(f'\t\t\t\t\t\t<beginColumnOffset>{box["left"]}</beginColumnOffset>')
        lines.append(f'\t\t\t\t\t\t<endColumn>{col}</endColumn>')
        lines.append(f'\t\t\t\t\t\t<endColumnOffset>{box["right"]}</endColumnOffset>')
        lines.append('\t\t\t\t\t\t<autoSize>%s</autoSize>' % ('true' if note['AutoSize'] else 'false'))
        lines.append('\t\t\t\t\t\t<pictureSize>Stretch</pictureSize>')
        lines.append('\t\t\t\t\t</note>')

    # Helper: register a cell format and return its index
    def register_cell_format(style_name, fill_type, value_props=None):
        resolved = resolve_style(style_name, fill_type)
        # Свойства значения кладём ПОВЕРХ стиля — до проверки на пустоту: у ячейки-поля ввода
        # оформления может не быть вовсе, и без слияния она получила бы <f>0</f>, потеряв значение.
        if value_props:
            resolved.update(value_props)
        # У ячейки без собственного оформления формата НЕТ вовсе: <f>0</f>, где ноль — не
        # индекс записи, а «формата нет». В корпусе так у 170 710 ячеек против 50 635,
        # ссылающихся на формат по умолчанию; <f>0</f> встречается в 71% макетов.
        if not resolved:
            return 0
        return register_format(resolved)

    # --- 5.5. Шорткат строк: строка-массив ячеек ---
    # Та же форма, что у макетов СКД (skd-compile): позиция ячейки = индекс в массиве,
    # ">" продолжает ячейку слева, "|" — ячейку сверху, null — пустая колонка,
    # "{Имя}" — параметр. Разворачиваем в обычную строку с явными col/span/rowspan,
    # поэтому весь код ниже про шорткат не знает.

    def is_cell_object(el):
        """Объект описывает СВОЙСТВА ячейки или является её ЗНАЧЕНИЕМ: в первом случае среди
        ключей есть ключ схемы ячейки, во втором ключи — идентификаторы языков. Пересечений
        нет: в корпусе это ru, en, ru1, Русский."""
        cell_keys = ('col', 'span', 'rowspan', 'style', 'param', 'detail', 'text', 'template',
                     'valueType', 'controlType', 'value', 'control', 'note', 'pictureParameter')
        return any(k in el for k in cell_keys)

    def expand_shorthand_row(row, area_name, row_idx, open_by_col, max_cols):
        cells = []
        placed = {}      # 1-based col -> ячейка, занимающая колонку в ЭТОЙ строке
        extended = []    # ячейки, чей rowspan уже нарастили в этой строке (span>1 даёт несколько "|")
        last = None      # последняя реальная ячейка слева — цель для ">"

        idx = 0
        for el in row:
            idx += 1
            if idx > max_cols:
                print(f'Row exceeds \'columns\' ({max_cols}): area "{area_name}",'
                      f' row {row_idx}', file=sys.stderr)
                sys.exit(1)

            if el is None:
                last = None
                continue

            if isinstance(el, str) and el == '>':
                if last is None:
                    print(f'Row shorthand: \'>\' has no cell to the left: area "{area_name}",'
                          f' row {row_idx}, cell {idx}', file=sys.stderr)
                    sys.exit(1)
                last['span'] = int(last.get('span', 1)) + 1
                placed[idx] = last
                continue

            if isinstance(el, str) and el == '|':
                above = open_by_col.get(idx)
                if above is None:
                    print(f'Row shorthand: \'|\' has no cell above: area "{area_name}",'
                          f' row {row_idx}, cell {idx}', file=sys.stderr)
                    sys.exit(1)
                if not any(above is e for e in extended):
                    above['rowspan'] = int(above.get('rowspan', 1)) + 1
                    extended.append(above)
                placed[idx] = above
                last = None
                continue

            if isinstance(el, str):
                cell = CIDict()
                cell['col'] = idx
                cell['span'] = 1
                m = re.match(r'^\{(.+)\}$', el)
                if m:
                    cell['param'] = m.group(1)
                else:
                    cell['text'] = el
            elif not is_cell_object(el):
                # Объект без единого ключа ячейки — это многоязычный ТЕКСТ: в позиционной
                # записи элемент и есть значение текста, а значение текста по общей конвенции
                # бывает строкой либо объектом «язык → текст».
                cell = CIDict({'col': idx, 'span': 1, 'text': el})
            else:
                # Объектный элемент — обычная ячейка mxl, позиция берётся из индекса.
                if 'col' in el:
                    print(f'Row shorthand: cell object must not carry \'col\': area "{area_name}",'
                          f' row {row_idx}, cell {idx}', file=sys.stderr)
                    sys.exit(1)
                cell = el
                cell['col'] = idx
                if not cell.get('span'):
                    cell['span'] = 1

            cells.append(cell)
            placed[idx] = cell
            last = cell
            # Ячейка занимает СТОЛЬКО позиций, каков её span. У строки со следующими ">" это
            # получается само (каждый маркер съедает позицию), а объектный элемент несёт span
            # внутри — без этого сдвига всё правее него уезжало влево.
            el_span = int(cell.get('span') or 1)
            for _ in range(el_span - 1):
                idx += 1
                placed[idx] = cell

        # Колонки, не занятые в этой строке, теряют «ячейку сверху».
        open_by_col.clear()
        open_by_col.update(placed)

        out = CIDict()
        out['cells'] = cells
        return out

    # Позиционный список ячеек опознаём по наличию хотя бы одного элемента-строки или None:
    # маркеры, текст и пропуски бывают только в нём. Список из одних объектов разбирается
    # как обычный — для простой строки обе трактовки дают один результат, неоднозначности нет.
    def is_positional_cells(cells):
        if not isinstance(cells, list):
            return False
        return any(el is None or isinstance(el, str) for el in cells)

    # Карту занятых колонок ведём и по объектным строкам: "|" продолжает ту ячейку,
    # которая реально стоит выше, независимо от того, какой формой её записали.
    def update_open_by_col(row, open_by_col):
        placed = {}
        for cell in (row.get('cells') or []):
            # Ячейки без col (строка с автопотоком) на этом шаге ещё не разложены — позиция
            # станет известна позже, поэтому «ячейку сверху» они не дают, и "|" под такой
            # строкой честно скажет, что сверху ничего нет.
            if cell.get('col') is None:
                continue
            col = int(cell['col'])
            span = int(cell.get('span', 1))
            for c in range(col, col + span):
                placed[c] = cell
        open_by_col.clear()
        open_by_col.update(placed)

    for area in defn['areas']:
        area_name = area.get('name', '')
        # Ширина сетки берётся из раскладки области: у каждой она своя.
        area_max_cols = total_columns
        if area.get('columnSet'):
            lay = next((x for x in column_layouts if x['Name'] == str(area['columnSet'])), None)
            if lay:
                area_max_cols = int(lay['Size'])
        open_by_col = {}
        expanded_rows = []
        for row_idx, row in enumerate(area.get('rows', []), start=1):
            if isinstance(row, list):
                # Строка целиком массивом — сахар для { cells: [...] }.
                expanded_rows.append(expand_shorthand_row(row, area_name, row_idx, open_by_col, area_max_cols))
            elif is_positional_cells(row.get('cells')):
                # Короткая запись — свойство СПИСКА ЯЧЕЕК, а не строки: свои height и rowStyle
                # строка при этом сохраняет.
                expanded = expand_shorthand_row(row['cells'], area_name, row_idx, open_by_col, area_max_cols)
                row['cells'] = expanded['cells']
                expanded_rows.append(row)
            else:
                expanded_rows.append(row)
                if row.get('empty'):
                    open_by_col.clear()
                else:
                    update_open_by_col(row, open_by_col)
        area['rows'] = expanded_rows

    # Pre-register all formats from areas
    for area in defn['areas']:
        for row in area.get('rows', []):
            # Skip empty row placeholder
            if row.get('empty'):
                continue

            # Формат САМОЙ строки: высота и скрытие — её собственные свойства (у ячейки
            # таких нет), плюс стиль строки, если он ложится на строку.
            row_props = row_format_props(row)
            if row_props:
                register_format(row_props)

            rs_name, rs_apply = row_style_spec(row.get('rowStyle'), 'row')
            cells_style = None if rs_apply == 'row' else rs_name

            # rowStyle gap-fill format
            if cells_style:
                register_cell_format(cells_style, '')

            # Explicit cell formats
            if row.get('cells'):
                for cell in row['cells']:
                    cell_style = cell.get('style') or cells_style or 'default'
                    ft = get_fill_type(cell)
                    vp = cell_value_props(cell, f'area "{area.get("name") or ""}"')
                    register_cell_format(cell_style, ft, vp)
                    note = cell_note(cell, f'area "{area.get("name") or ""}"')
                    if note:
                        register_note_format(note)

    # Колонтитулы. Шесть слотов: left/center/right у верхнего и нижнего. Слот устроен как
    # ячейка — ссылка на формат плюс текст, — а формат несёт то, что в диалоге задаётся на весь
    # колонтитул: шрифт, вертикальное выравнивание, признак вывода (<height> 1/-1) и страницу,
    # с которой колонтитул печатается (<width>).
    def header_format_index(hf):
        if not hf:
            return 0
        props = {}
        if hf.get('font') and str(hf['font']) in font_map:
            props['font'] = font_map[str(hf['font'])]
        # Признак вывода и стартовая страница осмысленны только вместе: платформа пишет их парой.
        props['height'] = -1 if (hf.get('show') is False or str(hf.get('show')).lower() == 'false') else 1
        props['width'] = int(hf['startPage']) if hf.get('startPage') else 1
        if hf.get('verticalAlignment'):
            props['verticalAlignment'] = str(hf['verticalAlignment'])
        return register_format(props)

    def emit_header_slot(lines, tag, value, fmt_idx):
        if value is None:
            return
        # Форматированная строка платформы — тот же текст, только разметка живёт внутри
        # содержимого (<b>жирный</>, <fontsize 12>…), поэтому возим её как есть и различаем
        # именем тега.
        formatted = isinstance(value, dict) and value.get('formatted') is not None
        text = value['formatted'] if formatted else value
        if isinstance(text, dict):
            pairs = [(str(k), str(v)) for k, v in text.items()]
        else:
            pairs = [(lang, str(text)) for lang in text_languages]
        text_tag = 'tfl' if formatted else 'tl'
        lines.append(f'\t<{tag}>')
        lines.append(f'\t\t<f>{fmt_idx}</f>')
        if not pairs:
            lines.append(f'\t\t<{text_tag}/>')
        else:
            lines.append(f'\t\t<{text_tag}>')
            for lang, content in pairs:
                lines.append('\t\t\t<v8:item>')
                lines.append(f'\t\t\t\t<v8:lang>{lang}</v8:lang>')
                # Перенос строки внутри колонтитула платформа хранит голым LF, тогда как весь
                # файл идёт CRLF. Содержимое кладём одним элементом списка, чтобы перенос
                # не переписался при склейке строк документа.
                lines.append(f'\t\t\t\t<v8:content>{esc_xml_text(content)}</v8:content>')
                lines.append('\t\t\t</v8:item>')
            lines.append(f'\t\t</{text_tag}>')
        lines.append(f'\t</{tag}>')

    # Параметры печати. Имя ключа совпадает с именем тега в выгрузке, как у свойств стиля.
    # Порядок снят с корпуса (2350 макетов): платформа пишет теги строго в этой последовательности.
    def print_settings_order():
        return ('pageOrientation', 'scale', 'collate', 'copies', 'perPage',
                'topMargin', 'leftMargin', 'bottomMargin', 'rightMargin', 'headerSize', 'footerSize',
                'fitToPage', 'blackAndWhite', 'printerName', 'paper', 'paperSource',
                'pageWidth', 'pageHeight', 'duplexType', 'pagePlacementAlternation', 'firstPageNumber')

    def emit_print_settings(lines, ps):
        if not ps:
            return
        order = print_settings_order()
        for key in ps:
            if key not in order:
                print(f'printSettings: unknown key "{key}". Allowed: {", ".join(order)}', file=sys.stderr)
                sys.exit(1)
        emitted = []
        for tag in order:
            v = ps.get(tag)
            if v is None:
                continue
            if isinstance(v, bool):
                v = 'true' if v else 'false'
            emitted.append(f'\t\t<{tag}>{esc_xml_text(str(v))}</{tag}>')
        if not emitted:
            return
        lines.append('\t<printSettings>')
        lines.extend(emitted)
        lines.append('\t</printSettings>')

    # Палитра картинок. Ресурс хранится двумя способами: ссылкой на библиотеку платформы
    # (ref="v8ui:Имя") либо данными base64 прямо в макете (9 905 из 9 988 картинок корпуса).
    # На неё ссылаются и рисунки (pictureIndex), и ячейки (picIndex в стиле) — индекс 1-based.
    picture_names = {}
    picture_entries = []
    for pic_name, pic_def in (defn.get('pictures') or {}).items():
        # Пустая запись — законная картинка «не задана»: в корпусе таких 151, ровно по одной
        # на макет. Ошибкой считаем только запись с непонятным содержимым.
        entry = {'Ref': '', 'Data': '', 'Transparent': '', 'PixelX': '', 'PixelY': ''}
        if pic_def.get('ref'):
            entry['Ref'] = str(pic_def['ref'])
        if pic_def.get('data') is not None:
            entry['Data'] = str(pic_def['data'])
        # Прозрачность — одна сущность диалога, записанная двумя способами: выключенную
        # платформа хранит атрибутом, включённую — координатами пикселя, чей цвет прозрачен.
        # Поэтому и ключ один, а форма значения выбирает способ.
        tr = pic_def.get('transparent')
        if tr is not None:
            if isinstance(tr, bool) or str(tr).lower() in ('true', 'false'):
                entry['Transparent'] = 'true' if (tr is True or str(tr).lower() == 'true') else 'false'
            elif isinstance(tr, dict) and 'x' in tr and 'y' in tr:
                entry['PixelX'] = str(int(tr['x']))
                entry['PixelY'] = str(int(tr['y']))
            else:
                print(f"pictures[{pic_name}]: 'transparent' is either false/true or {{ x, y }}", file=sys.stderr)
                sys.exit(1)
        if not entry['Ref'] and not entry['Data'] and (entry['Transparent'] or entry['PixelX']):
            print(f"pictures[{pic_name}]: 'transparent' requires 'ref' or 'data'", file=sys.stderr)
            sys.exit(1)
        picture_entries.append(entry)
        picture_names[pic_name] = len(picture_entries)

    # Рисунки: своя геометрия из двух якорей, тип, ссылка на картинку, текст, расшифровка.
    # id и zOrder — данные, а не позиция: на корпусе они расходятся у 8 253 рисунков из 11 268.
    DRAWING_TYPES = ('Picture', 'Rectangle', 'Ellipse', 'Line', 'Text', 'Chart', 'GanttChart')

    def drawing_anchor(node):
        node = node or {}
        return {
            'Row': int(node['row']) - 1 if node.get('row') is not None else 0,
            'Col': int(node['col']) - 1 if node.get('col') is not None else 0,
            'Dy': int(node['dy']) if node.get('dy') is not None else 0,
            'Dx': int(node['dx']) if node.get('dx') is not None else 0,
        }

    drawings = []
    for idx, dr in enumerate(defn.get('drawings') or [], start=1):
        where = f'drawings[{idx}]'
        dtype = str(dr.get('type') or 'Picture')
        canon_type = next((t for t in DRAWING_TYPES if t.lower() == dtype.lower()), None)
        if canon_type is None:
            print(f'{where}: unknown drawing \'type\' "{dtype}". Allowed: {", ".join(DRAWING_TYPES)}',
                  file=sys.stderr)
            sys.exit(1)
        pic_idx = 0
        if dr.get('picture'):
            if str(dr['picture']) not in picture_names:
                print(f'{where}: unknown \'picture\' "{dr["picture"]}" — not declared in pictures',
                      file=sys.stderr)
                sys.exit(1)
            pic_idx = picture_names[str(dr['picture'])]
        # Оформление рисунка: общее — из именованного стиля, чисто рисуночное (линия и её
        # стороны) — своими ключами, поверх стиля. Тот же приём, что у ячейки с fillType.
        props = resolve_style(str(dr['style']), '') if dr.get('style') else {}
        if dr.get('line') is not None:
            ln_val = to_line_value(dr['line'], where)
            ln_val['Kind'] = 'Drawing'
            props['drawingBorder'] = register_line(ln_val)
        for side in ('left', 'top', 'right', 'bottom'):
            v = (dr.get('sides') or {}).get(side)
            if v is not None:
                tag = 'drawingHave' + side.capitalize() + 'Border'
                props[tag] = 'true' if (v is True or str(v).lower() == 'true') else 'false'
        fmt_idx = register_format(props) if props else 0
        drawings.append({
            'Type': canon_type,
            'Id': int(dr['id']) if dr.get('id') is not None else idx,
            'ZOrder': int(dr['zOrder']) if dr.get('zOrder') is not None else idx,
            'FormatIdx': fmt_idx,
            'Detail': dr.get('detail'),
            'Text': dr.get('text'),
            'Begin': drawing_anchor(dr.get('begin')),
            'End': drawing_anchor(dr.get('end')),
            'PictureSize': str(dr.get('pictureSize') or 'Stretch'),
            'PictureIdx': pic_idx,
            'Name': dr.get('name'),
        })

    # Формат по умолчанию — последняя запись палитры (см. выше).
    default_format_index = register_format({'width': default_width})

    # Формат колонтитула заводим здесь же: он идёт в палитре следом за умолчанием, и он
    # обязан попасть в реестр ДО отсева неиспользуемых шрифтов — иначе шрифт колонтитула,
    # на который больше никто не ссылается, будет выброшен.
    header_fmt = header_format_index(defn.get('header'))
    footer_fmt = header_format_index(defn.get('footer'))

    # Шрифт, на который не ссылается ни один формат, платформа в палитру не кладёт: у макета
    # без оформления элемента <font> нет вовсе. Мы же всегда заводили Arial 10 по умолчанию.
    # Отбрасываем неиспользуемые и перенумеровываем ссылки — индексы шрифтов позиционные.
    used_fonts = {int(fp['font']) for fp in format_registry.values() if 'font' in fp}
    if len(used_fonts) < len(font_entries):
        font_remap = {}
        kept = []
        for i in range(len(font_entries)):
            if i in used_fonts:
                font_remap[i] = len(kept)
                kept.append(font_entries[i])
        for fp in format_registry.values():
            if 'font' in fp:
                fp['font'] = font_remap[int(fp['font'])]
        font_entries = kept

    # --- 7. Generate XML ---
    lines = []

    # 7a. Header
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    doc_ns_decl = ('xmlns="http://v8.1c.ru/8.2/data/spreadsheet" xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
                   ' xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
                   ' xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
    # 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (перед style):
    # платформа держит объявления по алфавиту, дописать в конец нельзя.
    if format_rank(format_version) >= 221:
        doc_ns_decl = doc_ns_decl.replace(
            ' xmlns:style=',
            ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')
    lines.append(f'<document {doc_ns_decl}>')

    # 7b. Language settings
    # Языки МАКЕТА — не то же, что textLanguages: там языки, на которые разворачивается текст
    # ячейки, здесь объявление в шапке. Почти во всех макетах ERP объявлен один ru, а текст
    # лежит и под ru, и под en, поэтому выводить одно из другого нельзя. Ключи
    # недокументированные: автору они не нужны, нужны раундтрипу.
    RU = '\u0420\u0443\u0441\u0441\u043a\u0438\u0439'
    lang_codes = {'ru': RU, 'en': '\u0410\u043d\u0433\u043b\u0438\u0439\u0441\u043a\u0438\u0439'}
    lang_list = []
    for lang in (defn.get('languages') or []):
        if isinstance(lang, dict):
            # description отсутствует и пустая строка — одно и то же: тег есть всегда, но
            # бывает самозакрывающимся (77 записей корпуса против 11 017 со значением).
            lang_list.append({'Id': str(lang.get('id') or ''),
                              'Code': str(lang.get('code') or ''),
                              'Description': '' if lang.get('description') is None
                                             else str(lang['description'])})
        else:
            code = lang_codes.get(str(lang), str(lang))
            lang_list.append({'Id': str(lang), 'Code': code, 'Description': code})
    if not lang_list:
        lang_list = [{'Id': 'ru', 'Code': RU, 'Description': RU}]
    current_lang = defn['currentLanguage'] if 'currentLanguage' in defn else 'ru'
    default_lang = str(defn.get('defaultLanguage') or 'ru')

    lines.append('	<languageSettings>')
    if current_lang is not None and str(current_lang) != '':
        lines.append(f'		<currentLanguage>{esc_xml_text(str(current_lang))}</currentLanguage>')
    lines.append(f'		<defaultLanguage>{esc_xml_text(default_lang)}</defaultLanguage>')
    for lang in lang_list:
        lines.append('		<languageInfo>')
        lines.append(f'			<id>{esc_xml_text(lang["Id"])}</id>')
        lines.append(f'			<code>{esc_xml_text(lang["Code"])}</code>')
        if lang['Description'] == '':
            lines.append('			<description/>')
        else:
            lines.append(f'			<description>{esc_xml_text(lang["Description"])}</description>')
        lines.append('		</languageInfo>')
    lines.append('	</languageSettings>')

    # 7c. Columns
    # Раскладка по умолчанию идёт первой и без <id> — так их хранит платформа.
    for layout in column_layouts:
        lines.append('\t<columns>')
        if layout['Id']:
            lines.append(f'\t\t<id>{layout["Id"]}</id>')
        lines.append(f'\t\t<size>{layout["Size"]}</size>')

        # Emit columnsItem for columns with non-default widths
        for col in sorted(layout['FormatMap'].keys()):
            fmt_idx = layout['FormatMap'][col]
            col_idx = col - 1  # Convert to 0-based
            lines.append('\t\t<columnsItem>')
            lines.append(f'\t\t\t<index>{col_idx}</index>')
            lines.append('\t\t\t<column>')
            lines.append(f'\t\t\t\t<formatIndex>{fmt_idx}</formatIndex>')
            lines.append('\t\t\t</column>')
            lines.append('\t\t</columnsItem>')

        lines.append('\t</columns>')

    # 7d. Rows -- main generation loop
    global_row = 0
    merges = []
    named_items = []
    # Строка документа → колоночная раскладка. Нужна для вывода привязки именованной области:
    # на корпусе она совпадает с раскладкой накрытых строк у 1 021 570 областей из 1 044 339.
    row_column_set = {}
    active_rowspans = []  # list of {ColStart, ColEnd, StartLocalRow, EndLocalRow}

    # Копилка подряд идущих одинаковых пустых строк — пишется одним rowsItem с indexTo.
    pending_gap = [None]

    def flush_gap():
        gap = pending_gap[0]
        if gap is None:
            return
        pending_gap[0] = None
        lines.append('\t<rowsItem>')
        lines.append(f'\t\t<index>{gap["Start"]}</index>')
        if gap['End'] > gap['Start']:
            lines.append(f'\t\t<indexTo>{gap["End"]}</indexTo>')
        lines.append('\t\t<row>')
        if gap['ColumnSet']:
            lines.append(f'\t\t\t<columnsID>{gap["ColumnSet"]}</columnsID>')
        if gap['FormatIdx'] > 0:
            lines.append(f'\t\t\t<formatIndex>{gap["FormatIdx"]}</formatIndex>')
        lines.append('\t\t\t<empty>true</empty>')
        lines.append('\t\t</row>')
        lines.append('\t</rowsItem>')

    def add_gap_row(key, row, column_set, format_idx):
        gap = pending_gap[0]
        if gap is not None and gap['Key'] == key and gap['End'] == row - 1:
            gap['End'] = row
            return
        flush_gap()
        pending_gap[0] = {'Key': key, 'Start': row, 'End': row,
                          'ColumnSet': column_set, 'FormatIdx': format_idx}

    for area in defn['areas']:
        area_start_row = global_row
        area_name = area.get('name', '')
        active_rowspans = []
        local_row = 0
        # Ссылка области на колоночную раскладку — её получают все строки области.
        # Раскладка адресуется ИМЕНЕМ из columnSets — инлайновой формы в этом DSL нет ни у чего
        # (стиль и шрифт тоже только по имени). Иначе сообщение включало бы сериализованный
        # объект, а он у портов выглядит по-разному.
        if isinstance(area.get('columnSet'), (dict, list)):
            print(f'\'columnSet\' must be a name declared in columnSets, got an object:'
                  f' area "{area.get("name", "")}"', file=sys.stderr)
            sys.exit(1)
        area_column_set_name = str(area.get('columnSet') or '')
        area_column_set = ''
        area_layout = column_layouts[0]
        if area_column_set_name:
            area_layout = next((x for x in column_layouts if x['Name'] == area_column_set_name), None)
            if area_layout is None:
                print(f'Unknown \'columnSet\': "{area_column_set_name}" is not declared in columnSets',
                      file=sys.stderr)
                sys.exit(1)
            area_column_set = area_layout['Id']
        # Ширина сетки — у КАЖДОЙ раскладки своя, поэтому позиции колонок сверяем с ней,
        # а не с документным columns (у макетов с раскладками умолчание бывает и пустым).
        area_columns = int(area_layout['Size'])

        for row in area.get('rows', []):
            # Empty row placeholder: emit N empty rows
            if row.get('empty'):
                count = int(row['empty'])
                for ei in range(count):
                    add_gap_row('|0', global_row, '', 0)
                    global_row += 1
                    local_row += 1
                continue

            # Build set of columns occupied by rowspans from previous rows
            rowspan_occupied = {}
            for rs in active_rowspans:
                if local_row > rs['StartLocalRow'] and local_row <= rs['EndLocalRow']:
                    for c in range(rs['ColStart'], rs['ColEnd'] + 1):
                        rowspan_occupied[c] = True

            row_has_content = False
            row_cells = []

            # Determine row height format
            # Формат самой строки — высота, скрытие и стиль строки, если он ложится на строку
            row_format_idx = 0
            row_props = row_format_props(row)
            if row_props:
                row_format_idx = register_format(row_props)

            rs_name, rs_apply = row_style_spec(row.get('rowStyle'), 'row')
            cells_style = None if rs_apply == 'row' else rs_name

            if row.get('cells') and len(row['cells']) > 0:
                row_has_content = True

                # Прощающий ввод: строка, в которой НИ У ОДНОЙ ячейки нет col, раскладывается
                # слева направо с учётом span и rowspan сверху. Канон один и он в документации —
                # col обязателен; здесь мы лишь спасаем естественный DSL вместо тихой порчи
                # (в ps1 $null -> [int]0 -> Col = -1). Смешанную строку не угадываем: это опечатка.
                positioned = [c for c in row['cells']
                              if 'col' in c and c.get('col') is not None and str(c.get('col')) != '']
                if len(positioned) == 0:
                    cursor = 1
                    for cell in row['cells']:
                        col_span = int(cell.get('span', 1))
                        while any(c in rowspan_occupied for c in range(cursor, cursor + col_span)):
                            cursor += 1
                        if cursor + col_span - 1 > area_columns:
                            print(f'Row exceeds \'columns\' ({area_columns}): area "{area_name}",'
                                  f' row {local_row + 1}', file=sys.stderr)
                            sys.exit(1)
                        cell['col'] = cursor
                        cursor += col_span
                elif len(positioned) != len(row['cells']):
                    print(f'Cell without \'col\' mixed with positioned cells: area "{area_name}",'
                          f' row {local_row + 1}', file=sys.stderr)
                    sys.exit(1)

                # Позиция обязана быть в 1..columns: до этой проверки нечисловой или нулевой col
                # ронял py голым KeyError/ValueError, а ps1 молча писал Col = -1.
                for cell_idx, cell in enumerate(row['cells'], start=1):
                    col_parsed = parse_col_value(cell.get('col'))
                    if col_parsed is None or col_parsed < 1 or col_parsed > area_columns:
                        print(f'Invalid \'col\' value "{cell.get("col")}": area "{area_name}",'
                              f' row {local_row + 1}, cell {cell_idx}', file=sys.stderr)
                        sys.exit(1)

                # Build set of occupied columns (1-based)
                occupied_cols = dict(rowspan_occupied)
                for cell in row['cells']:
                    col_start = int(cell['col'])
                    col_span = int(cell.get('span', 1))
                    for c in range(col_start, col_start + col_span):
                        occupied_cols[c] = True

                # Generate explicit cells
                for cell in row['cells']:
                    col_start = int(cell['col'])
                    col_span = int(cell.get('span', 1))
                    rowspan = int(cell.get('rowspan', 1))
                    cell_style = cell.get('style') or cells_style or 'default'
                    ft = get_fill_type(cell)
                    vp = cell_value_props(cell, f'area "{area_name}", row {local_row + 1}')
                    fmt_idx = register_cell_format(cell_style, ft, vp)
                    note = cell_note(cell, f'area "{area_name}", row {local_row + 1}')
                    note_fmt = register_note_format(note) if note else 0

                    cell_info = {
                        'Col': col_start - 1,  # 0-based
                        'FormatIdx': fmt_idx,
                        'Param': cell.get('param'),
                        'Detail': cell.get('detail'),
                        'PictureParam': cell.get('pictureParameter'),
                        'Text': cell.get('text'),
                        'Template': cell.get('template'),
                        'Value': (cell_value(cell, vp.get('valueType', ''),
                                             f'area "{area_name}", row {local_row + 1}') if vp else None),
                        'Control': (cell.get('control') if vp else None),
                        'Note': note,
                        'NoteFmt': note_fmt,
                    }
                    row_cells.append(cell_info)

                    # Track rowspan for subsequent rows
                    if rowspan > 1:
                        active_rowspans.append({
                            'ColStart': col_start,
                            'ColEnd': col_start + col_span - 1,
                            'StartLocalRow': local_row,
                            'EndLocalRow': local_row + rowspan - 1,
                        })

                    # Collect merge
                    if col_span > 1 or rowspan > 1:
                        merge = {'R': global_row, 'C': col_start - 1, 'W': col_span - 1}
                        if rowspan > 1:
                            merge['H'] = rowspan - 1
                        merges.append(merge)

                # Generate gap-fill cells for rowStyle
                if cells_style:
                    gap_fmt_idx = register_cell_format(cells_style, '')
                    for c in range(1, total_columns + 1):
                        if c not in occupied_cols:
                            row_cells.append({
                                'Col': c - 1,
                                'FormatIdx': gap_fmt_idx,
                                'Param': None,
                                'Detail': None,
                                'Text': None,
                                'Template': None,
                            })

                # Sort cells by column
                row_cells.sort(key=lambda x: x['Col'])

            elif cells_style:
                # Row with only rowStyle, no explicit cells
                row_has_content = True
                gap_fmt_idx = register_cell_format(cells_style, '')
                for c in range(1, total_columns + 1):
                    if c in rowspan_occupied:
                        continue
                    row_cells.append({
                        'Col': c - 1,
                        'FormatIdx': gap_fmt_idx,
                        'Param': None,
                        'Detail': None,
                        'Text': None,
                        'Template': None,
                    })

            # Emit rowsItem.
            # Подряд идущие ОДИНАКОВЫЕ пустые строки платформа хранит одним элементом с indexTo;
            # непустые не схлопывает, даже когда они совпадают. Поэтому пустую строку не пишем
            # сразу, а копим в пробеле и сбрасываем, когда он оборвался.
            if not row_has_content:
                # Пустая строка тоже принадлежит раскладке: без этой записи привязка
                # именованной области, накрывающей пустые строки, не выводилась.
                row_column_set[global_row] = area_column_set
                add_gap_row(f'{area_column_set}|{row_format_idx}', global_row,
                            area_column_set, row_format_idx)
                local_row += 1
                global_row += 1
                continue
            flush_gap()

            lines.append('\t<rowsItem>')
            lines.append(f'\t\t<index>{global_row}</index>')
            lines.append('\t\t<row>')

            row_column_set[global_row] = area_column_set
            if area_column_set:
                lines.append(f'\t\t\t<columnsID>{area_column_set}</columnsID>')

            if row_format_idx > 0:
                lines.append(f'\t\t\t<formatIndex>{row_format_idx}</formatIndex>')

            # Номер колонки платформа пишет только при разрыве: подряд идущая ячейка его не
            # несёт, читатель ведёт счётчик сам. Начальное значение счётчика -1, то есть у
            # ячейки в колонке 0 номера тоже нет.
            prev_col = -1
            for cell_info in row_cells:
                lines.append('\t\t\t<c>')
                if cell_info['Col'] != prev_col + 1:
                    lines.append(f'\t\t\t\t<i>{cell_info["Col"]}</i>')
                prev_col = cell_info['Col']
                lines.append('\t\t\t\t<c>')
                lines.append(f'\t\t\t\t\t<f>{cell_info["FormatIdx"]}</f>')

                if cell_info['Param']:
                    lines.append(f'\t\t\t\t\t<parameter>{cell_info["Param"]}</parameter>')

                # Проверяем НАЛИЧИЕ ключа, а не истинность: пустая строка — это текст,
                # платформа такие ячейки пишет с пустым <tl>, и по истинности он терялся.
                if cell_info['Text'] is not None:
                    emit_cell_text(lines, cell_info['Text'])

                if cell_info['Template'] is not None:
                    emit_cell_text(lines, cell_info['Template'])

                if cell_info.get('Value') is not None:
                    val = cell_info['Value']
                    lines.append(f'\t\t\t\t\t<v xsi:type="{val["Type"]}">{esc_xml_text(val["Text"])}</v>')

                # Настройки элемента управления платформа сериализует в base64 и держит у самой
                # ячейки. Структуру не разбираем — возим дословно, иначе она теряется.
                if cell_info.get('Control'):
                    # Блоб платформа переносит по строкам, а строки документа склеиваются
                    # позже — поэтому каждую строку блоба кладём отдельным элементом списка,
                    # иначе перевод строки внутри значения разошёлся бы с остальным файлом.
                    parts = str(cell_info['Control']).replace('\r\n', '\n').split('\n')
                    parts[0] = f'\t\t\t\t\t<control xsi:type="xs:base64Binary">{parts[0]}'
                    parts[-1] = f'{parts[-1]}</control>'
                    lines.extend(parts)

                # Расшифровка от параметра заполнения не зависит: на корпусе 20 404 ячейки несут
                # её БЕЗ параметра (у текста, у пустой ячейки, у поля ввода) против 8 582 с ним.
                # Пока она стояла внутри ветки параметра, две трети расшифровок терялись молча.
                # Порядок тегов ячейки снят с корпуса: parameter · текст · detailParameter.
                if cell_info['Detail']:
                    lines.append(f'\t\t\t\t\t<detailParameter>{cell_info["Detail"]}</detailParameter>')

                # Третий параметр ячейки — имя параметра, которым подставляют картинку. Сама
                # картинка при этом задаётся оформлением (picIndex), а параметр — тут, последним
                # из параметров ячейки (21 ячейка корпуса, порядок везде такой).
                if cell_info.get('PictureParam'):
                    lines.append('\t\t\t\t\t<pictureParameter>'
                                 f'{esc_xml_text(cell_info["PictureParam"])}</pictureParameter>')

                # Якорь конца примечания — координаты самой ячейки, поэтому его не задают:
                # он выводится здесь, при эмиссии.
                if cell_info.get('Note') is not None:
                    emit_cell_note(lines, cell_info['Note'], cell_info['NoteFmt'],
                                   global_row, cell_info['Col'])

                lines.append('\t\t\t\t</c>')
                lines.append('\t\t\t</c>')

            lines.append('\t\t</row>')
            lines.append('\t</rowsItem>')

            local_row += 1
            global_row += 1

        area_end_row = global_row - 1
        # Блок без имени — просто кусок сетки: строки, не принадлежащие ни одной именованной
        # области (в корпусе таких дыр 34%, а макетов вовсе без Rows-областей — 21%).
        # Имя на блоке — сахар: разворачиваем его в обычную именованную область типа Rows.
        if area_name:
            named_items.append({
                'Name': area_name,
                'BeginRow': area_start_row,
                'EndRow': area_end_row,
                'BeginCol': -1,
                'EndCol': -1,
                'ColumnSet': area_column_set,
            })

    flush_gap()

    total_row_count = global_row

    # 7d-bis. Именованные области, заданные координатами (namedAreas).
    # Нужны для всего, что блоком не выражается: области не-Rows и пересекающиеся Rows.
    # Ось, которую не указали, означает «вся» — так же устроен ТабличныйДокумент.Область().

    def to_area_range(spec, axis, where):
        """Диапазон — та же грамматика, что у columnWidths: число или "N-M". Список через
        запятую для области бессмыслен: область непрерывна, платформа разрывную не хранит."""
        if spec is None:
            return None
        s = str(spec).strip()
        if s == '':
            return None
        if ',' in s:
            print(f'namedAreas: \'{axis}\' must be a single number or range, got list "{s}": {where}',
                  file=sys.stderr)
            sys.exit(1)
        m = re.match(r'^(\d+)\s*-\s*(\d+)$', s)
        if m:
            frm, to = int(m.group(1)), int(m.group(2))
        elif re.match(r'^\d+$', s):
            frm = to = int(s)
        else:
            print(f'namedAreas: invalid \'{axis}\' value "{s}": {where}', file=sys.stderr)
            sys.exit(1)
        # Платформа трактует 0 как 1 (см. описание Область()) — принимаем так же.
        if frm < 1:
            frm = 1
        if to < frm:
            print(f'namedAreas: \'{axis}\' range is reversed "{s}": {where}', file=sys.stderr)
            sys.exit(1)
        return (frm, to)

    def from_r1c1(s):
        """Прощающий ввод: платформенный адрес "R1C1:R2C2" — модель, пишущая код на встроенном
        языке, естественно потянется за ним. В документацию не выносим."""
        s = s.strip()
        m = re.match(r'^R(\d+)(?:C(\d+))?(?::R(\d+)(?:C(\d+))?)?$', s, re.IGNORECASE)
        if not m:
            m2 = re.match(r'^C(\d+)(?::C(\d+))?$', s, re.IGNORECASE)
            if not m2:
                return None
            c1 = int(m2.group(1))
            c2 = int(m2.group(2)) if m2.group(2) else c1
            return (None, (c1, c2))
        r1 = int(m.group(1))
        r2 = int(m.group(3)) if m.group(3) else r1
        cols = None
        if m.group(2):
            c1 = int(m.group(2))
            c2 = int(m.group(4)) if m.group(4) else c1
            cols = (c1, c2)
        return ((r1, r2), cols)

    for na_idx, na in enumerate(defn.get('namedAreas') or [], start=1):
        na_name = str(na.get('name') or '')
        where = f'namedAreas[{na_idx}]' + (f' "{na_name}"' if na_name else '')
        if not na_name:
            print(f'namedAreas: \'name\' is required: {where}', file=sys.stderr)
            sys.exit(1)
        rows = to_area_range(na.get('rows'), 'rows', where)
        cols = to_area_range(na.get('cols'), 'cols', where)
        if not rows and not cols:
            addr = None
            for k in ('area', 'at', 'address'):
                if na.get(k):
                    addr = str(na.get(k))
                    break
            if addr:
                parsed = from_r1c1(addr)
                if parsed is None:
                    print(f'namedAreas: invalid address "{addr}": {where}', file=sys.stderr)
                    sys.exit(1)
                rows, cols = parsed
        if not rows and not cols:
            print(f'namedAreas: at least one of \'rows\'/\'cols\' is required: {where}', file=sys.stderr)
            sys.exit(1)
        # Привязка к колоночной раскладке. Три состояния: ключа нет → выводим из накрытых
        # строк; "" → привязки нет вовсе; имя → явная. На корпусе область типа Rows в 13 623
        # случаях повторяет раскладку строк и в 8 179 её не несёт, поэтому вывод обязан
        # переопределяться.
        na_set = ''
        if 'columnSet' in na:
            na_set_name = str(na.get('columnSet') or '')
            if na_set_name:
                na_layout = next((x for x in column_layouts if x['Name'] == na_set_name), None)
                if na_layout is None:
                    print(f"namedAreas: unknown 'columnSet' \"{na_set_name}\": {where}", file=sys.stderr)
                    sys.exit(1)
                na_set = na_layout['Id']
        elif rows:
            covered = {row_column_set[r] for r in range(rows[0] - 1, rows[1]) if r in row_column_set}
            if len(covered) == 1:
                na_set = covered.pop()
        # DSL 1-based, XML 0-based; отсутствующая ось помечается -1.
        named_items.append({
            'Name': na_name,
            'BeginRow': rows[0] - 1 if rows else -1,
            'EndRow': rows[1] - 1 if rows else -1,
            'BeginCol': cols[0] - 1 if cols else -1,
            'EndCol': cols[1] - 1 if cols else -1,
            'ColumnSet': na_set,
        })

    # 7d-bis2. Рисунки идут сразу после строк, до колонтитулов. Порядок тегов снят с корпуса:
    # у всех 11 268 рисунков он один и тот же.
    for dr in drawings:
        lines.append('\t<drawing>')
        lines.append(f'\t\t<drawingType>{dr["Type"]}</drawingType>')
        lines.append(f'\t\t<id>{dr["Id"]}</id>')
        lines.append(f'\t\t<formatIndex>{dr["FormatIdx"]}</formatIndex>')
        if dr['Detail']:
            lines.append(f'\t\t<detailParameter>{dr["Detail"]}</detailParameter>')
        if dr['Text'] is not None:
            value = dr['Text']
            if isinstance(value, dict):
                pairs = [(str(k), str(v)) for k, v in value.items()]
            else:
                pairs = [(lang, str(value)) for lang in text_languages]
            lines.append('\t\t<text>')
            for lang, content in pairs:
                lines.append('\t\t\t<v8:item>')
                lines.append(f'\t\t\t\t<v8:lang>{lang}</v8:lang>')
                lines.append(f'\t\t\t\t<v8:content>{esc_xml_text(content)}</v8:content>')
                lines.append('\t\t\t</v8:item>')
            lines.append('\t\t</text>')
        lines.append(f'\t\t<beginRow>{dr["Begin"]["Row"]}</beginRow>')
        lines.append(f'\t\t<beginRowOffset>{dr["Begin"]["Dy"]}</beginRowOffset>')
        lines.append(f'\t\t<endRow>{dr["End"]["Row"]}</endRow>')
        lines.append(f'\t\t<endRowOffset>{dr["End"]["Dy"]}</endRowOffset>')
        lines.append(f'\t\t<beginColumn>{dr["Begin"]["Col"]}</beginColumn>')
        lines.append(f'\t\t<beginColumnOffset>{dr["Begin"]["Dx"]}</beginColumnOffset>')
        lines.append(f'\t\t<endColumn>{dr["End"]["Col"]}</endColumn>')
        lines.append(f'\t\t<endColumnOffset>{dr["End"]["Dx"]}</endColumnOffset>')
        # autoSize у рисунка на корпусе всегда false (11 268 из 11 268), «АвтоРазмер» из
        # диалога уходит в pictureSize.
        lines.append('\t\t<autoSize>false</autoSize>')
        lines.append(f'\t\t<pictureSize>{dr["PictureSize"]}</pictureSize>')
        lines.append(f'\t\t<zOrder>{dr["ZOrder"]}</zOrder>')
        if dr['PictureIdx'] > 0:
            lines.append(f'\t\t<pictureIndex>{dr["PictureIdx"]}</pictureIndex>')
        lines.append('\t</drawing>')

    # 7d-ter. Колонтитулы: шесть слотов идут после строк и перед скалярными свойствами документа.
    for slot in ('left', 'center', 'right'):
        if defn.get('header'):
            emit_header_slot(lines, f'{slot}Header', defn['header'].get(slot), header_fmt)
    for slot in ('left', 'center', 'right'):
        if defn.get('footer'):
            emit_header_slot(lines, f'{slot}Footer', defn['footer'].get(slot), footer_fmt)

    # 7e-bis. Группировки строк и колонок. Платформа хранит их плоским списком диапазонов;
    # вложенность выражена вхождением одного диапазона в другой, а частичных пересечений не
    # бывает вовсе (корпус: 40 620 886 пар непересекающихся, 599 958 вложенных, 0 частичных).
    def parse_groups(key, axis):
        out = []
        for i, g in enumerate(defn.get(key) or [], start=1):
            where = f'{key}[{i}]'
            if not isinstance(g, dict):
                print(f'{key}: element must be an object: {where}', file=sys.stderr)
                sys.exit(1)
            spec = g.get(axis)
            if spec is None or str(spec).strip() == '':
                print(f"{key}: '{axis}' is required: {where}", file=sys.stderr)
                sys.exit(1)
            spec = str(spec).strip()
            m = re.match(r'^(\d+)\s*-\s*(\d+)$', spec)
            if m:
                frm, to = int(m.group(1)), int(m.group(2))
            elif re.match(r'^\d+$', spec):
                frm = to = int(spec)
            else:
                print(f"{key}: invalid '{axis}' value \"{spec}\": {where}", file=sys.stderr)
                sys.exit(1)
            if frm < 1:
                frm = 1
            if to < frm:
                print(f"{key}: '{axis}' range is reversed \"{spec}\": {where}", file=sys.stderr)
                sys.exit(1)
            header = g.get('titleLocation')
            header = str(header).strip().lower() if header is not None else ''
            if header in ('', 'auto'):
                header = ''
            elif header == 'begin':
                header = 'Begin'
            elif header == 'end':
                header = 'End'
            else:
                print(f"{key}: unknown 'titleLocation' value \"{g.get('titleLocation')}\""
                      f' ({where}). Allowed: begin, end, auto', file=sys.stderr)
                sys.exit(1)
            out.append({
                'B': frm - 1, 'E': to - 1,
                'Name': g.get('name'),
                'Collapsed': g.get('collapsed') is True or str(g.get('collapsed')).lower() == 'true',
                'Header': header,
            })
        for i in range(len(out)):
            for j in range(i + 1, len(out)):
                a, b = out[i], out[j]
                if a['E'] < b['B'] or b['E'] < a['B']:
                    continue
                if (a['B'] <= b['B'] and b['E'] <= a['E']) or (b['B'] <= a['B'] and a['E'] <= b['E']):
                    continue
                print(f'{key}: ranges must nest or be disjoint, got a partial overlap'
                      f' ({a["B"] + 1}-{a["E"] + 1} and {b["B"] + 1}-{b["E"] + 1})', file=sys.stderr)
                sys.exit(1)
        # Порядок платформы — родитель раньше детей, по возрастанию начала.
        out.sort(key=lambda x: (x['B'], -x['E']))
        return out

    row_groups = parse_groups('rowGroups', 'rows')
    col_groups = parse_groups('columnGroups', 'cols')

    def group_levels(groups):
        """Глубина вложенности. На корпусе она совпала с <vgLevels> у всех 1797 макетов."""
        depth = 0
        for i, g in enumerate(groups):
            d = 1
            for j, o in enumerate(groups):
                if j != i and o['B'] <= g['B'] and g['E'] <= o['E'] and (o['B'], o['E']) != (g['B'], g['E']):
                    d += 1
            depth = max(depth, d)
        return depth

    def emit_groups(lines, tag, groups):
        for g in groups:
            lines.append(f'\t<{tag}>')
            lines.append(f'\t\t<b>{g["B"]}</b>')
            if g['E'] != g['B']:
                lines.append(f'\t\t<e>{g["E"]}</e>')
            if g['Name'] is not None:
                value = g['Name']
                if isinstance(value, dict):
                    pairs = [(str(k), str(v)) for k, v in value.items()]
                else:
                    pairs = [(lang, str(value)) for lang in text_languages]
                lines.append('\t\t<t>')
                for lang, content in pairs:
                    lines.append('\t\t\t<v8:item>')
                    lines.append(f'\t\t\t\t<v8:lang>{lang}</v8:lang>')
                    lines.append(f'\t\t\t\t<v8:content>{esc_xml_text(content)}</v8:content>')
                    lines.append('\t\t\t</v8:item>')
                lines.append('\t\t</t>')
            # Развёрнутая группировка тега не пишет: на корпусе <o> только со значением false.
            if g['Collapsed']:
                lines.append('\t\t<o>false</o>')
            if g['Header']:
                lines.append(f'\t\t<g>{g["Header"]}</g>')
            lines.append(f'\t</{tag}>')

    # 7e. Scalar metadata
    lines.append(f'\t<templateMode>true</templateMode>')
    lines.append(f'\t<defaultFormatIndex>{default_format_index}</defaultFormatIndex>')
    # Рисунок расширяет документ, не создавая строк: на стендах высота равна нижней границе
    # самого нижнего рисунка, при том что строк записана всего одна.
    doc_height = total_row_count
    for dr in drawings:
        doc_height = max(doc_height, dr['End']['Row'] + 1)
    lines.append(f'\t<height>{doc_height}</height>')
    if row_groups:
        lines.append(f'\t<vgLevels>{group_levels(row_groups)}</vgLevels>')
    lines.append(f'\t<vgRows>{doc_height}</vgRows>')
    emit_groups(lines, 'vg', row_groups)
    emit_groups(lines, 'hg', col_groups)

    emit_print_settings(lines, defn.get('printSettings'))

    # 7f. Merges
    for m in merges:
        lines.append('\t<merge>')
        lines.append(f'\t\t<r>{m["R"]}</r>')
        lines.append(f'\t\t<c>{m["C"]}</c>')
        if m.get('H'):
            lines.append(f'\t\t<h>{m["H"]}</h>')
        lines.append(f'\t\t<w>{m["W"]}</w>')
        lines.append('\t</merge>')

    # 7g. Named items
    # Платформа хранит именованные элементы ОТСОРТИРОВАННЫМИ по имени: на выборке 541 макета
    # с несколькими элементами иного порядка нет ни разу. Сортировка регистронезависимая и
    # ординальная (в ps1 поэтому нельзя Sort-Object — он сортирует по текущей культуре).
    # NB: имён с «ё» в выборке не встретилось, этот случай не проверен.
    # Имя рисунка — namedItem другого типа, но список общий: на корпусе оба вида отсортированы
    # вместе по имени во всех 266 макетах с именованными рисунками.
    for dr in drawings:
        if dr['Name']:
            named_items.append({'Name': str(dr['Name']), 'DrawingId': dr['Id']})

    for ni in sorted(named_items, key=lambda x: str(x['Name']).lower()):
        if ni.get('DrawingId'):
            lines.append('\t<namedItem xsi:type="NamedItemDrawing">')
            lines.append(f'\t\t<name>{ni["Name"]}</name>')
            lines.append(f'\t\t<drawingID>{ni["DrawingId"]}</drawingID>')
            lines.append('\t</namedItem>')
            continue
        # Тип области выводится из указанных осей, как в ТабличныйДокумент.Область():
        # нет колонок → полоса строк, нет строк → полоса колонок, обе → прямоугольник.
        has_rows = int(ni['BeginRow']) >= 0
        has_cols = int(ni.get('BeginCol', -1)) >= 0
        area_type = 'Rectangle' if (has_rows and has_cols) else ('Columns' if has_cols else 'Rows')
        lines.append('\t<namedItem xsi:type="NamedItemCells">')
        lines.append(f'\t\t<name>{ni["Name"]}</name>')
        lines.append('\t\t<area>')
        lines.append(f'\t\t\t<type>{area_type}</type>')
        lines.append(f'\t\t\t<beginRow>{ni["BeginRow"]}</beginRow>')
        lines.append(f'\t\t\t<endRow>{ni["EndRow"]}</endRow>')
        lines.append(f'\t\t\t<beginColumn>{ni.get("BeginCol", -1)}</beginColumn>')
        lines.append(f'\t\t\t<endColumn>{ni.get("EndCol", -1)}</endColumn>')
        if ni.get('ColumnSet'):
            lines.append(f'\t\t\t<columnsID>{ni["ColumnSet"]}</columnsID>')
        lines.append('\t\t</area>')
        lines.append('\t</namedItem>')

    # 7h. Line palette
    for ln in line_registry:
        lines.append(f'\t<line width="{ln["Width"]}" gap="{ln["Gap"]}">')
        line_kind = ('SpreadsheetDocumentDrawingLineType' if ln.get('Kind') == 'Drawing'
                     else 'SpreadsheetDocumentCellLineType')
        lines.append(f'\t\t<v8ui:style xsi:type="v8ui:{line_kind}">{ln["Style"]}</v8ui:style>')
        lines.append('\t</line>')

    # 7i. Font palette
    for fe in font_entries:
        if fe.get('Ref'):
            # Префикс sys в корне документа не объявлен, поэтому платформа дописывает
            # объявление прямо на узел — тот же приём, что с цветами из web-палитры.
            if fe['Ref'].startswith('sys:'):
                lines.append(f'	<font xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"'
                             f' ref="{esc_xml(fe["Ref"])}" kind="{fe["Kind"]}"/>')
            else:
                lines.append(f'	<font ref="{esc_xml(fe["Ref"])}" kind="{fe["Kind"]}"/>')
            continue
        lines.append(f'\t<font faceName="{fe["Face"]}" height="{fe["Size"]}" bold="{fe["Bold"]}" italic="{fe["Italic"]}" underline="{fe["Underline"]}" strikeout="{fe["Strikeout"]}" kind="Absolute" scale="100"/>')

    # 7j. Format palette
    for key in format_order:
        fmt = format_registry[key]
        lines.append('\t<format>')

        ml_tags = format_ml_tags()
        kinds = format_tag_kind()
        for tag in format_tag_order():
            if tag not in fmt:
                continue
            val = fmt[tag]
            if tag in ml_tags:
                lines.append(f'\t\t<{tag}>')
                lines.append('\t\t\t<v8:item>')
                lines.append('\t\t\t\t<v8:lang>ru</v8:lang>')
                lines.append(f'\t\t\t\t<v8:content>{esc_xml_text(val)}</v8:content>')
                lines.append('\t\t\t</v8:item>')
                lines.append(f'\t\t</{tag}>')
            elif tag == 'valueType':
                # Пустой тип — самостоятельное состояние: «содержит значение», тип не задан.
                if str(val) == '':
                    lines.append('\t\t<valueType/>')
                else:
                    lines.append('\t\t<valueType>')
                    emit_value_type_content(lines, '\t\t\t', str(val))
                    lines.append('\t\t</valueType>')
            elif kinds.get(tag) == 'color' and color_namespace(str(val)):
                # web/win-палитры в корне документа не объявлены — платформа дописывает
                # объявление прямо на узел и пишет значение с этим префиксом.
                ns = color_namespace(str(val))
                name = str(val)[str(val).index(':') + 1:]
                lines.append(f'\t\t<{tag} xmlns:d3p1="{ns}">d3p1:{name}</{tag}>')
            else:
                lines.append(f'\t\t<{tag}>{val}</{tag}>')

        lines.append('\t</format>')

    # 7k. Палитра картинок — последний блок документа. Индекс здесь 0-based, а ссылки
    # на него (pictureIndex рисунка, picIndex стиля) 1-based.
    for pic_i, pic in enumerate(picture_entries):
        lines.append('\t<picture>')
        lines.append(f'\t\t<index>{pic_i}</index>')
        # Прозрачность записывается перед ссылкой и не зависит от того, где лежит картинка:
        # в БП 8.3.27 таких ссылочных записей 67.
        attr = f' t="{pic["Transparent"]}"' if pic['Transparent'] else ''
        if pic['PixelX']:
            attr += f' tx="{pic["PixelX"]}" ty="{pic["PixelY"]}"'
        if pic['Ref']:
            lines.append(f'\t\t<picture{attr} ref="{esc_xml(pic["Ref"])}"/>')
        elif not pic['Data']:
            lines.append('\t\t<picture/>')
        else:
            # Данные платформа переносит по строкам тем же переводом, что и весь файл, —
            # в отличие от блоба настроек элемента управления, где перенос голый LF.
            parts = str(pic['Data']).replace('\r\n', '\n').split('\n')
            parts[0] = f'\t\t<picture{attr}>{parts[0]}'
            parts[-1] = f'{parts[-1]}</picture>'
            lines.extend(parts)
        lines.append('\t</picture>')

    # 7l. Close document
    lines.append('</document>')

    # --- 8. Write output ---
    out_path = args.OutputPath
    if not os.path.isabs(out_path):
        out_path = os.path.join(os.getcwd(), out_path)

    assert_edit_allowed(out_path, "editable")

    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    content = '\r\n'.join(lines)
    write_utf8_bom(out_path, content)

    # --- 9. Summary ---
    print(f"[OK] Compiled: {args.OutputPath}")
    if defn.get('page'):
        print(f"     Page: {page_name} -> target {target_width}, defaultWidth={default_width}")
    print(f"     Areas: {len(named_items)}, Rows: {total_row_count}, Columns: {total_columns}")
    print(f"     Fonts: {len(font_entries)}, Lines: {len(line_registry)}, Formats: {len(format_registry)}")
    print(f"     Merges: {len(merges)}")


if __name__ == '__main__':
    main()
