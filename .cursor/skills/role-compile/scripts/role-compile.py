#!/usr/bin/env python3
# role-compile v1.35 — Compile 1C role from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import sys
import uuid
import xml.etree.ElementTree as ET

from lxml import etree

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.

def parse_json_input(text, source, expected=None, inline=False):
    """Разбор пользовательского JSON: одна строка в stderr вместо traceback (issue #80).

    expected заполняем только для полиморфного входа: у файла подсказка
    была бы наполнителем — имя файла и текст парсера самодостаточны. inline печатает ещё и то,
    что доехало: у файла такого вопроса нет, он лежит на диске и его видно целиком.

    Импорты внутри тела: копия функции живёт в навыках с разными именами модулей
    (skd-decompile импортирует json локально как _json), а тело обязано быть одинаковым.
    """
    import json as _pj
    import sys as _psys
    try:
        if not str(text).strip():
            raise ValueError("input is empty")
        return _pj.loads(text)
    except ValueError as exc:
        what = "%s expects %s" % (source, expected) if expected else "Invalid JSON in %s" % source
        if inline:
            got = " ".join(str(text).split())
            label = "got"
            if not got:
                got = "(empty)"
            elif len(got) > 60:
                label = "got (first 60 chars)"
                got = got[:60]
            what = "%s, %s: %s" % (what, label, got)
        print("[ERROR] %s (%s)" % (what, exc), file=_psys.stderr)
        _psys.exit(1)


def read_json_file(path):
    """Чтение входного JSON-файла с кодировкой из BOM (issue #80).

    BOM — объявление самого файла, поэтому ему верим; без BOM ждём строгий UTF-8. Кодовую
    страницу не подбираем: угаданное имя уехало бы в метаданные молча.
    """
    import os as _pos
    import sys as _psys
    if not _pos.path.exists(path):
        print("[ERROR] File not found: %s" % path, file=_psys.stderr)
        _psys.exit(1)
    if _pos.path.isdir(path):
        print("[ERROR] Expected a JSON file, got a directory: %s" % path, file=_psys.stderr)
        _psys.exit(1)
    with open(path, "rb") as _fh:
        data = _fh.read()
    if data[:3] == b"\xef\xbb\xbf":
        return data[3:].decode("utf-8")
    if data[:2] == b"\xff\xfe":
        return data[2:].decode("utf-16-le")
    if data[:2] == b"\xfe\xff":
        return data[2:].decode("utf-16-be")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        print("[ERROR] %s is not valid UTF-8: %s - save the file as UTF-8, or add a BOM if it is UTF-16"
              % (path, exc), file=_psys.stderr)
        _psys.exit(1)


class CIDict(dict):
    # Ключи храним КАК ЕСТЬ: часть из них — имена объектов (табличные части, стандартные
    # реквизиты), они попадают в XML. Регистронезависим только поиск. Порядок вставки
    # сохраняется — от него зависит порядок эмиссии.
    def _actual(self, key):
        if not isinstance(key, str) or dict.__contains__(self, key):
            return key
        ci = self.__dict__.get('_ci')
        if ci is None or len(ci) != len(self):
            ci = {k.lower(): k for k in self if isinstance(k, str)}
            self.__dict__['_ci'] = ci
        return ci.get(key.lower(), key)

    def __getitem__(self, key):
        return dict.__getitem__(self, self._actual(key))

    def __contains__(self, key):
        return dict.__contains__(self, self._actual(key))

    def get(self, key, default=None):
        return dict.get(self, self._actual(key), default)

    def pop(self, key, *default):
        return dict.pop(self, self._actual(key), *default)

    def __setitem__(self, key, value):
        # запись по ключу, отличающемуся регистром, обновляет существующий, а не плодит дубль
        dict.__setitem__(self, self._actual(key), value)

def ci_json(obj):
    """Рекурсивно оборачивает разобранный JSON: словари → CIDict, списки обходятся."""
    if isinstance(obj, dict):
        return CIDict((k, ci_json(v)) for k, v in obj.items())
    if isinstance(obj, list):
        return [ci_json(v) for v in obj]
    return obj

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


def detect_eol(text):
    # Перевод строки ВСТАВКИ берём из самого файла: канон CRLF относится к файлам,
    # которые мы создаём, а правка существующего сохраняет его стиль (#44/#46/#47).
    # Семантика та же, что у _detect_xml_style в остальных портах: есть CRLF → CRLF.
    # Мажоритарное правило здесь было расхождением — на смешанном входе оно давало
    # другой ответ, чем канон, при том же назначении.
    return '\r\n' if '\r\n' in text else '\n'

def esc_xml(s):
    # Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def esc_xml_text(s):
    """Экранирование ТЕКСТА элемента: только & < > . Кавычки платформа в тексте не экранирует
    (92142 сырых кавычки на корпус, ни одной &quot;); &quot; она принимает, но нормализует обратно."""
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def emit_mltext(lines, indent, tag, text):
    if not text:
        lines.append(f"{indent}<{tag}/>")
        return
    lines.append(f"{indent}<{tag}>")
    lines.append(f"{indent}\t<v8:item>")
    lines.append(f"{indent}\t\t<v8:lang>ru</v8:lang>")
    lines.append(f"{indent}\t\t<v8:content>{esc_xml_text(text)}</v8:content>")
    lines.append(f"{indent}\t</v8:item>")
    lines.append(f"{indent}</{tag}>")


def new_uuid():
    return str(uuid.uuid4())


def write_utf8_bom(path, content):
    # newline='' — без трансляции: иначе текстовый режим Python дал бы CRLF на Windows
    # и LF на macOS, то есть вывод навыка зависел бы от ОС.
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)



# --- Russian synonyms -> canonical English names ---

