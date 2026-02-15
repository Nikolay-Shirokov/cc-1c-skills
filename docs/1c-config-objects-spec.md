# Спецификация формата XML объектов метаданных конфигурации 1С

Формат: XML-выгрузка конфигурации 1С:Предприятие 8.3 (Конфигуратор → Конфигурация → Выгрузить конфигурацию в файлы).
Версии формата: `2.17` (платформа 8.3.20–8.3.24), `2.20` (платформа 8.3.27+).

Источники: выгрузки ERP 2, Бухгалтерия предприятия (платформы 8.3.20, 8.3.24, 8.3.27).

> **Связанные спецификации:**
> - Корневая структура конфигурации — [1c-configuration-spec.md](1c-configuration-spec.md)
> - Подсистемы и командный интерфейс — [1c-subsystem-spec.md](1c-subsystem-spec.md)
> - Сводный индекс — [1c-specs-index.md](1c-specs-index.md)

---

## 1. Общая структура выгрузки

### 1.1. Верхний уровень каталогов

```
Configuration.xml                  # Корневой файл конфигурации
ConfigDumpInfo.xml                 # Служебный файл выгрузки
Catalogs/                          # Справочники
Documents/                         # Документы
InformationRegisters/              # Регистры сведений
AccumulationRegisters/             # Регистры накопления
AccountingRegisters/               # Регистры бухгалтерии
CalculationRegisters/              # Регистры расчёта
ChartsOfAccounts/                  # Планы счетов
ChartsOfCharacteristicTypes/       # Планы видов характеристик
ChartsOfCalculationTypes/          # Планы видов расчёта
BusinessProcesses/                 # Бизнес-процессы
Tasks/                             # Задачи
ExchangePlans/                     # Планы обмена
DocumentJournals/                  # Журналы документов
Enums/                             # Перечисления
Reports/                           # Отчёты
DataProcessors/                    # Обработки
Constants/                         # Константы
CommonModules/                     # Общие модули
CommonAttributes/                  # Общие реквизиты
CommonCommands/                    # Общие команды
CommonForms/                       # Общие формы
CommonPictures/                    # Общие картинки
CommonTemplates/                   # Общие макеты
CommandGroups/                     # Группы команд
DefinedTypes/                      # Определяемые типы
DocumentNumerators/                # Нумераторы документов
EventSubscriptions/                # Подписки на события
FilterCriteria/                    # Критерии отбора
FunctionalOptions/                 # Функциональные опции
FunctionalOptionsParameters/       # Параметры функциональных опций
HTTPServices/                      # HTTP-сервисы
Languages/                         # Языки
Roles/                             # Роли
ScheduledJobs/                     # Регламентные задания
SessionParameters/                 # Параметры сеанса
SettingsStorages/                  # Хранилища настроек
StyleItems/                        # Элементы стиля
Styles/                            # Стили
Subsystems/                        # Подсистемы
WebServices/                       # Web-сервисы
WSReferences/                      # WS-ссылки
XDTOPackages/                      # XDTO-пакеты
Ext/                               # Расширение конфигурации
```

### 1.2. Структура каталога объекта метаданных

Каждый объект метаданных (справочник, документ и т.д.) хранится в каталоге с именем объекта:

```
<ИмяОбъекта>/
├── <ИмяОбъекта>.xml          # Корневой XML — определение объекта
├── Ext/
│   ├── ObjectModule.bsl      # Модуль объекта (опционально)
│   ├── ManagerModule.bsl     # Модуль менеджера (опционально)
│   ├── RecordSetModule.bsl   # Модуль набора записей — для регистров (опционально)
│   ├── Predefined.xml        # Предопределённые элементы (опционально)
│   ├── Help.xml              # Метаданные справки (опционально)
│   ├── Help/
│   │   └── ru.html           # HTML-страница справки
│   ├── Flowchart.xml         # Карта маршрута — только для бизнес-процессов
│   └── Content.xml           # Состав плана обмена — только для планов обмена
├── Forms/
│   ├── <ИмяФормы>/
│   │   ├── <ИмяФормы>.xml    # Метаданные формы
│   │   └── Ext/
│   │       ├── Form.xml      # Описание формы
│   │       ├── Form/
│   │       │   └── Module.bsl  # Модуль формы
│   │       └── Help.xml      # Справка формы (опционально)
│   └── ...
├── Templates/
│   ├── <ИмяМакета>/
│   │   ├── <ИмяМакета>.xml   # Метаданные макета
│   │   └── Ext/
│   │       └── Template.xml  # Тело макета (MXL, СКД и др.)
│   └── ...
└── Commands/                  # Команды (если определены отдельными файлами)
```

**Модули по типам объектов:**

| Тип объекта | ObjectModule | ManagerModule | RecordSetModule | CommandModule |
|---|---|---|---|---|
| Справочник | + | + | - | + |
| Документ | + | + | - | + |
| Регистры сведений | - | + | + | - |
| Регистры накопления | - | + | + | - |
| Регистры бухгалтерии | - | + | + | - |
| Регистры расчёта | - | + | + | - |
| ПланСчетов | + | + | - | + |
| ПВХ | + | + | - | + |
| ПВР | + | + | - | + |
| БизнесПроцесс | + | + | - | + |
| Задача | + | + | - | + |
| ПланОбмена | + | + | - | + |
| Перечисление | - | + | - | - |
| Отчёт | + | + | - | + |
| Обработка | + | + | - | + |
| Константа | - | + | - | - |

---

## 2. Общий формат XML

### 2.1. Корневой элемент

Все файлы метаданных объектов используют корневой элемент `<MetaDataObject>`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"
    xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
    xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"
    xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi"
    xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"
    xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"
    xmlns:style="http://v8.1c.ru/8.1/data/ui/style"
    xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"
    xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"
    xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"
    xmlns:xen="http://v8.3/xcf/enums"
    xmlns:xpr="http://v8.3/xcf/predef"
    xmlns:xr="http://v8.3/xcf/readable"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    version="2.17">

    <Catalog uuid="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx">
        <InternalInfo> ... </InternalInfo>
        <Properties> ... </Properties>
        <ChildObjects> ... </ChildObjects>
    </Catalog>

</MetaDataObject>
```

### 2.2. Пространства имён

| Префикс | URI | Назначение |
|---|---|---|
| *(default)* | `http://v8.1c.ru/8.3/MDClasses` | Основное пространство классов метаданных |
| `v8` | `http://v8.1c.ru/8.1/data/core` | Базовые типы данных (Type, item, lang, content) |
| `cfg` | `http://v8.1c.ru/8.1/data/enterprise/current-config` | Ссылки на объекты текущей конфигурации |
| `xr` | `http://v8.3/xcf/readable` | Человекочитаемый формат (GeneratedType, StandardAttribute) |
| `xsi` | `http://www.w3.org/2001/XMLSchema-instance` | Типы атрибутов (`xsi:type`, `xsi:nil`) |
| `xs` | `http://www.w3.org/2001/XMLSchema` | Типы XML Schema (`xs:string`, `xs:boolean`, ...) |
| `app` | `http://v8.1c.ru/8.2/managed-application/core` | Ядро управляемого приложения (ChoiceParameters) |
| `xen` | `http://v8.3/xcf/enums` | Перечисления формата |
| `xpr` | `http://v8.3/xcf/predef` | Предопределённые типы |

### 2.3. Элемент типа объекта

Внутри `<MetaDataObject>` содержится единственный дочерний элемент, имя которого соответствует типу объекта:

| Тип метаданных | XML-элемент |
|---|---|
| Справочник | `<Catalog>` |
| Документ | `<Document>` |
| Перечисление | `<Enum>` |
| Константа | `<Constant>` |
| Регистр сведений | `<InformationRegister>` |
| Регистр накопления | `<AccumulationRegister>` |
| Регистр бухгалтерии | `<AccountingRegister>` |
| Регистр расчёта | `<CalculationRegister>` |
| План счетов | `<ChartOfAccounts>` |
| План видов характеристик | `<ChartOfCharacteristicTypes>` |
| План видов расчёта | `<ChartOfCalculationTypes>` |
| Бизнес-процесс | `<BusinessProcess>` |
| Задача | `<Task>` |
| План обмена | `<ExchangePlan>` |
| Журнал документов | `<DocumentJournal>` |
| Отчёт | `<Report>` |
| Обработка | `<DataProcessor>` |
| Определяемый тип | `<DefinedType>` |
| Общий модуль | `<CommonModule>` |
| Регламентное задание | `<ScheduledJob>` |
| Подписка на событие | `<EventSubscription>` |
| HTTP-сервис | `<HTTPService>` |
| Веб-сервис | `<WebService>` |

Атрибут `uuid` — уникальный идентификатор объекта.

### 2.4. Три секции объекта

Каждый объект метаданных содержит три секции:

```xml
<[ТипОбъекта] uuid="...">
    <InternalInfo>      <!-- Внутренняя информация: генерируемые типы -->
    <Properties>        <!-- Свойства: имя, синоним, настройки, стандартные реквизиты -->
    <ChildObjects>      <!-- Дочерние объекты: реквизиты, ТЧ, формы, макеты, команды -->
</[ТипОбъекта]>
```

