---
name: skd-compile
description: Компиляция схемы компоновки данных 1С (СКД) из компактного JSON-определения. Используй когда нужно создать СКД с нуля
argument-hint: "[-DefinitionFile <json> | -Value <json-string>] -OutputPath <Template.xml>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /skd-compile — генерация СКД из JSON DSL

Принимает JSON-определение схемы компоновки данных → генерирует Template.xml (DataCompositionSchema).

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `DefinitionFile` | Путь к JSON-файлу с определением СКД (взаимоисключающий с Value) |
| `Value` | JSON-строка с определением СКД (взаимоисключающий с DefinitionFile) |
| `OutputPath` | Путь к выходному Template.xml |

```powershell
# Из файла
powershell.exe -NoProfile -File .claude/skills/skd-compile/scripts/skd-compile.ps1 -DefinitionFile "<json>" -OutputPath "<Template.xml>"

# Из строки (без промежуточного файла)
powershell.exe -NoProfile -File .claude/skills/skd-compile/scripts/skd-compile.ps1 -Value '<json-string>' -OutputPath "<Template.xml>"
```

## JSON DSL — краткий справочник

Справочник ниже. Все примеры компилируемы как есть.

### Корневая структура

```json
{
  "dataSets": [...],
  "calculatedFields": [...],
  "totalFields": [...],
  "parameters": [...],
  "templates": [...],
  "groupTemplates": [...],
  "dataSetLinks": [...],
  "settingsVariants": [...]
}
```

Умолчания: `dataSources` → авто `ИсточникДанных1/Local`; `settingsVariants` → авто "Основной" с деталями.

### Наборы данных

Тип по ключу: `query` → DataSetQuery, `objectName` → DataSetObject, `items` → DataSetUnion.

```json
{ "name": "Продажи", "query": "ВЫБРАТЬ ...", "fields": [...] }
```

Запрос поддерживает `@file` — ссылку на внешний .sql файл вместо inline-текста: `"query": "@queries/sales.sql"`. Путь разрешается относительно JSON-файла, затем CWD.

**DataSetObject** — внешний набор данных (без источника-запроса). Поля описываются явно; данные передаются вторым параметром `ПроцессорКомпоновкиДанных.Инициализировать(Макет, Новый Структура("<objectName>", ТЗ), ...)`.

```json
{ "name": "ЖурналОшибок", "objectName": "ЖурналОшибок", "fields": [
  { "field": "ТекстСообщения", "title": "Текст сообщения", "type": "string(150)" },
  { "field": "Расшифровка",   "title": "Описание",       "type": "CatalogRef.СтруктураПредприятия" }
]}
```

`name` — имя набора в схеме, `objectName` — ключ в структуре передачи данных.

### Поля — shorthand и объектная форма

```
"Наименование"                              — просто имя
"Количество: decimal(15,2)"                  — имя + тип
"Организация: CatalogRef.Организации @dimension"  — + роль
"Служебное: string #noFilter #noOrder"       — + ограничения
```

Объектная форма — когда нужен title или другие свойства:
```json
{ "field": "ОстатокНаНачалоПериода", "title": "Остаток на начало периода" }
```
`dataPath` автоматически берётся из `field`, если не указан явно.

Многоязычный заголовок: `"title": { "ru": "...", "en": "..." }`. Применимо везде, где принимается title/presentation (поля, calculatedFields, parameters, settingsVariants, availableValues и пр.). Строка эквивалентна `{ "ru": "..." }`.

Типы: `string`, `string(N)`, `decimal(D,F)`, `boolean`, `date`, `dateTime`, `CatalogRef.X`, `DocumentRef.X`, `EnumRef.X`, `StandardPeriod`. Ссылочные типы эмитируются с inline namespace `d5p1:` (`http://v8.1c.ru/8.1/data/enterprise/current-config`). Сборка EPF со ссылочными типами требует базу с соответствующей конфигурацией.

Составной тип (несколько типов значений) — массив в объектной форме: `"type": ["CatalogRef.A", "CatalogRef.B"]`. Квалификаторы (`(N)`, `(D,F)`) применяются к каждому элементу.

Роли: `@dimension`, `@account`, `@balance`, `@period`.

Ограничения: `#noField`, `#noFilter`, `#noGroup`, `#noOrder`.

В объектной форме: `"useRestriction": { "field": true, "condition": true, "group": true, "order": true }` или `"restrict": ["noField", "noFilter"]`.

