#!/usr/bin/env python3
# form-decompile v0.147 — Decompile 1C managed Form.xml to JSON DSL (draft)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# ВНИМАНИЕ: раундтрип не гарантируется. Навык исключён из авто-использования моделью.
#
# Зеркало form-decompile.ps1 (канон). Структура 1:1 — те же имена функций, порядок,
# комментарии. Изменения вносить сначала в .ps1, затем переносить сюда строка-в-строку.
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import OrderedDict
from decimal import Decimal

# --- 1. Namespaces ---
NS_LF = "http://v8.1c.ru/8.3/xcf/logform"
NS_V8 = "http://v8.1c.ru/8.1/data/core"
NS_XR = "http://v8.1c.ru/8.3/xcf/readable"
NS_XSI = "http://www.w3.org/2001/XMLSchema-instance"

NS_DCSSET = "http://v8.1c.ru/8.1/data-composition-system/settings"
NS_DCSSCH = "http://v8.1c.ru/8.1/data-composition-system/schema"
NS_DCSCOR = "http://v8.1c.ru/8.1/data-composition-system/core"
NS_V8UI = "http://v8.1c.ru/8.1/data/ui"
NS_APP = "http://v8.1c.ru/8.2/managed-application/core"

# Карта префиксов для ET.find/findall (зеркало XmlNamespaceManager).
NS = {
    'lf': NS_LF,
    'v8': NS_V8,
    'xr': NS_XR,
    'xsi': NS_XSI,
    'dcsset': NS_DCSSET,
    'dcssch': NS_DCSSCH,
    'dcscor': NS_DCSCOR,
    'v8ui': NS_V8UI,
    'app': NS_APP,
}

# Каноничные GUID пустых контейнеров ListSettings (умолчание платформы, ~90% форм).
# Если ListSettings = пустой скелет с этими GUID → декомпилятор опускает настройки вовсе,
# компилятор регенерит тот же скелет → чистый раундтрип.
CANON_FILTER_ID = 'dfcece9d-5077-440b-b6b3-45a5cb4538eb'
CANON_ORDER_ID = '88619765-ccb3-46c6-ac52-38e9c992ebd4'
CANON_CA_ID = 'b75fecce-942b-4aed-abc9-e6a02e460fb3'
CANON_ITEMS_ID = '911b6018-f537-43e8-a417-da56b22f9aec'

# Companion-элементы (авто-генерируемые компилятором) — пропускаем при обходе детей.
# Дополнения (Search*/ViewStatus) БОЛЬШЕ не companion — декомпилируются как тип-элементы
# (кастомные в AutoCommandBar/ChildItems → commandBar.children; стандартные на уровне таблицы → карта additions).
COMPANION_TAGS = ['ContextMenu', 'ExtendedTooltip', 'AutoCommandBar']

# Скрипт-скоуп состояние (зеркало $script:* канона). ROOT/NS_DOC ставятся в main().
ROOT = None
NSMAP_DOC = {}
OUTPUT_DIR = None
OUTPUT_BASENAME = None
QUERY_FILES_ACCUMULATOR = []
QUERY_FILE_NAMES_USED = {}

# Атрибут с пространством имён в формате ET ({uri}local) — зеркало GetAttribute("x", $NS_XSI).
_XSI_TYPE = '{%s}type' % NS_XSI


def _attr(node, name, ns_uri=None):
    """GetAttribute(name[, ns]) — .NET возвращает "" для отсутствующего атрибута, ET → None."""
    if node is None:
        return ''
    key = ('{%s}%s' % (ns_uri, name)) if ns_uri else name
    v = node.get(key)
    return v if v is not None else ''


# ═══════════════════════════════════════════════════════════════════════════
# JSON-сериализатор — точное зеркало ConvertTo-CompactJson/Try-InlineJson/
# Convert-StringToJsonLiteral. json.dumps НЕ подходит (иная раскладка inline/
# multiline и эскейпинг). Кириллица в выводе сырая (UTF-8 без эскейпа).
# ═══════════════════════════════════════════════════════════════════════════

def convert_string_to_json_literal(s):
    if s is None:
        return 'null'
    sb = ['"']
    for ch in s:
        code = ord(ch)
        if code == 0x22:
            sb.append('\\"')
        elif code == 0x5C:
            sb.append('\\\\')
        elif code == 0x08:
            sb.append('\\b')
        elif code == 0x09:
            sb.append('\\t')
        elif code == 0x0A:
            sb.append('\\n')
        elif code == 0x0C:
            sb.append('\\f')
        elif code == 0x0D:
            sb.append('\\r')
        elif code < 0x20:
            sb.append('\\u%04x' % code)
        else:
            sb.append(ch)
    sb.append('"')
    return ''.join(sb)


def _num_to_str(obj):
    """Зеркало [System.Convert]::ToString(.., InvariantCulture)."""
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, int):
        return str(obj)
    # Decimal — зеркало [decimal].ToString(): сохраняет масштаб ("1.50" остаётся "1.50").
    if isinstance(obj, Decimal):
        return str(obj)
    # float — зеркало [double].ToString('R'/InvariantCulture): кратчайшее round-trip, без хвостового .0.
    r = repr(float(obj))
    if r.endswith('.0'):
        r = r[:-2]
    return r


def try_inline_json(obj):
    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float, Decimal)):
        return _num_to_str(obj)
    if isinstance(obj, dict):
        if len(obj) == 0:
            return '{}'
        parts = []
        for k in obj.keys():
            v = try_inline_json(obj[k])
            if v is None:
                return None
            parts.append('%s: %s' % (convert_string_to_json_literal(str(k)), v))
        return '{ ' + ', '.join(parts) + ' }'
    if isinstance(obj, (list, tuple)):
        items = list(obj)
        if len(items) == 0:
            return '[]'
        parts = []
        for it in items:
            v = try_inline_json(it)
            if v is None:
                return None
            parts.append(v)
        return '[' + ', '.join(parts) + ']'
    return None


def convert_to_compact_json(obj, depth=0, indent_unit='  ', line_limit=120):
    indent = indent_unit * depth
    child_indent = indent_unit * (depth + 1)
    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float, Decimal)):
        return _num_to_str(obj)
    is_container = isinstance(obj, (dict, list, tuple))
    if is_container:
        inline_attempt = try_inline_json(obj)
        if inline_attempt is not None and (len(indent) + len(inline_attempt)) <= line_limit:
            return inline_attempt
    if isinstance(obj, dict):
        keys = list(obj.keys())
        if len(keys) == 0:
            return '{}'
        parts = []
        for k in keys:
            val = convert_to_compact_json(obj[k], depth + 1, indent_unit, line_limit)
            parts.append('%s%s: %s' % (child_indent, convert_string_to_json_literal(str(k)), val))
        return '{\n' + ',\n'.join(parts) + '\n' + indent + '}'
    if isinstance(obj, (list, tuple)):
        items = list(obj)
        if len(items) == 0:
            return '[]'
        parts = ['%s%s' % (child_indent, convert_to_compact_json(it, depth + 1, indent_unit, line_limit)) for it in items]
        return '[\n' + ',\n'.join(parts) + '\n' + indent + ']'
    return convert_string_to_json_literal(str(obj))


# ═══════════════════════════════════════════════════════════════════════════
# Низкоуровневые читатели текста.
# .NET .InnerText = конкатенация текста всех потомков. PreserveWhitespace=false
# в каноне сворачивает whitespace-only текст-узлы в "". ET не имеет такого режима,
# поэтому два читателя на одном ws-сохраняющем дереве:
#   _text     — main-doc семантика (whitespace-only → ""), для всех чтений значений;
#   _text_ws  — сырой текст (для Resolve-WS: восстановление точного числа пробелов).
# ═══════════════════════════════════════════════════════════════════════════

def _text(node):
    if node is None:
        return None
    s = ''.join(node.itertext())
    if s != '' and s.strip() == '':
        return ''
    return s


def _text_ws(node):
    if node is None:
        return None
    return ''.join(node.itertext())


# Запрос ≥3 строк + есть outputDir → вынести в `<basename>-<listName>.sql`, вернуть "@file".
def maybe_externalize_query(query_text, list_name):
    if not query_text:
        return query_text
    if not OUTPUT_DIR:
        return query_text
    line_count = len(re.findall('\n', query_text)) + 1
    if line_count < 3:
        return query_text
    safe = re.sub(r'[^\w\-]', '_', list_name)
    if not safe:
        safe = 'query'
    prefix = (OUTPUT_BASENAME + '-') if OUTPUT_BASENAME else ''
    file_name = prefix + safe + '.sql'
    suffix = 1
    while file_name in QUERY_FILE_NAMES_USED:
        suffix += 1
        file_name = '%s%s_%d.sql' % (prefix, safe, suffix)
    QUERY_FILE_NAMES_USED[file_name] = True
    QUERY_FILES_ACCUMULATOR.append(OrderedDict([('fileName', file_name), ('text', query_text)]))
    return '@' + file_name


def save_query_files():
    if len(QUERY_FILES_ACCUMULATOR) == 0:
        return
    if not OUTPUT_DIR:
        return
    for qf in QUERY_FILES_ACCUMULATOR:
        with open(os.path.join(OUTPUT_DIR, qf['fileName']), 'w', encoding='utf-8', newline='') as f:
            f.write(qf['text'])
    sys.stderr.write("Saved %d external query file(s)\n" % len(QUERY_FILES_ACCUMULATOR))


# Есть ли в ListSettings содержательные настройки (реальные items фильтра/порядка/
# условного оформления/параметров)? Пустой скелет (только viewMode+GUID) → false.
def test_list_settings_has_content(ls_node):
    if ls_node is None:
        return False
    for cont in ('filter', 'order', 'conditionalAppearance', 'dataParameters'):
        cn = ls_node.find('dcsset:%s' % cont, NS)
        if cn is not None and cn.find('dcsset:item', NS) is not None:
            return True
    return False


# Форма ListSettings: ordered-карта present top-level элементов. $null, если форма ==
# полному каноничному скелету ИЛИ содержит неподдержанные top-level элементы → канон-fallback.
def get_list_settings_shape(ls_node, has_grouping=False):
    if ls_node is None:
        return None
    shape = OrderedDict()
    for child in list(ls_node):
        tag = _local_name(child.tag)
        if tag in ('filter', 'order', 'conditionalAppearance'):
            has_vm = child.find('dcsset:viewMode', NS) is not None
            has_us = child.find('dcsset:userSettingID', NS) is not None
            code = ('v' if has_vm else '') + ('u' if has_us else '')
            usp_node = child.find('dcsset:userSettingPresentation', NS)
            if usp_node is not None:
                usp = get_pres_by_type(usp_node)
                shape[tag] = OrderedDict([('meta', code), ('presentation', usp)])
            else:
                shape[tag] = code
        elif tag == 'itemsViewMode':
            shape['itemsViewMode'] = True
        elif tag == 'itemsUserSettingID':
            shape['itemsUserSettingID'] = True
        elif tag == 'itemsUserSettingPresentation':
            shape['itemsUserSettingPresentation'] = get_pres_by_type(child)
        elif tag == 'dataParameters':
            shape['dataParameters'] = True
        elif tag == 'item':
            if has_grouping:
                shape['structure'] = True
            else:
                return None
        else:
            return None
    if (len(shape) == 5 and shape.get('filter') == 'vu' and shape.get('order') == 'vu'
            and shape.get('conditionalAppearance') == 'vu' and shape.get('itemsViewMode') is True
            and shape.get('itemsUserSettingID') is True):
        return None
    return shape


# Группировка строк динамического списка: цепочка <dcsset:item StructureItemGroup>.
# Плоский массив уровней ИЛИ $null (не «чистая линейная цепочка одно-польных уровней»).
def build_group_level(fn):
    field = get_child(fn, 'field')
    gt = get_child(fn, 'groupType')
    pat = get_child(fn, 'periodAdditionType')
    pab_n = fn.find('dcsset:periodAdditionBegin', NS)
    pae_n = fn.find('dcsset:periodAdditionEnd', NS)
    pab = None
    pae = None
    if pab_n is not None:
        pt = _attr(pab_n, 'type', NS_XSI)
        pv = _text(pab_n)
        if re.search(r'Field$', pt) or (pv and pv != '0001-01-01T00:00:00'):
            pab = pv
    if pae_n is not None:
        pt = _attr(pae_n, 'type', NS_XSI)
        pv = _text(pae_n)
        if re.search(r'Field$', pt) or (pv and pv != '0001-01-01T00:00:00'):
            pae = pv
    is_default = ((not gt) or gt == 'Items') and ((not pat) or pat == 'None') and (not pab) and (not pae)
    if is_default:
        return field
    o = OrderedDict([('field', field)])
    if gt and gt != 'Items':
        o['groupType'] = gt
    if pat and pat != 'None':
        o['periodAdditionType'] = pat
    if pab:
        o['periodAdditionBegin'] = pab
    if pae:
        o['periodAdditionEnd'] = pae
    return o


def build_list_grouping(item_node):
    levels = []
    cur = item_node
    while cur is not None:
        if not re.search(r'StructureItemGroup$', _attr(cur, 'type', NS_XSI)):
            return None
        gi = None
        nested = []
        for ch in list(cur):
            ln = _local_name(ch.tag)
            if ln == 'groupItems':
                if gi is not None:
                    return None
                gi = ch
            elif ln == 'item':
                nested.append(ch)
            else:
                return None
        if gi is None:
            return None
        field_items = gi.findall('dcsset:item', NS)
        if len(field_items) != 1:
            return None
        fn = field_items[0]
        if not re.search(r'GroupItemField$', _attr(fn, 'type', NS_XSI)):
            return None
        levels.append(build_group_level(fn))
        if len(nested) == 0:
            break
        if len(nested) > 1:
            return None
        cur = nested[0]
    if len(levels) == 0:
        return None
    return levels


# Ring-3: конструкции вне зоны поддержки → stderr + exit 3 (см. ring3-скан в main).
def fail_ring3(kind, loc):
    sys.stderr.write("form-decompile: декомпиляция пока не поддерживает %s (path: %s)\n" % (kind, loc))
    sys.stderr.write("Для точечной работы с этой формой используй /form-edit.\n")
    sys.exit(3)


# Извлечь мультиязычный Title/Presentation → string (ru) или ordered hash {ru,en,...}
def get_lang_text(node):
    if node is None:
        return None
    items = node.findall('v8:item', NS)
    if len(items) == 0:
        return None
    m = OrderedDict()
    for it in items:
        lang = it.find('v8:lang', NS)
        content = it.find('v8:content', NS)
        if lang is not None:
            m[_text(lang)] = _text(content) if content is not None else ""
    if len(m) == 1 and 'ru' in m:
        return m['ru']
    return m


# Точное число пробелов whitespace-only <v8:content>: ET хранит .text дословно,
# второй WS-парс не нужен — читаем сырой текст того же узла (_text_ws).
def resolve_ws(content_node):
    if content_node is None:
        return None
    return _text_ws(content_node)


# Точное восстановление пробела: whitespace-only content → реальная строка пробелов.
def restore_ws_content(content_node):
    ws = resolve_ws(content_node)
    if ws and ws.strip() == '':
        return ws
    return ' '


def get_lang_text_ws(node):
    t = get_lang_text(node)
    if t is None:
        return None
    if isinstance(t, str):
        cn = node.find('v8:item/v8:content', NS)
        if t == '' and cn is not None:
            return restore_ws_content(cn)
        return t
    for it in node.findall('v8:item', NS):
        lang = it.find('v8:lang', NS)
        content = it.find('v8:content', NS)
        if lang is not None and content is not None:
            lt = _text(lang)
            if lt in t and t[lt] == '':
                t[lt] = restore_ws_content(content)
    return t


# Авто-вывод заголовка из имени — ТОЧНОЕ зеркало Title-FromName из form-compile.
def title_from_name(name):
    if not name:
        return ''
    s = re.sub(r'([А-ЯA-Z])([А-ЯA-Z][а-яa-z])', r'\1 \2', name)
    s = re.sub(r'([а-яa-z0-9])([А-ЯA-Z])', r'\1 \2', s)
    parts = s.split(' ')
    if len(parts) == 0:
        return s
    out = [parts[0]]
    for i in range(1, len(parts)):
        p = parts[i]
        if len(p) > 1 and p == p.upper():
            out.append(p)
        else:
            out.append(p.lower())
    return ' '.join(out)


# Детектор «настоящей» inline-разметки форматированного текста (идентичен form-compile!).
FMT_MARKUP_RE = r'</>|<\s*(?:link|b|i|u|s|color|colorStyle|bgColor|bgColorStyle|font|fontSize|fontStyle|img)(?:\s|>)'


def test_has_real_markup(text):
    if text is None:
        return False
    vals = list(text.values()) if isinstance(text, dict) else [str(text)]
    for v in vals:
        if re.search(FMT_MARKUP_RE, str(v)):
            return True
    return False


# Title-узел → DSL-значение ML-поля (гибрид): строка/мапа или явный {text, formatted}.
def get_ml_formatted_value(title_node):
    if title_node is None:
        return None
    text = get_lang_text_ws(title_node)
    if text is None:
        return None
    fmt_attr = (_attr(title_node, 'formatted') == 'true')
    if fmt_attr == test_has_real_markup(text):
        return text
    o = OrderedDict()
    o['text'] = text
    o['formatted'] = fmt_attr
    return o


# Прочитать дочерний скаляр (по local-name, без namespace)
def get_child(node, name):
    if node is None:
        return None
    c = node.find('{*}%s' % name)
    if c is not None:
        return _text(c)
    return None


def has_child(node, name):
    if node is None:
        return False
    return node.find('{*}%s' % name) is not None


def to_bool(v):
    return v == 'true'


