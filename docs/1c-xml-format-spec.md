# Спецификация XML-формата выгрузки внешней обработки 1С

Формат: XML-выгрузка внешней обработки (ExternalDataProcessor) из конфигуратора 1С:Предприятие 8.3.
Версия формата: `2.17`.

## 1. Структура каталогов

```
<ИмяОбработки>.xml                          # Корневой файл метаданных
<ИмяОбработки>/
    Ext/
        ObjectModule.bsl                     # Модуль объекта (опционально)
        Help.xml                             # Метаданные справки (опционально)
        Help/
            ru.html                          # HTML-страница справки
    Forms/
        <ИмяФормы>.xml                       # Метаданные формы
        <ИмяФормы>/
            Ext/
                Form.xml                     # Описание формы (элементы, реквизиты, команды)
                Form/
                    Module.bsl               # Модуль формы
    Templates/
        <ИмяМакета>.xml                      # Метаданные макета
        <ИмяМакета>/
            Ext/
                Template.<расш>              # Тело макета: .html, .xml (mxl) и др.
```

Обработка может содержать:
- 0..N форм (каталог `Forms/`)
- 0..N макетов (каталог `Templates/`)
- 0..1 модуль объекта (`Ext/ObjectModule.bsl`)
- 0..1 встроенная справка (`Ext/Help.xml` + `Ext/Help/<язык>.html`), см. [1c-help-spec.md](1c-help-spec.md)
- 0..N табличных частей (описаны в корневом XML)

## 2. Пространства имён XML

### 2.1. Файлы метаданных (корневой XML, формы, макеты)

Корневой элемент — `<MetaDataObject>`, пространство имён:

```
xmlns="http://v8.1c.ru/8.3/MDClasses"
```

Полный набор деклараций (можно копировать как есть):

```xml
<MetaDataObject
    xmlns="http://v8.1c.ru/8.3/MDClasses"
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
```

### 2.2. Описание формы (Form.xml)

Корневой элемент — `<Form>`, пространство имён:

```
xmlns="http://v8.1c.ru/8.3/xcf/logform"
```

Полный набор деклараций:

```xml
<Form
    xmlns="http://v8.1c.ru/8.3/xcf/logform"
    xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
    xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"
    xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
    xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
    xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"
    xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"
    xmlns:style="http://v8.1c.ru/8.1/data/ui/style"
    xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"
    xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"
    xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"
    xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    version="2.17">
```

**Ключевое отличие**: файлы метаданных используют `http://v8.1c.ru/8.3/MDClasses`, описание формы — `http://v8.1c.ru/8.3/xcf/logform`.

## 3. Корневой файл обработки (`<Имя>.xml`)

Определяет имя обработки, синоним, форму по умолчанию и список дочерних объектов.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="..." version="2.17">
    <ExternalDataProcessor uuid="<UUID>">
        <InternalInfo>
            <xr:ContainedObject>
                <xr:ClassId>c3831ec8-d8d5-4f93-8a22-f9bfae07327f</xr:ClassId>
                <xr:ObjectId><UUID></xr:ObjectId>
            </xr:ContainedObject>
            <xr:GeneratedType name="ExternalDataProcessorObject.<Имя>" category="Object">
                <xr:TypeId><UUID></xr:TypeId>
                <xr:ValueId><UUID></xr:ValueId>
            </xr:GeneratedType>
        </InternalInfo>
        <Properties>
            <Name><Имя></Name>
            <Synonym>
                <v8:item>
                    <v8:lang>ru</v8:lang>
                    <v8:content><Представление></v8:content>
                </v8:item>
            </Synonym>
            <Comment/>
            <DefaultForm>ExternalDataProcessor.<Имя>.Form.<ИмяФормы></DefaultForm>
            <AuxiliaryForm/>
        </Properties>
        <ChildObjects>
            <!-- Табличные части (опционально) -->
            <TabularSection uuid="<UUID>">...</TabularSection>
            <!-- Формы -->
            <Form><ИмяФормы></Form>
            <!-- Макеты -->
            <Template><ИмяМакета></Template>
        </ChildObjects>
    </ExternalDataProcessor>