---

## 3. InternalInfo — внутренняя информация

Секция содержит определения типов, генерируемых платформой для работы с объектом.

### 3.1. GeneratedType

```xml
<InternalInfo>
    <xr:GeneratedType name="CatalogObject.Номенклатура" category="Object">
        <xr:TypeId>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</xr:TypeId>
        <xr:ValueId>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</xr:ValueId>
    </xr:GeneratedType>
    <xr:GeneratedType name="CatalogRef.Номенклатура" category="Ref">
        <xr:TypeId>...</xr:TypeId>
        <xr:ValueId>...</xr:ValueId>
    </xr:GeneratedType>
    <!-- ... другие категории ... -->
</InternalInfo>
```

**Категории генерируемых типов по видам объектов:**

| Вид объекта | Категории (category) |
|---|---|
| Catalog | Object, Ref, Selection, List, Manager |
| Document | Object, Ref, Selection, List, Manager |
| Enum | Ref, Manager, List |
| Constant | Manager, ValueManager, ValueKey |
| InformationRegister | Record, Manager, Selection, List, RecordSet, RecordKey, RecordManager |
| AccumulationRegister | Record, Manager, Selection, List, RecordSet, RecordKey |
| AccountingRegister | Record, Manager, Selection, List, RecordSet, RecordKey |
| CalculationRegister | Record, Manager, Selection, List, RecordSet, RecordKey + Recalcs |
| ChartOfAccounts | Object, Ref, Selection, List, Manager |
| ChartOfCharacteristicTypes | Object, Ref, Selection, List, Manager |
| ChartOfCalculationTypes | Object, Ref, Selection, List, Manager + Displacing, Base, Leading |
| BusinessProcess | Object, Ref, Selection, List, Manager |
| Task | Object, Ref, Selection, List, Manager |
| ExchangePlan | Object, Ref, Selection, List, Manager |
| DocumentJournal | Selection, List, Manager |
| Report | Object |
| DataProcessor | Object |

Формат имени: `{ТипОбъектаEng}.{ИмяОбъекта}` (напр. `CatalogObject.Номенклатура`, `DocumentRef.АвансовыйОтчет`).

### 3.2. ThisNode (только ExchangePlan)

```xml
<InternalInfo>
    <xr:ThisNode>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</xr:ThisNode>
    ...
</InternalInfo>
```

---

## 4. Общие элементы Properties

### 4.1. Базовые свойства (есть у всех объектов)

```xml
<Properties>
    <Name>ИмяОбъекта</Name>
    <Synonym>
        <v8:item>
            <v8:lang>ru</v8:lang>
            <v8:content>Отображаемое имя</v8:content>
        </v8:item>
        <v8:item>
            <v8:lang>en</v8:lang>
            <v8:content>Display name</v8:content>
        </v8:item>
    </Synonym>
    <Comment>Комментарий разработчика</Comment>
</Properties>
```

- **Name** — системное имя (идентификатор, без пробелов и спецсимволов)
- **Synonym** — локализованное отображаемое имя (структура `v8:item`)
- **Comment** — комментарий (может быть пустым элементом `<Comment/>`)

### 4.2. Многоязычный текст (v8:item)

Используется для Synonym, ToolTip, ObjectPresentation, ListPresentation и других текстовых свойств:

```xml
<Synonym>
    <v8:item>
        <v8:lang>ru</v8:lang>
        <v8:content>Текст на русском</v8:content>
    </v8:item>
    <v8:item>
        <v8:lang>en</v8:lang>
        <v8:content>English text</v8:content>
    </v8:item>
</Synonym>
```

### 4.3. Определение типа (Type)

Тип реквизита задаётся элементом `<Type>`, содержащим один или несколько `<v8:Type>`:

**Примитивные типы:**
```xml
<!-- Строка -->
<Type>
    <v8:Type>xs:string</v8:Type>
    <v8:StringQualifiers>
        <v8:Length>100</v8:Length>                         <!-- 0 = неограниченная -->
        <v8:AllowedLength>Variable</v8:AllowedLength>     <!-- Variable | Fixed -->
    </v8:StringQualifiers>
</Type>

<!-- Число -->
<Type>
    <v8:Type>xs:decimal</v8:Type>
    <v8:NumberQualifiers>
        <v8:Digits>15</v8:Digits>                         <!-- Всего знаков -->
        <v8:FractionDigits>2</v8:FractionDigits>          <!-- Дробная часть -->
        <v8:AllowedSign>Any</v8:AllowedSign>               <!-- Any | Nonnegative -->
    </v8:NumberQualifiers>
</Type>

<!-- Булево -->
<Type>
    <v8:Type>xs:boolean</v8:Type>
</Type>

<!-- Дата -->
<Type>
    <v8:Type>xs:dateTime</v8:Type>
    <v8:DateQualifiers>
        <v8:DateFractions>DateTime</v8:DateFractions>     <!-- Date | Time | DateTime -->
    </v8:DateQualifiers>
</Type>
```

**Ссылочные типы:**
```xml
<!-- Ссылка на справочник -->
<Type><v8:Type>cfg:CatalogRef.Номенклатура</v8:Type></Type>

<!-- Ссылка на документ -->
<Type><v8:Type>cfg:DocumentRef.РеализацияТоваровУслуг</v8:Type></Type>

<!-- Ссылка на перечисление -->
<Type><v8:Type>cfg:EnumRef.ВидыОпераций</v8:Type></Type>

<!-- Ссылка на план счетов -->
<Type><v8:Type>cfg:ChartOfAccountsRef.Хозрасчетный</v8:Type></Type>

<!-- Ссылка на ПВХ -->
<Type><v8:Type>cfg:ChartOfCharacteristicTypesRef.ВидыСубконто</v8:Type></Type>

<!-- Ссылка на ПВР -->
<Type><v8:Type>cfg:ChartOfCalculationTypesRef.Начисления</v8:Type></Type>

<!-- Ссылка на план обмена -->
<Type><v8:Type>cfg:ExchangePlanRef.ОбменССайтом</v8:Type></Type>

<!-- Ссылка на бизнес-процесс -->
<Type><v8:Type>cfg:BusinessProcessRef.Задание</v8:Type></Type>

<!-- Ссылка на задачу -->
<Type><v8:Type>cfg:TaskRef.ЗадачаИсполнителя</v8:Type></Type>
```

**Специальные типы:**
```xml
<!-- Хранилище значения (произвольные данные) -->
<Type><v8:Type>v8:ValueStorage</v8:Type></Type>

<!-- Уникальный идентификатор -->
<Type><v8:Type>v8:UUID</v8:Type></Type>
```

**Составной тип (несколько типов):**
```xml
<Type>
    <v8:Type>cfg:CatalogRef.Контрагенты</v8:Type>
    <v8:Type>cfg:CatalogRef.ФизическиеЛица</v8:Type>
    <v8:Type>xs:string</v8:Type>
    <v8:StringQualifiers>
        <v8:Length>100</v8:Length>
        <v8:AllowedLength>Variable</v8:AllowedLength>
    </v8:StringQualifiers>
</Type>
```

**Определяемый тип (DefinedType):**
```xml
<Type>
    <v8:TypeSet>cfg:DefinedType.Цена</v8:TypeSet>
</Type>
```

### 4.4. Свойства представления

```xml
<ObjectPresentation>                <!-- Единственное число: "Контрагент" -->
    <v8:item><v8:lang>ru</v8:lang><v8:content>...</v8:content></v8:item>
</ObjectPresentation>
<ExtendedObjectPresentation>...</ExtendedObjectPresentation>   <!-- Расширенное -->
<ListPresentation>...</ListPresentation>                       <!-- Множественное: "Контрагенты" -->
<ExtendedListPresentation>...</ExtendedListPresentation>       <!-- Расширенное множ. -->
<Explanation>...</Explanation>                                  <!-- Пояснение -->
```

### 4.5. Свойства поведения

```xml
<UseStandardCommands>true</UseStandardCommands>     <!-- Стандартные команды -->
<IncludeHelpInContents>true</IncludeHelpInContents> <!-- В оглавлении справки -->
<FullTextSearch>Use</FullTextSearch>                 <!-- Use | DontUse -->
<DataLockControlMode>Managed</DataLockControlMode>  <!-- Managed | Automatic -->
<DataHistory>Use</DataHistory>                       <!-- Use | DontUse -->
<UpdateDataHistoryImmediatelyAfterWrite>true</UpdateDataHistoryImmediatelyAfterWrite>
<ExecuteAfterWriteDataHistoryVersionProcessing>true</ExecuteAfterWriteDataHistoryVersionProcessing>
```

### 4.6. Свойства форм

