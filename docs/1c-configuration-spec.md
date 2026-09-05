# Спецификация корневой структуры конфигурации 1С

Формат: XML-выгрузка конфигурации 1С:Предприятие 8.3 (Конфигуратор → Конфигурация → Выгрузить конфигурацию в файлы).
Проверенный диапазон версий формата: `2.17` (платформа 8.3.24) … `2.21` (8.5). Полная лестница — [§7.1](#71-лестница-версий).

Источники: выгрузки Бухгалтерия предприятия (платформы 8.3.24–8.3.27), ERP 2 (8.3.24), УНФ (8.5.1).

> **Связанные спецификации:**
> - Объекты метаданных — [1c-config-objects-spec.md](1c-config-objects-spec.md)
> - Подсистемы и командный интерфейс — [1c-subsystem-spec.md](1c-subsystem-spec.md)
> - Сводный индекс — [1c-specs-index.md](1c-specs-index.md)

---

## 1. Общая структура выгрузки

```
Configuration.xml                  # Корневой файл — свойства и состав конфигурации
ConfigDumpInfo.xml                 # Служебный файл — версии объектов
Ext/                               # Корневой каталог модулей и интерфейса
Languages/                         # Языки конфигурации
Subsystems/                        # Подсистемы
Catalogs/                          # Справочники
Documents/                         # Документы
...                                # Каталоги всех типов объектов (см. раздел 2.4)
```

Полный перечень каталогов объектов и их формат — [1c-config-objects-spec.md § 1](1c-config-objects-spec.md#1-общая-структура-выгрузки).

---

## 2. Configuration.xml — корневой файл конфигурации

### 2.1. Общая структура

```xml
<?xml version="1.0" encoding="utf-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
    ... version="2.17">
  <Configuration uuid="e0666db2-...">
    <InternalInfo>...</InternalInfo>
    <Properties>...</Properties>
    <ChildObjects>...</ChildObjects>
  </Configuration>
</MetaDataObject>
```

Атрибут `version` корневого элемента `MetaDataObject` определяет версию формата выгрузки.

### 2.2. InternalInfo

Содержит набор `xr:ContainedObject` — пары ClassId/ObjectId, идентифицирующие внутренние компоненты конфигурации (модули, интерфейс, справка и т.д.). Количество записей фиксировано (7 в типичной конфигурации).

```xml
<InternalInfo>
  <xr:ContainedObject>
    <xr:ClassId>9cd510cd-abfc-11d4-9434-004095e12fc7</xr:ClassId>
    <xr:ObjectId>f0ba0954-a66b-4085-9df1-b8a4283bdbd3</xr:ObjectId>
  </xr:ContainedObject>
  <!-- ещё 6 записей -->
</InternalInfo>
```

ClassId — фиксированные идентификаторы классов платформы. ObjectId — уникальные для каждой конфигурации.

### 2.3. Properties — свойства конфигурации

Свойства идут строго в фиксированном порядке. Пустые свойства записываются как самозакрывающийся элемент (`<Comment/>`) или с пробелом (`<Comment />`).

#### Идентификация и общие

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Name` | `xs:string` | Имя конфигурации (идентификатор) |
| `Synonym` | `LocalString` | Отображаемое имя |
| `Comment` | `xs:string` | Комментарий |
| `NamePrefix` | `xs:string` | Префикс имён объектов |
| `Vendor` | `xs:string` | Поставщик |
| `Version` | `xs:string` | Версия конфигурации (напр. `3.0.181.31`) |
| `UpdateCatalogAddress` | `xs:string` | URL каталога обновлений |
| `BriefInformation` | `LocalString` | Краткая информация |
| `DetailedInformation` | `LocalString` | Подробная информация |
| `Copyright` | `LocalString` | Авторские права |
| `VendorInformationAddress` | `LocalString` | Адрес сайта поставщика |
| `ConfigurationInformationAddress` | `LocalString` | Адрес информации о конфигурации |

#### Режимы работы и совместимость

| Свойство | Тип | Описание |
|----------|-----|----------|
| `ConfigurationExtensionCompatibilityMode` | enum | Совместимость расширений (`Version8_3_24`, ...) |
| `DefaultRunMode` | enum | Режим запуска (`ManagedApplication`) |
| `ScriptVariant` | enum | Язык скриптов (`Russian` / `English`) |
| `CompatibilityMode` | enum | Режим совместимости (`Version8_3_24`, ...) |
| `DataLockControlMode` | enum | Управление блокировками (`Managed` / `Automatic`) |
| `ObjectAutonumerationMode` | enum | Автонумерация (`NotAutoFree` / `AutoFree`) |
| `ModalityUseMode` | enum | Модальность (`DontUse` / `Use` / `UseWithWarnings`) |
| `SynchronousPlatformExtensionAndAddInCallUseMode` | enum | Синхр. вызовы (`DontUse` / `Use`) |
| `InterfaceCompatibilityMode` | enum | Совместимость интерфейса (`Taxi` / `TaxiEnableVersion8_2`) |
| `DatabaseTablespacesUseMode` | enum | Табличные пространства (`DontUse` / `Use`) |
| `MainClientApplicationWindowMode` | enum | Режим окна (`Normal` / `Fullscreen` / `Kiosk`) |

#### Назначение и использование

| Свойство | Тип | Описание |
|----------|-----|----------|
| `UsePurposes` | list | Назначения: `PlatformApplication`, `MobilePlatformApplication` |
| `DefaultRoles` | list | Роли по умолчанию: `<xr:Item xsi:type="xr:MDObjectRef">Role.XXX</xr:Item>` |
| `DefaultLanguage` | ref | Язык по умолчанию: `Language.Русский` |
| `IncludeHelpInContents` | `xs:boolean` | Включить справку в оглавление |
| `UseManagedFormInOrdinaryApplication` | `xs:boolean` | Управл. формы в обычном приложении |
| `UseOrdinaryFormInManagedApplication` | `xs:boolean` | Обычные формы в управл. приложении |
| `Content` | list | Состав конфигурации (обычно пуст — используется при расширениях) |
| `StandaloneConfigurationRestrictionRoles` | list | Роли ограничения автономной конфигурации |

#### Хранилища настроек

| Свойство | Тип | Описание |
|----------|-----|----------|
| `CommonSettingsStorage` | ref | Хранилище общих настроек |
| `ReportsUserSettingsStorage` | ref | Хранилище пользовательских настроек отчётов |
| `ReportsVariantsStorage` | ref | Хранилище вариантов отчётов (напр. `SettingsStorage.XXX`) |
| `FormDataSettingsStorage` | ref | Хранилище данных форм |
| `DynamicListsUserSettingsStorage` | ref | Хранилище настроек динамических списков |
| `URLExternalDataStorage` | ref | Хранилище внешних данных URL |

#### Формы по умолчанию

| Свойство | Тип | Описание |
|----------|-----|----------|
| `DefaultReportForm` | ref | Форма отчёта по умолчанию (напр. `CommonForm.ФормаОтчета`) |
| `DefaultReportVariantForm` | ref | Форма варианта отчёта |
| `DefaultReportSettingsForm` | ref | Форма настроек отчёта |
| `DefaultReportAppearanceTemplate` | ref | Шаблон оформления отчёта |
| `DefaultDynamicListSettingsForm` | ref | Форма настроек динамического списка |
| `DefaultSearchForm` | ref | Форма поиска |
| `DefaultDataHistoryChangeHistoryForm` | ref | Форма истории изменений |
| `DefaultDataHistoryVersionDataForm` | ref | Форма данных версии |
| `DefaultDataHistoryVersionDifferencesForm` | ref | Форма различий версий |
| `DefaultCollaborationSystemUsersChoiceForm` | ref | Форма выбора пользователей |
| `DefaultConstantsForm` | ref | Форма констант |
| `DefaultInterface` | ref | Интерфейс по умолчанию (устаревший) |
| `DefaultStyle` | ref | Стиль по умолчанию (устаревший) |

#### Полнотекстовый поиск

| Свойство | Тип | Описание |
|----------|-----|----------|
| `AdditionalFullTextSearchDictionaries` | `xs:string` | Дополнительные словари |

#### Мобильные настройки

| Свойство | Тип | Описание |
|----------|-----|----------|
| `RequiredMobileApplicationPermissions` | list | Обязательные разрешения |
| `UsedMobileApplicationFunctionalities` | list | Используемые функциональности (см. ниже) |
| `MobileApplicationURLs` | list | URL мобильного приложения |
| `AllowedIncomingShareRequestTypes` | list | Разрешённые типы входящих share-запросов |

**UsedMobileApplicationFunctionalities** — список из `app:functionality` с подэлементами `app:functionality` (имя) и `app:use` (boolean):

```xml
<UsedMobileApplicationFunctionalities>
  <app:functionality>
    <app:functionality>Biometrics</app:functionality>
    <app:use>true</app:use>
  </app:functionality>
  <!-- ... -->
</UsedMobileApplicationFunctionalities>
```

Известные функциональности: `Biometrics`, `Location`, `BackgroundLocation`, `BluetoothPrinters`, `WiFiPrinters`, `Contacts`, `Calendars`, `PushNotifications`, `LocalNotifications`, `InAppPurchases`, `PersonalComputerFileExchange`, `Ads`, `NumberDialing`, `CallProcessing`, `CallLog`, `AutoSendSMS`, `ReceiveSMS`, `SMSLog`, `Camera`, `Microphone`, `MusicLibrary`, `PictureAndVideoLibraries`, `AudioPlaybackAndVibration`, `BackgroundAudioPlaybackAndVibration`, `InstallPackages`, `OSBackup`, `ApplicationUsageStatistics`, `BarcodeScanning`, `BackgroundAudioRecording`, `AllFilesAccess`, `Videoconferences`, `NFC`, `DocumentScanning`, `SpeechToText`, `Geofences`, `IncomingShareRequests`, `AllIncomingShareRequestsTypesProcessing`, `TextToSpeech` (v2.20+).

### 2.4. ChildObjects — состав конфигурации

Перечисляет все объекты метаданных, сгруппированные по типу. Имя XML-элемента = тип объекта, текстовое содержимое = имя объекта. Порядок типов фиксирован:

```xml
<ChildObjects>
  <Language>Русский</Language>
  <Subsystem>Администрирование</Subsystem>
  <Subsystem>Продажи</Subsystem>
  <StyleItem>АктуальнаяПодпискаЦвет</StyleItem>
  <!-- Style (только ERP и аналогичные) -->
  <CommonPicture>AppStore</CommonPicture>
  <SessionParameter>АвторизованныйПользователь</SessionParameter>
  <Role>ПолныеПрава</Role>
  <CommonTemplate>fresh</CommonTemplate>
  <FilterCriterion>ДокументыПоВидуОплаты</FilterCriterion>
  <CommonModule>АвтоматическиеСкидки</CommonModule>
  <!-- Bot (Боты; платформа 8.3.18 и новее) -->
  <CommonAttribute>КомментарийЯзык1</CommonAttribute>
  <ExchangePlan>ОбновлениеИнформационнойБазы</ExchangePlan>
  <XDTOPackage>AgentScripts</XDTOPackage>
  <WebService>EnterpriseDataExchange_1_0_1_2</WebService>
  <HTTPService>RegApi</HTTPService>
  <WSReference>WSСборОтчетностиРосстата</WSReference>
  <EventSubscription>ВстраиваниеОбщихФорм</EventSubscription>
  <ScheduledJob>АвтоматическаяВыгрузкаЧеков</ScheduledJob>
  <SettingsStorage>БуферыОбменаНовостей</SettingsStorage>
  <FunctionalOption>ИспользоватьВалюту</FunctionalOption>
  <FunctionalOptionsParameter>Организация</FunctionalOptionsParameter>
  <DefinedType>ОписаниеТаблицОбъекта</DefinedType>
  <CommonCommand>АвтономнаяРабота</CommonCommand>
  <CommandGroup>Документы</CommandGroup>
  <Constant>АдресОбработкиОповещений</Constant>
  <CommonForm>ФормаОтчета</CommonForm>
  <Catalog>Банки</Catalog>
  <Document>АвансовыйОтчет</Document>
  <DocumentNumerator>ПерсонифицированныйУчет</DocumentNumerator>
  <Sequence>ДокументыОрганизаций</Sequence>
  <DocumentJournal>ЖурналДокументовЕГАИС</DocumentJournal>
  <Enum>АвтоОперацииСПодотчетником</Enum>
  <Report>АктСверки</Report>
  <DataProcessor>АвансовыйОтчет</DataProcessor>
  <InformationRegister>АвторизованныеПодключения</InformationRegister>
  <AccumulationRegister>ВозвратыТоваров</AccumulationRegister>
  <ChartOfCharacteristicTypes>ВидыСубконтоХозрасчетные</ChartOfCharacteristicTypes>
  <ChartOfAccounts>Хозрасчетный</ChartOfAccounts>
  <AccountingRegister>Хозрасчетный</AccountingRegister>
  <ChartOfCalculationTypes>Начисления</ChartOfCalculationTypes>
  <!-- CalculationRegister (только ERP и аналогичные) -->
  <BusinessProcess>Задание</BusinessProcess>
  <Task>ЗадачаИсполнителя</Task>
  <ExternalDataSource>ВнешниеДанные</ExternalDataSource>
  <IntegrationService>ОбменСообщениями</IntegrationService>
</ChildObjects>
```

#### Порядок типов в ChildObjects

| № | XML-элемент | Каталог | Описание |
|---|-------------|---------|----------|
| 1 | `Language` | `Languages/` | Языки |
| 2 | `Subsystem` | `Subsystems/` | Подсистемы |
| 3 | `StyleItem` | `StyleItems/` | Элементы стиля |
| 4 | `Style` | `Styles/` | Стили (устаревший тип) |
| 5 | `CommonPicture` | `CommonPictures/` | Общие картинки |
| 6 | `SessionParameter` | `SessionParameters/` | Параметры сеанса |
| 7 | `Role` | `Roles/` | Роли |
| 8 | `CommonTemplate` | `CommonTemplates/` | Общие макеты |
| 9 | `FilterCriterion` | `FilterCriteria/` | Критерии отбора |
| 10 | `CommonModule` | `CommonModules/` | Общие модули |
| 11 | `CommonAttribute` | `CommonAttributes/` | Общие реквизиты |
| 12 | `ExchangePlan` | `ExchangePlans/` | Планы обмена |
| 13 | `XDTOPackage` | `XDTOPackages/` | XDTO-пакеты |
| 14 | `WebService` | `WebServices/` | Веб-сервисы |
| 15 | `HTTPService` | `HTTPServices/` | HTTP-сервисы |
| 16 | `WSReference` | `WSReferences/` | WS-ссылки |
| 17 | `EventSubscription` | `EventSubscriptions/` | Подписки на события |
| 18 | `ScheduledJob` | `ScheduledJobs/` | Регламентные задания |
| 19 | `SettingsStorage` | `SettingsStorages/` | Хранилища настроек |
| 20 | `FunctionalOption` | `FunctionalOptions/` | Функциональные опции |
| 21 | `FunctionalOptionsParameter` | `FunctionalOptionsParameters/` | Параметры ФО |
| 22 | `DefinedType` | `DefinedTypes/` | Определяемые типы |
| 23 | `Bot` | `Bots/` | Боты (платформа 8.3.18+) |
| 24 | `PaletteColor` | `PaletteColors/` | Цвета палитры (платформа 8.5+) |
| 25 | `CommonCommand` | `CommonCommands/` | Общие команды |
| 26 | `CommandGroup` | `CommandGroups/` | Группы команд |
| 27 | `Constant` | `Constants/` | Константы |
| 28 | `CommonForm` | `CommonForms/` | Общие формы |
| 29 | `Catalog` | `Catalogs/` | Справочники |
| 30 | `Document` | `Documents/` | Документы |
| 31 | `DocumentNumerator` | `DocumentNumerators/` | Нумераторы документов |
| 32 | `Sequence` | `Sequences/` | Последовательности |
| 33 | `DocumentJournal` | `DocumentJournals/` | Журналы документов |
| 34 | `Enum` | `Enums/` | Перечисления |
| 35 | `Report` | `Reports/` | Отчёты |
| 36 | `DataProcessor` | `DataProcessors/` | Обработки |
| 37 | `InformationRegister` | `InformationRegisters/` | Регистры сведений |
| 38 | `AccumulationRegister` | `AccumulationRegisters/` | Регистры накопления |
| 39 | `ChartOfCharacteristicTypes` | `ChartsOfCharacteristicTypes/` | Планы видов характеристик |
| 40 | `ChartOfAccounts` | `ChartsOfAccounts/` | Планы счетов |
| 41 | `AccountingRegister` | `AccountingRegisters/` | Регистры бухгалтерии |
| 42 | `ChartOfCalculationTypes` | `ChartsOfCalculationTypes/` | Планы видов расчёта |
| 43 | `CalculationRegister` | `CalculationRegisters/` | Регистры расчёта |
| 44 | `BusinessProcess` | `BusinessProcesses/` | Бизнес-процессы |
| 45 | `Task` | `Tasks/` | Задачи |
| 46 | `ExternalDataSource` | `ExternalDataSources/` | Внешние источники данных |
| 47 | `IntegrationService` | `IntegrationServices/` | Сервисы интеграции |

Внутри одного типа объекты отсортированы по имени (алфавитный порядок). Типы, для которых нет объектов, в ChildObjects не записываются.

### 2.5. InternalInfo объектов — наборы GeneratedType

У каждого объекта метаданных в `<InternalInfo>` перечислены порождаемые платформой типы. Набор фиксирован для типа объекта: имя элемента — `<префикс>.<ИмяОбъекта>`, атрибут `category` — категория из таблицы. **Неполный набор платформа отвергает при загрузке**: «отсутствует один или более типов объекта <Тип>» (для заимствованных оболочек в расширениях — тоже).

Запись `префикс`/Категория; `…` в префиксе = имя типа объекта (`…Ref` у `ChartOfAccounts` читается `ChartOfAccountsRef`).

| Тип объекта | Префикс + категория (в порядке типовой выгрузки) |
|-------------|--------------------------------------------------|
| `Catalog` | `CatalogObject`/Object, `CatalogRef`/Ref, `CatalogSelection`/Selection, `CatalogList`/List, `CatalogManager`/Manager |
| `Document` | `DocumentObject`/Object, `DocumentRef`/Ref, `DocumentSelection`/Selection, `DocumentList`/List, `DocumentManager`/Manager |
| `Enum` | `EnumRef`/Ref, `EnumManager`/Manager, `EnumList`/List |
| `Constant` | `ConstantManager`/Manager, `ConstantValueManager`/ValueManager, `ConstantValueKey`/ValueKey |
| `Report` | `ReportObject`/Object, `ReportManager`/Manager |
| `DataProcessor` | `DataProcessorObject`/Object, `DataProcessorManager`/Manager |
| `ExchangePlan` | `ExchangePlanObject`/Object, `ExchangePlanRef`/Ref, `ExchangePlanSelection`/Selection, `ExchangePlanList`/List, `ExchangePlanManager`/Manager |
| `Task` | `TaskObject`/Object, `TaskRef`/Ref, `TaskSelection`/Selection, `TaskList`/List, `TaskManager`/Manager |
| `BusinessProcess` | `BusinessProcessObject`/Object, `BusinessProcessRef`/Ref, `BusinessProcessSelection`/Selection, `BusinessProcessList`/List, `BusinessProcessManager`/Manager, `BusinessProcessRoutePointRef`/RoutePointRef |
| `ChartOfCharacteristicTypes` | `ChartOfCharacteristicTypesObject`/Object, `…Ref`/Ref, `…Selection`/Selection, `…List`/List, `Characteristic`/Characteristic, `…Manager`/Manager |
| `ChartOfAccounts` | `ChartOfAccountsObject`/Object, `…Ref`/Ref, `…Selection`/Selection, `…List`/List, `…Manager`/Manager, `…ExtDimensionTypes`/ExtDimensionTypes, `…ExtDimensionTypesRow`/ExtDimensionTypesRow |
| `ChartOfCalculationTypes` | `ChartOfCalculationTypesObject`/Object, `…Ref`/Ref, `…Selection`/Selection, `…List`/List, `…Manager`/Manager, `DisplacingCalculationTypes`/DisplacingCalculationTypes, `DisplacingCalculationTypesRow`/DisplacingCalculationTypesRow, `BaseCalculationTypes`/BaseCalculationTypes, `BaseCalculationTypesRow`/BaseCalculationTypesRow, `LeadingCalculationTypes`/LeadingCalculationTypes, `LeadingCalculationTypesRow`/LeadingCalculationTypesRow |
| `InformationRegister` | `InformationRegisterRecord`/Record, `…Manager`/Manager, `…Selection`/Selection, `…List`/List, `…RecordSet`/RecordSet, `…RecordKey`/RecordKey, `…RecordManager`/RecordManager |
| `AccumulationRegister` | `AccumulationRegisterRecord`/Record, `…Manager`/Manager, `…Selection`/Selection, `…List`/List, `…RecordSet`/RecordSet, `…RecordKey`/RecordKey |
| `AccountingRegister` | `AccountingRegisterRecord`/Record, `AccountingRegisterExtDimensions`/ExtDimensions, `…Manager`/Manager, `…Selection`/Selection, `…List`/List, `…RecordSet`/RecordSet, `…RecordKey`/RecordKey |
| `CalculationRegister` | `CalculationRegisterRecord`/Record, `…Manager`/Manager, `…Selection`/Selection, `…List`/List, `…RecordSet`/RecordSet, `…RecordKey`/RecordKey, `RecalculationsManager`/Recalcs |
| `DocumentJournal` | `DocumentJournalSelection`/Selection, `DocumentJournalList`/List, `DocumentJournalManager`/Manager |
| `Sequence` | `SequenceRecord`/Record, `SequenceManager`/Manager, `SequenceRecordSet`/RecordSet |
| `FilterCriterion` | `FilterCriterionManager`/Manager, `FilterCriterionList`/List |
| `SettingsStorage` | `SettingsStorageManager`/Manager |
| `IntegrationService` | `IntegrationServiceManager`/Manager |
| `WSReference` | `WSReferenceManager`/Manager |
| `DefinedType` | `DefinedType`/DefinedType |
| `ExternalDataSource` | `ExternalDataSourceManager`/Manager, `ExternalDataSourceTablesManager`/TablesManager, `ExternalDataSourceCubesManager`/CubesManager |
| `Table` | `ExternalDataSourceTableManager`/Manager, `ExternalDataSourceTableObject`/Object, `ExternalDataSourceTableRef`/Ref, `ExternalDataSourceTableList`/List, `ExternalDataSourceTableRecord`/Record, `ExternalDataSourceTableRecordSet`/RecordSet, `ExternalDataSourceTableRecordKey`/RecordKey, `ExternalDataSourceTableRecordManager`/RecordManager |

`Table` — корневой элемент файла таблицы внешнего источника (`ExternalDataSources/<Источник>/Tables/<Имя>.xml`),
единственный подчинённый объект со своим `<InternalInfo>` в отдельном файле. Имя элемента у него
**трёхчастное**: `<префикс>.<ИмяИсточника>.<ИмяТаблицы>` (например
`ExternalDataSourceTableRef.PG.eds_public_products`), поэтому навыки-эмиттеры строят его инлайном,
а не из карты «вид → набор». У `<Field>` и `<Function>` блока `InternalInfo` нет — только атрибут `uuid`.

Табличные части объектов несут собственную пару в своём `<InternalInfo>`: `<Тип>TabularSection.<Объект>.<ТЧ>`/TabularSection и `<Тип>TabularSectionRow.<Объект>.<ТЧ>`/TabularSectionRow.

Без `<InternalInfo>`/`GeneratedType` идут `CommonModule`, `ScheduledJob`, `EventSubscription` и прочие объекты без порождаемых типов.

Порядок в таблице — как в типовых выгрузках; на загрузку он не влияет (проверено вставкой `Characteristic` в середину набора заимствованного плана видов характеристик), значим именно состав.

---

## 3. ConfigDumpInfo.xml — служебный файл выгрузки

Содержит информацию о версиях всех объектов конфигурации. Используется платформой для определения изменений при загрузке.

### 3.1. Общая структура

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ConfigDumpInfo xmlns="http://v8.1c.ru/8.3/xcf/dumpinfo"
    xmlns:xen="http://v8.1c.ru/8.3/xcf/enums"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    format="Hierarchical" version="2.17">
  <ConfigVersions>
    <Metadata name="..." id="..." configVersion="...">
      <Metadata name="..." id="..."/>
      ...
    </Metadata>
    ...
  </ConfigVersions>
</ConfigDumpInfo>
```

### 3.2. Атрибуты корневого элемента

| Атрибут | Описание |
|---------|----------|
| `format` | Формат выгрузки (`Hierarchical`) |
| `version` | Версия формата (`2.17` / `2.20`) — совпадает с Configuration.xml |

### 3.3. Структура записей Metadata

Каждый `<Metadata>` описывает один объект или его компоненту:

| Атрибут | Описание |
|---------|----------|
| `name` | Полное имя в dot-нотации (напр. `Catalog.Банки.Attribute.Код`) |
| `id` | UUID объекта (с суффиксом `.N` для модулей/форм/справки) |
| `configVersion` | Хеш версии (32 hex-символа + `00000000`), только у записей с файлами |

**Правила:**
- Корневой объект содержит вложенные `<Metadata>` для реквизитов, измерений, ресурсов (без `configVersion`, т.к. они не имеют отдельных файлов)
- Формы, модули, справка — отдельные `<Metadata>` верхнего уровня с `configVersion`
- Суффиксы id для модулей: `.0` — форма, `.1` — модуль набора записей, `.2` — модуль менеджера, `.5` — справка, `.6` — модуль набора записей (альт.), `.7` — модуль менеджера (альт.)

```xml
<!-- Объект с вложенными реквизитами -->
<Metadata name="AccountingRegister.Хозрасчетный" id="7b248429-..." configVersion="eda4...">
  <Metadata name="AccountingRegister.Хозрасчетный.Attribute.Содержание" id="17c87c43-..."/>
  <Metadata name="AccountingRegister.Хозрасчетный.Resource.Сумма" id="3656a8da-..."/>
  <Metadata name="AccountingRegister.Хозрасчетный.Dimension.Организация" id="4d42e16e-..."/>
</Metadata>
<!-- Форма — отдельная запись -->
<Metadata name="AccountingRegister.Хозрасчетный.Form.ФормаСписка" id="5a682c7f-..." configVersion="1362..."/>
<Metadata name="AccountingRegister.Хозрасчетный.Form.ФормаСписка.Form" id="5a682c7f-....0" configVersion="e384..."/>
<!-- Модули — отдельные записи -->
<Metadata name="AccountingRegister.Хозрасчетный.ManagerModule" id="7b248429-....7" configVersion="0387..."/>
```

---

## 4. Ext/ — корневой каталог конфигурации

Каталог `Ext/` содержит файлы, относящиеся к конфигурации в целом (не к отдельным объектам).

### 4.1. Модули (BSL)

| Файл | Описание |
|------|----------|
| `ManagedApplicationModule.bsl` | Модуль управляемого приложения |
| `OrdinaryApplicationModule.bsl` | Модуль обычного приложения |
| `SessionModule.bsl` | Модуль сеанса |
| `ExternalConnectionModule.bsl` | Модуль внешнего соединения |

Все модули — текстовые файлы в кодировке UTF-8 с BOM, содержащие код на языке 1С (BSL).

### 4.2. Командный интерфейс

| Файл | Описание |
|------|----------|
| `CommandInterface.xml` | Корневой командный интерфейс (порядок подсистем, видимость) |
| `MainSectionCommandInterface.xml` | Командный интерфейс главного раздела |
| `ClientApplicationInterface.xml` | Интерфейс клиентского приложения (расположение панелей) |

**CommandInterface.xml** — описывает порядок подсистем и видимость команд для главного окна:

```xml
<CommandInterface xmlns="http://v8.1c.ru/8.3/xcf/extrnprops" ... version="2.17">
  <SubsystemsOrder>
    <Subsystem>Subsystem.Руководителю</Subsystem>
    <Subsystem>Subsystem.БанкИКасса</Subsystem>
    ...
  </SubsystemsOrder>
</CommandInterface>
```

Подробнее: [1c-subsystem-spec.md § 4](1c-subsystem-spec.md#4-формат-командного-интерфейса-commandinterfacexml).

**ClientApplicationInterface.xml** — расположение панелей рабочего пространства Taxi.

Структура: четыре стороны (`top`, `left`, `right`, `bottom`), внутри каждой произвольная комбинация `<panel>` и `<group>`. Список объявленных панелей — `<panelDef>` на верхнем уровне.

```xml
<ClientApplicationInterface xmlns="http://v8.1c.ru/8.2/managed-application/core" ... xsi:type="InterfaceLayouter">
  <top>
    <panel id="<arbitrary-uuid>"><uuid>cbab57f2-a0f3-4f0a-89ea-4cb19570ab75</uuid></panel>
  </top>
  <left>
    <panel id="<arbitrary-uuid>"><uuid>b553047f-c9aa-4157-978d-448ecad24248</uuid></panel>
  </left>
  <right>
    <group id="<arbitrary-uuid>">
      <group><panel id="..."><uuid>13322b22-...</uuid></panel></group>
      <group><panel id="..."><uuid>c933ac92-...</uuid></panel></group>
    </group>
  </right>
  <panelDef id="b553047f-c9aa-4157-978d-448ecad24248"/>
  <panelDef id="cbab57f2-a0f3-4f0a-89ea-4cb19570ab75"/>
  <panelDef id="13322b22-3960-4d68-93a6-fe2dd7f28ca3"/>
  <panelDef id="c933ac92-92cd-459d-81cc-e0c8a83ced99"/>
  <panelDef id="b2735bd3-d822-4430-ba59-c9e869693b24"/>
</ClientApplicationInterface>
```

**UUID платформенных панелей** (фиксированные константы во всех конфигурациях):

| UUID | Панель |
|------|--------|
| `cbab57f2-a0f3-4f0a-89ea-4cb19570ab75` | Панель открытых |
| `b553047f-c9aa-4157-978d-448ecad24248` | Панель разделов |
| `13322b22-3960-4d68-93a6-fe2dd7f28ca3` | Панель избранного |
| `c933ac92-92cd-459d-81cc-e0c8a83ced99` | Панель истории |
| `b2735bd3-d822-4430-ba59-c9e869693b24` | Панель функций текущего раздела |

**Семантика контейнеров:**
- Несколько прямых child-узлов внутри `<top>`/`<left>`/`<right>`/`<bottom>` располагаются **рядом** друг с другом (отдельные слоты на стороне).
- `<group id="...">` — контейнер-«ячейка»: вложенные `<panel>`/`<group>` располагаются **друг под другом** (стек).
- Атрибут `id` у `<group>` и `<panel>` — произвольный uuid экземпляра (Конфигуратор генерирует свой при сохранении). Привязка к платформенной панели — только через `<uuid>` внутри `<panel>`.
- `<panelDef id="...">` объявляет, что панель доступна пользователю. Если панель не размещена в `top/left/right/bottom`, она остаётся скрытой, но доступна через «Вид → Настройка панелей».

**Дефолтная раскладка** (как в типовых ERP/БП ≥ 8.3.24): «Панель открытых» в `top`, «Панель разделов» в `left`; «Функций», «Избранного», «История» — только в `panelDef`, по умолчанию не размещены.

> Замечание: в типовых конфигурациях встречается также `<panelDef id="8e10648b-...87de33778d95"/>` — наследие от старых версий платформы. В новых конфигурациях с нуля Конфигуратор её не создаёт; не закладывайте на неё логику.

### 4.3. Начальная страница

| Файл | Описание |
|------|----------|
| `HomePageWorkArea.xml` | Рабочая область начальной страницы |

```xml
<HomePageWorkArea xmlns="http://v8.1c.ru/8.3/xcf/extrnprops" ... version="2.17">
  <WorkingAreaTemplate>TwoColumnsVariableWidth</WorkingAreaTemplate>
  <LeftColumn>
    <Item>
      <Form>CommonForm.НачалоРаботы</Form>
      <Height>100</Height>
      <Visibility>
        <xr:Common>true</xr:Common>
        <xr:Value name="Role.ОператорОтправки...">false</xr:Value>
      </Visibility>
    </Item>
    ...
  </LeftColumn>
  <RightColumn>...</RightColumn>
</HomePageWorkArea>
```

Шаблон рабочей области: `TwoColumnsVariableWidth`, `OneColumn` и др.

### 4.4. Картинки

| Файл | Описание |
|------|----------|
| `Splash.xml` + `Splash/Picture.png` | Заставка при запуске |
| `MainSectionPicture.xml` + `MainSectionPicture/Picture.svg` | Картинка главного раздела |

Формат XML-описания картинки:

```xml
<ExtPicture xmlns="http://v8.1c.ru/8.3/xcf/extrnprops" ... version="2.17">
  <Picture>
    <xr:Abs>Picture.png</xr:Abs>
    <xr:LoadTransparent>false</xr:LoadTransparent>
  </Picture>
</ExtPicture>
```

### 4.5. Бинарные файлы

| Файл | Описание |
|------|----------|
| `ParentConfigurations.bin` | Состояние поддержки: конфигурации поставщика + пообъектные правила. Формат: [1c-support-state-spec.md](1c-support-state-spec.md) |
| `MobileClientSignature.bin` | Подпись мобильного клиента |

---

## 5. Языки (Languages)

Языки — простейший тип объекта конфигурации. Каталог `Languages/`, один XML-файл на язык.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" ... version="2.17">
  <Language uuid="db4a9ccb-9ef5-4b3c-8577-b6fe5db1b62e">
    <Properties>
      <Name>Русский</Name>
      <Synonym>
        <v8:item>
          <v8:lang>ru</v8:lang>
          <v8:content>Русский</v8:content>
        </v8:item>
      </Synonym>
      <Comment/>
      <LanguageCode>ru</LanguageCode>
    </Properties>
  </Language>
</MetaDataObject>
```

| Свойство | Описание |
|----------|----------|
| `Name` | Имя (идентификатор) |
| `Synonym` | Отображаемое имя |
| `Comment` | Комментарий |
| `LanguageCode` | Код языка (`ru`, `en`, и т.д.) |

Язык, указанный в `Properties.DefaultLanguage` конфигурации как `Language.Русский`, является основным.

---

## 6. Дополнительные типы объектов

Ниже описаны типы, не покрытые в [1c-config-objects-spec.md](1c-config-objects-spec.md). Все объекты следуют стандартной структуре `MetaDataObject / <Type> / Properties` с обязательными `Name`, `Synonym`, `Comment`.

### 6.1. CommonPicture — общая картинка

Каталог: `CommonPictures/`. Файлы: `<Имя>.xml` + `<Имя>/Ext/Picture/` (файлы картинок).

```xml
<CommonPicture uuid="...">
  <Properties>
    <Name>AppStore</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <AvailabilityForChoice>false</AvailabilityForChoice>
    <AvailabilityForAppearance>false</AvailabilityForAppearance>
  </Properties>
</CommonPicture>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `AvailabilityForChoice` | `xs:boolean` | Доступность для выбора в интерфейсе |
| `AvailabilityForAppearance` | `xs:boolean` | Доступность для оформления |

### 6.2. CommonTemplate — общий макет

Каталог: `CommonTemplates/`. Файлы: `<Имя>.xml` (метаданные) + `<Имя>/Ext/Template.xml` (содержимое).

```xml
<CommonTemplate uuid="...">
  <Properties>
    <Name>fresh</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <TemplateType>BinaryData</TemplateType>
  </Properties>
</CommonTemplate>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `TemplateType` | enum | Тип макета: `SpreadsheetDocument`, `BinaryData`, `HTMLDocument`, `TextDocument`, `ActiveDocument`, `DataCompositionSchema`, `DataCompositionAppearanceTemplate`, `GraphicalSchema`, `AddIn` |

### 6.3. CommonAttribute — общий реквизит

Каталог: `CommonAttributes/`. Один XML-файл на объект.

```xml
<CommonAttribute uuid="...">
  <Properties>
    <Name>КомментарийЯзык1</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Type>
      <v8:Type>xs:string</v8:Type>
      <v8:StringQualifiers>
        <v8:Length>0</v8:Length>
        <v8:AllowedLength>Variable</v8:AllowedLength>
      </v8:StringQualifiers>
    </Type>
    <!-- Свойства аналогичны Attribute объекта: PasswordMode, Format, EditFormat, ... -->
    <AutoUse>DontUse</AutoUse>
    <DataSeparation>DontUse</DataSeparation>
    <SeparatedDataUse>IndependentlyAndSimultaneously</SeparatedDataUse>
    <DataSeparationValue/>
    <DataSeparationUse/>
    <ConditionalSeparation/>
    <UsersSeparation>DontUse</UsersSeparation>
    <AuthenticationSeparation>DontUse</AuthenticationSeparation>
    <ConfigurationExtensionsSeparation>DontUse</ConfigurationExtensionsSeparation>
    <Content>...</Content>
  </Properties>
</CommonAttribute>
```

Специфичные свойства (помимо стандартных реквизитных): `AutoUse`, `DataSeparation`, `SeparatedDataUse`, `DataSeparationValue`, `DataSeparationUse`, `Content` (список объектов, к которым применяется).

### 6.4. CommonForm — общая форма

Каталог: `CommonForms/`. Файлы: `<Имя>.xml` (метаданные) + `<Имя>/Ext/Form.xml` + `<Имя>/Ext/Form/Module.bsl`.

```xml
<CommonForm uuid="...">
  <Properties>
    <Name>АварийныйРежимИСМП</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <FormType>Managed</FormType>
    <IncludeHelpInContents>false</IncludeHelpInContents>
    <UsePurposes>
      <v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
      <v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>
    </UsePurposes>
    <UseStandardCommands>false</UseStandardCommands>
    <ExtendedPresentation/>
    <Explanation/>
  </Properties>
</CommonForm>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `FormType` | enum | `Managed` / `Ordinary` |
| `IncludeHelpInContents` | `xs:boolean` | Включить справку в оглавление |
| `UsePurposes` | list | Назначения |
| `UseStandardCommands` | `xs:boolean` | Использовать стандартные команды |
| `ExtendedPresentation` | `LocalString` | Расширенное представление |
| `Explanation` | `LocalString` | Пояснение |

### 6.5. CommonCommand — общая команда

Каталог: `CommonCommands/`. Файлы: `<Имя>.xml` + `<Имя>/Ext/CommandModule.bsl`.

```xml
<CommonCommand uuid="...">
  <Properties>
    <Name>АвтономнаяРабота</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Group>NavigationPanelOrdinary</Group>
    <Representation>Auto</Representation>
    <ToolTip/>
    <Picture/>
    <Shortcut/>
    <IncludeHelpInContents>false</IncludeHelpInContents>
    <CommandParameterType/>
    <ParameterUseMode>Single</ParameterUseMode>
    <ModifiesData>false</ModifiesData>
    <OnMainServerUnavalableBehavior>Auto</OnMainServerUnavalableBehavior>
  </Properties>
</CommonCommand>
```

Подробнее: [1c-subsystem-spec.md § 6](1c-subsystem-spec.md#6-формат-общей-команды-commoncommand).

### 6.6. SessionParameter — параметр сеанса

Каталог: `SessionParameters/`. Один XML-файл на объект.

```xml
<SessionParameter uuid="...">
  <Properties>
    <Name>АвторизованныйПользователь</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Type>
      <v8:Type>cfg:CatalogRef.ВнешниеПользователи</v8:Type>
      <v8:Type>cfg:CatalogRef.Пользователи</v8:Type>
    </Type>
  </Properties>
</SessionParameter>
```

Единственное специфичное свойство — `Type` (составной тип).

### 6.7. FunctionalOption — функциональная опция

Каталог: `FunctionalOptions/`. Один XML-файл на объект.

```xml
<FunctionalOption uuid="...">
  <Properties>
    <Name>АвансыВключаютсяВДоходыВПериодеПолучения</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Location>InformationRegister.НастройкиУчетаНДФЛ.Resource.АвансыВключаютсяВДоходыВПериодеПолучения</Location>
    <PrivilegedGetMode>true</PrivilegedGetMode>
    <Content/>
  </Properties>
</FunctionalOption>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Location` | ref | Где хранится значение (ссылка на реквизит/ресурс/константу) |
| `PrivilegedGetMode` | `xs:boolean` | Привилегированный режим получения |
| `Content` | list | Состав (объекты, зависящие от опции) |

### 6.8. FunctionalOptionsParameter — параметр функциональных опций

Каталог: `FunctionalOptionsParameters/`. Один XML-файл.

```xml
<FunctionalOptionsParameter uuid="...">
  <Properties>
    <Name>ДополнительныеОтчетыИОбработкиОбъектНазначения</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Use>
      <xr:Item xsi:type="xr:MDObjectRef">InformationRegister.Назначение...Dimension.ОбъектНазначения</xr:Item>
    </Use>
  </Properties>
</FunctionalOptionsParameter>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Use` | list | Список измерений/реквизитов, используемых как параметр |

### 6.9. Sequence — последовательность документов

Каталог: `Sequences/`. Один XML-файл.

```xml
<Sequence uuid="...">
  <InternalInfo>
    <xr:GeneratedType name="SequenceRecord.ДокументыОрганизаций" category="Record">...</xr:GeneratedType>
    <xr:GeneratedType name="SequenceManager.ДокументыОрганизаций" category="Manager">...</xr:GeneratedType>
    <xr:GeneratedType name="SequenceRecordSet.ДокументыОрганизаций" category="RecordSet">...</xr:GeneratedType>
  </InternalInfo>
  <Properties>
    <Name>ДокументыОрганизаций</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <MoveBoundaryOnPosting>DontMove</MoveBoundaryOnPosting>
    <Documents>
      <xr:Item xsi:type="xr:MDObjectRef">Document.АвансовыйОтчет</xr:Item>
      ...
    </Documents>
  </Properties>
  <ChildObjects>
    <Dimension>Организация</Dimension>
  </ChildObjects>
</Sequence>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `MoveBoundaryOnPosting` | enum | Перемещение границы при проведении: `DontMove` / `Move` |
| `Documents` | list | Список документов, входящих в последовательность |

ChildObjects могут содержать `Dimension` (измерения последовательности).

### 6.10. SettingsStorage — хранилище настроек

Каталог: `SettingsStorages/`. Файлы: `<Имя>.xml` + `<Имя>/` (формы, модули).

```xml
<SettingsStorage uuid="...">
  <InternalInfo>
    <xr:GeneratedType name="SettingsStorageManager.БуферыОбменаНовостей" category="Manager">...</xr:GeneratedType>
  </InternalInfo>
  <Properties>
    <Name>БуферыОбменаНовостей</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <DefaultSaveForm/>
    <DefaultLoadForm/>
    <AuxiliarySaveForm/>
    <AuxiliaryLoadForm/>
  </Properties>
  <ChildObjects>
    <Form>ФормаУправленияБуферамиОбмена</Form>
  </ChildObjects>
</SettingsStorage>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `DefaultSaveForm` | ref | Форма сохранения по умолчанию |
| `DefaultLoadForm` | ref | Форма загрузки по умолчанию |
| `AuxiliarySaveForm` | ref | Вспомогательная форма сохранения |
| `AuxiliaryLoadForm` | ref | Вспомогательная форма загрузки |

ChildObjects: `Form` (формы), `Template` (макеты).

### 6.11. FilterCriterion — критерий отбора

Каталог: `FilterCriteria/`. Один XML-файл.

```xml
<FilterCriterion uuid="...">
  <InternalInfo>
    <xr:GeneratedType name="FilterCriterionManager.ДокументыПоВидуОплаты" category="Manager">...</xr:GeneratedType>
    <xr:GeneratedType name="FilterCriterionList.ДокументыПоВидуОплаты" category="List">...</xr:GeneratedType>
  </InternalInfo>
  <Properties>
    <Name>ДокументыПоВидуОплаты</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Type>
      <v8:Type>cfg:CatalogRef.ВидыОплатОрганизаций</v8:Type>
    </Type>
    <UseStandardCommands>true</UseStandardCommands>
    <Content>
      <xr:Item xsi:type="xr:MDObjectRef">Document.ОплатаПлатежнойКартой.Attribute.ВидОплаты</xr:Item>
      ...
    </Content>
  </Properties>
</FilterCriterion>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Type` | type-def | Тип значения критерия (обычно ссылочный) |
| `UseStandardCommands` | `xs:boolean` | Использовать стандартные команды |
| `Content` | list | Реквизиты объектов, по которым выполняется отбор |

ChildObjects: `Form` (формы), `Command` (команды).

### 6.12. DocumentNumerator — нумератор документов

Каталог: `DocumentNumerators/`. Один XML-файл.

```xml
<DocumentNumerator uuid="...">
  <Properties>
    <Name>ПерсонифицированныйУчет</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <NumberType>String</NumberType>
    <NumberLength>11</NumberLength>
    <NumberAllowedLength>Variable</NumberAllowedLength>
    <NumberPeriodicity>Year</NumberPeriodicity>
    <CheckUnique>true</CheckUnique>
  </Properties>
</DocumentNumerator>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `NumberType` | enum | Тип номера: `String` / `Number` |
| `NumberLength` | `xs:decimal` | Длина номера |
| `NumberAllowedLength` | enum | Допустимая длина: `Variable` / `Fixed` |
| `NumberPeriodicity` | enum | Периодичность: `Nonperiodical` / `Year` / `Quarter` / `Month` / `Day` |
| `CheckUnique` | `xs:boolean` | Контроль уникальности |

### 6.13. IntegrationService — сервис интеграции

Каталог: `IntegrationServices/`. Файлы: `<Имя>.xml` + `<Имя>/Ext/Module.bsl`.

```xml
<IntegrationService uuid="...">
  <InternalInfo>
    <xr:GeneratedType name="IntegrationServiceManager.ОбменСообщениями" category="Manager">...</xr:GeneratedType>
  </InternalInfo>
  <Properties>
    <Name>ОбменСообщениями</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <ExternalIntegrationServiceAddress/>
  </Properties>
  <ChildObjects>
    <IntegrationServiceChannel uuid="...">
      <InternalInfo>...</InternalInfo>
      <Properties>
        <Name>input_from_SM_normal_priority</Name>
        <Synonym/>
        <Comment/>
        <ExternalIntegrationServiceChannelName>e1c::FreshBus::Main::...</ExternalIntegrationServiceChannelName>
        <MessageDirection>Receive</MessageDirection>
        <ReceiveMessageProcessing>ОбработатьСообщениеОбычныйПриоритет</ReceiveMessageProcessing>
        <Transactioned>false</Transactioned>
      </Properties>
    </IntegrationServiceChannel>
  </ChildObjects>
</IntegrationService>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `ExternalIntegrationServiceAddress` | `xs:string` | Адрес внешнего сервиса интеграции |

ChildObjects содержат `IntegrationServiceChannel` (каналы) — inline-определения с uuid, InternalInfo и Properties (Name, ExternalIntegrationServiceChannelName, MessageDirection: `Send`/`Receive`, ReceiveMessageProcessing, Transactioned).

### 6.14. XDTOPackage — XDTO-пакет

Каталог: `XDTOPackages/`. Файлы: `<Имя>.xml` (метаданные) + `<Имя>/Ext/Package.bin` (модель пакета — текстовый XML в UTF-8 с BOM, несмотря на расширение).

```xml
<XDTOPackage uuid="...">
  <Properties>
    <Name>AgentScripts</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Namespace>http://v8.1c.ru/agent/scripts/1.0</Namespace>
  </Properties>
</XDTOPackage>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Namespace` | `xs:string` | URI пространства имён XDTO-пакета |

### 6.15. WSReference — WS-ссылка

Каталог: `WSReferences/`. Файлы: `<Имя>.xml` + `<Имя>/Ext/WSDefinition.wsdl`.

```xml
<WSReference uuid="...">
  <InternalInfo>
    <xr:GeneratedType name="WSReferenceManager.WSСборОтчетностиРосстата" category="Manager">...</xr:GeneratedType>
  </InternalInfo>
  <Properties>
    <Name>WSСборОтчетностиРосстата</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <LocationURL>file://C:/TEMP/ECCOwsdl.xml</LocationURL>
  </Properties>
</WSReference>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `LocationURL` | `xs:string` | URL WSDL-описания сервиса |

### 6.16. StyleItem — элемент стиля

Каталог: `StyleItems/`. Один XML-файл.

```xml
<StyleItem uuid="...">
  <Properties>
    <Name>АктуальнаяПодпискаЦвет</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Type>Color</Type>
    <Value xsi:type="v8ui:Color">#009646</Value>
  </Properties>
</StyleItem>
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Type` | enum | Тип элемента стиля: `Color`, `Font`, `Border` |
| `Value` | varies | Значение: цвет `#RRGGBB`, шрифт (`v8ui:FontInfo`), рамка (`v8ui:BorderInfo`) |

### 6.17. Style — стиль (устаревший)

Каталог: `Styles/`. Файлы: `<Имя>.xml` + `<Имя>/Ext/Style.xml`.

```xml
<Style uuid="...">
  <Properties>
    <Name>Основной</Name>
    <Synonym>...</Synonym>
    <Comment/>
  </Properties>
</Style>
```

Присутствует только в конфигурациях с поддержкой устаревших стилей (ERP). Не имеет специфичных свойств в метаданных; содержимое в `Ext/Style.xml`.

---

## 7. Различия версий формата 2.17 → 2.18 → 2.19 → 2.20 → 2.21

### 7.1. Лестница версий

Версию формата задаёт **платформа, которой выгружают**; от режима совместимости конфигурации она не зависит. Версия меняется **каждым релизом платформы**, промежуточных не пропускается:

| Платформа | Версия формата | Замерено |
|-----------|----------------|----------|
| 8.3.20 | `2.13` | да |
| 8.3.21 | `2.14` | нет |
| 8.3.22 | `2.15` | нет |
| 8.3.23 | `2.16` | да |
| 8.3.24 | `2.17` | да |
| 8.3.25 | `2.18` | да |
| 8.3.26 | `2.19` | да |
| 8.3.27 | `2.20` | да |
| 8.5.1 | `2.21` | да |

«Замерено» = создана пустая ИБ этой платформой и выгружена ею же; результат прочитан из `ConfigDumpInfo.xml` и корня `Configuration.xml`. Строки «нет» — интерполяция по шагу лестницы: платформ 8.3.21 и 8.3.22 в наличии не было. Замеренные крайние точки жёстко ограничивают этот пробел: 2.13 на 8.3.20 и 2.16 на 8.3.23 — ровно +3 версии на 3 релиза.

**Проверенный диапазон навыков — `2.17`–`2.21`.** Ниже 2.17 навыки работать не запрещают, но и не обещают: `*-init` выпустят скаффолд с предупреждением, валидаторы отметят версию как непроверенную. Дельты форматов 2.13–2.16 не изучались.

```xml
<MetaDataObject ... version="2.17">
<MetaDataObject ... version="2.21">
```

### 7.2. Что появилось в каждой версии

| Версия | Изменения |
|--------|-----------|
| `2.18` | `TypeReductionMode` у стандартных реквизитов и измерений регистров сведений; `TextToSpeech` в `UsedMobileApplicationFunctionalities`; три редких свойства форм (`ViewModeApplicationOnSetReportResult`, `ReportResultViewMode`, `UseForFoldersAndItems`) |
| `2.19` | Новых тегов нет. Роли перестали писать право, совпадающее с `setForNewObjects` |
| `2.20` | `LineNumberLength` у табличных частей |
| `2.21` | Пространство имён `xmlns:pal` в шапке; `Color` у значений перечислений; `AuxiliaryVariantForm`; `UseInInterfaceCompatibilityMode`; блок свойств интерфейса 8.5 в `Configuration.xml` (`MainClientApplicationWindowInterfaceVariant`, `ClientApplicationTheme`, `ClientApplicationWindowsOpenVariant`, `Version85InterfaceMigrationMode`, `Caption`/`ShortCaption`, восемь `Auxiliary*Form`) |

Ниже `2.17` дельта снята по пустой конфигурации в двух точках, 2.13 (8.3.20) и 2.16 (8.3.23):

| Переход | Что появилось в `Configuration.xml` |
|---|---|
| `2.13` → `2.16` | `DatabaseTablespacesUseMode`, `DefaultReportAppearanceTemplate` — на какой из ступеней 2.14–2.16, не установлено |
| `2.16` → `2.17` | `AllowedIncomingShareRequestTypes` |

Это свойства корня конфигурации, а не объектов метаданных, поэтому в реестр «тег → минимальная версия» (`meta-validate`, проверка 18) они не идут: он про объекты. Внутри проверенного диапазона `AllowedIncomingShareRequestTypes` существует всегда, так что гейт по версии для него не нужен.

Три свойства форм — не новые возможности, а изменение **дефолта эмиссии**: платформа 8.3.24 их принимает и сохраняет при роундтрипе, просто не пишет сама. `TypeReductionMode`, наоборот, свойство новое — 8.3.24 молча отбраковывает его при загрузке («Свойство не входит в состав объекта метаданных», при этом exit 0).

`TextToSpeech` — третья, самая жёсткая категория: на 8.3.24 его присутствие роняет загрузку («Ошибка XDTO в файле - Configuration.xml, при чтении свойства»), а не отбраковывается молча. Это последняя, 38-я запись `UsedMobileApplicationFunctionalities` (в `2.17` их 37); значение значимое — `true` переживает роундтрип. Пропуск тега на `2.18`+ ошибкой не является, но платформа допишет его со значением `false` и роундтрип разойдётся. Замерено выгрузками пустой ИБ шести платформ и роликами загрузки на 8.3.24/8.3.25.

### 7.3. Configuration.xml — Properties

Набор свойств Properties **идентичен** во всех версиях. `ConfigurationExtensionCompatibilityMode` платформа при выгрузке подставляет **свой собственный** (8.3.25 пишет `Version8_3_25`, 8.3.27 — `Version8_3_27`) даже если конфигурация не менялась, — при диффе двух дампов это выглядит как правка конфигурации, но ею не является.

### 7.4. Configuration.xml — ChildObjects

Порядок типов между версиями не меняется, а вот набор — растёт: `Bot` доступен с платформы 8.3.18,
`PaletteColor` — с 8.5. Версия появления указана в колонке «Описание» таблицы порядка типов.
Конфигурация на более старой платформе просто не содержит таких групп; позиция типа, когда он есть,
одна и та же (замерено: 8.3.27 и 8.5.1 ставят `Bot` сразу за `DefinedType`).

### 7.5. ConfigDumpInfo.xml и Ext/ файлы

В `ConfigDumpInfo.xml`, `CommandInterface.xml`, `HomePageWorkArea.xml` меняется только атрибут `version`. Структура не изменилась.

### 7.6. Форматирование XML

Стиль пустых элементов (`<Comment/>` против `<Comment />`) признаком версии **не является** — он различается и между дампами одной версии формата. Платформа принимает оба варианта; опираться на него нельзя.

---

## 8. Пространства имён XML

Полный набор namespace, используемых в Configuration.xml:

| Префикс | URI | Назначение |
|---------|-----|------------|
| *(default)* | `http://v8.1c.ru/8.3/MDClasses` | Метаданные объектов |
| `v8` | `http://v8.1c.ru/8.1/data/core` | Ядро данных (типы, LocalString) |
| `xr` | `http://v8.1c.ru/8.3/xcf/readable` | Человекочитаемые ссылки |
| `xs` | `http://www.w3.org/2001/XMLSchema` | XML Schema типы |
| `xsi` | `http://www.w3.org/2001/XMLSchema-instance` | Атрибуты xsi:type, xsi:nil |
| `app` | `http://v8.1c.ru/8.2/managed-application/core` | Управляемое приложение |
| `cfg` | `http://v8.1c.ru/8.1/data/enterprise/current-config` | Ссылочные типы конфигурации |
| `v8ui` | `http://v8.1c.ru/8.1/data/ui` | UI-элементы (цвета, шрифты) |
| `style` | `http://v8.1c.ru/8.1/data/ui/style` | Стили |
| `sys` | `http://v8.1c.ru/8.1/data/ui/fonts/system` | Системные шрифты |
| `web` | `http://v8.1c.ru/8.1/data/ui/colors/web` | Web-цвета |
| `win` | `http://v8.1c.ru/8.1/data/ui/colors/windows` | Windows-цвета |
| `xen` | `http://v8.1c.ru/8.3/xcf/enums` | Перечисления формата |
| `xpr` | `http://v8.1c.ru/8.3/xcf/predef` | Предопределённые элементы |
| `ent` | `http://v8.1c.ru/8.1/data/enterprise` | Предприятие |
| `cmi` | `http://v8.1c.ru/8.2/managed-application/cmi` | Командный интерфейс |
| `lf` | `http://v8.1c.ru/8.2/managed-application/logform` | Логические формы |