</MetaDataObject>
```

### Правила

| Элемент | Описание |
|---------|----------|
| `ClassId` | Всегда `c3831ec8-d8d5-4f93-8a22-f9bfae07327f` (идентификатор класса ExternalDataProcessor) |
| `ObjectId`, `TypeId`, `ValueId` | Уникальные UUID, генерируются при создании |
| `DefaultForm` | Полный путь: `ExternalDataProcessor.<Имя>.Form.<ИмяФормы>` |
| `<Form>`, `<Template>` | Только имена (без путей), соответствуют именам подкаталогов в `Forms/` и `Templates/` |
| `<TabularSection>` | Полное описание табличных частей объекта (включая реквизиты ТЧ с типами) |

### Табличные части объекта

Если обработка имеет табличные части, они описываются в `<ChildObjects>` корневого файла:

```xml
<TabularSection uuid="<UUID>">
    <InternalInfo>
        <xr:GeneratedType name="DataProcessorTabularSection.<ИмяОбработки>.<ИмяТЧ>" category="TabularSection">
            <xr:TypeId><UUID></xr:TypeId>
            <xr:ValueId><UUID></xr:ValueId>
        </xr:GeneratedType>
        <xr:GeneratedType name="DataProcessorTabularSectionRow.<ИмяОбработки>.<ИмяТЧ>" category="TabularSectionRow">
            <xr:TypeId><UUID></xr:TypeId>
            <xr:ValueId><UUID></xr:ValueId>
        </xr:GeneratedType>
    </InternalInfo>
    <Properties>
        <Name><ИмяТЧ></Name>
        <Synonym>...</Synonym>
        <Comment/>
        <ToolTip/>
        <FillChecking>DontCheck</FillChecking>
        <StandardAttributes>
            <xr:StandardAttribute name="LineNumber">
                <!-- Стандартные свойства реквизита -->
            </xr:StandardAttribute>
        </StandardAttributes>
    </Properties>
    <ChildObjects>
        <Attribute uuid="<UUID>">
            <Properties>
                <Name><ИмяРеквизита></Name>
                <Type>...</Type>
                <!-- Остальные свойства -->
            </Properties>
        </Attribute>
    </ChildObjects>
</TabularSection>
```

## 4. Метаданные формы (`Forms/<Имя>.xml`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="..." version="2.17">
    <Form uuid="<UUID>">
        <Properties>
            <Name><ИмяФормы></Name>
            <Synonym>
                <v8:item>
                    <v8:lang>ru</v8:lang>
                    <v8:content><Представление></v8:content>
                </v8:item>
            </Synonym>
            <Comment/>
            <FormType>Managed</FormType>
            <IncludeHelpInContents>false</IncludeHelpInContents>
            <UsePurposes>
                <v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
            </UsePurposes>
            <ExtendedPresentation/>
        </Properties>
    </Form>
</MetaDataObject>
```

`FormType` — всегда `Managed` для управляемых форм.

## 5. Метаданные макета (`Templates/<Имя>.xml`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="..." version="2.17">
    <Template uuid="<UUID>">
        <Properties>
            <Name><ИмяМакета></Name>
            <Synonym>
                <v8:item>
                    <v8:lang>ru</v8:lang>
                    <v8:content><Представление></v8:content>
                </v8:item>
            </Synonym>
            <Comment/>
            <TemplateType><ТипМакета></TemplateType>
        </Properties>
    </Template>
</MetaDataObject>
```

### Типы макетов

| Значение `TemplateType` | Расширение файла тела | Описание |
|---|---|---|
| `SpreadsheetDocument` | `.xml` | Табличный документ (MXL в XML) |
| `HTMLDocument` | `.html` | HTML-документ |
| `TextDocument` | `.txt` | Текстовый документ |
| `BinaryData` | `.bin` | Двоичные данные |
| `ActiveDocument` | `.xml` | Активный документ |

## 6. Описание формы (`Form.xml`)

Самый сложный файл. Содержит три корневых секции:
- `<ChildItems>` — дерево элементов формы (визуальная структура)
- `<Attributes>` — реквизиты формы (данные)
- `<Commands>` — команды формы

### 6.1. Общая структура

```xml
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" ... version="2.17">
    <Title>...</Title>
    <AutoTitle>false</AutoTitle>
    <AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
        <Autofill>false</Autofill>
    </AutoCommandBar>
    <Events>
        <Event name="OnCreateAtServer">ПриСозданииНаСервере</Event>
    </Events>
    <ChildItems>
        <!-- Элементы формы -->
    </ChildItems>
    <Attributes>
        <!-- Реквизиты формы -->
    </Attributes>
    <Commands>
        <!-- Команды формы -->
    </Commands>
