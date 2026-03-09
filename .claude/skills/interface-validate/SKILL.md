---
name: interface-validate
description: Валидация командного интерфейса 1С. Используй после настройки командного интерфейса подсистемы для проверки корректности
argument-hint: <CIPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /interface-validate — валидация CommandInterface.xml

Проверяет XML командного интерфейса на структурные ошибки: корневой элемент, допустимые секции, порядок, формат ссылок на команды, дубликаты.

## Использование

```
/interface-validate Subsystems/Продажи
/interface-validate Subsystems/Продажи/Ext/CommandInterface.xml
```

## Параметры

| Параметр  | Обяз. | Умолч. | Описание                                |
|-----------|:-----:|---------|-----------------------------------------|
| CIPath    | да    | —       | Путь к CommandInterface.xml             |
| Detailed  | нет   | —       | Показывать [OK] для каждой проверки      |
| MaxErrors | нет   | 30      | Остановиться после N ошибок              |
| OutFile   | нет   | —       | Записать результат в файл (UTF-8 BOM)   |

## Команда

```powershell
powershell.exe -NoProfile -File ".claude/skills/interface-validate/scripts/interface-validate.ps1" -CIPath "Subsystems/Продажи"
```

## Проверки (13)

| #  | Проверка                                                    | Серьёзность |
|----|--------------------------------------------------------------|-------------|
| 1  | XML well-formedness + root element (CommandInterface, version, namespace) | ERROR |
| 2  | Допустимые дочерние элементы (только 5 секций)               | ERROR |
| 3  | Порядок секций корректен                                     | ERROR |
| 4  | Нет дублирующихся секций                                     | ERROR |
| 5  | CommandsVisibility — Command.name + Visibility/xr:Common     | ERROR |
| 6  | CommandsVisibility — нет дубликатов по name                  | WARN  |
| 7  | CommandsPlacement — Command.name + CommandGroup + Placement  | ERROR |
| 8  | CommandsOrder — Command.name + CommandGroup                  | ERROR |
| 9  | SubsystemsOrder — Subsystem непустой, формат Subsystem.X     | ERROR |
| 10 | SubsystemsOrder — нет дубликатов                             | WARN  |
| 11 | GroupsOrder — Group непустой                                 | ERROR |
| 12 | GroupsOrder — нет дубликатов                                 | WARN  |
| 13 | Формат ссылок на команды                                     | WARN  |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
