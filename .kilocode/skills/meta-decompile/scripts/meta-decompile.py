#!/usr/bin/env python3
# meta-decompile v0.54 — XML объекта метаданных 1С → JSON-черновик формата meta-compile
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
#
# Зеркало meta-decompile.ps1 (КАНОН). Структура 1:1 — те же имена функций, порядок, комментарии.
# Изменения вносить СНАЧАЛА в .ps1, затем переносить сюда. lxml.etree — для полного XPath 1.0
# (SelectSingleNode/union/предикаты), как XmlNamespaceManager в .ps1.
#
# Поддержаны: Catalog, ExchangePlan, ChartOfCharacteristicTypes, ChartOfAccounts, ChartOfCalculationTypes, Document,
# InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister, BusinessProcess, Task, Enum, ...
# Инверс meta-compile (omit-on-default: ключ эмитим только когда значение в XML отличается от умолчания
# компилятора). Неподдерживаемый тип / не-MetaDataObject root → exit 3 (ring3, как form-decompile).

import argparse
import os
import re
import sys
from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# --- Namespaces (зеркало XmlNamespaceManager) ---
NS_MD = "http://v8.1c.ru/8.3/MDClasses"
NS_V8 = "http://v8.1c.ru/8.1/data/core"
NS_XR = "http://v8.1c.ru/8.3/xcf/readable"
NS_XSI = "http://www.w3.org/2001/XMLSchema-instance"
NS_APP = "http://v8.1c.ru/8.2/managed-application/core"
NS = {'md': NS_MD, 'v8': NS_V8, 'xr': NS_XR, 'xsi': NS_XSI, 'app': NS_APP}

# Скрипт-скоуп состояние (зеркало $script:* / module-level $props/$dsl/$objType канона). Ставятся в main().
props = None
obj_node = None
obj_type = None
obj_name = None
dsl = None
object_path = None


# --- XML-обёртки (зеркало SelectSingleNode/SelectNodes/GetAttribute/InnerText) ---
def _single(node, xpath):
    if node is None:
        return None
    r = node.xpath(xpath, namespaces=NS)
    return r[0] if r else None


def _nodes(node, xpath):
    if node is None:
        return []
    return node.xpath(xpath, namespaces=NS)


def _text(node):
    """InnerText — конкатенация всего текста-потомка (PreserveWhitespace=true у lxml по умолчанию)."""
    if node is None:
        return None
    return ''.join(node.itertext())


def _attr(node, name, ns=None):
    """GetAttribute(name[, ns]) — .NET возвращает '' для отсутствующего атрибута, lxml → None."""
    if node is None:
        return ''
    key = ('{%s}%s' % (ns, name)) if ns else name
    v = node.get(key)
    return v if v is not None else ''


def _localname(el):
    t = el.tag
    if not isinstance(t, str):
        return ''
    return t.split('}', 1)[1] if '}' in t else t


# --- JSON-эмиттер (контроль порядка/массивов/кириллицы) ---
def _json_num(n):
    """Зеркало "$node" для int/long/double."""
    if isinstance(n, bool):
        return 'true' if n else 'false'
    if isinstance(n, int):
        return str(n)
    r = repr(float(n))
    if r.endswith('.0'):
        r = r[:-2]
    return r


def convert_to_compact_json(node, depth=0):
    pad = "  " * depth
    pad1 = "  " * (depth + 1)
    if node is None:
        return "null"
    if isinstance(node, bool):
        return "true" if node else "false"
    if isinstance(node, (int, float)):
        return _json_num(node)
    if isinstance(node, dict):
        if len(node) == 0:
            return "{}"
        items = []
        for k in node.keys():
            items.append("%s%s: %s" % (pad1, quote_json(str(k)), convert_to_compact_json(node[k], depth + 1)))
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(node, list):
        if len(node) == 0:
            return "[]"
        # Массив скаляров-строк — компактно в строку; массив объектов — по строкам.
        all_scalar = True
        for e in node:
            if isinstance(e, (dict, list)):
                all_scalar = False
                break
        if all_scalar:
            items = [convert_to_compact_json(e, depth + 1) for e in node]
            return "[" + ", ".join(items) + "]"
        items = ["%s%s" % (pad1, convert_to_compact_json(e, depth + 1)) for e in node]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return quote_json(str(node))


def quote_json(s):
    sb = ['"']
    for ch in s:
        if ch == '"':
            sb.append('\\"')
        elif ch == '\\':
            sb.append('\\\\')
        elif ch == '\n':
            sb.append('\\n')
        elif ch == '\r':
            sb.append('\\r')
        elif ch == '\t':
            sb.append('\\t')
        else:
            if ord(ch) < 32:
                sb.append('\\u%04x' % ord(ch))
            else:
                sb.append(ch)
    sb.append('"')
    return ''.join(sb)


# --- Сравнение регистров (зеркало PS -ne / -cne) ---
def ne_cs(a, b):
    """PS -cne на строках (регистрочувствительно). True когда различаются с учётом регистра.
    Зеркало компилятора: авто-синоним/описание опускаем только при ТОЧНОМ совпадении со split_camel_words."""
    return (a if a is not None else '') != (b if b is not None else '')


def split_camel_words(name):
    """Авто-синоним: точное зеркало Split-CamelCase из meta-compile (split_camel_case, HE-эвристика).
    ВАЖНО: логика должна совпадать байт-в-байт с компилятором, иначе ложные «синоним==авто» → диффы."""
    if not name:
        return name
    result = re.sub(r'([а-яё])([А-ЯЁ])', r'\1 \2', name)
    result = re.sub(r'([a-z])([A-Z])', r'\1 \2', result)
    # HE: сохраняем прогон заглавных >=2, если сразу за ним НЕ буква (пробел/цифра/спецсимвол/конец);
    # предлоги/бренды перед буквой → лоуэркейз. Первый символ — как есть.
    if len(result) > 1:
        chars = list(result)
        n = len(chars)
        keep = [False] * n
        i = 0
        while i < n:
            if chars[i].isupper():
                j = i
                while j < n and chars[j].isupper():
                    j += 1
                after_boundary = (j == n) or (not chars[j].isalpha())
                if j - i >= 2 and after_boundary:
                    for k in range(i, j):
                        keep[k] = True
                i = j
            else:
                i += 1
        out = []
        for idx, c in enumerate(chars):
            if idx == 0 or keep[idx]:
                out.append(c)
            elif c.isupper():
                out.append(c.lower())
            else:
                out.append(c)
        result = ''.join(out)
    return result


def P(tag):
    n = _single(props, "md:" + tag)
    return _text(n) if n is not None else None


# --- Synonym (ru) ---
def get_ml_ru(node):
    if node is None:
        return None
    it = _single(node, "v8:item[v8:lang='ru']/v8:content")
    if it is not None:
        return _text(it)
    return None


def get_ml_value(node):
    """ML-значение → строка (если единственный item ru) ЛИБО dict{lang:content} (мультиязычно, порядок из XML).
    None если контента нет. Компактная строка для ru-only, объект для мультиязычных."""
    if node is None:
        return None
    items = _nodes(node, 'v8:item')
    if len(items) == 0:
        return None
    if len(items) == 1:
        lang = _text(_single(items[0], 'v8:lang'))
        content = _text(_single(items[0], 'v8:content'))
        # Единственный ru-item: пустое содержимое ≡ отсутствие значения → None (иначе tooltip:"" ≠ self-close).
        if lang == 'ru':
            return None if content == '' else content
    o = {}
    for it in items:
        l = _text(_single(it, 'v8:lang'))
        c = _text(_single(it, 'v8:content'))
        o[l] = c
    return o


# --- Тип реквизита: <Type> → shorthand-строка ---
def strip_ns_prefix(s):
    if ':' in s:
        return s.split(':', 1)[1]
    return s


def get_type_shorthand(type_node):
    if type_node is None:
        return ""
    parts = []
    children = [c for c in type_node if isinstance(c.tag, str)]
    for i in range(len(children)):
        c = children[i]
        ln = _localname(c)
        if ln == 'Type':
            raw = _text(c).strip()
            nxt = children[i + 1] if i + 1 < len(children) else None
            if re.search(r'(^|:)boolean$', raw, re.I):
                parts.append('Boolean')
            elif re.search(r'(^|:)string$', raw, re.I):
                length = '10'
                al = ''
                sq = nxt if (nxt is not None and _localname(nxt) == 'StringQualifiers') else _single(type_node, 'v8:StringQualifiers')
                if sq is not None:
                    l = _single(sq, 'v8:Length')
                    if l is not None:
                        length = _text(l)
                    aln = _single(sq, 'v8:AllowedLength')
                    if aln is not None and _text(aln) == 'Fixed':
                        al = ',fixed'
                parts.append("String(%s%s)" % (length, al))
            elif re.search(r'(^|:)decimal$', raw, re.I):
                d = '10'
                f = '0'
                sign = ''
                nq = nxt if (nxt is not None and _localname(nxt) == 'NumberQualifiers') else _single(type_node, 'v8:NumberQualifiers')
                if nq is not None:
                    dn = _single(nq, 'v8:Digits')
                    if dn is not None:
                        d = _text(dn)
                    fn = _single(nq, 'v8:FractionDigits')
                    if fn is not None:
                        f = _text(fn)
                    sn = _single(nq, 'v8:AllowedSign')
                    if sn is not None and _text(sn) == 'Nonnegative':
                        sign = ',nonneg'
                parts.append("Number(%s,%s%s)" % (d, f, sign))
            elif re.search(r'(^|:)dateTime$', raw, re.I):
                fr = 'DateTime'
                dq = nxt if (nxt is not None and _localname(nxt) == 'DateQualifiers') else _single(type_node, 'v8:DateQualifiers')
                if dq is not None:
                    dn = _single(dq, 'v8:DateFractions')
                    if dn is not None:
                        fr = _text(dn)
                parts.append(fr)   # Date | DateTime
            elif re.search(r'(^|:)base64Binary$', raw, re.I):
                parts.append('ValueStorage')
            else:
                parts.append(strip_ns_prefix(raw))   # cfg:CatalogRef.X → CatalogRef.X
        elif ln == 'TypeSet':
            parts.append(strip_ns_prefix(_text(c).strip()))   # cfg:DefinedType.X → DefinedType.X
    return ' + '.join(parts)


# Скалярное значение параметра выбора (<Value xsi:type=...>) → JSON-значение (bool/число/строка).
def convert_ch_scalar_node(vN):
    xt = _attr(vN, 'type', NS_XSI)
    txt = _text(vN)
    if re.search(r'boolean$', xt, re.I):
        return txt == 'true'
    if re.search(r'decimal$', xt, re.I):
        if re.match(r'^-?\d+$', txt):
            return int(txt)
        return float(txt)
    return txt


# app:value (тип прямо на узле) → значение ЛИБО список (v8:FixedArray с детьми v8:Value).
def get_choice_param_value(val_node):
    xt = _attr(val_node, 'type', NS_XSI)
    if re.search(r'FixedArray$', xt, re.I):
        arr = []
        for sub in _nodes(val_node, 'v8:Value'):
            arr.append(convert_ch_scalar_node(sub))
        return arr
    return convert_ch_scalar_node(val_node)