</Form>
```

### 6.2. Идентификаторы (id)

- Каждый элемент, реквизит и команда имеет уникальный `id` (целое число).
- `id` уникален в пределах своей секции: элементы, реквизиты и команды нумеруются независимо.
- `id="-1"` зарезервирован для `AutoCommandBar` формы.
- `id` колонок (`Column`) — уникальны в пределах своего реквизита.

### 6.3. Элементы формы (`<ChildItems>`)

#### Типы элементов

| XML-тег | Описание | Ключевые свойства |
|---------|----------|-------------------|
| `UsualGroup` | Обычная группа | `Group` (Vertical/Horizontal), `Representation`, `ShowTitle` |
| `Button` | Кнопка | `Type` (UsualButton/CommandBarButton), `CommandName` |
| `InputField` | Поле ввода | `DataPath`, `MinValue`, `MaxValue` |
| `CheckBoxField` | Флажок | `DataPath`, `CheckBoxType`, `ThreeState`, `ReadOnly` |
| `LabelField` | Поле надписи | `DataPath` (только отображение) |
| `LabelDecoration` | Декорация-надпись | `Title` (статический текст) |
| `FormTree` | Дерево формы | `DataPath`, `Header`, `RowPictureDataPath` |
| `Table` | Таблица формы | `DataPath`, `Representation` (List/Tree), `ChangeRowSet` |
| `HTMLDocumentField` | Поле HTML-документа | `DataPath` |
| `CommandBar` | Командная панель (внутри элемента) | `Autofill` |
| `Popup` | Подменю на командной панели | `Title`, `Picture` |

#### Правила DataPath

- Простые реквизиты: `DataPath` = имя реквизита формы. Пример: `<DataPath>СтрокаПоиска</DataPath>`
- Колонки таблицы/дерева (реквизит формы): `<ИмяРеквизита>.<ИмяКолонки>`. Пример: `<DataPath>ТаблицаРеквизитов.Пометка</DataPath>`
- Табличные части объекта: `Объект.<ИмяТЧ>.<ИмяРеквизита>`. Пример: `<DataPath>Объект.ТЧМетаданные.Флаг</DataPath>`

#### ExtendedTooltip

Каждый элемент формы **должен** иметь дочерний `<ExtendedTooltip>`. Минимальная форма:

```xml
<ExtendedTooltip name="<ИмяЭлемента>ExtendedTooltip" id="<ID>"/>
```

Имя: `<ИмяРодительскогоЭлемента>ExtendedTooltip`. Может содержать `<Title>` с текстом подсказки.

#### ContextMenu

Элементы, поддерживающие контекстное меню (`InputField`, `CheckBoxField`, `LabelField`, `FormTree`, `Table`, `HTMLDocumentField`), **должны** иметь:

```xml
<ContextMenu name="<ИмяЭлемента>КонтекстноеМеню" id="<ID>"/>
```

#### Пример: группа с кнопками

```xml
<UsualGroup name="ГруппаКоманд" id="1">
    <Title><v8:item><v8:lang>ru</v8:lang><v8:content>Команды</v8:content></v8:item></Title>
    <Representation>None</Representation>
    <ShowTitle>false</ShowTitle>
    <ExtendedTooltip name="ГруппаКомандExtendedTooltip" id="100"/>
    <ChildItems>
        <Button name="КнопкаПостроить" id="2">
            <Type>UsualButton</Type>
            <Title>...</Title>
            <CommandName>Form.Command.Построить</CommandName>
            <ExtendedTooltip name="КнопкаПостроитьExtendedTooltip" id="101"/>
        </Button>
    </ChildItems>
