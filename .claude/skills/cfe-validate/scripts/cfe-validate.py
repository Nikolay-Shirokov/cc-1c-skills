#!/usr/bin/env python3
# cfe-validate v1.0 — Validate 1C configuration extension XML structure (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Validates extension Configuration.xml: root, InternalInfo, extension properties, ChildObjects, borrowed objects."""
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
    '9cd510cd-abfc-11d4-9434-004095e12fc7',
    '9fcd25a0-4822-11d4-9414-008048da11f9',
    'e3687481-0a87-462c-a166-9f34594f9bba',
    '9de14907-ec23-4a07-96f0-85521cb6b53b',
    '51f2d5d8-ea4d-4064-8892-82951750031e',
    'e68182ea-4237-4383-967f-90c1e3370bc7',
    'fb282519-d103-4dd3-bc12-cb271d631dfc',
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

# Valid enum values for extension properties
VALID_ENUM_VALUES = {
    'ConfigurationExtensionCompatibilityMode': [
        'DontUse', 'Version8_1', 'Version8_2_13', 'Version8_2_16',
        'Version8_3_1', 'Version8_3_2', 'Version8_3_3', 'Version8_3_4', 'Version8_3_5',
        'Version8_3_6', 'Version8_3_7', 'Version8_3_8', 'Version8_3_9', 'Version8_3_10',
        'Version8_3_11', 'Version8_3_12', 'Version8_3_13', 'Version8_3_14', 'Version8_3_15',
        'Version8_3_16', 'Version8_3_17', 'Version8_3_18', 'Version8_3_19', 'Version8_3_20',
        'Version8_3_21', 'Version8_3_22', 'Version8_3_23', 'Version8_3_24', 'Version8_3_25',
        'Version8_3_26', 'Version8_3_27', 'Version8_3_28',
    ],
    'DefaultRunMode': ['ManagedApplication', 'OrdinaryApplication', 'Auto'],
    'ScriptVariant': ['Russian', 'English'],
    'InterfaceCompatibilityMode': ['Taxi', 'TaxiEnableVersion8_2', 'Version8_2'],
}

EXPECTED_NS = 'http://v8.1c.ru/8.3/MDClasses'


