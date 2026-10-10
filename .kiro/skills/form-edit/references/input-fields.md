# Поля: ввод, флажок, переключатель, поле-надпись

Все ключи необязательны.

## Основное

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `path` | путь данных | Что показывает поле: `"Объект.Организация"`, `"ИмяРеквизита"`; колонка таблицы — `"Объект.Товары.Сумма"` |
| `title` | строка или `{ru, en}` | Заголовок; `""` — без заголовка |
| `titleLocation` | `none` / `left` / `right` / `top` / `bottom` / `auto` | Где заголовок |
| `inputHint` | строка или `{ru, en}` | Подсказка в пустом поле |
| `choiceButton` / `clearButton` / `dropListButton` | bool | Кнопки выбора, очистки, выпадающего списка |
| `markIncomplete` | bool | Подсвечивать незаполненное |
| `skipOnInput` | bool | Пропускать при переходе по Enter/Tab |
| `multiLine` | bool | Многострочное поле (комментарий) |

Размеры и растягивание — `references/layout-advanced.md`.

## Кнопки поля

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `openButton` | bool | Кнопка открытия значения (для ссылочного поля) |
| `createButton` | bool | Кнопка создания нового элемента |
| `spinButton` | bool | Кнопки «больше/меньше» у числа или даты |
| `choiceListButton` | bool | Кнопка списка выбора |
| `choiceButtonRepresentation` | `ShowInInputField` / `ShowInDropList` / `ShowInDropListAndInInputField` | Где показывать кнопку выбора |

## Выбор значения

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `choiceList` | массив `{ value, presentation }` | Фиксированный список вариантов (та же форма, что у `radio`) |
| `listChoiceMode` | bool | Выбирать только из `choiceList` |
| `quickChoice` | bool | Быстрый выбор: значения в выпадающем списке вместо формы выбора |
| `choiceForm` | строка | Своя форма выбора, напр. `"Catalog.Контрагенты.Form.ФормаВыбораПоставщика"` |
| `choiceFoldersAndItems` | `Items` / `Folders` / `FoldersAndItems` | Что можно выбрать в иерархическом справочнике |
| `choiceHistoryOnInput` | `Auto` / `DontUse` | Показывать историю выбора при вводе |
| `autoChoiceIncomplete` | bool | Открывать выбор, если введённый текст неоднозначен |
| `incompleteChoiceMode` | `OnActivate` | Когда открывать выбор незаполненного |
| `choiceListHeight` | число | Высота выпадающего списка, в строках |
| `dropListWidth` | число | Ширина выпадающего списка |
| `chooseType` | bool | Выбор типа значения у поля составного типа |
| `availableTypes` | тип | Ограничить типы составного поля, напр. `"CatalogRef.Валюты \| decimal(10,2)"` |

Ограничить выбор отбором или связать с другим полем — `references/choice-params.md`.

```json
{ "input": "Валюта", "path": "Объект.Валюта", "quickChoice": true, "openButton": false }
{ "input": "Вид", "path": "Объект.Вид", "listChoiceMode": true, "choiceList": [
    { "value": "Приход", "presentation": "Поступление" },
    { "value": "Расход", "presentation": "Списание" } ] }
```

## Формат и ограничения значения

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `format` | строка формата 1С или `{ru, en}` | Формат показа: `"ЧДЦ=2"`, `"ДЛФ=D"`, `"БЛ=Нет; БИ=Да"` (также у `labelField` и `check`) |
| `editFormat` | как `format` | Формат при редактировании |
| `mask` | строка маски | Маска ввода, напр. `"9999 999999"` |
| `minValue` / `maxValue` | число или строка | Допустимый диапазон |
| `markNegatives` | bool | Выделять отрицательные числа |
| `passwordMode` | bool | Скрывать ввод звёздочками |

```json
{ "input": "Сумма", "path": "Объект.Сумма", "format": "ЧДЦ=2; ЧРГ=' '", "minValue": 0, "markNegatives": true }
{ "input": "Пароль", "path": "Пароль", "passwordMode": true }
```

## Текст

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `wrap` | bool | Перенос по словам |
| `extendedEdit` | bool | Расширенное редактирование (многострочный ввод в отдельном окне) |
| `textEdit` | bool | `false` — запретить ручной ввод текста, только выбор |
| `editTextUpdate` | `OnValueChange` / `Always` / `DontUse` | Когда срабатывает изменение текста при редактировании |
| `warningOnEdit` | строка или `{ru, en}` | Предупреждение при попытке изменить значение (также у `check`, `radio`, `labelField`) |

## Флажок (`check`)

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `checkBoxType` | `auto` / `checkBox` / `switcher` / `tumbler` | Вид: флажок, выключатель или тумблер |
| `threeState` | bool | Третье, неопределённое состояние |
| `titleLocation` | `right` (по умолчанию) / `left` / `none` / … | Где заголовок |

```json
{ "check": "Активен", "path": "Объект.Активен", "checkBoxType": "switcher" }
```

## Переключатель (`radio`)

`path`, `radioButtonType` (`Auto` / `RadioButtons` / `Tumbler`), `columnsCount`, `choiceList` — варианты:

```json
{ "radio": "СпособКурса", "path": "Объект.СпособУстановкиКурса", "radioButtonType": "Tumbler",
  "choiceList": [
    { "value": "Enum.СпособыКурса.EnumValue.Авто",   "presentation": "Автоматически" },
    { "value": "Enum.СпособыКурса.EnumValue.Ручной", "presentation": { "ru": "Вручную", "en": "Manual" } }
  ] }
```

`value` — строка, число, булево или значение перечисления `"Enum.Тип.EnumValue.Значение"`; `presentation` — текст варианта. Дополнительно:

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `equalColumnsWidth` | bool | Равная ширина колонок раскладки |
| `equalItemsWidth` | bool | Равная ширина пунктов (также у `check`) |
| `itemHeight` / `itemTitleHeight` | число | Высота пункта / его заголовка |

Значение варианта системного перечисления задаётся явным типом: `{ "value": "Active", "valueType": "ent:AccountType", "presentation": "Активный" }`.

## Поле-надпись (`labelField`)

Показывает значение без редактирования. `hyperlink: true` — значение как ссылка (событие `Click`); `format` — формат показа.
