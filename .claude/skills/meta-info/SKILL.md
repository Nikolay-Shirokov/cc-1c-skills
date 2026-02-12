---
name: meta-info
description: Структура объекта метаданных 1С из XML-выгрузки конфигурации
argument-hint: <ObjectPath> [-Mode overview|brief|full] [-Name <элемент>]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /meta-info — Структура объекта метаданных 1С

Читает XML объекта метаданных из выгрузки конфигурации 1С и выводит компактное описание структуры.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `ObjectPath` | Путь к XML-файлу объекта или каталогу (авто-резолв `<name>/<name>.xml`) |
| `Mode` | Режим: `overview` (default), `brief`, `full` |
| `Name` | Drill-down по имени элемента (реквизит, ТЧ, значение перечисления, шаблон URL, операция) |
| `Limit` / `Offset` | Пагинация (по умолчанию 150 строк) |
| `OutFile` | Записать результат в файл (UTF-8 BOM) |

```powershell
powershell.exe -NoProfile -File .claude\skills\meta-info\scripts\meta-info.ps1 -ObjectPath "<путь>"
```

## Три режима

| Режим | Что показывает |
|---|---|
| `overview` *(default)* | Заголовок + ключевые свойства + структура без раскрытия деталей |
| `brief` | Всё одной-двумя строками: имена полей, счётчики |
| `full` | Всё раскрыто: колонки ТЧ, список источников подписки, движения, формы |

`-Name` — drill-down: раскрыть конкретный элемент объекта (ТЧ, реквизит, шаблон URL, операцию веб-сервиса).

## Поддерживаемые типы (23)

**Ссылочные:** Справочник, Документ, Перечисление, Бизнес-процесс, Задача, План обмена, План счетов, ПВХ, ПВР
**Регистры:** Регистр сведений, Регистр накопления, Регистр бухгалтерии, Регистр расчёта
**Сервисные:** Отчёт, Обработка, HTTP-сервис, Веб-сервис, Общий модуль, Регламентное задание, Подписка на событие
**Прочие:** Константа, Журнал документов, Определяемый тип

## Примеры

```powershell
# Справочник — overview
... -ObjectPath Catalogs/Валюты/Валюты.xml

# Документ — полная сводка с колонками ТЧ, движениями, формами
... -ObjectPath Documents/АвансовыйОтчет/АвансовыйОтчет.xml -Mode full

# Регистр сведений — краткая сводка
... -ObjectPath InformationRegisters/КурсыВалют/КурсыВалют.xml -Mode brief

# Drill-down в ТЧ документа
... -ObjectPath Documents/АвансовыйОтчет/АвансовыйОтчет.xml -Name Товары

# Drill-down в реквизит
... -ObjectPath Catalogs/Валюты/Валюты.xml -Name ОсновнаяВалюта

# Общий модуль — флаги контекста и повторное использование
... -ObjectPath CommonModules/ОбщегоНазначения/ОбщегоНазначения.xml

# HTTP-сервис — шаблоны URL и методы
... -ObjectPath HTTPServices/ExternalAPI/ExternalAPI.xml

# HTTP-сервис — drill-down в шаблон URL
... -ObjectPath HTTPServices/ExternalAPI/ExternalAPI.xml -Name АктуальныеЗадачи

# Веб-сервис — операции с параметрами
... -ObjectPath WebServices/EnterpriseDataUpload_1_0_1_1/EnterpriseDataUpload_1_0_1_1.xml

# Веб-сервис — drill-down в операцию
... -ObjectPath WebServices/EnterpriseDataUpload_1_0_1_1/EnterpriseDataUpload_1_0_1_1.xml -Name TestConnection

# Подписка на событие — full раскрывает список источников
... -ObjectPath EventSubscriptions/ПолныйРегистрацияУдаления/ПолныйРегистрацияУдаления.xml -Mode full

# Регламентное задание
... -ObjectPath ScheduledJobs/АвтоматическоеЗакрытиеМесяца/АвтоматическоеЗакрытиеМесяца.xml

# Определяемый тип
... -ObjectPath DefinedTypes/GLN/GLN.xml
```
