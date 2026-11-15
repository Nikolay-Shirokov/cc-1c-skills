# Особые поля: HTML, текстовый документ, индикатор, ползунок, календарь, период

Поля для особых данных. У каждого — общие свойства поля (`path`, `title`, `titleLocation`, `readOnly`, размеры, события) и свои ключи ниже. Табличный документ — `references/spreadsheet.md`, диаграммы и планировщик — `references/charts.md`.

| Ключ типа | Тип реквизита |
|-----------|---------------|
| `html` | `string` (HTML-текст или адрес) |
| `textDoc` | `d5p1:TextDocument` |
| `formattedDoc` | `fd:FormattedDocument` |
| `progressBar` | число |
| `trackBar` | число |
| `calendar` | `date` |
| `periodField` | `v8:StandardPeriod` |

## html — HTML-документ

```json
{ "html": "Просмотр", "path": "СодержимоеHTML", "titleLocation": "none" }
```

`output` (`Enable` / `Disable`) — разрешить печать и сохранение.

## textDoc, formattedDoc — текстовый и форматированный документ

```json
{ "formattedDoc": "Описание", "path": "ФорматированноеОписание", "editMode": "Edit" }
```

`editMode` — `Edit` / `View`.

## progressBar — индикатор

```json
{ "progressBar": "Прогресс", "path": "Прогресс", "minValue": 0, "maxValue": 100, "showPercent": true }
```

## trackBar — ползунок

```json
{ "trackBar": "Масштаб", "path": "Масштаб", "minValue": 20, "maxValue": 400, "step": 10, "markingStep": 20 }
```

`step`, `largeStep`, `markingStep` — шаги; `markingAppearance` — вид разметки.

## calendar — календарь

```json
{ "calendar": "ДатаОтчета", "path": "ДатаОтчета", "selectionMode": "Interval", "widthInMonths": 2 }
```

| Ключ | Значения |
|------|----------|
| `selectionMode` | `Single` / `Multiple` / `Interval` |
| `showCurrentDate` | bool |
| `widthInMonths` / `heightInMonths` | число месяцев |
| `showMonthsPanel` | bool |

## periodField — поле периода

```json
{ "periodField": "Период", "path": "Период" }
```
