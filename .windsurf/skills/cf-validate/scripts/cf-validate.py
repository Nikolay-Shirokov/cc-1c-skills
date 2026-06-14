#!/usr/bin/env python3
# cf-validate v1.3 — Validate 1C configuration XML structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Validates Configuration.xml: root structure, InternalInfo, properties, ChildObjects, languages."""
import sys, os, argparse, re
from lxml import etree

NS = {
    'md':  'http://v8.1c.ru/8.3/MDClasses',
    'v8':  'http://v8.1c.ru/8.1/data/core',
    'xr':  'http://v8.1c.ru/8.3/xcf/readable',
    'xsi': 'http://www.w3.org/2001/XMLSchema-instance',
    'xs':  'http://www.w3.org/2001/XMLSchema',
    'app': 'http://v8.1c.ru/8.2/managed-application/core',
}

GUID_PATTERN = re.compile(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
)
IDENT_PATTERN = re.compile(
    r'^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_]'
    r'[A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$'
)

# 7 fixed ClassIds for Configuration
VALID_CLASS_IDS = [
    '9cd510cd-abfc-11d4-9434-004095e12fc7',   # managed application module
    '9fcd25a0-4822-11d4-9414-008048da11f9',   # ordinary application module
    'e3687481-0a87-462c-a166-9f34594f9bba',   # session module
    '9de14907-ec23-4a07-96f0-85521cb6b53b',   # external connection module
    '51f2d5d8-ea4d-4064-8892-82951750031e',   # command interface
    'e68182ea-4237-4383-967f-90c1e3370bc7',   # main section command interface
    'fb282519-d103-4dd3-bc12-cb271d631dfc',   # home page / client app interface
]

# 44 types in canonical order
CHILD_OBJECT_TYPES = [
    'Language', 'Subsystem', 'StyleItem', 'Style',
    'CommonPicture', 'SessionParameter', 'Role', 'CommonTemplate',
    'FilterCriterion', 'CommonModule', 'CommonAttribute', 'ExchangePlan',
    'XDTOPackage', 'WebService', 'HTTPService', 'WSReference',
    'EventSubscription', 'ScheduledJob', 'SettingsStorage', 'FunctionalOption',
    'FunctionalOptionsParameter', 'DefinedType', 'CommonCommand', 'CommandGroup',
    'Constant', 'CommonForm', 'Catalog', 'Document',
    'DocumentNumerator', 'Sequence', 'DocumentJournal', 'Enum',
    'Report', 'DataProcessor', 'InformationRegister', 'AccumulationRegister',
    'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'AccountingRegister',
    'ChartOfCalculationTypes', 'CalculationRegister',
    'BusinessProcess', 'Task', 'IntegrationService',
]

# Type -> directory mapping
CHILD_TYPE_DIR_MAP = {
    'Language': 'Languages', 'Subsystem': 'Subsystems', 'StyleItem': 'StyleItems', 'Style': 'Styles',
    'CommonPicture': 'CommonPictures', 'SessionParameter': 'SessionParameters', 'Role': 'Roles',
    'CommonTemplate': 'CommonTemplates', 'FilterCriterion': 'FilterCriteria', 'CommonModule': 'CommonModules',
    'CommonAttribute': 'CommonAttributes', 'ExchangePlan': 'ExchangePlans', 'XDTOPackage': 'XDTOPackages',
    'WebService': 'WebServices', 'HTTPService': 'HTTPServices', 'WSReference': 'WSReferences',
    'EventSubscription': 'EventSubscriptions', 'ScheduledJob': 'ScheduledJobs',
    'SettingsStorage': 'SettingsStorages', 'FunctionalOption': 'FunctionalOptions',
    'FunctionalOptionsParameter': 'FunctionalOptionsParameters', 'DefinedType': 'DefinedTypes',
    'CommonCommand': 'CommonCommands', 'CommandGroup': 'CommandGroups', 'Constant': 'Constants',
    'CommonForm': 'CommonForms', 'Catalog': 'Catalogs', 'Document': 'Documents',
    'DocumentNumerator': 'DocumentNumerators', 'Sequence': 'Sequences',
    'DocumentJournal': 'DocumentJournals', 'Enum': 'Enums', 'Report': 'Reports',
    'DataProcessor': 'DataProcessors', 'InformationRegister': 'InformationRegisters',
    'AccumulationRegister': 'AccumulationRegisters',
    'ChartOfCharacteristicTypes': 'ChartsOfCharacteristicTypes',
    'ChartOfAccounts': 'ChartsOfAccounts', 'AccountingRegister': 'AccountingRegisters',
    'ChartOfCalculationTypes': 'ChartsOfCalculationTypes',
    'CalculationRegister': 'CalculationRegisters',
    'BusinessProcess': 'BusinessProcesses', 'Task': 'Tasks',
    'IntegrationService': 'IntegrationServices',
}