TYPE_ALIASES = {
    "Справочник": "Catalog",
    "Документ": "Document",
    "РегистрСведений": "InformationRegister",
    "РегистрНакопления": "AccumulationRegister",
    "РегистрБухгалтерии": "AccountingRegister",
    "РегистрРасчета": "CalculationRegister",
    "РегистрРасчёта": "CalculationRegister",
    "Константа": "Constant",
    "ПланСчетов": "ChartOfAccounts",
    "ПланВидовХарактеристик": "ChartOfCharacteristicTypes",
    "ПланВидовРасчета": "ChartOfCalculationTypes",
    "ПланВидовРасчёта": "ChartOfCalculationTypes",
    "ПланОбмена": "ExchangePlan",
    "БизнесПроцесс": "BusinessProcess",
    "Задача": "Task",
    "Обработка": "DataProcessor",
    "Отчет": "Report",
    "Отчёт": "Report",
    "ОбщаяФорма": "CommonForm",
    "ОбщаяКоманда": "CommonCommand",
    "Подсистема": "Subsystem",
    "КритерийОтбора": "FilterCriterion",
    "ЖурналДокументов": "DocumentJournal",
    "Последовательность": "Sequence",
    "ВебСервис": "WebService",
    "HTTPСервис": "HTTPService",
    "СервисИнтеграции": "IntegrationService",
    "ПараметрСеанса": "SessionParameter",
    "ОбщийРеквизит": "CommonAttribute",
    "Конфигурация": "Configuration",
    "ВнешнийИсточникДанных": "ExternalDataSource",
    # Типы без прав в ролях: алиасы нужны не ради генерации, а ради отказа по делу —
    # иначе на русскую запись навык ответит «неизвестный тип 'ОбщийМодуль'».
    "Перечисление": "Enum",
    "ОбщийМодуль": "CommonModule",
    "ОпределяемыйТип": "DefinedType",
    "ОбщаяКартинка": "CommonPicture",
    "ОбщийМакет": "CommonTemplate",
    "Язык": "Language",
    "ФункциональнаяОпция": "FunctionalOption",
    "ПараметрФункциональныхОпций": "FunctionalOptionsParameter",
    "ПодпискаНаСобытие": "EventSubscription",
    "РегламентноеЗадание": "ScheduledJob",
    "ЭлементСтиля": "StyleItem",
    "ХранилищеНастроек": "SettingsStorage",
    "ПакетXDTO": "XDTOPackage",
    "WSСсылка": "WSReference",
    "Нумератор": "DocumentNumerator",
    # Nested
    "Реквизит": "Attribute",
    "СтандартныйРеквизит": "StandardAttribute",
    "ТабличнаяЧасть": "TabularSection",
    "Измерение": "Dimension",
    "Ресурс": "Resource",
    "Команда": "Command",
    "РеквизитАдресации": "AddressingAttribute",
}

RIGHT_ALIASES = {
    "Чтение": "Read",
    "Добавление": "Insert",
    "Изменение": "Update",
    "Удаление": "Delete",
    "Просмотр": "View",
    "Редактирование": "Edit",
    "ВводПоСтроке": "InputByString",
    "Проведение": "Posting",
    "ОтменаПроведения": "UndoPosting",
    "ИнтерактивноеДобавление": "InteractiveInsert",
    "ИнтерактивнаяПометкаУдаления": "InteractiveSetDeletionMark",
    "ИнтерактивноеСнятиеПометкиУдаления": "InteractiveClearDeletionMark",
    "ИнтерактивноеУдаление": "InteractiveDelete",
    "ИнтерактивноеУдалениеПомеченных": "InteractiveDeleteMarked",
    "ИнтерактивноеПроведение": "InteractivePosting",
    "ИнтерактивноеПроведениеНеоперативное": "InteractivePostingRegular",
    "ИнтерактивнаяОтменаПроведения": "InteractiveUndoPosting",
    "ИнтерактивноеИзменениеПроведенных": "InteractiveChangeOfPosted",
    "Использование": "Use",
    "Получение": "Get",
    "Установка": "Set",
    "Старт": "Start",
    "ИнтерактивныйСтарт": "InteractiveStart",
    "ИнтерактивнаяАктивация": "InteractiveActivate",
    "Выполнение": "Execute",
    "ИнтерактивноеВыполнение": "InteractiveExecute",
    "УправлениеИтогами": "TotalsControl",
    "Администрирование": "Administration",
    "АдминистрированиеДанных": "DataAdministration",
    "ТонкийКлиент": "ThinClient",
    "ВебКлиент": "WebClient",
    "ТолстыйКлиент": "ThickClient",
    "ВнешнееСоединение": "ExternalConnection",
    "Вывод": "Output",
    "СохранениеДанныхПользователя": "SaveUserData",
    "МобильныйКлиент": "MobileClient",
}

# --- Known rights per object type ---

