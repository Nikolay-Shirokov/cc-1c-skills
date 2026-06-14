#!/usr/bin/env python3
# mxl-info v1.0 — Analyze 1C spreadsheet structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import sys
from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# --- Argument parsing ---
parser = argparse.ArgumentParser(description="Analyze 1C spreadsheet (MXL) structure", allow_abbrev=False)
parser.add_argument("-TemplatePath", "-Path", default="", help="Path to Template.xml")
parser.add_argument("-ProcessorName", default="", help="Processor name (used with -TemplateName)")
parser.add_argument("-TemplateName", default="", help="Template name (used with -ProcessorName)")
parser.add_argument("-SrcDir", default="src", help="Source directory (default: src)")
parser.add_argument("-Format", choices=["text", "json"], default="text", help="Output format")
parser.add_argument("-WithText", action="store_true", default=False, help="Include text content")
parser.add_argument("-MaxParams", type=int, default=10, help="Max parameters to show per area")
parser.add_argument("-Limit", type=int, default=150, help="Max lines to show")
parser.add_argument("-Offset", type=int, default=0, help="Lines to skip")
args = parser.parse_args()

# --- Resolve template path ---
template_path = args.TemplatePath

if not template_path:
    if not args.ProcessorName or not args.TemplateName:
        print("Specify -TemplatePath or both -ProcessorName and -TemplateName", file=sys.stderr)
        sys.exit(1)
    template_path = os.path.join(args.SrcDir, args.ProcessorName, "Templates", args.TemplateName, "Ext", "Template.xml")

if not os.path.isabs(template_path):
    template_path = os.path.join(os.getcwd(), template_path)

if not os.path.isfile(template_path):
    print(f"File not found: {template_path}", file=sys.stderr)
    sys.exit(1)

# --- Load XML ---
tree = etree.parse(template_path, etree.XMLParser(remove_blank_text=True))
root = tree.getroot()

NS = {
    "d": "http://v8.1c.ru/8.2/data/spreadsheet",
    "v8": "http://v8.1c.ru/8.1/data/core",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
}

XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"

# --- Column sets ---
column_sets = []
default_col_count = 0

for cols in root.findall("d:columns", NS):
    size_node = cols.find("d:size", NS)
    id_node = cols.find("d:id", NS)
    size = int(size_node.text) if size_node is not None and size_node.text else 0

    if id_node is not None:
        column_sets.append({"Id": id_node.text or "", "Size": size})
    else:
        default_col_count = size

# --- Rows: collect row data ---
row_nodes = root.findall("d:rowsItem", NS)
total_rows = len(row_nodes)

height_node = root.find("d:height", NS)
doc_height = int(height_node.text) if height_node is not None and height_node.text else total_rows

# --- Named items ---
named_areas = []
named_drawings = []

for ni in root.findall("d:namedItem", NS):
    ni_type = ni.get(f"{{{XSI_NS}}}type", "")
    name_node = ni.find("d:name", NS)
    name = name_node.text if name_node is not None else ""

    if "NamedItemCells" in ni_type:
        area = ni.find("d:area", NS)
        area_type_node = area.find("d:type", NS)
        area_type = area_type_node.text if area_type_node is not None else ""
        begin_row = int(area.find("d:beginRow", NS).text)
        end_row = int(area.find("d:endRow", NS).text)
        begin_col = int(area.find("d:beginColumn", NS).text)
        end_col = int(area.find("d:endColumn", NS).text)
        cols_id = None
        cols_id_node = area.find("d:columnsID", NS)
        if cols_id_node is not None:
            cols_id = cols_id_node.text

        named_areas.append({
            "Name": name,
            "AreaType": area_type,
            "BeginRow": begin_row,
            "EndRow": end_row,
            "BeginCol": begin_col,
            "EndCol": end_col,
            "ColumnsID": cols_id,
        })
    elif "NamedItemDrawing" in ni_type:
        draw_id_node = ni.find("d:drawingID", NS)
        draw_id = draw_id_node.text if draw_id_node is not None else ""
        named_drawings.append({"Name": name, "DrawingID": draw_id})

