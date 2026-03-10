---
name: cfe-validate
description: Валидация расширения конфигурации 1С (CFE). Используй после создания или модификации расширения для проверки корректности
argument-hint: <ExtensionPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cfe-validate — валидация расширения конфигурации (CFE)

Проверяет структурную корректность расширения: XML-формат, свойства, состав, заимствованные объекты. Аналог `/cf-validate`, но для расширений.

## Параметры

| Параметр      | Обяз. | Умолч. | Описание                                        |
|---------------|:-----:|---------|-------------------------------------------------|
| ExtensionPath | да    | —       | Путь к каталогу или Configuration.xml расширения |
| Detailed      | нет   | —       | Показывать [OK] для каждой проверки              |
| MaxErrors     | нет   | 30      | Остановиться после N ошибок                      |
| OutFile       | нет   | —       | Записать результат в файл                        |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/cfe-validate/scripts/cfe-validate.ps1 -ExtensionPath "src"
powershell.exe -NoProfile -File .claude/skills/cfe-validate/scripts/cfe-validate.ps1 -ExtensionPath "src/Configuration.xml"
```

## Проверки (13 шагов)

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
| 10 | Sub-items: Attribute, TabularSection (InternalInfo + вложенные), EnumValue, Form-ссылки | ERROR |
| 11 | Заимствованные формы: метаданные, Form.xml, Module.bsl, BaseForm version | ERROR/WARN |
| 12 | Зависимости форм: CommonPicture, StyleItem (с whitelist платформенных), Enum DesignTimeRef | WARN |
| 13 | TypeLink: human-readable Items.* DataPath (должны быть удалены) | WARN |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
