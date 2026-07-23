# Inline-операции над дочерними элементами

Подробный справочник операций `add-*` / `remove-*` / `modify-*` для дочерних элементов объекта метаданных.

## Общие правила

**Batch-режим** — несколько элементов через `;;`:
```
-Value "Комментарий: Строка(200) ;; Сумма: Число(15,2) | index"
```

**Shorthand-формат** реквизитов: `ИмяРеквизита: Тип | флаги`

Флаги: `req` — обязательное заполнение; `index` — индексировать; `master` — ведущее измерение (только dimensions); `mainFilter` — основной отбор (только dimensions).

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

## add-predefined

Добавить предопределённые элементы (Catalog, ChartOfCharacteristicTypes). Существующие элементы и их
идентификаторы сохраняются, новые получают свежий id.

Inline — строка `(Код) Имя [Наименование]` (batch через `;;`; `[Наименование]` необязательно — иначе авто из имени):
```powershell
-Operation add-predefined -Value "(001) Основной ;; (002) Резервный [Резервный склад]"
```

JSON — строки и/или объекты (для групп с вложенными):
```json
{ "add": { "predefined": [
  "(001) Основной",
  { "name": "Группа", "isFolder": true, "childItems": ["(002) Вложенный"] }
] } }
```

Ключи объекта: `name`, `code`, `description`, `isFolder`, `childItems` (дерево). Тип кода (строковый/числовой)
берётся из объекта автоматически.

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

**Спец-операции** (строчные ключи): `name` (переименование), `type` (смена типа), `synonym`.

**Свойства** задавайте по имени свойства 1С (PascalCase, как в конфигураторе): `Indexing`, `FillChecking`,
`Use`, `FullTextSearch`, `DataHistory`, `PasswordMode`, `MultiLine`, `Mask`, `CreateOnInput`, `QuickChoice` и др.
Свойство можно задать, даже если у реквизита оно ещё не выставлено. Опечатка в имени свойства → ошибка
(правка не теряется молча).

```powershell
-Operation modify-attribute -Value "СтароеИмя: name=НовоеИмя, type=Строка(500)"
-Operation modify-attribute -Value "Комментарий: Indexing=Index, FullTextSearch=Use"
-Operation modify-enumValue -Value "СтароеЗначение: name=НовоеЗначение"
```

### Структурные свойства реквизита

Свойства со сложным значением задавайте через JSON DSL (`{ "modify": { "attributes": { "Имя": { ... } } } }`):

| Ключ | Значение | Пример (JSON) |
|------|----------|---------------|
| `Format` / `EditFormat` / `ToolTip` | строка (мультиязычная) | `"Format": "ДФ=dd.MM.yyyy"` |
| `ChoiceForm` | путь формы выбора | `"ChoiceForm": "Catalog.Товары.Form.ФормаВыбора"` |
| `MinValue` / `MaxValue` | число или строка | `"MinValue": 0, "MaxValue": 100` |
| `FillValue` | значение заполнения | `"FillValue": "EmptyRef"` · `true` · `10` · `{"nil": true}` |
| `LinkByType` | `{dataPath, linkItem?}` | `"LinkByType": {"dataPath": "Вид", "linkItem": 0}` |
| `ChoiceParameterLinks` | `[{name, dataPath, valueChange?}]` | `["Отбор.Организация=Организация"]` |
| `ChoiceParameters` | `[{name, type?, value?}]` | `[{"name": "Отбор.ЭтоГруппа", "value": false}]` |

- `FillValue`: `"EmptyRef"` — пустая ссылка по типу реквизита; `{"emptyRef": true}` / `{"nil": true}` — явные маркеры.
- `ChoiceParameters` value — булево/число/строка/ссылочный путь или массив; укажите `type` (напр.
  `EnumRef.СтавкиНДС`), чтобы задавать значения короткими именами (`"Оптовая"` вместо полного пути).
- В путях данных (`LinkByType`/`ChoiceParameterLinks`) можно писать короткое имя реквизита вместо полного пути.
