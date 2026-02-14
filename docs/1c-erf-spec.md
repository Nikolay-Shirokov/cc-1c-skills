# Спецификация XML-формата выгрузки внешнего отчёта 1С

Формат: XML-выгрузка внешнего отчёта (ExternalReport) из конфигуратора 1С:Предприятие 8.3.
Версия формата: `2.17`.

> **Связь с другими спецификациями**:
> - Структура каталогов, пространства имён, формат форм и макетов — идентичны [спецификации внешней обработки (EPF)](1c-epf-spec.md).
> - Формат СКД-макетов — см. [спецификацию СКД](1c-dcs-spec.md).
> - Формат форм — см. [спецификацию форм](1c-form-spec.md).
> - Формат MXL-макетов — см. [спецификацию табличного документа](mxl-dsl-spec.md).
>
> Данный документ описывает **только** отличия внешнего отчёта от внешней обработки.

## 1. Структура каталогов

```
<ИмяОтчёта>.xml                              # Корневой файл метаданных
<ИмяОтчёта>/
    Ext/
        ObjectModule.bsl                      # Модуль объекта (опционально)
        Help.xml                              # Метаданные справки (опционально)
        Help/
            ru.html                           # HTML-страница справки
    Forms/
        <ИмяФормы>.xml                        # Метаданные формы
        <ИмяФормы>/
            Ext/
                Form.xml                      # Описание формы
                Form/
                    Module.bsl               # Модуль формы
    Templates/
        <ИмяМакета>.xml                       # Метаданные макета
        <ИмяМакета>/
            Ext/
                Template.<расш>              # Тело макета
```

Структура полностью совпадает с EPF. Отчёт может содержать:
- 0..N реквизитов объекта (описаны в корневом XML)
- 0..N табличных частей (описаны в корневом XML)
- 0..N форм (каталог `Forms/`)
- 0..N макетов (каталог `Templates/`) — включая СКД и MXL-макеты печатных форм
- 0..1 модуль объекта (`Ext/ObjectModule.bsl`)
- 0..1 встроенная справка (`Ext/Help.xml` + `Ext/Help/<язык>.html`)

## 2. Корневой файл отчёта (`<Имя>.xml`)

### 2.1. Общая структура

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="..." version="2.17">
    <ExternalReport uuid="<UUID>">
        <InternalInfo>
            <xr:ContainedObject>
                <xr:ClassId>e41aff26-25cf-4bb6-b6c1-3f478a75f374</xr:ClassId>
                <xr:ObjectId><UUID></xr:ObjectId>
            </xr:ContainedObject>
            <xr:GeneratedType name="ExternalReportObject.<Имя>" category="Object">
                <xr:TypeId><UUID></xr:TypeId>
                <xr:ValueId><UUID></xr:ValueId>
            </xr:GeneratedType>
        </InternalInfo>
        <Properties>
            <Name><Имя></Name>
            <Synonym>...</Synonym>
            <Comment/>
            <DefaultForm/>
            <AuxiliaryForm/>
            <MainDataCompositionSchema/>
            <DefaultSettingsForm/>
            <AuxiliarySettingsForm/>
            <DefaultVariantForm/>
            <VariantsStorage/>
            <SettingsStorage/>
        </Properties>
        <ChildObjects>
            <!-- Реквизиты объекта (опционально) -->
            <Attribute uuid="<UUID>">...</Attribute>
            <!-- Табличные части (опционально) -->
            <TabularSection uuid="<UUID>">...</TabularSection>
            <!-- Формы -->
            <Form><ИмяФормы></Form>
            <!-- Макеты -->
            <Template><ИмяМакета></Template>
        </ChildObjects>
    </ExternalReport>