# Значение с учётом xsi:type → нативный JSON-тип (число/булево/строка).
def convert_typed_value(raw, xsi_type):
    if re.search(r'decimal$', xsi_type):
        if re.match(r'^-?\d+$', raw):
            return int(raw)
        return float(raw)
    if re.search(r'boolean$', xsi_type):
        return raw == 'true'
    return raw


# Прочитать дочерний скаляр по xpath (с NS). Аналог skd Get-Text.
def get_text(node, xpath):
    if node is None:
        return None
    if xpath is None or xpath == '':
        return _text(node)
    n = node.find(xpath, NS)
    if n is not None:
        return _text(n)
    return None


# Мультиязычный текст (LocalStringType) → string (ru) или ordered hash. Алиас Get-LangText.
def get_ml_text(node):
    return get_lang_text(node)


# Презентация: либо мультиязычный LocalStringType, либо плоский xs:string.
def get_pres_text(node):
    if node is None:
        return None
    ml = get_ml_text(node)
    if ml is not None:
        return ml
    t = _text(node)
    if t:
        return t
    return None


# Presentation, сохраняющий ФОРМУ по xsi:type (ru-only LocalStringType ≠ xs:string).
def get_pres_by_type(node):
    if node is None:
        return None
    xt = _attr(node, 'type', NS_XSI)
    if re.search(r'LocalStringType$', xt):
        d = OrderedDict()
        for it in node.findall('v8:item', NS):
            lang = get_text(it, 'v8:lang')
            content = get_text(it, 'v8:content')
            if lang:
                d[lang] = content
        if len(d) > 0:
            return d
        return None
    t = _text(node)
    if t:
        return t
    return None


# Снять namespace-префикс с xsi:type ("dcsset:Foo" → "Foo")
def get_local_xsi_type(node):
    if node is None:
        return None
    t = _attr(node, 'type', NS_XSI)
    mt = re.search(r':(.+)$', t)
    if mt:
        return mt.group(1)
    return t


# Зеркало булевой коэрции PowerShell `if ($x)`: одноэлементный массив коэрсится в truthiness
# СВОЕГО элемента (а не «непустой список → true», как в Python). Нужно там, где канон пишет
# `if ($arr)` на результате билдера: напр. вырожденный FunctionalOptions @("") → falsy → дроп.
def _ps_truthy(v):
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        return v != ''
    if isinstance(v, (int, float)):
        return v != 0
    if isinstance(v, dict):
        return True   # Hashtable/[ordered] — объект, всегда truthy
    if isinstance(v, (list, tuple)):
        if len(v) == 0:
            return False
        if len(v) == 1:
            return _ps_truthy(v[0])
        return True
    return True


# Зеркало PowerShell -eq/-ne для строк: регистронезависимое сравнение (PS по умолчанию ignore-case).
# Нужно там, где сравниваются произвольно-регистровые строки (заголовок vs авто-вывод из имени).
def _ps_ieq(a, b):
    return a.lower() == b.lower()


# Зеркало PowerShell "$v" (строковая интерполяция): bool→True/False, float без хвостового .0,
# $null→'', иначе str(). Используется везде, где канон делает "$value".
def _ps_str(v):
    if isinstance(v, bool):
        return 'True' if v else 'False'
    if isinstance(v, (float, Decimal)):
        return _num_to_str(v)
    if v is None:
        return ''
    return str(v)


# Шрифт оформления → объект {@type:Font, ...} (bit-perfect для compile).
def get_font_value(val_node):
    f = OrderedDict([('@type', 'Font')])
    for attr_name in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
        a = val_node.get(attr_name)
        if a is not None:
            f[attr_name] = a
    return f


# Линия (граница) оформления → объект {@type:Line, width, gap, style}.
def get_line_value(val_node):
    obj = OrderedDict([('@type', 'Line')])
    w = _attr(val_node, 'width')
    g = _attr(val_node, 'gap')
    if w != '':
        obj['width'] = int(w) if re.match(r'^-?\d+$', w) else w
    if g != '':
        obj['gap'] = (g == 'true')
    style_node = val_node.find('v8ui:style', NS)
    if style_node is not None:
        obj['style'] = _text(style_node)
    return obj


# Прочитать <dcscor:value> в JSON-значение: Font/Line/Field/multilang/raw text.
def read_appearance_value_node(val_node):
    if val_node is None:
        return None
    vt = get_local_xsi_type(val_node)
    if vt == 'LocalStringType':
        # НЕ схлопываем одноязычный в строку: значение параметра оформления различает
        # xs:string (плоская строка) и LocalStringType (локализуемый текст).
        m = OrderedDict()
        for it in val_node.findall('v8:item', NS):
            lang = it.find('v8:lang', NS)
            content = it.find('v8:content', NS)
            if lang is not None:
                m[_text(lang)] = _text(content) if content is not None else ""
        return m
    if vt == 'Font':
        return get_font_value(val_node)
    if vt == 'Line':
        return get_line_value(val_node)
    if vt == 'Field':
        return OrderedDict([('field', _text(val_node))])
    return _text(val_node)


# Обратная карта comparisonType → короткий оператор фильтра (зеркало skd).
FILTER_OP_MAP = {
    'Equal': '=', 'NotEqual': '<>', 'Greater': '>', 'GreaterOrEqual': '>=',
    'Less': '<', 'LessOrEqual': '<=', 'InList': 'in', 'NotInList': 'notIn',
    'InHierarchy': 'inHierarchy', 'InListByHierarchy': 'inListByHierarchy',
    'Contains': 'contains', 'NotContains': 'notContains',
    'BeginsWith': 'beginsWith', 'NotBeginsWith': 'notBeginsWith',
    'Like': 'like', 'NotLike': 'notLike',
    'Filled': 'filled', 'NotFilled': 'notFilled',
}

# Авто-детект DTV-ссылки (Перечисление.X/Catalog.X/…): компилятор сам выводит DesignTimeValue
# для таких значений → не фиксируем явный valueType. Инлайн в каноне (дважды) — держим как константу.
_DTV_REF_RE = r'^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.'


# Render filter value node → shorthand-acceptable scalar string
def get_filter_value(val_node):
    if val_node is None:
        return '_'
    nil = _attr(val_node, 'nil', NS_XSI)
    if nil == 'true':
        return '_'
    v_type = get_local_xsi_type(val_node)
    if v_type == 'DesignTimeValue':
        return _text(val_node)
    if v_type == 'LocalStringType':
        return get_ml_text(val_node)
    txt = _text(val_node)
    if not txt:
        return '_'
    return txt


# Get-FilterValue + xsi:type значения (для valueType, например dcscor:Field).
def get_filter_value_with_type(val_node):
    if val_node is None:
        return {'value': '_', 'type': None}
    raw_type = _attr(val_node, 'type', NS_XSI)
    nil = _attr(val_node, 'nil', NS_XSI)
    if nil == 'true':
        return {'value': '_', 'type': None}
    v_type = get_local_xsi_type(val_node)
    if v_type == 'LocalStringType':
        return {'value': get_ml_text(val_node), 'type': raw_type}
    # Стандартная дата начала/окончания: SBD Custom+date → голая ISO-дата без valueType;
    # именованный вариант → строка + valueType; SED Custom/нетипичное → {variant, date} + valueType.
    if v_type == 'StandardBeginningDate' or v_type == 'StandardEndDate':
        variant_n = val_node.find('v8:variant', NS)
        date_n = val_node.find('v8:date', NS)
        variant_str = _text(variant_n) if variant_n is not None else ''
        if date_n is not None:
            if v_type == 'StandardBeginningDate' and variant_str == 'Custom':
                return {'value': _text(date_n), 'type': None}
            return {'value': OrderedDict([('variant', variant_str), ('date', _text(date_n))]), 'type': raw_type}
        return {'value': variant_str, 'type': raw_type}
    txt = _text(val_node)
    if not txt:
        return {'value': '_', 'type': raw_type}
    if v_type == 'boolean':
        return {'value': (txt == 'true'), 'type': raw_type}
    if v_type == 'decimal':
        if re.match(r'^-?\d+$', txt):
            return {'value': int(txt), 'type': raw_type}
        return {'value': float(txt), 'type': raw_type}
    return {'value': txt, 'type': raw_type}


# Convert filter item node → shorthand string или object form (рекурсивно для групп).
def build_filter_item(item_node, loc):
    xtype = get_local_xsi_type(item_node)
    if xtype == 'FilterItemGroup':
        gt = get_text(item_node, 'dcsset:groupType')
        group_name = {'OrGroup': 'Or', 'NotGroup': 'Not'}.get(gt, 'And')
        items = []
        for c in item_node.findall('dcsset:item', NS):
            bi = build_filter_item(c, '%s/item' % loc)
            if bi is not None:
                items.append(bi)
        g_obj = OrderedDict([('group', group_name), ('items', items)])
        if get_text(item_node, 'dcsset:use') == 'false':
            g_obj['use'] = False   # группа отключена (@off)
        g_pres_node = item_node.find('dcsset:presentation', NS)
        if g_pres_node is not None:
            g_pres = get_pres_by_type(g_pres_node)
            if g_pres is not None and g_pres != '':
                g_obj['presentation'] = g_pres
        g_vm_node = item_node.find('dcsset:viewMode', NS)
        if g_vm_node is not None:
            g_obj['viewMode'] = _text(g_vm_node)
        g_usid = get_text(item_node, 'dcsset:userSettingID')
        if g_usid:
            g_obj['userSettingID'] = 'auto'
        g_uspn = item_node.find('dcsset:userSettingPresentation', NS)
        if g_uspn is not None:
            g_usp = get_pres_text(g_uspn)
            if g_usp:
                g_obj['userSettingPresentation'] = g_usp
        return g_obj
    if xtype != 'FilterItemComparison':
        sys.stderr.write("form-decompile: пропущен фильтр неизвестного типа '%s' (path: %s)\n" % (xtype, loc))
        return None
    left_node = item_node.find('dcsset:left', NS)
    field = _text(left_node) if left_node is not None else None
    ct = get_text(item_node, 'dcsset:comparisonType')
    op = FILTER_OP_MAP.get(ct)
    if not op:
        op = ct

    right_nodes = item_node.findall('dcsset:right', NS)
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
                bool(re.search(_DTV_REF_RE, _ps_str(vt['value'])))
            if vt['type'] and not re.match(r'^xs:', vt['type']) and not auto_detects_dtv:
                value_type_attr = vt['type']
            elif vt['type'] == 'xs:string' and isinstance(value, str) and re.search(r'^(-?\d+(\.\d+)?|\d{4}-\d{2}-\d{2}T)', value):
                # Значение-строка "1"/"2020-..." с xs:string: компилятор авто-детектит число/дату → фиксируем явный valueType.
                value_type_attr = 'xs:string'
    elif len(right_nodes) > 1:
        arr = []
        raw_types = []
        for rn in right_nodes:
            arr.append(get_filter_value(rn))
            raw_types.append(_attr(rn, 'type', NS_XSI))
        value = arr
        value_is_array_flag = True
        uniq_types = sorted(set(raw_types))
        if len(uniq_types) == 1 and uniq_types[0]:
            auto_detects_dtv = (uniq_types[0] == 'dcscor:DesignTimeValue') and \
                (len(arr) > 0) and \
                (len([x for x in arr if not re.search(_DTV_REF_RE, _ps_str(x))]) == 0)
            if not auto_detects_dtv:
                value_type_attr = uniq_types[0]

    use = get_text(item_node, 'dcsset:use')
    user_id = get_text(item_node, 'dcsset:userSettingID')
    vm_node = item_node.find('dcsset:viewMode', NS)
    view_mode = _text(vm_node) if vm_node is not None else None
    user_pres_node = item_node.find('dcsset:userSettingPresentation', NS)
    fi_pres_node = item_node.find('dcsset:presentation', NS)
    fi_pres = None
    if fi_pres_node is not None:
        fi_pres = get_pres_by_type(fi_pres_node)

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

    # Пустой xs:string right ≠ отсутствие <right>; пробельные значения рвут shorthand → форсим объект.
    val_needs_obj = False
    if len(right_nodes) == 1 and not value_is_array_flag and op not in no_value_ops:
        if _ps_str(value) == '_':
            ws = resolve_ws(right_nodes[0])
            if ws and len(ws) > 0 and ws.strip() == '':
                value = ws
            val_needs_obj = True
        elif value is not None and re.search(r'\s', _ps_str(value)):
            val_needs_obj = True

    if user_pres_node is not None or value_is_array_flag or value_type_attr or fi_pres or val_needs_obj:
        obj = OrderedDict([('field', field), ('op', op)])
        if op not in no_value_ops and value is not None:
            if value_is_array_flag:
                arr_as_list = []
                for vv in (value if isinstance(value, (list, tuple)) else [value]):
                    arr_as_list.append(vv)
                obj['value'] = arr_as_list
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
        if user_pres_node is not None:
            obj['userSettingPresentation'] = get_pres_text(user_pres_node)
        return obj

    s = field if field is not None else ''   # $null + строка в PS → '' (избегаем TypeError)
    if op in no_value_ops:
        s += ' ' + op
    else:
        v_display = '_'
        if value is not None:
            if isinstance(value, bool):
                v_display = 'true' if value else 'false'
            elif _ps_str(value) != '':
                v_display = _ps_str(value)
        s += ' ' + op + ' ' + v_display
    if flags:
        s += ' ' + ' '.join(flags)
    return s


# Рекурсивный хелпер одного элемента selection (для conditionalAppearance).
def build_selection_item(item, loc):
    xt = get_local_xsi_type(item)
    if not xt:
        f_name = get_text(item, 'dcsset:field')
        if f_name:
            return f_name
        field_el = item.find('dcsset:field', NS)
        if field_el is not None:
            return 'Auto'
    if xt == 'SelectedItemAuto':
        use_v = get_text(item, 'dcsset:use')
        if use_v == 'false':
            return OrderedDict([('auto', True), ('use', False)])
        return 'Auto'
    if xt == 'SelectedItemField':
        f_name = get_text(item, 'dcsset:field')
        title_node = item.find('dcsset:lwsTitle', NS)
        title = get_ml_text(title_node)
        vm_n = item.find('dcsset:viewMode', NS)
        use_v = get_text(item, 'dcsset:use')
        use_false = (use_v == 'false')
        if title or vm_n is not None or use_false:
            obj = OrderedDict([('field', f_name)])
            if use_false:
                obj['use'] = False
            if title:
                obj['title'] = title
            if vm_n is not None:
                obj['viewMode'] = _text(vm_n)
            return obj
        return f_name
    if xt == 'SelectedItemFolder':
        title_node = item.find('dcsset:lwsTitle', NS)
        folder_title = get_ml_text(title_node)
        inner = []
        for sub in item.findall('dcsset:item', NS):
            bi = build_selection_item(sub, '%s/folder' % loc)
            if bi is not None:
                inner.append(bi)
        entry = OrderedDict([('folder', folder_title), ('items', inner)])
        folder_field = get_text(item, 'dcsset:field')
        if folder_field:
            entry['field'] = folder_field
        pl_n = item.find('dcsset:placement', NS)
        if pl_n is not None and _text(pl_n) and _text(pl_n) != 'Auto':
            entry['placement'] = _text(pl_n)
        return entry
    sys.stderr.write("form-decompile: пропущен элемент selection неизвестного типа '%s' (path: %s)\n" % (xt, loc))
    return None


# Build selection items array (для conditionalAppearance).
def build_selection(sel_node, loc):
    if sel_node is None:
        return []
    out = []
    for it in sel_node.findall('dcsset:item', NS):
        bi = build_selection_item(it, loc)
        if bi is not None:
            out.append(bi)
    return out


# Build order items array.
def build_order(ord_node, loc):
    if ord_node is None:
        return []
    out = []
    for it in ord_node.findall('dcsset:item', NS):
        xt = get_local_xsi_type(it)
        if xt == 'OrderItemAuto':
            out.append('Auto')
        elif xt == 'OrderItemField':
            fn = get_text(it, 'dcsset:field')
            ot = get_text(it, 'dcsset:orderType')
            vm_n = it.find('dcsset:viewMode', NS)
            use_v = get_text(it, 'dcsset:use')
            use_false = (use_v == 'false')
            if vm_n is not None or use_false:
                obj = OrderedDict([('field', fn)])
                if use_false:
                    obj['use'] = False
                if ot == 'Desc':
                    obj['direction'] = 'desc'
                if vm_n is not None:
                    obj['viewMode'] = _text(vm_n)
                out.append(obj)
            else:
                if ot == 'Desc':
                    out.append('%s desc' % fn)
                else:
                    out.append(fn)
        else:
            sys.stderr.write("form-decompile: пропущен элемент сортировки неизвестного типа '%s' (path: %s)\n" % (xt, loc))
    return out


# Build appearance dict из <dcsset:appearance> (Line/Font/multilang/nested items).
def get_settings_appearance(app_node):
    if app_node is None:
        return None
    d = OrderedDict()
    for it in app_node.findall('dcscor:item', NS):
        p_name = get_text(it, 'dcscor:parameter')
        val = it.find('dcscor:value', NS)
        if not p_name or val is None:
            continue
        raw_val = read_appearance_value_node(val)
        use_v = get_text(it, 'dcscor:use')
        nested_items = OrderedDict()
        for sub in it.findall('dcscor:item', NS):
            sub_name = get_text(sub, 'dcscor:parameter')
            sub_val = sub.find('dcscor:value', NS)
            if not sub_name:
                continue
            sub_raw = read_appearance_value_node(sub_val)
            sub_use = get_text(sub, 'dcscor:use')
            sub_entry = OrderedDict([('value', sub_raw)])
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
            wrap = OrderedDict([('value', raw_val)])
            if use_v == 'false':
                wrap['use'] = False
            if len(nested_items) > 0:
                wrap['items'] = nested_items
            d[p_name] = wrap
        else:
            d[p_name] = raw_val
    return d


