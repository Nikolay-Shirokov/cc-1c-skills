# Form DSL Specification

Спецификация JSON-формата для `/form-compile` — компактного описания управляемых форм 1С:Предприятия 8.3.

---

## 1. Корневой объект

```json
{
  "title": "Заголовок формы",
  "properties": { ... },
  "excludedCommands": [ ... ],
  "events": { ... },
  "elements": [ ... ],
  "attributes": [ ... ],
  "parameters": [ ... ],
  "commands": [ ... ]
}
```

| Поле | Тип | Описание |
|------|-----|----------|
| `title` | string | Заголовок формы (необязательный) |
| `properties` | object | Свойства формы (необязательный) |
| `excludedCommands` | string[] | Исключённые стандартные команды (необязательный) |
| `events` | object | Обработчики событий формы (необязательный) |
| `elements` | array | Дерево UI-элементов (необязательный) |
| `attributes` | array | Реквизиты формы (необязательный) |
| `parameters` | array | Параметры формы (необязательный) |
| `commands` | array | Команды формы (необязательный) |

---

## 2. Properties — свойства формы

Объект со свойствами в camelCase. Компилятор преобразует в PascalCase для XML.

```json
"properties": {
  "autoTitle": false,
  "windowOpeningMode": "LockOwnerWindow",
  "commandBarLocation": "Bottom"
}
```

### Поддерживаемые свойства

| DSL ключ | XML элемент | Значения |
|----------|-------------|----------|
| `autoTitle` | `<AutoTitle>` | `true` / `false` |
| `windowOpeningMode` | `<WindowOpeningMode>` | `LockOwnerWindow`, `Modeless` |
| `commandBarLocation` | `<CommandBarLocation>` | `Top`, `Bottom`, `None` |
| `saveDataInSettings` | `<SaveDataInSettings>` | `UseList`, `Use`, `DontUse` |
| `autoSaveDataInSettings` | `<AutoSaveDataInSettings>` | `Use`, `DontUse` |
| `autoTime` | `<AutoTime>` | `CurrentOrLast`, `Current`, `Last` |
| `usePostingMode` | `<UsePostingMode>` | `Auto`, `Postings`, `Movements` |
| `repostOnWrite` | `<RepostOnWrite>` | `true` / `false` |
| `autoURL` | `<AutoURL>` | `true` / `false` |
| `autoFillCheck` | `<AutoFillCheck>` | `true` / `false` |
| `customizable` | `<Customizable>` | `true` / `false` |
| `enterKeyBehavior` | `<EnterKeyBehavior>` | `DefaultButton`, `NewLine` |
| `verticalScroll` | `<VerticalScroll>` | `useIfNecessary`, `Auto`, `AlwaysShow`, `Never` |
| `width` | `<Width>` | число |
| `height` | `<Height>` | число |
| `group` | `<Group>` | `Vertical`, `Horizontal`, `AlwaysHorizontal`, `AlwaysVertical` |
| `useForFoldersAndItems` | `<UseForFoldersAndItems>` | `Folders`, `Items`, `FoldersAndItems` |

Нераспознанные ключи преобразуются с автоматическим PascalCase (первая буква в верхний регистр).

---

## 3. Events — обработчики событий формы

```json
"events": {
  "OnCreateAtServer": "ПриСозданииНаСервере",
  "OnOpen": "ПриОткрытии"
}
```

Ключ — имя события, значение — имя процедуры-обработчика.

### Доступные события

| Событие | Описание |
|---------|----------|
| `OnCreateAtServer` | Создание формы на сервере |
| `OnOpen` | Открытие формы |
| `BeforeClose` | Перед закрытием |
| `OnClose` | При закрытии |
| `BeforeWrite` | Перед записью |
| `BeforeWriteAtServer` | Перед записью на сервере |
| `OnWriteAtServer` | При записи на сервере |
| `AfterWriteAtServer` | После записи на сервере |
| `AfterWrite` | После записи |
| `OnReadAtServer` | При чтении объекта |
| `NotificationProcessing` | Обработка оповещений |
| `ChoiceProcessing` | Обработка выбора |
| `FillCheckProcessingAtServer` | Проверка заполнения |

---

## 4. Elements — дерево UI-элементов

Массив объектов. Тип элемента определяется ключом-идентификатором.

### 4.1. Общие свойства всех элементов

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя элемента (по умолчанию — из значения ключа типа) |
| `title` | string | Заголовок |
| `hidden` | bool | `true` → `<Visible>false</Visible>` |
| `disabled` | bool | `true` → `<Enabled>false</Enabled>` |
| `readOnly` | bool | `true` → `<ReadOnly>true</ReadOnly>` |
| `on` | string[] | Массив имён событий |
| `handlers` | object | Явные имена обработчиков: `{"OnChange": "МойОбработчик"}` |

