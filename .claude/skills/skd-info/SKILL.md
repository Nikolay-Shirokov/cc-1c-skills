---
name: skd-info
description: Анализ структуры схемы компоновки данных 1С (СКД) — наборы, поля, параметры, варианты
argument-hint: <TemplatePath> [-Mode overview|query|fields|params|variant] [-Name <dataset|variant>]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /skd-info — Анализ схемы компоновки данных

Читает Template.xml схемы компоновки данных (СКД) и выводит компактную сводку. Заменяет необходимость читать тысячи строк XML.

## Использование

```
/skd-info <TemplatePath>
/skd-info <TemplatePath> -Mode query -Name НаборДанных1
```

## Параметры

| Параметр     | Обязательный | По умолчанию | Описание                                          |
|--------------|:------------:|--------------|---------------------------------------------------|
| TemplatePath | да           | —            | Путь к Template.xml или каталогу макета            |
| Mode         | нет          | `overview`   | Режим: `overview`, `query`, `fields`, `params`, `variant` |
| Name         | нет          | —            | Имя набора (query/fields) или варианта (variant)   |
| Batch        | нет          | `0`          | Номер пакета запроса (0 = все). Только для query   |
| Limit        | нет          | `150`        | Макс. строк вывода (защита от переполнения)        |
| Offset       | нет          | `0`          | Пропустить N строк (для пагинации)                 |
| OutFile      | нет          | —            | Записать результат в файл (UTF-8 BOM)              |

## Команда

```powershell
powershell.exe -NoProfile -File .claude\skills\skd-info\scripts\skd-info.ps1 -TemplatePath "<путь>"
```

С указанием режима:
```powershell
... -Mode query -Name НоменклатураСЦенами
... -Mode query -Name ДанныеТ13 -Batch 3
... -Mode fields
... -Mode fields -Name НаборДанных1
... -Mode params
... -Mode variant -Name Основной
... -Mode variant -Name 1
```

Для большого вывода используй `-OutFile`:
```powershell
... -Mode query -Name ДанныеТ13 -OutFile test-tmp\query.txt
```
Затем прочитай результат через Read tool.

## Режимы

### overview (по умолчанию) — карта схемы

Компактная навигационная карта (10-25 строк). Показывает структуру и подсказывает следующие шаги:

```
=== DCS: ОсновнаяСхемаКомпоновкиДанных (362 lines) ===

Sources: ИсточникДанных1 (Local)

Datasets:
  [Query]  НоменклатураСЦенами   7 fields, query 40 lines
Calculated: 1
Totals: 1
Templates: 1 templates, 1 group bindings
Params: (none)

Variants:
  [1] НоменклатураИЦены  "Номенклатура и цены"  Table(detail)  3 filters
  [2] НоменклатураБезЦен  "Номенклатура без цен"  Group(detail)  2 filters

Next:
  -Mode query             query text
  -Mode fields            field details + calculated + totals
  -Mode variant -Name <N> variant structure (1..2)
```

Для DataSetUnion — дерево наборов + связи:
```
Datasets:
  [Union] РасчетНалогаНаИмущество  52 fields
    ├─ [Query] РасчетНалогаНаИмущество   51 fields, query 181 lines
    ├─ [Query] ДанныеПоКадастровой   29 fields, query 40 lines
    ├─ [Query] ДанныеПоСреднегодовой   34 fields, query 41 lines
Links: РасчетНалогаНаИмущество -> СостояниеОС (2 fields)
```

Параметры разделяются на видимые/скрытые:
```
Params: 18 (7 visible, 11 hidden): Период, Ответственный, ...
```

### query — текст запроса

Извлекает raw-текст запроса с деэкранированием XML (`&amp;`→`&`, `&gt;`→`>`). Для пакетных запросов — оглавление батчей:

```
=== Query: ДанныеТ13 (334 lines, 10 batches) ===
  Batch 1: lines 1-8     → ПОМЕСТИТЬ Представления_Периоды
  Batch 2: lines 9-26    → ПОМЕСТИТЬ Представления_СотрудникиОрганизации
  ...
--- Batch 1 ---
ВЫБРАТЬ
  ДАТАВРЕМЯ(1, 1, 1) КАК Период
ПОМЕСТИТЬ Представления_Периоды
...
```

Фильтр по номеру батча: `-Batch 3` покажет только 3-й пакет.

### fields — таблица полей

```
=== Fields: НоменклатураСЦенами (7) ===
  dataPath                     title                  role       restrict     format
  Номенклатура                 -                      -          -            -
  Номенклатура.Артикул         "Артикул"              -          -            -
  Цена                         -                      -          -            ЧГ=0
--- calculated ---
  УИД = БухгалтерскиеОтчеты.ПолучитьУИДСсылкиСтрокой(Номенклатура)  restrict:cond,grp,ord
--- totals ---
  Цена = Максимум(Цена)
  ПравоИнтерактивное = Максимум(ПравоИнтерактивное) [group:ОбъектМетаданных]
```

### params — параметры схемы

```
=== Parameters (16) ===
  Name                       Type                   Default          Visible  Expression
  Период                     StandardPeriod         LastMonth        yes      -
  НачалоПериода              DateTime               -                hidden   &Период.ДатаНачала
  Организация                CatalogRef.Организации null             yes      -
```

### variant — структура варианта

```
=== Variant [1]: НоменклатураИЦены "Номенклатура и цены" ===

Structure:
  Table "Таблица"
  ├── Columns: [ТипЦен Items]
  │     Selection: Auto, Цена
  └── Rows: [Номенклатура Items]
        Selection: Номенклатура, УИД, Auto

Filter:
  [ ] Номенклатура InHierarchy  [user]
  [ ] ТипЦен Equal
  [x] ВАрхиве = false  "Исключая скрытые товары"

DataParams: КлючВарианта="НоменклатураИЦены"
Output: style=ЧерноБелый  groups=Separately  totalsH=None  totalsV=None
```

## Разрешение пути

- Прямой путь: `path/to/Template.xml`
- Каталог макета: `path/to/ИмяМакета/` → авто-резолв в `Ext/Template.xml`

## Что не выводится

- XML namespace-декларации
- Обёртки v8:item/v8:lang/v8:content (извлекаем чистый текст)
- userSettingID (GUID-ы пользовательских настроек)
- Дефолтные periodAdditionBegin/End = 0001-01-01
- viewMode

## Когда использовать

- **Перед анализом отчёта**: overview для понимания структуры
- **Отладка данных**: query для просмотра текста запроса
- **Модификация полей**: fields для полного списка с ролями
- **Программный вызов**: params для списка параметров
- **Изменение вывода**: variant для структуры группировок и фильтров

## Защита от переполнения

Вывод ограничен 150 строками по умолчанию. При превышении:
```
[TRUNCATED] Shown 150 of 400 lines. Use -Offset 150 to continue.
```

Используйте `-Offset N` и `-Limit N` для постраничного просмотра.
