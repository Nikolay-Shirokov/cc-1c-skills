#!/usr/bin/env python3
# subsystem-info v1.0 — Compact summary of 1C subsystem structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
from collections import OrderedDict
from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# --- Argument parsing ---
parser = argparse.ArgumentParser(description="Analyze 1C subsystem structure", allow_abbrev=False)
parser.add_argument("-SubsystemPath", "-Path", required=True, help="Path to subsystem XML or Subsystems/ directory")
parser.add_argument("-Mode", choices=["overview", "content", "ci", "tree", "full"], default="overview", help="Output mode")
parser.add_argument("-Name", default="", help="Filter by name/type")
parser.add_argument("-Limit", type=int, default=150, help="Max lines to show")
parser.add_argument("-Offset", type=int, default=0, help="Lines to skip")
parser.add_argument("-OutFile", default="", help="Write output to file")
args = parser.parse_args()

# --- Output helper ---
lines_buf = []

def out(text=""):
    lines_buf.append(text)

# --- Resolve path ---
subsystem_path = args.SubsystemPath
if not os.path.isabs(subsystem_path):
    subsystem_path = os.path.join(os.getcwd(), subsystem_path)

NS = {
    "md": "http://v8.1c.ru/8.3/MDClasses",
    "v8": "http://v8.1c.ru/8.1/data/core",
    "xr": "http://v8.1c.ru/8.3/xcf/readable",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
}

CI_NS = {
    "ci": "http://v8.1c.ru/8.3/xcf/extrnprops",
    "xr": "http://v8.1c.ru/8.3/xcf/readable",
}

# --- Helper: get LocalString text ---
def get_ml_text(node):
    if node is None:
        return ""
    # Look for v8:item children
    for item in node:
        if not isinstance(item.tag, str):
            continue
        lang = ""
        content = ""
        for c in item:
            if not isinstance(c.tag, str):
                continue
            local = etree.QName(c.tag).localname
            if local == "lang":
                lang = c.text or ""
            if local == "content":
                content = c.text or ""
        if lang == "ru" and content:
            return content
    # fallback: first item
    for item in node:
        if not isinstance(item.tag, str):
            continue
        for c in item:
            if not isinstance(c.tag, str):
                continue
            local = etree.QName(c.tag).localname
            if local == "content" and c.text:
                return c.text
    return ""

# --- Helper: load subsystem XML ---
def load_subsystem_xml(xml_path):
    tree = etree.parse(xml_path, etree.XMLParser(remove_blank_text=False))
    doc_root = tree.getroot()
    sub = doc_root.find("md:Subsystem", NS)
    if sub is None:
        print(f"[ERROR] Not a valid subsystem XML: {xml_path}", file=sys.stderr)
        sys.exit(1)
    return {"Doc": doc_root, "Sub": sub}

# --- Helper: get content items ---
def get_content_items(props):
    items = []
    content_node = props.find("md:Content", NS)
    if content_node is None:
        return items
    for item in content_node.findall("xr:Item", NS):
        if item.text:
            items.append(item.text)
    return items

# --- Helper: get child subsystem names ---
def get_child_names(sub):
    names = []
    co = sub.find("md:ChildObjects", NS)
    if co is None:
        return names
    for child in co:
        if not isinstance(child.tag, str):
            continue
        if etree.QName(child.tag).localname == "Subsystem":
            names.append(child.text or "")
    return names

# --- Helper: group content by type ---
def group_content_by_type(items):
    groups = OrderedDict()
    for item in items:
        m = re.match(r'^([^.]+)\.(.+)$', item)
        if m:
            type_name = m.group(1)
            name = m.group(2)
        elif re.match(r'^[0-9a-fA-F]{8}-', item):
            type_name = "[UUID]"
            name = item
        else:
            type_name = "[Other]"
            name = item
        if type_name not in groups:
            groups[type_name] = []
        groups[type_name].append(name)
    return groups

