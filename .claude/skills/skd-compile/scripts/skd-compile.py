#!/usr/bin/env python3
# skd-compile v1.1 — Compile 1C DCS from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid


def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def resolve_query_value(val, base_dir):
    if not val.startswith("@"):
        return val
    file_path = val[1:]
    if os.path.isabs(file_path):
        candidates = [file_path]
    else:
        candidates = [
            os.path.join(base_dir, file_path),
            os.path.join(os.getcwd(), file_path),
        ]
    for c in candidates:
        if os.path.exists(c):
            with open(c, 'r', encoding='utf-8-sig') as f:
                return f.read().rstrip()
    print(f"Query file not found: {file_path} (searched: {', '.join(candidates)})", file=sys.stderr)
    sys.exit(1)


def emit_mltext(lines, indent, tag, text):
    if not text:
        lines.append(f"{indent}<{tag}/>")
        return
    lines.append(f'{indent}<{tag} xsi:type="v8:LocalStringType">')
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


# --- Type system ---

TYPE_SYNONYMS = {
    # Russian names (lowercase)
    "\u0447\u0438\u0441\u043b\u043e": "decimal",
    "\u0441\u0442\u0440\u043e\u043a\u0430": "string",
    "\u0431\u0443\u043b\u0435\u0432\u043e": "boolean",
    "\u0434\u0430\u0442\u0430": "date",
    "\u0434\u0430\u0442\u0430\u0432\u0440\u0435\u043c\u044f": "dateTime",
    "\u0441\u0442\u0430\u043d\u0434\u0430\u0440\u0442\u043d\u044b\u0439\u043f\u0435\u0440\u0438\u043e\u0434": "StandardPeriod",
    # English canonical (lowercase)
    "bool": "boolean",
    "str": "string",
    "int": "decimal",
    "integer": "decimal",
    "number": "decimal",
    "num": "decimal",
    # Reference synonyms (Russian, lowercase)
    "\u0441\u043f\u0440\u0430\u0432\u043e\u0447\u043d\u0438\u043a\u0441\u0441\u044b\u043b\u043a\u0430": "CatalogRef",
    "\u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0441\u0441\u044b\u043b\u043a\u0430": "DocumentRef",
    "\u043f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u0438\u0435\u0441\u0441\u044b\u043b\u043a\u0430": "EnumRef",
    "\u043f\u043b\u0430\u043d\u0441\u0447\u0435\u0442\u043e\u0432\u0441\u0441\u044b\u043b\u043a\u0430": "ChartOfAccountsRef",
    "\u043f\u043b\u0430\u043d\u0432\u0438\u0434\u043e\u0432\u0445\u0430\u0440\u0430\u043a\u0442\u0435\u0440\u0438\u0441\u0442\u0438\u043a\u0441\u0441\u044b\u043b\u043a\u0430": "ChartOfCharacteristicTypesRef",
}


def resolve_type_str(type_str):
    if not type_str:
        return type_str

    # Check for parameterized types: число(15,2), строка(100), etc.
    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = TYPE_SYNONYMS.get(base_name.lower())
        if resolved:
            return f"{resolved}({params})"
        return type_str

    # Check for reference types: СправочникСсылка.Организации -> CatalogRef.Организации
    if '.' in type_str:
        dot_idx = type_str.index('.')
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]  # includes the dot
        resolved = TYPE_SYNONYMS.get(prefix.lower())
        if resolved:
            return f"{resolved}{suffix}"
        return type_str

    # Simple name lookup (case-insensitive)
    resolved = TYPE_SYNONYMS.get(type_str.lower())
    if resolved:
        return resolved

    return type_str


