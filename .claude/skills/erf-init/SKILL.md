---
name: erf-init
description: Создать пустой внешний отчёт 1С (scaffold XML-исходников). Использовать, когда пользователь просит создать новый внешний отчёт (ERF) с нуля
argument-hint: <Name> [Synonym] [--with-skd]
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /erf-init — Создание нового отчёта

Генерирует минимальный набор XML-исходников для внешнего отчёта 1С: корневой файл метаданных и каталог отчёта.

## Usage

```
/erf-init <Name> [Synonym] [SrcDir] [--with-skd]
```

| Параметр  | Обязательный | По умолчанию | Описание                              |
|-----------|:------------:|--------------|---------------------------------------|
| Name      | да           | —            | Имя отчёта (латиница/кириллица)       |
| Synonym   | нет          | = Name       | Синоним (отображаемое имя)            |
| SrcDir    | нет          | `src`        | Каталог исходников относительно CWD   |
| --WithSKD | нет          | —            | Создать пустую СКД и привязать к MainDataCompositionSchema |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/erf-init/scripts/init.ps1 -Name "<Name>" [-Synonym "<Synonym>"] [-SrcDir "<SrcDir>"] [-WithSKD]
```

## Дальнейшие шаги

- Добавить форму: `/form-add`
- Добавить макет: `/template-add`
- Добавить справку: `/help-add`
- Собрать ERF: `/erf-build`
