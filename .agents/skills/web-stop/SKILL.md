---
name: web-stop
description: Остановка Apache HTTP Server. Используй когда пользователь просит остановить веб-сервер, Apache, прекратить веб-публикацию
argument-hint: ""
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /web-stop — Остановка Apache

Останавливает Apache HTTP Server. Публикации сохраняются — при следующем `/web-publish` сервер запустится снова.

## Usage

```
/web-stop
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Если задан `webPath` — используй как `-ApachePath`.
По умолчанию `tools/apache24` от корня проекта.

## Команда

```powershell
python ".agents/skills/web-stop/scripts/web-stop.py" <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-ApachePath <путь>` | нет | Корень Apache (по умолчанию `tools/apache24`) |

## После выполнения

Предложи пользователю:
- **Перезапуск** — `/web-publish <база>` (повторный вызов поднимет Apache с существующими публикациями)
- **Удаление публикаций** — `/web-unpublish <имя>` или `/web-unpublish --all`

## Примеры

```powershell
# Остановить Apache
python ".agents/skills/web-stop/scripts/web-stop.py"

# С указанием пути
python ".agents/skills/web-stop/scripts/web-stop.py" -ApachePath "C:\tools\apache24"
```
