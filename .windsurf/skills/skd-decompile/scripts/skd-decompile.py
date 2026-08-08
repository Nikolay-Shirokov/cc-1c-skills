#!/usr/bin/env python3
# skd-decompile v0.91 — Decompile 1C DCS Template.xml to JSON DSL (draft)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET

# --- 1. Namespace manager ---

NS_SCHEMA = "http://v8.1c.ru/8.1/data-composition-system/schema"
NS_COM    = "http://v8.1c.ru/8.1/data-composition-system/common"
NS_COR    = "http://v8.1c.ru/8.1/data-composition-system/core"
NS_SET    = "http://v8.1c.ru/8.1/data-composition-system/settings"
NS_AT     = "http://v8.1c.ru/8.1/data-composition-system/area-template"
NS_V8     = "http://v8.1c.ru/8.1/data/core"
NS_V8UI   = "http://v8.1c.ru/8.1/data/ui"
NS_XS     = "http://www.w3.org/2001/XMLSchema"
NS_XSI    = "http://www.w3.org/2001/XMLSchema-instance"
NS_CFG    = "http://v8.1c.ru/8.1/data/enterprise/current-config"

NS_PREFIX_MAP = {
    'r':      NS_SCHEMA,
    'dcscom': NS_COM,
    'dcscor': NS_COR,
    'dcsset': NS_SET,
    'dcsat':  NS_AT,
    'v8':     NS_V8,
    'v8ui':   NS_V8UI,
    'xs':     NS_XS,
    'xsi':    NS_XSI,
}

_NSMAP_BY_ID = {}  # id(Element) -> dict[prefix, uri] of locally declared xmlns


def _get_nsmap(el):
    return _NSMAP_BY_ID.get(id(el), {})


# Element wrapper: holds ET element + per-element prefix→uri map (inherited).
class XNode:
    __slots__ = ('el', 'nsmap', 'parent')

    def __init__(self, el, nsmap, parent=None):
        self.el = el
        self.nsmap = nsmap  # dict: prefix → uri (in scope)
        self.parent = parent

    def __bool__(self):
        return self.el is not None

    @property
    def local_name(self):
        t = self.el.tag
        if '}' in t:
            return t.split('}', 1)[1]
        return t

    @property
    def namespace_uri(self):
        t = self.el.tag
        if t.startswith('{'):
            return t[1:].split('}', 1)[0]
        return ''

    @property
    def inner_text(self):
        # Concatenate all text content (mirror PS InnerText)
        return _inner_text(self.el)

    @property
    def has_child_nodes(self):
        return len(self.el) > 0 or (self.el.text is not None and self.el.text != '')

    @property
    def child_nodes(self):
        for sub in self.el:
            yield XNode(sub, _merged_nsmap(self.nsmap, sub), self)

    def get_namespace_of_prefix(self, prefix):
        return self.nsmap.get(prefix)

    def get_attribute(self, name, ns_uri=None):
        if ns_uri:
            v = self.el.get('{%s}%s' % (ns_uri, name))
            return v if v is not None else ''
        # No namespace — try plain
        v = self.el.get(name)
        return v if v is not None else ''

    def get_attr_raw(self, qname):
        # qname like "xsi:type" — get raw attribute by qname value (we need to lookup ns)
        if ':' in qname:
            pfx, local = qname.split(':', 1)
            uri = self.nsmap.get(pfx)
            if uri:
                v = self.el.get('{%s}%s' % (uri, local))
                if v is not None:
                    return v
            return None
        v = self.el.get(qname)
        return v

    def select_single_node(self, xpath):
        return _xpath_single(self, xpath)

    def select_nodes(self, xpath):
        return _xpath_all(self, xpath)


# Build nsmap from xmlns attributes on the element + parent inheritance.
def _merged_nsmap(parent_map, el):
    nsmap = dict(parent_map)
    # ET parsed elements lose xmlns attrs but expose tag namespaces via {uri}.
    # We pre-populate via iterparse — see parse_xml below.
    extra = _get_nsmap(el)
    if extra:
        nsmap.update(extra)
    return nsmap


def _inner_text(el):
    # All text content concatenated
    parts = []
    if el.text:
        parts.append(el.text)
    for child in el:
        parts.append(_inner_text(child))
        if child.tail:
            parts.append(child.tail)
    return ''.join(parts)


def parse_xml(path):
    # Use iterparse to capture start-ns events and attach nsmap to each element.
    ns_stack = [{}]
    pending_ns = {}
    root = None
    parents_stack = []
    parser = ET.iterparse(path, events=('start', 'end', 'start-ns'))
    for event, item in parser:
        if event == 'start-ns':
            prefix, uri = item
            pending_ns[prefix if prefix else ''] = uri
        elif event == 'start':
            # item is the element
            if pending_ns:
                _NSMAP_BY_ID[id(item)] = pending_ns
                pending_ns = {}
            else:
                _NSMAP_BY_ID[id(item)] = {}
            if root is None:
                root = item
        elif event == 'end':
            pass
    return root


# XPath translator: parse PS-style XPath like "r:name", "dcsset:item", "dcsset:item[@xsi:type='dcsset:TableRow']"
# Returns list of (axis, pred) tokens. axis = ('child', uri, local) or ('descendant', uri, local).
def _xpath_steps(xpath):
    # Split by '/' but not inside [] — predicates here don't include /.
    steps = []
    parts = xpath.split('/')
    i = 0
    while i < len(parts):
        p = parts[i]
        if p == '':
            # '//' → next part is descendant
            i += 1
            if i < len(parts):
                steps.append(('descendant', parts[i]))
            i += 1
            continue
        steps.append(('child', p))
        i += 1
    return steps


def _step_match(step_text):
    # Returns (qname, predicate)
    pred = None
    m = re.match(r'^([^\[]+)(\[.+\])?$', step_text)
    if not m:
        return step_text, None
    qname = m.group(1)
    pred = m.group(2)
    return qname, pred


def _qname_to_tag(qname, nsmap):
    # qname: "prefix:local" or "*[local-name()='x']" handling
    if qname == '*':
        return None, None
    # Wildcard with local-name predicate handled by caller
    if ':' in qname:
        pfx, local = qname.split(':', 1)
        uri = nsmap.get(pfx)
        if uri:
            return uri, local
        return None, local
    return None, qname


def _check_predicate(node, pred):
    if not pred:
        return True
    # Only support [@xsi:type='value'] form
    m = re.match(r"^\[@([^=]+)=['\"]([^'\"]+)['\"]\]$", pred)
    if m:
        attr = m.group(1)
        expected = m.group(2)
        actual = node.get_attr_raw(attr)
        if actual is None:
            return False
        return actual == expected
    # Fallback: ignore unknown predicates (treat as match)
    return True


def _xpath_all(node, xpath):
    steps = _xpath_steps(xpath)
    current = [node]
    for axis, step_text in steps:
        qname, pred = _step_match(step_text)
        next_nodes = []
        # Handle local-name() form
        if qname.startswith("*[local-name()="):
            mlc = re.match(r"^\*\[local-name\(\)=['\"]([^'\"]+)['\"]\]$", qname)
            target_local = mlc.group(1) if mlc else None
            for n in current:
                if axis == 'child':
                    for child in n.el:
                        wrapped = XNode(child, _merged_nsmap(n.nsmap, child), n)
                        if wrapped.local_name == target_local and _check_predicate(wrapped, pred):
                            next_nodes.append(wrapped)
                else:  # descendant
                    for child in n.el.iter():
                        if child is n.el:
                            continue
                        wrapped = XNode(child, _merged_nsmap(n.nsmap, child), n)
                        if wrapped.local_name == target_local and _check_predicate(wrapped, pred):
                            next_nodes.append(wrapped)
            current = next_nodes
            continue

        uri, local = _qname_to_tag(qname, node.nsmap)
        for n in current:
            if axis == 'child':
                children_iter = list(n.el)
            else:
                children_iter = [c for c in n.el.iter() if c is not n.el]
            for child in children_iter:
                wrapped = XNode(child, _merged_nsmap(n.nsmap, child), n)
                # Match local + uri
                if wrapped.local_name != local:
                    continue
                if uri is not None and wrapped.namespace_uri != uri:
                    continue
                if not _check_predicate(wrapped, pred):
                    continue
                next_nodes.append(wrapped)
        current = next_nodes
    return current


def _xpath_single(node, xpath):
    res = _xpath_all(node, xpath)
    if res:
        return res[0]
    return None


# --- 0. Resolve and validate input ---

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Decompile 1C DCS Template.xml to JSON DSL', allow_abbrev=False)
    parser.add_argument('-TemplatePath', '-Path', dest='TemplatePath', type=str, required=True)
    parser.add_argument('-OutputPath', type=str, default=None)
    args = parser.parse_args()

    global TemplatePath, OutputPath
    TemplatePath = args.TemplatePath
    OutputPath = args.OutputPath

    if not os.path.exists(TemplatePath):
        print(f"Template not found: {TemplatePath}", file=sys.stderr)
        sys.exit(1)

    TemplatePath = os.path.abspath(TemplatePath)

    _NSMAP_BY_ID.clear()
    root_el = parse_xml(TemplatePath)
    root = XNode(root_el, dict(_get_nsmap(root_el)), None)

    # Ring 3: not a DataCompositionSchema → fail-fast
    if root.local_name != 'DataCompositionSchema':
        print(f"skd-decompile: корневой элемент <{root.local_name}> не <DataCompositionSchema> — это не схема СКД (возможно, табличный документ — используй /mxl-decompile).", file=sys.stderr)
        sys.exit(2)

    run(root)


# --- 1b. Ring 3 scan: bail out on unsupported constructs ---

def fail_ring3(kind, loc):
    print(f"skd-decompile: декомпиляция не поддерживает {kind} (path: {loc})", file=sys.stderr)
    print("Для точечной работы с этим отчётом используй /skd-edit.", file=sys.stderr)
    sys.exit(3)


# --- 2. Warnings accumulator ---

warnings_list = []
warning_counter = [0]


def add_warning(kind, loc, detail):
    warning_counter[0] += 1
    wid = "W%03d" % warning_counter[0]
    warnings_list.append({'id': wid, 'kind': kind, 'loc': loc, 'detail': detail})
    return wid


def new_sentinel(kind, loc, detail):
    wid = add_warning(kind, loc, detail)
    return {'__unsupported__': {'id': wid, 'kind': kind, 'loc': loc}}


# --- 3. Helpers ---

# Custom JSON serializer — компактный, 2-пробельный indent, массивы примитивов inline.
# В отличие от ConvertTo-Json (PS5.1):
#   - не выравнивает ключи объекта по самому длинному
#   - не разворачивает массивы примитивов на отдельные строки
#   - кириллица в UTF-8 (без \uXXXX-escapes)
def convert_string_to_json_literal(s):
    if s is None:
        return 'null'
    out = ['"']
    for ch in s:
        code = ord(ch)
        if code == 0x22:
            out.append('\\"')
        elif code == 0x5C:
            out.append('\\\\')
        elif code == 0x08:
            out.append('\\b')
        elif code == 0x09:
            out.append('\\t')
        elif code == 0x0A:
            out.append('\\n')
        elif code == 0x0C:
            out.append('\\f')
        elif code == 0x0D:
            out.append('\\r')
        elif code < 0x20:
            out.append('\\u%04x' % code)
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def _fmt_number(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        # Invariant culture: '.' decimal sep
        if v == int(v):
            # Preserve float-ness: PS [double] 5.0 → "5"
            # Match PS ToString invariant: 5.0 → "5"
            return str(int(v))
        return repr(v)
    return str(v)


def try_inline_json(obj):
    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float)):
        return _fmt_number(obj)
    if isinstance(obj, dict):
        if len(obj) == 0:
            return '{}'
        parts = []
        for k, v in obj.items():
            vs = try_inline_json(v)
            if vs is None:
                return None
            parts.append(convert_string_to_json_literal(str(k)) + ': ' + vs)
        return '{ ' + ', '.join(parts) + ' }'
    if isinstance(obj, (list, tuple)):
        if len(obj) == 0:
            return '[]'
        parts = []
        for it in obj:
            vs = try_inline_json(it)
            if vs is None:
                return None
            parts.append(vs)
        return '[' + ', '.join(parts) + ']'
    return None


def convert_to_compact_json(obj, depth=0, indent_unit='  ', line_limit=400):
    indent = indent_unit * depth
    child_indent = indent_unit * (depth + 1)

    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float)):
        return _fmt_number(obj)

    # Try inline для объектов и массивов с объектами — если помещается в lineLimit с учётом текущего indent.
    is_container = isinstance(obj, (dict, list, tuple))
    if is_container:
        inline_attempt = try_inline_json(obj)
        if inline_attempt is not None and (len(indent) + len(inline_attempt)) <= line_limit:
            return inline_attempt

    if isinstance(obj, dict):
        if len(obj) == 0:
            return '{}'
        parts = []
        for k, v in obj.items():
            val = convert_to_compact_json(v, depth + 1, indent_unit, line_limit)
            parts.append(child_indent + convert_string_to_json_literal(str(k)) + ': ' + val)
        return "{\n" + ",\n".join(parts) + "\n" + indent + "}"
    if isinstance(obj, (list, tuple)):
        if len(obj) == 0:
            return '[]'
        parts = [child_indent + convert_to_compact_json(it, depth + 1, indent_unit, line_limit) for it in obj]
        return "[\n" + ",\n".join(parts) + "\n" + indent + "]"
    return convert_string_to_json_literal(str(obj))


def get_text(node, xpath=None):
    if not node:
        return None
    if not xpath:
        return node.inner_text
    n = node.select_single_node(xpath)
    if n:
        return n.inner_text
    return None


# Extract LocalStringType (multilingual title) → string (if only ru) or hashtable
def get_ml_text(node):
    if not node:
        return None
    items = node.select_nodes("v8:item")
    if len(items) == 0:
        return None
    d = {}
    for it in items:
        lang = get_text(it, "v8:lang")
        content = get_text(it, "v8:content")
        if lang:
            d[lang] = content if content else ""
    if len(d) == 1 and 'ru' in d:
        return d['ru']
    return d


