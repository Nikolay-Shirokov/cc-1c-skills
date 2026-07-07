# Meta DSL — спецификация JSON-формата для объектов метаданных 1С

## Обзор

JSON DSL для описания объектов метаданных конфигурации 1С. Компактный формат компилируется в полноценный XML, совместимый с выгрузкой конфигурации 1С:Предприятие 8.3.

Поддерживаемые типы (23): **Catalog**, **Document**, **Enum**, **Constant**, **InformationRegister**, **AccumulationRegister**, **AccountingRegister**, **CalculationRegister**, **ChartOfAccounts**, **ChartOfCharacteristicTypes**, **ChartOfCalculationTypes**, **BusinessProcess**, **Task**, **ExchangePlan**, **DocumentJournal**, **Report**, **DataProcessor**, **CommonModule**, **ScheduledJob**, **EventSubscription**, **HTTPService**, **WebService**, **DefinedType**.

---

## 1. Корневая структура

```json
{
  "type": "Catalog",
  "name": "Номенклатура",
  "synonym": "авто из name",
  "comment": "",
  ...type-specific properties...,
  "attributes": [...],
  "tabularSections": {...}
}
```

| Поле | Тип | Обязательное | Описание |
|------|-----|-------------|----------|
| `type` | string | да | Тип объекта (см. §8) |
| `name` | string | да | Имя объекта (идентификатор 1С) |
| `synonym` | string | нет | Синоним; если не указан — авто из CamelCase (§2) |
| `comment` | string | нет | Комментарий |

Дополнительные поля зависят от типа (§7).

---

## 2. Автогенерация синонима (CamelCase → слова)

Если `synonym` не указан, имя автоматически разбивается на слова:

| Вход | Результат |
|------|-----------|
| `АвансовыйОтчет` | `Авансовый отчет` |
| `ОсновнаяВалюта` | `Основная валюта` |
| `НДС20` | `НДС20` |
| `IncomingDocument` | `Incoming document` |

Правила:
- Граница на переходе `[а-яё][А-ЯЁ]` и `[a-z][A-Z]`
- Первое слово сохраняет заглавную, остальные — строчные
- Явный `synonym` перекрывает автогенерацию

---

## 3. Система типов

Совместима с skd-compile.

### 3.1 Примитивные типы

| DSL | XML |
|-----|-----|
| `String` или `String(100)` | `xs:string` + StringQualifiers (AllowedLength=Variable) |
| `String(100,fixed)` | `xs:string` + AllowedLength=Fixed (строка фикс. длины) |
| `Number(15,2)` | `xs:decimal` + NumberQualifiers |
| `Number(10,0,nonneg)` | `xs:decimal` + AllowedSign=Nonnegative |
| `Boolean` | `xs:boolean` |
| `Date` | `xs:dateTime` + DateFractions=Date |
| `DateTime` | `xs:dateTime` + DateFractions=DateTime |
| `Time` | `xs:dateTime` + DateFractions=Time (только время) |
| `ValueStorage` | `v8:ValueStorage` (ХранилищеЗначения) |
| `UUID` | `v8:UUID` (УникальныйИдентификатор) |

### 3.2 Ссылочные типы

| DSL | XML |
|-----|-----|
| `CatalogRef.Xxx` | `cfg:CatalogRef.Xxx` |
| `DocumentRef.Xxx` | `cfg:DocumentRef.Xxx` |
| `EnumRef.Xxx` | `cfg:EnumRef.Xxx` |
| `ChartOfAccountsRef.Xxx` | `cfg:ChartOfAccountsRef.Xxx` |
| `ChartOfCharacteristicTypesRef.Xxx` | `cfg:ChartOfCharacteristicTypesRef.Xxx` |
| `ChartOfCalculationTypesRef.Xxx` | `cfg:ChartOfCalculationTypesRef.Xxx` |
| `ExchangePlanRef.Xxx` | `cfg:ExchangePlanRef.Xxx` |
| `BusinessProcessRef.Xxx` | `cfg:BusinessProcessRef.Xxx` |
| `TaskRef.Xxx` | `cfg:TaskRef.Xxx` |
| `DefinedType.Xxx` | `cfg:DefinedType.Xxx` (через `v8:TypeSet`) |
| `Characteristic.Xxx` | `cfg:Characteristic.Xxx` (через `v8:TypeSet`) |
| `CatalogRef` / `DocumentRef` / … / `AnyRef` / `AnyIBRef` (голый, без имени) | `cfg:<метатип>` (через `v8:TypeSet`) |

**Тип-множество (`v8:TypeSet`)** — тип, подразумевающий набор типов:
- `DefinedType.Xxx` (Определяемый тип) и `Characteristic.Xxx` (значение Характеристики из ПВХ — «Вид субконто»/
  доп.реквизит). У реквизита-значения Характеристики тип обычно определяется другим реквизитом-Видом — см. `linkByType` (§4.2).
- **Голый метатип-категория** без имени объекта — «любой объект категории»: `CatalogRef` (любой справочник),
  `DocumentRef`, `EnumRef`, `ChartOfAccountsRef`, `ChartOfCharacteristicTypesRef`, `ChartOfCalculationTypesRef`,
  `ExchangePlanRef`, `BusinessProcessRef`, `TaskRef`, а также `AnyRef` (любая ссылка) и `AnyIBRef` (любая ссылка ИБ).
  Отличается от именованного `CatalogRef.Xxx` (конкретный тип через `v8:Type`) отсутствием точки. В составном типе —
  каждый через `+`: `DocumentRef + CatalogRef`.

### 3.3 Русские синонимы типов

| Русский | Канонический |
|---------|-------------|
| `Строка(100)` | `String(100)` |
| `Число(15,2)` | `Number(15,2)` |
| `Булево` | `Boolean` |
| `Дата` | `Date` |
| `ДатаВремя` | `DateTime` |
| `Время` | `Time` |
| `СправочникСсылка.Xxx` | `CatalogRef.Xxx` |
| `ДокументСсылка.Xxx` | `DocumentRef.Xxx` |
| `ПеречислениеСсылка.Xxx` | `EnumRef.Xxx` |
| `ПланСчетовСсылка.Xxx` | `ChartOfAccountsRef.Xxx` |
| `ПланВидовХарактеристикСсылка.Xxx` | `ChartOfCharacteristicTypesRef.Xxx` |
| `ПланВидовРасчётаСсылка.Xxx` | `ChartOfCalculationTypesRef.Xxx` |
| `ПланОбменаСсылка.Xxx` | `ExchangePlanRef.Xxx` |
| `БизнесПроцессСсылка.Xxx` | `BusinessProcessRef.Xxx` |
| `ЗадачаСсылка.Xxx` | `TaskRef.Xxx` |
| `ОпределяемыйТип.Xxx` | `DefinedType.Xxx` |
| `ХранилищеЗначений` / `ХранилищеЗначения` / `base64Binary` | `ValueStorage` |
| `УникальныйИдентификатор` | `UUID` |

Регистронезависимые.

---

## 4. Сокращённая запись реквизитов

### 4.1 Строковая форма

```
"ИмяРеквизита"                              → String(10) по умолчанию
"ИмяРеквизита: Тип"                         → с типом
"ИмяРеквизита: Тип | req, index"           → с флагами
```

### 4.2 Объектная форма

```json
{
  "name": "Имя",
  "type": "String(100)",
  "synonym": "Мой синоним",
  "tooltip": "Всплывающая подсказка",
  "comment": "Комментарий",
  "fillChecking": "ShowError",
  "indexing": "Index"
}
```

**`synonym` и `tooltip` — ML-значения** (см. §4.4): строка → русский текст; объект `{ "ru": "…", "en": "…" }` → мультиязычный (`<v8:item>` на язык, в порядке ключей). `tooltip` → `<ToolTip>` реквизита; нет ключа → `<ToolTip/>` (пусто). `synonym` не задан → авто из имени (§2).

Полный набор ключей объектной формы (omit-on-default; имена согласованы с form-compile, где применимо):

| Ключ | XML | Умолчание | Значения |
|------|-----|-----------|----------|
| `synonym` / `tooltip` | Synonym / ToolTip | авто / пусто | ML (§4.4) |
| `comment` | Comment | пусто | строка |
| `fillChecking` | FillChecking | DontCheck | DontCheck/ShowError/ShowWarning. Синоним `fillCheck` (из формы; `true`→ShowError). Флаг `req`→ShowError |
| `fullTextSearch` | FullTextSearch | Use | Use/DontUse |
| `fillFromFillingValue` | FillFromFillingValue | false | bool |
| `fillValue` | FillValue | по типу (см. ниже) | значение заполнения — bool/число/строка/дата/DTR-путь; `null` → nil |
| `linkByType` | LinkByType | пусто | связь по типу: `{dataPath, linkItem?}` ИЛИ строка-путь (linkItem=0). Тип значения реквизита-Характеристики берётся из реквизита по `dataPath` |
| `choiceParameterLinks` | ChoiceParameterLinks | пусто | связи параметров выбора: массив `{name, dataPath, valueChange?}` ИЛИ строк `"name=dataPath[:DontChange]"`. valueChange по умолч. `Clear` |

`dataPath` (в `linkByType` и `choiceParameterLinks`) ссылается на реквизит **самого объекта** — прощающий ввод:
- стандартный реквизит: `Ссылка`/`Ref`, `Наименование`/`Description`, `Код`/`Code`, `Владелец`/`Owner`, … →
  `<Тип>.<Имя>.StandardAttribute.<EN>`;
- обычный реквизит: имя (`Свойство`) → `<Тип>.<Имя>.Attribute.Свойство`;
- частичное `StandardAttribute.X` / `Attribute.X` → добавит префикс `<Тип>.<Имя>`; полный путь — как есть.
| `choiceParameters` | ChoiceParameters | пусто | параметры выбора: массив `{name, type?, value?}` ИЛИ строк `"name=value"`. value — bool/число/строка/DTR-путь ИЛИ массив (→ FixedArray); без value → nil |

