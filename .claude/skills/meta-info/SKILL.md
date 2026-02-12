---
name: meta-info
description: Компактная сводка объекта метаданных конфигурации 1С — реквизиты, ТЧ, типы, движения
argument-hint: <ObjectPath> [-Mode overview|brief|full] [-Name <реквизит|ТЧ>]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /meta-info — Сводка объекта метаданных 1С

Читает XML-файл объекта метаданных конфигурации 1С и выводит компактную сводку: реквизиты с типами, табличные части, движения, формы. Заменяет необходимость читать тысячи строк XML.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `ObjectPath` | Путь к XML-файлу объекта или каталогу (авто-резолв `<name>/<name>.xml`) |
| `Mode` | Режим: `overview` (default), `brief`, `full` |
| `Name` | Drill-down: раскрыть ТЧ или деталь реквизита |
| `Limit` / `Offset` | Пагинация (по умолчанию 150 строк) |
| `OutFile` | Записать результат в файл (UTF-8 BOM) |

```powershell
powershell.exe -NoProfile -File .claude\skills\meta-info\scripts\meta-info.ps1 -ObjectPath "<путь>"
```

## Три режима

| Режим | Что показывает |
|---|---|
| `overview` *(default)* | Заголовок + ключевые свойства + все поля с типами + имена ТЧ (без раскрытия) |
| `brief` | Только имена полей и ТЧ одной строкой |
| `full` | Всё: поля + колонки всех ТЧ + движения + формы + макеты + команды |

`-Name` — drill-down: раскрыть ТЧ (показать колонки) или деталь реквизита.

## Поддерживаемые типы объектов

Справочник, Документ, Перечисление, Регистр сведений, Регистр накопления, Регистр бухгалтерии, План счетов, План видов характеристик, Бизнес-процесс, Задача, План обмена, Отчёт, Обработка, Константа, Журнал документов, Определяемый тип, Общий модуль, Регламентное задание, Подписка на событие, HTTP-сервис, Веб-сервис.

## Примеры

```powershell
# Перечисление
... -ObjectPath upload\erp\Enums\ABCКлассификация.xml

# Справочник brief
... -ObjectPath upload\acc\Catalogs\Валюты.xml -Mode brief

# Документ full
... -ObjectPath upload\acc\Documents\АвансовыйОтчет.xml -Mode full

# Drill-down в ТЧ
... -ObjectPath upload\acc\Catalogs\Валюты.xml -Name Представления

# Drill-down в реквизит
... -ObjectPath upload\acc\Catalogs\Валюты.xml -Name ОсновнаяВалюта

# Определяемый тип
... -ObjectPath upload\acc\DefinedTypes\GLN.xml

# Общий модуль
... -ObjectPath upload\acc\CommonModules\GoogleПереводчик.xml

# Регламентное задание
... -ObjectPath upload\acc\ScheduledJobs\АвтоматическоеЗакрытиеМесяца.xml

# HTTP-сервис
... -ObjectPath upload\acc\HTTPServices\ExternalAPI.xml

# Веб-сервис — drill-down в операцию
... -ObjectPath upload\acc\WebServices\EnterpriseDataUpload_1_0_1_1.xml -Name TestConnection
```

## Верификация

```
/meta-info <path>                           — overview (точка входа)
/meta-info <path> -Mode brief               — краткая сводка
/meta-info <path> -Mode full                — полная сводка
/meta-info <path> -Name <имя>               — drill-down
```
