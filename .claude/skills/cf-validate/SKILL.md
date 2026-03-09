---
name: cf-validate
description: Валидация конфигурации 1С. Используй после создания или модификации конфигурации для проверки корректности
argument-hint: <ConfigPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cf-validate — валидация конфигурации 1С

Проверяет Configuration.xml на структурные ошибки: XML well-formedness, InternalInfo, свойства, enum-значения, ChildObjects, DefaultLanguage, файлы языков, каталоги объектов.

## Использование

```
/cf-validate upload/cfempty
/cf-validate upload/cfempty/Configuration.xml
```

## Параметры

| Параметр   | Обяз. | Умолч. | Описание                                      |
|------------|:-----:|---------|-------------------------------------------------|
| ConfigPath | да    | —       | Путь к Configuration.xml или каталогу выгрузки  |
| Detailed   | нет   | —       | Показывать [OK] для каждой проверки             |
| MaxErrors  | нет   | 30      | Остановиться после N ошибок                     |
| OutFile    | нет   | —       | Записать результат в файл (UTF-8 BOM)           |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/cf-validate/scripts/cf-validate.ps1 -ConfigPath "upload/cfempty"
```

## Проверки

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

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