# Valid enum values for Configuration properties
VALID_ENUM_VALUES = {
    'ConfigurationExtensionCompatibilityMode': [
        'DontUse', 'Version8_1', 'Version8_2_13', 'Version8_2_16',
        'Version8_3_1', 'Version8_3_2', 'Version8_3_3', 'Version8_3_4', 'Version8_3_5',
        'Version8_3_6', 'Version8_3_7', 'Version8_3_8', 'Version8_3_9', 'Version8_3_10',
        'Version8_3_11', 'Version8_3_12', 'Version8_3_13', 'Version8_3_14', 'Version8_3_15',
        'Version8_3_16', 'Version8_3_17', 'Version8_3_18', 'Version8_3_19', 'Version8_3_20',
        'Version8_3_21', 'Version8_3_22', 'Version8_3_23', 'Version8_3_24', 'Version8_3_25',
        'Version8_3_26', 'Version8_3_27', 'Version8_3_28', 'Version8_5_1',
    ],
    'DefaultRunMode': ['ManagedApplication', 'OrdinaryApplication', 'Auto'],
    'ScriptVariant': ['Russian', 'English'],
    'DataLockControlMode': ['Automatic', 'Managed', 'AutomaticAndManaged'],
    'ObjectAutonumerationMode': ['NotAutoFree', 'AutoFree'],
    'ModalityUseMode': ['DontUse', 'Use', 'UseWithWarnings'],
    'SynchronousPlatformExtensionAndAddInCallUseMode': ['DontUse', 'Use', 'UseWithWarnings'],
    'InterfaceCompatibilityMode': [
        'Version8_2', 'Version8_2EnableTaxi', 'Taxi', 'TaxiEnableVersion8_2',
        'TaxiEnableVersion8_5', 'Version8_5EnableTaxi', 'Version8_5',
    ],
    'DatabaseTablespacesUseMode': ['DontUse', 'Use'],
    'MainClientApplicationWindowMode': ['Normal', 'Fullscreen', 'Kiosk'],
    'CompatibilityMode': [
        'DontUse', 'Version8_1', 'Version8_2_13', 'Version8_2_16',
        'Version8_3_1', 'Version8_3_2', 'Version8_3_3', 'Version8_3_4', 'Version8_3_5',
        'Version8_3_6', 'Version8_3_7', 'Version8_3_8', 'Version8_3_9', 'Version8_3_10',
        'Version8_3_11', 'Version8_3_12', 'Version8_3_13', 'Version8_3_14', 'Version8_3_15',
        'Version8_3_16', 'Version8_3_17', 'Version8_3_18', 'Version8_3_19', 'Version8_3_20',
        'Version8_3_21', 'Version8_3_22', 'Version8_3_23', 'Version8_3_24', 'Version8_3_25',
        'Version8_3_26', 'Version8_3_27', 'Version8_3_28', 'Version8_5_1',
    ],
}

EXPECTED_NS = 'http://v8.1c.ru/8.3/MDClasses'


