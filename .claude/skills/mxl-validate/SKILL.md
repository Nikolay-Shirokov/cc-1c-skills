---
name: mxl-validate
description: Валидация макета табличного документа (MXL). Используй после создания или модификации макета для проверки корректности
argument-hint: <TemplatePath> или <ProcessorName> <TemplateName>
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /mxl-validate — Валидатор макета

Проверяет Template.xml на структурные ошибки, которые платформа 1С может молча проигнорировать (с возможной потерей данных или повреждением макета).

## Использование

```
/mxl-validate <TemplatePath>
/mxl-validate <ProcessorName> <TemplateName>
```

## Параметры

| Параметр      | Обязательный | По умолчанию | Описание                                 |
|---------------|:------------:|--------------|------------------------------------------|
| TemplatePath  | нет          | —            | Прямой путь к Template.xml               |
| ProcessorName | нет          | —            | Имя обработки (альтернатива пути)        |
| TemplateName  | нет          | —            | Имя макета (альтернатива пути)           |
| SrcDir        | нет          | `src`        | Каталог исходников                       |
| MaxErrors     | нет          | 20           | Остановиться после N ошибок              |

Укажите либо `-TemplatePath`, либо оба `-ProcessorName` и `-TemplateName`.

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/mxl-validate/scripts/mxl-validate.ps1 -TemplatePath "<путь>"
```

Или по имени обработки/макета:
```powershell
powershell.exe -NoProfile -File .claude/skills/mxl-validate/scripts/mxl-validate.ps1 -ProcessorName "<Имя>" -TemplateName "<Макет>" [-SrcDir "<каталог>"]
```

## Выполняемые проверки

| # | Проверка | Серьёзность |
|---|---|---|
| 1 | `<height>` >= максимальный индекс строки + 1 | ERROR |
| 2 | `<vgRows>` <= `<height>` | WARN |
| 3 | Индексы форматов ячеек (`<f>`) в пределах палитры форматов | ERROR |
| 4 | `<formatIndex>` строк и колонок в пределах палитры | ERROR |
| 5 | Индексы колонок в ячейках (`<i>`) в пределах количества колонок (с учётом набора) | ERROR |
| 6 | `<columnsID>` строк ссылается на существующий набор колонок | ERROR |
| 7 | `<columnsID>` в merge/namedItem ссылается на существующий набор | ERROR |
| 8 | Диапазоны именованных областей в пределах границ документа | ERROR |
| 9 | Диапазоны объединений в пределах границ документа | ERROR |
| 10 | Индексы шрифтов в форматах в пределах палитры шрифтов | ERROR |
| 11 | Индексы линий границ в форматах в пределах палитры линий | ERROR |
| 12 | `pictureIndex` рисунков ссылается на существующую картинку | ERROR |

## Вывод

```
=== Validation: ИмяМакета ===

[OK]    height (40) >= max row index + 1 (40), rowsItem count=34
[OK]    Font refs: max=3, palette size=4
[ERROR] Row 15: cell format index 38 > format palette size (37)
[OK]    Column indices: max in default set=32, default column count=33
---
Errors: 1, Warnings: 0
```

Код возврата: 0 = все проверки пройдены, 1 = есть ошибки.

## Когда использовать

- **После генерации макета**: запустить валидатор для выявления структурных ошибок до сборки EPF
- **После редактирования Template.xml**: убедиться, что индексы и ссылки остались валидными
- **При ошибках**: исправить найденные проблемы и перезапустить до полного прохождения

## Защита от переполнения

Останавливается после 20 ошибок по умолчанию (настраивается через `-MaxErrors`). Итоговая строка с количеством ошибок/предупреждений выводится всегда.
