#!/usr/bin/env python3
# skd-info v1.1 — Analyze 1C DCS structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
from collections import OrderedDict
from lxml import etree

S_NS = "http://v8.1c.ru/8.1/data-composition-system/schema"
DCSCOM_NS = "http://v8.1c.ru/8.1/data-composition-system/common"
DCSCOR_NS = "http://v8.1c.ru/8.1/data-composition-system/core"
DCSSET_NS = "http://v8.1c.ru/8.1/data-composition-system/settings"
V8_NS = "http://v8.1c.ru/8.1/data/core"
V8UI_NS = "http://v8.1c.ru/8.1/data/ui"
XS_NS = "http://www.w3.org/2001/XMLSchema"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
DCSAT_NS = "http://v8.1c.ru/8.1/data-composition-system/area-template"

NSMAP = {
    "s": S_NS,
    "dcscom": DCSCOM_NS,
    "dcscor": DCSCOR_NS,
    "dcsset": DCSSET_NS,
    "v8": V8_NS,
    "v8ui": V8UI_NS,
    "xs": XS_NS,
    "xsi": XSI_NS,
    "dcsat": DCSAT_NS,
}


def localname(el):
    return etree.QName(el.tag).localname


def get_ml_text(node):
    if node is None:
        return ""
    content = node.find("v8:item/v8:content", NSMAP)
    if content is not None and content.text:
        return content.text
    text = (node.text or "").strip()
    if text:
        return text
    # Also check inner text (all text content)
    all_text = "".join(node.itertext()).strip()
    if all_text:
        return all_text
    return ""


def unescape_xml(text):
    if not text:
        return text
    text = text.replace("&amp;", "&")
    text = text.replace("&gt;", ">")
    text = text.replace("&lt;", "<")
    text = text.replace("&quot;", '"')
    text = text.replace("&apos;", "'")
    return text


def get_compact_type(value_type_node):
    if value_type_node is None:
        return ""
    types = []
    for t in value_type_node.findall("v8:Type", NSMAP):
        raw = (t.text or "").strip()
        if raw == "xs:string":
            types.append("String")
        elif raw == "xs:decimal":
            types.append("Number")
        elif raw == "xs:boolean":
            types.append("Boolean")
        elif raw == "xs:dateTime":
            types.append("DateTime")
        elif raw == "v8:StandardPeriod":
            types.append("StandardPeriod")
        elif raw == "v8:StandardBeginningDate":
            types.append("StandardBeginningDate")
        elif raw == "v8:AccountType":
            types.append("AccountType")
        elif raw == "v8:Null":
            types.append("Null")
        else:
            # Strip namespace prefixes like d4p1: cfg:
            clean = re.sub(r'^[a-zA-Z0-9]+:', '', raw)
            types.append(clean)
    if not types:
        return ""
    return " | ".join(types)


def get_dataset_type(ds_node):
    xsi_type = ds_node.get(f"{{{XSI_NS}}}type", "")
    if "DataSetQuery" in xsi_type:
        return "Query"
    if "DataSetObject" in xsi_type:
        return "Object"
    if "DataSetUnion" in xsi_type:
        return "Union"
    return "Unknown"


def get_field_count(ds_node):
    return len(ds_node.findall("s:field", NSMAP))


def get_query_line_count(ds_node):
    query_node = ds_node.find("s:query", NSMAP)
    if query_node is None:
        return 0
    text = "".join(query_node.itertext())
    return len(text.split("\n"))


def get_structure_item_type(item_node):
    xsi_type = item_node.get(f"{{{XSI_NS}}}type", "")
    if "StructureItemGroup" in xsi_type:
        return "Group"
    if "StructureItemTable" in xsi_type:
        return "Table"
    if "StructureItemChart" in xsi_type:
        return "Chart"
    return "Unknown"


def get_group_fields(item_node):
    fields = []
    for gi in item_node.findall("dcsset:groupItems/dcsset:item", NSMAP):
        field_node = gi.find("dcsset:field", NSMAP)
        group_type = gi.find("dcsset:groupType", NSMAP)
        if field_node is not None:
            f = (field_node.text or "").strip()
            gt = (group_type.text or "").strip() if group_type is not None else ""
            if gt and gt != "Items":
                f += f"({gt})"
            fields.append(f)
    return fields


def get_selection_fields(item_node):
    fields = []
    for si in item_node.findall("dcsset:selection/dcsset:item", NSMAP):
        xsi_type = si.get(f"{{{XSI_NS}}}type", "")
        if "SelectedItemAuto" in xsi_type:
            fields.append("Auto")
        elif "SelectedItemField" in xsi_type:
            f = si.find("dcsset:field", NSMAP)
            if f is not None:
                fields.append((f.text or "").strip())
        elif "SelectedItemFolder" in xsi_type:
            fields.append("Folder")
    return fields


def get_filter_summary(settings_node):
    filters = []
    for fi in settings_node.findall("dcsset:filter/dcsset:item", NSMAP):
        xsi_type = fi.get(f"{{{XSI_NS}}}type", "")

        if "FilterItemGroup" in xsi_type:
            group_type = fi.find("dcsset:groupType", NSMAP)
            gt = (group_type.text or "").strip() if group_type is not None else "And"
            sub_count = len(fi.findall("dcsset:item", NSMAP))
            filters.append(f"[Group:{gt} {sub_count} items]")
            continue

        use = fi.find("dcsset:use", NSMAP)
        is_active = "[ ]" if (use is not None and (use.text or "").strip() == "false") else "[x]"

        left = fi.find("dcsset:left", NSMAP)
        comp = fi.find("dcsset:comparisonType", NSMAP)
        right = fi.find("dcsset:right", NSMAP)
        pres = fi.find("dcsset:presentation", NSMAP)
        user_setting = fi.find("dcsset:userSettingID", NSMAP)

        left_str = (left.text or "").strip() if left is not None else "?"
        comp_str = (comp.text or "").strip() if comp is not None else "?"
        right_str = ""
        if right is not None:
            right_text = "".join(right.itertext()).strip()
            right_str = f" {right_text}"

        pres_str = ""
        if pres is not None:
            pt = get_ml_text(pres)
            if pt:
                pres_str = f'  "{pt}"'

        user_str = ""
        if user_setting is not None:
            user_str = "  [user]"

        filters.append(f"{is_active} {left_str} {comp_str}{right_str}{pres_str}{user_str}")
    return filters