Дополнительные ключи объектной формы:
- `"presentationExpression": "<выражение>"` — что показывать вместо значения поля. Исходное значение остаётся «под капотом» для перехода/расшифровки.
- `"appearance": { "<параметр>": "<значение>" }` — оформление колонки по умолчанию (применяется во всех вариантах настроек). Ключи — параметры платформы (`ГоризонтальноеПоложение`, `МинимальнаяШирина`, `Формат`, `Текст` и т.п.).

```json
{ "field": "Сумма", "title": "Сумма продажи", "type": "decimal(15,2)",
  "appearance": { "ГоризонтальноеПоложение": "Right", "МинимальнаяШирина": "80" } }
```

### Вычисляемые поля (calculatedFields)

Shorthand: `"Имя [Заголовок]: тип = Выражение #noField #noFilter #noGroup #noOrder"` — все части кроме имени опциональны.

```json
"calculatedFields": [
  "Маржа = Цена - Закупка",
  "Наценка [Наценка, %]: decimal(10,2) = Маржа / Закупка * 100",
  "Служебное: string = \"\" #noField #noFilter #noGroup #noOrder"
]
```

Объектная форма — когда нужна `appearance`:
```json
{ "name": "Маржа", "title": "Маржа", "expression": "Цена - Закупка", "type": "decimal(15,2)", "useRestriction": "#noField #noFilter" }
```

### Итоги (shorthand)

```json
"totalFields": ["Количество: Сумма", "Стоимость: Сумма(Кол * Цена)"]
```

### Параметры (shorthand + @autoDates)

```json
"parameters": [
  "Период [Отчетный период]: StandardPeriod = LastMonth @autoDates"
]
```

Shorthand: `"Имя [Заголовок]: тип = значение @флаги"`. `[Заголовок]` опциональный — добавляет `<title>` (LocalStringType).

Флаги shorthand:
- `@autoDates` — добавляет к параметру StandardPeriod пару дат `НачалоПериода`/`КонецПериода`, вычисляемых из него. Используй их в тексте запроса как `&НачалоПериода`/`&КонецПериода`; пользователь выбирает только сам период. По умолчанию сам параметр получает `use=Always` и `denyIncompleteValues=true` (чтобы производные даты всегда были заполнены); в объектной форме можно явно переопределить.
- `@valueList` — `<valueListAllowed>true</valueListAllowed>` — разрешает передавать список значений
- `@hidden` — скрытый параметр: `availableAsField=false` + исключается из `"dataParameters": "auto"`

Объектная форма: `title`, `hidden: true`, `valueListAllowed: true`, `availableAsField: false`, `denyIncompleteValues: true`, `use: "Always"`.

Список допустимых значений (availableValues):

```json
{
  "name": "ПорядокОкругления",
  "type": "EnumRef.Округления",
  "value": "Перечисление.Округления.Окр1_00",
  "use": "Always",
  "denyIncompleteValues": true,
  "availableValues": [
    {"value": "Перечисление.Округления.Окр1_00", "presentation": "руб. коп"},
    {"value": "Перечисление.Округления.Окр1", "presentation": "руб."},
    {"value": "Перечисление.Округления.Окр1000", "presentation": "тыс. руб"}
  ]
}
```

В варианте настроек `"dataParameters": "auto"` выводит все не-hidden параметры с `userSettingID`. Значения по умолчанию наследуются и остаются активными; параметры без значения по умолчанию отключаются (пользователь включит их в настройках).

### Фильтры — shorthand

```json
"filter": [
  "Организация = _ @off @user",
  "Дата >= 2024-01-01T00:00:00",
  "Статус filled"
]
```

Формат: `"Поле оператор значение @флаги"`. Значение `_` = пустое (placeholder). Флаги: `@off` (use=false), `@user` (userSettingID=auto), `@quickAccess`, `@normal`, `@inaccessible`.

В объектной форме доступны: `viewMode`, `userSettingID`, `userSettingPresentation`.

Группы фильтров (Or/And/Not):
```json
{ "group": "Or", "items": [
  { "group": "And", "items": [
    { "field": "Статус", "op": "=", "value": "Активен" },
    { "field": "Сумма", "op": ">", "value": 1000 }
  ]},
  { "field": "Количество", "op": "filled" }
]}
```

