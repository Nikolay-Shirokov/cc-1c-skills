# 1C Form.xml Format Specification

Спецификация формата управляемых форм 1С:Предприятие 8.3 (version 2.17).
Составлена на основе анализа 7723 форм конфигурации «Бухгалтерия предприятия 3.0.180».

---

## 0. Файловая структура и регистрация

### Файлы формы

Каждая форма объекта конфигурации состоит из 3 файлов:

```
<Объект>/Forms/
  ИмяФормы.xml                  ← метаданные (UUID, имя, синоним, FormType)
  ИмяФормы/
    Ext/
      Form.xml                   ← определение формы (описано в разделах 1–17)
      Form/
        Module.bsl               ← модуль формы (1С-код)
```

Общие формы (CommonForm) — аналогично, но на верхнем уровне конфигурации:

```
CommonForms/
  ИмяФормы.xml                  ← метаданные (тег <CommonForm>)
  ИмяФормы/
    Ext/
      Form.xml
      Form/
        Module.bsl
```

### Метаданные формы — шаблон

#### Форма объекта (Document, Catalog, DataProcessor, Report, ...)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"
		xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
		xmlns:v8="http://v8.1c.ru/8.1/data/core"
		xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
		xmlns:xs="http://www.w3.org/2001/XMLSchema"
		xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		version="2.17">
	<Form uuid="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX">
		<Properties>
			<Name>ИмяФормы</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>Отображаемое имя</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<FormType>Managed</FormType>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
				<v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>
			</UsePurposes>
		</Properties>
	</Form>
</MetaDataObject>
```

#### CommonForm

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"
		xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
		xmlns:v8="http://v8.1c.ru/8.1/data/core"
		xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
		xmlns:xs="http://www.w3.org/2001/XMLSchema"
		xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		version="2.17">
	<CommonForm uuid="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX">
		<Properties>
			<Name>ИмяФормы</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>Отображаемое имя</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<FormType>Managed</FormType>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<UseStandardCommands>false</UseStandardCommands>
			<ExtendedPresentation/>
			<Explanation/>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
				<v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>
			</UsePurposes>
		</Properties>
	</CommonForm>
</MetaDataObject>
```

### Регистрация формы

#### В ChildObjects родительского объекта

```xml
<!-- В файле Documents/АвансовыйОтчет.xml (или Catalogs/Контрагенты.xml и т.д.) -->
<ChildObjects>
	<Form>ФормаДокумента</Form>
	<Form>ФормаСписка</Form>
	...
</ChildObjects>
```

CommonForms регистрируются в `Configuration.xml`:

```xml
<ChildObjects>
	<CommonForm>ИмяФормы</CommonForm>
	...
</ChildObjects>
```

#### DefaultForm в Properties родительского объекта

Формат значения: `ТипОбъекта.ИмяОбъекта.Form.ИмяФормы`

```xml
<Properties>
	<DefaultObjectForm>Document.АвансовыйОтчет.Form.ФормаДокумента</DefaultObjectForm>
	<DefaultListForm>Document.АвансовыйОтчет.Form.ФормаСписка</DefaultListForm>
	<DefaultChoiceForm>Document.АвансовыйОтчет.Form.ФормаВыбора</DefaultChoiceForm>
</Properties>
```

#### Свойства DefaultForm по типам объектов

| Тип объекта | Свойства DefaultForm |
|-------------|---------------------|
| Document | DefaultObjectForm, DefaultListForm, DefaultChoiceForm |
| Catalog | DefaultObjectForm, DefaultFolderForm, DefaultListForm, DefaultChoiceForm, DefaultFolderChoiceForm |
| ChartOfCharacteristicTypes | DefaultObjectForm, DefaultFolderForm, DefaultListForm, DefaultChoiceForm, DefaultFolderChoiceForm |
| ChartOfAccounts | DefaultObjectForm, DefaultListForm, DefaultChoiceForm |
| DataProcessor | DefaultForm |
| Report | DefaultForm |
| InformationRegister | DefaultRecordForm, DefaultListForm |
| ExchangePlan | DefaultObjectForm, DefaultListForm, DefaultChoiceForm |
| BusinessProcess | DefaultObjectForm, DefaultListForm, DefaultChoiceForm |
| Task | DefaultObjectForm, DefaultListForm, DefaultChoiceForm |
| CommonForm | — (регистрируется в Configuration.xml, нет DefaultForm) |

> Report.DefaultForm может указывать на общую форму: `CommonForm.ФормаОтчета`.

---

## 1. Корневой элемент

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform"
      xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
      xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"
      xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
      xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema"
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
  ...
