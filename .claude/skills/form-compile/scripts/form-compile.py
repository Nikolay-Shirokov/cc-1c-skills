#!/usr/bin/env python3
# form-compile v1.4 — Compile 1C managed form from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid


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
    "visible", "hidden", "enabled", "disabled", "readOnly",
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

    # Companions
    emit_companion(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner)
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


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    global _next_id

    parser = argparse.ArgumentParser(description='Compile 1C managed form from JSON', allow_abbrev=False)
    parser.add_argument('-JsonPath', type=str, required=True)
    parser.add_argument('-OutputPath', type=str, required=True)
    args = parser.parse_args()

    # --- Detect XML format version ---
    out_path_resolved = args.OutputPath if os.path.isabs(args.OutputPath) else os.path.join(os.getcwd(), args.OutputPath)
    format_version = detect_format_version(os.path.dirname(out_path_resolved))

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
