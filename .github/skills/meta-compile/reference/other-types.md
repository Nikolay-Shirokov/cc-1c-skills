# Прочие типы

Редкие/служебные объекты. Каждый — минимальный набор свойств.

## FunctionalOption (Функциональная опция)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `location` | пусто | где хранится значение: `Constant.X` / `InformationRegister.X.Resource.Y` / `<Тип>.X.Attribute.Y` |
| `content` | `[]` | реквизиты/измерения/ресурсы, зависящие от опции (полные пути к объектам) |
| `privilegedGetMode` | `true` | bool |
| `comment` | пусто | строка |

```json
{ "type": "FunctionalOption", "name": "ВестиУчетПоСкладам", "location": "Constant.ВестиУчетПоСкладам",
  "content": ["Document.РеализацияТоваров.TabularSection.Товары.Attribute.Склад"] }
```

## FilterCriterion (Критерий отбора)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `valueType` | — | тип значения отбора (составной через `+`) |
| `content` | `[]` | реквизиты, по которым идёт отбор (пути к объектам) |
| `useStandardCommands` | `true` | bool |
| `defaultForm` / `auxiliaryForm` | пусто | формы |
| `comment` | пусто | строка |

```json
{ "type": "FilterCriterion", "name": "ДокументыПоКонтрагенту", "valueType": "CatalogRef.Контрагенты",
  "content": ["Document.Реализация.Attribute.Контрагент"] }
```

## SettingsStorage (Хранилище настроек)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `defaultSaveForm` / `defaultLoadForm` | пусто | формы сохранения / загрузки |
| `auxiliarySaveForm` / `auxiliaryLoadForm` | пусто | вспомогательные формы |
| `comment` | пусто | строка |

## CommonForm (Общая форма)

Создаёт метаданные + заготовку формы. Содержимое формы наполняется `/form-compile` или `/form-edit`.

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `formType` | `Managed` | тип формы |
| `usePurposes` | `[PlatformApplication, MobilePlatformApplication]` | назначение (массив) |
| `useStandardCommands` | `false` | bool |
| `includeHelpInContents` | `false` | bool |
| `comment` | пусто | строка |

```json
{ "type": "CommonForm", "name": "НастройкиОбмена", "usePurposes": ["PlatformApplication"] }
```

## CommonPicture / CommonTemplate (Общие картинки и макеты)

Только метаданные + регистрация; содержимое (`Ext/Picture*`, `Ext/Template.*`) импортируется отдельно
(для табличного макета — `/mxl-compile`).

- **CommonPicture** — `availabilityForChoice` / `availabilityForAppearance` (bool, по умолчанию `false`).
- **CommonTemplate** — `templateType` (`SpreadsheetDocument` по умолчанию / `TextDocument` / `HTMLDocument` /
  `BinaryData` / `AddIn` / `DataCompositionSchema` / `DataCompositionAppearanceTemplate` / `GraphicalSchema`).

```json
{ "type": "CommonTemplate", "name": "ПечатьЗаказа", "templateType": "SpreadsheetDocument" }
```

## Служебные типы

- **SessionParameter** (параметр сеанса) — `valueType` (тип значения, составной через `+`).
- **FunctionalOptionsParameter** (параметр функциональной опции) — `use` (массив измерений/реквизитов).
- **WSReference** (WS-ссылка) — `locationURL` (URL WSDL).
- **CommandGroup** (группа команд) — `category` (по умолч. `NavigationPanel`) — где размещается группа:
  `NavigationPanel` / `ActionsPanel` (командный интерфейс раздела) или `FormCommandBar` / `FormNavigationPanel`
  (командный интерфейс формы); `representation` (`Auto`), `tooltip` (ML), `picture`. Команды объекта ссылаются на
  группу через `group: "CommandGroup.<Имя>"` (см. `blocks.md`).
- **CommonCommand** (общая команда) — `group`, `representation`, `tooltip`, `picture`, `shortcut`,
  `commandParameterType`, `parameterUseMode` (`Single`/`Multiple`), `modifiesData`, `includeHelpInContents`.
  Создаёт `Ext/CommandModule.bsl`.
- **CommonAttribute** (общий реквизит) — `valueType` (по умолчанию `String(0)`) + свойства реквизита
  (`attributes.md`) + `content` (объекты, куда входит реквизит) + свойства разделения данных
  (`dataSeparation`, `separatedDataUse`, `usersSeparation`, … — по умолчанию `DontUse`/`Independently`).

```json
{ "type": "CommonAttribute", "name": "Организация", "valueType": "CatalogRef.Организации",
  "autoUse": "Use", "content": ["Document.РеализацияТоваров", "Document.ПоступлениеТоваров"] }
```
