---
name: epf-remove-template
description: Удалить макет из внешней обработки 1С
argument-hint: <ProcessorName> <TemplateName>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /epf-remove-template — Удаление макета

Удаляет макет и убирает его регистрацию из корневого XML обработки.

## Usage

```
/epf-remove-template <ProcessorName> <TemplateName>
```

| Параметр      | Обязательный | По умолчанию | Описание                            |
|---------------|:------------:|--------------|-------------------------------------|
| ProcessorName | да           | —            | Имя обработки                       |
| TemplateName  | да           | —            | Имя макета для удаления             |
| SrcDir        | нет          | `src`        | Каталог исходников                  |

## Команда

```powershell
pwsh -NoProfile -File .claude/skills/epf-remove-template/scripts/remove-template.ps1 -ProcessorName "<ProcessorName>" -TemplateName "<TemplateName>" [-SrcDir "<SrcDir>"]
```

## Что удаляется

```
<SrcDir>/<ProcessorName>/Templates/<TemplateName>.xml     # Метаданные макета
<SrcDir>/<ProcessorName>/Templates/<TemplateName>/         # Каталог макета (рекурсивно)
```

## Что модифицируется

- `<SrcDir>/<ProcessorName>.xml` — убирается `<Template>` из `ChildObjects`