# Build conditionalAppearance array.
def build_conditional_appearance(ca_node, loc):
    if ca_node is None:
        return []
    out = []
    i = 0
    for it in ca_node.findall('dcsset:item', NS):
        entry = OrderedDict()
        scope_node = it.find('dcsset:scope', NS)
        if scope_node is not None and (len(scope_node) > 0 or bool(_text(scope_node))):
            sys.stderr.write("form-decompile: conditionalAppearance item имеет scope — не воспроизводится в DSL (path: %s/%d/scope)\n" % (loc, i))
        sel_node = it.find('dcsset:selection', NS)
        if sel_node is not None and len(sel_node.findall('dcsset:item', NS)) > 0:
            entry['selection'] = build_selection(sel_node, '%s/%d/selection' % (loc, i))
        filter_node = it.find('dcsset:filter', NS)
        if filter_node is not None and len(filter_node.findall('dcsset:item', NS)) > 0:
            f = []
            for fc in filter_node.findall('dcsset:item', NS):
                bi = build_filter_item(fc, '%s/%d/filter' % (loc, i))
                if bi is not None:
                    f.append(bi)
            entry['filter'] = f
        app_node = it.find('dcsset:appearance', NS)
        ap = get_settings_appearance(app_node)
        if ap and len(ap) > 0:
            entry['appearance'] = ap
        pres_node = it.find('dcsset:presentation', NS)
        if pres_node is not None:
            pres = get_pres_by_type(pres_node)
            if pres is not None and pres != '':
                entry['presentation'] = pres
        vm_n = it.find('dcsset:viewMode', NS)
        if vm_n is not None:
            entry['viewMode'] = _text(vm_n)
        usid = get_text(it, 'dcsset:userSettingID')
        if usid:
            entry['userSettingID'] = 'auto'
        usp_n = it.find('dcsset:userSettingPresentation', NS)
        if usp_n is not None:
            usp = get_pres_text(usp_n)
            if usp:
                entry['userSettingPresentation'] = usp
        use_v = get_text(it, 'dcsset:use')
        if use_v == 'false':
            entry['use'] = False
        use_in_dont_use = []
        for ch in list(it):
            if not ch.tag.startswith('{%s}' % NS_DCSSET):
                continue
            ln = _local_name(ch.tag)
            mt = re.match(r'^useIn(.+)$', ln)
            if mt and _text(ch) == 'DontUse':
                short_name = mt.group(1)[0:1].lower() + mt.group(1)[1:]
                use_in_dont_use.append(short_name)
        if len(use_in_dont_use) > 0:
            entry['useInDontUse'] = use_in_dont_use
        out.append(entry)
        i += 1
    return out


# Общие layout-свойства → в obj (симметрично Emit-Layout компилятора).
def add_layout(obj, node):
    if get_child(node, 'DefaultItem') == 'true':
        obj['defaultItem'] = True
    soi = get_child(node, 'SkipOnInput')
    if soi is not None:
        obj['skipOnInput'] = (soi == 'true')
    esd = get_child(node, 'EnableStartDrag')
    if esd is not None:
        obj['enableStartDrag'] = (esd == 'true')
    edr = get_child(node, 'EnableDrag')
    if edr is not None:
        obj['enableDrag'] = (edr == 'true')
    fdm = get_child(node, 'FileDragMode')
    if fdm:
        obj['fileDragMode'] = fdm
    # AutoMaxWidth: компилятор додумывает false для multiLine-input → захват факт. значения.
    amw_node = get_child(node, 'AutoMaxWidth')
    if amw_node == 'false':
        obj['autoMaxWidth'] = False
    elif amw_node == 'true':
        obj['autoMaxWidth'] = True
    elif get_child(node, 'MultiLine') == 'true':
        obj['autoMaxWidth'] = True
    mw = get_child(node, 'MaxWidth')
    if mw:
        obj['maxWidth'] = int(mw)
    if get_child(node, 'AutoMaxHeight') == 'false':
        obj['autoMaxHeight'] = False
    mh = get_child(node, 'MaxHeight')
    if mh:
        obj['maxHeight'] = int(mh)
    w = get_child(node, 'Width')
    if w:
        obj['width'] = int(w)
    h = get_child(node, 'Height')
    if h:
        obj['height'] = int(h)
    hs = get_child(node, 'HorizontalStretch')
    if hs is not None:
        obj['horizontalStretch'] = (hs == 'true')
    vs = get_child(node, 'VerticalStretch')
    if vs is not None:
        obj['verticalStretch'] = (vs == 'true')
    gha = get_child(node, 'GroupHorizontalAlign')
    if gha:
        obj['groupHorizontalAlign'] = gha
    gva = get_child(node, 'GroupVerticalAlign')
    if gva:
        obj['groupVerticalAlign'] = gva
    ha = get_child(node, 'HorizontalAlign')
    if ha:
        obj['horizontalAlign'] = ha
    for p in ('ShowInHeader', 'ShowInFooter', 'AutoCellHeight'):
        v = get_child(node, p)
        if v is not None:
            obj[p[0:1].lower() + p[1:]] = (v == 'true')
    fha = get_child(node, 'FooterHorizontalAlign')
    if fha:
        obj['footerHorizontalAlign'] = fha
    hha = get_child(node, 'HeaderHorizontalAlign')
    if hha:
        obj['headerHorizontalAlign'] = hha
    hdp = get_child(node, 'HeaderDataPath')
    if hdp:
        obj['headerDataPath'] = hdp
    hf_node = node.find('lf:HeaderFormat', NS)
    if hf_node is not None:
        hf = get_lang_text(hf_node)
        if hf is not None:
            obj['headerFormat'] = hf


# TitleLocation у check/radio: тега нет → ""; значение = умный дефолт → опускаем; иначе пишем.
def add_title_location(obj, node, smart_default):
    tl = get_child(node, 'TitleLocation')
    if tl is None:
        obj['titleLocation'] = ''
    elif tl != smart_default:
        obj['titleLocation'] = tl.lower()


# Разобрать <Events> элемента → упорядоченная мапа { ИмяСобытия: ИмяОбработчика }.
def get_events(node, el_name):
    ev = node.find('lf:Events', NS)
    if ev is None:
        return None
    events = OrderedDict()
    for e in ev.findall('lf:Event', NS):
        events[_attr(e, 'name')] = _text(e)
    if len(events) == 0:
        return None
    return events


# Инверсия Emit-XrFlag: role-adjustable boolean (UserVisible/View/Edit/Use).
def decompile_xr_flag(node, tag):
    el = node.find('{*}%s' % tag)
    if el is None:
        return None
    common_node = el.find('{*}Common')
    common = (common_node is not None and _text(common_node) == 'true')
    val_nodes = el.findall('{*}Value')
    if len(val_nodes) == 0:
        return common
    roles = OrderedDict()
    for v in val_nodes:
        rn = _attr(v, 'name')
        if re.match(r'^Role\.', rn):
            rn = rn[5:]
        roles[rn] = (_text(v) == 'true')
    o = OrderedDict()
    o['common'] = common
    o['roles'] = roles
    return o


# Командный интерфейс формы (<CommandInterface>): панели CommandBar + NavigationPanel.
def decompile_command_interface():
    ci_node = ROOT.find('lf:CommandInterface', NS)
    if ci_node is None:
        return None
    ci = OrderedDict()
    for panel in (('CommandBar', 'commandBar'), ('NavigationPanel', 'navigationPanel')):
        pn = ci_node.find('lf:%s' % panel[0], NS)
        if pn is None:
            continue
        items = []
        for it in pn.findall('lf:Item', NS):
            o = OrderedDict()
            cmd = get_child(it, 'Command')
            o['command'] = _ps_str(cmd)
            ty = get_child(it, 'Type')
            if ty and ty != 'Auto':
                o['type'] = ty
            at = get_child(it, 'Attribute')
            if at:
                o['attribute'] = at
            cg = get_child(it, 'CommandGroup')
            if cg:
                o['group'] = cg
            idx = get_child(it, 'Index')
            if idx is not None:
                o['index'] = int(idx)
            dv = get_child(it, 'DefaultVisible')
            if dv is not None:
                o['defaultVisible'] = (dv == 'true')
            vis = decompile_xr_flag(it, 'Visible')
            if vis is not None:
                o['visible'] = vis
            # Голый элемент (только command) → строка-shorthand; иначе объект
            if len(o) == 1:
                items.append(_ps_str(cmd))
            else:
                items.append(o)
        if len(items) > 0:
            ci[panel[1]] = items
    if len(ci) > 0:
        return ci
    return None


# <FunctionalOptions><Item>FunctionalOption.X</Item>…> → массив строк (префикс снят; GUID — как есть).
def decompile_functional_options(node):
    fo_node = node.find('lf:FunctionalOptions', NS)
    if fo_node is None:
        return None
    opts = []
    for it in fo_node.findall('lf:Item', NS):
        t = re.sub(r'^FunctionalOption\.', '', (_text(it) or '').strip())
        opts.append(t)
    if len(opts) > 0:
        return opts
    return None


# Колонка реквизита (прямая или внутри AdditionalColumns): name/type/title/functionalOptions.
def decompile_attr_column(c):
    co = OrderedDict()
    co['name'] = _attr(c, 'name')
    cty = decompile_type(c.find('lf:Type', NS))
    if cty:
        co['type'] = cty
    ct_node = c.find('lf:Title', NS)
    if ct_node is not None:
        t = get_lang_text_ws(ct_node)
        if t is not None:
            co['title'] = t
    cfc = get_child(c, 'FillCheck')
    if cfc:
        co['fillCheck'] = cfc
    cfo = decompile_functional_options(c)
    if _ps_truthy(cfo):
        co['functionalOptions'] = cfo
    cv = decompile_xr_flag(c, 'View')
    if cv is not None:
        co['view'] = cv
    ce = decompile_xr_flag(c, 'Edit')
    if ce is not None:
        co['edit'] = ce
    return co


# Картинка-ссылка с прозрачностью (HeaderPicture/FooterPicture/…). Дефолт loadTransparent=false.
def get_picture_ref(node, pic_tag):
    ref = node.find('lf:%s/xr:Ref' % pic_tag, NS)
    abs_ = node.find('lf:%s/xr:Abs' % pic_tag, NS)
    if ref is None and abs_ is None:
        return None
    src = _text(ref) if ref is not None else 'abs:%s' % _text(abs_)
    lt = node.find('lf:%s/xr:LoadTransparent' % pic_tag, NS)
    lt_true = (lt is not None and _text(lt) == 'true')
    tpx = node.find('lf:%s/xr:TransparentPixel' % pic_tag, NS)
    if not lt_true and tpx is None:
        return src
    o = OrderedDict([('src', src)])
    if lt_true:
        o['loadTransparent'] = True
    if tpx is not None:
        o['transparentPixel'] = OrderedDict([('x', int(_attr(tpx, 'x'))), ('y', int(_attr(tpx, 'y')))])
    return o


# <Picture> кнопки/попапа/команды. Дефолт LoadTransparent=true (обратная конвенция).
def set_command_picture(obj, node):
    ref = node.find('lf:Picture/xr:Ref', NS)
    abs_ = node.find('lf:Picture/xr:Abs', NS)
    if ref is None and abs_ is None:
        return
    src = _text(ref) if ref is not None else 'abs:%s' % _text(abs_)
    lt = node.find('lf:Picture/xr:LoadTransparent', NS)
    lt_false = (lt is not None and _text(lt) == 'false')
    tpx = node.find('lf:Picture/xr:TransparentPixel', NS)
    if tpx is not None:
        o = OrderedDict([('src', src)])
        if lt_false:
            o['loadTransparent'] = False
        o['transparentPixel'] = OrderedDict([('x', int(_attr(tpx, 'x'))), ('y', int(_attr(tpx, 'y')))])
        obj['picture'] = o
    else:
        obj['picture'] = src
        if lt_false:
            obj['loadTransparent'] = False


# Шрифт <Font ...> → строка-ref (если только ref+kind=StyleItem) или объект-атрибуты.
def build_font_value(f):
    present = []
    for a in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
        if a in f.attrib:
            present.append(a)
    if len(present) == 2 and ('ref' in present) and _attr(f, 'kind') == 'StyleItem':
        return _attr(f, 'ref')
    o = OrderedDict()
    for k in present:
        v = _attr(f, k)
        if k in ('height', 'scale') and re.match(r'^-?\d+$', v):
            o[k] = int(v)
        elif k in ('bold', 'italic', 'underline', 'strikeout'):
            o[k] = (v == 'true')
        else:
            o[k] = v
    return o


# Граница <Border> → строка-ref (из стиля) или объект {width, style}.
def build_border_value(b):
    if 'ref' in b.attrib:
        return _attr(b, 'ref')
    o = OrderedDict()
    if 'width' in b.attrib:
        w = _attr(b, 'width')
        o['width'] = int(w) if re.match(r'^-?\d+$', w) else w
    st = b.find('v8ui:style', NS)
    if st is not None:
        o['style'] = _text(st)
    return o


# Порядок ключей цвета = .NET Hashtable enumeration (захвачено из PS 5.1), НЕ порядок литерала.
COLOR_MAP = [
    ('BackColor', 'backColor'),
    ('TitleBackColor', 'titleBackColor'),
    ('TitleTextColor', 'titleTextColor'),
    ('TextColor', 'textColor'),
    ('FooterTextColor', 'footerTextColor'),
    ('FooterBackColor', 'footerBackColor'),
    ('BorderColor', 'borderColor'),
]


# Оформление элемента (цвета/шрифты/граница) → canonical DSL-ключи. Цвет — verbatim-строка.
def add_appearance(obj, node):
    for tag, key in COLOR_MAP:
        c = node.find('lf:%s' % tag, NS)
        if c is not None:
            obj[key] = _text(c)
    for pair in (('Font', 'font'), ('TitleFont', 'titleFont'), ('FooterFont', 'footerFont')):
        f = node.find('lf:%s' % pair[0], NS)
        if f is not None:
            obj[pair[1]] = build_font_value(f)
    b = node.find('lf:Border', NS)
    if b is not None:
        obj['border'] = build_border_value(b)


def add_common_props(obj, node, el_name):
    add_appearance(obj, node)
    if get_child(node, 'Visible') == 'false':
        obj['hidden'] = True
    if get_child(node, 'Enabled') == 'false':
        obj['disabled'] = True
    if get_child(node, 'ReadOnly') == 'true':
        obj['readOnly'] = True
    uv = decompile_xr_flag(node, 'UserVisible')
    if uv is not None:
        obj['userVisible'] = uv
    title_node = node.find('lf:Title', NS)
    if title_node is not None:
        t = get_lang_text_ws(title_node)
        if t is not None:
            obj['title'] = t
    tt_node = node.find('lf:ToolTip', NS)
    if tt_node is not None:
        tt = get_lang_text_ws(tt_node)
        if tt is not None:
            obj['tooltip'] = tt
    ttr = get_child(node, 'ToolTipRepresentation')
    if ttr:
        obj['tooltipRepresentation'] = ttr
    hp = get_picture_ref(node, 'HeaderPicture')
    if hp is not None:
        obj['headerPicture'] = hp
    fp = get_picture_ref(node, 'FooterPicture')
    if fp is not None:
        obj['footerPicture'] = fp
    ev = get_events(node, el_name)
    if ev:
        obj['events'] = ev
    # CommandSet — список отключённых команд редактора (только <ExcludedCommand>).
    cs_node = node.find('lf:CommandSet', NS)
    if cs_node is not None:
        exc = []
        for ec in cs_node.findall('lf:ExcludedCommand', NS):
            exc.append(_text(ec))
        if len(exc) > 0:
            obj['excludedCommands'] = exc


# --- 3. Type decompile (inverse of Emit-Type) ---
def decompile_type(type_node):
    if type_node is None:
        return None
    parts = []
    for vt in type_node.findall('v8:Type', NS):
        raw = (_text(vt) or '').strip()
        short = raw
        # break-эквивалент: ветви взаимоисключающи (общий v8|v8ui не перетирает специфичные).
        if re.match(r'^xs:string$', raw):
            ln = type_node.find('v8:StringQualifiers/v8:Length', NS)
            al = type_node.find('v8:StringQualifiers/v8:AllowedLength', NS)
            fixed = (al is not None and _text(al) == 'Fixed')   # Variable = дефолт; Fixed — явно
            if ln is not None and int(_text(ln)) > 0:
                short = ('string(%s,fixed)' % _text(ln)) if fixed else ('string(%s)' % _text(ln))
            else:
                short = 'string'   # Length=0 → всегда Variable (корпус)
        elif re.match(r'^xs:decimal$', raw):
            d = type_node.find('v8:NumberQualifiers/v8:Digits', NS)
            f = type_node.find('v8:NumberQualifiers/v8:FractionDigits', NS)
            sgn = type_node.find('v8:NumberQualifiers/v8:AllowedSign', NS)
            dd = _text(d) if d is not None else '0'
            ff = _text(f) if f is not None else '0'
            if sgn is not None and _text(sgn) == 'Nonnegative':
                short = 'decimal(%s,%s,nonneg)' % (dd, ff)
            else:
                short = 'decimal(%s,%s)' % (dd, ff)
        elif re.match(r'^xs:boolean$', raw):
            short = 'boolean'
        elif re.match(r'^xs:dateTime$', raw):
            df = type_node.find('v8:DateQualifiers/v8:DateFractions', NS)
            dfv = _text(df) if df is not None else 'DateTime'
            if dfv == 'Date':
                short = 'date'
            elif dfv == 'Time':
                short = 'time'
            else:
                short = 'dateTime'
        else:
            m_cfg = re.match(r'^cfg:(.+)$', raw)
            if m_cfg:
                short = m_cfg.group(1)
            elif re.match(r'^(v8|v8ui):', raw):
                # Платформенный тип: friendly-шорткат если есть, иначе verbatim (не теряем v8:UUID и т.п.).
                rev = {
                    'v8:ValueTable': 'ValueTable', 'v8:ValueTree': 'ValueTree', 'v8:ValueListType': 'ValueList',
                    'v8:TypeDescription': 'TypeDescription', 'v8:Universal': 'Universal',
                    'v8:FixedArray': 'FixedArray', 'v8:FixedStructure': 'FixedStructure',
                    'v8ui:FormattedString': 'FormattedString', 'v8ui:Picture': 'Picture', 'v8ui:Color': 'Color', 'v8ui:Font': 'Font',
                }
                short = rev.get(raw, raw)
            else:
                short = raw
        parts.append(short)
    # TypeSet (набор типов): префикс cfg:/v8: снимаем — обратный роутинг в компиляторе по форме токена.
    for ts in type_node.findall('v8:TypeSet', NS):
        raw = (_text(ts) or '').strip()
        short = re.sub(r'^(v8ui|v8|cfg):', '', raw)
        parts.append(short)
    # TypeId — тип по глобальному стабильному GUID → маркер 'typeid:GUID' (компилятор разворачивает).
    for ti in type_node.findall('v8:TypeId', NS):
        parts.append('typeid:' + (_text(ti) or '').strip())
    if len(parts) == 0:
        return None
    if len(parts) == 1:
        return parts[0]
    return ' | '.join(parts)