</Form>
```

Все 17 namespace-деклараций **идентичны** во всех формах конфигурации. Атрибут `version` всегда `"2.17"`.

### Назначение namespace-префиксов

| Префикс | URI | Назначение |
|---------|-----|------------|
| _(default)_ | `http://v8.1c.ru/8.3/xcf/logform` | Основная схема формы |
| `v8` | `http://v8.1c.ru/8.1/data/core` | Базовые типы данных (Type, item, lang, content) |
| `v8ui` | `http://v8.1c.ru/8.1/data/ui` | UI-типы (Color, Font, Border, FormattedString) |
| `cfg` | `http://v8.1c.ru/8.1/data/enterprise/current-config` | Ссылки на объекты конфигурации (CatalogRef, DocumentRef) |
| `xr` | `http://v8.1c.ru/8.3/xcf/readable` | Читаемый формат (Ref, Item, LoadTransparent) |
| `style` | `http://v8.1c.ru/8.1/data/ui/style` | Стили оформления (FormBackColor и т.д.) |
| `web` | `http://v8.1c.ru/8.1/data/ui/colors/web` | Web-цвета |
| `win` | `http://v8.1c.ru/8.1/data/ui/colors/windows` | Windows-цвета |
| `sys` | `http://v8.1c.ru/8.1/data/ui/fonts/system` | Системные шрифты |
| `xs` | `http://www.w3.org/2001/XMLSchema` | XML Schema |
| `xsi` | `http://www.w3.org/2001/XMLSchema-instance` | XML Schema Instance |
| `app` | `http://v8.1c.ru/8.2/managed-application/core` | Ядро управляемого приложения |
| `lf` | `http://v8.1c.ru/8.2/managed-application/logform` | Формы управляемого приложения |
| `dcscor` | `http://v8.1c.ru/8.1/data-composition-system/core` | СКД — ядро |
| `dcssch` | `http://v8.1c.ru/8.1/data-composition-system/schema` | СКД — схема |
| `dcsset` | `http://v8.1c.ru/8.1/data-composition-system/settings` | СКД — настройки |
| `ent` | `http://v8.1c.ru/8.1/data/enterprise` | Данные предприятия |

---

## 2. Структура Form — порядок дочерних элементов

```
<Form>
  ┌─ Свойства формы (необязательные, в произвольном порядке)
  ├─ <CommandSet>           — исключённые стандартные команды
  ├─ <AutoCommandBar>       — главная командная панель (обязательный, id="-1")
  ├─ <Events>               — обработчики событий формы
  ├─ <ChildItems>           — дерево UI-элементов
  ├─ <Attributes>           — реквизиты формы
  ├─ <Parameters>           — параметры открытия формы
  └─ <Commands>             — пользовательские команды
</Form>
```

---

## 3. Свойства формы

Прямые дочерние элементы `<Form>` (все необязательные, указываются до `<CommandSet>`/`<AutoCommandBar>`):

### Общие свойства (все типы форм)

| Элемент | Тип | Значения | Описание |
|---------|-----|----------|----------|
| `<Title>` | multilang | — | Заголовок формы |
| `<Width>` | int | 60, 67... | Ширина формы в символах |
| `<Height>` | int | — | Высота формы в символах |
| `<Group>` | enum | `Vertical`, `Horizontal`, `AlwaysHorizontal`, `AlwaysVertical` | Направление размещения |
| `<WindowOpeningMode>` | enum | `LockOwnerWindow`, `Modeless` | Режим открытия окна |
| `<EnterKeyBehavior>` | enum | `DefaultButton`, `NewLine` | Действие по Enter |
| `<AutoTitle>` | bool | `true`/`false` | Автозаголовок |
| `<AutoURL>` | bool | `true`/`false` | Авто-URL |
| `<AutoFillCheck>` | bool | `true`/`false` | Автопроверка заполнения |
| `<Customizable>` | bool | `true`/`false` | Разрешить настройку |
| `<CommandBarLocation>` | enum | `Top`, `Bottom`, `None` | Расположение панели команд |
| `<VerticalScroll>` | enum | `useIfNecessary`, `Auto`, `AlwaysShow`, `Never` | Вертикальная прокрутка |
| `<ScalingMode>` | enum | — | Режим масштабирования |

### Свойства сохранения данных (DataProcessors)

| Элемент | Значения | Описание |
|---------|----------|----------|
| `<SaveDataInSettings>` | `UseList`, `Use`, `DontUse` | Сохранять данные в настройках |
| `<AutoSaveDataInSettings>` | `Use`, `DontUse` | Автосохранение |

### Свойства документов (Documents)

| Элемент | Значения | Описание |
|---------|----------|----------|
| `<AutoTime>` | `CurrentOrLast`, `Current`, `Last` | Управление временем документа |
| `<UsePostingMode>` | `Auto`, `Postings`, `Movements` | Режим проведения |
| `<RepostOnWrite>` | `true`/`false` | Перепроведение при записи |

### Свойства справочников (Catalogs, ChartsOfAccounts)

| Элемент | Значения | Описание |
|---------|----------|----------|
| `<UseForFoldersAndItems>` | `Folders`, `Items`, `FoldersAndItems` | Назначение формы |

### Свойства отчётов (Reports)

| Элемент | Значения | Описание |
|---------|----------|----------|
| `<ReportResult>` | string | Имя реквизита результата (`Результат`) |
| `<DetailsData>` | string | Имя реквизита расшифровки (`ДанныеРасшифровки`) |
| `<ReportFormType>` | `Main`, `Settings`, `Choice` | Тип формы отчёта |
| `<AutoShowState>` | `Auto`, `Show`, `Hide` | Автоотображение состояния |
| `<ReportResultViewMode>` | `Auto`, `Table`, `Spreadsheet` | Режим отображения результата |
| `<ViewModeApplicationOnSetReportResult>` | `Auto`, `Always`, `Never` | Применение режима |

### Мобильные свойства

| Элемент | Описание |
|---------|----------|
| `<MobileDeviceCommandBarContent>` | Конфигурация панели команд мобильного устройства |

### Матрица свойств по типам форм