</MetaDataObject>
```

### 2.2. Отличия от EPF

| Элемент | EPF | ERF |
|---------|-----|-----|
| Корневой элемент | `<ExternalDataProcessor>` | `<ExternalReport>` |
| ClassId | `c3831ec8-d8d5-4f93-8a22-f9bfae07327f` | `e41aff26-25cf-4bb6-b6c1-3f478a75f374` |
| GeneratedType (Object) | `ExternalDataProcessorObject.<Имя>` | `ExternalReportObject.<Имя>` |
| GeneratedType (ТЧ) | `DataProcessorTabularSection.<Имя>.<ТЧ>` | `ReportTabularSection.<Имя>.<ТЧ>` |
| GeneratedType (строка ТЧ) | `DataProcessorTabularSectionRow.<Имя>.<ТЧ>` | `ReportTabularSectionRow.<Имя>.<ТЧ>` |
| Путь к форме | `ExternalDataProcessor.<Имя>.Form.<Форма>` | `ExternalReport.<Имя>.Form.<Форма>` |
| Путь к макету | `ExternalDataProcessor.<Имя>.Template.<Макет>` | `ExternalReport.<Имя>.Template.<Макет>` |
| Тип реквизита формы | `cfg:ExternalDataProcessorObject.<Имя>` | `cfg:ExternalReportObject.<Имя>` |

### 2.3. Свойства (Properties)

Свойства EPF (`Name`, `Synonym`, `Comment`, `DefaultForm`, `AuxiliaryForm`) сохраняются. Добавляются **6 свойств**, специфичных для отчёта:

| Свойство | Описание | Пример значения |
|----------|----------|-----------------|
| `MainDataCompositionSchema` | Основная СКД отчёта. Полный путь к макету-СКД | `ExternalReport.<Имя>.Template.ОсновнаяСхемаКомпоновкиДанных` |
| `DefaultSettingsForm` | Форма настроек отчёта | `ExternalReport.<Имя>.Form.ФормаНастроек` |
| `AuxiliarySettingsForm` | Дополнительная форма настроек | (обычно пустой) |
| `DefaultVariantForm` | Форма вариантов отчёта | `ExternalReport.<Имя>.Form.ФормаВарианта` |
| `VariantsStorage` | Хранилище вариантов отчёта | `SettingsStorage.ХранилищеВариантовОтчетов` |
| `SettingsStorage` | Хранилище настроек | (обычно пустой) |

**Порядок свойств фиксирован**: Name → Synonym → Comment → DefaultForm → AuxiliaryForm → MainDataCompositionSchema → DefaultSettingsForm → AuxiliarySettingsForm → DefaultVariantForm → VariantsStorage → SettingsStorage.

Если значение отсутствует, элемент остаётся пустым (самозакрывающимся):
```xml
<DefaultForm/>
<MainDataCompositionSchema>ExternalReport.МойОтчёт.Template.ОсновнаяСхемаКомпоновкиДанных</MainDataCompositionSchema>
<VariantsStorage/>
```

## 3. Реквизиты объекта (Attribute)

В отличие от EPF (где реквизиты не документированы), внешний отчёт часто имеет реквизиты объекта. Они размещаются в `<ChildObjects>` корневого файла **перед** `<TabularSection>`, `<Form>` и `<Template>`:

```xml
<Attribute uuid="<UUID>">
    <Properties>
        <Name>Реквизит1</Name>
        <Synonym/>
        <Comment/>
        <Type>
            <v8:Type>xs:string</v8:Type>
            <v8:StringQualifiers>
                <v8:Length>10</v8:Length>
                <v8:AllowedLength>Variable</v8:AllowedLength>
            </v8:StringQualifiers>
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
        <FillChecking>DontCheck</FillChecking>
        <ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>
        <ChoiceParameterLinks/>
        <ChoiceParameters/>
        <QuickChoice>Auto</QuickChoice>
        <CreateOnInput>Auto</CreateOnInput>
        <ChoiceForm/>
        <LinkByType/>
        <ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
    </Properties>
