# Inline-операции над дочерними элементами

Подробный справочник операций `add-*` / `remove-*` / `modify-*` для дочерних элементов объекта метаданных.

## Общие правила

**Batch-режим** — несколько элементов через `;;`:
```
-Value "Комментарий: Строка(200) ;; Сумма: Число(15,2) | index"
```

**Shorthand-формат** реквизитов: `ИмяРеквизита: Тип | флаги`

Флаги: `req` (FillChecking=ShowError), `index` (Indexing=Index), `master` (Master=true, только dimensions), `mainFilter` (MainFilterOperand, только dimensions).

**Позиционная вставка**: `>> after ИмяЭлемента` или `<< before ИмяЭлемента`:
```powershell
-Operation add-attribute -Value "Склад: CatalogRef.Склады >> after Организация"
```

## Составные типы

Для реквизитов с несколькими допустимыми типами — разделитель `+`:
```powershell
-Operation add-attribute -Value "Значение: Строка + Число(15,2) + Дата + CatalogRef.Контрагенты"
-Operation add-attribute -Value "Значение: Строка + Число(15,2) | req"
-Operation modify-ts-attribute -Value "Данные.Значение: type=Строка + Число(15,2) + Дата"
```

В JSON DSL — массив в `type`:
```json
{ "name": "Значение", "type": ["Строка", "Число(15,2)", "Дата", "CatalogRef.Контрагенты"] }
```

## add-attribute / add-dimension / add-resource / add-column

```powershell
-Operation add-attribute -Value "Комментарий: Строка(200)"
-Operation add-attribute -Value "Сумма: Число(15,2) | req, index"
-Operation add-attribute -Value "Ном: CatalogRef.Номенклатура | req ;; Кол: Число(15,3)"
-Operation add-dimension -Value "Организация: CatalogRef.Организации | master, mainFilter"
-Operation add-resource -Value "Сумма: Число(15,2)"
-Operation add-column -Value "Тип: EnumRef.ТипыДокументов"
```

## add-ts

Формат: `ИмяТЧ: Реквизит1: Тип1, Реквизит2: Тип2, ...`

```powershell
-Operation add-ts -Value "Товары: Ном: CatalogRef.Ном | req, Кол: Число(15,3), Цена: Число(15,2), Сумма: Число(15,2)"
```

## add-ts-attribute / remove-ts-attribute / modify-ts-attribute

Операции над реквизитами **внутри существующей ТЧ**. Формат: `ИмяТЧ.ОпределениеРеквизита` (dot-нотация).

```powershell
# Добавить реквизит в ТЧ
-Operation add-ts-attribute -Value "Товары.СтавкаНДС: EnumRef.СтавкиНДС"
-Operation add-ts-attribute -Value "Товары.Скидка: Число(15,2) ;; Товары.Бонус: Число(15,2)"

# Позиционная вставка в ТЧ
-Operation add-ts-attribute -Value "Товары.Скидка: Число(15,2) >> after Цена"

# Удалить реквизит из ТЧ
-Operation remove-ts-attribute -Value "Товары.УстаревшийРекв"
-Operation remove-ts-attribute -Value "Товары.Рекв1 ;; Товары.Рекв2"

# Изменить реквизит в ТЧ (rename, type change и т.д.)
-Operation modify-ts-attribute -Value "Товары.СтароеИмя: name=НовоеИмя, type=Строка(500)"
```

Batch через `;;` — можно указать разные ТЧ: `"Товары.А: Строка(50) ;; Услуги.Б: Число(10)"`.

## modify-ts

Изменение свойств **самой табличной части** (Synonym, FillChecking, Use и др.):

```powershell
-Operation modify-ts -Value "Товары: synonym=Товарный состав"
-Operation modify-ts -Value "Товары: fillChecking=ShowError"
```

Формат аналогичен `modify-attribute`: `ИмяТЧ: ключ=значение, ключ=значение`.

## add-enumValue / add-form / add-template / add-command

Просто имена (batch через `;;`):
```powershell
-Operation add-enumValue -Value "Значение1 ;; Значение2 ;; Значение3"
-Operation add-form -Value "ФормаЭлемента ;; ФормаСписка"
-Operation add-template -Value "ПечатнаяФорма"
-Operation add-command -Value "Команда1"
```

## remove-*

Имя элемента (или несколько через `;;`):
```powershell
-Operation remove-attribute -Value "СтарыйРеквизит ;; ЕщёОдин"
-Operation remove-ts -Value "УстаревшаяТЧ"
-Operation remove-enumValue -Value "НеиспользуемоеЗначение"
```

## modify-attribute / modify-dimension / modify-resource / modify-enumValue / modify-column

Формат: `ИмяЭлемента: ключ=значение, ключ=значение`

Ключи: `name` (rename), `type`, `synonym`, `indexing`, `fillChecking`, `use` и др.

```powershell
-Operation modify-attribute -Value "СтароеИмя: name=НовоеИмя, type=Строка(500)"
-Operation modify-attribute -Value "Комментарий: indexing=Index"
-Operation modify-enumValue -Value "СтароеЗначение: name=НовоеЗначение"
```
