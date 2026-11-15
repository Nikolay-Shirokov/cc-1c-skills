---
name: cf-info
description: Анализ структуры конфигурации 1С — свойства, состав, счётчики объектов. Используй для обзора конфигурации — какие объекты есть, сколько их, какие настройки
argument-hint: <ConfigPath> [-Mode overview|brief|full] [-Section home-page]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cf-info — Структура конфигурации 1С

Читает Configuration.xml из выгрузки конфигурации и выводит компактное описание структуры.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `ConfigPath` | Путь к Configuration.xml или каталогу выгрузки |
| `Mode` | Режим: `overview` (default), `brief`, `full` |
| `Section` | Drill-down по разделу (alias: `Name`). Сейчас: `home-page` |
| `Limit` / `Offset` | Пагинация (по умолчанию 150 строк) |
| `OutFile` | Записать результат в файл (UTF-8 BOM) |

```powershell
powershell.exe -NoProfile -File ".windsurf/skills/cf-info/scripts/cf-info.ps1" -ConfigPath "<путь>"
```

## Три режима

| Режим | Что показывает |
|---|---|
| `overview` *(default)* | Заголовок + ключевые свойства + таблица счётчиков объектов по типам |
| `brief` | Одна строка: Имя — "Синоним" vВерсия \| N объектов \| совместимость |
| `full` | Все свойства по категориям + полный список ChildObjects + DefaultRoles + мобильные функциональности |

## Примеры

```powershell
# Обзор пустой конфигурации
... -ConfigPath src

# Краткая сводка реальной конфигурации
... -ConfigPath src -Mode brief

# Полная информация
... -ConfigPath src -Mode full

# С пагинацией
... -ConfigPath src -Mode full -Limit 50 -Offset 100

# Drill-down: только начальная страница (раскладка форм с ролями)
... -ConfigPath src -Section home-page
```
