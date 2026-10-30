#!/usr/bin/env python3
# cfe-validate v1.33 — Validate 1C configuration extension structure (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Validates extension Configuration.xml: root, InternalInfo, extension properties, ChildObjects, borrowed objects."""
import sys, os, argparse, re
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


# Built-in language keywords in both spellings. The platform accepts either one in any module
# (pairs taken from the platform string tables), so a module written in English is ordinary
# source, not a broken one: we must read both and emit the spelling we read.
def bsl_keywords():
    return {
        "ru": {
            "Async": "Асинх", "Proc": "Процедура", "EndProc": "КонецПроцедуры",
            "Func": "Функция", "EndFunc": "КонецФункции", "Val": "Знач",
            "Region": "Область", "EndRegion": "КонецОбласти",
            "If": "Если", "Then": "Тогда", "ElsIf": "ИначеЕсли", "Else": "Иначе", "EndIf": "КонецЕсли",
            # Platform spells the negation "Не"; we emit "НЕ" as this skill always has —
            # the language is case-insensitive, and the lower case would churn every snapshot.
            "And": "И", "Or": "Или", "Not": "НЕ",
            "Insert": "Вставка", "EndInsert": "КонецВставки", "Delete": "Удаление", "EndDelete": "КонецУдаления",
            "Before": "Перед", "After": "После", "Around": "Вместо", "Control": "ИзменениеИКонтроль",
            "Proceed": "ПродолжитьВызов", "Return": "Возврат",
            # Not a keyword: name of the local the generated Instead-stub declares. Lives here so
            # that the language of emitted text is decided in exactly one place.
            "ResultVar": "Результат",
            "Directives": ["НаКлиенте", "НаСервере", "НаСервереБезКонтекста", "НаКлиентеНаСервереБезКонтекста", "НаКлиентеНаСервере"],
        },
        "en": {
            "Async": "Async", "Proc": "Procedure", "EndProc": "EndProcedure",
            "Func": "Function", "EndFunc": "EndFunction", "Val": "Val",
            "Region": "Region", "EndRegion": "EndRegion",
            "If": "If", "Then": "Then", "ElsIf": "ElsIf", "Else": "Else", "EndIf": "EndIf",
            "And": "And", "Or": "Or", "Not": "Not",
            "Insert": "Insert", "EndInsert": "EndInsert", "Delete": "Delete", "EndDelete": "EndDelete",
            "Before": "Before", "After": "After", "Around": "Around", "Control": "ChangeAndValidate",
            "Proceed": "ProceedWithCall", "Return": "Return",
            "ResultVar": "Result",
            "Directives": ["AtClient", "AtServer", "AtServerNoContext", "AtClientAtServerNoContext", "AtClientAtServer"],
        },
    }


NS = {
    'md':  'http://v8.1c.ru/8.3/MDClasses',
    'v8':  'http://v8.1c.ru/8.1/data/core',
    'xr':  'http://v8.1c.ru/8.3/xcf/readable',
    'xsi': 'http://www.w3.org/2001/XMLSchema-instance',
    'xs':  'http://www.w3.org/2001/XMLSchema',
    'app': 'http://v8.1c.ru/8.2/managed-application/core',
}

GUID_PATTERN = re.compile(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
)
IDENT_PATTERN = re.compile(
    r'^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_]'
    r'[A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$'
)

# 7 fixed ClassIds for Configuration
VALID_CLASS_IDS = [
    '9cd510cd-abfc-11d4-9434-004095e12fc7',
    '9fcd25a0-4822-11d4-9414-008048da11f9',
    'e3687481-0a87-462c-a166-9f34594f9bba',
    '9de14907-ec23-4a07-96f0-85521cb6b53b',
    '51f2d5d8-ea4d-4064-8892-82951750031e',
    'e68182ea-4237-4383-967f-90c1e3370bc7',
    'fb282519-d103-4dd3-bc12-cb271d631dfc',
]

# 46 types in canonical order
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
    'BusinessProcess', 'Task', 'ExternalDataSource', 'IntegrationService',
]

# Модули заимствованных объектов: тип → виды модулей. Имя свойства в <xr:PropertyState>
# совпадает с базовым именем файла модуля. Копия таблицы есть в cfe-borrow (навыки автономны).
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

# Type -> directory mapping
CHILD_TYPE_DIR_MAP = {
    'Language': 'Languages', 'Subsystem': 'Subsystems', 'StyleItem': 'StyleItems', 'Style': 'Styles',
    'CommonPicture': 'CommonPictures', 'SessionParameter': 'SessionParameters', 'Role': 'Roles',
    'CommonTemplate': 'CommonTemplates', 'FilterCriterion': 'FilterCriteria', 'CommonModule': 'CommonModules',
    'Bot': 'Bots', 'PaletteColor': 'PaletteColors',
    'CommonAttribute': 'CommonAttributes', 'ExchangePlan': 'ExchangePlans', 'XDTOPackage': 'XDTOPackages',
    'WebService': 'WebServices', 'HTTPService': 'HTTPServices', 'WSReference': 'WSReferences',
    'EventSubscription': 'EventSubscriptions', 'ScheduledJob': 'ScheduledJobs',
    'SettingsStorage': 'SettingsStorages', 'FunctionalOption': 'FunctionalOptions',
    'FunctionalOptionsParameter': 'FunctionalOptionsParameters', 'DefinedType': 'DefinedTypes',
    'CommonCommand': 'CommonCommands', 'CommandGroup': 'CommandGroups', 'Constant': 'Constants',
    'CommonForm': 'CommonForms', 'Catalog': 'Catalogs', 'Document': 'Documents',
    'DocumentNumerator': 'DocumentNumerators', 'Sequence': 'Sequences',
    'DocumentJournal': 'DocumentJournals', 'Enum': 'Enums', 'Report': 'Reports',
    'DataProcessor': 'DataProcessors', 'InformationRegister': 'InformationRegisters',
    'AccumulationRegister': 'AccumulationRegisters',
    'ChartOfCharacteristicTypes': 'ChartsOfCharacteristicTypes',
    'ChartOfAccounts': 'ChartsOfAccounts', 'AccountingRegister': 'AccountingRegisters',
    'ChartOfCalculationTypes': 'ChartsOfCalculationTypes',
    'CalculationRegister': 'CalculationRegisters',
    'BusinessProcess': 'BusinessProcesses', 'Task': 'Tasks',
    'ExternalDataSource': 'ExternalDataSources',
    'IntegrationService': 'IntegrationServices',
}

# Наборы GeneratedType по типу объекта (эталон — таблица §2.5 спецификации конфигурации).
# Неполный набор в заимствованной оболочке платформа отвергает при загрузке: «отсутствует один
# или более типов объекта <Тип>». Типы, у которых GeneratedType нет вовсе (общие модули,
# подписки, регламентные задания и т.п.), в карте отсутствуют — для них проверка не выполняется.
GENERATED_TYPE_CATEGORIES = {
    'Catalog':                    ['Object', 'Ref', 'Selection', 'List', 'Manager'],
    'Document':                   ['Object', 'Ref', 'Selection', 'List', 'Manager'],
    'Enum':                       ['Ref', 'Manager', 'List'],
    'Constant':                   ['Manager', 'ValueManager', 'ValueKey'],
    'Report':                     ['Object', 'Manager'],
    'DataProcessor':              ['Object', 'Manager'],
    'ExchangePlan':               ['Object', 'Ref', 'Selection', 'List', 'Manager'],
    'Task':                       ['Object', 'Ref', 'Selection', 'List', 'Manager'],
    'BusinessProcess':            ['Object', 'Ref', 'Selection', 'List', 'Manager', 'RoutePointRef'],
    'ChartOfCharacteristicTypes': ['Object', 'Ref', 'Selection', 'List', 'Manager', 'Characteristic'],
    'ChartOfAccounts':            ['Object', 'Ref', 'Selection', 'List', 'Manager', 'ExtDimensionTypes', 'ExtDimensionTypesRow'],
    'ChartOfCalculationTypes':    ['Object', 'Ref', 'Selection', 'List', 'Manager', 'DisplacingCalculationTypes', 'DisplacingCalculationTypesRow', 'BaseCalculationTypes', 'BaseCalculationTypesRow', 'LeadingCalculationTypes', 'LeadingCalculationTypesRow'],
    'InformationRegister':        ['Record', 'Manager', 'Selection', 'List', 'RecordSet', 'RecordKey', 'RecordManager'],
    'AccumulationRegister':       ['Record', 'Manager', 'Selection', 'List', 'RecordSet', 'RecordKey'],
    'AccountingRegister':         ['Record', 'Manager', 'Selection', 'List', 'RecordSet', 'RecordKey', 'ExtDimensions'],
    'CalculationRegister':        ['Record', 'Manager', 'Selection', 'List', 'RecordSet', 'RecordKey', 'Recalcs'],
    'DocumentJournal':            ['Selection', 'List', 'Manager'],
    'Sequence':                   ['Record', 'Manager', 'RecordSet'],
    'FilterCriterion':            ['Manager', 'List'],
    'SettingsStorage':            ['Manager'],
    'ExternalDataSource':         ['Manager', 'TablesManager', 'CubesManager'],
    'IntegrationService':         ['Manager'],
    'WSReference':                ['Manager'],
    'DefinedType':                ['DefinedType'],
}

# Стандартные реквизиты объектов: в ChildObjects их нет, но пути Объект.<Стандартный> законны.
# Имена зависят от варианта встроенного языка, поэтому держим оба написания.
# Основной реквизит формы: <Attribute name="X"> с <MainAttribute>true</MainAttribute> внутри
MAIN_ATTR_RE = re.compile(
    r'<Attribute name=\"([^\"]+)\"[^>]*>(?:(?!</Attribute>).)*?<MainAttribute>true</MainAttribute>', re.DOTALL)
# Обычные имена основного реквизита формы — когда настоящее имя взять неоткуда
MAIN_ATTR_DEFAULT_NAMES = ['Объект', 'Список', 'Запись', 'Отчет', 'НаборЗаписей', 'НаборКонстант',
                           'Object', 'List', 'Record', 'Report', 'RecordSet', 'ConstantsSet']

MAIN_ATTR_TYPE_RE = re.compile(r'<v8:Type[^>]*>(?:\w+:)?(\w+?)(Object|RecordManager|RecordSet)\.([^<]+)</v8:Type>')
# Вид объекта без учёта регистра — как у хеш-таблицы PS-порта
CHILD_TYPE_KINDS_CI = {k.upper() for k in CHILD_TYPE_DIR_MAP}


def main_attribute_target(main_attr_xml):
    """Объект, по которому разрешаются пути формы, — тип её основного реквизита, а не владелец формы:
    форма обработки бывает с основным реквизитом DocumentObject.X. Берётся первый тип, который
    является объектом метаданных (префикс пространства имён любой, в т.ч. объявленный на самом
    <v8:Type>). Нет такого (динамический список,
    таблица значений) — None: путь не по составу объекта."""
    for tm in MAIN_ATTR_TYPE_RE.finditer(main_attr_xml):
        if tm.group(1).upper() in CHILD_TYPE_KINDS_CI:
            return {'Key': f'{tm.group(1)}.{tm.group(3)}', 'Category': tm.group(1) + tm.group(2),
                    'TypeName': f'{tm.group(1)}{tm.group(2)}.{tm.group(3)}'}
    return None


# Стандартные реквизиты, которые платформа принимает первым сегментом пути формы, — по типу
# основного реквизита (замер 8.3.24 на собственных объектах расширения, оба написания). Набор
# зависит и от свойств объекта (Parent — иерархия, Owner — владельцы, ExtDimensionDr — корреспонденция),
# здесь — надмножество по типу. Типа нет в карте (не замерен) — пути формы не проверяются.
MAIN_ATTR_STANDARD_FIELDS = {k.upper(): {n.upper() for n in v.split()} for k, v in {
    'CatalogObject': 'Code Description Ref Parent Owner DeletionMark Predefined PredefinedDataName IsFolder Код Наименование Ссылка Родитель Владелец ПометкаУдаления Предопределенный ИмяПредопределенныхДанных ЭтоГруппа',
    'DocumentObject': 'Number Date Posted Ref DeletionMark RegisterRecords Номер Дата Проведен Ссылка ПометкаУдаления Движения',
    'ChartOfCharacteristicTypesObject': 'Code Description Ref Parent IsFolder DeletionMark Predefined PredefinedDataName ValueType Код Наименование Ссылка Родитель ЭтоГруппа ПометкаУдаления Предопределенный ИмяПредопределенныхДанных ТипЗначения',
    'ChartOfAccountsObject': 'Code Description Ref Parent DeletionMark Predefined PredefinedDataName OffBalance Order Type ExtDimensionTypes Код Наименование Ссылка Родитель ПометкаУдаления Предопределенный ИмяПредопределенныхДанных Забалансовый Порядок Вид ВидыСубконто',
    'ChartOfCalculationTypesObject': 'Code Description Ref DeletionMark Predefined PredefinedDataName ActionPeriodIsBasic BaseCalculationTypes LeadingCalculationTypes DisplacingCalculationTypes Код Наименование Ссылка ПометкаУдаления Предопределенный ИмяПредопределенныхДанных ПериодДействияБазовый БазовыеВидыРасчета ВедущиеВидыРасчета ВытесняющиеВидыРасчета',
    'ExchangePlanObject': 'Code Description Ref DeletionMark ThisNode SentNo ReceivedNo Код Наименование Ссылка ПометкаУдаления ЭтотУзел НомерОтправленного НомерПринятого',
    'TaskObject': 'Number Date Description Ref DeletionMark BusinessProcess RoutePoint Executed Номер Дата Наименование Ссылка ПометкаУдаления БизнесПроцесс ТочкаМаршрута Выполнена',
    'BusinessProcessObject': 'Number Date Ref DeletionMark Started Completed HeadTask Номер Дата Ссылка ПометкаУдаления Стартован Завершен ВедущаяЗадача',
    'DataProcessorObject': '',
    'ReportObject': 'SettingsComposer КомпоновщикНастроек',
    'InformationRegisterRecordManager': 'Period Recorder LineNumber Active Период Регистратор НомерСтроки Активность',
    'InformationRegisterRecordSet': 'Period Recorder LineNumber Active RowsCount Период Регистратор НомерСтроки Активность КоличествоСтрок',
    'AccumulationRegisterRecordSet': 'Period Recorder LineNumber Active RecordType RowsCount Период Регистратор НомерСтроки Активность ВидДвижения КоличествоСтрок',
    'AccountingRegisterRecordSet': 'Period Recorder LineNumber Active RecordType RowsCount Account AccountDr AccountCr ExtDimension1 ExtDimension2 ExtDimension3 ExtDimensionDr1 ExtDimensionDr2 ExtDimensionDr3 ExtDimensionCr1 ExtDimensionCr2 ExtDimensionCr3 Период Регистратор НомерСтроки Активность ВидДвижения КоличествоСтрок Счет СчетДт СчетКт Субконто1 Субконто2 Субконто3 СубконтоДт1 СубконтоДт2 СубконтоДт3 СубконтоКт1 СубконтоКт2 СубконтоКт3',
    'CalculationRegisterRecordSet': 'Recorder LineNumber Active RowsCount CalculationType RegistrationPeriod ReversingEntry ActionPeriod BegOfActionPeriod EndOfActionPeriod BegOfBasePeriod EndOfBasePeriod Регистратор НомерСтроки Активность КоличествоСтрок ВидРасчета ПериодРегистрации Сторно ПериодДействия ПериодДействияНачало ПериодДействияКонец БазовыйПериодНачало БазовыйПериодКонец',
}.items()}