| Свойство | CommonForm | Document | Catalog | Report | DataProcessor | InfoRegister |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|
| Title | + | + | + | + | + | + |
| Width | — | — | + | — | + | — |
| WindowOpeningMode | + | + | + | — | + | — |
| AutoTitle | + | + | + | + | + | + |
| CommandBarLocation | + | + | + | + | + | + |
| AutoTime | — | + | — | — | — | — |
| UsePostingMode | — | + | — | — | — | — |
| UseForFoldersAndItems | — | — | + | — | — | — |
| ReportResult | — | — | — | + | — | — |
| SaveDataInSettings | — | — | — | — | + | — |

---

## 4. CommandSet — исключённые команды

```xml
<CommandSet>
  <ExcludedCommand>CommandName</ExcludedCommand>
  ...
</CommandSet>
```

### Стандартные команды диалогов

`OK`, `Cancel`, `Yes`, `No`, `Abort`, `Retry`, `Ignore`, `Help`, `SaveValues`, `RestoreValues`

### Стандартные команды объектов

`Copy`, `Delete`, `SetDeletionMark`, `CreateInitialImage`, `ReadChanges`, `WriteChanges`

### Команды отчётов

`CustomizeForm`

---

## 5. AutoCommandBar — главная панель команд

Всегда присутствует. Фиксированные `name="ФормаКоманднаяПанель"` и `id="-1"`.

```xml
<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
  <HorizontalAlign>Right</HorizontalAlign>    <!-- Left | Center | Right -->
  <Autofill>false</Autofill>                  <!-- true | false -->
  <EnableContentChange>true</EnableContentChange>  <!-- optional -->
  <ChildItems>
    <!-- Button, ButtonGroup, Popup -->
  </ChildItems>
</AutoCommandBar>
```

Может быть пустым (самозакрывающийся тег) или содержать `<ChildItems>` с кнопками.

---

## 6. Events — обработчики событий формы

```xml
<Events>
  <Event name="EventName">ИмяОбработчика</Event>
  ...
</Events>
```

### Все события формы

| Имя события | Контекст | Описание |
|-------------|----------|----------|
| `OnCreateAtServer` | Сервер | Создание формы на сервере (инициализация) |
| `OnOpen` | Клиент | Открытие формы на клиенте |
| `BeforeClose` | Клиент | Перед закрытием формы |
| `OnClose` | Клиент | При закрытии формы |
| `AfterWrite` | Клиент | После записи объекта |
| `BeforeWrite` | Клиент | Перед записью объекта |
| `BeforeWriteAtServer` | Сервер | Перед записью на сервере |
| `OnWriteAtServer` | Сервер | При записи на сервере |
| `AfterWriteAtServer` | Сервер | После записи на сервере |
| `OnReadAtServer` | Сервер | При чтении объекта |
| `NotificationProcessing` | Клиент | Обработка межформенных оповещений |
| `ChoiceProcessing` | Клиент | Обработка результата выбора |
| `NewWriteProcessing` | Сервер | Создание нового объекта |
| `FillCheckProcessingAtServer` | Сервер | Проверка заполнения |
| `OnLoadUserSettingsAtServer` | Сервер | Загрузка пользовательских настроек (отчёты) |
| `OnSaveUserSettingsAtServer` | Сервер | Сохранение пользовательских настроек (отчёты) |
| `URLProcessing` | Клиент | Обработка навигационных ссылок |

### Типичные комбинации по типам форм

**Диалог:** `OnCreateAtServer` + `OnOpen`

**Документ:** `OnCreateAtServer` + `OnOpen` + `BeforeWriteAtServer` + `OnWriteAtServer` + `AfterWrite`

**Справочник:** `OnCreateAtServer` + `OnOpen` + `OnReadAtServer` + `BeforeWriteAtServer` + `AfterWrite` + `NotificationProcessing`

**Отчёт:** `OnCreateAtServer` + `OnOpen` + `BeforeClose` + `OnClose` + `OnLoadUserSettingsAtServer` + `OnSaveUserSettingsAtServer` + `NotificationProcessing` + `ChoiceProcessing` + `URLProcessing`

---

## 7. ChildItems — дерево UI-элементов

### 7.1. Иерархия вложенности

```
ChildItems
├── UsualGroup          → содержит любые элементы
│   └── ChildItems
├── Pages               → содержит только Page
│   └── ChildItems
│       └── Page        → содержит любые элементы
│           └── ChildItems
├── Table               → содержит колонки (InputField, LabelField, CheckBoxField, PictureField)
│   └── ChildItems
├── CommandBar          → содержит Button, ButtonGroup, Popup
│   └── ChildItems
├── InputField          (лист)
├── LabelField          (лист)
├── CheckBoxField       (лист)
├── LabelDecoration     (лист)
├── PictureDecoration   (лист)
├── PictureField        (лист)
├── CalendarField       (лист)
└── Button              (лист)
```

### 7.2. Общие свойства всех элементов

Каждый UI-элемент имеет атрибуты `name` (string) и `id` (int). Кроме того, большинство элементов поддерживают:

| Свойство | Тип | Описание |
|----------|-----|----------|
| `<Title>` | multilang | Заголовок |
| `<ToolTip>` | multilang | Подсказка |
| `<Visible>` | bool | Видимость |
| `<Enabled>` | bool | Доступность |
| `<ReadOnly>` | bool | Только чтение |
| `<Width>` | int | Ширина |
| `<Height>` | int | Высота |
| `<HorizontalStretch>` | bool | Растягивание по горизонтали |
| `<VerticalStretch>` | bool | Растягивание по вертикали |
| `<HorizontalAlign>` | enum | `Left` / `Center` / `Right` |
| `<VerticalAlign>` | enum | `Top` / `Center` / `Bottom` |
| `<GroupHorizontalAlign>` | enum | Горизонтальное выравнивание в группе |
| `<GroupVerticalAlign>` | enum | Вертикальное выравнивание в группе |
| `<SkipOnInput>` | bool | Пропускать при вводе |
| `<ContextMenu>` | ref | Контекстное меню (name + id) |
| `<ExtendedTooltip>` | ref | Расширенная подсказка (name + id) |
| `<Events>` | block | Обработчики событий элемента |

