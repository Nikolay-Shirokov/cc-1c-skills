# Схема компоновки данных (СКД)

Навыки группы `/skd-*` позволяют анализировать, создавать, редактировать и проверять схемы компоновки данных 1С — XML-файлы DataCompositionSchema (Template.xml).

## Навыки

| Навык | Параметры | Описание |
|-------|-----------|----------|
| `/skd-info` | `<TemplatePath> [-Mode] [-Name]` | Анализ структуры СКД: наборы, поля, параметры, ресурсы, варианты (11 режимов, включая full) |
| `/skd-compile` | `[-DefinitionFile <json> \| -Value <json-string>] -OutputPath <Template.xml>` | Генерация Template.xml из JSON DSL: наборы, поля, итоги, параметры, варианты |
| `/skd-edit` | `<TemplatePath> -Operation <op> -Value "<value>"` | Точечное редактирование: 25 атомарных операций (add/set/modify/clear/remove) |
| `/skd-validate` | `<TemplatePath> [-MaxErrors 20]` | Валидация структурной корректности: ~30 проверок |

## Рабочий цикл

```
Описание отчёта (текст) → JSON DSL → /skd-compile → Template.xml → /skd-validate
                                                    ↕ /skd-edit      → /skd-info
```

1. Claude формирует JSON-определение СКД (shorthand-поля, параметры, итоги, варианты)
2. `/skd-compile` генерирует Template.xml с корректными namespace, типами, группировками
3. `/skd-edit` вносит точечные изменения: добавление полей, фильтров, наборов данных, вариантов, условного оформления и т.д.
4. `/skd-validate` проверяет корректность XML
5. `/skd-info` выводит компактную сводку для визуальной проверки

## JSON DSL — компактный формат

СКД описываются в JSON с двумя уровнями детализации для каждой секции:

### Минимальный пример

```json
{
  "dataSets": [{
    "query": "ВЫБРАТЬ Номенклатура.Наименование ИЗ Справочник.Номенклатура КАК Номенклатура",
    "fields": ["Наименование"]
  }]
}
```

Умолчания: dataSource создаётся автоматически (`ИсточникДанных1/Local`), набор получает имя `НаборДанных1`, вариант настроек "Основной" с деталями.

### Поля — shorthand

```json
"fields": [
  "Наименование",
  "Количество: decimal(15,2)",
  "Организация: CatalogRef.Организации @dimension",
  "Служебное: string #noFilter #noOrder"
]
```

Формат: `Имя[: Тип] [@роль...] [#ограничение...]`. Роли: `@dimension`, `@account`, `@balance`, `@period`. Ограничения: `#noField`, `#noFilter`, `#noGroup`, `#noOrder`.

### Итоги — shorthand

```json
"totalFields": ["Количество: Сумма", "Стоимость: Сумма(Кол * Цена)"]
```

Формат: `Поле: Функция` или `Поле: Функция(выражение)`. Объектная форма поддерживает привязку к группировкам: `{ "dataPath": "X", "expression": "Сумма(X)", "group": ["Группа1", "ОбщийИтог"] }`.

### Параметры — shorthand + @autoDates

```json
"parameters": [
  "Период: StandardPeriod = LastMonth @autoDates",
  "Организация: CatalogRef.Организации"
]
```

`@autoDates` автоматически генерирует параметры `ДатаНачала`/`ДатаОкончания` (заменяет 5 строк на 1).

### Вычисляемые поля — shorthand

```json
"calculatedFields": ["Итого = Количество * Цена"]
```

### Варианты настроек — shorthand

```json
"settingsVariants": [{
  "name": "Основной",
  "settings": {
    "selection": ["Номенклатура", "Количество", "Сумма"],
    "filter": ["Организация = _ @off @user"],
    "order": ["Сумма desc"],
    "dataParameters": ["Период = LastMonth @user"],
    "outputParameters": { "Заголовок": "Мой отчёт" },
    "structure": "Организация > details"
  }
}]
```

- **filter shorthand**: `"Поле оператор значение @флаги"` — флаги `@off`, `@user`, `@quickAccess`, `@normal`, `@inaccessible`
- **dataParameters shorthand**: `"Имя = значение @флаги"`
- **structure shorthand**: `"Поле1 > Поле2 > details"` — `>` разделяет уровни группировки
- **conditionalAppearance**: условное оформление с автоопределением типов значений (Color, Boolean, LocalStringType)

