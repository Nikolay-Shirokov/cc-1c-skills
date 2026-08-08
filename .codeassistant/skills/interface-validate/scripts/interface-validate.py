#!/usr/bin/env python3
# interface-validate v1.1 — Validate 1C CommandInterface.xml structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Validates CommandInterface.xml sections, command references, order, duplicates."""
import sys, os, argparse, re
from lxml import etree

NS_CI  = 'http://v8.1c.ru/8.3/xcf/extrnprops'
NS_XR  = 'http://v8.1c.ru/8.3/xcf/readable'
NS_XSI = 'http://www.w3.org/2001/XMLSchema-instance'
NS_XS  = 'http://www.w3.org/2001/XMLSchema'

NS = {
    'ci':  NS_CI,
    'xr':  NS_XR,
    'xsi': NS_XSI,
    'xs':  NS_XS,
}

VALID_SECTIONS = [
    'CommandsVisibility', 'CommandsPlacement', 'CommandsOrder',
    'SubsystemsOrder', 'GroupsOrder'
]

STD_CMD_PATTERN   = re.compile(r'^[A-Za-z]+\.[^\s\.]+\.StandardCommand\.\w+$')
CUSTOM_CMD_PATTERN = re.compile(r'^[A-Za-z]+\.[^\s\.]+\.Command\.\w+$')
COMMON_CMD_PATTERN = re.compile(r'^CommonCommand\.\w+$')
UUID_CMD_PATTERN   = re.compile(
    r'^0:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
)


class Reporter:
    def __init__(self, max_errors, detailed=False):
        self.errors = 0
        self.warnings = 0
        self.ok_count = 0
        self.stopped = False
        self.max_errors = max_errors
        self.detailed = detailed
        self.lines = []

    def out(self, msg=''):
        self.lines.append(msg)

    def ok(self, msg):
        self.ok_count += 1
        if self.detailed:
            self.lines.append(f'[OK]    {msg}')

    def error(self, msg):
        self.errors += 1
        self.lines.append(f'[ERROR] {msg}')
        if self.errors >= self.max_errors:
            self.stopped = True

    def warn(self, msg):
        self.warnings += 1
        self.lines.append(f'[WARN]  {msg}')

    def text(self):
        return '\r\n'.join(self.lines) + '\r\n'