### 7.3. Мультиязычный формат (multilang)

```xml
<Title>
  <v8:item>
    <v8:lang>ru</v8:lang>
    <v8:content>Текст на русском</v8:content>
  </v8:item>
</Title>
```

Атрибут `formatted="true"` на `<Title>` означает форматированную строку.

---

## 8. Типы UI-элементов — полное описание

### 8.1. UsualGroup — группа элементов

Основной контейнер для компоновки. Используется в ~90% форм.

```xml
<UsualGroup name="..." id="...">
  <!-- Компоновка -->
  <Group>Vertical | Horizontal | AlwaysHorizontal | AlwaysVertical</Group>
  <Behavior>Usual | Collapsible | CommandBar</Behavior>
  <Representation>None | NormalSeparation | WeakSeparation | StrongSeparation</Representation>
  <ShowTitle>true | false</ShowTitle>
  <United>true | false</United>

  <!-- Расположение дочерних -->
  <ChildItemsWidth>LeftWidest | RightWidest | Equal</ChildItemsWidth>
  <HorizontalSpacing>Single | Half | Double</HorizontalSpacing>
  <VerticalSpacing>Single | Half | Double</VerticalSpacing>
  <ThroughAlign>Use | DontUse</ThroughAlign>

  <!-- Внешний вид -->
  <BackColor>style:... | web:... | win:...</BackColor>
  <TextColor>style:...</TextColor>
  <TitleTextColor>style:...</TitleTextColor>
  <EnableContentChange>true | false</EnableContentChange>
  <ControlRepresentation>Picture | Text</ControlRepresentation>

  <ChildItems>...</ChildItems>
</UsualGroup>
```

### 8.2. InputField — поле ввода

Основной элемент ввода данных. Используется в ~80% форм.

```xml
<InputField name="..." id="...">
  <DataPath>Объект.Организация</DataPath>

  <!-- Заголовок -->
  <TitleLocation>Left | Right | Top | Bottom | None</TitleLocation>
  <TitleHeight>N</TitleHeight>
  <TitleWidth>N</TitleWidth>

  <!-- Размеры -->
  <AutoMaxWidth>true | false</AutoMaxWidth>
  <AutoMaxHeight>true | false</AutoMaxHeight>

  <!-- Режим редактирования -->
  <EditMode>Enter | EnterOnInput</EditMode>
  <MultiLine>true | false</MultiLine>
  <Wrap>true | false</Wrap>
  <ExtendedEdit>true | false</ExtendedEdit>
  <PasswordMode>true | false</PasswordMode>
  <DefaultItem>true | false</DefaultItem>

  <!-- Кнопки -->
  <ChoiceButton>true | false</ChoiceButton>
  <ChoiceButtonRepresentation>ShowInInputField | ShowInToolbar | Auto</ChoiceButtonRepresentation>
  <OpenButton>true | false</OpenButton>
  <ClearButton>true | false</ClearButton>
  <SpinButton>true | false</SpinButton>
  <CreateButton>true | false</CreateButton>
  <DropListButton>true | false</DropListButton>
  <TextEdit>true | false</TextEdit>
  <ListChoiceMode>true | false</ListChoiceMode>

  <!-- Автозаполнение и проверка -->
  <AutoMarkIncomplete>true | false</AutoMarkIncomplete>
  <MarkIncomplete>true | false</MarkIncomplete>
  <AutoComplete>true | false</AutoComplete>
  <QuickChoice>true | false</QuickChoice>
  <ChoiceHistoryOnInput>Auto | Never | Always</ChoiceHistoryOnInput>

  <!-- Подсказка ввода -->
  <InputHint>
    <v8:item>
      <v8:lang>ru</v8:lang>
      <v8:content>Placeholder text</v8:content>
    </v8:item>
  </InputHint>
  <Mask>маска ввода</Mask>

  <!-- Параметры выбора -->
  <ChoiceFoldersAndItems>Items | Folders | FoldersAndItems</ChoiceFoldersAndItems>
  <ChoiceParameters>
    <v8:Parameter>
      <v8:Name>name</v8:Name>
      <v8:Value>value</v8:Value>
    </v8:Parameter>
  </ChoiceParameters>

  <!-- Стилизация -->
  <TextColor>style:... | web:... | win:...</TextColor>
  <BackColor>style:... | web:... | win:...</BackColor>
  <BorderColor>style:... | web:... | win:...</BorderColor>
  <Font>...</Font>

  <!-- События -->
  <Events>
    <Event name="OnChange">...</Event>
    <Event name="StartChoice">...</Event>
    <Event name="ChoiceProcessing">...</Event>
    <Event name="Clearing">...</Event>
    <Event name="AutoComplete">...</Event>
    <Event name="TextEditEnd">...</Event>
    <Event name="Opening">...</Event>
    <Event name="OnEditEnd">...</Event>
    <Event name="DragCheck">...</Event>
    <Event name="Drag">...</Event>
    <Event name="DragStart">...</Event>
  </Events>
</InputField>
```

