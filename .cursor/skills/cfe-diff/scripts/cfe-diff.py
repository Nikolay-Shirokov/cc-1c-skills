#!/usr/bin/env python3
# cfe-diff v1.0 — Analyze and compare 1C configuration extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
from lxml import etree

# --- Namespace maps ---

MD_NSMAP = {
    "md": "http://v8.1c.ru/8.3/MDClasses",
    "xr": "http://v8.1c.ru/8.3/xcf/readable",
}

FORM_NSMAP = {
    "f": "http://v8.1c.ru/8.3/xcf/logform",
}

# --- Type -> directory mapping ---

CHILD_TYPE_DIR_MAP = {
    "Catalog": "Catalogs",
    "Document": "Documents",
    "Enum": "Enums",
    "CommonModule": "CommonModules",
    "CommonPicture": "CommonPictures",
    "CommonCommand": "CommonCommands",
    "CommonTemplate": "CommonTemplates",
    "ExchangePlan": "ExchangePlans",
    "Report": "Reports",
    "DataProcessor": "DataProcessors",
    "InformationRegister": "InformationRegisters",
    "AccumulationRegister": "AccumulationRegisters",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfAccounts": "ChartsOfAccounts",
    "AccountingRegister": "AccountingRegisters",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes",
    "CalculationRegister": "CalculationRegisters",
    "BusinessProcess": "BusinessProcesses",
    "Task": "Tasks",
    "Subsystem": "Subsystems",
    "Role": "Roles",
    "Constant": "Constants",
    "FunctionalOption": "FunctionalOptions",
    "DefinedType": "DefinedTypes",
    "FunctionalOptionsParameter": "FunctionalOptionsParameters",
    "CommonForm": "CommonForms",
    "DocumentJournal": "DocumentJournals",
    "SessionParameter": "SessionParameters",
    "StyleItem": "StyleItems",
    "EventSubscription": "EventSubscriptions",
    "ScheduledJob": "ScheduledJobs",
    "SettingsStorage": "SettingsStorages",
    "FilterCriterion": "FilterCriteria",
    "CommandGroup": "CommandGroups",
    "DocumentNumerator": "DocumentNumerators",
    "Sequence": "Sequences",
    "IntegrationService": "IntegrationServices",
    "CommonAttribute": "CommonAttributes",
}


# --- Helper: check if object is borrowed ---

def get_object_info(obj_type, obj_name, extension_path):
    if obj_type not in CHILD_TYPE_DIR_MAP:
        return None
    dir_name = CHILD_TYPE_DIR_MAP[obj_type]
    obj_file = os.path.join(extension_path, dir_name, f"{obj_name}.xml")

    if not os.path.isfile(obj_file):
        return {"Borrowed": False, "File": obj_file, "Exists": False}

    parser_xml = etree.XMLParser(remove_blank_text=False)
    doc = etree.parse(obj_file, parser_xml)
    doc_root = doc.getroot()

    # Find first element child
    obj_el = None
    for c in doc_root:
        if isinstance(c.tag, str):
            obj_el = c
            break

    if obj_el is None:
        return {"Borrowed": False, "File": obj_file, "Exists": True}

    props_el = obj_el.find("md:Properties", MD_NSMAP)
    ob_node = None
    if props_el is not None:
        ob_node = props_el.find("md:ObjectBelonging", MD_NSMAP)

    borrowed = ob_node is not None and ob_node.text == "Adopted"

    return {
        "Borrowed": borrowed,
        "File": obj_file,
        "Exists": True,
        "Type": obj_type,
        "Name": obj_name,
        "DirName": dir_name,
        "ObjElement": obj_el,
    }


# --- Helper: find .bsl files for object ---

