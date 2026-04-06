#!/usr/bin/env python3
# role-compile v1.4 — Compile 1C role from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid


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


# --- Russian synonyms -> canonical English names ---

TYPE_ALIASES = {
    "Справочник": "Catalog",
    "Документ": "Document",
    "РегистрСведений": "InformationRegister",
    "РегистрНакопления": "AccumulationRegister",
    "РегистрБухгалтерии": "AccountingRegister",
    "РегистрРасчета": "CalculationRegister",
    "Константа": "Constant",
    "ПланСчетов": "ChartOfAccounts",
    "ПланВидовХарактеристик": "ChartOfCharacteristicTypes",
    "ПланВидовРасчета": "ChartOfCalculationTypes",
    "ПланОбмена": "ExchangePlan",
    "БизнесПроцесс": "BusinessProcess",
    "Задача": "Task",
    "Обработка": "DataProcessor",
    "Отчет": "Report",
    "ОбщаяФорма": "CommonForm",
    "ОбщаяКоманда": "CommonCommand",
    "Подсистема": "Subsystem",
    "КритерийОтбора": "FilterCriterion",
    "ЖурналДокументов": "DocumentJournal",
    "Последовательность": "Sequence",
    "ВебСервис": "WebService",
    "HTTPСервис": "HTTPService",
    "СервисИнтеграции": "IntegrationService",
    "ПараметрСеанса": "SessionParameter",
    "ОбщийРеквизит": "CommonAttribute",
    "Конфигурация": "Configuration",
    "Перечисление": "Enum",
    # Nested
    "Реквизит": "Attribute",
    "СтандартныйРеквизит": "StandardAttribute",
    "ТабличнаяЧасть": "TabularSection",
    "Измерение": "Dimension",
    "Ресурс": "Resource",
    "Команда": "Command",
    "РеквизитАдресации": "AddressingAttribute",
}

RIGHT_ALIASES = {
    "Чтение": "Read",
    "Добавление": "Insert",
    "Изменение": "Update",
    "Удаление": "Delete",
    "Просмотр": "View",
    "Редактирование": "Edit",
    "ВводПоСтроке": "InputByString",
    "Проведение": "Posting",
    "ОтменаПроведения": "UndoPosting",
    "ИнтерактивноеДобавление": "InteractiveInsert",
    "ИнтерактивнаяПометкаУдаления": "InteractiveSetDeletionMark",
    "ИнтерактивноеСнятиеПометкиУдаления": "InteractiveClearDeletionMark",
    "ИнтерактивноеУдаление": "InteractiveDelete",
    "ИнтерактивноеУдалениеПомеченных": "InteractiveDeleteMarked",
    "ИнтерактивноеПроведение": "InteractivePosting",
    "ИнтерактивноеПроведениеНеоперативное": "InteractivePostingRegular",
    "ИнтерактивнаяОтменаПроведения": "InteractiveUndoPosting",
    "ИнтерактивноеИзменениеПроведенных": "InteractiveChangeOfPosted",
    "Использование": "Use",
    "Получение": "Get",
    "Установка": "Set",
    "Старт": "Start",
    "ИнтерактивныйСтарт": "InteractiveStart",
    "ИнтерактивнаяАктивация": "InteractiveActivate",
    "Выполнение": "Execute",
    "ИнтерактивноеВыполнение": "InteractiveExecute",
    "УправлениеИтогами": "TotalsControl",
    "Администрирование": "Administration",
    "АдминистрированиеДанных": "DataAdministration",
    "ТонкийКлиент": "ThinClient",
    "ВебКлиент": "WebClient",
    "ТолстыйКлиент": "ThickClient",
    "ВнешнееСоединение": "ExternalConnection",
    "Вывод": "Output",
    "СохранениеДанныхПользователя": "SaveUserData",
    "МобильныйКлиент": "MobileClient",
}

# --- Known rights per object type ---

