#!/usr/bin/env python3
# mxl-validate v1.8 — Validate 1C spreadsheet document Template.xml
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Validates spreadsheet Template.xml: height, palette refs, column/row indices, areas, merges."""
import sys, os, argparse
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


NS_D   = 'http://v8.1c.ru/8.2/data/spreadsheet'
NS_V8  = 'http://v8.1c.ru/8.1/data/core'
NS_XSI = 'http://www.w3.org/2001/XMLSchema-instance'

NS = {
    'd':   NS_D,
    'v8':  NS_V8,
    'xsi': NS_XSI,
}


class Reporter:
    def __init__(self, max_errors, detailed=False):
        self.errors = 0
        self.warnings = 0
        self.ok_count = 0
        self.stopped = False
        self.max_errors = max_errors
        self.detailed = detailed
        self.lines = []

    def ok(self, msg):
        self.ok_count += 1
        if self.detailed:
            self.lines.append(f'[OK]    {msg}')

    def error(self, msg):
        self.errors += 1
        self.lines.append(f'[ERROR] {msg}')
        if self.errors >= self.max_errors:
            self.stopped = True

    def warn(self, msg):
        self.warnings += 1
        self.lines.append(f'[WARN]  {msg}')


def int_text(node):
    """Return int from node text, or 0 if None."""
    if node is not None and node.text:
        return int(node.text)
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description='Validate 1C spreadsheet document Template.xml', allow_abbrev=False
    )
    parser.add_argument('-TemplatePath', '-Path', dest='TemplatePath', default='')
    parser.add_argument('-ProcessorName', dest='ProcessorName', default='')
    parser.add_argument('-TemplateName', dest='TemplateName', default='')
    parser.add_argument('-SrcDir', dest='SrcDir', default='src')
    parser.add_argument('-Detailed', action='store_true')
    parser.add_argument('-MaxErrors', dest='MaxErrors', type=int, default=20)
    args = ci_parse_args(parser)

    template_path = args.TemplatePath
    processor_name = args.ProcessorName
    template_name_arg = args.TemplateName
    src_dir = args.SrcDir
    detailed = args.Detailed
    max_errors = args.MaxErrors

    # --- Resolve template path ---
    if not template_path:
        if not processor_name or not template_name_arg:
            print('Specify -TemplatePath or both -ProcessorName and -TemplateName', file=sys.stderr)
            sys.exit(1)
        template_path = os.path.join(src_dir, processor_name, 'Templates',
                                     template_name_arg, 'Ext', 'Template.xml')

    if not os.path.isabs(template_path):
        template_path = os.path.join(os.getcwd(), template_path)

    # A: Directory → Ext/Template.xml
    if os.path.isdir(template_path):
        template_path = os.path.join(template_path, 'Ext', 'Template.xml')
    # B1: Missing Ext/ (e.g. Templates/Макет/Template.xml → Templates/Макет/Ext/Template.xml)
    if not os.path.exists(template_path):
        fn = os.path.basename(template_path)
        if fn == 'Template.xml':
            c = os.path.join(os.path.dirname(template_path), 'Ext', fn)
            if os.path.exists(c):
                template_path = c
    # B2: Descriptor (Templates/Макет.xml → Templates/Макет/Ext/Template.xml)
    if not os.path.exists(template_path) and template_path.endswith('.xml'):
        stem = os.path.splitext(os.path.basename(template_path))[0]
        parent = os.path.dirname(template_path)
        c = os.path.join(parent, stem, 'Ext', 'Template.xml')
        if os.path.exists(c):
            template_path = c

    if not os.path.exists(template_path):
        print(f'File not found: {template_path}', file=sys.stderr)
        sys.exit(1)

    resolved_path = os.path.abspath(template_path)

    # --- Load XML ---
    xml_parser = etree.XMLParser(remove_blank_text=False)
    xml_doc = etree.parse(resolved_path, xml_parser)
    root = xml_doc.getroot()

    r = Reporter(max_errors, detailed)

    # Derive template name from path: .../Templates/<Name>/Ext/Template.xml
    # Go up 2 levels from Template.xml -> Ext -> <Name>
    template_display_name = os.path.basename(os.path.dirname(os.path.dirname(resolved_path)))
    r.lines.append(f'=== Validation: Template.{template_display_name} ===')
    r.lines.append('')

    # --- Collect palettes ---
    line_nodes = root.findall(f'{{{NS_D}}}line')
    line_count = len(line_nodes)

    font_nodes = [node for node in root if isinstance(node.tag, str) and etree.QName(node.tag).localname == 'font']
    font_count = len(font_nodes)

    format_nodes = [node for node in root if isinstance(node.tag, str) and etree.QName(node.tag).localname == 'format']
    format_count = len(format_nodes)

    picture_nodes = root.findall(f'{{{NS_D}}}picture')
    picture_count = len(picture_nodes)

    # --- Collect column sets ---
    column_sets = {}  # id -> size
    default_col_count = 0

    for cols in root.findall(f'{{{NS_D}}}columns'):
        size_node = cols.find(f'{{{NS_D}}}size')
        id_node = cols.find(f'{{{NS_D}}}id')
        size = int_text(size_node)

        if id_node is not None and id_node.text:
            column_sets[id_node.text] = size
        else:
            default_col_count = size

    # --- Check 1: height vs actual rows ---
    row_nodes = root.findall(f'{{{NS_D}}}rowsItem')
    height_node = root.find(f'{{{NS_D}}}height')
    doc_height = int_text(height_node)

    max_row_index = -1
    for ri in row_nodes:
        idx_node = ri.find(f'{{{NS_D}}}index')
        if idx_node is not None and idx_node.text:
            idx = int(idx_node.text)
            if idx > max_row_index:
                max_row_index = idx

    expected_min_height = max_row_index + 1
    if doc_height >= expected_min_height:
        r.ok(f'height ({doc_height}) >= max row index + 1 ({expected_min_height}), rowsItem count={len(row_nodes)}')
    else:
        r.error(f'height={doc_height} but max row index={max_row_index} (need at least {expected_min_height})')

    # --- Check 2: vgRows <= height ---
    vg_rows_node = root.find(f'{{{NS_D}}}vgRows')
    if vg_rows_node is not None:
        vg_rows = int_text(vg_rows_node)
        if vg_rows <= doc_height:
            r.ok(f'vgRows ({vg_rows}) <= height ({doc_height})')
        else:
            r.warn(f'vgRows ({vg_rows}) > height ({doc_height})')

    # --- Build row data for checks ---
    max_format_ref = 0
    max_font_ref = 0
    max_line_ref = 0

    # Check format palette references in formats (font, border indices)
    for fmt in format_nodes:
        font_idx_node = fmt.find(f'{{{NS_D}}}font')
        if font_idx_node is not None and font_idx_node.text:
            val = int(font_idx_node.text)
            if val > max_font_ref:
                max_font_ref = val

        for border_name in ('leftBorder', 'topBorder', 'rightBorder', 'bottomBorder', 'drawingBorder'):
            border_node = fmt.find(f'{{{NS_D}}}{border_name}')
            if border_node is not None and border_node.text:
                val = int(border_node.text)
                if val > max_line_ref:
                    max_line_ref = val

    # --- Check 10: font indices in formats ---
    if font_count > 0:
        if max_font_ref < font_count:
            r.ok(f'Font refs: max={max_font_ref}, palette size={font_count}')
        else:
            r.error(f'Font index {max_font_ref} exceeds palette size ({font_count})')
    elif max_font_ref > 0:
        r.error(f'Font index {max_font_ref} referenced but no fonts defined')
    else:
        # Макет без единого шрифта — норма (ячейки-поля ввода, макеты без оформления).
        # Строку печатаем как ps1-порт: раньше py молчал, и на таком макете число проверок
        # у портов расходилось.
        r.ok('No font references')

    # --- Check 11: line/border indices in formats ---
    if line_count > 0:
        if max_line_ref < line_count:
            r.ok(f'Line/border refs: max={max_line_ref}, palette size={line_count}')
        else:
            r.error(f'Line index {max_line_ref} exceeds palette size ({line_count})')
    elif max_line_ref > 0:
        r.error(f'Line index {max_line_ref} referenced but no lines defined')
    else:
        r.ok('No line/border references')

    # --- Check 3, 4, 5, 6: row/cell checks ---
    max_cell_format_ref = 0
    max_row_format_ref = 0
    max_default_col_idx = 0
    row_index = 0

    for ri in row_nodes:
        if r.stopped:
            break

        idx_node = ri.find(f'{{{NS_D}}}index')
        if idx_node is not None and idx_node.text:
            row_index = int(idx_node.text)

        row = ri.find(f'{{{NS_D}}}row')
        if row is None:
            row_index += 1
            continue

        # Row formatIndex
        row_fmt_node = row.find(f'{{{NS_D}}}formatIndex')
        if row_fmt_node is not None and row_fmt_node.text:
            val = int(row_fmt_node.text)
            if val > max_row_format_ref:
                max_row_format_ref = val
            if val > format_count:
                r.error(f'Row {row_index}: formatIndex={val} > format palette size ({format_count})')

        # Check columnsID
        row_cols_id = None
        cols_id_node = row.find(f'{{{NS_D}}}columnsID')
        if cols_id_node is not None and cols_id_node.text:
            row_cols_id = cols_id_node.text
            if row_cols_id not in column_sets:
                r.error(f"Row {row_index}: columnsID '{row_cols_id[:8]}...' not found in column sets")

        # Determine column count for this row
        row_col_count = default_col_count
        if row_cols_id and row_cols_id in column_sets:
            row_col_count = column_sets[row_cols_id]

        # Cell checks
        for c_group in row.findall(f'{{{NS_D}}}c'):
            i_node = c_group.find(f'{{{NS_D}}}i')
            col_idx = None
            if i_node is not None and i_node.text:
                col_idx = int(i_node.text)
                # Track max index for default column set only
                if row_cols_id is None and col_idx > max_default_col_idx:
                    max_default_col_idx = col_idx
                # Check against row's column count
                if row_col_count > 0 and col_idx >= row_col_count:
                    r.error(f'Row {row_index}: column index {col_idx} >= column count ({row_col_count})')

            cell = c_group.find(f'{{{NS_D}}}c')
            if cell is not None:
                f_node = cell.find(f'{{{NS_D}}}f')
                if f_node is not None and f_node.text:
                    val = int(f_node.text)
                    if val > max_cell_format_ref:
                        max_cell_format_ref = val
                    if val > format_count:
                        r.error(f'Row {row_index}: cell format index {val} > format palette size ({format_count})')
                # Примечание — четвёртый владелец формата, и его ссылка тоже бывает битой.
                note = cell.find(f'{{{NS_D}}}note')
                if note is not None:
                    nf = note.find(f'{{{NS_D}}}formatIndex')
                    if nf is not None and nf.text and int(nf.text) > format_count:
                        r.error(f'Row {row_index}: note format index {nf.text}'
                                f' > format palette size ({format_count})')

        row_index += 1

    # Summary checks for format refs
    if not r.stopped:
        if max_cell_format_ref <= format_count and max_row_format_ref <= format_count:
            r.ok(f'Format refs: max cell={max_cell_format_ref}, max row={max_row_format_ref}, palette size={format_count}')

    # Check column format indices
    for cols in root.findall(f'{{{NS_D}}}columns'):
        if r.stopped:
            break
        for ci in cols.findall(f'{{{NS_D}}}columnsItem'):
            col = ci.find(f'{{{NS_D}}}column')
            if col is not None:
                fmt_node = col.find(f'{{{NS_D}}}formatIndex')
                if fmt_node is not None and fmt_node.text:
                    val = int(fmt_node.text)
                    if val > format_count:
                        col_idx_node = ci.find(f'{{{NS_D}}}index')
                        col_idx_text = col_idx_node.text if col_idx_node is not None else '?'
                        r.error(f'Column {col_idx_text}: formatIndex={val} > format palette size ({format_count})')

    # --- Check 5: column index summary ---
    if not r.stopped:
        r.ok(f'Column indices: max in default set={max_default_col_idx}, default column count={default_col_count}')

    # --- Check 7, 8: named areas ---
    for ni in root.findall(f'{{{NS_D}}}namedItem'):
        if r.stopped:
            break

        ni_type = ni.get(f'{{{NS_XSI}}}type', '')
        name_node = ni.find(f'{{{NS_D}}}name')
        name = name_node.text if name_node is not None else ''

        if 'NamedItemCells' in ni_type:
            area = ni.find(f'{{{NS_D}}}area')
            if area is None:
                continue
            begin_row = int_text(area.find(f'{{{NS_D}}}beginRow'))
            end_row = int_text(area.find(f'{{{NS_D}}}endRow'))

            # Check row bounds (skip -1 which means "all")
            if begin_row != -1 and begin_row >= doc_height:
                r.error(f"Area '{name}': beginRow={begin_row} >= height={doc_height}")
            if end_row != -1 and end_row >= doc_height:
                r.error(f"Area '{name}': endRow={end_row} >= height={doc_height}")

            # Check columnsID reference
            cols_id_node = area.find(f'{{{NS_D}}}columnsID')
            if cols_id_node is not None and cols_id_node.text:
                cols_id = cols_id_node.text
                if cols_id not in column_sets:
                    r.error(f"Area '{name}': columnsID '{cols_id[:8]}...' not found")

    # --- Check 9: merge bounds ---
    for merge in root.findall(f'{{{NS_D}}}merge'):
        if r.stopped:
            break

        merge_r = int_text(merge.find(f'{{{NS_D}}}r'))
        merge_c = int_text(merge.find(f'{{{NS_D}}}c'))
        w_node = merge.find(f'{{{NS_D}}}w')
        h_node = merge.find(f'{{{NS_D}}}h')

        # r=-1 means all rows, skip bound check
        if merge_r != -1 and merge_r >= doc_height:
            r.error(f'Merge at row={merge_r}, col={merge_c}: row >= height ({doc_height})')

        if h_node is not None and merge_r != -1:
            h = int_text(h_node)
            if (merge_r + h) >= doc_height:
                r.error(f'Merge at row={merge_r}: extends to row {merge_r + h} >= height ({doc_height})')

        # Check columnsID in merge
        cols_id_node = merge.find(f'{{{NS_D}}}columnsID')
        if cols_id_node is not None and cols_id_node.text:
            cols_id = cols_id_node.text
            if cols_id not in column_sets:
                r.error(f"Merge at row={merge_r}, col={merge_c}: columnsID '{cols_id[:8]}...' not found")

    # --- Check 12: drawing picture indices ---
    for drawing in root.findall(f'{{{NS_D}}}drawing'):
        if r.stopped:
            break

        pic_idx_node = drawing.find(f'{{{NS_D}}}pictureIndex')
        if pic_idx_node is not None and pic_idx_node.text:
            pic_idx = int(pic_idx_node.text)
            if pic_idx > picture_count:
                draw_id_node = drawing.find(f'{{{NS_D}}}id')
                draw_id = draw_id_node.text if draw_id_node is not None else '?'
                r.error(f'Drawing id={draw_id}: pictureIndex={pic_idx} > picture count ({picture_count})')

        # Оформление рисунка — такая же запись палитры форматов, как у ячейки, и висячая
        # ссылка на неё так же валит загрузку макета.
        fmt_idx_node = drawing.find(f'{{{NS_D}}}formatIndex')
        if fmt_idx_node is not None and fmt_idx_node.text:
            fmt_idx = int(fmt_idx_node.text)
            if fmt_idx > format_count:
                draw_id_node = drawing.find(f'{{{NS_D}}}id')
                draw_id = draw_id_node.text if draw_id_node is not None else '?'
                r.error(f'Drawing id={draw_id}: formatIndex={fmt_idx} > format palette size ({format_count})')

    # --- Check 13: value cells (input fields) ---
    # Свойства containsValue/valueType/controlType принадлежат ЯЧЕЙКЕ: на корпусе ERP
    # (370 197 ссылок) на такие записи палитры ссылаются только <f>, ни строка, ни колонка,
    # ни defaultFormatIndex. Ячейка со значением текста не несёт — ни одна из 370 197.
    value_format_idx = set()
    control_guids = ('381ed624-9217-4e63-85db-c4c3cb87daae', '35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26')
    for i, fmt in enumerate(format_nodes, start=1):
        contains = fmt.find(f'{{{NS_D}}}containsValue')
        vt = fmt.find(f'{{{NS_D}}}valueType')
        if contains is None and vt is None:
            continue
        value_format_idx.add(i)
        if contains is None or (contains.text or '').strip() != 'true':
            r.error(f'Format {i}: <valueType> without <containsValue>true</containsValue>')
        elif vt is None:
            r.error(f'Format {i}: <containsValue> without <valueType>')
        if vt is not None:
            for child in vt:
                tag = child.tag.split('}')[-1]
                if tag not in ('Type', 'TypeSet') and not tag.endswith('Qualifiers'):
                    r.error(f'Format {i}: unexpected <{tag}> inside <valueType>')
        ctl = fmt.find(f'{{{NS_D}}}controlType')
        if ctl is not None and (ctl.text or '').strip().lower() not in control_guids:
            r.warn(f'Format {i}: unknown controlType {(ctl.text or "").strip()}')
        # Флажок Конфигуратор предлагает только для булева и числа. Движок принимает его на
        # любом типе (проверено сборкой EPF и обратной выгрузкой), поэтому это предупреждение,
        # а не ошибка: собрать такую ячейку в Конфигураторе нельзя, и почти наверняка это описка.
        if ctl is not None and (ctl.text or '').strip().lower() == control_guids[1] and vt is not None:
            kinds = [(t.text or '').strip() for t in vt if t.tag.endswith('}Type')]
            if kinds != ['xs:boolean'] and kinds != ['xs:decimal']:
                r.warn(f'Format {i}: checkbox control on a type other than Boolean or Number')

    for ri in root.findall(f'{{{NS_D}}}rowsItem'):
        if r.stopped:
            break
        row = ri.find(f'{{{NS_D}}}row')
        if row is None:
            continue
        idx_node = ri.find(f'{{{NS_D}}}index')
        rn = idx_node.text if idx_node is not None else '?'
        row_fmt = row.find(f'{{{NS_D}}}formatIndex')
        if row_fmt is not None and row_fmt.text and int(row_fmt.text) in value_format_idx:
            r.warn(f'Row {rn}: formatIndex points to a value format (cell-only property)')
        for c_group in row.findall(f'{{{NS_D}}}c'):
            cell = c_group.find(f'{{{NS_D}}}c')
            if cell is None:
                continue
            f_node = cell.find(f'{{{NS_D}}}f')
            if f_node is None or not f_node.text or int(f_node.text) not in value_format_idx:
                continue
            if cell.find(f'{{{NS_D}}}tl') is not None:
                r.error(f'Row {rn}: cell contains a value and text at the same time')
    # Значение и настройки элемента управления бывают только у ячейки-поля ввода: на корпусе
    # ни одного <v> и ни одного <control> в обычной ячейке.
    for ri in root.findall(f'{{{NS_D}}}rowsItem'):
        if r.stopped:
            break
        row = ri.find(f'{{{NS_D}}}row')
        if row is None:
            continue
        idx_node = ri.find(f'{{{NS_D}}}index')
        rn = idx_node.text if idx_node is not None else '?'
        for c_group in row.findall(f'{{{NS_D}}}c'):
            cell = c_group.find(f'{{{NS_D}}}c')
            if cell is None:
                continue
            f_node = cell.find(f'{{{NS_D}}}f')
            is_value = f_node is not None and f_node.text and int(f_node.text) in value_format_idx
            if is_value:
                continue
            for tag, what in (('v', 'value'), ('control', 'control settings')):
                if cell.find(f'{{{NS_D}}}{tag}') is not None:
                    r.error(f'Row {rn}: cell carries {what} but its format has no containsValue')
    for cols in root.findall(f'{{{NS_D}}}columns'):
        for ci in cols.findall(f'{{{NS_D}}}columnsItem'):
            col = ci.find(f'{{{NS_D}}}column')
            if col is None:
                continue
            fmt_node = col.find(f'{{{NS_D}}}formatIndex')
            if fmt_node is not None and fmt_node.text and int(fmt_node.text) in value_format_idx:
                col_idx_node = ci.find(f'{{{NS_D}}}index')
                col_idx_text = col_idx_node.text if col_idx_node is not None else '?'
                r.warn(f'Column {col_idx_text}: formatIndex points to a value format (cell-only property)')
    dfi = root.find(f'{{{NS_D}}}defaultFormatIndex')
    if dfi is not None and dfi.text and int(dfi.text) in value_format_idx:
        r.warn('defaultFormatIndex points to a value format (cell-only property)')
    if value_format_idx:
        r.ok(f'Value cells: {len(value_format_idx)} value formats')

    # --- Check 14: группировки строк и колонок ---
    # Диапазоны группировок либо вложены, либо не пересекаются: на корпусе 40 620 886 пар
    # непересекающихся и 599 958 вложенных, частичных пересечений нет ни одного.
    for tag in ('vg', 'hg'):
        ranges = []
        for g in root.findall(f'{{{NS_D}}}{tag}'):
            b_node = g.find(f'{{{NS_D}}}b')
            if b_node is None or not b_node.text:
                r.error(f'Group <{tag}>: <b> is missing')
                continue
            b = int(b_node.text)
            e_node = g.find(f'{{{NS_D}}}e')
            e = int(e_node.text) if e_node is not None and e_node.text else b
            if e < b:
                r.error(f'Group <{tag}> {b}..{e}: range is reversed')
            if tag == 'vg' and doc_height > 0 and b >= doc_height:
                r.warn(f'Group <vg> starts at row {b}, beyond document height ({doc_height})')
            ranges.append((b, e))
        for i in range(len(ranges)):
            for j in range(i + 1, len(ranges)):
                a, c = ranges[i], ranges[j]
                if a[1] < c[0] or c[1] < a[0]:
                    continue
                if (a[0] <= c[0] and c[1] <= a[1]) or (c[0] <= a[0] and a[1] <= c[1]):
                    continue
                r.error(f'Groups <{tag}> {a[0]}..{a[1]} and {c[0]}..{c[1]} overlap partially')
        if ranges:
            r.ok(f'Groups <{tag}>: {len(ranges)}')

    # --- Finalize ---
    checks = r.ok_count + r.errors + r.warnings
    if r.errors == 0 and r.warnings == 0 and not detailed:
        result = f'=== Validation OK: Template.{template_display_name} ({checks} checks) ==='
    else:
        r.lines.append('')
        r.lines.append(f'=== Result: {r.errors} errors, {r.warnings} warnings ({checks} checks) ===')
        result = '\n'.join(r.lines)

    print(result)

    sys.exit(1 if r.errors > 0 else 0)


if __name__ == '__main__':
    main()