`value` в `choiceParameters` — ref-путь несёт тип в себе (`Enum.X.EmptyRef`, `Enum.X.EnumValue.Y`, рус. корни). Опц.
ключ **`type`** (тип поля-фильтра, напр. `EnumRef.ТипыВЕТИС` / `СправочникСсылка.X`) разворачивает **голые** значения:
`{name:"Отбор.Тип", type:"EnumRef.ТипыВЕТИС", value:["EmptyRef","ТТН"]}` → `Enum.ТипыВЕТИС.EmptyRef`,
`Enum.ТипыВЕТИС.EnumValue.ТТН`. Без `type` голое имя (`ТТН`) остаётся **строкой** (`xs:string`) — для ссылки нужен путь.
| `createOnInput` | CreateOnInput | Auto | Auto/Use/DontUse |
| `quickChoice` | QuickChoice | Auto | Auto/Use/DontUse. Прощаем bool (форм-стиль): `true`→Use, `false`→DontUse |
| `dataHistory` | DataHistory | Use | Use/DontUse |
| `use` | Use | ForItem | ForItem/ForFolderAndItem/ForFolder (иерарх. справочник) |
| `passwordMode` | PasswordMode | false | bool |
| `mask` | Mask | пусто | строка маски |
| `format` / `editFormat` | Format / EditFormat | пусто | строка/`{ru,en}` (ML, форматная строка 1С) |
| `choiceHistoryOnInput` | ChoiceHistoryOnInput | Auto | Auto/DontUse |
| `indexing` | Indexing | DontIndex | флаги `index`/`indexAdditional` |
| `multiLine` | MultiLine | false | bool (флаг `multiline`) |
| `extendedEdit` | ExtendedEdit | false | bool (расширенное редактирование — многострочное поле) |
| `minValue` / `maxValue` | MinValue / MaxValue | nil (не задано) | граница диапазона, типизировано (см. ниже) |

**`minValue` / `maxValue`** — границы диапазона значений реквизита (`<MinValue>`/`<MaxValue>`). Без ключа →
`xsi:nil="true"` (не задано). Значение **типизировано** (зеркало form-compile): JSON-**число** → `xsi:type="xs:decimal"`,
JSON-**строка** → `xsi:type="xs:string"` (напр. год `"2000"`, код `"01"`). Тип сохраняется декомпилятором из XML.

**Фикс. длина строки:** тип `String(N,fixed)` → `<v8:AllowedLength>Fixed</v8:AllowedLength>` (строка ровно N символов);
`String(N)` / `String(N,variable)` → `Variable` (дефолт). См. §3.2.

**`fillValue` — значение заполнения реквизита** (`<FillValue>`). Пара с `fillFromFillingValue` — единый блок
«заполнения» (недоступен у реквизитов ТЧ; там оба свойства не эмитятся). Форма **пустого** значения зависит от
типа реквизита (то же, что «пустое» значение типа), компилятор выводит её сам — ключ **не задают**:

| Тип реквизита | Пустое значение (без ключа) |
|---------------|-----------------------------|
| String | `<FillValue xsi:type="xs:string"/>` |
| Number | `<FillValue xsi:type="xs:decimal">0</FillValue>` |
| Boolean, Date, ссылочный, составной, TypeSet | `<FillValue xsi:nil="true"/>` |

Ключ `fillValue` задают только для **реального** значения; интерпретация — по типу реквизита:

- **Boolean** — `true`/`false` (прощаем `"Истина"`/`"Ложь"`, `"да"`/`"нет"`).
- **Number** — число или строка-число (`1.5`, `"21"`).
- **String** — строковый литерал (без ссылочной/датовой детекции).
- **Date** — ISO-строка `"0001-01-01T00:00:00"` (или `"2020-01-01"` → добавит время).
- **Ссылочный / составной / TypeSet** — DTR-путь:
  - полный: `"Catalog.Валюты.EmptyRef"`, `"Enum.Периодичность.EnumValue.Месяц"`, `"Catalog.СтраныМира.Россия"`;
  - русские метатипы: `"Справочник.Валюты.ПустаяСсылка"`, `"Перечисление.Периодичность.ЗначениеПеречисления.Год"`;
  - GUID-ссылка `"<guid>.<guid>"` (несётся verbatim);
  - **короткая запись** по типу реквизита (одно имя, без точки): `"EmptyRef"`/`"ПустаяСсылка"` → пустая ссылка типа;
    для `EnumRef` — имя значения (`"Месяц"` → `Enum.<Тип>.EnumValue.Месяц`); для прочих — имя предопределённого
    (`"Россия"` → `Catalog.<Тип>.Россия`). Для составного типа короткая запись запрещена (нужен полный путь).
- **`null`** — явный `<FillValue xsi:nil="true"/>` (для String/Number, где нужно nil вместо пустого значения типа).

> `EmptyRef` («пустая ссылка типа X») ≠ `null` («значение не задано»): платформа хранит их различно, оба сохраняются.

Тип можно задать единой строкой (`"type": "String(100)"`) или раздельными полями:

```json
{ "name": "Имя", "type": "String", "length": 100 }
{ "name": "Сумма", "type": "Number", "length": 15, "precision": 2 }
{ "name": "Остаток", "type": "Number", "length": 15, "precision": 2, "nonneg": true }
```

Раздельная форма эквивалентна `String(100)`, `Number(15,2)`, `Number(15,2,nonneg)`.
Если `type` уже содержит скобки — `length`/`precision` игнорируются.

**Зарезервированные имена.** Имя собственного реквизита не должно совпадать со стандартным реквизитом объекта
(англ. или рус., регистронезависимо) — платформа такое не примет. Компилятор отклоняет с ошибкой:
- **Catalog**: `Ref`/`Ссылка`, `DeletionMark`/`ПометкаУдаления`, `Predefined`/`Предопределенный`,
  `PredefinedDataName`/`ИмяПредопределенныхДанных`, `Code`/`Код`, `Description`/`Наименование`, `Owner`/`Владелец`,
  `Parent`/`Родитель`, `IsFolder`/`ЭтоГруппа`.
- **Document**: `Ref`/`Ссылка`, `DeletionMark`/`ПометкаУдаления`, `Date`/`Дата`, `Number`/`Номер`, `Posted`/`Проведен`.

Проверка **типозависима**: напр. `Номер` — легальное имя реквизита справочника (стандартный он только у документа).
Реквизиты табличных частей проверке не подлежат (там зарезервирован лишь `НомерСтроки`).

### 4.3 Флаги

| Флаг | Действие | Применимость |
|------|---------|-------------|
| `req` | FillChecking = ShowError | attributes, dimensions, resources |
| `index` | Indexing = Index | attributes, dimensions |
| `indexAdditional` | Indexing = IndexWithAdditionalOrder | attributes |
| `multiline` | MultiLine = true | attributes |
| `nonneg` | MinValue = 0 (+ nonneg для Number) | attributes, resources |
| `master` | Master = true | dimensions (РС) |
| `mainFilter` | MainFilter = true | dimensions (РС) |
| `denyIncomplete` | DenyIncompleteValues = true | dimensions |
| `useInTotals` | UseInTotals = true | dimensions (РН) |

Флаги разделяются запятой после `|`.

### 4.4 ML-значения (многоязычный текст)

Текстовые поля, попадающие в `<v8:item>`-структуру 1С (`synonym`, `tooltip`), принимают две формы:

- **строка** → один язык `ru`: `"synonym": "Наименование"`;
- **объект `{ lang: content }`** → по `<v8:item>` на язык, **в порядке ключей**: `"tooltip": { "ru": "Подсказка", "en": "Hint" }`.

Пустая строка `""` / отсутствие ключа → самозакрывающийся тег (`<ToolTip/>`). Консистентно с формой `title`/`tooltip` в form-compile.

---

## 5. Табличные части

Для типов с ChildObjects → TabularSection: Catalog, Document, ExchangePlan, ChartOfCharacteristicTypes, ChartOfCalculationTypes, BusinessProcess, Task, Report, DataProcessor, ChartOfAccounts.

```json
"tabularSections": {
  "Товары": [
    "Номенклатура: CatalogRef.Номенклатура | req",
    "Количество: Number(10,3)",
    "Цена: Number(15,2)",
    "Сумма: Number(15,2)"
  ],
  "Услуги": [
    "Описание: String(200)"
  ]
}
```

Ключ — имя табличной части, значение — **массив реквизитов** (в строковой или объектной форме; синоним ТЧ авто из имени) ЛИБО **объект** с собственными свойствами ТЧ:

```json
"tabularSections": {
  "Представления": {
    "synonym": { "ru": "Представления", "en": "Presentations" },
    "tooltip": "Локализованные представления",
    "attributes": [ "КодЯзыка: String(10) | index", "Наименование: String(150)" ]
  }
}
```

Свойства объектной формы ТЧ: `synonym` (ML; нет ключа → авто из имени), `tooltip` (ML), `comment` (строка), `attributes` (колонки; синоним `columns`), `lineNumber` (кастомизация стандартного реквизита НомерСтроки, см. ниже).

Для Catalog добавляется `<Use>ForItem</Use>` в Properties табличной части. Для Document Use не применяется.

### 5.1 `lineNumber` — кастомизация стандартного реквизита НомерСтроки

У каждой ТЧ ровно один стандартный реквизит — **LineNumber** (НомерСтроки). Платформа материализует блок
`<StandardAttributes>` с ним практически всегда (компилятор эмитит его безусловно), но по умолчанию все свойства
LineNumber дефолтные. Ключ `lineNumber` на объектной форме ТЧ переопределяет их (omit-on-default по каждому свойству):

| Ключ | XML | Умолчание | Тип |
|------|-----|-----------|-----|
| `synonym` | Synonym | пусто | ML (строка/`{ru,en}`) |
| `comment` | Comment | пусто | строка |
| `fullTextSearch` | FullTextSearch | Use | Use/DontUse |
| `tooltip` | ToolTip | пусто | ML |
| `format` | Format | пусто | ML (форматная строка) |
| `editFormat` | EditFormat | пусто | ML |
| `choiceHistoryOnInput` | ChoiceHistoryOnInput | Auto | Auto/DontUse |

```json
"tabularSections": {
  "Строки": {
    "lineNumber": { "synonym": "Номер п/п", "fullTextSearch": "DontUse" },
    "attributes": ["Товар: CatalogRef.Номенклатура"]
  }
}
```

Прочие свойства LineNumber (FillChecking, CreateOnInput и т.п.) платформа не даёт переопределять — они всегда дефолтные.
Декомпилятор эмитит `lineNumber` только при отклонении ≥1 свойства от дефолта. NB: редкий хвост ТЧ (~2.5% корпуса)
блок `<StandardAttributes>` вовсе опускает — правило не выведено; компилятор такие не воспроизводит (эмитит блок всегда).

