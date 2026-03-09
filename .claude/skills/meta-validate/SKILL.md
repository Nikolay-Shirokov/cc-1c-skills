---
name: meta-validate
description: Валидация объекта метаданных 1С. Используй после создания или модификации объекта конфигурации для проверки корректности
argument-hint: <ObjectPath> [-Detailed] [-MaxErrors 30] — pipe-separated paths for batch
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /meta-validate — валидация объекта метаданных 1С

Проверяет XML объекта метаданных из выгрузки конфигурации на структурные ошибки.

## Использование

```
/meta-validate Catalogs/Номенклатура/Номенклатура.xml
/meta-validate Catalogs/Банки|Documents/Заказ     — batch mode
```

## Параметры

| Параметр   | Обяз. | Умолч. | Описание                                      |
|------------|:-----:|---------|-------------------------------------------------|
| ObjectPath | да    | —       | Путь к XML-файлу или каталогу. Через `\|` для batch |
| Detailed   | нет   | —       | Показывать [OK] для каждой проверки             |
| MaxErrors  | нет   | 30      | Остановиться после N ошибок (per object)        |
| OutFile    | нет   | —       | Записать результат в файл (UTF-8 BOM)           |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/meta-validate/scripts/meta-validate.ps1 -ObjectPath "Catalogs/Номенклатура/Номенклатура.xml"
```

## Поддерживаемые типы (23)

**Ссылочные:** Catalog, Document, Enum, ExchangePlan, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes, BusinessProcess, Task
**Регистры:** InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister
**Отчёты/Обработки:** Report, DataProcessor
**Сервисные:** CommonModule, ScheduledJob, EventSubscription, HTTPService, WebService
**Прочие:** Constant, DocumentJournal, DefinedType

## Проверки

| #  | Проверка                                | Серьёзность  |
|----|------------------------------------------|--------------|
| 1  | XML well-formedness + root structure     | ERROR        |
| 2  | InternalInfo / GeneratedType             | ERROR / WARN |
| 3  | Properties — Name, Synonym               | ERROR / WARN |
| 4  | Properties — enum-значения свойств       | ERROR        |
| 5  | StandardAttributes                       | ERROR / WARN |
| 6  | ChildObjects — допустимые элементы       | ERROR        |
| 7  | Attributes/Dimensions/Resources — UUID, Name, Type | ERROR |
| 7b | Reserved attribute names                 | WARN         |
| 8  | Уникальность имён                       | ERROR        |
| 9  | TabularSections — внутренняя структура   | ERROR / WARN |
| 10 | Кросс-свойства                          | ERROR / WARN |
| 11 | HTTPService/WebService — вложенная структура | ERROR   |
| 12 | Forbidden properties per type            | ERROR        |
| 13 | Method reference (Handler/MethodName)    | ERROR / WARN |
| 14 | DocumentJournal Columns                  | ERROR        |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
