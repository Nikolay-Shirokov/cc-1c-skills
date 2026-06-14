#!/usr/bin/env python3
# subsystem-compile v1.5 — Create 1C subsystem from JSON definition
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid
import xml.etree.ElementTree as ET


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


def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def emit_mltext(lines, indent, tag, text):
    if not text:
        lines.append(f"{indent}<{tag}/>")
        return
    lines.append(f"{indent}<{tag}>")
    lines.append(f"{indent}\t<v8:item>")
    lines.append(f"{indent}\t\t<v8:lang>ru</v8:lang>")
    lines.append(f"{indent}\t\t<v8:content>{esc_xml(text)}</v8:content>")
    lines.append(f"{indent}\t</v8:item>")
    lines.append(f"{indent}</{tag}>")


def new_uuid():
    return str(uuid.uuid4())


def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


def split_camel_case(name):
    if not name:
        return name
    result = re.sub(r'([a-z\u0430-\u044f\u0451])([A-Z\u0410-\u042f\u0401])', r'\1 \2', name)
    if len(result) > 1:
        result = result[0] + result[1:].lower()
    return result


def write_child_subsystem_stub(child_path, child_name, format_version):
    child_uuid = new_uuid()
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(
        '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" '
        'xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
        'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" '
        'xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" '
        'xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" '
        'xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" '
        'xmlns:style="http://v8.1c.ru/8.1/data/ui/style" '
        'xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" '
        'xmlns:v8="http://v8.1c.ru/8.1/data/core" '
        'xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" '
        'xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" '
        'xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" '
        'xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" '
        'xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" '
        'xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" '
        'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        f'version="{format_version}">'
    )
    lines.append(f'\t<Subsystem uuid="{child_uuid}">')
    lines.append('\t\t<Properties>')
    lines.append(f'\t\t\t<Name>{esc_xml(child_name)}</Name>')
    lines.append('\t\t\t<Synonym/>')
    lines.append('\t\t\t<Comment/>')
    lines.append('\t\t\t<IncludeHelpInContents>true</IncludeHelpInContents>')
    lines.append('\t\t\t<IncludeInCommandInterface>true</IncludeInCommandInterface>')
    lines.append('\t\t\t<UseOneCommand>false</UseOneCommand>')
    lines.append('\t\t\t<Explanation/>')
    lines.append('\t\t\t<Picture/>')
    lines.append('\t\t\t<Content/>')
    lines.append('\t\t</Properties>')
    lines.append('\t\t<ChildObjects/>')
    lines.append('\t</Subsystem>')
    lines.append('</MetaDataObject>')
    write_utf8_bom(child_path, '\n'.join(lines) + '\n')


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C subsystem from JSON definition', allow_abbrev=False)
    parser.add_argument('-DefinitionFile', type=str, default=None)
    parser.add_argument('-Value', type=str, default=None)
    parser.add_argument('-OutputDir', type=str, required=True)
    parser.add_argument('-Parent', type=str, default=None)
    parser.add_argument('-NoValidate', action='store_true', default=False)
    args = parser.parse_args()

    # --- 1. Load JSON ---
    if args.DefinitionFile and args.Value:
        print("Cannot use both -DefinitionFile and -Value", file=sys.stderr)
        sys.exit(1)
    if not args.DefinitionFile and not args.Value:
        print("Either -DefinitionFile or -Value is required", file=sys.stderr)
        sys.exit(1)

    if args.DefinitionFile:
        def_file = args.DefinitionFile
        if not os.path.isabs(def_file):
            def_file = os.path.join(os.getcwd(), def_file)
        if not os.path.exists(def_file):
            print(f"Definition file not found: {def_file}", file=sys.stderr)
            sys.exit(1)
        with open(def_file, 'r', encoding='utf-8-sig') as f:
            json_text = f.read()
    else:
        json_text = args.Value

    defn = json.loads(json_text)

    if not defn.get('name'):
        print("JSON must have 'name' field", file=sys.stderr)
        sys.exit(1)

    obj_name = str(defn['name'])

    # Resolve OutputDir
    output_dir = args.OutputDir
    if not os.path.isabs(output_dir):
        output_dir = os.path.join(os.getcwd(), output_dir)

    # --- 2. Content type normalization (plural→singular, Russian→English) ---
    CONTENT_TYPE_MAP = {
        # Plural English → Singular
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
        'SessionParameters': 'SessionParameter', 'FilterCriteria': 'FilterCriterion',
        'XDTOPackages': 'XDTOPackage', 'WebServices': 'WebService',
        'HTTPServices': 'HTTPService', 'WSReferences': 'WSReference',
        'EventSubscriptions': 'EventSubscription', 'ScheduledJobs': 'ScheduledJob',
        'SettingsStorages': 'SettingsStorage', 'FunctionalOptions': 'FunctionalOption',
        'FunctionalOptionsParameters': 'FunctionalOptionsParameter',
        'DefinedTypes': 'DefinedType', 'DocumentNumerators': 'DocumentNumerator',
        'Sequences': 'Sequence', 'Subsystems': 'Subsystem',
        'StyleItems': 'StyleItem', 'IntegrationServices': 'IntegrationService',
        # Russian singular → English
        'Справочник': 'Catalog', 'Каталог': 'Catalog', 'Документ': 'Document',
        'Перечисление': 'Enum', 'Константа': 'Constant',
        'Отчёт': 'Report', 'Отчет': 'Report', 'Обработка': 'DataProcessor',
        'РегистрСведений': 'InformationRegister', 'РегистрНакопления': 'AccumulationRegister',
        'РегистрБухгалтерии': 'AccountingRegister',
        'РегистрРасчёта': 'CalculationRegister', 'РегистрРасчета': 'CalculationRegister',
        'ПланСчетов': 'ChartOfAccounts', 'ПланВидовХарактеристик': 'ChartOfCharacteristicTypes',
        'ПланВидовРасчёта': 'ChartOfCalculationTypes', 'ПланВидовРасчета': 'ChartOfCalculationTypes',
        'БизнесПроцесс': 'BusinessProcess', 'Задача': 'Task',
        'ПланОбмена': 'ExchangePlan', 'ЖурналДокументов': 'DocumentJournal',
        'ОбщийМодуль': 'CommonModule', 'ОбщаяКоманда': 'CommonCommand',
        'ОбщаяФорма': 'CommonForm', 'ОбщаяКартинка': 'CommonPicture',
        'ОбщийМакет': 'CommonTemplate', 'ОбщийРеквизит': 'CommonAttribute',
        'ГруппаКоманд': 'CommandGroup', 'Роль': 'Role',
        'ПараметрСеанса': 'SessionParameter', 'КритерийОтбора': 'FilterCriterion',
        'ПакетXDTO': 'XDTOPackage', 'ВебСервис': 'WebService',
        'HTTPСервис': 'HTTPService', 'WSСсылка': 'WSReference',
        'ПодпискаНаСобытие': 'EventSubscription', 'РегламентноеЗадание': 'ScheduledJob',
        'ХранилищеНастроек': 'SettingsStorage', 'ФункциональнаяОпция': 'FunctionalOption',
        'ПараметрФункциональныхОпций': 'FunctionalOptionsParameter',
        'ОпределяемыйТип': 'DefinedType', 'НумераторДокументов': 'DocumentNumerator',
        'Последовательность': 'Sequence', 'Подсистема': 'Subsystem',
        'ЭлементСтиля': 'StyleItem', 'СервисИнтеграции': 'IntegrationService',
        # Russian plural → English
        'Справочники': 'Catalog', 'Документы': 'Document', 'Перечисления': 'Enum',
        'Константы': 'Constant', 'Отчёты': 'Report', 'Отчеты': 'Report',
        'Обработки': 'DataProcessor', 'РегистрыСведений': 'InformationRegister',
        'РегистрыНакопления': 'AccumulationRegister', 'РегистрыБухгалтерии': 'AccountingRegister',
        'РегистрыРасчёта': 'CalculationRegister', 'РегистрыРасчета': 'CalculationRegister',
        'ПланыСчетов': 'ChartOfAccounts', 'ПланыВидовХарактеристик': 'ChartOfCharacteristicTypes',
        'ПланыВидовРасчёта': 'ChartOfCalculationTypes', 'ПланыВидовРасчета': 'ChartOfCalculationTypes',
        'БизнесПроцессы': 'BusinessProcess', 'Задачи': 'Task',
        'ПланыОбмена': 'ExchangePlan', 'ЖурналыДокументов': 'DocumentJournal',
        'ОбщиеМодули': 'CommonModule', 'ОбщиеКоманды': 'CommonCommand',
        'ОбщиеФормы': 'CommonForm', 'ОбщиеКартинки': 'CommonPicture',
        'ОбщиеМакеты': 'CommonTemplate', 'ОбщиеРеквизиты': 'CommonAttribute',
        'ГруппыКоманд': 'CommandGroup', 'Роли': 'Role',
        'ПараметрыСеанса': 'SessionParameter', 'КритерииОтбора': 'FilterCriterion',
        'ПакетыXDTO': 'XDTOPackage', 'ВебСервисы': 'WebService',
        'HTTPСервисы': 'HTTPService', 'WSСсылки': 'WSReference',
        'ПодпискиНаСобытия': 'EventSubscription', 'РегламентныеЗадания': 'ScheduledJob',
        'ХранилищаНастроек': 'SettingsStorage', 'ФункциональныеОпции': 'FunctionalOption',
        'ОпределяемыеТипы': 'DefinedType', 'Подсистемы': 'Subsystem',
        'ЭлементыСтиля': 'StyleItem', 'СервисыИнтеграции': 'IntegrationService',
    }

    def normalize_content_ref(ref):
        if not ref or '.' not in ref:
            return ref
        dot_idx = ref.index('.')
        type_part = ref[:dot_idx]
        name_part = ref[dot_idx + 1:]
        if type_part in CONTENT_TYPE_MAP:
            type_part = CONTENT_TYPE_MAP[type_part]
        return f'{type_part}.{name_part}'

    format_version = detect_format_version(output_dir)

    # --- 3. Resolve defaults ---
    synonym = str(defn['synonym']) if defn.get('synonym') else split_camel_case(obj_name)
    comment = str(defn['comment']) if defn.get('comment') else ''
    include_help_in_contents = 'true'
    include_in_ci = str(defn['includeInCommandInterface']).lower() if defn.get('includeInCommandInterface') is not None else 'true'
    use_one_command = str(defn['useOneCommand']).lower() if defn.get('useOneCommand') is not None else 'false'
    explanation = str(defn['explanation']) if defn.get('explanation') else ''
    picture = str(defn['picture']) if defn.get('picture') else ''

    # Synonym: accept "objects" as alias for "content"
    if not defn.get('content') and defn.get('objects'):
        defn['content'] = defn['objects']

    content_items = []
    normalized_count = 0
    if defn.get('content'):
        for c in defn['content']:
            raw = str(c)
            normalized = normalize_content_ref(raw)
            if normalized != raw:
                print(f'[NORM] Content: {raw} -> {normalized}')
                normalized_count += 1
            content_items.append(normalized)
    if normalized_count > 0:
        print(f'[INFO] Normalized {normalized_count} content reference(s) to singular English form')

    children = []
    if defn.get('children'):
        for ch in defn['children']:
            children.append(str(ch))

    # --- 3. Build XML ---
    uid = new_uuid()
    lines = []

    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(f'<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="{format_version}">')
    lines.append(f'\t<Subsystem uuid="{uid}">')
    lines.append('\t\t<Properties>')

    # Name
    lines.append(f'\t\t\t<Name>{esc_xml(obj_name)}</Name>')

    # Synonym
    emit_mltext(lines, '\t\t\t', 'Synonym', synonym)

    # Comment
    if comment:
        lines.append(f'\t\t\t<Comment>{esc_xml(comment)}</Comment>')
    else:
        lines.append('\t\t\t<Comment/>')

    # Boolean properties
    lines.append(f'\t\t\t<IncludeHelpInContents>{include_help_in_contents}</IncludeHelpInContents>')
    lines.append(f'\t\t\t<IncludeInCommandInterface>{include_in_ci}</IncludeInCommandInterface>')
    lines.append(f'\t\t\t<UseOneCommand>{use_one_command}</UseOneCommand>')

    # Explanation
    emit_mltext(lines, '\t\t\t', 'Explanation', explanation)

    # Picture
    if picture:
        lines.append('\t\t\t<Picture>')
        lines.append(f'\t\t\t\t<xr:Ref>{picture}</xr:Ref>')
        lines.append('\t\t\t\t<xr:LoadTransparent>false</xr:LoadTransparent>')
        lines.append('\t\t\t</Picture>')
    else:
        lines.append('\t\t\t<Picture/>')

    # Content
    if len(content_items) > 0:
        lines.append('\t\t\t<Content>')
        for item in content_items:
            lines.append(f'\t\t\t\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml(item)}</xr:Item>')
        lines.append('\t\t\t</Content>')
    else:
        lines.append('\t\t\t<Content/>')

    lines.append('\t\t</Properties>')

    # ChildObjects
    if len(children) > 0:
        lines.append('\t\t<ChildObjects>')
        for ch in children:
            lines.append(f'\t\t\t<Subsystem>{esc_xml(ch)}</Subsystem>')
        lines.append('\t\t</ChildObjects>')
    else:
        lines.append('\t\t<ChildObjects/>')

    lines.append('\t</Subsystem>')
    lines.append('</MetaDataObject>')

    # --- 4. Write files ---
    parent = args.Parent

    if parent:
        # Nested subsystem
        if not os.path.isabs(parent):
            parent = os.path.join(os.getcwd(), parent)
        if not os.path.exists(parent):
            print(f"Parent subsystem not found: {parent}", file=sys.stderr)
            sys.exit(1)
        parent_dir = os.path.dirname(parent)
        parent_base_name = os.path.splitext(os.path.basename(parent))[0]
        subs_dir = os.path.join(parent_dir, parent_base_name, 'Subsystems')
    else:
        # Top-level subsystem
        subs_dir = os.path.join(output_dir, 'Subsystems')

    os.makedirs(subs_dir, exist_ok=True)

    target_xml = os.path.join(subs_dir, f'{obj_name}.xml')

    # Write XML
    xml_content = '\n'.join(lines) + '\n'
    write_utf8_bom(target_xml, xml_content)
    print(f"[OK] Created: {target_xml}")

    # Create subdirectory and stub files for children if they exist
    if len(children) > 0:
        child_subs_dir = os.path.join(subs_dir, obj_name, 'Subsystems')
        if not os.path.exists(child_subs_dir):
            os.makedirs(child_subs_dir, exist_ok=True)
            print(f"[OK] Created directory: {child_subs_dir}")
        seen = set()
        for ch in children:
            if ch in seen:
                continue
            seen.add(ch)
            child_xml = os.path.join(child_subs_dir, f'{ch}.xml')
            if not os.path.exists(child_xml):
                write_child_subsystem_stub(child_xml, ch, format_version)
                print(f"[OK] Created stub: {child_xml}")

    # --- 5. Register in parent ---
    parent_xml_path = None
    if parent:
        parent_xml_path = parent
    else:
        config_xml = os.path.join(output_dir, 'Configuration.xml')
        if os.path.exists(config_xml):
            parent_xml_path = config_xml

    if parent_xml_path and os.path.exists(parent_xml_path):
        with open(parent_xml_path, 'r', encoding='utf-8-sig') as f:
            raw_text = f.read()

        doc = ET.ElementTree(ET.fromstring(raw_text))
        root = doc.getroot()
        md_ns = 'http://v8.1c.ru/8.3/MDClasses'

        # Find ChildObjects
        child_objects = None
        if parent:
            for sub in root.iter(f'{{{md_ns}}}Subsystem'):
                child_objects = sub.find(f'{{{md_ns}}}ChildObjects')
                break
        else:
            for cfg in root.iter(f'{{{md_ns}}}Configuration'):
                child_objects = cfg.find(f'{{{md_ns}}}ChildObjects')
                break

        if child_objects is not None:
            # Check if already registered
            already_exists = False
            for child in child_objects:
                if child.tag == f'{{{md_ns}}}Subsystem' and child.text == obj_name:
                    already_exists = True
                    break

            if not already_exists:
                new_el = ET.SubElement(child_objects, f'{{{md_ns}}}Subsystem')
                new_el.text = obj_name

                # Re-serialize with whitespace preservation via raw text manipulation instead
                # Since ElementTree doesn't preserve whitespace well, use regex-based insertion
                # Find </ChildObjects> or <ChildObjects/> and inject
                pass  # Fall through to raw text approach below

            if not already_exists:
                # Use raw text manipulation to preserve formatting
                if '<ChildObjects/>' in raw_text:
                    replacement = f'<ChildObjects>\n\t\t\t<Subsystem>{esc_xml(obj_name)}</Subsystem>\n\t\t</ChildObjects>'
                    raw_text = raw_text.replace('<ChildObjects/>', replacement, 1)
                elif '</ChildObjects>' in raw_text:
                    insert_line = f'\t\t\t<Subsystem>{esc_xml(obj_name)}</Subsystem>\n'
                    raw_text = raw_text.replace('</ChildObjects>', insert_line + '\t\t</ChildObjects>', 1)

                write_utf8_bom(parent_xml_path, raw_text)
                print(f"[OK] Registered in: {parent_xml_path}")
            else:
                print(f"[SKIP] Already registered in: {parent_xml_path}")
        else:
            print(f"[WARN] ChildObjects not found in: {parent_xml_path}")
    else:
        print("[INFO] No parent XML to register in")

    # --- 6. Auto-validate ---
    if not args.NoValidate:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        validate_script = os.path.normpath(os.path.join(script_dir, '..', '..', 'subsystem-validate', 'scripts', 'subsystem-validate.ps1'))
        if os.path.exists(validate_script):
            print()
            print("--- Running subsystem-validate ---")
            os.system(f'powershell.exe -NoProfile -File "{validate_script}" -SubsystemPath "{target_xml}"')

    # --- 7. Summary ---
    print()
    print("=== subsystem-compile summary ===")
    print(f"  Name:     {obj_name}")
    print(f"  UUID:     {uid}")
    print(f"  Content:  {len(content_items)} objects")
    print(f"  Children: {len(children)}")
    print(f"  File:     {target_xml}")
    sys.exit(0)


if __name__ == '__main__':
    main()
