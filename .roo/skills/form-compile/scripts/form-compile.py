#!/usr/bin/env python3
# form-compile v1.172 — Compile 1C managed form from JSON or object metadata
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import copy
import json
import os
import re
import sys
import uuid
import xml.etree.ElementTree as ET
from collections import OrderedDict

# ═══════════════════════════════════════════════════════════════════════════
# FROM-OBJECT MODE: functions for metadata parsing, presets, DSL generation
# ═══════════════════════════════════════════════════════════════════════════

NS = {
    'md': 'http://v8.1c.ru/8.3/MDClasses',
    'xr': 'http://v8.1c.ru/8.3/xcf/readable',
    'v8': 'http://v8.1c.ru/8.1/data/core',
}


def _et_find(node, path):
    """Find with namespace map."""
    return node.find(path, NS)


def _et_findall(node, path):
    """Findall with namespace map."""
    return node.findall(path, NS)


def _et_text(node, path, default=''):
    """Get text of a sub-element, or default."""
    el = node.find(path, NS)
    return el.text if el is not None and el.text else default


def parse_object_meta(object_path):
    """Parse 1C metadata XML and return dict with Type, Name, Synonym, Attributes, TabularSections, etc."""
    tree = ET.parse(object_path)
    root = tree.getroot()

    # Detect object type from root child
    meta_root = _et_find(root, '.')
    # Root is MetaDataObject; first child is the type node
    type_node = None
    for child in root:
        type_node = child
        break
    if type_node is None:
        print("Not a 1C metadata XML: " + object_path, file=sys.stderr)
        sys.exit(1)

    # Extract local name (strip namespace)
    obj_type = type_node.tag.split('}')[-1] if '}' in type_node.tag else type_node.tag

    props_node = _et_find(type_node, 'md:Properties')
    child_objs = _et_find(type_node, 'md:ChildObjects')

    # Name
    obj_name = _et_text(props_node, 'md:Name')

    # Synonym (Russian)
    synonym = obj_name
    syn_node = _et_find(props_node, "md:Synonym/v8:item[v8:lang='ru']/v8:content")
    if syn_node is not None and syn_node.text:
        synonym = syn_node.text

    def extract_type(type_parent):
        """Extract type string from md:Type element."""
        if type_parent is None:
            return 'string'
        types = []
        for t in _et_findall(type_parent, 'v8:Type'):
            if t.text:
                types.append(t.text)
        if not types:
            return 'string'
        return ' | '.join(types)

    def is_ref_type(t):
        return bool(re.search(r'Ref\.', t) or re.search(r'\u0441\u0441\u044b\u043b\u043a\u0430\.', t))

    def extract_fields(parent_node, tag_name='Attribute'):
        """Extract field list from ChildObjects by tag name (Attribute, Dimension, Resource, AccountingFlag, ExtDimensionAccountingFlag)."""
        result = []
        if parent_node is None:
            return result
        for field_node in _et_findall(parent_node, f'md:{tag_name}'):
            fp = _et_find(field_node, 'md:Properties')
            f_name = _et_text(fp, 'md:Name')
            f_syn_node = _et_find(fp, "md:Synonym/v8:item[v8:lang='ru']/v8:content")
            f_syn = f_syn_node.text if f_syn_node is not None and f_syn_node.text else f_name
            f_type_node = _et_find(fp, 'md:Type')
            f_type = extract_type(f_type_node)
            result.append({
                'Name': f_name,
                'Synonym': f_syn,
                'Type': f_type,
                'IsRef': is_ref_type(f_type),
            })
        return result

    # Attributes
    attributes = extract_fields(child_objs, 'Attribute')

    # Tabular sections
    tabular_sections = []
    if child_objs is not None:
        for ts_node in _et_findall(child_objs, 'md:TabularSection'):
            tsp = _et_find(ts_node, 'md:Properties')
            ts_name = _et_text(tsp, 'md:Name')
            ts_syn_node = _et_find(tsp, "md:Synonym/v8:item[v8:lang='ru']/v8:content")
            ts_syn = ts_syn_node.text if ts_syn_node is not None and ts_syn_node.text else ts_name
            ts_co = _et_find(ts_node, 'md:ChildObjects')
            ts_cols = extract_fields(ts_co, 'Attribute')
            tabular_sections.append({
                'Name': ts_name,
                'Synonym': ts_syn,
                'Columns': ts_cols,
            })

    meta = {
        'Type': obj_type,
        'Name': obj_name,
        'Synonym': synonym,
        'Attributes': attributes,
        'TabularSections': tabular_sections,
    }

    # Type-specific properties
    if obj_type == 'Document':
        nt_node = _et_find(props_node, 'md:NumberType')
        meta['NumberType'] = nt_node.text if nt_node is not None and nt_node.text else 'String'
    elif obj_type == 'Catalog':
        cl_node = _et_find(props_node, 'md:CodeLength')
        meta['CodeLength'] = int(cl_node.text) if cl_node is not None and cl_node.text else 0
        dl_node = _et_find(props_node, 'md:DescriptionLength')
        meta['DescriptionLength'] = int(dl_node.text) if dl_node is not None and dl_node.text else 0
        hi_node = _et_find(props_node, 'md:Hierarchical')
        meta['Hierarchical'] = (hi_node is not None and hi_node.text == 'true')
        ht_node = _et_find(props_node, 'md:HierarchyType')
        meta['HierarchyType'] = ht_node.text if ht_node is not None and ht_node.text else 'HierarchyFoldersAndItems'
        owners = []
        for ow in _et_findall(props_node, 'md:Owners/xr:Item'):
            if ow.text:
                owners.append(ow.text)
        meta['Owners'] = owners
    elif obj_type == 'InformationRegister':
        meta['Dimensions'] = extract_fields(child_objs, 'Dimension')
        meta['Resources'] = extract_fields(child_objs, 'Resource')
        prd_node = _et_find(props_node, 'md:InformationRegisterPeriodicity')
        meta['Periodicity'] = prd_node.text if prd_node is not None and prd_node.text else 'Nonperiodical'
        wm_node = _et_find(props_node, 'md:WriteMode')
        meta['WriteMode'] = wm_node.text if wm_node is not None and wm_node.text else 'Independent'
    elif obj_type == 'AccumulationRegister':
        meta['Dimensions'] = extract_fields(child_objs, 'Dimension')
        meta['Resources'] = extract_fields(child_objs, 'Resource')
        rt_node = _et_find(props_node, 'md:RegisterType')
        meta['RegisterType'] = rt_node.text if rt_node is not None and rt_node.text else 'Balances'
    elif obj_type == 'ChartOfCharacteristicTypes':
        cl_node = _et_find(props_node, 'md:CodeLength')
        meta['CodeLength'] = int(cl_node.text) if cl_node is not None and cl_node.text else 0
        dl_node = _et_find(props_node, 'md:DescriptionLength')
        meta['DescriptionLength'] = int(dl_node.text) if dl_node is not None and dl_node.text else 0
        hi_node = _et_find(props_node, 'md:Hierarchical')
        meta['Hierarchical'] = (hi_node is not None and hi_node.text == 'true')
        ht_node = _et_find(props_node, 'md:HierarchyType')
        meta['HierarchyType'] = ht_node.text if ht_node is not None and ht_node.text else 'HierarchyFoldersAndItems'
        owners = []
        for ow in _et_findall(props_node, 'md:Owners/xr:Item'):
            if ow.text:
                owners.append(ow.text)
        meta['Owners'] = owners
        meta['HasValueType'] = True
    elif obj_type == 'ExchangePlan':
        cl_node = _et_find(props_node, 'md:CodeLength')
        meta['CodeLength'] = int(cl_node.text) if cl_node is not None and cl_node.text else 0
        dl_node = _et_find(props_node, 'md:DescriptionLength')
        meta['DescriptionLength'] = int(dl_node.text) if dl_node is not None and dl_node.text else 0
        meta['Hierarchical'] = False
        meta['HierarchyType'] = None
        meta['Owners'] = []
    elif obj_type == 'ChartOfAccounts':
        cl_node = _et_find(props_node, 'md:CodeLength')
        meta['CodeLength'] = int(cl_node.text) if cl_node is not None and cl_node.text else 0
        dl_node = _et_find(props_node, 'md:DescriptionLength')
        meta['DescriptionLength'] = int(dl_node.text) if dl_node is not None and dl_node.text else 0
        meta['Hierarchical'] = True
        ht_node = _et_find(props_node, 'md:HierarchyType')
        meta['HierarchyType'] = ht_node.text if ht_node is not None and ht_node.text else 'HierarchyFoldersAndItems'
        meta['Owners'] = []
        max_ed_node = _et_find(props_node, 'md:MaxExtDimensionCount')
        meta['MaxExtDimensionCount'] = int(max_ed_node.text) if max_ed_node is not None and max_ed_node.text else 0
        meta['AccountingFlags'] = extract_fields(child_objs, 'AccountingFlag')
        meta['ExtDimensionAccountingFlags'] = extract_fields(child_objs, 'ExtDimensionAccountingFlag')

    return meta


def _deep_merge(base, overlay):
    """Deep merge two dicts. overlay wins on conflicts."""
    if not overlay:
        return base
    if not base:
        return overlay
    result = {}
    for k in base:
        result[k] = base[k]
    for k in overlay:
        if k in result and isinstance(result[k], dict) and isinstance(overlay[k], dict):
            result[k] = _deep_merge(result[k], overlay[k])
        else:
            result[k] = overlay[k]
    return result


def load_preset(preset_name, script_dir, out_path_resolved):
    """Load preset: hardcoded defaults -> built-in JSON -> project-level JSON, with deep merge."""
    defaults = {
        'document.item': {
            'header': {'position': 'insidePage', 'layout': '2col', 'distribute': 'even', 'dateTitle': '\u043e\u0442'},
            'footer': {'fields': ['\u041a\u043e\u043c\u043c\u0435\u043d\u0442\u0430\u0440\u0438\u0439'], 'position': 'insidePage'},
            'tabularSections': {'container': 'pages', 'exclude': ['\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b'], 'lineNumber': True},
            'additional': {'position': 'page', 'layout': '2col', 'bspGroup': True},
            'fieldDefaults': {'ref': {'choiceButton': True}, 'boolean': {'element': 'check'}},
            'commandBar': 'auto',
            'properties': {'autoTitle': False},
        },
        'document.list': {
            'columns': 'all', 'columnType': 'labelField', 'hiddenRef': True,
            'tableCommandBar': 'none', 'commandBar': 'auto',
            'properties': {},
        },
        'document.choice': {
            'basedOn': 'document.list',
            'properties': {'windowOpeningMode': 'LockOwnerWindow'},
        },
        'catalog.item': {
            'header': {'layout': '1col', 'distribute': 'left'},
            'codeDescription': {'layout': 'horizontal', 'order': 'descriptionFirst'},
            'parent': {'title': '\u0412\u0445\u043e\u0434\u0438\u0442 \u0432 \u0433\u0440\u0443\u043f\u043f\u0443', 'position': 'afterCodeDescription'},
            'owner': {'readOnly': True, 'position': 'first'},
            'tabularSections': {'container': 'inline', 'exclude': ['\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b', '\u041f\u0440\u0435\u0434\u0441\u0442\u0430\u0432\u043b\u0435\u043d\u0438\u044f'], 'lineNumber': True},
            'footer': {'fields': [], 'position': 'none'},
            'additional': {'position': 'none', 'bspGroup': True},
            'fieldDefaults': {'ref': {'choiceButton': True}, 'boolean': {'element': 'check'}},
            'commandBar': 'auto',
            'properties': {},
        },
        'catalog.folder': {
            'parent': {'title': '\u0412\u0445\u043e\u0434\u0438\u0442 \u0432 \u0433\u0440\u0443\u043f\u043f\u0443'},
            'properties': {'windowOpeningMode': 'LockOwnerWindow'},
        },
        'catalog.list': {
            'columns': 'all', 'columnType': 'labelField', 'hiddenRef': True,
            'tableCommandBar': 'none', 'commandBar': 'auto',
            'properties': {},
        },
        'catalog.choice': {
            'basedOn': 'catalog.list', 'choiceMode': True,
            'properties': {'windowOpeningMode': 'LockOwnerWindow'},
        },
        # --- Register defaults ---
        'informationRegister.record': {
            'fieldDefaults': {'ref': {'choiceButton': True}, 'boolean': {'element': 'check'}},
            'properties': {'windowOpeningMode': 'LockOwnerWindow'},
        },
        'informationRegister.list': {
            'columns': 'all', 'columnType': 'labelField',
            'tableCommandBar': 'none', 'commandBar': 'auto',
            'properties': {},
        },
        'accumulationRegister.list': {
            'columns': 'all', 'columnType': 'labelField',
            'tableCommandBar': 'none', 'commandBar': 'auto',
            'properties': {},
        },
        # --- Catalog-like type defaults ---
        'chartOfCharacteristicTypes.item': {'basedOn': 'catalog.item'},
        'chartOfCharacteristicTypes.folder': {'basedOn': 'catalog.folder'},
        'chartOfCharacteristicTypes.list': {'basedOn': 'catalog.list'},
        'chartOfCharacteristicTypes.choice': {'basedOn': 'catalog.choice'},
        'exchangePlan.item': {'basedOn': 'catalog.item'},
        'exchangePlan.list': {'basedOn': 'catalog.list'},
        'exchangePlan.choice': {'basedOn': 'catalog.choice'},
        # --- ChartOfAccounts defaults ---
        'chartOfAccounts.item': {
            'parent': {'title': '\u041f\u043e\u0434\u0447\u0438\u043d\u0435\u043d \u0441\u0447\u0435\u0442\u0443'},
            'fieldDefaults': {'ref': {'choiceButton': True}, 'boolean': {'element': 'check'}},
            'properties': {},
        },
        'chartOfAccounts.folder': {
            'parent': {'title': '\u041f\u043e\u0434\u0447\u0438\u043d\u0435\u043d \u0441\u0447\u0435\u0442\u0443'},
            'properties': {'windowOpeningMode': 'LockOwnerWindow'},
        },
        'chartOfAccounts.list': {'basedOn': 'catalog.list'},
        'chartOfAccounts.choice': {'basedOn': 'catalog.choice'},
    }

    # Try built-in preset
    preset_dir = os.path.join(os.path.dirname(script_dir), 'presets')
    built_in_path = os.path.join(preset_dir, f'{preset_name}.json')
    if os.path.isfile(built_in_path):
        with open(built_in_path, 'r', encoding='utf-8-sig') as f:
            preset_data = json.load(f)
        for k in list(preset_data.keys()):
            defaults[k] = _deep_merge(defaults.get(k), preset_data[k])

    # Try project-level preset (scan up from output path)
    scan_dir = os.path.dirname(out_path_resolved)
    while scan_dir:
        proj_preset = os.path.join(scan_dir, 'presets', 'skills', 'form', f'{preset_name}.json')
        if os.path.isfile(proj_preset):
            with open(proj_preset, 'r', encoding='utf-8-sig') as f:
                proj_data = json.load(f)
            for k in list(proj_data.keys()):
                defaults[k] = _deep_merge(defaults.get(k), proj_data[k])
            break
        parent_dir = os.path.dirname(scan_dir)
        if parent_dir == scan_dir:
            break
        scan_dir = parent_dir

    # Resolve basedOn references
    for k in list(defaults.keys()):
        sect = defaults[k]
        if isinstance(sect, dict) and 'basedOn' in sect:
            base_name = sect['basedOn']
            if base_name in defaults:
                merged = _deep_merge(defaults[base_name], sect)
                merged.pop('basedOn', None)
                defaults[k] = merged

    return defaults


# Non-displayable types — cannot be bound to form elements
NON_DISPLAYABLE_TYPES = ('ValueStorage', 'v8:ValueStorage', 'ХранилищеЗначения')

def is_displayable_type(type_str):
    return not any(nd in type_str for nd in NON_DISPLAYABLE_TYPES)

def new_field_element(attr_name, data_path, attr_type, field_defaults, extra_props=None):
    """Build a field element DSL entry."""
    is_ref = bool(re.search(r'Ref\.', attr_type))
    is_bool = bool(re.match(r'^\s*xs:boolean\s*$', attr_type) or attr_type == 'boolean' or re.search(r'Boolean', attr_type))

    el_type = 'input'
    if is_bool and field_defaults and field_defaults.get('boolean') and field_defaults['boolean'].get('element') == 'check':
        el_type = 'check'

    el = OrderedDict()
    el[el_type] = attr_name
    el['path'] = data_path

    # (ChoiceButton у ref-полей платформа выводит сама; компилятор эмитит true по StartChoice-эвристике.
    #  Явный choiceButton из декомпиляции эмитится verbatim. Дефолт-«true» здесь НЕ ставим, чтобы
    #  from-object вывод совпадал с сертифицированным и не плодил ChoiceButton на каждом ref-поле.)

    # Extra props
    if extra_props:
        for k in extra_props:
            el[k] = extra_props[k]

    return el


# --- Catalog DSL generators ---

def generate_catalog_dsl(meta, preset_data, purpose):
    purpose_key = f"catalog.{purpose.lower()}"
    p = preset_data.get(purpose_key, {})
    fd = p.get('fieldDefaults', {})

    dispatch = {
        'Folder': lambda: generate_catalog_folder_dsl(meta, p),
        'List': lambda: generate_catalog_list_dsl(meta, p),
        'Choice': lambda: generate_catalog_choice_dsl(meta, p, preset_data),
        'Item': lambda: generate_catalog_item_dsl(meta, p, fd),
    }
    return dispatch[purpose]()