```xml
<DefaultObjectForm>Catalog.Номенклатура.Form.ФормаЭлемента</DefaultObjectForm>
<DefaultFolderForm>Catalog.Номенклатура.Form.ФормаГруппы</DefaultFolderForm>
<DefaultListForm>Catalog.Номенклатура.Form.ФормаСписка</DefaultListForm>
<DefaultChoiceForm>Catalog.Номенклатура.Form.ФормаВыбора</DefaultChoiceForm>
<DefaultFolderChoiceForm>...</DefaultFolderChoiceForm>
<AuxiliaryObjectForm>...</AuxiliaryObjectForm>
<AuxiliaryFolderForm>...</AuxiliaryFolderForm>
<AuxiliaryListForm>...</AuxiliaryListForm>
<AuxiliaryChoiceForm>...</AuxiliaryChoiceForm>
<AuxiliaryFolderChoiceForm>...</AuxiliaryFolderChoiceForm>
```

### 4.7. Свойства поиска при вводе

```xml
<InputByString>
    <xr:Field>Catalog.Номенклатура.StandardAttribute.Description</xr:Field>
    <xr:Field>Catalog.Номенклатура.StandardAttribute.Code</xr:Field>
</InputByString>
<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>  <!-- Begin | Anywhere -->
<FullTextSearchOnInputByString>Use</FullTextSearchOnInputByString>
<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString> <!-- Directly | SlowlyObtainedSet -->
<CreateOnInput>DontUse</CreateOnInput>                  <!-- Use | DontUse -->
<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>        <!-- Auto | Use | DontUse -->
```

### 4.8. Свойства блокировки данных

```xml
<DataLockFields>
    <xr:Field>Document.АвансовыйОтчет.Attribute.Организация</xr:Field>
</DataLockFields>
<DataLockControlMode>Managed</DataLockControlMode>  <!-- Managed | Automatic -->
```

### 4.9. Ввод на основании (BasedOn)

```xml
<BasedOn>
    <xr:Item xsi:type="xr:MDObjectRef">Document.РасходныйКассовыйОрдер</xr:Item>
    <xr:Item xsi:type="xr:MDObjectRef">Document.СписаниеБезналичныхДС</xr:Item>
</BasedOn>
```

### 4.10. Характеристики (Characteristics)

Механизм динамических свойств — позволяет расширять состав реквизитов объекта в режиме 1С:Предприятие:

```xml
<Characteristics>
    <xr:Characteristic>
        <xr:CharacteristicTypes from="Catalog.НаборыДополнительныхРеквизитовИСведений.TabularSection.ДополнительныеРеквизиты.Attribute.ДополнительныйРеквизит">
            <xr:KeyField>InformationRegister.ДополнительныеСведения.Dimension.Свойство</xr:KeyField>
            <xr:TypesFilterField>Catalog.НаборыДополнительныхРеквизитовИСведений.TabularSection.ДополнительныеРеквизиты.Attribute.ДополнительныйРеквизит</xr:TypesFilterField>
            <xr:TypesFilterValue xsi:type="xs:string">Документ_АвансовыйОтчет</xr:TypesFilterValue>
            <xr:DataPathField>-1</xr:DataPathField>
            <xr:MultipleValuesUseField>-1</xr:MultipleValuesUseField>
        </xr:CharacteristicTypes>
        <xr:CharacteristicValues from="InformationRegister.ДополнительныеСведения">
            <xr:ObjectField>InformationRegister.ДополнительныеСведения.Dimension.Объект</xr:ObjectField>
            <xr:TypeField>InformationRegister.ДополнительныеСведения.Dimension.Свойство</xr:TypeField>
            <xr:ValueField>InformationRegister.ДополнительныеСведения.Resource.Значение</xr:ValueField>
            <xr:MultipleValuesKeyField>-1</xr:MultipleValuesKeyField>
            <xr:MultipleValuesOrderField>-1</xr:MultipleValuesOrderField>
        </xr:CharacteristicValues>
    </xr:Characteristic>
</Characteristics>
```

---

## 5. Стандартные реквизиты (StandardAttributes)

Каждый объект имеет набор предопределённых стандартных реквизитов, задаваемых в секции `<StandardAttributes>` внутри `<Properties>`.

### 5.1. Формат стандартного реквизита

```xml
<StandardAttributes>
    <xr:StandardAttribute name="Description">
        <xr:LinkByType/>
        <xr:FillChecking>ShowError</xr:FillChecking>
        <xr:MultiLine>false</xr:MultiLine>
        <xr:FillFromFillingValue>true</xr:FillFromFillingValue>
        <xr:CreateOnInput>Auto</xr:CreateOnInput>
        <xr:MaxValue xsi:nil="true"/>
        <xr:ToolTip>
            <v8:item><v8:lang>ru</v8:lang><v8:content>Подсказка</v8:content></v8:item>
        </xr:ToolTip>
        <xr:ExtendedEdit>false</xr:ExtendedEdit>
        <xr:Format/>
        <xr:ChoiceForm/>
        <xr:QuickChoice>Auto</xr:QuickChoice>
        <xr:ChoiceHistoryOnInput>Auto</xr:ChoiceHistoryOnInput>
        <xr:EditFormat/>
        <xr:PasswordMode>false</xr:PasswordMode>
        <xr:DataHistory>Use</xr:DataHistory>
        <xr:MarkNegatives>false</xr:MarkNegatives>
        <xr:MinValue xsi:nil="true"/>
        <xr:Synonym>
            <v8:item><v8:lang>ru</v8:lang><v8:content>Наименование</v8:content></v8:item>
        </xr:Synonym>
        <xr:Comment/>
        <xr:FullTextSearch>Use</xr:FullTextSearch>
        <xr:ChoiceParameterLinks/>
        <xr:FillValue xsi:type="xs:string"></xr:FillValue>
        <xr:Mask/>
        <xr:ChoiceParameters/>
    </xr:StandardAttribute>
</StandardAttributes>
```

### 5.2. Свойства стандартного реквизита

| Свойство | Тип | Описание |
|---|---|---|
| `name` | атрибут | Имя стандартного реквизита |
| `LinkByType` | элемент | Связь по типу (обычно пустой) |
| `FillChecking` | enum | `DontCheck` \| `ShowWarning` \| `ShowError` |
| `MultiLine` | boolean | Многострочное поле |
| `FillFromFillingValue` | boolean | Заполнять из значения заполнения |
| `CreateOnInput` | enum | `Auto` \| `Use` \| `DontUse` |
| `MaxValue` | any | Макс. значение (`xsi:nil="true"` если не задано) |
| `MinValue` | any | Мин. значение |
| `ToolTip` | v8:item | Подсказка |
| `ExtendedEdit` | boolean | Расширенное редактирование |
| `Format` | v8:item | Формат отображения |
| `EditFormat` | v8:item | Формат редактирования |
| `ChoiceForm` | string | Форма выбора |
| `QuickChoice` | enum | `Auto` \| `Use` \| `DontUse` |
| `ChoiceHistoryOnInput` | enum | `Auto` \| `Use` \| `DontUse` |
| `PasswordMode` | boolean | Режим пароля |
| `DataHistory` | enum | `Use` \| `DontUse` |
| `MarkNegatives` | boolean | Выделять отрицательные |
| `Synonym` | v8:item | Переопределённый синоним |
| `Comment` | string | Комментарий |
| `FullTextSearch` | enum | `Use` \| `DontUse` |
| `ChoiceParameterLinks` | сложный | Связи параметров выбора |
| `FillValue` | typed | Значение заполнения |
| `Mask` | string | Маска ввода |
| `ChoiceParameters` | сложный | Параметры выбора |

### 5.3. Стандартные реквизиты по видам объектов

| Стандартный реквизит | Catalog | Document | Enum | ChartOfAccounts | ChartOfCharacteristicTypes | ExchangePlan | BusinessProcess | Task |
|---|---|---|---|---|---|---|---|---|
| Ref | + | + | + | + | + | + | + | + |
| DeletionMark | + | + | - | + | + | + | + | + |
| PredefinedDataName | + | - | - | + | + | - | - | - |
| Predefined | + | - | - | + | + | - | - | - |
| Code | + | - | - | + | + | + | - | - |
| Description | + | - | - | + | + | + | - | + |
| IsFolder | +* | - | - | - | - | - | - | - |
| Owner | +** | - | - | - | - | - | - | - |
| Parent | +* | - | - | + | +* | - | - | - |
| Date | - | + | - | - | - | - | + | + |
| Number | - | + | - | - | - | - | + | + |
| Posted | - | + | - | - | - | - | - | - |
| Order | - | - | + | + | - | - | - | - |
| ValueType | - | - | - | - | + | - | - | - |
| Type (тип счёта) | - | - | - | + | - | - | - | - |
| OffBalance | - | - | - | + | - | - | - | - |
| ThisNode | - | - | - | - | - | + | - | - |
| SentNo | - | - | - | - | - | + | - | - |
| ReceivedNo | - | - | - | - | - | + | - | - |
| Started | - | - | - | - | - | - | + | - |
| Completed | - | - | - | - | - | - | + | - |
| HeadTask | - | - | - | - | - | - | + | - |
| Executed | - | - | - | - | - | - | - | + |
| RoutePoint | - | - | - | - | - | - | - | + |
| BusinessProcess | - | - | - | - | - | - | - | + |

`*` — если Hierarchical=true. `**` — если задан Owners.

**Стандартные реквизиты регистров:**

