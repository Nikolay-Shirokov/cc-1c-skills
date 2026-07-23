#!/usr/bin/env python3
# interface-edit v1.8 — Edit 1C CommandInterface.xml
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import subprocess
import sys
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


def detect_format_version(d):
    while d:
        cfg_path = os.path.join(d, "Configuration.xml")
        if os.path.isfile(cfg_path):
            with open(cfg_path, "r", encoding="utf-8-sig") as f:
                head = f.read(2000)
            m = re.search(r'<MetaDataObject[^>]+version="(\d+\.\d+)"', head)
            if m:
                return m.group(1)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return "2.17"


CI_NS = "http://v8.1c.ru/8.3/xcf/extrnprops"
XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
XS_NS = "http://www.w3.org/2001/XMLSchema"

SECTION_ORDER = ["CommandsVisibility", "CommandsPlacement", "CommandsOrder", "SubsystemsOrder", "GroupsOrder"]


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


def import_ci_fragment(xml_string):
    wrapper = (
        f'<_W xmlns="{CI_NS}" xmlns:xr="{XR_NS}" '
        f'xmlns:xsi="{XSI_NS}" xmlns:xs="{XS_NS}">{xml_string}</_W>'
    )
    frag = etree.fromstring(wrapper.encode("utf-8"))
    nodes = []
    for child in frag:
        nodes.append(child)
    return nodes


def parse_value_list(val):
    val = val.strip()
    if val.startswith("["):
        arr = json.loads(val)
        return [str(item) for item in arr]
    return [val]


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


TYPE_NORM_MAP = {
    'Catalogs': 'Catalog', 'Documents': 'Document', 'Enums': 'Enum',
    'Constants': 'Constant', 'Reports': 'Report', 'DataProcessors': 'DataProcessor',
    'InformationRegisters': 'InformationRegister', 'AccumulationRegisters': 'AccumulationRegister',
    'AccountingRegisters': 'AccountingRegister', 'CalculationRegisters': 'CalculationRegister',
    'ChartsOfAccounts': 'ChartOfAccounts', 'ChartsOfCharacteristicTypes': 'ChartOfCharacteristicTypes',
    'ChartsOfCalculationTypes': 'ChartOfCalculationTypes',
    'BusinessProcesses': 'BusinessProcess', 'Tasks': 'Task',
    'ExchangePlans': 'ExchangePlan', 'DocumentJournals': 'DocumentJournal',
    'CommonModules': 'CommonModule', 'CommonCommands': 'CommonCommand',
    'CommonForms': 'CommonForm', 'CommonPictures': 'CommonPicture',
    'CommonTemplates': 'CommonTemplate', 'CommonAttributes': 'CommonAttribute',
    'CommandGroups': 'CommandGroup', 'Roles': 'Role',
    'Subsystems': 'Subsystem', 'StyleItems': 'StyleItem',
    # Russian singular
    'Справочник': 'Catalog', 'Документ': 'Document', 'Перечисление': 'Enum',
    'Константа': 'Constant', 'Отчёт': 'Report', 'Отчет': 'Report', 'Обработка': 'DataProcessor',
    'РегистрСведений': 'InformationRegister', 'РегистрНакопления': 'AccumulationRegister',
    'РегистрБухгалтерии': 'AccountingRegister',
    'ПланСчетов': 'ChartOfAccounts', 'ПланВидовХарактеристик': 'ChartOfCharacteristicTypes',
    'БизнесПроцесс': 'BusinessProcess', 'Задача': 'Task',
    'ПланОбмена': 'ExchangePlan', 'ЖурналДокументов': 'DocumentJournal',
    'ОбщийМодуль': 'CommonModule', 'ОбщаяКоманда': 'CommonCommand',
    'ОбщаяФорма': 'CommonForm', 'Подсистема': 'Subsystem',
    # Russian plural
    'Справочники': 'Catalog', 'Документы': 'Document', 'Перечисления': 'Enum',
    'Константы': 'Constant', 'Отчёты': 'Report', 'Отчеты': 'Report', 'Обработки': 'DataProcessor',
    'РегистрыСведений': 'InformationRegister', 'РегистрыНакопления': 'AccumulationRegister',
    'РегистрыБухгалтерии': 'AccountingRegister',
    'ПланыСчетов': 'ChartOfAccounts', 'ПланыВидовХарактеристик': 'ChartOfCharacteristicTypes',
    'БизнесПроцессы': 'BusinessProcess', 'Задачи': 'Task',
    'ПланыОбмена': 'ExchangePlan', 'ЖурналыДокументов': 'DocumentJournal',
    'Подсистемы': 'Subsystem',
}


