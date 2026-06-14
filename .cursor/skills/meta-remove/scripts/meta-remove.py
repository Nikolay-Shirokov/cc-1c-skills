#!/usr/bin/env python3
# meta-remove v1.1 — Remove metadata object from 1C configuration dump
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import sys
import shutil
from lxml import etree

# --- Type -> plural directory mapping ---

TYPE_PLURAL_MAP = {
    "Catalog": "Catalogs",
    "Document": "Documents",
    "Enum": "Enums",
    "Constant": "Constants",
    "InformationRegister": "InformationRegisters",
    "AccumulationRegister": "AccumulationRegisters",
    "AccountingRegister": "AccountingRegisters",
    "CalculationRegister": "CalculationRegisters",
    "ChartOfAccounts": "ChartsOfAccounts",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes",
    "BusinessProcess": "BusinessProcesses",
    "Task": "Tasks",
    "ExchangePlan": "ExchangePlans",
    "DocumentJournal": "DocumentJournals",
    "Report": "Reports",
    "DataProcessor": "DataProcessors",
    "CommonModule": "CommonModules",
    "ScheduledJob": "ScheduledJobs",
    "EventSubscription": "EventSubscriptions",
    "HTTPService": "HTTPServices",
    "WebService": "WebServices",
    "DefinedType": "DefinedTypes",
    "Role": "Roles",
    "Subsystem": "Subsystems",
    "CommonForm": "CommonForms",
    "CommonTemplate": "CommonTemplates",
    "CommonPicture": "CommonPictures",
    "CommonAttribute": "CommonAttributes",
    "SessionParameter": "SessionParameters",
    "FunctionalOption": "FunctionalOptions",
    "FunctionalOptionsParameter": "FunctionalOptionsParameters",
    "Sequence": "Sequences",
    "FilterCriterion": "FilterCriteria",
    "SettingsStorage": "SettingsStorages",
    "XDTOPackage": "XDTOPackages",
    "WSReference": "WSReferences",
    "StyleItem": "StyleItems",
    "Language": "Languages",
}

# Type -> reference type names (used in XML <v8:Type> elements)
TYPE_REF_NAMES = {
    "Catalog": ["CatalogRef", "CatalogObject"],
    "Document": ["DocumentRef", "DocumentObject"],
    "Enum": ["EnumRef"],
    "ExchangePlan": ["ExchangePlanRef", "ExchangePlanObject"],
    "ChartOfAccounts": ["ChartOfAccountsRef", "ChartOfAccountsObject"],
    "ChartOfCharacteristicTypes": ["ChartOfCharacteristicTypesRef", "ChartOfCharacteristicTypesObject"],
    "ChartOfCalculationTypes": ["ChartOfCalculationTypesRef", "ChartOfCalculationTypesObject"],
    "BusinessProcess": ["BusinessProcessRef", "BusinessProcessObject"],
    "Task": ["TaskRef", "TaskObject"],
}

# Type -> Russian manager name (used in BSL code)
TYPE_RU_MANAGER = {
    "Catalog": "\u0421\u043f\u0440\u0430\u0432\u043e\u0447\u043d\u0438\u043a\u0438",
    "Document": "\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u044b",
    "Enum": "\u041f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u0438\u044f",
    "Constant": "\u041a\u043e\u043d\u0441\u0442\u0430\u043d\u0442\u044b",
    "InformationRegister": "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u044b\u0421\u0432\u0435\u0434\u0435\u043d\u0438\u0439",
    "AccumulationRegister": "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u044b\u041d\u0430\u043a\u043e\u043f\u043b\u0435\u043d\u0438\u044f",
    "AccountingRegister": "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u044b\u0411\u0443\u0445\u0433\u0430\u043b\u0442\u0435\u0440\u0438\u0438",
    "CalculationRegister": "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u044b\u0420\u0430\u0441\u0447\u0435\u0442\u0430",
    "ChartOfAccounts": "\u041f\u043b\u0430\u043d\u044b\u0421\u0447\u0435\u0442\u043e\u0432",
    "ChartOfCharacteristicTypes": "\u041f\u043b\u0430\u043d\u044b\u0412\u0438\u0434\u043e\u0432\u0425\u0430\u0440\u0430\u043a\u0442\u0435\u0440\u0438\u0441\u0442\u0438\u043a",
    "ChartOfCalculationTypes": "\u041f\u043b\u0430\u043d\u044b\u0412\u0438\u0434\u043e\u0432\u0420\u0430\u0441\u0447\u0435\u0442\u0430",
    "BusinessProcess": "\u0411\u0438\u0437\u043d\u0435\u0441\u041f\u0440\u043e\u0446\u0435\u0441\u0441\u044b",
    "Task": "\u0417\u0430\u0434\u0430\u0447\u0438",
    "ExchangePlan": "\u041f\u043b\u0430\u043d\u044b\u041e\u0431\u043c\u0435\u043d\u0430",
    "Report": "\u041e\u0442\u0447\u0435\u0442\u044b",
    "DataProcessor": "\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0438",
    "DocumentJournal": "\u0416\u0443\u0440\u043d\u0430\u043b\u044b\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u043e\u0432",
    "CommonModule": None,
}

