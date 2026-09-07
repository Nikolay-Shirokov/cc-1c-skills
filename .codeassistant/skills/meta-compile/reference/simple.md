# Enum, Constant, DefinedType

## Enum (Перечисление)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `values` | `[]` | значения перечисления (массив имён или объектов) |

Значение — строка `"ИмяЗначения"` или объект `{ name, synonym }`.

```json
{ "type": "Enum", "name": "Статусы", "values": ["Новый", "ВРаботе", "Закрыт"] }
```

## Constant (Константа)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `valueType` | `String` | тип значения (shorthand типа) |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |

`valueType` принимает shorthand: `"String(100)"`, `"Number(15,2)"`, `"Boolean"`, `"CatalogRef.Валюты"`,
составной через `+`.

```json
{ "type": "Constant", "name": "ОсновнаяВалюта", "valueType": "CatalogRef.Валюты" }
```

## DefinedType (Определяемый тип)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `valueTypes` | `[]` | состав типа (массив shorthand-типов) |
| `valueType` | — | то же одной строкой (`"A + B"`) или строкой одного типа |

```json
{ "type": "DefinedType", "name": "ДенежныеСредства",
  "valueTypes": ["CatalogRef.БанковскиеСчета", "CatalogRef.Кассы"] }
{ "type": "DefinedType", "name": "ФлагАктивности", "valueType": "Boolean" }
```