# <ChoiceParameterLinks> → [{name,dataPath,valueChange?}] | строки "name=dataPath". tag: 'md:...' | 'xr:...'.
def parse_choice_parameter_links(parent, tag):
    node = _single(parent, tag)
    if node is None:
        return None
    links = _nodes(node, 'xr:Link')
    if len(links) == 0:
        return None
    arr = []
    for lk in links:
        l_name = _text(_single(lk, 'xr:Name'))
        l_dp = _text(_single(lk, 'xr:DataPath'))
        vc_n = _single(lk, 'xr:ValueChange')
        vcv = _text(vc_n) if vc_n is not None else 'Clear'
        if vcv == 'Clear':
            arr.append("%s=%s" % (l_name, l_dp))
        else:
            arr.append({'name': l_name, 'dataPath': l_dp, 'valueChange': vcv})
    # PS-трап: `return $arr` БЕЗ унарной запятой → одноэлементный ArrayList разворачивается в скаляр
    # (в отличие от Get-ChoiceParamValue с `,$arr`). Зеркалим: len==1 → голый элемент.
    return arr[0] if len(arr) == 1 else arr


# <ChoiceParameters> → [{name,value?}]. tag: 'md:...' | 'xr:...'.
def parse_choice_parameters(parent, tag):
    node = _single(parent, tag)
    if node is None:
        return None
    items = _nodes(node, 'app:item')
    if len(items) == 0:
        return None
    arr = []
    for it in items:
        p_name = _attr(it, 'name')
        val_n = _single(it, 'app:value')
        nil_attr = _attr(val_n, 'nil', NS_XSI) if val_n is not None else ''
        if val_n is None or nil_attr == 'true':
            arr.append({'name': p_name})
        else:
            o = {'name': p_name}
            o['value'] = get_choice_param_value(val_n)
            arr.append(o)
    # PS-трап (как выше): одноэлементный ArrayList разворачивается в скаляр при `return $arr`.
    return arr[0] if len(arr) == 1 else arr


# --- Реквизит → DSL: shorthand-строка "Имя: Тип | флаги" ЛИБО object-форма при кастомном синониме. ---
def attr_to_dsl(attr_node):
    ap = _single(attr_node, 'md:Properties')
    nm = _text(_single(ap, 'md:Name'))
    ts = get_type_shorthand(_single(ap, 'md:Type'))
    flags = []
    fc = _single(ap, 'md:FillChecking')
    if fc is not None and _text(fc) == 'ShowError':
        flags.append('req')
    ix = _single(ap, 'md:Indexing')
    if ix is not None:
        ixt = _text(ix)
        if ixt == 'Index':
            flags.append('index')
        elif ixt == 'IndexWithAdditionalOrder':
            flags.append('indexAdditional')
    ml = _single(ap, 'md:MultiLine')
    if ml is not None and _text(ml) == 'true':
        flags.append('multiline')

    # Синоним/подсказка (строка ru-only ИЛИ {ru,en}).
    syn_node = _single(ap, 'md:Synonym')
    syn_val = get_ml_value(syn_node)
    syn_custom = False
    # Пустой <Synonym/> (узел есть, значения нет) ≠ авто-синоним из имени → явный пустой (synonym:"").
    syn_empty = (syn_node is not None and syn_val is None)
    if isinstance(syn_val, str):
        if ne_cs(syn_val, split_camel_words(nm)):
            syn_custom = True
    elif syn_val is not None:
        syn_custom = True   # {ru,en} = всегда кастом
    tt_val = get_ml_value(_single(ap, 'md:ToolTip'))

    # Extra-свойства реквизита (omit-on-default). Наличие любого → object-форма.
    def en(tag):
        n = _single(ap, "md:" + tag)
        return _text(n) if n is not None else None

    extra = {}
    v = en('Comment')
    if v:
        extra['comment'] = v
    v = en('FullTextSearch')
    if v and v != 'Use':
        extra['fullTextSearch'] = v
    v = en('FillFromFillingValue')
    if v == 'true':
        extra['fillFromFillingValue'] = True
    v = en('CreateOnInput')
    if v and v != 'Auto':
        extra['createOnInput'] = v
    v = en('QuickChoice')
    if v and v != 'Auto':
        extra['quickChoice'] = v
    v = en('DataHistory')
    if v and v != 'Use':
        extra['dataHistory'] = v
    v = en('Use')
    if v and v != 'ForItem':
        extra['use'] = v
    v = en('PasswordMode')
    if v == 'true':
        extra['passwordMode'] = True
    v = en('Mask')
    if v:
        extra['mask'] = v
    v = en('ChoiceHistoryOnInput')
    if v and v != 'Auto':
        extra['choiceHistoryOnInput'] = v
    v = en('FillChecking')
    if v == 'ShowWarning':
        extra['fillChecking'] = 'ShowWarning'
    v = en('ExtendedEdit')
    if v == 'true':
        extra['extendedEdit'] = True
    v = en('MarkNegatives')
    if v == 'true':
        extra['markNegatives'] = True
    v = en('ChoiceFoldersAndItems')
    if v and v != 'Items':
        extra['choiceFoldersAndItems'] = v
    v = en('ChoiceForm')
    if v:
        extra['choiceForm'] = v
    # Регистро-специфика измерения (теги присутствуют только у Dimension → безвредно для прочих).
    v = en('Master')
    if v == 'true':
        extra['master'] = True
    v = en('MainFilter')
    if v == 'true':
        extra['mainFilter'] = True
    v = en('DenyIncompleteValues')
    if v == 'true':
        extra['denyIncompleteValues'] = True
    v = en('UseInTotals')
    if v == 'false':
        extra['useInTotals'] = False   # дефолт true → захват при false
    v = en('BaseDimension')
    if v == 'true':
        extra['baseDimension'] = True
    v = en('ScheduleLink')
    if v:
        extra['scheduleLink'] = v   # ссылка на измерение графика (пустой → пропуск)
    v = en('Balance')
    if v == 'true':
        extra['balance'] = True
    v = en('AccountingFlag')
    if v:
        extra['accountingFlag'] = v   # ссылка на признак учёта ПС (пустой → пропуск)
    v = en('ExtDimensionAccountingFlag')
    if v:
        extra['extDimensionAccountingFlag'] = v
    v = en('AddressingDimension')
    if v:
        extra['addressingDimension'] = v   # ссылка на измерение регистра исполнителей
    # MinValue/MaxValue — граница диапазона (omit при nil). Тип сохраняем: xs:string→строка, xs:decimal→число.
    for mm in ('MinValue', 'MaxValue'):
        mn = _single(ap, "md:" + mm)
        if mn is None:
            continue
        if _attr(mn, 'nil', NS_XSI) == 'true':
            continue
        key = 'minValue' if mm == 'MinValue' else 'maxValue'
        xt = _attr(mn, 'type', NS_XSI)
        txt = _text(mn)
        if re.search(r'decimal|int|double|float', xt, re.I):
            extra[key] = int(txt) if re.match(r'^-?\d+$', txt) else float(txt)
        else:
            extra[key] = txt
    fmt_v = get_ml_value(_single(ap, 'md:Format'))
    if fmt_v is not None:
        extra['format'] = fmt_v
    efmt_v = get_ml_value(_single(ap, 'md:EditFormat'))
    if efmt_v is not None:
        extra['editFormat'] = efmt_v

    # FillValue (значение заполнения). Форма по умолчанию зависит от типа реквизита: String→typed-empty,
    # Number→zero, всё остальное→nil. Эмитим `fillValue` только при отклонении от дефолта (§4.2 spec).
    fv_node = _single(ap, 'md:FillValue')
    if fv_node is not None:
        fcat = 'Other'
        if re.search(r'\+', ts):
            fcat = 'Other'
        elif re.search(r'^Boolean', ts):
            fcat = 'Boolean'
        elif re.search(r'^String', ts):
            fcat = 'String'
        elif re.search(r'^Number', ts):
            fcat = 'Number'
        elif re.search(r'^(Date|DateTime)', ts):
            fcat = 'Date'
        nil_attr = _attr(fv_node, 'nil', NS_XSI)
        xsi_t = _attr(fv_node, 'type', NS_XSI)
        fv_text = _text(fv_node)
        if nil_attr == 'true':
            if fcat == 'String' or fcat == 'Number':
                extra['fillValue'] = None   # nil-override
            # иначе nil — это дефолт → пропускаем
        elif re.search(r'boolean$', xsi_t, re.I):
            extra['fillValue'] = (fv_text == 'true')
        elif re.search(r'decimal$', xsi_t, re.I):
            # Захватываем как ЧИСЛО (не строку): на составном типе компилятор берёт xsi-тип из JSON-значения.
            if not (fcat == 'Number' and (fv_text == '0' or fv_text == '')):
                extra['fillValue'] = int(fv_text) if re.match(r'^-?\d+$', fv_text) else float(fv_text)
        elif re.search(r'string$', xsi_t, re.I):
            if not (fcat == 'String' and fv_text == ''):
                extra['fillValue'] = fv_text
        elif re.search(r'dateTime$', xsi_t, re.I):
            extra['fillValue'] = fv_text
        elif re.search(r'DesignTimeRef$', xsi_t, re.I):
            # Пустой DTR ≠ nil/xs:string → маркер emptyRef (иначе тип терялся в xs:string).
            if fv_text == '':
                extra['fillValue'] = {'emptyRef': True}
            else:
                extra['fillValue'] = fv_text

    # LinkByType (связь по типу): DataPath + LinkItem. Пусто → пропускаем. linkItem=0 → компактно строкой.
    lbt_node = _single(ap, 'md:LinkByType')
    if lbt_node is not None:
        dp_n = _single(lbt_node, 'xr:DataPath')
        if dp_n is not None and _text(dp_n):
            li_n = _single(lbt_node, 'xr:LinkItem')
            li = int(_text(li_n)) if (li_n is not None and _text(li_n)) else 0
            if li == 0:
                extra['linkByType'] = _text(dp_n)
            else:
                extra['linkByType'] = {'dataPath': _text(dp_n), 'linkItem': li}

    cpl_arr = parse_choice_parameter_links(ap, 'md:ChoiceParameterLinks')
    if cpl_arr is not None:
        extra['choiceParameterLinks'] = cpl_arr
    cp_arr = parse_choice_parameters(ap, 'md:ChoiceParameters')
    if cp_arr is not None:
        extra['choiceParameters'] = cp_arr

    # Пустой <Type/> (реквизит без типа) → ts=''. Отличаем от «дефолтного» отсутствия: явный type:''.
    type_empty = (ts == '')
    if syn_custom or syn_empty or (tt_val is not None) or len(extra) > 0 or type_empty:
        o = {'name': nm}
        if ts:
            o['type'] = ts
        elif type_empty:
            o['type'] = ''
        if syn_custom:
            o['synonym'] = syn_val
        elif syn_empty:
            o['synonym'] = ''
        if tt_val is not None:
            o['tooltip'] = tt_val
        for k in extra:
            o[k] = extra[k]
        if len(flags) > 0:
            o['flags'] = list(flags)
        return o
    head = ("%s: %s" % (nm, ts)) if ts else nm
    if len(flags) > 0:
        return head + " | " + ", ".join(flags)
    return head


# --- Свойства (omit-on-default). ---
def add_bool_prop(key, tag, default):
    v = P(tag)
    if v is not None:
        b = (v == 'true')
        if b != default:
            dsl[key] = b


def add_enum_prop(key, tag, default):
    v = P(tag)
    if v is not None and v != '' and v != default:
        dsl[key] = v


def add_int_prop(key, tag, default):
    v = P(tag)
    if v is not None and v != '':
        iv = int(v)
        if iv != default:
            dsl[key] = iv