def emit_value_type(lines, type_str, indent):
    if not type_str:
        return

    # Resolve synonyms first
    type_str = resolve_type_str(type_str)

    # boolean
    if type_str == 'boolean':
        lines.append(f'{indent}<v8:Type>xs:boolean</v8:Type>')
        return

    # string or string(N)
    m = re.match(r'^string(\((\d+)\))?$', type_str)
    if m:
        length = m.group(2) if m.group(2) else '0'
        lines.append(f'{indent}<v8:Type>xs:string</v8:Type>')
        lines.append(f'{indent}<v8:StringQualifiers>')
        lines.append(f'{indent}\t<v8:Length>{length}</v8:Length>')
        lines.append(f'{indent}\t<v8:AllowedLength>Variable</v8:AllowedLength>')
        lines.append(f'{indent}</v8:StringQualifiers>')
        return

    # decimal(D,F) or decimal(D,F,nonneg)
    m = re.match(r'^decimal\((\d+),(\d+)(,nonneg)?\)$', type_str)
    if m:
        digits = m.group(1)
        fraction = m.group(2)
        sign = 'Nonnegative' if m.group(3) else 'Any'
        lines.append(f'{indent}<v8:Type>xs:decimal</v8:Type>')
        lines.append(f'{indent}<v8:NumberQualifiers>')
        lines.append(f'{indent}\t<v8:Digits>{digits}</v8:Digits>')
        lines.append(f'{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>')
        lines.append(f'{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>')
        lines.append(f'{indent}</v8:NumberQualifiers>')
        return

    # date / dateTime
    m = re.match(r'^(date|dateTime)$', type_str)
    if m:
        fractions_map = {'date': 'Date', 'dateTime': 'DateTime'}
        fractions = fractions_map[type_str]
        lines.append(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
        lines.append(f'{indent}<v8:DateQualifiers>')
        lines.append(f'{indent}\t<v8:DateFractions>{fractions}</v8:DateFractions>')
        lines.append(f'{indent}</v8:DateQualifiers>')
        return

    # StandardPeriod
    if type_str == 'StandardPeriod':
        lines.append(f'{indent}<v8:Type>v8:StandardPeriod</v8:Type>')
        return

    # Reference types: CatalogRef.XXX, DocumentRef.XXX, EnumRef.XXX, etc.
    if re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.', type_str):
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return

    # Fallback -- assume dot-qualified types are also config references
    if '.' in type_str:
        lines.append(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{esc_xml(type_str)}</v8:Type>')
        return

    lines.append(f'{indent}<v8:Type>{esc_xml(type_str)}</v8:Type>')


# --- Field shorthand parser ---

def parse_field_shorthand(s):
    result = {
        'dataPath': '', 'field': '', 'title': '', 'type': '',
        'roles': [], 'restrict': [], 'appearance': {},
    }

    # Extract @roles
    role_matches = re.findall(r'@(\w+)', s)
    for m in role_matches:
        result['roles'].append(m)
    s = re.sub(r'\s*@\w+', '', s)

    # Extract #restrictions
    restrict_matches = re.findall(r'#(\w+)', s)
    for m in restrict_matches:
        result['restrict'].append(m)
    s = re.sub(r'\s*#\w+', '', s)

    # Split name: type
    s = s.strip()
    if ':' in s:
        parts = s.split(':', 1)
        result['dataPath'] = parts[0].strip()
        result['type'] = resolve_type_str(parts[1].strip())
    else:
        result['dataPath'] = s

    result['field'] = result['dataPath']
    return result


# --- Total field shorthand parser ---

def parse_total_shorthand(s):
    parts = s.split(':', 1)
    data_path = parts[0].strip()
    func_part = parts[1].strip()

    if re.match(r'^\w+\(', func_part):
        return {'dataPath': data_path, 'expression': func_part}
    else:
        return {'dataPath': data_path, 'expression': f'{func_part}({data_path})'}


# --- Parameter shorthand parser ---

def parse_param_shorthand(s):
    result = {'name': '', 'type': '', 'value': None, 'autoDates': False}

    # Extract @autoDates flag
    if '@autoDates' in s:
        result['autoDates'] = True
        s = re.sub(r'\s*@autoDates', '', s)

    # Split "Name: Type = Value"
    m = re.match(r'^([^:]+):\s*(\S+)(\s*=\s*(.+))?$', s)
    if m:
        result['name'] = m.group(1).strip()
        result['type'] = resolve_type_str(m.group(2).strip())
        if m.group(4):
            result['value'] = m.group(4).strip()
    else:
        result['name'] = s.strip()

    return result


# --- Calculated field shorthand parser ---

def parse_calc_shorthand(s):
    idx = s.find('=')
    if idx > 0:
        return {
            'dataPath': s[:idx].strip(),
            'expression': s[idx + 1:].strip(),
        }
    return {'dataPath': s.strip(), 'expression': ''}


# --- DataParameter shorthand parser ---

PERIOD_VARIANTS = [
    "Custom", "Today", "ThisWeek", "ThisTenDays", "ThisMonth", "ThisQuarter",
    "ThisHalfYear", "ThisYear", "FromBeginningOfThisWeek", "FromBeginningOfThisTenDays",
    "FromBeginningOfThisMonth", "FromBeginningOfThisQuarter", "FromBeginningOfThisHalfYear",
    "FromBeginningOfThisYear", "LastWeek", "LastTenDays", "LastMonth", "LastQuarter",
    "LastHalfYear", "LastYear", "NextDay", "NextWeek", "NextTenDays", "NextMonth",
    "NextQuarter", "NextHalfYear", "NextYear", "TillEndOfThisWeek", "TillEndOfThisTenDays",
    "TillEndOfThisMonth", "TillEndOfThisQuarter", "TillEndOfThisHalfYear", "TillEndOfThisYear",
]


def parse_data_param_shorthand(s):
    result = {'parameter': '', 'value': None, 'use': True, 'userSettingID': None, 'viewMode': None}

    # Extract @flags
    if '@user' in s:
        result['userSettingID'] = 'auto'
        s = re.sub(r'\s*@user', '', s)
    if '@off' in s:
        result['use'] = False
        s = re.sub(r'\s*@off', '', s)
    if '@quickAccess' in s:
        result['viewMode'] = 'QuickAccess'
        s = re.sub(r'\s*@quickAccess', '', s)
    if '@normal' in s:
        result['viewMode'] = 'Normal'
        s = re.sub(r'\s*@normal', '', s)

    s = s.strip()

    # Split "Name = Value"
    m = re.match(r'^([^=]+)=\s*(.+)$', s)
    if m:
        result['parameter'] = m.group(1).strip()
        val_str = m.group(2).strip()

        if val_str in PERIOD_VARIANTS:
            result['value'] = {'variant': val_str}
        elif re.match(r'^\d{4}-\d{2}-\d{2}T', val_str):
            result['value'] = val_str
        elif val_str == 'true' or val_str == 'false':
            result['value'] = val_str == 'true'
        else:
            result['value'] = val_str
    else:
        result['parameter'] = s

    return result


# --- Filter item shorthand parser ---

def parse_filter_shorthand(s):
    result = {'field': '', 'op': 'Equal', 'value': None, 'use': True,
              'userSettingID': None, 'viewMode': None, 'presentation': None}

    # Extract @flags
    if '@user' in s:
        result['userSettingID'] = 'auto'
        s = re.sub(r'\s*@user', '', s)
    if '@off' in s:
        result['use'] = False
        s = re.sub(r'\s*@off', '', s)
    if '@quickAccess' in s:
        result['viewMode'] = 'QuickAccess'
        s = re.sub(r'\s*@quickAccess', '', s)
    if '@normal' in s:
        result['viewMode'] = 'Normal'
        s = re.sub(r'\s*@normal', '', s)
    if '@inaccessible' in s:
        result['viewMode'] = 'Inaccessible'
        s = re.sub(r'\s*@inaccessible', '', s)

    s = s.strip()

    # Operators sorted longest first
    op_patterns = [
        '<>', '>=', '<=', '=', '>', '<',
        r'notIn\b', r'in\b', r'inHierarchy\b', r'inListByHierarchy\b',
        r'notContains\b', r'contains\b', r'notBeginsWith\b', r'beginsWith\b',
        r'notFilled\b', r'filled\b',
    ]
    op_joined = '|'.join(op_patterns)

    m = re.match(rf'^(.+?)\s+({op_joined})\s*(.*)?$', s)
    if m:
        result['field'] = m.group(1).strip()
        op_raw = m.group(2).strip()
        val_part = m.group(3).strip() if m.group(3) else ''

        # Parse value (skip "_" which means empty/placeholder)
        if val_part and val_part != '_':
            if val_part == 'true' or val_part == 'false':
                result['value'] = val_part == 'true'
                result['valueType'] = 'xs:boolean'
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', val_part):
                result['value'] = val_part
                result['valueType'] = 'xs:dateTime'
            elif re.match(r'^\d+(\.\d+)?$', val_part):
                result['value'] = val_part
                result['valueType'] = 'xs:decimal'
            else:
                result['value'] = val_part
                result['valueType'] = 'xs:string'

        result['op'] = op_raw
    else:
        result['field'] = s

    return result


# --- Comparison type mapper ---

COMPARISON_TYPES = {
    '=': 'Equal', '<>': 'NotEqual',
    '>': 'Greater', '>=': 'GreaterOrEqual',
    '<': 'Less', '<=': 'LessOrEqual',
    'in': 'InList', 'notIn': 'NotInList',
    'inHierarchy': 'InHierarchy', 'inListByHierarchy': 'InListByHierarchy',
    'contains': 'Contains', 'notContains': 'NotContains',
    'beginsWith': 'BeginsWith', 'notBeginsWith': 'NotBeginsWith',
    'filled': 'Filled', 'notFilled': 'NotFilled',
}

# --- Output parameter type detection ---

OUTPUT_PARAM_TYPES = {
    "\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a": "mltext",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a": "dcsset:DataCompositionTextOutputType",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b\u0414\u0430\u043d\u043d\u044b\u0445": "dcsset:DataCompositionTextOutputType",
    "\u0412\u044b\u0432\u043e\u0434\u0438\u0442\u044c\u041e\u0442\u0431\u043e\u0440": "dcsset:DataCompositionTextOutputType",
    "\u041c\u0430\u043a\u0435\u0442\u041e\u0444\u043e\u0440\u043c\u043b\u0435\u043d\u0438\u044f": "xs:string",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041f\u043e\u043b\u0435\u0439\u0413\u0440\u0443\u043f\u043f\u0438\u0440\u043e\u0432\u043a\u0438": "dcsset:DataCompositionGroupFieldsPlacement",
    "\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u043e\u0432": "dcsset:DataCompositionAttributesPlacement",
    "\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041e\u0431\u0449\u0438\u0445\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
    "\u0412\u0435\u0440\u0442\u0438\u043a\u0430\u043b\u044c\u043d\u043e\u0435\u0420\u0430\u0441\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435\u041e\u0431\u0449\u0438\u0445\u0418\u0442\u043e\u0433\u043e\u0432": "dcscor:DataCompositionTotalPlacement",
}


# ===== Emit sections =====

def emit_data_sources(lines, data_sources):
    for ds in data_sources:
        lines.append('\t<dataSource>')
        lines.append(f'\t\t<name>{esc_xml(ds["name"])}</name>')
        lines.append(f'\t\t<dataSourceType>{esc_xml(ds["type"])}</dataSourceType>')
        lines.append('\t</dataSource>')


# === Fields ===

def emit_field(lines, field_def, indent):
    if isinstance(field_def, str):
        f = parse_field_shorthand(field_def)
    else:
        f = {
            'dataPath': str(field_def.get('dataPath', '')),
            'field': str(field_def.get('field', '')) or str(field_def.get('dataPath', '')),
            'title': str(field_def.get('title', '')) if field_def.get('title') else '',
            'type': resolve_type_str(str(field_def['type'])) if field_def.get('type') else '',
            'roles': [],
            'restrict': [],
            'appearance': {},
        }
        # Parse role
        if field_def.get('role'):
            if isinstance(field_def['role'], str):
                f['roles'] = [field_def['role']]
            else:
                # Object form -- collect truthy keys
                for k, v in field_def['role'].items():
                    if v is True:
                        f['roles'].append(k)
        # Parse restrictions
        if field_def.get('restrict'):
            f['restrict'] = list(field_def['restrict'])
        # Parse appearance
        if field_def.get('appearance'):
            for k, v in field_def['appearance'].items():
                f['appearance'][k] = str(v)
        if field_def.get('presentationExpression'):
            f['presentationExpression'] = str(field_def['presentationExpression'])
        # attrRestrict
        if field_def.get('attrRestrict'):
            f['attrRestrict'] = list(field_def['attrRestrict'])
        # role object extras
        if field_def.get('role') and not isinstance(field_def['role'], str):
            f['roleObj'] = field_def['role']

    lines.append(f'{indent}<field xsi:type="DataSetFieldField">')
    lines.append(f'{indent}\t<dataPath>{esc_xml(f["dataPath"])}</dataPath>')
    lines.append(f'{indent}\t<field>{esc_xml(f["field"])}</field>')

    # Title
    if f.get('title'):
        emit_mltext(lines, f'{indent}\t', 'title', f['title'])

    # UseRestriction
    restrict_map = {
        'noField': 'field', 'noFilter': 'condition', 'noCondition': 'condition',
        'noGroup': 'group', 'noOrder': 'order',
    }
    if f.get('restrict') and len(f['restrict']) > 0:
        lines.append(f'{indent}\t<useRestriction>')
        for r in f['restrict']:
            xml_name = restrict_map.get(str(r))
            if xml_name:
                lines.append(f'{indent}\t\t<{xml_name}>true</{xml_name}>')
        lines.append(f'{indent}\t</useRestriction>')

    # AttributeUseRestriction
    if f.get('attrRestrict') and len(f['attrRestrict']) > 0:
        lines.append(f'{indent}\t<attributeUseRestriction>')
        for r in f['attrRestrict']:
            xml_name = restrict_map.get(str(r))
            if xml_name:
                lines.append(f'{indent}\t\t<{xml_name}>true</{xml_name}>')
        lines.append(f'{indent}\t</attributeUseRestriction>')

    # Role
    if (f.get('roles') and len(f['roles']) > 0) or f.get('roleObj'):
        lines.append(f'{indent}\t<role>')
        for role in f.get('roles', []):
            if role == 'period':
                lines.append(f'{indent}\t\t<dcscom:periodNumber>1</dcscom:periodNumber>')
                lines.append(f'{indent}\t\t<dcscom:periodType>Main</dcscom:periodType>')
            else:
                lines.append(f'{indent}\t\t<dcscom:{role}>true</dcscom:{role}>')
        if f.get('roleObj'):
            ro = f['roleObj']
            if ro.get('accountTypeExpression'):
                lines.append(f'{indent}\t\t<dcscom:accountTypeExpression>{esc_xml(str(ro["accountTypeExpression"]))}</dcscom:accountTypeExpression>')
            if ro.get('balanceGroup'):
                lines.append(f'{indent}\t\t<dcscom:balanceGroup>{esc_xml(str(ro["balanceGroup"]))}</dcscom:balanceGroup>')
        lines.append(f'{indent}\t</role>')

    # ValueType
    if f.get('type'):
        lines.append(f'{indent}\t<valueType>')
        emit_value_type(lines, f['type'], f'{indent}\t\t')
        lines.append(f'{indent}\t</valueType>')

    # Appearance
    if f.get('appearance') and len(f['appearance']) > 0:
        lines.append(f'{indent}\t<appearance>')
        for key, val in f['appearance'].items():
            lines.append(f'{indent}\t\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
            lines.append(f'{indent}\t\t\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')
            if key == '\u0413\u043e\u0440\u0438\u0437\u043e\u043d\u0442\u0430\u043b\u044c\u043d\u043e\u0435\u041f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435':
                lines.append(f'{indent}\t\t\t<dcscor:value xsi:type="v8ui:HorizontalAlign">{esc_xml(val)}</dcscor:value>')
            else:
                lines.append(f'{indent}\t\t\t<dcscor:value xsi:type="xs:string">{esc_xml(val)}</dcscor:value>')
            lines.append(f'{indent}\t\t</dcscor:item>')
        lines.append(f'{indent}\t</appearance>')

    # PresentationExpression
    if f.get('presentationExpression'):
        lines.append(f'{indent}\t<presentationExpression>{esc_xml(f["presentationExpression"])}</presentationExpression>')

    lines.append(f'{indent}</field>')


# === DataSets ===

def emit_data_set(lines, ds, indent, default_source):
    # Determine type
    if ds.get('items'):
        ds_type = 'DataSetUnion'
    elif ds.get('objectName'):
        ds_type = 'DataSetObject'
    else:
        ds_type = 'DataSetQuery'

    lines.append(f'{indent}<dataSet xsi:type="{ds_type}">')
    lines.append(f'{indent}\t<name>{esc_xml(str(ds.get("name", "")))}</name>')

    # Fields
    if ds.get('fields'):
        for f in ds['fields']:
            emit_field(lines, f, f'{indent}\t')

    # DataSource (not for Union)
    if ds_type != 'DataSetUnion':
        src = str(ds['source']) if ds.get('source') else default_source
        lines.append(f'{indent}\t<dataSource>{esc_xml(src)}</dataSource>')

    # Type-specific content
    if ds_type == 'DataSetQuery':
        query_text = resolve_query_value(str(ds.get("query", "")), query_base_dir)
        lines.append(f'{indent}\t<query>{esc_xml(query_text)}</query>')
        if ds.get('autoFillFields') is False:
            lines.append(f'{indent}\t<autoFillFields>false</autoFillFields>')
    elif ds_type == 'DataSetObject':
        lines.append(f'{indent}\t<objectName>{esc_xml(str(ds["objectName"]))}</objectName>')
    elif ds_type == 'DataSetUnion':
        for item in ds['items']:
            emit_data_set(lines, item, f'{indent}\t', default_source)

    lines.append(f'{indent}</dataSet>')


def emit_data_sets(lines, defn, default_source):
    for ds in defn['dataSets']:
        emit_data_set(lines, ds, '\t', default_source)


# === DataSetLinks ===

def emit_data_set_links(lines, defn):
    if not defn.get('dataSetLinks'):
        return
    for link in defn['dataSetLinks']:
        lines.append('\t<dataSetLink>')
        lines.append(f'\t\t<sourceDataSet>{esc_xml(str(link["source"]))}</sourceDataSet>')
        lines.append(f'\t\t<destinationDataSet>{esc_xml(str(link["dest"]))}</destinationDataSet>')
        lines.append(f'\t\t<sourceExpression>{esc_xml(str(link["sourceExpr"]))}</sourceExpression>')
        lines.append(f'\t\t<destinationExpression>{esc_xml(str(link["destExpr"]))}</destinationExpression>')
        if link.get('parameter'):
            lines.append(f'\t\t<parameter>{esc_xml(str(link["parameter"]))}</parameter>')
        lines.append('\t</dataSetLink>')


# === CalculatedFields ===

def emit_calc_fields(lines, defn):
    if not defn.get('calculatedFields'):
        return
    for cf in defn['calculatedFields']:
        if isinstance(cf, str):
            parsed = parse_calc_shorthand(cf)
            is_obj = False
        else:
            parsed = {
                'dataPath': str(cf.get('dataPath', '')),
                'expression': str(cf.get('expression', '')),
            }
            is_obj = True

        lines.append('\t<calculatedField>')
        lines.append(f'\t\t<dataPath>{esc_xml(parsed["dataPath"])}</dataPath>')
        lines.append(f'\t\t<expression>{esc_xml(parsed["expression"])}</expression>')

        if is_obj:
            if cf.get('title'):
                emit_mltext(lines, '\t\t', 'title', str(cf['title']))
            if cf.get('type'):
                cf_type = resolve_type_str(str(cf['type']))
                lines.append('\t\t<valueType>')
                emit_value_type(lines, cf_type, '\t\t\t')
                lines.append('\t\t</valueType>')
            if cf.get('restrict'):
                restrict_map = {
                    'noField': 'field', 'noFilter': 'condition', 'noCondition': 'condition',
                    'noGroup': 'group', 'noOrder': 'order',
                }
                lines.append('\t\t<useRestriction>')
                for r in cf['restrict']:
                    xml_name = restrict_map.get(str(r))
                    if xml_name:
                        lines.append(f'\t\t\t<{xml_name}>true</{xml_name}>')
                lines.append('\t\t</useRestriction>')
            if cf.get('appearance'):
                lines.append('\t\t<appearance>')
                for k, v in cf['appearance'].items():
                    lines.append('\t\t\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
                    lines.append(f'\t\t\t\t<dcscor:parameter>{esc_xml(k)}</dcscor:parameter>')
                    lines.append(f'\t\t\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(v))}</dcscor:value>')
                    lines.append('\t\t\t</dcscor:item>')
                lines.append('\t\t</appearance>')

        lines.append('\t</calculatedField>')


# === TotalFields ===

def emit_total_fields(lines, defn):
    if not defn.get('totalFields'):
        return
    for tf in defn['totalFields']:
        if isinstance(tf, str):
            parsed = parse_total_shorthand(tf)
            groups = None
        else:
            parsed = {
                'dataPath': str(tf.get('dataPath', '')),
                'expression': str(tf.get('expression', '')),
            }
            groups = tf.get('group')

        lines.append('\t<totalField>')
        lines.append(f'\t\t<dataPath>{esc_xml(parsed["dataPath"])}</dataPath>')
        lines.append(f'\t\t<expression>{esc_xml(parsed["expression"])}</expression>')
        if groups:
            if isinstance(groups, list):
                for g in groups:
                    lines.append(f'\t\t<group>{esc_xml(str(g))}</group>')
            else:
                lines.append(f'\t\t<group>{esc_xml(str(groups))}</group>')
        lines.append('\t</totalField>')


# === Parameters ===

def emit_param_value(lines, type_str, val, indent):
    if val is None:
        return

    val_str = str(val)

    if type_str == 'StandardPeriod':
        lines.append(f'{indent}<value xsi:type="v8:StandardPeriod">')
        lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(val_str)}</v8:variant>')
        lines.append(f'{indent}</value>')
    elif type_str and re.match(r'^date', type_str):
        lines.append(f'{indent}<value xsi:type="xs:dateTime">{esc_xml(val_str)}</value>')
    elif type_str == 'boolean':
        lines.append(f'{indent}<value xsi:type="xs:boolean">{esc_xml(val_str)}</value>')
    elif type_str and re.match(r'^decimal', type_str):
        lines.append(f'{indent}<value xsi:type="xs:decimal">{esc_xml(val_str)}</value>')
    elif type_str and re.match(r'^string', type_str):
        lines.append(f'{indent}<value xsi:type="xs:string">{esc_xml(val_str)}</value>')
    else:
        # Guess from value
        if re.match(r'^\d{4}-\d{2}-\d{2}T', val_str):
            lines.append(f'{indent}<value xsi:type="xs:dateTime">{esc_xml(val_str)}</value>')
        elif val_str == 'true' or val_str == 'false':
            lines.append(f'{indent}<value xsi:type="xs:boolean">{esc_xml(val_str)}</value>')
        else:
            lines.append(f'{indent}<value xsi:type="xs:string">{esc_xml(val_str)}</value>')


def emit_single_param(lines, p, parsed):
    lines.append('\t<parameter>')
    lines.append(f'\t\t<name>{esc_xml(parsed["name"])}</name>')

    # Title
    title = ''
    if p is not None and not isinstance(p, str) and p.get('title'):
        title = str(p['title'])
    if title:
        emit_mltext(lines, '\t\t', 'title', title)

    # ValueType
    if parsed.get('type'):
        lines.append('\t\t<valueType>')
        emit_value_type(lines, parsed['type'], '\t\t\t')
        lines.append('\t\t</valueType>')

    # Value
    emit_param_value(lines, parsed.get('type', ''), parsed.get('value'), '\t\t')

    # UseRestriction
    if p is not None and not isinstance(p, str) and p.get('useRestriction') is True:
        lines.append('\t\t<useRestriction>true</useRestriction>')

    # Expression
    if parsed.get('expression'):
        lines.append(f'\t\t<expression>{esc_xml(parsed["expression"])}</expression>')

    # AvailableAsField
    if parsed.get('availableAsField') is False:
        lines.append('\t\t<availableAsField>false</availableAsField>')

    # Use
    if p is not None and not isinstance(p, str) and p.get('use'):
        lines.append(f'\t\t<use>{esc_xml(str(p["use"]))}</use>')

    lines.append('\t</parameter>')


def emit_parameters(lines, defn):
    if not defn.get('parameters'):
        return
    for p in defn['parameters']:
        if isinstance(p, str):
            parsed = parse_param_shorthand(p)
        else:
            parsed = {
                'name': str(p.get('name', '')),
                'type': resolve_type_str(str(p['type'])) if p.get('type') else '',
                'value': p.get('value'),
                'autoDates': False,
            }
            if p.get('expression'):
                parsed['expression'] = str(p['expression'])
            if p.get('availableAsField') is False:
                parsed['availableAsField'] = False
            if p.get('autoDates') is True:
                parsed['autoDates'] = True

        emit_single_param(lines, p, parsed)

        # @autoDates: auto-generate ДатаНачала and ДатаОкончания
        if parsed.get('autoDates'):
            param_name = parsed['name']
            begin_parsed = {
                'name': '\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430',
                'type': 'date', 'value': None,
                'expression': f'&{param_name}.\u0414\u0430\u0442\u0430\u041d\u0430\u0447\u0430\u043b\u0430',
                'availableAsField': False,
            }
            emit_single_param(lines, None, begin_parsed)
            end_parsed = {
                'name': '\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f',
                'type': 'date', 'value': None,
                'expression': f'&{param_name}.\u0414\u0430\u0442\u0430\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u044f',
                'availableAsField': False,
            }
            emit_single_param(lines, None, end_parsed)


# === Templates ===

def emit_templates(lines, defn):
    if not defn.get('templates'):
        return
    for t in defn['templates']:
        lines.append('\t<template>')
        lines.append(f'\t\t<name>{esc_xml(str(t["name"]))}</name>')
        if t.get('template'):
            lines.append(f'\t\t{t["template"]}')
        if t.get('parameters'):
            for tp in t['parameters']:
                lines.append('\t\t<parameter xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template" xsi:type="dcsat:ExpressionAreaTemplateParameter">')
                lines.append(f'\t\t\t<dcsat:name>{esc_xml(str(tp["name"]))}</dcsat:name>')
                lines.append(f'\t\t\t<dcsat:expression>{esc_xml(str(tp["expression"]))}</dcsat:expression>')
                lines.append('\t\t</parameter>')
        lines.append('\t</template>')


# === GroupTemplates ===

def emit_group_templates(lines, defn):
    if not defn.get('groupTemplates'):
        return
    for gt in defn['groupTemplates']:
        lines.append('\t<groupTemplate>')
        lines.append(f'\t\t<groupField>{esc_xml(str(gt["groupField"]))}</groupField>')
        lines.append(f'\t\t<templateType>{esc_xml(str(gt["templateType"]))}</templateType>')
        lines.append(f'\t\t<template>{esc_xml(str(gt["template"]))}</template>')
        lines.append('\t</groupTemplate>')


# === Settings Variants ===

def emit_selection(lines, items, indent, skip_auto=False):
    if not items or len(items) == 0:
        return

    lines.append(f'{indent}<dcsset:selection>')
    for item in items:
        if isinstance(item, str):
            if item == 'Auto':
                if not skip_auto:
                    lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:SelectedItemAuto"/>')
            else:
                lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:SelectedItemField">')
                lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(item)}</dcsset:field>')
                lines.append(f'{indent}\t</dcsset:item>')
        else:
            lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:SelectedItemField">')
            lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(str(item["field"]))}</dcsset:field>')
            if item.get('title'):
                lines.append(f'{indent}\t\t<dcsset:lwsTitle>')
                lines.append(f'{indent}\t\t\t<v8:item>')
                lines.append(f'{indent}\t\t\t\t<v8:lang>ru</v8:lang>')
                lines.append(f'{indent}\t\t\t\t<v8:content>{esc_xml(str(item["title"]))}</v8:content>')
                lines.append(f'{indent}\t\t\t</v8:item>')
                lines.append(f'{indent}\t\t</dcsset:lwsTitle>')
            lines.append(f'{indent}\t</dcsset:item>')
    lines.append(f'{indent}</dcsset:selection>')


def emit_filter_item(lines, item, indent):
    if item.get('group'):
        # FilterItemGroup
        group_type_map = {'And': 'AndGroup', 'Or': 'OrGroup', 'Not': 'NotGroup'}
        group_type = group_type_map.get(str(item['group']), f'{item["group"]}Group')
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:FilterItemGroup">')
        lines.append(f'{indent}\t<dcsset:groupType>{group_type}</dcsset:groupType>')
        if item.get('items'):
            for sub in item['items']:
                emit_filter_item(lines, sub, f'{indent}\t')
        lines.append(f'{indent}</dcsset:item>')
        return

    # FilterItemComparison
    lines.append(f'{indent}<dcsset:item xsi:type="dcsset:FilterItemComparison">')

    if item.get('use') is False:
        lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')

    lines.append(f'{indent}\t<dcsset:left xsi:type="dcscor:Field">{esc_xml(str(item["field"]))}</dcsset:left>')

    comp_type = COMPARISON_TYPES.get(str(item.get('op', '')), str(item.get('op', '')))
    lines.append(f'{indent}\t<dcsset:comparisonType>{esc_xml(comp_type)}</dcsset:comparisonType>')

    # Right value
    if item.get('value') is not None:
        vt = str(item.get('valueType', '')) if item.get('valueType') else ''
        if not vt:
            v = item['value']
            if isinstance(v, bool):
                vt = 'xs:boolean'
            elif isinstance(v, (int, float)):
                vt = 'xs:decimal'
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(v)):
                vt = 'xs:dateTime'
            else:
                vt = 'xs:string'
        if isinstance(item['value'], bool):
            v_str = str(item['value']).lower()
        else:
            v_str = esc_xml(str(item['value']))
        lines.append(f'{indent}\t<dcsset:right xsi:type="{vt}">{v_str}</dcsset:right>')

    if item.get('presentation'):
        lines.append(f'{indent}\t<dcsset:presentation xsi:type="v8:LocalStringType">')
        lines.append(f'{indent}\t\t<v8:item>')
        lines.append(f'{indent}\t\t\t<v8:lang>ru</v8:lang>')
        lines.append(f'{indent}\t\t\t<v8:content>{esc_xml(str(item["presentation"]))}</v8:content>')
        lines.append(f'{indent}\t\t</v8:item>')
        lines.append(f'{indent}\t</dcsset:presentation>')

    if item.get('viewMode'):
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')

    if item.get('userSettingID'):
        uid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')

    if item.get('userSettingPresentation'):
        lines.append(f'{indent}\t<dcsset:userSettingPresentation xsi:type="v8:LocalStringType">')
        lines.append(f'{indent}\t\t<v8:item>')
        lines.append(f'{indent}\t\t\t<v8:lang>ru</v8:lang>')
        lines.append(f'{indent}\t\t\t<v8:content>{esc_xml(str(item["userSettingPresentation"]))}</v8:content>')
        lines.append(f'{indent}\t\t</v8:item>')
        lines.append(f'{indent}\t</dcsset:userSettingPresentation>')

    lines.append(f'{indent}</dcsset:item>')