### Параметры данных — shorthand

```json
"dataParameters": [
  "Период = LastMonth @user",
  "Организация @off @user"
]
```

Формат: `"Имя [= значение] @флаги"`. Для StandardPeriod варианты (LastMonth, ThisYear и т.д.) распознаются автоматически.

### Структура — string shorthand

```json
"structure": "Организация > details"
"structure": "Организация > Номенклатура > details"
```

`>` разделяет уровни группировки. `details` (или `детали`) = детальные записи. `selection` и `order` по умолчанию `["Auto"]` на каждом уровне.

Объектная форма — для сложных случаев (именованные группировки, selection/filter на уровне группировки, таблицы, диаграммы):

```json
"structure": [
  {
    "name": "ПоОрганизациям",
    "groupFields": ["Организация"],
    "selection": ["Организация", "Сумма", "Auto"],
    "children": [{ "groupFields": [] }]
  }
]
```

`type` по умолчанию `"group"` (можно не указывать). `groupFields` — алиас для `groupBy`. Поддержка `name`, `selection`, `order`, `filter`, `outputParameters`, рекурсивных `children`.

### Варианты настроек

```json
"settingsVariants": [{
  "name": "Основной",
  "title": "Продажи по организациям",
  "settings": {
    "selection": ["Номенклатура", "Количество", "Auto"],
    "filter": ["Организация = _ @off @user"],
    "order": ["Количество desc", "Auto"],
    "conditionalAppearance": [
      {
        "filter": ["Просрочено = true"],
        "appearance": { "ЦветТекста": "style:ПросроченныеДанныеЦвет" },
        "presentation": "Выделять просроченные",
        "viewMode": "Normal",
        "userSettingID": "auto"
      }
    ],
    "outputParameters": { "Заголовок": "Мой отчёт" },
    "dataParameters": ["Период = LastMonth @user"],
    "structure": "Организация > details"
  }
}]
```

### Условное оформление (conditionalAppearance)

```json
"conditionalAppearance": [
  {
    "selection": ["Поле1"],
    "filter": ["Поле1 notFilled"],
    "appearance": { "Текст": "Не указано", "ЦветТекста": "style:XXX" },
    "presentation": "Описание",
    "viewMode": "Normal",
    "userSettingID": "auto"
  }
]
```

Типы значений appearance: `style:XXX`/`web:XXX`/`win:XXX` → Color, `true`/`false` → Boolean, параметр `Формат`/`Текст`/`Заголовок` → LocalStringType, прочее → String.

Типы значений фильтра: `Перечисление.*`/`Справочник.*`/`ПланСчетов.*`/`Документ.*` → DesignTimeValue (автодетект).

OrGroup в фильтре: `{"group": "Or", "items": ["условие1", "условие2"]}`.

Folder в selection: `{"folder": "Поступление", "items": ["ПолеА", "ПолеБ"]}` → SelectedItemFolder с lwsTitle и placement=Auto.

### Итоги с привязкой к группировкам

```json
"totalFields": [
  { "dataPath": "Кол", "expression": "Сумма(Кол)", "group": ["Группа1", "Группа1 Иерархия", "ОбщийИтог"] }
]
```

### Шаблоны вывода — компактный DSL

Вместо raw XML (`template`) — табличное описание через `rows` + именованный стиль `style`:

```json
"templates": [
  {
    "name": "Макет1",
    "style": "header",
    "widths": [36, 33, 16, 17],
    "minHeight": 24.75,
    "rows": [
      ["Виды кассы", "Валюта", "Остаток на начало\nпериода", "Остаток на\nконец периода"],
      ["|", "|", "|", "|"],
      ["К1", "К2", "К3", "К4"]
    ]
  },
  {
    "name": "Макет2",
    "style": "data",
    "widths": [36, 33, 16, 17],
    "rows": [["{ВидКассы}", "{Валюта}", "{Остаток}", "{ОстатокКонец}"]],
    "parameters": [
      { "name": "ВидКассы", "expression": "Представление(Счет)" },
      { "name": "Остаток", "expression": "ОстатокНаНачалоПериода" }
    ]
  }
]
```

Синтаксис ячеек: `"текст"` — статика, `"{Имя}"` — параметр, `"|"` — объединение с ячейкой выше, `">"` — объединение с ячейкой слева, `null` — пустая.

