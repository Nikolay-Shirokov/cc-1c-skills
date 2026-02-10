---
name: role-compile
description: Создание роли 1С — метаданные и Rights.xml из описания прав
argument-hint: <JsonPath> <RolesDir>
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
| `RolesDir` | Каталог `Roles/` в исходниках конфигурации |

```powershell
powershell.exe -NoProfile -File .claude\skills\role-compile\scripts\role-compile.ps1 -JsonPath "<json>" -OutputDir "<RolesDir>"
```

`<Role>ИмяРоли</Role>` автоматически добавляется в `<ChildObjects>` файла `Configuration.xml` (ожидается в parent от `RolesDir`).

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
  { "name": "Document.Продажа", "preset": "view", "rights": {"Delete": false}, "rls": {"Read": "#Шаблон(\"\")"} }
]
```

- Shorthand: `"Тип.Имя: @пресет"` или `"Тип.Имя: Право1, Право2"`
- Объектная форма: `preset` + `rights` (переопределения) + `rls` (ограничения)

### Пресеты

| Пресет | Действие |
|--------|----------|
| `@view` | Просмотр — Read, View (+InputByString для справочников/документов; Use+View для обработок/отчётов) |
| `@edit` | Полное редактирование — CRUD + Interactive* + Posting (документы) |

`@` обязателен в shorthand. В объектной форме — `"preset": "view"` без `@`.

Для сервисов (WebService, HTTPService, IntegrationService) пресеты не определены — используй явные права: `"WebService.Имя: Use"`.

### Русские синонимы

Поддерживаются русские типы (`Справочник`→Catalog, `Документ`→Document) и права (`Чтение`→Read, `Просмотр`→View). Смешивание допустимо: `"Справочник.Контрагенты: Чтение, View"`.

### Шаблоны RLS

```json
"templates": [{"name": "ДляОбъекта(Мод)", "condition": "ГДЕ Организация = &ТекОрг"}]
```

Ссылка в `rls`: `"#ДляОбъекта(\"\")"`. Символ `&` автоматически экранируется в XML.

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

Подробные таблицы пресетов, русских синонимов и дополнительные примеры — в `dsl-reference.md`.

## Верификация

```
/role-validate <RightsPath> [MetadataPath]  — проверка корректности XML, прав, RLS
/role-info <RightsPath>                     — визуальная сводка структуры
```