# Путь через компоновщик настроек отчёта (<Отчет>.SettingsComposer.<Свойство>.<Колонка или коллекция>) —
# по дереву реквизита формы в конфигураторе (замер 8.3.24, 8.3.27, 8.5). Справка синтакс-помощника тут не
# источник: Structure, Parent, UserSettings.Items во встроенном языке есть, а в пути формы — «Неверный путь
# к данным». Платформа проверяет путь на всю глубину; здесь — два уровня после компоновщика, поля строк
# коллекций (Filter.Use) не проверяем.
SETTINGS_COMPOSER_NAMES = {'SETTINGSCOMPOSER', 'КОМПОНОВЩИКНАСТРОЕК'}
_SC_SETTINGS = ('Use ReportStructurePicture ReportStructure HasSelection HasFilter HasOrder HasConditionalAppearance '
                'HasOutputParameters DataParameters Filter Selection Order ConditionalAppearance OutputParameters UserFields '
                'Использование КартинкаСтруктурыОтчета СтруктураОтчета НаличиеВыбора НаличиеОтбора НаличиеПорядка '
                'НаличиеУсловногоОформления НаличиеПараметровВывода ПараметрыДанных Отбор Выбор Порядок УсловноеОформление '
                'ПараметрыВывода ПользовательскиеПоля')
_SC_USER_SETTINGS = ('Use SettingPicture Setting ComparisonType ValuePicture Value EditInReportForm '
                     'Использование КартинкаНастройки Настройка ВидСравнения КартинкаЗначения Значение РедактированиеВФормеОтчета')
SETTINGS_COMPOSER_TREE = {k.upper(): {n.upper() for n in v.split()} for k, v in {
    'Settings': _SC_SETTINGS, 'Настройки': _SC_SETTINGS,
    'FixedSettings': _SC_SETTINGS, 'ФиксированныеНастройки': _SC_SETTINGS,
    'UserSettings': _SC_USER_SETTINGS, 'ПользовательскиеНастройки': _SC_USER_SETTINGS,
}.items()}


def settings_composer_error(segs):
    """Путь после компоновщика настроек (segs[0]): (номер неверного сегмента, текст) или None."""
    if len(segs) < 2:
        return None
    node = SETTINGS_COMPOSER_TREE.get(segs[1].upper())
    if node is None:
        # Подсказка — на языке, которым записан сам компоновщик
        names = ('Настройки, ПользовательскиеНастройки, ФиксированныеНастройки' if segs[0].upper() == 'КОМПОНОВЩИКНАСТРОЕК'
                 else 'Settings, UserSettings, FixedSettings')
        return 1, f'the settings composer has no such property (available to forms: {names})'
    if len(segs) >= 3 and segs[2].upper() not in node:
        return 2, f'{segs[1]} has no such column or settings collection available to forms'
    return None


REF_TYPE_RE = re.compile(r'^(?:\w+:)?(\w+?)Ref\.(.+)$')


# Стандартные поля строки табличной части: в ChildObjects их нет, но пути Объект.<ТЧ>.<Стандартный>
# законны. Имена зависят от варианта встроенного языка, поэтому держим оба написания.
STANDARD_OBJECT_FIELDS = {
    'Code', 'Description', 'Ref', 'Parent', 'Owner', 'DeletionMark', 'Predefined', 'IsFolder', 'LineNumber',
    'Number', 'Date', 'Posted', 'PredefinedDataName', 'RegisterRecords', 'DataVersion', 'RowsCount',
    'Код', 'Наименование', 'Ссылка', 'Родитель', 'Владелец', 'ПометкаУдаления', 'Предопределенный',
    'ЭтоГруппа', 'НомерСтроки', 'Номер', 'Дата', 'Проведен', 'ИмяПредопределенныхДанных',
    'Движения', 'ВерсияДанных', 'КоличествоСтрок',
}
STANDARD_OBJECT_FIELDS_CI = {f.upper() for f in STANDARD_OBJECT_FIELDS}

# Valid enum values for extension properties
VALID_ENUM_VALUES = {
    'ConfigurationExtensionCompatibilityMode': [
        'DontUse', 'Version8_1', 'Version8_2_13', 'Version8_2_16',
        'Version8_3_1', 'Version8_3_2', 'Version8_3_3', 'Version8_3_4', 'Version8_3_5',
        'Version8_3_6', 'Version8_3_7', 'Version8_3_8', 'Version8_3_9', 'Version8_3_10',
        'Version8_3_11', 'Version8_3_12', 'Version8_3_13', 'Version8_3_14', 'Version8_3_15',
        'Version8_3_16', 'Version8_3_17', 'Version8_3_18', 'Version8_3_19', 'Version8_3_20',
        'Version8_3_21', 'Version8_3_22', 'Version8_3_23', 'Version8_3_24', 'Version8_3_25',
        'Version8_3_26', 'Version8_3_27', 'Version8_3_28', 'Version8_5_1',
    ],
    'DefaultRunMode': ['ManagedApplication', 'OrdinaryApplication', 'Auto'],
    'ScriptVariant': ['Russian', 'English'],
    'InterfaceCompatibilityMode': [
        'Version8_2', 'Version8_2EnableTaxi', 'Taxi', 'TaxiEnableVersion8_2',
        'TaxiEnableVersion8_5', 'Version8_5EnableTaxi', 'Version8_5',
    ],
}

EXPECTED_NS = 'http://v8.1c.ru/8.3/MDClasses'

# ── Format version ───────────────────────────────────────────
# Проверенный диапазон версий формата выгрузки: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница —
# docs/1c-configuration-spec.md, «Лестница версий». Версию задаёт платформа ВЫГРУЗКИ, а не режим
# совместимости конфигурации. Версии ниже 2.17 (платформы 8.3.23 и старше) существуют, но навыки
# на них не проверялись — это предупреждение о непокрытии, а не о некорректности файла.
FORMAT_VERIFIED_MIN = "2.17"
FORMAT_VERIFIED_MAX = "2.21"


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


# Штамп версии формата — атрибут version КОРНЕВОГО элемента файла. Копия общего эталона (семья
# root_version, авторитет — meta-validate). Корневого: в Form.xml расширения ниже стоит <BaseForm version=…>.
def root_version(xml_path):
    if not os.path.isfile(xml_path):
        return None
    with open(xml_path, "rb") as f:
        head = f.read(4096).decode("utf-8", errors="ignore")
    m = re.search(r'<[A-Za-z_][\w.:-]*(\s[^>]*)?/?>', head)
    if not m:
        return None
    v = re.search(r'(?:^|\s)version="([^"]*)"', m.group(1) or "")
    if v:
        return v.group(1)
    return None


