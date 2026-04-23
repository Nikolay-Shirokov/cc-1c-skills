---
name: epf-build
description: Собрать внешнюю обработку 1С (EPF/ERF) из XML-исходников. Используй когда нужно собрать, скомпилировать обработку или получить EPF/ERF файл из исходников — по запросу пользователя или в рамках составной задачи
argument-hint: <ProcessorName>
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# /epf-build — Сборка обработки

## Usage

```
/epf-build <ProcessorName> [SrcDir] [OutDir]
```

| Параметр      | Обязательный | По умолчанию | Описание                             |
|---------------|:------------:|--------------|--------------------------------------|
| ProcessorName | да           | —            | Имя обработки (имя корневого XML)    |
| SrcDir        | нет          | `src`        | Каталог исходников                   |
| OutDir        | нет          | `build`      | Каталог для результата               |

## Параметры подключения (опционально)

Предпочтительно использовать конкретную базу — это надёжнее и не требует создания временной базы.

1. Прочитай `.v8-project.json` из корня проекта. Возьми `v8path` и разреши базу:
2. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
3. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
4. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
5. Если ветка не совпала — используй `default`
6. Если `.v8-project.json` нет или база не найдена — не указывай параметры подключения: скрипт автоматически создаст временную базу. Для EPF со ссылочными типами (CatalogRef, DocumentRef и т.д.) генерируются заглушки метаданных. Временная база удаляется после сборки.

Если `v8path` не задан — автоопределение: `Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" | Sort -Desc | Select -First 1`
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/epf-build/scripts/epf-build.ps1 <параметры>
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
| `-SourceFile <путь>` | да | Путь к корневому XML-файлу исходников |
| `-OutputFile <путь>` | да | Путь к выходному EPF/ERF-файлу |

> `*` — опционально. Если не указано — автоматически создаётся временная база со заглушками метаданных

## Примеры

```powershell
# Сборка обработки (файловая база)
powershell.exe -NoProfile -File .claude/skills/epf-build/scripts/epf-build.ps1 -InfoBasePath "C:\Bases\MyDB" -SourceFile "src/МояОбработка.xml" -OutputFile "build/МояОбработка.epf"

# Серверная база
powershell.exe -NoProfile -File .claude/skills/epf-build/scripts/epf-build.ps1 -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -UserName "Admin" -Password "secret" -SourceFile "src/МояОбработка.xml" -OutputFile "build/МояОбработка.epf"
```