def emit_filter(lines, items, indent):
    if not items or len(items) == 0:
        return

    lines.append(f'{indent}<dcsset:filter>')
    for item in items:
        if isinstance(item, str):
            parsed = parse_filter_shorthand(item)
            filter_obj = {
                'field': parsed['field'],
                'op': parsed['op'],
            }
            if parsed['use'] is False:
                filter_obj['use'] = False
            if parsed.get('value') is not None:
                filter_obj['value'] = parsed['value']
            if parsed.get('valueType'):
                filter_obj['valueType'] = parsed['valueType']
            if parsed.get('userSettingID'):
                filter_obj['userSettingID'] = parsed['userSettingID']
            if parsed.get('viewMode'):
                filter_obj['viewMode'] = parsed['viewMode']
            emit_filter_item(lines, filter_obj, f'{indent}\t')
        else:
            emit_filter_item(lines, item, f'{indent}\t')
    lines.append(f'{indent}</dcsset:filter>')


def emit_order(lines, items, indent, skip_auto=False):
    if not items or len(items) == 0:
        return

    lines.append(f'{indent}<dcsset:order>')
    for item in items:
        if isinstance(item, str):
            if item == 'Auto':
                if not skip_auto:
                    lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemAuto"/>')
            else:
                parts = item.split()
                field = parts[0]
                direction = 'Asc'
                if len(parts) > 1 and re.match(r'^(?i)desc$', parts[1]):
                    direction = 'Desc'
                elif len(parts) > 1 and re.match(r'^(?i)asc$', parts[1]):
                    direction = 'Asc'
                lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemField">')
                lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(field)}</dcsset:field>')
                lines.append(f'{indent}\t\t<dcsset:orderType>{direction}</dcsset:orderType>')
                lines.append(f'{indent}\t</dcsset:item>')
    lines.append(f'{indent}</dcsset:order>')