MD_NS = "http://v8.1c.ru/8.3/MDClasses"
V8_NS = "http://v8.1c.ru/8.1/data/core"

NSMAP = {"md": MD_NS, "v8": V8_NS}


def localname(el):
    return etree.QName(el.tag).localname


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
    parser = argparse.ArgumentParser(description="Remove metadata object from 1C configuration dump", allow_abbrev=False)
    parser.add_argument("-ConfigDir", required=True)
    parser.add_argument("-Object", required=True)
    parser.add_argument("-DryRun", action="store_true")
    parser.add_argument("-KeepFiles", action="store_true")
    parser.add_argument("-Force", action="store_true")
    args = parser.parse_args()

    config_dir = args.ConfigDir
    if not os.path.isabs(config_dir):
        config_dir = os.path.join(os.getcwd(), config_dir)

    if not os.path.isdir(config_dir):
        print(f"[ERROR] Config directory not found: {config_dir}")
        sys.exit(1)

    config_xml = os.path.join(config_dir, "Configuration.xml")
    if not os.path.isfile(config_xml):
        print(f"[ERROR] Configuration.xml not found in: {config_dir}")
        sys.exit(1)

    # --- Parse object spec ---
    parts = args.Object.split(".", 1)
    if len(parts) != 2 or not parts[0] or not parts[1]:
        print(f"[ERROR] Invalid object format '{args.Object}'. Expected: Type.Name (e.g. Catalog.\u0422\u043e\u0432\u0430\u0440\u044b)")
        sys.exit(1)

    obj_type = parts[0]
    obj_name = parts[1]

    if obj_type not in TYPE_PLURAL_MAP:
        print(f"[ERROR] Unknown type '{obj_type}'. Supported: {', '.join(TYPE_PLURAL_MAP.keys())}")
        sys.exit(1)

    type_plural = TYPE_PLURAL_MAP[obj_type]

    print(f"=== meta-remove: {obj_type}.{obj_name} ===")
    print()

    if args.DryRun:
        print("[DRY-RUN] No changes will be made")
        print()

    actions = 0
    errors = 0

    # --- 1. Find object files ---
    type_dir = os.path.join(config_dir, type_plural)
    obj_xml = os.path.join(type_dir, f"{obj_name}.xml")
    obj_dir = os.path.join(type_dir, obj_name)

    has_xml = os.path.isfile(obj_xml)
    has_dir = os.path.isdir(obj_dir)

    if not has_xml and not has_dir:
        # Check if registered in Configuration.xml before proceeding
        cfg_check_tree = etree.parse(config_xml, etree.XMLParser(remove_blank_text=False))
        cfg_check_root = cfg_check_tree.getroot()
        child_objects = cfg_check_root.find(f"{{{MD_NS}}}Configuration/{{{MD_NS}}}ChildObjects")
        registered_in_cfg = False
        if child_objects is not None:
            for child in child_objects:
                if isinstance(child.tag, str) and etree.QName(child.tag).localname == obj_type and (child.text or "").strip() == obj_name:
                    registered_in_cfg = True
                    break
        if not registered_in_cfg:
            print(f"[ERROR] Object not found: {type_plural}/{obj_name}.xml and not registered in Configuration.xml")
            sys.exit(1)
        print(f"[WARN]  Object files not found: {type_plural}/{obj_name}.xml")
        print("        Proceeding with deregistration only...")
    else:
        if has_xml:
            print(f"[FOUND] {type_plural}/{obj_name}.xml")
        if has_dir:
            file_count = sum(len(files) for _, _, files in os.walk(obj_dir))
            print(f"[FOUND] {type_plural}/{obj_name}/ ({file_count} files)")

    # --- 2. Reference check ---
    print()
    print("--- Reference check ---")

    search_patterns = []

    # 1) XML type references
    if obj_type in TYPE_REF_NAMES:
        for ref_name in TYPE_REF_NAMES[obj_type]:
            search_patterns.append(f"{ref_name}.{obj_name}")

    # 2) BSL code references
    ru_mgr = TYPE_RU_MANAGER.get(obj_type)
    if ru_mgr:
        search_patterns.append(f"{ru_mgr}.{obj_name}")
    search_patterns.append(f"{type_plural}.{obj_name}")

    # 3) CommonModule: method calls
    if obj_type == "CommonModule":
        search_patterns.append(f"{obj_name}.")

    # 4) ScheduledJob/EventSubscription handler references
    if obj_type == "CommonModule":
        search_patterns.append(f"<Handler>{obj_name}.")
        search_patterns.append(f"<MethodName>{obj_name}.")

    # Exclude object's own files
    exclude_dirs = []
    if has_dir:
        exclude_dirs.append(obj_dir)
    exclude_file = obj_xml if has_xml else ""

    # Search all XML and BSL files
    references = []
    search_extensions = (".xml", ".bsl")

    for root_path, dirs, files in os.walk(config_dir):
        for fname in files:
            ext = os.path.splitext(fname)[1].lower()
            if ext not in search_extensions:
                continue
            full_path = os.path.join(root_path, fname)

            # Skip own files
            if exclude_file and os.path.normcase(full_path) == os.path.normcase(exclude_file):
                continue
            skip = False
            for ed in exclude_dirs:
                if os.path.normcase(full_path).startswith(os.path.normcase(ed + os.sep)) or os.path.normcase(full_path) == os.path.normcase(ed):
                    skip = True
                    break
            if skip:
                continue

            # Get relative path
            rel_path = os.path.relpath(full_path, config_dir)
            rel_path_fwd = rel_path.replace("\\", "/")

            # Skip auto-cleaned files
            if rel_path_fwd == "Configuration.xml" or rel_path_fwd == "ConfigDumpInfo.xml" or rel_path_fwd.startswith("Subsystems"):
                continue

            try:
                with open(full_path, "r", encoding="utf-8-sig") as fh:
                    content = fh.read()
            except Exception:
                continue

            for pat in search_patterns:
                if pat in content:
                    references.append({"File": rel_path, "Pattern": pat})
                    break

    # Also check Type.Name references
    type_name_ref = f"{obj_type}.{obj_name}"
    already_found_files = {r["File"] for r in references}

    for root_path, dirs, files in os.walk(config_dir):
        for fname in files:
            if not fname.lower().endswith(".xml"):
                continue
            full_path = os.path.join(root_path, fname)

            if exclude_file and os.path.normcase(full_path) == os.path.normcase(exclude_file):
                continue
            skip = False
            for ed in exclude_dirs:
                if os.path.normcase(full_path).startswith(os.path.normcase(ed + os.sep)) or os.path.normcase(full_path) == os.path.normcase(ed):
                    skip = True
                    break
            if skip:
                continue

            rel_path = os.path.relpath(full_path, config_dir)
            rel_path_fwd = rel_path.replace("\\", "/")

            if rel_path_fwd == "Configuration.xml" or rel_path_fwd == "ConfigDumpInfo.xml" or rel_path_fwd.startswith("Subsystems"):
                continue

            if rel_path in already_found_files:
                continue

            try:
                with open(full_path, "r", encoding="utf-8-sig") as fh:
                    content = fh.read()
            except Exception:
                continue

            if type_name_ref in content:
                references.append({"File": rel_path, "Pattern": type_name_ref})

    if references:
        print(f"[WARN]  Found {len(references)} reference(s) to {obj_type}.{obj_name}:")
        print()
        shown = 0
        for ref in references:
            print(f"        {ref['File']}")
            print(f"          pattern: {ref['Pattern']}")
            shown += 1
            if shown >= 20:
                remaining = len(references) - shown
                if remaining > 0:
                    print(f"        ... and {remaining} more")
                break
        print()

        if not args.Force:
            print(f"[ERROR] Cannot remove: object has {len(references)} reference(s).")
            print("        Use -Force to remove anyway, or fix references first.")
            sys.exit(1)
        else:
            print("[WARN]  -Force specified, proceeding despite references")
    else:
        print("[OK]    No references found")

    # --- 3. Remove from Configuration.xml ChildObjects ---
    print()
    print("--- Configuration.xml ---")

    xml_parser = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(config_xml, xml_parser)
    xml_root = tree.getroot()

    cfg_node = xml_root.find(f"{{{MD_NS}}}Configuration")
    if cfg_node is None:
        print("[ERROR] Configuration element not found in Configuration.xml")
        errors += 1
    else:
        child_objects = cfg_node.find(f"{{{MD_NS}}}ChildObjects")
        if child_objects is not None:
            found = False
            for child in list(child_objects):
                if not isinstance(child.tag, str):
                    continue
                if localname(child) == obj_type and (child.text or "").strip() == obj_name:
                    found = True
                    if not args.DryRun:
                        # Remove preceding whitespace (tail of previous sibling or text of parent)
                        prev = child.getprevious()
                        if prev is not None:
                            if prev.tail and prev.tail.strip() == "":
                                prev.tail = prev.tail.rsplit("\n", 1)[0] + "\n" if "\n" in prev.tail else ""
                                if not prev.tail.strip():
                                    # Keep just the last newline+indent before the next element
                                    pass
                        child_objects.remove(child)
                    print(f"[OK]    Removed <{obj_type}>{obj_name}</{obj_type}> from ChildObjects")
                    actions += 1
                    break
            if not found:
                print(f"[WARN]  <{obj_type}>{obj_name}</{obj_type}> not found in ChildObjects")

        # Save Configuration.xml
        if actions > 0 and not args.DryRun:
            save_xml_bom(tree, config_xml)
            print("[OK]    Configuration.xml saved")

    # --- 4. Remove from subsystem Content ---
    print()
    print("--- Subsystems ---")

    subsystems_dir = os.path.join(config_dir, "Subsystems")
    subsystems_found = 0
    subsystems_cleaned = 0

    def remove_from_subsystems(dir_path):
        nonlocal subsystems_found, subsystems_cleaned

        if not os.path.isdir(dir_path):
            return

        for fname in os.listdir(dir_path):
            if not fname.lower().endswith(".xml"):
                continue
            xml_file = os.path.join(dir_path, fname)
            if not os.path.isfile(xml_file):
                continue

            ss_parser = etree.XMLParser(remove_blank_text=False)
            try:
                ss_tree = etree.parse(xml_file, ss_parser)
            except Exception:
                continue

            ss_root = ss_tree.getroot()
            ss_node = None
            for child in ss_root:
                if isinstance(child.tag, str) and localname(child) == "Subsystem":
                    ss_node = child
                    break
            if ss_node is None:
                continue

            props_node = ss_node.find(f"{{{MD_NS}}}Properties")
            if props_node is None:
                continue

            content_node = props_node.find(f"{{{MD_NS}}}Content")
            if content_node is None:
                continue

            ss_name_node = props_node.find(f"{{{MD_NS}}}Name")
            ss_name = ss_name_node.text if ss_name_node is not None and ss_name_node.text else os.path.splitext(fname)[0]

            target_ref = f"{obj_type}.{obj_name}"
            modified = False

            for item in list(content_node):
                if not isinstance(item.tag, str):
                    continue
                val = (item.text or "").strip()
                if val == target_ref:
                    subsystems_found += 1
                    if not args.DryRun:
                        content_node.remove(item)
                        modified = True
                    print(f"[OK]    Removed from subsystem '{ss_name}'")
                    subsystems_cleaned += 1

            if modified and not args.DryRun:
                save_xml_bom(ss_tree, xml_file)

            # Recurse into child subsystems
            base_name = os.path.splitext(fname)[0]
            child_dir = os.path.join(dir_path, base_name, "Subsystems")
            if os.path.isdir(child_dir):
                remove_from_subsystems(child_dir)

    if os.path.isdir(subsystems_dir):
        remove_from_subsystems(subsystems_dir)
        if subsystems_cleaned == 0:
            print("[OK]    Not referenced in any subsystem")
    else:
        print("[OK]    No Subsystems directory")

    # --- 5. Delete object files ---
    print()
    print("--- Files ---")

    if not args.KeepFiles:
        if has_dir and not args.DryRun:
            shutil.rmtree(obj_dir)
            print(f"[OK]    Deleted directory: {type_plural}/{obj_name}/")
            actions += 1
        elif has_dir:
            print(f"[DRY]   Would delete directory: {type_plural}/{obj_name}/")
            actions += 1

        if has_xml and not args.DryRun:
            os.remove(obj_xml)
            print(f"[OK]    Deleted file: {type_plural}/{obj_name}.xml")
            actions += 1
        elif has_xml:
            print(f"[DRY]   Would delete file: {type_plural}/{obj_name}.xml")
            actions += 1

        if not has_xml and not has_dir:
            print("[OK]    No files to delete")
    else:
        print("[SKIP]  File deletion skipped (-KeepFiles)")

    # --- Summary ---
    print()
    total_actions = actions + subsystems_cleaned
    if args.DryRun:
        print(f"=== Dry run complete: {total_actions} actions would be performed ===")
    else:
        print(f"=== Done: {total_actions} actions performed ({subsystems_cleaned} subsystem references removed) ===")

    if errors > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
