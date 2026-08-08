---
name: mxl-validate
description: Валидация макета табличного документа (MXL). Используй после создания или модификации макета для проверки корректности
argument-hint: <TemplatePath> [-Detailed] [-MaxErrors 20]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /mxl-validate — валидация макета табличного документа (MXL)

Проверяет Template.xml на структурные ошибки: индексы, ссылки на палитры, диапазоны именованных областей и объединений.

## Параметры

| Параметр      | Обяз. | Умолч. | Описание                                 |
|---------------|:-----:|---------|--------------------------------------------|
| TemplatePath  | да    | —       | Путь к макету (директория или Template.xml) |
| Detailed      | нет   | —       | Подробный вывод (все проверки, включая успешные) |
| MaxErrors     | нет   | 20      | Остановиться после N ошибок                |

## Команда

```powershell
python ".roo/skills/mxl-validate/scripts/mxl-validate.py" -TemplatePath "Catalogs/Номенклатура/Templates/Макет"
python ".roo/skills/mxl-validate/scripts/mxl-validate.py" -TemplatePath "src/МояОбработка/Templates/ПечатнаяФорма"
```

