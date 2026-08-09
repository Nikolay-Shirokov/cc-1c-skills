#!/usr/bin/env python3
# mxl-compile v1.15 — Compile 1C spreadsheet from JSON (+плоский режим, области всех типов, поля ввода)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import math
import os
import re
import sys

from lxml import etree

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.
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

    with open(json_path, 'r', encoding='utf-8-sig') as f:
        defn = ci_json(json.load(f))

    if not defn.get('columns'):
        print("Required field 'columns' is missing", file=sys.stderr)
        sys.exit(1)
    if defn.get('rows') and defn.get('areas'):
        print("Fields 'rows' and 'areas' are mutually exclusive: 'rows' is the flat mode "
              "(whole grid + namedAreas), 'areas' is the block mode", file=sys.stderr)
        sys.exit(1)
    if not defn.get('areas') and not defn.get('rows'):
        print("Required field 'areas' (block mode) or 'rows' (flat mode) is missing", file=sys.stderr)
        sys.exit(1)

    # Normalized row groups: block mode = one group per area, flat mode = single unnamed group
    flat_mode = bool(defn.get('rows'))
    row_groups = []
    if flat_mode:
        row_groups.append({'Name': None, 'Rows': defn['rows']})
    else:
        for area in defn['areas']:
            row_groups.append({'Name': area.get('name'), 'Rows': area.get('rows', [])})

    total_columns = int(defn['columns'])
    # 0 is a meaningful value: "no default width, columns take the platform's own"
    default_width = int(defn['defaultWidth']) if defn.get('defaultWidth') is not None else 10

    # Language plain-string cell texts are written under. `text` wins over `current`:
    # a template can declare one current language and store its texts under another.
    text_lang = 'ru'
    langs_def = defn.get('languages') or {}
    if langs_def.get('text'):
        text_lang = str(langs_def['text'])
    elif langs_def.get('current'):
        text_lang = str(langs_def['current'])

    # Every language that appears anywhere in the document must end up declared in
    # languageSettings, otherwise the platform drops the texts it cannot resolve
    used_langs = {text_lang: True}

    def add_used_langs(value):
        if value is None or isinstance(value, str):
            return
        if isinstance(value, dict):
            for k in value:
                used_langs[k] = True

    for group in row_groups:
        for row in group['Rows']:
            if not isinstance(row, dict):
                continue
            for cell in row.get('cells') or []:
                add_used_langs(cell.get('text'))
                add_used_langs(cell.get('template'))
    for sval in (defn.get('styles') or {}).values():
        add_used_langs(sval.get('format'))

    # --- 2. Build font palette ---
    font_map = {}   # name -> 0-based index
    font_entries = []  # list of dicts

    def add_font(name, font_def):
        font_def = font_def or {}
        # An explicitly empty face means "inherit the default font" — keep it,
        # only a missing face falls back to Arial
        face = str(font_def['face']) if font_def.get('face') is not None else 'Arial'
        # Font height can be fractional (8.3, 6.8) — do not round it to an integer
        has_size = font_def.get('size') is not None
        size = float(font_def['size']) if has_size else 10
        bold = 'true' if font_def.get('bold') is True else 'false'
        italic = 'true' if font_def.get('italic') is True else 'false'
        underline = 'true' if font_def.get('underline') is True else 'false'
        strikeout = 'true' if font_def.get('strikeout') is True else 'false'

        idx = len(font_entries)
        font_map[name] = idx
        font_entries.append({
            'Face': face,
            'Size': size,
            'HasSize': has_size,
            'Bold': bold,
            'Italic': italic,
            'Underline': underline,
            'Strikeout': strikeout,
            'Ref': str(font_def['ref']) if font_def.get('ref') else '',
            'Kind': str(font_def['kind']) if font_def.get('kind') else '',
            'HasStyleAttrs': font_def.get('bold') is not None,
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

    # --- 3. Determine line palette ---
    has_thin_borders = False
    has_thick_borders = False

    if defn.get('styles'):
        for sname, sval in defn['styles'].items():
            if sval.get('border') and sval['border'] != 'none':
                if sval.get('borderWidth') == 'thick':
                    has_thick_borders = True
                else:
                    has_thin_borders = True

    # Line palette: "<width>|<style>" -> 0-based index. Thin and thick solid keep
    # their historical positions, everything else is appended in order of first use.
    line_palette = {}

    def register_line(width, style):
        key = f'{width}|{style}'
        if key not in line_palette:
            line_palette[key] = len(line_palette)
        return line_palette[key]

    thin_line_index = -1
    thick_line_index = -1
    if has_thin_borders:
        thin_line_index = register_line(1, 'Solid')
    if has_thick_borders:
        thick_line_index = register_line(2, 'Solid')

    # Per-side border specs may name any line style the platform knows
    for sval in (defn.get('styles') or {}).values():
        b = sval.get('borders')
        if not b:
            continue
        for spec in b.values():
            if not spec:
                continue
            style = str(spec['style']) if spec.get('style') else 'Solid'
            width = int(spec['width']) if spec.get('width') is not None else 1
            register_line(width, style)

    line_count = len(line_palette)

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
    col_width_map = {}
    if defn.get('columnWidths'):
        for prop_name, prop_value in defn['columnWidths'].items():
            val = str(prop_value)
            m = re.match(r'^([0-9.]+)x$', val)
            if m:
                width = round(float(m.group(1)) * default_width)
            else:
                width = int(val)
            columns = parse_column_spec(prop_name)
            for c in columns:
                col_width_map[c] = width

    # --- 5. Style resolver ---
    def resolve_style(style_name, fill_type):
        font_idx = font_map.get('default', 0)
        lb = -1; tb = -1; rb = -1; bb = -1
        ha = ''; va = ''; nf = ''
        wrap = ''   # textPlacement: '', Wrap, Auto or Cut
        text_color = ''; border_color = ''; hidden = ''; indent = -1
        extra = None; order = None
        style_width = -1; style_height = -1

        if style_name and defn.get('styles'):
            style = defn['styles'].get(style_name)
            if style:
                # Font. An empty name means "no <font> element at all", which the
                # platform writes for formats that inherit it.
                if style.get('font') and style['font'] in font_map:
                    font_idx = font_map[style['font']]
                elif style.get('font') is not None and str(style['font']) == '':
                    font_idx = -1

                # Borders. `borders` describes each side on its own and wins over the
                # compact `border` + `borderWidth` pair.
                if style.get('borders'):
                    for side_name, spec in style['borders'].items():
                        if not spec:
                            continue
                        s_style = str(spec['style']) if spec.get('style') else 'Solid'
                        s_width = int(spec['width']) if spec.get('width') is not None else 1
                        idx = register_line(s_width, s_style)
                        sn = side_name.lower()
                        if sn == 'left':
                            lb = idx
                        elif sn == 'top':
                            tb = idx
                        elif sn == 'right':
                            rb = idx
                        elif sn == 'bottom':
                            bb = idx
                elif style.get('border') and style['border'] != 'none':
                    line_idx = thick_line_index if style.get('borderWidth') == 'thick' else thin_line_index
                    for side in style['border'].split(','):
                        side = side.strip()
                        if side == 'all':
                            lb = line_idx; tb = line_idx; rb = line_idx; bb = line_idx
                        elif side == 'left':
                            lb = line_idx
                        elif side == 'top':
                            tb = line_idx
                        elif side == 'right':
                            rb = line_idx
                        elif side == 'bottom':
                            bb = line_idx

                # Alignment
                # Common names are spelled out, anything else is passed through with
                # its first letter capitalised (Justify, Fill, ...)
                if style.get('align'):
                    v = str(style['align'])
                    align_map = {'left': 'Left', 'center': 'Center', 'right': 'Right'}
                    ha = align_map.get(v, v[:1].upper() + v[1:])
                if style.get('valign'):
                    v = str(style['valign'])
                    valign_map = {'top': 'Top', 'center': 'Center', 'bottom': 'Bottom'}
                    va = valign_map.get(v, v[:1].upper() + v[1:])

                # Text placement
                if style.get('wrap') is True:
                    wrap = 'Wrap'
                if style.get('textPlacement'):
                    tp = str(style['textPlacement']).lower()
                    if tp == 'wrap':
                        wrap = 'Wrap'
                    elif tp == 'auto':
                        wrap = 'Auto'
                    elif tp == 'cut':
                        wrap = 'Cut'
                    else:
                        print(f"WARNING: Unknown textPlacement '{style['textPlacement']}'; "
                              f"expected wrap, auto or cut", file=sys.stderr)

                # Number format
                if style.get('format'):
                    nf = style['format']

                # Colors and misc
                if style.get('textColor'):
                    text_color = style['textColor']
                if style.get('borderColor'):
                    border_color = style['borderColor']
                # false is meaningful: templates spell it out
                if style.get('hidden') is not None:
                    hidden = 'true' if style['hidden'] is True else 'false'
                if style.get('indent') is not None:
                    indent = int(style['indent'])
                # 0 is a real value, so absence is what -1 stands for
                if style.get('width') is not None:
                    style_width = int(style['width'])
                if style.get('height') is not None:
                    style_height = int(style['height'])

                # Properties the DSL does not model, plus the original element order
                if style.get('extra'):
                    extra = style['extra']
                if style.get('order'):
                    order = style['order']

        return {
            'FontIdx': font_idx,
            'LB': lb, 'TB': tb, 'RB': rb, 'BB': bb,
            'HA': ha, 'VA': va,
            'Wrap': wrap,
            'FillType': fill_type,
            'NumberFormat': nf,
            'TextColor': text_color,
            'BorderColor': border_color,
            'Hidden': hidden,
            'Indent': indent,
            'Extra': extra,
            'Order': order,
            'Width': style_width,
            'Height': style_height,
        }

    # --- 6. Format palette builder ---
    format_registry = {}   # key -> props
    format_order = []       # ordered keys for index assignment

    def get_format_key(font_idx=-1, lb=-1, tb=-1, rb=-1, bb=-1, ha='', va='',
                       wrap='', fill_type='', number_format='', width=-1, height=-1,
                       text_color='', border_color='', hidden='', indent=0,
                       control_type='', value_type='', extra=''):
        key = (f'f={font_idx}|lb={lb}|tb={tb}|rb={rb}|bb={bb}|ha={ha}|va={va}'
               f'|wr={wrap}|ft={fill_type}|nf={number_format}|w={width}|h={height}')
        # Extra properties are appended only when used, so keys of plain cells stay unchanged
        if text_color or border_color or hidden or indent or control_type or value_type or extra:
            key += (f'|tc={text_color}|bc={border_color}|hd={hidden}|in={indent}'
                    f'|ct={control_type}|vt={value_type}|ex={extra}')
        return key

    # Number format may be a plain string or one entry per language
    def get_number_format_key(nf):
        if not nf:
            return ''
        if isinstance(nf, str):
            return nf
        return ';'.join(f'{k}={v}' for k, v in nf.items())

    # Cell control types: DSL name -> platform GUID
    control_type_guids = {
        'field': '381ed624-9217-4e63-85db-c4c3cb87daae',
        'checkbox': '35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26',
    }

    # valueType: shorthand string or object -> normalized dict
    def resolve_value_type(vt):
        if not vt:
            return None

        spec = vt
        if isinstance(vt, str):
            # "number(10,0)", "string(50)", "date", "boolean"
            m = re.match(r'^number\((\d+)\s*,\s*(\d+)\)$', vt)
            if m:
                spec = {'type': 'number', 'digits': int(m.group(1)), 'fractionDigits': int(m.group(2))}
            elif re.match(r'^number\((\d+)\)$', vt):
                spec = {'type': 'number', 'digits': int(re.match(r'^number\((\d+)\)$', vt).group(1)),
                        'fractionDigits': 0}
            elif re.match(r'^string\((\d+)\)$', vt):
                spec = {'type': 'string', 'length': int(re.match(r'^string\((\d+)\)$', vt).group(1))}
            elif vt == 'string':
                spec = {'type': 'string', 'length': 0}
            elif vt in ('date', 'boolean', 'number'):
                spec = {'type': vt}
            else:
                print(f"WARNING: Unknown valueType '{vt}'; expected number(N,M), string(N), date or boolean",
                      file=sys.stderr)
                return None

        vtype = str(spec.get('type'))
        out = {'Type': vtype}

        if vtype == 'number':
            out['Digits'] = int(spec['digits']) if spec.get('digits') is not None else 10
            out['FractionDigits'] = int(spec['fractionDigits']) if spec.get('fractionDigits') is not None else 0
            out['AllowedSign'] = str(spec['allowedSign']) if spec.get('allowedSign') else 'Any'
        elif vtype == 'string':
            out['Length'] = int(spec['length']) if spec.get('length') is not None else 0
            out['AllowedLength'] = str(spec['allowedLength']) if spec.get('allowedLength') else 'Variable'
        elif vtype == 'date':
            out['XsType'] = str(spec['xsType']) if spec.get('xsType') else 'xs:dateTime'
            out['DateFractions'] = str(spec['dateFractions']) if spec.get('dateFractions') else 'Date'
        elif vtype == 'boolean':
            pass
        else:
            print(f"WARNING: Unknown valueType type '{vtype}'", file=sys.stderr)
            return None

        return out

    def get_value_type_key(vt):
        if not vt:
            return ''
        t = vt['Type']
        if t == 'number':
            return f"number({vt['Digits']},{vt['FractionDigits']},{vt['AllowedSign']})"
        if t == 'string':
            return f"string({vt['Length']},{vt['AllowedLength']})"
        if t == 'date':
            return f"date({vt['XsType']},{vt['DateFractions']})"
        if t == 'boolean':
            return 'boolean'
        return ''

    def register_format(key, props):
        if key not in format_registry:
            format_registry[key] = props
            format_order.append(key)
        # Return 1-based index
        return format_order.index(key) + 1

    # 6a. Default format. Without a width it would come out empty, so it carries the
    # default font instead — the same shape the platform writes.
    if default_width > 0:
        default_format_key = get_format_key(width=default_width)
        default_format_index = register_format(default_format_key, {'Width': default_width})
    else:
        default_format_key = get_format_key(font_idx=font_map['default'])
        default_format_index = register_format(default_format_key, {'FontIdx': font_map['default']})

    # 6b. Column width formats
    col_format_map = {}  # 1-based col -> format index
    for col in sorted(col_width_map):
        w = col_width_map[col]
        key = get_format_key(width=w)
        idx = register_format(key, {'Width': w})
        col_format_map[int(col)] = idx

    # 6c. Helper: determine fillType from cell content
    def get_fill_type(cell):
        # Explicit wins: a cell can carry a fill type without content
        if cell.get('fillType'):
            return str(cell['fillType'])
        if cell.get('param'):
            return 'Parameter'
        if cell.get('template'):
            return 'Template'
        if cell.get('text'):
            return 'Text'
        return ''

    # Helper: register a cell format and return its index
    def register_cell_format(style_name, fill_type, cell=None):
        # Format index 0 is "no format"; nothing to register
        if (style_name is not None and str(style_name) == '' and not fill_type
                and not (cell and cell.get('input'))):
            return 0
        resolved = resolve_style(style_name, fill_type)

        # Input cell properties live on the cell, not on the style
        control_type = ''
        value_type = None
        if cell and cell.get('input'):
            input_name = str(cell['input'])
            control_type = control_type_guids.get(input_name, input_name)
            value_type = resolve_value_type(cell.get('valueType'))
        vt_key = get_value_type_key(value_type)
        ex_key = ''
        if resolved['Extra']:
            ex_key = ''.join(e['xml'] for e in resolved['Extra'])

        key = get_format_key(
            font_idx=resolved['FontIdx'],
            lb=resolved['LB'], tb=resolved['TB'], rb=resolved['RB'], bb=resolved['BB'],
            ha=resolved['HA'], va=resolved['VA'],
            wrap=resolved['Wrap'], fill_type=resolved['FillType'],
            number_format=get_number_format_key(resolved['NumberFormat']),
            width=resolved['Width'], height=resolved['Height'],
            text_color=resolved['TextColor'], border_color=resolved['BorderColor'],
            hidden=resolved['Hidden'], indent=resolved['Indent'],
            control_type=control_type, value_type=vt_key, extra=ex_key)
        props = {
            'FontIdx': resolved['FontIdx'],
            'LB': resolved['LB'], 'TB': resolved['TB'],
            'RB': resolved['RB'], 'BB': resolved['BB'],
            'HA': resolved['HA'], 'VA': resolved['VA'],
            'Wrap': resolved['Wrap'],
            'FillType': resolved['FillType'],
            'NumberFormat': resolved['NumberFormat'],
            'TextColor': resolved['TextColor'],
            'BorderColor': resolved['BorderColor'],
            'Hidden': resolved['Hidden'],
            'Indent': resolved['Indent'],
            'ControlType': control_type,
            'ValueType': value_type,
            'Extra': resolved['Extra'],
            'Order': resolved['Order'],
            'Width': resolved['Width'],
            'Height': resolved['Height'],
        }
        return register_format(key, props)

    # Pre-register all formats from rows
    for group in row_groups:
        for row in group['Rows']:
            # Skip list-of-values shorthand rows (treated as empty rows like PS1)
            if isinstance(row, list):
                continue
            # Skip empty row placeholder
            if row.get('empty'):
                continue

            # Row height format
            if row.get('height'):
                h_key = get_format_key(height=int(row['height']))
                register_format(h_key, {'Height': int(row['height'])})

            # rowStyle gap-fill format (no content → no fillType)
            if row.get('rowStyle'):
                register_cell_format(row['rowStyle'], '')

            # Explicit cell formats
            if row.get('cells'):
                for cell in row['cells']:
                    # An explicitly empty style means the cell names no format at all
                    if cell.get('style') is not None:
                        cell_style = str(cell['style'])
                    else:
                        cell_style = row.get('rowStyle') or 'default'
                    ft = get_fill_type(cell)
                    register_cell_format(cell_style, ft, cell)

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
    cur_lang = text_lang
    def_lang = text_lang
    if langs_def:
        if langs_def.get('current'):
            cur_lang = str(langs_def['current'])
        if langs_def.get('default'):
            def_lang = str(langs_def['default'])
        else:
            def_lang = cur_lang
    used_langs[cur_lang] = True
    used_langs[def_lang] = True

    # Names for languages the definition does not describe itself
    known_lang_names = {
        'ru': {'Code': '\u0420\u0443\u0441\u0441\u043a\u0438\u0439', 'Description': '\u0420\u0443\u0441\u0441\u043a\u0438\u0439'},
        'uk': {'Code': '\u0423\u043a\u0440\u0430\u0438\u043d\u0441\u043a\u0438\u0439', 'Description': '\u0423\u043a\u0440\u0430\u0457\u043d\u0441\u044c\u043a\u0430'},
        'en': {'Code': '\u0410\u043d\u0433\u043b\u0438\u0439\u0441\u043a\u0438\u0439', 'Description': 'English'},
    }

    lang_infos = {}
    for li in (langs_def.get('list') or []):
        if not li.get('id'):
            continue
        lang_infos[str(li['id'])] = {
            'Code': str(li['code']) if li.get('code') else str(li['id']),
            'Description': str(li['description']) if li.get('description') else str(li['id']),
        }
    for l in used_langs:
        if l in lang_infos:
            continue
        lang_infos[l] = known_lang_names.get(l, {'Code': l, 'Description': l})

    lines.append('\t<languageSettings>')
    lines.append(f'\t\t<currentLanguage>{cur_lang}</currentLanguage>')
    lines.append(f'\t\t<defaultLanguage>{def_lang}</defaultLanguage>')
    for lid, info in lang_infos.items():
        lines.append('\t\t<languageInfo>')
        lines.append(f'\t\t\t<id>{lid}</id>')
        lines.append(f'\t\t\t<code>{esc_xml_text(info["Code"])}</code>')
        lines.append(f'\t\t\t<description>{esc_xml_text(info["Description"])}</description>')
        lines.append('\t\t</languageInfo>')
    lines.append('\t</languageSettings>')

    # Cell children the DSL does not model (value, control, note, ...) \u2014 written back
    # verbatim. `names` selects which ones; `rest` flips the selection.
    def write_cell_extra(extra, names, rest=False):
        if not extra:
            return
        for e in extra:
            is_listed = str(e['name']) in names
            if rest == is_listed:
                continue
            lines.append('\t\t\t\t\t' + e['xml'])

    # Cell text: a plain string goes under the document language, an object writes
    # one <v8:item> per language key ({ "uk": "...", "ru": "..." })
    def write_tl(value):
        lines.append('\t\t\t\t\t<tl>')
        if isinstance(value, str):
            lines.append('\t\t\t\t\t\t<v8:item>')
            lines.append(f'\t\t\t\t\t\t\t<v8:lang>{text_lang}</v8:lang>')
            lines.append(f'\t\t\t\t\t\t\t<v8:content>{esc_xml_text(value)}</v8:content>')
            lines.append('\t\t\t\t\t\t</v8:item>')
        else:
            for lang, content in value.items():
                lines.append('\t\t\t\t\t\t<v8:item>')
                lines.append(f'\t\t\t\t\t\t\t<v8:lang>{lang}</v8:lang>')
                lines.append(f'\t\t\t\t\t\t\t<v8:content>{esc_xml_text(str(content))}</v8:content>')
                lines.append('\t\t\t\t\t\t</v8:item>')
        lines.append('\t\t\t\t\t</tl>')

    # 7c. Columns
    lines.append('\t<columns>')
    lines.append(f'\t\t<size>{total_columns}</size>')

    # Emit columnsItem for columns with non-default widths
    for col in sorted(col_format_map.keys()):
        fmt_idx = col_format_map[col]
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
    active_rowspans = []  # list of {ColStart, ColEnd, StartLocalRow, EndLocalRow}

    for group in row_groups:
        area_start_row = global_row
        area_name = group['Name']
        active_rowspans = []
        local_row = 0

        for row in group['Rows']:
            # List-of-values shorthand: treat as row with no properties (like PS1)
            if isinstance(row, list):
                row = {}
            # Empty row placeholder: emit N empty rows
            if row.get('empty'):
                count = int(row['empty'])
                for ei in range(count):
                    lines.append('\t<rowsItem>')
                    lines.append(f'\t\t<index>{global_row}</index>')
                    lines.append('\t\t<row>')
                    lines.append('\t\t\t<empty>true</empty>')
                    lines.append('\t\t</row>')
                    lines.append('\t</rowsItem>')
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
            row_format_idx = 0
            if row.get('height'):
                h_key = get_format_key(height=int(row['height']))
                if h_key in format_registry:
                    row_format_idx = format_order.index(h_key) + 1

            if row.get('cells') and len(row['cells']) > 0:
                row_has_content = True

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
                    # An explicitly empty style means the cell names no format at all
                    if cell.get('style') is not None:
                        cell_style = str(cell['style'])
                    else:
                        cell_style = row.get('rowStyle') or 'default'
                    ft = get_fill_type(cell)
                    fmt_idx = register_cell_format(cell_style, ft, cell)

                    cell_info = {
                        'Col': col_start - 1,  # 0-based
                        'FormatIdx': fmt_idx,
                        'Param': cell.get('param'),
                        'Detail': cell.get('detail'),
                        'Text': cell.get('text'),
                        'Template': cell.get('template'),
                        'Extra': cell.get('extra'),
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

                    # Collect merge (horizontal, vertical, both, or an explicit 1x1 record)
                    if col_span > 1 or rowspan > 1 or cell.get('merge') is True:
                        merge = {'R': global_row, 'C': col_start - 1, 'W': col_span - 1}
                        if rowspan > 1:
                            merge['H'] = rowspan - 1
                        merges.append(merge)

                # Generate gap-fill cells for rowStyle
                if row.get('rowStyle'):
                    gap_fmt_idx = register_cell_format(row['rowStyle'], '')
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

            elif row.get('rowStyle'):
                # Row with only rowStyle, no explicit cells
                row_has_content = True
                gap_fmt_idx = register_cell_format(row['rowStyle'], '')
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

            # Emit rowsItem
            lines.append('\t<rowsItem>')
            lines.append(f'\t\t<index>{global_row}</index>')
            lines.append('\t\t<row>')

            if row_format_idx > 0:
                lines.append(f'\t\t\t<formatIndex>{row_format_idx}</formatIndex>')

            if not row_has_content:
                lines.append('\t\t\t<empty>true</empty>')
            else:
                for cell_info in row_cells:
                    lines.append('\t\t\t<c>')
                    lines.append(f'\t\t\t\t<i>{cell_info["Col"]}</i>')
                    lines.append('\t\t\t\t<c>')
                    lines.append(f'\t\t\t\t\t<f>{cell_info["FormatIdx"]}</f>')

                    if cell_info['Param']:
                        lines.append(f'\t\t\t\t\t<parameter>{cell_info["Param"]}</parameter>')

                    # Platform order inside a cell: f, parameter, v, detailParameter,
                    # tl, control, everything else
                    write_cell_extra(cell_info.get('Extra'), ['v'])

                    # A detail parameter can stand on its own, without a parameter
                    if cell_info['Detail']:
                        lines.append(f'\t\t\t\t\t<detailParameter>{cell_info["Detail"]}</detailParameter>')

                    if cell_info['Text']:
                        write_tl(cell_info['Text'])
                    if cell_info['Template']:
                        write_tl(cell_info['Template'])

                    write_cell_extra(cell_info.get('Extra'), ['v'], True)

                    lines.append('\t\t\t\t</c>')
                    lines.append('\t\t\t</c>')

            lines.append('\t\t</row>')
            lines.append('\t</rowsItem>')

            local_row += 1
            global_row += 1

        area_end_row = global_row - 1
        if area_name:
            named_items.append({
                'Name': area_name,
                'Type': 'Rows',
                'BeginRow': area_start_row,
                'EndRow': area_end_row,
                'BeginCol': -1,
                'EndCol': -1,
            })

    # Explicit named areas (any type) — coordinates are 1-based in the DSL
    for na in (defn.get('namedAreas') or []):
        na_type = str(na['type']) if na.get('type') else 'Rectangle'
        item = {
            'Name': na.get('name'),
            'Type': na_type,
            'BeginRow': -1, 'EndRow': -1,
            'BeginCol': -1, 'EndCol': -1,
        }
        # Bounds are independent: a missing one stays -1, which the platform reads as
        # "open on that side" (it writes such areas itself)
        if na.get('firstRow') is not None:
            item['BeginRow'] = int(na['firstRow']) - 1
        if na.get('lastRow') is not None:
            item['EndRow'] = int(na['lastRow']) - 1
        elif na.get('firstRow') is not None:
            item['EndRow'] = item['BeginRow']

        if na.get('firstCol') is not None:
            item['BeginCol'] = int(na['firstCol']) - 1
        if na.get('lastCol') is not None:
            item['EndCol'] = int(na['lastCol']) - 1
        elif na.get('firstCol') is not None:
            item['EndCol'] = item['BeginCol']

        if na_type != 'Columns' and item['BeginRow'] < 0 and item['EndRow'] < 0:
            print(f"WARNING: Named area '{na.get('name')}' of type {na_type} has no row range",
                  file=sys.stderr)
        if na_type != 'Rows' and item['BeginCol'] < 0 and item['EndCol'] < 0:
            print(f"WARNING: Named area '{na.get('name')}' of type {na_type} has no column range",
                  file=sys.stderr)
        named_items.append(item)

    total_row_count = global_row

    # 7e. Scalar metadata
    lines.append(f'\t<templateMode>true</templateMode>')
    lines.append(f'\t<defaultFormatIndex>{default_format_index}</defaultFormatIndex>')
    # An explicit height keeps the declared geometry of templates that carry rows
    # past their own height
    doc_height_out = int(defn['height']) if defn.get('height') else total_row_count
    lines.append(f'\t<height>{doc_height_out}</height>')
    lines.append(f'\t<vgRows>{doc_height_out}</vgRows>')

    # 7f. Merges
    for m in merges:
        lines.append('\t<merge>')
        lines.append(f'\t\t<r>{m["R"]}</r>')
        lines.append(f'\t\t<c>{m["C"]}</c>')
        if m.get('H'):
            lines.append(f'\t\t<h>{m["H"]}</h>')
        lines.append(f'\t\t<w>{m["W"]}</w>')
        lines.append('\t</merge>')

    # Merges that belong to no cell (-1 = all rows / all columns), written verbatim
    for m in (defn.get('extraMerges') or []):
        lines.append('\t<merge>')
        lines.append(f'\t\t<r>{int(m["r"])}</r>')
        lines.append(f'\t\t<c>{int(m["c"])}</c>')
        if m.get('h'):
            lines.append(f'\t\t<h>{int(m["h"])}</h>')
        lines.append(f'\t\t<w>{int(m["w"]) if m.get("w") is not None else 0}</w>')
        lines.append('\t</merge>')

    # 7g. Named items
    for ni in named_items:
        lines.append('\t<namedItem xsi:type="NamedItemCells">')
        lines.append(f'\t\t<name>{ni["Name"]}</name>')
        lines.append('\t\t<area>')
        lines.append(f'\t\t\t<type>{ni["Type"]}</type>')
        lines.append(f'\t\t\t<beginRow>{ni["BeginRow"]}</beginRow>')
        lines.append(f'\t\t\t<endRow>{ni["EndRow"]}</endRow>')
        lines.append(f'\t\t\t<beginColumn>{ni["BeginCol"]}</beginColumn>')
        lines.append(f'\t\t\t<endColumn>{ni["EndCol"]}</endColumn>')
        lines.append('\t\t</area>')
        lines.append('\t</namedItem>')

    # 7h. Line palette
    for key in line_palette:
        width, style = key.split('|')
        lines.append(f'\t<line width="{width}" gap="false">')
        lines.append(f'\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">{style}</v8ui:style>')
        lines.append('\t</line>')

    # 7i. Font palette
    for fe in font_entries:
        # Height is written with a dot regardless of the machine locale, and an
        # integral value keeps its integer form (10, not 10.0)
        size = fe['Size']
        font_height = str(int(size)) if float(size) == int(size) else repr(float(size))

        if fe['Ref'] or (fe['Kind'] and fe['Kind'] != 'Absolute'):
            # System font: keep it minimal, the platform fills the rest from the OS
            attrs = []
            if fe['Ref']:
                attrs.append(f'ref="{fe["Ref"]}"')
            attrs.append(f'faceName="{fe["Face"]}"')
            if fe['HasSize']:
                attrs.append(f'height="{font_height}"')
            # Written when the definition states them at all, false included
            if fe['HasStyleAttrs']:
                attrs.append(f'bold="{fe["Bold"]}"')
                attrs.append(f'italic="{fe["Italic"]}"')
                attrs.append(f'underline="{fe["Underline"]}"')
                attrs.append(f'strikeout="{fe["Strikeout"]}"')
            else:
                if fe['Bold'] == 'true':
                    attrs.append('bold="true"')
                if fe['Italic'] == 'true':
                    attrs.append('italic="true"')
                if fe['Underline'] == 'true':
                    attrs.append('underline="true"')
                if fe['Strikeout'] == 'true':
                    attrs.append('strikeout="true"')
            attrs.append(f'kind="{fe["Kind"] or "Absolute"}"')
            lines.append('\t<font ' + ' '.join(attrs) + '/>')
        else:
            lines.append(f'\t<font faceName="{fe["Face"]}" height="{font_height}" bold="{fe["Bold"]}" italic="{fe["Italic"]}" underline="{fe["Underline"]}" strikeout="{fe["Strikeout"]}" kind="Absolute" scale="100"/>')

    # 7j. Format palette
    # Every property is rendered into a name -> lines map first, so the element order
    # can follow the one captured from the source template.
    default_format_order = [
        'font', 'leftBorder', 'topBorder', 'rightBorder', 'bottomBorder', 'border',
        'borderColor', 'width', 'height', 'horizontalAlignment', 'verticalAlignment',
        'textPlacement', 'textColor', 'hidden', 'indent', 'fillType', 'format',
        'containsValue', 'valueType', 'controlType',
    ]

    for key in format_order:
        fmt = format_registry[key]
        out = {}

        if fmt.get('FontIdx') is not None and fmt.get('FontIdx', -1) >= 0:
            out['font'] = [f'\t\t<font>{fmt["FontIdx"]}</font>']

        # All four sides on one line -> <border>, as the platform writes it. It never
        # spells out four equal per-side elements.
        all_sides = (fmt.get('LB') is not None and fmt.get('LB', -1) >= 0
                     and fmt.get('LB') == fmt.get('TB')
                     and fmt.get('LB') == fmt.get('RB')
                     and fmt.get('LB') == fmt.get('BB'))

        if all_sides:
            out['border'] = [f'\t\t<border>{fmt["LB"]}</border>']
        else:
            if fmt.get('LB') is not None and fmt.get('LB', -1) >= 0:
                out['leftBorder'] = [f'\t\t<leftBorder>{fmt["LB"]}</leftBorder>']
            if fmt.get('TB') is not None and fmt.get('TB', -1) >= 0:
                out['topBorder'] = [f'\t\t<topBorder>{fmt["TB"]}</topBorder>']
            if fmt.get('RB') is not None and fmt.get('RB', -1) >= 0:
                out['rightBorder'] = [f'\t\t<rightBorder>{fmt["RB"]}</rightBorder>']
            if fmt.get('BB') is not None and fmt.get('BB', -1) >= 0:
                out['bottomBorder'] = [f'\t\t<bottomBorder>{fmt["BB"]}</bottomBorder>']

        if fmt.get('BorderColor'):
            out['borderColor'] = [f'\t\t<borderColor>{fmt["BorderColor"]}</borderColor>']
        if fmt.get('Width') is not None and fmt.get('Width', -1) >= 0:
            out['width'] = [f'\t\t<width>{fmt["Width"]}</width>']
        if fmt.get('Height') is not None and fmt.get('Height', -1) >= 0:
            out['height'] = [f'\t\t<height>{fmt["Height"]}</height>']
        if fmt.get('HA'):
            out['horizontalAlignment'] = [f'\t\t<horizontalAlignment>{fmt["HA"]}</horizontalAlignment>']
        if fmt.get('VA'):
            out['verticalAlignment'] = [f'\t\t<verticalAlignment>{fmt["VA"]}</verticalAlignment>']
        if fmt.get('Wrap'):
            out['textPlacement'] = [f'\t\t<textPlacement>{fmt["Wrap"]}</textPlacement>']
        if fmt.get('TextColor'):
            out['textColor'] = [f'\t\t<textColor>{fmt["TextColor"]}</textColor>']
        if fmt.get('Hidden'):
            out['hidden'] = [f'\t\t<hidden>{fmt["Hidden"]}</hidden>']
        if fmt.get('Indent') is not None and fmt.get('Indent', -1) >= 0:
            out['indent'] = [f'\t\t<indent>{fmt["Indent"]}</indent>']
        if fmt.get('FillType'):
            out['fillType'] = [f'\t\t<fillType>{fmt["FillType"]}</fillType>']

        if fmt.get('NumberFormat'):
            nf = fmt['NumberFormat']
            nf_lines = ['\t\t<format>']
            if isinstance(nf, str):
                nf_lines.append('\t\t\t<v8:item>')
                nf_lines.append(f'\t\t\t\t<v8:lang>{text_lang}</v8:lang>')
                nf_lines.append(f'\t\t\t\t<v8:content>{esc_xml_text(nf)}</v8:content>')
                nf_lines.append('\t\t\t</v8:item>')
            else:
                for lang, content in nf.items():
                    nf_lines.append('\t\t\t<v8:item>')
                    nf_lines.append(f'\t\t\t\t<v8:lang>{lang}</v8:lang>')
                    nf_lines.append(f'\t\t\t\t<v8:content>{esc_xml_text(str(content))}</v8:content>')
                    nf_lines.append('\t\t\t</v8:item>')
            nf_lines.append('\t\t</format>')
            out['format'] = nf_lines

        # Input cell: containsValue -> valueType -> controlType
        if fmt.get('ControlType'):
            out['containsValue'] = ['\t\t<containsValue>true</containsValue>']
            vt = fmt.get('ValueType')
            if vt:
                vt_lines = ['\t\t<valueType>']
                if vt['Type'] == 'number':
                    vt_lines.append('\t\t\t<v8:Type>xs:decimal</v8:Type>')
                    vt_lines.append('\t\t\t<v8:NumberQualifiers>')
                    vt_lines.append(f'\t\t\t\t<v8:Digits>{vt["Digits"]}</v8:Digits>')
                    vt_lines.append(f'\t\t\t\t<v8:FractionDigits>{vt["FractionDigits"]}</v8:FractionDigits>')
                    vt_lines.append(f'\t\t\t\t<v8:AllowedSign>{vt["AllowedSign"]}</v8:AllowedSign>')
                    vt_lines.append('\t\t\t</v8:NumberQualifiers>')
                elif vt['Type'] == 'string':
                    vt_lines.append('\t\t\t<v8:Type>xs:string</v8:Type>')
                    vt_lines.append('\t\t\t<v8:StringQualifiers>')
                    vt_lines.append(f'\t\t\t\t<v8:Length>{vt["Length"]}</v8:Length>')
                    vt_lines.append(f'\t\t\t\t<v8:AllowedLength>{vt["AllowedLength"]}</v8:AllowedLength>')
                    vt_lines.append('\t\t\t</v8:StringQualifiers>')
                elif vt['Type'] == 'date':
                    vt_lines.append(f'\t\t\t<v8:Type>{vt["XsType"]}</v8:Type>')
                    vt_lines.append('\t\t\t<v8:DateQualifiers>')
                    vt_lines.append(f'\t\t\t\t<v8:DateFractions>{vt["DateFractions"]}</v8:DateFractions>')
                    vt_lines.append('\t\t\t</v8:DateQualifiers>')
                elif vt['Type'] == 'boolean':
                    vt_lines.append('\t\t\t<v8:Type>xs:boolean</v8:Type>')
                vt_lines.append('\t\t</valueType>')
                out['valueType'] = vt_lines
            out['controlType'] = [f'\t\t<controlType>{fmt["ControlType"]}</controlType>']

        # Properties the DSL does not model, carried over as they were
        if fmt.get('Extra'):
            for e in fmt['Extra']:
                out[str(e['name'])] = ['\t\t' + e['xml']]

        # Order: the one captured from the source, then anything it did not mention
        order = []
        for nm in (fmt.get('Order') or []):
            if nm not in order:
                order.append(nm)
        for nm in default_format_order:
            if nm not in order:
                order.append(nm)
        for nm in out:
            if nm not in order:
                order.append(nm)

        lines.append('\t<format>')
        for nm in order:
            if nm not in out:
                continue
            lines.extend(out[nm])
        lines.append('\t</format>')

    # 7k. Close document
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
    mode = 'flat' if flat_mode else 'blocks'
    type_counts = {}
    for ni in named_items:
        type_counts[ni['Type']] = type_counts.get(ni['Type'], 0) + 1
    by_type = ', '.join(f'{k}={v}' for k, v in type_counts.items())
    print(f"     Mode: {mode}, Areas: {len(named_items)} ({by_type}), Rows: {total_row_count}, Columns: {total_columns}")
    print(f"     Fonts: {len(font_entries)}, Lines: {len(line_palette)}, Formats: {len(format_registry)}")
    extra_merge_count = len(defn.get('extraMerges') or [])
    print(f"     Merges: {len(merges) + extra_merge_count}")


if __name__ == '__main__':
    main()