### 8.3. Button — кнопка

```xml
<Button name="..." id="...">
  <Type>CommandBarButton | UsualButton | Hyperlink</Type>
  <CommandName>Form.Command.Name | Form.StandardCommand.Name | CommonCommand.Name</CommandName>
  <DataPath>Attribute</DataPath>

  <Picture>
    <xr:Ref>StdPicture.Name | CommonPicture.Name</xr:Ref>
    <xr:LoadTransparent>true | false</xr:LoadTransparent>
  </Picture>
  <Representation>Auto | Picture | Text | PictureAndText</Representation>
  <ShapeRepresentation>Auto | None | Button</ShapeRepresentation>

  <DefaultButton>true | false</DefaultButton>
  <LocationInCommandBar>InCommandBar | InAdditionalSubmenu | InCommandBarAndInAdditionalSubmenu | Auto</LocationInCommandBar>
  <OnlyInAllActions>true | false</OnlyInAllActions>

  <Events>
    <Event name="Click">...</Event>
  </Events>
</Button>
```

### 8.4. Table — таблица

```xml
<Table name="..." id="...">
  <DataPath>ТабличныйРеквизит</DataPath>
  <RowPictureDataPath>ТабличныйРеквизит.Иконка</RowPictureDataPath>
  <RowsPicture>
    <xr:Ref>CommonPicture.Name</xr:Ref>
  </RowsPicture>

  <!-- Отображение -->
  <Representation>List | Tree | HierarchicalList</Representation>
  <TitleLocation>Top | None</TitleLocation>
  <HeightInTableRows>N</HeightInTableRows>
  <Header>true | false</Header>
  <Footer>true | false</Footer>
  <HorizontalLines>true | false</HorizontalLines>
  <VerticalLines>true | false</VerticalLines>
  <UseAlternationRowColor>true | false</UseAlternationRowColor>

  <!-- Редактирование -->
  <SelectionMode>SingleRow | MultiRow</SelectionMode>
  <ChangeRowSet>true | false</ChangeRowSet>
  <ChangeRowOrder>true | false</ChangeRowOrder>
  <AutoInsertNewRow>true | false</AutoInsertNewRow>

  <!-- Панели -->
  <CommandBarLocation>None | Top | Bottom | Auto</CommandBarLocation>
  <SearchStringLocation>None | Top | Bottom | CommandBar | Auto</SearchStringLocation>
  <ViewStatusLocation>Top | Bottom | None</ViewStatusLocation>
  <SearchControlLocation>Top | Bottom | Auto</SearchControlLocation>

  <!-- D&D -->
  <EnableStartDrag>true | false</EnableStartDrag>
  <EnableDrag>true | false</EnableDrag>
  <FileDragMode>AsFile | AsFileRef</FileDragMode>

  <!-- Дерево -->
  <TopLevelParent xsi:nil="true"/>
  <ShowRoot>true | false</ShowRoot>
  <AllowRootChoice>true | false</AllowRootChoice>
  <ChoiceFoldersAndItems>Items | Folders | FoldersAndItems</ChoiceFoldersAndItems>

  <!-- Обновление -->
  <AutoRefresh>true | false</AutoRefresh>
  <AutoRefreshPeriod>seconds</AutoRefreshPeriod>
  <UpdateOnDataChange>Auto | DontUpdate</UpdateOnDataChange>

  <!-- Исключённые команды таблицы -->
  <CommandSet>
    <ExcludedCommand>...</ExcludedCommand>
  </CommandSet>

  <!-- Служебные элементы -->
  <ContextMenu name="..." id="..."/>
  <AutoCommandBar name="..." id="..."/>
  <SearchStringAddition name="..." id="..."/>
  <ViewStatusAddition name="..." id="..."/>
  <SearchControlAddition name="..." id="..."/>

  <!-- Колонки -->
  <ChildItems>
    <!-- InputField, LabelField, CheckBoxField, PictureField -->
  </ChildItems>

  <!-- События -->
  <Events>
    <Event name="Selection">...</Event>
    <Event name="OnActivateRow">...</Event>
    <Event name="BeforeRowChange">...</Event>
    <Event name="BeforeAddRow">...</Event>
    <Event name="BeforeDeleteRow">...</Event>
    <Event name="AfterDeleteRow">...</Event>
    <Event name="DragStart">...</Event>
    <Event name="Drag">...</Event>
    <Event name="DragCheck">...</Event>
    <Event name="Drop">...</Event>
  </Events>
</Table>
```

### 8.5. Pages / Page — вкладки

```xml
<Pages name="..." id="...">
  <PagesRepresentation>None | TabsOnTop | TabsOnBottom | TabsOnLeft | TabsOnRight</PagesRepresentation>

  <Events>
    <Event name="OnCurrentPageChange">...</Event>
  </Events>

  <ChildItems>
    <Page name="..." id="...">
      <Title>...</Title>
      <Picture>
        <xr:Ref>StdPicture.Name</xr:Ref>
      </Picture>
      <ShowTitle>true | false</ShowTitle>
      <ChildItemsWidth>LeftWidest | RightWidest | Equal</ChildItemsWidth>

      <ChildItems>
        <!-- Любые UI-элементы -->
      </ChildItems>
    </Page>
  </ChildItems>
</Pages>
```

### 8.6. CommandBar — командная панель

