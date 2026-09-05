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

## Параметры

| Параметр     | Обяз. | Умолч. | Описание                                              |
|--------------|:-----:|---------|---------------------------------------------------------|
| TemplatePath | да    | —       | Путь к Template.xml или каталогу макета                 |
| Detailed     | нет   | —       | Подробный вывод (все проверки, включая успешные)         |
| MaxErrors    | нет   | 20      | Остановиться после N ошибок                             |
| OutFile      | нет   | —       | Записать результат в файл                               |

## Команда

```powershell
python ".augment/skills/skd-validate/scripts/skd-validate.py" -TemplatePath "src/МойОтчёт/Templates/ОсновнаяСхема"
python ".augment/skills/skd-validate/scripts/skd-validate.py" -TemplatePath "Catalogs/Номенклатура/Templates/СКД/Ext/Template.xml"
```
