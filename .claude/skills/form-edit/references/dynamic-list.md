# Динамический список

Реквизит с `type: "DynamicList"` (обычно `main: true`) — основа формы списка. Объект `settings` описывает источник данных и настройки списка. Минимум — указать источник:

```json
{ "name": "Список", "type": "DynamicList", "main": true,
  "settings": { "mainTable": "Catalog.Контрагенты" } }
```

К списку привязывается таблица-элемент (`table`), ссылающаяся на реквизит через `path` (`references/table-advanced.md`).

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

Ключи объекта: `name`, `title`, `type` (грамматика — `references/type-system-advanced.md`), `value`, `valueListAllowed` (разрешить список значений), `availableValues` (`[{ value, presentation }]`), `expression`, `use`.

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
  { "field": "Остаток", "valueType": "decimal(15,2)" }
]
```

Ключи поля: `field`, `dataPath`, `title`, `valueType`, `appearance` (как в условном оформлении), `presentationExpression`, `inputParameters` (связь по параметрам выбора), `typeLink` (`{ field, linkItem }` — связь по типу, напр. субконто).

## Вычисляемые поля (`calculatedFields`)

Поля, считаемые выражением. Shorthand `"Имя [Заголовок]: тип = Выражение"`:

```json
"calculatedFields": [
  "Метка = Code + \" \" + Description",
  "Маржа [Маржа, руб]: decimal(15,2) = Цена - Закупка"
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

Операторы, флаги (`@off`, `@user`, `@quickAccess`), группы и значения-даты — как в условном оформлении: `references/appearance.md`, раздел «filter». Здесь поля — поля списка (`Сумма`, `Организация`).

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

Без `selection` правило оформляет всю строку списка. `filter` и `appearance` — как в условном оформлении формы: `references/appearance.md`.

## Таблица динамического списка

Таблица, у которой `path` — реквизит динамического списка, сразу получает поведение списка: автообновление, корень, значок строки, своя командная панель скрыта. Вид (`representation: "HierarchicalList"`, `initialTreeView`) — `references/table-advanced.md`. Указывайте **только отличия**:

| Ключ | Умолчание | Назначение |
|------|-----------|-----------|
| `initialListView` | — | `Beginning` / `End` — куда прокрутить при открытии |
| `rowPictureDataPath` | `<Список>.DefaultPicture` | Значок строки; `""` — без значка |
| `choiceFoldersAndItems` | `Items` | Что выбирать: `Items` / `Folders` / `FoldersAndItems` |
| `allowRootChoice` | `false` | Разрешить выбор корня |
| `showRoot` | `true` | Показывать корень |
| `autoRefresh` / `autoRefreshPeriod` | `false` / `60` | Автообновление и период, сек |
| `updateOnDataChange` | `Auto` | `DontUpdate` — не обновлять при изменении данных |
| `restoreCurrentRow` | `false` | Восстанавливать текущую строку при обновлении |
| `userSettingsGroup` | — | Группа пользовательских настроек списка |
| `allowGettingCurrentRowURL` | `true` | `false` — запретить получение ссылки на текущую строку |
| `commandBar` | скрыта | `{ "autofill": true }` — показать свою панель таблицы |

```json
{ "table": "Список", "path": "Список", "representation": "HierarchicalList",
  "initialTreeView": "ExpandTopLevel", "choiceFoldersAndItems": "FoldersAndItems", "allowRootChoice": true }
```
