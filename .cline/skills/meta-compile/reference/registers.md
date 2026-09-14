# Регистры: Information, Accumulation, Accounting, Calculation

**Измерения и ресурсы** задаются как реквизиты (shorthand `"Имя: Тип | флаги"` или объектная форма, см.
`attributes.md`). Флаги измерений: `master`, `mainFilter`, `denyIncomplete`, `useInTotals` (регистр накопления).

```json
"dimensions": ["Организация: CatalogRef.Организации | master, mainFilter"],
"resources": ["Сумма: Number(15,2)"]
```

## InformationRegister (Регистр сведений)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `writeMode` | `Independent` | `Independent` / `RecorderSubordinate` |
| `periodicity` | `Nonperiodical` | `Nonperiodical` / `Second` / `Day` / `Month` / `Quarter` / `Year` / `RecorderPosition` |
| `mainFilterOnPeriod` | `false` | bool (основной отбор по периоду) |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `dimensions` / `resources` / `attributes` | `[]` | измерения / ресурсы / реквизиты |

```json
{ "type": "InformationRegister", "name": "КурсыВалют", "periodicity": "Day",
  "dimensions": ["Валюта: CatalogRef.Валюты | master, mainFilter, denyIncomplete"],
  "resources": ["Курс: Number(15,4)", "Кратность: Number(10,0)"] }
```

## AccumulationRegister (Регистр накопления)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `registerType` | `Balance` | `Balance` (остатки) / `Turnovers` (обороты) |
| `enableTotalsSplitting` | `true` | bool (разделение итогов) |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `dimensions` / `resources` / `attributes` | `[]` | измерения / ресурсы / реквизиты |

```json
{ "type": "AccumulationRegister", "name": "ОстаткиТоваров", "registerType": "Balance",
  "dimensions": ["Номенклатура: CatalogRef.Номенклатура", "Склад: CatalogRef.Склады"],
  "resources": ["Количество: Number(15,3)"] }
```

## AccountingRegister (Регистр бухгалтерии)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `chartOfAccounts` | — | **обязательно**: ссылка на план счетов `ChartOfAccounts.X` |
| `correspondence` | `false` | bool (корреспонденция) |
| `periodAdjustmentLength` | `0` | длина периода корректировки |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `dimensions` / `resources` / `attributes` | `[]` | измерения / ресурсы / реквизиты |

```json
{ "type": "AccountingRegister", "name": "Хозрасчетный",
  "chartOfAccounts": "ChartOfAccounts.Хозрасчетный",
  "dimensions": ["Организация: CatalogRef.Организации"], "resources": ["Сумма: Number(15,2)"] }
```

## CalculationRegister (Регистр расчёта)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `chartOfCalculationTypes` | — | **обязательно**: ссылка на ПВР `ChartOfCalculationTypes.X` |
| `periodicity` | `Month` | периодичность |
| `actionPeriod` | `false` | bool (период действия) |
| `basePeriod` | `false` | bool (базовый период) |
| `schedule` | пусто | ссылка на регистр сведений графиков |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `dimensions` / `resources` / `attributes` | `[]` | измерения / ресурсы / реквизиты |

```json
{ "type": "CalculationRegister", "name": "Начисления",
  "chartOfCalculationTypes": "ChartOfCalculationTypes.Начисления", "periodicity": "Month",
  "dimensions": ["Сотрудник: CatalogRef.Сотрудники"], "resources": ["Сумма: Number(15,2)"] }
```

> **AccountingRegister** требует план счетов, **CalculationRegister** — план видов расчёта (и оба — документ-регистратор).
