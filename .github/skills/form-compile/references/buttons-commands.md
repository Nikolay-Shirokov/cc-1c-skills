# Кнопки и команды, подменю, группы кнопок, меню и панели элементов

## Основное

| Ключ (`button`) | Значения | Назначение |
|-----------------|----------|-----------|
| `command` | имя команды формы | Команда формы → `Form.Command.Имя` |
| `stdCommand` | `"Close"`; с точкой — команда элемента: `"Товары.Add"` | Стандартная команда |
| `defaultButton` | bool | Кнопка по умолчанию |
| `type` | `usual` / `hyperlink` | Обычная кнопка или ссылка (в командной панели — кнопка панели) |
| `representation` | `Auto` / `Text` / `Picture` / `PictureAndText` | Что показывать |
| `locationInCommandBar` | `InCommandBar` / `InAdditionalSubmenu` / `InCommandBarAndInAdditionalSubmenu` | В панели, в меню «Ещё» или и там, и там |

Контейнеры кнопок:
- `popup` — подменю: `title`, `children`;
- `buttonGroup` — кнопки, объединённые в группу: `title`, `children`;
- `cmdBar` — отдельная командная панель в раскладке формы: `autofill`, `children`;
- `autoCmdBar` — командная панель самой формы (`ФормаКоманднаяПанель`): `children`, `autofill: false` — без стандартных команд, `horizontalAlign`.

Подменю и группы кнопок лежат только в командной панели, подменю или группе кнопок.

```json
{ "autoCmdBar": "ФормаКоманднаяПанель", "children": [
    { "button": "Загрузить", "command": "Загрузить", "defaultButton": true },
    { "popup": "Печать", "title": "Печать", "children": [
        { "button": "ПечатьСчета", "command": "ПечатьСчета" } ] } ] }
```

## Кнопка

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `commandName` | `CommonCommand.X` / `Catalog.X.Command.Y` / … | Глобальная команда (не команда формы) |
| `parameter` | строка или `{ type }` | Параметр команды: объект метаданных (`"DocumentJournal.Взаимодействия"`) или тип (`{ "type": "DocumentRef.Заказ" }`) |
| `path` | путь данных | Контекст общей команды, напр. `"Объект.Ref"` или `"Items.Список.CurrentData.Ref"` |
| `picture` | `"StdPicture.X"` / `"CommonPicture.X"` / `{ src, loadTransparent }` | Картинка кнопки |
| `pictureLocation` | `Left` / `Right` | Где картинка относительно текста |
| `shape` | `Usual` / `Oval` | Форма обычной кнопки |
| `shapeRepresentation` | `None` / `WhenActive` / `Always` | Когда рисовать рамку кнопки |
| `checked` | bool | Нажатое состояние кнопки-переключателя в командной панели |
| `representationInContextMenu` | `None` / `OnlyInContextMenu` / `AdditionalInContextMenu` | Показ кнопки в контекстном меню |

```json
{ "button": "Обновить", "command": "Обновить", "picture": "StdPicture.Refresh", "representation": "Picture" }
{ "button": "ОткрытьЖурнал", "commandName": "CommonCommand.ОткрытьЖурнал", "parameter": "DocumentJournal.Взаимодействия" }
```

## Команда формы

```json
{ "name": "Загрузить", "action": "ЗагрузитьОбработка", "title": "Загрузить", "shortcut": "Ctrl+Enter", "picture": "StdPicture.Refresh" }
```

`name`, `action` — процедура-обработчик, `title` (без него — из имени), `shortcut`, `picture`, а также:

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `tooltip` | строка или `{ru, en}` | Подсказка команды |
| `representation` | `Auto` / `Text` / `Picture` / `PictureAndText` | Вид кнопок команды |
| `table` | имя таблицы-элемента | Команда работает с текущей строкой этой таблицы |
| `currentRowUse` | `Auto` / `DontUse` / `Use` | Использование текущей строки |
| `modifiesSavedData` | `true` | Команда изменяет данные формы (форма помечается изменённой) |
| `functionalOptions` | массив имён | Доступность по функциональным опциям |

```json
{ "name": "Подобрать", "action": "ПодобратьОбработка", "table": "Товары", "picture": "StdPicture.Select" }
```

## Подменю и группа кнопок

| Ключ | Где | Назначение |
|------|-----|-----------|
| `picture`, `representation` | `popup`, `buttonGroup` | Картинка и вид, как у кнопки |
| `commandSource` | `buttonGroup`, `popup`, `cmdBar` | Наполнить командами из источника: `Form`, `FormCommandPanelGlobalCommands`, `Item.<ИмяТаблицы>` |
| `horizontalLocation` | элемент командной панели | `auto` / `left` / `right` / `center` — прижать к краю панели |

```json
{ "buttonGroup": "КомандыТоваров", "commandSource": "Item.Товары" }
{ "popup": "Печать", "picture": "StdPicture.Print", "children": [
    { "button": "ПечатьСчета", "command": "ПечатьСчета" } ] }
```

## Командная панель и контекстное меню элемента

Любое поле, группа или таблица может нести свою командную панель (`commandBar`) и своё контекстное меню (`contextMenu`). Значение — массив кнопок или объект:

```json
{ "table": "Заказы", "path": "Объект.Заказы",
  "commandBar": { "autofill": false, "horizontalAlign": "Right", "children": [
      { "button": "Добавить", "command": "ДобавитьЗаказ" },
      { "button": "Удалить", "command": "УдалитьЗаказ" } ] },
  "contextMenu": [ { "button": "ОткрытьДокумент", "command": "ОткрытьЗаказ" } ] }
```

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `children` | массив | Кнопки, группы кнопок, подменю |
| `autofill` | `false` | Не добавлять стандартные команды. По умолчанию панель и меню автозаполняются |
| `horizontalAlign` | `Left` / `Center` / `Right` | Выравнивание кнопок (только у `commandBar`) |

`cmdBar: "Имя"` (строка) — отдельная панель в раскладке формы; `commandBar: { … }` (объект или массив) — панель самого элемента.