### 4.2. Автоименование обработчиков

При указании `"on"` без `"handlers"` имя обработчика генерируется автоматически:

```
<ИмяЭлемента><РусскийСуффикс>
```

| Событие | Суффикс |
|---------|---------|
| `OnChange` | `ПриИзменении` |
| `StartChoice` | `НачалоВыбора` |
| `ChoiceProcessing` | `ОбработкаВыбора` |
| `AutoComplete` | `АвтоПодбор` |
| `Clearing` | `Очистка` |
| `Opening` | `Открытие` |
| `Click` | `Нажатие` |
| `OnActivateRow` | `ПриАктивизацииСтроки` |
| `BeforeAddRow` | `ПередНачаломДобавления` |
| `BeforeDeleteRow` | `ПередУдалением` |
| `BeforeRowChange` | `ПередНачаломИзменения` |
| `OnStartEdit` | `ПриНачалеРедактирования` |
| `OnEndEdit` | `ПриОкончанииРедактирования` |
| `Selection` | `ВыборСтроки` |
| `OnCurrentPageChange` | `ПриСменеСтраницы` |
| `TextEditEnd` | `ОкончаниеВводаТекста` |

Пример: элемент `Контрагент` + событие `OnChange` → обработчик `КонтрагентПриИзменении`.

### 4.3. Типы элементов

#### group — UsualGroup

```json
{ "group": "horizontal", "name": "ГруппаШапка", "children": [ ... ] }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `group` | string | Ориентация: `horizontal`, `vertical`, `alwaysHorizontal`, `alwaysVertical`, `collapsible` |
| `children` | array | Вложенные элементы |
| `showTitle` | bool | Показывать заголовок группы |
| `representation` | string | `none`, `normal`, `weak`, `strong` |
| `united` | bool | Объединение |

#### input — InputField

```json
{ "input": "Организация", "path": "Объект.Организация", "on": ["OnChange"] }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `multiLine` | bool | Многострочный режим |
| `passwordMode` | bool | Режим пароля |
| `titleLocation` | string | `none`, `left`, `right`, `top`, `bottom` |
| `choiceButton` | bool | Показывать кнопку выбора |
| `clearButton` | bool | Показывать кнопку очистки |
| `spinButton` | bool | Показывать кнопку прокрутки |
| `dropListButton` | bool | Показывать кнопку раскрытия |
| `markIncomplete` | bool | Автопометка незаполненных |
| `skipOnInput` | bool | Пропускать при вводе |
| `inputHint` | string | Подсказка ввода (placeholder) |
| `width` | int | Ширина |
| `height` | int | Высота |
| `horizontalStretch` | bool | Растягивание по горизонтали |
| `verticalStretch` | bool | Растягивание по вертикали |
| `autoMaxWidth` | bool | Автомаксимальная ширина |
| `autoMaxHeight` | bool | Автомаксимальная высота |

#### check — CheckBoxField

```json
{ "check": "ФлагАктивности", "path": "Активен", "on": ["OnChange"] }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `titleLocation` | string | Расположение заголовка |

#### radio — RadioButtonField

```json
{
  "radio": "СпособКурса",
  "path": "Объект.СпособУстановкиКурса",
  "radioButtonType": "Auto",
  "choiceList": [
    { "value": "Enum.СпособыКурса.EnumValue.Авто",   "presentation": "автоматически" },
    { "value": "Enum.СпособыКурса.EnumValue.Ручной", "presentation": { "ru": "вручную", "en": "manual" } }
  ]
}
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `radioButtonType` | string | `Auto` (по умолчанию), `RadioButtons`, `Tumbler` |
| `columnsCount` | int | Число колонок раскладки |
| `titleLocation` | string | Расположение заголовка (компилятор подставляет `None`, если не задан) |
| `choiceList` | array | Варианты выбора: массив `{ value, presentation }` |

`choiceList[*]`:

| Свойство | Тип | Описание |
|----------|-----|----------|
| `value` | string/number/bool | Значение варианта. Для перечисления — `"Enum.ИмяТипа.EnumValue.ИмяЗначения"` (xsi:type автоматически: `xr:DesignTimeRef` / `xs:string` / `xs:decimal` / `xs:boolean`) |
| `presentation` | string или object | Текст рядом с переключателем. Строка → ru; объект `{ru, en, ...}` → мультиязык. Если не задано — выводится из имени значения |

#### label — LabelDecoration

