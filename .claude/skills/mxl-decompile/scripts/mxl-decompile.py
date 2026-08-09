#!/usr/bin/env python3
# mxl-decompile v1.2 — Decompile 1C spreadsheet to JSON (+плоский режим, области всех типов, поля ввода)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
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
D_NS = "http://v8.1c.ru/8.2/data/spreadsheet"


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


# Font height can be fractional (8.3, 6.8) and is always written with a dot,
# so it must be parsed and formatted culture-independently
def convert_to_number(s, fallback=0):
    if s is None or str(s).strip() == "":
        return fallback
    try:
        value = float(s)
    except ValueError:
        return fallback
    # Keep whole numbers as integers so the DSL stays readable
    if value == int(value):
        return int(value)
    return value


def num_str(value):
    """Invariant text form of a number: 10 -> "10", 8.3 -> "8.3"."""
    if float(value) == int(value):
        return str(int(value))
    return repr(float(value))


# Namespaces live on the document element, a fragment must not repeat them
def strip_xmlns(xml):
    return re.sub(r'\s+xmlns(:[A-Za-z0-9_]+)?="[^"]*"', '', xml)


def local_name(node):
    tag = node.tag
    if not isinstance(tag, str):
        return None
    return tag.split("}")[-1]


def outer_xml(node):
    return strip_xmlns(etree.tostring(node, encoding="unicode"))


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

    parser_xml = etree.XMLParser(remove_blank_text=True)
    tree = etree.parse(template_path, parser_xml)
    root = tree.getroot()

    root_ns = root.tag.split("}")[0].lstrip("{") if "}" in root.tag else ""
    if root_ns != D_NS:
        print(f"Not a spreadsheet template: root <{local_name(root)}> in namespace '{root_ns}'. "
              f"Expected a Template.xml of a spreadsheet document.", file=sys.stderr)
        sys.exit(1)

    # --- 1a. Language settings ---

    lang_settings = None
    ls_node = find(root, "d:languageSettings")
    if ls_node is not None:
        cur = find(ls_node, "d:currentLanguage")
        dflt = find(ls_node, "d:defaultLanguage")
        lst = []
        for li in findall(ls_node, "d:languageInfo"):
            item = OrderedDict()
            for f in ("id", "code", "description"):
                n = find(li, f"d:{f}")
                if n is not None:
                    item[f] = n.text or ""
            lst.append(item)
        lang_settings = OrderedDict()
        if cur is not None:
            lang_settings["current"] = cur.text or ""
        if dflt is not None:
            lang_settings["default"] = dflt.text or ""
        if lst:
            lang_settings["list"] = lst

    # Main language of the template, detected from the cell texts themselves:
    # currentLanguage is not reliable (templates carry texts under another language,
    # and some have no languageSettings at all)
    lang_counts = {}
    for item in root.findall("d:rowsItem//d:tl/v8:item", NSMAP):
        l_node = find(item, "v8:lang")
        if l_node is None:
            continue
        l = l_node.text or ""
        lang_counts[l] = lang_counts.get(l, 0) + 1

    text_lang = None
    best_count = 0
    for l in sorted(lang_counts):
        if lang_counts[l] > best_count:
            text_lang = l
            best_count = lang_counts[l]
    if not text_lang:
        # No texts at all — fall back to what the template declares
        text_lang = lang_settings["current"] if (lang_settings and lang_settings.get("current")) else "ru"

    # --- 2. Extract font palette ---

    raw_fonts = []
    for f_node in findall(root, "d:font"):
        # A system font (`ref` + kind="WindowsFont") carries almost no attributes and
        # follows the OS settings — inventing a size for it changes how it looks
        height_attr = f_node.get("height")
        raw_fonts.append({
            "Face": f_node.get("faceName", ""),
            "Size": convert_to_number(height_attr),
            "HasSize": height_attr is not None and height_attr != "",
            "Bold": f_node.get("bold") == "true",
            "Italic": f_node.get("italic") == "true",
            "Underline": f_node.get("underline") == "true",
            "Strikeout": f_node.get("strikeout") == "true",
            "Ref": f_node.get("ref", ""),
            "Kind": f_node.get("kind", ""),
            # Which style attributes the element actually carried — a system font may
            # spell out bold="false", and dropping it changes the element
            "HasStyleAttrs": f_node.get("bold") is not None and f_node.get("bold") != "",
        })

    # --- 3. Extract line palette ---

    raw_lines = []
    for l_node in findall(root, "d:line"):
        style = "Solid"
        s_node = find(l_node, "v8ui:style")
        if s_node is not None and s_node.text:
            style = s_node.text
        raw_lines.append({"Width": convert_to_number(l_node.get("width")), "Style": style})

    # A border index pointing at a line with style None means "no border"
    def test_line_visible(idx):
        if idx < 0:
            return False
        if idx >= len(raw_lines):
            return True
        return raw_lines[idx]["Style"] != "None"

    # --- 3a. Input cell control types ---

    # Platform GUIDs of cell control types (constants, same in every configuration)
    control_type_names = {
        "381ed624-9217-4e63-85db-c4c3cb87daae": "field",     # input field
        "35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26": "checkbox",  # checkbox
    }

    # valueType XML -> compact DSL object
    def convert_from_value_type_node(vt_node):
        if vt_node is None:
            return None
        t_node = find(vt_node, "v8:Type")
        if t_node is None:
            return None
        xs_type = t_node.text or ""

        out = OrderedDict()

        if xs_type == "xs:decimal":
            out["type"] = "number"
            q = find(vt_node, "v8:NumberQualifiers")
            if q is not None:
                n = find(q, "v8:Digits")
                if n is not None:
                    out["digits"] = int(n.text)
                n = find(q, "v8:FractionDigits")
                if n is not None:
                    out["fractionDigits"] = int(n.text)
                n = find(q, "v8:AllowedSign")
                if n is not None and n.text != "Any":
                    out["allowedSign"] = n.text
        elif xs_type == "xs:string":
            out["type"] = "string"
            q = find(vt_node, "v8:StringQualifiers")
            if q is not None:
                n = find(q, "v8:Length")
                if n is not None:
                    out["length"] = int(n.text)
                n = find(q, "v8:AllowedLength")
                if n is not None and n.text != "Variable":
                    out["allowedLength"] = n.text
        elif xs_type == "xs:boolean":
            out["type"] = "boolean"
        else:
            # xs:dateTime and anything else date-like
            out["type"] = "date"
            q = find(vt_node, "v8:DateQualifiers")
            if q is not None:
                n = find(q, "v8:DateFractions")
                if n is not None and n.text != "Date":
                    out["dateFractions"] = n.text
            if xs_type != "xs:dateTime":
                out["xsType"] = xs_type

        return out

    # --- 4. Extract format palette ---

    # Format children the DSL models itself; the rest is carried over verbatim
    modelled_format_children = {
        "font", "leftBorder", "topBorder", "rightBorder", "bottomBorder", "border",
        "width", "height", "horizontalAlignment", "verticalAlignment", "textPlacement",
        "fillType", "format", "textColor", "borderColor", "hidden", "indent",
        "containsValue", "valueType", "controlType",
    }

    raw_formats = []
    for fmt_node in findall(root, "d:format"):
        fmt = {
            "FontIdx": -1,
            "LB": -1, "TB": -1, "RB": -1, "BB": -1,
            "Width": 0, "Height": 0, "HasWidth": False, "HasHeight": False,
            "HA": "", "VA": "",
            # Wrap holds textPlacement: Wrap, Auto or Cut
            "Wrap": "", "FillType": "", "DataFormat": "",
            "DataFormatByLang": None,
            "TextColor": "", "BorderColor": "", "Hidden": "", "Indent": 0, "HasIndent": False,
            "ContainsValue": False, "ControlType": "", "ValueType": None,
        }

        n = find(fmt_node, "d:font")
        if n is not None:
            fmt["FontIdx"] = int(n.text)
        n = find(fmt_node, "d:leftBorder")
        if n is not None:
            fmt["LB"] = int(n.text)
        n = find(fmt_node, "d:topBorder")
        if n is not None:
            fmt["TB"] = int(n.text)
        n = find(fmt_node, "d:rightBorder")
        if n is not None:
            fmt["RB"] = int(n.text)
        n = find(fmt_node, "d:bottomBorder")
        if n is not None:
            fmt["BB"] = int(n.text)

        # <border> sets all four sides at once. The platform uses either this form or
        # the per-side one, never both — and never spells out four equal sides.
        n = find(fmt_node, "d:border")
        if n is not None:
            all_sides = int(n.text)
            fmt["LB"] = all_sides
            fmt["TB"] = all_sides
            fmt["RB"] = all_sides
            fmt["BB"] = all_sides

        # 0 is a real value here, so presence is tracked separately
        n = find(fmt_node, "d:width")
        if n is not None:
            fmt["Width"] = int(n.text)
            fmt["HasWidth"] = True
        n = find(fmt_node, "d:height")
        if n is not None:
            fmt["Height"] = int(n.text)
            fmt["HasHeight"] = True

        n = find(fmt_node, "d:horizontalAlignment")
        if n is not None:
            fmt["HA"] = n.text or ""
        n = find(fmt_node, "d:verticalAlignment")
        if n is not None:
            fmt["VA"] = n.text or ""

        n = find(fmt_node, "d:textPlacement")
        if n is not None:
            fmt["Wrap"] = n.text or ""

        n = find(fmt_node, "d:fillType")
        if n is not None:
            fmt["FillType"] = n.text or ""

        # Number format is multilingual just like cell text
        df_items = findall(fmt_node, "d:format/v8:item")
        if len(df_items) == 1:
            c_n = find(df_items[0], "v8:content")
            l_n = find(df_items[0], "v8:lang")
            if c_n is not None:
                fmt["DataFormat"] = c_n.text or ""
            if l_n is not None and (l_n.text or "") != text_lang:
                fmt["DataFormatByLang"] = OrderedDict({l_n.text: fmt["DataFormat"]})
        elif len(df_items) > 1:
            fmt["DataFormatByLang"] = OrderedDict()
            for it in df_items:
                c_n = find(it, "v8:content")
                l_n = find(it, "v8:lang")
                if c_n is None or l_n is None:
                    continue
                fmt["DataFormatByLang"][l_n.text] = c_n.text or ""
                if not fmt["DataFormat"]:
                    fmt["DataFormat"] = c_n.text or ""

        n = find(fmt_node, "d:textColor")
        if n is not None:
            fmt["TextColor"] = n.text or ""
        n = find(fmt_node, "d:borderColor")
        if n is not None:
            fmt["BorderColor"] = n.text or ""
        # Templates spell out hidden=false too; dropping it changes the format
        n = find(fmt_node, "d:hidden")
        if n is not None:
            fmt["Hidden"] = n.text or ""
        # indent=0 is spelled out in templates, so presence is tracked separately
        n = find(fmt_node, "d:indent")
        if n is not None:
            fmt["Indent"] = int(n.text)
            fmt["HasIndent"] = True

        # Input cell (containsValue + valueType + controlType)
        n = find(fmt_node, "d:containsValue")
        if n is not None and (n.text or "") == "true":
            fmt["ContainsValue"] = True
        n = find(fmt_node, "d:controlType")
        if n is not None:
            fmt["ControlType"] = n.text or ""
        vt_node = find(fmt_node, "d:valueType")
        if vt_node is not None:
            fmt["ValueType"] = convert_from_value_type_node(vt_node)

        # Everything the DSL does not model — carried over verbatim, in the order the
        # platform wrote it. Without this the property is silently dropped.
        extra = []
        order = []
        for ch in fmt_node:
            nm = local_name(ch)
            if nm is None:
                continue
            order.append(nm)
            # An empty <format> holds no number format to model — keep it as is
            if nm == "format" and len(df_items) == 0:
                extra.append(OrderedDict({"name": nm, "xml": outer_xml(ch)}))
                continue
            if nm in modelled_format_children:
                continue
            extra.append(OrderedDict({"name": nm, "xml": outer_xml(ch)}))
        fmt["Extra"] = extra
        fmt["Order"] = order

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

    # Extra column sets (a second <columns> with its own id, referenced by rows via
    # <columnsID>) are not describable in the DSL. Say so instead of quietly mixing
    # their geometry into the default set.
    column_set_count = len(findall(root, "d:columns"))
    if column_set_count > 1:
        print(f"WARNING: Template has {column_set_count} column sets; the DSL describes only "
              f"the default one. Rows bound to another set will come out with the default geometry.",
              file=sys.stderr)

    # <size> is not always trustworthy: templates ship with size=0 or with a size
    # smaller than the columns their cells actually use. Widen to what is used —
    # but only with one column set, otherwise cells belong to different geometries.
    max_col = -1
    for k in col_format_indices:
        if k > max_col:
            max_col = k
    if column_set_count <= 1:
        for ri in findall(root, "d:rowsItem"):
            row_node = find(ri, "d:row")
            if row_node is None:
                continue
            c = -1
            for c_group in findall(row_node, "d:c"):
                i_node = find(c_group, "d:i")
                if i_node is not None:
                    c = int(i_node.text)
                else:
                    c += 1
                if c > max_col:
                    max_col = c
    # Merges are deliberately left out: stock templates do extend a merge past the
    # last column, and widening the document for that would change its geometry
    if (max_col + 1) > total_columns:
        total_columns = max_col + 1
    if total_columns < 1:
        total_columns = 1

    default_fmt_idx = int_of(find(root, "d:defaultFormatIndex"))

    # 0 means the template declares no default width and every column without an
    # explicit one takes the platform's own. Inventing a number here shrinks those
    # columns — do not guess.
    default_width = 0
    if default_fmt_idx > 0:
        def_fmt = get_format(default_fmt_idx)
        if def_fmt and def_fmt["Width"] > 0:
            default_width = def_fmt["Width"]

    # Build column width map (1-based col → width), only non-default
    col_width_map = OrderedDict()
    for col0 in sorted(col_format_indices):
        fmt = get_format(col_format_indices[col0])
        if fmt and fmt["Width"] > 0 and fmt["Width"] != default_width:
            col_width_map[str(col0 + 1)] = fmt["Width"]

    # --- 5a. Document height ---

    # Needed before merges: a merge pointing past the last row belongs to no cell
    doc_height = 0
    declared_height = 0
    h_node = find(root, "d:height")
    if h_node is not None:
        doc_height = int(h_node.text)
        declared_height = doc_height
    for ri in findall(root, "d:rowsItem"):
        idx_node = find(ri, "d:index")
        if idx_node is None:
            continue
        # Rows past <height> matter only when they actually carry something:
        # templates often keep empty rowsItem entries beyond the declared height
        row_node = find(ri, "d:row")
        if row_node is None or find(row_node, "d:c") is None:
            continue
        last = int(idx_node.text)
        it_node = find(ri, "d:indexTo")
        if it_node is not None:
            last = int(it_node.text)
        if (last + 1) > doc_height:
            doc_height = last + 1

    # --- 6. Extract merges ---

    merge_map = {}
    merge_cols_by_row = {}
    extra_merges = []
    for m_node in findall(root, "d:merge"):
        r = int_of(find(m_node, "d:r"))
        c = int_of(find(m_node, "d:c"))
        w = int_of(find(m_node, "d:w"))
        h = int_of(find(m_node, "d:h"))

        # -1 means "all rows" / "all columns", and a row past the end of the document
        # has no cell either — such merges are carried over verbatim
        if r < 0 or c < 0 or r >= doc_height:
            extra_merges.append(OrderedDict({"r": r, "c": c, "w": w, "h": h}))
            continue

        merge_map[f"{r},{c}"] = {"W": w, "H": h}
        merge_cols_by_row.setdefault(r, []).append(c)

    # --- 7. Extract named items ---

    named_areas = []
    for ni_node in findall(root, "d:namedItem"):
        xsi_type = ni_node.get(f"{{{XSI_NS}}}type", "")
        if xsi_type != "NamedItemCells":
            continue

        area_node = find(ni_node, "d:area")
        named_areas.append({
            "Name": text_of(find(ni_node, "d:name")) or "",
            "Type": text_of(find(area_node, "d:type")) or "",
            "BeginRow": int_of(find(area_node, "d:beginRow")),
            "EndRow": int_of(find(area_node, "d:endRow")),
            "BeginCol": int_of(find(area_node, "d:beginColumn")),
            "EndCol": int_of(find(area_node, "d:endColumn")),
        })

    # Block mode (areas = sequence of row blocks) describes the document without loss
    # only when every area is a Rows area, no two of them overlap, and together they
    # cover every row. Otherwise fall back to flat mode: whole grid in "rows" plus
    # coordinates in "namedAreas".
    row_areas = [a for a in named_areas if a["Type"] == "Rows"]
    flat_mode = len(row_areas) != len(named_areas)

    # Degenerate ranges (empty or inverted) cannot be expressed as a block
    if not flat_mode:
        for a in row_areas:
            if a["BeginRow"] < 0 or a["EndRow"] < a["BeginRow"]:
                flat_mode = True
                break

    if not flat_mode:
        for i in range(len(row_areas)):
            if flat_mode:
                break
            for j in range(i + 1, len(row_areas)):
                if (row_areas[i]["BeginRow"] <= row_areas[j]["EndRow"]
                        and row_areas[j]["BeginRow"] <= row_areas[i]["EndRow"]):
                    flat_mode = True
                    break

    if not flat_mode and doc_height > 0:
        covered = set()
        for a in row_areas:
            for r in range(a["BeginRow"], a["EndRow"] + 1):
                covered.add(r)
        for r in range(doc_height):
            if r not in covered:
                flat_mode = True
                break

    # --- 8. Extract rows ---

    # Cell children the DSL models itself; the rest is carried over verbatim
    modelled_cell_children = {"f", "parameter", "detailParameter", "tl"}

    row_data = {}
    for ri_node in findall(root, "d:rowsItem"):
        row_idx = int_of(find(ri_node, "d:index"))
        row_node = find(ri_node, "d:row")

        index_to = row_idx
        it_node = find(ri_node, "d:indexTo")
        if it_node is not None:
            index_to = int(it_node.text)

        row_fmt_idx = int_of(find(row_node, "d:formatIndex")) if row_node is not None else 0

        is_empty = False
        if row_node is not None:
            empty_node = find(row_node, "d:empty")
            if empty_node is not None and (empty_node.text or "") == "true":
                is_empty = True

        cells = []
        if not is_empty and row_node is not None:
            col = -1
            for c_group in findall(row_node, "d:c"):
                i_node = find(c_group, "d:i")
                if i_node is not None:
                    col = int(i_node.text)
                else:
                    col += 1

                c_content = find(c_group, "d:c")
                if c_content is None:
                    continue

                cell_fmt_idx = int_of(find(c_content, "d:f"))
                param = text_of(find(c_content, "d:parameter"))
                detail = text_of(find(c_content, "d:detailParameter"))

                # Cell text can carry several languages; keep the plain string form
                # when there is only the document language
                text = None
                text_by_lang = None
                tl_items = findall(c_content, "d:tl/v8:item")
                if len(tl_items) == 1:
                    c_n = find(tl_items[0], "v8:content")
                    l_n = find(tl_items[0], "v8:lang")
                    if c_n is not None:
                        text = c_n.text or ""
                    if l_n is not None and (l_n.text or "") != text_lang:
                        text_by_lang = OrderedDict({l_n.text: text})
                elif len(tl_items) > 1:
                    text_by_lang = OrderedDict()
                    for it in tl_items:
                        c_n = find(it, "v8:content")
                        l_n = find(it, "v8:lang")
                        if c_n is None or l_n is None:
                            continue
                        text_by_lang[l_n.text] = c_n.text or ""
                        if not text:
                            text = c_n.text or ""

                # Everything else the cell carries — value, control, note and the like.
                # Kept verbatim so nothing is silently dropped.
                extra = []
                for ch in c_content:
                    nm = local_name(ch)
                    if nm is None:
                        continue
                    # An empty <tl> holds no text to model — carry it over as is
                    if nm == "tl" and len(tl_items) > 0:
                        continue
                    if nm != "tl" and nm in modelled_cell_children:
                        continue
                    extra.append(OrderedDict({"name": nm, "xml": outer_xml(ch)}))

                cells.append({
                    "Col": col,
                    "FormatIdx": cell_fmt_idx,
                    "Param": param,
                    "Detail": detail,
                    "Text": text,
                    "TextByLang": text_by_lang,
                    "Extra": extra,
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
            return {"Border": "none", "Thick": False, "PerSide": OrderedDict(), "Uniform": True}

        lb = test_line_visible(fmt["LB"])
        tb = test_line_visible(fmt["TB"])
        rb = test_line_visible(fmt["RB"])
        bb = test_line_visible(fmt["BB"])

        if not lb and not tb and not rb and not bb:
            return {"Border": "none", "Thick": False, "PerSide": OrderedDict(), "Uniform": True}

        thick = False
        for b_idx in (fmt["LB"], fmt["TB"], fmt["RB"], fmt["BB"]):
            if (0 <= b_idx < len(raw_lines) and raw_lines[b_idx]["Style"] != "None"
                    and raw_lines[b_idx]["Width"] >= 2):
                thick = True
                break

        # Per-side line identity: needed both to tell Dotted from Solid and to notice
        # that sides of one cell use different lines
        per_side = OrderedDict()
        for side_name, idx in (("top", fmt["TB"]), ("bottom", fmt["BB"]),
                               ("left", fmt["LB"]), ("right", fmt["RB"])):
            if not test_line_visible(idx):
                continue
            if 0 <= idx < len(raw_lines):
                per_side[side_name] = {"Style": raw_lines[idx]["Style"], "Width": raw_lines[idx]["Width"]}
            else:
                per_side[side_name] = {"Style": "Solid", "Width": 1}

        # The compact form only covers plain solid lines of one width on every side
        uniform = True
        first_key = None
        for k in per_side:
            s = per_side[k]
            key = f'{s["Width"]}|{s["Style"]}'
            if s["Style"] != "Solid":
                uniform = False
                break
            if first_key is None:
                first_key = key
            elif key != first_key:
                uniform = False
                break

        if lb and tb and rb and bb:
            return {"Border": "all", "Thick": thick, "PerSide": per_side, "Uniform": uniform}

        sides = []
        if tb:
            sides.append("top")
        if bb:
            sides.append("bottom")
        if lb:
            sides.append("left")
        if rb:
            sides.append("right")

        return {"Border": ",".join(sides), "Thick": thick, "PerSide": per_side, "Uniform": uniform}

    # Stable text form of the per-side border description
    def get_border_key(bd):
        parts = []
        for k in bd["PerSide"]:
            s = bd["PerSide"][k]
            parts.append(f'{k}={s["Width"]}/{s["Style"]}')
        return ";".join(parts)

    def get_style_key(fmt):
        if not fmt:
            return "empty"
        # -1 means the format has no <font> at all, which is not the same as font 0
        fi = fmt["FontIdx"]
        bd = get_border_desc(fmt)
        bc = fmt["BorderColor"]
        bk = get_border_key(bd)
        # Carried-over properties are part of the style: two formats differing only in
        # them must not collapse into one
        ex = ""
        if fmt["Extra"]:
            ex = "".join(e["xml"] for e in fmt["Extra"])
        dfl = ""
        if fmt["DataFormatByLang"]:
            dfl = ";".join(f"{k}={v}" for k, v in fmt["DataFormatByLang"].items())
        ind = fmt["Indent"] if fmt["HasIndent"] else "-"
        wid = fmt["Width"] if fmt["HasWidth"] else "-"
        hei = fmt["Height"] if fmt["HasHeight"] else "-"
        return (f'f={fi}|b={bk}|ha={fmt["HA"]}|va={fmt["VA"]}|wr={fmt["Wrap"]}'
                f'|df={fmt["DataFormat"]}|dfl={dfl}|tc={fmt["TextColor"]}|bc={bc}'
                f'|hd={fmt["Hidden"]}|in={ind}|w={wid}|h={hei}|ex={ex}')

    # --- 10. Name fonts ---

    font_names = {}
    font_defs = OrderedDict()

    if raw_fonts:
        font_names[0] = "default"
        font_defs["default"] = raw_fonts[0]

    def get_font_key(f):
        size = num_str(f["Size"]) if f["HasSize"] else "-"
        return (f'{f["Face"]}|{size}|{f["Bold"]}|{f["Italic"]}|{f["Underline"]}'
                f'|{f["Strikeout"]}|{f["Ref"]}|{f["Kind"]}')

    font_key_map = {}
    if raw_fonts:
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
            parts.append(num_str(f["Size"]))
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

    for r in row_data.values():
        for cell in r["Cells"]:
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
                parts.append(f'border-{bd["Border"]}')

        if fmt["HA"] == "Center":
            parts.append("center")
        elif fmt["HA"] == "Right":
            parts.append("right")
        if fmt["VA"] == "Center":
            parts.append("vcenter")
        elif fmt["VA"] == "Top":
            parts.append("vtop")
        elif fmt["VA"] == "Bottom":
            parts.append("vbottom")
        if fmt["Wrap"] == "Wrap":
            parts.append("wrap")
        elif fmt["Wrap"]:
            parts.append(fmt["Wrap"].lower())
        if fmt["DataFormat"]:
            parts.append("fmt")

        if not parts:
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
        if fmt["FontIdx"] < 0:
            # The format names no font at all — an empty name says exactly that
            s_def["font"] = ""
        elif fmt["FontIdx"] in font_names and font_names[fmt["FontIdx"]] != "default":
            s_def["font"] = font_names[fmt["FontIdx"]]
        # Any token the platform uses, not just the three or four common ones
        if fmt["HA"]:
            s_def["align"] = fmt["HA"].lower()
        if fmt["VA"]:
            s_def["valign"] = fmt["VA"].lower()
        bd = get_border_desc(fmt)
        if bd["Border"] != "none":
            if bd["Uniform"]:
                s_def["border"] = bd["Border"]
                if bd["Thick"]:
                    s_def["borderWidth"] = "thick"
            else:
                # Sides differ in line style or width — describe each on its own
                borders = OrderedDict()
                for k in bd["PerSide"]:
                    s = bd["PerSide"][k]
                    borders[k] = OrderedDict({"style": s["Style"], "width": s["Width"]})
                s_def["borders"] = borders
        if fmt["Wrap"] == "Wrap":
            s_def["wrap"] = True
        elif fmt["Wrap"]:
            s_def["textPlacement"] = fmt["Wrap"].lower()
        if fmt["DataFormatByLang"]:
            s_def["format"] = fmt["DataFormatByLang"]
        elif fmt["DataFormat"]:
            s_def["format"] = fmt["DataFormat"]
        # A cell format can carry width/height of its own, zero included
        if fmt["HasWidth"]:
            s_def["width"] = fmt["Width"]
        if fmt["HasHeight"]:
            s_def["height"] = fmt["Height"]
        if fmt["TextColor"]:
            s_def["textColor"] = fmt["TextColor"]
        if fmt["BorderColor"]:
            s_def["borderColor"] = fmt["BorderColor"]
        if fmt["Hidden"]:
            s_def["hidden"] = (fmt["Hidden"] == "true")
        if fmt["HasIndent"]:
            s_def["indent"] = fmt["Indent"]

        # Properties the DSL does not model, plus the element order of the original
        # format so the compiler can reproduce it exactly
        if fmt["Extra"]:
            s_def["extra"] = fmt["Extra"]
            s_def["order"] = fmt["Order"]

        style_defs[name] = s_def

    def get_style_name(fmt_idx):
        key = format_to_style_key.get(fmt_idx)
        if key and key in style_names:
            return style_names[key]
        return "default"

    # --- 12. Build rows and areas ---

    # One document row -> DSL row object
    def build_dsl_row(global_row):
        rd = row_data.get(global_row)
        merge_cols = merge_cols_by_row.get(global_row, [])

        if not rd or rd["Empty"]:
            # A row without cells can still carry a height and anchor merges
            kept_fmt = rd["FormatIdx"] if rd else 0
            row_fmt = get_format(kept_fmt)
            has_height = bool(row_fmt and row_fmt["Height"] > 0)

            if len(merge_cols) == 0 and not has_height:
                return OrderedDict()
            rd = {"FormatIdx": kept_fmt, "Cells": [], "Empty": False}

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
            cf = get_format(cell["FormatIdx"])
            has_content = bool(cell["Param"] or cell["Text"] or (cf and cf["ContainsValue"])
                               or cell["Extra"])
            has_merge = f'{global_row},{cell["Col"]}' in merge_map

            if has_content or has_merge:
                content_cells.append(cell)
            else:
                gap_cells.append(cell)

        # Detect rowStyle
        row_style_name = None
        row_style_key = None

        # rowStyle fills every column of the row on compile, so it is only safe when the
        # row is materialized over the full width and all gap cells share one style
        row_is_full = len(rd["Cells"]) >= total_columns

        if gap_cells and row_is_full:
            gap_keys = {}
            for gc in gap_cells:
                fmt = get_format(gc["FormatIdx"])
                gap_keys[get_style_key(fmt)] = True

            if len(gap_keys) == 1:
                row_style_key = list(gap_keys.keys())[0]
                if row_style_key in style_names:
                    row_style_name = style_names[row_style_key]

        # Gap cells that rowStyle does not cover have to be written out explicitly,
        # otherwise their borders are lost
        if not row_style_name:
            content_cells.extend(gap_cells)
            gap_cells = []

        if row_style_name and row_style_name != "default":
            dsl_row["rowStyle"] = row_style_name

        # Build cell list
        dsl_cells = []

        for cell in sorted(content_cells, key=lambda x: x["Col"]):
            dsl_cell = OrderedDict({"col": cell["Col"] + 1})

            # Span/rowspan from merge
            mk = f'{global_row},{cell["Col"]}'
            if mk in merge_map:
                m = merge_map[mk]
                if m["W"] > 0:
                    dsl_cell["span"] = m["W"] + 1
                if m["H"] > 0:
                    dsl_cell["rowspan"] = m["H"] + 1
                # A 1x1 merge record carries no span but still exists in the document
                if m["W"] == 0 and m["H"] == 0:
                    dsl_cell["merge"] = True

            # Style
            cell_fmt = get_format(cell["FormatIdx"])
            cell_style_key = get_style_key(cell_fmt)

            if cell["FormatIdx"] <= 0:
                # The cell names no format at all — an empty style says exactly that
                dsl_cell["style"] = ""
            elif row_style_key and cell_style_key == row_style_key:
                # Inherits rowStyle
                pass
            else:
                sn = get_style_name(cell["FormatIdx"])
                if sn != "default" or not row_style_name:
                    dsl_cell["style"] = sn

            # Content
            fill_type = cell_fmt["FillType"] if cell_fmt else ""

            text_value = cell["TextByLang"] if cell["TextByLang"] else cell["Text"]

            # A detail parameter can stand on its own, without a parameter
            if cell["Detail"]:
                dsl_cell["detail"] = cell["Detail"]

            if cell["Param"]:
                dsl_cell["param"] = cell["Param"]
            elif fill_type == "Template" and cell["Text"]:
                dsl_cell["template"] = text_value
            elif cell["Text"]:
                dsl_cell["text"] = text_value

            if cell["Extra"]:
                dsl_cell["extra"] = cell["Extra"]

            # A cell can declare a fill type without carrying content — the compiler
            # would not guess it from the content, so state it
            auto_fill = ""
            if dsl_cell.get("param"):
                auto_fill = "Parameter"
            elif dsl_cell.get("template"):
                auto_fill = "Template"
            elif dsl_cell.get("text"):
                auto_fill = "Text"
            if fill_type and fill_type != auto_fill:
                dsl_cell["fillType"] = fill_type

            # Input cell
            if cell_fmt and cell_fmt["ContainsValue"]:
                ct = cell_fmt["ControlType"]
                if ct and ct in control_type_names:
                    dsl_cell["input"] = control_type_names[ct]
                elif ct:
                    dsl_cell["input"] = ct
                else:
                    dsl_cell["input"] = "field"

                if cell_fmt["ValueType"]:
                    dsl_cell["valueType"] = cell_fmt["ValueType"]

            dsl_cells.append(dsl_cell)

        # Merges anchored at positions without a cell record — emit a bare cell so the
        # merge survives the round trip
        known_cols = {cell["Col"] for cell in rd["Cells"]}
        for mc in merge_cols:
            if mc in known_cols:
                continue
            m = merge_map[f"{global_row},{mc}"]
            dsl_cell = OrderedDict({"col": mc + 1})
            if m["W"] > 0:
                dsl_cell["span"] = m["W"] + 1
            if m["H"] > 0:
                dsl_cell["rowspan"] = m["H"] + 1
            if m["W"] == 0 and m["H"] == 0:
                dsl_cell["merge"] = True
            dsl_cells.append(dsl_cell)

        if dsl_cells:
            dsl_row["cells"] = sorted(dsl_cells, key=lambda x: x["col"])
        return dsl_row

    # Compress consecutive empty rows ({}) into { empty = N }
    def compress_empty_rows(rows):
        compressed = []
        empty_run = 0
        for r in rows:
            if len(r) == 0:
                empty_run += 1
            else:
                if empty_run > 0:
                    if empty_run == 1:
                        compressed.append(OrderedDict())
                    else:
                        compressed.append(OrderedDict({"empty": empty_run}))
                    empty_run = 0
                compressed.append(r)
        if empty_run > 0:
            if empty_run == 1:
                compressed.append(OrderedDict())
            else:
                compressed.append(OrderedDict({"empty": empty_run}))
        return compressed

    dsl_areas = []
    dsl_rows = []
    dsl_named_areas = []

    if flat_mode:
        # Whole grid in one "rows" list, areas keep their absolute coordinates
        all_rows = [build_dsl_row(gr) for gr in range(doc_height)]
        dsl_rows = compress_empty_rows(all_rows)

        for area in named_areas:
            # Each bound is written on its own: the platform does emit half-open areas
            # such as beginColumn=-1 with endColumn=41 ("from the first column")
            na = OrderedDict({"name": area["Name"], "type": area["Type"]})
            if area["BeginRow"] >= 0:
                na["firstRow"] = area["BeginRow"] + 1
            if area["EndRow"] >= 0:
                na["lastRow"] = area["EndRow"] + 1
            if area["BeginCol"] >= 0:
                na["firstCol"] = area["BeginCol"] + 1
            if area["EndCol"] >= 0:
                na["lastCol"] = area["EndCol"] + 1
            dsl_named_areas.append(na)
    else:
        # Blocks are written out one after another, so they must go in row order —
        # the template lists namedItem elements in arbitrary order
        for area in sorted(named_areas, key=lambda a: a["BeginRow"]):
            area_rows = [build_dsl_row(gr) for gr in range(area["BeginRow"], area["EndRow"] + 1)]
            dsl_areas.append(OrderedDict({
                "name": area["Name"],
                "rows": compress_empty_rows(area_rows),
            }))

    # --- 13. Compress columnWidths ---

    compressed_widths = OrderedDict()
    if col_width_map:
        grouped = OrderedDict()
        for col in col_width_map:
            grouped.setdefault(col_width_map[col], []).append(col)
        for width, cols_raw in grouped.items():
            cols = sorted(cols_raw, key=lambda x: int(x))
            ranges = []
            range_start = cols[0]
            range_prev = cols[0]

            for i in range(1, len(cols)):
                if int(cols[i]) == int(range_prev) + 1:
                    range_prev = cols[i]
                else:
                    if range_start == range_prev:
                        ranges.append(f"{range_start}")
                    else:
                        ranges.append(f"{range_start}-{range_prev}")
                    range_start = cols[i]
                    range_prev = cols[i]
            if range_start == range_prev:
                ranges.append(f"{range_start}")
            else:
                ranges.append(f"{range_start}-{range_prev}")

            for rng in ranges:
                compressed_widths[rng] = width

    # --- 14. Build fonts output ---

    fonts_out = OrderedDict()
    for name, f in font_defs.items():
        f_out = OrderedDict({"face": f["Face"]})
        if f["HasSize"]:
            f_out["size"] = f["Size"]

        is_system_font = bool(f["Ref"] or (f["Kind"] and f["Kind"] != "Absolute"))
        if is_system_font and f["HasStyleAttrs"]:
            # Spell them out, false included, exactly as the template does
            f_out["bold"] = f["Bold"]
            f_out["italic"] = f["Italic"]
            f_out["underline"] = f["Underline"]
            f_out["strikeout"] = f["Strikeout"]
        else:
            if f["Bold"]:
                f_out["bold"] = True
            if f["Italic"]:
                f_out["italic"] = True
            if f["Underline"]:
                f_out["underline"] = True
            if f["Strikeout"]:
                f_out["strikeout"] = True

        if f["Ref"]:
            f_out["ref"] = f["Ref"]
        if f["Kind"] and f["Kind"] != "Absolute":
            f_out["kind"] = f["Kind"]
        fonts_out[name] = f_out

    # --- 15. Assemble result ---

    result = OrderedDict()
    result["columns"] = total_columns
    result["defaultWidth"] = default_width
    # Some templates keep leftover rows past their declared height — carry the
    # declared value over so the geometry of the document does not change
    if flat_mode and declared_height > 0 and declared_height != doc_height:
        result["height"] = declared_height
    # Only worth carrying when the template is not the plain single-language default
    multi_lang = bool(lang_settings and lang_settings.get("list") and len(lang_settings["list"]) > 1)
    if text_lang != "ru" or multi_lang:
        langs_out = lang_settings if lang_settings else OrderedDict()
        langs_out["text"] = text_lang
        result["languages"] = langs_out
    if compressed_widths:
        result["columnWidths"] = compressed_widths
    # Remove empty "default" style
    if "default" in style_defs and len(style_defs["default"]) == 0:
        del style_defs["default"]

    # Remove unused styles
    used_styles = set()
    if flat_mode:
        all_dsl_rows = dsl_rows
    else:
        all_dsl_rows = []
        for a in dsl_areas:
            all_dsl_rows.extend(a["rows"])

    for r in all_dsl_rows:
        if r.get("rowStyle"):
            used_styles.add(r["rowStyle"])
        for c in r.get("cells", []):
            if c.get("style"):
                used_styles.add(c["style"])
    to_remove = [s for s in style_defs if s not in used_styles]
    for s in to_remove:
        del style_defs[s]

    result["fonts"] = fonts_out
    result["styles"] = style_defs
    if extra_merges:
        result["extraMerges"] = extra_merges
    if flat_mode:
        result["rows"] = dsl_rows
        result["namedAreas"] = dsl_named_areas
    else:
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

    row_count = len(dsl_rows) if flat_mode else len(row_data)
    type_counts = OrderedDict()
    for a in named_areas:
        type_counts[a["Type"]] = type_counts.get(a["Type"], 0) + 1
    by_type = ", ".join(f"{k}={v}" for k, v in type_counts.items())
    mode = "flat" if flat_mode else "blocks"
    input_cells = sum(1 for f in raw_formats if f["ContainsValue"])

    print(f"     Mode: {mode}, Areas: {len(named_areas)} ({by_type}), "
          f"Rows: {row_count}, Columns: {total_columns}")
    print(f"     Fonts: {len(font_defs)}, Styles: {len(style_defs)}, "
          f"Merges: {len(merge_map) + len(extra_merges)}, Input formats: {input_cells}")


if __name__ == "__main__":
    main()
