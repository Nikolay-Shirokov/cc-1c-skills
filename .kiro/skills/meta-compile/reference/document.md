# Document, DocumentJournal, Sequence, DocumentNumerator

## Document (Документ)

```json
{ "type": "Document", "name": "ПриходнаяНакладная",
  "registerRecords": ["AccumulationRegister.ОстаткиТоваров"],
  "attributes": ["Организация: CatalogRef.Организации"],
  "tabularSections": { "Товары": ["Номенклатура: CatalogRef.Номенклатура", "Количество: Number(15,3)"] } }
```

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `comment` | пусто | строка |
| `numerator` | пусто | ссылка на нумератор `DocumentNumerator.X` |
| `numberType` | `String` | `String` / `Number` |
| `numberLength` | `11` | длина номера |
| `numberAllowedLength` | `Variable` | `Variable` / `Fixed` |
| `numberPeriodicity` | `Year` | `Nonperiodical` / `Day` / `Month` / `Quarter` / `Year` |
| `checkUnique` | `true` | bool |
| `autonumbering` | `true` | bool |
| `posting` | `Allow` | `Allow` / `Deny` (проведение) |
| `realTimePosting` | `Deny` | `Allow` / `Deny` (оперативное проведение) |
| `registerRecordsDeletion` | `AutoDelete` | `AutoDelete` / `AutoDeleteOnUnpost` / `AutoDeleteOff` |
| `registerRecordsWritingOnPost` | `WriteSelected` | `WriteModified` / `WriteSelected` / `WriteAll` |
| `sequenceFilling` | `AutoFill` | заполнение последовательностей |
| `postInPrivilegedMode` | `true` | bool |
| `unpostInPrivilegedMode` | `true` | bool |
| `createOnInput` | `Use` | `Auto` / `Use` / `DontUse` |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `fullTextSearch` | `Use` | `Use` / `DontUse` |
| `dataHistory` | `DontUse` | `Use` / `DontUse` |
| `registerRecords` | `[]` | движения: список ссылок `["AccumulationRegister.ОстаткиТоваров", "InformationRegister.Цены"]` |
| `useStandardCommands` | `true` | bool |
| `includeHelpInContents` | `false` | bool |
| `attributes` / `tabularSections` | `[]` / `{}` | реквизиты / табличные части |

Формы: `defaultObjectForm`, `defaultListForm`, `defaultChoiceForm`, `auxiliary*` (см. `catalog.md`).
Реквизиты и ТЧ — `attributes.md`. Представления, команды, характеристики, `basedOn`, `standardAttributes`,
`inputByString`, `dataLockFields` — `blocks.md`.

## DocumentJournal (Журнал документов)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `registeredDocuments` | `[]` | документы журнала: `["Document.Встреча", "Document.Звонок"]` |
| `columns` | `[]` | графы журнала (см. ниже) |

Графа — строка `"Имя"` или объект `{ name, synonym, indexing, references }`, где `indexing` — `Index`/`DontIndex`,
`references` — пути к реквизитам документов, отображаемым в графе.

```json
{ "type": "DocumentJournal", "name": "Взаимодействия",
  "registeredDocuments": ["Document.Встреча", "Document.Звонок"],
  "columns": [{ "name": "Организация", "indexing": "Index",
                "references": ["Document.Встреча.Attribute.Организация"] }] }
```

## Sequence (Последовательность документов)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `moveBoundaryOnPosting` | `DontMove` | сдвиг границы при проведении |
| `documents` | `[]` | документы последовательности (список ссылок) |
| `registerRecords` | `[]` | движения (список ссылок) |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `dimensions` | `[]` | измерения `{name, type, documentMap[], registerRecordsMap[]}` |

`documentMap` / `registerRecordsMap` — пути к реквизитам документов / движениям, соответствующим измерению.

## DocumentNumerator (Нумератор документов)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `numberType` | `String` | `String` / `Number` |
| `numberLength` | `11` | длина номера |
| `numberAllowedLength` | `Variable` | `Variable` / `Fixed` |
| `numberPeriodicity` | `Year` | `Nonperiodical` / `Day` / … / `Year` |
| `checkUnique` | `true` | bool |
