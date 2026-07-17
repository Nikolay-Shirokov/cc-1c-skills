---
name: mxl-decompile
description: Декомпиляция табличного документа (MXL) в JSON-определение. Используй когда нужно получить редактируемое описание существующего макета
argument-hint: <TemplatePath> [OutputPath]
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /mxl-decompile — Декомпилятор макета в DSL

Принимает Template.xml табличного документа 1С и генерирует компактное JSON-определение (DSL). Обратная операция к `/mxl-compile`.

## Использование

```
/mxl-decompile <TemplatePath> [OutputPath]
```

## Параметры

| Параметр     | Обязательный | Описание                                |
|--------------|:------------:|-----------------------------------------|
| TemplatePath | да           | Путь к Template.xml                     |
| OutputPath   | нет          | Путь для JSON (если не указан — stdout) |

## Команда

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/mxl-decompile.ps1" -TemplatePath "<путь>/Template.xml" [-OutputPath "<путь>.json"]
```

## Рабочий процесс

Декомпиляция существующего макета для анализа или доработки:

1. Вызвать `/mxl-decompile` для получения JSON из Template.xml
2. Проанализировать или изменить JSON (добавить области, поменять стили)
3. Вызвать `/mxl-compile` для генерации нового Template.xml
4. Вызвать `/mxl-validate` для проверки

Формат JSON на выходе — тот же DSL, что принимает `/mxl-compile`; его полное описание живёт в навыке `/mxl-compile`.