def emit_appearance_value(lines, key, val, indent):
    lines.append(f'{indent}<dcscor:item xsi:type="dcsset:SettingsParameterValue">')

    if isinstance(val, dict) and val.get('use') is False:
        lines.append(f'{indent}\t<dcscor:use>false</dcscor:use>')
        lines.append(f'{indent}\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')
        actual_val = str(val.get('value', ''))
    else:
        lines.append(f'{indent}\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')
        actual_val = str(val)

    # Auto-detect value type
    if re.match(r'^(style|web|win):', actual_val):
        lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Color">{esc_xml(actual_val)}</dcscor:value>')
    elif actual_val == 'true' or actual_val == 'false':
        lines.append(f'{indent}\t<dcscor:value xsi:type="xs:boolean">{actual_val}</dcscor:value>')
    elif key == '\u0422\u0435\u043a\u0441\u0442' or key == '\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a':
        lines.append(f'{indent}\t<dcscor:value xsi:type="v8:LocalStringType">')
        lines.append(f'{indent}\t\t<v8:item>')
        lines.append(f'{indent}\t\t\t<v8:lang>ru</v8:lang>')
        lines.append(f'{indent}\t\t\t<v8:content>{esc_xml(actual_val)}</v8:content>')
        lines.append(f'{indent}\t\t</v8:item>')
        lines.append(f'{indent}\t</dcscor:value>')
    else:
        lines.append(f'{indent}\t<dcscor:value xsi:type="xs:string">{esc_xml(actual_val)}</dcscor:value>')
    lines.append(f'{indent}</dcscor:item>')