</Attribute>
```

### Типы реквизитов

Типы реквизитов объекта аналогичны типам реквизитов форм:

| v8:Type | Описание | Квалификаторы |
|---------|----------|---------------|
| `xs:string` | Строка | `v8:StringQualifiers`: `Length`, `AllowedLength` |
| `xs:boolean` | Булево | — |
| `xs:decimal` | Число | `v8:NumberQualifiers`: `Digits`, `FractionDigits`, `AllowedSign` |
| `xs:dateTime` | Дата | `v8:DateQualifiers`: `DateFractions` |
| `cfg:CatalogRef.<Имя>` | Ссылка на справочник | — |
| `cfg:DocumentRef.<Имя>` | Ссылка на документ | — |
| `cfg:EnumRef.<Имя>` | Ссылка на перечисление | — |

> **Примечание**: Ссылочные типы (`cfg:CatalogRef.*` и т.д.) в контексте внешнего отчёта работают **только** при наличии в информационной базе конфигурации с соответствующими объектами.

### Свойства реквизита объекта (полный перечень)

Порядок фиксирован:

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Name` | string | Имя реквизита |
| `Synonym` | LocalString | Синоним (отображаемое имя) |
| `Comment` | string | Комментарий |
| `Type` | TypeDescription | Тип данных (см. таблицу типов выше) |
| `PasswordMode` | boolean | Режим пароля (`false`) |
| `Format` | string | Формат вывода |
| `EditFormat` | string | Формат редактирования |
| `ToolTip` | LocalString | Подсказка |
| `MarkNegatives` | boolean | Выделять отрицательные (`false`) |
| `Mask` | string | Маска ввода |
| `MultiLine` | boolean | Многострочный (`false`) |
| `ExtendedEdit` | boolean | Расширенное редактирование (`false`) |
| `MinValue` | any | Минимальное значение (`xsi:nil="true"`) |
| `MaxValue` | any | Максимальное значение (`xsi:nil="true"`) |
| `FillChecking` | enum | Проверка заполнения (`DontCheck`) |
| `ChoiceFoldersAndItems` | enum | Выбор групп и элементов (`Items`) |
| `ChoiceParameterLinks` | list | Связи параметров выбора |
| `ChoiceParameters` | list | Параметры выбора |
| `QuickChoice` | enum | Быстрый выбор (`Auto`) |
| `CreateOnInput` | enum | Создание при вводе (`Auto`) |
| `ChoiceForm` | string | Форма выбора |
| `LinkByType` | ref | Связь по типу |
| `ChoiceHistoryOnInput` | enum | История выбора при вводе (`Auto`) |

## 4. Табличные части (TabularSection)

Структура полностью аналогична EPF, отличаются только имена GeneratedType:

```xml
<TabularSection uuid="<UUID>">
    <InternalInfo>
        <xr:GeneratedType name="ReportTabularSection.<ИмяОтчёта>.<ИмяТЧ>" category="TabularSection">
            <xr:TypeId><UUID></xr:TypeId>
            <xr:ValueId><UUID></xr:ValueId>
        </xr:GeneratedType>
        <xr:GeneratedType name="ReportTabularSectionRow.<ИмяОтчёта>.<ИмяТЧ>" category="TabularSectionRow">
            <xr:TypeId><UUID></xr:TypeId>
            <xr:ValueId><UUID></xr:ValueId>
        </xr:GeneratedType>
    </InternalInfo>
    <Properties>
        <Name><ИмяТЧ></Name>
        <Synonym/>
        <Comment/>
        <ToolTip/>
        <FillChecking>DontCheck</FillChecking>
    </Properties>
    <ChildObjects>
        <Attribute uuid="<UUID>">
            <Properties>
                <!-- Те же свойства, что у реквизитов объекта, -->
                <!-- плюс два дополнительных: -->
                <FillFromFillingValue>false</FillFromFillingValue>
                <FillValue xsi:nil="true"/>
                <!-- ... остальные совпадают -->
            </Properties>
        </Attribute>
    </ChildObjects>
</TabularSection>
```

**Важно**: Реквизиты табличной части имеют 2 дополнительных свойства по сравнению с реквизитами объекта:
- `FillFromFillingValue` — заполнять из значения заполнения (`false`)
- `FillValue` — значение заполнения (`xsi:nil="true"` или `xsi:type="xs:string"` и т.д.)

Эти свойства вставляются между `MaxValue` и `FillChecking`.

## 5. Порядок элементов в ChildObjects

Порядок дочерних объектов **фиксирован**:

