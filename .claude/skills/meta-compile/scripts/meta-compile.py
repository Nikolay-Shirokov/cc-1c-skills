#!/usr/bin/env python3
# meta-compile v1.66 — Compile 1C metadata object from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# ============================================================
# Support guard (Ext/ParentConfigurations.bin) — see docs/1c-support-state-spec.md
# Blocks edits of vendor objects "на замке" / read-only configs. Trigger = bin
# present; reaction from .v8-project.json editingAllowedCheck (deny|warn|off,
# default deny). Never throws (except sys.exit on deny) — errors degrade to allow.
# ============================================================

def _sg_root_uuid(xml_path):
    if not os.path.isfile(xml_path):
        return None
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str) and child.get("uuid"):
                return child.get("uuid")
    except Exception:
        return None
    return None


def _sg_is_external_root(xml_path):
    if not os.path.isfile(xml_path):
        return False
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str):
                return child.tag.split("}")[-1] in ("ExternalDataProcessor", "ExternalReport")
    except Exception:
        return False
    return False

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


def _sg_get_edit_mode(cfg_dir):
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(cfg_dir)
        if not pj:
            return "deny"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir)).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src:
                src_full = os.path.normcase(os.path.abspath(src)).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    if db.get("editingAllowedCheck"):
                        return db["editingAllowedCheck"]
        if proj.get("editingAllowedCheck"):
            return proj["editingAllowedCheck"]
        return "deny"
    except Exception:
        return "deny"


def assert_edit_allowed(target_path, require):
    try:
        rp = os.path.abspath(target_path)
        # Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
        if _sg_is_external_root(rp):
            return
        elem_uuid = _sg_root_uuid(rp)
        cfg_dir = None
        bin_path = None
        d = rp if os.path.isdir(rp) else os.path.dirname(rp)
        for _ in range(12):
            if not d:
                break
            if _sg_is_external_root(d + ".xml"):
                return
            if not elem_uuid:
                elem_uuid = _sg_root_uuid(d + ".xml")
            if not cfg_dir:
                cand = os.path.join(d, "Ext", "ParentConfigurations.bin")
                if os.path.exists(cand) or os.path.exists(os.path.join(d, "Configuration.xml")):
                    cfg_dir = d
                    bin_path = cand
            if elem_uuid and cfg_dir:
                break
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
        if not elem_uuid and cfg_dir:
            elem_uuid = _sg_root_uuid(os.path.join(cfg_dir, "Configuration.xml"))
        if not bin_path or not os.path.exists(bin_path):
            return
        data = open(bin_path, "rb").read()
        if len(data) <= 32:
            return
        if data[:3] == b"\xef\xbb\xbf":
            data = data[3:]
        text = data.decode("utf-8", "replace")
        h = re.match(r"\{6,(\d+),(\d+),", text)
        if not h:
            return
        g = int(h.group(1))
        k = int(h.group(2))
        if k == 0:
            return
        best = None
        if elem_uuid:
            for m in re.finditer(r"([0-2]),0," + re.escape(elem_uuid.lower()), text):
                f1 = int(m.group(1))
                if best is None or f1 < best:
                    best = f1
        blocked = False
        code = ""
        reason = ""
        if g == 1:
            blocked = True
            code = "capability-off"
            reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)"
        elif require == "removed":
            if best is not None and best != 2:
                blocked = True
                code = "not-removed"
                reason = "объект не снят с поддержки — удаление сломает обновления"
        else:
            if best is not None and best == 0:
                blocked = True
                code = "locked"
                reason = "объект на замке — редактирование сломает обновления"
        if not blocked:
            return
        mode = _sg_get_edit_mode(cfg_dir)
        if mode == "off":
            return
        if mode == "warn":
            sys.stderr.write(f"[support-guard] ПРЕДУПРЕЖДЕНИЕ: {reason}. Цель: {rp}\n")
            return
        head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
        cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
        off_note = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
        if code == "capability-off":
            state = f"Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «{rp}» редактировать нельзя."
            fix = (
                "Либо снять защиту явно (навык support-edit, два шага):\n"
                f'  1. support-edit -Path "{cfg_dir}" -Capability on — включить возможность изменения (объекты пока остаются на замке);\n'
                f'  2. support-edit -Path "{rp}" -Set editable — открыть этот объект для редактирования.\n'
                "  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
            )
        elif code == "not-removed":
            state = f"Состояние: объект «{rp}» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
            fix = (
                "Либо сначала снять объект с поддержки, затем удалять:\n"
                f'  support-edit -Path "{rp}" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно.'
            )
        else:
            state = f"Состояние: объект «{rp}» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
            fix = (
                "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):\n"
                f'  support-edit -Path "{rp}" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);\n'
                f'  support-edit -Path "{rp}" -Set off-support — снять с поддержки: обновления по объекту больше не приходят.'
            )
        sys.stderr.write(head + "\n" + state + "\n" + cfe + "\n" + fix + "\n" + off_note + "\n")
        sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        return

# ---------------------------------------------------------------------------
# Inline utilities
# ---------------------------------------------------------------------------

def esc_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')

def esc_xml_text(s):
    # Эскейп ТЕКСТА элемента: только & < > (кавычки в тексте 1С держит raw).
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

def new_uuid():
    return str(uuid.uuid4())

def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)

# ---------------------------------------------------------------------------
# XML builder (lines list)
# ---------------------------------------------------------------------------

lines = []

def X(text):
    lines.append(text)

# ML-значение: строка → один <v8:item> ru; dict {lang: content} → item на язык (в порядке ключей).
def emit_ml_items(indent, val):
    if isinstance(val, dict):
        for k, v in val.items():
            X(f'{indent}<v8:item>')
            X(f'{indent}\t<v8:lang>{k}</v8:lang>')
            X(f'{indent}\t<v8:content>{esc_xml_text(str(v))}</v8:content>')
            X(f'{indent}</v8:item>')
    else:
        X(f'{indent}<v8:item>')
        X(f'{indent}\t<v8:lang>ru</v8:lang>')
        X(f'{indent}\t<v8:content>{esc_xml_text(str(val))}</v8:content>')
        X(f'{indent}</v8:item>')

def emit_mltext(indent, tag, text):
    # Пусто (None / '') → самозакрывающийся тег.
    if text is None or (isinstance(text, str) and text == ''):
        X(f'{indent}<{tag}/>')
        return
    X(f'{indent}<{tag}>')
    emit_ml_items(f'{indent}\t', text)
    X(f'{indent}</{tag}>')

# ---------------------------------------------------------------------------
# CamelCase splitter
# ---------------------------------------------------------------------------

def split_camel_case(name):
    if not name:
        return name
    result = re.sub(r'([а-яё])([А-ЯЁ])', r'\1 \2', name)
    result = re.sub(r'([a-z])([A-Z])', r'\1 \2', result)
    # Лоуэркейзим хвост, СОХРАНЯЯ аббревиатуры (зеркало эвристики платформы): максимальный прогон
    # заглавных длиной >=2, если сразу за ним НЕ буква (пробел/цифра/спецсимвол/конец) — остаётся заглавным
    # (НДС, ЕГАИС, ОС, ЭП). Прилипшие предлоги (СКлиентами)/бренды (ЮКасса) идут перед буквой → лоуэркейз.
    # Первый символ строки — как есть.
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

# ---------------------------------------------------------------------------
# 1. Load and validate JSON
# ---------------------------------------------------------------------------

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('-JsonPath', required=True)
parser.add_argument('-OutputDir', required=True)
args = parser.parse_args()

json_path = args.JsonPath
output_dir = args.OutputDir

if not os.path.isfile(json_path):
    print(f'File not found: {json_path}', file=sys.stderr)
    sys.exit(1)

with open(json_path, 'r', encoding='utf-8-sig') as f:
    json_text = f.read()

defn = json.loads(json_text)

assert_edit_allowed(output_dir, "editable")

# --- Batch mode: JSON array of objects ---
if isinstance(defn, list):
    batch_ok = 0
    batch_fail = 0
    for idx, item in enumerate(defn, 1):
        tmp_fd, tmp_path = tempfile.mkstemp(suffix='.json', prefix=f'meta-compile-batch-{idx}-')
        try:
            with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
                json.dump(item, f, ensure_ascii=False, indent=2)
            rc = subprocess.call([sys.executable, __file__, '-JsonPath', tmp_path, '-OutputDir', output_dir])
            if rc == 0:
                batch_ok += 1
            else:
                batch_fail += 1
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
    print()
    print(f"=== Batch: {len(defn)} objects, {batch_ok} compiled, {batch_fail} failed ===")
    sys.exit(1 if batch_fail > 0 else 0)

# Normalize field synonyms: accept "objectType" as alias for "type"
if not defn.get('type') and defn.get('objectType'):
    defn['type'] = defn['objectType']

# Object type synonyms (Russian -> English)
object_type_synonyms = {
    'Справочник': 'Catalog',
    'Каталог': 'Catalog',
    'Документ': 'Document',
    'Перечисление': 'Enum',
    'Константа': 'Constant',
    'РегистрСведений': 'InformationRegister',
    'РегистрНакопления': 'AccumulationRegister',
    'РегистрБухгалтерии': 'AccountingRegister',
    'РегистрРасчёта': 'CalculationRegister',
    'РегистрРасчета': 'CalculationRegister',
    'ПланСчетов': 'ChartOfAccounts',
    'ПланВидовХарактеристик': 'ChartOfCharacteristicTypes',
    'ПланВидовРасчёта': 'ChartOfCalculationTypes',
    'ПланВидовРасчета': 'ChartOfCalculationTypes',
    'БизнесПроцесс': 'BusinessProcess',
    'Задача': 'Task',
    'ПланОбмена': 'ExchangePlan',
    'ЖурналДокументов': 'DocumentJournal',
    'Отчёт': 'Report',
    'Отчет': 'Report',
    'Обработка': 'DataProcessor',
    'ОбщийМодуль': 'CommonModule',
    'РегламентноеЗадание': 'ScheduledJob',
    'ПодпискаНаСобытие': 'EventSubscription',
    'HTTPСервис': 'HTTPService',
    'ВебСервис': 'WebService',
    'ОпределяемыйТип': 'DefinedType',
    'ФункциональнаяОпция': 'FunctionalOption',
}

# Enum property value synonyms — model often gets these slightly wrong
enum_value_aliases = {
    # RegisterType (AccumulationRegister)
    'Balances': 'Balance', 'Остатки': 'Balance', 'Обороты': 'Turnovers',
    # WriteMode (InformationRegister)
    'RecordSubordinate': 'RecorderSubordinate', 'Subordinate': 'RecorderSubordinate',
    'ПодчинениеРегистратору': 'RecorderSubordinate', 'Независимый': 'Independent',
    # DependenceOnCalculationTypes (ChartOfCalculationTypes)
    'NotDependOnCalculationTypes': 'DontUse', 'NoDependence': 'DontUse', 'NotUsed': 'DontUse',
    'Depend': 'OnActionPeriod', 'ПоПериодуДействия': 'OnActionPeriod',
    # InformationRegisterPeriodicity
    'None': 'Nonperiodical', 'Daily': 'Day', 'Monthly': 'Month',
    'Quarterly': 'Quarter', 'Yearly': 'Year',
    'Непериодический': 'Nonperiodical', 'Секунда': 'Second', 'День': 'Day',
    'Месяц': 'Month', 'Квартал': 'Quarter', 'Год': 'Year',
    'ПозицияРегистратора': 'RecorderPosition',
    # DataLockControlMode
    'Автоматический': 'Automatic', 'Управляемый': 'Managed',
    # FullTextSearch
    'Использовать': 'Use', 'НеИспользовать': 'DontUse',
    # Posting
    'Разрешить': 'Allow', 'Запретить': 'Deny',
    # EditType
    'ВДиалоге': 'InDialog', 'ВСписке': 'InList', 'ОбаСпособа': 'BothWays',
    # DefaultPresentation
    'ВВидеНаименования': 'AsDescription', 'ВВидеКода': 'AsCode',
    # FillChecking
    'НеПроверять': 'DontCheck', 'Ошибка': 'ShowError', 'Предупреждение': 'ShowWarning',
    # Indexing
    'НеИндексировать': 'DontIndex', 'Индексировать': 'Index',
    'ИндексироватьСДопУпорядочиванием': 'IndexWithAdditionalOrder',
}

# Valid enum values per property (from meta-validate)
valid_enum_values = {
    'RegisterType': ['Balance', 'Turnovers'],
    'WriteMode': ['Independent', 'RecorderSubordinate'],
    'InformationRegisterPeriodicity': ['Nonperiodical', 'Second', 'Day', 'Month', 'Quarter', 'Year', 'RecorderPosition'],
    'DependenceOnCalculationTypes': ['DontUse', 'OnActionPeriod'],
    'DataLockControlMode': ['Automatic', 'Managed'],
    'FullTextSearch': ['Use', 'DontUse'],
    'DataHistory': ['Use', 'DontUse'],
    'DefaultPresentation': ['AsDescription', 'AsCode'],
    'Posting': ['Allow', 'Deny'],
    'RealTimePosting': ['Allow', 'Deny'],
    'EditType': ['InDialog', 'InList', 'BothWays'],
    'HierarchyType': ['HierarchyFoldersAndItems', 'HierarchyOfItems'],
    'CodeType': ['String', 'Number'],
    'CodeAllowedLength': ['Variable', 'Fixed'],
    'NumberType': ['String', 'Number'],
    'NumberAllowedLength': ['Variable', 'Fixed'],
    'RegisterRecordsDeletion': ['AutoDelete', 'AutoDeleteOnUnpost', 'AutoDeleteOff'],
    'RegisterRecordsWritingOnPost': ['WriteModified', 'WriteSelected', 'WriteAll'],
    'ReturnValuesReuse': ['DontUse', 'DuringRequest', 'DuringSession'],
    'ReuseSessions': ['DontUse', 'AutoUse'],
    'FillChecking': ['DontCheck', 'ShowError', 'ShowWarning'],
    'Indexing': ['DontIndex', 'Index', 'IndexWithAdditionalOrder'],
    'SubordinationUse': ['ToItems', 'ToFolders', 'ToFoldersAndItems'],
    'CodeSeries': ['WholeCatalog', 'WithinSubordination', 'WithinOwnerSubordination', 'WholeCharacteristicKind', 'WholeChartOfAccounts'],
    'ChoiceMode': ['BothWays', 'QuickChoice', 'FromForm'],
    'CreateOnInput': ['Auto', 'Use', 'DontUse'],
    'ChoiceHistoryOnInput': ['Auto', 'DontUse'],
    'PredefinedDataUpdate': ['Auto', 'DontAutoUpdate', 'AutoUpdate'],
    'SearchStringModeOnInputByString': ['Begin', 'AnyPart'],
    'FullTextSearchOnInputByString': ['Use', 'DontUse'],
    'Category': ['NavigationPanel', 'ActionsPanel', 'FormCommandBar', 'FormNavigationPanel'],
}

# --- Группы команд объекта (командный интерфейс) ---
# Группы командного интерфейса РАЗДЕЛА (панель навигации/действий): команда БЕЗ параметра. Группы формы: параметр доступен.
SECTION_COMMAND_GROUPS = [
    'NavigationPanelImportant', 'NavigationPanelOrdinary', 'NavigationPanelSeeAlso',
    'ActionsPanelCreate', 'ActionsPanelReports', 'ActionsPanelTools',
]
FORM_COMMAND_GROUPS = [
    'FormCommandBarImportant', 'FormCommandBarCreateBasedOn',
    'FormNavigationPanelImportant', 'FormNavigationPanelGoTo', 'FormNavigationPanelSeeAlso',
]
VALID_COMMAND_GROUPS = SECTION_COMMAND_GROUPS + FORM_COMMAND_GROUPS
COMMAND_GROUP_ALIASES = {
    'Панель навигации.Важное': 'NavigationPanelImportant',
    'Панель навигации.Обычное': 'NavigationPanelOrdinary',
    'Панель навигации.См. также': 'NavigationPanelSeeAlso',
    'Панель действий.Создать': 'ActionsPanelCreate',
    'Панель действий.Отчеты': 'ActionsPanelReports',
    'Панель действий.Отчёты': 'ActionsPanelReports',
    'Панель действий.Сервис': 'ActionsPanelTools',
    'Командная панель формы.Важное': 'FormCommandBarImportant',
    'Командная панель формы.Создать на основании': 'FormCommandBarCreateBasedOn',
    'Панель навигации формы.Важное': 'FormNavigationPanelImportant',
    'Панель навигации формы.Перейти': 'FormNavigationPanelGoTo',
    'Панель навигации формы.См. также': 'FormNavigationPanelSeeAlso',
}


def resolve_command_group(raw, cmd_name):
    g = (str(raw) if raw is not None else '').strip()
    if not g:
        sys.stderr.write(f"Команде '{cmd_name}' не задана группа (group). 1С требует группу. "
                         f"Валидные: {', '.join(VALID_COMMAND_GROUPS)}; либо CommandGroup.<Имя> — кастомная группа.\n")
        sys.exit(1)
    if g in COMMAND_GROUP_ALIASES:
        return COMMAND_GROUP_ALIASES[g]
    m = re.match(r'^(?:CommandGroup|ГруппаКоманд)\.(.+)$', g)
    if m:
        return f'CommandGroup.{m.group(1)}'
    return g

def normalize_enum_value(prop_name, value):
    # 1. Check alias dictionary — silent auto-correct
    if value in enum_value_aliases:
        return enum_value_aliases[value]
    # 2. Case-insensitive match against valid values — silent
    valid = valid_enum_values.get(prop_name)
    if valid:
        for v in valid:
            if v.lower() == value.lower():
                return v
        # 3. Known property, unknown value — error with hint
        print(f"Invalid value '{value}' for property '{prop_name}'. Valid values: {', '.join(valid)}", file=sys.stderr)
        sys.exit(1)
    # 4. Unknown property — pass-through (no validation data)
    return value

def get_enum_prop(prop_name, field_name, default):
    val = defn.get(field_name)
    raw = str(val) if val else default
    return normalize_enum_value(prop_name, raw)

def get_bool_prop(field_name, default):
    """Bool object-свойство: presence-aware (иначе false спутать с отсутствием). Прощаем строки."""
    val = defn.get(field_name)
    if val is None:
        return default
    if isinstance(val, bool):
        return val
    return str(val).lower() in ('true', '1', 'да', 'истина')

def normalize_form_ref(s):
    """Прощающая нормализация ссылки на форму: рус корень, Форма→Form, короткая запись → вставка Form."""
    if not s:
        return s
    parts = s.split('.')
    if len(parts) < 3:
        return s
    root = fill_ref_roots.get(parts[0].lower())
    if root:
        parts[0] = root
    for k in range(1, len(parts)):
        if parts[k].lower() == 'форма':
            parts[k] = 'Form'
    if 'Form' not in parts and len(parts) == 3:
        parts = [parts[0], parts[1], 'Form', parts[2]]
    return '.'.join(parts)

def emit_form_ref(i, tag, val):
    """Ссылка на форму по умолчанию: непустая → <Tag>значение</Tag>, иначе <Tag/>."""
    if val:
        X(f'{i}<{tag}>{esc_xml(normalize_form_ref(str(val)))}</{tag}>')
    else:
        X(f'{i}<{tag}/>')

def emit_verbatim_ref(i, tag, val):
    """Ссылка verbatim (без normalize_form_ref): формы/схемы/хранилища Report/DataProcessor, где имя формы
    может быть буквально «Форма» (normalize перевёл бы имя-сегмент Форма→Form) либо ref не-форменного вида."""
    if val:
        X(f'{i}<{tag}>{esc_xml(str(val))}</{tag}>')
    else:
        X(f'{i}<{tag}/>')

if not defn.get('type'):
    print("JSON must have 'type' field", file=sys.stderr)
    sys.exit(1)

obj_type = str(defn['type'])
if obj_type in object_type_synonyms:
    obj_type = object_type_synonyms[obj_type]

valid_types = [
    'Catalog', 'Document', 'Enum', 'Constant', 'InformationRegister',
    'AccumulationRegister', 'AccountingRegister', 'CalculationRegister',
    'ChartOfAccounts', 'ChartOfCharacteristicTypes', 'ChartOfCalculationTypes',
    'BusinessProcess', 'Task', 'ExchangePlan', 'DocumentJournal',
    'Report', 'DataProcessor', 'CommonModule', 'ScheduledJob',
    'EventSubscription', 'HTTPService', 'WebService', 'DefinedType',
    'FunctionalOption',
    'Sequence', 'FilterCriterion', 'DocumentNumerator', 'SettingsStorage',
    'CommonForm',
    'SessionParameter', 'CommonCommand', 'CommandGroup', 'CommonAttribute', 'FunctionalOptionsParameter', 'WSReference',
    'CommonPicture', 'CommonTemplate',
]
if obj_type not in valid_types:
    print(f"Unsupported type: {obj_type}. Valid: {', '.join(valid_types)}", file=sys.stderr)
    sys.exit(1)

if not defn.get('name'):
    print("JSON must have 'name' field", file=sys.stderr)
    sys.exit(1)

obj_name = str(defn['name'])

# Auto-synonym
# Проброс без стрингификации (строка ИЛИ {ru,en} — мультиязычный синоним объекта).
synonym = defn['synonym'] if defn.get('synonym') is not None else split_camel_case(obj_name)
comment = str(defn['comment']) if defn.get('comment') else ''

# ---------------------------------------------------------------------------
# 4. Type system
# ---------------------------------------------------------------------------

type_synonyms = {
    'число': 'Number',
    'строка': 'String',
    'булево': 'Boolean',
    'дата': 'Date',
    'датавремя': 'DateTime',
    'время': 'Time',
    'time': 'Time',
    'number': 'Number',
    'string': 'String',
    'boolean': 'Boolean',
    'date': 'Date',
    'datetime': 'DateTime',
    'bool': 'Boolean',
    # ValueStorage / UUID — прощающий ввод (base64Binary / рус. форма → канон).
    'valuestorage': 'ValueStorage',
    'base64binary': 'ValueStorage',
    'хранилищезначений': 'ValueStorage',
    'хранилищезначения': 'ValueStorage',
    'uuid': 'UUID',
    'уникальныйидентификатор': 'UUID',
    # Reference synonyms (Russian, lowercase)
    'справочникссылка': 'CatalogRef',
    'документссылка': 'DocumentRef',
    'перечислениессылка': 'EnumRef',
    'плансчетовссылка': 'ChartOfAccountsRef',
    'планвидовхарактеристикссылка': 'ChartOfCharacteristicTypesRef',
    'планвидоврасчётассылка': 'ChartOfCalculationTypesRef',
    'планвидоврасчетассылка': 'ChartOfCalculationTypesRef',
    'планобменассылка': 'ExchangePlanRef',
    'бизнеспроцессссылка': 'BusinessProcessRef',
    'задачассылка': 'TaskRef',
    'определяемыйтип': 'DefinedType',
    'definedtype': 'DefinedType',
    # English lowercase ref synonyms
    'catalogref': 'CatalogRef',
    'documentref': 'DocumentRef',
    'enumref': 'EnumRef',
    # Платформенные коллекции (прощающий ввод рус. форм).
    'таблицазначений': 'ValueTable',
    'деревозначений': 'ValueTree',
    'списокзначений': 'ValueListType',
    'стандартныйпериод': 'StandardPeriod',
}

# Платформенные типы, требующие префикса v8: (коллекции/периоды, частые в реквизитах обработок/отчётов).
v8_platform_types = {"ValueTable", "ValueTree", "ValueList", "ValueListType", "StandardPeriod",
    "StandardBeginningDate", "PointInTime", "TypeDescription", "FixedArray", "FixedMap", "FixedStructure"}
# Типы со ВЫДЕЛЕННЫМ пространством имён (локальный xmlns на <v8:Type>). prefix — канон корпуса.
type_namespace_map = {
    "Chart":               {"ns": "http://v8.1c.ru/8.2/data/chart",                       "prefix": "d5p1"},
    "SettingsComposer":    {"ns": "http://v8.1c.ru/8.1/data-composition-system/settings",  "prefix": "dcsset"},
    "SpreadsheetDocument": {"ns": "http://v8.1c.ru/8.2/data/spreadsheet",                  "prefix": "mxl"},
}
# Типы current-config пространства (cfg:, объявлено в корне): голые и объектные. Ссылочные — отдельно (d5p1).
cfg_bare_types = {"ConstantsSet", "ReportBuilder", "FilterCriterion"}
cfg_object_kinds = {"Catalog", "Document", "Enum", "ChartOfAccounts", "ChartOfCharacteristicTypes",
    "ChartOfCalculationTypes", "ExchangePlan", "BusinessProcess", "Task", "InformationRegister",
    "AccumulationRegister", "AccountingRegister", "CalculationRegister", "DataProcessor", "Report",
    "DocumentJournal", "Constant", "ConstantValue", "Sequence", "Recalculation"}

def resolve_type_str(type_str):
    if not type_str:
        return type_str
    # Parameterized types: Number(15,2), Строка(100), etc.
    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = type_synonyms.get(base_name.lower())
        if resolved:
            return f'{resolved}({params})'
        return type_str
    # Reference types: СправочникСсылка.Организации -> CatalogRef.Организации
    if '.' in type_str:
        dot_idx = type_str.index('.')
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]  # includes the dot
        resolved = type_synonyms.get(prefix.lower())
        if resolved:
            return f'{resolved}{suffix}'
        return type_str
    # Simple name lookup
    resolved = type_synonyms.get(type_str.lower())
    if resolved:
        return resolved
    return type_str

