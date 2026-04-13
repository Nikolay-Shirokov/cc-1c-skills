#!/usr/bin/env python3
# form-compile v1.6 — Compile 1C managed form from JSON or object metadata
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

    # Apply ref defaults
    if is_ref and field_defaults and field_defaults.get('ref'):
        if field_defaults['ref'].get('choiceButton') is True:
            el['choiceButton'] = True

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
    elements = OrderedDict()

    # Header: Code + Parent
    header_left = OrderedDict()
    if meta.get('CodeLength', 0) > 0:
        header_left['\u041a\u043e\u0434'] = {'element': 'input', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.Code'}
    header_right = OrderedDict()
    if meta.get('Hierarchical'):
        parent_title = (p.get('parent') or {}).get('title', '\u041f\u043e\u0434\u0447\u0438\u043d\u0435\u043d \u0441\u0447\u0435\u0442\u0443')
        header_right['\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c'] = {'element': 'input', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.Parent', 'title': parent_title}

    if len(header_right) > 0:
        elements['\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430'] = OrderedDict([
            ('element', 'group'), ('groupType', 'horizontal'), ('showTitle', False), ('representation', 'none'),
            ('elements', OrderedDict([
                ('\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430\u041b\u0435\u0432\u043e', OrderedDict([('element', 'group'), ('groupType', 'vertical'), ('showTitle', False), ('elements', header_left)])),
                ('\u0413\u0440\u0443\u043f\u043f\u0430\u0428\u0430\u043f\u043a\u0430\u041f\u0440\u0430\u0432\u043e', OrderedDict([('element', 'group'), ('groupType', 'vertical'), ('showTitle', False), ('elements', header_right)])),
            ])),
        ])
    elif len(header_left) > 0:
        for k, v in header_left.items():
            elements[k] = v

    # Description
    if meta.get('DescriptionLength', 0) > 0:
        elements['\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'] = {'element': 'input', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.Description'}

    # OffBalance
    elements['\u0417\u0430\u0431\u0430\u043b\u0430\u043d\u0441\u043e\u0432\u044b\u0439'] = {'element': 'check', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.OffBalance'}

    # AccountingFlags as checkboxes
    if meta.get('AccountingFlags') and len(meta['AccountingFlags']) > 0:
        flag_elements = OrderedDict()
        for flag in meta['AccountingFlags']:
            flag_elements[flag['Name']] = {'element': 'check', 'path': f"\u041e\u0431\u044a\u0435\u043a\u0442.{flag['Name']}"}
        elements['\u0413\u0440\u0443\u043f\u043f\u0430\u041f\u0440\u0438\u0437\u043d\u0430\u043a\u0438\u0423\u0447\u0435\u0442\u0430'] = OrderedDict([
            ('element', 'group'), ('groupType', 'vertical'), ('title', '\u041f\u0440\u0438\u0437\u043d\u0430\u043a\u0438 \u0443\u0447\u0435\u0442\u0430'),
            ('elements', flag_elements),
        ])

    # ExtDimensionTypes table
    if meta.get('MaxExtDimensionCount', 0) > 0:
        ed_cols = OrderedDict()
        ed_cols['\u0412\u0438\u0434\u0421\u0443\u0431\u043a\u043e\u043d\u0442\u043e'] = {'element': 'input', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes.ExtDimensionType'}
        ed_cols['\u0422\u043e\u043b\u044c\u043a\u043e\u041e\u0431\u043e\u0440\u043e\u0442\u044b'] = {'element': 'check', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes.TurnoversOnly'}
        if meta.get('ExtDimensionAccountingFlags'):
            for ed_flag in meta['ExtDimensionAccountingFlags']:
                ed_cols[ed_flag['Name']] = {'element': 'check', 'path': f"\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes.{ed_flag['Name']}"}
        elements['\u0412\u0438\u0434\u044b\u0421\u0443\u0431\u043a\u043e\u043d\u0442\u043e'] = OrderedDict([
            ('element', 'table'),
            ('path', '\u041e\u0431\u044a\u0435\u043a\u0442.ExtDimensionTypes'),
            ('columns', ed_cols),
        ])

    # Custom attributes
    for attr in meta['Attributes']:
        if not is_displayable_type(attr['Type']):
            continue
        elements[attr['Name']] = new_field_element(attr['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{attr['Name']}", attr['Type'], fd)

    # Tabular sections
    ts_exclude = ['\u0414\u043e\u043f\u043e\u043b\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u044b\u0435\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u044b', '\u041f\u0440\u0435\u0434\u0441\u0442\u0430\u0432\u043b\u0435\u043d\u0438\u044f']
    for ts in meta['TabularSections']:
        if ts['Name'] in ts_exclude:
            continue
        ts_cols = OrderedDict()
        for col in ts['Columns']:
            if not is_displayable_type(col['Type']):
                continue
            ts_cols[f"{ts['Name']}{col['Name']}"] = new_field_element(col['Name'], f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}.{col['Name']}", col['Type'], fd)
        elements[ts['Name']] = OrderedDict([('element', 'table'), ('path', f"\u041e\u0431\u044a\u0435\u043a\u0442.{ts['Name']}"), ('columns', ts_cols)])

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
    elements = OrderedDict()
    if meta.get('CodeLength', 0) > 0:
        elements['\u041a\u043e\u0434'] = {'element': 'input', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.Code'}
    if meta.get('DescriptionLength', 0) > 0:
        elements['\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435'] = {'element': 'input', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.Description'}
    if meta.get('Hierarchical'):
        parent_title = (p.get('parent') or {}).get('title', '\u041f\u043e\u0434\u0447\u0438\u043d\u0435\u043d \u0441\u0447\u0435\u0442\u0443')
        elements['\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c'] = {'element': 'input', 'path': '\u041e\u0431\u044a\u0435\u043a\u0442.Parent', 'title': parent_title}

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


# --- ID allocator ---
_next_id = 0

def new_id():
    global _next_id
    _next_id += 1
    return _next_id


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
    "group", "input", "check", "label", "labelField", "table", "pages", "page",
    "button", "picture", "picField", "calendar", "cmdBar", "popup",
    "name", "path", "title",
    "visible", "hidden", "enabled", "disabled", "readOnly", "userVisible",
    "on", "handlers",
    "titleLocation", "representation", "width", "height",
    "horizontalStretch", "verticalStretch", "autoMaxWidth", "autoMaxHeight",
    "multiLine", "passwordMode", "choiceButton", "clearButton",
    "spinButton", "dropListButton", "markIncomplete", "skipOnInput", "inputHint",
    "hyperlink",
    "showTitle", "united",
    "children", "columns",
    "changeRowSet", "changeRowOrder", "header", "footer",
    "commandBarLocation", "searchStringLocation",
    "pagesRepresentation",
    "type", "command", "stdCommand", "defaultButton", "locationInCommandBar",
    "src",
    "autofill",
    "choiceMode", "initialTreeView", "enableDrag", "enableStartDrag",
    "rowPictureDataPath", "tableAutofill",
}

TYPE_KEYS = ["group", "input", "check", "label", "labelField", "table", "pages", "page",
             "button", "picture", "picField", "calendar", "cmdBar", "popup"]


def get_handler_name(element_name, event_name):
    suffix = EVENT_SUFFIX_MAP.get(event_name)
    if suffix:
        return f"{element_name}{suffix}"
    return f"{element_name}{event_name}"


def get_element_name(el, type_key):
    if el.get('name'):
        return str(el['name'])
    return str(el.get(type_key, ''))


def emit_events(lines, el, element_name, indent, type_key):
    if not el.get('on'):
        return

    # Validate event names
    if type_key and type_key in KNOWN_EVENTS:
        allowed = KNOWN_EVENTS[type_key]
        for evt in el['on']:
            if allowed and str(evt) not in allowed:
                print(f"[WARN] Unknown event '{evt}' for {type_key} '{element_name}'. Known: {', '.join(allowed)}")

    lines.append(f"{indent}<Events>")
    for evt in el['on']:
        evt_name = str(evt)
        handlers = el.get('handlers')
        if handlers and handlers.get(evt_name):
            handler = str(handlers[evt_name])
        else:
            handler = get_handler_name(element_name, evt_name)
        lines.append(f'{indent}\t<Event name="{evt_name}">{handler}</Event>')
    lines.append(f"{indent}</Events>")


def emit_companion(lines, tag, name, indent):
    cid = new_id()
    lines.append(f'{indent}<{tag} name="{name}" id="{cid}"/>')


def emit_common_flags(lines, el, indent):
    if el.get('visible') is False or el.get('hidden') is True:
        lines.append(f"{indent}<Visible>false</Visible>")
    if el.get('userVisible') is False:
        lines.append(f"{indent}<UserVisible>")
        lines.append(f"{indent}\t<xr:Common>false</xr:Common>")
        lines.append(f"{indent}</UserVisible>")
    if el.get('enabled') is False or el.get('disabled') is True:
        lines.append(f"{indent}<Enabled>false</Enabled>")
    if el.get('readOnly') is True:
        lines.append(f"{indent}<ReadOnly>true</ReadOnly>")


def emit_title(lines, el, name, indent):
    if el.get('title'):
        emit_mltext(lines, indent, 'Title', str(el['title']))


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
    'FormDataStructure': 'Runtime type. Use cfg:*Object.XXX (e.g. CatalogObject.XXX)',
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
}


def resolve_type_str(type_str):
    if not type_str:
        return type_str
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

    # DynamicList
    if type_str == 'DynamicList':
        lines.append(f'{indent}<v8:Type>cfg:DynamicList</v8:Type>')
        return

    # cfg: references
    if CFG_REF_PATTERN.match(type_str):
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return

    # Fallback with validation
    if type_str in KNOWN_INVALID_TYPES:
        raise ValueError(f"Invalid form attribute type '{type_str}': {KNOWN_INVALID_TYPES[type_str]}")
    if '.' in type_str:
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
    else:
        print(f"WARNING: Unrecognized bare type '{type_str}' — will be emitted without namespace prefix", file=sys.stderr)
        lines.append(f'{indent}<v8:Type>{type_str}</v8:Type>')


def emit_type(lines, type_str, indent):
    if not type_str:
        lines.append(f'{indent}<Type/>')
        return

    type_string = str(type_str)
    parts = [p.strip() for p in re.split(r'[|+]', type_string)]

    lines.append(f'{indent}<Type>')
    for part in parts:
        emit_single_type(lines, part, f'{indent}\t')
    lines.append(f'{indent}</Type>')


# --- Element emitters ---

def emit_element(lines, el, indent):
    type_key = None
    for key in TYPE_KEYS:
        if el.get(key) is not None:
            type_key = key
            break

    if not type_key:
        print("WARNING: Unknown element type, skipping", file=sys.stderr)
        return

    # Validate known keys
    for p_name in el.keys():
        if p_name not in KNOWN_KEYS:
            print(f"WARNING: Element '{el.get(type_key, '')}': unknown key '{p_name}' -- ignored. Check SKILL.md for valid keys.", file=sys.stderr)

    name = get_element_name(el, type_key)
    eid = new_id()

    emitters = {
        'group': emit_group,
        'input': emit_input,
        'check': emit_check,
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
    }

    emitter = emitters.get(type_key)
    if emitter:
        emitter(lines, el, name, eid, indent)


def emit_group(lines, el, name, eid, indent):
    lines.append(f'{indent}<UsualGroup name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    # Group orientation
    group_val = str(el.get('group', ''))
    orientation_map = {
        'horizontal': 'Horizontal',
        'vertical': 'Vertical',
        'alwaysHorizontal': 'AlwaysHorizontal',
        'alwaysVertical': 'AlwaysVertical',
    }
    orientation = orientation_map.get(group_val)
    if orientation:
        lines.append(f'{inner}<Group>{orientation}</Group>')

    # Behavior
    if group_val == 'collapsible':
        lines.append(f'{inner}<Group>Vertical</Group>')
        lines.append(f'{inner}<Behavior>Collapsible</Behavior>')

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

    # ShowTitle
    if el.get('showTitle') is False:
        lines.append(f'{inner}<ShowTitle>false</ShowTitle>')

    # United
    if el.get('united') is False:
        lines.append(f'{inner}<United>false</United>')

    emit_common_flags(lines, el, inner)

    # Companion: ExtendedTooltip
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</UsualGroup>')


def emit_input(lines, el, name, eid, indent):
    lines.append(f'{indent}<InputField name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        loc_map = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom'}
        loc = loc_map.get(str(el['titleLocation']), str(el['titleLocation']))
        lines.append(f'{inner}<TitleLocation>{loc}</TitleLocation>')

    if el.get('multiLine') is True:
        lines.append(f'{inner}<MultiLine>true</MultiLine>')
    if el.get('passwordMode') is True:
        lines.append(f'{inner}<PasswordMode>true</PasswordMode>')
    if el.get('choiceButton') is False:
        lines.append(f'{inner}<ChoiceButton>false</ChoiceButton>')
    if el.get('clearButton') is True:
        lines.append(f'{inner}<ClearButton>true</ClearButton>')
    if el.get('spinButton') is True:
        lines.append(f'{inner}<SpinButton>true</SpinButton>')
    if el.get('dropListButton') is True:
        lines.append(f'{inner}<DropListButton>true</DropListButton>')
    if el.get('markIncomplete') is True:
        lines.append(f'{inner}<AutoMarkIncomplete>true</AutoMarkIncomplete>')
    if el.get('skipOnInput') is True:
        lines.append(f'{inner}<SkipOnInput>true</SkipOnInput>')
    if el.get('autoMaxWidth') is False:
        lines.append(f'{inner}<AutoMaxWidth>false</AutoMaxWidth>')
    if el.get('autoMaxHeight') is False:
        lines.append(f'{inner}<AutoMaxHeight>false</AutoMaxHeight>')
    if el.get('width'):
        lines.append(f'{inner}<Width>{el["width"]}</Width>')
    if el.get('height'):
        lines.append(f'{inner}<Height>{el["height"]}</Height>')
    if el.get('horizontalStretch') is True:
        lines.append(f'{inner}<HorizontalStretch>true</HorizontalStretch>')
    if el.get('verticalStretch') is True:
        lines.append(f'{inner}<VerticalStretch>true</VerticalStretch>')

    if el.get('inputHint'):
        emit_mltext(lines, inner, 'InputHint', str(el['inputHint']))

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'input')

    lines.append(f'{indent}</InputField>')


def emit_check(lines, el, name, eid, indent):
    lines.append(f'{indent}<CheckBoxField name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{el["titleLocation"]}</TitleLocation>')

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'check')

    lines.append(f'{indent}</CheckBoxField>')


def emit_label(lines, el, name, eid, indent):
    lines.append(f'{indent}<LabelDecoration name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('title'):
        formatted = 'true' if el.get('hyperlink') is True else 'false'
        lines.append(f'{inner}<Title formatted="{formatted}">')
        lines.append(f'{inner}\t<v8:item>')
        lines.append(f'{inner}\t\t<v8:lang>ru</v8:lang>')
        lines.append(f'{inner}\t\t<v8:content>{esc_xml(str(el["title"]))}</v8:content>')
        lines.append(f'{inner}\t</v8:item>')
        lines.append(f'{inner}</Title>')

    emit_common_flags(lines, el, inner)

    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
    if el.get('autoMaxWidth') is False:
        lines.append(f'{inner}<AutoMaxWidth>false</AutoMaxWidth>')
    if el.get('autoMaxHeight') is False:
        lines.append(f'{inner}<AutoMaxHeight>false</AutoMaxHeight>')
    if el.get('width'):
        lines.append(f'{inner}<Width>{el["width"]}</Width>')
    if el.get('height'):
        lines.append(f'{inner}<Height>{el["height"]}</Height>')

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'label')

    lines.append(f'{indent}</LabelDecoration>')


def emit_label_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<LabelField name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'labelField')

    lines.append(f'{indent}</LabelField>')


def emit_table(lines, el, name, eid, indent):
    lines.append(f'{indent}<Table name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')
    if el.get('changeRowSet') is True:
        lines.append(f'{inner}<ChangeRowSet>true</ChangeRowSet>')
    if el.get('changeRowOrder') is True:
        lines.append(f'{inner}<ChangeRowOrder>true</ChangeRowOrder>')
    if el.get('height'):
        lines.append(f'{inner}<HeightInTableRows>{el["height"]}</HeightInTableRows>')
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
    if el.get('initialTreeView'):
        lines.append(f'{inner}<InitialTreeView>{el["initialTreeView"]}</InitialTreeView>')
    if el.get('enableStartDrag') is True:
        lines.append(f'{inner}<EnableStartDrag>true</EnableStartDrag>')
    if el.get('enableDrag') is True:
        lines.append(f'{inner}<EnableDrag>true</EnableDrag>')
    if el.get('rowPictureDataPath'):
        lines.append(f'{inner}<RowPictureDataPath>{el["rowPictureDataPath"]}</RowPictureDataPath>')

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    # AutoCommandBar — with optional Autofill control
    if el.get('tableAutofill') is not None:
        acb_id = new_id()
        acb_name = f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c'
        af_val = 'true' if el['tableAutofill'] else 'false'
        lines.append(f'{inner}<AutoCommandBar name="{acb_name}" id="{acb_id}">')
        lines.append(f'{inner}\t<Autofill>{af_val}</Autofill>')
        lines.append(f'{inner}</AutoCommandBar>')
    else:
        emit_companion(lines, 'AutoCommandBar', f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c', inner)
    emit_companion(lines, 'SearchStringAddition', f'{name}\u0421\u0442\u0440\u043e\u043a\u0430\u041f\u043e\u0438\u0441\u043a\u0430', inner)
    emit_companion(lines, 'ViewStatusAddition', f'{name}\u0421\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u0435\u041f\u0440\u043e\u0441\u043c\u043e\u0442\u0440\u0430', inner)
    emit_companion(lines, 'SearchControlAddition', f'{name}\u0423\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u0438\u0435\u041f\u043e\u0438\u0441\u043a\u043e\u043c', inner)

    # Columns
    if el.get('columns') and len(el['columns']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for col in el['columns']:
            emit_element(lines, col, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    emit_events(lines, el, name, inner, 'table')

    lines.append(f'{indent}</Table>')


def emit_pages(lines, el, name, eid, indent):
    lines.append(f'{indent}<Pages name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('pagesRepresentation'):
        lines.append(f'{inner}<PagesRepresentation>{el["pagesRepresentation"]}</PagesRepresentation>')

    emit_common_flags(lines, el, inner)

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'pages')

    # Children (pages)
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Pages>')


def emit_page(lines, el, name, eid, indent):
    lines.append(f'{indent}<Page name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('group'):
        orientation_map = {
            'horizontal': 'Horizontal',
            'vertical': 'Vertical',
            'alwaysHorizontal': 'AlwaysHorizontal',
            'alwaysVertical': 'AlwaysVertical',
        }
        orientation = orientation_map.get(str(el['group']))
        if orientation:
            lines.append(f'{inner}<Group>{orientation}</Group>')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Page>')


def emit_button(lines, el, name, eid, indent):
    lines.append(f'{indent}<Button name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    # Type
    if el.get('type'):
        btn_type_map = {'usual': 'UsualButton', 'hyperlink': 'Hyperlink', 'commandBar': 'CommandBarButton'}
        btn_type = btn_type_map.get(str(el['type']), str(el['type']))
        lines.append(f'{inner}<Type>{btn_type}</Type>')

    # CommandName
    if el.get('command'):
        lines.append(f'{inner}<CommandName>Form.Command.{el["command"]}</CommandName>')
    if el.get('stdCommand'):
        sc = str(el['stdCommand'])
        m = re.match(r'^(.+)\.(.+)$', sc)
        if m:
            lines.append(f'{inner}<CommandName>Form.Item.{m.group(1)}.StandardCommand.{m.group(2)}</CommandName>')
        else:
            lines.append(f'{inner}<CommandName>Form.StandardCommand.{sc}</CommandName>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('defaultButton') is True:
        lines.append(f'{inner}<DefaultButton>true</DefaultButton>')

    # Picture
    if el.get('picture'):
        lines.append(f'{inner}<Picture>')
        lines.append(f'{inner}\t<xr:Ref>{el["picture"]}</xr:Ref>')
        lines.append(f'{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>')
        lines.append(f'{inner}</Picture>')

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')

    if el.get('locationInCommandBar'):
        lines.append(f'{inner}<LocationInCommandBar>{el["locationInCommandBar"]}</LocationInCommandBar>')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'button')

    lines.append(f'{indent}</Button>')


def emit_picture_decoration(lines, el, name, eid, indent):
    lines.append(f'{indent}<PictureDecoration name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('picture') or el.get('src'):
        ref = str(el.get('src') or el.get('picture'))
        lines.append(f'{inner}<Picture>')
        lines.append(f'{inner}\t<xr:Ref>{ref}</xr:Ref>')
        lines.append(f'{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>')
        lines.append(f'{inner}</Picture>')

    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
    if el.get('width'):
        lines.append(f'{inner}<Width>{el["width"]}</Width>')
    if el.get('height'):
        lines.append(f'{inner}<Height>{el["height"]}</Height>')

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'picture')

    lines.append(f'{indent}</PictureDecoration>')


def emit_picture_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<PictureField name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('width'):
        lines.append(f'{inner}<Width>{el["width"]}</Width>')
    if el.get('height'):
        lines.append(f'{inner}<Height>{el["height"]}</Height>')

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'picField')

    lines.append(f'{indent}</PictureField>')


def emit_calendar(lines, el, name, eid, indent):
    lines.append(f'{indent}<CalendarField name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner)

    emit_events(lines, el, name, inner, 'calendar')

    lines.append(f'{indent}</CalendarField>')


def emit_command_bar(lines, el, name, eid, indent):
    lines.append(f'{indent}<CommandBar name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    if el.get('autofill') is True:
        lines.append(f'{inner}<Autofill>true</Autofill>')

    emit_common_flags(lines, el, inner)

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</CommandBar>')


def emit_popup(lines, el, name, eid, indent):
    lines.append(f'{indent}<Popup name="{name}" id="{eid}">')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('picture'):
        lines.append(f'{inner}<Picture>')
        lines.append(f'{inner}\t<xr:Ref>{el["picture"]}</xr:Ref>')
        lines.append(f'{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>')
        lines.append(f'{inner}</Picture>')

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Popup>')


# --- Attribute emitter ---

def emit_attributes(lines, attrs, indent):
    if not attrs or len(attrs) == 0:
        return

    lines.append(f'{indent}<Attributes>')
    for attr in attrs:
        attr_id = new_id()
        attr_name = str(attr['name'])

        lines.append(f'{indent}\t<Attribute name="{attr_name}" id="{attr_id}">')
        inner = f'{indent}\t\t'

        if attr.get('title'):
            emit_mltext(lines, inner, 'Title', str(attr['title']))

        # Type
        if attr.get('type'):
            emit_type(lines, str(attr['type']), inner)
        else:
            lines.append(f'{inner}<Type/>')

        if attr.get('main') is True:
            lines.append(f'{inner}<MainAttribute>true</MainAttribute>')
        if attr.get('savedData') is True:
            lines.append(f'{inner}<SavedData>true</SavedData>')
        if attr.get('fillChecking'):
            lines.append(f'{inner}<FillChecking>{attr["fillChecking"]}</FillChecking>')

        # Columns (for ValueTable/ValueTree)
        if attr.get('columns') and len(attr['columns']) > 0:
            lines.append(f'{inner}<Columns>')
            for col in attr['columns']:
                col_id = new_id()
                lines.append(f'{inner}\t<Column name="{col["name"]}" id="{col_id}">')
                if col.get('title'):
                    emit_mltext(lines, f'{inner}\t\t', 'Title', str(col['title']))
                emit_type(lines, str(col.get('type', '')), f'{inner}\t\t')
                lines.append(f'{inner}\t</Column>')
            lines.append(f'{inner}</Columns>')

        # Settings (for DynamicList)
        if attr.get('settings'):
            s = attr['settings']
            lines.append(f'{inner}<Settings xsi:type="DynamicList">')
            si = f'{inner}\t'
            if s.get('mainTable'):
                lines.append(f'{si}<MainTable>{s["mainTable"]}</MainTable>')
            mq = 'true' if s.get('manualQuery') else 'false'
            lines.append(f'{si}<ManualQuery>{mq}</ManualQuery>')
            ddr = 'true' if s.get('dynamicDataRead') else 'false'
            lines.append(f'{si}<DynamicDataRead>{ddr}</DynamicDataRead>')
            lines.append(f'{inner}</Settings>')

        lines.append(f'{indent}\t</Attribute>')
    lines.append(f'{indent}</Attributes>')


# --- Parameter emitter ---

def emit_parameters(lines, params, indent):
    if not params or len(params) == 0:
        return

    lines.append(f'{indent}<Parameters>')
    for param in params:
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
    for cmd in cmds:
        cmd_id = new_id()
        lines.append(f'{indent}\t<Command name="{cmd["name"]}" id="{cmd_id}">')
        inner = f'{indent}\t\t'

        if cmd.get('title'):
            emit_mltext(lines, inner, 'Title', str(cmd['title']))

        if cmd.get('action'):
            lines.append(f'{inner}<Action>{cmd["action"]}</Action>')

        if cmd.get('shortcut'):
            lines.append(f'{inner}<Shortcut>{cmd["shortcut"]}</Shortcut>')

        if cmd.get('picture'):
            lines.append(f'{inner}<Picture>')
            lines.append(f'{inner}\t<xr:Ref>{cmd["picture"]}</xr:Ref>')
            lines.append(f'{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>')
            lines.append(f'{inner}</Picture>')

        if cmd.get('representation'):
            lines.append(f'{inner}<Representation>{cmd["representation"]}</Representation>')

        lines.append(f'{indent}\t</Command>')
    lines.append(f'{indent}</Commands>')


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

    # --- 2. Main compilation ---
    _next_id = 0
    lines = []

    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(f'<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="{format_version}">')

    # Title
    form_title = defn.get('title')
    if not form_title and defn.get('properties') and defn['properties'].get('title'):
        form_title = defn['properties']['title']
    if form_title:
        emit_mltext(lines, '\t', 'Title', str(form_title))

    # Properties (skip 'title' — handled above)
    if defn.get('properties'):
        props_clone = {k: v for k, v in defn['properties'].items() if k != 'title'}
        emit_properties(lines, props_clone, '\t')

    # CommandSet (excluded commands)
    if defn.get('excludedCommands') and len(defn['excludedCommands']) > 0:
        lines.append('\t<CommandSet>')
        for cmd in defn['excludedCommands']:
            lines.append(f'\t\t<ExcludedCommand>{cmd}</ExcludedCommand>')
        lines.append('\t</CommandSet>')

    # AutoCommandBar (always present, id=-1)
    lines.append('\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">')
    lines.append('\t\t<HorizontalAlign>Right</HorizontalAlign>')
    lines.append('\t\t<Autofill>false</Autofill>')
    lines.append('\t</AutoCommandBar>')

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
    emit_attributes(lines, defn.get('attributes'), '\t')

    # Parameters
    emit_parameters(lines, defn.get('parameters'), '\t')

    # Commands
    emit_commands(lines, defn.get('commands'), '\t')

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
