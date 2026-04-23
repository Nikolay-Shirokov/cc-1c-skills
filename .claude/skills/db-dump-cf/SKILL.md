---
name: db-dump-cf
description: Выгрузка конфигурации 1С в CF-файл. Используй когда нужно выгрузить конфигурацию в CF, сохранить конфигурацию, сделать бэкап CF — по запросу пользователя или в рамках составной задачи
argument-hint: "[database] [output.cf]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-dump-cf — Выгрузка конфигурации в CF-файл

Выгружает конфигурацию информационной базы в бинарный CF-файл.

## Usage

```
/db-dump-cf [database] [output.cf]
/db-dump-cf dev config.cf
/db-dump-cf                          — база по умолчанию, файл config.cf
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
powershell.exe -NoProfile -File .claude/skills/db-dump-cf/scripts/db-dump-cf.ps1 <параметры>
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
| `-OutputFile <путь>` | да | Путь к выходному CF-файлу |
| `-Extension <имя>` | нет | Выгрузить расширение |
| `-AllExtensions` | нет | Выгрузить все расширения |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

## Коды возврата

| Код | Описание |
|-----|----------|
| 0 | Успешно |
| 1 | Ошибка (см. лог) |

## После выполнения

Прочитай лог-файл и покажи результат. Если есть ошибки — покажи содержимое лога.

## Примеры

```powershell
# Выгрузка конфигурации (файловая база)
powershell.exe -NoProfile -File .claude/skills/db-dump-cf/scripts/db-dump-cf.ps1 -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -OutputFile "C:\backup\config.cf"

# Серверная база
powershell.exe -NoProfile -File .claude/skills/db-dump-cf/scripts/db-dump-cf.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -OutputFile "config.cf"

# Выгрузка расширения
powershell.exe -NoProfile -File .claude/skills/db-dump-cf/scripts/db-dump-cf.ps1 -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -OutputFile "ext.cfe" -Extension "МоёРасширение"
```