# --- Helper: find subsystem dir from XML path ---
def get_subsystem_dir(xml_path):
    dir_name = os.path.dirname(xml_path)
    base_name = os.path.splitext(os.path.basename(xml_path))[0]
    return os.path.join(dir_name, base_name)

# --- Show functions ---
def show_overview(sub_name, synonym, comment_text, incl_ci, use_one_cmd,
                  explanation, pic_text, content_items, groups, child_names, has_ci):
    out(f"Подсистема: {sub_name}")
    if synonym and synonym != sub_name:
        out(f"Синоним: {synonym}")
    if comment_text:
        out(f"Комментарий: {comment_text}")
    out(f"ВключатьВКомандныйИнтерфейс: {incl_ci}")
    out(f"ИспользоватьОднуКоманду: {use_one_cmd}")
    if explanation:
        out(f"Пояснение: {explanation}")
    if pic_text:
        out(f"Картинка: {pic_text}")
    if len(content_items) > 0:
        parts = []
        for type_name in groups:
            parts.append(f"{type_name}: {len(groups[type_name])}")
        out(f"Состав: {len(content_items)} объектов ({', '.join(parts)})")
    else:
        out("Состав: пусто")
    if len(child_names) > 0:
        out(f"Дочерние подсистемы ({len(child_names)}): {', '.join(child_names)}")
    if has_ci:
        out("Командный интерфейс: есть")


def show_content(sub_name, content_items, groups, name_filter):
    out(f"Состав подсистемы {sub_name} ({len(content_items)} объектов):")
    out()
    if name_filter:
        if name_filter in groups:
            filtered = groups[name_filter]
            out(f"{name_filter} ({len(filtered)}):")
            for n in filtered:
                out(f"  {n}")
        else:
            out(f"[INFO] Тип '{name_filter}' не найден в составе.")
            out(f"Доступные типы: {', '.join(groups.keys())}")
    else:
        for type_name in groups:
            out(f"{type_name} ({len(groups[type_name])}):")
            for n in groups[type_name]:
                out(f"  {n}")
            out()


