# Таблица: вид, выделение, подвал и колонки, поиск, перетаскивание

Таблица привязывается к реквизиту-таблице: `ValueTable`, табличной части объекта, динамическому списку (`references/dynamic-list.md`). Все ключи, кроме `path`, необязательны.

## Основное

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `path` | путь данных | Реквизит-таблица: `"Объект.Товары"`, `"Данные"` |
| `columns` | массив элементов | Колонки: `input`, `check`, `labelField`, `picField`, `columnGroup`; путь колонки — путь таблицы плюс имя колонки: `"Объект.Товары.Сумма"` |
| `changeRowSet` / `changeRowOrder` | bool | Разрешить добавлять и удалять / перемещать строки |
| `header` | `false` | Без шапки |
| `heightInTableRows` | число | Высота в строках |
| `commandBarLocation` | `None` / `Top` / `Bottom` / `Auto` | Где командная панель таблицы |
| `searchStringLocation` | `None` / `Top` / `Bottom` / `CommandBar` / `Auto` | Где строка поиска |
| `choiceMode` | bool | Таблица выбора (форма выбора) |

```json
{ "table": "Товары", "path": "Объект.Товары", "changeRowSet": true, "columns": [
    { "input": "ТоварыНоменклатура", "path": "Объект.Товары.Номенклатура" },
    { "input": "ТоварыКоличество", "path": "Объект.Товары.Количество" } ] }
```

`columnGroup` группирует колонки: значение ключа — `horizontal` / `vertical` / `inCell` (несколько колонок в одной ячейке); `title`, `showInHeader`, `children`:

```json
{ "columnGroup": "horizontal", "name": "ГруппаСрок", "title": "Срок", "children": [
    { "input": "ДатаНачала", "path": "Список.ДатаНачала" },
    { "input": "ДатаОкончания", "path": "Список.ДатаОкончания" } ] }
```

## Вид

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `representation` | `List` / `Tree` / `HierarchicalList` | Плоский список, дерево, иерархический список |
| `initialTreeView` | `ExpandTopLevel` / `ExpandAllLevels` / `NoExpand` | Раскрытие дерева при открытии |
| `useAlternationRowColor` | bool | Чередование цвета строк |
| `verticalLines` / `horizontalLines` | `false` | Скрыть линии сетки |
| `headerHeight` / `footerHeight` | число | Высота шапки / подвала, в строках |
| `heightControlVariant` | `UseHeightInTableRows` / `UseContentHeight` / `UseHeightInFormRows` | Как определять высоту таблицы |
| `maxRowsCount` / `autoMaxRowsCount` | число / bool | Ограничение высоты по числу строк |

## Выделение и текущая строка

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `selectionMode` | `SingleRow` / `MultiRow` | Одна или несколько строк |
| `rowSelectionMode` | `Row` / … | Выделять строку целиком |
| `multipleChoice` | bool | Множественный выбор (в форме выбора) |
| `currentRowUse` | `DontUse` / `Use` / `SelectionPresentation` / `SelectionPresentationAndChoice` / `Choice` | Использование текущей строки |

```json
{ "table": "Список", "path": "Список", "selectionMode": "MultiRow", "multipleChoice": true }
```

## Ввод строк

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `autoInsertNewRow` | bool | Новая строка при вводе в последнюю |
| `rowInputMode` | `AfterCurrentRow` / … | Куда добавлять новую строку |
| `markIncomplete` | bool | Отмечать незаполненные ячейки |
| `editMode` (на колонке) | `EnterOnInput` / `Directly` | Ввод в ячейку сразу или по Enter |

## Подвал и колонки

Подвал включается у таблицы — `footer: true`; что показать в подвале, задаётся у колонки — `footerDataPath` или `footerText`.

| Ключ (на колонке) | Значения | Назначение |
|------|----------|-----------|
| `showInFooter` | `false` | Не показывать колонку в подвале |
| `footerDataPath` | путь данных | Значение подвала; итог колонки табличной части — `Total` + имя реквизита: `"Объект.Товары.TotalСумма"` |
| `footerText` | строка или `{ru, en}` | Постоянный текст подвала, напр. «Итого:» |
| `footerHorizontalAlign` | `Left` / `Center` / `Right` | Выравнивание в подвале |
| `showInHeader` | bool | Показать колонку в шапке |
| `headerHorizontalAlign` | `Left` / `Center` / `Right` / `Auto` | Выравнивание в шапке |
| `autoCellHeight` | bool | Высота ячейки по содержимому (перенос) |
| `fixingInTable` | `Left` / `Right` / `None` | Закрепить колонку при горизонтальной прокрутке |
| `cellHyperlink` | bool | Значение ячейки — ссылка |

У `columnGroup` в шапке можно показывать значение из данных: `headerDataPath` (путь) и `headerFormat` (формат).

```json
{ "table": "Товары", "path": "Объект.Товары", "footer": true, "columns": [
    { "input": "Номенклатура", "path": "Объект.Товары.Номенклатура", "fixingInTable": "Left",
      "footerText": "Итого:" },
    { "input": "Сумма", "path": "Объект.Товары.Сумма", "headerHorizontalAlign": "Right",
      "footerDataPath": "Объект.Товары.TotalСумма", "footerHorizontalAlign": "Right" } ] }
```

## Поиск

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `searchOnInput` | `Auto` / `Use` / `DontUse` | Поиск при наборе текста в таблице |
| `viewStatusLocation` / `searchControlLocation` | `None` / `Top` / `Bottom` / `Auto` | Где состояние просмотра и управление поиском |

Своя строка поиска, размещённая в командной панели таблицы — элемент `searchString` (также `viewStatus`, `searchControl`):

```json
{ "table": "Список", "path": "Список", "commandBar": [
    { "searchString": "ПоискСписка", "width": 15, "horizontalStretch": true } ] }
```

`source` — таблица, по которой ищет элемент (по умолчанию — таблица, в панели которой он стоит).

Изменить только положение стандартного элемента поиска — карта `additions`:

```json
{ "table": "Список", "path": "Список", "additions": { "viewStatus": { "horizontalLocation": "left" } } }
```

## Перетаскивание

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `enableDrag` | bool | Принимать перетаскивание в таблицу |
| `enableStartDrag` | bool | Перетаскивать строки из таблицы |

События: `DragStart`, `DragCheck`, `Drag`, `DragEnd`.

## Команды таблицы

Убрать стандартные команды (добавление, перемещение, сортировку):

```json
{ "table": "Товары", "path": "Объект.Товары", "excludedCommands": [ "Add", "Delete", "MoveUp", "SortListAsc" ] }
```

Своя командная панель и контекстное меню таблицы — `references/buttons-commands.md`.