def find_duplicates(items):
    seen = {}
    dupes = []
    for item in items:
        seen[item] = seen.get(item, 0) + 1
    for item, count in seen.items():
        if count > 1 and item not in dupes:
            dupes.append(item)
    return dupes


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description='Validate 1C CommandInterface.xml structure', allow_abbrev=False
    )
    parser.add_argument('-CIPath', '-Path', dest='CIPath', required=True)
    parser.add_argument('-Detailed', action='store_true')
    parser.add_argument('-MaxErrors', dest='MaxErrors', type=int, default=30)
    parser.add_argument('-OutFile', dest='OutFile', default='')
    args = parser.parse_args()

    ci_path = args.CIPath
    detailed = args.Detailed
    max_errors = args.MaxErrors
    out_file = args.OutFile

    # --- Resolve path ---
    if not os.path.isabs(ci_path):
        ci_path = os.path.join(os.getcwd(), ci_path)

    # A: Directory → Ext/CommandInterface.xml
    if os.path.isdir(ci_path):
        ci_path = os.path.join(ci_path, 'Ext', 'CommandInterface.xml')
    # B1: Missing Ext/
    if not os.path.exists(ci_path):
        fn = os.path.basename(ci_path)
        if fn == 'CommandInterface.xml':
            c = os.path.join(os.path.dirname(ci_path), 'Ext', fn)
            if os.path.exists(c):
                ci_path = c

    if not os.path.exists(ci_path):
        print(f'[ERROR] File not found: {ci_path}')
        sys.exit(1)

    resolved_path = os.path.abspath(ci_path)

    # --- Derive context name from path ---
    context_name = ''
    parts = re.split(r'[/\\]', resolved_path)
    for i in range(len(parts)):
        if parts[i] == 'Subsystems' and (i + 1) < len(parts):
            context_name = parts[i + 1]
    if not context_name:
        context_name = 'Root'

    r = Reporter(max_errors, detailed)
    all_command_names = []

    r.out(f'=== Validation: CommandInterface ({context_name}) ===')
    r.out('')

    # --- 1. XML well-formedness + root structure ---
    xml_doc = None
    try:
        xml_parser = etree.XMLParser(remove_blank_text=False)
        xml_doc = etree.parse(resolved_path, xml_parser)
    except etree.XMLSyntaxError as e:
        r.error(f'1. XML parse error: {e}')
        r.stopped = True

    root = None
    if not r.stopped:
        root = xml_doc.getroot()
        root_local = etree.QName(root.tag).localname

        if root_local != 'CommandInterface':
            r.error(f'1. Root element: expected <CommandInterface>, got <{root_local}>')
            r.stopped = True
        else:
            ns_uri = etree.QName(root.tag).namespace or ''
            version = root.get('version', '')
            expected_ns = NS_CI
            if ns_uri != expected_ns:
                r.error(f'1. Root namespace: expected {expected_ns}, got {ns_uri}')
            elif not version:
                r.warn('1. Root structure: CommandInterface, namespace valid, but no version attribute')
            else:
                r.ok(f'1. Root structure: CommandInterface, version {version}, namespace valid')

    # --- 2. Valid child elements ---
    found_sections = []
    if not r.stopped:
        invalid_elements = []
        for child in root:
            if not isinstance(child.tag, str):
                continue
            local_name = etree.QName(child.tag).localname
            if local_name in VALID_SECTIONS:
                found_sections.append(local_name)
            else:
                invalid_elements.append(local_name)
        if len(invalid_elements) > 0:
            r.error(f'2. Invalid child elements: {", ".join(invalid_elements)}')
        else:
            r.ok(f'2. Child elements: {len(found_sections)} valid sections')

    # --- 3. Section order ---
    if not r.stopped:
        order_ok = True
        last_idx = -1
        for sec in found_sections:
            idx = VALID_SECTIONS.index(sec) if sec in VALID_SECTIONS else -1
            if idx < last_idx:
                r.error(f"3. Section order: '{sec}' appears after a later section (expected: CommandsVisibility -> CommandsPlacement -> CommandsOrder -> SubsystemsOrder -> GroupsOrder)")
                order_ok = False
                break
            last_idx = idx
        if order_ok:
            r.ok('3. Section order: correct')

    # --- 4. No duplicate sections ---
    if not r.stopped:
        dupes = find_duplicates(found_sections)
        if dupes:
            r.error(f'4. Duplicate sections: {", ".join(dupes)}')
        else:
            r.ok('4. No duplicate sections')

    # --- 5. CommandsVisibility ---
    vis_names = []
    if not r.stopped:
        vis_section = root.find(f'{{{NS_CI}}}CommandsVisibility')
        if vis_section is not None:
            vis_ok = True
            vis_count = 0
            for cmd in vis_section:
                if not isinstance(cmd.tag, str):
                    continue
                vis_count += 1
                cmd_name = cmd.get('name', '')
                if not cmd_name:
                    r.error("5. CommandsVisibility: Command element without 'name' attribute")
                    vis_ok = False
                    continue
                vis_names.append(cmd_name)
                all_command_names.append(cmd_name)
                visibility = cmd.find(f'{{{NS_CI}}}Visibility')
                if visibility is None:
                    r.error(f'5. CommandsVisibility[{cmd_name}]: missing <Visibility>')
                    vis_ok = False
                    continue
                common = visibility.find(f'{{{NS_XR}}}Common')
                if common is None:
                    r.error(f'5. CommandsVisibility[{cmd_name}]: missing <xr:Common>')
                    vis_ok = False
                    continue
                val = (common.text or '').strip()
                if val not in ('true', 'false'):
                    r.error(f"5. CommandsVisibility[{cmd_name}]: xr:Common='{val}' (expected true/false)")
                    vis_ok = False
            if vis_ok:
                r.ok(f'5. CommandsVisibility: {vis_count} entries, all valid')
        # CommandsVisibility not present — no check needed

    # --- 6. CommandsVisibility duplicates ---
    if not r.stopped:
        if len(vis_names) > 0:
            dupes = find_duplicates(vis_names)
            if dupes:
                r.warn(f'6. CommandsVisibility: duplicates: {", ".join(dupes)}')
            else:
                r.ok('6. CommandsVisibility: no duplicates')

    # --- 7. CommandsPlacement ---
    if not r.stopped:
        plc_section = root.find(f'{{{NS_CI}}}CommandsPlacement')
        if plc_section is not None:
            plc_ok = True
            plc_count = 0
            for cmd in plc_section:
                if not isinstance(cmd.tag, str):
                    continue
                plc_count += 1
                cmd_name = cmd.get('name', '')
                if not cmd_name:
                    r.error("7. CommandsPlacement: Command without 'name' attribute")
                    plc_ok = False
                    continue
                all_command_names.append(cmd_name)
                grp_el = cmd.find(f'{{{NS_CI}}}CommandGroup')
                if grp_el is None or not (grp_el.text or '').strip():
                    r.error(f'7. CommandsPlacement[{cmd_name}]: missing or empty <CommandGroup>')
                    plc_ok = False
                    continue
                placement_el = cmd.find(f'{{{NS_CI}}}Placement')
                if placement_el is None:
                    r.error(f'7. CommandsPlacement[{cmd_name}]: missing <Placement>')
                    plc_ok = False
                elif (placement_el.text or '').strip() != 'Auto':
                    r.warn(f"7. CommandsPlacement[{cmd_name}]: Placement='{(placement_el.text or '').strip()}' (expected Auto)")
            if plc_ok:
                r.ok(f'7. CommandsPlacement: {plc_count} entries, all valid')
        # CommandsPlacement not present — no check needed

    # --- 8. CommandsOrder ---
    if not r.stopped:
        ord_section = root.find(f'{{{NS_CI}}}CommandsOrder')
        if ord_section is not None:
            ord_ok = True
            ord_count = 0
            for cmd in ord_section:
                if not isinstance(cmd.tag, str):
                    continue
                ord_count += 1
                cmd_name = cmd.get('name', '')
                if not cmd_name:
                    r.error("8. CommandsOrder: Command without 'name' attribute")
                    ord_ok = False
                    continue
                all_command_names.append(cmd_name)
                grp_el = cmd.find(f'{{{NS_CI}}}CommandGroup')
                if grp_el is None or not (grp_el.text or '').strip():
                    r.error(f'8. CommandsOrder[{cmd_name}]: missing or empty <CommandGroup>')
                    ord_ok = False
            if ord_ok:
                r.ok(f'8. CommandsOrder: {ord_count} entries, all valid')
        # CommandsOrder not present — no check needed

    # --- 9. SubsystemsOrder format ---
    sub_names = []
    if not r.stopped:
        sub_section = root.find(f'{{{NS_CI}}}SubsystemsOrder')
        if sub_section is not None:
            sub_ok = True
            sub_count = 0
            for sub_el in sub_section:
                if not isinstance(sub_el.tag, str):
                    continue
                sub_count += 1
                text = (sub_el.text or '').strip()
                sub_names.append(text)
                if not text:
                    r.error('9. SubsystemsOrder: empty <Subsystem> element')
                    sub_ok = False
                elif not text.startswith('Subsystem.'):
                    r.error(f"9. SubsystemsOrder: '{text}' - expected format Subsystem.X...")
                    sub_ok = False
            if sub_ok:
                r.ok(f'9. SubsystemsOrder: {sub_count} entries, all valid format')
        # SubsystemsOrder not present — no check needed

    # --- 10. SubsystemsOrder duplicates ---
    if not r.stopped:
        if len(sub_names) > 0:
            dupes = find_duplicates(sub_names)
            if dupes:
                r.warn(f'10. SubsystemsOrder: duplicates: {", ".join(dupes)}')
            else:
                r.ok('10. SubsystemsOrder: no duplicates')

    # --- 11. GroupsOrder entries ---
    grp_names = []
    if not r.stopped:
        grp_section = root.find(f'{{{NS_CI}}}GroupsOrder')
        if grp_section is not None:
            grp_ok = True
            grp_count = 0
            for grp in grp_section:
                if not isinstance(grp.tag, str):
                    continue
                grp_count += 1
                text = (grp.text or '').strip()
                grp_names.append(text)
                if not text:
                    r.error('11. GroupsOrder: empty <Group> element')
                    grp_ok = False
            if grp_ok:
                r.ok(f'11. GroupsOrder: {grp_count} entries, all valid')
        # GroupsOrder not present — no check needed

    # --- 12. GroupsOrder duplicates ---
    if not r.stopped:
        if len(grp_names) > 0:
            dupes = find_duplicates(grp_names)
            if dupes:
                r.warn(f'12. GroupsOrder: duplicates: {", ".join(dupes)}')
            else:
                r.ok('12. GroupsOrder: no duplicates')

    # --- 13. Command reference format ---
    if not r.stopped:
        if len(all_command_names) > 0:
            bad_refs = []
            for ref in all_command_names:
                if STD_CMD_PATTERN.match(ref):
                    continue
                if CUSTOM_CMD_PATTERN.match(ref):
                    continue
                if COMMON_CMD_PATTERN.match(ref):
                    continue
                if UUID_CMD_PATTERN.match(ref):
                    continue
                bad_refs.append(ref)
            if len(bad_refs) == 0:
                r.ok(f'13. Command reference format: all {len(all_command_names)} valid')
            else:
                shown = bad_refs[:5]
                suffix = ' ...' if len(bad_refs) > 5 else ''
                r.warn(f'13. Command reference format: {len(bad_refs)} unrecognized: {", ".join(shown)}{suffix}')

    # --- Finalize ---
    checks = r.ok_count + r.errors + r.warnings
    if r.errors == 0 and r.warnings == 0 and not detailed:
        result = f'=== Validation OK: CommandInterface ({context_name}) ({checks} checks) ==='
    else:
        r.out('')
        r.out(f'=== Result: {r.errors} errors, {r.warnings} warnings ({checks} checks) ===')
        result = '\r\n'.join(r.lines) + '\r\n'

    print(result, end='')

    if out_file:
        if not os.path.isabs(out_file):
            out_file = os.path.join(os.getcwd(), out_file)
        with open(out_file, 'w', encoding='utf-8-sig', newline='') as f:
            f.write(result)
        print(f'Written to: {out_file}')

    sys.exit(1 if r.errors > 0 else 0)


if __name__ == '__main__':
    main()