# Общий захват структурного <Picture> (зеркало Emit-CommandPicture). Пишет в tgt ключи picture/loadTransparent.
def get_picture_to_dsl(props_node, tgt):
    ref_n = _single(props_node, 'md:Picture/xr:Ref')
    abs_n = _single(props_node, 'md:Picture/xr:Abs')
    if ref_n is not None or abs_n is not None:
        psrc = _text(ref_n) if ref_n is not None else ("abs:" + _text(abs_n))
        lt_n = _single(props_node, 'md:Picture/xr:LoadTransparent')
        lt_false = (lt_n is not None and _text(lt_n) == 'false')
        tpx_n = _single(props_node, 'md:Picture/xr:TransparentPixel')
        if tpx_n is not None:
            po = {'src': psrc}
            if lt_false:
                po['loadTransparent'] = False
            po['transparentPixel'] = {'x': int(_attr(tpx_n, 'x')), 'y': int(_attr(tpx_n, 'y'))}
            tgt['picture'] = po
        else:
            tgt['picture'] = psrc
            if lt_false:
                tgt['loadTransparent'] = False


# Короткая форма поля: <Type>.<Name>.StandardAttribute.X / .Attribute.X → StandardAttribute.X / Attribute.X
def short_field(full):
    m = re.search(r'\.(StandardAttribute|Attribute)\.(.+)$', full)
    if m:
        return "%s.%s" % (m.group(1), m.group(2))
    return full


def add_form_ref(key, tag):
    v = P(tag)
    if v:
        dsl[key] = v


# --- Characteristics: короткая форма поля bare/partial. ---
def shorten_char_field(full, frm):
    if full.startswith(frm + "."):
        rest = full[len(frm) + 1:]
        m = re.match(r'^StandardAttribute\.(Ref|Parent|Owner)$', rest)
        if m:
            return m.group(1)   # ссылочные станд. → голое
        m = re.match(r'^Attribute\.(.+)$', rest)
        if m:
            return m.group(1)   # кастом → голое
        return rest   # прочие StandardAttribute.X / Dimension.X / Resource.X → частичное
    return full


# --- Предопределённые (local-name xpath, без ns-менеджера) ---
def _lx1(el, xp):
    r = el.xpath(xp)
    return r[0] if r else None


def _lxn(el, xp):
    return el.xpath(xp)


def predef_item_to_dsl(item_el):
    name = _text(_lx1(item_el, "*[local-name()='Name']"))
    code_el = _lx1(item_el, "*[local-name()='Code']")
    code = _text(code_el) if (code_el is not None and _text(code_el)) else ''
    desc_el = _lx1(item_el, "*[local-name()='Description']")
    desc = _text(desc_el) if desc_el is not None else ''
    folder_el = _lx1(item_el, "*[local-name()='IsFolder']")
    is_folder = (folder_el is not None and _text(folder_el) == 'true')
    child_container = _lx1(item_el, "*[local-name()='ChildItems']")
    kids = _lxn(child_container, "*[local-name()='Item']") if child_container is not None else []
    # Type — тип значения предопределённой характеристики (ПВХ). Наличие узла → object-форма с ключом type.
    type_el = _lx1(item_el, "*[local-name()='Type']")
    type_str = get_type_shorthand(type_el) if type_el is not None else None
    auto = split_camel_words(name)

    # Компактная строка для плоских: без узла Type (Catalog) ИЛИ с непустым типом → "(Код) Имя [Наим]: Тип".
    if (not is_folder) and len(kids) == 0 and (type_str is None or type_str != ''):
        s = ("(%s) %s" % (code, name)) if code else name
        if desc == '':
            s = s + " []"
        elif ne_cs(desc, auto):
            s = s + (" [%s]" % desc)
        if type_str:
            s = "%s: %s" % (s, type_str)
        return s
    # Группа/иерархия/с типом → объект.
    o = {'name': name}
    if code:
        o['code'] = code
    if desc == '':
        o['description'] = ''
    elif ne_cs(desc, auto):
        o['description'] = desc
    if type_str is not None:
        o['type'] = type_str
    if is_folder:
        o['isFolder'] = True
    if len(kids) > 0:
        sub = []
        for k in kids:
            sub.append(predef_item_to_dsl(k))
        o['childItems'] = sub
    return o


def predef_account_to_dsl(item_el):
    name = _text(_lx1(item_el, "*[local-name()='Name']"))
    code_el = _lx1(item_el, "*[local-name()='Code']")
    code = _text(code_el) if (code_el is not None and _text(code_el)) else ''
    desc_el = _lx1(item_el, "*[local-name()='Description']")
    desc = _text(desc_el) if desc_el is not None else ''
    at_el = _lx1(item_el, "*[local-name()='AccountType']")
    acct_type = _text(at_el) if at_el is not None else 'ActivePassive'
    off_el = _lx1(item_el, "*[local-name()='OffBalance']")
    off = (off_el is not None and _text(off_el) == 'true')
    ord_el = _lx1(item_el, "*[local-name()='Order']")
    order = _text(ord_el) if ord_el is not None else ''
    auto = split_camel_words(name)
    # TRUE-флаги (leaf после последней точки в ref).
    true_flags = []
    for fl in _lxn(item_el, "*[local-name()='AccountingFlags']/*[local-name()='Flag']"):
        if _text(fl) == 'true':
            r = _attr(fl, 'ref')
            true_flags.append(r.split('.')[-1])
    # ExtDimensionTypes → subconto. Короткая запись "Тип | Признак1, Признак2".
    edt_pfx = (dsl['extDimensionTypes'] + ".") if dsl.get('extDimensionTypes') else None
    subconto = []
    for edt in _lxn(item_el, "*[local-name()='ExtDimensionTypes']/*[local-name()='ExtDimensionType']"):
        sc_t = _attr(edt, 'name')
        if edt_pfx and sc_t.startswith(edt_pfx):
            sc_t = sc_t[len(edt_pfx):]
        t_el = _lx1(edt, "*[local-name()='Turnover']")
        sc_flags_out = []
        if t_el is not None and _text(t_el) == 'true':
            sc_flags_out.append('Turnover')
        for fl in _lxn(edt, "*[local-name()='AccountingFlags']/*[local-name()='Flag']"):
            if _text(fl) == 'true':
                r = _attr(fl, 'ref')
                sc_flags_out.append(r.split('.')[-1])
        if len(sc_flags_out) > 0:
            subconto.append(sc_t + " | " + ", ".join(sc_flags_out))
        else:
            subconto.append(sc_t)
    child_container = _lx1(item_el, "*[local-name()='ChildItems']")
    kids = _lxn(child_container, "*[local-name()='Item']") if child_container is not None else []

    o = {'name': name}
    if code:
        o['code'] = code
    # -cne (регистрочувствительно!): хвостовые аббревиатуры (ОС/НМА) теряли бы регистр при -ne.
    if desc != auto:
        o['description'] = desc
    o['accountType'] = acct_type
    if off:
        o['offBalance'] = True
    o['order'] = order
    if len(true_flags) > 0:
        o['flags'] = list(true_flags)
    if len(subconto) > 0:
        o['subconto'] = subconto
    if len(kids) > 0:
        sub = []
        for k in kids:
            sub.append(predef_account_to_dsl(k))
        o['childItems'] = sub
    return o


def predef_calc_type_to_dsl(item_el):
    name = _text(_lx1(item_el, "*[local-name()='Name']"))
    code_el = _lx1(item_el, "*[local-name()='Code']")
    code = _text(code_el) if (code_el is not None and _text(code_el)) else ''
    desc_el = _lx1(item_el, "*[local-name()='Description']")
    desc = _text(desc_el) if desc_el is not None else ''
    apib_el = _lx1(item_el, "*[local-name()='ActionPeriodIsBase']")
    apib = (apib_el is not None and _text(apib_el) == 'true')
    auto = split_camel_words(name)
    if not apib:
        s = ("(%s) %s" % (code, name)) if code else name
        if desc == '':
            s = s + " []"
        elif desc != auto:   # -cne
            s = s + (" [%s]" % desc)
        return s
    o = {'name': name}
    if code:
        o['code'] = code
    if desc != auto:   # -cne
        o['description'] = desc
    o['actionPeriodIsBase'] = True
    return o