def show_ci(sub_name, subsystem_path_local):
    local_sub_dir = get_subsystem_dir(subsystem_path_local)
    local_ci_path = os.path.join(local_sub_dir, "Ext", "CommandInterface.xml")

    if not os.path.isfile(local_ci_path):
        out(f"Командный интерфейс: {sub_name}")
        out()
        out("Файл CommandInterface.xml не найден.")
        out(f"Путь: {local_ci_path}")
    else:
        ci_tree = etree.parse(local_ci_path, etree.XMLParser(remove_blank_text=False))
        ci_root = ci_tree.getroot()

        out(f"Командный интерфейс: {sub_name}")
        out()

        # --- CommandsVisibility ---
        vis_section = ci_root.find("ci:CommandsVisibility", CI_NS)
        if vis_section is not None:
            hidden = []
            shown = []
            for cmd in vis_section.findall("ci:Command", CI_NS):
                cmd_name = cmd.get("name", "")
                vis = cmd.find("ci:Visibility/xr:Common", CI_NS)
                if vis is not None and vis.text == "false":
                    hidden.append(cmd_name)
                else:
                    shown.append(cmd_name)
            total = len(hidden) + len(shown)
            if not args.Name or args.Name == "visibility":
                out(f"Видимость ({total}):")
                if hidden:
                    out(f"  СКРЫТО ({len(hidden)}):")
                    for h in hidden:
                        out(f"    {h}")
                if shown:
                    out(f"  ПОКАЗАНО ({len(shown)}):")
                    for s in shown:
                        out(f"    {s}")
                out()

        # --- CommandsPlacement ---
        place_section = ci_root.find("ci:CommandsPlacement", CI_NS)
        if place_section is not None:
            placements = []
            for cmd in place_section.findall("ci:Command", CI_NS):
                cmd_name = cmd.get("name", "")
                grp = cmd.find("ci:CommandGroup", CI_NS)
                pl = cmd.find("ci:Placement", CI_NS)
                grp_text = grp.text if grp is not None and grp.text else "?"
                pl_text = pl.text if pl is not None and pl.text else "?"
                placements.append({"Name": cmd_name, "Group": grp_text, "Placement": pl_text})
            if (not args.Name or args.Name == "placement") and placements:
                arrow = "\u2192"
                out(f"Размещение ({len(placements)}):")
                for p in placements:
                    out(f"  {p['Name']} {arrow} {p['Group']} ({p['Placement']})")
                out()

        # --- CommandsOrder ---
        order_section = ci_root.find("ci:CommandsOrder", CI_NS)
        if order_section is not None:
            order_groups = OrderedDict()
            for cmd in order_section.findall("ci:Command", CI_NS):
                cmd_name = cmd.get("name", "")
                grp = cmd.find("ci:CommandGroup", CI_NS)
                grp_text = grp.text if grp is not None and grp.text else "?"
                if grp_text not in order_groups:
                    order_groups[grp_text] = []
                order_groups[grp_text].append(cmd_name)
            total_order = sum(len(v) for v in order_groups.values())
            if (not args.Name or args.Name == "order") and total_order > 0:
                out(f"Порядок команд ({total_order}):")
                for grp_name, cmds in order_groups.items():
                    out(f"  [{grp_name}]:")
                    for c in cmds:
                        out(f"    {c}")
                out()

        # --- SubsystemsOrder ---
        sub_order_section = ci_root.find("ci:SubsystemsOrder", CI_NS)
        if sub_order_section is not None:
            sub_order = []
            for s in sub_order_section.findall("ci:Subsystem", CI_NS):
                if s.text:
                    sub_order.append(s.text)
            if (not args.Name or args.Name == "subsystems") and sub_order:
                out(f"Порядок подсистем ({len(sub_order)}):")
                for i, s in enumerate(sub_order):
                    out(f"  {i + 1}. {s}")
                out()

        # --- GroupsOrder ---
        grp_order_section = ci_root.find("ci:GroupsOrder", CI_NS)
        if grp_order_section is not None:
            grp_order = []
            for g in grp_order_section.findall("ci:Group", CI_NS):
                if g.text:
                    grp_order.append(g.text)
            if (not args.Name or args.Name == "groups") and grp_order:
                out(f"Порядок групп ({len(grp_order)}):")
                for g in grp_order:
                    out(f"  {g}")


