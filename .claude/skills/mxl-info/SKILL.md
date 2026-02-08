---
name: mxl-info
description: Analyze SpreadsheetDocument (MXL) template structure — areas, parameters, column sets
argument-hint: <TemplatePath> or <ProcessorName> <TemplateName>
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /mxl-info — Template Structure Analyzer

Reads a SpreadsheetDocument Template.xml and outputs a compact summary: named areas, parameters, column sets. Replaces the need to read thousands of XML lines.

## Usage

```
/mxl-info <TemplatePath>
/mxl-info <ProcessorName> <TemplateName>
```

## Parameters

| Parameter     | Required | Default | Description                              |
|---------------|:--------:|---------|------------------------------------------|
| TemplatePath  | no       | —       | Direct path to Template.xml              |
| ProcessorName | no       | —       | Processor name (alternative to path)     |
| TemplateName  | no       | —       | Template name (alternative to path)      |
| SrcDir        | no       | `src`   | Source directory                         |
| Format        | no       | `text`  | Output format: `text` or `json`         |
| WithText      | no       | false   | Include static text and template content |
| MaxParams     | no       | 10      | Max parameters listed per area          |
| Limit         | no       | 150     | Max output lines (truncation protection) |
| Offset        | no       | 0       | Skip N lines (for pagination)           |

Specify either `-TemplatePath` or both `-ProcessorName` and `-TemplateName`.

## Command

```powershell
powershell.exe -NoProfile -File .claude/skills/mxl-info/scripts/mxl-info.ps1 -TemplatePath "<path>"
```

Or with processor/template names:
```powershell
powershell.exe -NoProfile -File .claude/skills/mxl-info/scripts/mxl-info.ps1 -ProcessorName "<Name>" -TemplateName "<Template>" [-SrcDir "<dir>"]
```

Additional flags:
```powershell
... -WithText              # include cell text content
... -Format json           # JSON output for programmatic use
... -MaxParams 20          # show more parameters per area
... -Offset 150            # pagination: skip first 150 lines
```

## Output (text mode)

```
=== TemplName ===
  Rows: 40, Columns: 33
  Column sets: 1 (default only)

--- Named areas ---
  Заголовок          Rows     rows 1-4     (1 params)
  Строка             Rows     rows 14-14   (8 params)
  Итого              Rows     rows 16-17   (1 params)

--- Parameters by area ---
  Заголовок: ТекстЗаголовка
  Строка: НомерСтроки, Товар, Количество, Цена, Сумма, ... (+3)
  Итого: Всего

--- Stats ---
  Merges: 43
  Drawings: 0
```

With `-WithText`, adds a section showing static text (labels, headers) and template strings:

```
--- Text content ---
  ШапкаТаблицы:
    Text: "№", "Товар", "Ед. изм.", "Кол-во", "Цена", "Сумма"
  Строка:
    Templates: "[НомерСтроки]", "[Товар] ([Артикул])"
```

## When to Use

- **Before writing fill code**: run `/mxl-info` to understand the template structure, then write BSL code based on area names and parameter lists
- **With `-WithText`**: when you need context about what labels/headers surround the parameters
- **With `-Format json`**: when you need structured data for programmatic processing
- **For existing templates**: analyze uploaded or configuration templates without reading raw XML

## Truncation Protection

Output is limited to 150 lines by default. If exceeded:
```
[TRUNCATED] Shown 150 of 220 lines. Use -Offset 150 to continue.
```

Use `-Offset N` and `-Limit N` to paginate through large outputs.
