#!/usr/bin/env python3
# meta-compile v1.3 — Compile 1C metadata object from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# ---------------------------------------------------------------------------
# Inline utilities
# ---------------------------------------------------------------------------

def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')

def new_uuid():
    return str(uuid.uuid4())

def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)

# ---------------------------------------------------------------------------
# XML builder (lines list)
# ---------------------------------------------------------------------------

lines = []

def X(text):
    lines.append(text)

def emit_mltext(indent, tag, text):
    if not text:
        X(f'{indent}<{tag}/>')
        return
    X(f'{indent}<{tag}>')
    X(f'{indent}\t<v8:item>')
    X(f'{indent}\t\t<v8:lang>ru</v8:lang>')
    X(f'{indent}\t\t<v8:content>{esc_xml(text)}</v8:content>')
    X(f'{indent}\t</v8:item>')
    X(f'{indent}</{tag}>')

# ---------------------------------------------------------------------------
# CamelCase splitter
# ---------------------------------------------------------------------------

def split_camel_case(name):
    if not name:
        return name
    result = re.sub(r'([а-яё])([А-ЯЁ])', r'\1 \2', name)
    result = re.sub(r'([a-z])([A-Z])', r'\1 \2', result)
    if len(result) > 1:
        result = result[0] + result[1:].lower()
    return result

# ---------------------------------------------------------------------------
# 1. Load and validate JSON
# ---------------------------------------------------------------------------

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('-JsonPath', required=True)
parser.add_argument('-OutputDir', required=True)
args = parser.parse_args()

json_path = args.JsonPath
output_dir = args.OutputDir

if not os.path.isfile(json_path):
    print(f'File not found: {json_path}', file=sys.stderr)
    sys.exit(1)

with open(json_path, 'r', encoding='utf-8-sig') as f:
    json_text = f.read()

defn = json.loads(json_text)

# --- Batch mode: JSON array of objects ---
if isinstance(defn, list):
    batch_ok = 0
    batch_fail = 0
    for idx, item in enumerate(defn, 1):
        tmp_fd, tmp_path = tempfile.mkstemp(suffix='.json', prefix=f'meta-compile-batch-{idx}-')
        try:
            with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
                json.dump(item, f, ensure_ascii=False, indent=2)
            rc = subprocess.call([sys.executable, __file__, '-JsonPath', tmp_path, '-OutputDir', output_dir])
            if rc == 0:
                batch_ok += 1
            else:
                batch_fail += 1
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
    print()
    print(f"=== Batch: {len(defn)} objects, {batch_ok} compiled, {batch_fail} failed ===")
    sys.exit(1 if batch_fail > 0 else 0)

# Normalize field synonyms: accept "objectType" as alias for "type"
if not defn.get('type') and defn.get('objectType'):
    defn['type'] = defn['objectType']

# Object type synonyms (Russian -> English)
object_type_synonyms = {
    'Справочник': 'Catalog',
    'Каталог': 'Catalog',
    'Документ': 'Document',
    'Перечисление': 'Enum',
    'Константа': 'Constant',
    'РегистрСведений': 'InformationRegister',
    'РегистрНакопления': 'AccumulationRegister',
    'РегистрБухгалтерии': 'AccountingRegister',
    'РегистрРасчёта': 'CalculationRegister',
    'РегистрРасчета': 'CalculationRegister',
    'ПланСчетов': 'ChartOfAccounts',
    'ПланВидовХарактеристик': 'ChartOfCharacteristicTypes',
    'ПланВидовРасчёта': 'ChartOfCalculationTypes',
    'ПланВидовРасчета': 'ChartOfCalculationTypes',
    'БизнесПроцесс': 'BusinessProcess',
    'Задача': 'Task',
    'ПланОбмена': 'ExchangePlan',
    'ЖурналДокументов': 'DocumentJournal',
    'Отчёт': 'Report',
    'Отчет': 'Report',
    'Обработка': 'DataProcessor',
    'ОбщийМодуль': 'CommonModule',
    'РегламентноеЗадание': 'ScheduledJob',
    'ПодпискаНаСобытие': 'EventSubscription',
    'HTTPСервис': 'HTTPService',
    'ВебСервис': 'WebService',
    'ОпределяемыйТип': 'DefinedType',
}

if not defn.get('type'):
    print("JSON must have 'type' field", file=sys.stderr)
    sys.exit(1)

obj_type = str(defn['type'])
if obj_type in object_type_synonyms:
    obj_type = object_type_synonyms[obj_type]

valid_types = [
    'Catalog', 'Document', 'Enum', 'Constant', 'InformationRegister',
    'AccumulationRegister', 'AccountingRegister', 'CalculationRegister',
    'ChartOfAccounts', 'ChartOfCharacteristicTypes', 'ChartOfCalculationTypes',
    'BusinessProcess', 'Task', 'ExchangePlan', 'DocumentJournal',
    'Report', 'DataProcessor', 'CommonModule', 'ScheduledJob',
    'EventSubscription', 'HTTPService', 'WebService', 'DefinedType',
]
if obj_type not in valid_types:
    print(f"Unsupported type: {obj_type}. Valid: {', '.join(valid_types)}", file=sys.stderr)
    sys.exit(1)

if not defn.get('name'):
    print("JSON must have 'name' field", file=sys.stderr)
    sys.exit(1)

obj_name = str(defn['name'])

# Auto-synonym
synonym = str(defn['synonym']) if defn.get('synonym') else split_camel_case(obj_name)
comment = str(defn['comment']) if defn.get('comment') else ''

# ---------------------------------------------------------------------------
# 4. Type system
# ---------------------------------------------------------------------------

type_synonyms = {
    'число': 'Number',
    'строка': 'String',
    'булево': 'Boolean',
    'дата': 'Date',
    'датавремя': 'DateTime',
    'number': 'Number',
    'string': 'String',
    'boolean': 'Boolean',
    'date': 'Date',
    'datetime': 'DateTime',
    'bool': 'Boolean',
    # Reference synonyms (Russian, lowercase)
    'справочникссылка': 'CatalogRef',
    'документссылка': 'DocumentRef',
    'перечислениессылка': 'EnumRef',
    'плансчетовссылка': 'ChartOfAccountsRef',
    'планвидовхарактеристикссылка': 'ChartOfCharacteristicTypesRef',
    'планвидоврасчётассылка': 'ChartOfCalculationTypesRef',
    'планвидоврасчетассылка': 'ChartOfCalculationTypesRef',
    'планобменассылка': 'ExchangePlanRef',
    'бизнеспроцессссылка': 'BusinessProcessRef',
    'задачассылка': 'TaskRef',
    'определяемыйтип': 'DefinedType',
    'definedtype': 'DefinedType',
    # English lowercase ref synonyms
    'catalogref': 'CatalogRef',
    'documentref': 'DocumentRef',
    'enumref': 'EnumRef',
}

def resolve_type_str(type_str):
    if not type_str:
        return type_str
    # Parameterized types: Number(15,2), Строка(100), etc.
    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = type_synonyms.get(base_name.lower())
        if resolved:
            return f'{resolved}({params})'
        return type_str
    # Reference types: СправочникСсылка.Организации -> CatalogRef.Организации
    if '.' in type_str:
        dot_idx = type_str.index('.')
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]  # includes the dot
        resolved = type_synonyms.get(prefix.lower())
        if resolved:
            return f'{resolved}{suffix}'
        return type_str
    # Simple name lookup
    resolved = type_synonyms.get(type_str.lower())
    if resolved:
        return resolved
    return type_str