# Ограничения использования (useRestriction/attributeUseRestriction) → объект {field?,condition?,group?,order?}.
def build_restrict_obj(node):
    r = OrderedDict()
    for k in ('field', 'condition', 'group', 'order'):
        if get_child(node, k) == 'true':
            r[k] = True
    return r


# Вычисляемое поле DataSet динамического списка (<CalculatedField>) → объектная модель.
def build_calc_field(cf_node):
    o = OrderedDict()
    o['dataPath'] = get_child(cf_node, 'dataPath')
    o['expression'] = get_child(cf_node, 'expression')
    tn = cf_node.find('dcssch:title', NS)
    if tn is not None:
        t = get_lang_text(tn)
        if t is not None:
            o['title'] = t
    vt = cf_node.find('dcssch:valueType', NS)
    if vt is not None:
        v = decompile_type(vt)
        if v:
            o['valueType'] = v
    ur = cf_node.find('dcssch:useRestriction', NS)
    if ur is not None:
        r = OrderedDict()
        for k in ('field', 'condition', 'group', 'order'):
            if get_child(ur, k) == 'true':
                r[k] = True
        if len(r) > 0:
            o['useRestriction'] = r
    pe = get_child(cf_node, 'presentationExpression')
    if pe is not None and pe != '':
        o['presentationExpression'] = pe
    oe_nodes = cf_node.findall('dcssch:orderExpression', NS)
    if len(oe_nodes) > 0:
        oes = []
        for oen in oe_nodes:
            eo = OrderedDict()
            expr_n = oen.find('{*}expression')
            ot_n = oen.find('{*}orderType')
            ao_n = oen.find('{*}autoOrder')
            eo['expression'] = _text(expr_n) if expr_n is not None else ''
            if ot_n is not None and _text(ot_n) != 'Asc':
                eo['orderType'] = _text(ot_n)
            if ao_n is not None and _text(ao_n) == 'true':
                eo['autoOrder'] = True
            oes.append(eo)
        o['orderExpression'] = oes
    return o


# Параметры выбора входа дин-списка (<inputParameters>) → массив. Зеркало Emit-DLInputParameters.
def build_dl_input_parameters(ip_node):
    items = []
    for it in ip_node.findall('dcscor:item', NS):
        io = OrderedDict()
        io['parameter'] = get_child(it, 'parameter')
        use_n = it.find('dcscor:use', NS)
        if use_n is not None and _text(use_n) == 'false':
            io['use'] = False
        val_n = it.find('dcscor:value', NS)
        if val_n is not None:
            vt = _attr(val_n, 'type', NS_XSI)
            if re.search(r'ChoiceParameters$', vt):
                cps = []
                for cpi in val_n.findall('dcscor:item', NS):
                    cpo = OrderedDict()
                    cpo['name'] = get_child(cpi, 'choiceParameter')
                    vals = []
                    for cv in cpi.findall('dcscor:value', NS):
                        vals.append(convert_typed_value(_text(cv), _attr(cv, 'type', NS_XSI)))
                    cpo['values'] = vals
                    cps.append(cpo)
                io['choiceParameters'] = cps
            elif re.search(r'ChoiceParameterLinks$', vt):
                cpls = []
                for cpi in val_n.findall('dcscor:item', NS):
                    cpo = OrderedDict()
                    cpo['name'] = get_child(cpi, 'choiceParameter')
                    cpo['value'] = get_child(cpi, 'value')
                    md = get_child(cpi, 'mode')
                    if md and md != 'Auto':
                        cpo['mode'] = md
                    cpls.append(cpo)
                io['choiceParameterLinks'] = cpls
            elif re.search(r'TypeLink$', vt):
                # Связь по типу: field + linkItem — структурное значение, НЕ склеивать InnerText в строку.
                tlo = OrderedDict()
                tlf = get_child(val_n, 'field')
                if tlf is not None:
                    tlo['field'] = tlf
                tli = get_child(val_n, 'linkItem')
                if tli is not None:
                    tlo['linkItem'] = int(tli) if re.match(r'^-?\d+$', tli) else tli
                io['typeLink'] = tlo
            else:
                if _attr(val_n, 'nil', NS_XSI) != 'true':
                    io['value'] = convert_typed_value(_text(val_n), vt)
        items.append(io)
    return items


# dcsset:dataParameters → массив (shorthand "Имя @off" / объект для типизированного значения).
def build_form_data_parameters(dp_node):
    entries = []
    for it in dp_node.findall('dcscor:item', NS):
        pn = get_text(it, 'dcscor:parameter')
        use = get_text(it, 'dcscor:use')
        val_nodes = it.findall('dcscor:value', NS)
        val_node = val_nodes[0] if len(val_nodes) >= 1 else None
        usid_n = it.find('dcsset:userSettingID', NS)
        vm_n = it.find('dcsset:viewMode', NS)
        usp_n = it.find('dcsset:userSettingPresentation', NS)
        if val_node is not None or usid_n is not None or vm_n is not None or usp_n is not None:
            obj = OrderedDict([('parameter', pn)])
            if len(val_nodes) > 1:
                # Список значений параметра (valueListAllowed) — все <dcscor:value> массивом
                obj['value'] = [_text(v) for v in val_nodes]
                vt0 = _attr(val_nodes[0], 'type', NS_XSI)
                if vt0:
                    obj['valueType'] = vt0
            elif val_node is not None:
                if _attr(val_node, 'nil', NS_XSI) == 'true':
                    obj['nilValue'] = True
                else:
                    v_type = _attr(val_node, 'type', NS_XSI)
                    v_val = _text(val_node)
                    if re.search(r'decimal$', v_type) and re.match(r'^-?\d+$', v_val):
                        obj['value'] = int(v_val)
                    elif re.search(r'boolean$', v_type):
                        obj['value'] = (v_val == 'true')
                    else:
                        obj['value'] = v_val
                    if v_type:
                        obj['valueType'] = v_type
            if use == 'false':
                obj['use'] = False
            if usid_n is not None:
                obj['userSettingID'] = 'auto'
            if vm_n is not None:
                obj['viewMode'] = _text(vm_n)
            if usp_n is not None:
                usp = get_pres_text(usp_n)
                if usp is not None:
                    obj['userSettingPresentation'] = usp
            entries.append(obj)
        else:
            s = pn
            if use == 'false':
                s += ' @off'
            entries.append(s)
    return entries


def build_dl_parameter(p_node):
    name = get_child(p_node, 'name')
    o = OrderedDict()
    o['name'] = name
    # title — опускаем, если совпадает с авто-выводом из имени (ru-only)
    title_node = p_node.find('dcssch:title', NS)
    if title_node is not None:
        t = get_lang_text(title_node)
        if t is not None:
            auto = title_from_name(name)
            if not (isinstance(t, str) and _ps_ieq(t, auto)):
                o['title'] = t
    vt_node = p_node.find('dcssch:valueType', NS)
    type_val = None
    if vt_node is not None:
        type_val = decompile_type(vt_node)
        if type_val:
            o['type'] = type_val
    # value — опускаем nil (дефолт), КРОМЕ valueListAllowed+nil (явный маркер value:null).
    v_nodes = p_node.findall('dcssch:value', NS)
    if len(v_nodes) > 1:
        o['value'] = [convert_typed_value(_text(v), _attr(v, 'type', NS_XSI)) for v in v_nodes]
    elif len(v_nodes) == 1:
        v_node = v_nodes[0]
        if _attr(v_node, 'nil', NS_XSI) != 'true':
            o['value'] = convert_typed_value(_text(v_node), _attr(v_node, 'type', NS_XSI))
        elif get_child(p_node, 'valueListAllowed') == 'true':
            o['value'] = None
    if get_child(p_node, 'useRestriction') == 'false':
        o['useRestriction'] = False
    expr = get_child(p_node, 'expression')
    if expr is not None and expr != '':
        o['expression'] = expr
    av_nodes = p_node.findall('dcssch:availableValue', NS)
    if len(av_nodes) > 0:
        avs = []
        for avn in av_nodes:
            avo = OrderedDict()
            avv = avn.find('dcssch:value', NS)
            if avv is not None and _attr(avv, 'nil', NS_XSI) != 'true':
                avo['value'] = convert_typed_value(_text(avv), _attr(avv, 'type', NS_XSI))
            else:
                avo['value'] = None
            avp = avn.find('dcssch:presentation', NS)
            if avp is not None:
                pres = get_lang_text(avp)
                if pres is not None:
                    avo['presentation'] = pres
            avs.append(avo)
        o['availableValues'] = avs
    if get_child(p_node, 'valueListAllowed') == 'true':
        o['valueListAllowed'] = True
    if get_child(p_node, 'availableAsField') == 'false':
        o['availableAsField'] = False
    ip_node = p_node.find('dcssch:inputParameters', NS)
    if ip_node is not None:
        ip = build_dl_input_parameters(ip_node)
        if len(ip) > 0:
            o['inputParameters'] = ip[0] if len(ip) == 1 else ip   # PS unwrap @() одноэлементного → объект
    if get_child(p_node, 'denyIncompleteValues') == 'true':
        o['denyIncompleteValues'] = True
    use = get_child(p_node, 'use')
    if use is not None and use != '':
        o['use'] = use

    # Компактизация: {name} → "name"; {name, type} → "name: type"; иначе объект.
    keys = list(o.keys())
    if len(keys) == 1:
        return name
    if len(keys) == 2 and 'type' in o and isinstance(type_val, str):
        return '%s: %s' % (name, type_val)
    return o


# --- 4. Element dispatch ---
# Lookup-карта (диспетчер по тегу → DSL-ключ); порядок не влияет на вывод.
ELEMENT_KEY = {
    'UsualGroup': 'group', 'ColumnGroup': 'columnGroup', 'ButtonGroup': 'buttonGroup', 'InputField': 'input', 'CheckBoxField': 'check',
    'RadioButtonField': 'radio', 'LabelDecoration': 'label', 'LabelField': 'labelField',
    'PictureDecoration': 'picture', 'PictureField': 'picField', 'CalendarField': 'calendar',
    'Table': 'table', 'Pages': 'pages', 'Page': 'page', 'Button': 'button', 'CommandBar': 'cmdBar', 'Popup': 'popup',
    'SearchStringAddition': 'searchString', 'ViewStatusAddition': 'viewStatus', 'SearchControlAddition': 'searchControl',
    'SpreadSheetDocumentField': 'spreadsheet', 'HTMLDocumentField': 'html', 'TextDocumentField': 'textDoc',
    'FormattedDocumentField': 'formattedDoc', 'ProgressBarField': 'progressBar', 'TrackBarField': 'trackBar',
    'ChartField': 'chart', 'GraphicalSchemaField': 'graphicalSchema', 'PlannerField': 'planner',
    'PeriodField': 'periodField', 'DendrogramField': 'dendrogram', 'GanttChartField': 'ganttChart',
}

# Простые скаляры элемента (pass-through, зеркало $script:genericScalars). ПОРЯДОК значим (ordered).
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
    ('HorizontalSpacing', 'horizontalSpacing', 'value'),
    ('RepresentationInContextMenu', 'representationInContextMenu', 'value'),
    ('SettingsNamedItemDetailedRepresentation', 'settingsNamedItemDetailedRepresentation', 'bool'),
    ('ItemHeight', 'itemHeight', 'value'),
    ('DropListWidth', 'dropListWidth', 'value'),
    ('TitleDataPath', 'titleDataPath', 'value'),
    ('ExtendedEdit', 'extendedEdit', 'bool'),
    ('MaxRowsCount', 'maxRowsCount', 'value'),
    ('AutoMaxRowsCount', 'autoMaxRowsCount', 'bool'),
    ('HeightControlVariant', 'heightControlVariant', 'value'),
    ('EditTextUpdate', 'editTextUpdate', 'value'),
    ('ControlRepresentation', 'controlRepresentation', 'value'),
    ('ShapeRepresentation', 'shapeRepresentation', 'value'),
    ('AutoAddIncomplete', 'autoAddIncomplete', 'bool'),
    ('MarkNegatives', 'markNegatives', 'bool'),
    ('InitialListView', 'initialListView', 'value'),
    ('ChoiceListHeight', 'choiceListHeight', 'value'),
    ('ThreeState', 'threeState', 'bool'),
    ('ScrollOnCompress', 'scrollOnCompress', 'bool'),
    ('Shortcut', 'shortcut', 'value'),
    ('IncompleteChoiceMode', 'incompleteChoiceMode', 'value'),
    ('EqualColumnsWidth', 'equalColumnsWidth', 'bool'),
    ('ChildrenAlign', 'childrenAlign', 'value'),
    ('ImageScale', 'imageScale', 'value'),
    ('Zoomable', 'zoomable', 'bool'),
    ('Shape', 'shape', 'value'),
    ('PictureLocation', 'pictureLocation', 'value'),
    ('EqualItemsWidth', 'equalItemsWidth', 'bool'),
    ('ItemTitleHeight', 'itemTitleHeight', 'value'),
    ('SpecialTextInputMode', 'specialTextInputMode', 'value'),
    ('ItemWidth', 'itemWidth', 'value'),
    ('ShowCheckBoxesInDropList', 'showCheckBoxesInDropList', 'bool'),
    ('MultipleValueDataPath', 'multipleValueDataPath', 'value'),
    ('MultipleValuePresentDataPath', 'multipleValuePresentDataPath', 'value'),
    ('AutoShowOpenButtonMode', 'autoShowOpenButtonMode', 'value'),
    ('AutoShowClearButtonMode', 'autoShowClearButtonMode', 'value'),
    ('MultipleValuesTextColor', 'multipleValuesTextColor', 'value'),
    ('MultipleValuesBackColor', 'multipleValuesBackColor', 'value'),
    ('MultipleValuePictureShape', 'multipleValuePictureShape', 'value'),
    ('MultipleValuePictureDataPath', 'multipleValuePictureDataPath', 'value'),
    ('AutoCorrectionOnTextInput', 'autoCorrectionOnTextInput', 'value'),
    ('SpellCheckingOnTextInput', 'spellCheckingOnTextInput', 'value'),
    ('CommandUniqueness', 'commandUniqueness', 'bool'),
    ('AllowInputEmptyMultipleValues', 'allowInputEmptyMultipleValues', 'bool'),
    ('BehaviorOnHorizontalCompression', 'behaviorOnHorizontalCompression', 'value'),
]


# Захват generic-скаляров. Специфичная обработка (если ключ уже задан) — побеждает.
def add_generic_scalars(obj, node):
    for tag, key, kind in GENERIC_SCALARS:
        if key in obj:
            continue
        v = get_child(node, tag)
        if v is None:
            continue
        if kind == 'bool':
            obj[key] = (v == 'true')
        else:
            obj[key] = v


def decompile_children(parent_node, child_container='ChildItems'):
    container = parent_node.find('lf:%s' % child_container, NS)
    if container is None:
        return None
    lst = []
    for child in list(container):
        if _local_name(child.tag) in COMPANION_TAGS:
            continue
        el = decompile_element(child)
        if el is not None:
            lst.append(el)
    if len(lst) == 0:
        return None
    return lst


# Инверсия Emit-CompanionPanel: companion-панель (ContextMenu/AutoCommandBar) с контентом → объект либо None.
def decompile_companion_panel(node, tag, is_dyn_list_table=False):
    p = node.find('lf:%s' % tag, NS)
    if p is None:
        return None
    autofill_raw = get_child(p, 'Autofill')
    halign = get_child(p, 'HorizontalAlign')
    kids = decompile_children(p)
    has_kids = kids is not None and len(kids) > 0
    if is_dyn_list_table and tag == 'AutoCommandBar' and not has_kids and not halign:
        if autofill_raw == 'false':
            return None                                  # = дефолт эвристики → молчим
        return OrderedDict([('autofill', True)])         # голая панель → отклонение
    if not has_kids and autofill_raw is None and not halign:
        return None
    o = OrderedDict()
    if halign:
        o['horizontalAlign'] = halign
    if autofill_raw == 'false':
        o['autofill'] = False
    elif autofill_raw == 'true':
        o['autofill'] = True
    if has_kids:
        o['children'] = kids
    return o


