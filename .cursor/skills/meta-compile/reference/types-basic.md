# Базовые типы: Catalog, Document, Enum, Constant, DefinedType, Report, DataProcessor

## Catalog

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `hierarchical` | `false` | Hierarchical |
| `hierarchyType` | `HierarchyFoldersAndItems` | HierarchyType |
| `limitLevelCount` | `false` | LimitLevelCount |
| `levelCount` | `2` | LevelCount |
| `foldersOnTop` | `true` | FoldersOnTop |
| `codeLength` | `9` | CodeLength |
| `codeType` | `String` | CodeType |
| `codeAllowedLength` | `Variable` | CodeAllowedLength |
| `codeSeries` | `WholeCatalog` | CodeSeries |
| `descriptionLength` | `25` | DescriptionLength |
| `autonumbering` | `true` | Autonumbering |
| `checkUnique` | `false` | CheckUnique |
| `defaultPresentation` | `AsDescription` | DefaultPresentation |
| `subordinationUse` | `ToItems` | SubordinationUse |
| `quickChoice` | `false` | QuickChoice |
| `choiceMode` | `BothWays` | ChoiceMode |
| `owners` | `[]` | Owners |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

```json
{ "type": "Catalog", "name": "Организации", "attributes": ["ИНН: String(12)", "КПП: String(9)"] }
```

## Document

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `numberType` | `String` | NumberType |
| `numberLength` | `11` | NumberLength |
| `numberAllowedLength` | `Variable` | NumberAllowedLength |
| `numberPeriodicity` | `Year` | NumberPeriodicity |
| `checkUnique` | `true` | CheckUnique |
| `autonumbering` | `true` | Autonumbering |
| `posting` | `Allow` | Posting |
| `realTimePosting` | `Deny` | RealTimePosting |
| `registerRecordsDeletion` | `AutoDelete` | RegisterRecordsDeletion |
| `registerRecordsWritingOnPost` | `WriteModified` | RegisterRecordsWritingOnPost |
| `postInPrivilegedMode` | `true` | PostInPrivilegedMode |
| `unpostInPrivilegedMode` | `true` | UnpostInPrivilegedMode |
| `registerRecords` | `[]` | RegisterRecords |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

RegisterRecords — массив строк: `"AccumulationRegister.Продажи"`, `"InformationRegister.Цены"`.

```json
{
  "type": "Document", "name": "ПриходнаяНакладная",
  "registerRecords": ["AccumulationRegister.ОстаткиТоваров"],
  "attributes": ["Организация: CatalogRef.Организации", "Контрагент: CatalogRef.Контрагенты"],
  "tabularSections": { "Товары": ["Номенклатура: CatalogRef.Номенклатура", "Количество: Number(15,3)"] }
}
```

## Enum

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `values` | `[]` | → EnumValue в ChildObjects |

```json
{ "type": "Enum", "name": "Статусы", "values": ["Новый", "ВРаботе", "Закрыт"] }
```

## Constant

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `valueType` | `String` | Type |

`valueType` принимает shorthand типа: `"String(100)"`, `"Number(15,2)"`, `"Boolean"`, `"CatalogRef.Валюты"`.

```json
{ "type": "Constant", "name": "ОсновнаяВалюта", "valueType": "CatalogRef.Валюты" }
```

## DefinedType

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `valueTypes` | `[]` | Type (составной тип) |
| `valueType` | — | Алиас для `valueTypes` (строка или массив) |

```json
{ "type": "DefinedType", "name": "ДенежныеСредства", "valueTypes": ["CatalogRef.БанковскиеСчета", "CatalogRef.Кассы"] }
{ "type": "DefinedType", "name": "ФлагАктивности", "valueType": "Boolean" }
```

## Report

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

```json
{ "type": "Report", "name": "ОстаткиТоваров" }
```

## DataProcessor

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

```json
{ "type": "DataProcessor", "name": "ЗагрузкаДанных", "attributes": ["ПутьКФайлу: String(500)"] }
```