def emit_type_content(indent, type_str):
    if not type_str:
        return
    # Composite type: "Type1 + Type2 + Type3"
    if ' + ' in type_str:
        parts = [p.strip() for p in type_str.split('+')]
        for part in parts:
            emit_type_content(indent, part)
        return
    type_str = resolve_type_str(type_str)
    # Boolean
    if type_str == 'Boolean':
        X(f'{indent}<v8:Type>xs:boolean</v8:Type>')
        return
    # String or String(N)
    m = re.match(r'^String(\((\d+)\))?$', type_str)
    if m:
        length = m.group(2) if m.group(2) else '10'
        X(f'{indent}<v8:Type>xs:string</v8:Type>')
        X(f'{indent}<v8:StringQualifiers>')
        X(f'{indent}\t<v8:Length>{length}</v8:Length>')
        X(f'{indent}\t<v8:AllowedLength>Variable</v8:AllowedLength>')
        X(f'{indent}</v8:StringQualifiers>')
        return
    # Number without params -> Number(10,0)
    if type_str == 'Number':
        X(f'{indent}<v8:Type>xs:decimal</v8:Type>')
        X(f'{indent}<v8:NumberQualifiers>')
        X(f'{indent}\t<v8:Digits>10</v8:Digits>')
        X(f'{indent}\t<v8:FractionDigits>0</v8:FractionDigits>')
        X(f'{indent}\t<v8:AllowedSign>Any</v8:AllowedSign>')
        X(f'{indent}</v8:NumberQualifiers>')
        return

    # Number(D,F) or Number(D,F,nonneg)
    m = re.match(r'^Number\((\d+),(\d+)(,nonneg)?\)$', type_str)
    if m:
        digits = m.group(1)
        fraction = m.group(2)
        sign = 'Nonnegative' if m.group(3) else 'Any'
        X(f'{indent}<v8:Type>xs:decimal</v8:Type>')
        X(f'{indent}<v8:NumberQualifiers>')
        X(f'{indent}\t<v8:Digits>{digits}</v8:Digits>')
        X(f'{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>')
        X(f'{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>')
        X(f'{indent}</v8:NumberQualifiers>')
        return
    # Date / DateTime
    if type_str == 'Date':
        X(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
        X(f'{indent}<v8:DateQualifiers>')
        X(f'{indent}\t<v8:DateFractions>Date</v8:DateFractions>')
        X(f'{indent}</v8:DateQualifiers>')
        return
    if type_str == 'DateTime':
        X(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
        X(f'{indent}<v8:DateQualifiers>')
        X(f'{indent}\t<v8:DateFractions>DateTime</v8:DateFractions>')
        X(f'{indent}</v8:DateQualifiers>')
        return
    # DefinedType
    m = re.match(r'^DefinedType\.(.+)$', type_str)
    if m:
        dt_name = m.group(1)
        X(f'{indent}<v8:TypeSet>cfg:DefinedType.{dt_name}</v8:TypeSet>')
        return
    # ValueStorage
    if type_str == 'ValueStorage':
        X(f'{indent}<v8:Type>xs:base64Binary</v8:Type>')
        return

    # Reference types — use local xmlns declaration for 1C compatibility
    m = re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef)\.(.+)$', type_str)
    if m:
        X(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{type_str}</v8:Type>')
        return
    # Fallback
    X(f'{indent}<v8:Type>{type_str}</v8:Type>')

def emit_value_type(indent, type_str):
    X(f'{indent}<Type>')
    emit_type_content(f'{indent}\t', type_str)
    X(f'{indent}</Type>')

def emit_fill_value(indent, type_str):
    if not type_str:
        X(f'{indent}<FillValue xsi:nil="true"/>')
        return
    type_str = resolve_type_str(type_str)
    if type_str == 'Boolean':
        X(f'{indent}<FillValue xsi:type="xs:boolean">false</FillValue>')
        return
    if re.match(r'^String', type_str):
        X(f'{indent}<FillValue xsi:type="xs:string"/>')
        return
    if re.match(r'^Number', type_str):
        X(f'{indent}<FillValue xsi:type="xs:decimal">0</FillValue>')
        return
    if re.match(r'^(Date|DateTime)$', type_str):
        X(f'{indent}<FillValue xsi:nil="true"/>')
        return
    X(f'{indent}<FillValue xsi:nil="true"/>')

# ---------------------------------------------------------------------------
# 5. Attribute shorthand parser
# ---------------------------------------------------------------------------

def build_type_str(obj):
    t = str(obj.get('valueType') or obj.get('type') or '')
    if t and '(' not in t:
        if t == 'String' and obj.get('length'):
            t = f"String({obj['length']})"
        elif t == 'Number' and obj.get('length'):
            prec = obj.get('precision', 0)
            nn = ',nonneg' if obj.get('nonneg') or obj.get('nonnegative') else ''
            t = f"Number({obj['length']},{prec}{nn})"
    return t

def parse_attribute_shorthand(val):
    if isinstance(val, str):
        parsed = {
            'name': '',
            'type': '',
            'synonym': '',
            'comment': '',
            'flags': [],
            'fillChecking': '',
            'indexing': '',
        }
        parts = val.split('|', 1)
        main_part = parts[0].strip()
        if len(parts) > 1:
            flag_str = parts[1].strip()
            parsed['flags'] = [f.strip().lower() for f in flag_str.split(',') if f.strip()]
        colon_parts = main_part.split(':', 1)
        parsed['name'] = colon_parts[0].strip()
        if len(colon_parts) > 1:
            parsed['type'] = colon_parts[1].strip()
        parsed['synonym'] = split_camel_case(parsed['name'])
        return parsed
    # Object form
    name = str(val.get('name', ''))
    return {
        'name': name,
        'type': build_type_str(val),
        'synonym': str(val['synonym']) if val.get('synonym') else split_camel_case(name),
        'comment': str(val['comment']) if val.get('comment') else '',
        'flags': list(val.get('flags', [])),
        'fillChecking': str(val['fillChecking']) if val.get('fillChecking') else '',
        'indexing': str(val['indexing']) if val.get('indexing') else '',
    }

def parse_enum_value_shorthand(val):
    if isinstance(val, str):
        return {
            'name': val,
            'synonym': split_camel_case(val),
            'comment': '',
        }
    name = str(val.get('name', ''))
    return {
        'name': name,
        'synonym': str(val['synonym']) if val.get('synonym') else split_camel_case(name),
        'comment': str(val['comment']) if val.get('comment') else '',
    }

# ---------------------------------------------------------------------------
# 6. GeneratedType categories
# ---------------------------------------------------------------------------

generated_types = {
    'Catalog': [
        {'prefix': 'CatalogObject', 'category': 'Object'},
        {'prefix': 'CatalogRef', 'category': 'Ref'},
        {'prefix': 'CatalogSelection', 'category': 'Selection'},
        {'prefix': 'CatalogList', 'category': 'List'},
        {'prefix': 'CatalogManager', 'category': 'Manager'},
    ],
    'Document': [
        {'prefix': 'DocumentObject', 'category': 'Object'},
        {'prefix': 'DocumentRef', 'category': 'Ref'},
        {'prefix': 'DocumentSelection', 'category': 'Selection'},
        {'prefix': 'DocumentList', 'category': 'List'},
        {'prefix': 'DocumentManager', 'category': 'Manager'},
    ],
    'Enum': [
        {'prefix': 'EnumRef', 'category': 'Ref'},
        {'prefix': 'EnumManager', 'category': 'Manager'},
        {'prefix': 'EnumList', 'category': 'List'},
    ],
    'Constant': [
        {'prefix': 'ConstantManager', 'category': 'Manager'},
        {'prefix': 'ConstantValueManager', 'category': 'ValueManager'},
        {'prefix': 'ConstantValueKey', 'category': 'ValueKey'},
    ],
    'InformationRegister': [
        {'prefix': 'InformationRegisterRecord', 'category': 'Record'},
        {'prefix': 'InformationRegisterManager', 'category': 'Manager'},
        {'prefix': 'InformationRegisterSelection', 'category': 'Selection'},
        {'prefix': 'InformationRegisterList', 'category': 'List'},
        {'prefix': 'InformationRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'InformationRegisterRecordKey', 'category': 'RecordKey'},
        {'prefix': 'InformationRegisterRecordManager', 'category': 'RecordManager'},
    ],
    'AccumulationRegister': [
        {'prefix': 'AccumulationRegisterRecord', 'category': 'Record'},
        {'prefix': 'AccumulationRegisterManager', 'category': 'Manager'},
        {'prefix': 'AccumulationRegisterSelection', 'category': 'Selection'},
        {'prefix': 'AccumulationRegisterList', 'category': 'List'},
        {'prefix': 'AccumulationRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'AccumulationRegisterRecordKey', 'category': 'RecordKey'},
    ],
    'AccountingRegister': [
        {'prefix': 'AccountingRegisterRecord', 'category': 'Record'},
        {'prefix': 'AccountingRegisterExtDimensions', 'category': 'ExtDimensions'},
        {'prefix': 'AccountingRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'AccountingRegisterRecordKey', 'category': 'RecordKey'},
        {'prefix': 'AccountingRegisterSelection', 'category': 'Selection'},
        {'prefix': 'AccountingRegisterList', 'category': 'List'},
        {'prefix': 'AccountingRegisterManager', 'category': 'Manager'},
    ],
    'CalculationRegister': [
        {'prefix': 'CalculationRegisterRecord', 'category': 'Record'},
        {'prefix': 'CalculationRegisterManager', 'category': 'Manager'},
        {'prefix': 'CalculationRegisterSelection', 'category': 'Selection'},
        {'prefix': 'CalculationRegisterList', 'category': 'List'},
        {'prefix': 'CalculationRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'CalculationRegisterRecordKey', 'category': 'RecordKey'},
        {'prefix': 'RecalculationsManager', 'category': 'Recalcs'},
    ],
    'ChartOfAccounts': [
        {'prefix': 'ChartOfAccountsObject', 'category': 'Object'},
        {'prefix': 'ChartOfAccountsRef', 'category': 'Ref'},
        {'prefix': 'ChartOfAccountsSelection', 'category': 'Selection'},
        {'prefix': 'ChartOfAccountsList', 'category': 'List'},
        {'prefix': 'ChartOfAccountsManager', 'category': 'Manager'},
        {'prefix': 'ChartOfAccountsExtDimensionTypes', 'category': 'ExtDimensionTypes'},
        {'prefix': 'ChartOfAccountsExtDimensionTypesRow', 'category': 'ExtDimensionTypesRow'},
    ],
    'ChartOfCharacteristicTypes': [
        {'prefix': 'ChartOfCharacteristicTypesObject', 'category': 'Object'},
        {'prefix': 'ChartOfCharacteristicTypesRef', 'category': 'Ref'},
        {'prefix': 'ChartOfCharacteristicTypesSelection', 'category': 'Selection'},
        {'prefix': 'ChartOfCharacteristicTypesList', 'category': 'List'},
        {'prefix': 'ChartOfCharacteristicTypesCharacteristic', 'category': 'Characteristic'},
        {'prefix': 'ChartOfCharacteristicTypesManager', 'category': 'Manager'},
    ],
    'ChartOfCalculationTypes': [
        {'prefix': 'ChartOfCalculationTypesObject', 'category': 'Object'},
        {'prefix': 'ChartOfCalculationTypesRef', 'category': 'Ref'},
        {'prefix': 'ChartOfCalculationTypesSelection', 'category': 'Selection'},
        {'prefix': 'ChartOfCalculationTypesList', 'category': 'List'},
        {'prefix': 'ChartOfCalculationTypesManager', 'category': 'Manager'},
        {'prefix': 'DisplacingCalculationTypes', 'category': 'DisplacingCalculationTypes'},
        {'prefix': 'DisplacingCalculationTypesRow', 'category': 'DisplacingCalculationTypesRow'},
        {'prefix': 'BaseCalculationTypes', 'category': 'BaseCalculationTypes'},
        {'prefix': 'BaseCalculationTypesRow', 'category': 'BaseCalculationTypesRow'},
        {'prefix': 'LeadingCalculationTypes', 'category': 'LeadingCalculationTypes'},
        {'prefix': 'LeadingCalculationTypesRow', 'category': 'LeadingCalculationTypesRow'},
    ],
    'BusinessProcess': [
        {'prefix': 'BusinessProcessObject', 'category': 'Object'},
        {'prefix': 'BusinessProcessRef', 'category': 'Ref'},
        {'prefix': 'BusinessProcessSelection', 'category': 'Selection'},
        {'prefix': 'BusinessProcessList', 'category': 'List'},
        {'prefix': 'BusinessProcessManager', 'category': 'Manager'},
        {'prefix': 'BusinessProcessRoutePointRef', 'category': 'RoutePointRef'},
    ],
    'Task': [
        {'prefix': 'TaskObject', 'category': 'Object'},
        {'prefix': 'TaskRef', 'category': 'Ref'},
        {'prefix': 'TaskSelection', 'category': 'Selection'},
        {'prefix': 'TaskList', 'category': 'List'},
        {'prefix': 'TaskManager', 'category': 'Manager'},
    ],
    'ExchangePlan': [
        {'prefix': 'ExchangePlanObject', 'category': 'Object'},
        {'prefix': 'ExchangePlanRef', 'category': 'Ref'},
        {'prefix': 'ExchangePlanSelection', 'category': 'Selection'},
        {'prefix': 'ExchangePlanList', 'category': 'List'},
        {'prefix': 'ExchangePlanManager', 'category': 'Manager'},
    ],
    'DefinedType': [
        {'prefix': 'DefinedType', 'category': 'DefinedType'},
    ],
    'DocumentJournal': [
        {'prefix': 'DocumentJournalSelection', 'category': 'Selection'},
        {'prefix': 'DocumentJournalList', 'category': 'List'},
        {'prefix': 'DocumentJournalManager', 'category': 'Manager'},
    ],
    'Report': [
        {'prefix': 'ReportObject', 'category': 'Object'},
        {'prefix': 'ReportManager', 'category': 'Manager'},
    ],
    'DataProcessor': [
        {'prefix': 'DataProcessorObject', 'category': 'Object'},
        {'prefix': 'DataProcessorManager', 'category': 'Manager'},
    ],
}

def emit_internal_info(indent, object_type, object_name):
    types = generated_types.get(object_type)
    if not types:
        return
    X(f'{indent}<InternalInfo>')
    if object_type == 'ExchangePlan':
        X(f'{indent}\t<xr:ThisNode>{new_uuid()}</xr:ThisNode>')
    for gt in types:
        full_name = f"{gt['prefix']}.{object_name}"
        X(f'{indent}\t<xr:GeneratedType name="{full_name}" category="{gt["category"]}">')
        X(f'{indent}\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
        X(f'{indent}\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
        X(f'{indent}\t</xr:GeneratedType>')
    X(f'{indent}</InternalInfo>')

# ---------------------------------------------------------------------------
# 7. StandardAttributes
# ---------------------------------------------------------------------------

standard_attributes_by_type = {
    'Catalog': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'IsFolder', 'Owner', 'Parent', 'Description', 'Code'],
    'Document': ['Posted', 'Ref', 'DeletionMark', 'Date', 'Number'],
    'Enum': ['Order', 'Ref'],
    'InformationRegister': ['Active', 'LineNumber', 'Recorder', 'Period'],
    'AccumulationRegister': ['Active', 'LineNumber', 'Recorder', 'Period'],
    'AccountingRegister': ['Active', 'Period', 'Recorder', 'LineNumber', 'Account'],
    'CalculationRegister': ['Active', 'Recorder', 'LineNumber', 'RegistrationPeriod', 'CalculationType', 'ReversingEntry'],
    'ChartOfAccounts': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'Description', 'Code', 'Parent', 'Order', 'Type', 'OffBalance'],
    'ChartOfCharacteristicTypes': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'Description', 'Code', 'Parent', 'ValueType'],
    'ChartOfCalculationTypes': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'Description', 'Code', 'ActionPeriodIsBasic'],
    'BusinessProcess': ['Ref', 'DeletionMark', 'Date', 'Number', 'Started', 'Completed', 'HeadTask'],
    'Task': ['Ref', 'DeletionMark', 'Date', 'Number', 'Executed', 'Description', 'RoutePoint', 'BusinessProcess'],
    'ExchangePlan': ['Ref', 'DeletionMark', 'Code', 'Description', 'ThisNode', 'SentNo', 'ReceivedNo'],
    'DocumentJournal': ['Type', 'Ref', 'Date', 'Posted', 'DeletionMark', 'Number'],
}

def emit_standard_attribute(indent, attr_name):
    X(f'{indent}<xr:StandardAttribute name="{attr_name}">')
    X(f'{indent}\t<xr:LinkByType/>')
    X(f'{indent}\t<xr:FillChecking>DontCheck</xr:FillChecking>')
    X(f'{indent}\t<xr:MultiLine>false</xr:MultiLine>')
    X(f'{indent}\t<xr:FillFromFillingValue>false</xr:FillFromFillingValue>')
    X(f'{indent}\t<xr:CreateOnInput>Auto</xr:CreateOnInput>')
    X(f'{indent}\t<xr:MaxValue xsi:nil="true"/>')
    X(f'{indent}\t<xr:ToolTip/>')
    X(f'{indent}\t<xr:ExtendedEdit>false</xr:ExtendedEdit>')
    X(f'{indent}\t<xr:Format/>')
    X(f'{indent}\t<xr:ChoiceForm/>')
    X(f'{indent}\t<xr:QuickChoice>Auto</xr:QuickChoice>')
    X(f'{indent}\t<xr:ChoiceHistoryOnInput>Auto</xr:ChoiceHistoryOnInput>')
    X(f'{indent}\t<xr:EditFormat/>')
    X(f'{indent}\t<xr:PasswordMode>false</xr:PasswordMode>')
    X(f'{indent}\t<xr:DataHistory>Use</xr:DataHistory>')
    X(f'{indent}\t<xr:MarkNegatives>false</xr:MarkNegatives>')
    X(f'{indent}\t<xr:MinValue xsi:nil="true"/>')
    X(f'{indent}\t<xr:Synonym/>')
    X(f'{indent}\t<xr:Comment/>')
    X(f'{indent}\t<xr:FullTextSearch>Use</xr:FullTextSearch>')
    X(f'{indent}\t<xr:ChoiceParameterLinks/>')
    X(f'{indent}\t<xr:FillValue xsi:nil="true"/>')
    X(f'{indent}\t<xr:Mask/>')
    X(f'{indent}\t<xr:ChoiceParameters/>')
    X(f'{indent}</xr:StandardAttribute>')

def emit_standard_attributes(indent, object_type):
    attrs = standard_attributes_by_type.get(object_type)
    if not attrs:
        return
    X(f'{indent}<StandardAttributes>')
    for a in attrs:
        emit_standard_attribute(f'{indent}\t', a)
    X(f'{indent}</StandardAttributes>')

def emit_tabular_standard_attributes(indent):
    X(f'{indent}<StandardAttributes>')
    emit_standard_attribute(f'{indent}\t', 'LineNumber')
    X(f'{indent}</StandardAttributes>')

# ---------------------------------------------------------------------------
# 8. Attribute emitter
# ---------------------------------------------------------------------------

RESERVED_ATTR_NAMES = {
    'Ref', 'DeletionMark', 'Code', 'Description', 'Date', 'Number', 'Posted',
    'Parent', 'Owner', 'IsFolder', 'Predefined', 'PredefinedDataName',
    'Recorder', 'Period', 'LineNumber', 'Active', 'Order', 'Type', 'OffBalance',
    'Started', 'Completed', 'HeadTask', 'Executed', 'RoutePoint', 'BusinessProcess',
    'ThisNode', 'SentNo', 'ReceivedNo', 'CalculationType', 'RegistrationPeriod',
    'ReversingEntry', 'Account', 'ValueType', 'ActionPeriodIsBasic',
}
RESERVED_ATTR_NAMES_RU = {
    '\u0421\u0441\u044b\u043b\u043a\u0430', '\u041f\u043e\u043c\u0435\u0442\u043a\u0430\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u044f',
    '\u041a\u043e\u0434', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435',
    '\u0414\u0430\u0442\u0430', '\u041d\u043e\u043c\u0435\u0440', '\u041f\u0440\u043e\u0432\u0435\u0434\u0435\u043d',
    '\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c', '\u0412\u043b\u0430\u0434\u0435\u043b\u0435\u0446',
    '\u042d\u0442\u043e\u0413\u0440\u0443\u043f\u043f\u0430', '\u041f\u0440\u0435\u0434\u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u043d\u044b\u0439',
    '\u0418\u043c\u044f\u041f\u0440\u0435\u0434\u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u043d\u044b\u0445\u0414\u0430\u043d\u043d\u044b\u0445',
    '\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440', '\u041f\u0435\u0440\u0438\u043e\u0434',
    '\u041d\u043e\u043c\u0435\u0440\u0421\u0442\u0440\u043e\u043a\u0438', '\u0410\u043a\u0442\u0438\u0432\u043d\u043e\u0441\u0442\u044c',
    '\u041f\u043e\u0440\u044f\u0434\u043e\u043a', '\u0422\u0438\u043f', '\u0417\u0430\u0431\u0430\u043b\u0430\u043d\u0441\u043e\u0432\u044b\u0439',
    '\u0421\u0442\u0430\u0440\u0442\u043e\u0432\u0430\u043d', '\u0417\u0430\u0432\u0435\u0440\u0448\u0435\u043d',
    '\u0412\u0435\u0434\u0443\u0449\u0430\u044f\u0417\u0430\u0434\u0430\u0447\u0430',
    '\u0412\u044b\u043f\u043e\u043b\u043d\u0435\u043d\u0430', '\u0422\u043e\u0447\u043a\u0430\u041c\u0430\u0440\u0448\u0440\u0443\u0442\u0430',
    '\u0411\u0438\u0437\u043d\u0435\u0441\u041f\u0440\u043e\u0446\u0435\u0441\u0441',
    '\u042d\u0442\u043e\u0442\u0423\u0437\u0435\u043b', '\u041d\u043e\u043c\u0435\u0440\u041e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043d\u043e\u0433\u043e',
    '\u041d\u043e\u043c\u0435\u0440\u041f\u0440\u0438\u043d\u044f\u0442\u043e\u0433\u043e',
    '\u0412\u0438\u0434\u0420\u0430\u0441\u0447\u0435\u0442\u0430', '\u041f\u0435\u0440\u0438\u043e\u0434\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u0438',
    '\u0421\u0442\u043e\u0440\u043d\u043e\u0417\u0430\u043f\u0438\u0441\u044c',
    '\u0421\u0447\u0435\u0442', '\u0422\u0438\u043f\u0417\u043d\u0430\u0447\u0435\u043d\u0438\u044f',
    '\u041f\u0435\u0440\u0438\u043e\u0434\u0414\u0435\u0439\u0441\u0442\u0432\u0438\u044f\u0411\u0430\u0437\u043e\u0432\u044b\u0439',
}

def emit_attribute(indent, parsed, context):
    attr_name = parsed['name']
    if attr_name in RESERVED_ATTR_NAMES or attr_name in RESERVED_ATTR_NAMES_RU:
        print(f"WARNING: Attribute '{attr_name}' conflicts with a standard attribute name. This may cause errors when loading into 1C.", file=sys.stderr)
    uid = new_uuid()
    X(f'{indent}<Attribute uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    X(f'{indent}\t\t<Comment/>')
    type_str = parsed['type']
    if type_str:
        emit_value_type(f'{indent}\t\t', type_str)
    else:
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:string</v8:Type>')
        X(f'{indent}\t\t</Type>')
    X(f'{indent}\t\t<PasswordMode>false</PasswordMode>')
    X(f'{indent}\t\t<Format/>')
    X(f'{indent}\t\t<EditFormat/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<MarkNegatives>false</MarkNegatives>')
    X(f'{indent}\t\t<Mask/>')
    X(f'{indent}\t\t<MultiLine>false</MultiLine>')
    X(f'{indent}\t\t<ExtendedEdit>false</ExtendedEdit>')
    X(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    X(f'{indent}\t\t<MaxValue xsi:nil="true"/>')
    if context not in ('tabular', 'processor'):
        X(f'{indent}\t\t<FillFromFillingValue>false</FillFromFillingValue>')
    if context not in ('tabular', 'processor'):
        emit_fill_value(f'{indent}\t\t', type_str)
    fill_checking = 'DontCheck'
    if 'req' in parsed.get('flags', []):
        fill_checking = 'ShowError'
    if parsed.get('fillChecking'):
        fill_checking = parsed['fillChecking']
    X(f'{indent}\t\t<FillChecking>{fill_checking}</FillChecking>')
    X(f'{indent}\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>')
    X(f'{indent}\t\t<ChoiceParameterLinks/>')
    X(f'{indent}\t\t<ChoiceParameters/>')
    X(f'{indent}\t\t<QuickChoice>Auto</QuickChoice>')
    X(f'{indent}\t\t<CreateOnInput>Auto</CreateOnInput>')
    X(f'{indent}\t\t<ChoiceForm/>')
    X(f'{indent}\t\t<LinkByType/>')
    X(f'{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    if context == 'catalog':
        X(f'{indent}\t\t<Use>ForItem</Use>')
    if context not in ('processor', 'processor-tabular'):
        indexing = 'DontIndex'
        if 'index' in parsed.get('flags', []):
            indexing = 'Index'
        if 'indexadditional' in parsed.get('flags', []):
            indexing = 'IndexWithAdditionalOrder'
        if parsed.get('indexing'):
            indexing = parsed['indexing']
        X(f'{indent}\t\t<Indexing>{indexing}</Indexing>')
        X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
        X(f'{indent}\t\t<DataHistory>Use</DataHistory>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Attribute>')

# ---------------------------------------------------------------------------
# 9. TabularSection emitter
# ---------------------------------------------------------------------------

def emit_tabular_section(indent, ts_name, columns, object_type, object_name):
    uid = new_uuid()
    X(f'{indent}<TabularSection uuid="{uid}">')
    type_prefix = f'{object_type}TabularSection'
    row_prefix = f'{object_type}TabularSectionRow'
    X(f'{indent}\t<InternalInfo>')
    X(f'{indent}\t\t<xr:GeneratedType name="{type_prefix}.{object_name}.{ts_name}" category="TabularSection">')
    X(f'{indent}\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
    X(f'{indent}\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
    X(f'{indent}\t\t</xr:GeneratedType>')
    X(f'{indent}\t\t<xr:GeneratedType name="{row_prefix}.{object_name}.{ts_name}" category="TabularSectionRow">')
    X(f'{indent}\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
    X(f'{indent}\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
    X(f'{indent}\t\t</xr:GeneratedType>')
    X(f'{indent}\t</InternalInfo>')
    ts_synonym = split_camel_case(ts_name)
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(ts_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', ts_synonym)
    X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<FillChecking>DontCheck</FillChecking>')
    emit_tabular_standard_attributes(f'{indent}\t\t')
    if object_type == 'Catalog':
        X(f'{indent}\t\t<Use>ForItem</Use>')
    X(f'{indent}\t</Properties>')
    ts_context = 'processor-tabular' if object_type in ('DataProcessor', 'Report') else 'tabular'
    X(f'{indent}\t<ChildObjects>')
    for col in columns:
        parsed = parse_attribute_shorthand(col)
        emit_attribute(f'{indent}\t\t', parsed, ts_context)
    X(f'{indent}\t</ChildObjects>')
    X(f'{indent}</TabularSection>')

# ---------------------------------------------------------------------------
# 10. EnumValue emitter
# ---------------------------------------------------------------------------

def emit_enum_value(indent, parsed):
    uid = new_uuid()
    X(f'{indent}<EnumValue uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</EnumValue>')

# ---------------------------------------------------------------------------
# 11. Dimension emitter
# ---------------------------------------------------------------------------

def emit_dimension(indent, parsed, register_type):
    uid = new_uuid()
    X(f'{indent}<Dimension uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    X(f'{indent}\t\t<Comment/>')
    type_str = parsed['type']
    if type_str:
        emit_value_type(f'{indent}\t\t', type_str)
    else:
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:string</v8:Type>')
        X(f'{indent}\t\t</Type>')
    X(f'{indent}\t\t<PasswordMode>false</PasswordMode>')
    X(f'{indent}\t\t<Format/>')
    X(f'{indent}\t\t<EditFormat/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<MarkNegatives>false</MarkNegatives>')
    X(f'{indent}\t\t<Mask/>')
    X(f'{indent}\t\t<MultiLine>false</MultiLine>')
    X(f'{indent}\t\t<ExtendedEdit>false</ExtendedEdit>')
    X(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    X(f'{indent}\t\t<MaxValue xsi:nil="true"/>')
    flags = parsed.get('flags', [])
    if register_type == 'InformationRegister':
        fill_from = 'true' if 'master' in flags else 'false'
        X(f'{indent}\t\t<FillFromFillingValue>{fill_from}</FillFromFillingValue>')
        X(f'{indent}\t\t<FillValue xsi:nil="true"/>')
    fill_checking = 'DontCheck'
    if 'req' in flags:
        fill_checking = 'ShowError'
    X(f'{indent}\t\t<FillChecking>{fill_checking}</FillChecking>')
    X(f'{indent}\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>')
    X(f'{indent}\t\t<ChoiceParameterLinks/>')
    X(f'{indent}\t\t<ChoiceParameters/>')
    X(f'{indent}\t\t<QuickChoice>Auto</QuickChoice>')
    X(f'{indent}\t\t<CreateOnInput>Auto</CreateOnInput>')
    X(f'{indent}\t\t<ChoiceForm/>')
    X(f'{indent}\t\t<LinkByType/>')
    X(f'{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    if register_type == 'InformationRegister':
        master = 'true' if 'master' in flags else 'false'
        main_filter = 'true' if 'mainfilter' in flags else 'false'
        deny_incomplete = 'true' if 'denyincomplete' in flags else 'false'
        X(f'{indent}\t\t<Master>{master}</Master>')
        X(f'{indent}\t\t<MainFilter>{main_filter}</MainFilter>')
        X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
    if register_type == 'AccumulationRegister':
        deny_incomplete = 'true' if 'denyincomplete' in flags else 'false'
        X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
    indexing = 'DontIndex'
    if 'index' in flags:
        indexing = 'Index'
    X(f'{indent}\t\t<Indexing>{indexing}</Indexing>')
    X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
    if register_type == 'AccumulationRegister':
        use_in_totals = 'false' if 'nouseintotals' in flags else 'true'
        X(f'{indent}\t\t<UseInTotals>{use_in_totals}</UseInTotals>')
    if register_type == 'InformationRegister':
        X(f'{indent}\t\t<DataHistory>Use</DataHistory>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Dimension>')

# ---------------------------------------------------------------------------
# 12. Resource emitter
# ---------------------------------------------------------------------------

def emit_resource(indent, parsed, register_type):
    uid = new_uuid()
    X(f'{indent}<Resource uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    X(f'{indent}\t\t<Comment/>')
    type_str = parsed['type']
    if type_str:
        emit_value_type(f'{indent}\t\t', type_str)
    else:
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:decimal</v8:Type>')
        X(f'{indent}\t\t\t<v8:NumberQualifiers>')
        X(f'{indent}\t\t\t\t<v8:Digits>15</v8:Digits>')
        X(f'{indent}\t\t\t\t<v8:FractionDigits>2</v8:FractionDigits>')
        X(f'{indent}\t\t\t\t<v8:AllowedSign>Any</v8:AllowedSign>')
        X(f'{indent}\t\t\t</v8:NumberQualifiers>')
        X(f'{indent}\t\t</Type>')
    X(f'{indent}\t\t<PasswordMode>false</PasswordMode>')
    X(f'{indent}\t\t<Format/>')
    X(f'{indent}\t\t<EditFormat/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<MarkNegatives>false</MarkNegatives>')
    X(f'{indent}\t\t<Mask/>')
    X(f'{indent}\t\t<MultiLine>false</MultiLine>')
    X(f'{indent}\t\t<ExtendedEdit>false</ExtendedEdit>')
    X(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    X(f'{indent}\t\t<MaxValue xsi:nil="true"/>')
    if register_type == 'InformationRegister':
        X(f'{indent}\t\t<FillFromFillingValue>false</FillFromFillingValue>')
        X(f'{indent}\t\t<FillValue xsi:nil="true"/>')
    flags = parsed.get('flags', [])
    fill_checking = 'DontCheck'
    if 'req' in flags:
        fill_checking = 'ShowError'
    X(f'{indent}\t\t<FillChecking>{fill_checking}</FillChecking>')
    X(f'{indent}\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>')
    X(f'{indent}\t\t<ChoiceParameterLinks/>')
    X(f'{indent}\t\t<ChoiceParameters/>')
    X(f'{indent}\t\t<QuickChoice>Auto</QuickChoice>')
    X(f'{indent}\t\t<CreateOnInput>Auto</CreateOnInput>')
    X(f'{indent}\t\t<ChoiceForm/>')
    X(f'{indent}\t\t<LinkByType/>')
    X(f'{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    if register_type == 'InformationRegister':
        X(f'{indent}\t\t<Indexing>DontIndex</Indexing>')
        X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
        X(f'{indent}\t\t<DataHistory>Use</DataHistory>')
    if register_type == 'AccumulationRegister':
        X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Resource>')

# ---------------------------------------------------------------------------
# 13. Property emitters per type
# ---------------------------------------------------------------------------

def emit_catalog_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    hierarchical = 'true' if defn.get('hierarchical') is True else 'false'
    hierarchy_type = str(defn['hierarchyType']) if defn.get('hierarchyType') else 'HierarchyFoldersAndItems'
    X(f'{i}<Hierarchical>{hierarchical}</Hierarchical>')
    X(f'{i}<HierarchyType>{hierarchy_type}</HierarchyType>')
    X(f'{i}<LimitLevelCount>false</LimitLevelCount>')
    X(f'{i}<LevelCount>2</LevelCount>')
    X(f'{i}<FoldersOnTop>true</FoldersOnTop>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    X(f'{i}<Owners/>')
    X(f'{i}<SubordinationUse>ToItems</SubordinationUse>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '25'
    code_type = str(defn['codeType']) if defn.get('codeType') else 'String'
    code_allowed_length = str(defn['codeAllowedLength']) if defn.get('codeAllowedLength') else 'Variable'
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    check_unique = 'true' if defn.get('checkUnique') is True else 'false'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<CodeType>{code_type}</CodeType>')
    X(f'{i}<CodeAllowedLength>{code_allowed_length}</CodeAllowedLength>')
    X(f'{i}<CodeSeries>WholeCatalog</CodeSeries>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    default_presentation = str(defn['defaultPresentation']) if defn.get('defaultPresentation') else 'AsDescription'
    X(f'{i}<DefaultPresentation>{default_presentation}</DefaultPresentation>')
    emit_standard_attributes(i, 'Catalog')
    X(f'{i}<Characteristics/>')
    X(f'{i}<PredefinedDataUpdate>Auto</PredefinedDataUpdate>')
    X(f'{i}<EditType>InDialog</EditType>')
    X(f'{i}<QuickChoice>true</QuickChoice>')
    X(f'{i}<ChoiceMode>BothWays</ChoiceMode>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>Catalog.{obj_name}.StandardAttribute.Description</xr:Field>')
    X(f'{i}\t<xr:Field>Catalog.{obj_name}.StandardAttribute.Code</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultFolderForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<DefaultFolderChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryFolderForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<AuxiliaryFolderChoiceForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_document_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    X(f'{i}<Numerator/>')
    number_type = str(defn['numberType']) if defn.get('numberType') else 'String'
    number_length = str(defn['numberLength']) if defn.get('numberLength') is not None else '11'
    number_allowed_length = str(defn['numberAllowedLength']) if defn.get('numberAllowedLength') else 'Variable'
    number_periodicity = str(defn['numberPeriodicity']) if defn.get('numberPeriodicity') else 'Year'
    check_unique = 'false' if defn.get('checkUnique') is False else 'true'
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    X(f'{i}<NumberType>{number_type}</NumberType>')
    X(f'{i}<NumberLength>{number_length}</NumberLength>')
    X(f'{i}<NumberAllowedLength>{number_allowed_length}</NumberAllowedLength>')
    X(f'{i}<NumberPeriodicity>{number_periodicity}</NumberPeriodicity>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    emit_standard_attributes(i, 'Document')
    X(f'{i}<Characteristics/>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>Document.{obj_name}.StandardAttribute.Number</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    posting = str(defn['posting']) if defn.get('posting') else 'Allow'
    real_time_posting = str(defn['realTimePosting']) if defn.get('realTimePosting') else 'Deny'
    reg_records_deletion = str(defn['registerRecordsDeletion']) if defn.get('registerRecordsDeletion') else 'AutoDelete'
    reg_records_writing = str(defn['registerRecordsWritingOnPost']) if defn.get('registerRecordsWritingOnPost') else 'WriteModified'
    sequence_filling = str(defn['sequenceFilling']) if defn.get('sequenceFilling') else 'AutoFill'
    post_in_priv = 'false' if defn.get('postInPrivilegedMode') is False else 'true'
    unpost_in_priv = 'false' if defn.get('unpostInPrivilegedMode') is False else 'true'
    X(f'{i}<Posting>{posting}</Posting>')
    X(f'{i}<RealTimePosting>{real_time_posting}</RealTimePosting>')
    X(f'{i}<RegisterRecordsDeletion>{reg_records_deletion}</RegisterRecordsDeletion>')
    X(f'{i}<RegisterRecordsWritingOnPost>{reg_records_writing}</RegisterRecordsWritingOnPost>')
    X(f'{i}<SequenceFilling>{sequence_filling}</SequenceFilling>')
    # RegisterRecords
    reg_records = []
    if defn.get('registerRecords'):
        for rr in defn['registerRecords']:
            rr_str = str(rr)
            if '.' in rr_str:
                dot_idx = rr_str.index('.')
                rr_prefix = rr_str[:dot_idx]
                rr_suffix = rr_str[dot_idx + 1:]
                if rr_prefix in object_type_synonyms:
                    rr_prefix = object_type_synonyms[rr_prefix]
                reg_records.append(f'{rr_prefix}.{rr_suffix}')
            else:
                reg_records.append(rr_str)
    if reg_records:
        X(f'{i}<RegisterRecords>')
        for rr in reg_records:
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{rr}</xr:Item>')
        X(f'{i}</RegisterRecords>')
    else:
        X(f'{i}<RegisterRecords/>')
    X(f'{i}<PostInPrivilegedMode>{post_in_priv}</PostInPrivilegedMode>')
    X(f'{i}<UnpostInPrivilegedMode>{unpost_in_priv}</UnpostInPrivilegedMode>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_enum_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>false</UseStandardCommands>')
    emit_standard_attributes(i, 'Enum')
    X(f'{i}<Characteristics/>')
    X(f'{i}<QuickChoice>true</QuickChoice>')
    X(f'{i}<ChoiceMode>BothWays</ChoiceMode>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')

def emit_constant_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    # Type
    value_type = build_type_str(defn) or 'String'
    emit_value_type(i, value_type)
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    X(f'{i}<DefaultForm/>')
    X(f'{i}<ExtendedPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<PasswordMode>false</PasswordMode>')
    X(f'{i}<Format/>')
    X(f'{i}<EditFormat/>')
    X(f'{i}<ToolTip/>')
    X(f'{i}<MarkNegatives>false</MarkNegatives>')
    X(f'{i}<Mask/>')
    X(f'{i}<MultiLine>false</MultiLine>')
    X(f'{i}<ExtendedEdit>false</ExtendedEdit>')
    X(f'{i}<MinValue xsi:nil="true"/>')
    X(f'{i}<MaxValue xsi:nil="true"/>')
    X(f'{i}<FillChecking>DontCheck</FillChecking>')
    X(f'{i}<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>')
    X(f'{i}<ChoiceParameterLinks/>')
    X(f'{i}<ChoiceParameters/>')
    X(f'{i}<QuickChoice>Auto</QuickChoice>')
    X(f'{i}<ChoiceForm/>')
    X(f'{i}<LinkByType/>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_information_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    X(f'{i}<EditType>InDialog</EditType>')
    X(f'{i}<DefaultRecordForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<AuxiliaryRecordForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    emit_standard_attributes(i, 'InformationRegister')
    periodicity = str(defn['periodicity']) if defn.get('periodicity') else 'Nonperiodical'
    write_mode = str(defn['writeMode']) if defn.get('writeMode') else 'Independent'
    main_filter_on_period = 'false'
    if defn.get('mainFilterOnPeriod') is not None:
        main_filter_on_period = 'true' if defn['mainFilterOnPeriod'] is True else 'false'
    elif periodicity != 'Nonperiodical':
        main_filter_on_period = 'true'
    X(f'{i}<InformationRegisterPeriodicity>{periodicity}</InformationRegisterPeriodicity>')
    X(f'{i}<WriteMode>{write_mode}</WriteMode>')
    X(f'{i}<MainFilterOnPeriod>{main_filter_on_period}</MainFilterOnPeriod>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<EnableTotalsSliceFirst>false</EnableTotalsSliceFirst>')
    X(f'{i}<EnableTotalsSliceLast>false</EnableTotalsSliceLast>')
    X(f'{i}<RecordPresentation/>')
    X(f'{i}<ExtendedRecordPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_accumulation_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    register_type = str(defn['registerType']) if defn.get('registerType') else 'Balance'
    X(f'{i}<RegisterType>{register_type}</RegisterType>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    emit_standard_attributes(i, 'AccumulationRegister')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    enable_totals_splitting = 'false' if defn.get('enableTotalsSplitting') is False else 'true'
    X(f'{i}<EnableTotalsSplitting>{enable_totals_splitting}</EnableTotalsSplitting>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')

# --- 13a. DefinedType, CommonModule, ScheduledJob, EventSubscription ---

def emit_defined_type_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    # Accept both valueType and valueTypes
    value_types = list(defn.get('valueTypes', []))
    if not value_types and defn.get('valueType'):
        vt_raw = defn['valueType']
        value_types = list(vt_raw) if isinstance(vt_raw, list) else [vt_raw]
    if value_types:
        X(f'{i}<Type>')
        for vt in value_types:
            resolved = resolve_type_str(str(vt))
            if re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef)\.', resolved):
                X(f'{i}\t<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{resolved}</v8:Type>')
            elif resolved == 'Boolean':
                X(f'{i}\t<v8:Type>xs:boolean</v8:Type>')
            elif re.match(r'^String', resolved):
                X(f'{i}\t<v8:Type>xs:string</v8:Type>')
                X(f'{i}\t<v8:StringQualifiers>')
                X(f'{i}\t\t<v8:Length>0</v8:Length>')
                X(f'{i}\t\t<v8:AllowedLength>Variable</v8:AllowedLength>')
                X(f'{i}\t</v8:StringQualifiers>')
            else:
                X(f'{i}\t<v8:Type>cfg:{resolved}</v8:Type>')
        X(f'{i}</Type>')
    else:
        X(f'{i}<Type/>')

def emit_common_module_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    context = str(defn['context']) if defn.get('context') else ''
    global_val = 'true' if defn.get('global') is True else 'false'
    server = 'false'
    server_call = 'false'
    client_managed = 'false'
    client_ordinary = 'false'
    external_connection = 'false'
    privileged = 'false'
    if context == 'server' or context == 'serverCall':
        server = 'true'
        server_call = 'true'
    elif context == 'client':
        client_managed = 'true'
    elif context == 'serverClient':
        server = 'true'
        client_managed = 'true'
    else:
        if defn.get('server') is True:
            server = 'true'
        if defn.get('serverCall') is True:
            server_call = 'true'
        if defn.get('clientManagedApplication') is True:
            client_managed = 'true'
        if defn.get('clientOrdinaryApplication') is True:
            client_ordinary = 'true'
        if defn.get('externalConnection') is True:
            external_connection = 'true'
        if defn.get('privileged') is True:
            privileged = 'true'
    X(f'{i}<Global>{global_val}</Global>')
    X(f'{i}<ClientManagedApplication>{client_managed}</ClientManagedApplication>')
    X(f'{i}<Server>{server}</Server>')
    X(f'{i}<ExternalConnection>{external_connection}</ExternalConnection>')
    X(f'{i}<ClientOrdinaryApplication>{client_ordinary}</ClientOrdinaryApplication>')
    X(f'{i}<ServerCall>{server_call}</ServerCall>')
    X(f'{i}<Privileged>{privileged}</Privileged>')
    return_values_reuse = str(defn['returnValuesReuse']) if defn.get('returnValuesReuse') else 'DontUse'
    X(f'{i}<ReturnValuesReuse>{return_values_reuse}</ReturnValuesReuse>')

def emit_scheduled_job_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    method_name = str(defn['methodName']) if defn.get('methodName') else ''
    # Ensure CommonModule. prefix
    if method_name and not method_name.startswith('CommonModule.'):
        method_name = f'CommonModule.{method_name}'
    X(f'{i}<MethodName>{esc_xml(method_name)}</MethodName>')
    description = str(defn['description']) if defn.get('description') else synonym
    X(f'{i}<Description>{esc_xml(description)}</Description>')
    key = str(defn['key']) if defn.get('key') else ''
    X(f'{i}<Key>{esc_xml(key)}</Key>')
    use = 'true' if defn.get('use') is True else 'false'
    X(f'{i}<Use>{use}</Use>')
    predefined = 'true' if defn.get('predefined') is True else 'false'
    X(f'{i}<Predefined>{predefined}</Predefined>')
    restart_count = str(defn['restartCountOnFailure']) if defn.get('restartCountOnFailure') is not None else '3'
    restart_interval = str(defn['restartIntervalOnFailure']) if defn.get('restartIntervalOnFailure') is not None else '10'
    X(f'{i}<RestartCountOnFailure>{restart_count}</RestartCountOnFailure>')
    X(f'{i}<RestartIntervalOnFailure>{restart_interval}</RestartIntervalOnFailure>')

def emit_event_subscription_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    sources = list(defn.get('source', []))
    if sources:
        X(f'{i}<Source>')
        for src in sources:
            resolved = resolve_type_str(str(src))
            X(f'{i}\t<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{resolved}</v8:Type>')
        X(f'{i}</Source>')
    else:
        X(f'{i}<Source/>')
    event = str(defn['event']) if defn.get('event') else 'BeforeWrite'
    X(f'{i}<Event>{event}</Event>')
    handler = str(defn['handler']) if defn.get('handler') else ''
    # Ensure CommonModule. prefix
    if handler and not handler.startswith('CommonModule.'):
        handler = f'CommonModule.{handler}'
    X(f'{i}<Handler>{esc_xml(handler)}</Handler>')

# --- 13b. Report, DataProcessor ---

def emit_report_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    default_form = str(defn['defaultForm']) if defn.get('defaultForm') else ''
    if default_form:
        X(f'{i}<DefaultForm>{default_form}</DefaultForm>')
    else:
        X(f'{i}<DefaultForm/>')
    aux_form = str(defn['auxiliaryForm']) if defn.get('auxiliaryForm') else ''
    if aux_form:
        X(f'{i}<AuxiliaryForm>{aux_form}</AuxiliaryForm>')
    else:
        X(f'{i}<AuxiliaryForm/>')
    main_dcs = str(defn['mainDataCompositionSchema']) if defn.get('mainDataCompositionSchema') else ''
    if main_dcs:
        X(f'{i}<MainDataCompositionSchema>{main_dcs}</MainDataCompositionSchema>')
    else:
        X(f'{i}<MainDataCompositionSchema/>')
    def_settings = str(defn['defaultSettingsForm']) if defn.get('defaultSettingsForm') else ''
    if def_settings:
        X(f'{i}<DefaultSettingsForm>{def_settings}</DefaultSettingsForm>')
    else:
        X(f'{i}<DefaultSettingsForm/>')
    aux_settings = str(defn['auxiliarySettingsForm']) if defn.get('auxiliarySettingsForm') else ''
    if aux_settings:
        X(f'{i}<AuxiliarySettingsForm>{aux_settings}</AuxiliarySettingsForm>')
    else:
        X(f'{i}<AuxiliarySettingsForm/>')
    def_variant = str(defn['defaultVariantForm']) if defn.get('defaultVariantForm') else ''
    if def_variant:
        X(f'{i}<DefaultVariantForm>{def_variant}</DefaultVariantForm>')
    else:
        X(f'{i}<DefaultVariantForm/>')
    X(f'{i}<VariantsStorage/>')
    X(f'{i}<SettingsStorage/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<ExtendedPresentation/>')
    X(f'{i}<Explanation/>')

def emit_data_processor_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>false</UseStandardCommands>')
    default_form = str(defn['defaultForm']) if defn.get('defaultForm') else ''
    if default_form:
        X(f'{i}<DefaultForm>{default_form}</DefaultForm>')
    else:
        X(f'{i}<DefaultForm/>')
    aux_form = str(defn['auxiliaryForm']) if defn.get('auxiliaryForm') else ''
    if aux_form:
        X(f'{i}<AuxiliaryForm>{aux_form}</AuxiliaryForm>')
    else:
        X(f'{i}<AuxiliaryForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<ExtendedPresentation/>')
    X(f'{i}<Explanation/>')

# --- 13c. ExchangePlan, ChartOfCharacteristicTypes, DocumentJournal ---

def emit_exchange_plan_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '100'
    code_allowed_length = str(defn['codeAllowedLength']) if defn.get('codeAllowedLength') else 'Variable'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<CodeAllowedLength>{code_allowed_length}</CodeAllowedLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<DefaultPresentation>AsDescription</DefaultPresentation>')
    X(f'{i}<EditType>InDialog</EditType>')
    emit_standard_attributes(i, 'ExchangePlan')
    distributed = 'true' if defn.get('distributedInfoBase') is True else 'false'
    include_ext = 'true' if defn.get('includeConfigurationExtensions') is True else 'false'
    X(f'{i}<DistributedInfoBase>{distributed}</DistributedInfoBase>')
    X(f'{i}<IncludeConfigurationExtensions>{include_ext}</IncludeConfigurationExtensions>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<QuickChoice>true</QuickChoice>')
    X(f'{i}<ChoiceMode>BothWays</ChoiceMode>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>ExchangePlan.{obj_name}.StandardAttribute.Description</xr:Field>')
    X(f'{i}\t<xr:Field>ExchangePlan.{obj_name}.StandardAttribute.Code</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_chart_of_characteristic_types_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '25'
    code_allowed_length = str(defn['codeAllowedLength']) if defn.get('codeAllowedLength') else 'Variable'
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    check_unique = 'true' if defn.get('checkUnique') is True else 'false'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<CodeAllowedLength>{code_allowed_length}</CodeAllowedLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    X(f'{i}<DefaultPresentation>AsDescription</DefaultPresentation>')
    char_ext_values = str(defn['characteristicExtValues']) if defn.get('characteristicExtValues') else ''
    if char_ext_values:
        X(f'{i}<CharacteristicExtValues>{char_ext_values}</CharacteristicExtValues>')
    else:
        X(f'{i}<CharacteristicExtValues/>')
    value_types = list(defn.get('valueTypes', []))
    if value_types:
        X(f'{i}<Type>')
        for vt in value_types:
            emit_type_content(f'{i}\t', str(vt))
        X(f'{i}</Type>')
    else:
        X(f'{i}<Type>')
        X(f'{i}\t<v8:Type>xs:boolean</v8:Type>')
        X(f'{i}\t<v8:Type>xs:string</v8:Type>')
        X(f'{i}\t<v8:StringQualifiers>')
        X(f'{i}\t\t<v8:Length>100</v8:Length>')
        X(f'{i}\t\t<v8:AllowedLength>Variable</v8:AllowedLength>')
        X(f'{i}\t</v8:StringQualifiers>')
        X(f'{i}\t<v8:Type>xs:decimal</v8:Type>')
        X(f'{i}\t<v8:NumberQualifiers>')
        X(f'{i}\t\t<v8:Digits>15</v8:Digits>')
        X(f'{i}\t\t<v8:FractionDigits>2</v8:FractionDigits>')
        X(f'{i}\t\t<v8:AllowedSign>Any</v8:AllowedSign>')
        X(f'{i}\t</v8:NumberQualifiers>')
        X(f'{i}\t<v8:Type>xs:dateTime</v8:Type>')
        X(f'{i}\t<v8:DateQualifiers>')
        X(f'{i}\t\t<v8:DateFractions>DateTime</v8:DateFractions>')
        X(f'{i}\t</v8:DateQualifiers>')
        X(f'{i}</Type>')
    hierarchical = 'true' if defn.get('hierarchical') is True else 'false'
    X(f'{i}<Hierarchical>{hierarchical}</Hierarchical>')
    X(f'{i}<FoldersOnTop>true</FoldersOnTop>')
    emit_standard_attributes(i, 'ChartOfCharacteristicTypes')
    X(f'{i}<Characteristics/>')
    X(f'{i}<PredefinedDataUpdate>Auto</PredefinedDataUpdate>')
    X(f'{i}<EditType>InDialog</EditType>')
    X(f'{i}<QuickChoice>true</QuickChoice>')
    X(f'{i}<ChoiceMode>BothWays</ChoiceMode>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>ChartOfCharacteristicTypes.{obj_name}.StandardAttribute.Description</xr:Field>')
    X(f'{i}\t<xr:Field>ChartOfCharacteristicTypes.{obj_name}.StandardAttribute.Code</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultFolderForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<DefaultFolderChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryFolderForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<AuxiliaryFolderChoiceForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_document_journal_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    default_form = str(defn['defaultForm']) if defn.get('defaultForm') else ''
    if default_form:
        X(f'{i}<DefaultForm>{default_form}</DefaultForm>')
    else:
        X(f'{i}<DefaultForm/>')
    aux_form = str(defn['auxiliaryForm']) if defn.get('auxiliaryForm') else ''
    if aux_form:
        X(f'{i}<AuxiliaryForm>{aux_form}</AuxiliaryForm>')
    else:
        X(f'{i}<AuxiliaryForm/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    reg_docs = list(defn.get('registeredDocuments', []))
    if reg_docs:
        X(f'{i}<RegisteredDocuments>')
        for rd in reg_docs:
            rd_str = str(rd)
            if '.' in rd_str:
                dot_idx = rd_str.index('.')
                rd_prefix = rd_str[:dot_idx]
                rd_suffix = rd_str[dot_idx + 1:]
                if rd_prefix in object_type_synonyms:
                    rd_prefix = object_type_synonyms[rd_prefix]
                rd_str = f'{rd_prefix}.{rd_suffix}'
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{rd_str}</xr:Item>')
        X(f'{i}</RegisteredDocuments>')
    else:
        X(f'{i}<RegisteredDocuments/>')
    emit_standard_attributes(i, 'DocumentJournal')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')

def emit_chart_of_accounts_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    ext_dim_types = str(defn['extDimensionTypes']) if defn.get('extDimensionTypes') else ''
    if ext_dim_types:
        X(f'{i}<ExtDimensionTypes>{ext_dim_types}</ExtDimensionTypes>')
    else:
        X(f'{i}<ExtDimensionTypes/>')
    max_ext_dim = str(defn['maxExtDimensionCount']) if defn.get('maxExtDimensionCount') is not None else '3'
    X(f'{i}<MaxExtDimensionCount>{max_ext_dim}</MaxExtDimensionCount>')
    code_mask = str(defn['codeMask']) if defn.get('codeMask') else ''
    if code_mask:
        X(f'{i}<CodeMask>{code_mask}</CodeMask>')
    else:
        X(f'{i}<CodeMask/>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '8'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '120'
    code_series = str(defn['codeSeries']) if defn.get('codeSeries') else 'WholeChartOfAccounts'
    auto_order = 'false' if defn.get('autoOrderByCode') is False else 'true'
    order_length = str(defn['orderLength']) if defn.get('orderLength') is not None else '5'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<CodeSeries>{code_series}</CodeSeries>')
    X(f'{i}<CheckUnique>false</CheckUnique>')
    X(f'{i}<DefaultPresentation>AsDescription</DefaultPresentation>')
    X(f'{i}<AutoOrderByCode>{auto_order}</AutoOrderByCode>')
    X(f'{i}<OrderLength>{order_length}</OrderLength>')
    X(f'{i}<EditType>InDialog</EditType>')
    emit_standard_attributes(i, 'ChartOfAccounts')
    X(f'{i}<StandardTabularSections>')
    X(f'{i}\t<xr:StandardTabularSection name="ExtDimensionTypes">')
    X(f'{i}\t\t<xr:StandardAttributes>')
    for st_attr in ['TurnoversOnly', 'Predefined', 'ExtDimensionType', 'LineNumber']:
        emit_standard_attribute(f'{i}\t\t\t', st_attr)
    X(f'{i}\t\t</xr:StandardAttributes>')
    X(f'{i}\t</xr:StandardTabularSection>')
    X(f'{i}</StandardTabularSections>')
    X(f'{i}<Characteristics/>')
    X(f'{i}<PredefinedDataUpdate>Auto</PredefinedDataUpdate>')
    X(f'{i}<QuickChoice>true</QuickChoice>')
    X(f'{i}<ChoiceMode>BothWays</ChoiceMode>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>ChartOfAccounts.{obj_name}.StandardAttribute.Description</xr:Field>')
    X(f'{i}\t<xr:Field>ChartOfAccounts.{obj_name}.StandardAttribute.Code</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_accounting_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    chart_of_accounts = str(defn['chartOfAccounts']) if defn.get('chartOfAccounts') else ''
    if chart_of_accounts:
        X(f'{i}<ChartOfAccounts>{chart_of_accounts}</ChartOfAccounts>')
    else:
        X(f'{i}<ChartOfAccounts/>')
    correspondence = 'true' if defn.get('correspondence') is True else 'false'
    X(f'{i}<Correspondence>{correspondence}</Correspondence>')
    period_adj_len = str(defn['periodAdjustmentLength']) if defn.get('periodAdjustmentLength') is not None else '0'
    X(f'{i}<PeriodAdjustmentLength>{period_adj_len}</PeriodAdjustmentLength>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    emit_standard_attributes(i, 'AccountingRegister')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')

def emit_chart_of_calculation_types_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '25'
    code_type = str(defn['codeType']) if defn.get('codeType') else 'String'
    code_allowed_length = str(defn['codeAllowedLength']) if defn.get('codeAllowedLength') else 'Variable'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<CodeType>{code_type}</CodeType>')
    X(f'{i}<CodeAllowedLength>{code_allowed_length}</CodeAllowedLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<DefaultPresentation>AsDescription</DefaultPresentation>')
    dependence = str(defn['dependenceOnCalculationTypes']) if defn.get('dependenceOnCalculationTypes') else 'DontUse'
    X(f'{i}<DependenceOnCalculationTypes>{dependence}</DependenceOnCalculationTypes>')
    base_types = list(defn.get('baseCalculationTypes', []))
    if base_types:
        X(f'{i}<BaseCalculationTypes>')
        for bt in base_types:
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{bt}</xr:Item>')
        X(f'{i}</BaseCalculationTypes>')
    else:
        X(f'{i}<BaseCalculationTypes/>')
    action_period_use = 'true' if defn.get('actionPeriodUse') is True else 'false'
    X(f'{i}<ActionPeriodUse>{action_period_use}</ActionPeriodUse>')
    emit_standard_attributes(i, 'ChartOfCalculationTypes')
    X(f'{i}<Characteristics/>')
    X(f'{i}<PredefinedDataUpdate>Auto</PredefinedDataUpdate>')
    X(f'{i}<EditType>InDialog</EditType>')
    X(f'{i}<QuickChoice>true</QuickChoice>')
    X(f'{i}<ChoiceMode>BothWays</ChoiceMode>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>ChartOfCalculationTypes.{obj_name}.StandardAttribute.Description</xr:Field>')
    X(f'{i}\t<xr:Field>ChartOfCalculationTypes.{obj_name}.StandardAttribute.Code</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')

def emit_calculation_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    chart_of_calc_types = str(defn['chartOfCalculationTypes']) if defn.get('chartOfCalculationTypes') else ''
    if chart_of_calc_types:
        X(f'{i}<ChartOfCalculationTypes>{chart_of_calc_types}</ChartOfCalculationTypes>')
    else:
        X(f'{i}<ChartOfCalculationTypes/>')
    periodicity = str(defn['periodicity']) if defn.get('periodicity') else 'Month'
    X(f'{i}<Periodicity>{periodicity}</Periodicity>')
    action_period = 'true' if defn.get('actionPeriod') is True else 'false'
    X(f'{i}<ActionPeriod>{action_period}</ActionPeriod>')
    base_period = 'true' if defn.get('basePeriod') is True else 'false'
    X(f'{i}<BasePeriod>{base_period}</BasePeriod>')
    schedule = str(defn['schedule']) if defn.get('schedule') else ''
    if schedule:
        X(f'{i}<Schedule>{schedule}</Schedule>')
    else:
        X(f'{i}<Schedule/>')
    schedule_value = str(defn['scheduleValue']) if defn.get('scheduleValue') else ''
    if schedule_value:
        X(f'{i}<ScheduleValue>{schedule_value}</ScheduleValue>')
    else:
        X(f'{i}<ScheduleValue/>')
    schedule_date = str(defn['scheduleDate']) if defn.get('scheduleDate') else ''
    if schedule_date:
        X(f'{i}<ScheduleDate>{schedule_date}</ScheduleDate>')
    else:
        X(f'{i}<ScheduleDate/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    emit_standard_attributes(i, 'CalculationRegister')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')

def emit_business_process_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    edit_type = str(defn['editType']) if defn.get('editType') else 'InDialog'
    X(f'{i}<EditType>{edit_type}</EditType>')
    number_type = str(defn['numberType']) if defn.get('numberType') else 'String'
    number_length = str(defn['numberLength']) if defn.get('numberLength') is not None else '11'
    number_allowed_length = str(defn['numberAllowedLength']) if defn.get('numberAllowedLength') else 'Variable'
    check_unique = 'false' if defn.get('checkUnique') is False else 'true'
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    X(f'{i}<NumberType>{number_type}</NumberType>')
    X(f'{i}<NumberLength>{number_length}</NumberLength>')
    X(f'{i}<NumberAllowedLength>{number_allowed_length}</NumberAllowedLength>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    emit_standard_attributes(i, 'BusinessProcess')
    X(f'{i}<Characteristics/>')
    task_ref = str(defn['task']) if defn.get('task') else ''
    if task_ref:
        X(f'{i}<Task>{task_ref}</Task>')
    else:
        X(f'{i}<Task/>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>BusinessProcess.{obj_name}.StandardAttribute.Number</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_task_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>true</UseStandardCommands>')
    number_type = str(defn['numberType']) if defn.get('numberType') else 'String'
    number_length = str(defn['numberLength']) if defn.get('numberLength') is not None else '14'
    number_allowed_length = str(defn['numberAllowedLength']) if defn.get('numberAllowedLength') else 'Variable'
    check_unique = 'false' if defn.get('checkUnique') is False else 'true'
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    task_number_auto_prefix = str(defn['taskNumberAutoPrefix']) if defn.get('taskNumberAutoPrefix') else 'BusinessProcessNumber'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '150'
    X(f'{i}<NumberType>{number_type}</NumberType>')
    X(f'{i}<NumberLength>{number_length}</NumberLength>')
    X(f'{i}<NumberAllowedLength>{number_allowed_length}</NumberAllowedLength>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    X(f'{i}<TaskNumberAutoPrefix>{task_number_auto_prefix}</TaskNumberAutoPrefix>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    addressing = str(defn['addressing']) if defn.get('addressing') else ''
    if addressing:
        X(f'{i}<Addressing>{addressing}</Addressing>')
    else:
        X(f'{i}<Addressing/>')
    main_addressing = str(defn['mainAddressingAttribute']) if defn.get('mainAddressingAttribute') else ''
    if main_addressing:
        X(f'{i}<MainAddressingAttribute>{main_addressing}</MainAddressingAttribute>')
    else:
        X(f'{i}<MainAddressingAttribute/>')
    current_performer = str(defn['currentPerformer']) if defn.get('currentPerformer') else ''
    if current_performer:
        X(f'{i}<CurrentPerformer>{current_performer}</CurrentPerformer>')
    else:
        X(f'{i}<CurrentPerformer/>')
    emit_standard_attributes(i, 'Task')
    X(f'{i}<Characteristics/>')
    X(f'{i}<BasedOn/>')
    X(f'{i}<InputByString>')
    X(f'{i}\t<xr:Field>Task.{obj_name}.StandardAttribute.Number</xr:Field>')
    X(f'{i}</InputByString>')
    X(f'{i}<CreateOnInput>DontUse</CreateOnInput>')
    X(f'{i}<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<DefaultObjectForm/>')
    X(f'{i}<DefaultListForm/>')
    X(f'{i}<DefaultChoiceForm/>')
    X(f'{i}<AuxiliaryObjectForm/>')
    X(f'{i}<AuxiliaryListForm/>')
    X(f'{i}<AuxiliaryChoiceForm/>')
    X(f'{i}<IncludeHelpInContents>false</IncludeHelpInContents>')
    X(f'{i}<DataLockFields/>')
    data_lock_control_mode = str(defn['dataLockControlMode']) if defn.get('dataLockControlMode') else 'Automatic'
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = str(defn['fullTextSearch']) if defn.get('fullTextSearch') else 'Use'
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    X(f'{i}<ObjectPresentation/>')
    X(f'{i}<ExtendedObjectPresentation/>')
    X(f'{i}<ListPresentation/>')
    X(f'{i}<ExtendedListPresentation/>')
    X(f'{i}<Explanation/>')
    X(f'{i}<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_http_service_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    root_url = str(defn['rootURL']) if defn.get('rootURL') else obj_name.lower()
    X(f'{i}<RootURL>{esc_xml(root_url)}</RootURL>')
    reuse_sessions = str(defn['reuseSessions']) if defn.get('reuseSessions') else 'DontUse'
    X(f'{i}<ReuseSessions>{reuse_sessions}</ReuseSessions>')
    session_max_age = str(defn['sessionMaxAge']) if defn.get('sessionMaxAge') is not None else '20'
    X(f'{i}<SessionMaxAge>{session_max_age}</SessionMaxAge>')

def emit_web_service_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    namespace = str(defn['namespace']) if defn.get('namespace') else ''
    X(f'{i}<Namespace>{esc_xml(namespace)}</Namespace>')
    xdto_packages = str(defn['xdtoPackages']) if defn.get('xdtoPackages') else ''
    if xdto_packages:
        X(f'{i}<XDTOPackages>{xdto_packages}</XDTOPackages>')
    else:
        X(f'{i}<XDTOPackages/>')
    reuse_sessions = str(defn['reuseSessions']) if defn.get('reuseSessions') else 'DontUse'
    X(f'{i}<ReuseSessions>{reuse_sessions}</ReuseSessions>')
    session_max_age = str(defn['sessionMaxAge']) if defn.get('sessionMaxAge') is not None else '20'
    X(f'{i}<SessionMaxAge>{session_max_age}</SessionMaxAge>')


# --- 13g. ChildObjects emitters for new types ---

def emit_column(indent, col_def):
    uid = new_uuid()
    name = ''
    col_synonym = ''
    indexing = 'DontIndex'
    references = []
    if isinstance(col_def, str):
        name = col_def
        col_synonym = split_camel_case(name)
    else:
        name = str(col_def.get('name', ''))
        col_synonym = str(col_def['synonym']) if col_def.get('synonym') else split_camel_case(name)
        if col_def.get('indexing'):
            indexing = str(col_def['indexing'])
        if col_def.get('references'):
            references = list(col_def['references'])
    X(f'{indent}<Column uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', col_synonym)
    X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t\t<Indexing>{indexing}</Indexing>')
    if references:
        X(f'{indent}\t\t<References>')
        for ref in references:
            X(f'{indent}\t\t\t<xr:Item xsi:type="xr:MDObjectRef">{ref}</xr:Item>')
        X(f'{indent}\t\t</References>')
    else:
        X(f'{indent}\t\t<References/>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Column>')

def emit_accounting_flag(indent, flag_name):
    uid = new_uuid()
    flag_synonym = split_camel_case(flag_name)
    X(f'{indent}<AccountingFlag uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(flag_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', flag_synonym)
    X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t\t<Type>')
    X(f'{indent}\t\t\t<v8:Type>xs:boolean</v8:Type>')
    X(f'{indent}\t\t</Type>')
    X(f'{indent}\t\t<PasswordMode>false</PasswordMode>')
    X(f'{indent}\t\t<Format/>')
    X(f'{indent}\t\t<EditFormat/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<MarkNegatives>false</MarkNegatives>')
    X(f'{indent}\t\t<Mask/>')
    X(f'{indent}\t\t<MultiLine>false</MultiLine>')
    X(f'{indent}\t\t<ExtendedEdit>false</ExtendedEdit>')
    X(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    X(f'{indent}\t\t<MaxValue xsi:nil="true"/>')
    X(f'{indent}\t\t<FillChecking>DontCheck</FillChecking>')
    X(f'{indent}\t\t<ChoiceParameterLinks/>')
    X(f'{indent}\t\t<ChoiceParameters/>')
    X(f'{indent}\t\t<QuickChoice>Auto</QuickChoice>')
    X(f'{indent}\t\t<ChoiceForm/>')
    X(f'{indent}\t\t<LinkByType/>')
    X(f'{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</AccountingFlag>')

def emit_ext_dimension_accounting_flag(indent, flag_name):
    uid = new_uuid()
    flag_synonym = split_camel_case(flag_name)
    X(f'{indent}<ExtDimensionAccountingFlag uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(flag_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', flag_synonym)
    X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t\t<Type>')
    X(f'{indent}\t\t\t<v8:Type>xs:boolean</v8:Type>')
    X(f'{indent}\t\t</Type>')
    X(f'{indent}\t\t<PasswordMode>false</PasswordMode>')
    X(f'{indent}\t\t<Format/>')
    X(f'{indent}\t\t<EditFormat/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<MarkNegatives>false</MarkNegatives>')
    X(f'{indent}\t\t<Mask/>')
    X(f'{indent}\t\t<MultiLine>false</MultiLine>')
    X(f'{indent}\t\t<ExtendedEdit>false</ExtendedEdit>')
    X(f'{indent}\t\t<MinValue xsi:nil="true"/>')
    X(f'{indent}\t\t<MaxValue xsi:nil="true"/>')
    X(f'{indent}\t\t<FillChecking>DontCheck</FillChecking>')
    X(f'{indent}\t\t<ChoiceParameterLinks/>')
    X(f'{indent}\t\t<ChoiceParameters/>')
    X(f'{indent}\t\t<QuickChoice>Auto</QuickChoice>')
    X(f'{indent}\t\t<ChoiceForm/>')
    X(f'{indent}\t\t<LinkByType/>')
    X(f'{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</ExtDimensionAccountingFlag>')

def emit_url_template(indent, tmpl_name, tmpl_def):
    uid = new_uuid()
    tmpl_synonym = split_camel_case(tmpl_name)
    template = ''
    methods = {}
    if isinstance(tmpl_def, str):
        template = tmpl_def
    else:
        template = str(tmpl_def['template']) if tmpl_def.get('template') else f'/{tmpl_name.lower()}'
        if tmpl_def.get('methods'):
            for k, v in tmpl_def['methods'].items():
                methods[k] = str(v)
    X(f'{indent}<URLTemplate uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(tmpl_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', tmpl_synonym)
    X(f'{indent}\t\t<Template>{esc_xml(template)}</Template>')
    X(f'{indent}\t</Properties>')
    if methods:
        X(f'{indent}\t<ChildObjects>')
        for method_name, http_method in methods.items():
            method_uuid = new_uuid()
            method_synonym = split_camel_case(method_name)
            handler = f'{tmpl_name}{method_name}'
            X(f'{indent}\t\t<Method uuid="{method_uuid}">')
            X(f'{indent}\t\t\t<Properties>')
            X(f'{indent}\t\t\t\t<Name>{esc_xml(method_name)}</Name>')
            emit_mltext(f'{indent}\t\t\t\t', 'Synonym', method_synonym)
            X(f'{indent}\t\t\t\t<HTTPMethod>{http_method}</HTTPMethod>')
            X(f'{indent}\t\t\t\t<Handler>{esc_xml(handler)}</Handler>')
            X(f'{indent}\t\t\t</Properties>')
            X(f'{indent}\t\t</Method>')
        X(f'{indent}\t</ChildObjects>')
    else:
        X(f'{indent}\t<ChildObjects/>')
    X(f'{indent}</URLTemplate>')

def emit_operation(indent, op_name, op_def):
    uid = new_uuid()
    op_synonym = split_camel_case(op_name)
    return_type = 'xs:string'
    nillable = 'false'
    transactioned = 'false'
    handler = op_name
    params = {}
    if isinstance(op_def, str):
        return_type = op_def
    else:
        if op_def.get('returnType'):
            return_type = str(op_def['returnType'])
        if op_def.get('nillable') is True:
            nillable = 'true'
        if op_def.get('transactioned') is True:
            transactioned = 'true'
        if op_def.get('handler'):
            handler = str(op_def['handler'])
        if op_def.get('parameters'):
            for k, v in op_def['parameters'].items():
                params[k] = v
    X(f'{indent}<Operation uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(op_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', op_synonym)
    X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t\t<XDTOReturningValueType>{return_type}</XDTOReturningValueType>')
    X(f'{indent}\t\t<Nillable>{nillable}</Nillable>')
    X(f'{indent}\t\t<Transactioned>{transactioned}</Transactioned>')
    X(f'{indent}\t\t<ProcedureName>{esc_xml(handler)}</ProcedureName>')
    X(f'{indent}\t</Properties>')
    if params:
        X(f'{indent}\t<ChildObjects>')
        for param_name, param_def in params.items():
            param_uuid = new_uuid()
            param_synonym = split_camel_case(param_name)
            param_type = 'xs:string'
            param_nillable = 'true'
            param_dir = 'In'
            if isinstance(param_def, str):
                param_type = param_def
            else:
                if param_def.get('type'):
                    param_type = str(param_def['type'])
                if param_def.get('nillable') is False:
                    param_nillable = 'false'
                if param_def.get('direction'):
                    param_dir = str(param_def['direction'])
            X(f'{indent}\t\t<Parameter uuid="{param_uuid}">')
            X(f'{indent}\t\t\t<Properties>')
            X(f'{indent}\t\t\t\t<Name>{esc_xml(param_name)}</Name>')
            emit_mltext(f'{indent}\t\t\t\t', 'Synonym', param_synonym)
            X(f'{indent}\t\t\t\t<XDTOValueType>{param_type}</XDTOValueType>')
            X(f'{indent}\t\t\t\t<Nillable>{param_nillable}</Nillable>')
            X(f'{indent}\t\t\t\t<TransferDirection>{param_dir}</TransferDirection>')
            X(f'{indent}\t\t\t</Properties>')
            X(f'{indent}\t\t</Parameter>')
        X(f'{indent}\t</ChildObjects>')
    else:
        X(f'{indent}\t<ChildObjects/>')
    X(f'{indent}</Operation>')

def emit_addressing_attribute(indent, addr_def):
    uid = new_uuid()
    name = ''
    attr_synonym = ''
    type_str = ''
    addressing_dimension = ''
    indexing = 'Index'
    parsed = parse_attribute_shorthand(addr_def)
    name = parsed['name']
    attr_synonym = parsed['synonym']
    type_str = parsed['type']
    if not isinstance(addr_def, str):
        if addr_def.get('addressingDimension'):
            addressing_dimension = str(addr_def['addressingDimension'])
        if addr_def.get('indexing'):
            indexing = str(addr_def['indexing'])
    X(f'{indent}<AddressingAttribute uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', attr_synonym)
    X(f'{indent}\t\t<Comment/>')
    if type_str:
        emit_value_type(f'{indent}\t\t', type_str)
    else:
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:string</v8:Type>')
        X(f'{indent}\t\t</Type>')
    if addressing_dimension:
        X(f'{indent}\t\t<AddressingDimension>{addressing_dimension}</AddressingDimension>')
    else:
        X(f'{indent}\t\t<AddressingDimension/>')
    X(f'{indent}\t\t<Indexing>{indexing}</Indexing>')
    X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
    X(f'{indent}\t\t<DataHistory>Use</DataHistory>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</AddressingAttribute>')

# ---------------------------------------------------------------------------
# 14. Namespaces
# ---------------------------------------------------------------------------

xmlns_decl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

# ---------------------------------------------------------------------------
# 15. Main assembler
# ---------------------------------------------------------------------------

obj_uuid = new_uuid()

X('<?xml version="1.0" encoding="UTF-8"?>')
X(f'<MetaDataObject {xmlns_decl} version="2.17">')
X(f'\t<{obj_type} uuid="{obj_uuid}">')

# InternalInfo
emit_internal_info('\t\t', obj_type, obj_name)

# Properties
X('\t\t<Properties>')

property_emitters = {
    'Catalog': emit_catalog_properties,
    'Document': emit_document_properties,
    'Enum': emit_enum_properties,
    'Constant': emit_constant_properties,
    'InformationRegister': emit_information_register_properties,
    'AccumulationRegister': emit_accumulation_register_properties,
    'DefinedType': emit_defined_type_properties,
    'CommonModule': emit_common_module_properties,
    'ScheduledJob': emit_scheduled_job_properties,
    'EventSubscription': emit_event_subscription_properties,
    'Report': emit_report_properties,
    'DataProcessor': emit_data_processor_properties,
    'ExchangePlan': emit_exchange_plan_properties,
    'ChartOfCharacteristicTypes': emit_chart_of_characteristic_types_properties,
    'DocumentJournal': emit_document_journal_properties,
    'ChartOfAccounts': emit_chart_of_accounts_properties,
    'AccountingRegister': emit_accounting_register_properties,
    'ChartOfCalculationTypes': emit_chart_of_calculation_types_properties,
    'CalculationRegister': emit_calculation_register_properties,
    'BusinessProcess': emit_business_process_properties,
    'Task': emit_task_properties,
    'HTTPService': emit_http_service_properties,
    'WebService': emit_web_service_properties,
}

property_emitters[obj_type]('\t\t\t')

X('\t\t</Properties>')

# ChildObjects
has_children = False

# --- Types with Attributes + TabularSections ---
types_with_attr_ts = [
    'Catalog', 'Document', 'Report', 'DataProcessor', 'ExchangePlan',
    'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes',
    'BusinessProcess', 'Task',
]

if obj_type in types_with_attr_ts:
    def _as_list(val):
        """Normalize attributes: dict {"K":"V"} → ["K:V"], list/other → list."""
        if val is None:
            return []
        if isinstance(val, dict):
            return [f"{k}:{v}" for k, v in val.items()]
        return list(val)

    attrs = []
    if defn.get('attributes'):
        for a in _as_list(defn['attributes']):
            attrs.append(parse_attribute_shorthand(a))
    ts_sections = {}
    ts_order = []
    if defn.get('tabularSections'):
        ts_data = defn['tabularSections']
        if isinstance(ts_data, list):
            for ts in ts_data:
                ts_name = ts['name']
                ts_cols = _as_list(ts.get('attributes', []))
                ts_sections[ts_name] = ts_cols
                ts_order.append(ts_name)
        else:
            for k, v in ts_data.items():
                ts_sections[k] = _as_list(v)
                ts_order.append(k)
    # ChartOfAccounts: AccountingFlags + ExtDimensionAccountingFlags
    acct_flags = []
    ext_dim_flags = []
    if obj_type == 'ChartOfAccounts':
        if defn.get('accountingFlags'):
            acct_flags = _as_list(defn['accountingFlags'])
        if defn.get('extDimensionAccountingFlags'):
            ext_dim_flags = _as_list(defn['extDimensionAccountingFlags'])
    # Task: AddressingAttributes
    addr_attrs = []
    if obj_type == 'Task' and defn.get('addressingAttributes'):
        addr_attrs = _as_list(defn['addressingAttributes'])
    child_count = len(attrs) + len(ts_sections) + len(acct_flags) + len(ext_dim_flags) + len(addr_attrs)
    if child_count > 0:
        has_children = True
        X('\t\t<ChildObjects>')
        if obj_type == 'Catalog':
            context = 'catalog'
        elif obj_type == 'Document':
            context = 'document'
        elif obj_type in ('DataProcessor', 'Report'):
            context = 'processor'
        else:
            context = 'object'
        for a in attrs:
            emit_attribute('\t\t\t', a, context)
        for ts_name in ts_order:
            columns = ts_sections[ts_name]
            emit_tabular_section('\t\t\t', ts_name, columns, obj_type, obj_name)
        for af in acct_flags:
            emit_accounting_flag('\t\t\t', str(af))
        for edf in ext_dim_flags:
            emit_ext_dimension_accounting_flag('\t\t\t', str(edf))
        for aa in addr_attrs:
            emit_addressing_attribute('\t\t\t', aa)
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- Enum: enum values ---
if obj_type == 'Enum':
    values = []
    if defn.get('values'):
        for v in defn['values']:
            values.append(parse_enum_value_shorthand(v))
    if values:
        has_children = True
        X('\t\t<ChildObjects>')
        for v in values:
            emit_enum_value('\t\t\t', v)
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- Constant, DefinedType, ScheduledJob, EventSubscription: no ChildObjects ---

# --- Registers: dimensions + resources + attributes ---
if obj_type in ('InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister'):
    dims = []
    resources = []
    reg_attrs = []
    if defn.get('dimensions'):
        for d in defn['dimensions']:
            dims.append(parse_attribute_shorthand(d))
    if defn.get('resources'):
        for r in defn['resources']:
            resources.append(parse_attribute_shorthand(r))
    if defn.get('attributes'):
        for a in defn['attributes']:
            reg_attrs.append(parse_attribute_shorthand(a))
    if dims or resources or reg_attrs:
        has_children = True
        X('\t\t<ChildObjects>')
        for r in resources:
            emit_resource('\t\t\t', r, obj_type)
        for d in dims:
            emit_dimension('\t\t\t', d, obj_type)
        for a in reg_attrs:
            emit_attribute('\t\t\t', a, 'register')
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- DocumentJournal: columns ---
if obj_type == 'DocumentJournal':
    columns = list(defn.get('columns', []))
    if columns:
        has_children = True
        X('\t\t<ChildObjects>')
        for col in columns:
            emit_column('\t\t\t', col)
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- HTTPService: URLTemplates ---
if obj_type == 'HTTPService':
    url_templates = {}
    url_tmpl_order = []
    if defn.get('urlTemplates'):
        for k, v in defn['urlTemplates'].items():
            url_templates[k] = v
            url_tmpl_order.append(k)
    if url_templates:
        has_children = True
        X('\t\t<ChildObjects>')
        for tmpl_name in url_tmpl_order:
            emit_url_template('\t\t\t', tmpl_name, url_templates[tmpl_name])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- WebService: Operations ---
if obj_type == 'WebService':
    operations = {}
    op_order = []
    if defn.get('operations'):
        for k, v in defn['operations'].items():
            operations[k] = v
            op_order.append(k)
    if operations:
        has_children = True
        X('\t\t<ChildObjects>')
        for op_name in op_order:
            emit_operation('\t\t\t', op_name, operations[op_name])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- CommonModule: no ChildObjects ---

X(f'\t</{obj_type}>')
X('</MetaDataObject>')

metadata_xml = '\n'.join(lines)

# ---------------------------------------------------------------------------
# 16. Write files
# ---------------------------------------------------------------------------

type_plural_map = {
    'Catalog': 'Catalogs',
    'Document': 'Documents',
    'Enum': 'Enums',
    'Constant': 'Constants',
    'InformationRegister': 'InformationRegisters',
    'AccumulationRegister': 'AccumulationRegisters',
    'AccountingRegister': 'AccountingRegisters',
    'CalculationRegister': 'CalculationRegisters',
    'ChartOfAccounts': 'ChartsOfAccounts',
    'ChartOfCharacteristicTypes': 'ChartsOfCharacteristicTypes',
    'ChartOfCalculationTypes': 'ChartsOfCalculationTypes',
    'BusinessProcess': 'BusinessProcesses',
    'Task': 'Tasks',
    'ExchangePlan': 'ExchangePlans',
    'DocumentJournal': 'DocumentJournals',
    'Report': 'Reports',
    'DataProcessor': 'DataProcessors',
    'CommonModule': 'CommonModules',
    'ScheduledJob': 'ScheduledJobs',
    'EventSubscription': 'EventSubscriptions',
    'HTTPService': 'HTTPServices',
    'WebService': 'WebServices',
    'DefinedType': 'DefinedTypes',
}

type_plural = type_plural_map[obj_type]
type_dir = os.path.join(output_dir, type_plural)

# Main XML file
main_xml_path = os.path.join(type_dir, f'{obj_name}.xml')

# Types that don't have subdirectory structure
types_no_sub_dir = ['DefinedType', 'ScheduledJob', 'EventSubscription']

obj_sub_dir = os.path.join(type_dir, obj_name)
ext_dir = os.path.join(obj_sub_dir, 'Ext')

os.makedirs(type_dir, exist_ok=True)
if obj_type not in types_no_sub_dir:
    os.makedirs(ext_dir, exist_ok=True)

write_utf8_bom(main_xml_path, metadata_xml)

# Module files
modules_created = []

types_with_object_module = [
    'Catalog', 'Document', 'Report', 'DataProcessor', 'ExchangePlan',
    'ChartOfAccounts', 'ChartOfCharacteristicTypes', 'ChartOfCalculationTypes',
    'BusinessProcess', 'Task',
]
types_with_record_set_module = [
    'InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister',
]
types_with_manager_module = ['Report', 'DataProcessor']
types_with_module = ['CommonModule', 'HTTPService', 'WebService']

if obj_type in types_with_object_module:
    module_path = os.path.join(ext_dir, 'ObjectModule.bsl')
    if not os.path.isfile(module_path):
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

if obj_type in types_with_manager_module:
    module_path = os.path.join(ext_dir, 'ManagerModule.bsl')
    if not os.path.isfile(module_path):
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

if obj_type in types_with_record_set_module:
    module_path = os.path.join(ext_dir, 'RecordSetModule.bsl')
    if not os.path.isfile(module_path):
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

if obj_type in types_with_module:
    module_path = os.path.join(ext_dir, 'Module.bsl')
    if not os.path.isfile(module_path):
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

# Special files
if obj_type == 'ExchangePlan':
    content_path = os.path.join(ext_dir, 'Content.xml')
    if not os.path.isfile(content_path):
        content_xml = '<?xml version="1.0" encoding="UTF-8"?>\r\n<ExchangePlanContent xmlns="http://v8.1c.ru/8.3/xcf/extrnprops" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" version="2.17"/>\r\n'
        write_utf8_bom(content_path, content_xml)
        modules_created.append(content_path)

if obj_type == 'BusinessProcess':
    flowchart_path = os.path.join(ext_dir, 'Flowchart.xml')
    if not os.path.isfile(flowchart_path):
        flowchart_xml = '<?xml version="1.0" encoding="UTF-8"?>\r\n<Flowchart xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.17"/>\r\n'
        write_utf8_bom(flowchart_path, flowchart_xml)
        modules_created.append(flowchart_path)

# ---------------------------------------------------------------------------
# 17. Register in Configuration.xml
# ---------------------------------------------------------------------------

config_xml_path = os.path.join(output_dir, 'Configuration.xml')
reg_result = None

child_tag = obj_type

if os.path.isfile(config_xml_path):
    # Parse preserving whitespace via raw string manipulation
    with open(config_xml_path, 'r', encoding='utf-8-sig') as f:
        config_content = f.read()

    ns = 'http://v8.1c.ru/8.3/MDClasses'
    ET.register_namespace('', ns)
    # Parse all namespaces used in the file
    # Use iterparse to collect namespace prefixes
    namespaces_in_file = {}
    for evt, elem in ET.iterparse(config_xml_path, events=['start-ns']):
        prefix, uri = elem
        if prefix:
            namespaces_in_file[prefix] = uri
            ET.register_namespace(prefix, uri)

    tree = ET.parse(config_xml_path)
    root = tree.getroot()

    child_objects = root.find(f'{{{ns}}}Configuration/{{{ns}}}ChildObjects')
    if child_objects is None:
        # Try direct path
        config_elem = root.find(f'{{{ns}}}Configuration')
        if config_elem is not None:
            child_objects = config_elem.find(f'{{{ns}}}ChildObjects')

    if child_objects is not None:
        existing = child_objects.findall(f'{{{ns}}}{child_tag}')
        already_exists = False
        for e in existing:
            if (e.text or '').strip() == obj_name:
                already_exists = True
                break

        if already_exists:
            reg_result = 'already'
        else:
            new_elem = ET.SubElement(child_objects, f'{{{ns}}}{child_tag}')
            new_elem.text = obj_name

            if existing:
                # Insert after last existing element of same type
                last_elem = existing[-1]
                all_children = list(child_objects)
                idx = all_children.index(last_elem)
                child_objects.remove(new_elem)
                child_objects.insert(idx + 1, new_elem)

            # Write back preserving BOM
            tree.write(config_xml_path, encoding='utf-8', xml_declaration=True)
            # Re-read to add BOM
            with open(config_xml_path, 'r', encoding='utf-8') as f:
                raw = f.read()
            write_utf8_bom(config_xml_path, raw)
            reg_result = 'added'
    else:
        reg_result = 'no-childobj'
else:
    reg_result = 'no-config'

# ---------------------------------------------------------------------------
# 18. Summary
# ---------------------------------------------------------------------------

attr_count = len(defn.get('attributes', []))
ts_count = 0
if defn.get('tabularSections'):
    ts_data = defn['tabularSections']
    if isinstance(ts_data, list):
        ts_count = len(ts_data)
    else:
        ts_count = len(ts_data)
dim_count = len(defn.get('dimensions', []))
res_count = len(defn.get('resources', []))
val_count = len(defn.get('values', []))
col_count = len(defn.get('columns', []))

print(f"[OK] {obj_type} '{obj_name}' compiled")
print(f'     UUID: {obj_uuid}')
print(f'     File: {main_xml_path}')

details = []
if attr_count > 0:
    details.append(f'Attributes: {attr_count}')
if ts_count > 0:
    details.append(f'TabularSections: {ts_count}')
if dim_count > 0:
    details.append(f'Dimensions: {dim_count}')
if res_count > 0:
    details.append(f'Resources: {res_count}')
if val_count > 0:
    details.append(f'Values: {val_count}')
if col_count > 0:
    details.append(f'Columns: {col_count}')

if details:
    print(f"     {', '.join(details)}")

for mc in modules_created:
    print(f'     Module: {mc}')

if reg_result == 'added':
    print(f'     Configuration.xml: <{child_tag}>{obj_name}</{child_tag}> added to ChildObjects')
elif reg_result == 'already':
    print(f'     Configuration.xml: <{child_tag}>{obj_name}</{child_tag}> already registered')
elif reg_result == 'no-childobj':
    print('WARNING: Configuration.xml found but <ChildObjects> not found', file=sys.stderr)
elif reg_result == 'no-config':
    print(f'     Configuration.xml: not found at {config_xml_path} (register manually)')

# Cross-reference hints
if obj_type == 'AccountingRegister' and not defn.get('chartOfAccounts'):
    print('[HINT] AccountingRegister requires ChartOfAccounts reference:')
    print('       /meta-edit -Operation modify-property -Value "ChartOfAccounts=ChartOfAccounts.XXX"')
if obj_type == 'CalculationRegister' and not defn.get('chartOfCalculationTypes'):
    print('[HINT] CalculationRegister requires ChartOfCalculationTypes reference:')
    print('       /meta-edit -Operation modify-property -Value "ChartOfCalculationTypes=ChartOfCalculationTypes.XXX"')
if obj_type == 'BusinessProcess' and not defn.get('task'):
    print('[HINT] BusinessProcess requires Task reference:')
    print('       /meta-edit -Operation modify-property -Value "Task=Task.XXX"')
if obj_type == 'ChartOfAccounts':
    max_ext_dim = int(defn['maxExtDimensionCount']) if defn.get('maxExtDimensionCount') is not None else 0
    if max_ext_dim > 0 and not defn.get('extDimensionTypes'):
        print('[HINT] ChartOfAccounts with MaxExtDimensionCount>0 requires ExtDimensionTypes:')
        print('       /meta-edit -Operation modify-property -Value "ExtDimensionTypes=ChartOfCharacteristicTypes.XXX"')