| Стандартный реквизит | InformationRegister | AccumulationRegister | AccountingRegister | CalculationRegister |
|---|---|---|---|---|
| Active | + | + | + | + |
| Period | + | + | + | - |
| Recorder | +* | + | + | + |
| LineNumber | +* | + | + | + |
| Account | - | - | + | - |
| ExtDimension1..3 | - | - | + | - |
| ExtDimensionType1..3 | - | - | + | - |
| RegistrationPeriod | - | - | - | + |
| CalculationType | - | - | - | + |
| ActionPeriod | - | - | - | +** |
| BegOfActionPeriod | - | - | - | +** |
| EndOfActionPeriod | - | - | - | +** |
| BegOfBasePeriod | - | - | - | +*** |
| EndOfBasePeriod | - | - | - | +*** |
| ReversingEntry | - | - | - | + |

`*` — если WriteMode = RecorderSubordinate. `**` — если ActionPeriod = true. `***` — если BasePeriod = true.

### 5.4. LinkByType (связь по типу)

Используется в регистрах бухгалтерии для привязки субконто к счёту:

```xml
<xr:LinkByType>
    <xr:DataPath>AccountingRegister.Хозрасчетный.StandardAttribute.Account</xr:DataPath>
    <xr:LinkItem>1</xr:LinkItem>   <!-- Номер субконто: 1, 2 или 3 -->
</xr:LinkByType>
```

### 5.5. FillValue — значение заполнения

```xml
<!-- Пустое значение -->
<xr:FillValue xsi:nil="true"/>

<!-- Литеральные значения -->
<xr:FillValue xsi:type="xs:string">Текст</xr:FillValue>
<xr:FillValue xsi:type="xs:boolean">false</xr:FillValue>
<xr:FillValue xsi:type="xs:decimal">0</xr:FillValue>
<xr:FillValue xsi:type="xs:dateTime">0001-01-01T00:00:00</xr:FillValue>

<!-- Ссылка на объект конфигурации (design-time) -->
<xr:FillValue xsi:type="xr:DesignTimeRef">Catalog.Номенклатура.EmptyRef</xr:FillValue>
<xr:FillValue xsi:type="xr:DesignTimeRef">Enum.ВидыОпераций.EnumValue.Продажа</xr:FillValue>
```

---

## 6. Дочерние объекты (ChildObjects)

### 6.1. Реквизит (Attribute)

```xml
<Attribute uuid="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx">
    <Properties>
        <Name>Организация</Name>
        <Synonym>
            <v8:item><v8:lang>ru</v8:lang><v8:content>Организация</v8:content></v8:item>
        </Synonym>
        <Comment/>
        <Type>
            <v8:Type>cfg:CatalogRef.Организации</v8:Type>
        </Type>
        <PasswordMode>false</PasswordMode>
        <Format/>
        <EditFormat/>
        <ToolTip/>
        <MarkNegatives>false</MarkNegatives>
        <Mask/>
        <MultiLine>false</MultiLine>
        <ExtendedEdit>false</ExtendedEdit>
        <MinValue xsi:nil="true"/>
        <MaxValue xsi:nil="true"/>
        <FillFromFillingValue>true</FillFromFillingValue>
        <FillValue xsi:nil="true"/>
        <FillChecking>DontCheck</FillChecking>
        <ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>
        <ChoiceParameterLinks/>
        <ChoiceParameters/>
        <QuickChoice>Auto</QuickChoice>
        <CreateOnInput>Auto</CreateOnInput>
        <ChoiceForm/>
        <LinkByType/>
        <ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
        <Indexing>DontIndex</Indexing>
        <FullTextSearch>Use</FullTextSearch>
        <DataHistory>Use</DataHistory>
        <Use>ForItem</Use>               <!-- Только для справочников с иерархией -->
    </Properties>
</Attribute>
```

**Специфичные свойства реквизита:**

| Свойство | Тип | Описание |
|---|---|---|
| `Indexing` | enum | `DontIndex` \| `Index` \| `IndexWithAdditionalOrder` |
| `ChoiceFoldersAndItems` | enum | `Items` \| `Folders` \| `FoldersAndItems` |
| `Use` | enum | `ForItem` \| `ForFolder` \| `ForFolderAndItem` (только для справочников) |
| `FillFromFillingValue` | boolean | Заполнять из значения по умолчанию |

> **Различие хранимых и нехранимых объектов**: Свойства `Indexing`, `FullTextSearch`, `DataHistory`, `FillFromFillingValue`, `FillValue` присутствуют только у **хранимых** объектов (Catalog, Document, ExchangePlan, ChartOf*, BusinessProcess, Task). У объектов DataProcessor и Report (как в конфигурации, так и внешних EPF/ERF) эти свойства **отсутствуют**. Свойство `Use` есть только у справочников (Catalog).

### 6.2. Табличная часть (TabularSection)

```xml
<TabularSection uuid="...">
    <InternalInfo>
        <xr:GeneratedType name="CatalogTabularSection.Номенклатура.Штрихкоды" category="TabularSection">
            <xr:TypeId>...</xr:TypeId>
            <xr:ValueId>...</xr:ValueId>
        </xr:GeneratedType>
        <xr:GeneratedType name="CatalogTabularSectionRow.Номенклатура.Штрихкоды" category="TabularSectionRow">
            <xr:TypeId>...</xr:TypeId>
            <xr:ValueId>...</xr:ValueId>
        </xr:GeneratedType>
    </InternalInfo>
    <Properties>
        <Name>Штрихкоды</Name>
        <Synonym>...</Synonym>
        <Comment/>
        <ToolTip/>
        <FillChecking>DontCheck</FillChecking>
        <StandardAttributes>
            <xr:StandardAttribute name="LineNumber">
                <!-- Свойства стандартного реквизита НомерСтроки -->
            </xr:StandardAttribute>
        </StandardAttributes>
        <Use>ForItem</Use>  <!-- Только для иерарх. справочников -->
    </Properties>
    <ChildObjects>
        <Attribute uuid="...">
            <!-- Реквизиты-колонки таблицы: формат как у обычных реквизитов,
                 но без FillFromFillingValue, FillValue, Use.
                 У нехранимых объектов (DataProcessor, Report) реквизиты ТЧ
                 содержат FillFromFillingValue и FillValue, но не содержат
                 Indexing, FullTextSearch, DataHistory -->
        </Attribute>
    </ChildObjects>
</TabularSection>
```

Имя генерируемого типа: `{Тип}TabularSection.{Объект}.{ИмяТЧ}` и `{Тип}TabularSectionRow.{Объект}.{ИмяТЧ}`.

### 6.3. Форма (Form)

```xml
<Form uuid="...">
    <Properties>
        <Name>ФормаЭлемента</Name>
        <Synonym>...</Synonym>
        <Comment/>
        <FormType>Ordinary</FormType>   <!-- Ordinary = управляемая форма -->
    </Properties>
</Form>
```

Содержимое формы хранится в отдельных файлах: `Forms/<Имя>/<Имя>.xml` и `Forms/<Имя>/Ext/Form.xml`.

### 6.4. Макет (Template)

```xml
<Template uuid="...">
    <Properties>
        <Name>ОсновнаяСхемаКомпоновкиДанных</Name>
        <Synonym>...</Synonym>
        <Comment/>
        <TemplateType>DataCompositionSchema</TemplateType>  <!-- DataCompositionSchema | SpreadsheetDocument | HTMLDocument | TextDocument | BinaryData | ActiveDocument -->
    </Properties>
</Template>
```

Тело макета: `Templates/<Имя>/Ext/Template.xml` (или другое расширение в зависимости от типа).

### 6.5. Команда (Command)

```xml
<Command uuid="...">
    <Properties>
        <Name>ВвестиНаОсновании</Name>
        <Synonym>...</Synonym>
        <Comment/>
        <Group>FormCommandBarImportant</Group>   <!-- FormCommandBar | FormNavigationPanel | ActionsPanelTools | ... -->
        <CommandParameterType>
            <v8:TypeDescription>
                <v8:Type>cfg:DocumentRef.АвансовыйОтчет</v8:Type>
            </v8:TypeDescription>
        </CommandParameterType>
        <ParameterUseMode>Multiple</ParameterUseMode>  <!-- Multiple -->
        <ModifiesData>true</ModifiesData>
        <Representation>Auto</Representation>    <!-- Auto | TextPicture | Text | Picture -->
        <ToolTip>...</ToolTip>
        <Picture>
            <xr:Ref>CommonPicture.Создать</xr:Ref>
            <xr:LoadTransparent>false</xr:LoadTransparent>
        </Picture>
        <Shortcut/>
        <OnMainServerUnavalableBehavior>Auto</OnMainServerUnavalableBehavior>
    </Properties>
</Command>
```

---

## 7. Справочники (Catalogs)

XML-элемент: `<Catalog>`. Категория InternalInfo: CatalogObject, CatalogRef, CatalogSelection, CatalogList, CatalogManager.

### 7.1. Специфичные свойства

**Иерархия:**

```xml
<Hierarchical>true</Hierarchical>
<HierarchyType>HierarchyFoldersAndItems</HierarchyType>  <!-- HierarchyFoldersAndItems | HierarchyItemsOnly -->
<LimitLevelCount>true</LimitLevelCount>
<LevelCount>3</LevelCount>
<FoldersOnTop>true</FoldersOnTop>
```

