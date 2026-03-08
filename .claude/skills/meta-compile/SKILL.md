---
name: meta-compile
description: Создать исходники объекта метаданных 1С (справочник, документ, регистр, перечисление, константа, общий модуль, обработка, HTTP-сервис и др.) в выгрузке конфигурации. Используй когда пользователь просит добавить или создать объект конфигурации
argument-hint: <JsonPath> <OutputDir>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /meta-compile — генерация объектов метаданных из JSON DSL

Принимает JSON-определение объекта метаданных → генерирует XML + модули в структуре выгрузки конфигурации + регистрирует в Configuration.xml.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `JsonPath` | Путь к JSON-определению объекта (один объект `{...}` или массив `[{...}, ...]`) |
| `OutputDir` | Корневая директория выгрузки конфигурации (где `Catalogs/`, `Documents/` и т.д.) |

```powershell
powershell.exe -NoProfile -File .claude/skills/meta-compile/scripts/meta-compile.ps1 -JsonPath "<json>" -OutputDir "<ConfigDir>"
```

`OutputDir` — директория, содержащая подпапки типов (`Catalogs/`, `Documents/`, ...) и `Configuration.xml`.

## Поддерживаемые типы (23)

### Ссылочные
Catalog (Справочник), Document (Документ), Enum (Перечисление), ExchangePlan (ПланОбмена), ChartOfAccounts (ПланСчетов), ChartOfCharacteristicTypes (ПВХ), ChartOfCalculationTypes (ПВР), BusinessProcess (БизнесПроцесс), Task (Задача)

### Регистры
InformationRegister (РегистрСведений), AccumulationRegister (РегистрНакопления), AccountingRegister (РегистрБухгалтерии), CalculationRegister (РегистрРасчёта)

### Отчёты/Обработки
Report (Отчёт), DataProcessor (Обработка)

### Сервисные
Constant (Константа), DefinedType (ОпределяемыйТип), CommonModule (ОбщийМодуль), ScheduledJob (РегламентноеЗадание), EventSubscription (ПодпискаНаСобытие), DocumentJournal (ЖурналДокументов), HTTPService (HTTPСервис), WebService (ВебСервис)

## JSON DSL — краткий справочник

Полная спецификация: `docs/meta-dsl-spec.md`.

### Корневая структура

```json
{
  "type": "Catalog",
  "name": "Номенклатура",
  "synonym": "авто из name",
  ...type-specific...,
  "attributes": [...],
  "tabularSections": {...}
}
```

### Реквизиты — shorthand

```
"ИмяРеквизита"                     — String без квалификаторов
"ИмяРеквизита: Тип"                — с типом
"ИмяРеквизита: Тип | req, index"  — с флагами
```

Типы: `String(100)`, `Number(15,2)`, `Boolean`, `Date`, `DateTime`, `CatalogRef.Xxx`, `DocumentRef.Xxx`, `EnumRef.Xxx`, `ChartOfAccountsRef.Xxx`, `ChartOfCharacteristicTypesRef.Xxx`, `ChartOfCalculationTypesRef.Xxx`, `ExchangePlanRef.Xxx`, `BusinessProcessRef.Xxx`, `TaskRef.Xxx`, `DefinedType.Xxx`.

Русские синонимы типов: `Строка`, `Число`, `Булево`, `Дата`, `СправочникСсылка.Xxx`, `ДокументСсылка.Xxx`, `ПланСчетовСсылка.Xxx`.

Составной тип (несколько допустимых типов через `+`): `"Значение: Строка + Число(15,2) + Дата + CatalogRef.Контрагенты"`.

Флаги: `req`, `index`, `indexAdditional`, `nonneg`, `master`, `mainFilter`, `denyIncomplete`, `useInTotals`.

## Примеры

### Справочник

```json
{ "type": "Catalog", "name": "Валюты" }
```

### Перечисление

```json
{ "type": "Enum", "name": "Статусы", "values": ["Новый", "Закрыт"] }
```

### Константа

```json
{ "type": "Constant", "name": "ОсновнаяВалюта", "valueType": "CatalogRef.Валюты" }
```

