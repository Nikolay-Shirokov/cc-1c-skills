---
name: mxl-compile
description: Компиляция табличного документа (MXL) из JSON-определения. Используй когда нужно создать макет печатной формы
argument-hint: <JsonPath> <OutputPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /mxl-compile — Компилятор макета из DSL

Принимает компактное JSON-определение макета (области, параметры, стили) → генерирует Template.xml табличного документа 1С: палитры, индексы, объединения, namespace.

## Использование

```
/mxl-compile <JsonPath> <OutputPath>
```

## Параметры

| Параметр   | Обязательный | Описание                           |
|------------|:------------:|------------------------------------|
| JsonPath   | да           | Путь к JSON-определению макета     |
| OutputPath | да           | Путь для генерации Template.xml    |

## Команда

```powershell
powershell.exe -NoProfile -File ".codeassistant/skills/mxl-compile/scripts/mxl-compile.ps1" -JsonPath "<путь>.json" -OutputPath "<путь>/Template.xml"
```

## Рабочий процесс

1. Написать JSON-определение (Write tool) → файл `.json`
2. Вызвать `/mxl-compile` для генерации Template.xml
3. Вызвать `/mxl-validate` для проверки корректности
4. Вызвать `/mxl-info` для верификации структуры

**Если макет создаётся по изображению** (скриншот, скан печатной формы) — сначала вызвать `/img-grid` для наложения сетки, по ней определить границы колонок и пропорции, затем использовать `"Nx"` ширины + `"page"` для автоматического расчёта размеров.

## Что читать под задачу

Ниже — всё, что нужно для типового макета. Остальное лежит по файлу на задачу, читать нужно
только свой:

| Задача | Ключи | Файл |
|---|---|---|
| Свойство стиля вне частых: отступ, защита, узор, маска, поведение при выводе | — | `reference/style-properties.md` |
| Область, не описываемая диапазоном строк; свои ширины колонок у части документа | `namedAreas`, `columnSets`, `columnSet` | `reference/layout.md` |
| Колонтитулы, ориентация, поля, масштаб | `header`, `footer`, `printSettings` | `reference/print.md` |
| Картинка, фигура или надпись поверх сетки; картинка в ячейке | `pictures`, `drawings`, `pictureParameter` | `reference/drawings.md` |
| Ячейки для ввода данных пользователем | `valueType`, `controlType`, `value` | `reference/input-cells.md` |
| Сворачиваемые группы строк или колонок | `rowGroups`, `columnGroups` | `reference/groups.md` |
| Всплывающая подсказка у ячейки | `note` | `reference/notes.md` |

## Пример

```json
{
  "columns": 5,
  "columnWidths": { "1": 5, "2": 40, "3-5": 12 },
  "fonts": { "жирный": { "face": "Arial", "size": 10, "bold": true } },
  "styles": {
    "шапка":  { "font": "жирный", "horizontalAlignment": "Center", "textPlacement": "Wrap", "border": "Solid" },
    "клетка": { "border": "Solid" },
    "число":  { "border": "Solid", "horizontalAlignment": "Right", "format": "ЧЦ=15; ЧДЦ=2" },
    "итог":   { "font": "жирный", "horizontalAlignment": "Right", "topBorder": "Solid" }
  },
  "areas": [
    { "name": "Заголовок", "rows": [
      { "height": 20, "cells": [{ "col": 1, "span": 5, "style": "шапка", "param": "ЗаголовокОтчёта" }] },
      {}
    ]},
    { "name": "ШапкаТаблицы", "rows": [
      { "rowStyle": "шапка", "cells": ["№", "Номенклатура", "Количество", "Цена", "Сумма"] }
    ]},
    { "name": "Строка", "rows": [
      { "rowStyle": "клетка", "cells": [
        { "col": 1, "param": "НомерСтроки" },
        { "col": 2, "param": "Товар", "detail": "Номенклатура" },
        { "col": 3, "style": "число", "param": "Количество" },
        { "col": 4, "style": "число", "param": "Цена" },
        { "col": 5, "style": "число", "param": "Сумма" }
      ]}
    ]},
    { "name": "Итого", "rows": [
      { "rowStyle": "итог", "cells": [null, null, null, "Итого:", "{Всего}"] }
    ]}
  ]
}
```

Шапка таблицы и итог записаны позиционно — позиция берётся из порядка, `col` не нужен;
строка таблицы записана ячейками с `col`, потому что у них разные стили и расшифровка.

## Структура DSL

```
{ columns, page, defaultWidth, columnWidths, columnStyles, textLanguages,
  fonts:  { имя: { face, size, bold, italic, underline, strikeout } | { ref } },
  styles: { имя: { font, horizontalAlignment, verticalAlignment, textPlacement,
                   border, leftBorder, topBorder, rightBorder, bottomBorder,
                   borderColor, backColor, textColor, format } },
  areas: [{ name, columnSet, rows: [
    { height, hidden, rowStyle, empty, cells: [
      { col, span, rowspan, style, param, detail, text, template, note,
        valueType, controlType, value, pictureParameter } ] } ] }],
  namedAreas, columnSets, rowGroups, columnGroups, header, footer, printSettings,
  pictures, drawings
}
```

Верхний уровень: `columns` обязателен, остальное по необходимости.