---

## 6. Значения перечислений

Только для Enum.

```json
"values": [
  "Приход",
  "Расход",
  { "name": "НДС20", "synonym": "НДС 20%" }
]
```

Строка — имя (синоним авто из CamelCase). Объект — полная форма.

---

## 7. Свойства по типам

### 7.1 Catalog

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `comment` | пусто | Comment |
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
| `quickChoice` | `true` | QuickChoice |
| `choiceMode` | `BothWays` | ChoiceMode |
| `useStandardCommands` | `true` | UseStandardCommands (bool) |
| `editType` | `InDialog` | EditType (InDialog/InList/BothWays) |
| `createOnInput` | `Use` | CreateOnInput (Auto/Use/DontUse) |
| `choiceHistoryOnInput` | `Auto` | ChoiceHistoryOnInput (Auto/DontUse) |
| `predefinedDataUpdate` | `Auto` | PredefinedDataUpdate (Auto/DontAutoUpdate/AutoUpdate) |
| `searchStringModeOnInputByString` | `Begin` | SearchStringModeOnInputByString (Begin/AnyPart) |
| `fullTextSearchOnInputByString` | `DontUse` | FullTextSearchOnInputByString (Use/DontUse) |
| `includeHelpInContents` | `false` | IncludeHelpInContents (bool) |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `defaultObjectForm` / `defaultFolderForm` / `defaultListForm` / `defaultChoiceForm` / `defaultFolderChoiceForm` | пусто | Default*Form (ссылка на форму) |
| `auxiliaryObjectForm` / `auxiliaryFolderForm` / `auxiliaryListForm` / `auxiliaryChoiceForm` / `auxiliaryFolderChoiceForm` | пусто | Auxiliary*Form (ссылка на форму) |

Ссылка на форму — `Тип.Объект.Form.ИмяФормы` (напр. `Catalog.НастройкиОбмена.Form.ФормаЭлемента`). Прощающий ввод:
русский корень (`Справочник`→`Catalog`), сегмент `Форма`→`Form`, и короткая запись без него —
`Справочник.НастройкиОбмена.ФормаЭлемента` ≡ `Справочник.НастройкиОбмена.Форма.ФормаЭлемента` ≡ канон.
| `owners` | `[]` | Owners |
| `objectPresentation` | пусто | ObjectPresentation (ML) |
| `extendedObjectPresentation` | пусто | ExtendedObjectPresentation (ML) |
| `listPresentation` | пусто | ListPresentation (ML) |
| `extendedListPresentation` | пусто | ExtendedListPresentation (ML) |
| `explanation` | пусто | Explanation (ML) |
| `standardAttributes` | *(ключа нет → блок опущен)* | StandardAttributes |
| `inputByString` | *(ключа нет → авто-вывод)* | InputByString (поля ввода по строке, §7.1.5) |
| `dataLockFields` | `[]` | DataLockFields (поля блокировки данных, §7.1.5) |
| `basedOn` | `[]` | BasedOn (ввод на основании, §7.1.5) |
| `characteristics` | `[]` | Characteristics (привязка ПВХ, §7.1.4) |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

#### 7.1.1 `standardAttributes` — кастомизация стандартных реквизитов

Блок `<StandardAttributes>` платформа материализует **только когда пользователь кастомизировал хотя бы один стандартный реквизит** (Наименование/Код/Владелец/…). Ни иерархия, ни владелец, ни предопределённые сами по себе блок не создают. В DSL это выражается **наличием ключа `standardAttributes`**:

- **Ключа нет** → блок не эмитится (обычный справочник: Наименование, Код, Владелец и т.д. остаются платформенными по умолчанию).
- **Ключ есть** (даже пустой `{}`) → эмитится полный блок из всех стандартных реквизитов с **профилем материализованного блока**, поверх которого накладываются заданные переопределения.

Формат: `standardAttributes` — объект `{ ИмяРеквизита: { переопределения } }`. Имена реквизитов — как в XML: `PredefinedDataName`, `Predefined`, `Ref`, `DeletionMark`, `IsFolder`, `Owner`, `Parent`, `Description`, `Code`.

Переопределяемые поля реквизита: `synonym` (ML — строка/`{ru,en}`), `tooltip` (ML), `fillChecking` (`DontCheck`|`ShowError`|`ShowWarning`), `fillFromFillingValue` (bool), `fullTextSearch` (`Use`|`DontUse`), `dataHistory` (`Use`|`DontUse`), `fillValue` (значение — DTR-путь/строка/bool; см. §4.2), `choiceParameterLinks` / `choiceParameters` (как у реквизита, §4.2), `comment`, `mask`, `choiceForm`.

> «Пустая ссылка» как значение заполнения (`<FillValue xsi:type="xr:DesignTimeRef"/>` без содержимого) — маркер
> `fillValue: {emptyRef: true}` (декомпилятор проставляет его сам; тип из строки не выводится, т.к. `DefinedType.X`
> непрозрачен). Применимо к реквизиту и стандартному реквизиту (в т.ч. `lineNumber` ТЧ поддерживает `fillValue`).

**Профиль материализованного блока** (значения, которые платформа заполняет автоматически — задавать их в DSL не нужно):

| Реквизит | Профильные значения |
|----------|--------------------|
| `Owner` | fillChecking=`ShowError`, fillFromFillingValue=`true` |
| `Parent` | fillFromFillingValue=`true` |
| `Description` | fillChecking=`ShowError` |
| остальные | schema-дефолт (fillChecking=`DontCheck`, fillFromFillingValue=`false`, …) |

В `standardAttributes` указывают **только отклонения** от профиля (переопределение синонима, нетиповой fillChecking и т.п.).

```json
{
  "type": "Catalog", "name": "Контрагенты",
  "standardAttributes": {
    "Description": { "synonym": "Наименование контрагента" },
    "Code": { "fillChecking": "ShowError" }
  }
}
```
Здесь эмитится блок: `Owner`/`Parent`/`Description` получают профиль автоматически; `Description` — ещё и заданный синоним; `Code` — `fillChecking=ShowError` поверх дефолта.

> Пока поддержано для **Catalog**. У прочих типов объектов — свои стандартные реквизиты и профили (будут добавлены при их проработке).

#### 7.1.2 `predefined` — предопределённые элементы

Массив предопределённых элементов справочника → файл `Ext/Predefined.xml`. Ключа нет / пустой массив → файл не создаётся. Элемент — **строка** (короткая форма, плоский случай) ЛИБО **объект** (группа/иерархия).

**Строковая форма:** `"(Код) Имя [Наименование]"`
- **Имя** — обязательный идентификатор (без пробелов).
- **`(Код)`** — опциональный префикс.
- **`[Наименование]`** — опциональный суффикс:
  - нет `[...]` → Наименование **авто** из Имени (Split-CamelCase, §2);
  - `[]` (пусто) → Наименование пустое (для системных/placeholder-элементов);
  - `[текст]` → заданное.

```json
"predefined": [
  "Основной",                                   // Наименование авто = "Основной"
  "(1) ДокументОПриемке [Документ о приемке]",  // код + имя + Наименование
  "ПустоеЗначение []"                           // Наименование пустое
]
```

**Объектная форма** (группа/иерархия):

| Ключ | Синоним | Описание |
|------|---------|----------|
| `name` | `имя` | Имя (обязательно) |
| `code` | `код` | Код |
| `description` | `наименование` | Наименование (ключа нет → авто; `""` → пусто) |
| `isFolder` | `группа` | Признак группы |
| `childItems` | `подчиненные` | Вложенные элементы (строки/объекты, рекурсивно) |

```json
{ "name": "Группа1", "isFolder": true, "description": "Прочие",
  "childItems": [ "Факс", "(7) Скайп [Скайп]" ] }
```

Тип кода в XML определяется свойством справочника `codeType`: `Number` → `<Code xsi:type="xs:decimal">`, `String` → `<Code>` (без типа); пустой код → `<Code/>`.

> Пока поддержано для **Catalog** (`CatalogPredefinedItems`). ChartOf*/ПВХ — при их проработке.

#### 7.1.3 `commands` — команды объекта

Команды объекта → `<Command>`-блоки в ChildObjects + заготовка `Commands/<Имя>/Ext/CommandModule.bsl` (обработчик `ОбработкаКоманды`). Ключ — имя команды, значение — объект свойств (map `имя→объект`, либо массив `[{name, …}]`).

| Ключ | XML | Умолчание |
|------|-----|-----------|
| `synonym` | Synonym | авто из имени (ML) |
| `tooltip` | ToolTip | пусто (ML) |
| `comment` | Comment | пусто |
| `group` | Group | пусто (`FormCommandBarImportant`, `FormNavigationPanelGoTo`, …) |
| `commandParameterType` | CommandParameterType | пусто (тип, напр. `CatalogRef.Номенклатура`) |
| `parameterUseMode` | ParameterUseMode | `Single` (`Single`/`Multiple`) |
| `modifiesData` | ModifiesData | `false` (bool) |
| `representation` | Representation | `Auto` |
| `picture` | Picture | пусто (структурный блок, см. ниже) |
| `loadTransparent` | Picture/LoadTransparent | `true` (bool, sibling `picture`) |
| `shortcut` | Shortcut | пусто |
| `onMainServerUnavalableBehavior` | OnMainServerUnavalableBehavior | `Auto` |

**`picture`** — картинка команды `<Picture>` (структурный блок `<xr:Ref>`+`<xr:LoadTransparent>`, зеркало form-compile).
Значение: строка-ref (`StdPicture.X` / `CommonPicture.X`; встроенная — префикс `abs:` → `<xr:Abs>`) ЛИБО объект
`{src, loadTransparent?, transparentPixel?}`. LoadTransparent платформа пишет всегда, **дефолт `true`** (конвенция
кнопки/команды) — фиксируем только `false`: строкой-ref + sibling-ключ `loadTransparent: false`, либо внутри объекта.
`transparentPixel: {x, y}` → `<xr:TransparentPixel>`. Декомпилятор: скаляр при LoadTransparent=true без пикселя,
иначе объект.