Двухуровневая шапка с горизонтальным объединением:
```json
"rows": [
  ["Вид актива", "Остаток начало", "Поступление", ">", ">", ">", "Выбытие", ">", ">", "Остаток конец"],
  ["|",          "|",              "из произв.",   "из п/ф", "со сч.40", "прочее", "Реализ.", "отгруж.", "прочее", "|"],
  ["К1",         "К2",             "К3",           "К4",     "К5",       "К6",     "К7",      "К8",      "К9",     "К10"]
]
```

Встроенные стили: `header` (фон, центр, перенос), `data` (фон группы), `subheader` (без фона, центр), `total` (без фона). Все — Arial 10, рамки Solid 1px, цвета через стили платформы.

Пользовательские стили: файл `skd-styles.json` рядом с JSON-определением, в текущей директории, или в `presets/skills/skd/skd-styles.json` (поиск вверх от OutputPath). Первый найденный файл побеждает. Все допустимые ключи и формат цветов — в `examples/skd-styles.json`.

Raw XML (`"template": "<...>"`) остаётся как fallback. Детект: если есть `rows` — DSL, иначе — raw.

### Расшифровка (drilldown) в параметрах шаблона

Ключ `drilldown` в параметре шаблона автоматически генерирует `DetailsAreaTemplateParameter` и привязку `Расшифровка` в appearance ячеек:

```json
"parameters": [
  { "name": "Сырье", "expression": "ПоступлениеСырья", "drilldown": "ПоступлениеСырья" }
]
```

Генерирует: `ExpressionAreaTemplateParameter` (обычный) + `DetailsAreaTemplateParameter` с именем `Расшифровка_ПоступлениеСырья`, `fieldExpression` по полю `ИмяРесурса`, `mainAction=DrillDown`. Ячейки `{Сырье}` автоматически получают appearance `Расшифровка = Расшифровка_ПоступлениеСырья`.

### Привязки макетов к группировкам

```json
"groupTemplates": [
  { "groupName": "ДанныеОтчета", "templateType": "GroupHeader", "template": "Макет1" },
  { "groupField": "Счет", "templateType": "Header", "template": "Макет2" },
  { "groupField": "Счет", "templateType": "OverallHeader", "template": "Макет3" }
]
```

`groupField` — привязка к полю группировки, `groupName` — к именованной группировке в структуре варианта.

`templateType`: `Header` (строки данных) → `<groupTemplate>`, `OverallHeader` (итоги) → `<groupTemplate>`, `GroupHeader` (шапка) → `<groupHeaderTemplate>`.

## Примеры

### Минимальный

```json
{
  "dataSets": [{
    "query": "ВЫБРАТЬ Номенклатура.Наименование КАК Наименование ИЗ Справочник.Номенклатура КАК Номенклатура",
    "fields": ["Наименование"]
  }]
}
```

### С запросом из внешнего файла (@file)

```json
{
  "dataSets": [{
    "query": "@queries/sales.sql",
    "fields": ["Номенклатура: СправочникСсылка.Номенклатура @dimension", "Количество: число(15,3)", "Сумма: число(15,2)"]
  }]
}
```

### С ресурсами, параметрами и @autoDates

```json
{
  "dataSets": [{
    "query": "ВЫБРАТЬ Продажи.Организация, Продажи.Номенклатура, Продажи.Количество, Продажи.Сумма ИЗ РегистрНакопления.Продажи.Обороты(&НачалоПериода, &КонецПериода) КАК Продажи",
    "fields": [
      "Организация: СправочникСсылка.Организации @dimension",
      "Номенклатура: СправочникСсылка.Номенклатура @dimension",
      "Количество: число(15,3)",
      "Сумма: число(15,2)"
    ]
  }],
  "totalFields": ["Количество: Сумма", "Сумма: Сумма"],
  "parameters": ["Период: СтандартныйПериод = LastMonth @autoDates"],
  "settingsVariants": [{
    "name": "Основной",
    "settings": {
      "selection": ["Организация", "Номенклатура", "Количество", "Сумма"],
      "filter": ["Организация = _ @off @user"],
      "dataParameters": "auto",
      "structure": "Организация > details"
    }
  }]
}
```

## Верификация

```
/skd-validate <OutputPath>                  — валидация структуры XML
/skd-info <OutputPath>                      — визуальная сводка
/skd-info <OutputPath> -Mode variant -Name 1 — проверка варианта настроек
```
