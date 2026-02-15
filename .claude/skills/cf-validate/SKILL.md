---
name: cf-validate
description: Валидация конфигурации 1С. Используй после создания или модификации конфигурации для проверки корректности
argument-hint: <ConfigPath> [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cf-validate — валидация конфигурации 1С

Проверяет Configuration.xml на структурные ошибки: XML well-formedness, InternalInfo, свойства, enum-значения, ChildObjects, DefaultLanguage, файлы языков, каталоги объектов.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `ConfigPath` | Путь к Configuration.xml или каталогу выгрузки |
| `MaxErrors` | Остановиться после N ошибок (default: 30) |
| `OutFile` | Записать результат в файл (UTF-8 BOM) |

```powershell
powershell.exe -NoProfile -File .claude\skills\cf-validate\scripts\cf-validate.ps1 -ConfigPath "<путь>"
```

## Выполняемые проверки

| # | Проверка | Серьёзность |
|---|----------|-------------|
| 1 | XML well-formedness, MetaDataObject/Configuration, version 2.17/2.20 | ERROR |
| 2 | InternalInfo: 7 ContainedObject, валидные ClassId, уникальность | ERROR |
| 3 | Properties: Name непустой, Synonym, DefaultLanguage, DefaultRunMode | ERROR/WARN |
| 4 | Properties: enum-значения (11 свойств) | ERROR |
| 5 | ChildObjects: валидные имена типов (44 типа), нет дубликатов, порядок типов | ERROR/WARN |
| 6 | DefaultLanguage ссылается на существующий Language в ChildObjects | ERROR |
| 7 | Файлы языков Languages/<name>.xml существуют | WARN |
| 8 | Каталоги объектов из ChildObjects существуют (spot-check) | WARN |

## Вывод

```
=== Validation: Configuration.МояКонфигурация ===

[OK]    1. Root structure: MetaDataObject/Configuration, version 2.17
[OK]    2. InternalInfo: 7 ContainedObject, all ClassIds valid
[OK]    3. Properties: Name="МояКонфигурация", Synonym present
[OK]    4. Property values: 11 enum properties checked
[OK]    5. ChildObjects: 1 types, 1 objects, order correct
[OK]    6. DefaultLanguage "Language.Русский" found in ChildObjects
[OK]    7. Language files: 1/1 exist
[OK]    8. Object directories: spot-check passed

=== Result: 0 errors, 0 warnings ===
```

Exit code: 0 = OK, 1 = errors.

## Примеры

```powershell
# Пустая конфигурация
... -ConfigPath upload/cfempty

# Реальная конфигурация
... -ConfigPath C:\WS\tasks\cfsrc\acc_8.3.24

# С лимитом ошибок
... -ConfigPath test-tmp/cf -MaxErrors 10
```