def get_bsl_files(obj_type, obj_name, extension_path):
    if obj_type not in CHILD_TYPE_DIR_MAP:
        return []
    dir_name = CHILD_TYPE_DIR_MAP[obj_type]
    obj_dir = os.path.join(extension_path, dir_name, obj_name)

    if not os.path.isdir(obj_dir):
        return []

    bsl_files = []
    ext_dir = os.path.join(obj_dir, "Ext")
    if os.path.isdir(ext_dir):
        for item in os.listdir(ext_dir):
            if item.lower().endswith(".bsl"):
                bsl_files.append(os.path.join(ext_dir, item))

    # Forms
    forms_dir = os.path.join(obj_dir, "Forms")
    if os.path.isdir(forms_dir):
        for dirpath, dirnames, filenames in os.walk(forms_dir):
            for fn in filenames:
                if fn == "Module.bsl":
                    bsl_files.append(os.path.join(dirpath, fn))

    return bsl_files


# --- Helper: parse interceptors from .bsl ---

def get_interceptors(bsl_path):
    if not os.path.isfile(bsl_path):
        return []

    with open(bsl_path, "r", encoding="utf-8-sig") as fh:
        lines = fh.readlines()

    interceptors = []
    pattern = re.compile(r'^&(\u041f\u0435\u0440\u0435\u0434|\u041f\u043e\u0441\u043b\u0435|\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435\u0418\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c|\u0412\u043c\u0435\u0441\u0442\u043e)\("([^"]+)"\)')
    # The above is: ^&(Перед|После|ИзменениеИКонтроль|Вместо)\("([^"]+)"\)

    for i, line in enumerate(lines):
        stripped = line.strip()
        m = pattern.match(stripped)
        if m:
            interceptors.append({
                "Type": m.group(1),
                "Method": m.group(2),
                "Line": i + 1,
                "File": bsl_path,
            })

    return interceptors


# --- Helper: extract #Вставка blocks from .bsl ---

def get_insertion_blocks(bsl_path):
    if not os.path.isfile(bsl_path):
        return []

    with open(bsl_path, "r", encoding="utf-8-sig") as fh:
        lines = fh.readlines()

    blocks = []
    in_block = False
    block_lines = []
    start_line = 0

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "\u0023\u0412\u0441\u0442\u0430\u0432\u043a\u0430":
            # #Вставка
            in_block = True
            block_lines = []
            start_line = i + 1
        elif stripped == "\u0023\u041a\u043e\u043d\u0435\u0446\u0412\u0441\u0442\u0430\u0432\u043a\u0438" and in_block:
            # #КонецВставки
            in_block = False
            blocks.append({
                "StartLine": start_line,
                "EndLine": i + 1,
                "Code": "\n".join(block_lines).strip(),
                "File": bsl_path,
            })
        elif in_block:
            block_lines.append(line.rstrip("\n").rstrip("\r"))

    return blocks


# --- Helper: analyze form for callType events and commands ---

