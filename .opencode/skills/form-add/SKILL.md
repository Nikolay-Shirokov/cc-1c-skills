---
name: form-add
description: Добавить пустую управляемую форму к объекту 1С. Используй когда нужно создать у объекта новую форму
argument-hint: <ObjectPath> <FormName> [-Purpose <Purpose>] [-Synonym <Synonym>] [-SetDefault]
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
/form-add <ObjectPath> <FormName> [-Purpose <Purpose>] [-Synonym <Synonym>] [-SetDefault]
```

| Параметр    | Обязательный | По умолчанию | Описание                                     |
|-------------|:------------:|--------------|----------------------------------------------|
| ObjectPath  | да           | —            | Путь к XML-файлу объекта (Documents/Док.xml)  |
| FormName    | да           | —            | Имя формы (ФормаДокумента)                    |
| Purpose     | нет          | основная форма вида | Назначение формы — см. таблицу ниже: у справочника это форма объекта, у регистра сведений — форма записи, у журнала — форма списка |
| Synonym     | нет          | = FormName   | Синоним формы                                 |
| -SetDefault | нет          | авто         | Сделать основной. Без флага основной становится первая форма каждого назначения |

## Команда

```powershell
powershell.exe -NoProfile -File ".opencode/skills/form-add/scripts/form-add.ps1" -ObjectPath "<ObjectPath>" -FormName "<FormName>" [-Purpose "<Purpose>"] [-Synonym "<Synonym>"] [-SetDefault]
```

## Purpose — назначение формы

| Purpose | Какая форма | Становится основной |
|---------|-------------|---------------------|
| Object | форма объекта (элемента, документа, обработки) | да |
| List | форма списка | да |
| Choice | форма выбора | да |
| Folder | форма группы | да |
| FolderChoice | форма выбора группы | да |
| Record | форма записи | да |
| RecordSet | форма набора записей | нет — в платформе нет такого свойства |
| Save | форма сохранения настроек | да |
| Load | форма загрузки настроек | да |
| Custom | произвольная форма, без привязки к объекту | нет |

### Что доступно типу объекта

| Тип объекта | Назначения |
|-------------|------------|
| Catalog, ChartOfCharacteristicTypes | Object, Folder, List, Choice, FolderChoice, Custom |
| Document, ChartOfAccounts, ChartOfCalculationTypes, ExchangePlan, BusinessProcess, Task | Object, List, Choice, Custom |
| DataProcessor, Report, ExternalDataProcessor, ExternalReport | Object, Custom |
| InformationRegister | Record, List, RecordSet, Custom |
| AccumulationRegister, AccountingRegister, CalculationRegister | List, RecordSet, Custom |
| DocumentJournal, FilterCriterion | List, Custom |
| Enum | List, Choice, Custom |
| SettingsStorage | Save, Load, Custom |

Недопустимое сочетание отклоняется со списком доступных для этого типа. У константы собственных
форм нет — для неё используется общая форма (`CommonForm`).

## Примеры

```
# Форма документа
/form-add Documents/АвансовыйОтчет.xml ФормаДокумента -Purpose Object

# Форма списка каталога
/form-add Catalogs/Контрагенты.xml ФормаСписка -Purpose List

# Форма записи регистра сведений
/form-add InformationRegisters/КурсыВалют.xml ФормаЗаписи -Purpose Record

# Форма выбора с синонимом
/form-add Catalogs/Номенклатура.xml ФормаВыбора -Purpose Choice -Synonym "Выбор номенклатуры"

# Установить как форму по умолчанию
/form-add Documents/Заказ.xml ФормаДокументаНовая -Purpose Object -SetDefault
```

## Workflow

1. `/form-add` — создать каркас формы
2. `/form-compile` или `/form-edit` — наполнить Form.xml элементами
3. `/form-validate` — проверить корректность
4. `/form-info` — проанализировать результат
