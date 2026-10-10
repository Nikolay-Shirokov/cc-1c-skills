# Группы и страницы: сворачивание, выравнивание, заголовки из данных

Все ключи необязательны.

## Основное

Значение ключа `group` — ориентация: `vertical` / `horizontalIfPossible` / `alwaysHorizontal`; имя — в `name`.

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `children` | массив элементов | Содержимое группы |
| `title` | строка или `{ru, en}` | Заголовок группы |
| `showTitle` | bool | Показывать заголовок |
| `behavior` | `collapsible` / `popup` | Сворачиваемая / всплывающая; не указан — обычная |
| `representation` | `none` / `normal` / `weak` / `strong` | Рамка группы |
| `united` | `false` | Выравнивать поля только внутри группы, а не вместе с соседними |

Страницы: `pages` — имя, `pagesRepresentation` (`TabsOnTop` / `TabsOnBottom` / `TabsOnLeft` / `TabsOnRight` / `None` — без закладок), `children` — массив `page`. `page` — имя, `title`, `group` (ориентация содержимого), `children`.

```json
{ "pages": "Страницы", "children": [
    { "page": "СтраницаОсновное", "title": "Основное", "children": [ ... ] },
    { "page": "СтраницаТовары", "title": "Товары", "children": [ ... ] } ] }
```

## Сворачиваемая и всплывающая группа

`behavior: "collapsible"` — группа сворачивается по заголовку; `behavior: "popup"` — содержимое открывается во всплывающем окне.

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `collapsed` | bool | Создать свёрнутой |
| `collapsedTitle` | строка или `{ru, en}` | Заголовок в свёрнутом виде (например, с краткой сводкой) |
| `controlRepresentation` | `TitleHyperlink` (по умолчанию) / `Picture` | Чем сворачивать: ссылкой-заголовком или значком |

```json
{ "group": "vertical", "name": "ГруппаДополнительно", "title": "Дополнительно",
  "behavior": "collapsible", "collapsed": true, "children": [ ... ] }
```

## Раскладка содержимого группы

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `childItemsWidth` | `Equal` / `LeftWide` / `LeftNarrow` / `LeftWidest` / `LeftNarrowest` | Соотношение ширины колонок у горизонтальной группы |
| `horizontalSpacing` / `verticalSpacing` | `None` / `Half` / `Single` / `OneAndHalf` / `Double` | Интервал между элементами |
| `showLeftMargin` | bool | Отступ слева у содержимого |
| `childrenAlign` | `ItemsLeftTitlesLeft` / `ItemsRightTitlesLeft` / `None` / … | Выравнивание элементов и их заголовков |

```json
{ "group": "alwaysHorizontal", "name": "ГруппаПериод", "childItemsWidth": "Equal",
  "horizontalSpacing": "Half", "children": [ ... ] }
```

## Заголовок из данных

У группы и страницы заголовок можно брать из значения реквизита:

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `titleDataPath` | путь данных | Откуда брать заголовок, напр. `"Объект.Товары.RowsCount"` |
| `format` | строка формата или `{ru, en}` | Как показать значение, напр. `"ЧН=0"` |

```json
{ "page": "СтраницаТовары", "title": "Товары", "titleDataPath": "Объект.Товары.RowsCount", "children": [ ... ] }
```

## Страницы

| Ключ | Где | Значения |
|------|-----|----------|
| `group` | `page` | Ориентация содержимого страницы: `vertical` / `horizontalIfPossible` / `alwaysHorizontal` |
| `picture` | `page` | Значок закладки: `"StdPicture.X"` / `"CommonPicture.X"` (формат картинок — `references/pictures.md`) |

Мастер по шагам — страницы без закладок, переключение кнопками «Назад»/«Далее» из кода:

```json
{ "pages": "СтраницыМастера", "pagesRepresentation": "None", "children": [
    { "page": "Шаг1", "title": "Параметры", "children": [ { "input": "Параметр", "path": "Параметр" } ] },
    { "page": "Шаг2", "title": "Результат", "children": [ { "input": "Итог", "path": "Итог", "readOnly": true } ] } ] }
```
