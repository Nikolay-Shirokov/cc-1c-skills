#!/usr/bin/env python3
# cf-edit v1.2 — Edit 1C configuration root (Configuration.xml)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import subprocess
import sys
import uuid as _uuid
from html import escape as html_escape
from lxml import etree

MD_NS = "http://v8.1c.ru/8.3/MDClasses"
XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
V8_NS = "http://v8.1c.ru/8.1/data/core"
XS_NS = "http://www.w3.org/2001/XMLSchema"

# Canonical type order for ChildObjects (44 types)
TYPE_ORDER = [
    "Language", "Subsystem", "StyleItem", "Style",
    "CommonPicture", "SessionParameter", "Role", "CommonTemplate",
    "FilterCriterion", "CommonModule", "CommonAttribute", "ExchangePlan",
    "XDTOPackage", "WebService", "HTTPService", "WSReference",
    "EventSubscription", "ScheduledJob", "SettingsStorage", "FunctionalOption",
    "FunctionalOptionsParameter", "DefinedType", "CommonCommand", "CommandGroup",
    "Constant", "CommonForm", "Catalog", "Document",
    "DocumentNumerator", "Sequence", "DocumentJournal", "Enum",
    "Report", "DataProcessor", "InformationRegister", "AccumulationRegister",
    "ChartOfCharacteristicTypes", "ChartOfAccounts", "AccountingRegister",
    "ChartOfCalculationTypes", "CalculationRegister",
    "BusinessProcess", "Task", "IntegrationService",
]

# Type → on-disk directory name (plural)
TYPE_TO_DIR = {
    "Language": "Languages", "Subsystem": "Subsystems", "StyleItem": "StyleItems", "Style": "Styles",
    "CommonPicture": "CommonPictures", "SessionParameter": "SessionParameters", "Role": "Roles", "CommonTemplate": "CommonTemplates",
    "FilterCriterion": "FilterCriteria", "CommonModule": "CommonModules", "CommonAttribute": "CommonAttributes", "ExchangePlan": "ExchangePlans",
    "XDTOPackage": "XDTOPackages", "WebService": "WebServices", "HTTPService": "HTTPServices", "WSReference": "WSReferences",
    "EventSubscription": "EventSubscriptions", "ScheduledJob": "ScheduledJobs", "SettingsStorage": "SettingsStorages", "FunctionalOption": "FunctionalOptions",
    "FunctionalOptionsParameter": "FunctionalOptionsParameters", "DefinedType": "DefinedTypes", "CommonCommand": "CommonCommands", "CommandGroup": "CommandGroups",
    "Constant": "Constants", "CommonForm": "CommonForms", "Catalog": "Catalogs", "Document": "Documents",
    "DocumentNumerator": "DocumentNumerators", "Sequence": "Sequences", "DocumentJournal": "DocumentJournals", "Enum": "Enums",
    "Report": "Reports", "DataProcessor": "DataProcessors", "InformationRegister": "InformationRegisters", "AccumulationRegister": "AccumulationRegisters",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes", "ChartOfAccounts": "ChartsOfAccounts", "AccountingRegister": "AccountingRegisters",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes", "CalculationRegister": "CalculationRegisters",
    "BusinessProcess": "BusinessProcesses", "Task": "Tasks", "IntegrationService": "IntegrationServices",
}

ML_PROPS = ["Synonym", "BriefInformation", "DetailedInformation", "Copyright", "VendorInformationAddress", "ConfigurationInformationAddress"]
SCALAR_PROPS = ["Name", "Version", "Vendor", "Comment", "NamePrefix", "UpdateCatalogAddress"]
REF_PROPS = ["DefaultLanguage"]


def localname(el):
    return etree.QName(el.tag).localname


def info(msg):
    print(f"[INFO] {msg}")


def warn(msg):
    print(f"[WARN] {msg}")


def get_child_indent(container):
    if container.text and "\n" in container.text:
        after_nl = container.text.rsplit("\n", 1)[-1]
        if after_nl and not after_nl.strip():
            return after_nl
    for child in container:
        if child.tail and "\n" in child.tail:
            after_nl = child.tail.rsplit("\n", 1)[-1]
            if after_nl and not after_nl.strip():
                return after_nl
    depth = 0
    current = container
    while current is not None:
        depth += 1
        current = current.getparent()
    return "\t" * depth


