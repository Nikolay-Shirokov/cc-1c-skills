# ExternalDataSource (внешний источник данных)

Источник описывается **одним JSON целиком**: сам источник, его таблицы с полями и функции.
Результат — `ExternalDataSources/<Имя>.xml` плюс по файлу на таблицу в `<Имя>/Tables/`.

Строку соединения, пользователя, пароль и тип СУБД задавать не нужно: в конфигурации их нет,
они настраиваются в режиме «Предприятие» и хранятся в базе.

```json
{
  "type": "ExternalDataSource",
  "name": "PG",
  "tables": {
    "prices": ["product_id: Number(10,0)", "period: Date", "price: Number(15,2)"],
    "products": {
      "nameInDataSource": "eds.public.products",
      "tableDataType": "ObjectData",
      "keyFields": ["id"],
      "presentationField": "name",
      "fields": [
        "id: Number(10,0)",
        "name: String(150)",
        "article: String(50) | nullable",
        "parent_id: ExternalDataSourceTableRef.PG.products | nullable"
      ]
    }
  },
  "functions": {
    "total": { "expression": "public.f_total(&1, &2)", "returns": "Number(15,2)" }
  }
}
```

## Свойства источника

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `dataLockControlMode` | `Automatic` | `Automatic` / `Managed` / `AutomaticAndManaged` |
| `tables` | `{}` | таблицы (см. ниже) |
| `functions` | `{}` | функции (см. ниже) |

При `AutomaticAndManaged` режим блокировок решает каждая таблица сама; при конкретном значении
одноимённое свойство таблицы игнорируется платформой.

## Таблицы

Ключ — имя таблицы в конфигурации. Значение — **массив полей** либо **объект** со свойствами
и ключом `fields` (та же двойственность, что у `tabularSections` справочника).

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `nameInDataSource` | = имя таблицы | имя физической таблицы; для реляционной СУБД обычно `<база>.<схема>.<таблица>` |
| `tableType` | `Table` | `Table` — таблица или представление; `Expression` — табличная функция |
| `readOnly` | `false` | запрет записи; ставь `true` для представлений и таблиц вида `Expression` — писать в них нельзя |
| `expressionInDataSource` | пусто | выражение для `Expression`, напр. `public.f_by_parent(&1)`; имя базы не указывается |
| `tableDataType` | `NonobjectData` | `ObjectData` (запись определяется одним полем) / `NonobjectData` |
| `keyFields` | `[]` | имена ключевых полей; без них таблица собирается, но недоступны форма записи и набор записей |
| `presentationField` | пусто | имя поля представления (только `ObjectData`) |
| `parentField` | пусто | имя поля родителя; его тип должен быть ссылкой на эту же таблицу |
| `inputByString` | `[]` | имена полей ввода по строке; ключа нет → берётся `presentationField` |
| `dataVersionField` | пусто | имя поля версии данных |
| `dataLockFields` | `[]` | имена полей блокировки |
| `transactionsIsolationLevel` | `Auto` | `Auto` / `ReadUncommitted` / `ReadCommitted` / `RepeatableRead` / `Serializable` |
| `dataLockControlMode` | `Automatic` | `Automatic` / `Managed` / `AutomaticAndManaged` |
| `basedOn` | `[]` | ввод на основании, ссылки вида `Catalog.Контрагенты` |
| `useStandardCommands` | `true` | bool |
| `quickChoice` | `false` | bool |
| `editType` | `InDialog` | `InDialog` / `InList` |
| `fields` | `[]` | поля (см. ниже); синоним — `columns` |

Ссылки на поля (`keyFields`, `presentationField`, `parentField`, `dataVersionField`,
`inputByString`, `dataLockFields`) задаются **короткими именами полей** этой же таблицы.

Прочие свойства — представления (`objectPresentation`, `listPresentation`, …), формы по умолчанию
(`defaultObjectForm`, `defaultListForm`, …), `characteristics`, `explanation`,
`includeHelpInContents` — как у справочника.

**Значение незаполненного родителя загрузкой XML не задаётся** — платформа сбрасывает его в пустое
при любой загрузке, включая загрузку собственной выгрузки. Ставится только в Конфигураторе вручную.

## Поля

Строковая и объектная форма — те же, что у реквизитов (см. `attributes.md`). Своих ключа три:

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `nameInDataSource` | = имя поля | имя колонки; в одинарных кавычках уходит в SQL как есть |
| `readOnly` | `false` | поле не записывается (вычисляемые, автоинкрементные) |
| `allowNull` | `false` | допускает `NULL` |

Флаги строковой формы: `readonly`, `nullable`.

```json
"fields": [
  "id: Number(10,0) | readonly",
  { "name": "article", "type": "String(50)", "nameInDataSource": "art_code", "allowNull": true }
]
```

Допустимые типы: `Number`, `String`, `Date`, `Boolean`, `UUID`, `BinaryData` и ссылка на таблицу
внешнего источника — `ExternalDataSourceTableRef.<Источник>.<Таблица>`.

**Составной тип у поля недопустим** — платформа такую конфигурацию не загружает.

## Функции

Ключ — имя функции. Значение — строка (интерпретируется как `expression`) либо объект.

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `expression` | — | выражение в источнике, обязательный |
| `returns` | `String` | тип возвращаемого значения |
| `returnValue` | `true` | `false` — процедура, тип не пишется |

Параметры описываются прямо в выражении как `&1`, `&2` — отдельного ключа для них нет.
Необязательные — в фигурных скобках `f(&1{, &2})`, переменное число — `&n[]` (только последним).

```json
"functions": {
  "nextKey": "NEXT VALUE FOR dbo.SimpleSequence",
  "total": { "expression": "public.f_total(&1, &2)", "returns": "Number(15,2)" }
}
```

## Не поддерживается

- **Кубы OLAP** (`Cube`, `DimensionTable`, `Dimension`, `Resource`).
- **Формы и модули** таблиц — формы добавляют `form-add` и `form-compile`.
