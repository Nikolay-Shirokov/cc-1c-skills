# Role DSL — полная справка

Подробная справка по JSON DSL для `/role-compile`. Компактное описание — в [SKILL.md](SKILL.md).

## Какие объекты можно писать в `objects`

Права в роли имеют ровно 27 типов. Тип вне этого списка — ошибка компиляции: роль не
создаётся, файлы не пишутся.

| Тип | Права |
|-----|-------|
| `Configuration` | Administration, DataAdministration, UpdateDataBaseConfiguration, ConfigurationExtensionsAdministration, ActiveUsers, EventLog, ExclusiveMode, ThinClient, ThickClient, WebClient, MobileClient, ExternalConnection, Automation, Output, SaveUserData, TechnicalSpecialistMode, InteractiveOpenExtDataProcessors, InteractiveOpenExtReports, AnalyticsSystemClient, CollaborationSystemInfoBaseRegistration, MainWindowModeNormal, MainWindowModeWorkplace, MainWindowModeEmbeddedWorkplace, MainWindowModeFullscreenWorkplace, MainWindowModeKiosk |
| `Catalog`, `ChartOfCharacteristicTypes` | Read, Insert, Update, Delete, View, Edit, InputByString, Interactive* (Insert, SetDeletionMark, ClearDeletionMark, Delete, DeleteMarked), *PredefinedData, *DataHistory* |
| `Document` | то же + Posting, UndoPosting, InteractivePosting, InteractivePostingRegular, InteractiveUndoPosting, InteractiveChangeOfPosted |
| `ChartOfAccounts`, `ChartOfCalculationTypes`, `ExchangePlan` | Read, Insert, Update, Delete, View, Edit, InputByString, Interactive*, *DataHistory* (без InteractiveDeleteMarked у ChartOfAccounts) |
| `BusinessProcess` | Read, Insert, Update, Delete, View, Edit, InputByString, Start, InteractiveInsert, InteractiveSetDeletionMark, InteractiveClearDeletionMark, InteractiveDelete, InteractiveActivate, InteractiveStart |
| `Task` | то же, но вместо Start/InteractiveStart — Execute, InteractiveExecute |
| `InformationRegister` | Read, Update, View, Edit, TotalsControl, *DataHistory* |
| `AccumulationRegister`, `AccountingRegister` | Read, Update, View, Edit, TotalsControl |
| `CalculationRegister` | Read, View |
| `Constant` | Read, Update, View, Edit, *DataHistory* |
| `DocumentJournal` | Read, View |
| `Sequence` | Read, Update |
| `DataProcessor`, `Report` | Use, View |
| `WebService`, `HTTPService`, `IntegrationService` | — права только на вложенных объектах, см. ниже |
| `CommonForm`, `CommonCommand`, `Subsystem`, `FilterCriterion` | View |
| `CommonAttribute` | View, Edit |
| `SessionParameter` | Get, Set |
| `ExternalDataSource` | Use, Administration, StandardAuthenticationChange, SessionStandardAuthenticationChange, SessionOSAuthenticationChange |

Полные списки прав по каждому типу — в коде навыка (`scripts/role-compile.ps1`,
таблица `$knownRights`); навык проверяет каждое имя права и отвергает несуществующее.

### Вложенные объекты

Путь длиннее двух сегментов задаёт права на часть объекта. Вид вложенности —
предпоследний сегмент, он определяет набор прав.

| Вид | Права |
|-----|-------|
| `Attribute`, `StandardAttribute`, `TabularSection`, `StandardTabularSection`, `Dimension`, `Resource`, `AccountingFlag`, `ExtDimensionAccountingFlag`, `AddressingAttribute` | View, Edit |
| `Command`, вложенная `Subsystem` | View |
| `Operation` (веб-сервис), `Method` (HTTP-сервис, под `URLTemplate`), `IntegrationServiceChannel` | Use |
| `Recalculation` (регистр расчёта) | Read, Update |

Виды `Operation`, `Method`, `IntegrationServiceChannel`, `Recalculation` и виды внешнего
источника допустимы только у своего типа-родителя. Графы журнала документов
(`DocumentJournal.Ж.Column.Г`) собственных прав не имеют.

Примеры: `Catalog.Контрагенты.Attribute.ИНН: View, Edit`,
`Document.Реализация.TabularSection.Товары.Attribute.Цена: View`,
`WebService.Обмен.Operation.Загрузить: Use`,
`HTTPService.API.URLTemplate.Файлы.Method.Получить: Use`.

Сегмент после `Method.` — **имя объекта Method в дереве метаданных**, а не HTTP-глагол:
встречаются и `Method.GET`, и `Method.Установить`, и `Method.СоздатьПодключение`.

Про короткую запись `HTTPService.API: Use` — раздел «Сервисы» в `SKILL.md`.

### Вложенные объекты внешнего источника данных

Виды `Table`, `Cube`, `Function`, `Field`, `DimensionTable` бывают **только** под
`ExternalDataSource`.

| Путь | Права |
|------|-------|
| `ExternalDataSource.И.Table.Т` | Read, Insert, Update, Delete, View, Edit, InputByString, InteractiveInsert, InteractiveDelete |
| `ExternalDataSource.И.Table.Т.Field.П` | View, Edit |
| `ExternalDataSource.И.Cube.К` | Read, View |
| `ExternalDataSource.И.Cube.К.Dimension.И`, `…Resource.Р` | View |
| `ExternalDataSource.И.Cube.К.DimensionTable.Т` | Read, View |
| `ExternalDataSource.И.Cube.К.DimensionTable.Т.Field.П` | View, Edit |
| `ExternalDataSource.И.Function.Ф` | Use, View |
| `…Table.Т.Command.К`, `…Cube.К.Command.К`, `…DimensionTable.Т.Command.К` | View |