def emit_conditional_appearance(lines, items, indent):
    if not items or len(items) == 0:
        return

    lines.append(f'{indent}<dcsset:conditionalAppearance>')
    for ca in items:
        lines.append(f'{indent}\t<dcsset:item>')

        # Selection
        if ca.get('selection') and len(ca['selection']) > 0:
            lines.append(f'{indent}\t\t<dcsset:selection>')
            for sel in ca['selection']:
                lines.append(f'{indent}\t\t\t<dcsset:item>')
                lines.append(f'{indent}\t\t\t\t<dcsset:field>{esc_xml(str(sel))}</dcsset:field>')
                lines.append(f'{indent}\t\t\t</dcsset:item>')
            lines.append(f'{indent}\t\t</dcsset:selection>')
        else:
            lines.append(f'{indent}\t\t<dcsset:selection/>')

        # Filter
        if ca.get('filter'):
            emit_filter(lines, ca['filter'], f'{indent}\t\t')

        # Appearance
        if ca.get('appearance'):
            lines.append(f'{indent}\t\t<dcsset:appearance>')
            for k, v in ca['appearance'].items():
                emit_appearance_value(lines, k, v, f'{indent}\t\t\t')
            lines.append(f'{indent}\t\t</dcsset:appearance>')

        # Presentation
        if ca.get('presentation'):
            lines.append(f'{indent}\t\t<dcsset:presentation xsi:type="xs:string">{esc_xml(str(ca["presentation"]))}</dcsset:presentation>')

        # ViewMode
        if ca.get('viewMode'):
            lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(ca["viewMode"]))}</dcsset:viewMode>')

        # UserSettingID
        if ca.get('userSettingID'):
            uid = new_uuid() if str(ca['userSettingID']) == 'auto' else str(ca['userSettingID'])
            lines.append(f'{indent}\t\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')

        lines.append(f'{indent}\t</dcsset:item>')
    lines.append(f'{indent}</dcsset:conditionalAppearance>')


