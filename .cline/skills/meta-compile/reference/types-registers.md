# Регистры и планы: InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes

## Измерения и ресурсы (общее)

Синтаксис аналогичен реквизитам (shorthand `"Имя: Тип | флаги"`).

Флаги измерений: `master`, `mainFilter`, `denyIncomplete`, `useInTotals` (AccumulationRegister only, default `true`).

```json
"dimensions": ["Организация: CatalogRef.Организации | master, mainFilter, denyIncomplete"],
"resources": ["Сумма: Number(15,2)"]
```

---

## InformationRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `writeMode` | `Independent` | WriteMode |
| `periodicity` | `Nonperiodical` | InformationRegisterPeriodicity |
| `mainFilterOnPeriod` | авто* | MainFilterOnPeriod |
| `dimensions` | `[]` | → Dimension |
| `resources` | `[]` | → Resource |
| `attributes` | `[]` | → Attribute |

\* `mainFilterOnPeriod` = `true` если `periodicity` != `Nonperiodical`.

```json
{
  "type": "InformationRegister", "name": "КурсыВалют", "periodicity": "Day",
  "dimensions": ["Валюта: CatalogRef.Валюты | master, mainFilter, denyIncomplete"],
  "resources": ["Курс: Number(15,4)", "Кратность: Number(10,0)"]
}
```

## AccumulationRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `registerType` | `Balance` | RegisterType (`Balance` / `Turnovers`) |
| `enableTotalsSplitting` | `true` | EnableTotalsSplitting |
| `dimensions` | `[]` | → Dimension |
| `resources` | `[]` | → Resource |
| `attributes` | `[]` | → Attribute |

```json
{
  "type": "AccumulationRegister", "name": "ОстаткиТоваров", "registerType": "Balance",
  "dimensions": ["Номенклатура: CatalogRef.Номенклатура"],
  "resources": ["Количество: Number(15,3)"]
}
```

## AccountingRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `chartOfAccounts` | `""` | ChartOfAccounts (**обязательная** ссылка на план счетов) |
| `correspondence` | `false` | Correspondence |
| `periodAdjustmentLength` | `0` | PeriodAdjustmentLength |
| `dimensions` | `[]` | → Dimension |
| `resources` | `[]` | → Resource |
| `attributes` | `[]` | → Attribute |

```json
{
  "type": "AccountingRegister", "name": "Хозрасчетный",
  "chartOfAccounts": "ChartOfAccounts.Хозрасчетный",
  "dimensions": ["Организация: CatalogRef.Организации"],
  "resources": ["Сумма: Number(15,2)"]
}
```

## CalculationRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `chartOfCalculationTypes` | `""` | ChartOfCalculationTypes (**обязательная** ссылка на ПВР) |
| `periodicity` | `Month` | Periodicity |
| `actionPeriod` | `false` | ActionPeriod |
| `basePeriod` | `false` | BasePeriod |
| `schedule` | `""` | Schedule (ссылка на РС графиков) |
| `dimensions` | `[]` | → Dimension |
| `resources` | `[]` | → Resource |
| `attributes` | `[]` | → Attribute |

```json
{
  "type": "CalculationRegister", "name": "Начисления",
  "chartOfCalculationTypes": "ChartOfCalculationTypes.Начисления",
  "periodicity": "Month",
  "dimensions": ["Сотрудник: CatalogRef.Сотрудники"],
  "resources": ["Сумма: Number(15,2)"]
}
```

---

## ChartOfCharacteristicTypes

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `codeLength` | `9` | CodeLength |
| `descriptionLength` | `25` | DescriptionLength |
| `autonumbering` | `true` | Autonumbering |
| `checkUnique` | `false` | CheckUnique |
| `characteristicExtValues` | `""` | CharacteristicExtValues |
| `valueTypes` | авто* | Type (составной тип значений характеристик) |
| `hierarchical` | `false` | Hierarchical |
| `attributes` | `[]` | → Attribute |
| `tabularSections` | `{}` | → TabularSection |

\* По умолчанию: Boolean, String(100), Number(15,2), DateTime.

```json
{
  "type": "ChartOfCharacteristicTypes", "name": "ВидыСубконто",
  "valueTypes": ["CatalogRef.Номенклатура", "CatalogRef.Контрагенты", "Boolean", "String", "Number(15,2)"]
}
```

## ChartOfAccounts

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `extDimensionTypes` | `""` | ExtDimensionTypes (ссылка на ПВХ) |
| `maxExtDimensionCount` | `3` | MaxExtDimensionCount |
| `codeMask` | `""` | CodeMask |
| `codeLength` | `8` | CodeLength |
| `descriptionLength` | `120` | DescriptionLength |
| `codeSeries` | `WholeChartOfAccounts` | CodeSeries |
| `autoOrderByCode` | `true` | AutoOrderByCode |
| `orderLength` | `5` | OrderLength |
| `hierarchical` | `false` | Hierarchical |
| `accountingFlags` | `[]` | → AccountingFlag (Boolean-тип, массив имён) |
| `extDimensionAccountingFlags` | `[]` | → ExtDimensionAccountingFlag (Boolean-тип, массив имён) |
| `attributes` | `[]` | → Attribute |
| `tabularSections` | `{}` | → TabularSection |

```json
{
  "type": "ChartOfAccounts", "name": "Хозрасчетный",
  "extDimensionTypes": "ChartOfCharacteristicTypes.ВидыСубконто", "maxExtDimensionCount": 3,
  "codeLength": 8, "codeMask": "@@@.@@.@",
  "accountingFlags": ["Валютный", "Количественный"],
  "extDimensionAccountingFlags": ["Суммовой", "Валютный"]
}
```

## ChartOfCalculationTypes

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `codeLength` | `9` | CodeLength |
| `descriptionLength` | `25` | DescriptionLength |
| `autonumbering` | `true` | Autonumbering |
| `checkUnique` | `false` | CheckUnique |
| `dependenceOnCalculationTypes` | `DontUse` | DependenceOnCalculationTypes |
| `actionPeriodUse` | `false` | ActionPeriodUse |
| `attributes` | `[]` | → Attribute |
| `tabularSections` | `{}` | → TabularSection |

`dependenceOnCalculationTypes`: `DontUse`, `OnActionPeriod`.

```json
{ "type": "ChartOfCalculationTypes", "name": "Начисления", "dependenceOnCalculationTypes": "OnActionPeriod" }
```

## Зависимости

- **AccountingRegister** требует `ChartOfAccounts` (и документ-регистратор)
- **CalculationRegister** требует `ChartOfCalculationTypes` (и документ-регистратор)
- **ChartOfAccounts** ссылается на `ChartOfCharacteristicTypes` через `extDimensionTypes`
