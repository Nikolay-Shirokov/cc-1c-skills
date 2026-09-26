# Form Presets

Пресеты управляют раскладкой форм, генерируемых в режиме `--from-object`.

## Как работает

Цепочка merge (каждый следующий уровень перезаписывает предыдущий через deep merge):

1. **Hardcoded defaults** -- встроены в скрипт, ориентированы на ERP
2. **Built-in preset** -- файл из этой папки (`erp-standard.json` по умолчанию)
3. **Project-level preset** -- файл `presets/skills/form/<name>.json`, поиск вверх от OutputPath

Имя пресета задаётся параметром `--preset` (по умолчанию `erp-standard`).

## Project-level пресет

Чтобы переопределить стандартный пресет в своём проекте, создайте файл:

```
<project-root>/presets/skills/form/erp-standard.json
```

Скрипт ищет этот файл, поднимаясь от OutputPath к корню. Первый найденный файл применяется поверх built-in через deep merge -- не нужно копировать весь пресет, достаточно указать только переопределяемые ключи.

## Секции

Ключи верхнего уровня в JSON -- секции вида `{тип}.{назначение}`:

| Секция | Тип объекта | Назначение формы |
|--------|-------------|------------------|
| `document.item` | Document | Форма документа |
| `document.list` | Document | Форма списка |
| `document.choice` | Document | Форма выбора |
| `catalog.item` | Catalog | Форма элемента |
| `catalog.folder` | Catalog | Форма группы |
| `catalog.list` | Catalog | Форма списка |
| `catalog.choice` | Catalog | Форма выбора |
| `informationRegister.record` | InformationRegister | Форма записи |
| `informationRegister.list` | InformationRegister | Форма списка |
| `accumulationRegister.list` | AccumulationRegister | Форма списка |
| `chartOfCharacteristicTypes.*` | ChartOfCharacteristicTypes | item/folder/list/choice |
| `exchangePlan.*` | ExchangePlan | item/list/choice |
| `chartOfAccounts.*` | ChartOfAccounts | item/folder/list/choice |

### basedOn

Секция может наследовать от другой:

```json
{
  "document.choice": {
    "basedOn": "document.list",
    "properties": { "windowOpeningMode": "LockOwnerWindow" }
  }
}
```

## Ключи секций

### Форма объекта (Item/Record)

| Ключ | Описание | Допустимые значения |
|------|----------|---------------------|
| `header.position` | Где размещать шапку | `"insidePage"` -- на первой странице, `"abovePages"` -- над страницами |
| `header.layout` | Колонки шапки | `"1col"`, `"2col"` |
| `header.distribute` | Распределение в 2 колонках | `"even"`, `"left"`, `"right"` |
| `header.dateTitle` | Заголовок даты (Document) | строка, напр. `"от"` |
| `footer.fields` | Поля в подвале | массив имён реквизитов, напр. `["Комментарий"]` |
| `footer.position` | Где размещать подвал | `"insidePage"`, `"belowPages"`, `"none"` |
| `tabularSections.container` | Контейнер табчастей | `"pages"` -- на вкладках, `"inline"` -- в корне, `"single-no-pages"` -- одна ТЧ без страниц |
| `tabularSections.exclude` | Исключить табчасти | массив имён, напр. `["ДополнительныеРеквизиты"]` |
| `tabularSections.lineNumber` | Колонка НомерСтроки | `true` / `false` |
| `additional.position` | Блок доп. реквизитов | `"page"` -- отдельная вкладка, `"below"` -- под табчастями, `"none"` -- не создавать |
| `additional.layout` | Колонки доп. блока | `"1col"`, `"2col"` |
| `additional.bspGroup` | Группа ДополнительныеРеквизиты | `true` / `false` |
| `codeDescription.layout` | Код + Наименование | `"horizontal"`, `"vertical"` |
| `codeDescription.order` | Порядок Код/Наименование | `"descriptionFirst"`, `"codeFirst"` |
| `parent.title` | Заголовок поля Родитель | строка, напр. `"Входит в группу"` |
| `parent.position` | Позиция поля Родитель | `"beforeCodeDescription"`, `"afterCodeDescription"`, `"inHeader"` |
| `owner.readOnly` | Владелец только для чтения | `true` / `false` |
| `owner.position` | Позиция поля Владелец | `"first"` |
| `fieldDefaults.ref.choiceButton` | Кнопка выбора для ссылок | `true` / `false` |
| `fieldDefaults.boolean.element` | Элемент для Boolean | `"check"` (флажок) |
| `commandBar` | Командная панель формы | `"auto"`, `"none"` |
| `properties` | Свойства формы | объект: `autoTitle`, `windowOpeningMode` и др. |

### Форма списка (List/Choice)

| Ключ | Описание | Допустимые значения |
|------|----------|---------------------|
| `columns` | Какие колонки показывать | `"all"` -- все реквизиты, или массив имён |
| `columnType` | Тип элемента колонки | `"labelField"`, `"input"` |
| `hiddenRef` | Скрытая колонка Ref | `true` / `false` |
| `tableCommandBar` | Командная панель таблицы | `"auto"`, `"none"` |
| `commandBar` | Командная панель формы | `"auto"`, `"none"` |
| `choiceMode` | Режим выбора (ChoiceForm) | `true` / `false` |
| `properties` | Свойства формы | объект: `windowOpeningMode` и др. |

## Пример project-level пресета

```json
{
  "name": "my-project",
  "description": "Стиль форм нашего проекта",

  "document.item": {
    "header": {
      "layout": "1col"
    },
    "tabularSections": {
      "exclude": ["ДополнительныеРеквизиты", "СведенияОСертификатах"]
    },
    "additional": {
      "position": "none"
    }
  },

  "catalog.item": {
    "codeDescription": {
      "order": "codeFirst"
    }
  }
}
```

Этот файл переопределяет только указанные ключи -- остальное наследуется из built-in пресета.
