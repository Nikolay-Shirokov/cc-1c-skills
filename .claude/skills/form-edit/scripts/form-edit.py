# form-edit v1.0 — Edit 1C managed form elements (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# ── arg parsing ──────────────────────────────────────────────

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-FormPath", required=True)
parser.add_argument("-JsonPath", required=True)
args = parser.parse_args()

form_path = args.FormPath
json_path = args.JsonPath

# ── namespaces ───────────────────────────────────────────────

FORM_NS = "http://v8.1c.ru/8.3/xcf/logform"
V8_NS = "http://v8.1c.ru/8.1/data/core"
NS = {
    "f": FORM_NS,
    "v8": V8_NS,
}

ALL_NS_DECL = (
    'xmlns="http://v8.1c.ru/8.3/xcf/logform"'
    ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
    ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
    ' xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"'
    ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
    ' xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"'
    ' xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"'
    ' xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"'
    ' xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema"'
)


def local_name(node):
    return etree.QName(node.tag).localname


# ── helpers ──────────────────────────────────────────────────

def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


# ── 1. Load Form.xml ────────────────────────────────────────

if not os.path.exists(form_path):
    print(f"File not found: {form_path}", file=sys.stderr)
    sys.exit(1)
if not os.path.exists(json_path):
    print(f"File not found: {json_path}", file=sys.stderr)
    sys.exit(1)

resolved_form_path = os.path.abspath(form_path)
xml_parser = etree.XMLParser(remove_blank_text=False)
try:
    tree = etree.parse(resolved_form_path, xml_parser)
except etree.XMLSyntaxError as e:
    print(f"[ERROR] XML parse error: {e}")
    sys.exit(1)

root = tree.getroot()

# ── 2. Load JSON ────────────────────────────────────────────

with open(json_path, "r", encoding="utf-8-sig") as f:
    defn = json.load(f)

# ── 3. Form name + header ───────────────────────────────────

form_name = os.path.splitext(os.path.basename(form_path))[0]
parent_dir = os.path.dirname(resolved_form_path)
if parent_dir:
    ext_dir = os.path.basename(parent_dir)
    if ext_dir == "Ext":
        form_dir = os.path.dirname(parent_dir)
        if form_dir:
            form_name = os.path.basename(form_dir)

print(f"=== form-edit: {form_name} ===")
print()

# ── 4. Scan max IDs per pool ────────────────────────────────

next_elem_id = 0
next_attr_id = 0
next_cmd_id = 0


def _scan_id(node, attr="id"):
    val = node.get(attr)
    if val and val != "-1":
        try:
            return int(val)
        except ValueError:
            pass
    return -1


# Scan element IDs
root_ci = root.find("f:ChildItems", NS)
if root_ci is not None:
    for elem in root_ci.iter():
        v = _scan_id(elem)
        if v > next_elem_id:
            next_elem_id = v

acb = root.find("f:AutoCommandBar", NS)
if acb is not None:
    v = _scan_id(acb)
    if v > next_elem_id:
        next_elem_id = v

# Scan attribute IDs (including column IDs - same pool)
for attr_el in root.findall("f:Attributes/f:Attribute", NS):
    v = _scan_id(attr_el)
    if v > next_attr_id:
        next_attr_id = v
    for col_el in attr_el.findall("f:Columns/f:Column", NS):
        v = _scan_id(col_el)
        if v > next_attr_id:
            next_attr_id = v

# Scan command IDs
for cmd_el in root.findall("f:Commands/f:Command", NS):
    v = _scan_id(cmd_el)
    if v > next_cmd_id:
        next_cmd_id = v

next_elem_id += 1
next_attr_id += 1
next_cmd_id += 1

# --- 4b. Auto-detect extension mode (BaseForm present) ---
is_extension = False
base_form = root.find("f:BaseForm", NS)
if base_form is not None:
    is_extension = True
    if next_attr_id < 1000000:
        next_attr_id = 1000000
    if next_cmd_id < 1000000:
        next_cmd_id = 1000000
    if next_elem_id < 1000000:
        next_elem_id = 1000000


def new_elem_id():
    global next_elem_id
    _id = next_elem_id
    next_elem_id += 1
    return _id


def new_attr_id():
    global next_attr_id
    _id = next_attr_id
    next_attr_id += 1
    return _id


def new_cmd_id():
    global next_cmd_id
    _id = next_cmd_id
    next_cmd_id += 1
    return _id


new_id = new_elem_id  # alias for element emitters

# ── 5. Fragment helpers (StringBuilder + Emit-* from form-compile) ──

xml_lines = []


def X(text):
    xml_lines.append(text)


# --- Type emitter ---

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


def emit_type(type_str, indent):
    if not type_str:
        X(f"{indent}<Type/>")
        return
    type_string = str(type_str)
    parts = [p.strip() for p in re.split(r'[|+]', type_string)]
    X(f"{indent}<Type>")
    for part in parts:
        emit_single_type(part, indent + "\t")
    X(f"{indent}</Type>")


