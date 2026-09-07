#!/usr/bin/env python3
# mxl-decompile v1.31 — Decompile 1C spreadsheet to JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import sys
from collections import OrderedDict
from lxml import etree

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


# --- Namespace map ---

NSMAP = {
    "d": "http://v8.1c.ru/8.2/data/spreadsheet",
    "v8": "http://v8.1c.ru/8.1/data/core",
    "v8ui": "http://v8.1c.ru/8.1/data/ui",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
}

XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"


def find(node, xpath):
    return node.find(xpath, NSMAP)


def findall(node, xpath):
    return node.findall(xpath, NSMAP)


def text_of(node):
    if node is not None and node.text:
        return node.text
    return None


def to_font_size(raw):
    """Размер шрифта бывает дробным (8.3, 11.3 — в корпусе ERP это треть макетов).
    int() на таком падал, а ps1 ТИХО округлял. Целое держим целым, иначе "10" → "10.0"."""
    s = str(raw).strip() if raw is not None else ''
    if not s:
        return 0
    try:
        d = float(s)
    except (TypeError, ValueError):
        return 0
    return int(d) if d == int(d) else d


def format_tag_kind():
    """Тип значения каждого тега — выведен из корпуса, а не выписан на глаз.
    line — ссылка в палитру <line>; color — #RRGGBB / style: / web: / win:
    ml — многоязычная строка; enum — замкнутый список (см. format_enum_values).
    containsValue / valueType / controlType сюда НЕ входят: это свойства конкретной ячейки,
    а стиль — сущность общая, один на многие ячейки."""
    return {
        'autoIndent': 'int', 'autoMarkIncomplete': 'bool', 'autoWidthCalculation': 'bool',
        'backColor': 'color', 'border': 'line', 'borderColor': 'color',
        'bottomBorder': 'line', 'bySelectedColumns': 'bool', 'columnSizeChange': 'enum',
        'detailsUse': 'enum', 'drawingBorder': 'line',
        'drawingHaveBottomBorder': 'bool', 'drawingHaveLeftBorder': 'bool',
        'drawingHaveRightBorder': 'bool', 'drawingHaveTopBorder': 'bool',
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


RU_NAME = 'Русский'


def format_ml_tags():
    """Теги, значение которых — многоязычная строка (<v8:item> на язык), а не скаляр."""
    return {'format': True, 'editFormat': True, 'mask': True}


def color_to_dsl(node, val):
    """Цвет платформа хранит значением с префиксом пространства имён. style: объявлен в корне
    документа и читается как есть; web/win объявлены прямо на узле сгенерированным префиксом
    (d3p1), поэтому его надо разрешить в URI и вернуть привычное web:/win:."""
    if ':' not in val or val.startswith('style:'):
        return val
    prefix, name = val.split(':', 1)
    uri = node.nsmap.get(prefix)
    if uri == 'http://v8.1c.ru/8.1/data/ui/colors/web':
        return 'web:' + name
    if uri == 'http://v8.1c.ru/8.1/data/ui/colors/windows':
        return 'win:' + name
    return val


CFG_NS = 'http://v8.1c.ru/8.1/data/enterprise/current-config'

# Элемент управления ячейки: в выгрузке это GUID, имён у платформы в XML нет.
VALUE_CONTROL_NAMES = {
    '381ed624-9217-4e63-85db-c4c3cb87daae': 'input',
    '35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26': 'checkbox',
}


def value_type_to_dsl(node):
    """Обратная функция к эмиттеру типа компилятора: <valueType> → строка DSL в КРАТЧАЙШЕЙ
    форме (Boolean, String, String(10,fixed), Number(15,3,nonneg), DateTime, CatalogRef.X,
    AnyRef), из которой компилятор восстановит тот же XML. Пустой тег → пустая строка:
    «содержит значение» без указания типа — самостоятельное состояние.
    Префикс ссылочного типа разрешаем по URI, а не по имени: локальное объявление платформа
    называет сгенерированным dNpM. Чужое пространство имён оставляем как есть."""
    types = []
    quals = {}
    for child in node:
        tag = etree.QName(child).localname
        if tag in ('Type', 'TypeSet'):
            types.append((tag, child, (child.text or '').strip()))
        elif tag.endswith('Qualifiers'):
            quals[tag[:-len('Qualifiers')]] = child

    def qual(kind, name, default=''):
        el = quals.get(kind)
        if el is None:
            return default
        sub = find(el, 'v8:' + name)
        val = text_of(sub)
        return val.strip() if val else default

    parts = []
    for tag, child, val in types:
        if ':' in val:
            prefix, name = val.split(':', 1)
            uri = child.nsmap.get(prefix)
            if uri == CFG_NS:
                val = name
            elif uri == 'http://www.w3.org/2001/XMLSchema':
                val = 'xs:' + name
        if val == 'xs:boolean':
            parts.append('Boolean')
        elif val == 'xs:string':
            length = qual('String', 'Length', '0')
            fixed = qual('String', 'AllowedLength', 'Variable') == 'Fixed'
            if fixed:
                parts.append(f'String({length},fixed)')
            elif length != '0':
                parts.append(f'String({length})')
            else:
                parts.append('String')
        elif val == 'xs:decimal':
            digits = qual('Number', 'Digits', '0')
            fraction = qual('Number', 'FractionDigits', '0')
            nonneg = qual('Number', 'AllowedSign', 'Any') == 'Nonnegative'
            if nonneg:
                parts.append(f'Number({digits},{fraction},nonneg)')
            elif digits != '0' or fraction != '0':
                parts.append(f'Number({digits},{fraction})')
            else:
                parts.append('Number')
        elif val == 'xs:dateTime':
            parts.append(qual('Date', 'DateFractions', 'DateTime'))
        else:
            parts.append(val)
    return ' + '.join(parts)


def value_to_dsl(xsi_type, text):
    """Значение ячейки-поля ввода → литерал DSL. Тип значения выражается самим литералом:
    число → числом, булево → true/false, строка и дата → строкой. Пустое значение пишем
    как есть (0, false, пустая дата), а не схлопываем: так оно собирается обратно тем же
    типом независимо от того, какой тип объявлен у ячейки."""
    text = text or ''
    if xsi_type == 'xs:boolean':
        return text.strip() == 'true'
    if xsi_type == 'xs:decimal':
        s = text.strip()
        try:
            return int(s) if '.' not in s else float(s)
        except ValueError:
            return s
    return text


def int_of(node, default=0):
    if node is not None and node.text:
        return int(node.text)
    return default


# Custom JSON serializer — компактный, 2-пробельный indent, массивы примитивов inline.
# В отличие от ConvertTo-Json (PS5.1):
#   - не выравнивает ключи объекта по самому длинному
#   - не разворачивает массивы примитивов на отдельные строки
#   - кириллица в UTF-8 (без \uXXXX-escapes)
def convert_string_to_json_literal(s):
    if s is None:
        return 'null'
    out = ['"']
    for ch in s:
        code = ord(ch)
        if code == 0x22:
            out.append('\\"')
        elif code == 0x5C:
            out.append('\\\\')
        elif code == 0x08:
            out.append('\\b')
        elif code == 0x09:
            out.append('\\t')
        elif code == 0x0A:
            out.append('\\n')
        elif code == 0x0C:
            out.append('\\f')
        elif code == 0x0D:
            out.append('\\r')
        elif code < 0x20:
            out.append('\\u%04x' % code)
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def _fmt_number(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        # Invariant culture: '.' decimal sep
        if v == int(v):
            # Preserve float-ness: PS [double] 5.0 → "5"
            # Match PS ToString invariant: 5.0 → "5"
            return str(int(v))
        return repr(v)
    return str(v)


def try_inline_json(obj):
    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float)):
        return _fmt_number(obj)
    if isinstance(obj, dict):
        if len(obj) == 0:
            return '{}'
        parts = []
        for k, v in obj.items():
            vs = try_inline_json(v)
            if vs is None:
                return None
            parts.append(convert_string_to_json_literal(str(k)) + ': ' + vs)
        return '{ ' + ', '.join(parts) + ' }'
    if isinstance(obj, (list, tuple)):
        if len(obj) == 0:
            return '[]'
        parts = []
        for it in obj:
            vs = try_inline_json(it)
            if vs is None:
                return None
            parts.append(vs)
        return '[' + ', '.join(parts) + ']'
    return None