# --- Scan rows for parameters and text ---

# Build row index map: rowIndex -> XmlNode
row_map = {}
for ri in row_nodes:
    idx_node = ri.find("d:index", NS)
    if idx_node is not None and idx_node.text:
        idx = int(idx_node.text)
        row_map[idx] = ri


def get_cell_data(row_node, include_text):
    row = row_node.find("d:row", NS)
    if row is None:
        return []

    results = []
    for c_group in row.findall("d:c", NS):
        cell = c_group.find("d:c", NS)
        if cell is None:
            continue

        param = cell.find("d:parameter", NS)
        detail = cell.find("d:detailParameter", NS)
        tl = cell.find("d:tl", NS)

        if param is not None:
            entry = {"Kind": "Parameter", "Value": param.text or ""}
            if detail is not None:
                entry["Detail"] = detail.text or ""
            results.append(entry)

        if tl is not None:
            content = tl.find("v8:item/v8:content", NS)
            if content is not None and content.text:
                text = content.text
                is_template = bool(re.search(r'\[.+\]', text))

                if is_template:
                    # Extract parameter names from [Param] placeholders
                    # Skip numeric-only like [5]
                    for m in re.finditer(r'\[([^\]]+)\]', text):
                        val = m.group(1)
                        if not re.match(r'^\d+$', val):
                            results.append({"Kind": "TemplateParam", "Value": val})
                    # Full template text only with -WithText
                    if include_text:
                        results.append({"Kind": "Template", "Value": text})
                elif include_text:
                    results.append({"Kind": "Text", "Value": text})

    return results


def get_area_cell_data(area, row_map_ref, include_text):
    params = []
    details = []
    texts = []
    templates = []

    start_row = area["BeginRow"]
    end_row = area["EndRow"]
    if start_row == -1:
        start_row = 0
    if end_row == -1:
        end_row = doc_height - 1

    for r in range(start_row, end_row + 1):
        if r in row_map_ref:
            cells = get_cell_data(row_map_ref[r], include_text)
            for c in cells:
                kind = c["Kind"]
                if kind == "Parameter":
                    params.append(c["Value"])
                    if "Detail" in c:
                        details.append(f"{c['Value']}->{c['Detail']}")
                elif kind == "TemplateParam":
                    params.append(f"{c['Value']} [tpl]")
                elif kind == "Text":
                    texts.append(c["Value"])
                elif kind == "Template":
                    templates.append(c["Value"])

    return {"Params": params, "Details": details, "Texts": texts, "Templates": templates}


# Sort areas by position: Rows by beginRow, Columns by beginCol, Rectangle by beginRow
def area_sort_key(a):
    if a["AreaType"] == "Columns":
        return (a["BeginCol"], a["Name"])
    return (a["BeginRow"], a["Name"])

named_areas.sort(key=area_sort_key)

# Collect data for each area
area_data = []
covered_rows = set()

for area in named_areas:
    data = get_area_cell_data(area, row_map, args.WithText)
    area_data.append({
        "Area": area,
        "Params": data["Params"],
        "Details": data["Details"],
        "Texts": data["Texts"],
        "Templates": data["Templates"],
    })

    # Track covered rows
    sr = area["BeginRow"]
    er = area["EndRow"]
    if sr != -1 and er != -1:
        for r in range(sr, er + 1):
            covered_rows.add(r)

# Find parameters outside named areas
outside_params = []
outside_details = []
outside_texts = []
outside_templates = []