def get_form_interceptors(form_xml_path):
    if not os.path.isfile(form_xml_path):
        return None

    parser_xml = etree.XMLParser(remove_blank_text=False)
    try:
        doc = etree.parse(form_xml_path, parser_xml)
    except Exception:
        return None

    f_root = doc.getroot()
    base_form = f_root.find("f:BaseForm", FORM_NSMAP)
    is_borrowed = base_form is not None

    interceptors = []

    # Form-level events with callType
    events_node = f_root.find("f:Events", FORM_NSMAP)
    if events_node is not None:
        for evt in events_node.findall("f:Event", FORM_NSMAP):
            ct = evt.get("callType", "")
            if ct:
                evt_name = evt.get("name", "")
                evt_text = evt.text or ""
                interceptors.append(f"Event:{evt_name} [{ct}] -> {evt_text}")

    # Element-level events with callType (scan all elements recursively)
    child_items = f_root.find("f:ChildItems", FORM_NSMAP)
    if child_items is not None:
        # Walk all descendant elements looking for Events/Event[@callType]
        f_ns = FORM_NSMAP["f"]
        for el in child_items.iter():
            if not isinstance(el.tag, str):
                continue
            el_name = el.get("name", "")
            if not el_name:
                continue
            events_sub = el.find(f"{{{f_ns}}}Events")
            if events_sub is None:
                continue
            for evt in events_sub.findall(f"{{{f_ns}}}Event"):
                ct = evt.get("callType", "")
                if ct:
                    evt_name = evt.get("name", "")
                    evt_text = evt.text or ""
                    interceptors.append(f"Element:{el_name}.{evt_name} [{ct}] -> {evt_text}")

    # Commands with callType on Action
    f_ns = FORM_NSMAP["f"]
    cmds_node = f_root.find(f"{{{f_ns}}}Commands")
    if cmds_node is not None:
        for cmd in cmds_node.findall(f"{{{f_ns}}}Command"):
            cmd_name = cmd.get("name", "")
            for action in cmd.findall(f"{{{f_ns}}}Action"):
                ct = action.get("callType", "")
                if ct:
                    action_text = action.text or ""
                    interceptors.append(f"Command:{cmd_name} [{ct}] -> {action_text}")

    return {
        "IsBorrowed": is_borrowed,
        "Interceptors": interceptors,
    }


# --- Mode A: Extension overview ---

def mode_a(objects, extension_path):
    borrowed_list = []
    own_list = []

    for obj in objects:
        info = get_object_info(obj["Type"], obj["Name"], extension_path)
        if info is None:
            print(f"  [?] {obj['Type']}.{obj['Name']} \u2014 unknown type")
            continue
        if not info["Exists"]:
            print(f"  [?] {obj['Type']}.{obj['Name']} \u2014 file not found")
            continue

        if info["Borrowed"]:
            borrowed_list.append(obj)

            print(f"  [BORROWED] {obj['Type']}.{obj['Name']}")

            # Find .bsl files and interceptors
            bsl_files = get_bsl_files(obj["Type"], obj["Name"], extension_path)
            for bsl in bsl_files:
                rel_path = bsl.replace(extension_path, "").lstrip("\\/")
                interceptor_list = get_interceptors(bsl)
                if len(interceptor_list) > 0:
                    for ic in interceptor_list:
                        print(f'             &{ic["Type"]}("{ic["Method"]}") \u2014 line {ic["Line"]} in {rel_path}')
                else:
                    print(f"             {rel_path} (no interceptors)")

            # Check for own attributes/forms in ChildObjects
            obj_el = info.get("ObjElement")
            if obj_el is not None:
                child_obj = obj_el.find("md:ChildObjects", MD_NSMAP)
                if child_obj is not None:
                    own_attrs = 0
                    own_forms = 0
                    own_ts = 0
                    borrowed_items = 0
                    form_names = []
                    for c in child_obj:
                        if not isinstance(c.tag, str):
                            continue
                        ln = etree.QName(c.tag).localname
                        c_props = c.find("md:Properties", MD_NSMAP)
                        if c_props is not None:
                            c_ob = c_props.find("md:ObjectBelonging", MD_NSMAP)
                            if c_ob is not None and c_ob.text == "Adopted":
                                borrowed_items += 1
                                continue
                        if ln == "Attribute":
                            own_attrs += 1
                        elif ln == "TabularSection":
                            own_ts += 1
                        elif ln == "Form":
                            form_names.append(c.text or "")
                            own_forms += 1

                    parts = []
                    if own_attrs > 0:
                        parts.append(f"{own_attrs} own attrs")
                    if own_ts > 0:
                        parts.append(f"{own_ts} own TS")
                    if own_forms > 0:
                        parts.append(f"{own_forms} own forms")
                    if borrowed_items > 0:
                        parts.append(f"{borrowed_items} borrowed items")
                    if len(parts) > 0:
                        print(f"             ChildObjects: {', '.join(parts)}")

                    # Analyze forms
                    for fn in form_names:
                        form_xml_path = os.path.join(
                            extension_path, info["DirName"], info["Name"],
                            "Forms", fn, "Ext", "Form.xml"
                        )
                        fi = get_form_interceptors(form_xml_path)
                        if fi is None:
                            print(f"             Form.{fn} (?)")
                            continue
                        form_tag = "borrowed" if fi["IsBorrowed"] else "own"
                        if len(fi["Interceptors"]) > 0:
                            print(f"             Form.{fn} ({form_tag}):")
                            for ic in fi["Interceptors"]:
                                print(f"               {ic}")
                        else:
                            print(f"             Form.{fn} ({form_tag})")
        else:
            own_list.append(obj)
            print(f"  [OWN]      {obj['Type']}.{obj['Name']}")

            # Brief info for own objects
            obj_el = info.get("ObjElement")
            if obj_el is not None:
                child_obj = obj_el.find("md:ChildObjects", MD_NSMAP)
                if child_obj is not None:
                    attrs = 0
                    forms = 0
                    ts = 0
                    for c in child_obj:
                        if not isinstance(c.tag, str):
                            continue
                        ln = etree.QName(c.tag).localname
                        if ln == "Attribute":
                            attrs += 1
                        elif ln == "TabularSection":
                            ts += 1
                        elif ln == "Form":
                            forms += 1
                    parts = []
                    if attrs > 0:
                        parts.append(f"{attrs} attrs")
                    if ts > 0:
                        parts.append(f"{ts} TS")
                    if forms > 0:
                        parts.append(f"{forms} forms")
                    if len(parts) > 0:
                        print(f"             {', '.join(parts)}")

    print("")
    print(f"=== Summary: {len(borrowed_list)} borrowed, {len(own_list)} own objects ===")


