#!/usr/bin/env python3
# cfe-borrow v1.36 — Borrow objects from configuration into extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
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
CHILD_OBJECT_KINDS = ("Attribute", "Dimension", "Resource", "AddressingAttribute")

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


DROPPED_LINKS = []


def rewrite_choice_parameter_links(xml, attr_uuids, form_attr_ids, main_attr_name, main_attr_borrowed):
    """Ссылки параметров выбора (<ChoiceParameterLinks>/<xr:Link>) — привязка особого рода: путь лежит
    в <xr:DataPath> и обычным стриппингом не снимается. Текстовое имя в расширении разрешается только
    если его корень объявлен в <Attributes> самой заимствованной формы; иначе платформа отвергает
    загрузку — «Неверный путь к полю - X». Реквизиты формы не заимствуются никогда, поэтому ссылка на
    них разрешима только через id: Конфигуратор подставляет id реквизита ИСХОДНОЙ формы (эталоны
    Issue66Example4/5/6, JR2433, JR2976, JR49904 — совпадение на шести расширениях). Именно id
    исходной, а не заимствованной: при заимствовании реквизиты перенумеровываются в 1000000+, а
    ссылка продолжает указывать в нумерацию базовой формы.
    Путь на основной реквизит («Объект.X») при заимствованном основном реквизите разрешается текстом
    и остаётся читаемым; без заимствования переводится в «<id>/0:<uuid реквизита объекта>».
    Реквизит, которого в источнике нет, недоступен и по uuid: такую связь вырезаем целиком."""
    if '<ChoiceParameterLinks>' not in xml:
        return xml

    main_pat = re.escape(main_attr_name) if main_attr_name else None
    main_id = form_attr_ids.get(main_attr_name, "1") if main_attr_name else "1"

    def repl(m):
        link = m.group(0)
        dp = re.search(r'<xr:DataPath[^>]*>([^<]+)</xr:DataPath>', link)
        if not dp:
            return link
        path = dp.group(1)

        # Путь на основной реквизит формы
        if main_pat:
            mm = re.match('^' + main_pat + r'\.(.+)$', path)
            if mm:
                attr_name = mm.group(1)
                if main_attr_borrowed:
                    # Реквизит объекта разрешается текстом и остаётся читаемым. Стандартное поле
                    # («Объект.Owner», «Объект.Date») — нет: платформа отвергает «Неверный путь к данным».
                    # Конфигуратор в этом случае оставляет ссылку на сам реквизит (эталон Issue66Example7_1).
                    if attr_name in attr_uuids:
                        return link
                    return re.sub(r'(<xr:DataPath[^>]*>)[^<]+(</xr:DataPath>)',
                                  lambda x: f"{x.group(1)}{main_id}{x.group(2)}", link)
                if attr_name in attr_uuids:
                    return re.sub(r'(<xr:DataPath[^>]*>)[^<]+(</xr:DataPath>)',
                                  lambda x: f"{x.group(1)}{main_id}/0:{attr_uuids[attr_name]}{x.group(2)}", link)
                return ''

        # Односегментный путь на реквизит формы — только по id исходной формы
        if '.' not in path and path in form_attr_ids:
            return re.sub(r'(<xr:DataPath[^>]*>)[^<]+(</xr:DataPath>)',
                          lambda x: f"{x.group(1)}{form_attr_ids[path]}{x.group(2)}", link)

        # Уже непрозрачный путь (форма-источник сама из расширения) — не трогаем
        if re.match(r'^\d', path):
            return link

        # С заимствованным основным реквизитом текстовый путь разрешается: элементы формы на месте,
        # а их данные доступны через основной реквизит. Конфигуратор такие пути и оставляет текстом
        # (эталон Issue66Example7_1: «Items.Товары.CurrentData.Характеристика» перенесён как есть).
        if main_attr_borrowed:
            return link

        # Прочее текстом не разрешается: платформа отвергает загрузку «Неверный путь к полю».
        # Сюда попадают «Items.<Элемент>.CurrentData.<Поле>» — их кодировка непрозрачна и по
        # имеющимся эталонам не воспроизводима. Связь параметров выбора — удобство подбора, а не
        # данные: без неё форма заимствуется и работает, с ней — не грузится вовсе.
        DROPPED_LINKS.append(path)
        return ''

    xml = re.sub(r'\s*<xr:Link>.*?</xr:Link>', repl, xml, flags=re.DOTALL)
    # Опустевший контейнер платформе не нужен
    xml = re.sub(r'\s*<ChoiceParameterLinks>\s*</ChoiceParameterLinks>', '', xml, flags=re.DOTALL)
    return xml