# Strip namespace prefix from xsi:type value (e.g. "dcsset:Foo" → "Foo")
def get_local_xsi_type(node):
    if not node:
        return None
    t = node.get_attribute("type", NS_XSI)
    if t and ':' in t:
        return t.split(':', 1)[1]
    return t if t else None


# Convert one <v8:Type> element + sibling qualifiers → shorthand type string
def get_one_type_shorthand(type_node, qual_number, qual_string, qual_date):
    raw = type_node.inner_text.strip()
    # Strip namespace prefix; check if it's d5p1: (config refs)
    local = raw
    m = re.match(r'^([^:]+):(.+)$', raw)
    if m:
        prefix = m.group(1)
        local = m.group(2)
        uri = type_node.get_namespace_of_prefix(prefix)
        if uri == NS_CFG:
            return local
        if uri == NS_XS:
            if local == 'string':
                if qual_string:
                    length = int(get_text(qual_string, "v8:Length") or 0)
                    allowed = get_text(qual_string, "v8:AllowedLength")
                    if length == 0:
                        return 'string'
                    if allowed == 'Fixed':
                        return "string(%d,fix)" % length
                    return "string(%d)" % length
                return 'string'
            if local == 'boolean':
                return 'boolean'
            if local == 'decimal':
                if qual_number:
                    d = int(get_text(qual_number, "v8:Digits") or 0)
                    f = int(get_text(qual_number, "v8:FractionDigits") or 0)
                    sign = get_text(qual_number, "v8:AllowedSign")
                    sign_suf = ''
                    if sign == 'Nonnegative':
                        sign_suf = ',nonneg'
                    if f == 0:
                        return "decimal(%d%s)" % (d, sign_suf)
                    if sign_suf:
                        return "decimal(%d,%d%s)" % (d, f, sign_suf)
                    return "decimal(%d,%d)" % (d, f)
                return 'decimal'
            if local == 'dateTime':
                frac = get_text(qual_date, "v8:DateFractions") if qual_date else 'DateTime'
                if frac == 'Date':
                    return 'date'
                if frac == 'Time':
                    return 'time'
                return 'dateTime'
            return local
        if uri == NS_V8:
            return local
    return local


# valueType → string shorthand OR array of shorthands (composite)
def get_value_type_shorthand(value_type_node):
    if not value_type_node:
        return None
    types = value_type_node.select_nodes("v8:Type")
    type_sets = value_type_node.select_nodes("v8:TypeSet")
    if len(types) == 0 and len(type_sets) == 0:
        return None
    qual_n = value_type_node.select_single_node("v8:NumberQualifiers")
    qual_s = value_type_node.select_single_node("v8:StringQualifiers")
    qual_d = value_type_node.select_single_node("v8:DateQualifiers")
    shorts = []
    for t in types:
        shorts.append(get_one_type_shorthand(t, qual_n, qual_s, qual_d))
    for ts in type_sets:
        txt = ts.inner_text
        m = re.match(r'.*:(.+)$', txt)
        if m:
            shorts.append(m.group(1))
        else:
            shorts.append(txt)
    if len(shorts) == 1:
        return shorts[0]
    return shorts


# <role> → { tokens, extras }
def get_role_info(role_node, loc):
    if not role_node:
        return None
    tokens = []
    extras = {}
    has_complex = False
    pn_node = role_node.select_single_node("dcscom:periodNumber")
    pt_node = role_node.select_single_node("dcscom:periodType")
    period_handled = False
    if pn_node and pt_node and pn_node.inner_text == '1' and pt_node.inner_text == 'Main':
        tokens.append('@period')
        period_handled = True
    for child in role_node.child_nodes:
        if child.namespace_uri != NS_COM:
            has_complex = True
            continue
        if period_handled and (child.local_name == 'periodNumber' or child.local_name == 'periodType'):
            continue
        txt = child.inner_text
        if txt == 'true':
            tokens.append('@' + child.local_name)
        elif txt == 'false' or not txt:
            pass
        else:
            extras[child.local_name] = txt
    if has_complex:
        new_sentinel('ComplexRole', loc, 'Роль с не-dcscom-атрибутами не сворачивается в DSL')
    return {'tokens': tokens, 'extras': extras}


def render_role(tokens, extras):
    has_extras = extras and len(extras) > 0
    has_tokens = tokens and len(tokens) > 0
    if not has_extras and not has_tokens:
        return None
    if not has_extras:
        plain = [re.sub(r'^@', '', t) for t in tokens]
        if len(plain) == 1:
            return {'value': plain[0], 'isString': True}
        with_at = ['@' + p for p in plain]
        return {'value': ' '.join(with_at), 'isString': True}
    all_simple = True
    for v in extras.values():
        if not re.match(r'^[\w\.\-]+$', str(v)):
            all_simple = False
            break
    if all_simple:
        parts = []
        for t in tokens:
            parts.append(t)
        for k, v in extras.items():
            parts.append("%s=%s" % (k, v))
        return {'value': ' '.join(parts), 'isString': True}
    obj = {}
    for t in tokens:
        obj[re.sub(r'^@', '', t)] = True
    for k, v in extras.items():
        obj[k] = v
    return {'value': obj, 'isString': False}


# <useRestriction> → array of #tokens
def get_restriction_tokens(ur_node):
    if not ur_node:
        return []
    tokens = []
    m = {'field': '#noField', 'condition': '#noFilter', 'group': '#noGroup', 'order': '#noOrder'}
    for key in ('field', 'condition', 'group', 'order'):
        v = get_text(ur_node, "r:" + key)
        if v == 'true':
            tokens.append(m[key])
    return tokens


# <appearance> → hashtable {param: value}
def get_font_value(val_node):
    f = {'@type': 'Font'}
    for attr_name in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
        a = val_node.el.get(attr_name)
        if a is not None:
            f[attr_name] = a
    return f


def get_appearance_dict(app_node):
    if not app_node:
        return None
    d = {}
    items = app_node.select_nodes("dcscor:item")
    for it in items:
        p = get_text(it, "dcscor:parameter")
        val_node = it.select_single_node("dcscor:value")
        if not p or not val_node:
            continue
        val_type = get_local_xsi_type(val_node)
        if val_type == 'LocalStringType':
            raw_val = get_ml_text(val_node)
        elif val_type == 'Font':
            raw_val = get_font_value(val_node)
        else:
            raw_val = val_node.inner_text
        use_v = get_text(it, "dcscor:use")
        if use_v == 'false':
            d[p] = {'value': raw_val, 'use': False}
        else:
            d[p] = raw_val
    return d


# Read <r:inputParameters> → JSON array. Returns None если отсутствует или пустой.
def read_input_parameters(parent_node):
    ip = parent_node.select_single_node("r:inputParameters")
    if not ip:
        return None
    result = []
    for it in ip.select_nodes("dcscor:item"):
        entry = {}
        use_text = get_text(it, "dcscor:use")
        p_name = get_text(it, "dcscor:parameter")
        entry['parameter'] = p_name
        if use_text == 'false':
            entry['use'] = False
        val = it.select_single_node("dcscor:value")
        if val:
            v_type = get_local_xsi_type(val)
            if v_type == 'ChoiceParameters':
                cp = []
                for cp_item in val.select_nodes("dcscor:item"):
                    cp_entry = {'name': get_text(cp_item, "dcscor:choiceParameter")}
                    values = []
                    for v in cp_item.select_nodes("dcscor:value"):
                        v_xsi = get_local_xsi_type(v)
                        v_txt = v.inner_text
                        if v_xsi == 'boolean':
                            values.append(v_txt == 'true')
                        elif v_xsi == 'decimal':
                            if re.match(r'^-?\d+$', v_txt or ''):
                                values.append(int(v_txt))
                            else:
                                values.append(float(v_txt))
                        else:
                            values.append(v_txt)
                    cp_entry['values'] = values
                    cp.append(cp_entry)
                entry['choiceParameters'] = cp
            elif v_type == 'ChoiceParameterLinks':
                cpl = []
                for cpl_item in val.select_nodes("dcscor:item"):
                    cpl_entry = {
                        'name': get_text(cpl_item, "dcscor:choiceParameter"),
                        'value': get_text(cpl_item, "dcscor:value"),
                    }
                    mode = get_text(cpl_item, "dcscor:mode")
                    if mode:
                        cpl_entry['mode'] = mode
                    cpl.append(cpl_entry)
                entry['choiceParameterLinks'] = cpl
            elif v_type == 'LocalStringType':
                ml = get_ml_text(val)
                entry['value'] = ml if ml else ''
            else:
                txt = val.inner_text
                if v_type == 'boolean':
                    entry['value'] = (txt == 'true')
                elif v_type == 'decimal':
                    if re.match(r'^-?\d+$', txt or ''):
                        entry['value'] = int(txt)
                    else:
                        entry['value'] = float(txt)
                else:
                    entry['value'] = txt
                    ta = val.get_attr_raw('xsi:type')
                    if ta and not re.match(r'^xs:', ta):
                        prefix = ta.split(':', 1)[0]
                        local_name = ta.split(':', 1)[1]
                        uri = val.get_namespace_of_prefix(prefix)
                        if uri:
                            entry['valueType'] = {'uri': uri, 'name': local_name}
        result.append(entry)
    if len(result) == 0:
        return None
    return result


# Build a field JSON entry (shorthand if possible, object form otherwise)
def build_field(field_node, loc):
    input_parameters = read_input_parameters(field_node)
    order_expr_nodes = field_node.select_nodes("r:orderExpression")
    order_expression = None
    order_expression_list = []
    for oe_n in order_expr_nodes:
        oe_expr = get_text(oe_n, "dcscom:expression")
        oe_type = get_text(oe_n, "dcscom:orderType")
        oe_auto = get_text(oe_n, "dcscom:autoOrder")
        oe = {}
        if oe_expr:
            oe['expression'] = oe_expr
        if oe_type:
            oe['orderType'] = oe_type
        if oe_auto == 'true':
            oe['autoOrder'] = True
        elif oe_auto == 'false':
            oe['autoOrder'] = False
        order_expression_list.append(oe)
    if len(order_expression_list) == 1:
        order_expression = order_expression_list[0]
    elif len(order_expression_list) > 1:
        order_expression = order_expression_list
    data_path = get_text(field_node, "r:dataPath")
    field_name = get_text(field_node, "r:field")
    title_node = field_node.select_single_node("r:title")
    title = get_ml_text(title_node)
    value_type_node = field_node.select_single_node("r:valueType")
    type_short = get_value_type_shorthand(value_type_node)
    role_info = get_role_info(field_node.select_single_node("r:role"), "%s/role" % loc)
    role_tokens = role_info['tokens'] if role_info else []
    role_extras = role_info['extras'] if role_info else {}
    role_rendered = render_role(role_tokens, role_extras)
    restrict_tokens = get_restriction_tokens(field_node.select_single_node("r:useRestriction"))
    attr_restrict_tokens = get_restriction_tokens(field_node.select_single_node("r:attributeUseRestriction"))
    app_node = field_node.select_single_node("r:appearance")
    appearance = get_appearance_dict(app_node)
    pres_expr = get_text(field_node, "r:presentationExpression")
    av_nodes = field_node.select_nodes("r:availableValue")
    available_values = []
    for av in av_nodes:
        av_vn = av.select_single_node("r:value")
        av_pn = av.select_single_node("r:presentation")
        av_entry = {}
        if av_vn:
            av_type = get_local_xsi_type(av_vn)
            av_text = av_vn.inner_text
            if av_type == 'boolean':
                av_entry['value'] = (av_text == 'true')
            elif av_type == 'decimal':
                if re.match(r'^-?\d+$', av_text or ''):
                    av_entry['value'] = int(av_text)
                else:
                    av_entry['value'] = float(av_text)
            else:
                av_entry['value'] = av_text
        if av_pn:
            av_pres = get_ml_text(av_pn)
            if av_pres:
                av_entry['presentation'] = av_pres
        available_values.append(av_entry)

    role_in_string = role_rendered and role_rendered['isString']
    needs_object = bool(title) or bool(appearance) or bool(pres_expr) or isinstance(type_short, list) \
        or (role_rendered and not role_in_string) or bool(order_expression) or bool(input_parameters) \
        or (len(available_values) > 0) or (attr_restrict_tokens and len(attr_restrict_tokens) > 0)

    if not needs_object:
        s = field_name
        if type_short:
            s = "%s: %s" % (field_name, type_short)
        if role_in_string:
            rv = role_rendered['value']
            if '@' in rv or '=' in rv or re.search(r'\s', rv):
                s += ' ' + rv
            else:
                s += " @%s" % rv
        if restrict_tokens:
            s += ' ' + ' '.join(restrict_tokens)
        if not (data_path and data_path != field_name):
            return s

    obj = {'field': field_name}
    if data_path and data_path != field_name:
        obj['dataPath'] = data_path
    if title:
        obj['title'] = title
    if type_short:
        obj['type'] = type_short
    if role_rendered:
        obj['role'] = role_rendered['value']
    if order_expression:
        obj['orderExpression'] = order_expression
    if input_parameters:
        obj['inputParameters'] = input_parameters
    if restrict_tokens:
        obj['restrict'] = [re.sub(r'^#', '', t) for t in restrict_tokens]
    if attr_restrict_tokens and len(attr_restrict_tokens) > 0:
        obj['attrRestrict'] = [re.sub(r'^#', '', t) for t in attr_restrict_tokens]
    if pres_expr:
        obj['presentationExpression'] = pres_expr
    if len(available_values) > 0:
        obj['availableValues'] = available_values
    if appearance:
        obj['appearance'] = appearance
    return obj