# --- Mode B: Transfer check ---

def mode_b(objects, extension_path, config_path):
    transferred = 0
    not_transferred = 0
    needs_review = 0

    for obj in objects:
        info = get_object_info(obj["Type"], obj["Name"], extension_path)
        if info is None or not info["Exists"] or not info["Borrowed"]:
            continue

        # Find .bsl files with &ИзменениеИКонтроль
        bsl_files = get_bsl_files(obj["Type"], obj["Name"], extension_path)
        for bsl in bsl_files:
            interceptor_list = get_interceptors(bsl)
            mac_interceptors = [ic for ic in interceptor_list if ic["Type"] == "\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435\u0418\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c"]

            if len(mac_interceptors) == 0:
                continue

            for ic in mac_interceptors:
                method_name = ic["Method"]
                rel_bsl = bsl.replace(extension_path, "").lstrip("\\/")

                # Find #Вставка blocks in this file
                insert_blocks = get_insertion_blocks(bsl)

                if len(insert_blocks) == 0:
                    print(f'  [NEEDS_REVIEW] {obj["Type"]}.{obj["Name"]} \u2014 &\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435\u0418\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c("{method_name}") \u2014 no #\u0412\u0441\u0442\u0430\u0432\u043a\u0430 blocks')
                    needs_review += 1
                    continue

                # Find corresponding module in config
                if obj["Type"] not in CHILD_TYPE_DIR_MAP:
                    continue
                config_bsl = bsl.replace(extension_path, config_path)

                if not os.path.isfile(config_bsl):
                    print(f'  [NEEDS_REVIEW] {obj["Type"]}.{obj["Name"]} \u2014 &\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435\u0418\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c("{method_name}") \u2014 config module not found')
                    needs_review += 1
                    continue

                with open(config_bsl, "r", encoding="utf-8-sig") as fh:
                    config_content = fh.read()

                all_transferred = True
                for block in insert_blocks:
                    code = block["Code"]
                    if not code:
                        continue

                    # Normalize whitespace for comparison
                    code_norm = re.sub(r'\s+', ' ', code)
                    config_norm = re.sub(r'\s+', ' ', config_content)

                    if code_norm not in config_norm:
                        all_transferred = False

                if all_transferred:
                    print(f'  [TRANSFERRED]     {obj["Type"]}.{obj["Name"]} \u2014 &\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435\u0418\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c("{method_name}") \u2014 {len(insert_blocks)} block(s)')
                    transferred += 1
                else:
                    print(f'  [NOT_TRANSFERRED] {obj["Type"]}.{obj["Name"]} \u2014 &\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435\u0418\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c("{method_name}") \u2014 some blocks not found in config')
                    not_transferred += 1

    print("")
    print(f"=== Transfer check: {transferred} transferred, {not_transferred} not transferred, {needs_review} needs review ===")


