#!/usr/bin/env python3
# role-validate v1.1 — Validate 1C role Rights.xml structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Validates role Rights.xml: root element, global flags, objects, rights, RLS, templates."""
import sys, os, argparse, re
from lxml import etree

GUID_PATTERN = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    re.IGNORECASE
)

RIGHTS_NS = 'http://v8.1c.ru/8.2/roles'

# --- Known rights per object type ---
KNOWN_RIGHTS = {
    'Configuration': [
        'Administration', 'DataAdministration', 'UpdateDataBaseConfiguration',
        'ConfigurationExtensionsAdministration', 'ActiveUsers', 'EventLog', 'ExclusiveMode',
        'ThinClient', 'ThickClient', 'WebClient', 'MobileClient', 'ExternalConnection',
        'Automation', 'Output', 'SaveUserData', 'TechnicalSpecialistMode',
        'InteractiveOpenExtDataProcessors', 'InteractiveOpenExtReports',
        'AnalyticsSystemClient', 'CollaborationSystemInfoBaseRegistration',
        'MainWindowModeNormal', 'MainWindowModeWorkplace',
        'MainWindowModeEmbeddedWorkplace', 'MainWindowModeFullscreenWorkplace', 'MainWindowModeKiosk',
    ],
    'Catalog': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete', 'InteractiveDeleteMarked',
        'InteractiveDeletePredefinedData', 'InteractiveSetDeletionMarkPredefinedData',
        'InteractiveClearDeletionMarkPredefinedData', 'InteractiveDeleteMarkedPredefinedData',
        'ReadDataHistory', 'ViewDataHistory', 'UpdateDataHistory',
        'UpdateDataHistoryOfMissingData', 'ReadDataHistoryOfMissingData',
        'UpdateDataHistorySettings', 'UpdateDataHistoryVersionComment',
        'EditDataHistoryVersionComment', 'SwitchToDataHistoryVersion',
    ],
    'Document': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'Posting', 'UndoPosting',
        'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete', 'InteractiveDeleteMarked',
        'InteractivePosting', 'InteractivePostingRegular', 'InteractiveUndoPosting',
        'InteractiveChangeOfPosted',
        'ReadDataHistory', 'ViewDataHistory', 'UpdateDataHistory',
        'UpdateDataHistoryOfMissingData', 'ReadDataHistoryOfMissingData',
        'UpdateDataHistorySettings', 'UpdateDataHistoryVersionComment',
        'EditDataHistoryVersionComment', 'SwitchToDataHistoryVersion',
    ],
    'InformationRegister': [
        'Read', 'Update', 'View', 'Edit', 'TotalsControl',
        'ReadDataHistory', 'ViewDataHistory', 'UpdateDataHistory',
        'UpdateDataHistoryOfMissingData', 'ReadDataHistoryOfMissingData',
        'UpdateDataHistorySettings', 'UpdateDataHistoryVersionComment',
        'EditDataHistoryVersionComment', 'SwitchToDataHistoryVersion',
    ],
    'AccumulationRegister': ['Read', 'Update', 'View', 'Edit', 'TotalsControl'],
    'AccountingRegister': ['Read', 'Update', 'View', 'Edit', 'TotalsControl'],
    'CalculationRegister': ['Read', 'View'],
    'Constant': [
        'Read', 'Update', 'View', 'Edit',
        'ReadDataHistory', 'ViewDataHistory', 'UpdateDataHistory',
        'UpdateDataHistorySettings', 'UpdateDataHistoryVersionComment',
        'EditDataHistoryVersionComment', 'SwitchToDataHistoryVersion',
    ],
    'ChartOfAccounts': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete',
        'InteractiveDeletePredefinedData', 'InteractiveSetDeletionMarkPredefinedData',
        'InteractiveClearDeletionMarkPredefinedData', 'InteractiveDeleteMarkedPredefinedData',
        'ReadDataHistory', 'ReadDataHistoryOfMissingData',
        'UpdateDataHistory', 'UpdateDataHistoryOfMissingData',
        'UpdateDataHistorySettings', 'UpdateDataHistoryVersionComment',
    ],
    'ChartOfCharacteristicTypes': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete', 'InteractiveDeleteMarked',
        'InteractiveDeletePredefinedData', 'InteractiveSetDeletionMarkPredefinedData',
        'InteractiveClearDeletionMarkPredefinedData', 'InteractiveDeleteMarkedPredefinedData',
        'ReadDataHistory', 'ViewDataHistory', 'UpdateDataHistory',
        'ReadDataHistoryOfMissingData', 'UpdateDataHistoryOfMissingData',
        'UpdateDataHistorySettings', 'UpdateDataHistoryVersionComment',
        'EditDataHistoryVersionComment', 'SwitchToDataHistoryVersion',
    ],
    'ChartOfCalculationTypes': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete',
        'InteractiveDeletePredefinedData', 'InteractiveSetDeletionMarkPredefinedData',
        'InteractiveClearDeletionMarkPredefinedData', 'InteractiveDeleteMarkedPredefinedData',
    ],
    'ExchangePlan': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete', 'InteractiveDeleteMarked',
        'ReadDataHistory', 'ViewDataHistory', 'UpdateDataHistory',
        'ReadDataHistoryOfMissingData', 'UpdateDataHistoryOfMissingData',
        'UpdateDataHistorySettings', 'UpdateDataHistoryVersionComment',
        'EditDataHistoryVersionComment', 'SwitchToDataHistoryVersion',
    ],
    'BusinessProcess': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'Start', 'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete', 'InteractiveActivate', 'InteractiveStart',
    ],
    'Task': [
        'Read', 'Insert', 'Update', 'Delete', 'View', 'Edit', 'InputByString',
        'Execute', 'InteractiveInsert', 'InteractiveSetDeletionMark', 'InteractiveClearDeletionMark',
        'InteractiveDelete', 'InteractiveActivate', 'InteractiveExecute',
    ],
    'DataProcessor': ['Use', 'View'],
    'Report': ['Use', 'View'],
    'CommonForm': ['View'],
    'CommonCommand': ['View'],
    'Subsystem': ['View'],
    'FilterCriterion': ['View'],
    'DocumentJournal': ['Read', 'View'],
    'Sequence': ['Read', 'Update'],
    'WebService': ['Use'],
    'HTTPService': ['Use'],
    'IntegrationService': ['Use'],
    'SessionParameter': ['Get', 'Set'],
    'CommonAttribute': ['View', 'Edit'],
}