KNOWN_RIGHTS = {
    "Configuration": [
        "Administration", "DataAdministration", "UpdateDataBaseConfiguration",
        "ConfigurationExtensionsAdministration", "ActiveUsers", "EventLog", "ExclusiveMode",
        "ThinClient", "ThickClient", "WebClient", "MobileClient", "ExternalConnection",
        "Automation", "Output", "SaveUserData", "TechnicalSpecialistMode",
        "InteractiveOpenExtDataProcessors", "InteractiveOpenExtReports",
        "AnalyticsSystemClient", "CollaborationSystemInfoBaseRegistration",
        "MainWindowModeNormal", "MainWindowModeWorkplace",
        "MainWindowModeEmbeddedWorkplace", "MainWindowModeFullscreenWorkplace", "MainWindowModeKiosk",
    ],
    "Catalog": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistoryOfMissingData", "ReadDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "Document": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "Posting", "UndoPosting",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractivePosting", "InteractivePostingRegular", "InteractiveUndoPosting",
        "InteractiveChangeOfPosted",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistoryOfMissingData", "ReadDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "InformationRegister": [
        "Read", "Update", "View", "Edit", "TotalsControl",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistoryOfMissingData", "ReadDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "AccumulationRegister": ["Read", "Update", "View", "Edit", "TotalsControl"],
    "AccountingRegister": ["Read", "Update", "View", "Edit", "TotalsControl"],
    "CalculationRegister": ["Read", "View"],
    "Constant": [
        "Read", "Update", "View", "Edit",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "ChartOfAccounts": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData",
        "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
    ],
    "ChartOfCharacteristicTypes": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "ChartOfCalculationTypes": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
    ],
    "ExchangePlan": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "BusinessProcess": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "Start", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveActivate", "InteractiveStart",
    ],
    "Task": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "Execute", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveActivate", "InteractiveExecute",
    ],
    "DataProcessor": ["Use", "View"],
    "Report": ["Use", "View"],
    "CommonForm": ["View"],
    "CommonCommand": ["View"],
    "Subsystem": ["View"],
    "FilterCriterion": ["View"],
    "DocumentJournal": ["Read", "View"],
    "Sequence": ["Read", "Update"],
    "WebService": ["Use"],
    "HTTPService": ["Use"],
    "IntegrationService": ["Use"],
    "SessionParameter": ["Get", "Set"],
    "CommonAttribute": ["View", "Edit"],
}

NESTED_RIGHTS = ["View", "Edit"]
COMMAND_RIGHTS = ["View"]

# --- Presets ---

PRESETS = {
    "view": {
        "Catalog": ["Read", "View", "InputByString"],
        "ExchangePlan": ["Read", "View", "InputByString"],
        "Document": ["Read", "View", "InputByString"],
        "ChartOfAccounts": ["Read", "View", "InputByString"],
        "ChartOfCharacteristicTypes": ["Read", "View", "InputByString"],
        "ChartOfCalculationTypes": ["Read", "View", "InputByString"],
        "BusinessProcess": ["Read", "View", "InputByString"],
        "Task": ["Read", "View", "InputByString"],
        "InformationRegister": ["Read", "View"],
        "AccumulationRegister": ["Read", "View"],
        "AccountingRegister": ["Read", "View"],
        "CalculationRegister": ["Read", "View"],
        "Constant": ["Read", "View"],
        "DocumentJournal": ["Read", "View"],
        "Sequence": ["Read"],
        "CommonForm": ["View"],
        "CommonCommand": ["View"],
        "Subsystem": ["View"],
        "FilterCriterion": ["View"],
        "SessionParameter": ["Get"],
        "CommonAttribute": ["View"],
        "DataProcessor": ["Use", "View"],
        "Report": ["Use", "View"],
        "Configuration": ["ThinClient", "WebClient", "Output", "SaveUserData", "MainWindowModeNormal"],
    },
    "edit": {
        "Catalog": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "ExchangePlan": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "Document": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "Posting", "UndoPosting", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractivePosting", "InteractivePostingRegular", "InteractiveUndoPosting", "InteractiveChangeOfPosted"],
        "ChartOfAccounts": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "ChartOfCharacteristicTypes": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "ChartOfCalculationTypes": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "BusinessProcess": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "Start", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveActivate", "InteractiveStart"],
        "Task": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "Execute", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveActivate", "InteractiveExecute"],
        "InformationRegister": ["Read", "Update", "View", "Edit"],
        "AccumulationRegister": ["Read", "Update", "View", "Edit"],
        "AccountingRegister": ["Read", "Update", "View", "Edit"],
        "Constant": ["Read", "Update", "View", "Edit"],
        "DocumentJournal": ["Read", "View"],
        "Sequence": ["Read", "Update"],
        "SessionParameter": ["Get", "Set"],
        "CommonAttribute": ["View", "Edit"],
    },
}


def translate_object_name(name):
    parts = name.split('.')
    result = []
    for p in parts:
        result.append(TYPE_ALIASES.get(p, p))
    return '.'.join(result)


def translate_right_name(name):
    return RIGHT_ALIASES.get(name, name)


def get_object_type(object_name):
    dot_idx = object_name.find('.')
    if dot_idx < 0:
        return object_name
    return object_name[:dot_idx]