def generate_catalog_folder_dsl(meta, p):
    elements = []
    # Code (if CodeLength > 0)
    if meta.get('CodeLength', 0) > 0:
        elements.append(OrderedDict([('input', '\u041a\u043e\u0434'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Code')]))
    # Description
    elements.append(OrderedDict([('input', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Description')]))
    # Parent
    parent_title = p.get('parent', {}).get('title')
    parent_el = OrderedDict([('input', '\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Parent')])
    if parent_title:
        parent_el['title'] = parent_title
    elements.append(parent_el)

    props = OrderedDict([('windowOpeningMode', 'LockOwnerWindow')])
    if p.get('properties'):
        for k in p['properties']:
            props[k] = p['properties'][k]

    form_props = OrderedDict([('useForFoldersAndItems', 'Folders')])
    for k in props:
        form_props[k] = props[k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', form_props),
        ('elements', elements),
        ('attributes', [
            OrderedDict([('name', '\u041e\u0431\u044a\u0435\u043a\u0442'), ('type', f"CatalogObject.{meta['Name']}"), ('main', True)])
        ]),
    ])


def generate_catalog_list_dsl(meta, p):
    columns = []
    # Description always first
    columns.append(OrderedDict([('labelField', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Description')]))
    # Code if present
    if meta.get('CodeLength', 0) > 0:
        columns.append(OrderedDict([('labelField', '\u041a\u043e\u0434'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Code')]))
    # Custom attributes
    for attr in meta['Attributes']:
        if not is_displayable_type(attr['Type']):
            continue
        columns.append(OrderedDict([('labelField', attr['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{attr['Name']}")]))
    # Hidden ref
    if p.get('hiddenRef', True) is not False:
        columns.append(OrderedDict([('labelField', '\u0421\u0441\u044b\u043b\u043a\u0430'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Ref'), ('userVisible', False)]))

    table_el = OrderedDict([
        ('table', '\u0421\u043f\u0438\u0441\u043e\u043a'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a'),
        ('rowPictureDataPath', '\u0421\u043f\u0438\u0441\u043e\u043a.DefaultPicture'),
        ('commandBarLocation', 'None'),
        ('tableAutofill', False),
        ('columns', columns),
    ])
    # Hierarchical properties
    if meta.get('Hierarchical'):
        table_el['initialTreeView'] = 'ExpandTopLevel'
        table_el['enableStartDrag'] = True
        table_el['enableDrag'] = True

    form_props = OrderedDict()
    if p.get('properties'):
        for k in p['properties']:
            form_props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', form_props),
        ('elements', [table_el]),
        ('attributes', [
            OrderedDict([
                ('name', '\u0421\u043f\u0438\u0441\u043e\u043a'), ('type', 'DynamicList'), ('main', True),
                ('settings', OrderedDict([('mainTable', f"Catalog.{meta['Name']}"), ('dynamicDataRead', True)])),
            ])
        ]),
    ])


def generate_catalog_choice_dsl(meta, p, preset_data):
    # Start from list
    list_key = 'catalog.list'
    lp = preset_data.get(list_key, {})
    dsl = generate_catalog_list_dsl(meta, lp)

    # Add choice-specific properties
    dsl['properties']['windowOpeningMode'] = 'LockOwnerWindow'
    if p.get('properties'):
        for k in p['properties']:
            dsl['properties'][k] = p['properties'][k]

    # Set ChoiceMode on table
    dsl['elements'][0]['choiceMode'] = True

    return dsl


def generate_catalog_item_dsl(meta, p, fd):
    header_children = []

    # Owner (if subordinate)
    if meta.get('Owners') and len(meta['Owners']) > 0:
        owner_el = OrderedDict([('input', '\u0412\u043b\u0430\u0434\u0435\u043b\u0435\u0446'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Owner'), ('readOnly', True)])
        header_children.append(owner_el)

    # Code + Description
    cd_layout = (p.get('codeDescription') or {}).get('layout', 'horizontal')
    cd_order = (p.get('codeDescription') or {}).get('order', 'descriptionFirst')
    has_code = meta.get('CodeLength', 0) > 0

    if cd_layout == 'horizontal' and has_code:
        cd_children = []
        desc_el = OrderedDict([('input', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Description')])
        code_el = OrderedDict([('input', '\u041a\u043e\u0434'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Code')])
        if cd_order == 'descriptionFirst':
            cd_children = [desc_el, code_el]
        else:
            cd_children = [code_el, desc_el]
        header_children.append(OrderedDict([
            ('group', 'horizontal'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u041a\u043e\u0434\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'), ('showTitle', False),
            ('representation', 'none'), ('children', cd_children),
        ]))
    else:
        # Vertical or no code
        header_children.append(OrderedDict([('input', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Description')]))
        if has_code:
            header_children.append(OrderedDict([('input', '\u041a\u043e\u0434'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Code')]))

    # Parent (for hierarchical catalogs)
    parent_pos = (p.get('parent') or {}).get('position', 'afterCodeDescription')
    parent_title = (p.get('parent') or {}).get('title')
    if meta.get('Hierarchical'):
        parent_el = OrderedDict([('input', '\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Parent')])
        if parent_title:
            parent_el['title'] = parent_title
        if parent_pos == 'beforeCodeDescription':
            insert_idx = 1 if (meta.get('Owners') and len(meta['Owners']) > 0) else 0
            header_children.insert(insert_idx, parent_el)
        else:
            # afterCodeDescription (default)
            header_children.append(parent_el)

    # Custom attributes -> header
    footer_field_names = (p.get('footer') or {}).get('fields', [])

    for attr in meta['Attributes']:
        if attr['Name'] in footer_field_names:
            continue
        if not is_displayable_type(attr['Type']):
            continue
        header_children.append(new_field_element(attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{attr['Name']}", attr['Type'], fd))

    # Build root elements
    root_elements = []

    # ГруппаШапка
    root_elements.append(OrderedDict([
        ('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430'), ('showTitle', False),
        ('representation', 'none'), ('children', header_children),
    ]))

    # Tabular sections
    ts_exclude = ['\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b', '\u041f\u0440\u0435\u0434\u0441\u0442\u0430\u0432\u043b\u0435\u043d\u0438\u044f']
    if (p.get('tabularSections') or {}).get('exclude'):
        ts_exclude = p['tabularSections']['exclude']
    ts_line_number = (p.get('tabularSections') or {}).get('lineNumber', True)

    visible_ts = [ts for ts in meta['TabularSections'] if ts['Name'] not in ts_exclude]

    for ts in visible_ts:
        ts_cols = []
        if ts_line_number:
            ts_cols.append(OrderedDict([('labelField', f"{ts['Name']}\u041d\u043e\u043c\u0435\u0440\u0421\u0442\u0440\u043e\u043a\u0438"), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}.LineNumber")]))
        for col in ts['Columns']:
            ts_cols.append(new_field_element(f"{ts['Name']}{col['Name']}", f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}.{col['Name']}", col['Type'], fd))
        root_elements.append(OrderedDict([('table', ts['Name']), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}"), ('columns', ts_cols)]))

    # Footer fields
    for fn in footer_field_names:
        f_attr = next((a for a in meta['Attributes'] if a['Name'] == fn), None)
        if f_attr:
            root_elements.append(new_field_element(f_attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{f_attr['Name']}", f_attr['Type'], fd))

    # BSP group
    bsp_group = (p.get('additional') or {}).get('bspGroup', True)
    if bsp_group:
        root_elements.append(OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b')]))

    # Properties
    form_props = OrderedDict()
    if p.get('properties'):
        for k in p['properties']:
            form_props[k] = p['properties'][k]
    # UseForFoldersAndItems
    if meta.get('Hierarchical') and meta.get('HierarchyType') == 'HierarchyFoldersAndItems':
        form_props['useForFoldersAndItems'] = 'Items'

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', form_props),
        ('elements', root_elements),
        ('attributes', [
            OrderedDict([('name', '\u041e\u0431\u044a\u0435\u043a\u0442'), ('type', f"CatalogObject.{meta['Name']}"), ('main', True)])
        ]),
    ])


# --- Document DSL generators ---

def generate_document_dsl(meta, preset_data, purpose):
    purpose_key = f"document.{purpose.lower()}"
    p = preset_data.get(purpose_key, {})
    fd = p.get('fieldDefaults', {})

    dispatch = {
        'List': lambda: generate_document_list_dsl(meta, p),
        'Choice': lambda: generate_document_choice_dsl(meta, p, preset_data),
        'Item': lambda: generate_document_item_dsl(meta, p, fd),
    }
    return dispatch[purpose]()


def generate_document_list_dsl(meta, p):
    columns = []
    # Standard columns: Number + Date
    columns.append(OrderedDict([('labelField', 'Номер'), ('path', 'Список.Number')]))
    columns.append(OrderedDict([('labelField', 'Дата'), ('path', 'Список.Date')]))
    # All custom attributes as labelField
    for attr in meta['Attributes']:
        if not is_displayable_type(attr['Type']):
            continue
        columns.append(OrderedDict([('labelField', attr['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{attr['Name']}")]))
    # Hidden ref
    if p.get('hiddenRef', True):
        columns.append(OrderedDict([('labelField', '\u0421\u0441\u044b\u043b\u043a\u0430'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Ref'), ('userVisible', False)]))

    table_el = OrderedDict([
        ('table', '\u0421\u043f\u0438\u0441\u043e\u043a'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a'),
        ('rowPictureDataPath', '\u0421\u043f\u0438\u0441\u043e\u043a.DefaultPicture'),
        ('commandBarLocation', 'None'),
        ('tableAutofill', False),
        ('columns', columns),
    ])

    form_props = OrderedDict()
    if p.get('properties'):
        for k in p['properties']:
            form_props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', form_props),
        ('elements', [table_el]),
        ('attributes', [
            OrderedDict([
                ('name', '\u0421\u043f\u0438\u0441\u043e\u043a'), ('type', 'DynamicList'), ('main', True),
                ('settings', OrderedDict([('mainTable', f"Document.{meta['Name']}"), ('dynamicDataRead', True)])),
            ])
        ]),
    ])


def generate_document_choice_dsl(meta, p, preset_data):
    list_key = 'document.list'
    lp = preset_data.get(list_key, {})
    dsl = generate_document_list_dsl(meta, lp)

    dsl['properties']['windowOpeningMode'] = 'LockOwnerWindow'
    if p.get('properties'):
        for k in p['properties']:
            dsl['properties'][k] = p['properties'][k]

    return dsl


def generate_document_item_dsl(meta, p, fd):
    header_pos = (p.get('header') or {}).get('position', 'insidePage')
    header_layout = (p.get('header') or {}).get('layout', '2col')
    header_distribute = (p.get('header') or {}).get('distribute', 'even')
    date_title = (p.get('header') or {}).get('dateTitle', '\u043e\u0442')

    footer_fields = (p.get('footer') or {}).get('fields', [])
    footer_pos = (p.get('footer') or {}).get('position', 'insidePage')

    add_pos = (p.get('additional') or {}).get('position', 'page')
    add_layout = (p.get('additional') or {}).get('layout', '2col')
    add_bsp_group = (p.get('additional') or {}).get('bspGroup', True)
    add_left = (p.get('additional') or {}).get('left', [])
    add_right = (p.get('additional') or {}).get('right', [])

    header_right = (p.get('header') or {}).get('right', [])

    ts_exclude = ['\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b']
    if (p.get('tabularSections') or {}).get('exclude'):
        ts_exclude = p['tabularSections']['exclude']
    ts_line_number = (p.get('tabularSections') or {}).get('lineNumber', True)

    # Classify attributes
    claimed = {}
    for fn in footer_fields:
        claimed[fn] = 'footer'
    for fn in header_right:
        claimed[fn] = 'header.right'
    for fn in add_left:
        claimed[fn] = 'additional.left'
    for fn in add_right:
        claimed[fn] = 'additional.right'

    unclaimed = [attr for attr in meta['Attributes'] if attr['Name'] not in claimed and is_displayable_type(attr['Type'])]

    # Distribute unclaimed
    left_attrs = []
    right_extra_attrs = []
    if header_distribute == 'left':
        left_attrs = unclaimed
    elif header_distribute == 'right':
        right_extra_attrs = unclaimed
    else:  # "even"
        import math
        half = math.ceil(len(unclaimed) / 2) if unclaimed else 0
        left_attrs = unclaimed[:half]
        right_extra_attrs = unclaimed[half:]

    # Build ГруппаНомерДата
    num_date_children = [
        OrderedDict([('input', '\u041d\u043e\u043c\u0435\u0440'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Number'), ('autoMaxWidth', False), ('width', 9)]),
        OrderedDict([('input', '\u0414\u0430\u0442\u0430'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Date'), ('title', date_title)]),
    ]
    num_date_group = OrderedDict([
        ('group', 'horizontal'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u041d\u043e\u043c\u0435\u0440\u0414\u0430\u0442\u0430'), ('showTitle', False), ('children', num_date_children),
    ])

    # Build left column
    left_children = [num_date_group]
    for attr in left_attrs:
        left_children.append(new_field_element(attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{attr['Name']}", attr['Type'], fd))

    # Build right column
    right_children = []
    for rn in header_right:
        r_attr = next((a for a in meta['Attributes'] if a['Name'] == rn), None)
        if r_attr:
            right_children.append(new_field_element(r_attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{r_attr['Name']}", r_attr['Type'], fd))
    for attr in right_extra_attrs:
        right_children.append(new_field_element(attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{attr['Name']}", attr['Type'], fd))

    # Header group
    if header_layout == '2col' and len(right_children) > 0:
        header_group = OrderedDict([
            ('group', 'horizontal'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430'), ('showTitle', False), ('representation', 'none'),
            ('children', [
                OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430\u041b\u0435\u0432\u043e'), ('showTitle', False), ('children', left_children)]),
                OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430\u041f\u0440\u0430\u0432\u043e'), ('showTitle', False), ('children', right_children)]),
            ]),
        ])
    else:
        # 1col or no right items
        all_header_fields = left_children + right_children
        header_group = OrderedDict([
            ('group', 'horizontal'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430'), ('showTitle', False), ('representation', 'none'),
            ('children', [
                OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430\u041b\u0435\u0432\u043e'), ('showTitle', False), ('children', all_header_fields)]),
            ]),
        ])

    # Footer elements
    footer_elements = []
    for fn in footer_fields:
        f_attr = next((a for a in meta['Attributes'] if a['Name'] == fn), None)
        if f_attr:
            footer_elements.append(new_field_element(f_attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{f_attr['Name']}", f_attr['Type'], fd))

    # Visible tabular sections
    visible_ts = [ts for ts in meta['TabularSections'] if ts['Name'] not in ts_exclude]

    # Additional page content
    additional_page = None
    if add_pos == 'page':
        add_left_els = []
        add_right_els = []
        for aln in add_left:
            al_attr = next((a for a in meta['Attributes'] if a['Name'] == aln), None)
            if al_attr:
                add_left_els.append(new_field_element(al_attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{al_attr['Name']}", al_attr['Type'], fd))
        for arn in add_right:
            ar_attr = next((a for a in meta['Attributes'] if a['Name'] == arn), None)
            if ar_attr:
                add_right_els.append(new_field_element(ar_attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{ar_attr['Name']}", ar_attr['Type'], fd))
        add_page_children = []
        if add_layout == '2col':
            add_page_children.append(OrderedDict([
                ('group', 'horizontal'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b'), ('showTitle', False),
                ('children', [
                    OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b\u041b\u0435\u0432\u043e'), ('showTitle', False), ('children', add_left_els)]),
                    OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u044b\u041f\u0440\u0430\u0432\u043e'), ('showTitle', False), ('children', add_right_els)]),
                ]),
            ]))
        else:
            add_page_children.extend(add_left_els + add_right_els)
        if add_bsp_group:
            add_page_children.append(OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b')]))
        additional_page = OrderedDict([('page', '\u0413\u0440\u0443\u043f\u043f\u0430\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u043e'), ('title', '\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u043e'), ('children', add_page_children)])

    # Build TS page elements
    ts_pages = []
    for ts in visible_ts:
        ts_cols = []
        if ts_line_number:
            ts_cols.append(OrderedDict([('labelField', f"{ts['Name']}\u041d\u043e\u043c\u0435\u0440\u0421\u0442\u0440\u043e\u043a\u0438"), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}.LineNumber")]))
        for col in ts['Columns']:
            ts_cols.append(new_field_element(f"{ts['Name']}{col['Name']}", f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}.{col['Name']}", col['Type'], fd))
        ts_pages.append(OrderedDict([
            ('page', f"\u0413\u0440\u0443\u043f\u043f\u0430{ts['Name']}"), ('title', ts['Synonym']),
            ('children', [
                OrderedDict([('table', ts['Name']), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}"), ('columns', ts_cols)])
            ]),
        ]))

    # Assemble root elements
    root_elements = []

    if len(visible_ts) == 0:
        # Simple form - no Pages
        root_elements.append(header_group)
        if footer_elements:
            root_elements.extend(footer_elements)
        if add_bsp_group and add_pos != 'none':
            root_elements.append(OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b')]))
    else:
        # Pages form
        if header_pos == 'abovePages':
            root_elements.append(header_group)
            pages_children = list(ts_pages)
            if additional_page:
                pages_children.append(additional_page)
            root_elements.append(OrderedDict([('pages', '\u0413\u0440\u0443\u043f\u043f\u0430\u0421\u0442\u0440\u0430\u043d\u0438\u0446\u044b'), ('children', pages_children)]))
        else:
            # insidePage (default)
            osnovnoe_children = [header_group]
            if footer_pos == 'insidePage' and footer_elements:
                osnovnoe_children.extend(footer_elements)
            pages_children = []
            pages_children.append(OrderedDict([('page', '\u0413\u0440\u0443\u043f\u043f\u0430\u041e\u0441\u043d\u043e\u0432\u043d\u043e\u0435'), ('title', '\u041e\u0441\u043d\u043e\u0432\u043d\u043e\u0435'), ('children', osnovnoe_children)]))
            pages_children.extend(ts_pages)
            if additional_page:
                pages_children.append(additional_page)
            root_elements.append(OrderedDict([('pages', '\u0413\u0440\u0443\u043f\u043f\u0430\u0421\u0442\u0440\u0430\u043d\u0438\u0446\u044b'), ('children', pages_children)]))

        # Footer below pages
        if footer_pos == 'belowPages' and footer_elements:
            root_elements.extend(footer_elements)

    # Properties
    form_props = OrderedDict([('autoTitle', False)])
    if p.get('properties'):
        for k in p['properties']:
            form_props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', form_props),
        ('elements', root_elements),
        ('attributes', [
            OrderedDict([('name', '\u041e\u0431\u044a\u0435\u043a\u0442'), ('type', f"DocumentObject.{meta['Name']}"), ('main', True)])
        ]),
    ])


# --- InformationRegister DSL generators ---

def generate_information_register_dsl(meta, preset_data, purpose):
    p_key = f"informationRegister.{purpose.lower()}"
    p = preset_data.get(p_key, {})
    fd = p.get('fieldDefaults') or {'ref': {'choiceButton': True}, 'boolean': {'element': 'check'}}
    dispatch = {
        'Record': lambda: generate_information_register_record_dsl(meta, p, fd),
        'List': lambda: generate_information_register_list_dsl(meta, p),
    }
    return dispatch[purpose]()


def generate_information_register_record_dsl(meta, p, fd):
    elements = OrderedDict()
    is_periodic = meta.get('Periodicity') and meta['Periodicity'] != 'Nonperiodical'

    # Period first (if periodic)
    if is_periodic:
        elements['\u041f\u0435\u0440\u0438\u043e\u0434'] = {'element': 'input', 'path': '\u0417\u0430\u043f\u0438\u0441\u044c.Period'}
    # Dimensions
    for dim in meta.get('Dimensions', []):
        if not is_displayable_type(dim['Type']):
            continue
        elements[dim['Name']] = new_field_element(dim['Name'], f"\u0417\u0430\u043f\u0438\u0441\u044c.{dim['Name']}", dim['Type'], fd)
    # Resources
    for res in meta.get('Resources', []):
        if not is_displayable_type(res['Type']):
            continue
        elements[res['Name']] = new_field_element(res['Name'], f"\u0417\u0430\u043f\u0438\u0441\u044c.{res['Name']}", res['Type'], fd)
    # Attributes
    for attr in meta['Attributes']:
        if not is_displayable_type(attr['Type']):
            continue
        elements[attr['Name']] = new_field_element(attr['Name'], f"\u0417\u0430\u043f\u0438\u0441\u044c.{attr['Name']}", attr['Type'], fd)

    props = OrderedDict([('windowOpeningMode', 'LockOwnerWindow')])
    if p.get('properties'):
        for k in p['properties']:
            props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', props),
        ('elements', elements),
        ('attributes', [
            {'name': '\u0417\u0430\u043f\u0438\u0441\u044c', 'type': f"InformationRegisterRecordManager.{meta['Name']}", 'main': True, 'savedData': True}
        ]),
    ])


def generate_information_register_list_dsl(meta, p):
    is_periodic = meta.get('Periodicity') and meta['Periodicity'] != 'Nonperiodical'
    is_recorder_subordinate = meta.get('WriteMode') == 'RecorderSubordinate'

    columns_list = []
    # Period
    if is_periodic:
        columns_list.append(OrderedDict([('labelField', '\u041f\u0435\u0440\u0438\u043e\u0434'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Period')]))
    # Recorder/LineNumber for subordinate registers
    if is_recorder_subordinate:
        columns_list.append(OrderedDict([('labelField', '\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Recorder')]))
        columns_list.append(OrderedDict([('labelField', '\u041d\u043e\u043c\u0435\u0440\u0421\u0442\u0440\u043e\u043a\u0438'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.LineNumber')]))
    # Dimensions
    for dim in meta.get('Dimensions', []):
        if not is_displayable_type(dim['Type']):
            continue
        columns_list.append(OrderedDict([('labelField', dim['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{dim['Name']}")]))
    # Resources
    for res in meta.get('Resources', []):
        if not is_displayable_type(res['Type']):
            continue
        el_key = 'check' if re.match(r'^xs:boolean$|^Boolean$', res['Type']) else 'labelField'
        columns_list.append(OrderedDict([(el_key, res['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{res['Name']}")]))
    # Attributes
    for attr in meta['Attributes']:
        if not is_displayable_type(attr['Type']):
            continue
        el_key = 'check' if re.match(r'^xs:boolean$|^Boolean$', attr['Type']) else 'labelField'
        columns_list.append(OrderedDict([(el_key, attr['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{attr['Name']}")]))

    table_el = OrderedDict([
        ('table', '\u0421\u043f\u0438\u0441\u043e\u043a'),
        ('path', '\u0421\u043f\u0438\u0441\u043e\u043a'),
        ('rowPictureDataPath', '\u0421\u043f\u0438\u0441\u043e\u043a.DefaultPicture'),
        ('commandBarLocation', 'None'),
        ('tableAutofill', False),
        ('columns', columns_list),
    ])

    props = OrderedDict()
    if p.get('properties'):
        for k in p['properties']:
            props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', props),
        ('elements', [table_el]),
        ('attributes', [
            {'name': '\u0421\u043f\u0438\u0441\u043e\u043a', 'type': 'DynamicList', 'main': True, 'settings': {'mainTable': f"InformationRegister.{meta['Name']}", 'dynamicDataRead': True}}
        ]),
    ])


# --- AccumulationRegister DSL generators ---

def generate_accumulation_register_dsl(meta, preset_data, purpose):
    p_key = f"accumulationRegister.{purpose.lower()}"
    p = preset_data.get(p_key, {})
    dispatch = {
        'List': lambda: generate_accumulation_register_list_dsl(meta, p),
    }
    return dispatch[purpose]()


def generate_accumulation_register_list_dsl(meta, p):
    columns_list = []
    # AccumulationRegisters always have Period, Recorder, LineNumber
    columns_list.append(OrderedDict([('labelField', '\u041f\u0435\u0440\u0438\u043e\u0434'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Period')]))
    columns_list.append(OrderedDict([('labelField', '\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.Recorder')]))
    columns_list.append(OrderedDict([('labelField', '\u041d\u043e\u043c\u0435\u0440\u0421\u0442\u0440\u043e\u043a\u0438'), ('path', '\u0421\u043f\u0438\u0441\u043e\u043a.LineNumber')]))
    # Dimensions
    for dim in meta.get('Dimensions', []):
        if not is_displayable_type(dim['Type']):
            continue
        columns_list.append(OrderedDict([('labelField', dim['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{dim['Name']}")]))
    # Resources
    for res in meta.get('Resources', []):
        if not is_displayable_type(res['Type']):
            continue
        el_key = 'check' if re.match(r'^xs:boolean$|^Boolean$', res['Type']) else 'labelField'
        columns_list.append(OrderedDict([(el_key, res['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{res['Name']}")]))
    # Attributes
    for attr in meta['Attributes']:
        if not is_displayable_type(attr['Type']):
            continue
        el_key = 'check' if re.match(r'^xs:boolean$|^Boolean$', attr['Type']) else 'labelField'
        columns_list.append(OrderedDict([(el_key, attr['Name']), ('path', f"\u0421\u043f\u0438\u0441\u043e\u043a.{attr['Name']}")]))

    table_el = OrderedDict([
        ('table', '\u0421\u043f\u0438\u0441\u043e\u043a'),
        ('path', '\u0421\u043f\u0438\u0441\u043e\u043a'),
        ('rowPictureDataPath', '\u0421\u043f\u0438\u0441\u043e\u043a.DefaultPicture'),
        ('commandBarLocation', 'None'),
        ('tableAutofill', False),
        ('columns', columns_list),
    ])

    props = OrderedDict()
    if p.get('properties'):
        for k in p['properties']:
            props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', props),
        ('elements', [table_el]),
        ('attributes', [
            {'name': '\u0421\u043f\u0438\u0441\u043e\u043a', 'type': 'DynamicList', 'main': True, 'settings': {'mainTable': f"AccumulationRegister.{meta['Name']}", 'dynamicDataRead': True}}
        ]),
    ])


# --- ChartOfCharacteristicTypes (delegates to Catalog) ---

def generate_chart_of_characteristic_types_dsl(meta, preset_data, purpose):
    # Delegate to Catalog generators -- meta already has CodeLength, DescriptionLength, etc.
    dsl = generate_catalog_dsl(meta, preset_data, purpose)

    # Post-patch: replace Catalog types with ChartOfCharacteristicTypes types
    cat_obj_type = f"CatalogObject.{meta['Name']}"
    ccoct_obj_type = f"ChartOfCharacteristicTypesObject.{meta['Name']}"
    cat_list_type = f"Catalog.{meta['Name']}"
    ccoct_list_type = f"ChartOfCharacteristicTypes.{meta['Name']}"

    for a in dsl['attributes']:
        if a.get('type') == cat_obj_type:
            a['type'] = ccoct_obj_type
        if a.get('type') == 'DynamicList' and a.get('settings') and a['settings'].get('mainTable') == cat_list_type:
            a['settings']['mainTable'] = ccoct_list_type

    # For Item forms: inject ValueType field after Description/ГруппаКодНаименование
    if purpose == 'Item' and dsl.get('elements'):
        vt_el = OrderedDict([('input', '\u0422\u0438\u043f\u0417\u043d\u0430\u0447\u0435\u043d\u0438\u044f'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.ValueType')])
        els = dsl['elements']
        if isinstance(els, list):
            inserted = False
            new_els = []
            for el in els:
                new_els.append(el)
                if not inserted and isinstance(el, dict):
                    name = el.get('input') or el.get('group') or ''
                    if name in ('\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435', '\u0413\u0440\u0443\u043f\u043f\u0430\u041a\u043e\u0434\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'):
                        new_els.append(vt_el)
                        inserted = True
            if not inserted:
                new_els.append(vt_el)
            dsl['elements'] = new_els

    return dsl


# --- ExchangePlan (delegates to Catalog) ---

def generate_exchange_plan_dsl(meta, preset_data, purpose):
    # ExchangePlans are not hierarchical and have no Folder form
    dsl = generate_catalog_dsl(meta, preset_data, purpose)

    # Post-patch: replace Catalog types with ExchangePlan types
    cat_obj_type = f"CatalogObject.{meta['Name']}"
    ep_obj_type = f"ExchangePlanObject.{meta['Name']}"
    cat_list_type = f"Catalog.{meta['Name']}"
    ep_list_type = f"ExchangePlan.{meta['Name']}"

    for a in dsl['attributes']:
        if a.get('type') == cat_obj_type:
            a['type'] = ep_obj_type
        if a.get('type') == 'DynamicList' and a.get('settings') and a['settings'].get('mainTable') == cat_list_type:
            a['settings']['mainTable'] = ep_list_type

    # For Item forms: inject SentNo, ReceivedNo after Code/Description
    if purpose == 'Item' and dsl.get('elements'):
        sent_el = OrderedDict([('input', '\u041d\u043e\u043c\u0435\u0440\u041e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043d\u043e\u0433\u043e'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.SentNo'), ('readOnly', True)])
        recv_el = OrderedDict([('input', '\u041d\u043e\u043c\u0435\u0440\u041f\u0440\u0438\u043d\u044f\u0442\u043e\u0433\u043e'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.ReceivedNo'), ('readOnly', True)])
        els = dsl['elements']
        if isinstance(els, list):
            inserted = False
            new_els = []
            for el in els:
                new_els.append(el)
                if not inserted and isinstance(el, dict):
                    name = el.get('input') or el.get('group') or ''
                    if name in ('\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435', '\u0413\u0440\u0443\u043f\u043f\u0430\u041a\u043e\u0434\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'):
                        new_els.append(sent_el)
                        new_els.append(recv_el)
                        inserted = True
            if not inserted:
                new_els.append(sent_el)
                new_els.append(recv_el)
            dsl['elements'] = new_els

    return dsl


# --- ChartOfAccounts DSL generators ---

def generate_chart_of_accounts_dsl(meta, preset_data, purpose):
    p_key = f"chartOfAccounts.{purpose.lower()}"
    p = preset_data.get(p_key, {})
    fd = p.get('fieldDefaults') or {'ref': {'choiceButton': True}, 'boolean': {'element': 'check'}}
    dispatch = {
        'Item': lambda: generate_chart_of_accounts_item_dsl(meta, p, fd, preset_data),
        'Folder': lambda: generate_chart_of_accounts_folder_dsl(meta, p),
        'List': lambda: generate_chart_of_accounts_list_dsl(meta, preset_data),
        'Choice': lambda: generate_chart_of_accounts_choice_dsl(meta, preset_data),
    }
    return dispatch[purpose]()


def generate_chart_of_accounts_item_dsl(meta, p, fd, preset_data):
    elements = []

    # Header: Code + Parent
    header_left_children = []
    if meta.get('CodeLength', 0) > 0:
        header_left_children.append(OrderedDict([('input', '\u041a\u043e\u0434'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Code')]))
    header_right_children = []
    if meta.get('Hierarchical'):
        parent_title = (p.get('parent') or {}).get('title', '\u041f\u043e\u0434\u0447\u0438\u043d\u0435\u043d \u0441\u0447\u0435\u0442\u0443')
        header_right_children.append(OrderedDict([('input', '\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Parent'), ('title', parent_title)]))

    if len(header_right_children) > 0:
        elements.append(OrderedDict([
            ('group', 'horizontal'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430'), ('showTitle', False), ('representation', 'none'),
            ('children', [
                OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430\u041b\u0435\u0432\u043e'), ('showTitle', False), ('children', header_left_children)]),
                OrderedDict([('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430\u041f\u0440\u0430\u0432\u043e'), ('showTitle', False), ('children', header_right_children)]),
            ]),
        ]))
    elif len(header_left_children) > 0:
        elements.extend(header_left_children)

    # Description
    if meta.get('DescriptionLength', 0) > 0:
        elements.append(OrderedDict([('input', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Description')]))

    # OffBalance
    elements.append(OrderedDict([('check', '\u0417\u0430\u0431\u0430\u043b\u0430\u043d\u0441\u043e\u0432\u044b\u0439'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.OffBalance')]))

    # AccountingFlags as checkboxes
    if meta.get('AccountingFlags') and len(meta['AccountingFlags']) > 0:
        flag_children = []
        for flag in meta['AccountingFlags']:
            flag_children.append(OrderedDict([('check', flag['Name']), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.{flag['Name']}")]))
        elements.append(OrderedDict([
            ('group', 'vertical'), ('name', '\u0413\u0440\u0443\u043f\u043f\u0430\u041f\u0440\u0438\u0437\u043d\u0430\u043a\u0438\u0423\u0447\u0435\u0442\u0430'), ('title', '\u041f\u0440\u0438\u0437\u043d\u0430\u043a\u0438 \u0443\u0447\u0435\u0442\u0430'),
            ('children', flag_children),
        ]))

    # ExtDimensionTypes table
    if meta.get('MaxExtDimensionCount', 0) > 0:
        # Column names are prefixed with the table name (like the generic TS path and stock 1C),
        # else a subconto flag column collides with a same-named account accounting-flag checkbox.
        ed_table = '\u0412\u0438\u0434\u044b\u0421\u0443\u0431\u043a\u043e\u043d\u0442\u043e'
        ed_cols = []
        ed_cols.append(OrderedDict([('input', f"{ed_table}\u0412\u0438\u0434\u0421\u0443\u0431\u043a\u043e\u043d\u0442\u043e"), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes.ExtDimensionType')]))
        ed_cols.append(OrderedDict([('check', f"{ed_table}\u0422\u043e\u043b\u044c\u043a\u043e\u041e\u0431\u043e\u0440\u043e\u0442\u044b"), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes.TurnoversOnly')]))
        if meta.get('ExtDimensionAccountingFlags'):
            for ed_flag in meta['ExtDimensionAccountingFlags']:
                ed_cols.append(OrderedDict([('check', f"{ed_table}{ed_flag['Name']}"), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes.{ed_flag['Name']}")]))
        elements.append(OrderedDict([
            ('table', ed_table),
            ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes'),
            ('columns', ed_cols),
        ]))

    # Custom attributes
    for attr in meta['Attributes']:
        if not is_displayable_type(attr['Type']):
            continue
        elements.append(new_field_element(attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{attr['Name']}", attr['Type'], fd))

    # Tabular sections
    ts_exclude = ['\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b', '\u041f\u0440\u0435\u0434\u0441\u0442\u0430\u0432\u043b\u0435\u043d\u0438\u044f']
    for ts in meta['TabularSections']:
        if ts['Name'] in ts_exclude:
            continue
        ts_cols = []
        for col in ts['Columns']:
            if not is_displayable_type(col['Type']):
                continue
            ts_cols.append(new_field_element(f"{ts['Name']}{col['Name']}", f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}.{col['Name']}", col['Type'], fd))
        elements.append(OrderedDict([('table', ts['Name']), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}"), ('columns', ts_cols)]))

    props = OrderedDict()
    if p.get('properties'):
        for k in p['properties']:
            props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('properties', props),
        ('elements', elements),
        ('attributes', [
            {'name': '\u041e\u0431\u044a\u0435\u043a\u0442', 'type': f"ChartOfAccountsObject.{meta['Name']}", 'main': True, 'savedData': True}
        ]),
    ])


def generate_chart_of_accounts_folder_dsl(meta, p):
    elements = []
    if meta.get('CodeLength', 0) > 0:
        elements.append(OrderedDict([('input', '\u041a\u043e\u0434'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Code')]))
    if meta.get('DescriptionLength', 0) > 0:
        elements.append(OrderedDict([('input', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Description')]))
    if meta.get('Hierarchical'):
        parent_title = (p.get('parent') or {}).get('title', '\u041f\u043e\u0434\u0447\u0438\u043d\u0435\u043d \u0441\u0447\u0435\u0442\u0443')
        elements.append(OrderedDict([('input', '\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c'), ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.Parent'), ('title', parent_title)]))

    props = OrderedDict([('windowOpeningMode', 'LockOwnerWindow')])
    if p.get('properties'):
        for k in p['properties']:
            props[k] = p['properties'][k]

    return OrderedDict([
        ('title', meta['Synonym']),
        ('useForFoldersAndItems', 'Folders'),
        ('properties', props),
        ('elements', elements),
        ('attributes', [
            {'name': '\u041e\u0431\u044a\u0435\u043a\u0442', 'type': f"ChartOfAccountsObject.{meta['Name']}", 'main': True, 'savedData': True}
        ]),
    ])


def generate_chart_of_accounts_list_dsl(meta, preset_data):
    # Delegate to Catalog List and patch types
    dsl = generate_catalog_dsl(meta, preset_data, 'List')
    for a in dsl['attributes']:
        if a.get('type') == 'DynamicList' and a.get('settings') and a['settings'].get('mainTable') == f"Catalog.{meta['Name']}":
            a['settings']['mainTable'] = f"ChartOfAccounts.{meta['Name']}"
    return dsl


def generate_chart_of_accounts_choice_dsl(meta, preset_data):
    dsl = generate_catalog_dsl(meta, preset_data, 'Choice')
    for a in dsl['attributes']:
        if a.get('type') == 'DynamicList' and a.get('settings') and a['settings'].get('mainTable') == f"Catalog.{meta['Name']}":
            a['settings']['mainTable'] = f"ChartOfAccounts.{meta['Name']}"
    return dsl


# ═══════════════════════════════════════════════════════════════════════════
# END OF FROM-OBJECT MODE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════


def esc_xml(s):
    # Экранирование ТЕКСТА элемента (<v8:content>, <Value>): только & < > .
    # Кавычки/апострофы в тексте 1С не экранирует (пишет литерально) — &quot; ломал бы раундтрип.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def di_attr(el):
    # DisplayImportance — атрибут открывающего тега элемента (адаптивная важность). "" если нет.
    if isinstance(el, dict) and el.get('displayImportance'):
        return f' DisplayImportance="{esc_xml(str(el["displayImportance"]))}"'
    return ''


# Базовая директория для @file-ссылок в query динсписка (устанавливается в main)
QUERY_BASE_DIR = None


def resolve_query_value(val, base_dir):
    if not val.startswith('@'):
        return val
    file_path = val[1:]
    if os.path.isabs(file_path):
        candidates = [file_path]
    else:
        candidates = [os.path.join(base_dir or os.getcwd(), file_path), os.path.join(os.getcwd(), file_path)]
    for c in candidates:
        if os.path.exists(c):
            with open(c, 'r', encoding='utf-8-sig') as f:
                return f.read().rstrip()
    print(f"Query file not found: {file_path} (searched: {', '.join(candidates)})", file=sys.stderr)
    sys.exit(1)


def emit_ml_items(lines, indent, val):
    # строка → один ru-элемент; объект {lang: text} → по элементу на язык
    if isinstance(val, dict):
        for k, v in val.items():
            lines.append(f"{indent}<v8:item>")
            lines.append(f"{indent}\t<v8:lang>{k}</v8:lang>")
            lines.append(f"{indent}\t<v8:content>{esc_xml(str(v))}</v8:content>")
            lines.append(f"{indent}</v8:item>")
    else:
        lines.append(f"{indent}<v8:item>")
        lines.append(f"{indent}\t<v8:lang>ru</v8:lang>")
        lines.append(f"{indent}\t<v8:content>{esc_xml(str(val))}</v8:content>")
        lines.append(f"{indent}</v8:item>")


def emit_mltext(lines, indent, tag, text, xsi_type=None):
    attr = f' xsi:type="{xsi_type}"' if xsi_type else ''
    if not text:
        lines.append(f"{indent}<{tag}{attr}/>")
        return
    lines.append(f"{indent}<{tag}{attr}>")
    emit_ml_items(lines, f"{indent}\t", text)
    lines.append(f"{indent}</{tag}>")


def emit_us_presentation(lines, indent, tag, val):
    # <dcsset:userSettingPresentation>: плоская строка → xsi:type="xs:string"; мультиязычный → v8:LocalStringType
    if val is None:
        return
    if isinstance(val, str):
        lines.append(f'{indent}<{tag} xsi:type="xs:string">{esc_xml(val)}</{tag}>')
    else:
        emit_mltext(lines, indent, tag, val, xsi_type='v8:LocalStringType')


# Каноничные GUID пустых контейнеров ListSettings (умолчание платформы, ~90% форм).
CANON_FILTER_ID = 'dfcece9d-5077-440b-b6b3-45a5cb4538eb'
CANON_ORDER_ID = '88619765-ccb3-46c6-ac52-38e9c992ebd4'
CANON_CA_ID = 'b75fecce-942b-4aed-abc9-e6a02e460fb3'
CANON_ITEMS_ID = '911b6018-f537-43e8-a417-da56b22f9aec'


def new_uuid():
    return str(uuid.uuid4())


# ─────────────────────────────────────────────────────────────────────────────
# Настройки компоновщика ListSettings: filter/order/conditionalAppearance.
# Грамматика DSL и эмиссия dcsset скопированы из skd-compile (навыки автономны).
# ─────────────────────────────────────────────────────────────────────────────
COMPARISON_TYPES = {
    '=': 'Equal', '<>': 'NotEqual',
    '>': 'Greater', '>=': 'GreaterOrEqual',
    '<': 'Less', '<=': 'LessOrEqual',
    'in': 'InList', 'notIn': 'NotInList',
    'inHierarchy': 'InHierarchy', 'inListByHierarchy': 'InListByHierarchy',
    'contains': 'Contains', 'notContains': 'NotContains',
    'beginsWith': 'BeginsWith', 'notBeginsWith': 'NotBeginsWith',
    'like': 'Like', 'notLike': 'NotLike',
    'подобно': 'Like', 'неподобно': 'NotLike',  # рус. синоним
    'filled': 'Filled', 'notFilled': 'NotFilled',
}
# Регистронезависимый лукап (зеркало PS-хэша): Like/LIKE/ПОДОБНО → канон
_COMPARISON_TYPES_CI = {k.lower(): v for k, v in COMPARISON_TYPES.items()}

_REF_TYPE_RE = re.compile(
    r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|'
    r'БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|'
    r'ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|'
    r'InformationRegister|ExchangePlan)\.')


def parse_filter_shorthand(s):
    result = {'field': '', 'op': 'Equal', 'value': None, 'use': True,
              'userSettingID': None, 'viewMode': None, 'presentation': None}
    if re.search(r'@user', s):
        result['userSettingID'] = 'auto'
        s = re.sub(r'\s*@user', '', s)
    if re.search(r'@off', s):
        result['use'] = False
        s = re.sub(r'\s*@off', '', s)
    if re.search(r'@quickAccess', s):
        result['viewMode'] = 'QuickAccess'
        s = re.sub(r'\s*@quickAccess', '', s)
    if re.search(r'@normal', s):
        result['viewMode'] = 'Normal'
        s = re.sub(r'\s*@normal', '', s)
    if re.search(r'@inaccessible', s):
        result['viewMode'] = 'Inaccessible'
        s = re.sub(r'\s*@inaccessible', '', s)
    s = s.strip()
    op_patterns = ['<>', '>=', '<=', '=', '>', '<',
                   r'notIn\b', r'in\b', r'inHierarchy\b', r'inListByHierarchy\b',
                   r'notContains\b', r'contains\b', r'notBeginsWith\b', r'beginsWith\b',
                   r'notLike\b', r'like\b', r'неподобно\b', r'подобно\b',
                   r'notFilled\b', r'filled\b']
    op_joined = '|'.join(op_patterns)
    m = re.match(r'^(.+?)\s+(' + op_joined + r')\s*(.*)?$', s, re.IGNORECASE)
    if m:
        result['field'] = m.group(1).strip()
        result['op'] = m.group(2).strip()
        val_part = m.group(3).strip() if m.group(3) else ''
        if val_part and val_part != '_':
            if val_part == 'true' or val_part == 'false':
                result['value'] = (val_part == 'true')
                result['valueType'] = 'xs:boolean'
            elif re.match(r'^\d{4}-\d{2}-\d{2}T', val_part):
                # дата без valueType → emit_filter_item выведет StandardBeginningDate Custom (дефолт даты в фильтре)
                result['value'] = val_part
            elif re.match(r'^\d+(\.\d+)?$', val_part):
                result['value'] = val_part
                result['valueType'] = 'xs:decimal'
            elif re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.', val_part):
                result['value'] = val_part
                result['valueType'] = 'dcscor:DesignTimeValue'
            else:
                result['value'] = val_part
                result['valueType'] = 'xs:string'
    else:
        result['field'] = s
    return result


def _value_type_for(v, explicit=None):
    if explicit:
        return explicit
    if isinstance(v, bool):
        return 'xs:boolean'
    if isinstance(v, (int, float)):
        return 'xs:decimal'
    vs = str(v)
    if re.match(r'^\d{4}-\d{2}-\d{2}T', vs):
        return 'xs:dateTime'
    if re.match(r'^-?\d+(\.\d+)?$', vs):
        return 'xs:decimal'
    if _REF_TYPE_RE.match(vs):
        return 'dcscor:DesignTimeValue'
    return 'xs:string'


# Значение типа v8:Type (напр. тип «Неопределено» = <prefix>:Undefined) ссылается на тип
# платформы из namespace http://v8.1c.ru/8.2/data/types — платформа объявляет его ЛОКАЛЬНО
# на теге значения (префикс авто: d6p1/d8p1/dN…). Без объявления QName битый.
def _value_type_ns_attr(value_type, value):
    if value_type == 'v8:Type':
        m = re.match(r'^([A-Za-z]\w*):', str(value))
        if m and m.group(1) not in ('xs', 'cfg', 'v8', 'v8ui', 'ent', 'dcscor', 'dcsset', 'dcssch'):
            return f' xmlns:{m.group(1)}="http://v8.1c.ru/8.2/data/types"'
    return ''


def emit_filter_item(lines, item, indent):
    if item.get('group'):
        g = str(item['group'])
        group_type = {'And': 'AndGroup', 'Or': 'OrGroup', 'Not': 'NotGroup'}.get(g, g + 'Group')
        lines.append(f'{indent}<dcsset:item xsi:type="dcsset:FilterItemGroup">')
        if item.get('use') is False:
            lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')   # группа отключена (перед groupType)
        lines.append(f'{indent}\t<dcsset:groupType>{group_type}</dcsset:groupType>')
        if item.get('items'):
            for sub in item['items']:
                if isinstance(sub, str):
                    parsed = parse_filter_shorthand(sub)
                    obj = {'field': parsed['field'], 'op': parsed['op']}
                    if parsed['use'] is False:
                        obj['use'] = False
                    if parsed['value'] is not None:
                        obj['value'] = parsed['value']
                    if parsed.get('valueType'):
                        obj['valueType'] = parsed['valueType']
                    if parsed.get('userSettingID'):
                        obj['userSettingID'] = parsed['userSettingID']
                    if parsed.get('viewMode'):
                        obj['viewMode'] = parsed['viewMode']
                    sub = obj
                emit_filter_item(lines, sub, f'{indent}\t')
        if item.get('presentation'):
            emit_us_presentation(lines, f'{indent}\t', 'dcsset:presentation', item['presentation'])
        if item.get('viewMode'):
            lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
        if item.get('userSettingID'):
            guid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
            lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(guid)}</dcsset:userSettingID>')
        if item.get('userSettingPresentation'):
            emit_us_presentation(lines, f'{indent}\t', 'dcsset:userSettingPresentation', item['userSettingPresentation'])
        lines.append(f'{indent}</dcsset:item>')
        return

    lines.append(f'{indent}<dcsset:item xsi:type="dcsset:FilterItemComparison">')
    if item.get('use') is False:
        lines.append(f'{indent}\t<dcsset:use>false</dcsset:use>')
    lines.append(f'{indent}\t<dcsset:left xsi:type="dcscor:Field">{esc_xml(str(item.get("field", "")))}</dcsset:left>')
    # Регистронезависимый лукап (зеркало PS): Like/LIKE/ПОДОБНО → канон; иначе — как есть
    comp_type = _COMPARISON_TYPES_CI.get(str(item.get('op')).lower())
    if not comp_type:
        comp_type = str(item.get('op'))
    lines.append(f'{indent}\t<dcsset:comparisonType>{esc_xml(comp_type)}</dcsset:comparisonType>')
    val = item.get('value')
    if isinstance(val, list):
        if len(val) == 0:
            lines.append(f'{indent}\t<dcsset:right xsi:type="v8:ValueListType">')
            lines.append(f'{indent}\t\t<v8:valueType/>')
            lines.append(f'{indent}\t\t<v8:lastId xsi:type="xs:decimal">-1</v8:lastId>')
            lines.append(f'{indent}\t</dcsset:right>')
        else:
            for v in val:
                vt = _value_type_for(v, item.get('valueType'))
                v_str = str(v).lower() if isinstance(v, bool) else esc_xml(str(v))
                ns_attr = _value_type_ns_attr(vt, v)
                lines.append(f'{indent}\t<dcsset:right{ns_attr} xsi:type="{vt}">{v_str}</dcsset:right>')
    elif val is not None and (
            re.search(r'Standard(Beginning|End)Date$', str(item.get('valueType') or '')) or
            (not item.get('valueType') and isinstance(val, str) and re.match(r'^\d{4}-\d{2}-\d{2}T', val))):
        # Стандартная дата начала/окончания. Формы: объект {variant, date?} (Custom несёт <v8:date>);
        # строка-вариант "BeginningOfThisDay" (именованный без даты); голая ISO-дата без valueType —
        # шорткат для Custom+date (дата в фильтре почти всегда SBD Custom, корпус 268 vs 2 xs:dateTime).
        sd_type = re.sub(r'^v8:', '', str(item['valueType'])) if item.get('valueType') else 'StandardBeginningDate'
        if isinstance(val, dict):
            variant = str(val.get('variant', '')); date_v = val.get('date')
        elif isinstance(val, str) and re.match(r'^\d{4}-\d{2}-\d{2}T', val):
            variant = 'Custom'; date_v = val
        else:
            variant = str(val); date_v = None
        lines.append(f'{indent}\t<dcsset:right xsi:type="v8:{sd_type}">')
        lines.append(f'{indent}\t\t<v8:variant xsi:type="v8:{sd_type}Variant">{esc_xml(variant)}</v8:variant>')
        if date_v is not None:
            lines.append(f'{indent}\t\t<v8:date>{esc_xml(str(date_v))}</v8:date>')
        lines.append(f'{indent}\t</dcsset:right>')
    elif str(val) == '_':
        # "_" — маркер пустого значения: платформа эмитит пустой self-closing <dcsset:right>
        # (напр. <dcsset:right xsi:type="dcscor:Field"/> — сравнение с незаданным полем).
        vt = str(item['valueType']) if item.get('valueType') else 'xs:string'
        lines.append(f'{indent}\t<dcsset:right xsi:type="{vt}"/>')
    elif val is not None:
        vt = _value_type_for(val, item.get('valueType'))
        v_str = str(val).lower() if isinstance(val, bool) else esc_xml(str(val))
        ns_attr = _value_type_ns_attr(vt, val)
        lines.append(f'{indent}\t<dcsset:right{ns_attr} xsi:type="{vt}">{v_str}</dcsset:right>')
    if item.get('presentation'):
        emit_us_presentation(lines, f'{indent}\t', 'dcsset:presentation', item['presentation'])
    if item.get('viewMode'):
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
    if item.get('userSettingID'):
        uid = new_uuid() if str(item['userSettingID']) == 'auto' else str(item['userSettingID'])
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    if item.get('userSettingPresentation'):
        emit_us_presentation(lines, f'{indent}\t', 'dcsset:userSettingPresentation', item['userSettingPresentation'])
    lines.append(f'{indent}</dcsset:item>')


def emit_filter(lines, items, indent, block_view_mode=None, block_user_setting_id=None, block_user_setting_presentation=None):
    has_items = bool(items) and len(items) > 0
    has_block_meta = (block_view_mode is not None) or (block_user_setting_id is not None) or (block_user_setting_presentation is not None)
    if not has_items and not has_block_meta:
        return
    lines.append(f'{indent}<dcsset:filter>')
    for item in (items or []):
        if isinstance(item, str):
            parsed = parse_filter_shorthand(item)
            obj = {'field': parsed['field'], 'op': parsed['op']}
            if parsed['use'] is False:
                obj['use'] = False
            if parsed['value'] is not None:
                obj['value'] = parsed['value']
            if parsed.get('valueType'):
                obj['valueType'] = parsed['valueType']
            if parsed.get('userSettingID'):
                obj['userSettingID'] = parsed['userSettingID']
            if parsed.get('viewMode'):
                obj['viewMode'] = parsed['viewMode']
            emit_filter_item(lines, obj, f'{indent}\t')
        else:
            emit_filter_item(lines, item, f'{indent}\t')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    if block_user_setting_id is not None:
        uid = new_uuid() if str(block_user_setting_id) == 'auto' else str(block_user_setting_id)
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    if block_user_setting_presentation is not None:
        emit_us_presentation(lines, f'{indent}\t', 'dcsset:userSettingPresentation', block_user_setting_presentation)
    lines.append(f'{indent}</dcsset:filter>')


def emit_order(lines, items, indent, skip_auto=False, block_view_mode=None, block_user_setting_id=None, block_user_setting_presentation=None):
    has_items = bool(items) and len(items) > 0
    has_block_meta = (block_view_mode is not None) or (block_user_setting_id is not None) or (block_user_setting_presentation is not None)
    if not has_items and not has_block_meta:
        return
    lines.append(f'{indent}<dcsset:order>')
    for item in (items or []):
        if isinstance(item, str):
            if item == 'Auto':
                if not skip_auto:
                    lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemAuto"/>')
            else:
                parts = re.split(r'\s+', item)
                field = parts[0]
                direction = 'Asc'
                if len(parts) > 1 and re.match(r'(?i)^(desc|убыв)', parts[1]):
                    direction = 'Desc'
                elif len(parts) > 1 and re.match(r'(?i)^(asc|возр)', parts[1]):
                    direction = 'Asc'
                lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemField">')
                lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(field)}</dcsset:field>')
                lines.append(f'{indent}\t\t<dcsset:orderType>{direction}</dcsset:orderType>')
                lines.append(f'{indent}\t</dcsset:item>')
        else:
            if item.get('field') == 'Auto' or item.get('type') == 'auto':
                if not skip_auto:
                    lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemAuto"/>')
                continue
            direction = str(item['direction']) if item.get('direction') else 'Asc'
            if re.match(r'(?i)^(desc|убыв)', direction):
                direction = 'Desc'
            elif re.match(r'(?i)^(asc|возр)', direction):
                direction = 'Asc'
            lines.append(f'{indent}\t<dcsset:item xsi:type="dcsset:OrderItemField">')
            if item.get('use') is False:
                lines.append(f'{indent}\t\t<dcsset:use>false</dcsset:use>')
            lines.append(f'{indent}\t\t<dcsset:field>{esc_xml(str(item.get("field", "")))}</dcsset:field>')
            lines.append(f'{indent}\t\t<dcsset:orderType>{direction}</dcsset:orderType>')
            if item.get('viewMode'):
                lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(item["viewMode"]))}</dcsset:viewMode>')
            lines.append(f'{indent}\t</dcsset:item>')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    if block_user_setting_id is not None:
        uid = new_uuid() if str(block_user_setting_id) == 'auto' else str(block_user_setting_id)
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    if block_user_setting_presentation is not None:
        emit_us_presentation(lines, f'{indent}\t', 'dcsset:userSettingPresentation', block_user_setting_presentation)
    lines.append(f'{indent}</dcsset:order>')


def emit_appearance_value(lines, key, val, indent):
    lines.append(f'{indent}<dcscor:item xsi:type="dcsset:SettingsParameterValue">')

    def _has_key(o, k):
        return isinstance(o, dict) and (k in o)

    def _get(o, k):
        return o.get(k) if isinstance(o, dict) else None

    is_top_level_line = _has_key(val, '@type') and (str(_get(val, '@type')) == 'Line')
    use_wrapper = False
    inner_val = val
    nested_items = None
    if is_top_level_line:
        if _has_key(val, 'use') and (_get(val, 'use') is False):
            use_wrapper = True
        if _has_key(val, 'items'):
            nested_items = _get(val, 'items')
    elif _has_key(val, 'value') and isinstance(val, dict):
        inner_val = _get(val, 'value')
        if _has_key(val, 'use') and (_get(val, 'use') is False):
            use_wrapper = True
        if _has_key(val, 'items'):
            nested_items = _get(val, 'items')
    if use_wrapper:
        lines.append(f'{indent}\t<dcscor:use>false</dcscor:use>')
    lines.append(f'{indent}\t<dcscor:parameter>{esc_xml(key)}</dcscor:parameter>')

    is_font_dict = isinstance(inner_val, dict) and inner_val.get('@type') is not None and str(inner_val.get('@type')) == 'Font'
    is_line_dict = _has_key(inner_val, '@type') and (str(_get(inner_val, '@type')) == 'Line')
    is_dict = isinstance(inner_val, dict)
    if is_line_dict:
        lw = _get(inner_val, 'width') if _has_key(inner_val, 'width') else 0
        lg = ('true' if _get(inner_val, 'gap') else 'false') if _has_key(inner_val, 'gap') else 'false'
        ls = str(_get(inner_val, 'style')) if _has_key(inner_val, 'style') else 'None'
        lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Line" width="{lw}" gap="{lg}">')
        lines.append(f'{indent}\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">{esc_xml(ls)}</v8ui:style>')
        lines.append(f'{indent}\t</dcscor:value>')
    elif is_font_dict:
        attr_parts = []
        for attr_name in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
            if attr_name in inner_val:
                av = inner_val[attr_name]
                if av is not None:
                    attr_parts.append(f'{attr_name}="{esc_xml(str(av))}"')
        lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Font" {" ".join(attr_parts)}/>')
    elif is_dict and _has_key(inner_val, 'field'):
        # Ссылка на поле (dcscor:Field) — значение параметра оформления = поле компоновки
        lines.append(f'{indent}\t<dcscor:value xsi:type="dcscor:Field">{esc_xml(str(_get(inner_val, "field")))}</dcscor:value>')
    elif is_dict:
        # Локализуемый текст параметра оформления: платформа объявляет xsi:type на dcscor:value
        emit_mltext(lines, f'{indent}\t', 'dcscor:value', inner_val, xsi_type='v8:LocalStringType')
    else:
        actual_val = str(inner_val)
        key_type_map = {
            'Размещение': 'dcscor:DataCompositionTextPlacementType',
            'ГоризонтальноеПоложение': 'v8ui:HorizontalAlign',
            'ВертикальноеПоложение': 'v8ui:VerticalAlign',
            'ОриентацияТекста': 'xs:decimal',
            'РасположениеИтогов': 'dcscor:DataCompositionTotalPlacement',
            'ТипМакета': 'dcsset:DataCompositionGroupTemplateType',
        }
        key_type = key_type_map.get(key)
        if key_type:
            lines.append(f'{indent}\t<dcscor:value xsi:type="{key_type}">{esc_xml(actual_val)}</dcscor:value>')
        elif re.match(r'^(style|web|win):', actual_val):
            lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Color">{esc_xml(actual_val)}</dcscor:value>')
        elif actual_val == 'true' or actual_val == 'false':
            lines.append(f'{indent}\t<dcscor:value xsi:type="xs:boolean">{actual_val}</dcscor:value>')
        elif key == 'Текст' or key == 'Заголовок' or key == 'Формат':
            # Голая строка = плоский xs:string (нелокализованный литерал). Локализуемый → объект {ru,en}.
            # Пустая строка → самозакрывающийся тег (как у платформы).
            if actual_val == '':
                lines.append(f'{indent}\t<dcscor:value xsi:type="xs:string"/>')
            else:
                lines.append(f'{indent}\t<dcscor:value xsi:type="xs:string">{esc_xml(actual_val)}</dcscor:value>')
        elif re.match(r'^-?\d+(\.\d+)?$', actual_val):
            lines.append(f'{indent}\t<dcscor:value xsi:type="xs:decimal">{actual_val}</dcscor:value>')
        elif key == 'ЦветТекста' or key == 'ЦветФона' or key == 'ЦветГраницы':
            lines.append(f'{indent}\t<dcscor:value xsi:type="v8ui:Color">{esc_xml(actual_val)}</dcscor:value>')
        else:
            lines.append(f'{indent}\t<dcscor:value xsi:type="xs:string">{esc_xml(actual_val)}</dcscor:value>')
    if nested_items:
        if isinstance(nested_items, dict):
            for nk, nv in nested_items.items():
                emit_appearance_value(lines, nk, nv, f'{indent}\t')
    lines.append(f'{indent}</dcscor:item>')


# === Группировка строк динамического списка (DCS-структура ListSettings) ===
# Линейная цепочка <dcsset:item StructureItemGroup> (каждый уровень = одно поле в groupItems;
# вложенность — через дочерний <dcsset:item>). Плоская модель уровней (список всегда линеен).
def get_list_grouping_value(s):
    for k in ('grouping', 'structure', 'группировка'):
        if s.get(k):
            return s[k]
    return None


def parse_list_grouping(grouping):
    # Шорткат "A > B > C" → массив имён; массив строк/объектов → как есть.
    if not grouping:
        return []
    if isinstance(grouping, str):
        return [p.strip() for p in re.split(r'\s*>\s*', grouping) if p.strip()]
    return list(grouping)


def emit_group_item_field(lines, level, indent):
    if isinstance(level, str):
        field, gt, pat = level, 'Items', 'None'
        pab = pae = '0001-01-01T00:00:00'
    else:
        field = str(level.get('field', ''))
        gt = str(level.get('groupType') or 'Items')
        pat = str(level.get('periodAdditionType') or 'None')
        pab = str(level.get('periodAdditionBegin') or '0001-01-01T00:00:00')
        pae = str(level.get('periodAdditionEnd') or '0001-01-01T00:00:00')
    lines.append(f'{indent}<dcsset:item xsi:type="dcsset:GroupItemField">')
    lines.append(f'{indent}\t<dcsset:field>{esc_xml(field)}</dcsset:field>')
    lines.append(f'{indent}\t<dcsset:groupType>{esc_xml(gt)}</dcsset:groupType>')
    lines.append(f'{indent}\t<dcsset:periodAdditionType>{esc_xml(pat)}</dcsset:periodAdditionType>')
    # Авто-детект: ISO-дата → xs:dateTime, иначе путь → dcscor:Field.
    pab_t = 'xs:dateTime' if re.match(r'^\d{4}-\d{2}-\d{2}T', pab) else 'dcscor:Field'
    pae_t = 'xs:dateTime' if re.match(r'^\d{4}-\d{2}-\d{2}T', pae) else 'dcscor:Field'
    lines.append(f'{indent}\t<dcsset:periodAdditionBegin xsi:type="{pab_t}">{esc_xml(pab)}</dcsset:periodAdditionBegin>')
    lines.append(f'{indent}\t<dcsset:periodAdditionEnd xsi:type="{pae_t}">{esc_xml(pae)}</dcsset:periodAdditionEnd>')
    lines.append(f'{indent}</dcsset:item>')


def emit_list_grouping_levels(lines, levels, i, indent):
    lines.append(f'{indent}<dcsset:item xsi:type="dcsset:StructureItemGroup">')
    lines.append(f'{indent}\t<dcsset:groupItems>')
    emit_group_item_field(lines, levels[i], f'{indent}\t\t')
    lines.append(f'{indent}\t</dcsset:groupItems>')
    if i < len(levels) - 1:
        emit_list_grouping_levels(lines, levels, i + 1, f'{indent}\t')
    lines.append(f'{indent}</dcsset:item>')


def emit_list_grouping(lines, grouping, indent):
    levels = parse_list_grouping(grouping)
    if not levels:
        return
    emit_list_grouping_levels(lines, levels, 0, indent)


# === Вычисляемые поля DataSet динамического списка (<CalculatedField>) ===
# Зеркало skd calculatedFields: shorthand "Имя [Заголовок]: тип = Выражение #noField #noFilter
# #noGroup #noOrder" или объект. Форм-специфика: dcssch:-теги + presentationExpression/orderExpression.
_CALC_RESTRICT_MAP = {'noField': 'field', 'noFilter': 'condition', 'noCondition': 'condition',
                      'noGroup': 'group', 'noOrder': 'order'}
_DCS_COMMON_NS = 'http://v8.1c.ru/8.1/data-composition-system/common'


def parse_calc_shorthand(s):
    restrict = re.findall(r'#(noField|noFilter|noCondition|noGroup|noOrder)\b', s)
    s = re.sub(r'\s*#(?:noField|noFilter|noCondition|noGroup|noOrder)\b', '', s)
    eq = s.find('=')
    lhs, rhs = (s[:eq], s[eq + 1:].strip()) if eq > 0 else (s, '')
    title = ''
    m = re.search(r'\[([^\]]+)\]', lhs)
    if m:
        title = m.group(1)
        lhs = re.sub(r'\s*\[[^\]]+\]', '', lhs)
    lhs = lhs.strip()
    typ, data_path = '', lhs
    if ':' in lhs:
        data_path, t = lhs.split(':', 1)
        data_path, typ = data_path.strip(), resolve_type_str(t.strip())
    return {'dataPath': data_path, 'expression': rhs, 'type': typ, 'title': title, 'restrict': restrict}


def emit_calc_fields(lines, calc_fields, indent):
    if not calc_fields:
        return
    for cf in calc_fields:
        if isinstance(cf, str):
            p = parse_calc_shorthand(cf)
            data_path, expression, title = p['dataPath'], p['expression'], p['title']
            type_str = p['type']
            restrict = [_CALC_RESTRICT_MAP[r] for r in p['restrict'] if r in _CALC_RESTRICT_MAP]
            pres_expr = order_expr = None
        else:
            data_path = str(cf.get('dataPath') or cf.get('field') or cf.get('name', ''))
            expression = str(cf.get('expression', ''))
            title = cf.get('title')
            type_str = cf.get('valueType') or cf.get('type')
            type_str = str(type_str) if type_str else None
            ur = cf.get('useRestriction') or cf.get('restrict')
            if isinstance(ur, dict):
                restrict = [k for k in ('field', 'condition', 'group', 'order') if ur.get(k)]
            elif isinstance(ur, str):
                restrict = [_CALC_RESTRICT_MAP.get(t.strip().lstrip('#'), t.strip().lstrip('#')) for t in ur.split() if t.strip()]
            elif isinstance(ur, list):
                restrict = [_CALC_RESTRICT_MAP.get(str(r), str(r)) for r in ur]
            else:
                restrict = []
            pres_expr = cf.get('presentationExpression')
            order_expr = cf.get('orderExpression')
        ci = f'{indent}\t'
        lines.append(f'{indent}<CalculatedField>')
        lines.append(f'{ci}<dcssch:dataPath>{esc_xml(data_path)}</dcssch:dataPath>')
        lines.append(f'{ci}<dcssch:expression>{esc_xml(expression)}</dcssch:expression>')
        if title:
            emit_mltext(lines, ci, 'dcssch:title', title, xsi_type='v8:LocalStringType')
        if restrict:
            lines.append(f'{ci}<dcssch:useRestriction>')
            for r in ('field', 'condition', 'group', 'order'):
                if r in restrict:
                    lines.append(f'{ci}\t<dcssch:{r}>true</dcssch:{r}>')
            lines.append(f'{ci}</dcssch:useRestriction>')
        if pres_expr:
            lines.append(f'{ci}<dcssch:presentationExpression>{esc_xml(str(pres_expr))}</dcssch:presentationExpression>')
        if order_expr:
            for oe in (order_expr if isinstance(order_expr, list) else [order_expr]):
                if isinstance(oe, str):
                    expr_v, otype, auto = oe, 'Asc', 'false'
                else:
                    expr_v = str(oe.get('expression', ''))
                    otype = str(oe.get('orderType', 'Asc'))
                    auto = 'true' if oe.get('autoOrder') else 'false'
                lines.append(f'{ci}<dcssch:orderExpression>')
                lines.append(f'{ci}\t<expression xmlns="{_DCS_COMMON_NS}">{esc_xml(expr_v)}</expression>')
                lines.append(f'{ci}\t<orderType xmlns="{_DCS_COMMON_NS}">{otype}</orderType>')
                lines.append(f'{ci}\t<autoOrder xmlns="{_DCS_COMMON_NS}">{auto}</autoOrder>')
                lines.append(f'{ci}</dcssch:orderExpression>')
        if type_str:
            emit_dl_value_type(lines, type_str, ci)
        lines.append(f'{indent}</CalculatedField>')


# Ограничения использования поля/вычисляемого поля (useRestriction / attributeUseRestriction).
# Значение: объект {field?,condition?,group?,order?} | флаг-строка "#noField …" | массив.
def parse_restrict(ur):
    if not ur:
        return []
    if isinstance(ur, dict):
        return [k for k in ('field', 'condition', 'group', 'order') if ur.get(k)]
    if isinstance(ur, str):
        return [_CALC_RESTRICT_MAP.get(t.strip().lstrip('#'), t.strip().lstrip('#')) for t in ur.split() if t.strip()]
    if isinstance(ur, list):
        return [_CALC_RESTRICT_MAP.get(str(r), str(r)) for r in ur]
    return []


def emit_restrict_block(lines, tag, ur, indent):
    r = parse_restrict(ur)
    if not r:
        return
    lines.append(f'{indent}<dcssch:{tag}>')
    for k in ('field', 'condition', 'group', 'order'):
        if k in r:
            lines.append(f'{indent}\t<dcssch:{k}>true</dcssch:{k}>')
    lines.append(f'{indent}</dcssch:{tag}>')


def emit_conditional_appearance(lines, items, indent, block_view_mode=None, block_user_setting_id=None, wrap_tag='dcsset:conditionalAppearance', block_user_setting_presentation=None):
    has_items = bool(items) and len(items) > 0
    has_block_meta = (block_view_mode is not None) or (block_user_setting_id is not None) or (block_user_setting_presentation is not None)
    if not has_items and not has_block_meta:
        return
    lines.append(f'{indent}<{wrap_tag}>')
    for ca in (items or []):
        lines.append(f'{indent}\t<dcsset:item>')
        if ca.get('use') is False:
            lines.append(f'{indent}\t\t<dcsset:use>false</dcsset:use>')
        if ca.get('selection') and len(ca['selection']) > 0:
            lines.append(f'{indent}\t\t<dcsset:selection>')
            for sel in ca['selection']:
                lines.append(f'{indent}\t\t\t<dcsset:item>')
                lines.append(f'{indent}\t\t\t\t<dcsset:field>{esc_xml(str(sel))}</dcsset:field>')
                lines.append(f'{indent}\t\t\t</dcsset:item>')
            lines.append(f'{indent}\t\t</dcsset:selection>')
        else:
            lines.append(f'{indent}\t\t<dcsset:selection/>')
        if ca.get('filter') and len(ca['filter']) > 0:
            emit_filter(lines, ca['filter'], f'{indent}\t\t')
        else:
            lines.append(f'{indent}\t\t<dcsset:filter/>')
        if ca.get('appearance'):
            lines.append(f'{indent}\t\t<dcsset:appearance>')
            for k, v in ca['appearance'].items():
                emit_appearance_value(lines, k, v, f'{indent}\t\t\t')
            lines.append(f'{indent}\t\t</dcsset:appearance>')
        if ca.get('presentation'):
            if isinstance(ca['presentation'], dict):
                # Мультиязык → LocalStringType (платформа объявляет тип у локализованного presentation)
                lines.append(f'{indent}\t\t<dcsset:presentation xsi:type="v8:LocalStringType">')
                emit_ml_items(lines, f'{indent}\t\t\t', ca['presentation'])
                lines.append(f'{indent}\t\t</dcsset:presentation>')
            else:
                lines.append(f'{indent}\t\t<dcsset:presentation xsi:type="xs:string">{esc_xml(str(ca["presentation"]))}</dcsset:presentation>')
        if ca.get('viewMode'):
            lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(ca["viewMode"]))}</dcsset:viewMode>')
        if ca.get('userSettingID'):
            uid = new_uuid() if str(ca['userSettingID']) == 'auto' else str(ca['userSettingID'])
            lines.append(f'{indent}\t\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
        if ca.get('userSettingPresentation'):
            emit_us_presentation(lines, f'{indent}\t\t', 'dcsset:userSettingPresentation', ca['userSettingPresentation'])
        if ca.get('useInDontUse') and len(ca['useInDontUse']) > 0:
            use_in_order = ['group', 'hierarchicalGroup', 'overall', 'fieldsHeader', 'header',
                            'parameters', 'filter', 'resourceFieldsHeader', 'overallHeader',
                            'overallResourceFieldsHeader']
            sset = {str(n): True for n in ca['useInDontUse']}
            for n in use_in_order:
                if n in sset:
                    tag = 'useIn' + n[0].upper() + n[1:]
                    lines.append(f'{indent}\t\t<dcsset:{tag}>DontUse</dcsset:{tag}>')
        lines.append(f'{indent}\t</dcsset:item>')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    if block_user_setting_id is not None:
        uid = new_uuid() if str(block_user_setting_id) == 'auto' else str(block_user_setting_id)
        lines.append(f'{indent}\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
    if block_user_setting_presentation is not None:
        emit_us_presentation(lines, f'{indent}\t', 'dcsset:userSettingPresentation', block_user_setting_presentation)
    lines.append(f'{indent}</{wrap_tag}>')


def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


# --- ID allocator ---
_next_id = 0

def new_id():
    global _next_id
    _next_id += 1
    return _next_id


# Уникальность имён внутри коллекции (1С: элементы/реквизиты/команды/параметры/колонки — каждое своё
# пространство имён). Дубль → битый XML, форма не открывается, поэтому fail-fast.
_seen_element_names = set()  # пул имён элементов (глобально по всей форме)

def _ensure_unique(name, seen, kind):
    if name in seen:
        print(f"[ERROR] Duplicate {kind} name '{name}' — names must be unique within their collection in a 1C form (set a unique 'name')", file=sys.stderr)
        sys.exit(1)
    seen.add(name)


# --- Event handler name generator ---

EVENT_SUFFIX_MAP = {
    "OnChange": "\u041f\u0440\u0438\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0438",
    "StartChoice": "\u041d\u0430\u0447\u0430\u043b\u043e\u0412\u044b\u0431\u043e\u0440\u0430",
    "ChoiceProcessing": "\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430\u0412\u044b\u0431\u043e\u0440\u0430",
    "AutoComplete": "\u0410\u0432\u0442\u043e\u041f\u043e\u0434\u0431\u043e\u0440",
    "Clearing": "\u041e\u0447\u0438\u0441\u0442\u043a\u0430",
    "Opening": "\u041e\u0442\u043a\u0440\u044b\u0442\u0438\u0435",
    "Click": "\u041d\u0430\u0436\u0430\u0442\u0438\u0435",
    "OnActivateRow": "\u041f\u0440\u0438\u0410\u043a\u0442\u0438\u0432\u0438\u0437\u0430\u0446\u0438\u0438\u0421\u0442\u0440\u043e\u043a\u0438",
    "BeforeAddRow": "\u041f\u0435\u0440\u0435\u0434\u041d\u0430\u0447\u0430\u043b\u043e\u043c\u0414\u043e\u0431\u0430\u0432\u043b\u0435\u043d\u0438\u044f",
    "BeforeDeleteRow": "\u041f\u0435\u0440\u0435\u0434\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u0435\u043c",
    "BeforeRowChange": "\u041f\u0435\u0440\u0435\u0434\u041d\u0430\u0447\u0430\u043b\u043e\u043c\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u044f",
    "OnStartEdit": "\u041f\u0440\u0438\u041d\u0430\u0447\u0430\u043b\u0435\u0420\u0435\u0434\u0430\u043a\u0442\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u044f",
    "OnEndEdit": "\u041f\u0440\u0438\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u0438\u0420\u0435\u0434\u0430\u043a\u0442\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u044f",
    "Selection": "\u0412\u044b\u0431\u043e\u0440\u0421\u0442\u0440\u043e\u043a\u0438",
    "OnCurrentPageChange": "\u041f\u0440\u0438\u0421\u043c\u0435\u043d\u0435\u0421\u0442\u0440\u0430\u043d\u0438\u0446\u044b",
    "TextEditEnd": "\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u0435\u0412\u0432\u043e\u0434\u0430\u0422\u0435\u043a\u0441\u0442\u0430",
    "URLProcessing": "\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430\u041d\u0430\u0432\u0438\u0433\u0430\u0446\u0438\u043e\u043d\u043d\u043e\u0439\u0421\u0441\u044b\u043b\u043a\u0438",
    "DragStart": "\u041d\u0430\u0447\u0430\u043b\u043e\u041f\u0435\u0440\u0435\u0442\u0430\u0441\u043a\u0438\u0432\u0430\u043d\u0438\u044f",
    "Drag": "\u041f\u0435\u0440\u0435\u0442\u0430\u0441\u043a\u0438\u0432\u0430\u043d\u0438\u0435",
    "DragCheck": "\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430\u041f\u0435\u0440\u0435\u0442\u0430\u0441\u043a\u0438\u0432\u0430\u043d\u0438\u044f",
    "Drop": "\u041f\u043e\u043c\u0435\u0449\u0435\u043d\u0438\u0435",
    "AfterDeleteRow": "\u041f\u043e\u0441\u043b\u0435\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u044f",
}

KNOWN_EVENTS = {
    "input": ["OnChange", "StartChoice", "ChoiceProcessing", "AutoComplete", "TextEditEnd", "Clearing", "Creating", "EditTextChange"],
    "check": ["OnChange"],
    "radio": ["OnChange"],
    "label": ["Click", "URLProcessing"],
    "labelField": ["OnChange", "StartChoice", "ChoiceProcessing", "Click", "URLProcessing", "Clearing"],
    "table": ["Selection", "BeforeAddRow", "AfterDeleteRow", "BeforeDeleteRow", "OnActivateRow", "OnEditEnd", "OnStartEdit", "BeforeRowChange", "BeforeEditEnd", "ValueChoice", "OnActivateCell", "OnActivateField", "Drag", "DragStart", "DragCheck", "DragEnd", "OnGetDataAtServer", "BeforeLoadUserSettingsAtServer", "OnUpdateUserSettingSetAtServer", "OnChange"],
    "pages": ["OnCurrentPageChange"],
    "page": ["OnCurrentPageChange"],
    "button": ["Click"],
    "picField": ["OnChange", "StartChoice", "ChoiceProcessing", "Click", "Clearing"],
    "calendar": ["OnChange", "OnActivate"],
    "picture": ["Click"],
    "cmdBar": [],
    "popup": [],
    "group": [],
}

KNOWN_FORM_EVENTS = [
    "OnCreateAtServer", "OnOpen", "BeforeClose", "OnClose", "NotificationProcessing",
    "ChoiceProcessing", "OnReadAtServer", "AfterWriteAtServer", "BeforeWriteAtServer",
    "AfterWrite", "BeforeWrite", "OnWriteAtServer", "FillCheckProcessingAtServer",
    "OnLoadDataFromSettingsAtServer", "BeforeLoadDataFromSettingsAtServer",
    "OnSaveDataInSettingsAtServer", "ExternalEvent", "OnReopen", "Opening",
]

KNOWN_KEYS = {
    "group", "columnGroup", "buttonGroup", "input", "check", "radio", "label", "labelField", "table", "pages", "page",
    "button", "picture", "picField", "calendar", "cmdBar", "popup",
    "showInHeader",
    "radioButtonType", "choiceList", "columnsCount", "checkBoxType", "editMode",
    "name", "path", "title", "tooltip", "tooltipRepresentation", "extendedTooltip",
    "visible", "hidden", "enabled", "disabled", "readOnly", "userVisible",
    "events", "on", "handlers",
    "selectionMode", "showCurrentDate", "widthInMonths", "heightInMonths", "showMonthsPanel",
    "titleLocation", "representation", "width", "height",
    "horizontalStretch", "verticalStretch", "autoMaxWidth", "autoMaxHeight",
    "maxWidth", "maxHeight",
    "groupHorizontalAlign", "groupVerticalAlign", "horizontalAlign",
    "multiLine", "passwordMode", "choiceButton", "clearButton",
    "spinButton", "dropListButton", "markIncomplete", "skipOnInput", "inputHint",
    "textEdit", "choiceList",
    "wrap", "openButton", "listChoiceMode", "showInHeader", "showInFooter",
    "extendedEditMultipleValues", "chooseType", "autoCellHeight",
    "choiceButtonRepresentation", "footerHorizontalAlign", "headerHorizontalAlign",
    "headerDataPath", "headerFormat", "currentRowUse",
    "format", "editFormat", "choiceParameters", "choiceParameterLinks", "typeLink",
    "hyperlink", "formatted",
    "collapsedTitle", "showTitle", "united", "collapsed", "behavior",
    "children", "columns",
    "changeRowSet", "changeRowOrder", "autoInsertNewRow", "rowFilter", "header", "footer",
    "commandBarLocation", "searchStringLocation", "viewStatusLocation", "searchControlLocation",
    "excludedCommands",
    "pagesRepresentation",
    "type", "command", "commandName", "stdCommand", "parameter", "defaultButton", "locationInCommandBar", "displayImportance",
    "commandBar", "contextMenu", "commandSource",
    "src", "valuesPicture", "loadTransparent", "headerPicture", "footerPicture",
    "autofill",
    "choiceMode", "initialTreeView", "enableDrag", "enableStartDrag",
    "rowSelectionMode", "verticalLines", "horizontalLines",
    "rowPictureDataPath", "tableAutofill", "heightInTableRows",
    "multipleChoice", "searchOnInput", "shortcut",
    # dynamic-list table block
    "defaultItem", "useAlternationRowColor", "fileDragMode", "autoRefresh",
    "autoRefreshPeriod", "choiceFoldersAndItems", "restoreCurrentRow", "showRoot",
    "allowRootChoice", "updateOnDataChange", "allowGettingCurrentRowURL",
    "userSettingsGroup", "rowsPicture",
    # AutoCommandBar-маркер (autofill heuristic) на элементе/таблице
    "autoCmdBar",
    # дополнения командной панели таблицы (тип-ключи + свойства)
    "searchString", "viewStatus", "searchControl", "source", "horizontalLocation", "additions",
    # generic-скаляры (pass-through)
    "verticalAlign", "throughAlign", "enableContentChange", "pictureSize", "titleHeight",
    "childItemsWidth", "showLeftMargin", "cellHyperlink", "viewMode", "verticalScrollBar",
    "rowInputMode", "mask", "createButton", "fixingInTable", "verticalSpacing",
    # InputField choice-скаляры
    "choiceListButton", "quickChoice", "autoChoiceIncomplete",
    "choiceForm", "choiceHistoryOnInput", "footerDataPath", "minValue", "maxValue",
    # Button — пометка toggle-кнопки
    "checked",
    # спец-поля (документ/датчик/диаграмма) — тип-ключи + типоспец. скаляры
    "spreadsheet", "html", "textDoc", "formattedDoc", "progressBar", "trackBar",
    "chart", "ganttChart", "graphicalSchema", "planner", "periodField", "dendrogram", "ganttTable",
    "showPercent", "largeStep", "markingStep", "step",
    "horizontalScrollBar", "viewScalingMode", "output", "selectionShowMode", "protection",
    "edit", "showGrid", "showGroups", "showHeaders", "showRowAndColumnNames", "showCellNames",
    "pointerType", "drawingSelectionShowMode", "warningOnEditRepresentation", "markingAppearance",
    # report-form контекст (generic-скаляры элементов)
    "horizontalSpacing", "representationInContextMenu", "settingsNamedItemDetailedRepresentation",
    # хвост: высота элемента списка / ширина выпадающего списка / картинка кнопки выбора / прозрачный пиксель
    "itemHeight", "dropListWidth", "choiceButtonPicture", "transparentPixel",
    # хвост CI-форм: динамический заголовок / расширенное редактирование / высота таблицы
    "titleDataPath", "extendedEdit", "maxRowsCount", "autoMaxRowsCount", "heightControlVariant",
    "warningOnEdit", "nonselectedPictureText", "editTextUpdate", "footerText",
}

# picture/picField — НИЗКИЙ приоритет: 'picture' это и тип (PictureDecoration), и свойство-иконка
# у popup/button/cmdBar. Тип-ключ владельца (popup/button/…) должен выиграть.
# pages/page ПЕРЕД group: у Page/Pages ключ 'group' — это направление раскладки детей
# (<Group>Horizontal</Group>), а не тип UsualGroup. Реальная UsualGroup ключа page/pages не несёт.
TYPE_KEYS = ["columnGroup", "buttonGroup", "pages", "page", "group", "input", "check", "radio", "label", "labelField", "table",
             "button", "calendar", "cmdBar", "popup", "searchString", "viewStatus", "searchControl", "picField", "picture",
             "spreadsheet", "html", "textDoc", "formattedDoc", "progressBar", "trackBar",
             "chart", "ganttChart", "graphicalSchema", "planner", "periodField", "dendrogram"]

# Synonyms: model often writes XML name or Russian (ПолеПереключателя/RadioButtonField → radio)
ELEMENT_TYPE_SYNONYMS = {
    "commandBar": "cmdBar",
    "autoCommandBar": "autoCmdBar",
    "КоманднаяПанель": "cmdBar",
    "InputField": "input",
    "ПолеВвода": "input",
    "CheckBoxField": "check",
    "ПолеФлажка": "check",
    "RadioButtonField": "radio",
    "ПолеПереключателя": "radio",
    "radioButton": "radio",
    "PictureField": "picField",
    "ПолеКартинки": "picField",
    "LabelField": "labelField",
    "ПолеНадписи": "labelField",
    "CalendarField": "calendar",
    "ПолеКалендаря": "calendar",
    "LabelDecoration": "label",
    "Надпись": "label",
    "PictureDecoration": "picture",
    "Картинка": "picture",
    "UsualGroup": "group",
    "Группа": "group",
    "ОбычнаяГруппа": "group",
    "ColumnGroup": "columnGroup",
    "ГруппаКолонок": "columnGroup",
    "Pages": "pages",
    "ГруппаСтраниц": "pages",
    "Page": "page",
    "Страница": "page",
    "Table": "table",
    "Таблица": "table",
    "Button": "button",
    "Кнопка": "button",
    "Popup": "popup",
    "ВсплывающееМеню": "popup",
    # дополнения командной панели таблицы — forgiving: XML-тег/Type/рус.имя → канон
    "SearchStringAddition": "searchString",
    "SearchStringRepresentation": "searchString",
    "строкаПоиска": "searchString",
    "отображениеСтрокиПоиска": "searchString",
    "Отображение строки поиска": "searchString",
    "ViewStatusAddition": "viewStatus",
    "ViewStatusRepresentation": "viewStatus",
    "состояниеПросмотра": "viewStatus",
    "Состояние просмотра": "viewStatus",
    "SearchControlAddition": "searchControl",
    "SearchControl": "searchControl",
    "управлениеПоиском": "searchControl",
    "Управление поиском": "searchControl",
    # Спец-поля (документ/датчик) — XML-имя/рус. → канон
    "SpreadSheetDocumentField": "spreadsheet",
    "ПолеТабличногоДокумента": "spreadsheet",
    "HTMLDocumentField": "html",
    "ПолеHTMLДокумента": "html",
    "TextDocumentField": "textDoc",
    "ПолеТекстовогоДокумента": "textDoc",
    "FormattedDocumentField": "formattedDoc",
    "ПолеФорматированногоДокумента": "formattedDoc",
    "ProgressBarField": "progressBar",
    "ПолеИндикатора": "progressBar",
    "TrackBarField": "trackBar",
    "ПолеПолосыРегулирования": "trackBar",
    "ChartField": "chart",
    "ПолеДиаграммы": "chart",
    "GanttChartField": "ganttChart",
    "ПолеДиаграммыГанта": "ganttChart",
    "GraphicalSchemaField": "graphicalSchema",
    "ПолеГрафическойСхемы": "graphicalSchema",
    "PlannerField": "planner",
    "ПолеПланировщика": "planner",
    "PeriodField": "periodField",
    "ПолеПериода": "periodField",
    "DendrogramField": "dendrogram",
    "ПолеДендрограммы": "dendrogram",
}

# Тип-синонимы, применяемые ТОЛЬКО к строковому значению (имя элемента); объект/массив
# у того же слова — companion-панель (свойство), см. normalize_panel_synonyms.
STR_ONLY_TYPE_SYNONYMS = {"commandBar", "autoCommandBar", "КоманднаяПанель"}

# Companion-панели как СВОЙСТВА (значение объект/массив): синоним → каноника.
PANEL_SYNONYMS = {
    'commandBar': ['commandBar', 'autoCommandBar', 'AutoCommandBar', 'autoCmdBar', 'cmdBar', 'КоманднаяПанель'],
    'contextMenu': ['contextMenu', 'ContextMenu', 'КонтекстноеМеню'],
}


def normalize_panel_synonyms(el):
    if not isinstance(el, dict):
        return
    for canon, syns in PANEL_SYNONYMS.items():
        for syn in syns:
            if syn in el and isinstance(el[syn], (list, dict)):
                if syn != canon and canon not in el:
                    el[canon] = el.pop(syn)
                break


# Maps Russian/English root of typed reference path to canonical English root
REF_ROOT_SYNONYMS = {
    "Перечисление": "Enum",
    "Справочник": "Catalog",
    "Документ": "Document",
    "ПланСчетов": "ChartOfAccounts",
    "ПланВидовХарактеристик": "ChartOfCharacteristicTypes",
    "ПланВидовРасчета": "ChartOfCalculationTypes",
    "ПланВидовРасчёта": "ChartOfCalculationTypes",
    "ПланОбмена": "ExchangePlan",
    "БизнесПроцесс": "BusinessProcess",
    "Задача": "Task",
    "РегистрСведений": "InformationRegister",
    "РегистрНакопления": "AccumulationRegister",
    "РегистрБухгалтерии": "AccountingRegister",
    "РегистрРасчета": "CalculationRegister",
    "РегистрРасчёта": "CalculationRegister",
    "ЖурналДокументов": "DocumentJournal",
    "КритерийОтбора": "FilterCriterion",
}
ENUM_VALUE_SYNONYMS = {"EnumValue", "ЗначениеПеречисления"}


def normalize_meta_type_ref(ref):
    # "Справочник.Контрагенты" → "Catalog.Контрагенты"; уже англ — без изменений
    if not ref:
        return ref
    dot = ref.find('.')
    if dot < 1:
        return ref
    root = ref[:dot]
    if root in REF_ROOT_SYNONYMS:
        return REF_ROOT_SYNONYMS[root] + ref[dot:]
    return ref


def normalize_choice_value(value):
    """Returns dict {xsi_type, text} for a choiceList item value."""
    if isinstance(value, bool):
        return {"xsi_type": "xs:boolean", "text": "true" if value else "false"}
    if isinstance(value, (int, float)):
        return {"xsi_type": "xs:decimal", "text": str(value)}

    s = "" if value is None else str(value)
    if not s:
        return {"xsi_type": "xs:string", "text": ""}

    # ISO datetime ("2020-01-01T00:00:00") → xs:dateTime
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', s):
        return {"xsi_type": "xs:dateTime", "text": s}

    # Raw-ссылка по GUID (метаданные.значение) "GUID.GUID" → xr:DesignTimeRef (всегда ссылка, не строка)
    if re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F]{8}-[0-9a-fA-F-]+', s):
        return {"xsi_type": "xr:DesignTimeRef", "text": s}

    parts = s.split(".")
    if len(parts) >= 2:
        root = parts[0]
        canon_root = None
        if root in REF_ROOT_SYNONYMS:
            canon_root = REF_ROOT_SYNONYMS[root]
        elif root in REF_ROOT_SYNONYMS.values():
            canon_root = root

        if canon_root:
            type_name = parts[1]
            normalized = None
            if canon_root == "Enum":
                if len(parts) == 3 and parts[2] == 'EmptyRef':
                    # "Enum.X.EmptyRef" — пустая ссылка, НЕ значение перечисления (без .EnumValue.)
                    normalized = f"Enum.{type_name}.EmptyRef"
                elif len(parts) == 3:
                    normalized = f"Enum.{type_name}.EnumValue.{parts[2]}"
                elif len(parts) >= 4:
                    member = parts[2]
                    if member in ENUM_VALUE_SYNONYMS:
                        rest = ".".join(parts[3:])
                    else:
                        rest = ".".join(parts[2:])
                    normalized = f"Enum.{type_name}.EnumValue.{rest}"
            else:
                if len(parts) >= 3:
                    tail = ".".join(parts[1:])
                    normalized = f"{canon_root}.{tail}"

            if normalized:
                return {"xsi_type": "xr:DesignTimeRef", "text": normalized}

    return {"xsi_type": "xs:string", "text": s}


def emit_choice_presentation(lines, pres, indent):
    """Accepts None/empty → <Presentation/>; str → ru only; dict → multi-lang."""
    if pres is None or (isinstance(pres, str) and pres == ""):
        lines.append(f"{indent}<Presentation/>")
        return

    if isinstance(pres, str):
        pairs = [("ru", pres)]
    elif isinstance(pres, dict):
        pairs = [(str(k), str(v)) for k, v in pres.items()]
    else:
        pairs = [("ru", str(pres))]

    lines.append(f"{indent}<Presentation>")
    for lang, content in pairs:
        lines.append(f"{indent}\t<v8:item>")
        lines.append(f"{indent}\t\t<v8:lang>{lang}</v8:lang>")
        lines.append(f"{indent}\t\t<v8:content>{esc_xml(content)}</v8:content>")
        lines.append(f"{indent}\t</v8:item>")
    lines.append(f"{indent}</Presentation>")


def choice_value_tag(norm):
    # <Value> для choiceList/choiceParameters: пустой текст → самозакрывающийся тег (зеркало платформы).
    if not norm["text"]:
        return f'<Value xsi:type="{norm["xsi_type"]}"/>'
    return f'<Value xsi:type="{norm["xsi_type"]}">{esc_xml(norm["text"])}</Value>'


def emit_choice_list(lines, el, indent):
    # <ChoiceList> — у RadioButtonField и InputField. Элемент: { value, presentation?/title? }.
    choice_list = el.get('choiceList') or []
    if not choice_list:
        return
    lines.append(f'{indent}<ChoiceList>')
    item_indent = f'{indent}\t'
    for item in choice_list:
        if not isinstance(item, dict):
            continue
        val_raw = item.get('value', item.get('значение'))
        has_pres = any(k in item for k in ('presentation', 'представление', 'title'))
        pres_raw = item.get('presentation', item.get('представление', item.get('title')))

        # valueType: явный xsi:type значения (системное перечисление ent:*, иной не-примитив) —
        # переопределяет авто-детект (normalize_choice_value вывела бы xs:string).
        vt_raw = item.get('valueType')
        if vt_raw == 'nil':
            norm = {'xsi_type': None, 'text': None, 'nil': True}
        elif vt_raw:
            norm = {'xsi_type': str(vt_raw), 'text': '' if val_raw is None else str(val_raw)}
        else:
            norm = normalize_choice_value(val_raw)

        if not has_pres:
            if norm.get('xsi_type') == 'xr:DesignTimeRef':
                tail = norm['text'].split('.')[-1]
                pres_raw = title_from_name(tail)
            else:
                pres_raw = norm.get('text')

        lines.append(f'{item_indent}<xr:Item>')
        val_indent = f'{item_indent}\t'
        lines.append(f'{val_indent}<xr:Presentation/>')
        lines.append(f'{val_indent}<xr:CheckState>0</xr:CheckState>')
        lines.append(f'{val_indent}<xr:Value xsi:type="FormChoiceListDesTimeValue">')
        emit_choice_presentation(lines, pres_raw, f'{val_indent}\t')
        val_tag = '<Value xsi:nil="true"/>' if norm.get('nil') else choice_value_tag(norm)
        lines.append(f'{val_indent}\t{val_tag}')
        lines.append(f'{val_indent}</xr:Value>')
        lines.append(f'{item_indent}</xr:Item>')
    lines.append(f'{indent}</ChoiceList>')


def get_el_prop(obj, names):
    # Читает свойство из dict по списку синонимов (первый найденный, иначе None).
    if not isinstance(obj, dict):
        return None
    for n in names:
        if n in obj:
            return obj[n]
    return None


def to_scalar_literal(s):
    # Литерал shorthand → тип: true/false → bool, целое/дробное → число, иначе строка.
    t = str(s).strip()
    if t.lower() == 'true':
        return True
    if t.lower() == 'false':
        return False
    if re.fullmatch(r'-?\d+', t):
        return int(t)
    if re.fullmatch(r'-?\d+\.\d+', t):
        return float(t)
    return t


def from_choice_param_shorthand(s):
    # "name=value" либо "name=v1, v2, …" (запятые → массив). → {name, value}.
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    name = s[:eq].strip()
    rest = s[eq + 1:]
    if ',' in rest:
        return {'name': name, 'value': [to_scalar_literal(p) for p in rest.split(',')]}
    return {'name': name, 'value': to_scalar_literal(rest)}


def from_choice_param_link_shorthand(s):
    # "name=dataPath" либо "name=dataPath:DontChange". → {name, dataPath, valueChange?}.
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    o = {'name': s[:eq].strip()}
    rest = s[eq + 1:].strip()
    m = re.fullmatch(r'(.*):(Clear|DontChange|очистить|неизменять)', rest, re.IGNORECASE)
    if m:
        o['dataPath'] = m.group(1).strip()
        o['valueChange'] = m.group(2)
    else:
        o['dataPath'] = rest
    return o


def from_type_link_shorthand(s):
    # "dataPath" либо "dataPath#linkItem". → {dataPath, linkItem}.
    m = re.fullmatch(r'(.*)#(\d+)', str(s))
    if m:
        return {'dataPath': m.group(1).strip(), 'linkItem': int(m.group(2))}
    return {'dataPath': str(s).strip()}


def emit_choice_param_value(lines, value, indent):
    # Внутреннее значение параметра выбора (FormChoiceListDesTimeValue): <Presentation/> + <Value>.
    # Скаляр → один Value; массив → v8:FixedArray из вложенных FormChoiceListDesTimeValue.
    lines.append(f'{indent}<Presentation/>')
    if isinstance(value, (list, tuple)):
        lines.append(f'{indent}<Value xsi:type="v8:FixedArray">')
        for v in value:
            norm = normalize_choice_value(v)
            lines.append(f'{indent}\t<v8:Value xsi:type="FormChoiceListDesTimeValue">')
            lines.append(f'{indent}\t\t<Presentation/>')
            lines.append(f'{indent}\t\t{choice_value_tag(norm)}')
            lines.append(f'{indent}\t</v8:Value>')
        lines.append(f'{indent}</Value>')
    else:
        norm = normalize_choice_value(value)
        lines.append(f'{indent}{choice_value_tag(norm)}')


def emit_choice_parameters(lines, el, indent):
    # <ChoiceParameters> (параметры выбора поля ввода) — [{name, value}]. value через
    # normalize_choice_value; массив значений → FixedArray. Рус. синонимы имя/значение.
    cp = el.get('choiceParameters') or []
    if not cp:
        return
    lines.append(f'{indent}<ChoiceParameters>')
    for item in cp:
        if isinstance(item, str):
            item = from_choice_param_shorthand(item)
        name = get_el_prop(item, ('name', 'имя'))
        has_val = isinstance(item, dict) and ('value' in item or 'значение' in item)
        val = get_el_prop(item, ('value', 'значение'))
        name_s = '' if name is None else str(name)
        lines.append(f'{indent}\t<app:item name="{esc_xml(name_s)}">')
        # Параметр выбора без значения → <app:value xsi:nil="true"/> (платформа, 13 в корпусе);
        # со значением (в т.ч. пустой строкой) → FormChoiceListDesTimeValue.
        if not has_val:
            lines.append(f'{indent}\t\t<app:value xsi:nil="true"/>')
        else:
            lines.append(f'{indent}\t\t<app:value xsi:type="FormChoiceListDesTimeValue">')
            emit_choice_param_value(lines, val, f'{indent}\t\t\t')
            lines.append(f'{indent}\t\t</app:value>')
        lines.append(f'{indent}\t</app:item>')
    lines.append(f'{indent}</ChoiceParameters>')


def emit_choice_parameter_links(lines, el, indent):
    # <ChoiceParameterLinks> (связи параметров выбора) — [{name, dataPath, valueChange?}].
    # valueChange всегда эмитится, дефолт Clear; forgiving Clear/DontChange + рус. синонимы.
    cpl = el.get('choiceParameterLinks') or []
    if not cpl:
        return
    lines.append(f'{indent}<ChoiceParameterLinks>')
    for lk in cpl:
        if isinstance(lk, str):
            lk = from_choice_param_link_shorthand(lk)
        name = get_el_prop(lk, ('name', 'имя'))
        dp = get_el_prop(lk, ('dataPath', 'path', 'путь'))
        vc_raw = get_el_prop(lk, ('valueChange', 'режимИзменения'))
        vc = 'Clear'
        if vc_raw:
            s = str(vc_raw).lower()
            if s in ('clear', 'очистить', 'очистка'):
                vc = 'Clear'
            elif s in ('dontchange', 'неизменять', 'неменять', 'нет'):
                vc = 'DontChange'
            else:
                vc = str(vc_raw)
        name_s = '' if name is None else str(name)
        dp_s = '' if dp is None else str(dp)
        lines.append(f'{indent}\t<xr:Link>')
        lines.append(f'{indent}\t\t<xr:Name>{esc_xml(name_s)}</xr:Name>')
        lines.append(f'{indent}\t\t<xr:DataPath xsi:type="xs:string">{esc_xml(dp_s)}</xr:DataPath>')
        lines.append(f'{indent}\t\t<xr:ValueChange>{vc}</xr:ValueChange>')
        lines.append(f'{indent}\t</xr:Link>')
    lines.append(f'{indent}</ChoiceParameterLinks>')


def emit_type_link(lines, el, indent):
    # <TypeLink> (связь по типу) — {dataPath, linkItem}. linkItem дефолт 0.
    tl = el.get('typeLink')
    if not tl:
        return
    if isinstance(tl, str):
        tl = from_type_link_shorthand(tl)
    dp = get_el_prop(tl, ('dataPath', 'path', 'путь'))
    li = get_el_prop(tl, ('linkItem', 'элементСвязи'))
    if li is None:
        li = 0
    dp_s = '' if dp is None else str(dp)
    lines.append(f'{indent}<TypeLink>')
    lines.append(f'{indent}\t<xr:DataPath>{esc_xml(dp_s)}</xr:DataPath>')
    lines.append(f'{indent}\t<xr:LinkItem>{li}</xr:LinkItem>')
    lines.append(f'{indent}</TypeLink>')


def normalize_radio_button_type(raw):
    if not raw:
        return "Auto"
    s = str(raw).strip().lower()
    if s in ("auto", "авто"):
        return "Auto"
    if s in ("radiobutton", "radiobuttons", "переключатель", "радио"):
        return "RadioButtons"
    if s in ("tumbler", "тумблер"):
        return "Tumbler"
    return str(raw).strip()


def get_handler_name(element_name, event_name):
    suffix = EVENT_SUFFIX_MAP.get(event_name)
    if suffix:
        return f"{element_name}{suffix}"
    return f"{element_name}{event_name}"


def get_element_name(el, type_key):
    if el.get('name'):
        return str(el['name'])
    return str(el.get(type_key, ''))


# Собрать упорядоченный список событий элемента (имя, обработчик) из DSL.
# Основной формат: el['events'] = { Событие: ИмяОбработчика } (None/"" → авто-имя по конвенции).
# Legacy (принимается ради совместимости): el['on'] (массив) + el['handlers'] (переопределение имён).
def get_event_pairs(el, element_name):
    pairs = []
    events = el.get('events')
    if events:
        for ev_name, val in events.items():
            handler = '' if val is None else str(val)
            if not handler:
                handler = get_handler_name(element_name, ev_name)
            pairs.append((ev_name, handler))
    elif el.get('on'):
        handlers = el.get('handlers') or {}
        for evt in el['on']:
            evt_name = str(evt)
            if handlers.get(evt_name):
                handler = str(handlers[evt_name])
            else:
                handler = get_handler_name(element_name, evt_name)
            pairs.append((evt_name, handler))
    return pairs


# Проверить, подключено ли событие к элементу (в любом из форматов).
def test_element_event(el, event_name):
    events = el.get('events')
    if events and event_name in events:
        return True
    return event_name in (el.get('on') or [])


def emit_events(lines, el, element_name, indent, type_key):
    pairs = get_event_pairs(el, element_name)
    if not pairs:
        return

    # Validate event names
    if type_key and type_key in KNOWN_EVENTS:
        allowed = KNOWN_EVENTS[type_key]
        for ev_name, _ in pairs:
            if allowed and str(ev_name) not in allowed:
                print(f"[WARN] Unknown event '{ev_name}' for {type_key} '{element_name}'. Known: {', '.join(allowed)}")

    lines.append(f"{indent}<Events>")
    for ev_name, handler in pairs:
        lines.append(f'{indent}\t<Event name="{ev_name}">{handler}</Event>')
    lines.append(f"{indent}</Events>")


# Детектор «настоящей» inline-разметки (1С: <link>/<b>/<color>/… и </>). Должен быть
# идентичен form-decompile/form-compile.ps1, иначе гибрид-раундтрип поедет.
_FMT_MARKUP_RE = re.compile(r'</>|<\s*(?:link|b|i|u|s|color|colorStyle|bgColor|bgColorStyle|font|fontSize|fontStyle|img)(?:\s|>)', re.I)


def _has_real_markup(text):
    if text is None:
        return False
    vals = list(text.values()) if isinstance(text, dict) else [text]
    return any(_FMT_MARKUP_RE.search(str(v)) for v in vals)


def resolve_ml_formatted(val):
    # {text, formatted} = явный override; строка/мапа → авто-детект formatted
    if isinstance(val, dict) and 'text' in val:
        return val['text'], bool(val.get('formatted'))
    return val, _has_real_markup(val)


# ExtendedTooltip — это LabelDecoration: own-content (layout/оформление/флаги/hyperlink) ±текст.
# Признак структурированной формы: объект с любым НЕ-текстовым ключом ({text,formatted}/{ru,en} → текст).
COMPANION_STRUCT_KEYS = {
    'width', 'autoMaxWidth', 'maxWidth', 'height', 'autoMaxHeight', 'maxHeight', 'verticalAlign', 'titleHeight',
    'horizontalStretch', 'verticalStretch', 'horizontalAlign', 'groupHorizontalAlign', 'groupVerticalAlign',
    'visible', 'hidden', 'enabled', 'disabled', 'hyperlink', 'events', 'tooltip',
    'textColor', 'backColor', 'borderColor', 'font', 'border', 'цветтекста', 'цветфона', 'цветрамки', 'шрифт', 'рамка',
}


def emit_companion_title(lines, content, indent):
    text, fmt = resolve_ml_formatted(content)
    lines.append(f'{indent}<Title formatted="{"true" if fmt else "false"}">')
    emit_ml_items(lines, f'{indent}\t', text)
    lines.append(f'{indent}</Title>')


def emit_companion(lines, tag, name, indent, content=None):
    cid = new_id()
    has_content = content is not None and not (isinstance(content, str) and content == '')
    if not has_content:
        lines.append(f'{indent}<{tag} name="{name}" id="{cid}"/>')
        return
    inner = f'{indent}\t'
    # DI-Attr от собственного объекта компаньона (не от владельца) — зеркало ps1
    lines.append(f'{indent}<{tag} name="{name}" id="{cid}"{di_attr(content if isinstance(content, dict) else None)}>')
    if isinstance(content, dict) and any(k in content for k in COMPANION_STRUCT_KEYS):
        # own-content ПЕРЕД Title (в корпусе layout-first 582 vs 10).
        emit_common_flags(lines, content, inner)
        if content.get('hyperlink') is True:
            lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
        emit_layout(lines, content, inner)
        emit_appearance(lines, content, inner, 'decoration')
        if 'text' in content:
            emit_companion_title(lines, content, inner)
        # ToolTip компаньона (подсказка самой расширенной подсказки) — после Title (порядок схемы LabelDecoration)
        if content.get('tooltip'):
            emit_mltext(lines, inner, 'ToolTip', content['tooltip'])
        # События компаньона (ExtendedTooltip = LabelDecoration: напр. URLProcessing у hyperlink-подсказки)
        emit_events(lines, content, name, inner, 'label')
    else:
        emit_companion_title(lines, content, inner)
    lines.append(f'{indent}</{tag}>')


def emit_companion_panel(lines, tag, name, indent, panel):
    # Companion-командная-панель (ContextMenu/AutoCommandBar) с контентом: { autofill?, horizontalAlign?, children?[] }
    # или массив = shorthand для { children }. Пусто/нет → self-closing.
    cid = new_id()
    autofill = None
    halign = None
    children = None
    if isinstance(panel, list):
        children = panel
    elif panel is not None:
        if panel.get('autofill') is not None:
            autofill = bool(panel.get('autofill'))
        if panel.get('horizontalAlign'):
            halign = str(panel.get('horizontalAlign'))
        children = panel.get('children')
    has_children = bool(children) and len(children) > 0
    # Платформа пишет <Autofill> только при false; true = дефолт (тег опускается).
    emit_af_false = (autofill is False)
    if not emit_af_false and not has_children and not halign:
        lines.append(f'{indent}<{tag} name="{name}" id="{cid}"/>')
        return
    lines.append(f'{indent}<{tag} name="{name}" id="{cid}"{di_attr(panel if isinstance(panel, dict) else None)}>')
    if halign:
        lines.append(f'{indent}\t<HorizontalAlign>{halign}</HorizontalAlign>')
    if emit_af_false:
        lines.append(f'{indent}\t<Autofill>false</Autofill>')
    if has_children:
        lines.append(f'{indent}\t<ChildItems>')
        for c in children:
            emit_element(lines, c, f'{indent}\t\t', in_cmd_bar=True)
        lines.append(f'{indent}\t</ChildItems>')
    lines.append(f'{indent}</{tag}>')


# Дополнения командной панели таблицы: тип DSL → XML-тег + AdditionSource.Type + суффикс имени.
ADDITION_TYPE_MAP = {
    'searchString':  {'tag': 'SearchStringAddition',  'type': 'SearchStringRepresentation', 'suffix': 'СтрокаПоиска'},
    'viewStatus':    {'tag': 'ViewStatusAddition',    'type': 'ViewStatusRepresentation',   'suffix': 'СостояниеПросмотра'},
    'searchControl': {'tag': 'SearchControlAddition', 'type': 'SearchControl',               'suffix': 'УправлениеПоиском'},
}
ADDITION_KEY_SYNONYMS = {
    'searchString':  ['SearchStringAddition', 'SearchStringRepresentation', 'строкаПоиска', 'отображениеСтрокиПоиска'],
    'viewStatus':    ['ViewStatusAddition', 'ViewStatusRepresentation', 'состояниеПросмотра'],
    'searchControl': ['SearchControlAddition', 'SearchControl', 'управлениеПоиском'],
}
# Имя текущей таблицы — дефолт source для кастомных дополнений в commandBar.
_current_table_name = {'name': None}


def get_hlocation(el):
    # HorizontalLocation: auto (дефолт, опускаем) / left / right; forgiving + рус.
    if not isinstance(el, dict):
        return None
    v = el.get('horizontalLocation')
    if not v:
        return None
    s = str(v).lower()
    if s in ('auto', 'авто'):
        return None
    if s in ('left', 'слева', 'лево'):
        return 'Left'
    if s in ('right', 'справа', 'право'):
        return 'Right'
    if s in ('center', 'центр', 'по центру'):
        return 'Center'
    return str(v)


def emit_addition_body(lines, props, source, src_type, add_name, indent):
    # Тело дополнения: AdditionSource + свойства (как у поля) + companions. props может быть None.
    inner = f'{indent}\t'
    lines.append(f'{inner}<AdditionSource>')
    lines.append(f'{inner}\t<Item>{source}</Item>')
    lines.append(f'{inner}\t<Type>{src_type}</Type>')
    lines.append(f'{inner}</AdditionSource>')
    if props:
        if props.get('title'):
            emit_mltext(lines, inner, 'Title', props['title'])
        emit_common_flags(lines, props, inner)
        if props.get('tooltip'):
            emit_mltext(lines, inner, 'ToolTip', props['tooltip'])
        if props.get('tooltipRepresentation'):
            lines.append(f'{inner}<ToolTipRepresentation>{props["tooltipRepresentation"]}</ToolTipRepresentation>')
        hl = get_hlocation(props)
        if hl:
            lines.append(f'{inner}<HorizontalLocation>{hl}</HorizontalLocation>')
        emit_layout(lines, props, inner)
        emit_appearance(lines, props, inner, 'field')
    emit_companion(lines, 'ContextMenu', f'{add_name}КонтекстноеМеню', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{add_name}РасширеннаяПодсказка', inner)


def emit_addition(lines, el, name, eid, type_key, indent):
    # Кастомное дополнение (тип-элемент в commandBar): source дефолтит в текущую таблицу.
    m = ADDITION_TYPE_MAP[type_key]
    source = el.get('source') or _current_table_name['name'] or ''
    lines.append(f'{indent}<{m["tag"]} name="{name}" id="{eid}"{di_attr(el)}>')
    emit_addition_body(lines, el, source, m['type'], name, indent)
    lines.append(f'{indent}</{m["tag"]}>')


def emit_table_addition(lines, type_key, table_name, indent, override=None):
    # Стандартное табличное дополнение (авто-генерация). override — объект отклонений из карты additions.
    m = ADDITION_TYPE_MAP[type_key]
    add_name = f'{table_name}{m["suffix"]}'
    aid = new_id()
    lines.append(f'{indent}<{m["tag"]} name="{add_name}" id="{aid}">')
    emit_addition_body(lines, override, table_name, m['type'], add_name, indent)
    lines.append(f'{indent}</{m["tag"]}>')


def get_addition_override(additions, type_key):
    # Прочитать override-объект для типа из per-table карты additions (с синонимами).
    if not isinstance(additions, dict):
        return None
    for k in [type_key] + ADDITION_KEY_SYNONYMS[type_key]:
        if k in additions:
            return additions[k]
    return None


# Role-adjustable boolean (xr:Common + 0..N xr:Value name="Role.X").
# Единый механизм платформы: UserVisible (элементы), View/Edit (атрибуты), Use (команды/кнопки).
# Значение DSL: скаляр bool → только <xr:Common>; объект { common, roles:{ Имя: bool } } → +пер-ролевые исключения.
# Имя роли принимаем с/без префикса "Role." (forgiving); на выход всегда с префиксом.
def emit_xr_flag(lines, tag, val, indent):
    if val is None:
        return
    if isinstance(val, bool):
        lines.append(f"{indent}<{tag}>")
        lines.append(f"{indent}\t<xr:Common>{'true' if val else 'false'}</xr:Common>")
        lines.append(f"{indent}</{tag}>")
        return
    # объектная форма { common, roles }
    common = bool(val.get('common')) if val.get('common') is not None else False
    lines.append(f"{indent}<{tag}>")
    lines.append(f"{indent}\t<xr:Common>{'true' if common else 'false'}</xr:Common>")
    roles = val.get('roles')
    if roles:
        for rname, rval in roles.items():
            # Forgiving: имя без префикса, с "Role." или кириллическим "Роль." → нормализуем в "Role.".
            # Роль по GUID (заимствованная/расширение — name="<guid>" без префикса) эмитим как есть.
            rn = re.sub(r'^(Role|Роль)\.', '', rname)
            if not re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', rn):
                rn = "Role." + rn
            lines.append(f"{indent}\t<xr:Value name=\"{rn}\">{'true' if rval else 'false'}</xr:Value>")
    lines.append(f"{indent}</{tag}>")


def emit_common_flags(lines, el, indent):
    if el.get('visible') is False or el.get('hidden') is True:
        lines.append(f"{indent}<Visible>false</Visible>")
    if el.get('userVisible') is not None:
        emit_xr_flag(lines, 'UserVisible', el.get('userVisible'), indent)
    if el.get('enabled') is False or el.get('disabled') is True:
        lines.append(f"{indent}<Enabled>false</Enabled>")
    if el.get('readOnly') is True:
        lines.append(f"{indent}<ReadOnly>true</ReadOnly>")


# Общие свойства элемента (любой тип, включая Button/cmdBar): default/skip/drag.
def emit_common_element_props(lines, el, indent):
    if el.get('defaultItem') is True:
        lines.append(f"{indent}<DefaultItem>true</DefaultItem>")
    if 'skipOnInput' in el and el['skipOnInput'] is not None:
        siv = 'true' if el['skipOnInput'] is True else 'false'
        lines.append(f"{indent}<SkipOnInput>{siv}</SkipOnInput>")
    # EnableStartDrag — фактическое значение (платформа эмитит и явный false, напр. SpreadSheet)
    if el.get('enableStartDrag') is not None:
        lines.append(f'{indent}<EnableStartDrag>{"true" if el["enableStartDrag"] else "false"}</EnableStartDrag>')
    if el.get('fileDragMode'):
        lines.append(f"{indent}<FileDragMode>{el['fileDragMode']}</FileDragMode>")
    # Cell-свойства поля в таблице (общие для Input/Label/Picture/CheckBox): захват «как есть»
    for key, tag in (('showInHeader', 'ShowInHeader'), ('showInFooter', 'ShowInFooter'), ('autoCellHeight', 'AutoCellHeight')):
        if el.get(key) is not None:
            lines.append(f'{indent}<{tag}>{"true" if el[key] else "false"}</{tag}>')
    # Динамический заголовок колонки-группы из данных (HeaderDataPath) — перед HeaderHorizontalAlign (порядок XSD)
    if el.get('headerDataPath'):
        lines.append(f"{indent}<HeaderDataPath>{esc_xml(str(el['headerDataPath']))}</HeaderDataPath>")
    if el.get('footerHorizontalAlign'):
        lines.append(f"{indent}<FooterHorizontalAlign>{el['footerHorizontalAlign']}</FooterHorizontalAlign>")
    if el.get('headerHorizontalAlign'):
        lines.append(f"{indent}<HeaderHorizontalAlign>{el['headerHorizontalAlign']}</HeaderHorizontalAlign>")
    # Формат заголовка колонки-группы (ML-текст) — после HeaderHorizontalAlign (порядок XSD)
    if el.get('headerFormat'):
        emit_mltext(lines, indent, 'HeaderFormat', el['headerFormat'])


def emit_picture_ref(lines, val, pic_tag, indent):
    """Картинка-ссылка с прозрачностью (HeaderPicture/FooterPicture/ValuesPicture/Page Picture).
    Платформа ВСЕГДА эмитит <xr:LoadTransparent> → пишем всегда (false по умолчанию).
    Значение: скаляр (Ref) ИЛИ объект {src, loadTransparent, transparentPixel}.
    src с префиксом "abs:" → встроенная картинка <xr:Abs>; иначе <xr:Ref>."""
    if not val:
        return
    tpx = None
    if isinstance(val, str):
        src, lt = val, False
    else:
        src = val.get('src')
        lt = val.get('loadTransparent') is True
        tpx = val.get('transparentPixel')
    if not src:
        return
    src_str = str(src)
    lines.append(f"{indent}<{pic_tag}>")
    if src_str.startswith('abs:'):
        lines.append(f"{indent}\t<xr:Abs>{esc_xml(src_str[4:])}</xr:Abs>")
    else:
        lines.append(f"{indent}\t<xr:Ref>{esc_xml(src_str)}</xr:Ref>")
    lines.append(f'{indent}\t<xr:LoadTransparent>{"true" if lt else "false"}</xr:LoadTransparent>')
    if tpx:
        lines.append(f'{indent}\t<xr:TransparentPixel x="{tpx.get("x")}" y="{tpx.get("y")}"/>')
    lines.append(f"{indent}</{pic_tag}>")


def emit_column_pics(lines, el, indent):
    """Картинки заголовка/подвала колонки поля — по схеме сразу после <EditMode>,
    перед тип-специфичными элементами и layout (порядок XDTO строгий именно здесь)."""
    emit_picture_ref(lines, el.get('headerPicture'), 'HeaderPicture', indent)
    emit_picture_ref(lines, el.get('footerPicture'), 'FooterPicture', indent)


def emit_command_picture(lines, pic, elem_lt, indent):
    """<Picture> кнопки/попапа/команды. Дефолт LoadTransparent=true, отклонение false
    (обратная конвенция относительно header/values-картинок). Прощающий ввод:
    принимает скаляр (Ref) ИЛИ объект {src, loadTransparent} — на случай если модель
    опишет картинку объектно по аналогии с headerPicture. elem_lt — legacy
    элемент-уровневый ключ loadTransparent (если в объекте флаг не задан)."""
    if not pic:
        return
    lt = None
    tpx = None
    if isinstance(pic, str):
        src = pic
    else:
        src = pic.get('src')
        if pic.get('loadTransparent') is not None:
            lt = bool(pic.get('loadTransparent'))
        tpx = pic.get('transparentPixel')
    if not src:
        return
    if lt is None and elem_lt is not None:
        lt = bool(elem_lt)
    src_str = str(src)
    lines.append(f'{indent}<Picture>')
    if src_str.startswith('abs:'):
        lines.append(f'{indent}\t<xr:Abs>{esc_xml(src_str[4:])}</xr:Abs>')
    else:
        lines.append(f'{indent}\t<xr:Ref>{esc_xml(src_str)}</xr:Ref>')
    lines.append(f'{indent}\t<xr:LoadTransparent>{"false" if lt is False else "true"}</xr:LoadTransparent>')
    if tpx:
        lines.append(f'{indent}\t<xr:TransparentPixel x="{tpx.get("x")}" y="{tpx.get("y")}"/>')
    lines.append(f'{indent}</Picture>')


# --- Оформление элемента: цвета / шрифты / граница (зеркало form-compile.ps1 Emit-Appearance) ---
# Прямые свойства элемента (<TextColor>/<Font>/<Border> + header/footer у полей). Ключи англ.
# camelCase 1:1 с тегами + приём рус. синонимов. Цвет — verbatim-строка (style:/web:/win:/#RRGGBB);
# шрифт — строка-ref/объект-атрибуты; граница — строка-ref/
# объект {width,style}. Порядок тегов — XSD (профиль по базовому типу).
APPEARANCE_SPEC = {
    'titleTextColor':  ('TitleTextColor', 'color'),
    'titleBackColor':  ('TitleBackColor', 'color'),
    'titleFont':       ('TitleFont', 'font'),
    'footerTextColor': ('FooterTextColor', 'color'),
    'footerBackColor': ('FooterBackColor', 'color'),
    'footerFont':      ('FooterFont', 'font'),
    'textColor':       ('TextColor', 'color'),
    'backColor':       ('BackColor', 'color'),
    'borderColor':     ('BorderColor', 'color'),
    'border':          ('Border', 'border'),
    'font':            ('Font', 'font'),
}
APPEARANCE_SYNONYMS = {
    'цветтекста': 'textColor', 'цветфона': 'backColor', 'цветрамки': 'borderColor',
    'цветтекстазаголовка': 'titleTextColor', 'цветфоназаголовка': 'titleBackColor', 'шрифтзаголовка': 'titleFont',
    'цветтекстаподвала': 'footerTextColor', 'цветфонаподвала': 'footerBackColor', 'шрифтподвала': 'footerFont',
    'шрифт': 'font', 'рамка': 'border',
}
# Синонимы ключей-свойств: русские имена свойств 1С (как в Конфигураторе) → канон. англ. ключ.
# Ключи нормализованы (lowercase, без пробелов); сопоставление в emit_element тоже. Англ. ключ
# работает всегда (доп. слой прощающего ввода). Видимость/Доступность НЕ включаем (hidden/disabled инвертирован).
PROP_SYNONYMS = {
    'пометка': 'checked',
    'кнопкавыбора': 'choiceButton', 'кнопкаочистки': 'clearButton', 'кнопкарегулирования': 'spinButton',
    'кнопкавыпадающегосписка': 'dropListButton', 'кнопкасписковоговыбора': 'choiceListButton',
    'кнопкаоткрытия': 'openButton', 'кнопкапоумолчанию': 'defaultButton',
    'быстрыйвыбор': 'quickChoice', 'формавыбора': 'choiceForm', 'историявыборапривводе': 'choiceHistoryOnInput',
    'выборгруппиэлементов': 'choiceFoldersAndItems', 'фиксациявтаблице': 'fixingInTable',
    'путькданнымподвала': 'footerDataPath', 'автоотметканезаполненного': 'markIncomplete',
    'многострочныйрежим': 'multiLine', 'режимпароля': 'passwordMode', 'переноспословам': 'wrap',
    'расположениезаголовка': 'titleLocation', 'пропускатьпривводе': 'skipOnInput',
    'заголовок': 'title', 'ширина': 'width', 'высота': 'height', 'подсказкаввода': 'inputHint',
}
APP_ORDER_FIELD =['titleTextColor', 'titleBackColor', 'titleFont', 'footerTextColor', 'footerBackColor', 'footerFont', 'textColor', 'backColor', 'borderColor', 'border', 'font']
APP_ORDER_DECORATION = ['textColor', 'font', 'backColor', 'borderColor', 'border']
APP_ORDER_BUTTON = ['textColor', 'backColor', 'borderColor', 'font']


def get_appearance_value(el, canonical):
    if not isinstance(el, dict):
        return None
    if canonical in el:
        return el[canonical]
    lowmap = {k.lower(): k for k in el.keys()}
    if canonical.lower() in lowmap:
        return el[lowmap[canonical.lower()]]
    for syn, canon in APPEARANCE_SYNONYMS.items():
        if canon == canonical and syn in lowmap:
            return el[lowmap[syn]]
    return None


def emit_font_tag(lines, tag, val, indent):
    if isinstance(val, str):
        lines.append(f'{indent}<{tag} ref="{esc_xml(val)}" kind="StyleItem"/>')
        return
    attrs = []
    for a in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
        if a in val and val[a] is not None:
            v = val[a]
            if isinstance(v, bool):
                v = 'true' if v else 'false'
            attrs.append(f'{a}="{esc_xml(str(v))}"')
    lines.append(f'{indent}<{tag} {" ".join(attrs)}/>')


def emit_border_tag(lines, val, indent):
    if isinstance(val, str):
        lines.append(f'{indent}<Border ref="{esc_xml(val)}"/>')
        return
    if val.get('ref'):
        lines.append(f'{indent}<Border ref="{esc_xml(str(val["ref"]))}"/>')
        return
    width = val['width'] if val.get('width') is not None else 1
    style = str(val['style']) if 'style' in val else None
    lines.append(f'{indent}<Border width="{width}">')
    if style:
        lines.append(f'{indent}\t<v8ui:style xsi:type="v8ui:ControlBorderType">{esc_xml(style)}</v8ui:style>')
    lines.append(f'{indent}</Border>')


# ─────────────────────────────────────────────────────────────────────────────
# Planner design-time <Settings xsi:type="pl:Planner"> — зеркало Emit-PlannerSettings (ps1).
PLANNER_NS = 'http://v8.1c.ru/8.3/data/planner'
CHART_NS = 'http://v8.1c.ru/8.2/data/chart'


def _pl_get(o, k, default=None):
    if isinstance(o, dict) and o.get(k) is not None:
        return o[k]
    return default


def _pl_bool(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if str(v) == 'True':
        return 'true'
    if str(v) == 'False':
        return 'false'
    return str(v)


def emit_planner_color(lines, tag, o, key, ind):
    lines.append(f'{ind}<pl:{tag}>{esc_xml(str(_pl_get(o, key, "auto")))}</pl:{tag}>')


def emit_planner_text(lines, tag, v, ind):
    if v is None or str(v) == '':
        lines.append(f'{ind}<pl:{tag}/>')
    else:
        lines.append(f'{ind}<pl:{tag}>{esc_xml(str(v))}</pl:{tag}>')


_PLANNER_REF_RE = re.compile(
    r'^(Enum|Catalog|Document|ChartOfAccounts|ChartOfCalculationTypes|ChartOfCharacteristicTypes|ExchangePlan|BusinessProcess|Task)\.'
    r'|\.EnumValue\.|EmptyRef$'
    r'|^(Перечисление|Справочник|Документ|ПланСчетов|ПланВидовХарактеристик|ПланВидовРасчета|ПланОбмена|БизнесПроцесс|Задача)\.')


def test_planner_ref(v):
    return bool(_PLANNER_REF_RE.search(str(v)))


def emit_planner_value(lines, v, ind):
    if v is None or str(v) == '':
        lines.append(f'{ind}<pl:value xsi:nil="true"/>')
        return
    t = 'xr:DesignTimeRef' if test_planner_ref(v) else 'xs:string'
    lines.append(f'{ind}<pl:value xsi:type="{t}">{esc_xml(str(v))}</pl:value>')


def emit_planner_font(lines, o, ind):
    f = _pl_get(o, 'font')
    if f is None:
        lines.append(f'{ind}<pl:font kind="AutoFont"/>')
        return
    emit_font_tag(lines, 'pl:font', f, ind)


def emit_planner_border(lines, o, ind, key='border'):
    b = _pl_get(o, key)
    bw = _pl_get(b, 'width', 1) if b else 1
    bs = _pl_get(b, 'style', 'Single') if b else 'Single'
    lines.append(f'{ind}<pl:border width="{bw}">')
    lines.append(f'{ind}\t<v8ui:style xsi:type="v8ui:ControlBorderType">{esc_xml(str(bs))}</v8ui:style>')
    lines.append(f'{ind}</pl:border>')


def emit_planner_level(lines, lv, cns, ind):
    li = f'{ind}\t'
    lines.append(f'{ind}<level xmlns="{cns}">')
    lines.append(f'{li}<measure>{esc_xml(str(_pl_get(lv, "measure", "Hour")))}</measure>')
    lines.append(f'{li}<interval>{_pl_get(lv, "interval", 1)}</interval>')
    lines.append(f'{li}<show>{_pl_bool(_pl_get(lv, "show", True))}</show>')
    line = _pl_get(lv, 'line')
    lw = _pl_get(line, 'width', 1) if line else 1
    lg = _pl_get(line, 'gap', False) if line else False
    lst = _pl_get(line, 'style', 'Solid') if line else 'Solid'
    lines.append(f'{li}<line width="{lw}" gap="{_pl_bool(lg)}">')
    lines.append(f'{li}\t<v8ui:style xsi:type="v8ui:ChartLineType">{esc_xml(str(lst))}</v8ui:style>')
    lines.append(f'{li}</line>')
    lines.append(f'{li}<scaleColor>{esc_xml(str(_pl_get(lv, "scaleColor", "auto")))}</scaleColor>')
    lines.append(f'{li}<dayFormatRule>{esc_xml(str(_pl_get(lv, "dayFormatRule", "MonthDayWeekDay")))}</dayFormatRule>')
    fmt = _pl_get(lv, 'format')
    if fmt is None:
        fmt = {'#': 'DF="HH:mm"', 'ru': 'DF="HH:mm"'}
    lines.append(f'{li}<format>')
    emit_ml_items(lines, f'{li}\t', fmt)
    lines.append(f'{li}</format>')
    labels = _pl_get(lv, 'labels')
    ticks = _pl_get(labels, 'ticks', 0) if labels else 0
    lines.append(f'{li}<labels>')
    lines.append(f'{li}\t<ticks>{ticks}</ticks>')
    lines.append(f'{li}</labels>')
    lines.append(f'{li}<backColor>{esc_xml(str(_pl_get(lv, "backColor", "auto")))}</backColor>')
    lines.append(f'{li}<textColor>{esc_xml(str(_pl_get(lv, "textColor", "auto")))}</textColor>')
    lines.append(f'{li}<showPereodicalLabels>{_pl_bool(_pl_get(lv, "showPereodicalLabels", True))}</showPereodicalLabels>')
    lines.append(f'{ind}</level>')


def emit_planner_timescale(lines, ts, ind):
    cns = CHART_NS
    ci = f'{ind}\t'
    lines.append(f'{ind}<pl:timeScale>')
    placement = _pl_get(ts, 'placement', 'Left') if ts else 'Left'
    lines.append(f'{ci}<placement xmlns="{cns}">{esc_xml(str(placement))}</placement>')
    levels = _pl_get(ts, 'levels', []) if ts else []
    if not levels:
        levels = [None]
    for lv in levels:
        emit_planner_level(lines, lv, cns, ci)
    transp = _pl_get(ts, 'transparent', False) if ts else False
    lines.append(f'{ci}<transparent xmlns="{cns}">{_pl_bool(transp)}</transparent>')
    tbc = _pl_get(ts, 'backColor', 'auto') if ts else 'auto'
    ttc = _pl_get(ts, 'textColor', 'auto') if ts else 'auto'
    tcl = _pl_get(ts, 'currentLevel', 0) if ts else 0
    lines.append(f'{ci}<backColor xmlns="{cns}">{esc_xml(str(tbc))}</backColor>')
    lines.append(f'{ci}<textColor xmlns="{cns}">{esc_xml(str(ttc))}</textColor>')
    lines.append(f'{ci}<currentLevel xmlns="{cns}">{tcl}</currentLevel>')
    lines.append(f'{ind}</pl:timeScale>')


def emit_planner_item(lines, it, ind):
    lines.append(f'{ind}<pl:item>')
    ii = f'{ind}\t'
    emit_planner_value(lines, _pl_get(it, 'value'), ii)
    emit_planner_text(lines, 'text', _pl_get(it, 'text', ''), ii)
    emit_planner_text(lines, 'tooltip', _pl_get(it, 'tooltip', ''), ii)
    lines.append(f'{ii}<pl:begin>{_pl_get(it, "begin", "0001-01-01T00:00:00")}</pl:begin>')
    lines.append(f'{ii}<pl:end>{_pl_get(it, "end", "0001-01-01T00:00:00")}</pl:end>')
    emit_planner_color(lines, 'borderColor', it, 'borderColor', ii)
    emit_planner_color(lines, 'backColor', it, 'backColor', ii)
    emit_planner_color(lines, 'textColor', it, 'textColor', ii)
    emit_planner_font(lines, it, ii)
    lines.append(f'{ii}<pl:dimensionValues/>')
    lines.append(f'{ii}<pl:replacementDate>{_pl_get(it, "replacementDate", "0001-01-01T00:00:00")}</pl:replacementDate>')
    lines.append(f'{ii}<pl:deleted>{_pl_bool(_pl_get(it, "deleted", False))}</pl:deleted>')
    iid = _pl_get(it, 'id')
    if iid is None:
        import uuid
        iid = str(uuid.uuid4())
    lines.append(f'{ii}<pl:id>{iid}</pl:id>')
    lines.append(f'{ii}<pl:textFormatted>{_pl_bool(_pl_get(it, "textFormatted", False))}</pl:textFormatted>')
    emit_planner_border(lines, it, ii, 'border')
    lines.append(f'{ii}<pl:editMode>{esc_xml(str(_pl_get(it, "editMode", "EnableEdit")))}</pl:editMode>')
    lines.append(f'{ind}</pl:item>')


def emit_planner_dim_element(lines, el, ind):
    lines.append(f'{ind}<pl:item>')
    ii = f'{ind}\t'
    emit_planner_value(lines, _pl_get(el, 'value'), ii)
    emit_planner_text(lines, 'text', _pl_get(el, 'text', ''), ii)
    emit_planner_color(lines, 'borderColor', el, 'borderColor', ii)
    emit_planner_color(lines, 'backColor', el, 'backColor', ii)
    emit_planner_color(lines, 'textColor', el, 'textColor', ii)
    emit_planner_font(lines, el, ii)
    for sub in _pl_get(el, 'elements', []):
        emit_planner_dim_element(lines, sub, ii)
    lines.append(f'{ii}<pl:showOnlySubordinatesAreas>{_pl_bool(_pl_get(el, "showOnlySubordinatesAreas", True))}</pl:showOnlySubordinatesAreas>')
    lines.append(f'{ii}<pl:textFormatted>{_pl_bool(_pl_get(el, "textFormatted", False))}</pl:textFormatted>')
    lines.append(f'{ind}</pl:item>')


def emit_planner_dimension(lines, d, ind):
    lines.append(f'{ind}<pl:dimension>')
    di = f'{ind}\t'
    emit_planner_value(lines, _pl_get(d, 'value'), di)
    emit_planner_text(lines, 'text', _pl_get(d, 'text', ''), di)
    emit_planner_color(lines, 'borderColor', d, 'borderColor', di)
    emit_planner_color(lines, 'backColor', d, 'backColor', di)
    emit_planner_color(lines, 'textColor', d, 'textColor', di)
    emit_planner_font(lines, d, di)
    for el in _pl_get(d, 'elements', []):
        emit_planner_dim_element(lines, el, di)
    lines.append(f'{di}<pl:textFormatted>{_pl_bool(_pl_get(d, "textFormatted", False))}</pl:textFormatted>')
    lines.append(f'{ind}</pl:dimension>')


def emit_planner_settings(lines, pl, ind):
    lines.append(f'{ind}<Settings xmlns:pl="{PLANNER_NS}" xsi:type="pl:Planner">')
    si = f'{ind}\t'
    for it in _pl_get(pl, 'items', []):
        emit_planner_item(lines, it, si)
    for d in _pl_get(pl, 'dimensions', []):
        emit_planner_dimension(lines, d, si)
    emit_planner_color(lines, 'borderColor', pl, 'borderColor', si)
    emit_planner_color(lines, 'backColor', pl, 'backColor', si)
    emit_planner_color(lines, 'textColor', pl, 'textColor', si)
    emit_planner_color(lines, 'lineColor', pl, 'lineColor', si)
    emit_planner_font(lines, pl, si)
    lines.append(f'{si}<pl:beginOfRepresentationPeriod>{_pl_get(pl, "beginOfRepresentationPeriod", "0001-01-01T00:00:00")}</pl:beginOfRepresentationPeriod>')
    lines.append(f'{si}<pl:endOfRepresentationPeriod>{_pl_get(pl, "endOfRepresentationPeriod", "0001-01-01T00:00:00")}</pl:endOfRepresentationPeriod>')
    lines.append(f'{si}<pl:alignElementsOfTimeScale>{_pl_bool(_pl_get(pl, "alignElementsOfTimeScale", True))}</pl:alignElementsOfTimeScale>')
    lines.append(f'{si}<pl:displayTimeScaleWrapHeaders>{_pl_bool(_pl_get(pl, "displayTimeScaleWrapHeaders", True))}</pl:displayTimeScaleWrapHeaders>')
    lines.append(f'{si}<pl:displayWrapHeaders>{_pl_bool(_pl_get(pl, "displayWrapHeaders", True))}</pl:displayWrapHeaders>')
    wfmt = _pl_get(pl, 'timeScaleWrapHeadersFormat')
    if wfmt is None:
        wfmt = {'#': 'DLF="DD"', 'ru': 'DLF="DD"'}
    emit_mltext(lines, si, 'pl:timeScaleWrapHeadersFormat', wfmt)
    lines.append(f'{si}<pl:periodicVariantUnit>{esc_xml(str(_pl_get(pl, "periodicVariantUnit", "Day")))}</pl:periodicVariantUnit>')
    lines.append(f'{si}<pl:periodicVariantRepetition>{_pl_get(pl, "periodicVariantRepetition", 1)}</pl:periodicVariantRepetition>')
    lines.append(f'{si}<pl:timeScaleWrapBeginIndent>{_pl_get(pl, "timeScaleWrapBeginIndent", 0)}</pl:timeScaleWrapBeginIndent>')
    lines.append(f'{si}<pl:timeScaleWrapEndIndent>{_pl_get(pl, "timeScaleWrapEndIndent", 0)}</pl:timeScaleWrapEndIndent>')
    emit_planner_timescale(lines, _pl_get(pl, 'timeScale'), si)
    period = _pl_get(pl, 'period')
    if period:
        lines.append(f'{si}<pl:period>')
        lines.append(f'{si}\t<pl:begin>{_pl_get(period, "begin", "0001-01-01T00:00:00")}</pl:begin>')
        lines.append(f'{si}\t<pl:end>{_pl_get(period, "end", "0001-01-01T00:00:00")}</pl:end>')
        lines.append(f'{si}</pl:period>')
    lines.append(f'{si}<pl:displayCurrentDate>{_pl_bool(_pl_get(pl, "displayCurrentDate", True))}</pl:displayCurrentDate>')
    lines.append(f'{si}<pl:itemsTimeRepresentation>{esc_xml(str(_pl_get(pl, "itemsTimeRepresentation", "BeginTime")))}</pl:itemsTimeRepresentation>')
    lines.append(f'{si}<pl:itemsBehaviorWhenSpaceInsufficient>{esc_xml(str(_pl_get(pl, "itemsBehaviorWhenSpaceInsufficient", "CollapseItems")))}</pl:itemsBehaviorWhenSpaceInsufficient>')
    lines.append(f'{si}<pl:autoMinColumnWidth>{_pl_bool(_pl_get(pl, "autoMinColumnWidth", True))}</pl:autoMinColumnWidth>')
    lines.append(f'{si}<pl:autoMinRowHeight>{_pl_bool(_pl_get(pl, "autoMinRowHeight", True))}</pl:autoMinRowHeight>')
    lines.append(f'{si}<pl:minColumnWidth>{_pl_get(pl, "minColumnWidth", 0)}</pl:minColumnWidth>')
    lines.append(f'{si}<pl:minRowHeight>{_pl_get(pl, "minRowHeight", 0)}</pl:minRowHeight>')
    lines.append(f'{si}<pl:fixDimensionsHeader>{esc_xml(str(_pl_get(pl, "fixDimensionsHeader", "auto")))}</pl:fixDimensionsHeader>')
    lines.append(f'{si}<pl:fixTimeScaleHeader>{esc_xml(str(_pl_get(pl, "fixTimeScaleHeader", "auto")))}</pl:fixTimeScaleHeader>')
    emit_planner_border(lines, pl, si, 'border')
    lines.append(f'{si}<pl:newItemsTextType>{esc_xml(str(_pl_get(pl, "newItemsTextType", "String")))}</pl:newItemsTextType>')
    lines.append(f'{ind}</Settings>')


# ─────────────────────────────────────────────────────────────────────────────
# Chart design-time <Settings xsi:type="d4p1:Chart"> — генерик-эмиттер (зеркало
# Build-ChartNode декомпилятора + Emit-ChartNode ps1).
CHART_ML_FIELDS = {'title', 'lbFormat', 'lbpFormat', 'vsFormat', 'dtFormat', 'dataSourceDescription', 'labelFormat', 'text'}
CHART_ATTR_FIELDS = {'gaugeQualityBands'}
CHART_FONT_KEYS = ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale')


def emit_chart_node(lines, name, val, ind):
    if name in CHART_ML_FIELDS:
        if val is None or str(val) == '':
            lines.append(f'{ind}<d4p1:{name}/>')
            return
        lines.append(f'{ind}<d4p1:{name}>')
        emit_ml_items(lines, f'{ind}\t', val)
        lines.append(f'{ind}</d4p1:{name}>')
        return
    if isinstance(val, list):
        for e in val:
            emit_chart_node(lines, name, e, ind)
        return
    if isinstance(val, dict):
        keys = list(val.keys())
        if name in CHART_ATTR_FIELDS:
            attrs = ' '.join(f'{k}="{esc_xml(_pl_bool(val[k]) if isinstance(val[k], bool) else str(val[k]))}"' for k in keys)
            lines.append(f'{ind}<d4p1:{name} {attrs}/>')
            return
        if 'gap' in val:
            lines.append(f'{ind}<d4p1:{name} width="{val.get("width")}" gap="{_pl_bool(val.get("gap"))}">')
            lines.append(f'{ind}\t<v8ui:style xsi:type="v8ui:ChartLineType">{esc_xml(str(val.get("style")))}</v8ui:style>')
            lines.append(f'{ind}</d4p1:{name}>')
            return
        if 'style' in val and 'width' in val:
            lines.append(f'{ind}<d4p1:{name} width="{val.get("width")}">')
            lines.append(f'{ind}\t<v8ui:style xsi:type="v8ui:ControlBorderType">{esc_xml(str(val.get("style")))}</v8ui:style>')
            lines.append(f'{ind}</d4p1:{name}>')
            return
        if any(fk in val for fk in CHART_FONT_KEYS):
            attrs = ' '.join(f'{fk}="{esc_xml(_pl_bool(val[fk]) if isinstance(val[fk], bool) else str(val[fk]))}"' for fk in CHART_FONT_KEYS if fk in val)
            lines.append(f'{ind}<d4p1:{name} {attrs}/>')
            return
        if not keys:
            lines.append(f'{ind}<d4p1:{name}/>')
            return
        lines.append(f'{ind}<d4p1:{name}>')
        for k in keys:
            emit_chart_node(lines, k, val[k], f'{ind}\t')
        lines.append(f'{ind}</d4p1:{name}>')
        return
    if val is None or str(val) == '':
        lines.append(f'{ind}<d4p1:{name}/>')
        return
    if isinstance(val, bool):
        lines.append(f'{ind}<d4p1:{name}>{_pl_bool(val)}</d4p1:{name}>')
        return
    lines.append(f'{ind}<d4p1:{name}>{esc_xml(str(val))}</d4p1:{name}>')


def emit_chart_settings(lines, chart, ind, ctype='d4p1:Chart'):
    lines.append(f'{ind}<Settings xmlns:d4p1="{CHART_NS}" xsi:type="{ctype}">')
    for k in list(chart.keys()):
        emit_chart_node(lines, k, chart[k], f'{ind}\t')
    lines.append(f'{ind}</Settings>')


def emit_appearance(lines, el, indent, profile='field'):
    if not isinstance(el, dict):
        return
    order = {'decoration': APP_ORDER_DECORATION, 'button': APP_ORDER_BUTTON}.get(profile, APP_ORDER_FIELD)
    for key in order:
        val = get_appearance_value(el, key)
        if val is None or (isinstance(val, str) and val == ''):
            continue
        tag, kind = APPEARANCE_SPEC[key]
        if kind == 'color':
            lines.append(f'{indent}<{tag}>{esc_xml(str(val))}</{tag}>')
        elif kind == 'font':
            emit_font_tag(lines, tag, val, indent)
        else:
            emit_border_tag(lines, val, indent)


# Простые скаляры элемента (pass-through, зеркало $script:genericScalars). kind bool/value.
GENERIC_SCALARS = [
    ('VerticalAlign', 'verticalAlign', 'value'),
    ('ThroughAlign', 'throughAlign', 'value'),
    ('EnableContentChange', 'enableContentChange', 'bool'),
    ('PictureSize', 'pictureSize', 'value'),
    ('TitleHeight', 'titleHeight', 'value'),
    ('ChildItemsWidth', 'childItemsWidth', 'value'),
    ('ShowLeftMargin', 'showLeftMargin', 'bool'),
    ('CellHyperlink', 'cellHyperlink', 'bool'),
    ('ViewMode', 'viewMode', 'value'),
    ('VerticalScrollBar', 'verticalScrollBar', 'value'),
    ('RowInputMode', 'rowInputMode', 'value'),
    ('Mask', 'mask', 'value'),
    ('CreateButton', 'createButton', 'bool'),
    ('FixingInTable', 'fixingInTable', 'value'),
    ('VerticalSpacing', 'verticalSpacing', 'value'),
    # Spec-fields (document/gauge) - type-specific enum/bool scalars pass-through
    ('HorizontalScrollBar', 'horizontalScrollBar', 'value'),
    ('ViewScalingMode', 'viewScalingMode', 'value'),
    ('Output', 'output', 'value'),
    ('SelectionShowMode', 'selectionShowMode', 'value'),
    ('PointerType', 'pointerType', 'value'),
    ('DrawingSelectionShowMode', 'drawingSelectionShowMode', 'value'),
    ('WarningOnEditRepresentation', 'warningOnEditRepresentation', 'value'),
    ('MarkingAppearance', 'markingAppearance', 'value'),
    ('Protection', 'protection', 'bool'),
    ('Edit', 'edit', 'bool'),
    ('ShowGrid', 'showGrid', 'bool'),
    ('ShowGroups', 'showGroups', 'bool'),
    ('ShowHeaders', 'showHeaders', 'bool'),
    ('ShowRowAndColumnNames', 'showRowAndColumnNames', 'bool'),
    ('ShowCellNames', 'showCellNames', 'bool'),
    ('ShowPercent', 'showPercent', 'bool'),
    # Report-form контекст: интервал группы / представление кнопки в контекстном меню / детальное представление настройки таблицы
    ('HorizontalSpacing', 'horizontalSpacing', 'value'),
    ('RepresentationInContextMenu', 'representationInContextMenu', 'value'),
    ('SettingsNamedItemDetailedRepresentation', 'settingsNamedItemDetailedRepresentation', 'bool'),
    # Хвост: высота элемента списка (radio) / ширина выпадающего списка (input)
    ('ItemHeight', 'itemHeight', 'value'),
    ('DropListWidth', 'dropListWidth', 'value'),
    # Хвост CI-форм: динамический заголовок (Page/Group) / расширенное ред. (input) / высота таблицы по строкам
    ('TitleDataPath', 'titleDataPath', 'value'),
    ('ExtendedEdit', 'extendedEdit', 'bool'),
    ('MaxRowsCount', 'maxRowsCount', 'value'),
    ('AutoMaxRowsCount', 'autoMaxRowsCount', 'bool'),
    ('HeightControlVariant', 'heightControlVariant', 'value'),
    ('EditTextUpdate', 'editTextUpdate', 'value'),
    # Корпусный хвост: свёртка группы / форма попапа / авто-добавление / выделение отрицательных /
    # нач. позиция списка / высота списка выбора / три состояния / прокрутка страницы при сжатии
    ('ControlRepresentation', 'controlRepresentation', 'value'),
    ('ShapeRepresentation', 'shapeRepresentation', 'value'),
    ('AutoAddIncomplete', 'autoAddIncomplete', 'bool'),
    ('MarkNegatives', 'markNegatives', 'bool'),
    ('InitialListView', 'initialListView', 'value'),
    ('ChoiceListHeight', 'choiceListHeight', 'value'),
    ('ThreeState', 'threeState', 'bool'),
    ('ScrollOnCompress', 'scrollOnCompress', 'bool'),
    # Сочетание клавиш — общее свойство (команда — отдельный путь)
    ('Shortcut', 'shortcut', 'value'),
    # Батч простых скаляров (input/radio/group/picDecoration/button; Table-специфичные — отдельно)
    ('IncompleteChoiceMode', 'incompleteChoiceMode', 'value'),
    ('EqualColumnsWidth', 'equalColumnsWidth', 'bool'),
    ('ChildrenAlign', 'childrenAlign', 'value'),
    ('ImageScale', 'imageScale', 'value'),
    ('Zoomable', 'zoomable', 'bool'),
    ('Shape', 'shape', 'value'),
    ('PictureLocation', 'pictureLocation', 'value'),
    # Равная ширина элементов (check/radio) / высота заголовка пункта (radio)
    ('EqualItemsWidth', 'equalItemsWidth', 'bool'),
    ('ItemTitleHeight', 'itemTitleHeight', 'value'),
    # Спец-режим ввода текста (input, моб.: Email/PhoneNumber/...) — листовой enum-скаляр
    ('SpecialTextInputMode', 'specialTextInputMode', 'value'),
    # Ширина пункта (radio/check) / выбор нескольких значений из выпадающего (input)
    ('ItemWidth', 'itemWidth', 'value'),
    ('ShowCheckBoxesInDropList', 'showCheckBoxesInDropList', 'bool'),
    ('MultipleValueDataPath', 'multipleValueDataPath', 'value'),
    ('MultipleValuePresentDataPath', 'multipleValuePresentDataPath', 'value'),
    # Режим авто-показа кнопок открытия/очистки (input, enum)
    ('AutoShowOpenButtonMode', 'autoShowOpenButtonMode', 'value'),
    ('AutoShowClearButtonMode', 'autoShowClearButtonMode', 'value'),
    # Оформление/картинка множественного выбора (input, редко; цвета — текст-контент)
    ('MultipleValuesTextColor', 'multipleValuesTextColor', 'value'),
    ('MultipleValuesBackColor', 'multipleValuesBackColor', 'value'),
    ('MultipleValuePictureShape', 'multipleValuePictureShape', 'value'),
    ('MultipleValuePictureDataPath', 'multipleValuePictureDataPath', 'value'),
    # Хвост листовых скаляров (по 1): автокоррекция / уникальность команды / пустое множ.значение / гориз.сжатие
    ('AutoCorrectionOnTextInput', 'autoCorrectionOnTextInput', 'value'),
    ('SpellCheckingOnTextInput', 'spellCheckingOnTextInput', 'value'),
    ('CommandUniqueness', 'commandUniqueness', 'bool'),
    ('AllowInputEmptyMultipleValues', 'allowInputEmptyMultipleValues', 'bool'),
    ('BehaviorOnHorizontalCompression', 'behaviorOnHorizontalCompression', 'value'),
]


def emit_generic_scalars(lines, el, indent):
    for tag, key, kind in GENERIC_SCALARS:
        if key not in el or el[key] is None:
            continue
        if kind == 'bool':
            lines.append(f'{indent}<{tag}>{"true" if el[key] else "false"}</{tag}>')
        else:
            v = str(el[key])
            if v == '':
                continue
            lines.append(f'{indent}<{tag}>{esc_xml(v)}</{tag}>')


def emit_layout(lines, el, indent, skip_height=False, multi_line_default=False):
    # Общие layout-свойства — применимы ко всем элементам. Порядок согласован
    # с историческим выводом input/label, чтобы не сдвигать существующие снапшоты.
    # skip_height: подавить <Height> (зарезервирован; Table теперь эмитит <Height> generic-ом + свой <HeightInTableRows>).
    # multi_line_default: input без явного autoMaxWidth при multiLine → AutoMaxWidth=false.
    # CommandSet (отключённые команды редактора) — общее свойство поля; в схеме рано (после TitleLocation).
    if el.get('excludedCommands') and len(el['excludedCommands']) > 0:
        lines.append(f'{indent}<CommandSet>')
        for cmd in el['excludedCommands']:
            lines.append(f'{indent}\t<ExcludedCommand>{cmd}</ExcludedCommand>')
        lines.append(f'{indent}</CommandSet>')
    emit_common_element_props(lines, el, indent)
    if 'autoMaxWidth' in el:
        if el.get('autoMaxWidth') is False:
            lines.append(f"{indent}<AutoMaxWidth>false</AutoMaxWidth>")
    elif multi_line_default:
        lines.append(f"{indent}<AutoMaxWidth>false</AutoMaxWidth>")
    if el.get('maxWidth') is not None:
        lines.append(f"{indent}<MaxWidth>{el['maxWidth']}</MaxWidth>")
    if el.get('autoMaxHeight') is False:
        lines.append(f"{indent}<AutoMaxHeight>false</AutoMaxHeight>")
    if el.get('maxHeight') is not None:
        lines.append(f"{indent}<MaxHeight>{el['maxHeight']}</MaxHeight>")
    if el.get('width'):
        lines.append(f"{indent}<Width>{el['width']}</Width>")
    if not skip_height and el.get('height'):
        lines.append(f"{indent}<Height>{el['height']}</Height>")
    if el.get('horizontalStretch') is not None:
        lines.append(f'{indent}<HorizontalStretch>{"true" if el["horizontalStretch"] else "false"}</HorizontalStretch>')
    if el.get('verticalStretch') is not None:
        lines.append(f'{indent}<VerticalStretch>{"true" if el["verticalStretch"] else "false"}</VerticalStretch>')
    if el.get('groupHorizontalAlign'):
        lines.append(f"{indent}<GroupHorizontalAlign>{el['groupHorizontalAlign']}</GroupHorizontalAlign>")
    if el.get('groupVerticalAlign'):
        lines.append(f"{indent}<GroupVerticalAlign>{el['groupVerticalAlign']}</GroupVerticalAlign>")
    if el.get('horizontalAlign'):
        lines.append(f"{indent}<HorizontalAlign>{el['horizontalAlign']}</HorizontalAlign>")
    emit_generic_scalars(lines, el, indent)


def title_from_name(name):
    """СуммаДокумента → 'Сумма документа'. НДСВключен → 'НДС включен'."""
    if not name:
        return ''
    s = re.sub(r'([А-ЯA-Z])([А-ЯA-Z][а-яa-z])', r'\1 \2', name)
    s = re.sub(r'([а-яa-z0-9])([А-ЯA-Z])', r'\1 \2', s)
    parts = s.split(' ')
    if not parts:
        return s
    out = [parts[0]]
    for p in parts[1:]:
        out.append(p if (len(p) > 1 and p.isupper()) else p.lower())
    return ' '.join(out)


def emit_title(lines, el, name, indent, auto=False):
    # Нет ключа title → авто-вывод из имени (помощь модели).
    # Явный title "" (или None) → подавить. Явный непустой → как есть.
    if 'title' in el:
        if el.get('title'):
            emit_mltext(lines, indent, 'Title', el['title'])
    elif auto and name:
        emit_mltext(lines, indent, 'Title', title_from_name(name))
    # ToolTip элемента (всплывающая подсказка) — по схеме сразу после Title.
    if el.get('tooltip'):
        emit_mltext(lines, indent, 'ToolTip', el['tooltip'])
    # ToolTipRepresentation — режим показа подсказки (None/Button/ShowBottom/…), после ToolTip.
    if el.get('tooltipRepresentation'):
        lines.append(f'{indent}<ToolTipRepresentation>{el["tooltipRepresentation"]}</ToolTipRepresentation>')


_TITLE_LOC_MAP = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom', 'auto': 'Auto'}


def map_title_loc(v):
    return _TITLE_LOC_MAP.get(str(v).lower(), str(v))


def emit_title_location(lines, el, indent, smart_default):
    # Нет ключа → умный дефолт (Right/None), эмитится. "" → подавить (дефолт платформы).
    # Значение → эмитить с маппингом регистра.
    if 'titleLocation' in el:
        if el.get('titleLocation'):
            lines.append(f"{indent}<TitleLocation>{map_title_loc(el['titleLocation'])}</TitleLocation>")
    elif smart_default:
        lines.append(f"{indent}<TitleLocation>{smart_default}</TitleLocation>")


# --- Type emitter ---

V8_TYPES = {
    "ValueTable": "v8:ValueTable",
    "ValueTree": "v8:ValueTree",
    "ValueList": "v8:ValueListType",
    "TypeDescription": "v8:TypeDescription",
    "Universal": "v8:Universal",
    "FixedArray": "v8:FixedArray",
    "FixedStructure": "v8:FixedStructure",
}

UI_TYPES = {
    "FormattedString": "v8ui:FormattedString",
    "Picture": "v8ui:Picture",
    "Color": "v8ui:Color",
    "Font": "v8ui:Font",
}

DCS_MAP = {
    "DataCompositionSettings": "dcsset:DataCompositionSettings",
    "DataCompositionSchema": "dcssch:DataCompositionSchema",
    "DataCompositionComparisonType": "dcscor:DataCompositionComparisonType",
}

CFG_REF_PATTERN = re.compile(
    r'^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|'
    r'ChartOfAccountsRef|ChartOfAccountsObject|ChartOfCharacteristicTypesRef|ChartOfCharacteristicTypesObject|'
    r'ChartOfCalculationTypesRef|ChartOfCalculationTypesObject|'
    r'ExchangePlanRef|ExchangePlanObject|BusinessProcessRef|BusinessProcessObject|TaskRef|TaskObject|'
    r'InformationRegisterRecordSet|InformationRegisterRecordManager|'
    r'AccumulationRegisterRecordSet|AccountingRegisterRecordSet|'
    r'ConstantsSet|DataProcessorObject|ReportObject)\.'
)

KNOWN_INVALID_TYPES = {
    'FormDataStructure': 'Runtime type. Use object type without cfg: prefix (e.g. CatalogObject.Контрагенты, DocumentObject.Приход)',
    'FormDataCollection': 'Runtime type. Use ValueTable',
    'FormDataTree': 'Runtime type. Use ValueTree',
    'FormDataTreeItem': 'Runtime type, not valid in XML',
    'FormDataCollectionItem': 'Runtime type, not valid in XML',
    'FormGroup': 'UI element type, not a data type',
    'FormField': 'UI element type, not a data type',
    'FormButton': 'UI element type, not a data type',
    'FormDecoration': 'UI element type, not a data type',
    'FormTable': 'UI element type, not a data type',
}


_FORM_TYPE_SYNONYMS = {
    "строка": "string", "число": "decimal", "булево": "boolean",
    "дата": "date", "датавремя": "dateTime",
    "number": "decimal", "bool": "boolean",
    "справочникссылка": "CatalogRef", "справочникобъект": "CatalogObject",
    "документссылка": "DocumentRef", "документобъект": "DocumentObject",
    "перечислениессылка": "EnumRef",
    "плансчетовссылка": "ChartOfAccountsRef",
    "планвидовхарактеристикссылка": "ChartOfCharacteristicTypesRef",
    "планвидоврасчётассылка": "ChartOfCalculationTypesRef",
    "планвидоврасчетассылка": "ChartOfCalculationTypesRef",
    "планобменассылка": "ExchangePlanRef",
    "бизнеспроцессссылка": "BusinessProcessRef",
    "задачассылка": "TaskRef",
    "определяемыйтип": "DefinedType",
    "характеристика": "Characteristic",
    "любаяссылка": "AnyRef",
    "любаяссылкаиб": "AnyIBRef",
    # Платформенные v8-типы (forgiving: англ. без префикса + рус.) → каноничный с префиксом v8:
    "standardperiod": "v8:StandardPeriod",
    "стандартныйпериод": "v8:StandardPeriod",
    "standardbeginningdate": "v8:StandardBeginningDate",
    "стандартнаядатаначала": "v8:StandardBeginningDate",
    "uuid": "v8:UUID",
    "уникальныйидентификатор": "v8:UUID",
    "списокзначений": "ValueList",
}


def resolve_type_str(type_str):
    if not type_str:
        return type_str
    # Lenient: strip leading cfg: prefix if user passed it (canonical form is without prefix)
    if type_str.startswith('cfg:'):
        type_str = type_str[4:]
    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base, params = m.group(1).strip(), m.group(2)
        r = _FORM_TYPE_SYNONYMS.get(base.lower())
        return f"{r}({params})" if r else type_str
    if '.' in type_str:
        i = type_str.index('.')
        prefix, suffix = type_str[:i], type_str[i:]
        r = _FORM_TYPE_SYNONYMS.get(prefix.lower())
        return f"{r}{suffix}" if r else type_str
    r = _FORM_TYPE_SYNONYMS.get(type_str.lower())
    return r if r else type_str


def emit_single_type(lines, type_str, indent):
    type_str = resolve_type_str(type_str)
    # TypeId — тип, заданный глобальным стабильным GUID (<v8:TypeId>, не <v8:Type>). Платформа так
    # сериализует типы, чьё имя в этом контексте недоступно (определяемые/характеристики). GUID
    # глобально стабилен → эмитим verbatim (как роль-по-GUID). Маркер декомпилятора: 'typeid:GUID'.
    m = re.match(r'^typeid:([0-9a-fA-F-]{36})$', type_str)
    if m:
        lines.append(f'{indent}<v8:TypeId>{m.group(1)}</v8:TypeId>')
        return
    # boolean
    if type_str == 'boolean':
        lines.append(f'{indent}<v8:Type>xs:boolean</v8:Type>')
        return

    # string or string(N) or string(N,fixed) (AllowedLength: Variable дефолт / Fixed)
    m = re.match(r'^string(\((\d+)(\s*,\s*(fixed|variable))?\))?$', type_str, re.IGNORECASE)
    if m:
        length = m.group(2) if m.group(2) else '0'
        al = 'Fixed' if (m.group(4) and m.group(4).lower() == 'fixed') else 'Variable'
        lines.append(f'{indent}<v8:Type>xs:string</v8:Type>')
        lines.append(f'{indent}<v8:StringQualifiers>')
        lines.append(f'{indent}\t<v8:Length>{length}</v8:Length>')
        lines.append(f'{indent}\t<v8:AllowedLength>{al}</v8:AllowedLength>')
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

    # date / dateTime / time
    m = re.match(r'^(date|dateTime|time)$', type_str)
    if m:
        fractions_map = {'date': 'Date', 'dateTime': 'DateTime', 'time': 'Time'}
        fractions = fractions_map[type_str]
        lines.append(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
        lines.append(f'{indent}<v8:DateQualifiers>')
        lines.append(f'{indent}\t<v8:DateFractions>{fractions}</v8:DateFractions>')
        lines.append(f'{indent}</v8:DateQualifiers>')
        return

    # V8 types
    if type_str in V8_TYPES:
        lines.append(f'{indent}<v8:Type>{V8_TYPES[type_str]}</v8:Type>')
        return

    # UI types
    if type_str in UI_TYPES:
        lines.append(f'{indent}<v8:Type>{UI_TYPES[type_str]}</v8:Type>')
        return

    # DCS types
    if type_str.startswith('DataComposition'):
        if type_str in DCS_MAP:
            lines.append(f'{indent}<v8:Type>{DCS_MAP[type_str]}</v8:Type>')
            return

    # Голые конфигурационные типы (cfg: без .Имя): дин-список, набор констант, общий объект отчёта.
    # Корпус (acc+erp 8.3.24): DynamicList 5205, ConstantsSet 103, ReportObject 10.
    if type_str in ('DynamicList', 'ConstantsSet', 'ReportObject'):
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return

    # TypeSet (набор типов) → <v8:TypeSet>: определяемый тип / характеристика (именованные)
    # + «любая ссылка вида» (голый ref-вид без .Имя). Развязка с обычным типом — по наличию точки.
    if re.match(r'^(DefinedType|Characteristic)\.', type_str):
        lines.append(f'{indent}<v8:TypeSet>cfg:{type_str}</v8:TypeSet>')
        return
    if re.match(r'^(AnyRef|AnyIBRef|CatalogRef|DocumentRef|EnumRef|ExchangePlanRef|TaskRef|BusinessProcessRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef)$', type_str):
        lines.append(f'{indent}<v8:TypeSet>cfg:{type_str}</v8:TypeSet>')
        return

    # cfg: references
    if CFG_REF_PATTERN.match(type_str):
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return

    # Спец-типы платформы с собственным namespace (объявляется ЛОКАЛЬНО на <v8:Type>).
    # Префикс d5p1 неоднозначен (5 разных URI), поэтому маппинг по полному значению типа.
    # К таким типам привязаны спец-поля: mxl→SpreadSheetDocumentField, fd→FormattedDocumentField,
    # d5p1:TextDocument→TextDocumentField, pdfdoc→PDF, pl→Planner, chart/geo/graphscheme/data-analysis.
    special_type_ns = {
        "mxl:SpreadsheetDocument": "http://v8.1c.ru/8.2/data/spreadsheet",
        "fd:FormattedDocument": "http://v8.1c.ru/8.2/data/formatted-document",
        "d5p1:TextDocument": "http://v8.1c.ru/8.1/data/txtedt",
        "d5p1:Chart": "http://v8.1c.ru/8.2/data/chart",
        "d5p1:GanttChart": "http://v8.1c.ru/8.2/data/chart",
        "d5p1:Dendrogram": "http://v8.1c.ru/8.2/data/chart",
        "d5p1:FlowchartContextType": "http://v8.1c.ru/8.2/data/graphscheme",
        "d5p1:DataAnalysisTimeIntervalUnitType": "http://v8.1c.ru/8.2/data/data-analysis",
        "d5p1:GeographicalSchema": "http://v8.1c.ru/8.2/data/geo",
        "pdfdoc:PDFDocument": "http://v8.1c.ru/8.3/data/pdf",
        "pl:Planner": "http://v8.1c.ru/8.3/data/planner",
    }
    if type_str in special_type_ns:
        pref = type_str.split(':', 1)[0]
        lines.append(f'{indent}<v8:Type xmlns:{pref}="{special_type_ns[type_str]}">{type_str}</v8:Type>')
        return

    # Fallback with validation
    if type_str in KNOWN_INVALID_TYPES:
        raise ValueError(f"Invalid form attribute type '{type_str}': {KNOWN_INVALID_TYPES[type_str]}")
    # Платформенный тип с префиксом (v8:/v8ui:/xs:/dcs*:) — verbatim (напр. v8:UUID, v8:StandardPeriod).
    if re.match(r'^(v8|v8ui|xs|ent|style|sys|web|win|dcs\w*):', type_str):
        lines.append(f'{indent}<v8:Type>{type_str}</v8:Type>')
    elif '.' in type_str:
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
    else:
        print(f"WARNING: Unrecognized bare type '{type_str}' — will be emitted without namespace prefix", file=sys.stderr)
        lines.append(f'{indent}<v8:Type>{type_str}</v8:Type>')


def emit_type(lines, type_str, indent, tag="Type", tag_attrs=""):
    # tag/tag_attrs — обёртка (по умолчанию <Type>); для valueType ValueList вызывается с
    # tag="Settings", tag_attrs=' xsi:type="v8:TypeDescription"'.
    if not type_str:
        lines.append(f'{indent}<{tag}{tag_attrs}/>')
        return

    type_string = str(type_str)
    parts = [p.strip() for p in re.split(r'[|+]', type_string)]

    lines.append(f'{indent}<{tag}{tag_attrs}>')
    for part in parts:
        emit_single_type(lines, part, f'{indent}\t')
    lines.append(f'{indent}</{tag}>')


# --- Element emitters ---

def emit_element(lines, el, indent, in_cmd_bar=False):
    # Companion-панели (объект/массив-значение) → commandBar/contextMenu, до тип-синонимов.
    normalize_panel_synonyms(el)

    # Silent synonyms: model often writes XML name or Russian (ПолеПереключателя/RadioButtonField → radio).
    # commandBar/autoCommandBar/КоманднаяПанель → тип-элемент ТОЛЬКО при строковом значении (имя).
    for src, dst in ELEMENT_TYPE_SYNONYMS.items():
        if src in el and dst not in el:
            if src in STR_ONLY_TYPE_SYNONYMS and not isinstance(el[src], str):
                continue
            el[dst] = el.pop(src)

    # Синонимы ключей-свойств (русские имена 1С → канон. англ.). Case/space-insensitive.
    # Канон побеждает: если задан и русский, и англ. ключ — англ. остаётся, русский отбрасываем.
    for p_name in list(el.keys()):
        norm = p_name.replace(' ', '').lower()
        canon = PROP_SYNONYMS.get(norm)
        if canon and p_name != canon:
            val = el.pop(p_name)
            if canon not in el:
                el[canon] = val

    type_key = None
    for key in TYPE_KEYS:
        if el.get(key) is not None:
            type_key = key
            break

    if not type_key:
        print("WARNING: Unknown element type, skipping", file=sys.stderr)
        return

    # Validate known keys (внутренние маркеры на _ пропускаем). Оформление (цвета/шрифты/граница)
    # проверяем против самих структур appearance — канонические ключи + forgiving-синонимы, чтобы
    # allowlist не дрейфовал при добавлении новых.
    for p_name in el.keys():
        if p_name.startswith('_'):
            continue
        if p_name not in KNOWN_KEYS and p_name not in APPEARANCE_SPEC and p_name not in APPEARANCE_SYNONYMS:
            print(f"WARNING: Element '{el.get(type_key, '')}': unknown key '{p_name}' -- ignored. Check SKILL.md for valid keys.", file=sys.stderr)

    name = get_element_name(el, type_key)
    _ensure_unique(name, _seen_element_names, 'element')
    eid = new_id()

    emitters = {
        'group': emit_group,
        'columnGroup': emit_column_group,
        'buttonGroup': emit_button_group,
        'input': emit_input,
        'check': emit_check,
        'radio': emit_radio_button_field,
        'label': emit_label,
        'labelField': emit_label_field,
        'table': emit_table,
        'pages': emit_pages,
        'page': emit_page,
        'button': emit_button,
        'picture': emit_picture_decoration,
        'picField': emit_picture_field,
        'calendar': emit_calendar,
        'cmdBar': emit_command_bar,
        'popup': emit_popup,
        'searchString':  lambda lines, el, name, eid, indent: emit_addition(lines, el, name, eid, 'searchString', indent),
        'viewStatus':    lambda lines, el, name, eid, indent: emit_addition(lines, el, name, eid, 'viewStatus', indent),
        'searchControl': lambda lines, el, name, eid, indent: emit_addition(lines, el, name, eid, 'searchControl', indent),
        'spreadsheet':   lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'SpreadSheetDocumentField', 'spreadsheet'),
        'html':          lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'HTMLDocumentField', 'html'),
        'textDoc':       lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'TextDocumentField', 'textDoc'),
        'formattedDoc':  lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'FormattedDocumentField', 'formattedDoc'),
        'progressBar':   lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'ProgressBarField', 'progressBar'),
        'trackBar':      lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'TrackBarField', 'trackBar'),
        'chart':           lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'ChartField', 'chart'),
        'graphicalSchema': lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'GraphicalSchemaField', 'graphicalSchema'),
        'planner':         lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'PlannerField', 'planner'),
        'periodField':     lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'PeriodField', 'periodField'),
        'dendrogram':      lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'DendrogramField', 'dendrogram'),
        'ganttChart':      emit_gantt_chart,
    }

    emitter = emitters.get(type_key)
    if emitter:
        if type_key == 'button':
            emitter(lines, el, name, eid, indent, in_cmd_bar=in_cmd_bar)
        else:
            emitter(lines, el, name, eid, indent)


def _warn_unrecognized(key, raw, valid, owner):
    # drop-on-miss enum: значение не распознано → тег не эмитится. Громко, чтобы автор увидел потерю.
    print(f"[WARN] Unrecognized {key} '{raw}' on '{owner}'. Valid values: {', '.join(valid)}. Value ignored.")


def emit_group(lines, el, name, eid, indent):
    lines.append(f'{indent}<UsualGroup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    # Group orientation
    # Group orientation (направление). Legacy: group:'collapsible' = Vertical + behavior collapsible.
    group_val = str(el.get('group', '')).lower()
    orientation_map = {
        'horizontal': 'Horizontal',
        'vertical': 'Vertical',
        'alwayshorizontal': 'AlwaysHorizontal',
        'alwaysvertical': 'AlwaysVertical',
        'horizontalifpossible': 'HorizontalIfPossible',
        'collapsible': 'Vertical',
    }
    orientation = orientation_map.get(group_val)
    if orientation:
        lines.append(f'{inner}<Group>{orientation}</Group>')
    elif group_val:
        _warn_unrecognized('group orientation', el.get('group'), ('vertical', 'horizontalIfPossible', 'alwaysHorizontal'), name)

    # Behavior: ключ behavior (usual/collapsible/popup) → <Behavior>; отсутствие = Авто (не эмитим).
    behavior_val = str(el['behavior']).lower() if el.get('behavior') else ('collapsible' if group_val == 'collapsible' else None)
    bmap = {'usual': 'Usual', 'collapsible': 'Collapsible', 'popup': 'PopUp'}
    if behavior_val and behavior_val in bmap:
        lines.append(f'{inner}<Behavior>{bmap[behavior_val]}</Behavior>')
    elif el.get('behavior') and behavior_val not in bmap:
        _warn_unrecognized('behavior', el.get('behavior'), ('collapsible', 'popup'), name)
    # Collapsed — у Collapsible и PopUp (не привязано к одному behavior)
    if el.get('collapsed') is True:
        lines.append(f'{inner}<Collapsed>true</Collapsed>')

    # Representation
    if el.get('representation'):
        repr_map = {
            'none': 'None',
            'normal': 'NormalSeparation',
            'weak': 'WeakSeparation',
            'strong': 'StrongSeparation',
        }
        repr_val = repr_map.get(str(el['representation']), str(el['representation']))
        lines.append(f'{inner}<Representation>{repr_val}</Representation>')

    # Использование текущей строки группы (после Representation, порядок XSD)
    if el.get('currentRowUse'):
        lines.append(f'{inner}<CurrentRowUse>{el["currentRowUse"]}</CurrentRowUse>')

    # ShowTitle
    if el.get('showTitle') is not None:
        lines.append(f'{inner}<ShowTitle>{"true" if el["showTitle"] else "false"}</ShowTitle>')
    # Заголовок свёрнутого представления (collapsible/popup) — мультиязычный текст
    if el.get('collapsedTitle'):
        emit_mltext(lines, inner, 'CollapsedRepresentationTitle', el['collapsedTitle'])

    # United
    if el.get('united') is False:
        lines.append(f'{inner}<United>false</United>')

    # Формат значения пути к данным заголовка (<Format>; парный к titleDataPath группы)
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # Оформление (цвета/шрифты/граница) — перед компаньоном
    emit_appearance(lines, el, inner, 'field')

    # Companion: ExtendedTooltip
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</UsualGroup>')


def emit_column_group(lines, el, name, eid, indent):
    lines.append(f'{indent}<ColumnGroup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    group_val = str(el.get('columnGroup', '')).lower()
    orientation_map = {
        'horizontal': 'Horizontal',
        'vertical': 'Vertical',
        'incell': 'InCell',
    }
    orientation = orientation_map.get(group_val)
    if orientation:
        lines.append(f'{inner}<Group>{orientation}</Group>')
    elif group_val:
        _warn_unrecognized('columnGroup orientation', el.get('columnGroup'), ('vertical', 'horizontal', 'inCell'), name)

    if el.get('showTitle') is not None:
        lines.append(f'{inner}<ShowTitle>{"true" if el["showTitle"] else "false"}</ShowTitle>')
    # showInHeader эмитится общим emit_common_element_props (через emit_layout)

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # Картинка заголовка колонки-группы (после ShowInHeader/Layout, перед оформлением — порядок XSD)
    emit_column_pics(lines, el, inner)

    # Оформление (цвета/шрифты/граница) — перед компаньоном
    emit_appearance(lines, el, inner, 'field')

    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</ColumnGroup>')


def emit_input(lines, el, name, eid, indent):
    lines.append(f'{indent}<InputField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        loc_map = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom'}
        loc = loc_map.get(str(el['titleLocation']), str(el['titleLocation']))
        lines.append(f'{inner}<TitleLocation>{loc}</TitleLocation>')

    if el.get('multiLine') is not None:
        lines.append(f'{inner}<MultiLine>{"true" if el["multiLine"] else "false"}</MultiLine>')
    if el.get('passwordMode') is not None:
        lines.append(f'{inner}<PasswordMode>{"true" if el["passwordMode"] else "false"}</PasswordMode>')
    # ChoiceButton — захват «как есть» (платформа эмитит явное значение; ref-поля выводят сама,
    # декомпилятор фиксирует факт. значение). Нет ключа → не эмитим (не додумываем по событию).
    if el.get('choiceButton') is not None:
        lines.append(f'{inner}<ChoiceButton>{"true" if el["choiceButton"] else "false"}</ChoiceButton>')
    # Кнопки поля ввода — захват «как есть» (платформа эмитит явное значение, в т.ч. false)
    if el.get('clearButton') is not None:
        lines.append(f'{inner}<ClearButton>{"true" if el["clearButton"] else "false"}</ClearButton>')
    if el.get('spinButton') is not None:
        lines.append(f'{inner}<SpinButton>{"true" if el["spinButton"] else "false"}</SpinButton>')
    if el.get('dropListButton') is not None:
        lines.append(f'{inner}<DropListButton>{"true" if el["dropListButton"] else "false"}</DropListButton>')
    if el.get('choiceListButton') is not None:
        lines.append(f'{inner}<ChoiceListButton>{"true" if el["choiceListButton"] else "false"}</ChoiceListButton>')
    if el.get('markIncomplete') is not None:
        lines.append(f'{inner}<AutoMarkIncomplete>{"true" if el["markIncomplete"] else "false"}</AutoMarkIncomplete>')
    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_column_pics(lines, el, inner)
    if el.get('textEdit') is False:
        lines.append(f'{inner}<TextEdit>false</TextEdit>')
    # InputField-специфичные скаляры (захват «как есть»: платформа эмитит явное не-дефолтное значение)
    for key, tag in (('wrap', 'Wrap'), ('openButton', 'OpenButton'), ('listChoiceMode', 'ListChoiceMode'),
                     ('extendedEditMultipleValues', 'ExtendedEditMultipleValues'), ('chooseType', 'ChooseType'),
                     ('quickChoice', 'QuickChoice'), ('autoChoiceIncomplete', 'AutoChoiceIncomplete')):
        if el.get(key) is not None:
            lines.append(f'{inner}<{tag}>{"true" if el[key] else "false"}</{tag}>')
    # Ограничение доступных типов (поле на составном типе): домен типов + явный набор.
    # availableTypes — формат типа реквизита (§type); emit_type сам разбирает мультитип "a | b".
    if el.get('typeDomainEnabled') is not None:
        lines.append(f'{inner}<TypeDomainEnabled>{"true" if el["typeDomainEnabled"] else "false"}</TypeDomainEnabled>')
    if el.get('availableTypes'):
        emit_type(lines, el['availableTypes'], inner, tag='AvailableTypes')
    # InputField-специфичные value-скаляры
    for key, tag in (('choiceForm', 'ChoiceForm'), ('choiceHistoryOnInput', 'ChoiceHistoryOnInput'),
                     ('choiceFoldersAndItems', 'ChoiceFoldersAndItems'), ('footerDataPath', 'FooterDataPath')):
        if el.get(key):
            lines.append(f'{inner}<{tag}>{esc_xml(str(el[key]))}</{tag}>')
    # MinValue/MaxValue — типизированное. JSON-число → xs:decimal, строка → xs:string (тип сохранён декомпилятором).
    for key, tag in (('minValue', 'MinValue'), ('maxValue', 'MaxValue')):
        if el.get(key) is not None:
            mvt = 'xs:string' if isinstance(el[key], str) else 'xs:decimal'
            lines.append(f'{inner}<{tag} xsi:type="{mvt}">{esc_xml(str(el[key]))}</{tag}>')
    if el.get('choiceButtonRepresentation'):
        lines.append(f'{inner}<ChoiceButtonRepresentation>{el["choiceButtonRepresentation"]}</ChoiceButtonRepresentation>')
    emit_picture_ref(lines, el.get('choiceButtonPicture'), 'ChoiceButtonPicture', inner)
    emit_layout(lines, el, inner, multi_line_default=(el.get('multiLine') is True))

    if el.get('inputHint'):
        emit_mltext(lines, inner, 'InputHint', el['inputHint'])
    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # Формат / формат редактирования (LocalStringType — строка или {ru,en})
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    emit_choice_list(lines, el, inner)

    # Связи по типу / связи параметров выбора / параметры выбора
    emit_type_link(lines, el, inner)
    emit_choice_parameter_links(lines, el, inner)
    emit_choice_parameters(lines, el, inner)

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'input')

    lines.append(f'{indent}</InputField>')


def emit_check(lines, el, name, eid, indent):
    lines.append(f'{indent}<CheckBoxField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_column_pics(lines, el, inner)
    # CheckBoxType: нет ключа → умный дефолт Auto; "" → подавить; значение → маппинг
    _cbt_map = {'auto': 'Auto', 'checkbox': 'CheckBox', 'switcher': 'Switcher', 'tumbler': 'Tumbler'}
    if 'checkBoxType' in el:
        if el.get('checkBoxType'):
            lines.append(f'{inner}<CheckBoxType>{_cbt_map.get(str(el["checkBoxType"]).lower(), el["checkBoxType"])}</CheckBoxType>')
    else:
        lines.append(f'{inner}<CheckBoxType>Auto</CheckBoxType>')

    emit_title_location(lines, el, inner, 'Right')

    emit_layout(lines, el, inner)

    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])
    # FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
    if el.get('footerDataPath'):
        lines.append(f'{inner}<FooterDataPath>{esc_xml(str(el["footerDataPath"]))}</FooterDataPath>')
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # Формат / формат редактирования (LocalStringType — строка или {ru,en})
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'check')

    lines.append(f'{indent}</CheckBoxField>')


def emit_radio_button_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<RadioButtonField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_title_location(lines, el, inner, 'None')

    rbt = normalize_radio_button_type(el.get('radioButtonType'))
    lines.append(f'{inner}<RadioButtonType>{rbt}</RadioButtonType>')

    if el.get('columnsCount') is not None:
        lines.append(f'{inner}<ColumnsCount>{el["columnsCount"]}</ColumnsCount>')

    emit_choice_list(lines, el, inner)

    emit_layout(lines, el, inner)

    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    emit_companion_panel(lines, 'ContextMenu', f'{name}КонтекстноеМеню', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'radio')

    lines.append(f'{indent}</RadioButtonField>')


# Заголовок декорации (Label/Picture): formatted-aware <Title> через единую ML-text форму
# (reuse resolve_ml_formatted, как у extendedTooltip). Sibling-ключ formatted — back-compat override.
def emit_decoration_title(lines, el, name, indent, auto=False):
    has_key = 'title' in el
    title_val = el['title'] if has_key else (title_from_name(name) if (auto and name) else None)
    if title_val:
        text, fmt = resolve_ml_formatted(title_val)
        if 'formatted' in el:
            fmt = bool(el['formatted'])
        lines.append(f'{indent}<Title formatted="{"true" if fmt else "false"}">')
        emit_ml_items(lines, f'{indent}\t', text)
        lines.append(f'{indent}</Title>')
    if el.get('tooltip'):
        emit_mltext(lines, indent, 'ToolTip', el['tooltip'])
    if el.get('tooltipRepresentation'):
        lines.append(f'{indent}<ToolTipRepresentation>{el["tooltipRepresentation"]}</ToolTipRepresentation>')


def emit_label(lines, el, name, eid, indent):
    lines.append(f'{indent}<LabelDecoration name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    # Порядок как у платформы: own-content (флаги/hyperlink/layout/оформление) ПЕРЕД Title
    # (корпус layout-first 16970 vs 44 — заодно убирает шум атрибуции харнесса на многострочном Title).
    emit_common_flags(lines, el, inner)
    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
    emit_layout(lines, el, inner)
    emit_appearance(lines, el, inner, 'decoration')

    emit_decoration_title(lines, el, name, inner, auto=True)

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'label')

    lines.append(f'{indent}</LabelDecoration>')


def emit_label_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<LabelField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    # FooterDataPath — путь данных подвала колонки (общий cell-prop, как у input); после EditMode
    if el.get('footerDataPath'):
        lines.append(f'{inner}<FooterDataPath>{esc_xml(str(el["footerDataPath"]))}</FooterDataPath>')
    # PasswordMode на LabelField — платформа эмитит явный false (редко); факт. значение
    if el.get('passwordMode') is not None:
        lines.append(f'{inner}<PasswordMode>{"true" if el["passwordMode"] else "false"}</PasswordMode>')
    emit_column_pics(lines, el, inner)
    # ВНИМАНИЕ: у LabelField платформенный тег <Hiperlink> (опечатка 1С), не <Hyperlink>.
    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hiperlink>true</Hiperlink>')
    emit_layout(lines, el, inner)

    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # Формат / формат редактирования (LocalStringType — строка или {ru,en})
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    # Оформление (цвета/шрифты/граница + header/footer) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'labelField')

    lines.append(f'{indent}</LabelField>')


# Блок свойств таблицы, привязанной к динамическому списку (Group A defaults + B/C).
def emit_dynlist_table_block(lines, el, indent):
    # (useAlternationRowColor — общее свойство таблицы, эмитится в emit_table)
    # Group A (гарант. блок): дефолт + override
    ar = 'true' if el.get('autoRefresh') is True else 'false'
    lines.append(f'{indent}<AutoRefresh>{ar}</AutoRefresh>')
    arp = el['autoRefreshPeriod'] if el.get('autoRefreshPeriod') is not None else 60
    lines.append(f'{indent}<AutoRefreshPeriod>{arp}</AutoRefreshPeriod>')
    lines.append(f'{indent}<Period>')
    lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">Custom</v8:variant>')
    lines.append(f'{indent}\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>')
    lines.append(f'{indent}\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>')
    lines.append(f'{indent}</Period>')
    cfi = el.get('choiceFoldersAndItems') or 'Items'
    lines.append(f'{indent}<ChoiceFoldersAndItems>{cfi}</ChoiceFoldersAndItems>')
    rcr = 'true' if el.get('restoreCurrentRow') is True else 'false'
    lines.append(f'{indent}<RestoreCurrentRow>{rcr}</RestoreCurrentRow>')
    lines.append(f'{indent}<TopLevelParent xsi:nil="true"/>')
    sr = 'false' if el.get('showRoot') is False else 'true'
    lines.append(f'{indent}<ShowRoot>{sr}</ShowRoot>')
    arc = 'true' if el.get('allowRootChoice') is True else 'false'
    lines.append(f'{indent}<AllowRootChoice>{arc}</AllowRootChoice>')
    uodc = el.get('updateOnDataChange') or 'Auto'
    lines.append(f'{indent}<UpdateOnDataChange>{uodc}</UpdateOnDataChange>')
    if el.get('userSettingsGroup'):
        lines.append(f'{indent}<UserSettingsGroup>{el["userSettingsGroup"]}</UserSettingsGroup>')
    agcru = 'false' if el.get('allowGettingCurrentRowURL') is False else 'true'
    lines.append(f'{indent}<AllowGettingCurrentRowURL>{agcru}</AllowGettingCurrentRowURL>')


def emit_table(lines, el, name, eid, indent):
    _current_table_name['name'] = name   # дефолт source для кастомных дополнений в commandBar
    lines.append(f'{indent}<Table name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    # ChangeRowSet/Order — явное значение (в т.ч. false: платформа пишет его на ValueTable)
    if 'changeRowSet' in el and el['changeRowSet'] is not None:
        lines.append(f'{inner}<ChangeRowSet>{"true" if el["changeRowSet"] is True else "false"}</ChangeRowSet>')
    if 'changeRowOrder' in el and el['changeRowOrder'] is not None:
        lines.append(f'{inner}<ChangeRowOrder>{"true" if el["changeRowOrder"] is True else "false"}</ChangeRowOrder>')
    if el.get('autoInsertNewRow') is True:
        lines.append(f'{inner}<AutoInsertNewRow>true</AutoInsertNewRow>')
    # RowFilter — nil-плейсхолдер (ключ присутствует → эмитим)
    if 'rowFilter' in el:
        lines.append(f'{inner}<RowFilter xsi:nil="true"/>')
    # Высота в строках (<HeightInTableRows>) — отдельное свойство от <Height> (высота элемента,
    # эмитится generic-ом emit_layout ниже). Таблица может нести оба (237 в корпусе).
    if el.get('heightInTableRows'):
        lines.append(f'{inner}<HeightInTableRows>{el["heightInTableRows"]}</HeightInTableRows>')
    if el.get('header') is False:
        lines.append(f'{inner}<Header>false</Header>')
    if el.get('footer') is True:
        lines.append(f'{inner}<Footer>true</Footer>')

    if el.get('commandBarLocation'):
        lines.append(f'{inner}<CommandBarLocation>{el["commandBarLocation"]}</CommandBarLocation>')
    if el.get('searchStringLocation'):
        lines.append(f'{inner}<SearchStringLocation>{el["searchStringLocation"]}</SearchStringLocation>')

    if el.get('choiceMode') is True:
        lines.append(f'{inner}<ChoiceMode>true</ChoiceMode>')
    # Скаляры таблицы (захват «как есть»). Autofill — СВОЁ свойство таблицы (≠ AutoCommandBar autofill = tableAutofill).
    if el.get('autofill') is not None:
        lines.append(f'{inner}<Autofill>{"true" if el["autofill"] else "false"}</Autofill>')
    if el.get('multipleChoice') is True:
        lines.append(f'{inner}<MultipleChoice>true</MultipleChoice>')
    if el.get('searchOnInput'):
        lines.append(f'{inner}<SearchOnInput>{el["searchOnInput"]}</SearchOnInput>')
    if el.get('markIncomplete') is not None:
        lines.append(f'{inner}<AutoMarkIncomplete>{"true" if el["markIncomplete"] else "false"}</AutoMarkIncomplete>')
    # Высота шапки/подвала в строках (pass-through; 1С толерантна к порядку детей Table)
    if el.get('headerHeight') is not None:
        lines.append(f'{inner}<HeaderHeight>{el["headerHeight"]}</HeaderHeight>')
    if el.get('footerHeight') is not None:
        lines.append(f'{inner}<FooterHeight>{el["footerHeight"]}</FooterHeight>')
    if el.get('useAlternationRowColor') is True:
        lines.append(f'{inner}<UseAlternationRowColor>true</UseAlternationRowColor>')
    if el.get('selectionMode'):
        lines.append(f'{inner}<SelectionMode>{el["selectionMode"]}</SelectionMode>')
    if el.get('rowSelectionMode'):
        lines.append(f'{inner}<RowSelectionMode>{el["rowSelectionMode"]}</RowSelectionMode>')
    if el.get('verticalLines') is False:
        lines.append(f'{inner}<VerticalLines>false</VerticalLines>')
    if el.get('horizontalLines') is False:
        lines.append(f'{inner}<HorizontalLines>false</HorizontalLines>')
    if el.get('initialTreeView'):
        lines.append(f'{inner}<InitialTreeView>{el["initialTreeView"]}</InitialTreeView>')
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')
    if el.get('rowPictureDataPath'):
        lines.append(f'{inner}<RowPictureDataPath>{el["rowPictureDataPath"]}</RowPictureDataPath>')
    # RowsPicture — та же конвенция, что ValuesPicture (дефолт LoadTransparent=false; abs/TransparentPixel)
    emit_picture_ref(lines, el.get('rowsPicture'), 'RowsPicture', inner)
    # Использование текущей строки таблицы (pass-through; в корпусе соседствует с блоком дин-списка)
    if el.get('currentRowUse'):
        lines.append(f'{inner}<CurrentRowUse>{el["currentRowUse"]}</CurrentRowUse>')
    # Запрос обновления дин-списка (pass-through; в корпусе всегда PullFromTop)
    if el.get('refreshRequest'):
        lines.append(f'{inner}<RefreshRequest>{el["refreshRequest"]}</RefreshRequest>')
    # Блок свойств дин-список-таблицы (помечена эвристикой)
    if el.get('_dynList'):
        emit_dynlist_table_block(lines, el, inner)
    if el.get('viewStatusLocation'):
        lines.append(f'{inner}<ViewStatusLocation>{el["viewStatusLocation"]}</ViewStatusLocation>')
    if el.get('searchControlLocation'):
        lines.append(f'{inner}<SearchControlLocation>{el["searchControlLocation"]}</SearchControlLocation>')
    emit_layout(lines, el, inner)

    # CommandSet таблицы эмитится через emit_layout (общий механизм поля)

    # Оформление (цвета/граница таблицы) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    # AutoCommandBar — with optional Autofill control
    if el.get('commandBar') is not None:
        emit_companion_panel(lines, 'AutoCommandBar', f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c', inner, el.get('commandBar'))
    elif el.get('tableAutofill') is not None:
        acb_id = new_id()
        acb_name = f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c'
        af_val = 'true' if el['tableAutofill'] else 'false'
        lines.append(f'{inner}<AutoCommandBar name="{acb_name}" id="{acb_id}">')
        lines.append(f'{inner}\t<Autofill>{af_val}</Autofill>')
        lines.append(f'{inner}</AutoCommandBar>')
    else:
        emit_companion(lines, 'AutoCommandBar', f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))
    adds = el.get('additions')
    emit_table_addition(lines, 'searchString',  name, inner, get_addition_override(adds, 'searchString'))
    emit_table_addition(lines, 'viewStatus',    name, inner, get_addition_override(adds, 'viewStatus'))
    emit_table_addition(lines, 'searchControl', name, inner, get_addition_override(adds, 'searchControl'))

    # Columns
    if el.get('columns') and len(el['columns']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for col in el['columns']:
            emit_element(lines, col, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    emit_events(lines, el, name, inner, 'table')

    lines.append(f'{indent}</Table>')


def emit_pages(lines, el, name, eid, indent):
    lines.append(f'{indent}<Pages name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    if el.get('pagesRepresentation'):
        lines.append(f'{inner}<PagesRepresentation>{el["pagesRepresentation"]}</PagesRepresentation>')
    # \u0418\u0441\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u043d\u0438\u0435 \u0442\u0435\u043a\u0443\u0449\u0435\u0439 \u0441\u0442\u0440\u043e\u043a\u0438 (\u043f\u043e\u0441\u043b\u0435 PagesRepresentation, \u043f\u043e\u0440\u044f\u0434\u043e\u043a XSD)
    if el.get('currentRowUse'):
        lines.append(f'{inner}<CurrentRowUse>{el["currentRowUse"]}</CurrentRowUse>')

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # \u041e\u0444\u043e\u0440\u043c\u043b\u0435\u043d\u0438\u0435 (\u0446\u0432\u0435\u0442\u0430/\u0448\u0440\u0438\u0444\u0442\u044b/\u0433\u0440\u0430\u043d\u0438\u0446\u0430) \u0437\u0430\u0433\u043e\u043b\u043e\u0432\u043a\u0430 \u0433\u0440\u0443\u043f\u043f\u044b \u0441\u0442\u0440\u0430\u043d\u0438\u0446 \u2014 TitleFont/TitleTextColor/\u2026 (\u043a\u0430\u043a \u0443 Page)
    emit_appearance(lines, el, inner, 'field')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'pages')

    # Children (pages)
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Pages>')


def emit_page(lines, el, name, eid, indent):
    lines.append(f'{indent}<Page name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner, auto=True)
    emit_common_flags(lines, el, inner)

    # Картинка страницы (иконка вкладки): после Title/флагов, перед Group (порядок XSD).
    # Конвенция как у ValuesPicture (дефолт LoadTransparent=false): скаляр-Ref/'abs:X' или объект.
    emit_picture_ref(lines, el.get('picture'), 'Picture', inner)

    if el.get('group'):
        orientation_map = {
            'horizontal': 'Horizontal',
            'vertical': 'Vertical',
            'alwayshorizontal': 'AlwaysHorizontal',
            'alwaysvertical': 'AlwaysVertical',
            'horizontalifpossible': 'HorizontalIfPossible',
        }
        orientation = orientation_map.get(str(el['group']).lower())
        if orientation:
            lines.append(f'{inner}<Group>{orientation}</Group>')
        else:
            _warn_unrecognized('page group orientation', el['group'], ('vertical', 'horizontalIfPossible', 'alwaysHorizontal'), name)
    if el.get('showTitle') is not None:
        lines.append(f'{inner}<ShowTitle>{"true" if el["showTitle"] else "false"}</ShowTitle>')
    # Формат значения пути к данным заголовка (<Format>; парный к titleDataPath страницы)
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])
    emit_layout(lines, el, inner)

    # \u041e\u0444\u043e\u0440\u043c\u043b\u0435\u043d\u0438\u0435 \u0441\u0442\u0440\u0430\u043d\u0438\u0446\u044b (BackColor / TitleTextColor / TitleFont) \u2014 \u043f\u043e\u0441\u043b\u0435 ShowTitle, \u043f\u0435\u0440\u0435\u0434 \u043a\u043e\u043c\u043f\u0430\u043d\u044c\u043e\u043d\u043e\u043c
    emit_appearance(lines, el, inner, 'field')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Page>')


def emit_button(lines, el, name, eid, indent, in_cmd_bar=False):
    lines.append(f'{indent}<Button name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'
    # (общие свойства — через emit_layout ниже; отдельный вызов был бы двойной эмиссией)

    # Type — context-aware. Inside command bars (cmdBar/autoCmdBar/popup) only
    # CommandBarButton/CommandBarHyperlink are valid; UsualButton/Hyperlink would be ignored.
    # Forgiving resolver: any "ordinary button" hint resolves to UsualButton/CommandBarButton,
    # any "hyperlink" hint resolves to Hyperlink/CommandBarHyperlink — depending on context.
    btn_type = None
    if el.get('type'):
        raw = str(el['type'])
        if in_cmd_bar:
            cmd_bar_map = {
                'usual': 'CommandBarButton',
                'UsualButton': 'CommandBarButton',
                'commandBar': 'CommandBarButton',
                'CommandBarButton': 'CommandBarButton',
                'hyperlink': 'CommandBarHyperlink',
                'Hyperlink': 'CommandBarHyperlink',
                'CommandBarHyperlink': 'CommandBarHyperlink',
            }
            btn_type = cmd_bar_map.get(raw, raw)
        else:
            normal_map = {
                'usual': 'UsualButton',
                'UsualButton': 'UsualButton',
                'commandBar': 'UsualButton',
                'CommandBarButton': 'UsualButton',
                'hyperlink': 'Hyperlink',
                'Hyperlink': 'Hyperlink',
                'CommandBarHyperlink': 'Hyperlink',
            }
            btn_type = normal_map.get(raw, raw)
    elif in_cmd_bar:
        btn_type = 'CommandBarButton'
    if btn_type:
        lines.append(f'{inner}<Type>{btn_type}</Type>')

    # CommandName
    if el.get('command'):
        lines.append(f'{inner}<CommandName>Form.Command.{el["command"]}</CommandName>')
    # commandName — глобальная команда «как есть» (CommonCommand.X, Catalog.X.Command.Y …), без обёртки Form.
    if el.get('commandName') and not el.get('command'):
        lines.append(f'{inner}<CommandName>{el["commandName"]}</CommandName>')
    if el.get('stdCommand'):
        sc = str(el['stdCommand'])
        m = re.match(r'^(.+)\.(.+)$', sc)
        if m:
            lines.append(f'{inner}<CommandName>Form.Item.{m.group(1)}.StandardCommand.{m.group(2)}</CommandName>')
        else:
            lines.append(f'{inner}<CommandName>Form.StandardCommand.{sc}</CommandName>')
    # Parameter команды (после CommandName): строка → xr:MDObjectRef (объект метаданных);
    # объект {type} → v8:TypeDescription (грамматика типа). Forgiving-синоним 'параметр'.
    btn_param = el.get('parameter')
    if btn_param is None:
        btn_param = el.get('параметр')
    if btn_param is not None:
        if isinstance(btn_param, dict) and btn_param.get('type'):
            emit_type(lines, str(btn_param['type']), inner, tag='Parameter', tag_attrs=' xsi:type="v8:TypeDescription"')
        else:
            lines.append(f'{inner}<Parameter xsi:type="xr:MDObjectRef">{esc_xml(str(btn_param))}</Parameter>')
    # DataPath — привязка команды кнопки к контексту (Объект.Ref, Items.X.CurrentData.Поле)
    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not (el.get('command') or el.get('commandName') or el.get('stdCommand')))
    emit_common_flags(lines, el, inner)

    if el.get('defaultButton') is True:
        lines.append(f'{inner}<DefaultButton>true</DefaultButton>')
    # Check (пометка toggle-кнопки командной панели) — платформа эмитит только true.
    # Ключ 'checked' (не 'check': 'check' — тип-ключ CheckBoxField, был бы конфликт диспетчера типов)
    if el.get('checked') is True:
        lines.append(f'{inner}<Check>true</Check>')

    # Picture
    emit_command_picture(lines, el.get('picture'), el.get('loadTransparent'), inner)

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')

    if el.get('locationInCommandBar'):
        lines.append(f'{inner}<LocationInCommandBar>{el["locationInCommandBar"]}</LocationInCommandBar>')
    emit_layout(lines, el, inner)

    # Оформление (цвета/шрифт/граница) — перед компаньоном (профиль кнопки)
    emit_appearance(lines, el, inner, 'button')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'button')

    lines.append(f'{indent}</Button>')


def emit_picture_decoration(lines, el, name, eid, indent):
    lines.append(f'{indent}<PictureDecoration name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_decoration_title(lines, el, name, inner)
    # Текст при невыбранной картинке (NonselectedPictureText) — после Title (порядок корпуса)
    if el.get('nonselectedPictureText') is not None:
        emit_mltext(lines, inner, 'NonselectedPictureText', el['nonselectedPictureText'])
    emit_common_flags(lines, el, inner)

    # Источник картинки — ТОЛЬКО src (ключ 'picture' = тип/имя элемента, не источник).
    # Префикс "abs:" → встроенная картинка <xr:Abs>; иначе именованная/стилевая <xr:Ref>.
    if el.get('src'):
        src_str = str(el['src'])
        lt = 'true' if el.get('loadTransparent') is True else 'false'
        lines.append(f'{inner}<Picture>')
        if src_str.startswith('abs:'):
            lines.append(f'{inner}\t<xr:Abs>{esc_xml(src_str[4:])}</xr:Abs>')
        else:
            lines.append(f'{inner}\t<xr:Ref>{esc_xml(src_str)}</xr:Ref>')
        lines.append(f'{inner}\t<xr:LoadTransparent>{lt}</xr:LoadTransparent>')
        tpx = el.get('transparentPixel')
        if tpx:
            lines.append(f'{inner}\t<xr:TransparentPixel x="{tpx.get("x")}" y="{tpx.get("y")}"/>')
        lines.append(f'{inner}</Picture>')

    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
    emit_layout(lines, el, inner)
    # EnableDrag — фактическое значение (декорация-картинка перетаскиваема; декомпилятор ловит generic-ом)
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')

    # Оформление (цвета/шрифт/граница) — профиль декорации (1С толерантна к порядку appearance)
    emit_appearance(lines, el, inner, 'decoration')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'picture')

    lines.append(f'{indent}</PictureDecoration>')


def emit_picture_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<PictureField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_column_pics(lines, el, inner)
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')

    emit_layout(lines, el, inner)
    # EnableDrag — фактическое значение (поле картинки перетаскиваемо; декомпилятор ловит generic-ом)
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')

    # FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
    if el.get('footerDataPath'):
        lines.append(f'{inner}<FooterDataPath>{esc_xml(str(el["footerDataPath"]))}</FooterDataPath>')
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # ValuesPicture — picture (collection) used to render the field's value.
    # Required for a Boolean-bound PictureField to actually show an icon.
    # Скаляр (Ref) или объект {src, loadTransparent}; LoadTransparent эмитится всегда.
    emit_picture_ref(lines, el.get('valuesPicture'), 'ValuesPicture', inner)
    if el.get('nonselectedPictureText') is not None:
        emit_mltext(lines, inner, 'NonselectedPictureText', el['nonselectedPictureText'])

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'picField')

    lines.append(f'{indent}</PictureField>')


def emit_simple_field(lines, el, name, eid, indent, xml_tag, type_key):
    # Спец-поля "документ/датчик" (SpreadSheet/HTML/Text/Formatted/ProgressBar/TrackBar):
    # единый скелет поля. Типоспец. enum/bool скаляры — через generic (emit_layout);
    # числовые скаляры датчиков (min/max/шаги) — без xsi:type; enableDrag — фактическое значение.
    lines.append(f'{indent}<{xml_tag} name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')
    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')

    emit_layout(lines, el, inner)

    # EnableDrag — фактическое значение (SpreadSheet; платформа эмитит явный false). enableStartDrag — через emit_layout.
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')

    # Датчики (ProgressBar/TrackBar) — числовые скаляры (без xsi:type)
    for key, tag in (('minValue', 'MinValue'), ('maxValue', 'MaxValue'), ('largeStep', 'LargeStep'), ('markingStep', 'MarkingStep'), ('step', 'Step')):
        if el.get(key) is not None:
            lines.append(f'{inner}<{tag}>{el[key]}</{tag}>')

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}КонтекстноеМеню', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, type_key)

    lines.append(f'{indent}</{xml_tag}>')


def emit_gantt_chart(lines, el, name, eid, indent):
    # GanttChartField — скелет поля + вложенная <Table> (полноценная таблица, через emit_element).
    lines.append(f'{indent}<GanttChartField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'
    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')
    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    emit_layout(lines, el, inner)
    emit_appearance(lines, el, inner, 'field')
    emit_companion_panel(lines, 'ContextMenu', f'{name}КонтекстноеМеню', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))
    # Вложенная таблица диаграммы Ганта (стандартный Table — переиспользуем emit_element)
    if el.get('ganttTable'):
        emit_element(lines, el['ganttTable'], inner)
    emit_events(lines, el, name, inner, 'ganttChart')
    lines.append(f'{indent}</GanttChartField>')


def emit_calendar(lines, el, name, eid, indent):
    lines.append(f'{indent}<CalendarField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        loc_map = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom', 'auto': 'Auto'}
        loc = loc_map.get(str(el['titleLocation']), str(el['titleLocation']))
        lines.append(f'{inner}<TitleLocation>{loc}</TitleLocation>')

    emit_layout(lines, el, inner)

    # Календарно-специфичные свойства (порядок схемы: после layout, до companions)
    if el.get('selectionMode'):
        lines.append(f'{inner}<SelectionMode>{el["selectionMode"]}</SelectionMode>')
    if el.get('showCurrentDate') is not None:
        lines.append(f'{inner}<ShowCurrentDate>{"true" if el["showCurrentDate"] else "false"}</ShowCurrentDate>')
    if el.get('widthInMonths') is not None:
        lines.append(f'{inner}<WidthInMonths>{el["widthInMonths"]}</WidthInMonths>')
    if el.get('heightInMonths') is not None:
        lines.append(f'{inner}<HeightInMonths>{el["heightInMonths"]}</HeightInMonths>')
    if el.get('showMonthsPanel') is not None:
        lines.append(f'{inner}<ShowMonthsPanel>{"true" if el["showMonthsPanel"] else "false"}</ShowMonthsPanel>')

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'calendar')

    lines.append(f'{indent}</CalendarField>')


def emit_command_bar(lines, el, name, eid, indent):
    lines.append(f'{indent}<CommandBar name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    if el.get('commandSource'):
        lines.append(f'{inner}<CommandSource>{el["commandSource"]}</CommandSource>')

    if el.get('autofill') is True:
        lines.append(f'{inner}<Autofill>true</Autofill>')

    # CommandBar хранит HorizontalLocation фактически (включая Auto); ≠ дополнениям (Auto=скип)
    if el.get('horizontalLocation'):
        _hlv = {'auto': 'Auto', 'left': 'Left', 'right': 'Right', 'center': 'Center'}.get(str(el['horizontalLocation']).lower(), str(el['horizontalLocation']))
        lines.append(f'{inner}<HorizontalLocation>{_hlv}</HorizontalLocation>')

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t', in_cmd_bar=True)
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</CommandBar>')


def emit_popup(lines, el, name, eid, indent):
    lines.append(f'{indent}<Popup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner, auto=True)
    emit_common_flags(lines, el, inner)

    # Источник команд попапа (после Title/ToolTip, перед компаньоном) — как у ButtonGroup/CommandBar
    if el.get('commandSource'):
        lines.append(f'{inner}<CommandSource>{el["commandSource"]}</CommandSource>')

    emit_command_picture(lines, el.get('picture'), el.get('loadTransparent'), inner)

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')
    emit_layout(lines, el, inner)

    # Оформление попапа (TitleTextColor / TitleFont) — перед компаньоном
    emit_appearance(lines, el, inner, 'field')

    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t', in_cmd_bar=True)
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Popup>')


def emit_button_group(lines, el, name, eid, indent):
    lines.append(f'{indent}<ButtonGroup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    if el.get('commandSource'):
        lines.append(f'{inner}<CommandSource>{el["commandSource"]}</CommandSource>')

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # Companion: ExtendedTooltip
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    # Children (кнопки в контексте командной панели)
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t', in_cmd_bar=True)
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</ButtonGroup>')


# --- Attribute emitter ---

def emit_functional_options(lines, fo, indent):
    # <FunctionalOptions><Item>FunctionalOption.X</Item>…> — у Attribute/Command/Column.
    # Forgiving: "X"/"FunctionalOption.X" → FunctionalOption.X; GUID (расширение) — как есть.
    if not fo:
        return
    lines.append(f'{indent}<FunctionalOptions>')
    for opt in fo:
        v = str(opt)
        if re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$', v):
            pass
        elif v.startswith('FunctionalOption.'):
            pass
        else:
            v = f'FunctionalOption.{v}'
        lines.append(f'{indent}\t<Item>{v}</Item>')
    lines.append(f'{indent}</FunctionalOptions>')


def emit_attr_column(lines, col, indent):
    # Колонка реквизита (ValueTable/Tree или AdditionalColumns): name/Title/Type/FunctionalOptions.
    col_id = new_id()
    lines.append(f'{indent}<Column name="{col["name"]}" id="{col_id}">')
    if col.get('title'):
        emit_mltext(lines, f'{indent}\t', 'Title', col['title'])
    emit_type(lines, str(col.get('type', '')), f'{indent}\t')
    # Проверка заполнения колонки → <FillCheck> (как у реквизита; bool true→ShowError / строка verbatim)
    cfc = col.get('fillCheck') if col.get('fillCheck') is not None else col.get('fillChecking')
    if cfc is not None:
        cfcv = ('ShowError' if cfc else None) if isinstance(cfc, bool) else str(cfc)
        if cfcv:
            lines.append(f'{indent}\t<FillCheck>{cfcv}</FillCheck>')
    emit_functional_options(lines, col.get('functionalOptions'), f'{indent}\t')
    # Ролевой доступ колонки (View/Edit) — xr-флаг, как у самого реквизита
    if col.get('view') is not None:
        emit_xr_flag(lines, 'View', col['view'], f'{indent}\t')
    if col.get('edit') is not None:
        emit_xr_flag(lines, 'Edit', col['edit'], f'{indent}\t')
    lines.append(f'{indent}</Column>')


# --- Schema-параметры динамического списка (DataCompositionSchemaParameter) ---
# Зеркало form-compile.ps1 (Emit-DLParameters). Та же сущность, что параметры СКД, но в
# форме: обёртка <Parameter> + дети dcssch:. DSL переиспользует грамматику параметров СКД.
# Контекстные дефолты: useRestriction эмитим ВСЕГДА, дефолт true (в СКД false); title — авто
# из имени; пустое value — всегда xsi:nil (даже при известном типе). Канон. порядок детей
# (по корпусу): name, title, valueType, value, useRestriction, expression, availableValue*,
# valueListAllowed, availableAsField, inputParameters, denyIncompleteValues, use.

def emit_dl_mltext(lines, indent, tag, text):
    # ML-текст с xsi:type="v8:LocalStringType" (в dcssch:* обязателен; emit_mltext его не ставит).
    lines.append(f'{indent}<{tag} xsi:type="v8:LocalStringType">')
    emit_ml_items(lines, f'{indent}\t', text)
    lines.append(f'{indent}</{tag}>')


def split_dl_valuelist_csv(s):
    result = []
    if s is None:
        return result
    items = []
    buf = []
    in_quote = None
    for ch in s:
        if in_quote:
            buf.append(ch)
            if ch == in_quote:
                in_quote = None
        elif ch in ("'", '"'):
            in_quote = ch
            buf.append(ch)
        elif ch == ',':
            items.append(''.join(buf)); buf = []
        else:
            buf.append(ch)
    if buf:
        items.append(''.join(buf))
    for raw in items:
        t = raw.strip()
        if len(t) >= 2 and ((t[0] == "'" and t[-1] == "'") or (t[0] == '"' and t[-1] == '"')):
            t = t[1:-1]
        if t != '':
            result.append(t)
    return result


def parse_dl_param_shorthand(s):
    result = {'name': '', 'type': '', 'value': None, 'title': None}
    if '@valueList' in s:
        result['valueListAllowed'] = True
        s = re.sub(r'\s*@valueList', '', s)
    if '@hidden' in s:
        result['hidden'] = True
        s = re.sub(r'\s*@hidden', '', s)
    m = re.search(r'\[([^\]]*)\]', s)
    if m:
        result['title'] = m.group(1).strip()
        s = re.sub(r'\s*\[[^\]]*\]\s*', ' ', s).strip()
    # Тип может быть СОСТАВНЫМ (A | B | C — с пробелами); значение — после '=' (тип '=' не содержит).
    m = re.match(r'^([^:]+):\s*([^=]+?)(\s*=\s*(.*))?$', s)
    if m:
        result['name'] = m.group(1).strip()
        type_raw = m.group(2).strip()
        if re.search(r'[|+]', type_raw):
            result['type'] = ' | '.join(resolve_type_str(p.strip()) for p in re.split(r'\s*[|+]\s*', type_raw))
        else:
            result['type'] = resolve_type_str(type_raw)
        if m.group(4):
            rhs = m.group(4).strip()
            items = split_dl_valuelist_csv(rhs)
            if len(items) >= 2:
                result['value'] = items
                result['valueListAllowed'] = True
            elif len(items) == 1:
                result['value'] = items[0]
            else:
                result['value'] = rhs
    else:
        result['name'] = s.strip()
    return result


def is_dl_empty_value(v):
    if v is None:
        return True
    sv = str(v).strip()
    return sv == '' or sv == '_' or sv.lower() == 'null'


def emit_dl_value(lines, type_str, val, indent, value_list_allowed=False):
    if is_dl_empty_value(val):
        # Дин-список: пустое значение платформа ВСЕГДА пишет как xsi:nil (даже при известном типе).
        if value_list_allowed:
            return
        lines.append(f'{indent}<dcssch:value xsi:nil="true"/>')
        return
    if isinstance(val, bool):
        val_str = 'true' if val else 'false'
    else:
        val_str = str(val)
    t = type_str or ''
    if re.match(r'^(date|dateTime|time)', t):
        lines.append(f'{indent}<dcssch:value xsi:type="xs:dateTime">{esc_xml(val_str)}</dcssch:value>')
    elif t == 'boolean':
        lines.append(f'{indent}<dcssch:value xsi:type="xs:boolean">{esc_xml(val_str)}</dcssch:value>')
    elif t == 'v8:Type':
        ns_attr = _value_type_ns_attr('v8:Type', val_str)
        lines.append(f'{indent}<dcssch:value{ns_attr} xsi:type="v8:Type">{esc_xml(val_str)}</dcssch:value>')
    elif re.match(r'^ent:', t):
        # системное перечисление (ent:X) — value несёт тот же xsi:type
        lines.append(f'{indent}<dcssch:value xsi:type="{t}">{esc_xml(val_str)}</dcssch:value>')
    elif re.match(r'^decimal', t):
        lines.append(f'{indent}<dcssch:value xsi:type="xs:decimal">{esc_xml(val_str)}</dcssch:value>')
    elif re.match(r'^string', t):
        lines.append(f'{indent}<dcssch:value xsi:type="xs:string">{esc_xml(val_str)}</dcssch:value>')
    elif re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef)\.', t):
        lines.append(f'{indent}<dcssch:value xsi:type="dcscor:DesignTimeValue">{esc_xml(val_str)}</dcssch:value>')
    else:
        if re.match(r'^\d{4}-\d{2}-\d{2}T', val_str):
            lines.append(f'{indent}<dcssch:value xsi:type="xs:dateTime">{esc_xml(val_str)}</dcssch:value>')
        elif val_str in ('true', 'false'):
            lines.append(f'{indent}<dcssch:value xsi:type="xs:boolean">{esc_xml(val_str)}</dcssch:value>')
        elif re.match(r'^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.', val_str) or re.match(r'^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', val_str):
            lines.append(f'{indent}<dcssch:value xsi:type="dcscor:DesignTimeValue">{esc_xml(val_str)}</dcssch:value>')
        else:
            lines.append(f'{indent}<dcssch:value xsi:type="xs:string">{esc_xml(val_str)}</dcssch:value>')


def emit_dl_value_type(lines, type_str, indent):
    if not type_str:
        return
    lines.append(f'{indent}<dcssch:valueType>')
    for part in re.split(r'\s*[|+]\s*', str(type_str)):
        emit_single_type(lines, part.strip(), f'{indent}\t')
    lines.append(f'{indent}</dcssch:valueType>')


def emit_dl_available_value(lines, av, type_str, indent):
    lines.append(f'{indent}<dcssch:availableValue>')
    av_val = av.get('value') if isinstance(av, dict) else None
    emit_dl_value(lines, type_str, av_val, f'{indent}\t', False)
    pres = (av.get('presentation') or av.get('title')) if isinstance(av, dict) else None
    if pres:
        emit_dl_mltext(lines, f'{indent}\t', 'dcssch:presentation', pres)
    lines.append(f'{indent}</dcssch:availableValue>')


def emit_dl_input_parameters(lines, ip, indent):
    if ip is None:
        return
    items = ip if isinstance(ip, list) else [ip]
    if len(items) == 0:
        return
    lines.append(f'{indent}<dcssch:inputParameters>')
    for item in items:
        lines.append(f'{indent}\t<dcscor:item>')
        if 'use' in item and item.get('use') is not None and not item.get('use'):
            lines.append(f'{indent}\t\t<dcscor:use>false</dcscor:use>')
        lines.append(f'{indent}\t\t<dcscor:parameter>{esc_xml(str(item.get("parameter", "")))}</dcscor:parameter>')
        if 'choiceParameters' in item:
            cp_items = item.get('choiceParameters') or []
            if len(cp_items) == 0:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameters"/>')
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameters">')
                for cp in cp_items:
                    lines.append(f'{indent}\t\t\t<dcscor:item>')
                    lines.append(f'{indent}\t\t\t\t<dcscor:choiceParameter>{esc_xml(str(cp.get("name", "")))}</dcscor:choiceParameter>')
                    for v in (cp.get('values') or []):
                        if isinstance(v, bool):
                            lines.append(f'{indent}\t\t\t\t<dcscor:value xsi:type="xs:boolean">{"true" if v else "false"}</dcscor:value>')
                        elif isinstance(v, (int, float)):
                            lines.append(f'{indent}\t\t\t\t<dcscor:value xsi:type="xs:decimal">{v}</dcscor:value>')
                        else:
                            lines.append(f'{indent}\t\t\t\t<dcscor:value xsi:type="dcscor:DesignTimeValue">{esc_xml(str(v))}</dcscor:value>')
                    lines.append(f'{indent}\t\t\t</dcscor:item>')
                lines.append(f'{indent}\t\t</dcscor:value>')
        elif 'choiceParameterLinks' in item:
            cpl_items = item.get('choiceParameterLinks') or []
            if len(cpl_items) == 0:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameterLinks"/>')
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:ChoiceParameterLinks">')
                for cpl in cpl_items:
                    lines.append(f'{indent}\t\t\t<dcscor:item>')
                    lines.append(f'{indent}\t\t\t\t<dcscor:choiceParameter>{esc_xml(str(cpl.get("name", "")))}</dcscor:choiceParameter>')
                    lines.append(f'{indent}\t\t\t\t<dcscor:value>{esc_xml(str(cpl.get("value", "")))}</dcscor:value>')
                    mode = str(cpl.get('mode') or 'Auto')
                    lines.append(f'{indent}\t\t\t\t<dcscor:mode xmlns:d8p1="http://v8.1c.ru/8.1/data/enterprise" xsi:type="d8p1:LinkedValueChangeMode">{mode}</dcscor:mode>')
                    lines.append(f'{indent}\t\t\t</dcscor:item>')
                lines.append(f'{indent}\t\t</dcscor:value>')
        elif 'typeLink' in item:
            # Связь по типу (dcscor:TypeLink) — field + linkItem (структурное значение параметра).
            tl = item.get('typeLink') or {}
            lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:TypeLink">')
            if tl.get('field') is not None:
                lines.append(f'{indent}\t\t\t<dcscor:field>{esc_xml(str(tl.get("field")))}</dcscor:field>')
            if tl.get('linkItem') is not None:
                lines.append(f'{indent}\t\t\t<dcscor:linkItem>{esc_xml(str(tl.get("linkItem")))}</dcscor:linkItem>')
            lines.append(f'{indent}\t\t</dcscor:value>')
        elif 'value' in item:
            val = item.get('value')
            if isinstance(val, bool):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:boolean">{"true" if val else "false"}</dcscor:value>')
            elif isinstance(val, (int, float)):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:decimal">{val}</dcscor:value>')
            elif isinstance(val, dict):
                emit_dl_mltext(lines, f'{indent}\t\t', 'dcscor:value', val)
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')
        lines.append(f'{indent}\t</dcscor:item>')
    lines.append(f'{indent}</dcssch:inputParameters>')


# ── dataParameters (значения параметров запроса в настройках компоновки) — порт из skd ──
def _test_empty_value(v):
    if v is None:
        return True
    s = str(v).strip()
    return s == '' or s == '_' or s.lower() == 'null'


def emit_empty_value(lines, type_str, indent, tag_prefix='', value_list_allowed=False):
    if value_list_allowed:
        return
    t = type_str or ''
    t_bare = t[3:] if t.startswith('xs:') else t
    pf = tag_prefix
    if t == '':
        lines.append(f'{indent}<{pf}value xsi:nil="true"/>')
    elif t == 'StandardPeriod':
        lines.append(f'{indent}<{pf}value xsi:type="v8:StandardPeriod">')
        lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">Custom</v8:variant>')
        lines.append(f'{indent}\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>')
        lines.append(f'{indent}\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>')
        lines.append(f'{indent}</{pf}value>')
    elif re.match(r'^string', t_bare):
        lines.append(f'{indent}<{pf}value xsi:type="xs:string"/>')
    elif re.match(r'^(date|time)', t_bare):
        lines.append(f'{indent}<{pf}value xsi:type="xs:dateTime">0001-01-01T00:00:00</{pf}value>')
    elif re.match(r'^decimal', t_bare):
        lines.append(f'{indent}<{pf}value xsi:type="xs:decimal">0</{pf}value>')
    elif t_bare == 'boolean':
        lines.append(f'{indent}<{pf}value xsi:type="xs:boolean">false</{pf}value>')
    else:
        lines.append(f'{indent}<{pf}value xsi:nil="true"/>')


_DP_PERIOD_VARIANTS = {"Custom","Today","ThisWeek","ThisTenDays","ThisMonth","ThisQuarter","ThisHalfYear","ThisYear","FromBeginningOfThisWeek","FromBeginningOfThisTenDays","FromBeginningOfThisMonth","FromBeginningOfThisQuarter","FromBeginningOfThisHalfYear","FromBeginningOfThisYear","LastWeek","LastTenDays","LastMonth","LastQuarter","LastHalfYear","LastYear","NextDay","NextWeek","NextTenDays","NextMonth","NextQuarter","NextHalfYear","NextYear","TillEndOfThisWeek","TillEndOfThisTenDays","TillEndOfThisMonth","TillEndOfThisQuarter","TillEndOfThisHalfYear","TillEndOfThisYear"}


def parse_data_param_shorthand(s):
    result = {'parameter': '', 'value': None, 'use': True, 'userSettingID': None, 'viewMode': None}
    if '@user' in s:
        result['userSettingID'] = 'auto'; s = re.sub(r'\s*@user', '', s)
    if '@off' in s:
        result['use'] = False; s = re.sub(r'\s*@off', '', s)
    if '@quickAccess' in s:
        result['viewMode'] = 'QuickAccess'; s = re.sub(r'\s*@quickAccess', '', s)
    if '@normal' in s:
        result['viewMode'] = 'Normal'; s = re.sub(r'\s*@normal', '', s)
    s = s.strip()
    m = re.match(r'^([^=]+)=\s*(.+)$', s)
    if m:
        result['parameter'] = m.group(1).strip()
        val_str = m.group(2).strip()
        if val_str in _DP_PERIOD_VARIANTS:
            result['value'] = {'variant': val_str}
        elif re.match(r'^\d{4}-\d{2}-\d{2}T', val_str):
            result['value'] = val_str
        elif val_str in ('true', 'false'):
            result['value'] = (val_str == 'true')
        else:
            result['value'] = val_str
    else:
        result['parameter'] = s
    return result


def emit_data_parameters(lines, items, indent, block_view_mode=None):
    if not items or len(items) == 0:
        return
    lines.append(f'{indent}<dcsset:dataParameters>')
    for dp in items:
        if isinstance(dp, str):
            parsed = parse_data_param_shorthand(dp)
            dp = {'parameter': parsed['parameter']}
            if parsed['value'] is not None:
                dp['value'] = parsed['value']
            if parsed['use'] is False:
                dp['use'] = False
            if parsed['userSettingID']:
                dp['userSettingID'] = parsed['userSettingID']
            if parsed['viewMode']:
                dp['viewMode'] = parsed['viewMode']
        lines.append(f'{indent}\t<dcscor:item xsi:type="dcsset:SettingsParameterValue">')
        if dp.get('use') is False:
            lines.append(f'{indent}\t\t<dcscor:use>false</dcscor:use>')
        lines.append(f'{indent}\t\t<dcscor:parameter>{esc_xml(str(dp.get("parameter", "")))}</dcscor:parameter>')
        vtype = str(dp.get('valueType') or '')
        val = dp.get('value')
        if isinstance(val, list):
            # Список значений параметра (valueListAllowed) — отдельный <dcscor:value> на каждое.
            avtype = str(dp.get('valueType', ''))
            for v in val:
                v_str = ('true' if v else 'false') if isinstance(v, bool) else str(v)
                if re.match(r'^[a-zA-Z]+:', avtype):
                    lines.append(f'{indent}\t\t<dcscor:value xsi:type="{avtype}">{esc_xml(v_str)}</dcscor:value>')
                elif re.match(r'^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.', v_str) or re.match(r'^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', v_str):
                    lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:DesignTimeValue">{esc_xml(v_str)}</dcscor:value>')
                else:
                    lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(v_str)}</dcscor:value>')
        elif dp.get('nilValue') is True:
            lines.append(f'{indent}\t\t<dcscor:value xsi:nil="true"/>')
        elif _test_empty_value(val) and vtype:
            emit_empty_value(lines, vtype, f'{indent}\t\t', tag_prefix='dcscor:', value_list_allowed=False)
        elif _test_empty_value(val):
            pass  # нет значения → не эмитим value-узел (form дин-список: use=false плейсхолдер)
        elif val is not None:
            if isinstance(val, dict) and val.get('variant'):
                variant = str(val.get('variant'))
                has_date = 'date' in val
                has_sd = 'startDate' in val
                is_sbd = has_date or (not has_sd and variant.startswith('BeginningOf'))
                if is_sbd:
                    lines.append(f'{indent}\t\t<dcscor:value xsi:type="v8:StandardBeginningDate">')
                    lines.append(f'{indent}\t\t\t<v8:variant xsi:type="v8:StandardBeginningDateVariant">{esc_xml(variant)}</v8:variant>')
                    if variant == 'Custom':
                        d = str(val.get('date') or '0001-01-01T00:00:00')
                        lines.append(f'{indent}\t\t\t<v8:date>{esc_xml(d)}</v8:date>')
                    lines.append(f'{indent}\t\t</dcscor:value>')
                else:
                    lines.append(f'{indent}\t\t<dcscor:value xsi:type="v8:StandardPeriod">')
                    lines.append(f'{indent}\t\t\t<v8:variant xsi:type="v8:StandardPeriodVariant">{esc_xml(variant)}</v8:variant>')
                    if variant == 'Custom':
                        sd = str(val.get('startDate') or '0001-01-01T00:00:00')
                        ed = str(val.get('endDate') or '0001-01-01T00:00:00')
                        lines.append(f'{indent}\t\t\t<v8:startDate>{esc_xml(sd)}</v8:startDate>')
                        lines.append(f'{indent}\t\t\t<v8:endDate>{esc_xml(ed)}</v8:endDate>')
                    lines.append(f'{indent}\t\t</dcscor:value>')
            elif re.match(r'^[a-zA-Z]+:', vtype):
                v_str = str(val).lower() if isinstance(val, bool) else str(val)
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="{vtype}">{esc_xml(v_str)}</dcscor:value>')
            elif vtype == 'boolean' or isinstance(val, bool):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:boolean">{esc_xml(str(val).lower())}</dcscor:value>')
            elif re.match(r'^date', vtype) or re.match(r'^\d{4}-\d{2}-\d{2}T', str(val)):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:dateTime">{esc_xml(str(val))}</dcscor:value>')
            elif re.match(r'^decimal', vtype):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:decimal">{esc_xml(str(val))}</dcscor:value>')
            elif re.match(r'^string', vtype):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')
            elif re.match(r'^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.', str(val)) or re.match(r'^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', str(val)):
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="dcscor:DesignTimeValue">{esc_xml(str(val))}</dcscor:value>')
            else:
                lines.append(f'{indent}\t\t<dcscor:value xsi:type="xs:string">{esc_xml(str(val))}</dcscor:value>')
        if dp.get('viewMode'):
            lines.append(f'{indent}\t\t<dcsset:viewMode>{esc_xml(str(dp["viewMode"]))}</dcsset:viewMode>')
        if dp.get('userSettingID'):
            uid = new_uuid() if str(dp['userSettingID']) == 'auto' else str(dp['userSettingID'])
            lines.append(f'{indent}\t\t<dcsset:userSettingID>{esc_xml(uid)}</dcsset:userSettingID>')
        if dp.get('userSettingPresentation'):
            emit_us_presentation(lines, f'{indent}\t\t', 'dcsset:userSettingPresentation', dp['userSettingPresentation'])
        lines.append(f'{indent}\t</dcscor:item>')
    if block_view_mode is not None:
        lines.append(f'{indent}\t<dcsset:viewMode>{esc_xml(str(block_view_mode))}</dcsset:viewMode>')
    lines.append(f'{indent}</dcsset:dataParameters>')


def emit_dl_parameter(lines, p, parsed, indent):
    is_obj = not isinstance(p, str)
    lines.append(f'{indent}<Parameter>')
    ci = f'{indent}\t'
    lines.append(f'{ci}<dcssch:name>{esc_xml(parsed["name"])}</dcssch:name>')
    # Title: явный override (shorthand [..] / объект title/presentation) или авто из имени.
    title = None
    if parsed.get('title'):
        title = parsed['title']
    elif is_obj and p.get('title'):
        title = p['title']
    elif is_obj and p.get('presentation'):
        title = p['presentation']
    if title is None or (isinstance(title, str) and title == ''):
        title = title_from_name(parsed['name'])
    emit_dl_mltext(lines, ci, 'dcssch:title', title)
    # valueType
    if parsed.get('type'):
        emit_dl_value_type(lines, parsed['type'], ci)
    # value (дефолт nil; при valueListAllowed пустое — опускаем)
    vla = bool(parsed.get('valueListAllowed'))
    pv = parsed.get('value')
    if isinstance(pv, list):
        for v in pv:
            emit_dl_value(lines, parsed.get('type', ''), v, ci, False)
    elif parsed.get('value_explicit') and pv is not None and str(pv) == '' and (str(parsed.get('type', '')) == '' or re.match(r'^string', str(parsed.get('type', '')))):
        # Явный пустой СТРОКОВЫЙ параметр (value:"" от декомпилятора) → типизированный пустой
        # <dcssch:value xsi:type="xs:string"/>, НЕ nil. Решается ФОРМОЙ value (""→typed-empty,
        # null/отсутствие→nil), независимо от valueListAllowed; декомпилятор различает ""/null.
        # Корпус: 26 xs:string typed-empty.
        lines.append(f'{ci}<dcssch:value xsi:type="xs:string"/>')
    elif vla and is_dl_empty_value(pv) and parsed.get('value_explicit'):
        # valueListAllowed + явный пустой (value:null от декомпилятора) → платформа пишет nil
        lines.append(f'{ci}<dcssch:value xsi:nil="true"/>')
    else:
        emit_dl_value(lines, parsed.get('type', ''), pv, ci, vla)
    # useRestriction — ВСЕГДА; дефолт true; false только при явном useRestriction:false.
    ur = True
    if is_obj and 'useRestriction' in p:
        ur = bool(p['useRestriction'])
    lines.append(f'{ci}<dcssch:useRestriction>{"true" if ur else "false"}</dcssch:useRestriction>')
    # expression
    expr = str(p['expression']) if (is_obj and p.get('expression')) else None
    if expr:
        lines.append(f'{ci}<dcssch:expression>{esc_xml(expr)}</dcssch:expression>')
    # availableValues
    if is_obj and p.get('availableValues'):
        for av in p['availableValues']:
            emit_dl_available_value(lines, av, parsed.get('type', ''), ci)
    # valueListAllowed
    if vla:
        lines.append(f'{ci}<dcssch:valueListAllowed>true</dcssch:valueListAllowed>')
    # availableAsField=false (hidden или явный)
    aaf = None
    if parsed.get('hidden') is True:
        aaf = False
    if is_obj and 'availableAsField' in p:
        aaf = bool(p['availableAsField'])
    if aaf is False:
        lines.append(f'{ci}<dcssch:availableAsField>false</dcssch:availableAsField>')
    # inputParameters
    if is_obj and p.get('inputParameters'):
        emit_dl_input_parameters(lines, p['inputParameters'], ci)
    # denyIncompleteValues
    if is_obj and p.get('denyIncompleteValues') is True:
        lines.append(f'{ci}<dcssch:denyIncompleteValues>true</dcssch:denyIncompleteValues>')
    # use
    if is_obj and p.get('use'):
        lines.append(f'{ci}<dcssch:use>{esc_xml(str(p["use"]))}</dcssch:use>')
    lines.append(f'{indent}</Parameter>')


def emit_dl_parameters(lines, params, indent):
    if not params:
        return
    for p in params:
        if isinstance(p, str):
            parsed = parse_dl_param_shorthand(p)
        else:
            resolved_type = ''
            if p.get('type'):
                if isinstance(p['type'], list):
                    resolved_type = ' | '.join(resolve_type_str(str(x)) for x in p['type'])
                else:
                    resolved_type = resolve_type_str(str(p['type']))
            elif p.get('valueType'):
                resolved_type = resolve_type_str(str(p['valueType']))
            parsed = {'name': str(p.get('name', '')), 'type': resolved_type,
                      'value': p.get('value') if 'value' in p else None,
                      'value_explicit': ('value' in p), 'title': None}
            if p.get('valueListAllowed') is True:
                parsed['valueListAllowed'] = True
            if p.get('hidden') is True:
                parsed['hidden'] = True
        emit_dl_parameter(lines, p, parsed, indent)


def emit_attributes(lines, attrs, indent, conditional_appearance=None):
    has_ca = bool(conditional_appearance) and len(conditional_appearance) > 0
    # Платформа ВСЕГДА эмитит <Attributes> (100% корпуса; 162 формы — пустой <Attributes/>).
    if (not attrs or len(attrs) == 0) and not has_ca:
        lines.append(f'{indent}<Attributes/>')
        return
    if not attrs or len(attrs) == 0:
        # Нет реквизитов, но есть условное оформление (последний child <Attributes>)
        lines.append(f'{indent}<Attributes>')
        emit_conditional_appearance(lines, conditional_appearance, f'{indent}\t', wrap_tag='ConditionalAppearance')
        lines.append(f'{indent}</Attributes>')
        return

    lines.append(f'{indent}<Attributes>')
    seen_attrs = set()
    for attr in attrs:
        attr_id = new_id()
        attr_name = str(attr['name'])
        _ensure_unique(attr_name, seen_attrs, 'attribute')

        lines.append(f'{indent}\t<Attribute name="{attr_name}" id="{attr_id}">')
        inner = f'{indent}\t\t'

        # Title атрибута (зеркало emit_title): нет ключа → авто-вывод из имени (кроме main);
        # title "" → подавить; непустой → эмитить как есть.
        if 'title' in attr:
            if attr.get('title'):
                emit_mltext(lines, inner, 'Title', attr['title'])
        elif attr.get('main') is not True:
            emit_mltext(lines, inner, 'Title', title_from_name(attr_name))

        # Type
        if attr.get('type'):
            emit_type(lines, str(attr['type']), inner)
        else:
            lines.append(f'{inner}<Type/>')
        # valueType: ОписаниеТипов значений ValueList → <Settings xsi:type="v8:TypeDescription">
        # (та же грамматика типа, включая составной "A | B"). Forgiving-синонимы.
        # Три состояния: нет ключа → нет Settings; "" → пустой <Settings…/>; тип → с типом.
        vt_spec = None
        has_vt = False
        for k in ('valueType', 'typeDescription', 'описаниеТипов', 'типЗначений'):
            if k in attr:
                vt_spec = attr[k]
                has_vt = True
                break
        if has_vt:
            emit_type(lines, '' if vt_spec is None else str(vt_spec), inner, tag="Settings", tag_attrs=' xsi:type="v8:TypeDescription"')
        # Planner design-time <Settings xsi:type="pl:Planner"> (встроенный конфиг планировщика).
        if attr.get('planner') is not None:
            emit_planner_settings(lines, attr['planner'], inner)
        # Chart/GanttChart design-time <Settings> (тип выводится из типа реквизита).
        if attr.get('chart') is not None:
            ctype = 'd4p1:GanttChart' if 'GanttChart' in str(attr.get('type', '')) else 'd4p1:Chart'
            emit_chart_settings(lines, attr['chart'], inner, ctype)

        if attr.get('main') is True:
            lines.append(f'{inner}<MainAttribute>true</MainAttribute>')
        # Доступ по ролям: просмотр/редактирование (порядок схемы: View → Edit, после MainAttribute)
        if attr.get('view') is not None:
            emit_xr_flag(lines, 'View', attr.get('view'), inner)
        if attr.get('edit') is not None:
            emit_xr_flag(lines, 'Edit', attr.get('edit'), inner)
        main_saved = False
        if attr.get('main') is True and attr.get('type'):
            t = str(attr['type'])
            main_saved = bool(re.match(r'^(CatalogObject|DocumentObject|ChartOfAccountsObject|ChartOfCalculationTypesObject|ChartOfCharacteristicTypesObject|ExchangePlanObject|BusinessProcessObject|TaskObject)\.', t)) or ('RecordManager.' in t)
        # Явный ключ savedData побеждает (в т.ч. False → суппресс авто-вывода main_saved); нет ключа → авто.
        emit_saved = (attr['savedData'] is True) if 'savedData' in attr else main_saved
        if emit_saved:
            lines.append(f'{inner}<SavedData>true</SavedData>')
        # Save: сохранение значения реквизита в пользовательских настройках. true → <Field>имя</Field>;
        # строка/массив → под-поля с авто-префиксом "имя." (путь с точкой / UUID / =имя — как есть).
        # Нет ключа или false → не эмитим.
        if 'save' in attr and attr['save'] is not None:
            save_fields = []
            sv = attr['save']
            if isinstance(sv, bool):
                if sv:
                    save_fields.append(attr_name)
            else:
                for e in (sv if isinstance(sv, (list, tuple)) else [sv]):
                    fld = str(e)
                    if not fld:
                        continue
                    if fld != attr_name and '.' not in fld and not re.match(r'^\d+/\d+', fld):
                        fld = f'{attr_name}.{fld}'
                    if fld not in save_fields:
                        save_fields.append(fld)
            if save_fields:
                lines.append(f'{inner}<Save>')
                for f in save_fields:
                    lines.append(f'{inner}\t<Field>{esc_xml(f)}</Field>')
                lines.append(f'{inner}</Save>')
        # Проверка заполнения → <FillCheck> (реальный тег; <FillChecking> в схеме нет).
        # bool true → ShowError; строка → verbatim. Синоним fillChecking.
        fc_raw = attr['fillCheck'] if 'fillCheck' in attr else attr.get('fillChecking')
        if fc_raw:
            fcv = 'ShowError' if isinstance(fc_raw, bool) else str(fc_raw)
            lines.append(f'{inner}<FillCheck>{fcv}</FillCheck>')

        # UseAlways: поля, всегда читаемые. Две формы DSL сливаются:
        #  attr.useAlways[] (короткие имена) + columns с useAlways:true → <Field>ИмяРеквизита.Поле</Field>.
        ua_fields = []
        for e in (attr.get('useAlways') or []):
            fld = str(e)
            # Префикс "ИмяРеквизита." добавляем к коротким именам. Поля дин-списка с маркером "~"
            # (query-поля, ~13% корпуса) — префикс ставится ПОСЛЕ "~": ~Остановлен → ~Список.Остановлен.
            # Полная форма (~Список.Остановлен / Список.Остановлен) — verbatim (forgiving ввод).
            if fld.startswith('~'):
                bare = fld[1:]
                if not re.match(r'^' + re.escape(attr_name) + r'\.', bare):
                    bare = f'{attr_name}.{bare}'
                fld = f'~{bare}'
            elif not re.match(r'^' + re.escape(attr_name) + r'\.', fld) and not re.match(r'^\d+/\d+', fld):
                # UUID-ссылка (1/0:GUID) — НЕ префиксуем (платформа хранит её без "имя.")
                fld = f'{attr_name}.{fld}'
            if fld not in ua_fields:
                ua_fields.append(fld)
        for col in (attr.get('columns') or []):
            if col.get('useAlways') is True:
                fld = f'{attr_name}.{col["name"]}'
                if fld not in ua_fields:
                    ua_fields.append(fld)
        if ua_fields:
            lines.append(f'{inner}<UseAlways>')
            for f in ua_fields:
                lines.append(f'{inner}\t<Field>{f}</Field>')
            lines.append(f'{inner}</UseAlways>')

        emit_functional_options(lines, attr.get('functionalOptions'), inner)

        # Columns: прямые <Column> + <AdditionalColumns table="X"> (доп. колонки табличных частей объекта).
        # Прямые сначала, затем AdditionalColumns-группы. Для дин-списка (settings) прямые НЕ эмитим.
        has_direct_cols = bool(attr.get('columns')) and len(attr['columns']) > 0 and not attr.get('settings')
        has_add_cols = bool(attr.get('additionalColumns')) and len(attr['additionalColumns']) > 0
        if has_direct_cols or has_add_cols:
            lines.append(f'{inner}<Columns>')
            if has_direct_cols:
                seen_cols = set()  # колонки уникальны в пределах своего реквизита
                for col in attr['columns']:
                    _ensure_unique(str(col['name']), seen_cols, f"column of '{attr_name}'")
                    emit_attr_column(lines, col, f'{inner}\t')
            if has_add_cols:
                for ac in attr['additionalColumns']:
                    ac_cols = ac.get('columns') or []
                    if not ac_cols:
                        # Пустая группа доп.колонок (table-ref без колонок) → self-closing (как платформа)
                        lines.append(f'{inner}\t<AdditionalColumns table="{ac["table"]}"/>')
                        continue
                    lines.append(f'{inner}\t<AdditionalColumns table="{ac["table"]}">')
                    seen_ac_cols = set()  # уникальность в пределах группы AdditionalColumns
                    for col in ac_cols:
                        _ensure_unique(str(col['name']), seen_ac_cols, f"column of '{attr_name}'")
                        emit_attr_column(lines, col, f'{inner}\t\t')
                    lines.append(f'{inner}\t</AdditionalColumns>')
            lines.append(f'{inner}</Columns>')

        # Settings (динамический список)
        if attr.get('settings'):
            s = attr['settings']
            lines.append(f'{inner}<Settings xsi:type="DynamicList">')
            si = f'{inner}\t'
            # Порядок платформы: AutoFillAvailableFields, ManualQuery, DynamicDataRead, QueryText, Field*, MainTable, ListSettings
            # AutoFillAvailableFields — дефолт true; эмитим только при заданном ключе (отклонение).
            if s.get('autoFillAvailableFields') is not None:
                lines.append(f'{si}<AutoFillAvailableFields>{"true" if s["autoFillAvailableFields"] else "false"}</AutoFillAvailableFields>')
            # Порядок платформы: ManualQuery, DynamicDataRead, QueryText, Field*, MainTable, ListSettings
            has_query = bool(s.get('query') and str(s['query']).strip())
            # Явный ключ manualQuery (в т.ч. False) ПОБЕЖДАЕТ эвристику has_query (платформа изредка
            # хранит QueryText при ManualQuery=false — декомпилятор фиксирует отклонение).
            if s.get('manualQuery') is not None:
                mq = 'true' if s['manualQuery'] else 'false'
            else:
                mq = 'true' if has_query else 'false'
            lines.append(f'{si}<ManualQuery>{mq}</ManualQuery>')
            # DynamicDataRead: дефолт true; false только при явном отключении
            ddr = 'false' if s.get('dynamicDataRead') is False else 'true'
            lines.append(f'{si}<DynamicDataRead>{ddr}</DynamicDataRead>')
            if has_query:
                qtext = resolve_query_value(str(s['query']), QUERY_BASE_DIR)
                lines.append(f'{si}<QueryText>{esc_xml(qtext)}</QueryText>')
            # Явные поля набора (редко): override title/dataPath
            if s.get('fields'):
                for fld in s['fields']:
                    # Тип поля набора: DataSetFieldField (дефолт) vs DataSetFieldNestedDataSet
                    # (поле-вложенный набор = реквизит табличной части; маркер nested).
                    # folder = папка-группировка полей (DataSetFieldFolder, без <field>); nested = вложенный набор.
                    is_folder = bool(fld.get('folder'))
                    ftype = 'DataSetFieldNestedDataSet' if fld.get('nested') else ('DataSetFieldFolder' if is_folder else 'DataSetFieldField')
                    lines.append(f'{si}<Field xsi:type="dcssch:{ftype}">')
                    # dataPath: явный (включая "" → self-closing) побеждает; иначе fallback на field.
                    if fld.get('dataPath') is not None:
                        dp = str(fld.get('dataPath'))
                    elif is_folder:
                        dp = ''
                    else:
                        dp = str(fld.get('field', ''))
                    if dp == '':
                        lines.append(f'{si}\t<dcssch:dataPath/>')
                    else:
                        lines.append(f'{si}\t<dcssch:dataPath>{esc_xml(dp)}</dcssch:dataPath>')
                    if not is_folder:
                        lines.append(f'{si}\t<dcssch:field>{esc_xml(str(fld.get("field", "")))}</dcssch:field>')
                    if fld.get('title'):
                        lines.append(f'{si}\t<dcssch:title xsi:type="v8:LocalStringType">')
                        emit_ml_items(lines, f'{si}\t\t', fld['title'])
                        lines.append(f'{si}\t</dcssch:title>')
                    # Ограничения использования поля — после title, перед presentationExpression
                    emit_restrict_block(lines, 'useRestriction', fld.get('useRestriction'), f'{si}\t')
                    emit_restrict_block(lines, 'attributeUseRestriction', fld.get('attributeUseRestriction'), f'{si}\t')
                    # presentationExpression поля — перед valueType (порядок исходника)
                    if fld.get('presentationExpression'):
                        lines.append(f'{si}\t<dcssch:presentationExpression>{esc_xml(str(fld["presentationExpression"]))}</dcssch:presentationExpression>')
                    # valueType поля набора (тип значения; вычисляемые/кастомные поля)
                    if fld.get('valueType'):
                        emit_dl_value_type(lines, fld['valueType'], f'{si}\t')
                    # appearance поля (формат/оформление) — после valueType (порядок исходника)
                    if fld.get('appearance'):
                        lines.append(f'{si}\t<dcssch:appearance>')
                        for ak, av in fld['appearance'].items():
                            emit_appearance_value(lines, ak, av, f'{si}\t\t')
                        lines.append(f'{si}\t</dcssch:appearance>')
                    # inputParameters поля (связь по параметрам выбора) — в конце
                    if fld.get('inputParameters'):
                        emit_dl_input_parameters(lines, fld['inputParameters'], f'{si}\t')
                    lines.append(f'{si}</Field>')
            # Вычисляемые поля DataSet (<CalculatedField>) — после Field*, до Parameter*.
            emit_calc_fields(lines, s.get('calculatedFields'), si)
            # Schema-параметры дин-списка (DataCompositionSchemaParameter) — после Field*, до MainTable.
            emit_dl_parameters(lines, s.get('parameters'), si)
            # Ключ набора (query-based список без MainTable): KeyType (RowNumber/FieldValue/RowKey)
            # + KeyField* — после Parameter*, до MainTable. Захват/эмит факт. значений.
            if s.get('keyType'):
                lines.append(f'{si}<KeyType>{esc_xml(str(s["keyType"]))}</KeyType>')
            if s.get('keyFields'):
                for kf in s['keyFields']:
                    lines.append(f'{si}<KeyField>{esc_xml(str(kf))}</KeyField>')
            if s.get('mainTable'):
                lines.append(f'{si}<MainTable>{normalize_meta_type_ref(str(s["mainTable"]))}</MainTable>')
            # GetInvisibleFieldPresentations — после MainTable (дефолт true; эмитим только при заданном ключе = отклонении false).
            if s.get('getInvisibleFieldPresentations') is not None:
                lines.append(f'{si}<GetInvisibleFieldPresentations>{"true" if s["getInvisibleFieldPresentations"] else "false"}</GetInvisibleFieldPresentations>')
            # AutoSaveUserSettings — после MainTable (дефолт true; эмитим только при заданном ключе = отклонении).
            if s.get('autoSaveUserSettings') is not None:
                lines.append(f'{si}<AutoSaveUserSettings>{"true" if s["autoSaveUserSettings"] else "false"}</AutoSaveUserSettings>')
            # ListSettings: filter/order/conditionalAppearance (skd-грамматика) + каноничные блок-GUID.
            # Нет items → контейнеры всё равно эмитятся (blockMeta) = каноничный пустой скелет платформы.
            lsi = f'{si}\t'
            lines.append(f'{si}<ListSettings>')
            ls_open_idx = len(lines) - 1  # для self-closing, если внутри ничего не эмитнётся
            ls_shape = s.get('listSettings')
            if ls_shape is not None:
                # Частичная/минимальная форма скелета — эмитим ТОЛЬКО указанные части с их блок-метой.
                for tag, pv in ls_shape.items():
                    # Значение дескриптора: строка-код "vu" ИЛИ объект {meta, presentation}
                    # (контейнер несёт собственный userSettingPresentation — подпись настройки).
                    if isinstance(pv, dict):
                        meta = str(pv.get('meta', '')); bpres = pv.get('presentation')
                    else:
                        meta = str(pv); bpres = None
                    bvm = 'Normal' if 'v' in meta else None
                    if tag == 'filter':
                        bus = CANON_FILTER_ID if 'u' in meta else None
                        emit_filter(lines, s.get('filter'), lsi, block_view_mode=bvm, block_user_setting_id=bus, block_user_setting_presentation=bpres)
                    elif tag == 'order':
                        bus = CANON_ORDER_ID if 'u' in meta else None
                        emit_order(lines, s.get('order'), lsi, block_view_mode=bvm, block_user_setting_id=bus, block_user_setting_presentation=bpres)
                    elif tag == 'conditionalAppearance':
                        bus = CANON_CA_ID if 'u' in meta else None
                        emit_conditional_appearance(lines, s.get('conditionalAppearance'), lsi, block_view_mode=bvm, block_user_setting_id=bus, block_user_setting_presentation=bpres)
                    elif tag == 'itemsViewMode':
                        lines.append(f'{lsi}<dcsset:itemsViewMode>Normal</dcsset:itemsViewMode>')
                    elif tag == 'itemsUserSettingID':
                        lines.append(f'{lsi}<dcsset:itemsUserSettingID>{CANON_ITEMS_ID}</dcsset:itemsUserSettingID>')
                    elif tag == 'itemsUserSettingPresentation':
                        emit_us_presentation(lines, lsi, 'dcsset:itemsUserSettingPresentation', pv)
                    elif tag == 'dataParameters':
                        emit_data_parameters(lines, s.get('dataParameters'), lsi)
                    elif tag == 'structure':
                        emit_list_grouping(lines, get_list_grouping_value(s), lsi)
            else:
                # Полный каноничный скелет (умолчание, ~93% форм) — без изменений.
                emit_filter(lines, s.get('filter'), lsi, block_view_mode='Normal', block_user_setting_id=CANON_FILTER_ID)
                # dataParameters — после filter, до order (XSD-порядок ListSettings)
                if 'dataParameters' in s:
                    emit_data_parameters(lines, s.get('dataParameters'), lsi)
                emit_order(lines, s.get('order'), lsi, block_view_mode='Normal', block_user_setting_id=CANON_ORDER_ID)
                emit_conditional_appearance(lines, s.get('conditionalAppearance'), lsi, block_view_mode='Normal', block_user_setting_id=CANON_CA_ID)
                # Группировка строк списка (авторинг без round-trip дескриптора) — после CA, до itemsViewMode
                emit_list_grouping(lines, get_list_grouping_value(s), lsi)
                lines.append(f'{lsi}<dcsset:itemsViewMode>Normal</dcsset:itemsViewMode>')
                lines.append(f'{lsi}<dcsset:itemsUserSettingID>{CANON_ITEMS_ID}</dcsset:itemsUserSettingID>')
            if len(lines) - 1 == ls_open_idx:
                # Пустой дескриптор listSettings:{} (оригинал = <ListSettings/>) → зеркалим self-closing.
                lines[ls_open_idx] = f'{si}<ListSettings/>'
            else:
                lines.append(f'{si}</ListSettings>')
            lines.append(f'{inner}</Settings>')

        lines.append(f'{indent}\t</Attribute>')
    # Условное оформление формы — последний child <Attributes> (та же DCS-грамматика, что settings CA)
    emit_conditional_appearance(lines, conditional_appearance, f'{indent}\t', wrap_tag='ConditionalAppearance')
    lines.append(f'{indent}</Attributes>')


# --- Parameter emitter ---

def emit_parameters(lines, params, indent):
    if not params or len(params) == 0:
        return

    lines.append(f'{indent}<Parameters>')
    seen_params = set()
    for param in params:
        _ensure_unique(str(param['name']), seen_params, 'parameter')
        lines.append(f'{indent}\t<Parameter name="{param["name"]}">')
        inner = f'{indent}\t\t'

        emit_type(lines, str(param.get('type', '')), inner)

        if param.get('key') is True:
            lines.append(f'{inner}<KeyParameter>true</KeyParameter>')

        lines.append(f'{indent}\t</Parameter>')
    lines.append(f'{indent}</Parameters>')


# --- Command emitter ---

def emit_commands(lines, cmds, indent):
    if not cmds or len(cmds) == 0:
        return

    lines.append(f'{indent}<Commands>')
    seen_cmds = set()
    for cmd in cmds:
        cmd_id = new_id()
        _ensure_unique(str(cmd['name']), seen_cmds, 'command')
        lines.append(f'{indent}\t<Command name="{cmd["name"]}" id="{cmd_id}">')
        inner = f'{indent}\t\t'

        # Заголовок команды (зеркало emit_title): ключ есть+непустой → эмитим; ключ есть+"" → суппресс
        # (в оригинале <Title> нет — не додумывать); ключ отсутствует → авто-вывод из имени.
        if 'title' in cmd:
            if cmd['title']:
                emit_mltext(lines, inner, 'Title', cmd['title'])
        else:
            cmd_title = title_from_name(str(cmd['name']))
            if cmd_title:
                emit_mltext(lines, inner, 'Title', cmd_title)

        if cmd.get('tooltip'):
            emit_mltext(lines, inner, 'ToolTip', cmd['tooltip'])

        # Доступность команды по ролям (после ToolTip, до Action)
        if cmd.get('use') is not None:
            emit_xr_flag(lines, 'Use', cmd.get('use'), inner)

        if cmd.get('action'):
            lines.append(f'{inner}<Action>{cmd["action"]}</Action>')

        if cmd.get('modifiesSavedData') is True:
            lines.append(f'{inner}<ModifiesSavedData>true</ModifiesSavedData>')

        emit_functional_options(lines, cmd.get('functionalOptions'), inner)

        if cmd.get('currentRowUse'):
            lines.append(f'{inner}<CurrentRowUse>{cmd["currentRowUse"]}</CurrentRowUse>')

        # Используемая таблица — имя элемента-таблицы (xsi:type обязателен).
        # Forgiving-ключи: table / associatedTableElementId (XML-тег) / ИспользуемаяТаблица (рус., регистр-незав.)
        _cmd_norm = {k.replace(' ', '').lower(): v for k, v in cmd.items()}
        cmd_table = (_cmd_norm.get('table') or _cmd_norm.get('associatedtableelementid')
                     or _cmd_norm.get('используемаятаблица'))
        if cmd_table:
            lines.append(f'{inner}<AssociatedTableElementId xsi:type="xs:string">{esc_xml(str(cmd_table))}</AssociatedTableElementId>')

        if cmd.get('shortcut'):
            lines.append(f'{inner}<Shortcut>{cmd["shortcut"]}</Shortcut>')

        emit_command_picture(lines, cmd.get('picture'), cmd.get('loadTransparent'), inner)

        if cmd.get('representation'):
            lines.append(f'{inner}<Representation>{cmd["representation"]}</Representation>')

        lines.append(f'{indent}\t</Command>')
    lines.append(f'{indent}</Commands>')


# Командный интерфейс формы (<CommandInterface>): панели CommandBar + NavigationPanel.
# Элемент: строка (голый command, Type=Auto) или dict. Порядок тегов:
# Command, Type(деф. Auto), Attribute, CommandGroup, Index, DefaultVisible, Visible(xr-flag).
def _resolve_command_group_key(key, panel_tag):
    """Ключ-группа древовидной формы → CommandGroup (зависит от панели); иначе verbatim."""
    k = re.sub(r'\s', '', str(key)).lower()
    if panel_tag == 'NavigationPanel':
        m = {'important': 'FormNavigationPanelImportant', 'важное': 'FormNavigationPanelImportant',
             'goto': 'FormNavigationPanelGoTo', 'перейти': 'FormNavigationPanelGoTo',
             'seealso': 'FormNavigationPanelSeeAlso', 'смтакже': 'FormNavigationPanelSeeAlso'}
    else:
        m = {'important': 'FormCommandBarImportant', 'важное': 'FormCommandBarImportant',
             'createbasedon': 'FormCommandBarCreateBasedOn', 'создатьнаосновании': 'FormCommandBarCreateBasedOn'}
    return m.get(k, key)


def emit_command_interface(lines, ci, indent):
    if not ci:
        return
    inner = f'{indent}\t'
    panels = [
        ('CommandBar', ('commandBar', 'команднаяПанель', 'КоманднаяПанель')),
        ('NavigationPanel', ('navigationPanel', 'панельНавигации', 'ПанельНавигации')),
    ]
    present = []
    for tag, syns in panels:
        items = None
        for syn in syns:
            if isinstance(ci, dict) and syn in ci:
                items = ci[syn]
                break
        if items is not None:
            present.append((tag, items))
    if not present:
        return
    lines.append(f'{indent}<CommandInterface>')
    for tag, items in present:
        lines.append(f'{inner}<{tag}>')
        # Нормализация: плоский список пар (элемент, group-из-дерева). dict → древовидная форма.
        flat = []
        if isinstance(items, dict):
            for gkey, gitems in items.items():
                grp_tree = _resolve_command_group_key(gkey, tag)
                for it in gitems:
                    flat.append((it, grp_tree))
        else:
            for it in items:
                flat.append((it, None))
        for item, tree_group in flat:
            if isinstance(item, str):
                cmd, typ, attr, grp, idx, dv, vis = item, 'Auto', None, None, None, None, None
            else:
                cmd = get_el_prop(item, ('command', 'команда'))
                typ = get_el_prop(item, ('type', 'тип')) or 'Auto'
                attr = get_el_prop(item, ('attribute', 'реквизит'))
                grp = get_el_prop(item, ('group', 'группа', 'группаКоманд'))
                idx = get_el_prop(item, ('index', 'индекс'))
                dv = get_el_prop(item, ('defaultVisible', 'видимость', 'видимостьПоУмолчанию'))
                vis = get_el_prop(item, ('visible', 'видимостьПоРолям', 'настройкаВидимости'))
            # group из дерева побеждает (если задан и непустой); явный group элемента — фолбэк
            if tree_group:
                grp = tree_group
            lines.append(f'{inner}\t<Item>')
            lines.append(f'{inner}\t\t<Command>{esc_xml(str(cmd))}</Command>')
            lines.append(f'{inner}\t\t<Type>{typ}</Type>')
            if attr:
                lines.append(f'{inner}\t\t<Attribute>{esc_xml(str(attr))}</Attribute>')
            if grp:
                lines.append(f'{inner}\t\t<CommandGroup>{esc_xml(str(grp))}</CommandGroup>')
            if idx is not None:
                lines.append(f'{inner}\t\t<Index>{idx}</Index>')
            if dv is not None:
                lines.append(f'{inner}\t\t<DefaultVisible>{"true" if dv else "false"}</DefaultVisible>')
            if vis is not None:
                emit_xr_flag(lines, 'Visible', vis, f'{inner}\t\t')
            lines.append(f'{inner}\t</Item>')
        lines.append(f'{inner}</{tag}>')
    lines.append(f'{indent}</CommandInterface>')


# --- Properties emitter ---

PROP_MAP = {
    "autoTitle": "AutoTitle",
    "windowOpeningMode": "WindowOpeningMode",
    "commandBarLocation": "CommandBarLocation",
    "saveDataInSettings": "SaveDataInSettings",
    "autoSaveDataInSettings": "AutoSaveDataInSettings",
    "autoTime": "AutoTime",
    "usePostingMode": "UsePostingMode",
    "repostOnWrite": "RepostOnWrite",
    "autoURL": "AutoURL",
    "autoFillCheck": "AutoFillCheck",
    "customizable": "Customizable",
    "enterKeyBehavior": "EnterKeyBehavior",
    "verticalScroll": "VerticalScroll",
    "scalingMode": "ScalingMode",
    "useForFoldersAndItems": "UseForFoldersAndItems",
    "reportResult": "ReportResult",
    "detailsData": "DetailsData",
    "reportFormType": "ReportFormType",
    "autoShowState": "AutoShowState",
    "width": "Width",
    "height": "Height",
    "group": "Group",
}


def emit_properties(lines, props, indent):
    if not props:
        return

    for p_name, p_value in props.items():
        xml_name = PROP_MAP.get(p_name)
        if not xml_name:
            # Auto PascalCase
            xml_name = p_name[0].upper() + p_name[1:]

        # Пустая строка = суппресс-маркер (напр. autoTitle:"" — не эмитить и не додумывать)
        if isinstance(p_value, str) and p_value == '':
            continue
        # Convert boolean to lowercase
        if isinstance(p_value, bool):
            val = 'true' if p_value else 'false'
        else:
            val = str(p_value)
        lines.append(f'{indent}<{xml_name}>{val}</{xml_name}>')



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


def _normalize_elements(defn):
    """Convert dict-style elements from --from-object generators to list-style expected by compiler.
    Generator format:  elements = {"ИмяЭлемента": {"element": "input", "path": "..."}, ...}
    Compiler format:   elements = [{"input": "ИмяЭлемента", "path": "..."}, ...]
    Also handles nested 'elements' in groups and 'columns' in tables recursively.
    """
    def convert_elements(els):
        if isinstance(els, list):
            # Already list format — but may have nested dicts inside groups
            result = []
            for el in els:
                if isinstance(el, dict):
                    el = dict(el)  # copy
                    if 'elements' in el and isinstance(el['elements'], dict):
                        el['elements'] = convert_elements(el['elements'])
                    if 'columns' in el and isinstance(el['columns'], dict):
                        el['columns'] = convert_columns(el['columns'])
                result.append(el)
            return result
        if isinstance(els, dict):
            result = []
            for name, props in els.items():
                if not isinstance(props, dict):
                    continue
                new_el = {}
                el_type = props.get('element', 'input')
                # Map element type to the key name used in JSON DSL
                type_map = {
                    'input': 'input', 'check': 'check', 'labelField': 'labelField',
                    'table': 'table', 'group': 'group', 'pages': 'pages',
                    'page': 'page', 'label': 'label', 'button': 'button',
                    'checkBox': 'check', 'radioButton': 'radioButton',
                    'pictureField': 'pictureField',
                }
                mapped_type = type_map.get(el_type, el_type)
                new_el[mapped_type] = name
                for k, v in props.items():
                    if k == 'element':
                        continue
                    if k == 'elements' and isinstance(v, dict):
                        new_el['elements'] = convert_elements(v)
                    elif k == 'columns' and isinstance(v, dict):
                        new_el['columns'] = convert_columns(v)
                    elif k == 'groupType':
                        # groupType → group property in DSL
                        new_el['group'] = v
                    elif k == 'showTitle':
                        new_el['showTitle'] = v
                    elif k == 'representation':
                        new_el['representation'] = v
                    elif k == 'autoCommandBar':
                        new_el['autoCommandBar'] = v
                    elif k == 'commandBarLocation':
                        new_el['commandBarLocation'] = v
                    else:
                        new_el[k] = v
                result.append(new_el)
            return result
        return els

    def convert_columns(cols):
        if isinstance(cols, list):
            return cols
        if isinstance(cols, dict):
            result = []
            for name, props in cols.items():
                if not isinstance(props, dict):
                    continue
                new_col = {}
                el_type = props.get('element', 'input')
                type_map = {
                    'input': 'input', 'check': 'check', 'labelField': 'labelField',
                    'checkBox': 'check',
                }
                mapped_type = type_map.get(el_type, el_type)
                new_col[mapped_type] = name
                for k, v in props.items():
                    if k == 'element':
                        continue
                    new_col[k] = v
                result.append(new_col)
            return result
        return cols

    if 'elements' in defn:
        defn['elements'] = convert_elements(defn['elements'])
    return defn


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    global _next_id

    parser = argparse.ArgumentParser(description='Compile 1C managed form from JSON or object metadata', allow_abbrev=False)
    parser.add_argument('-JsonPath', type=str, default=None)
    parser.add_argument('-OutputPath', type=str, required=True)
    parser.add_argument('-FromObject', action='store_true', default=False)
    parser.add_argument('-ObjectPath', type=str, default=None)
    parser.add_argument('-Purpose', type=str, default=None)
    parser.add_argument('-Preset', type=str, default='erp-standard')
    parser.add_argument('-EmitDsl', type=str, default=None)
    args = parser.parse_args()

    # Form name -> purpose mapping
    _FORM_NAME_TO_PURPOSE = {
        '\u0424\u043e\u0440\u043c\u0430\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0430': 'Item',       # ФормаДокумента
        '\u0424\u043e\u0440\u043c\u0430\u042d\u043b\u0435\u043c\u0435\u043d\u0442\u0430': 'Item',              # ФормаЭлемента
        '\u0424\u043e\u0440\u043c\u0430\u0421\u043f\u0438\u0441\u043a\u0430': 'List',                          # ФормаСписка
        '\u0424\u043e\u0440\u043c\u0430\u0412\u044b\u0431\u043e\u0440\u0430': 'Choice',                        # ФормаВыбора
        '\u0424\u043e\u0440\u043c\u0430\u0413\u0440\u0443\u043f\u043f\u044b': 'Folder',                        # ФормаГруппы
        '\u0424\u043e\u0440\u043c\u0430\u0417\u0430\u043f\u0438\u0441\u0438': 'Record',                       # ФормаЗаписи
        '\u0424\u043e\u0440\u043c\u0430\u0421\u0447\u0435\u0442\u0430': 'Item',                               # ФормаСчета
        '\u0424\u043e\u0440\u043c\u0430\u0423\u0437\u043b\u0430': 'Item',                                     # ФормаУзла
    }

    # Mutual exclusion validation
    if args.FromObject and args.JsonPath:
        print("Cannot use both -JsonPath and -FromObject. Choose one mode.", file=sys.stderr)
        sys.exit(1)
    if not args.FromObject and not args.JsonPath:
        print("Either -JsonPath or -FromObject is required.", file=sys.stderr)
        sys.exit(1)

    # Normalize OutputPath in from-object mode: append /Ext/Form.xml if missing
    if args.FromObject:
        out_norm = args.OutputPath.rstrip('/\\')
        if not re.search(r'[/\\]Ext[/\\]Form\.xml$', out_norm):
            if re.search(r'[/\\]Ext$', out_norm):
                args.OutputPath = out_norm + '/Form.xml'
            else:
                args.OutputPath = out_norm + '/Ext/Form.xml'
            print(f"[resolved] OutputPath -> {args.OutputPath}")

    # --- Detect XML format version ---
    out_path_resolved = args.OutputPath if os.path.isabs(args.OutputPath) else os.path.join(os.getcwd(), args.OutputPath)
    format_version = detect_format_version(os.path.dirname(out_path_resolved))

    # --- 0. From-object mode ---
    if args.FromObject:
        # Resolve object path and purpose from OutputPath convention:
        # .../TypePlural/ObjectName/Forms/FormName/Ext/Form.xml
        out_abs = out_path_resolved
        parts = re.split(r'[/\\]', out_abs)
        forms_idx = -1
        for i in range(len(parts) - 1, -1, -1):
            if parts[i] == 'Forms':
                forms_idx = i
                break

        resolved_object_path = None
        resolved_purpose = None

        if forms_idx >= 2:
            form_name = parts[forms_idx + 1]
            object_name = parts[forms_idx - 1]
            type_plural_and_above = os.sep.join(parts[:forms_idx - 1])

            if form_name in _FORM_NAME_TO_PURPOSE:
                resolved_purpose = _FORM_NAME_TO_PURPOSE[form_name]

            candidate = os.path.join(type_plural_and_above, f'{object_name}.xml')
            if os.path.exists(candidate):
                resolved_object_path = candidate

        # Apply: explicit -ObjectPath / -Purpose override resolved
        from_obj_path = None
        if args.ObjectPath:
            from_obj_path = args.ObjectPath if os.path.isabs(args.ObjectPath) else os.path.join(os.getcwd(), args.ObjectPath)
            if not from_obj_path.endswith('.xml'):
                from_obj_path += '.xml'
        elif resolved_object_path:
            from_obj_path = resolved_object_path
            print(f"[resolved] ObjectPath -> {from_obj_path}")
        else:
            print("Cannot derive object path from OutputPath. Use -ObjectPath explicitly.", file=sys.stderr)
            sys.exit(1)

        if not os.path.exists(from_obj_path):
            print(f"Object file not found: {from_obj_path}", file=sys.stderr)
            sys.exit(1)

        purpose = args.Purpose or resolved_purpose or 'Item'
        if resolved_purpose and not args.Purpose:
            print(f"[resolved] Purpose -> {purpose}")

        meta = parse_object_meta(from_obj_path)
        print(f"[from-object] Type={meta['Type']}, Name={meta['Name']}, Attrs={len(meta['Attributes'])}, TS={len(meta['TabularSections'])}")

        preset_data = load_preset(args.Preset, os.path.dirname(os.path.abspath(__file__)), out_path_resolved)

        supported = {
            'Document': ['Item', 'List', 'Choice'],
            'Catalog': ['Item', 'Folder', 'List', 'Choice'],
            'InformationRegister': ['Record', 'List'],
            'AccumulationRegister': ['List'],
            'ChartOfCharacteristicTypes': ['Item', 'Folder', 'List', 'Choice'],
            'ExchangePlan': ['Item', 'List', 'Choice'],
            'ChartOfAccounts': ['Item', 'Folder', 'List', 'Choice'],
        }
        if meta['Type'] not in supported:
            print(f"Object type '{meta['Type']}' not supported. Supported: Document, Catalog, InformationRegister, AccumulationRegister, ChartOfCharacteristicTypes, ExchangePlan, ChartOfAccounts.", file=sys.stderr)
            sys.exit(1)
        if purpose not in supported[meta['Type']]:
            print(f"Purpose '{purpose}' not valid for {meta['Type']}. Valid: {', '.join(supported[meta['Type']])}", file=sys.stderr)
            sys.exit(1)

        dsl_dispatch = {
            'Document': generate_document_dsl,
            'Catalog': generate_catalog_dsl,
            'InformationRegister': generate_information_register_dsl,
            'AccumulationRegister': generate_accumulation_register_dsl,
            'ChartOfCharacteristicTypes': generate_chart_of_characteristic_types_dsl,
            'ExchangePlan': generate_exchange_plan_dsl,
            'ChartOfAccounts': generate_chart_of_accounts_dsl,
        }
        dsl = dsl_dispatch[meta['Type']](meta, preset_data, purpose)

        if args.EmitDsl:
            dsl_path = args.EmitDsl if os.path.isabs(args.EmitDsl) else os.path.join(os.getcwd(), args.EmitDsl)
            os.makedirs(os.path.dirname(dsl_path) or '.', exist_ok=True)
            with open(dsl_path, 'w', encoding='utf-8') as f:
                json.dump(dsl, f, ensure_ascii=False, indent=2)
            print(f"[from-object] DSL saved: {dsl_path}")

        defn = json.loads(json.dumps(dsl))  # normalize OrderedDict to regular dict
        # Convert dict-style elements (from generators) to list-style (expected by compiler)
        defn = _normalize_elements(defn)
    else:
        # --- 1. Load and validate JSON ---
        json_path = args.JsonPath
        if not os.path.exists(json_path):
            print(f"File not found: {json_path}", file=sys.stderr)
            sys.exit(1)

        with open(json_path, 'r', encoding='utf-8-sig') as f:
            defn = json.load(f)
        global QUERY_BASE_DIR
        QUERY_BASE_DIR = os.path.dirname(os.path.abspath(json_path))

    # --- 1b. Pre-pass: synonyms, main attribute inference, heuristics, autoCmdBar extraction ---
    def _normalize_synonyms(el):
        if not isinstance(el, dict):
            return
        # Companion-панели (объект/массив-значение) → commandBar/contextMenu
        normalize_panel_synonyms(el)
        # Тип-синонимы: commandBar/autoCommandBar → элемент-тип ТОЛЬКО при строковом значении
        synonyms = {'commandBar': 'cmdBar', 'autoCommandBar': 'autoCmdBar', 'extTooltip': 'extendedTooltip'}
        for src, dst in synonyms.items():
            if src in el and dst not in el:
                if src in STR_ONLY_TYPE_SYNONYMS and not isinstance(el[src], str):
                    continue
                el[dst] = el.pop(src)
        # Рекурсия в детей панелей (commandBar/contextMenu)
        for pk in ('commandBar', 'contextMenu'):
            pv = el.get(pk)
            kids = pv if isinstance(pv, list) else (pv.get('children') if isinstance(pv, dict) else None)
            if isinstance(kids, list):
                for child in kids:
                    _normalize_synonyms(child)
        if isinstance(el.get('children'), list):
            for child in el['children']:
                _normalize_synonyms(child)
        if isinstance(el.get('columns'), list):
            for child in el['columns']:
                _normalize_synonyms(child)

    def _has_cmd_bar_recursive(el):
        if not isinstance(el, dict):
            return False
        if el.get('cmdBar') is not None:
            return True
        if isinstance(el.get('children'), list):
            for child in el['children']:
                if _has_cmd_bar_recursive(child):
                    return True
        if isinstance(el.get('columns'), list):
            for child in el['columns']:
                if _has_cmd_bar_recursive(child):
                    return True
        return False

    def _apply_dlist_table_heuristic(el, list_name, has_main_table):
        if not isinstance(el, dict):
            return
        if el.get('table') is not None and str(el.get('path', '')) == list_name:
            # Маркер дин-список-таблицы → emit_table эмитит блок свойств
            el['_dynList'] = True
            if 'tableAutofill' not in el:
                el['tableAutofill'] = False
            if 'commandBarLocation' not in el:
                el['commandBarLocation'] = 'None'
            # RowPictureDataPath: умный дефолт <Список>.DefaultPicture, если ключ ОТСУТСТВУЕТ.
            # Декомпилятор опускает при rpdp == smart-default; реальное отсутствие → ""-маркер (не
            # перезатирается). Гейт has_main_table снят: дин-список без mainTable тоже несёт RowPictureDataPath.
            if 'rowPictureDataPath' not in el:
                el['rowPictureDataPath'] = f'{list_name}.DefaultPicture'
        if isinstance(el.get('children'), list):
            for child in el['children']:
                _apply_dlist_table_heuristic(child, list_name, has_main_table)

    def _is_object_like_type(t):
        if not t:
            return False
        if t == 'DynamicList' or t == 'ConstantsSet':
            return True
        object_suffixes = (
            'CatalogObject', 'DocumentObject', 'DataProcessorObject', 'ReportObject',
            'ExternalDataProcessorObject', 'ExternalReportObject', 'BusinessProcessObject',
            'TaskObject', 'ChartOfAccountsObject', 'ChartOfCharacteristicTypesObject',
            'ChartOfCalculationTypesObject', 'ExchangePlanObject',
        )
        record_set_prefixes = (
            'InformationRegisterRecordSet', 'AccumulationRegisterRecordSet',
            'AccountingRegisterRecordSet', 'CalculationRegisterRecordSet',
            'InformationRegisterRecordManager',
        )
        for s in object_suffixes:
            if t.startswith(s + '.'):
                return True
        for s in record_set_prefixes:
            if t.startswith(s + '.'):
                return True
        return False

    # 1b.1: Normalize synonyms recursively
    if isinstance(defn.get('elements'), list):
        for el in defn['elements']:
            _normalize_synonyms(el)

    # 1b.2: Extract autoCmdBar element from defn['elements']
    main_acb_def = None
    if isinstance(defn.get('elements'), list):
        auto_bars = [el for el in defn['elements'] if isinstance(el, dict) and el.get('autoCmdBar') is not None]
        if len(auto_bars) > 1:
            print(f"form-compile: more than one autoCmdBar in def.elements (found {len(auto_bars)}); only one allowed.", file=sys.stderr)
            sys.exit(1)
        if len(auto_bars) == 1:
            main_acb_def = auto_bars[0]
            defn['elements'] = [el for el in defn['elements'] if el is not main_acb_def]

    # 1b.3: Infer main attribute
    if isinstance(defn.get('attributes'), list):
        has_explicit_main = any(a.get('main') is True for a in defn['attributes'] if isinstance(a, dict))
        if not has_explicit_main:
            candidates = []
            for a in defn['attributes']:
                if not isinstance(a, dict):
                    continue
                if 'main' in a and a.get('main') is False:
                    continue
                if _is_object_like_type(str(a.get('type', ''))):
                    candidates.append(a)
            if len(candidates) == 1:
                candidates[0]['main'] = True
                print(f"[INFO] Inferred main attribute: {candidates[0].get('name')} ({candidates[0].get('type')})")
            elif len(candidates) > 1:
                names = ', '.join(c.get('name', '') for c in candidates)
                print(f"[WARN] Multiple main-attribute candidates: {names}; specify \"main\": true explicitly")

    # 1b.4: DynamicList → table heuristic (для ВСЕХ DynamicList-реквизитов, не только main)
    if isinstance(defn.get('attributes'), list) and isinstance(defn.get('elements'), list):
        for attr in defn['attributes']:
            if not isinstance(attr, dict) or str(attr.get('type', '')) != 'DynamicList':
                continue
            settings = attr.get('settings') or {}
            has_mt = bool(isinstance(settings, dict) and settings.get('mainTable'))
            for el in defn['elements']:
                _apply_dlist_table_heuristic(el, attr.get('name', ''), has_mt)

    # 1b.5: Compute main AutoCommandBar Autofill (B3)
    def _compute_main_acb_autofill():
        if main_acb_def is not None:
            if 'autofill' in main_acb_def:
                return bool(main_acb_def.get('autofill'))
            return True
        if isinstance(defn.get('elements'), list):
            for el in defn['elements']:
                if _has_cmd_bar_recursive(el):
                    return False
        return True

    # --- 2. Main compilation ---
    _next_id = 0
    _seen_element_names.clear()  # пул имён элементов (на случай повторного вызова в одном процессе)
    lines = []

    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(f'<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="{format_version}">')

    # Title
    form_title = defn.get('title')
    if not form_title and defn.get('properties') and defn['properties'].get('title'):
        form_title = defn['properties']['title']
    if form_title:
        emit_mltext(lines, '\t', 'Title', form_title)

    # Properties (skip 'title' — handled above)
    # When form-level Title is set, default autoTitle=false (≈95% of ERP forms do this;
    # otherwise platform appends synonym → "Title: Synonym" double-titles).
    props_src = defn.get('properties') or {}
    props_clone = OrderedDict()
    if form_title and 'autoTitle' not in props_src:
        props_clone['autoTitle'] = False
    for k, v in props_src.items():
        if k != 'title':
            props_clone[k] = v
    emit_properties(lines, props_clone, '\t')

    # CommandSet (excluded commands)
    if defn.get('excludedCommands') and len(defn['excludedCommands']) > 0:
        lines.append('\t<CommandSet>')
        for cmd in defn['excludedCommands']:
            lines.append(f'\t\t<ExcludedCommand>{cmd}</ExcludedCommand>')
        lines.append('\t</CommandSet>')

    # MobileDeviceCommandBarContent — форменный список имён командных панелей/кнопок
    # (Presentation пустой, CheckState=0, тип xs:string — константы; варьируется только имя-Value).
    # 12 форм корпуса несут один пустой item (Value="") — список присутствует, но не пуст по len.
    if defn.get('mobileCommandBarContent') is not None and len(defn['mobileCommandBarContent']) > 0:
        lines.append('\t<MobileDeviceCommandBarContent>')
        for nm in defn['mobileCommandBarContent']:
            lines.append('\t\t<xr:Item>')
            lines.append('\t\t\t<xr:Presentation/>')
            lines.append('\t\t\t<xr:CheckState>0</xr:CheckState>')
            # пустое значение → самозакрывающийся тег (зеркало платформы)
            if not str(nm):
                lines.append('\t\t\t<xr:Value xsi:type="xs:string"/>')
            else:
                lines.append(f'\t\t\t<xr:Value xsi:type="xs:string">{esc_xml(str(nm))}</xr:Value>')
            lines.append('\t\t</xr:Item>')
        lines.append('\t</MobileDeviceCommandBarContent>')

    # AutoCommandBar (always present, id=-1)
    acb_autofill = _compute_main_acb_autofill()
    acb_name = '\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c'
    acb_halign = None
    if main_acb_def is not None:
        v = main_acb_def.get('autoCmdBar')
        if v:
            acb_name = str(v)
        if main_acb_def.get('name'):
            acb_name = str(main_acb_def['name'])
        if main_acb_def.get('horizontalAlign'):
            acb_halign = str(main_acb_def['horizontalAlign'])
    has_acb_children = bool(main_acb_def and isinstance(main_acb_def.get('children'), list) and len(main_acb_def['children']) > 0)
    # DisplayImportance форменной панели (адаптивная важность) — атрибут тега
    acb_di_attr = di_attr(main_acb_def) if main_acb_def is not None else ''
    has_inner = bool(acb_halign) or (not acb_autofill) or has_acb_children
    if has_inner:
        lines.append(f'\t<AutoCommandBar name="{acb_name}" id="-1"{acb_di_attr}>')
        if acb_halign:
            lines.append(f'\t\t<HorizontalAlign>{acb_halign}</HorizontalAlign>')
        if not acb_autofill:
            lines.append('\t\t<Autofill>false</Autofill>')
        if has_acb_children:
            lines.append('\t\t<ChildItems>')
            for child in main_acb_def['children']:
                emit_element(lines, child, '\t\t\t', in_cmd_bar=True)
            lines.append('\t\t</ChildItems>')
        lines.append('\t</AutoCommandBar>')
    else:
        lines.append(f'\t<AutoCommandBar name="{acb_name}" id="-1"{acb_di_attr}/>')

    # Events
    if defn.get('events'):
        for evt_name in defn['events']:
            if evt_name not in KNOWN_FORM_EVENTS:
                print(f"[WARN] Unknown form event '{evt_name}'. Known: {', '.join(KNOWN_FORM_EVENTS)}")
        lines.append('\t<Events>')
        for evt_name, evt_handler in defn['events'].items():
            lines.append(f'\t\t<Event name="{evt_name}">{evt_handler}</Event>')
        lines.append('\t</Events>')

    # ChildItems (elements)
    if defn.get('elements') and len(defn['elements']) > 0:
        lines.append('\t<ChildItems>')
        for el in defn['elements']:
            emit_element(lines, el, '\t\t')
        lines.append('\t</ChildItems>')

    # Attributes
    emit_attributes(lines, defn.get('attributes'), '\t', conditional_appearance=defn.get('conditionalAppearance'))

    # Parameters
    emit_parameters(lines, defn.get('parameters'), '\t')

    # Commands
    emit_commands(lines, defn.get('commands'), '\t')

    # CommandInterface (командный интерфейс формы — последний дочерний Form)
    emit_command_interface(lines, defn.get('commandInterface'), '\t')

    # Close
    lines.append('</Form>')

    # --- 3. Write output ---
    out_path = args.OutputPath
    if not os.path.isabs(out_path):
        out_path = os.path.join(os.getcwd(), out_path)
    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    content = '\n'.join(lines) + '\n'
    write_utf8_bom(out_path, content)

    # --- 4. Auto-register form in parent object XML ---
    # Infer parent from OutputPath: .../TypePlural/ObjectName/Forms/FormName/Ext/Form.xml
    form_xml_dir = os.path.dirname(out_path)    # Ext
    form_name_dir = os.path.dirname(form_xml_dir)  # FormName
    forms_dir = os.path.dirname(form_name_dir)    # Forms
    object_dir = os.path.dirname(forms_dir)       # ObjectName
    type_plural_dir = os.path.dirname(object_dir)  # TypePlural

    form_name = os.path.basename(form_name_dir)
    object_name = os.path.basename(object_dir)
    forms_leaf = os.path.basename(forms_dir)

    if forms_leaf == 'Forms':
        object_xml_path = os.path.join(type_plural_dir, f'{object_name}.xml')
        if os.path.exists(object_xml_path):
            with open(object_xml_path, 'r', encoding='utf-8-sig') as f:
                raw_text = f.read()

            # Check if already registered
            if f'<Form>{form_name}</Form>' not in raw_text:
                # Insert before </ChildObjects>
                if '</ChildObjects>' in raw_text:
                    insert_line = f'\t\t\t<Form>{form_name}</Form>\n'
                    raw_text = raw_text.replace('</ChildObjects>', insert_line + '\t\t</ChildObjects>', 1)
                elif '<ChildObjects/>' in raw_text:
                    replacement = f'<ChildObjects>\n\t\t\t<Form>{form_name}</Form>\n\t\t</ChildObjects>'
                    raw_text = raw_text.replace('<ChildObjects/>', replacement, 1)

                write_utf8_bom(object_xml_path, raw_text)
                print(f"     Registered: <Form>{form_name}</Form> in {object_name}.xml")

    # --- 5. Summary ---
    el_count = _next_id
    print(f"[OK] Compiled: {args.OutputPath}")
    print(f"     Elements+IDs: {el_count}")
    if defn.get('attributes'):
        print(f"     Attributes: {len(defn['attributes'])}")
    if defn.get('commands'):
        print(f"     Commands: {len(defn['commands'])}")
    if defn.get('parameters'):
        print(f"     Parameters: {len(defn['parameters'])}")


if __name__ == '__main__':
    main()
