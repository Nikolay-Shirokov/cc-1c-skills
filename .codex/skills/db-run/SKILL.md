---
name: db-run
description: Запуск 1С:Предприятие. Используй когда нужно запустить 1С, открыть базу, запустить предприятие
argument-hint: "[database]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-run — Запуск 1С:Предприятие

Запускает информационную базу в режиме 1С:Предприятие (пользовательский режим).

## Usage

```
/db-run [database]
/db-run dev
/db-run dev /Execute process.epf
/db-run dev /C "параметр запуска"
```

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
python ".codex/skills/db-run/scripts/db-run.py" <параметры>
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
| `-Execute <файл.epf>` | нет | Запуск внешней обработки сразу после старта |
| `-CParam <строка>` | нет | Параметр запуска (/C) |
| `-URL <ссылка>` | нет | Навигационная ссылка (формат `e1cib/...`) |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

## Важно

Скрипт запускает 1С в фоне (`Start-Process` без `-Wait`) — управление возвращается сразу.

## Примеры

```powershell
# Простой запуск
python ".codex/skills/db-run/scripts/db-run.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin"

# Запуск с обработкой
python ".codex/skills/db-run/scripts/db-run.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -Execute "C:\epf\МояОбработка.epf"

# Открыть по навигационной ссылке
python ".codex/skills/db-run/scripts/db-run.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -URL "e1cib/data/Справочник.Номенклатура"

# Серверная база с параметром запуска
python ".codex/skills/db-run/scripts/db-run.py" -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -UserName "Admin" -Password "secret" -CParam "ЗапуститьОбновление"
```