**Код и наименование:**

```xml
<CodeLength>11</CodeLength>
<CodeType>String</CodeType>                          <!-- String | Number -->
<CodeAllowedLength>Variable</CodeAllowedLength>      <!-- Variable | Fixed -->
<CodeSeries>WholeCatalog</CodeSeries>                <!-- WholeCatalog | WithinOwnerSubordination | WithinParent -->
<DescriptionLength>150</DescriptionLength>
<CheckUnique>true</CheckUnique>
<Autonumbering>true</Autonumbering>
<DefaultPresentation>AsDescription</DefaultPresentation>  <!-- AsDescription | AsCode -->
```

**Владелец:**

```xml
<Owners>
    <xr:Item xsi:type="xr:MDObjectRef">Catalog.Контрагенты</xr:Item>
</Owners>
<SubordinationUse>ToItems</SubordinationUse>  <!-- ToItems | ToFolders | ToFoldersAndItems -->
```

**Прочее:**

```xml
<EditType>InDialog</EditType>               <!-- InDialog | InList | Both -->
<QuickChoice>true</QuickChoice>
<ChoiceMode>BothWays</ChoiceMode>            <!-- BothWays -->
<PredefinedDataUpdate>Auto</PredefinedDataUpdate>  <!-- Auto | DontAutoUpdate -->
```

### 7.2. Предопределённые элементы (Predefined.xml)

Файл `Ext/Predefined.xml` содержит предопределённые элементы справочника (если есть):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PredefinedData xmlns="http://v8.1c.ru/8.3/MDClasses" ...>
    <Item>
        <Name>ОсновнаяВалюта</Name>
        <Description>Рубль</Description>
        <Code>643</Code>
        <IsFolder>false</IsFolder>
        <!-- значения реквизитов -->
    </Item>
</PredefinedData>
```

---

## 8. Документы (Documents)

XML-элемент: `<Document>`. Категория InternalInfo: DocumentObject, DocumentRef, DocumentSelection, DocumentList, DocumentManager.

### 8.1. Специфичные свойства

**Нумерация:**

```xml
<Numerator/>                                          <!-- Ссылка на нумератор (опционально) -->
<NumberType>String</NumberType>                       <!-- String | Number -->
<NumberLength>11</NumberLength>
<NumberAllowedLength>Variable</NumberAllowedLength>   <!-- Variable | Fixed -->
<NumberPeriodicity>Year</NumberPeriodicity>            <!-- Nonperiodical | Year | Quarter | Month | Day -->
<CheckUnique>true</CheckUnique>
<Autonumbering>true</Autonumbering>
```

**Проведение:**

```xml
<Posting>Allow</Posting>                              <!-- Allow | Deny -->
<RealTimePosting>Allow</RealTimePosting>              <!-- Allow | Deny -->
<PostInPrivilegedMode>true</PostInPrivilegedMode>
<UnpostInPrivilegedMode>true</UnpostInPrivilegedMode>
```

**Движения по регистрам:**

```xml
<RegisterRecords>
    <xr:Item xsi:type="xr:MDObjectRef">AccumulationRegister.ТоварыНаСкладах</xr:Item>
    <xr:Item xsi:type="xr:MDObjectRef">InformationRegister.ЦеныНоменклатуры</xr:Item>
    <xr:Item xsi:type="xr:MDObjectRef">AccountingRegister.Хозрасчетный</xr:Item>
</RegisterRecords>
<RegisterRecordsDeletion>AutoDeleteOnUnpost</RegisterRecordsDeletion>   <!-- AutoDeleteOnUnpost | AutoDeleteOff -->
<RegisterRecordsWritingOnPost>WriteSelected</RegisterRecordsWritingOnPost>  <!-- WriteSelected | WriteAll -->
<SequenceFilling>AutoFill</SequenceFilling>                              <!-- AutoFill | AutoFillOff -->
```

### 8.2. Стандартные реквизиты документа

- **Ref** — ссылка
- **DeletionMark** — пометка удаления
- **Date** — дата документа
- **Number** — номер документа
- **Posted** — проведён

---

## 9. Регистры

### 9.1. Регистры сведений (InformationRegisters)

XML-элемент: `<InformationRegister>`.

**Специфичные свойства:**

```xml
<InformationRegisterPeriodicity>Month</InformationRegisterPeriodicity>
    <!-- Nonperiodical | Second | Day | Month | Quarter | Year | RecorderPosition -->
<WriteMode>Independent</WriteMode>              <!-- Independent | RecorderSubordinate -->
<MainFilterOnPeriod>true</MainFilterOnPeriod>
<EnableTotalsSliceFirst>false</EnableTotalsSliceFirst>
<EnableTotalsSliceLast>false</EnableTotalsSliceLast>
```

- `WriteMode=Independent` — записи создаются напрямую, без документа-регистратора
- `WriteMode=RecorderSubordinate` — записи привязаны к документу-регистратору
- `RecorderPosition` — непериодический, но подчинённый регистратору (период = момент записи регистратора)

**Дочерние объекты (ChildObjects):**

- `<Dimension>` — измерения (ключевые поля)
- `<Resource>` — ресурсы (хранимые значения)
- `<Attribute>` — реквизиты (дополнительная информация)
- `<Form>`, `<Template>`, `<Command>`

### 9.2. Измерение (Dimension)

Дополнительные свойства по сравнению с обычным реквизитом:

```xml
<Dimension uuid="...">
    <Properties>
        <!-- Все свойства как у Attribute, плюс: -->
        <Master>true</Master>                           <!-- Ведущее измерение -->
        <MainFilter>true</MainFilter>                   <!-- Основной отбор -->
        <DenyIncompleteValues>true</DenyIncompleteValues> <!-- Запрет незаполненных -->
    </Properties>
</Dimension>
```

### 9.3. Ресурс (Resource)

Структура идентична реквизиту (Attribute), дополнительных специфичных свойств нет. Семантически ресурс — это хранимое значение, по которому возможна агрегация.

### 9.4. Регистры накопления (AccumulationRegisters)

XML-элемент: `<AccumulationRegister>`.

**Специфичные свойства:**

```xml
<RegisterType>Balances</RegisterType>       <!-- Balances (остатки) | Turnovers (обороты) -->
<EnableTotalsSplitting>true</EnableTotalsSplitting>
```

- `Balances` — хранит остатки (приход/расход → итоговое сальдо)
- `Turnovers` — хранит только обороты (без остатков)

**Дочерние объекты:** `<Dimension>`, `<Resource>`, `<Attribute>`.

### 9.5. Регистры бухгалтерии (AccountingRegisters)

XML-элемент: `<AccountingRegister>`.

**Специфичные свойства:**

```xml
<ChartOfAccounts>ChartOfAccounts.Хозрасчетный</ChartOfAccounts>  <!-- Ссылка на план счетов -->
<Correspondence>true</Correspondence>                              <!-- Корреспонденция (двойная запись) -->
<PeriodAdjustmentLength>3</PeriodAdjustmentLength>
```

**Стандартные реквизиты** включают Account, ExtDimension1-3, ExtDimensionType1-3 — субконто и виды субконто, привязанные к счёту через LinkByType.

**Дочерние объекты:** `<Dimension>` (доп. разрезы, напр. Организация). Ресурсы и реквизиты в ChildObjects обычно отсутствуют — суммы определяются через корреспонденцию.

### 9.6. Регистры расчёта (CalculationRegisters)

XML-элемент: `<CalculationRegister>`.

**Специфичные свойства:**

```xml
<ChartOfCalculationTypes>ChartOfCalculationTypes.Начисления</ChartOfCalculationTypes>
<Periodicity>Month</Periodicity>             <!-- Month | Quarter | Year -->
<ActionPeriod>true</ActionPeriod>            <!-- Период действия -->
<BasePeriod>true</BasePeriod>                <!-- Базовый период -->
<Schedule>InformationRegister.ГрафикиРаботы</Schedule>
<ScheduleValue>InformationRegister.ГрафикиРаботы.Resource.ЗначениеДень</ScheduleValue>
<ScheduleDate>InformationRegister.ГрафикиРаботы.Dimension.Дата</ScheduleDate>
```

**Специфика реквизитов:** реквизиты могут содержать элемент `<ScheduleLink>` — ссылку на измерение графика.

---

## 10. Планы счетов (ChartsOfAccounts)

XML-элемент: `<ChartOfAccounts>`.

### 10.1. Специфичные свойства

```xml
<ExtDimensionTypes>ChartOfCharacteristicTypes.ВидыСубконтоХозрасчетные</ExtDimensionTypes>
<MaxExtDimensionCount>3</MaxExtDimensionCount>
<CodeMask>@@@.@@.@</CodeMask>         <!-- Маска кода счёта -->
<CodeLength>8</CodeLength>
<DescriptionLength>120</DescriptionLength>
<CodeSeries>WholeChartOfAccounts</CodeSeries>
<AutoOrderByCode>true</AutoOrderByCode>
<OrderLength>5</OrderLength>
```

### 10.2. Специфичные стандартные реквизиты

- **Type** — тип счёта (`Active` | `Passive` | `ActivePassive`)
- **OffBalance** — забалансовый
- **Order** — порядок

### 10.3. Стандартная табличная часть (StandardTabularSections)

```xml
<StandardTabularSections>
    <xr:StandardTabularSection name="ExtDimensionTypes">
        <xr:StandardAttributes>
            <xr:StandardAttribute name="TurnoversOnly">...</xr:StandardAttribute>
            <xr:StandardAttribute name="Predefined">...</xr:StandardAttribute>
            <xr:StandardAttribute name="ExtDimensionType">...</xr:StandardAttribute>
            <xr:StandardAttribute name="LineNumber">...</xr:StandardAttribute>
        </xr:StandardAttributes>
    </xr:StandardTabularSection>
