# Свойства объекта и свойства-списки

Справочник операций для обычных свойств объекта и свойств-списков (Owners, RegisterRecords, BasedOn, InputByString).

## modify-property

Изменение свойств объекта по имени свойства 1С (PascalCase, как в конфигураторе). Формат: `Ключ=Значение`
(batch через `;;`):
```powershell
-Operation modify-property -Value "CodeLength=11 ;; DescriptionLength=150"
-Operation modify-property -Value "Hierarchical=true"
```

Свойство можно задать, даже если оно ещё не выставлено у объекта (например `FullTextSearch`, `DataHistory`).
Опечатка в имени свойства → ошибка (правка не теряется молча). Допустимы имена свойств соответствующего типа объекта.

### Type — тип значения (Константа, ПВХ)

`Type=...` перестраивает дескриптор типа значения. Значение — тип 1С в том же синтаксисе,
что у реквизитов: составной через `+`, с квалификаторами и ссылочными типами:
```powershell
-Operation modify-property -Value "Type=String(100) + Number(15,2) + CatalogRef.Номенклатура"
```
Структурные свойства (со вложенными узлами) в скалярный текст не превращаются: попытка задать
такое свойство обычным `Ключ=Значение` (кроме `Type`) завершается ошибкой до записи файла.

## Свойства-списки

Свойства, значение которых — список ссылок. Управляются через inline `add-*` / `remove-*` / `set-*` и через JSON `modify.properties`.

| Свойство | Объекты | Inline-значение |
|----------|---------|-----------------|
| Owners | Catalog, ChartOfCharacteristicTypes | `Catalog.XXX` |
| RegisterRecords | Document | `AccumulationRegister.XXX` |
| BasedOn | Document, Catalog, BP, Task | `Document.XXX` |
| InputByString | Catalog, ChartOf*, Task | `StandardAttribute.Description` |
| DataLockFields | Catalog, Document, регистры и др. | `Организация` (короткое имя реквизита → полный путь) |
| RegisteredDocuments | DocumentJournal | `Document.XXX` |

### add-owner / add-registerRecord / add-basedOn / add-registeredDocument

Полное имя метаданных `MetaType.Name`:
```powershell
-Operation add-owner -Value "Catalog.Контрагенты ;; Catalog.Организации"
-Operation add-registerRecord -Value "AccumulationRegister.ОстаткиТоваров"
-Operation add-basedOn -Value "Document.ЗаказКлиента"
-Operation add-registeredDocument -Value "Document.РасходныйОрдер"
```

### add-inputByString / add-dataLockField

Пути полей (короткое имя реквизита разворачивается в полный путь автоматически):
```powershell
-Operation add-inputByString -Value "StandardAttribute.Description ;; StandardAttribute.Code"
-Operation add-dataLockField -Value "Организация ;; Контрагент"
```

### remove-owner / remove-registerRecord / remove-basedOn / remove-inputByString / remove-dataLockField / remove-registeredDocument

```powershell
-Operation remove-owner -Value "Catalog.Контрагенты"
-Operation remove-inputByString -Value "Catalog.МойСпр.StandardAttribute.Code"
-Operation remove-dataLockField -Value "Организация"
```

### set-owners / set-registerRecords / set-basedOn / set-inputByString / set-dataLockFields / set-registeredDocuments

Заменяют **весь список** (в отличие от add/remove):
```powershell
-Operation set-owners -Value "Catalog.Организации ;; Catalog.Контрагенты"
-Operation set-registerRecords -Value "AccumulationRegister.Продажи ;; AccumulationRegister.ОстаткиТоваров"
-Operation set-inputByString -Value "StandardAttribute.Description ;; StandardAttribute.Code"
```