def is_nested_object(object_name):
    return len(object_name.split('.')) >= 3


def resolve_preset(object_type, preset_name):
    preset = preset_name.lstrip('@')
    if preset not in PRESETS:
        print(f"WARNING: Unknown preset '@{preset}'. Known: @view, @edit", file=sys.stderr)
        return []
    type_map = PRESETS[preset]
    if object_type not in type_map:
        available = []
        for k in PRESETS:
            if object_type in PRESETS[k]:
                available.append(f'@{k}')
        avail_str = ', '.join(available) if available else 'none'
        print(f"WARNING: Preset '@{preset}' not defined for type '{object_type}'. Available: {avail_str}", file=sys.stderr)
        return []
    return list(type_map[object_type])


def validate_right_name(object_name, right_name):
    object_type = get_object_type(object_name)

    if is_nested_object(object_name):
        if '.Command.' in object_name:
            if right_name not in COMMAND_RIGHTS:
                print(f"WARNING: {object_name}: '{right_name}' not valid for commands (only: View)", file=sys.stderr)
                return False
        else:
            if right_name not in NESTED_RIGHTS:
                print(f"WARNING: {object_name}: '{right_name}' not valid for nested objects (only: View, Edit)", file=sys.stderr)
                return False
        return True

    if object_type not in KNOWN_RIGHTS:
        print(f"WARNING: {object_name}: unknown object type '{object_type}'", file=sys.stderr)
        return True

    valid_rights = KNOWN_RIGHTS[object_type]
    if right_name not in valid_rights:
        suggestions = [r for r in valid_rights if right_name in r or r in right_name]
        sug_str = f" Did you mean: {', '.join(suggestions)}?" if suggestions else ""
        print(f"WARNING: {object_name}: unknown right '{right_name}'.{sug_str}", file=sys.stderr)
        return False

    return True


