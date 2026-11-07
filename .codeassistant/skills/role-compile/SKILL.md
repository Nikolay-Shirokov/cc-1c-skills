---
name: role-compile
description: Создание роли 1С из описания прав. Используй когда нужно создать новую роль с набором прав на объекты
argument-hint: <JsonPath> <OutputDir>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /role-compile — генерация роли 1С из JSON DSL

Принимает JSON-определение роли → генерирует `Roles/Имя.xml` (метаданные) и `Roles/Имя/Ext/Rights.xml` (права). UUID автоматически.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `JsonPath` | Путь к JSON-определению роли |
| `OutputDir` | Корень выгрузки конфигурации (где `Configuration.xml`, `Roles/` и т.д.) |

```powershell
powershell.exe -NoProfile -File ".codeassistant/skills/role-compile/scripts/role-compile.ps1" -JsonPath "<json>" -OutputDir "<ConfigDir>"
```

Создаёт `{OutputDir}/Roles/Имя.xml` и `{OutputDir}/Roles/Имя/Ext/Rights.xml`. Регистрирует `<Role>` в `Configuration.xml`.

## JSON DSL

### Структура

```json
{ "name": "ИмяРоли", "synonym": "Отображаемое имя", "objects": [...], "templates": [...] }
```

Необязательные: `comment` (""), `setForNewObjects` (false), `setForAttributesByDefault` (true), `independentRightsOfChildObjects` (false).

### Shorthand-строки и объектная форма

```json
"objects": [
  "Catalog.Номенклатура: @view",
  "Document.Реализация: @edit",
  "DataProcessor.Загрузка: @view",
  "InformationRegister.Цены: Read, Update",
  { "name": "Document.Продажа", "preset": "view", "rls": {"Read": "#Шаблон(\"\")"} },
  { "name": "Catalog.Номенклатура.Attribute.Цена", "rights": {"View": false} }
]
```

- Shorthand: `"Тип.Имя: @пресет"` или `"Тип.Имя: Право1, Право2"`
- Объектная форма: `preset` + `rights` (точечные значения прав) + `rls` (ограничения)

### Пресеты

| Пресет | Действие |
|--------|----------|
| `@view` | Просмотр — Read, View (+InputByString для справочников/документов; Use+View для обработок/отчётов) |
| `@edit` | Полное редактирование — CRUD + Interactive* + Posting (документы) |

`@` обязателен в shorthand. В объектной форме — `"preset": "view"` без `@`.


### Сервисы

Право живёт на **вложенном объекте** сервиса — методе шаблона URL, операции, канале; на сервисе целиком его не бывает. Весь сервис — короткая запись, навык раскроет её по метаданным в `OutputDir`:

```json
"objects": ["HTTPService.ЭДО: Use"]
```
→ `HTTPService.ЭДО.URLTemplate.ЕстьНовыеДокументы.Method.POST: Use`, и так по каждому методу каждого шаблона.

Часть маршрутов — полным путём: `"HTTPService.ЭДО.URLTemplate.ЕстьНовыеДокументы.Method.POST: Use"`.


### Шаблоны RLS

```json
"templates": [{"name": "ДляОбъекта(Мод)", "condition": "ГДЕ Организация = &ТекОрг"}]
```

Ссылка в `rls`: `"#ДляОбъекта(\"\")"`. Символ `&` автоматически экранируется в XML.

Длинное условие держи в файле — в значении пишется `@путь`. Относительный путь ищется рядом
с JSON-описанием роли, затем в текущем каталоге:

```json
"objects": [{"name": "Document.Продажа", "preset": "view", "rls": {"Read": "@условие.txt"}}],
"templates": [{"name": "ДляОбъекта(Мод)", "condition": "@шаблон.txt"}]
```

## Примеры

### Простая роль

```json
{
  "name": "ЧтениеНоменклатуры", "synonym": "Чтение номенклатуры",
  "objects": ["Catalog.Номенклатура: @view", "Catalog.Контрагенты: @view", "DataProcessor.Загрузка: @view"]
}
```

### Роль с RLS

```json
{
  "name": "ЧтениеДокументовПоОрганизации",
  "synonym": "Чтение документов (ограничение по организации)",
  "objects": [
    "Catalog.Организации: @view",
    {"name": "Document.РеализацияТоваровУслуг", "preset": "view", "rls": {"Read": "#ДляОбъекта(\"\")"}}
  ],
  "templates": [{"name": "ДляОбъекта(Модификатор)", "condition": "ГДЕ Организация = &ТекущаяОрганизация"}]
}
```

## Что можно писать в `objects`

Прав не бывает у `Enum`, `CommonModule`, `DefinedType`, `CommonPicture`, `CommonTemplate`, `Language`, `FunctionalOption`, `EventSubscription`, `ScheduledJob`, `StyleItem`, `SettingsStorage` и подобных — в дереве редактора ролей их нет. Ошибка в описании — отказ до записи: файлы не создаются, `Configuration.xml` не меняется.

Права на части объекта задаются точечным путём: `Catalog.Контрагенты.Attribute.ИНН: View, Edit`, `WebService.Обмен.Operation.Загрузить: Use`, `HTTPService.ЭДО.URLTemplate.ЕстьНовыеДокументы.Method.POST: Use`.

Реквизиты, табличные части, измерения и ресурсы наследуют права своего объекта — им задают
запрет, чтобы закрыть унаследованное:

```json
{"name": "Catalog.Товары.Attribute.Цена", "rights": {"View": false}}
```

Роль расширения, включённая в основные (`DefaultRoles`), прав на заимствованные объекты давать не может — платформа это запрещает. Такие права выноси в отдельную роль вне основных.

Полные таблицы «тип → права», виды вложенности (включая внешние источники данных), список типов без прав, таблицы пресетов и дополнительные примеры — в `dsl-reference.md`.

## Верификация

```
/role-validate <RightsPath>  — проверка корректности XML, прав, RLS
/role-info <RightsPath>      — визуальная сводка структуры
```