def emit_output_parameters(lines, params, indent):
    if not params:
        return

    lines.append(f'{indent}<dcsset:outputParameters>')
    for key, val in params.items():
        val_str = str(val)
        ptype = OUTPUT_PARAM_TYPES.get(key, 'xs:string')

        lines.append(f'{indent}\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
        lines.append(f'{indent}\t\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')
        if ptype == 'mltext':
            lines.append(f'{indent}\t\t<dcscor:value xsi:type="v8:LocalStringType">')
            lines.append(f'{indent}\t\t\t<v8:item>')
            lines.append(f'{indent}\t\t\t\t<v8:lang>ru</v8:lang>')
            lines.append(f'{indent}\t\t\t\t<v8:content>{esc_xml(val_str)}</v8:content>')
            lines.append(f'{indent}\t\t\t</v8:item>')
            lines.append(f'{indent}\t\t</dcscor:value>')
        else:
            lines.append(f'{indent}\t\t<dcscor:value xsi:type="{ptype}">{esc_xml(val_str)}</dcscor:value>')
        lines.append(f'{indent}\t</dcscor:item>')
    lines.append(f'{indent}</dcsset:outputParameters>')


def emit_data_parameters(lines, items, indent):
    if not items or len(items) == 0:
        return

    lines.append(f'{indent}<dcsset:dataParameters>')
    for dp in items:
        # Support string shorthand
        if isinstance(dp, str):
            parsed = parse_data_param_shorthand(dp)
            dp = {
                'parameter': parsed['parameter'],
            }
            if parsed.get('value') is not None:
                dp['value'] = parsed['value']
            if parsed['use'] is False:
                dp['use'] = False
            if parsed.get('userSettingID'):
                dp['userSettingID'] = parsed['userSettingID']
            if parsed.get('viewMode'):
                dp['viewMode'] = parsed['viewMode']

        lines.append(f'{indent}\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')

        if dp.get('use') is False:
            lines.append(f'{indent}\t\t<dcscor:use>false</dcscor:use>')

        lines.append(f'{indent}\t\t<dcscor:parameter>{esc_xml(str(dp["parameter"]))}</dcscor:parameter>')

        # Value
        if dp.get('value') is not None:
            val = dp['value']
            if isinstance(val, dict) and val.get('variant'):
                # StandardPeriod
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="v8:StandardPeriod">')
                lines.append(f'{indent}\t\t\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(str(val["variant"]))}</v8:variant>')
                lines.append(f'{indent}\t\t</dcscor:value>')
            elif isinstance(val, bool):
                bv = str(val).lower()
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:boolean">{esc_xml(bv)}</dcscor:value>')
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', str(val)):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:dateTime">{esc_xml(str(val))}</dcscor:value>')
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')

        if dp.get('viewMode'):
            lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(dp["viewMode"]))}</dcsset:viewMode>')

        if dp.get('userSettingID'):
            uid = new_uuid() if str(dp['userSettingID']) == 'auto' else str(dp['userSettingID'])
            lines.append(f'{indent}\t\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')

        if dp.get('userSettingPresentation'):
            lines.append(f'{indent}\t\t<dcsset:userSettingPresentation xsi:type="v8:LocalStringType">')
            lines.append(f'{indent}\t\t\t<v8:item>')
            lines.append(f'{indent}\t\t\t\t<v8:lang>ru</v8:lang>')
            lines.append(f'{indent}\t\t\t\t<v8:content>{esc_xml(str(dp["userSettingPresentation"]))}</v8:content>')
            lines.append(f'{indent}\t\t\t</v8:item>')
            lines.append(f'{indent}\t\t</dcsset:userSettingPresentation>')

        lines.append(f'{indent}\t</dcscor:item>')
    lines.append(f'{indent}</dcsset:dataParameters>')


