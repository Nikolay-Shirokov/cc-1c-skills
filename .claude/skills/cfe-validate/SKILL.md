---
name: cfe-validate
description: Валидация расширения конфигурации 1С (CFE). Используй после создания или модификации расширения для проверки корректности
argument-hint: <ExtensionPath> [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cfe-validate — Валидация расширения конфигурации

Проверяет структурную корректность расширения: XML-формат, свойства, состав, заимствованные объекты. Аналог `/cf-validate`, но для расширений.

## Параметры

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `ExtensionPath` | Путь к каталогу или Configuration.xml расширения (обязат.) | — |
| `MaxErrors` | Лимит ошибок | 30 |
| `OutFile` | Записать результат в файл | — |

## Команда

```powershell
powershell.exe -NoProfile -File .claude\skills\cfe-validate\scripts\cfe-validate.ps1 -ExtensionPath src
```

## Проверки (9 шагов)

| # | Проверка | Уровень |
|---|----------|---------|
| 1 | XML well-formedness, MetaDataObject/Configuration, version | ERROR |
| 2 | InternalInfo: 7 ContainedObject, валидные ClassId | ERROR |
| 3 | Extension properties: ObjectBelonging=Adopted, Name, Purpose, NamePrefix, KeepMapping | ERROR |
| 4 | Enum-значения: ConfigurationExtensionCompatibilityMode, DefaultRunMode, ScriptVariant, InterfaceCompatibilityMode | ERROR |
| 5 | ChildObjects: валидные типы (44), нет дубликатов, каноничный порядок | ERROR/WARN |
| 6 | DefaultLanguage ссылается на Language в ChildObjects | ERROR |
| 7 | Файлы языков существуют | WARN |
| 8 | Каталоги объектов существуют | WARN |
| 9 | Заимствованные объекты: ObjectBelonging=Adopted, ExtendedConfigurationObject UUID | ERROR/WARN |

## Пример вывода

```
=== Validation: Extension.МоёРасширение ===
[OK]    1. Root structure: MetaDataObject/Configuration, version 2.17
[OK]    2. InternalInfo: 7 ContainedObject, all ClassIds valid
...
=== Result: 0 errors, 0 warnings ===
```