1. `<Attribute>` — реквизиты объекта (0..N)
2. `<TabularSection>` — табличные части (0..N)
3. `<Form>` — формы (0..N)
4. `<Template>` — макеты (0..N)

## 6. Формы отчёта

### 6.1. Метаданные формы (`Forms/<Имя>.xml`)

Формат метаданных формы полностью совпадает с EPF — см. [спецификацию EPF, раздел 4](1c-epf-spec.md).

### 6.2. Специфика Form.xml для отчётов

Формы отчёта имеют дополнительные свойства в `<Form>`, которых нет у форм обработки:

| Свойство | Описание | Допустимые значения |
|----------|----------|---------------------|
| `ReportFormType` | Тип формы отчёта | `Main`, `Settings`, `Variant` |
| `ReportResult` | Имя реквизита-результата | Имя реквизита типа SpreadsheetDocument |
| `DetailsData` | Имя реквизита данных расшифровки | Имя строкового реквизита |
| `CustomSettingsFolder` | Группа пользовательских настроек | Имя элемента UsualGroup на форме |

Эти свойства размещаются в начале `<Form>`, после `<CommandBarLocation>` и до `<AutoCommandBar>`.

### 6.3. Основная форма отчёта (ReportFormType = Main)

Форма для отображения результата отчёта.

```xml
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" ... version="2.17">
    <CommandBarLocation>None</CommandBarLocation>
    <ReportResult>Результат</ReportResult>
    <DetailsData>ДанныеРасшифровки</DetailsData>
    <ReportFormType>Main</ReportFormType>
    <CustomSettingsFolder>КомпоновщикНастроекПользовательскиеНастройки</CustomSettingsFolder>
    <AutoCommandBar name="" id="-1">
        <Autofill>false</Autofill>
    </AutoCommandBar>
    <ChildItems>
        <CommandBar name="ОсновнаяКоманднаяПанель" id="1">
            <Title>...</Title>
            <CommandSource>Form</CommandSource>
            <ExtendedTooltip name="ОсновнаяКоманднаяПанельРасширеннаяПодсказка" id="2"/>
        </CommandBar>
        <UsualGroup name="КомпоновщикНастроекПользовательскиеНастройки" id="3">
            <Title>...</Title>
            <VerticalStretch>false</VerticalStretch>
            <Group>Vertical</Group>
            <ShowTitle>false</ShowTitle>
            <ExtendedTooltip name="КомпоновщикНастроекПользовательскиеНастройкиРасширеннаяПодсказка" id="4"/>
        </UsualGroup>
        <SpreadSheetDocumentField name="Результат" id="5">
            <DataPath>Результат</DataPath>
            <DefaultItem>true</DefaultItem>
            <TitleLocation>None</TitleLocation>
            <Width>100</Width>
            <ContextMenu name="РезультатКонтекстноеМеню" id="6"/>
            <ExtendedTooltip name="РезультатРасширеннаяПодсказка" id="7"/>
        </SpreadSheetDocumentField>
    </ChildItems>
    <Attributes>
        <Attribute name="Отчет" id="1">
            <Type>
                <v8:Type>cfg:ExternalReportObject.<ИмяОтчёта></v8:Type>
            </Type>
            <MainAttribute>true</MainAttribute>
        </Attribute>
        <Attribute name="Результат" id="2">
            <Title>...</Title>
            <Type>
                <v8:Type xmlns:mxl="http://v8.1c.ru/8.2/data/spreadsheet">mxl:SpreadsheetDocument</v8:Type>
            </Type>
        </Attribute>
        <Attribute name="ДанныеРасшифровки" id="3">
            <Type>
                <v8:Type>xs:string</v8:Type>
                <v8:StringQualifiers>
                    <v8:Length>0</v8:Length>
                    <v8:AllowedLength>Variable</v8:AllowedLength>
                </v8:StringQualifiers>
            </Type>
        </Attribute>
    </Attributes>
</Form>
```

**Ключевые элементы основной формы отчёта:**

