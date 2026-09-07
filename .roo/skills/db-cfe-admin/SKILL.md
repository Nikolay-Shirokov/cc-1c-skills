---
name: db-cfe-admin
description: Управление расширениями конфигурации в информационной базе 1С. Используй когда нужно узнать какие расширения подключены к базе, выполнить проверку применимости или синтаксическую проверку, изменить безопасный режим или активность, удалить расширение из базы
argument-hint: <list|check|set-properties|delete> [database] [-Name <Имя>]
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-cfe-admin — Управление расширениями конфигурации

Расширения **на стороне базы**: состав и свойства подключения, проверки, удаление.
Про исходники расширения — другие навыки, см. «Смежное».

## Usage

```
/db-cfe-admin list           [database]
/db-cfe-admin check          [database] [-Name Расш1]
/db-cfe-admin set-properties [database] -Name Расш1 -SafeMode off
/db-cfe-admin delete         [database] -Name Расш1
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Возьми `v8path` (путь к платформе) и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`

Если `v8path` не задан — скрипт сам попытается определить платформу.

## Команда

```powershell
python ".roo/skills/db-cfe-admin/scripts/db-cfe-admin.py" -Command <команда> <параметры>
```

### Общие параметры

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-Command <команда>` | да | `list` / `check` / `set-properties` / `delete` |
| `-V8Path <путь>` | нет | Каталог bin платформы или полный путь к `1cv8.exe` / `ibcmd.exe` |
| `-InfoBasePath <путь>` | * | Файловая база |
| `-InfoBaseServer <сервер>` | * | Сервер 1С (для серверной базы) |
| `-InfoBaseRef <имя>` | * | Имя базы на сервере |
| `-UserName <имя>` | нет | Пользователь базы |
| `-Password <пароль>` | нет | Пароль пользователя |
| `-Name <имя>` | усл. | Расширение. Обязателен для `set-properties`; в `delete` — вместо `-All`. Без него `list` и `check` работают по всем расширениям |
| `-All` | усл. | Только для `delete`: удалить все расширения. Вместо `-Name`, а не вместе с ним |
| `-AdditionalV8Arguments <список>` | нет | Доп. аргументы `1cv8.exe` через запятую |
| `-AdditionalIbcmdArguments <список>` | нет | Доп. аргументы `ibcmd` через запятую, в форме `--ключ=значение` |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

### Параметры `check`

| Параметр | Описание |
|----------|----------|
| `-Checks <список>` | `apply` — применимость расширения, `modules` — синтаксическая проверка, `config` — проверки конфигурации (целостность, ссылки, неиспользуемые процедуры и обработчики). Через запятую, по умолчанию `apply,modules` |
| `-Context <список>` | Контексты синтаксической проверки: `ThinClient`, `WebClient`, `Server`, `ExternalConnection`, `ThickClientManagedApplication`, `ThickClientOrdinaryApplication`, `MobileClient` и др. Через запятую, по умолчанию `ThinClient,Server` |

Применимость и синтаксис проверяют разное и друг друга не заменяют. Проверяется только
расширение: ошибки самой конфигурации сюда не попадают.

### Свойства `set-properties`

| Параметр | Описание |
|----------|----------|
| `-SafeMode <on/off>` | Безопасный режим |
| `-Active <on/off>` | Активность расширения |
| `-UnsafeActionProtection <on/off>` | Защита от опасных действий |
| `-UsedInDistributedInfobase <on/off>` | Использование в распределённой ИБ |
| `-Scope <область>` | `infobase` / `data-separation` |
| `-SecurityProfile <имя>` | Профиль безопасности |

Передавай только то, что меняешь: не указанное свойство остаётся как было. Расширение, впервые
попавшее в базу загрузкой, создаётся с включённым безопасным режимом, а в нём расширение модуля не
применяется.

Свойствами управляет `ibcmd` — он есть не в каждой установке платформы и работает с файловой базой;
остальные команды работают всегда.

## Смежное

| Задача | Навык |
|--------|-------|
| Создать расширение, заимствовать объекты, перехватить метод | `/cfe-init`, `/cfe-borrow`, `/cfe-patch-method`, `/cfe-validate` |
| Загрузить исходники расширения в базу | `/db-load-xml -Extension` (из коммита Git — `/db-load-git`) |
| Загрузить готовый `.cfe` | `/db-load-cf -Extension` |
| Выгрузить расширение из базы | `/db-dump-xml -Extension`, `/db-dump-cf -Extension` |
| Обновить конфигурацию базы после загрузки | `/db-update -Extension` |
| Проверить дрейф контролируемых методов по исходникам | `/cfe-patch-method -Check` |

## Примеры

```powershell
# Что подключено к базе
... -Command list -InfoBasePath "C:\Bases\MyDB"

# Проверить расширение
... -Command check -InfoBasePath "C:\Bases\MyDB" -Name "Расш1"

# Синтаксическая проверка в контексте веб-клиента
... -Command check -InfoBasePath "C:\Bases\MyDB" -Checks modules -Context WebClient,Server

# Снять безопасный режим
... -Command set-properties -InfoBasePath "C:\Bases\MyDB" -Name "Расш1" -SafeMode off

# Отключить, не удаляя
... -Command set-properties -InfoBasePath "C:\Bases\MyDB" -Name "Расш1" -Active off

# Убрать расширение из базы
... -Command delete -InfoBasePath "C:\Bases\MyDB" -Name "Расш1"
```
