# Role DSL — полная справка

Подробная справка по JSON DSL для `/role-compile`. Компактное описание — в [SKILL.md](SKILL.md).

## Структура верхнего уровня

```json
{
  "name": "ИмяРоли",
  "synonym": "Отображаемое имя роли",
  "comment": "",
  "setForNewObjects": false,
  "setForAttributesByDefault": true,
  "independentRightsOfChildObjects": false,
  "objects": [ ... ],
  "templates": [ ... ]
}
```

- `name` — программное имя роли (обязательно)
- `synonym` — отображаемое имя (по умолчанию = name)
- `comment` — комментарий (по умолчанию пусто)
- Глобальные флаги — по умолчанию `false`, `true`, `false`

## Объекты: два формата

Массив `objects` принимает строки (shorthand) и объекты (полная форма).

### Строковый shorthand

```
"ОбъектМетаданных: @пресет"
"ОбъектМетаданных: Право1, Право2"
```

Примеры:
```json
"objects": [
  "Catalog.Номенклатура: @view",
  "Document.Реализация: @edit",
  "InformationRegister.Цены: Read, Update",
  "DataProcessor.Загрузка: @view"
]
```

### Объектная форма (для RLS и переопределений)

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

Для сервисов (WebService, HTTPService, IntegrationService) пресеты не определены — используй явные права: `"WebService.Имя: Use"`.

Если пресет не определён для типа объекта — предупреждение с подсказкой доступных.

## Русские синонимы

Скрипт автоматически транслирует русские имена в английские. Можно смешивать: `"Справочник.Контрагенты: Чтение, View"` — работает.

### Типы объектов

| Русский | English |
|---------|---------|
| `Справочник` | Catalog |
| `Документ` | Document |
| `РегистрСведений` | InformationRegister |
| `РегистрНакопления` | AccumulationRegister |
| `РегистрБухгалтерии` | AccountingRegister |
| `РегистрРасчета` | CalculationRegister |
| `Константа` | Constant |
| `ПланСчетов` | ChartOfAccounts |
| `ПланВидовХарактеристик` | ChartOfCharacteristicTypes |
| `ПланВидовРасчета` | ChartOfCalculationTypes |
| `ПланОбмена` | ExchangePlan |
| `БизнесПроцесс` | BusinessProcess |
| `Задача` | Task |
| `Обработка` | DataProcessor |
| `Отчет` | Report |
| `ОбщаяФорма` | CommonForm |
| `ОбщаяКоманда` | CommonCommand |
| `Подсистема` | Subsystem |
| `КритерийОтбора` | FilterCriterion |
| `ЖурналДокументов` | DocumentJournal |
| `Последовательность` | Sequence |
| `ВебСервис` | WebService |
| `HTTPСервис` | HTTPService |
| `СервисИнтеграции` | IntegrationService |
| `ПараметрСеанса` | SessionParameter |
| `ОбщийРеквизит` | CommonAttribute |
| `Конфигурация` | Configuration |
| `Перечисление` | Enum |

### Вложенные типы

| Русский | English |
|---------|---------|
| `Реквизит` | Attribute |
| `СтандартныйРеквизит` | StandardAttribute |
| `ТабличнаяЧасть` | TabularSection |
| `Измерение` | Dimension |
| `Ресурс` | Resource |
| `Команда` | Command |
| `РеквизитАдресации` | AddressingAttribute |

### Права (основные)

| Русский | English |
|---------|---------|
| `Чтение` | Read |
| `Добавление` | Insert |
| `Изменение` | Update |
| `Удаление` | Delete |
| `Просмотр` | View |
| `Редактирование` | Edit |
| `ВводПоСтроке` | InputByString |
| `Проведение` | Posting |
| `ОтменаПроведения` | UndoPosting |
| `Использование` | Use |
| `Получение` | Get |
| `Установка` | Set |
| `Старт` | Start |
| `Выполнение` | Execute |
| `УправлениеИтогами` | TotalsControl |

### Права (интерактивные)

| Русский | English |
|---------|---------|
| `ИнтерактивноеДобавление` | InteractiveInsert |
| `ИнтерактивнаяПометкаУдаления` | InteractiveSetDeletionMark |
| `ИнтерактивноеСнятиеПометкиУдаления` | InteractiveClearDeletionMark |
| `ИнтерактивноеУдаление` | InteractiveDelete |
| `ИнтерактивноеУдалениеПомеченных` | InteractiveDeleteMarked |
| `ИнтерактивноеПроведение` | InteractivePosting |
| `ИнтерактивноеПроведениеНеоперативное` | InteractivePostingRegular |
| `ИнтерактивнаяОтменаПроведения` | InteractiveUndoPosting |
| `ИнтерактивноеИзменениеПроведенных` | InteractiveChangeOfPosted |
| `ИнтерактивныйСтарт` | InteractiveStart |
| `ИнтерактивнаяАктивация` | InteractiveActivate |
| `ИнтерактивноеВыполнение` | InteractiveExecute |

### Права (конфигурация)

| Русский | English |
|---------|---------|
| `Администрирование` | Administration |
| `АдминистрированиеДанных` | DataAdministration |
| `ТонкийКлиент` | ThinClient |
| `ТолстыйКлиент` | ThickClient |
| `ВебКлиент` | WebClient |
| `МобильныйКлиент` | MobileClient |
| `ВнешнееСоединение` | ExternalConnection |
| `Вывод` | Output |
| `СохранениеДанныхПользователя` | SaveUserData |

## Типы объектов без прав в ролях

Следующие типы 1С **не могут** иметь права в ролях (не добавляются в `objects`):

| Тип | Причина |
|-----|---------|
| Enum (Перечисление) | Права наследуются от конфигурации, явное назначение невозможно |
| CommonModule (ОбщийМодуль) | Не имеет собственных прав в роли |
| DefinedType (ОпределяемыйТип) | Тип данных, не объект прав |
| CommonPicture (ОбщаяКартинка) | Ресурс, не объект прав |
| CommonTemplate (ОбщийМакет) | Ресурс, не объект прав |
| Language (Язык) | Конфигурационный элемент |
| FunctionalOption (ФункциональнаяОпция) | Не объект прав |
| FunctionalOptionsParameter | Не объект прав |
| EventSubscription (ПодпискаНаСобытие) | Не объект прав |
| ScheduledJob (РегламентноеЗадание) | Не объект прав |
| StyleItem (ЭлементСтиля) | Ресурс оформления |

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

### 1. Простая роль (только пресеты)

```json
{
  "name": "ЧтениеНоменклатуры",
  "synonym": "Чтение номенклатуры",
  "objects": [
    "Catalog.Номенклатура: @view",
    "Catalog.Контрагенты: @view",
    "DataProcessor.Загрузка: @view"
  ]
}
```

### 2. Роль для регламентного задания

```json
{
  "name": "ОбновлениеЦен",
  "synonym": "Обновление цен номенклатуры",
  "objects": [
    "Catalog.Номенклатура: Read",
    "Catalog.Валюты: Read",
    "InformationRegister.ЦеныНоменклатуры: Read, Update",
    "Constant.ОсновнаяВалюта: Read"
  ]
}
```

### 3. Роль с RLS

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

### 4. Роль с русскими синонимами

```json
{
  "name": "ПросмотрДанных",
  "synonym": "Просмотр данных",
  "objects": [
    "Справочник.Контрагенты: @view",
    "Документ.Реализация: Чтение, Просмотр",
    "РегистрСведений.Цены: @edit",
    "Обработка.ЗагрузкаДанных: @view"
  ]
}
```

### 5. Роль с переопределением прав из пресета

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