def get_own_child_object_names(obj_file):
    """Имена ПРЯМЫХ детей собственного <ChildObjects> объекта — для дедупа при повторном
    заимствовании. Текстом это не снять: regex «первый <ChildObjects> до первого </ChildObjects>»
    у объекта с табличными частями обрывается на закрытии первой ТЧ, забирает имена её колонок и
    теряет то, что идёт после неё."""
    names = set()
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


def insert_into_own_child_objects(text, content):
    """Вставка в СОБСТВЕННЫЙ <ChildObjects> объекта. Свой контейнер закрывается в файле последним:
    объект в файле один, а вложенные <ChildObjects> табличных частей закрываются раньше. Замена по
    всем вхождениям раскидывала реквизиты по каждой ТЧ — ps1 рвал XML, py прятал ТЧ внутрь ТЧ."""
    close_idx = text.rfind("</ChildObjects>")
    if close_idx >= 0:
        return text[:close_idx] + content + "\r\n\t\t" + text[close_idx:]
    # Своего закрывающего тега нет — значит контейнер самозакрытый (детей у него нет, вложенных тоже)
    self_matches = list(re.finditer(r'<ChildObjects\s*/>', text))
    if not self_matches:
        return text
    m = self_matches[-1]
    return text[:m.start()] + f"<ChildObjects>{content}\r\n\t\t</ChildObjects>" + text[m.end():]


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
    "Sequence": "Sequences", "IntegrationService": "IntegrationServices",
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
    "BusinessProcess", "Task", "IntegrationService",
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
TYPE_GATE_PROPS = {
    "InformationRegister": ["InformationRegisterPeriodicity", "WriteMode"],
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

    # --- Helper functions ---
    def get_source_attribute_uuids(type_name, obj_name):
        """Имена реквизитов исходного объекта → uuid. Нужны для непрозрачной формы пути в ссылках
        параметров выбора (см. rewrite_choice_parameter_links)."""
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
                if not isinstance(sub.tag, str) or localname(sub) not in ("Attribute", "TabularSection"):
                    continue
                uuid_val = sub.get("uuid")
                name_val = None
                for props in sub:
                    if isinstance(props.tag, str) and localname(props) == "Properties":
                        for prop in props:
                            if isinstance(prop.tag, str) and localname(prop) == "Name":
                                name_val = (prop.text or "").strip()
                                break
                        break
                if uuid_val and name_val:
                    result[name_val] = uuid_val
            break
        return result

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

        first_level = {}
        deep_paths = []

        # Scan every data-binding tag (DataPath/TitleDataPath/FooterDataPath/HeaderDataPath/MultipleValue*)
        # for Объект.* references — picture-path tags carry picture indices, not data attributes.
        for tag in FORM_BINDING_DATA_TAGS:
            for m in re.finditer(r'<' + tag + r'>[^<]*\b' + root + r'\.(\w+(?:\.\w+)*)</' + tag + r'>', content):
                path = m.group(1)
                segments = path.split(".")
                seg0 = segments[0]
                if seg0 in STANDARD_FIELDS:
                    continue
                first_level[seg0] = True
                if len(segments) >= 2:
                    seg1 = segments[1]
                    if seg1 in STANDARD_FIELDS:
                        continue
                    seg2 = segments[2] if len(segments) >= 3 else None
                    deep_paths.append({"ObjectAttr": seg0, "SubAttr": seg1, "SubSubAttr": seg2})

        # Also scan <Field>Объект.X</Field> — object attributes referenced by filter/conditional-appearance
        # fields (and dynamic lists), not via a *DataPath binding (e.g. УдалитьЮрФизЛицо). Designer borrows these too.
        for m in re.finditer(r'<Field>[^<]*\b' + root + r'\.(\w+(?:\.\w+)*)</Field>', content):
            path = m.group(1)
            segments = path.split(".")
            seg0 = segments[0]
            if seg0 in STANDARD_FIELDS:
                continue
            first_level[seg0] = True
            if len(segments) >= 2:
                seg1 = segments[1]
                if seg1 in STANDARD_FIELDS:
                    continue
                seg2 = segments[2] if len(segments) >= 3 else None
                deep_paths.append({"ObjectAttr": seg0, "SubAttr": seg1, "SubSubAttr": seg2})

        # Also scan <AdditionalColumns table="Объект.X"> — доп. колонки табличной части, объявленные в
        # самой форме (напр. Объект.Товары.Артикул). Такая ТЧ может больше нигде на форме не встречаться,
        # и без её заимствования платформа отвергает форму: «Неверный путь к данным».
        for m in re.finditer(r'<AdditionalColumns table="' + root + r'\.(\w+)"', content):
            seg0 = m.group(1)
            if seg0 in STANDARD_FIELDS:
                continue
            first_level[seg0] = True

        # Текст запроса динамического списка — такое же место ссылки на реквизиты объекта, как DataPath.
        # Конфигуратор заимствует всё, что упомянуто в запросе: на эталоне Issue66Example2 это 21 из 27
        # дочерних объектов, совпадение с ним точное в обе стороны. У списка без ручного запроса
        # (<QueryText> нет) заимствуется только видимое на форме — эталон Issue66Example3.
        # Разбирать язык запросов не нужно: имена-кандидаты отфильтрует resolve_source_attributes по
        # реальному составу объекта, поэтому лишние слова из запроса безвредны.
        for qm in re.finditer(r'(?s)<QueryText>(.*?)</QueryText>', content):
            for w in re.finditer(r'\w+', qm.group(1)):
                if w.group(0) in STANDARD_FIELDS:
                    continue
                first_level[w.group(0)] = True

        # Deduplicate deep paths
        seen = set()
        unique_deep = []
        for dp in deep_paths:
            key = f"{dp['ObjectAttr']}.{dp['SubAttr']}.{dp.get('SubSubAttr')}"
            if key not in seen:
                seen.add(key)
                unique_deep.append(dp)

        return {"FirstLevel": first_level, "DeepPaths": unique_deep}

    # --- 11c. Resolve source attributes and tabular sections ---
    def resolve_source_attributes(type_name, obj_name, first_level_names):
        # first_level_names: dict of names, or None for "all"
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
                if first_level_names is not None and attr_name not in first_level_names:
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
                if first_level_names is not None and ts_name not in first_level_names:
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
        with open(obj_file, "r", encoding="utf-8-sig", newline="") as fh:
            obj_content = fh.read()

        # Collect existing names for dedup — только прямые дети своего ChildObjects
        existing_names = get_own_child_object_names(obj_file)

        all_attr_xml = ""
        added = 0
        for attr in attrs_to_add:
            if attr["Name"] in existing_names:
                continue
            all_attr_xml += "\r\n" + build_adopted_attribute_xml(attr["Name"], attr["Uuid"], attr["TypeXml"], "\t\t\t", attr.get("Kind", "Attribute"))
            added += 1

        if added > 0:
            obj_content = insert_into_own_child_objects(obj_content, all_attr_xml)
            write_utf8_bom(obj_file, obj_content)
            info(f"  Merged {added} attribute(s) into: {obj_file}")

    # --- 11h. Borrow main attribute orchestrator ---
    def borrow_main_attribute(type_name, obj_name, form_name, mode):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]
        info(f"Borrowing main attribute for {type_name}.{obj_name} (mode: {mode})...")

        # Step 1: Collect DataPaths (Form mode) or take all (All mode)
        first_level_names = None
        deep_paths = []
        if mode == "Form":
            src_form_xml_path = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml")
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
        with open(obj_file, "r", encoding="utf-8-sig", newline="") as fh:
            obj_content = fh.read()

        # Dedup: skip attributes/TS already present in object's ChildObjects (idempotent re-borrow)
        existing_child_names = get_own_child_object_names(obj_file)
        insert_attrs = [a for a in src_attrs if a["Name"] not in existing_child_names]
        insert_ts = [t for t in src_ts if t["Name"] not in existing_child_names]

        # Generate full object XML with attributes and TS
        content_parts = []
        for attr in insert_attrs:
            content_parts.append(build_adopted_attribute_xml(attr["Name"], attr["Uuid"], attr["TypeXml"], "\t\t\t", attr.get("Kind", "Attribute")))
        for ts in insert_ts:
            content_parts.append(build_adopted_tabular_section_xml(ts["Name"], ts["Uuid"], ts["GeneratedTypes"], ts["Attributes"], "\t\t\t"))
        adopted_content = "\n".join(content_parts).rstrip()

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
        if adopted_content:
            obj_content = insert_into_own_child_objects(obj_content, f"\r\n{adopted_content}")

        write_utf8_bom(obj_file, obj_content)
        info(f"  Enriched object: {obj_file}")

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
        src_form_for_cols = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml")
        if os.path.isfile(src_form_for_cols):
            cols_tree = etree.parse(src_form_for_cols)
            cols_ns_strip = re.compile(r'\s+xmlns(?::\w+)?="[^"]*"')
            cols_info = get_main_attribute_info(cols_tree.getroot(), cols_ns_strip)
            if cols_info:
                all_type_xmls.extend(re.findall(r'(?s)<Columns>.*?</Columns>', cols_info["Xml"]))

        ref_types = collect_reference_types(all_type_xmls)
        info(f"  Reference types to borrow: {len(ref_types)}")

        for rt in ref_types:
            if rt["TypeName"] not in CHILD_TYPE_DIR_MAP:
                warn(f"  Unknown reference type: {rt['TypeName']}.{rt['ObjName']}")
                continue
            if test_object_borrowed(rt["TypeName"], rt["ObjName"]):
                info(f"  Already borrowed: {rt['TypeName']}.{rt['ObjName']}")
                continue
            rt_src_file = os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[rt["TypeName"]], f"{rt['ObjName']}.xml")
            if not os.path.isfile(rt_src_file):
                warn(f"  Source not found: {rt['TypeName']}.{rt['ObjName']}")
                continue
            src = read_source_object(rt["TypeName"], rt["ObjName"])
            borrowed_xml = build_borrowed_object_xml(rt["TypeName"], rt["ObjName"], src["Uuid"], src["Properties"])
            target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[rt["TypeName"]])
            os.makedirs(target_dir, exist_ok=True)
            target_file = os.path.join(target_dir, f"{rt['ObjName']}.xml")
            write_xml_file(target_file, borrowed_xml)
            add_to_child_objects(rt["TypeName"], rt["ObjName"])
            borrowed_files.append(target_file)
            info(f"  Auto-borrowed: {rt['TypeName']}.{rt['ObjName']}")

        # Step 5: Handle deep paths (Form mode only)
        if mode == "Form" and deep_paths:
            # Top-level ref deep paths: Объект.<Ref>.<Sub> — borrow the ref attribute's catalog with the sub-attribute
            deep_by_attr = {}
            for dp in deep_paths:
                if dp["ObjectAttr"] in ts_names:
                    continue
                deep_by_attr.setdefault(dp["ObjectAttr"], [])
                if dp["SubAttr"] not in deep_by_attr[dp["ObjectAttr"]]:
                    deep_by_attr[dp["ObjectAttr"]].append(dp["SubAttr"])
            if deep_by_attr:
                info(f"  Processing {len(deep_by_attr)} deep path attribute(s)...")
                for attr_name, sub_attr_names in deep_by_attr.items():
                    attr_info = next((a for a in src_attrs if a["Name"] == attr_name), None)
                    if not attr_info:
                        continue
                    cat_match = re.search(r'cfg:(\w+)Ref\.(\w+)', attr_info["TypeXml"])
                    if not cat_match:
                        continue
                    borrow_deep_target_attrs(cat_match.group(1), cat_match.group(2), sub_attr_names)

            # Tabular-section deep paths: Объект.<ТЧ>.<Колонка>.<Sub> — borrow the column's catalog with the sub-attribute
            ts_deep_by_col = {}
            for dp in deep_paths:
                if dp["ObjectAttr"] not in ts_names:
                    continue
                if not dp.get("SubSubAttr"):
                    continue
                if dp["SubSubAttr"] in STANDARD_FIELDS:
                    continue
                k = (dp["ObjectAttr"], dp["SubAttr"])
                ts_deep_by_col.setdefault(k, [])
                if dp["SubSubAttr"] not in ts_deep_by_col[k]:
                    ts_deep_by_col[k].append(dp["SubSubAttr"])
            if ts_deep_by_col:
                info(f"  Processing {len(ts_deep_by_col)} tabular-section deep path(s)...")
                for (ts_name, col_name), sub_attr_names in ts_deep_by_col.items():
                    ts_info = next((t for t in src_ts if t["Name"] == ts_name), None)
                    if not ts_info:
                        continue
                    col_info = next((c for c in ts_info["Attributes"] if c["Name"] == col_name), None)
                    if not col_info:
                        continue
                    cat_match = re.search(r'cfg:(\w+)Ref\.(\w+)', col_info["TypeXml"])
                    if not cat_match:
                        continue
                    borrow_deep_target_attrs(cat_match.group(1), cat_match.group(2), sub_attr_names)

        info("  Main attribute borrowing complete")

    def borrow_deep_target_attrs(target_type_name, target_obj_name, sub_attr_names):
        # Borrow a deep-path target catalog together with the referenced sub-attributes, for both
        # Объект.<Ref>.<Sub> and Объект.<ТЧ>.<Колонка>.<Sub>. Mirrors Designer: the referenced catalog
        # is adopted WITH the sub-attributes the form shows, else the platform rejects the deep DataPath.
        if not test_object_borrowed(target_type_name, target_obj_name):
            t_src = read_source_object(target_type_name, target_obj_name)
            t_borrowed_xml = build_borrowed_object_xml(target_type_name, target_obj_name, t_src["Uuid"], t_src["Properties"])
            t_target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[target_type_name])
            os.makedirs(t_target_dir, exist_ok=True)
            t_target_file = os.path.join(t_target_dir, f"{target_obj_name}.xml")
            write_xml_file(t_target_file, t_borrowed_xml)
            add_to_child_objects(target_type_name, target_obj_name)
            borrowed_files.append(t_target_file)
            info(f"  Auto-borrowed for deep path: {target_type_name}.{target_obj_name}")

        sub_names = {sn: True for sn in sub_attr_names}
        sub_resolved = resolve_source_attributes(target_type_name, target_obj_name, sub_names)
        if sub_resolved["Attributes"]:
            merge_attributes_into_object(target_type_name, target_obj_name, sub_resolved["Attributes"])
            sub_type_xmls = [sa["TypeXml"] for sa in sub_resolved["Attributes"]]
            sub_ref_types = collect_reference_types(sub_type_xmls)
            for srt in sub_ref_types:
                if srt["TypeName"] not in CHILD_TYPE_DIR_MAP:
                    continue
                if test_object_borrowed(srt["TypeName"], srt["ObjName"]):
                    continue
                s_src_file = os.path.join(cfg_dir, CHILD_TYPE_DIR_MAP[srt["TypeName"]], f"{srt['ObjName']}.xml")
                if not os.path.isfile(s_src_file):
                    continue
                s_src = read_source_object(srt["TypeName"], srt["ObjName"])
                s_borrowed_xml = build_borrowed_object_xml(srt["TypeName"], srt["ObjName"], s_src["Uuid"], s_src["Properties"])
                s_target_dir = os.path.join(ext_dir, CHILD_TYPE_DIR_MAP[srt["TypeName"]])
                os.makedirs(s_target_dir, exist_ok=True)
                s_target_file = os.path.join(s_target_dir, f"{srt['ObjName']}.xml")
                write_xml_file(s_target_file, s_borrowed_xml)
                add_to_child_objects(srt["TypeName"], srt["ObjName"])
                borrowed_files.append(s_target_file)
                info(f"  Auto-borrowed (deep): {srt['TypeName']}.{srt['ObjName']}")

    def borrow_form(type_name, obj_name, form_name, borrow_main_attr=False):
        dir_name = CHILD_TYPE_DIR_MAP[type_name]

        # 1. Read source form UUID
        form_uuid = read_source_form_uuid(type_name, obj_name, form_name)
        info(f"  Source form UUID: {form_uuid}")

        # 2. Read source Form.xml
        src_form_xml_path = os.path.join(cfg_dir, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml")
        if not os.path.isfile(src_form_xml_path):
            print(f"Source Form.xml not found: {src_form_xml_path}", file=sys.stderr)
            sys.exit(1)
        with open(src_form_xml_path, "r", encoding="utf-8-sig") as fh:
            src_form_content = fh.read()

        # 3. Generate form metadata XML.
        # If the wrapper was already borrowed, reuse its uuid so re-borrow is idempotent
        # (regenerating it would churn the form's identity on every rerun).
        existing_wrapper = os.path.join(ext_dir, dir_name, obj_name, "Forms", f"{form_name}.xml")
        new_form_uuid = ""
        if os.path.isfile(existing_wrapper):
            try:
                existing_root = etree.parse(existing_wrapper).getroot()
                for c in existing_root:
                    if isinstance(c.tag, str) and localname(c) == "Form":
                        new_form_uuid = c.get("uuid", "") or ""
                        break
            except Exception:
                new_form_uuid = ""
        if not new_form_uuid:
            new_form_uuid = new_guid()
        form_meta_lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<MetaDataObject {XMLNS_DECL} version="{format_version}">',
            f'\t<Form uuid="{new_form_uuid}">',
            '\t\t<InternalInfo/>',
            '\t\t<Properties>',
            '\t\t\t<ObjectBelonging>Adopted</ObjectBelonging>',
            f'\t\t\t<Name>{form_name}</Name>',
            '\t\t\t<Comment/>',
            f'\t\t\t<ExtendedConfigurationObject>{form_uuid}</ExtendedConfigurationObject>',
            '\t\t\t<FormType>Managed</FormType>',
            '\t\t</Properties>',
            '\t</Form>',
            '</MetaDataObject>',
        ]

        # 4. Create directories
        form_meta_dir = os.path.join(ext_dir, dir_name, obj_name, "Forms")
        os.makedirs(form_meta_dir, exist_ok=True)

        form_meta_file = os.path.join(form_meta_dir, f"{form_name}.xml")
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

        # Основной реквизит исходной формы: его имя — корень путей к данным, которые нужно сохранить
        # («Объект.» у формы объекта, «Список.» у формы списка, «Запись.» у формы записи регистра)
        main_attr_info = src_main_info if borrow_main_attr else None
        # Имена реквизитов объекта нужны в обоих режимах: без заимствования — чтобы построить
        # непрозрачный путь, с заимствованием — чтобы отличить реквизит (разрешается текстом) от
        # стандартного поля (не разрешается)
        src_attr_uuids = get_source_attribute_uuids(type_name, obj_name)
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
            auto_cmd_xml = rewrite_choice_parameter_links(
                auto_cmd_xml, src_attr_uuids, form_attr_ids, src_main_attr_name, main_attr_info is not None)

        # ChildItems: copy full tree, clean up base-config references
        child_items_xml = ""
        src_child_items = None
        for fc in src_form_el:
            if isinstance(fc.tag, str) and localname(fc) == "ChildItems":
                src_child_items = fc
                break

        if src_child_items is not None:
            child_items_xml = decode_numeric_entities(etree.tostring(src_child_items, encoding="unicode", with_tail=False))
            child_items_xml = ns_strip_pattern.sub("", child_items_xml)
            # Replace all CommandName values with 0
            child_items_xml = re.sub(r'<CommandName>[^<]*</CommandName>', '<CommandName>0</CommandName>', child_items_xml)
            # Strip data-binding tags whose root attribute isn't borrowed
            child_items_xml = strip_form_bindings(child_items_xml, main_attr_name)
            child_items_xml = rewrite_choice_parameter_links(
                child_items_xml, src_attr_uuids, form_attr_ids, src_main_attr_name, main_attr_info is not None)
            # Вложенные CommandSet (у таблиц, полей табличного документа и т.п.) — целиком, см. выше
            child_items_xml = re.sub(r'(?s)\s*<CommandSet>.*?</CommandSet>', '', child_items_xml)
            child_items_xml = re.sub(r'\s*<CommandSet/>', '', child_items_xml)
            # Strip TypeLink blocks with human-readable DataPath (Items.XXX)
            child_items_xml = re.sub(r'\s*<TypeLink>\s*<xr:DataPath>Items\.[^<]*</xr:DataPath>.*?</TypeLink>', '', child_items_xml, flags=re.DOTALL)
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
            # Strip StdPicture blocks (except Print)
            child_items_xml = re.sub(r'\s*<Picture>\s*<xr:Ref>StdPicture\.(?!Print\b)\w+</xr:Ref>.*?</Picture>', '', child_items_xml, flags=re.DOTALL)

            # Same Picture strip for AutoCommandBar
            if auto_cmd_xml:
                ac_pic_matches = list(pic_block_pattern.finditer(auto_cmd_xml))
                for pm in reversed(ac_pic_matches):
                    cp_name = pm.group(1)
                    if cp_name not in borrowed_pic_set:
                        auto_cmd_xml = auto_cmd_xml[:pm.start()] + auto_cmd_xml[pm.end():]
                auto_cmd_xml = re.sub(r'\s*<Picture>\s*<xr:Ref>StdPicture\.(?!Print\b)\w+</xr:Ref>.*?</Picture>', '', auto_cmd_xml, flags=re.DOTALL)

            # Auto-borrow StyleItems referenced in ChildItems
            referenced_styles = set()
            for m in re.finditer(r'ref="style:(\w+)"[^>]*kind="StyleItem"', child_items_xml):
                referenced_styles.add(m.group(1))
            for m in re.finditer(r'>style:(\w+)</\w+>', child_items_xml):
                referenced_styles.add(m.group(1))

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
                    else:
                        warn(f"  StyleItem.{style_name} not found in source config")

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

        # Attributes: empty or with MainAttribute when borrow_main_attr
        if borrow_main_attr and main_attr_info:
            parts.append("\t<Attributes>\r\n")
            parts.append(f"\t\t{main_attr_info['Xml']}\r\n")
            parts.append("\t</Attributes>")
        else:
            parts.append("\t<Attributes/>")
        parts.append("\r\n")

        # BaseForm: same content, indented one more level
        parts.append(f'\t<BaseForm version="{form_version}">\r\n')

        for prop_xml in form_props:
            prop_xml_clean = ns_strip_pattern.sub("", prop_xml)
            parts.append(f"\t\t{prop_xml_clean}\r\n")
        if auto_cmd_xml:
            ac_lines = auto_cmd_xml.split("\n")
            for li, line in enumerate(ac_lines):
                if li == 0:
                    parts.append(f"\t\t{line}")
                else:
                    parts.append(f"\t{line}")
                parts.append("\r\n")
        if child_items_xml:
            ci_lines = child_items_xml.split("\n")
            for li, line in enumerate(ci_lines):
                if li == 0:
                    parts.append(f"\t\t{line}")
                else:
                    parts.append(f"\t{line}")
                parts.append("\r\n")

        # BaseForm Attributes: same as main section
        if borrow_main_attr and main_attr_info:
            parts.append("\t\t<Attributes>\r\n")
            # В BaseForm та же секция на уровень глубже — приём переиндентации тот же, что у ChildItems
            for li, line in enumerate(main_attr_info['Xml'].split('\n')):
                parts.append(f"\t\t\t{line}" if li == 0 else f"\t{line}")
                parts.append("\r\n")
            parts.append("\t\t</Attributes>")
        else:
            parts.append("\t\t<Attributes/>")
        parts.append("\r\n")
        parts.append("\t</BaseForm>\r\n")
        parts.append("</Form>")

        form_xml_dir = os.path.join(form_meta_dir, form_name, "Ext")
        os.makedirs(form_xml_dir, exist_ok=True)
        form_xml_file = os.path.join(form_xml_dir, "Form.xml")
        write_xml_file(form_xml_file, "".join(parts))
        info(f"  Created: {form_xml_file}")
        if DROPPED_LINKS:
            uniq = sorted(set(DROPPED_LINKS))
            warn(f"  Вырезано связей параметров выбора: {len(uniq)} — путь не разрешается в расширении: {', '.join(uniq)}")
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

        # 7. Register form in parent object ChildObjects
        register_form_in_object(type_name, obj_name, form_name)

        return [form_meta_file, form_xml_file, module_bsl_file]

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
        # Validate: only with .Form. pattern
        has_form = any(".Form." in item for item in items)
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

    for item in items:
        dot_idx = item.find(".")
        if dot_idx < 1:
            print(f"Invalid format '{item}', expected 'Type.Name' or 'Type.Name.Form.FormName'", file=sys.stderr)
            sys.exit(1)
        type_name = item[:dot_idx]
        remainder = item[dot_idx + 1:]

        if type_name in SYNONYM_MAP:
            type_name = SYNONYM_MAP[type_name]

        if type_name not in CHILD_TYPE_DIR_MAP:
            print(f"Unknown type '{type_name}'", file=sys.stderr)
            sys.exit(1)

        form_name = None
        form_idx = remainder.find(".Form.")
        if form_idx > 0:
            obj_name = remainder[:form_idx]
            form_name = remainder[form_idx + 6:]
        else:
            obj_name = remainder

        dir_name = CHILD_TYPE_DIR_MAP[type_name]

        if form_name:
            # --- Form borrowing ---
            info(f"Borrowing form {type_name}.{obj_name}.Form.{form_name}...")

            if not test_object_borrowed(type_name, obj_name):
                info(f"  Parent object {type_name}.{obj_name} not yet borrowed \u2014 borrowing first...")

                src = read_source_object(type_name, obj_name)
                info(f"  Source UUID: {src['Uuid']}")
                borrowed_xml = build_borrowed_object_xml(type_name, obj_name, src["Uuid"], src["Properties"])

                target_dir = os.path.join(ext_dir, dir_name)
                os.makedirs(target_dir, exist_ok=True)
                target_file = os.path.join(target_dir, f"{obj_name}.xml")
                write_xml_file(target_file, borrowed_xml)
                info(f"  Created: {target_file}")

                add_to_child_objects(type_name, obj_name)
                borrowed_files.append(target_file)

            has_bma = borrow_main_attribute_mode is not None
            form_files = borrow_form(type_name, obj_name, form_name, borrow_main_attr=has_bma)
            borrowed_files.extend(form_files)
            # Замер на 8.3.26: платформа помечает форму расширенной сразу при заимствовании,
            # даже если элементы не менялись. Флаг живёт в метаданных формы, не у владельца.
            set_property_state_flag(form_files[0], "Form", format_version)
            borrowed_count += 1

            # Borrow main attribute if requested
            if has_bma:
                borrow_main_attribute(type_name, obj_name, form_name, borrow_main_attribute_mode)
        else:
            # --- Object borrowing ---
            target_dir = os.path.join(ext_dir, dir_name)
            target_file = os.path.join(target_dir, f"{obj_name}.xml")

            # Уже заимствованный объект НЕ переписываем: в его XML лежат собственные реквизиты
            # расширения, заимствованные подобъекты и состояния, которые из источника не
            # выводятся. Повторный вызов — законный способ доделать модуль (-Module), а не
            # переиздать заготовку.
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

            borrowed_files.append(target_file)
            for kind in resolve_module_kinds(type_name):
                borrowed_files.append(new_borrowed_module_file(type_name, obj_name, kind))
            borrowed_count += 1

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