### Шаблоны вывода — компактный DSL

Для отчётов с фиксированным оформлением (ФСД, ведомости) — табличное описание вместо raw XML:

```json
"templates": [
  {
    "name": "Макет1", "style": "header",
    "widths": [36, 33, 16, 17], "minHeight": 24.75,
    "rows": [
      ["Виды кассы", "Валюта", "Остаток на начало\nпериода", "Остаток на конец периода"],
      ["|", "|", "|", "|"],
      ["К1", "К2", "К3", "К4"]
    ]
  },
  {
    "name": "Макет2", "style": "data",
    "widths": [36, 33, 16, 17],
    "rows": [["{ВидКассы}", "{Валюта}", "{Остаток}", "{ОстатокКонец}"]],
    "parameters": [
      { "name": "ВидКассы", "expression": "Представление(Счет)" }
    ]
  }
],
"groupTemplates": [
  { "groupField": "Счет", "templateType": "GroupHeader", "template": "Макет1" },
  { "groupField": "Счет", "templateType": "Header", "template": "Макет2" }
]
```

Синтаксис ячеек: `"текст"` — статика, `"{Имя}"` — параметр, `"|"` — объединение с ячейкой выше, `null` — пустая.

Встроенные стили: `header` (фон, центр, перенос), `data` (фон группы), `subheader` (без фона, центр), `total` (без фона). Все — Arial 10, рамки Solid 1px, цвета через стили платформы. Пользовательские стили — через `skd-styles.json` в директории проекта.

### Объектная форма

Все секции поддерживают полную объектную форму для сложных случаев (title, appearance, role с выражениями, userSettingID, userSettingPresentation, conditionalAppearance, группы фильтров And/Or/Not и т.д.). Подробности — в [спецификации SKD DSL](skd-dsl-spec.md).

## Сценарии использования

### Анализ существующей СКД

```
> Проанализируй схему компоновки отчёта Reports/АнализНДФЛ/Templates/ОсновнаяСхемаКомпоновкиДанных
```

Claude вызовет `/skd-info` (overview → trace → query → variant) и опишет:
- наборы данных и их поля
- параметры и значения по умолчанию
- ресурсы и формулы агрегации
- структуру группировок в вариантах настроек

### Создание СКД по описанию

```
> Создай СКД для отчёта по продажам: группировка по организациям,
> поля Номенклатура, Количество, Сумма. Период — параметр.
```

Claude сформирует JSON (запрос можно вынести в файл: `"query": "@queries/sales.sql"`):
```json
{
  "dataSets": [{
    "name": "Продажи",
    "query": "ВЫБРАТЬ ...",
    "fields": [
      "Организация: CatalogRef.Организации @dimension",
      "Номенклатура: CatalogRef.Номенклатура @dimension",
      "Количество: decimal(15,3)",
      "Сумма: decimal(15,2)"
    ]
  }],
  "totalFields": ["Количество: Сумма", "Сумма: Сумма"],
  "parameters": ["Период: StandardPeriod = LastMonth @autoDates"],
  "settingsVariants": [{
    "name": "Основной",
    "settings": {
      "selection": ["Номенклатура", "Количество", "Сумма"],
      "dataParameters": ["Период = LastMonth @user"],
      "structure": "Организация > details"
    }
  }]
}
```

И вызовет `/skd-compile` → `/skd-validate` → `/skd-info`.

### Проверка существующей СКД

```
> Проверь корректность СКД Reports/МойОтчёт/Templates/ОсновнаяСхемаКомпоновкиДанных/Ext/Template.xml
```

Claude вызовет `/skd-validate` и покажет результат: ошибки (битые ссылки, дубликаты, невалидные типы) и предупреждения.

## Структура файлов СКД

```
<Объект>/Templates/
├── ИмяМакета.xml              # Метаданные (UUID, TemplateType=DataCompositionSchema)
└── ИмяМакета/
    └── Ext/
        └── Template.xml        # Тело схемы (DataCompositionSchema)
```

## Спецификации

- [1c-dcs-spec.md](1c-dcs-spec.md) — XML-формат DataCompositionSchema, namespace, элементы, типы
- [skd-dsl-spec.md](skd-dsl-spec.md) — JSON DSL для описания СКД (формат входных данных `/skd-compile`)
