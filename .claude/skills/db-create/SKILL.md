---
name: db-create
description: Создание информационной базы 1С. Используй когда нужно создать базу, новую ИБ, пустую базу — по запросу пользователя или в рамках составной задачи
argument-hint: <path|name>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - AskUserQuestion
---

# /db-create — Создание информационной базы

Создаёт новую информационную базу 1С (файловую или серверную) и предлагает зарегистрировать в `.v8-project.json`.

## Usage

```
/db-create <path>                   — файловая база по указанному пути
/db-create <server>/<name>          — серверная база
/db-create                          — интерактивно
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта для `v8path` (путь к платформе).
Если `v8path` не задан — автоопределение: `Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" | Sort -Desc | Select -First 1`
После создания базы предложи зарегистрировать через `/db-list add`.

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/db-create/scripts/db-create.ps1 <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-V8Path <путь>` | нет | Каталог bin платформы (или полный путь к 1cv8.exe) |
| `-InfoBasePath <путь>` | * | Путь к файловой базе |
| `-InfoBaseServer <сервер>` | * | Сервер 1С (для серверной базы) |
| `-InfoBaseRef <имя>` | * | Имя базы на сервере |
| `-UseTemplate <файл>` | нет | Создать из шаблона (.cf или .dt) |
| `-AddToList` | нет | Добавить в список баз 1С |
| `-ListName <имя>` | нет | Имя базы в списке |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

## Коды возврата

| Код | Описание |
|-----|----------|
| 0 | Успешно |
| 1 | Ошибка (см. лог) |

## После создания

1. Прочитай лог-файл и покажи результат
2. Предложи зарегистрировать базу в `.v8-project.json` (через `/db-list add`)
3. Если указан шаблон `/UseTemplate` — предупреди что конфигурация будет загружена из шаблона

## Примеры

```powershell
# Создать файловую базу
powershell.exe -NoProfile -File .claude/skills/db-create/scripts/db-create.ps1 -InfoBasePath "C:\Bases\NewDB"

# Создать серверную базу
powershell.exe -NoProfile -File .claude/skills/db-create/scripts/db-create.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Test"

# Создать из шаблона CF
powershell.exe -NoProfile -File .claude/skills/db-create/scripts/db-create.ps1 -InfoBasePath "C:\Bases\NewDB" -UseTemplate "C:\Templates\config.cf"

# Создать и добавить в список баз
powershell.exe -NoProfile -File .claude/skills/db-create/scripts/db-create.ps1 -InfoBasePath "C:\Bases\NewDB" -AddToList -ListName "Новая база"
```
