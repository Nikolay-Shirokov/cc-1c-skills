# BusinessProcess, Task (Бизнес-процессы и Задачи)

Ссылочные типы. Наследуют слой Catalog (нумерация, формы, `standardAttributes`, `characteristics`, `basedOn`,
представления — см. `catalog.md` / `attributes.md` / `blocks.md`). Бизнес-процесс всегда связан с задачей.

## BusinessProcess (Бизнес-процесс)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `task` | пусто | ссылка на задачу `Task.X` (обязательна для рабочего БП) |
| `numberType` | `String` | `String` / `Number` |
| `numberLength` | `11` | длина номера |
| `checkUnique` | `true` | bool |
| `autonumbering` | `true` | bool |
| `createOnInput` | `DontUse` | `Auto` / `Use` / `DontUse` |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `attributes` / `tabularSections` | `[]` / `{}` | реквизиты / табличные части |

Создаётся с картой маршрута (`Ext/Flowchart.xml`) и модулем объекта.

```json
{ "type": "BusinessProcess", "name": "Согласование", "task": "Task.ЗадачаИсполнителя",
  "attributes": ["Документ: DocumentRef.ЗаявкаНаРасход"] }
```

## Task (Задача)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `numberType` | `String` | `String` / `Number` |
| `numberLength` | `14` | длина номера |
| `checkUnique` | `true` | bool |
| `autonumbering` | `true` | bool |
| `descriptionLength` | `150` | длина наименования |
| `addressing` | пусто | ссылка на регистр сведений адресации `InformationRegister.X` |
| `mainAddressingAttribute` | пусто | основной реквизит адресации (имя реквизита адресации) |
| `currentPerformer` | пусто | реквизит текущего исполнителя |
| `createOnInput` | `DontUse` | `Auto` / `Use` / `DontUse` |
| `dataLockControlMode` | `Managed` | `Automatic` / `Managed` |
| `addressingAttributes` | `[]` | реквизиты адресации (см. ниже) |
| `attributes` / `tabularSections` | `[]` / `{}` | реквизиты / табличные части |

**Реквизит адресации** — shorthand `"Имя: Тип"` или объект `{ name, type, addressingDimension }`
(`addressingDimension` — измерение регистра адресации).

```json
{ "type": "Task", "name": "ЗадачаИсполнителя",
  "addressingAttributes": ["Исполнитель: CatalogRef.Пользователи", "Роль: CatalogRef.Роли"] }
```