```xml
<CommandBar name="..." id="...">
  <CommandSource>Form | FormCommandPanelGlobalCommands</CommandSource>
  <Autofill>true | false</Autofill>
  <EnableContentChange>true | false</EnableContentChange>
  <HorizontalLocation>Left | Right</HorizontalLocation>
  <VerticalLocation>Top | Bottom</VerticalLocation>

  <ChildItems>
    <!-- Button, ButtonGroup, Popup -->
  </ChildItems>
</CommandBar>
```

### 8.7. ButtonGroup — группа кнопок

```xml
<ButtonGroup name="..." id="...">
  <Representation>Auto | Compact | Separate</Representation>
  <CommandSource>Form | FormCommandPanelGlobalCommands | CommandPanel</CommandSource>

  <ChildItems>
    <!-- Button, ButtonGroup -->
  </ChildItems>
</ButtonGroup>
```

### 8.8. Popup — выпадающее меню

```xml
<Popup name="..." id="...">
  <Picture>
    <xr:Ref>StdPicture.Print</xr:Ref>
    <xr:LoadTransparent>true</xr:LoadTransparent>
  </Picture>
  <Representation>Auto | Picture | Text | PictureAndText</Representation>
  <ShapeRepresentation>Auto | None | Button</ShapeRepresentation>
  <LocationInCommandBar>InCommandBar | InAdditionalSubmenu | Auto</LocationInCommandBar>

  <ChildItems>
    <!-- Button, ButtonGroup, Popup -->
  </ChildItems>
</Popup>
```

### 8.9. LabelDecoration — декоративная надпись

```xml
<LabelDecoration name="..." id="...">
  <Title formatted="true">...</Title>
  <AutoMaxWidth>true | false</AutoMaxWidth>
  <AutoMaxHeight>true | false</AutoMaxHeight>
  <Hyperlink>true | false</Hyperlink>
  <ToolTipRepresentation>Auto | Button | None</ToolTipRepresentation>

  <TextColor>style:... | web:... | win:...</TextColor>
  <BackColor>style:... | web:... | win:...</BackColor>
  <Font>...</Font>
  <Border width="N">
    <v8ui:style xsi:type="v8ui:ControlBorderType">WithoutBorder | WithBorder</v8ui:style>
  </Border>

  <Events>
    <Event name="Click">...</Event>
  </Events>
</LabelDecoration>
```

### 8.10. LabelField — поле надписи (привязанное к данным)

```xml
<LabelField name="..." id="...">
  <DataPath>Реквизит.Свойство</DataPath>
  <TitleLocation>Left | Right | Top | Bottom | None</TitleLocation>
  <TitleTextColor>style:...</TitleTextColor>
  <PasswordMode>true | false</PasswordMode>
  <Hyperlink>true | false</Hyperlink>

  <TextColor>style:... | web:... | win:...</TextColor>
  <BackColor>style:... | web:... | win:...</BackColor>
  <Font>...</Font>

  <Events>
    <Event name="Click">...</Event>
    <Event name="URLProcessing">...</Event>
  </Events>
</LabelField>
```

### 8.11. CheckBoxField — флажок

```xml
<CheckBoxField name="..." id="...">
  <DataPath>Реквизит.Свойство</DataPath>
  <TitleLocation>Left | Right | Top | Bottom | None</TitleLocation>
  <CheckBoxType>Auto | Checkbox | Tumbler</CheckBoxType>
  <EditMode>Enter | EnterOnInput</EditMode>

  <Events>
    <Event name="OnChange">...</Event>
  </Events>
</CheckBoxField>
```

### 8.12. PictureDecoration — декоративная картинка

```xml
<PictureDecoration name="..." id="...">
  <Picture>
    <xr:Ref>StdPicture.Name | CommonPicture.Name</xr:Ref>
    <xr:LoadTransparent>true | false</xr:LoadTransparent>
  </Picture>
  <Zoomable>true | false</Zoomable>
  <NonselectedPictureText>текст</NonselectedPictureText>
  <Hyperlink>true | false</Hyperlink>
  <FileDragMode>AsFile | AsFileRef</FileDragMode>
  <DisplayImportance>Auto | VeryLow | Low | Normal | High | VeryHigh</DisplayImportance>

  <Border width="N">
    <v8ui:style xsi:type="v8ui:ControlBorderType">WithoutBorder | WithBorder</v8ui:style>
  </Border>

  <Events>
    <Event name="Click">...</Event>
  </Events>
</PictureDecoration>
```

### 8.13. PictureField — поле картинки (привязанное к данным)

```xml
<PictureField name="..." id="...">
  <DataPath>Реквизит.Свойство</DataPath>
  <TitleLocation>Left | Right | Top | Bottom | None</TitleLocation>
  <ValuesPicture>
    <xr:Ref>CommonPicture.Name</xr:Ref>
  </ValuesPicture>
  <Zoomable>true | false</Zoomable>
  <NonselectedPictureText>текст</NonselectedPictureText>
  <FileDragMode>AsFile | AsFileRef</FileDragMode>

  <Border width="N">
    <v8ui:style xsi:type="v8ui:ControlBorderType">WithoutBorder | WithBorder</v8ui:style>
  </Border>

  <Events>
    <Event name="Click">...</Event>
    <Event name="StartDrag">...</Event>
    <Event name="DragCheck">...</Event>
    <Event name="Drag">...</Event>
  </Events>
</PictureField>
```

### 8.14. CalendarField — календарь