</UsualGroup>
```

#### Пример: FormTree (дерево)

```xml
<FormTree name="ДеревоМетаданных" id="11">
    <DataPath>ДеревоМетаданных</DataPath>
    <TitleLocation>None</TitleLocation>
    <ContextMenu name="ДеревоМетаданныхКонтекстноеМеню" id="12"/>
    <ExtendedTooltip name="ДеревоМетаданныхExtendedTooltip" id="108"/>
    <CommandBar name="ДеревоМетаданныхКоманднаяПанель" id="13">
        <Autofill>false</Autofill>
        <ExtendedTooltip name="ДеревоМетаданныхКоманднаяПанельExtendedTooltip" id="109"/>
    </CommandBar>
    <Header>false</Header>
    <RowPictureDataPath>ДеревоМетаданных.ИндексКартинки</RowPictureDataPath>
    <Events>
        <Event name="OnActivateRow">ДеревоМетаданныхПриАктивизацииСтроки</Event>
    </Events>
    <ChildItems>
        <!-- Колонки как дочерние элементы -->
        <CheckBoxField name="ДеревоМетаданныхПометка" id="14">
            <DataPath>ДеревоМетаданных.Пометка</DataPath>
            ...
        </CheckBoxField>
    </ChildItems>
</FormTree>
```

#### Пример: Table (таблица, привязанная к реквизиту формы типа ValueTable)

```xml
<Table name="ТаблицаРеквизитов" id="26">
    <DataPath>ТаблицаРеквизитов</DataPath>
    <TitleLocation>None</TitleLocation>
    <ContextMenu name="ТаблицаРеквизитовКонтекстноеМеню" id="27"/>
    <ExtendedTooltip name="ТаблицаРеквизитовExtendedTooltip" id="119"/>
    <CommandBar name="ТаблицаРеквизитовКоманднаяПанель" id="28">
        <Autofill>false</Autofill>
        <ExtendedTooltip name="ТаблицаРеквизитовКоманднаяПанельExtendedTooltip" id="120"/>
    </CommandBar>
    <ChangeRowSet>false</ChangeRowSet>
    <ChangeRowOrder>false</ChangeRowOrder>
    <ChildItems>
        <CheckBoxField name="ТаблицаРеквизитовПометка" id="29">
            <DataPath>ТаблицаРеквизитов.Пометка</DataPath>
            ...
        </CheckBoxField>
    </ChildItems>
</Table>
```

#### Table: режим дерева

Элемент `Table` может отображать данные как дерево через `<Representation>Tree</Representation>`. В этом случае реквизит формы должен иметь тип `v8:ValueTree`.

```xml
<Table name="ДеревоМетаданных" id="238">
    <Representation>Tree</Representation>
    <DataPath>ДеревоМетаданных</DataPath>
    ...
</Table>
```

> **Примечание**: Элемент `FormTree` — альтернативный способ отобразить дерево. `FormTree` не требует явного указания `<Representation>`, дерево подразумевается. `Table` с `<Representation>Tree</Representation>` — более полный элемент с дополнительными возможностями (SearchStringAddition, ViewStatusAddition и др.).

#### Table: привязка к ТЧ объекта vs реквизит формы

| Источник данных | DataPath таблицы | DataPath колонки | Тип реквизита |
|---|---|---|---|
| Табличная часть объекта | `Объект.<ИмяТЧ>` | `Объект.<ИмяТЧ>.<ИмяРеквизита>` | (определён в корневом XML) |
| Реквизит формы (ValueTable) | `<ИмяРеквизита>` | `<ИмяРеквизита>.<ИмяКолонки>` | `v8:ValueTable` |
| Реквизит формы (ValueTree) | `<ИмяРеквизита>` | `<ИмяРеквизита>.<ИмяКолонки>` | `v8:ValueTree` |

### 6.4. Реквизиты формы (`<Attributes>`)

#### Примитивные типы

```xml
<Attribute name="СтрокаПоиска" id="18">
    <Title><v8:item><v8:lang>ru</v8:lang><v8:content>Строка поиска</v8:content></v8:item></Title>
    <Type>
        <v8:Type>xs:string</v8:Type>
        <v8:StringQualifiers>
            <v8:Length>200</v8:Length>
            <v8:AllowedLength>Variable</v8:AllowedLength>
        </v8:StringQualifiers>
    </Type>
