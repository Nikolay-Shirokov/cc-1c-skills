---
name: cf-edit
description: Точечное редактирование конфигурации 1С. Используй когда нужно изменить свойства конфигурации, добавить или удалить объект из состава, настроить роли по умолчанию
argument-hint: -ConfigPath <path> -Operation <op> -Value <value>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /cf-edit — редактирование конфигурации 1С

Точечное редактирование Configuration.xml: свойства, состав ChildObjects, роли по умолчанию.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `ConfigPath` | Путь к Configuration.xml или каталогу выгрузки |
| `Operation` | Операция (см. таблицу) |
| `Value` | Значение для операции (batch через `;;`) |
| `DefinitionFile` | JSON-файл с массивом операций |
| `NoValidate` | Пропустить авто-валидацию |

```powershell
powershell.exe -NoProfile -File .claude\skills\cf-edit\scripts\cf-edit.ps1 -ConfigPath '<path>' -Operation modify-property -Value 'Version=1.0.0.1'
```

## Операции

| Операция | Формат Value | Описание |
|----------|-------------|----------|
| `modify-property` | `Ключ=Значение` (batch `;;`) | Изменить свойство |
| `add-childObject` | `Type.Name` (batch `;;`) | Добавить объект в ChildObjects |
| `remove-childObject` | `Type.Name` (batch `;;`) | Удалить объект из ChildObjects |
| `add-defaultRole` | `Role.Name` или `Name` | Добавить роль по умолчанию |
| `remove-defaultRole` | `Role.Name` или `Name` | Удалить роль по умолчанию |
| `set-defaultRoles` | Имена через `;;` | Заменить список ролей по умолчанию |

Подробнее: `reference.md` в каталоге навыка.

## Примеры

```powershell
# Изменить версию и поставщика
... -ConfigPath test-tmp/cf -Operation modify-property -Value "Version=1.0.0.1 ;; Vendor=Фирма 1С"

# Добавить объекты
... -ConfigPath test-tmp/cf -Operation add-childObject -Value "Catalog.Товары ;; Document.Заказ"

# Удалить объект
... -ConfigPath test-tmp/cf -Operation remove-childObject -Value "Catalog.Устаревший"

# Роли по умолчанию
... -ConfigPath test-tmp/cf -Operation add-defaultRole -Value "ПолныеПрава"
... -ConfigPath test-tmp/cf -Operation set-defaultRoles -Value "ПолныеПрава ;; Администратор"
```
