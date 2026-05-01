#!/usr/bin/env python3
# form-info v1.3 — Analyze 1C managed form structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
from lxml import etree

# --- Namespace map ---

NSMAP = {
    "d": "http://v8.1c.ru/8.3/xcf/logform",
    "v8": "http://v8.1c.ru/8.1/data/core",
    "v8ui": "http://v8.1c.ru/8.1/data/ui",
    "xr": "http://v8.1c.ru/8.3/xcf/readable",
    "xs": "http://www.w3.org/2001/XMLSchema",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "cfg": "http://v8.1c.ru/8.1/data/enterprise/current-config",
    "dcsset": "http://v8.1c.ru/8.1/data-composition-system/settings",
}

# --- Skip elements ---

SKIP_ELEMENTS = {
    "ExtendedTooltip",
    "ContextMenu",
    "AutoCommandBar",
    "SearchStringAddition",
    "ViewStatusAddition",
    "SearchControlAddition",
    "ColumnGroup",
}


# --- Helper: extract multilang text ---

def get_ml_text(node):
    if node is None:
        return ""
    content = node.find("v8:item/v8:content", NSMAP)
    if content is not None and content.text:
        return content.text
    # Fallback: concatenate all text
    text = "".join(node.itertext()).strip()
    if text:
        return text
    return ""


# --- Helper: format type compactly ---

def format_type(type_node):
    if type_node is None or len(type_node) == 0:
        return ""

    type_set = type_node.find("v8:TypeSet", NSMAP)
    if type_set is not None:
        val = type_set.text or ""
        if val.startswith("cfg:"):
            val = val[4:]
        return val

    types = type_node.findall("v8:Type", NSMAP)
    if len(types) == 0:
        return ""

    parts = []
    for t in types:
        raw = t.text or ""
        if raw == "xs:string":
            sq = type_node.find("v8:StringQualifiers/v8:Length", NSMAP)
            length = int(sq.text) if sq is not None and sq.text else 0
            if length > 0:
                parts.append(f"string({length})")
            else:
                parts.append("string")
        elif raw == "xs:decimal":
            nq = type_node.find("v8:NumberQualifiers", NSMAP)
            if nq is not None:
                d = nq.find("v8:Digits", NSMAP)
                f = nq.find("v8:FractionDigits", NSMAP)
                digits = d.text if d is not None and d.text else "0"
                frac = f.text if f is not None and f.text else "0"
                parts.append(f"decimal({digits},{frac})")
            else:
                parts.append("decimal")
        elif raw == "xs:boolean":
            parts.append("boolean")
        elif raw == "xs:dateTime":
            dq = type_node.find("v8:DateQualifiers/v8:DateFractions", NSMAP)
            if dq is not None:
                frac_text = dq.text or ""
                if frac_text == "Date":
                    parts.append("date")
                elif frac_text == "Time":
                    parts.append("time")
                else:
                    parts.append("dateTime")
            else:
                parts.append("dateTime")
        elif raw == "xs:binary":
            parts.append("binary")
        elif raw.startswith("cfg:") or re.match(r'^d\d+p\d+:', raw):
            parts.append(re.sub(r'^(?:cfg|d\d+p\d+):', '', raw))
        elif raw == "v8:ValueTable":
            parts.append("ValueTable")
        elif raw == "v8:ValueTree":
            parts.append("ValueTree")
        elif raw == "v8:ValueListType":
            parts.append("ValueList")
        elif raw == "v8:TypeDescription":
            parts.append("TypeDescription")
        elif raw == "v8:Universal":
            parts.append("Universal")
        elif raw == "v8:FixedArray":
            parts.append("FixedArray")
        elif raw == "v8:FixedStructure":
            parts.append("FixedStructure")
        elif raw == "v8ui:FormattedString":
            parts.append("FormattedString")
        elif raw == "v8ui:Picture":
            parts.append("Picture")
        elif raw == "v8ui:Color":
            parts.append("Color")
        elif raw == "v8ui:Font":
            parts.append("Font")
        elif raw.startswith("dcsset:"):
            parts.append(raw.replace("dcsset:", "DCS."))
        elif raw.startswith("dcssch:"):
            parts.append(raw.replace("dcssch:", "DCS."))
        elif raw.startswith("dcscor:"):
            parts.append(raw.replace("dcscor:", "DCS."))
        else:
            parts.append(raw)

    return " | ".join(parts)