# Build calculatedField → shorthand string or object form
def build_calc_field(cf_node, loc):
    data_path = get_text(cf_node, "r:dataPath")
    expression = get_text(cf_node, "r:expression")
    title_node = cf_node.select_single_node("r:title")
    title = get_ml_text(title_node)
    value_type_node = cf_node.select_single_node("r:valueType")
    type_short = get_value_type_shorthand(value_type_node)
    restrict_tokens = get_restriction_tokens(cf_node.select_single_node("r:useRestriction"))
    app_node = cf_node.select_single_node("r:appearance")
    appearance = get_appearance_dict(app_node)

    title_needs_object = isinstance(title, dict) or isinstance(type_short, list)
    needs_object = bool(appearance) or title_needs_object

    if not needs_object:
        s = data_path
        if title:
            s += " [%s]" % title
        if type_short:
            s += ": %s" % type_short
        if expression:
            s += " = %s" % expression
        if restrict_tokens:
            s += ' ' + ' '.join(restrict_tokens)
        return s

    obj = {'name': data_path}
    if title:
        obj['title'] = title
    if type_short:
        obj['type'] = type_short
    if expression:
        obj['expression'] = expression
    if restrict_tokens:
        obj['restrict'] = [re.sub(r'^#', '', t) for t in restrict_tokens]
    if appearance:
        obj['appearance'] = appearance
    return obj


# Build totalField → shorthand or object form
def build_total_field(tf_node):
    data_path = get_text(tf_node, "r:dataPath")
    expression = get_text(tf_node, "r:expression") or ''
    group_nodes = tf_node.select_nodes("r:group")
    has_groups = bool(group_nodes) and len(group_nodes) > 0

    if has_groups or re.search(r'[\r\n]', expression):
        obj = {'dataPath': data_path, 'expression': expression}
        if has_groups:
            groups = []
            for g in group_nodes:
                groups.append(g.inner_text)
            obj['group'] = groups
        return obj

    m = re.match(r'^(\w+)\((\w+)\)$', expression)
    if m and m.group(2) == data_path:
        return "%s: %s" % (data_path, m.group(1))
    return "%s: %s" % (data_path, expression)


# Detect StandardPeriod variant from <value> node
def get_standard_period_variant(value_node):
    if not value_node:
        return None
    variant = get_text(value_node, "v8:variant")
    if variant:
        return variant
    return None


# Build parameter → shorthand or object form
def build_parameter(p_node, loc):
    name = get_text(p_node, "r:name")
    title_node = p_node.select_single_node("r:title")
    title = get_ml_text(title_node)
    value_type_node = p_node.select_single_node("r:valueType")
    type_short = get_value_type_shorthand(value_type_node)

    value_nodes = p_node.select_nodes("r:value")
    value_display = None
    value_is_nil = False
    if len(value_nodes) > 1:
        value_arr = []
        for vn in value_nodes:
            vt = get_local_xsi_type(vn)
            v_txt = vn.inner_text
            if vt == 'boolean':
                value_arr.append(v_txt == 'true')
            elif vt == 'decimal':
                if re.match(r'^-?\d+$', v_txt or ''):
                    value_arr.append(int(v_txt))
                else:
                    value_arr.append(float(v_txt))
            else:
                value_arr.append(v_txt)
        value_display = value_arr
    elif len(value_nodes) == 1:
        value_node = value_nodes[0]
        nil = value_node.get_attribute("nil", NS_XSI)
        if nil == 'true':
            value_is_nil = True
        else:
            v_type = get_local_xsi_type(value_node)
            if v_type == 'StandardPeriod':
                variant = get_text(value_node, "v8:variant")
                sd = get_text(value_node, "v8:startDate")
                ed = get_text(value_node, "v8:endDate")
                has_explicit_dates = (sd and sd != '0001-01-01T00:00:00') or (ed and ed != '0001-01-01T00:00:00')
                if has_explicit_dates:
                    value_display = {'variant': variant}
                    if sd:
                        value_display['startDate'] = sd
                    if ed:
                        value_display['endDate'] = ed
                elif variant and variant != 'Custom':
                    value_display = variant
            elif v_type == 'DesignTimeValue':
                value_display = value_node.inner_text
            elif v_type == 'LocalStringType':
                value_display = get_ml_text(value_node)
            else:
                txt = value_node.inner_text
                if txt:
                    value_display = txt

    value_list_allowed = (get_text(p_node, "r:valueListAllowed") == 'true')
    available_as_field = get_text(p_node, "r:availableAsField")
    deny_incomplete = (get_text(p_node, "r:denyIncompleteValues") == 'true')
    use_attr = get_text(p_node, "r:use")
    use_restriction = (get_text(p_node, "r:useRestriction") == 'true')
    expression = get_text(p_node, "r:expression")
    input_parameters = read_input_parameters(p_node)
    not_a_field = (available_as_field == 'false')
    hidden = not_a_field and use_restriction

    av_nodes = p_node.select_nodes("r:availableValue")
    available_values = []
    for av in av_nodes:
        av_val_node = av.select_single_node("r:value")
        av_pres_node = av.select_single_node("r:presentation")
        av_entry = {}
        if av_val_node:
            av_type = get_local_xsi_type(av_val_node)
            av_text = av_val_node.inner_text
            if av_type == 'boolean':
                av_entry['value'] = (av_text == 'true')
            elif av_type == 'decimal':
                if re.match(r'^-?\d+$', av_text or ''):
                    av_entry['value'] = int(av_text)
                else:
                    av_entry['value'] = float(av_text)
            else:
                av_entry['value'] = av_text
        if av_pres_node:
            av_entry['presentation'] = get_ml_text(av_pres_node)
        available_values.append(av_entry)

    result = {
        'name': name,
        'title': title,
        'typeShort': type_short,
        'valueDisplay': value_display,
        'valueIsNil': value_is_nil,
        'valueListAllowed': value_list_allowed,
        'hidden': hidden,
        'notAField': (not_a_field and not hidden),
        'denyIncomplete': deny_incomplete,
        'useAttr': use_attr,
        'useRestriction': use_restriction,
        'expression': expression,
        'availableValues': available_values,
        'inputParameters': input_parameters,
    }
    return result


# Render parameter (after autoDates folding) → shorthand or object form
def render_parameter(p):
    name = p['name']
    title = p['title']
    type_short = p['typeShort']
    value_display = p['valueDisplay']
    value_is_nil = p['valueIsNil']
    flags = []
    if p.get('autoDates'):
        flags.append('@autoDates')
    if p['valueListAllowed']:
        flags.append('@valueList')
    if p['hidden']:
        flags.append('@hidden')

    title_needs_object = isinstance(title, dict)
    type_is_array = isinstance(type_short, list)
    value_is_dict = isinstance(value_display, dict)

    needs_object = False
    if p['availableValues'] and len(p['availableValues']) > 0:
        needs_object = True
    if p['inputParameters']:
        needs_object = True
    if title_needs_object:
        needs_object = True
    if type_is_array:
        needs_object = True
    if value_is_dict:
        needs_object = True
    if not p.get('autoDates'):
        if p['denyIncomplete']:
            needs_object = True
        if p['useAttr']:
            needs_object = True
    if p['useRestriction'] and not p['hidden'] and not p.get('autoDates'):
        needs_object = True
    if p['expression']:
        needs_object = True
    if p['notAField']:
        needs_object = True

    ref_type_pattern = r'^(Catalog|Document|Enum|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan|CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|InformationRegisterRef|ExchangePlanRef|AnyRef)'
    type_is_ref = False
    if isinstance(type_short, str) and re.match(ref_type_pattern, type_short):
        type_is_ref = True
    nil_needs_object = value_is_nil and not type_is_ref and type_short and not isinstance(type_short, list)
    if nil_needs_object:
        needs_object = True

    if not needs_object:
        s = name
        if title:
            s += " [%s]" % title
        if type_short:
            s += ": %s" % type_short
        if not value_is_nil and value_display is not None and value_display != '':
            s += " = %s" % value_display
        if flags:
            s += ' ' + ' '.join(flags)
        return s

    obj = {'name': name}
    if title:
        obj['title'] = title
    if type_short:
        obj['type'] = type_short
    if not value_is_nil and value_display is not None and value_display != '':
        obj['value'] = value_display
    if nil_needs_object:
        obj['nilValue'] = True
    if p['useAttr'] and not p.get('autoDates'):
        obj['use'] = p['useAttr']
    if p['denyIncomplete'] and not p.get('autoDates'):
        obj['denyIncompleteValues'] = True
    if p['hidden']:
        obj['hidden'] = True
    if p['notAField']:
        obj['availableAsField'] = False
    if p['valueListAllowed']:
        obj['valueListAllowed'] = True
    if p.get('autoDates'):
        obj['autoDates'] = True
    if p['expression']:
        obj['expression'] = p['expression']
    if p['useRestriction'] and not p['hidden'] and not p.get('autoDates'):
        obj['useRestriction'] = True
    if p['availableValues'] and len(p['availableValues']) > 0:
        obj['availableValues'] = p['availableValues']
    if p['inputParameters']:
        obj['inputParameters'] = p['inputParameters']
    return obj


# --- 3b. Built-in style presets (preset-shape: 11 полей) ---

builtin_preset_names = ['none', 'data', 'header', 'subheader', 'total']

builtin_presets = {
    'none': {
        'font': None, 'fontSize': None, 'bold': False, 'italic': False,
        'hAlign': None, 'vAlign': None, 'wrap': False,
        'bgColor': None, 'textColor': None,
        'borderColor': None, 'borders': False,
    },
    'data': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': None, 'vAlign': None, 'wrap': False,
        'bgColor': 'style:ReportGroup1BackColor', 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
    'header': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': 'Center', 'vAlign': None, 'wrap': True,
        'bgColor': 'style:ReportHeaderBackColor', 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
    'subheader': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': 'Center', 'vAlign': None, 'wrap': True,
        'bgColor': None, 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
    'total': {
        'font': 'Arial', 'fontSize': 10, 'bold': False, 'italic': False,
        'hAlign': None, 'vAlign': None, 'wrap': False,
        'bgColor': None, 'textColor': None,
        'borderColor': 'style:ReportLineColor', 'borders': True,
    },
}

effective_presets = {}
for k in builtin_presets:
    copy = {}
    for f in builtin_presets[k]:
        copy[f] = builtin_presets[k][f]
    effective_presets[k] = copy

existing_user_presets_raw = None

query_files_accumulator = []
query_file_names_used = {}

output_dir = None
output_basename = None


def maybe_externalize_query(query_text, dataset_name):
    if not query_text:
        return query_text
    if not output_dir:
        return query_text
    line_count = len(re.findall(r'\n', query_text)) + 1
    if line_count < 3:
        return query_text
    safe_ds = re.sub(r'[^\w\-]', '_', dataset_name)
    if not safe_ds:
        safe_ds = 'query'
    prefix = "%s-" % output_basename if output_basename else ''
    file_name = "%s%s.sql" % (prefix, safe_ds)
    suffix = 1
    while file_name in query_file_names_used:
        suffix += 1
        file_name = "%s%s_%d.sql" % (prefix, safe_ds, suffix)
    query_file_names_used[file_name] = True
    query_files_accumulator.append({'fileName': file_name, 'text': query_text})
    return "@" + file_name


def save_query_files():
    if len(query_files_accumulator) == 0:
        return
    if not output_dir:
        return
    for qf in query_files_accumulator:
        path = os.path.join(output_dir, qf['fileName'])
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(qf['text'])
    print("Saved %d external query file(s)" % len(query_files_accumulator), file=sys.stderr)


custom_styles_accumulator = {}
custom_style_counter = [0]


def normalize_color(val_node):
    if not val_node:
        return None
    txt = val_node.inner_text
    m = re.match(r'^([^:]+):(.+)$', txt or '')
    if m:
        pfx = m.group(1)
        name = m.group(2)
        uri = val_node.get_namespace_of_prefix(pfx)
        if uri == 'http://v8.1c.ru/8.1/data/ui/style':
            return 'style:' + name
        if uri == 'http://v8.1c.ru/8.1/data/ui/colors/web':
            return 'web:' + name
        if uri == 'http://v8.1c.ru/8.1/data/ui/colors/windows':
            return 'win:' + name
    return txt


def extract_cell_preset(app_node):
    if not app_node:
        return None
    preset = {
        'font': None, 'fontSize': None, 'bold': False, 'italic': False,
        'hAlign': None, 'vAlign': None, 'wrap': False,
        'bgColor': None, 'textColor': None,
        'borderColor': None, 'borders': False,
    }
    has_any_style = False
    for it in app_node.select_nodes("dcscor:item"):
        p_name = get_text(it, "dcscor:parameter")
        val = it.select_single_node("dcscor:value")
        if not p_name:
            continue
        if p_name in ('МинимальнаяШирина', 'МаксимальнаяШирина', 'МинимальнаяВысота', 'ОбъединятьПоВертикали', 'ОбъединятьПоГоризонтали', 'Расшифровка'):
            continue
        if p_name == 'Шрифт':
            if val:
                preset['font'] = val.el.get('faceName')
                h = val.el.get('height')
                if h:
                    preset['fontSize'] = int(h)
                preset['bold'] = (val.el.get('bold') == 'true')
                preset['italic'] = (val.el.get('italic') == 'true')
                has_any_style = True
        elif p_name == 'ЦветФона':
            if val:
                preset['bgColor'] = normalize_color(val)
                has_any_style = True
        elif p_name == 'ЦветТекста':
            if val:
                preset['textColor'] = normalize_color(val)
                has_any_style = True
        elif p_name == 'ЦветГраницы':
            if val:
                preset['borderColor'] = normalize_color(val)
                has_any_style = True
        elif p_name == 'СтильГраницы':
            sides_found = 0
            for sub in it.select_nodes("dcscor:item"):
                sub_name = get_text(sub, "dcscor:parameter")
                if sub_name and re.match(r'^СтильГраницы\.(Слева|Сверху|Справа|Снизу)$', sub_name):
                    sides_found += 1
            if sides_found > 0:
                preset['borders'] = True
                has_any_style = True
        elif p_name == 'ГоризонтальноеПоложение':
            if val:
                preset['hAlign'] = val.inner_text
                has_any_style = True
        elif p_name == 'ВертикальноеПоложение':
            if val:
                preset['vAlign'] = val.inner_text
                has_any_style = True
        elif p_name == 'Размещение':
            if val and val.inner_text == 'Wrap':
                preset['wrap'] = True
                has_any_style = True
    if not has_any_style:
        return None
    return preset