```json
{ "label": "Подсказка", "title": "Выберите параметры", "hyperlink": true }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `title` | string | Текст надписи |
| `hyperlink` | bool | Режим гиперссылки |
| `width` | int | Ширина |
| `height` | int | Высота |
| `autoMaxWidth` | bool | Автомаксимальная ширина |
| `autoMaxHeight` | bool | Автомаксимальная высота |

#### labelField — LabelField

```json
{ "labelField": "СтатусОбработки", "path": "Статус" }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `hyperlink` | bool | Режим гиперссылки |

#### table — Table

```json
{
  "table": "Товары", "path": "Объект.Товары",
  "columns": [
    { "input": "Номенклатура", "path": "Объект.Товары.Номенклатура" }
  ]
}
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `columns` | array | Колонки (элементы input/check/labelField/picField, либо `columnGroup` для группировки) |
| `representation` | string | `List`, `Tree`, `HierarchicalList` |
| `changeRowSet` | bool | Разрешить добавление/удаление строк |
| `changeRowOrder` | bool | Разрешить перемещение строк |
| `height` | int | Высота в строках таблицы |
| `header` | bool | Показывать шапку |
| `footer` | bool | Показывать подвал |
| `commandBarLocation` | string | `None`, `Top`, `Bottom`, `Auto` |
| `searchStringLocation` | string | `None`, `Top`, `Bottom`, `CommandBar`, `Auto` |

#### columnGroup — ColumnGroup

Группа колонок таблицы. Используется только внутри `columns` таблицы. Допускается вложение `columnGroup` в `columnGroup`.

```json
{ "table": "Список", "path": "Список", "columns": [
    { "columnGroup": "horizontal", "name": "ГруппаДата", "title": "Срок", "children": [
        { "input": "ДатаНачала", "path": "Список.ДатаНачала" },
        { "input": "ДатаОкончания", "path": "Список.ДатаОкончания" }
    ]},
    { "columnGroup": "inCell", "name": "ГруппаИсполнитель", "showInHeader": true, "children": [
        { "input": "Исполнитель", "path": "Список.Исполнитель" }
    ]}
]}
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `columnGroup` | string | Ориентация: `horizontal`, `vertical`, `inCell` (склейка колонок в одной ячейке шапки) |
| `name` | string | Имя элемента (рекомендуется задавать явно) |
| `title` | string/object | Заголовок группы |
| `showTitle` | bool | Показывать заголовок |
| `showInHeader` | bool | Показывать в шапке таблицы |
| `width` | int | Ширина |
| `horizontalStretch` | bool | Растягивание |
| `children` | array | Колонки внутри группы |

#### pages / page — Pages / Page

```json
{
  "pages": "Страницы", "children": [
    { "page": "Основное", "children": [ ... ] },
    { "page": "Дополнительно", "children": [ ... ] }
  ]
}
```

Page поддерживает `group` для задания ориентации содержимого и `children` для вложенных элементов.

Pages поддерживает `pagesRepresentation`: `None`, `TabsOnTop`, `TabsOnBottom`, `TabsOnLeft`, `TabsOnRight`.

#### button — Button

```json
{ "button": "Загрузить", "command": "Загрузить", "defaultButton": true }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `command` | string | Имя команды формы (→ `Form.Command.<name>`) |
| `stdCommand` | string | Стандартная команда (→ `Form.StandardCommand.<name>`) |
| `type` | string | `usual`, `hyperlink`, `commandBar` |
| `defaultButton` | bool | Кнопка по умолчанию |
| `picture` | string | Ссылка на картинку (`StdPicture.Name`) |
| `representation` | string | `Auto`, `Picture`, `Text`, `PictureAndText` |
| `locationInCommandBar` | string | `InCommandBar`, `InAdditionalSubmenu` |

#### picture — PictureDecoration

```json
{ "picture": "Логотип", "src": "CommonPicture.Логотип" }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `src` или `picture` (как свойство) | string | Ссылка на картинку |
| `hyperlink` | bool | Режим гиперссылки |
| `width` | int | Ширина |
| `height` | int | Высота |

#### picField — PictureField

```json
{ "picField": "Фото", "path": "Фотография" }
```

#### calendar — CalendarField

```json
{ "calendar": "Дата", "path": "ДатаОтчета" }
```

#### cmdBar — CommandBar

```json
{ "cmdBar": "КоманднаяПанель", "children": [ ... ] }
```

#### popup — Popup

```json
{ "popup": "Печать", "picture": "StdPicture.Print", "children": [ ... ] }
```

---

## 5. Attributes — реквизиты формы