```xml
<CalendarField name="..." id="...">
  <DataPath>Реквизит.Дата</DataPath>
  <TitleLocation>Left | Right | Top | Bottom | None</TitleLocation>
  <WidthInMonths>N</WidthInMonths>
  <HeightInWeeks>N</HeightInWeeks>
  <ShowCurrentDate>true | false</ShowCurrentDate>
  <BeginOfRepresentationPeriod>date</BeginOfRepresentationPeriod>
  <EndOfRepresentationPeriod>date</EndOfRepresentationPeriod>

  <Events>
    <Event name="Selection">...</Event>
    <Event name="OnPeriodOutput">...</Event>
  </Events>
</CalendarField>
```

---

## 9. Attributes — реквизиты формы

```xml
<Attributes>
  <Attribute name="ИмяРеквизита" id="N">
    <Title>...</Title>                          <!-- multilang, необязательный -->
    <ToolTip>...</ToolTip>                      <!-- multilang, необязательный -->
    <Type>...</Type>                            <!-- определение типа -->
    <MainAttribute>true</MainAttribute>         <!-- основной реквизит формы -->
    <SavedData>true</SavedData>                 <!-- сохраняемые данные -->
    <FillChecking>Show | DontShow</FillChecking>  <!-- проверка заполнения -->
    <UseAlwaysAttributes>true</UseAlwaysAttributes>
    <Columns>...</Columns>                      <!-- для ValueTable/ValueTree -->
  </Attribute>
</Attributes>
```

### 9.1. Система типов

#### Примитивные типы (xs:*)

```xml
<!-- Строка -->
<Type>
  <v8:Type>xs:string</v8:Type>
  <v8:StringQualifiers>
    <v8:Length>100</v8:Length>              <!-- 0 = неограниченная -->
    <v8:AllowedLength>Variable</v8:AllowedLength>  <!-- Variable | Fixed -->
  </v8:StringQualifiers>
</Type>

<!-- Число -->
<Type>
  <v8:Type>xs:decimal</v8:Type>
  <v8:NumberQualifiers>
    <v8:Digits>15</v8:Digits>              <!-- всего цифр -->
    <v8:FractionDigits>2</v8:FractionDigits>  <!-- дробная часть -->
    <v8:AllowedSign>Any</v8:AllowedSign>   <!-- Any | Nonnegative -->
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
    <v8:DateFractions>Date</v8:DateFractions>  <!-- Date | Time | DateTime -->
  </v8:DateQualifiers>
</Type>

<!-- Двоичные данные -->
<Type>
  <v8:Type>xs:binary</v8:Type>
  <v8:BinaryDataQualifiers>
    <v8:Length>0</v8:Length>
    <v8:AllowedLength>Variable</v8:AllowedLength>
  </v8:BinaryDataQualifiers>
</Type>
```

#### Ссылочные типы (cfg:*)

| Шаблон | Пример | Описание |
|--------|--------|----------|
| `cfg:CatalogRef.<Имя>` | `cfg:CatalogRef.Организации` | Ссылка на элемент справочника |
| `cfg:CatalogObject.<Имя>` | `cfg:CatalogObject.Контрагенты` | Объект справочника |
| `cfg:DocumentRef.<Имя>` | `cfg:DocumentRef.СчетФактура` | Ссылка на документ |
| `cfg:DocumentObject.<Имя>` | `cfg:DocumentObject.ПроцессПокупки` | Объект документа |
| `cfg:EnumRef.<Имя>` | `cfg:EnumRef.СпособДоставки` | Ссылка на перечисление |
| `cfg:ChartOfAccountsRef.<Имя>` | `cfg:ChartOfAccountsRef.Хозрасчетный` | Ссылка на план счетов |
| `cfg:ChartOfCalculationTypesRef.<Имя>` | — | Ссылка на план видов расчёта |
| `cfg:ChartOfCharacteristicTypesRef.<Имя>` | — | Ссылка на план видов характеристик |
| `cfg:ExchangePlanRef.<Имя>` | `cfg:ExchangePlanRef.АвтономнаяРабота` | Ссылка на план обмена |
| `cfg:BusinessProcessRef.<Имя>` | — | Ссылка на бизнес-процесс |
| `cfg:TaskRef.<Имя>` | — | Ссылка на задачу |
| `cfg:InformationRegisterRecordSet.<Имя>` | — | Набор записей регистра сведений |
| `cfg:AccumulationRegisterRecordSet.<Имя>` | — | Набор записей регистра накопления |

#### Платформенные типы (v8:*)

| Тип | Описание |
|-----|----------|
| `v8:ValueListType` | Список значений |
| `v8:ValueTable` | Таблица значений |
| `v8:ValueTree` | Дерево значений |
| `v8:TypeDescription` | Описание типов |
| `v8:Universal` | Произвольный тип |
| `v8:FixedArray` | Фиксированный массив |
| `v8:FixedStructure` | Фиксированная структура |

#### UI-типы (v8ui:*)

| Тип | Описание |
|-----|----------|
| `v8ui:FormattedString` | Форматированная строка |
| `v8ui:Picture` | Картинка |
| `v8ui:Color` | Цвет |
| `v8ui:Font` | Шрифт |

#### Типы СКД (dcs*:*)

| Тип | Описание |
|-----|----------|
| `dcsset:DataCompositionSettings` | Настройки СКД |
| `dcssch:DataCompositionSchema` | Схема СКД |
| `dcscor:DataCompositionComparisonType` | Тип сравнения СКД |

#### Пустой тип