# --- Helper: check if title differs from name ---

def test_title_differs(node, name):
    title_node = node.find("d:Title", NSMAP)
    if title_node is None:
        return None
    title_text = get_ml_text(title_node)
    if not title_text:
        return None
    # Normalize: remove spaces, lowercase
    norm_title = title_text.replace(" ", "").lower()
    norm_name = name.lower()
    if norm_title == norm_name:
        return None
    return title_text


# --- Helper: get events as compact string ---

def get_events_str(node):
    events_node = node.find("d:Events", NSMAP)
    if events_node is None:
        return ""
    evts = []
    for e in events_node.findall("d:Event", NSMAP):
        e_name = e.get("name", "")
        ct = e.get("callType", "")
        if ct:
            evts.append(f"{e_name}[{ct}]")
        else:
            evts.append(e_name)
    if len(evts) == 0:
        return ""
    return " {" + ", ".join(evts) + "}"


# --- Helper: get flags ---

def get_flags(node):
    flags = []
    vis = node.find("d:Visible", NSMAP)
    if vis is not None and vis.text == "false":
        flags.append("visible:false")
    en = node.find("d:Enabled", NSMAP)
    if en is not None and en.text == "false":
        flags.append("enabled:false")
    ro = node.find("d:ReadOnly", NSMAP)
    if ro is not None and ro.text == "true":
        flags.append("ro")
    if len(flags) == 0:
        return ""
    return " [" + ",".join(flags) + "]"


# --- Element type abbreviations ---

def get_element_tag(node):
    local_name = etree.QName(node.tag).localname
    if local_name == "UsualGroup":
        group_node = node.find("d:Group", NSMAP)
        orient = ""
        if group_node is not None:
            g_text = group_node.text or ""
            if g_text == "Vertical":
                orient = ":V"
            elif g_text == "Horizontal":
                orient = ":H"
            elif g_text == "AlwaysHorizontal":
                orient = ":AH"
            elif g_text == "AlwaysVertical":
                orient = ":AV"
        beh = node.find("d:Behavior", NSMAP)
        collapse = ""
        if beh is not None and beh.text == "Collapsible":
            collapse = ",collapse"
        return f"[Group{orient}{collapse}]"
    elif local_name == "InputField":
        return "[Input]"
    elif local_name == "CheckBoxField":
        return "[Check]"
    elif local_name == "LabelDecoration":
        return "[Label]"
    elif local_name == "LabelField":
        return "[LabelField]"
    elif local_name == "PictureDecoration":
        return "[Picture]"
    elif local_name == "PictureField":
        return "[PicField]"
    elif local_name == "CalendarField":
        return "[Calendar]"
    elif local_name == "Table":
        return "[Table]"
    elif local_name == "Button":
        return "[Button]"
    elif local_name == "CommandBar":
        return "[CmdBar]"
    elif local_name == "Pages":
        return "[Pages]"
    elif local_name == "Page":
        return "[Page]"
    elif local_name == "Popup":
        return "[Popup]"
    elif local_name == "ButtonGroup":
        return "[BtnGroup]"
    else:
        return f"[{local_name}]"


# --- Count significant children (for Page summary) ---

def count_significant_children(child_items_node):
    if child_items_node is None:
        return 0
    count = 0
    for child in child_items_node:
        if not isinstance(child.tag, str):
            continue
        ln = etree.QName(child.tag).localname
        if ln in SKIP_ELEMENTS:
            continue
        count += 1
    return count


