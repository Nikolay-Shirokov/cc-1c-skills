#!/usr/bin/env python3
# meta-remove v1.5 — Remove metadata object from 1C configuration dump
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import sys
import shutil
from lxml import etree


# ============================================================
# Support guard (Ext/ParentConfigurations.bin) — see docs/1c-support-state-spec.md
# Blocks edits of vendor objects "на замке" / read-only configs. Trigger = bin
# present; reaction from .v8-project.json editingAllowedCheck (deny|warn|off,
# default deny). Never throws (except sys.exit on deny) — errors degrade to allow.
# ============================================================

def _sg_root_uuid(xml_path):
    if not os.path.isfile(xml_path):
        return None
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str) and child.get("uuid"):
                return child.get("uuid")
    except Exception:
        return None
    return None


def _sg_is_external_root(xml_path):
    if not os.path.isfile(xml_path):
        return False
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str):
                return child.tag.split("}")[-1] in ("ExternalDataProcessor", "ExternalReport")
    except Exception:
        return False
    return False

def _sg_find_v8project(start_dir):
    d = start_dir
    for _ in range(20):
        if not d:
            break
        pj = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pj):
            return pj
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def _sg_get_edit_mode(cfg_dir):
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(cfg_dir)
        if not pj:
            return "deny"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir)).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src:
                src_full = os.path.normcase(os.path.abspath(src)).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    if db.get("editingAllowedCheck"):
                        return db["editingAllowedCheck"]
        if proj.get("editingAllowedCheck"):
            return proj["editingAllowedCheck"]
        return "deny"
    except Exception:
        return "deny"


def assert_edit_allowed(target_path, require):
    try:
        rp = os.path.abspath(target_path)
        # Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
        if _sg_is_external_root(rp):
            return
        elem_uuid = _sg_root_uuid(rp)
        cfg_dir = None
        bin_path = None
        d = rp if os.path.isdir(rp) else os.path.dirname(rp)
        for _ in range(12):
            if not d:
                break
            if _sg_is_external_root(d + ".xml"):
                return
            if not elem_uuid:
                elem_uuid = _sg_root_uuid(d + ".xml")
            if not cfg_dir:
                cand = os.path.join(d, "Ext", "ParentConfigurations.bin")
                if os.path.exists(cand) or os.path.exists(os.path.join(d, "Configuration.xml")):
                    cfg_dir = d
                    bin_path = cand
            if elem_uuid and cfg_dir:
                break
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
        if not elem_uuid and cfg_dir:
            elem_uuid = _sg_root_uuid(os.path.join(cfg_dir, "Configuration.xml"))
        if not bin_path or not os.path.exists(bin_path):
            return
        data = open(bin_path, "rb").read()
        if len(data) <= 32:
            return
        if data[:3] == b"\xef\xbb\xbf":
            data = data[3:]
        text = data.decode("utf-8", "replace")
        h = re.match(r"\{6,(\d+),(\d+),", text)
        if not h:
            return
        g = int(h.group(1))
        k = int(h.group(2))
        if k == 0:
            return
        best = None
        if elem_uuid:
            for m in re.finditer(r"([0-2]),0," + re.escape(elem_uuid.lower()), text):
                f1 = int(m.group(1))
                if best is None or f1 < best:
                    best = f1
        blocked = False
        code = ""
        reason = ""
        if g == 1:
            blocked = True
            code = "capability-off"
            reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)"
        elif require == "removed":
            if best is not None and best != 2:
                blocked = True
                code = "not-removed"
                reason = "объект не снят с поддержки — удаление сломает обновления"
        else:
            if best is not None and best == 0:
                blocked = True
                code = "locked"
                reason = "объект на замке — редактирование сломает обновления"
        if not blocked:
            return
        mode = _sg_get_edit_mode(cfg_dir)
        if mode == "off":
            return
        if mode == "warn":
            sys.stderr.write(f"[support-guard] ПРЕДУПРЕЖДЕНИЕ: {reason}. Цель: {rp}\n")
            return
        head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
        cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
        off_note = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
        if code == "capability-off":
            state = f"Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «{rp}» редактировать нельзя."
            fix = (
                "Либо снять защиту явно (навык support-edit, два шага):\n"
                f'  1. support-edit -Path "{cfg_dir}" -Capability on — включить возможность изменения (объекты пока остаются на замке);\n'
                f'  2. support-edit -Path "{rp}" -Set editable — открыть этот объект для редактирования.\n'
                "  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
            )
        elif code == "not-removed":
            state = f"Состояние: объект «{rp}» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
            fix = (
                "Либо сначала снять объект с поддержки, затем удалять:\n"
                f'  support-edit -Path "{rp}" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно.'
            )
        else:
            state = f"Состояние: объект «{rp}» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
            fix = (
                "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):\n"
                f'  support-edit -Path "{rp}" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);\n'
                f'  support-edit -Path "{rp}" -Set off-support — снять с поддержки: обновления по объекту больше не приходят.'
            )
        sys.stderr.write(head + "\n" + state + "\n" + cfe + "\n" + fix + "\n" + off_note + "\n")
        sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        return

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


def _detect_xml_style(path):
    """Стиль существующего файла для round-trip-сохранения: BOM / EOL / регистр encoding /
    финальный перенос. None → файл новый (сохранить текущее поведение)."""
    try:
        raw = open(path, "rb").read()
    except OSError:
        return None
    bom = raw.startswith(b"\xef\xbb\xbf")
    body = raw[3:] if bom else raw
    crlf = b"\r\n" in body
    m = re.search(rb'encoding="([^"]+)"', body[:200])
    enc = m.group(1).decode("ascii") if m else "utf-8"
    final_nl = body.endswith(b"\n")
    return {"bom": bom, "crlf": crlf, "enc": enc, "final_nl": final_nl}


def _finalize_xml_bytes(xml_bytes, style):
    """Привести сериализованные байты к стилю оригинала (или к дефолту, если style is None)."""
    enc_decl = style["enc"] if style else "utf-8"
    xml_bytes = xml_bytes.replace(
        b"<?xml version='1.0' encoding='UTF-8'?>",
        b'<?xml version="1.0" encoding="' + enc_decl.encode("ascii") + b'"?>')
    # Канонизировать переносы к LF (убирает &#13; от \r в tail'ах)
    xml_bytes = (xml_bytes.replace(b"&#13;\n", b"\n").replace(b"&#13;", b"")
                 .replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
    # Финальный перенос — как в оригинале (новый файл → есть)
    want_final_nl = style["final_nl"] if style else True
    xml_bytes = xml_bytes.rstrip(b"\n")
    if want_final_nl:
        xml_bytes += b"\n"
    # EOL — как в оригинале (новый файл → LF, текущее поведение)
    if style and style["crlf"]:
        xml_bytes = xml_bytes.replace(b"\n", b"\r\n")
    return xml_bytes


def save_xml_bom(tree, path):
    style = _detect_xml_style(path)
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    xml_bytes = _finalize_xml_bytes(xml_bytes, style)
    with open(path, "wb") as f:
        if style is None or style["bom"]:
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

    # Support guard — removal requires the object be снят-с-поддержки (f1=2).
    assert_edit_allowed(obj_xml, "removed")

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
