---
name: web-publish
description: Публикация информационной базы 1С через Apache. Используй когда нужно опубликовать базу, сервисы, настроить веб-доступ, веб-клиент, открыть в браузере — по запросу пользователя или в рамках составной задачи
argument-hint: "[database]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /web-publish — Публикация 1С через Apache

Генерирует `default.vrd`, настраивает `httpd.conf` и запускает Apache HTTP Server для веб-доступа к информационной базе. При необходимости скачивает portable Apache. Идемпотентный — повторный вызов обновляет конфигурацию.

## Usage

```
/web-publish [database]
/web-publish dev
/web-publish dev --manual
/web-publish dev --port 9090
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`

**ОБЯЗАТЕЛЬНО передавай все найденные параметры:**
- **`-V8Path`** — из `v8path` в `.v8-project.json`. Если не передать, скрипт автоопределит версию платформы, что может выбрать не ту версию
- **`-UserName`** — из поля `user` найденной записи базы (если есть)
- **`-Password`** — из поля `password` найденной записи базы (если есть)
- **`-ApachePath`** — из `webPath` в `.v8-project.json` (если есть)

Если файла `.v8-project.json` нет — предложи `/db-list add`.

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/web-publish/scripts/web-publish.ps1 <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-V8Path <путь>` | нет | Каталог bin платформы (для wsap24.dll) |
| `-InfoBasePath <путь>` | * | Файловая база |
| `-InfoBaseServer <сервер>` | * | Сервер 1С (для серверной базы) |
| `-InfoBaseRef <имя>` | * | Имя базы на сервере |
| `-UserName <имя>` | нет | Имя пользователя |
| `-Password <пароль>` | нет | Пароль |
| `-AppName <имя>` | нет | Имя публикации (по умолчанию из имени каталога базы) |
| `-ApachePath <путь>` | нет | Корень Apache (по умолчанию `tools/apache24`) |
| `-Port <порт>` | нет | Порт (по умолчанию `8081`) |
| `-Manual` | нет | Не скачивать — только проверить и дать инструкцию |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

## Несколько пользователей одной базы

Повторный вызов с тем же AppName **заменяет** публикацию (идемпотентность). Это используется для:
- смены пользователя: «опубликуй под Ивановым» → тот же AppName, новый `-UserName`
- перезапуска после `/web-stop`: тот же вызов поднимает Apache обратно

Если пользователь просит **параллельную** публикацию под другим пользователем (для тестирования разных наборов прав), добавь суффикс к AppName:
- база `bpdemo`, пользователь `Иванов` → `-AppName bpdemo-ivanov`
- база `bpdemo`, пользователь `Admin` → `-AppName bpdemo-admin` (или просто `bpdemo`)

Ключевые слова: «ещё одну публикацию», «дополнительно», «параллельно», «под другим пользователем не убирая текущую».

## После выполнения

1. Сообщи URL-ы:
   - Веб-клиент: `http://localhost:{Port}/{AppName}`
   - OData: `http://localhost:{Port}/{AppName}/odata/standard.odata`
   - HTTP-сервисы: `http://localhost:{Port}/{AppName}/hs/<RootUrl>/...`
   - Web-сервисы: `http://localhost:{Port}/{AppName}/ws/<Имя>?wsdl`
2. Предложи открыть в браузере
3. Если нужно протестировать сервис — помоги составить запрос
4. Если база не зарегистрирована — предложи `/db-list add`

## Примеры

```powershell
# Файловая база
powershell.exe -NoProfile -File .claude/skills/web-publish/scripts/web-publish.ps1 -InfoBasePath "C:\Bases\MyDB" -UserName "Admin"

# С явным именем публикации и портом
powershell.exe -NoProfile -File .claude/skills/web-publish/scripts/web-publish.ps1 -InfoBasePath "C:\Bases\MyDB" -AppName "mydb" -Port 9090

# Серверная база
powershell.exe -NoProfile -File .claude/skills/web-publish/scripts/web-publish.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -UserName "Admin" -Password "secret"

# Ручной режим (только инструкция)
powershell.exe -NoProfile -File .claude/skills/web-publish/scripts/web-publish.ps1 -InfoBasePath "C:\Bases\MyDB" -Manual
```
