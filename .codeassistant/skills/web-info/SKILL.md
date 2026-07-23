---
name: web-info
description: Статус Apache и веб-публикаций 1С — запущен ли сервер, какие базы опубликованы, ошибки. Используй когда пользователь спрашивает про статус веб-сервера, опубликованные базы, работает ли Apache
argument-hint: ""
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /web-info — Статус Apache и публикаций 1С

Показывает состояние Apache HTTP Server, список опубликованных баз и последние ошибки.

## Usage

```
/web-info
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Если задан `webPath` — используй как `-ApachePath`.
По умолчанию `tools/apache24` от корня проекта.

## Команда

```powershell
powershell.exe -NoProfile -File ".codeassistant/skills/web-info/scripts/web-info.ps1" <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-ApachePath <путь>` | нет | Корень Apache (по умолчанию `tools/apache24`) |

## Формат вывода

```
=== Apache Web Server ===
Status: Запущен (PID: 12345)
Path:   C:\...\tools\apache24
Port:   8081
Module: C:/Program Files/1cv8/8.3.24.1691/bin/wsap24.dll

=== Опубликованные базы ===
  mydb   http://localhost:8081/mydb   File="C:\Bases\MyDB";

=== Последние ошибки ===
(пусто)
```

## Примеры

```powershell
# Статус по умолчанию
powershell.exe -NoProfile -File ".codeassistant/skills/web-info/scripts/web-info.ps1"

# Указать путь к Apache
powershell.exe -NoProfile -File ".codeassistant/skills/web-info/scripts/web-info.ps1" -ApachePath "C:\tools\apache24"
```
