---
name: form-remove
description: Удалить форму из объекта 1С (обработка, отчёт, справочник, документ и др.)
argument-hint: <ObjectName> <FormName>
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /form-remove — Удаление формы

Удаляет форму и убирает её регистрацию из корневого XML объекта.

## Usage

```
/form-remove <ObjectName> <FormName>
```

| Параметр   | Обязательный | По умолчанию | Описание                            |
|------------|:------------:|--------------|-------------------------------------|
| ObjectName | да           | —            | Имя объекта                         |
| FormName   | да           | —            | Имя формы для удаления              |
| SrcDir     | нет          | `src`        | Каталог исходников                  |
| Force      | нет          | —            | Удалить, даже если на форму ссылаются, и очистить ссылки |

## Команда

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".codex/skills/form-remove/scripts/remove-form.ps1" -ObjectName "<ObjectName>" -FormName "<FormName>" [-SrcDir "<SrcDir>"] [-Force]
```

## Что удаляется

```
<SrcDir>/<ObjectName>/Forms/<FormName>.xml     # Метаданные формы
<SrcDir>/<ObjectName>/Forms/<FormName>/         # Каталог формы (рекурсивно)
```

## Что модифицируется

- `<SrcDir>/<ObjectName>.xml` — убирается `<Form>` из `ChildObjects`
- Свойства объекта, указывавшие на удалённую форму — очищаются