# ============================================================
# Mode: tree
# ============================================================
if args.Mode == "tree":
    is_dir = os.path.isdir(subsystem_path)
    root_dir = None
    root_xml = None

    if is_dir:
        root_dir = subsystem_path
    else:
        if not os.path.isfile(subsystem_path):
            print(f"[ERROR] File not found: {subsystem_path}", file=sys.stderr)
            sys.exit(1)
        root_xml = subsystem_path

    # Box-drawing chars
    T_BRANCH = "\u251C\u2500\u2500 "   # ├──
    T_LAST   = "\u2514\u2500\u2500 "   # └──
    T_PIPE   = "\u2502   "             # │
    T_ARROW  = "\u2192"                # →

    def get_tree_line(xml_path):
        parsed = load_subsystem_xml(xml_path)
        sub = parsed["Sub"]
        props = sub.find("md:Properties", NS)
        name_node = props.find("md:Name", NS)
        name = name_node.text if name_node is not None else ""

        markers = []
        sub_dir = get_subsystem_dir(xml_path)
        ci_path = os.path.join(sub_dir, "Ext", "CommandInterface.xml")
        if os.path.isfile(ci_path):
            markers.append("CI")
        use_one = props.find("md:UseOneCommand", NS)
        if use_one is not None and use_one.text == "true":
            markers.append("OneCmd")
        incl_ci_node = props.find("md:IncludeInCommandInterface", NS)
        if incl_ci_node is not None and incl_ci_node.text == "false":
            markers.append("Скрыт")
        marker_str = f" [{', '.join(markers)}]" if markers else ""

        content_items = get_content_items(props)
        child_names = get_child_names(sub)
        child_str = f", {len(child_names)} дочерних" if child_names else ""

        return {
            "Label": f"{name}{marker_str} ({len(content_items)} объектов{child_str})",
            "SubDir": sub_dir,
            "ChildNames": child_names,
        }

    def build_tree_entry(xml_path, prefix, is_last, is_root):
        info = get_tree_line(xml_path)

        if is_root:
            connector = ""
        elif is_last:
            connector = T_LAST
        else:
            connector = T_BRANCH
        out(f"{prefix}{connector}{info['Label']}")

        if info["ChildNames"]:
            if is_root:
                child_prefix = ""
            elif is_last:
                child_prefix = prefix + "    "
            else:
                child_prefix = prefix + T_PIPE

            subs_dir = os.path.join(info["SubDir"], "Subsystems")
            for i, child_name in enumerate(info["ChildNames"]):
                child_xml = os.path.join(subs_dir, f"{child_name}.xml")
                child_is_last = (i == len(info["ChildNames"]) - 1)
                if os.path.isfile(child_xml):
                    build_tree_entry(child_xml, child_prefix, child_is_last, False)
                else:
                    conn2 = T_LAST if child_is_last else T_BRANCH
                    out(f"{child_prefix}{conn2}{child_name} [NOT FOUND]")

    if root_dir:
        label = os.path.basename(root_dir)
        out(f"Дерево подсистем от: {label}/")
        out()
        xml_files = sorted(
            [f for f in os.listdir(root_dir) if f.lower().endswith(".xml") and os.path.isfile(os.path.join(root_dir, f))],
            key=lambda x: x.lower()
        )
        if args.Name:
            xml_files = [f for f in xml_files if os.path.splitext(f)[0] == args.Name]
            if not xml_files:
                print(f"[ERROR] Subsystem '{args.Name}' not found in {root_dir}", file=sys.stderr)
                sys.exit(1)
        for i, fname in enumerate(xml_files):
            build_tree_entry(os.path.join(root_dir, fname), "", i == len(xml_files) - 1, True)
    else:
        build_tree_entry(root_xml, "", True, True)

elif args.Mode == "ci":
    # ============================================================
    # Mode: ci -- CommandInterface.xml
    # ============================================================
    if os.path.isdir(subsystem_path):
        print("[ERROR] ci mode requires a subsystem .xml file, not a directory", file=sys.stderr)
        sys.exit(1)
    # File not found -- check Dir/Name/Name.xml -> Dir/Name.xml
    if not os.path.isfile(subsystem_path):
        fn = os.path.splitext(os.path.basename(subsystem_path))[0]
        pd = os.path.dirname(subsystem_path)
        if fn == os.path.basename(pd):
            c = os.path.join(os.path.dirname(pd), f"{fn}.xml")
            if os.path.isfile(c):
                subsystem_path = c
    if not os.path.isfile(subsystem_path):
        print(f"[ERROR] File not found: {subsystem_path}", file=sys.stderr)
        sys.exit(1)

    parsed = load_subsystem_xml(subsystem_path)
    sub = parsed["Sub"]
    props = sub.find("md:Properties", NS)
    name_node = props.find("md:Name", NS)
    sub_name = name_node.text if name_node is not None else ""

    show_ci(sub_name, subsystem_path)