KNOWN_RIGHTS = {
    "Configuration": [
        "Administration", "DataAdministration", "UpdateDataBaseConfiguration",
        "ConfigurationExtensionsAdministration", "ActiveUsers", "EventLog", "ExclusiveMode",
        "ThinClient", "ThickClient", "WebClient", "MobileClient", "ExternalConnection",
        "Automation", "Output", "SaveUserData", "TechnicalSpecialistMode",
        "InteractiveOpenExtDataProcessors", "InteractiveOpenExtReports",
        "AnalyticsSystemClient", "CollaborationSystemInfoBaseRegistration",
        "MainWindowModeNormal", "MainWindowModeWorkplace",
        "MainWindowModeEmbeddedWorkplace", "MainWindowModeFullscreenWorkplace", "MainWindowModeKiosk",
    ],
    "Catalog": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistoryOfMissingData", "ReadDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "Document": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "Posting", "UndoPosting",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractivePosting", "InteractivePostingRegular", "InteractiveUndoPosting",
        "InteractiveChangeOfPosted",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistoryOfMissingData", "ReadDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "InformationRegister": [
        "Read", "Update", "View", "Edit", "TotalsControl",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistoryOfMissingData", "ReadDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "AccumulationRegister": ["Read", "Update", "View", "Edit", "TotalsControl"],
    "AccountingRegister": ["Read", "Update", "View", "Edit", "TotalsControl"],
    "CalculationRegister": ["Read", "View"],
    "Constant": [
        "Read", "Update", "View", "Edit",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "ChartOfAccounts": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData",
        "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
    ],
    "ChartOfCharacteristicTypes": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "ChartOfCalculationTypes": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData",
        "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
    ],
    "ExchangePlan": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveDeleteMarked",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "BusinessProcess": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "Start", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveActivate", "InteractiveStart",
    ],
    "Task": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "Execute", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDelete", "InteractiveActivate", "InteractiveExecute",
    ],
    "DataProcessor": ["Use", "View"],
    "Report": ["Use", "View"],
    "CommonForm": ["View"],
    "CommonCommand": ["View"],
    "Subsystem": ["View"],
    "FilterCriterion": ["View"],
    "DocumentJournal": ["Read", "View"],
    "Sequence": ["Read", "Update"],
    "WebService": ["Use"],
    "HTTPService": ["Use"],
    "IntegrationService": ["Use"],
    "SessionParameter": ["Get", "Set"],
    "CommonAttribute": ["View", "Edit"],
    "ExternalDataSource": [
        "Use", "Administration", "StandardAuthenticationChange",
        "SessionStandardAuthenticationChange", "SessionOSAuthenticationChange",
    ],
}

# Виды вложенности (предпоследний сегмент пути) → допустимые права. Списки сняты с корпуса
# типовых конфигураций и с выгрузки роли, где права проставлены по всему дереву редактора:
# догадкам тут не место — закрытый список превращает промах в ложный отказ.
NESTED_KIND_RIGHTS = {
    "Attribute": ["View", "Edit"],
    "StandardAttribute": ["View", "Edit"],
    "TabularSection": ["View", "Edit"],
    "StandardTabularSection": ["View", "Edit"],
    "Dimension": ["View", "Edit"],
    "Resource": ["View", "Edit"],
    "AccountingFlag": ["View", "Edit"],
    "ExtDimensionAccountingFlag": ["View", "Edit"],
    "AddressingAttribute": ["View", "Edit"],
    "Field": ["View", "Edit"],
    "Command": ["View"],
    "Subsystem": ["View"],
    "Operation": ["Use"],
    "Method": ["Use"],
    "IntegrationServiceChannel": ["Use"],
    "Recalculation": ["Read", "Update"],
    "Cube": ["Read", "View"],
    "DimensionTable": ["Read", "View"],
    "Function": ["Use", "View"],
    "Table": [
        "Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString",
        "InteractiveInsert", "InteractiveDelete",
    ],
}

# Виды, существующие только у одного типа-родителя: без этой привязки
# `Catalog.Товары.Field.Цена` прошёл бы как валидный вложенный объект.
KIND_OWNERS = {
    'Table': 'ExternalDataSource',
    'Cube': 'ExternalDataSource',
    'Function': 'ExternalDataSource',
    'Field': 'ExternalDataSource',
    'DimensionTable': 'ExternalDataSource',
    'Recalculation': 'CalculationRegister',
    'Operation': 'WebService',
    'Method': 'HTTPService',
    'IntegrationServiceChannel': 'IntegrationService',
}

# Право на сервис живёт на ЛИСТЕ — методе шаблона URL, операции, канале, — а не на самом
# сервисе: корневого узла нет ни в одной типовой роли (907 записей корпуса — ноль), в
# Конфигураторе галки на корне нет вовсе. Короткая запись `HTTPService.X: Use` выражает
# намерение «открой сервис целиком» и раскрывается в листья по метаданным сервиса.
SERVICE_LEAVES = {
    'WebService': {'dir': 'WebServices', 'kinds': ['Operation']},
    'HTTPService': {'dir': 'HTTPServices', 'kinds': ['URLTemplate', 'Method']},
    'IntegrationService': {'dir': 'IntegrationServices', 'kinds': ['IntegrationServiceChannel']},
}

# Один и тот же вид под разными родителями имеет разный набор: измерение регистра —
# View + Edit, измерение куба внешнего источника — только View. Объединять нельзя,
# объединение молча разрешило бы Edit там, где платформа его не даёт.
NESTED_KIND_RIGHTS_BY_TYPE = {
    "ExternalDataSource": {
        "Dimension": ["View"],
        "Resource": ["View"],
    },
}

# Типы без прав в ролях (в дереве редактора ролей их нет). Список НЕ управляет поведением —
# отказ даёт отсутствие типа в KNOWN_RIGHTS; здесь только выбор формулировки.
NO_RIGHTS_TYPES = [
    "Enum", "CommonModule", "DefinedType", "CommonPicture", "CommonTemplate", "Language",
    "FunctionalOption", "FunctionalOptionsParameter", "EventSubscription", "ScheduledJob",
    "StyleItem", "Style", "SettingsStorage", "XDTOPackage", "WSReference", "DocumentNumerator",
]

# --- Presets ---

