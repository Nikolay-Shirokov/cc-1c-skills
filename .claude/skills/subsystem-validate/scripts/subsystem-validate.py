#!/usr/bin/env python3
# subsystem-validate v1.2 — Validate 1C subsystem XML structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Validates subsystem XML file structure, properties, content items, child objects."""
import sys, os, argparse, re
from lxml import etree

NS = {
    'md':  'http://v8.1c.ru/8.3/MDClasses',
    'v8':  'http://v8.1c.ru/8.1/data/core',
    'xr':  'http://v8.1c.ru/8.3/xcf/readable',
    'xsi': 'http://www.w3.org/2001/XMLSchema-instance',
}

GUID_PATTERN = re.compile(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
)
IDENT_PATTERN = re.compile(
    r'^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_]'
    r'[A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$'
)

KNOWN_PLURAL_TYPES = {
    'Catalogs', 'Documents', 'Enums', 'Constants', 'Reports', 'DataProcessors',
    'InformationRegisters', 'AccumulationRegisters', 'AccountingRegisters', 'CalculationRegisters',
    'ChartsOfAccounts', 'ChartsOfCharacteristicTypes', 'ChartsOfCalculationTypes',
    'BusinessProcesses', 'Tasks', 'ExchangePlans', 'DocumentJournals',
    'CommonModules', 'CommonCommands', 'CommonForms', 'CommonPictures', 'CommonTemplates',
    'CommonAttributes', 'CommandGroups', 'Roles', 'SessionParameters', 'FilterCriteria',
    'XDTOPackages', 'WebServices', 'HTTPServices', 'WSReferences', 'EventSubscriptions',
    'ScheduledJobs', 'SettingsStorages', 'FunctionalOptions', 'FunctionalOptionsParameters',
    'DefinedTypes', 'DocumentNumerators', 'Sequences', 'Subsystems', 'StyleItems', 'IntegrationServices',
}


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
        description='Validate 1C subsystem XML structure', allow_abbrev=False
    )
    parser.add_argument('-SubsystemPath', dest='SubsystemPath', required=True)
    parser.add_argument('-Detailed', action='store_true')
    parser.add_argument('-MaxErrors', dest='MaxErrors', type=int, default=30)
    parser.add_argument('-OutFile', dest='OutFile', default='')
    args = parser.parse_args()

    subsystem_path = args.SubsystemPath
    detailed = args.Detailed
    max_errors = args.MaxErrors
    out_file = args.OutFile

    # --- Resolve path ---
    if not os.path.isabs(subsystem_path):
        subsystem_path = os.path.join(os.getcwd(), subsystem_path)

    if os.path.isdir(subsystem_path):
        dir_name = os.path.basename(subsystem_path)
        candidate = os.path.join(subsystem_path, dir_name + '.xml')
        sibling = os.path.join(os.path.dirname(subsystem_path), dir_name + '.xml')
        if os.path.exists(candidate):
            subsystem_path = candidate
        elif os.path.exists(sibling):
            subsystem_path = sibling
        else:
            print(f'[ERROR] No {dir_name}.xml found in directory: {subsystem_path}')
            sys.exit(1)

    # File not found -- check Dir/Name/Name.xml -> Dir/Name.xml
    if not os.path.exists(subsystem_path):
        fn = os.path.splitext(os.path.basename(subsystem_path))[0]
        pd = os.path.dirname(subsystem_path)
        if fn == os.path.basename(pd):
            c = os.path.join(os.path.dirname(pd), fn + '.xml')
            if os.path.exists(c):
                subsystem_path = c

    if not os.path.exists(subsystem_path):
        print(f'[ERROR] File not found: {subsystem_path}')
        sys.exit(1)

    resolved_path = os.path.abspath(subsystem_path)
    r = Reporter(max_errors, detailed)

    # --- 1. XML well-formedness + root structure ---
    xml_doc = None
    try:
        xml_parser = etree.XMLParser(remove_blank_text=False)
        xml_doc = etree.parse(resolved_path, xml_parser)
    except etree.XMLSyntaxError as e:
        r.error(f'1. XML parse error: {e}')
        r.stopped = True

    sub = None
    version = ''
    if not r.stopped:
        root = xml_doc.getroot()
        version = root.get('version', '')
        sub_list = root.findall('md:Subsystem', NS)
        sub = sub_list[0] if sub_list else None

        if sub is None:
            r.error('1. Root structure: expected MetaDataObject/Subsystem, not found')
            r.stopped = True
        else:
            uuid_val = sub.get('uuid', '')
            if uuid_val and GUID_PATTERN.match(uuid_val):
                r.ok(f'1. Root structure: MetaDataObject/Subsystem, uuid={uuid_val}, version {version}')
            else:
                r.error('1. Root structure: invalid or missing uuid')

    # --- Properties checks ---
    props = None
    if not r.stopped:
        props_list = sub.findall('md:Properties', NS)
        props = props_list[0] if props_list else None
        if props is None:
            r.error('2. Properties: <Properties> element not found')
            r.stopped = True

    sub_name = ''
    if not r.stopped:
        # --- 2. Required properties ---
        required_props = [
            'Name', 'Synonym', 'Comment', 'IncludeHelpInContents',
            'IncludeInCommandInterface', 'UseOneCommand', 'Explanation',
            'Picture', 'Content'
        ]
        missing = []
        for p in required_props:
            el = props.find(f'md:{p}', NS)
            if el is None:
                missing.append(p)

        if len(missing) == 0:
            r.ok('2. Properties: all 9 required properties present')
        else:
            r.error(f'2. Properties: missing: {", ".join(missing)}')

        # --- 3. Name ---
        name_el = props.find('md:Name', NS)
        sub_name = (name_el.text or '').strip() if name_el is not None else ''

        r.out('')
        r.out(f'=== Validation: Subsystem.{sub_name} ===')
        # Re-insert header at position 0
        header_line = f'=== Validation: Subsystem.{sub_name} ==='
        r.lines.insert(0, '')
        r.lines.insert(0, header_line)

        if sub_name and IDENT_PATTERN.match(sub_name):
            r.ok(f'3. Name: "{sub_name}" - valid identifier')
        elif not sub_name:
            r.error('3. Name: empty')
        else:
            r.error(f'3. Name: "{sub_name}" - invalid identifier')

        # --- 4. Synonym ---
        syn_el = props.find('md:Synonym', NS)
        if syn_el is not None and len(syn_el) > 0:
            items = syn_el.findall('v8:item', NS)
            if len(items) > 0:
                first_content = ''
                for item in items:
                    c = item.find('v8:content', NS)
                    if c is not None and c.text:
                        first_content = c.text
                        break
                r.ok(f'4. Synonym: "{first_content}" ({len(items)} lang(s))')
            else:
                r.warn('4. Synonym: element exists but no v8:item children')
        else:
            r.warn('4. Synonym: empty or missing')

        # --- 5. Boolean properties ---
        bool_props = ['IncludeHelpInContents', 'IncludeInCommandInterface', 'UseOneCommand']
        bool_ok = True
        bool_vals = {}
        for bp in bool_props:
            el = props.find(f'md:{bp}', NS)
            if el is not None:
                val = (el.text or '').strip()
                bool_vals[bp] = val
                if val not in ('true', 'false'):
                    r.error(f'5. Boolean property {bp} = "{val}" (expected true/false)')
                    bool_ok = False
        if bool_ok:
            r.ok('5. Boolean properties: valid')

        # --- 6. Content items format ---
        content_el = props.find('md:Content', NS)
        content_items = []
        if content_el is not None and len(content_el) > 0:
            xr_items = content_el.findall('xr:Item', NS)
            content_ok = True
            for item in xr_items:
                type_attr = item.get(f'{{{NS["xsi"]}}}type', '')
                text = (item.text or '').strip()
                content_items.append(text)
                if type_attr != 'xr:MDObjectRef':
                    r.error(f'6. Content item "{text}": xsi:type="{type_attr}" (expected xr:MDObjectRef)')
                    content_ok = False
                if not re.match(r'^[A-Za-z]+\..+$', text) and not GUID_PATTERN.match(text):
                    r.error(f'6. Content item "{text}": invalid format (expected Type.Name or UUID)')
                    content_ok = False
                m = re.match(r'^([A-Za-z]+)\.', text)
                if m and m.group(1) in KNOWN_PLURAL_TYPES:
                    r.error(f'6. Content item "{text}": uses plural form "{m.group(1)}" (platform requires singular, e.g. Catalog not Catalogs)')
                    content_ok = False
            if content_ok:
                r.ok(f'6. Content: {len(xr_items)} items, all valid MDObjectRef format')
        else:
            r.ok('6. Content: empty (no items)')

        # --- 7. Content duplicates ---
        if len(content_items) > 0:
            dupes = find_duplicates(content_items)
            if dupes:
                r.warn(f'7. Content: duplicates found: {", ".join(dupes)}')
            else:
                r.ok('7. Content: no duplicates')

        # --- 8. ChildObjects entries non-empty ---
        child_objs = sub.find('md:ChildObjects', NS)
        child_names = []
        if child_objs is not None and len(child_objs) > 0:
            child_ok = True
            for child in child_objs:
                if not isinstance(child.tag, str):
                    continue
                local_name = etree.QName(child.tag).localname
                if local_name != 'Subsystem':
                    r.error(f'8. ChildObjects: unexpected element <{local_name}>')
                    child_ok = False
                elif not (child.text or '').strip():
                    r.error('8. ChildObjects: empty <Subsystem> element')
                    child_ok = False
                else:
                    child_names.append((child.text or '').strip())
            if child_ok:
                r.ok(f'8. ChildObjects: {len(child_names)} entries, all non-empty')
        else:
            r.ok('8. ChildObjects: empty (leaf subsystem)')

        # --- 9. ChildObjects duplicates ---
        if len(child_names) > 0:
            dupes = find_duplicates(child_names)
            if dupes:
                r.error(f'9. ChildObjects: duplicates: {", ".join(dupes)}')
            else:
                r.ok('9. ChildObjects: no duplicates')

        # --- 10. ChildObjects files exist ---
        if len(child_names) > 0:
            parent_dir = os.path.dirname(resolved_path)
            base_name = os.path.splitext(os.path.basename(resolved_path))[0]
            subs_dir = os.path.join(parent_dir, base_name, 'Subsystems')
            missing_files = []
            for cn in child_names:
                child_xml = os.path.join(subs_dir, cn + '.xml')
                if not os.path.exists(child_xml):
                    missing_files.append(cn)
            if len(missing_files) == 0:
                r.ok(f'10. ChildObjects files: all {len(child_names)} files exist')
            else:
                r.warn(f'10. ChildObjects files: missing: {", ".join(missing_files)}')

        # --- 11. CommandInterface.xml ---
        parent_dir2 = os.path.dirname(resolved_path)
        base_name2 = os.path.splitext(os.path.basename(resolved_path))[0]
        ci_path = os.path.join(parent_dir2, base_name2, 'Ext', 'CommandInterface.xml')
        if os.path.exists(ci_path):
            try:
                etree.parse(ci_path, etree.XMLParser(remove_blank_text=False))
                r.ok('11. CommandInterface: exists, well-formed')
            except etree.XMLSyntaxError as e:
                r.warn(f'11. CommandInterface: exists but NOT well-formed: {e}')
        else:
            r.ok('11. CommandInterface: not present')

        # --- 12. Picture format ---
        pic_el = props.find('md:Picture', NS)
        if pic_el is not None and len(pic_el) > 0:
            pic_ref = pic_el.find('xr:Ref', NS)
            if pic_ref is not None and pic_ref.text:
                ref_text = pic_ref.text
                if ref_text.startswith('CommonPicture.'):
                    r.ok(f'12. Picture: {ref_text}')
                else:
                    r.warn(f'12. Picture: "{ref_text}" (expected CommonPicture.XXX)')
            else:
                r.warn('12. Picture: has children but no xr:Ref content')
        else:
            r.ok('12. Picture: empty (not set)')

        # --- 13. UseOneCommand constraint ---
        use_one = bool_vals.get('UseOneCommand', '')
        if use_one == 'true':
            if len(content_items) == 1:
                r.ok('13. UseOneCommand: true, Content has exactly 1 item')
            else:
                r.warn(f'13. UseOneCommand: true but Content has {len(content_items)} items (expected 1)')
        else:
            r.ok('13. UseOneCommand: false (no constraint)')

    # --- Finalize ---
    checks = r.ok_count + r.errors + r.warnings
    if r.errors == 0 and r.warnings == 0 and not detailed:
        result = f'=== Validation OK: Subsystem.{sub_name} ({checks} checks) ==='
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