</Attribute>
```

#### Таблица типов

| v8:Type | Описание | Квалификаторы |
|---------|----------|---------------|
| `xs:string` | Строка | `v8:StringQualifiers`: `Length` (0 = неограниченная), `AllowedLength` (Variable/Fixed) |
| `xs:boolean` | Булево | — |
| `xs:decimal` | Число | `v8:NumberQualifiers`: `Digits`, `FractionDigits`, `AllowedSign` (Any/Nonnegative) |
| `xs:dateTime` | Дата | `v8:DateQualifiers`: `DateFractions` (Date/Time/DateTime) |
| `v8:ValueTable` | Таблица значений | Должен содержать `<Columns>` |
| `v8:ValueTree` | Дерево значений | Должен содержать `<Columns>` |
| `v8:UUID` | Уникальный идентификатор | — |
| `cfg:ExternalDataProcessorObject.<Имя>` | Объект обработки (основной реквизит) | `<MainAttribute>true</MainAttribute>` |
| `cfg:CatalogRef.<Имя>` | Ссылка на справочник | — |
| `xmlns:mxl="http://v8.1c.ru/8.2/data/spreadsheet"` `mxl:SpreadsheetDocument` | Табличный документ | Требует дополнительное объявление namespace `mxl` |

> **ВАЖНО**: Для коллекций (ValueTable, ValueTree) тип **обязателен**. Пустой `<Type/>` приведёт к ошибке «Неверный путь к данным» при обращении к колонкам через DataPath.

#### Коллекции: ValueTable и ValueTree

```xml
<Attribute name="ТаблицаРеквизитов" id="8">
    <Title>...</Title>
    <Type>
        <v8:Type>v8:ValueTable</v8:Type>
    </Type>
    <Columns>
        <Column name="Пометка" id="1">
            <Title>...</Title>
            <Type>
                <v8:Type>xs:boolean</v8:Type>
            </Type>
        </Column>
        <Column name="ИмяРеквизита" id="2">
            <Title>...</Title>
            <Type>
                <v8:Type>xs:string</v8:Type>
                <v8:StringQualifiers>
                    <v8:Length>150</v8:Length>
                    <v8:AllowedLength>Variable</v8:AllowedLength>
                </v8:StringQualifiers>
            </Type>
        </Column>
    </Columns>
</Attribute>
```

Для дерева — `v8:ValueTree`, структура аналогична.

#### Основной реквизит (Объект)

Связывает форму с объектом обработки. Обязателен для доступа к табличным частям и модулю объекта.

```xml
<Attribute name="Объект" id="20">
    <Type>
        <v8:Type>cfg:ExternalDataProcessorObject.<ИмяОбработки></v8:Type>
    </Type>
    <MainAttribute>true</MainAttribute>
</Attribute>
```

### 6.5. Команды формы (`<Commands>`)

```xml
<Command name="Построить" id="1">
    <Title>
        <v8:item>
            <v8:lang>ru</v8:lang>
            <v8:content>Построить</v8:content>
        </v8:item>
    </Title>
    <ToolTip>
        <v8:item>
            <v8:lang>ru</v8:lang>
            <v8:content>Построить ER-диаграмму</v8:content>
        </v8:item>
    </ToolTip>
    <Action>КомандаПостроить</Action>
    <CurrentRowUse>DontUse</CurrentRowUse>
</Command>
```

Команда привязывается к кнопке через `CommandName`:
```xml
<Button ...>
    <CommandName>Form.Command.Построить</CommandName>
</Button>
```

### 6.6. События формы и элементов

#### События формы

```xml
<Events>
    <Event name="OnCreateAtServer">ПриСозданииНаСервере</Event>
    <Event name="OnOpen">ПриОткрытии</Event>
</Events>
```

#### События элементов (внутри элемента)

```xml
<Events>
    <Event name="OnChange">ДеревоМетаданныхПометкаПриИзменении</Event>
    <Event name="OnActivateRow">ДеревоМетаданныхПриАктивизацииСтроки</Event>