def compare_preset(a, b):
    for key in ('font', 'fontSize', 'bold', 'italic', 'hAlign', 'vAlign', 'wrap', 'bgColor', 'textColor', 'borderColor', 'borders'):
        if a[key] != b[key]:
            return False
    return True


def match_preset_by_shape(cell_preset):
    if not cell_preset:
        return None
    for name in effective_presets:
        if compare_preset(cell_preset, effective_presets[name]):
            return name
    return None


def allocate_custom_style(cell_preset):
    custom_style_counter[0] += 1
    name = "custom%d" % custom_style_counter[0]
    while name in effective_presets:
        custom_style_counter[0] += 1
        name = "custom%d" % custom_style_counter[0]
    effective_presets[name] = cell_preset
    custom_styles_accumulator[name] = cell_preset
    return name


def load_user_styles(dir_path):
    global existing_user_presets_raw
    if not dir_path:
        return
    styles_path = os.path.join(dir_path, 'skd-styles.json')
    if not os.path.exists(styles_path):
        return
    import json as _json
    with open(styles_path, 'r', encoding='utf-8-sig') as f:
        raw = _json.load(f)
    existing_user_presets_raw = raw
    for prop_name, prop_value in raw.items():
        preset = {}
        for k in builtin_presets['data']:
            preset[k] = builtin_presets['data'][k]
        if prop_name in builtin_presets:
            for k in builtin_presets[prop_name]:
                preset[k] = builtin_presets[prop_name][k]
        for up_name, up_value in prop_value.items():
            preset[up_name] = up_value
        effective_presets[prop_name] = preset


def save_user_styles(dir_path):
    if not dir_path:
        return
    if len(custom_styles_accumulator) == 0 and not existing_user_presets_raw:
        return
    styles_path = os.path.join(dir_path, 'skd-styles.json')
    out = {}
    if existing_user_presets_raw:
        for prop_name, prop_value in existing_user_presets_raw.items():
            out[prop_name] = prop_value
    for name in custom_styles_accumulator:
        if name in out:
            continue
        out[name] = custom_styles_accumulator[name]
    if len(out) == 0:
        return
    json_text = convert_to_compact_json(out)
    with open(styles_path, 'w', encoding='utf-8', newline='') as f:
        f.write(json_text)
    print("Saved skd-styles.json (custom styles: %d)" % len(custom_styles_accumulator), file=sys.stderr)


def get_cell_per_cell_attrs(app_node):
    attrs = {'width': None, 'height': None, 'mergeV': False, 'mergeH': False, 'drilldown': None, 'drilldownTarget': None}
    if not app_node:
        return attrs
    for it in app_node.select_nodes("dcscor:item"):
        p_name = get_text(it, "dcscor:parameter")
        val = it.select_single_node("dcscor:value")
        if not p_name:
            continue
        if p_name == 'МинимальнаяШирина':
            if val:
                attrs['width'] = val.inner_text
        elif p_name == 'МинимальнаяВысота':
            if val:
                attrs['height'] = val.inner_text
        elif p_name == 'ОбъединятьПоВертикали':
            if val and val.inner_text == 'true':
                attrs['mergeV'] = True
        elif p_name == 'ОбъединятьПоГоризонтали':
            if val and val.inner_text == 'true':
                attrs['mergeH'] = True
        elif p_name == 'Расшифровка':
            if val:
                param_ref = val.inner_text
                attrs['drilldownTarget'] = param_ref
                m = re.match(r'^Расшифровка_(.+)$', param_ref or '')
                if m:
                    attrs['drilldown'] = m.group(1)
    return attrs


def get_cell_content(cell_node, per_cell_attrs):
    if per_cell_attrs['mergeV']:
        return '|'
    if per_cell_attrs['mergeH']:
        return '>'

    item = cell_node.select_single_node("dcsat:item")
    if not item:
        return None
    item_type = get_local_xsi_type(item)
    val_node = item.select_single_node("dcsat:value")
    if not val_node:
        return None
    val_type = get_local_xsi_type(val_node)

    if item_type == 'Field' and val_type == 'Parameter':
        return '{' + val_node.inner_text + '}'
    if val_type == 'LocalStringType':
        text = get_ml_text(val_node)
        if isinstance(text, dict):
            return text
        return text
    return val_node.inner_text


def build_template_parameter(p_node):
    p_type = get_local_xsi_type(p_node)
    obj = {}
    obj['name'] = get_text(p_node, "dcsat:name")
    if p_type == 'ExpressionAreaTemplateParameter':
        obj['expression'] = get_text(p_node, "dcsat:expression")
    elif p_type == 'DetailsAreaTemplateParameter':
        obj['__details__'] = True
        obj['expression'] = get_text(p_node, "dcsat:expression")
    return obj


def build_template(template_node, loc):
    tmpl_obj = {'name': get_text(template_node, "r:name")}
    inner = template_node.select_single_node("r:template")
    if not inner:
        return tmpl_obj

    row_nodes = inner.select_nodes("dcsat:item[@xsi:type='dcsat:TableRow']")
    if len(row_nodes) == 0:
        all_items = inner.select_nodes("dcsat:item")
        row_nodes = []
        for n in all_items:
            if get_local_xsi_type(n) == 'TableRow':
                row_nodes.append(n)

    rows = []
    widths = None
    min_height = None
    cell_style_map = {}
    cell_drilldown_map = {}
    has_any_styled_cell = False
    drilldown_by_param = {}

    row_idx = 0
    for row_node in row_nodes:
        cells = []
        cell_nodes = row_node.select_nodes("dcsat:tableCell")
        col_idx = 0
        row_widths = []
        for cell_node in cell_nodes:
            app_node = cell_node.select_single_node("dcsat:appearance")
            per_cell = get_cell_per_cell_attrs(app_node)
            content = get_cell_content(cell_node, per_cell)

            if app_node and not per_cell['mergeV'] and not per_cell['mergeH']:
                cell_preset = extract_cell_preset(app_node)
                if cell_preset is not None:
                    matched = match_preset_by_shape(cell_preset)
                    if matched is None:
                        matched = allocate_custom_style(cell_preset)
                    cell_style_map["%d,%d" % (row_idx, col_idx)] = matched
                    has_any_styled_cell = True

            m_content = re.match(r'^\{(.+)\}$', content) if isinstance(content, str) else None
            if m_content and per_cell['drilldown']:
                drilldown_by_param[m_content.group(1)] = per_cell['drilldown']
            if per_cell['drilldownTarget']:
                cell_drilldown_map["%d,%d" % (row_idx, col_idx)] = per_cell['drilldownTarget']

            if row_idx == 0 and per_cell['width']:
                row_widths.append(per_cell['width'])
            if row_idx == 0 and col_idx == 0 and per_cell['height']:
                min_height = per_cell['height']

            cells.append(content)
            col_idx += 1
        if row_idx == 0 and len(row_widths) > 0:
            widths = row_widths
        rows.append(cells)
        row_idx += 1

    template_default = None
    if has_any_styled_cell:
        counts = {}
        for k in cell_style_map:
            name = cell_style_map[k]
            if name not in counts:
                counts[name] = 0
            counts[name] += 1
        max_count = 0
        for name in counts:
            if counts[name] > max_count:
                max_count = counts[name]
                template_default = name

    if template_default:
        rows_out = []
        for r in range(len(rows)):
            new_row = []
            for c in range(len(rows[r])):
                key = "%d,%d" % (r, c)
                if key in cell_style_map and cell_style_map[key] != template_default:
                    new_row.append({'value': rows[r][c], 'style': cell_style_map[key]})
                else:
                    new_row.append(rows[r][c])
            rows_out.append(new_row)
        rows = rows_out

    param_nodes = template_node.select_nodes("r:parameter")
    expr_params = {}
    details_by_name = {}
    for pn in param_nodes:
        p_type = get_local_xsi_type(pn)
        p_name = get_text(pn, "dcsat:name")
        if p_type == 'ExpressionAreaTemplateParameter':
            expr_params[p_name] = get_text(pn, "dcsat:expression")
        elif p_type == 'DetailsAreaTemplateParameter':
            fe_node = pn.select_single_node("dcsat:fieldExpression")
            details_by_name[p_name] = {
                'field': get_text(fe_node, "dcsat:field") if fe_node else '',
                'expression': get_text(fe_node, "dcsat:expression") if fe_node else '',
                'action': get_text(pn, "dcsat:mainAction"),
            }

    folded_detail_names = {}
    for pname in list(drilldown_by_param.keys()):
        y_val = drilldown_by_param[pname]
        detail_name = "Расшифровка_%s" % y_val
        if detail_name in details_by_name:
            d = details_by_name[detail_name]
            expected_expr = '"%s"' % y_val
            if d['field'] == 'ИмяРесурса' and d['expression'] == expected_expr and d['action'] == 'DrillDown':
                folded_detail_names[detail_name] = True

    template_params = []
    for pname in expr_params:
        entry = {'name': pname, 'expression': expr_params[pname]}
        if pname in drilldown_by_param:
            entry['drilldown'] = drilldown_by_param[pname]
        template_params.append(entry)
    for dname in details_by_name:
        if dname in folded_detail_names:
            continue
        d = details_by_name[dname]
        entry = {'name': dname}
        dd_obj = {'field': d['field'], 'expression': d['expression']}
        if d['action'] and d['action'] != 'DrillDown':
            dd_obj['action'] = d['action']
        entry['drilldown'] = dd_obj
        template_params.append(entry)

    if len(cell_drilldown_map) > 0:
        for r in range(len(rows)):
            new_row = []
            for c in range(len(rows[r])):
                cell_val = rows[r][c]
                key = "%d,%d" % (r, c)
                target = cell_drilldown_map.get(key)
                inner_val = cell_val
                is_wrapped = False
                if isinstance(cell_val, dict):
                    if 'value' in cell_val:
                        inner_val = cell_val['value']
                        is_wrapped = True
                needs_wrap = False
                if target and isinstance(inner_val, str):
                    m = re.match(r'^\{(.+)\}$', inner_val)
                    if m:
                        cell_param = m.group(1)
                        expected_shortcut = None
                        if cell_param in drilldown_by_param:
                            expected_shortcut = "Расшифровка_%s" % drilldown_by_param[cell_param]
                        if target != expected_shortcut:
                            needs_wrap = True
                if needs_wrap:
                    if is_wrapped:
                        cell_val['drilldown'] = target
                        new_row.append(cell_val)
                    else:
                        new_row.append({'value': inner_val, 'drilldown': target})
                else:
                    new_row.append(cell_val)
            rows[r] = new_row

    if template_default:
        tmpl_obj['style'] = template_default
    elif len(rows) > 0:
        tmpl_obj['style'] = 'none'
    if widths:
        tmpl_obj['widths'] = widths
    if min_height:
        tmpl_obj['minHeight'] = min_height
    tmpl_obj['rows'] = rows
    if len(template_params) > 0:
        tmpl_obj['parameters'] = template_params

    return tmpl_obj


# --- 3c. Filter / settings helpers ---

filter_op_map = {
    'Equal': '=', 'NotEqual': '<>', 'Greater': '>', 'GreaterOrEqual': '>=',
    'Less': '<', 'LessOrEqual': '<=', 'InList': 'in', 'NotInList': 'notIn',
    'InHierarchy': 'inHierarchy', 'InListByHierarchy': 'inListByHierarchy',
    'Contains': 'contains', 'NotContains': 'notContains',
    'BeginsWith': 'beginsWith', 'NotBeginsWith': 'notBeginsWith',
    'Filled': 'filled', 'NotFilled': 'notFilled',
}


def get_filter_value(val_node):
    if not val_node:
        return '_'
    nil = val_node.get_attribute("nil", NS_XSI)
    if nil == 'true':
        return '_'
    v_type = get_local_xsi_type(val_node)
    if v_type == 'DesignTimeValue':
        return val_node.inner_text
    if v_type == 'LocalStringType':
        return get_ml_text(val_node)
    txt = val_node.inner_text
    if not txt:
        return '_'
    return txt


def get_filter_value_with_type(val_node):
    if not val_node:
        return {'value': '_', 'type': None}
    raw_type = val_node.get_attribute("type", NS_XSI)
    nil = val_node.get_attribute("nil", NS_XSI)
    if nil == 'true':
        return {'value': '_', 'type': None}
    v_type = get_local_xsi_type(val_node)
    if v_type == 'LocalStringType':
        return {'value': get_ml_text(val_node), 'type': raw_type}
    txt = val_node.inner_text
    if not txt:
        return {'value': '_', 'type': raw_type}
    if v_type == 'boolean':
        return {'value': (txt == 'true'), 'type': raw_type}
    if v_type == 'decimal':
        if re.match(r'^-?\d+$', txt):
            return {'value': int(txt), 'type': raw_type}
        return {'value': float(txt), 'type': raw_type}
    return {'value': txt, 'type': raw_type}


