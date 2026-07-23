---
name: db-update
description: Обновление конфигурации базы данных 1С. Используй когда нужно обновить БД, применить конфигурацию, UpdateDBCfg
argument-hint: "[database]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-update — Обновление конфигурации БД

Применяет изменения основной конфигурации к конфигурации базы данных (`/UpdateDBCfg`). Обязательный шаг после `/db-load-cf`, `/db-load-xml`, `/db-load-git`.

## Usage

```
/db-update [database]
/db-update dev
/db-update dev -Dynamic+
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
python ".kilocode/skills/db-update/scripts/db-update.py" <параметры>
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
| `-Extension <имя>` | нет | Обновить расширение |
| `-AllExtensions` | нет | Обновить все расширения |
| `-Dynamic <+/->` | нет | `+` — динамическое обновление, `-` — отключить |
| `-Server` | нет | Обновление на стороне сервера |
| `-WarningsAsErrors` | нет | Предупреждения считать ошибками |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

### Фоновое обновление (серверная база)

| Параметр | Описание |
|----------|----------|
| `-BackgroundStart` | Начать фоновое обновление |
| `-BackgroundFinish` | Дождаться окончания |
| `-BackgroundCancel` | Отменить |
| `-BackgroundSuspend` | Приостановить |
| `-BackgroundResume` | Возобновить |

## Предупреждения

- Если обновление **не динамическое** — потребуется **монопольный доступ** к базе (все пользователи должны выйти)
- Для серверных баз рекомендуется `-Dynamic+` для обновления без остановки
- Если структура данных существенно изменилась (удаление реквизитов, изменение типов) — динамическое обновление может быть невозможно

## Примеры

```powershell
# Обычное обновление (файловая база)
python ".kilocode/skills/db-update/scripts/db-update.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin"

# Динамическое обновление (серверная база)
python ".kilocode/skills/db-update/scripts/db-update.py" -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -UserName "Admin" -Password "secret" -Dynamic "+"

# Обновление расширения
python ".kilocode/skills/db-update/scripts/db-update.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -Extension "МоёРасширение"
```
