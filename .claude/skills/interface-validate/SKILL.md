---
name: interface-validate
description: Валидация командного интерфейса 1С. Используй после настройки командного интерфейса подсистемы для проверки корректности
argument-hint: <CIPath> [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /interface-validate — валидация CommandInterface.xml

Проверяет XML командного интерфейса из выгрузки конфигурации на структурные ошибки: корневой элемент, допустимые секции, порядок, формат ссылок на команды, дубликаты.

## Параметры

| Параметр  | Обязательный | По умолчанию | Описание                            |
|-----------|:------------:|--------------|------------------------------------|
| CIPath    | да           | —            | Путь к CommandInterface.xml        |
| MaxErrors | нет          | 30           | Остановиться после N ошибок         |
| OutFile   | нет          | —            | Записать результат в файл (UTF-8 BOM) |

## Команда

```powershell
powershell.exe -NoProfile -File '.claude\skills\interface-validate\scripts\interface-validate.ps1' -CIPath '<path>'
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

## Вывод

```
=== Validation: CommandInterface (Продажи) ===

[OK]    1. Root structure: CommandInterface, version 2.17, namespace valid
[OK]    2. Child elements: 5 valid sections
[OK]    3. Section order: correct
[OK]    4. No duplicate sections
[OK]    5. CommandsVisibility: 55 entries, all valid
[OK]    6. CommandsVisibility: no duplicates
[OK]    7. CommandsPlacement: 3 entries, all valid
[OK]    8. CommandsOrder: 12 entries, all valid
[OK]    9. SubsystemsOrder: 9 entries, all valid format
[OK]    10. SubsystemsOrder: no duplicates
[OK]    11. GroupsOrder: 7 entries, all valid
[OK]    12. GroupsOrder: no duplicates
[OK]    13. Command reference format: all valid
---
Errors: 0, Warnings: 0
```

Код возврата: 0 = все проверки пройдены, 1 = есть ошибки.

## Примеры

```powershell
# CommandInterface подсистемы
... -CIPath upload/acc_8.3.24/Subsystems/Продажи/Ext/CommandInterface.xml

# Корневой CommandInterface конфигурации
... -CIPath upload/acc_8.3.24/Ext/CommandInterface.xml

# С лимитом ошибок
... -CIPath <path> -MaxErrors 10
```