def build_filter_item(item_node, loc):
    xtype = get_local_xsi_type(item_node)
    if xtype == 'FilterItemGroup':
        gt = get_text(item_node, "dcsset:groupType")
        if gt == 'OrGroup':
            group_name = 'Or'
        elif gt == 'NotGroup':
            group_name = 'Not'
        else:
            group_name = 'And'
        items = []
        for c in item_node.select_nodes("dcsset:item"):
            items.append(build_filter_item(c, "%s/item" % loc))
        g_obj = {'group': group_name, 'items': items}
        g_pres_node = item_node.select_single_node("dcsset:presentation")
        if g_pres_node:
            g_pres = get_ml_text(g_pres_node)
            if not g_pres:
                g_pres = g_pres_node.inner_text
            if g_pres:
                g_obj['presentation'] = g_pres
        g_vm_node = item_node.select_single_node("dcsset:viewMode")
        if g_vm_node:
            g_obj['viewMode'] = g_vm_node.inner_text
        g_usid = get_text(item_node, "dcsset:userSettingID")
        if g_usid:
            g_obj['userSettingID'] = 'auto'
        g_uspn = item_node.select_single_node("dcsset:userSettingPresentation")
        if g_uspn:
            g_usp = get_ml_text(g_uspn)
            if g_usp:
                g_obj['userSettingPresentation'] = g_usp
        return g_obj
    if xtype != 'FilterItemComparison':
        return new_sentinel("FilterItemType:%s" % xtype, loc, 'Неизвестный тип фильтра')
    left_node = item_node.select_single_node("dcsset:left")
    field = left_node.inner_text if left_node else None
    ct = get_text(item_node, "dcsset:comparisonType")
    op = filter_op_map.get(ct)
    if not op:
        op = ct

    right_nodes = item_node.select_nodes("dcsset:right")
    value = None
    value_is_array_flag = False
    value_type_attr = None
    if len(right_nodes) == 1:
        rn = right_nodes[0]
        if get_local_xsi_type(rn) == 'ValueListType':
            value = []
            value_is_array_flag = True
        else:
            vt = get_filter_value_with_type(rn)
            value = vt['value']
            auto_detects_dtv = (vt['type'] == 'dcscor:DesignTimeValue') and \
                re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', str(vt['value']))
            if vt['type'] and not re.match(r'^xs:', vt['type']) and not auto_detects_dtv:
                value_type_attr = vt['type']
    elif len(right_nodes) > 1:
        arr = []
        raw_types = []
        for rn in right_nodes:
            arr.append(get_filter_value(rn))
            raw_types.append(rn.get_attribute("type", NS_XSI))
        value = arr
        value_is_array_flag = True
        uniq_types = sorted(set(t for t in raw_types if t))
        # PS does Sort-Object -Unique, preserves None as well; we filtered. Replicate "all same":
        uniq_all = sorted(set(raw_types))
        if len(uniq_all) == 1 and uniq_all[0]:
            t0 = uniq_all[0]
            if t0 == 'dcscor:DesignTimeValue' and len(arr) > 0:
                all_match = all(re.match(r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.', str(x)) for x in arr)
                auto_detects_dtv = all_match
            else:
                auto_detects_dtv = False
            if not auto_detects_dtv:
                value_type_attr = t0

    use = get_text(item_node, "dcsset:use")
    user_id = get_text(item_node, "dcsset:userSettingID")
    vm_node = item_node.select_single_node("dcsset:viewMode")
    view_mode = vm_node.inner_text if vm_node else None
    user_pres_node = item_node.select_single_node("dcsset:userSettingPresentation")
    fi_pres_node = item_node.select_single_node("dcsset:presentation")
    fi_pres = None
    if fi_pres_node:
        fi_pres = get_ml_text(fi_pres_node)
        if not fi_pres:
            fi_pres = fi_pres_node.inner_text

    flags = []
    if use == 'false':
        flags.append('@off')
    if user_id:
        flags.append('@user')
    if view_mode == 'QuickAccess':
        flags.append('@quickAccess')
    elif view_mode == 'Inaccessible':
        flags.append('@inaccessible')
    elif view_mode == 'Normal':
        flags.append('@normal')

    no_value_ops = ('filled', 'notFilled')

    if user_pres_node or value_is_array_flag or value_type_attr or fi_pres:
        obj = {'field': field, 'op': op}
        if op not in no_value_ops and value is not None:
            if value_is_array_flag:
                obj['value'] = list(value)
            else:
                obj['value'] = value
        if value_type_attr:
            obj['valueType'] = value_type_attr
        if use == 'false':
            obj['use'] = False
        if user_id:
            obj['userSettingID'] = 'auto'
        if fi_pres:
            obj['presentation'] = fi_pres
        if view_mode:
            obj['viewMode'] = view_mode
        if user_pres_node:
            obj['userSettingPresentation'] = get_ml_text(user_pres_node)
        return obj

    s = field
    if op in no_value_ops:
        s += " %s" % op
    else:
        v_display = '_'
        if value is not None:
            if isinstance(value, bool):
                v_display = 'true' if value else 'false'
            elif str(value) != '':
                v_display = str(value)
        s += " %s %s" % (op, v_display)
    if flags:
        s += ' ' + ' '.join(flags)
    return s


def build_selection_item(item, loc):
    xt = get_local_xsi_type(item)
    if not xt:
        f_name = get_text(item, "dcsset:field")
        if f_name:
            return f_name
        field_el = item.select_single_node("dcsset:field")
        if field_el:
            return 'Auto'
    if xt == 'SelectedItemAuto':
        use_v = get_text(item, "dcsset:use")
        if use_v == 'false':
            return {'auto': True, 'use': False}
        return 'Auto'
    if xt == 'SelectedItemField':
        f_name = get_text(item, "dcsset:field")
        title_node = item.select_single_node("dcsset:lwsTitle")
        title = get_ml_text(title_node)
        vm_n = item.select_single_node("dcsset:viewMode")
        use_v = get_text(item, "dcsset:use")
        use_false = (use_v == 'false')
        if title or vm_n or use_false:
            obj = {'field': f_name}
            if use_false:
                obj['use'] = False
            if title:
                obj['title'] = title
            if vm_n:
                obj['viewMode'] = vm_n.inner_text
            return obj
        return f_name
    if xt == 'SelectedItemFolder':
        title_node = item.select_single_node("dcsset:lwsTitle")
        folder_title = get_ml_text(title_node)
        inner = []
        for sub in item.select_nodes("dcsset:item"):
            inner.append(build_selection_item(sub, "%s/folder" % loc))
        entry = {'folder': folder_title, 'items': inner}
        folder_field = get_text(item, "dcsset:field")
        if folder_field:
            entry['field'] = folder_field
        pl_n = item.select_single_node("dcsset:placement")
        if pl_n and pl_n.inner_text and pl_n.inner_text != 'Auto':
            entry['placement'] = pl_n.inner_text
        return entry
    return new_sentinel("SelectionItem:%s" % xt, loc, 'Неизвестный тип элемента selection')


def build_selection(sel_node, loc):
    if not sel_node:
        return []
    out = []
    for it in sel_node.select_nodes("dcsset:item"):
        out.append(build_selection_item(it, loc))
    return out


def build_order(ord_node, loc):
    if not ord_node:
        return []
    out = []
    for it in ord_node.select_nodes("dcsset:item"):
        xt = get_local_xsi_type(it)
        if xt == 'OrderItemAuto':
            out.append('Auto')
        elif xt == 'OrderItemField':
            fn = get_text(it, "dcsset:field")
            ot = get_text(it, "dcsset:orderType")
            vm_n = it.select_single_node("dcsset:viewMode")
            use_v = get_text(it, "dcsset:use")
            use_false = (use_v == 'false')
            if vm_n or use_false:
                obj = {'field': fn}
                if use_false:
                    obj['use'] = False
                if ot == 'Desc':
                    obj['direction'] = 'desc'
                if vm_n:
                    obj['viewMode'] = vm_n.inner_text
                out.append(obj)
            else:
                if ot == 'Desc':
                    out.append("%s desc" % fn)
                else:
                    out.append(fn)
        else:
            out.append(new_sentinel("OrderItem:%s" % xt, loc, 'Неизвестный тип сортировки'))
    return out


def get_line_value(val_node):
    obj = {'@type': 'Line'}
    w = val_node.el.get('width')
    g = val_node.el.get('gap')
    if w is not None and w != '':
        obj['width'] = int(w) if re.match(r'^-?\d+$', w) else w
    if g is not None and g != '':
        obj['gap'] = (g == 'true')
    style_node = val_node.select_single_node("v8ui:style")
    if style_node:
        obj['style'] = style_node.inner_text
    return obj


def read_appearance_value_node(val_node):
    if not val_node:
        return None
    vt = get_local_xsi_type(val_node)
    if vt == 'LocalStringType':
        return get_ml_text(val_node)
    if vt == 'Font':
        return get_font_value(val_node)
    if vt == 'Line':
        return get_line_value(val_node)
    return val_node.inner_text


def get_settings_appearance(app_node):
    if not app_node:
        return None
    d = {}
    for it in app_node.select_nodes("dcscor:item"):
        p_name = get_text(it, "dcscor:parameter")
        val = it.select_single_node("dcscor:value")
        if not p_name or not val:
            continue
        raw_val = read_appearance_value_node(val)
        use_v = get_text(it, "dcscor:use")
        nested_items = {}
        for sub in it.select_nodes("dcscor:item"):
            sub_name = get_text(sub, "dcscor:parameter")
            sub_val = sub.select_single_node("dcscor:value")
            if not sub_name:
                continue
            sub_raw = read_appearance_value_node(sub_val)
            sub_use = get_text(sub, "dcscor:use")
            sub_entry = {'value': sub_raw}
            if sub_use == 'false':
                sub_entry['use'] = False
            nested_items[sub_name] = sub_entry
        val_is_line = isinstance(raw_val, dict) and ('@type' in raw_val) and (raw_val['@type'] == 'Line')
        if val_is_line:
            if use_v == 'false':
                raw_val['use'] = False
            if len(nested_items) > 0:
                raw_val['items'] = nested_items
            d[p_name] = raw_val
        elif (use_v == 'false') or (len(nested_items) > 0):
            wrap = {'value': raw_val}
            if use_v == 'false':
                wrap['use'] = False
            if len(nested_items) > 0:
                wrap['items'] = nested_items
            d[p_name] = wrap
        else:
            d[p_name] = raw_val
    return d


def build_conditional_appearance(ca_node, loc):
    if not ca_node:
        return []
    out = []
    i = 0
    for it in ca_node.select_nodes("dcsset:item"):
        entry = {}
        scope_node = it.select_single_node("dcsset:scope")
        if scope_node and scope_node.has_child_nodes:
            add_warning('SilentDrop:scope', "%s/%d/scope" % (loc, i), "conditionalAppearance item имеет scope — не воспроизводится в DSL")
        sel_node = it.select_single_node("dcsset:selection")
        if sel_node and len(sel_node.select_nodes("dcsset:item")) > 0:
            entry['selection'] = build_selection(sel_node, "%s/%d/selection" % (loc, i))
        filter_node = it.select_single_node("dcsset:filter")
        if filter_node and len(filter_node.select_nodes("dcsset:item")) > 0:
            f = []
            for fc in filter_node.select_nodes("dcsset:item"):
                f.append(build_filter_item(fc, "%s/%d/filter" % (loc, i)))
            entry['filter'] = f
        app_node = it.select_single_node("dcsset:appearance")
        ap = get_settings_appearance(app_node)
        if ap and len(ap) > 0:
            entry['appearance'] = ap
        pres_node = it.select_single_node("dcsset:presentation")
        if pres_node:
            pres = get_ml_text(pres_node)
            if not pres:
                pres = pres_node.inner_text
            if pres:
                entry['presentation'] = pres
        vm_n = it.select_single_node("dcsset:viewMode")
        if vm_n:
            entry['viewMode'] = vm_n.inner_text
        usid = get_text(it, "dcsset:userSettingID")
        if usid:
            entry['userSettingID'] = 'auto'
        usp_n = it.select_single_node("dcsset:userSettingPresentation")
        if usp_n:
            usp = get_ml_text(usp_n)
            if usp:
                entry['userSettingPresentation'] = usp
        use_v = get_text(it, "dcsset:use")
        if use_v == 'false':
            entry['use'] = False
        use_in_dont_use = []
        for ch in it.child_nodes:
            if ch.namespace_uri != NS_SET:
                continue
            m = re.match(r'^useIn(.+)$', ch.local_name)
            if m and ch.inner_text == 'DontUse':
                tail = m.group(1)
                short_name = tail[0].lower() + tail[1:]
                use_in_dont_use.append(short_name)
        if len(use_in_dont_use) > 0:
            entry['useInDontUse'] = use_in_dont_use
        out.append(entry)
        i += 1
    return out


# Build outputParameters dict
output_param_types_known = {
    'Заголовок': 'mltext',
    'ВыводитьЗаголовок': 'dcsset:DataCompositionTextOutputType',
    'ВыводитьПараметрыДанных': 'dcsset:DataCompositionTextOutputType',
    'ВыводитьОтбор': 'dcsset:DataCompositionTextOutputType',
    'МакетОформления': 'xs:string',
    'РасположениеПолейГруппировки': 'dcsset:DataCompositionGroupFieldsPlacement',
    'РасположениеРеквизитов': 'dcsset:DataCompositionAttributesPlacement',
    'ГоризонтальноеРасположениеОбщихИтогов': 'dcscor:DataCompositionTotalPlacement',
    'ВертикальноеРасположениеОбщихИтогов': 'dcscor:DataCompositionTotalPlacement',
    'РасположениеОбщихИтогов': 'dcscor:DataCompositionTotalPlacement',
    'РасположениеИтогов': 'dcscor:DataCompositionTotalPlacement',
    'РасположениеГруппировки': 'dcsset:DataCompositionFieldGroupPlacement',
    'РасположениеРесурсов': 'dcsset:DataCompositionResourcesPlacement',
    'ТипМакета': 'dcsset:DataCompositionGroupTemplateType',
}


def build_output_parameters(op_node):
    if not op_node:
        return None
    d = {}
    for it in op_node.select_nodes("dcscor:item"):
        p_name = get_text(it, "dcscor:parameter")
        val = it.select_single_node("dcscor:value")
        if not p_name or not val:
            continue
        v_type = get_local_xsi_type(val)
        full_type = val.get_attr_raw('xsi:type')
        if v_type == 'LocalStringType':
            raw_val = get_ml_text(val)
        elif v_type == 'Font':
            raw_val = get_font_value(val)
        else:
            raw_val = val.inner_text
        nested_items = {}
        for sub in it.select_nodes("dcscor:item"):
            sub_name = get_text(sub, "dcscor:parameter")
            sub_val = sub.select_single_node("dcscor:value")
            if not sub_name or not sub_val:
                continue
            sub_type = get_local_xsi_type(sub_val)
            sub_full = sub_val.get_attr_raw('xsi:type')
            if sub_type == 'LocalStringType':
                sub_raw = get_ml_text(sub_val)
            elif sub_type == 'Font':
                sub_raw = get_font_value(sub_val)
            else:
                sub_raw = sub_val.inner_text
            sub_type_field = sub_full
            if sub_full:
                m = re.match(r'^([^:]+):(.+)$', sub_full)
                if m:
                    pfx = m.group(1)
                    local_name = m.group(2)
                    uri = sub_val.get_namespace_of_prefix(pfx)
                    if uri and uri not in (
                        'http://www.w3.org/2001/XMLSchema',
                        'http://www.w3.org/2001/XMLSchema-instance',
                        'http://v8.1c.ru/8.1/data-composition-system/schema',
                        'http://v8.1c.ru/8.1/data-composition-system/settings',
                        'http://v8.1c.ru/8.1/data-composition-system/core',
                        'http://v8.1c.ru/8.1/data-composition-system/common',
                        'http://v8.1c.ru/8.1/data/core',
                        'http://v8.1c.ru/8.1/data/ui',
                    ):
                        sub_type_field = {'uri': uri, 'name': local_name}
            entry = {'value': sub_raw, 'valueType': sub_type_field}
            sub_use = get_text(sub, "dcscor:use")
            if sub_use == 'false':
                entry['use'] = False
            nested_items[sub_name] = entry
        use_v = get_text(it, "dcscor:use")
        vm_n = it.select_single_node("dcsset:viewMode")
        usid_v = get_text(it, "dcsset:userSettingID")
        usp_n = it.select_single_node("dcsset:userSettingPresentation")
        type_auto_detected = False
        if p_name in output_param_types_known:
            map_type = output_param_types_known[p_name]
            if map_type == 'mltext' and v_type == 'LocalStringType':
                type_auto_detected = True
            elif full_type == map_type:
                type_auto_detected = True
        type_is_custom = bool(full_type) and (not re.match(r'^xs:', full_type)) and (v_type != 'LocalStringType') and (v_type != 'Font') and (not type_auto_detected)
        has_extras = (use_v == 'false') or vm_n or usid_v or usp_n or (len(nested_items) > 0) or type_is_custom
        if has_extras:
            wrap = {'value': raw_val}
            if full_type and not (v_type == 'LocalStringType' or v_type == 'Font') and not type_auto_detected:
                wrap['valueType'] = full_type
            if use_v == 'false':
                wrap['use'] = False
            if len(nested_items) > 0:
                wrap['items'] = nested_items
            if vm_n:
                wrap['viewMode'] = vm_n.inner_text
            if usid_v:
                wrap['userSettingID'] = 'auto'
            if usp_n:
                wrap['userSettingPresentation'] = get_ml_text(usp_n)
            d[p_name] = wrap
        else:
            d[p_name] = raw_val
    return d


auto_dates_companions = {}


def build_data_parameters(dp_node, top_params):
    if not dp_node:
        return None
    items = dp_node.select_nodes("dcscor:item")
    if len(items) == 0:
        return None
    visible_top = {}
    for tp in top_params:
        if not tp['hidden'] and tp['name'] not in auto_dates_companions:
            visible_top[tp['name']] = tp
    can_auto = True
    present_names = {}
    entries = []
    for it in items:
        pn = get_text(it, "dcscor:parameter")
        present_names[pn] = True
        usid = get_text(it, "dcsset:userSettingID")
        if not usid:
            can_auto = False
        val_node = it.select_single_node("dcscor:value")
        use = get_text(it, "dcscor:use")
        if use == 'false':
            can_auto = False
        vm_n = it.select_single_node("dcsset:viewMode")
        usp_n = it.select_single_node("dcsset:userSettingPresentation")
        if vm_n or usp_n:
            can_auto = False
        tp = visible_top.get(pn)
        flags = []
        if usid:
            flags.append('@user')
        if use == 'false':
            flags.append('@off')
        vt = get_local_xsi_type(val_node)
        v_display = None
        std_period_obj = None
        if vt == 'StandardPeriod':
            variant = get_text(val_node, "v8:variant")
            sd = get_text(val_node, "v8:startDate")
            ed = get_text(val_node, "v8:endDate")
            has_explicit_dates = (sd and sd != '0001-01-01T00:00:00') or (ed and ed != '0001-01-01T00:00:00')
            if has_explicit_dates:
                std_period_obj = {'variant': variant}
                if sd:
                    std_period_obj['startDate'] = sd
                if ed:
                    std_period_obj['endDate'] = ed
                can_auto = False
            elif variant:
                v_display = variant
                if vm_n or usp_n:
                    std_period_obj = {'variant': variant}
        elif vt == 'StandardBeginningDate':
            variant = get_text(val_node, "v8:variant")
            d_ = get_text(val_node, "v8:date")
            has_explicit_date = d_ and d_ != '0001-01-01T00:00:00'
            if has_explicit_date:
                std_period_obj = {'variant': variant, 'date': d_}
                can_auto = False
            elif variant:
                std_period_obj = {'variant': variant}
                can_auto = False
        elif vt == 'DesignTimeValue':
            v_display = val_node.inner_text
        elif vt == 'LocalStringType':
            v_display = get_ml_text(val_node)
        else:
            if val_node:
                v_display = val_node.inner_text
        if tp and tp['valueDisplay'] != v_display:
            can_auto = False
        if not tp:
            can_auto = False
        is_empty_string_placeholder = (vt == 'string') and (not val_node.inner_text) and (use == 'false')
        if is_empty_string_placeholder:
            can_auto = False
        if std_period_obj or vm_n or usp_n or is_empty_string_placeholder:
            obj = {'parameter': pn}
            if std_period_obj:
                obj['value'] = std_period_obj
            elif is_empty_string_placeholder:
                obj['value'] = ''
                obj['valueType'] = 'xs:string'
            elif v_display is not None and v_display != '':
                if vt == 'boolean':
                    obj['value'] = (v_display == 'true')
                elif vt == 'decimal':
                    if re.match(r'^-?\d+$', v_display):
                        obj['value'] = int(v_display)
                    else:
                        obj['value'] = float(v_display)
                else:
                    obj['value'] = v_display
                ta = val_node.get_attr_raw('xsi:type')
                if ta:
                    obj['valueType'] = ta
            if use == 'false':
                obj['use'] = False
            if usid:
                obj['userSettingID'] = 'auto'
            if vm_n:
                obj['viewMode'] = vm_n.inner_text
            if usp_n:
                usp_v = get_ml_text(usp_n)
                if usp_v:
                    obj['userSettingPresentation'] = usp_v
            entries.append(obj)
        else:
            s = pn
            if v_display is not None and v_display != '':
                s += " = %s" % v_display
            if flags:
                s += ' ' + ' '.join(flags)
            entries.append(s)
    for vn in visible_top:
        if vn not in present_names:
            can_auto = False
    if can_auto:
        return 'auto'
    return entries


def get_group_fields(parent_node, loc):
    g_fields = []
    gi = parent_node.select_single_node("dcsset:groupItems")
    if not gi:
        return g_fields
    for g_item in gi.select_nodes("dcsset:item"):
        gxt = get_local_xsi_type(g_item)
        if gxt == 'GroupItemAuto':
            g_fields.append('Auto')
        elif gxt == 'GroupItemField':
            gf = get_text(g_item, "dcsset:field")
            pat = get_text(g_item, "dcsset:periodAdditionType")
            gt = get_text(g_item, "dcsset:groupType")
            pab_n = g_item.select_single_node("dcsset:periodAdditionBegin")
            pae_n = g_item.select_single_node("dcsset:periodAdditionEnd")
            pab = None
            pae = None
            if pab_n:
                pt = get_local_xsi_type(pab_n)
                pv = pab_n.inner_text
                if pt == 'Field' or (pv and pv != '0001-01-01T00:00:00'):
                    pab = pv
            if pae_n:
                pt = get_local_xsi_type(pae_n)
                pv = pae_n.inner_text
                if pt == 'Field' or (pv and pv != '0001-01-01T00:00:00'):
                    pae = pv
            is_default = (not pat or pat == 'None') and (not gt or gt == 'Items') and (not pab) and (not pae)
            if is_default:
                g_fields.append(gf)
            else:
                obj = {'field': gf}
                if gt and gt != 'Items':
                    obj['groupType'] = gt
                if pat and pat != 'None':
                    obj['periodAdditionType'] = pat
                if pab:
                    obj['periodAdditionBegin'] = pab
                if pae:
                    obj['periodAdditionEnd'] = pae
                g_fields.append(obj)
        else:
            g_fields.append(new_sentinel("GroupItem:%s" % gxt, "%s/groupItems" % loc, 'Тип элемента группировки не покрыт'))
    return g_fields


def build_table_axis_block(node, loc, include_name=False):
    entry = {}
    nm = get_text(node, "dcsset:name")
    if nm:
        entry['name'] = nm
    gf = get_group_fields(node, loc)
    if len(gf) > 0:
        entry['groupFields'] = gf
    f_node = node.select_single_node("dcsset:filter")
    if f_node and len(f_node.select_nodes("dcsset:item")) > 0:
        fa = []
        for fc in f_node.select_nodes("dcsset:item"):
            fa.append(build_filter_item(fc, "%s/filter" % loc))
        entry['filter'] = fa
    # order/selection — всегда явные ([Auto] как есть, отсутствие/пустоту как []): иначе compile
    # впаяет дефолтный Auto → round-trip рвётся на осях без выбора (напр. ветки use=false).
    ord_node = node.select_single_node("dcsset:order")
    ord_items = build_order(ord_node, "%s/order" % loc) if ord_node else []
    entry['order'] = ord_items if len(ord_items) > 0 else []
    sel_node = node.select_single_node("dcsset:selection")
    sel_items = build_selection(sel_node, "%s/selection" % loc) if sel_node else []
    entry['selection'] = sel_items if len(sel_items) > 0 else []
    ca_n = node.select_single_node("dcsset:conditionalAppearance")
    if ca_n:
        ca = build_conditional_appearance(ca_n, "%s/ca" % loc)
        if len(ca) > 0:
            entry['conditionalAppearance'] = ca
    op_node = node.select_single_node("dcsset:outputParameters")
    op = build_output_parameters(op_node)
    if op and len(op) > 0:
        entry['outputParameters'] = op
    children = build_structure(node, "%s/children" % loc)
    if len(children) > 0:
        entry['children'] = children
    avm_node = node.select_single_node("dcsset:viewMode")
    if avm_node:
        entry['viewMode'] = avm_node.inner_text
    ausid = get_text(node, "dcsset:userSettingID")
    if ausid:
        entry['userSettingID'] = 'auto'
    aus_pres_node = node.select_single_node("dcsset:userSettingPresentation")
    if aus_pres_node:
        aus_pres = get_ml_text(aus_pres_node)
        if aus_pres:
            entry['userSettingPresentation'] = aus_pres
    aivm_node = node.select_single_node("dcsset:itemsViewMode")
    if aivm_node:
        entry['itemsViewMode'] = aivm_node.inner_text
    return entry


def build_structure(node, loc):
    if not node:
        return []
    items = []
    idx = 0
    for it in node.select_nodes("dcsset:item"):
        xt = get_local_xsi_type(it)
        if xt == 'StructureItemTable':
            entry = {'type': 'table'}
            nm = get_text(it, "dcsset:name")
            if nm:
                entry['name'] = nm
            cols = []
            for cn in it.select_nodes("dcsset:column"):
                cols.append(build_table_axis_block(cn, "%s/%d/column" % (loc, idx)))
            if len(cols) > 0:
                entry['columns'] = cols
            rows = []
            for rn in it.select_nodes("dcsset:row"):
                rows.append(build_table_axis_block(rn, "%s/%d/row" % (loc, idx), include_name=True))
            if len(rows) > 0:
                entry['rows'] = rows
            t_sel_n = it.select_single_node("dcsset:selection")
            if t_sel_n:
                t_sel_i = build_selection(t_sel_n, "%s/%d/selection" % (loc, idx))
                if len(t_sel_i) > 0:
                    entry['selection'] = t_sel_i
            t_op_n = it.select_single_node("dcsset:outputParameters")
            t_op = build_output_parameters(t_op_n)
            if t_op and len(t_op) > 0:
                entry['outputParameters'] = t_op
            t_ca_n = it.select_single_node("dcsset:conditionalAppearance")
            if t_ca_n:
                t_ca = build_conditional_appearance(t_ca_n, "%s/%d/ca" % (loc, idx))
                if len(t_ca) > 0:
                    entry['conditionalAppearance'] = t_ca
            t_use = get_text(it, "dcsset:use")
            if t_use == 'false':
                entry['use'] = False
            for ch in it.child_nodes:
                if ch.namespace_uri != NS_SET:
                    continue
                if ch.local_name == 'viewMode' and 'viewMode' not in entry:
                    entry['viewMode'] = ch.inner_text
                elif ch.local_name == 'userSettingID' and 'userSettingID' not in entry:
                    entry['userSettingID'] = 'auto'
                elif ch.local_name == 'userSettingPresentation' and 'userSettingPresentation' not in entry:
                    usp_v = get_ml_text(ch)
                    if usp_v:
                        entry['userSettingPresentation'] = usp_v
                elif ch.local_name == 'itemsViewMode' and 'itemsViewMode' not in entry:
                    entry['itemsViewMode'] = ch.inner_text
                elif ch.local_name == 'columnsViewMode' and 'columnsViewMode' not in entry:
                    entry['columnsViewMode'] = ch.inner_text
                elif ch.local_name == 'rowsViewMode' and 'rowsViewMode' not in entry:
                    entry['rowsViewMode'] = ch.inner_text
            items.append(entry)
            idx += 1
            continue
        if xt == 'StructureItemNestedObject':
            entry = {'type': 'nestedObject'}
            obj_id = get_text(it, "dcsset:objectID")
            if obj_id:
                entry['objectID'] = obj_id
            settings_node = it.select_single_node("dcsset:settings")
            if settings_node:
                nested_settings = {}
                sel_node = settings_node.select_single_node("dcsset:selection")
                sel_i = build_selection(sel_node, "%s/%d/nested/selection" % (loc, idx))
                if len(sel_i) > 0:
                    nested_settings['selection'] = sel_i
                f_node = settings_node.select_single_node("dcsset:filter")
                if f_node and len(f_node.select_nodes("dcsset:item")) > 0:
                    fa = []
                    for fc in f_node.select_nodes("dcsset:item"):
                        fa.append(build_filter_item(fc, "%s/%d/nested/filter" % (loc, idx)))
                    nested_settings['filter'] = fa
                o_node = settings_node.select_single_node("dcsset:order")
                o_i = build_order(o_node, "%s/%d/nested/order" % (loc, idx))
                if len(o_i) > 0:
                    nested_settings['order'] = o_i
                ca_node = settings_node.select_single_node("dcsset:conditionalAppearance")
                if ca_node:
                    ca = build_conditional_appearance(ca_node, "%s/%d/nested/ca" % (loc, idx))
                    if len(ca) > 0:
                        nested_settings['conditionalAppearance'] = ca
                op_node = settings_node.select_single_node("dcsset:outputParameters")
                op = build_output_parameters(op_node)
                if op and len(op) > 0:
                    nested_settings['outputParameters'] = op
                entry['settings'] = nested_settings
            items.append(entry)
            idx += 1
            continue
        if xt == 'StructureItemChart':
            entry = {'type': 'chart'}
            nm = get_text(it, "dcsset:name")
            if nm:
                entry['name'] = nm
            pn_list = it.select_nodes("dcsset:point")
            if len(pn_list) == 1:
                entry['points'] = build_table_axis_block(pn_list[0], "%s/%d/point" % (loc, idx))
            elif len(pn_list) > 1:
                p_arr = []
                pi = 0
                for p in pn_list:
                    p_arr.append(build_table_axis_block(p, "%s/%d/point[%d]" % (loc, idx, pi)))
                    pi += 1
                entry['points'] = p_arr
            sn_list = it.select_nodes("dcsset:series")
            if len(sn_list) == 1:
                entry['series'] = build_table_axis_block(sn_list[0], "%s/%d/series" % (loc, idx))
            elif len(sn_list) > 1:
                s_arr = []
                si = 0
                for s in sn_list:
                    s_arr.append(build_table_axis_block(s, "%s/%d/series[%d]" % (loc, idx, si)))
                    si += 1
                entry['series'] = s_arr
            # chart-level selection — всегда явно ([] при отсутствии/пустоте, иначе compile впаяет Auto)
            sel_n = it.select_single_node("dcsset:selection")
            sel_i = build_selection(sel_n, "%s/%d/selection" % (loc, idx)) if sel_n else []
            entry['selection'] = sel_i if len(sel_i) > 0 else []
            op_n = it.select_single_node("dcsset:outputParameters")
            op = build_output_parameters(op_n)
            if op and len(op) > 0:
                entry['outputParameters'] = op
            ch_use = get_text(it, "dcsset:use")
            if ch_use == 'false':
                entry['use'] = False
            for ch in it.child_nodes:
                if ch.namespace_uri != NS_SET:
                    continue
                if ch.local_name == 'viewMode' and 'viewMode' not in entry:
                    entry['viewMode'] = ch.inner_text
                elif ch.local_name == 'userSettingID' and 'userSettingID' not in entry:
                    entry['userSettingID'] = 'auto'
                elif ch.local_name == 'userSettingPresentation' and 'userSettingPresentation' not in entry:
                    usp_v = get_ml_text(ch)
                    if usp_v:
                        entry['userSettingPresentation'] = usp_v
                elif ch.local_name == 'itemsViewMode' and 'itemsViewMode' not in entry:
                    entry['itemsViewMode'] = ch.inner_text
                elif ch.local_name == 'pointsViewMode' and 'pointsViewMode' not in entry:
                    entry['pointsViewMode'] = ch.inner_text
                elif ch.local_name == 'seriesViewMode' and 'seriesViewMode' not in entry:
                    entry['seriesViewMode'] = ch.inner_text
            items.append(entry)
            idx += 1
            continue
        if xt and xt != 'StructureItemGroup':
            items.append(new_sentinel("StructureItem:%s" % xt, loc, 'Тип структуры пока не покрыт'))
            idx += 1
            continue
        entry = {}
        g_use = get_text(it, "dcsset:use")
        if g_use == 'false':
            entry['use'] = False
        nm = get_text(it, "dcsset:name")
        if nm:
            entry['name'] = nm
        g_fields = get_group_fields(it, loc)
        if len(g_fields) > 0:
            entry['groupFields'] = g_fields

        # Local selection/order — всегда явные ([Auto] как есть, отсутствие/пустоту как []): иначе
        # compile впаяет дефолтный Auto → round-trip рвётся на группах без выбора (напр. use=false).
        # [] не Auto-only → try_structure_shorthand не свернёт такую группу в shorthand (без Auto).
        sel_node = it.select_single_node("dcsset:selection")
        sel_items = build_selection(sel_node, "%s/selection" % loc) if sel_node else []
        entry['selection'] = sel_items if len(sel_items) > 0 else []
        ord_node = it.select_single_node("dcsset:order")
        ord_items = build_order(ord_node, "%s/order" % loc) if ord_node else []
        entry['order'] = ord_items if len(ord_items) > 0 else []
        if ord_node:
            for ch in ord_node.child_nodes:
                if ch.namespace_uri != NS_SET:
                    continue
                if ch.local_name == 'viewMode':
                    entry['orderViewMode'] = ch.inner_text
                elif ch.local_name == 'userSettingID':
                    entry['orderUserSettingID'] = 'auto'
        filter_node = it.select_single_node("dcsset:filter")
        if filter_node and len(filter_node.select_nodes("dcsset:item")) > 0:
            f = []
            for fc in filter_node.select_nodes("dcsset:item"):
                f.append(build_filter_item(fc, "%s/filter" % loc))
            entry['filter'] = f
        ca_node = it.select_single_node("dcsset:conditionalAppearance")
        if ca_node:
            ca = build_conditional_appearance(ca_node, "%s/ca" % loc)
            if len(ca) > 0:
                entry['conditionalAppearance'] = ca
        op_node = it.select_single_node("dcsset:outputParameters")
        op = build_output_parameters(op_node)
        if op and len(op) > 0:
            entry['outputParameters'] = op

        children = build_structure(it, "%s/children" % loc)
        if len(children) > 0:
            entry['children'] = children

        gvm = None
        givm = None
        gusid = None
        gusp_node = None
        for ch in it.child_nodes:
            if ch.namespace_uri != NS_SET:
                continue
            if ch.local_name == 'viewMode' and gvm is None:
                gvm = ch.inner_text
            elif ch.local_name == 'itemsViewMode' and givm is None:
                givm = ch.inner_text
            elif ch.local_name == 'userSettingID' and gusid is None:
                gusid = ch.inner_text
            elif ch.local_name == 'userSettingPresentation' and gusp_node is None:
                gusp_node = ch
        if gvm is not None:
            entry['viewMode'] = gvm
        if givm is not None:
            entry['itemsViewMode'] = givm
        if gusid:
            entry['userSettingID'] = 'auto'
        if gusp_node:
            gusp = get_ml_text(gusp_node)
            if gusp:
                entry['userSettingPresentation'] = gusp

        items.append(entry)
        idx += 1
    return items


def is_auto_only(val):
    # True when selection/order is just the single auto element ("Auto") that the
    # compiler adds by default to every shorthand group — folding such a group back
    # to shorthand is bit-perfect (parse re-adds it on compile). Disabled auto
    # ({auto,use}), mixed lists and explicit fields won't match → keep object form.
    if val is None:
        return False
    arr = val if isinstance(val, list) else [val]
    return len(arr) == 1 and isinstance(arr[0], str) and arr[0] == 'Auto'


def try_structure_shorthand(items):
    if len(items) != 1:
        return None
    parts = []
    cur = items[0]
    while cur is not None:
        if 'type' in cur and cur['type'] != 'group':
            return None
        if 'name' in cur:
            return None
        if 'selection' in cur and not is_auto_only(cur['selection']):
            return None
        if 'order' in cur and not is_auto_only(cur['order']):
            return None
        if 'filter' in cur:
            return None
        if 'viewMode' in cur:
            return None
        if 'itemsViewMode' in cur:
            return None
        if 'userSettingID' in cur:
            return None
        if 'userSettingPresentation' in cur:
            return None
        if 'use' in cur:
            return None
        if 'conditionalAppearance' in cur:
            return None
        if 'outputParameters' in cur:
            return None
        gfs = cur.get('groupFields')
        if gfs is None or len(gfs) == 0:
            parts.append('details')
            break
        if len(gfs) != 1:
            return None
        if not isinstance(gfs[0], str):
            return None
        parts.append(gfs[0])
        children = cur.get('children')
        if children is None or len(children) == 0:
            break
        if len(children) != 1:
            return None
        cur = children[0]
    return ' > '.join(parts)


# --- 4. dataSources / 5. dataSets / ... main runner ---

def build_data_set(ds_node, loc, emit_data_sources):
    xsi_type = get_local_xsi_type(ds_node)
    name = get_text(ds_node, "r:name")
    ds = {'name': name}

    if xsi_type == 'DataSetQuery':
        query_text = get_text(ds_node, "r:query")
        ds['query'] = maybe_externalize_query(query_text, name)
    elif xsi_type == 'DataSetObject':
        ds['objectName'] = get_text(ds_node, "r:objectName")
    elif xsi_type == 'DataSetUnion':
        nested = []
        ni = 0
        inner_nodes = list(ds_node.select_nodes("r:item")) + list(ds_node.select_nodes("r:dataSet"))
        for n_node in inner_nodes:
            nested.append(build_data_set(n_node, "%s/items[%d]" % (loc, ni), emit_data_sources))
            ni += 1
        ds['items'] = nested
    else:
        ds['__unsupported__'] = new_sentinel("DataSetType:%s" % xsi_type, loc, "Неизвестный тип набора данных")['__unsupported__']

    field_nodes = ds_node.select_nodes("r:field")
    if len(field_nodes) > 0:
        fields = []
        fi = 0
        for fn in field_nodes:
            fxsi = get_local_xsi_type(fn)
            if fxsi == 'DataSetFieldField':
                fields.append(build_field(fn, "%s/field[%d]" % (loc, fi)))
            elif fxsi == 'DataSetFieldFolder':
                folder_obj = {
                    'field': get_text(fn, "r:dataPath"),
                    'folder': True,
                }
                title_node = fn.select_single_node("r:title")
                title = get_ml_text(title_node)
                if title:
                    folder_obj['title'] = title
                fields.append(folder_obj)
            else:
                fields.append(new_sentinel("FieldType:%s" % fxsi, "%s/field[%d]" % (loc, fi), 'Тип поля не DataSetFieldField/Folder'))
            fi += 1
        ds['fields'] = fields

    if xsi_type != 'DataSetUnion':
        ds_src = get_text(ds_node, "r:dataSource")
        if emit_data_sources and ds_src:
            ds['dataSource'] = ds_src

    return ds


def run(root):
    global output_dir, output_basename, auto_dates_companions

    # Ring 3 scans
    for el in root.el.iter():
        local = el.tag.split('}', 1)[1] if '}' in el.tag else el.tag
        if local == 'item':
            xsi = el.get('{%s}type' % NS_XSI) or ''
            ns_uri = el.tag[1:].split('}', 1)[0] if el.tag.startswith('{') else ''
            if re.search(r'Picture$', xsi) and ns_uri == NS_AT:
                fail_ring3("Picture cell в шаблоне", "template/.../item[@xsi:type=Picture]")
        if local == 'Type':
            inner = _inner_text(el)
            if re.search(r'^v8:ValueStorage$|:ValueStorage$', inner or ''):
                fail_ring3("параметр типа ХранилищеЗначения", "valueType[v8:Type=ValueStorage]")
        if local == 'templateCondition':
            fail_ring3("templateCondition (вариативные шаблоны)", "template/templateCondition")
        if local == 'nestedSchema':
            fail_ring3("nestedSchema (вложенные подсхемы)", "nestedSchema")

    ds_count_check = 0
    for el in root.el.iter():
        local = el.tag.split('}', 1)[1] if '}' in el.tag else el.tag
        if local == 'dataSet':
            ds_count_check += 1
    if ds_count_check == 0:
        fail_ring3("отчёт без dataSet (служебный шаблон-обёртка)", "DataCompositionSchema/dataSet")

    # Resolve outputPath + load user styles
    global OutputPath
    if OutputPath:
        if not os.path.isabs(OutputPath):
            OutputPath = os.path.join(os.getcwd(), OutputPath)
        output_dir = os.path.dirname(OutputPath)
        output_basename = os.path.splitext(os.path.basename(OutputPath))[0]
        load_user_styles(output_dir)

    data_sources = []
    dsource_nodes = root.select_nodes("r:dataSource")
    for dsn in dsource_nodes:
        nm = get_text(dsn, "r:name")
        tp = get_text(dsn, "r:dataSourceType")
        data_sources.append({'name': nm, 'type': tp})
    emit_data_sources = True
    if len(data_sources) == 1 and data_sources[0]['name'] == 'ИсточникДанных1' and data_sources[0]['type'] == 'Local':
        emit_data_sources = False

    # --- 5. dataSets ---
    data_sets = []
    ds_nodes = root.select_nodes("r:dataSet")
    dsi = 0
    for ds_node in ds_nodes:
        data_sets.append(build_data_set(ds_node, "dataSet[%d]" % dsi, emit_data_sources))
        dsi += 1

    # --- 5a-bis. dataSetLinks ---
    data_set_links = []
    dsl_nodes = root.select_nodes("r:dataSetLink")
    for dsl_node in dsl_nodes:
        link = {}
        link['sourceDataSet']         = get_text(dsl_node.select_single_node("r:sourceDataSet"))
        link['destinationDataSet']    = get_text(dsl_node.select_single_node("r:destinationDataSet"))
        link['sourceExpression']      = get_text(dsl_node.select_single_node("r:sourceExpression"))
        link['destinationExpression'] = get_text(dsl_node.select_single_node("r:destinationExpression"))
        p_node = dsl_node.select_single_node("r:parameter")
        if p_node:
            link['parameter'] = p_node.inner_text
        pla_node = dsl_node.select_single_node("r:parameterListAllowed")
        if pla_node and pla_node.inner_text == 'true':
            link['parameterListAllowed'] = True
        se_node = dsl_node.select_single_node("r:startExpression")
        if se_node:
            link['startExpression'] = se_node.inner_text
        lce_node = dsl_node.select_single_node("r:linkConditionExpression")
        if lce_node:
            link['linkConditionExpression'] = lce_node.inner_text
        data_set_links.append(link)

    # --- 5b. calculatedFields ---
    calculated_fields = []
    cf_nodes = root.select_nodes("r:calculatedField")
    ci = 0
    for cf in cf_nodes:
        calculated_fields.append(build_calc_field(cf, "calculatedField[%d]" % ci))
        ci += 1

    # --- 5c. totalFields ---
    total_fields = []
    tf_nodes = root.select_nodes("r:totalField")
    for tf in tf_nodes:
        total_fields.append(build_total_field(tf))

    # --- 5d. parameters with autoDates folding ---
    params_raw = []
    pi = 0
    p_nodes = root.select_nodes("r:parameter")
    for p in p_nodes:
        params_raw.append(build_parameter(p, "parameter[%d]" % pi))
        pi += 1

    param_by_name = {}
    for p in params_raw:
        param_by_name[p['name']] = p

    removed_names = {}
    auto_dates_companions.clear()
    for p in params_raw:
        if p['typeShort'] != 'StandardPeriod':
            continue
        parent_name = p['name']
        start_expr = '&' + parent_name + '.ДатаНачала'
        end_expr = '&' + parent_name + '.ДатаОкончания'
        start_match = None
        end_match = None
        for q in params_raw:
            if q['name'] == parent_name:
                continue
            if q['expression'] == start_expr:
                start_match = q['name']
            elif q['expression'] == end_expr:
                end_match = q['name']
        begin_p = param_by_name.get(start_match)
        end_p = param_by_name.get(end_match)
        has_not_a_field = (begin_p and begin_p['notAField']) or (end_p and end_p['notAField'])
        if start_match == 'НачалоПериода' and end_match == 'КонецПериода' and not has_not_a_field:
            p['autoDates'] = True
            removed_names[start_match] = True
            removed_names[end_match] = True
            auto_dates_companions[start_match] = True
            auto_dates_companions[end_match] = True

    parameters = []
    for p in params_raw:
        if p['name'] in removed_names:
            continue
        parameters.append(render_parameter(p))

    # --- 6. Build top-level JSON object ---
    out = {}
    if emit_data_sources:
        out['dataSources'] = data_sources
    out['dataSets'] = data_sets
    if len(data_set_links) > 0:
        out['dataSetLinks'] = data_set_links
    if len(calculated_fields) > 0:
        out['calculatedFields'] = calculated_fields
    if len(total_fields) > 0:
        out['totalFields'] = total_fields
    if len(parameters) > 0:
        out['parameters'] = parameters

    # --- 5e. templates ---
    templates = []
    t_nodes = root.select_nodes("r:template")
    ti = 0
    for tn in t_nodes:
        templates.append(build_template(tn, "template[%d]" % ti))
        ti += 1
    if len(templates) > 0:
        out['templates'] = templates

    # --- 5e2. fieldTemplates ---
    field_templates = []
    for ftn in root.select_nodes("r:fieldTemplate"):
        ft_field = get_text(ftn, "r:field")
        ft_templ = get_text(ftn, "r:template")
        field_templates.append({'field': ft_field, 'template': ft_templ})
    if len(field_templates) > 0:
        out['fieldTemplates'] = field_templates

    # --- 5f. groupTemplates ---
    group_templates = []
    for ght in root.select_nodes("r:groupHeaderTemplate"):
        entry = {}
        gn = get_text(ght, "r:groupName")
        gf = get_text(ght, "r:groupField")
        if gn:
            entry['groupName'] = gn
        if gf:
            entry['groupField'] = gf
        entry['templateType'] = 'GroupHeader'
        entry['template'] = get_text(ght, "r:template")
        group_templates.append(entry)
    for gt in root.select_nodes("r:groupTemplate"):
        entry = {}
        gn = get_text(gt, "r:groupName")
        gf = get_text(gt, "r:groupField")
        if gn:
            entry['groupName'] = gn
        if gf:
            entry['groupField'] = gf
        entry['templateType'] = get_text(gt, "r:templateType")
        entry['template'] = get_text(gt, "r:template")
        group_templates.append(entry)
    if len(group_templates) > 0:
        out['groupTemplates'] = group_templates

    # --- 5g. settingsVariants ---
    def get_block_vm(node):
        if not node:
            return None
        for child in node.child_nodes:
            if child.local_name == 'viewMode' and child.namespace_uri == NS_SET:
                return child.inner_text
        return None

    def get_block_usid(node):
        if not node:
            return None
        for child in node.child_nodes:
            if child.local_name == 'userSettingID' and child.namespace_uri == NS_SET:
                return child.inner_text
        return None

    settings_variants = []
    sv_nodes = root.select_nodes("r:settingsVariant")
    vi = 0
    for sv in sv_nodes:
        vname = get_text(sv, "dcsset:name")
        pres_node = sv.select_single_node("dcsset:presentation")
        presentation = get_ml_text(pres_node)

        settings_node = sv.select_single_node("dcsset:settings")
        settings = {}

        # userFields
        uf_node = settings_node.select_single_node("dcsset:userFields") if settings_node else None
        if uf_node:
            uf_list = []
            ufi = 0
            for uf_item in uf_node.select_nodes("dcsset:item"):
                uxt = get_local_xsi_type(uf_item)
                entry = {}
                dp = get_text(uf_item, "dcsset:dataPath")
                if dp:
                    entry['dataPath'] = dp
                title_n = uf_item.select_single_node("dcsset:lwsTitle")
                title_v = get_ml_text(title_n)
                if title_v:
                    entry['title'] = title_v
                if uxt == 'UserFieldExpression':
                    d_ex_n = uf_item.select_single_node("dcsset:detailExpression")
                    d_ep_n = uf_item.select_single_node("dcsset:detailExpressionPresentation")
                    t_ex_n = uf_item.select_single_node("dcsset:totalExpression")
                    t_ep_n = uf_item.select_single_node("dcsset:totalExpressionPresentation")
                    if d_ex_n or d_ep_n:
                        d = {}
                        if d_ex_n:
                            d['expression'] = d_ex_n.inner_text
                        if d_ep_n:
                            d['presentation'] = d_ep_n.inner_text
                        entry['detail'] = d
                    if t_ex_n or t_ep_n:
                        t = {}
                        if t_ex_n:
                            t['expression'] = t_ex_n.inner_text
                        if t_ep_n:
                            t['presentation'] = t_ep_n.inner_text
                        entry['total'] = t
                elif uxt == 'UserFieldCase':
                    cases_node = uf_item.select_single_node("dcsset:cases")
                    cases_arr = []
                    if cases_node:
                        for case_item in cases_node.select_nodes("dcsset:item"):
                            ce = {}
                            cf_node2 = case_item.select_single_node("dcsset:filter")
                            if cf_node2 and len(cf_node2.select_nodes("dcsset:item")) > 0:
                                cfa = []
                                for cfi in cf_node2.select_nodes("dcsset:item"):
                                    cfa.append(build_filter_item(cfi, "variant[%d]/userField/case/filter" % vi))
                                ce['filter'] = cfa
                            cv_node = case_item.select_single_node("dcsset:value")
                            if cv_node:
                                cv_type = get_local_xsi_type(cv_node)
                                cv_text = cv_node.inner_text
                                if cv_type == 'boolean':
                                    ce['value'] = (cv_text == 'true')
                                elif cv_type == 'decimal':
                                    if re.match(r'^-?\d+$', cv_text or ''):
                                        ce['value'] = int(cv_text)
                                    else:
                                        ce['value'] = float(cv_text)
                                else:
                                    ce['value'] = cv_text
                            cp_node = case_item.select_single_node("dcsset:lwsPresentationValue")
                            cp_v = get_ml_text(cp_node)
                            if cp_v:
                                ce['presentation'] = cp_v
                            cases_arr.append(ce)
                    entry['cases'] = cases_arr
                else:
                    entry['__unsupported__'] = new_sentinel("UserField:%s" % uxt, "variant[%d]/userField[%d]" % (vi, ufi), 'Неизвестный тип пользовательского поля')['__unsupported__']
                uf_list.append(entry)
                ufi += 1
            if len(uf_list) > 0:
                settings['userFields'] = uf_list

        # selection (top-level)
        sel_top = settings_node.select_single_node("dcsset:selection") if settings_node else None
        sel_items = build_selection(sel_top, "variant[%d]/selection" % vi)
        if len(sel_items) > 0:
            settings['selection'] = sel_items
        svm = get_block_vm(sel_top)
        if svm is not None:
            settings['selectionViewMode'] = svm
        susid = get_block_usid(sel_top)
        if susid:
            settings['selectionUserSettingID'] = 'auto'

        # filter
        f_top = settings_node.select_single_node("dcsset:filter") if settings_node else None
        if f_top and len(f_top.select_nodes("dcsset:item")) > 0:
            fa = []
            for fc in f_top.select_nodes("dcsset:item"):
                fa.append(build_filter_item(fc, "variant[%d]/filter" % vi))
            settings['filter'] = fa
        fvm = get_block_vm(f_top)
        if fvm is not None:
            settings['filterViewMode'] = fvm
        fusid = get_block_usid(f_top)
        if fusid:
            settings['filterUserSettingID'] = 'auto'

        # order
        ord_top = settings_node.select_single_node("dcsset:order") if settings_node else None
        ord_items = build_order(ord_top, "variant[%d]/order" % vi)
        if len(ord_items) > 0:
            settings['order'] = ord_items
        ovm = get_block_vm(ord_top)
        if ovm is not None:
            settings['orderViewMode'] = ovm
        ousid = get_block_usid(ord_top)
        if ousid:
            settings['orderUserSettingID'] = 'auto'

        # conditionalAppearance
        ca_top = settings_node.select_single_node("dcsset:conditionalAppearance") if settings_node else None
        if ca_top:
            ca = build_conditional_appearance(ca_top, "variant[%d]/ca" % vi)
            if len(ca) > 0:
                settings['conditionalAppearance'] = ca
        cavm = get_block_vm(ca_top)
        if cavm is not None:
            settings['conditionalAppearanceViewMode'] = cavm
        causid = get_block_usid(ca_top)
        if causid:
            settings['conditionalAppearanceUserSettingID'] = 'auto'

        # outputParameters
        op_top = settings_node.select_single_node("dcsset:outputParameters") if settings_node else None
        op = build_output_parameters(op_top)
        if op and len(op) > 0:
            settings['outputParameters'] = op

        # dataParameters
        dp_top = settings_node.select_single_node("dcsset:dataParameters") if settings_node else None
        dp = build_data_parameters(dp_top, params_raw)
        if dp is not None:
            settings['dataParameters'] = dp

        # structure
        struct_items = build_structure(settings_node, "variant[%d]/structure" % vi) if settings_node else []
        if len(struct_items) > 0:
            short = try_structure_shorthand(struct_items)
            if short:
                settings['structure'] = short
            else:
                settings['structure'] = struct_items

        sivm_node = settings_node.select_single_node("dcsset:itemsViewMode") if settings_node else None
        if sivm_node:
            settings['itemsViewMode'] = sivm_node.inner_text

        # additionalProperties
        ap_node = settings_node.select_single_node("dcsset:additionalProperties") if settings_node else None
        if ap_node:
            ap_dict = {}
            for prop in ap_node.select_nodes("v8:Property"):
                p_name = prop.el.get("name")
                val_el = prop.select_single_node("v8:Value")
                if p_name and val_el:
                    ap_dict[p_name] = val_el.inner_text
            if len(ap_dict) > 0:
                settings['additionalProperties'] = ap_dict

        non_struct_keys = [k for k in settings if k != 'structure']
        struct_only_details = ('structure' not in settings) or (settings.get('structure') == 'details')
        is_default = (len(non_struct_keys) == 0) and struct_only_details and (vname == 'Основной') and (not presentation or presentation == vname)
        if not is_default:
            entry = {'name': vname}
            if presentation and presentation != vname:
                entry['title'] = presentation
            entry['settings'] = settings
            settings_variants.append(entry)
        vi += 1
    if len(settings_variants) > 0:
        out['settingsVariants'] = settings_variants

    # --- 7. Serialize ---
    json_text = convert_to_compact_json(out)

    if OutputPath:
        with open(OutputPath, 'w', encoding='utf-8', newline='') as f:
            f.write(json_text)
        save_user_styles(output_dir)
        save_query_files()

        if len(warnings_list) > 0:
            base, _ext = os.path.splitext(OutputPath)
            w_path = base + '.warnings.md'
            sb = []
            sb.append("# skd-decompile warnings")
            sb.append("")
            sb.append("Source: %s" % TemplatePath)
            sb.append("")
            for w in warnings_list:
                sb.append("- **%s** (%s) at %s — %s" % (w['id'], w['kind'], w['loc'], w['detail']))
            with open(w_path, 'w', encoding='utf-8', newline='') as f:
                f.write('\r\n'.join(sb) + '\r\n')
            print("Warnings: %s (%d issue(s))" % (w_path, len(warnings_list)))

        print("Decompiled: dataSets=%d, calc=%d, totals=%d, params=%d, templates=%d, groupTemplates=%d, variants=%d, warnings=%d" % (
            len(data_sets), len(calculated_fields), len(total_fields), len(parameters), len(templates), len(group_templates), len(settings_variants), len(warnings_list)
        ), file=sys.stderr)
    else:
        print(json_text)
        if len(warnings_list) > 0:
            print("Warnings (%d):" % len(warnings_list), file=sys.stderr)
            for w in warnings_list:
                print("  %s [%s] %s: %s" % (w['id'], w['kind'], w['loc'], w['detail']), file=sys.stderr)


if __name__ == '__main__':
    main()