### Определяемый тип

```json
{ "type": "DefinedType", "name": "ДенежныеСредства", "valueTypes": ["CatalogRef.БанковскиеСчета", "CatalogRef.Кассы"] }
```

### Общий модуль

```json
{ "type": "CommonModule", "name": "ОбменДаннымиСервер", "context": "server", "returnValuesReuse": "DuringRequest" }
```

Шорткаты context: `"server"` → Server+ServerCall, `"client"` → ClientManagedApplication, `"serverClient"` → Server+ClientManagedApplication.

### Регистр сведений

```json
{
  "type": "InformationRegister", "name": "КурсыВалют", "periodicity": "Day",
  "dimensions": ["Валюта: CatalogRef.Валюты | master, mainFilter, denyIncomplete"],
  "resources": ["Курс: Number(15,4)", "Кратность: Number(10,0)"]
}
```

### План обмена

```json
{ "type": "ExchangePlan", "name": "ОбменССайтом", "attributes": ["АдресСервера: String(200)"] }
```

### Журнал документов

```json
{
  "type": "DocumentJournal", "name": "Взаимодействия",
  "registeredDocuments": ["Document.Встреча", "Document.ТелефонныйЗвонок"],
  "columns": [{ "name": "Организация", "indexing": "Index", "references": ["Document.Встреча.Attribute.Организация"] }]
}
```

### HTTP-сервис

```json
{
  "type": "HTTPService", "name": "API", "rootURL": "api",
  "urlTemplates": { "Users": { "template": "/v1/users", "methods": { "Get": "GET", "Create": "POST" } } }
}
```

### Веб-сервис

```json
{
  "type": "WebService", "name": "DataExchange", "namespace": "http://www.1c.ru/DataExchange",
  "operations": { "TestConnection": { "returnType": "xs:boolean", "handler": "ПроверкаПодключения", "parameters": { "ErrorMessage": { "type": "xs:string", "direction": "Out" } } } }
}
```

### План счетов

```json
{
  "type": "ChartOfAccounts", "name": "Хозрасчетный",
  "extDimensionTypes": "ChartOfCharacteristicTypes.ВидыСубконто", "maxExtDimensionCount": 3,
  "codeMask": "@@@.@@.@", "codeLength": 8,
  "accountingFlags": ["Валютный", "Количественный"],
  "extDimensionAccountingFlags": ["Суммовой", "Валютный"]
}
```

### Бизнес-процесс

```json
{ "type": "BusinessProcess", "name": "Задание", "attributes": ["Описание: String(200)"] }
```

### Batch — массив объектов в одном файле

```json
[
  { "type": "Enum", "name": "Статусы", "values": ["Новый", "Закрыт"] },
  { "type": "Catalog", "name": "Валюты" },
  { "type": "Constant", "name": "ОсновнаяВалюта", "valueType": "CatalogRef.Валюты" }
]
```

Каждый элемент массива компилируется отдельно. Итоговый вывод: `=== Batch: 3 objects, 3 compiled, 0 failed ===`.

## Что генерируется

- `{OutputDir}/{TypePlural}/{Name}.xml` — метаданные объекта
- `{OutputDir}/{TypePlural}/{Name}/Ext/ObjectModule.bsl` — модуль объекта (Catalog, Document, Report, DataProcessor, ExchangePlan, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes, BusinessProcess, Task)
- `{OutputDir}/{TypePlural}/{Name}/Ext/RecordSetModule.bsl` — модуль набора записей (4 типа регистров)
- `{OutputDir}/{TypePlural}/{Name}/Ext/Module.bsl` — модуль (CommonModule, HTTPService, WebService)
- `{OutputDir}/{TypePlural}/{Name}/Ext/Content.xml` — состав плана обмена (ExchangePlan)
- `{OutputDir}/{TypePlural}/{Name}/Ext/Flowchart.xml` — карта маршрута (BusinessProcess)
- `Configuration.xml` — автоматическая регистрация в `<ChildObjects>`

## Верификация

```
/meta-info <OutputDir>/<TypePlural>/<Name>.xml    — проверка структуры
```
