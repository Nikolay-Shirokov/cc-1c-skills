#!/usr/bin/env python3
# mxl-decompile v1.0 — Decompile 1C spreadsheet to JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import sys
from collections import OrderedDict
from lxml import etree

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


def int_of(node, default=0):
    if node is not None and node.text:
        return int(node.text)
    return default


# --- Main ---

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Decompile 1C spreadsheet to JSON", allow_abbrev=False)
    parser.add_argument("-TemplatePath", "-Path", required=True, help="Path to Template.xml")
    parser.add_argument("-OutputPath", default=None, help="Output JSON path (stdout if omitted)")
    args = parser.parse_args()

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
            "Face": f_node.get("faceName", ""),
            "Size": int(f_node.get("height", "0")),
            "Bold": f_node.get("bold") == "true",
            "Italic": f_node.get("italic") == "true",
            "Underline": f_node.get("underline") == "true",
            "Strikeout": f_node.get("strikeout") == "true",
        })

    # --- 3. Extract line palette ---

    raw_lines = []
    for l_node in findall(root, "d:line"):
        raw_lines.append({"Width": int(l_node.get("width", "0"))})

    # --- 4. Extract format palette ---

    raw_formats = []
    for fmt_node in findall(root, "d:format"):
        fmt = {
            "FontIdx": -1,
            "LB": -1, "TB": -1, "RB": -1, "BB": -1,
            "Width": 0, "Height": 0,
            "HA": "", "VA": "",
            "Wrap": False, "FillType": "", "DataFormat": "",
        }

        n = find(fmt_node, "d:font")
        if n is not None and n.text:
            fmt["FontIdx"] = int(n.text)
        n = find(fmt_node, "d:leftBorder")
        if n is not None and n.text:
            fmt["LB"] = int(n.text)
        n = find(fmt_node, "d:topBorder")
        if n is not None and n.text:
            fmt["TB"] = int(n.text)
        n = find(fmt_node, "d:rightBorder")
        if n is not None and n.text:
            fmt["RB"] = int(n.text)
        n = find(fmt_node, "d:bottomBorder")
        if n is not None and n.text:
            fmt["BB"] = int(n.text)

        n = find(fmt_node, "d:width")
        if n is not None and n.text:
            fmt["Width"] = int(n.text)
        n = find(fmt_node, "d:height")
        if n is not None and n.text:
            fmt["Height"] = int(n.text)

        n = find(fmt_node, "d:horizontalAlignment")
        if n is not None and n.text:
            fmt["HA"] = n.text
        n = find(fmt_node, "d:verticalAlignment")
        if n is not None and n.text:
            fmt["VA"] = n.text

        n = find(fmt_node, "d:textPlacement")
        if n is not None and n.text == "Wrap":
            fmt["Wrap"] = True

        n = find(fmt_node, "d:fillType")
        if n is not None and n.text:
            fmt["FillType"] = n.text

        n = find(fmt_node, "d:format/v8:item/v8:content")
        if n is not None and n.text:
            fmt["DataFormat"] = n.text

        raw_formats.append(fmt)

    def get_format(idx):
        if idx <= 0 or idx > len(raw_formats):
            return None
        return raw_formats[idx - 1]

    # --- 5. Extract columns and default width ---

    col_node = find(root, "d:columns")
    total_columns = int_of(find(col_node, "d:size"))

    col_format_indices = {}
    for ci in findall(col_node, "d:columnsItem"):
        col_idx = int_of(find(ci, "d:index"))
        fmt_idx = int_of(find(ci, "d:column/d:formatIndex"))
        col_format_indices[col_idx] = fmt_idx

    default_fmt_idx = 0
    n = find(root, "d:defaultFormatIndex")
    if n is not None and n.text:
        default_fmt_idx = int(n.text)

    default_width = 10
    if default_fmt_idx > 0:
        def_fmt = get_format(default_fmt_idx)
        if def_fmt and def_fmt["Width"] > 0:
            default_width = def_fmt["Width"]

    # Build column width map (1-based col -> width), only non-default
    col_width_map = OrderedDict()
    for col0 in sorted(col_format_indices.keys()):
        fmt = get_format(col_format_indices[col0])
        if fmt and fmt["Width"] > 0 and fmt["Width"] != default_width:
            col1 = str(col0 + 1)
            col_width_map[col1] = fmt["Width"]

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

    named_areas = []
    for ni_node in findall(root, "d:namedItem"):
        xsi_type = ni_node.get(f"{{{XSI_NS}}}type", "")
        if xsi_type != "NamedItemCells":
            continue

        area_node = find(ni_node, "d:area")
        area_type_node = find(area_node, "d:type")
        area_type = text_of(area_type_node) or ""
        if area_type != "Rows":
            continue

        named_areas.append({
            "Name": text_of(find(ni_node, "d:name")) or "",
            "BeginRow": int_of(find(area_node, "d:beginRow")),
            "EndRow": int_of(find(area_node, "d:endRow")),
        })

    # --- 8. Extract rows ---

    row_data = {}
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

                text = None
                t_node = find(c_content, "d:tl/v8:item/v8:content")
                if t_node is not None and t_node.text:
                    text = t_node.text

                cells.append({
                    "Col": col,
                    "FormatIdx": cell_fmt_idx,
                    "Param": param,
                    "Detail": detail,
                    "Text": text,
                })

        for r in range(row_idx, index_to + 1):
            row_data[r] = {
                "FormatIdx": row_fmt_idx,
                "Cells": cells,
                "Empty": is_empty,
            }

    # --- 9. Build style key (ignoring fillType) ---

    def get_border_desc(fmt):
        if not fmt:
            return {"Border": "none", "Thick": False}

        lb = fmt["LB"] >= 0
        tb = fmt["TB"] >= 0
        rb = fmt["RB"] >= 0
        bb = fmt["BB"] >= 0

        if not lb and not tb and not rb and not bb:
            return {"Border": "none", "Thick": False}

        thick = False
        for b_idx in [fmt["LB"], fmt["TB"], fmt["RB"], fmt["BB"]]:
            if b_idx >= 0 and b_idx < len(raw_lines) and raw_lines[b_idx]["Width"] >= 2:
                thick = True
                break

        if lb and tb and rb and bb:
            return {"Border": "all", "Thick": thick}

        sides = []
        if tb:
            sides.append("top")
        if bb:
            sides.append("bottom")
        if lb:
            sides.append("left")
        if rb:
            sides.append("right")

        return {"Border": ",".join(sides), "Thick": thick}

    def get_style_key(fmt):
        if not fmt:
            return "empty"
        fi = fmt["FontIdx"] if fmt["FontIdx"] >= 0 else 0
        bd = get_border_desc(fmt)
        return f"f={fi}|b={bd['Border']}|bw={bd['Thick']}|ha={fmt['HA']}|va={fmt['VA']}|wr={fmt['Wrap']}|df={fmt['DataFormat']}"

    # --- 10. Name fonts ---

    font_names = {}
    font_defs = OrderedDict()

    if len(raw_fonts) > 0:
        font_names[0] = "default"
        font_defs["default"] = raw_fonts[0]

    def get_font_key(f):
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

        if f["Face"] == df["Face"] and f["Size"] == df["Size"]:
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

    def name_style(fmt):
        if not fmt:
            return "default"
        parts = []

        fi = fmt["FontIdx"] if fmt["FontIdx"] >= 0 else 0
        if fi in font_names and font_names[fi] != "default":
            parts.append(font_names[fi])

        bd = get_border_desc(fmt)
        if bd["Border"] != "none":
            if bd["Border"] == "all":
                parts.append("bordered")
            else:
                parts.append(f"border-{bd['Border']}")

        if fmt["HA"] == "Center":
            parts.append("center")
        elif fmt["HA"] == "Right":
            parts.append("right")
        if fmt["VA"] == "Center":
            parts.append("vcenter")
        elif fmt["VA"] == "Top":
            parts.append("vtop")
        if fmt["Wrap"]:
            parts.append("wrap")
        if fmt["DataFormat"]:
            parts.append("fmt")

        if len(parts) == 0:
            return "default"
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
        fi = fmt["FontIdx"] if fmt["FontIdx"] >= 0 else 0
        if fi in font_names and font_names[fi] != "default":
            s_def["font"] = font_names[fi]
        if fmt["HA"]:
            a_map = {"Left": "left", "Center": "center", "Right": "right"}
            a = a_map.get(fmt["HA"])
            if a:
                s_def["align"] = a
        if fmt["VA"]:
            va_map = {"Top": "top", "Center": "center"}
            a = va_map.get(fmt["VA"])
            if a:
                s_def["valign"] = a
        bd = get_border_desc(fmt)
        if bd["Border"] != "none":
            s_def["border"] = bd["Border"]
            if bd["Thick"]:
                s_def["borderWidth"] = "thick"
        if fmt["Wrap"]:
            s_def["wrap"] = True
        if fmt["DataFormat"]:
            s_def["format"] = fmt["DataFormat"]

        style_defs[name] = s_def

    def get_style_name(fmt_idx):
        key = format_to_style_key.get(fmt_idx)
        if key and key in style_names:
            return style_names[key]
        return "default"

    # --- 12. Build areas ---

    dsl_areas = []

    for area in named_areas:
        area_rows = []

        for global_row in range(area["BeginRow"], area["EndRow"] + 1):
            rd = row_data.get(global_row)

            if not rd or rd["Empty"]:
                area_rows.append(OrderedDict())
                continue

            dsl_row = OrderedDict()

            # Row height
            if rd["FormatIdx"] > 0:
                row_fmt = get_format(rd["FormatIdx"])
                if row_fmt and row_fmt["Height"] > 0:
                    dsl_row["height"] = row_fmt["Height"]

            # Separate content cells from gap-fill cells
            content_cells = []
            gap_cells = []

            for cell in rd["Cells"]:
                has_content = cell["Param"] or cell["Text"]
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

            if row_style_name and row_style_name != "default":
                dsl_row["rowStyle"] = row_style_name

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
                    sn = get_style_name(cell["FormatIdx"])
                    if sn != "default" or not row_style_name:
                        dsl_cell["style"] = sn

                # Content
                fill_type = cell_fmt["FillType"] if cell_fmt else ""

                if cell["Param"]:
                    dsl_cell["param"] = cell["Param"]
                    if cell["Detail"]:
                        dsl_cell["detail"] = cell["Detail"]
                elif fill_type == "Template" and cell["Text"]:
                    dsl_cell["template"] = cell["Text"]
                elif cell["Text"]:
                    dsl_cell["text"] = cell["Text"]

                dsl_cells.append(dsl_cell)

            if len(dsl_cells) > 0:
                dsl_row["cells"] = dsl_cells
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

        dsl_areas.append(OrderedDict([
            ("name", area["Name"]),
            ("rows", compressed_rows),
        ]))

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

    # Remove empty "default" style
    if "default" in style_defs and len(style_defs["default"]) == 0:
        del style_defs["default"]

    # Remove unused styles
    used_styles = set()
    for a in dsl_areas:
        for r in a["rows"]:
            if "rowStyle" in r:
                used_styles.add(r["rowStyle"])
            if "cells" in r:
                for c in r["cells"]:
                    if "style" in c:
                        used_styles.add(c["style"])
    to_remove = [s for s in style_defs if s not in used_styles]
    for s in to_remove:
        del style_defs[s]

    result["fonts"] = fonts_out
    result["styles"] = style_defs
    result["areas"] = dsl_areas

    # --- 16. Convert to JSON ---

    json_str = json.dumps(result, ensure_ascii=False, indent=2)

    # --- 17. Output ---

    if output_path:
        abs_path = os.path.join(os.getcwd(), output_path) if not os.path.isabs(output_path) else output_path
        with open(abs_path, "w", encoding="utf-8") as fh:
            fh.write(json_str)
        print(f"[OK] Decompiled: {output_path}")
    else:
        print(json_str)

    print(f"     Areas: {len(named_areas)}, Rows: {len(row_data)}, Columns: {total_columns}", file=sys.stderr)
    print(f"     Fonts: {len(font_defs)}, Styles: {len(style_defs)}, Merges: {len(merge_map)}", file=sys.stderr)


if __name__ == "__main__":
    main()
