---
name: mxl-validate
description: Validate SpreadsheetDocument (MXL) template for structural correctness
argument-hint: <TemplatePath> or <ProcessorName> <TemplateName>
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /mxl-validate — Template Validator

Checks Template.xml for structural errors that the 1C platform may silently ignore (potentially causing data loss or template corruption).

## Usage

```
/mxl-validate <TemplatePath>
/mxl-validate <ProcessorName> <TemplateName>
```

## Parameters

| Parameter     | Required | Default | Description                              |
|---------------|:--------:|---------|------------------------------------------|
| TemplatePath  | no       | —       | Direct path to Template.xml              |
| ProcessorName | no       | —       | Processor name (alternative to path)     |
| TemplateName  | no       | —       | Template name (alternative to path)      |
| SrcDir        | no       | `src`   | Source directory                         |
| MaxErrors     | no       | 20      | Stop after N errors                     |

Specify either `-TemplatePath` or both `-ProcessorName` and `-TemplateName`.

## Command

```powershell
powershell.exe -NoProfile -File .claude/skills/mxl-validate/scripts/mxl-validate.ps1 -TemplatePath "<path>"
```

Or with processor/template names:
```powershell
powershell.exe -NoProfile -File .claude/skills/mxl-validate/scripts/mxl-validate.ps1 -ProcessorName "<Name>" -TemplateName "<Template>" [-SrcDir "<dir>"]
```

## Checks Performed

| # | Check | Severity |
|---|---|---|
| 1 | `<height>` >= max row index + 1 | ERROR |
| 2 | `<vgRows>` <= `<height>` | WARN |
| 3 | Cell format indices (`<f>`) within format palette | ERROR |
| 4 | Row/column `<formatIndex>` within format palette | ERROR |
| 5 | Cell column indices (`<i>`) within column count (per column set) | ERROR |
| 6 | Row `<columnsID>` references existing column set | ERROR |
| 7 | Merge/namedItem `<columnsID>` references existing column set | ERROR |
| 8 | Named area row/column ranges within document bounds | ERROR |
| 9 | Merge ranges within document bounds | ERROR |
| 10 | Font indices in formats within font palette | ERROR |
| 11 | Border/line indices in formats within line palette | ERROR |
| 12 | Drawing `pictureIndex` references existing picture | ERROR |

## Output

```
=== Validation: TemplateName ===

[OK]    height (40) >= max row index + 1 (40), rowsItem count=34
[OK]    Font refs: max=3, palette size=4
[ERROR] Row 15: cell format index 38 > format palette size (37)
[OK]    Column indices: max in default set=32, default column count=33
---
Errors: 1, Warnings: 0
```

Exit code: 0 = all checks passed, 1 = errors found.

## When to Use

- **After generating a template**: run validator to catch structural errors before building EPF
- **After editing Template.xml**: verify indices and references are still valid
- **On errors**: fix the reported issues and re-run until all checks pass

## Error Protection

Stops after 20 errors by default (configurable with `-MaxErrors`). Summary line always shows total counts.
