---
name: epf-add-template
description: Добавить макет к внешней обработке 1С
argument-hint: <ProcessorName> <TemplateName> <TemplateType>
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /epf-add-template — Добавление макета

Создаёт макет указанного типа и регистрирует его в корневом XML обработки.

## Usage

```
/epf-add-template <ProcessorName> <TemplateName> <TemplateType>
```

| Параметр      | Обязательный | По умолчанию    | Описание                                         |
|---------------|:------------:|-----------------|--------------------------------------------------|
| ProcessorName | да           | —               | Имя обработки                                    |
| TemplateName  | да           | —               | Имя макета                                       |
| TemplateType  | да           | —               | Тип: HTML, Text, SpreadsheetDocument, BinaryData |
| Synonym       | нет          | = TemplateName  | Синоним макета                                   |
| SrcDir        | нет          | `src`           | Каталог исходников                               |

## Команда

```powershell
pwsh -NoProfile -File .claude/skills/epf-add-template/scripts/add-template.ps1 -ProcessorName "<ProcessorName>" -TemplateName "<TemplateName>" -TemplateType "<TemplateType>" [-Synonym "<Synonym>"] [-SrcDir "<SrcDir>"]
```

## Маппинг типов

Пользователь может указать тип в свободной форме. Определи нужный по контексту:

| Пользователь пишет                          | TemplateType        | Расширение | Содержимое              |
|---------------------------------------------|---------------------|------------|-------------------------|
| HTML                                        | HTMLDocument        | `.html`    | Пустой HTML-документ    |
| Text, текстовый документ, текст             | TextDocument        | `.txt`     | Пустой файл             |
| SpreadsheetDocument, табличный документ, MXL | SpreadsheetDocument | `.xml`     | Минимальный spreadsheet |
| BinaryData, двоичные данные                 | BinaryData          | `.bin`     | Пустой файл             |

## Что создаётся

```
<SrcDir>/<ProcessorName>/Templates/
├── <TemplateName>.xml              # Метаданные макета (1 UUID)
└── <TemplateName>/
    └── Ext/
        └── Template.<ext>          # Содержимое макета
```

## Что модифицируется

- `<SrcDir>/<ProcessorName>.xml` — добавляется `<Template>` в конец `ChildObjects`