def build_structure_tree(item_node, prefix, is_last, out_lines):
    item_type = get_structure_item_type(item_node)
    name_node = item_node.find("dcsset:name", NSMAP)
    item_name = (name_node.text or "").strip() if name_node is not None else ""

    group_fields = get_group_fields(item_node)
    group_str = "[" + ", ".join(group_fields) + "]" if group_fields else "(detail)"

    sel_fields = get_selection_fields(item_node)
    sel_str = "Selection: " + ", ".join(sel_fields) if sel_fields else ""

    line = ""
    if item_type == "Group":
        line = f"{item_type} {group_str}"
        if item_name:
            line = f'{item_type} "{item_name}" {group_str}'
    elif item_type == "Table":
        line = "Table"
        if item_name:
            line = f'Table "{item_name}"'
    elif item_type == "Chart":
        line = "Chart"
        if item_name:
            line = f'Chart "{item_name}"'

    out_lines.append(f"{prefix}{line}")
    if sel_str and item_type == "Group":
        out_lines.append(f"{prefix}      {sel_str}")

    # For Table, show columns and rows
    if item_type == "Table":
        columns = item_node.findall("dcsset:column", NSMAP)
        rows = item_node.findall("dcsset:row", NSMAP)

        for col in columns:
            col_group = get_group_fields(col)
            col_group_str = "[" + ", ".join(col_group) + "]" if col_group else "(detail)"
            col_sel = get_selection_fields(col)
            col_sel_str = "Selection: " + ", ".join(col_sel) if col_sel else ""
            conn_c = "\u251C\u2500\u2500" if rows else "\u2514\u2500\u2500"
            cont_c = "\u2502     " if rows else "      "
            out_lines.append(f"{prefix}{conn_c} Columns: {col_group_str}")
            if col_sel_str:
                out_lines.append(f"{prefix}{cont_c} {col_sel_str}")

        for row in rows:
            row_group = get_group_fields(row)
            row_group_str = "[" + ", ".join(row_group) + "]" if row_group else "(detail)"
            row_sel = get_selection_fields(row)
            row_sel_str = "Selection: " + ", ".join(row_sel) if row_sel else ""
            out_lines.append(f"{prefix}\u2514\u2500\u2500 Rows: {row_group_str}")
            if row_sel_str:
                out_lines.append(f"{prefix}      {row_sel_str}")

    # Recurse into nested structure items (for Group)
    if item_type == "Group":
        children = item_node.findall("dcsset:item", NSMAP)
        for i, child in enumerate(children):
            child_type = child.get(f"{{{XSI_NS}}}type", "")
            if "StructureItem" in child_type:
                last = (i == len(children) - 1)
                connector = "\u2514\u2500 " if last else "\u251C\u2500 "
                continuation = "    " if last else "\u2502   "
                build_structure_tree(child, f"{prefix}{continuation}", last, out_lines)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Analyze 1C DCS structure", allow_abbrev=False)
    parser.add_argument("-TemplatePath", required=True)
    parser.add_argument("-Mode", default="overview",
                        choices=["overview", "query", "fields", "links", "calculated",
                                 "resources", "params", "variant", "trace", "templates", "full"])
    parser.add_argument("-Name", default=None)
    parser.add_argument("-Batch", type=int, default=0)
    parser.add_argument("-Limit", type=int, default=150)
    parser.add_argument("-Offset", type=int, default=0)
    parser.add_argument("-OutFile", default=None)
    args = parser.parse_args()

    # --- Resolve path ---
    original_path = args.TemplatePath
    template_path = original_path
    if not template_path.endswith(".xml"):
        candidate = os.path.join(template_path, "Ext", "Template.xml")
        if os.path.isfile(candidate):
            template_path = candidate

    # If still not found, try resolving from object directory (Reports/X, DataProcessors/X)
    if not os.path.isfile(template_path) and not template_path.endswith(".xml"):
        templates_dir = os.path.join(original_path, "Templates")
        if os.path.isdir(templates_dir):
            dcs_templates = []
            for fname in os.listdir(templates_dir):
                if not fname.endswith(".xml"):
                    continue
                meta_path = os.path.join(templates_dir, fname)
                if not os.path.isfile(meta_path):
                    continue
                try:
                    meta_tree = etree.parse(meta_path, etree.XMLParser(remove_blank_text=True))
                    tt_nodes = meta_tree.xpath("//*[local-name()='TemplateType']")
                    if tt_nodes and (tt_nodes[0].text or "").strip() == "DataCompositionSchema":
                        tpl_name = os.path.splitext(fname)[0]
                        tpl_path = os.path.join(templates_dir, tpl_name, "Ext", "Template.xml")
                        if os.path.isfile(tpl_path):
                            dcs_templates.append(tpl_path)
                except Exception:
                    continue
            if len(dcs_templates) == 1:
                template_path = dcs_templates[0]
                resolved_display = os.path.relpath(os.path.abspath(template_path))
                print(f"[i] Resolved: {resolved_display}")
            elif len(dcs_templates) > 1:
                print(f"Multiple DCS templates found in: {original_path}")
                for i, p in enumerate(dcs_templates):
                    print(f"  {i+1}. {os.path.relpath(os.path.abspath(p))}")
                print("Specify the template path.")
                sys.exit(1)
            else:
                print(f"No DCS templates found in: {original_path}", file=sys.stderr)
                sys.exit(1)

    if not os.path.isabs(template_path):
        template_path = os.path.join(os.getcwd(), template_path)

    if not os.path.isfile(template_path):
        print(f"File not found: {template_path}", file=sys.stderr)
        sys.exit(1)

    resolved_path = os.path.abspath(template_path)

    # --- Load XML ---
    xml_parser = etree.XMLParser(remove_blank_text=True)
    tree = etree.parse(resolved_path, xml_parser)
    root = tree.getroot()

    # --- Output collector ---
    lines = []

    # Determine template name from path
    path_parts = re.split(r'[/\\]', resolved_path)
    template_name = resolved_path
    for i in range(len(path_parts) - 1, -1, -1):
        if path_parts[i] == "Ext" and i >= 1:
            template_name = path_parts[i - 1]
            break

    with open(resolved_path, "r", encoding="utf-8-sig") as fh:
        total_xml_lines = len(fh.readlines())

    # === Helper functions that use root/lines/NSMAP ===

    def show_overview():
        lines.append(f"=== DCS: {template_name} ({total_xml_lines} lines) ===")
        lines.append("")

        # Sources
        sources = []
        for ds in root.findall("s:dataSource", NSMAP):
            ds_name_node = ds.find("s:name", NSMAP)
            ds_type_node = ds.find("s:dataSourceType", NSMAP)
            ds_name = (ds_name_node.text or "") if ds_name_node is not None else ""
            ds_type = (ds_type_node.text or "") if ds_type_node is not None else ""
            sources.append(f"{ds_name} ({ds_type})")
        lines.append("Sources: " + ", ".join(sources))
        lines.append("")

        # Datasets (recursive for Union)
        lines.append("Datasets:")
        for ds in root.findall("s:dataSet", NSMAP):
            ds_type = get_dataset_type(ds)
            ds_name_node = ds.find("s:name", NSMAP)
            ds_name = (ds_name_node.text or "") if ds_name_node is not None else ""
            field_count = get_field_count(ds)

            if ds_type == "Query":
                query_lines = get_query_line_count(ds)
                lines.append(f"  [Query]  {ds_name}   {field_count} fields, query {query_lines} lines")
            elif ds_type == "Object":
                obj_name = ds.find("s:objectName", NSMAP)
                obj_str = f"  objectName={obj_name.text}" if obj_name is not None else ""
                lines.append(f"  [Object] {ds_name}{obj_str}  {field_count} fields")
            elif ds_type == "Union":
                lines.append(f"  [Union]  {ds_name}  {field_count} fields")
                for sub_ds in ds.findall("s:item", NSMAP):
                    sub_type = get_dataset_type(sub_ds)
                    sub_name_node = sub_ds.find("s:name", NSMAP)
                    sub_name_str = (sub_name_node.text or "") if sub_name_node is not None else "?"
                    sub_fields = get_field_count(sub_ds)
                    if sub_type == "Query":
                        sub_query_lines = get_query_line_count(sub_ds)
                        lines.append(f"    \u251C\u2500 [Query] {sub_name_str}   {sub_fields} fields, query {sub_query_lines} lines")
                    elif sub_type == "Object":
                        sub_obj_name = sub_ds.find("s:objectName", NSMAP)
                        sub_obj_str = f"  objectName={sub_obj_name.text}" if sub_obj_name is not None else ""
                        lines.append(f"    \u251C\u2500 [Object] {sub_name_str}{sub_obj_str}  {sub_fields} fields")
                    else:
                        lines.append(f"    \u251C\u2500 [{sub_type}] {sub_name_str}  {sub_fields} fields")

        # Links -- only dataset pairs (not field-level)
        link_nodes = root.findall("s:dataSetLink", NSMAP)
        if link_nodes:
            link_pairs = OrderedDict()
            for lnk in link_nodes:
                src_ds = (lnk.find("s:sourceDataSet", NSMAP).text or "")
                dst_ds = (lnk.find("s:destinationDataSet", NSMAP).text or "")
                key = f"{src_ds} -> {dst_ds}"
                if key not in link_pairs:
                    link_pairs[key] = 0
                link_pairs[key] += 1
            link_strs = []
            for key, cnt in link_pairs.items():
                if cnt > 1:
                    link_strs.append(f"{key} ({cnt} fields)")
                else:
                    link_strs.append(key)
            lines.append("Links: " + ", ".join(link_strs))

        # Calculated fields -- count only
        calc_fields = root.findall("s:calculatedField", NSMAP)
        if calc_fields:
            lines.append(f"Calculated: {len(calc_fields)}")

        # Totals -- count + group flag
        total_fields = root.findall("s:totalField", NSMAP)
        if total_fields:
            has_grouped = False
            unique_paths = {}
            for tf in total_fields:
                tf_path = (tf.find("s:dataPath", NSMAP).text or "")
                unique_paths[tf_path] = True
                if tf.find("s:group", NSMAP) is not None:
                    has_grouped = True
            group_note = ", with group formulas" if has_grouped else ""
            if len(unique_paths) == len(total_fields):
                lines.append(f"Resources: {len(total_fields)}{group_note}")
            else:
                lines.append(f"Resources: {len(total_fields)} ({len(unique_paths)} fields{group_note})")

        # Templates -- count with binding types
        tpl_defs = root.findall("s:template", NSMAP)
        field_tpls = root.findall("s:fieldTemplate", NSMAP)
        group_tpls = root.findall("s:groupTemplate", NSMAP)
        group_header_tpls = root.findall("s:groupHeaderTemplate", NSMAP)
        group_footer_tpls = root.findall("s:groupFooterTemplate", NSMAP)
        if tpl_defs:
            parts = []
            if field_tpls:
                parts.append(f"{len(field_tpls)} field")
            grp_count = len(group_tpls) + len(group_header_tpls) + len(group_footer_tpls)
            if grp_count > 0:
                parts.append(f"{grp_count} group")
            lines.append(f"Templates: {len(tpl_defs)} defined ({', '.join(parts)} bindings)")

        # Parameters -- split visible/hidden
        params = root.findall("s:parameter", NSMAP)
        if params:
            visible_names = []
            hidden_count = 0
            for p in params:
                p_name = (p.find("s:name", NSMAP).text or "")
                use_restrict = p.find("s:useRestriction", NSMAP)
                is_hidden = (use_restrict is not None and (use_restrict.text or "").strip() == "true")
                if is_hidden:
                    hidden_count += 1
                else:
                    visible_names.append(p_name)
            param_line = f"Params: {len(params)}"
            if hidden_count > 0 and visible_names:
                param_line += f" ({len(visible_names)} visible, {hidden_count} hidden)"
            elif hidden_count == len(params):
                param_line += " (all hidden)"
            if visible_names and len(visible_names) <= 8:
                param_line += ": " + ", ".join(visible_names)
            lines.append(param_line)
        else:
            lines.append("Params: (none)")

        lines.append("")

        # Variants
        variants = root.findall("s:settingsVariant", NSMAP)
        if variants:
            lines.append("Variants:")
            for var_idx, v in enumerate(variants, 1):
                v_name = (v.find("dcsset:name", NSMAP).text or "")
                v_pres = v.find("dcsset:presentation", NSMAP)
                v_pres_str = ""
                if v_pres is not None:
                    pt = get_ml_text(v_pres)
                    if pt:
                        v_pres_str = f'  "{pt}"'

                settings = v.find("dcsset:settings", NSMAP)
                struct_items = []
                if settings is not None:
                    for si in settings.findall("dcsset:item", NSMAP):
                        si_type = get_structure_item_type(si)
                        gf = get_group_fields(si)
                        g_str = "(" + ",".join(gf) + ")" if gf else "(detail)"
                        struct_items.append(f"{si_type}{g_str}")

                # Compact: if many identical items, show count
                if len(struct_items) > 3:
                    from collections import Counter
                    counted = Counter(struct_items)
                    compact_parts = []
                    for name, count in counted.most_common():
                        if count > 1:
                            compact_parts.append(f"{count}x {name}")
                        else:
                            compact_parts.append(name)
                    struct_items = compact_parts

                struct_str = "  " + ", ".join(struct_items) if struct_items else ""

                filter_count = 0
                if settings is not None:
                    filter_count = len(settings.findall("dcsset:filter/dcsset:item", NSMAP))
                filter_str = f"  {filter_count} filters" if filter_count > 0 else ""

                lines.append(f"  [{var_idx}] {v_name}{v_pres_str}{struct_str}{filter_str}")

    def show_overview_hints():
        lines.append("")
        hints = []
        # Collect query dataset names for hint
        query_ds_names = []
        for ds in root.findall("s:dataSet", NSMAP):
            ds_type = get_dataset_type(ds)
            if ds_type == "Query":
                query_ds_names.append((ds.find("s:name", NSMAP).text or ""))
            elif ds_type == "Union":
                for sub_ds in ds.findall("s:item", NSMAP):
                    if get_dataset_type(sub_ds) == "Query":
                        sn = sub_ds.find("s:name", NSMAP)
                        if sn is not None:
                            query_ds_names.append((sn.text or ""))
        if len(query_ds_names) == 1:
            hints.append("-Mode query             query text")
        elif len(query_ds_names) > 1:
            hints.append(f"-Mode query -Name <ds>  query text ({', '.join(query_ds_names)})")
        hints.append("-Mode fields            field tables by dataset")
        link_count = len(root.findall("s:dataSetLink", NSMAP))
        if link_count > 0:
            hints.append(f"-Mode links             dataset connections ({link_count})")
        calc_count = len(root.findall("s:calculatedField", NSMAP))
        total_count = len(root.findall("s:totalField", NSMAP))
        if calc_count > 0:
            hints.append(f"-Mode calculated        calculated field expressions ({calc_count})")
        if total_count > 0:
            hints.append(f"-Mode resources         resource aggregation ({total_count})")
        params = root.findall("s:parameter", NSMAP)
        if params:
            hints.append("-Mode params            parameter details")
        variants = root.findall("s:settingsVariant", NSMAP)
        if len(variants) == 1:
            hints.append("-Mode variant           variant structure")
        elif len(variants) > 1:
            hints.append(f"-Mode variant -Name <N> variant structure (1..{len(variants)})")
        tpl_defs = root.findall("s:template", NSMAP)
        if tpl_defs:
            hints.append("-Mode templates         template bindings and expressions")
        hints.append("-Mode trace -Name <f>   trace field origin (by name or title)")
        hints.append("-Mode full              all sections at once")
        lines.append("Next:")
        for h in hints:
            lines.append(f"  {h}")

    def show_query():
        # Find dataset
        data_sets = root.findall("s:dataSet", NSMAP)
        target_ds = None

        if args.Name:
            # Search by name: prefer nested Query items over parent Union
            # Pass 1: search nested items first
            for ds in data_sets:
                for sub_ds in ds.findall("s:item", NSMAP):
                    sub_name_node = sub_ds.find("s:name", NSMAP)
                    if sub_name_node is not None and (sub_name_node.text or "") == args.Name:
                        target_ds = sub_ds
                        break
                if target_ds is not None:
                    break
            # Pass 2: search top-level
            if target_ds is None:
                for ds in data_sets:
                    ds_name_node = ds.find("s:name", NSMAP)
                    if ds_name_node is not None and (ds_name_node.text or "") == args.Name:
                        target_ds = ds
                        break
            if target_ds is None:
                print(f"Dataset '{args.Name}' not found", file=sys.stderr)
                sys.exit(1)
        else:
            # Take first Query dataset
            for ds in data_sets:
                ds_type = get_dataset_type(ds)
                if ds_type == "Query":
                    target_ds = ds
                    break
                if ds_type == "Union":
                    for sub_ds in ds.findall("s:item", NSMAP):
                        if get_dataset_type(sub_ds) == "Query":
                            target_ds = sub_ds
                            break
                    if target_ds is not None:
                        break
            if target_ds is None:
                print("No Query dataset found", file=sys.stderr)
                sys.exit(1)

        query_node = target_ds.find("s:query", NSMAP)
        if query_node is None:
            # If this is a Union, list nested query datasets
            ds_type = get_dataset_type(target_ds)
            if ds_type == "Union":
                sub_names = []
                for sub_ds in target_ds.findall("s:item", NSMAP):
                    sn = sub_ds.find("s:name", NSMAP)
                    if sn is not None:
                        sub_names.append((sn.text or ""))
                ds_name_text = (target_ds.find("s:name", NSMAP).text or "")
                print(f"Dataset '{ds_name_text}' is a Union. Specify nested: {', '.join(sub_names)}", file=sys.stderr)
            else:
                print("Dataset has no query element", file=sys.stderr)
            sys.exit(1)

        raw_query = unescape_xml("".join(query_node.itertext()))
        ds_name_str = (target_ds.find("s:name", NSMAP).text or "")

        # Split into batches
        batches = []
        batch_texts = re.split(r';\s*\r?\n\s*/{16,}\s*\r?\n', raw_query)
        for bt in batch_texts:
            trimmed = bt.strip()
            if trimmed:
                batches.append(trimmed)

        total_query_lines = len(raw_query.split("\n"))

        if len(batches) <= 1:
            # Single query
            lines.append(f"=== Query: {ds_name_str} ({total_query_lines} lines) ===")
            lines.append("")
            for ql in raw_query.strip().split("\n"):
                lines.append(ql.rstrip())
        else:
            lines.append(f"=== Query: {ds_name_str} ({total_query_lines} lines, {len(batches)} batches) ===")

            if args.Batch == 0:
                # Show TOC
                line_num = 1
                for bi in range(len(batches)):
                    batch_lines = batches[bi].split("\n")
                    end_line = line_num + len(batch_lines) - 1
                    # Detect target
                    target = ""
                    for bl in batch_lines:
                        m = re.match(r'^\s*(?:\u041F\u041E\u041C\u0415\u0421\u0422\u0418\u0422\u042C|INTO)\s+(\S+)', bl)
                        if m:
                            target = "\u2192 " + m.group(1)
                            break
                    lines.append(f"  Batch {bi + 1}: lines {line_num}-{end_line}  {target}")
                    line_num = end_line + 3  # +separator

                lines.append("")

                # Show all batches
                for bi in range(len(batches)):
                    lines.append(f"--- Batch {bi + 1} ---")
                    for ql in batches[bi].split("\n"):
                        lines.append(ql.rstrip())
                    lines.append("")
            else:
                # Show specific batch
                if args.Batch > len(batches):
                    print(f"Batch {args.Batch} not found (total: {len(batches)})", file=sys.stderr)
                    sys.exit(1)
                lines.append("")
                lines.append(f"--- Batch {args.Batch} ---")
                for ql in batches[args.Batch - 1].split("\n"):
                    lines.append(ql.rstrip())

    def show_fields():
        data_sets = root.findall("s:dataSet", NSMAP)

        def show_dataset_fields(ds_node):
            ds_type = get_dataset_type(ds_node)
            ds_name_str = (ds_node.find("s:name", NSMAP).text or "")
            fields = ds_node.findall("s:field", NSMAP)

            lines.append(f"=== Fields: {ds_name_str} [{ds_type}] ({len(fields)}) ===")
            lines.append("  dataPath                          title                  role       restrict     format")

            for f in fields:
                dp = f.find("s:dataPath", NSMAP)
                dp_str = (dp.text or "").strip() if dp is not None else "-"

                title_node = f.find("s:title", NSMAP)
                title_str = get_ml_text(title_node) if title_node is not None else ""
                if not title_str:
                    title_str = "-"

                # Role
                role = f.find("s:role", NSMAP)
                role_str = "-"
                if role is not None:
                    role_parts = []
                    for child in role:
                        if isinstance(child.tag, str) and (child.text or "").strip() == "true":
                            role_parts.append(localname(child))
                    if role_parts:
                        role_str = ",".join(role_parts)

                # UseRestriction
                restrict = f.find("s:useRestriction", NSMAP)
                restrict_str = "-"
                if restrict is not None:
                    restrict_parts = []
                    for child in restrict:
                        if isinstance(child.tag, str) and (child.text or "").strip() == "true":
                            ln = localname(child)
                            restrict_parts.append(ln[:4])
                    if restrict_parts:
                        restrict_str = ",".join(restrict_parts)

                # Appearance format
                format_str = "-"
                appearance = f.find("s:appearance", NSMAP)
                if appearance is not None:
                    for app_item in appearance.findall("dcscor:item", NSMAP):
                        param_node = app_item.find("dcscor:parameter", NSMAP)
                        val_node = app_item.find("dcscor:value", NSMAP)
                        if param_node is not None and val_node is not None:
                            param_text = (param_node.text or "").strip()
                            if param_text in ("\u0424\u043E\u0440\u043C\u0430\u0442", "Format"):
                                format_str = (val_node.text or "").strip()

                # presentationExpression
                pres_expr = f.find("s:presentationExpression", NSMAP)
                pres_str = "  presExpr" if pres_expr is not None else ""

                dp_pad = dp_str.ljust(35)
                title_pad = title_str.ljust(22)
                role_pad = role_str.ljust(10)
                restrict_pad = restrict_str.ljust(12)

                lines.append(f"  {dp_pad} {title_pad} {role_pad} {restrict_pad} {format_str}{pres_str}")

        def collect_field_info(ds_node):
            ds_type = get_dataset_type(ds_node)
            ds_name_str = (ds_node.find("s:name", NSMAP).text or "")
            for f in ds_node.findall("s:field", NSMAP):
                dp = f.find("s:dataPath", NSMAP)
                if dp is None or (dp.text or "") != args.Name:
                    continue

                info = {"dataset": f"{ds_name_str} [{ds_type}]"}

                title_node = f.find("s:title", NSMAP)
                info["title"] = get_ml_text(title_node) if title_node is not None else ""

                # ValueType
                vt = f.find("s:valueType", NSMAP)
                info["type"] = get_compact_type(vt) if vt is not None else ""

                # Role
                role = f.find("s:role", NSMAP)
                role_parts = []
                if role is not None:
                    for child in role:
                        if isinstance(child.tag, str) and (child.text or "").strip() == "true":
                            role_parts.append(localname(child))
                info["role"] = ", ".join(role_parts)

                # UseRestriction
                restrict = f.find("s:useRestriction", NSMAP)
                restrict_parts = []
                if restrict is not None:
                    for child in restrict:
                        if isinstance(child.tag, str) and (child.text or "").strip() == "true":
                            restrict_parts.append(localname(child))
                info["restrict"] = ", ".join(restrict_parts)

                # Format
                format_str = ""
                appearance = f.find("s:appearance", NSMAP)
                if appearance is not None:
                    for app_item in appearance.findall("dcscor:item", NSMAP):
                        pn = app_item.find("dcscor:parameter", NSMAP)
                        vn = app_item.find("dcscor:value", NSMAP)
                        if pn is not None and vn is not None:
                            pn_text = (pn.text or "").strip()
                            if pn_text in ("\u0424\u043E\u0440\u043C\u0430\u0442", "Format"):
                                format_str = (vn.text or "").strip()
                info["format"] = format_str

                # PresentationExpression
                pres_expr = f.find("s:presentationExpression", NSMAP)
                info["presExpr"] = "".join(pres_expr.itertext()) if pres_expr is not None else ""

                return info
            return None

        if args.Name:
            # Detail for specific field by dataPath -- search all datasets
            field_infos = []
            for ds in data_sets:
                info = collect_field_info(ds)
                if info:
                    field_infos.append(info)
                ds_type = get_dataset_type(ds)
                if ds_type == "Union":
                    for sub_ds in ds.findall("s:item", NSMAP):
                        info = collect_field_info(sub_ds)
                        if info:
                            field_infos.append(info)

            if not field_infos:
                print(f"Field '{args.Name}' not found in any dataset", file=sys.stderr)
                sys.exit(1)

            # Use first match for detail
            first = field_infos[0]
            title_str = f' "{first["title"]}"' if first["title"] else ""
            lines.append(f"=== Field: {args.Name}{title_str} ===")
            lines.append("")

            # Datasets
            ds_list = ", ".join(fi["dataset"] for fi in field_infos)
            lines.append(f"Dataset: {ds_list}")

            if first["type"]:
                lines.append(f"Type: {first['type']}")
            if first["role"]:
                lines.append(f"Role: {first['role']}")
            if first["restrict"]:
                lines.append(f"Restrict: {first['restrict']}")
            if first["format"]:
                lines.append(f"Format: {first['format']}")
            if first["presExpr"]:
                lines.append("PresentationExpression:")
                for el in first["presExpr"].split("\n"):
                    lines.append(f"  {el.rstrip()}")
        else:
            # Compact map: field names per dataset
            lines.append("=== Fields map ===")

            def show_dataset_field_map(ds_node, indent):
                ds_type = get_dataset_type(ds_node)
                ds_name_str = (ds_node.find("s:name", NSMAP).text or "")
                fields = ds_node.findall("s:field", NSMAP)
                field_names = []
                for f in fields:
                    dp = f.find("s:dataPath", NSMAP)
                    if dp is not None:
                        field_names.append((dp.text or ""))
                name_list = ", ".join(field_names)
                if len(name_list) > 100:
                    name_list = name_list[:97] + "..."
                lines.append(f"{indent}{ds_name_str} [{ds_type}] ({len(fields)}): {name_list}")

            for ds in data_sets:
                show_dataset_field_map(ds, "")
                ds_type = get_dataset_type(ds)
                if ds_type == "Union":
                    for sub_ds in ds.findall("s:item", NSMAP):
                        show_dataset_field_map(sub_ds, "  ")

            lines.append("")
            lines.append("Use -Name <field> for details.")

    def show_links():
        link_nodes = root.findall("s:dataSetLink", NSMAP)
        if not link_nodes:
            lines.append("(no links)")
        else:
            lines.append(f"=== Links ({len(link_nodes)}) ===")
            lines.append("")
            # Group by source->dest pair
            current_pair = ""
            for lnk in link_nodes:
                src_ds = (lnk.find("s:sourceDataSet", NSMAP).text or "")
                dst_ds = (lnk.find("s:destinationDataSet", NSMAP).text or "")
                src_expr = (lnk.find("s:sourceExpression", NSMAP).text or "")
                dst_expr = (lnk.find("s:destinationExpression", NSMAP).text or "")
                param_node = lnk.find("s:parameter", NSMAP)

                pair = f"{src_ds} -> {dst_ds}"
                if pair != current_pair:
                    if current_pair:
                        lines.append("")
                    lines.append(f"{pair} :")
                    current_pair = pair

                param_str = ""
                if param_node is not None:
                    param_str = f"  param={param_node.text or ''}"

                lines.append(f"  {src_expr} -> {dst_expr}{param_str}")

    def show_calculated():
        calc_fields = root.findall("s:calculatedField", NSMAP)
        if not calc_fields:
            lines.append("(no calculated fields)")
        elif args.Name:
            found = False
            for cf in calc_fields:
                cf_path = (cf.find("s:dataPath", NSMAP).text or "")
                if cf_path == args.Name:
                    lines.append(f"=== Calculated: {cf_path} ===")
                    lines.append("")

                    cf_expr = "".join(cf.find("s:expression", NSMAP).itertext())
                    lines.append("Expression:")
                    for el in cf_expr.split("\n"):
                        lines.append(f"  {el.rstrip()}")

                    cf_title = cf.find("s:title", NSMAP)
                    if cf_title is not None:
                        t = get_ml_text(cf_title)
                        if t:
                            lines.append(f"Title: {t}")

                    cf_restrict = cf.find("s:useRestriction", NSMAP)
                    if cf_restrict is not None:
                        parts = []
                        for child in cf_restrict:
                            if isinstance(child.tag, str) and (child.text or "").strip() == "true":
                                parts.append(localname(child))
                        if parts:
                            lines.append(f"Restrict: {', '.join(parts)}")

                    found = True
                    break
            if not found:
                print(f"Calculated field '{args.Name}' not found", file=sys.stderr)
                sys.exit(1)
        else:
            # Map
            lines.append(f"=== Calculated fields ({len(calc_fields)}) ===")
            for cf in calc_fields:
                cf_path = (cf.find("s:dataPath", NSMAP).text or "")
                cf_title = cf.find("s:title", NSMAP)
                title_str = ""
                if cf_title is not None:
                    t = get_ml_text(cf_title)
                    if t and t != cf_path:
                        title_str = f'  "{t}"'
                lines.append(f"  {cf_path}{title_str}")
            lines.append("")
            lines.append("Use -Name <field> for full expression.")

    def show_resources():
        total_fields = root.findall("s:totalField", NSMAP)
        if not total_fields:
            lines.append("(no resources)")
        elif args.Name:
            matched = []
            for tf in total_fields:
                tf_path = (tf.find("s:dataPath", NSMAP).text or "")
                if tf_path == args.Name:
                    matched.append(tf)
            if not matched:
                print(f"Resource '{args.Name}' not found", file=sys.stderr)
                sys.exit(1)
            lines.append(f"=== Resource: {args.Name} ===")
            lines.append("")
            for tf in matched:
                tf_expr = (tf.find("s:expression", NSMAP).text or "")
                tf_group = tf.find("s:group", NSMAP)
                group_str = "(overall)"
                if tf_group is not None:
                    group_str = (tf_group.text or "")
                lines.append(f"  [{group_str}] {tf_expr}")
        else:
            # Map
            lines.append(f"=== Resources ({len(total_fields)}) ===")
            res_map = OrderedDict()
            for tf in total_fields:
                tf_path = (tf.find("s:dataPath", NSMAP).text or "")
                tf_group = tf.find("s:group", NSMAP)
                if tf_path not in res_map:
                    res_map[tf_path] = {"hasGroup": False}
                if tf_group is not None:
                    res_map[tf_path]["hasGroup"] = True
            for key, val in res_map.items():
                group_mark = " *" if val["hasGroup"] else ""
                lines.append(f"  {key}{group_mark}")
            lines.append("")
            lines.append("  * = has group-level formulas")
            lines.append("")
            lines.append("Use -Name <field> for full formula.")

    def show_params():
        params = root.findall("s:parameter", NSMAP)
        lines.append(f"=== Parameters ({len(params)}) ===")
        lines.append("  Name                            Type                   Default          Visible  Expression")

        for p in params:
            p_name = (p.find("s:name", NSMAP).text or "")
            p_type = get_compact_type(p.find("s:valueType", NSMAP))
            if not p_type:
                p_type = "-"

            # Default value
            val_node = p.find("s:value", NSMAP)
            val_str = "-"
            if val_node is not None:
                nil_attr = val_node.get(f"{{{XSI_NS}}}nil", "")
                if nil_attr == "true":
                    val_str = "null"
                else:
                    raw = "".join(val_node.itertext()).strip()
                    if raw == "0001-01-01T00:00:00":
                        val_str = "-"
                    elif raw:
                        # Check for StandardPeriod variant
                        variant = val_node.find("v8:variant", NSMAP)
                        if variant is not None:
                            val_str = (variant.text or "")
                        else:
                            val_str = raw
                            if len(val_str) > 15:
                                val_str = val_str[:12] + "..."

            # Visibility
            use_restrict = p.find("s:useRestriction", NSMAP)
            vis_str = "yes"
            if use_restrict is not None:
                ur_text = (use_restrict.text or "").strip()
                if ur_text == "true":
                    vis_str = "hidden"
                elif ur_text == "false":
                    vis_str = "yes"

            # Expression
            expr_node = p.find("s:expression", NSMAP)
            expr_str = "-"
            if expr_node is not None:
                expr_text = "".join(expr_node.itertext()).strip()
                if expr_text:
                    expr_str = unescape_xml(expr_text)

            # availableAsField
            avail_field = p.find("s:availableAsField", NSMAP)
            avail_str = ""
            if avail_field is not None and (avail_field.text or "").strip() == "false":
                avail_str = " [noField]"

            name_pad = p_name.ljust(33)
            type_pad = p_type.ljust(22)
            val_pad = val_str.ljust(16)
            vis_pad = vis_str.ljust(8)

            lines.append(f"  {name_pad} {type_pad} {val_pad} {vis_pad} {expr_str}{avail_str}")

    def show_variant():
        variants = root.findall("s:settingsVariant", NSMAP)

        if not args.Name:
            # --- Variant list (map) ---
            if not variants:
                lines.append("=== Variants: (none) ===")
            else:
                lines.append(f"=== Variants ({len(variants)}) ===")
                for var_idx, v in enumerate(variants, 1):
                    v_name = (v.find("dcsset:name", NSMAP).text or "")
                    v_pres = v.find("dcsset:presentation", NSMAP)
                    v_pres_str = ""
                    if v_pres is not None:
                        pt = get_ml_text(v_pres)
                        if pt:
                            v_pres_str = f'  "{pt}"'

                    settings = v.find("dcsset:settings", NSMAP)
                    struct_items = []
                    if settings is not None:
                        for si in settings.findall("dcsset:item", NSMAP):
                            si_type = get_structure_item_type(si)
                            gf = get_group_fields(si)
                            g_str = "(" + ",".join(gf) + ")" if gf else "(detail)"
                            struct_items.append(f"{si_type}{g_str}")
                    if len(struct_items) > 3:
                        from collections import Counter
                        counted = Counter(struct_items)
                        compact_parts = []
                        for name, count in counted.most_common():
                            if count > 1:
                                compact_parts.append(f"{count}x {name}")
                            else:
                                compact_parts.append(name)
                        struct_items = compact_parts
                    struct_str = "  " + ", ".join(struct_items) if struct_items else ""

                    filter_count = 0
                    if settings is not None:
                        filter_count = len(settings.findall("dcsset:filter/dcsset:item", NSMAP))
                    filter_str = f"  {filter_count} filters" if filter_count > 0 else ""

                    # Selection fields
                    sel_fields = []
                    if settings is not None:
                        sel_fields = get_selection_fields(settings)
                    sel_str = "  sel: " + ", ".join(sel_fields) if sel_fields else ""

                    lines.append(f"  [{var_idx}] {v_name}{v_pres_str}{struct_str}{filter_str}")
                    if sel_str:
                        lines.append(f"        {sel_str}")
        else:
            # --- Variant detail ---
            target_variant = None
            match_idx = 0
            for var_idx, v in enumerate(variants, 1):
                v_name = (v.find("dcsset:name", NSMAP).text or "")
                if v_name == args.Name or str(var_idx) == args.Name:
                    target_variant = v
                    match_idx = var_idx
                    break
            if target_variant is None:
                print(f"Variant '{args.Name}' not found. Use -Mode variant without -Name to see list.", file=sys.stderr)
                sys.exit(1)

            v_name = (target_variant.find("dcsset:name", NSMAP).text or "")
            v_pres = target_variant.find("dcsset:presentation", NSMAP)
            v_pres_str = ""
            if v_pres is not None:
                pt = get_ml_text(v_pres)
                if pt:
                    v_pres_str = f' "{pt}"'

            lines.append(f"=== Variant [{match_idx}]: {v_name}{v_pres_str} ===")

            settings = target_variant.find("dcsset:settings", NSMAP)
            if settings is None:
                lines.append("  (empty settings)")
            else:
                # Selection at settings level
                top_sel = get_selection_fields(settings)
                if top_sel:
                    lines.append("")
                    lines.append("Selection: " + ", ".join(top_sel))

                # Structure
                struct_items = settings.findall("dcsset:item", NSMAP)
                has_struct = False
                for si in struct_items:
                    si_xsi_type = si.get(f"{{{XSI_NS}}}type", "")
                    if "StructureItem" in si_xsi_type:
                        has_struct = True
                        break

                if has_struct:
                    lines.append("")
                    lines.append("Structure:")
                    for si in struct_items:
                        si_xsi_type = si.get(f"{{{XSI_NS}}}type", "")
                        if "StructureItem" in si_xsi_type:
                            build_structure_tree(si, "  ", False, lines)

                # Filter
                filters = get_filter_summary(settings)
                if filters:
                    lines.append("")
                    lines.append("Filter:")
                    for f in filters:
                        lines.append(f"  {f}")

                # Data parameters
                data_params = settings.findall("dcsset:dataParameters/dcsset:item", NSMAP)
                if data_params:
                    dp_strs = []
                    for dp in data_params:
                        dp_param = dp.find("dcscor:parameter", NSMAP)
                        dp_val = dp.find("dcscor:value", NSMAP)
                        if dp_param is not None and dp_val is not None:
                            dp_strs.append(f'{(dp_param.text or "")}="{(dp_val.text or "")}"')
                    if dp_strs:
                        lines.append("")
                        lines.append("DataParams: " + ", ".join(dp_strs))

                # Output parameters
                out_params = settings.findall("dcsset:outputParameters/dcscor:item", NSMAP)
                if out_params:
                    op_strs = []
                    for op in out_params:
                        op_param = op.find("dcscor:parameter", NSMAP)
                        op_val = op.find("dcscor:value", NSMAP)
                        if op_param is not None and op_val is not None:
                            param_name = (op_param.text or "")
                            param_val = (op_val.text or "")
                            # Shorten known long names
                            short_map = {
                                "\u041C\u0430\u043A\u0435\u0442\u041E\u0444\u043E\u0440\u043C\u043B\u0435\u043D\u0438\u044F": "style",
                                "\u0420\u0430\u0441\u043F\u043E\u043B\u043E\u0436\u0435\u043D\u0438\u0435\u041F\u043E\u043B\u0435\u0439\u0413\u0440\u0443\u043F\u043F\u0438\u0440\u043E\u0432\u043A\u0438": "groups",
                                "\u0413\u043E\u0440\u0438\u0437\u043E\u043D\u0442\u0430\u043B\u044C\u043D\u043E\u0435\u0420\u0430\u0441\u043F\u043E\u043B\u043E\u0436\u0435\u043D\u0438\u0435\u041E\u0431\u0449\u0438\u0445\u0418\u0442\u043E\u0433\u043E\u0432": "totalsH",
                                "\u0412\u0435\u0440\u0442\u0438\u043A\u0430\u043B\u044C\u043D\u043E\u0435\u0420\u0430\u0441\u043F\u043E\u043B\u043E\u0436\u0435\u043D\u0438\u0435\u041E\u0431\u0449\u0438\u0445\u0418\u0442\u043E\u0433\u043E\u0432": "totalsV",
                                "\u0412\u044B\u0432\u043E\u0434\u0438\u0442\u044C\u0417\u0430\u0433\u043E\u043B\u043E\u0432\u043E\u043A": "header",
                                "\u0412\u044B\u0432\u043E\u0434\u0438\u0442\u044C\u041E\u0442\u0431\u043E\u0440": "filter",
                                "\u0412\u044B\u0432\u043E\u0434\u0438\u0442\u044C\u041F\u0430\u0440\u0430\u043C\u0435\u0442\u0440\u044B\u0414\u0430\u043D\u043D\u044B\u0445": "dataParams",
                                "\u0420\u0430\u0441\u043F\u043E\u043B\u043E\u0436\u0435\u043D\u0438\u0435\u0420\u0435\u043A\u0432\u0438\u0437\u0438\u0442\u043E\u0432": "attrs",
                            }
                            short = short_map.get(param_name, None)
                            if short:
                                op_strs.append(f"{short}={param_val}")
                            else:
                                op_strs.append(f"{param_name}={param_val}")
                    if op_strs:
                        lines.append("")
                        lines.append("Output: " + "  ".join(op_strs))

    def show_trace():
        if not args.Name:
            print("Trace mode requires -Name <field_name_or_title>", file=sys.stderr)
            sys.exit(1)

        # --- Build field index ---
        ds_fields = {}     # dataPath -> { "datasets": [], "title": "" }
        calc_fields_map = {}   # dataPath -> { "expression": "", "title": "" }
        res_fields = {}    # dataPath -> [{ "expression": "", "group": "" }]
        title_map = {}     # title -> dataPath

        # Scan dataset fields (including nested Union items)
        data_sets = root.findall("s:dataSet", NSMAP)
        for ds in data_sets:
            ds_name = (ds.find("s:name", NSMAP).text or "")
            ds_type = get_dataset_type(ds)

            for f in ds.findall("s:field", NSMAP):
                dp = f.find("s:dataPath", NSMAP)
                if dp is None:
                    continue
                dp_str = (dp.text or "")
                if dp_str not in ds_fields:
                    ds_fields[dp_str] = {"datasets": [], "title": ""}
                ds_fields[dp_str]["datasets"].append(f"{ds_name} [{ds_type}]")
                title_node = f.find("s:title", NSMAP)
                if title_node is not None:
                    t = get_ml_text(title_node)
                    if t:
                        if not ds_fields[dp_str]["title"]:
                            ds_fields[dp_str]["title"] = t
                        if t not in title_map:
                            title_map[t] = dp_str

            if ds_type == "Union":
                for sub_ds in ds.findall("s:item", NSMAP):
                    sub_name = (sub_ds.find("s:name", NSMAP).text or "")
                    sub_type = get_dataset_type(sub_ds)
                    for f in sub_ds.findall("s:field", NSMAP):
                        dp = f.find("s:dataPath", NSMAP)
                        if dp is None:
                            continue
                        dp_str = (dp.text or "")
                        if dp_str not in ds_fields:
                            ds_fields[dp_str] = {"datasets": [], "title": ""}
                        ds_fields[dp_str]["datasets"].append(f"{sub_name} [{sub_type}]")
                        title_node = f.find("s:title", NSMAP)
                        if title_node is not None:
                            t = get_ml_text(title_node)
                            if t:
                                if not ds_fields[dp_str]["title"]:
                                    ds_fields[dp_str]["title"] = t
                                if t not in title_map:
                                    title_map[t] = dp_str

        # Scan calculated fields
        for cf in root.findall("s:calculatedField", NSMAP):
            dp_str = (cf.find("s:dataPath", NSMAP).text or "")
            expr = "".join(cf.find("s:expression", NSMAP).itertext())
            cf_title = cf.find("s:title", NSMAP)
            t = ""
            if cf_title is not None:
                t = get_ml_text(cf_title)
            calc_fields_map[dp_str] = {"expression": expr, "title": t}
            if t and t not in title_map:
                title_map[t] = dp_str

        # Scan resources
        for tf in root.findall("s:totalField", NSMAP):
            dp_str = (tf.find("s:dataPath", NSMAP).text or "")
            expr = (tf.find("s:expression", NSMAP).text or "")
            grp = tf.find("s:group", NSMAP)
            group_str = "(overall)"
            if grp is not None:
                group_str = (grp.text or "")
            if dp_str not in res_fields:
                res_fields[dp_str] = []
            res_fields[dp_str].append({"expression": expr, "group": group_str})

        # --- Resolve name: try dataPath, then exact title, then substring title ---
        target_path = args.Name
        known_paths = set()
        known_paths.update(ds_fields.keys())
        known_paths.update(calc_fields_map.keys())
        known_paths.update(res_fields.keys())
        is_known = args.Name in known_paths

        if not is_known:
            if args.Name in title_map:
                target_path = title_map[args.Name]
            else:
                # Substring match in titles
                matched_title = None
                for key in title_map:
                    if args.Name in key:
                        matched_title = key
                        break
                if matched_title:
                    target_path = title_map[matched_title]
                else:
                    print(f"Field '{args.Name}' not found by dataPath or title", file=sys.stderr)
                    sys.exit(1)

        # --- Build output ---
        title = ""
        if target_path in calc_fields_map and calc_fields_map[target_path]["title"]:
            title = calc_fields_map[target_path]["title"]
        elif target_path in ds_fields and ds_fields[target_path]["title"]:
            title = ds_fields[target_path]["title"]
        title_str = f' "{title}"' if title else ""

        lines.append(f"=== Trace: {target_path}{title_str} ===")
        lines.append("")

        # Dataset origin
        if target_path in ds_fields:
            unique_ds = list(dict.fromkeys(ds_fields[target_path]["datasets"]))
            lines.append(f"Dataset: {', '.join(unique_ds)}")
        else:
            lines.append("Dataset: (schema-level only, not in dataset fields)")

        # Calculated field
        if target_path in calc_fields_map:
            cf = calc_fields_map[target_path]
            lines.append("")
            lines.append("Calculated:")
            for el in cf["expression"].split("\n"):
                lines.append(f"  {el.rstrip()}")

            # Extract operands: find known field names in expression
            operands = []
            all_known = set()
            all_known.update(ds_fields.keys())
            all_known.update(calc_fields_map.keys())
            all_known.discard(target_path)
            # Sort by length descending to match longer names first
            all_known_sorted = sorted(all_known, key=len, reverse=True)

            for field_name in all_known_sorted:
                escaped = re.escape(field_name)
                pattern = f"(?<![\\u0430-\\u044F\\u0410-\\u042F\\u0451\\u0401a-zA-Z0-9_.]){escaped}(?![\\u0430-\\u044F\\u0410-\\u042F\\u0451\\u0401a-zA-Z0-9_.])"
                if re.search(pattern, cf["expression"]):
                    operands.append(field_name)

            if operands:
                lines.append("  Operands:")
                for op in operands:
                    if op in calc_fields_map:
                        lines.append(f"    {op} -> calculated")
                    elif op in ds_fields:
                        op_ds = list(dict.fromkeys(ds_fields[op]["datasets"]))
                        lines.append(f"    {op} -> {', '.join(op_ds)}")
                    else:
                        lines.append(f"    {op}")

        # Resource
        if target_path in res_fields:
            lines.append("")
            lines.append("Resource:")
            for r in res_fields[target_path]:
                lines.append(f"  [{r['group']}] {r['expression']}")

        # Simple dataset field, no calc/resource
        if target_path not in calc_fields_map and target_path not in res_fields:
            if target_path in ds_fields:
                lines.append("")
                lines.append("(direct dataset field, no calculated expression or resource)")

    def show_templates():
        # --- Helper: check if expression is trivial ---
        def is_trivial_expr(param_name, expr):
            e = expr.strip()
            n = param_name.strip()
            if e == n:
                return True
            # Представление(...)
            if e == f"\u041F\u0440\u0435\u0434\u0441\u0442\u0430\u0432\u043B\u0435\u043D\u0438\u0435({n})":
                return True
            return False

        # --- Helper: parse template content (rows/cells) ---
        def get_template_content(tpl_node):
            inner_t = tpl_node.find("s:template", NSMAP)
            if inner_t is None:
                return {"rows": 0, "cells": [], "params": [], "nonTrivial": []}

            rows = inner_t.findall("dcsat:item", NSMAP)
            row_count = len(rows)
            cell_data = []
            for row_idx, row in enumerate(rows, 1):
                row_cells = []
                for cell in row.findall("dcsat:tableCell", NSMAP):
                    field = cell.find("dcsat:item", NSMAP)
                    if field is None:
                        row_cells.append("(empty)")
                        continue
                    val = field.find("dcsat:value", NSMAP)
                    if val is None:
                        row_cells.append("(empty)")
                        continue
                    xsi_type = val.get(f"{{{XSI_NS}}}type", "")
                    if "LocalStringType" in xsi_type:
                        text = get_ml_text(val)
                        if text:
                            row_cells.append(f'"{text}"')
                        else:
                            row_cells.append("(empty)")
                    elif "Parameter" in xsi_type:
                        row_cells.append(f"{{{val.text or ''}}}")
                    else:
                        row_cells.append("(?)")
                cell_data.append({"row": row_idx, "cells": row_cells})

            # Parameters
            param_nodes = tpl_node.findall("s:parameter", NSMAP)
            param_list = []
            non_trivial_list = []
            for p in param_nodes:
                pn = p.find("dcsat:name", NSMAP)
                pe = p.find("dcsat:expression", NSMAP)
                if pn is not None and pe is not None:
                    p_name = (pn.text or "")
                    p_expr = (pe.text or "")
                    param_list.append({"name": p_name, "expression": p_expr})
                    if not is_trivial_expr(p_name, p_expr):
                        non_trivial_list.append({"name": p_name, "expression": p_expr})

            return {
                "rows": row_count,
                "cells": cell_data,
                "params": param_list,
                "nonTrivial": non_trivial_list,
            }

        # --- Build template name -> node index ---
        tpl_index = {}
        for t in root.findall("s:template", NSMAP):
            tn = t.find("s:name", NSMAP)
            if tn is not None:
                tpl_index[(tn.text or "")] = t

        # --- Parse bindings ---
        # Group bindings: groupTemplate + groupHeaderTemplate + groupFooterTemplate
        group_bindings = OrderedDict()

        for gt in root.findall("s:groupTemplate", NSMAP):
            gn = gt.find("s:groupName", NSMAP)
            gf = gt.find("s:groupField", NSMAP)
            gn_str = (gn.text or "") if gn is not None else ((gf.text or "") if gf is not None else "(default)")
            tt = gt.find("s:templateType", NSMAP)
            tn = gt.find("s:template", NSMAP)
            tt_str = (tt.text or "") if tt is not None else "-"
            tn_str = (tn.text or "") if tn is not None else "-"

            if gn_str not in group_bindings:
                group_bindings[gn_str] = []
            group_bindings[gn_str].append({"type": tt_str, "tplName": tn_str})

        for ght in root.findall("s:groupHeaderTemplate", NSMAP):
            gn = ght.find("s:groupName", NSMAP)
            gf = ght.find("s:groupField", NSMAP)
            gn_str = (gn.text or "") if gn is not None else ((gf.text or "") if gf is not None else "(default)")
            tn = ght.find("s:template", NSMAP)
            tn_str = (tn.text or "") if tn is not None else "-"

            if gn_str not in group_bindings:
                group_bindings[gn_str] = []
            group_bindings[gn_str].append({"type": "GroupHeader", "tplName": tn_str})

        for gft in root.findall("s:groupFooterTemplate", NSMAP):
            gn = gft.find("s:groupName", NSMAP)
            gf = gft.find("s:groupField", NSMAP)
            gn_str = (gn.text or "") if gn is not None else ((gf.text or "") if gf is not None else "(default)")
            tn = gft.find("s:template", NSMAP)
            tn_str = (tn.text or "") if tn is not None else "-"

            if gn_str not in group_bindings:
                group_bindings[gn_str] = []
            group_bindings[gn_str].append({"type": "GroupFooter", "tplName": tn_str})

        # Field bindings: fieldTemplate
        field_bindings = OrderedDict()
        field_non_trivial = []

        for ft in root.findall("s:fieldTemplate", NSMAP):
            fn = ft.find("s:field", NSMAP)
            tn = ft.find("s:template", NSMAP)
            if fn is not None and tn is not None:
                f_name = (fn.text or "")
                t_name = (tn.text or "")
                field_bindings[f_name] = t_name
                # Check params for non-trivial expressions
                if t_name in tpl_index:
                    content = get_template_content(tpl_index[t_name])
                    for nt in content["nonTrivial"]:
                        field_non_trivial.append({
                            "field": f_name,
                            "template": t_name,
                            "name": nt["name"],
                            "expression": nt["expression"],
                        })

        total_tpl = len(tpl_index)
        field_count = len(field_bindings)
        group_bind_count = sum(len(v) for v in group_bindings.values())

        if not args.Name:
            # --- MAP mode ---
            lines.append(f"=== Templates ({total_tpl} defined: {field_count} field, {group_bind_count} group) ===")

            # Field bindings
            if field_bindings:
                lines.append("")
                if not field_non_trivial:
                    field_names = list(field_bindings.keys())
                    if len(field_names) <= 8:
                        lines.append(f"Field bindings ({field_count}): {', '.join(field_names)}  (all trivial)")
                    else:
                        lines.append(f"Field bindings ({field_count}): (all trivial)")
                        lines.append(f"  {', '.join(field_names[:8])}, ...")
                else:
                    unique_nt_fields = set(nt["field"] for nt in field_non_trivial)
                    trivial_count = len(field_bindings) - len(unique_nt_fields)
                    lines.append(f"Field bindings ({field_count}, {trivial_count} trivial):")
                    for nt in field_non_trivial:
                        lines.append(f"  {nt['field']}: {nt['name']} = {nt['expression']}")

            # Group bindings
            if group_bindings:
                lines.append("")
                lines.append(f"Group bindings ({group_bind_count}):")
                for g_name, bindings in group_bindings.items():
                    parts = []
                    for b in bindings:
                        info = f"{b['type']} -> {b['tplName']}"
                        if b["tplName"] in tpl_index:
                            content = get_template_content(tpl_index[b["tplName"]])
                            # Check if any cell has content
                            has_content = False
                            for r in content["cells"]:
                                for c in r["cells"]:
                                    if c != "(empty)":
                                        has_content = True
                                        break
                                if has_content:
                                    break
                            info += f" ({content['rows']} rows"
                            if content["params"]:
                                info += f", {len(content['params'])} params"
                            info += ")"
                            if not has_content and not content["params"]:
                                info += " spacer"
                            if content["nonTrivial"]:
                                nt_names = ", ".join(nt["name"] for nt in content["nonTrivial"])
                                info += f" *{nt_names}"
                        parts.append(info)
                    lines.append(f"  {g_name}")
                    for p in parts:
                        lines.append(f"    {p}")

            if field_bindings or group_bindings:
                lines.append("")
                lines.append("Use -Name <group|field> for template details.")
        else:
            # --- DETAIL mode ---
            found = False

            # Check group bindings first
            if args.Name in group_bindings:
                found = True
                bindings = group_bindings[args.Name]
                lines.append(f"=== Templates: {args.Name} ===")
                for b in bindings:
                    lines.append("")
                    t_name = b["tplName"]
                    if t_name not in tpl_index:
                        lines.append(f"{b['type']} -> {t_name}  (template not found)")
                        continue
                    content = get_template_content(tpl_index[t_name])
                    cell_count = sum(len(r["cells"]) for r in content["cells"])
                    lines.append(f"{b['type']} -> {t_name} [{content['rows']} rows, {cell_count} cells]:")

                    for r in content["cells"]:
                        cell_str = " | ".join(r["cells"])
                        lines.append(f"  Row {r['row']}: {cell_str}")

                    if content["nonTrivial"]:
                        lines.append("  Params:")
                        for nt in content["nonTrivial"]:
                            lines.append(f"    {nt['name']} = {nt['expression']}")

            # Check field bindings
            if args.Name in field_bindings:
                if found:
                    lines.append("")
                found = True
                t_name = field_bindings[args.Name]
                lines.append(f"=== Field template: {args.Name} -> {t_name} ===")
                if t_name in tpl_index:
                    content = get_template_content(tpl_index[t_name])
                    cell_count = sum(len(r["cells"]) for r in content["cells"])
                    lines.append(f"[{content['rows']} rows, {cell_count} cells]")

                    for r in content["cells"]:
                        cell_str = " | ".join(r["cells"])
                        lines.append(f"  Row {r['row']}: {cell_str}")

                    if content["nonTrivial"]:
                        lines.append("  Non-trivial params:")
                        for nt in content["nonTrivial"]:
                            lines.append(f"    {nt['name']} = {nt['expression']}")
                    else:
                        lines.append("  (all params trivial)")

            if not found:
                print(f"Group or field '{args.Name}' not found in template bindings", file=sys.stderr)
                sys.exit(1)

    # === Execute mode ===

    mode = args.Mode

    if mode == "overview":
        show_overview()
        show_overview_hints()
    elif mode == "query":
        show_query()
    elif mode == "fields":
        show_fields()
    elif mode == "links":
        show_links()
    elif mode == "calculated":
        show_calculated()
    elif mode == "resources":
        show_resources()
    elif mode == "params":
        show_params()
    elif mode == "variant":
        show_variant()
    elif mode == "trace":
        show_trace()
    elif mode == "templates":
        show_templates()
    elif mode == "full":
        show_overview()
        lines.append("")
        lines.append("--- query ---")
        lines.append("")
        show_query()
        lines.append("")
        lines.append("--- fields ---")
        lines.append("")
        show_fields()
        lines.append("")
        lines.append("--- resources ---")
        lines.append("")
        show_resources()
        lines.append("")
        lines.append("--- params ---")
        lines.append("")
        show_params()
        lines.append("")
        lines.append("--- variant ---")
        lines.append("")
        show_variant()

    # --- Output ---

    result = lines
    total_lines = len(result)

    # OutFile
    if args.OutFile:
        out_path = args.OutFile
        if not os.path.isabs(out_path):
            out_path = os.path.join(os.getcwd(), out_path)
        with open(out_path, "w", encoding="utf-8-sig") as fh:
            fh.write("\n".join(result))
        print(f"Written {total_lines} lines to {args.OutFile}")
        sys.exit(0)

    # Pagination
    if args.Offset > 0:
        if args.Offset >= total_lines:
            print(f"[INFO] Offset {args.Offset} exceeds total lines ({total_lines}). Nothing to show.")
            sys.exit(0)
        result = result[args.Offset:]

    if len(result) > args.Limit:
        shown = result[:args.Limit]
        for line in shown:
            print(line)
        print("")
        print(f"[TRUNCATED] Shown {args.Limit} of {total_lines} lines. Use -Offset {args.Offset + args.Limit} to continue.")
    else:
        for line in result:
            print(line)


if __name__ == "__main__":
    main()