PRESETS = {
    "view": {
        "Catalog": ["Read", "View", "InputByString"],
        "ExchangePlan": ["Read", "View", "InputByString"],
        "Document": ["Read", "View", "InputByString"],
        "ChartOfAccounts": ["Read", "View", "InputByString"],
        "ChartOfCharacteristicTypes": ["Read", "View", "InputByString"],
        "ChartOfCalculationTypes": ["Read", "View", "InputByString"],
        "BusinessProcess": ["Read", "View", "InputByString"],
        "Task": ["Read", "View", "InputByString"],
        "InformationRegister": ["Read", "View"],
        "AccumulationRegister": ["Read", "View"],
        "AccountingRegister": ["Read", "View"],
        "CalculationRegister": ["Read", "View"],
        "Constant": ["Read", "View"],
        "DocumentJournal": ["Read", "View"],
        "Sequence": ["Read"],
        "CommonForm": ["View"],
        "CommonCommand": ["View"],
        "Subsystem": ["View"],
        "FilterCriterion": ["View"],
        "SessionParameter": ["Get"],
        "CommonAttribute": ["View"],
        "DataProcessor": ["Use", "View"],
        "Report": ["Use", "View"],
        "Configuration": ["ThinClient", "WebClient", "Output", "SaveUserData", "MainWindowModeNormal"],
    },
    "edit": {
        "Catalog": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "ExchangePlan": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "Document": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "Posting", "UndoPosting", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractivePosting", "InteractivePostingRegular", "InteractiveUndoPosting", "InteractiveChangeOfPosted"],
        "ChartOfAccounts": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "ChartOfCharacteristicTypes": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "ChartOfCalculationTypes": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark"],
        "BusinessProcess": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "Start", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveActivate", "InteractiveStart"],
        "Task": ["Read", "Insert", "Update", "Delete", "View", "Edit", "InputByString", "Execute", "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveActivate", "InteractiveExecute"],
        "InformationRegister": ["Read", "Update", "View", "Edit"],
        "AccumulationRegister": ["Read", "Update", "View", "Edit"],
        "AccountingRegister": ["Read", "Update", "View", "Edit"],
        "Constant": ["Read", "Update", "View", "Edit"],
        "DocumentJournal": ["Read", "View"],
        "Sequence": ["Read", "Update"],
        "SessionParameter": ["Get", "Set"],
        "CommonAttribute": ["View", "Edit"],
    },
}


def translate_object_name(name):
    parts = name.split('.')
    result = []
    for p in parts:
        result.append(TYPE_ALIASES.get(p, p))
    return '.'.join(result)


def translate_right_name(name):
    return RIGHT_ALIASES.get(name, name)


def get_object_type(object_name):
    dot_idx = object_name.find('.')
    if dot_idx < 0:
        return object_name
    return object_name[:dot_idx]


def is_nested_object(object_name):
    return len(object_name.split('.')) >= 3


def get_nested_kind(object_name):
    """Вид вложенности — предпоследний сегмент: путь бывает и восьмисегментным
    (ExternalDataSource.И.Cube.К.DimensionTable.Т.Field.П), считать от конца."""
    parts = object_name.split('.')
    if len(parts) < 3:
        return None
    return parts[-2]


def get_nested_rights(object_type, kind):
    by_type = NESTED_KIND_RIGHTS_BY_TYPE.get(object_type)
    if by_type and kind in by_type:
        return by_type[kind]
    return NESTED_KIND_RIGHTS.get(kind)


# Отказ копится, а не печатается сразу: роль пишется целиком, поэтому единственный
# безопасный момент отказа — до первой записи, и показать надо все причины сразу.
VALIDATION_ERRORS = []


def add_validation_error(message):
    VALIDATION_ERRORS.append(message)


def validate_object_name(object_name):
    """Тип по белому списку (всегда, включая вложенные пути) и вид вложенности.
    Запрещённый и незнакомый тип — разные диагнозы."""
    object_type = get_object_type(object_name)
    if object_type not in KNOWN_RIGHTS:
        if object_type in NO_RIGHTS_TYPES:
            add_validation_error(f"{object_name}: тип '{object_type}' не имеет прав в роли — уберите объект из списка")
        else:
            similar = [t for t in KNOWN_RIGHTS if object_type in t or t in object_type][:3]
            sug = f" Возможно: {', '.join(similar)}?" if similar else ''
            add_validation_error(f"{object_name}: неизвестный тип объекта '{object_type}'.{sug}")
        return False

    if is_nested_object(object_name):
        kind = get_nested_kind(object_name)
        if kind in KIND_OWNERS and object_type != KIND_OWNERS[kind]:
            add_validation_error(f"{object_name}: вид '{kind}' бывает только у {KIND_OWNERS[kind]}")
            return False
        if get_nested_rights(object_type, kind) is None:
            add_validation_error(f"{object_name}: неизвестный вид вложенности '{kind}'")
            return False

    return True


def resolve_preset(object_type, preset_name):
    preset = preset_name.lstrip('@')
    if preset not in PRESETS:
        print(f"WARNING: Unknown preset '@{preset}'. Known: @view, @edit", file=sys.stderr)
        return []
    type_map = PRESETS[preset]
    if object_type not in type_map:
        available = []
        for k in PRESETS:
            if object_type in PRESETS[k]:
                available.append(f'@{k}')
        avail_str = ', '.join(available) if available else 'none'
        print(f"WARNING: Preset '@{preset}' not defined for type '{object_type}'. Available: {avail_str}", file=sys.stderr)
        return []
    return list(type_map[object_type])


def validate_right_name(object_name, right_name):
    object_type = get_object_type(object_name)

    # Тип уже проверен validate_object_name — здесь только права, иначе про один
    # запрещённый тип напечатается столько строк, сколько у него перечислено прав.
    if object_type not in KNOWN_RIGHTS:
        return False

    if is_nested_object(object_name):
        kind = get_nested_kind(object_name)
        valid_nested = get_nested_rights(object_type, kind)
        if valid_nested is None:
            return False
        if right_name not in valid_nested:
            add_validation_error(f"{object_name}: право '{right_name}' недопустимо для вида '{kind}' (допустимо: {', '.join(valid_nested)})")
            return False
        return True

    valid_rights = KNOWN_RIGHTS[object_type]
    if right_name not in valid_rights:
        suggestions = [r for r in valid_rights if right_name in r or r in right_name][:3]
        sug_str = f" Возможно: {', '.join(suggestions)}?" if suggestions else ""
        add_validation_error(f"{object_name}: право '{right_name}' не существует у типа '{object_type}'.{sug_str}")
        return False

    return True


MD_NS = 'http://v8.1c.ru/8.3/MDClasses'

# Метаданные сервиса читаются один раз на имя: раскрытие и проверка заимствования
# спрашивают один и тот же файл.
SERVICE_META_CACHE = {}