def insert_before_closing(container, new_el, child_indent):
    children = list(container)
    if len(children) == 0:
        parent_indent = child_indent[:-1] if len(child_indent) > 0 else ""
        container.text = "\r\n" + child_indent
        new_el.tail = "\r\n" + parent_indent
        container.append(new_el)
    else:
        last = children[-1]
        new_el.tail = last.tail
        last.tail = "\r\n" + child_indent
        container.append(new_el)


def insert_before_ref(container, new_el, ref_el, child_indent):
    """Insert new_el before ref_el inside container."""
    idx = list(container).index(ref_el)
    prev = ref_el.getprevious()
    if prev is not None:
        new_el.tail = prev.tail
        prev.tail = "\r\n" + child_indent
    else:
        new_el.tail = container.text
        container.text = "\r\n" + child_indent
    container.insert(idx, new_el)


def remove_with_indent(el):
    parent = el.getparent()
    prev = el.getprevious()
    if prev is not None:
        if el.tail:
            prev.tail = el.tail
    else:
        if el.tail:
            parent.text = el.tail
    parent.remove(el)


def expand_self_closing(container, parent_indent):
    if len(container) == 0 and not (container.text and container.text.strip()):
        container.text = "\r\n" + parent_indent


def import_fragment(xml_string):
    wrapper = (
        f'<_W xmlns="{MD_NS}" xmlns:xsi="{XSI_NS}" xmlns:v8="{V8_NS}" '
        f'xmlns:xr="{XR_NS}" xmlns:xs="{XS_NS}">{xml_string}</_W>'
    )
    frag = etree.fromstring(wrapper.encode("utf-8"))
    return list(frag)


def parse_batch_value(val):
    items = []
    for part in val.split(";;"):
        trimmed = part.strip()
        if trimmed:
            items.append(trimmed)
    return items