# --- Build element tree recursively ---

def build_tree(child_items_node, prefix, tree_lines, expand="", state=None):
    if child_items_node is None:
        return

    # Collect significant children
    children = []
    for child in child_items_node:
        if not isinstance(child.tag, str):
            continue
        ln = etree.QName(child.tag).localname
        if ln in SKIP_ELEMENTS:
            continue
        children.append(child)

    for i, child in enumerate(children):
        last = (i == len(children) - 1)
        connector = "\u2514\u2500" if last else "\u251C\u2500"
        continuation = "  " if last else "\u2502 "

        tag = get_element_tag(child)
        name = child.get("name", "")
        flags = get_flags(child)
        events = get_events_str(child)

        # DataPath or CommandName
        binding = ""
        dp = child.find("d:DataPath", NSMAP)
        if dp is not None and dp.text:
            binding = f" -> {dp.text}"
        else:
            cn = child.find("d:CommandName", NSMAP)
            if cn is not None and cn.text:
                cn_val = cn.text
                m = re.match(r'^Form\.StandardCommand\.(.+)$', cn_val)
                if m:
                    binding = f" -> {m.group(1)} [std]"
                else:
                    m = re.match(r'^Form\.Command\.(.+)$', cn_val)
                    if m:
                        binding = f" -> {m.group(1)} [cmd]"
                    else:
                        binding = f" -> {cn_val}"

        # Title differs?
        title_str = ""
        diff_title = test_title_differs(child, name)
        if diff_title:
            title_str = f" [title:{diff_title}]"

        line = f"{prefix}{connector} {tag} {name}{binding}{flags}{title_str}{events}"
        tree_lines.append(line)

        # Recurse into containers (but not Page -- show summary unless expanded)
        local_name = etree.QName(child.tag).localname
        if local_name == "Page":
            ci = child.find("d:ChildItems", NSMAP)
            page_name = child.get("name", "")
            page_title = test_title_differs(child, page_name)
            should_expand = (expand == "*") or (expand == page_name) or (page_title and expand == page_title)
            if should_expand and ci is not None:
                build_tree(ci, prefix + continuation, tree_lines, expand, state)
            else:
                cnt = count_significant_children(ci)
                tree_lines[-1] = tree_lines[-1] + f" ({cnt} items)"
                if state is not None:
                    state["has_collapsed"] = True
        elif local_name in ("UsualGroup", "Pages", "Table", "CommandBar", "ButtonGroup", "Popup"):
            ci = child.find("d:ChildItems", NSMAP)
            if ci is not None:
                build_tree(ci, prefix + continuation, tree_lines, expand, state)