# === Structure items (recursive) ===

def emit_group_items(lines, group_by, indent):
    if not group_by or len(group_by) == 0:
        return

    lines.append(f'{indent}<dcsset:groupItems>')
    for field in group_by:
        if isinstance(field, str):
            lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:GroupItemField">')
            lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(field)}</dcsset:field>')
            lines.append(f'{indent}\t\t<dcsset:groupType>Items</dcsset:groupType>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionBegin xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionBegin>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionEnd xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionEnd>')
            lines.append(f'{indent}\t</dcsset:item>')
        else:
            lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:GroupItemField">')
            lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(str(field["field"]))}</dcsset:field>')
            gt = str(field.get('groupType', 'Items'))
            lines.append(f'{indent}\t\t<dcsset:groupType>{esc_xml(gt)}</dcsset:groupType>')
            pat = str(field.get('periodAdditionType', 'None'))
            lines.append(f'{indent}\t\t<dcsset:periodAdditionType>{esc_xml(pat)}</dcsset:periodAdditionType>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionBegin xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionBegin>')
            lines.append(f'{indent}\t\t<dcsset:periodAdditionEnd xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionEnd>')
            lines.append(f'{indent}\t</dcsset:item>')
    lines.append(f'{indent}</dcsset:groupItems>')


def parse_structure_shorthand(s):
    segments = re.split(r'\s*>\s*', s)
    innermost = None
    for i in range(len(segments) - 1, -1, -1):
        seg = segments[i].strip()
        group = {'type': 'group'}

        if re.match(r'^(?i)(details|\u0434\u0435\u0442\u0430\u043b\u0438)$', seg):
            group['groupBy'] = []
        else:
            group['groupBy'] = [seg]

        if innermost is not None:
            group['children'] = [innermost]
        innermost = group

    if innermost:
        return [innermost]
    return []


def emit_structure_item(lines, item, indent):
    item_type = str(item.get('type', ''))

    if item_type == 'group':
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemGroup">')

        if item.get('name'):
            lines.append(f'{indent}\t<dcsset:name>{esc_xml(str(item["name"]))}</dcsset:name>')

        emit_group_items(lines, item.get('groupBy'), f'{indent}\t')

        # Default order to ["Auto"] if not specified
        order_items = item.get('order') or ['Auto']
        emit_order(lines, order_items, f'{indent}\t')

        # Default selection to ["Auto"] if not specified
        sel_items = item.get('selection') or ['Auto']
        emit_selection(lines, sel_items, f'{indent}\t')

        emit_filter(lines, item.get('filter'), f'{indent}\t')

        if item.get('outputParameters'):
            emit_output_parameters(lines, item['outputParameters'], f'{indent}\t')

        # Nested children
        if item.get('children'):
            for child in item['children']:
                emit_structure_item(lines, child, f'{indent}\t')

        lines.append(f'{indent}</dcsset:item>')

    elif item_type == 'table':
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemTable">')

        if item.get('name'):
            lines.append(f'{indent}\t<dcsset:name>{esc_xml(str(item["name"]))}</dcsset:name>')

        # Columns
        if item.get('columns'):
            for col in item['columns']:
                lines.append(f'{indent}\t<dcsset:column>')
                emit_group_items(lines, col.get('groupBy'), f'{indent}\t\t')
                col_order = col.get('order') or ['Auto']
                emit_order(lines, col_order, f'{indent}\t\t')
                col_sel = col.get('selection') or ['Auto']
                emit_selection(lines, col_sel, f'{indent}\t\t')
                lines.append(f'{indent}\t</dcsset:column>')

        # Rows
        if item.get('rows'):
            for row in item['rows']:
                lines.append(f'{indent}\t<dcsset:row>')
                if row.get('name'):
                    lines.append(f'{indent}\t\t<dcsset:name>{esc_xml(str(row["name"]))}</dcsset:name>')
                emit_group_items(lines, row.get('groupBy'), f'{indent}\t\t')
                row_order = row.get('order') or ['Auto']
                emit_order(lines, row_order, f'{indent}\t\t')
                row_sel = row.get('selection') or ['Auto']
                emit_selection(lines, row_sel, f'{indent}\t\t')
                lines.append(f'{indent}\t</dcsset:row>')

        lines.append(f'{indent}</dcsset:item>')

    elif item_type == 'chart':
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemChart">')

        if item.get('name'):
            lines.append(f'{indent}\t<dcsset:name>{esc_xml(str(item["name"]))}</dcsset:name>')

        # Points
        if item.get('points'):
            lines.append(f'{indent}\t<dcsset:point>')
            emit_group_items(lines, item['points'].get('groupBy'), f'{indent}\t\t')
            pt_order = item['points'].get('order') or ['Auto']
            emit_order(lines, pt_order, f'{indent}\t\t')
            pt_sel = item['points'].get('selection') or ['Auto']
            emit_selection(lines, pt_sel, f'{indent}\t\t')
            lines.append(f'{indent}\t</dcsset:point>')

        # Series
        if item.get('series'):
            lines.append(f'{indent}\t<dcsset:series>')
            emit_group_items(lines, item['series'].get('groupBy'), f'{indent}\t\t')
            sr_order = item['series'].get('order') or ['Auto']
            emit_order(lines, sr_order, f'{indent}\t\t')
            sr_sel = item['series'].get('selection') or ['Auto']
            emit_selection(lines, sr_sel, f'{indent}\t\t')
            lines.append(f'{indent}\t</dcsset:series>')

        # Selection (chart values)
        emit_selection(lines, item.get('selection'), f'{indent}\t')

        if item.get('outputParameters'):
            emit_output_parameters(lines, item['outputParameters'], f'{indent}\t')

        lines.append(f'{indent}</dcsset:item>')