def emit_single_type(type_str, indent):
    type_str = resolve_type_str(type_str)
    if type_str == "boolean":
        X(f"{indent}<v8:Type>xs:boolean</v8:Type>")
        return

    m = re.match(r'^string(\((\d+)\))?$', type_str)
    if m:
        length = m.group(2) if m.group(2) else "0"
        X(f"{indent}<v8:Type>xs:string</v8:Type>")
        X(f"{indent}<v8:StringQualifiers>")
        X(f"{indent}\t<v8:Length>{length}</v8:Length>")
        X(f"{indent}\t<v8:AllowedLength>Variable</v8:AllowedLength>")
        X(f"{indent}</v8:StringQualifiers>")
        return

    m = re.match(r'^decimal\((\d+),(\d+)(,nonneg)?\)$', type_str)
    if m:
        digits = m.group(1)
        fraction = m.group(2)
        sign = "Nonnegative" if m.group(3) else "Any"
        X(f"{indent}<v8:Type>xs:decimal</v8:Type>")
        X(f"{indent}<v8:NumberQualifiers>")
        X(f"{indent}\t<v8:Digits>{digits}</v8:Digits>")
        X(f"{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>")
        X(f"{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>")
        X(f"{indent}</v8:NumberQualifiers>")
        return

    m = re.match(r'^(date|dateTime|time)$', type_str)
    if m:
        fractions_map = {"date": "Date", "dateTime": "DateTime", "time": "Time"}
        fractions = fractions_map[type_str]
        X(f"{indent}<v8:Type>xs:dateTime</v8:Type>")
        X(f"{indent}<v8:DateQualifiers>")
        X(f"{indent}\t<v8:DateFractions>{fractions}</v8:DateFractions>")
        X(f"{indent}</v8:DateQualifiers>")
        return

    v8_types = {
        "ValueTable": "v8:ValueTable", "ValueTree": "v8:ValueTree", "ValueList": "v8:ValueListType",
        "TypeDescription": "v8:TypeDescription", "Universal": "v8:Universal",
        "FixedArray": "v8:FixedArray", "FixedStructure": "v8:FixedStructure",
    }
    if type_str in v8_types:
        X(f"{indent}<v8:Type>{v8_types[type_str]}</v8:Type>")
        return

    ui_types = {"FormattedString": "v8ui:FormattedString", "Picture": "v8ui:Picture", "Color": "v8ui:Color", "Font": "v8ui:Font"}
    if type_str in ui_types:
        X(f"{indent}<v8:Type>{ui_types[type_str]}</v8:Type>")
        return

    if type_str == "DynamicList":
        X(f"{indent}<v8:Type>cfg:DynamicList</v8:Type>")
        return

    if type_str.startswith("DataComposition"):
        dcs_map = {
            "DataCompositionSettings": "dcsset:DataCompositionSettings",
            "DataCompositionSchema": "dcssch:DataCompositionSchema",
            "DataCompositionComparisonType": "dcscor:DataCompositionComparisonType",
        }
        if type_str in dcs_map:
            X(f"{indent}<v8:Type>{dcs_map[type_str]}</v8:Type>")
            return

    if re.match(r'^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef|InformationRegisterRecordSet|AccumulationRegisterRecordSet|DataProcessorObject)\.', type_str):
        X(f"{indent}<v8:Type>cfg:{type_str}</v8:Type>")
        return

    if "." in type_str:
        X(f"{indent}<v8:Type>cfg:{type_str}</v8:Type>")
    else:
        X(f"{indent}<v8:Type>{type_str}</v8:Type>")


def emit_mltext(tag, text, indent):
    X(f"{indent}<{tag}>")
    X(f"{indent}\t<v8:item>")
    X(f"{indent}\t\t<v8:lang>ru</v8:lang>")
    X(f"{indent}\t\t<v8:content>{esc_xml(text)}</v8:content>")
    X(f"{indent}\t</v8:item>")
    X(f"{indent}</{tag}>")


# --- Event handler name generator ---

