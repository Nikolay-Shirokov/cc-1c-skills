---
name: erf-validate
description: Валидация внешнего отчёта 1С (ERF). Используй после создания или модификации отчёта для проверки корректности
argument-hint: <ObjectPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /erf-validate — валидация внешнего отчёта (ERF)

Проверяет структурную корректность XML-исходников внешнего отчёта: корневую структуру, InternalInfo, свойства (включая MainDataCompositionSchema), ChildObjects, реквизиты, табличные части, уникальность имён, наличие файлов форм и макетов.

Использует тот же скрипт, что и `/epf-validate` — автоопределение по типу элемента (ExternalReport).

## Использование

```
/erf-validate src/МойОтчёт
/erf-validate src/МойОтчёт/МойОтчёт.xml
```

## Параметры

| Параметр   | Обяз. | Умолч. | Описание                                      |
|------------|:-----:|---------|-------------------------------------------------|
| ObjectPath | да    | —       | Путь к корневому XML или каталогу отчёта        |
| Detailed   | нет   | —       | Показывать [OK] для каждой проверки             |
| MaxErrors  | нет   | 30      | Остановиться после N ошибок                     |
| OutFile    | нет   | —       | Записать результат в файл (UTF-8 BOM)           |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/epf-validate/scripts/epf-validate.ps1 -ObjectPath "src/МойОтчёт"
```

## Проверки

| #  | Проверка                                              | Серьёзность  |
|----|-------------------------------------------------------|--------------|
| 1  | Root structure: MetaDataObject/ExternalReport          | ERROR        |
| 2  | InternalInfo: ClassId, ContainedObject, GeneratedType  | ERROR / WARN |
| 3  | Properties: Name, Synonym, MainDataCompositionSchema   | ERROR / WARN |
| 4  | ChildObjects: допустимые типы, порядок                 | ERROR / WARN |
| 5  | Cross-references: DefaultForm, MainDCS → Template      | ERROR / WARN |
| 6  | Attributes: UUID, Name, Type                           | ERROR        |
| 7  | TabularSections: UUID, Name, GeneratedType, Attributes | ERROR / WARN |
| 8  | Уникальность имён (Attribute, TS, Form, Template, Command) | ERROR   |
| 9  | Файлы: формы (.xml + Ext/Form.xml), макеты            | ERROR        |
| 10 | Дескрипторы форм: корневая структура, uuid, Name, FormType | ERROR / WARN |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