```json
"attributes": [
  { "name": "Объект", "type": "DocumentObject.Реализация", "main": true },
  { "name": "Итого", "type": "decimal(15,2)" },
  { "name": "Таблица", "type": "ValueTable", "columns": [
    { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
    { "name": "Количество", "type": "decimal(10,3)" }
  ]}
]
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя реквизита (обязательно) |
| `type` | string | Тип (shorthand) |
| `main` | bool | Основной реквизит формы |
| `title` | string | Заголовок |
| `savedData` | bool | Сохраняемые данные |
| `fillChecking` | string | `Show`, `DontShow` |
| `columns` | array | Колонки для ValueTable/ValueTree |

---

## 6. Parameters — параметры формы

```json
"parameters": [
  { "name": "Ключ", "type": "DocumentRef.Реализация", "key": true },
  { "name": "Основание", "type": "DocumentRef.Реализация" }
]
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя параметра (обязательно) |
| `type` | string | Тип (shorthand) |
| `key` | bool | Ключевой параметр |

---

## 7. Commands — команды формы

```json
"commands": [
  { "name": "Печать", "action": "ПечатьОбработка", "shortcut": "Ctrl+P" },
  { "name": "Обновить", "action": "ОбновитьОбработка", "picture": "StdPicture.Refresh" }
]
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя команды (обязательно) |
| `action` | string | Имя процедуры-обработчика |
| `title` | string | Заголовок |
| `shortcut` | string | Клавиатурное сочетание |
| `picture` | string | Ссылка на картинку |
| `representation` | string | `Auto`, `Picture`, `Text`, `PictureAndText` |

---

## 8. Система типов (shorthand)

### Примитивные типы

| DSL | XML |
|-----|-----|
| `"string"` | `xs:string` (неограниченная) |
| `"string(100)"` | `xs:string` + Length=100 |
| `"decimal(15,2)"` | `xs:decimal` + Digits=15, FractionDigits=2, AllowedSign=Any |
| `"decimal(10,0,nonneg)"` | `xs:decimal` + AllowedSign=Nonnegative |
| `"boolean"` | `xs:boolean` |
| `"date"` | `xs:dateTime` + DateFractions=Date |
| `"dateTime"` | `xs:dateTime` + DateFractions=DateTime |
| `"time"` | `xs:dateTime` + DateFractions=Time |

### Ссылочные типы

| DSL | XML |
|-----|-----|
| `"CatalogRef.Организации"` | `cfg:CatalogRef.Организации` |
| `"DocumentObject.Реализация"` | `cfg:DocumentObject.Реализация` |
| `"EnumRef.СтавкиНДС"` | `cfg:EnumRef.СтавкиНДС` |
| `"DataProcessorObject.ЗагрузкаДанных"` | `cfg:DataProcessorObject.ЗагрузкаДанных` |

### Платформенные типы

| DSL | XML |
|-----|-----|
| `"ValueTable"` | `v8:ValueTable` |
| `"ValueTree"` | `v8:ValueTree` |
| `"ValueList"` | `v8:ValueListType` |
| `"FormattedString"` | `v8ui:FormattedString` |
| `"Picture"` | `v8ui:Picture` |
| `"DynamicList"` | `cfg:DynamicList` |

### Составные типы

Разделитель `" | "`:

```json
"type": "CatalogRef.Организации | CatalogRef.ИндивидуальныеПредприниматели"
```

---

## 9. Автогенерация

### Companion-элементы

Для каждого элемента автоматически создаются служебные вложенные элементы:

| Тип элемента | Companions |
|---|---|
| UsualGroup | ExtendedTooltip |
| InputField | ContextMenu, ExtendedTooltip |
| CheckBoxField | ContextMenu, ExtendedTooltip |
| RadioButtonField | ContextMenu, ExtendedTooltip |
| LabelDecoration | ContextMenu, ExtendedTooltip |
| LabelField | ContextMenu, ExtendedTooltip |
| PictureDecoration | ContextMenu, ExtendedTooltip |
| PictureField | ContextMenu, ExtendedTooltip |
| CalendarField | ContextMenu, ExtendedTooltip |
| Table | ContextMenu, AutoCommandBar, SearchStringAddition, ViewStatusAddition, SearchControlAddition |
| Pages | ExtendedTooltip |
| Page | ExtendedTooltip |
| Button | ExtendedTooltip |

Именование: `<name>КонтекстноеМеню`, `<name>РасширеннаяПодсказка`, `<name>КоманднаяПанель`, `<name>СтрокаПоиска`, `<name>СостояниеПросмотра`, `<name>УправлениеПоиском`.

### ID

Последовательная нумерация начиная с 1. `AutoCommandBar` формы всегда имеет `id="-1"`.

### Namespace

Все 17 namespace-деклараций добавляются автоматически (version="2.17").

### Кодировка

UTF-8 с BOM (как в файлах конфигурации 1С).
