# Диаграммы, диаграмма Ганта, планировщик

Поле-диаграмма (`chart` / `ganttChart`), поле-планировщик (`planner`) и дендрограмма выводят значение из реквизита соответствующего типа. Конструкция всегда двойная:

1. **Реквизит** chart/planner-типа (несёт данные и, при необходимости, design-time конфиг).
2. **Элемент** формы, привязанный к реквизиту через `path`.

Минимум — реквизит нужного типа плюс элемент с тем же `path`:

```json
"attributes": [ { "name": "Диаграмма", "type": "d5p1:Chart" } ],
"items":      [ { "chart": "ПолеДиаграммы", "path": "Диаграмма" } ]
```

Реквизит, заполняемый в коде (без встроенной настройки), достаточно объявить типом — элемент привязывается и работает.

## Типы реквизита и элемента

| Элемент | Ключ типа | Тип реквизита | Что несёт элемент дополнительно |
|---------|-----------|---------------|---------------------------------|
| Диаграмма | `chart` | `d5p1:Chart` | — |
| Диаграмма Ганта | `ganttChart` | `d5p1:GanttChart` | `ganttTable` — вложенная таблица (см. ниже) |
| Планировщик | `planner` | `pl:Planner` | — |
| График. схема | `graphicalSchema` | `d5p1:FlowchartContextType` | `edit`, `warningOnEditRepresentation` |
| Период | `periodField` | `v8:StandardPeriod` | — |
| Дендрограмма | `dendrogram` | — | — |

Имя элемента — значение ключа (`"chart": "ПолеДиаграммы"`); `path` — короткое имя реквизита.

### Элемент диаграммы Ганта (`ganttTable`)

У поля Ганта внутри лежит полноценная таблица — задаётся ключом `ganttTable` (та же грамматика, что у обычной `table`):

```json
{ "ganttChart": "Ганта", "path": "Ганта",
  "ganttTable": { "table": "ТаблицаГанта", "path": "Ганта", "height": 3 } }
```

## Design-time конфиг диаграммы (`chart`)

Реквизит типа `d5p1:Chart` / `d5p1:GanttChart` может нести встроенную настройку диаграммы — объект `chart` на реквизите. Платформа всегда пишет полный набор свойств (~127: тип, серии, легенда, заголовок, шкалы, цвета, шрифты, оси), поэтому **авторинг с нуля непрактичен** — возьмите рабочую диаграмму за основу и правьте смысловое ядро.

Ключи `chart` = канонические имена свойств диаграммы; задавайте только те, что меняете:

```json
{ "name": "Диаграмма", "type": "d5p1:Chart", "chart": {
  "chartType": "Line",
  "isSeriesDesign": true, "realSeriesCount": "2",
  "realSeriesData": [
    { "id": "1", "color": "auto", "line": {"width":2,"gap":false,"style":"Solid"},
      "marker": "Auto", "text": "Серия 1", "strIsChanged": false, "isExpand": false,
      "isIndicator": false, "colorPriority": false }
  ],
  "isShowTitle": true, "title": "Продажи",
  "isShowLegend": true, "legendPlacement": "Bottom",
  "paletteKind": "Auto"
} }
```

Смысловое ядро для правки:

| Ключ | Назначение |
|------|------------|
| `chartType` | Тип: `Line` / `Pie` / `Bar` / `Histogram` / `Column` / `Area` / … |
| `realSeriesData` | Массив серий — объекты `{ id, text, color, line, marker, … }` |
| `isShowTitle` + `title` | Показ и текст заголовка |
| `isShowLegend` + `legendPlacement` | Показ и расположение легенды (`Bottom` / `Right` / …) |
| `paletteKind` | Палитра (`Auto` / …) |
| `bkgColor` / `labelsColor` / … | Базовые цвета |

Формы значений внутри `chart`:

- **Цвета** — verbatim: `auto`, `style:ИмяСтиля`, `web:Red`, `#hex`.
- **`line`** — `{ width, gap, style }` (стиль линии: `Solid` / …).
- **`border`** — `{ width, style }`.
- **`font`** — `{ kind: "AutoFont" }` либо атрибуты шрифта.
- **Локализуемые строки** (`title`, `vsFormat`, `lbFormat`, `labelFormat`, серия `text`, …) — голая строка либо `{ "ru": "…", "en": "…" }`.
- **Области** (`elementsChart` / `elementsLegend` / `elementsTitle`) — `{ left, right, top, bottom }`.
- **Серии** (`realSeriesData` / `realExSeriesData`) — массивы объектов.

Любое из ~127 свойств переопределяется по каноническому имени; остальное оставляйте дефолтным (не указывайте — берётся из основы).

### Диаграмма Ганта (`d5p1:GanttChart`)

Реквизит типа `d5p1:GanttChart` использует **тот же** ключ `chart`. Внутри — вложенный полный `chart`-блок плюс гант-специфика (`points` / `series` / `timeScale` / `drawEmpty` / …). Так же берите рабочую диаграмму Ганта за основу.