```xml
<Type/>  <!-- нетипизированный / произвольный -->
```

### 9.2. Составные типы

Несколько типов в одном реквизите:

```xml
<Type>
  <v8:Type>cfg:CatalogRef.Организации</v8:Type>
  <v8:Type>cfg:CatalogRef.ИндивидуальныеПредприниматели</v8:Type>
  <v8:Type>cfg:CatalogRef.Контрагенты</v8:Type>
</Type>
```

### 9.3. ValueTable / ValueTree с колонками

```xml
<Attribute name="Строки" id="5">
  <Type>
    <v8:Type>v8:ValueTable</v8:Type>
  </Type>
  <Columns>
    <Column name="Номенклатура" id="1">
      <Title>...</Title>
      <Type>
        <v8:Type>cfg:CatalogRef.Номенклатура</v8:Type>
      </Type>
    </Column>
    <Column name="Количество" id="2">
      <Type>
        <v8:Type>xs:decimal</v8:Type>
        <v8:NumberQualifiers>
          <v8:Digits>10</v8:Digits>
          <v8:FractionDigits>3</v8:FractionDigits>
          <v8:AllowedSign>Nonnegative</v8:AllowedSign>
        </v8:NumberQualifiers>
      </Type>
    </Column>
  </Columns>
</Attribute>
```

---

## 10. Parameters — параметры формы

```xml
<Parameters>
  <Parameter name="ИмяПараметра">
    <Type>...</Type>                        <!-- идентично типам Attributes -->
    <KeyParameter>true</KeyParameter>       <!-- ключевой параметр -->
  </Parameter>
</Parameters>
```

Параметры **не имеют** атрибута `id`. Типы — те же, что для Attributes.

---

## 11. Commands — команды формы

```xml
<Commands>
  <Command name="ИмяКоманды" id="N">
    <Title>...</Title>                    <!-- multilang -->
    <ToolTip>...</ToolTip>                <!-- multilang -->
    <Picture>
      <xr:Ref>StdPicture.Refresh</xr:Ref>
      <xr:LoadTransparent>true</xr:LoadTransparent>
    </Picture>
    <Action>ИмяОбработчика</Action>       <!-- имя процедуры обработки -->
    <Shortcut>Ctrl+S</Shortcut>           <!-- клавиатурное сочетание -->
    <Representation>Auto | Picture | Text | PictureAndText | TextPicture | None | Compact</Representation>
    <CurrentRowUse>DontUse | Use | Auto</CurrentRowUse>
    <ModifiesData>true | false</ModifiesData>
    <ModifiesSavedData>true | false</ModifiesSavedData>
    <ChangedStateSavedData>true | false</ChangedStateSavedData>
    <Use>Auto</Use>
    <Mark>true | false</Mark>
    <ParameterUse>...</ParameterUse>
  </Command>
</Commands>
```

---

## 12. Ссылки на картинки

Два вида ссылок:

```xml
<!-- Стандартная картинка платформы -->
<xr:Ref>StdPicture.Refresh</xr:Ref>

<!-- Общая картинка конфигурации -->
<xr:Ref>CommonPicture.ЗаполнитьФорму</xr:Ref>
```

С прозрачностью:

```xml
<Picture>
  <xr:Ref>StdPicture.Print</xr:Ref>
  <xr:LoadTransparent>true</xr:LoadTransparent>
</Picture>
```

---

## 13. Ссылки на стили, цвета, шрифты

```xml
<!-- Стиль -->
<BackColor>style:FormBackColor</BackColor>

<!-- Web-цвет -->
<TextColor>web:Red</TextColor>

<!-- Windows-цвет -->
<BackColor>win:ButtonFace</BackColor>

<!-- Системный шрифт -->
<Font>sys:DefaultGUIFont</Font>
```

---

## 14. Рамки (Border)

```xml
<Border width="1">
  <v8ui:style xsi:type="v8ui:ControlBorderType">WithoutBorder</v8ui:style>
</Border>
```

Значения `ControlBorderType`: `WithoutBorder`, `WithBorder`.

---

## 15. DataPath — привязка к данным

Формат пути:

| Пример | Описание |
|--------|----------|
| `Объект.Организация` | Реквизит основного объекта формы |
| `Объект.Товары.Номенклатура` | Колонка табличной части объекта |
| `Отчет.НачалоПериода` | Параметр отчёта |
| `Запись.ОКОФ` | Поле записи регистра |
| `ТекстСообщения` | Реквизит формы верхнего уровня |

---

## 16. Статистика использования элементов

| Тип элемента | Частота |
|--------------|---------|
| UsualGroup | ~90% форм |
| Button | ~85% |
| InputField | ~80% |
| LabelDecoration | ~75% |
| CommandBar | ~70% |
| Table | ~60% |
| LabelField | ~60% |
| Pages / Page | ~55% |
| ButtonGroup | ~50% |
| CheckBoxField | ~45% |
| Popup | ~40% |
| PictureDecoration | ~40% |
| PictureField | ~15% |
| CalendarField | ~5% |

---

## 17. Элементы, не встреченные в конфигурации

Следующие элементы управления существуют в платформе, но не использованы в БП 3.0:

- `RadioButtonField`
- `TrackBarField`
- `ProgressBarField`
- `TextDocumentField`
- `SpreadSheetDocumentField`
- `HTMLDocumentField`
- `ChartField`
- `GanttChartField`
- `PlannerField`
- `GraphicalSchemaField`
- `FormattedDocumentField`
