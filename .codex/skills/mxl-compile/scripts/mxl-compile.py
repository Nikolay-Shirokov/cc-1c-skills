#!/usr/bin/env python3
# mxl-compile v1.1 — Compile 1C spreadsheet from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import math
import os
import re
import sys


def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C spreadsheet from JSON', allow_abbrev=False)
    parser.add_argument('-JsonPath', type=str, required=True)
    parser.add_argument('-OutputPath', type=str, required=True)
    args = parser.parse_args()

    # --- 1. Load and validate JSON ---
    json_path = args.JsonPath
    if not os.path.exists(json_path):
        print(f"File not found: {json_path}", file=sys.stderr)
        sys.exit(1)

    with open(json_path, 'r', encoding='utf-8-sig') as f:
        defn = json.load(f)

    if not defn.get('columns'):
        print("Required field 'columns' is missing", file=sys.stderr)
        sys.exit(1)
    if not defn.get('areas'):
        print("Required field 'areas' is missing", file=sys.stderr)
        sys.exit(1)

    total_columns = int(defn['columns'])
    default_width = int(defn['defaultWidth']) if defn.get('defaultWidth') else 10

    # --- 2. Build font palette ---
    font_map = {}   # name -> 0-based index
    font_entries = []  # list of dicts

    def add_font(name, font_def):
        face = font_def.get('face', 'Arial') if font_def else 'Arial'
        size = int(font_def.get('size', 10)) if font_def else 10
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

    thin_line_index = -1
    thick_line_index = -1
    line_count = 0
    if has_thin_borders:
        thin_line_index = line_count
        line_count += 1
    if has_thick_borders:
        thick_line_index = line_count
        line_count += 1

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
        wrap = False

        if style_name and defn.get('styles'):
            style = defn['styles'].get(style_name)
            if style:
                # Font
                if style.get('font') and style['font'] in font_map:
                    font_idx = font_map[style['font']]

                # Borders
                if style.get('border') and style['border'] != 'none':
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
                if style.get('align'):
                    align_map = {'left': 'Left', 'center': 'Center', 'right': 'Right'}
                    ha = align_map.get(style['align'], '')
                if style.get('valign'):
                    valign_map = {'top': 'Top', 'center': 'Center'}
                    va = valign_map.get(style['valign'], '')

                # Wrap
                if style.get('wrap') is True:
                    wrap = True

                # Number format
                if style.get('format'):
                    nf = style['format']

        return {
            'FontIdx': font_idx,
            'LB': lb, 'TB': tb, 'RB': rb, 'BB': bb,
            'HA': ha, 'VA': va,
            'Wrap': wrap,
            'FillType': fill_type,
            'NumberFormat': nf,
        }

    # --- 6. Format palette builder ---
    format_registry = {}   # key -> props
    format_order = []       # ordered keys for index assignment

    def get_format_key(font_idx=-1, lb=-1, tb=-1, rb=-1, bb=-1, ha='', va='',
                       wrap=False, fill_type='', number_format='', width=-1, height=-1):
        return f'f={font_idx}|lb={lb}|tb={tb}|rb={rb}|bb={bb}|ha={ha}|va={va}|wr={wrap}|ft={fill_type}|nf={number_format}|w={width}|h={height}'

    def register_format(key, props):
        if key not in format_registry:
            format_registry[key] = props
            format_order.append(key)
        # Return 1-based index
        return format_order.index(key) + 1

    # 6a. Default width format
    default_format_key = get_format_key(width=default_width)
    default_format_index = register_format(default_format_key, {'Width': default_width})

    # 6b. Column width formats
    col_format_map = {}  # 1-based col -> format index
    for col in sorted(col_width_map):
        w = col_width_map[col]
        key = get_format_key(width=w)
        idx = register_format(key, {'Width': w})
        col_format_map[int(col)] = idx

    # 6c. Helper: determine fillType from cell content
    def get_fill_type(cell):
        if cell.get('param'):
            return 'Parameter'
        if cell.get('template'):
            return 'Template'
        if cell.get('text'):
            return 'Text'
        return ''

    # Helper: register a cell format and return its index
    def register_cell_format(style_name, fill_type):
        resolved = resolve_style(style_name, fill_type)
        key = get_format_key(
            font_idx=resolved['FontIdx'],
            lb=resolved['LB'], tb=resolved['TB'], rb=resolved['RB'], bb=resolved['BB'],
            ha=resolved['HA'], va=resolved['VA'],
            wrap=resolved['Wrap'], fill_type=resolved['FillType'],
            number_format=resolved['NumberFormat'])
        props = {
            'FontIdx': resolved['FontIdx'],
            'LB': resolved['LB'], 'TB': resolved['TB'],
            'RB': resolved['RB'], 'BB': resolved['BB'],
            'HA': resolved['HA'], 'VA': resolved['VA'],
            'Wrap': resolved['Wrap'],
            'FillType': resolved['FillType'],
            'NumberFormat': resolved['NumberFormat'],
        }
        return register_format(key, props)

    # Pre-register all formats from areas
    for area in defn['areas']:
        for row in area.get('rows', []):
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

            # rowStyle gap-fill format
            if row.get('rowStyle'):
                register_cell_format(row['rowStyle'], '')

            # Explicit cell formats
            if row.get('cells'):
                for cell in row['cells']:
                    cell_style = cell.get('style') or row.get('rowStyle') or 'default'
                    ft = get_fill_type(cell)
                    register_cell_format(cell_style, ft)

    # --- 7. Generate XML ---
    lines = []

    # 7a. Header
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<document xmlns="http://v8.1c.ru/8.2/data/spreadsheet" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">')

    # 7b. Language settings
    lines.append('\t<languageSettings>')
    lines.append('\t\t<currentLanguage>ru</currentLanguage>')
    lines.append('\t\t<defaultLanguage>ru</defaultLanguage>')
    lines.append('\t\t<languageInfo>')
    lines.append('\t\t\t<id>ru</id>')
    lines.append('\t\t\t<code>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</code>')
    lines.append('\t\t\t<description>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</description>')
    lines.append('\t\t</languageInfo>')
    lines.append('\t</languageSettings>')

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

    for area in defn['areas']:
        area_start_row = global_row
        area_name = area.get('name', '')
        active_rowspans = []
        local_row = 0

        for row in area.get('rows', []):
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
                    cell_style = cell.get('style') or row.get('rowStyle') or 'default'
                    ft = get_fill_type(cell)
                    fmt_idx = register_cell_format(cell_style, ft)

                    cell_info = {
                        'Col': col_start - 1,  # 0-based
                        'FormatIdx': fmt_idx,
                        'Param': cell.get('param'),
                        'Detail': cell.get('detail'),
                        'Text': cell.get('text'),
                        'Template': cell.get('template'),
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
                        if cell_info['Detail']:
                            lines.append(f'\t\t\t\t\t<detailParameter>{cell_info["Detail"]}</detailParameter>')

                    if cell_info['Text']:
                        lines.append('\t\t\t\t\t<tl>')
                        lines.append('\t\t\t\t\t\t<v8:item>')
                        lines.append('\t\t\t\t\t\t\t<v8:lang>ru</v8:lang>')
                        lines.append(f'\t\t\t\t\t\t\t<v8:content>{esc_xml(cell_info["Text"])}</v8:content>')
                        lines.append('\t\t\t\t\t\t</v8:item>')
                        lines.append('\t\t\t\t\t</tl>')

                    if cell_info['Template']:
                        lines.append('\t\t\t\t\t<tl>')
                        lines.append('\t\t\t\t\t\t<v8:item>')
                        lines.append('\t\t\t\t\t\t\t<v8:lang>ru</v8:lang>')
                        lines.append(f'\t\t\t\t\t\t\t<v8:content>{esc_xml(cell_info["Template"])}</v8:content>')
                        lines.append('\t\t\t\t\t\t</v8:item>')
                        lines.append('\t\t\t\t\t</tl>')

                    lines.append('\t\t\t\t</c>')
                    lines.append('\t\t\t</c>')

            lines.append('\t\t</row>')
            lines.append('\t</rowsItem>')

            local_row += 1
            global_row += 1

        area_end_row = global_row - 1
        named_items.append({
            'Name': area_name,
            'BeginRow': area_start_row,
            'EndRow': area_end_row,
        })

    total_row_count = global_row

    # 7e. Scalar metadata
    lines.append(f'\t<templateMode>true</templateMode>')
    lines.append(f'\t<defaultFormatIndex>{default_format_index}</defaultFormatIndex>')
    lines.append(f'\t<height>{total_row_count}</height>')
    lines.append(f'\t<vgRows>{total_row_count}</vgRows>')

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
    for ni in named_items:
        lines.append('\t<namedItem xsi:type="NamedItemCells">')
        lines.append(f'\t\t<name>{ni["Name"]}</name>')
        lines.append('\t\t<area>')
        lines.append('\t\t\t<type>Rows</type>')
        lines.append(f'\t\t\t<beginRow>{ni["BeginRow"]}</beginRow>')
        lines.append(f'\t\t\t<endRow>{ni["EndRow"]}</endRow>')
        lines.append('\t\t\t<beginColumn>-1</beginColumn>')
        lines.append('\t\t\t<endColumn>-1</endColumn>')
        lines.append('\t\t</area>')
        lines.append('\t</namedItem>')

    # 7h. Line palette
    if has_thin_borders:
        lines.append('\t<line width="1" gap="false">')
        lines.append('\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">Solid</v8ui:style>')
        lines.append('\t</line>')
    if has_thick_borders:
        lines.append('\t<line width="2" gap="false">')
        lines.append('\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">Solid</v8ui:style>')
        lines.append('\t</line>')

    # 7i. Font palette
    for fe in font_entries:
        lines.append(f'\t<font faceName="{fe["Face"]}" height="{fe["Size"]}" bold="{fe["Bold"]}" italic="{fe["Italic"]}" underline="{fe["Underline"]}" strikeout="{fe["Strikeout"]}" kind="Absolute" scale="100"/>')

    # 7j. Format palette
    for key in format_order:
        fmt = format_registry[key]
        lines.append('\t<format>')

        if fmt.get('FontIdx') is not None and fmt.get('FontIdx', -1) >= 0:
            lines.append(f'\t\t<font>{fmt["FontIdx"]}</font>')
        if fmt.get('LB') is not None and fmt.get('LB', -1) >= 0:
            lines.append(f'\t\t<leftBorder>{fmt["LB"]}</leftBorder>')
        if fmt.get('TB') is not None and fmt.get('TB', -1) >= 0:
            lines.append(f'\t\t<topBorder>{fmt["TB"]}</topBorder>')
        if fmt.get('RB') is not None and fmt.get('RB', -1) >= 0:
            lines.append(f'\t\t<rightBorder>{fmt["RB"]}</rightBorder>')
        if fmt.get('BB') is not None and fmt.get('BB', -1) >= 0:
            lines.append(f'\t\t<bottomBorder>{fmt["BB"]}</bottomBorder>')
        if fmt.get('Width'):
            lines.append(f'\t\t<width>{fmt["Width"]}</width>')
        if fmt.get('Height'):
            lines.append(f'\t\t<height>{fmt["Height"]}</height>')
        if fmt.get('HA'):
            lines.append(f'\t\t<horizontalAlignment>{fmt["HA"]}</horizontalAlignment>')
        if fmt.get('VA'):
            lines.append(f'\t\t<verticalAlignment>{fmt["VA"]}</verticalAlignment>')
        if fmt.get('Wrap') is True:
            lines.append('\t\t<textPlacement>Wrap</textPlacement>')
        if fmt.get('FillType'):
            lines.append(f'\t\t<fillType>{fmt["FillType"]}</fillType>')
        if fmt.get('NumberFormat'):
            lines.append('\t\t<format>')
            lines.append('\t\t\t<v8:item>')
            lines.append('\t\t\t\t<v8:lang>ru</v8:lang>')
            lines.append(f'\t\t\t\t<v8:content>{esc_xml(fmt["NumberFormat"])}</v8:content>')
            lines.append('\t\t\t</v8:item>')
            lines.append('\t\t</format>')

        lines.append('\t</format>')

    # 7k. Close document
    lines.append('</document>')

    # --- 8. Write output ---
    out_path = args.OutputPath
    if not os.path.isabs(out_path):
        out_path = os.path.join(os.getcwd(), out_path)

    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    content = '\n'.join(lines) + '\n'
    write_utf8_bom(out_path, content)

    # --- 9. Summary ---
    print(f"[OK] Compiled: {args.OutputPath}")
    if defn.get('page'):
        print(f"     Page: {page_name} -> target {target_width}, defaultWidth={default_width}")
    print(f"     Areas: {len(named_items)}, Rows: {total_row_count}, Columns: {total_columns}")
    print(f"     Fonts: {len(font_entries)}, Lines: {line_count}, Formats: {len(format_registry)}")
    print(f"     Merges: {len(merges)}")


if __name__ == '__main__':
    main()
