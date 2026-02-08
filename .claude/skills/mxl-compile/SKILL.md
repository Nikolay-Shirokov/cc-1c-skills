---
name: mxl-compile
description: Компиляция табличного документа (MXL) из JSON-определения
argument-hint: <JsonPath> <OutputPath>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /mxl-compile — Компилятор макета из DSL

Принимает компактное JSON-определение макета и генерирует корректный Template.xml для табличного документа 1С. Claude описывает *что* нужно (области, параметры, стили), скрипт обеспечивает *корректность* XML (палитры, индексы, объединения, namespace).

## Использование

```
/mxl-compile <JsonPath> <OutputPath>
```

## Параметры

| Параметр   | Обязательный | Описание                           |
|------------|:------------:|------------------------------------|
| JsonPath   | да           | Путь к JSON-определению макета     |
| OutputPath | да           | Путь для генерации Template.xml    |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/mxl-compile/scripts/mxl-compile.ps1 -JsonPath "<путь>.json" -OutputPath "<путь>/Template.xml"
```

## Рабочий процесс

1. Claude пишет JSON-определение (Write tool) → файл `.json`
2. Claude вызывает `/mxl-compile` для генерации Template.xml
3. Claude вызывает `/mxl-validate` для проверки корректности
4. Claude вызывает `/mxl-info` для верификации структуры

**Если макет создаётся по изображению** (скриншот, скан печатной формы) — сначала вызвать `/img-grid` для наложения сетки, по ней определить границы колонок и пропорции, затем использовать `"Nx"` ширины + `"page"` для автоматического расчёта размеров.

## JSON-схема DSL

Полная спецификация формата: **`docs/mxl-dsl-spec.md`** (прочитать через Read tool перед написанием JSON).

Краткая структура:

```
{ columns, page, defaultWidth, columnWidths,
  fonts: { name: { face, size, bold, italic, underline, strikeout } },
  styles: { name: { font, align, valign, border, borderWidth, wrap, format } },
  areas: [{ name, rows: [{ height, rowStyle, cells: [
    { col, span, rowspan, style, param, detail, text, template }
  ]}]}]
}
```

Ключевые правила:
- `page` — формат страницы (`"A4-landscape"`, `"A4-portrait"` или число). Автоматически вычисляет `defaultWidth` из суммы пропорций `"Nx"`
- `col` — 1-based позиция колонки
- `rowStyle` — автозаполнение пустот стилем (рамки по всей ширине)
- Тип заполнения определяется автоматически: `param` → Parameter, `text` → Text, `template` → Template
- `rowspan` — объединение строк вниз (rowStyle учитывает занятые ячейки)