# --- Main ---

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Analyze 1C managed form structure", allow_abbrev=False)
    parser.add_argument("-FormPath", "-Path", required=True, help="Path to Form.xml")
    parser.add_argument("-Limit", type=int, default=150, help="Max lines to show")
    parser.add_argument("-Offset", type=int, default=0, help="Line offset for pagination")
    parser.add_argument("-Expand", default="", help="Expand collapsed section by name, or * for all")
    args = parser.parse_args()

    form_path = args.FormPath
    limit = args.Limit
    offset = args.Offset
    expand = args.Expand

    # --- Resolve FormPath ---
    if not os.path.isabs(form_path):
        form_path = os.path.join(os.getcwd(), form_path)
    # A: Directory → Ext/Form.xml
    if os.path.isdir(form_path):
        form_path = os.path.join(form_path, "Ext", "Form.xml")
    # B1: Missing Ext/ (Forms/Форма/Form.xml → Forms/Форма/Ext/Form.xml)
    if not os.path.isfile(form_path):
        fn = os.path.basename(form_path)
        if fn == "Form.xml":
            c = os.path.join(os.path.dirname(form_path), "Ext", fn)
            if os.path.isfile(c):
                form_path = c
    # B2: Descriptor (Forms/Форма.xml → Forms/Форма/Ext/Form.xml)
    if not os.path.isfile(form_path) and form_path.endswith(".xml"):
        stem = os.path.splitext(os.path.basename(form_path))[0]
        parent = os.path.dirname(form_path)
        c = os.path.join(parent, stem, "Ext", "Form.xml")
        if os.path.isfile(c):
            form_path = c

    if not os.path.isfile(form_path):
        print(f"File not found: {form_path}", file=sys.stderr)
        sys.exit(1)

    # --- Load XML ---
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(form_path, parser_xml)
    root = tree.getroot()

    # --- Detect extension (BaseForm) ---
    base_form_node = root.find("d:BaseForm", NSMAP)
    is_extension = base_form_node is not None

    # --- Determine form name and object from path ---
    resolved_path = os.path.abspath(form_path)
    parts = resolved_path.replace("\\", "/").split("/")

    form_name = ""
    object_context = ""

    # Look for /Forms/<FormName>/Ext/Form.xml pattern
    forms_idx = -1
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "Forms":
            forms_idx = i
            break

    if forms_idx >= 0 and (forms_idx + 1) < len(parts):
        form_name = parts[forms_idx + 1]
        # Object is 2 levels up: .../<ObjectType>/<ObjectName>/Forms/...
        if forms_idx >= 2:
            obj_type = parts[forms_idx - 2]
            obj_name = parts[forms_idx - 1]
            object_context = f"{obj_type}.{obj_name}"
    else:
        # CommonForms pattern: .../<ObjectType>/<FormName>/Ext/Form.xml
        ext_idx = -1
        for i in range(len(parts) - 1, -1, -1):
            if parts[i] == "Ext":
                ext_idx = i
                break
        if ext_idx >= 2:
            form_name = parts[ext_idx - 1]
            obj_type = parts[ext_idx - 2]
            object_context = obj_type
        else:
            form_name = os.path.splitext(os.path.basename(form_path))[0]

    # --- Collect output ---
    lines = []

    # Header -- include Title if present
    title_node = root.find("d:Title", NSMAP)
    form_title = None
    if title_node is not None:
        form_title = get_ml_text(title_node)
        if not form_title:
            form_title = "".join(title_node.itertext()).strip() or None

    ext_marker = " [EXTENSION]" if is_extension else ""
    header = f"=== Form: {form_name}{ext_marker}"
    if form_title:
        header += f' — "{form_title}"'
    if object_context:
        header += f" ({object_context})"
    header += " ==="
    lines.append(header)

    # --- Form properties (Title excluded -- shown in header) ---
    prop_names = [
        "Width", "Height", "Group",
        "WindowOpeningMode", "EnterKeyBehavior", "AutoTitle", "AutoURL",
        "AutoFillCheck", "Customizable", "CommandBarLocation",
        "SaveDataInSettings", "AutoSaveDataInSettings",
        "AutoTime", "UsePostingMode", "RepostOnWrite",
        "UseForFoldersAndItems",
        "ReportResult", "DetailsData", "ReportFormType",
        "VerticalScroll", "ScalingMode",
    ]

    props = []
    for pn in prop_names:
        p_node = root.find(f"d:{pn}", NSMAP)
        if p_node is not None:
            val = get_ml_text(p_node)
            if not val:
                val = "".join(p_node.itertext()).strip()
            props.append(f"{pn}={val}")

    if len(props) > 0:
        lines.append("")
        lines.append("Properties: " + ", ".join(props))

    # --- Excluded commands ---
    excluded_cmds = []
    for ec in root.findall("d:CommandSet/d:ExcludedCommand", NSMAP):
        excluded_cmds.append(ec.text or "")

    # --- Form events ---
    form_events = root.find("d:Events", NSMAP)
    if form_events is not None and len(form_events) > 0:
        lines.append("")
        lines.append("Events:")
        for e in form_events.findall("d:Event", NSMAP):
            e_name = e.get("name", "")
            e_handler = e.text or ""
            ct = e.get("callType", "")
            ct_str = f"[{ct}]" if ct else ""
            lines.append(f"  {e_name}{ct_str} -> {e_handler}")

    # --- Main AutoCommandBar (form's id=-1 panel) ---
    def format_main_acb(acb_node):
        if acb_node is None:
            return []
        autofill_node = acb_node.find("d:Autofill", NSMAP)
        autofill = not (autofill_node is not None and autofill_node.text == "false")
        halign_node = acb_node.find("d:HorizontalAlign", NSMAP)
        flags = ["autofill" if autofill else "no-autofill"]
        if halign_node is not None and halign_node.text:
            flags.append(f"align={halign_node.text}")
        ci_node = acb_node.find("d:ChildItems", NSMAP)
        buttons = []
        if ci_node is not None:
            for btn in ci_node:
                if not isinstance(btn.tag, str):
                    continue
                ln = etree.QName(btn).localname
                if ln in SKIP_ELEMENTS:
                    continue
                b_name = btn.get("name", "")
                cmd_node = btn.find("d:CommandName", NSMAP)
                cmd_ref = cmd_node.text if cmd_node is not None and cmd_node.text else ""
                loc_node = btn.find("d:LocationInCommandBar", NSMAP)
                loc_str = f" [{loc_node.text}]" if loc_node is not None and loc_node.text else ""
                tag = get_element_tag(btn)
                if cmd_ref:
                    buttons.append(f"  {tag} {b_name} -> {cmd_ref}{loc_str}")
                else:
                    buttons.append(f"  {tag} {b_name}{loc_str}")
        if not buttons and autofill and halign_node is None:
            return ["AutoCommandBar [autofill]"]
        return [f"AutoCommandBar [{', '.join(flags)}]"] + buttons

    cb_loc_node = root.find("d:CommandBarLocation", NSMAP)
    cb_loc = cb_loc_node.text if cb_loc_node is not None and cb_loc_node.text else "Auto"
    main_acb_node = root.find("d:AutoCommandBar", NSMAP)
    acb_lines = []
    if cb_loc != "None" and main_acb_node is not None:
        acb_lines = format_main_acb(main_acb_node)

    if acb_lines and cb_loc in ("Auto", "Top"):
        lines.append("")
        lines.extend(acb_lines)

    # --- Element tree ---
    tree_state = {"has_collapsed": False}
    child_items = root.find("d:ChildItems", NSMAP)
    if child_items is not None:
        lines.append("")
        lines.append("Elements:")
        tree_lines = []
        build_tree(child_items, "  ", tree_lines, expand, tree_state)
        lines.extend(tree_lines)

    if acb_lines and cb_loc == "Bottom":
        lines.append("")
        lines.extend(acb_lines)

    # --- Attributes ---
    attrs_node = root.find("d:Attributes", NSMAP)
    if attrs_node is not None:
        attr_lines = []
        for attr in attrs_node.findall("d:Attribute", NSMAP):
            a_name = attr.get("name", "")
            type_node = attr.find("d:Type", NSMAP)
            type_str = format_type(type_node)

            main_attr = attr.find("d:MainAttribute", NSMAP)
            is_main = main_attr is not None and main_attr.text == "true"

            prefix_char = "*" if is_main else " "
            main_suffix = " (main)" if is_main else ""

            # DynamicList: show MainTable
            settings = attr.find("d:Settings", NSMAP)
            dyn_table = ""
            if settings is not None and type_str == "DynamicList":
                mt = settings.find("d:MainTable", NSMAP)
                if mt is not None and mt.text:
                    dyn_table = f" -> {mt.text}"

            # ValueTable/ValueTree columns
            col_str = ""
            columns = attr.find("d:Columns", NSMAP)
            if columns is not None and type_str in ("ValueTable", "ValueTree"):
                cols = []
                for col in columns.findall("d:Column", NSMAP):
                    c_name = col.get("name", "")
                    c_type_node = col.find("d:Type", NSMAP)
                    c_type = format_type(c_type_node)
                    if c_type:
                        cols.append(f"{c_name}: {c_type}")
                    else:
                        cols.append(c_name)
                if len(cols) > 0:
                    col_str = " [" + ", ".join(cols) + "]"

            if type_str or col_str or dyn_table:
                line = f"  {prefix_char}{a_name}: {type_str}{col_str}{dyn_table}{main_suffix}"
            else:
                line = f"  {prefix_char}{a_name}{main_suffix}"
            attr_lines.append(line)

        if len(attr_lines) > 0:
            lines.append("")
            lines.append("Attributes:")
            lines.extend(attr_lines)

    # --- Parameters ---
    params_node = root.find("d:Parameters", NSMAP)
    if params_node is not None:
        param_lines = []
        for param in params_node.findall("d:Parameter", NSMAP):
            p_name = param.get("name", "")
            type_node = param.find("d:Type", NSMAP)
            type_str = format_type(type_node)

            key_param = param.find("d:KeyParameter", NSMAP)
            is_key = key_param is not None and key_param.text == "true"
            key_suffix = " (key)" if is_key else ""

            if type_str:
                param_lines.append(f"  {p_name}: {type_str}{key_suffix}")
            else:
                param_lines.append(f"  {p_name}{key_suffix}")

        if len(param_lines) > 0:
            lines.append("")
            lines.append("Parameters:")
            lines.extend(param_lines)

    # --- Commands ---
    cmds_node = root.find("d:Commands", NSMAP)
    if cmds_node is not None:
        cmd_lines = []
        for cmd in cmds_node.findall("d:Command", NSMAP):
            c_name = cmd.get("name", "")
            shortcut = cmd.find("d:Shortcut", NSMAP)
            sc_str = f" [{shortcut.text}]" if shortcut is not None and shortcut.text else ""

            # Collect all Action elements (may have multiple with callType)
            actions = cmd.findall("d:Action", NSMAP)
            if len(actions) > 1:
                act_parts = []
                for a in actions:
                    ct = a.get("callType", "")
                    ct_str = f"[{ct}]" if ct else ""
                    act_parts.append(f"{a.text or ''}{ct_str}")
                action_str = " -> " + ", ".join(act_parts)
            elif len(actions) == 1:
                ct = actions[0].get("callType", "")
                ct_str = f"[{ct}]" if ct else ""
                action_str = f" -> {actions[0].text or ''}{ct_str}"
            else:
                action_str = ""

            cmd_lines.append(f"  {c_name}{action_str}{sc_str}")

        if len(cmd_lines) > 0:
            lines.append("")
            lines.append("Commands:")
            lines.extend(cmd_lines)

    # --- BaseForm footer ---
    if is_extension:
        bf_version = base_form_node.get("version", "")
        bf_str = f"present (version {bf_version})" if bf_version else "present"
        lines.append("")
        lines.append(f"BaseForm: {bf_str}")

    # --- Expand hint ---
    if tree_state["has_collapsed"]:
        lines.append("")
        lines.append("Hint: use -Expand <name> to expand a collapsed section, -Expand * for all")

    # --- Truncation protection ---
    total_lines = len(lines)

    if offset > 0:
        if offset >= total_lines:
            print(f"[INFO] Offset {offset} exceeds total lines ({total_lines}). Nothing to show.")
            sys.exit(0)
        lines = lines[offset:]

    if len(lines) > limit:
        shown = lines[:limit]
        for l in shown:
            print(l)
        remaining = total_lines - offset - limit
        print("")
        print(f"[TRUNCATED] Shown {limit} of {total_lines} lines. Use -Offset {offset + limit} to continue.")
    else:
        for l in lines:
            print(l)


if __name__ == "__main__":
    main()
