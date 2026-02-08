---
name: epf-init
description: Создать пустую внешнюю обработку 1С (scaffold XML-исходников)
argument-hint: <Name> [Synonym]
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /epf-init — Создание новой обработки

Генерирует минимальный набор XML-исходников для внешней обработки 1С: корневой файл метаданных и каталог обработки.

## Usage

```
/epf-init <Name> [Synonym] [SrcDir]
```

| Параметр  | Обязательный | По умолчанию | Описание                            |
|-----------|:------------:|--------------|-------------------------------------|
| Name      | да           | —            | Имя обработки (латиница/кириллица)  |
| Synonym   | нет          | = Name       | Синоним (отображаемое имя)          |
| SrcDir    | нет          | `src`        | Каталог исходников относительно CWD |

## Команда

```powershell
pwsh -NoProfile -File .claude/skills/epf-init/scripts/init.ps1 -Name "<Name>" [-Synonym "<Synonym>"] [-SrcDir "<SrcDir>"]
```

## Что создаётся

```
<SrcDir>/
├── <Name>.xml          # Корневой файл метаданных (4 UUID)
└── <Name>/
    └── Ext/
        └── ObjectModule.bsl  # Модуль объекта с 3 регионами
```

- Корневой XML содержит `MetaDataObject/ExternalDataProcessor` с пустыми `DefaultForm` и `ChildObjects`
- ClassId фиксирован: `c3831ec8-d8d5-4f93-8a22-f9bfae07327f`
- Файл создаётся в UTF-8 с BOM

## Дальнейшие шаги

- Добавить форму: `/epf-add-form`
- Добавить макет: `/epf-add-template`
- Собрать EPF: `/epf-build`