def save_xml_bom(tree, path):
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    xml_bytes = xml_bytes.replace(b"<?xml version='1.0' encoding='UTF-8'?>", b'<?xml version="1.0" encoding="utf-8"?>')
    if not xml_bytes.endswith(b"\n"):
        xml_bytes += b"\n"
    with open(path, "wb") as f:
        f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Edit 1C configuration root (Configuration.xml)", allow_abbrev=False)
    parser.add_argument("-ConfigPath", "-Path", required=True)
    parser.add_argument("-DefinitionFile", default=None)
    parser.add_argument("-Operation", default=None, choices=["modify-property", "add-childObject", "remove-childObject", "add-defaultRole", "remove-defaultRole", "set-defaultRoles", "set-panels"])
    parser.add_argument("-Value", default=None)
    parser.add_argument("-NoValidate", action="store_true")
    args = parser.parse_args()

    if args.DefinitionFile and args.Operation:
        print("Cannot use both -DefinitionFile and -Operation", file=sys.stderr)
        sys.exit(1)
    if not args.DefinitionFile and not args.Operation:
        print("Either -DefinitionFile or -Operation is required", file=sys.stderr)
        sys.exit(1)

    config_path = args.ConfigPath
    if not os.path.isabs(config_path):
        config_path = os.path.join(os.getcwd(), config_path)
    if os.path.isdir(config_path):
        candidate = os.path.join(config_path, "Configuration.xml")
        if os.path.isfile(candidate):
            config_path = candidate
        else:
            print("No Configuration.xml in directory", file=sys.stderr)
            sys.exit(1)
    if not os.path.isfile(config_path):
        print(f"File not found: {config_path}", file=sys.stderr)
        sys.exit(1)
    resolved_path = os.path.abspath(config_path)
    config_dir = os.path.dirname(resolved_path)

    xml_parser = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(resolved_path, xml_parser)
    xml_root = tree.getroot()

    add_count = 0
    remove_count = 0
    modify_count = 0

    cfg_el = None
    for child in xml_root:
        if isinstance(child.tag, str) and localname(child) == "Configuration":
            cfg_el = child
            break
    if cfg_el is None:
        print("No <Configuration> element found", file=sys.stderr)
        sys.exit(1)

    props_el = None
    child_objs_el = None
    for child in cfg_el:
        if not isinstance(child.tag, str):
            continue
        if localname(child) == "Properties":
            props_el = child
        if localname(child) == "ChildObjects":
            child_objs_el = child

    obj_name = ""
    if props_el is not None:
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == "Name":
                obj_name = (child.text or "").strip()
                break
    info(f"Configuration: {obj_name}")

    # --- Operations ---
    def do_modify_property(batch_val):
        nonlocal modify_count
        items = parse_batch_value(batch_val)
        for item in items:
            eq_idx = item.find("=")
            if eq_idx < 1:
                print(f"Invalid property format '{item}', expected 'Key=Value'", file=sys.stderr)
                sys.exit(1)
            prop_name = item[:eq_idx].strip()
            prop_value = item[eq_idx + 1:].strip()

            prop_el = None
            for child in props_el:
                if isinstance(child.tag, str) and localname(child) == prop_name:
                    prop_el = child
                    break
            if prop_el is None:
                print(f"Property '{prop_name}' not found in Properties", file=sys.stderr)
                sys.exit(1)

            if prop_name in ML_PROPS:
                for ch in list(prop_el):
                    prop_el.remove(ch)
                if not prop_value:
                    prop_el.text = None
                else:
                    indent = get_child_indent(props_el)
                    item_el = etree.SubElement(prop_el, f"{{{V8_NS}}}item")
                    lang_el = etree.SubElement(item_el, f"{{{V8_NS}}}lang")
                    lang_el.text = "ru"
                    content_el = etree.SubElement(item_el, f"{{{V8_NS}}}content")
                    content_el.text = prop_value
                    prop_el.text = "\r\n" + indent + "\t"
                    item_el.text = "\r\n" + indent + "\t\t"
                    lang_el.tail = "\r\n" + indent + "\t\t"
                    content_el.tail = "\r\n" + indent + "\t"
                    item_el.tail = "\r\n" + indent
            elif prop_name in SCALAR_PROPS or prop_name in REF_PROPS:
                for ch in list(prop_el):
                    prop_el.remove(ch)
                if not prop_value:
                    prop_el.text = None
                else:
                    prop_el.text = prop_value
            else:
                for ch in list(prop_el):
                    prop_el.remove(ch)
                prop_el.text = prop_value

            modify_count += 1
            info(f'Set {prop_name} = "{prop_value}"')

    def do_add_child_object(batch_val):
        nonlocal add_count
        if child_objs_el is None:
            print("No <ChildObjects> element found", file=sys.stderr)
            sys.exit(1)

        items = parse_batch_value(batch_val)
        cfg_indent = get_child_indent(cfg_el)
        if len(child_objs_el) == 0 and not (child_objs_el.text and child_objs_el.text.strip()):
            expand_self_closing(child_objs_el, cfg_indent)
        child_indent = get_child_indent(child_objs_el)

        for item in items:
            dot_idx = item.find(".")
            if dot_idx < 1:
                print(f"Invalid format '{item}', expected 'Type.Name'", file=sys.stderr)
                sys.exit(1)
            type_name = item[:dot_idx]
            obj_name_val = item[dot_idx + 1:]

            if type_name not in TYPE_ORDER:
                print(f"Unknown type '{type_name}'", file=sys.stderr)
                sys.exit(1)
            type_idx = TYPE_ORDER.index(type_name)

            # Check that the referenced object actually exists on disk.
            # cf-edit add-childObject is a low-level operation for rare scenarios
            # (e.g. restoring a rolled-back Configuration.xml when object files are intact).
            # For creating NEW objects, meta-compile/role-compile/subsystem-compile already
            # auto-register in Configuration.xml — calling cf-edit add-childObject there is
            # unnecessary and error-prone.
            type_dir = TYPE_TO_DIR.get(type_name)
            obj_file = os.path.join(config_dir, type_dir, f"{obj_name_val}.xml")
            if not os.path.exists(obj_file):
                hint_skill = {"Subsystem": "subsystem-compile", "Role": "role-compile"}.get(type_name, "meta-compile")
                print(
                    f"Object file not found: {type_dir}/{obj_name_val}.xml\n"
                    f"cf-edit add-childObject only references objects that already exist on disk.\n"
                    f"To create a new {type_name}, use {hint_skill} (auto-registers in Configuration.xml):\n"
                    f'  /{hint_skill} with {{"type":"{type_name}","name":"{obj_name_val}"}}',
                    file=sys.stderr
                )
                sys.exit(1)

            # Dedup
            exists = False
            for child in child_objs_el:
                if isinstance(child.tag, str) and localname(child) == type_name and (child.text or "") == obj_name_val:
                    exists = True
                    break
            if exists:
                warn(f"Already exists: {type_name}.{obj_name_val}")
                continue

            # Find insertion point
            insert_before = None
            for child in child_objs_el:
                if not isinstance(child.tag, str):
                    continue
                child_type_name = localname(child)
                if child_type_name not in TYPE_ORDER:
                    continue
                child_type_idx = TYPE_ORDER.index(child_type_name)

                if child_type_name == type_name:
                    if (child.text or "") > obj_name_val and insert_before is None:
                        insert_before = child
                elif child_type_idx > type_idx and insert_before is None:
                    insert_before = child

            new_el = etree.Element(f"{{{MD_NS}}}{type_name}")
            new_el.text = obj_name_val

            if insert_before is not None:
                insert_before_ref(child_objs_el, new_el, insert_before, child_indent)
            else:
                insert_before_closing(child_objs_el, new_el, child_indent)

            add_count += 1
            info(f"Added: {type_name}.{obj_name_val}")

    def do_remove_child_object(batch_val):
        nonlocal remove_count
        if child_objs_el is None:
            print("No <ChildObjects> element found", file=sys.stderr)
            sys.exit(1)

        items = parse_batch_value(batch_val)
        for item in items:
            dot_idx = item.find(".")
            if dot_idx < 1:
                print(f"Invalid format '{item}', expected 'Type.Name'", file=sys.stderr)
                sys.exit(1)
            type_name = item[:dot_idx]
            obj_name_val = item[dot_idx + 1:]

            found = False
            for child in list(child_objs_el):
                if isinstance(child.tag, str) and localname(child) == type_name and (child.text or "") == obj_name_val:
                    remove_with_indent(child)
                    remove_count += 1
                    info(f"Removed: {type_name}.{obj_name_val}")
                    found = True
                    break
            if not found:
                warn(f"Not found: {type_name}.{obj_name_val}")

    def do_add_default_role(batch_val):
        nonlocal add_count
        items = parse_batch_value(batch_val)

        roles_el = None
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == "DefaultRoles":
                roles_el = child
                break
        if roles_el is None:
            print("No <DefaultRoles> element found in Properties", file=sys.stderr)
            sys.exit(1)

        props_indent = get_child_indent(props_el)
        if len(roles_el) == 0 and not (roles_el.text and roles_el.text.strip()):
            expand_self_closing(roles_el, props_indent)
        role_indent = get_child_indent(roles_el)

        for item in items:
            role_name = item
            if not role_name.startswith("Role."):
                role_name = f"Role.{role_name}"

            exists = False
            for child in roles_el:
                if isinstance(child.tag, str) and (child.text or "").strip() == role_name:
                    exists = True
                    break
            if exists:
                warn(f"DefaultRole already exists: {role_name}")
                continue

            frag_xml = f'<xr:Item xsi:type="xr:MDObjectRef">{role_name}</xr:Item>'
            nodes = import_fragment(frag_xml)
            if nodes:
                insert_before_closing(roles_el, nodes[0], role_indent)
                add_count += 1
                info(f"Added DefaultRole: {role_name}")

    def do_remove_default_role(batch_val):
        nonlocal remove_count
        items = parse_batch_value(batch_val)

        roles_el = None
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == "DefaultRoles":
                roles_el = child
                break
        if roles_el is None:
            print("No <DefaultRoles> element found", file=sys.stderr)
            sys.exit(1)

        for item in items:
            role_name = item
            if not role_name.startswith("Role."):
                role_name = f"Role.{role_name}"

            found = False
            for child in list(roles_el):
                if isinstance(child.tag, str) and (child.text or "").strip() == role_name:
                    remove_with_indent(child)
                    remove_count += 1
                    info(f"Removed DefaultRole: {role_name}")
                    found = True
                    break
            if not found:
                warn(f"DefaultRole not found: {role_name}")

    def do_set_default_roles(batch_val):
        nonlocal modify_count
        items = parse_batch_value(batch_val)

        roles_el = None
        for child in props_el:
            if isinstance(child.tag, str) and localname(child) == "DefaultRoles":
                roles_el = child
                break
        if roles_el is None:
            print("No <DefaultRoles> element found", file=sys.stderr)
            sys.exit(1)

        # Clear all existing children
        for ch in list(roles_el):
            roles_el.remove(ch)
        roles_el.text = None

        if not items:
            modify_count += 1
            info("Cleared DefaultRoles")
            return

        props_indent = get_child_indent(props_el)
        role_indent = props_indent + "\t"

        roles_el.text = "\r\n" + props_indent

        for item in items:
            role_name = item
            if not role_name.startswith("Role."):
                role_name = f"Role.{role_name}"

            frag_xml = f'<xr:Item xsi:type="xr:MDObjectRef">{role_name}</xr:Item>'
            nodes = import_fragment(frag_xml)
            if nodes:
                insert_before_closing(roles_el, nodes[0], role_indent)

        modify_count += 1
        info(f"Set DefaultRoles: {len(items)} roles")

    # --- set-panels (writes Ext/ClientApplicationInterface.xml from scratch) ---
    PANEL_UUIDS = {
        "sections":  "b553047f-c9aa-4157-978d-448ecad24248",
        "open":      "cbab57f2-a0f3-4f0a-89ea-4cb19570ab75",
        "favorites": "13322b22-3960-4d68-93a6-fe2dd7f28ca3",
        "history":   "c933ac92-92cd-459d-81cc-e0c8a83ced99",
        "functions": "b2735bd3-d822-4430-ba59-c9e869693b24",
    }

    def build_panel_entry_xml(entry, indent):
        if isinstance(entry, str):
            if entry not in PANEL_UUIDS:
                allowed = ", ".join(sorted(PANEL_UUIDS.keys()))
                print(f"Unknown panel alias '{entry}'. Allowed: {allowed}", file=sys.stderr)
                sys.exit(1)
            inst = str(_uuid.uuid4())
            return f'{indent}<panel id="{inst}">\r\n{indent}\t<uuid>{PANEL_UUIDS[entry]}</uuid>\r\n{indent}</panel>'
        if isinstance(entry, dict) and "group" in entry:
            children = entry["group"]
            if not children:
                print("group must contain at least one entry", file=sys.stderr)
                sys.exit(1)
            gid = str(_uuid.uuid4())
            inner = ""
            for child in children:
                child_xml = build_panel_entry_xml(child, indent + "\t\t")
                inner += f"{indent}\t<group>\r\n{child_xml}\r\n{indent}\t</group>\r\n"
            return f'{indent}<group id="{gid}">\r\n{inner}{indent}</group>'
        print(f"Panel entry must be string alias or {{group:[...]}}, got: {entry!r}", file=sys.stderr)
        sys.exit(1)

    def do_set_panels(value):
        nonlocal modify_count
        layout = value
        if isinstance(layout, str):
            try:
                layout = json.loads(layout)
            except json.JSONDecodeError:
                print(f"set-panels value must be valid JSON object", file=sys.stderr)
                sys.exit(1)
        if not isinstance(layout, dict) or not layout:
            print("set-panels value must be non-empty object", file=sys.stderr)
            sys.exit(1)

        sides = ("top", "left", "right", "bottom")
        # Reject unknown side keys
        for k in layout.keys():
            if k not in sides:
                print(f"Unknown side '{k}'. Allowed: {', '.join(sides)}", file=sys.stderr)
                sys.exit(1)

        body_parts = []
        for side in sides:
            entries = layout.get(side)
            if entries is None:
                continue
            if not isinstance(entries, list):
                entries = [entries]
            for entry in entries:
                entry_xml = build_panel_entry_xml(entry, "\t\t")
                body_parts.append(f"\t<{side}>\r\n{entry_xml}\r\n\t</{side}>")
        body = "\r\n".join(body_parts)
        body_block = body + "\r\n" if body else ""
        declarations = (
            '\t<panelDef id="b553047f-c9aa-4157-978d-448ecad24248"/>\r\n'
            '\t<panelDef id="13322b22-3960-4d68-93a6-fe2dd7f28ca3"/>\r\n'
            '\t<panelDef id="c933ac92-92cd-459d-81cc-e0c8a83ced99"/>\r\n'
            '\t<panelDef id="cbab57f2-a0f3-4f0a-89ea-4cb19570ab75"/>\r\n'
            '\t<panelDef id="b2735bd3-d822-4430-ba59-c9e869693b24"/>'
        )
        cai_xml = (
            '<?xml version="1.0" encoding="UTF-8"?>\r\n'
            '<ClientApplicationInterface xmlns="http://v8.1c.ru/8.2/managed-application/core" '
            'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
            'xsi:type="InterfaceLayouter">\r\n'
            f'{body_block}{declarations}\r\n'
            '</ClientApplicationInterface>'
        )
        ext_dir = os.path.join(config_dir, "Ext")
        os.makedirs(ext_dir, exist_ok=True)
        cai_path = os.path.join(ext_dir, "ClientApplicationInterface.xml")
        with open(cai_path, "w", encoding="utf-8-sig", newline="") as fh:
            fh.write(cai_xml)
        modify_count += 1
        info(f"Wrote panel layout: {cai_path}")

    # --- Execute operations ---
    operations = []
    if args.DefinitionFile:
        def_file = args.DefinitionFile
        if not os.path.isabs(def_file):
            def_file = os.path.join(os.getcwd(), def_file)
        with open(def_file, "r", encoding="utf-8-sig") as fh:
            ops = json.loads(fh.read())
        if isinstance(ops, list):
            operations = ops
        else:
            operations = [ops]
    else:
        operations = [{"operation": args.Operation, "value": args.Value or ""}]

    for op in operations:
        op_name = op.get("operation", args.Operation or "")
        op_value = op.get("value", args.Value or "")

        if op_name == "modify-property":
            do_modify_property(op_value if isinstance(op_value, str) else str(op_value))
        elif op_name == "add-childObject":
            do_add_child_object(op_value if isinstance(op_value, str) else str(op_value))
        elif op_name == "remove-childObject":
            do_remove_child_object(op_value if isinstance(op_value, str) else str(op_value))
        elif op_name == "add-defaultRole":
            do_add_default_role(op_value if isinstance(op_value, str) else str(op_value))
        elif op_name == "remove-defaultRole":
            do_remove_default_role(op_value if isinstance(op_value, str) else str(op_value))
        elif op_name == "set-defaultRoles":
            do_set_default_roles(op_value if isinstance(op_value, str) else str(op_value))
        elif op_name == "set-panels":
            do_set_panels(op_value)
        else:
            print(f"Unknown operation: {op_name}", file=sys.stderr)
            sys.exit(1)

    # --- Save ---
    save_xml_bom(tree, resolved_path)
    info(f"Saved: {resolved_path}")

    # --- Auto-validate ---
    if not args.NoValidate:
        validate_script = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "cf-validate", "scripts", "cf-validate.py"))
        if os.path.isfile(validate_script):
            print()
            print("--- Running cf-validate ---")
            subprocess.run([sys.executable, validate_script, "-ConfigPath", "-Path", resolved_path])

    # --- Summary ---
    print()
    print("=== cf-edit summary ===")
    print(f"  Configuration: {obj_name}")
    print(f"  Added:         {add_count}")
    print(f"  Removed:       {remove_count}")
    print(f"  Modified:      {modify_count}")
    sys.exit(0)


if __name__ == "__main__":
    main()
