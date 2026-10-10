# Типы

Тип пишется в поле `type` реквизита, колонки, параметра или поля.

## Основные типы

| DSL | Тип |
|-----|-----|
| `string` / `string(100)` | Строка (неограниченная / длины 100) |
| `decimal(15,2)` / `decimal(10,0,nonneg)` | Число / неотрицательное |
| `boolean` | Булево |
| `date` / `dateTime` / `time` | Дата / дата и время / время |
| `CatalogRef.X` / `DocumentRef.X` / `EnumRef.X` / … | Ссылки |
| `CatalogObject.X` / `DocumentObject.X` / `DataProcessorObject.X` / `ReportObject.X` | Объекты (основной реквизит) |
| `InformationRegisterRecordSet.X` / `AccumulationRegisterRecordSet.X` | Наборы записей |
| `ValueTable` / `ValueTree` / `ValueList` | Таблица / дерево / список значений |
| `DynamicList` | Динамический список |
| `TypeDescription`, `UUID`, `FormattedString`, `Picture`, `Color`, `Font`, `DataCompositionSettings`, `StandardPeriod`, `mxl:SpreadsheetDocument` | Платформенные |

Также `ChartOfAccountsRef/Object`, `ChartOfCharacteristicTypesRef/Object`, `ChartOfCalculationTypesRef/Object`, `ExchangePlanRef/Object`, `BusinessProcessRef/Object`, `TaskRef/Object`, `AccountingRegisterRecordSet`, `InformationRegisterRecordManager`, `ConstantsSet`.

> `FormDataStructure`, `FormDataCollection`, `FormDataTree` — не типы реквизита (ошибка при загрузке). Вместо них — объектный тип (`DocumentObject.X`…), `ValueTable`, `ValueTree`.

Ниже — типы, которые нельзя выразить одним именем: составные типы, наборы типов и платформенные наборы ссылок.

## Составные типы

Несколько типов на одном реквизите — части перечисляются через разделитель `" | "` (можно `+`). Реквизит сможет принимать значение любого из перечисленных типов:

```json
{ "name": "Плательщик",
  "type": "CatalogRef.Организации | CatalogRef.ИндивидуальныеПредприниматели" }
```

Смешивать можно типы из разных категорий — ссылки, примитивы, наборы типов:

```json
{ "name": "Источник",
  "type": "CatalogRef.Контрагенты | DocumentRef.Заказ | string(150)" }
```

Каждая часть — самостоятельный тип из этого файла. Порядок частей произвольный.

## Наборы типов (TypeSet)

«Набор типов» подставляется вместо конкретного типа — это один токен, а не перечисление. Применимо и в составном типе как одна из частей.

| Токен `type` | Смысл |
|------|-------|
| `"DefinedType.ИмяТипа"` | определяемый тип конфигурации |
| `"Characteristic.ИмяПлана"` | тип значения характеристики (по плану видов характеристик) |
| `"AnyRef"` | любая ссылка |
| `"AnyIBRef"` | любая ссылка информационной базы |

Определяемый тип — реквизит принимает то, что задано в определяемом типе конфигурации (например `DefinedType.ДенежнаяСумма`):

```json
{ "name": "Сумма", "type": "DefinedType.ДенежнаяСумма" }
```

Характеристика — тип значения берётся из плана видов характеристик:

```json
{ "name": "Значение", "type": "Characteristic.ДополнительныеРеквизиты" }
```

## Платформенные наборы ссылок

«Голый» ссылочный токен **без `.Имя`** означает «любая ссылка этой категории объектов»:

| Токен `type` | Смысл |
|------|-------|
| `"CatalogRef"` | любая ссылка справочника |
| `"DocumentRef"` | любая ссылка документа |
| `"EnumRef"` | любая ссылка перечисления |
| `"ExchangePlanRef"` | любая ссылка плана обмена |
| `"TaskRef"` | любая ссылка задачи |
| `"BusinessProcessRef"` | любая ссылка бизнес-процесса |
| `"ChartOfCharacteristicTypesRef"` | любая ссылка плана видов характеристик |
| `"ChartOfAccountsRef"` | любая ссылка плана счетов |
| `"ChartOfCalculationTypesRef"` | любая ссылка плана видов расчёта |

Различие с одиночной ссылкой — только в наличии `.Имя`:

- `"CatalogRef.Валюты"` — конкретный справочник «Валюты»;
- `"CatalogRef"` — любой справочник.

```json
{ "name": "ЛюбойСправочник", "type": "CatalogRef" }
```

Эти наборы тоже комбинируются в составном типе:

```json
{ "name": "Объект", "type": "CatalogRef | DocumentRef" }
```