```json
"commands": {
  "ПечатьЭтикеток": {
    "synonym": "Печать этикеток", "group": "FormCommandBarImportant",
    "commandParameterType": "CatalogRef.Номенклатура", "modifiesData": true,
    "picture": "StdPicture.Print"
  },
  "ЗагрузитьИзФайла": { "picture": "CommonPicture.Загрузка", "loadTransparent": false }
}
```

> Тело модуля команды генерируется заготовкой (обработчик пустой). Раундтрип тела модуля не проверяет (как ObjectModule).

#### 7.1.4 `characteristics` — привязка ПВХ («Дополнительные реквизиты и сведения»)

Массив характеристик. Каждая связывает **источник типов** (где определены характеристики) и **источник значений**
(где хранятся значения). Имена ключей зеркалят XML без `xr:`; `-1`-поля (`DataPathField`/`MultipleValues*`) неявны.

```json
"characteristics": [{
  "types":  { "from": "Справочник.НаборыДопРеквИСвед.ДополнительныеРеквизиты",
              "key": "Свойство", "filterField": "Ссылка", "filterValue": "Справочник_Организации" },
  "values": { "from": "Catalog.Организации.TabularSection.ДополнительныеРеквизиты",
              "object": "Ссылка", "type": "Свойство", "value": "Значение" }
}]
```

- **`from`** — источник-таблица. Прощающий ввод: рус. корни (`Справочник`→Catalog, `ТабличнаяЧасть`→TabularSection),
  короткая 3-сегментная `Тип.X.ТЧ` → вставит `TabularSection`. Синоним `source`.
- **Поля** (`key`/`filterField`/`object`/`type`/`value`) — путь к полю источника, прощающий ввод (как dataPath):
  голое имя → `StandardAttribute.<EN>` для ссылочных станд. (`Ссылка`/`Родитель`/`Владелец`, RU→EN), иначе → `Attribute.<имя>`;
  частичное `Dimension.X`/`Resource.X`/`StandardAttribute.X` → + префикс `from` (форма для регистров ДопСведения);
  полный путь → как есть.
- **`filterValue`** — значение фильтра типов (обычно предопределённый набор): голое имя → `xs:string` (частый случай,
  напр. `Справочник_Организации`); полный путь → `xr:DesignTimeRef` (`Catalog.X.Справочник_Y`); bool → `xs:boolean`;
  `null` → `xsi:nil` (пустая характеристика). Различает вид по наличию точки.
- **Числовые флаги** `dataPathField`/`multipleValuesUseField` (в `types`), `multipleValuesKeyField`/
  `multipleValuesOrderField` (в `values`) — по умолчанию `-1`, задавать не нужно (кроме редких `0`).
- **Синонимы ключей:** `types`/`characteristicTypes`, `values`/`characteristicValues`, `key`/`keyField`,
  `filterField`/`typesFilterField`, `filterValue`/`typesFilterValue`, `object`/`objectField`, `type`/`typeField`, `value`/`valueField`.

Декомпилятор пишет короткую форму (поля голые/частичные, `filterValue` без каталога, `from` полный).

#### 7.1.5 `inputByString` / `dataLockFields` / `basedOn` — object-списки полей

Три списка object-уровня. Имена полей — прощающий ввод как `dataPath`: голое стандартное (`Наименование`/`Код`/
`Владелец`, RU→EN) → `<Тип>.<Объект>.StandardAttribute.<EN>`; голое обычное → `Attribute.<имя>`;
частичное `StandardAttribute.X`/`Attribute.X` → + префикс; полный путь → как есть.

- **`inputByString`** — поля быстрого ввода по строке (`<InputByString>`). **Дефолт выводится** из наличия Кода/
  Наименования: `[Наименование при descriptionLength>0] + [Код при codeLength>0]` — покрывает ~88% каталогов, ключ не
  нужен. Задавать только при отличии: другой порядок, подмножество, добавленные реквизиты, или **пустой список `[]`**
  (быстрый ввод выключен).
  ```json
  "inputByString": ["Код", "Наименование", "Контрагент"]   // порядок + реквизит
  "inputByString": []                                        // явно пусто
  ```
- **`dataLockFields`** — поля управляемой блокировки данных (`<DataLockFields>`). По умолчанию пусто; массив имён полей.
  ```json
  "dataLockFields": ["Организация", "Контрагент", "Владелец"]
  ```
- **`basedOn`** — «ввод на основании» (`<BasedOn>`), список ссылок на объекты метаданных (`MDObjectRef`) verbatim.
  ```json
  "basedOn": ["Catalog.Контрагенты", "Document.ЗаказПоставщику"]
  ```

Декомпилятор: `inputByString` — только при отличии от выведенного дефолта (иначе опущен); `dataLockFields`/`basedOn` —
omit-on-empty. Поля пишутся частичной формой (`StandardAttribute.X`/`Attribute.X`).

### 7.2 Document (Документ)

Общий с Catalog слой: `synonym`, `comment`, `useStandardCommands`, `inputByString` (§7.1.5, дефолт [Номер]),
формы (`defaultObjectForm`/`defaultListForm`/`defaultChoiceForm`/`auxiliary*`), `standardAttributes` (§7.1.1),
`characteristics` (§7.1.4), `basedOn`, `dataLockFields`, презентации, `createOnInput`, `choiceHistoryOnInput`,
`includeHelpInContents`. Стандартные реквизиты Document: Ref, DeletionMark, Date, Number, Posted. Блок SA
**условный** (профиль материализованного: **Дата → FillChecking=ShowError**, 974/1010 доков); опускается лишь у
редкого all-default дока.

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `numerator` | `""` | Numerator (ссылка `DocumentNumerator.X`, omit-on-empty) |
| `numberType` | `String` | NumberType |
| `numberLength` | `11` | NumberLength |
| `numberAllowedLength` | `Variable` | NumberAllowedLength |
| `numberPeriodicity` | `Year` | NumberPeriodicity *(корпусная мода; платформа-свежий `Nonperiodical`)* |
| `checkUnique` | `true` | CheckUnique |
| `autonumbering` | `true` | Autonumbering |
| `posting` | `Allow` | Posting |
| `realTimePosting` | `Deny` | RealTimePosting |
| `registerRecordsDeletion` | `AutoDelete` | RegisterRecordsDeletion *(безопасный дефолт для авторства; в корпусе редкий)* |
| `registerRecordsWritingOnPost` | `WriteSelected` | RegisterRecordsWritingOnPost |
| `sequenceFilling` | `AutoFill` | SequenceFilling |
| `postInPrivilegedMode` | `true` | PostInPrivilegedMode |
| `unpostInPrivilegedMode` | `true` | UnpostInPrivilegedMode |
| `createOnInput` | `Use` | CreateOnInput |
| `dataLockControlMode` | `Managed` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `dataHistory` | `DontUse` | DataHistory (+ триплет Update/Execute) |
| `registerRecords` | `[]` | RegisterRecords (список MDObjectRef движений; рус.синонимы типов резолвятся) |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

**Реквизит** (общее для всех типов, всплыло на Document): `markNegatives` (bool, выделять отрицательные красным),
`choiceForm` (ссылка на форму выбора), `choiceFoldersAndItems` (Items|Folders|FoldersAndItems, дефолт Items),
`format`/`editFormat` стандартного реквизита (в `standardAttributes`-override, ML).

**Табличная часть** (объектная форма): `fillChecking` (обязательность заполнения ТЧ, дефолт DontCheck);
`lineNumber: ""` — **подавляет** эмиссию TS-блока стандартных реквизитов (LineNumber). Наличие блока — пер-ТЧ
исторический артефакт (~6% доковых ТЧ его опускают, правило не выводимо); по умолчанию блок эмитится (opt-out).

### 7.2a ExchangePlan (План обмена)

Близок к Catalog (без иерархии/владельцев/кодогенерации), плюс два своих флага. Общий с Catalog слой: `synonym`,
`comment`, `useStandardCommands`, `codeLength`/`codeAllowedLength`/`descriptionLength`, `defaultPresentation`, `editType`,
`quickChoice`, `choiceMode`, `inputByString` (§7.1.5, дефолт [Наименование]+[Код] по длинам), формы (`defaultObjectForm`/
`defaultListForm`/`defaultChoiceForm`/`auxiliary*`), `standardAttributes` (§7.1.1), `characteristics` (§7.1.4), `basedOn`,
`dataLockFields`, презентации, `choiceHistoryOnInput`, `includeHelpInContents`.

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `distributedInfoBase` | `false` | DistributedInfoBase (РИБ — распределённая ИБ) |
| `includeConfigurationExtensions` | `false` | IncludeConfigurationExtensions |
| `createOnInput` | `DontUse` | CreateOnInput *(отличие от Catalog: там `Use`)* |
| `dataLockControlMode` | `Managed` | DataLockControlMode *(отличие от Catalog: там `Automatic`)* |
| `dataHistory` | `DontUse` | DataHistory |
| `updateDataHistoryImmediatelyAfterWrite` | `false` | UpdateDataHistoryImmediatelyAfterWrite |
| `executeAfterWriteDataHistoryVersionProcessing` | `false` | ExecuteAfterWriteDataHistoryVersionProcessing |
| `descriptionLength` | `150` | DescriptionLength *(отличие от Catalog: там `25`)* |
| `attributes` / `tabularSections` | `[]` / `{}` | → ChildObjects |

Стандартные реквизиты EP: Ref, DeletionMark, Code, Description, ThisNode, SentNo, ReceivedNo (профиль материализованного
блока: Наименование/Код → FillChecking=ShowError). Блок **условный** (как Catalog): материализуется при кастомизации —
ключ `standardAttributes`. Опциональный легаси-реквизит `ExchangeDate` (часть планов) поддержан как «доп.» член
`standardAttributes` (эмитится по факту наличия ключа, вне фикс-списка).

**Состав плана обмена** (`content`, синоним `Состав`) — соседний `Ext/Content.xml`: список объектов-участников обмена,
у каждого признак авторегистрации изменений на узле (AutoRecord: `Deny`=запрещена, дефолт; `Allow`=разрешена). Элемент —
MDObjectRef (`Catalog.X`/`Document.Y`/`InformationRegister.Z`/`Constant.W`/…), пишется verbatim.

