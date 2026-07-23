---
name: db-load-xml
description: Загрузка конфигурации 1С из XML-файлов. Используй когда нужно загрузить конфигурацию из файлов, XML, исходников, LoadConfigFromFiles
argument-hint: <configDir> [database]
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-load-xml — Загрузка конфигурации из XML

Загружает конфигурацию в информационную базу из XML-файлов (исходников). Поддерживает полную и частичную загрузку.

## Usage

```
/db-load-xml <configDir> [database]
/db-load-xml src/config dev
/db-load-xml src/config dev -Mode Partial -Files "Catalogs/Номенклатура.xml,Catalogs/Номенклатура/Ext/ObjectModule.bsl"
```

> **Внимание**: полная загрузка **заменяет всю конфигурацию** в базе. Перед выполнением запроси подтверждение у пользователя.

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Возьми `v8path` (путь к платформе) и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`
Если `v8path` не задан — скрипт сам попытается определить платформу (`.v8-project.json` → Program Files).
Если файла нет — предложи `/db-list add`.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.
Если в записи базы указан `configSrc` — используй как каталог загрузки по умолчанию.

## Команда

```powershell
python "${CLAUDE_SKILL_DIR}/scripts/db-load-xml.py" <параметры>
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
| `-ConfigDir <путь>` | да | Каталог XML-исходников |
| `-Mode <режим>` | нет | `Full` (по умолч.) / `Partial` |
| `-Files <список>` | для Partial | Относительные пути файлов через запятую |
| `-ListFile <путь>` | для Partial | Путь к файлу со списком (альтернатива `-Files`) |
| `-Extension <имя>` | нет | Загрузить в расширение |
| `-AllExtensions` | нет | Загрузить все расширения |
| `-Format <формат>` | нет | `Hierarchical` (по умолч.) / `Plain` |
| `-UpdateDB` | нет | После загрузки сразу обновить конфигурацию БД (`/UpdateDBCfg`) |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

### Режимы загрузки

| Режим | Описание |
|-------|----------|
| `Full` | Полная загрузка — замена всей конфигурации из каталога XML |
| `Partial` | Частичная — загрузка выбранных файлов (с `-partial -updateConfigDumpInfo`) |

### Формат файла списка (listFile)

Файл содержит **относительные пути к файлам** в каталоге выгрузки (один на строку), кодировка **UTF-8 с BOM**:

```
Catalogs/Номенклатура.xml
Catalogs/Номенклатура/Ext/ObjectModule.bsl
Documents/Заказ.xml
Documents/Заказ/Forms/ФормаДокумента.xml
```

## После выполнения

Если `-UpdateDB` не был указан — **предложи выполнить `/db-update`** для применения изменений к БД

## Примеры

```powershell
# Полная загрузка
python "${CLAUDE_SKILL_DIR}/scripts/db-load-xml.py" -V8Path "C:\Program Files\1cv8\8.3.25.1257\bin" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Full

# Частичная загрузка конкретных файлов
python "${CLAUDE_SKILL_DIR}/scripts/db-load-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Partial -Files "Catalogs/Номенклатура.xml,Catalogs/Номенклатура/Ext/ObjectModule.bsl"

# Загрузка расширения
python "${CLAUDE_SKILL_DIR}/scripts/db-load-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\ext_src" -Mode Full -Extension "МоёРасширение"

# Загрузка + обновление БД в одном запуске
python "${CLAUDE_SKILL_DIR}/scripts/db-load-xml.py" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Full -UpdateDB
```