| Элемент | Описание |
|---------|----------|
| `SpreadSheetDocumentField` | Поле табличного документа для вывода результата. Привязано к реквизиту типа `mxl:SpreadsheetDocument` |
| Реквизит `Отчет` | Основной реквизит (`MainAttribute=true`), тип `cfg:ExternalReportObject.<Имя>` |
| Реквизит `Результат` | Табличный документ. Тип `mxl:SpreadsheetDocument` (требует дополнительный namespace `xmlns:mxl`) |
| Реквизит `ДанныеРасшифровки` | Строка неограниченной длины для данных расшифровки |
| Группа `КомпоновщикНастроекПользовательскиеНастройки` | Контейнер для пользовательских настроек СКД |

### 6.4. Форма настроек (ReportFormType = Settings)

Форма настроек отчёта для пользователя.

```xml
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" ... version="2.17">
    <CommandBarLocation>Bottom</CommandBarLocation>
    <VerticalScroll>useIfNecessary</VerticalScroll>
    <ReportFormType>Settings</ReportFormType>
    <CustomSettingsFolder>КомпоновщикНастроекПользовательскиеНастройки</CustomSettingsFolder>
    <AutoCommandBar name="" id="-1">
        <HorizontalAlign>Right</HorizontalAlign>
    </AutoCommandBar>
    <ChildItems>
        <UsualGroup name="КомпоновщикНастроекПользовательскиеНастройки" id="1">
            <Title>...</Title>
            <Group>Vertical</Group>
            <Representation>None</Representation>
            <ShowTitle>false</ShowTitle>
            <ExtendedTooltip name="КомпоновщикНастроекПользовательскиеНастройкиРасширеннаяПодсказка" id="2"/>
        </UsualGroup>
    </ChildItems>
    <Attributes>
        <Attribute name="Отчет" id="1">
            <Type>
                <v8:Type>cfg:ExternalReportObject.<ИмяОтчёта></v8:Type>
            </Type>
            <MainAttribute>true</MainAttribute>
        </Attribute>
    </Attributes>
</Form>
```

### 6.5. Форма варианта (ReportFormType = Variant)

Форма для настройки варианта отчёта (структуры, группировок, фильтров).

```xml
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" ... version="2.17">
    <CommandBarLocation>Bottom</CommandBarLocation>
    <CollapseItemsByImportanceVariant>DontUse</CollapseItemsByImportanceVariant>
    <ReportFormType>Variant</ReportFormType>
    <AutoCommandBar name="" id="-1">
        <HorizontalAlign>Right</HorizontalAlign>
    </AutoCommandBar>
    <ChildItems>
        <Table name="КомпоновщикНастроекНастройки" id="1">
            <Representation>Tree</Representation>
            <DataPath>Отчет.SettingsComposer.Settings</DataPath>
            <!-- ... элементы управления деревом настроек -->
        </Table>
        <!-- Страницы настроек (параметры, поля, фильтры и т.д.) -->
    </ChildItems>
    <!-- ... -->
</Form>
```

Форма варианта обычно содержит сложную структуру с деревом настроек (`Table` с `Representation=Tree` и `DataPath=Отчет.SettingsComposer.Settings`) и множеством страниц для редактирования параметров, полей, фильтров, сортировки и условного оформления.

### 6.6. Элемент SpreadSheetDocumentField

Специфичный для отчётов элемент формы — поле табличного документа. Используется для отображения результата отчёта.

```xml
<SpreadSheetDocumentField name="Результат" id="5">
    <DataPath>Результат</DataPath>
    <DefaultItem>true</DefaultItem>
    <TitleLocation>None</TitleLocation>
    <Width>100</Width>
    <ContextMenu name="РезультатКонтекстноеМеню" id="6"/>
    <ExtendedTooltip name="РезультатРасширеннаяПодсказка" id="7"/>
</SpreadSheetDocumentField>
```

| Свойство | Описание |
|----------|----------|
| `DataPath` | Путь к реквизиту типа SpreadsheetDocument |
| `DefaultItem` | Элемент по умолчанию (`true`) |
| `TitleLocation` | Расположение заголовка (`None`) |
| `Width` | Ширина в символах |

## 7. Модуль объекта