def parse_object_entry(entry):
    # --- String shorthand ---
    if isinstance(entry, str):
        colon_idx = entry.find(':')
        if colon_idx < 0:
            print(f"WARNING: Invalid string '{entry}' -- expected 'Object.Name: @preset' or 'Object.Name: Right1, Right2'", file=sys.stderr)
            return None
        obj_name = translate_object_name(entry[:colon_idx].strip())
        rights_str = entry[colon_idx + 1:].strip()
        object_type = get_object_type(obj_name)

        if rights_str.startswith('@'):
            right_names = resolve_preset(object_type, rights_str)
        else:
            right_names = [translate_right_name(r.strip()) for r in rights_str.split(',') if r.strip()]
            for r in right_names:
                validate_right_name(obj_name, r)

        rights = []
        for r in right_names:
            rights.append({'Name': r, 'Value': 'true', 'Condition': None})
        return {'Name': obj_name, 'Rights': rights}

    # --- Object form ---
    obj_name = translate_object_name(str(entry.get('name', '')))
    if not obj_name:
        print("WARNING: Object entry missing 'name' field", file=sys.stderr)
        return None

    object_type = get_object_type(obj_name)
    # Use a list of tuples to preserve insertion order
    rights_map = {}  # name -> {Value, Condition}
    rights_order = []  # preserve order

    # 1) Start with preset
    if entry.get('preset'):
        preset_rights = resolve_preset(object_type, str(entry['preset']))
        for r in preset_rights:
            if r not in rights_map:
                rights_order.append(r)
            rights_map[r] = {'Value': 'true', 'Condition': None}

    # 2) Apply explicit rights
    if entry.get('rights') is not None:
        if isinstance(entry['rights'], list):
            for r in entry['rights']:
                r_name = translate_right_name(str(r))
                validate_right_name(obj_name, r_name)
                if r_name not in rights_map:
                    rights_order.append(r_name)
                rights_map[r_name] = {'Value': 'true', 'Condition': None}
        elif isinstance(entry['rights'], dict):
            for p_name, p_value in entry['rights'].items():
                r_name = translate_right_name(p_name)
                validate_right_name(obj_name, r_name)
                bool_val = 'true' if p_value is True or str(p_value) == 'True' else 'false'
                if r_name not in rights_map:
                    rights_order.append(r_name)
                rights_map[r_name] = {'Value': bool_val, 'Condition': None}

    # 3) Apply RLS conditions
    if entry.get('rls'):
        for p_name, p_value in entry['rls'].items():
            rls_right = translate_right_name(p_name)
            if rls_right in rights_map:
                rights_map[rls_right]['Condition'] = str(p_value)
            else:
                print(f"WARNING: {obj_name}: RLS for '{rls_right}' but this right is not in the rights list", file=sys.stderr)

    # Convert to array
    rights = []
    for k in rights_order:
        rights.append({
            'Name': k,
            'Value': rights_map[k]['Value'],
            'Condition': rights_map[k]['Condition'],
        })

    return {'Name': obj_name, 'Rights': rights}


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C role from JSON', allow_abbrev=False)
    parser.add_argument('-JsonPath', type=str, required=True)
    parser.add_argument('-OutputDir', type=str, required=True)
    args = parser.parse_args()

    # --- 1. Load and validate JSON ---
    json_path = args.JsonPath
    if not os.path.exists(json_path):
        print(f"File not found: {json_path}", file=sys.stderr)
        sys.exit(1)

    with open(json_path, 'r', encoding='utf-8-sig') as f:
        defn = json.load(f)

    if not defn.get('name'):
        print("JSON must have 'name' field (role programmatic name)", file=sys.stderr)
        sys.exit(1)

    role_name = str(defn['name'])
    synonym = str(defn['synonym']) if defn.get('synonym') else role_name
    comment = str(defn['comment']) if defn.get('comment') else ''

    # Synonym: accept "rights" as alias for "objects"
    if not defn.get('objects') and defn.get('rights'):
        defn['objects'] = defn['rights']

    out_dir_resolved = args.OutputDir if os.path.isabs(args.OutputDir) else os.path.join(os.getcwd(), args.OutputDir)
    format_version = detect_format_version(out_dir_resolved)

    # --- 2. Parse all object entries ---
    parsed_objects = []
    if defn.get('objects'):
        for entry in defn['objects']:
            parsed = parse_object_entry(entry)
            if parsed:
                parsed_objects.append(parsed)

    # --- 3. Generate UUID ---
    uid = new_uuid()

    # --- 4. Emit metadata XML (Roles/Name.xml) ---
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"')
    lines.append('        xmlns:app="http://v8.1c.ru/8.2/managed-application/core"')
    lines.append('        xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"')
    lines.append('        xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi"')
    lines.append('        xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"')
    lines.append('        xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"')
    lines.append('        xmlns:style="http://v8.1c.ru/8.1/data/ui/style"')
    lines.append('        xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"')
    lines.append('        xmlns:v8="http://v8.1c.ru/8.1/data/core"')
    lines.append('        xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"')
    lines.append('        xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"')
    lines.append('        xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"')
    lines.append('        xmlns:xen="http://v8.1c.ru/8.3/xcf/enums"')
    lines.append('        xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef"')
    lines.append('        xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"')
    lines.append('        xmlns:xs="http://www.w3.org/2001/XMLSchema"')
    lines.append('        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
    lines.append(f'        version="{format_version}">')
    lines.append(f'    <Role uuid="{uid}">')
    lines.append('        <Properties>')
    lines.append(f'            <Name>{role_name}</Name>')
    lines.append('            <Synonym>')
    lines.append('                <v8:item>')
    lines.append('                    <v8:lang>ru</v8:lang>')
    lines.append(f'                    <v8:content>{esc_xml(synonym)}</v8:content>')
    lines.append('                </v8:item>')
    lines.append('            </Synonym>')
    if comment:
        lines.append(f'            <Comment>{esc_xml(comment)}</Comment>')
    else:
        lines.append('            <Comment/>')
    lines.append('        </Properties>')
    lines.append('    </Role>')
    lines.append('</MetaDataObject>')

    metadata_xml = '\n'.join(lines) + '\n'

    # --- 5. Emit Rights XML (Roles/Name/Ext/Rights.xml) ---
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<Rights xmlns="http://v8.1c.ru/8.2/roles"')
    lines.append('        xmlns:xs="http://www.w3.org/2001/XMLSchema"')
    lines.append('        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
    lines.append(f'        xsi:type="Rights" version="{format_version}">')

    # Global flags
    sfno = str(defn['setForNewObjects']).lower() if defn.get('setForNewObjects') is not None else 'false'
    sfab = str(defn['setForAttributesByDefault']).lower() if defn.get('setForAttributesByDefault') is not None else 'true'
    irco = str(defn['independentRightsOfChildObjects']).lower() if defn.get('independentRightsOfChildObjects') is not None else 'false'

    lines.append(f'    <setForNewObjects>{sfno}</setForNewObjects>')
    lines.append(f'    <setForAttributesByDefault>{sfab}</setForAttributesByDefault>')
    lines.append(f'    <independentRightsOfChildObjects>{irco}</independentRightsOfChildObjects>')

    # Object blocks
    total_rights = 0
    for obj in parsed_objects:
        lines.append('    <object>')
        lines.append(f'        <name>{obj["Name"]}</name>')
        for right in obj['Rights']:
            lines.append('        <right>')
            lines.append(f'            <name>{right["Name"]}</name>')
            lines.append(f'            <value>{right["Value"]}</value>')
            if right['Condition']:
                lines.append('            <restrictionByCondition>')
                lines.append(f'                <condition>{esc_xml(right["Condition"])}</condition>')
                lines.append('            </restrictionByCondition>')
            lines.append('        </right>')
            total_rights += 1
        lines.append('    </object>')

    # RLS restriction templates
    template_count = 0
    if defn.get('templates'):
        for tpl in defn['templates']:
            lines.append('    <restrictionTemplate>')
            lines.append(f'        <name>{esc_xml(str(tpl["name"]))}</name>')
            lines.append(f'        <condition>{esc_xml(str(tpl["condition"]))}</condition>')
            lines.append('    </restrictionTemplate>')
            template_count += 1

    lines.append('</Rights>')

    rights_xml = '\n'.join(lines) + '\n'

    # --- 6. Write output files ---
    out_dir = args.OutputDir
    if not os.path.isabs(out_dir):
        out_dir = os.path.join(os.getcwd(), out_dir)

    # Determine Roles dir and config root
    # Back-compat: if OutputDir leaf is "Roles", use as-is; otherwise treat as config root
    leaf = os.path.basename(out_dir.rstrip(os.sep).rstrip('/'))
    if leaf == 'Roles':
        roles_dir = out_dir
        config_dir = os.path.dirname(out_dir)
    else:
        roles_dir = os.path.join(out_dir, 'Roles')
        config_dir = out_dir

    # Metadata: Roles/RoleName.xml
    metadata_path = os.path.join(roles_dir, f'{role_name}.xml')
    os.makedirs(roles_dir, exist_ok=True)

    # Rights: Roles/RoleName/Ext/Rights.xml
    role_sub_dir = os.path.join(roles_dir, role_name)
    ext_dir = os.path.join(role_sub_dir, 'Ext')
    rights_path = os.path.join(ext_dir, 'Rights.xml')
    os.makedirs(ext_dir, exist_ok=True)

    write_utf8_bom(metadata_path, metadata_xml)
    write_utf8_bom(rights_path, rights_xml)

    # --- 7. Register in Configuration.xml ---
    config_xml_path = os.path.join(config_dir, 'Configuration.xml')
    reg_result = None

    if os.path.exists(config_xml_path):
        with open(config_xml_path, 'r', encoding='utf-8-sig') as f:
            raw_text = f.read()

        # Check if already registered
        if f'<Role>{role_name}</Role>' in raw_text:
            reg_result = 'already'
        else:
            # Find last <Role>...</Role> and insert after it
            role_pattern = re.compile(r'(<Role>[^<]*</Role>)')
            matches = list(role_pattern.finditer(raw_text))
            new_role_tag = f'<Role>{role_name}</Role>'

            if matches:
                # Insert after last existing <Role>
                last_match = matches[-1]
                insert_pos = last_match.end()
                raw_text = raw_text[:insert_pos] + f'\n\t\t\t{new_role_tag}' + raw_text[insert_pos:]
            else:
                # No existing roles — insert before </ChildObjects>
                raw_text = raw_text.replace('</ChildObjects>', f'\t\t\t{new_role_tag}\n\t\t</ChildObjects>')

            write_utf8_bom(config_xml_path, raw_text)
            reg_result = 'added'
    else:
        reg_result = 'no-config'

    # --- 8. Summary ---
    print(f"[OK] Role '{role_name}' compiled")
    print(f"     UUID: {uid}")
    print(f"     Metadata: {metadata_path}")
    print(f"     Rights:   {rights_path}")
    print(f"     Objects: {len(parsed_objects)}, Rights: {total_rights}, Templates: {template_count}")
    if reg_result == 'added':
        print(f"     Configuration.xml: <Role>{role_name}</Role> added to ChildObjects")
    elif reg_result == 'already':
        print(f"     Configuration.xml: <Role>{role_name}</Role> already registered")
    elif reg_result == 'no-childobj':
        print(f"WARNING: Configuration.xml found but <ChildObjects> not found", file=sys.stderr)
    elif reg_result == 'no-config':
        print(f"WARNING: Configuration.xml not found at {config_xml_path} -- register manually", file=sys.stderr)


if __name__ == '__main__':
    main()
