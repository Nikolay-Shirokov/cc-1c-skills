# Процессы и сервисные: BusinessProcess, Task, ExchangePlan, CommonModule, ScheduledJob, EventSubscription, DocumentJournal

## BusinessProcess

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `task` | `""` | Task (ссылка `Task.XXX`) |
| `numberType` | `String` | NumberType |
| `numberLength` | `11` | NumberLength |
| `checkUnique` | `true` | CheckUnique |
| `autonumbering` | `true` | Autonumbering |
| `attributes` | `[]` | → Attribute |
| `tabularSections` | `{}` | → TabularSection |

Модули: `Ext/ObjectModule.bsl`, `Ext/Flowchart.xml`.

```json
{ "type": "BusinessProcess", "name": "Задание", "task": "Task.ЗадачаИсполнителя", "attributes": ["Описание: String(200)"] }
```

## Task

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `numberType` | `String` | NumberType |
| `numberLength` | `14` | NumberLength |
| `checkUnique` | `true` | CheckUnique |
| `autonumbering` | `true` | Autonumbering |
| `descriptionLength` | `150` | DescriptionLength |
| `addressing` | `""` | Addressing (ссылка на РС адресации) |
| `mainAddressingAttribute` | `""` | MainAddressingAttribute |
| `currentPerformer` | `""` | CurrentPerformer |
| `attributes` | `[]` | → Attribute |
| `tabularSections` | `{}` | → TabularSection |
| `addressingAttributes` | `[]` | → AddressingAttribute (shorthand или объект) |

AddressingAttribute — shorthand `"Имя: Тип"` или объект `{ "name", "type", "addressingDimension" }`.

```json
{
  "type": "Task", "name": "ЗадачаИсполнителя",
  "addressingAttributes": ["Исполнитель: CatalogRef.Пользователи"]
}
```

## ExchangePlan

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `codeLength` | `9` | CodeLength |
| `descriptionLength` | `100` | DescriptionLength |
| `distributedInfoBase` | `false` | DistributedInfoBase |
| `attributes` | `[]` | → Attribute |
| `tabularSections` | `{}` | → TabularSection |

Модули: `Ext/ObjectModule.bsl`, `Ext/Content.xml`.

```json
{ "type": "ExchangePlan", "name": "ОбменССайтом", "attributes": ["АдресСервера: String(200)"] }
```

## CommonModule

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `context` | — | Шорткат (см. ниже) |
| `global` | `false` | Global |
| `server` | `false` | Server |
| `serverCall` | `false` | ServerCall |
| `clientManagedApplication` | `false` | ClientManagedApplication |
| `externalConnection` | `false` | ExternalConnection |
| `privileged` | `false` | Privileged |
| `returnValuesReuse` | `DontUse` | ReturnValuesReuse |

Шорткаты `context`: `"server"` → Server+ServerCall, `"client"` → ClientManagedApplication, `"serverClient"` → Server+ClientManagedApplication.

```json
{ "type": "CommonModule", "name": "ОбщиеФункции", "context": "serverClient" }
```

## ScheduledJob

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `methodName` | `""` | MethodName |
| `description` | = synonym | Description |
| `use` | `false` | Use |
| `predefined` | `false` | Predefined |
| `restartCountOnFailure` | `3` | RestartCountOnFailure |
| `restartIntervalOnFailure` | `10` | RestartIntervalOnFailure |

Формат `methodName`: `"МодульСервер.Процедура"` — авто-дополняется до `CommonModule.МодульСервер.Процедура`.

```json
{ "type": "ScheduledJob", "name": "ОбменДанными", "methodName": "ОбменДаннымиСервер.Выполнить" }
```

## EventSubscription

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `source` | `[]` | Source (массив, формат `XxxObject.Name`) |
| `event` | `BeforeWrite` | Event |
| `handler` | `""` | Handler |

Формат `handler`: `"МодульСервер.Процедура"` — авто-дополняется до `CommonModule.МодульСервер.Процедура`.

Значения `event`: `BeforeWrite`, `OnWrite`, `BeforeDelete`, `OnReadAtServer`, `FillCheckProcessing`.

Формат `source`: `"CatalogObject.Xxx"`, `"DocumentObject.Xxx"`.

```json
{ "type": "EventSubscription", "name": "ПередЗаписью", "source": ["CatalogObject.Контрагенты"], "event": "BeforeWrite", "handler": "ОбщиеФункции.ПередЗаписью" }
```

## DocumentJournal

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `registeredDocuments` | `[]` | RegisteredDocuments (массив `"Document.Xxx"`) |
| `columns` | `[]` | → Column |

Колонки — строка `"Имя"` или объект `{ "name", "synonym", "indexing": "Index"/"DontIndex", "references": ["Document.Xxx.Attribute.Yyy"] }`.

```json
{
  "type": "DocumentJournal", "name": "Взаимодействия",
  "registeredDocuments": ["Document.Встреча", "Document.Звонок"],
  "columns": [{ "name": "Организация", "indexing": "Index", "references": ["Document.Встреча.Attribute.Организация"] }]
}
```

## Зависимости

- **ScheduledJob/EventSubscription** — процедура-обработчик должна существовать в модуле (экспортная)
- **BusinessProcess** → `Task` (задача должна существовать)