### 7.1. Событие ПриКомпоновкеРезультата

Основное событие модуля объекта отчёта. Вызывается платформой при формировании результата. Позволяет перехватить стандартную обработку СКД.

```bsl
Процедура ПриКомпоновкеРезультата(ДокументРезультат, ДанныеРасшифровки, СтандартнаяОбработка)
    // СтандартнаяОбработка = Ложь; // отключить стандартное формирование по СКД
    // Собственная логика формирования отчёта
КонецПроцедуры
```

Параметры:
- `ДокументРезультат` — табличный документ для вывода результата
- `ДанныеРасшифровки` — данные расшифровки
- `СтандартнаяОбработка` — если установить `Ложь`, платформа не будет сама формировать отчёт по СКД

### 7.2. Директива условной компиляции

В ERP-отчётах модуль объекта часто обёрнут в директиву условной компиляции:

```bsl
#Если Сервер Или ТолстыйКлиентОбычноеПриложение Или ВнешнееСоединение Тогда

// ... весь код модуля ...

#КонецЕсли
```

### 7.3. Типичные процедуры модуля объекта отчёта

| Процедура | Описание |
|-----------|----------|
| `ПриКомпоновкеРезультата` | Событие формирования результата |
| `ИнициализироватьОтчет` | Инициализация отчёта (экспорт, для БСП) |
| `ОпределитьНастройкиФормы` | Определение настроек формы (экспорт, для БСП) |
| `ПередЗагрузкойНастроекВКомпоновщик` | Предобработка настроек (экспорт, для БСП) |

## 8. Макеты (Templates)

### 8.1. СКД-макет (DataCompositionSchema)

Основной макет отчёта. Обязателен, если указан `MainDataCompositionSchema`.

```xml
<!-- Метаданные: Templates/ОсновнаяСхемаКомпоновкиДанных.xml -->
<Template uuid="<UUID>">
    <Properties>
        <Name>ОсновнаяСхемаКомпоновкиДанных</Name>
        <Synonym>...</Synonym>
        <Comment/>
        <TemplateType>DataCompositionSchema</TemplateType>
    </Properties>
</Template>
```

Тело СКД: `Templates/ОсновнаяСхемаКомпоновкиДанных/Ext/Template.xml` — формат описан в [спецификации СКД](1c-dcs-spec.md).

### 8.2. MXL-макеты печатных форм (SpreadsheetDocument)

Отчёты часто содержат MXL-макеты для вывода печатных форм.

```xml
<!-- Метаданные: Templates/ПФ_MXL_КарточкаУчета.xml -->
<Template uuid="<UUID>">
    <Properties>
        <Name>ПФ_MXL_КарточкаУчета</Name>
        <Synonym>...</Synonym>
        <Comment/>
        <TemplateType>SpreadsheetDocument</TemplateType>
    </Properties>
</Template>
```

Тело макета: `Templates/ПФ_MXL_КарточкаУчета/Ext/Template.xml` — формат MXL.

Конвенция именования MXL-макетов: `ПФ_MXL_<НазваниеПечатнойФормы>`.

## 9. Сравнение с отчётом конфигурации (Report)

| Аспект | ExternalReport (ERF) | Report (в конфигурации) |
|--------|---------------------|------------------------|
| Корневой элемент | `<ExternalReport>` | `<Report>` |
| ClassId | `e41aff26-25cf-4bb6-b6c1-3f478a75f374` | (нет ContainedObject) |
| GeneratedType (Object) | `ExternalReportObject.<Имя>` | `ReportObject.<Имя>` |
| GeneratedType (Manager) | — | `ReportManager.<Имя>` |
| Тип реквизита формы | `cfg:ExternalReportObject.<Имя>` | `cfg:ReportObject.<Имя>` |
| Дополнительные свойства | — | `UseStandardCommands`, `IncludeHelpInContents`, `ExtendedPresentation`, `Explanation` |
| Формы по умолчанию | Могут ссылаться на свои формы | Могут ссылаться на `CommonForm.*` |
| Хранение | Файл `.erf` | В составе конфигурации |

