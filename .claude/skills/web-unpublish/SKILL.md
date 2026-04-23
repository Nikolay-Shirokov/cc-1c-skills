---
name: web-unpublish
description: Удаление веб-публикации 1С из Apache. Используй когда нужно убрать публикацию, удалить веб-доступ к базе — по запросу пользователя или в рамках составной задачи
argument-hint: "<appname | --all>"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /web-unpublish — Удаление веб-публикации 1С из Apache

Удаляет блок публикации из `httpd.conf` и каталог `publish/{appname}` внутри Apache. Если других публикаций не осталось — удаляет глобальный блок 1C и останавливает Apache. С флагом `--all` удаляет все публикации разом.

> **Внимание:** этот навык управляет только веб-публикациями в Apache (блоки в `httpd.conf` + каталог `publish/`). Он **НЕ** удаляет каталоги проекта, `upload/`, базы данных или исходники.

## Usage

```
/web-unpublish <appname>
/web-unpublish bpdemo
/web-unpublish --all
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Если задан `webPath` — используй как `-ApachePath`.
По умолчанию `tools/apache24` от корня проекта.

Если пользователь не указал `appname` и не указал `--all`, выполни `/web-info` чтобы показать список публикаций и спроси какую удалить.

Если пользователь просит удалить **все** публикации — используй `-All`.

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/web-unpublish/scripts/web-unpublish.ps1 <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-AppName <имя>` | * | Имя публикации |
| `-All` | * | Удалить все публикации |
| `-ApachePath <путь>` | нет | Корень Apache (по умолчанию `tools/apache24`) |

> `*` — нужен либо `-AppName`, либо `-All`

## Примеры

```powershell
# Удалить одну публикацию
powershell.exe -NoProfile -File .claude/skills/web-unpublish/scripts/web-unpublish.ps1 -AppName "bpdemo"

# Удалить все публикации
powershell.exe -NoProfile -File .claude/skills/web-unpublish/scripts/web-unpublish.ps1 -All

# С указанием пути
powershell.exe -NoProfile -File .claude/skills/web-unpublish/scripts/web-unpublish.ps1 -AppName "mydb" -ApachePath "C:\tools\apache24"
```