event_suffix_map = {
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


def get_handler_name(element_name, event_name):
    suffix = event_suffix_map.get(event_name)
    if suffix:
        return f"{element_name}{suffix}"
    return f"{element_name}{event_name}"


# --- Element helpers ---

def get_element_name(el, type_key):
    if "name" in el and el["name"]:
        return str(el["name"])
    return str(el[type_key])


known_events = {
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


def emit_events(el, element_name, indent, type_key):
    on_list = el.get("on")
    if not on_list:
        return

    # Validate event names
    if type_key and type_key in known_events:
        allowed = known_events[type_key]
        for evt in on_list:
            evt_str = evt if isinstance(evt, str) else str(evt.get("event", ""))
            if allowed and evt_str not in allowed:
                print(f"[WARN] Unknown event '{evt_str}' for {type_key} '{element_name}'. Known: {', '.join(allowed)}")

    X(f"{indent}<Events>")
    handlers_map = el.get("handlers", {}) or {}
    for evt in on_list:
        if isinstance(evt, str):
            evt_name = evt
            handler = handlers_map.get(evt_name) or get_handler_name(element_name, evt_name)
            X(f'{indent}\t<Event name="{evt_name}">{handler}</Event>')
        elif not evt.get("event"):
            evt_name = str(evt)
            handler = handlers_map.get(evt_name) or get_handler_name(element_name, evt_name)
            X(f'{indent}\t<Event name="{evt_name}">{handler}</Event>')
        else:
            evt_name = str(evt["event"])
            handler = evt.get("handler") or handlers_map.get(evt_name) or get_handler_name(element_name, evt_name)
            call_type_attr = f' callType="{evt["callType"]}"' if evt.get("callType") else ""
            X(f'{indent}\t<Event name="{evt_name}"{call_type_attr}>{handler}</Event>')
    X(f"{indent}</Events>")


def emit_companion(tag, name, indent):
    _id = new_id()
    X(f'{indent}<{tag} name="{name}" id="{_id}"/>')


def emit_common_flags(el, indent):
    if el.get("visible") is False or el.get("hidden") is True:
        X(f"{indent}<Visible>false</Visible>")
    if el.get("enabled") is False or el.get("disabled") is True:
        X(f"{indent}<Enabled>false</Enabled>")
    if el.get("readOnly") is True:
        X(f"{indent}<ReadOnly>true</ReadOnly>")


def emit_title(el, name, indent):
    if el.get("title"):
        emit_mltext("Title", str(el["title"]), indent)


# --- Element emitters ---

def emit_group(el, name, _id, indent):
    X(f'{indent}<UsualGroup name="{name}" id="{_id}">')
    inner = indent + "\t"
    emit_title(el, name, inner)
    group_val = str(el.get("group", ""))
    orientation_map = {"horizontal": "Horizontal", "vertical": "Vertical", "alwaysHorizontal": "AlwaysHorizontal", "alwaysVertical": "AlwaysVertical"}
    orientation = orientation_map.get(group_val)
    if orientation:
        X(f"{inner}<Group>{orientation}</Group>")
    if group_val == "collapsible":
        X(f"{inner}<Group>Vertical</Group>")
        X(f"{inner}<Behavior>Collapsible</Behavior>")
    if el.get("representation"):
        repr_map = {"none": "None", "normal": "NormalSeparation", "weak": "WeakSeparation", "strong": "StrongSeparation"}
        repr_val = repr_map.get(str(el["representation"]), str(el["representation"]))
        X(f"{inner}<Representation>{repr_val}</Representation>")
    if el.get("showTitle") is False:
        X(f"{inner}<ShowTitle>false</ShowTitle>")
    if el.get("united") is False:
        X(f"{inner}<United>false</United>")
    emit_common_flags(el, inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    children = el.get("children")
    if children and len(children) > 0:
        X(f"{inner}<ChildItems>")
        for child in children:
            emit_element(child, inner + "\t")
        X(f"{inner}</ChildItems>")
    X(f"{indent}</UsualGroup>")


def emit_input(el, name, _id, indent):
    X(f'{indent}<InputField name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("path"):
        X(f"{inner}<DataPath>{el['path']}</DataPath>")
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("titleLocation"):
        loc_map = {"none": "None", "left": "Left", "right": "Right", "top": "Top", "bottom": "Bottom"}
        loc = loc_map.get(str(el["titleLocation"]), str(el["titleLocation"]))
        X(f"{inner}<TitleLocation>{loc}</TitleLocation>")
    if el.get("multiLine") is True:
        X(f"{inner}<MultiLine>true</MultiLine>")
    if el.get("passwordMode") is True:
        X(f"{inner}<PasswordMode>true</PasswordMode>")
    if el.get("choiceButton") is False:
        X(f"{inner}<ChoiceButton>false</ChoiceButton>")
    if el.get("clearButton") is True:
        X(f"{inner}<ClearButton>true</ClearButton>")
    if el.get("spinButton") is True:
        X(f"{inner}<SpinButton>true</SpinButton>")
    if el.get("dropListButton") is True:
        X(f"{inner}<DropListButton>true</DropListButton>")
    if el.get("markIncomplete") is True:
        X(f"{inner}<AutoMarkIncomplete>true</AutoMarkIncomplete>")
    if el.get("skipOnInput") is True:
        X(f"{inner}<SkipOnInput>true</SkipOnInput>")
    if el.get("autoMaxWidth") is False:
        X(f"{inner}<AutoMaxWidth>false</AutoMaxWidth>")
    if el.get("autoMaxHeight") is False:
        X(f"{inner}<AutoMaxHeight>false</AutoMaxHeight>")
    if el.get("width"):
        X(f"{inner}<Width>{el['width']}</Width>")
    if el.get("height"):
        X(f"{inner}<Height>{el['height']}</Height>")
    if el.get("horizontalStretch") is True:
        X(f"{inner}<HorizontalStretch>true</HorizontalStretch>")
    if el.get("verticalStretch") is True:
        X(f"{inner}<VerticalStretch>true</VerticalStretch>")
    if el.get("inputHint"):
        emit_mltext("InputHint", str(el["inputHint"]), inner)
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "input")
    X(f"{indent}</InputField>")


def emit_check(el, name, _id, indent):
    X(f'{indent}<CheckBoxField name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("path"):
        X(f"{inner}<DataPath>{el['path']}</DataPath>")
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("titleLocation"):
        X(f"{inner}<TitleLocation>{el['titleLocation']}</TitleLocation>")
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "check")
    X(f"{indent}</CheckBoxField>")


def emit_label(el, name, _id, indent):
    X(f'{indent}<LabelDecoration name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("title"):
        formatted = "true" if el.get("hyperlink") is True else "false"
        X(f'{inner}<Title formatted="{formatted}">')
        X(f"{inner}\t<v8:item>")
        X(f"{inner}\t\t<v8:lang>ru</v8:lang>")
        X(f"{inner}\t\t<v8:content>{esc_xml(str(el['title']))}</v8:content>")
        X(f"{inner}\t</v8:item>")
        X(f"{inner}</Title>")
    emit_common_flags(el, inner)
    if el.get("hyperlink") is True:
        X(f"{inner}<Hyperlink>true</Hyperlink>")
    if el.get("autoMaxWidth") is False:
        X(f"{inner}<AutoMaxWidth>false</AutoMaxWidth>")
    if el.get("autoMaxHeight") is False:
        X(f"{inner}<AutoMaxHeight>false</AutoMaxHeight>")
    if el.get("width"):
        X(f"{inner}<Width>{el['width']}</Width>")
    if el.get("height"):
        X(f"{inner}<Height>{el['height']}</Height>")
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "label")
    X(f"{indent}</LabelDecoration>")


def emit_label_field(el, name, _id, indent):
    X(f'{indent}<LabelField name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("path"):
        X(f"{inner}<DataPath>{el['path']}</DataPath>")
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("hyperlink") is True:
        X(f"{inner}<Hyperlink>true</Hyperlink>")
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "labelField")
    X(f"{indent}</LabelField>")


def emit_table(el, name, _id, indent):
    X(f'{indent}<Table name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("path"):
        X(f"{inner}<DataPath>{el['path']}</DataPath>")
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("representation"):
        X(f"{inner}<Representation>{el['representation']}</Representation>")
    if el.get("changeRowSet") is True:
        X(f"{inner}<ChangeRowSet>true</ChangeRowSet>")
    if el.get("changeRowOrder") is True:
        X(f"{inner}<ChangeRowOrder>true</ChangeRowOrder>")
    if el.get("height"):
        X(f"{inner}<HeightInTableRows>{el['height']}</HeightInTableRows>")
    if el.get("header") is False:
        X(f"{inner}<Header>false</Header>")
    if el.get("footer") is True:
        X(f"{inner}<Footer>true</Footer>")
    if el.get("commandBarLocation"):
        X(f"{inner}<CommandBarLocation>{el['commandBarLocation']}</CommandBarLocation>")
    if el.get("searchStringLocation"):
        X(f"{inner}<SearchStringLocation>{el['searchStringLocation']}</SearchStringLocation>")
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("AutoCommandBar", f"{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c", inner)
    emit_companion("SearchStringAddition", f"{name}\u0421\u0442\u0440\u043e\u043a\u0430\u041f\u043e\u0438\u0441\u043a\u0430", inner)
    emit_companion("ViewStatusAddition", f"{name}\u0421\u043e\u0441\u0442\u043e\u044f\u043d\u0438\u0435\u041f\u0440\u043e\u0441\u043c\u043e\u0442\u0440\u0430", inner)
    emit_companion("SearchControlAddition", f"{name}\u0423\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u0438\u0435\u041f\u043e\u0438\u0441\u043a\u043e\u043c", inner)
    columns = el.get("columns")
    if columns and len(columns) > 0:
        X(f"{inner}<ChildItems>")
        for col in columns:
            emit_element(col, inner + "\t")
        X(f"{inner}</ChildItems>")
    emit_events(el, name, inner, "table")
    X(f"{indent}</Table>")


def emit_pages(el, name, _id, indent):
    X(f'{indent}<Pages name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("pagesRepresentation"):
        X(f"{inner}<PagesRepresentation>{el['pagesRepresentation']}</PagesRepresentation>")
    emit_common_flags(el, inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "pages")
    children = el.get("children")
    if children and len(children) > 0:
        X(f"{inner}<ChildItems>")
        for child in children:
            emit_element(child, inner + "\t")
        X(f"{inner}</ChildItems>")
    X(f"{indent}</Pages>")


def emit_page(el, name, _id, indent):
    X(f'{indent}<Page name="{name}" id="{_id}">')
    inner = indent + "\t"
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("group"):
        orientation_map = {"horizontal": "Horizontal", "vertical": "Vertical", "alwaysHorizontal": "AlwaysHorizontal", "alwaysVertical": "AlwaysVertical"}
        orientation = orientation_map.get(str(el["group"]))
        if orientation:
            X(f"{inner}<Group>{orientation}</Group>")
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    children = el.get("children")
    if children and len(children) > 0:
        X(f"{inner}<ChildItems>")
        for child in children:
            emit_element(child, inner + "\t")
        X(f"{inner}</ChildItems>")
    X(f"{indent}</Page>")


def emit_button(el, name, _id, indent):
    X(f'{indent}<Button name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("type"):
        btn_map = {"usual": "UsualButton", "hyperlink": "Hyperlink", "commandBar": "CommandBarButton"}
        btn_type = btn_map.get(str(el["type"]), str(el["type"]))
        X(f"{inner}<Type>{btn_type}</Type>")
    if el.get("command"):
        X(f"{inner}<CommandName>Form.Command.{el['command']}</CommandName>")
    if el.get("stdCommand"):
        sc = str(el["stdCommand"])
        m = re.match(r'^(.+)\.(.+)$', sc)
        if m:
            X(f"{inner}<CommandName>Form.Item.{m.group(1)}.StandardCommand.{m.group(2)}</CommandName>")
        else:
            X(f"{inner}<CommandName>Form.StandardCommand.{sc}</CommandName>")
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("defaultButton") is True:
        X(f"{inner}<DefaultButton>true</DefaultButton>")
    if el.get("picture"):
        X(f"{inner}<Picture>")
        X(f"{inner}\t<xr:Ref>{el['picture']}</xr:Ref>")
        X(f"{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>")
        X(f"{inner}</Picture>")
    if el.get("representation"):
        X(f"{inner}<Representation>{el['representation']}</Representation>")
    if el.get("locationInCommandBar"):
        X(f"{inner}<LocationInCommandBar>{el['locationInCommandBar']}</LocationInCommandBar>")
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "button")
    X(f"{indent}</Button>")


def emit_picture_decoration(el, name, _id, indent):
    X(f'{indent}<PictureDecoration name="{name}" id="{_id}">')
    inner = indent + "\t"
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    ref = el.get("src") or el.get("picture")
    if ref:
        X(f"{inner}<Picture>")
        X(f"{inner}\t<xr:Ref>{ref}</xr:Ref>")
        X(f"{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>")
        X(f"{inner}</Picture>")
    if el.get("hyperlink") is True:
        X(f"{inner}<Hyperlink>true</Hyperlink>")
    if el.get("width"):
        X(f"{inner}<Width>{el['width']}</Width>")
    if el.get("height"):
        X(f"{inner}<Height>{el['height']}</Height>")
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "picture")
    X(f"{indent}</PictureDecoration>")


def emit_picture_field(el, name, _id, indent):
    X(f'{indent}<PictureField name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("path"):
        X(f"{inner}<DataPath>{el['path']}</DataPath>")
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("width"):
        X(f"{inner}<Width>{el['width']}</Width>")
    if el.get("height"):
        X(f"{inner}<Height>{el['height']}</Height>")
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "picField")
    X(f"{indent}</PictureField>")


def emit_calendar(el, name, _id, indent):
    X(f'{indent}<CalendarField name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("path"):
        X(f"{inner}<DataPath>{el['path']}</DataPath>")
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    emit_companion("ContextMenu", f"{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e", inner)
    emit_companion("ExtendedTooltip", f"{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430", inner)
    emit_events(el, name, inner, "calendar")
    X(f"{indent}</CalendarField>")


def emit_command_bar_el(el, name, _id, indent):
    X(f'{indent}<CommandBar name="{name}" id="{_id}">')
    inner = indent + "\t"
    if el.get("autofill") is True:
        X(f"{inner}<Autofill>true</Autofill>")
    emit_common_flags(el, inner)
    children = el.get("children")
    if children and len(children) > 0:
        X(f"{inner}<ChildItems>")
        for child in children:
            emit_element(child, inner + "\t")
        X(f"{inner}</ChildItems>")
    X(f"{indent}</CommandBar>")


def emit_popup(el, name, _id, indent):
    X(f'{indent}<Popup name="{name}" id="{_id}">')
    inner = indent + "\t"
    emit_title(el, name, inner)
    emit_common_flags(el, inner)
    if el.get("picture"):
        X(f"{inner}<Picture>")
        X(f"{inner}\t<xr:Ref>{el['picture']}</xr:Ref>")
        X(f"{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>")
        X(f"{inner}</Picture>")
    if el.get("representation"):
        X(f"{inner}<Representation>{el['representation']}</Representation>")
    children = el.get("children")
    if children and len(children) > 0:
        X(f"{inner}<ChildItems>")
        for child in children:
            emit_element(child, inner + "\t")
        X(f"{inner}</ChildItems>")
    X(f"{indent}</Popup>")


# --- Element dispatcher ---

ELEMENT_KEYS = ["group", "input", "check", "label", "labelField", "table", "pages", "page", "button", "picture", "picField", "calendar", "cmdBar", "popup"]

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
    "hyperlink", "showTitle", "united", "children", "columns",
    "changeRowSet", "changeRowOrder", "header", "footer",
    "commandBarLocation", "searchStringLocation", "pagesRepresentation",
    "type", "command", "stdCommand", "defaultButton", "locationInCommandBar",
    "src", "autofill",
}

EMITTER_MAP = {
    "group": emit_group,
    "input": emit_input,
    "check": emit_check,
    "label": emit_label,
    "labelField": emit_label_field,
    "table": emit_table,
    "pages": emit_pages,
    "page": emit_page,
    "button": emit_button,
    "picture": emit_picture_decoration,
    "picField": emit_picture_field,
    "calendar": emit_calendar,
    "cmdBar": emit_command_bar_el,
    "popup": emit_popup,
}


def emit_element(el, indent):
    type_key = None
    for key in ELEMENT_KEYS:
        if key in el and el[key] is not None:
            type_key = key
            break
    if not type_key:
        print("[WARN] Unknown element type, skipping")
        return

    # Validate known keys
    for p in el:
        if p not in KNOWN_KEYS:
            print(f"[WARN] Element '{el[type_key]}': unknown key '{p}' -- ignored.")

    name = get_element_name(el, type_key)
    _id = new_id()

    emitter = EMITTER_MAP.get(type_key)
    if emitter:
        emitter(el, name, _id, indent)


# ── 6. Find element by name recursively ─────────────────────

def find_element(start_node, target_name):
    for child in start_node:
        if not isinstance(child.tag, str):
            continue
        child_name = child.get("name")
        if child_name == target_name:
            return child
        ci = child.find("f:ChildItems", NS)
        if ci is not None:
            found = find_element(ci, target_name)
            if found is not None:
                return found
    return None


# ── 7. Detect indent level of a container's children ────────

def get_child_indent(container):
    for child_node in container:
        if not isinstance(child_node.tag, str):
            # text nodes - check preceding/following text
            pass
    # Check text content of container (tail/text)
    for i, child in enumerate(container):
        # Check text before this child
        if i == 0:
            txt = container.text
        else:
            txt = container[i - 1].tail
        if txt:
            m = re.search(r'\n(\t+)$', txt)
            if m:
                return m.group(1)

    # Fallback: count depth from root
    depth = 0
    current = container
    while current is not None:
        parent = current.getparent()
        if parent is None:
            break
        depth += 1
        current = parent
    return "\t" * (depth + 1)


# ── 8. Insert node into container ───────────────────────────

def insert_into_container(container, new_node, after_name, child_indent):
    ref_idx = None

    if after_name:
        # Find the after-element
        after_elem = None
        for i, child in enumerate(container):
            if isinstance(child.tag, str) and child.get("name") == after_name:
                after_elem = child
                ref_idx = i + 1
                break
        if after_elem is None:
            print(f"[WARN] after='{after_name}' not found in target container, appending at end")

    children = list(container)
    if ref_idx is not None:
        # Insert after the after-element
        if ref_idx < len(children):
            children[ref_idx - 1].tail = "\n" + child_indent
            children[ref_idx - 1].addnext(new_node)
            new_node.tail = "\n" + child_indent
        else:
            # Append at end
            if len(children) > 0:
                children[-1].tail = "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent
    else:
        # Append at end
        if len(children) > 0:
            # Insert before trailing whitespace (append after last child)
            children[-1].tail = "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent
        else:
            # Container is empty
            container.text = "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent


# ── 9. Generate fragment, parse, import nodes ────────────────

def parse_fragment(xml_text):
    frag_parser = etree.XMLParser(remove_blank_text=False)
    frag_doc = etree.fromstring(xml_text.encode("utf-8"), frag_parser)
    return frag_doc


def import_element_nodes(frag_root):
    nodes = []
    for child in frag_root:
        if isinstance(child.tag, str):
            nodes.append(child)
    return nodes


# ── 10. Add elements ────────────────────────────────────────

added_elems = []
companion_count = 0

elements_list = defn.get("elements") or []
if elements_list:
    # Resolve target container
    target_ci = None
    into_name = defn.get("into")
    after_name = defn.get("after")

    if into_name:
        target_group = find_element(root_ci, into_name)
        if target_group is None:
            print(f"[ERROR] Target group '{into_name}' not found")
            sys.exit(1)
        target_ci = target_group.find("f:ChildItems", NS)
        if target_ci is None:
            # Create ChildItems for the group
            target_ci = etree.SubElement(target_group, f"{{{FORM_NS}}}ChildItems")
    elif after_name:
        after_elem = find_element(root_ci, after_name)
        if after_elem is None:
            print(f"[ERROR] Element '{after_name}' not found")
            sys.exit(1)
        target_ci = after_elem.getparent()
    else:
        target_ci = root_ci

    if target_ci is None:
        # Create ChildItems section in form
        target_ci = etree.SubElement(root, f"{{{FORM_NS}}}ChildItems")
        root_ci = target_ci

    # Detect indent level
    child_indent = get_child_indent(target_ci)

    # Check for duplicate element names
    for el in elements_list:
        type_key = None
        for key in ELEMENT_KEYS:
            if key in el and el[key] is not None:
                type_key = key
                break
        if type_key:
            el_name = get_element_name(el, type_key)
            existing = find_element(root_ci, el_name) if root_ci is not None else None
            if existing is not None:
                print(f"[WARN] Element '{el_name}' already exists in form (id={existing.get('id')})")

    # Remember starting element ID for companion counting
    start_elem_id = next_elem_id

    # Generate fragment
    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    for el in elements_list:
        emit_element(el, child_indent)
    X("</_F>")

    frag_text = "\n".join(xml_lines)
    frag_root = parse_fragment(frag_text)
    imported_nodes = import_element_nodes(frag_root)

    # Count actual elements for reporting
    tag_map = {
        "group": "Group", "input": "Input", "check": "Check", "label": "Label", "labelField": "LabelField",
        "table": "Table", "pages": "Pages", "page": "Page", "button": "Button",
        "picture": "Picture", "picField": "PicField", "calendar": "Calendar", "cmdBar": "CmdBar", "popup": "Popup",
    }
    for el in elements_list:
        type_key = None
        for key in ELEMENT_KEYS:
            if key in el and el[key] is not None:
                type_key = key
                break
        name = get_element_name(el, type_key)
        path_str = f" -> {el['path']}" if el.get("path") else ""
        on_list = el.get("on")
        evt_str = f" {{{', '.join(str(e) for e in on_list)}}}" if on_list else ""
        added_elems.append(f"  + [{tag_map.get(type_key, type_key)}] {name}{path_str}{evt_str}")

    # Insert each imported node
    for node in imported_nodes:
        insert_into_container(target_ci, node, after_name, child_indent)
        after_name = node.get("name")

    total_new_elem_ids = next_elem_id - start_elem_id
    companion_count = total_new_elem_ids - len(elements_list)

# ── 11. Add attributes ──────────────────────────────────────

added_attrs = []

attrs_list = defn.get("attributes") or []
if attrs_list:
    attrs_section = root.find("f:Attributes", NS)
    if attrs_section is None:
        attrs_section = etree.SubElement(root, f"{{{FORM_NS}}}Attributes")

    attr_child_indent = get_child_indent(attrs_section)
    if not attr_child_indent:
        attr_child_indent = "\t\t"

    # Generate attribute fragments
    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    for attr in attrs_list:
        attr_id = new_attr_id()
        attr_name = str(attr["name"])
        X(f'{attr_child_indent}<Attribute name="{attr_name}" id="{attr_id}">')
        inner = attr_child_indent + "\t"

        if attr.get("title"):
            emit_mltext("Title", str(attr["title"]), inner)
        if attr.get("type"):
            emit_type(str(attr["type"]), inner)
        else:
            X(f"{inner}<Type/>")
        if attr.get("main") is True:
            X(f"{inner}<MainAttribute>true</MainAttribute>")
        if attr.get("savedData") is True:
            X(f"{inner}<SavedData>true</SavedData>")
        if attr.get("fillChecking"):
            X(f"{inner}<FillChecking>{attr['fillChecking']}</FillChecking>")

        columns = attr.get("columns")
        if columns and len(columns) > 0:
            X(f"{inner}<Columns>")
            col_id = 1
            for col in columns:
                X(f'{inner}\t<Column name="{col["name"]}" id="{col_id}">')
                if col.get("title"):
                    emit_mltext("Title", str(col["title"]), inner + "\t\t")
                emit_type(str(col["type"]), inner + "\t\t")
                X(f'{inner}\t</Column>')
                col_id += 1
            X(f"{inner}</Columns>")

        X(f"{attr_child_indent}</Attribute>")
        type_str = str(attr["type"]) if attr.get("type") else "(no type)"
        added_attrs.append(f"  + {attr_name}: {type_str} (id={attr_id})")
    X("</_F>")

    frag_text = "\n".join(xml_lines)
    frag_root = parse_fragment(frag_text)
    imported_attrs = import_element_nodes(frag_root)

    for node in imported_attrs:
        insert_into_container(attrs_section, node, None, attr_child_indent)

# ── 12. Add commands ────────────────────────────────────────

added_cmds = []

cmds_list = defn.get("commands") or []
if cmds_list:
    cmds_section = root.find("f:Commands", NS)
    if cmds_section is None:
        cmds_section = etree.SubElement(root, f"{{{FORM_NS}}}Commands")

    cmd_child_indent = get_child_indent(cmds_section)
    if not cmd_child_indent:
        cmd_child_indent = "\t\t"

    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    for cmd in cmds_list:
        cmd_id = new_cmd_id()
        cmd_name = str(cmd["name"])
        X(f'{cmd_child_indent}<Command name="{cmd_name}" id="{cmd_id}">')
        inner = cmd_child_indent + "\t"

        if cmd.get("title"):
            emit_mltext("Title", str(cmd["title"]), inner)

        if cmd.get("actions"):
            for act in cmd["actions"]:
                act_handler = str(act["handler"])
                call_type_attr = f' callType="{act["callType"]}"' if act.get("callType") else ""
                X(f"{inner}<Action{call_type_attr}>{act_handler}</Action>")
        elif cmd.get("action"):
            call_type_attr = f' callType="{cmd["callType"]}"' if cmd.get("callType") else ""
            X(f"{inner}<Action{call_type_attr}>{cmd['action']}</Action>")

        if cmd.get("shortcut"):
            X(f"{inner}<Shortcut>{cmd['shortcut']}</Shortcut>")
        if cmd.get("picture"):
            X(f"{inner}<Picture>")
            X(f"{inner}\t<xr:Ref>{cmd['picture']}</xr:Ref>")
            X(f"{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>")
            X(f"{inner}</Picture>")
        if cmd.get("representation"):
            X(f"{inner}<Representation>{cmd['representation']}</Representation>")

        X(f"{cmd_child_indent}</Command>")
        action_str = ""
        if cmd.get("action"):
            action_str = f" -> {cmd['action']}"
        elif cmd.get("actions"):
            action_str = f" -> {len(cmd['actions'])} action(s)"
        added_cmds.append(f"  + {cmd_name}{action_str} (id={cmd_id})")
    X("</_F>")

    frag_text = "\n".join(xml_lines)
    frag_root = parse_fragment(frag_text)
    imported_cmds = import_element_nodes(frag_root)

    for node in imported_cmds:
        insert_into_container(cmds_section, node, None, cmd_child_indent)

# ── 12b. Add form-level events ──────────────────────────────

added_form_events = []

form_events_list = defn.get("formEvents") or []
if form_events_list:
    events_section = root.find("f:Events", NS)
    if events_section is None:
        events_section = etree.SubElement(root, f"{{{FORM_NS}}}Events")

    evt_child_indent = get_child_indent(events_section)
    if not evt_child_indent:
        evt_child_indent = "\t\t"

    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    for fe in form_events_list:
        fe_name = str(fe["name"])
        fe_handler = str(fe["handler"])
        call_type_attr = f' callType="{fe["callType"]}"' if fe.get("callType") else ""
        X(f'{evt_child_indent}<Event name="{fe_name}"{call_type_attr}>{fe_handler}</Event>')
        ct_str = f"[{fe['callType']}]" if fe.get("callType") else ""
        added_form_events.append(f"  + {fe_name}{ct_str} -> {fe_handler}")
    X("</_F>")

    frag_text = "\n".join(xml_lines)
    frag_root = parse_fragment(frag_text)
    imported_events = import_element_nodes(frag_root)

    for node in imported_events:
        insert_into_container(events_section, node, None, evt_child_indent)

# ── 12c. Add element-level events ───────────────────────────

added_elem_events = []

elem_events_list = defn.get("elementEvents") or []
if elem_events_list:
    if root_ci is None:
        root_ci = root.find("f:ChildItems", NS)

    for ee in elem_events_list:
        target_name = str(ee["element"])
        target_el = find_element(root_ci, target_name)
        if target_el is None:
            print(f"[WARN] Element '{target_name}' not found -- skipping elementEvent")
            continue

        # Find or create Events element within the target
        target_events = target_el.find("f:Events", NS)
        if target_events is None:
            target_events = etree.SubElement(target_el, f"{{{FORM_NS}}}Events")

        ee_child_indent = get_child_indent(target_events)
        if not ee_child_indent:
            parent_indent = get_child_indent(target_el)
            ee_child_indent = parent_indent + "\t"

        ee_name = str(ee["name"])
        ee_handler = str(ee["handler"])
        call_type_attr = f' callType="{ee["callType"]}"' if ee.get("callType") else ""

        xml_lines.clear()
        X(f"<_F {ALL_NS_DECL}>")
        X(f'{ee_child_indent}<Event name="{ee_name}"{call_type_attr}>{ee_handler}</Event>')
        X("</_F>")

        frag_text = "\n".join(xml_lines)
        frag_root = parse_fragment(frag_text)
        imported_ee = import_element_nodes(frag_root)

        for node in imported_ee:
            insert_into_container(target_events, node, None, ee_child_indent)

        ct_str = f"[{ee['callType']}]" if ee.get("callType") else ""
        added_elem_events.append(f"  + {target_name}.{ee_name}{ct_str} -> {ee_handler}")

# ── 13. Save ────────────────────────────────────────────────

xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
# Fix encoding declaration case
xml_bytes = xml_bytes.replace(b"encoding='UTF-8'", b'encoding="UTF-8"')
# Write with BOM
with open(resolved_form_path, "wb") as f:
    f.write(b'\xef\xbb\xbf')
    f.write(xml_bytes)

# ── 14. Summary ─────────────────────────────────────────────

if is_extension:
    print("[EXTENSION] BaseForm detected -- IDs start at 1000000+")
    print()

if added_form_events:
    print("Added form events:")
    for line in added_form_events:
        print(line)
    print()

if added_elem_events:
    print("Added element events:")
    for line in added_elem_events:
        print(line)
    print()

if added_elems:
    pos_str = ""
    if defn.get("into"):
        pos_str += f"into {defn['into']}"
    if defn.get("after"):
        if pos_str:
            pos_str += ", "
        pos_str += f"after {defn['after']}"
    if pos_str:
        pos_str = f" ({pos_str})"
    print(f"Added elements{pos_str}:")
    for line in added_elems:
        print(line)
    print()

if added_attrs:
    print("Added attributes:")
    for line in added_attrs:
        print(line)
    print()

if added_cmds:
    print("Added commands:")
    for line in added_cmds:
        print(line)
    print()

print("---")
total_parts = []
if added_form_events:
    total_parts.append(f"{len(added_form_events)} form event(s)")
if added_elem_events:
    total_parts.append(f"{len(added_elem_events)} element event(s)")
if added_elems:
    comp_str = f" (+{companion_count} companions)" if companion_count > 0 else ""
    total_parts.append(f"{len(added_elems)} element(s){comp_str}")
if added_attrs:
    total_parts.append(f"{len(added_attrs)} attribute(s)")
if added_cmds:
    total_parts.append(f"{len(added_cmds)} command(s)")
print(f"Total: {', '.join(total_parts)}")
print("Run /form-validate to verify.")