</Events>
```

| Имя события | Описание |
|-------------|----------|
| `OnCreateAtServer` | При создании на сервере (форма) |
| `OnOpen` | При открытии (форма) |
| `OnChange` | При изменении (элементы ввода, флажки) |
| `OnActivateRow` | При активизации строки (дерево, таблица) |
| `OnEditEnd` | При окончании редактирования (таблица) |

## 7. Модули BSL

### 7.1. Модуль объекта (`ObjectModule.bsl`)

Серверная логика без контекста формы. Доступен через `РеквизитФормыВЗначение("Объект")`.

```bsl
// Экспортные функции — API объекта
Функция ПолучитьДанные() Экспорт
    // ...
КонецФункции
```

### 7.2. Модуль формы (`Module.bsl`)

Обработчики событий формы, элементов и команд.

Директивы компиляции:
- `&НаСервере` — выполняется на сервере, есть доступ к реквизитам формы
- `&НаКлиенте` — выполняется на клиенте
- `&НаСервереБезКонтекста` — на сервере без контекста формы

```bsl
#Область ОбработчикиСобытийФормы

&НаСервере
Процедура ПриСозданииНаСервере(Отказ, СтандартнаяОбработка)
    ОбъектОбработки = РеквизитФормыВЗначение("Объект");
    // ... вызовы функций модуля объекта
КонецПроцедуры

#КонецОбласти
```

## 8. Генерация UUID

Все UUID в XML-файлах должны быть валидными UUID v4. Формат: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.

При генерации нового проекта каждый UUID должен быть уникальным. UUID используются для:
- Идентификации объекта обработки (`ExternalDataProcessor uuid`)
- Внутренних типов (`ContainedObject`, `GeneratedType`)
- Форм (`Form uuid`)
- Макетов (`Template uuid`)
- Табличных частей и их реквизитов

## 9. Известные ошибки и подводные камни

### «Неверный путь к данным» для колонок таблицы

**Проблема**: При загрузке формы конфигуратор выдаёт ошибку «Неверный путь к данным: <Реквизит>.<Колонка>» для всех колонок таблицы.

**Причина**: Реквизит формы с колонками (`<Columns>`) не имеет правильного типа. Для коллекций тип обязателен:
- `v8:ValueTable` для таблиц
- `v8:ValueTree` для деревьев

**Неправильно**:
```xml
<Attribute name="МояТаблица" id="1">
    <Type/>                              <!-- ОШИБКА: тип пустой -->
    <Columns>...</Columns>
</Attribute>
```

**Правильно**:
```xml
<Attribute name="МояТаблица" id="1">
    <Type>
        <v8:Type>v8:ValueTable</v8:Type>  <!-- Тип обязателен -->
    </Type>
    <Columns>...</Columns>
</Attribute>
```

### BOM в файлах метаданных

Файлы метаданных (корневой XML, формы, макеты), выгруженные конфигуратором, содержат BOM (Byte Order Mark, `\xEF\xBB\xBF`) в начале. Файл `Form.xml` (описание формы) и `.bsl`-модули — **без BOM**. При ручном создании файлов рекомендуется следовать этому же правилу, хотя конфигуратор принимает файлы и без BOM.

### Кодировка

Все файлы — UTF-8. XML-файлы имеют заголовок `<?xml version="1.0" encoding="UTF-8"?>`.

## 10. Чеклист для создания новой обработки

1. Сгенерировать UUID для каждого объекта (обработка, формы, макеты, ТЧ)
2. Создать структуру каталогов (раздел 1)
3. Создать корневой XML (раздел 3) с правильными ChildObjects
4. Для каждой формы:
   - Создать `<Имя>.xml` (раздел 4)
   - Создать `Form.xml` (раздел 6) — проверить пространство имён!
   - Создать `Module.bsl` (раздел 7.2)
5. Для каждого макета:
   - Создать `<Имя>.xml` (раздел 5) с правильным TemplateType
   - Создать тело макета (`Template.<расш>`)
6. При необходимости создать `ObjectModule.bsl` (раздел 7.1)
7. Проверить:
   - Все `<Type>` для коллекций содержат `v8:ValueTable` / `v8:ValueTree`
   - Все `DataPath` корректны (особенно для колонок таблиц)
   - Все элементы имеют `ExtendedTooltip`
   - Все ID уникальны в пределах своих секций
   - `DefaultForm` в корневом файле соответствует реальному имени формы
