#!/usr/bin/env python3
# cfe-borrow v1.56 — Borrow objects from configuration into extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import html
import json
import os
import re
import shutil
import sys
import uuid
from lxml import etree

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.
def ci_parse_args(parser, argv=None):
    """parse_args по правилам PS: имена параметров и значения choices регистронезависимы."""
    argv = list(sys.argv[1:] if argv is None else argv)
    names = {s.lower(): s for a in parser._actions for s in a.option_strings}
    for i, tok in enumerate(argv):
        if tok.startswith('-') and tok.lower() in names:
            argv[i] = names[tok.lower()]
    # choices — зеркало [ValidateSet]; канонизируем ДО разбора, иначе argparse отвергнет регистр
    choice_map = {}
    for a in parser._actions:
        if a.choices:
            for s in a.option_strings:
                choice_map[s] = {str(c).lower(): c for c in a.choices}
    for i in range(len(argv) - 1):
        m = choice_map.get(argv[i])
        if m and argv[i + 1].lower() in m:
            argv[i + 1] = m[argv[i + 1].lower()]
    return parser.parse_args(argv)


MD_NS = "http://v8.1c.ru/8.3/MDClasses"
XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
V8_NS = "http://v8.1c.ru/8.1/data/core"

# Form data-binding tags (value = attribute path). A binding survives only if its root
# attribute is borrowed into the form's <Attributes>; otherwise it must be stripped or the
# platform rejects the form with "Неверный путь к данным" on load.
# RowPictureDataPath тоже путь к данным («Объект.Товары.РасхождениеЗаказ», «Список.DefaultPicture»),
# а не индекс картинки: эталон Конфигуратора сохраняет его с заимствованным основным реквизитом
# и выбрасывает без него — то же правило, что у остальных путей.
FORM_BINDING_DATA_TAGS = ["DataPath", "TitleDataPath", "FooterDataPath", "HeaderDataPath", "MultipleValueDataPath", "MultipleValuePresentDataPath", "RowPictureDataPath"]
# Picture-path binding tags (value = picture index path, never a data attribute) — always stripped in the skeleton.
FORM_BINDING_PICTURE_TAGS = ["MultipleValuePictureDataPath"]

# id основного реквизита в заимствованной форме — как у Конфигуратора
MAIN_ATTR_ID = "1000001"

# Виды дочерних объектов, которые заимствуются в оболочку поимённо (табличные части — отдельно)
CHILD_OBJECT_KINDS = ("Attribute", "Dimension", "Resource", "AddressingAttribute", "AccountingFlag", "ExtDimensionAccountingFlag")

# Виды подобъектов в -Object (Тип.Имя.<Вид>.<Имя>). Признак учёта субконто идёт только вместе с
# ТЧ видов субконто (свойства ExtDimensionTypes у оболочки) — по одному не заимствуется.
SUB_OBJECT_KINDS = ("Attribute", "TabularSection", "Dimension", "Resource", "AddressingAttribute", "AccountingFlag")
# Своя колонка в заимствованной ТЧ: у этих видов — отказ UpdateDBCfg на любой платформе, у БП и
# Задачи — ниже 8.3.25 (граница по версии платформы, не по режиму)
TS_OWN_COLUMNS_BLOCKED = ("ChartOfCharacteristicTypes", "ChartOfAccounts", "ChartOfCalculationTypes")
TS_OWN_COLUMNS_FROM_PLATFORM = {"BusinessProcess": "8.3.25", "Task": "8.3.25"}

# Прямые дети <Form>, которые в заимствованную форму не переносятся.
# Структурные секции: AutoCommandBar и ChildItems забираются отдельно, остальные выбрасываются целиком.
FORM_STRUCTURAL_SECTIONS = ("Events", "Attributes", "Commands", "Parameters", "CommandInterface")
# Свойства формы, значение которых — имя реквизита формы (реквизиты не заимствуются, ссылка повиснет).
FORM_ATTRIBUTE_REF_PROPS = ("ReportResult", "DetailsData", "VariantAppearance", "GroupList")


def strip_form_bindings(xml, main_attr_name):
    """Strip data-binding tags whose root attribute isn't borrowed.
    main_attr_name задан (BorrowMainAttribute): оставить привязки от его имени, остальные снять.
    Пусто (скелет без основного реквизита): снять все. Картиночные пути снимаются всегда."""
    for tag in FORM_BINDING_DATA_TAGS:
        if main_attr_name:
            # Оставить и «Список.Поле», и путь ровно на сам реквизит («Список» у таблицы формы)
            root = re.escape(main_attr_name)
            xml = re.sub(rf'\s*<{tag}>(?!{root}(\.|<))[^<]*</{tag}>', '', xml)
        else:
            xml = re.sub(rf'\s*<{tag}>[^<]*</{tag}>', '', xml)
    for tag in FORM_BINDING_PICTURE_TAGS:
        xml = re.sub(rf'\s*<{tag}>[^<]*</{tag}>', '', xml)
    return xml


def indent_for_base_form(xml, first_indent):
    """Сдвиг блока на уровень вглубь для <BaseForm>; first_indent — отступ первой строки.
    Таб добавляется только в пробельные промежутки между тегами: строки продолжения многострочного
    текста (<v8:content>, текст запроса) — часть значения. Со сдвигом снимок расходился с формой,
    и Конфигуратор показывал такой текст изменённым в расширении. Пробельный промежуток между
    открывающим и закрывающим тегом одного элемента — тоже значение, его не сдвигаем."""
    parts = re.split(r'''(<(?:[^>"']|"[^"]*"|'[^']*')*>)''', xml)
    for i in range(0, len(parts), 2):
        seg = parts[i]
        if '\n' not in seg or seg.strip():
            continue
        prev_tag = parts[i - 1] if i > 0 else ''
        next_tag = parts[i + 1] if i + 1 < len(parts) else ''
        m = re.match(r'<([\w:.-]+)[^>]*(?<!/)>$', prev_tag)
        if m and next_tag == f'</{m.group(1)}>':
            continue
        parts[i] = seg.replace('\n', '\n\t')
    return first_indent + ''.join(parts)


DROPPED_LINKS = []

# Связи формы — параметров выбора (<ChoiceParameterLinks>/<xr:Link>) и по типу (<TypeLink>) —
# хранят путь в <xr:DataPath>, обычным стриппингом он не снимается. Путь — внутренняя ссылка
# платформы: в выгрузке она пишет имя, а если имя в контексте формы не разрешается — код.
# Текстовое имя в расширении разрешается, только если его корень объявлен в <Attributes> самой
# заимствованной формы; иначе платформа отвергает загрузку — «Неверный путь к полю - X».
# Конфигуратор поэтому пишет текст там, где он разрешается, и код — где нет.
# Грамматика кода (оракул «код в форму конфигурации → загрузка → выгрузка → имя», 8.3.27; эталоны
# Конфигуратора УТ и Issue66Example4-7, JR2433, JR2976, JR49904):
#   первый сегмент  <id>                — реквизит ИСХОДНОЙ формы (в расширении реквизиты
#                                         перенумерованы в 1000000+, ссылка остаётся в нумерации базы);
#                   <id>:<CurrentData>  — элемент-таблица исходной формы, её текущая строка;
#   дальше          0:<uuid>            — реквизит/ТЧ/измерение/ресурс метаданных источника;
#                   <id>                — колонка реквизита формы;
#                   <id>:<AddColumn>    — колонка AdditionalColumns;
#                   -<k>                — стандартный реквизит, код по виду объекта (STD_FIELD_CODES).
# В расширении платформа код обратно в имя не переводит, а висячий код грузит молча — ошибка
# кодирования не упадёт, а тихо не сработает. Поэтому кодируется только измеренное; прочее
# вырезается с предупреждением: связь — удобство подбора, без неё форма работает, с неверной
# текстовой — не грузится вовсе.
LINK_CURRENT_DATA = '02023637-7868-4a5f-8576-835a76e0c9ba'
LINK_ADD_COLUMN = '5bdad865-f2c5-434b-8041-ba4aad3b6687'
# Коды стандартных реквизитов — свой порядок у каждого вида (оракул 8.3.27; в XML объекта
# полного списка нет). Незамеренное (-1, скрытые поля, колонки ExtDimensionTypes) — не кодируем.
STD_FIELD_CODES = {
    'Catalog': {'Code': -2, 'Description': -3, 'Parent': -4, 'Owner': -5, 'IsFolder': -6, 'DeletionMark': -7, 'Ref': -8, 'DataVersion': -9, 'Predefined': -10, 'PredefinedDataName': -13},
    'Document': {'Number': -2, 'Date': -3, 'DeletionMark': -4, 'Ref': -5, 'DataVersion': -6, 'Posted': -7, 'RegisterRecords': -8},
    'ChartOfCharacteristicTypes': {'Ref': -2, 'DataVersion': -3, 'DeletionMark': -4, 'Predefined': -5, 'Parent': -6, 'IsFolder': -7, 'Code': -8, 'Description': -9, 'ValueType': -11, 'PredefinedDataName': -14},
    'ChartOfAccounts': {'Ref': -2, 'DataVersion': -3, 'DeletionMark': -4, 'Predefined': -5, 'Parent': -6, 'Code': -7, 'Description': -8, 'Type': -10, 'OffBalance': -11, 'ExtDimensionTypes': -12, 'Order': -17, 'PredefinedDataName': -28},
    'ChartOfCalculationTypes': {'Code': -2, 'Description': -3, 'ActionPeriodIsBasic': -4, 'DeletionMark': -5, 'Ref': -6, 'DataVersion': -7, 'Predefined': -8, 'PredefinedDataName': -11, 'DisplacingCalculationTypes': -20, 'LeadingCalculationTypes': -30},
    'ExchangePlan': {'Code': -2, 'Description': -3, 'DeletionMark': -4, 'Ref': -6, 'DataVersion': -7, 'SentNo': -9, 'ReceivedNo': -10, 'ThisNode': -13, 'ExchangeDate': -14},
    'BusinessProcess': {'Number': -2, 'Date': -3, 'DeletionMark': -4, 'Ref': -5, 'DataVersion': -6, 'Completed': -7, 'HeadTask': -8, 'Started': -9},
    'Task': {'Number': -2, 'Date': -3, 'DeletionMark': -4, 'Ref': -5, 'DataVersion': -6, 'BusinessProcess': -7, 'RoutePoint': -8, 'Description': -9, 'Executed': -10},
    'InformationRegisterRecord': {'Period': -2, 'Recorder': -3, 'LineNumber': -4, 'Active': -5},
    'AccumulationRegisterRow': {'Period': -2, 'Recorder': -3, 'LineNumber': -4, 'Active': -5, 'RecordType': -9, 'SecondPeriod': -10, 'MinutePeriod': -11, 'HourPeriod': -12, 'DayPeriod': -13, 'WeekPeriod': -14, 'TenDaysPeriod': -15},
    'TabularSectionRow': {'LineNumber': -2},
}
# Тип основного реквизита → вид для таблицы стандартных кодов (запись РС — сам реквизит,
# набор записей РН — строка таблицы на нём)
MAIN_ATTR_KINDS = {
    'CatalogObject': 'Catalog', 'DocumentObject': 'Document', 'ChartOfCharacteristicTypesObject': 'ChartOfCharacteristicTypes',
    'ChartOfAccountsObject': 'ChartOfAccounts', 'ChartOfCalculationTypesObject': 'ChartOfCalculationTypes',
    'ExchangePlanObject': 'ExchangePlan', 'BusinessProcessObject': 'BusinessProcess', 'TaskObject': 'Task',
    'InformationRegisterRecordManager': 'InformationRegisterRecord', 'AccumulationRegisterRecordSet': 'AccumulationRegisterRow',
    'ConstantsSet': 'ConstantsSet',
}


def resolve_link_data_path(path, ctx):
    """Путь связи → текст (разрешается в расширении), код или None (вырезать).
    ctx: MainName, MainId, MainBorrowed, MainKind, BorrowedNames (реквизиты объекта в расширении;
    None — все), AttrUuids (имя/«ТЧ.Реквизит» → uuid),
    FormAttrIds, FormAttrCols («Реквизит.Колонка» → id), AddCols («<путь таблицы>.Колонка» → id),
    Tables (имя элемента-таблицы → {Id, Path})."""
    # Уже код (форма-источник сама из расширения, или висячая ссылка в типовой) — как есть
    if re.match(r'^-?\d', path):
        return path
    main = ctx['MainName']
    attr_uuids = ctx['AttrUuids']

    # Текущая строка элемента-таблицы
    cd = re.match(r'^Items\.([^.]+)\.CurrentData\.([^.]+)$', path)
    if cd:
        tbl = ctx['Tables'].get(cd.group(1))
        field = cd.group(2)
        if not tbl:
            return None
        tp = tbl['Path']
        prefix = f"{tbl['Id']}:{LINK_CURRENT_DATA}"
        if main and (tp == main or tp.startswith(main + '.')):
            # Таблица на основном реквизите: с заимствованным — текст разрешается (эталоны 7_1, УТ)
            if ctx['MainBorrowed']:
                return path
            if tp == main:
                # Строки самого основного реквизита — набор записей регистра накопления
                if ctx['MainKind'] != 'AccumulationRegisterRow':
                    return None
                if field in attr_uuids:
                    return f"{prefix}/0:{attr_uuids[field]}"
                code = STD_FIELD_CODES['AccumulationRegisterRow'].get(field)
                return f"{prefix}/{code}" if code else None
            ts = tp[len(main) + 1:]
            if '.' in ts:
                return None
            if f"{ts}.{field}" in attr_uuids:
                return f"{prefix}/0:{attr_uuids[ts + '.' + field]}"
            if f"{tp}.{field}" in ctx['AddCols']:
                return f"{prefix}/{ctx['AddCols'][tp + '.' + field]}:{LINK_ADD_COLUMN}"
            code = STD_FIELD_CODES['TabularSectionRow'].get(field)
            return f"{prefix}/{code}" if code else None
        # Таблица на реквизите формы: реквизиты формы не заимствуются никогда — только код
        # (текст платформа отвергает и с заимствованным основным реквизитом, оракул 8.3.27)
        if tp in ctx['FormAttrIds'] and f"{tp}.{field}" in ctx['FormAttrCols']:
            return f"{prefix}/{ctx['FormAttrCols'][tp + '.' + field]}"
        return None

    # Путь от основного реквизита формы
    if main and path.startswith(main + '.'):
        rest = path[len(main) + 1:]
        if ctx['MainBorrowed']:
            # Заимствованный реквизит объекта разрешается текстом и остаётся читаемым. Стандартное
            # поле («Объект.Owner», «Объект.Date») и реквизит, который в расширение не попал (в режиме
            # Form заимствуется только используемое формой) — нет: платформа отвергает «Неверный путь
            # к полю». Конфигуратор в обоих случаях ставит ссылку на сам основной реквизит (эталоны
            # Issue66Example7_1 и УТ Претензии.ФормаЭлементаСамообслуживание).
            borrowed = ctx['BorrowedNames'] is None or rest.split('.')[0] in ctx['BorrowedNames']
            if borrowed and rest in attr_uuids:
                return path
            return ctx['MainId']
        # Код пути на константу набора не измерен — такую связь вырезаем, а не кодируем наугад
        if ctx['MainKind'] == 'ConstantsSet':
            return None
        segs = rest.split('.')
        if len(segs) == 1:
            if rest in attr_uuids:
                return f"{ctx['MainId']}/0:{attr_uuids[rest]}"
            codes = STD_FIELD_CODES.get(ctx['MainKind']) if ctx['MainKind'] else None
            if codes and rest in codes:
                return f"{ctx['MainId']}/{codes[rest]}"
            return None
        if len(segs) == 2 and segs[0] in attr_uuids and rest in attr_uuids:
            return f"{ctx['MainId']}/0:{attr_uuids[segs[0]]}/0:{attr_uuids[rest]}"
        return None

    # Путь от реквизита формы — только по id исходной формы, в обоих режимах
    segs = path.split('.')
    if segs[0] in ctx['FormAttrIds']:
        attr_id = ctx['FormAttrIds'][segs[0]]
        if len(segs) == 1:
            return attr_id
        if len(segs) == 2 and path in ctx['FormAttrCols']:
            return f"{attr_id}/{ctx['FormAttrCols'][path]}"
        return None

    # Прочее: с заимствованным основным реквизитом текст может разрешиться, без него — нет
    if ctx['MainBorrowed']:
        return path
    return None


def rewrite_link_blocks(xml, block_pattern, ctx):
    """Путь в <xr:DataPath> блока связи → разрешённый; неразрешимый блок вырезается целиком."""
    def repl(m):
        link = m.group(0)
        dp = re.search(r'<xr:DataPath[^>]*>([^<]+)</xr:DataPath>', link)
        if not dp:
            return link
        path = dp.group(1)
        resolved = resolve_link_data_path(path, ctx)
        if resolved is None:
            DROPPED_LINKS.append(path)
            return ''
        if resolved == path:
            return link
        return link[:dp.start(1)] + resolved + link[dp.end(1):]

    return re.sub(block_pattern, repl, xml, flags=re.DOTALL)


def rewrite_choice_parameter_links(xml, ctx):
    if '<ChoiceParameterLinks>' not in xml:
        return xml
    xml = rewrite_link_blocks(xml, r'\s*<xr:Link>.*?</xr:Link>', ctx)
    # Опустевший контейнер платформе не нужен
    xml = re.sub(r'\s*<ChoiceParameterLinks>\s*</ChoiceParameterLinks>', '', xml, flags=re.DOTALL)
    return xml


def rewrite_type_links(xml, ctx):
    """Связь по типу — тот же путь и то же правило (эталоны УТ ВводОстатков.ФормаРасчетыМеждуОрганизациями:
    без основного реквизита — код, с ним — текст)."""
    if '<TypeLink>' not in xml:
        return xml
    return rewrite_link_blocks(xml, r'\s*<TypeLink>.*?</TypeLink>', ctx)


class CiNames(set):
    """Множество имён без учёта регистра — как хеш-таблица PS (@{}): имена 1С регистронезависимы."""

    def add(self, name):
        super().add(name.lower())

    def __contains__(self, name):
        return super().__contains__(name.lower())


def get_own_child_object_names(obj_file):
    """Имена ПРЯМЫХ детей собственного <ChildObjects> объекта — для дедупа при повторном
    заимствовании. Текстом это не снять: regex «первый <ChildObjects> до первого </ChildObjects>»
    у объекта с табличными частями обрывается на закрытии первой ТЧ, забирает имена её колонок и
    теряет то, что идёт после неё. Без учёта регистра, как хеш-таблица PS: имена 1С регистронезависимы."""
    names = CiNames()
    try:
        tree = etree.parse(obj_file)
    except Exception:
        return names
    root = tree.getroot()
    obj_el = next((c for c in root if isinstance(c.tag, str)), None)
    if obj_el is None:
        return names
    child_objs = next((c for c in obj_el if isinstance(c.tag, str) and localname(c) == "ChildObjects"), None)
    if child_objs is None:
        return names
    for child in child_objs:
        if not isinstance(child.tag, str):
            continue
        props = next((p for p in child if isinstance(p.tag, str) and localname(p) == "Properties"), None)
        if props is None:
            continue
        nm = next((n for n in props if isinstance(n.tag, str) and localname(n) == "Name"), None)
        if nm is not None and nm.text:
            names.add(nm.text.strip())
    return names


def object_child_order():
    """Порядок групп в <ChildObjects> объекта по виду. Это xs:sequence <Вид>ChildObjects из MDClasses XSD,
    сверенный выгрузкой платформы: выгрузка сама ставит группы в этот порядок, так что вставка не на место
    даёт дифф при следующей выгрузке. Единого порядка нет — у документа Form стоит до TabularSection."""
    return {
        "Catalog":                    ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "Document":                   ["Attribute", "Form", "TabularSection", "Template", "Command"],
        "ExchangePlan":               ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "ChartOfCharacteristicTypes": ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "ChartOfAccounts":            ["Attribute", "TabularSection", "AccountingFlag", "ExtDimensionAccountingFlag", "Form", "Template", "Command"],
        "ChartOfCalculationTypes":    ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "BusinessProcess":            ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "Task":                       ["Attribute", "TabularSection", "Form", "Template", "AddressingAttribute", "Command"],
        "DataProcessor":              ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "Report":                     ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "ExternalDataProcessor":      ["Attribute", "TabularSection", "Form", "Template"],
        "ExternalReport":             ["Attribute", "TabularSection", "Form", "Template"],
        "Enum":                       ["EnumValue", "Form", "Template", "Command"],
        "InformationRegister":        ["Resource", "Attribute", "Dimension", "Form", "Template", "Command"],
        "AccumulationRegister":       ["Resource", "Attribute", "Dimension", "Form", "Template", "Command"],
        "AccountingRegister":         ["Dimension", "Resource", "Attribute", "Form", "Template", "Command"],
        "CalculationRegister":        ["Resource", "Attribute", "Dimension", "Recalculation", "Form", "Template", "Command"],
        "DocumentJournal":            ["Column", "Form", "Template", "Command"],
        "Table":                      ["Field", "Form", "Command", "Template"],
        "ExternalDataSource":         ["Table", "Cube", "Function"],
        "Cube":                       ["DimensionTable", "Dimension", "Resource", "Form", "Command", "Template"],
        "DimensionTable":             ["Field", "Form", "Command", "Template"],
        "FilterCriterion":            ["Form", "Command"],
        "SettingsStorage":            ["Form", "Template"],
        "TabularSection":             ["Attribute"],
    }


def find_child_anchor(container, tag, obj_type):
    """Элемент <ChildObjects>, ПЕРЕД которым встаёт новый <tag>; None — дописать в конец.
    Сразу за последним элементом своего тега, иначе перед первым элементом группы, идущей
    по канону вида позже. Вид или тег вне канона — None, как раньше."""
    children = [c for c in container if isinstance(c.tag, str)]
    last_idx = -1
    for i, c in enumerate(children):
        if c.tag.rsplit('}', 1)[-1] == tag:
            last_idx = i
    if last_idx >= 0:
        return children[last_idx + 1] if last_idx + 1 < len(children) else None
    order = object_child_order().get(obj_type)
    if not order or tag not in order:
        return None
    later = order[order.index(tag) + 1:]
    for c in children:
        if c.tag.rsplit('}', 1)[-1] in later:
            return c
    return None


def insert_into_own_child_objects_by_canon(text, fragment, tag, obj_type):
    """Вставка ОДНОГО узла <tag> (fragment — с отступом прямого ребёнка) в СОБСТВЕННЫЙ <ChildObjects>
    объекта на место по канону вида — как find_child_anchor, только по тексту: за последним своим тегом,
    иначе перед первой группой, идущей по канону позже, иначе перед закрывающим тегом. Свой контейнер
    открывается первым (свойства объекта <ChildObjects> не содержат) и закрывается последним: вложенные
    <ChildObjects> табличных частей лежат внутри него, поиск «первого </ChildObjects>» уводил вставку в ТЧ.
    Прямые дети — по глубине вложенности, не по отступу. Строку с одним тегом дополняем целой строкой,
    перевод строки — из самого файла. None — своего <ChildObjects> у объекта нет."""
    eol = "\r\n" if "\r\n" in text else "\n"
    frag = fragment.rstrip().lstrip("\r\n").replace("\r\n", "\n").replace("\n", eol)
    m_open = re.search(r'<ChildObjects\b[^>]*?(/?)>', text)
    if not m_open:
        return None

    def line_indent(p):
        # Отступ строки до позиции p; None — перед p на строке есть что-то кроме пробелов
        ls = text.rfind("\n", 0, p) + 1
        return text[ls:p] if not text[ls:p].strip() else None

    if m_open.group(1):
        # Контейнер самозакрытый — детей у него нет, раскрыть с единственным узлом
        ind = line_indent(m_open.start()) or ""
        return text[:m_open.start()] + "<ChildObjects>" + eol + frag + eol + ind + "</ChildObjects>" + text[m_open.end():]
    m_close = None
    for m_close in re.finditer(r'</ChildObjects\s*>', text):
        pass
    if m_close is None or m_close.start() < m_open.end():
        return None
    starts = []
    depth = 0
    for m in re.finditer(r'<(/?)([\w:.-]+)[^>]*?(/?)>', text[m_open.end():m_close.start()]):
        if m.group(1):
            depth -= 1
            continue
        if depth == 0:
            starts.append((m_open.end() + m.start(), m.group(2).rsplit(':', 1)[-1]))
        if not m.group(3):
            depth += 1
    pos = m_close.start()
    last_idx = max((i for i, s in enumerate(starts) if s[1] == tag), default=-1)
    order = object_child_order().get(obj_type) or []
    if last_idx >= 0:
        if last_idx + 1 < len(starts):
            pos = starts[last_idx + 1][0]
    elif tag in order:
        later = order[order.index(tag) + 1:]
        pos = next((p for p, t in starts if t in later), pos)
    if line_indent(pos) is not None:
        ls = text.rfind("\n", 0, pos) + 1
        return text[:ls] + frag + eol + text[ls:]
    return text[:pos] + frag.lstrip() + text[pos:]


