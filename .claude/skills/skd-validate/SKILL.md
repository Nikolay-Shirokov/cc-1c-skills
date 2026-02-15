---
name: skd-validate
description: Валидация схемы компоновки данных 1С (СКД). Используй после создания или модификации СКД для проверки корректности
argument-hint: <TemplatePath> [-MaxErrors 20]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /skd-validate — валидация СКД (DataCompositionSchema)

Проверяет структурную корректность Template.xml схемы компоновки данных. Выявляет ошибки формата, битые ссылки, дубликаты имён.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `TemplatePath` | Путь к Template.xml или каталогу макета (авто-резолв в `Ext/Template.xml`) |
| `MaxErrors` | Макс. ошибок до остановки (по умолчанию 20) |
| `OutFile` | Записать результат в файл |

```powershell
powershell.exe -NoProfile -File .claude\skills\skd-validate\scripts\skd-validate.ps1 -TemplatePath "<путь>"
```

## Проверки (~30)

| Группа | Что проверяется |
|--------|-----------------|
| **Root** | XML parse, корневой элемент `DataCompositionSchema`, default namespace, ns-префиксы |
| **DataSource** | Наличие, name не пуст, type валиден (Local/External), уникальность имён |
| **DataSet** | Наличие, xsi:type валиден, name не пуст, уникальность, ссылка на dataSource, query не пуст |
| **Fields** | dataPath не пуст, field не пуст, уникальность dataPath в наборе |
| **Links** | source/dest ссылаются на существующие наборы, expressions не пусты |
| **CalcFields** | dataPath не пуст, expression не пуст, уникальность, коллизии с полями наборов |
| **TotalFields** | dataPath не пуст, expression не пуст |
| **Parameters** | name не пуст, уникальность |
| **Templates** | name не пуст, уникальность |
| **GroupTemplates** | template ссылается на существующий template, templateType валиден |
| **Variants** | Наличие, name не пуст, settings element присутствует |
| **Settings** | selection/filter/order ссылаются на известные поля, comparisonType валиден, structure items типизированы |

## Коды выхода

| Код | Значение |
|-----|----------|
| 0 | Ошибок нет (могут быть предупреждения) |
| 1 | Есть ошибки |

## Пример вывода

```
=== Validation: Template.xml ===

[OK]    XML parsed successfully
[OK]    Root element: DataCompositionSchema
[OK]    Default namespace correct
[OK]    1 dataSource(s) found, names unique
[OK]    1 dataSet(s) found, names unique
[OK]    DataSet "НаборДанных1": 2 fields, dataPath unique
[OK]    1 totalField(s): dataPath and expression present
[OK]    1 settingsVariant(s) found

=== Result: 0 errors, 0 warnings ===
```

## Верификация

```
/skd-compile <JsonPath> <OutputPath>    — генерация XML
/skd-validate <OutputPath>              — проверка результата
/skd-info <OutputPath>                  — визуальная сводка
```
