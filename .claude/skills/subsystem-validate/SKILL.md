---
name: subsystem-validate
description: Валидация подсистемы 1С. Используй после создания или модификации подсистемы для проверки корректности
argument-hint: <SubsystemPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /subsystem-validate — валидация подсистемы 1С

Проверяет структурную корректность XML-файла подсистемы из выгрузки конфигурации.

## Использование

```
/subsystem-validate Subsystems/Продажи
/subsystem-validate Subsystems/Продажи.xml
```

## Параметры

| Параметр      | Обяз. | Умолч. | Описание                                  |
|---------------|:-----:|---------|--------------------------------------------|
| SubsystemPath | да    | —       | Путь к XML-файлу подсистемы                |
| Detailed      | нет   | —       | Показывать [OK] для каждой проверки        |
| MaxErrors     | нет   | 30      | Остановиться после N ошибок                |
| OutFile       | нет   | —       | Записать результат в файл                  |

## Команда

```powershell
powershell.exe -NoProfile -File ".claude/skills/subsystem-validate/scripts/subsystem-validate.ps1" -SubsystemPath "Subsystems/Продажи"
```

## Проверки (13)

| # | Проверка | Серьёзность |
|---|----------|-------------|
| 1 | XML well-formedness + root structure (MetaDataObject/Subsystem) | ERROR |
| 2 | Properties — 9 обязательных свойств | ERROR |
| 3 | Name — непустой, валидный идентификатор | ERROR |
| 4 | Synonym — непустой (хотя бы один v8:item) | WARN |
| 5 | Булевы свойства — содержат true/false | ERROR |
| 6 | Content — формат xr:Item, xsi:type | ERROR |
| 7 | Content — нет дубликатов | WARN |
| 8 | ChildObjects — элементы непустые | ERROR |
| 9 | ChildObjects — нет дубликатов | WARN |
| 10 | ChildObjects → файлы существуют | WARN |
| 11 | CommandInterface.xml — well-formedness | ERROR |
| 12 | Picture — формат ссылки | ERROR |
| 13 | UseOneCommand=true → ровно 1 элемент в Content | ERROR |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