def build_dsl():
    """Линейный поток сборки DSL — зеркало script-body .ps1 (стр.392–1459)."""
    global dsl

    # === Сборка DSL ===
    dsl = {'type': obj_type, 'name': obj_name}

    # Синоним объекта: строка ru-only ИЛИ {ru,en}. Кастом → эмитим. Пустой <Synonym/> → явный synonym:"".
    syn_node_obj = _single(props, 'md:Synonym')
    syn_val = get_ml_value(syn_node_obj)
    if isinstance(syn_val, str):
        if ne_cs(syn_val, split_camel_words(obj_name)):
            dsl['synonym'] = syn_val
    elif syn_val is not None:
        dsl['synonym'] = syn_val
    elif syn_node_obj is not None:
        dsl['synonym'] = ''
    cmt = P('Comment')
    if cmt:
        dsl['comment'] = cmt

    # Свойства Catalog (omit-on-default).
    add_bool_prop('hierarchical', 'Hierarchical', False)
    add_enum_prop('hierarchyType', 'HierarchyType', 'HierarchyFoldersAndItems')
    add_bool_prop('limitLevelCount', 'LimitLevelCount', False)
    add_int_prop('levelCount', 'LevelCount', 2)
    add_bool_prop('foldersOnTop', 'FoldersOnTop', True)
    # owners
    owners_node = _single(props, 'md:Owners')
    if owners_node is not None:
        items = [_text(x) for x in _nodes(owners_node, 'xr:Item')]
        if len(items) > 0:
            dsl['owners'] = [(s.split('.', 1)[1] if re.match(r'^Catalog\.', s) else s) for s in items]
    add_enum_prop('subordinationUse', 'SubordinationUse', 'ToItems')
    # Тип-зависимые дефолты (компилятор задаёт их по типу — декомпилятор обязан зеркалить).
    descr_len_def = {'ExchangePlan': 150, 'ChartOfCharacteristicTypes': 100, 'ChartOfCalculationTypes': 100}.get(obj_type, 25)
    code_len_def = 5 if obj_type == 'ChartOfCalculationTypes' else 9
    create_inp_def = 'Use' if obj_type in ('Catalog', 'Document') else 'DontUse'
    data_lock_def = 'Managed'  # компилятор эмитит Managed по умолчанию для всех типов (авторинг); Automatic несётся в DSL явно
    code_series_def = {'ChartOfCharacteristicTypes': 'WholeCharacteristicKind', 'ChartOfAccounts': 'WholeChartOfAccounts'}.get(obj_type, 'WholeCatalog')
    check_unique_def = (obj_type in ('ChartOfCharacteristicTypes', 'ChartOfAccounts', 'Document', 'DocumentNumerator'))
    def_pres_def = 'AsCode' if obj_type == 'ChartOfAccounts' else 'AsDescription'
    add_int_prop('codeLength', 'CodeLength', code_len_def)
    add_int_prop('descriptionLength', 'DescriptionLength', descr_len_def)
    add_enum_prop('codeType', 'CodeType', 'String')
    add_enum_prop('codeAllowedLength', 'CodeAllowedLength', 'Variable')
    add_bool_prop('autonumbering', 'Autonumbering', True)
    add_bool_prop('checkUnique', 'CheckUnique', check_unique_def)
    add_enum_prop('codeSeries', 'CodeSeries', code_series_def)
    add_enum_prop('defaultPresentation', 'DefaultPresentation', def_pres_def)
    if obj_type != 'Constant':
        add_bool_prop('quickChoice', 'QuickChoice', True if obj_type == 'Enum' else False)
    add_enum_prop('choiceMode', 'ChoiceMode', 'BothWays')
    add_enum_prop('dataLockControlMode', 'DataLockControlMode', data_lock_def)
    add_enum_prop('fullTextSearch', 'FullTextSearch', 'Use')
    add_bool_prop('useStandardCommands', 'UseStandardCommands', False if obj_type in ('Enum', 'CommonForm') else True)
    add_enum_prop('createOnInput', 'CreateOnInput', create_inp_def)
    add_enum_prop('editType', 'EditType', 'InDialog')
    add_bool_prop('includeHelpInContents', 'IncludeHelpInContents', False)
    add_enum_prop('choiceHistoryOnInput', 'ChoiceHistoryOnInput', 'Auto')
    add_enum_prop('predefinedDataUpdate', 'PredefinedDataUpdate', 'Auto')
    add_enum_prop('searchStringModeOnInputByString', 'SearchStringModeOnInputByString', 'Begin')
    add_enum_prop('fullTextSearchOnInputByString', 'FullTextSearchOnInputByString', 'DontUse')
    # ExchangePlan-специфичные свойства.
    if obj_type == 'ExchangePlan':
        add_bool_prop('distributedInfoBase', 'DistributedInfoBase', False)
        add_bool_prop('includeConfigurationExtensions', 'IncludeConfigurationExtensions', False)
        add_enum_prop('dataHistory', 'DataHistory', 'DontUse')
        add_bool_prop('updateDataHistoryImmediatelyAfterWrite', 'UpdateDataHistoryImmediatelyAfterWrite', False)
        add_bool_prop('executeAfterWriteDataHistoryVersionProcessing', 'ExecuteAfterWriteDataHistoryVersionProcessing', False)
    # ChartOfCharacteristicTypes-специфичные свойства.
    if obj_type == 'ChartOfCharacteristicTypes':
        add_enum_prop('dataHistory', 'DataHistory', 'DontUse')
        add_bool_prop('updateDataHistoryImmediatelyAfterWrite', 'UpdateDataHistoryImmediatelyAfterWrite', False)
        add_bool_prop('executeAfterWriteDataHistoryVersionProcessing', 'ExecuteAfterWriteDataHistoryVersionProcessing', False)
        cev = P('CharacteristicExtValues')
        if cev:
            dsl['characteristicExtValues'] = cev
        vt_node = _single(props, 'md:Type')
        if vt_node is not None:
            vt_str = get_type_shorthand(vt_node)
            if vt_str and vt_str != 'Boolean + String(100) + Number(15,2) + DateTime':
                dsl['valueType'] = vt_str
    # ChartOfAccounts-специфичные свойства.
    if obj_type == 'ChartOfAccounts':
        edt = P('ExtDimensionTypes')
        if edt:
            dsl['extDimensionTypes'] = edt
        add_int_prop('maxExtDimensionCount', 'MaxExtDimensionCount', 3 if edt else 0)
        cm = P('CodeMask')
        if cm:
            dsl['codeMask'] = cm
        add_bool_prop('autoOrderByCode', 'AutoOrderByCode', True)
        add_int_prop('orderLength', 'OrderLength', 9)
        add_enum_prop('dataHistory', 'DataHistory', 'DontUse')
        add_bool_prop('updateDataHistoryImmediatelyAfterWrite', 'UpdateDataHistoryImmediatelyAfterWrite', False)
        add_bool_prop('executeAfterWriteDataHistoryVersionProcessing', 'ExecuteAfterWriteDataHistoryVersionProcessing', False)
    # ChartOfCalculationTypes-специфичные свойства.
    if obj_type == 'ChartOfCalculationTypes':
        add_enum_prop('dependenceOnCalculationTypes', 'DependenceOnCalculationTypes', 'DontUse')
        add_bool_prop('actionPeriodUse', 'ActionPeriodUse', False)
        bct_node = _single(props, 'md:BaseCalculationTypes')
        if bct_node is not None:
            bct_items = [_text(x) for x in _nodes(bct_node, 'xr:Item')]
            if len(bct_items) > 0:
                dsl['baseCalculationTypes'] = list(bct_items)
        add_enum_prop('dataHistory', 'DataHistory', 'DontUse')
        add_bool_prop('updateDataHistoryImmediatelyAfterWrite', 'UpdateDataHistoryImmediatelyAfterWrite', False)
        add_bool_prop('executeAfterWriteDataHistoryVersionProcessing', 'ExecuteAfterWriteDataHistoryVersionProcessing', False)
    # Document-специфичные свойства.
    if obj_type == 'Document':
        num_ref = P('Numerator')
        if num_ref:
            dsl['numerator'] = num_ref
        add_enum_prop('numberType', 'NumberType', 'String')
        add_int_prop('numberLength', 'NumberLength', 11)
        add_enum_prop('numberAllowedLength', 'NumberAllowedLength', 'Variable')
        add_enum_prop('numberPeriodicity', 'NumberPeriodicity', 'Year')
        add_enum_prop('posting', 'Posting', 'Allow')
        add_enum_prop('realTimePosting', 'RealTimePosting', 'Deny')
        add_enum_prop('registerRecordsDeletion', 'RegisterRecordsDeletion', 'AutoDelete')
        add_enum_prop('registerRecordsWritingOnPost', 'RegisterRecordsWritingOnPost', 'WriteSelected')
        add_enum_prop('sequenceFilling', 'SequenceFilling', 'AutoFill')
        add_bool_prop('postInPrivilegedMode', 'PostInPrivilegedMode', True)
        add_bool_prop('unpostInPrivilegedMode', 'UnpostInPrivilegedMode', True)
        rr_node = _single(props, 'md:RegisterRecords')
        if rr_node is not None:
            rr_items = [_text(x) for x in _nodes(rr_node, 'xr:Item')]
            if len(rr_items) > 0:
                dsl['registerRecords'] = list(rr_items)
        add_enum_prop('dataHistory', 'DataHistory', 'DontUse')
        add_bool_prop('updateDataHistoryImmediatelyAfterWrite', 'UpdateDataHistoryImmediatelyAfterWrite', False)
        add_bool_prop('executeAfterWriteDataHistoryVersionProcessing', 'ExecuteAfterWriteDataHistoryVersionProcessing', False)
    # InformationRegister-специфичные свойства.
    if obj_type == 'InformationRegister':
        add_enum_prop('periodicity', 'InformationRegisterPeriodicity', 'Nonperiodical')
        add_enum_prop('writeMode', 'WriteMode', 'Independent')
        add_bool_prop('mainFilterOnPeriod', 'MainFilterOnPeriod', False)
        add_bool_prop('enableTotalsSliceFirst', 'EnableTotalsSliceFirst', False)
        add_bool_prop('enableTotalsSliceLast', 'EnableTotalsSliceLast', False)
        add_enum_prop('dataHistory', 'DataHistory', 'DontUse')
        add_bool_prop('updateDataHistoryImmediatelyAfterWrite', 'UpdateDataHistoryImmediatelyAfterWrite', False)
        add_bool_prop('executeAfterWriteDataHistoryVersionProcessing', 'ExecuteAfterWriteDataHistoryVersionProcessing', False)
    # AccumulationRegister-специфичные свойства.
    if obj_type == 'AccumulationRegister':
        add_enum_prop('registerType', 'RegisterType', 'Balance')
        add_bool_prop('enableTotalsSplitting', 'EnableTotalsSplitting', True)
    # AccountingRegister-специфичные свойства.
    if obj_type == 'AccountingRegister':
        coa = P('ChartOfAccounts')
        if coa:
            dsl['chartOfAccounts'] = coa
        add_bool_prop('correspondence', 'Correspondence', False)
        add_int_prop('periodAdjustmentLength', 'PeriodAdjustmentLength', 0)
        add_bool_prop('enableTotalsSplitting', 'EnableTotalsSplitting', True)
    # CalculationRegister-специфичные свойства.
    if obj_type == 'CalculationRegister':
        cct = P('ChartOfCalculationTypes')
        if cct:
            dsl['chartOfCalculationTypes'] = cct
        add_enum_prop('periodicity', 'Periodicity', 'Month')
        add_bool_prop('actionPeriod', 'ActionPeriod', False)
        add_bool_prop('basePeriod', 'BasePeriod', False)
        sch = P('Schedule')
        if sch:
            dsl['schedule'] = sch
        schv = P('ScheduleValue')
        if schv:
            dsl['scheduleValue'] = schv
        schd = P('ScheduleDate')
        if schd:
            dsl['scheduleDate'] = schd
    # BusinessProcess-специфичные свойства.
    if obj_type == 'BusinessProcess':
        add_enum_prop('numberType', 'NumberType', 'String')
        add_int_prop('numberLength', 'NumberLength', 11)
        add_enum_prop('numberAllowedLength', 'NumberAllowedLength', 'Variable')
        add_enum_prop('numberPeriodicity', 'NumberPeriodicity', 'Nonperiodical')
        add_bool_prop('checkUnique', 'CheckUnique', True)
        add_bool_prop('autonumbering', 'Autonumbering', True)
        tsk = P('Task')
        if tsk:
            dsl['task'] = tsk
        add_bool_prop('createTaskInPrivilegedMode', 'CreateTaskInPrivilegedMode', True)
    # Task-специфичные свойства.
    if obj_type == 'Task':
        add_enum_prop('numberType', 'NumberType', 'String')
        add_int_prop('numberLength', 'NumberLength', 14)
        add_enum_prop('numberAllowedLength', 'NumberAllowedLength', 'Variable')
        add_bool_prop('checkUnique', 'CheckUnique', True)
        add_bool_prop('autonumbering', 'Autonumbering', True)
        tnap = P('TaskNumberAutoPrefix')
        if tnap and tnap != 'BusinessProcessNumber':
            dsl['taskNumberAutoPrefix'] = tnap
        add_int_prop('descriptionLength', 'DescriptionLength', 150)
        addr = P('Addressing')
        if addr:
            dsl['addressing'] = addr
        maa = P('MainAddressingAttribute')
        if maa:
            dsl['mainAddressingAttribute'] = maa
        cp = P('CurrentPerformer')
        if cp:
            dsl['currentPerformer'] = cp
        add_enum_prop('defaultPresentation', 'DefaultPresentation', 'AsDescription')
    # Report-специфичные свойства.
    if obj_type == 'Report':
        dfm = P('DefaultForm')
        if dfm:
            dsl['defaultForm'] = dfm
        afm = P('AuxiliaryForm')
        if afm:
            dsl['auxiliaryForm'] = afm
        mdcs = P('MainDataCompositionSchema')
        if mdcs:
            dsl['mainDataCompositionSchema'] = mdcs
        dsf = P('DefaultSettingsForm')
        if dsf:
            dsl['defaultSettingsForm'] = dsf
        asf = P('AuxiliarySettingsForm')
        if asf:
            dsl['auxiliarySettingsForm'] = asf
        dvf = P('DefaultVariantForm')
        if dvf:
            dsl['defaultVariantForm'] = dvf
        vs = P('VariantsStorage')
        if vs:
            dsl['variantsStorage'] = vs
        ss = P('SettingsStorage')
        if ss:
            dsl['settingsStorage'] = ss
        ep = get_ml_value(_single(props, 'md:ExtendedPresentation'))
        if ep is not None:
            dsl['extendedPresentation'] = ep
    # DataProcessor-специфичные свойства.
    if obj_type == 'DataProcessor':
        dfm = P('DefaultForm')
        if dfm:
            dsl['defaultForm'] = dfm
        afm = P('AuxiliaryForm')
        if afm:
            dsl['auxiliaryForm'] = afm
        ep = get_ml_value(_single(props, 'md:ExtendedPresentation'))
        if ep is not None:
            dsl['extendedPresentation'] = ep
    # DefinedType — тип-псевдоним.
    if obj_type == 'DefinedType':
        vt = get_type_shorthand(_single(props, 'md:Type'))
        if vt:
            dsl['valueType'] = vt
    # FunctionalOption.
    if obj_type == 'FunctionalOption':
        loc = P('Location')
        if loc:
            dsl['location'] = loc
        add_bool_prop('privilegedGetMode', 'PrivilegedGetMode', True)
        content_node = _single(props, 'md:Content')
        if content_node is not None:
            items = [_text(x) for x in _nodes(content_node, 'xr:Object')]
            if len(items) > 0:
                dsl['content'] = list(items)
    # DocumentJournal.
    if obj_type == 'DocumentJournal':
        dfm = P('DefaultForm')
        if dfm:
            dsl['defaultForm'] = dfm
        afm = P('AuxiliaryForm')
        if afm:
            dsl['auxiliaryForm'] = afm
        rd_node = _single(props, 'md:RegisteredDocuments')
        if rd_node is not None:
            rd_items = [_text(x) for x in _nodes(rd_node, 'xr:Item')]
            if len(rd_items) > 0:
                dsl['registeredDocuments'] = list(rd_items)
    # Sequence.
    if obj_type == 'Sequence':
        add_enum_prop('moveBoundaryOnPosting', 'MoveBoundaryOnPosting', 'DontMove')
        for ll in (('Documents', 'documents'), ('RegisterRecords', 'registerRecords')):
            ln = _single(props, "md:" + ll[0])
            if ln is not None:
                items = [_text(x) for x in _nodes(ln, 'xr:Item')]
                if len(items) > 0:
                    dsl[ll[1]] = list(items)
    # FilterCriterion.
    if obj_type == 'FilterCriterion':
        vt = get_type_shorthand(_single(props, 'md:Type'))
        if vt:
            dsl['valueType'] = vt
        cn = _single(props, 'md:Content')
        if cn is not None:
            items = [_text(x) for x in _nodes(cn, 'xr:Item')]
            if len(items) > 0:
                dsl['content'] = list(items)
        dfm = P('DefaultForm')
        if dfm:
            dsl['defaultForm'] = dfm
        afm = P('AuxiliaryForm')
        if afm:
            dsl['auxiliaryForm'] = afm
    # DocumentNumerator.
    if obj_type == 'DocumentNumerator':
        add_enum_prop('numberType', 'NumberType', 'String')
        add_int_prop('numberLength', 'NumberLength', 11)
        add_enum_prop('numberAllowedLength', 'NumberAllowedLength', 'Variable')
        add_enum_prop('numberPeriodicity', 'NumberPeriodicity', 'Year')
    # SettingsStorage.
    if obj_type == 'SettingsStorage':
        for fp in (('DefaultSaveForm', 'defaultSaveForm'), ('DefaultLoadForm', 'defaultLoadForm'),
                   ('AuxiliarySaveForm', 'auxiliarySaveForm'), ('AuxiliaryLoadForm', 'auxiliaryLoadForm')):
            fv = P(fp[0])
            if fv:
                dsl[fp[1]] = fv
    # CommonModule.
    if obj_type == 'CommonModule':
        add_bool_prop('global', 'Global', False)
        add_bool_prop('clientManagedApplication', 'ClientManagedApplication', False)
        add_bool_prop('server', 'Server', False)
        add_bool_prop('externalConnection', 'ExternalConnection', False)
        add_bool_prop('clientOrdinaryApplication', 'ClientOrdinaryApplication', False)
        add_bool_prop('serverCall', 'ServerCall', False)
        add_bool_prop('privileged', 'Privileged', False)
        add_enum_prop('returnValuesReuse', 'ReturnValuesReuse', 'DontUse')
    # EventSubscription.
    if obj_type == 'EventSubscription':
        src_node = _single(props, 'md:Source')
        if src_node is not None:
            src_types = [strip_ns_prefix(_text(x).strip()) for x in _nodes(src_node, 'v8:Type|v8:TypeSet')]
            if len(src_types) > 0:
                dsl['source'] = list(src_types)
        add_enum_prop('event', 'Event', 'BeforeWrite')
        h = P('Handler')
        if h:
            dsl['handler'] = h
    # CommonForm.
    if obj_type == 'CommonForm':
        add_enum_prop('formType', 'FormType', 'Managed')
        up_node = _single(props, 'md:UsePurposes')
        if up_node is not None:
            ups = [_text(x) for x in _nodes(up_node, 'v8:Value')]
            def2 = ['PlatformApplication', 'MobilePlatformApplication']
            same = (len(ups) == len(def2))
            if same:
                for k in range(len(ups)):
                    if ups[k] != def2[k]:
                        same = False
                        break
            if (not same) and len(ups) > 0:
                dsl['usePurposes'] = list(ups)
        ep = get_ml_value(_single(props, 'md:ExtendedPresentation'))
        if ep is not None:
            dsl['extendedPresentation'] = ep
    # SessionParameter.
    if obj_type == 'SessionParameter':
        vt = get_type_shorthand(_single(props, 'md:Type'))
        if vt:
            dsl['valueType'] = vt
    # FunctionalOptionsParameter.
    if obj_type == 'FunctionalOptionsParameter':
        un = _single(props, 'md:Use')
        if un is not None:
            items = [_text(x) for x in _nodes(un, 'xr:Item')]
            if len(items) > 0:
                dsl['use'] = list(items)
    # WSReference.
    if obj_type == 'WSReference':
        url = P('LocationURL')
        if url:
            dsl['locationURL'] = url
    # CommonPicture.
    if obj_type == 'CommonPicture':
        add_bool_prop('availabilityForChoice', 'AvailabilityForChoice', False)
        add_bool_prop('availabilityForAppearance', 'AvailabilityForAppearance', False)
    # CommonTemplate.
    if obj_type == 'CommonTemplate':
        add_enum_prop('templateType', 'TemplateType', 'SpreadsheetDocument')
    # CommandGroup.
    if obj_type == 'CommandGroup':
        add_enum_prop('representation', 'Representation', 'Auto')
        tt = get_ml_value(_single(props, 'md:ToolTip'))
        if tt is not None:
            dsl['tooltip'] = tt
        get_picture_to_dsl(props, dsl)
        add_enum_prop('category', 'Category', 'NavigationPanel')
    # CommonCommand.
    if obj_type == 'CommonCommand':
        grp = P('Group')
        if grp:
            dsl['group'] = grp
        add_enum_prop('representation', 'Representation', 'Auto')
        tt = get_ml_value(_single(props, 'md:ToolTip'))
        if tt is not None:
            dsl['tooltip'] = tt
        get_picture_to_dsl(props, dsl)
        sc = P('Shortcut')
        if sc:
            dsl['shortcut'] = sc
        cpt = get_type_shorthand(_single(props, 'md:CommandParameterType'))
        if cpt:
            dsl['commandParameterType'] = cpt
        add_enum_prop('parameterUseMode', 'ParameterUseMode', 'Single')
        add_bool_prop('modifiesData', 'ModifiesData', False)
        add_enum_prop('onMainServerUnavalableBehavior', 'OnMainServerUnavalableBehavior', 'Auto')
    # CommonAttribute.
    if obj_type == 'CommonAttribute':
        vt = get_type_shorthand(_single(props, 'md:Type'))
        if vt and vt != 'String(0)':
            dsl['valueType'] = vt
        add_bool_prop('passwordMode', 'PasswordMode', False)
        for mlp in (('Format', 'format'), ('EditFormat', 'editFormat'), ('ToolTip', 'tooltip')):
            mv = get_ml_value(_single(props, "md:" + mlp[0]))
            if mv is not None:
                dsl[mlp[1]] = mv
        add_bool_prop('markNegatives', 'MarkNegatives', False)
        msk = P('Mask')
        if msk:
            dsl['mask'] = msk
        add_bool_prop('multiLine', 'MultiLine', False)
        add_bool_prop('extendedEdit', 'ExtendedEdit', False)
        for mm in (('MinValue', 'minValue'), ('MaxValue', 'maxValue')):
            mn = _single(props, "md:" + mm[0])
            if mn is not None and _attr(mn, 'nil', NS_XSI) != 'true':
                mxt = _attr(mn, 'type', NS_XSI)
                if re.search(r'decimal$', mxt, re.I):
                    dsl[mm[1]] = int(_text(mn)) if re.match(r'^-?\d+$', _text(mn)) else float(_text(mn))
                else:
                    dsl[mm[1]] = _text(mn)
        add_bool_prop('fillFromFillingValue', 'FillFromFillingValue', False)
        # FillValue: тип-зависимый дефолт (String→typed-empty, Number→0, прочее→nil).
        cat_vt = vt if vt else 'String(0)'
        fv_n = _single(props, 'md:FillValue')
        if fv_n is not None:
            fv_nil = (_attr(fv_n, 'nil', NS_XSI) == 'true')
            if fv_nil:
                if re.match(r'^(String|Number)', cat_vt):
                    dsl['fillValue'] = {'nil': True}
            else:
                fv_xt = _attr(fv_n, 'type', NS_XSI)
                if re.search(r'DesignTimeRef$', fv_xt, re.I) and _text(fv_n) == '':
                    dsl['fillValue'] = {'emptyRef': True}
                elif re.search(r'decimal$', fv_xt, re.I):
                    if _text(fv_n) != '0':
                        dsl['fillValue'] = int(_text(fv_n)) if re.match(r'^-?\d+$', _text(fv_n)) else float(_text(fv_n))
                elif _text(fv_n):
                    dsl['fillValue'] = _text(fv_n)
        add_enum_prop('fillChecking', 'FillChecking', 'DontCheck')
        add_enum_prop('choiceFoldersAndItems', 'ChoiceFoldersAndItems', 'Items')
        cpl = parse_choice_parameter_links(props, 'md:ChoiceParameterLinks')
        if cpl is not None:
            dsl['choiceParameterLinks'] = cpl
        cp = parse_choice_parameters(props, 'md:ChoiceParameters')
        if cp is not None:
            dsl['choiceParameters'] = cp
        add_enum_prop('quickChoice', 'QuickChoice', 'Auto')
        add_enum_prop('createOnInput', 'CreateOnInput', 'Auto')
        cf = P('ChoiceForm')
        if cf:
            dsl['choiceForm'] = cf
        add_enum_prop('choiceHistoryOnInput', 'ChoiceHistoryOnInput', 'Auto')
        cn = _single(props, 'md:Content')
        if cn is not None:
            c_arr = []
            for it in _nodes(cn, 'xr:Item'):
                md_n = _single(it, 'xr:Metadata')
                mdv = _text(md_n) if md_n is not None else ''
                use_n = _single(it, 'xr:Use')
                usev = _text(use_n) if use_n is not None else 'Use'
                cs_n = _single(it, 'xr:ConditionalSeparation')
                csv = _text(cs_n) if cs_n is not None else ''
                if usev == 'Use' and not csv:
                    c_arr.append(mdv)
                else:
                    io = {'metadata': mdv}
                    if usev != 'Use':
                        io['use'] = usev
                    if csv:
                        io['conditionalSeparation'] = csv
                    c_arr.append(io)
            if len(c_arr) > 0:
                dsl['content'] = c_arr
        add_enum_prop('autoUse', 'AutoUse', 'DontUse')
        add_enum_prop('dataSeparation', 'DataSeparation', 'DontUse')
        add_enum_prop('separatedDataUse', 'SeparatedDataUse', 'Independently')
        dsv = P('DataSeparationValue')
        if dsv:
            dsl['dataSeparationValue'] = dsv
        dsu = P('DataSeparationUse')
        if dsu:
            dsl['dataSeparationUse'] = dsu
        cs2 = P('ConditionalSeparation')
        if cs2:
            dsl['conditionalSeparation'] = cs2
        add_enum_prop('usersSeparation', 'UsersSeparation', 'DontUse')
        add_enum_prop('authenticationSeparation', 'AuthenticationSeparation', 'DontUse')
        add_enum_prop('configurationExtensionsSeparation', 'ConfigurationExtensionsSeparation', 'DontUse')
        add_enum_prop('indexing', 'Indexing', 'DontIndex')
        add_enum_prop('dataHistory', 'DataHistory', 'Use')
    # ScheduledJob.
    if obj_type == 'ScheduledJob':
        mn = P('MethodName')
        if mn:
            dsl['methodName'] = mn
        descr = P('Description')
        if descr:
            dsl['description'] = descr
        k = P('Key')
        if k:
            dsl['key'] = k
        add_bool_prop('use', 'Use', False)
        add_bool_prop('predefined', 'Predefined', False)
        add_int_prop('restartCountOnFailure', 'RestartCountOnFailure', 3)
        add_int_prop('restartIntervalOnFailure', 'RestartIntervalOnFailure', 10)
    # Constant — богатый одиночный реквизит.
    if obj_type == 'Constant':
        vt = get_type_shorthand(_single(props, 'md:Type'))
        if vt:
            dsl['valueType'] = vt
        else:
            dsl['valueType'] = ''
        dfm = P('DefaultForm')
        if dfm:
            dsl['defaultForm'] = dfm
        ep = get_ml_value(_single(props, 'md:ExtendedPresentation'))
        if ep is not None:
            dsl['extendedPresentation'] = ep
        add_bool_prop('passwordMode', 'PasswordMode', False)
        fmt = get_ml_value(_single(props, 'md:Format'))
        if fmt is not None:
            dsl['format'] = fmt
        efmt = get_ml_value(_single(props, 'md:EditFormat'))
        if efmt is not None:
            dsl['editFormat'] = efmt
        tt = get_ml_value(_single(props, 'md:ToolTip'))
        if tt is not None:
            dsl['tooltip'] = tt
        add_bool_prop('markNegatives', 'MarkNegatives', False)
        msk = P('Mask')
        if msk:
            dsl['mask'] = msk
        add_bool_prop('multiLine', 'MultiLine', False)
        add_bool_prop('extendedEdit', 'ExtendedEdit', False)
        for mm in (('MinValue', 'minValue'), ('MaxValue', 'maxValue')):
            mn = _single(props, "md:" + mm[0])
            if mn is not None and _attr(mn, 'nil', NS_XSI) != 'true':
                mxt = _attr(mn, 'type', NS_XSI)
                if re.search(r'decimal$', mxt, re.I):
                    dsl[mm[1]] = int(_text(mn)) if re.match(r'^-?\d+$', _text(mn)) else float(_text(mn))
                else:
                    dsl[mm[1]] = _text(mn)
        add_enum_prop('fillChecking', 'FillChecking', 'DontCheck')
        add_enum_prop('choiceFoldersAndItems', 'ChoiceFoldersAndItems', 'Items')
        cpl = parse_choice_parameter_links(props, 'md:ChoiceParameterLinks')
        if cpl is not None:
            dsl['choiceParameterLinks'] = cpl
        cp = parse_choice_parameters(props, 'md:ChoiceParameters')
        if cp is not None:
            dsl['choiceParameters'] = cp
        add_enum_prop('quickChoice', 'QuickChoice', 'Auto')
        cf = P('ChoiceForm')
        if cf:
            dsl['choiceForm'] = cf
        lbt_node = _single(props, 'md:LinkByType')
        if lbt_node is not None:
            dp_n = _single(lbt_node, 'md:DataPath')
            if dp_n is not None and _text(dp_n):
                li_n = _single(lbt_node, 'md:LinkItem')
                li = int(_text(li_n)) if (li_n is not None and _text(li_n)) else 0
                dsl['linkByType'] = _text(dp_n) if li == 0 else {'dataPath': _text(dp_n), 'linkItem': li}
        add_enum_prop('dataHistory', 'DataHistory', 'DontUse')
        add_bool_prop('updateDataHistoryImmediatelyAfterWrite', 'UpdateDataHistoryImmediatelyAfterWrite', False)
        add_bool_prop('executeAfterWriteDataHistoryVersionProcessing', 'ExecuteAfterWriteDataHistoryVersionProcessing', False)

    # InputByString — эмитим только при отличии от выведенного дефолта.
    ib_node = _single(props, 'md:InputByString')
    if ib_node is not None:
        ib_actual = [_text(x) for x in _nodes(ib_node, 'xr:Field')]
        clv = P('CodeLength')
        dlv = P('DescriptionLength')
        cl = int(clv) if (clv is not None and clv != '') else 9
        dl = int(dlv) if (dlv is not None and dlv != '') else 25
        ib_def = []
        if dl > 0:
            ib_def.append("StandardAttribute.Description")
        if cl > 0:
            ib_def.append("StandardAttribute.Code")
        ib_short = [short_field(x) for x in ib_actual]
        same = (len(ib_short) == len(ib_def))
        if same:
            for k in range(len(ib_short)):
                if ib_short[k] != ib_def[k]:
                    same = False
                    break
        if not same:
            dsl['inputByString'] = list(ib_short)

    # BasedOn.
    bo_node = _single(props, 'md:BasedOn')
    if bo_node is not None:
        bo_items = [_text(x) for x in _nodes(bo_node, 'xr:Item')]
        if len(bo_items) > 0:
            dsl['basedOn'] = list(bo_items)

    # DataLockFields.
    dlf_node = _single(props, 'md:DataLockFields')
    if dlf_node is not None:
        dlf_fields = [short_field(_text(x)) for x in _nodes(dlf_node, 'xr:Field')]
        if len(dlf_fields) > 0:
            dsl['dataLockFields'] = list(dlf_fields)

    # Формы по умолчанию (omit-on-empty).
    add_form_ref('defaultObjectForm', 'DefaultObjectForm')
    add_form_ref('defaultFolderForm', 'DefaultFolderForm')
    add_form_ref('defaultListForm', 'DefaultListForm')
    add_form_ref('defaultChoiceForm', 'DefaultChoiceForm')
    add_form_ref('defaultFolderChoiceForm', 'DefaultFolderChoiceForm')
    add_form_ref('auxiliaryObjectForm', 'AuxiliaryObjectForm')
    add_form_ref('auxiliaryFolderForm', 'AuxiliaryFolderForm')
    add_form_ref('auxiliaryListForm', 'AuxiliaryListForm')
    add_form_ref('auxiliaryChoiceForm', 'AuxiliaryChoiceForm')
    add_form_ref('auxiliaryFolderChoiceForm', 'AuxiliaryFolderChoiceForm')
    add_form_ref('defaultRecordForm', 'DefaultRecordForm')
    add_form_ref('auxiliaryRecordForm', 'AuxiliaryRecordForm')

    # Презентации (ML, omit-on-empty).
    for pp in (('ObjectPresentation', 'objectPresentation'), ('ExtendedObjectPresentation', 'extendedObjectPresentation'),
               ('RecordPresentation', 'recordPresentation'), ('ExtendedRecordPresentation', 'extendedRecordPresentation'),
               ('ListPresentation', 'listPresentation'), ('ExtendedListPresentation', 'extendedListPresentation'),
               ('Explanation', 'explanation')):
        pv = get_ml_value(_single(props, "md:" + pp[0]))
        if pv is not None:
            dsl[pp[1]] = pv

    # --- Characteristics (привязка ПВХ). ---
    chars_node = _single(props, 'md:Characteristics')
    if chars_node is not None:
        ch_list = _nodes(chars_node, 'xr:Characteristic')
        if len(ch_list) > 0:
            ch_arr = []
            for ch in ch_list:
                ct = _single(ch, 'xr:CharacteristicTypes')
                cv = _single(ch, 'xr:CharacteristicValues')
                t_from = _attr(ct, 'from')
                v_from = _attr(cv, 'from')

                def gt(n, node):
                    x = _single(node, "xr:" + n)
                    return _text(x) if x is not None else ""

                def giv(n, node):
                    x = _single(node, "xr:" + n)
                    return int(_text(x)) if (x is not None and _text(x) != '') else -1

                tfv_node = _single(ct, 'xr:TypesFilterValue')
                tfv_nil = _attr(tfv_node, 'nil', NS_XSI) if tfv_node is not None else ''
                types = {
                    'from': t_from,
                    'key': shorten_char_field(gt('KeyField', ct), t_from),
                    'filterField': shorten_char_field(gt('TypesFilterField', ct), t_from),
                    'filterValue': None if tfv_nil == 'true' else convert_ch_scalar_node(tfv_node),
                }
                dpf = giv('DataPathField', ct)
                if dpf != -1:
                    types['dataPathField'] = dpf
                mvu = giv('MultipleValuesUseField', ct)
                if mvu != -1:
                    types['multipleValuesUseField'] = mvu
                values = {
                    'from': v_from,
                    'object': shorten_char_field(gt('ObjectField', cv), v_from),
                    'type': shorten_char_field(gt('TypeField', cv), v_from),
                    'value': shorten_char_field(gt('ValueField', cv), v_from),
                }
                mvk = giv('MultipleValuesKeyField', cv)
                if mvk != -1:
                    values['multipleValuesKeyField'] = mvk
                mvo = giv('MultipleValuesOrderField', cv)
                if mvo != -1:
                    values['multipleValuesOrderField'] = mvo
                ch_arr.append({'types': types, 'values': values})
            dsl['characteristics'] = ch_arr

    # --- StandardAttributes: захватываем ОТКЛОНЕНИЯ от профиля материализованного блока. ---
    std_profile_by_type = {
        'Catalog': {
            'Owner': {'fillChecking': 'ShowError', 'fillFromFillingValue': True},
            'Parent': {'fillFromFillingValue': True},
            'Description': {'fillChecking': 'ShowError'},
        },
        'ExchangePlan': {
            'Description': {'fillChecking': 'ShowError'},
            'Code': {'fillChecking': 'ShowError'},
        },
        'ChartOfCharacteristicTypes': {
            'Description': {'fillChecking': 'ShowError'},
            'Parent': {'fillFromFillingValue': True},
        },
        'ChartOfAccounts': {
            'Description': {'fillChecking': 'ShowError'},
            'Code': {'fillChecking': 'ShowError'},
            'Parent': {'fillFromFillingValue': True},
        },
        'ChartOfCalculationTypes': {
            'Description': {'fillChecking': 'ShowError'},
        },
        'Document': {
            'Date': {'fillChecking': 'ShowError'},
        },
    }
    cat_std_profile = std_profile_by_type.get(obj_type, {})
    std_fixed_by_type = {
        'Catalog': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'IsFolder', 'Owner', 'Parent', 'Description', 'Code'],
        'ExchangePlan': ['Ref', 'DeletionMark', 'Code', 'Description', 'ThisNode', 'SentNo', 'ReceivedNo'],
        'ChartOfCharacteristicTypes': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'Description', 'Code', 'Parent', 'ValueType'],
        'ChartOfAccounts': ['PredefinedDataName', 'Order', 'OffBalance', 'Type', 'Description', 'Code', 'Parent', 'Predefined', 'DeletionMark', 'Ref'],
        'ChartOfCalculationTypes': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'ActionPeriodIsBasic', 'Description', 'Code'],
        'Document': ['Ref', 'DeletionMark', 'Date', 'Number', 'Posted'],
        'Enum': ['Order', 'Ref'],
        'DocumentJournal': ['Type', 'Ref', 'Date', 'Posted', 'DeletionMark', 'Number'],
    }
    std_fixed = std_fixed_by_type.get(obj_type, [])
    std_conditional_types = ['Catalog', 'ExchangePlan', 'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes', 'Document']
    sa_node = _single(props, 'md:StandardAttributes')
    if sa_node is not None:
        sa_map = {}
        for sa in _nodes(sa_node, 'xr:StandardAttribute'):
            an = _attr(sa, 'name')
            prof = cat_std_profile.get(an, {})
            ov = {}
            # FillChecking (профиль или DontCheck)
            fc_n = _single(sa, 'xr:FillChecking')
            fc = _text(fc_n) if fc_n is not None else 'DontCheck'
            prof_fc = prof.get('fillChecking', 'DontCheck')
            if fc != prof_fc:
                ov['fillChecking'] = fc
            # FillFromFillingValue (профиль или false)
            ffv_n = _single(sa, 'xr:FillFromFillingValue')
            ffv = (ffv_n is not None and _text(ffv_n) == 'true')
            prof_ffv = (prof.get('fillFromFillingValue') is True)
            if ffv != prof_ffv:
                ov['fillFromFillingValue'] = ffv
            # Synonym / ToolTip (профиль пуст)
            syn = get_ml_value(_single(sa, 'xr:Synonym'))
            if syn is not None:
                ov['synonym'] = syn
            tt = get_ml_value(_single(sa, 'xr:ToolTip'))
            if tt is not None:
                ov['tooltip'] = tt
            # FullTextSearch / DataHistory (профиль = Use)
            fts_n = _single(sa, 'xr:FullTextSearch')
            if fts_n is not None and _text(fts_n) != 'Use':
                ov['fullTextSearch'] = _text(fts_n)
            dh_n = _single(sa, 'xr:DataHistory')
            if dh_n is not None and _text(dh_n) != 'Use':
                ov['dataHistory'] = _text(dh_n)
            # FillValue (дефолт nil). Comment/Mask/ChoiceForm (дефолт пусто).
            fv_n = _single(sa, 'xr:FillValue')
            if fv_n is not None and _attr(fv_n, 'nil', NS_XSI) != 'true':
                fv_xt = _attr(fv_n, 'type', NS_XSI)
                if re.search(r'DesignTimeRef$', fv_xt, re.I) and _text(fv_n) == '':
                    ov['fillValue'] = {'emptyRef': True}
                elif re.search(r'TypeDescription$', fv_xt, re.I) and _text(fv_n) == '':
                    ov['fillValue'] = {'typeDescription': True}   # пустое типизированное (реквизит ValueType ПВХ) ≠ xs:string
                else:
                    ov['fillValue'] = convert_ch_scalar_node(fv_n)
            sa_cmt = _single(sa, 'xr:Comment')
            if sa_cmt is not None and _text(sa_cmt):
                ov['comment'] = _text(sa_cmt)
            sa_msk = _single(sa, 'xr:Mask')
            if sa_msk is not None and _text(sa_msk):
                ov['mask'] = _text(sa_msk)
            sa_fmt = get_ml_value(_single(sa, 'xr:Format'))
            if sa_fmt is not None:
                ov['format'] = sa_fmt
            sa_efmt = get_ml_value(_single(sa, 'xr:EditFormat'))
            if sa_efmt is not None:
                ov['editFormat'] = sa_efmt
            sa_cf = _single(sa, 'xr:ChoiceForm')
            if sa_cf is not None and _text(sa_cf):
                ov['choiceForm'] = _text(sa_cf)
            sa_cpl = parse_choice_parameter_links(sa, 'xr:ChoiceParameterLinks')
            if sa_cpl is not None:
                ov['choiceParameterLinks'] = sa_cpl
            sa_cp = parse_choice_parameters(sa, 'xr:ChoiceParameters')
            if sa_cp is not None:
                ov['choiceParameters'] = sa_cp
            # LinkByType стандартного реквизита (ExtDimensionN→Account у регистра бухгалтерии).
            sa_lbt = _single(sa, 'xr:LinkByType')
            if sa_lbt is not None:
                sa_lbt_dp = _single(sa_lbt, 'xr:DataPath')
                if sa_lbt_dp is not None and _text(sa_lbt_dp):
                    sa_lbt_li = _single(sa_lbt, 'xr:LinkItem')
                    li = int(_text(sa_lbt_li)) if (sa_lbt_li is not None and _text(sa_lbt_li)) else 0
                    ov['linkByType'] = {'dataPath': _text(sa_lbt_dp), 'linkItem': li}
            # Доп./опциональный реквизит (не в фикс-списке) — эмитим по присутствию даже без отклонений.
            if len(ov) > 0 or (an not in std_fixed):
                sa_map[an] = ov
        if len(sa_map) > 0 or (obj_type in std_conditional_types):
            dsl['standardAttributes'] = sa_map
    elif obj_type in ('InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister', 'BusinessProcess', 'Task', 'Enum', 'DocumentJournal'):
        # Регистр/БП/Задача опускают all-default блок → opt-out `standardAttributes:""`.
        dsl['standardAttributes'] = ''

    # --- ChildObjects: Attributes + TabularSections ---
    child_objs = _single(obj_node, 'md:ChildObjects')
    if child_objs is not None:
        attrs = _nodes(child_objs, 'md:Attribute')
        if len(attrs) > 0:
            arr = []
            for a in attrs:
                arr.append(attr_to_dsl(a))
            dsl['attributes'] = arr
        # Enum: значения перечисления.
        ev_nodes = _nodes(child_objs, 'md:EnumValue')
        if len(ev_nodes) > 0:
            ev_arr = []
            for ev in ev_nodes:
                evp = _single(ev, 'md:Properties')
                ev_name = _text(_single(evp, 'md:Name'))
                ev_syn_node = _single(evp, 'md:Synonym')
                ev_syn = get_ml_value(ev_syn_node)
                ev_cmt_n = _single(evp, 'md:Comment')
                ev_cmt = _text(ev_cmt_n) if ev_cmt_n is not None else ''
                ev_syn_val = None
                if isinstance(ev_syn, str):
                    if ne_cs(ev_syn, split_camel_words(ev_name)):
                        ev_syn_val = ev_syn
                elif ev_syn is not None:
                    ev_syn_val = ev_syn
                elif ev_syn_node is not None:
                    ev_syn_val = ''
                if (ev_syn_val is not None) or ev_cmt:
                    o = {'name': ev_name}
                    if ev_syn_val is not None:
                        o['synonym'] = ev_syn_val
                    if ev_cmt:
                        o['comment'] = ev_cmt
                    ev_arr.append(o)
                else:
                    ev_arr.append(ev_name)
            dsl['values'] = ev_arr
        # DocumentJournal: колонки.
        col_nodes = _nodes(child_objs, 'md:Column')
        if len(col_nodes) > 0:
            col_arr = []
            for col in col_nodes:
                cp = _single(col, 'md:Properties')
                c_name = _text(_single(cp, 'md:Name'))
                o = {'name': c_name}
                c_syn_node = _single(cp, 'md:Synonym')
                c_syn = get_ml_value(c_syn_node)
                if isinstance(c_syn, str):
                    if ne_cs(c_syn, split_camel_words(c_name)):
                        o['synonym'] = c_syn
                elif c_syn is not None:
                    o['synonym'] = c_syn
                elif c_syn_node is not None:
                    o['synonym'] = ''   # пустой <Synonym/> ≠ авто-синоним → явный ''
                c_cmt_n = _single(cp, 'md:Comment')
                if c_cmt_n is not None and _text(c_cmt_n):
                    o['comment'] = _text(c_cmt_n)
                c_idx_n = _single(cp, 'md:Indexing')
                if c_idx_n is not None and _text(c_idx_n) != 'DontIndex':
                    o['indexing'] = _text(c_idx_n)
                c_ref_node = _single(cp, 'md:References')
                refs = []
                if c_ref_node is not None:
                    for it in _nodes(c_ref_node, 'xr:Item'):
                        refs.append(_text(it))
                o['references'] = refs
                col_arr.append(o)
            dsl['columns'] = col_arr
        # ChartOfAccounts: признаки учёта.
        acct_flag_nodes = _nodes(child_objs, 'md:AccountingFlag')
        if len(acct_flag_nodes) > 0:
            arr = []
            for a in acct_flag_nodes:
                arr.append(attr_to_dsl(a))
            dsl['accountingFlags'] = arr
        ext_dim_flag_nodes = _nodes(child_objs, 'md:ExtDimensionAccountingFlag')
        if len(ext_dim_flag_nodes) > 0:
            arr = []
            for a in ext_dim_flag_nodes:
                arr.append(attr_to_dsl(a))
            dsl['extDimensionAccountingFlags'] = arr
        # Sequence: измерения несут DocumentMap/RegisterRecordsMap.
        dim_nodes = _nodes(child_objs, 'md:Dimension')
        if len(dim_nodes) > 0 and obj_type == 'Sequence':
            arr = []
            for dn in dim_nodes:
                dp = _single(dn, 'md:Properties')
                d_name = _text(_single(dp, 'md:Name'))
                o = {'name': d_name}
                d_syn = get_ml_value(_single(dp, 'md:Synonym'))
                if isinstance(d_syn, str):
                    if ne_cs(d_syn, split_camel_words(d_name)):
                        o['synonym'] = d_syn
                elif d_syn is not None:
                    o['synonym'] = d_syn
                d_cmt_n = _single(dp, 'md:Comment')
                if d_cmt_n is not None and _text(d_cmt_n):
                    o['comment'] = _text(d_cmt_n)
                dt = get_type_shorthand(_single(dp, 'md:Type'))
                if dt:
                    o['type'] = dt
                for mp in (('DocumentMap', 'documentMap'), ('RegisterRecordsMap', 'registerRecordsMap')):
                    mn = _single(dp, "md:" + mp[0])
                    if mn is not None:
                        m_items = [_text(x) for x in _nodes(mn, 'xr:Item')]
                        if len(m_items) > 0:
                            o[mp[1]] = list(m_items)
                arr.append(o)
            dsl['dimensions'] = arr
        elif len(dim_nodes) > 0:
            arr = []
            for a in dim_nodes:
                arr.append(attr_to_dsl(a))
            dsl['dimensions'] = arr
        res_nodes = _nodes(child_objs, 'md:Resource')
        if len(res_nodes) > 0:
            arr = []
            for a in res_nodes:
                arr.append(attr_to_dsl(a))
            dsl['resources'] = arr
        # Задача: реквизиты адресации.
        addr_nodes = _nodes(child_objs, 'md:AddressingAttribute')
        if len(addr_nodes) > 0:
            arr = []
            for a in addr_nodes:
                arr.append(attr_to_dsl(a))
            dsl['addressingAttributes'] = arr
        ts_nodes = _nodes(child_objs, 'md:TabularSection')
        if len(ts_nodes) > 0:
            ts_map = {}
            for ts in ts_nodes:
                tsp = _single(ts, 'md:Properties')
                ts_name = _text(_single(tsp, 'md:Name'))
                tco = _single(ts, 'md:ChildObjects')
                cols = []
                if tco is not None:
                    for ca in _nodes(tco, 'md:Attribute'):
                        cols.append(attr_to_dsl(ca))
                # Синоним/подсказка/комментарий ТЧ.
                ts_syn = get_ml_value(_single(tsp, 'md:Synonym'))
                ts_syn_custom = False
                if isinstance(ts_syn, str):
                    if ne_cs(ts_syn, split_camel_words(ts_name)):
                        ts_syn_custom = True
                elif ts_syn is not None:
                    ts_syn_custom = True
                ts_tt = get_ml_value(_single(tsp, 'md:ToolTip'))
                ts_cmt_n = _single(tsp, 'md:Comment')
                ts_cmt = _text(ts_cmt_n) if ts_cmt_n is not None else ''
                ts_fc_n = _single(tsp, 'md:FillChecking')
                ts_fc = _text(ts_fc_n) if (ts_fc_n is not None and _text(ts_fc_n) != 'DontCheck') else ''
                # Use ТЧ (иерархические Catalog/ПВХ: ForItem/ForFolder/ForFolderAndItem; omit при дефолте ForItem).
                ts_use_n = _single(tsp, 'md:Use')
                ts_use = _text(ts_use_n) if (ts_use_n is not None and _text(ts_use_n) != 'ForItem') else ''
                # TS-блок стандартных реквизитов (LineNumber).
                ln_obj = {}
                sa_ts_node = _single(tsp, 'md:StandardAttributes')
                has_block = (sa_ts_node is not None and len(_nodes(sa_ts_node, 'xr:StandardAttribute')) > 0)
                ln_node = _single(sa_ts_node, "xr:StandardAttribute[@name='LineNumber']") if has_block else None
                if ln_node is not None:
                    ln_syn = get_ml_value(_single(ln_node, 'xr:Synonym'))
                    if ln_syn is not None:
                        ln_obj['synonym'] = ln_syn
                    ln_cmt_n = _single(ln_node, 'xr:Comment')
                    if ln_cmt_n is not None and _text(ln_cmt_n):
                        ln_obj['comment'] = _text(ln_cmt_n)
                    ln_fts_n = _single(ln_node, 'xr:FullTextSearch')
                    if ln_fts_n is not None and _text(ln_fts_n) != 'Use':
                        ln_obj['fullTextSearch'] = _text(ln_fts_n)
                    ln_tt = get_ml_value(_single(ln_node, 'xr:ToolTip'))
                    if ln_tt is not None:
                        ln_obj['tooltip'] = ln_tt
                    ln_fmt = get_ml_value(_single(ln_node, 'xr:Format'))
                    if ln_fmt is not None:
                        ln_obj['format'] = ln_fmt
                    ln_efmt = get_ml_value(_single(ln_node, 'xr:EditFormat'))
                    if ln_efmt is not None:
                        ln_obj['editFormat'] = ln_efmt
                    ln_chi_n = _single(ln_node, 'xr:ChoiceHistoryOnInput')
                    if ln_chi_n is not None and _text(ln_chi_n) != 'Auto':
                        ln_obj['choiceHistoryOnInput'] = _text(ln_chi_n)
                    ln_fv_n = _single(ln_node, 'xr:FillValue')
                    if ln_fv_n is not None and _attr(ln_fv_n, 'nil', NS_XSI) != 'true':
                        ln_fv_t = _attr(ln_fv_n, 'type', NS_XSI)
                        if re.search(r'decimal$', ln_fv_t, re.I):
                            ln_obj['fillValue'] = int(_text(ln_fv_n)) if re.match(r'^-?\d+$', _text(ln_fv_n)) else float(_text(ln_fv_n))
                if ts_syn_custom or (ts_tt is not None) or ts_cmt or ts_fc or ts_use or len(ln_obj) > 0 or (not has_block):
                    to = {}
                    if ts_syn_custom:
                        to['synonym'] = ts_syn
                    if ts_tt is not None:
                        to['tooltip'] = ts_tt
                    if ts_cmt:
                        to['comment'] = ts_cmt
                    if ts_fc:
                        to['fillChecking'] = ts_fc
                    if ts_use:
                        to['use'] = ts_use
                    if not has_block:
                        to['lineNumber'] = ''
                    elif len(ln_obj) > 0:
                        to['lineNumber'] = ln_obj
                    to['attributes'] = cols
                    ts_map[ts_name] = to
                else:
                    ts_map[ts_name] = cols
            dsl['tabularSections'] = ts_map
        # --- Commands (полноблочные <Command> в ChildObjects) → DSL commands. ---
        cmd_nodes = _nodes(child_objs, 'md:Command')
        if len(cmd_nodes) > 0:
            cmd_map = {}
            for cm in cmd_nodes:
                cp = _single(cm, 'md:Properties')
                cn = _text(_single(cp, 'md:Name'))
                o = {}
                syn = get_ml_value(_single(cp, 'md:Synonym'))
                if isinstance(syn, str):
                    if ne_cs(syn, split_camel_words(cn)):
                        o['synonym'] = syn
                elif syn is not None:
                    o['synonym'] = syn
                cmt_n = _single(cp, 'md:Comment')
                if cmt_n is not None and _text(cmt_n):
                    o['comment'] = _text(cmt_n)
                grp_n = _single(cp, 'md:Group')
                if grp_n is not None and _text(grp_n):
                    o['group'] = _text(grp_n)
                cpt = get_type_shorthand(_single(cp, 'md:CommandParameterType'))
                if cpt:
                    o['commandParameterType'] = cpt
                pum_n = _single(cp, 'md:ParameterUseMode')
                if pum_n is not None and _text(pum_n) != 'Single':
                    o['parameterUseMode'] = _text(pum_n)
                md_n = _single(cp, 'md:ModifiesData')
                if md_n is not None and _text(md_n) == 'true':
                    o['modifiesData'] = True
                rep_n = _single(cp, 'md:Representation')
                if rep_n is not None and _text(rep_n) != 'Auto':
                    o['representation'] = _text(rep_n)
                ctt = get_ml_value(_single(cp, 'md:ToolTip'))
                if ctt is not None:
                    o['tooltip'] = ctt
                # <Picture> — структурный блок.
                ref_n = _single(cp, 'md:Picture/xr:Ref')
                abs_n = _single(cp, 'md:Picture/xr:Abs')
                if ref_n is not None or abs_n is not None:
                    psrc = _text(ref_n) if ref_n is not None else ("abs:" + _text(abs_n))
                    lt_n = _single(cp, 'md:Picture/xr:LoadTransparent')
                    lt_false = (lt_n is not None and _text(lt_n) == 'false')
                    tpx_n = _single(cp, 'md:Picture/xr:TransparentPixel')
                    if tpx_n is not None:
                        po = {'src': psrc}
                        if lt_false:
                            po['loadTransparent'] = False
                        po['transparentPixel'] = {'x': int(_attr(tpx_n, 'x')), 'y': int(_attr(tpx_n, 'y'))}
                        o['picture'] = po
                    else:
                        o['picture'] = psrc
                        if lt_false:
                            o['loadTransparent'] = False
                sc_n = _single(cp, 'md:Shortcut')
                if sc_n is not None and _text(sc_n):
                    o['shortcut'] = _text(sc_n)
                osu_n = _single(cp, 'md:OnMainServerUnavalableBehavior')
                if osu_n is not None and _text(osu_n) != 'Auto':
                    o['onMainServerUnavalableBehavior'] = _text(osu_n)
                cmd_map[cn] = o
            dsl['commands'] = cmd_map

    # --- Предопределённые (соседний Ext/Predefined.xml) → DSL predefined. ---
    obj_dir = os.path.dirname(os.path.abspath(object_path))
    predef_path = os.path.join(obj_dir, obj_name, 'Ext', 'Predefined.xml')
    if os.path.isfile(predef_path):
        pdoc = etree.parse(predef_path).getroot()
        root_items = []
        if obj_type == 'ChartOfAccounts':
            for it in _lxn(pdoc, "*[local-name()='Item']"):
                root_items.append(predef_account_to_dsl(it))
        elif obj_type == 'ChartOfCalculationTypes':
            for it in _lxn(pdoc, "*[local-name()='Item']"):
                root_items.append(predef_calc_type_to_dsl(it))
        else:
            for it in _lxn(pdoc, "*[local-name()='Item']"):
                root_items.append(predef_item_to_dsl(it))
        if len(root_items) > 0:
            dsl['predefined'] = root_items

    # --- Состав плана обмена (соседний Ext/Content.xml) → DSL content (ExchangePlan). ---
    if obj_type == 'ExchangePlan':
        content_path = os.path.join(obj_dir, obj_name, 'Ext', 'Content.xml')
        if os.path.isfile(content_path):
            cdoc = etree.parse(content_path).getroot()
            content_items = []
            for it in _lxn(cdoc, "*[local-name()='Item']"):
                md_el = _lx1(it, "*[local-name()='Metadata']")
                if md_el is None or not _text(md_el):
                    continue
                ref = _text(md_el)
                ar_el = _lx1(it, "*[local-name()='AutoRecord']")
                ar = _text(ar_el) if ar_el is not None else 'Deny'
                if ar == 'Allow':
                    content_items.append("%s: autoRecord" % ref)
                else:
                    content_items.append(ref)
            if len(content_items) > 0:
                dsl['content'] = content_items