| Форма записи | Смысл |
|--------------|-------|
| `"Catalog.Организации"` | AutoRecord=Deny (авторегистрация выкл — дефолт) |
| `"InformationRegister.Курсы: autoRecord"` | AutoRecord=Allow — токен-признак `autoRecord`/`АвтоРегистрация` (регистронезависимо; принимается и `: Allow`/`: Разрешить`) |
| `{ "metadata": "Document.РеализацияТоваров", "autoRecord": true }` | объектная форма: `autoRecord` — boolean (`true`=Allow) ИЛИ строка `Allow`/`Deny`/`Разрешить`/`Запретить` |

Синонимы ключей объектной формы: `metadata` → `Метаданные`/`объект`, `autoRecord` → `АвтоРегистрация`. Дефолт `Deny` в
строке опускается. Пустой/отсутствующий `content` → пустой `<ExchangePlanContent/>`. Декомпилятор пишет короткую строковую
форму (`"Ref"` для Deny, `"Ref: autoRecord"` для Allow). Порядок элементов платформенно-произвольный (1С толерантна).

### 7.2b ChartOfCharacteristicTypes (План видов характеристик)

Иерархический ссылочный тип (папки+элементы, без уровней/подчинения). Общий с Catalog слой: `synonym`, `comment`,
`useStandardCommands`, `includeHelpInContents`, `hierarchical`/`foldersOnTop`, коды (`codeLength`/`codeAllowedLength`/
`descriptionLength`/`checkUnique`/`autonumbering`), `defaultPresentation`, `standardAttributes` (§7.1.1),
`characteristics` (§7.1.4), `inputByString` (§7.1.5), формы (вкл. `*Folder*`), `basedOn`, `dataLockFields`, презентации,
`predefined` (§7.1.2) — предопределённые виды характеристик.

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `valueType` | *(любой примитив)* | Type (тип значения характеристики, составной — строка `"A + B"` или массив `valueTypes`) |
| `characteristicExtValues` | пусто | CharacteristicExtValues (ссылка на справочник доп. значений) |
| `createOnInput` | `DontUse` | CreateOnInput *(≠ Catalog `Use`)* |
| `dataLockControlMode` | `Managed` | DataLockControlMode *(≠ Catalog `Automatic`)* |
| `codeSeries` | `WholeCharacteristicKind` | CodeSeries *(≠ Catalog `WholeCatalog`)* |
| `checkUnique` | `true` | CheckUnique *(≠ Catalog `false`)* |
| `descriptionLength` | `100` | DescriptionLength *(≠ Catalog `25`)* |
| `dataHistory` + `updateDataHistoryImmediatelyAfterWrite` + `executeAfterWriteDataHistoryVersionProcessing` | `DontUse`/`false`/`false` | DataHistory-триплет |

Стандартные реквизиты ПВХ: PredefinedDataName, Predefined, Ref, DeletionMark, Description, Code, Parent, ValueType
(профиль: Наименование → FillChecking=ShowError, Родитель → FillFromFillingValue=true). Блок **условный** (`standardAttributes`).

**Предопределённые виды** несут **тип значения на элемент**. Короткая запись — как в полях СКД/реквизитах, тип после `:`:
`"(Код) Имя [Наименование]: Тип"` (тип составной через `+`). Объектная форма — ключ `type` (строка/массив; `""` → пустой
`<Type/>`). Правило: нет `:`/ключа → без блока Type; непустой тип → короткая строка; пустой `<Type/>` / папки / с детьми →
объектная форма. Примеры:
```json
"predefined": [
  "(000001) Цвет: CatalogRef.Цвета",
  "(000002) Размер [Размер одежды]: String(50) + Number(3,0)",
  { "name": "Группа", "isFolder": true, "type": "" }
]
```

### 7.2c ChartOfAccounts (План счетов)

Иерархический ссылочный тип бухгалтерских счетов (без папок/уровней/владельцев). Общий с Catalog слой: `synonym`,
`comment`, `useStandardCommands`, `includeHelpInContents`, коды (`codeLength`/`descriptionLength`/`checkUnique`/
`codeMask`), `defaultPresentation`, `standardAttributes` (§7.1.1), `characteristics` (§7.1.4), `inputByString` (§7.1.5),
формы (без `*Folder*`), `basedOn`, `dataLockFields`, презентации.

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `extDimensionTypes` | пусто | ExtDimensionTypes (ссылка на ПВХ видов субконто; `ПланВидовХарактеристик.X` → `ChartOfCharacteristicTypes.X`) |
| `maxExtDimensionCount` | `3` при заданном `extDimensionTypes`, иначе `0` | MaxExtDimensionCount (платформа не даёт > 0 без ПВХ видов субконто) |
| `codeMask` | пусто | CodeMask (маска кода счёта) |
| `codeSeries` | `WholeChartOfAccounts` | CodeSeries |
| `checkUnique` | `true` | CheckUnique *(≠ Catalog `false`)* |
| `defaultPresentation` | `AsCode` | DefaultPresentation *(≠ Catalog `AsDescription`)* |
| `autoOrderByCode` | `true` | AutoOrderByCode |
| `orderLength` | `9` | OrderLength |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `dataHistory` + `updateDataHistoryImmediatelyAfterWrite` + `executeAfterWriteDataHistoryVersionProcessing` | `DontUse`/`false`/`false` | DataHistory-триплет |
| `accountingFlags` | `[]` | AccountingFlag в ChildObjects (признаки учёта — как реквизит, тип по умолчанию Boolean; §4.2) |
| `extDimensionAccountingFlags` | `[]` | ExtDimensionAccountingFlag в ChildObjects (признаки учёта субконто; как реквизит) |
| `predefined` | `[]` | Ext/Predefined.xml — предопределённые счета (грамматика ниже) |

Стандартные реквизиты ПС: PredefinedDataName, Order, OffBalance, Type, Description, Code, Parent, Predefined,
DeletionMark, Ref (профиль: Наименование/Код → FillChecking=ShowError, Родитель → FillFromFillingValue=true). Блок
**условный** (`standardAttributes`). Реквизит `Type` (Тип счёта) несёт FillValue-перечисление **`ent:AccountType`** —
значения `Active`/`Passive`/`ActivePassive` (распознаются автоматически в `fillValue`/параметрах выбора). Всегда
эмитится вложенный блок субконто `StandardTabularSections/ExtDimensionTypes` (платформенно-константен: обёртка
«Виды субконто», вложенный ExtDimensionType → FillChecking=ShowError).

**Предопределённые счета** — отдельная грамматика (объектная форма). Признаки (`flags`) перечисляют только
**включённые** (`true`) имена; компилятор разворачивает полный список по def-порядку `accountingFlags`/
`extDimensionAccountingFlags` плана. `order` — вербатим (не выводится). `description` опускается при равенстве
Split-CamelCase имени.

| Поле счёта | Умолчание | XML |
|-----------|----------|-----|
| `name` / `code` / `description` | — / пусто / *(авто из имени)* | Name / Code / Description |
| `accountType` | `ActivePassive` | AccountType (`Active`/`Passive`/`ActivePassive`) |
| `offBalance` | `false` | OffBalance |
| `order` | — | Order (строка сортировки, вербатим) |
| `flags` | `[]` | AccountingFlags → `<Flag>` по каждому признаку плана |
| `subconto` | `[]` | ExtDimensionTypes → `<ExtDimensionType name="…">` (вид субконто) |
| `childItems` | `[]` | ChildItems (иерархия счетов) |

**Субконто** (`subconto`) — короткая строка **`"Вид | Признак1, Признак2"`** (после `|` — включённые признаки учёта
субконто): `type` — голое имя предопределённого значения ПВХ, компилятор разворачивает через `extDimensionTypes` плана
(`Номенклатура` → `ChartOfCharacteristicTypes.ВидыСубконто.Номенклатура`); признаки — только TRUE, разворот по def-порядку
`extDimensionAccountingFlags`. **«Только обороты»** (`<Turnover>` — субконто ведётся только по оборотам, без остатков) —
предопределённый признак-токен **`Turnover`** (синонимы `ТолькоОбороты`/`Только обороты`) в том же списке признаков:
`"Номенклатура | Turnover, Суммовой"`. Объектная форма `{type, turnover?, flags?}` тоже принимается (эквивалент).

```json
"predefined": [
  { "name": "ОсновныеСредства", "code": "01", "accountType": "Active", "order": " 01",
    "flags": ["Количественный"],
    "subconto": ["Номенклатура | Суммовой, Валютный"],
    "childItems": [
      { "name": "ОС в организации", "code": "01.01", "accountType": "Active", "order": " 01.01" }
    ] }
]
```

### 7.2d ChartOfCalculationTypes (План видов расчёта)

Ссылочный тип видов расчёта (без иерархии/владельцев). Общий с Catalog слой: `synonym`, `comment`,
`useStandardCommands`, `includeHelpInContents`, коды (`codeLength`/`codeType`/`codeAllowedLength`/`descriptionLength`),
`defaultPresentation`, `standardAttributes` (§7.1.1), `characteristics` (§7.1.4), `inputByString` (§7.1.5), формы (без
`*Folder*`), `basedOn`, `dataLockFields`, презентации.

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `codeLength` | `5` | CodeLength |
| `descriptionLength` | `100` | DescriptionLength |
| `codeAllowedLength` | `Variable` | CodeAllowedLength |
| `dependenceOnCalculationTypes` | `DontUse` | DependenceOnCalculationTypes (`DontUse`/`OnPeriod`/`OnActionPeriod`) |
| `baseCalculationTypes` | `[]` | BaseCalculationTypes (список ссылок на ПВР; `ПланВидовРасчета.X` → `ChartOfCalculationTypes.X`) |
| `actionPeriodUse` | `false` | ActionPeriodUse (использовать период действия) |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `dataHistory` + триплет | `DontUse`/`false`/`false` | DataHistory-триплет |
| `predefined` | `[]` | Ext/Predefined.xml — предопределённые виды расчёта |

Стандартные реквизиты ПВР: PredefinedDataName, Predefined, Ref, DeletionMark, ActionPeriodIsBasic, Description, Code
(профиль: Наименование → FillChecking=ShowError). Блок **условный** (`standardAttributes`). Всегда эмитятся три
платформенно-константных стандартных ТЧ: **LeadingCalculationTypes** (ведущие), **DisplacingCalculationTypes**
(вытесняющие), **BaseCalculationTypes** (базовые) — вложенный CalculationType → FillChecking=ShowError.

**Предопределённые виды расчёта** — плоские (без иерархии): короткая строка `"(Код) Имя [Наименование]"` ЛИБО объект
`{name, code, description, actionPeriodIsBase}`. `actionPeriodIsBase` (bool, дефолт false) → `<ActionPeriodIsBase>`;
при true — объектная форма.

