---
name: erf-dump
description: Разобрать ERF-файл отчёта 1С в XML-исходники. Используй когда нужно разобрать, декомпилировать отчёт, получить исходники из ERF файла — по запросу пользователя или в рамках составной задачи
argument-hint: <ErfFile>
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# /erf-dump — Разборка отчёта

## Usage

```
/erf-dump <ErfFile> [OutDir]
```

| Параметр | Обязательный | По умолчанию | Описание                            |
|----------|:------------:|--------------|-------------------------------------|
| ErfFile  | да           | —            | Путь к ERF-файлу                    |
| OutDir   | нет          | `src`        | Каталог для выгрузки исходников     |

## Параметры подключения (обязательно)

Для разборки EPF/ERF требуется информационная база с конфигурацией. Без базы ссылочные типы безвозвратно теряются.

1. Прочитай `.v8-project.json` из корня проекта. Возьми `v8path` и разреши базу:
2. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
3. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
4. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
5. Если ветка не совпала — используй `default`
6. Если `.v8-project.json` нет или база не найдена — **сообщи пользователю об ошибке**. Для dump база обязательна: в пустой базе ссылочные типы (CatalogRef, DocumentRef и т.д.) безвозвратно сбрасываются в строки. Предложи указать базу или зарегистрировать через `/db-list add`.

Если `v8path` не задан — автоопределение: `Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" | Sort -Desc | Select -First 1`
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.

## Команда

Используй общий скрипт из epf-dump:

```powershell
powershell.exe -NoProfile -File .claude/skills/epf-dump/scripts/epf-dump.ps1 <параметры>
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
| `-InputFile <путь>` | да | Путь к ERF-файлу |
| `-OutputDir <путь>` | да | Каталог для выгрузки исходников |
| `-Format <формат>` | нет | `Hierarchical` (по умолч.) / `Plain` |

> `*` — обязательно хотя бы одно подключение. Без базы скрипт завершится с ошибкой (dump в пустой базе безвозвратно теряет ссылочные типы)

## Примеры

```powershell
# Разборка отчёта (файловая база)
powershell.exe -NoProfile -File .claude/skills/epf-dump/scripts/epf-dump.ps1 -InfoBasePath "C:\Bases\MyDB" -InputFile "build/МойОтчёт.erf" -OutputDir "src"

# Серверная база
powershell.exe -NoProfile -File .claude/skills/epf-dump/scripts/epf-dump.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -UserName "Admin" -Password "secret" -InputFile "build/МойОтчёт.erf" -OutputDir "src"
```