def insert_own_child_or_die(text, fragment, tag, obj_type, obj_file):
    """insert_into_own_child_objects_by_canon, но своего <ChildObjects> нет — создать его последним
    ребёнком элемента объекта; вставить всё равно некуда — отказ, а не молчаливое «добавлено»."""
    if not re.search(r'<ChildObjects\b', text):
        m_end = None
        for m_end in re.finditer(r'</' + re.escape(obj_type) + r'\s*>', text):
            pass
        if m_end:
            ls = text.rfind("\n", 0, m_end.start()) + 1
            pre = text[ls:m_end.start()]
            if not pre.strip():
                eol = "\r\n" if "\r\n" in text else "\n"
                text = text[:ls] + pre + "\t<ChildObjects/>" + eol + text[ls:]
            else:
                text = text[:m_end.start()] + "<ChildObjects/>" + text[m_end.start():]
    result = insert_into_own_child_objects_by_canon(text, fragment, tag, obj_type)
    if result is None:
        print(f"Cannot insert <{tag}>: no own <ChildObjects> in {obj_file}", file=sys.stderr)
        sys.exit(1)
    return result


def find_own_tabular_section_span(text, ts_name):
    """Блок <TabularSection> с именем ts_name среди прямых детей СОБСТВЕННОГО <ChildObjects> объекта:
    (start, end) в тексте, None — нет. Прямые дети — по глубине, как в insert_into_own_child_objects_by_canon;
    имя ТЧ — первый <Name> блока (в InternalInfo имён нет), без учёта регистра, как имена 1С. Реквизит с тем же
    именем — не ТЧ."""
    m_open = re.search(r'<ChildObjects\b[^>]*?(/?)>', text)
    if not m_open or m_open.group(1):
        return None
    closes = list(re.finditer(r'</ChildObjects\s*>', text))
    if not closes:
        return None
    body_start = m_open.end()
    body_end = closes[-1].start()
    if body_end < body_start:
        return None
    depth = 0
    ts_start = -1
    for m in re.finditer(r'<(/?)([\w:.-]+)[^>]*?(/?)>', text[body_start:body_end]):
        if m.group(1):
            depth -= 1
            if depth == 0 and ts_start >= 0:
                end = body_start + m.end()
                nm = re.search(r'<Name>([^<]*)</Name>', text[ts_start:end])
                if nm and nm.group(1).lower() == ts_name.lower():
                    return (ts_start, end)
                ts_start = -1
            continue
        if depth == 0:
            ts_start = body_start + m.start() if m.group(2) == "TabularSection" else -1
        if not m.group(3):
            depth += 1
    return None


def decode_numeric_entities(s):
    """lxml emits numeric character refs (&#xNNNN;) for non-ASCII in some self-closed
    elements where the PowerShell port writes literal characters. Normalize numeric refs
    back to literal so PS↔PY output matches. Named entities (&amp; &lt; ...) are left intact."""
    s = re.sub(r'&#x([0-9A-Fa-f]+);', lambda m: chr(int(m.group(1), 16)), s)
    s = re.sub(r'&#(\d+);', lambda m: chr(int(m.group(1))), s)
    return s


