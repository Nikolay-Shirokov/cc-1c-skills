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

## Свойства-списки

Свойства, значение которых — список ссылок. Управляются через inline `add-*` / `remove-*` / `set-*` и через JSON `modify.properties`.

| Свойство | Объекты | Inline-значение |
|----------|---------|-----------------|
| Owners | Catalog, ChartOfCharacteristicTypes | `Catalog.XXX` |
| RegisterRecords | Document | `AccumulationRegister.XXX` |
| BasedOn | Document, Catalog, BP, Task | `Document.XXX` |
| InputByString | Catalog, ChartOf*, Task | `StandardAttribute.Description` |

### add-owner / add-registerRecord / add-basedOn

Полное имя метаданных `MetaType.Name`:
```powershell
-Operation add-owner -Value "Catalog.Контрагенты ;; Catalog.Организации"
-Operation add-registerRecord -Value "AccumulationRegister.ОстаткиТоваров"
-Operation add-basedOn -Value "Document.ЗаказКлиента"
```

### add-inputByString

Пути полей (префикс `MetaType.Name.` добавляется автоматически):
```powershell
-Operation add-inputByString -Value "StandardAttribute.Description ;; StandardAttribute.Code"
```

### remove-owner / remove-registerRecord / remove-basedOn / remove-inputByString

```powershell
-Operation remove-owner -Value "Catalog.Контрагенты"
-Operation remove-inputByString -Value "Catalog.МойСпр.StandardAttribute.Code"
```

### set-owners / set-registerRecords / set-basedOn / set-inputByString

Заменяют **весь список** (в отличие от add/remove):
```powershell
-Operation set-owners -Value "Catalog.Организации ;; Catalog.Контрагенты"
-Operation set-registerRecords -Value "AccumulationRegister.Продажи ;; AccumulationRegister.ОстаткиТоваров"
-Operation set-inputByString -Value "StandardAttribute.Description ;; StandardAttribute.Code"
```