### Типы объектов без прав в ролях

Права нельзя назначить на `Enum`, `CommonModule`, `DefinedType`, `CommonPicture`,
`CommonTemplate`, `Language`, `FunctionalOption`, `FunctionalOptionsParameter`,
`EventSubscription`, `ScheduledJob`, `StyleItem`, `Style`, `SettingsStorage`,
`XDTOPackage`, `WSReference`, `DocumentNumerator` — в дереве редактора ролей этих типов нет.

Попытка — ошибка компиляции. Права на перечисления особенно опасны: конфигурация с таким
блоком не загружается в информационную базу, конфигуратор зависает без сообщений.

## Формат записи объектов

Массив `objects` принимает строки (shorthand) и объекты (полная форма).

```json
{
  "name": "Document.Реализация",
  "preset": "view",
  "rights": { "Delete": false },
  "rls": { "Read": "#ДляОбъекта(\"\")" }
}
```

- `preset` — базовый набор прав (`"view"`, `"edit"`)
- `rights` — переопределения: dict `{"Right": true/false}` или массив `["Right1", "Right2"]`
- `rls` — RLS-ограничения: `{"ИмяПрава": "текст условия"}`

Русские имена типов и прав тоже принимаются (`Справочник.Контрагенты: Чтение`), каноничная
форма — английская.

## Пресеты — подробные таблицы

Пресеты обозначаются `@` в строковом формате. В объектной форме ключ `preset` без `@`.

### `@view` — просмотр

| Тип объекта | Права |
|-------------|-------|
| Catalog, ExchangePlan, Document, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes, BusinessProcess, Task | Read, View, InputByString |
| InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister, Constant, DocumentJournal | Read, View |
| Sequence | Read |
| CommonForm, CommonCommand, Subsystem, FilterCriterion, CommonAttribute | View |
| DataProcessor, Report | Use, View |
| SessionParameter | Get |
| Configuration | ThinClient, WebClient, Output, SaveUserData, MainWindowModeNormal |

### `@edit` — полное редактирование

| Тип объекта | Права |
|-------------|-------|
| Catalog, ExchangePlan, ChartOfAccounts, ChartOfCharacteristicTypes, ChartOfCalculationTypes | Read, Insert, Update, Delete, View, Edit, InputByString, InteractiveInsert, InteractiveSetDeletionMark, InteractiveClearDeletionMark |
| Document | Read, Insert, Update, Delete, View, Edit, InputByString, Posting, UndoPosting, InteractiveInsert, InteractiveSetDeletionMark, InteractiveClearDeletionMark, InteractivePosting, InteractivePostingRegular, InteractiveUndoPosting, InteractiveChangeOfPosted |
| BusinessProcess | Read, Insert, Update, Delete, View, Edit, InputByString, Start, InteractiveInsert, InteractiveSetDeletionMark, InteractiveClearDeletionMark, InteractiveActivate, InteractiveStart |
| Task | Read, Insert, Update, Delete, View, Edit, InputByString, Execute, InteractiveInsert, InteractiveSetDeletionMark, InteractiveClearDeletionMark, InteractiveActivate, InteractiveExecute |
| InformationRegister, AccumulationRegister, AccountingRegister, Constant | Read, Update, View, Edit |
| DocumentJournal | Read, View |
| Sequence | Read, Update |
| SessionParameter | Get, Set |
| CommonAttribute | View, Edit |

Для сервисов (WebService, HTTPService, IntegrationService) и внешних источников данных
пресеты не определены — задавай права явно: `"WebService.Обмен.Operation.Загрузить: Use"`.

## Шаблоны ограничений (RLS templates)

```json
"templates": [
  {
    "name": "ДляОбъекта(Модификатор)",
    "condition": "// текст шаблона\nГДЕ 1=1\n&Модификатор"
  }
]
```

- `&` в условии автоматически экранируется в `&amp;` в XML
- Ссылка на шаблон в `rls`: `"#ИмяШаблона(\"параметры\")"` — начинается с `#`
- Параметры шаблона можно передавать пустыми: `#ДляОбъекта("")`

## Примеры

### Роль с RLS

```json
{
  "name": "ЧтениеДокументовПоОрганизации",
  "synonym": "Чтение документов (ограничение по организации)",
  "objects": [
    "Catalog.Организации: @view",
    {
      "name": "Document.РеализацияТоваровУслуг",
      "preset": "view",
      "rls": {
        "Read": "#ДляОбъекта(\"\")"
      }
    }
  ],
  "templates": [
    {
      "name": "ДляОбъекта(Модификатор)",
      "condition": "ГДЕ Организация = &ТекущаяОрганизация"
    }
  ]
}
```

### Роль с переопределением прав из пресета

```json
{
  "name": "ОграниченноеРедактирование",
  "synonym": "Редактирование без удаления",
  "objects": [
    {
      "name": "Catalog.Контрагенты",
      "preset": "edit",
      "rights": { "Delete": false }
    }
  ]
}
```

### Роль с правами на части объекта

```json
{
  "name": "МенеджерБезЦен",
  "synonym": "Менеджер без доступа к ценам",
  "objects": [
    "Catalog.Номенклатура: @view",
    { "name": "Catalog.Номенклатура.Attribute.Цена", "rights": { "View": false, "Edit": false } }
  ]
}
```