</StandardTabularSections>
```

### 10.4. Специфичные дочерние объекты

- **AccountingFlag** — признаки учёта (напр. `Валютный`, `Количественный`, `НалоговыйУчет`):

```xml
<AccountingFlag uuid="...">
    <Properties>
        <Name>Валютный</Name>
        <Synonym>...</Synonym>
        <Type><v8:Type>xs:boolean</v8:Type></Type>
        <!-- стандартные свойства реквизита -->
    </Properties>
</AccountingFlag>
```

- **ExtDimensionAccountingFlag** — признаки учёта субконто (напр. `Суммовой`, `Валютный`, `Количественный`):

```xml
<ExtDimensionAccountingFlag uuid="...">
    <Properties>
        <Name>Суммовой</Name>
        <Type><v8:Type>xs:boolean</v8:Type></Type>
        <!-- ... -->
    </Properties>
</ExtDimensionAccountingFlag>
```

---

## 11. Планы видов характеристик (ChartsOfCharacteristicTypes)

XML-элемент: `<ChartOfCharacteristicTypes>`.

### 11.1. Специфичные свойства

```xml
<CharacteristicExtValues>Catalog.Субконто</CharacteristicExtValues>  <!-- Доп. значения характеристик -->
<Type>
    <!-- Составной тип со ВСЕМИ допустимыми типами значений характеристик -->
    <v8:Type>cfg:CatalogRef.Контрагенты</v8:Type>
    <v8:Type>cfg:CatalogRef.Номенклатура</v8:Type>
    <!-- ... сотни типов ... -->
</Type>
<Hierarchical>false</Hierarchical>
```

Стандартный реквизит **ValueType** определяет тип значения конкретного вида характеристики.

---

## 12. Планы видов расчёта (ChartsOfCalculationTypes)

XML-элемент: `<ChartOfCalculationTypes>`.

### 12.1. Специфичные свойства

```xml
<DependenceOnCalculationTypes>OnActionPeriod</DependenceOnCalculationTypes>  <!-- OnActionPeriod -->
<BaseCalculationTypes>
    <xr:Item xsi:type="xr:MDObjectRef">ChartOfCalculationTypes.Начисления</xr:Item>
</BaseCalculationTypes>
<ActionPeriodUse>true</ActionPeriodUse>
```

### 12.2. Дополнительные генерируемые типы

- `DisplacingCalculationTypes.{Имя}` — вытесняющие виды расчёта
- `BaseCalculationTypes.{Имя}` — базовые виды расчёта
- `LeadingCalculationTypes.{Имя}` — ведущие виды расчёта

### 12.3. Специфичный стандартный реквизит

- **ActionPeriodIsBasic** — период действия является базовым

---

## 13. Бизнес-процессы (BusinessProcesses)

XML-элемент: `<BusinessProcess>`.

### 13.1. Специфичные свойства

```xml
<EditType>InDialog</EditType>
<NumberType>String</NumberType>
<NumberLength>11</NumberLength>
<NumberAllowedLength>Variable</NumberAllowedLength>
<CheckUnique>true</CheckUnique>
<Autonumbering>true</Autonumbering>
```

### 13.2. Стандартные реквизиты

- **Started** — запущен
- **Completed** — завершён
- **HeadTask** — ведущая задача
- **Ref**, **DeletionMark**, **Date**, **Number**

### 13.3. Карта маршрута (Flowchart.xml)

Файл `Ext/Flowchart.xml` содержит визуальную схему маршрута бизнес-процесса с точками действий, условиями и переходами.

---

## 14. Задачи (Tasks)

XML-элемент: `<Task>`.

### 14.1. Специфичные свойства

```xml
<NumberType>String</NumberType>
<NumberLength>14</NumberLength>
<TaskNumberAutoPrefix>BusinessProcessNumber</TaskNumberAutoPrefix>  <!-- Автопрефикс -->
<DescriptionLength>150</DescriptionLength>
<Addressing>InformationRegister.ИсполнителиЗадач</Addressing>     <!-- Регистр адресации -->
<MainAddressingAttribute>Task.ЗадачаИсполнителя.AddressingAttribute.Исполнитель</MainAddressingAttribute>
<CurrentPerformer>SessionParameter.АвторизованныйПользователь</CurrentPerformer>
```

### 14.2. Стандартные реквизиты

- **Executed** — выполнена
- **Description** — описание
- **RoutePoint** — точка маршрута
- **BusinessProcess** — бизнес-процесс
- **Ref**, **DeletionMark**, **Date**, **Number**

### 14.3. Реквизит адресации (AddressingAttribute)

Специальный тип дочернего объекта для маршрутизации задач:

```xml
<AddressingAttribute uuid="...">
    <Properties>
        <Name>Исполнитель</Name>
        <Synonym>...</Synonym>
        <Type>...</Type>
        <AddressingDimension>InformationRegister.ИсполнителиЗадач.Dimension.Исполнитель</AddressingDimension>
        <Indexing>Index</Indexing>
        <FullTextSearch>Use</FullTextSearch>
        <DataHistory>Use</DataHistory>
    </Properties>
</AddressingAttribute>
```

---

## 15. Планы обмена (ExchangePlans)

XML-элемент: `<ExchangePlan>`.

### 15.1. Специфичные свойства

```xml
<DistributedInfoBase>false</DistributedInfoBase>     <!-- Распределённая ИБ -->
<IncludeConfigurationExtensions>false</IncludeConfigurationExtensions>
<CodeLength>9</CodeLength>
<DescriptionLength>100</DescriptionLength>
```

### 15.2. Стандартные реквизиты

- **ThisNode** — этот узел
- **SentNo** — номер отправленного
- **ReceivedNo** — номер принятого
- **Ref**, **DeletionMark**, **Description**, **Code**

### 15.3. InternalInfo — ThisNode

```xml
<InternalInfo>
    <xr:ThisNode>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</xr:ThisNode>
    <!-- GeneratedType элементы -->
</InternalInfo>
```

### 15.4. Состав плана обмена (Content.xml)

Файл `Ext/Content.xml` определяет, какие объекты участвуют в обмене:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ExchangePlanContent xmlns="http://v8.1c.ru/8.3/MDClasses" ...>
    <Item>
        <Metadata>Catalog.Контрагенты</Metadata>
        <AutoRecord>Allow</AutoRecord>       <!-- Allow | Deny -->
    </Item>
    <Item>
        <Metadata>Document.РеализацияТоваровУслуг</Metadata>
        <AutoRecord>Allow</AutoRecord>
    </Item>
</ExchangePlanContent>
```

---

## 16. Перечисления (Enums)

XML-элемент: `<Enum>`. Категория InternalInfo: EnumRef, EnumManager, EnumList.

### 16.1. Специфичные свойства

```xml
<UseStandardCommands>false</UseStandardCommands>
<QuickChoice>true</QuickChoice>
<ChoiceMode>BothWays</ChoiceMode>
```

### 16.2. Стандартные реквизиты

- **Order** — порядок
- **Ref** — ссылка

### 16.3. Значения перечисления (EnumValue)

```xml
<ChildObjects>
    <EnumValue uuid="...">
        <Properties>
            <Name>Продажа</Name>
            <Synonym>
                <v8:item><v8:lang>ru</v8:lang><v8:content>Продажа</v8:content></v8:item>
            </Synonym>
            <Comment/>
        </Properties>
    </EnumValue>
    <EnumValue uuid="...">
        <Properties>
            <Name>Возврат</Name>
            <Synonym>...</Synonym>
            <Comment/>
        </Properties>
    </EnumValue>
</ChildObjects>
```

Порядок `<EnumValue>` в XML определяет порядок отображения.

---

## 17. Константы (Constants)

XML-элемент: `<Constant>`. Категория InternalInfo: ConstantManager, ConstantValueManager, ConstantValueKey.

### 17.1. Свойства

Константа — простейший объект, хранящий одно значение заданного типа:

```xml
<Properties>
    <Name>ВалютаРегламентированногоУчета</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Type>
        <v8:Type>cfg:CatalogRef.Валюты</v8:Type>
    </Type>
    <UseStandardCommands>true</UseStandardCommands>
    <DefaultForm/>
    <ExtendedPresentation/>
    <Explanation/>
    <PasswordMode>false</PasswordMode>
    <Format/>
    <EditFormat/>
    <ToolTip/>
    <MarkNegatives>false</MarkNegatives>
    <Mask/>
    <MultiLine>false</MultiLine>
    <ExtendedEdit>false</ExtendedEdit>
    <MinValue xsi:nil="true"/>
    <MaxValue xsi:nil="true"/>
    <FillChecking>ShowError</FillChecking>
    <ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>
    <ChoiceParameterLinks/>
    <ChoiceParameters/>
    <QuickChoice>Auto</QuickChoice>
    <ChoiceForm/>
    <LinkByType/>
    <ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
    <DataLockControlMode>Managed</DataLockControlMode>
    <DataHistory>DontUse</DataHistory>
</Properties>
```

**ChildObjects** у константы отсутствует.

---

## 18. Отчёты и обработки

### 18.1. Отчёты (Reports)

XML-элемент: `<Report>`. Категория InternalInfo: только Object.

```xml
<Properties>
    <Name>АнализПродаж</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <UseStandardCommands>true</UseStandardCommands>
    <DefaultForm>CommonForm.ФормаОтчета</DefaultForm>
    <AuxiliaryForm/>
    <MainDataCompositionSchema>Report.АнализПродаж.Template.ОсновнаяСхемаКомпоновкиДанных</MainDataCompositionSchema>
    <DefaultSettingsForm>CommonForm.ФормаНастроекОтчета</DefaultSettingsForm>
    <AuxiliarySettingsForm/>
    <DefaultVariantForm>CommonForm.ФормаВариантаОтчета</DefaultVariantForm>
    <VariantsStorage/>
    <SettingsStorage/>
    <IncludeHelpInContents>false</IncludeHelpInContents>
    <ExtendedPresentation/>
    <Explanation/>
</Properties>
```

**Дочерние объекты:** `<Attribute>`, `<TabularSection>`, `<Form>`, `<Template>`, `<Command>`.

### 18.2. Обработки (DataProcessors)

XML-элемент: `<DataProcessor>`. Категория InternalInfo: только Object.

```xml
<Properties>
    <Name>ЗагрузкаДанных</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <UseStandardCommands>false</UseStandardCommands>
    <DefaultForm>DataProcessor.ЗагрузкаДанных.Form.Форма</DefaultForm>
    <AuxiliaryForm/>
    <IncludeHelpInContents>true</IncludeHelpInContents>
    <ExtendedPresentation/>
    <Explanation/>
</Properties>
```

**Дочерние объекты:** `<Attribute>`, `<TabularSection>`, `<Form>`, `<Template>`, `<Command>`.

**Различия Отчёт vs Обработка:**
- Отчёт имеет `MainDataCompositionSchema`, `DefaultSettingsForm`, `DefaultVariantForm`, `VariantsStorage`, `SettingsStorage`
- Обработка не имеет этих свойств

---

## 19. Журналы документов (DocumentJournals)

XML-элемент: `<DocumentJournal>`. Категория InternalInfo: DocumentJournalSelection, DocumentJournalList, DocumentJournalManager.

### 19.1. Специфичные свойства

```xml
<DefaultForm>DocumentJournal.Взаимодействия.Form.ФормаСписка</DefaultForm>
<AuxiliaryForm/>
<UseStandardCommands>true</UseStandardCommands>
<RegisteredDocuments>
    <xr:Item xsi:type="xr:MDObjectRef">Document.Встреча</xr:Item>
    <xr:Item xsi:type="xr:MDObjectRef">Document.ТелефонныйЗвонок</xr:Item>
    <xr:Item xsi:type="xr:MDObjectRef">Document.ЭлектронноеПисьмо</xr:Item>
</RegisteredDocuments>
```

### 19.2. Стандартные реквизиты

- **Type** — тип документа
- **Ref** — ссылка
- **Date** — дата
- **Posted** — проведён
- **DeletionMark** — пометка удаления
- **Number** — номер

### 19.3. Графы журнала (Column)

```xml
<ChildObjects>
    <Column uuid="...">
        <Properties>
            <Name>Организация</Name>
            <Synonym>...</Synonym>
            <Comment/>
            <Indexing>Index</Indexing>    <!-- DontIndex | Index | IndexWithAdditionalOrder -->
            <References>
                <xr:Item xsi:type="xr:MDObjectRef">Document.Встреча.Attribute.Организация</xr:Item>
                <xr:Item xsi:type="xr:MDObjectRef">Document.ТелефонныйЗвонок.Attribute.Организация</xr:Item>
            </References>
        </Properties>
    </Column>
</ChildObjects>
```

Каждая графа ссылается на реквизиты нескольких документов через `<References>`.

---

## 20. Определяемые типы (DefinedTypes)

XML-элемент: `<DefinedType>`. Категория InternalInfo: DefinedType.

### 20.1. Свойства

Определяемый тип — именованный составной тип, используемый для унификации типов реквизитов:

```xml
<Properties>
    <Name>ДенежныеСредстваВДокументах</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Type>
        <v8:Type>cfg:CatalogRef.БанковскиеСчета</v8:Type>
        <v8:Type>cfg:CatalogRef.КассыККМ</v8:Type>
        <v8:Type>cfg:CatalogRef.Кассы</v8:Type>
    </Type>
</Properties>
```

**ChildObjects** отсутствует.

---

## 21. Общие модули (CommonModules)

XML-элемент: `<CommonModule>`.

### 21.1. Свойства

```xml
<Properties>
    <Name>ОбменДаннымиСервер</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Global>false</Global>
    <ClientManagedApplication>false</ClientManagedApplication>
    <Server>true</Server>
    <ExternalConnection>false</ExternalConnection>
    <ClientOrdinaryApplication>false</ClientOrdinaryApplication>
    <ServerCall>true</ServerCall>
    <Privileged>false</Privileged>
    <ReturnValuesReuse>DuringRequest</ReturnValuesReuse>
</Properties>
```

| Свойство | Тип | Описание |
|---|---|---|
| `Global` | boolean | Глобальный модуль |
| `Server` | boolean | Доступен на сервере |
| `ServerCall` | boolean | Вызов сервера (из клиентского кода) |
| `ClientManagedApplication` | boolean | Клиент управляемого приложения |
| `ClientOrdinaryApplication` | boolean | Обычный клиент |
| `ExternalConnection` | boolean | Внешнее соединение |
| `Privileged` | boolean | Привилегированный режим |
| `ReturnValuesReuse` | enum | `DontUse` \| `DuringRequest` \| `DuringSession` |

**ChildObjects** отсутствует. Код модуля — в файле `Ext/Module.bsl`.

---

## 22. Регламентные задания (ScheduledJobs)

XML-элемент: `<ScheduledJob>`.

### 22.1. Свойства

```xml
<Properties>
    <Name>АвтоматическоеЗакрытиеМесяца</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <MethodName>CommonModule.ЗакрытиеМесяца.АвтоматическоеЗакрытиеМесяцаРегламентноеЗадание</MethodName>
    <Description>Автоматическое закрытие месяца</Description>
    <Key/>
    <Use>false</Use>
    <Predefined>false</Predefined>
    <RestartCountOnFailure>3</RestartCountOnFailure>
    <RestartIntervalOnFailure>10</RestartIntervalOnFailure>
</Properties>
```

| Свойство | Тип | Описание |
|---|---|---|
| `MethodName` | string | Метод вида `CommonModule.ИмяМодуля.ИмяПроцедуры` |
| `Use` | boolean | Использование (включено/выключено) |
| `Predefined` | boolean | Предопределённое |
| `RestartCountOnFailure` | int | Количество перезапусков при аварийном завершении |
| `RestartIntervalOnFailure` | int | Интервал перезапуска (секунды) |

**ChildObjects** отсутствует.

---

## 23. Подписки на события (EventSubscriptions)

XML-элемент: `<EventSubscription>`.

### 23.1. Свойства

```xml
<Properties>
    <Name>ПолныйРегистрацияУдаления</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Source>
        <v8:Type>cfg:DocumentObject.АвансовыйОтчет</v8:Type>
        <v8:Type>cfg:CatalogObject.Контрагенты</v8:Type>
        <!-- ... список типов-источников ... -->
    </Source>
    <Event>BeforeDelete</Event>
    <Handler>CommonModule.ОбменДаннымиРИБСобытия.ПолныйЗарегистрироватьУдаленияПередУдалением</Handler>
</Properties>
```

| Свойство | Тип | Описание |
|---|---|---|
| `Source` | `v8:Type[]` | Типы объектов-источников (в формате `cfg:{Тип}.{Имя}`) |
| `Event` | enum | `BeforeWrite` \| `OnWrite` \| `AfterWrite` \| `BeforeDelete` \| `Posting` \| `UndoPosting` \| `FillCheckProcessing` и др. |
| `Handler` | string | Обработчик вида `CommonModule.ИмяМодуля.ИмяПроцедуры` |

Типы источников: `cfg:CatalogObject.Xxx`, `cfg:DocumentObject.Xxx`, `cfg:InformationRegisterRecordSet.Xxx`, `cfg:AccumulationRegisterRecordSet.Xxx` и др.

**ChildObjects** отсутствует.

---

## 24. HTTP-сервисы (HTTPServices)

XML-элемент: `<HTTPService>`. Трёхуровневая вложенность: сервис → шаблон URL → метод.