class Reporter:
    def __init__(self, max_errors, detailed=False):
        self.errors = 0
        self.warnings = 0
        self.ok_count = 0
        self.stopped = False
        self.max_errors = max_errors
        self.detailed = detailed
        self.lines = []
        self.obj_name = '(unknown)'

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

    def finalize(self, out_file):
        checks = self.ok_count + self.errors + self.warnings
        if self.errors == 0 and self.warnings == 0 and not self.detailed:
            result = f'=== Validation OK: Configuration.{self.obj_name} ({checks} checks) ==='
        else:
            self.out('')
            self.out(f'=== Result: {self.errors} errors, {self.warnings} warnings ({checks} checks) ===')
            result = self.text()

        print(result, end='' if '\r\n' in result else '\n')

        if out_file:
            with open(out_file, 'w', encoding='utf-8-sig', newline='') as f:
                f.write(result)
            print(f'Written to: {out_file}')


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description='Validate 1C configuration XML structure', allow_abbrev=False
    )
    parser.add_argument('-ConfigPath', '-Path', dest='ConfigPath', required=True)
    parser.add_argument('-Detailed', action='store_true')
    parser.add_argument('-MaxErrors', dest='MaxErrors', type=int, default=30)
    parser.add_argument('-OutFile', dest='OutFile', default='')
    args = parser.parse_args()

    config_path = args.ConfigPath
    max_errors = args.MaxErrors
    out_file = args.OutFile

    # --- Resolve path ---
    if not os.path.isabs(config_path):
        config_path = os.path.join(os.getcwd(), config_path)

    if os.path.isdir(config_path):
        candidate = os.path.join(config_path, 'Configuration.xml')
        if os.path.exists(candidate):
            config_path = candidate
        else:
            print(f'[ERROR] No Configuration.xml found in directory: {config_path}')
            sys.exit(1)

    if not os.path.exists(config_path):
        print(f'[ERROR] File not found: {config_path}')
        sys.exit(1)

    resolved_path = os.path.abspath(config_path)
    config_dir = os.path.dirname(resolved_path)

    if out_file and not os.path.isabs(out_file):
        out_file = os.path.join(os.getcwd(), out_file)

    r = Reporter(max_errors, detailed=args.Detailed)
    r.out('')

    # --- 1. Parse XML ---
    xml_doc = None
    try:
        xml_parser = etree.XMLParser(remove_blank_text=False)
        xml_doc = etree.parse(resolved_path, xml_parser)
    except etree.XMLSyntaxError as e:
        r.lines.insert(0, '=== Validation: Configuration (parse failed) ===')
        r.out('')
        r.error(f'1. XML parse failed: {e}')
        r.finalize(out_file)
        sys.exit(1)

    root = xml_doc.getroot()

    # --- Check 1: Root structure ---
    check1_ok = True
    root_local = etree.QName(root.tag).localname
    root_ns = etree.QName(root.tag).namespace or ''

    if root_local != 'MetaDataObject':
        r.error(f"1. Root element is '{root_local}', expected 'MetaDataObject'")
        r.finalize(out_file)
        sys.exit(1)

    if root_ns != EXPECTED_NS:
        r.error(f"1. Root namespace is '{root_ns}', expected '{EXPECTED_NS}'")
        check1_ok = False

    version = root.get('version', '')
    if not version:
        r.warn('1. Missing version attribute on MetaDataObject')
    elif version not in ('2.17', '2.20', '2.21'):
        r.warn(f"1. Unusual version '{version}' (expected 2.17, 2.20 or 2.21)")

    # Must have Configuration child
    cfg_node = None
    for child in root:
        if not isinstance(child.tag, str):
            continue
        if etree.QName(child.tag).localname == 'Configuration' and etree.QName(child.tag).namespace == EXPECTED_NS:
            cfg_node = child
            break

    if cfg_node is None:
        r.error('1. No <Configuration> element found inside MetaDataObject')
        r.finalize(out_file)
        sys.exit(1)

    # UUID
    cfg_uuid = cfg_node.get('uuid', '')
    if not cfg_uuid:
        r.error('1. Missing uuid on <Configuration>')
        check1_ok = False
    elif not GUID_PATTERN.match(cfg_uuid):
        r.error(f"1. Invalid uuid '{cfg_uuid}' on <Configuration>")
        check1_ok = False

    # Get name early for header
    props_node = cfg_node.find('md:Properties', NS)
    name_node = props_node.find('md:Name', NS) if props_node is not None else None
    obj_name = (name_node.text or '') if name_node is not None and name_node.text else '(unknown)'
    r.obj_name = obj_name

    r.lines.insert(0, f'=== Validation: Configuration.{obj_name} ===')

    if check1_ok:
        r.ok(f'1. Root structure: MetaDataObject/Configuration, version {version}')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 2: InternalInfo ---
    internal_info = cfg_node.find('md:InternalInfo', NS)
    check2_ok = True

    if internal_info is None:
        r.error('2. InternalInfo: missing')
    else:
        contained = internal_info.findall('xr:ContainedObject', NS)
        if len(contained) != 7:
            r.warn(f'2. InternalInfo: expected 7 ContainedObject, found {len(contained)}')

        found_class_ids = {}
        for co in contained:
            class_id_el = co.find('xr:ClassId', NS)
            object_id_el = co.find('xr:ObjectId', NS)

            if class_id_el is None or not (class_id_el.text or ''):
                r.error('2. ContainedObject missing ClassId')
                check2_ok = False
                continue

            cid = class_id_el.text
            if cid not in VALID_CLASS_IDS:
                r.error(f'2. Unknown ClassId: {cid}')
                check2_ok = False

            if cid in found_class_ids:
                r.error(f'2. Duplicate ClassId: {cid}')
                check2_ok = False
            found_class_ids[cid] = True

            if object_id_el is None or not (object_id_el.text or ''):
                r.error(f'2. ContainedObject missing ObjectId for ClassId {cid}')
                check2_ok = False
            elif not GUID_PATTERN.match(object_id_el.text):
                r.error(f"2. Invalid ObjectId '{object_id_el.text}' for ClassId {cid}")
                check2_ok = False

        # Check missing ClassIds
        missing_ids = [cid for cid in VALID_CLASS_IDS if cid not in found_class_ids]
        if len(missing_ids) > 0:
            r.warn(f'2. Missing ClassIds: {len(missing_ids)} of 7')

        if check2_ok:
            r.ok(f'2. InternalInfo: {len(contained)} ContainedObject, all ClassIds valid')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 3: Properties -- Name, Synonym, DefaultLanguage, DefaultRunMode ---
    def_lang = ''
    syn_present = False

    if props_node is None:
        r.error('3. Properties block missing')
    else:
        check3_ok = True

        # Name
        if name_node is None or not (name_node.text or ''):
            r.error('3. Properties: Name is missing or empty')
            check3_ok = False
        else:
            name_val = name_node.text
            if not IDENT_PATTERN.match(name_val):
                r.error(f"3. Properties: Name '{name_val}' is not a valid 1C identifier")
                check3_ok = False

        # Synonym
        syn_node = props_node.find('md:Synonym', NS)
        if syn_node is not None:
            syn_item = syn_node.find('v8:item', NS)
            if syn_item is not None:
                syn_content = syn_item.find('v8:content', NS)
                if syn_content is not None and syn_content.text:
                    syn_present = True

        # DefaultLanguage
        def_lang_node = props_node.find('md:DefaultLanguage', NS)
        def_lang = (def_lang_node.text or '') if def_lang_node is not None else ''
        if not def_lang:
            r.error('3. Properties: DefaultLanguage is missing or empty')
            check3_ok = False

        # DefaultRunMode
        def_run_node = props_node.find('md:DefaultRunMode', NS)
        if def_run_node is None or not (def_run_node.text or ''):
            r.warn('3. Properties: DefaultRunMode is missing or empty')

        if check3_ok:
            syn_info = 'Synonym present' if syn_present else 'no Synonym'
            r.ok(f'3. Properties: Name="{obj_name}", {syn_info}, DefaultLanguage={def_lang}')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 4: Property values -- enum properties ---
    if props_node is not None:
        enum_checked = 0
        check4_ok = True

        for prop_name, allowed in VALID_ENUM_VALUES.items():
            prop_node = props_node.find(f'md:{prop_name}', NS)
            if prop_node is not None and prop_node.text:
                val = prop_node.text
                if val not in allowed:
                    r.error(f"4. Property '{prop_name}' has invalid value '{val}'")
                    check4_ok = False
                enum_checked += 1

        if check4_ok:
            r.ok(f'4. Property values: {enum_checked} enum properties checked')
    else:
        r.warn('4. No Properties block to check')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 5: ChildObjects -- valid types, no duplicates, order ---
    child_obj_node = cfg_node.find('md:ChildObjects', NS)

    if child_obj_node is None:
        r.error('5. ChildObjects block missing')
    else:
        check5_ok = True
        total_count = 0
        type_counts = {}    # type_name -> {obj_name: True}
        duplicates = {}
        type_first_index = {}
        last_type_order = -1
        order_ok = True

        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            obj_name_val = child.text or ''

            # Valid type?
            if type_name in CHILD_OBJECT_TYPES:
                type_idx = CHILD_OBJECT_TYPES.index(type_name)
            else:
                type_idx = -1

            if type_idx < 0:
                r.error(f"5. Unknown type '{type_name}' in ChildObjects")
                check5_ok = False
            else:
                # Check order
                if type_name not in type_first_index:
                    type_first_index[type_name] = type_idx
                    if type_idx < last_type_order:
                        r.warn(f"5. Type '{type_name}' is out of canonical order (after type at position {last_type_order})")
                        order_ok = False
                    last_type_order = type_idx

            # Count and dedup
            if type_name not in type_counts:
                type_counts[type_name] = {}
            if obj_name_val in type_counts[type_name]:
                dup_key = f'{type_name}.{obj_name_val}'
                if dup_key not in duplicates:
                    r.error(f'5. Duplicate: {dup_key}')
                    duplicates[dup_key] = True
                    check5_ok = False
            else:
                type_counts[type_name][obj_name_val] = True

            total_count += 1

        type_count = len(type_counts)
        if check5_ok:
            order_info = ', order correct' if order_ok else ''
            r.ok(f'5. ChildObjects: {type_count} types, {total_count} objects{order_info}')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 6: DefaultLanguage references existing Language in ChildObjects ---
    if def_lang and child_obj_node is not None:
        lang_name = def_lang
        if lang_name.startswith('Language.'):
            lang_name = lang_name[9:]

        found = False
        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            if etree.QName(child.tag).localname == 'Language' and (child.text or '') == lang_name:
                found = True
                break

        if found:
            r.ok(f'6. DefaultLanguage "{def_lang}" found in ChildObjects')
        else:
            r.error(f'6. DefaultLanguage "{def_lang}" not found in ChildObjects')
    else:
        if not def_lang:
            r.warn('6. Cannot check DefaultLanguage (empty)')
        else:
            r.warn('6. Cannot check DefaultLanguage (no ChildObjects)')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 7: Language files exist ---
    if child_obj_node is not None:
        lang_names = []
        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            if etree.QName(child.tag).localname == 'Language':
                lang_names.append(child.text or '')

        if len(lang_names) > 0:
            exist_count = 0
            for ln in lang_names:
                lang_file = os.path.join(config_dir, 'Languages', ln + '.xml')
                if os.path.exists(lang_file):
                    exist_count += 1
                else:
                    r.warn(f'7. Language file missing: Languages/{ln}.xml')
            if exist_count == len(lang_names):
                r.ok(f'7. Language files: {exist_count}/{len(lang_names)} exist')
        else:
            r.warn('7. No Language entries in ChildObjects')
    else:
        r.warn('7. Cannot check language files (no ChildObjects)')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 8: Object directories exist (spot-check) ---
    if child_obj_node is not None:
        dirs_to_check = {}
        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            if type_name == 'Language':
                continue
            if type_name in CHILD_TYPE_DIR_MAP:
                dir_name = CHILD_TYPE_DIR_MAP[type_name]
                dirs_to_check[dir_name] = dirs_to_check.get(dir_name, 0) + 1

        missing_dirs = []
        for dir_name, count in dirs_to_check.items():
            dir_path = os.path.join(config_dir, dir_name)
            if not os.path.isdir(dir_path):
                missing_dirs.append(f'{dir_name} ({count} objects)')

        if len(missing_dirs) == 0:
            r.ok(f'8. Object directories: {len(dirs_to_check)} directories, all exist')
        else:
            for md in missing_dirs:
                r.warn(f'8. Missing directory: {md}')
    else:
        pass  # no ChildObjects

    # --- Check 9: Form references (HomePageWorkArea + Properties) ---
    def test_form_ref(ref):
        if not ref:
            return True
        if GUID_PATTERN.match(ref):
            return True
        parts = ref.split('.')
        if len(parts) == 2 and parts[0] == 'CommonForm':
            p = os.path.join(config_dir, 'CommonForms', parts[1], 'Form.xml')
            p_ext = os.path.join(config_dir, 'CommonForms', parts[1], 'Ext', 'Form.xml')
            return os.path.isfile(p) or os.path.isfile(p_ext)
        if len(parts) == 4 and parts[2] == 'Form' and parts[0] in CHILD_TYPE_DIR_MAP:
            d = CHILD_TYPE_DIR_MAP[parts[0]]
            p = os.path.join(config_dir, d, parts[1], 'Forms', parts[3], 'Form.xml')
            p_ext = os.path.join(config_dir, d, parts[1], 'Forms', parts[3], 'Ext', 'Form.xml')
            return os.path.isfile(p) or os.path.isfile(p_ext)
        return False

    form_refs_checked = 0
    form_ref_errors = []

    hp_path = os.path.join(config_dir, 'Ext', 'HomePageWorkArea.xml')
    if os.path.isfile(hp_path):
        try:
            hp_tree = etree.parse(hp_path)
            HP_NS = 'http://v8.1c.ru/8.3/xcf/extrnprops'
            for f in hp_tree.getroot().iter(f'{{{HP_NS}}}Form'):
                ref = (f.text or '').strip()
                if not ref:
                    continue
                form_refs_checked += 1
                if not test_form_ref(ref):
                    form_ref_errors.append(f"HomePageWorkArea.Form '{ref}' — file not found")
        except Exception as e:
            form_ref_errors.append(f'HomePageWorkArea.xml: parse error — {e}')

    if props_node is not None:
        form_props = ['DefaultReportForm','DefaultReportVariantForm','DefaultReportSettingsForm','DefaultDynamicListSettingsForm','DefaultSearchForm','DefaultDataHistoryChangeHistoryForm','DefaultDataHistoryVersionDataForm','DefaultDataHistoryVersionDifferencesForm','DefaultCollaborationSystemUsersChoiceForm','DefaultConstantsForm']
        for pn in form_props:
            node = props_node.find(f'md:{pn}', NS)
            if node is not None and node.text and node.text.strip():
                ref = node.text.strip()
                form_refs_checked += 1
                if not test_form_ref(ref):
                    form_ref_errors.append(f"Properties.{pn} '{ref}' — form not found")

    if form_refs_checked == 0:
        r.ok('9. Form references: none to check')
    elif not form_ref_errors:
        r.ok(f'9. Form references: {form_refs_checked} verified')
    else:
        for err in form_ref_errors:
            r.error(f'9. {err}')

    # --- Final output ---
    r.finalize(out_file)
    sys.exit(1 if r.errors > 0 else 0)


if __name__ == '__main__':
    main()
