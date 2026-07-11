# Планы: ChartOfCharacteristicTypes, ChartOfAccounts, ChartOfCalculationTypes

Все три — ссылочные типы (наследуют слой Catalog: коды, `standardAttributes`, `characteristics`, `inputByString`,
формы, представления — см. `catalog.md` / `attributes.md` / `blocks.md`) с предопределёнными элементами и своими
специальными свойствами.

## ChartOfCharacteristicTypes (План видов характеристик)

Хранит определения характеристик (видов). Иерархический (папки+элементы).

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `valueType` | любой примитив | тип значения характеристики (составной — строка `"A + B"` или массив `valueTypes`) |
| `characteristicExtValues` | пусто | ссылка на справочник доп. значений |
| `hierarchical` | `false` | bool |
| `foldersOnTop` | `true` | bool |
| `codeLength` | `9` | длина кода |
| `descriptionLength` | `100` | длина наименования |
| `checkUnique` | `true` | bool |
| `autonumbering` | `true` | bool |
| `codeSeries` | `WholeCharacteristicKind` | серия кодов |
| `createOnInput` | `DontUse` | `Auto` / `Use` / `DontUse` |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `predefined` | `[]` | предопределённые виды (несут тип значения — см. ниже) |
| `attributes` / `tabularSections` | `[]` / `{}` | реквизиты / табличные части |

**Предопределённые виды** несут **тип значения на элемент** — короткой строкой после `:`
(`"(Код) Имя [Наименование]: Тип"`, составной через `+`) или объектной формой с ключом `type`:

```json
"predefined": [
  "(000001) Цвет: CatalogRef.Цвета",
  "(000002) Размер [Размер одежды]: String(50) + Number(3,0)",
  { "name": "Группа", "isFolder": true, "type": "" }
]
```

## ChartOfAccounts (План счетов)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `extDimensionTypes` | пусто | ссылка на ПВХ видов субконто `ChartOfCharacteristicTypes.X` |
| `maxExtDimensionCount` | `0` (без ПВХ) / `3` (с ПВХ) | макс. число субконто |
| `codeMask` | пусто | маска кода счёта (напр. `"@@@.@@"`) |
| `codeLength` | `9` | длина кода |
| `descriptionLength` | `25` | длина наименования |
| `checkUnique` | `true` | bool |
| `codeSeries` | `WholeChartOfAccounts` | серия кодов |
| `defaultPresentation` | `AsCode` | `AsCode` / `AsDescription` |
| `autoOrderByCode` | `true` | bool |
| `orderLength` | `9` | длина строки упорядочивания |
| `createOnInput` | `DontUse` | `Auto` / `Use` / `DontUse` |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `accountingFlags` | `[]` | признаки учёта (как реквизиты, тип по умолчанию Boolean; массив имён/реквизитов) |
| `extDimensionAccountingFlags` | `[]` | признаки учёта субконто (как реквизиты) |
| `predefined` | `[]` | предопределённые счета (см. ниже) |

**Предопределённый счёт** (объектная форма):

| Поле | Умолчание | Значения |
|------|-----------|----------|
| `name` | — | имя (обязательно) |
| `code` | пусто | код счёта |
| `description` | из имени | наименование |
| `accountType` | `ActivePassive` | `Active` / `Passive` / `ActivePassive` |
| `offBalance` | `false` | bool (забалансовый) |
| `order` | — | строка сортировки |
| `flags` | `[]` | включённые признаки учёта (только TRUE) |
| `subconto` | `[]` | виды субконто (см. ниже) |
| `childItems` | `[]` | подчинённые счета |

`subconto` — строка `"Вид | Признак1, Признак2"` (после `|` — включённые признаки учёта субконто; токен `Turnover` —
«только обороты») или объект `{ type, turnover, flags }`. `Вид` — имя предопределённого вида из ПВХ `extDimensionTypes`.

```json
"predefined": [
  { "name": "ОсновныеСредства", "code": "01", "accountType": "Active", "order": " 01",
    "flags": ["Количественный"], "subconto": ["Номенклатура | Суммовой, Валютный"],
    "childItems": [ { "name": "ОСВОрганизации", "code": "01.01", "accountType": "Active", "order": " 01.01" } ] }
]
```

## ChartOfCalculationTypes (План видов расчёта)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `codeLength` | `5` | длина кода |
| `descriptionLength` | `100` | длина наименования |
| `codeAllowedLength` | `Variable` | `Variable` / `Fixed` |
| `dependenceOnCalculationTypes` | `DontUse` | `DontUse` / `OnPeriod` / `OnActionPeriod` |
| `baseCalculationTypes` | `[]` | базовые виды расчёта (список ссылок `ChartOfCalculationTypes.X`) |
| `actionPeriodUse` | `false` | bool (использовать период действия) |
| `createOnInput` | `DontUse` | `Auto` / `Use` / `DontUse` |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `predefined` | `[]` | предопределённые виды расчёта (см. ниже) |

**Предопределённый вид расчёта** — плоский: строка `"(Код) Имя [Наименование]"` или объект
`{ name, code, description, actionPeriodIsBase }` (`actionPeriodIsBase` — bool, по умолчанию `false`).

```json
"predefined": [ "(00001) Оклад [Оклад по дням]", { "name": "Премия", "code": "00002", "actionPeriodIsBase": true } ]
```

> **ChartOfAccounts** ссылается на ПВХ через `extDimensionTypes`. Регистр бухгалтерии/расчёта требует
> соответствующий план (см. `registers.md`).