def emit_settings_variants(lines, defn):
    variants = defn.get('settingsVariants')

    # Default variant if none specified
    if not variants or len(variants) == 0:
        variants = [{
            'name': '\u041e\u0441\u043d\u043e\u0432\u043d\u043e\u0439',
            'presentation': '\u041e\u0441\u043d\u043e\u0432\u043d\u043e\u0439',
            'settings': {
                'selection': ['Auto'],
                'structure': [{
                    'type': 'group',
                    'order': ['Auto'],
                    'selection': ['Auto'],
                }],
            },
        }]

    for v in variants:
        lines.append('\t<settingsVariant>')
        lines.append(f'\t\t<dcsset:name>{esc_xml(str(v["name"]))}</dcsset:name>')

        pres = str(v.get('presentation', '')) or str(v['name'])
        lines.append('\t\t<dcsset:presentation xsi:type="v8:LocalStringType">')
        lines.append('\t\t\t<v8:item>')
        lines.append('\t\t\t\t<v8:lang>ru</v8:lang>')
        lines.append(f'\t\t\t\t<v8:content>{esc_xml(pres)}</v8:content>')
        lines.append('\t\t\t</v8:item>')
        lines.append('\t\t</dcsset:presentation>')

        lines.append('\t\t<dcsset:settings xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows">')

        s = v.get('settings', {})

        # Selection
        if s.get('selection'):
            emit_selection(lines, s['selection'], '\t\t\t', skip_auto=True)

        # Filter
        if s.get('filter'):
            emit_filter(lines, s['filter'], '\t\t\t')

        # Order
        if s.get('order'):
            emit_order(lines, s['order'], '\t\t\t', skip_auto=True)

        # ConditionalAppearance
        if s.get('conditionalAppearance'):
            emit_conditional_appearance(lines, s['conditionalAppearance'], '\t\t\t')

        # OutputParameters
        if s.get('outputParameters'):
            emit_output_parameters(lines, s['outputParameters'], '\t\t\t')

        # DataParameters
        if s.get('dataParameters'):
            emit_data_parameters(lines, s['dataParameters'], '\t\t\t')

        # Structure (supports string shorthand)
        if s.get('structure'):
            struct_items = s['structure']
            if isinstance(struct_items, str):
                struct_items = parse_structure_shorthand(struct_items)
            for item in struct_items:
                emit_structure_item(lines, item, '\t\t\t')

        lines.append('\t\t</dcsset:settings>')
        lines.append('\t</settingsVariant>')


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C DCS from JSON', allow_abbrev=False)
    parser.add_argument('-DefinitionFile', type=str, default=None)
    parser.add_argument('-Value', type=str, default=None)
    parser.add_argument('-OutputPath', type=str, required=True)
    args = parser.parse_args()

    # --- 1. Load and validate JSON ---
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

    if not defn.get('dataSets') or len(defn['dataSets']) == 0:
        print("JSON must have at least one entry in 'dataSets'", file=sys.stderr)
        sys.exit(1)

    # Base directory for resolving @file references in query
    global query_base_dir
    query_base_dir = os.path.dirname(def_file) if args.DefinitionFile else os.getcwd()

    # --- 2. Resolve defaults ---

    # DataSources
    data_sources = []
    if defn.get('dataSources'):
        for ds in defn['dataSources']:
            data_sources.append({
                'name': str(ds['name']),
                'type': str(ds.get('type', 'Local')),
            })
    else:
        data_sources.append({'name': '\u0418\u0441\u0442\u043e\u0447\u043d\u0438\u043a\u0414\u0430\u043d\u043d\u044b\u04451', 'type': 'Local'})

    default_source = data_sources[0]['name']

    # Auto-name dataSets
    ds_index = 1
    for ds in defn['dataSets']:
        if not ds.get('name'):
            ds['name'] = f'\u041d\u0430\u0431\u043e\u0440\u0414\u0430\u043d\u043d\u044b\u0445{ds_index}'
        ds_index += 1

    # --- 3. Assemble XML ---
    lines = []

    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"')
    lines.append('\t\txmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"')
    lines.append('\t\txmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"')
    lines.append('\t\txmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"')
    lines.append('\t\txmlns:v8="http://v8.1c.ru/8.1/data/core"')
    lines.append('\t\txmlns:v8ui="http://v8.1c.ru/8.1/data/ui"')
    lines.append('\t\txmlns:xs="http://www.w3.org/2001/XMLSchema"')
    lines.append('\t\txmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">')

    emit_data_sources(lines, data_sources)
    emit_data_sets(lines, defn, default_source)
    emit_data_set_links(lines, defn)
    emit_calc_fields(lines, defn)
    emit_total_fields(lines, defn)
    emit_parameters(lines, defn)
    emit_templates(lines, defn)
    emit_group_templates(lines, defn)
    emit_settings_variants(lines, defn)

    lines.append('</DataCompositionSchema>')

    # --- 4. Write output ---
    output_path = args.OutputPath
    if not os.path.isabs(output_path):
        output_path = os.path.join(os.getcwd(), output_path)

    parent_dir = os.path.dirname(output_path)
    if parent_dir and not os.path.exists(parent_dir):
        os.makedirs(parent_dir, exist_ok=True)

    content = '\n'.join(lines) + '\n'
    write_utf8_bom(output_path, content)

    # --- 5. Statistics ---
    ds_count = len(defn['dataSets'])
    field_count = 0
    for ds in defn['dataSets']:
        if ds.get('fields'):
            field_count += len(ds['fields'])
    calc_count = len(defn['calculatedFields']) if defn.get('calculatedFields') else 0
    total_count = len(defn['totalFields']) if defn.get('totalFields') else 0
    param_count = len(defn['parameters']) if defn.get('parameters') else 0
    variant_count = len(defn['settingsVariants']) if defn.get('settingsVariants') else 1
    file_size = os.path.getsize(output_path)

    print(f"OK  {args.OutputPath}")
    print(f"    DataSets: {ds_count}  Fields: {field_count}  Calculated: {calc_count}  Totals: {total_count}  Params: {param_count}  Variants: {variant_count}")
    print(f"    Size: {file_size} bytes")


if __name__ == '__main__':
    main()