> **Ограничение.** Диаграммы (Chart/Gantt) с заполненными **точками/осями** (`realPointData` / `realDataItems`, заполненные `valuesAxis` / `pointsAxis`) генерик-движком не поддержаны — это редкий вариант. Частые дашборд-диаграммы и диаграммы Ганта (серии / легенда / оформление / шкалы) поддержаны полностью.

## Design-time конфиг планировщика (`planner`)

Реквизит типа `pl:Planner` несёт встроенную настройку планировщика — объект `planner`. Компилятор подставляет умолчания для пропущенных ключей, поэтому авторинг может быть кратким:

```json
{ "name": "Планировщик", "type": "pl:Planner", "planner": {
  "items": [
    { "text": "Встреча", "begin": "2026-06-09T01:00:00", "end": "2026-06-09T04:00:00",
      "borderColor": "auto", "backColor": "auto", "deleted": false, "editMode": "EnableEdit" }
  ],
  "period": { "begin": "2026-06-09T00:00:00", "end": "2026-06-09T23:59:59" },
  "displayCurrentDate": true, "itemsTimeRepresentation": "BeginTime",
  "timeScale": { "placement": "Left", "levels": [ { "measure": "Hour", "interval": 1 } ] }
} }
```

Минимум — один `item`:

```json
"planner": { "items": [ { "text": "Встреча", "begin": "2026-06-09T01:00:00", "end": "2026-06-09T04:00:00" } ] }
```

| Ключ `planner` | Тип | Назначение |
|----------------|-----|------------|
| `items` | array | Элементы расписания. Поля элемента: `text`, `tooltip`, `begin`, `end`, `value`, `borderColor`, `backColor`, `textColor`, `font`, `border`, `replacementDate`, `deleted` (bool), `editMode` (`EnableEdit` / …), `id` (необязательно — авто-GUID), `textFormatted` |
| `dimensions` | array | Измерения (разрезы) планировщика. Поля: `value` (объект разреза — ссылка `Enum.X.EnumValue.Y` / `Справочник.X`; опустить → пусто), `text` (заголовок), `borderColor`, `backColor`, `textColor`, `font`, `textFormatted`, `elements`. `elements` — элементы измерения, рекурсивны (могут нести вложенные `elements`): `value`, `text`, цвета, `font`, `showOnlySubordinatesAreas` (bool), `textFormatted` |
| `period` | object | Отображаемый период `{ begin, end }` (необязательно) |
| `timeScale` | object | Шкала времени (см. ниже) |
| `borderColor` / `backColor` / `textColor` / `lineColor` | color | Цвета (умолч. `auto`) |
| `font` | font | Шрифт (умолч. `{ kind: "AutoFont" }`) |
| `border` | border | Рамка `{ width, style }` |
| `beginOfRepresentationPeriod` / `endOfRepresentationPeriod` | dateTime | Период представления |
| `displayCurrentDate` / `displayWrapHeaders` / `displayTimeScaleWrapHeaders` / `alignElementsOfTimeScale` | bool | Флаги отображения |
| `timeScaleWrapHeadersFormat` | ML | Формат перенесённых заголовков шкалы |
| `timeScaleWrapBeginIndent` / `timeScaleWrapEndIndent` | int | Отступы переноса шкалы |
| `periodicVariantUnit` / `periodicVariantRepetition` | value / int | Единица и кратность периодического варианта |
| `itemsTimeRepresentation` | value | Представление времени элементов (`BeginTime` / …) |
| `itemsBehaviorWhenSpaceInsufficient` / `newItemsTextType` / `fixDimensionsHeader` / `fixTimeScaleHeader` | value | Поведение элементов и заголовков |
| `autoMinColumnWidth` / `autoMinRowHeight` | bool | Авто-минимум размеров |
| `minColumnWidth` / `minRowHeight` | int | Минимальные размеры |

Шкала времени (`timeScale`):

```json
"timeScale": {
  "placement": "Left",
  "levels": [ { "measure": "Hour", "interval": 1 } ]
}
```

Ключи: `placement`, `levels` (массив уровней), `transparent`, `backColor`, `textColor`, `currentLevel`. Уровень: `measure` (`Hour` / `Day` / …), `interval`, `show`, `line` (`{ width, gap, style }`), `scaleColor`, `dayFormatRule`, `format` (ML), `labels` (`{ ticks }`), `backColor`, `textColor`, `showPereodicalLabels`.

Формы значений в `planner` те же, что у диаграммы: цвета verbatim (`auto` / `style:X` / `web:Red` / `#hex`); шрифт `{ kind: "AutoFont" }` либо ref-строка; граница `{ width, style }`; ML-форматы — строка или `{ "ru": …, "en": … }`.

> **Ограничение.** Привязка элемента расписания к элементам измерений (`item.dimensionValues`) пока всегда пустая. Сами измерения (`dimensions`) задавать можно.
