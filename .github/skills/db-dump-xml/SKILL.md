---
name: db-dump-xml
description: Выгрузка конфигурации 1С в XML-файлы. Используй когда нужно выгрузить конфигурацию в файлы, XML, исходники, DumpConfigToFiles
argument-hint: "[database] [outputDir]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-dump-xml — Выгрузка конфигурации в XML

Выгружает конфигурацию информационной базы в XML-файлы (исходники). Поддерживает полную, инкрементальную, частичную выгрузку и обновление ConfigDumpInfo.

## Usage

```
/db-dump-xml [database] [outputDir]
/db-dump-xml dev src/config
/db-dump-xml dev src/config -Mode Full
/db-dump-xml dev src/config -Mode Partial -Objects "Справочник.Номенклатура,Документ.Заказ"
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
Если в записи базы указан `configSrc` — используй как каталог выгрузки по умолчанию.

## Команда

```powershell
python ".github/skills/db-dump-xml/scripts/db-dump-xml.py" <параметры>
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
| `-ConfigDir <путь>` | да | Каталог для выгрузки |
| `-Mode <режим>` | нет | `Full` / `Changes` (по умолч.) / `Partial` / `UpdateInfo` |
| `-Objects <список>` | для Partial | Имена объектов через запятую |
| `-Extension <имя>` | нет | Выгрузить расширение |
| `-AllExtensions` | нет | Выгрузить все расширения |
| `-Format <формат>` | нет | `Hierarchical` (по умолч.) / `Plain` |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

### Режимы выгрузки

| Режим | Описание |
|-------|----------|
| `Full` | Полная выгрузка — все объекты конфигурации |
| `Changes` | Инкрементальная — только изменённые с последней выгрузки (использует ConfigDumpInfo.xml) |
| `Partial` | Частичная — выбранные объекты из параметра `-Objects` |
| `UpdateInfo` | Обновить только ConfigDumpInfo.xml без выгрузки файлов |

> Если пользователь просит выгрузить конкретные объекты — используй `-Mode Partial` с `-Objects`.

## Примеры

```powershell
# Полная выгрузка (файловая база)
python ".github/skills/db-dump-xml/scripts/db-dump-xml.py" -V8Path "C:\Program Files\1cv8\8.3.25.1257\bin" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Full

# Инкрементальная выгрузка
python ".github/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Changes

# Частичная выгрузка
python ".github/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Partial -Objects "Справочник.Номенклатура,Документ.Заказ"

# Серверная база
python ".github/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -ConfigDir "C:\WS\cfsrc" -Mode Full

# Выгрузка расширения
python ".github/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\ext_src" -Mode Full -Extension "МоёРасширение"
```
