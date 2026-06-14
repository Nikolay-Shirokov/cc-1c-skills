#!/usr/bin/env python3
# role-info v1.0 — Analyze 1C role rights
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import sys
from collections import OrderedDict
from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# --- Argument parsing ---
parser = argparse.ArgumentParser(description="Analyze 1C role rights", allow_abbrev=False)
parser.add_argument("-RightsPath", "-Path", required=True, help="Path to Rights.xml")
parser.add_argument("-ShowDenied", action="store_true", default=False, help="Show denied rights")
parser.add_argument("-Limit", type=int, default=150, help="Max lines to show")
parser.add_argument("-Offset", type=int, default=0, help="Lines to skip")
parser.add_argument("-OutFile", default="", help="Write output to file")
args = parser.parse_args()

# --- Output helper (collect all, paginate at the end) ---
lines_buf = []

def out(text=""):
    lines_buf.append(text)

# --- Resolve paths ---
rights_path = args.RightsPath
if not os.path.isabs(rights_path):
    rights_path = os.path.join(os.getcwd(), rights_path)

if not os.path.isfile(rights_path):
    print(f"[ERROR] File not found: {rights_path}", file=sys.stderr)
    sys.exit(1)

# --- Try to find metadata file for role name/synonym ---
role_name = ""
role_synonym = ""
ext_dir = os.path.dirname(rights_path)        # .../Ext
role_dir = os.path.dirname(ext_dir)            # .../RoleName
roles_dir = os.path.dirname(role_dir)          # .../Roles
role_folder_name = os.path.basename(role_dir)
meta_path = os.path.join(roles_dir, f"{role_folder_name}.xml")

if os.path.isfile(meta_path):
    try:
        meta_tree = etree.parse(meta_path, etree.XMLParser(remove_blank_text=False))
        meta_root = meta_tree.getroot()
        meta_ns = {
            "md": "http://v8.1c.ru/8.3/MDClasses",
            "v8": "http://v8.1c.ru/8.1/data/core",
        }
        name_node = meta_root.find(".//md:Role/md:Properties/md:Name", meta_ns)
        if name_node is not None and name_node.text:
            role_name = name_node.text
        syn_node = meta_root.find(
            ".//md:Role/md:Properties/md:Synonym/v8:item[v8:lang='ru']/v8:content", meta_ns
        )
        if syn_node is not None and syn_node.text:
            role_synonym = syn_node.text
    except Exception:
        pass

if not role_name:
    role_name = role_folder_name

# --- Parse Rights.xml ---
tree = etree.parse(rights_path, etree.XMLParser(remove_blank_text=False))
root = tree.getroot()
rights_ns = "http://v8.1c.ru/8.2/roles"
NSMAP = {"r": rights_ns}

# Global flags
set_for_new = root.get("setForNewObjects", "")
set_for_attrs = root.get("setForAttributesByDefault", "")
independent_child = root.get("independentRightsOfChildObjects", "")

# --- Collect objects ---
allowed = OrderedDict()   # type -> OrderedDict { shortName -> [rights] }
denied = OrderedDict()
rls_objects = []
total_allowed = 0
total_denied = 0

for obj in root.findall("r:object", NSMAP):
    obj_name = ""
    rights = []

    for child in obj:
        local = etree.QName(child.tag).localname
        if local == "name" and child.tag == f"{{{rights_ns}}}name":
            obj_name = child.text or ""
        if local == "right" and child.tag == f"{{{rights_ns}}}right":
            r_name = ""
            r_value = ""
            has_rls = False
            for rc in child:
                rc_local = etree.QName(rc.tag).localname
                if rc_local == "name":
                    r_name = rc.text or ""
                if rc_local == "value":
                    r_value = rc.text or ""
                if rc_local == "restrictionByCondition":
                    has_rls = True
            if r_name and r_value:
                rights.append({"name": r_name, "value": r_value, "rls": has_rls})

    if not obj_name or len(rights) == 0:
        continue

    dot_idx = obj_name.find(".")
    if dot_idx < 0:
        continue
    type_prefix = obj_name[:dot_idx]
    short_name = obj_name[dot_idx + 1:]

    for r in rights:
        if r["value"] == "true":
            total_allowed += 1
            if type_prefix not in allowed:
                allowed[type_prefix] = OrderedDict()
            if short_name not in allowed[type_prefix]:
                allowed[type_prefix][short_name] = []
            suffix = r["name"]
            if r["rls"]:
                suffix += " [RLS]"
                rls_objects.append(f"{type_prefix}.{short_name} ({r['name']})")
            allowed[type_prefix][short_name].append(suffix)
        else:
            total_denied += 1
            if type_prefix not in denied:
                denied[type_prefix] = OrderedDict()
            if short_name not in denied[type_prefix]:
                denied[type_prefix][short_name] = []
            denied[type_prefix][short_name].append(r["name"])

# --- Restriction templates ---
templates = []
for tpl in root.findall("r:restrictionTemplate", NSMAP):
    for child in tpl:
        if etree.QName(child.tag).localname == "name":
            t_name = child.text or ""
            paren_idx = t_name.find("(")
            if paren_idx > 0:
                t_name = t_name[:paren_idx]
            templates.append(t_name)

# --- Output ---
header = f"=== Role: {role_name}"
if role_synonym:
    header += f' --- "{role_synonym}"'
header += " ==="
out(header)
out()

out(f"Properties: setForNewObjects={set_for_new}, setForAttributesByDefault={set_for_attrs}, independentRightsOfChildObjects={independent_child}")
out()

# Helper: output group
def out_group(obj_map, is_denied=False):
    for short_name, rights_list in obj_map.items():
        if is_denied:
            rights_str = ", ".join(f"-{r}" for r in rights_list)
        else:
            rights_str = ", ".join(rights_list)
        out(f"    {short_name}: {rights_str}")

# Allowed rights grouped by type
if len(allowed) > 0:
    out("Allowed rights:")
    out()
    for type_prefix, obj_map in allowed.items():
        out(f"  {type_prefix} ({len(obj_map)}):")
        out_group(obj_map)
        out()
else:
    out("(no allowed rights)")
    out()

# Denied rights
if args.ShowDenied and len(denied) > 0:
    out("Denied rights:")
    out()
    for type_prefix, obj_map in denied.items():
        out(f"  {type_prefix} ({len(obj_map)}):")
        out_group(obj_map, is_denied=True)
        out()
elif total_denied > 0:
    out(f"Denied: {total_denied} rights (use -ShowDenied to list)")
    out()

# RLS summary
if len(rls_objects) > 0:
    out(f"RLS: {len(rls_objects)} restrictions")

# Templates
if len(templates) > 0:
    out(f"Templates: {', '.join(templates)}")

out()
out("---")
out(f"Total: {total_allowed} allowed, {total_denied} denied")

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
    shown.append(f"[TRUNCATED] Shown {args.Limit} of {total_lines} lines. Use -Offset {args.Offset + args.Limit} to continue.")
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