for r in sorted(row_map.keys()):
    if r not in covered_rows:
        cells = get_cell_data(row_map[r], args.WithText)
        for c in cells:
            kind = c["Kind"]
            if kind == "Parameter":
                outside_params.append(c["Value"])
                if "Detail" in c:
                    outside_details.append(f"{c['Value']}->{c['Detail']}")
            elif kind == "TemplateParam":
                outside_params.append(f"{c['Value']} [tpl]")
            elif kind == "Text":
                outside_texts.append(c["Value"])
            elif kind == "Template":
                outside_templates.append(c["Value"])

# --- Counts ---
merge_count = len(root.findall("d:merge", NS))
drawing_nodes = root.findall("d:drawing", NS)
drawing_count = len(drawing_nodes)

# --- Output ---

def truncate_list(items, max_count):
    if len(items) <= max_count:
        return ", ".join(items)
    shown = ", ".join(items[:max_count])
    remaining = len(items) - max_count
    return f"{shown}, ... (+{remaining})"


# Determine template name from path
template_name = os.path.basename(os.path.dirname(os.path.dirname(template_path)))

if args.Format == "json":
    result = {
        "name": template_name,
        "rows": doc_height,
        "columns": default_col_count,
        "columnSets": [{"id": cs["Id"], "size": cs["Size"]} for cs in column_sets],
        "areas": [],
        "outsideParams": list(outside_params),
        "mergeCount": merge_count,
        "drawingCount": drawing_count,
    }

    for ad in area_data:
        area_obj = {
            "name": ad["Area"]["Name"],
            "type": ad["Area"]["AreaType"],
            "beginRow": ad["Area"]["BeginRow"],
            "endRow": ad["Area"]["EndRow"],
            "beginCol": ad["Area"]["BeginCol"],
            "endCol": ad["Area"]["EndCol"],
            "params": list(ad["Params"]),
        }
        if ad["Area"]["ColumnsID"]:
            area_obj["columnsID"] = ad["Area"]["ColumnsID"]
        if args.WithText:
            area_obj["texts"] = list(ad["Texts"])
            area_obj["templates"] = list(ad["Templates"])
        result["areas"].append(area_obj)

    if args.WithText:
        result["outsideTexts"] = list(outside_texts)
        result["outsideTemplates"] = list(outside_templates)

    for nd in named_drawings:
        result["areas"].append({
            "name": nd["Name"],
            "type": "Drawing",
            "drawingID": nd["DrawingID"],
        })

    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0)

# --- Text format output ---
lines = []

lines.append(f"=== {template_name} ===")
lines.append(f"  Rows: {doc_height}, Columns: {default_col_count}")

if len(column_sets) == 0:
    lines.append("  Column sets: 1 (default only)")
else:
    lines.append(f"  Column sets: {len(column_sets) + 1} (default={default_col_count} cols + {len(column_sets)} additional)")
    for cs in column_sets:
        lines.append(f"    {cs['Id'][:8]}...: {cs['Size']} cols")

lines.append("")
lines.append("--- Named areas ---")

for ad in area_data:
    a = ad["Area"]
    param_count = len(ad["Params"])
    row_range = ""

    if a["AreaType"] == "Rows":
        row_range = f"rows {a['BeginRow']}-{a['EndRow']}"
    elif a["AreaType"] == "Columns":
        row_range = f"cols {a['BeginCol']}-{a['EndCol']}"
    elif a["AreaType"] == "Rectangle":
        row_range = f"rows {a['BeginRow']}-{a['EndRow']}, cols {a['BeginCol']}-{a['EndCol']}"

    cols_info = ""
    if a["ColumnsID"]:
        cs_size = ""
        for cs in column_sets:
            if cs["Id"] == a["ColumnsID"]:
                cs_size = f" {cs['Size']}cols"
                break
        cols_info = f" [colset{cs_size}]"

    param_info = f"({param_count} params)"
    name_str = a["Name"].ljust(25)
    type_str = a["AreaType"].ljust(12)
    lines.append(f"  {name_str} {type_str} {row_range}  {param_info}{cols_info}")

for nd in named_drawings:
    name_str = nd["Name"].ljust(25)
    lines.append(f"  {name_str} Drawing      drawingID={nd['DrawingID']}")

