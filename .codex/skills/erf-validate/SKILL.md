---
name: erf-validate
description: Валидация внешнего отчёта 1С (ERF). Используй после создания или модификации отчёта для проверки корректности
argument-hint: <ObjectPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /erf-validate — валидация внешнего отчёта (ERF)

Проверяет структурную корректность XML-исходников внешнего отчёта: корневую структуру, InternalInfo, свойства (включая MainDataCompositionSchema), ChildObjects, реквизиты, табличные части, уникальность имён, наличие файлов форм и макетов.

Использует тот же скрипт, что и `/epf-validate` — автоопределение по типу элемента (ExternalReport).

## Параметры

| Параметр   | Обяз. | Умолч. | Описание                                      |
|------------|:-----:|---------|-------------------------------------------------|
| ObjectPath | да    | —       | Путь к корневому XML или каталогу отчёта        |
| Detailed   | нет   | —       | Подробный вывод (все проверки, включая успешные) |
| MaxErrors  | нет   | 30      | Остановиться после N ошибок                     |
| OutFile    | нет   | —       | Записать результат в файл (UTF-8 BOM)           |

## Команда

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".codex/skills/epf-validate/scripts/epf-validate.ps1" -ObjectPath "src/МойОтчёт"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".codex/skills/epf-validate/scripts/epf-validate.ps1" -ObjectPath "src/МойОтчёт/МойОтчёт.xml"
```

