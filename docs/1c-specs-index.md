# Сводный индекс спецификаций формата XML конфигурации 1С

Единая точка входа ко всем спецификациям XML-формата выгрузки 1С:Предприятие 8.3.

---

## 1. Корневые файлы конфигурации

| Файл | Описание | Спецификация |
|------|----------|--------------|
| `Configuration.xml` | Свойства и состав конфигурации | [1c-configuration-spec.md § 2](1c-configuration-spec.md#2-configurationxml--корневой-файл-конфигурации) |
| `ConfigDumpInfo.xml` | Версии объектов (служебный) | [1c-configuration-spec.md § 3](1c-configuration-spec.md#3-configdumpinfoxml--служебный-файл-выгрузки) |
| `Ext/` | Модули, интерфейс, начальная страница | [1c-configuration-spec.md § 4](1c-configuration-spec.md#4-ext--корневой-каталог-конфигурации) |
| `Languages/` | Языки конфигурации | [1c-configuration-spec.md § 5](1c-configuration-spec.md#5-языки-languages) |

---

## 2. Объекты метаданных

Все типы объектов, встречающиеся в `ChildObjects` корневого `Configuration.xml`. Порядок соответствует порядку в XML.

### Служебные и интерфейсные

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `Language` | `Languages/` | Языки | [1c-configuration-spec.md § 5](1c-configuration-spec.md#5-языки-languages) |
| `Subsystem` | `Subsystems/` | Подсистемы | [1c-subsystem-spec.md § 3](1c-subsystem-spec.md#3-формат-подсистемы) |
| `StyleItem` | `StyleItems/` | Элементы стиля | [1c-configuration-spec.md § 6.16](1c-configuration-spec.md#616-styleitem--элемент-стиля) |
| `Style` | `Styles/` | Стили (устаревший) | [1c-configuration-spec.md § 6.17](1c-configuration-spec.md#617-style--стиль-устаревший) |
| `CommandGroup` | `CommandGroups/` | Группы команд | [1c-subsystem-spec.md § 5](1c-subsystem-spec.md#5-формат-группы-команд-commandgroup) |

### Общие объекты

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `CommonPicture` | `CommonPictures/` | Общие картинки | [1c-configuration-spec.md § 6.1](1c-configuration-spec.md#61-commonpicture--общая-картинка) |
| `SessionParameter` | `SessionParameters/` | Параметры сеанса | [1c-configuration-spec.md § 6.6](1c-configuration-spec.md#66-sessionparameter--параметр-сеанса) |
| `Role` | `Roles/` | Роли | [1c-role-spec.md § Файл метаданных](1c-role-spec.md#файл-метаданных-rolesимяролиxml) |
| `CommonTemplate` | `CommonTemplates/` | Общие макеты | [1c-configuration-spec.md § 6.2](1c-configuration-spec.md#62-commontemplate--общий-макет) |
| `FilterCriterion` | `FilterCriteria/` | Критерии отбора | [1c-configuration-spec.md § 6.11](1c-configuration-spec.md#611-filtercriterion--критерий-отбора) |
| `CommonModule` | `CommonModules/` | Общие модули | [1c-config-objects-spec.md § 21](1c-config-objects-spec.md#21-общие-модули-commonmodules) |
| `CommonAttribute` | `CommonAttributes/` | Общие реквизиты | [1c-configuration-spec.md § 6.3](1c-configuration-spec.md#63-commonattribute--общий-реквизит) |
| `CommonCommand` | `CommonCommands/` | Общие команды | [1c-subsystem-spec.md § 6](1c-subsystem-spec.md#6-формат-общей-команды-commoncommand) |
| `CommonForm` | `CommonForms/` | Общие формы | [1c-configuration-spec.md § 6.4](1c-configuration-spec.md#64-commonform--общая-форма) |

### Интеграция и сервисы

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `ExchangePlan` | `ExchangePlans/` | Планы обмена | [1c-config-objects-spec.md § 15](1c-config-objects-spec.md#15-планы-обмена-exchangeplans) |
| `XDTOPackage` | `XDTOPackages/` | XDTO-пакеты | [1c-configuration-spec.md § 6.14](1c-configuration-spec.md#614-xdtopackage--xdto-пакет) |
| `WebService` | `WebServices/` | Веб-сервисы | [1c-config-objects-spec.md § 25](1c-config-objects-spec.md#25-веб-сервисы-webservices) |
| `HTTPService` | `HTTPServices/` | HTTP-сервисы | [1c-config-objects-spec.md § 24](1c-config-objects-spec.md#24-http-сервисы-httpservices) |
| `WSReference` | `WSReferences/` | WS-ссылки | [1c-configuration-spec.md § 6.15](1c-configuration-spec.md#615-wsreference--ws-ссылка) |
| `IntegrationService` | `IntegrationServices/` | Сервисы интеграции | [1c-configuration-spec.md § 6.13](1c-configuration-spec.md#613-integrationservice--сервис-интеграции) |

### Поведение и параметризация

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `EventSubscription` | `EventSubscriptions/` | Подписки на события | [1c-config-objects-spec.md § 23](1c-config-objects-spec.md#23-подписки-на-события-eventsubscriptions) |
| `ScheduledJob` | `ScheduledJobs/` | Регламентные задания | [1c-config-objects-spec.md § 22](1c-config-objects-spec.md#22-регламентные-задания-scheduledjobs) |
| `SettingsStorage` | `SettingsStorages/` | Хранилища настроек | [1c-configuration-spec.md § 6.10](1c-configuration-spec.md#610-settingsstorage--хранилище-настроек) |
| `FunctionalOption` | `FunctionalOptions/` | Функциональные опции | [1c-configuration-spec.md § 6.7](1c-configuration-spec.md#67-functionaloption--функциональная-опция) |
| `FunctionalOptionsParameter` | `FunctionalOptionsParameters/` | Параметры ФО | [1c-configuration-spec.md § 6.8](1c-configuration-spec.md#68-functionaloptionsparameter--параметр-функциональных-опций) |
| `DefinedType` | `DefinedTypes/` | Определяемые типы | [1c-config-objects-spec.md § 20](1c-config-objects-spec.md#20-определяемые-типы-definedtypes) |
| `Constant` | `Constants/` | Константы | [1c-config-objects-spec.md § 17](1c-config-objects-spec.md#17-константы-constants) |

### Прикладные объекты

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `Catalog` | `Catalogs/` | Справочники | [1c-config-objects-spec.md § 7](1c-config-objects-spec.md#7-справочники-catalogs) |
| `Document` | `Documents/` | Документы | [1c-config-objects-spec.md § 8](1c-config-objects-spec.md#8-документы-documents) |
| `DocumentNumerator` | `DocumentNumerators/` | Нумераторы документов | [1c-configuration-spec.md § 6.12](1c-configuration-spec.md#612-documentnumerator--нумератор-документов) |
| `Sequence` | `Sequences/` | Последовательности | [1c-configuration-spec.md § 6.9](1c-configuration-spec.md#69-sequence--последовательность-документов) |
| `DocumentJournal` | `DocumentJournals/` | Журналы документов | [1c-config-objects-spec.md § 19](1c-config-objects-spec.md#19-журналы-документов-documentjournals) |
| `Enum` | `Enums/` | Перечисления | [1c-config-objects-spec.md § 16](1c-config-objects-spec.md#16-перечисления-enums) |
| `Report` | `Reports/` | Отчёты | [1c-config-objects-spec.md § 18](1c-config-objects-spec.md#18-отчёты-и-обработки) |
| `DataProcessor` | `DataProcessors/` | Обработки | [1c-config-objects-spec.md § 18](1c-config-objects-spec.md#18-отчёты-и-обработки) |

### Регистры

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `InformationRegister` | `InformationRegisters/` | Регистры сведений | [1c-config-objects-spec.md § 9.1](1c-config-objects-spec.md#91-регистры-сведений-informationregisters) |
| `AccumulationRegister` | `AccumulationRegisters/` | Регистры накопления | [1c-config-objects-spec.md § 9.4](1c-config-objects-spec.md#94-регистры-накопления-accumulationregisters) |
| `AccountingRegister` | `AccountingRegisters/` | Регистры бухгалтерии | [1c-config-objects-spec.md § 9.5](1c-config-objects-spec.md#95-регистры-бухгалтерии-accountingregisters) |
| `CalculationRegister` | `CalculationRegisters/` | Регистры расчёта | [1c-config-objects-spec.md § 9.6](1c-config-objects-spec.md#96-регистры-расчёта-calculationregisters) |

### Планы

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `ChartOfCharacteristicTypes` | `ChartsOfCharacteristicTypes/` | Планы видов характеристик | [1c-config-objects-spec.md § 11](1c-config-objects-spec.md#11-планы-видов-характеристик-chartsofcharacteristictypes) |
| `ChartOfAccounts` | `ChartsOfAccounts/` | Планы счетов | [1c-config-objects-spec.md § 10](1c-config-objects-spec.md#10-планы-счетов-chartsofaccounts) |
| `ChartOfCalculationTypes` | `ChartsOfCalculationTypes/` | Планы видов расчёта | [1c-config-objects-spec.md § 12](1c-config-objects-spec.md#12-планы-видов-расчёта-chartsofcalculationtypes) |

### Бизнес-процессы

| XML-элемент | Каталог | Русское название | Спецификация |
|-------------|---------|-----------------|--------------|
| `BusinessProcess` | `BusinessProcesses/` | Бизнес-процессы | [1c-config-objects-spec.md § 13](1c-config-objects-spec.md#13-бизнес-процессы-businessprocesses) |
| `Task` | `Tasks/` | Задачи | [1c-config-objects-spec.md § 14](1c-config-objects-spec.md#14-задачи-tasks) |

---

## 3. Вложенные форматы

Форматы файлов, вложенных в каталоги объектов метаданных.

| Формат | Файл | Описание | Спецификация |
|--------|------|----------|--------------|
| Управляемая форма | `Ext/Form.xml` | Элементы, реквизиты, команды | [1c-form-spec.md § 1](1c-form-spec.md#1-корневой-элемент) |
| СКД (DataCompositionSchema) | `Ext/Template.xml` | Схема компоновки данных | [1c-dcs-spec.md § 2](1c-dcs-spec.md#2-общая-структура-datacompositionschema) |
| Табличный документ (MXL) | `Ext/Template.xml` | Печатная форма | [1c-spreadsheet-spec.md](1c-spreadsheet-spec.md#структура-документа) |
| Роль (Rights) | `Ext/Rights.xml` | Права доступа и RLS | [1c-role-spec.md](1c-role-spec.md#файл-прав-rolesимяролиextrightsxml) |
| Справка (Help) | `Ext/Help/` | Встроенная справка | [1c-help-spec.md § 1](1c-help-spec.md#1-структура-файлов) |
| Предопределённые элементы | `Predefined.xml` | Предопределённые справочники/ПВХ | [1c-config-objects-spec.md § 7.2](1c-config-objects-spec.md#72-предопределённые-элементы-predefinedxml) |
| Состав плана обмена | `Content.xml` | Объекты синхронизации | [1c-config-objects-spec.md § 15.4](1c-config-objects-spec.md#154-состав-плана-обмена-contentxml) |
| Карта маршрута | `Flowchart.xml` | Маршрут бизнес-процесса | [1c-config-objects-spec.md § 13.3](1c-config-objects-spec.md#133-карта-маршрута-flowchartxml) |

---

## 4. Внешние обработки и отчёты

| Формат | Описание | Спецификация |
|--------|----------|--------------|
| EPF (внешняя обработка) | ExternalDataProcessor | [1c-epf-spec.md § 1](1c-epf-spec.md#1-структура-каталогов) |
| ERF (внешний отчёт) | ExternalReport | [1c-erf-spec.md § 1](1c-erf-spec.md#1-структура-каталогов) |

---

## 5. Общие элементы формата

Общие для всех типов объектов структуры XML описаны в спецификации объектов:

| Тема | Спецификация |
|------|--------------|
| Корневой элемент MetaDataObject | [1c-config-objects-spec.md § 2](1c-config-objects-spec.md#2-общий-формат-xml) |
| Пространства имён XML | [1c-config-objects-spec.md § 2.2](1c-config-objects-spec.md#22-пространства-имён) |
| InternalInfo / GeneratedType | [1c-config-objects-spec.md § 3](1c-config-objects-spec.md#3-internalinfo--внутренняя-информация) |
| Общие свойства Properties | [1c-config-objects-spec.md § 4](1c-config-objects-spec.md#4-общие-элементы-properties) |
| Стандартные реквизиты | [1c-config-objects-spec.md § 5](1c-config-objects-spec.md#5-стандартные-реквизиты-standardattributes) |
| Дочерние объекты (Attribute, TabularSection, Form, Template, Command) | [1c-config-objects-spec.md § 6](1c-config-objects-spec.md#6-дочерние-объекты-childobjects) |
| Формат ссылок на объекты | [1c-config-objects-spec.md § 28](1c-config-objects-spec.md#28-формат-ссылок-на-объекты-метаданных) |
| Различия версий 2.17 → 2.20 | [1c-config-objects-spec.md § 26](1c-config-objects-spec.md#26-различия-версий-платформы) |

---

## 6. DSL-спецификации (компактный формат ввода)

| DSL | Описание | Спецификация |
|-----|----------|--------------|
| Meta DSL | JSON-формат для создания/редактирования объектов | [meta-dsl-spec.md](meta-dsl-spec.md) |
| Form DSL | JSON-формат для компиляции форм | [form-dsl-spec.md](form-dsl-spec.md) |
| SKD DSL | JSON-формат для компиляции СКД | [skd-dsl-spec.md](skd-dsl-spec.md) |
| MXL DSL | JSON-формат для компиляции табличных документов | [mxl-dsl-spec.md](mxl-dsl-spec.md) |
| Role DSL | JSON-формат для компиляции ролей | [role-dsl-spec.md](role-dsl-spec.md) |
