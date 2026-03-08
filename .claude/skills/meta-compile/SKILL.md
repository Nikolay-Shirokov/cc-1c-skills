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

## Порядок работы

1. Составь JSON по синтаксису и примерам ниже → запиши во временный файл
2. Запусти скрипт meta-compile
3. Если нужно изменить созданный объект — `/meta-edit`
4. Если нужно проверить — `/meta-validate`

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/meta-compile/scripts/meta-compile.ps1 -JsonPath "<json>" -OutputDir "<ConfigDir>"
```

| Параметр | Описание |
|----------|----------|
| `JsonPath` | Путь к JSON-файлу (один объект `{...}` или массив `[{...}, ...]`) |
| `OutputDir` | Корень выгрузки конфигурации (где `Configuration.xml`, `Catalogs/`, `Documents/` и т.д.) |

## JSON DSL

### Общая структура

```json
{ "type": "Catalog", "name": "Номенклатура", ...свойства типа... }
```

`type` и `name` — обязательные. `synonym` генерируется из `name` автоматически (CamelCase → слова через пробел). Можно задать явно: `"synonym": "Мой синоним"`.

### Shorthand реквизитов

Используется в `attributes`, `dimensions`, `resources`, `tabularSections`:

```
"ИмяРеквизита"                    → String(10) по умолчанию
"ИмяРеквизита: Тип"               → с типом
"ИмяРеквизита: Тип | req, index"  → с флагами
```

Типы: `String(100)`, `Number(15,2)`, `Boolean`, `Date`, `DateTime`, `CatalogRef.Xxx`, `DocumentRef.Xxx`, `EnumRef.Xxx`, `DefinedType.Xxx` и др. ссылочные.

Составной тип: `"Значение: String + Number(15,2) + CatalogRef.Контрагенты"`.

Флаги: `req`, `index`, `indexAdditional`, `nonneg`, `master`, `mainFilter`, `denyIncomplete`, `useInTotals`.

### Свойства по типам

Примеров и shorthand-синтаксиса выше достаточно для типовых задач. Если нужны свойства типа, не показанные в примерах, и их допустимые значения — см. reference-файл:

- `reference/types-basic.md` — Catalog, Document, Enum, Constant, DefinedType, Report, DataProcessor
- `reference/types-registers.md` — InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes
- `reference/types-process.md` — BusinessProcess, Task, ExchangePlan, CommonModule, ScheduledJob, EventSubscription, DocumentJournal
- `reference/types-web.md` — HTTPService, WebService

Эта инструкция и reference-файлы — полная документация для генерации. Не ищи примеры XML в выгрузках конфигураций.

## Примеры паттернов DSL

### Минимальный объект

```json
{ "type": "Catalog", "name": "Валюты" }
```

### С реквизитами

```json
{
  "type": "Catalog", "name": "Организации",
  "descriptionLength": 100,
  "attributes": ["ИНН: String(12)", "КПП: String(9)", "Директор: CatalogRef.ФизическиеЛица"]
}
```

### С табличной частью

```json
{
  "type": "Document", "name": "ПриходнаяНакладная",
  "registerRecords": ["AccumulationRegister.ОстаткиТоваров"],
  "attributes": ["Организация: CatalogRef.Организации", "Контрагент: CatalogRef.Контрагенты"],
  "tabularSections": { "Товары": ["Номенклатура: CatalogRef.Номенклатура", "Количество: Number(15,3)", "Цена: Number(15,2)"] }
}
```

### Регистровый паттерн (измерения + ресурсы)

```json
{
  "type": "InformationRegister", "name": "КурсыВалют", "periodicity": "Day",
  "dimensions": ["Валюта: CatalogRef.Валюты | master, mainFilter, denyIncomplete"],
  "resources": ["Курс: Number(15,4)", "Кратность: Number(10,0)"]
}
```

### Batch — несколько объектов в одном файле

```json
[
  { "type": "Enum", "name": "Статусы", "values": ["Новый", "Закрыт"] },
  { "type": "Catalog", "name": "Валюты" },
  { "type": "Constant", "name": "ОсновнаяВалюта", "valueType": "CatalogRef.Валюты" }
]
```

## Что генерируется

- `{TypePlural}/{Name}.xml` — метаданные объекта
- `{TypePlural}/{Name}/Ext/*.bsl` — модули (ObjectModule, RecordSetModule, Module — зависит от типа)
- `Configuration.xml` — автоматическая регистрация в `<ChildObjects>`

