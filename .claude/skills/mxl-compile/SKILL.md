---
name: mxl-compile
description: Компиляция табличного документа (MXL) из JSON-определения. Используй когда нужно создать макет печатной формы
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
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/mxl-compile.ps1" -JsonPath "<путь>.json" -OutputPath "<путь>/Template.xml"
```

## Рабочий процесс

1. Написать JSON-определение (Write tool) → файл `.json`
2. Вызвать `/mxl-compile` для генерации Template.xml
3. Вызвать `/mxl-validate` для проверки корректности
4. Вызвать `/mxl-info` для верификации структуры

**Если макет создаётся по изображению** (скриншот, скан печатной формы) — сначала вызвать `/img-grid` для наложения сетки, по ней определить границы колонок и пропорции, затем использовать `"Nx"` ширины + `"page"` для автоматического расчёта размеров.

## JSON-схема DSL

Ниже — компактная структура и ключевые правила, достаточные для типового макета. Полные таблицы полей (все свойства шрифтов, стилей, ячеек), развёрнутый пример и ограничения формата — в **`reference/dsl-spec.md`**; нужны не всегда, читать по необходимости.

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
- `empty` в строке — шорткат для N подряд пустых строк (`{ "empty": 3 }` = три `{}`)