def normalize_cmd_name(name):
    if not name or '.' not in name:
        return name
    dot_idx = name.index('.')
    first = name[:dot_idx]
    rest = name[dot_idx:]
    if first in TYPE_NORM_MAP:
        normalized = TYPE_NORM_MAP[first] + rest
        if normalized != name:
            print(f'[NORM] Command: {name} -> {normalized}')
        return normalized
    return name


def find_command_by_name(section, cmd_name):
    for child in section:
        if isinstance(child.tag, str) and localname(child) == "Command":
            if child.get("name") == cmd_name:
                return child
    return None


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Edit 1C CommandInterface.xml", allow_abbrev=False)
    parser.add_argument("-CIPath", "-Path", required=True)
    parser.add_argument("-DefinitionFile", default=None)
    parser.add_argument("-Operation", default=None, choices=["hide", "show", "place", "order", "subsystem-order", "group-order"])
    parser.add_argument("-Value", default=None)
    parser.add_argument("-CreateIfMissing", action="store_true")
    parser.add_argument("-NoValidate", action="store_true")
    args = parser.parse_args()

    # --- Mode validation ---
    if args.DefinitionFile and args.Operation:
        print("Cannot use both -DefinitionFile and -Operation", file=sys.stderr)
        sys.exit(1)
    if not args.DefinitionFile and not args.Operation:
        print("Either -DefinitionFile or -Operation is required", file=sys.stderr)
        sys.exit(1)

    # --- Detect format version ---
    ci_dir = os.path.dirname(os.path.abspath(args.CIPath))
    format_version = detect_format_version(ci_dir)

    # --- Resolve path ---
    ci_path = args.CIPath
    if not os.path.isabs(ci_path):
        ci_path = os.path.join(os.getcwd(), ci_path)
    resolved_path = ci_path

    assert_edit_allowed(ci_path, "editable")

    # --- Create if missing ---
    if not os.path.isfile(ci_path):
        if args.CreateIfMissing:
            parent_dir = os.path.dirname(ci_path)
            if parent_dir and not os.path.isdir(parent_dir):
                os.makedirs(parent_dir, exist_ok=True)
            empty_ci = (
                f'<?xml version="1.0" encoding="UTF-8"?>\n'
                f'<CommandInterface xmlns="{CI_NS}"\n'
                f'\txmlns:xr="{XR_NS}"\n'
                f'\txmlns:xs="{XS_NS}"\n'
                f'\txmlns:xsi="{XSI_NS}"\n'
                f'\tversion="{format_version}">\n'
                f'</CommandInterface>'
            )
            with open(ci_path, "w", encoding="utf-8-sig") as fh:
                fh.write(empty_ci)
            print(f"[INFO] Created new CommandInterface.xml: {ci_path}")
        else:
            print(f"File not found: {ci_path} (use -CreateIfMissing to create)", file=sys.stderr)
            sys.exit(1)
    resolved_path = os.path.abspath(ci_path)

    # --- Load XML ---
    xml_parser = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(resolved_path, xml_parser)
    root = tree.getroot()

    add_count = 0
    remove_count = 0
    modify_count = 0

    if localname(root) != "CommandInterface":
        print(f"Expected <CommandInterface> root element, got <{localname(root)}>", file=sys.stderr)
        sys.exit(1)

    def ensure_section(section_name):
        # Find existing
        for child in root:
            if isinstance(child.tag, str) and localname(child) == section_name:
                return child

        # Create new section
        new_section = etree.Element(f"{{{CI_NS}}}{section_name}")

        my_idx = SECTION_ORDER.index(section_name) if section_name in SECTION_ORDER else -1
        ref_node = None
        for child in root:
            if not isinstance(child.tag, str):
                continue
            child_idx = SECTION_ORDER.index(localname(child)) if localname(child) in SECTION_ORDER else -1
            if child_idx > my_idx:
                ref_node = child
                break

        root_indent = get_child_indent(root)
        new_section.text = "\r\n" + root_indent

        if ref_node is not None:
            # Insert before ref_node
            idx = list(root).index(ref_node)
            new_section.tail = "\r\n" + root_indent
            root.insert(idx, new_section)
        else:
            insert_before_closing(root, new_section, root_indent)

        return new_section

    def do_hide(commands):
        nonlocal add_count, modify_count
        commands = [normalize_cmd_name(c) for c in commands]
        section = ensure_section("CommandsVisibility")
        section_indent = get_child_indent(section)

        for cmd in commands:
            existing = find_command_by_name(section, cmd)
            if existing is not None:
                common_el = None
                for vis in existing:
                    if isinstance(vis.tag, str) and localname(vis) == "Visibility":
                        for c in vis:
                            if isinstance(c.tag, str) and localname(c) == "Common":
                                common_el = c
                                break
                if common_el is not None and (common_el.text or "").strip() == "false":
                    warn(f"Already hidden: {cmd}")
                    continue
                if common_el is not None:
                    common_el.text = "false"
                    modify_count += 1
                    info(f"Changed to hidden: {cmd}")
                    continue

            frag_xml = f'<Command name="{cmd}"><Visibility><xr:Common>false</xr:Common></Visibility></Command>'
            nodes = import_ci_fragment(frag_xml)
            if nodes:
                insert_before_closing(section, nodes[0], section_indent)
                add_count += 1
                info(f"Hidden: {cmd}")

    def do_show(commands):
        nonlocal add_count, modify_count
        commands = [normalize_cmd_name(c) for c in commands]
        section = None
        for child in root:
            if isinstance(child.tag, str) and localname(child) == "CommandsVisibility":
                section = child
                break

        for cmd in commands:
            if section is None:
                section = ensure_section("CommandsVisibility")

            existing = find_command_by_name(section, cmd)
            if existing is not None:
                common_el = None
                for vis in existing:
                    if isinstance(vis.tag, str) and localname(vis) == "Visibility":
                        for c in vis:
                            if isinstance(c.tag, str) and localname(c) == "Common":
                                common_el = c
                                break
                if common_el is not None and (common_el.text or "").strip() == "true":
                    warn(f"Already shown: {cmd}")
                    continue
                if common_el is not None and (common_el.text or "").strip() == "false":
                    common_el.text = "true"
                    modify_count += 1
                    info(f"Changed to shown: {cmd}")
                    continue

            section_indent = get_child_indent(section)
            frag_xml = f'<Command name="{cmd}"><Visibility><xr:Common>true</xr:Common></Visibility></Command>'
            nodes = import_ci_fragment(frag_xml)
            if nodes:
                insert_before_closing(section, nodes[0], section_indent)
                add_count += 1
                info(f"Shown: {cmd}")

    def do_place(json_val):
        nonlocal add_count, modify_count
        defn = json_val if isinstance(json_val, dict) else json.loads(json_val)
        cmd_name = normalize_cmd_name(str(defn["command"]))
        group_name = str(defn["group"])
        if not cmd_name or not group_name:
            print("place requires {command, group}", file=sys.stderr)
            sys.exit(1)

        section = ensure_section("CommandsPlacement")
        section_indent = get_child_indent(section)

        existing = find_command_by_name(section, cmd_name)
        if existing is not None:
            for child in existing:
                if isinstance(child.tag, str) and localname(child) == "CommandGroup":
                    child.text = group_name
                    modify_count += 1
                    info(f"Updated placement: {cmd_name} -> {group_name}")
                    return

        frag_xml = f'<Command name="{cmd_name}"><CommandGroup>{group_name}</CommandGroup><Placement>Auto</Placement></Command>'
        nodes = import_ci_fragment(frag_xml)
        if nodes:
            insert_before_closing(section, nodes[0], section_indent)
            add_count += 1
            info(f"Placed: {cmd_name} -> {group_name}")

    def do_order(json_val):
        nonlocal add_count, remove_count
        defn = json_val if isinstance(json_val, dict) else json.loads(json_val)
        group_name = str(defn["group"])
        commands = [normalize_cmd_name(str(c)) for c in defn["commands"]]
        if not group_name or not commands:
            print("order requires {group, commands:[...]}", file=sys.stderr)
            sys.exit(1)

        section = ensure_section("CommandsOrder")
        section_indent = get_child_indent(section)

        # Remove existing entries for this group
        to_remove = []
        for child in section:
            if not isinstance(child.tag, str) or localname(child) != "Command":
                continue
            for gc in child:
                if isinstance(gc.tag, str) and localname(gc) == "CommandGroup" and (gc.text or "").strip() == group_name:
                    to_remove.append(child)
                    break
        for node in to_remove:
            remove_with_indent(node)
            remove_count += 1

        # Add new entries
        for cmd_name in commands:
            frag_xml = f'<Command name="{cmd_name}"><CommandGroup>{group_name}</CommandGroup></Command>'
            nodes = import_ci_fragment(frag_xml)
            if nodes:
                insert_before_closing(section, nodes[0], section_indent)
                add_count += 1
        info(f"Set order for {group_name} : {len(commands)} commands")

    def do_subsystem_order(json_val):
        nonlocal add_count, remove_count
        parsed = json_val if isinstance(json_val, list) else json.loads(json_val)
        subsystems = [str(s) for s in parsed]
        if not subsystems:
            print("subsystem-order requires array of subsystem paths", file=sys.stderr)
            sys.exit(1)

        section = ensure_section("SubsystemsOrder")
        section_indent = get_child_indent(section)

        # Clear existing
        for child in list(section):
            if isinstance(child.tag, str):
                remove_with_indent(child)
                remove_count += 1

        # Add new entries
        for sub in subsystems:
            new_el = etree.Element(f"{{{CI_NS}}}Subsystem")
            new_el.text = sub
            insert_before_closing(section, new_el, section_indent)
            add_count += 1
        info(f"Set subsystem order: {len(subsystems)} entries")

    def do_group_order(json_val):
        nonlocal add_count, remove_count
        parsed = json_val if isinstance(json_val, list) else json.loads(json_val)
        groups = [str(g) for g in parsed]
        if not groups:
            print("group-order requires array of group names", file=sys.stderr)
            sys.exit(1)

        section = ensure_section("GroupsOrder")
        section_indent = get_child_indent(section)

        # Clear existing
        for child in list(section):
            if isinstance(child.tag, str):
                remove_with_indent(child)
                remove_count += 1

        # Add new entries
        for grp in groups:
            new_el = etree.Element(f"{{{CI_NS}}}Group")
            new_el.text = grp
            insert_before_closing(section, new_el, section_indent)
            add_count += 1
        info(f"Set group order: {len(groups)} entries")

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

        if op_name == "hide":
            do_hide(parse_value_list(op_value))
        elif op_name == "show":
            do_show(parse_value_list(op_value))
        elif op_name == "place":
            do_place(op_value)
        elif op_name == "order":
            do_order(op_value)
        elif op_name == "subsystem-order":
            do_subsystem_order(op_value)
        elif op_name == "group-order":
            do_group_order(op_value)
        else:
            print(f"Unknown operation: {op_name}", file=sys.stderr)
            sys.exit(1)

    # --- Save ---
    save_xml_bom(tree, resolved_path)
    info(f"Saved: {resolved_path}")

    # --- Auto-validate ---
    if not args.NoValidate:
        validate_script = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "interface-validate", "scripts", "interface-validate.py"))
        if os.path.isfile(validate_script):
            print()
            print("--- Running interface-validate ---")
            subprocess.run([sys.executable, validate_script, "-CIPath", resolved_path])

    # --- Summary ---
    print()
    print("=== interface-edit summary ===")
    print(f"  Added:    {add_count}")
    print(f"  Removed:  {remove_count}")
    print(f"  Modified: {modify_count}")
    sys.exit(0)


if __name__ == "__main__":
    main()
