---
name: epf-validate
description: Валидация внешней обработки 1С (EPF). Используй после создания или модификации обработки для проверки корректности
argument-hint: <ObjectPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /epf-validate — валидация внешней обработки (EPF)

Проверяет структурную корректность XML-исходников внешней обработки: корневую структуру, InternalInfo, свойства, ChildObjects, реквизиты, табличные части, уникальность имён, наличие файлов форм и макетов. Также работает для внешних отчётов (ERF).

## Параметры

| Параметр   | Обяз. | Умолч. | Описание                                      |
|------------|:-----:|---------|-------------------------------------------------|
| ObjectPath | да    | —       | Путь к корневому XML или каталогу обработки     |
| Detailed   | нет   | —       | Подробный вывод (все проверки, включая успешные) |
| MaxErrors  | нет   | 30      | Остановиться после N ошибок                     |
| OutFile    | нет   | —       | Записать результат в файл (UTF-8 BOM)           |

## Команда

```powershell
python ".cline/skills/epf-validate/scripts/epf-validate.py" -ObjectPath "src/МояОбработка"
python ".cline/skills/epf-validate/scripts/epf-validate.py" -ObjectPath "src/МояОбработка/МояОбработка.xml"
```