| Ключ | Описание |
|---|---|
| `columns` | Количество колонок раскладки по умолчанию |
| `page` | Формат страницы: `"A4-landscape"` (780), `"A4-portrait"` (540) или число. Сам вычисляет `defaultWidth` из суммы пропорций `"Nx"` |
| `defaultWidth` | Ширина колонок по умолчанию (10) |
| `columnWidths` | Ширины: ключи 1-based (`"1"`, `"3-14"`, `"5,7,9"`), значение — число или `"2x"` (доля от `defaultWidth`) |
| `columnStyles` | Стиль на колонку целиком: те же ключи диапазонов, значение — имя стиля |
| `textLanguages` | Языки, на которые разворачивается текст, заданный строкой (по умолчанию `["ru"]`) |
| `areas` | Области — диапазоны подряд идущих строк, в порядке документа |

## Области, строки, ячейки

**Область** (`areas[]`) — диапазон подряд идущих строк: `name` (необязательно; с именем область
доступна как `Макет.ПолучитьОбласть("Имя")`) и `rows`. Область без имени — просто кусок сетки.

**Строка** (`rows[]`): `height`, `hidden`, `rowStyle`, `cells`. Пустая строка — `{}`,
а `{ "empty": 3 }` заменяет три подряд. `height` и `hidden` — свойства самой строки, у ячейки
таких нет.

**Ячейка** (`cells[]`):

| Ключ | Описание |
|---|---|
| `col` | Позиция колонки, 1-based |
| `span` / `rowspan` | Объединение вправо / вниз |
| `style` | Имя стиля; перекрывает `rowStyle` для этой ячейки |
| `param` | Параметр заполнения — `Область.Параметры.Имя = …` |
| `text` | Статический текст: строка или объект «язык → текст» |
| `template` | Текст со вставками `[Параметр]` |
| `detail` | Параметр расшифровки; ставится и без `param` |

Содержимое задаётся ровно одним ключом из `param` / `text` / `template`; ячейка без них —
пустая (нужна, например, ради рамки). Пустая строка `"text": ""` — это тоже текст, а не
отсутствие текста.

### Короткая форма: список ячеек позиционно

Позиция берётся из порядка, `col` не нужен:

| Элемент | Значение |
|---|---|
| `"текст"` | Статический текст |
| `{ "ru": "…", "en": "…" }` | Тот же текст на нескольких языках |
| `"{Имя}"` | Параметр заполнения |
| `">"` | Продолжение ячейки слева — увеличивает её `span` |
| `"|"` | Продолжение ячейки сверху — увеличивает её `rowspan` |
| `null` | Пропуск колонки |
| `{ … }` | Обычная ячейка без `col` — когда нужны `style`, `detail`, `template` |

```json
"rows": [
  ["Вид", "Остаток", ">", "Итог"],
  ["|",   "начало",  "конец", "|"],
  ["{Вид}", "{Нач}", "{Кон}", "{Итог}"]
]
```

Здесь «Вид» и «Итог» объединены по вертикали, «Остаток» — по горизонтали на две колонки.

Позиционный список — это форма записи ЯЧЕЕК, а не строки. Если у строки нет своих свойств, он
и есть строка (как в примере выше). Если нужны `height`, `hidden` или `rowStyle` — тот же
список кладётся в `cells`:

```json
{ "rowStyle": "итог", "cells": [null, null, null, "Итого:", "{Всего}"] }
```

### `rowStyle` — оформление строки

Стиль ложится на ВСЮ ширину строки: колонки без явных ячеек получают его тоже — так выходят
сплошные рамки в табличной части. Он же становится оформлением самой строки. Ячейки с `rowspan`
из предыдущих строк при этом пропускаются.

## Оформление

Ячейка, строка и колонка ссылаются на один и тот же именованный стиль: ячейка — ключом `style`,
строка — `rowStyle`, колонка — через `columnStyles`.

**Шрифт** (`fonts.<имя>`): `face` (Arial), `size` (10), `bold`, `italic`, `underline`,
`strikeout`. Либо ссылка вместо описания: `{ "ref": "style:TextFont" }`,
`{ "ref": "sys:DefaultGUIFont" }`. Шрифт `"default"` берётся, когда стиль не указал свой.

**Частые ключи стиля** — имя ключа совпадает с именем свойства в выгрузке, значения перечислений
регистр не различают:

| Ключ | Значение |
|---|---|
| `font` | Имя из `fonts` |
| `horizontalAlignment` | `Left`, `Center`, `Right`, `Justify`, `Auto` |
| `verticalAlignment` | `Top`, `Center`, `Bottom` |
| `textPlacement` | Длинный текст: `Wrap` (перенос), `Cut` (обрезать), `Block`, `Auto` |
| `border` | Рамка со всех сторон |
| `leftBorder`, `topBorder`, `rightBorder`, `bottomBorder` | Отдельная сторона |
| `borderColor` | Цвет рамки |
| `backColor`, `textColor` | Цвет фона и текста |
| `format` | Формат данных 1С: `"ЧЦ=15; ЧДЦ=2"`, `"ДФ=dd.MM.yyyy"` |

**Рамка**: `"Solid"` (ширина 1) либо `{ "style": "Solid", "width": 2 }`. Стили линии: `None`,
`Solid`, `Dotted`, `Dashed`, `DashDotted`, `DashDottedDotted`, `ThinDashed`, `LargeDashed`,
`ThickDashed`, `Double`. Стороны можно задавать по отдельности всегда: совпавшие четыре
компилятор свернёт сам.

**Цвет** — нотация платформы: `#RRGGBB`, `style:ИмяСтиля` (элемент стиля конфигурации),
`web:Имя`, `win:Имя`. Несуществующее имя платформа отвергнет при загрузке.

```json
"styles": {
  "шапка":  { "font": "жирный", "horizontalAlignment": "Center", "backColor": "#EBEBEB" },
  "рамка":  { "border": { "style": "Solid", "width": 2 } },
  "снизу":  { "bottomBorder": "Dotted" }
}
```
