# Реквизиты, измерения, ресурсы, графы

Операции над «плоскими» дочерними элементами объекта: реквизит (`attribute`), измерение (`dimension`),
ресурс (`resource`), графа журнала (`column`). Синтаксис у всех один.

## Общие правила

**Batch-режим** — несколько элементов через `;;`:
```
-Value "Комментарий: Строка(200) ;; Сумма: Число(15,2) | index"
```

**Shorthand-формат**: `ИмяРеквизита: Тип | флаги`

Флаги: `req` — обязательное заполнение; `index` — индексировать; `master` — ведущее измерение (только
измерения); `mainFilter` — основной отбор (только измерения).

**Позиционная вставка**: `>> after ИмяЭлемента` или `<< before ИмяЭлемента`:
```powershell
-Operation add-attribute -Value "Склад: CatalogRef.Склады >> after Организация"
```

## Составные типы

Разделитель `+`:
```powershell
-Operation add-attribute -Value "Значение: Строка + Число(15,2) + Дата + CatalogRef.Контрагенты"
-Operation add-attribute -Value "Значение: Строка + Число(15,2) | req"
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

## remove-*

Имя элемента (или несколько через `;;`):
```powershell
-Operation remove-attribute -Value "СтарыйРеквизит ;; ЕщёОдин"
-Operation remove-enumValue -Value "НеиспользуемоеЗначение"
```

## modify-attribute / modify-dimension / modify-resource / modify-enumValue / modify-column

Формат: `ИмяЭлемента: ключ=значение, ключ=значение`

**Спец-операции** (строчные ключи): `name` (переименование), `type` (смена типа), `synonym`.

**Свойства** задавайте по имени свойства 1С (PascalCase, как в конфигураторе): `Indexing`, `FillChecking`,
`Use`, `FullTextSearch`, `DataHistory`, `PasswordMode`, `MultiLine`, `Mask`, `CreateOnInput`, `QuickChoice` и др.
Свойство можно задать, даже если у реквизита оно ещё не выставлено.

```powershell
-Operation modify-attribute -Value "СтароеИмя: name=НовоеИмя, type=Строка(500)"
-Operation modify-attribute -Value "Комментарий: Indexing=Index, FullTextSearch=Use"
-Operation modify-enumValue -Value "СтароеЗначение: name=НовоеЗначение"
```

## Структурные свойства реквизита

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