# Detect intersection pairs (Rows + Columns areas that overlap)
rows_areas = [ad for ad in area_data if ad["Area"]["AreaType"] == "Rows"]
cols_areas = [ad for ad in area_data if ad["Area"]["AreaType"] == "Columns"]
intersections = []
if rows_areas and cols_areas:
    for ra in rows_areas:
        for ca in cols_areas:
            intersections.append(f"{ra['Area']['Name']}|{ca['Area']['Name']}")

if intersections:
    lines.append("")
    lines.append("--- Intersections (use with GetArea) ---")
    for pair in intersections:
        lines.append(f"  {pair}")

# Parameters by area
has_params = any(len(ad["Params"]) > 0 for ad in area_data) or len(outside_params) > 0

if has_params:
    lines.append("")
    lines.append("--- Parameters by area ---")
    for ad in area_data:
        if len(ad["Params"]) > 0:
            param_str = truncate_list(ad["Params"], args.MaxParams)
            lines.append(f"  {ad['Area']['Name']}: {param_str}")
            # Show detailParameters if any
            if len(ad["Details"]) > 0:
                detail_str = truncate_list(ad["Details"], args.MaxParams)
                lines.append(f"    detail: {detail_str}")
    if len(outside_params) > 0:
        param_str = truncate_list(outside_params, args.MaxParams)
        lines.append(f"  (outside areas): {param_str}")
        if len(outside_details) > 0:
            detail_str = truncate_list(outside_details, args.MaxParams)
            lines.append(f"    detail: {detail_str}")

# WithText sections
if args.WithText:
    has_text = any(len(ad["Texts"]) > 0 or len(ad["Templates"]) > 0 for ad in area_data) or len(outside_texts) > 0 or len(outside_templates) > 0

    if has_text:
        lines.append("")
        lines.append("--- Text content ---")
        for ad in area_data:
            if len(ad["Texts"]) > 0 or len(ad["Templates"]) > 0:
                lines.append(f"  {ad['Area']['Name']}:")
                if len(ad["Texts"]) > 0:
                    text_items = [f'"{t}"' for t in ad["Texts"]]
                    text_str = truncate_list(text_items, args.MaxParams)
                    lines.append(f"    Text: {text_str}")
                if len(ad["Templates"]) > 0:
                    tpl_items = [f'"{t}"' for t in ad["Templates"]]
                    tpl_str = truncate_list(tpl_items, args.MaxParams)
                    lines.append(f"    Templates: {tpl_str}")
        if len(outside_texts) > 0 or len(outside_templates) > 0:
            lines.append("  (outside areas):")
            if len(outside_texts) > 0:
                text_items = [f'"{t}"' for t in outside_texts]
                text_str = truncate_list(text_items, args.MaxParams)
                lines.append(f"    Text: {text_str}")
            if len(outside_templates) > 0:
                tpl_items = [f'"{t}"' for t in outside_templates]
                tpl_str = truncate_list(tpl_items, args.MaxParams)
                lines.append(f"    Templates: {tpl_str}")

lines.append("")
lines.append("--- Stats ---")
lines.append(f"  Merges: {merge_count}")
lines.append(f"  Drawings: {drawing_count}")

# --- Truncation protection ---
total_lines = len(lines)

if args.Offset > 0:
    if args.Offset >= total_lines:
        print(f"[INFO] Offset {args.Offset} exceeds total lines ({total_lines}). Nothing to show.")
        sys.exit(0)
    lines = lines[args.Offset:]

if len(lines) > args.Limit:
    shown = lines[:args.Limit]
    for l in shown:
        print(l)
    remaining = total_lines - args.Offset - args.Limit
    print("")
    print(f"[TRUNCATED] Shown {args.Limit} of {total_lines} lines. Use -Offset {args.Offset + args.Limit} to continue.")
else:
    for l in lines:
        print(l)