## 10. Минимальный пример

### Пустой отчёт (без СКД, форм, модулей)

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
    xmlns:xen="http://v8.1c.ru/8.3/xcf/enums"
    xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef"
    xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    version="2.17">
    <ExternalReport uuid="b38bc179-9b8a-4eb3-9422-96c6eded1ac3">
        <InternalInfo>
            <xr:ContainedObject>
                <xr:ClassId>e41aff26-25cf-4bb6-b6c1-3f478a75f374</xr:ClassId>
                <xr:ObjectId>38f084a4-47ce-4e67-ab4b-ac6323b9da08</xr:ObjectId>
            </xr:ContainedObject>
            <xr:GeneratedType name="ExternalReportObject.МойОтчёт" category="Object">
                <xr:TypeId>1fd37c7e-ade2-47ac-8dae-3fafeec96943</xr:TypeId>
                <xr:ValueId>b85e1756-f044-4907-b4bd-75a57649c486</xr:ValueId>
            </xr:GeneratedType>
        </InternalInfo>
        <Properties>
            <Name>МойОтчёт</Name>
            <Synonym>
                <v8:item>
                    <v8:lang>ru</v8:lang>
                    <v8:content>Мой отчёт</v8:content>
                </v8:item>
            </Synonym>
            <Comment/>
            <DefaultForm/>
            <AuxiliaryForm/>
            <MainDataCompositionSchema/>
            <DefaultSettingsForm/>
            <AuxiliarySettingsForm/>
            <DefaultVariantForm/>
            <VariantsStorage/>
            <SettingsStorage/>
        </Properties>
        <ChildObjects/>
    </ExternalReport>
</MetaDataObject>
```

### Отчёт с СКД

Добавляется ссылка на СКД в `MainDataCompositionSchema` и макет-СКД в `ChildObjects`:

```xml
<Properties>
    ...
    <MainDataCompositionSchema>ExternalReport.МойОтчёт.Template.ОсновнаяСхемаКомпоновкиДанных</MainDataCompositionSchema>
    ...
</Properties>
<ChildObjects>
    <Template>ОсновнаяСхемаКомпоновкиДанных</Template>
</ChildObjects>
```

Плюс файлы:
- `Templates/ОсновнаяСхемаКомпоновкиДанных.xml` (метаданные, `TemplateType=DataCompositionSchema`)
- `Templates/ОсновнаяСхемаКомпоновкиДанных/Ext/Template.xml` (тело СКД)

## 11. Чеклист для создания внешнего отчёта

1. Сгенерировать UUID для каждого объекта (отчёт, реквизиты, ТЧ, формы, макеты)
2. Создать структуру каталогов (раздел 1)
3. Создать корневой XML (раздел 2) с:
   - `ClassId = e41aff26-25cf-4bb6-b6c1-3f478a75f374`
   - `GeneratedType name="ExternalReportObject.<Имя>"`
   - Корректными путями в `MainDataCompositionSchema`, `DefaultForm` и др.
   - Правильным порядком элементов в `ChildObjects`
4. Создать СКД-макет (раздел 8.1):
   - Метаданные с `TemplateType=DataCompositionSchema`
   - Тело СКД по [спецификации СКД](1c-dcs-spec.md)
5. При необходимости создать формы (раздел 6):
   - Указать `ReportFormType` (`Main` / `Settings` / `Variant`)
   - Основная форма: `ReportResult`, `DetailsData`, `SpreadSheetDocumentField`
   - Основной реквизит: `cfg:ExternalReportObject.<Имя>`
6. При необходимости создать `ObjectModule.bsl` (раздел 7)
7. При необходимости создать MXL-макеты печатных форм (раздел 8.2)
8. Проверить:
   - Все пути используют префикс `ExternalReport.<Имя>` (не `ExternalDataProcessor`)
   - Тип основного реквизита формы: `cfg:ExternalReportObject.<Имя>`
   - `MainDataCompositionSchema` соответствует реальному макету в `ChildObjects`
   - Порядок в `ChildObjects`: Attribute → TabularSection → Form → Template
   - Все UUID уникальны
