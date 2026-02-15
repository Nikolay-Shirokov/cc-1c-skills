---
name: subsystem-edit
description: Точечное редактирование подсистемы 1С. Используй когда нужно добавить или удалить объекты из подсистемы, управлять дочерними подсистемами или изменить свойства
argument-hint: -SubsystemPath <path> -Operation <op> -Value <value>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /subsystem-edit — редактирование подсистемы 1С

Точечное редактирование XML подсистемы: состав, дочерние подсистемы, свойства.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `SubsystemPath` | Путь к XML-файлу подсистемы |
| `DefinitionFile` | JSON-файл с массивом операций |
| `Operation` | Одна операция (альтернатива DefinitionFile) |
| `Value` | Значение для операции |
| `NoValidate` | Пропустить авто-валидацию |

```powershell
powershell.exe -NoProfile -File '.claude\skills\subsystem-edit\scripts\subsystem-edit.ps1' -SubsystemPath '<path>' -Operation add-content -Value 'Catalog.Товары'
```

## Операции

| Операция | Значение | Описание |
|----------|----------|----------|
| `add-content` | `"Catalog.X"` или `["Catalog.X","Document.Y"]` | Добавить объекты в Content |
| `remove-content` | `"Catalog.X"` или `["Catalog.X"]` | Удалить объекты из Content |
| `add-child` | `"ИмяПодсистемы"` | Добавить дочернюю подсистему в ChildObjects |
| `remove-child` | `"ИмяПодсистемы"` | Удалить дочернюю подсистему |
| `set-property` | `{"name":"prop","value":"val"}` | Изменить свойство (Synonym, IncludeInCommandInterface, UseOneCommand, etc.) |

## Примеры

```powershell
# Добавить объект в состав
... -SubsystemPath Subsystems/Продажи.xml -Operation add-content -Value "Document.Заказ"

# Добавить несколько объектов
... -SubsystemPath Subsystems/Продажи.xml -Operation add-content -Value '["Catalog.Товары","Report.Продажи"]'

# Удалить объект из состава
... -SubsystemPath Subsystems/Продажи.xml -Operation remove-content -Value "Report.Старый"

# Добавить дочернюю подсистему
... -SubsystemPath Subsystems/Продажи.xml -Operation add-child -Value "НоваяДочерняя"

# Изменить свойство
... -SubsystemPath Subsystems/Продажи.xml -Operation set-property -Value '{"name":"IncludeInCommandInterface","value":"false"}'
```