class Reporter:
    def __init__(self, max_errors, detailed=False):
        self.errors = 0
        self.warnings = 0
        self.ok_count = 0
        self.stopped = False
        self.max_errors = max_errors
        self.detailed = detailed
        self.lines = []
        self.obj_name = '(unknown)'

    def out(self, msg=''):
        self.lines.append(msg)

    def ok(self, msg):
        self.ok_count += 1
        if self.detailed:
            self.lines.append(f'[OK]    {msg}')

    def error(self, msg):
        self.errors += 1
        self.lines.append(f'[ERROR] {msg}')
        if self.errors >= self.max_errors:
            self.stopped = True

    def warn(self, msg):
        self.warnings += 1
        self.lines.append(f'[WARN]  {msg}')

    def text(self):
        return '\r\n'.join(self.lines) + '\r\n'

    def finalize(self, out_file):
        checks = self.ok_count + self.errors + self.warnings
        if self.errors == 0 and self.warnings == 0 and not self.detailed:
            result = f'=== Validation OK: Extension.{self.obj_name} ({checks} checks) ==='
        else:
            self.out('')
            if self.stopped and self.errors >= self.max_errors:
                self.out(f'Stopped after {self.max_errors} errors. Fix and re-run.')
            self.out(f'=== Result: {self.errors} errors, {self.warnings} warnings ({checks} checks) ===')
            result = self.text()

        print(result, end='' if '\r\n' in result else '\n')

        if out_file:
            with open(out_file, 'w', encoding='utf-8-sig', newline='') as f:
                f.write(result)
            print(f'Written to: {out_file}')


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description='Validate 1C configuration extension XML structure (CFE)', allow_abbrev=False
    )
    parser.add_argument('-ExtensionPath', '-Path', dest='ExtensionPath', required=True)
    parser.add_argument('-Detailed', action='store_true')
    parser.add_argument('-MaxErrors', dest='MaxErrors', type=int, default=30)
    parser.add_argument('-OutFile', dest='OutFile', default='')
    # Конфигурация-источник. Без неё проверки, требующие сравнения с основной конфигурацией,
    # пропускаются (о чём сказано в отчёте), остальные работают как раньше.
    parser.add_argument('-ConfigPath', dest='ConfigPath', default='')
    args = ci_parse_args(parser)

    extension_path = args.ExtensionPath
    max_errors = args.MaxErrors
    out_file = args.OutFile
    config_path_arg = args.ConfigPath

    # --- Resolve path ---
    if not os.path.isabs(extension_path):
        extension_path = os.path.join(os.getcwd(), extension_path)

    if os.path.isdir(extension_path):
        candidate = os.path.join(extension_path, 'Configuration.xml')
        if os.path.exists(candidate):
            extension_path = candidate
        else:
            print(f'[ERROR] No Configuration.xml found in directory: {extension_path}')
            sys.exit(1)

    if not os.path.exists(extension_path):
        print(f'[ERROR] File not found: {extension_path}')
        sys.exit(1)

    resolved_path = os.path.abspath(extension_path)
    config_dir = os.path.dirname(resolved_path)

    if out_file and not os.path.isabs(out_file):
        out_file = os.path.join(os.getcwd(), out_file)

    r = Reporter(max_errors, detailed=args.Detailed)
    r.out('')

    # --- 1. Parse XML ---
    xml_doc = None
    try:
        xml_parser = etree.XMLParser(remove_blank_text=False)
        xml_doc = etree.parse(resolved_path, xml_parser)
    except etree.XMLSyntaxError as e:
        r.lines.insert(0, '=== Validation: Extension (parse failed) ===')
        r.out('')
        r.error(f'1. XML parse failed: {e}')
        r.finalize(out_file)
        sys.exit(1)

    root = xml_doc.getroot()

    # --- Check 1: Root structure ---
    check1_ok = True
    root_local = etree.QName(root.tag).localname
    root_ns = etree.QName(root.tag).namespace or ''

    if root_local != 'MetaDataObject':
        r.error(f"1. Root element is '{root_local}', expected 'MetaDataObject'")
        r.finalize(out_file)
        sys.exit(1)

    if root_ns != EXPECTED_NS:
        r.error(f"1. Root namespace is '{root_ns}', expected '{EXPECTED_NS}'")
        check1_ok = False

    version = root.get('version', '')
    version_rank = format_rank(version)
    if not version:
        r.warn('1. Missing version attribute on MetaDataObject')
    elif version_rank == 0:
        r.error(f"1. Malformed version '{version}' (expected N.N)")
    elif version_rank < format_rank(FORMAT_VERIFIED_MIN):
        r.warn(f"1. Format version '{version}' is below the tested range "
               f"{FORMAT_VERIFIED_MIN}-{FORMAT_VERIFIED_MAX} — skills were not verified on it")
    elif version_rank > format_rank(FORMAT_VERIFIED_MAX):
        r.warn(f"1. Format version '{version}' is above the tested range "
               f"{FORMAT_VERIFIED_MIN}-{FORMAT_VERIFIED_MAX} — skills were not verified on it")

    # Must have Configuration child
    cfg_node = None
    for child in root:
        if not isinstance(child.tag, str):
            continue
        if etree.QName(child.tag).localname == 'Configuration' and etree.QName(child.tag).namespace == EXPECTED_NS:
            cfg_node = child
            break

    if cfg_node is None:
        r.error('1. No <Configuration> element found inside MetaDataObject')
        r.finalize(out_file)
        sys.exit(1)

    # UUID
    cfg_uuid = cfg_node.get('uuid', '')
    if not cfg_uuid:
        r.error('1. Missing uuid on <Configuration>')
        check1_ok = False
    elif not GUID_PATTERN.match(cfg_uuid):
        r.error(f"1. Invalid uuid '{cfg_uuid}' on <Configuration>")
        check1_ok = False

    # Get name early for header
    props_node = cfg_node.find('md:Properties', NS)
    name_node = props_node.find('md:Name', NS) if props_node is not None else None
    obj_name = (name_node.text or '') if name_node is not None and name_node.text else '(unknown)'
    r.obj_name = obj_name

    r.lines.insert(0, f'=== Validation: Extension.{obj_name} ===')

    if check1_ok:
        r.ok(f'1. Root structure: MetaDataObject/Configuration, version {version}')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 2: InternalInfo ---
    internal_info = cfg_node.find('md:InternalInfo', NS)
    check2_ok = True

    if internal_info is None:
        r.error('2. InternalInfo: missing')
    else:
        contained = internal_info.findall('xr:ContainedObject', NS)
        if len(contained) != 7:
            r.warn(f'2. InternalInfo: expected 7 ContainedObject, found {len(contained)}')

        found_class_ids = {}
        for co in contained:
            class_id_el = co.find('xr:ClassId', NS)
            object_id_el = co.find('xr:ObjectId', NS)

            if class_id_el is None or not (class_id_el.text or ''):
                r.error('2. ContainedObject missing ClassId')
                check2_ok = False
                continue

            cid = class_id_el.text
            if cid not in VALID_CLASS_IDS:
                r.error(f'2. Unknown ClassId: {cid}')
                check2_ok = False

            if cid in found_class_ids:
                r.error(f'2. Duplicate ClassId: {cid}')
                check2_ok = False
            found_class_ids[cid] = True

            if object_id_el is None or not (object_id_el.text or ''):
                r.error(f'2. ContainedObject missing ObjectId for ClassId {cid}')
                check2_ok = False
            elif not GUID_PATTERN.match(object_id_el.text):
                r.error(f"2. Invalid ObjectId '{object_id_el.text}' for ClassId {cid}")
                check2_ok = False

        missing_ids = [cid for cid in VALID_CLASS_IDS if cid not in found_class_ids]
        if len(missing_ids) > 0:
            r.warn(f'2. Missing ClassIds: {len(missing_ids)} of 7')

        if check2_ok:
            r.ok(f'2. InternalInfo: {len(contained)} ContainedObject, all ClassIds valid')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 3: Extension-specific properties ---
    def_lang = ''

    if props_node is None:
        r.error('3. Properties block missing')
    else:
        check3_ok = True

        # ObjectBelonging = Adopted
        ob_node = props_node.find('md:ObjectBelonging', NS)
        ob_val = (ob_node.text or '') if ob_node is not None else ''
        if ob_val != 'Adopted':
            r.error(f"3. ObjectBelonging must be 'Adopted', got '{ob_val}'")
            check3_ok = False

        # Name
        if name_node is None or not (name_node.text or ''):
            r.error('3. Name is missing or empty')
            check3_ok = False
        else:
            name_val = name_node.text
            if not IDENT_PATTERN.match(name_val):
                r.error(f"3. Name '{name_val}' is not a valid 1C identifier")
                check3_ok = False

        # ConfigurationExtensionPurpose
        purpose_node = props_node.find('md:ConfigurationExtensionPurpose', NS)
        valid_purposes = ['Patch', 'Customization', 'AddOn']
        if purpose_node is None or not (purpose_node.text or ''):
            r.error('3. ConfigurationExtensionPurpose is missing')
            check3_ok = False
        elif purpose_node.text not in valid_purposes:
            r.error(f"3. ConfigurationExtensionPurpose '{purpose_node.text}' invalid (expected: Patch, Customization, AddOn)")
            check3_ok = False

        # NamePrefix
        prefix_node = props_node.find('md:NamePrefix', NS)
        if prefix_node is None or not (prefix_node.text or ''):
            r.warn('3. NamePrefix is empty')

        # KeepMappingToExtendedConfigurationObjectsByIDs
        keep_map_node = props_node.find('md:KeepMappingToExtendedConfigurationObjectsByIDs', NS)
        if keep_map_node is None:
            r.warn('3. KeepMappingToExtendedConfigurationObjectsByIDs is missing')

        # DefaultLanguage
        def_lang_node = props_node.find('md:DefaultLanguage', NS)
        def_lang = (def_lang_node.text or '') if def_lang_node is not None else ''

        if check3_ok:
            purpose_val = purpose_node.text if purpose_node is not None and purpose_node.text else '?'
            prefix_val = (prefix_node.text or '') if prefix_node is not None and prefix_node.text else '(empty)'
            r.ok(f'3. Extension properties: Name="{obj_name}", Purpose={purpose_val}, Prefix={prefix_val}')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 4: Enum property values ---
    if props_node is not None:
        enum_checked = 0
        check4_ok = True

        for prop_name, allowed in VALID_ENUM_VALUES.items():
            prop_node = props_node.find(f'md:{prop_name}', NS)
            if prop_node is not None and prop_node.text:
                val = prop_node.text
                if val not in allowed:
                    r.error(f"4. Property '{prop_name}' has invalid value '{val}'")
                    check4_ok = False
                enum_checked += 1

        if check4_ok:
            r.ok(f'4. Property values: {enum_checked} enum properties checked')
    else:
        r.warn('4. No Properties block to check')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 5: ChildObjects -- valid types, no duplicates, order ---
    child_obj_node = cfg_node.find('md:ChildObjects', NS)

    if child_obj_node is None:
        r.error('5. ChildObjects block missing')
    else:
        check5_ok = True
        total_count = 0
        child_object_index = {}
        duplicates = {}
        type_first_index = {}
        last_type_order = -1
        order_ok = True

        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            obj_name_val = child.text or ''

            if type_name in CHILD_OBJECT_TYPES:
                type_idx = CHILD_OBJECT_TYPES.index(type_name)
            else:
                type_idx = -1

            if type_idx < 0:
                r.error(f"5. Unknown type '{type_name}' in ChildObjects")
                check5_ok = False
            else:
                if type_name not in type_first_index:
                    type_first_index[type_name] = type_idx
                    if type_idx < last_type_order:
                        r.warn(f"5. Type '{type_name}' is out of canonical order (after type at position {last_type_order})")
                        order_ok = False
                    last_type_order = type_idx

            if type_name not in child_object_index:
                child_object_index[type_name] = {}
            if obj_name_val in child_object_index[type_name]:
                dup_key = f'{type_name}.{obj_name_val}'
                if dup_key not in duplicates:
                    r.error(f'5. Duplicate: {dup_key}')
                    duplicates[dup_key] = True
                    check5_ok = False
            else:
                child_object_index[type_name][obj_name_val] = True

            total_count += 1

        type_count = len(child_object_index)
        if check5_ok:
            order_info = ', order correct' if order_ok else ''
            r.ok(f'5. ChildObjects: {type_count} types, {total_count} objects{order_info}')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 6: DefaultLanguage references existing Language in ChildObjects ---
    if def_lang and child_obj_node is not None:
        lang_name = def_lang
        if lang_name.startswith('Language.'):
            lang_name = lang_name[9:]

        found = False
        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            if etree.QName(child.tag).localname == 'Language' and (child.text or '') == lang_name:
                found = True
                break

        if found:
            r.ok(f'6. DefaultLanguage "{def_lang}" found in ChildObjects')
        else:
            r.error(f'6. DefaultLanguage "{def_lang}" not found in ChildObjects')
    else:
        if not def_lang:
            r.warn('6. Cannot check DefaultLanguage (empty)')
        else:
            r.warn('6. Cannot check DefaultLanguage (no ChildObjects)')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 7: Language files exist ---
    if child_obj_node is not None:
        lang_names = []
        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            if etree.QName(child.tag).localname == 'Language':
                lang_names.append(child.text or '')

        if len(lang_names) > 0:
            exist_count = 0
            for ln in lang_names:
                lang_file = os.path.join(config_dir, 'Languages', ln + '.xml')
                if os.path.exists(lang_file):
                    exist_count += 1
                else:
                    r.warn(f'7. Language file missing: Languages/{ln}.xml')
            if exist_count == len(lang_names):
                r.ok(f'7. Language files: {exist_count}/{len(lang_names)} exist')
        else:
            r.warn('7. No Language entries in ChildObjects')
    else:
        r.warn('7. Cannot check language files (no ChildObjects)')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 8: Object directories exist ---
    if child_obj_node is not None:
        dirs_to_check = {}
        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            if type_name == 'Language':
                continue
            if type_name in CHILD_TYPE_DIR_MAP:
                dir_name = CHILD_TYPE_DIR_MAP[type_name]
                dirs_to_check[dir_name] = dirs_to_check.get(dir_name, 0) + 1

        missing_dirs = []
        for dir_name, count in dirs_to_check.items():
            dir_path = os.path.join(config_dir, dir_name)
            if not os.path.isdir(dir_path):
                missing_dirs.append(f'{dir_name} ({count} objects)')

        if len(missing_dirs) == 0:
            r.ok(f'8. Object directories: {len(dirs_to_check)} directories, all exist')
        else:
            for md in missing_dirs:
                r.warn(f'8. Missing directory: {md}')
    else:
        pass  # no ChildObjects

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 9: Borrowed objects + Check 10: Sub-items ---
    MD = NS['md']
    XR = NS['xr']
    enum_values_index = {}
    ext_obj_index = {}
    # Все объекты состава расширения, и те, чей файл не прочитан: отличить «объекта нет» от «не разобран»
    ext_obj_listed = set()
    form_list = []

    # Собственные подобъекты данных в заимствованном объекте (реквизит, ТЧ, колонка заимствованной ТЧ,
    # измерение, ресурс, признаки учёта, реквизит адресации): у ПВХ, ПС, ПВР и регистров платформа их загружает, но базу не
    # обновляет («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»,
    # 8.3.24–8.5.1 при любом режиме совместимости); у БП и Задачи — так же на платформе ниже 8.3.25, а с
    # 8.3.25 можно (граница по версии платформы, не по режиму — по исходникам её не определить).
    # Формы, команды и макеты — можно везде (замер 8.3.24, 8.3.27, 8.5.1).
    # Собственные объекты верхнего уровня: платформа загружает расширение, но базу не обновляет
    # («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо в режиме
    # совместимости <режим> и ниже» — режим в сообщении лишь текущий). Последовательность, хранилище
    # настроек, общий реквизит — нигде (8.3.24–8.5.1, и в режиме 8.5.1); БП и Задача — на платформе ниже
    # 8.3.25, журнал документов — ниже 8.3.26 (граница по версии платформы, режим расширения 8.3.24).
    # Остальные виды — можно уже на 8.3.24.
    own_object_restricted = {
        'Sequence': 'Error', 'SettingsStorage': 'Error', 'CommonAttribute': 'Error',
        'BusinessProcess': '8.3.25', 'Task': '8.3.25', 'DocumentJournal': '8.3.26',
    }
    own_child_restricted = {
        'ChartOfCharacteristicTypes': 'Error', 'ChartOfAccounts': 'Error', 'ChartOfCalculationTypes': 'Error',
        'InformationRegister': 'Error', 'AccumulationRegister': 'Error', 'AccountingRegister': 'Error',
        'CalculationRegister': 'Error', 'BusinessProcess': 'Since8325', 'Task': 'Since8325',
    }
    own_data_child_tags = ('Attribute', 'TabularSection', 'Dimension', 'Resource', 'AccountingFlag', 'ExtDimensionAccountingFlag', 'AddressingAttribute')

    def md_type_list(el):
        """Типы подобъекта метаданных: тексты <v8:Type>; определяемый тип — меткой «#DefinedType.<Имя>», прочие
        наборы — «#TypeSet», квалификаторы пропускаются."""
        result = []
        type_el = el.find(f'{{{MD}}}Properties/{{{MD}}}Type')
        if type_el is not None:
            for tn in type_el:
                if not isinstance(tn.tag, str):
                    continue
                ln = etree.QName(tn.tag).localname
                if ln == 'Type':
                    result.append((tn.text or '').strip())
                elif ln == 'TypeSet':
                    dtm = re.match(r'^(?:\w+:)?DefinedType\.(.+)$', (tn.text or '').strip())
                    result.append(f'#DefinedType.{dtm.group(1)}' if dtm else '#TypeSet')
        return result

    def get_std_ref_types(kind, name, seg):
        """Типы стандартного ссылочного реквизита справочника, через который путь идёт дальше: Родитель — сам
        справочник, Владелец — единственный владелец (несколько — не замерено). Иначе None."""
        if kind.upper() != 'CATALOG':
            return None
        if seg.upper() in ('PARENT', 'РОДИТЕЛЬ'):
            return [f'cfg:CatalogRef.{name}']
        if seg.upper() in ('OWNER', 'ВЛАДЕЛЕЦ'):
            entry = ext_obj_index.get(f'{kind}.{name}'.upper())
            if entry is not None and len(entry['Owners']) == 1:
                om = re.match(r'^(\w+)\.(.+)$', entry['Owners'][0])
                if om:
                    return [f'cfg:{om.group(1)}Ref.{om.group(2)}']
        return None

    def ref_tail_error(types, segs, i):
        """Хвост пути после ссылочного реквизита: сегмент с номером i и дальше. Замер 8.3.24: сегмент
        разрешается по целевому объекту в расширении (заимствованные и собственные подобъекты) и стандартным
        реквизитам вида — набор тот же, что у объекта (MAIN_ATTR_STANDARD_FIELDS); объекта в расширении
        нет — только стандартные.
        ТЧ цели — дальше колонка этой ТЧ; Родитель и Владелец справочника — дальше по их типу. Правило
        повторяется на каждом шаге. У составного типа (любой состав) дальше реквизита путь не разрешается.
        Определяемый тип раскрывается по его составу в расширении (замер 8.3.27: путь через составной ОТ
        отвергается и в конфигурации); ОТ нет в расширении — не проверяем, это проверка 19.
        Не замерено (примитивный тип, перечисление, прочие стандартные реквизиты в середине пути) — не
        проверяем. Ошибка — (номер сегмента, текст), иначе None."""
        while i < len(segs):
            expanded = []
            for t in types:
                if t.startswith('#DefinedType.'):
                    dt_entry = ext_obj_index.get(f'DefinedType.{t[13:]}'.upper())
                    if dt_entry is None:
                        return None
                    expanded.extend(dt_entry['Types'])
                else:
                    expanded.append(t)
            types = expanded
            if '#TypeSet' in types:
                return None
            if len(types) >= 2:
                return i, f'{segs[i - 1]} has a composite type — the path cannot continue past it'
            if len(types) != 1:
                return None
            rm = REF_TYPE_RE.match(types[0])
            if not rm:
                return None
            t_kind, t_name = rm.group(1), rm.group(2)
            t_std = MAIN_ATTR_STANDARD_FIELDS.get(f'{t_kind}Object'.upper())
            if t_std is None:
                return None
            t_key = f'{t_kind}.{t_name}'
            seg = segs[i]
            seg_ci = seg.upper()
            if seg_ci in t_std:
                std_types = get_std_ref_types(t_kind, t_name, seg)
                if std_types is None:
                    return None
                types = std_types
                i += 1
                continue
            t_entry = ext_obj_index.get(t_key.upper())
            if t_entry is None:
                if t_key.upper() in ext_obj_listed:
                    return None
                return i, (f'{t_key} has no attribute {seg} in the extension: the object is not borrowed, '
                           f'and through a reference only its standard attributes are visible')
            if seg_ci not in t_entry['Names']:
                return i, f'{t_key} has no attribute {seg} in the extension (an unborrowed source attribute is not visible to extension forms)'
            if seg_ci in t_entry['TSColumns']:
                if i + 1 >= len(segs):
                    return None
                col = segs[i + 1]
                if col.upper() in STANDARD_OBJECT_FIELDS_CI:
                    return None
                if col.upper() not in t_entry['TSColumns'][seg_ci]:
                    return i + 1, f'tabular section {seg} of {t_key} has no column {col} in the extension'
                types = t_entry['TSColumns'][seg_ci][col.upper()]
                i += 2
                continue
            types = t_entry['Names'][seg_ci]
            i += 1
        return None

    def add_ref_tail_bad_path(bad_paths, root_name, segs, types, i):
        """Хвост пути через ссылку — в список висячих путей формы (ключ — путь до сегмента с ошибкой)."""
        tail = ref_tail_error(types, segs, i)
        if tail:
            bad = f"{root_name}.{'.'.join(segs[:tail[0] + 1])}"
            bad_paths.setdefault(bad.upper(), [bad, ''])[1] = tail[1]

    def is_borrowed_sub_item(sub_item):
        """Check if sub-item has explicit borrowed metadata (ObjectBelonging or ExtendedConfigurationObject)."""
        sub_props = sub_item.find(f'{{{MD}}}Properties')
        if sub_props is None:
            return False
        sub_ob = sub_props.find(f'{{{MD}}}ObjectBelonging')
        if sub_ob is not None and (sub_ob.text or ''):
            return True
        sub_ext = sub_props.find(f'{{{MD}}}ExtendedConfigurationObject')
        return sub_ext is not None and bool(sub_ext.text or '')

    def validate_borrowed_sub_item(check_num, context, sub_type, sub_item):
        """Validate a borrowed Attribute/EnumValue/TabularSection sub-item."""
        sub_props = sub_item.find(f'{{{MD}}}Properties')
        if sub_props is None:
            r.error(f'{check_num}. {context}: {sub_type} missing Properties')
            return False
        ok = True
        sub_ob = sub_props.find(f'{{{MD}}}ObjectBelonging')
        if sub_ob is None or (sub_ob.text or '') != 'Adopted':
            r.error(f"{check_num}. {context}: {sub_type} ObjectBelonging must be 'Adopted'")
            ok = False
        sub_name = sub_props.find(f'{{{MD}}}Name')
        if sub_name is None or not (sub_name.text or ''):
            r.error(f'{check_num}. {context}: {sub_type} missing Name')
            ok = False
        sub_ext = sub_props.find(f'{{{MD}}}ExtendedConfigurationObject')
        sub_name_val = (sub_name.text or '') if sub_name is not None else '?'
        if sub_ext is None or not (sub_ext.text or ''):
            r.error(f'{check_num}. {context}: {sub_type}.{sub_name_val} missing ExtendedConfigurationObject')
            ok = False
        elif not GUID_PATTERN.match(sub_ext.text):
            r.error(f'{check_num}. {context}: {sub_type}.{sub_name_val} invalid ExtendedConfigurationObject')
            ok = False
        return ok

    if child_obj_node is not None:
        borrowed_count = 0
        borrowed_ok_count = 0
        check9_ok = True
        check10_ok = True
        sub_item_count = 0

        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            child_name = child.text or ''
            if type_name == 'Language':
                continue

            if type_name not in CHILD_TYPE_DIR_MAP:
                continue
            dir_name = CHILD_TYPE_DIR_MAP[type_name]
            ext_obj_listed.add(f'{type_name}.{child_name}'.upper())
            obj_file = os.path.join(config_dir, dir_name, child_name + '.xml')
            # Общая форма — сама себе объект: её Form.xml проверяют те же 11–14, что и формы объектов
            if type_name == 'CommonForm' and os.path.isfile(os.path.join(config_dir, dir_name, child_name, 'Ext', 'Form.xml')):
                form_list.append({'TypeName': type_name, 'ObjName': child_name, 'FormName': child_name,
                                  'DirName': dir_name, 'IsCommon': True})

            if not os.path.exists(obj_file):
                continue

            # Parse object XML
            try:
                obj_parser = etree.XMLParser(remove_blank_text=False)
                obj_doc = etree.parse(obj_file, obj_parser)
            except etree.XMLSyntaxError as e:
                r.warn(f'9. Cannot parse {dir_name}/{child_name}.xml: {e}')
                continue

            obj_root = obj_doc.getroot()

            # Find the object element (Catalog, Document, etc.)
            obj_el = None
            for c in obj_root:
                if isinstance(c.tag, str):
                    obj_el = c
                    break
            if obj_el is None:
                continue

            obj_props = obj_el.find(f'{{{MD}}}Properties')
            if obj_props is None:
                continue

            # --- Check 9: ObjectBelonging + ExtendedConfigurationObject ---
            ob_node = obj_props.find(f'{{{MD}}}ObjectBelonging')
            if ob_node is not None and (ob_node.text or '') == 'Adopted':
                borrowed_count += 1

                ext_obj = obj_props.find(f'{{{MD}}}ExtendedConfigurationObject')
                # UUID связи может отсутствовать в платформенной выгрузке; заданный UUID должен быть корректным.
                if ext_obj is not None and not GUID_PATTERN.match(ext_obj.text or ''):
                    r.error(f"9. Borrowed {type_name}.{child_name}: invalid ExtendedConfigurationObject UUID '{ext_obj.text or ''}'")
                    check9_ok = False
                else:
                    borrowed_ok_count += 1

                # Полнота набора GeneratedType: платформа отвергает оболочку с неполным набором
                # («отсутствует один или более типов объекта ChartOfCharacteristicTypes»)
                expected_cats = GENERATED_TYPE_CATEGORIES.get(type_name)
                if expected_cats:
                    obj_info = obj_el.find(f'{{{MD}}}InternalInfo')
                    found_cats = set()
                    if obj_info is not None:
                        for gt in obj_info.findall(f'{{{XR}}}GeneratedType'):
                            cat = gt.get('category')
                            if cat:
                                found_cats.add(cat)
                    missing_cats = [c for c in expected_cats if c not in found_cats]
                    if missing_cats:
                        word = 'category' if len(missing_cats) == 1 else 'categories'
                        r.error(f"9. Borrowed {type_name}.{child_name}: missing GeneratedType {word} {', '.join(missing_cats)}")
                        check9_ok = False
            else:
                own_obj_rule = own_object_restricted.get(type_name)
                if own_obj_rule == 'Error':
                    r.error(f'9. {type_name}.{child_name}: own object of this kind in an extension — the platform loads the extension but does not update the database («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»)')
                    check9_ok = False
                elif own_obj_rule:
                    r.warn(f'9. {type_name}.{child_name}: own object of this kind — below platform {own_obj_rule} the database is not updated («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»)')

            # --- Check 10: Sub-items (Attribute, TabularSection, EnumValue, Form) ---
            obj_child_objects = obj_el.find(f'{{{MD}}}ChildObjects')

            # Объект таким, каким он описан в расширении: реквизиты (и реквизиты адресации задачи, признаки
            # учёта плана счетов), измерения, ресурсы, ТЧ и колонки ТЧ — и заимствованные, и собственные;
            # значение — список типов (по нему разрешается путь через ссылочный реквизит). По этому описанию платформа разрешает пути любой формы
            # расширения (проверка 14) и таблицы <AdditionalColumns> (проверка 12); незаимствованный
            # подобъект источника она не видит. Имена (и ключ объекта) регистронезависимы, как в языке 1С: upper().
            ix_names = {}
            ix_ts_columns = {}
            if obj_child_objects is not None:
                for ix_sub in obj_child_objects:
                    if not isinstance(ix_sub.tag, str):
                        continue
                    ix_ln = etree.QName(ix_sub.tag).localname
                    if ix_ln not in ('Attribute', 'Dimension', 'Resource', 'TabularSection',
                                     'AddressingAttribute', 'AccountingFlag', 'ExtDimensionAccountingFlag'):
                        continue
                    ix_name_el = ix_sub.find(f'{{{MD}}}Properties/{{{MD}}}Name')
                    if ix_name_el is None or not ix_name_el.text:
                        continue
                    ix_name = ix_name_el.text.strip().upper()
                    ix_names[ix_name] = md_type_list(ix_sub)
                    if ix_ln != 'TabularSection':
                        continue
                    ix_cols = {}
                    for ix_col in ix_sub.findall(f'{{{MD}}}ChildObjects/{{{MD}}}Attribute'):
                        ix_col_name = ix_col.find(f'{{{MD}}}Properties/{{{MD}}}Name')
                        if ix_col_name is not None and ix_col_name.text:
                            ix_cols[ix_col_name.text.strip().upper()] = md_type_list(ix_col)
                    ix_ts_columns[ix_name] = ix_cols
            ix_owners = [o.text.strip() for o in obj_el.findall(f'{{{MD}}}Properties/{{{MD}}}Owners/{{{XR}}}Item') if o.text]
            ix_ext_dim = obj_el.find(f'{{{MD}}}Properties/{{{MD}}}ExtDimensionTypes')
            ix_max_ext_dim = obj_el.find(f'{{{MD}}}Properties/{{{MD}}}MaxExtDimensionCount')
            ext_obj_index[f'{type_name}.{child_name}'.upper()] = {'Names': ix_names, 'TSColumns': ix_ts_columns, 'Owners': ix_owners,
                                                                  'ExtDimTypes': (ix_ext_dim is not None and bool((ix_ext_dim.text or '').strip())
                                                                                  and ix_max_ext_dim is not None and bool((ix_max_ext_dim.text or '').strip())),
                                                                  'Types': md_type_list(obj_el) if type_name == 'DefinedType' else []}

            # Собственные подобъекты данных в заимствованном объекте вида, где они запрещены
            own_rule = None
            if ob_node is not None and (ob_node.text or '') == 'Adopted':
                own_rule = own_child_restricted.get(type_name)
            if own_rule and obj_child_objects is not None:
                own_found = []
                for oc in obj_child_objects:
                    if not isinstance(oc.tag, str) or etree.QName(oc.tag).localname not in own_data_child_tags:
                        continue
                    oc_ln = etree.QName(oc.tag).localname
                    oc_name = oc.find(f'{{{MD}}}Properties/{{{MD}}}Name')
                    oc_label = f"{oc_ln}.{(oc_name.text or '').strip() if oc_name is not None else '?'}"
                    if not is_borrowed_sub_item(oc):
                        own_found.append(oc_label)
                        continue
                    if oc_ln != 'TabularSection':
                        continue
                    for occ in oc.findall(f'{{{MD}}}ChildObjects/{{{MD}}}Attribute'):
                        if is_borrowed_sub_item(occ):
                            continue
                        occ_name = occ.find(f'{{{MD}}}Properties/{{{MD}}}Name')
                        own_found.append(f"{oc_label}.Attribute.{(occ_name.text or '').strip() if occ_name is not None else '?'}")
                for own_label in own_found:
                    if r.stopped:
                        break
                    if own_rule == 'Error':
                        r.error(f'10. {type_name}.{child_name}: own {own_label} in a borrowed object — the platform loads the extension '
                                f'but does not update the database («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»)')
                        check10_ok = False
                    else:
                        r.warn(f'10. {type_name}.{child_name}: own {own_label} in a borrowed object — below platform 8.3.25 '
                               f'the database is not updated («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»)')

            if obj_child_objects is not None:
                ctx = f'{type_name}.{child_name}'
                for sub_item in obj_child_objects:
                    if not isinstance(sub_item.tag, str):
                        continue
                    sub_type = etree.QName(sub_item.tag).localname

                    if sub_type == 'Attribute':
                        if not is_borrowed_sub_item(sub_item):
                            continue
                        sub_item_count += 1
                        if not validate_borrowed_sub_item('10', ctx, 'Attribute', sub_item):
                            check10_ok = False

                    elif sub_type == 'TabularSection':
                        if not is_borrowed_sub_item(sub_item):
                            continue
                        sub_item_count += 1
                        if not validate_borrowed_sub_item('10', ctx, 'TabularSection', sub_item):
                            check10_ok = False
                        else:
                            # Check InternalInfo GeneratedTypes
                            ts_info = sub_item.find(f'{{{MD}}}InternalInfo')
                            ts_name_el = sub_item.find(f'{{{MD}}}Properties/{{{MD}}}Name')
                            ts_label = (ts_name_el.text or '?') if ts_name_el is not None else '?'
                            if ts_info is None:
                                r.error(f'10. {ctx}: TabularSection.{ts_label} missing InternalInfo')
                                check10_ok = False
                            else:
                                gt_nodes = ts_info.findall(f'{{{XR}}}GeneratedType')
                                has_ts = any(gt.get('category') == 'TabularSection' for gt in gt_nodes)
                                has_tsr = any(gt.get('category') == 'TabularSectionRow' for gt in gt_nodes)
                                if not has_ts or not has_tsr:
                                    r.error(f'10. {ctx}: TabularSection.{ts_label} missing GeneratedType (need TabularSection + TabularSectionRow)')
                                    check10_ok = False
                            # Recurse into TS ChildObjects/Attribute
                            ts_child_objs = sub_item.find(f'{{{MD}}}ChildObjects')
                            if ts_child_objs is not None:
                                for ts_attr in ts_child_objs:
                                    if not isinstance(ts_attr.tag, str):
                                        continue
                                    if etree.QName(ts_attr.tag).localname != 'Attribute':
                                        continue
                                    if not is_borrowed_sub_item(ts_attr):
                                        continue
                                    sub_item_count += 1
                                    if not validate_borrowed_sub_item('10', f'{ctx}.TabularSection.{ts_label}', 'Attribute', ts_attr):
                                        check10_ok = False

                    elif sub_type == 'EnumValue' and type_name == 'Enum':
                        if not is_borrowed_sub_item(sub_item):
                            continue
                        sub_item_count += 1
                        if validate_borrowed_sub_item('10', ctx, 'EnumValue', sub_item):
                            ev_name = sub_item.find(f'{{{MD}}}Properties/{{{MD}}}Name')
                            if ev_name is not None and (ev_name.text or ''):
                                if child_name not in enum_values_index:
                                    enum_values_index[child_name] = {}
                                enum_values_index[child_name][ev_name.text] = True
                        else:
                            check10_ok = False

                    elif sub_type == 'Form':
                        form_name = sub_item.text or ''
                        if form_name:
                            form_meta_file = os.path.join(config_dir, dir_name, child_name, 'Forms', form_name + '.xml')
                            if not os.path.exists(form_meta_file):
                                r.error(f'10. {ctx}: Form.{form_name} metadata file missing')
                                check10_ok = False
                            form_list.append({
                                'TypeName': type_name, 'ObjName': child_name,
                                'FormName': form_name, 'DirName': dir_name,
                            })
                            sub_item_count += 1

            if r.stopped:
                break

        # Ошибка проверки 9 (в т.ч. на собственном объекте) гасит итоговую строку OK
        if check9_ok:
            if borrowed_count == 0:
                r.ok('9. Borrowed objects: none found')
            else:
                r.ok(f'9. Borrowed objects: {borrowed_ok_count}/{borrowed_count} validated')

        if sub_item_count == 0:
            r.ok('10. Sub-items: none found')
        elif check10_ok:
            r.ok(f'10. Sub-items: {sub_item_count} validated (Attributes, TabularSections, EnumValues, Forms)')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 11: Borrowed form structure ---
    borrowed_forms_with_tree = []
    # Все формы объектов расширения с текстом Form.xml — заимствованные и собственные (проверка 14)
    forms_with_text = []
    check11_ok = True
    form_count = 0

    for fi in form_list:
        form_count += 1
        is_common = fi.get('IsCommon', False)
        # Каталог формы относительно корня: CommonForms/X у общей, Catalogs/X/Forms/Y у формы объекта
        form_rel = (os.path.join(fi['DirName'], fi['ObjName']) if is_common
                    else os.path.join(fi['DirName'], fi['ObjName'], 'Forms', fi['FormName']))
        form_base = os.path.join(config_dir, form_rel)
        form_meta_file = os.path.join(os.path.dirname(form_base), fi['FormName'] + '.xml')
        form_xml_file = os.path.join(form_base, 'Ext', 'Form.xml')
        module_bsl_file = os.path.join(form_base, 'Ext', 'Form', 'Module.bsl')
        ctx = (f"{fi['TypeName']}.{fi['ObjName']}" if is_common
               else f"{fi['TypeName']}.{fi['ObjName']}.Form.{fi['FormName']}")
        # Владелец формы — объект, у общей формы его нет
        owner_key11 = '' if is_common else f"{fi['TypeName']}.{fi['ObjName']}"

        # Validate form metadata XML
        if os.path.exists(form_meta_file):
            try:
                fm_doc = etree.parse(form_meta_file, etree.XMLParser(remove_blank_text=False))
                fm_root = fm_doc.getroot()
                fm_el = None
                for c in fm_root:
                    if isinstance(c.tag, str):
                        fm_el = c
                        break
                if fm_el is not None:
                    fm_props = fm_el.find(f'{{{MD}}}Properties')
                    if fm_props is not None:
                        fm_ob = fm_props.find(f'{{{MD}}}ObjectBelonging')
                        is_borrowed = fm_ob is not None and (fm_ob.text or '') == 'Adopted'
                        # У общей формы это описание самого объекта — его уже проверила проверка 9
                        if is_borrowed and not is_common:
                            fm_ext = fm_props.find(f'{{{MD}}}ExtendedConfigurationObject')
                            if fm_ext is None or not (fm_ext.text or '') or not GUID_PATTERN.match(fm_ext.text or ''):
                                r.error(f'11. {ctx}: invalid/missing ExtendedConfigurationObject')
                                check11_ok = False
                        fm_type = fm_props.find(f'{{{MD}}}FormType')
                        if fm_type is not None and (fm_type.text or '') != 'Managed':
                            r.error(f"11. {ctx}: FormType must be 'Managed', got '{fm_type.text}'")
                            check11_ok = False
            except etree.XMLSyntaxError as e:
                r.warn(f'11. {ctx}: Cannot parse metadata: {e}')

        # Form.xml must exist
        if not os.path.exists(form_xml_file):
            r.error(f'11. {ctx}: Ext/Form.xml missing')
            check11_ok = False
            continue

        # Module.bsl should exist
        if not os.path.exists(module_bsl_file):
            r.warn(f'11. {ctx}: Ext/Form/Module.bsl missing')

        # Read Form.xml as raw text for BaseForm checks
        with open(form_xml_file, 'r', encoding='utf-8-sig') as f:
            form_raw_text = f.read()
        forms_with_text.append({
            'RawText': form_raw_text, 'Context': ctx, 'OwnerKey': owner_key11, 'FormRel': form_rel,
        })

        if '<BaseForm' in form_raw_text:
            if not re.search(r'<BaseForm[^>]+version=', form_raw_text):
                r.warn(f'11. {ctx}: <BaseForm> missing version attribute')
            borrowed_forms_with_tree.append({
                'Path': form_xml_file, 'RawText': form_raw_text, 'Context': ctx, 'OwnerKey': owner_key11,
            })

    if form_count == 0:
        r.ok('11. Borrowed forms: none found')
    elif check11_ok:
        bf_count = len(borrowed_forms_with_tree)
        r.ok(f'11. Borrowed forms: {form_count} validated ({bf_count} with BaseForm)')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 12: Form dependency references ---
    PLATFORM_STYLE_ITEMS = {
        'TableHeaderBackColor', 'AccentColor', 'NormalTextFont',
        'FormBackColor', 'ToolTipBackColor', 'BorderColor',
        'FieldBackColor', 'FieldTextColor', 'ButtonBackColor',
        'ButtonTextColor', 'AlternateRowColor', 'SpecialTextColor',
        'TextFont', 'ImportantColor', 'FormTextColor',
        'SmallTextFont', 'ExtraLargeTextFont', 'LargeTextFont',
        'NormalTextColor', 'GroupHeaderBackColor', 'GroupHeaderFont',
        'ErrorColor', 'SuccessColor', 'WarningColor',
    }
    check12_ok = True
    dep_check_count = 0

    for bf in borrowed_forms_with_tree:
        raw = bf['RawText']
        ctx = bf['Context']
        missing_items = []

        # CommonPicture references
        cp_refs = {}
        for m in re.finditer(r'<xr:Ref>CommonPicture\.(\w+)</xr:Ref>', raw):
            cp_refs[m.group(1)] = True
        cp_index = child_object_index.get('CommonPicture', {})
        for cp_name in cp_refs:
            dep_check_count += 1
            if cp_name not in cp_index:
                missing_items.append(f'CommonPicture.{cp_name}')

        # StyleItem references
        si_refs = {}
        for m in re.finditer(r'style:([A-Za-z\u0410-\u044F\u0401\u0451_][A-Za-z0-9\u0410-\u044F\u0401\u0451_]*)', raw):
            si_refs[m.group(1)] = True
        si_index = child_object_index.get('StyleItem', {})
        for si_name in si_refs:
            dep_check_count += 1
            if si_name in PLATFORM_STYLE_ITEMS:
                continue
            if si_name not in si_index:
                missing_items.append(f'StyleItem.{si_name}')

        # Enum DesignTimeRef references
        enum_refs = {}
        for m in re.finditer(r'xr:DesignTimeRef">Enum\.(\w+)\.EnumValue\.(\w+)', raw):
            e_key = f'{m.group(1)}.{m.group(2)}'
            enum_refs[e_key] = {'Enum': m.group(1), 'Value': m.group(2)}
        e_index = child_object_index.get('Enum', {})
        for entry in enum_refs.values():
            dep_check_count += 1
            if entry['Enum'] not in e_index:
                missing_items.append(f"Enum.{entry['Enum']}")
            elif entry['Enum'] not in enum_values_index or entry['Value'] not in enum_values_index.get(entry['Enum'], {}):
                missing_items.append(f"Enum.{entry['Enum']}.EnumValue.{entry['Value']}")

        # <AdditionalColumns table="Объект.X"> — доп. колонки табличной части, объявленные в самой форме.
        # Колонки есть, а самой ТЧ в расширении нет (ни заимствованной, ни собственной) → платформа
        # отвергает загрузку: «Неверный путь к данным» плюс «Колонки не могут быть добавлены к реквизиту».
        # Соседние проверки этого блока эвристичны (имя стиля добывается регуляркой), поэтому там
        # предупреждение. Здесь сигнал точный — имя ТЧ берётся из атрибута, — а последствие жёсткое,
        # поэтому ошибка.
        # Корень путей формы — имя её основного реквизита: «Объект» только у формы объекта, у формы
        # списка «Список», у формы записи регистра «Запись». С зашитым «Объект» обе проверки на
        # таких формах молча не срабатывали. Ищем сначала в <Attributes> формы, потом в <BaseForm>.
        root_match = MAIN_ATTR_RE.search(raw)
        root_name = root_match.group(1) if root_match else ""
        # Только своя часть формы: <BaseForm> — снимок исходной формы, его платформа разрешает по конфигурации.
        ac_tables = set()
        if root_name:
            own_part = raw.split('<BaseForm', 1)[0]
            ac_tables = set(re.findall(r'<AdditionalColumns table="' + re.escape(root_name) + r'\.(\w+)"', own_part))
        # ТЧ ищется у объекта основного реквизита; типа у реквизита нет — у владельца формы; тип не объект
        # метаданных (таблица значений, список) — ТЧ объекта тут ни при чём. Объекта основного реквизита
        # в расширении нет — об этом скажет проверка 14, здесь бы вышла ложная подсказка про ТЧ.
        ac_target = main_attribute_target(root_match.group(0)) if root_match else None
        owner_key = None
        if ac_target:
            if ac_target['Key'].upper() in ext_obj_index:
                owner_key = ac_target['Key']
        elif '<v8:Type' not in (root_match.group(0) if root_match else '') and bf['OwnerKey']:
            owner_key = bf['OwnerKey']
        if ac_tables and owner_key:
            owner_ts = ext_obj_index.get(owner_key.upper(), {}).get('TSColumns', {})
            for tbl_name in sorted(ac_tables):
                dep_check_count += 1
                if tbl_name.upper() not in owner_ts:
                    r.error(f'12. {ctx}: <AdditionalColumns table="{root_name}.{tbl_name}"> — TabularSection.{tbl_name} is neither borrowed nor added in extension')
                    check12_ok = False

        for mi in missing_items:
            r.warn(f'12. {ctx}: references {mi} not borrowed in extension')
            check12_ok = False

    if len(borrowed_forms_with_tree) == 0:
        r.ok('12. Form dependencies: no borrowed forms with tree')
    elif check12_ok:
        r.ok(f'12. Form dependencies: {dep_check_count} references checked')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 13: TypeLink with human-readable paths ---
    check13_ok = True
    type_link_count = 0

    for bf in borrowed_forms_with_tree:
        raw = bf['RawText']
        ctx = bf['Context']
        matches = re.findall(r'<TypeLink>\s*<xr:DataPath>Items\.[^<]*</xr:DataPath>', raw)
        if matches:
            type_link_count += len(matches)
            r.warn(f'13. {ctx}: {len(matches)} TypeLink(s) with human-readable Items.* DataPath (should be stripped)')
            check13_ok = False

    if len(borrowed_forms_with_tree) == 0:
        r.ok('13. TypeLink: no borrowed forms with tree')
    elif check13_ok:
        r.ok('13. TypeLink: clean')

    # Каталог конфигурации-источника из -ConfigPath (каталог или путь к Configuration.xml) для
    # проверки 18; есть ли там Configuration.xml, она решает и сообщает сама.
    def source_config_root():
        root = config_path_arg
        if not os.path.isabs(root):
            root = os.path.join(os.getcwd(), root)
        if os.path.exists(root) and not os.path.isdir(root):
            root = os.path.dirname(root)
        return root

    # --- Check 14: пути <Основной реквизит>.* форм расширения против объекта в расширении ---
    # Платформа разрешает путь любой формы расширения — и заимствованной, и собственной — по объекту
    # таким, каким он описан в расширении: заимствованные и собственные реквизиты, ТЧ и их колонки
    # (индекс ext_obj_index, проверка 10). Незаимствованный реквизит источника она не видит даже
    # на заимствованной форме, где он был в исходной: «Неверный путь к данным». Имена — без учёта
    # регистра. Стандартные реквизиты — по типу основного реквизита (MAIN_ATTR_STANDARD_FIELDS).
    # После ссылочного реквизита или колонки путь продолжается по целевому объекту (ref_tail_error).
    if not r.stopped and forms_with_text:
        check14_ok = True
        path_check_count = 0

        for fw in forms_with_text:
            raw = fw['RawText']
            ctx = fw['Context']
            # Только своя часть формы: <BaseForm> — снимок исходной формы, его платформа разрешает по
            # конфигурации, а не по расширению.
            own = raw.split('<BaseForm', 1)[0]
            root_match14 = MAIN_ATTR_RE.search(own)

            # Корень любого пути — реквизит, объявленный в <Attributes> самой формы, иначе «Неверный путь к
            # данным». Заимствованная без основного реквизита форма его не объявляет, а поле Объект.* на неё
            # дописать можно. Пропускаются Items.* (текущая строка таблицы) и ссылки, которые Конфигуратор
            # пишет номерами (58, 1/0:<uuid>, 306:<uuid>/8:<uuid>) — имя реквизита с цифры не начинается.
            declared = set()
            attr_section = re.search(r'(?s)<Attributes>(.*?)</Attributes>', own)
            if attr_section:
                declared = {n.upper() for n in re.findall(r'<Attribute name="([^"]+)"', attr_section.group(1))}
            undeclared = {}   # корень в верхнем регистре -> (корень как в первом пути, пути)
            for m in re.finditer(r'<(?:\w+:)?\w*DataPath[^>]*>([^<]+)</(?:\w+:)?\w*DataPath>', own):
                dp = m.group(1).strip()
                if not dp or dp[0].isdigit():
                    continue
                root = re.sub(r'^~', '', re.sub(r'\[\d+\]', '', dp)).split('.', 1)[0]
                if root.upper() == 'ITEMS' or root.upper() in declared:
                    continue
                entry = undeclared.setdefault(root.upper(), (root, []))
                if dp not in entry[1]:
                    entry[1].append(dp)
            if undeclared:
                # Подсказка — только когда корень и есть основной реквизит исходной формы: по самой исходной
                # форме (-ConfigPath), без неё — по снимку <BaseForm>, а нет его и там — по обычным именам
                # основного реквизита (так же решает form-validate).
                hint_roots = []
                hint_exact = False   # имя взято из исходной формы или <BaseForm>, а не из обычных имён
                if not root_match14 and '<BaseForm' in raw:
                    src_form = (os.path.join(source_config_root(), fw['FormRel'], 'Ext', 'Form.xml')
                                if config_path_arg else '')
                    if src_form and os.path.isfile(src_form):
                        with open(src_form, 'r', encoding='utf-8-sig') as f:
                            src_match = MAIN_ATTR_RE.search(f.read().split('<BaseForm', 1)[0])
                        if src_match:
                            hint_roots = [src_match.group(1)]
                            hint_exact = True
                    else:
                        base_match = MAIN_ATTR_RE.search(raw.split('<BaseForm', 1)[1])
                        hint_exact = base_match is not None
                        hint_roots = [base_match.group(1)] if base_match else MAIN_ATTR_DEFAULT_NAMES
                hint_roots_upper = {n.upper() for n in hint_roots}
                for root, paths in undeclared.values():   # порядок корней — как в файле
                    sample = "', '".join(paths[:3])
                    more = f' (and {len(paths) - 3} more)' if len(paths) > 3 else ''
                    if root.upper() not in hint_roots_upper:
                        hint = ''
                    elif hint_exact:
                        hint = ' — the form was borrowed without its main attribute, re-borrow it with -BorrowMainAttribute Form'
                    else:
                        hint = f" — if '{root}' is the source form's main attribute, re-borrow the form with -BorrowMainAttribute Form"
                    r.error(f"14. {ctx}: path '{sample}'{more} — form attribute '{root}' is not declared in the form{hint}")
                check14_ok = False

            # Дальше — хвост путей от основного реквизита по составу объекта (см. проверку 12). Основного
            # реквизита нет — проверять хвост не по чему.
            if not root_match14:
                continue
            root_name14 = root_match14.group(1)
            # Тип не объект метаданных — пути не по составу объекта. Так и у динамического списка: его поля —
            # результат запроса, туда входят стандартные поля списка (Ref, Date, DefaultPicture) и псевдонимы
            # (корпусная проверка: 3383 таких сегмента на 1094 формах списка УТ).
            target = main_attribute_target(root_match14.group(0))
            if target is None:
                continue
            owner_key = target['Key']
            owner_entry = ext_obj_index.get(owner_key.upper())
            if owner_entry is None:
                # Объект в составе расширения есть, но его файл не прочитан — об этом уже сказала проверка 9.
                if owner_key.upper() in ext_obj_listed:
                    continue
                # Объекта основного реквизита в расширении нет — тип не разрешается, и платформа не читает
                # форму целиком: «Исключение XDTO произошло при чтении файла». Это ошибка типа, а не путей,
                # поэтому она не зависит от того, замерен ли набор стандартных реквизитов этого типа (ниже).
                r.error(f"14. {ctx}: main attribute '{root_name14}' of type {target['TypeName']} — object {owner_key} is not in the extension (borrow it)")
                check14_ok = False
                continue
            std_fields = MAIN_ATTR_STANDARD_FIELDS.get(target['Category'].upper())
            if std_fields is None:
                continue

            # Колонки ТЧ — из описания в расширении плюс объявленные в самой форме через
            # <Columns>/<AdditionalColumns table="Объект.X">. Копия, чтобы не дописывать в индекс.
            ts_columns = {ts: dict(cols) for ts, cols in owner_entry['TSColumns'].items()}
            root_pat14 = re.escape(root_name14)
            for acm in re.finditer(r'<AdditionalColumns table="' + root_pat14 + r'\.(\w+)">(.*?)</AdditionalColumns>', own, re.DOTALL):
                cols = ts_columns.setdefault(acm.group(1).upper(), {})
                for cm in re.finditer(r'<Column name="(\w+)"', acm.group(2)):
                    cols.setdefault(cm.group(1).upper(), [])

            # Ключ — путь без учёта регистра, как у хеш-таблицы PS-порта: первое написание остаётся
            bad_paths = {}
            for m in re.finditer(r'<(?:\w+:)?\w*DataPath[^>]*>' + root_pat14 + r'\.([^<]+)</(?:\w+:)?\w*DataPath>', own):
                # Индекс строки ТЧ (Объект.Товары[0].Цена) к имени не относится
                segments = [re.sub(r'\[.*$', '', s) for s in m.group(1).split('.')]
                seg0 = segments[0]
                seg0_ci = seg0.upper()
                path_check_count += 1
                if seg0_ci in std_fields:
                    # Стандартная ТЧ видов субконто плана счетов видна, только если в описании объекта в расширении
                    # заданы свойства ExtDimensionTypes и MaxExtDimensionCount: без любого из них — «Неверный путь к
                    # данным» (замер 8.3.24). ПВХ видов субконто ещё должен быть заимствован — иначе «Неизвестный объект
                    # метаданных», это не про пути.
                    if (target['Category'] == 'ChartOfAccountsObject' and seg0_ci in ('EXTDIMENSIONTYPES', 'ВИДЫСУБКОНТО')
                            and not owner_entry['ExtDimTypes']):
                        bad = f'{root_name14}.{seg0}'
                        bad_paths.setdefault(bad.upper(), [bad, ''])[1] = (
                            f'{owner_key} in the extension lacks ExtDimensionTypes or MaxExtDimensionCount — the standard tabular section '
                            f'ExtDimensionTypes is not visible to the form (copy both properties and borrow the extra dimension types chart)')
                        continue
                    if target['Category'].upper() == 'REPORTOBJECT' and seg0_ci in SETTINGS_COMPOSER_NAMES:
                        sc_err = settings_composer_error(segments)
                        if sc_err:
                            bad = f"{root_name14}.{'.'.join(segments[:sc_err[0] + 1])}"
                            bad_paths.setdefault(bad.upper(), [bad, ''])[1] = sc_err[1]
                        continue
                    if len(segments) >= 2:
                        target_kind, target_name = owner_key.split('.', 1)
                        std_types = get_std_ref_types(target_kind, target_name, seg0)
                        if std_types:
                            add_ref_tail_bad_path(bad_paths, root_name14, segments, std_types, 1)
                    continue
                if seg0_ci not in owner_entry['Names']:
                    bad = f'{root_name14}.{seg0}'
                    bad_paths.setdefault(bad.upper(), [bad, ''])[1] = (
                        f'{owner_key} has no such attribute or tabular section in the extension '
                        f'(an unborrowed source attribute is not visible to extension forms)')
                    continue
                if len(segments) < 2:
                    continue
                if seg0_ci not in ts_columns:
                    add_ref_tail_bad_path(bad_paths, root_name14, segments, owner_entry['Names'][seg0_ci], 1)
                    continue
                seg1 = segments[1]
                seg1_ci = seg1.upper()
                if seg1_ci in STANDARD_OBJECT_FIELDS_CI:
                    continue
                # Итог колонки — псевдополе платформы: Total<Колонка> при живой колонке законен
                if seg1_ci.startswith('TOTAL') and seg1_ci[5:] in ts_columns[seg0_ci]:
                    continue
                if seg1_ci not in ts_columns[seg0_ci]:
                    bad = f'{root_name14}.{seg0}.{seg1}'
                    bad_paths.setdefault(bad.upper(), [bad, ''])[1] = (
                        f'tabular section {seg0} has no column {seg1} in the extension, and the form <Columns> does not declare it')
                    continue
                # Дальше колонки — по её типу (Объект.Товары.Номенклатура.Артикул)
                if len(segments) > 2:
                    add_ref_tail_bad_path(bad_paths, root_name14, segments, ts_columns[seg0_ci][seg1_ci], 2)

            for bad, msg in sorted(bad_paths.values(), key=lambda bm: bm[0].upper()):
                r.error(f"14. {ctx}: path '{bad}' — {msg}")
                check14_ok = False

        if check14_ok:
            r.ok(f'14. Form object paths: {path_check_count} checked')

    # --- Check 15: основные роли расширения не дают прав на заимствованные объекты ---
    # Платформа: «Назначение прав доступа на заимствованные объекты основными ролями в
    # расширениях недопустимо». Роль вне <DefaultRoles> так делать вправе — проверяем только
    # основные. Ловится статически, а по симптому (отказ загрузки) причина не читается.
    default_role_nodes = cfg_node.findall('md:Properties/md:DefaultRoles/xr:Item', NS)
    if default_role_nodes:
        adopted_cache = {}

        def is_object_adopted(type_name, obj_name):
            key = f"{type_name}.{obj_name}"
            if key in adopted_cache:
                return adopted_cache[key]
            adopted_cache[key] = False
            dir_name = CHILD_TYPE_DIR_MAP.get(type_name)
            if dir_name:
                obj_path = os.path.join(config_dir, dir_name, obj_name + '.xml')
                if os.path.isfile(obj_path):
                    try:
                        obj_root = etree.parse(obj_path).getroot()
                        ob = obj_root.find(f'md:{type_name}/md:Properties/md:ObjectBelonging', NS)
                        if ob is not None and (ob.text or '') == 'Adopted':
                            adopted_cache[key] = True
                    except Exception:
                        pass
            return adopted_cache[key]

        check15_ok = True
        check15_count = 0
        roles_ns = {'r': 'http://v8.1c.ru/8.2/roles'}
        for rn in default_role_nodes:
            m = re.match(r'^Role\.(.+)$', rn.text or '')
            if not m:
                continue
            def_role_name = m.group(1)
            rights_path = os.path.join(config_dir, 'Roles', def_role_name, 'Ext', 'Rights.xml')
            if not os.path.isfile(rights_path):
                continue
            try:
                rights_root = etree.parse(rights_path).getroot()
            except Exception:
                continue
            for name_node in rights_root.findall('r:object/r:name', roles_ns):
                full_name = name_node.text or ''
                segs = full_name.split('.')
                # Configuration.* — права самого расширения, не объект; заимствования там нет.
                if len(segs) < 2 or segs[0] == 'Configuration':
                    continue
                check15_count += 1
                if is_object_adopted(segs[0], segs[1]):
                    r.error(f"15. Role '{def_role_name}' is in DefaultRoles and grants rights on borrowed "
                            f"{segs[0]}.{segs[1]} ({full_name}): the platform forbids this. "
                            "Move these rights to a separate role outside DefaultRoles.")
                    check15_ok = False
        if check15_ok and check15_count > 0:
            r.ok(f'15. Default roles: no rights on borrowed objects ({check15_count} checked)')

    if r.stopped:
        r.finalize(out_file)
        sys.exit(1)

    # --- Check 16: модуль заимствованного объекта и пометка расширенного свойства ---
    # Свойство <xr:PropertyState> появилось в формате 2.19 (8.3.26); ниже платформа его молча
    # выбрасывает, поэтому там проверять нечего. С 2.19 состояние обязано соответствовать факту:
    # есть файл модуля — есть пометка, и наоборот. Перекос платформа принимает (проверено на
    # стенде), но выгрузка Конфигуратора так не выглядит — отсюда предупреждение, а не ошибка.
    if version_rank >= 219 and child_obj_node is not None:
        state_issues = []
        state_checked = 0
        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            if type_name not in MODULE_KINDS_BY_TYPE or type_name not in CHILD_TYPE_DIR_MAP:
                continue
            obj_name_val = (child.text or '').strip()
            if not obj_name_val:
                continue
            type_dir = os.path.join(config_dir, CHILD_TYPE_DIR_MAP[type_name])
            obj_file = os.path.join(type_dir, f'{obj_name_val}.xml')
            if not os.path.isfile(obj_file):
                continue
            with open(obj_file, 'r', encoding='utf-8-sig') as f:
                obj_text = f.read()
            if '<ObjectBelonging>Adopted</ObjectBelonging>' not in obj_text:
                continue

            for kind in MODULE_KINDS_BY_TYPE[type_name]:
                state_checked += 1
                has_file = os.path.isfile(os.path.join(type_dir, obj_name_val, 'Ext', f'{kind}.bsl'))
                has_flag = f'<xr:Property>{kind}</xr:Property>' in obj_text
                if has_file and not has_flag:
                    state_issues.append(f'{type_name}.{obj_name_val} — {kind}.bsl exists but <xr:PropertyState> for {kind} is missing')
                elif has_flag and not has_file:
                    state_issues.append(f'{type_name}.{obj_name_val} — <xr:PropertyState> for {kind} is present but {kind}.bsl is missing')

        if state_checked > 0:
            if not state_issues:
                r.ok(f'16. Borrowed object modules: extended property marks are consistent ({state_checked})')
            else:
                for issue in state_issues:
                    r.warn(f'16. {issue}')

    # --- Check 17: версия формата согласована внутри объектов расширения; сверка с Configuration.xml ---
    # Дескриптор объекта и его штампованные тела X/Ext/*.xml, дескриптор формы/макета и его тело (и
    # Configuration.xml с его Ext/*.xml) платформа загружает только в одной версии формата: «Версия формата
    # загружаемого файла … отличается от версии формата ранее загруженных файлов». Объект целиком в другой
    # версии, чем расширение, загружается — это лишь неоднородность выгрузки (типично после мержа веток,
    # выгруженных разными платформами), поэтому такое расхождение только предупреждение.
    if version:
        ver_descriptors = [resolved_path]
        if child_obj_node is not None:
            for child in child_obj_node:
                if not isinstance(child.tag, str):
                    continue
                type_name = etree.QName(child.tag).localname
                if type_name not in CHILD_TYPE_DIR_MAP:
                    continue
                ver_obj_name = (child.text or '').strip()
                if not ver_obj_name:
                    continue
                ver_type_dir = os.path.join(config_dir, CHILD_TYPE_DIR_MAP[type_name])
                ver_obj_file = os.path.join(ver_type_dir, f'{ver_obj_name}.xml')
                if not os.path.isfile(ver_obj_file):
                    continue
                ver_descriptors.append(ver_obj_file)
                for sub in ('Forms', 'Templates'):
                    sub_dir = os.path.join(ver_type_dir, ver_obj_name, sub)
                    if not os.path.isdir(sub_dir):
                        continue
                    names = sorted(n for n in os.listdir(sub_dir)
                                   if n.lower().endswith('.xml') and os.path.isfile(os.path.join(sub_dir, n)))
                    for n in names:
                        ver_descriptors.append(os.path.join(sub_dir, n))

        def ver_rel(p):
            return p[len(config_dir):].lstrip('\\/').replace('\\', '/')

        ver_errors = 0
        ver_bodies_ok = 0
        ver_off = []
        for desc in ver_descriptors:
            if r.stopped:
                break
            is_root = desc == resolved_path
            desc_ver = version if is_root else root_version(desc)
            if not desc_ver:
                continue
            if not is_root and desc_ver != version:
                ver_off.append(f'{ver_rel(desc)} {desc_ver}')
            # Тела Configuration.xml лежат в <корень>/Ext, тела объекта X.xml — в X/Ext.
            if is_root:
                ext_dir = os.path.join(config_dir, 'Ext')
            else:
                ext_dir = os.path.join(os.path.dirname(desc), os.path.splitext(os.path.basename(desc))[0], 'Ext')
            if not os.path.isdir(ext_dir):
                continue
            body_names = sorted(n for n in os.listdir(ext_dir)
                                if n.lower().endswith('.xml') and os.path.isfile(os.path.join(ext_dir, n)))
            for bn in body_names:
                body = os.path.join(ext_dir, bn)
                body_ver = root_version(body)
                if not body_ver:
                    continue
                # У заимствованной формы второй штамп — <BaseForm version=…> внутри тела; платформа сверяет
                # с дескриптором и его.
                if bn == 'Form.xml':
                    with open(body, 'r', encoding='utf-8-sig') as f:
                        body_text = f.read()
                    bfm = re.search(r'<BaseForm\s[^>]*?version="([^"]*)"', body_text)
                    if bfm and bfm.group(1) != desc_ver:
                        ver_errors += 1
                        r.error(f'17. {ver_rel(body)} <BaseForm> is stamped {bfm.group(1)}, its descriptor '
                                f'{ver_rel(desc)} {desc_ver} — the platform refuses to load parts of one object in different formats')
                        if r.stopped:
                            break
                if body_ver == desc_ver:
                    ver_bodies_ok += 1
                    continue
                ver_errors += 1
                r.error(f'17. {ver_rel(body)} is stamped {body_ver}, its descriptor {ver_rel(desc)} {desc_ver} '
                        '— the platform refuses to load parts of one object in different formats')
                if r.stopped:
                    break
        if ver_off:
            shown = ', '.join(ver_off[:5])
            if len(ver_off) > 5:
                shown += f', … (+{len(ver_off) - 5})'
            r.warn(f'17. Format version differs from the extension ({version}): {shown} — the platform loads it, '
                   'but the dump is no longer uniform (typical after merging branches dumped by different platforms)')
        elif ver_errors == 0 and ver_bodies_ok > 0:
            r.ok(f'17. Format version: {ver_bodies_ok} stamped part(s) agree with their descriptors and the extension')

    # --- Check 18: заимствованные объекты и основной язык против конфигурации-источника ---
    # ОбъектРасширяемойКонфигурации контролируется у самого объекта и у каждого заимствованного
    # подобъекта (реквизит, ТЧ, колонка ТЧ, форма — замер 8.3.24), ОсновнойЯзык — у расширения.
    # Расхождение платформа принимает при загрузке, а применять расширение отказывается, и по
    # сообщению не видно, откуда взялся чужой UUID. Нулевой UUID (cfe-init без -ConfigPath) не
    # совпадёт ни с чем — его видно и без источника. Собственный подобъект с именем незаимствованного
    # подобъекта источника платформа тоже загружает, а базу не обновляет.

    # UUID, по которому подобъект связан с основной конфигурацией: в расширении —
    # ExtendedConfigurationObject (у собственных подобъектов его нет), в источнике — атрибут uuid.
    def md_id_value(el, from_extension):
        if from_extension:
            n = el.xpath("*[local-name()='Properties']/*[local-name()='ExtendedConfigurationObject']")
            return (n[0].text or '').strip() if n else None
        return el.get('uuid') or None

    # Подобъекты, у которых в ChildObjects владельца только имя, а описание — в отдельном файле
    # <каталог владельца>/<Имя владельца>/<Каталог>/<Имя>.xml.
    nested_file_dirs = {'Form': 'Forms', 'Template': 'Templates', 'Subsystem': 'Subsystems', 'Recalculation': 'Recalculations'}

    # Объект или подобъект из отдельного файла: сам файл и всё, что под ним. False — файла нет или он
    # не читается.
    def add_md_id_file(idx, obj_file, key, from_extension):
        if not os.path.isfile(obj_file):
            return False
        try:
            doc_root = etree.parse(obj_file).getroot()
        except Exception:
            return False
        obj_el = None
        for c in doc_root:
            if isinstance(c.tag, str):
                obj_el = c
                break
        if obj_el is None:
            return False
        v = md_id_value(obj_el, from_extension)
        belonging = obj_el.xpath("*[local-name()='Properties']/*[local-name()='ObjectBelonging']")
        # Заимствованный объект без UUID тоже должен проверяться на наличие в источнике.
        if v or (from_extension and belonging and belonging[0].text == 'Adopted'):
            idx[key] = v
        own_dir = os.path.join(os.path.dirname(obj_file), os.path.splitext(os.path.basename(obj_file))[0])
        add_md_id_entries(idx, obj_el, key, from_extension, own_dir)
        return True

    # Подобъекты с собственными свойствами (реквизиты, ТЧ и их колонки, значения перечисления, команды
    # и т.п.) лежат в ChildObjects целиком — обходим их рекурсивно. Формы, макеты, вложенные подсистемы
    # и перерасчёты там — только имя: их UUID в отдельном файле под каталогом владельца.
    def add_md_id_entries(idx, el, prefix, from_extension, own_dir):
        co = el.xpath("*[local-name()='ChildObjects']")
        if not co:
            return
        for sub in co[0]:
            if not isinstance(sub.tag, str):
                continue
            sub_type = etree.QName(sub.tag).localname
            name_node = sub.xpath("*[local-name()='Properties']/*[local-name()='Name']")
            if name_node:
                key = f'{prefix}.{sub_type}.{(name_node[0].text or "").strip()}'
                v = md_id_value(sub, from_extension)
                if v:
                    idx[key] = v
                add_md_id_entries(idx, sub, key, from_extension, '')
            elif own_dir and sub_type in nested_file_dirs and (sub.text or '').strip():
                sub_name = sub.text.strip()
                sub_file = os.path.join(own_dir, nested_file_dirs[sub_type], f'{sub_name}.xml')
                add_md_id_file(idx, sub_file, f'{prefix}.{sub_type}.{sub_name}', from_extension)

    # Индекс «путь подобъекта → UUID связи» по файлу объекта; None — файла нет или он не читается.
    # Ключи сравниваются с учётом регистра: имя заимствованного подобъекта платформа сверяет точно
    # (контролируемое свойство «Имя», замер 8.3.24), хотя в коде 1С имена регистронезависимы.
    def md_id_index(type_dir, type_name, obj_name, from_extension):
        idx = {}
        if not add_md_id_file(idx, os.path.join(type_dir, f'{obj_name}.xml'), f'{type_name}.{obj_name}', from_extension):
            return None
        return idx

    # Собственные подобъекты заимствованного объекта, одноимённые (без учёта регистра) с незаимствованным
    # подобъектом источника того же вида на том же уровне: реквизит, ТЧ, колонка заимствованной ТЧ, значение
    # перечисления, форма, команда, макет. Платформа расширение загружает, а базу не обновляет: «Уже существует объект с
    # именем …» (замер 8.3.24, 8.3.27). Реквизит и ТЧ с одним именем друг другу не мешают. Совпадение с
    # подобъектом, заимствованным в этом же расширении, — дубль имени, его платформа отвергает уже на загрузке.
    def get_own_name_collisions(obj_file, prefix, ext_idx, src_idx):
        result = []
        try:
            doc_root = etree.parse(obj_file).getroot()
        except Exception:
            return result
        obj_el = next((c for c in doc_root if isinstance(c.tag, str)), None)
        co = obj_el.xpath("*[local-name()='ChildObjects']") if obj_el is not None else []
        if not co:
            return result
        own_dir = os.path.join(os.path.dirname(obj_file), os.path.splitext(os.path.basename(obj_file))[0])
        keys = []
        for sub in co[0]:
            if not isinstance(sub.tag, str):
                continue
            ln = etree.QName(sub.tag).localname
            if ln in ('Form', 'Template'):
                # Собственная форма или макет — файл есть и в нём нет ExtendedConfigurationObject. Нет файла или
                # не читается — не судим (об отсутствии файла формы говорит проверка 10)
                f_name = (sub.text or '').strip()
                if not f_name:
                    continue
                f_file = os.path.join(own_dir, nested_file_dirs[ln], f'{f_name}.xml')
                if not os.path.isfile(f_file):
                    continue
                try:
                    f_root = etree.parse(f_file).getroot()
                except Exception:
                    continue
                if f_root.xpath("//*[local-name()='Properties']/*[local-name()='ExtendedConfigurationObject']"):
                    continue
                keys.append(f'{prefix}.{ln}.{f_name}')
                continue
            if ln not in ('Attribute', 'TabularSection', 'EnumValue', 'Command'):
                continue
            name_node = sub.xpath("*[local-name()='Properties']/*[local-name()='Name']")
            if not name_node:
                continue
            k = f'{prefix}.{ln}.{(name_node[0].text or "").strip()}'
            keys.append(k)
            if ln != 'TabularSection' or k not in ext_idx:
                continue
            for col in sub.xpath("*[local-name()='ChildObjects']/*[local-name()='Attribute']"):
                col_name = col.xpath("*[local-name()='Properties']/*[local-name()='Name']")
                if col_name:
                    keys.append(f'{k}.Attribute.{(col_name[0].text or "").strip()}')
        src_ci = {sk.upper(): sk for sk in src_idx}
        ext_ci = {ek.upper() for ek in ext_idx}
        for k in keys:
            if k.upper() in ext_ci:
                continue
            if k.upper() in src_ci:
                result.append({'Own': k, 'Src': src_ci[k.upper()]})
        return result

    if not r.stopped and child_obj_node is not None:
        zero_guid = '00000000-0000-0000-0000-000000000000'
        src_root = None
        src_cfg_root = None
        if config_path_arg:
            src_root = source_config_root()
            src_cfg_file = os.path.join(src_root, 'Configuration.xml')
            if not os.path.isfile(src_cfg_file):
                r.warn(f"18. -ConfigPath '{config_path_arg}': Configuration.xml not found — comparison with the source configuration skipped")
                src_root = None
            else:
                try:
                    src_cfg_root = etree.parse(src_cfg_file).getroot()
                except Exception:
                    r.warn(f"18. -ConfigPath '{config_path_arg}': Configuration.xml is unreadable — comparison with the source configuration skipped")
                    src_root = None

        check18_ok = True
        check18_count = 0

        if src_root:
            src_def_lang_node = src_cfg_root.xpath("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='DefaultLanguage']")
            src_def_lang = (src_def_lang_node[0].text or '').strip() if src_def_lang_node else ''
            ext_def_lang = (def_lang or '').strip()
            if ext_def_lang and src_def_lang:
                check18_count += 1
                if ext_def_lang != src_def_lang:
                    r.error(f'18. Extension DefaultLanguage "{def_lang}" differs from the source configuration "{src_def_lang}" — the platform loads the extension but does not apply it («ОсновнойЯзык не совпадает»)')
                    check18_ok = False

        for child in child_obj_node:
            if r.stopped:
                break
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            if type_name not in CHILD_TYPE_DIR_MAP:
                continue
            obj_name18 = (child.text or '').strip()
            if not obj_name18:
                continue
            dir_name = CHILD_TYPE_DIR_MAP[type_name]
            ext_idx = md_id_index(os.path.join(config_dir, dir_name), type_name, obj_name18, True)
            if not ext_idx:
                continue

            if not src_root:
                for key, ext_id in ext_idx.items():
                    check18_count += 1
                    if ext_id == zero_guid:
                        r.warn(f'18. {key}: ExtendedConfigurationObject is zero — the platform loads the extension but does not apply it. Create the extension and borrow objects with -ConfigPath')
                continue

            src_idx = md_id_index(os.path.join(src_root, dir_name), type_name, obj_name18, False)
            if src_idx is None:
                r.error(f'18. {type_name}.{obj_name18}: borrowed object is missing from the source configuration ({dir_name}/{obj_name18}.xml)')
                check18_ok = False
                continue
            for key, ext_id in ext_idx.items():
                check18_count += 1
                src_id = src_idx.get(key)
                if src_id is None:
                    case_twin = next((sk for sk in src_idx if sk.upper() == key.upper()), None)
                    if case_twin:
                        r.error(f'18. {key}: the source configuration has this name in a different case ({case_twin}) — the platform loads the extension but does not apply it («контролируемое свойство Имя не совпадает»)')
                    else:
                        r.error(f'18. {key}: borrowed sub-object is missing from the source configuration')
                    check18_ok = False
                elif ext_id and ext_id.lower() != src_id.lower():
                    what = 'zero' if ext_id == zero_guid else ext_id
                    r.error(f'18. {key}: ExtendedConfigurationObject is {what}, but the UUID in the source configuration is {src_id} — the platform loads the extension but does not apply it («ОбъектРасширяемойКонфигурации не совпадает»)')
                    check18_ok = False
                if r.stopped:
                    break
            if r.stopped:
                break
            # Там, где собственных подобъектов данных быть не может, о них уже сказала проверка 10 — остаются
            # формы, команды и макеты (их добавлять можно)
            data_banned = own_child_restricted.get(type_name) == 'Error'
            for nc in get_own_name_collisions(os.path.join(config_dir, dir_name, f'{obj_name18}.xml'), f'{type_name}.{obj_name18}', ext_idx, src_idx):
                if data_banned and nc['Own'].split('.')[2] not in ('Form', 'Command', 'Template'):
                    continue
                r.error(f"18. {nc['Own']}: own sub-object, but the source configuration has an unborrowed sub-object with this name ({nc['Src']}) — the platform loads the extension but does not update the database («Уже существует объект с именем …»)")
                check18_ok = False
                if r.stopped:
                    break

        if not config_path_arg:
            r.out('[INFO]  18. Borrowed objects and the default language were not compared with the source configuration: -ConfigPath not set')
        elif src_root and check18_ok and check18_count > 0:
            r.ok(f'18. Source config: {check18_count} link(s) agree (DefaultLanguage, ExtendedConfigurationObject)')

    # --- Check 19: ссылки на объекты, которых нет в расширении ---
    # Объект основной конфигурации виден расширению, только если он заимствован (замер 8.3.24/8.3.27):
    # - ссылочный тип (реквизит, колонка, константа, измерение, параметр команды, реквизит формы, состав
    #   заимствованного определяемого типа): ниже 8.3.25 — «Неизвестное имя типа», с 8.3.25 работает;
    # - ссылка на объект (владельцы, движения, ввод на основании, журнал, состав подсистемы, план
    #   счетов регистра, задача БП): ниже 8.3.25 — «Неизвестный объект метаданных», с 8.3.25 грузится,
    #   но в рантайме связь пуста;
    # - права роли на такой объект платформа выбрасывает;
    # - тип собственного определяемого типа, источник подписки, виды субконто плана счетов не грузятся нигде;
    # - заимствованный определяемый тип с таким составом в реквизите, колонке, измерении собственного объекта
    #   или в собственной константе — «Недопустимый тип» на любой платформе (замер 8.3.25/8.3.27); в
    #   реквизитах заимствованного объекта и в реквизитах форм с 8.3.25 работает.
    # Формы (значения, СКД) и макеты не проверяются — не замерено.
    if not r.stopped and child_obj_node is not None:
        ref_type_kind = {}
        for k in ('Catalog', 'Document', 'Enum', 'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'ChartOfCalculationTypes', 'ExchangePlan', 'BusinessProcess', 'Task'):
            for s in ('Ref', 'Object', 'Selection', 'List', 'Manager'):
                ref_type_kind[k + s] = k
        for k in ('InformationRegister', 'AccumulationRegister', 'AccountingRegister', 'CalculationRegister'):
            for s in ('RecordSet', 'RecordKey', 'Record', 'Manager', 'Selection', 'List', 'RecordManager'):
                ref_type_kind[k + s] = k
        for k in ('DataProcessor', 'Report'):
            ref_type_kind[k + 'Object'] = k
            ref_type_kind[k + 'Manager'] = k
        ref_type_kind.update({'ConstantValueManager': 'Constant', 'ConstantManager': 'Constant', 'DefinedType': 'DefinedType',
                              'Characteristic': 'ChartOfCharacteristicTypes', 'BusinessProcessRoutePointRef': 'BusinessProcess',
                              'DocumentJournalSelection': 'DocumentJournal'})
        ref_type_re = re.compile(r'<v8:(Type|TypeSet)>(?:\w+:)?(\w+)\.([^<.\s]+)</v8:\1>')
        ref_list_re = re.compile(r'<(Owners|RegisterRecords|BasedOn|RegisteredDocuments|Content)>(.*?)</\1>', re.S)
        ref_item_re = re.compile(r'>(\w+)\.([^<.\s]+)</xr:Item>')
        ref_tag_re = re.compile(r'<(ChartOfAccounts|Task|ExtDimensionTypes)>(\w+)\.([^<.\s]+)</\1>')
        ref_rights_re = re.compile(r'<object>\s*<name>(\w+)\.([^<.\s]+)')
        ref_seen = set()
        check19 = {'count': 0, 'ok': True}

        # where — что ссылается (относительный путь файла), prop — свойство, kind.name — цель
        def report_ref(where, prop, kind, name, level):
            if kind.upper() not in CHILD_TYPE_KINDS_CI:
                return
            target = f'{kind}.{name}'
            check19['count'] += 1
            if target.upper() in ext_obj_listed:
                return
            key = f'{where}|{prop}|{target}'.upper()
            if key in ref_seen:
                return
            ref_seen.add(key)
            check19['ok'] = False
            if level == 'type':
                r.warn(f'19. {where}: {prop} refers to {target}, which is not in the extension — below 8.3.25 it does not load («Неизвестное имя типа»), from 8.3.25 it is allowed. Borrow {target}')
            elif level == 'adt':
                r.warn(f'19. {where}: {prop} refers to {target}, which is not in the extension — below 8.3.25 it does not load («Неизвестное имя типа»), from 8.3.25 it is allowed only in borrowed objects and forms. Borrow {target}')
            elif level == 'owndt':
                r.error(f'19. {where}: type {prop} includes {target}, which is not in the extension — the platform does not load the extension («Недопустимый тип»). Borrow {target}')
            elif level == 'never':
                r.error(f'19. {where}: {prop} refers to {target}, which is not in the extension — the platform does not load the extension. Borrow {target}')
            elif level == 'rights':
                r.error(f'19. {where}: rights on {target}, which is not in the extension — the platform drops them. Borrow {target}')
            else:
                r.error(f'19. {where}: {prop} refers to {target}, which is not in the extension — below 8.3.25 it does not load («Неизвестный объект метаданных»), from 8.3.25 it loads but the link is empty at runtime. Borrow {target}')

        def read_text19(f):
            try:
                with open(f, encoding='utf-8-sig') as fh:
                    return fh.read()
            except Exception:
                return None

        def scan_types(text, where, prop, level):
            for m in ref_type_re.finditer(text):
                k = ref_type_kind.get(m.group(2))
                if k:
                    report_ref(where, prop, k, m.group(3), level)
                if r.stopped:
                    return

        # Файлы под каталогом: (относительный путь через "/", полный путь); сначала файлы, потом
        # подкаталоги, имена по кодовым точкам — как Ordinal в PS
        def rel_files(d, rel=''):
            try:
                names = sorted(os.listdir(d))
            except OSError:
                return
            for n in names:
                if os.path.isfile(os.path.join(d, n)):
                    yield (f'{rel}/{n}' if rel else n), os.path.join(d, n)
            for n in names:
                if os.path.isdir(os.path.join(d, n)):
                    yield from rel_files(os.path.join(d, n), f'{rel}/{n}' if rel else n)

        for child in child_obj_node:
            if r.stopped:
                break
            if not isinstance(child.tag, str):
                continue
            type_name = etree.QName(child.tag).localname
            child_name = child.text or ''
            if type_name == 'Language' or type_name not in CHILD_TYPE_DIR_MAP:
                continue
            obj_dir = os.path.join(config_dir, CHILD_TYPE_DIR_MAP[type_name])
            text = read_text19(os.path.join(obj_dir, child_name + '.xml'))
            if text is None:
                continue
            where = f'{type_name}.{child_name}'

            # Подсистема: состав — у неё и у вложенных подсистем
            texts = [(where, text)]
            if type_name == 'Subsystem':
                sub_dir = os.path.join(obj_dir, child_name)
                if os.path.isdir(sub_dir):
                    for rel, f in rel_files(sub_dir):
                        segs = rel.split('/')
                        if len(segs) < 2 or segs[-2].lower() != 'subsystems' or not rel.lower().endswith('.xml'):
                            continue
                        t = read_text19(f)
                        if t is not None:
                            texts.append((f'{where}/{rel}', t))
            for w, t in texts:
                # Состав заимствованного определяемого типа — как ссылочный тип (замер 8.3.24/8.3.27, в т.ч.
                # режим расширения 8.3.24 на 8.3.27); у собственного не грузится нигде
                if type_name == 'DefinedType':
                    type_prop = 'Type'
                    type_level = 'adt' if '<ObjectBelonging>Adopted</ObjectBelonging>' in t else 'never'
                elif type_name == 'EventSubscription':
                    type_prop, type_level = 'Source', 'never'
                else:
                    type_prop, type_level = 'type', 'type'
                scan_types(t, w, type_prop, type_level)
                if r.stopped:
                    break
                # Собственный объект: заимствованный определяемый тип, в составе которого объект вне расширения
                if type_name != 'DefinedType' and '<ObjectBelonging>Adopted</ObjectBelonging>' not in t:
                    for dm in re.finditer(r'<v8:TypeSet>(?:\w+:)?DefinedType\.([^<.\s]+)</v8:TypeSet>', t):
                        dt_name = dm.group(1)
                        dt_text = read_text19(os.path.join(config_dir, CHILD_TYPE_DIR_MAP['DefinedType'], dt_name + '.xml'))
                        if dt_text is None or '<ObjectBelonging>Adopted</ObjectBelonging>' not in dt_text:
                            continue
                        for m in ref_type_re.finditer(dt_text):
                            k = ref_type_kind.get(m.group(2))
                            if k and k != 'DefinedType':
                                report_ref(w, f'DefinedType.{dt_name}', k, m.group(3), 'owndt')
                            if r.stopped:
                                break
                        if r.stopped:
                            break
                    if r.stopped:
                        break
                # Движения последовательности не замерены
                for lm in ([] if type_name == 'Sequence' else ref_list_re.finditer(t)):
                    for im in ref_item_re.finditer(lm.group(2)):
                        report_ref(w, lm.group(1), im.group(1), im.group(2), 'object')
                        if r.stopped:
                            break
                    if r.stopped:
                        break
                for tm in ref_tag_re.finditer(t):
                    report_ref(w, tm.group(1), tm.group(2), tm.group(3), 'never' if tm.group(1) == 'ExtDimensionTypes' else 'object')
                    if r.stopped:
                        break
            if r.stopped:
                break

            # Формы объекта (и общая форма): типы реквизитов и параметров формы
            form_root = os.path.join(obj_dir, child_name)
            if os.path.isdir(form_root):
                for frel, f in rel_files(form_root):
                    segs = frel.split('/')
                    if len(segs) < 2 or segs[-1].lower() != 'form.xml' or segs[-2].lower() != 'ext':
                        continue
                    t = read_text19(f)
                    if t is None:
                        continue
                    # Общая форма — сам объект (Ext/Form.xml), форма объекта — <Объект>/Forms/<Имя>
                    rel = where if len(segs) == 2 else f'{where}/' + '/'.join(segs[:-2])
                    scan_types(t, rel, 'type', 'type')
                    if r.stopped:
                        break
            if r.stopped:
                break

            if type_name == 'Role':
                t = read_text19(os.path.join(obj_dir, child_name, 'Ext', 'Rights.xml'))
                if t is not None:
                    for rm in ref_rights_re.finditer(t):
                        report_ref(where, 'rights', rm.group(1), rm.group(2), 'rights')
                        if r.stopped:
                            break

        if check19['ok'] and check19['count'] > 0:
            r.ok(f"19. References: {check19['count']} reference(s) to objects, all present in the extension")

    # --- Breadcrumb: controlled methods (&ИзменениеИКонтроль) drift is not checked here ---
    ctrl_kw = bsl_keywords()
    ctrl_re = re.compile(r'^\s*&(?:' + ctrl_kw["ru"]["Control"] + '|' + ctrl_kw["en"]["Control"] + r')\(', re.IGNORECASE)
    ctrl_count = 0
    for dp, _dn, files in os.walk(config_dir):
        for fn in files:
            if fn.endswith('.bsl'):
                try:
                    with open(os.path.join(dp, fn), 'r', encoding='utf-8-sig') as f:
                        for ln in f:
                            if ctrl_re.match(ln):
                                ctrl_count += 1
                except OSError:
                    pass
    if ctrl_count > 0:
        r.out('[INFO]  Controlled methods (&ИзменениеИКонтроль): %d — not checked for staleness here. Check with: /cfe-patch-method -Check -ExtensionPath <ext> -ConfigPath <cf>' % ctrl_count)

    # --- Final output ---
    r.finalize(out_file)
    sys.exit(1 if r.errors > 0 else 0)


if __name__ == '__main__':
    main()
