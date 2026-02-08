---
name: epf-remove-form
description: Удалить форму из внешней обработки 1С
argument-hint: <ProcessorName> <FormName>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /epf-remove-form — Удаление формы

Удаляет форму и убирает её регистрацию из корневого XML обработки.

## Usage

```
/epf-remove-form <ProcessorName> <FormName>
```

| Параметр      | Обязательный | По умолчанию | Описание                            |
|---------------|:------------:|--------------|-------------------------------------|
| ProcessorName | да           | —            | Имя обработки                       |
| FormName      | да           | —            | Имя формы для удаления              |
| SrcDir        | нет          | `src`        | Каталог исходников                  |

## Команда

```powershell
pwsh -NoProfile -File .claude/skills/epf-remove-form/scripts/remove-form.ps1 -ProcessorName "<ProcessorName>" -FormName "<FormName>" [-SrcDir "<SrcDir>"]
```

## Что удаляется

```
<SrcDir>/<ProcessorName>/Forms/<FormName>.xml     # Метаданные формы
<SrcDir>/<ProcessorName>/Forms/<FormName>/         # Каталог формы (рекурсивно)
```

## Что модифицируется

- `<SrcDir>/<ProcessorName>.xml` — убирается `<Form>` из `ChildObjects`
- Если удаляемая форма была DefaultForm — очищается значение DefaultForm