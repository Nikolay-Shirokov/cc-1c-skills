---
name: db-load-cf
description: Загрузка конфигурации 1С из CF-файла. Используй когда нужно загрузить конфигурацию из CF, восстановить из бэкапа CF — по запросу пользователя или в рамках составной задачи
argument-hint: <input.cf> [database]
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-load-cf — Загрузка конфигурации из CF-файла

Загружает конфигурацию из бинарного CF-файла в информационную базу.

## Usage

```
/db-load-cf <input.cf> [database]
/db-load-cf config.cf dev
```

> **Внимание**: загрузка CF **полностью заменяет** конфигурацию в базе. Перед выполнением запроси подтверждение у пользователя.

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Возьми `v8path` (путь к платформе) и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`
Если `v8path` не задан — автоопределение: `Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" | Sort -Desc | Select -First 1`
Если файла нет — предложи `/db-list add`.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/db-load-cf/scripts/db-load-cf.ps1 <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-V8Path <путь>` | нет | Каталог bin платформы (или полный путь к 1cv8.exe) |
| `-InfoBasePath <путь>` | * | Файловая база |
| `-InfoBaseServer <сервер>` | * | Сервер 1С (для серверной базы) |
| `-InfoBaseRef <имя>` | * | Имя базы на сервере |
| `-UserName <имя>` | нет | Имя пользователя |
| `-Password <пароль>` | нет | Пароль |
| `-InputFile <путь>` | да | Путь к CF-файлу |
| `-Extension <имя>` | нет | Загрузить как расширение |
| `-AllExtensions` | нет | Загрузить все расширения из архива |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

## Коды возврата

| Код | Описание |
|-----|----------|
| 0 | Успешно |
| 1 | Ошибка (см. лог) |

## После выполнения

1. Прочитай лог-файл и покажи результат
2. **Предложи выполнить `/db-update`** — загрузка CF обновляет только «основную» конфигурацию конфигуратора, для применения к БД нужен `/UpdateDBCfg`

## Примеры

```powershell
# Файловая база
powershell.exe -NoProfile -File .claude/skills/db-load-cf/scripts/db-load-cf.ps1 -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -InputFile "C:\backup\config.cf"

# Серверная база
powershell.exe -NoProfile -File .claude/skills/db-load-cf/scripts/db-load-cf.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Test" -UserName "Admin" -Password "secret" -InputFile "config.cf"

# Загрузка расширения
powershell.exe -NoProfile -File .claude/skills/db-load-cf/scripts/db-load-cf.ps1 -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -InputFile "ext.cfe" -Extension "МоёРасширение"
```
