# Объектная форма реквизита и табличной части

Когда реквизиту (в `attributes` / `dimensions` / `resources` / колонках ТЧ) нужны свойства сверх
shorthand — вместо строки задаётся объект:

```json
{ "name": "Цена", "type": "Number(15,2)", "tooltip": "Цена за единицу", "fillValue": 0 }
```

`name` и `type` обязательны (тип можно задать и раздельно: `"type": "Number", "length": 15, "precision": 2`).
Остальные ключи — ниже, все со значением по умолчанию (не задавать, если устраивает дефолт).

## Свойства реквизита

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `synonym` | из имени | ML (строка или `{ru,en}`) |
| `tooltip` | пусто | ML |
| `comment` | пусто | строка |
| `fillChecking` | `DontCheck` | `DontCheck` / `ShowError` / `ShowWarning` (то же, что флаг `req`) |
| `fullTextSearch` | `Use` | `Use` / `DontUse` |
| `fillFromFillingValue` | `false` | bool |
| `fillValue` | по типу (см. ниже) | значение заполнения |
| `createOnInput` | `Auto` | `Auto` / `Use` / `DontUse` |
| `quickChoice` | `Auto` | `Auto` / `Use` / `DontUse` |
| `choiceHistoryOnInput` | `Auto` | `Auto` / `DontUse` |
| `dataHistory` | `Use` | `Use` / `DontUse` |
| `use` | `ForItem` | `ForItem` / `ForFolder` / `ForFolderAndItem` (реквизит иерархического справочника) |
| `passwordMode` | `false` | bool |
| `multiLine` | `false` | bool (то же, что флаг `multiline`) |
| `extendedEdit` | `false` | bool (расширенное редактирование — многострочный ввод) |
| `mask` | пусто | строка маски ввода |
| `format` / `editFormat` | пусто | форматная строка 1С (ML) |
| `markNegatives` | `false` | bool (выделять отрицательные, для Number) |
| `minValue` / `maxValue` | не задано | граница диапазона (см. ниже) |
| `choiceParameterLinks` | пусто | связи параметров выбора (см. ниже) |
| `choiceParameters` | пусто | параметры выбора (см. ниже) |
| `choiceForm` | пусто | ссылка на форму выбора `Тип.Объект.Form.ИмяФормы` |
| `choiceFoldersAndItems` | `Items` | `Items` / `Folders` / `FoldersAndItems` (что выбирать в иерарх. справочнике) |

Индексирование задаётся флагом `index` / `indexAdditional` в shorthand, либо в объекте — как и в строковой форме,
через `"type": "… | index"`.

### `fillValue` — значение заполнения

Пустое значение по типу компилятор подставляет сам — ключ **не задают**:

| Тип реквизита | Пустое значение |
|---------------|-----------------|
| String | пустая строка |
| Number | `0` |
| Boolean, Date, ссылочный, составной | не задано (nil) |

Ключ `fillValue` задают для **конкретного** значения — интерпретируется по типу реквизита:

- **Boolean** — `true` / `false`.
- **Number** — число (`21`, `1.5`).
- **String** — строка.
- **Date** — ISO-строка `"2020-01-01T00:00:00"`.
- **Ссылочный** — путь: `"Catalog.Валюты.EmptyRef"` (пустая ссылка), `"Enum.Периодичность.EnumValue.Месяц"`
  (значение перечисления), `"Catalog.СтраныМира.Россия"` (предопределённый элемент).
- **`null`** — явно «значение не задано» (nil), когда нужно перекрыть непустой дефолт типа.
- **`{ "emptyRef": true }`** — пустая ссылка для реквизита типа `DefinedType.X` (когда тип из пути не выводится).

> Пустая ссылка (`EmptyRef`) и `null` — разное: платформа хранит их отдельно.

### `minValue` / `maxValue` — границы диапазона

Число → числовая граница; строка → строковая (напр. год `"2000"`). Без ключа — граница не задана.

### `choiceParameterLinks` — связи параметров выбора

Связывают параметр выбора этого реквизита с другим реквизитом объекта. Массив строк или объектов:

```json
"choiceParameterLinks": ["Отбор.Организация=Организация", "Отбор.Договор=Договор:DontChange"]
"choiceParameterLinks": [{ "name": "Отбор.Организация", "dataPath": "Организация", "valueChange": "Clear" }]
```

- `dataPath` — реквизит **того же объекта**: имя обычного реквизита (`"Организация"`) или стандартного
  (`"Владелец"`, `"Ссылка"`).
- `valueChange` — `Clear` (по умолчанию) / `DontChange`.

### `choiceParameters` — параметры выбора

Фиксируют параметр выбора значением. Массив строк или объектов:

```json
"choiceParameters": ["Отбор.ЭтоГруппа=false"]
"choiceParameters": [{ "name": "Отбор.Владелец", "value": "Catalog.Организации.EmptyRef" }]
```

- `value` — bool / число / строка / ссылочный путь (несёт тип) ИЛИ массив (список фиксированных значений).
- Для набора голых имён-значений добавьте `type` (тип поля-фильтра), чтобы они стали ссылками:
  `{ "name": "Отбор.Тип", "type": "EnumRef.ТипыВЕТИС", "value": ["EmptyRef", "ТТН"] }`.

### Редкие ключи

`linkByType` — связь по типу (тип реквизита-Характеристики берётся из другого реквизита):
`{ "dataPath": "Свойство", "linkItem": 0 }` или строка-путь. Применяется для реквизитов-характеристик.

---

## Табличная часть — объектная форма

Значение в `tabularSections` — массив колонок ЛИБО объект со свойствами самой ТЧ:

```json
"tabularSections": {
  "Товары": {
    "synonym": { "ru": "Товары", "en": "Goods" },
    "tooltip": "Строки заказа",
    "fillChecking": "ShowError",
    "attributes": ["Номенклатура: CatalogRef.Номенклатура", "Количество: Number(15,3)"]
  }
}
```

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `synonym` | из имени | ML |
| `tooltip` | пусто | ML |
| `comment` | пусто | строка |
| `fillChecking` | `DontCheck` | `DontCheck` / `ShowError` / `ShowWarning` (обязательность заполнения ТЧ) |
| `use` | `ForItem` | `ForItem` / `ForFolder` / `ForFolderAndItem` (только Catalog / ChartOfCharacteristicTypes) |
| `attributes` | `[]` | колонки (shorthand или объектная форма реквизита) |
| `lineNumber` | — | кастомизация стандартного реквизита НомерСтроки (см. ниже) |

### `lineNumber` — стандартный реквизит НомерСтроки

У каждой ТЧ есть стандартный реквизит НомерСтроки. По умолчанию все его свойства типовые. Ключ `lineNumber`
на объектной форме ТЧ их переопределяет:

```json
"Строки": { "lineNumber": { "synonym": "Номер п/п", "fullTextSearch": "DontUse" }, "attributes": [...] }
```

Переопределяемые: `synonym`, `comment`, `fullTextSearch` (`Use`/`DontUse`), `tooltip`, `format`, `editFormat`,
`choiceHistoryOnInput` (`Auto`/`DontUse`).
