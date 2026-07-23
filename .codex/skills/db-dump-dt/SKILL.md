---
name: db-dump-dt
description: Выгрузка информационной базы 1С в DT-файл (вся база — конфигурация + данные). Используй когда нужно выгрузить информационную базу, выгрузить архив базы, сделать бэкап, выгрузить dt
argument-hint: "[database] [output.dt]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-dump-dt — Выгрузка информационной базы в DT-файл

Выгружает информационную базу целиком (конфигурация **+ данные**) в DT-файл — полный снимок ИБ.

> В отличие от `/db-dump-cf` (только конфигурация), `.dt` содержит **всю базу**: данные,
> настройки, пользователей. Это бэкап/точка отката, а не выгрузка метаданных.

## Usage

```
/db-dump-dt [database] [output.dt]
/db-dump-dt dev backup.dt
/db-dump-dt                          — база по умолчанию, имя файла по базе и дате
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Возьми `v8path` (путь к платформе) и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`
Если `v8path` не задан — скрипт сам попытается определить платформу (`.v8-project.json` → Program Files).
Если файла нет — предложи `/db-list add`.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.

## Команда

```powershell
python ".codex/skills/db-dump-dt/scripts/db-dump-dt.py" <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-V8Path <путь>` | нет | Каталог bin платформы, или полный путь к `1cv8.exe` / `ibcmd.exe` |
| `-InfoBasePath <путь>` | * | Файловая база |
| `-InfoBaseServer <сервер>` | * | Сервер 1С (для серверной базы) |
| `-InfoBaseRef <имя>` | * | Имя базы на сервере |
| `-UserName <имя>` | нет | Имя пользователя |
| `-Password <пароль>` | нет | Пароль |
| `-OutputFile <путь>` | да | Путь к выходному DT-файлу |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

## Примеры

```powershell
# Выгрузка ИБ (файловая база)
python ".codex/skills/db-dump-dt/scripts/db-dump-dt.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -OutputFile "C:\backup\base.dt"

# Серверная база
python ".codex/skills/db-dump-dt/scripts/db-dump-dt.py" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -OutputFile "base.dt"
```

## Связанные навыки

- `/db-load-dt` — загрузка ИБ из DT (обратная операция)
- `/db-dump-cf` — выгрузка только конфигурации (без данных)
- `/db-create` — создать новую базу (в т.ч. из DT-шаблона)
