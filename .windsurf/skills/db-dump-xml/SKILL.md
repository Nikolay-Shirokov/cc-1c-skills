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

Прочитай `.v8-project.json` из корня проекта и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`
Платформа — `v8path` найденной записи базы, иначе корневой `v8path`. Не задан ни там, ни там — `-V8Path` не передавай.
Если файла нет — предложи `/db-list add`.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.
Если в записи базы указан `configSrc` — используй как каталог выгрузки по умолчанию.
Для `-Extension` каталог берётся из `extensions[].src` записи базы, если он там указан.

## Команда

```powershell
python ".windsurf/skills/db-dump-xml/scripts/db-dump-xml.py" <параметры>
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
| `-AdditionalV8Arguments <список>` | нет | Доп. аргументы запуска `1cv8.exe` через запятую, напр. `/UseHwLicenses+` |
| `-AdditionalIbcmdArguments <список>` | нет | Доп. аргументы `ibcmd` через запятую, в форме `--ключ=значение` |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

### Режимы выгрузки

| Режим | Описание |
|-------|----------|
| `Full` | Полная выгрузка — все объекты конфигурации. Пишет поверх каталога: файлы, которых нет в конфигурации, остаются |
| `Changes` | Инкрементальная — только изменённые с последней выгрузки (по `ConfigDumpInfo.xml`). Если выгрузки в каталоге ещё нет (пусто или только `.git`, README), выгружает полностью |
| `Partial` | Частичная — выбранные объекты из параметра `-Objects` |
| `UpdateInfo` | Обновить только ConfigDumpInfo.xml без выгрузки файлов |

> Если пользователь просит выгрузить конкретные объекты — используй `-Mode Partial` с `-Objects`.

`Changes` отказывает, если в каталоге есть выгрузка без `ConfigDumpInfo.xml` или каталог выгружен
в другой версии формата (другой платформой). `-Mode Full` в таком случае перевыгрузит всё дерево,
и изменятся все файлы, поэтому решение о полной выгрузке оставь пользователю.

## Примеры

```powershell
# Полная выгрузка (файловая база)
python ".windsurf/skills/db-dump-xml/scripts/db-dump-xml.py" -V8Path "C:\Program Files\1cv8\8.3.25.1257\bin" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Full

# Инкрементальная выгрузка
python ".windsurf/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Changes

# Частичная выгрузка
python ".windsurf/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Partial -Objects "Справочник.Номенклатура,Документ.Заказ"

# Серверная база
python ".windsurf/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -ConfigDir "C:\WS\cfsrc" -Mode Full

# Выгрузка расширения
python ".windsurf/skills/db-dump-xml/scripts/db-dump-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\ext_src" -Mode Full -Extension "МоёРасширение"
```
