---
name: meta-validate
description: Валидация структурной корректности объекта метаданных 1С (Справочник, Документ, Регистр, Перечисление и ещё 19 типов)
argument-hint: <ObjectPath> [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /meta-validate — валидация объекта метаданных 1С

Проверяет XML объекта метаданных из выгрузки конфигурации на структурные ошибки: корневую структуру, InternalInfo, свойства, допустимые значения, StandardAttributes, ChildObjects, уникальность имён, табличные части, кросс-свойства, вложенные структуры HTTP/Web-сервисов.

## Использование

```
/meta-validate <ObjectPath>
```

## Параметры

| Параметр   | Обязательный | По умолчанию | Описание                                      |
|------------|:------------:|--------------|-------------------------------------------------|
| ObjectPath | да           | —            | Путь к XML-файлу или каталогу объекта           |
| MaxErrors  | нет          | 30           | Остановиться после N ошибок                     |
| OutFile    | нет          | —            | Записать результат в файл (UTF-8 BOM)           |

`ObjectPath` авторезолв: если указана директория — ищет `<dirName>/<dirName>.xml`.

## Команда

```powershell
powershell.exe -NoProfile -File .claude\skills\meta-validate\scripts\meta-validate.ps1 -ObjectPath "<путь>"
```

## Поддерживаемые типы (23)

**Ссылочные:** Catalog, Document, Enum, ExchangePlan, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes, BusinessProcess, Task
**Регистры:** InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister
**Отчёты/Обработки:** Report, DataProcessor
**Сервисные:** CommonModule, ScheduledJob, EventSubscription, HTTPService, WebService
**Прочие:** Constant, DocumentJournal, DefinedType

## Выполняемые проверки

| #  | Проверка                                | Серьёзность  |
|----|------------------------------------------|--------------|
| 1  | XML well-formedness + root structure     | ERROR        |
| 2  | InternalInfo / GeneratedType             | ERROR / WARN |
| 3  | Properties — Name, Synonym               | ERROR / WARN |
| 4  | Properties — enum-значения свойств       | ERROR        |
| 5  | StandardAttributes                       | ERROR / WARN |
| 6  | ChildObjects — допустимые элементы       | ERROR        |
| 7  | Attributes/Dimensions/Resources — UUID, Name, Type | ERROR |
| 8  | Уникальность имён                       | ERROR        |
| 9  | TabularSections — внутренняя структура   | ERROR / WARN |
| 10 | Кросс-свойства                          | ERROR / WARN |
| 11 | HTTPService/WebService — вложенная структура | ERROR   |

## Вывод

```
=== Validation: Catalog.Номенклатура ===

[OK]    1. Root structure: MetaDataObject/Catalog, version 2.17
[OK]    2. InternalInfo: 5 GeneratedType (Object, Ref, Selection, List, Manager)
[OK]    3. Properties: Name="Номенклатура", Synonym present
[OK]    4. Property values: 12 enum properties checked
[ERROR] 5. StandardAttributes: missing "PredefinedDataName"
[OK]    6. ChildObjects types: Attribute(15), TabularSection(3), Form(4)
[OK]    7. Attributes/Dimensions: all valid
[WARN]  8. Name uniqueness: duplicate attribute "Комментарий" at positions 5, 12
[OK]    9. TabularSections: 3 sections, structure valid
[OK]    10. Cross-property consistency
[OK]    11. N/A (not HTTPService/WebService)
---
Errors: 1, Warnings: 1
```

Код возврата: 0 = все проверки пройдены, 1 = есть ошибки.

## Примеры

```powershell
# Справочник из выгрузки конфигурации
... -ObjectPath upload/acc_8.3.24/Catalogs/Банки/Банки.xml

# Авторезолв из директории
... -ObjectPath upload/acc_8.3.24/Documents/АвансовыйОтчет

# С лимитом ошибок
... -ObjectPath Catalogs/Номенклатура.xml -MaxErrors 10

# С записью в файл
... -ObjectPath Catalogs/Номенклатура.xml -OutFile result.txt
```

## Верификация

```
/meta-compile <JsonPath> <OutputDir>    — генерация XML
/meta-validate <OutputDir>/<Type>/<Name>.xml  — проверка результата
/meta-info <OutputDir>/<Type>/<Name>.xml      — визуальная сводка
```

## Когда использовать

- **После `/meta-compile`**: проверить корректность сгенерированного XML
- **После ручного редактирования**: убедиться что структура не нарушена
- **После merge/импорта**: выявить конфликты и битые ссылки
- **При отладке**: найти структурные ошибки до сборки EPF
