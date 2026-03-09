---
name: epf-validate
description: Валидация внешней обработки 1С (EPF). Используй после создания или модификации обработки для проверки корректности
argument-hint: <ObjectPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /epf-validate — валидация внешней обработки (EPF)

Проверяет структурную корректность XML-исходников внешней обработки: корневую структуру, InternalInfo, свойства, ChildObjects, реквизиты, табличные части, уникальность имён, наличие файлов форм и макетов. Также работает для внешних отчётов (ERF).

## Использование

```
/epf-validate src/МояОбработка
/epf-validate src/МояОбработка/МояОбработка.xml
```

## Параметры

| Параметр   | Обяз. | Умолч. | Описание                                      |
|------------|:-----:|---------|-------------------------------------------------|
| ObjectPath | да    | —       | Путь к корневому XML или каталогу обработки     |
| Detailed   | нет   | —       | Показывать [OK] для каждой проверки             |
| MaxErrors  | нет   | 30      | Остановиться после N ошибок                     |
| OutFile    | нет   | —       | Записать результат в файл (UTF-8 BOM)           |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/epf-validate/scripts/epf-validate.ps1 -ObjectPath "src/МояОбработка"
```

## Проверки

| #  | Проверка                                              | Серьёзность  |
|----|-------------------------------------------------------|--------------|
| 1  | Root structure: MetaDataObject/ExternalDataProcessor   | ERROR        |
| 2  | InternalInfo: ClassId, ContainedObject, GeneratedType  | ERROR / WARN |
| 3  | Properties: Name (identifier), Synonym                 | ERROR / WARN |
| 4  | ChildObjects: допустимые типы, порядок                 | ERROR / WARN |
| 5  | Cross-references: DefaultForm → Form, AuxiliaryForm    | ERROR / WARN |
| 6  | Attributes: UUID, Name, Type                           | ERROR        |
| 7  | TabularSections: UUID, Name, GeneratedType, Attributes | ERROR / WARN |
| 8  | Уникальность имён (Attribute, TS, Form, Template, Command) | ERROR   |
| 9  | Файлы: формы (.xml + Ext/Form.xml), макеты            | ERROR        |
| 10 | Дескрипторы форм: корневая структура, uuid, Name, FormType | ERROR / WARN |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
