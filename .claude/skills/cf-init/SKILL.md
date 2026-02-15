---
name: cf-init
description: Создать пустую конфигурацию 1С (scaffold XML-исходников). Используй когда нужно начать новую конфигурацию с нуля
argument-hint: <Name> [-Synonym <name>] [-OutputDir src]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cf-init — Создание пустой конфигурации 1С

Создаёт scaffold исходников пустой конфигурации 1С: `Configuration.xml`, `Languages/Русский.xml`.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `Name` | Имя конфигурации (обязат.) |
| `Synonym` | Синоним (= Name если не указан) |
| `OutputDir` | Каталог для создания (default: `src`) |
| `Version` | Версия конфигурации |
| `Vendor` | Поставщик |
| `CompatibilityMode` | Режим совместимости (default: `Version8_3_24`) |

```powershell
powershell.exe -NoProfile -File .claude\skills\cf-init\scripts\cf-init.ps1 -Name "МояКонфигурация"
```

## Что создаётся

```
<OutputDir>/
├── Configuration.xml         # Корневой файл — все свойства
└── Languages/
    └── Русский.xml           # Язык по умолчанию
```

## Примеры

```powershell
# Базовая конфигурация
... -Name МояКонфигурация -Synonym "Моя конфигурация" -OutputDir test-tmp/cf

# С версией и поставщиком
... -Name TestCfg -Synonym "Тестовая" -Version "1.0.0.1" -Vendor "Фирма 1С" -OutputDir test-tmp/cf2

# Другой режим совместимости
... -Name TestCfg -CompatibilityMode Version8_3_27 -OutputDir test-tmp/cf3
```

## Верификация

```
/cf-init TestConfig -OutputDir test-tmp/cf
/cf-info test-tmp/cf          — проверить созданное
/cf-validate test-tmp/cf      — валидировать
```
