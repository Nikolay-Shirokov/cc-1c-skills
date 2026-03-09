---
name: skd-validate
description: Валидация схемы компоновки данных 1С (СКД). Используй после создания или модификации СКД для проверки корректности
argument-hint: <TemplatePath> [-Detailed] [-MaxErrors 20]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /skd-validate — валидация СКД (DataCompositionSchema)

Проверяет структурную корректность Template.xml схемы компоновки данных. Выявляет ошибки формата, битые ссылки, дубликаты имён.

## Использование

```
/skd-validate src/МойОтчёт/Templates/ОсновнаяСхема
/skd-validate Catalogs/Номенклатура/Templates/СКД/Ext/Template.xml
```

## Параметры

| Параметр     | Обяз. | Умолч. | Описание                                              |
|--------------|:-----:|---------|---------------------------------------------------------|
| TemplatePath | да    | —       | Путь к Template.xml или каталогу макета                 |
| Detailed     | нет   | —       | Показывать [OK] для каждой проверки                     |
| MaxErrors    | нет   | 20      | Остановиться после N ошибок                             |
| OutFile      | нет   | —       | Записать результат в файл                               |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/skd-validate/scripts/skd-validate.ps1 -TemplatePath "src/МойОтчёт/Templates/ОсновнаяСхема"
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

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
