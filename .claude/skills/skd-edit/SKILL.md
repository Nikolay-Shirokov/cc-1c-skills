---
name: skd-edit
description: Точечное редактирование схемы компоновки данных 1С (СКД) — добавление полей, итогов, фильтров, параметров, вычисляемых полей
argument-hint: <TemplatePath> -Operation <op> -Value <value>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /skd-edit — точечное редактирование СКД (Template.xml)

Атомарные операции модификации существующей схемы компоновки данных: добавление полей, итогов, фильтров, параметров, замена запроса.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `TemplatePath` | Путь к Template.xml (или к папке — автодополнение Ext/Template.xml) |
| `Operation` | Операция: `add-field`, `add-total`, `add-calculated-field`, `add-parameter`, `add-filter`, `set-query` |
| `Value` | Значение операции (shorthand-строка или текст запроса) |
| `DataSet` | (опц.) Имя набора данных (умолч. первый) |
| `Variant` | (опц.) Имя варианта настроек (умолч. первый) |
| `NoSelection` | (опц.) Не добавлять поле в selection варианта |

```powershell
powershell.exe -NoProfile -File .claude\skills\skd-edit\scripts\skd-edit.ps1 -TemplatePath "<path>" -Operation <op> -Value "<value>"
```

## Операции

### add-field — добавить поле в набор данных

Shorthand-формат из skd-compile: `"Цена: decimal(15,2)"`, `"Организация: CatalogRef.Организации @dimension"`.

```powershell
-Operation add-field -Value "Цена: decimal(15,2)"
-Operation add-field -Value "Организация: CatalogRef.Организации @dimension"
-Operation add-field -Value "Служебное: string #noFilter #noOrder"
```

Поле добавляется перед `<dataSource>` в наборе, а также в `<dcsset:selection>` первого варианта (если нет `-NoSelection`).

### add-total — добавить итог

```powershell
-Operation add-total -Value "Цена: Среднее"
-Operation add-total -Value "Стоимость: Сумма(Кол * Цена)"
```

### add-calculated-field — добавить вычисляемое поле

```powershell
-Operation add-calculated-field -Value "Маржа = Продажа - Закупка"
```

Также добавляется в selection варианта (если нет `-NoSelection`).

### add-parameter — добавить параметр

```powershell
-Operation add-parameter -Value "Период: StandardPeriod = LastMonth @autoDates"
-Operation add-parameter -Value "Организация: CatalogRef.Организации"
```

`@autoDates` генерирует дополнительные параметры `ДатаНачала` и `ДатаОкончания`.

### add-filter — добавить фильтр в вариант настроек

```powershell
-Operation add-filter -Value "Номенклатура = _ @off @user"
-Operation add-filter -Value "Дата >= 2024-01-01T00:00:00"
-Operation add-filter -Value "Статус filled"
```

Формат: `"Поле оператор значение @флаги"`. Флаги: `@off`, `@user`, `@quickAccess`, `@normal`, `@inaccessible`.

### set-query — заменить текст запроса

```powershell
-Operation set-query -Value "ВЫБРАТЬ 1 КАК Тест"
```

## Примеры

```powershell
# Добавить числовое поле
powershell.exe -NoProfile -File .claude\skills\skd-edit\scripts\skd-edit.ps1 `
  -TemplatePath test-tmp\edit-test.xml -Operation add-field -Value "Цена: decimal(15,2)"

# Добавить итог
powershell.exe -NoProfile -File .claude\skills\skd-edit\scripts\skd-edit.ps1 `
  -TemplatePath test-tmp\edit-test.xml -Operation add-total -Value "Цена: Среднее"

# Добавить фильтр
powershell.exe -NoProfile -File .claude\skills\skd-edit\scripts\skd-edit.ps1 `
  -TemplatePath test-tmp\edit-test.xml -Operation add-filter -Value "Организация = _ @off @user"

# Заменить запрос
powershell.exe -NoProfile -File .claude\skills\skd-edit\scripts\skd-edit.ps1 `
  -TemplatePath test-tmp\edit-test.xml -Operation set-query -Value "ВЫБРАТЬ 1 КАК Тест"
```

## Верификация

```
/skd-validate <TemplatePath>    — валидация структуры после редактирования
/skd-info <TemplatePath>        — визуальная сводка
```
