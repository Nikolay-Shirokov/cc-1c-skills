---
name: cfe-init
description: Создать расширение конфигурации 1С (CFE) — scaffold XML-исходников. Используй когда нужно создать новое расширение для исправления, доработки или дополнения конфигурации
argument-hint: <Name> [-ConfigPath <path>] [-Purpose Patch|Customization|AddOn] [-CompatibilityMode Version8_3_24]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cfe-init — Создание расширения конфигурации 1С

Создаёт scaffold расширения: `Configuration.xml`, `Languages/Русский.xml`, опционально `Roles/`.

## Подготовка

Если есть выгрузка базовой конфигурации, передай `-ConfigPath` — скрипт автоматически определит `CompatibilityMode` и UUID языка из базовой конфигурации.

Если `-ConfigPath` не задан, рекомендуется предварительно получить режим совместимости:

```
/cf-info <ConfigPath> -Mode brief
```

## Параметры

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `Name` | Имя расширения (обязат.) | — |
| `Synonym` | Синоним | = Name |
| `NamePrefix` | Префикс собственных объектов | = Name + "_" |
| `OutputDir` | Каталог для создания | `src` |
| `Purpose` | `Patch` (исправление) / `Customization` (доработка) / `AddOn` (дополнение) | `Customization` |
| `Version` | Версия расширения | — |
| `Vendor` | Поставщик | — |
| `CompatibilityMode` | Режим совместимости | `Version8_3_24` |
| `ConfigPath` | Путь к выгрузке базовой конфигурации (авто-определяет CompatibilityMode и Language UUID) | — |
| `NoRole` | Без основной роли | false |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/cfe-init/scripts/cfe-init.ps1 -Name "МоёРасширение"
```

## Что создаётся

```
<OutputDir>/
├── Configuration.xml         # Свойства расширения
├── Languages/
│   └── Русский.xml           # Язык (заимствованный)
└── Roles/                    # Если не -NoRole
    └── <Prefix>ОсновнаяРоль.xml
```

## Примеры

```powershell
# Расширение для ERP с авто-определением совместимости из базовой конфигурации
... -Name Расш1 -ConfigPath C:\WS\tasks\cfsrc\erp_8.3.24 -OutputDir src

# Расширение-исправление с явным режимом совместимости
... -Name Расш1 -Purpose Patch -CompatibilityMode Version8_3_17 -OutputDir src

# Расширение-доработка с версией
... -Name МоёРасширение -Version "1.0.0.1" -Vendor "Компания" -OutputDir src

# Без роли, с явным префиксом
... -Name ИсправлениеБага -NamePrefix "ИБ_" -Purpose Patch -NoRole -OutputDir src
```

## Верификация

```
/cfe-validate <OutputDir>
```