def _sg_find_v8project(start_dir):
    d = start_dir
    for _ in range(20):
        if not d:
            break
        pj = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pj):
            return pj
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def get_new_object_position(cfg_dir):
    """Куда навык ставит новую запись в <ChildObjects> — настройка newObjectPosition.

    databases[].newObjectPosition базы, чей configSrc охватывает каталог родительского XML,
    иначе корневое поле, иначе end. Значения: end — после последнего объекта того же вида
    (так дописывает Конфигуратор); byName — по имени среди объектов того же вида.
    Файл ищем от рабочего каталога вверх, каталог конфигурации — запасной путь: так же
    его ищут support-guard и группа db-*, а скрипт навыка зовут по абсолютному пути, и cwd
    остаётся рабочим каталогом проекта.
    configSrc считается от каталога .v8-project.json, как задокументировано в
    docs/v8-project-guide.md. Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(os.path.abspath(cfg_dir or "."))
        if not pj:
            return "end"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        proj_dir = os.path.dirname(pj)
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir or ".")).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src and db.get("newObjectPosition"):
                src_full = os.path.normcase(os.path.abspath(os.path.join(proj_dir, src))).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    return "byName" if str(db["newObjectPosition"]).lower() == "byname" else "end"
        if str(proj.get("newObjectPosition") or "").lower() == "byname":
            return "byName"
        return "end"
    except Exception:
        return "end"


def is_order_sensitive_type(type_name):
    """Виды, у которых порядок в дереве несёт смысл: автоматически их не упорядочиваем.

    CommonAttribute — исключение самого стандарта (#std467): у общих реквизитов-разделителей
    порядок в дереве задаёт порядок установки параметров сеанса. Subsystem и CommandGroup:
    пока они не перечислены в <SubsystemsOrder> / <GroupsOrder> файла Ext/CommandInterface.xml,
    порядок дерева задаёт порядок в интерфейсе, а платформа эти списки сама не заводит
    (в выгрузке ACC вне GroupsOrder 15 живых групп из 39). Language исключён из осторожности,
    без замера: языков обычно один-два, и в типовых их порядок не алфавитный.
    Явно названный вид сортируется в любом случае.
    Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    return type_name in ("CommonAttribute", "Subsystem", "CommandGroup", "Language")


def compare_metadata_names(a, b):
    """Порядок имён объектов метаданных, как в дереве Конфигуратора.

    Ключ — пары «ранг+символ»: регистр не учитывается, подчёркивание раньше цифр, цифры раньше
    букв, буквы по кодам (латиница раньше кириллицы), ё на месте е. Культурные таблицы не
    используются — они разные на разных ОС и в разных рантаймах, а так оба порта сравнивают
    одинаково везде. Равные ключи разводит ordinal-сравнение исходных строк.
    Возвращает -1 | 0 | 1. Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    keys = []
    for name in (a, b):
        parts = []
        for ch in name.lower():
            if ch == "ё":
                ch = "е"
            if ch.isdigit():
                parts.append("1" + ch)
            elif ch.isalpha():
                parts.append("2" + ch)
            else:
                parts.append("0" + ch)
        keys.append("".join(parts))
    if keys[0] != keys[1]:
        return -1 if keys[0] < keys[1] else 1
    if a != b:
        return -1 if a < b else 1
    return 0


def localname(el):
    return etree.QName(el.tag).localname


def info(msg):
    print(f"[INFO] {msg}")


def warn(msg):
    print(f"[WARN] {msg}")


# --- Type mappings ---
CHILD_TYPE_DIR_MAP = {
    "Catalog": "Catalogs", "Document": "Documents", "Enum": "Enums",
    "CommonModule": "CommonModules", "CommonPicture": "CommonPictures",
    "CommonCommand": "CommonCommands", "CommonTemplate": "CommonTemplates",
    "ExchangePlan": "ExchangePlans", "Report": "Reports", "DataProcessor": "DataProcessors",
    "InformationRegister": "InformationRegisters", "AccumulationRegister": "AccumulationRegisters",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfAccounts": "ChartsOfAccounts", "AccountingRegister": "AccountingRegisters",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes", "CalculationRegister": "CalculationRegisters",
    "BusinessProcess": "BusinessProcesses", "Task": "Tasks",
    "Subsystem": "Subsystems", "Role": "Roles", "Constant": "Constants",
    "FunctionalOption": "FunctionalOptions", "DefinedType": "DefinedTypes",
    "FunctionalOptionsParameter": "FunctionalOptionsParameters",
    "CommonForm": "CommonForms", "DocumentJournal": "DocumentJournals",
    "SessionParameter": "SessionParameters", "StyleItem": "StyleItems",
    "EventSubscription": "EventSubscriptions", "ScheduledJob": "ScheduledJobs",
    "SettingsStorage": "SettingsStorages", "FilterCriterion": "FilterCriteria",
    "CommandGroup": "CommandGroups", "DocumentNumerator": "DocumentNumerators",
    "Sequence": "Sequences", "ExternalDataSource": "ExternalDataSources", "IntegrationService": "IntegrationServices",
    "XDTOPackage": "XDTOPackages", "WebService": "WebServices",
    "HTTPService": "HTTPServices", "WSReference": "WSReferences",
    "CommonAttribute": "CommonAttributes", "Style": "Styles",
    "Bot": "Bots", "PaletteColor": "PaletteColors", "PaletteColor": "PaletteColors", "Language": "Languages",
}

# --- Модули заимствованных объектов ---
# Порядок внутри значения — порядок выгрузки Конфигуратора: сначала «объектный» модуль
# (ObjectModule / RecordSetModule / ValueManagerModule), затем ManagerModule.
MODULE_KINDS_BY_TYPE = {
    "CommonModule": ["Module"], "HTTPService": ["Module"], "WebService": ["Module"],
    "Catalog": ["ObjectModule", "ManagerModule"], "Document": ["ObjectModule", "ManagerModule"],
    "Report": ["ObjectModule", "ManagerModule"], "DataProcessor": ["ObjectModule", "ManagerModule"],
    "ExchangePlan": ["ObjectModule", "ManagerModule"],
    "ChartOfCharacteristicTypes": ["ObjectModule", "ManagerModule"],
    "ChartOfAccounts": ["ObjectModule", "ManagerModule"],
    "ChartOfCalculationTypes": ["ObjectModule", "ManagerModule"],
    "BusinessProcess": ["ObjectModule", "ManagerModule"], "Task": ["ObjectModule", "ManagerModule"],
    "InformationRegister": ["RecordSetModule", "ManagerModule"],
    "AccumulationRegister": ["RecordSetModule", "ManagerModule"],
    "AccountingRegister": ["RecordSetModule", "ManagerModule"],
    "CalculationRegister": ["RecordSetModule", "ManagerModule"],
    "Sequence": ["RecordSetModule", "ManagerModule"],
    "Constant": ["ValueManagerModule", "ManagerModule"],
    "Enum": ["ManagerModule"], "DocumentJournal": ["ManagerModule"],
    "FilterCriterion": ["ManagerModule"],
}
# Типы с ЕДИНСТВЕННЫМ модулем: ради него объект и заимствуют, поэтому файл создаётся молча.
# Отказ — `-Module None`.
AUTO_MODULE_TYPES = ["CommonModule", "HTTPService", "WebService"]
MODULE_KIND_NAMES = ["Module", "ObjectModule", "ManagerModule", "RecordSetModule", "ValueManagerModule"]

def query_key(s):
    """Ключ сравнения имён в тексте запроса: язык запросов регистронезависим, Ё и Е — одна буква."""
    return s.upper().replace('Ё', 'Е')


# Виды таблиц языка запросов (рус. и англ.) → вид метаданных. Ключи — через query_key.
QUERY_TABLE_KINDS = {}
for _ru, _en in (
    ("Справочник", "Catalog"), ("Документ", "Document"), ("Перечисление", "Enum"),
    ("ПланВидовХарактеристик", "ChartOfCharacteristicTypes"), ("ПланСчетов", "ChartOfAccounts"),
    ("ПланВидовРасчета", "ChartOfCalculationTypes"), ("ПланОбмена", "ExchangePlan"),
    ("БизнесПроцесс", "BusinessProcess"), ("Задача", "Task"),
    ("РегистрСведений", "InformationRegister"), ("РегистрНакопления", "AccumulationRegister"),
    ("РегистрБухгалтерии", "AccountingRegister"), ("РегистрРасчета", "CalculationRegister"),
    ("ЖурналДокументов", "DocumentJournal"), ("Константа", "Constant"),
    ("Последовательность", "Sequence"), ("КритерийОтбора", "FilterCriterion"),
    ("ВнешнийИсточникДанных", "ExternalDataSource"),
):
    QUERY_TABLE_KINDS[query_key(_ru)] = _en
    QUERY_TABLE_KINDS[query_key(_en)] = _en


# Ключевые слова языка запросов, которые могут стоять сразу за таблицей вместо псевдонима.
QUERY_ALIAS_STOP_WORDS = {query_key(_kw) for _kw in (
    "ГДЕ", "WHERE", "ЛЕВОЕ", "LEFT", "ПРАВОЕ", "RIGHT", "ПОЛНОЕ", "FULL", "ВНУТРЕННЕЕ", "INNER",
    "ВНЕШНЕЕ", "OUTER", "СОЕДИНЕНИЕ", "JOIN", "ПО", "ON", "СГРУППИРОВАТЬ", "GROUP", "УПОРЯДОЧИТЬ", "ORDER",
    "ИМЕЮЩИЕ", "HAVING", "ОБЪЕДИНИТЬ", "UNION", "ДЛЯ", "FOR", "ИТОГИ", "TOTALS", "ИНДЕКСИРОВАТЬ", "INDEX",
    "ИЗ", "FROM", "ВЫБРАТЬ", "SELECT", "И", "AND", "ИЛИ", "OR", "НЕ", "NOT", "КОГДА", "WHEN", "ТОГДА", "THEN",
    "ИНАЧЕ", "ELSE", "КОНЕЦ", "END", "ПОМЕСТИТЬ", "INTO", "ССЫЛКА", "REFS", "В", "IN", "МЕЖДУ", "BETWEEN",
    "ПОДОБНО", "LIKE", "ЕСТЬ", "IS", "ИЕРАРХИИ", "HIERARCHY", "ВОЗР", "ASC", "УБЫВ", "DESC", "АВТОУПОРЯДОЧИВАНИЕ",
    "AUTOORDER", "ИЗМЕНЕНИЯ", "UPDATE", "ВСЕ", "ALL")}

# Стандартные поля по видам объектов (рус. и англ.) — есть у таблицы без заимствования реквизитов.
# У каждого вида свои: Номер/Дата — стандартные у документа, а у справочника это обычные реквизиты,
# которых в оболочке нет. Неизвестный вид — только общие поля. Поля, которые включаются свойством
# объекта (Родитель, Владелец, Период регистра сведений…), — в QUERY_GATED_STD. Ключи — query_key.
_QS_COMMON = ("Ссылка", "Ref", "ПометкаУдаления", "DeletionMark", "Предопределенный", "Predefined",
              "ИмяПредопределенныхДанных", "PredefinedDataName", "ВерсияДанных", "DataVersion", "Представление",
              "Presentation", "DefaultPicture")
_QS_BY_KIND = {
    "Catalog": ("Код", "Code", "Наименование", "Description"),
    "Document": ("Номер", "Number", "Дата", "Date", "Проведен", "Posted", "МоментВремени", "PointInTime"),
    "ChartOfCharacteristicTypes": ("Код", "Code", "Наименование", "Description", "ТипЗначения", "ValueType"),
    "ChartOfAccounts": ("Код", "Code", "Наименование", "Description", "Родитель", "Parent", "Порядок", "Order", "Вид", "Type", "Забалансовый", "OffBalance"),
    "ChartOfCalculationTypes": ("Код", "Code", "Наименование", "Description"),
    "ExchangePlan": ("Код", "Code", "Наименование", "Description", "НомерОтправленного", "SentNo", "НомерПринятого", "ReceivedNo", "ЭтотУзел", "ThisNode"),
    "BusinessProcess": ("Номер", "Number", "Дата", "Date", "Завершен", "Completed", "Стартован", "Started", "ВедущаяЗадача", "HeadTask"),
    "Task": ("Номер", "Number", "Дата", "Date", "Наименование", "Description", "Выполнена", "Executed", "БизнесПроцесс", "BusinessProcess", "ТочкаМаршрута", "RoutePoint"),
    "Enum": ("Порядок", "Order"),
    "DocumentJournal": ("Номер", "Number", "Дата", "Date", "Проведен", "Posted", "Тип", "Type"),
    "InformationRegister": (),
    "AccumulationRegister": ("Период", "Period", "Регистратор", "Recorder", "НомерСтроки", "LineNumber", "Активность", "Active", "ВидДвижения", "RecordType"),
    "AccountingRegister": ("Период", "Period", "Регистратор", "Recorder", "НомерСтроки", "LineNumber", "Активность", "Active"),
    "CalculationRegister": ("Регистратор", "Recorder", "НомерСтроки", "LineNumber", "Активность", "Active"),
}
QUERY_STD_COMMON = {query_key(_sf) for _sf in _QS_COMMON}
QUERY_STD_BY_KIND = {_k: {query_key(_sf) for _sf in _QS_COMMON + _v} for _k, _v in _QS_BY_KIND.items()}


# Стандартные поля, которые есть, только если это включено свойством объекта: у заимствованного
# объекта в расширении их нет, пока свойства нет в его копии (замер 8.3.24: Родитель у иерархического
# справочника на оболочке без <Hierarchical> — «Неверный путь к данным»; Код, Наименование — есть).
QUERY_GATED_STD = {}
for _kind, _gate, _fields in (
    ("Catalog", "Hierarchical", ("Родитель", "Parent", "ЭтоГруппа", "IsFolder")),
    ("ChartOfCharacteristicTypes", "Hierarchical", ("Родитель", "Parent", "ЭтоГруппа", "IsFolder")),
    ("Catalog", "Owners", ("Владелец", "Owner")),
    ("InformationRegister", "Periodic", ("Период", "Period")),
    ("InformationRegister", "Recorder", ("Регистратор", "Recorder", "НомерСтроки", "LineNumber", "Активность", "Active")),
):
    for _f in _fields:
        QUERY_GATED_STD[f"{_kind}|{query_key(_f)}"] = _gate


def test_query_std_field(info_, field_key):
    gate = QUERY_GATED_STD.get(f"{info_['Kind']}|{field_key}")
    if gate:
        return bool(info_['Gates'].get(gate))
    if info_['Kind'] in QUERY_STD_BY_KIND:
        return field_key in QUERY_STD_BY_KIND[info_['Kind']]
    return field_key in QUERY_STD_COMMON


# Поля таблицы — только данные: команды, формы, макеты и т.п. полями не бывают
QUERY_FIELD_KINDS = ('Attribute', 'Dimension', 'Resource', 'TabularSection', 'AddressingAttribute',
                     'AccountingFlag', 'ExtDimensionAccountingFlag', 'Column', 'EnumValue')


# Зарезервированные слова языка запросов — полем быть не могут: стоп-слова псевдонима плюс
# литералы и модификаторы. Имена типов (СТРОКА, ДАТА…) и периодов (МЕСЯЦ, ГОД…) сюда не входят:
# это бывают и имена полей. Тип пропускается по позиции — после КАК, как всякое определение
# псевдонима; период — аргументом после запятой внутри скобок (НАЧАЛОПЕРИОДА(Д.Дата, МЕСЯЦ)).
QUERY_RESERVED_WORDS = set(QUERY_ALIAS_STOP_WORDS) | {query_key(_kw) for _kw in (
    "КАК", "AS", "РАЗРЕШЕННЫЕ", "ALLOWED", "РАЗЛИЧНЫЕ", "DISTINCT", "ПЕРВЫЕ", "TOP", "NULL", "ИСТИНА",
    "TRUE", "ЛОЖЬ", "FALSE", "НЕОПРЕДЕЛЕНО", "UNDEFINED", "ВЫБОР", "CASE", "СПЕЦСИМВОЛ", "ESCAPE", "BY",
    "ИЕРАРХИЯ", "ОБЩИЕ", "OVERALL", "ПЕРИОДАМИ", "PERIODS", "УНИЧТОЖИТЬ", "DROP", "ГРУППИРУЮЩИМ", "НАБОРАМ",
    "GROUPING", "SETS")}
QUERY_PERIOD_NAMES = {query_key(_kw) for _kw in (
    "СЕКУНДА", "SECOND", "МИНУТА", "MINUTE", "ЧАС", "HOUR", "ДЕНЬ", "DAY", "НЕДЕЛЯ", "WEEK",
    "МЕСЯЦ", "MONTH", "КВАРТАЛ", "QUARTER", "ГОД", "YEAR", "ДЕКАДА", "TENDAYS", "ПОЛУГОДИЕ", "HALFYEAR", "АВТО", "AUTO")}
RE_TABLE_ALIAS = re.compile(r'(?:(КАК|AS)\s+)?([^\W\d]\w*)', re.IGNORECASE)
RE_FUNC_PAREN = re.compile(r'\s*\(')
# Слова, после которых в запросе стоит таблица-источник
QUERY_SOURCE_KEYWORDS = {query_key(_kw) for _kw in ("ИЗ", "FROM", "СОЕДИНЕНИЕ", "JOIN")}


def get_ref_kind_from_type(type_text):
    """Ссылочный тип → вид метаданных: CatalogRef → Catalog и т.п. (у DefinedType и прочих — None)."""
    t = type_text.strip()
    ci = t.find(':')
    if ci >= 0:
        t = t[ci + 1:]
    m = re.match(r'^(\w+)Ref\.(\w+)$', t)
    return {'Kind': m.group(1), 'Name': m.group(2)} if m else None


SYNONYM_MAP = {
    "\u0421\u043f\u0440\u0430\u0432\u043e\u0447\u043d\u0438\u043a": "Catalog",
    "\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442": "Document",
    "\u041f\u0435\u0440\u0435\u0447\u0438\u0441\u043b\u0435\u043d\u0438\u0435": "Enum",
    "\u041e\u0431\u0449\u0438\u0439\u041c\u043e\u0434\u0443\u043b\u044c": "CommonModule",
    "\u041e\u0431\u0449\u0430\u044f\u041a\u0430\u0440\u0442\u0438\u043d\u043a\u0430": "CommonPicture",
    "\u041e\u0431\u0449\u0430\u044f\u041a\u043e\u043c\u0430\u043d\u0434\u0430": "CommonCommand",
    "\u041e\u0431\u0449\u0438\u0439\u041c\u0430\u043a\u0435\u0442": "CommonTemplate",
    "\u041f\u043b\u0430\u043d\u041e\u0431\u043c\u0435\u043d\u0430": "ExchangePlan",
    "\u041e\u0442\u0447\u0435\u0442": "Report",
    "\u041e\u0442\u0447\u0451\u0442": "Report",
    "\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430": "DataProcessor",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0421\u0432\u0435\u0434\u0435\u043d\u0438\u0439": "InformationRegister",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u041d\u0430\u043a\u043e\u043f\u043b\u0435\u043d\u0438\u044f": "AccumulationRegister",
    "\u041f\u043b\u0430\u043d\u0412\u0438\u0434\u043e\u0432\u0425\u0430\u0440\u0430\u043a\u0442\u0435\u0440\u0438\u0441\u0442\u0438\u043a": "ChartOfCharacteristicTypes",
    "\u041f\u043b\u0430\u043d\u0421\u0447\u0435\u0442\u043e\u0432": "ChartOfAccounts",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0411\u0443\u0445\u0433\u0430\u043b\u0442\u0435\u0440\u0438\u0438": "AccountingRegister",
    "\u041f\u043b\u0430\u043d\u0412\u0438\u0434\u043e\u0432\u0420\u0430\u0441\u0447\u0435\u0442\u0430": "ChartOfCalculationTypes",
    "\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0420\u0430\u0441\u0447\u0435\u0442\u0430": "CalculationRegister",
    "\u0411\u0438\u0437\u043d\u0435\u0441\u041f\u0440\u043e\u0446\u0435\u0441\u0441": "BusinessProcess",
    "\u0417\u0430\u0434\u0430\u0447\u0430": "Task",
    "\u041f\u043e\u0434\u0441\u0438\u0441\u0442\u0435\u043c\u0430": "Subsystem",
    "\u0420\u043e\u043b\u044c": "Role",
    "\u041a\u043e\u043d\u0441\u0442\u0430\u043d\u0442\u0430": "Constant",
    "\u0424\u0443\u043d\u043a\u0446\u0438\u043e\u043d\u0430\u043b\u044c\u043d\u0430\u044f\u041e\u043f\u0446\u0438\u044f": "FunctionalOption",
    "\u041e\u043f\u0440\u0435\u0434\u0435\u043b\u044f\u0435\u043c\u044b\u0439\u0422\u0438\u043f": "DefinedType",
    "\u041e\u0431\u0449\u0430\u044f\u0424\u043e\u0440\u043c\u0430": "CommonForm",
    "\u0416\u0443\u0440\u043d\u0430\u043b\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u043e\u0432": "DocumentJournal",
    "\u041f\u0430\u0440\u0430\u043c\u0435\u0442\u0440\u0421\u0435\u0430\u043d\u0441\u0430": "SessionParameter",
    "\u0413\u0440\u0443\u043f\u043f\u0430\u041a\u043e\u043c\u0430\u043d\u0434": "CommandGroup",
    "\u041f\u043e\u0434\u043f\u0438\u0441\u043a\u0430\u041d\u0430\u0421\u043e\u0431\u044b\u0442\u0438\u0435": "EventSubscription",
    "\u0420\u0435\u0433\u043b\u0430\u043c\u0435\u043d\u0442\u043d\u043e\u0435\u0417\u0430\u0434\u0430\u043d\u0438\u0435": "ScheduledJob",
    "\u041e\u0431\u0449\u0438\u0439\u0420\u0435\u043a\u0432\u0438\u0437\u0438\u0442": "CommonAttribute",
    "\u041f\u0430\u043a\u0435\u0442XDTO": "XDTOPackage",
    "HTTP\u0421\u0435\u0440\u0432\u0438\u0441": "HTTPService",
    "\u0421\u0435\u0440\u0432\u0438\u0441\u0418\u043d\u0442\u0435\u0433\u0440\u0430\u0446\u0438\u0438": "IntegrationService",
}

TYPE_ORDER = [
    "Language", "Subsystem", "StyleItem", "Style",
    "CommonPicture", "SessionParameter", "Role", "CommonTemplate",
    "FilterCriterion", "CommonModule", "CommonAttribute", "ExchangePlan",
    "XDTOPackage", "WebService", "HTTPService", "WSReference",
    "EventSubscription", "ScheduledJob", "SettingsStorage", "FunctionalOption",
    "FunctionalOptionsParameter", "DefinedType", "Bot", "PaletteColor", "CommonCommand", "CommandGroup",
    "Constant", "CommonForm", "Catalog", "Document",
    "DocumentNumerator", "Sequence", "DocumentJournal", "Enum",
    "Report", "DataProcessor", "InformationRegister", "AccumulationRegister",
    "ChartOfCharacteristicTypes", "ChartOfAccounts", "AccountingRegister",
    "ChartOfCalculationTypes", "CalculationRegister",
    "BusinessProcess", "Task", "ExternalDataSource", "IntegrationService",
]

GENERATED_TYPES = {
    "Catalog": [
        {"prefix": "CatalogObject", "category": "Object"},
        {"prefix": "CatalogRef", "category": "Ref"},
        {"prefix": "CatalogSelection", "category": "Selection"},
        {"prefix": "CatalogList", "category": "List"},
        {"prefix": "CatalogManager", "category": "Manager"},
    ],
    "Document": [
        {"prefix": "DocumentObject", "category": "Object"},
        {"prefix": "DocumentRef", "category": "Ref"},
        {"prefix": "DocumentSelection", "category": "Selection"},
        {"prefix": "DocumentList", "category": "List"},
        {"prefix": "DocumentManager", "category": "Manager"},
    ],
    "Enum": [
        {"prefix": "EnumRef", "category": "Ref"},
        {"prefix": "EnumManager", "category": "Manager"},
        {"prefix": "EnumList", "category": "List"},
    ],
    "Constant": [
        {"prefix": "ConstantManager", "category": "Manager"},
        {"prefix": "ConstantValueManager", "category": "ValueManager"},
        {"prefix": "ConstantValueKey", "category": "ValueKey"},
    ],
    "InformationRegister": [
        {"prefix": "InformationRegisterRecord", "category": "Record"},
        {"prefix": "InformationRegisterManager", "category": "Manager"},
        {"prefix": "InformationRegisterSelection", "category": "Selection"},
        {"prefix": "InformationRegisterList", "category": "List"},
        {"prefix": "InformationRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "InformationRegisterRecordKey", "category": "RecordKey"},
        {"prefix": "InformationRegisterRecordManager", "category": "RecordManager"},
    ],
    "AccumulationRegister": [
        {"prefix": "AccumulationRegisterRecord", "category": "Record"},
        {"prefix": "AccumulationRegisterManager", "category": "Manager"},
        {"prefix": "AccumulationRegisterSelection", "category": "Selection"},
        {"prefix": "AccumulationRegisterList", "category": "List"},
        {"prefix": "AccumulationRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "AccumulationRegisterRecordKey", "category": "RecordKey"},
    ],
    "AccountingRegister": [
        {"prefix": "AccountingRegisterRecord", "category": "Record"},
        {"prefix": "AccountingRegisterExtDimensions", "category": "ExtDimensions"},
        {"prefix": "AccountingRegisterManager", "category": "Manager"},
        {"prefix": "AccountingRegisterSelection", "category": "Selection"},
        {"prefix": "AccountingRegisterList", "category": "List"},
        {"prefix": "AccountingRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "AccountingRegisterRecordKey", "category": "RecordKey"},
    ],
    "CalculationRegister": [
        {"prefix": "CalculationRegisterRecord", "category": "Record"},
        {"prefix": "CalculationRegisterManager", "category": "Manager"},
        {"prefix": "CalculationRegisterSelection", "category": "Selection"},
        {"prefix": "CalculationRegisterList", "category": "List"},
        {"prefix": "CalculationRegisterRecordSet", "category": "RecordSet"},
        {"prefix": "CalculationRegisterRecordKey", "category": "RecordKey"},
        {"prefix": "RecalculationsManager", "category": "Recalcs"},
    ],
    "ChartOfAccounts": [
        {"prefix": "ChartOfAccountsObject", "category": "Object"},
        {"prefix": "ChartOfAccountsRef", "category": "Ref"},
        {"prefix": "ChartOfAccountsSelection", "category": "Selection"},
        {"prefix": "ChartOfAccountsList", "category": "List"},
        {"prefix": "ChartOfAccountsManager", "category": "Manager"},
        {"prefix": "ChartOfAccountsExtDimensionTypes", "category": "ExtDimensionTypes"},
        {"prefix": "ChartOfAccountsExtDimensionTypesRow", "category": "ExtDimensionTypesRow"},
    ],
    "ChartOfCharacteristicTypes": [
        {"prefix": "ChartOfCharacteristicTypesObject", "category": "Object"},
        {"prefix": "ChartOfCharacteristicTypesRef", "category": "Ref"},
        {"prefix": "ChartOfCharacteristicTypesSelection", "category": "Selection"},
        {"prefix": "ChartOfCharacteristicTypesList", "category": "List"},
        {"prefix": "Characteristic", "category": "Characteristic"},
        {"prefix": "ChartOfCharacteristicTypesManager", "category": "Manager"},
    ],
    "ChartOfCalculationTypes": [
        {"prefix": "ChartOfCalculationTypesObject", "category": "Object"},
        {"prefix": "ChartOfCalculationTypesRef", "category": "Ref"},
        {"prefix": "ChartOfCalculationTypesSelection", "category": "Selection"},
        {"prefix": "ChartOfCalculationTypesList", "category": "List"},
        {"prefix": "ChartOfCalculationTypesManager", "category": "Manager"},
        {"prefix": "DisplacingCalculationTypes", "category": "DisplacingCalculationTypes"},
        {"prefix": "DisplacingCalculationTypesRow", "category": "DisplacingCalculationTypesRow"},
        {"prefix": "BaseCalculationTypes", "category": "BaseCalculationTypes"},
        {"prefix": "BaseCalculationTypesRow", "category": "BaseCalculationTypesRow"},
        {"prefix": "LeadingCalculationTypes", "category": "LeadingCalculationTypes"},
        {"prefix": "LeadingCalculationTypesRow", "category": "LeadingCalculationTypesRow"},
    ],
    "BusinessProcess": [
        {"prefix": "BusinessProcessObject", "category": "Object"},
        {"prefix": "BusinessProcessRef", "category": "Ref"},
        {"prefix": "BusinessProcessSelection", "category": "Selection"},
        {"prefix": "BusinessProcessList", "category": "List"},
        {"prefix": "BusinessProcessManager", "category": "Manager"},
        {"prefix": "BusinessProcessRoutePointRef", "category": "RoutePointRef"},
    ],
    "Task": [
        {"prefix": "TaskObject", "category": "Object"},
        {"prefix": "TaskRef", "category": "Ref"},
        {"prefix": "TaskSelection", "category": "Selection"},
        {"prefix": "TaskList", "category": "List"},
        {"prefix": "TaskManager", "category": "Manager"},
    ],
    "ExchangePlan": [
        {"prefix": "ExchangePlanObject", "category": "Object"},
        {"prefix": "ExchangePlanRef", "category": "Ref"},
        {"prefix": "ExchangePlanSelection", "category": "Selection"},
        {"prefix": "ExchangePlanList", "category": "List"},
        {"prefix": "ExchangePlanManager", "category": "Manager"},
    ],
    "DocumentJournal": [
        {"prefix": "DocumentJournalSelection", "category": "Selection"},
        {"prefix": "DocumentJournalList", "category": "List"},
        {"prefix": "DocumentJournalManager", "category": "Manager"},
    ],
    "Report": [
        {"prefix": "ReportObject", "category": "Object"},
        {"prefix": "ReportManager", "category": "Manager"},
    ],
    "DataProcessor": [
        {"prefix": "DataProcessorObject", "category": "Object"},
        {"prefix": "DataProcessorManager", "category": "Manager"},
    ],
    "DefinedType": [
        {"prefix": "DefinedType", "category": "DefinedType"},
    ],
    "ExternalDataSource": [
        {"prefix": "ExternalDataSourceManager", "category": "Manager"},
        {"prefix": "ExternalDataSourceTablesManager", "category": "TablesManager"},
        {"prefix": "ExternalDataSourceCubesManager", "category": "CubesManager"},
    ],
    "Sequence": [
        {"prefix": "SequenceRecord", "category": "Record"},
        {"prefix": "SequenceManager", "category": "Manager"},
        {"prefix": "SequenceRecordSet", "category": "RecordSet"},
    ],
    "FilterCriterion": [
        {"prefix": "FilterCriterionManager", "category": "Manager"},
        {"prefix": "FilterCriterionList", "category": "List"},
    ],
    "SettingsStorage": [
        {"prefix": "SettingsStorageManager", "category": "Manager"},
    ],
    "IntegrationService": [
        {"prefix": "IntegrationServiceManager", "category": "Manager"},
    ],
    "WSReference": [
        {"prefix": "WSReferenceManager", "category": "Manager"},
    ],
}

# Types that need ChildObjects element — fallback when the source object cannot be probed.
# The platform emits <ChildObjects> for every container type even when empty, and rejects
# the file without it ("expected ChildObjects"); primary signal is the source object itself.
TYPES_WITH_CHILD_OBJECTS = [
    "Catalog", "Document", "ExchangePlan", "ChartOfAccounts",
    "ChartOfCharacteristicTypes", "ChartOfCalculationTypes",
    "BusinessProcess", "Task", "Enum",
    "InformationRegister", "AccumulationRegister", "AccountingRegister", "CalculationRegister",
    "DataProcessor", "Report", "DocumentJournal", "FilterCriterion", "SettingsStorage",
    "Sequence", "HTTPService", "WebService", "IntegrationService", "Subsystem",
]

COMMON_MODULE_PROPS = ["Global", "ClientManagedApplication", "Server", "ExternalConnection", "ClientOrdinaryApplication", "ServerCall"]

# Свойства объекта, от которых зависит существование стандартного поля: без них платформа
# отвергает загрузку — «Неверный путь к данным». Конфигуратор переносит ровно их (эталоны
# Issue66Example7_1 и Issue66Example2). Проверено сплошным прогоном по типам: у регистра
# сведений без InformationRegisterPeriodicity не разрешается «Запись.Period».
# Тем же путём переносится код языка: платформа принимает заимствованный язык и без него, но
# конфигуратор пишет LanguageCode у любого заимствованного языка, основного и неосновного (замер 8.3.24).
TYPE_GATE_PROPS = {
    "InformationRegister": ["InformationRegisterPeriodicity", "WriteMode"],
    "Language": ["LanguageCode"],
}
# Владельцы справочника — список <xr:Item>, а не скаляр: переносится фрагментом, как __TypeXml
TYPES_WITH_OWNERS = ("Catalog", "ChartOfCharacteristicTypes")

# Standard system fields to skip when collecting DataPath references
STANDARD_FIELDS = [
    "Code", "Description", "Ref", "Parent", "DeletionMark",
    "Predefined", "IsFolder", "LineNumber", "RowsCount", "PredefinedDataName",
]

XMLNS_DECL = (
    'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
    'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" '
    'xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" '
    'xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" '
    'xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" '
    'xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" '
    'xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" '
    'xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
)


def detect_format_version(d):
    while d:
        # Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
        # корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
        ext_path = d + ".xml"
        if os.path.isfile(ext_path):
            with open(ext_path, "r", encoding="utf-8-sig") as f:
                ext_head = f.read(2000)
            if re.search(r'<(ExternalDataProcessor|ExternalReport)[ >]', ext_head):
                m = re.search(r'<MetaDataObject[^>]+version="(\d+\.\d+)"', ext_head)
                if m:
                    return m.group(1)
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


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


# --- Пометка расширенного свойства (<xr:PropertyState>) ---
# Свойство появилось в формате 2.19 (8.3.26): на 2.18 и ниже платформа молча выбрасывает элемент
# при загрузке. С 2.19 Конфигуратор ставит его сам при выгрузке. Правило: флаг ставит тот, кто
# создал файл модуля, — здесь это мы. Имя свойства = базовое имя файла модуля.
# Копии этих функций есть в cfe-patch-method (навыки автономны); держать их одинаковыми — сознательно.
def build_property_state_xml(property_name, indent):
    return "\n".join([
        f"{indent}<xr:PropertyState>",
        f"{indent}\t<xr:Property>{property_name}</xr:Property>",
        f"{indent}\t<xr:State>Extended</xr:State>",
        f"{indent}</xr:PropertyState>",
    ])


def set_property_state_flag(obj_file, property_name, format_version):
    if format_rank(format_version) < 219:
        return
    if not os.path.isfile(obj_file):
        return

    with open(obj_file, "r", encoding="utf-8-sig", newline="") as fh:
        text = fh.read()
    nl = "\r\n" if "\r\n" in text else "\n"

    # ПЕРВЫЙ <InternalInfo> в файле — собственный у объекта: у реквизитов и подобъектов свои,
    # но они лежат ниже, внутри <ChildObjects>.
    empty = re.search(r"([ \t]*)<InternalInfo\s*/>", text)
    opened = re.search(r"([ \t]*)<InternalInfo>(.*?)</InternalInfo>", text, re.S)

    if empty and (not opened or empty.start() < opened.start()):
        ind = empty.group(1)
        block = build_property_state_xml(property_name, ind + "\t")
        replacement = f"{ind}<InternalInfo>{nl}{block}{nl}{ind}</InternalInfo>"
        text = text[:empty.start()] + replacement + text[empty.end():]
    elif opened:
        if re.search(rf"<xr:Property>{re.escape(property_name)}</xr:Property>", opened.group(2)):
            return
        ind = opened.group(1)
        block = build_property_state_xml(property_name, ind + "\t")
        # Дописываем в КОНЕЦ InternalInfo: у Конфигуратора PropertyState идёт после GeneratedType.
        close_at = opened.end() - len("</InternalInfo>") - len(ind)
        text = text[:close_at] + block + nl + text[close_at:]
    else:
        return

    with open(obj_file, "w", encoding="utf-8-sig", newline="") as fh:
        fh.write(text)


def apply_pal_ns(format_version):
    """2.21 (8.5) добавила в шапку пространство палитры — ради <Color> у значений перечисления.
    Вставляем НА МЕСТО (после lf, перед style): платформа держит объявления по алфавиту,
    дописать в конец нельзя."""
    global XMLNS_DECL
    if format_rank(format_version) >= 221:
        XMLNS_DECL = XMLNS_DECL.replace(
            ' xmlns:style=',
            ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')


def get_child_indent(container):
    if container.text and "\n" in container.text:
        after_nl = container.text.rsplit("\n", 1)[-1]
        if after_nl and not after_nl.strip():
            return after_nl
    for child in container:
        if child.tail and "\n" in child.tail:
            after_nl = child.tail.rsplit("\n", 1)[-1]
            if after_nl and not after_nl.strip():
                return after_nl
    depth = 0
    current = container
    while current is not None:
        depth += 1
        current = current.getparent()
    return "\t" * depth


def insert_before_closing(container, new_el, child_indent):
    children = list(container)
    if len(children) == 0:
        parent_indent = child_indent[:-1] if len(child_indent) > 0 else ""
        container.text = "\r\n" + child_indent
        new_el.tail = "\r\n" + parent_indent
        container.append(new_el)
    else:
        last = children[-1]
        new_el.tail = last.tail
        last.tail = "\r\n" + child_indent
        container.append(new_el)


def insert_before_ref(container, new_el, ref_el, child_indent):
    idx = list(container).index(ref_el)
    prev = ref_el.getprevious()
    if prev is not None:
        new_el.tail = prev.tail
        prev.tail = "\r\n" + child_indent
    else:
        new_el.tail = container.text
        container.text = "\r\n" + child_indent
    container.insert(idx, new_el)


def expand_self_closing(container, parent_indent):
    if len(container) == 0 and not (container.text and container.text.strip()):
        container.text = "\r\n" + parent_indent


def _detect_xml_style(path):
    """Стиль существующего файла для round-trip-сохранения: BOM / EOL / регистр encoding /
    финальный перенос. None → файл новый (сохранить текущее поведение)."""
    try:
        raw = open(path, "rb").read()
    except OSError:
        return None
    bom = raw.startswith(b"\xef\xbb\xbf")
    body = raw[3:] if bom else raw
    crlf = b"\r\n" in body
    m = re.search(rb'encoding="([^"]+)"', body[:200])
    enc = m.group(1).decode("ascii") if m else "utf-8"
    final_nl = body.endswith(b"\n")
    return {"bom": bom, "crlf": crlf, "enc": enc, "final_nl": final_nl}


def _finalize_xml_bytes(xml_bytes, style):
    """Привести байты к стилю оригинала; для НОВОГО файла (style is None) — к канону
    выгрузки Конфигуратора: encoding="UTF-8", CRLF в разделителях, без перевода в конце."""
    enc_decl = style["enc"] if style else "UTF-8"
    xml_bytes = xml_bytes.replace(
        b"<?xml version='1.0' encoding='UTF-8'?>",
        b'<?xml version="1.0" encoding="' + enc_decl.encode("ascii") + b'"?>')
    # Канонизировать переносы к LF (убирает &#13; от \r в tail'ах)
    xml_bytes = (xml_bytes.replace(b"&#13;\n", b"\n").replace(b"&#13;", b"")
                 .replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
    # Финальный перенос — как в оригинале (новый файл → нет, канон #57)
    want_final_nl = style["final_nl"] if style else False
    xml_bytes = xml_bytes.rstrip(b"\n")
    if want_final_nl:
        xml_bytes += b"\n"
    # EOL — как в оригинале (новый файл → CRLF, канон #57)
    if (style["crlf"] if style else True):
        xml_bytes = xml_bytes.replace(b"\n", b"\r\n")
    return xml_bytes


def save_xml_bom(tree, path):
    style = _detect_xml_style(path)
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    xml_bytes = _finalize_xml_bytes(xml_bytes, style)
    with open(path, "wb") as f:
        if style is None or style["bom"]:
            f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


def write_text_keep_bom(path, content, style):
    """Текст в файл с BOM, как был у файла (style — _detect_xml_style до записи; файла не было — с BOM)."""
    bom = style is None or style["bom"]
    with open(path, 'w', encoding='utf-8-sig' if bom else 'utf-8', newline='') as f:
        f.write(content)


def write_utf8_bom(path, content):
    # newline='' — без трансляции: иначе текстовый режим Python дал бы CRLF на Windows
    # и LF на macOS, то есть вывод навыка зависел бы от ОС.
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)



def write_xml_file(path, content):
    """XML в каноне выгрузки Конфигуратора: CRLF в разделителях, без перевода в конце.

    Копия этой функции есть в каждом навыке-эмиттере (навыки автономны). Держать
    копии одинаковыми — сознательно: разошедшиеся копии сводят на нет весь смысл.

    Только для файлов, которые СОЗДАЁМ: правка существующего наследует его стиль.
    """
    text = content.replace('\r\n', '\n').replace('\n', '\r\n').rstrip('\r\n')
    write_utf8_bom(path, text)


def new_guid():
    return str(uuid.uuid4())


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Borrow objects from configuration into extension", allow_abbrev=False)
    parser.add_argument("-ExtensionPath", required=True)
    parser.add_argument("-ConfigPath", required=True)
    parser.add_argument("-Object", required=True)
    parser.add_argument("-BorrowMainAttribute", nargs="?", const="Form", default=None)
    parser.add_argument("-Module", default=None)
    args = ci_parse_args(parser)

    # --- 1. Resolve paths ---
    ext_path = args.ExtensionPath
    if not os.path.isabs(ext_path):
        ext_path = os.path.join(os.getcwd(), ext_path)
    if os.path.isdir(ext_path):
        candidate = os.path.join(ext_path, "Configuration.xml")
        if os.path.isfile(candidate):
            ext_path = candidate
        else:
            print(f"No Configuration.xml in extension directory: {ext_path}", file=sys.stderr)
            sys.exit(1)
    if not os.path.isfile(ext_path):
        print(f"Extension file not found: {ext_path}", file=sys.stderr)
        sys.exit(1)
    ext_resolved = os.path.abspath(ext_path)
    ext_dir = os.path.dirname(ext_resolved)

    cfg_path = args.ConfigPath
    if not os.path.isabs(cfg_path):
        cfg_path = os.path.join(os.getcwd(), cfg_path)
    if os.path.isdir(cfg_path):
        candidate = os.path.join(cfg_path, "Configuration.xml")
        if os.path.isfile(candidate):
            cfg_path = candidate
        else:
            print(f"No Configuration.xml in config directory: {cfg_path}", file=sys.stderr)
            sys.exit(1)
    if not os.path.isfile(cfg_path):
        print(f"Config file not found: {cfg_path}", file=sys.stderr)
        sys.exit(1)
    cfg_resolved = os.path.abspath(cfg_path)
    cfg_dir = os.path.dirname(cfg_resolved)

    format_version = detect_format_version(ext_dir)
    apply_pal_ns(format_version)

    # --- 2. Load extension Configuration.xml ---
    xml_parser = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(ext_resolved, xml_parser)
    xml_root = tree.getroot()

    cfg_el = None
    for child in xml_root:
        if isinstance(child.tag, str) and localname(child) == "Configuration":
            cfg_el = child
            break
    if cfg_el is None:
        print("No <Configuration> element found in extension", file=sys.stderr)
        sys.exit(1)

    props_el = None
    child_objs_el = None
    for child in cfg_el:
        if not isinstance(child.tag, str):
            continue
        if localname(child) == "Properties":
            props_el = child
        if localname(child) == "ChildObjects":
            child_objs_el = child

    if props_el is None:
        print("No <Properties> element found in extension", file=sys.stderr)
        sys.exit(1)
    if child_objs_el is None:
        print("No <ChildObjects> element found in extension", file=sys.stderr)
        sys.exit(1)

    # --- 3. Extract NamePrefix ---
    name_prefix = ""
    for child in props_el:
        if isinstance(child.tag, str) and localname(child) == "NamePrefix":
            name_prefix = (child.text or "").strip()
            break
    info(f"Extension NamePrefix: {name_prefix}")

    # Module-level list for borrowed files (used by both main loop and borrow_main_attribute)
    borrowed_files = []
    # Формы с динамическим списком — основная таблица и тильда решаются в конце запуска (шаги 14a, 14c)
    dyn_list_forms = []

    # --- Helper functions ---
    def get_source_attribute_uuids(type_name, obj_name):
        """Имена реквизитов исходного объекта → uuid: реквизиты, ТЧ, измерения и ресурсы регистра,
        реквизиты ТЧ — ключом «ТЧ.Реквизит». Нужны для кода пути в связях формы (см. resolve_link_data_path)."""
        result = {}
        dir_name = CHILD_TYPE_DIR_MAP.get(type_name)
        if not dir_name:
            return result
        src_file = os.path.join(cfg_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(src_file):
            return result

        tree = etree.parse(src_file, etree.XMLParser(remove_blank_text=True))
        obj_el = None
        for c in tree.getroot():
            if isinstance(c.tag, str):
                obj_el = c
                break
        if obj_el is None:
            return result
        for child in obj_el:
            if not isinstance(child.tag, str) or localname(child) != "ChildObjects":
                continue
            for sub in child:
                if not isinstance(sub.tag, str) or localname(sub) not in ("Attribute", "TabularSection", "Dimension", "Resource"):
                    continue
                uuid_val = sub.get("uuid")
                name_val = md_name(sub)
                if not (uuid_val and name_val):
                    continue
                result[name_val] = uuid_val
                if localname(sub) != "TabularSection":
                    continue
                for ts_children in sub:
                    if not isinstance(ts_children.tag, str) or localname(ts_children) != "ChildObjects":
                        continue
                    for ts_attr in ts_children:
                        if not isinstance(ts_attr.tag, str) or localname(ts_attr) != "Attribute":
                            continue
                        ts_uuid, ts_name = ts_attr.get("uuid"), md_name(ts_attr)
                        if ts_uuid and ts_name:
                            result[f"{name_val}.{ts_name}"] = ts_uuid
            break
        return result

    def md_name(el):
        """<Properties>/<Name> объекта метаданных."""
        for props in el:
            if isinstance(props.tag, str) and localname(props) == "Properties":
                for prop in props:
                    if isinstance(prop.tag, str) and localname(prop) == "Name":
                        return (prop.text or "").strip()
                break
        return None

    def read_source_object(type_name, obj_name):
        dir_name = CHILD_TYPE_DIR_MAP.get(type_name)
        if not dir_name:
            print(f"Unknown type '{type_name}'", file=sys.stderr)
            sys.exit(1)

        src_file = os.path.join(cfg_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(src_file):
            print(f"Source object not found: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_parser = etree.XMLParser(remove_blank_text=True)
        src_tree = etree.parse(src_file, src_parser)
        src_root = src_tree.getroot()

        src_el = None
        for c in src_root:
            if isinstance(c.tag, str):
                src_el = c
                break
        if src_el is None:
            print(f"No metadata element found in {dir_name}/{obj_name}.xml", file=sys.stderr)
            sys.exit(1)

        src_uuid = src_el.get("uuid", "")
        if not src_uuid:
            print(f"No uuid attribute on source element in {dir_name}/{obj_name}.xml", file=sys.stderr)
            sys.exit(1)

        src_props = {}
        props_node = src_el.find(f"{{{MD_NS}}}Properties")
        if props_node is not None:
            for prop_name in COMMON_MODULE_PROPS:
                prop_node = props_node.find(f"{{{MD_NS}}}{prop_name}")
                if prop_node is not None:
                    src_props[prop_name] = (prop_node.text or "").strip()
            # DefinedType: carry the <Type> definition. A type alias is meaningless as a bare shell —
            # the platform needs its underlying type (e.g. to know a column is a summable Number for totals).
            if type_name == "DefinedType":
                type_node = props_node.find(f"{{{MD_NS}}}Type")
                if type_node is not None:
                    type_xml = etree.tostring(type_node, encoding="unicode")
                    src_props["__TypeXml"] = re.sub(r'\s+xmlns(?::\w+)?="[^"]*"', '', type_xml)
            # Владельцы: стандартное поле «Owner» появляется у справочника, только если задан Owners
            if type_name in TYPES_WITH_OWNERS:
                owners_node = props_node.find(f"{{{MD_NS}}}Owners")
                if owners_node is not None and len(owners_node):
                    owners_xml = etree.tostring(owners_node, encoding="unicode")
                    src_props["__OwnersXml"] = re.sub(r'\s+xmlns(?::\w+)?="[^"]*"', '', owners_xml)
            # Скалярные свойства, включающие стандартные поля своего типа
            for gp in TYPE_GATE_PROPS.get(type_name, []):
                gp_node = props_node.find(f"{{{MD_NS}}}{gp}")
                if gp_node is not None:
                    src_props[gp] = (gp_node.text or "").strip()

        # Whether the platform emits <ChildObjects> for this type — the source object is the ground truth
        src_props["__HasChildObjects"] = src_el.find(f"{{{MD_NS}}}ChildObjects") is not None

        return {"Uuid": src_uuid, "Properties": src_props, "Element": src_el}

    def read_source_form_uuid(type_name, obj_name, form_name):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        # Общая форма — сама объект конфигурации: её описание лежит рядом с другими, а не в Forms владельца
        if type_name == "CommonForm":
            src_file = os.path.join(cfg_dir, dir_name, f"{obj_name}.xml")
        else:
            src_file = os.path.join(cfg_dir, dir_name, obj_name, "Forms", f"{form_name}.xml")
        if not os.path.isfile(src_file):
            print(f"Source form not found: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_parser = etree.XMLParser(remove_blank_text=True)
        src_tree = etree.parse(src_file, src_parser)

        src_el = None
        for c in src_tree.getroot():
            if isinstance(c.tag, str):
                src_el = c
                break
        if src_el is None:
            print(f"No metadata element found in source form: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_uuid = src_el.get("uuid", "")
        if not src_uuid:
            print(f"No uuid attribute on source form element: {src_file}", file=sys.stderr)
            sys.exit(1)
        return src_uuid

    # --- Пустой модуль заимствованного объекта ---
    def new_borrowed_module_file(type_name, obj_name, module_kind):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        module_dir = os.path.join(ext_dir, dir_name, obj_name, "Ext")
        os.makedirs(module_dir, exist_ok=True)

        # NEVER overwrite an existing one: повторное заимствование не должно затирать дописанный
        # код (то же правило, что у модуля формы).
        module_file = os.path.join(module_dir, f"{module_kind}.bsl")
        if os.path.isfile(module_file):
            info(f"  Preserved existing {module_kind}.bsl")
        else:
            write_utf8_bom(module_file, "")
            info(f"  Created: {module_file}")

        # Флаг ставим и для уже существовавшего файла: состояние объекта должно отражать факт модуля.
        set_property_state_flag(os.path.join(ext_dir, dir_name, f"{obj_name}.xml"), module_kind, format_version)
        return module_file

    def build_internal_info_xml(type_name, obj_name, indent):
        types = GENERATED_TYPES.get(type_name)
        if not types:
            return f"{indent}<InternalInfo/>"

        lines = [f"{indent}<InternalInfo>"]

        if type_name == "ExchangePlan":
            this_node_uuid = new_guid()
            lines.append(f"{indent}\t<xr:ThisNode>{this_node_uuid}</xr:ThisNode>")

        for gt in types:
            full_name = f"{gt['prefix']}.{obj_name}"
            type_id = new_guid()
            value_id = new_guid()
            lines.append(f'{indent}\t<xr:GeneratedType name="{full_name}" category="{gt["category"]}">')
            lines.append(f"{indent}\t\t<xr:TypeId>{type_id}</xr:TypeId>")
            lines.append(f"{indent}\t\t<xr:ValueId>{value_id}</xr:ValueId>")
            lines.append(f"{indent}\t</xr:GeneratedType>")

        lines.append(f"{indent}</InternalInfo>")
        return "\n".join(lines)

    def build_borrowed_object_xml(type_name, obj_name, source_uuid, source_props):
        new_uuid_val = new_guid()
        internal_info_xml = build_internal_info_xml(type_name, obj_name, "\t\t")

        lines = []
        lines.append('<?xml version="1.0" encoding="UTF-8"?>')
        lines.append(f'<MetaDataObject {XMLNS_DECL} version="{format_version}">')
        lines.append(f'\t<{type_name} uuid="{new_uuid_val}">')
        lines.append(internal_info_xml)
        lines.append("\t\t<Properties>")
        lines.append("\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>")
        lines.append(f"\t\t\t<Name>{obj_name}</Name>")
        lines.append("\t\t\t<Comment/>")
        lines.append(f"\t\t\t<ExtendedConfigurationObject>{source_uuid}</ExtendedConfigurationObject>")

        if type_name == "CommonModule":
            for prop_name in COMMON_MODULE_PROPS:
                prop_val = source_props.get(prop_name, "false")
                lines.append(f"\t\t\t<{prop_name}>{prop_val}</{prop_name}>")

        # DefinedType: emit the carried <Type> definition (needed for the alias to resolve, e.g. totals)
        if type_name == "DefinedType" and "__TypeXml" in source_props:
            lines.append(f"\t\t\t{source_props['__TypeXml']}")

        # Свойства, от которых зависят стандартные поля (см. TYPE_GATE_PROPS / TYPES_WITH_OWNERS)
        for gp in TYPE_GATE_PROPS.get(type_name, []):
            if gp in source_props:
                lines.append(f"\t\t\t<{gp}>{source_props[gp]}</{gp}>")
        if "__OwnersXml" in source_props:
            lines.append(f"\t\t\t{source_props['__OwnersXml']}")

        lines.append("\t\t</Properties>")

        if source_props.get("__HasChildObjects") or type_name in TYPES_WITH_CHILD_OBJECTS:
            lines.append("\t\t<ChildObjects/>")

        lines.append(f"\t</{type_name}>")
        lines.append("</MetaDataObject>")
        return "\n".join(lines)

    def add_to_child_objects(type_name, obj_name):
        cfg_indent = get_child_indent(cfg_el)
        if len(child_objs_el) == 0 and not (child_objs_el.text and child_objs_el.text.strip()):
            expand_self_closing(child_objs_el, cfg_indent)
        ci = get_child_indent(child_objs_el)

        if type_name not in TYPE_ORDER:
            print(f"Unknown type '{type_name}' for ChildObjects ordering", file=sys.stderr)
            sys.exit(1)
        type_idx = TYPE_ORDER.index(type_name)

        # Dedup
        for child in child_objs_el:
            if isinstance(child.tag, str) and localname(child) == type_name and (child.text or "") == obj_name:
                warn(f"Already in ChildObjects: {type_name}.{obj_name}")
                return

        # Место вставки. Вид — по TYPE_ORDER; внутри вида — по newObjectPosition:
        # end (по умолчанию) кладёт после последнего объекта того же вида, byName — по имени.
        # Так же, как заимствует Конфигуратор: в боевых выгрузках расширений ChildObjects
        # не отсортирован. Subsystem по имени не упорядочиваем никогда: порядок подсистем
        # в дереве задаёт порядок разделов в панели.
        by_name = (not is_order_sensitive_type(type_name)
                   and get_new_object_position(ext_dir) == "byName")
        insert_before = None
        for child in child_objs_el:
            if not isinstance(child.tag, str):
                continue
            child_type_name = localname(child)
            if child_type_name not in TYPE_ORDER:
                continue
            child_type_idx = TYPE_ORDER.index(child_type_name)

            if child_type_name == type_name:
                if (by_name and insert_before is None
                        and compare_metadata_names(child.text or "", obj_name) > 0):
                    insert_before = child
            elif child_type_idx > type_idx and insert_before is None:
                insert_before = child

        new_el = etree.Element(f"{{{MD_NS}}}{type_name}")
        new_el.text = obj_name

        if insert_before is not None:
            insert_before_ref(child_objs_el, new_el, insert_before, ci)
        else:
            insert_before_closing(child_objs_el, new_el, ci)

        info(f"Added to ChildObjects: {type_name}.{obj_name}")

    def test_object_borrowed(type_name, obj_name):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")
        return os.path.isfile(obj_file)

    def register_form_in_object(type_name, obj_name, form_name):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(obj_file):
            warn(f"Parent object file not found: {obj_file} \u2014 form not registered in ChildObjects")
            return

        obj_parser = etree.XMLParser(remove_blank_text=False)
        obj_tree = etree.parse(obj_file, obj_parser)
        obj_root = obj_tree.getroot()

        obj_el = None
        for c in obj_root:
            if isinstance(c.tag, str):
                obj_el = c
                break
        if obj_el is None:
            warn(f"No type element in {obj_file} \u2014 form not registered")
            return

        child_objs = obj_el.find(f"{{{MD_NS}}}ChildObjects")
        if child_objs is None:
            child_objs = etree.SubElement(obj_el, f"{{{MD_NS}}}ChildObjects")
            # Set proper whitespace
            prev = child_objs.getprevious()
            if prev is not None:
                child_objs.tail = "\r\n\t"
                prev_tail = prev.tail or ""
                if not prev_tail.endswith("\t\t"):
                    prev.tail = "\r\n\t\t"

        # Dedup
        for c in child_objs:
            if isinstance(c.tag, str) and localname(c) == "Form" and (c.text or "") == form_name:
                warn(f"Form '{form_name}' already in ChildObjects of {type_name}.{obj_name}")
                return

        if len(child_objs) == 0 and not (child_objs.text and child_objs.text.strip()):
            child_objs.text = "\r\n\t\t"

        form_el = etree.Element(f"{{{MD_NS}}}Form")
        form_el.text = form_name
        # Место — по канону вида (у документа форма до ТЧ, у справочника после)
        anchor = find_child_anchor(child_objs, "Form", localname(obj_el))
        if anchor is not None:
            insert_before_ref(child_objs, form_el, anchor, "\t\t\t")
        else:
            insert_before_closing(child_objs, form_el, "\t\t\t")

        save_xml_bom(obj_tree, obj_file)
        info(f"  Registered form in: {obj_file}")

    # --- 11b1. Основной реквизит исходной формы ---
    # Переносится ЦЕЛИКОМ, а не собирается из констант: имя, тип и состав детей зависят от вида формы.
    # У формы объекта это «Объект»/<Тип>Object + SavedData/UseAlways/Columns, у формы списка —
    # «Список»/DynamicList + Settings, у формы записи регистра — «Запись»/RecordManager + SavedData.
    # Синтез фиксированного набора давал для необъектных форм «Исключение XDTO» при загрузке.
    # Конфигуратор меняет у скопированного реквизита только id (эталоны Issue64UtB, Issue66Example2).
    def get_form_attribute_ids(form_el):
        """Имена реквизитов ИСХОДНОЙ формы → их id. Ссылки параметров выбора адресуют реквизит формы
        именно по id базовой формы (см. rewrite_choice_parameter_links)."""
        result = {}
        for child in form_el:
            if not isinstance(child.tag, str) or localname(child) != "Attributes":
                continue
            for a in child:
                if not isinstance(a.tag, str) or localname(a) != "Attribute":
                    continue
                nm, aid = a.get("name"), a.get("id")
                if nm and aid:
                    result[nm] = aid
            break
        return result

    def get_link_context(form_el, main_name, main_borrowed, borrowed_names, attr_uuids, form_attr_ids):
        """Контекст разрешения путей в связях формы (см. resolve_link_data_path) — всё по ИСХОДНОЙ
        форме: колонки реквизитов формы, колонки AdditionalColumns, элементы-таблицы и вид основного
        реквизита."""
        cols, add_cols, tables, kind = {}, {}, {}, None
        for child in form_el:
            if not isinstance(child.tag, str):
                continue
            if localname(child) == "Attributes":
                for a in child:
                    if not isinstance(a.tag, str) or localname(a) != "Attribute":
                        continue
                    nm = a.get("name")
                    for sub in a:
                        if not isinstance(sub.tag, str):
                            continue
                        if localname(sub) == "Columns":
                            for c in sub:
                                if not isinstance(c.tag, str):
                                    continue
                                if localname(c) == "Column":
                                    cols[f"{nm}.{c.get('name')}"] = c.get("id")
                                elif localname(c) == "AdditionalColumns":
                                    tbl_path = c.get("table")
                                    for ac in c:
                                        if isinstance(ac.tag, str) and localname(ac) == "Column":
                                            add_cols[f"{tbl_path}.{ac.get('name')}"] = ac.get("id")
                        elif localname(sub) == "Type" and main_name and nm == main_name and kind is None:
                            for tn in sub:
                                if isinstance(tn.tag, str) and localname(tn) == "Type":
                                    # Тип без имени объекта (cfg:ConstantsSet) — тоже вид
                                    tm = re.match(r'^(?:\w+:)?(\w+)(?:\.|$)', (tn.text or "").strip())
                                    if tm and tm.group(1) in MAIN_ATTR_KINDS:
                                        kind = MAIN_ATTR_KINDS[tm.group(1)]
                                    break
            elif localname(child) == "ChildItems":
                for tbl in child.iter():
                    if not isinstance(tbl.tag, str) or localname(tbl) != "Table":
                        continue
                    for dp in tbl:
                        if isinstance(dp.tag, str) and localname(dp) == "DataPath":
                            tables[tbl.get("name")] = {"Id": tbl.get("id"), "Path": (dp.text or "").strip()}
                            break
        main_id = form_attr_ids.get(main_name, "1") if main_name else "1"
        return {"MainName": main_name, "MainId": main_id, "MainBorrowed": main_borrowed, "MainKind": kind,
                "BorrowedNames": borrowed_names,
                "AttrUuids": attr_uuids, "FormAttrIds": form_attr_ids, "FormAttrCols": cols,
                "AddCols": add_cols, "Tables": tables}

    # Псевдоним таблицы, ссылка на которую кончается в позиции pos: «КАК имя» / «AS имя», имя без
    # КАК (если это не ключевое слово); параметры виртуальной таблицы в скобках пропускаются.
    # None — псевдонима нет, тогда псевдоним — последний сегмент имени таблицы. Иначе — имя и позиция:
    # имя без КАК — тоже определение псевдонима, а не поле.
    def get_query_table_alias(q, pos):
        i = pos
        while i < len(q) and q[i].isspace():
            i += 1
        if i < len(q) and q[i] == '(':
            depth = 0
            while i < len(q):
                if q[i] == '(':
                    depth += 1
                elif q[i] == ')':
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
            while i < len(q) and q[i].isspace():
                i += 1
        m = RE_TABLE_ALIAS.match(q, i)
        if not m:
            return None
        if m.group(1) is None and query_key(m.group(2)) in QUERY_ALIAS_STOP_WORDS:
            return None
        return m.group(2), m.start(2)

    # Что объект предоставляет запросу в контексте расширения — по итоговому составу расширения.
    # None — объекта в расширении нет. Fields: имена заимствованных подобъектов (реквизиты, измерения,
    # ресурсы, ТЧ, признаки учёта…); TSCols: колонки заимствованных ТЧ; EnumValues: значения
    # перечисления; Types: поле → ссылочный тип (одиночный) для разыменования. Ключи — query_key.
    ext_table_info_cache = {}

    def get_ext_table_info(kind, name_key):
        cache_key = f"{kind}|{name_key}"
        if cache_key in ext_table_info_cache:
            return ext_table_info_cache[cache_key]
        info_ = None
        dir_ = CHILD_TYPE_DIR_MAP.get(kind)
        actual = None
        if dir_:
            # Имя — каноническое, из состава расширения: в запросе регистр и Ё/Е произвольны
            for c in child_objs_el:
                if isinstance(c.tag, str) and etree.QName(c.tag).localname == kind \
                        and query_key((c.text or '').strip()) == name_key:
                    actual = (c.text or '').strip()
                    break
        if actual:
            f = os.path.join(ext_dir, dir_, f"{actual}.xml")
            if os.path.isfile(f):
                root = etree.parse(f).getroot()
                el = next((c for c in root if isinstance(c.tag, str)), None)
                info_ = {'Kind': kind, 'Fields': set(), 'TSCols': {}, 'EnumValues': set(), 'Types': {}, 'Gates': {}}
                if el is not None:
                    pr = el.xpath("*[local-name()='Properties']")
                    if pr:
                        pr = pr[0]

                        def _prop(name):
                            n = pr.xpath(f"*[local-name()='{name}']")
                            return (n[0].text or '').strip() if n else None
                        info_['Gates']['Hierarchical'] = _prop('Hierarchical') == 'true'
                        info_['Gates']['Owners'] = bool(pr.xpath("*[local-name()='Owners']/*"))
                        pv = _prop('InformationRegisterPeriodicity')
                        info_['Gates']['Periodic'] = bool(pv) and pv != 'Nonperiodical'
                        info_['Gates']['Recorder'] = _prop('WriteMode') == 'RecorderSubordinate'
                    for sub in el.xpath("*[local-name()='ChildObjects']/*"):
                        local = etree.QName(sub.tag).localname
                        if local not in QUERY_FIELD_KINDS:
                            continue
                        nm = sub.xpath("*[local-name()='Properties']/*[local-name()='Name']")
                        if not nm:
                            continue
                        k = query_key((nm[0].text or '').strip())
                        if local == 'EnumValue':
                            info_['EnumValues'].add(k)
                            continue
                        info_['Fields'].add(k)
                        types = sub.xpath("*[local-name()='Properties']/*[local-name()='Type']/*[local-name()='Type']")
                        if len(types) == 1:
                            rk = get_ref_kind_from_type(types[0].text or '')
                            if rk:
                                info_['Types'][k] = rk
                        if local == 'TabularSection':
                            info_['TSCols'][k] = {
                                query_key((cn.text or '').strip())
                                for cn in sub.xpath("*[local-name()='ChildObjects']/*/*[local-name()='Properties']/*[local-name()='Name']")}
        ext_table_info_cache[cache_key] = info_
        return info_

    # Что в ручном запросе динамического списка не разрешится в контексте расширения — список причин;
    # пустой — запрос разрешим, тильда не нужна. Проверяется по ИТОГОВОМУ составу расширения, а не по
    # прогнозу заимствования: каждая таблица запроса (её объект) должна быть в расширении, её ТЧ,
    # значения перечисления — тоже; каждое поле — заимствованным подобъектом или стандартным полем,
    # разыменование — по одиночному ссылочному типу до объекта, который тоже есть в расширении.
    # Предопределённые, виртуальные таблицы, «*», обращения через скобку и неизвестные слова — не
    # разрешаются. Правило консервативное: лишняя тильда — лишь шум, пропущенная — отказ загрузки.
    # Сверено с платформой 8.3.24 (оракул — загрузка без тильды).
    def get_dyn_list_query_unresolved(query_text):
        reasons = []
        # Строковые литералы и комментарии — не код запроса; пробелы вокруг точки — часть пути
        q = re.sub(r'"(?:[^"]|"")*"|//[^\r\n]*', ' ', query_text)
        q = re.sub(r'(?<=[\w)])\s*\.\s*(?=[^\W\d]|\*)', '.', q)
        empty_ref_keys = (query_key("ПустаяСсылка"), query_key("EmptyRef"))
        ts_std_keys = (query_key("Ссылка"), query_key("Ref"), query_key("НомерСтроки"), query_key("LineNumber"))
        same_obj_std = (query_key("Ссылка"), query_key("Ref"), query_key("Родитель"), query_key("Parent"))
        ref_keys = (query_key("Ссылка"), query_key("Ref"))

        # «*» (кроме КОЛИЧЕСТВО(*)) и обращение через скобку — состав полей не виден
        if re.search(r'(?i)\.\*|(?:(?<![\w.])(?:ВЫБРАТЬ|SELECT|РАЗЛИЧНЫЕ|DISTINCT|РАЗРЕШЕННЫЕ|ALLOWED)|,|\{|(?<![\w.])(?:ПЕРВЫЕ|TOP)\s+\d+)\s*\*', q):
            reasons.append("*")
        # Области запроса не разбираются: части ОБЪЕДИНИТЬ и вложенные запросы — со своими таблицами
        if re.search(r'(?i)(?<![\w.])(?:ОБЪЕДИНИТЬ|UNION)(?![\w.])', q):
            reasons.append("ОБЪЕДИНИТЬ")
        if len(re.findall(r'(?i)(?<![\w.])(?:ВЫБРАТЬ|SELECT)(?![\w.])', q)) > 1:
            reasons.append("вложенный запрос")
        if re.search(r'\)\.[^\W\d]', q):
            reasons.append(").Поле")

        path_matches = list(re.finditer(r'(?<![\w.&])[^\W\d]\w*(?:\.[^\W\d]\w*)+', q))
        alias_pos = set()
        # Таблицы и их псевдонимы: псевдоним → {Info, TS ('' — сам объект)}
        alias_map = {}
        for pm in path_matches:
            segs = pm.group(0).split('.')
            k0 = query_key(segs[0])
            if k0 not in QUERY_TABLE_KINDS:
                continue
            kind = QUERY_TABLE_KINDS[k0]
            tinfo = get_ext_table_info(kind, query_key(segs[1]))
            if tinfo is None:
                reasons.append(f"{segs[0]}.{segs[1]}")
                continue
            ts_key = ''
            if len(segs) >= 3:
                k2 = query_key(segs[2])
                if len(segs) == 3 and (k2 in empty_ref_keys or k2 in tinfo['EnumValues']):
                    continue
                if len(segs) == 3 and k2 in tinfo['TSCols']:
                    ts_key = k2
                else:
                    reasons.append(pm.group(0))
                    continue
            # Псевдоним — только у таблицы-источника (после ИЗ/СОЕДИНЕНИЕ или запятой в их списке). У
            # ссылок в ЗНАЧЕНИЕ(), ТИП(), ВЫРАЗИТЬ(... КАК …), ССЫЛКА … псевдонима нет: фантомный псевдоним
            # закрыл бы от проверки одноимённое поле.
            bi = pm.start() - 1
            while bi >= 0 and q[bi].isspace():
                bi -= 1
            is_source = False
            if bi >= 0 and q[bi] == ',':
                is_source = True
            elif bi >= 0:
                we = bi + 1
                while bi >= 0 and q[bi].isalnum():
                    bi -= 1
                is_source = query_key(q[bi + 1:we]) in QUERY_SOURCE_KEYWORDS
            if not is_source:
                continue
            al = get_query_table_alias(q, pm.end())
            alias = segs[-1]
            if al:
                alias = al[0]
                alias_pos.add(al[1])
            alias_map[query_key(alias)] = {'Info': tinfo, 'TS': ts_key}

        # Поле Источник.Поле[.Подполе…]: каждое звено — заимствованный подобъект или стандартное поле
        for pm in path_matches:
            segs = pm.group(0).split('.')
            k0 = query_key(segs[0])
            if k0 in QUERY_TABLE_KINDS:
                continue
            if k0 not in alias_map:
                reasons.append(pm.group(0))
                continue
            cur_info = alias_map[k0]['Info']
            cur_ts = alias_map[k0]['TS']
            ok = True
            for i in range(1, len(segs)):
                fk = query_key(segs[i])
                last = (i == len(segs) - 1)
                if cur_ts:
                    # Поле строки ТЧ: колонка (без разыменования) или Ссылка/НомерСтроки
                    if last and (fk in cur_info['TSCols'][cur_ts] or fk in ts_std_keys):
                        break
                    if not last and fk in ref_keys:
                        cur_ts = ''
                        continue
                    ok = False
                    break
                if last:
                    if not (fk in cur_info['Fields'] or test_query_std_field(cur_info, fk)):
                        ok = False
                    break
                # Разыменование: Ссылка/Родитель — тот же объект; реквизит — по его ссылочному типу
                if fk in same_obj_std and test_query_std_field(cur_info, fk):
                    continue
                if fk in cur_info['Types']:
                    t = cur_info['Types'][fk]
                    cur_info = get_ext_table_info(t['Kind'], query_key(t['Name']))
                    if cur_info is None:
                        ok = False
                        break
                    continue
                ok = False
                break
            if not ok:
                reasons.append(pm.group(0))

        # Слова без точки. Пропускаются: определение псевдонима (после КАК/AS — в т.ч. имя типа в
        # ВЫРАЗИТЬ), имя функции (перед «(»), зарезервированное слово, период аргументом после запятой
        # внутри скобок. Остальное — поле одной из таблиц запроса: Месяц, Документ, Сумма — и имена полей.
        alias_defs = {mm.start(1) for mm in re.finditer(r'(?i)(?<![\w.])(?:КАК|AS)\s+([^\W\d]\w*)', q)}
        comma_args = {mm.start(1) for mm in re.finditer(r',\s*([^\W\d]\w*)', q)}
        depth_at = [0] * (len(q) + 1)
        depth = 0
        for ci, ch in enumerate(q):
            depth_at[ci] = depth
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
        for wm in re.finditer(r'(?<![\w.&])[^\W\d]\w*(?![\w.])', q):
            if wm.start() in alias_defs or wm.start() in alias_pos:
                continue
            wk = query_key(wm.group(0))
            if wk in QUERY_RESERVED_WORDS:
                continue
            if wk in QUERY_PERIOD_NAMES and wm.start() in comma_args and depth_at[wm.start()] > 0:
                continue
            if RE_FUNC_PAREN.match(q, wm.end()):
                continue
            found = False
            for src in alias_map.values():
                if src['TS']:
                    if wk in src['Info']['TSCols'][src['TS']] or wk in ts_std_keys:
                        found = True
                        break
                elif wk in src['Info']['Fields'] or test_query_std_field(src['Info'], wk):
                    found = True
                    break
            if not found:
                reasons.append(wm.group(0))

        seen = set()
        return [r for r in reasons if not (r in seen or seen.add(r))]

    def get_main_attribute_info(form_el, ns_strip_pattern):
        main_attr = None
        for child in form_el:
            if not isinstance(child.tag, str) or localname(child) != "Attributes":
                continue
            for attr in child:
                if not isinstance(attr.tag, str) or localname(attr) != "Attribute":
                    continue
                for sub in attr:
                    if isinstance(sub.tag, str) and localname(sub) == "MainAttribute" and (sub.text or "").strip() == "true":
                        main_attr = attr
                        break
                if main_attr is not None:
                    break
            break
        if main_attr is None:
            return None
        # with_tail=False: хвостовой пробельный узел — часть родителя, а не секции; иначе в
        # вывод попадают пустые строки, которых нет у PS (OuterXml хвост не включает).
        xml = decode_numeric_entities(etree.tostring(main_attr, encoding="unicode", with_tail=False))
        xml = ns_strip_pattern.sub("", xml)
        # id заменяется только в открывающем теге самого реквизита — у вложенных элементов свои
        xml = re.sub(r'^(<Attribute\s[^>]*?)id="[^"]*"', lambda m: m.group(1) + f'id="{MAIN_ATTR_ID}"', xml)
        return {"Name": main_attr.get("name"), "Xml": xml}

    # --- 11b. Collect DataPath references from source Form.xml ---
    def collect_form_data_paths(form_xml_path, main_attr_name):
        # Корень путей — имя основного реквизита формы: «Объект» у формы объекта, «Список» у формы
        # списка, «Запись» у формы записи регистра. Зашитый «Объект» не находил ничего у необъектных
        # форм, и в оболочку не заимствовалось ни одного дочернего объекта.
        root = re.escape(main_attr_name)
        with open(form_xml_path, "r", encoding="utf-8-sig") as fh:
            content = fh.read()

        # Имена без учёта регистра, как у платформы (и у хеш-таблицы ps1): ключ — первое написание
        first_level = {}
        first_seen = set()
        deep_paths = []
        std_upper = {f.upper() for f in STANDARD_FIELDS}

        def is_std(name):
            return name.upper() in std_upper

        def add_first(name):
            if name.upper() not in first_seen:
                first_seen.add(name.upper())
                first_level[name] = True

        # Scan every data-binding tag (DataPath/TitleDataPath/FooterDataPath/HeaderDataPath/MultipleValue*)
        # for Объект.* references — picture-path tags carry picture indices, not data attributes.
        for tag in FORM_BINDING_DATA_TAGS:
            for m in re.finditer(r'<' + tag + r'>[^<]*\b' + root + r'\.(\w+(?:\.\w+)*)</' + tag + r'>', content):
                path = m.group(1)
                segments = path.split(".")
                seg0 = segments[0]
                if is_std(seg0):
                    continue
                add_first(seg0)
                if len(segments) >= 2:
                    if is_std(segments[1]):
                        continue
                    deep_paths.append(segments)

        # Also scan <Field>Объект.X</Field> — object attributes referenced by filter/conditional-appearance
        # fields (and dynamic lists), not via a *DataPath binding (e.g. УдалитьЮрФизЛицо). Designer borrows these too.
        for m in re.finditer(r'<Field>[^<]*\b' + root + r'\.(\w+(?:\.\w+)*)</Field>', content):
            path = m.group(1)
            segments = path.split(".")
            seg0 = segments[0]
            if is_std(seg0):
                continue
            add_first(seg0)
            if len(segments) >= 2:
                if is_std(segments[1]):
                    continue
                deep_paths.append(segments)

        # Also scan <AdditionalColumns table="Объект.X"> — доп. колонки табличной части, объявленные в
        # самой форме (напр. Объект.Товары.Артикул). Такая ТЧ может больше нигде на форме не встречаться,
        # и без её заимствования платформа отвергает форму: «Неверный путь к данным».
        for m in re.finditer(r'<AdditionalColumns table="' + root + r'\.(\w+)"', content):
            seg0 = m.group(1)
            if is_std(seg0):
                continue
            add_first(seg0)

        # Текст запроса динамического списка — такое же место ссылки на реквизиты объекта, как DataPath.
        # Конфигуратор заимствует всё, что упомянуто в запросе: на эталоне Issue66Example2 это 21 из 27
        # дочерних объектов, совпадение с ним точное в обе стороны. У списка без ручного запроса
        # (<QueryText> нет) заимствуется только видимое на форме — эталон Issue66Example3.
        # Разбирать язык запросов не нужно: имена-кандидаты отфильтрует resolve_source_attributes по
        # реальному составу объекта, поэтому лишние слова из запроса безвредны.
        for qm in re.finditer(r'(?s)<QueryText>(.*?)</QueryText>', content):
            for w in re.finditer(r'\w+', qm.group(1)):
                if is_std(w.group(0)):
                    continue
                add_first(w.group(0))

        # Deduplicate deep paths (each is the full segment list after the root)
        seen = set()
        unique_deep = []
        for dp in deep_paths:
            key = ".".join(dp).upper()
            if key not in seen:
                seen.add(key)
                unique_deep.append(dp)

        return {"FirstLevel": first_level, "DeepPaths": unique_deep}

    # --- 11c. Resolve source attributes and tabular sections ---
    def resolve_source_attributes(type_name, obj_name, first_level_names):
        # first_level_names: dict of names, or None for "all"
        # Имена сверяются ключом запроса (регистр, Ё/Е): слова приходят и из текста запроса списка,
        # а правило тильды (get_dyn_list_query_unresolved) считает их найденными по тому же ключу.
        fl_keys = None if first_level_names is None else {query_key(k) for k in first_level_names}
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        src_file = os.path.join(cfg_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(src_file):
            print(f"Source object not found: {src_file}", file=sys.stderr)
            sys.exit(1)

        src_parser = etree.XMLParser(remove_blank_text=True)
        src_tree = etree.parse(src_file, src_parser)
        src_root = src_tree.getroot()

        ns_strip = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')

        src_el = None
        for c in src_root:
            if isinstance(c.tag, str):
                src_el = c
                break
        if src_el is None:
            print(f"No metadata element in source: {src_file}", file=sys.stderr)
            sys.exit(1)

        child_objs = src_el.find(f"{{{MD_NS}}}ChildObjects")
        if child_objs is None:
            return {"Attributes": [], "TabularSections": [], "ExtraProps": {}}

        attrs = []
        tab_sections = []
        # Стандартная ТЧ видов субконто плана счетов: нужна форме (или режим All) — переносятся свойства
        # ExtDimensionTypes/MaxExtDimensionCount и признаки учёта субконто
        want_ext_dim = type_name == "ChartOfAccounts" and (fl_keys is None or query_key("ExtDimensionTypes") in fl_keys
                                                           or query_key("ВидыСубконто") in fl_keys)

        for child in child_objs:
            if not isinstance(child.tag, str):
                continue
            ln = localname(child)

            # Реквизит объекта, измерение и ресурс регистра — один и тот же вид дочернего объекта с
            # точки зрения заимствования, различается только имя элемента. Конфигуратор переносит их
            # своим видом (эталон Issue66Example2: у регистра <Dimension> x3 и <Resource>), поэтому вид
            # запоминается и выпускается как есть — иначе измерение уехало бы в файл как <Attribute>.
            if ln in CHILD_OBJECT_KINDS:
                name_node = child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
                if name_node is None:
                    continue
                attr_name = (name_node.text or "").strip()
                # Признак учёта субконто — колонка стандартной ТЧ видов субконто (Объект.ВидыСубконто.<Признак>):
                # идёт вместе с ней, а не по первому сегменту пути
                if ln == "ExtDimensionAccountingFlag":
                    if not want_ext_dim:
                        continue
                elif fl_keys is not None and query_key(attr_name) not in fl_keys:
                    continue

                attr_uuid = child.get("uuid", "")
                type_node = child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Type")
                type_xml = ""
                if type_node is not None:
                    type_xml = etree.tostring(type_node, encoding="unicode")
                    type_xml = ns_strip.sub("", type_xml)

                attrs.append({"Name": attr_name, "Uuid": attr_uuid, "TypeXml": type_xml, "Kind": ln})

            elif ln == "TabularSection":
                name_node = child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
                if name_node is None:
                    continue
                ts_name = (name_node.text or "").strip()
                if fl_keys is not None and query_key(ts_name) not in fl_keys:
                    continue

                ts_uuid = child.get("uuid", "")

                # Extract GeneratedTypes from InternalInfo
                ts_gen_types = []
                ii_node = child.find(f"{{{MD_NS}}}InternalInfo")
                if ii_node is not None:
                    for gt in ii_node:
                        if isinstance(gt.tag, str) and localname(gt) == "GeneratedType":
                            gt_name = gt.get("name", "")
                            gt_category = gt.get("category", "")
                            tid_el = gt.find(f"{{{XR_NS}}}TypeId")
                            vid_el = gt.find(f"{{{XR_NS}}}ValueId")
                            ts_gen_types.append({
                                "Name": gt_name,
                                "Category": gt_category,
                                "TypeId": (tid_el.text or "") if tid_el is not None else "",
                                "ValueId": (vid_el.text or "") if vid_el is not None else "",
                            })

                # Extract ALL child attributes of TabularSection
                ts_attrs = []
                ts_child_objs = child.find(f"{{{MD_NS}}}ChildObjects")
                if ts_child_objs is not None:
                    for ts_child in ts_child_objs:
                        if not isinstance(ts_child.tag, str) or localname(ts_child) != "Attribute":
                            continue
                        ts_attr_name_el = ts_child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
                        if ts_attr_name_el is None:
                            continue
                        ts_attr_uuid = ts_child.get("uuid", "")
                        ts_type_node = ts_child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Type")
                        ts_type_xml = ""
                        if ts_type_node is not None:
                            ts_type_xml = etree.tostring(ts_type_node, encoding="unicode")
                            ts_type_xml = ns_strip.sub("", ts_type_xml)
                        ts_attrs.append({
                            "Name": (ts_attr_name_el.text or "").strip(),
                            "Uuid": ts_attr_uuid,
                            "TypeXml": ts_type_xml,
                        })

                tab_sections.append({
                    "Name": ts_name, "Uuid": ts_uuid,
                    "GeneratedTypes": ts_gen_types, "Attributes": ts_attrs,
                })

        # Extract extra Properties for main object enrichment
        extra_props = {}
        props_node = src_el.find(f"{{{MD_NS}}}Properties")
        if props_node is not None:
            # NumberPeriodicity сюда НЕ входит: платформа считает его модификацией настроек нумерации и
            # тогда требует объявить ещё и <Numerator/>, иначе /UpdateDBCfg падает — «отключать
            # контролируемость свойства "Нумератор" недопустимо». Конфигуратор его не переносит
            # (эталон заимствования документа: NumberType/NumberLength/NumberAllowedLength и всё).
            # Загрузку это не ломает, ошибка вылезает только на обновлении конфигурации БД.
            # FoldersOnTop сюда НЕ входит: платформа его у заимствованной оболочки не хранит — при
            # загрузке молча выбрасывает (проверено раундтрипом: записали, выгрузили обратно, свойства
            # нет). Конфигуратор его тоже не переносит. Остальные из списка сохраняются.
            props_to_extract = [
                "Hierarchical", "CodeLength", "DescriptionLength",
                "CodeType", "CodeAllowedLength", "NumberType", "NumberLength",
                "NumberAllowedLength",
            ]
            for p_name in props_to_extract:
                p_node = props_node.find(f"{{{MD_NS}}}{p_name}")
                if p_node is not None:
                    extra_props[p_name] = (p_node.text or "").strip()
            # Стандартная ТЧ видов субконто плана счетов видна форме расширения, только если в оболочке есть
            # ExtDimensionTypes и MaxExtDimensionCount, а ПВХ видов субконто заимствован (замер 8.3.24, 8.3.27).
            # ПВХ нет в источнике — свойства не переносим: ссылка на незаимствованный объект не загрузится.
            edt_node = props_node.find(f"{{{MD_NS}}}ExtDimensionTypes")
            max_node = props_node.find(f"{{{MD_NS}}}MaxExtDimensionCount")
            if want_ext_dim and edt_node is not None and max_node is not None and (edt_node.text or "").strip():
                edm = re.match(r'^(\w+)\.(.+)$', edt_node.text.strip())
                ed_found = (edm is not None and edm.group(1) in CHILD_TYPE_DIR_MAP and
                            os.path.isfile(os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[edm.group(1)], f"{edm.group(2)}.xml")))
                if ed_found:
                    extra_props["ExtDimensionTypes"] = edt_node.text.strip()
                    extra_props["MaxExtDimensionCount"] = (max_node.text or "").strip()
                else:
                    warn(f"  {type_name}.{obj_name}: виды субконто {edt_node.text.strip()} не найдены в конфигурации-источнике — "
                         f"ТЧ видов субконто форме расширения не будет видна")

        return {"Attributes": attrs, "TabularSections": tab_sections, "ExtraProps": extra_props}

    # --- 11d. Build adopted attribute XML ---
    def build_adopted_attribute_xml(name, source_uuid, type_xml, indent, kind="Attribute"):
        new_uuid_val = new_guid()
        lines = [
            f'{indent}<{kind} uuid="{new_uuid_val}">',
            f'{indent}\t<InternalInfo/>',
            f'{indent}\t<Properties>',
            f'{indent}\t\t<ObjectBelonging>Adopted</ObjectBelonging>',
            f'{indent}\t\t<Name>{name}</Name>',
            f'{indent}\t\t<Comment/>',
            f'{indent}\t\t<ExtendedConfigurationObject>{source_uuid}</ExtendedConfigurationObject>',
            f'{indent}\t\t{type_xml}',
            f'{indent}\t</Properties>',
            f'{indent}</{kind}>',
        ]
        return "\n".join(lines)

    # --- 11e. Build adopted tabular section XML ---
    def build_adopted_tabular_section_xml(ts_name, source_uuid, generated_types, child_attrs, indent):
        new_uuid_val = new_guid()
        lines = [f'{indent}<TabularSection uuid="{new_uuid_val}">']

        # InternalInfo with GeneratedTypes (new UUIDs, referencing source names)
        if generated_types:
            lines.append(f'{indent}\t<InternalInfo>')
            for gt in generated_types:
                new_tid = new_guid()
                new_vid = new_guid()
                lines.append(f'{indent}\t\t<xr:GeneratedType name="{gt["Name"]}" category="{gt["Category"]}">')
                lines.append(f'{indent}\t\t\t<xr:TypeId>{new_tid}</xr:TypeId>')
                lines.append(f'{indent}\t\t\t<xr:ValueId>{new_vid}</xr:ValueId>')
                lines.append(f'{indent}\t\t</xr:GeneratedType>')
            lines.append(f'{indent}\t</InternalInfo>')
        else:
            lines.append(f'{indent}\t<InternalInfo/>')

        lines.append(f'{indent}\t<Properties>')
        lines.append(f'{indent}\t\t<ObjectBelonging>Adopted</ObjectBelonging>')
        lines.append(f'{indent}\t\t<Name>{ts_name}</Name>')
        lines.append(f'{indent}\t\t<Comment/>')
        lines.append(f'{indent}\t\t<ExtendedConfigurationObject>{source_uuid}</ExtendedConfigurationObject>')
        lines.append(f'{indent}\t</Properties>')

        # ChildObjects with all attributes
        if child_attrs:
            lines.append(f'{indent}\t<ChildObjects>')
            for ca in child_attrs:
                ca_xml = build_adopted_attribute_xml(ca["Name"], ca["Uuid"], ca["TypeXml"], f"{indent}\t\t")
                lines.append(ca_xml)
            lines.append(f'{indent}\t</ChildObjects>')
        else:
            lines.append(f'{indent}\t<ChildObjects/>')

        lines.append(f'{indent}</TabularSection>')
        return "\n".join(lines)

    # --- 11f. Collect reference types from attribute Type XML strings ---
    def collect_reference_types(type_xmls):
        result = {}
        for type_xml in type_xmls:
            # cfg:CatalogRef.XXX, cfg:EnumRef.XXX, cfg:DocumentRef.XXX, etc.
            for m in re.finditer(r'cfg:(\w+)Ref\.(\w+)', type_xml):
                ref_prefix = m.group(1)
                obj_n = m.group(2)
                key = f"{ref_prefix}.{obj_n}"
                if key not in result:
                    result[key] = {"TypeName": ref_prefix, "ObjName": obj_n}
            # cfg:DefinedType.XXX
            for m in re.finditer(r'cfg:DefinedType\.(\w+)', type_xml):
                dt_name = m.group(1)
                key = f"DefinedType.{dt_name}"
                if key not in result:
                    result[key] = {"TypeName": "DefinedType", "ObjName": dt_name}
        return list(result.values())

    # --- 11g. Merge adopted attributes into existing extension object XML ---
    def merge_attributes_into_object(type_name, obj_name, attrs_to_add):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")
        if not os.path.isfile(obj_file):
            warn(f"Cannot merge attributes: {obj_file} not found")
            return

        # newline="" => без трансляции: иначе CRLF молча схлопнется в LF при чтении
        # и файл будет переписан в LF.
        style = _detect_xml_style(obj_file)
        with open(obj_file, "r", encoding="utf-8-sig", newline="") as fh:
            obj_content = fh.read()

        # Collect existing names for dedup — только прямые дети своего ChildObjects
        existing_names = get_own_child_object_names(obj_file)

        added = 0
        for attr in attrs_to_add:
            if attr["Name"] in existing_names:
                continue
            kind = attr.get("Kind", "Attribute")
            obj_content = insert_own_child_or_die(
                obj_content, build_adopted_attribute_xml(attr["Name"], attr["Uuid"], attr["TypeXml"], "\t\t\t", kind),
                kind, type_name, obj_file)
            added += 1

        if added > 0:
            write_text_keep_bom(obj_file, obj_content, style)
            info(f"  Merged {added} attribute(s) into: {obj_file}")

    # Колонки источника — в уже заимствованную ТЧ объекта расширения (недостающие по имени; свои колонки
    # и порядок остальных не трогаем). Возвращает число добавленных; ТЧ нет — -1.
    def merge_columns_into_tabular_section(type_name, obj_name, ts_name, cols):
        obj_file = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[type_name], f"{obj_name}.xml")
        style = _detect_xml_style(obj_file)
        with open(obj_file, "r", encoding="utf-8-sig", newline="") as fh:
            text = fh.read()
        span = find_own_tabular_section_span(text, ts_name)
        if not span:
            return -1
        block = text[span[0]:span[1]]
        # Имена колонок — все <Name> блока, кроме первого (имя самой ТЧ)
        existing = {m.group(1).lower() for m in list(re.finditer(r'<Name>([^<]*)</Name>', block))[1:]}
        ls = text.rfind("\n", 0, span[0]) + 1
        col_indent = text[ls:span[0]] + "\t\t"
        added = 0
        for c in cols:
            if c["Name"].lower() in existing:
                continue
            new_block = insert_into_own_child_objects_by_canon(
                block, build_adopted_attribute_xml(c["Name"], c["Uuid"], c["TypeXml"], col_indent), "Attribute", "TabularSection")
            if new_block is None:
                warn(f"  Tabular section {ts_name} has no <ChildObjects> — attribute {c['Name']} not added")
                break
            block = new_block
            existing.add(c["Name"].lower())
            added += 1
        if added > 0:
            text = text[:span[0]] + block + text[span[1]:]
            write_text_keep_bom(obj_file, text, style)
            info(f"  Merged {added} attribute(s) into tabular section {ts_name}: {obj_file}")
        return added

    # --- 11h. Borrow main attribute orchestrator ---
    # Объект-оболочка в расширении: кто уже заимствован — пропускается, без источника — предупреждение.
    def borrow_object_shell(type_name, obj_name):
        if type_name not in CHILD_TYPE_DIR_MAP:
            warn(f"  Unknown object type: {type_name}.{obj_name}")
            return
        if test_object_borrowed(type_name, obj_name):
            info(f"  Already borrowed: {type_name}.{obj_name}")
            return
        src_file = os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[type_name], f"{obj_name}.xml")
        if not os.path.isfile(src_file):
            warn(f"  Source not found: {type_name}.{obj_name}")
            return
        src = read_source_object(type_name, obj_name)
        borrowed_xml = build_borrowed_object_xml(type_name, obj_name, src["Uuid"], src["Properties"])
        target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[type_name])
        os.makedirs(target_dir, exist_ok=True)
        target_file = os.path.join(target_dir, f"{obj_name}.xml")
        write_xml_file(target_file, borrowed_xml)
        add_to_child_objects(type_name, obj_name)
        borrowed_files.append(target_file)
        info(f"  Auto-borrowed: {type_name}.{obj_name}")
        # Оболочка определяемого типа несёт его состав: объекты из состава — оболочками (эталон
        # Конфигуратора). Без них ниже 8.3.25 загрузка падает: «Неизвестное имя типа».
        if type_name == "DefinedType" and "__TypeXml" in src["Properties"]:
            for rt in collect_reference_types([src["Properties"]["__TypeXml"]]):
                borrow_object_shell(rt["TypeName"], rt["ObjName"])

    def resolve_single_ref_target(type_xml, allow_defined=True):
        """Единственный объект, на который ведёт ссылочный тип: <Вид>Ref.<Имя> или определяемый тип из одной
        такой ссылки (состав — из источника). Составной, примитивный, неизвестный вид — None: дальше
        такого типа путь формы не продолжается. Определяемый тип раскрывается один раз: в его составе
        определяемых типов не бывает."""
        types = re.findall(r'<v8:(?:Type|TypeSet)>([^<]+)</v8:(?:Type|TypeSet)>', type_xml)
        if len(types) != 1:
            return None
        dt = re.match(r'^(?:\w+:)?DefinedType\.(\w+)$', types[0])
        if dt and not allow_defined:
            return None
        if dt:
            dt_file = os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP["DefinedType"], f"{dt.group(1)}.xml")
            if not os.path.isfile(dt_file):
                return None
            dt_src = read_source_object("DefinedType", dt.group(1))
            if "__TypeXml" not in dt_src["Properties"]:
                return None
            return resolve_single_ref_target(dt_src["Properties"]["__TypeXml"], False)
        ref = re.match(r'^(?:\w+:)?(\w+)Ref\.(\w+)$', types[0])
        if not ref or ref.group(1) not in CHILD_TYPE_DIR_MAP:
            return None
        return {"TypeName": ref.group(1), "ObjName": ref.group(2)}

    def borrow_reference_type_shells(type_xmls):
        """Ссылочные типы → объекты-оболочки в расширении (кто уже заимствован — пропускается)."""
        ref_types = collect_reference_types(type_xmls)
        info(f"  Reference types to borrow: {len(ref_types)}")

        for rt in ref_types:
            borrow_object_shell(rt["TypeName"], rt["ObjName"])

    # Владелец общей формы — из ТИПА её основного реквизита (эталон УТ CommonMain):
    # <Вид>Object.Имя / <Вид>RecordManager.Имя → объект; DynamicList → объект из <MainTable>;
    # ConstantsSet → константы по путям формы. Примитив, тип без имени (ReportObject — любой отчёт),
    # список без MainTable → владельца нет: в расширение идёт только сам реквизит формы.
    common_form_owner_kinds = {
        'CatalogObject': 'Catalog', 'DocumentObject': 'Document', 'DataProcessorObject': 'DataProcessor', 'ReportObject': 'Report',
        'ChartOfCharacteristicTypesObject': 'ChartOfCharacteristicTypes', 'ChartOfAccountsObject': 'ChartOfAccounts',
        'ChartOfCalculationTypesObject': 'ChartOfCalculationTypes', 'ExchangePlanObject': 'ExchangePlan',
        'BusinessProcessObject': 'BusinessProcess', 'TaskObject': 'Task',
        'InformationRegisterRecordManager': 'InformationRegister', 'InformationRegisterRecordSet': 'InformationRegister',
        'AccumulationRegisterRecordSet': 'AccumulationRegister',
    }

    def resolve_common_form_owner(form_el):
        main_attr = None
        for attrs in form_el:
            if isinstance(attrs.tag, str) and localname(attrs) == "Attributes":
                for a in attrs:
                    if not isinstance(a.tag, str) or localname(a) != "Attribute":
                        continue
                    if any(isinstance(c.tag, str) and localname(c) == "MainAttribute" and (c.text or "").strip() == "true" for c in a):
                        main_attr = a
                        break
                break
        if main_attr is None:
            return None
        type_text = ""
        for c in main_attr:
            if isinstance(c.tag, str) and localname(c) == "Type":
                for tn in c:
                    if isinstance(tn.tag, str) and localname(tn) == "Type":
                        type_text = (tn.text or "").strip()
                        break
                break
        if type_text == "cfg:ConstantsSet":
            return {"Kind": "Constants", "MainName": main_attr.get("name")}
        m = re.match(r'^cfg:(\w+)\.(\w+)$', type_text)
        if m and m.group(1) in common_form_owner_kinds:
            return {"Kind": "Object", "TypeName": common_form_owner_kinds[m.group(1)], "ObjName": m.group(2), "ByType": True}
        if type_text == "cfg:DynamicList":
            for el in main_attr.iter():
                if isinstance(el.tag, str) and localname(el) == "MainTable":
                    mtm = re.match(r'^(\w+)\.(\w+)$', (el.text or "").strip())
                    if mtm and mtm.group(1) in CHILD_TYPE_DIR_MAP:
                        return {"Kind": "Object", "TypeName": mtm.group(1), "ObjName": mtm.group(2)}
                    break
        return None

    def resolve_main_attribute_object(form_el, type_name, obj_name):
        """Объект, по которому разрешаются пути формы объекта: тип основного реквизита <Вид>Object.Имя и т.п.,
        а не владелец формы — форма обработки с основным реквизитом DocumentObject.X видит реквизиты X (замер
        8.3.24, #120). Список (DynamicList) и прочие типы — владелец формы, как раньше."""
        o = resolve_common_form_owner(form_el)
        if o and o["Kind"] == "Object" and o.get("ByType"):
            return {"TypeName": o["TypeName"], "ObjName": o["ObjName"]}
        return {"TypeName": type_name, "ObjName": obj_name}

    def borrow_form_constants(src_form_xml_path, main_name):
        """Набор констант как основной реквизит общей формы: заимствуются константы, пути на которые есть
        в форме (<Реквизит>.<Константа>), — с типом как в источнике; их ссылочные типы — оболочками
        (эталон УТ CommonMain: НастройкаПереводаТекста → две константы + перечисление из типа)."""
        info(f"Borrowing constants for main attribute {main_name} (ConstantsSet)...")
        names = collect_form_data_paths(src_form_xml_path, main_name)["FirstLevel"]
        type_xmls = []
        for c_name in list(names.keys()):
            c_src_file = os.path.join(cfg_dir, "Constants", f"{c_name}.xml")
            if not os.path.isfile(c_src_file):
                continue
            with open(c_src_file, "r", encoding="utf-8-sig") as fh:
                c_text = fh.read()
            # С пробелами: вложенные отступы типа в источнике — ровно та же глубина, что в расширении
            tm = re.search(r'<Constant uuid="[^"]+">[\s\S]*?<Properties>[\s\S]*?(<Type>[\s\S]*?</Type>)', c_text)
            c_type_xml = re.sub(r'\s+xmlns(?::\w+)?="[^"]*"', '', tm.group(1)).replace("\r\n", "\n") if tm else ""
            if c_type_xml:
                type_xmls.append(c_type_xml)
            def add_type(xml):
                # Тип — последним свойством, после ExtendedConfigurationObject (как у Конфигуратора)
                return re.sub(r'(?P<ind>[ \t]*)<ExtendedConfigurationObject>[^<]*</ExtendedConfigurationObject>',
                              lambda mm: mm.group(0) + "\n" + mm.group('ind') + c_type_xml, xml, count=1)
            if test_object_borrowed("Constant", c_name):
                # Заимствованная раньше оболочкой (-Object Constant.X) — без типа: дописываем, как при
                # слиянии реквизитов в уже заимствованный объект
                ext_c_file = os.path.join(ext_dir, "Constants", f"{c_name}.xml")
                with open(ext_c_file, "r", encoding="utf-8-sig", newline="") as fh:
                    ext_c_text = fh.read()
                if c_type_xml and '<Type>' not in ext_c_text:
                    write_xml_file(ext_c_file, add_type(ext_c_text.replace("\r\n", "\n")))
                    info(f"  Added type: Constant.{c_name}")
                else:
                    info(f"  Already borrowed: Constant.{c_name}")
                continue
            src = read_source_object("Constant", c_name)
            borrowed_xml = build_borrowed_object_xml("Constant", c_name, src["Uuid"], src["Properties"])
            if c_type_xml:
                borrowed_xml = add_type(borrowed_xml)
            target_dir = os.path.join(ext_dir, "Constants")
            os.makedirs(target_dir, exist_ok=True)
            target_file = os.path.join(target_dir, f"{c_name}.xml")
            write_xml_file(target_file, borrowed_xml)
            add_to_child_objects("Constant", c_name)
            borrowed_files.append(target_file)
            info(f"  Borrowed: Constant.{c_name}")
        borrow_reference_type_shells(type_xmls)

    def borrow_main_attribute(type_name, obj_name, form_name, mode, src_form_xml_path=""):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        info(f"Borrowing main attribute for {type_name}.{obj_name} (mode: {mode})...")
        # Путь к исходной форме: у общей формы его передают явно (владелец выведен из типа реквизита)
        if not src_form_xml_path:
            src_form_xml_path = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml")

        # Step 1: Collect DataPaths (Form mode) or take all (All mode)
        first_level_names = None
        deep_paths = []
        if mode == "Form":
            if not os.path.isfile(src_form_xml_path):
                print(f"Source Form.xml not found: {src_form_xml_path}", file=sys.stderr)
                sys.exit(1)
            # Имя основного реквизита исходной формы — корень путей, которые надо собрать
            dp_ns_strip = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')
            dp_info = get_main_attribute_info(etree.parse(src_form_xml_path).getroot(), dp_ns_strip)
            if dp_info is None:
                warn("  У формы нет основного реквизита — заимствовать нечего")
                return
            dp = collect_form_data_paths(src_form_xml_path, dp_info["Name"])
            first_level_names = dp["FirstLevel"]
            deep_paths = dp["DeepPaths"]
            info(f"  Collected {len(first_level_names)} first-level DataPath references, {len(deep_paths)} deep paths")
        else:
            info("  Mode All: borrowing all attributes and tabular sections")
            # Первый уровень — все реквизиты, но глубокие пути формы те же: объекты по ссылкам из них
            # нужны с показанными реквизитами в любом режиме
            if os.path.isfile(src_form_xml_path):
                dp_ns_strip = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')
                dp_info = get_main_attribute_info(etree.parse(src_form_xml_path).getroot(), dp_ns_strip)
                if dp_info is not None:
                    deep_paths = collect_form_data_paths(src_form_xml_path, dp_info["Name"])["DeepPaths"]

        # Step 2: Resolve source attributes
        resolved = resolve_source_attributes(type_name, obj_name, first_level_names)
        src_attrs = resolved["Attributes"]
        src_ts = resolved["TabularSections"]
        extra_props = resolved["ExtraProps"]
        info(f"  Resolved: {len(src_attrs)} attributes, {len(src_ts)} tabular section(s)")

        # Identify which FirstLevel names are TabularSections (for deep path filtering)
        ts_names = {ts["Name"]: True for ts in src_ts}

        # Step 3: Build the adopted content and insert into main object XML
        obj_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")

        # Read existing object XML (needed for dedup + enrichment)
        # newline="" => без трансляции: иначе CRLF молча схлопнется в LF при чтении
        # и файл будет переписан в LF.
        obj_style = _detect_xml_style(obj_file)
        with open(obj_file, "r", encoding="utf-8-sig", newline="") as fh:
            obj_content = fh.read()

        # Dedup: skip attributes/TS already present in object's ChildObjects (idempotent re-borrow)
        existing_child_names = get_own_child_object_names(obj_file)
        insert_attrs = [a for a in src_attrs if a["Name"] not in existing_child_names]
        insert_ts = [t for t in src_ts if t["Name"] not in existing_child_names]

        # Узлы заимствуемого содержимого: (тег, XML). Место каждому — по канону вида при вставке
        content_parts = []
        for attr in insert_attrs:
            kind = attr.get("Kind", "Attribute")
            content_parts.append((kind, build_adopted_attribute_xml(attr["Name"], attr["Uuid"], attr["TypeXml"], "\t\t\t", kind)))
        for ts in insert_ts:
            content_parts.append(("TabularSection", build_adopted_tabular_section_xml(ts["Name"], ts["Uuid"], ts["GeneratedTypes"], ts["Attributes"], "\t\t\t")))

        # Inject extra properties into the object's OWN Properties only — idempotent and anchored to the
        # first ExtendedConfigurationObject (the object's). On re-borrow, adopted attributes each have their
        # own ExtendedConfigurationObject; a global replace would push object props inside every <Attribute>.
        if extra_props:
            m_props = re.search(r'(?s)<Properties>(.*?)</Properties>', obj_content)
            obj_props_block = m_props.group(1) if m_props else ""
            props_xml = ""
            for p_name, p_val in extra_props.items():
                if f"<{p_name}>" in obj_props_block:
                    continue
                props_xml += f"\r\n\t\t\t<{p_name}>{p_val}</{p_name}>"
            if props_xml:
                obj_content = obj_content.replace("</ExtendedConfigurationObject>", f"</ExtendedConfigurationObject>{props_xml}", 1)

        # Добавить заимствованное содержимое в ChildObjects объекта (там уже может лежать <Form>)
        for part_tag, part_xml in content_parts:
            obj_content = insert_own_child_or_die(obj_content, part_xml, part_tag, type_name, obj_file)

        write_text_keep_bom(obj_file, obj_content, obj_style)
        info(f"  Enriched object: {obj_file}")

        # ТЧ уже в расширении (заимствована без формы, своими колонками) — колонки, которые нужны форме,
        # доливаются в неё: пропуск по имени оставил бы форму с «Неверный путь к данным Объект.<ТЧ>.<Колонка>»
        for ts in src_ts:
            if ts["Name"] not in existing_child_names:
                continue
            if merge_columns_into_tabular_section(type_name, obj_name, ts["Name"], ts["Attributes"]) < 0:
                warn(f"  {ts['Name']}: name is taken in {type_name}.{obj_name}, but not by a tabular section \u2014 "
                     f"its attributes not borrowed")

        # Step 4: Collect all reference types and borrow as shells
        all_type_xmls = []
        for a in src_attrs:
            all_type_xmls.append(a["TypeXml"])
        for ts in src_ts:
            for tsa in ts["Attributes"]:
                all_type_xmls.append(tsa["TypeXml"])
        # Типы из <Columns> основного реквизита формы: колонку мы переносим (borrow_form), значит и её
        # тип должен быть заимствован — иначе колонка ссылается на DefinedType/справочник, которого в
        # расширении нет. Конфигуратор поступает так же (эталон: DefinedTypes/Артикул при заимствовании
        # формы заказа поставщику).
        src_form_for_cols = src_form_xml_path
        if os.path.isfile(src_form_for_cols):
            cols_tree = etree.parse(src_form_for_cols)
            cols_ns_strip = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')
            cols_info = get_main_attribute_info(cols_tree.getroot(), cols_ns_strip)
            if cols_info:
                all_type_xmls.extend(re.findall(r'(?s)<Columns>.*?</Columns>', cols_info["Xml"]))

        borrow_reference_type_shells(all_type_xmls)
        # ПВХ видов субконто, на который ссылается перенесённое свойство ExtDimensionTypes, — оболочкой:
        # иначе «Неизвестный объект метаданных» при загрузке
        if "ExtDimensionTypes" in extra_props:
            edm = re.match(r'^(\w+)\.(.+)$', extra_props["ExtDimensionTypes"])
            if edm:
                borrow_object_shell(edm.group(1), edm.group(2))

        # Step 5: Deep paths — Объект.<Реквизит>.<…> and Объект.<ТЧ>.<Колонка>.<…>. Each reference step borrows
        # its target object with the next segment's attribute (Designer etalon), down the whole chain
        if deep_paths:
            info(f"  Processing {len(deep_paths)} deep path(s)...")
            # Имена в пути формы — без учёта регистра, как у платформы
            std_upper = {f.upper() for f in STANDARD_FIELDS}
            for segs in deep_paths:
                ts_info = next((t for t in src_ts if t["Name"].upper() == segs[0].upper()), None)
                if ts_info:
                    start_attr = next((c for c in ts_info["Attributes"] if c["Name"].upper() == segs[1].upper()), None)
                    nxt = 2
                else:
                    start_attr = next((a for a in src_attrs if a["Name"].upper() == segs[0].upper()), None)
                    nxt = 1
                if not start_attr:
                    continue
                type_xml = start_attr["TypeXml"]
                for i in range(nxt, len(segs)):
                    if segs[i].upper() in std_upper:
                        break
                    target = resolve_single_ref_target(type_xml)
                    if not target:
                        break
                    merged = borrow_deep_target_attrs(target["TypeName"], target["ObjName"], [segs[i]])
                    if not merged:
                        break
                    type_xml = merged[0]["TypeXml"]

        info("  Main attribute borrowing complete")

    def borrow_deep_target_attrs(target_type_name, target_obj_name, sub_attr_names):
        # Borrow a deep-path target object together with the referenced sub-attributes. Mirrors Designer:
        # the referenced object is adopted WITH the sub-attributes the form shows, else the platform rejects
        # the deep DataPath. Returns the merged source attributes (Name/TypeXml) — the chain walk continues
        # along their types.
        borrow_object_shell(target_type_name, target_obj_name)
        if not test_object_borrowed(target_type_name, target_obj_name):
            return []
        sub_names = {sn: True for sn in sub_attr_names}
        sub_resolved = resolve_source_attributes(target_type_name, target_obj_name, sub_names)
        if not sub_resolved["Attributes"]:
            return []
        merge_attributes_into_object(target_type_name, target_obj_name, sub_resolved["Attributes"])
        # Ссылочные типы смёрженных реквизитов — оболочками
        borrow_reference_type_shells([sa["TypeXml"] for sa in sub_resolved["Attributes"]])
        return sub_resolved["Attributes"]

    def borrow_form(type_name, obj_name, form_name, borrow_main_attr=False):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]

        # Общая форма — сама объект конфигурации: описание CommonForms/<Имя>.xml с корнем <CommonForm>,
        # тело CommonForms/<Имя>/Ext/Form.xml, регистрация в Configuration.xml. Форма объекта — в Forms
        # владельца. Остальное (скелет, BaseForm, связи, оформление, картинки) одинаково (эталон УТ link).
        is_common_form = type_name == "CommonForm"
        # Уже заимствованная общая форма (в т.ч. оболочкой от прежних версий навыка) в Configuration.xml
        # уже есть — повторно не регистрируем
        common_form_registered = is_common_form and test_object_borrowed(type_name, obj_name)
        if is_common_form:
            src_form_dir = os.path.join(cfg_dir, dir_name, obj_name)
            form_meta_file = os.path.join(ext_dir, dir_name, f"{obj_name}.xml")
            ext_form_dir = os.path.join(ext_dir, dir_name, obj_name)
            form_meta_tag = "CommonForm"
        else:
            src_form_dir = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name)
            form_meta_file = os.path.join(ext_dir, dir_name, obj_name, "Forms", f"{form_name}.xml")
            ext_form_dir = os.path.join(ext_dir, dir_name, obj_name, "Forms", form_name)
            form_meta_tag = "Form"

        # 1. Read source form UUID
        form_uuid = read_source_form_uuid(type_name, obj_name, form_name)
        info(f"  Source form UUID: {form_uuid}")

        # 2. Read source Form.xml
        src_form_xml_path = os.path.join(src_form_dir, "Ext", "Form.xml")
        if not os.path.isfile(src_form_xml_path):
            print(f"Source Form.xml not found: {src_form_xml_path}", file=sys.stderr)
            sys.exit(1)
        with open(src_form_xml_path, "r", encoding="utf-8-sig") as fh:
            src_form_content = fh.read()

        # 3. Generate form metadata XML.
        # If the wrapper was already borrowed, reuse its uuid so re-borrow is idempotent
        # (regenerating it would churn the form's identity on every rerun).
        new_form_uuid = ""
        if os.path.isfile(form_meta_file):
            try:
                existing_root = etree.parse(form_meta_file).getroot()
                for c in existing_root:
                    if isinstance(c.tag, str) and localname(c) == form_meta_tag:
                        new_form_uuid = c.get("uuid", "") or ""
                        break
            except Exception:
                new_form_uuid = ""
        if not new_form_uuid:
            new_form_uuid = new_guid()
        form_meta_lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<MetaDataObject {XMLNS_DECL} version="{format_version}">',
            f'\t<{form_meta_tag} uuid="{new_form_uuid}">',
            '\t\t<InternalInfo/>',
            '\t\t<Properties>',
            '\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>',
            f'\t\t\t<Name>{form_name}</Name>',
            '\t\t\t<Comment/>',
            f'\t\t\t<ExtendedConfigurationObject>{form_uuid}</ExtendedConfigurationObject>',
            '\t\t\t<FormType>Managed</FormType>',
            '\t\t</Properties>',
            f'\t</{form_meta_tag}>',
            '</MetaDataObject>',
        ]

        # 4. Create directories
        form_meta_dir = os.path.dirname(form_meta_file)
        os.makedirs(form_meta_dir, exist_ok=True)

        write_xml_file(form_meta_file, "\n".join(form_meta_lines))
        info(f"  Created: {form_meta_file}")

        # 5. Generate Form.xml with BaseForm
        src_form_parser = etree.XMLParser(remove_blank_text=False)
        src_form_tree = etree.parse(src_form_xml_path, src_form_parser)
        src_form_el = src_form_tree.getroot()

        # Borrowed form uses the extension's format version (not the source form's) — keeps the
        # extension uniform; otherwise the platform rejects the import on a version mismatch
        # (e.g. a 2.13 form inside a 2.17 extension). The platform upgrades the form to the root version.
        form_version = format_version

        # Секции формы отбираются по имени, а не по позиции: свойства лежат и до, и после
        # <CommandSet> (корпусная проверка: у всех 794 форм документов ERP с CommandSet он стоит
        # раньше AutoCommandBar, а AutoTime/UsePostingMode/RepostOnWrite — после него). Позиционная
        # отсечка теряла весь хвост, и платформа молча подставляла дефолты вместо потерянных свойств.
        src_auto_cmd = None
        form_props = []
        for fc in src_form_el:
            if not isinstance(fc.tag, str):
                continue
            ln = localname(fc)
            if ln == "AutoCommandBar" and src_auto_cmd is None:
                src_auto_cmd = fc
                continue
            # ChildItems забирается отдельным поиском ниже
            if ln == "ChildItems":
                continue
            # Структурные секции: в расширении их содержимое недействительно (обработчики, команды и
            # параметры базовой формы, ссылки командного интерфейса на команды базовой конфигурации).
            if ln in FORM_STRUCTURAL_SECTIONS:
                continue
            # Свойства, значение которых — имя реквизита формы. Реквизиты в заимствованную форму не
            # переносятся, поэтому Конфигуратор такие свойства выбрасывает (проверено на форме отчёта:
            # ReportResult и DetailsData выброшены, CustomSettingsFolder — имя элемента — сохранён).
            if ln in FORM_ATTRIBUTE_REF_PROPS:
                continue
            # with_tail=False — хвостовой пробел принадлежит родителю; с ним в вывод попадали
            # пустые строки, которых нет у PS-порта (OuterXml хвост не включает).
            form_props.append(decode_numeric_entities(etree.tostring(fc, encoding="unicode", with_tail=False)))

        ns_strip_pattern = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')

        # uuid реквизитов объекта — только для формы без заимствованного основного реквизита:
        # там ссылки параметров выбора переводятся на непрозрачную форму пути
        # Имя основного реквизита источника нужно в обоих режимах: по нему опознаётся корень путей
        # в ссылках параметров выбора. А main_attr_name управляет вырезанием привязок и потому
        # остаётся пустым в скелетном режиме — там привязки снимаются все.
        src_main_info = get_main_attribute_info(src_form_el, ns_strip_pattern)
        src_main_attr_name = src_main_info["Name"] if src_main_info else ""
        form_attr_ids = get_form_attribute_ids(src_form_el)
        # Условное оформление формы Конфигуратор копирует как есть в обе части, внутрь <Attributes>
        # после реквизитов — и без основного реквизита тоже; ссылки на незаимствованные реквизиты формы
        # платформа принимает (эталоны УТ StdPic, StdPic_WithMain, CAStyle, УНФ Номенклатура)
        src_cond_appearance_xml = ""
        for attrs_el in src_form_el:
            if isinstance(attrs_el.tag, str) and localname(attrs_el) == "Attributes":
                for ca_el in attrs_el:
                    if isinstance(ca_el.tag, str) and localname(ca_el) == "ConditionalAppearance":
                        src_cond_appearance_xml = ns_strip_pattern.sub("", decode_numeric_entities(
                            etree.tostring(ca_el, encoding="unicode", with_tail=False)))
                        break
                break

        # Основной реквизит исходной формы: его имя — корень путей к данным, которые нужно сохранить
        # («Объект.» у формы объекта, «Список.» у формы списка, «Запись.» у формы записи регистра)
        main_attr_info = src_main_info if borrow_main_attr else None
        # Имена реквизитов объекта нужны в обоих режимах: без заимствования — для кода пути в связях
        # формы, с заимствованием — чтобы отличить реквизит (разрешается текстом) от стандартного поля
        # У общей формы реквизиты берутся у владельца, выведенного из типа основного реквизита;
        # у набора констант — ничего: код пути на константу не измерен, связь без основного реквизита
        # вырезается с предупреждением, с ним — остаётся текстом
        if is_common_form:
            cf_owner = resolve_common_form_owner(etree.parse(src_form_xml_path).getroot())
            src_attr_uuids = {}
            if cf_owner and cf_owner["Kind"] == "Object":
                src_attr_uuids = get_source_attribute_uuids(cf_owner["TypeName"], cf_owner["ObjName"])
            elif cf_owner and cf_owner["Kind"] == "Constants":
                # Константы, на которые есть пути: с основным реквизитом путь на заимствованную — текстом
                for c_name in list(collect_form_data_paths(src_form_xml_path, cf_owner["MainName"])["FirstLevel"].keys()):
                    c_file = os.path.join(cfg_dir, "Constants", f"{c_name}.xml")
                    if not os.path.isfile(c_file):
                        continue
                    with open(c_file, "r", encoding="utf-8-sig") as fh:
                        cm = re.search(r'<Constant uuid="([^"]+)"', fh.read())
                    if cm:
                        src_attr_uuids[c_name] = cm.group(1)
        else:
            ma_obj = resolve_main_attribute_object(src_form_el, type_name, obj_name)
            src_attr_uuids = get_source_attribute_uuids(ma_obj["TypeName"], ma_obj["ObjName"])
        # Реквизиты объекта, которые попадут в расширение: в режиме Form — только используемые формой
        # (тот же сбор, что в borrow_main_attribute), в режиме All — все (None)
        borrowed_names = None
        if main_attr_info is not None and borrow_main_attribute_mode == "Form":
            borrowed_names = collect_form_data_paths(src_form_xml_path, src_main_attr_name)["FirstLevel"]
        link_ctx = get_link_context(src_form_el, src_main_attr_name, main_attr_info is not None,
                                    borrowed_names, src_attr_uuids, form_attr_ids)
        main_attr_name = main_attr_info["Name"] if main_attr_info else ""
        if borrow_main_attr and main_attr_info is None:
            warn("  У формы нет основного реквизита — -BorrowMainAttribute проигнорирован")

        # AutoCommandBar: keep ChildItems (buttons with CommandName->0), Autofill->false
        auto_cmd_xml = ""
        if src_auto_cmd is not None:
            auto_cmd_xml = decode_numeric_entities(etree.tostring(src_auto_cmd, encoding="unicode", with_tail=False))
            auto_cmd_xml = ns_strip_pattern.sub("", auto_cmd_xml)
            auto_cmd_xml = re.sub(r'<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>', auto_cmd_xml)
            auto_cmd_xml = auto_cmd_xml.replace('<Autofill>true</Autofill>', '<Autofill>false</Autofill>')
            # Вложенный CommandSet выбрасывается целиком, а не опустошается: Конфигуратор в заимствованной
            # форме оставляет только корневой (тот идёт свойством формы, здесь его нет).
            auto_cmd_xml = re.sub(r'(?s)\s*<CommandSet>.*?</CommandSet>', '', auto_cmd_xml)
            auto_cmd_xml = re.sub(r'\s*<CommandSet/>', '', auto_cmd_xml)
            # Strip data-binding tags whose root attribute isn't borrowed
            auto_cmd_xml = strip_form_bindings(auto_cmd_xml, main_attr_name)
            auto_cmd_xml = rewrite_choice_parameter_links(auto_cmd_xml, link_ctx)

        # ChildItems: copy full tree, clean up base-config references
        child_items_xml = ""
        src_child_items = None
        for fc in src_form_el:
            if isinstance(fc.tag, str) and localname(fc) == "ChildItems":
                src_child_items = fc
                break

        # Картинка декорации в заимствованную форму не переносится: Конфигуратор выбрасывает <Picture>
        # у PictureDecoration из обеих частей формы при любом виде картинки (своя, общая, стандартная)
        # и не тянет за ней ни файл, ни общую картинку. Замер 8.3.27: 10 декораций в 5 формах УТ.
        # Картинки кнопок, таблиц и полей картинки остаются — вместе с файлами, см. копирование ниже.
        if src_child_items is not None:
            for deco in [e for e in src_child_items.iter() if isinstance(e.tag, str) and localname(e) == "PictureDecoration"]:
                for deco_pic in [c for c in deco if isinstance(c.tag, str) and localname(c) == "Picture"]:
                    # Отступ перед картинкой — хвост предыдущего узла; как в PS-порте, уходит он,
                    # а хвост самой картинки занимает его место.
                    prev = deco_pic.getprevious()
                    if prev is not None:
                        prev.tail = deco_pic.tail
                    else:
                        deco.text = deco_pic.tail
                    deco.remove(deco_pic)

        if src_child_items is not None:
            child_items_xml = decode_numeric_entities(etree.tostring(src_child_items, encoding="unicode", with_tail=False))
            child_items_xml = ns_strip_pattern.sub("", child_items_xml)
            # Replace all CommandName values with 0
            child_items_xml = re.sub(r'<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>', child_items_xml)
            # Strip data-binding tags whose root attribute isn't borrowed
            child_items_xml = strip_form_bindings(child_items_xml, main_attr_name)
            child_items_xml = rewrite_choice_parameter_links(child_items_xml, link_ctx)
            # Вложенные CommandSet (у таблиц, полей табличного документа и т.п.) — целиком, см. выше.
            # Исключение — набор таблицы самого основного реквизита, когда он заимствован: его команды
            # (Find/CancelSearch динамического списка) снова разрешимы, и Конфигуратор набор оставляет
            # (эталоны УТ CommonMain/ФайлыВТоме, StdPic_WithMain/ЖурналСкладскихАктов; без основного
            # реквизита и у прочих элементов — выброшен во всех эталонах).
            kept_cmd_sets = {}
            if main_attr_name:
                main_table_pat = (r'(?s)(<Table name="[^"]+" id="\d+">(?:(?!<ChildItems>|</Table>|<CommandSet>).)*?<DataPath>'
                                  + re.escape(main_attr_name)
                                  + r'</DataPath>(?:(?!<ChildItems>|</Table>|<CommandSet>).)*?)(<CommandSet>.*?</CommandSet>)')

                def keep_cmd_set(m):
                    key = f"@@KEPTCMDSET{len(kept_cmd_sets)}@@"
                    kept_cmd_sets[key] = m.group(2)
                    return m.group(1) + key
                child_items_xml = re.sub(main_table_pat, keep_cmd_set, child_items_xml)
            child_items_xml = re.sub(r'(?s)\s*<CommandSet>.*?</CommandSet>', '', child_items_xml)
            child_items_xml = re.sub(r'\s*<CommandSet/>', '', child_items_xml)
            for key, val in kept_cmd_sets.items():
                child_items_xml = child_items_xml.replace(key, val)
            child_items_xml = rewrite_type_links(child_items_xml, link_ctx)
            # Strip element-level Events
            child_items_xml = re.sub(r'\s*<Events>.*?</Events>', '', child_items_xml, flags=re.DOTALL)

            # Collect CommonPicture references from ChildItems and AutoCommandBar
            referenced_pictures = {}
            for name in re.findall(r'<xr:Ref>CommonPicture\.(\w+)</xr:Ref>', child_items_xml):
                referenced_pictures[name] = True
            if auto_cmd_xml:
                for name in re.findall(r'<xr:Ref>CommonPicture\.(\w+)</xr:Ref>', auto_cmd_xml):
                    referenced_pictures[name] = True

            # Auto-borrow referenced CommonPictures
            auto_borrowed_pics = []
            for pic_name in referenced_pictures:
                if not test_object_borrowed("CommonPicture", pic_name):
                    pic_src_file = os.path.join(cfg_dir, "CommonPictures", f"{pic_name}.xml")
                    if os.path.isfile(pic_src_file):
                        src = read_source_object("CommonPicture", pic_name)
                        borrowed_xml = build_borrowed_object_xml("CommonPicture", pic_name, src["Uuid"], src["Properties"])
                        target_dir = os.path.join(ext_dir, "CommonPictures")
                        os.makedirs(target_dir, exist_ok=True)
                        target_file = os.path.join(target_dir, f"{pic_name}.xml")
                        write_xml_file(target_file, borrowed_xml)
                        add_to_child_objects("CommonPicture", pic_name)
                        auto_borrowed_pics.append(pic_name)
                        borrowed_files.append(target_file)
                        info(f"  Auto-borrowed: CommonPicture.{pic_name}")
                    else:
                        warn(f"  CommonPicture.{pic_name} not found in source config — will strip from form")

            # Collect all borrowed CommonPictures for Picture stripping
            borrowed_pic_set = set()
            for co_child in child_objs_el:
                if isinstance(co_child.tag, str) and localname(co_child) == "CommonPicture":
                    borrowed_pic_set.add((co_child.text or "").strip())

            # Strip <Picture> blocks referencing non-borrowed CommonPictures (reverse order)
            pic_block_pattern = re.compile(r'\s*<Picture>\s*<xr:Ref>CommonPicture\.(\w+)</xr:Ref>.*?</Picture>', re.DOTALL)
            pic_matches = list(pic_block_pattern.finditer(child_items_xml))
            for pm in reversed(pic_matches):
                cp_name = pm.group(1)
                if cp_name not in borrowed_pic_set:
                    child_items_xml = child_items_xml[:pm.start()] + child_items_xml[pm.end():]
            # Стандартные картинки (StdPicture.*) не вырезаются: Конфигуратор оставляет их у кнопок, подменю
            # и страниц в обеих частях формы (эталоны 8.3.27, 26 элементов в 3 формах).

            # Same Picture strip for AutoCommandBar
            if auto_cmd_xml:
                ac_pic_matches = list(pic_block_pattern.finditer(auto_cmd_xml))
                for pm in reversed(ac_pic_matches):
                    cp_name = pm.group(1)
                    if cp_name not in borrowed_pic_set:
                        auto_cmd_xml = auto_cmd_xml[:pm.start()] + auto_cmd_xml[pm.end():]

            # Auto-borrow Enums + EnumValues referenced via DesignTimeRef
            referenced_enum_values = {}  # enum_name -> set of value_names
            for m in re.finditer(r'xr:DesignTimeRef">Enum\.(\w+)\.EnumValue\.(\w+)', child_items_xml):
                e_name, ev_name = m.group(1), m.group(2)
                if e_name not in referenced_enum_values:
                    referenced_enum_values[e_name] = set()
                referenced_enum_values[e_name].add(ev_name)

            for enum_name, needed_values in referenced_enum_values.items():
                if not test_object_borrowed("Enum", enum_name):
                    enum_src_file = os.path.join(cfg_dir, "Enums", f"{enum_name}.xml")
                    if os.path.isfile(enum_src_file):
                        # Read source Enum to find EnumValue UUIDs
                        src_enum_tree = etree.parse(enum_src_file, etree.XMLParser(remove_blank_text=False))
                        src_enum_root = src_enum_tree.getroot()
                        src_enum_el = None
                        for cn in src_enum_root:
                            if isinstance(cn.tag, str):
                                src_enum_el = cn
                                break

                        # Find needed EnumValues
                        ev_xmls = []
                        for ev_node in src_enum_el.iter():
                            if isinstance(ev_node.tag, str) and localname(ev_node) == "EnumValue":
                                ev_uuid = ev_node.get("uuid", "")
                                name_el = None
                                for props in ev_node:
                                    if isinstance(props.tag, str) and localname(props) == "Properties":
                                        for prop in props:
                                            if isinstance(prop.tag, str) and localname(prop) == "Name":
                                                name_el = prop
                                                break
                                if name_el is not None and (name_el.text or "").strip() in needed_values:
                                    new_ev_uuid = str(uuid.uuid4())
                                    ev_xmls.append(
                                        f'\t\t\t<EnumValue uuid="{new_ev_uuid}">\n'
                                        f'\t\t\t\t<InternalInfo/>\n'
                                        f'\t\t\t\t<Properties>\n'
                                        f'\t\t\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>\n'
                                        f'\t\t\t\t\t<Name>{name_el.text.strip()}</Name>\n'
                                        f'\t\t\t\t\t<Comment/>\n'
                                        f'\t\t\t\t\t<ExtendedConfigurationObject>{ev_uuid}</ExtendedConfigurationObject>\n'
                                        f'\t\t\t\t</Properties>\n'
                                        f'\t\t\t</EnumValue>'
                                    )

                        # Build borrowed Enum with EnumValues
                        src_obj = read_source_object("Enum", enum_name)
                        borrowed_xml = build_borrowed_object_xml("Enum", enum_name, src_obj["Uuid"], src_obj["Properties"])
                        if ev_xmls:
                            ev_block = "\n".join(ev_xmls)
                            borrowed_xml = borrowed_xml.replace("<ChildObjects/>", f"<ChildObjects>\n{ev_block}\n\t\t</ChildObjects>")

                        target_dir = os.path.join(ext_dir, "Enums")
                        os.makedirs(target_dir, exist_ok=True)
                        target_file = os.path.join(target_dir, f"{enum_name}.xml")
                        write_xml_file(target_file, borrowed_xml)
                        add_to_child_objects("Enum", enum_name)
                        borrowed_files.append(target_file)
                        info(f"  Auto-borrowed: Enum.{enum_name} (with {len(ev_xmls)} EnumValue(s))")
                    else:
                        warn(f"  Enum.{enum_name} not found in source config")

        # Вне блока ChildItems: стили нужны и оформлению формы без элементов
        # Auto-borrow StyleItems referenced in ChildItems and in the form's conditional appearance
        # (стиль только из оформления Конфигуратор тоже заимствует — эталон УТ CAStyle).
        # Порядок первого упоминания — как в PS-порте (от него зависит порядок в ChildObjects)
        style_scan_xml = child_items_xml + src_cond_appearance_xml
        referenced_styles = {}
        for m in re.finditer(r'ref="style:(\w+)"[^>]*kind="StyleItem"', style_scan_xml):
            referenced_styles[m.group(1)] = True
        # Закрывающий тег может быть с префиксом: в оформлении значение — <dcscor:value>style:X</dcscor:value>
        for m in re.finditer(r'>style:(\w+)</[\w:]+>', style_scan_xml):
            referenced_styles[m.group(1)] = True

        for style_name in referenced_styles:
            if not test_object_borrowed("StyleItem", style_name):
                style_src_file = os.path.join(cfg_dir, "StyleItems", f"{style_name}.xml")
                if os.path.isfile(style_src_file):
                    src = read_source_object("StyleItem", style_name)
                    borrowed_xml = build_borrowed_object_xml("StyleItem", style_name, src["Uuid"], src["Properties"])
                    target_dir = os.path.join(ext_dir, "StyleItems")
                    os.makedirs(target_dir, exist_ok=True)
                    target_file = os.path.join(target_dir, f"{style_name}.xml")
                    write_xml_file(target_file, borrowed_xml)
                    add_to_child_objects("StyleItem", style_name)
                    borrowed_files.append(target_file)
                    info(f"  Auto-borrowed: StyleItem.{style_name}")
                # Файла нет — встроенный стиль платформы (ImportantColor, AccentColor…): заимствовать
                # нечего, пропускаем молча. Пользовательский стиль, на который ссылается форма, в
                # валидном источнике существует всегда — предупреждение было только шумом.

        # Открывающий тег <Form ...> берём из исходной формы — ради её объявлений пространств
        # имён, но version подставляем СВОЮ: форма обязана нести версию расширения, иначе
        # платформа отвергает импорт (форма 2.13 внутри расширения 2.17). Раньше тег
        # копировался целиком, и версия источника молча побеждала.
        xml_decl = '<?xml version="1.0" encoding="UTF-8"?>'
        form_tag = f'<Form version="{form_version}">'
        m_decl = re.search(r'^(<\?xml[^?]*\?>)', src_form_content)
        if m_decl:
            xml_decl = m_decl.group(1)
        m_tag = re.search(r'(<Form[^>]*>)', src_form_content)
        if m_tag:
            src_ns = re.sub(r'^<Form\s*', '', m_tag.group(1))
            src_ns = re.sub(r'\s*/?>$', '', src_ns)
            src_ns = re.sub(r'\s*version="[^"]*"', '', src_ns)
            # 2.21 (8.5): пространство палитры. Место строгое — после lf, перед style.
            if format_rank(form_version) >= 221 and 'xmlns:pal=' not in src_ns:
                src_ns = src_ns.replace(
                    ' xmlns:style=',
                    ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')
            form_tag = f'<Form {src_ns} version="{form_version}">' if src_ns else f'<Form version="{form_version}">'

        # Build output
        parts = []
        parts.append(xml_decl)
        parts.append("\r\n")
        parts.append(form_tag)
        parts.append("\r\n")

        # Part 1: form properties + AutoCommandBar + ChildItems
        for prop_xml in form_props:
            prop_xml_clean = ns_strip_pattern.sub("", prop_xml)
            parts.append(f"\t{prop_xml_clean}\r\n")
        if auto_cmd_xml:
            parts.append(f"\t{auto_cmd_xml}\r\n")
        if child_items_xml:
            parts.append(f"\t{child_items_xml}\r\n")

        # Attributes: основной реквизит (с -BorrowMainAttribute) и условное оформление формы — после него
        with_main_attr = bool(borrow_main_attr and main_attr_info)
        if with_main_attr or src_cond_appearance_xml:
            parts.append("\t<Attributes>\r\n")
            if with_main_attr:
                parts.append(f"\t\t{main_attr_info['Xml']}\r\n")
            if src_cond_appearance_xml:
                parts.append(f"\t\t{src_cond_appearance_xml}\r\n")
            parts.append("\t</Attributes>")
        else:
            parts.append("\t<Attributes/>")
        parts.append("\r\n")

        # BaseForm: same content, indented one more level (многострочный текст не сдвигается)
        parts.append(f'\t<BaseForm version="{form_version}">\r\n')

        for prop_xml in form_props:
            prop_xml_clean = ns_strip_pattern.sub("", prop_xml)
            parts.append(indent_for_base_form(prop_xml_clean, "\t\t") + "\r\n")
        if auto_cmd_xml:
            parts.append(indent_for_base_form(auto_cmd_xml, "\t\t") + "\r\n")
        if child_items_xml:
            parts.append(indent_for_base_form(child_items_xml, "\t\t") + "\r\n")

        # BaseForm Attributes: same as main section
        if with_main_attr or src_cond_appearance_xml:
            parts.append("\t\t<Attributes>\r\n")
            # В BaseForm та же секция на уровень глубже — сдвиг тот же, что у ChildItems
            if with_main_attr:
                parts.append(indent_for_base_form(main_attr_info['Xml'], "\t\t\t") + "\r\n")
            if src_cond_appearance_xml:
                parts.append(indent_for_base_form(src_cond_appearance_xml, "\t\t\t") + "\r\n")
            parts.append("\t\t</Attributes>")
        else:
            parts.append("\t\t<Attributes/>")
        parts.append("\r\n")
        parts.append("\t</BaseForm>\r\n")
        parts.append("</Form>")

        # Динамический список: оболочка его основной таблицы и тильда у путей полей — в конце запуска
        # (шаги 14a и 14c), по итоговому составу расширения — реквизиты основной таблицы заимствует
        # borrow_main_attribute уже после формы, а в пакете — и соседние формы.
        form_xml_text = "".join(parts)
        pending_dyn_list = with_main_attr and (':DynamicList<' in main_attr_info['Xml']
                                               or 'xsi:type="DynamicList"' in main_attr_info['Xml'])

        form_xml_dir = os.path.join(ext_form_dir, "Ext")
        os.makedirs(form_xml_dir, exist_ok=True)
        form_xml_file = os.path.join(form_xml_dir, "Form.xml")
        write_xml_file(form_xml_file, form_xml_text)
        if pending_dyn_list:
            dl_mt = re.search(r'<MainTable>([^<]*)</MainTable>', main_attr_info['Xml'])
            dl_qt = re.search(r'(?s)<QueryText>(.*?)</QueryText>', main_attr_info['Xml'])
            dyn_list_forms.append({
                'File': form_xml_file, 'MainName': main_attr_info['Name'],
                'Manual': '<ManualQuery>true</ManualQuery>' in main_attr_info['Xml'],
                'MainTable': dl_mt.group(1).strip() if dl_mt else '',
                'Query': html.unescape(dl_qt.group(1)) if dl_qt else ''})
        info(f"  Created: {form_xml_file}")
        if DROPPED_LINKS:
            uniq = sorted(set(DROPPED_LINKS))
            warn(f"  Вырезано связей формы: {len(uniq)} — путь не разрешается в расширении: {', '.join(uniq)}")
            DROPPED_LINKS.clear()

        # 6. Create empty Module.bsl — but NEVER overwrite an existing one (re-borrow must
        # not clobber user code added to the form module).
        module_dir = os.path.join(form_xml_dir, "Form")
        os.makedirs(module_dir, exist_ok=True)
        module_bsl_file = os.path.join(module_dir, "Module.bsl")
        if os.path.isfile(module_bsl_file):
            info("  Preserved existing Module.bsl")
        else:
            write_utf8_bom(module_bsl_file, "")
            info(f"  Created: {module_bsl_file}")

        # 6b. Встроенные картинки элементов. Form.xml ссылается на них как <xr:Abs>Файл</xr:Abs>, а сам файл
        # лежит в Ext/Form/Items/<Элемент>/<Файл>; без него платформа отвергает расширение («Файл не найден»).
        # Конфигуратор копирует их байт в байт. Берём ровно то, на что ссылается скелет (картинки декораций
        # выброшены выше). Уже лежащий файл не перезаписываем: его могли заменить в расширении.
        pic_files = []
        src_items_dir = os.path.join(os.path.dirname(src_form_xml_path), "Form", "Items")
        pic_rels = []
        for sect in (src_auto_cmd, src_child_items):
            if sect is None:
                continue
            for abs_node in sect.iter("{http://v8.1c.ru/8.3/xcf/readable}Abs"):
                pic_owner = abs_node.getparent().getparent()
                pic_el_name = pic_owner.get("name") if pic_owner is not None else None
                pic_file_name = (abs_node.text or "").strip()
                if not pic_el_name or not pic_file_name:
                    continue
                # Платформа пишет сюда голое имя файла. Иное (путь, «..») — не наша выгрузка: мимо Items не ходим.
                if ("\\" in pic_el_name or "\\" in pic_file_name or "/" in pic_el_name or "/" in pic_file_name
                        or pic_el_name in (".", "..") or pic_file_name in (".", "..")):
                    warn(f"  Картинка элемента пропущена — не имя файла: {pic_el_name} / {pic_file_name}")
                    continue
                rel = f"{pic_el_name}/{pic_file_name}"
                if rel not in pic_rels:
                    pic_rels.append(rel)
        for rel in sorted(pic_rels):
            pic_el_name, pic_file_name = rel.split("/", 1)
            src_pic = os.path.join(src_items_dir, pic_el_name, pic_file_name)
            dst_pic_dir = os.path.join(module_dir, "Items", pic_el_name)
            dst_pic = os.path.join(dst_pic_dir, pic_file_name)
            if os.path.exists(dst_pic):
                info(f"  Preserved existing: {dst_pic}")
                continue
            if not os.path.isfile(src_pic):
                warn(f"  Картинка элемента не найдена в источнике: {src_pic}")
                continue
            os.makedirs(dst_pic_dir, exist_ok=True)
            shutil.copyfile(src_pic, dst_pic)
            pic_files.append(dst_pic)
            info(f"  Copied: {dst_pic}")

        # 7. Register form in parent object ChildObjects
        # общая форма — в Configuration.xml, форма объекта — в ChildObjects владельца
        if is_common_form:
            if not common_form_registered:
                add_to_child_objects(type_name, obj_name)
        else:
            register_form_in_object(type_name, obj_name, form_name)

        return [form_meta_file, form_xml_file, module_bsl_file] + pic_files

    # --- 9. Parse -Object into items ---
    items = []
    for part in args.Object.split(";;"):
        trimmed = part.strip()
        if trimmed:
            items.append(trimmed)

    if not items:
        print("No objects specified in -Object", file=sys.stderr)
        sys.exit(1)

    # --- 9b. Validate -BorrowMainAttribute ---
    borrow_main_attribute_mode = args.BorrowMainAttribute
    if borrow_main_attribute_mode is not None:
        if borrow_main_attribute_mode not in ("Form", "All"):
            print("-BorrowMainAttribute accepts 'Form' or 'All' (default: Form)", file=sys.stderr)
            sys.exit(1)
        # Validate: only with a form — .Form. pattern or a common form
        has_form = any(".Form." in item or re.match(r'^(CommonForm|ОбщаяФорма)\.', item) for item in items)
        if not has_form:
            print("-BorrowMainAttribute requires a form in -Object (e.g. 'Catalog.X.Form.Y')", file=sys.stderr)
            sys.exit(1)

    # --- 9c. Validate -Module ---
    requested_modules = []
    no_module = False
    if args.Module:
        for raw in re.split(r"[,;]", args.Module):
            kind = raw.strip()
            if not kind:
                continue
            # Сравнение РЕГИСТРОНЕЗАВИСИМОЕ явно: в ps1-порте `-ieq`, и молчаливое расхождение
            # портов на «none» ловится только глазами.
            if kind.lower() == "none":
                no_module = True
                continue
            canon = [k for k in MODULE_KIND_NAMES if k.lower() == kind.lower()]
            if not canon:
                print(f"Неизвестный вид модуля '{kind}'. Допустимо: {', '.join(MODULE_KIND_NAMES)}, None", file=sys.stderr)
                sys.exit(1)
            requested_modules.append(canon[0])
        if no_module and requested_modules:
            print("-Module None нельзя сочетать с видами модулей", file=sys.stderr)
            sys.exit(1)

    # Какие модули создать для объекта. Тип с единственным модулем получает его всегда — уточнять
    # там нечего; -Module разбирает только неоднозначные типы. Иначе батч смешанных типов
    # (`CommonModule.X ;; Catalog.Y`) не выражался бы одним вызовом.
    def resolve_module_kinds(type_name):
        if no_module:
            return []
        allowed = MODULE_KINDS_BY_TYPE.get(type_name, [])
        if not allowed:
            return []
        if type_name in AUTO_MODULE_TYPES:
            return [allowed[0]]
        if not requested_modules:
            return []
        # Порядок берём из таблицы типа, а не из порядка ключей в -Module.
        selected = [k for k in allowed if k in requested_modules]
        if not selected:
            warn(f"  Тип {type_name} не имеет запрошенных модулей — пропущено. Допустимо: {', '.join(allowed)}")
        return selected

    # --- 10. Process each item ---
    borrowed_count = 0

    def split_borrow_item(item):
        """Элемент -Object: тип (синоним → английское имя), объект, форма и путь к её Form.xml в источнике.
        Error — текст отказа для неверного элемента."""
        fmt_hint = ("expected 'Type.Name', 'Type.Name.Form.FormName', 'Type.Name.<Kind>.<SubName>' or "
                    "'Type.Name.TabularSection.<TS>.Attribute.<Attribute>'")
        dot_idx = item.find(".")
        if dot_idx < 1:
            return {"Error": f"Invalid format '{item}', {fmt_hint}"}
        type_name = item[:dot_idx]
        remainder = item[dot_idx + 1:]
        type_name = SYNONYM_MAP.get(type_name, type_name)
        if type_name not in CHILD_TYPE_DIR_MAP:
            return {"Error": f"Unknown type '{type_name}'"}
        # Имена метаданных без точек — разбор по сегментам: Имя | Имя.Form.Ф | Имя.<Вид>.<П> | Имя.TabularSection.<ТЧ>.Attribute.<К>
        segs = remainder.split(".")
        if "" in segs:
            return {"Error": f"Invalid format '{item}', {fmt_hint}"}
        obj_name = segs[0]
        form_name = sub_kind = sub_name = col_name = None
        if len(segs) == 1:
            pass
        elif len(segs) == 3 and segs[1] == "Form":
            form_name = segs[2]
        elif len(segs) == 3 and segs[1] in SUB_OBJECT_KINDS:
            sub_kind, sub_name = segs[1], segs[2]
        elif len(segs) == 5 and segs[1] == "TabularSection" and segs[3] == "Attribute":
            sub_kind, sub_name, col_name = "TabularSection", segs[2], segs[4]
        elif len(segs) == 3:
            return {"Error": f"Unsupported child object kind '{segs[1]}' in '{item}': expected Form, {', '.join(SUB_OBJECT_KINDS)}"}
        else:
            return {"Error": f"Invalid format '{item}', {fmt_hint}"}
        # Вид подобъекта — из канона ChildObjects своего типа: измерения у документа нет
        if sub_kind:
            order = object_child_order().get(type_name)
            if not order or sub_kind not in order:
                return {"Error": f"{type_name} has no child objects of kind {sub_kind} ('{item}')"}
        # Общая форма — сама форма: «CommonForm.X» заимствуется вместе с содержимым, владельца у неё нет
        is_common_form = type_name == "CommonForm"
        if is_common_form:
            if len(segs) != 1:
                return {"Error": f"Invalid format '{item}': общая форма задаётся как 'CommonForm.Имя'"}
            form_name = obj_name
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        src_form_xml = None
        if is_common_form:
            src_form_xml = os.path.join(cfg_dir, dir_name, obj_name, "Ext", "Form.xml")
        elif form_name:
            src_form_xml = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml")
        return {"TypeName": type_name, "ObjName": obj_name, "FormName": form_name, "IsCommonForm": is_common_form,
                "DirName": dir_name, "SrcFormXml": src_form_xml,
                "SubKind": sub_kind, "SubName": sub_name, "ColName": col_name}

    def resolve_sub_object_source(pi):
        """Подобъект в источнике: реквизит/измерение/… своего вида, ТЧ и колонка. Имя сверяется ключом
        запроса, как у resolve_source_attributes; в расширение идёт имя из источника. Нет — Error."""
        res = resolve_source_attributes(pi["TypeName"], pi["ObjName"], {pi["SubName"]: True})
        key = query_key(pi["SubName"])
        where = f"{pi['TypeName']}.{pi['ObjName']}"
        if pi["SubKind"] == "TabularSection":
            ts = next((t for t in res["TabularSections"] if query_key(t["Name"]) == key), None)
            if not ts:
                return {"Error": f"TabularSection '{pi['SubName']}' not found in {where}"}
            col = None
            if pi["ColName"]:
                col_key = query_key(pi["ColName"])
                col = next((c for c in ts["Attributes"] if query_key(c["Name"]) == col_key), None)
                if not col:
                    return {"Error": f"Attribute '{pi['ColName']}' not found in tabular section {where}.{ts['Name']}"}
            return {"TS": ts, "Col": col}
        attr = next((a for a in res["Attributes"] if a.get("Kind") == pi["SubKind"] and query_key(a["Name"]) == key), None)
        if not attr:
            return {"Error": f"{pi['SubKind']} '{pi['SubName']}' not found in {where}"}
        return {"Attr": attr}

    def ensure_parent_borrowed(type_name, obj_name):
        """Объект-родитель формы или подобъекта: не заимствован — заимствовать заготовкой."""
        if test_object_borrowed(type_name, obj_name):
            return
        info(f"  Parent object {type_name}.{obj_name} not yet borrowed — borrowing first...")
        src = read_source_object(type_name, obj_name)
        info(f"  Source UUID: {src['Uuid']}")
        borrowed_xml = build_borrowed_object_xml(type_name, obj_name, src["Uuid"], src["Properties"])
        target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[type_name])
        os.makedirs(target_dir, exist_ok=True)
        target_file = os.path.join(target_dir, f"{obj_name}.xml")
        write_xml_file(target_file, borrowed_xml)
        info(f"  Created: {target_file}")
        add_to_child_objects(type_name, obj_name)
        borrowed_files.append(target_file)

    def borrow_sub_object(pi, src):
        """Подобъект без формы — как «Добавить в расширение» Конфигуратора: ТЧ пустая (свои колонки — потом,
        meta-edit), реквизит/измерение/колонка — по одному, ссылочные типы — оболочками. Свойства объекта
        (Hierarchical, CodeLength…) не переносятся — Конфигуратор их тут тоже не пишет."""
        type_name, obj_name = pi["TypeName"], pi["ObjName"]
        ensure_parent_borrowed(type_name, obj_name)
        obj_file = os.path.join(ext_dir, pi["DirName"], f"{obj_name}.xml")
        if pi["SubKind"] != "TabularSection":
            attr = src["Attr"]
            if attr["Name"] in get_own_child_object_names(obj_file):
                info(f"  Already borrowed: {pi['SubKind']} {attr['Name']}")
            else:
                merge_attributes_into_object(type_name, obj_name, [attr])
            borrow_reference_type_shells([attr["TypeXml"]])
            return
        ts = src["TS"]
        style = _detect_xml_style(obj_file)
        with open(obj_file, "r", encoding="utf-8-sig", newline="") as fh:
            text = fh.read()
        if find_own_tabular_section_span(text, ts["Name"]):
            info(f"  Already borrowed: TabularSection {ts['Name']}")
        else:
            text = insert_own_child_or_die(
                text, build_adopted_tabular_section_xml(ts["Name"], ts["Uuid"], ts["GeneratedTypes"], [], "\t\t\t"),
                "TabularSection", type_name, obj_file)
            write_text_keep_bom(obj_file, text, style)
            info(f"  Borrowed TabularSection {ts['Name']} (no attributes): {obj_file}")
        # Собственный реквизит в заимствованную ТЧ этих видов платформа не примет — отказ на обновлении БД.
        # Предупреждаем, когда ТЧ заимствуется под собственные реквизиты — элемент без реквизита источника
        if not src["Col"]:
            if type_name in TS_OWN_COLUMNS_BLOCKED:
                warn(f"  {type_name}: own attributes cannot be added to a borrowed tabular section of this kind \u2014 "
                     f"the platform rejects them on database update")
            elif type_name in TS_OWN_COLUMNS_FROM_PLATFORM:
                warn(f"  {type_name}: own attributes in a borrowed tabular section are accepted only from platform "
                     f"{TS_OWN_COLUMNS_FROM_PLATFORM[type_name]}")
        if src["Col"]:
            merge_columns_into_tabular_section(type_name, obj_name, ts["Name"], [src["Col"]])
            borrow_reference_type_shells([src["Col"]["TypeXml"]])

    # С -BorrowMainAttribute реквизиты берутся у объекта из типа основного реквизита формы. Если это не
    # владелец формы и его нет в конфигурации-источнике, форма в расширении не загрузится — отказываем
    # до записи, расширение не трогаем.
    if borrow_main_attribute_mode is not None:
        for item in items:
            pi = split_borrow_item(item)
            # Неверный элемент и нет самой формы — об этом скажет основной цикл
            if pi.get("Error") or not pi["SrcFormXml"] or not os.path.isfile(pi["SrcFormXml"]):
                continue
            p_root = etree.parse(pi["SrcFormXml"]).getroot()
            if pi["IsCommonForm"]:
                p_owner = resolve_common_form_owner(p_root)
                if not p_owner or p_owner["Kind"] != "Object":
                    continue
            else:
                p_owner = resolve_main_attribute_object(p_root, pi["TypeName"], pi["ObjName"])
                if p_owner["TypeName"].lower() == pi["TypeName"].lower() and p_owner["ObjName"].lower() == pi["ObjName"].lower():
                    continue
            p_found = (p_owner["TypeName"] in CHILD_TYPE_DIR_MAP and
                       os.path.isfile(os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[p_owner["TypeName"]], f"{p_owner['ObjName']}.xml")))
            if not p_found:
                print(f"Основной реквизит формы {item} ссылается на {p_owner['TypeName']}.{p_owner['ObjName']}, а его нет в "
                      f"конфигурации-источнике — форма в расширении не загрузится. Расширение не изменено", file=sys.stderr)
                sys.exit(1)

    # Элементы разобраны и подобъекты найдены в источнике ДО записи: ошибка в любом элементе пакета —
    # расширение не тронуто
    sub_object_sources = {}
    for item in items:
        pi = split_borrow_item(item)
        if pi.get("Error"):
            print(pi["Error"], file=sys.stderr)
            sys.exit(1)
        if not pi["SubKind"]:
            continue
        sub_src = resolve_sub_object_source(pi)
        if sub_src.get("Error"):
            print(f"{sub_src['Error']}. Extension not changed", file=sys.stderr)
            sys.exit(1)
        sub_object_sources[item] = sub_src

    for item in items:
        pi = split_borrow_item(item)
        if pi.get("Error"):
            print(pi["Error"], file=sys.stderr)
            sys.exit(1)
        type_name, obj_name, form_name, is_common_form = pi["TypeName"], pi["ObjName"], pi["FormName"], pi["IsCommonForm"]

        dir_name = CHILD_TYPE_DIR_MAP[type_name]

        if pi["SubKind"]:
            info(f"Borrowing {item}...")
            borrow_sub_object(pi, sub_object_sources[item])
            borrowed_count += 1
        elif form_name:
            # --- Form borrowing ---
            if is_common_form:
                info(f"Borrowing common form {type_name}.{obj_name}...")
            else:
                info(f"Borrowing form {type_name}.{obj_name}.Form.{form_name}...")

            if not is_common_form:
                ensure_parent_borrowed(type_name, obj_name)

            has_bma = borrow_main_attribute_mode is not None
            form_files = borrow_form(type_name, obj_name, form_name, borrow_main_attr=has_bma)
            borrowed_files.extend(form_files)
            # Замер на 8.3.26: платформа помечает форму расширенной сразу при заимствовании,
            # даже если элементы не менялись. Флаг живёт в метаданных формы, не у владельца.
            set_property_state_flag(form_files[0], "Form", format_version)
            borrowed_count += 1

            # Borrow main attribute if requested
            if has_bma and is_common_form:
                # У общей формы владельца нет — он выводится из типа основного реквизита
                cf_src_form_xml_path = pi["SrcFormXml"]
                cf_owner = resolve_common_form_owner(etree.parse(cf_src_form_xml_path).getroot())
                if not cf_owner:
                    info("  Основной реквизит общей формы не ссылается на объект — заимствуется только сам реквизит")
                elif cf_owner["Kind"] == "Constants":
                    borrow_form_constants(cf_src_form_xml_path, cf_owner["MainName"])
                else:
                    borrow_object_shell(cf_owner["TypeName"], cf_owner["ObjName"])
                    if test_object_borrowed(cf_owner["TypeName"], cf_owner["ObjName"]):
                        borrow_main_attribute(cf_owner["TypeName"], cf_owner["ObjName"], None, borrow_main_attribute_mode, cf_src_form_xml_path)
            elif has_bma:
                # Реквизиты заимствуются у объекта из типа основного реквизита: у формы обработки с
                # DocumentObject.X это X, и его нужно заимствовать — иначе форма не загрузится
                src_form_xml_path = pi["SrcFormXml"]
                ma_obj = {"TypeName": type_name, "ObjName": obj_name}
                if os.path.isfile(src_form_xml_path):
                    ma_obj = resolve_main_attribute_object(etree.parse(src_form_xml_path).getroot(), type_name, obj_name)
                if ma_obj["TypeName"].lower() == type_name.lower() and ma_obj["ObjName"].lower() == obj_name.lower():
                    borrow_main_attribute(type_name, obj_name, form_name, borrow_main_attribute_mode)
                else:
                    info(f"  Основной реквизит формы — {ma_obj['TypeName']}.{ma_obj['ObjName']}: реквизиты заимствуются у него")
                    borrow_object_shell(ma_obj["TypeName"], ma_obj["ObjName"])
                    if test_object_borrowed(ma_obj["TypeName"], ma_obj["ObjName"]):
                        borrow_main_attribute(ma_obj["TypeName"], ma_obj["ObjName"], None, borrow_main_attribute_mode, src_form_xml_path)
        else:
            # --- Object borrowing ---
            target_dir = os.path.join(ext_dir, dir_name)
            target_file = os.path.join(target_dir, f"{obj_name}.xml")

            # Уже заимствованный объект НЕ переписываем: в его XML лежат собственные реквизиты
            # расширения, заимствованные подобъекты и состояния, которые из источника не
            # выводятся. Повторный вызов — законный способ доделать модуль (-Module), а не
            # переиздать заготовку.
            src = None
            if test_object_borrowed(type_name, obj_name):
                info(f"Already borrowed: {type_name}.{obj_name} — XML сохранён без изменений")
            else:
                info(f"Borrowing {type_name}.{obj_name}...")

                src = read_source_object(type_name, obj_name)
                info(f"  Source UUID: {src['Uuid']}")

                borrowed_xml = build_borrowed_object_xml(type_name, obj_name, src["Uuid"], src["Properties"])

                os.makedirs(target_dir, exist_ok=True)
                write_xml_file(target_file, borrowed_xml)
                info(f"  Created: {target_file}")

            add_to_child_objects(type_name, obj_name)
            # Определяемый тип — с оболочками объектов своего состава, как у Конфигуратора
            if src and type_name == "DefinedType" and "__TypeXml" in src["Properties"]:
                for rt in collect_reference_types([src["Properties"]["__TypeXml"]]):
                    borrow_object_shell(rt["TypeName"], rt["ObjName"])

            borrowed_files.append(target_file)
            for kind in resolve_module_kinds(type_name):
                borrowed_files.append(new_borrowed_module_file(type_name, obj_name, kind))
            borrowed_count += 1

    # --- 14a. Основные таблицы динамических списков заимствованных форм — оболочками ---
    # Объект основной таблицы списка обязан быть в расширении («Неверно указана главная таблица
    # динамического списка»), даже если форма принадлежит другому объекту. Для виртуальной таблицы или
    # ТЧ (InformationRegister.Цены.SliceLast) — объект по первым двум сегментам. До шага 14b: оболочке
    # справочника нужны и его владельцы.
    for dl in dyn_list_forms:
        mt = re.match(r'^(\w+)\.(\w+)(?:\.\w+)*$', dl['MainTable'])
        if mt and mt.group(1) in CHILD_TYPE_DIR_MAP:
            mt_kind, mt_name = mt.group(1), mt.group(2)
            if not test_object_borrowed(mt_kind, mt_name):
                info(f"Основная таблица динамического списка {mt_kind}.{mt_name} — в расширение оболочкой")
                borrow_object_shell(mt_kind, mt_name)

    # --- Владельцы заимствованных справочников ---
    # Ссылка в <Owners> должна вести на объект, который в расширении есть: иначе платформа падает
    # при загрузке (проверено — access violation, не сообщение об ошибке). Конфигуратор владельца
    # заимствует (эталон Issue66Example7_1: вместе со справочником перенесён и его ПВХ-владелец).
    # Проход общий и повторяется, пока находятся новые: у владельца может быть свой владелец.
    for _owner_pass in range(10):
        new_owners = []
        for root_dir, _dirs, files in os.walk(ext_dir):
            for fn in files:
                if not fn.endswith(".xml"):
                    continue
                with open(os.path.join(root_dir, fn), "r", encoding="utf-8-sig") as fh:
                    shell_text = fh.read()
                if "<Owners>" not in shell_text:
                    continue
                for om in re.finditer(r'<xr:Item[^>]*>(\w+)\.(\w+)</xr:Item>', shell_text):
                    o_type, o_name = om.group(1), om.group(2)
                    if o_type not in CHILD_TYPE_DIR_MAP:
                        continue
                    if test_object_borrowed(o_type, o_name):
                        continue
                    if (o_type, o_name) in new_owners:
                        continue
                    new_owners.append((o_type, o_name))
        if not new_owners:
            break
        for o_type, o_name in new_owners:
            ow_src_file = os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[o_type], f"{o_name}.xml")
            if not os.path.isfile(ow_src_file):
                warn(f"  Владелец {o_type}.{o_name} не найден в источнике — ссылка останется висячей")
                continue
            ow_src = read_source_object(o_type, o_name)
            ow_xml = build_borrowed_object_xml(o_type, o_name, ow_src["Uuid"], ow_src["Properties"])
            ow_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[o_type])
            os.makedirs(ow_dir, exist_ok=True)
            ow_file = os.path.join(ow_dir, f"{o_name}.xml")
            write_utf8_bom(ow_file, ow_xml)
            add_to_child_objects(o_type, o_name)
            borrowed_files.append(ow_file)
            info(f"  Auto-borrowed owner: {o_type}.{o_name}")

    # --- 14c. Тильда у путей полей динамических списков заимствованных форм ---
    # Запрос списка компилируется в контексте расширения, и что-то из него, чего там нет, делает
    # невалидными все поля списка («Неверный путь к данным»). Конфигуратор такие пути пишет с тильдой —
    # платформа разрешает их после наложения на основную конфигурацию. Тильду ставим, только если
    # список не разрешится в расширении (get_dyn_list_query_unresolved): лишняя тильда безвредна, но первая
    # выгрузка из базы её снимет — шум в истории файлов. У списка без ручного запроса поля — пути формы
    # по основной таблице: проверяем их как запрос «ВЫБРАТЬ Т.Поле… ИЗ <таблица> КАК Т». Решаем здесь,
    # по итоговому составу расширения (после 14a и 14b): реквизиты заимствуются уже после формы, в пакете —
    # и соседними формами. Помечаются привязки, которые платформа проверяет при загрузке: *DataPath
    # элементов (DataPath, FooterDataPath, RowPictureDataPath…) и <Field> в UseAlways; в форме и в
    # BaseForm. Сам список (DataPath без поля) — как есть; пути отбора и оформления (dcsset:/dcscor:)
    # не проверяются.
    for dl in dyn_list_forms:
        with open(dl['File'], 'r', encoding='utf-8-sig', newline='') as fh:
            dl_text = fh.read()
        if dl['Manual']:
            dl_query = dl['Query']
        else:
            if not dl['MainTable']:
                continue
            dl_path_pat = r'<(?:\w*DataPath|Field)>~?' + re.escape(dl['MainName']) + r'\.([^<]+)<'
            dl_fields = list(dict.fromkeys("Т." + m.group(1) for m in re.finditer(dl_path_pat, dl_text)))
            if not dl_fields:
                continue
            dl_query = "ВЫБРАТЬ " + ", ".join(dl_fields) + f" ИЗ {dl['MainTable']} КАК Т"
        dl_unresolved = get_dyn_list_query_unresolved(dl_query)
        if not dl_unresolved:
            continue
        dl_field_pat = r'(<(?:\w*DataPath|Field)>)(?=' + re.escape(dl['MainName']) + r'\.)'
        dl_text, dl_count = re.subn(dl_field_pat, r'\1~', dl_text)
        if dl_count > 0:
            write_utf8_bom(dl['File'], dl_text)
            dl_shown = ", ".join(dl_unresolved[:5])
            if len(dl_unresolved) > 5:
                dl_shown += ", …"
            dl_rel = os.path.relpath(dl['File'], ext_dir).replace('\\', '/')
            info(f"Поля динамического списка ({dl_rel}): пути с тильдой ({dl_count}) — список использует то, чего нет в расширении ({dl_shown}); разрешатся после наложения")

    # --- Save modified Configuration.xml ---
    save_xml_bom(tree, ext_resolved)
    info(f"Saved: {ext_resolved}")

    # --- Summary ---
    print()
    print("=== cfe-borrow summary ===")
    print(f"  Extension:  {ext_dir}")
    print(f"  Config:     {cfg_dir}")
    print(f"  Borrowed:   {borrowed_count} object(s)")
    for f in borrowed_files:
        print(f"    - {f}")
    sys.exit(0)


if __name__ == "__main__":
    main()