def get_service_meta(object_type, service_name, config_root):
    key = f"{object_type}.{service_name}"
    if key in SERVICE_META_CACHE:
        return SERVICE_META_CACHE[key]

    spec = SERVICE_LEAVES[object_type]
    xml_path = os.path.join(config_root, spec['dir'], f"{service_name}.xml")
    result = {'path': xml_path, 'found': False, 'adopted': False, 'leaves': []}

    if os.path.isfile(xml_path):
        try:
            root = etree.parse(xml_path).getroot()
            node = root.find(f"{{{MD_NS}}}{object_type}")
            if node is not None:
                result['found'] = True
                # ObjectBelonging=Adopted — сервис заимствован в расширение.
                ob = node.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}ObjectBelonging")
                if ob is not None and (ob.text or '') == 'Adopted':
                    result['adopted'] = True

                # Спуск по видам: у HTTP-сервиса лист лежит на два уровня ниже
                # (URLTemplate → Method), у остальных — на один.
                level = [(node, f"{object_type}.{service_name}")]
                for kind in spec['kinds']:
                    nxt = []
                    for item_node, item_name in level:
                        for child in item_node.findall(f"{{{MD_NS}}}ChildObjects/{{{MD_NS}}}{kind}"):
                            name_node = child.find(f"{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
                            if name_node is None:
                                continue
                            nxt.append((child, f"{item_name}.{kind}.{name_node.text}"))
                    level = nxt
                result['leaves'] = [n for _, n in level]
        except Exception:
            # Битый XML — не наша забота: раскрывать нечего, дальше отработает отказ
            # «метаданные не найдены» с тем же путём в подсказке.
            pass

    SERVICE_META_CACHE[key] = result
    return result


def get_service_leaf_hint(object_type, service_name):
    """Подсказка формата: единственное, что отличается у трёх видов сервисов, — путь до листа."""
    if object_type == 'HTTPService':
        return f"{object_type}.{service_name}.URLTemplate.<Шаблон>.Method.<Метод>: Use"
    if object_type == 'WebService':
        return f"{object_type}.{service_name}.Operation.<Операция>: Use"
    return f"{object_type}.{service_name}.IntegrationServiceChannel.<Канал>: Use"


# Роль расширения, включённая в <DefaultRoles>, прав на заимствованные объекты давать не
# может — платформа отвечает «Назначение прав доступа на заимствованные объекты основными
# ролями в расширениях недопустимо». Считаем один раз: имя роли за прогон не меняется.
IS_DEFAULT_ROLE = None


def test_default_role(config_root, name):
    global IS_DEFAULT_ROLE
    if IS_DEFAULT_ROLE is not None:
        return IS_DEFAULT_ROLE
    IS_DEFAULT_ROLE = False

    cfg_path = os.path.join(config_root, 'Configuration.xml')
    if os.path.isfile(cfg_path):
        with open(cfg_path, 'r', encoding='utf-8-sig') as f:
            text = f.read()
        # Только расширение: у обычной конфигурации DefaultRoles значит другое и запрета нет.
        if '<ConfigurationExtensionPurpose>' in text:
            m = re.search(r'<DefaultRoles>(.*?)</DefaultRoles>', text, re.S)
            # Сравнение регистрозависимое — паритет с -cmatch в PS1, где регистронезависимый
            # -match принял бы «расш1_роль1» за основную роль «Расш1_Роль1».
            if m and re.search(re.escape(f"Role.{name}") + r'\s*<', m.group(1)):
                IS_DEFAULT_ROLE = True
    return IS_DEFAULT_ROLE


def expand_service_entry(parsed, config_root, name):
    """Возвращает список записей на замену исходной: сервисный корень раскрывается в листья,
    всё остальное проходит как есть."""
    obj_name = parsed['Name']
    object_type = get_object_type(obj_name)
    if object_type not in SERVICE_LEAVES:
        return [parsed]

    parts = obj_name.split('.')
    if len(parts) < 2:
        return [parsed]
    service_name = parts[1]
    meta = get_service_meta(object_type, service_name, config_root)

    if meta['adopted'] and test_default_role(config_root, name):
        add_validation_error(
            f"{obj_name}: '{name}' — основная роль расширения (входит в DefaultRoles), "
            f"а {object_type}.{service_name} заимствован; назначать права на заимствованные объекты "
            "основными ролями расширения платформа запрещает. Заведите отдельную роль и не включайте её в основные.")
        return []

    # Полный путь пользователь задал сам — раскрывать нечего.
    if len(parts) > 2:
        return [parsed]

    hint = get_service_leaf_hint(object_type, service_name)
    if not meta['found']:
        add_validation_error(
            f"{obj_name}: метаданные сервиса не найдены ({meta['path']}); "
            f"право на сервис целиком платформа игнорирует — укажите листья явно: {hint}")
        return []
    if not meta['leaves']:
        add_validation_error(
            f"{obj_name}: у сервиса нет ни одного вложенного объекта, раскрывать нечего; "
            "право на сервис целиком платформа игнорирует. "
            f"Для заимствованного сервиса заимствуйте нужные методы, затем: {hint}")
        return []

    expanded = [{'Name': leaf, 'Rights': parsed['Rights']} for leaf in meta['leaves']]
    print(f"     {obj_name} -> раскрыт (вложенных объектов: {len(expanded)})")
    return expanded


def parse_object_entry(entry):
    # --- String shorthand ---
    if isinstance(entry, str):
        colon_idx = entry.find(':')
        if colon_idx < 0:
            print(f"WARNING: Invalid string '{entry}' -- expected 'Object.Name: @preset' or 'Object.Name: Right1, Right2'", file=sys.stderr)
            return None
        obj_name = translate_object_name(entry[:colon_idx].strip())
        rights_str = entry[colon_idx + 1:].strip()
        # Объект с непроходным именем дальше не разбираем: пресет для несуществующего типа
        # добавил бы к отказу ещё и бессмысленное предупреждение.
        if not validate_object_name(obj_name):
            return None
        object_type = get_object_type(obj_name)

        if rights_str.startswith('@'):
            right_names = resolve_preset(object_type, rights_str)
        else:
            right_names = [translate_right_name(r.strip()) for r in rights_str.split(',') if r.strip()]
            for r in right_names:
                validate_right_name(obj_name, r)

        rights = []
        for r in right_names:
            rights.append({'Name': r, 'Value': 'true', 'Condition': None})
        return {'Name': obj_name, 'Rights': rights}

    # --- Object form ---
    obj_name = translate_object_name(str(entry.get('name', '')))
    if not obj_name:
        print("WARNING: Object entry missing 'name' field", file=sys.stderr)
        return None

    if not validate_object_name(obj_name):
        return None

    object_type = get_object_type(obj_name)
    # Use a list of tuples to preserve insertion order
    rights_map = {}  # name -> {Value, Condition}
    rights_order = []  # preserve order

    # 1) Start with preset
    if entry.get('preset'):
        preset_rights = resolve_preset(object_type, str(entry['preset']))
        for r in preset_rights:
            if r not in rights_map:
                rights_order.append(r)
            rights_map[r] = {'Value': 'true', 'Condition': None}

    # 2) Apply explicit rights
    if entry.get('rights') is not None:
        if isinstance(entry['rights'], list):
            for r in entry['rights']:
                r_name = translate_right_name(str(r))
                validate_right_name(obj_name, r_name)
                if r_name not in rights_map:
                    rights_order.append(r_name)
                rights_map[r_name] = {'Value': 'true', 'Condition': None}
        elif isinstance(entry['rights'], dict):
            for p_name, p_value in entry['rights'].items():
                r_name = translate_right_name(p_name)
                validate_right_name(obj_name, r_name)
                bool_val = 'true' if p_value is True or str(p_value) == 'True' else 'false'
                if r_name not in rights_map:
                    rights_order.append(r_name)
                rights_map[r_name] = {'Value': bool_val, 'Condition': None}

    # 3) Apply RLS conditions
    if entry.get('rls'):
        for p_name, p_value in entry['rls'].items():
            rls_right = translate_right_name(p_name)
            if rls_right in rights_map:
                rights_map[rls_right]['Condition'] = str(p_value)
            else:
                print(f"WARNING: {obj_name}: RLS for '{rls_right}' but this right is not in the rights list", file=sys.stderr)

    # Convert to array
    rights = []
    for k in rights_order:
        rights.append({
            'Name': k,
            'Value': rights_map[k]['Value'],
            'Condition': rights_map[k]['Condition'],
        })

    return {'Name': obj_name, 'Rights': rights}


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


# Канонический порядок видов в <ChildObjects> — эталон в docs/1c-configuration-spec.md,
# таблица «Порядок типов в ChildObjects». Нужен, чтобы новая группа вида вставала на своё
# место: иначе платформа переставит её при первой же выгрузке и даст диф на ровном месте.
# Реестр карт: tests/skills/check-type-maps.mjs.
CHILD_OBJECT_TYPES = [
    'Language', 'Subsystem', 'StyleItem', 'Style',
    'CommonPicture', 'SessionParameter', 'Role', 'CommonTemplate',
    'FilterCriterion', 'CommonModule', 'CommonAttribute', 'ExchangePlan',
    'XDTOPackage', 'WebService', 'HTTPService', 'WSReference',
    'EventSubscription', 'ScheduledJob', 'SettingsStorage', 'FunctionalOption',
    'FunctionalOptionsParameter', 'DefinedType', 'Bot', 'PaletteColor', 'CommonCommand', 'CommandGroup',
    'Constant', 'CommonForm', 'Catalog', 'Document',
    'DocumentNumerator', 'Sequence', 'DocumentJournal', 'Enum',
    'Report', 'DataProcessor', 'InformationRegister', 'AccumulationRegister',
    'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'AccountingRegister',
    'ChartOfCalculationTypes', 'CalculationRegister',
    'BusinessProcess', 'Task', 'IntegrationService',
]


def register_in_childobjects(parent_xml_path, parent_tag, child_tag, child_name):
    """Регистрация объекта в <ChildObjects> родительского XML.

    Общая реализация: эталон — meta-compile, копии — role-compile, xdto-compile.
    Реестр семьи: tests/skills/check-inline-drift.mjs.
    Возвращает исход: added | already | no-childobj | no-config.
    """
    if not os.path.isfile(parent_xml_path):
        return 'no-config'

    # Read raw content, preserving BOM/EOL byte-for-byte (newline='' => no translation)
    with open(parent_xml_path, 'r', encoding='utf-8-sig', newline='') as f:
        config_content = f.read()

    ns = 'http://v8.1c.ru/8.3/MDClasses'
    # ET is used ONLY read-only here: to locate ChildObjects and detect a duplicate.
    # We deliberately do NOT re-serialize Configuration.xml with ElementTree.write():
    # it drops every xmlns declaration used only inside attribute VALUES (e.g.
    # xsi:type="app:ApplicationUsePurpose" in UsePurposes) because ET never sees such
    # prefixes in element/attribute names. The dropped declaration makes XDTO read the
    # value as anyType and Designer refuses to load the file (issue #38). Registration is
    # therefore done by raw-text insertion, preserving BOM, EOL and all namespaces
    # byte-for-byte (same approach as subsystem-compile).
    tree = ET.parse(parent_xml_path)
    root = tree.getroot()

    child_objects = root.find(f'{{{ns}}}{parent_tag}/{{{ns}}}ChildObjects')
    if child_objects is None:
        # Try direct path
        parent_elem = root.find(f'{{{ns}}}{parent_tag}')
        if parent_elem is not None:
            child_objects = parent_elem.find(f'{{{ns}}}ChildObjects')

    if child_objects is None:
        return 'no-childobj'

    existing = child_objects.findall(f'{{{ns}}}{child_tag}')
    if any((e.text or '').strip() == child_name for e in existing):
        return 'already'

    eol = '\r\n' if '\r\n' in config_content else '\n'
    entry = f'<{child_tag}>{esc_xml_text(child_name)}</{child_tag}>'

    block = re.search(r'<ChildObjects\s*>.*?</ChildObjects>', config_content, re.S)
    if block is None:
        # Empty self-closing <ChildObjects/> => open it with the first entry.
        empty = re.search(r'<ChildObjects\s*/>', config_content)
        if empty is None:
            return 'no-childobj'
        replacement = f'<ChildObjects>{eol}\t\t\t{entry}{eol}\t\t</ChildObjects>'
        new_content = config_content[:empty.start()] + replacement + config_content[empty.end():]
        write_utf8_bom(parent_xml_path, new_content)
        return 'added'

    # byName: перед первым объектом того же вида, чьё имя больше нового.
    # Виды с осмысленным порядком в дереве пропускаем — см. is_order_sensitive_type.
    if (not is_order_sensitive_type(child_tag)
            and get_new_object_position(os.path.dirname(os.path.abspath(parent_xml_path))) == 'byName'):
        line_rx = re.compile(rf'(?m)^([ \t]*)<{child_tag}>([^<]*)</{child_tag}>')
        for m in line_rx.finditer(config_content, block.start(), block.end()):
            if compare_metadata_names(m.group(2), child_name) > 0:
                new_content = (config_content[:m.start()]
                               + f'{m.group(1)}{entry}{eol}'
                               + config_content[m.start():])
                write_utf8_bom(parent_xml_path, new_content)
                return 'added'

    close_same = f'</{child_tag}>'
    last_same = config_content.rfind(close_same, block.start(), block.end())
    if last_same != -1:
        # After the last element of the same type (keeps them grouped).
        insert_at = last_same + len(close_same)
        new_content = (config_content[:insert_at]
                       + f'{eol}\t\t\t{entry}'
                       + config_content[insert_at:])
    else:
        # Группы своего вида ещё нет: ставим её в канонический порядок видов — перед первой
        # группой вида старше по CHILD_OBJECT_TYPES. Дописать в конец блока нельзя: платформа
        # переставит группу при первой же выгрузке и даст диф на ровном месте.
        anchor = None
        if child_tag in CHILD_OBJECT_TYPES:
            own_idx = CHILD_OBJECT_TYPES.index(child_tag)
            type_rx = re.compile(r'(?m)^([ \t]*)<(\w+)>[^<]*</\2>')
            for m in type_rx.finditer(config_content, block.start(), block.end()):
                other = m.group(2)
                if other in CHILD_OBJECT_TYPES and CHILD_OBJECT_TYPES.index(other) > own_idx:
                    anchor = m
                    break
        if anchor is not None:
            new_content = (config_content[:anchor.start()]
                           + f'{anchor.group(1)}{entry}{eol}'
                           + config_content[anchor.start():])
        else:
            # Видов старше в файле нет — новая строка перед </ChildObjects>,
            # отступ закрывающего тега переиспользуется.
            close_at = config_content.rfind('</ChildObjects>', block.start(), block.end())
            new_content = (config_content[:close_at]
                           + f'\t{entry}{eol}\t\t'
                           + config_content[close_at:])
    write_utf8_bom(parent_xml_path, new_content)
    return 'added'


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C role from JSON', allow_abbrev=False)
    parser.add_argument('-JsonPath', type=str, required=True)
    parser.add_argument('-OutputDir', type=str, required=True)
    args = ci_parse_args(parser)

    # --- 1. Load and validate JSON ---
    json_path = args.JsonPath
    if not os.path.exists(json_path):
        print(f"File not found: {json_path}", file=sys.stderr)
        sys.exit(1)

    defn = ci_json(parse_json_input(read_json_file(json_path), json_path))

    if not defn.get('name'):
        print("JSON must have 'name' field (role programmatic name)", file=sys.stderr)
        sys.exit(1)

    role_name = str(defn['name'])
    synonym = str(defn['synonym']) if defn.get('synonym') else role_name
    comment = str(defn['comment']) if defn.get('comment') else ''

    # Synonym: accept "rights" as alias for "objects"
    if not defn.get('objects') and defn.get('rights'):
        defn['objects'] = defn['rights']

    out_dir_resolved = args.OutputDir if os.path.isabs(args.OutputDir) else os.path.join(os.getcwd(), args.OutputDir)
    assert_edit_allowed(out_dir_resolved, "editable")
    format_version = detect_format_version(out_dir_resolved)

    # --- 2. Parse all object entries ---
    parsed_objects = []
    seen_object_names = set()
    if defn.get('objects'):
        for entry in defn['objects']:
            parsed = parse_object_entry(entry)
            if not parsed:
                continue
            for p in expand_service_entry(parsed, out_dir_resolved, role_name):
                # Дубль возникает штатно: раскрытый лист совпал с явно заданным. Права на
                # листе одни и те же (Use), так что вторая запись — шум, а не конфликт.
                if p['Name'] in seen_object_names:
                    print(f"WARNING: {p['Name']}: объект указан дважды, вторая запись пропущена", file=sys.stderr)
                    continue
                seen_object_names.add(p['Name'])
                parsed_objects.append(p)

    # Отказ ДО записи: роль пишется тремя файлами (метаданные, права, регистрация в
    # Configuration.xml), и частично записанная роль хуже отсутствующей. Печатаем все
    # причины разом — иначе пользователь чинит их по одной.
    if VALIDATION_ERRORS:
        print(f"[role-compile] Роль не создана: {len(VALIDATION_ERRORS)} ошибок в описании прав.", file=sys.stderr)
        for e in VALIDATION_ERRORS:
            print(f"  ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    # --- 3. Generate UUID ---
    uid = new_uuid()

    # --- 4. Emit metadata XML (Roles/Name.xml) ---
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    # Объявления пространств имён — одной переменной и одной строкой, как пишет платформа.
    xmlns_decl = ('xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
    # 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (после lf, перед
    # style): платформа держит объявления по алфавиту. В Rights.xml палитра НЕ идёт.
    if format_rank(format_version) >= 221:
        xmlns_decl = xmlns_decl.replace(
            ' xmlns:style=',
            ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')
    lines.append(f'<MetaDataObject {xmlns_decl} version="{format_version}">')
    lines.append(f'\t<Role uuid="{uid}">')
    lines.append('\t\t<Properties>')
    lines.append(f'\t\t\t<Name>{role_name}</Name>')
    lines.append('\t\t\t<Synonym>')
    lines.append('\t\t\t\t<v8:item>')
    lines.append('\t\t\t\t\t<v8:lang>ru</v8:lang>')
    lines.append(f'\t\t\t\t\t<v8:content>{esc_xml_text(synonym)}</v8:content>')
    lines.append('\t\t\t\t</v8:item>')
    lines.append('\t\t\t</Synonym>')
    if comment:
        lines.append(f'\t\t\t<Comment>{esc_xml_text(comment)}</Comment>')
    else:
        lines.append('\t\t\t<Comment/>')
    lines.append('\t\t</Properties>')
    lines.append('\t</Role>')
    lines.append('</MetaDataObject>')

    metadata_xml = '\r\n'.join(lines)

    # --- 5. Emit Rights XML (Roles/Name/Ext/Rights.xml) ---
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<Rights xmlns="http://v8.1c.ru/8.2/roles" xmlns:xs="http://www.w3.org/2001/XMLSchema"'
                 ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Rights"'
                 f' version="{format_version}">')

    # Global flags
    sfno = str(defn['setForNewObjects']).lower() if defn.get('setForNewObjects') is not None else 'false'
    sfab = str(defn['setForAttributesByDefault']).lower() if defn.get('setForAttributesByDefault') is not None else 'true'
    irco = str(defn['independentRightsOfChildObjects']).lower() if defn.get('independentRightsOfChildObjects') is not None else 'false'

    lines.append(f'\t<setForNewObjects>{sfno}</setForNewObjects>')
    lines.append(f'\t<setForAttributesByDefault>{sfab}</setForAttributesByDefault>')
    lines.append(f'\t<independentRightsOfChildObjects>{irco}</independentRightsOfChildObjects>')

    # Object blocks
    total_rights = 0
    for obj in parsed_objects:
        lines.append('\t<object>')
        lines.append(f'\t\t<name>{obj["Name"]}</name>')
        for right in obj['Rights']:
            lines.append('\t\t<right>')
            lines.append(f'\t\t\t<name>{right["Name"]}</name>')
            lines.append(f'\t\t\t<value>{right["Value"]}</value>')
            if right['Condition']:
                lines.append('\t\t\t<restrictionByCondition>')
                lines.append(f'\t\t\t\t<condition>{esc_xml_text(right["Condition"])}</condition>')
                lines.append('\t\t\t</restrictionByCondition>')
            lines.append('\t\t</right>')
            total_rights += 1
        lines.append('\t</object>')

    # RLS restriction templates
    template_count = 0
    if defn.get('templates'):
        for tpl in defn['templates']:
            lines.append('\t<restrictionTemplate>')
            lines.append(f'\t\t<name>{esc_xml_text(str(tpl["name"]))}</name>')
            lines.append(f'\t\t<condition>{esc_xml_text(str(tpl["condition"]))}</condition>')
            lines.append('\t</restrictionTemplate>')
            template_count += 1

    lines.append('</Rights>')

    rights_xml = '\r\n'.join(lines)

    # --- 6. Write output files ---
    out_dir = args.OutputDir
    if not os.path.isabs(out_dir):
        out_dir = os.path.join(os.getcwd(), out_dir)

    # Determine Roles dir and config root
    # Back-compat: if OutputDir leaf is "Roles", use as-is; otherwise treat as config root
    leaf = os.path.basename(out_dir.rstrip(os.sep).rstrip('/'))
    if leaf == 'Roles':
        roles_dir = out_dir
        config_dir = os.path.dirname(out_dir)
    else:
        roles_dir = os.path.join(out_dir, 'Roles')
        config_dir = out_dir

    # Metadata: Roles/RoleName.xml
    metadata_path = os.path.join(roles_dir, f'{role_name}.xml')
    os.makedirs(roles_dir, exist_ok=True)

    # Rights: Roles/RoleName/Ext/Rights.xml
    role_sub_dir = os.path.join(roles_dir, role_name)
    ext_dir = os.path.join(role_sub_dir, 'Ext')
    rights_path = os.path.join(ext_dir, 'Rights.xml')
    os.makedirs(ext_dir, exist_ok=True)

    write_utf8_bom(metadata_path, metadata_xml)
    write_utf8_bom(rights_path, rights_xml)

    # --- 7. Register in Configuration.xml ---
    config_xml_path = os.path.join(config_dir, 'Configuration.xml')
    reg_result = register_in_childobjects(config_xml_path, 'Configuration', 'Role', role_name)

    # --- 8. Summary ---
    print(f"[OK] Role '{role_name}' compiled")
    print(f"     UUID: {uid}")
    print(f"     Metadata: {metadata_path}")
    print(f"     Rights:   {rights_path}")
    print(f"     Objects: {len(parsed_objects)}, Rights: {total_rights}, Templates: {template_count}")
    if reg_result == 'added':
        print(f"     Configuration.xml: <Role>{role_name}</Role> added to ChildObjects")
    elif reg_result == 'already':
        print(f"     Configuration.xml: <Role>{role_name}</Role> already registered")
    elif reg_result == 'no-childobj':
        print(f"WARNING: Configuration.xml found but <ChildObjects> not found", file=sys.stderr)
    elif reg_result == 'no-config':
        print(f"WARNING: Configuration.xml not found at {config_xml_path} -- register manually", file=sys.stderr)


if __name__ == '__main__':
    main()
