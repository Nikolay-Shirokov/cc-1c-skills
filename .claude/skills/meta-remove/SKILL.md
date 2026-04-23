---
name: meta-remove
description: Удалить объект метаданных из конфигурации 1С. Используй когда нужно удалить, убрать объект из конфигурации — по запросу пользователя или в рамках составной задачи
argument-hint: <ConfigDir> -Object <Type.Name>
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /meta-remove — удаление объекта метаданных

Безопасно удаляет объект из XML-выгрузки конфигурации. Перед удалением проверяет ссылки на объект в реквизитах, коде и других метаданных. Если ссылки найдены — удаление блокируется.

## Использование

```
/meta-remove <ConfigDir> -Object <Type.Name>
```

## Параметры

| Параметр   | Обязательный | Описание                                        |
|------------|:------------:|-------------------------------------------------|
| ConfigDir  | да           | Корневая директория выгрузки (где Configuration.xml) |
| Object     | да           | Тип и имя объекта: `Catalog.Товары`, `Document.Заказ` и т.д. |
| DryRun     | нет          | Только показать что будет удалено, без изменений |
| KeepFiles  | нет          | Не удалять файлы, только дерегистрировать       |
| Force      | нет          | Удалить несмотря на найденные ссылки            |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/meta-remove/scripts/meta-remove.ps1 -ConfigDir "<путь>" -Object "Catalog.Товары"
```

## Поддерживаемые типы

Catalog, Document, Enum, Constant, InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes, BusinessProcess, Task, ExchangePlan, DocumentJournal, Report, DataProcessor, CommonModule, ScheduledJob, EventSubscription, HTTPService, WebService, DefinedType, Role, Subsystem, CommonForm, CommonTemplate, CommonPicture, CommonAttribute, SessionParameter, FunctionalOption, FunctionalOptionsParameter, Sequence, FilterCriterion, SettingsStorage, XDTOPackage, WSReference, StyleItem, Language

## Примеры

```powershell
# Проверка ссылок + dry run
... -ConfigDir C:\WS\tasks\cfsrc\acc_8.3.24 -Object "Catalog.Устаревший" -DryRun

# Удалить объект без ссылок
... -ConfigDir C:\WS\tasks\cfsrc\acc_8.3.24 -Object "Catalog.Устаревший"

# Принудительно удалить несмотря на ссылки
... -ConfigDir C:\WS\tasks\cfsrc\acc_8.3.24 -Object "Catalog.Устаревший" -Force

# Только дерегистрировать (файлы оставить)
... -ConfigDir C:\WS\tasks\cfsrc\acc_8.3.24 -Object "Report.Старый" -KeepFiles

# Удалить общий модуль
... -ConfigDir src -Object "CommonModule.МойМодуль"
```