# --- Main ---

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Analyze and compare 1C configuration extension (CFE)", allow_abbrev=False)
    parser.add_argument("-ExtensionPath", required=True, help="Path to extension dump root")
    parser.add_argument("-ConfigPath", required=True, help="Path to base config dump root")
    parser.add_argument("-Mode", choices=["A", "B"], default="A", help="A=overview, B=transfer check")
    args = parser.parse_args()

    extension_path = args.ExtensionPath
    config_path = args.ConfigPath
    mode = args.Mode

    # --- Resolve paths ---
    if not os.path.isabs(extension_path):
        extension_path = os.path.join(os.getcwd(), extension_path)
    if not os.path.isabs(config_path):
        config_path = os.path.join(os.getcwd(), config_path)
    if os.path.isfile(extension_path):
        extension_path = os.path.dirname(extension_path)
    if os.path.isfile(config_path):
        config_path = os.path.dirname(config_path)

    ext_cfg = os.path.join(extension_path, "Configuration.xml")
    src_cfg = os.path.join(config_path, "Configuration.xml")
    if not os.path.isfile(ext_cfg):
        print(f"Extension Configuration.xml not found: {ext_cfg}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(src_cfg):
        print(f"Config Configuration.xml not found: {src_cfg}", file=sys.stderr)
        sys.exit(1)

    # --- Parse extension Configuration.xml ---
    parser_xml = etree.XMLParser(remove_blank_text=False)
    ext_doc = etree.parse(ext_cfg, parser_xml)
    ext_root = ext_doc.getroot()

    ext_props = ext_root.find(".//md:Configuration/md:Properties", MD_NSMAP)
    ext_name_node = ext_props.find("md:Name", MD_NSMAP) if ext_props is not None else None
    ext_name = ext_name_node.text if ext_name_node is not None and ext_name_node.text else "?"
    prefix_node = ext_props.find("md:NamePrefix", MD_NSMAP) if ext_props is not None else None
    name_prefix = prefix_node.text if prefix_node is not None and prefix_node.text else ""
    purpose_node = ext_props.find("md:ConfigurationExtensionPurpose", MD_NSMAP) if ext_props is not None else None
    purpose = purpose_node.text if purpose_node is not None and purpose_node.text else "?"

    print(f"=== cfe-diff Mode {mode}: {ext_name} ({purpose}) ===")
    print(f"    NamePrefix: {name_prefix}")
    print("")

    # --- Collect ChildObjects ---
    child_obj_node = ext_root.find(".//md:Configuration/md:ChildObjects", MD_NSMAP)
    if child_obj_node is None:
        print("[WARN] No ChildObjects in extension")
        sys.exit(0)

    objects = []
    for child in child_obj_node:
        if not isinstance(child.tag, str):
            continue
        ln = etree.QName(child.tag).localname
        if ln == "Language":
            continue
        objects.append({"Type": ln, "Name": child.text or ""})

    if len(objects) == 0:
        print("No objects (besides Language) in extension.")
        sys.exit(0)

    # --- Run selected mode ---
    if mode == "A":
        mode_a(objects, extension_path)
    elif mode == "B":
        mode_b(objects, extension_path, config_path)


if __name__ == "__main__":
    main()