NESTED_RIGHTS = ['View', 'Edit']
CHANNEL_RIGHTS = ['Use']
COMMAND_RIGHTS = ['View']


def get_object_type(name):
    dot_idx = name.find('.')
    if dot_idx < 0:
        return name
    return name[:dot_idx]


def is_nested_object(name):
    return name.count('.') >= 2


def find_similar(needle, haystack):
    result = []
    needle_lower = needle.lower()
    for h in haystack:
        h_lower = h.lower()
        if needle_lower in h_lower or h_lower in needle_lower:
            result.append(h)
        if len(result) >= 3:
            break
    return result


def get_child_text(parent, local_name, ns):
    """Get text of first child element with given local name in namespace."""
    for child in parent:
        if not isinstance(child.tag, str):
            continue
        if etree.QName(child.tag).localname == local_name and etree.QName(child.tag).namespace == ns:
            return child.text or ''
    return None


def get_child_el(parent, local_name, ns):
    """Get first child element with given local name in namespace."""
    for child in parent:
        if not isinstance(child.tag, str):
            continue
        if etree.QName(child.tag).localname == local_name and etree.QName(child.tag).namespace == ns:
            return child
    return None


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description='Validate 1C role Rights.xml structure', allow_abbrev=False
    )
    parser.add_argument('-RightsPath', '-Path', dest='RightsPath', required=True)
    parser.add_argument('-OutFile', dest='OutFile', default='')
    parser.add_argument('-Detailed', dest='Detailed', action='store_true')
    parser.add_argument('-MaxErrors', dest='MaxErrors', type=int, default=30)
    args = parser.parse_args()

    rights_path = args.RightsPath
    out_file = args.OutFile

    if not os.path.isabs(rights_path):
        rights_path = os.path.join(os.getcwd(), rights_path)

    # A: Directory → Ext/Rights.xml
    if os.path.isdir(rights_path):
        rights_path = os.path.join(rights_path, 'Ext', 'Rights.xml')
    # B1: Missing Ext/
    if not os.path.exists(rights_path):
        fn = os.path.basename(rights_path)
        if fn == 'Rights.xml':
            c = os.path.join(os.path.dirname(rights_path), 'Ext', fn)
            if os.path.exists(c):
                rights_path = c

    resolved_path = os.path.abspath(rights_path)

    # Auto-detect metadata: Roles/Name/Ext/Rights.xml → Roles/Name.xml
    ext_dir = os.path.dirname(resolved_path)
    role_dir = os.path.dirname(ext_dir)
    roles_dir = os.path.dirname(role_dir)
    role_dir_name = os.path.basename(role_dir)
    metadata_path = os.path.join(roles_dir, f'{role_dir_name}.xml')

    # --- Output helpers ---
    lines = []
    errors = 0
    warnings = 0
    ok_count = 0
    stopped = False

    def report_ok(msg):
        nonlocal ok_count
        ok_count += 1
        if args.Detailed:
            lines.append(f'[OK]    {msg}')

    def report_warn(msg):
        nonlocal warnings
        warnings += 1
        lines.append(f'[WARN]  {msg}')

    def report_error(msg):
        nonlocal errors, stopped
        errors += 1
        lines.append(f'[ERROR] {msg}')
        if errors >= args.MaxErrors:
            stopped = True

    # --- 3. Validate Rights.xml ---

    def write_output(text):
        if out_file:
            out_path = out_file if os.path.isabs(out_file) else os.path.join(os.getcwd(), out_file)
            out_dir = os.path.dirname(out_path)
            if out_dir and not os.path.exists(out_dir):
                os.makedirs(out_dir, exist_ok=True)
            with open(out_path, 'w', encoding='utf-8-sig', newline='') as f:
                f.write(text)
            print(f'Written to: {out_path}')
        else:
            print(text)

    if not os.path.exists(rights_path):
        report_error(f'File not found: {rights_path}')
        result = '\n'.join(lines)
        write_output(result)
        sys.exit(1)

    # 3a. Parse XML
    xml_doc = None
    try:
        xml_parser = etree.XMLParser(remove_blank_text=False)
        xml_doc = etree.parse(rights_path, xml_parser)
        report_ok('XML well-formed')
    except etree.XMLSyntaxError as e:
        report_error(f'XML parse error: {e}')
        result = '\n'.join(lines)
        write_output(result)
        sys.exit(1)

    root = xml_doc.getroot()
    root_local = etree.QName(root.tag).localname
    root_ns = etree.QName(root.tag).namespace or ''

    # 3b. Check root element
    if root_local != 'Rights':
        report_error(f"Root element is '{root_local}', expected 'Rights'")
    elif root_ns != RIGHTS_NS:
        report_warn(f"Namespace is '{root_ns}', expected '{RIGHTS_NS}'")
    else:
        report_ok('Root element: <Rights> with correct namespace')

    # 3c. Global flags
    flag_names = ['setForNewObjects', 'setForAttributesByDefault', 'independentRightsOfChildObjects']
    flags_found = 0
    for fn in flag_names:
        nodes = root.findall(f'{{{RIGHTS_NS}}}{fn}')
        if len(nodes) > 0:
            val = nodes[0].text or ''
            if val not in ('true', 'false'):
                report_warn(f"{fn} = '{val}' (expected 'true' or 'false')")
            flags_found += 1
        else:
            report_warn(f'Missing global flag: {fn}')
    if flags_found == 3:
        report_ok('3 global flags present')

    # 3d. Objects
    objects = root.findall(f'{{{RIGHTS_NS}}}object')
    obj_count = len(objects)
    right_count = 0
    rls_count = 0

    for obj in objects:
        obj_name = ''
        for child in obj:
            if not isinstance(child.tag, str):
                continue
            if etree.QName(child.tag).localname == 'name' and etree.QName(child.tag).namespace == RIGHTS_NS:
                obj_name = child.text or ''
                break

        if not obj_name:
            report_error('Object without <name>')
            continue

        object_type = get_object_type(obj_name)
        is_nested = is_nested_object(obj_name)

        # Check object type is known
        if not is_nested and object_type not in KNOWN_RIGHTS:
            report_warn(f"{obj_name}: unknown object type '{object_type}'")

        # Check rights
        for child in obj:
            if not isinstance(child.tag, str):
                continue
            if etree.QName(child.tag).localname != 'right' or etree.QName(child.tag).namespace != RIGHTS_NS:
                continue

            r_name = ''
            r_value = ''
            has_rls = False

            for rc in child:
                if not isinstance(rc.tag, str):
                    continue
                rc_local = etree.QName(rc.tag).localname
                rc_ns = etree.QName(rc.tag).namespace
                if rc_ns != RIGHTS_NS:
                    continue

                if rc_local == 'name':
                    r_name = rc.text or ''
                elif rc_local == 'value':
                    r_value = rc.text or ''
                elif rc_local == 'restrictionByCondition':
                    has_rls = True
                    rls_count += 1
                    # Check condition not empty
                    cond_node = get_child_el(rc, 'condition', RIGHTS_NS)
                    if cond_node is None or not (cond_node.text or ''):
                        report_warn(f"{obj_name}: RLS condition for '{r_name}' is empty")

            if not r_name:
                report_error(f'{obj_name}: <right> without <name>')
                continue

            if r_value not in ('true', 'false'):
                report_error(f"{obj_name}: right '{r_name}' has invalid value '{r_value}'")
                continue

            right_count += 1

            # Validate right name
            if is_nested:
                if '.Command.' in obj_name:
                    if r_name not in COMMAND_RIGHTS:
                        report_warn(f"{obj_name}: '{r_name}' not valid for commands (only: View)")
                elif '.IntegrationServiceChannel.' in obj_name:
                    if r_name not in CHANNEL_RIGHTS:
                        report_warn(f"{obj_name}: '{r_name}' not valid for channels (only: Use)")
                else:
                    if r_name not in NESTED_RIGHTS:
                        report_warn(f"{obj_name}: '{r_name}' not valid for nested objects (only: View, Edit)")
            elif object_type in KNOWN_RIGHTS:
                valid_rights = KNOWN_RIGHTS[object_type]
                if r_name not in valid_rights:
                    similar = find_similar(r_name, valid_rights)
                    sug_str = f' Did you mean: {", ".join(similar)}?' if similar else ''
                    report_warn(f"{obj_name}: unknown right '{r_name}'.{sug_str}")

    report_ok(f'{obj_count} objects, {right_count} rights')
    if rls_count > 0:
        report_ok(f'{rls_count} RLS restrictions')

    # 3e. Templates
    templates = root.findall(f'{{{RIGHTS_NS}}}restrictionTemplate')
    if len(templates) > 0:
        tpl_names = []
        for tpl in templates:
            t_name = ''
            t_cond = ''
            for child in tpl:
                if not isinstance(child.tag, str):
                    continue
                local = etree.QName(child.tag).localname
                ns = etree.QName(child.tag).namespace
                if ns != RIGHTS_NS:
                    continue
                if local == 'name':
                    t_name = child.text or ''
                elif local == 'condition':
                    t_cond = child.text or ''
            if not t_name:
                report_warn('Restriction template without <name>')
            else:
                paren_idx = t_name.find('(')
                short_name = t_name[:paren_idx] if paren_idx > 0 else t_name
                tpl_names.append(short_name)
            if not t_cond:
                report_warn(f"Template '{t_name}': empty <condition>")
        report_ok(f'{len(templates)} templates: {", ".join(tpl_names)}')

    # --- 4. Validate metadata (optional) ---
    inferred_role_name = ''
    if os.path.isfile(metadata_path):
        lines.append('')

        try:
            meta_parser = etree.XMLParser(remove_blank_text=False)
            meta_xml = etree.parse(metadata_path, meta_parser)
            meta_root = meta_xml.getroot()
            # Find <Role> element anywhere
            role_node = None
            for el in meta_root.iter():
                if isinstance(el.tag, str) and etree.QName(el.tag).localname == 'Role':
                    role_node = el
                    break

            if role_node is None:
                report_error('Metadata: <Role> element not found')
            else:
                uuid_val = role_node.get('uuid', '')
                if GUID_PATTERN.match(uuid_val):
                    report_ok(f'Metadata: UUID valid ({uuid_val})')
                else:
                    report_error(f"Metadata: invalid UUID format '{uuid_val}'")

                # Find Name
                name_node = None
                for el in role_node.iter():
                    if isinstance(el.tag, str) and etree.QName(el.tag).localname == 'Name':
                        name_node = el
                        break

                if name_node is not None and name_node.text:
                    report_ok(f'Metadata: Name = {name_node.text}')
                    inferred_role_name = name_node.text
                else:
                    report_error('Metadata: <Name> is empty or missing')

                # Find Synonym
                syn_node = None
                for el in role_node.iter():
                    if isinstance(el.tag, str) and etree.QName(el.tag).localname == 'Synonym':
                        syn_node = el
                        break

                if syn_node is not None and len(syn_node) > 0:
                    report_ok('Metadata: Synonym present')
                else:
                    report_warn('Metadata: <Synonym> is empty')
        except etree.XMLSyntaxError as e:
            report_error(f'Metadata XML parse error: {e}')

    # --- 5. Check registration in Configuration.xml ---
    config_dir = os.path.dirname(roles_dir)            # config root
    config_xml_path = os.path.join(config_dir, 'Configuration.xml')

    if not inferred_role_name:
        inferred_role_name = os.path.basename(role_dir)

    if os.path.exists(config_xml_path):
        lines.append('')
        try:
            cfg_parser = etree.XMLParser(remove_blank_text=False)
            cfg_xml = etree.parse(config_xml_path, cfg_parser)
            cfg_ns = {'md': 'http://v8.1c.ru/8.3/MDClasses'}
            child_obj = cfg_xml.getroot().find('.//md:Configuration/md:ChildObjects', cfg_ns)
            if child_obj is not None:
                role_nodes = child_obj.findall('md:Role', cfg_ns)
                found = False
                for rn in role_nodes:
                    if (rn.text or '') == inferred_role_name:
                        found = True
                        break
                if found:
                    report_ok(f'Configuration.xml: <Role>{inferred_role_name}</Role> registered')
                else:
                    report_warn(f'Configuration.xml: <Role>{inferred_role_name}</Role> NOT found in ChildObjects')
        except etree.XMLSyntaxError as e:
            report_warn(f'Configuration.xml: parse error \u2014 {e}')

    # --- 6. Summary ---

    # Insert header at position 0
    lines.insert(0, f'=== Validation: Role.{inferred_role_name} ===')

    checks = ok_count + errors + warnings
    if errors == 0 and warnings == 0 and not args.Detailed:
        result = f'=== Validation OK: Role.{inferred_role_name} ({checks} checks) ==='
    else:
        lines.append('')
        lines.append(f'=== Result: {errors} errors, {warnings} warnings ({checks} checks) ===')
        result = '\n'.join(lines)
    write_output(result)
    sys.exit(1 if errors > 0 else 0)


if __name__ == '__main__':
    main()
