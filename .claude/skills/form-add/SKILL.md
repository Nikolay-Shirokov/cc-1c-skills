---
name: form-add
description: Добавить пустую управляемую форму к объекту 1С. Используй когда нужно создать у объекта новую форму
argument-hint: <ObjectPath> <FormName> [Purpose] [--set-default] [--events ПриСозданииНаСервере,ПриОткрытии]
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /form-add — Добавление формы к объекту конфигурации

Создаёт управляемую форму (metadata XML + Form.xml + Module.bsl) и регистрирует её в корневом XML объекта конфигурации (Document, Catalog, InformationRegister и др.).

## Usage

```
/form-add <ObjectPath> <FormName> [Purpose] [Synonym] [--set-default] [--events <список>]
```

| Параметр    | Обязательный | По умолчанию | Описание                                     |
|-------------|:------------:|--------------|----------------------------------------------|
| ObjectPath  | да           | —            | Путь к XML-файлу объекта (Documents/Док.xml)  |
| FormName    | да           | —            | Имя формы (ФормаДокумента)                    |
| Purpose     | нет          | Object       | Назначение: Object, List, Choice, Record      |
| Synonym     | нет          | = FormName   | Синоним формы                                 |
| --set-default | нет        | авто         | Установить как форму по умолчанию             |
| --events    | нет          | —            | Список обработчиков событий формы через запятую (рус. имена). Прописывает `<Events>` в Form.xml И заглушки в Module.bsl |

## Команда

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/form-add.ps1" -ObjectPath "<ObjectPath>" -FormName "<FormName>" [-Purpose "<Purpose>"] [-Synonym "<Synonym>"] [-SetDefault] [-Events "ПриСозданииНаСервере,ПриОткрытии"]
```

## События формы (`-Events`)

Обработчик события формы, просто написанный в `Module.bsl`, **не вызывается** — событие должно быть привязано
в `Form.xml` через его английский идентификатор (`<Event name="OnCreateAtServer">ПриСозданииНаСервере</Event>`).
Параметр `-Events` принимает русские имена обработчиков, прописывает привязку в `Form.xml` и добавляет заглушки
процедур с правильными директивами/сигнатурами в `Module.bsl`.

Поддерживаемые: `ПриСозданииНаСервере`, `ПриОткрытии`, `ПриПовторномОткрытии`, `ПриЗакрытии`, `ПередЗакрытием`,
`ПриЧтенииНаСервере`, `ПередЗаписьюНаСервере`, `ПослеЗаписиНаСервере`, `ПередЗаписью`, `ПослеЗаписи`,
`ОбработкаВыбора`, `ОбработкаОповещения`.

## Purpose — назначение формы

| Purpose | Допустимые типы объектов | Основной реквизит | DefaultForm-свойство |
|---------|-------------------------|-------------------|---------------------|
| Object  | Document, Catalog, DataProcessor, Report, ExternalDataProcessor, ExternalReport, ChartOf*, ExchangePlan, BusinessProcess, Task | Объект (тип: *Object.Имя) | DefaultObjectForm (DefaultForm для DataProcessor/Report/ExternalDataProcessor/ExternalReport) |
| List    | Все кроме DataProcessor | Список (DynamicList) | DefaultListForm |
| Choice  | Document, Catalog, ChartOf*, ExchangePlan, BusinessProcess, Task | Список (DynamicList) | DefaultChoiceForm |
| Record  | InformationRegister | Запись (InformationRegisterRecordManager) | DefaultRecordForm |

## Примеры

```
# Форма документа
/form-add Documents/АвансовыйОтчет.xml ФормаДокумента --purpose Object

# Форма списка каталога
/form-add Catalogs/Контрагенты.xml ФормаСписка --purpose List

# Форма записи регистра сведений
/form-add InformationRegisters/КурсыВалют.xml ФормаЗаписи --purpose Record

# Форма выбора с синонимом
/form-add Catalogs/Номенклатура.xml ФормаВыбора --purpose Choice --synonym "Выбор номенклатуры"

# Установить как форму по умолчанию
/form-add Documents/Заказ.xml ФормаДокументаНовая --purpose Object --set-default

# Форма обработки с обработчиками событий (привязка в Form.xml + заглушки в модуле)
/form-add DataProcessors/МояОбработка.xml Форма --purpose Object --events ПриСозданииНаСервере,ПриОткрытии
```

## Workflow

1. `/form-add` — создать каркас формы
2. `/form-compile` или `/form-edit` — наполнить Form.xml элементами
3. `/form-validate` — проверить корректность
4. `/form-info` — проанализировать результат
