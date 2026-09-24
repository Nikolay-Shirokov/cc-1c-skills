---
name: meta-validate
description: Валидация объекта метаданных 1С. Используй после создания или модификации объекта конфигурации для проверки корректности
argument-hint: <ObjectPath> [-Detailed] [-MaxErrors 30] — pipe-separated paths for batch
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /meta-validate — валидация объекта метаданных 1С

Проверяет XML объекта метаданных из выгрузки конфигурации на структурные ошибки. Понимает и вложенные дескрипторы `Forms/<Имя>.xml`, `Templates/<Имя>.xml`; у любого файла сверяет версию формата с версией выгрузки (`Configuration.xml` или корень автономной EPF/ERF).

## Параметры

| Параметр   | Обяз. | Умолч. | Описание                                      |
|------------|:-----:|---------|-------------------------------------------------|
| ObjectPath | да    | —       | Путь к XML-файлу или каталогу. Через `\|` для batch |
| Detailed   | нет   | —       | Подробный вывод (все проверки, включая успешные) |
| MaxErrors  | нет   | 30      | Остановиться после N ошибок (per object)        |
| OutFile    | нет   | —       | Записать результат в файл (UTF-8 BOM)           |

## Команда

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/meta-validate.ps1" -ObjectPath "Catalogs/Номенклатура/Номенклатура.xml"
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/meta-validate.ps1" -ObjectPath "Catalogs/Банки|Documents/Заказ"
```