```json
"predefined": [
  "(00001) Оклад [Оклад по дням]",
  { "name": "Премия", "code": "00002", "actionPeriodIsBase": true }
]
```

### 7.3 Enum

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `values` | `[]` | → EnumValue в ChildObjects |

Других настраиваемых свойств нет — все дефолтные.

### 7.4 Constant

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `valueType` | `String` | Type |
| `length` | — | Длина строки (если valueType=String) |
| `precision` | — | Точность числа (если valueType=Number) |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |

`valueType` + `length`/`precision` работают аналогично раздельной форме типа (§4.2):
`"valueType": "String", "length": 100` → `String(100)`.

### 7.5 InformationRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `writeMode` | `Independent` | WriteMode (Independent/RecorderSubordinate) |
| `periodicity` | `Nonperiodical` | InformationRegisterPeriodicity |
| `mainFilterOnPeriod` | `false` | MainFilterOnPeriod (не выводится из `periodicity` — задаётся явно) |
| `dataLockControlMode` | `Managed` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `editType` | `InDialog` | EditType |
| `useStandardCommands` | `true` | UseStandardCommands |
| `enableTotalsSliceFirst` / `enableTotalsSliceLast` | `false` | EnableTotalsSlice* (срез первых/последних) |
| `comment` | пусто | Comment |
| `recordPresentation` / `extendedRecordPresentation` / `listPresentation` / `extendedListPresentation` / `explanation` | пусто | презентации (ML) |
| `defaultRecordForm` / `defaultListForm` / `auxiliaryRecordForm` / `auxiliaryListForm` | пусто | *RecordForm/*ListForm (ссылка на форму) |
| `dataHistory` (+ триплет) | `DontUse` | DataHistory / UpdateDataHistoryImmediatelyAfterWrite / ExecuteAfterWriteDataHistoryVersionProcessing |
| `standardAttributes` | (блок всегда) | `""` — opt-out: подавить all-default блок стандартных реквизитов (~5% регистров его опускают, правило не выводимо) |
| `dimensions` | `[]` | → Dimension в ChildObjects (богатый object-слой реквизита + `master`/`mainFilter`/`denyIncompleteValues`) |
| `resources` | `[]` | → Resource в ChildObjects (богатый object-слой реквизита) |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `commands` | `[]` | → Command в ChildObjects (см. §7.1.3) |

Измерения/ресурсы РС поддерживают полный object-слой реквизита (synonym/tooltip/comment/type/fillValue/
choiceParameters/indexing/fullTextSearch/dataHistory/…, см. §3–4). Признаки измерения — флаги shorthand
(`master`/`mainFilter`/`denyIncomplete`) ЛИБО object-ключи (`master`/`mainFilter`/`denyIncompleteValues`: bool).
Флаг `master` дополнительно ставит `FillFromFillingValue=true` (конвенция ведущего измерения).

### 7.6 AccumulationRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `registerType` | `Balance` | RegisterType (Balance/Turnovers) |
| `enableTotalsSplitting` | `true` | EnableTotalsSplitting |
| `dataLockControlMode` | `Managed` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `useStandardCommands` | `true` | UseStandardCommands |
| `comment` | пусто | Comment |
| `listPresentation` / `extendedListPresentation` / `explanation` | пусто | презентации (ML) |
| `defaultListForm` / `auxiliaryListForm` | пусто | *ListForm (ссылка на форму) |
| `standardAttributes` | (блок всегда) | `""` — opt-out: подавить all-default блок (~9% регистров опускают) |
| `dimensions` | `[]` | → Dimension в ChildObjects (богатый object-слой + `denyIncomplete`/`useInTotals`) |
| `resources` | `[]` | → Resource в ChildObjects (богатый object-слой; без Indexing/DataHistory) |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `commands` | `[]` | → Command в ChildObjects (см. §7.1.3) |

Измерения/ресурсы РН поддерживают полный object-слой реквизита (synonym/tooltip/comment/type/choiceParameters/…, §3–4).
Признаки измерения — флаги shorthand (`denyIncomplete`, `nouseintotals`) ЛИБО object-ключи (`denyIncompleteValues`,
`useInTotals`: bool, дефолт true). Ресурс РН НЕ имеет `<Indexing>` (только `<FullTextSearch>`).

### 7.6a AccountingRegister (Регистр бухгалтерии)

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `chartOfAccounts` | пусто | ChartOfAccounts (MDObjectRef `ChartOfAccounts.X`) |
| `correspondence` | `false` | Correspondence (bool) |
| `periodAdjustmentLength` | `0` | PeriodAdjustmentLength (int) |
| `enableTotalsSplitting` | `true` | EnableTotalsSplitting |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| общие (comment/useStandardCommands/includeHelpInContents/defaultListForm/auxiliaryListForm/презентации ML) | — | — |
| `dimensions` / `resources` / `attributes` / `commands` | `[]` | → ChildObjects |

Измерения/ресурсы РБ несут `balance` (bool), `accountingFlag` (ссылка `ChartOfAccounts.X.AccountingFlag.Y`);
ресурсы дополнительно `extDimensionAccountingFlag`, измерения — `denyIncompleteValues`. Стандартные реквизиты
ExtDimension1..N связаны с Account через `linkByType` (в блоке `standardAttributes`, §7.1.1; DataPath полный).

### 7.6b CalculationRegister (Регистр расчёта)

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `chartOfCalculationTypes` | пусто | ChartOfCalculationTypes (ссылка) |
| `periodicity` | `Month` | Periodicity |
| `actionPeriod` / `basePeriod` | `false` | ActionPeriod / BasePeriod (bool) |
| `schedule` / `scheduleValue` / `scheduleDate` | пусто | Schedule* (ссылки на регистр-график и его поля) |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| общие (comment/useStandardCommands/includeHelpInContents/defaultListForm/auxiliaryListForm/презентации ML) | — | — |
| `dimensions` / `resources` / `attributes` / `commands` | `[]` | → ChildObjects |

Измерения РР несут `denyIncompleteValues`, `baseDimension` (bool), `scheduleLink` (ссылка на измерение графика);
реквизиты — `scheduleLink`; ресурсы — только `<FullTextSearch>` (без Indexing).

### 7.6c BusinessProcess (Бизнес-процесс)

Ссылочный тип с нумерацией (Document-стиль). Поля: `numberType`/`numberLength`/`numberAllowedLength`/`checkUnique`/
`autonumbering`/`numberPeriodicity` (нумерация); `task` (ссылка `Task.X`); `createTaskInPrivilegedMode` (bool, дефолт
true); `characteristics` (§7.1.4); `basedOn`/`inputByString`/`dataLockFields` (§7.1.5); `editType`/`createOnInput`/формы/
презентации; `dataLockControlMode` (дефолт **Managed**); DataHistory-триплет; `attributes`/`tabularSections`/`commands`.
Тип точки маршрута — `BusinessProcessRoutePointRef.X` (ссылка на маршрут самого БП).

### 7.6d Task (Задача)

Ссылочный тип адресных задач. Поля: нумерация (как БП) + `taskNumberAutoPrefix`/`descriptionLength`; `addressing`
(ссылка на регистр сведений исполнителей); `mainAddressingAttribute`/`currentPerformer` (ссылки); `defaultPresentation`;
`basedOn`/`characteristics`/`inputByString`/`dataLockFields`; формы/презентации; `dataLockControlMode` (дефолт **Managed**).
Дети: `attributes`, `commands` и **`addressingAttributes`** — реквизиты адресации (полный object-слой реквизита +
`addressingDimension`: ссылка на измерение регистра исполнителей).

### 7.7 DefinedType

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `valueTypes` | `[]` | Type (составной — массив `v8:Type`) |
| `valueType` | — | Алиас для `valueTypes` (принимает строку или массив) |

Без ChildObjects и модулей. Принимается как `valueTypes` (мн.ч.), так и `valueType` (ед.ч.).

```json
{ "type": "DefinedType", "name": "ДенежныеСредства", "valueTypes": ["CatalogRef.БанковскиеСчета", "CatalogRef.Кассы"] }
{ "type": "DefinedType", "name": "ФлагАктивности", "valueType": "Boolean" }
```

### 7.8 CommonModule

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `context` | — | Шорткат (см. ниже) |
| `global` | `false` | Global |
| `server` | `false` | Server |
| `serverCall` | `false` | ServerCall |
| `clientManagedApplication` | `false` | ClientManagedApplication |
| `clientOrdinaryApplication` | `false` | ClientOrdinaryApplication |
| `externalConnection` | `false` | ExternalConnection |
| `privileged` | `false` | Privileged |
| `returnValuesReuse` | `DontUse` | ReturnValuesReuse |

Шорткаты `context`:
- `"server"` → Server=true, ServerCall=true
- `"client"` → ClientManagedApplication=true
- `"serverClient"` → Server=true, ClientManagedApplication=true

Модуль: `Ext/Module.bsl` (пустой).

```json
{ "type": "CommonModule", "name": "ОбменДаннымиСервер", "context": "server", "returnValuesReuse": "DuringRequest" }
```

### 7.9 ScheduledJob

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `methodName` | `""` | MethodName (авто-префикс `CommonModule.`) |
| `description` | = synonym | Description |
| `key` | `""` | Key |
| `use` | `false` | Use |
| `predefined` | `false` | Predefined |
| `restartCountOnFailure` | `3` | RestartCountOnFailure |
| `restartIntervalOnFailure` | `10` | RestartIntervalOnFailure |

Без ChildObjects и модулей.

Формат `methodName`: `"МодульСервер.Процедура"` — при компиляции авто-дополняется до `CommonModule.МодульСервер.Процедура`. Если уже содержит `CommonModule.` — оставляется как есть.

```json
{ "type": "ScheduledJob", "name": "ОбменДанными", "methodName": "ОбменДаннымиСервер.Выполнить", "use": true }
```

### 7.10 EventSubscription

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `source` | `[]` | Source (массив `v8:Type`, формат `cfg:XxxObject.Name`) |
| `event` | `BeforeWrite` | Event |
| `handler` | `""` | Handler (авто-префикс `CommonModule.`) |

Без ChildObjects и модулей.

Значения `event`: `BeforeWrite`, `OnWrite`, `BeforeDelete`, `OnReadAtServer`, `FillCheckProcessing` и др.

Формат `handler`: `"МодульСервер.Процедура"` — при компиляции авто-дополняется до `CommonModule.МодульСервер.Процедура`. Если уже содержит `CommonModule.` — оставляется как есть.

```json
{ "type": "EventSubscription", "name": "ПередЗаписьюКонтрагента", "source": ["CatalogObject.Контрагенты"], "event": "BeforeWrite", "handler": "ОбщегоНазначенияСервер.ПередЗаписьюКонтрагента" }
```

### 7.11 Report

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `defaultForm` | `""` | DefaultForm |
| `auxiliaryForm` | `""` | AuxiliaryForm |
| `mainDataCompositionSchema` | `""` | MainDataCompositionSchema |
| `defaultSettingsForm` | `""` | DefaultSettingsForm |
| `auxiliarySettingsForm` | `""` | AuxiliarySettingsForm |
| `defaultVariantForm` | `""` | DefaultVariantForm |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

Модули: `Ext/ObjectModule.bsl` (пустой).

```json
{ "type": "Report", "name": "ОстаткиТоваров", "attributes": ["НачалоПериода: Date", "КонецПериода: Date"] }
```

### 7.12 DataProcessor

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `defaultForm` | `""` | DefaultForm |
| `auxiliaryForm` | `""` | AuxiliaryForm |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

Модули: `Ext/ObjectModule.bsl` (пустой).

```json
{ "type": "DataProcessor", "name": "ЗагрузкаДанных", "attributes": ["ПутьКФайлу: String(500)"] }
```

### 7.13 ExchangePlan

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `codeLength` | `9` | CodeLength |
| `codeAllowedLength` | `Variable` | CodeAllowedLength |
| `descriptionLength` | `100` | DescriptionLength |
| `distributedInfoBase` | `false` | DistributedInfoBase |
| `includeConfigurationExtensions` | `false` | IncludeConfigurationExtensions |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

Модули: `Ext/ObjectModule.bsl` (пустой).
Дополнительно: `Ext/Content.xml` — состав плана обмена (ключ `content`/`Состав`, см. §7.2a; пустой, если не задан).

```json
{ "type": "ExchangePlan", "name": "ОбменССайтом", "attributes": ["АдресСервера: String(200)"] }
```

### 7.14 ChartOfCharacteristicTypes

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `codeLength` | `9` | CodeLength |
| `codeType` | `String` | CodeType |
| `codeAllowedLength` | `Variable` | CodeAllowedLength |
| `descriptionLength` | `25` | DescriptionLength |
| `autonumbering` | `true` | Autonumbering |
| `checkUnique` | `false` | CheckUnique |
| `characteristicExtValues` | `""` | CharacteristicExtValues |
| `valueTypes` | авто* | Type (составной тип значений характеристик) |
| `hierarchical` | `false` | Hierarchical |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

\* Если `valueTypes` не указан, по умолчанию: Boolean, String(100), Number(15,2), DateTime.

Модули: `Ext/ObjectModule.bsl` (пустой).

```json
{
  "type": "ChartOfCharacteristicTypes", "name": "ВидыСубконто",
  "valueTypes": ["CatalogRef.Номенклатура", "CatalogRef.Контрагенты", "Boolean", "String", "Number(15,2)"]
}
```

### 7.15 DocumentJournal

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `defaultForm` | `""` | DefaultForm |
| `auxiliaryForm` | `""` | AuxiliaryForm |
| `registeredDocuments` | `[]` | RegisteredDocuments |
| `columns` | `[]` | → Column в ChildObjects |

Без модулей.

DSL для `registeredDocuments` — массив строк `"Document.ИмяДокумента"` (или русский `"Документ.ИмяДокумента"`).

DSL для `columns` (§12).

```json
{
  "type": "DocumentJournal", "name": "Взаимодействия",
  "registeredDocuments": ["Document.Встреча", "Document.ТелефонныйЗвонок"],
  "columns": [{ "name": "Организация", "indexing": "Index", "references": ["Document.Встреча.Attribute.Организация"] }]
}
```

### 7.16 ChartOfAccounts

Полное описание типа (все поля, стандартные реквизиты, грамматика предопределённых счетов) — см. **§7.2c**.

### 7.17 AccountingRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `chartOfAccounts` | `""` | ChartOfAccounts (ссылка на план счетов) |
| `correspondence` | `false` | Correspondence |
| `periodAdjustmentLength` | `0` | PeriodAdjustmentLength |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `dimensions` | `[]` | → Dimension в ChildObjects |
| `resources` | `[]` | → Resource в ChildObjects |
| `attributes` | `[]` | → Attribute в ChildObjects |

Модули: `Ext/RecordSetModule.bsl` (пустой).

```json
{
  "type": "AccountingRegister", "name": "Хозрасчетный",
  "chartOfAccounts": "ChartOfAccounts.Хозрасчетный", "correspondence": true,
  "dimensions": ["Организация: CatalogRef.Организации"],
  "resources": ["Сумма: Number(15,2)"]
}
```

### 7.18 ChartOfCalculationTypes

Полное описание типа (все поля, стандартные реквизиты, стандартные ТЧ, предопределённые виды расчёта) — см. **§7.2d**.

### 7.19 CalculationRegister

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `chartOfCalculationTypes` | `""` | ChartOfCalculationTypes (ссылка на ПВР) |
| `periodicity` | `Month` | Periodicity |
| `actionPeriod` | `false` | ActionPeriod |
| `basePeriod` | `false` | BasePeriod |
| `schedule` | `""` | Schedule (ссылка на РС графиков) |
| `scheduleValue` | `""` | ScheduleValue |
| `scheduleDate` | `""` | ScheduleDate |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `dimensions` | `[]` | → Dimension в ChildObjects |
| `resources` | `[]` | → Resource в ChildObjects |
| `attributes` | `[]` | → Attribute в ChildObjects |

Модули: `Ext/RecordSetModule.bsl` (пустой).

```json
{
  "type": "CalculationRegister", "name": "Начисления",
  "chartOfCalculationTypes": "ChartOfCalculationTypes.Начисления",
  "periodicity": "Month", "actionPeriod": true, "basePeriod": true,
  "dimensions": ["Сотрудник: CatalogRef.Сотрудники"],
  "resources": ["Сумма: Number(15,2)", "Дни: Number(3,0)"]
}
```

### 7.20 BusinessProcess

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `editType` | `InDialog` | EditType |
| `numberType` | `String` | NumberType |
| `numberLength` | `11` | NumberLength |
| `numberAllowedLength` | `Variable` | NumberAllowedLength |
| `checkUnique` | `true` | CheckUnique |
| `autonumbering` | `true` | Autonumbering |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `task` | `""` | Task (ссылка на Task.XXX) |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |

Модули: `Ext/ObjectModule.bsl` (пустой).
Дополнительно: `Ext/Flowchart.xml` (заглушка карты маршрута).

```json
{ "type": "BusinessProcess", "name": "Задание", "task": "Task.ЗадачаИсполнителя", "attributes": ["Описание: String(200)"] }
```

### 7.21 Task

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `numberType` | `String` | NumberType |
| `numberLength` | `14` | NumberLength |
| `numberAllowedLength` | `Variable` | NumberAllowedLength |
| `checkUnique` | `true` | CheckUnique |
| `autonumbering` | `true` | Autonumbering |
| `taskNumberAutoPrefix` | `BusinessProcessNumber` | TaskNumberAutoPrefix |
| `descriptionLength` | `150` | DescriptionLength |
| `addressing` | `""` | Addressing (ссылка на РС адресации) |
| `mainAddressingAttribute` | `""` | MainAddressingAttribute |
| `currentPerformer` | `""` | CurrentPerformer |
| `dataLockControlMode` | `Automatic` | DataLockControlMode |
| `fullTextSearch` | `Use` | FullTextSearch |
| `attributes` | `[]` | → Attribute в ChildObjects |
| `tabularSections` | `{}` | → TabularSection в ChildObjects |
| `addressingAttributes` | `[]` | → AddressingAttribute в ChildObjects (§15) |

Модули: `Ext/ObjectModule.bsl` (пустой).

```json
{
  "type": "Task", "name": "ЗадачаИсполнителя", "descriptionLength": 200,
  "addressing": "InformationRegister.АдресацияЗадач",
  "addressingAttributes": [{ "name": "Исполнитель", "type": "CatalogRef.Пользователи", "addressingDimension": "InformationRegister.АдресацияЗадач.Dimension.Исполнитель" }]
}
```

### 7.22 HTTPService

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `rootURL` | = имя (lowercase) | RootURL |
| `reuseSessions` | `DontUse` | ReuseSessions |
| `sessionMaxAge` | `20` | SessionMaxAge |
| `urlTemplates` | `{}` | → URLTemplate в ChildObjects (§16) |

Модули: `Ext/Module.bsl` (пустой).

```json
{
  "type": "HTTPService", "name": "API", "rootURL": "api",
  "urlTemplates": {
    "Users": { "template": "/v1/users", "methods": { "Get": "GET", "Create": "POST" } }
  }
}
```

### 7.23 WebService

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `namespace` | `""` | Namespace |
| `xdtoPackages` | `""` | XDTOPackages |
| `reuseSessions` | `DontUse` | ReuseSessions |
| `sessionMaxAge` | `20` | SessionMaxAge |
| `operations` | `{}` | → Operation в ChildObjects (§17) |

Модули: `Ext/Module.bsl` (пустой).

```json
{
  "type": "WebService", "name": "DataExchange", "namespace": "http://www.1c.ru/DataExchange",
  "operations": {
    "TestConnection": {
      "returnType": "xs:boolean",
      "handler": "ПроверкаПодключения",
      "parameters": { "ErrorMessage": { "type": "xs:string", "direction": "Out" } }
    }
  }
}
```

---

## 8. Русские синонимы типов объектов

| Русский | Канонический |
|---------|-------------|
| `Справочник` | `Catalog` |
| `Документ` | `Document` |
| `Перечисление` | `Enum` |
| `Константа` | `Constant` |
| `РегистрСведений` | `InformationRegister` |
| `РегистрНакопления` | `AccumulationRegister` |
| `РегистрБухгалтерии` | `AccountingRegister` |
| `РегистрРасчёта` | `CalculationRegister` |
| `ПланСчетов` | `ChartOfAccounts` |
| `ПланВидовХарактеристик` | `ChartOfCharacteristicTypes` |
| `ПланВидовРасчёта` | `ChartOfCalculationTypes` |
| `БизнесПроцесс` | `BusinessProcess` |
| `Задача` | `Task` |
| `ПланОбмена` | `ExchangePlan` |
| `ЖурналДокументов` | `DocumentJournal` |
| `Отчёт` | `Report` |
| `Обработка` | `DataProcessor` |
| `ОбщийМодуль` | `CommonModule` |
| `РегламентноеЗадание` | `ScheduledJob` |
| `ПодпискаНаСобытие` | `EventSubscription` |
| `HTTPСервис` | `HTTPService` |
| `ВебСервис` | `WebService` |
| `ОпределяемыйТип` | `DefinedType` |

---

## 9. RegisterRecords для документов

```json
"registerRecords": [
  "AccumulationRegister.Продажи",
  "InformationRegister.Цены"
]
```

Или с русскими синонимами: `"РегистрНакопления.Продажи"`.

---

## 10. Измерения и ресурсы регистров

Синтаксис аналогичен реквизитам (§4), но с дополнительными флагами:

### Измерения (dimensions)

```json
"dimensions": [
  "Организация: CatalogRef.Организации | master, mainFilter, denyIncomplete",
  "Номенклатура: CatalogRef.Номенклатура"
]
```

### Ресурсы (resources)

```json
"resources": [
  "Количество: Number(15,3)",
  "Сумма: Number(15,2)"
]
```

Флаг `useInTotals` — только для измерений AccumulationRegister (по умолчанию `true`).

Применимо к: InformationRegister, AccumulationRegister, AccountingRegister, CalculationRegister.

---

## 11. Примеры

### Минимальные

```json
{ "type": "Catalog", "name": "Валюты" }
```

```json
{ "type": "Enum", "name": "Статусы", "values": ["Новый", "Закрыт"] }
```

```json
{ "type": "Constant", "name": "ОсновнаяВалюта", "valueType": "CatalogRef.Валюты" }
```

### Справочник с реквизитами и табличной частью

```json
{
  "type": "Catalog",
  "name": "Номенклатура",
  "codeLength": 11,
  "descriptionLength": 100,
  "hierarchical": true,
  "attributes": [
    "Артикул: String(25)",
    "ЕдиницаИзмерения: CatalogRef.ЕдиницыИзмерения | req",
    "ВидНоменклатуры: EnumRef.ВидыНоменклатуры",
    "Цена: Number(15,2)"
  ],
  "tabularSections": {
    "Штрихкоды": [
      "Штрихкод: String(200) | req, index"
    ]
  }
}
```

### Документ с движениями

```json
{
  "type": "Document",
  "name": "РеализацияТоваров",
  "posting": "Allow",
  "registerRecords": ["AccumulationRegister.Продажи"],
  "attributes": [
    "Организация: CatalogRef.Организации | req",
    "Контрагент: CatalogRef.Контрагенты | req",
    "Склад: CatalogRef.Склады"
  ],
  "tabularSections": {
    "Товары": [
      "Номенклатура: CatalogRef.Номенклатура | req",
      "Количество: Number(15,3)",
      "Цена: Number(15,2)",
      "Сумма: Number(15,2)"
    ]
  }
}
```

### Регистр сведений с периодичностью

```json
{
  "type": "InformationRegister",
  "name": "КурсыВалют",
  "periodicity": "Day",
  "dimensions": [
    "Валюта: CatalogRef.Валюты | master, mainFilter, denyIncomplete"
  ],
  "resources": [
    "Курс: Number(15,4)",
    "Кратность: Number(10,0)"
  ]
}
```

### Регистр накопления

```json
{
  "type": "AccumulationRegister",
  "name": "ОстаткиТоваров",
  "registerType": "Balance",
  "dimensions": [
    "Номенклатура: CatalogRef.Номенклатура",
    "Склад: CatalogRef.Склады"
  ],
  "resources": [
    "Количество: Number(15,3)"
  ]
}
```

### Определяемый тип

```json
{ "type": "DefinedType", "name": "ДенежныеСредства", "valueTypes": ["CatalogRef.БанковскиеСчета", "CatalogRef.Кассы"] }
```

### Общий модуль

```json
{ "type": "CommonModule", "name": "ОбменДаннымиСервер", "context": "server", "returnValuesReuse": "DuringRequest" }
```

### План обмена

```json
{ "type": "ExchangePlan", "name": "ОбменССайтом", "attributes": ["АдресСервера: String(200)"] }
```

### Журнал документов

```json
{
  "type": "DocumentJournal", "name": "Взаимодействия",
  "registeredDocuments": ["Document.Встреча", "Document.ТелефонныйЗвонок"],
  "columns": [{ "name": "Организация", "indexing": "Index", "references": ["Document.Встреча.Attribute.Организация"] }]
}
```

### План счетов

```json
{
  "type": "ChartOfAccounts", "name": "Хозрасчетный",
  "extDimensionTypes": "ChartOfCharacteristicTypes.ВидыСубконто", "maxExtDimensionCount": 3,
  "codeMask": "@@@.@@.@", "codeLength": 8,
  "accountingFlags": ["Валютный", "Количественный"],
  "extDimensionAccountingFlags": ["Суммовой", "Валютный"]
}
```

### HTTP-сервис

```json
{
  "type": "HTTPService", "name": "API", "rootURL": "api",
  "urlTemplates": {
    "Users": { "template": "/v1/users", "methods": { "Get": "GET", "Create": "POST" } }
  }
}
```

### Веб-сервис

```json
{
  "type": "WebService", "name": "DataExchange", "namespace": "http://www.1c.ru/DataExchange",
  "operations": {
    "TestConnection": {
      "returnType": "xs:boolean",
      "handler": "ПроверкаПодключения",
      "parameters": { "ErrorMessage": { "type": "xs:string", "direction": "Out" } }
    }
  }
}
```

### Бизнес-процесс

```json
{ "type": "BusinessProcess", "name": "Задание", "task": "Task.ЗадачаИсполнителя", "attributes": ["Описание: String(200)"] }
```

### Задача

```json
{
  "type": "Task", "name": "ЗадачаИсполнителя", "descriptionLength": 200,
  "addressing": "InformationRegister.АдресацияЗадач",
  "addressingAttributes": [{ "name": "Исполнитель", "type": "CatalogRef.Пользователи" }]
}
```

---

## 12. Графы журнала документов (columns)

Только для DocumentJournal.

### Строковая форма

```json
"columns": ["Организация", "Контрагент"]
```

Создаёт графу без ссылок, без индексации.

### Объектная форма

```json
"columns": [
  {
    "name": "Организация",
    "synonym": "Организация",
    "indexing": "Index",
    "references": [
      "Document.Встреча.Attribute.Организация",
      "Document.ТелефонныйЗвонок.Attribute.Организация"
    ]
  }
]
```

| Поле | Умолчание | Описание |
|------|----------|----------|
| `name` | — | Имя графы (обязательное) |
| `synonym` | авто | Синоним |
| `indexing` | `DontIndex` | `DontIndex` / `Index` |
| `references` | `[]` | Ссылки на реквизиты регистрируемых документов |

---

## 13. Признаки учёта (accountingFlags)

Только для ChartOfAccounts.

```json
"accountingFlags": ["Валютный", "Количественный"]
```

Массив имён. Каждый признак — Boolean-тип. Синоним авто из CamelCase.

---

## 14. Признаки учёта субконто (extDimensionAccountingFlags)

Только для ChartOfAccounts.

```json
"extDimensionAccountingFlags": ["Суммовой", "Валютный"]
```

Аналогично accountingFlags, но применяется к субконто (ExtDimensionTypes).

---

## 15. Реквизиты адресации (addressingAttributes)

Только для Task.

### Строковая форма

```json
"addressingAttributes": ["Исполнитель"]
```

### Объектная форма

```json
"addressingAttributes": [
  {
    "name": "Исполнитель",
    "type": "CatalogRef.Пользователи",
    "addressingDimension": "InformationRegister.АдресацияЗадач.Dimension.Исполнитель"
  }
]
```

| Поле | Умолчание | Описание |
|------|----------|----------|
| `name` | — | Имя реквизита (обязательное) |
| `type` | `String` | Тип значения |
| `synonym` | авто | Синоним |
| `addressingDimension` | `""` | Ссылка на измерение регистра адресации |

---

## 16. URL-шаблоны HTTP-сервиса (urlTemplates)

Только для HTTPService.

```json
"urlTemplates": {
  "Users": {
    "template": "/v1/users",
    "methods": {
      "Get": "GET",
      "Create": "POST"
    }
  }
}
```

Ключ — имя шаблона. Значение — объект:

| Поле | Умолчание | Описание |
|------|----------|----------|
| `template` | `/{name}` | URL-шаблон (строка) |
| `methods` | `{}` | Имя метода → HTTP-метод (`GET`, `POST`, `PUT`, `DELETE`, `PATCH`) |

Обработчик метода авто: `{TemplateName}{MethodName}` (напр. `UsersGet`).

Если значение — строка, интерпретируется как `template` без методов.

---

## 17. Операции веб-сервиса (operations)

Только для WebService.

```json
"operations": {
  "TestConnection": {
    "returnType": "xs:boolean",
    "handler": "ПроверкаПодключения",
    "nillable": false,
    "transactioned": false,
    "parameters": {
      "ErrorMessage": {
        "type": "xs:string",
        "nillable": true,
        "direction": "Out"
      }
    }
  }
}
```

Ключ — имя операции. Значение — объект:

| Поле | Умолчание | Описание |
|------|----------|----------|
| `returnType` | `xs:string` | XDTO-тип возвращаемого значения |
| `handler` | = имя операции | Имя процедуры-обработчика |
| `nillable` | `false` | Может ли возвращать null |
| `transactioned` | `false` | Выполняется в транзакции |
| `parameters` | `{}` | Параметры операции |

Если значение — строка, интерпретируется как `returnType`.

### Параметры операции

| Поле | Умолчание | Описание |
|------|----------|----------|
| `type` | `xs:string` | XDTO-тип параметра |
| `nillable` | `true` | Может ли быть null |
| `direction` | `In` | Направление: `In` / `Out` / `InOut` |

Если значение — строка, интерпретируется как `type`.