# Инверсия Emit-ChoiceList: <ChoiceList><xr:Item>… → [ { value, presentation? } ] либо None.
def decompile_choice_list(node):
    cl = node.find('lf:ChoiceList', NS)
    if cl is None:
        return None
    items = []
    for it in cl.findall('xr:Item', NS):
        val_node = it.find('xr:Value/lf:Value', NS)
        pres_node = it.find('xr:Value/lf:Presentation', NS)
        ci = OrderedDict()
        if val_node is not None:
            if _attr(val_node, 'nil', NS_XSI) == 'true':
                # nil-значение — компилятор эмитит <Value xsi:nil="true"/>.
                ci['valueType'] = 'nil'
            else:
                xsi_type = _attr(val_node, 'type', NS_XSI)
                ci['value'] = convert_typed_value(_text(val_node), xsi_type)
                # Не-примитивный тип / raw-ссылка по GUID → сохраняем valueType.
                if xsi_type and not re.match(r'^xs:(string|decimal|boolean|dateTime)$', xsi_type) and \
                        (xsi_type != 'xr:DesignTimeRef' or re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-', _text(val_node) or '')):
                    ci['valueType'] = xsi_type
        # Presentation: непустой → текст; пустой <Presentation/> → "" суппресс-маркер.
        if pres_node is not None:
            p = get_lang_text_ws(pres_node)
            if p is not None and p != '':
                ci['presentation'] = p
            else:
                ci['presentation'] = ''
        items.append(ci)
    if len(items) > 0:
        return items
    return None


# Значение Параметра выбора (<lf:Value>): скаляр или v8:FixedArray → массив скаляров.
def convert_choice_param_value(val_node):
    vt = _attr(val_node, 'type', NS_XSI)
    if re.search(r'FixedArray$', vt):
        arr = []
        for it in val_node.findall('v8:Value', NS):
            inner = it.find('lf:Value', NS)
            if inner is not None:
                arr.append(convert_typed_value(_text(inner), _attr(inner, 'type', NS_XSI)))
        return arr
    return convert_typed_value(_text(val_node), vt)


# Инверсия Emit-ChoiceParameters: <ChoiceParameters><app:item name="X"><app:value><Value…> → [{name, value}].
def decompile_choice_parameters(node):
    cpn = node.find('lf:ChoiceParameters', NS)
    if cpn is None:
        return None
    items = []
    for it in cpn.findall('app:item', NS):
        o = OrderedDict()
        o['name'] = _attr(it, 'name')
        val_node = it.find('app:value/lf:Value', NS)
        if val_node is not None:
            o['value'] = convert_choice_param_value(val_node)
        items.append(o)
    if len(items) > 0:
        return items
    return None


# Инверсия Emit-ChoiceParameterLinks → [{name, dataPath, valueChange?}].
def decompile_choice_parameter_links(node):
    cln = node.find('lf:ChoiceParameterLinks', NS)
    if cln is None:
        return None
    items = []
    for lk in cln.findall('xr:Link', NS):
        o = OrderedDict()
        o['name'] = get_text(lk, 'xr:Name')
        o['dataPath'] = get_text(lk, 'xr:DataPath')
        vc = get_text(lk, 'xr:ValueChange')
        if vc and vc != 'Clear':
            o['valueChange'] = vc
        items.append(o)
    if len(items) > 0:
        return items
    return None


# Инверсия Emit-TypeLink: <TypeLink><xr:DataPath><xr:LinkItem> → {dataPath, linkItem}.
def decompile_type_link(node):
    tn = node.find('lf:TypeLink', NS)
    if tn is None:
        return None
    o = OrderedDict()
    o['dataPath'] = get_text(tn, 'xr:DataPath')
    li = get_text(tn, 'xr:LinkItem')
    if li is not None and li != '':
        o['linkItem'] = int(li)
    return o


# Захват <Format>/<EditFormat> (LocalStringType) → format/editFormat.
def add_format_props(obj, node):
    fmt = node.find('lf:Format', NS)
    if fmt is not None:
        t = get_lang_text(fmt)
        if t is not None and t != '':
            obj['format'] = t
    efmt = node.find('lf:EditFormat', NS)
    if efmt is not None:
        t = get_lang_text(efmt)
        if t is not None and t != '':
            obj['editFormat'] = t


# Ядро дополнения: source + Add-CommonProps + horizontalLocation. Layout добавляется отдельно.
def add_addition_core(obj, node, el_name):
    src = node.find('lf:AdditionSource/lf:Item', NS)
    if src is not None:
        obj['source'] = _text(src)
    add_common_props(obj, node, el_name)
    hl = get_child(node, 'HorizontalLocation')
    if hl:
        obj['horizontalLocation'] = hl.lower()


# Стандартные дополнения уровня таблицы → карта { тип: {отклонения} }.
def decompile_table_additions(table_node, table_name):
    tag_to_key = {'SearchStringAddition': 'searchString', 'ViewStatusAddition': 'viewStatus', 'SearchControlAddition': 'searchControl'}
    m = OrderedDict()
    for child in list(table_node):
        ln = _local_name(child.tag)
        if ln not in tag_to_key:
            continue
        key = tag_to_key[ln]
        nm = _attr(child, 'name')
        o = OrderedDict()
        o[key] = nm
        add_addition_core(o, child, nm)
        add_layout(o, child)
        del o[key]                                                          # имя авто
        if 'source' in o and o['source'] == table_name:
            del o['source']                                                 # source=таблица дефолт
        if len(o) > 0:
            m[key] = o
    if len(m) > 0:
        return m
    return None


# Спец-поля «документ/датчик» — общий скелет поля.
def decompile_simple_field(obj, node, name, key):
    obj[key] = name
    dp = get_child(node, 'DataPath')
    if dp:
        obj['path'] = dp
    add_common_props(obj, node, name)
    tl = get_child(node, 'TitleLocation')
    if tl:
        obj['titleLocation'] = tl.lower()
    em = get_child(node, 'EditMode')
    if em:
        obj['editMode'] = em


# Числовые скаляры датчиков (ProgressBar/TrackBar) — без xsi:type.
def add_gauge_scalars(obj, node, tags):
    for p in tags:
        v = get_child(node, p)
        if v is None:
            continue
        key = p[0:1].lower() + p[1:]
        if re.match(r'^-?\d+$', v):
            obj[key] = int(v)
        else:
            obj[key] = v


def decompile_element(node):
    tag = _local_name(node.tag)
    if tag not in ELEMENT_KEY:
        fail_ring3("элемент <%s>" % tag, "ChildItems/%s" % tag)
    key = ELEMENT_KEY[tag]
    name = _attr(node, 'name')
    obj = OrderedDict()

    if tag == 'UsualGroup':
        g = get_child(node, 'Group')
        gmap = {'Horizontal': 'horizontal', 'Vertical': 'vertical', 'AlwaysHorizontal': 'alwaysHorizontal', 'AlwaysVertical': 'alwaysVertical', 'HorizontalIfPossible': 'horizontalIfPossible'}
        if g and g in gmap:
            obj[key] = gmap[g]
        else:
            obj[key] = ''
        behavior = get_child(node, 'Behavior')
        if behavior:
            bmap = {'Usual': 'usual', 'Collapsible': 'collapsible', 'PopUp': 'popup'}
            obj['behavior'] = bmap[behavior] if behavior in bmap else behavior
        obj['name'] = name
        add_common_props(obj, node, name)
        rep = get_child(node, 'Representation')
        if rep:
            repmap = {'None': 'none', 'NormalSeparation': 'normal', 'WeakSeparation': 'weak', 'StrongSeparation': 'strong'}
            obj['representation'] = repmap[rep] if rep in repmap else rep
        st = get_child(node, 'ShowTitle')
        if st is not None:
            obj['showTitle'] = (st == 'true')
        cru = get_child(node, 'CurrentRowUse')
        if cru:
            obj['currentRowUse'] = cru
        crt = node.find('lf:CollapsedRepresentationTitle', NS)
        if crt is not None:
            ct = get_lang_text(crt)
            if ct is not None and ct != '':
                obj['collapsedTitle'] = ct
        if get_child(node, 'United') == 'false':
            obj['united'] = False
        if get_child(node, 'Collapsed') == 'true':
            obj['collapsed'] = True
        add_format_props(obj, node)
        kids = decompile_children(node)
        if kids:
            obj['children'] = kids
    elif tag == 'ColumnGroup':
        g = get_child(node, 'Group')
        gmap = {'Horizontal': 'horizontal', 'Vertical': 'vertical', 'InCell': 'inCell'}
        if g and g in gmap:
            obj[key] = gmap[g]
        else:
            obj[key] = ''
        obj['name'] = name
        add_common_props(obj, node, name)
        st = get_child(node, 'ShowTitle')
        if st is not None:
            obj['showTitle'] = (st == 'true')
        sih = get_child(node, 'ShowInHeader')
        if sih is not None:
            obj['showInHeader'] = to_bool(sih)
        kids = decompile_children(node)
        if kids:
            obj['children'] = kids
    elif tag == 'InputField':
        obj[key] = name
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        add_common_props(obj, node, name)
        ml_in = get_child(node, 'MultiLine')
        if ml_in is not None:
            obj['multiLine'] = (ml_in == 'true')
        pm_in = get_child(node, 'PasswordMode')
        if pm_in is not None:
            obj['passwordMode'] = (pm_in == 'true')
        mi = get_child(node, 'AutoMarkIncomplete')
        if mi is not None:
            obj['markIncomplete'] = (mi == 'true')
        em = get_child(node, 'EditMode')
        if em:
            obj['editMode'] = em
        tl = get_child(node, 'TitleLocation')
        if tl:
            obj['titleLocation'] = tl.lower()
        ih = node.find('lf:InputHint', NS)
        if ih is not None:
            t = get_lang_text_ws(ih)
            if t:
                obj['inputHint'] = t
        woe = node.find('lf:WarningOnEdit', NS)
        if woe is not None:
            t = get_lang_text_ws(woe)
            if t is not None:
                obj['warningOnEdit'] = t
        ftxt = node.find('lf:FooterText', NS)
        if ftxt is not None:
            t = get_lang_text_ws(ftxt)
            if t is not None:
                obj['footerText'] = t
        for p in ('ChoiceButton', 'ClearButton', 'SpinButton', 'DropListButton', 'ChoiceListButton'):
            v = get_child(node, p)
            if v is not None:
                obj[p[0:1].lower() + p[1:]] = to_bool(v)
        for p in ('Wrap', 'OpenButton', 'ListChoiceMode', 'ExtendedEditMultipleValues', 'ChooseType', 'QuickChoice', 'AutoChoiceIncomplete'):
            v = get_child(node, p)
            if v is not None:
                obj[p[0:1].lower() + p[1:]] = to_bool(v)
        for p in ('ChoiceForm', 'ChoiceHistoryOnInput', 'ChoiceFoldersAndItems', 'FooterDataPath'):
            v = get_child(node, p)
            if v is not None:
                obj[p[0:1].lower() + p[1:]] = v
        for p in ('MinValue', 'MaxValue'):
            mn = node.find('lf:%s' % p, NS)
            if mn is not None:
                xt = _attr(mn, 'type', NS_XSI)
                txt = _text(mn)
                k = p[0:1].lower() + p[1:]
                if re.search(r'decimal|int', xt):
                    if re.match(r'^-?\d+$', txt):
                        obj[k] = int(txt)
                    elif re.match(r'^-?\d+\.\d+$', txt):
                        obj[k] = Decimal(txt)
                    else:
                        obj[k] = txt
                else:
                    obj[k] = txt
        tde = get_child(node, 'TypeDomainEnabled')
        if tde is not None:
            obj['typeDomainEnabled'] = to_bool(tde)
        at_node = node.find('lf:AvailableTypes', NS)
        if at_node is not None:
            at = decompile_type(at_node)
            if at:
                obj['availableTypes'] = at
        cbr = get_child(node, 'ChoiceButtonRepresentation')
        if cbr:
            obj['choiceButtonRepresentation'] = cbr
        cbp = get_picture_ref(node, 'ChoiceButtonPicture')
        if cbp is not None:
            obj['choiceButtonPicture'] = cbp
        if get_child(node, 'TextEdit') == 'false':
            obj['textEdit'] = False
        cl = decompile_choice_list(node)
        if cl:
            obj['choiceList'] = cl
        add_format_props(obj, node)
        cp = decompile_choice_parameters(node)
        if cp:
            obj['choiceParameters'] = cp
        cpl = decompile_choice_parameter_links(node)
        if cpl:
            obj['choiceParameterLinks'] = cpl
        tlk = decompile_type_link(node)
        if tlk:
            obj['typeLink'] = tlk
    elif tag == 'CheckBoxField':
        obj[key] = name
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        add_common_props(obj, node, name)
        em = get_child(node, 'EditMode')
        if em:
            obj['editMode'] = em
        cbt = get_child(node, 'CheckBoxType')
        if cbt is None:
            obj['checkBoxType'] = ''
        elif cbt != 'Auto':
            obj['checkBoxType'] = cbt[0:1].lower() + cbt[1:]
        add_title_location(obj, node, 'Right')
        woe = node.find('lf:WarningOnEdit', NS)
        if woe is not None:
            t = get_lang_text_ws(woe)
            if t is not None:
                obj['warningOnEdit'] = t
        fdp = get_child(node, 'FooterDataPath')
        if fdp:
            obj['footerDataPath'] = fdp
        ftxt = node.find('lf:FooterText', NS)
        if ftxt is not None:
            t = get_lang_text_ws(ftxt)
            if t is not None:
                obj['footerText'] = t
        add_format_props(obj, node)
    elif tag == 'RadioButtonField':
        obj[key] = name
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        add_common_props(obj, node, name)
        add_title_location(obj, node, 'None')
        em = get_child(node, 'EditMode')
        if em:
            obj['editMode'] = em
        rbt = get_child(node, 'RadioButtonType')
        if rbt:
            obj['radioButtonType'] = rbt
        cc = get_child(node, 'ColumnsCount')
        if cc:
            obj['columnsCount'] = int(cc)
        woe = node.find('lf:WarningOnEdit', NS)
        if woe is not None:
            t = get_lang_text_ws(woe)
            if t is not None:
                obj['warningOnEdit'] = t
        cl = decompile_choice_list(node)
        if cl:
            obj['choiceList'] = cl
    elif tag == 'LabelDecoration':
        obj[key] = name
        add_common_props(obj, node, name)
        if get_child(node, 'Hyperlink') == 'true':
            obj['hyperlink'] = True
        ti_node = node.find('lf:Title', NS)
        if ti_node is not None:
            tv = get_ml_formatted_value(ti_node)
            if tv is not None:
                obj['title'] = tv
    elif tag == 'LabelField':
        obj[key] = name
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        add_common_props(obj, node, name)
        tl = get_child(node, 'TitleLocation')
        if tl:
            obj['titleLocation'] = tl.lower()
        em = get_child(node, 'EditMode')
        if em:
            obj['editMode'] = em
        if get_child(node, 'Hiperlink') == 'true':   # тег <Hiperlink> (опечатка платформы)
            obj['hyperlink'] = True
        pm = get_child(node, 'PasswordMode')
        if pm is not None:
            obj['passwordMode'] = (pm == 'true')
        woe = node.find('lf:WarningOnEdit', NS)
        if woe is not None:
            t = get_lang_text_ws(woe)
            if t is not None:
                obj['warningOnEdit'] = t
        fdp = get_child(node, 'FooterDataPath')
        if fdp:
            obj['footerDataPath'] = fdp
        ftxt = node.find('lf:FooterText', NS)
        if ftxt is not None:
            t = get_lang_text_ws(ftxt)
            if t is not None:
                obj['footerText'] = t
        add_format_props(obj, node)
    elif tag == 'PictureDecoration':
        obj[key] = name
        add_common_props(obj, node, name)
        ti_node = node.find('lf:Title', NS)
        if ti_node is not None:
            tv = get_ml_formatted_value(ti_node)
            if tv is not None:
                obj['title'] = tv
        npt = node.find('lf:NonselectedPictureText', NS)
        if npt is not None:
            t = get_lang_text_ws(npt)
            if t is not None:
                obj['nonselectedPictureText'] = t
        ref = node.find('lf:Picture/xr:Ref', NS)
        abs_ = node.find('lf:Picture/xr:Abs', NS)
        if ref is not None:
            obj['src'] = _text(ref)
        elif abs_ is not None:
            obj['src'] = 'abs:%s' % _text(abs_)
        lt = node.find('lf:Picture/xr:LoadTransparent', NS)
        if lt is not None and _text(lt) == 'true':
            obj['loadTransparent'] = True
        tpx = node.find('lf:Picture/xr:TransparentPixel', NS)
        if tpx is not None:
            obj['transparentPixel'] = OrderedDict([('x', int(_attr(tpx, 'x'))), ('y', int(_attr(tpx, 'y')))])
        if get_child(node, 'Hyperlink') == 'true':
            obj['hyperlink'] = True
    elif tag == 'PictureField':
        obj[key] = name
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        add_common_props(obj, node, name)
        em = get_child(node, 'EditMode')
        if em:
            obj['editMode'] = em
        tl = get_child(node, 'TitleLocation')
        if tl:
            obj['titleLocation'] = tl.lower()
        if get_child(node, 'Hyperlink') == 'true':
            obj['hyperlink'] = True
        vp = get_picture_ref(node, 'ValuesPicture')
        if vp is not None:
            obj['valuesPicture'] = vp
        npt = node.find('lf:NonselectedPictureText', NS)
        if npt is not None:
            t = get_lang_text_ws(npt)
            if t is not None:
                obj['nonselectedPictureText'] = t
        fdp = get_child(node, 'FooterDataPath')
        if fdp:
            obj['footerDataPath'] = fdp
        ftxt = node.find('lf:FooterText', NS)
        if ftxt is not None:
            t = get_lang_text_ws(ftxt)
            if t is not None:
                obj['footerText'] = t
    elif tag == 'CalendarField':
        obj[key] = name
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        add_common_props(obj, node, name)
        tl = get_child(node, 'TitleLocation')
        if tl:
            obj['titleLocation'] = tl.lower()
        sm = get_child(node, 'SelectionMode')
        if sm:
            obj['selectionMode'] = sm
        scd = get_child(node, 'ShowCurrentDate')
        if scd is not None:
            obj['showCurrentDate'] = (scd == 'true')
        wim = get_child(node, 'WidthInMonths')
        if wim is not None:
            obj['widthInMonths'] = int(wim)
        him = get_child(node, 'HeightInMonths')
        if him is not None:
            obj['heightInMonths'] = int(him)
        smp = get_child(node, 'ShowMonthsPanel')
        if smp is not None:
            obj['showMonthsPanel'] = (smp == 'true')
    elif tag == 'Table':
        obj[key] = name
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        add_common_props(obj, node, name)
        tl = get_child(node, 'TitleLocation')
        if tl:
            obj['titleLocation'] = tl.lower()
        rep = get_child(node, 'Representation')
        if rep:
            obj['representation'] = rep
        crs = get_child(node, 'ChangeRowSet')
        if crs is not None:
            obj['changeRowSet'] = (crs == 'true')
        cro = get_child(node, 'ChangeRowOrder')
        if cro is not None:
            obj['changeRowOrder'] = (cro == 'true')
        if get_child(node, 'AutoInsertNewRow') == 'true':
            obj['autoInsertNewRow'] = True
        if node.find('lf:RowFilter', NS) is not None:
            obj['rowFilter'] = None
        if get_child(node, 'Header') == 'false':
            obj['header'] = False
        if get_child(node, 'Footer') == 'true':
            obj['footer'] = True
        htr = get_child(node, 'HeightInTableRows')
        if htr:
            obj['heightInTableRows'] = int(htr)
        hh = get_child(node, 'HeaderHeight')
        if hh is not None:
            obj['headerHeight'] = int(hh)
        fh = get_child(node, 'FooterHeight')
        if fh is not None:
            obj['footerHeight'] = int(fh)
        cru = get_child(node, 'CurrentRowUse')
        if cru:
            obj['currentRowUse'] = cru
        rr = get_child(node, 'RefreshRequest')
        if rr:
            obj['refreshRequest'] = rr
        # CommandBarLocation: дин-список-таблица авто-инжектит "None" → инвертируем суппресс-маркером.
        cbl = get_child(node, 'CommandBarLocation')
        if has_child(node, 'UpdateOnDataChange'):
            if cbl is None:
                obj['commandBarLocation'] = ''
            elif cbl != 'None':
                obj['commandBarLocation'] = cbl
        elif cbl:
            obj['commandBarLocation'] = cbl
        ssl = get_child(node, 'SearchStringLocation')
        if ssl:
            obj['searchStringLocation'] = ssl
        vsl = get_child(node, 'ViewStatusLocation')
        if vsl:
            obj['viewStatusLocation'] = vsl
        scl = get_child(node, 'SearchControlLocation')
        if scl:
            obj['searchControlLocation'] = scl
        if get_child(node, 'ChoiceMode') == 'true':
            obj['choiceMode'] = True
        selm = get_child(node, 'SelectionMode')
        if selm:
            obj['selectionMode'] = selm
        rsm = get_child(node, 'RowSelectionMode')
        if rsm:
            obj['rowSelectionMode'] = rsm
        if get_child(node, 'VerticalLines') == 'false':
            obj['verticalLines'] = False
        if get_child(node, 'HorizontalLines') == 'false':
            obj['horizontalLines'] = False
        if get_child(node, 'UseAlternationRowColor') == 'true':
            obj['useAlternationRowColor'] = True
        taf = get_child(node, 'Autofill')
        if taf is not None:
            obj['autofill'] = (taf == 'true')
        if get_child(node, 'MultipleChoice') == 'true':
            obj['multipleChoice'] = True
        soin = get_child(node, 'SearchOnInput')
        if soin:
            obj['searchOnInput'] = soin
        mi = get_child(node, 'AutoMarkIncomplete')
        if mi is not None:
            obj['markIncomplete'] = (mi == 'true')
        itv = get_child(node, 'InitialTreeView')
        if itv:
            obj['initialTreeView'] = itv
        rp = get_picture_ref(node, 'RowsPicture')
        if rp is not None:
            obj['rowsPicture'] = rp
        rpdp = get_child(node, 'RowPictureDataPath')
        if has_child(node, 'UpdateOnDataChange'):
            if get_child(node, 'AutoRefresh') == 'true':
                obj['autoRefresh'] = True
            arp = get_child(node, 'AutoRefreshPeriod')
            if arp and arp != '60':
                obj['autoRefreshPeriod'] = int(arp)
            cfi = get_child(node, 'ChoiceFoldersAndItems')
            if cfi and cfi != 'Items':
                obj['choiceFoldersAndItems'] = cfi
            if get_child(node, 'RestoreCurrentRow') == 'true':
                obj['restoreCurrentRow'] = True
            if get_child(node, 'ShowRoot') == 'false':
                obj['showRoot'] = False
            if get_child(node, 'AllowRootChoice') == 'true':
                obj['allowRootChoice'] = True
            uodc = get_child(node, 'UpdateOnDataChange')
            if uodc and uodc != 'Auto':
                obj['updateOnDataChange'] = uodc
            if get_child(node, 'AllowGettingCurrentRowURL') == 'false':
                obj['allowGettingCurrentRowURL'] = False
            if rpdp is None:
                obj['rowPictureDataPath'] = ''
            elif rpdp != ('%s.DefaultPicture' % _ps_str(obj.get('path'))):
                obj['rowPictureDataPath'] = rpdp
            usg = get_child(node, 'UserSettingsGroup')
            if usg:
                if re.match(r'^\d+:[0-9a-fA-F]{8}-', usg):
                    sys.stderr.write("form-decompile: UserSettingsGroup '%s' (%s) — ссылка по id, не воспроизводима, опущена\n" % (usg, name))
                else:
                    obj['userSettingsGroup'] = usg
        elif rpdp:
            obj['rowPictureDataPath'] = rpdp
        cs_node = node.find('lf:CommandSet', NS)
        if cs_node is not None:
            exc = []
            for ec in cs_node.findall('lf:ExcludedCommand', NS):
                exc.append(_text(ec))
            if len(exc) > 0:
                obj['excludedCommands'] = exc
        cols = decompile_children(node)
        if cols:
            obj['columns'] = cols
        add_map = decompile_table_additions(node, name)
        if add_map:
            obj['additions'] = add_map
    elif tag == 'Pages':
        obj[key] = name
        add_common_props(obj, node, name)
        pr = get_child(node, 'PagesRepresentation')
        if pr:
            obj['pagesRepresentation'] = pr
        cru = get_child(node, 'CurrentRowUse')
        if cru:
            obj['currentRowUse'] = cru
        kids = decompile_children(node)
        if kids:
            obj['children'] = kids
    elif tag == 'Page':
        obj[key] = name
        add_common_props(obj, node, name)
        g = get_child(node, 'Group')
        gmap = {'Horizontal': 'horizontal', 'Vertical': 'vertical', 'AlwaysHorizontal': 'alwaysHorizontal', 'AlwaysVertical': 'alwaysVertical', 'HorizontalIfPossible': 'horizontalIfPossible'}
        if g and g in gmap:
            obj['group'] = gmap[g]
        pp = get_picture_ref(node, 'Picture')
        if pp is not None:
            obj['picture'] = pp
        st = get_child(node, 'ShowTitle')
        if st is not None:
            obj['showTitle'] = (st == 'true')
        add_format_props(obj, node)
        kids = decompile_children(node)
        if kids:
            obj['children'] = kids
    elif tag == 'Button':
        obj[key] = name
        cmd = get_child(node, 'CommandName')
        if cmd:
            m1 = re.match(r'^Form\.Command\.(.+)$', cmd)
            m2 = re.match(r'^Form\.StandardCommand\.(.+)$', cmd)
            m3 = re.match(r'^Form\.Item\.(.+)\.StandardCommand\.(.+)$', cmd)
            if m1:
                obj['command'] = m1.group(1)
            elif m2:
                obj['stdCommand'] = m2.group(1)
            elif m3:
                obj['stdCommand'] = '%s.%s' % (m3.group(1), m3.group(2))
            else:
                obj['commandName'] = cmd
        dp = get_child(node, 'DataPath')
        if dp:
            obj['path'] = dp
        btn_param = node.find('lf:Parameter', NS)
        if btn_param is not None:
            pxt = _attr(btn_param, 'type', NS_XSI)
            if re.search(r'TypeDescription$', pxt):
                pt = decompile_type(btn_param)
                if pt:
                    obj['parameter'] = OrderedDict([('type', pt)])
            elif _text(btn_param):
                obj['parameter'] = _text(btn_param)
        add_common_props(obj, node, name)
        type_ = get_child(node, 'Type')
        if type_:
            tmap = {'CommandBarButton': 'commandBar', 'UsualButton': 'usual', 'Hyperlink': 'hyperlink', 'CommandBarHyperlink': 'hyperlink'}
            obj['type'] = tmap[type_] if type_ in tmap else type_
        if get_child(node, 'DefaultButton') == 'true':
            obj['defaultButton'] = True
        if get_child(node, 'Check') == 'true':
            obj['checked'] = True
        set_command_picture(obj, node)
        rep = get_child(node, 'Representation')
        if rep:
            obj['representation'] = rep
        lic = get_child(node, 'LocationInCommandBar')
        if lic:
            obj['locationInCommandBar'] = lic
    elif tag == 'ButtonGroup':
        obj[key] = name
        add_common_props(obj, node, name)
        cs = get_child(node, 'CommandSource')
        if cs:
            if re.match(r'^\d+:[0-9a-fA-F]{8}-', cs):
                sys.stderr.write("form-decompile: CommandSource '%s' (%s) — ссылка по id, не воспроизводима, опущена\n" % (cs, name))
            else:
                obj['commandSource'] = cs
        rep = get_child(node, 'Representation')
        if rep:
            obj['representation'] = rep
        kids = decompile_children(node)
        if kids:
            obj['children'] = kids
    elif tag == 'CommandBar':
        obj[key] = name
        add_common_props(obj, node, name)
        cs = get_child(node, 'CommandSource')
        if cs:
            if re.match(r'^\d+:[0-9a-fA-F]{8}-', cs):
                sys.stderr.write("form-decompile: CommandSource '%s' (%s) — ссылка по id, не воспроизводима, опущена\n" % (cs, name))
            else:
                obj['commandSource'] = cs
        hl = get_child(node, 'HorizontalLocation')
        if hl:
            obj['horizontalLocation'] = hl.lower()
        if get_child(node, 'Autofill') == 'true':
            obj['autofill'] = True
        kids = decompile_children(node)
        if kids:
            obj['children'] = kids
    elif tag == 'Popup':
        obj[key] = name
        add_common_props(obj, node, name)
        set_command_picture(obj, node)
        rep = get_child(node, 'Representation')
        if rep:
            obj['representation'] = rep
        cs = get_child(node, 'CommandSource')
        if cs:
            if re.match(r'^\d+:[0-9a-fA-F]{8}-', cs):
                sys.stderr.write("form-decompile: CommandSource '%s' (%s) — ссылка по id, не воспроизводима, опущена\n" % (cs, name))
            else:
                obj['commandSource'] = cs
        kids = decompile_children(node)
        if kids:
            obj['children'] = kids
    elif tag == 'SearchStringAddition':
        obj[key] = name
        add_addition_core(obj, node, name)
    elif tag == 'ViewStatusAddition':
        obj[key] = name
        add_addition_core(obj, node, name)
    elif tag == 'SearchControlAddition':
        obj[key] = name
        add_addition_core(obj, node, name)
    elif tag == 'SpreadSheetDocumentField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'HTMLDocumentField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'TextDocumentField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'FormattedDocumentField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'ProgressBarField':
        decompile_simple_field(obj, node, name, key)
        add_gauge_scalars(obj, node, ('MinValue', 'MaxValue'))
    elif tag == 'TrackBarField':
        decompile_simple_field(obj, node, name, key)
        add_gauge_scalars(obj, node, ('MinValue', 'MaxValue', 'LargeStep', 'MarkingStep', 'Step'))
    elif tag == 'ChartField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'GraphicalSchemaField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'PlannerField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'PeriodField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'DendrogramField':
        decompile_simple_field(obj, node, name, key)
    elif tag == 'GanttChartField':
        decompile_simple_field(obj, node, name, key)
        tbl_node = node.find('lf:Table', NS)
        if tbl_node is not None:
            obj['ganttTable'] = decompile_element(tbl_node)

    # DisplayImportance — атрибут открывающего тега, захват «как есть».
    di = _attr(node, 'DisplayImportance')
    if di:
        obj['displayImportance'] = di
    # title: "" — подавление авто-вывода компилятора там, где <Title> отсутствует.
    if 'title' not in obj:
        auto_title = False
        if tag in ('LabelDecoration', 'Page', 'Popup'):
            auto_title = True
        elif tag == 'Button':
            auto_title = not ('command' in obj or 'commandName' in obj or 'stdCommand' in obj)
        elif tag in ('InputField', 'CheckBoxField', 'RadioButtonField', 'LabelField', 'Table', 'CalendarField'):
            auto_title = 'path' not in obj
        if auto_title:
            obj['title'] = ''
    add_layout(obj, node)
    add_generic_scalars(obj, node)
    # extendedTooltip: companion <ExtendedTooltip> (LabelDecoration). Текст-форма или own-content объект.
    et_node = node.find('lf:ExtendedTooltip', NS)
    if et_node is not None:
        et_title = et_node.find('lf:Title', NS)
        text_val = get_ml_formatted_value(et_title) if et_title is not None else None
        et_obj = OrderedDict()
        add_layout(et_obj, et_node)
        add_generic_scalars(et_obj, et_node)
        add_appearance(et_obj, et_node)
        et_tt = et_node.find('lf:ToolTip', NS)
        if et_tt is not None:
            tt_val = get_lang_text(et_tt)
            if tt_val is not None:
                et_obj['tooltip'] = tt_val
        if get_child(et_node, 'Visible') == 'false':
            et_obj['hidden'] = True
        if get_child(et_node, 'Enabled') == 'false':
            et_obj['disabled'] = True
        if get_child(et_node, 'Hyperlink') == 'true':
            et_obj['hyperlink'] = True
        et_ev = get_events(et_node, name)
        if et_ev:
            et_obj['events'] = et_ev
        if len(et_obj) > 0:
            if text_val is not None:
                if isinstance(text_val, dict) and 'text' in text_val:
                    et_obj['text'] = text_val['text']
                    if text_val['formatted']:
                        et_obj['formatted'] = True
                else:
                    et_obj['text'] = text_val
                if 'formatted' not in et_obj and et_title is not None and _attr(et_title, 'formatted') == 'true':
                    et_obj['formatted'] = True
            obj['extendedTooltip'] = et_obj
        elif text_val is not None:
            obj['extendedTooltip'] = text_val
    # companion-панели с контентом: AutoCommandBar → commandBar, ContextMenu → contextMenu
    is_dyn_list_table = (tag == 'Table') and has_child(node, 'UpdateOnDataChange')
    cb = decompile_companion_panel(node, 'AutoCommandBar', is_dyn_list_table)
    if cb is not None:
        obj['commandBar'] = cb
    cm = decompile_companion_panel(node, 'ContextMenu')
    if cm is not None:
        obj['contextMenu'] = cm
    return obj


# ─────────────────────────────────────────────────────────────────────────────
# Planner design-time <Settings xsi:type="pl:Planner"> → объект planner на реквизите.
def pld_bool(v):
    if v is None:
        return None
    return v == 'true'


def pld_int(v):
    if v is None:
        return None
    return int(v)


def get_planner_value(node):
    if node is None:
        return None
    if _attr(node, 'nil', NS_XSI) == 'true':
        return None
    t = _text(node)
    if t:
        return t
    return None


def build_planner_font(node):
    if node is None:
        return None
    o = OrderedDict()
    for a in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
        av = _attr(node, a)
        if av != '':
            o[a] = av
    if len(o) == 0:
        return None
    return o


def build_planner_border(node):
    if node is None:
        return None
    o = OrderedDict()
    w = _attr(node, 'width')
    if w != '':
        o['width'] = int(w)
    st = node.find('{*}style')
    if st is not None:
        o['style'] = _text(st)
    return o


def build_planner_item(itn):
    o = OrderedDict()
    val_node = itn.find('{*}value')
    if val_node is not None and _attr(val_node, 'nil', NS_XSI) != 'true' and _text(val_node):
        o['value'] = _text(val_node)
    o['text'] = get_child(itn, 'text')
    tt = get_child(itn, 'tooltip')
    if tt:
        o['tooltip'] = tt
    o['begin'] = get_child(itn, 'begin')
    o['end'] = get_child(itn, 'end')
    o['borderColor'] = get_child(itn, 'borderColor')
    o['backColor'] = get_child(itn, 'backColor')
    o['textColor'] = get_child(itn, 'textColor')
    fnt = build_planner_font(itn.find('{*}font'))
    if fnt:
        o['font'] = fnt
    o['replacementDate'] = get_child(itn, 'replacementDate')
    o['deleted'] = pld_bool(get_child(itn, 'deleted'))
    o['id'] = get_child(itn, 'id')
    o['textFormatted'] = pld_bool(get_child(itn, 'textFormatted'))
    brd = build_planner_border(itn.find('{*}border'))
    if brd:
        o['border'] = brd
    o['editMode'] = get_child(itn, 'editMode')
    return o


def build_planner_dim_element(eln):
    o = OrderedDict()
    v = get_planner_value(eln.find('{*}value'))
    if v is not None:
        o['value'] = v
    o['text'] = get_child(eln, 'text')
    o['borderColor'] = get_child(eln, 'borderColor')
    o['backColor'] = get_child(eln, 'backColor')
    o['textColor'] = get_child(eln, 'textColor')
    fnt = build_planner_font(eln.find('{*}font'))
    if fnt:
        o['font'] = fnt
    subs = []
    for s in eln.findall('{*}item'):
        subs.append(build_planner_dim_element(s))
    if len(subs) > 0:
        o['elements'] = subs
    sos = get_child(eln, 'showOnlySubordinatesAreas')
    if sos is not None:
        o['showOnlySubordinatesAreas'] = (sos == 'true')
    o['textFormatted'] = pld_bool(get_child(eln, 'textFormatted'))
    return o


def build_planner_dimension(dn):
    o = OrderedDict()
    v = get_planner_value(dn.find('{*}value'))
    if v is not None:
        o['value'] = v
    o['text'] = get_child(dn, 'text')
    o['borderColor'] = get_child(dn, 'borderColor')
    o['backColor'] = get_child(dn, 'backColor')
    o['textColor'] = get_child(dn, 'textColor')
    fnt = build_planner_font(dn.find('{*}font'))
    if fnt:
        o['font'] = fnt
    els = []
    for e in dn.findall('{*}item'):
        els.append(build_planner_dim_element(e))
    if len(els) > 0:
        o['elements'] = els
    o['textFormatted'] = pld_bool(get_child(dn, 'textFormatted'))
    return o


def build_planner_level(lvn):
    o = OrderedDict()
    o['measure'] = get_child(lvn, 'measure')
    o['interval'] = pld_int(get_child(lvn, 'interval'))
    o['show'] = pld_bool(get_child(lvn, 'show'))
    line_node = lvn.find('{*}line')
    if line_node is not None:
        ln = OrderedDict()
        w = _attr(line_node, 'width')
        if w != '':
            ln['width'] = int(w)
        g = _attr(line_node, 'gap')
        if g != '':
            ln['gap'] = (g == 'true')
        st = line_node.find('{*}style')
        if st is not None:
            ln['style'] = _text(st)
        o['line'] = ln
    o['scaleColor'] = get_child(lvn, 'scaleColor')
    o['dayFormatRule'] = get_child(lvn, 'dayFormatRule')
    fmt_node = lvn.find('{*}format')
    if fmt_node is not None:
        f = get_lang_text(fmt_node)
        if f is not None:
            o['format'] = f
    labels_node = lvn.find('{*}labels')
    if labels_node is not None:
        o['labels'] = OrderedDict([('ticks', pld_int(get_child(labels_node, 'ticks')))])
    o['backColor'] = get_child(lvn, 'backColor')
    o['textColor'] = get_child(lvn, 'textColor')
    o['showPereodicalLabels'] = pld_bool(get_child(lvn, 'showPereodicalLabels'))
    return o


def build_planner_time_scale(tsn):
    o = OrderedDict()
    o['placement'] = get_child(tsn, 'placement')
    levels = []
    for lvn in tsn.findall('{*}level'):
        levels.append(build_planner_level(lvn))
    o['levels'] = levels
    o['transparent'] = pld_bool(get_child(tsn, 'transparent'))
    o['backColor'] = get_child(tsn, 'backColor')
    o['textColor'] = get_child(tsn, 'textColor')
    o['currentLevel'] = pld_int(get_child(tsn, 'currentLevel'))
    return o


def build_planner_settings(set_node):
    pl = OrderedDict()
    item_nodes = set_node.findall('{*}item')
    if len(item_nodes) > 0:
        items = []
        for itn in item_nodes:
            items.append(build_planner_item(itn))
        pl['items'] = items
    dim_nodes = set_node.findall('{*}dimension')
    if len(dim_nodes) > 0:
        dims = []
        for dn in dim_nodes:
            dims.append(build_planner_dimension(dn))
        pl['dimensions'] = dims
    pl['borderColor'] = get_child(set_node, 'borderColor')
    pl['backColor'] = get_child(set_node, 'backColor')
    pl['textColor'] = get_child(set_node, 'textColor')
    pl['lineColor'] = get_child(set_node, 'lineColor')
    fnt = build_planner_font(set_node.find('{*}font'))
    if fnt:
        pl['font'] = fnt
    pl['beginOfRepresentationPeriod'] = get_child(set_node, 'beginOfRepresentationPeriod')
    pl['endOfRepresentationPeriod'] = get_child(set_node, 'endOfRepresentationPeriod')
    pl['alignElementsOfTimeScale'] = pld_bool(get_child(set_node, 'alignElementsOfTimeScale'))
    pl['displayTimeScaleWrapHeaders'] = pld_bool(get_child(set_node, 'displayTimeScaleWrapHeaders'))
    pl['displayWrapHeaders'] = pld_bool(get_child(set_node, 'displayWrapHeaders'))
    wf_node = set_node.find('{*}timeScaleWrapHeadersFormat')
    if wf_node is not None:
        wf = get_lang_text(wf_node)
        if wf is not None:
            pl['timeScaleWrapHeadersFormat'] = wf
    pl['periodicVariantUnit'] = get_child(set_node, 'periodicVariantUnit')
    pl['periodicVariantRepetition'] = pld_int(get_child(set_node, 'periodicVariantRepetition'))
    pl['timeScaleWrapBeginIndent'] = pld_int(get_child(set_node, 'timeScaleWrapBeginIndent'))
    pl['timeScaleWrapEndIndent'] = pld_int(get_child(set_node, 'timeScaleWrapEndIndent'))
    ts_node = set_node.find('{*}timeScale')
    if ts_node is not None:
        pl['timeScale'] = build_planner_time_scale(ts_node)
    per_node = set_node.find('{*}period')
    if per_node is not None:
        pl['period'] = OrderedDict([('begin', get_child(per_node, 'begin')), ('end', get_child(per_node, 'end'))])
    pl['displayCurrentDate'] = pld_bool(get_child(set_node, 'displayCurrentDate'))
    pl['itemsTimeRepresentation'] = get_child(set_node, 'itemsTimeRepresentation')
    pl['itemsBehaviorWhenSpaceInsufficient'] = get_child(set_node, 'itemsBehaviorWhenSpaceInsufficient')
    pl['autoMinColumnWidth'] = pld_bool(get_child(set_node, 'autoMinColumnWidth'))
    pl['autoMinRowHeight'] = pld_bool(get_child(set_node, 'autoMinRowHeight'))
    pl['minColumnWidth'] = pld_int(get_child(set_node, 'minColumnWidth'))
    pl['minRowHeight'] = pld_int(get_child(set_node, 'minRowHeight'))
    pl['fixDimensionsHeader'] = get_child(set_node, 'fixDimensionsHeader')
    pl['fixTimeScaleHeader'] = get_child(set_node, 'fixTimeScaleHeader')
    brd = build_planner_border(set_node.find('{*}border'))
    if brd:
        pl['border'] = brd
    pl['newItemsTextType'] = get_child(set_node, 'newItemsTextType')
    return pl


# ─────────────────────────────────────────────────────────────────────────────
# Chart design-time <Settings xsi:type="d4p1:Chart"> → объект chart (генерик-движок).
CHART_ML_FIELDS = {'title', 'lbFormat', 'lbpFormat', 'vsFormat', 'dtFormat', 'dataSourceDescription', 'labelFormat', 'text'}
CHART_SERIES_FIELDS = {'realSeriesData', 'realExSeriesData', 'realPointData', 'realDataItems'}
CHART_ATTR_FIELDS = {'gaugeQualityBands'}


def conv_chart_scalar(v):
    if v == 'true':
        return True
    if v == 'false':
        return False
    return v


def build_chart_node(n, name):
    # ML-поле → строка/мапа/"" (даже ru-only форсим в ML на эмите по имени)
    if name in CHART_ML_FIELDS:
        ml = get_lang_text(n)
        if ml is None:
            return ''
        return ml
    kids = list(n)
    if len(kids) == 0:
        # лист: attrs-only (шрифт/gaugeQualityBands) или текст
        attrs = [(k, v) for k, v in n.attrib.items() if k != _XSI_TYPE and k != ('{%s}nil' % NS_XSI)]
        if len(attrs) > 0:
            o = OrderedDict()
            for k, v in attrs:
                o[k] = conv_chart_scalar(v)
            return o
        return conv_chart_scalar(_text(n))
    # line/border: дочерний v8ui:style (+ width[/gap])
    style_child = n.find('{*}style')
    if style_child is not None:
        o = OrderedDict()
        w = _attr(n, 'width')
        if w != '':
            o['width'] = int(w)
        g = _attr(n, 'gap')
        if g != '':
            o['gap'] = (g == 'true')
        o['style'] = _text(style_child)
        return o
    # вложенный объект d4p1: группируем детей по имени
    o = OrderedDict()
    for c in kids:
        ln = _local_name(c.tag)
        val = build_chart_node(c, ln)
        if ln in CHART_SERIES_FIELDS:
            if ln not in o:
                o[ln] = []
            o[ln].append(val)
        elif ln in o:
            if not isinstance(o[ln], list):
                o[ln] = [o[ln]]
            o[ln].append(val)
        else:
            o[ln] = val
    return o


def build_chart_settings(set_node):
    return build_chart_node(set_node, '')


# Зеркало компилятор-эвристики B3: есть ли cmdBar-элемент где-либо в дереве.
def test_any_cmd_bar(lst):
    if not lst:
        return False
    for e in lst:
        if isinstance(e, dict) and 'cmdBar' in e:
            return True
        if isinstance(e, dict):
            if 'children' in e and test_any_cmd_bar(e['children']):
                return True
            if 'columns' in e and test_any_cmd_bar(e['columns']):
                return True
    return False


# Объектный тип (зеркало Test-IsObjectLikeType) — кандидат на авто-main эвристики 11b.3.
def test_is_object_like_type_dec(type_):
    if not type_:
        return False
    if type_ == 'DynamicList' or type_ == 'ConstantsSet':
        return True
    return bool(re.match(r'^(CatalogObject|DocumentObject|DataProcessorObject|ReportObject|ExternalDataProcessorObject|ExternalReportObject|BusinessProcessObject|TaskObject|ChartOfAccountsObject|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesObject|ExchangePlanObject|InformationRegisterRecordSet|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|CalculationRegisterRecordSet|InformationRegisterRecordManager)\.', type_))


# Ring 3: конструкции вне зоны поддержки (зеркало inline-скана канона 219-235).
def _ring3_scan(root, form_path):
    # ConditionalAppearance со scope (привязка к области) пока не воспроизводим.
    for ca in root.iter():
        if _local_name(ca.tag) != 'ConditionalAppearance':
            continue
        for item in list(ca):
            if _local_name(item.tag) != 'item':
                continue
            for scope in list(item):
                if _local_name(scope.tag) != 'scope':
                    continue
                if len(scope) > 0 or (scope.text or '').strip():
                    fail_ring3("ConditionalAppearance со scope", "form/ConditionalAppearance/item/scope")
    # Реквизит с design-time <Settings> chart-типа (кроме TypeDescription/DynamicList/Planner/Chart).
    for attr in root.iter():
        if _local_name(attr.tag) != 'Attribute':
            continue
        for s in list(attr):
            if _local_name(s.tag) != 'Settings':
                continue
            st = _attr(s, 'type', NS_XSI)
            if st and not re.search(r'TypeDescription$', st) and not re.search(r'DynamicList$', st) and not re.search(r'Planner$', st) and not re.search(r'd4p1:(Gantt)?Chart$', st):
                fail_ring3("Attribute>Settings типа '%s' (design-time конфигурация, напр. диаграмма)" % st, "Attribute/Settings")
            elif re.search(r'd4p1:(Gantt)?Chart$', st):
                # Chart/GanttChart с типизированными значениями/осями/точками (d4p1 xsi:type/nil/item).
                chart_uri = NSMAP_DOC.get('d4p1')
                typed = False
                if chart_uri:
                    pref = '{%s}' % chart_uri
                    nil_key = '{%s}nil' % NS_XSI
                    for d in s.iter():
                        if not d.tag.startswith(pref):
                            continue
                        if _XSI_TYPE in d.attrib or nil_key in d.attrib or _local_name(d.tag) == 'item':
                            typed = True
                            break
                if typed:
                    fail_ring3("Attribute>Settings %s с точками/осями (типизированные значения/d4p1-ML)" % st, "Attribute/Settings")


# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

def main():
    global ROOT, NSMAP_DOC, OUTPUT_DIR, OUTPUT_BASENAME, QUERY_FILES_ACCUMULATOR, QUERY_FILE_NAMES_USED
    parser = argparse.ArgumentParser(description='Decompile 1C managed Form.xml to JSON DSL', allow_abbrev=False)
    parser.add_argument('-FormPath', '-Path', dest='FormPath', type=str, required=True)
    parser.add_argument('-OutputPath', dest='OutputPath', type=str, default=None)
    args = parser.parse_args()

    form_path = args.FormPath
    output_path = args.OutputPath

    # --- 0. Resolve and validate input ---
    if not os.path.exists(form_path):
        sys.stderr.write("Form not found: %s\n" % form_path)
        sys.exit(1)
    form_path = os.path.abspath(form_path)

    # Префикс→URI (для ring3-проверки d4p1-чартов). Первое связывание на префикс.
    NSMAP_DOC = {}
    for _ev, (_pfx, _uri) in ET.iterparse(form_path, events=['start-ns']):
        if _pfx not in NSMAP_DOC:
            NSMAP_DOC[_pfx] = _uri

    # .NET XmlDocument сохраняет литеральные \r\n в InnerText; ET (expat) нормализует CRLF→LF
    # по XML-спеке. Чтобы совпасть с каноном, превращаем \r\n→&#13;\n (символьные ссылки не
    # подлежат EOL-нормализации) в содержимом документа — но только от <Form (в прологе char-ref
    # невалиден). Покрывает многострочные title/tooltip/content/QueryText.
    raw = open(form_path, 'rb').read()
    rs = raw.find(b'<Form')
    re_end = raw.rfind(b'</Form>')
    if rs >= 0 and re_end >= 0:
        end = re_end + len(b'</Form>')
        # Только ВНУТРИ корневого элемента: в прологе/эпилоге char-ref невалиден (хвостовой </Form>\r\n).
        raw = raw[:rs] + raw[rs:end].replace(b'\r\n', b'&#13;\n') + raw[end:]
    root = ET.fromstring(raw)
    ROOT = root

    # Ring 2: not a managed Form
    if _local_name(root.tag) != 'Form':
        sys.stderr.write("form-decompile: корневой элемент <%s> не <Form> — это не управляемая форма.\n" % _local_name(root.tag))
        sys.exit(2)

    # --- Вынос запроса динсписка в .sql рядом с output ---
    QUERY_FILES_ACCUMULATOR = []
    QUERY_FILE_NAMES_USED = {}
    if output_path:
        od = os.path.dirname(output_path)
        if not od:
            od = os.getcwd()
        OUTPUT_DIR = od
        OUTPUT_BASENAME = os.path.splitext(os.path.basename(output_path))[0]

    # --- 1b. Ring-3 scan ---
    _ring3_scan(root, form_path)

    # --- 5. Form-level assembly ---
    dsl = OrderedDict()

    title_node = root.find('lf:Title', NS)
    if title_node is not None:
        t = get_lang_text(title_node)
        if t is not None:
            dsl['title'] = t

    # properties (прямые скаляры под <Form>, PascalCase → camelCase)
    known_form_props = ['AutoTitle', 'ReportResult', 'DetailsData', 'ReportFormType', 'AutoShowState', 'ReportResultViewMode', 'ViewModeApplicationOnSetReportResult', 'WindowOpeningMode', 'CommandBarLocation', 'SaveDataInSettings', 'AutoSaveDataInSettings', 'AutoTime', 'UsePostingMode', 'RepostOnWrite', 'AutoURL', 'AutoFillCheck', 'Customizable', 'EnterKeyBehavior', 'VerticalScroll', 'Width', 'Height', 'Group', 'UseForFoldersAndItems', 'SaveWindowSettings', 'ScalingMode', 'VerticalSpacing', 'VariantAppearance', 'ShowCloseButton', 'HorizontalAlign', 'ChildrenAlign', 'ShowTitle', 'ConversationsRepresentation', 'CollapseItemsByImportanceVariant', 'GroupList', 'ChildItemsWidth', 'VerticalAlign', 'HorizontalSpacing', 'CustomSettingsFolder', 'SettingsStorage', 'Enabled', 'Scale']
    props = OrderedDict()
    for pn in known_form_props:
        v = get_child(root, pn)
        if v is not None:
            camel = pn[0:1].lower() + pn[1:]
            if v == 'true':
                props[camel] = True
            elif v == 'false':
                props[camel] = False
            elif re.match(r'^\d+$', v):
                props[camel] = int(v)
            else:
                props[camel] = v
    # Ссылка на члена формы по id ("N:uuid") в groupList/customSettingsFolder НЕ воспроизводима.
    for ref_key in ('groupList', 'customSettingsFolder'):
        if ref_key in props and re.match(r'^\d+:[0-9a-fA-F]{8}-', _ps_str(props[ref_key])):
            sys.stderr.write("form-decompile: %s = '%s' — ссылка на члена формы по id, не воспроизводима (id переназначаются), опущена. Задайте по имени через form-edit.\n" % (ref_key, props[ref_key]))
            del props[ref_key]
    # AutoTitle при наличии title: компилятор инъектит false (~95%). Зеркалим.
    if 'title' in dsl:
        if 'autoTitle' not in props:
            props['autoTitle'] = ''
        elif props['autoTitle'] is False:
            del props['autoTitle']
    if len(props) > 0:
        dsl['properties'] = props

    # MobileDeviceCommandBarContent (form-level) → список имён
    mdcb = root.find('lf:MobileDeviceCommandBarContent', NS)
    if mdcb is not None:
        names = []
        for it in mdcb.findall('xr:Item', NS):
            v = it.find('xr:Value', NS)
            if v is not None:
                names.append(_text(v))
        if len(names) > 0:
            dsl['mobileCommandBarContent'] = names

    # excludedCommands (form-level <CommandSet>)
    cs_form = root.find('lf:CommandSet', NS)
    if cs_form is not None:
        exc_form = []
        for ec in cs_form.findall('lf:ExcludedCommand', NS):
            exc_form.append(_text(ec))
        if len(exc_form) > 0:
            dsl['excludedCommands'] = exc_form

    # events (form-level) → {Event: handler} напрямую
    ev_form = get_events(root, None)
    if ev_form:
        ev_map = OrderedDict()
        ev_node = root.find('lf:Events', NS)
        for e in ev_node.findall('lf:Event', NS):
            ev_map[_attr(e, 'name')] = _text(e)
        if len(ev_map) > 0:
            dsl['events'] = ev_map

    # elements (+ форменный AutoCommandBar как autoCmdBar-элемент)
    elem_list = []
    elements = decompile_children(root)
    form_has_cmd_bar = test_any_cmd_bar(elements)
    acb = root.find('lf:AutoCommandBar', NS)
    if acb is not None:
        haln = get_child(acb, 'HorizontalAlign')
        acb_autofill = get_child(acb, 'Autofill')
        acb_di = _attr(acb, 'DisplayImportance')
        acb_kids = decompile_children(acb)
        acb_obj = None
        if haln or (acb_autofill == 'false') or acb_kids or acb_di:
            acb_obj = OrderedDict()
            acb_obj['autoCmdBar'] = _attr(acb, 'name')
            if acb_di:
                acb_obj['displayImportance'] = acb_di
            if haln:
                acb_obj['horizontalAlign'] = haln
            if acb_autofill == 'false':
                acb_obj['autofill'] = False
            if acb_kids:
                acb_obj['children'] = acb_kids
        elif form_has_cmd_bar and acb_autofill is None:
            acb_obj = OrderedDict()
            acb_obj['autoCmdBar'] = _attr(acb, 'name')
            acb_obj['autofill'] = True
        if acb_obj is not None:
            elem_list.append(acb_obj)
    if elements:
        for e in elements:
            elem_list.append(e)
    if len(elem_list) > 0:
        dsl['elements'] = elem_list

    # attributes
    attrs_node = root.find('lf:Attributes', NS)
    if attrs_node is not None:
        attrs = []
        # Подавление авто-main (эвристика 11b.3): нет <MainAttribute> И ровно 1 объектный реквизит.
        all_attr_nodes = attrs_node.findall('lf:Attribute', NS)
        any_main_attr = False
        obj_like_nodes = []
        for an in all_attr_nodes:
            if get_child(an, 'MainAttribute') == 'true':
                any_main_attr = True
            atype = decompile_type(an.find('lf:Type', NS))
            if test_is_object_like_type_dec(_ps_str(atype)):
                obj_like_nodes.append(an)
        suppress_main_name = _attr(obj_like_nodes[0], 'name') if (not any_main_attr and len(obj_like_nodes) == 1) else None
        for a in all_attr_nodes:
            ao = OrderedDict()
            ao['name'] = _attr(a, 'name')
            ty = decompile_type(a.find('lf:Type', NS))
            if ty:
                ao['type'] = ty
            # valueType: <Settings xsi:type="v8:TypeDescription">; Planner/Chart — отдельно.
            set_node = a.find('lf:Settings', NS)
            if set_node is not None and re.search(r'TypeDescription$', _attr(set_node, 'type', NS_XSI)):
                vt = decompile_type(set_node)
                ao['valueType'] = vt if vt else ''
            elif set_node is not None and re.search(r'Planner$', _attr(set_node, 'type', NS_XSI)):
                ao['planner'] = build_planner_settings(set_node)
            elif set_node is not None and re.search(r'd4p1:(Gantt)?Chart$', _attr(set_node, 'type', NS_XSI)):
                ao['chart'] = build_chart_settings(set_node)
            if get_child(a, 'MainAttribute') == 'true':
                ao['main'] = True
            elif suppress_main_name and ao['name'] == suppress_main_name:
                ao['main'] = False
            vw = decompile_xr_flag(a, 'View')
            if vw is not None:
                ao['view'] = vw
            ed = decompile_xr_flag(a, 'Edit')
            if ed is not None:
                ao['edit'] = ed
            is_main = (ao.get('main') is True)
            t_node = a.find('lf:Title', NS)
            if t_node is not None:
                t = get_lang_text_ws(t_node)
                if t is not None:
                    if is_main or not isinstance(t, str) or not _ps_ieq(t, title_from_name(ao['name'])):
                        ao['title'] = t
            elif not is_main:
                ao['title'] = ''
            if get_child(a, 'SavedData') == 'true':
                ao['savedData'] = True
            elif ao.get('main') is True and re.search(r'^(CatalogObject|DocumentObject|ChartOfAccountsObject|ChartOfCalculationTypesObject|ChartOfCharacteristicTypesObject|ExchangePlanObject|BusinessProcessObject|TaskObject)\.|RecordManager\.', _ps_str(ao.get('type'))):
                ao['savedData'] = False
            save_node = a.find('lf:Save', NS)
            if save_node is not None:
                nm = _ps_str(ao['name'])
                flds = [_text(f) for f in save_node.findall('lf:Field', NS)]
                if len(flds) == 1 and flds[0] == nm:
                    ao['save'] = True
                elif len(flds) > 0:
                    stripped = []
                    for f in flds:
                        m = re.match('^' + re.escape(nm) + r'\.([^.]+)$', f)
                        if m and not re.match(r'^\d+/\d+', m.group(1)):
                            stripped.append(m.group(1))
                        else:
                            stripped.append(f)
                    ao['save'] = stripped[0] if len(stripped) == 1 else stripped
            fc = get_child(a, 'FillCheck')
            if fc:
                ao['fillCheck'] = fc
            afo = decompile_functional_options(a)
            if _ps_truthy(afo):
                ao['functionalOptions'] = afo
            cols_node = a.find('lf:Columns', NS)
            if cols_node is not None:
                cols = []
                for c in cols_node.findall('lf:Column', NS):
                    cols.append(decompile_attr_column(c))
                if len(cols) > 0:
                    ao['columns'] = cols
                add_nodes = cols_node.findall('lf:AdditionalColumns', NS)
                if len(add_nodes) > 0:
                    add_list = []
                    for an2 in add_nodes:
                        ac_obj = OrderedDict()
                        ac_obj['table'] = _attr(an2, 'table')
                        ac_cols = []
                        for c in an2.findall('lf:Column', NS):
                            ac_cols.append(decompile_attr_column(c))
                        ac_obj['columns'] = ac_cols
                        add_list.append(ac_obj)
                    ao['additionalColumns'] = add_list
            # UseAlways: префикс "ИмяРеквизита." снимаем; маркер "~" сохраняем (префикс после него).
            ua_node = a.find('lf:UseAlways', NS)
            if ua_node is not None:
                prefix = _ps_str(ao['name']) + '.'
                shorts = []
                for fn in ua_node.findall('lf:Field', NS):
                    t = (_text(fn) or '').strip()
                    if t.startswith('~'):
                        rest = t[1:]
                        if rest.startswith(prefix):
                            rest = rest[len(prefix):]
                        t = '~' + rest
                    elif t.startswith(prefix):
                        t = t[len(prefix):]
                    shorts.append(t)
                if 'columns' in ao:
                    rest_list = []
                    for s in shorts:
                        col = None
                        for cc in ao['columns']:
                            if cc.get('name') == s:
                                col = cc
                                break
                        if col is not None:
                            col['useAlways'] = True
                        else:
                            rest_list.append(s)
                    if len(rest_list) > 0:
                        ao['useAlways'] = rest_list
                elif len(shorts) > 0:
                    ao['useAlways'] = shorts
            # Settings динамического списка (xsi:type=DynamicList)
            set_node = a.find('lf:Settings', NS)
            if set_node is not None and re.search(r'DynamicList$', _attr(set_node, 'type', NS_XSI)):
                so = OrderedDict()
                afaf = get_child(set_node, 'AutoFillAvailableFields')
                if afaf is not None:
                    so['autoFillAvailableFields'] = (afaf == 'true')
                mt = get_child(set_node, 'MainTable')
                if mt:
                    so['mainTable'] = mt
                gifp = get_child(set_node, 'GetInvisibleFieldPresentations')
                if gifp is not None:
                    so['getInvisibleFieldPresentations'] = (gifp == 'true')
                kt = get_child(set_node, 'KeyType')
                if kt:
                    so['keyType'] = kt
                kf_nodes = [_text(x) for x in set_node.findall('lf:KeyField', NS)]
                if len(kf_nodes) > 0:
                    so['keyFields'] = kf_nodes
                asus = get_child(set_node, 'AutoSaveUserSettings')
                if asus is not None:
                    so['autoSaveUserSettings'] = (asus == 'true')
                qt_node = set_node.find('lf:QueryText', NS)
                has_q = bool(qt_node is not None and _text(qt_node))
                if has_q:
                    so['query'] = maybe_externalize_query(_text(qt_node), _ps_str(ao['name']))
                mq_v = get_child(set_node, 'ManualQuery')
                if mq_v is not None:
                    mq_actual = (mq_v == 'true')
                    if mq_actual != has_q:
                        so['manualQuery'] = mq_actual
                if get_child(set_node, 'DynamicDataRead') == 'false':
                    so['dynamicDataRead'] = False
                field_nodes = set_node.findall('lf:Field', NS)
                if len(field_nodes) > 0:
                    fields = []
                    for fn in field_nodes:
                        fo = OrderedDict()
                        fld = get_child(fn, 'field')
                        dp = get_child(fn, 'dataPath')
                        if fld:
                            fo['field'] = fld
                        if has_child(fn, 'dataPath') and dp != fld:
                            fo['dataPath'] = dp
                        f_type_attr = _attr(fn, 'type', NS_XSI)
                        if re.search(r'NestedDataSet$', f_type_attr):
                            fo['nested'] = True
                        elif re.search(r'Folder$', f_type_attr):
                            fo['folder'] = True
                        ftn = fn.find('dcssch:title', NS)
                        if ftn is not None:
                            t = get_lang_text(ftn)
                            if t is not None:
                                fo['title'] = t
                        fvt = fn.find('dcssch:valueType', NS)
                        if fvt is not None:
                            fvt_val = decompile_type(fvt)
                            if fvt_val:
                                fo['valueType'] = fvt_val
                        fpe = get_child(fn, 'presentationExpression')
                        if fpe is not None and fpe != '':
                            fo['presentationExpression'] = fpe
                        fapp_node = fn.find('dcssch:appearance', NS)
                        if fapp_node is not None:
                            fap = get_settings_appearance(fapp_node)
                            if fap and len(fap) > 0:
                                fo['appearance'] = fap
                        fur_node = fn.find('dcssch:useRestriction', NS)
                        if fur_node is not None:
                            fur = build_restrict_obj(fur_node)
                            if len(fur) > 0:
                                fo['useRestriction'] = fur
                        faur_node = fn.find('dcssch:attributeUseRestriction', NS)
                        if faur_node is not None:
                            faur = build_restrict_obj(faur_node)
                            if len(faur) > 0:
                                fo['attributeUseRestriction'] = faur
                        fip_node = fn.find('dcssch:inputParameters', NS)
                        if fip_node is not None:
                            fip = build_dl_input_parameters(fip_node)
                            if len(fip) > 0:
                                fo['inputParameters'] = fip[0] if len(fip) == 1 else fip   # PS unwrap
                        fields.append(fo)
                    so['fields'] = fields
                calc_nodes = set_node.findall('lf:CalculatedField', NS)
                if len(calc_nodes) > 0:
                    cfs = []
                    for cn in calc_nodes:
                        cfs.append(build_calc_field(cn))
                    so['calculatedFields'] = cfs
                param_nodes = set_node.findall('lf:Parameter', NS)
                if len(param_nodes) > 0:
                    dl_pars = []
                    for pn in param_nodes:
                        dl_pars.append(build_dl_parameter(pn))
                    so['parameters'] = dl_pars
                ls_node = set_node.find('lf:ListSettings', NS)
                if ls_node is not None:
                    f_node = ls_node.find('dcsset:filter', NS)
                    if f_node is not None and f_node.find('dcsset:item', NS) is not None:
                        flt = []
                        for fc in f_node.findall('dcsset:item', NS):
                            bi = build_filter_item(fc, 'settings/filter')
                            if bi is not None:
                                flt.append(bi)
                        if len(flt) > 0:
                            so['filter'] = flt
                    o_node = ls_node.find('dcsset:order', NS)
                    if o_node is not None and o_node.find('dcsset:item', NS) is not None:
                        ordr = build_order(o_node, 'settings/order')
                        if len(ordr) > 0:
                            so['order'] = ordr
                    ca_node = ls_node.find('dcsset:conditionalAppearance', NS)
                    if ca_node is not None and ca_node.find('dcsset:item', NS) is not None:
                        ca = build_conditional_appearance(ca_node, 'settings/conditionalAppearance')
                        if len(ca) > 0:
                            so['conditionalAppearance'] = ca
                    dp_node = ls_node.find('dcsset:dataParameters', NS)
                    if dp_node is not None and dp_node.find('dcscor:item', NS) is not None:
                        dp = build_form_data_parameters(dp_node)
                        if len(dp) > 0:
                            so['dataParameters'] = dp
                    grp_item_node = ls_node.find('dcsset:item', NS)
                    grouping = None
                    if grp_item_node is not None:
                        grouping = build_list_grouping(grp_item_node)
                    if grouping is not None:
                        so['grouping'] = grouping
                    ls_shape = get_list_settings_shape(ls_node, grouping is not None)
                    if ls_shape is not None:
                        so['listSettings'] = ls_shape
                if len(so) > 0:
                    ao['settings'] = so
            attrs.append(ao)
        if len(attrs) > 0:
            dsl['attributes'] = attrs

    # conditionalAppearance формы (<ConditionalAppearance> — последний child <Attributes>)
    if attrs_node is not None:
        ca_node = attrs_node.find('lf:ConditionalAppearance', NS)
        if ca_node is not None:
            ca = build_conditional_appearance(ca_node, 'form/conditionalAppearance')
            if len(ca) > 0:
                dsl['conditionalAppearance'] = ca

    # parameters
    pars_node = root.find('lf:Parameters', NS)
    if pars_node is not None:
        pars = []
        for p in pars_node.findall('lf:Parameter', NS):
            po = OrderedDict()
            po['name'] = _attr(p, 'name')
            ty = decompile_type(p.find('lf:Type', NS))
            if ty:
                po['type'] = ty
            if get_child(p, 'KeyParameter') == 'true':
                po['key'] = True
            pars.append(po)
        if len(pars) > 0:
            dsl['parameters'] = pars

    # commands
    cmds_node = root.find('lf:Commands', NS)
    if cmds_node is not None:
        cmds = []
        for c in cmds_node.findall('lf:Command', NS):
            co = OrderedDict()
            co['name'] = _attr(c, 'name')
            act = get_child(c, 'Action')
            if act:
                co['action'] = act
            if get_child(c, 'ModifiesSavedData') == 'true':
                co['modifiesSavedData'] = True
            t_node = c.find('lf:Title', NS)
            if t_node is not None:
                t = get_lang_text(t_node)
                if t is not None:
                    co['title'] = t
            else:
                co['title'] = ''
            tt_node = c.find('lf:ToolTip', NS)
            if tt_node is not None:
                t = get_lang_text(tt_node)
                if t is not None:
                    co['tooltip'] = t
            us = decompile_xr_flag(c, 'Use')
            if us is not None:
                co['use'] = us
            cfo = decompile_functional_options(c)
            if _ps_truthy(cfo):
                co['functionalOptions'] = cfo
            cru = get_child(c, 'CurrentRowUse')
            if cru:
                co['currentRowUse'] = cru
            ate = get_child(c, 'AssociatedTableElementId')
            if ate:
                co['table'] = ate
            sc = get_child(c, 'Shortcut')
            if sc:
                co['shortcut'] = sc
            set_command_picture(co, c)
            rep = get_child(c, 'Representation')
            if rep:
                co['representation'] = rep
            cmds.append(co)
        if len(cmds) > 0:
            dsl['commands'] = cmds

    # commandInterface (форменный <CommandInterface>)
    ci = decompile_command_interface()
    if ci is not None:
        dsl['commandInterface'] = ci

    # --- 6. Output ---
    js = convert_to_compact_json(dsl)
    if output_path:
        with open(output_path, 'w', encoding='utf-8', newline='') as f:
            f.write(js)
        save_query_files()
        sys.stdout.write("form-decompile: %s\n" % output_path)
    else:
        sys.stdout.write(js + "\n")


def _local_name(tag):
    """{uri}local → local."""
    return tag.rsplit('}', 1)[-1] if '}' in tag else tag


if __name__ == '__main__':
    main()
