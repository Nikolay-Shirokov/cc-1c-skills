---
name: subsystem-compile
description: Создать подсистему 1С — XML-исходники из JSON-определения. Используй когда нужно добавить подсистему (раздел) в конфигурацию — по запросу пользователя или в рамках составной задачи
argument-hint: "[-DefinitionFile <json> | -Value <json-string>] -OutputDir <ConfigDir> [-Parent <path>]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /subsystem-compile — генерация подсистемы из JSON

Принимает JSON-определение подсистемы → генерирует XML + файловую структуру + регистрирует в родителе (Configuration.xml или родительская подсистема).

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `DefinitionFile` | Путь к JSON-файлу определения |
| `Value` | Инлайн JSON-строка (альтернатива DefinitionFile) |
| `OutputDir` | Корень выгрузки (где `Subsystems/`, `Configuration.xml`) |
| `Parent` | Путь к XML родительской подсистемы (для вложенных) |
| `NoValidate` | Пропустить авто-валидацию |

```powershell
powershell.exe -NoProfile -File '.claude/skills/subsystem-compile/scripts/subsystem-compile.ps1' -Value '<json>' -OutputDir '<ConfigDir>'
```

## JSON-определение

```json
{
  "name": "МояПодсистема",
  "synonym": "Моя подсистема",
  "comment": "",
  "includeInCommandInterface": true,
  "useOneCommand": false,
  "explanation": "Описание раздела",
  "picture": "CommonPicture.МояКартинка",
  "content": ["Catalog.Товары", "Document.Заказ"]
}
```

Минимально: только `name`. Остальное — дефолты.

## Примеры

```powershell
# Минимальная подсистема
... -Value '{"name":"Тест"}' -OutputDir config/

# С составом и картинкой
... -Value '{"name":"Продажи","content":["Catalog.Товары","Report.Продажи"],"picture":"CommonPicture.Продажи"}' -OutputDir config/

# Вложенная подсистема
... -Value '{"name":"Дочерняя"}' -OutputDir config/ -Parent config/Subsystems/Продажи.xml
```

