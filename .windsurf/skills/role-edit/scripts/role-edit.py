#!/usr/bin/env python3
# role-edit v1.7 — Edit existing 1C role rights in place
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import json
import os
import re
import subprocess
import sys

from lxml import etree

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
    "CalculationRegister": [
        "Read", "Update", "View", "Edit",
    ],
    "Constant": [
        "Read", "Update", "View", "Edit",
        "ReadDataHistory", "ViewDataHistory", "UpdateDataHistory",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "ChartOfAccounts": [
        "Read", "Insert", "Update", "Delete",
        "View", "Edit", "InputByString", "InteractiveInsert",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData", "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment",
        "SwitchToDataHistoryVersion",
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
        "Read", "Insert", "Update", "Delete",
        "View", "Edit", "InputByString", "InteractiveInsert",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDelete", "InteractiveDeleteMarked",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData", "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment",
        "SwitchToDataHistoryVersion",
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
        "Read", "Insert", "Update", "Delete",
        "View", "Edit", "InputByString", "Start",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDelete",
        "InteractiveDeleteMarked", "InteractiveActivate", "InteractiveStart", "ReadDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData", "UpdateDataHistorySettings",
        "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "Task": [
        "Read", "Insert", "Update", "Delete",
        "View", "Edit", "InputByString", "Execute",
        "InteractiveInsert", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDelete",
        "InteractiveDeleteMarked", "InteractiveActivate", "InteractiveExecute", "ReadDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData", "UpdateDataHistorySettings",
        "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
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


# --- Зависимости прав (замерено на платформе) ---
# Платформа при загрузке сама доводит набор до замыкания: выдал Edit — получил ещё
# Read, Update и View. Пишем замыкание сразу, иначе файл и база расходятся.
# Таблица общая для типов; исключения — там, где у типа своя механика (обработка и отчёт
# держатся на Use, план счетов не тянет Read под историю данных).
RIGHT_DEPS = {
    "Delete": ["Read"],
    "Edit": ["Read", "Update", "View"],
    "EditDataHistoryVersionComment": ["Read", "ReadDataHistory", "UpdateDataHistoryVersionComment", "View"],
    "Execute": ["Read", "Update"],
    "InputByString": ["Read", "View"],
    "Insert": ["Read"],
    "InteractiveActivate": ["Read", "Update"],
    "InteractiveChangeOfPosted": ["Edit", "Read", "Update", "View"],
    "InteractiveClearDeletionMark": ["Edit", "Read", "Update", "View"],
    "InteractiveClearDeletionMarkPredefinedData": ["Edit", "InteractiveClearDeletionMark", "Read", "Update", "View"],
    "InteractiveDelete": ["Delete", "Edit", "Read", "Update", "View"],
    "InteractiveDeleteMarked": ["Delete", "Edit", "Read", "Update", "View"],
    "InteractiveDeleteMarkedPredefinedData": ["Delete", "Edit", "InteractiveDeleteMarked", "Read", "Update", "View"],
    "InteractiveDeletePredefinedData": ["Delete", "Edit", "InteractiveDelete", "Read", "Update", "View"],
    "InteractiveExecute": ["Execute", "Read", "Update"],
    "InteractiveInsert": ["Edit", "Insert", "Read", "Update", "View"],
    "InteractivePosting": ["Edit", "Posting", "Read", "Update", "View"],
    "InteractivePostingRegular": ["Edit", "InteractivePosting", "Posting", "Read", "Update", "View"],
    "InteractiveSetDeletionMark": ["Edit", "Read", "Update", "View"],
    "InteractiveSetDeletionMarkPredefinedData": ["Edit", "InteractiveSetDeletionMark", "Read", "Update", "View"],
    "InteractiveStart": ["Read", "Start", "Update"],
    "InteractiveUndoPosting": ["Edit", "Read", "UndoPosting", "Update", "View"],
    "Posting": ["Read", "Update"],
    "ReadDataHistory": ["Read"],
    "ReadDataHistoryOfMissingData": ["Read", "ReadDataHistory"],
    "Start": ["Read", "Update"],
    "SwitchToDataHistoryVersion": ["Read", "View"],
    "UndoPosting": ["Read", "Update"],
    "Update": ["Read"],
    "UpdateDataHistory": ["Read", "ReadDataHistory"],
    "UpdateDataHistoryOfMissingData": ["Read", "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory"],
    "UpdateDataHistoryVersionComment": ["Read", "ReadDataHistory"],
    "View": ["Read"],
    "ViewDataHistory": ["Read", "ReadDataHistory", "View"],
}

RIGHT_DEPS_BY_TYPE = {
    "ChartOfAccounts": {
        "ReadDataHistory": [],
        "ReadDataHistoryOfMissingData": ["ReadDataHistory"],
        "UpdateDataHistory": ["ReadDataHistory"],
        "UpdateDataHistoryOfMissingData": ["ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory"],
        "UpdateDataHistoryVersionComment": ["ReadDataHistory"],
    },
    "DataProcessor": {
        "View": ["Use"],
    },
    "InformationRegister": {
        "UpdateDataHistoryOfMissingData": ["Read", "ReadDataHistory", "UpdateDataHistory"],
    },
    "Report": {
        "View": ["Use"],
    },
}

CONFIGURATION_LEGACY_DEPS = ["AnalyticsSystemClient", "MainWindowModeEmbeddedWorkplace", "MainWindowModeFullscreenWorkplace", "MainWindowModeKiosk", "MainWindowModeNormal", "MainWindowModeWorkplace"]

# Права конфигурации: до формата 2.19 платформа взводила весь блок режимов окна вместе с
# любым правом, с 2.19 (8.3.26) перестала. Сами права допустимы и там, и там.
CONFIGURATION_LEGACY_RANK = 218


# Платформа хранит только то, что ОТЛИЧАЕТСЯ от значения по умолчанию для роли: при
# setForNewObjects=false на верхнем уровне живут разрешения, при true — запреты; у реквизитных
# вложенных объектов ту же роль играет setForAttributesByDefault. Совпавшее с умолчанием
# платформа выбрасывает при первой же загрузке, поэтому не пишем его и сами.
ATTRIBUTE_KINDS = [
    "Attribute", "StandardAttribute", "TabularSection", "StandardTabularSection",
    "Dimension", "Resource", "AccountingFlag", "ExtDimensionAccountingFlag", "AddressingAttribute",
]


def get_default_right_value(object_name, set_for_new_objects, set_for_attributes_by_default):
    parts = object_name.split('.')
    if len(parts) < 3:
        return set_for_new_objects
    # Внешние источники данных под это правило не проверялись — трогаем только то, что замерено.
    if parts[0] == 'ExternalDataSource':
        return "false"
    kind = parts[-2]
    if kind in ATTRIBUTE_KINDS:
        return set_for_attributes_by_default
    # Команды, подсистемы, операции сервисов флагами роли не управляются — там живут разрешения.
    return "false"


def close_rights_dependencies(object_name, rights, format_rank):
    """Замыкание набора прав объекта. Возвращает (итоговые права, что дописано)."""
    parts = object_name.split('.')
    nested = len(parts) >= 3
    object_type = parts[0]
    allowed = (get_nested_rights(object_type, get_nested_kind(object_name)) if nested
               else KNOWN_RIGHTS.get(object_type))
    if not allowed:
        return rights, []
    have = {}
    for r in rights:
        have.setdefault(r['Name'], r)
    by_type = RIGHT_DEPS_BY_TYPE.get(object_type, {})
    added = []
    # Вперёд — только от РАЗРЕШЁННЫХ прав: платформа замыкает выданное, а не запрещённое.
    queue = [n for n in have if have[n]['Value'] == 'true']
    while queue:
        name = queue.pop(0)
        need = by_type[name] if name in by_type else RIGHT_DEPS.get(name)
        if not need:
            continue
        for dep in need:
            if dep not in allowed:
                continue
            if dep in have:
                # Разрешение перебивает запрет — так поступает и платформа при загрузке.
                if have[dep]['Value'] != 'true':
                    have[dep]['Value'] = 'true'
                    added.append(dep)
                    queue.append(dep)
                continue
            have[dep] = {'Name': dep, 'Value': 'true', 'Condition': None}
            added.append(dep)
            queue.append(dep)
    # Назад — от ЗАПРЕТОВ: право, которому запрещённое нужно, платформа запрещает следом.
    deny_queue = [n for n in have if have[n]['Value'] != 'true']
    while deny_queue:
        name = deny_queue.pop(0)
        for candidate in allowed:
            if candidate == name or candidate in have:
                continue
            need = by_type[candidate] if candidate in by_type else RIGHT_DEPS.get(candidate)
            if not need or name not in need:
                continue
            have[candidate] = {'Name': candidate, 'Value': 'false', 'Condition': None}
            added.append(candidate)
            deny_queue.append(candidate)
    if object_type == 'Configuration' and format_rank <= CONFIGURATION_LEGACY_RANK and have:
        for dep in CONFIGURATION_LEGACY_DEPS:
            if dep in have:
                continue
            have[dep] = {'Name': dep, 'Value': 'true', 'Condition': None}
            added.append(dep)
    return list(have.values()), added


# --- Канонический порядок прав и узлов (замерено на платформе) ---
# Платформа нормализует порядок <right> внутри <object> и порядок самих <object>:
# права идут в фиксированном для типа порядке, узлы — по uuid объекта метаданных.
# Пишем сразу так же, иначе первая же выгрузка из Конфигуратора даст диф на ровном месте.
RIGHT_ORDER = {
    "AccountingRegister": ["Read", "Update", "View", "Edit", "TotalsControl"],
    "AccumulationRegister": ["Read", "Update", "View", "Edit", "TotalsControl"],
    "BusinessProcess": [
        "Read", "Insert", "Update", "Delete",
        "View", "InteractiveInsert", "Edit", "InteractiveDelete",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDeleteMarked", "InputByString",
        "InteractiveActivate", "Start", "InteractiveStart", "ReadDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData", "UpdateDataHistorySettings",
        "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "CalculationRegister": ["Read", "Update", "View", "Edit"],
    "Catalog": [
        "Read", "Insert", "Update", "Delete",
        "View", "InteractiveInsert", "Edit", "InteractiveDelete",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDeleteMarked", "InputByString",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData", "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment",
        "SwitchToDataHistoryVersion",
    ],
    "ChartOfAccounts": [
        "Read", "Insert", "Update", "Delete",
        "View", "InteractiveInsert", "Edit", "InteractiveDelete",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDeleteMarked", "InputByString",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData", "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment",
        "SwitchToDataHistoryVersion",
    ],
    "ChartOfCalculationTypes": [
        "Read", "Insert", "Update", "Delete",
        "View", "InteractiveInsert", "Edit", "InteractiveDelete",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDeleteMarked", "InputByString",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData", "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment",
        "SwitchToDataHistoryVersion",
    ],
    "ChartOfCharacteristicTypes": [
        "Read", "Insert", "Update", "Delete",
        "View", "InteractiveInsert", "Edit", "InteractiveDelete",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDeleteMarked", "InputByString",
        "InteractiveDeletePredefinedData", "InteractiveSetDeletionMarkPredefinedData", "InteractiveClearDeletionMarkPredefinedData", "InteractiveDeleteMarkedPredefinedData",
        "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment",
        "SwitchToDataHistoryVersion",
    ],
    "CommonAttribute": ["View", "Edit"],
    "CommonCommand": ["View"],
    "CommonForm": ["View"],
    "Configuration": [
        "Administration", "DataAdministration", "UpdateDataBaseConfiguration", "ExclusiveMode",
        "ActiveUsers", "EventLog", "ThinClient", "WebClient",
        "MobileClient", "ThickClient", "ExternalConnection", "Automation",
        "TechnicalSpecialistMode", "CollaborationSystemInfoBaseRegistration", "MainWindowModeNormal", "MainWindowModeWorkplace",
        "MainWindowModeEmbeddedWorkplace", "MainWindowModeFullscreenWorkplace", "MainWindowModeKiosk", "AnalyticsSystemClient",
        "SaveUserData", "ConfigurationExtensionsAdministration", "InteractiveOpenExtDataProcessors", "InteractiveOpenExtReports",
        "Output",
    ],
    "Constant": [
        "Read", "Update", "View", "Edit",
        "ReadDataHistory", "UpdateDataHistory", "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "ViewDataHistory", "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "DataProcessor": ["Use", "View"],
    "Document": [
        "Read", "Insert", "Update", "Delete",
        "Posting", "UndoPosting", "View", "InteractiveInsert",
        "Edit", "InteractiveDelete", "InteractiveSetDeletionMark", "InteractiveClearDeletionMark",
        "InteractiveDeleteMarked", "InteractivePosting", "InteractivePostingRegular", "InteractiveUndoPosting",
        "InteractiveChangeOfPosted", "InputByString", "ReadDataHistory", "ReadDataHistoryOfMissingData",
        "UpdateDataHistory", "UpdateDataHistoryOfMissingData", "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment",
        "ViewDataHistory", "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "DocumentJournal": ["Read", "View"],
    "ExchangePlan": [
        "Read", "Insert", "Update", "Delete",
        "View", "InteractiveInsert", "Edit", "InteractiveDelete",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDeleteMarked", "InputByString",
        "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData",
        "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment",
        "SwitchToDataHistoryVersion",
    ],
    "FilterCriterion": ["View"],
    "HTTPService": ["Use"],
    "InformationRegister": [
        "Read", "Update", "View", "Edit",
        "TotalsControl", "ReadDataHistory", "ReadDataHistoryOfMissingData", "UpdateDataHistory",
        "UpdateDataHistoryOfMissingData", "UpdateDataHistorySettings", "UpdateDataHistoryVersionComment", "ViewDataHistory",
        "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "IntegrationService": ["Use"],
    "Report": ["Use", "View"],
    "Sequence": ["Read", "Update"],
    "SessionParameter": ["Get", "Set"],
    "Subsystem": ["View"],
    "Task": [
        "Read", "Insert", "Update", "Delete",
        "View", "InteractiveInsert", "Edit", "InteractiveDelete",
        "InteractiveSetDeletionMark", "InteractiveClearDeletionMark", "InteractiveDeleteMarked", "InputByString",
        "InteractiveActivate", "Execute", "InteractiveExecute", "ReadDataHistory",
        "ReadDataHistoryOfMissingData", "UpdateDataHistory", "UpdateDataHistoryOfMissingData", "UpdateDataHistorySettings",
        "UpdateDataHistoryVersionComment", "ViewDataHistory", "EditDataHistoryVersionComment", "SwitchToDataHistoryVersion",
    ],
    "WebService": ["Use"],
}

NESTED_RIGHT_ORDER = {
    "AccountingFlag": ["View", "Edit"],
    "AddressingAttribute": ["View", "Edit"],
    "Attribute": ["View", "Edit"],
    "Command": ["View"],
    "Dimension": ["View", "Edit"],
    "ExtDimensionAccountingFlag": ["View", "Edit"],
    "IntegrationServiceChannel": ["Use"],
    "Method": ["Use"],
    "Operation": ["Use"],
    "Recalculation": ["Read", "Update"],
    "Resource": ["View", "Edit"],
    "StandardAttribute": ["View", "Edit"],
    "StandardTabularSection": ["View", "Edit"],
    "Subsystem": ["View"],
    "TabularSection": ["View", "Edit"],
}

# Каталоги объектов метаданных — нужны, чтобы прочитать uuid и расставить <object>.
TYPE_DIRS = {
    "Catalog": "Catalogs", "Document": "Documents", "DocumentJournal": "DocumentJournals",
    "Sequence": "Sequences", "Constant": "Constants", "Report": "Reports",
    "DataProcessor": "DataProcessors", "InformationRegister": "InformationRegisters",
    "AccumulationRegister": "AccumulationRegisters", "AccountingRegister": "AccountingRegisters",
    "CalculationRegister": "CalculationRegisters", "ChartOfAccounts": "ChartsOfAccounts",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes", "ExchangePlan": "ExchangePlans",
    "BusinessProcess": "BusinessProcesses", "Task": "Tasks", "Subsystem": "Subsystems",
    "CommonForm": "CommonForms", "CommonCommand": "CommonCommands",
    "CommonAttribute": "CommonAttributes", "FilterCriterion": "FilterCriteria",
    "SessionParameter": "SessionParameters", "WebService": "WebServices",
    "HTTPService": "HTTPServices", "IntegrationService": "IntegrationServices",
    "ExternalDataSource": "ExternalDataSources",
}


def sort_rights_canonical(object_name, rights):
    """Порядок прав объекта: известные — по таблице, незнакомые — следом, в порядке ввода."""
    parts = object_name.split('.')
    order = NESTED_RIGHT_ORDER.get(parts[-2]) if len(parts) >= 3 else RIGHT_ORDER.get(parts[0])
    if not order:
        return rights
    by_name = {}
    for r in rights:
        by_name.setdefault(r['Name'], r)
    sorted_rights = []
    for name in order:
        if name in by_name:
            sorted_rights.append(by_name.pop(name))
    for r in rights:
        if r['Name'] in by_name:
            sorted_rights.append(by_name.pop(r['Name']))
    return sorted_rights


# У стандартных реквизитов и стандартных табличных частей uuid в выгрузке нет: они системные.
# Отсутствие uuid для них — норма, а не потерянный объект.
def is_standard_kind(object_name):
    parts = object_name.split('.')
    if len(parts) < 3:
        return False
    return parts[-2].startswith("Standard")


# uuid объекта прав: у верхнего уровня — из файла объекта, у вложенного — спуском по дереву.
# Искать регуляркой по всему файлу нельзя: реквизит шапки и реквизит табличной части часто
# называются одинаково, и поиск нашёл бы первый попавшийся. Дочерние подсистемы лежат
# отдельными файлами, поэтому для них спуск идёт по каталогам.
# У стандартных реквизитов uuid в выгрузке нет вовсе — для них возвращаем None молча.
def get_rights_object_uuid(object_name, config_root):
    parts = object_name.split('.')
    if parts[0] == 'Configuration':
        cfg_path = os.path.join(config_root, 'Configuration.xml')
        if not os.path.isfile(cfg_path):
            return None
        with open(cfg_path, 'r', encoding='utf-8-sig') as f:
            m = re.search(r'<Configuration uuid="([0-9a-fA-F-]+)"', f.read())
        return m.group(1) if m else None
    directory = TYPE_DIRS.get(parts[0])
    if not directory or len(parts) < 2:
        return None
    # Подсистемы вложены каталогами: Subsystems/Родитель/Subsystems/Ребёнок.xml
    owner_path = os.path.join(config_root, directory, parts[1] + '.xml')
    i = 2
    while len(parts) > i + 1 and parts[i] == 'Subsystem':
        owner_path = os.path.join(os.path.splitext(owner_path)[0], 'Subsystems', parts[i + 1] + '.xml')
        i += 2
    if not os.path.isfile(owner_path):
        return None
    try:
        tree = etree.parse(owner_path)
    except Exception:
        return None
    md = '{http://v8.1c.ru/8.3/MDClasses}'
    node = tree.getroot()[0] if len(tree.getroot()) else None
    if node is None:
        return None
    # Оставшиеся пары «вид, имя» ищем строго внутри текущего узла.
    while i + 1 < len(parts):
        kind, name = parts[i], parts[i + 1]
        child = None
        for candidate in node.findall(f'{md}ChildObjects/{md}{kind}'):
            props = candidate.find(f'{md}Properties/{md}Name')
            if props is not None and (props.text or '') == name:
                child = candidate
                break
        if child is None:
            return None
        node = child
        i += 2
    return node.get('uuid')


def sort_objects_by_uuid(objects, config_root):
    """Порядок узлов: по uuid объекта; неразрешённые — в конец, в порядке ввода."""
    known, unknown = [], []
    for o in objects:
        uuid_value = get_rights_object_uuid(o['Name'], config_root)
        if uuid_value:
            known.append((uuid_value, o))
        else:
            print(f"[role-compile] {o['Name']}: объект не найден в выгрузке, uuid неизвестен — "
                  f"узел записан в конец (платформа переставит его при первой выгрузке)",
                  file=sys.stderr)
            unknown.append(o)
    known.sort(key=lambda pair: pair[0])
    return [o for _, o in known] + unknown


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


# "@путь" в значении условия — текст берётся из файла: условия RLS типовых занимают десятки

def resolve_text_from_file(val, base_dir):
    if not val.startswith("@"):
        return val
    file_path = val[1:]
    if os.path.isabs(file_path):
        candidates = [file_path]
    else:
        candidates = [
            os.path.join(base_dir, file_path),
            os.path.join(os.getcwd(), file_path),
        ]
    for c in candidates:
        if os.path.exists(c):
            with open(c, 'r', encoding='utf-8-sig') as f:
                return f.read().rstrip()
    print(f"Файл значения не найден: {file_path} (искали: {', '.join(candidates)})", file=sys.stderr)
    sys.exit(1)


TEXT_BASE_DIR = os.getcwd()

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



def esc_xml(s):
    # Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def esc_xml_text(s):
    """Экранирование ТЕКСТА элемента: только & < > . Кавычки платформа в тексте не экранирует
    (92142 сырых кавычки на корпус, ни одной &quot;); &quot; она принимает, но нормализует обратно."""
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')



def get_child_indent(container):
    """Detect indentation of children inside a container element."""
    if container.text and "\n" in container.text:
        after_nl = container.text.rsplit("\n", 1)[-1]
        if after_nl and not after_nl.strip():
            return after_nl
    for child in container:
        if child.tail and "\n" in child.tail:
            after_nl = child.tail.rsplit("\n", 1)[-1]
            if after_nl and not after_nl.strip():
                return after_nl
    # Fallback: count depth
    depth = 0
    current = container
    while current is not None:
        depth += 1
        current = current.getparent()
    return "\t" * depth


def insert_before_closing(container, new_el, child_indent):
    """Insert new_el before the closing tag of container, with proper indentation."""
    children = list(container)
    if len(children) == 0:
        # Empty element: set text to newline+indent, tail of new_el to newline+parent_indent
        parent_indent = child_indent[:-1] if len(child_indent) > 0 else ""
        container.text = "\r\n" + child_indent
        new_el.tail = "\r\n" + parent_indent
        container.append(new_el)
    else:
        last = children[-1]
        new_el.tail = last.tail
        last.tail = "\r\n" + child_indent
        container.append(new_el)


def remove_with_indent(el):
    """Remove element and clean up surrounding whitespace."""
    parent = el.getparent()
    prev = el.getprevious()
    if prev is not None:
        # Transfer el.tail to prev.tail
        if el.tail and el.tail.strip() == "":
            pass  # just drop extra whitespace
        prev.tail = el.tail if el.tail and el.tail.strip() else (prev.tail or "")
        # Actually try to keep the prev's tail as the closing indent
        # Better approach: set prev.tail to what el.tail was (newline+indent of next or closing)
        if el.tail:
            prev.tail = el.tail
    else:
        # First child: adjust parent.text
        if el.tail:
            parent.text = el.tail
    parent.remove(el)


def expand_self_closing(container, parent_indent):
    """If container is self-closing (no children, no text), add closing whitespace."""
    if len(container) == 0 and not (container.text and container.text.strip()):
        container.text = "\r\n" + parent_indent


def import_fragment(xml_string, doc_root):
    """Parse an XML fragment in the MD namespace context and return elements."""
    wrapper = (
        f'<_W xmlns="{MD_NS}" xmlns:xsi="{XSI_NS}" xmlns:v8="{V8_NS}" '
        f'xmlns:xr="{XR_NS}" xmlns:xs="{XS_NS}">{xml_string}</_W>'
    )
    frag = etree.fromstring(wrapper.encode("utf-8"))
    nodes = []
    for child in frag:
        nodes.append(child)
    return nodes


def parse_value_list(val, op_name):
    """Parse a string or JSON array into a list of strings."""
    val = val.strip()
    if val.startswith("["):
        arr = ci_json(parse_json_input(val, "-Value for operation '%s'" % op_name, "a JSON array of object names", inline=True))
        return [str(item) for item in arr]
    return [val]



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

ROLES_NS = "http://v8.1c.ru/8.2/roles"
MD_OBJECT_NS = "http://v8.1c.ru/8.3/MDClasses"
V8_NS = "http://v8.1c.ru/8.1/data/core"

# --- Стандартные реквизиты в списке полей RLS платформа пишет по-английски ---
FIELD_ALIASES = {
    "Ссылка": "Ref", "Код": "Code", "Наименование": "Description", "Родитель": "Parent",
    "Владелец": "Owner", "Дата": "Date", "Номер": "Number", "ПометкаУдаления": "DeletionMark",
    "ЭтоГруппа": "IsFolder", "Проведен": "Posted", "Проведён": "Posted", "ВерсияДанных": "DataVersion",
    "Предопределенный": "Predefined", "Предопределённый": "Predefined",
}


def translate_field_name(name):
    for key, value in FIELD_ALIASES.items():
        if key.lower() == name.lower():
            return value
    return name


def rt(tag):
    return "{%s}%s" % (ROLES_NS, tag)


def node_text(parent, tag):
    child = parent.find(rt(tag))
    return child.text or "" if child is not None else ""


# --- Резолв пути роли ---
# Принимаем всё, чем роль называют в обиходе: каталог роли, файл метаданных, сам Rights.xml.
def resolve_role_paths(input_path):
    if not os.path.exists(input_path):
        print(f"[role-edit] Путь не найден: {input_path}", file=sys.stderr)
        sys.exit(1)
    full = os.path.abspath(input_path)
    rights_path = None
    if os.path.isfile(full):
        if os.path.basename(full) == "Rights.xml":
            rights_path = full
        else:
            # Roles/Имя.xml — рядом лежит каталог Имя/Ext/Rights.xml
            name = os.path.splitext(os.path.basename(full))[0]
            rights_path = os.path.join(os.path.dirname(full), name, "Ext", "Rights.xml")
    else:
        for candidate in (os.path.join(full, "Ext", "Rights.xml"), os.path.join(full, "Rights.xml")):
            if os.path.isfile(candidate):
                rights_path = candidate
                break
    if not rights_path or not os.path.isfile(rights_path):
        print(f"[role-edit] Rights.xml не найден для пути: {input_path}", file=sys.stderr)
        print("  Ожидается каталог роли, Roles/Имя.xml или Roles/Имя/Ext/Rights.xml.", file=sys.stderr)
        sys.exit(1)
    rights_path = os.path.abspath(rights_path)
    # Rights.xml лежит в <Roles>/<Имя>/Ext/, метаданные — в <Roles>/<Имя>.xml
    role_dir = os.path.dirname(os.path.dirname(rights_path))
    role_name = os.path.basename(role_dir)
    roles_dir = os.path.dirname(role_dir)
    return {
        "RightsPath": rights_path,
        "RoleXmlPath": os.path.join(roles_dir, role_name + ".xml"),
        "RoleName": role_name,
        "ConfigRoot": os.path.dirname(roles_dir),
    }


class Editor:
    """Состояние правки: дерево прав, счётчики, отложенные операции."""

    def __init__(self, paths, text_base_dir):
        self.paths = paths
        # База относительного пути @файла: каталог списка операций, иначе каталог самой роли.
        # Текущий каталог функция проверяет вторым кандидатом в любом случае.
        self.text_base_dir = text_base_dir
        parser = etree.XMLParser(remove_blank_text=False)
        self.tree = etree.parse(paths["RightsPath"], parser)
        self.root = self.tree.getroot()
        self.format_version = self.root.get("version") or "2.17"
        self.format_rank = format_rank(self.format_version)
        self.meta_tree = None
        self.rights_dirty = False
        self.meta_dirty = False
        self.add_count = 0
        self.remove_count = 0
        self.modify_count = 0
        self.notes = []
        self.pending = []
        # Умолчания роли решают, какие записи платформа хранит: совпавшее с умолчанием она выбрасывает.
        self.role_sfno = node_text(self.root, "setForNewObjects")
        self.role_sfab = node_text(self.root, "setForAttributesByDefault")
        self.dropped_by_default = []

    def note(self, text):
        self.notes.append(text)

    def right_stored(self, obj_name, right_name, value):
        if value != get_default_right_value(obj_name, self.role_sfno, self.role_sfab):
            return True
        self.dropped_by_default.append(f"{obj_name}.{right_name}")
        return False

    # --- Разбор значений операций ---

    def parse_batch(self, value):
        # Делим ДО чтения файлов, поэтому ';;' внутри условия из файла разделителем не становится.
        return [part.strip() for part in value.split(";;") if part.strip()]


    @staticmethod
    def split_at_top_level_colon(text, open_char, close_char):
        depth = 0
        for i, ch in enumerate(text):
            if ch == open_char:
                depth += 1
            elif ch == close_char:
                if depth > 0:
                    depth -= 1
            elif ch == ":" and depth == 0:
                return text[:i].strip(), text[i + 1:].strip(), True
        return text.strip(), "", False

    def parse_rights_spec(self, text, allow_no_rights=False):
        left, right, found = self.split_at_top_level_colon(text, "[", "]")
        if not found:
            if not allow_no_rights:
                add_validation_error(f"{text} : ожидается 'Тип.Имя: Право1, Право2' или 'Тип.Имя: @пресет'")
                return None
            obj_name = translate_object_name(left)
            if not validate_object_name(obj_name):
                return None
            return {"Name": obj_name, "Rights": []}
        obj_name = translate_object_name(left)
        if not validate_object_name(obj_name):
            return None
        object_type = get_object_type(obj_name)
        if right.startswith("@"):
            right_names = resolve_preset(object_type, right)
        else:
            right_names = [translate_right_name(r.strip()) for r in right.split(",") if r.strip()]
        valid = [r for r in right_names if validate_right_name(obj_name, r)]
        return {"Name": obj_name, "Rights": valid}

    def parse_rls_address(self, text, condition_required=False):
        address, condition, found = self.split_at_top_level_colon(text, "[", "]")
        if condition_required and not found:
            add_validation_error(f"{text} : ожидается 'Тип.Имя.Право: условие' (условие может быть пустым)")
            return None
        fields = []
        if address.endswith("]"):
            open_idx = address.rfind("[")
            if open_idx < 0:
                add_validation_error(f"{text} : не закрыта скобка списка полей")
                return None
            fields_part = address[open_idx + 1:-1]
            address = address[:open_idx].strip()
            fields = [translate_field_name(f.strip()) for f in fields_part.split(",") if f.strip()]
            if not fields:
                add_validation_error(f"{text} : пустой список полей — уберите скобки, если ограничение на все поля")
                return None
        last_dot = address.rfind(".")
        if last_dot < 1:
            add_validation_error(f"{text} : ожидается 'Тип.Имя.Право', последний сегмент — имя права")
            return None
        obj_name = translate_object_name(address[:last_dot])
        right_name = translate_right_name(address[last_dot + 1:])
        if not validate_object_name(obj_name):
            return None
        if not validate_right_name(obj_name, right_name):
            # Показываем разбор: иначе непонятно, что навык откусил не тот сегмент.
            add_validation_error(f"{text} : разобрано как объект '{obj_name}' и право '{right_name}'")
            return None
        return {"Object": obj_name, "Right": right_name, "Fields": fields,
                "Condition": resolve_text_from_file(condition, self.text_base_dir)}

    def parse_template_spec(self, text, name_only=False):
        left, right, found = self.split_at_top_level_colon(text, "(", ")")
        if name_only:
            return {"Name": left, "Condition": None}
        if not found:
            add_validation_error(f"{text} : ожидается 'Имя(Параметры): условие'")
            return None
        return {"Name": left, "Condition": resolve_text_from_file(right, self.text_base_dir)}

    # --- Доступ к дереву прав ---

    def object_nodes(self):
        return self.root.findall(rt("object"))

    def find_object(self, name):
        for node in self.object_nodes():
            if node_text(node, "name").lower() == name.lower():
                return node
        return None

    @staticmethod
    def right_nodes(obj_node):
        return obj_node.findall(rt("right"))

    def find_right(self, obj_node, right_name):
        for node in self.right_nodes(obj_node):
            if node_text(node, "name").lower() == right_name.lower():
                return node
        return None

    def true_right_names(self, obj_node):
        return [node_text(n, "name") for n in self.right_nodes(obj_node) if node_text(n, "value") == "true"]

    @staticmethod
    def child_indent(container):
        return get_child_indent(container)

    def insert_child(self, container, new_el, ref_el, child_indent):
        """Вставка с отступом: перед ref_el, либо последним ребёнком контейнера."""
        parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
        if ref_el is not None:
            new_el.tail = "\r\n" + child_indent
            ref_el.addprevious(new_el)
            return
        children = list(container)
        if children:
            new_el.tail = children[-1].tail
            children[-1].tail = "\r\n" + child_indent
            container.append(new_el)
        else:
            container.text = "\r\n" + child_indent
            new_el.tail = "\r\n" + parent_indent
            container.append(new_el)

    @staticmethod
    def remove_child(el):
        remove_with_indent(el)

    def make_right(self, name, value, indent):
        xml = (f"<right>\r\n{indent}\t<name>{esc_xml_text(name)}</name>\r\n"
               f"{indent}\t<value>{value}</value>\r\n{indent}</right>")
        return self.fragment(xml)

    def make_object(self, obj_name, indent):
        xml = f"<object>\r\n{indent}\t<name>{esc_xml_text(obj_name)}</name>\r\n{indent}</object>"
        return self.fragment(xml)

    @staticmethod
    def fragment(xml_string):
        wrapper = f'<_W xmlns="{ROLES_NS}">{xml_string}</_W>'
        parsed = etree.fromstring(wrapper.encode("utf-8"), etree.XMLParser(remove_blank_text=False))
        return parsed[0]

    # Порядок прав внутри узла у платформы фиксирован для типа — новое право встаёт на своё место.
    def insert_right_canonical(self, obj_node, new_el, obj_name):
        parts = obj_name.split(".")
        order = NESTED_RIGHT_ORDER.get(parts[-2]) if len(parts) >= 3 else RIGHT_ORDER.get(parts[0])
        new_name = node_text(new_el, "name")
        ref = None
        if order and new_name in order:
            new_index = order.index(new_name)
            for node in self.right_nodes(obj_node):
                name = node_text(node, "name")
                if name in order and order.index(name) > new_index:
                    ref = node
                    break
        self.insert_child(obj_node, new_el, ref, self.child_indent(obj_node))

    # Узлы <object> платформа держит в порядке uuid объекта метаданных.
    def insert_object_node(self, new_el, obj_name):
        indent = self.child_indent(self.root)
        uuid_value = get_rights_object_uuid(obj_name, self.paths["ConfigRoot"])
        ref = None
        if uuid_value:
            for node in self.object_nodes():
                other = get_rights_object_uuid(node_text(node, "name"), self.paths["ConfigRoot"])
                if other and other > uuid_value:
                    ref = node
                    break
        elif not is_standard_kind(obj_name):
            self.note(f"[WARN] {obj_name}: объект не найден в выгрузке, uuid неизвестен — "
                      f"узел записан перед шаблонами (платформа переставит его при первой выгрузке)")
        if ref is None:
            templates = self.root.findall(rt("restrictionTemplate"))
            if templates:
                ref = templates[0]
        self.insert_child(self.root, new_el, ref, indent)

    # Пустых узлов платформа не производит. Узел с одними запретами — производит (так закрывают
    # реквизит), поэтому смотрим на наличие прав вообще, а не только разрешающих.
    def remove_object_if_empty(self, obj_node):
        if self.right_nodes(obj_node):
            return
        name = node_text(obj_node, "name")
        self.remove_child(obj_node)
        self.note(f"     {name}: прав не осталось — узел объекта удалён")

    # --- Зависимости ---

    @staticmethod
    def allowed_rights(obj_name):
        parts = obj_name.split(".")
        if len(parts) >= 3:
            return get_nested_rights(parts[0], get_nested_kind(obj_name))
        return KNOWN_RIGHTS.get(parts[0])

    @staticmethod
    def direct_deps(object_type, right_name):
        by_type = RIGHT_DEPS_BY_TYPE.get(object_type, {})
        if right_name in by_type:
            return by_type[right_name]
        return RIGHT_DEPS.get(right_name, [])

    def dependent_rights(self, obj_name, right_name):
        # Кто требует это право: снимаем его — обязаны снять и их, иначе платформа вернёт снятое.
        # У вложенных объектов это работает и для запретов: View=false тянет Edit=false.
        object_type = obj_name.split(".")[0]
        allowed = self.allowed_rights(obj_name)
        if not allowed:
            return []
        result = []
        queue = [right_name]
        while queue:
            current = queue.pop(0)
            for candidate in allowed:
                if candidate in result or candidate == right_name:
                    continue
                if current in self.direct_deps(object_type, candidate):
                    result.append(candidate)
                    queue.append(candidate)
        return result

    # --- Операции ---

    def apply_add_rights(self, spec):
        obj_node = self.find_object(spec["Name"])
        created = False
        if obj_node is None:
            obj_node = self.make_object(spec["Name"], self.child_indent(self.root))
            self.insert_object_node(obj_node, spec["Name"])
            created = True
        existing = [node_text(n, "name") for n in self.right_nodes(obj_node)]
        wanted = list(spec["Rights"])
        merged, seen = [], set()
        for name in existing + wanted:
            if name not in seen:
                seen.add(name)
                merged.append({"Name": name, "Value": "true", "Condition": None})
        # Платформа при загрузке всё равно доведёт набор до замыкания — пишем его сразу.
        closed, _ = close_rights_dependencies(spec["Name"], merged, self.format_rank)
        added = []
        indent = self.child_indent(obj_node)
        for right in closed:
            name = right["Name"]
            if not self.right_stored(spec["Name"], name, "true"):
                continue
            node = self.find_right(obj_node, name)
            if node is not None:
                if node_text(node, "value") != "true":
                    node.find(rt("value")).text = "true"
                    added.append(name)
                    self.modify_count += 1
                    self.rights_dirty = True
                continue
            new_el = self.make_right(name, "true", indent)
            self.insert_right_canonical(obj_node, new_el, spec["Name"])
            added.append(name)
            self.add_count += 1
            self.rights_dirty = True
        if created and not added:
            self.remove_child(obj_node)
            return
        if added:
            extra = [a for a in added if a not in wanted]
            note = f"     {spec['Name']}: добавлено — {', '.join(added)}"
            if extra:
                note += f" (по зависимости: {', '.join(extra)})"
            self.note(note)
        else:
            self.note(f"     {spec['Name']}: права уже выданы, изменений нет")

    def apply_set_rights(self, spec):
        obj_node = self.find_object(spec["Name"])
        if obj_node is None:
            self.apply_add_rights(spec)
            return
        dropped_rls = 0
        for node in self.right_nodes(obj_node):
            if node.find(rt("restrictionByCondition")) is not None:
                dropped_rls += 1
            self.remove_child(node)
            self.remove_count += 1
        closed, _ = close_rights_dependencies(
            spec["Name"], [{"Name": r, "Value": "true", "Condition": None} for r in spec["Rights"]],
            self.format_rank)
        indent = self.child_indent(obj_node)
        for right in closed:
            if not self.right_stored(spec["Name"], right["Name"], "true"):
                continue
            new_el = self.make_right(right["Name"], "true", indent)
            self.insert_right_canonical(obj_node, new_el, spec["Name"])
            self.add_count += 1
        self.rights_dirty = True
        self.note(f"     {spec['Name']}: набор прав заменён")
        if dropped_rls:
            self.note(f"[WARN] {spec['Name']}: снято ограничений RLS: {dropped_rls}")
        self.remove_object_if_empty(obj_node)

    def apply_remove_rights(self, spec):
        obj_node = self.find_object(spec["Name"])
        if obj_node is None:
            self.note(f"     {spec['Name']}: объекта нет в роли, пропуск")
            return
        if not spec["Rights"]:
            self.remove_child(obj_node)
            self.remove_count += 1
            self.rights_dirty = True
            self.note(f"     {spec['Name']}: узел объекта удалён")
            return
        # Каскад: право, которое требует снимаемое, платформа вернула бы обратно.
        to_remove = []
        for right_name in spec["Rights"]:
            to_remove.append(right_name)
            for dependent in self.dependent_rights(spec["Name"], right_name):
                if dependent not in to_remove:
                    to_remove.append(dependent)
        removed = []
        for right_name in to_remove:
            node = self.find_right(obj_node, right_name)
            if node is None:
                continue
            self.remove_child(node)
            removed.append(right_name)
            self.remove_count += 1
            self.rights_dirty = True
        if not removed:
            self.note(f"     {spec['Name']}: перечисленных прав нет, изменений нет")
            return
        cascade = [r for r in removed if r not in spec["Rights"]]
        note = f"     {spec['Name']}: снято — {', '.join(removed)}"
        if cascade:
            note += f" (каскадом: {', '.join(cascade)})"
        self.note(note)
        self.remove_object_if_empty(obj_node)

    def apply_deny_rights(self, spec):
        obj_node = self.find_object(spec["Name"])
        created = False
        if obj_node is None:
            obj_node = self.make_object(spec["Name"], self.child_indent(self.root))
            self.insert_object_node(obj_node, spec["Name"])
            created = True
        to_deny = []
        for right_name in spec["Rights"]:
            to_deny.append(right_name)
            for dependent in self.dependent_rights(spec["Name"], right_name):
                if dependent not in to_deny:
                    to_deny.append(dependent)
        denied = []
        indent = self.child_indent(obj_node)
        for right_name in to_deny:
            if not self.right_stored(spec["Name"], right_name, "false"):
                continue
            node = self.find_right(obj_node, right_name)
            if node is not None:
                if node_text(node, "value") == "false":
                    continue
                node.find(rt("value")).text = "false"
                self.modify_count += 1
            else:
                new_el = self.make_right(right_name, "false", indent)
                self.insert_right_canonical(obj_node, new_el, spec["Name"])
                self.add_count += 1
            denied.append(right_name)
            self.rights_dirty = True
        if not denied:
            if created:
                self.remove_child(obj_node)
            reason = ("запрет совпадает с умолчанием роли и платформой не хранится"
                      if any(d.startswith(spec['Name'] + '.') for d in self.dropped_by_default)
                      else "права уже запрещены")
            self.note(f"     {spec['Name']}: {reason}, изменений нет")
            return
        cascade = [r for r in denied if r not in spec["Rights"]]
        note = f"     {spec['Name']}: запрещено — {', '.join(denied)}"
        if cascade:
            note += f" (каскадом: {', '.join(cascade)})"
        self.note(note)

    # --- RLS ---

    @staticmethod
    def restriction_fields(node):
        return [f.text or "" for f in node.findall(rt("field"))]

    @staticmethod
    def same_field_set(a, b):
        return sorted(x.lower() for x in a) == sorted(x.lower() for x in b)

    def make_restriction(self, indent, fields, condition):
        # Поля платформа держит отсортированными ordinal, условие без полей идёт первой строкой.
        inner = ""
        for field in sorted(fields):
            inner += f"{indent}\t<field>{esc_xml_text(field)}</field>\r\n"
        if condition:
            inner += f"{indent}\t<condition>{esc_xml_text(condition)}</condition>\r\n"
        else:
            inner += f"{indent}\t<condition/>\r\n"
        return self.fragment(f"<restrictionByCondition>\r\n{inner}{indent}</restrictionByCondition>")

    def apply_set_rls(self, spec):
        obj_node = self.find_object(spec["Object"])
        right_node = self.find_right(obj_node, spec["Right"]) if obj_node is not None else None
        if right_node is None or node_text(right_node, "value") != "true":
            add_validation_error(f"{spec['Object']}.{spec['Right']}: право не выдано — сначала add-rights, "
                                 f"ограничение без права платформа игнорирует")
            return
        indent = self.child_indent(obj_node) + "\t"
        existing = right_node.findall(rt("restrictionByCondition"))
        target = None
        for node in existing:
            if self.same_field_set(self.restriction_fields(node), spec["Fields"]):
                target = node
                break
        # Ссылка на шаблон, которого в роли нет, — тихая ошибка в рантайме 1С. Отказывать нельзя:
        # шаблон могут добавить следующей операцией или следующим вызовом.
        for m in re.finditer(r'#([A-Za-zА-Яа-яЁё0-9_]+)\s*\(', spec["Condition"] or ""):
            template_name = m.group(1)
            if template_name in ("Если", "Тогда", "Иначе", "КонецЕсли"):
                continue
            if self.find_template(template_name) is None:
                print(f"[role-edit] {spec['Object']}.{spec['Right']}: условие ссылается на шаблон "
                      f"'{template_name}', которого в роли нет", file=sys.stderr)
        new_el = self.make_restriction(indent, spec["Fields"], spec["Condition"])
        if target is not None:
            new_el.tail = target.tail
            target.getparent().replace(target, new_el)
            self.modify_count += 1
            self.note(f"     {spec['Object']}.{spec['Right']}: ограничение заменено")
        else:
            # Строка без полей («прочие поля») идёт первой, строки с полями — после неё.
            ref = None
            if not spec["Fields"]:
                for node in existing:
                    if self.restriction_fields(node):
                        ref = node
                        break
            self.insert_child(right_node, new_el, ref, indent)
            self.add_count += 1
            self.note(f"     {spec['Object']}.{spec['Right']}: ограничение добавлено")
        self.rights_dirty = True

    def apply_remove_rls(self, spec):
        obj_node = self.find_object(spec["Object"])
        if obj_node is None:
            self.note(f"     {spec['Object']}: объекта нет в роли, пропуск")
            return
        right_node = self.find_right(obj_node, spec["Right"])
        if right_node is None:
            self.note(f"     {spec['Object']}.{spec['Right']}: права нет в роли, пропуск")
            return
        removed = 0
        for node in right_node.findall(rt("restrictionByCondition")):
            # Адрес без скобок снимает все ограничения права, со скобками — строку с этим набором полей.
            if spec["Fields"] and not self.same_field_set(self.restriction_fields(node), spec["Fields"]):
                continue
            self.remove_child(node)
            removed += 1
        if not removed:
            self.note(f"     {spec['Object']}.{spec['Right']}: ограничений нет, изменений нет")
            return
        self.remove_count += removed
        self.rights_dirty = True
        self.note(f"     {spec['Object']}.{spec['Right']}: снято ограничений — {removed}")

    # --- Шаблоны ---

    @staticmethod
    def template_identifier(name):
        paren = name.find("(")
        return name[:paren].strip() if paren > 0 else name.strip()

    def find_template(self, name):
        wanted = self.template_identifier(name).lower()
        for node in self.root.findall(rt("restrictionTemplate")):
            if self.template_identifier(node_text(node, "name")).lower() == wanted:
                return node
        return None

    def apply_add_template(self, spec, allow_replace=False):
        existing = self.find_template(spec["Name"])
        if existing is not None and not allow_replace:
            add_validation_error(f"{spec['Name']}: шаблон с таким именем уже есть — используйте set-template")
            return
        indent = self.child_indent(self.root)
        xml = (f"<restrictionTemplate>\r\n{indent}\t<name>{esc_xml_text(spec['Name'])}</name>\r\n"
               f"{indent}\t<condition>{esc_xml_text(spec['Condition'])}</condition>\r\n"
               f"{indent}</restrictionTemplate>")
        new_el = self.fragment(xml)
        if existing is not None:
            new_el.tail = existing.tail
            existing.getparent().replace(existing, new_el)
            self.modify_count += 1
            self.note(f"     {spec['Name']}: шаблон заменён")
        else:
            self.insert_child(self.root, new_el, None, indent)
            self.add_count += 1
            self.note(f"     {spec['Name']}: шаблон добавлен")
        self.rights_dirty = True

    def apply_remove_template(self, spec):
        node = self.find_template(spec["Name"])
        if node is None:
            self.note(f"     {spec['Name']}: шаблона нет в роли, пропуск")
            return
        # Ссылка на удалённый шаблон — тихая ошибка в рантайме, поэтому показываем, кто им пользуется.
        identifier = self.template_identifier(spec["Name"])
        users = []
        for obj_node in self.object_nodes():
            for right_node in self.right_nodes(obj_node):
                for restriction in right_node.findall(rt("restrictionByCondition")):
                    condition = restriction.find(rt("condition"))
                    if condition is not None and condition.text and re.search(
                            "#" + re.escape(identifier) + r"\s*\(", condition.text):
                        users.append(f"{node_text(obj_node, 'name')}.{node_text(right_node, 'name')}")
        self.remove_child(node)
        self.remove_count += 1
        self.rights_dirty = True
        self.note(f"     {spec['Name']}: шаблон удалён")
        if users:
            print(f"[role-edit] На шаблон '{identifier}' ещё ссылаются: {', '.join(users)}", file=sys.stderr)

    # --- Глобальные флаги ---

    def apply_modify_property(self, spec):
        node = self.root.find(rt(spec["Name"]))
        if node is None:
            self.note(f"[WARN] {spec['Name']}: свойства нет в файле роли, пропуск")
            return
        if (node.text or "") == spec["Value"]:
            self.note(f"     {spec['Name']}: уже {spec['Value']}, изменений нет")
            return
        node.text = spec["Value"]
        # Умолчания решают, какие записи вообще пишутся, — следующие операции должны видеть новое значение.
        if spec["Name"] == "setForNewObjects":
            self.role_sfno = spec["Value"]
        if spec["Name"] == "setForAttributesByDefault":
            self.role_sfab = spec["Value"]
        self.modify_count += 1
        self.rights_dirty = True
        self.note(f"     {spec['Name']} = {spec['Value']}")
        # Измерено: при setForNewObjects=true платформа перестаёт хранить права, совпадающие с
        # автоматически выдаваемыми, и переписывает файл роли целиком.
        if spec["Name"] == "setForNewObjects" and spec["Value"] == "true":
            print("[role-edit] setForNewObjects=true: платформа пересчитает хранимые права роли "
                  "при первой же загрузке — часть явных записей исчезнет", file=sys.stderr)

    # --- Метаданные роли ---

    def edit_role_metadata(self, field, text):
        path = self.paths["RoleXmlPath"]
        if not os.path.isfile(path):
            add_validation_error(f"Файл метаданных роли не найден: {path}")
            return
        if self.meta_tree is None:
            self.meta_tree = etree.parse(path, etree.XMLParser(remove_blank_text=False))
        props = self.meta_tree.getroot().find("{%s}Role/{%s}Properties" % (MD_OBJECT_NS, MD_OBJECT_NS))
        if props is None:
            add_validation_error(f"В метаданных роли нет блока <Properties>: {path}")
            return
        node = props.find("{%s}%s" % (MD_OBJECT_NS, field))
        indent = get_child_indent(props)
        if field == "Synonym":
            if text:
                xml = (f"<Synonym>\r\n{indent}\t<v8:item>\r\n{indent}\t\t<v8:lang>ru</v8:lang>\r\n"
                       f"{indent}\t\t<v8:content>{esc_xml_text(text)}</v8:content>\r\n"
                       f"{indent}\t</v8:item>\r\n{indent}</Synonym>")
            else:
                xml = "<Synonym/>"
        else:
            xml = f"<Comment>{esc_xml_text(text)}</Comment>" if text else "<Comment/>"
        wrapper = f'<_W xmlns="{MD_OBJECT_NS}" xmlns:v8="{V8_NS}">{xml}</_W>'
        new_el = etree.fromstring(wrapper.encode("utf-8"), etree.XMLParser(remove_blank_text=False))[0]
        if node is not None:
            new_el.tail = node.tail
            props.replace(node, new_el)
        else:
            self.insert_child(props, new_el, None, indent)
        self.meta_dirty = True
        self.modify_count += 1
        self.note(f"     {field} обновлён в метаданных роли")


def save_tree(tree, path):
    style = _detect_xml_style(path)
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8", standalone=None)
    xml_bytes = _finalize_xml_bytes(xml_bytes, style)
    with open(path, "wb") as f:
        if style is None or style["bom"]:
            f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Edit existing 1C role rights in place", allow_abbrev=False)
    parser.add_argument("-RolePath", "-Path", "-RightsPath", required=True)
    parser.add_argument("-DefinitionFile", default=None)
    parser.add_argument("-Operation", default=None, choices=[
        "add-rights", "set-rights", "remove-rights", "deny-rights", "set-rls", "remove-rls",
        "add-template", "set-template", "remove-template", "modify-property", "set-synonym", "set-comment"])
    parser.add_argument("-Value", default=None)
    parser.add_argument("-NoValidate", action="store_true")
    args = ci_parse_args(parser)

    paths = resolve_role_paths(args.RolePath)

    value = args.Value

    if args.DefinitionFile and args.Operation:
        print("[role-edit] Укажите либо -DefinitionFile, либо -Operation, но не оба сразу", file=sys.stderr)
        sys.exit(1)
    if not args.DefinitionFile and not args.Operation:
        print("[role-edit] Укажите -Operation с -Value или -DefinitionFile", file=sys.stderr)
        sys.exit(1)

    target_for_guard = paths["RoleXmlPath"] if os.path.isfile(paths["RoleXmlPath"]) else paths["RightsPath"]
    assert_edit_allowed(target_for_guard, "editable")

    text_base_dir = (os.path.dirname(os.path.abspath(args.DefinitionFile)) if args.DefinitionFile
                     else os.path.dirname(paths["RightsPath"]))
    ed = Editor(paths, text_base_dir)

    operations = []
    if args.DefinitionFile:
        data = ci_json(parse_json_input(read_json_file(args.DefinitionFile),
                                        f"-DefinitionFile '{args.DefinitionFile}'",
                                        "a JSON object or array of operations"))
        items = data if isinstance(data, list) else [data]
        for item in items:
            op_name = str(item.get("operation") or item.get("op") or "")
            op_value = str(item.get("value") or "")
            operations.append((op_name, op_value))
    else:
        operations.append((args.Operation, value or ""))

    pending = []
    for op_name, op_value in operations:
        key = op_name.strip().lower()
        if key in ("add-rights", "set-rights", "remove-rights", "deny-rights"):
            for item in ed.parse_batch(op_value):
                spec = ed.parse_rights_spec(item, allow_no_rights=(key == "remove-rights"))
                if not spec:
                    continue
                if key == "add-rights":
                    rights = [{"Name": r, "Value": "true", "Condition": None} for r in spec["Rights"]]
                    for expanded in expand_service_entry({"Name": spec["Name"], "Rights": rights},
                                                         paths["ConfigRoot"], paths["RoleName"]):
                        pending.append((key, {"Name": expanded["Name"],
                                              "Rights": [r["Name"] for r in expanded["Rights"]]}))
                else:
                    pending.append((key, spec))
        elif key in ("set-rls", "remove-rls"):
            for item in ed.parse_batch(op_value):
                spec = ed.parse_rls_address(item, condition_required=(key == "set-rls"))
                if spec:
                    pending.append((key, spec))
        elif key in ("add-template", "set-template", "remove-template"):
            for item in ed.parse_batch(op_value):
                spec = ed.parse_template_spec(item, name_only=(key == "remove-template"))
                if spec:
                    pending.append((key, spec))
        elif key == "modify-property":
            allowed = ["setForNewObjects", "setForAttributesByDefault", "independentRightsOfChildObjects"]
            for item in ed.parse_batch(op_value):
                eq = item.find("=")
                if eq < 1:
                    add_validation_error(f"{item} : ожидается 'свойство=true' или 'свойство=false'")
                    continue
                name = item[:eq].strip()
                val = item[eq + 1:].strip().lower()
                canonical = next((a for a in allowed if a.lower() == name.lower()), None)
                if not canonical:
                    add_validation_error(f"{name} : неизвестное свойство роли, допустимы {', '.join(allowed)}")
                    continue
                if val not in ("true", "false"):
                    add_validation_error(f"{item} : значение должно быть true или false")
                    continue
                pending.append((key, {"Name": canonical, "Value": val}))
        elif key == "set-synonym":
            pending.append((key, {"Field": "Synonym", "Text": resolve_text_from_file(op_value, ed.text_base_dir)}))
        elif key == "set-comment":
            pending.append((key, {"Field": "Comment", "Text": resolve_text_from_file(op_value, ed.text_base_dir)}))
        else:
            add_validation_error(f"Неизвестная операция: {op_name}")

    # Отказ до записи: правка роли — это несколько узлов сразу, и наполовину применённая правка
    # хуже неприменённой. Печатаем все причины разом.
    def refuse_if_errors():
        if VALIDATION_ERRORS:
            print(f"[role-edit] Правка не применена: {len(VALIDATION_ERRORS)} ошибок во входе.", file=sys.stderr)
            for err in VALIDATION_ERRORS:
                print(f"  ERROR: {err}", file=sys.stderr)
            sys.exit(1)

    refuse_if_errors()

    handlers = {
        "add-rights": ed.apply_add_rights,
        "set-rights": ed.apply_set_rights,
        "deny-rights": ed.apply_deny_rights,
        "remove-rights": ed.apply_remove_rights,
        "add-template": ed.apply_add_template,
        "set-template": lambda s: ed.apply_add_template(s, allow_replace=True),
        "set-rls": ed.apply_set_rls,
        "remove-rls": ed.apply_remove_rls,
        "remove-template": ed.apply_remove_template,
        "modify-property": ed.apply_modify_property,
        "set-synonym": lambda s: ed.edit_role_metadata(s["Field"], s["Text"]),
        "set-comment": lambda s: ed.edit_role_metadata(s["Field"], s["Text"]),
    }
    # Операции применяются в том порядке, в котором их перечислили.
    for op_key, spec in pending:
        handlers[op_key](spec)

    # Ошибка могла всплыть и на применении (RLS без права) — файл в этом случае не трогаем.
    refuse_if_errors()

    if ed.rights_dirty:
        save_tree(ed.tree, paths["RightsPath"])
    if ed.meta_dirty:
        save_tree(ed.meta_tree, paths["RoleXmlPath"])

    print(f"[OK] Роль '{paths['RoleName']}' обновлена")
    print(f"     Rights:   {paths['RightsPath']}")
    for note in ed.notes:
        print(note)
    print(f"     Added: {ed.add_count}, Removed: {ed.remove_count}, Modified: {ed.modify_count}")
    if ed.dropped_by_default:
        print("[role-edit] Не записаны права, совпадающие с умолчанием роли "
              f"(платформа их не хранит): {', '.join(ed.dropped_by_default)}", file=sys.stderr)
        print("  Запрет хранится у реквизитов и табличных частей (они наследуют права объекта) "
              "либо в роли с setForNewObjects=true; выдача прав — наоборот.", file=sys.stderr)

    if not args.NoValidate:
        validate_script = os.path.normpath(os.path.join(
            os.path.dirname(__file__), "..", "..", "role-validate", "scripts", "role-validate.py"))
        if os.path.isfile(validate_script):
            print()
            print("--- Running role-validate ---")
            subprocess.run([sys.executable, validate_script, "-RightsPath", paths["RightsPath"]])


if __name__ == "__main__":
    main()
