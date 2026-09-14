# Блоки объекта

Кросс-типовые блоки уровня объекта (применимы к ссылочным типам — Catalog, Document, ChartOf*, ExchangePlan,
BusinessProcess, Task и др.).

## Представления

Тексты представления объекта в интерфейсе (ML — строка или `{ru,en}`, по умолчанию пусто):

| Ключ | Смысл |
|------|-------|
| `objectPresentation` | представление объекта |
| `extendedObjectPresentation` | расширенное представление объекта |
| `listPresentation` | представление списка |
| `extendedListPresentation` | расширенное представление списка |
| `explanation` | пояснение |

Набор доступных ключей зависит от типа (у списочных без формы объекта нет `objectPresentation` и т.п.).

```json
"listPresentation": "Организации", "objectPresentation": { "ru": "Организация", "en": "Company" }
```

## Команды

Команды объекта. Ключ — имя команды, значение — объект свойств (map `имя → объект` или массив `[{name, …}]`).
Для каждой команды создаётся заготовка модуля с обработчиком `ОбработкаКоманды`.

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `synonym` | из имени | ML |
| `tooltip` | пусто | ML |
| `comment` | пусто | строка |
| `group` | **обязательно** | группа размещения (см. ниже) |
| `commandParameterType` | пусто | тип параметра (напр. `CatalogRef.Номенклатура`) — **только для групп формы** |
| `parameterUseMode` | `Single` | `Single` / `Multiple` |
| `modifiesData` | `false` | bool |
| `representation` | `Auto` | вид отображения |
| `picture` | пусто | ссылка на картинку (`StdPicture.Print`, `CommonPicture.Загрузка`) |
| `shortcut` | пусто | сочетание клавиш |

```json
"commands": {
  "ПечатьЭтикеток": { "synonym": "Печать этикеток", "group": "FormCommandBarImportant",
                      "commandParameterType": "CatalogRef.Номенклатура", "picture": "StdPicture.Print" }
}
```

**Группа (`group`) обязательна** — каждая команда размещается в группе командного интерфейса:

- **Командный интерфейс раздела** (панель навигации / панель действий; `commandParameterType` **недоступен**):
  `NavigationPanelImportant` / `NavigationPanelOrdinary` / `NavigationPanelSeeAlso`,
  `ActionsPanelCreate` / `ActionsPanelReports` / `ActionsPanelTools`.
- **Командный интерфейс формы** (`commandParameterType` допустим): `FormCommandBarImportant` /
  `FormCommandBarCreateBasedOn`, `FormNavigationPanelImportant` / `FormNavigationPanelGoTo` / `FormNavigationPanelSeeAlso`.
- **Кастомная группа:** `CommandGroup.<Имя>` (параметр допустим).

Группа раздела вместе с `commandParameterType` → ошибка.

## `inputByString` / `dataLockFields` / `basedOn`

Списки полей/объектов уровня объекта. Поля — по имени реквизита объекта (обычного или стандартного).

- **`inputByString`** — поля быстрого ввода по строке. По умолчанию выводятся из Кода/Наименования — ключ не нужен;
  задать при другом наборе/порядке, либо `[]` для отключения.
  ```json
  "inputByString": ["Код", "Наименование", "Контрагент"]
  ```
- **`dataLockFields`** — поля управляемой блокировки данных (по умолчанию пусто).
  ```json
  "dataLockFields": ["Организация", "Контрагент"]
  ```
- **`basedOn`** — «ввод на основании»: список ссылок на объекты метаданных (по умолчанию пусто).
  ```json
  "basedOn": ["Catalog.Контрагенты", "Document.ЗаказПоставщику"]
  ```

## `standardAttributes` — кастомизация стандартных реквизитов

Стандартные реквизиты объекта (Наименование, Код, Владелец, …) переопределяются блоком
`standardAttributes` — объект `{ ИмяРеквизита: { переопределения } }`. Имена — как в 1С: `Description`, `Code`,
`Owner`, `Parent`, `DeletionMark`, `Ref` и т.д. (для Document — `Date`, `Number`, `Posted`).

Переопределяемые поля — как у обычного реквизита (`synonym`, `tooltip`, `fillChecking`, `fillValue`,
`choiceParameters`, `comment`, `mask`, `choiceForm`; полный набор — `attributes.md`).

```json
"standardAttributes": {
  "Description": { "synonym": "Наименование контрагента" },
  "Code": { "fillChecking": "ShowError" }
}
```

## `characteristics` — «Дополнительные реквизиты и сведения»

Привязка плана видов характеристик. Массив; каждый элемент связывает **источник типов** (где определены
характеристики) и **источник значений** (где хранятся значения).

```json
"characteristics": [{
  "types":  { "from": "Catalog.НаборыДопРеквизитов.ДополнительныеРеквизиты",
              "key": "Свойство", "filterField": "Ссылка", "filterValue": "Справочник_Организации" },
  "values": { "from": "Catalog.Организации.TabularSection.ДополнительныеРеквизиты",
              "object": "Ссылка", "type": "Свойство", "value": "Значение" }
}]
```

- `from` — таблица-источник; `key`/`filterField`/`object`/`type`/`value` — поля источника (по имени реквизита).
- `filterValue` — значение фильтра типов: имя предопределённого набора (строка) или путь к элементу.
