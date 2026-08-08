# Динамический список

Реквизит с `type: "DynamicList"` (обычно `main: true`) — основа формы списка. Объект `settings` описывает источник данных и настройки списка. Минимум — указать источник:

```json
{ "name": "Список", "type": "DynamicList", "main": true,
  "settings": { "mainTable": "Catalog.Контрагенты" } }
```

К списку привязывается таблица-элемент (`table`), ссылающаяся на реквизит через `path` — см. основную инструкцию.

## Источник данных

Два взаимоисключающих режима:

**Таблично-ориентированный** — основная таблица метаданных:

```json
"settings": { "mainTable": "Catalog.Контрагенты" }
```

**Запросный** — произвольный запрос:

```json
"settings": {
  "query": "ВЫБРАТЬ Т.Ссылка, Т.Наименование, Т.Сумма ИЗ Документ.Заказ КАК Т ГДЕ Т.Сумма > &Порог",
  "mainTable": "Document.Заказ"
}
```

| Ключ | Тип | Назначение |
|------|-----|-----------|
| `mainTable` | string | Основная таблица (`Catalog.X` / `Document.X` / …). Можно вместе с `query` |
| `query` | string | Текст запроса. Поддерживает `@file.sql` (путь к файлу запроса рядом с JSON) |
| `keyType` | string | Запросный список без `mainTable`: тип ключа набора — `FieldValue` / `RowKey` / `RowNumber` |
| `keyFields` | array | Поля ключа набора (для `keyType` без `mainTable`) |

Параметры запроса (`&Имя`) задаются в `parameters` (ниже).

`"dynamicDataRead": false` отключает динамическое считывание (список читается обычным запросом, без фонового обновления) — нужно для тяжёлых/агрегатных запросов.

## Параметры запроса (`parameters`)

Значения для `&параметров` текста запроса. Shorthand `"Имя [Заголовок]: тип = Значение"` (всё кроме имени необязательно) либо объект:

```json
"settings": {
  "query": "… ГДЕ Т.Артикул = &Артикул И Т.Цена ПОДОБНО &Маска",
  "parameters": [
    "Артикул",
    "Маска: string = %",
    { "name": "ВидЦен", "valueListAllowed": true },
    { "name": "Период", "type": "dateTime" }
  ]
}
```

Ключи объекта: `name`, `title`, `type` (грамматика типов — см. основную инструкцию), `value`, `valueListAllowed` (разрешить список значений), `availableValues` (`[{ value, presentation }]`), `expression`, `use`.

## Значения параметров в настройках (`dataParameters`)

Предустановленные значения параметров на уровне настроек списка. Shorthand `"Имя = Значение"` или объект `{ parameter, value?, use?, viewMode? }`:

```json
"dataParameters": [ "Организация = _", "ВидЦен" ]
```

## Поля набора (`fields`)

Обычно поля выводятся из источника сами — `fields` нужен **только чтобы переопределить** свойства отдельного поля:

```json
"fields": [
  { "field": "Сумма", "title": "Сумма, руб", "appearance": { "Формат": "ЧДЦ=2" } },
  { "field": "Остаток", "valueType": "number(15,2)" }
]
```

Ключи поля: `field`, `dataPath`, `title`, `valueType`, `appearance` (как в условном оформлении), `presentationExpression`, `inputParameters` (связь по параметрам выбора), `typeLink` (`{ field, linkItem }` — связь по типу, напр. субконто).

## Вычисляемые поля (`calculatedFields`)

Поля, считаемые выражением. Shorthand `"Имя [Заголовок]: тип = Выражение"`:

```json
"calculatedFields": [
  "Метка = Code + \" \" + Description",
  "Маржа [Маржа, руб]: number(15,2) = Цена - Закупка"
]
```

Объектная форма — для `presentationExpression` / `orderExpression`:

```json
{ "dataPath": "Сорт", "expression": "Code", "title": "Сорт",
  "valueType": "string(10)", "presentationExpression": "Code" }
```

## Отбор (`filter`)

Shorthand `"Поле оператор значение @флаги"` или объект:

```json
"filter": [
  "Организация = _ @off @user",
  "Сумма > 1000",
  { "field": "Дата", "op": ">=", "value": "2024-01-01T00:00:00" },
  { "group": "Or", "items": [ "Статус = 1", "Статус = 2" ] }
]
```

- **Операторы:** `=` `<>` `>` `>=` `<` `<=`, `in` / `notIn`, `inHierarchy`, `contains` / `notContains`, `beginsWith` / `notBeginsWith`, `like` / `notLike` (`%`-шаблон), `filled` / `notFilled`.
- **Флаги:** `@off` (отключён), `@user` (в пользовательских настройках), `@quickAccess`; `_` = пустое значение.
- **Группа:** `{ group: "And"|"Or"|"Not", items: [...] }`.
- **Дата-значение:** ISO-дата `"2024-01-01T00:00:00"` — фиксированная дата. Именованный относительный период — строкой с типом: `{ "value": "BeginningOfThisWeek", "valueType": "v8:StandardBeginningDate" }` (варианты `BeginningOfThisDay`/`BeginningOfThisWeek`/`BeginningOfThisMonth`/`BeginningOfThisYear`/…).

## Сортировка (`order`)

Строка `"Поле"` (по возр.) / `"Поле desc"`, либо объект `{ field, direction? }`. `"Auto"` — автосортировка:

```json
"order": [ "Дата desc", "Наименование", "Auto" ]
```

## Группировка строк (`grouping`)

Линейная цепочка уровней (внешний → внутренний). Шорткат `>` или массив:

```json
"grouping": "Контрагент > Договор"
"grouping": [ "Контрагент", { "field": "Дата", "groupType": "Hierarchy" } ]
```

Ключи уровня-объекта: `field`, `groupType` (`Items` / `Hierarchy`).

## Условное оформление (`conditionalAppearance`)

```json
"conditionalAppearance": [
  { "filter": [ "Просрочено = true" ], "appearance": { "ЦветТекста": "web:Red" } }
]
```

`filter` — та же грамматика, что выше. `appearance` — словарь «параметр платформы: значение» (`ЦветТекста`, `ЦветФона`, `Шрифт`, `Текст`, `Формат`, …). Значение `Текст`/`Заголовок`/`Формат`: голая строка — нелокализованный литерал; `{ru,en}` — локализуемая строка; `{ field: "путь" }` — ссылка на поле. Подробнее об оформлении — `references/appearance.md`.