### 24.1. Свойства

```xml
<Properties>
    <Name>ExternalAPI</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <RootURL>api</RootURL>
    <ReuseSessions>DontUse</ReuseSessions>
    <SessionMaxAge>20</SessionMaxAge>
</Properties>
```

### 24.2. Дочерние объекты: URLTemplate → Method

```xml
<ChildObjects>
    <URLTemplate uuid="...">
        <Properties>
            <Name>ПоказателиМонитора</Name>
            <Synonym>...</Synonym>
            <Template>/v1/kpi/</Template>
        </Properties>
        <ChildObjects>
            <Method uuid="...">
                <Properties>
                    <Name>Получить</Name>
                    <Synonym>...</Synonym>
                    <HTTPMethod>GET</HTTPMethod>
                    <Handler>ПоказателиМонитораПолучить</Handler>
                </Properties>
            </Method>
        </ChildObjects>
    </URLTemplate>
</ChildObjects>
```

Код обработчиков — в файле `Ext/Module.bsl`.

---

## 25. Веб-сервисы (WebServices)

XML-элемент: `<WebService>`. Трёхуровневая вложенность: сервис → операция → параметр.

### 25.1. Свойства

```xml
<Properties>
    <Name>EnterpriseDataUpload_1_0_1_1</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Namespace>http://www.1c.ru/SSL/EnterpriseDataUpload_1_0_1_1</Namespace>
    <XDTOPackages>...</XDTOPackages>
    <ReuseSessions>DontUse</ReuseSessions>
    <SessionMaxAge>20</SessionMaxAge>
</Properties>
```

### 25.2. Дочерние объекты: Operation → Parameter

```xml
<ChildObjects>
    <Operation uuid="...">
        <Properties>
            <Name>TestConnection</Name>
            <Synonym>...</Synonym>
            <Comment>Проверка подключения</Comment>
            <XDTOReturningValueType>xs:boolean</XDTOReturningValueType>
            <Nillable>false</Nillable>
            <Transactioned>false</Transactioned>
            <ProcedureName>ПроверкаПодключения</ProcedureName>
        </Properties>
        <ChildObjects>
            <Parameter uuid="...">
                <Properties>
                    <Name>ErrorMessage</Name>
                    <Synonym>...</Synonym>
                    <XDTOValueType>xs:string</XDTOValueType>
                    <Nillable>true</Nillable>
                    <TransferDirection>Out</TransferDirection>
                </Properties>
            </Parameter>
        </ChildObjects>
    </Operation>
</ChildObjects>
```

| Свойство параметра | Тип | Описание |
|---|---|---|
| `XDTOValueType` | string | Тип XDTO (`xs:string`, `xs:boolean`, `xs:int`, `xs:base64Binary` и др.) |
| `TransferDirection` | enum | `In` \| `Out` \| `InOut` |
| `Nillable` | boolean | Допускает пустое значение |

Код операций — в файле `Ext/Module.bsl`.

---

## 26. Различия версий платформы

### 26.1. Версия 2.17 → 2.20

Атрибут `version` корневого элемента `<MetaDataObject>`.

**Изменения в версии 2.20 (платформа 8.3.27):**

1. **TypeReductionMode** — новый элемент в каждом стандартном реквизите:

```xml
<xr:StandardAttribute name="Description">
    <xr:TypeReductionMode>TransformValues</xr:TypeReductionMode>
    <!-- остальные свойства без изменений -->
</xr:StandardAttribute>
```

Значения: `TransformValues` (преобразовывать значения) | `Deny` (запретить).

2. **LineNumberLength** — длина поля номера строки в табличных частях:

```xml
<TabularSection>
    <Properties>
        <LineNumberLength>5</LineNumberLength>
        <!-- ... -->
    </Properties>
</TabularSection>
```

### 26.2. Стабильные элементы

Между версиями 8.3.20 → 8.3.24 → 8.3.27:
- Структура каталогов **без изменений**
- Пространства имён **без изменений**
- UUID объектов **сохраняются**
- Именование файлов и каталогов **без изменений**

---

## 27. Сводная таблица: свойства по типам объектов

| Свойство | Cat | Doc | Enum | Const | InfoReg | AccReg | AcctReg | CalcReg | CoA | CoCT | CoCaT | BP | Task | EP | DJ | Rep | DP |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Name, Synonym, Comment | + | + | + | + | + | + | + | + | + | + | + | + | + | + | + | + | + |
| Code, Description | + | - | - | - | - | - | - | - | + | + | + | - | +* | + | - | - | - |
| Hierarchical | + | - | - | - | - | - | - | - | + | + | - | - | - | - | - | - | - |
| Owners | + | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - |
| NumberType/Length | - | + | - | - | - | - | - | - | - | - | - | + | + | - | - | - | - |
| Posting | - | + | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - |
| RegisterRecords | - | + | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - |
| RegisterType | - | - | - | - | - | + | - | - | - | - | - | - | - | - | - | - | - |
| Periodicity | - | - | - | - | + | - | - | + | - | - | - | - | - | - | - | - | - |
| WriteMode | - | - | - | - | + | - | - | - | - | - | - | - | - | - | - | - | - |
| ChartOfAccounts | - | - | - | - | - | - | + | - | - | - | - | - | - | - | - | - | - |
| ChartOfCalculationTypes | - | - | - | - | - | - | - | + | - | - | - | - | - | - | - | - | - |
| ExtDimensionTypes | - | - | - | - | - | - | - | - | + | - | - | - | - | - | - | - | - |
| CharacteristicExtValues | - | - | - | - | - | - | - | - | - | + | - | - | - | - | - | - | - |
| DistributedInfoBase | - | - | - | - | - | - | - | - | - | - | - | - | - | + | - | - | - |
| RegisteredDocuments | - | - | - | - | - | - | - | - | - | - | - | - | - | - | + | - | - |
| MainDCS | - | - | - | - | - | - | - | - | - | - | - | - | - | - | - | + | - |
| Addressing | - | - | - | - | - | - | - | - | - | - | - | - | + | - | - | - | - |
| Dimension/Resource | - | - | - | - | + | + | + | + | - | - | - | - | - | - | - | - | - |
| AccountingFlag | - | - | - | - | - | - | - | - | + | - | - | - | - | - | - | - | - |
| EnumValue | - | - | + | - | - | - | - | - | - | - | - | - | - | - | - | - | - |
| Column | - | - | - | - | - | - | - | - | - | - | - | - | - | - | + | - | - |
| AddressingAttribute | - | - | - | - | - | - | - | - | - | - | - | - | + | - | - | - | - |

`+*` — Description (без Code) у задач.

Сокращения: Cat=Справочник, Doc=Документ, Const=Константа, InfoReg=РегСведений, AccReg=РегНакопления, AcctReg=РегБухгалтерии, CalcReg=РегРасчёта, CoA=ПланСчетов, CoCT=ПВХ, CoCaT=ПВР, BP=БизнесПроцесс, EP=ПланОбмена, DJ=ЖурналДокументов, Rep=Отчёт, DP=Обработка.

---

## 28. Формат ссылок на объекты метаданных

В свойствах типа `DefaultObjectForm`, `InputByString`, `RegisterRecords`, `DataLockFields` и др. используется формат ссылок:

```
{ВидОбъекта}.{ИмяОбъекта}                                     # На объект
{ВидОбъекта}.{ИмяОбъекта}.Attribute.{ИмяРеквизита}             # На реквизит
{ВидОбъекта}.{ИмяОбъекта}.TabularSection.{ИмяТЧ}               # На табличную часть
{ВидОбъекта}.{ИмяОбъекта}.TabularSection.{ИмяТЧ}.Attribute.{Реквизит}  # На колонку ТЧ
{ВидОбъекта}.{ИмяОбъекта}.StandardAttribute.{Имя}              # На стандартный реквизит
{ВидОбъекта}.{ИмяОбъекта}.Form.{ИмяФормы}                      # На форму
{ВидОбъекта}.{ИмяОбъекта}.Template.{ИмяМакета}                 # На макет
{ВидОбъекта}.{ИмяОбъекта}.Dimension.{ИмяИзмерения}             # На измерение регистра
{ВидОбъекта}.{ИмяОбъекта}.Resource.{ИмяРесурса}                # На ресурс регистра
{ВидОбъекта}.{ИмяОбъекта}.AddressingAttribute.{Имя}            # На реквизит адресации
{ВидОбъекта}.{ИмяОбъекта}.EnumValue.{ИмяЗначения}              # На значение перечисления
```

Виды объектов в ссылках: `Catalog`, `Document`, `Enum`, `InformationRegister`, `AccumulationRegister`, `AccountingRegister`, `CalculationRegister`, `ChartOfAccounts`, `ChartOfCharacteristicTypes`, `ChartOfCalculationTypes`, `BusinessProcess`, `Task`, `ExchangePlan`, `DocumentJournal`, `Report`, `DataProcessor`, `CommonForm`, `CommonPicture`, `SessionParameter`, `Constant`.

---

## 29. Кодировка

Все XML-файлы используют кодировку UTF-8 с BOM (байты `EF BB BF`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
```
