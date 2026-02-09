---
name: form-add
description: Добавить управляемую форму к объекту конфигурации 1С
argument-hint: <ObjectPath> <FormName> [Purpose] [--set-default]
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
/form-add <ObjectPath> <FormName> [Purpose] [Synonym] [--set-default]
```

| Параметр    | Обязательный | По умолчанию | Описание                                     |
|-------------|:------------:|--------------|----------------------------------------------|
| ObjectPath  | да           | —            | Путь к XML-файлу объекта (Documents/Док.xml)  |
| FormName    | да           | —            | Имя формы (ФормаДокумента)                    |
| Purpose     | нет          | Object       | Назначение: Object, List, Choice, Record      |
| Synonym     | нет          | = FormName   | Синоним формы                                 |
| --set-default | нет        | авто         | Установить как форму по умолчанию             |

## Команда

```powershell
powershell.exe -NoProfile -File .claude\skills\form-add\scripts\form-add.ps1 -ObjectPath "<ObjectPath>" -FormName "<FormName>" [-Purpose "<Purpose>"] [-Synonym "<Synonym>"] [-SetDefault]
```

## Purpose — назначение формы

| Purpose | Допустимые типы объектов | Основной реквизит | DefaultForm-свойство |
|---------|-------------------------|-------------------|---------------------|
| Object  | Document, Catalog, DataProcessor, Report, ChartOf*, ExchangePlan, BusinessProcess, Task | Объект (тип: *Object.Имя) | DefaultObjectForm (DefaultForm для DataProcessor/Report) |
| List    | Все кроме DataProcessor | Список (DynamicList) | DefaultListForm |
| Choice  | Document, Catalog, ChartOf*, ExchangePlan, BusinessProcess, Task | Список (DynamicList) | DefaultChoiceForm |
| Record  | InformationRegister | Запись (InformationRegisterRecordManager) | DefaultRecordForm |

## Что создаётся

```
<ObjectDir>/Forms/
├── <FormName>.xml                    # Метаданные формы (UUID)
└── <FormName>/
    └── Ext/
        ├── Form.xml                  # Описание формы (logform namespace)
        └── Form/
            └── Module.bsl           # BSL-модуль с 5 регионами + ПриСозданииНаСервере
```

## Что модифицируется

- `<ObjectPath>` — добавляется `<Form>` в `ChildObjects` (перед `<Template>` или `<TabularSection>`), обновляется Default*Form (автоматически если пустое, или явно при `--set-default`)

## Поддерживаемые типы объектов

Document, Catalog, DataProcessor, Report, InformationRegister, ChartOfAccounts, ChartOfCharacteristicTypes, ExchangePlan, BusinessProcess, Task

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
```

## Workflow

1. `/form-add` — создать каркас формы
2. `/form-compile` или `/form-edit` — наполнить Form.xml элементами
3. `/form-validate` — проверить корректность
4. `/form-info` — проанализировать результат