def convert_to_compact_json(obj, depth=0, indent_unit='  ', line_limit=400):
    indent = indent_unit * depth
    child_indent = indent_unit * (depth + 1)

    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float)):
        return _fmt_number(obj)

    # Try inline для объектов и массивов с объектами — если помещается в lineLimit с учётом текущего indent.
    is_container = isinstance(obj, (dict, list, tuple))
    if is_container:
        inline_attempt = try_inline_json(obj)
        if inline_attempt is not None and (len(indent) + len(inline_attempt)) <= line_limit:
            return inline_attempt

    if isinstance(obj, dict):
        if len(obj) == 0:
            return '{}'
        parts = []
        for k, v in obj.items():
            val = convert_to_compact_json(v, depth + 1, indent_unit, line_limit)
            parts.append(child_indent + convert_string_to_json_literal(str(k)) + ': ' + val)
        return "{\n" + ",\n".join(parts) + "\n" + indent + "}"
    if isinstance(obj, (list, tuple)):
        if len(obj) == 0:
            return '[]'
        parts = [child_indent + convert_to_compact_json(it, depth + 1, indent_unit, line_limit) for it in obj]
        return "[\n" + ",\n".join(parts) + "\n" + indent + "]"
    return convert_string_to_json_literal(str(obj))


# --- Main ---

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Decompile 1C spreadsheet to JSON", allow_abbrev=False)
    parser.add_argument("-TemplatePath", "-Path", required=True, help="Path to Template.xml")
    parser.add_argument("-OutputPath", default=None, help="Output JSON path (stdout if omitted)")
    args = ci_parse_args(parser)

    template_path = args.TemplatePath
    output_path = args.OutputPath

    # --- 1. Load and parse XML ---

    if not os.path.isfile(template_path):
        print(f"File not found: {template_path}", file=sys.stderr)
        sys.exit(1)

    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(template_path, parser_xml)
    root = tree.getroot()

    # --- 2. Extract font palette ---

    raw_fonts = []
    for f_node in findall(root, "d:font"):
        raw_fonts.append({
            # Шрифт бывает ссылкой на элемент стиля (style:) или системный шрифт (sys:) —
            # тогда своих атрибутов у него нет, и без этого он превращался в пустую запись.
            "Ref": f_node.get("ref", ""),
            "Face": f_node.get("faceName", ""),
            "Size": to_font_size(f_node.get("height", "0")),
            "Bold": f_node.get("bold") == "true",
            "Italic": f_node.get("italic") == "true",
            "Underline": f_node.get("underline") == "true",
            "Strikeout": f_node.get("strikeout") == "true",
        })

    # --- 3. Extract line palette ---

    raw_lines = []
    for l_node in findall(root, "d:line"):
        st = find(l_node, "v8ui:style")
        raw_lines.append({
            "Width": int(l_node.get("width", "0")),
            "Gap": l_node.get("gap", "false"),
            "Style": (text_of(st) or "Solid") if st is not None else "Solid",
        })

    # --- 4. Extract format palette ---

    # Формат читаем целиком — «тег → значение», а не выборочные девять полей. Тип значения
    # берём из общей таблицы, она же у компилятора.
    kinds = format_tag_kind()
    ml_tags = format_ml_tags()

    raw_formats = []
    for fmt_node in findall(root, "d:format"):
        # Совместимость с прежними полями: ими пользуются ширина колонки, высота строки и
        # признак заполнения — они не часть стиля.
        fmt = {
            "FontIdx": -1, "Width": 0, "Height": 0, "FillType": "", "Props": OrderedDict(),
        }
        for child in fmt_node:
            tag = etree.QName(child).localname
            if tag in ml_tags:
                item = find(child, "v8:item/v8:content")
                val = text_of(item) if item is not None else None
                if val:
                    fmt["Props"][tag] = val
                continue
            # Тип значения ячейки — единственный тег со СВОЕЙ структурой: разбираем его до
            # обеих отсечек ниже. Пустой <valueType/> тоже значим — это «содержит значение»
            # без указания типа.
            if tag == "valueType":
                fmt["Props"][tag] = value_type_to_dsl(child)
                continue
            # Вложенный элемент скаляром не является: .text дал бы пустоту, а ps1-порт брал
            # InnerText и получал склейку поддерева — отсюда расхождение портов.
            if len(child):
                continue
            val = (child.text or "").strip()
            if not val:
                continue
            if kinds.get(tag) == "color":
                val = color_to_dsl(child, val)
            fmt["Props"][tag] = val

        if "font" in fmt["Props"]:
            fmt["FontIdx"] = int(fmt["Props"]["font"])
        if "width" in fmt["Props"]:
            fmt["Width"] = int(fmt["Props"]["width"])
        if "height" in fmt["Props"]:
            fmt["Height"] = int(fmt["Props"]["height"])
        if "fillType" in fmt["Props"]:
            fmt["FillType"] = fmt["Props"]["fillType"]

        raw_formats.append(fmt)

    def get_format(idx):
        if idx <= 0 or idx > len(raw_formats):
            return None
        return raw_formats[idx - 1]

    # --- 4-bis. Палитра картинок и рисунки ---
    # Картинка хранится ссылкой на библиотеку либо данными base64; ссылки на палитру (у рисунка
    # pictureIndex, у ячейки picIndex) — 1-based, сам <index> — 0-based.
    pictures_out = OrderedDict()
    picture_key = {}
    for pic_i, pic_node in enumerate(findall(root, "d:picture"), start=1):
        inner = find(pic_node, "d:picture")
        if inner is None:
            continue
        name = f'pic{pic_i}'
        entry = OrderedDict()
        if inner.get("ref"):
            entry["ref"] = inner.get("ref")
        elif (inner.text or "").strip():
            entry["data"] = (inner.text or "").strip()
        # Прозрачность живёт и у ссылочной картинки (в БП 8.3.27 таких записей 67), поэтому
        # читаем её вне ветвления. Пиксель прозрачного цвета — координата внутри картинки.
        if entry and inner.get("t") is not None:
            entry["transparent"] = inner.get("t") == "true"
        if entry and inner.get("tx") is not None:
            entry["transparent"] = OrderedDict([("x", int(inner.get("tx"))),
                                                ("y", int(inner.get("ty") or 0))])
        pictures_out[name] = entry
        picture_key[pic_i] = name

    drawing_names = {}
    for ni_node in findall(root, "d:namedItem"):
        if (ni_node.get(f'{{{XSI_NS}}}type') or '') == 'NamedItemDrawing':
            drawing_names[text_of(find(ni_node, "d:drawingID")) or ''] = text_of(find(ni_node, "d:name")) or ''

    drawings_out = []
    for dr_i, dr in enumerate(findall(root, "d:drawing"), start=1):
        item = OrderedDict()
        item["type"] = text_of(find(dr, "d:drawingType")) or "Picture"
        did = text_of(find(dr, "d:id")) or str(dr_i)
        if did != str(dr_i):
            item["id"] = int(did)
        zorder = text_of(find(dr, "d:zOrder")) or str(dr_i)
        if zorder != str(dr_i):
            item["zOrder"] = int(zorder)
        if did in drawing_names:
            item["name"] = drawing_names[did]
        pic_ref = text_of(find(dr, "d:pictureIndex"))
        if pic_ref and int(pic_ref) in picture_key:
            item["picture"] = picture_key[int(pic_ref)]
        detail = text_of(find(dr, "d:detailParameter"))
        if detail:
            item["detail"] = detail
        t_el = find(dr, "d:text")
        if t_el is not None:
            by_lang = OrderedDict()
            for it in findall(t_el, "v8:item"):
                by_lang[text_of(find(it, "v8:lang")) or ''] = text_of(find(it, "v8:content")) or ''
            item["text"] = by_lang
        # Оформление разбирается позже: линию нужно развернуть в описание, а помощник для
        # этого появляется вместе с палитрой стилей.
        fmt_idx = int_of(find(dr, "d:formatIndex"))

        def anchor(prefix, off_row, off_col):
            return OrderedDict([("row", int_of(find(dr, f'd:{prefix}Row')) + 1),
                                ("col", int_of(find(dr, f'd:{prefix}Column')) + 1),
                                ("dy", int_of(find(dr, f'd:{off_row}'))),
                                ("dx", int_of(find(dr, f'd:{off_col}')))])
        item["begin"] = anchor("begin", "beginRowOffset", "beginColumnOffset")
        item["end"] = anchor("end", "endRowOffset", "endColumnOffset")
        psize = text_of(find(dr, "d:pictureSize"))
        if psize and psize != "Stretch":
            item["pictureSize"] = psize
        item["_fmt"] = fmt_idx
        drawings_out.append(item)

    # --- 4a. Колонтитулы и параметры печати ---
    # Слот колонтитула устроен как ячейка: ссылка на формат плюс текст. Признак вывода и стартовую
    # страницу читаем только у записи, где есть <height>: палитра дедуплицирована, и колонтитул без
    # своих настроек ссылается на чужую запись, где <width> — ширина колонки, а не номер страницы.
    def read_header_part(suffix):
        slots = OrderedDict()
        fmt_idx = None
        for slot in ('left', 'center', 'right'):
            el = find(root, f'd:{slot}{suffix}')
            if el is None:
                continue
            if fmt_idx is None:
                fmt_idx = int_of(find(el, 'd:f'))
            for text_tag in ('tl', 'tfl'):
                t = find(el, 'd:' + text_tag)
                if t is None:
                    continue
                by_lang = OrderedDict()
                for it in findall(t, 'v8:item'):
                    lang = text_of(find(it, 'v8:lang')) or ''
                    by_lang[lang] = text_of(find(it, 'v8:content')) or ''
                value = get_dsl_text(by_lang)
                slots[slot] = OrderedDict([('formatted', value)]) if text_tag == 'tfl' else value
                break
        if not slots and fmt_idx is None:
            return None
        fmt = get_format(fmt_idx) if fmt_idx else None
        if not fmt:
            return slots
        head = OrderedDict()
        if fmt["FontIdx"] >= 0:
            head["font"] = font_names.get(fmt["FontIdx"], "default")
        props = fmt["Props"]
        if 'height' in props:
            if str(props['height']) == '-1':
                head["show"] = False
            width = int(props.get('width', 1))
            if width != 1:
                head["startPage"] = width
        if 'verticalAlignment' in props:
            head["verticalAlignment"] = props['verticalAlignment']
        head.update(slots)
        return head

    print_settings = None
    ps_node = find(root, 'd:printSettings')
    if ps_node is not None:
        print_settings = OrderedDict()
        for c in ps_node:
            name = etree.QName(c).localname
            v = (c.text or '').strip()
            if v == 'true':
                print_settings[name] = True
            elif v == 'false':
                print_settings[name] = False
            else:
                try:
                    print_settings[name] = int(v)
                except ValueError:
                    print_settings[name] = v

    # --- 4b. Группировки строк и колонок ---
    # Платформа хранит их плоским списком диапазонов, родитель раньше детей. Число уровней
    # (<vgLevels>) не читаем: оно выводится из вложенности — совпало на всех 1797 макетах.
    def read_groups(tag, axis):
        out = []
        for g in findall(root, "d:" + tag):
            b = int_of(find(g, "d:b"))
            e_node = find(g, "d:e")
            e = int_of(e_node, b) if e_node is not None else b
            item = OrderedDict()
            item[axis] = (b + 1) if e == b else f'{b + 1}-{e + 1}'
            t_el = find(g, "d:t")
            if t_el is not None:
                by_lang = OrderedDict()
                for it in findall(t_el, "v8:item"):
                    lang = text_of(find(it, "v8:lang")) or ''
                    by_lang[lang] = text_of(find(it, "v8:content")) or ''
                if by_lang:
                    item["name"] = by_lang
            if (text_of(find(g, "d:o")) or 'true').strip() == 'false':
                item["collapsed"] = True
            place = text_of(find(g, "d:g"))
            if place:
                item["titleLocation"] = place.strip().lower()
            out.append(item)
        return out

    row_groups = read_groups("vg", "rows")
    col_groups = read_groups("hg", "cols")

    # --- 5. Extract columns and default width ---

    # Колоночная раскладка («индивидуальная ширина колонок» для группы строк) — элемент <columns>.
    # Их бывает несколько: раскладка БЕЗ <id> — умолчание (ровно одна в каждом макете корпуса),
    # остальные адресуются GUID из <id>, на который ссылаются строки (<row><columnsID>) и
    # области (<area><columnsID>). Раньше читался только первый <columns> — отсюда терялись
    # ширины и вылезал columns: 0.

    default_fmt_idx = 0
    n = find(root, "d:defaultFormatIndex")
    if n is not None and n.text:
        default_fmt_idx = int(n.text)

    default_width = 10
    if default_fmt_idx > 0:
        def_fmt = get_format(default_fmt_idx)
        if def_fmt and def_fmt["Width"] > 0:
            default_width = def_fmt["Width"]

    def read_column_set(node):
        by_idx = {}
        for ci in findall(node, "d:columnsItem"):
            by_idx[int_of(find(ci, "d:index"))] = int_of(find(ci, "d:column/d:formatIndex"))
        # Карта ширин (1-based колонка → ширина), только отличные от умолчания.
        widths = OrderedDict()
        for col0 in sorted(by_idx.keys()):
            fmt = get_format(by_idx[col0])
            if fmt and fmt["Width"] > 0 and fmt["Width"] != default_width:
                widths[str(col0 + 1)] = fmt["Width"]
        id_node = find(node, "d:id")
        size_node = find(node, "d:size")
        return {
            "Id": (text_of(id_node) or None) if id_node is not None else None,
            "Size": int_of(size_node) if size_node is not None else 0,
            "Widths": widths,
            # Формат колонки несёт не только ширину — имя стиля подставим ниже, когда стили
            # будут поименованы.
            "FmtIdx": {str(c0 + 1): by_idx[c0] for c0 in sorted(by_idx.keys())},
        }

    column_sets = [read_column_set(cn) for cn in findall(root, "d:columns")]

    default_set = next((c for c in column_sets if not c["Id"]), None)
    if default_set is None and column_sets:
        default_set = column_sets[0]
    total_columns = default_set["Size"] if default_set else 0
    col_width_map = default_set["Widths"] if default_set else OrderedDict()

    # --- 6. Extract merges ---

    merge_map = {}
    for m_node in findall(root, "d:merge"):
        r = int_of(find(m_node, "d:r"))
        c = int_of(find(m_node, "d:c"))
        w = int_of(find(m_node, "d:w"))
        h_node = find(m_node, "d:h")
        h = int_of(h_node) if h_node is not None else 0
        merge_map[f"{r},{c}"] = {"W": w, "H": h}

    # --- 7. Extract named items ---

    # Захватываем области ВСЕХ типов. Раньше здесь стоял `if area_type != "Rows": continue`,
    # из-за чего терялись Rectangle и Columns — а они есть у 61% макетов корпуса.
    named_areas = []
    for ni_node in findall(root, "d:namedItem"):
        xsi_type = ni_node.get(f"{{{XSI_NS}}}type", "")
        if xsi_type != "NamedItemCells":
            continue

        area_node = find(ni_node, "d:area")
        if area_node is None:
            continue

        def coord(tag, node=area_node):
            n = find(node, "d:" + tag)
            return int_of(n) if n is not None else -1

        named_areas.append({
            # Порядок в исходнике — явный ключ сортировки: sorted тут стабилен, а
            # Sort-Object в ps1 нет, и без него порты расходились.
            "Ord": len(named_areas),
            "Name": text_of(find(ni_node, "d:name")) or "",
            "Type": text_of(find(area_node, "d:type")) or "",
            "BeginRow": coord("beginRow"),
            "EndRow": coord("endRow"),
            "BeginCol": coord("beginColumn"),
            "EndCol": coord("endColumn"),
            # Привязка области к колоночной раскладке: у 913 483 прямоугольных областей корпуса
            # она есть, и из накрытых строк выводится не всегда.
            "ColumnsId": text_of(find(area_node, "d:columnsID")) or "",
        })

    # --- 8. Extract rows ---

    row_data = {}
    # Языки, на которых в макете вообще есть текст. Порядок — первого появления.
    doc_langs = OrderedDict()
    for ri_node in findall(root, "d:rowsItem"):
        row_idx = int_of(find(ri_node, "d:index"))
        row_node = find(ri_node, "d:row")

        index_to = row_idx
        it_node = find(ri_node, "d:indexTo")
        if it_node is not None and it_node.text:
            index_to = int(it_node.text)

        row_fmt_idx = 0
        fmt_node = find(row_node, "d:formatIndex")
        if fmt_node is not None and fmt_node.text:
            row_fmt_idx = int(fmt_node.text)

        is_empty = False
        empty_node = find(row_node, "d:empty")
        if empty_node is not None and empty_node.text == "true":
            is_empty = True

        cells = []
        if not is_empty:
            col = -1
            for c_group in findall(row_node, "d:c"):
                i_node = find(c_group, "d:i")
                if i_node is not None and i_node.text:
                    col = int(i_node.text)
                else:
                    col += 1

                c_content = find(c_group, "d:c")
                if c_content is None:
                    continue

                cell_fmt_idx = 0
                f_node = find(c_content, "d:f")
                if f_node is not None and f_node.text:
                    cell_fmt_idx = int(f_node.text)

                param = None
                p_node = find(c_content, "d:parameter")
                if p_node is not None and p_node.text:
                    param = p_node.text

                detail = None
                d_node = find(c_content, "d:detailParameter")
                if d_node is not None and d_node.text:
                    detail = d_node.text

                # Имя параметра, которым подставляют картинку. Сама картинка сидит в
                # оформлении (picIndex), поэтому этот тег живёт отдельно от неё.
                pic_param = None
                pp_node = find(c_content, "d:pictureParameter")
                if pp_node is not None and pp_node.text:
                    pic_param = pp_node.text

                # Значение ячейки-поля ввода. Тип значения свой, из объявленного не выводится,
                # поэтому читаем и его: пустое значение сворачивается в "", остальные едут как есть.
                value = None
                v_node = find(c_content, "d:v")
                if v_node is not None:
                    value = (v_node.get(f'{{{XSI_NS}}}type') or '', (v_node.text or ''))

                # Примечание к ячейке. Якоря не читаем как данные: конец — координаты самой
                # ячейки, начало — 1/1 у 1085 примечаний корпуса из 1087; остальное авторское.
                note = None
                note_node = find(c_content, "d:note")
                if note_node is not None:
                    g = {etree.QName(ch).localname: ch for ch in note_node}
                    def _txt(name, default=''):
                        el = g.get(name)
                        return (el.text or default).strip() if el is not None else default
                    note_text = OrderedDict()
                    t_el = g.get('text')
                    if t_el is not None:
                        for it in findall(t_el, "v8:item"):
                            lang = text_of(find(it, "v8:lang")) or ''
                            note_text[lang] = text_of(find(it, "v8:content")) or ''
                    note = {
                        "FormatIdx": int(_txt('formatIndex', '0') or 0),
                        "Text": note_text,
                        "AutoSize": _txt('autoSize', 'true') == 'true',
                        "Box": OrderedDict([
                            ("top", int(_txt('beginRowOffset', '0') or 0)),
                            ("left", int(_txt('beginColumnOffset', '0') or 0)),
                            ("bottom", int(_txt('endRowOffset', '0') or 0)),
                            ("right", int(_txt('endColumnOffset', '0') or 0)),
                        ]),
                        "AnchorRow": int(_txt('beginRow', '1') or 1),
                        "AnchorCol": int(_txt('beginColumn', '1') or 1),
                    }

                # Настройки элемента управления — сериализованный base64 у самой ячейки.
                # Структуру не разбираем, возим дословно.
                control = None
                ctl_node = find(c_content, "d:control")
                if ctl_node is not None and ctl_node.text:
                    # Переводы строк внутри блоба приводим к LF: XML-парсеры нормализуют их
                    # по-разному, и без этого порты давали разный JSON на одном файле.
                    control = ctl_node.text.replace('\r\n', '\n')

                # Текст ячейки платформа хранит по элементу на язык. Раньше брался ПЕРВЫЙ, и всё
                # остальное терялось — в корпусе ERP 98% макетов держат текст и под ru, и под en.
                # Здесь собираем «язык → текст» как есть; свернётся в строку позже, когда станет
                # известен набор языков всего макета (get_dsl_text).
                text = None
                has_text = False
                # Пустой <tl/> — отдельное состояние: тег текста есть, языков в нём нет. Без
                # этого ветвления такая ячейка теряла текст вовсе (1 из 15 ячеек с тегом текста).
                tl_node = find(c_content, "d:tl")
                items = findall(c_content, "d:tl/v8:item")
                if tl_node is not None and not items:
                    text = OrderedDict()
                    has_text = True
                elif items:
                    by_lang = OrderedDict()
                    for it in items:
                        lang_node = find(it, "v8:lang")
                        content_node = find(it, "v8:content")
                        lang = (text_of(lang_node) or '') if lang_node is not None else ''
                        by_lang[lang] = (text_of(content_node) or '') if content_node is not None else ''
                        doc_langs[lang] = True
                    text = by_lang
                    # Единственный пустой русский текст содержимым не считается — такая ячейка
                    # уходит в заполнители строки.
                    has_text = not (len(by_lang) == 1 and by_lang.get('ru') == '')

                cells.append({
                    "Col": col,
                    "FormatIdx": cell_fmt_idx,
                    "Param": param,
                    "Detail": detail,
                    "PictureParam": pic_param,
                    "Value": value,
                    "Control": control,
                    "Note": note,
                    "Text": text,
                    "HasText": has_text,
                })

        # Ссылка строки на колоночную раскладку; пусто = раскладка по умолчанию.
        cid_node = find(row_node, "d:columnsID")
        row_columns_id = text_of(cid_node) if cid_node is not None else None

        for r in range(row_idx, index_to + 1):
            row_data[r] = {
                "FormatIdx": row_fmt_idx,
                "Cells": cells,
                "Empty": is_empty,
                "ColumnsId": row_columns_id,
            }

    # Языки текстов макета и языки, объявленные в конфигурации, — разные вещи: у типовых они
    # не совпадают. Строкой пишем текст, одинаковый на ВСЁМ наборе языков макета; остальное —
    # объектом.
    text_languages = list(doc_langs.keys())

    def get_dsl_text(by_lang):
        if not isinstance(by_lang, dict):
            return by_lang
        # Пустой текст (<tl/>) записывается в DSL пустой строкой — той же формой, что
        # авторская. Без этой ветки макет, где ДРУГОГО текста нет вовсе, отдавал null,
        # и ячейка с пустым текстом теряла содержимое.
        if not by_lang:
            return ''
        if len(by_lang) != len(text_languages):
            return by_lang
        common = None
        for lang in text_languages:
            if lang not in by_lang:
                return by_lang
            if common is None:
                common = by_lang[lang]
            elif by_lang[lang] != common:
                return by_lang
        return common

    # --- 9. Build style key (ignoring fillType) ---

    # Свойства формата, которые стилем НЕ являются: ширина принадлежит колонке, высота —
    # строке, вид заполнения выводится из того, чем задано содержимое ячейки.
    # containsValue/valueType/controlType — свойства ЗНАЧЕНИЯ ячейки, а не оформления: стиль
    # общий на многие ячейки, а они индивидуальны. Компилятор таких ключей не знает, так что
    # в DSL они были чистым шумом.
    NON_STYLE_TAGS = ("width", "height", "fillType", "font",
                      "containsValue", "valueType", "controlType",
                      # Линия рисунка и её стороны — свойства рисунка, а не общего оформления:
                      # на корпусе все 2 135 записей с ними принадлежат только рисункам.
                      "drawingBorder", "drawingHaveLeftBorder", "drawingHaveTopBorder",
                      "drawingHaveRightBorder", "drawingHaveBottomBorder")
    BORDER_TAGS = ("border", "leftBorder", "topBorder", "rightBorder", "bottomBorder")

    def line_to_dsl(idx):
        """Ссылку в палитру разворачиваем в описание линии. Ширина 1 подразумевается,
        поэтому обычная линия пишется просто именем стиля."""
        i = int(idx)
        if i < 0 or i >= len(raw_lines):
            return "Solid"
        ln = raw_lines[i]
        out = OrderedDict()
        out["style"] = ln["Style"]
        if ln["Width"] != 1:
            out["width"] = ln["Width"]
        if ln["Gap"] == "true":
            out["gap"] = True
        if len(out) == 1:
            return out["style"]
        return out

    def style_props(fmt):
        """Свойства формата, попадающие в стиль, — в каноническом порядке тегов."""
        if not fmt:
            return OrderedDict()
        out = OrderedDict()
        for tag, val in fmt["Props"].items():
            if tag in NON_STYLE_TAGS:
                continue
            if tag in BORDER_TAGS:
                out[tag] = line_to_dsl(val)
            elif kinds.get(tag) == "bool":
                out[tag] = (val == "true")
            elif kinds.get(tag) == "int":
                out[tag] = int(val)
            else:
                out[tag] = val
        return out

    def get_style_key(fmt):
        if not fmt:
            return "empty"
        # «шрифта нет» и «шрифт с индексом 0» — разные форматы: нулевой шрифт вовсе не
        # обязан быть обычным, в макете он бывает курсивным или жирным.
        parts = ["f=" + (str(fmt["FontIdx"]) if fmt["FontIdx"] >= 0 else "none")]
        for tag, val in style_props(fmt).items():
            parts.append(f"{tag}={val}")
        return "|".join(parts)

    # --- 10. Name fonts ---

    font_names = {}
    font_defs = OrderedDict()

    if len(raw_fonts) > 0:
        font_names[0] = "default"
        font_defs["default"] = raw_fonts[0]

    def get_font_key(f):
        # Ссылку различаем по ней самой: своих атрибутов у такого шрифта нет, и без этого
        # две РАЗНЫЕ ссылки схлопывались в одну как «пустые».
        if f.get("Ref"):
            return "ref=" + f["Ref"]
        return f"{f['Face']}|{f['Size']}|{f['Bold']}|{f['Italic']}|{f['Underline']}|{f['Strikeout']}"

    font_key_map = {}
    if len(raw_fonts) > 0:
        font_key_map[get_font_key(raw_fonts[0])] = "default"

    for i in range(1, len(raw_fonts)):
        f = raw_fonts[i]
        df = raw_fonts[0]

        # Dedup: if identical font already named, reuse
        f_key = get_font_key(f)
        if f_key in font_key_map:
            font_names[i] = font_key_map[f_key]
            continue

        name = None

        if f.get("Ref"):
            # Имя из ссылки: читаемее самой ссылки ничего не придумать.
            name = f["Ref"].split(":", 1)[1].lower()
        elif f["Face"] == df["Face"] and f["Size"] == df["Size"]:
            if f["Bold"] and not df["Bold"] and not f["Italic"] and not f["Underline"] and not f["Strikeout"]:
                name = "bold"
            elif f["Italic"] and not df["Italic"] and not f["Bold"]:
                name = "italic"
            elif f["Underline"] and not df["Underline"] and not f["Bold"] and not f["Italic"]:
                name = "underline"
        elif f["Face"] == df["Face"] and f["Size"] > df["Size"] and f["Bold"]:
            name = "header"
        elif f["Face"] == df["Face"] and f["Size"] < df["Size"]:
            name = "small"

        if not name:
            parts = []
            if f["Face"] and f["Face"] != df["Face"]:
                parts.append(f["Face"].lower())
            parts.append(str(f["Size"]))
            if f["Bold"]:
                parts.append("bold")
            if f["Italic"]:
                parts.append("italic")
            if f["Underline"]:
                parts.append("underline")
            if f["Strikeout"]:
                parts.append("strikeout")
            name = "-".join(parts)

        base_name = name
        suffix = 2
        while name in font_defs:
            name = f"{base_name}{suffix}"
            suffix += 1

        font_names[i] = name
        font_defs[name] = f
        font_key_map[f_key] = name

    # --- 11. Collect and name styles ---

    style_keys = OrderedDict()
    format_to_style_key = {}

    for rd in row_data.values():
        for cell in rd["Cells"]:
            fmt = get_format(cell["FormatIdx"])
            if not fmt:
                continue
            key = get_style_key(fmt)
            if key not in style_keys:
                style_keys[key] = fmt
            format_to_style_key[cell["FormatIdx"]] = key
            # Формат примечания живёт в той же палитре и тоже заслуживает имени: иначе
            # оформление подсказки терялось бы при обратной сборке.
            if cell.get("Note"):
                nfmt = get_format(cell["Note"]["FormatIdx"])
                if nfmt:
                    nkey = get_style_key(nfmt)
                    if nkey not in style_keys:
                        style_keys[nkey] = nfmt
                    format_to_style_key[cell["Note"]["FormatIdx"]] = nkey

    # Формат рисунка — ещё один владелец записи палитры, наравне с ячейкой, строкой, колонкой
    # и примечанием: без этого оформление рисунка теряло имя и вырезалось как неиспользуемое.
    for _item in drawings_out:
        _fi = _item.get("_fmt") or 0
        if not _fi:
            continue
        _fmt = get_format(_fi)
        if _fmt and (style_props(_fmt) or _fmt["FontIdx"] >= 0):
            _key = get_style_key(_fmt)
            if _key not in style_keys:
                style_keys[_key] = _fmt
            format_to_style_key[_fi] = _key

    def row_style_fmt(fmt):
        """Оформление строки без её собственных свойств: скрытие уезжает инлайном к height,
        поэтому в именованный стиль попадать не должно."""
        if not fmt:
            return None
        props = style_props(fmt)
        props.pop("hidden", None)
        # Шрифт в style_props не входит (он адресуется именем), поэтому формат строки,
        # несущий ТОЛЬКО шрифт, здесь выглядел пустым и терялся.
        if not props and fmt["FontIdx"] < 0:
            return None
        reduced = OrderedDict()
        for tag, raw in fmt["Props"].items():
            if tag != "hidden":
                reduced[tag] = raw
        return {"FontIdx": fmt["FontIdx"], "Width": 0, "Height": 0,
                "FillType": "", "Props": reduced}

    # Строка — тоже владелец формата: её оформление становится именованным стилем.
    for rd in row_data.values():
        rf = row_style_fmt(get_format(rd["FormatIdx"])) if rd["FormatIdx"] > 0 else None
        if not rf:
            continue
        key = get_style_key(rf)
        if key not in style_keys:
            style_keys[key] = rf

    # Колонка — третий владелец формата, её оформление тоже становится именованным стилем.
    for cs in column_sets:
        for fi in cs["FmtIdx"].values():
            fmt = get_format(fi)
            if not fmt or not style_props(fmt):
                continue
            key = get_style_key(fmt)
            if key not in style_keys:
                style_keys[key] = fmt
            format_to_style_key[fi] = key

    def name_style(fmt):
        """Имя стиля — читаемая метка по самым заметным свойствам. Полнота тут не нужна:
        различает стили ключ, имя лишь помогает автору ориентироваться."""
        if not fmt:
            return "default"
        parts = []
        props = style_props(fmt)

        fi = fmt["FontIdx"]
        if fi >= 0 and font_names.get(fi, "default") != "default":
            parts.append(font_names[fi])

        if "border" in props:
            parts.append("bordered")
        else:
            sides = [s[:-6] for s in ("leftBorder", "topBorder", "rightBorder", "bottomBorder")
                     if s in props]
            if sides:
                parts.append("border-" + ",".join(sides))

        ha = props.get("horizontalAlignment")
        if ha == "Center":
            parts.append("center")
        elif ha == "Right":
            parts.append("right")
        va = props.get("verticalAlignment")
        if va == "Center":
            parts.append("vcenter")
        elif va == "Top":
            parts.append("vtop")
        if props.get("textPlacement") == "Wrap":
            parts.append("wrap")
        if "backColor" in props:
            parts.append("bg")
        if "format" in props:
            parts.append("fmt")

        if len(parts) == 0:
            # Имя "default" зарезервировано за стилем БЕЗ свойств: под ним компилятор
            # понимает отсутствие оформления, и ячейка такой стиль не записывает. Набор
            # из одних неприметных свойств (отступ, защита) или из одного шрифта обязан
            # получить своё имя, иначе он потеряется.
            has_content = bool(props) or fmt["FontIdx"] >= 0
            return "style" if has_content else "default"
        return "-".join(parts)

    style_names = OrderedDict()
    style_defs = OrderedDict()

    for key in style_keys:
        fmt = style_keys[key]
        name = name_style(fmt)

        base_name = name
        suffix = 2
        while name in style_defs:
            name = f"{base_name}{suffix}"
            suffix += 1

        style_names[key] = name

        s_def = OrderedDict()
        if fmt["FontIdx"] >= 0:
            s_def["font"] = font_names.get(fmt["FontIdx"], "default")
        s_def.update(style_props(fmt))

        style_defs[name] = s_def

    def get_style_name(fmt_idx):
        key = format_to_style_key.get(fmt_idx)
        if key and key in style_names:
            return style_names[key]
        return "default"

    def column_styles_of(cs):
        """Колонки раскладки, у которых формат несёт не только ширину, — «колонка → стиль»."""
        out = OrderedDict()
        for col, fi in cs["FmtIdx"].items():
            if fi == 0:
                # Колонка перечислена, формата у неё нет. Для авторинга бесполезно, но без
                # этого раундтрип теряет элемент целиком.
                out[col] = None
                continue
            fmt = get_format(fi)
            if fmt and style_props(fmt):
                out[col] = get_style_name(fi)
        return out

    def to_positional_cells(cells):
        """Позиционная запись списка ячеек: позиция берётся из порядка, `col` не пишется.
        Ячейка, у которой кроме текста или параметра ничего нет, пишется значением; span
        раскрывается маркерами ">"; прочее — объектным элементом без col. Пропуск колонки —
        null. Выбираем ту запись, которая КОРОЧЕ: раньше позиционная форма отбрасывалась,
        как только первая ячейка стояла не в первой колонке, хотя один-два null впереди
        обычно короче объектной записи с `col`."""
        if not cells:
            return cells
        out = []
        expected = 1
        for c in cells:
            col = int(c.get("col", 0))
            if col < expected:
                return cells   # перекрытие — позиционно не выразить
            while expected < col:
                out.append(None)
                expected += 1
            span = int(c.get("span", 1) or 1)
            keys = [k for k in c if k not in ("col", "span")]
            # Текст — единственное содержимое: пишем значением. Оно бывает строкой либо
            # объектом «язык → текст», и в позиционной записи элемент И ЕСТЬ это значение.
            plain_text = len(keys) == 1 and keys[0] == "text"
            plain_param = len(keys) == 1 and keys[0] == "param"
            if plain_text:
                out.append(c["text"])
            elif plain_param:
                out.append("{%s}" % c["param"])
            else:
                obj = OrderedDict((k, v) for k, v in c.items() if k != "col")
                out.append(obj)
            # span раскрываем маркерами — кроме объектного элемента, он несёт span сам.
            if (plain_text or plain_param) and span > 1:
                out.extend([">"] * (span - 1))
            expected = col + span
        # Позиционная форма ценна компактностью: если она длиннее объектной, смысла в ней нет.
        a, b = try_inline_json(out), try_inline_json(cells)
        if a is not None and b is not None and len(a) > len(b):
            return cells
        return out

    # --- 12. Build areas ---

    # Сетка нарезается на блоки: непересекающиеся области типа Rows задают границы, строки вне
    # них становятся БЕЗЫМЯННЫМИ блоками. Раньше строки вне областей просто терялись — в корпусе
    # такие дыры у 34% макетов, а макетов вовсе без Rows-областей 21%.
    # Всё, что блоком не выражается (области не-Rows и пересекающиеся Rows), уходит в namedAreas
    # координатами. Правило детерминированное — иначе раундтрип поехал бы.

    max_row_idx = max(row_data.keys()) if row_data else -1

    def row_columns_id(r):
        rd = row_data.get(r)
        return rd["ColumnsId"] if rd else None

    def uniform_column_set(frm, to):
        """Область годится в качестве области-диапазона, только если у всех её строк ОДНА
        раскладка: иначе её пришлось бы резать, а имя резать нельзя."""
        first = row_columns_id(frm)
        return all(row_columns_id(r) == first for r in range(frm + 1, to + 1))

    block_areas = []
    overlay_areas = []
    claimed = set()
    for a in sorted(named_areas, key=lambda x: (x["BeginRow"], x["EndRow"], x["Ord"])):
        fits = a["Type"] == "Rows" and a["BeginRow"] >= 0 and a["EndRow"] >= a["BeginRow"]
        if fits:
            for r in range(a["BeginRow"], a["EndRow"] + 1):
                if r in claimed:
                    fits = False
                    break
        if fits:
            fits = uniform_column_set(a["BeginRow"], a["EndRow"])
        if fits:
            # Блок задаёт раскладку строкам, и область наследует её же. Когда область несёт
            # ДРУГУЮ привязку, блоком её не выразить — уводим в namedAreas, где привязка пишется
            # явным ключом.
            fits = a["ColumnsId"] == (row_columns_id(a["BeginRow"]) or "")
        if fits:
            claimed.update(range(a["BeginRow"], a["EndRow"] + 1))
            block_areas.append(a)
        else:
            overlay_areas.append(a)

    def split_gap_by_column_set(frm, to):
        """Безымянный промежуток режем на куски с одной раскладкой: границы наборов не
        совпадают с границами именованных областей."""
        out = []
        if to < frm:
            return out
        run_start = frm
        run_id = row_columns_id(frm)
        for r in range(frm + 1, to + 1):
            cid = row_columns_id(r)
            if cid != run_id:
                out.append({"Name": None, "BeginRow": run_start, "EndRow": r - 1, "ColumnsId": run_id})
                run_start, run_id = r, cid
        out.append({"Name": None, "BeginRow": run_start, "EndRow": to, "ColumnsId": run_id})
        return out

    # Области в порядке строк + безымянные заполнители дыр.
    blocks = []
    cursor = 0
    for a in sorted(block_areas, key=lambda x: x["BeginRow"]):
        if a["BeginRow"] > cursor:
            blocks.extend(split_gap_by_column_set(cursor, a["BeginRow"] - 1))
        blocks.append({"Name": a["Name"], "BeginRow": a["BeginRow"], "EndRow": a["EndRow"],
                       "ColumnsId": row_columns_id(a["BeginRow"])})
        cursor = a["EndRow"] + 1
    if cursor <= max_row_idx:
        blocks.extend(split_gap_by_column_set(cursor, max_row_idx))

    dsl_areas = []

    for area in blocks:
        area_rows = []

        for global_row in range(area["BeginRow"], area["EndRow"] + 1):
            rd = row_data.get(global_row)

            if not rd or rd["Empty"]:
                area_rows.append(OrderedDict())
                continue

            dsl_row = OrderedDict()

            # Формат самой строки: высота и скрытие — её собственные свойства (у ячейки
            # таких нет), остальное — оформление, оно же может лежать и на ячейках.
            row_fmt = get_format(rd["FormatIdx"]) if rd["FormatIdx"] > 0 else None
            row_own = style_props(row_fmt) if row_fmt else OrderedDict()
            row_hidden = row_own.pop("hidden", False)
            if row_fmt and row_fmt["Height"] > 0:
                dsl_row["height"] = row_fmt["Height"]
            if row_hidden:
                dsl_row["hidden"] = True

            # Separate content cells from gap-fill cells
            content_cells = []
            gap_cells = []

            for cell in rd["Cells"]:
                # Ячейка-поле ввода — содержательная, даже когда ни текста, ни параметра в ней
                # нет: значение задаёт её формат. Без этого такая строка уходила бы в пустые.
                cf = get_format(cell["FormatIdx"])
                has_value = bool(cf and cf["Props"].get("containsValue") == "true")
                # Расшифровка сама по себе делает ячейку содержательной: в корпусе 12 653 ячейки
                # несут только её. Без этого такая ячейка уходила в заполнители и терялась.
                has_content = (cell["Param"] or cell["HasText"] or has_value
                               or cell["Detail"] or cell["Note"] or cell["PictureParam"])
                has_merge = f"{global_row},{cell['Col']}" in merge_map

                if has_content or has_merge:
                    content_cells.append(cell)
                else:
                    gap_cells.append(cell)

            # Detect rowStyle
            row_style_name = None
            row_style_key = None

            if len(gap_cells) > 0:
                gap_keys = {}
                for gc in gap_cells:
                    fmt = get_format(gc["FormatIdx"])
                    gap_keys[get_style_key(fmt)] = True

                if len(gap_keys) == 1:
                    row_style_key = list(gap_keys.keys())[0]
                    if row_style_key in style_names:
                        row_style_name = style_names[row_style_key]

            # Стиль строки и стиль ячеек — независимые вещи: платформа их часто, но не всегда
            # пишет одинаковыми. Один ключ с модификатором apply покрывает все три случая.
            own_fmt = row_style_fmt(row_fmt)
            own_key = get_style_key(own_fmt) if own_fmt else None
            own_name = style_names.get(own_key) if own_key else None
            cells_name = row_style_name if row_style_name and row_style_name != "default" else None

            if own_name and cells_name and own_key == row_style_key:
                dsl_row["rowStyle"] = own_name
            elif own_name and not cells_name:
                dsl_row["rowStyle"] = OrderedDict([("style", own_name), ("apply", "row")])
            elif cells_name and not own_name:
                dsl_row["rowStyle"] = OrderedDict([("style", cells_name), ("apply", "cells")])
            elif own_name and cells_name:
                # Стили разные — строке своё, ячейкам своё; ячейкам стиль раздаётся ниже
                # поячеечно, поэтому здесь пишем только строку.
                dsl_row["rowStyle"] = OrderedDict([("style", own_name), ("apply", "row")])
                row_style_name = None
                row_style_key = None
                cells_name = None

            # Build cell list
            dsl_cells = []

            for cell in sorted(content_cells, key=lambda c: c["Col"]):
                dsl_cell = OrderedDict()
                dsl_cell["col"] = cell["Col"] + 1

                # Span/rowspan from merge
                mk = f"{global_row},{cell['Col']}"
                if mk in merge_map:
                    m = merge_map[mk]
                    if m["W"] > 0:
                        dsl_cell["span"] = m["W"] + 1
                    if m["H"] > 0:
                        dsl_cell["rowspan"] = m["H"] + 1

                # Style
                cell_fmt = get_format(cell["FormatIdx"])
                cell_style_key = get_style_key(cell_fmt)

                if row_style_key and cell_style_key == row_style_key:
                    pass  # Inherits rowStyle
                else:
                    # Стиль пишем, только когда он отличается от того, что подставит компилятор:
                    # без стиля у ячеек умолчание и есть "default", поэтому такой ключ — шум
                    # (56% ячеек). А когда стиль ячейкам раздаётся, "default" писать ОБЯЗАТЕЛЬНО:
                    # иначе ячейка при обратной сборке унаследовала бы его.
                    # Сверяемся с cells_name — стилем, который РЕАЛЬНО раздаётся ячейкам. Раньше
                    # здесь стоял row_style_name, а он бывает равен "default": строка такой стиль
                    # не пишет, а ячейка получала бессмысленный ключ на несуществующий стиль.
                    sn = get_style_name(cell["FormatIdx"])
                    if sn != "default" or cells_name:
                        dsl_cell["style"] = sn

                # Значение (ячейка-поле ввода). Свойство живёт в формате, но принадлежит
                # ячейке: на корпусе на такие записи ссылаются только <f>.
                if cell_fmt and cell_fmt["Props"].get("containsValue") == "true":
                    dsl_cell["valueType"] = cell_fmt["Props"].get("valueType", "")
                    ctl = cell_fmt["Props"].get("controlType")
                    if ctl is None:
                        # Формат без <controlType> вовсе — так пишут машинно-сгенерированные
                        # макеты регламентированной отчётности; компилятор такое повторит
                        # только по явному указанию.
                        dsl_cell["controlType"] = "none"
                    else:
                        name = VALUE_CONTROL_NAMES.get(ctl.lower(), ctl)
                        # input — умолчание компилятора, писать его значит шуметь на 63 629
                        # форматах корпуса.
                        if name != "input":
                            dsl_cell["controlType"] = name
                    if cell["Value"] is not None:
                        dsl_cell["value"] = value_to_dsl(*cell["Value"])
                    if cell["Control"]:
                        dsl_cell["control"] = cell["Control"]

                # Content
                fill_type = cell_fmt["FillType"] if cell_fmt else ""

                if cell["Param"]:
                    dsl_cell["param"] = cell["Param"]
                elif fill_type == "Template" and cell["HasText"]:
                    dsl_cell["template"] = get_dsl_text(cell["Text"])
                elif cell["HasText"]:
                    dsl_cell["text"] = get_dsl_text(cell["Text"])
                # Расшифровка живёт отдельно от параметра заполнения: на корпусе 20 404 ячейки
                # несут её без параметра против 8 582 с ним. Пока она читалась только вместе
                # с параметром, две трети расшифровок терялись молча.
                if cell["Detail"]:
                    dsl_cell["detail"] = cell["Detail"]
                if cell["PictureParam"]:
                    dsl_cell["pictureParameter"] = cell["PictureParam"]

                if cell["Note"]:
                    n = cell["Note"]
                    dsl_note = OrderedDict()
                    dsl_note["text"] = get_dsl_text(n["Text"])
                    style_name = get_style_name(n["FormatIdx"])
                    if style_name != "default":
                        dsl_note["style"] = style_name
                    if not n["AutoSize"]:
                        dsl_note["autoSize"] = False
                    dsl_note["box"] = n["Box"]
                    if n["AnchorRow"] != 1 or n["AnchorCol"] != 1:
                        dsl_note["anchor"] = OrderedDict([("row", n["AnchorRow"]), ("col", n["AnchorCol"])])
                    dsl_cell["note"] = dsl_note

                dsl_cells.append(dsl_cell)

            if len(dsl_cells) > 0:
                dsl_row["cells"] = to_positional_cells(dsl_cells)
            # Самая короткая из применимых форм: если у строки нет своих свойств, а список ячеек
            # позиционный — строка пишется просто массивом, без ключа cells.
            # Список позиционный, если позиция в нём НЕ записана: ни у одного элемента нет col.
            # Прежняя проверка искала элемент-строку, поэтому строка из одних многоязычных
            # текстов позиционной не признавалась и оставалась объектной.
            if (len(dsl_row) == 1 and "cells" in dsl_row
                    and not any(isinstance(el, dict) and "col" in el for el in dsl_row["cells"])):
                area_rows.append(dsl_row["cells"])
            else:
                area_rows.append(dsl_row)

        # Compress consecutive empty rows ({}) into { empty = N }
        compressed_rows = []
        empty_run = 0
        for r in area_rows:
            if len(r) == 0:
                empty_run += 1
            else:
                if empty_run > 0:
                    if empty_run == 1:
                        compressed_rows.append(OrderedDict())
                    else:
                        compressed_rows.append(OrderedDict([("empty", empty_run)]))
                    empty_run = 0
                compressed_rows.append(r)
        if empty_run > 0:
            if empty_run == 1:
                compressed_rows.append(OrderedDict())
            else:
                compressed_rows.append(OrderedDict([("empty", empty_run)]))

        dsl_block = OrderedDict()
        # Область без имени — просто кусок сетки, ключ name у неё не пишем.
        if area["Name"]:
            dsl_block["name"] = area["Name"]
        # Ссылка на колоночную раскладку по имени из columnSets — как style у ячейки на styles.
        # Умолчание (раскладка без id) не пишем.
        if area.get("ColumnsId"):
            dsl_block["columnSet"] = area["ColumnsId"]
        dsl_block["rows"] = compressed_rows
        dsl_areas.append(dsl_block)

    # --- 13. Compress columnWidths ---

    compressed_widths = OrderedDict()
    if len(col_width_map) > 0:
        # Group columns by width
        width_to_cols = {}
        for col_str, width in col_width_map.items():
            width_to_cols.setdefault(width, []).append(col_str)

        for width, cols in width_to_cols.items():
            cols_sorted = sorted(cols, key=lambda x: int(x))

            ranges = []
            range_start = cols_sorted[0]
            range_prev = cols_sorted[0]

            for i in range(1, len(cols_sorted)):
                if int(cols_sorted[i]) == int(range_prev) + 1:
                    range_prev = cols_sorted[i]
                else:
                    if range_start == range_prev:
                        ranges.append(range_start)
                    else:
                        ranges.append(f"{range_start}-{range_prev}")
                    range_start = cols_sorted[i]
                    range_prev = cols_sorted[i]

            if range_start == range_prev:
                ranges.append(range_start)
            else:
                ranges.append(f"{range_start}-{range_prev}")

            for rng in ranges:
                compressed_widths[rng] = width

    # --- 14. Build fonts output ---

    fonts_out = OrderedDict()
    for name, f in font_defs.items():
        if f.get("Ref"):
            fonts_out[name] = OrderedDict([("ref", f["Ref"])])
            continue
        f_out = OrderedDict()
        f_out["face"] = f["Face"]
        f_out["size"] = f["Size"]
        if f["Bold"]:
            f_out["bold"] = True
        if f["Italic"]:
            f_out["italic"] = True
        if f["Underline"]:
            f_out["underline"] = True
        if f["Strikeout"]:
            f_out["strikeout"] = True
        fonts_out[name] = f_out

    # --- 15. Assemble result ---

    result = OrderedDict()
    result["columns"] = total_columns
    result["defaultWidth"] = default_width
    if len(compressed_widths) > 0:
        result["columnWidths"] = compressed_widths
    if default_set:
        default_col_styles = column_styles_of(default_set)
        if default_col_styles:
            result["columnStyles"] = default_col_styles
    # Набор языков объявляем, только если он отличается от умолчания компилятора (один ru).
    if text_languages and text_languages != ['ru']:
        result["textLanguages"] = text_languages

    # Объявление языков МАКЕТА — не то же, что языки текста: почти во всех макетах ERP
    # объявлен один ru, а текст лежит и под ru, и под en. Пишем, только если отличается
    # от умолчания компилятора.
    ls_node = find(root, "d:languageSettings")
    if ls_node is not None:
        langs = []
        for li in findall(ls_node, "d:languageInfo"):
            desc_node = find(li, "d:description")
            langs.append(OrderedDict([
                ("id", text_of(find(li, "d:id")) or ""),
                ("code", text_of(find(li, "d:code")) or ""),
                ("description", text_of(desc_node) or "" if desc_node is not None else ""),
            ]))
        if langs != [OrderedDict([("id", "ru"), ("code", RU_NAME), ("description", RU_NAME)])]:
            result["languages"] = langs
        cur_node = find(ls_node, "d:currentLanguage")
        cur = text_of(cur_node) if cur_node is not None else None
        if cur != "ru":
            result["currentLanguage"] = cur
        dflt = text_of(find(ls_node, "d:defaultLanguage"))
        if dflt and dflt != "ru":
            result["defaultLanguage"] = dflt

    # Remove empty "default" style
    if "default" in style_defs and len(style_defs["default"]) == 0:
        del style_defs["default"]

    # Remove unused styles
    used_styles = set()
    for a in dsl_areas:
        for r in a["rows"]:
            # Строка может быть массивом (короткая форма) — у неё нет ключа cells, и без этой
            # ветки стиль, использованный только внутри такой строки, вырезался как «неиспользуемый».
            if isinstance(r, list):
                cell_list = r
            else:
                if "rowStyle" in r:
                    rs = r["rowStyle"]
                    used_styles.add(rs["style"] if isinstance(rs, dict) else rs)
                cell_list = r.get("cells") or []
            # Список ячеек может быть позиционным: строки, None и маркеры стиля не несут,
            # стиль бывает только у объектного элемента.
            for c in cell_list:
                if isinstance(c, dict) and "style" in c:
                    used_styles.add(c["style"])
                # Четвёртый владелец формата — примечание: его стиль тоже держит ссылку,
                # иначе он вырезается как неиспользуемый и ссылка остаётся висячей.
                if isinstance(c, dict) and isinstance(c.get("note"), dict) and "style" in c["note"]:
                    used_styles.add(c["note"]["style"])
    # Стиль бывает не только у ячейки и строки: колонка — третий владелец формата. Берём
    # стили ИЗ САМИХ РАСКЛАДОК, а не из result: columnSets попадает в результат ПОЗЖЕ этой
    # проверки, поэтому стиль, на который ссылается только дополнительная раскладка,
    # отсекался, а ссылка на него оставалась висячей (5 макетов пилота из 40).
    for cs in column_sets:
        for name in column_styles_of(cs).values():
            if name:
                used_styles.add(name)
    # Рисунок — пятый владелец формата. Имя ему присваивается позже, при сборке результата,
    # поэтому здесь считаем его из ссылки на палитру: иначе стиль рисунка вырежется как
    # неиспользуемый, а ссылка на него останется висячей.
    for _item in drawings_out:
        _fi = _item.get("_fmt") or 0
        if _fi:
            _name = get_style_name(_fi)
            if _name != "default":
                used_styles.add(_name)
    to_remove = [s for s in style_defs if s not in used_styles]
    for s in to_remove:
        del style_defs[s]

    result["fonts"] = fonts_out
    result["styles"] = style_defs

    # Колоночные раскладки помимо умолчания: ключ — идентификатор из макета, на него ссылаются
    # области. Содержимое раскладку не опознаёт (в корпусе полно наборов с одинаковым
    # содержимым и разными id), поэтому склейки по содержимому нет.
    extra_sets = [c for c in column_sets if c["Id"]]
    if extra_sets:
        sets_out = OrderedDict()
        for cs in extra_sets:
            entry = OrderedDict([("columns", cs["Size"])])
            if cs["Widths"]:
                entry["columnWidths"] = cs["Widths"]
            styles_out = column_styles_of(cs)
            if styles_out:
                entry["columnStyles"] = styles_out
            sets_out[cs["Id"]] = entry
        result["columnSets"] = sets_out

    # Имя группировки — та же мультиязычная строка, что текст ячейки, и сворачивается так же.
    for _g in row_groups + col_groups:
        if "name" in _g:
            _g["name"] = get_dsl_text(_g["name"])
    if row_groups:
        result["rowGroups"] = row_groups
    if col_groups:
        result["columnGroups"] = col_groups

    # Читаем здесь, а не в разделе 4a: тексту колонтитула нужен свод языков макета, который
    # становится известен только после разбора строк.
    header_part = read_header_part('Header')
    footer_part = read_header_part('Footer')
    if header_part:
        result["header"] = header_part
    if footer_part:
        result["footer"] = footer_part
    if print_settings:
        result["printSettings"] = print_settings

    # Оформление рисунка: линия и её стороны — его собственные ключи, общее — именованный стиль.
    # Порядок ключей задаём здесь же, чтобы он не зависел от того, что разбиралось раньше.
    ordered = []
    for item in drawings_out:
        fmt_idx = item.pop("_fmt", 0)
        if "text" in item:
            item["text"] = get_dsl_text(item["text"])
        line_val = None
        sides = OrderedDict()
        if fmt_idx:
            fmt = get_format(fmt_idx)
            props = fmt["Props"] if fmt else {}
            if "drawingBorder" in props:
                line_val = line_to_dsl(int(props["drawingBorder"]))
            for side in ("Left", "Top", "Right", "Bottom"):
                tag = f'drawingHave{side}Border'
                if tag in props:
                    sides[side.lower()] = props[tag] == "true"
            name = get_style_name(fmt_idx)
            if name != "default":
                item["style"] = name
        if line_val is not None:
            item["line"] = line_val
        if sides:
            item["sides"] = sides
        out_item = OrderedDict()
        for key in ("type", "id", "zOrder", "name", "picture", "detail", "text",
                    "style", "line", "sides", "begin", "end", "pictureSize"):
            if key in item:
                out_item[key] = item[key]
        ordered.append(out_item)
    drawings_out = ordered
    if pictures_out:
        result["pictures"] = pictures_out
    if drawings_out:
        result["drawings"] = drawings_out

    result["areas"] = dsl_areas

    # Именованные области, не выразимые блоком, — координатами. Тип не пишем: он выводится
    # из указанных осей (как в ТабличныйДокумент.Область()). DSL 1-based, XML 0-based.
    if overlay_areas:
        na_out = []
        for a in overlay_areas:
            entry = OrderedDict([("name", a["Name"])])
            if a["BeginRow"] >= 0:
                entry["rows"] = (f'{a["BeginRow"] + 1}-{a["EndRow"] + 1}'
                                 if a["EndRow"] > a["BeginRow"] else a["BeginRow"] + 1)
            if a["BeginCol"] >= 0:
                entry["cols"] = (f'{a["BeginCol"] + 1}-{a["EndCol"] + 1}'
                                 if a["EndCol"] > a["BeginCol"] else a["BeginCol"] + 1)
            # Привязку пишем, только когда она не выводится из накрытых строк.
            derived = ""
            if a["BeginRow"] >= 0:
                covered = {row_columns_id(r) or "" for r in range(a["BeginRow"], a["EndRow"] + 1)}
                if len(covered) == 1:
                    derived = covered.pop()
            if a["ColumnsId"] != derived:
                entry["columnSet"] = a["ColumnsId"]
            na_out.append(entry)
        result["namedAreas"] = na_out

    # --- 16. Convert to JSON ---

    json_str = convert_to_compact_json(result)

    # --- 17. Output ---

    if output_path:
        abs_path = os.path.join(os.getcwd(), output_path) if not os.path.isabs(output_path) else output_path
        with open(abs_path, "w", encoding="utf-8", newline="") as fh:
            fh.write(json_str)
        print(f"[OK] Decompiled: {output_path}")
    else:
        print(json_str)

    print(f"     Areas: {len(named_areas)}, Rows: {len(row_data)}, Columns: {total_columns}", file=sys.stderr)
    print(f"     Fonts: {len(font_defs)}, Styles: {len(style_defs)}, Merges: {len(merge_map)}", file=sys.stderr)


if __name__ == "__main__":
    main()