SUPPORTED_TYPES = (
    'Catalog', 'ExchangePlan', 'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes', 'Document',
    'InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister', 'BusinessProcess', 'Task',
    'Enum', 'Report', 'DataProcessor', 'Constant', 'DefinedType', 'FunctionalOption', 'DocumentJournal', 'Sequence',
    'FilterCriterion', 'DocumentNumerator', 'SettingsStorage', 'CommonModule', 'EventSubscription', 'ScheduledJob',
    'CommonForm', 'SessionParameter', 'CommonCommand', 'CommandGroup', 'CommonAttribute', 'FunctionalOptionsParameter',
    'WSReference', 'CommonPicture', 'CommonTemplate',
)


def main():
    global props, obj_node, obj_type, obj_name, object_path

    parser = argparse.ArgumentParser(description='Decompile 1C metadata object XML to JSON DSL (draft)', allow_abbrev=False)
    parser.add_argument('-ObjectPath', '-Path', dest='ObjectPath', type=str, required=True)
    parser.add_argument('-OutputPath', dest='OutputPath', type=str, default=None)
    args = parser.parse_args()

    object_path = args.ObjectPath
    if not os.path.exists(object_path):
        sys.stderr.write("meta-decompile: файл не найден: %s\n" % object_path)
        sys.exit(2)

    # --- XML загрузка ---
    doc = etree.parse(object_path)
    root_el = doc.getroot()
    if _localname(root_el) != 'MetaDataObject':
        sys.stderr.write("meta-decompile: ожидался root <MetaDataObject>, получен <%s>\n" % _localname(root_el))
        sys.exit(3)
    # Первый элемент-потомок MetaDataObject = объект; его LocalName = тип.
    obj_node = None
    for c in root_el:
        if isinstance(c.tag, str):
            obj_node = c
            break
    if obj_node is None:
        sys.stderr.write("meta-decompile: пустой MetaDataObject\n")
        sys.exit(3)
    obj_type = _localname(obj_node)

    if obj_type not in SUPPORTED_TYPES:
        sys.stderr.write("meta-decompile: тип '%s' пока не поддержан (…, CommonPicture, CommonTemplate)\n" % obj_type)
        sys.exit(3)

    props = _single(obj_node, 'md:Properties')
    obj_name = P('Name')

    build_dsl()

    # === Вывод ===
    json_str = convert_to_compact_json(dsl, 0)
    if args.OutputPath:
        with open(args.OutputPath, 'w', encoding='utf-8', newline='') as f:
            f.write(json_str)
    else:
        sys.stdout.write(json_str + "\n")


if __name__ == '__main__':
    main()
