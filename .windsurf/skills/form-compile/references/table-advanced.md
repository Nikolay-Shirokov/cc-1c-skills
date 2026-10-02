# Таблица — продвинутые возможности

Базовый элемент таблицы (`type: "table"`, колонки, основные свойства) описан в основной инструкции, раздел «Таблица (table)». Здесь — продвинутые возможности: дополнения командной панели, специфика таблицы динамического списка и неочевидные свойства/режимы.

## Представление (`representation`)

Как таблица рисует строки:

```json
{ "table": "Список", "path": "Список", "representation": "Tree" }
```

`List` — плоский список (по умолчанию), `Tree` — дерево, `HierarchicalList` — иерархический список (группы + элементы на одном уровне).

Для дерева/иерархии управляйте раскрытием уровней через `initialTreeView` (`ExpandTopLevel` / `ExpandAllLevels` / `NoExpand`).

## Выделение и текущая строка

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `selectionMode` | `SingleRow` / `MultiRow` | Режим выделения строк |
| `multipleChoice` | bool | Разрешить множественный выбор (для форм выбора) |
| `currentRowUse` | `DontUse` / `Use` / `SelectionPresentation` / `SelectionPresentationAndChoice` / `Choice` | Использование текущей строки таблицы |

```json
{ "table": "Список", "path": "Список", "selectionMode": "MultiRow", "multipleChoice": true }
```

## Поиск при вводе (`searchOnInput`)

Поведение встроенного поиска при наборе текста в таблице:

```json
{ "table": "Список", "path": "Список", "searchOnInput": "Use" }
```

`Auto` (по умолчанию) / `Use` (искать) / `DontUse` (не искать).

Где располагать сами элементы поиска — управляется `searchStringLocation` / `viewStatusLocation` / `searchControlLocation` (`None` / `Top` / `Bottom` / `CommandBar` / `Auto`).

## Прочие свойства таблицы

| Ключ | Тип | Назначение |
|------|-----|-----------|
| `useAlternationRowColor` | bool | Чередование цвета строк |
| `verticalLines` / `horizontalLines` | bool | Линии сетки (укажите `false`, чтобы скрыть) |
| `markIncomplete` | bool | Автоотметка незаполненных ячеек |
| `heightInTableRows` | int | Высота элемента в строках (отдельно от `height`) |
| `autoInsertNewRow` | bool | Автодобавление новой строки при вводе в последнюю |
| `rowsPicture` | string \| object | Картинка строк. Ссылка (`"CommonPicture.X"`, `"abs:..."`) либо объект `{ src, loadTransparent?, transparentPixel? }` |
| `tooltipRepresentation` | string | Режим показа подсказки таблицы: `None`, `Button`, `ShowBottom`, `ShowTop`, `ShowLeft`, `ShowRight`, `ShowAuto`, `Balloon` |

## Фиксация колонки (`fixingInTable`)

Свойство **колонки** (на `input` / `labelField` / `check` / `picField` внутри `columns`), а не самой таблицы. Закрепляет колонку у края при горизонтальной прокрутке:

```json
{ "table": "Товары", "path": "Объект.Товары", "columns": [
  { "input": "Номенклатура", "path": "Объект.Товары.Номенклатура", "fixingInTable": "Left" },
  { "input": "Количество", "path": "Объект.Товары.Количество" }
]}
```

`Left` / `Right` / `None`.

## Исключённые команды (`excludedCommands`)

Убрать стандартные команды редактора таблицы (кнопки добавления/перемещения/сортировки):

```json
{ "table": "Товары", "path": "Объект.Товары",
  "excludedCommands": [ "Add", "Delete", "MoveUp", "SortListAsc" ] }
```

Свойство работает на любом поле и на уровне формы; для таблицы значимы команды вида `Add` / `Delete` / `MoveUp` / `MoveDown` / `SortListAsc` / `SortListDesc`.

## Дополнения командной панели (`additions`)

Дополнения — это «представления» встроенного поиска таблицы:

- `searchString` — отображение строки поиска,
- `viewStatus` — состояние просмотра,
- `searchControl` — управление поиском.

Каждое дополнение — полноценный элемент (полный набор свойств поля). Размещать их можно двумя способами.

**(1) Стандартные дополнения** генерирует платформа на уровне таблицы. В DSL указывайте **только отклонения** от стандартного вида — через карту `additions` (ключ = тип дополнения):

```json
{ "table": "Список", "path": "Список",
  "additions": { "viewStatus": { "horizontalLocation": "left" } } }
```

**(2) Кастомное дополнение**, размещённое прямо в командной панели — обычный элемент в `commandBar` с ключом-типом:

```json
{ "table": "Список", "path": "Список", "commandBar": [
  { "searchString": "ПоискСписка", "source": "Список", "width": 15, "horizontalStretch": true }
]}
```

- Тип-ключ: `searchString` / `viewStatus` / `searchControl`.
- `source` — имя таблицы-источника; необязательно, по умолчанию = имя родительской таблицы.
- `horizontalLocation`: `auto` (по умолчанию) / `left` / `right`. Применимо и к обычным элементам командных панелей.
- Прочие свойства как у поля: `title`, `visible`, `userVisible`, `enabled`, `tooltip`, оформление, `width` / `maxWidth` / `autoMaxWidth` / `horizontalStretch` / `groupHorizontalAlign` и др.

## Таблица динамического списка

Когда `path` таблицы указывает на реквизит `type: "DynamicList"` (см. `references/dynamic-list.md`), доступен блок специфичных свойств. Указывайте **только отличия** от умолчания.

| Ключ | Тип | Умолчание | Назначение |
|------|-----|-----------|-----------|
| `rowPictureDataPath` | string | картинка осн. таблицы | Путь к картинке строки. `""` — подавить картинку |
| `rowsPicture` | string | — | Картинка строк (`"CommonPicture.X"`) |
| `autoRefresh` | bool | `false` | Автообновление списка |
| `autoRefreshPeriod` | int | `60` | Период автообновления, сек |
| `updateOnDataChange` | string | `Auto` | Обновлять при изменении данных: `Auto` / `DontUpdate` |
| `choiceFoldersAndItems` | string | `Items` | Что выбирать: `Items` / `Folders` / `FoldersAndItems` |
| `restoreCurrentRow` | bool | `false` | Восстанавливать текущую строку при обновлении |
| `showRoot` | bool | `true` | Показывать корень |
| `allowRootChoice` | bool | `false` | Разрешить выбор корня |
| `allowGettingCurrentRowURL` | bool | `true` | Разрешить получение URL текущей строки |
| `userSettingsGroup` | string | — | Группа пользовательских настроек (привязка к одноимённой группе настроек) |

```json
{ "table": "Список", "path": "Список",
  "representation": "Tree",
  "rowPictureDataPath": "Список.DefaultPicture",
  "choiceFoldersAndItems": "FoldersAndItems",
  "allowRootChoice": true,
  "updateOnDataChange": "DontUpdate" }
```