def emit_type_content(indent, type_str):
    if not type_str:
        return
    # Composite type: "Type1 + Type2 + Type3"
    if ' + ' in type_str:
        parts = [p.strip() for p in type_str.split('+')]
        for part in parts:
            emit_type_content(indent, part)
        return
    type_str = resolve_type_str(type_str)
    # Boolean
    if type_str == 'Boolean':
        X(f'{indent}<v8:Type>xs:boolean</v8:Type>')
        return
    # String or String(N) or String(N,fixed|variable) — AllowedLength: Variable дефолт / Fixed (фикс. длина).
    m = re.match(r'^String(\((\d+)(\s*,\s*(fixed|variable))?\))?$', type_str)
    if m:
        length = m.group(2) if m.group(2) else '10'
        al = 'Fixed' if (m.group(4) and m.group(4).lower() == 'fixed') else 'Variable'
        X(f'{indent}<v8:Type>xs:string</v8:Type>')
        X(f'{indent}<v8:StringQualifiers>')
        X(f'{indent}\t<v8:Length>{length}</v8:Length>')
        X(f'{indent}\t<v8:AllowedLength>{al}</v8:AllowedLength>')
        X(f'{indent}</v8:StringQualifiers>')
        return
    # Number without params -> Number(10,0)
    if type_str == 'Number':
        X(f'{indent}<v8:Type>xs:decimal</v8:Type>')
        X(f'{indent}<v8:NumberQualifiers>')
        X(f'{indent}\t<v8:Digits>10</v8:Digits>')
        X(f'{indent}\t<v8:FractionDigits>0</v8:FractionDigits>')
        X(f'{indent}\t<v8:AllowedSign>Any</v8:AllowedSign>')
        X(f'{indent}</v8:NumberQualifiers>')
        return

    # Number(D,F) or Number(D,F,nonneg)
    m = re.match(r'^Number\((\d+),(\d+)(,nonneg)?\)$', type_str)
    if m:
        digits = m.group(1)
        fraction = m.group(2)
        sign = 'Nonnegative' if m.group(3) else 'Any'
        X(f'{indent}<v8:Type>xs:decimal</v8:Type>')
        X(f'{indent}<v8:NumberQualifiers>')
        X(f'{indent}\t<v8:Digits>{digits}</v8:Digits>')
        X(f'{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>')
        X(f'{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>')
        X(f'{indent}</v8:NumberQualifiers>')
        return
    # Date / DateTime / Time — общая структура xs:dateTime + DateFractions (различаются лишь составом).
    if type_str in ('Date', 'DateTime', 'Time'):
        X(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
        X(f'{indent}<v8:DateQualifiers>')
        X(f'{indent}\t<v8:DateFractions>{type_str}</v8:DateFractions>')
        X(f'{indent}</v8:DateQualifiers>')
        return
    # TypeSet — тип-множество: ОпределяемыйТип (DefinedType) ИЛИ Характеристика ПВХ (Characteristic).
    if re.match(r'^(DefinedType|Characteristic)\.(.+)$', type_str):
        X(f'{indent}<v8:TypeSet>cfg:{type_str}</v8:TypeSet>')
        return
    # Голый метатип-категория (CatalogRef/DocumentRef/…/AnyRef/AnyIBRef без имени объекта) — множество
    # «любой объект категории» → TypeSet (а не конкретный Type с именем).
    if re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef|AnyRef|AnyIBRef)$', type_str):
        X(f'{indent}<v8:TypeSet>cfg:{type_str}</v8:TypeSet>')
        return
    # ValueStorage (ХранилищеЗначения) — канон v8:ValueStorage (не xs:base64Binary).
    if type_str == 'ValueStorage':
        X(f'{indent}<v8:Type>v8:ValueStorage</v8:Type>')
        return
    # UUID (УникальныйИдентификатор)
    if type_str == 'UUID':
        X(f'{indent}<v8:Type>v8:UUID</v8:Type>')
        return
    # Платформенные типы-коллекции/периоды (ТаблицаЗначений/ДеревоЗначений/…) — канон с префиксом v8:.
    if type_str in v8_platform_types:
        X(f'{indent}<v8:Type>v8:{type_str}</v8:Type>')
        return
    # Типы с выделенным пространством имён (Chart/SettingsComposer/SpreadsheetDocument) — локальный xmlns.
    if type_str in type_namespace_map:
        m2 = type_namespace_map[type_str]
        X(f'{indent}<v8:Type xmlns:{m2["prefix"]}="{m2["ns"]}">{m2["prefix"]}:{type_str}</v8:Type>')
        return
    # Типы current-config (cfg:): голые (ConstantsSet/…) и объектные (CatalogObject.X/DataProcessorObject.X/…).
    if type_str in cfg_bare_types:
        X(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return
    m3 = re.match(r'^(\w+)(Object|List|Manager|Selection|RecordSet|RecordKey|RecordManager)\.(.+)$', type_str)
    if m3 and m3.group(1) in cfg_object_kinds:
        X(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return
    # Голый объектный метатип (без имени): Object/RecordSet + ConstantValueManager → «любой объект категории» = TypeSet cfg:;
    # прочие Manager/List/Selection → сам тип менеджера/списка = Type cfg: (напр. в Source подписки на событие).
    mbs = re.match(r'^(\w+)(Object|RecordSet)$', type_str)
    if (mbs and mbs.group(1) in cfg_object_kinds) or type_str == 'ConstantValueManager':
        X(f'{indent}<v8:TypeSet>cfg:{type_str}</v8:TypeSet>')
        return
    mbt = re.match(r'^(\w+)(Manager|List|Selection|RecordKey|RecordManager)$', type_str)
    if mbt and mbt.group(1) in cfg_object_kinds:
        X(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return

    # Reference types — use local xmlns declaration for 1C compatibility
    m = re.match(r'^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|BusinessProcessRoutePointRef|TaskRef)\.(.+)$', type_str)
    if m:
        X(f'{indent}<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:{type_str}</v8:Type>')
        return
    # Fallback
    X(f'{indent}<v8:Type>{type_str}</v8:Type>')

def emit_value_type(indent, type_str):
    X(f'{indent}<Type>')
    emit_type_content(f'{indent}\t', type_str)
    X(f'{indent}</Type>')

# --- FillValue (значение заполнения реквизита) ---
# Пара FillFromFillingValue+FillValue — единый блок «заполнения» (недоступен у реквизитов ТЧ).
# Форма пустого FillValue зависит от типа реквизита (то же значение по умолчанию, что и «пустое»
# значение типа): String→typed-empty, Number→0, всё остальное (Boolean/Date/Ref/составной/TypeSet)→nil.
# Реальное значение задаётся ключом `fillValue` (интерпретация по типу реквизита; см. §4.2 spec).

def get_fill_type_category(type_str):
    if not type_str:
        return 'String'          # реквизит без типа → неквалифиц. строка
    if '+' in type_str:
        return 'Other'           # составной тип → nil-дефолт
    t = resolve_type_str(type_str)
    if re.match(r'^Boolean$', t):
        return 'Boolean'
    if re.match(r'^String(\(|$)', t):
        return 'String'
    if re.match(r'^Number(\(|$)', t):
        return 'Number'
    if re.match(r'^(Date|DateTime)$', t):
        return 'Date'
    return 'Other'               # ссылки, TypeSet, ValueStorage, … → nil-дефолт

# Прощающий ввод для ссылочных путей DTR: рус/англ корни, ПустаяСсылка/EmptyRef, ЗначениеПеречисления/EnumValue.
fill_ref_roots = {
    'перечисление': 'Enum', 'справочник': 'Catalog', 'документ': 'Document',
    'плансчетов': 'ChartOfAccounts', 'планвидовхарактеристик': 'ChartOfCharacteristicTypes',
    'планвидоврасчета': 'ChartOfCalculationTypes', 'планвидоврасчёта': 'ChartOfCalculationTypes',
    'планобмена': 'ExchangePlan', 'бизнеспроцесс': 'BusinessProcess', 'задача': 'Task',
    'enum': 'Enum', 'catalog': 'Catalog', 'document': 'Document', 'chartofaccounts': 'ChartOfAccounts',
    'chartofcharacteristictypes': 'ChartOfCharacteristicTypes', 'chartofcalculationtypes': 'ChartOfCalculationTypes',
    'exchangeplan': 'ExchangePlan', 'businessprocess': 'BusinessProcess', 'task': 'Task',
}
fill_empty_ref_words = ('emptyref', 'пустаяссылка')
fill_enum_val_words = ('enumvalue', 'значениеперечисления')
fill_bool_true = ('true', 'истина', 'да')
fill_bool_false = ('false', 'ложь', 'нет')
# Прощающий ввод MDObjectRef-путей (Location/Content функц. опции): русские корни метаданных + подвиды →
# английские. Виды на ЧЁТНЫХ позициях (0,2,4…); имена (нечётные) не трогаем. Английские пути неизменны.
md_ref_roots = {
    'справочник': 'Catalog', 'документ': 'Document', 'перечисление': 'Enum', 'константа': 'Constant',
    'регистрсведений': 'InformationRegister', 'регистрнакопления': 'AccumulationRegister',
    'регистрбухгалтерии': 'AccountingRegister', 'регистррасчета': 'CalculationRegister', 'регистррасчёта': 'CalculationRegister',
    'плансчетов': 'ChartOfAccounts', 'планвидовхарактеристик': 'ChartOfCharacteristicTypes',
    'планвидоврасчета': 'ChartOfCalculationTypes', 'планвидоврасчёта': 'ChartOfCalculationTypes',
    'планобмена': 'ExchangePlan', 'бизнеспроцесс': 'BusinessProcess', 'задача': 'Task',
    'журналдокументов': 'DocumentJournal', 'отчет': 'Report', 'отчёт': 'Report', 'обработка': 'DataProcessor',
    'табличнаячасть': 'TabularSection', 'реквизит': 'Attribute', 'измерение': 'Dimension', 'ресурс': 'Resource',
    'стандартныйреквизит': 'StandardAttribute', 'значениеперечисления': 'EnumValue', 'команда': 'Command',
    'признакучета': 'AccountingFlag', 'признакучёта': 'AccountingFlag',
}

def normalize_md_object_ref(ref):
    if not ref or '.' not in ref:
        return ref
    parts = ref.split('.')
    for k in range(0, len(parts), 2):
        t = md_ref_roots.get(parts[k].lower())
        if t:
            parts[k] = t
    return '.'.join(parts)
# Значения платформенного перечисления ВидСчета (ent:AccountType) — FillValue реквизита Тип у Плана счетов.
ACCOUNT_TYPE_VALUES = ('Active', 'Passive', 'ActivePassive')
# «Только обороты» (<Turnover>) — предопределённый признак учёта субконто; токен в списке flags наравне с добавленными.
SUBCONTO_TURNOVER_TOKENS = ('turnover', 'толькообороты', 'только обороты', 'оборотный')
# XxxRef (тип реквизита) → корень DTR-пути (для разворота короткой записи значения).
fill_ref_kind_root = {
    'catalogref': 'Catalog', 'documentref': 'Document', 'enumref': 'Enum',
    'chartofaccountsref': 'ChartOfAccounts', 'chartofcharacteristictypesref': 'ChartOfCharacteristicTypes',
    'chartofcalculationtypesref': 'ChartOfCalculationTypes', 'exchangeplanref': 'ExchangePlan',
    'businessprocessref': 'BusinessProcess', 'taskref': 'Task',
}

def normalize_fill_ref(s):
    """Строка → нормализованный DTR-путь ЛИБО None (не ссылка)."""
    if not s:
        return None
    if re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F-]+$', s):
        return s
    parts = s.split('.')
    if len(parts) < 2:
        return None
    root = fill_ref_roots.get(parts[0].lower())
    if not root:
        return None
    type_name = parts[1]
    if root == 'Enum':
        if len(parts) == 2:
            return None
        if len(parts) == 3:
            if parts[2].lower() in fill_empty_ref_words:
                return f'Enum.{type_name}.EmptyRef'
            return f'Enum.{type_name}.EnumValue.{parts[2]}'
        if parts[2].lower() in fill_enum_val_words:
            rest = '.'.join(parts[3:])
        else:
            rest = '.'.join(parts[2:])
        return f'Enum.{type_name}.EnumValue.{rest}'
    tail = list(parts[1:])
    for i in range(len(tail)):
        if tail[i].lower() in fill_empty_ref_words:
            tail[i] = 'EmptyRef'
    return f'{root}.' + '.'.join(tail)

def expand_fill_short_ref(s, type_str):
    """Короткая запись значения ссылочного реквизита (без точки) → полный DTR-путь по типу, либо None."""
    if not type_str:
        return None
    if '+' in type_str:          # составной тип — короткая форма неоднозначна
        return None
    t = resolve_type_str(type_str)
    m = re.match(r'^(\w+Ref)\.(.+)$', t)
    if not m:
        return None
    root = fill_ref_kind_root.get(m.group(1).lower())
    if not root:
        return None
    type_name = m.group(2)
    if s.lower() in fill_empty_ref_words:
        return f'{root}.{type_name}.EmptyRef'
    if root == 'Enum':
        return f'Enum.{type_name}.EnumValue.{s}'
    return f'{root}.{type_name}.{s}'

def resolve_fill_value_spec(s, type_str):
    """Строковый spec → (xsi_type, text). Интерпретация по типу реквизита."""
    cat = get_fill_type_category(type_str)
    if s == '':
        return ('xs:string', '')
    if cat == 'String':
        return ('xs:string', s)
    if cat == 'Boolean' or s.lower() in fill_bool_true or s.lower() in fill_bool_false:
        if s.lower() in fill_bool_true:
            return ('xs:boolean', 'true')
        if s.lower() in fill_bool_false:
            return ('xs:boolean', 'false')
    if cat == 'Number':
        return ('xs:decimal', s)
    if cat == 'Date' or re.match(r'^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$', s):
        if re.match(r'^\d{4}-\d{2}-\d{2}$', s):
            s = f'{s}T00:00:00'
        return ('xs:dateTime', s)
    ref = normalize_fill_ref(s)
    if ref:
        return ('xr:DesignTimeRef', ref)
    short = expand_fill_short_ref(s, type_str)
    if short:
        return ('xr:DesignTimeRef', short)
    return ('xs:string', s)

def format_fill_num(n):
    if isinstance(n, bool):
        return 'true' if n else 'false'
    return str(n)

def emit_fill_value(indent, type_str, spec, has_spec, type_empty=False):
    """spec — значение ключа fillValue (None при явном nil-override), has_spec — присутствует ли ключ.
    type_empty — реквизит с пустым <Type/>: форма пустого значения nil, НЕ xs:string."""
    cat = 'Other' if type_empty else get_fill_type_category(type_str)
    if not has_spec:
        if cat == 'String':
            X(f'{indent}<FillValue xsi:type="xs:string"/>')
        elif cat == 'Number':
            X(f'{indent}<FillValue xsi:type="xs:decimal">0</FillValue>')
        else:
            X(f'{indent}<FillValue xsi:nil="true"/>')
        return
    if spec is None:
        X(f'{indent}<FillValue xsi:nil="true"/>')       # явный nil-override
        return
    if isinstance(spec, dict) and spec.get('nil') is True:
        X(f'{indent}<FillValue xsi:nil="true"/>')       # явный nil на типизированном (маркер декомпилятора)
        return
    if isinstance(spec, dict) and spec.get('emptyRef') is True:
        X(f'{indent}<FillValue xsi:type="xr:DesignTimeRef"/>')  # пустая ссылка (маркер декомпилятора)
        return
    if isinstance(spec, bool):
        X(f'{indent}<FillValue xsi:type="xs:boolean">{"true" if spec else "false"}</FillValue>')
        return
    if isinstance(spec, (int, float)):
        X(f'{indent}<FillValue xsi:type="xs:decimal">{format_fill_num(spec)}</FillValue>')
        return
    xsi_type, text = resolve_fill_value_spec(str(spec), type_str)
    if text == '' and xsi_type == 'xs:string':
        X(f'{indent}<FillValue xsi:type="xs:string"/>')
        return
    X(f'{indent}<FillValue xsi:type="{xsi_type}">{esc_xml_text(text)}</FillValue>')

# ---------------------------------------------------------------------------
# 5. Attribute shorthand parser
# ---------------------------------------------------------------------------

def build_type_str(obj):
    t = str(obj.get('valueType') or obj.get('type') or '')
    if t and '(' not in t:
        if t == 'String' and obj.get('length'):
            t = f"String({obj['length']})"
        elif t == 'Number' and obj.get('length'):
            prec = obj.get('precision', 0)
            nn = ',nonneg' if obj.get('nonneg') or obj.get('nonnegative') else ''
            t = f"Number({obj['length']},{prec}{nn})"
    return t

def parse_attribute_shorthand(val):
    if isinstance(val, str):
        parsed = {
            'name': '',
            'type': '',
            'typeEmpty': False,
            'synonym': '',
            'comment': '',
            'flags': [],
            'fillChecking': '',
            'indexing': '',
            'hasFillValue': False,
            'fillValue': None,
        }
        parts = val.split('|', 1)
        main_part = parts[0].strip()
        if len(parts) > 1:
            flag_str = parts[1].strip()
            parsed['flags'] = [f.strip().lower() for f in flag_str.split(',') if f.strip()]
        colon_parts = main_part.split(':', 1)
        parsed['name'] = colon_parts[0].strip()
        if len(colon_parts) > 1:
            parsed['type'] = colon_parts[1].strip()
        parsed['synonym'] = split_camel_case(parsed['name'])
        return parsed
    # Object form. synonym/tooltip — сквозной проброс (строка ИЛИ dict {ru,en}), НЕ стрингифаим.
    name = str(val.get('name', ''))
    # fillCheck — синоним fillChecking (bool true→ShowError). quickChoice — прощаем bool (true→Use, false→DontUse).
    if val.get('fillChecking'):
        fc = str(val['fillChecking'])
    elif val.get('fillCheck') is not None:
        fc = ('ShowError' if val['fillCheck'] else '') if isinstance(val['fillCheck'], bool) else str(val['fillCheck'])
    else:
        fc = ''
    if val.get('quickChoice') is not None:
        qc = ('Use' if val['quickChoice'] else 'DontUse') if isinstance(val['quickChoice'], bool) else str(val['quickChoice'])
    else:
        qc = ''
    return {
        'name': name,
        'type': build_type_str(val),
        # Явный `type: ""` (ключ есть, значение пустое) ≠ отсутствие: пустой <Type/> (реквизит без типа).
        'typeEmpty': ('type' in val and str(val.get('type') or '').strip() == '' and not val.get('valueType')),
        'synonym': val['synonym'] if val.get('synonym') is not None else split_camel_case(name),
        'tooltip': val.get('tooltip'),
        'comment': str(val['comment']) if val.get('comment') else '',
        # Лоуэркейз как в строковом пути (стр.809): проверки флагов регистронезависимы (зеркало PS -contains).
        'flags': [str(f).strip().lower() for f in val.get('flags', [])],
        'fillChecking': fc,
        'indexing': str(val['indexing']) if val.get('indexing') else '',
        'multiLine': True if val.get('multiLine') is True else False,
        'choiceHistoryOnInput': str(val['choiceHistoryOnInput']) if val.get('choiceHistoryOnInput') else '',
        'fullTextSearch': str(val['fullTextSearch']) if val.get('fullTextSearch') else '',
        'fillFromFillingValue': True if val.get('fillFromFillingValue') is True else False,
        'createOnInput': str(val['createOnInput']) if val.get('createOnInput') else '',
        'quickChoice': qc,
        'dataHistory': str(val['dataHistory']) if val.get('dataHistory') else '',
        'use': str(val['use']) if val.get('use') else '',
        'passwordMode': True if val.get('passwordMode') is True else False,
        'format': val.get('format'),
        'editFormat': val.get('editFormat'),
        'mask': str(val['mask']) if val.get('mask') else '',
        'extendedEdit': True if val.get('extendedEdit') is True else False,
        'markNegatives': True if val.get('markNegatives') is True else False,
        'choiceForm': str(val['choiceForm']) if val.get('choiceForm') else '',
        'choiceFoldersAndItems': str(val['choiceFoldersAndItems']) if val.get('choiceFoldersAndItems') else '',
        'minValue': val.get('minValue'),
        'maxValue': val.get('maxValue'),
        'hasFillValue': ('fillValue' in val),
        'fillValue': val.get('fillValue'),
        'linkByType': val.get('linkByType'),
        'choiceParameterLinks': val.get('choiceParameterLinks'),
        'choiceParameters': val.get('choiceParameters'),
        'master': val.get('master') is True,
        'mainFilter': val.get('mainFilter') is True,
        'denyIncompleteValues': val.get('denyIncompleteValues') is True,
        'useInTotals': (val.get('useInTotals') is True) if val.get('useInTotals') is not None else True,
        'baseDimension': val.get('baseDimension') is True,
        'scheduleLink': val.get('scheduleLink'),
        'balance': val.get('balance') is True,
        'accountingFlag': val.get('accountingFlag'),
        'extDimensionAccountingFlag': val.get('extDimensionAccountingFlag'),
        'addressingDimension': val.get('addressingDimension'),
    }

def parse_enum_value_shorthand(val):
    if isinstance(val, str):
        return {
            'name': val,
            'synonym': split_camel_case(val),
            'comment': '',
        }
    name = str(val.get('name', ''))
    return {
        'name': name,
        # строка ИЛИ {ru,en} → emit_mltext; None → авто из имени
        'synonym': val['synonym'] if val.get('synonym') is not None else split_camel_case(name),
        'comment': str(val['comment']) if val.get('comment') else '',
    }

# ---------------------------------------------------------------------------
# 6. GeneratedType categories
# ---------------------------------------------------------------------------

generated_types = {
    'Catalog': [
        {'prefix': 'CatalogObject', 'category': 'Object'},
        {'prefix': 'CatalogRef', 'category': 'Ref'},
        {'prefix': 'CatalogSelection', 'category': 'Selection'},
        {'prefix': 'CatalogList', 'category': 'List'},
        {'prefix': 'CatalogManager', 'category': 'Manager'},
    ],
    'Document': [
        {'prefix': 'DocumentObject', 'category': 'Object'},
        {'prefix': 'DocumentRef', 'category': 'Ref'},
        {'prefix': 'DocumentSelection', 'category': 'Selection'},
        {'prefix': 'DocumentList', 'category': 'List'},
        {'prefix': 'DocumentManager', 'category': 'Manager'},
    ],
    'Enum': [
        {'prefix': 'EnumRef', 'category': 'Ref'},
        {'prefix': 'EnumManager', 'category': 'Manager'},
        {'prefix': 'EnumList', 'category': 'List'},
    ],
    'Constant': [
        {'prefix': 'ConstantManager', 'category': 'Manager'},
        {'prefix': 'ConstantValueManager', 'category': 'ValueManager'},
        {'prefix': 'ConstantValueKey', 'category': 'ValueKey'},
    ],
    'InformationRegister': [
        {'prefix': 'InformationRegisterRecord', 'category': 'Record'},
        {'prefix': 'InformationRegisterManager', 'category': 'Manager'},
        {'prefix': 'InformationRegisterSelection', 'category': 'Selection'},
        {'prefix': 'InformationRegisterList', 'category': 'List'},
        {'prefix': 'InformationRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'InformationRegisterRecordKey', 'category': 'RecordKey'},
        {'prefix': 'InformationRegisterRecordManager', 'category': 'RecordManager'},
    ],
    'AccumulationRegister': [
        {'prefix': 'AccumulationRegisterRecord', 'category': 'Record'},
        {'prefix': 'AccumulationRegisterManager', 'category': 'Manager'},
        {'prefix': 'AccumulationRegisterSelection', 'category': 'Selection'},
        {'prefix': 'AccumulationRegisterList', 'category': 'List'},
        {'prefix': 'AccumulationRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'AccumulationRegisterRecordKey', 'category': 'RecordKey'},
    ],
    'AccountingRegister': [
        {'prefix': 'AccountingRegisterRecord', 'category': 'Record'},
        {'prefix': 'AccountingRegisterExtDimensions', 'category': 'ExtDimensions'},
        {'prefix': 'AccountingRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'AccountingRegisterRecordKey', 'category': 'RecordKey'},
        {'prefix': 'AccountingRegisterSelection', 'category': 'Selection'},
        {'prefix': 'AccountingRegisterList', 'category': 'List'},
        {'prefix': 'AccountingRegisterManager', 'category': 'Manager'},
    ],
    'CalculationRegister': [
        {'prefix': 'CalculationRegisterRecord', 'category': 'Record'},
        {'prefix': 'CalculationRegisterManager', 'category': 'Manager'},
        {'prefix': 'CalculationRegisterSelection', 'category': 'Selection'},
        {'prefix': 'CalculationRegisterList', 'category': 'List'},
        {'prefix': 'CalculationRegisterRecordSet', 'category': 'RecordSet'},
        {'prefix': 'CalculationRegisterRecordKey', 'category': 'RecordKey'},
        {'prefix': 'RecalculationsManager', 'category': 'Recalcs'},
    ],
    'ChartOfAccounts': [
        {'prefix': 'ChartOfAccountsObject', 'category': 'Object'},
        {'prefix': 'ChartOfAccountsRef', 'category': 'Ref'},
        {'prefix': 'ChartOfAccountsSelection', 'category': 'Selection'},
        {'prefix': 'ChartOfAccountsList', 'category': 'List'},
        {'prefix': 'ChartOfAccountsManager', 'category': 'Manager'},
        {'prefix': 'ChartOfAccountsExtDimensionTypes', 'category': 'ExtDimensionTypes'},
        {'prefix': 'ChartOfAccountsExtDimensionTypesRow', 'category': 'ExtDimensionTypesRow'},
    ],
    'ChartOfCharacteristicTypes': [
        {'prefix': 'ChartOfCharacteristicTypesObject', 'category': 'Object'},
        {'prefix': 'ChartOfCharacteristicTypesRef', 'category': 'Ref'},
        {'prefix': 'ChartOfCharacteristicTypesSelection', 'category': 'Selection'},
        {'prefix': 'ChartOfCharacteristicTypesList', 'category': 'List'},
        {'prefix': 'Characteristic', 'category': 'Characteristic'},
        {'prefix': 'ChartOfCharacteristicTypesManager', 'category': 'Manager'},
    ],
    'ChartOfCalculationTypes': [
        {'prefix': 'ChartOfCalculationTypesObject', 'category': 'Object'},
        {'prefix': 'ChartOfCalculationTypesRef', 'category': 'Ref'},
        {'prefix': 'ChartOfCalculationTypesSelection', 'category': 'Selection'},
        {'prefix': 'ChartOfCalculationTypesList', 'category': 'List'},
        {'prefix': 'ChartOfCalculationTypesManager', 'category': 'Manager'},
        {'prefix': 'DisplacingCalculationTypes', 'category': 'DisplacingCalculationTypes'},
        {'prefix': 'DisplacingCalculationTypesRow', 'category': 'DisplacingCalculationTypesRow'},
        {'prefix': 'BaseCalculationTypes', 'category': 'BaseCalculationTypes'},
        {'prefix': 'BaseCalculationTypesRow', 'category': 'BaseCalculationTypesRow'},
        {'prefix': 'LeadingCalculationTypes', 'category': 'LeadingCalculationTypes'},
        {'prefix': 'LeadingCalculationTypesRow', 'category': 'LeadingCalculationTypesRow'},
    ],
    'BusinessProcess': [
        {'prefix': 'BusinessProcessObject', 'category': 'Object'},
        {'prefix': 'BusinessProcessRef', 'category': 'Ref'},
        {'prefix': 'BusinessProcessSelection', 'category': 'Selection'},
        {'prefix': 'BusinessProcessList', 'category': 'List'},
        {'prefix': 'BusinessProcessManager', 'category': 'Manager'},
        {'prefix': 'BusinessProcessRoutePointRef', 'category': 'RoutePointRef'},
    ],
    'Task': [
        {'prefix': 'TaskObject', 'category': 'Object'},
        {'prefix': 'TaskRef', 'category': 'Ref'},
        {'prefix': 'TaskSelection', 'category': 'Selection'},
        {'prefix': 'TaskList', 'category': 'List'},
        {'prefix': 'TaskManager', 'category': 'Manager'},
    ],
    'ExchangePlan': [
        {'prefix': 'ExchangePlanObject', 'category': 'Object'},
        {'prefix': 'ExchangePlanRef', 'category': 'Ref'},
        {'prefix': 'ExchangePlanSelection', 'category': 'Selection'},
        {'prefix': 'ExchangePlanList', 'category': 'List'},
        {'prefix': 'ExchangePlanManager', 'category': 'Manager'},
    ],
    'DefinedType': [
        {'prefix': 'DefinedType', 'category': 'DefinedType'},
    ],
    'DocumentJournal': [
        {'prefix': 'DocumentJournalSelection', 'category': 'Selection'},
        {'prefix': 'DocumentJournalList', 'category': 'List'},
        {'prefix': 'DocumentJournalManager', 'category': 'Manager'},
    ],
    'Report': [
        {'prefix': 'ReportObject', 'category': 'Object'},
        {'prefix': 'ReportManager', 'category': 'Manager'},
    ],
    'DataProcessor': [
        {'prefix': 'DataProcessorObject', 'category': 'Object'},
        {'prefix': 'DataProcessorManager', 'category': 'Manager'},
    ],
    'Sequence': [
        {'prefix': 'SequenceRecord', 'category': 'Record'},
        {'prefix': 'SequenceManager', 'category': 'Manager'},
        {'prefix': 'SequenceRecordSet', 'category': 'RecordSet'},
    ],
    'FilterCriterion': [
        {'prefix': 'FilterCriterionManager', 'category': 'Manager'},
        {'prefix': 'FilterCriterionList', 'category': 'List'},
    ],
    'SettingsStorage': [
        {'prefix': 'SettingsStorageManager', 'category': 'Manager'},
    ],
    'WSReference': [
        {'prefix': 'WSReferenceManager', 'category': 'Manager'},
    ],
}

def emit_internal_info(indent, object_type, object_name):
    types = generated_types.get(object_type)
    if not types:
        return
    X(f'{indent}<InternalInfo>')
    if object_type == 'ExchangePlan':
        X(f'{indent}\t<xr:ThisNode>{new_uuid()}</xr:ThisNode>')
    for gt in types:
        full_name = f"{gt['prefix']}.{object_name}"
        X(f'{indent}\t<xr:GeneratedType name="{full_name}" category="{gt["category"]}">')
        X(f'{indent}\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
        X(f'{indent}\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
        X(f'{indent}\t</xr:GeneratedType>')
    X(f'{indent}</InternalInfo>')

# ---------------------------------------------------------------------------
# 7. StandardAttributes
# ---------------------------------------------------------------------------

standard_attributes_by_type = {
    'Catalog': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'IsFolder', 'Owner', 'Parent', 'Description', 'Code'],
    'Document': ['Posted', 'Ref', 'DeletionMark', 'Date', 'Number'],
    'Enum': ['Order', 'Ref'],
    'InformationRegister': ['Active', 'LineNumber', 'Recorder', 'Period'],
    'AccumulationRegister': ['Active', 'LineNumber', 'Recorder', 'Period'],
    'AccountingRegister': ['Active', 'Period', 'Recorder', 'LineNumber', 'Account'],
    'CalculationRegister': ['Active', 'Recorder', 'LineNumber', 'RegistrationPeriod', 'CalculationType', 'ReversingEntry'],
    'ChartOfAccounts': ['PredefinedDataName', 'Order', 'OffBalance', 'Type', 'Description', 'Code', 'Parent', 'Predefined', 'DeletionMark', 'Ref'],
    'ChartOfCharacteristicTypes': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'Description', 'Code', 'Parent', 'ValueType'],
    'ChartOfCalculationTypes': ['PredefinedDataName', 'Predefined', 'Ref', 'DeletionMark', 'ActionPeriodIsBasic', 'Description', 'Code'],
    'BusinessProcess': ['Ref', 'DeletionMark', 'Date', 'Number', 'Started', 'Completed', 'HeadTask'],
    'Task': ['Ref', 'DeletionMark', 'Date', 'Number', 'Executed', 'Description', 'RoutePoint', 'BusinessProcess'],
    'ExchangePlan': ['Ref', 'DeletionMark', 'Code', 'Description', 'ThisNode', 'SentNo', 'ReceivedNo'],
    'DocumentJournal': ['Type', 'Ref', 'Date', 'Posted', 'DeletionMark', 'Number'],
}

# Профиль материализованного блока StandardAttributes (см. коммент в .ps1). Пока только Catalog.
std_attr_profile = {
    'Catalog': {
        'Owner': {'FillChecking': 'ShowError', 'FillFromFillingValue': 'true'},
        'Parent': {'FillFromFillingValue': 'true'},
        'Description': {'FillChecking': 'ShowError'},
    },
    # ExchangePlan: блок при кастомизации; Наименование/Код → FillChecking=ShowError (корпус 40/38 из 41).
    'ExchangePlan': {
        'Description': {'FillChecking': 'ShowError'},
        'Code': {'FillChecking': 'ShowError'},
    },
    # ChartOfCharacteristicTypes: Наименование → FillChecking=ShowError (21/23), Родитель → FFV=true (23/23).
    'ChartOfCharacteristicTypes': {
        'Description': {'FillChecking': 'ShowError'},
        'Parent': {'FillFromFillingValue': 'true'},
    },
    # ChartOfAccounts: Наименование/Код → FillChecking=ShowError (3/3), Родитель → FFV=true (3/3).
    'ChartOfAccounts': {
        'Description': {'FillChecking': 'ShowError'},
        'Code': {'FillChecking': 'ShowError'},
        'Parent': {'FillFromFillingValue': 'true'},
    },
    # ChartOfCalculationTypes: Наименование → FillChecking=ShowError (Код здесь DontCheck).
    'ChartOfCalculationTypes': {
        'Description': {'FillChecking': 'ShowError'},
    },
    # Document: Дата → FillChecking=ShowError (974/1010 доков acc+erp; дата обязательна).
    'Document': {
        'Date': {'FillChecking': 'ShowError'},
    },
}

# ov — dict переопределений (профиль + DSL): FillChecking, FillFromFillingValue, Synonym,
# FullTextSearch, DataHistory. Прочие поля — фиксированный schema-дефолт.
def emit_standard_attribute(indent, attr_name, ov=None):
    ov = ov or {}
    fc = ov.get('FillChecking', 'DontCheck')
    ffv = ov.get('FillFromFillingValue', 'false')
    dh = ov.get('DataHistory', 'Use')
    fts = ov.get('FullTextSearch', 'Use')
    syn = ov.get('Synonym', '')
    tt = ov.get('ToolTip', '')
    cf = ov.get('ChoiceForm', '')
    cmt = ov.get('Comment', '')
    msk = ov.get('Mask', '')
    fmt = ov.get('Format')
    efmt = ov.get('EditFormat')
    chi = ov.get('ChoiceHistoryOnInput', 'Auto')
    X(f'{indent}<xr:StandardAttribute name="{attr_name}">')
    # LinkByType стандартного реквизита (напр. ExtDimensionN→Account у регистра бухгалтерии). DataPath verbatim.
    lbt = ov.get('LinkByType')
    if lbt:
        lbt_dp = str(lbt.get('dataPath')) if isinstance(lbt, dict) else str(lbt)
        lbt_li = lbt.get('linkItem', 0) if isinstance(lbt, dict) else 0
        X(f'{indent}\t<xr:LinkByType>')
        X(f'{indent}\t\t<xr:DataPath>{esc_xml(lbt_dp)}</xr:DataPath>')
        X(f'{indent}\t\t<xr:LinkItem>{lbt_li}</xr:LinkItem>')
        X(f'{indent}\t</xr:LinkByType>')
    else:
        X(f'{indent}\t<xr:LinkByType/>')
    X(f'{indent}\t<xr:FillChecking>{fc}</xr:FillChecking>')
    X(f'{indent}\t<xr:MultiLine>false</xr:MultiLine>')
    X(f'{indent}\t<xr:FillFromFillingValue>{ffv}</xr:FillFromFillingValue>')
    X(f'{indent}\t<xr:CreateOnInput>Auto</xr:CreateOnInput>')
    X(f'{indent}\t<xr:MaxValue xsi:nil="true"/>')
    emit_mltext(f'{indent}\t', 'xr:ToolTip', tt)
    X(f'{indent}\t<xr:ExtendedEdit>false</xr:ExtendedEdit>')
    emit_mltext(f'{indent}\t', 'xr:Format', fmt)
    if cf:
        X(f'{indent}\t<xr:ChoiceForm>{esc_xml(str(cf))}</xr:ChoiceForm>')
    else:
        X(f'{indent}\t<xr:ChoiceForm/>')
    X(f'{indent}\t<xr:QuickChoice>Auto</xr:QuickChoice>')
    X(f'{indent}\t<xr:ChoiceHistoryOnInput>{chi}</xr:ChoiceHistoryOnInput>')
    emit_mltext(f'{indent}\t', 'xr:EditFormat', efmt)
    X(f'{indent}\t<xr:PasswordMode>false</xr:PasswordMode>')
    X(f'{indent}\t<xr:DataHistory>{dh}</xr:DataHistory>')
    X(f'{indent}\t<xr:MarkNegatives>false</xr:MarkNegatives>')
    X(f'{indent}\t<xr:MinValue xsi:nil="true"/>')
    emit_mltext(f'{indent}\t', 'xr:Synonym', syn)
    if cmt:
        X(f'{indent}\t<xr:Comment>{esc_xml_text(str(cmt))}</xr:Comment>')
    else:
        X(f'{indent}\t<xr:Comment/>')
    X(f'{indent}\t<xr:FullTextSearch>{fts}</xr:FullTextSearch>')
    emit_choice_parameter_links(f'{indent}\t', ov.get('ChoiceParameterLinks'), 'xr:ChoiceParameterLinks')
    fv_raw = ov.get('FillValue', None)
    if fv_raw is None:
        X(f'{indent}\t<xr:FillValue xsi:nil="true"/>')
    elif isinstance(fv_raw, dict) and fv_raw.get('emptyRef') is True:
        X(f'{indent}\t<xr:FillValue xsi:type="xr:DesignTimeRef"/>')
    elif isinstance(fv_raw, dict) and fv_raw.get('typeDescription') is True:
        X(f'{indent}\t<xr:FillValue xsi:type="v8:TypeDescription"/>')   # пустое типизированное (ValueType ПВХ)
    else:
        fv_xt, fv_tx = normalize_choice_value(fv_raw)
        if fv_tx == '' or fv_tx is None:
            X(f'{indent}\t<xr:FillValue xsi:type="{fv_xt}"/>')
        else:
            X(f'{indent}\t<xr:FillValue xsi:type="{fv_xt}">{esc_xml(fv_tx)}</xr:FillValue>')
    if msk:
        X(f'{indent}\t<xr:Mask>{esc_xml_text(str(msk))}</xr:Mask>')
    else:
        X(f'{indent}\t<xr:Mask/>')
    emit_choice_parameters(f'{indent}\t', ov.get('ChoiceParameters'), 'xr:ChoiceParameters')
    X(f'{indent}</xr:StandardAttribute>')

# Единый эмиттер блока StandardAttributes — поведение правят ДАННЫЕ, не форк кода (см. коммент в .ps1).
# std_attr_conditional_types: типы, где блок только при кастомизации (DSL-ключ standardAttributes).
# Прочие типы → блок всегда (текущее поведение). Миграция типа = +строчка в оба справочника + снэпшоты.
std_attr_conditional_types = {'Catalog', 'ExchangePlan', 'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes', 'Document'}
def emit_standard_attributes(indent, object_type):
    attrs = standard_attributes_by_type.get(object_type)
    if not attrs:
        return
    conditional = object_type in std_attr_conditional_types
    sa = defn.get('standardAttributes')
    if conditional and sa is None:
        return
    if isinstance(sa, str) and sa == '':
        return  # opt-out `standardAttributes:""` (дом-конвенция суппресса, ~5% регистров опускают all-default блок)
    profile = std_attr_profile.get(object_type, {})
    # Доп. (опциональные) стандартные реквизиты вне фикс-списка — напр. ExchangeDate у части ПланОбмена
    # (легаси, присутствие не выводится). Эмитим по факту ключа в DSL, ПЕРЕД фикс-списком (их позиция).
    extra = [k for k in sa if k not in attrs] if isinstance(sa, dict) else []
    X(f'{indent}<StandardAttributes>')
    for a in extra + list(attrs):
        ov = dict(profile.get(a, {}))
        if isinstance(sa, dict):
            d = sa.get(a)
            if d:
                if d.get('synonym') is not None:
                    ov['Synonym'] = d['synonym']   # строка ИЛИ {ru,en}
                if d.get('tooltip') is not None:
                    ov['ToolTip'] = d['tooltip']   # строка ИЛИ {ru,en}
                if d.get('fillChecking'):
                    ov['FillChecking'] = str(d['fillChecking'])
                if d.get('fillFromFillingValue') is not None:
                    ov['FillFromFillingValue'] = 'true' if d['fillFromFillingValue'] else 'false'
                if d.get('fullTextSearch'):
                    ov['FullTextSearch'] = str(d['fullTextSearch'])
                if d.get('dataHistory'):
                    ov['DataHistory'] = str(d['dataHistory'])
                if d.get('fillValue') is not None:
                    ov['FillValue'] = d['fillValue']
                if d.get('choiceParameterLinks') is not None:
                    ov['ChoiceParameterLinks'] = d['choiceParameterLinks']
                if d.get('choiceParameters') is not None:
                    ov['ChoiceParameters'] = d['choiceParameters']
                if d.get('comment'):
                    ov['Comment'] = str(d['comment'])
                if d.get('mask'):
                    ov['Mask'] = str(d['mask'])
                if d.get('format') is not None:
                    ov['Format'] = d['format']         # строка ИЛИ {ru,en}
                if d.get('editFormat') is not None:
                    ov['EditFormat'] = d['editFormat']
                if d.get('choiceForm'):
                    ov['ChoiceForm'] = str(d['choiceForm'])
                if d.get('linkByType') is not None:
                    ov['LinkByType'] = d['linkByType']
        emit_standard_attribute(f'{indent}\t', a, ov)
    X(f'{indent}</StandardAttributes>')

def emit_tabular_standard_attributes(indent, line_number=None):
    """LineNumber/НомерСтроки ТЧ. Блок эмитится всегда. DSL `lineNumber` переопределяет
    synonym/comment/fullTextSearch/tooltip/format/editFormat/choiceHistoryOnInput."""
    ov = None
    if line_number:
        ov = {}
        if line_number.get('synonym') is not None:
            ov['Synonym'] = line_number['synonym']
        if line_number.get('comment'):
            ov['Comment'] = str(line_number['comment'])
        if line_number.get('fullTextSearch'):
            ov['FullTextSearch'] = str(line_number['fullTextSearch'])
        if line_number.get('tooltip') is not None:
            ov['ToolTip'] = line_number['tooltip']
        if line_number.get('format') is not None:
            ov['Format'] = line_number['format']
        if line_number.get('editFormat') is not None:
            ov['EditFormat'] = line_number['editFormat']
        if line_number.get('choiceHistoryOnInput'):
            ov['ChoiceHistoryOnInput'] = str(line_number['choiceHistoryOnInput'])
        if line_number.get('fillValue') is not None:
            ov['FillValue'] = line_number['fillValue']
    X(f'{indent}<StandardAttributes>')
    emit_standard_attribute(f'{indent}\t', 'LineNumber', ov)
    X(f'{indent}</StandardAttributes>')

# ---------------------------------------------------------------------------
# 8. Attribute emitter
# ---------------------------------------------------------------------------

RESERVED_ATTR_NAMES = {
    'Ref', 'DeletionMark', 'Code', 'Description', 'Date', 'Number', 'Posted',
    'Parent', 'Owner', 'IsFolder', 'Predefined', 'PredefinedDataName',
    'Recorder', 'Period', 'LineNumber', 'Active', 'Order', 'Type', 'OffBalance',
    'Started', 'Completed', 'HeadTask', 'Executed', 'RoutePoint', 'BusinessProcess',
    'ThisNode', 'SentNo', 'ReceivedNo', 'CalculationType', 'RegistrationPeriod',
    'ReversingEntry', 'Account', 'ValueType', 'ActionPeriodIsBasic',
}
RESERVED_ATTR_NAMES_RU = {
    '\u0421\u0441\u044b\u043b\u043a\u0430', '\u041f\u043e\u043c\u0435\u0442\u043a\u0430\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u044f',
    '\u041a\u043e\u0434', '\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435',
    '\u0414\u0430\u0442\u0430', '\u041d\u043e\u043c\u0435\u0440', '\u041f\u0440\u043e\u0432\u0435\u0434\u0435\u043d',
    '\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c', '\u0412\u043b\u0430\u0434\u0435\u043b\u0435\u0446',
    '\u042d\u0442\u043e\u0413\u0440\u0443\u043f\u043f\u0430', '\u041f\u0440\u0435\u0434\u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u043d\u044b\u0439',
    '\u0418\u043c\u044f\u041f\u0440\u0435\u0434\u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u043d\u044b\u0445\u0414\u0430\u043d\u043d\u044b\u0445',
    '\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440', '\u041f\u0435\u0440\u0438\u043e\u0434',
    '\u041d\u043e\u043c\u0435\u0440\u0421\u0442\u0440\u043e\u043a\u0438', '\u0410\u043a\u0442\u0438\u0432\u043d\u043e\u0441\u0442\u044c',
    '\u041f\u043e\u0440\u044f\u0434\u043e\u043a', '\u0422\u0438\u043f', '\u0417\u0430\u0431\u0430\u043b\u0430\u043d\u0441\u043e\u0432\u044b\u0439',
    '\u0421\u0442\u0430\u0440\u0442\u043e\u0432\u0430\u043d', '\u0417\u0430\u0432\u0435\u0440\u0448\u0435\u043d',
    '\u0412\u0435\u0434\u0443\u0449\u0430\u044f\u0417\u0430\u0434\u0430\u0447\u0430',
    '\u0412\u044b\u043f\u043e\u043b\u043d\u0435\u043d\u0430', '\u0422\u043e\u0447\u043a\u0430\u041c\u0430\u0440\u0448\u0440\u0443\u0442\u0430',
    '\u0411\u0438\u0437\u043d\u0435\u0441\u041f\u0440\u043e\u0446\u0435\u0441\u0441',
    '\u042d\u0442\u043e\u0442\u0423\u0437\u0435\u043b', '\u041d\u043e\u043c\u0435\u0440\u041e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043d\u043e\u0433\u043e',
    '\u041d\u043e\u043c\u0435\u0440\u041f\u0440\u0438\u043d\u044f\u0442\u043e\u0433\u043e',
    '\u0412\u0438\u0434\u0420\u0430\u0441\u0447\u0435\u0442\u0430', '\u041f\u0435\u0440\u0438\u043e\u0434\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u0438',
    '\u0421\u0442\u043e\u0440\u043d\u043e\u0417\u0430\u043f\u0438\u0441\u044c',
    '\u0421\u0447\u0435\u0442', '\u0422\u0438\u043f\u0417\u043d\u0430\u0447\u0435\u043d\u0438\u044f',
    '\u041f\u0435\u0440\u0438\u043e\u0434\u0414\u0435\u0439\u0441\u0442\u0432\u0438\u044f\u0411\u0430\u0437\u043e\u0432\u044b\u0439',
}

# Стандартные реквизиты по типу объекта (EN + RU). Совпадение имени реквизита с ними платформа
# не позволит — жёсткий отказ. Контексты вне карты → мягкое предупреждение по плоскому списку.
RESERVED_BY_CONTEXT = {
    'catalog': {
        'ref', 'ссылка',                      # Ссылка
        'deletionmark', 'пометкаудаления',  # ПометкаУдаления
        'predefined', 'предопределенный',  # Предопределенный
        'predefineddataname', 'имяпредопределенныхданных',  # ИмяПредопределенныхДанных
        'code', 'код',                                        # Код
        'description', 'наименование',  # Наименование
        'owner', 'владелец',          # Владелец
        'parent', 'родитель',         # Родитель
        'isfolder', 'этогруппа',  # ЭтоГруппа
    },
    'document': {
        'ref', 'ссылка',                      # Ссылка
        'deletionmark', 'пометкаудаления',  # ПометкаУдаления
        'date', 'дата',                                  # Дата
        'number', 'номер',                          # Номер
        'posted', 'проведен',        # Проведен
    },
}

# Стандартные реквизиты по типу для разворота dataPath: [(EN, RU), ...].
STD_ATTR_BY_TYPE = {
    'Catalog': [('Ref', 'Ссылка'), ('DeletionMark', 'ПометкаУдаления'), ('Predefined', 'Предопределенный'),
                ('PredefinedDataName', 'ИмяПредопределенныхДанных'), ('Code', 'Код'), ('Description', 'Наименование'),
                ('Owner', 'Владелец'), ('Parent', 'Родитель'), ('IsFolder', 'ЭтоГруппа')],
    'Document': [('Ref', 'Ссылка'), ('DeletionMark', 'ПометкаУдаления'), ('Date', 'Дата'), ('Number', 'Номер'),
                 ('Posted', 'Проведен')],
}

def resolve_std_attr_en(name):
    pairs = STD_ATTR_BY_TYPE.get(obj_type)
    if not pairs:
        return None
    low = name.lower()
    for en, ru in pairs:
        if low == en.lower() or low == ru.lower():
            return en
    return None

def expand_data_path(dp):
    """Путь к реквизиту самого объекта: "Ссылка"→<Тип>.<Имя>.StandardAttribute.Ref; обычное имя→.Attribute.имя;
    частичное StandardAttribute.X/Attribute.X→префикс; полный путь→verbatim."""
    if not dp:
        return dp
    s = str(dp)
    if re.search(r'[:/]', s):
        return s   # спец-путь (напр. 0:GUID/0:GUID в зависимостях ПВХ) — не разворачиваем
    if re.match(r'^-?\d+$', s):
        return s   # голый (отрицательный) индекс-маркер (напр. -8 в ChoiceParameterLinks) — verbatim
    if re.match(r'^(StandardAttribute|Attribute)\.', s):
        return f'{obj_type}.{obj_name}.{s}'
    if '.' not in s:
        en = resolve_std_attr_en(s)
        if en:
            return f'{obj_type}.{obj_name}.StandardAttribute.{en}'
        return f'{obj_type}.{obj_name}.Attribute.{s}'
    return s

def emit_link_by_type(indent, spec):
    """<LinkByType> (связь по типу): DataPath + LinkItem. spec — {dataPath, linkItem?} или строка-путь; нет → <LinkByType/>."""
    if not spec:
        X(f'{indent}<LinkByType/>')
        return
    if isinstance(spec, str):
        dp, li = spec, 0
    else:
        dp = str(spec.get('dataPath') or spec.get('path') or spec.get('путь') or '')
        li = spec.get('linkItem')
        if li is None:
            li = spec.get('элементСвязи')
        if li is None:
            li = 0
    if not dp:
        X(f'{indent}<LinkByType/>')
        return
    dp = expand_data_path(dp)
    X(f'{indent}<LinkByType>')
    X(f'{indent}\t<xr:DataPath>{esc_xml(str(dp))}</xr:DataPath>')
    X(f'{indent}\t<xr:LinkItem>{li}</xr:LinkItem>')
    X(f'{indent}</LinkByType>')

def emit_field_block(indent, tag, fields):
    """<Tag> со списком <xr:Field> (InputByString/DataLockFields). Пусто → self-close."""
    arr = [f for f in (fields or []) if str(f) != '']
    if not arr:
        X(f'{indent}<{tag}/>')
        return
    X(f'{indent}<{tag}>')
    for f in arr:
        X(f'{indent}\t<xr:Field>{esc_xml(str(f))}</xr:Field>')
    X(f'{indent}</{tag}>')

def emit_based_on(indent, items):
    """<BasedOn> — «ввод на основании», список MDObjectRef. Нет/пусто → self-close."""
    arr = [it for it in (items or []) if it]
    if not arr:
        X(f'{indent}<BasedOn/>')
        return
    X(f'{indent}<BasedOn>')
    for it in arr:
        X(f'{indent}\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml(str(it))}</xr:Item>')
    X(f'{indent}</BasedOn>')

# --- Параметры/связи выбора (порт из form-compile) ---

def ch_el_prop(obj, names):
    if obj is None:
        return None
    if isinstance(obj, dict):
        for n in names:
            if n in obj:
                return obj[n]
    return None

def convert_to_ch_scalar(s):
    t = str(s).strip()
    if re.match(r'^(?i:true|истина)$', t):
        return True
    if re.match(r'^(?i:false|ложь)$', t):
        return False
    if re.match(r'^-?\d+$', t):
        return int(t)
    if re.match(r'^-?\d+\.\d+$', t):
        return float(t)
    return t

def expand_choice_ref_value(value, type_str):
    """Голое значение (без точки) + тип параметра → полный DTR-путь, либо None. Принимает EnumRef.X / Enum.X / рус."""
    if not type_str:
        return None
    t = resolve_type_str(type_str)
    root = tn = None
    m = re.match(r'^(\w+Ref)\.(.+)$', t)
    if m:
        root = fill_ref_kind_root.get(m.group(1).lower())
        tn = m.group(2)
    else:
        m = re.match(r'^([^.]+)\.(.+)$', t)
        if m:
            root = fill_ref_roots.get(m.group(1).lower())
            tn = m.group(2)
    if not root:
        return None
    if str(value).lower() in fill_empty_ref_words:
        return f'{root}.{tn}.EmptyRef'
    if root == 'Enum':
        return f'Enum.{tn}.EnumValue.{value}'
    return f'{root}.{tn}.{value}'

def normalize_choice_value_t(value, type_str):
    """Значение параметра выбора → (xsi_type, text). type_str разворачивает голые ref-имена."""
    if type_str and isinstance(value, str) and '.' not in value:
        ex = expand_choice_ref_value(value, type_str)
        if ex:
            return ('xr:DesignTimeRef', ex)
    return normalize_choice_value(value)

def normalize_choice_value(value):
    """Значение параметра выбора → (xsi_type, text). Авто-детект по значению."""
    if isinstance(value, bool):
        return ('xs:boolean', 'true' if value else 'false')
    if isinstance(value, (int, float)):
        return ('xs:decimal', format_fill_num(value))
    s = str(value)
    if s == '':
        return ('xs:string', '')
    if re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$', s):
        return ('xs:dateTime', s)
    ref = normalize_fill_ref(s)
    if ref:
        return ('xr:DesignTimeRef', ref)
    if s in ACCOUNT_TYPE_VALUES:
        return ('ent:AccountType', s)
    return ('xs:string', s)

def convert_from_ch_param_shorthand(s):
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    name = s[:eq].strip()
    rest = s[eq + 1:]
    if ',' in rest:
        return {'name': name, 'value': [convert_to_ch_scalar(p) for p in rest.split(',')]}
    return {'name': name, 'value': convert_to_ch_scalar(rest)}

def convert_from_ch_link_shorthand(s):
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    o = {'name': s[:eq].strip()}
    rest = s[eq + 1:].strip()
    m = re.match(r'^(.*):(?i:(Clear|DontChange|очистить|неизменять))$', rest)
    if m:
        o['dataPath'] = m.group(1).strip()
        o['valueChange'] = m.group(2)
    else:
        o['dataPath'] = rest
    return o

def emit_choice_parameters(indent, cp, tag='ChoiceParameters'):
    if not cp:
        X(f'{indent}<{tag}/>')
        return
    if isinstance(cp, (str, dict)):
        cp = [cp]
    X(f'{indent}<{tag}>')
    for item in cp:
        if isinstance(item, str):
            item = convert_from_ch_param_shorthand(item)
        name = ch_el_prop(item, ['name', 'имя'])
        ptype = ch_el_prop(item, ['type', 'тип'])
        has_val = isinstance(item, dict) and ('value' in item or 'значение' in item)
        val = item.get('value', item.get('значение')) if has_val else None
        val_is_array = isinstance(val, (list, tuple))
        X(f'{indent}\t<app:item name="{esc_xml(str(name))}">')
        if not has_val:
            X(f'{indent}\t\t<app:value xsi:nil="true"/>')
        elif val_is_array:
            X(f'{indent}\t\t<app:value xsi:type="v8:FixedArray">')
            for v in val:
                xt, tx = normalize_choice_value_t(v, ptype)
                if tx == '' or tx is None:
                    X(f'{indent}\t\t\t<v8:Value xsi:type="{xt}"/>')
                else:
                    X(f'{indent}\t\t\t<v8:Value xsi:type="{xt}">{esc_xml(tx)}</v8:Value>')
            X(f'{indent}\t\t</app:value>')
        else:
            xt, tx = normalize_choice_value_t(val, ptype)
            if tx == '' or tx is None:
                X(f'{indent}\t\t<app:value xsi:type="{xt}"/>')
            else:
                X(f'{indent}\t\t<app:value xsi:type="{xt}">{esc_xml(tx)}</app:value>')
        X(f'{indent}\t</app:item>')
    X(f'{indent}</{tag}>')

def emit_choice_parameter_links(indent, cpl, tag='ChoiceParameterLinks'):
    if not cpl:
        X(f'{indent}<{tag}/>')
        return
    if isinstance(cpl, (str, dict)):
        cpl = [cpl]
    X(f'{indent}<{tag}>')
    for lk in cpl:
        if isinstance(lk, str):
            lk = convert_from_ch_link_shorthand(lk)
        name = ch_el_prop(lk, ['name', 'имя'])
        dp = expand_data_path(ch_el_prop(lk, ['dataPath', 'path', 'путь']))
        vc_raw = ch_el_prop(lk, ['valueChange', 'режимИзменения'])
        vc = 'Clear'
        if vc_raw:
            low = str(vc_raw).lower()
            if re.match(r'^(clear|очистить|очистка)$', low):
                vc = 'Clear'
            elif re.match(r'^(dontchange|неизменять|неменять|нет)$', low):
                vc = 'DontChange'
            else:
                vc = str(vc_raw)
        X(f'{indent}\t<xr:Link>')
        X(f'{indent}\t\t<xr:Name>{esc_xml(str(name))}</xr:Name>')
        X(f'{indent}\t\t<xr:DataPath xsi:type="xs:string">{esc_xml(str(dp))}</xr:DataPath>')
        X(f'{indent}\t\t<xr:ValueChange>{vc}</xr:ValueChange>')
        X(f'{indent}\t</xr:Link>')
    X(f'{indent}</{tag}>')

# --- Characteristics (привязка ПВХ «Дополнительные реквизиты и сведения») ---

CHAR_FROM_TS_TYPES = {'Catalog', 'Document', 'ChartOfCharacteristicTypes', 'ChartOfCalculationTypes',
                      'ChartOfAccounts', 'ExchangePlan', 'BusinessProcess', 'Task'}
CHAR_MEMBER_RU = {'ТабличнаяЧасть': 'TabularSection', 'Измерение': 'Dimension', 'Ресурс': 'Resource', 'Реквизит': 'Attribute'}

def normalize_char_from(from_):
    if not from_:
        return from_
    parts = str(from_).split('.')
    if parts[0] in object_type_synonyms:
        parts[0] = object_type_synonyms[parts[0]]
    for i in range(1, len(parts)):
        if parts[i] in CHAR_MEMBER_RU:
            parts[i] = CHAR_MEMBER_RU[parts[i]]
    if len(parts) == 3 and parts[0] in CHAR_FROM_TS_TYPES:
        parts = [parts[0], parts[1], 'TabularSection', parts[2]]
    return '.'.join(parts)

def resolve_char_std_en(name):
    n = str(name).lower()
    if n in ('ref', 'ссылка'):
        return 'Ref'
    if n in ('parent', 'родитель'):
        return 'Parent'
    if n in ('owner', 'владелец'):
        return 'Owner'
    return None

def char_int_field(obj, names):
    v = ch_el_prop(obj, names)
    if v is None or str(v) == '':
        return -1
    return int(v)

def expand_char_field(field, from_):
    s = str(field or '')
    if not s:
        return s
    if s == '-1':
        return '-1'   # поле не задано (empty-характеристика)
    if re.match(r'^(StandardAttribute|Attribute|Dimension|Resource)\.', s):
        return f'{from_}.{s}'
    if '.' not in s:
        en = resolve_char_std_en(s)
        if en:
            return f'{from_}.StandardAttribute.{en}'
        return f'{from_}.Attribute.{s}'
    return s

def emit_characteristics(indent, chars):
    if not chars:
        X(f'{indent}<Characteristics/>')
        return
    X(f'{indent}<Characteristics>')
    for ch in chars:
        types = ch_el_prop(ch, ['types', 'characteristicTypes', 'типы'])
        values = ch_el_prop(ch, ['values', 'characteristicValues', 'значения'])
        t_from = normalize_char_from(ch_el_prop(types, ['from', 'source', 'источник']) or '')
        v_from = normalize_char_from(ch_el_prop(values, ['from', 'source', 'источник']) or '')
        key = expand_char_field(ch_el_prop(types, ['key', 'keyField']), t_from)
        tff = expand_char_field(ch_el_prop(types, ['filterField', 'typesFilterField']), t_from)
        obj = expand_char_field(ch_el_prop(values, ['object', 'objectField']), v_from)
        typ = expand_char_field(ch_el_prop(values, ['type', 'typeField']), v_from)
        val = expand_char_field(ch_el_prop(values, ['value', 'valueField']), v_from)
        dpf = char_int_field(types, ['dataPathField'])
        mvu = char_int_field(types, ['multipleValuesUseField'])
        mvk = char_int_field(values, ['multipleValuesKeyField'])
        mvo = char_int_field(values, ['multipleValuesOrderField'])
        X(f'{indent}\t<xr:Characteristic>')
        X(f'{indent}\t\t<xr:CharacteristicTypes from="{esc_xml(t_from)}">')
        X(f'{indent}\t\t\t<xr:KeyField>{esc_xml(key)}</xr:KeyField>')
        X(f'{indent}\t\t\t<xr:TypesFilterField>{esc_xml(tff)}</xr:TypesFilterField>')
        # filterValue: None→nil; голое→xs:string, полный путь→DTR, bool→xs:boolean.
        tfv_raw = ch_el_prop(types, ['filterValue', 'typesFilterValue'])
        if tfv_raw is None:
            X(f'{indent}\t\t\t<xr:TypesFilterValue xsi:nil="true"/>')
        else:
            tfv_xt, tfv_tx = normalize_choice_value(tfv_raw)
            if tfv_tx == '' or tfv_tx is None:
                X(f'{indent}\t\t\t<xr:TypesFilterValue xsi:type="{tfv_xt}"/>')
            else:
                X(f'{indent}\t\t\t<xr:TypesFilterValue xsi:type="{tfv_xt}">{esc_xml(tfv_tx)}</xr:TypesFilterValue>')
        X(f'{indent}\t\t\t<xr:DataPathField>{dpf}</xr:DataPathField>')
        X(f'{indent}\t\t\t<xr:MultipleValuesUseField>{mvu}</xr:MultipleValuesUseField>')
        X(f'{indent}\t\t</xr:CharacteristicTypes>')
        X(f'{indent}\t\t<xr:CharacteristicValues from="{esc_xml(v_from)}">')
        X(f'{indent}\t\t\t<xr:ObjectField>{esc_xml(obj)}</xr:ObjectField>')
        X(f'{indent}\t\t\t<xr:TypeField>{esc_xml(typ)}</xr:TypeField>')
        X(f'{indent}\t\t\t<xr:ValueField>{esc_xml(val)}</xr:ValueField>')
        X(f'{indent}\t\t\t<xr:MultipleValuesKeyField>{mvk}</xr:MultipleValuesKeyField>')
        X(f'{indent}\t\t\t<xr:MultipleValuesOrderField>{mvo}</xr:MultipleValuesOrderField>')
        X(f'{indent}\t\t</xr:CharacteristicValues>')
        X(f'{indent}\t</xr:Characteristic>')
    X(f'{indent}</Characteristics>')

def emit_min_max_value(indent, tag, val):
    """<MinValue>/<MaxValue> — граница диапазона. None → nil. Число → xs:decimal, строка → xs:string."""
    if val is None:
        X(f'{indent}<{tag} xsi:nil="true"/>')
        return
    t = 'xs:string' if isinstance(val, str) else 'xs:decimal'
    X(f'{indent}<{tag} xsi:type="{t}">{esc_xml(str(val))}</{tag}>')

def emit_attribute(indent, parsed, context, elem_tag='Attribute'):
    # context: "catalog", "document", "object", "processor", "tabular", "processor-tabular", "register",
    #   "account" (реквизит Плана счетов: как catalog, но без <Use>), "account-flag" (признак учёта ПС:
    #   как account, но без <Indexing>/<FullTextSearch>, тип по умолчанию Boolean; elem_tag = AccountingFlag/ExtDimensionAccountingFlag)
    attr_name = parsed['name']
    ctx_reserved = RESERVED_BY_CONTEXT.get(context)
    if ctx_reserved is not None:
        if attr_name.lower() in ctx_reserved:
            print(f"meta-compile: имя реквизита '{attr_name}' зарезервировано стандартным реквизитом объекта '{context}'. Выберите другое имя.", file=sys.stderr)
            sys.exit(1)
    elif context not in ('tabular', 'processor-tabular') and (attr_name in RESERVED_ATTR_NAMES or attr_name in RESERVED_ATTR_NAMES_RU):
        print(f"WARNING: Attribute '{attr_name}' conflicts with a standard attribute name. This may cause errors when loading into 1C.", file=sys.stderr)
    uid = new_uuid()
    X(f'{indent}<{elem_tag} uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    if parsed.get('comment'):
        X(f'{indent}\t\t<Comment>{esc_xml_text(parsed["comment"])}</Comment>')
    else:
        X(f'{indent}\t\t<Comment/>')
    type_str = parsed['type']
    if parsed.get('typeEmpty'):
        # Явный пустой тип (реквизит без типа / произвольный) → <Type/>.
        X(f'{indent}\t\t<Type/>')
    elif type_str:
        emit_value_type(f'{indent}\t\t', type_str)
    elif context == 'account-flag':
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:boolean</v8:Type>')
        X(f'{indent}\t\t</Type>')
    else:
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:string</v8:Type>')
        X(f'{indent}\t\t</Type>')
    pw_mode = 'true' if parsed.get('passwordMode') is True else 'false'
    X(f'{indent}\t\t<PasswordMode>{pw_mode}</PasswordMode>')
    emit_mltext(f'{indent}\t\t', 'Format', parsed.get('format'))
    emit_mltext(f'{indent}\t\t', 'EditFormat', parsed.get('editFormat'))
    emit_mltext(f'{indent}\t\t', 'ToolTip', parsed.get('tooltip'))
    X(f'{indent}\t\t<MarkNegatives>{"true" if parsed.get("markNegatives") is True else "false"}</MarkNegatives>')
    if parsed.get('mask'):
        X(f'{indent}\t\t<Mask>{esc_xml_text(parsed["mask"])}</Mask>')
    else:
        X(f'{indent}\t\t<Mask/>')
    multi_line = 'true' if (parsed.get('multiLine') is True or 'multiline' in parsed.get('flags', [])) else 'false'
    X(f'{indent}\t\t<MultiLine>{multi_line}</MultiLine>')
    ext_edit = 'true' if parsed.get('extendedEdit') is True else 'false'
    X(f'{indent}\t\t<ExtendedEdit>{ext_edit}</ExtendedEdit>')
    emit_min_max_value(f'{indent}\t\t', 'MinValue', parsed.get('minValue'))
    emit_min_max_value(f'{indent}\t\t', 'MaxValue', parsed.get('maxValue'))
    # FillFromFillingValue / FillValue — not for tabular/processor/chart/register-other
    # (Chart*, AccumulationRegister/AccountingRegister/CalculationRegister don't support these)
    if context not in ('tabular', 'processor', 'chart', 'register-other', 'register-accum', 'register-calc', 'register-account'):
        ffv = 'true' if (parsed.get('fillFromFillingValue') is True or (elem_tag == 'Dimension' and 'master' in parsed.get('flags', []))) else 'false'
        X(f'{indent}\t\t<FillFromFillingValue>{ffv}</FillFromFillingValue>')
    if context not in ('tabular', 'processor', 'chart', 'register-other', 'register-accum', 'register-calc', 'register-account'):
        emit_fill_value(f'{indent}\t\t', type_str, parsed.get('fillValue'), parsed.get('hasFillValue'), bool(parsed.get('typeEmpty')))
    fill_checking = 'DontCheck'
    if 'req' in parsed.get('flags', []):
        fill_checking = 'ShowError'
    if parsed.get('fillChecking'):
        fill_checking = parsed['fillChecking']
    X(f'{indent}\t\t<FillChecking>{fill_checking}</FillChecking>')
    X(f'{indent}\t\t<ChoiceFoldersAndItems>{parsed.get("choiceFoldersAndItems") or "Items"}</ChoiceFoldersAndItems>')
    emit_choice_parameter_links(f'{indent}\t\t', parsed.get('choiceParameterLinks'))
    emit_choice_parameters(f'{indent}\t\t', parsed.get('choiceParameters'))
    X(f'{indent}\t\t<QuickChoice>{parsed.get("quickChoice") or "Auto"}</QuickChoice>')
    X(f'{indent}\t\t<CreateOnInput>{parsed.get("createOnInput") or "Auto"}</CreateOnInput>')
    X(f'{indent}\t\t<ChoiceForm>{esc_xml(str(parsed["choiceForm"]))}</ChoiceForm>' if parsed.get('choiceForm') else f'{indent}\t\t<ChoiceForm/>')
    emit_link_by_type(f'{indent}\t\t', parsed.get('linkByType'))
    chi = parsed.get('choiceHistoryOnInput') or 'Auto'
    X(f'{indent}\t\t<ChoiceHistoryOnInput>{chi}</ChoiceHistoryOnInput>')
    # Измерение регистра сведений: Master/MainFilter/DenyIncompleteValues (между ChoiceHistoryOnInput и Indexing).
    if elem_tag == 'Dimension' and context == 'register-info':
        master = 'true' if (parsed.get('master') is True or 'master' in parsed.get('flags', [])) else 'false'
        main_filter = 'true' if (parsed.get('mainFilter') is True or 'mainfilter' in parsed.get('flags', [])) else 'false'
        deny_incomplete = 'true' if (parsed.get('denyIncompleteValues') is True or 'denyincomplete' in parsed.get('flags', [])) else 'false'
        X(f'{indent}\t\t<Master>{master}</Master>')
        X(f'{indent}\t\t<MainFilter>{main_filter}</MainFilter>')
        X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
    # Измерение регистра накопления: DenyIncompleteValues (между ChoiceHistoryOnInput и Indexing).
    if elem_tag == 'Dimension' and context == 'register-accum':
        deny_incomplete = 'true' if (parsed.get('denyIncompleteValues') is True or 'denyincomplete' in parsed.get('flags', [])) else 'false'
        X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
    # Измерение регистра расчёта: DenyIncompleteValues + BaseDimension.
    if elem_tag == 'Dimension' and context == 'register-calc':
        deny_incomplete = 'true' if (parsed.get('denyIncompleteValues') is True or 'denyincomplete' in parsed.get('flags', [])) else 'false'
        base_dimension = 'true' if (parsed.get('baseDimension') is True or 'base' in parsed.get('flags', [])) else 'false'
        X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
        X(f'{indent}\t\t<BaseDimension>{base_dimension}</BaseDimension>')
    # Регистр расчёта: ScheduleLink у измерений и реквизитов (НЕ ресурсов), перед Indexing. Дефолт пустой.
    if context == 'register-calc' and elem_tag in ('Dimension', 'Attribute'):
        if parsed.get('scheduleLink'):
            X(f'{indent}\t\t<ScheduleLink>{esc_xml(str(parsed["scheduleLink"]))}</ScheduleLink>')
        else:
            X(f'{indent}\t\t<ScheduleLink/>')
    # Измерение/ресурс регистра бухгалтерии: Balance + AccountingFlag, затем DenyIncompleteValues (изм.) / ExtDimensionAccountingFlag (рес.).
    if context == 'register-account' and elem_tag in ('Dimension', 'Resource'):
        balance = 'true' if (parsed.get('balance') is True or 'balance' in parsed.get('flags', [])) else 'false'
        X(f'{indent}\t\t<Balance>{balance}</Balance>')
        if parsed.get('accountingFlag'):
            X(f'{indent}\t\t<AccountingFlag>{esc_xml(str(parsed["accountingFlag"]))}</AccountingFlag>')
        else:
            X(f'{indent}\t\t<AccountingFlag/>')
        if elem_tag == 'Dimension':
            deny_incomplete = 'true' if (parsed.get('denyIncompleteValues') is True or 'denyincomplete' in parsed.get('flags', [])) else 'false'
            X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
        else:
            if parsed.get('extDimensionAccountingFlag'):
                X(f'{indent}\t\t<ExtDimensionAccountingFlag>{esc_xml(str(parsed["extDimensionAccountingFlag"]))}</ExtDimensionAccountingFlag>')
            else:
                X(f'{indent}\t\t<ExtDimensionAccountingFlag/>')
    if context == 'catalog':
        X(f'{indent}\t\t<Use>{parsed.get("use") or "ForItem"}</Use>')
    if context not in ('processor', 'processor-tabular'):
        # Признаки учёта ПС (account-flag) не имеют <Indexing>/<FullTextSearch>, но имеют <DataHistory>.
        if context != 'account-flag':
            # Ресурс регистра накопления НЕ имеет <Indexing> (только <FullTextSearch>); измерение/реквизит — имеют.
            if not (context in ('register-accum', 'register-calc', 'register-account') and elem_tag == 'Resource'):
                indexing = 'DontIndex'
                if 'index' in parsed.get('flags', []):
                    indexing = 'Index'
                if 'indexadditional' in parsed.get('flags', []):
                    indexing = 'IndexWithAdditionalOrder'
                if parsed.get('indexing'):
                    indexing = parsed['indexing']
                X(f'{indent}\t\t<Indexing>{indexing}</Indexing>')
            # Реквизит адресации задачи: AddressingDimension (между Indexing и FullTextSearch).
            if context == 'task-addressing' and elem_tag == 'AddressingAttribute':
                if parsed.get('addressingDimension'):
                    X(f'{indent}\t\t<AddressingDimension>{esc_xml(str(parsed["addressingDimension"]))}</AddressingDimension>')
                else:
                    X(f'{indent}\t\t<AddressingDimension/>')
            X(f'{indent}\t\t<FullTextSearch>{parsed.get("fullTextSearch") or "Use"}</FullTextSearch>')
        # Измерение регистра накопления: UseInTotals (после FullTextSearch, дефолт true).
        if elem_tag == 'Dimension' and context == 'register-accum':
            use_in_totals = 'false' if (parsed.get('useInTotals') is False or 'nouseintotals' in parsed.get('flags', [])) else 'true'
            X(f'{indent}\t\t<UseInTotals>{use_in_totals}</UseInTotals>')
        # DataHistory — not for Chart* types and non-InformationRegister register family
        if context not in ('chart', 'register-other', 'register-accum', 'register-calc', 'register-account'):
            X(f'{indent}\t\t<DataHistory>{parsed.get("dataHistory") or "Use"}</DataHistory>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</{elem_tag}>')

# ---------------------------------------------------------------------------
# 9. TabularSection emitter
# ---------------------------------------------------------------------------

def emit_command_picture(indent, cmd):
    """<Picture> команды — структурный блок (зеркало form-compile). Дефолт LoadTransparent=true (конвенция
    кнопки/команды): фиксируем только false. Значение: строка-ref + sibling loadTransparent ЛИБО объект
    {src, loadTransparent?, transparentPixel?}. src с префиксом "abs:" → <xr:Abs>, иначе <xr:Ref>. Нет → <Picture/>."""
    pic = cmd.get('picture')
    if not pic:
        X(f'{indent}<Picture/>')
        return
    lt = True
    tpx = None
    if isinstance(pic, str):
        src = pic
        if cmd.get('loadTransparent') is False:
            lt = False
    else:
        src = str(pic.get('src') or pic.get('ref') or '')
        if pic.get('loadTransparent') is False:
            lt = False
        tpx = pic.get('transparentPixel')
    if not src:
        X(f'{indent}<Picture/>')
        return
    X(f'{indent}<Picture>')
    m = re.match(r'^abs:(.*)$', src)
    if m:
        X(f'{indent}\t<xr:Abs>{esc_xml(m.group(1))}</xr:Abs>')
    else:
        X(f'{indent}\t<xr:Ref>{esc_xml(src)}</xr:Ref>')
    X(f'{indent}\t<xr:LoadTransparent>{"true" if lt else "false"}</xr:LoadTransparent>')
    if tpx:
        X(f'{indent}\t<xr:TransparentPixel x="{tpx.get("x")}" y="{tpx.get("y")}"/>')
    X(f'{indent}</Picture>')

def emit_command(indent, cmd_name, cmd):
    X(f'{indent}<Command uuid="{new_uuid()}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(cmd_name)}</Name>')
    syn = cmd['synonym'] if cmd.get('synonym') is not None else split_camel_case(cmd_name)
    emit_mltext(f'{indent}\t\t', 'Synonym', syn)
    if cmd.get('comment'):
        X(f'{indent}\t\t<Comment>{esc_xml_text(str(cmd["comment"]))}</Comment>')
    else:
        X(f'{indent}\t\t<Comment/>')
    group = resolve_command_group(cmd.get('group'), cmd_name)
    if cmd.get('commandParameterType') and group in SECTION_COMMAND_GROUPS:
        sys.stderr.write(f"Команда '{cmd_name}': тип параметра (commandParameterType) недоступен для команд "
                         f"командного интерфейса раздела ('{group}'). Тип параметра — только для групп формы "
                         f"(FormCommandBar*/FormNavigationPanel*) или CommandGroup.<Имя>.\n")
        sys.exit(1)
    X(f'{indent}\t\t<Group>{esc_xml(group)}</Group>')
    if cmd.get('commandParameterType'):
        X(f'{indent}\t\t<CommandParameterType>')
        emit_type_content(f'{indent}\t\t\t', str(cmd['commandParameterType']))
        X(f'{indent}\t\t</CommandParameterType>')
    else:
        X(f'{indent}\t\t<CommandParameterType/>')
    X(f'{indent}\t\t<ParameterUseMode>{cmd.get("parameterUseMode") or "Single"}</ParameterUseMode>')
    X(f'{indent}\t\t<ModifiesData>{"true" if cmd.get("modifiesData") is True else "false"}</ModifiesData>')
    X(f'{indent}\t\t<Representation>{cmd.get("representation") or "Auto"}</Representation>')
    emit_mltext(f'{indent}\t\t', 'ToolTip', cmd.get('tooltip'))
    emit_command_picture(f'{indent}\t\t', cmd)
    if cmd.get('shortcut'):
        X(f'{indent}\t\t<Shortcut>{esc_xml(str(cmd["shortcut"]))}</Shortcut>')
    else:
        X(f'{indent}\t\t<Shortcut/>')
    X(f'{indent}\t\t<OnMainServerUnavalableBehavior>{cmd.get("onMainServerUnavalableBehavior") or "Auto"}</OnMainServerUnavalableBehavior>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Command>')

def emit_tabular_section(indent, ts_name, columns, object_type, object_name, ts_synonym_arg=None, ts_tooltip=None, ts_comment=None, ts_line_number=None, ts_fill_checking=None, ts_use=None):
    uid = new_uuid()
    X(f'{indent}<TabularSection uuid="{uid}">')
    type_prefix = f'{object_type}TabularSection'
    row_prefix = f'{object_type}TabularSectionRow'
    X(f'{indent}\t<InternalInfo>')
    X(f'{indent}\t\t<xr:GeneratedType name="{type_prefix}.{object_name}.{ts_name}" category="TabularSection">')
    X(f'{indent}\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
    X(f'{indent}\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
    X(f'{indent}\t\t</xr:GeneratedType>')
    X(f'{indent}\t\t<xr:GeneratedType name="{row_prefix}.{object_name}.{ts_name}" category="TabularSectionRow">')
    X(f'{indent}\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
    X(f'{indent}\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
    X(f'{indent}\t\t</xr:GeneratedType>')
    X(f'{indent}\t</InternalInfo>')
    ts_synonym = ts_synonym_arg if ts_synonym_arg is not None else split_camel_case(ts_name)
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(ts_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', ts_synonym)
    if ts_comment:
        X(f'{indent}\t\t<Comment>{esc_xml_text(ts_comment)}</Comment>')
    else:
        X(f'{indent}\t\t<Comment/>')
    emit_mltext(f'{indent}\t\t', 'ToolTip', ts_tooltip)
    X(f'{indent}\t\t<FillChecking>{ts_fill_checking if ts_fill_checking else "DontCheck"}</FillChecking>')
    # TS-блок стандартных реквизитов (LineNumber) эмитим ВСЕГДА, кроме подавления `lineNumber: ""` (дом-конвенция
    # суппресса): ~6% ТЧ исторически опускают блок (правило не выводимо — Товары all-default его имеет, соседи нет).
    if not (isinstance(ts_line_number, str) and ts_line_number == ''):
        emit_tabular_standard_attributes(f'{indent}\t\t', ts_line_number)
    if object_type in ('Catalog', 'ChartOfCharacteristicTypes'):
        X(f'{indent}\t\t<Use>{ts_use if ts_use else "ForItem"}</Use>')
    X(f'{indent}\t</Properties>')
    ts_context = 'processor-tabular' if object_type in ('DataProcessor', 'Report') else 'tabular'
    X(f'{indent}\t<ChildObjects>')
    for col in columns:
        parsed = parse_attribute_shorthand(col)
        emit_attribute(f'{indent}\t\t', parsed, ts_context)
    X(f'{indent}\t</ChildObjects>')
    X(f'{indent}</TabularSection>')

# ---------------------------------------------------------------------------
# 10. EnumValue emitter
# ---------------------------------------------------------------------------

def emit_enum_value(indent, parsed):
    uid = new_uuid()
    X(f'{indent}<EnumValue uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    if parsed.get('comment'):
        X(f'{indent}\t\t<Comment>{esc_xml_text(parsed["comment"])}</Comment>')
    else:
        X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</EnumValue>')

# ---------------------------------------------------------------------------
# 11. Dimension emitter
# ---------------------------------------------------------------------------

def emit_dimension(indent, parsed, register_type):
    uid = new_uuid()
    X(f'{indent}<Dimension uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    X(f'{indent}\t\t<Comment/>')
    type_str = parsed['type']
    if type_str:
        emit_value_type(f'{indent}\t\t', type_str)
    else:
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:string</v8:Type>')
        X(f'{indent}\t\t</Type>')
    X(f'{indent}\t\t<PasswordMode>false</PasswordMode>')
    X(f'{indent}\t\t<Format/>')
    X(f'{indent}\t\t<EditFormat/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<MarkNegatives>{"true" if parsed.get("markNegatives") is True else "false"}</MarkNegatives>')
    X(f'{indent}\t\t<Mask/>')
    multi_line = 'true' if (parsed.get('multiLine') is True or 'multiline' in parsed.get('flags', [])) else 'false'
    X(f'{indent}\t\t<MultiLine>{multi_line}</MultiLine>')
    ext_edit = 'true' if parsed.get('extendedEdit') is True else 'false'
    X(f'{indent}\t\t<ExtendedEdit>{ext_edit}</ExtendedEdit>')
    emit_min_max_value(f'{indent}\t\t', 'MinValue', parsed.get('minValue'))
    emit_min_max_value(f'{indent}\t\t', 'MaxValue', parsed.get('maxValue'))
    flags = parsed.get('flags', [])
    if register_type == 'InformationRegister':
        fill_from = 'true' if 'master' in flags else 'false'
        X(f'{indent}\t\t<FillFromFillingValue>{fill_from}</FillFromFillingValue>')
        X(f'{indent}\t\t<FillValue xsi:nil="true"/>')
    fill_checking = 'DontCheck'
    if 'req' in flags:
        fill_checking = 'ShowError'
    X(f'{indent}\t\t<FillChecking>{fill_checking}</FillChecking>')
    X(f'{indent}\t\t<ChoiceFoldersAndItems>{parsed.get("choiceFoldersAndItems") or "Items"}</ChoiceFoldersAndItems>')
    X(f'{indent}\t\t<ChoiceParameterLinks/>')
    X(f'{indent}\t\t<ChoiceParameters/>')
    X(f'{indent}\t\t<QuickChoice>Auto</QuickChoice>')
    X(f'{indent}\t\t<CreateOnInput>Auto</CreateOnInput>')
    X(f'{indent}\t\t<ChoiceForm>{esc_xml(str(parsed["choiceForm"]))}</ChoiceForm>' if parsed.get('choiceForm') else f'{indent}\t\t<ChoiceForm/>')
    X(f'{indent}\t\t<LinkByType/>')
    X(f'{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    if register_type == 'InformationRegister':
        master = 'true' if 'master' in flags else 'false'
        main_filter = 'true' if 'mainfilter' in flags else 'false'
        deny_incomplete = 'true' if 'denyincomplete' in flags else 'false'
        X(f'{indent}\t\t<Master>{master}</Master>')
        X(f'{indent}\t\t<MainFilter>{main_filter}</MainFilter>')
        X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
    if register_type == 'AccumulationRegister':
        deny_incomplete = 'true' if 'denyincomplete' in flags else 'false'
        X(f'{indent}\t\t<DenyIncompleteValues>{deny_incomplete}</DenyIncompleteValues>')
    indexing = 'DontIndex'
    if 'index' in flags:
        indexing = 'Index'
    X(f'{indent}\t\t<Indexing>{indexing}</Indexing>')
    X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
    if register_type == 'AccumulationRegister':
        use_in_totals = 'false' if 'nouseintotals' in flags else 'true'
        X(f'{indent}\t\t<UseInTotals>{use_in_totals}</UseInTotals>')
    if register_type == 'InformationRegister':
        X(f'{indent}\t\t<DataHistory>Use</DataHistory>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Dimension>')

# ---------------------------------------------------------------------------
# 12. Resource emitter
# ---------------------------------------------------------------------------

def emit_resource(indent, parsed, register_type):
    uid = new_uuid()
    X(f'{indent}<Resource uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    X(f'{indent}\t\t<Comment/>')
    type_str = parsed['type']
    if type_str:
        emit_value_type(f'{indent}\t\t', type_str)
    else:
        X(f'{indent}\t\t<Type>')
        X(f'{indent}\t\t\t<v8:Type>xs:decimal</v8:Type>')
        X(f'{indent}\t\t\t<v8:NumberQualifiers>')
        X(f'{indent}\t\t\t\t<v8:Digits>15</v8:Digits>')
        X(f'{indent}\t\t\t\t<v8:FractionDigits>2</v8:FractionDigits>')
        X(f'{indent}\t\t\t\t<v8:AllowedSign>Any</v8:AllowedSign>')
        X(f'{indent}\t\t\t</v8:NumberQualifiers>')
        X(f'{indent}\t\t</Type>')
    X(f'{indent}\t\t<PasswordMode>false</PasswordMode>')
    X(f'{indent}\t\t<Format/>')
    X(f'{indent}\t\t<EditFormat/>')
    X(f'{indent}\t\t<ToolTip/>')
    X(f'{indent}\t\t<MarkNegatives>{"true" if parsed.get("markNegatives") is True else "false"}</MarkNegatives>')
    X(f'{indent}\t\t<Mask/>')
    multi_line = 'true' if (parsed.get('multiLine') is True or 'multiline' in parsed.get('flags', [])) else 'false'
    X(f'{indent}\t\t<MultiLine>{multi_line}</MultiLine>')
    ext_edit = 'true' if parsed.get('extendedEdit') is True else 'false'
    X(f'{indent}\t\t<ExtendedEdit>{ext_edit}</ExtendedEdit>')
    emit_min_max_value(f'{indent}\t\t', 'MinValue', parsed.get('minValue'))
    emit_min_max_value(f'{indent}\t\t', 'MaxValue', parsed.get('maxValue'))
    if register_type == 'InformationRegister':
        X(f'{indent}\t\t<FillFromFillingValue>false</FillFromFillingValue>')
        X(f'{indent}\t\t<FillValue xsi:nil="true"/>')
    flags = parsed.get('flags', [])
    fill_checking = 'DontCheck'
    if 'req' in flags:
        fill_checking = 'ShowError'
    X(f'{indent}\t\t<FillChecking>{fill_checking}</FillChecking>')
    X(f'{indent}\t\t<ChoiceFoldersAndItems>{parsed.get("choiceFoldersAndItems") or "Items"}</ChoiceFoldersAndItems>')
    X(f'{indent}\t\t<ChoiceParameterLinks/>')
    X(f'{indent}\t\t<ChoiceParameters/>')
    X(f'{indent}\t\t<QuickChoice>Auto</QuickChoice>')
    X(f'{indent}\t\t<CreateOnInput>Auto</CreateOnInput>')
    X(f'{indent}\t\t<ChoiceForm>{esc_xml(str(parsed["choiceForm"]))}</ChoiceForm>' if parsed.get('choiceForm') else f'{indent}\t\t<ChoiceForm/>')
    X(f'{indent}\t\t<LinkByType/>')
    X(f'{indent}\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>')
    if register_type == 'InformationRegister':
        X(f'{indent}\t\t<Indexing>DontIndex</Indexing>')
        X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
        X(f'{indent}\t\t<DataHistory>Use</DataHistory>')
    if register_type == 'AccumulationRegister':
        X(f'{indent}\t\t<FullTextSearch>Use</FullTextSearch>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Resource>')

# ---------------------------------------------------------------------------
# 13. Property emitters per type
# ---------------------------------------------------------------------------

def emit_catalog_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    hierarchical = 'true' if defn.get('hierarchical') is True else 'false'
    hierarchy_type = get_enum_prop('HierarchyType', 'hierarchyType', 'HierarchyFoldersAndItems')
    X(f'{i}<Hierarchical>{hierarchical}</Hierarchical>')
    X(f'{i}<HierarchyType>{hierarchy_type}</HierarchyType>')
    limit_level_count = 'true' if defn.get('limitLevelCount') is True else 'false'
    level_count = str(defn['levelCount']) if defn.get('levelCount') is not None else '2'
    folders_on_top = 'false' if defn.get('foldersOnTop') is False else 'true'
    X(f'{i}<LimitLevelCount>{limit_level_count}</LimitLevelCount>')
    X(f'{i}<LevelCount>{level_count}</LevelCount>')
    X(f'{i}<FoldersOnTop>{folders_on_top}</FoldersOnTop>')
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    owners = defn.get('owners', [])
    if owners:
        X(f'{i}<Owners>')
        for owner_ref in owners:
            full_ref = owner_ref if '.' in str(owner_ref) else f'Catalog.{owner_ref}'
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{full_ref}</xr:Item>')
        X(f'{i}</Owners>')
    else:
        X(f'{i}<Owners/>')
    subordination_use = get_enum_prop('SubordinationUse', 'subordinationUse', 'ToItems')
    X(f'{i}<SubordinationUse>{subordination_use}</SubordinationUse>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '25'
    code_type = get_enum_prop('CodeType', 'codeType', 'String')
    code_allowed_length = get_enum_prop('CodeAllowedLength', 'codeAllowedLength', 'Variable')
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    check_unique = 'true' if defn.get('checkUnique') is True else 'false'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<CodeType>{code_type}</CodeType>')
    X(f'{i}<CodeAllowedLength>{code_allowed_length}</CodeAllowedLength>')
    code_series = get_enum_prop('CodeSeries', 'codeSeries', 'WholeCatalog')
    X(f'{i}<CodeSeries>{code_series}</CodeSeries>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    default_presentation = get_enum_prop('DefaultPresentation', 'defaultPresentation', 'AsDescription')
    X(f'{i}<DefaultPresentation>{default_presentation}</DefaultPresentation>')
    emit_standard_attributes(i, 'Catalog')
    emit_characteristics(i, defn.get('characteristics'))
    X(f'{i}<PredefinedDataUpdate>{get_enum_prop("PredefinedDataUpdate", "predefinedDataUpdate", "Auto")}</PredefinedDataUpdate>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    quick_choice = 'true' if defn.get('quickChoice') is True else 'false'
    choice_mode = get_enum_prop('ChoiceMode', 'choiceMode', 'BothWays')
    X(f'{i}<QuickChoice>{quick_choice}</QuickChoice>')
    X(f'{i}<ChoiceMode>{choice_mode}</ChoiceMode>')
    # InputByString: override `inputByString` (массив имён, авто-резолв; [] = пусто) ЛИБО дефолт [Descr при D>0]+[Code при C>0].
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = []
        if int(description_length) > 0:
            ib_fields.append(f'Catalog.{obj_name}.StandardAttribute.Description')
        if int(code_length) > 0:
            ib_fields.append(f'Catalog.{obj_name}.StandardAttribute.Code')
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultFolderForm', defn.get('defaultFolderForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'DefaultFolderChoiceForm', defn.get('defaultFolderChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryFolderForm', defn.get('auxiliaryFolderForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    emit_form_ref(i, 'AuxiliaryFolderChoiceForm', defn.get('auxiliaryFolderChoiceForm'))
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    emit_based_on(i, defn.get('basedOn'))
    dl_fields = [expand_data_path(str(x)) for x in defn.get('dataLockFields', [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    data_lock_control_mode = get_enum_prop('DataLockControlMode', 'dataLockControlMode', 'Managed')
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = get_enum_prop('FullTextSearch', 'fullTextSearch', 'Use')
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "Use")}</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>DontUse</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_document_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    use_std_cmd = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmd}</UseStandardCommands>')
    if defn.get('numerator'):
        X(f'{i}<Numerator>{esc_xml(str(defn["numerator"]))}</Numerator>')
    else:
        X(f'{i}<Numerator/>')
    number_type = get_enum_prop('NumberType', 'numberType', 'String')
    number_length = str(defn['numberLength']) if defn.get('numberLength') is not None else '11'
    number_allowed_length = get_enum_prop('NumberAllowedLength', 'numberAllowedLength', 'Variable')
    number_periodicity = get_enum_prop('NumberPeriodicity', 'numberPeriodicity', 'Year')
    check_unique = 'false' if defn.get('checkUnique') is False else 'true'
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    X(f'{i}<NumberType>{number_type}</NumberType>')
    X(f'{i}<NumberLength>{number_length}</NumberLength>')
    X(f'{i}<NumberAllowedLength>{number_allowed_length}</NumberAllowedLength>')
    X(f'{i}<NumberPeriodicity>{number_periodicity}</NumberPeriodicity>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    emit_standard_attributes(i, 'Document')
    emit_characteristics(i, defn.get('characteristics'))
    emit_based_on(i, defn.get('basedOn'))
    # InputByString: override `inputByString` ЛИБО дефолт [Номер].
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = [f'Document.{obj_name}.StandardAttribute.Number']
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "Use")}</CreateOnInput>')
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    X(f'{i}<Posting>{get_enum_prop("Posting", "posting", "Allow")}</Posting>')
    X(f'{i}<RealTimePosting>{get_enum_prop("RealTimePosting", "realTimePosting", "Deny")}</RealTimePosting>')
    X(f'{i}<RegisterRecordsDeletion>{get_enum_prop("RegisterRecordsDeletion", "registerRecordsDeletion", "AutoDelete")}</RegisterRecordsDeletion>')
    X(f'{i}<RegisterRecordsWritingOnPost>{get_enum_prop("RegisterRecordsWritingOnPost", "registerRecordsWritingOnPost", "WriteSelected")}</RegisterRecordsWritingOnPost>')
    X(f'{i}<SequenceFilling>{get_enum_prop("SequenceFilling", "sequenceFilling", "AutoFill")}</SequenceFilling>')
    # RegisterRecords — движения (список MDObjectRef, синонимы типов резолвятся).
    reg_records = []
    if defn.get('registerRecords'):
        for rr in defn['registerRecords']:
            rr_str = str(rr)
            if '.' in rr_str:
                dot_idx = rr_str.index('.')
                rr_prefix = rr_str[:dot_idx]
                rr_suffix = rr_str[dot_idx + 1:]
                if rr_prefix in object_type_synonyms:
                    rr_prefix = object_type_synonyms[rr_prefix]
                reg_records.append(f'{rr_prefix}.{rr_suffix}')
            else:
                reg_records.append(rr_str)
    if reg_records:
        X(f'{i}<RegisterRecords>')
        for rr in reg_records:
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{rr}</xr:Item>')
        X(f'{i}</RegisterRecords>')
    else:
        X(f'{i}<RegisterRecords/>')
    post_in_priv = 'false' if defn.get('postInPrivilegedMode') is False else 'true'
    unpost_in_priv = 'false' if defn.get('unpostInPrivilegedMode') is False else 'true'
    X(f'{i}<PostInPrivilegedMode>{post_in_priv}</PostInPrivilegedMode>')
    X(f'{i}<UnpostInPrivilegedMode>{unpost_in_priv}</UnpostInPrivilegedMode>')
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    dl_fields = [expand_data_path(str(x)) for x in (defn.get('dataLockFields') or [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    upd_dh = 'true' if get_bool_prop('updateDataHistoryImmediatelyAfterWrite', False) else 'false'
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{upd_dh}</UpdateDataHistoryImmediatelyAfterWrite>')
    exec_dh = 'true' if get_bool_prop('executeAfterWriteDataHistoryVersionProcessing', False) else 'false'
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{exec_dh}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_enum_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(defn["comment"])}</Comment>')
    else:
        X(f'{i}<Comment/>')
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', False) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    emit_standard_attributes(i, 'Enum')
    emit_characteristics(i, defn.get('characteristics'))
    quick_choice = 'false' if defn.get('quickChoice') is False else 'true'
    X(f'{i}<QuickChoice>{quick_choice}</QuickChoice>')
    X(f'{i}<ChoiceMode>{get_enum_prop("ChoiceMode", "choiceMode", "BothWays")}</ChoiceMode>')
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')

def emit_constant_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    # Type — valueType (явный '' → <Type/>, реквизит без типа; отсутствие → String дефолт).
    value_type = build_type_str(defn)
    type_empty = (defn.get('valueType') is not None and str(defn.get('valueType')).strip() == '') or \
                 (defn.get('type') is not None and str(defn.get('type')).strip() == '')
    if type_empty:
        X(f'{i}<Type/>')
    else:
        emit_value_type(i, value_type or 'String')
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    emit_verbatim_ref(i, 'DefaultForm', defn.get('defaultForm'))
    emit_mltext(i, 'ExtendedPresentation', defn.get('extendedPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<PasswordMode>{"true" if get_bool_prop("passwordMode", False) else "false"}</PasswordMode>')
    emit_mltext(i, 'Format', defn.get('format'))
    emit_mltext(i, 'EditFormat', defn.get('editFormat'))
    emit_mltext(i, 'ToolTip', defn.get('tooltip'))
    X(f'{i}<MarkNegatives>{"true" if get_bool_prop("markNegatives", False) else "false"}</MarkNegatives>')
    if defn.get('mask'):
        X(f'{i}<Mask>{esc_xml_text(str(defn["mask"]))}</Mask>')
    else:
        X(f'{i}<Mask/>')
    X(f'{i}<MultiLine>{"true" if get_bool_prop("multiLine", False) else "false"}</MultiLine>')
    X(f'{i}<ExtendedEdit>{"true" if get_bool_prop("extendedEdit", False) else "false"}</ExtendedEdit>')
    emit_min_max_value(i, 'MinValue', defn.get('minValue'))
    emit_min_max_value(i, 'MaxValue', defn.get('maxValue'))
    X(f'{i}<FillChecking>{get_enum_prop("FillChecking", "fillChecking", "DontCheck")}</FillChecking>')
    X(f'{i}<ChoiceFoldersAndItems>{get_enum_prop("ChoiceFoldersAndItems", "choiceFoldersAndItems", "Items")}</ChoiceFoldersAndItems>')
    emit_choice_parameter_links(i, defn.get('choiceParameterLinks'))
    emit_choice_parameters(i, defn.get('choiceParameters'))
    X(f'{i}<QuickChoice>{get_enum_prop("QuickChoice", "quickChoice", "Auto")}</QuickChoice>')
    if defn.get('choiceForm'):
        X(f'{i}<ChoiceForm>{esc_xml(str(defn["choiceForm"]))}</ChoiceForm>')
    else:
        X(f'{i}<ChoiceForm/>')
    emit_link_by_type(i, defn.get('linkByType'))
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{"true" if get_bool_prop("updateDataHistoryImmediatelyAfterWrite", False) else "false"}</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{"true" if get_bool_prop("executeAfterWriteDataHistoryVersionProcessing", False) else "false"}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_information_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    use_std_cmd = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmd}</UseStandardCommands>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    emit_form_ref(i, 'DefaultRecordForm', defn.get('defaultRecordForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'AuxiliaryRecordForm', defn.get('auxiliaryRecordForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_standard_attributes(i, 'InformationRegister')
    periodicity = get_enum_prop('InformationRegisterPeriodicity', 'periodicity', 'Nonperiodical')
    write_mode = get_enum_prop('WriteMode', 'writeMode', 'Independent')
    main_filter_on_period = 'true' if get_bool_prop('mainFilterOnPeriod', False) else 'false'
    X(f'{i}<InformationRegisterPeriodicity>{periodicity}</InformationRegisterPeriodicity>')
    X(f'{i}<WriteMode>{write_mode}</WriteMode>')
    X(f'{i}<MainFilterOnPeriod>{main_filter_on_period}</MainFilterOnPeriod>')
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    data_lock_control_mode = get_enum_prop('DataLockControlMode', 'dataLockControlMode', 'Managed')
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = get_enum_prop('FullTextSearch', 'fullTextSearch', 'Use')
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    en_tot_first = 'true' if get_bool_prop('enableTotalsSliceFirst', False) else 'false'
    en_tot_last = 'true' if get_bool_prop('enableTotalsSliceLast', False) else 'false'
    X(f'{i}<EnableTotalsSliceFirst>{en_tot_first}</EnableTotalsSliceFirst>')
    X(f'{i}<EnableTotalsSliceLast>{en_tot_last}</EnableTotalsSliceLast>')
    emit_mltext(i, 'RecordPresentation', defn.get('recordPresentation'))
    emit_mltext(i, 'ExtendedRecordPresentation', defn.get('extendedRecordPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    upd_dh = 'true' if get_bool_prop('updateDataHistoryImmediatelyAfterWrite', False) else 'false'
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{upd_dh}</UpdateDataHistoryImmediatelyAfterWrite>')
    exec_dh = 'true' if get_bool_prop('executeAfterWriteDataHistoryVersionProcessing', False) else 'false'
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{exec_dh}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_accumulation_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    use_std_cmd = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmd}</UseStandardCommands>')
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    register_type = get_enum_prop('RegisterType', 'registerType', 'Balance')
    X(f'{i}<RegisterType>{register_type}</RegisterType>')
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    emit_standard_attributes(i, 'AccumulationRegister')
    data_lock_control_mode = get_enum_prop('DataLockControlMode', 'dataLockControlMode', 'Managed')
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = get_enum_prop('FullTextSearch', 'fullTextSearch', 'Use')
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    enable_totals_splitting = 'false' if defn.get('enableTotalsSplitting') is False else 'true'
    X(f'{i}<EnableTotalsSplitting>{enable_totals_splitting}</EnableTotalsSplitting>')
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

# --- 13a. DefinedType, CommonModule, ScheduledJob, EventSubscription ---

def emit_defined_type_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    # Type — единый эмиттер emit_value_type/emit_type_content (составной через ' + '); valueType или valueTypes.
    if defn.get('valueType'):
        vt = str(defn['valueType'])
    elif defn.get('valueTypes'):
        vt = ' + '.join(str(x) for x in defn['valueTypes'])
    else:
        vt = ''
    if vt:
        emit_value_type(i, vt)
    else:
        X(f'{i}<Type/>')

def emit_functional_option_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    # Location — хранилище значения опции (ссылка verbatim; location или value).
    loc = str(defn['location']) if defn.get('location') else (str(defn['value']) if defn.get('value') else '')
    if loc:
        X(f'{i}<Location>{esc_xml(normalize_md_object_ref(loc))}</Location>')
    else:
        X(f'{i}<Location/>')
    # PrivilegedGetMode — дефолт true (корпус 2864/2864).
    X(f'{i}<PrivilegedGetMode>{"true" if get_bool_prop("privilegedGetMode", True) else "false"}</PrivilegedGetMode>')
    # Content — зависимые объекты (список MDObjectRef-путей). omit-on-empty.
    content = list(defn['content']) if defn.get('content') else []
    if content:
        X(f'{i}<Content>')
        for obj in content:
            X(f'{i}\t<xr:Object>{esc_xml(normalize_md_object_ref(str(obj)))}</xr:Object>')
        X(f'{i}</Content>')
    else:
        X(f'{i}<Content/>')

def emit_md_ref_list(indent, tag, items):
    """Список MDObjectRef (Documents/RegisterRecords/DocumentMap/…) с <xr:Item>. omit-on-empty."""
    arr = list(items) if items else []
    if arr:
        X(f'{indent}<{tag}>')
        for it in arr:
            X(f'{indent}\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml(normalize_md_object_ref(str(it)))}</xr:Item>')
        X(f'{indent}</{tag}>')
    else:
        X(f'{indent}<{tag}/>')

def emit_sequence_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<MoveBoundaryOnPosting>{get_enum_prop("MoveBoundaryOnPosting", "moveBoundaryOnPosting", "DontMove")}</MoveBoundaryOnPosting>')
    emit_md_ref_list(i, 'Documents', defn.get('documents'))
    emit_md_ref_list(i, 'RegisterRecords', defn.get('registerRecords'))
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')

def emit_filter_criterion_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    if defn.get('valueType'):
        vt = str(defn['valueType'])
    elif defn.get('valueTypes'):
        vt = ' + '.join(str(x) for x in defn['valueTypes'])
    else:
        vt = ''
    if vt:
        emit_value_type(i, vt)
    else:
        X(f'{i}<Type/>')
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    content = list(defn['content']) if defn.get('content') else []
    if content:
        X(f'{i}<Content>')
        for obj in content:
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml(normalize_md_object_ref(str(obj)))}</xr:Item>')
        X(f'{i}</Content>')
    else:
        X(f'{i}<Content/>')
    emit_verbatim_ref(i, 'DefaultForm', defn.get('defaultForm'))
    emit_verbatim_ref(i, 'AuxiliaryForm', defn.get('auxiliaryForm'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

def emit_document_numerator_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<NumberType>{get_enum_prop("NumberType", "numberType", "String")}</NumberType>')
    num_len = str(defn['numberLength']) if defn.get('numberLength') is not None else '11'
    X(f'{i}<NumberLength>{num_len}</NumberLength>')
    X(f'{i}<NumberAllowedLength>{get_enum_prop("NumberAllowedLength", "numberAllowedLength", "Variable")}</NumberAllowedLength>')
    X(f'{i}<NumberPeriodicity>{get_enum_prop("NumberPeriodicity", "numberPeriodicity", "Year")}</NumberPeriodicity>')
    X(f'{i}<CheckUnique>{"true" if get_bool_prop("checkUnique", True) else "false"}</CheckUnique>')

def emit_settings_storage_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    emit_verbatim_ref(i, 'DefaultSaveForm', defn.get('defaultSaveForm'))
    emit_verbatim_ref(i, 'DefaultLoadForm', defn.get('defaultLoadForm'))
    emit_verbatim_ref(i, 'AuxiliarySaveForm', defn.get('auxiliarySaveForm'))
    emit_verbatim_ref(i, 'AuxiliaryLoadForm', defn.get('auxiliaryLoadForm'))

def emit_common_form_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<FormType>{get_enum_prop("FormType", "formType", "Managed")}</FormType>')
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    purposes = list(defn['usePurposes']) if defn.get('usePurposes') else ['PlatformApplication', 'MobilePlatformApplication']
    if purposes:
        X(f'{i}<UsePurposes>')
        for p in purposes:
            X(f'{i}\t<v8:Value xsi:type="app:ApplicationUsePurpose">{p}</v8:Value>')
        X(f'{i}</UsePurposes>')
    else:
        X(f'{i}<UsePurposes/>')
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', False) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    emit_mltext(i, 'ExtendedPresentation', defn.get('extendedPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

def _emit_comment(i):
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')

def emit_session_parameter_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    if defn.get('valueType'):
        vt = str(defn['valueType'])
    elif defn.get('valueTypes'):
        vt = ' + '.join(str(x) for x in defn['valueTypes'])
    else:
        vt = ''
    if vt:
        emit_value_type(i, vt)
    else:
        X(f'{i}<Type/>')

def emit_functional_options_parameter_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    emit_md_ref_list(i, 'Use', defn.get('use'))

def emit_ws_reference_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    url = str(defn['locationURL']) if defn.get('locationURL') else (str(defn['locationUrl']) if defn.get('locationUrl') else '')
    if url:
        X(f'{i}<LocationURL>{esc_xml_text(url)}</LocationURL>')
    else:
        X(f'{i}<LocationURL/>')

def emit_common_picture_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    X(f'{i}<AvailabilityForChoice>{"true" if get_bool_prop("availabilityForChoice", False) else "false"}</AvailabilityForChoice>')
    X(f'{i}<AvailabilityForAppearance>{"true" if get_bool_prop("availabilityForAppearance", False) else "false"}</AvailabilityForAppearance>')

def emit_common_template_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    X(f'{i}<TemplateType>{get_enum_prop("TemplateType", "templateType", "SpreadsheetDocument")}</TemplateType>')

def emit_command_group_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    X(f'{i}<Representation>{get_enum_prop("Representation", "representation", "Auto")}</Representation>')
    emit_mltext(i, 'ToolTip', defn.get('tooltip'))
    emit_command_picture(i, defn)
    X(f'{i}<Category>{get_enum_prop("Category", "category", "NavigationPanel")}</Category>')

def emit_common_command_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    group = str(defn['group']) if defn.get('group') else ''
    if group:
        X(f'{i}<Group>{esc_xml(group)}</Group>')
    else:
        X(f'{i}<Group/>')
    X(f'{i}<Representation>{get_enum_prop("Representation", "representation", "Auto")}</Representation>')
    emit_mltext(i, 'ToolTip', defn.get('tooltip'))
    emit_command_picture(i, defn)
    if defn.get('shortcut'):
        X(f'{i}<Shortcut>{esc_xml(str(defn["shortcut"]))}</Shortcut>')
    else:
        X(f'{i}<Shortcut/>')
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    if defn.get('commandParameterType'):
        X(f'{i}<CommandParameterType>')
        emit_type_content(f'{i}\t', str(defn['commandParameterType']))
        X(f'{i}</CommandParameterType>')
    else:
        X(f'{i}<CommandParameterType/>')
    X(f'{i}<ParameterUseMode>{get_enum_prop("ParameterUseMode", "parameterUseMode", "Single")}</ParameterUseMode>')
    X(f'{i}<ModifiesData>{"true" if get_bool_prop("modifiesData", False) else "false"}</ModifiesData>')
    X(f'{i}<OnMainServerUnavalableBehavior>{get_enum_prop("OnMainServerUnavalableBehavior", "onMainServerUnavalableBehavior", "Auto")}</OnMainServerUnavalableBehavior>')

def emit_common_attribute_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    _emit_comment(i)
    vt = str(defn['valueType']) if defn.get('valueType') else 'String(0)'
    emit_value_type(i, vt)
    X(f'{i}<PasswordMode>{"true" if get_bool_prop("passwordMode", False) else "false"}</PasswordMode>')
    emit_mltext(i, 'Format', defn.get('format'))
    emit_mltext(i, 'EditFormat', defn.get('editFormat'))
    emit_mltext(i, 'ToolTip', defn.get('tooltip'))
    X(f'{i}<MarkNegatives>{"true" if get_bool_prop("markNegatives", False) else "false"}</MarkNegatives>')
    if defn.get('mask'):
        X(f'{i}<Mask>{esc_xml_text(str(defn["mask"]))}</Mask>')
    else:
        X(f'{i}<Mask/>')
    X(f'{i}<MultiLine>{"true" if get_bool_prop("multiLine", False) else "false"}</MultiLine>')
    X(f'{i}<ExtendedEdit>{"true" if get_bool_prop("extendedEdit", False) else "false"}</ExtendedEdit>')
    emit_min_max_value(i, 'MinValue', defn.get('minValue'))
    emit_min_max_value(i, 'MaxValue', defn.get('maxValue'))
    X(f'{i}<FillFromFillingValue>{"true" if get_bool_prop("fillFromFillingValue", False) else "false"}</FillFromFillingValue>')
    emit_fill_value(i, vt, defn.get('fillValue'), defn.get('fillValue') is not None)
    X(f'{i}<FillChecking>{get_enum_prop("FillChecking", "fillChecking", "DontCheck")}</FillChecking>')
    X(f'{i}<ChoiceFoldersAndItems>{get_enum_prop("ChoiceFoldersAndItems", "choiceFoldersAndItems", "Items")}</ChoiceFoldersAndItems>')
    emit_choice_parameter_links(i, defn.get('choiceParameterLinks'))
    emit_choice_parameters(i, defn.get('choiceParameters'))
    X(f'{i}<QuickChoice>{get_enum_prop("QuickChoice", "quickChoice", "Auto")}</QuickChoice>')
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "Auto")}</CreateOnInput>')
    if defn.get('choiceForm'):
        X(f'{i}<ChoiceForm>{esc_xml(str(defn["choiceForm"]))}</ChoiceForm>')
    else:
        X(f'{i}<ChoiceForm/>')
    emit_link_by_type(i, defn.get('linkByType'))
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    content = list(defn['content']) if defn.get('content') else []
    if content:
        X(f'{i}<Content>')
        for c in content:
            md = c if isinstance(c, str) else str(c.get('metadata', ''))
            use = 'Use' if isinstance(c, str) else (str(c['use']) if c.get('use') else 'Use')
            X(f'{i}\t<xr:Item>')
            X(f'{i}\t\t<xr:Metadata>{esc_xml(normalize_md_object_ref(md))}</xr:Metadata>')
            X(f'{i}\t\t<xr:Use>{use}</xr:Use>')
            cs = '' if isinstance(c, str) else (str(c['conditionalSeparation']) if c.get('conditionalSeparation') else '')
            if cs:
                X(f'{i}\t\t<xr:ConditionalSeparation>{esc_xml(cs)}</xr:ConditionalSeparation>')
            else:
                X(f'{i}\t\t<xr:ConditionalSeparation/>')
            X(f'{i}\t</xr:Item>')
        X(f'{i}</Content>')
    else:
        X(f'{i}<Content/>')
    X(f'{i}<AutoUse>{get_enum_prop("AutoUse", "autoUse", "DontUse")}</AutoUse>')
    X(f'{i}<DataSeparation>{get_enum_prop("DataSeparation", "dataSeparation", "DontUse")}</DataSeparation>')
    X(f'{i}<SeparatedDataUse>{get_enum_prop("SeparatedDataUse", "separatedDataUse", "Independently")}</SeparatedDataUse>')
    dsv = str(defn['dataSeparationValue']) if defn.get('dataSeparationValue') else ''
    X(f'{i}<DataSeparationValue>{esc_xml(dsv)}</DataSeparationValue>' if dsv else f'{i}<DataSeparationValue/>')
    dsu = str(defn['dataSeparationUse']) if defn.get('dataSeparationUse') else ''
    X(f'{i}<DataSeparationUse>{esc_xml(dsu)}</DataSeparationUse>' if dsu else f'{i}<DataSeparationUse/>')
    cs2 = str(defn['conditionalSeparation']) if defn.get('conditionalSeparation') else ''
    X(f'{i}<ConditionalSeparation>{esc_xml(cs2)}</ConditionalSeparation>' if cs2 else f'{i}<ConditionalSeparation/>')
    X(f'{i}<UsersSeparation>{get_enum_prop("UsersSeparation", "usersSeparation", "DontUse")}</UsersSeparation>')
    X(f'{i}<AuthenticationSeparation>{get_enum_prop("AuthenticationSeparation", "authenticationSeparation", "DontUse")}</AuthenticationSeparation>')
    X(f'{i}<ConfigurationExtensionsSeparation>{get_enum_prop("ConfigurationExtensionsSeparation", "configurationExtensionsSeparation", "DontUse")}</ConfigurationExtensionsSeparation>')
    X(f'{i}<Indexing>{get_enum_prop("Indexing", "indexing", "DontIndex")}</Indexing>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "Use")}</DataHistory>')

def emit_sequence_dimension(indent, dim_def):
    uid = new_uuid()
    parsed = parse_attribute_shorthand(dim_def)
    X(f'{indent}<Dimension uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(parsed["name"])}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', parsed['synonym'])
    if parsed.get('comment'):
        X(f'{indent}\t\t<Comment>{esc_xml_text(parsed["comment"])}</Comment>')
    else:
        X(f'{indent}\t\t<Comment/>')
    if parsed.get('typeEmpty'):
        X(f'{indent}\t\t<Type/>')
    elif parsed['type']:
        emit_value_type(f'{indent}\t\t', parsed['type'])
    else:
        X(f'{indent}\t\t<Type/>')
    dm = None if isinstance(dim_def, str) else dim_def.get('documentMap')
    rrm = None if isinstance(dim_def, str) else dim_def.get('registerRecordsMap')
    emit_md_ref_list(f'{indent}\t\t', 'DocumentMap', dm)
    emit_md_ref_list(f'{indent}\t\t', 'RegisterRecordsMap', rrm)
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Dimension>')

def emit_common_module_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    context = str(defn['context']) if defn.get('context') else ''
    global_val = 'true' if defn.get('global') is True else 'false'
    server = 'false'
    server_call = 'false'
    client_managed = 'false'
    client_ordinary = 'false'
    external_connection = 'false'
    privileged = 'false'
    if context == 'server' or context == 'serverCall':
        server = 'true'
        server_call = 'true'
    elif context == 'client':
        client_managed = 'true'
    elif context == 'serverClient':
        server = 'true'
        client_managed = 'true'
    else:
        if defn.get('server') is True:
            server = 'true'
        if defn.get('serverCall') is True:
            server_call = 'true'
        if defn.get('clientManagedApplication') is True:
            client_managed = 'true'
        if defn.get('clientOrdinaryApplication') is True:
            client_ordinary = 'true'
        if defn.get('externalConnection') is True:
            external_connection = 'true'
        if defn.get('privileged') is True:
            privileged = 'true'
    X(f'{i}<Global>{global_val}</Global>')
    X(f'{i}<ClientManagedApplication>{client_managed}</ClientManagedApplication>')
    X(f'{i}<Server>{server}</Server>')
    X(f'{i}<ExternalConnection>{external_connection}</ExternalConnection>')
    X(f'{i}<ClientOrdinaryApplication>{client_ordinary}</ClientOrdinaryApplication>')
    X(f'{i}<ServerCall>{server_call}</ServerCall>')
    X(f'{i}<Privileged>{privileged}</Privileged>')
    return_values_reuse = get_enum_prop('ReturnValuesReuse', 'returnValuesReuse', 'DontUse')
    X(f'{i}<ReturnValuesReuse>{return_values_reuse}</ReturnValuesReuse>')

def emit_scheduled_job_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    method_name = str(defn['methodName']) if defn.get('methodName') else ''
    # Ensure CommonModule. prefix
    if method_name and not method_name.startswith('CommonModule.'):
        method_name = f'CommonModule.{method_name}'
    X(f'{i}<MethodName>{esc_xml(method_name)}</MethodName>')
    # Description — плоская строка (дефолт ПУСТО, не синоним — иначе роундтрип рвётся).
    description = str(defn['description']) if defn.get('description') else ''
    if description:
        X(f'{i}<Description>{esc_xml_text(description)}</Description>')
    else:
        X(f'{i}<Description/>')
    key = str(defn['key']) if defn.get('key') else ''
    X(f'{i}<Key>{esc_xml(key)}</Key>')
    use = 'true' if defn.get('use') is True else 'false'
    X(f'{i}<Use>{use}</Use>')
    predefined = 'true' if defn.get('predefined') is True else 'false'
    X(f'{i}<Predefined>{predefined}</Predefined>')
    restart_count = str(defn['restartCountOnFailure']) if defn.get('restartCountOnFailure') is not None else '3'
    restart_interval = str(defn['restartIntervalOnFailure']) if defn.get('restartIntervalOnFailure') is not None else '10'
    X(f'{i}<RestartCountOnFailure>{restart_count}</RestartCountOnFailure>')
    X(f'{i}<RestartIntervalOnFailure>{restart_interval}</RestartIntervalOnFailure>')

def emit_event_subscription_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    sources = list(defn.get('source', []))
    if sources:
        X(f'{i}<Source>')
        for src in sources:
            emit_type_content(f'{i}\t', resolve_type_str(str(src)))
        X(f'{i}</Source>')
    else:
        X(f'{i}<Source/>')
    event = str(defn['event']) if defn.get('event') else 'BeforeWrite'
    X(f'{i}<Event>{event}</Event>')
    handler = str(defn['handler']) if defn.get('handler') else ''
    # Ensure CommonModule. prefix
    if handler and not handler.startswith('CommonModule.'):
        handler = f'CommonModule.{handler}'
    X(f'{i}<Handler>{esc_xml(handler)}</Handler>')

# --- 13b. Report, DataProcessor ---

def emit_report_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(defn["comment"])}</Comment>')
    else:
        X(f'{i}<Comment/>')
    # UseStandardCommands: дефолт true (авторски-безопасно — доступность через стандартный командный интерфейс;
    # при false и без переопределения размещения команд объект доступен лишь по навигационной ссылке).
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    emit_verbatim_ref(i, 'DefaultForm', defn.get('defaultForm'))
    emit_verbatim_ref(i, 'AuxiliaryForm', defn.get('auxiliaryForm'))
    emit_verbatim_ref(i, 'MainDataCompositionSchema', defn.get('mainDataCompositionSchema'))
    emit_verbatim_ref(i, 'DefaultSettingsForm', defn.get('defaultSettingsForm'))
    emit_verbatim_ref(i, 'AuxiliarySettingsForm', defn.get('auxiliarySettingsForm'))
    emit_verbatim_ref(i, 'DefaultVariantForm', defn.get('defaultVariantForm'))
    emit_verbatim_ref(i, 'VariantsStorage', defn.get('variantsStorage'))
    emit_verbatim_ref(i, 'SettingsStorage', defn.get('settingsStorage'))
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    emit_mltext(i, 'ExtendedPresentation', defn.get('extendedPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

def emit_data_processor_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(defn["comment"])}</Comment>')
    else:
        X(f'{i}<Comment/>')
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    emit_verbatim_ref(i, 'DefaultForm', defn.get('defaultForm'))
    emit_verbatim_ref(i, 'AuxiliaryForm', defn.get('auxiliaryForm'))
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    emit_mltext(i, 'ExtendedPresentation', defn.get('extendedPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

# --- 13c. ExchangePlan, ChartOfCharacteristicTypes, DocumentJournal ---

def emit_exchange_plan_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '150'
    code_allowed_length = get_enum_prop('CodeAllowedLength', 'codeAllowedLength', 'Variable')
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<CodeAllowedLength>{code_allowed_length}</CodeAllowedLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<DefaultPresentation>{get_enum_prop("DefaultPresentation", "defaultPresentation", "AsDescription")}</DefaultPresentation>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    X(f'{i}<QuickChoice>{"true" if defn.get("quickChoice") is True else "false"}</QuickChoice>')
    X(f'{i}<ChoiceMode>{get_enum_prop("ChoiceMode", "choiceMode", "BothWays")}</ChoiceMode>')
    # InputByString: override `inputByString` ЛИБО дефолт [Descr при D>0]+[Code при C>0] (prefix ExchangePlan).
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = []
        if int(description_length) > 0:
            ib_fields.append(f'ExchangePlan.{obj_name}.StandardAttribute.Description')
        if int(code_length) > 0:
            ib_fields.append(f'ExchangePlan.{obj_name}.StandardAttribute.Code')
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    emit_standard_attributes(i, 'ExchangePlan')
    emit_characteristics(i, defn.get('characteristics'))
    emit_based_on(i, defn.get('basedOn'))
    distributed = 'true' if defn.get('distributedInfoBase') is True else 'false'
    include_ext = 'true' if defn.get('includeConfigurationExtensions') is True else 'false'
    X(f'{i}<DistributedInfoBase>{distributed}</DistributedInfoBase>')
    X(f'{i}<IncludeConfigurationExtensions>{include_ext}</IncludeConfigurationExtensions>')
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "DontUse")}</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    dl_fields = [expand_data_path(str(x)) for x in defn.get('dataLockFields', [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{"true" if get_bool_prop("updateDataHistoryImmediatelyAfterWrite", False) else "false"}</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{"true" if get_bool_prop("executeAfterWriteDataHistoryVersionProcessing", False) else "false"}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_chart_of_characteristic_types_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    if defn.get('characteristicExtValues'):
        X(f'{i}<CharacteristicExtValues>{esc_xml(str(defn["characteristicExtValues"]))}</CharacteristicExtValues>')
    else:
        X(f'{i}<CharacteristicExtValues/>')
    vt = defn.get('valueType')
    if not vt and defn.get('valueTypes'):
        vt = ' + '.join(defn['valueTypes'])
    if vt:
        X(f'{i}<Type>')
        emit_type_content(f'{i}\t', str(vt))
        X(f'{i}</Type>')
    else:
        X(f'{i}<Type>')
        X(f'{i}\t<v8:Type>xs:boolean</v8:Type>')
        X(f'{i}\t<v8:Type>xs:string</v8:Type>')
        X(f'{i}\t<v8:StringQualifiers>')
        X(f'{i}\t\t<v8:Length>100</v8:Length>')
        X(f'{i}\t\t<v8:AllowedLength>Variable</v8:AllowedLength>')
        X(f'{i}\t</v8:StringQualifiers>')
        X(f'{i}\t<v8:Type>xs:decimal</v8:Type>')
        X(f'{i}\t<v8:NumberQualifiers>')
        X(f'{i}\t\t<v8:Digits>15</v8:Digits>')
        X(f'{i}\t\t<v8:FractionDigits>2</v8:FractionDigits>')
        X(f'{i}\t\t<v8:AllowedSign>Any</v8:AllowedSign>')
        X(f'{i}\t</v8:NumberQualifiers>')
        X(f'{i}\t<v8:Type>xs:dateTime</v8:Type>')
        X(f'{i}\t<v8:DateQualifiers>')
        X(f'{i}\t\t<v8:DateFractions>DateTime</v8:DateFractions>')
        X(f'{i}\t</v8:DateQualifiers>')
        X(f'{i}</Type>')
    X(f'{i}<Hierarchical>{"true" if defn.get("hierarchical") is True else "false"}</Hierarchical>')
    X(f'{i}<FoldersOnTop>{"false" if defn.get("foldersOnTop") is False else "true"}</FoldersOnTop>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '100'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<CodeAllowedLength>{get_enum_prop("CodeAllowedLength", "codeAllowedLength", "Variable")}</CodeAllowedLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<CodeSeries>{get_enum_prop("CodeSeries", "codeSeries", "WholeCharacteristicKind")}</CodeSeries>')
    X(f'{i}<CheckUnique>{"false" if defn.get("checkUnique") is False else "true"}</CheckUnique>')
    X(f'{i}<Autonumbering>{"false" if defn.get("autonumbering") is False else "true"}</Autonumbering>')
    X(f'{i}<DefaultPresentation>{get_enum_prop("DefaultPresentation", "defaultPresentation", "AsDescription")}</DefaultPresentation>')
    emit_standard_attributes(i, 'ChartOfCharacteristicTypes')
    emit_characteristics(i, defn.get('characteristics'))
    X(f'{i}<PredefinedDataUpdate>{get_enum_prop("PredefinedDataUpdate", "predefinedDataUpdate", "Auto")}</PredefinedDataUpdate>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    X(f'{i}<QuickChoice>{"true" if defn.get("quickChoice") is True else "false"}</QuickChoice>')
    X(f'{i}<ChoiceMode>{get_enum_prop("ChoiceMode", "choiceMode", "BothWays")}</ChoiceMode>')
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = []
        if int(description_length) > 0:
            ib_fields.append(f'ChartOfCharacteristicTypes.{obj_name}.StandardAttribute.Description')
        if int(code_length) > 0:
            ib_fields.append(f'ChartOfCharacteristicTypes.{obj_name}.StandardAttribute.Code')
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "DontUse")}</CreateOnInput>')
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultFolderForm', defn.get('defaultFolderForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'DefaultFolderChoiceForm', defn.get('defaultFolderChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryFolderForm', defn.get('auxiliaryFolderForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    emit_form_ref(i, 'AuxiliaryFolderChoiceForm', defn.get('auxiliaryFolderChoiceForm'))
    emit_based_on(i, defn.get('basedOn'))
    dl_fields = [expand_data_path(str(x)) for x in defn.get('dataLockFields', [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{"true" if get_bool_prop("updateDataHistoryImmediatelyAfterWrite", False) else "false"}</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{"true" if get_bool_prop("executeAfterWriteDataHistoryVersionProcessing", False) else "false"}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_document_journal_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    emit_verbatim_ref(i, 'DefaultForm', defn.get('defaultForm'))
    emit_verbatim_ref(i, 'AuxiliaryForm', defn.get('auxiliaryForm'))
    use_std_cmds = 'true' if get_bool_prop('useStandardCommands', True) else 'false'
    X(f'{i}<UseStandardCommands>{use_std_cmds}</UseStandardCommands>')
    reg_docs = list(defn.get('registeredDocuments', []))
    if reg_docs:
        X(f'{i}<RegisteredDocuments>')
        for rd in reg_docs:
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml(normalize_md_object_ref(str(rd)))}</xr:Item>')
        X(f'{i}</RegisteredDocuments>')
    else:
        X(f'{i}<RegisteredDocuments/>')
    incl_help = 'true' if get_bool_prop('includeHelpInContents', False) else 'false'
    X(f'{i}<IncludeHelpInContents>{incl_help}</IncludeHelpInContents>')
    emit_standard_attributes(i, 'DocumentJournal')
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

def resolve_type_prefix_syn(ref):
    """Ссылка на объект: русский префикс типа → английский (ПланВидовХарактеристик.X → ChartOfCharacteristicTypes.X)."""
    if ref and '.' in ref:
        p, s = ref.split('.', 1)
        if p in object_type_synonyms:
            p = object_type_synonyms[p]
        return f'{p}.{s}'
    return ref

def emit_chart_of_accounts_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    emit_based_on(i, defn.get('basedOn'))
    # ExtDimensionTypes — ссылка на ПВХ видов субконто (прощающий ввод: ПланВидовХарактеристик.X → ChartOfCharacteristicTypes.X).
    ext_dim_types = resolve_type_prefix_syn(str(defn['extDimensionTypes'])) if defn.get('extDimensionTypes') else ''
    if ext_dim_types:
        X(f'{i}<ExtDimensionTypes>{esc_xml(ext_dim_types)}</ExtDimensionTypes>')
    else:
        X(f'{i}<ExtDimensionTypes/>')
    # Количество субконто: без ПВХ (extDimensionTypes) платформа не даёт > 0 → дефолт 0; с ПВХ — 3.
    max_ext_dim = str(defn['maxExtDimensionCount']) if defn.get('maxExtDimensionCount') is not None else ('3' if ext_dim_types else '0')
    X(f'{i}<MaxExtDimensionCount>{max_ext_dim}</MaxExtDimensionCount>')
    if defn.get('codeMask'):
        X(f'{i}<CodeMask>{esc_xml_text(str(defn["codeMask"]))}</CodeMask>')
    else:
        X(f'{i}<CodeMask/>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '9'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '25'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<CodeSeries>{get_enum_prop("CodeSeries", "codeSeries", "WholeChartOfAccounts")}</CodeSeries>')
    X(f'{i}<CheckUnique>{"false" if defn.get("checkUnique") is False else "true"}</CheckUnique>')
    X(f'{i}<DefaultPresentation>{get_enum_prop("DefaultPresentation", "defaultPresentation", "AsCode")}</DefaultPresentation>')
    emit_standard_attributes(i, 'ChartOfAccounts')
    emit_characteristics(i, defn.get('characteristics'))
    # StandardTabularSections — ExtDimensionTypes (обёртка платформенно-константна: Synonym с пустым lang «Виды субконто»,
    # Comment/ToolTip/FillChecking; 4 вложенных стандартных реквизита, ExtDimensionType → FillChecking=ShowError).
    X(f'{i}<StandardTabularSections>')
    X(f'{i}\t<xr:StandardTabularSection name="ExtDimensionTypes">')
    X(f'{i}\t\t<xr:Synonym>')
    X(f'{i}\t\t\t<v8:item>')
    X(f'{i}\t\t\t\t<v8:lang/>')
    X(f'{i}\t\t\t\t<v8:content>Виды субконто</v8:content>')
    X(f'{i}\t\t\t</v8:item>')
    X(f'{i}\t\t</xr:Synonym>')
    X(f'{i}\t\t<xr:Comment/>')
    X(f'{i}\t\t<xr:ToolTip/>')
    X(f'{i}\t\t<xr:FillChecking>DontCheck</xr:FillChecking>')
    X(f'{i}\t\t<xr:StandardAttributes>')
    for st_attr in ['TurnoversOnly', 'Predefined', 'ExtDimensionType', 'LineNumber']:
        st_ov = {'FillChecking': 'ShowError'} if st_attr == 'ExtDimensionType' else None
        emit_standard_attribute(f'{i}\t\t\t', st_attr, st_ov)
    X(f'{i}\t\t</xr:StandardAttributes>')
    X(f'{i}\t</xr:StandardTabularSection>')
    X(f'{i}</StandardTabularSections>')
    X(f'{i}<PredefinedDataUpdate>{get_enum_prop("PredefinedDataUpdate", "predefinedDataUpdate", "Auto")}</PredefinedDataUpdate>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    X(f'{i}<QuickChoice>{"true" if defn.get("quickChoice") is True else "false"}</QuickChoice>')
    X(f'{i}<ChoiceMode>{get_enum_prop("ChoiceMode", "choiceMode", "BothWays")}</ChoiceMode>')
    # InputByString: override ЛИБО дефолт [Descr при D>0]+[Code при C>0] (prefix ChartOfAccounts).
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = []
        if int(description_length) > 0:
            ib_fields.append(f'ChartOfAccounts.{obj_name}.StandardAttribute.Description')
        if int(code_length) > 0:
            ib_fields.append(f'ChartOfAccounts.{obj_name}.StandardAttribute.Code')
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "DontUse")}</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    auto_order = 'false' if defn.get('autoOrderByCode') is False else 'true'
    X(f'{i}<AutoOrderByCode>{auto_order}</AutoOrderByCode>')
    order_length = str(defn['orderLength']) if defn.get('orderLength') is not None else '9'
    X(f'{i}<OrderLength>{order_length}</OrderLength>')
    dl_fields = [expand_data_path(str(x)) for x in defn.get('dataLockFields', [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    upd_dh = 'true' if get_bool_prop('updateDataHistoryImmediatelyAfterWrite', False) else 'false'
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{upd_dh}</UpdateDataHistoryImmediatelyAfterWrite>')
    exec_dh = 'true' if get_bool_prop('executeAfterWriteDataHistoryVersionProcessing', False) else 'false'
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{exec_dh}</ExecuteAfterWriteDataHistoryVersionProcessing>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

def emit_accounting_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    chart_of_accounts = str(defn['chartOfAccounts']) if defn.get('chartOfAccounts') else ''
    if chart_of_accounts:
        X(f'{i}<ChartOfAccounts>{esc_xml(chart_of_accounts)}</ChartOfAccounts>')
    else:
        X(f'{i}<ChartOfAccounts/>')
    correspondence = 'true' if defn.get('correspondence') is True else 'false'
    X(f'{i}<Correspondence>{correspondence}</Correspondence>')
    period_adj_len = str(defn['periodAdjustmentLength']) if defn.get('periodAdjustmentLength') is not None else '0'
    X(f'{i}<PeriodAdjustmentLength>{period_adj_len}</PeriodAdjustmentLength>')
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_standard_attributes(i, 'AccountingRegister')
    data_lock_control_mode = get_enum_prop('DataLockControlMode', 'dataLockControlMode', 'Managed')
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    X(f'{i}<EnableTotalsSplitting>{"false" if defn.get("enableTotalsSplitting") is False else "true"}</EnableTotalsSplitting>')
    full_text_search = get_enum_prop('FullTextSearch', 'fullTextSearch', 'Use')
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

# Стандартные ТЧ ПВР: Ведущие/Вытесняющие/Базовые виды расчёта (обёртка платформенно-константна, пустой lang;
# вложены Predefined/CalculationType(ShowError)/LineNumber).
CALC_TYPES_STD_TABULAR = [
    ('LeadingCalculationTypes', 'Ведущие виды расчета'),
    ('DisplacingCalculationTypes', 'Вытесняющие виды расчета'),
    ('BaseCalculationTypes', 'Базовые виды расчета'),
]
def emit_calc_types_std_tabular(i):
    X(f'{i}<StandardTabularSections>')
    for name, syn in CALC_TYPES_STD_TABULAR:
        X(f'{i}\t<xr:StandardTabularSection name="{name}">')
        X(f'{i}\t\t<xr:Synonym>')
        X(f'{i}\t\t\t<v8:item>')
        X(f'{i}\t\t\t\t<v8:lang/>')
        X(f'{i}\t\t\t\t<v8:content>{esc_xml_text(syn)}</v8:content>')
        X(f'{i}\t\t\t</v8:item>')
        X(f'{i}\t\t</xr:Synonym>')
        X(f'{i}\t\t<xr:Comment/>')
        X(f'{i}\t\t<xr:ToolTip/>')
        X(f'{i}\t\t<xr:FillChecking>DontCheck</xr:FillChecking>')
        X(f'{i}\t\t<xr:StandardAttributes>')
        for st_attr in ('Predefined', 'CalculationType', 'LineNumber'):
            st_ov = {'FillChecking': 'ShowError'} if st_attr == 'CalculationType' else None
            emit_standard_attribute(f'{i}\t\t\t', st_attr, st_ov)
        X(f'{i}\t\t</xr:StandardAttributes>')
        X(f'{i}\t</xr:StandardTabularSection>')
    X(f'{i}</StandardTabularSections>')

def emit_chart_of_calculation_types_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    code_length = str(defn['codeLength']) if defn.get('codeLength') is not None else '5'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '100'
    X(f'{i}<CodeLength>{code_length}</CodeLength>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<CodeType>{get_enum_prop("CodeType", "codeType", "String")}</CodeType>')
    X(f'{i}<CodeAllowedLength>{get_enum_prop("CodeAllowedLength", "codeAllowedLength", "Variable")}</CodeAllowedLength>')
    X(f'{i}<DefaultPresentation>{get_enum_prop("DefaultPresentation", "defaultPresentation", "AsDescription")}</DefaultPresentation>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    X(f'{i}<QuickChoice>{"true" if defn.get("quickChoice") is True else "false"}</QuickChoice>')
    X(f'{i}<ChoiceMode>{get_enum_prop("ChoiceMode", "choiceMode", "BothWays")}</ChoiceMode>')
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = []
        if int(description_length) > 0:
            ib_fields.append(f'ChartOfCalculationTypes.{obj_name}.StandardAttribute.Description')
        if int(code_length) > 0:
            ib_fields.append(f'ChartOfCalculationTypes.{obj_name}.StandardAttribute.Code')
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "DontUse")}</CreateOnInput>')
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    emit_based_on(i, defn.get('basedOn'))
    X(f'{i}<DependenceOnCalculationTypes>{get_enum_prop("DependenceOnCalculationTypes", "dependenceOnCalculationTypes", "DontUse")}</DependenceOnCalculationTypes>')
    base_types = [resolve_type_prefix_syn(str(x)) for x in defn.get('baseCalculationTypes', [])]
    if base_types:
        X(f'{i}<BaseCalculationTypes>')
        for bt in base_types:
            X(f'{i}\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml(bt)}</xr:Item>')
        X(f'{i}</BaseCalculationTypes>')
    else:
        X(f'{i}<BaseCalculationTypes/>')
    X(f'{i}<ActionPeriodUse>{"true" if defn.get("actionPeriodUse") is True else "false"}</ActionPeriodUse>')
    emit_standard_attributes(i, 'ChartOfCalculationTypes')
    emit_characteristics(i, defn.get('characteristics'))
    emit_calc_types_std_tabular(i)
    X(f'{i}<PredefinedDataUpdate>{get_enum_prop("PredefinedDataUpdate", "predefinedDataUpdate", "Auto")}</PredefinedDataUpdate>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    dl_fields = [expand_data_path(str(x)) for x in defn.get('dataLockFields', [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{"true" if get_bool_prop("updateDataHistoryImmediatelyAfterWrite", False) else "false"}</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{"true" if get_bool_prop("executeAfterWriteDataHistoryVersionProcessing", False) else "false"}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_calculation_register_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    periodicity = get_enum_prop('InformationRegisterPeriodicity', 'periodicity', 'Month')
    X(f'{i}<Periodicity>{periodicity}</Periodicity>')
    action_period = 'true' if defn.get('actionPeriod') is True else 'false'
    X(f'{i}<ActionPeriod>{action_period}</ActionPeriod>')
    base_period = 'true' if defn.get('basePeriod') is True else 'false'
    X(f'{i}<BasePeriod>{base_period}</BasePeriod>')
    schedule = str(defn['schedule']) if defn.get('schedule') else ''
    if schedule:
        X(f'{i}<Schedule>{esc_xml(schedule)}</Schedule>')
    else:
        X(f'{i}<Schedule/>')
    schedule_value = str(defn['scheduleValue']) if defn.get('scheduleValue') else ''
    if schedule_value:
        X(f'{i}<ScheduleValue>{esc_xml(schedule_value)}</ScheduleValue>')
    else:
        X(f'{i}<ScheduleValue/>')
    schedule_date = str(defn['scheduleDate']) if defn.get('scheduleDate') else ''
    if schedule_date:
        X(f'{i}<ScheduleDate>{esc_xml(schedule_date)}</ScheduleDate>')
    else:
        X(f'{i}<ScheduleDate/>')
    chart_of_calc_types = str(defn['chartOfCalculationTypes']) if defn.get('chartOfCalculationTypes') else ''
    if chart_of_calc_types:
        X(f'{i}<ChartOfCalculationTypes>{esc_xml(chart_of_calc_types)}</ChartOfCalculationTypes>')
    else:
        X(f'{i}<ChartOfCalculationTypes/>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    emit_standard_attributes(i, 'CalculationRegister')
    data_lock_control_mode = get_enum_prop('DataLockControlMode', 'dataLockControlMode', 'Managed')
    X(f'{i}<DataLockControlMode>{data_lock_control_mode}</DataLockControlMode>')
    full_text_search = get_enum_prop('FullTextSearch', 'fullTextSearch', 'Use')
    X(f'{i}<FullTextSearch>{full_text_search}</FullTextSearch>')
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))

def emit_business_process_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = [f'BusinessProcess.{obj_name}.StandardAttribute.Number']
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "DontUse")}</CreateOnInput>')
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    number_type = get_enum_prop('NumberType', 'numberType', 'String')
    number_length = str(defn['numberLength']) if defn.get('numberLength') is not None else '11'
    number_allowed_length = get_enum_prop('NumberAllowedLength', 'numberAllowedLength', 'Variable')
    check_unique = 'false' if defn.get('checkUnique') is False else 'true'
    X(f'{i}<NumberType>{number_type}</NumberType>')
    X(f'{i}<NumberLength>{number_length}</NumberLength>')
    X(f'{i}<NumberAllowedLength>{number_allowed_length}</NumberAllowedLength>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    emit_standard_attributes(i, 'BusinessProcess')
    emit_characteristics(i, defn.get('characteristics'))
    X(f'{i}<Autonumbering>{"false" if defn.get("autonumbering") is False else "true"}</Autonumbering>')
    emit_based_on(i, defn.get('basedOn'))
    X(f'{i}<NumberPeriodicity>{get_enum_prop("NumberPeriodicity", "numberPeriodicity", "Nonperiodical")}</NumberPeriodicity>')
    task_ref = str(defn['task']) if defn.get('task') else ''
    if task_ref:
        X(f'{i}<Task>{esc_xml(task_ref)}</Task>')
    else:
        X(f'{i}<Task/>')
    X(f'{i}<CreateTaskInPrivilegedMode>{"true" if get_bool_prop("createTaskInPrivilegedMode", True) else "false"}</CreateTaskInPrivilegedMode>')
    dl_fields = [expand_data_path(str(x)) for x in defn.get('dataLockFields', [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{"true" if get_bool_prop("updateDataHistoryImmediatelyAfterWrite", False) else "false"}</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{"true" if get_bool_prop("executeAfterWriteDataHistoryVersionProcessing", False) else "false"}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_task_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    if defn.get('comment'):
        X(f'{i}<Comment>{esc_xml_text(str(defn["comment"]))}</Comment>')
    else:
        X(f'{i}<Comment/>')
    X(f'{i}<UseStandardCommands>{"true" if get_bool_prop("useStandardCommands", True) else "false"}</UseStandardCommands>')
    number_type = get_enum_prop('NumberType', 'numberType', 'String')
    number_length = str(defn['numberLength']) if defn.get('numberLength') is not None else '14'
    number_allowed_length = get_enum_prop('NumberAllowedLength', 'numberAllowedLength', 'Variable')
    check_unique = 'false' if defn.get('checkUnique') is False else 'true'
    autonumbering = 'false' if defn.get('autonumbering') is False else 'true'
    task_number_auto_prefix = str(defn['taskNumberAutoPrefix']) if defn.get('taskNumberAutoPrefix') else 'BusinessProcessNumber'
    description_length = str(defn['descriptionLength']) if defn.get('descriptionLength') is not None else '150'
    X(f'{i}<NumberType>{number_type}</NumberType>')
    X(f'{i}<NumberLength>{number_length}</NumberLength>')
    X(f'{i}<NumberAllowedLength>{number_allowed_length}</NumberAllowedLength>')
    X(f'{i}<CheckUnique>{check_unique}</CheckUnique>')
    X(f'{i}<Autonumbering>{autonumbering}</Autonumbering>')
    X(f'{i}<TaskNumberAutoPrefix>{task_number_auto_prefix}</TaskNumberAutoPrefix>')
    X(f'{i}<DescriptionLength>{description_length}</DescriptionLength>')
    X(f'{i}<Addressing>{esc_xml(str(defn["addressing"]))}</Addressing>' if defn.get('addressing') else f'{i}<Addressing/>')
    X(f'{i}<MainAddressingAttribute>{esc_xml(str(defn["mainAddressingAttribute"]))}</MainAddressingAttribute>' if defn.get('mainAddressingAttribute') else f'{i}<MainAddressingAttribute/>')
    X(f'{i}<CurrentPerformer>{esc_xml(str(defn["currentPerformer"]))}</CurrentPerformer>' if defn.get('currentPerformer') else f'{i}<CurrentPerformer/>')
    emit_based_on(i, defn.get('basedOn'))
    emit_standard_attributes(i, 'Task')
    emit_characteristics(i, defn.get('characteristics'))
    X(f'{i}<DefaultPresentation>{get_enum_prop("DefaultPresentation", "defaultPresentation", "AsDescription")}</DefaultPresentation>')
    X(f'{i}<EditType>{get_enum_prop("EditType", "editType", "InDialog")}</EditType>')
    if 'inputByString' in defn:
        ib_fields = [expand_data_path(str(x)) for x in (defn.get('inputByString') or [])]
    else:
        ib_fields = [f'Task.{obj_name}.StandardAttribute.Number']
    emit_field_block(i, 'InputByString', ib_fields)
    X(f'{i}<SearchStringModeOnInputByString>{get_enum_prop("SearchStringModeOnInputByString", "searchStringModeOnInputByString", "Begin")}</SearchStringModeOnInputByString>')
    X(f'{i}<FullTextSearchOnInputByString>{get_enum_prop("FullTextSearchOnInputByString", "fullTextSearchOnInputByString", "DontUse")}</FullTextSearchOnInputByString>')
    X(f'{i}<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>')
    X(f'{i}<CreateOnInput>{get_enum_prop("CreateOnInput", "createOnInput", "DontUse")}</CreateOnInput>')
    emit_form_ref(i, 'DefaultObjectForm', defn.get('defaultObjectForm'))
    emit_form_ref(i, 'DefaultListForm', defn.get('defaultListForm'))
    emit_form_ref(i, 'DefaultChoiceForm', defn.get('defaultChoiceForm'))
    emit_form_ref(i, 'AuxiliaryObjectForm', defn.get('auxiliaryObjectForm'))
    emit_form_ref(i, 'AuxiliaryListForm', defn.get('auxiliaryListForm'))
    emit_form_ref(i, 'AuxiliaryChoiceForm', defn.get('auxiliaryChoiceForm'))
    X(f'{i}<ChoiceHistoryOnInput>{get_enum_prop("ChoiceHistoryOnInput", "choiceHistoryOnInput", "Auto")}</ChoiceHistoryOnInput>')
    X(f'{i}<IncludeHelpInContents>{"true" if get_bool_prop("includeHelpInContents", False) else "false"}</IncludeHelpInContents>')
    dl_fields = [expand_data_path(str(x)) for x in defn.get('dataLockFields', [])] if 'dataLockFields' in defn else []
    emit_field_block(i, 'DataLockFields', dl_fields)
    X(f'{i}<DataLockControlMode>{get_enum_prop("DataLockControlMode", "dataLockControlMode", "Managed")}</DataLockControlMode>')
    X(f'{i}<FullTextSearch>{get_enum_prop("FullTextSearch", "fullTextSearch", "Use")}</FullTextSearch>')
    emit_mltext(i, 'ObjectPresentation', defn.get('objectPresentation'))
    emit_mltext(i, 'ExtendedObjectPresentation', defn.get('extendedObjectPresentation'))
    emit_mltext(i, 'ListPresentation', defn.get('listPresentation'))
    emit_mltext(i, 'ExtendedListPresentation', defn.get('extendedListPresentation'))
    emit_mltext(i, 'Explanation', defn.get('explanation'))
    X(f'{i}<DataHistory>{get_enum_prop("DataHistory", "dataHistory", "DontUse")}</DataHistory>')
    X(f'{i}<UpdateDataHistoryImmediatelyAfterWrite>{"true" if get_bool_prop("updateDataHistoryImmediatelyAfterWrite", False) else "false"}</UpdateDataHistoryImmediatelyAfterWrite>')
    X(f'{i}<ExecuteAfterWriteDataHistoryVersionProcessing>{"true" if get_bool_prop("executeAfterWriteDataHistoryVersionProcessing", False) else "false"}</ExecuteAfterWriteDataHistoryVersionProcessing>')

def emit_http_service_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    root_url = str(defn['rootURL']) if defn.get('rootURL') else obj_name.lower()
    X(f'{i}<RootURL>{esc_xml(root_url)}</RootURL>')
    reuse_sessions = get_enum_prop('ReuseSessions', 'reuseSessions', 'DontUse')
    X(f'{i}<ReuseSessions>{reuse_sessions}</ReuseSessions>')
    session_max_age = str(defn['sessionMaxAge']) if defn.get('sessionMaxAge') is not None else '20'
    X(f'{i}<SessionMaxAge>{session_max_age}</SessionMaxAge>')

def emit_web_service_properties(indent):
    i = indent
    X(f'{i}<Name>{esc_xml(obj_name)}</Name>')
    emit_mltext(i, 'Synonym', synonym)
    X(f'{i}<Comment/>')
    namespace = str(defn['namespace']) if defn.get('namespace') else ''
    X(f'{i}<Namespace>{esc_xml(namespace)}</Namespace>')
    xdto_packages = str(defn['xdtoPackages']) if defn.get('xdtoPackages') else ''
    if xdto_packages:
        X(f'{i}<XDTOPackages>{xdto_packages}</XDTOPackages>')
    else:
        X(f'{i}<XDTOPackages/>')
    reuse_sessions = get_enum_prop('ReuseSessions', 'reuseSessions', 'DontUse')
    X(f'{i}<ReuseSessions>{reuse_sessions}</ReuseSessions>')
    session_max_age = str(defn['sessionMaxAge']) if defn.get('sessionMaxAge') is not None else '20'
    X(f'{i}<SessionMaxAge>{session_max_age}</SessionMaxAge>')


# --- 13g. ChildObjects emitters for new types ---

def emit_column(indent, col_def):
    uid = new_uuid()
    name = ''
    col_synonym = None
    comment = ''
    indexing = 'DontIndex'
    references = []
    if isinstance(col_def, str):
        name = col_def
        col_synonym = split_camel_case(name)
    else:
        name = str(col_def.get('name', ''))
        col_synonym = col_def['synonym'] if col_def.get('synonym') is not None else split_camel_case(name)  # строка ИЛИ {ru,en}
        if col_def.get('comment'):
            comment = str(col_def['comment'])
        if col_def.get('indexing'):
            indexing = str(col_def['indexing'])
        if col_def.get('references'):
            references = list(col_def['references'])
    X(f'{indent}<Column uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', col_synonym)
    if comment:
        X(f'{indent}\t\t<Comment>{esc_xml_text(comment)}</Comment>')
    else:
        X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t\t<Indexing>{indexing}</Indexing>')
    if references:
        X(f'{indent}\t\t<References>')
        for ref in references:
            X(f'{indent}\t\t\t<xr:Item xsi:type="xr:MDObjectRef">{esc_xml(normalize_md_object_ref(str(ref)))}</xr:Item>')
        X(f'{indent}\t\t</References>')
    else:
        X(f'{indent}\t\t<References/>')
    X(f'{indent}\t</Properties>')
    X(f'{indent}</Column>')

def emit_url_template(indent, tmpl_name, tmpl_def):
    uid = new_uuid()
    tmpl_synonym = split_camel_case(tmpl_name)
    template = ''
    methods = {}
    if isinstance(tmpl_def, str):
        template = tmpl_def
    else:
        template = str(tmpl_def['template']) if tmpl_def.get('template') else f'/{tmpl_name.lower()}'
        if tmpl_def.get('methods'):
            for k, v in tmpl_def['methods'].items():
                methods[k] = str(v)
    X(f'{indent}<URLTemplate uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(tmpl_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', tmpl_synonym)
    X(f'{indent}\t\t<Template>{esc_xml(template)}</Template>')
    X(f'{indent}\t</Properties>')
    if methods:
        X(f'{indent}\t<ChildObjects>')
        for method_name, http_method in sorted(methods.items()):
            method_uuid = new_uuid()
            method_synonym = split_camel_case(method_name)
            handler = f'{tmpl_name}{method_name}'
            X(f'{indent}\t\t<Method uuid="{method_uuid}">')
            X(f'{indent}\t\t\t<Properties>')
            X(f'{indent}\t\t\t\t<Name>{esc_xml(method_name)}</Name>')
            emit_mltext(f'{indent}\t\t\t\t', 'Synonym', method_synonym)
            X(f'{indent}\t\t\t\t<HTTPMethod>{http_method}</HTTPMethod>')
            X(f'{indent}\t\t\t\t<Handler>{esc_xml(handler)}</Handler>')
            X(f'{indent}\t\t\t</Properties>')
            X(f'{indent}\t\t</Method>')
        X(f'{indent}\t</ChildObjects>')
    else:
        X(f'{indent}\t<ChildObjects/>')
    X(f'{indent}</URLTemplate>')

def emit_operation(indent, op_name, op_def):
    uid = new_uuid()
    op_synonym = split_camel_case(op_name)
    return_type = 'xs:string'
    nillable = 'false'
    transactioned = 'false'
    handler = op_name
    params = {}
    if isinstance(op_def, str):
        return_type = op_def
    else:
        if op_def.get('returnType'):
            return_type = str(op_def['returnType'])
        if op_def.get('nillable') is True:
            nillable = 'true'
        if op_def.get('transactioned') is True:
            transactioned = 'true'
        if op_def.get('handler'):
            handler = str(op_def['handler'])
        if op_def.get('parameters'):
            for k, v in op_def['parameters'].items():
                params[k] = v
    X(f'{indent}<Operation uuid="{uid}">')
    X(f'{indent}\t<Properties>')
    X(f'{indent}\t\t<Name>{esc_xml(op_name)}</Name>')
    emit_mltext(f'{indent}\t\t', 'Synonym', op_synonym)
    X(f'{indent}\t\t<Comment/>')
    X(f'{indent}\t\t<XDTOReturningValueType>{return_type}</XDTOReturningValueType>')
    X(f'{indent}\t\t<Nillable>{nillable}</Nillable>')
    X(f'{indent}\t\t<Transactioned>{transactioned}</Transactioned>')
    X(f'{indent}\t\t<ProcedureName>{esc_xml(handler)}</ProcedureName>')
    X(f'{indent}\t</Properties>')
    if params:
        X(f'{indent}\t<ChildObjects>')
        for param_name, param_def in sorted(params.items()):
            param_uuid = new_uuid()
            param_synonym = split_camel_case(param_name)
            param_type = 'xs:string'
            param_nillable = 'true'
            param_dir = 'In'
            if isinstance(param_def, str):
                param_type = param_def
            else:
                if param_def.get('type'):
                    param_type = str(param_def['type'])
                if param_def.get('nillable') is False:
                    param_nillable = 'false'
                if param_def.get('direction'):
                    param_dir = str(param_def['direction'])
            X(f'{indent}\t\t<Parameter uuid="{param_uuid}">')
            X(f'{indent}\t\t\t<Properties>')
            X(f'{indent}\t\t\t\t<Name>{esc_xml(param_name)}</Name>')
            emit_mltext(f'{indent}\t\t\t\t', 'Synonym', param_synonym)
            X(f'{indent}\t\t\t\t<XDTOValueType>{param_type}</XDTOValueType>')
            X(f'{indent}\t\t\t\t<Nillable>{param_nillable}</Nillable>')
            X(f'{indent}\t\t\t\t<TransferDirection>{param_dir}</TransferDirection>')
            X(f'{indent}\t\t\t</Properties>')
            X(f'{indent}\t\t</Parameter>')
        X(f'{indent}\t</ChildObjects>')
    else:
        X(f'{indent}\t<ChildObjects/>')
    X(f'{indent}</Operation>')

def emit_addressing_attribute(indent, addr_def):
    # Реквизит адресации = полный object-слой реквизита (контекст task-addressing) + AddressingDimension.
    parsed = parse_attribute_shorthand(addr_def)
    emit_attribute(indent, parsed, 'task-addressing', 'AddressingAttribute')

# ---------------------------------------------------------------------------
# 14. Namespaces
# ---------------------------------------------------------------------------

xmlns_decl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

# ---------------------------------------------------------------------------
# 14a. Detect format version from existing Configuration.xml
# ---------------------------------------------------------------------------

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

format_version = detect_format_version(output_dir)

# ---------------------------------------------------------------------------
# 15. Main assembler
# ---------------------------------------------------------------------------

obj_uuid = new_uuid()

X('<?xml version="1.0" encoding="UTF-8"?>')
X(f'<MetaDataObject {xmlns_decl} version="{format_version}">')
X(f'\t<{obj_type} uuid="{obj_uuid}">')

# InternalInfo
emit_internal_info('\t\t', obj_type, obj_name)

# Properties
X('\t\t<Properties>')

property_emitters = {
    'Catalog': emit_catalog_properties,
    'Document': emit_document_properties,
    'Enum': emit_enum_properties,
    'Constant': emit_constant_properties,
    'InformationRegister': emit_information_register_properties,
    'AccumulationRegister': emit_accumulation_register_properties,
    'DefinedType': emit_defined_type_properties,
    'FunctionalOption': emit_functional_option_properties,
    'Sequence': emit_sequence_properties,
    'FilterCriterion': emit_filter_criterion_properties,
    'DocumentNumerator': emit_document_numerator_properties,
    'SettingsStorage': emit_settings_storage_properties,
    'CommonForm': emit_common_form_properties,
    'SessionParameter': emit_session_parameter_properties,
    'CommonCommand': emit_common_command_properties,
    'CommandGroup': emit_command_group_properties,
    'CommonAttribute': emit_common_attribute_properties,
    'FunctionalOptionsParameter': emit_functional_options_parameter_properties,
    'WSReference': emit_ws_reference_properties,
    'CommonPicture': emit_common_picture_properties,
    'CommonTemplate': emit_common_template_properties,
    'CommonModule': emit_common_module_properties,
    'ScheduledJob': emit_scheduled_job_properties,
    'EventSubscription': emit_event_subscription_properties,
    'Report': emit_report_properties,
    'DataProcessor': emit_data_processor_properties,
    'ExchangePlan': emit_exchange_plan_properties,
    'ChartOfCharacteristicTypes': emit_chart_of_characteristic_types_properties,
    'DocumentJournal': emit_document_journal_properties,
    'ChartOfAccounts': emit_chart_of_accounts_properties,
    'AccountingRegister': emit_accounting_register_properties,
    'ChartOfCalculationTypes': emit_chart_of_calculation_types_properties,
    'CalculationRegister': emit_calculation_register_properties,
    'BusinessProcess': emit_business_process_properties,
    'Task': emit_task_properties,
    'HTTPService': emit_http_service_properties,
    'WebService': emit_web_service_properties,
}

property_emitters[obj_type]('\t\t\t')

X('\t\t</Properties>')

# ChildObjects
has_children = False

# --- Types with Attributes + TabularSections ---
types_with_attr_ts = [
    'Catalog', 'Document', 'Report', 'DataProcessor', 'ExchangePlan',
    'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes',
    'BusinessProcess', 'Task',
]

commands = []   # заполняется внутри блока types_with_attr_ts; на уровне модуля для записи модулей команд
if obj_type in types_with_attr_ts:
    def _as_list(val):
        """Normalize attributes: dict {"K":"V"} → ["K:V"], list/other → list."""
        if val is None:
            return []
        if isinstance(val, dict):
            return [f"{k}:{v}" for k, v in val.items()]
        return list(val)

    attrs = []
    if defn.get('attributes'):
        for a in _as_list(defn['attributes']):
            attrs.append(parse_attribute_shorthand(a))
    ts_sections = {}
    ts_order = []
    if defn.get('tabularSections'):
        ts_data = defn['tabularSections']
        # Значение ТЧ: массив колонок (синоним авто) ЛИБО объект {attributes/columns, synonym, tooltip, comment}.
        def new_ts_entry(val):
            if isinstance(val, list):
                return {'columns': val, 'synonym': None, 'tooltip': None, 'comment': None, 'lineNumber': None, 'fillChecking': None, 'use': None}
            cols = _as_list(val.get('attributes') or val.get('columns') or [])
            return {'columns': cols, 'synonym': val.get('synonym'), 'tooltip': val.get('tooltip'),
                    'comment': str(val['comment']) if val.get('comment') else None, 'lineNumber': val.get('lineNumber'), 'fillChecking': val.get('fillChecking'), 'use': val.get('use')}
        if isinstance(ts_data, list):
            for ts in ts_data:
                ts_sections[ts['name']] = new_ts_entry(ts)
                ts_order.append(ts['name'])
        else:
            for k, v in ts_data.items():
                ts_sections[k] = new_ts_entry(v)
                ts_order.append(k)
    # ChartOfAccounts: AccountingFlags + ExtDimensionAccountingFlags (признаки учёта — структурно как реквизит,
    # но без Indexing/FullTextSearch/Use; тип по умолчанию Boolean). Парсим как реквизиты.
    acct_flags = []
    ext_dim_flags = []
    if obj_type == 'ChartOfAccounts':
        if defn.get('accountingFlags'):
            acct_flags = [parse_attribute_shorthand(af) for af in _as_list(defn['accountingFlags'])]
        if defn.get('extDimensionAccountingFlags'):
            ext_dim_flags = [parse_attribute_shorthand(edf) for edf in _as_list(defn['extDimensionAccountingFlags'])]
    # Task: AddressingAttributes
    addr_attrs = []
    if obj_type == 'Task' and defn.get('addressingAttributes'):
        addr_attrs = _as_list(defn['addressingAttributes'])
    # Commands (map имя→объект ИЛИ array [{name,...}])
    commands = []
    if defn.get('commands'):
        cd = defn['commands']
        if isinstance(cd, list):
            for c in cd:
                commands.append({'name': str(c.get('name', '')), 'def': c})
        else:
            for k, v in cd.items():
                commands.append({'name': k, 'def': v})
    child_count = len(attrs) + len(ts_sections) + len(acct_flags) + len(ext_dim_flags) + len(addr_attrs) + len(commands)
    if child_count > 0:
        has_children = True
        X('\t\t<ChildObjects>')
        if obj_type == 'Catalog':
            context = 'catalog'
        elif obj_type == 'Document':
            context = 'document'
        elif obj_type in ('DataProcessor', 'Report'):
            context = 'processor'
        elif obj_type == 'ChartOfCharacteristicTypes':
            context = 'catalog'   # реквизиты ПВХ структурно как у справочника (Use/FillFromFillingValue/DataHistory)
        elif obj_type in ('ChartOfAccounts', 'ChartOfCalculationTypes'):
            context = 'account'   # как catalog, но БЕЗ <Use> (реквизиты ПС/ПВР не иерархичны как справочник)
        else:
            context = 'object'
        for a in attrs:
            emit_attribute('\t\t\t', a, context)
        for ts_name in ts_order:
            e = ts_sections[ts_name]
            emit_tabular_section('\t\t\t', ts_name, e['columns'], obj_type, obj_name, e['synonym'], e['tooltip'], e['comment'], e.get('lineNumber'), e.get('fillChecking'), e.get('use'))
        for af in acct_flags:
            emit_attribute('\t\t\t', af, 'account-flag', 'AccountingFlag')
        for edf in ext_dim_flags:
            emit_attribute('\t\t\t', edf, 'account-flag', 'ExtDimensionAccountingFlag')
        for aa in addr_attrs:
            emit_addressing_attribute('\t\t\t', aa)
        for cmd in commands:
            emit_command('\t\t\t', cmd['name'], cmd['def'])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- Enum: enum values ---
if obj_type == 'Enum':
    values = []
    if defn.get('values'):
        for v in defn['values']:
            values.append(parse_enum_value_shorthand(v))
    if values:
        has_children = True
        X('\t\t<ChildObjects>')
        for v in values:
            emit_enum_value('\t\t\t', v)
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- Constant, DefinedType, ScheduledJob, EventSubscription: no ChildObjects ---

# --- Registers: dimensions + resources + attributes ---
if obj_type in ('InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister'):
    dims = []
    resources = []
    reg_attrs = []
    if defn.get('dimensions'):
        for d in defn['dimensions']:
            dims.append(parse_attribute_shorthand(d))
    if defn.get('resources'):
        for r in defn['resources']:
            resources.append(parse_attribute_shorthand(r))
    if defn.get('attributes'):
        for a in defn['attributes']:
            reg_attrs.append(parse_attribute_shorthand(a))
    reg_commands = []
    if defn.get('commands'):
        cd = defn['commands']
        if isinstance(cd, list):
            for c in cd:
                reg_commands.append({'name': str(c.get('name', '')), 'def': c})
        else:
            for k, v in cd.items():
                reg_commands.append({'name': k, 'def': v})
    if dims or resources or reg_attrs or reg_commands:
        has_children = True
        X('\t\t<ChildObjects>')
        # InformationRegister.Attribute несёт FillFromFillingValue/FillValue/DataHistory; CalculationRegister.Attribute
        # несёт <ScheduleLink> (register-calc); прочие — register-other.
        reg_ctx = {'InformationRegister': 'register-info', 'CalculationRegister': 'register-calc'}.get(obj_type, 'register-other')
        # Все семейства регистров: ресурсы/измерения — через богатый emit_attribute (общий слой object-свойств).
        dim_res_ctx = {'InformationRegister': 'register-info', 'AccumulationRegister': 'register-accum',
                       'CalculationRegister': 'register-calc', 'AccountingRegister': 'register-account'}.get(obj_type)
        for r in resources:
            if dim_res_ctx:
                emit_attribute('\t\t\t', r, dim_res_ctx, 'Resource')
            else:
                emit_resource('\t\t\t', r, obj_type)
        for d in dims:
            if dim_res_ctx:
                emit_attribute('\t\t\t', d, dim_res_ctx, 'Dimension')
            else:
                emit_dimension('\t\t\t', d, obj_type)
        for a in reg_attrs:
            emit_attribute('\t\t\t', a, reg_ctx)
        for cmd in reg_commands:
            emit_command('\t\t\t', cmd['name'], cmd['def'])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- DocumentJournal: columns + commands ---
if obj_type == 'DocumentJournal':
    columns = list(defn.get('columns', []))
    dj_commands = []
    if defn.get('commands'):
        cd = defn['commands']
        if isinstance(cd, list):
            for c in cd:
                dj_commands.append({'name': str(c.get('name', '')), 'def': c})
        else:
            for k, v in cd.items():
                dj_commands.append({'name': k, 'def': v})
    if columns or dj_commands:
        has_children = True
        X('\t\t<ChildObjects>')
        for col in columns:
            emit_column('\t\t\t', col)
        for cmd in dj_commands:
            emit_command('\t\t\t', cmd['name'], cmd['def'])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- Sequence: dimensions ---
if obj_type == 'Sequence':
    seq_dims = list(defn.get('dimensions', []))
    if seq_dims:
        has_children = True
        X('\t\t<ChildObjects>')
        for d in seq_dims:
            emit_sequence_dimension('\t\t\t', d)
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- FilterCriterion / SettingsStorage: ChildObjects (формы стрипаются; FilterCriterion может нести <Command>) ---
if obj_type in ('FilterCriterion', 'SettingsStorage'):
    fc_commands = []
    if defn.get('commands'):
        cd = defn['commands']
        if isinstance(cd, list):
            for c in cd:
                fc_commands.append({'name': str(c.get('name', '')), 'def': c})
        else:
            for k, v in cd.items():
                fc_commands.append({'name': k, 'def': v})
    if fc_commands:
        has_children = True
        X('\t\t<ChildObjects>')
        for cmd in fc_commands:
            emit_command('\t\t\t', cmd['name'], cmd['def'])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')
# DocumentNumerator: ChildObjects нет вовсе (не эмитим).

# --- HTTPService: URLTemplates ---
if obj_type == 'HTTPService':
    url_templates = {}
    url_tmpl_order = []
    if defn.get('urlTemplates'):
        for k, v in defn['urlTemplates'].items():
            url_templates[k] = v
            url_tmpl_order.append(k)
    if url_templates:
        has_children = True
        X('\t\t<ChildObjects>')
        for tmpl_name in sorted(url_tmpl_order):
            emit_url_template('\t\t\t', tmpl_name, url_templates[tmpl_name])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- WebService: Operations ---
if obj_type == 'WebService':
    operations = {}
    op_order = []
    if defn.get('operations'):
        for k, v in defn['operations'].items():
            operations[k] = v
            op_order.append(k)
    if operations:
        has_children = True
        X('\t\t<ChildObjects>')
        for op_name in sorted(op_order):
            emit_operation('\t\t\t', op_name, operations[op_name])
        X('\t\t</ChildObjects>')
    else:
        X('\t\t<ChildObjects/>')

# --- CommonModule: no ChildObjects ---

X(f'\t</{obj_type}>')
X('</MetaDataObject>')

metadata_xml = '\n'.join(lines) + '\n'

# ---------------------------------------------------------------------------
# 16. Write files
# ---------------------------------------------------------------------------

type_plural_map = {
    'Catalog': 'Catalogs',
    'Document': 'Documents',
    'Enum': 'Enums',
    'Constant': 'Constants',
    'InformationRegister': 'InformationRegisters',
    'AccumulationRegister': 'AccumulationRegisters',
    'AccountingRegister': 'AccountingRegisters',
    'CalculationRegister': 'CalculationRegisters',
    'ChartOfAccounts': 'ChartsOfAccounts',
    'ChartOfCharacteristicTypes': 'ChartsOfCharacteristicTypes',
    'ChartOfCalculationTypes': 'ChartsOfCalculationTypes',
    'BusinessProcess': 'BusinessProcesses',
    'Task': 'Tasks',
    'ExchangePlan': 'ExchangePlans',
    'DocumentJournal': 'DocumentJournals',
    'Report': 'Reports',
    'DataProcessor': 'DataProcessors',
    'CommonModule': 'CommonModules',
    'ScheduledJob': 'ScheduledJobs',
    'EventSubscription': 'EventSubscriptions',
    'HTTPService': 'HTTPServices',
    'WebService': 'WebServices',
    'DefinedType': 'DefinedTypes',
    'FunctionalOption': 'FunctionalOptions',
    'Sequence': 'Sequences',
    'FilterCriterion': 'FilterCriteria',
    'DocumentNumerator': 'DocumentNumerators',
    'SettingsStorage': 'SettingsStorages',
    'CommonForm': 'CommonForms',
    'SessionParameter': 'SessionParameters',
    'CommonCommand': 'CommonCommands',
    'CommandGroup': 'CommandGroups',
    'CommonAttribute': 'CommonAttributes',
    'FunctionalOptionsParameter': 'FunctionalOptionsParameters',
    'WSReference': 'WSReferences',
    'CommonPicture': 'CommonPictures',
    'CommonTemplate': 'CommonTemplates',
}

type_plural = type_plural_map[obj_type]
type_dir = os.path.join(output_dir, type_plural)

# Main XML file
main_xml_path = os.path.join(type_dir, f'{obj_name}.xml')

# Types that don't have subdirectory structure
types_no_sub_dir = ['DefinedType', 'ScheduledJob', 'EventSubscription']

obj_sub_dir = os.path.join(type_dir, obj_name)
ext_dir = os.path.join(obj_sub_dir, 'Ext')

os.makedirs(type_dir, exist_ok=True)
if obj_type not in types_no_sub_dir:
    os.makedirs(obj_sub_dir, exist_ok=True)

write_utf8_bom(main_xml_path, metadata_xml)

# Module files
modules_created = []

types_with_object_module = [
    'Catalog', 'Document', 'Report', 'DataProcessor', 'ExchangePlan',
    'ChartOfAccounts', 'ChartOfCharacteristicTypes', 'ChartOfCalculationTypes',
    'BusinessProcess', 'Task',
]
types_with_record_set_module = [
    'InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister',
]
types_with_manager_module = ['Report', 'DataProcessor', 'Constant', 'Enum']
types_with_value_manager_module = ['Constant']
types_with_module = ['CommonModule', 'HTTPService', 'WebService']

def ensure_ext_dir():
    os.makedirs(ext_dir, exist_ok=True)

if obj_type in types_with_object_module:
    module_path = os.path.join(ext_dir, 'ObjectModule.bsl')
    if not os.path.isfile(module_path):
        ensure_ext_dir()
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

if obj_type in types_with_manager_module:
    module_path = os.path.join(ext_dir, 'ManagerModule.bsl')
    if not os.path.isfile(module_path):
        ensure_ext_dir()
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

if obj_type in types_with_value_manager_module:
    module_path = os.path.join(ext_dir, 'ValueManagerModule.bsl')
    if not os.path.isfile(module_path):
        ensure_ext_dir()
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

if obj_type in types_with_record_set_module:
    module_path = os.path.join(ext_dir, 'RecordSetModule.bsl')
    if not os.path.isfile(module_path):
        ensure_ext_dir()
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

if obj_type in types_with_module:
    module_path = os.path.join(ext_dir, 'Module.bsl')
    if not os.path.isfile(module_path):
        ensure_ext_dir()
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

# CommonCommand — заготовка модуля команды (CommandModule.bsl).
if obj_type == 'CommonCommand':
    module_path = os.path.join(ext_dir, 'CommandModule.bsl')
    if not os.path.isfile(module_path):
        ensure_ext_dir()
        write_utf8_bom(module_path, '')
        modules_created.append(module_path)

# CommonForm — заготовка структуры формы под компиляцию (form-compile наполняет содержимое).
if obj_type == 'CommonForm':
    ensure_ext_dir()
    cf_form_xml_path = os.path.join(ext_dir, 'Form.xml')
    if not os.path.isfile(cf_form_xml_path):
        cf_ns = ('xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
                 'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" '
                 'xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" '
                 'xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" '
                 'xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" '
                 'xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" '
                 'xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" '
                 'xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
        cf_form_xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<Form ' + cf_ns + ' version="' + format_version + '">\n'
                       '\t<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">\n\t\t<Autofill>true</Autofill>\n\t</AutoCommandBar>\n'
                       '\t<ChildItems/>\n</Form>\n')
        write_utf8_bom(cf_form_xml_path, cf_form_xml)
        modules_created.append(cf_form_xml_path)
    cf_module_dir = os.path.join(ext_dir, 'Form')
    os.makedirs(cf_module_dir, exist_ok=True)
    cf_module_path = os.path.join(cf_module_dir, 'Module.bsl')
    if not os.path.isfile(cf_module_path):
        write_utf8_bom(cf_module_path, '')
        modules_created.append(cf_module_path)

# --- Predefined data (Ext/Predefined.xml). Элемент: "(Код) Имя [Наименование]" ИЛИ объект (+рус. синонимы).
# Наименование: нет [..]/ключа → авто(Split-CamelCase); [] / "" → пусто; [текст]/текст → как есть.
def resolve_predef_item(val):
    if isinstance(val, str):
        # Грамматика "(Код) Имя [Наименование]: Тип": сначала вынуть [Наим] (может содержать ':'), затем тип по ':'.
        s = val
        ptype = None
        desc_raw = None
        has_desc = False
        md = re.search(r'\[(.*)\]', s)
        if md:
            desc_raw = md.group(1)
            has_desc = True
            s = re.sub(r'\s*\[.*\]', '', s)
        if ':' in s:
            left, right = s.split(':', 1)
            s = left
            ptype = right.strip()   # '' → пустой <Type/>
        m = re.match(r'^\s*(?:\(([^)]*)\)\s*)?(\S+)\s*$', s.strip())
        name = m.group(2)
        code = m.group(1) if m.group(1) is not None else ''
        desc = desc_raw if has_desc else split_camel_case(name)
        return {'name': name, 'code': code, 'desc': desc, 'isFolder': False, 'children': [], 'type': ptype}
    def gv(keys):
        for k in keys:
            if k in val:
                return val[k]
        return None
    name = str(gv(['name', 'имя']) or '')
    code_v = gv(['code', 'код'])
    code = str(code_v) if code_v is not None else ''
    has_desc = ('description' in val) or ('наименование' in val)
    desc_v = gv(['description', 'наименование'])
    desc = ('' if desc_v is None else str(desc_v)) if has_desc else split_camel_case(name)
    is_folder = gv(['isFolder', 'группа']) is True
    subs = gv(['childItems', 'подчиненные']) or []
    type_v = gv(['type', 'тип'])   # тип значения характеристики (ПВХ): строка "A + B" ИЛИ массив
    if isinstance(type_v, list):
        type_v = ' + '.join(type_v)
    return {'name': name, 'code': code, 'desc': desc, 'isFolder': is_folder, 'children': list(subs), 'type': type_v}

def emit_predef_item(out, val, indent, code_type):
    r = resolve_predef_item(val)
    out.append(f'{indent}<Item id="{new_uuid()}">')
    out.append(f'{indent}\t<Name>{esc_xml_text(r["name"])}</Name>')
    if not r['code']:
        out.append(f'{indent}\t<Code/>')
    elif code_type == 'Number':
        out.append(f'{indent}\t<Code xsi:type="xs:decimal">{esc_xml_text(r["code"])}</Code>')
    else:
        out.append(f'{indent}\t<Code>{esc_xml_text(r["code"])}</Code>')
    if r['desc'] == '':
        out.append(f'{indent}\t<Description/>')
    else:
        out.append(f'{indent}\t<Description>{esc_xml_text(r["desc"])}</Description>')
    # Type — тип значения предопределённой характеристики (ПВХ). None→нет блока; ''→<Type/>; 'A + B'→наполненный.
    rt = r.get('type')
    if rt is not None and str(rt) == '':
        out.append(f'{indent}\t<Type/>')
    elif rt:
        out.append(f'{indent}\t<Type>')
        global lines
        saved = lines
        lines = []
        emit_type_content(indent + '\t\t', str(rt))
        out.extend(lines)
        lines = saved
        out.append(f'{indent}\t</Type>')
    out.append(f'{indent}\t<IsFolder>{"true" if r["isFolder"] else "false"}</IsFolder>')
    if r['children']:
        out.append(f'{indent}\t<ChildItems>')
        for c in r['children']:
            emit_predef_item(out, c, indent + '\t\t', code_type)
        out.append(f'{indent}\t</ChildItems>')
    out.append(f'{indent}</Item>')

def build_predefined_xml(items, xsi_type, code_type):
    out = ['<?xml version="1.0" encoding="UTF-8"?>']
    out.append(f'<PredefinedData xmlns="http://v8.1c.ru/8.3/xcf/predef" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="{xsi_type}" version="{format_version}">')
    for it in items:
        emit_predef_item(out, it, '\t', code_type)
    out.append('</PredefinedData>')
    return '\n'.join(out) + '\n'

# --- Предопределённые СЧЕТА Плана счетов (отдельная грамматика: AccountType/OffBalance/Order/AccountingFlags/
# ExtDimensionTypes/ChildItems). Флаги перечисляем по def-порядку признаков плана; в DSL — только TRUE. ---
def _predef_acc_get(o, keys):
    for k in keys:
        if isinstance(o, dict):
            if k in o:
                return o[k]
    return None

def emit_predef_account_flags(out, indent, tag, ref_kind, obj_nm, flag_names, true_set):
    if not flag_names:
        out.append(f'{indent}<{tag}/>')
        return
    tset = set(str(t) for t in (true_set or []))
    out.append(f'{indent}<{tag}>')
    for fn in flag_names:
        v = 'true' if fn in tset else 'false'
        out.append(f'{indent}\t<Flag ref="ChartOfAccounts.{obj_nm}.{ref_kind}.{fn}">{v}</Flag>')
    out.append(f'{indent}</{tag}>')

def emit_predef_account(out, val, indent, obj_nm, acct_flag_names, ext_dim_flag_names, ext_dim_types_ref=''):
    name = str(_predef_acc_get(val, ('name', 'имя')) or '')
    code_v = _predef_acc_get(val, ('code', 'код'))
    code = str(code_v) if code_v is not None else ''
    has_desc = isinstance(val, dict) and ('description' in val or 'наименование' in val)
    desc_v = _predef_acc_get(val, ('description', 'наименование'))
    desc = str(desc_v) if has_desc else split_camel_case(name)
    acct_type = str(_predef_acc_get(val, ('accountType', 'видСчета', 'вид')) or '') or 'ActivePassive'
    off = 'true' if _predef_acc_get(val, ('offBalance', 'забалансовый')) is True else 'false'
    order = str(_predef_acc_get(val, ('order', 'порядок')) or '')
    flags = _predef_acc_get(val, ('flags', 'признаки'))
    subconto = _predef_acc_get(val, ('subconto', 'extDimensionTypes', 'видыСубконто'))
    children = _predef_acc_get(val, ('childItems', 'подчиненные'))

    out.append(f'{indent}<Item id="{new_uuid()}">')
    out.append(f'{indent}\t<Name>{esc_xml_text(name)}</Name>')
    out.append(f'{indent}\t<Code/>' if not code else f'{indent}\t<Code>{esc_xml_text(code)}</Code>')
    out.append(f'{indent}\t<Description/>' if desc == '' else f'{indent}\t<Description>{esc_xml_text(desc)}</Description>')
    out.append(f'{indent}\t<AccountType>{acct_type}</AccountType>')
    out.append(f'{indent}\t<OffBalance>{off}</OffBalance>')
    out.append(f'{indent}\t<Order>{esc_xml_text(order)}</Order>')
    emit_predef_account_flags(out, f'{indent}\t', 'AccountingFlags', 'AccountingFlag', obj_nm, acct_flag_names, flags)
    sub_arr = list(subconto) if subconto else []
    if not sub_arr:
        out.append(f'{indent}\t<ExtDimensionTypes/>')
    else:
        out.append(f'{indent}\t<ExtDimensionTypes>')
        for sc in sub_arr:
            # Строковая форма "Тип | Признак1, Признак2" (флаги после |, turnover=false). Объектная — {type, turnover?, flags?}.
            if isinstance(sc, str):
                sc_turn_v = None
                if '|' in sc:
                    tpart, fpart = sc.split('|', 1)
                    sc_type = tpart.strip()
                    sc_flags = [x.strip() for x in fpart.split(',') if x.strip()]
                else:
                    sc_type = sc.strip()
                    sc_flags = None
            else:
                sc_type = str(_predef_acc_get(sc, ('type', 'тип')) or '')
                sc_turn_v = _predef_acc_get(sc, ('turnover', 'толькоОбороты', 'оборотный'))
                sc_flags = _predef_acc_get(sc, ('flags', 'признаки'))
            # Короткая запись: голое имя значения → префикс ПВХ видов субконто плана (extDimensionTypes); иначе резолв синонима.
            if '.' not in sc_type:
                if ext_dim_types_ref:
                    sc_type = f'{ext_dim_types_ref}.{sc_type}'
            else:
                sc_type = resolve_type_prefix_syn(sc_type)
            # «Только обороты» — токен в списке flags (или отдельный ключ turnover); вынимаем из настоящих признаков.
            sc_turn = 'true' if sc_turn_v is True else 'false'
            real_flags = []
            for f in (sc_flags or []):
                if str(f).strip().lower() in SUBCONTO_TURNOVER_TOKENS:
                    sc_turn = 'true'
                else:
                    real_flags.append(f)
            sc_flags = real_flags
            out.append(f'{indent}\t\t<ExtDimensionType name="{esc_xml(sc_type)}">')
            out.append(f'{indent}\t\t\t<Turnover>{sc_turn}</Turnover>')
            emit_predef_account_flags(out, f'{indent}\t\t\t', 'AccountingFlags', 'ExtDimensionAccountingFlag', obj_nm, ext_dim_flag_names, sc_flags)
            out.append(f'{indent}\t\t</ExtDimensionType>')
        out.append(f'{indent}\t</ExtDimensionTypes>')
    child_arr = list(children) if children else []
    if child_arr:
        out.append(f'{indent}\t<ChildItems>')
        for c in child_arr:
            emit_predef_account(out, c, f'{indent}\t\t', obj_nm, acct_flag_names, ext_dim_flag_names, ext_dim_types_ref)
        out.append(f'{indent}\t</ChildItems>')
    out.append(f'{indent}</Item>')

def build_predefined_account_xml(items, obj_nm, acct_flag_names, ext_dim_flag_names, ext_dim_types_ref=''):
    out = ['<?xml version="1.0" encoding="UTF-8"?>']
    out.append(f'<PredefinedData xmlns="http://v8.1c.ru/8.3/xcf/predef" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ChartOfAccountsPredefinedItems" version="{format_version}">')
    for it in items:
        emit_predef_account(out, it, '\t', obj_nm, acct_flag_names, ext_dim_flag_names, ext_dim_types_ref)
    out.append('</PredefinedData>')
    return '\n'.join(out) + '\n'

# Предопределённые ВИДЫ РАСЧЁТА (плоские: Name/Code/Description/ActionPeriodIsBase).
def emit_predef_calc_type(out, val, indent):
    r = resolve_predef_item(val)
    apib = 'false'
    if not isinstance(val, str):
        if _predef_acc_get(val, ('actionPeriodIsBase', 'периодДействияБазовый')) is True:
            apib = 'true'
    out.append(f'{indent}<Item id="{new_uuid()}">')
    out.append(f'{indent}\t<Name>{esc_xml_text(r["name"])}</Name>')
    out.append(f'{indent}\t<Code/>' if not r['code'] else f'{indent}\t<Code>{esc_xml_text(r["code"])}</Code>')
    out.append(f'{indent}\t<Description/>' if r['desc'] == '' else f'{indent}\t<Description>{esc_xml_text(r["desc"])}</Description>')
    out.append(f'{indent}\t<ActionPeriodIsBase>{apib}</ActionPeriodIsBase>')
    out.append(f'{indent}</Item>')

def build_predefined_calc_type_xml(items):
    out = ['<?xml version="1.0" encoding="UTF-8"?>']
    out.append(f'<PredefinedData xmlns="http://v8.1c.ru/8.3/xcf/predef" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CalculationTypePredefinedItems" version="{format_version}">')
    for it in items:
        emit_predef_calc_type(out, it, '\t')
    out.append('</PredefinedData>')
    return '\n'.join(out) + '\n'

# Special files
# --- Состав плана обмена (ExchangePlan, Ext/Content.xml). Ключ `content`/`Состав`:
# [ "MDRef" (AutoRecord=Deny, дефолт) | "MDRef: autoRecord" (Allow) | {metadata, autoRecord} ]. ---
def parse_exchange_content_item(entry):
    if isinstance(entry, str):
        ref, ar = entry, 'Deny'
        ci = entry.rfind(':')
        if ci >= 0:
            ref = entry[:ci].strip()
            flag = entry[ci + 1:].strip()
            if re.match(r'^(autoRecord|АвтоРегистрация|Allow|Разрешить)$', flag, re.I):
                ar = 'Allow'
            elif re.match(r'^(Deny|Запретить)$', flag, re.I):
                ar = 'Deny'
        return {'metadata': ref.strip(), 'autoRecord': ar}
    ref = ''
    for k in ('metadata', 'Метаданные', 'объект'):
        if entry.get(k) is not None:
            ref = str(entry[k]); break
    raw_ar = entry.get('autoRecord')
    if raw_ar is None:
        raw_ar = entry.get('АвтоРегистрация')
    ar = 'Deny'
    if isinstance(raw_ar, bool):
        if raw_ar:
            ar = 'Allow'
    elif raw_ar is not None and re.match(r'^(Allow|Разрешить|true|autoRecord|АвтоРегистрация)$', str(raw_ar), re.I):
        ar = 'Allow'
    return {'metadata': ref.strip(), 'autoRecord': ar}

if obj_type == 'ExchangePlan':
    content_path = os.path.join(ext_dir, 'Content.xml')
    xep_ns = 'xmlns="http://v8.1c.ru/8.3/xcf/extrnprops" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    c_src = defn.get('content')
    if c_src is None:
        c_src = defn.get('Состав')
    c_items = []
    if c_src:
        for e in (c_src if isinstance(c_src, list) else [c_src]):
            it = parse_exchange_content_item(e)
            if it['metadata']:
                c_items.append(it)
    if c_items:
        ensure_ext_dir()
        parts = ['<?xml version="1.0" encoding="UTF-8"?>\r\n',
                 f'<ExchangePlanContent {xep_ns} version="{format_version}">\r\n']
        for it in c_items:
            parts.append('\t<Item>\r\n')
            parts.append(f'\t\t<Metadata>{esc_xml(it["metadata"])}</Metadata>\r\n')
            parts.append(f'\t\t<AutoRecord>{it["autoRecord"]}</AutoRecord>\r\n')
            parts.append('\t</Item>\r\n')
        parts.append('</ExchangePlanContent>\r\n')
        write_utf8_bom(content_path, ''.join(parts))
        modules_created.append(content_path)
    elif not os.path.isfile(content_path):
        ensure_ext_dir()
        content_xml = f'<?xml version="1.0" encoding="UTF-8"?>\r\n<ExchangePlanContent {xep_ns} version="{format_version}"/>\r\n'
        write_utf8_bom(content_path, content_xml)
        modules_created.append(content_path)

if obj_type == 'BusinessProcess':
    flowchart_path = os.path.join(ext_dir, 'Flowchart.xml')
    if not os.path.isfile(flowchart_path):
        ensure_ext_dir()
        flowchart_xml = f'<?xml version="1.0" encoding="UTF-8"?>\r\n<Flowchart xmlns="http://v8.1c.ru/8.3/MDClasses" version="{format_version}"/>\r\n'
        write_utf8_bom(flowchart_path, flowchart_xml)
        modules_created.append(flowchart_path)

# Предопределённые элементы (Ext/Predefined.xml). Root-элемент по типу.
predef_root_by_type = {'Catalog': 'CatalogPredefinedItems', 'ChartOfCharacteristicTypes': 'PlanOfCharacteristicKindPredefinedItems'}
if obj_type == 'ChartOfAccounts' and defn.get('predefined'):
    # Предопределённые СЧЕТА — отдельная грамматика (флаги разворачиваются по def-порядку признаков плана).
    ensure_ext_dir()
    af_names = [parse_attribute_shorthand(af)['name'] for af in _as_list(defn['accountingFlags'])] if defn.get('accountingFlags') else []
    edf_names = [parse_attribute_shorthand(edf)['name'] for edf in _as_list(defn['extDimensionAccountingFlags'])] if defn.get('extDimensionAccountingFlags') else []
    edt_ref = resolve_type_prefix_syn(str(defn['extDimensionTypes'])) if defn.get('extDimensionTypes') else ''
    predef_xml = build_predefined_account_xml(defn['predefined'], obj_name, af_names, edf_names, edt_ref)
    predef_path = os.path.join(ext_dir, 'Predefined.xml')
    write_utf8_bom(predef_path, predef_xml)
    modules_created.append(predef_path)
elif obj_type == 'ChartOfCalculationTypes' and defn.get('predefined'):
    ensure_ext_dir()
    predef_xml = build_predefined_calc_type_xml(defn['predefined'])
    predef_path = os.path.join(ext_dir, 'Predefined.xml')
    write_utf8_bom(predef_path, predef_xml)
    modules_created.append(predef_path)
elif obj_type in predef_root_by_type and defn.get('predefined'):
    ensure_ext_dir()
    cat_code_type = str(defn['codeType']) if defn.get('codeType') else 'String'
    predef_xml = build_predefined_xml(defn['predefined'], predef_root_by_type[obj_type], cat_code_type)
    predef_path = os.path.join(ext_dir, 'Predefined.xml')
    write_utf8_bom(predef_path, predef_xml)
    modules_created.append(predef_path)

# Модули команд (Commands/<Имя>/Ext/CommandModule.bsl) — заготовка обработчика.
if commands:
    cmd_module_stub = '&НаКлиенте\r\nПроцедура ОбработкаКоманды(ПараметрКоманды, ПараметрыВыполненияКоманды)\r\n\r\n\t// Вставьте обработчик команды.\r\n\r\nКонецПроцедуры\r\n'
    for cmd in commands:
        cmd_dir = os.path.join(obj_sub_dir, 'Commands', cmd['name'], 'Ext')
        os.makedirs(cmd_dir, exist_ok=True)
        cmd_mod_path = os.path.join(cmd_dir, 'CommandModule.bsl')
        write_utf8_bom(cmd_mod_path, cmd_module_stub)
        modules_created.append(cmd_mod_path)

# ---------------------------------------------------------------------------
# 17. Register in Configuration.xml
# ---------------------------------------------------------------------------

config_xml_path = os.path.join(output_dir, 'Configuration.xml')
reg_result = None

child_tag = obj_type

if os.path.isfile(config_xml_path):
    # Read raw content, preserving BOM/EOL byte-for-byte (newline='' => no translation).
    with open(config_xml_path, 'r', encoding='utf-8-sig', newline='') as f:
        config_content = f.read()

    ns = 'http://v8.1c.ru/8.3/MDClasses'
    # ET is used ONLY read-only here: to locate ChildObjects and detect a duplicate.
    # We deliberately do NOT re-serialize Configuration.xml with ElementTree.write():
    # it drops every xmlns declaration used only inside attribute VALUES (e.g.
    # xsi:type="app:ApplicationUsePurpose" in UsePurposes) because ET never sees those
    # prefixes in element/attribute names. The dropped declaration makes XDTO read the
    # value as anyType and Designer refuses to load the file (issue #38). Registration is
    # therefore done by raw-text insertion, preserving BOM, EOL and all namespaces
    # byte-for-byte (same approach as subsystem-compile).
    tree = ET.parse(config_xml_path)
    root = tree.getroot()

    child_objects = root.find(f'{{{ns}}}Configuration/{{{ns}}}ChildObjects')
    if child_objects is None:
        # Try direct path
        config_elem = root.find(f'{{{ns}}}Configuration')
        if config_elem is not None:
            child_objects = config_elem.find(f'{{{ns}}}ChildObjects')

    if child_objects is None:
        reg_result = 'no-childobj'
    else:
        existing = child_objects.findall(f'{{{ns}}}{child_tag}')
        already_exists = any((e.text or '').strip() == obj_name for e in existing)

        if already_exists:
            reg_result = 'already'
        else:
            eol = '\r\n' if '\r\n' in config_content else '\n'
            entry = f'<{child_tag}>{esc_xml(obj_name)}</{child_tag}>'

            block = re.search(r'<ChildObjects\s*>.*?</ChildObjects>', config_content, re.S)
            if block is None:
                # Empty self-closing <ChildObjects/> => open it with the first entry.
                empty = re.search(r'<ChildObjects\s*/>', config_content)
                if empty is None:
                    reg_result = 'no-childobj'
                else:
                    replacement = f'<ChildObjects>{eol}\t\t\t{entry}{eol}\t\t</ChildObjects>'
                    new_content = config_content[:empty.start()] + replacement + config_content[empty.end():]
                    write_utf8_bom(config_xml_path, new_content)
                    reg_result = 'added'
            else:
                close_same = f'</{child_tag}>'
                last_same = config_content.rfind(close_same, block.start(), block.end())
                if last_same != -1:
                    # After the last element of the same type (keeps them grouped).
                    insert_at = last_same + len(close_same)
                    new_content = (config_content[:insert_at]
                                   + f'{eol}\t\t\t{entry}'
                                   + config_content[insert_at:])
                else:
                    # No element of this type yet: new line before </ChildObjects>,
                    # reusing the block's existing closing indent for </ChildObjects>.
                    close_at = config_content.rfind('</ChildObjects>', block.start(), block.end())
                    new_content = (config_content[:close_at]
                                   + f'\t{entry}{eol}\t\t'
                                   + config_content[close_at:])
                write_utf8_bom(config_xml_path, new_content)
                reg_result = 'added'
else:
    reg_result = 'no-config'

# ---------------------------------------------------------------------------
# 18. Summary
# ---------------------------------------------------------------------------

attr_count = len(defn.get('attributes', []))
ts_count = 0
if defn.get('tabularSections'):
    ts_data = defn['tabularSections']
    if isinstance(ts_data, list):
        ts_count = len(ts_data)
    else:
        ts_count = len(ts_data)
dim_count = len(defn.get('dimensions', []))
res_count = len(defn.get('resources', []))
val_count = len(defn.get('values', []))
col_count = len(defn.get('columns', []))

print(f"[OK] {obj_type} '{obj_name}' compiled")
print(f'     UUID: {obj_uuid}')
print(f'     File: {main_xml_path}')

details = []
if attr_count > 0:
    details.append(f'Attributes: {attr_count}')
if ts_count > 0:
    details.append(f'TabularSections: {ts_count}')
if dim_count > 0:
    details.append(f'Dimensions: {dim_count}')
if res_count > 0:
    details.append(f'Resources: {res_count}')
if val_count > 0:
    details.append(f'Values: {val_count}')
if col_count > 0:
    details.append(f'Columns: {col_count}')

if details:
    print(f"     {', '.join(details)}")

for mc in modules_created:
    print(f'     Module: {mc}')

if reg_result == 'added':
    print(f'     Configuration.xml: <{child_tag}>{obj_name}</{child_tag}> added to ChildObjects')
elif reg_result == 'already':
    print(f'     Configuration.xml: <{child_tag}>{obj_name}</{child_tag}> already registered')
elif reg_result == 'no-childobj':
    print('WARNING: Configuration.xml found but <ChildObjects> not found', file=sys.stderr)
elif reg_result == 'no-config':
    print(f'     Configuration.xml: not found at {config_xml_path} (register manually)')

# Cross-reference hints
if obj_type == 'AccountingRegister' and not defn.get('chartOfAccounts'):
    print('[HINT] AccountingRegister requires ChartOfAccounts reference:')
    print('       /meta-edit -Operation modify-property -Value "ChartOfAccounts=ChartOfAccounts.XXX"')
if obj_type == 'CalculationRegister' and not defn.get('chartOfCalculationTypes'):
    print('[HINT] CalculationRegister requires ChartOfCalculationTypes reference:')
    print('       /meta-edit -Operation modify-property -Value "ChartOfCalculationTypes=ChartOfCalculationTypes.XXX"')
if obj_type == 'BusinessProcess' and not defn.get('task'):
    print('[HINT] BusinessProcess requires Task reference:')
    print('       /meta-edit -Operation modify-property -Value "Task=Task.XXX"')
if obj_type == 'ChartOfAccounts':
    max_ext_dim = int(defn['maxExtDimensionCount']) if defn.get('maxExtDimensionCount') is not None else 0
    if max_ext_dim > 0 and not defn.get('extDimensionTypes'):
        print('[HINT] ChartOfAccounts with MaxExtDimensionCount>0 requires ExtDimensionTypes:')
        print('       /meta-edit -Operation modify-property -Value "ExtDimensionTypes=ChartOfCharacteristicTypes.XXX"')