class Reporter:
    def __init__(self, max_errors):
        self.errors = 0
        self.warnings = 0
        self.stopped = False
        self.max_errors = max_errors
        self.lines = []

    def out(self, msg=''):
        self.lines.append(msg)

    def ok(self, msg):
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
        self.out('')
        self.out(f'=== Result: {self.errors} errors, {self.warnings} warnings ===')

        result = self.text()
        print(result, end='')

        if out_file:
            with open(out_file, 'w', encoding='utf-8-sig', newline='') as f:
                f.write(result)
            print(f'Written to: {out_file}')


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description='Validate 1C configuration extension XML structure (CFE)', allow_abbrev=False
    )
    parser.add_argument('-ExtensionPath', dest='ExtensionPath', required=True)
    parser.add_argument('-MaxErrors', dest='MaxErrors', type=int, default=30)
    parser.add_argument('-OutFile', dest='OutFile', default='')
    args = parser.parse_args()

    extension_path = args.ExtensionPath
    max_errors = args.MaxErrors
    out_file = args.OutFile

    # --- Resolve path ---
    if not os.path.isabs(extension_path):
        extension_path = os.path.join(os.getcwd(), extension_path)

    if os.path.isdir(extension_path):
        candidate = os.path.join(extension_path, 'Configuration.xml')
        if os.path.exists(candidate):
            extension_path = candidate
        else:
            print(f'[ERROR] No Configuration.xml found in directory: {extension_path}')
            sys.exit(1)

    if not os.path.exists(extension_path):
        print(f'[ERROR] File not found: {extension_path}')
        sys.exit(1)

    resolved_path = os.path.abspath(extension_path)
    config_dir = os.path.dirname(resolved_path)

    if out_file and not os.path.isabs(out_file):
        out_file = os.path.join(os.getcwd(), out_file)

    r = Reporter(max_errors)
    r.out('')

    # --- 1. Parse XML ---
    xml_doc = None
    try:
        xml_parser = etree.XMLParser(remove_blank_text=False)
        xml_doc = etree.parse(resolved_path, xml_parser)
    except etree.XMLSyntaxError as e:
        r.lines.insert(0, '=== Validation: Extension (parse failed) ===')
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
    elif version not in ('2.17', '2.20'):
        r.warn(f"1. Unusual version '{version}' (expected 2.17 or 2.20)")

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

    r.lines.insert(0, f'=== Validation: Extension.{obj_name} ===')

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

        missing_ids = [cid for cid in VALID_CLASS_IDS if cid not in found_class_ids]
        if len(missing_ids) > 0:
            r.warn(f'2. Missing ClassIds: {len(missing_ids)} of 7')

        if check2_ok:
            r.ok(f'2. InternalInfo: {len(contained)} ContainedObject, all ClassIds valid')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 3: Extension-specific properties ---
    def_lang = ''

    if props_node is None:
        r.error('3. Properties block missing')
    else:
        check3_ok = True

        # ObjectBelonging = Adopted
        ob_node = props_node.find('md:ObjectBelonging', NS)
        ob_val = (ob_node.text or '') if ob_node is not None else ''
        if ob_val != 'Adopted':
            r.error(f"3. ObjectBelonging must be 'Adopted', got '{ob_val}'")
            check3_ok = False

        # Name
        if name_node is None or not (name_node.text or ''):
            r.error('3. Name is missing or empty')
            check3_ok = False
        else:
            name_val = name_node.text
            if not IDENT_PATTERN.match(name_val):
                r.error(f"3. Name '{name_val}' is not a valid 1C identifier")
                check3_ok = False

        # ConfigurationExtensionPurpose
        purpose_node = props_node.find('md:ConfigurationExtensionPurpose', NS)
        valid_purposes = ['Patch', 'Customization', 'AddOn']
        if purpose_node is None or not (purpose_node.text or ''):
            r.error('3. ConfigurationExtensionPurpose is missing')
            check3_ok = False
        elif purpose_node.text not in valid_purposes:
            r.error(f"3. ConfigurationExtensionPurpose '{purpose_node.text}' invalid (expected: Patch, Customization, AddOn)")
            check3_ok = False

        # NamePrefix
        prefix_node = props_node.find('md:NamePrefix', NS)
        if prefix_node is None or not (prefix_node.text or ''):
            r.warn('3. NamePrefix is empty')

        # KeepMappingToExtendedConfigurationObjectsByIDs
        keep_map_node = props_node.find('md:KeepMappingToExtendedConfigurationObjectsByIDs', NS)
        if keep_map_node is None:
            r.warn('3. KeepMappingToExtendedConfigurationObjectsByIDs is missing')

        # DefaultLanguage
        def_lang_node = props_node.find('md:DefaultLanguage', NS)
        def_lang = (def_lang_node.text or '') if def_lang_node is not None else ''

        if check3_ok:
            purpose_val = purpose_node.text if purpose_node is not None and purpose_node.text else '?'
            prefix_val = (prefix_node.text or '') if prefix_node is not None and prefix_node.text else '(empty)'
            r.ok(f'3. Extension properties: Name="{obj_name}", Purpose={purpose_val}, Prefix={prefix_val}')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 4: Enum property values ---
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
        type_counts = {}
        duplicates = {}
        type_first_index = {}
        last_type_order = -1
        order_ok = True

        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            obj_name_val = child.text or ''

            if type_name in CHILD_OBJECT_TYPES:
                type_idx = CHILD_OBJECT_TYPES.index(type_name)
            else:
                type_idx = -1

            if type_idx < 0:
                r.error(f"5. Unknown type '{type_name}' in ChildObjects")
                check5_ok = False
            else:
                if type_name not in type_first_index:
                    type_first_index[type_name] = type_idx
                    if type_idx < last_type_order:
                        r.warn(f"5. Type '{type_name}' is out of canonical order (after type at position {last_type_order})")
                        order_ok = False
                    last_type_order = type_idx

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

    # --- Check 8: Object directories exist ---
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
        r.ok('8. Object directories: N/A')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    def validate_borrowed_sub_item(check_num, context, sub_type, sub_item):
        sub_props = sub_item.find(f'{{{NS["md"]}}}Properties')
        if sub_props is None:
            r.error(f'{check_num}. {context}: {sub_type} missing Properties')
            return False
        ok = True
        sub_ob = sub_props.find(f'{{{NS["md"]}}}ObjectBelonging')
        if sub_ob is None or (sub_ob.text or '') != 'Adopted':
            r.error(f"{check_num}. {context}: {sub_type} ObjectBelonging must be 'Adopted'")
            ok = False
        sub_name = sub_props.find(f'{{{NS["md"]}}}Name')
        if sub_name is None or not (sub_name.text or ''):
            r.error(f'{check_num}. {context}: {sub_type} missing Name')
            ok = False
        sub_ext = sub_props.find(f'{{{NS["md"]}}}ExtendedConfigurationObject')
        sub_name_val = (sub_name.text or '') if sub_name is not None else '?'
        if sub_ext is None or not (sub_ext.text or ''):
            r.error(f'{check_num}. {context}: {sub_type}.{sub_name_val} missing ExtendedConfigurationObject')
            ok = False
        elif not GUID_PATTERN.match(sub_ext.text):
            r.error(f'{check_num}. {context}: {sub_type}.{sub_name_val} invalid ExtendedConfigurationObject')
            ok = False
        return ok

    def borrowed_metadata_declared(sub_item):
        sub_props = sub_item.find(f'{{{NS["md"]}}}Properties')
        if sub_props is None:
            return False
        sub_ob = sub_props.find(f'{{{NS["md"]}}}ObjectBelonging')
        if sub_ob is not None and (sub_ob.text or ''):
            return True
        sub_ext = sub_props.find(f'{{{NS["md"]}}}ExtendedConfigurationObject')
        return sub_ext is not None and bool(sub_ext.text or '')

    # --- Check 9: Borrowed objects validation ---
    if child_obj_node is not None:
        borrowed_count = 0
        borrowed_ok_count = 0
        check9_ok = True
        borrowed_sub_item_count = 0
        check10_ok = True

        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            child_name = child.text or ''
            if type_name == 'Language':
                continue

            if type_name not in CHILD_TYPE_DIR_MAP:
                continue
            dir_name = CHILD_TYPE_DIR_MAP[type_name]
            obj_file = os.path.join(config_dir, dir_name, child_name + '.xml')

            if not os.path.exists(obj_file):
                continue

            # Parse object XML
            obj_doc = None
            try:
                obj_parser = etree.XMLParser(remove_blank_text=False)
                obj_doc = etree.parse(obj_file, obj_parser)
            except etree.XMLSyntaxError as e:
                r.warn(f'9. Cannot parse {dir_name}/{child_name}.xml: {e}')
                continue

            obj_root = obj_doc.getroot()

            # Find the object element (Catalog, Document, etc.)
            obj_el = None
            for c in obj_root:
                if isinstance(c.tag, str):
                    obj_el = c
                    break
            if obj_el is None:
                continue

            obj_props = obj_el.find(f'{{{NS["md"]}}}Properties')
            if obj_props is None:
                continue

            ob_node = obj_props.find(f'{{{NS["md"]}}}ObjectBelonging')
            is_borrowed_object = ob_node is not None and (ob_node.text or '') == 'Adopted'
            if is_borrowed_object:
                borrowed_count += 1

                # Check ExtendedConfigurationObject
                ext_obj = obj_props.find(f'{{{NS["md"]}}}ExtendedConfigurationObject')
                if ext_obj is None or not (ext_obj.text or ''):
                    r.error(f'9. Borrowed {type_name}.{child_name}: missing ExtendedConfigurationObject')
                    check9_ok = False
                elif not GUID_PATTERN.match(ext_obj.text):
                    r.error(f"9. Borrowed {type_name}.{child_name}: invalid ExtendedConfigurationObject UUID '{ext_obj.text}'")
                    check9_ok = False
                else:
                    borrowed_ok_count += 1

            obj_child_objects = obj_el.find(f'{{{NS["md"]}}}ChildObjects')
            if obj_child_objects is not None:
                ctx = f'{type_name}.{child_name}'
                for sub_item in obj_child_objects:
                    if not isinstance(sub_item.tag, str):
                        continue
                    sub_type = etree.QName(sub_item.tag).localname

                    if sub_type in ('Attribute', 'TabularSection'):
                        if not is_borrowed_object or not borrowed_metadata_declared(sub_item):
                            continue
                        borrowed_sub_item_count += 1
                        if not validate_borrowed_sub_item('10', ctx, sub_type, sub_item):
                            check10_ok = False
                        if sub_type != 'TabularSection':
                            continue
                        ts_props = sub_item.find(f'{{{NS["md"]}}}Properties')
                        ts_name = ts_props.find(f'{{{NS["md"]}}}Name') if ts_props is not None else None
                        ts_label = (ts_name.text or '?') if ts_name is not None else '?'
                        ts_child_objects = sub_item.find(f'{{{NS["md"]}}}ChildObjects')
                        if ts_child_objects is None:
                            continue
                        for ts_attr in ts_child_objects:
                            if not isinstance(ts_attr.tag, str):
                                continue
                            if etree.QName(ts_attr.tag).localname != 'Attribute':
                                continue
                            if not borrowed_metadata_declared(ts_attr):
                                continue
                            borrowed_sub_item_count += 1
                            if not validate_borrowed_sub_item('10', f'{ctx}.ТЧ.{ts_label}', 'Attribute', ts_attr):
                                check10_ok = False

                    elif sub_type == 'EnumValue' and type_name == 'Enum':
                        if not is_borrowed_object or not borrowed_metadata_declared(sub_item):
                            continue
                        borrowed_sub_item_count += 1
                        if not validate_borrowed_sub_item('10', ctx, 'EnumValue', sub_item):
                            check10_ok = False

            if r.stopped:
                break

        if borrowed_count == 0:
            r.ok('9. Borrowed objects: none found')
        elif check9_ok:
            r.ok(f'9. Borrowed objects: {borrowed_ok_count}/{borrowed_count} validated')

        if borrowed_sub_item_count == 0:
            r.ok('10. Borrowed sub-items: none found')
        elif check10_ok:
            r.ok(f'10. Borrowed sub-items: {borrowed_sub_item_count} validated')

    # --- Final output ---
    r.finalize(out_file)
    sys.exit(1 if r.errors > 0 else 0)


if __name__ == '__main__':
    main()