else:
    # ============================================================
    # Mode: overview / content / full -- requires a subsystem XML file
    # ============================================================
    if os.path.isdir(subsystem_path):
        dir_name = os.path.basename(subsystem_path)
        candidate = os.path.join(subsystem_path, f"{dir_name}.xml")
        sibling = os.path.join(os.path.dirname(subsystem_path), f"{dir_name}.xml")
        if os.path.isfile(candidate):
            subsystem_path = candidate
        elif os.path.isfile(sibling):
            subsystem_path = sibling
        else:
            print(f"[ERROR] No {dir_name}.xml found in directory. Use -Mode tree for directory listing.", file=sys.stderr)
            sys.exit(1)

    # File not found -- check Dir/Name/Name.xml -> Dir/Name.xml
    if not os.path.isfile(subsystem_path):
        fn = os.path.splitext(os.path.basename(subsystem_path))[0]
        pd = os.path.dirname(subsystem_path)
        if fn == os.path.basename(pd):
            c = os.path.join(os.path.dirname(pd), f"{fn}.xml")
            if os.path.isfile(c):
                subsystem_path = c
    if not os.path.isfile(subsystem_path):
        print(f"[ERROR] File not found: {subsystem_path}", file=sys.stderr)
        sys.exit(1)

    parsed = load_subsystem_xml(subsystem_path)
    sub = parsed["Sub"]
    props = sub.find("md:Properties", NS)

    name_node = props.find("md:Name", NS)
    sub_name = name_node.text if name_node is not None else ""
    synonym = get_ml_text(props.find("md:Synonym", NS))
    comment_node = props.find("md:Comment", NS)
    comment_text = comment_node.text if comment_node is not None and comment_node.text else ""
    incl_help_node = props.find("md:IncludeHelpInContents", NS)
    incl_help = incl_help_node.text if incl_help_node is not None else ""
    incl_ci_node = props.find("md:IncludeInCommandInterface", NS)
    incl_ci = incl_ci_node.text if incl_ci_node is not None else ""
    use_one_cmd_node = props.find("md:UseOneCommand", NS)
    use_one_cmd = use_one_cmd_node.text if use_one_cmd_node is not None else ""
    explanation = get_ml_text(props.find("md:Explanation", NS))

    # Picture
    pic_node = props.find("md:Picture", NS)
    pic_text = ""
    if pic_node is not None and len(pic_node) > 0:
        pic_ref = pic_node.find("xr:Ref", NS)
        if pic_ref is not None and pic_ref.text:
            pic_text = pic_ref.text

    # Content
    content_items = get_content_items(props)
    groups = group_content_by_type(content_items)

    # Children
    child_names = get_child_names(sub)

    # CI presence
    sub_dir = get_subsystem_dir(subsystem_path)
    ci_path = os.path.join(sub_dir, "Ext", "CommandInterface.xml")
    has_ci = os.path.isfile(ci_path)

    if args.Mode == "overview":
        show_overview(sub_name, synonym, comment_text, incl_ci, use_one_cmd,
                      explanation, pic_text, content_items, groups, child_names, has_ci)
    elif args.Mode == "content":
        show_content(sub_name, content_items, groups, args.Name)
    elif args.Mode == "full":
        show_overview(sub_name, synonym, comment_text, incl_ci, use_one_cmd,
                      explanation, pic_text, content_items, groups, child_names, has_ci)
        out()
        out("--- content ---")
        out()
        show_content(sub_name, content_items, groups, args.Name)
        out()
        out("--- ci ---")
        out()
        show_ci(sub_name, subsystem_path)

# --- Pagination and output ---
total_lines = len(lines_buf)
out_lines = lines_buf[:]

if args.Offset > 0:
    if args.Offset >= total_lines:
        print(f"[INFO] Offset {args.Offset} exceeds total lines ({total_lines}). Nothing to show.")
        sys.exit(0)
    out_lines = out_lines[args.Offset:]

if args.Limit > 0 and len(out_lines) > args.Limit:
    shown = out_lines[:args.Limit]
    remaining = total_lines - args.Offset - args.Limit
    shown.append("")
    shown.append(f"[ОБРЕЗАНО] Показано {args.Limit} из {total_lines} строк. Используйте -Offset {args.Offset + args.Limit} для продолжения.")
    out_lines = shown

if args.OutFile:
    out_file = args.OutFile
    if not os.path.isabs(out_file):
        out_file = os.path.join(os.getcwd(), out_file)
    with open(out_file, "w", encoding="utf-8-sig") as f:
        f.write("\n".join(out_lines))
    print(f"Output written to {out_file}")
else:
    for line in out_lines:
        print(line)
