# Form DSL Specification

Спецификация JSON-формата для `/form-compile` — компактного описания управляемых форм 1С:Предприятия 8.3.

---

## 1. Корневой объект

```json
{
  "title": "Заголовок формы",
  "properties": { ... },
  "excludedCommands": [ ... ],
  "events": { ... },
  "elements": [ ... ],
  "attributes": [ ... ],
  "parameters": [ ... ],
  "commands": [ ... ]
}
```

| Поле | Тип | Описание |
|------|-----|----------|
| `title` | string | Заголовок формы (необязательный) |
| `properties` | object | Свойства формы (необязательный) |
| `excludedCommands` | string[] | Исключённые стандартные команды (необязательный) |
| `mobileCommandBarContent` | string[] | Состав командной панели моб. устройства — список имён командных панелей/кнопок (`<MobileDeviceCommandBarContent>`). Константы (Presentation/CheckState=0/xs:string) ставит компилятор |
| `events` | object | Обработчики событий формы (необязательный) |
| `elements` | array | Дерево UI-элементов (необязательный) |
| `attributes` | array | Реквизиты формы (необязательный) |
| `parameters` | array | Параметры формы (необязательный) |
| `commands` | array | Команды формы (необязательный) |

---

## 2. Properties — свойства формы

Объект со свойствами в camelCase. Компилятор преобразует в PascalCase для XML.

```json
"properties": {
  "autoTitle": false,
  "windowOpeningMode": "LockOwnerWindow",
  "commandBarLocation": "Bottom"
}
```

### Поддерживаемые свойства

| DSL ключ | XML элемент | Значения |
|----------|-------------|----------|
| `autoTitle` | `<AutoTitle>` | `true` / `false`. **При наличии `title` компилятор сам инъектит `false`** (≈95% форм). Маркер `""` подавляет инъекцию (редкие формы с title, но без `<AutoTitle>`) |
| `saveWindowSettings` | `<SaveWindowSettings>` | `true` / `false` |
| `windowOpeningMode` | `<WindowOpeningMode>` | `LockOwnerWindow`, `Modeless` |
| `commandBarLocation` | `<CommandBarLocation>` | `Top`, `Bottom`, `None` |
| `saveDataInSettings` | `<SaveDataInSettings>` | `UseList`, `Use`, `DontUse` |
| `autoSaveDataInSettings` | `<AutoSaveDataInSettings>` | `Use`, `DontUse` |
| `autoTime` | `<AutoTime>` | `CurrentOrLast`, `Current`, `Last` |
| `usePostingMode` | `<UsePostingMode>` | `Auto`, `Postings`, `Movements` |
| `repostOnWrite` | `<RepostOnWrite>` | `true` / `false` |
| `autoURL` | `<AutoURL>` | `true` / `false` |
| `autoFillCheck` | `<AutoFillCheck>` | `true` / `false` |
| `customizable` | `<Customizable>` | `true` / `false` |
| `enterKeyBehavior` | `<EnterKeyBehavior>` | `DefaultButton`, `NewLine` |
| `verticalScroll` | `<VerticalScroll>` | `useIfNecessary`, `Auto`, `AlwaysShow`, `Never` |
| `width` | `<Width>` | число |
| `height` | `<Height>` | число |
| `group` | `<Group>` | `Vertical`, `Horizontal`, `AlwaysHorizontal`, `AlwaysVertical`, `HorizontalIfPossible` |
| `useForFoldersAndItems` | `<UseForFoldersAndItems>` | `Folders`, `Items`, `FoldersAndItems` |
| `reportResult` | `<ReportResult>` | Имя реквизита-результата (форма отчёта) |
| `detailsData` | `<DetailsData>` | Имя реквизита данных расшифровки (форма отчёта) |
| `reportFormType` | `<ReportFormType>` | `Main`, `Settings`, `Variant` |
| `autoShowState` | `<AutoShowState>` | `Auto`, `DontShow`, `ShowOnComposition` |
| `reportResultViewMode` | `<ReportResultViewMode>` | `Auto` |
| `viewModeApplicationOnSetReportResult` | `<ViewModeApplicationOnSetReportResult>` | `Auto` |
| `variantAppearance` | `<VariantAppearance>` | Имя реквизита оформления варианта (форма отчёта) |

Нераспознанные ключи преобразуются с автоматическим PascalCase (первая буква в верхний регистр).

---

## 3. Events — обработчики событий формы

```json
"events": {
  "OnCreateAtServer": "ПриСозданииНаСервере",
  "OnOpen": "ПриОткрытии"
}
```

Ключ — имя события, значение — имя процедуры-обработчика. **Тот же формат `events` используется и на элементах** (§4.1) — единый способ описания событий во всём DSL.

### Доступные события

| Событие | Описание |
|---------|----------|
| `OnCreateAtServer` | Создание формы на сервере |
| `OnOpen` | Открытие формы |
| `BeforeClose` | Перед закрытием |
| `OnClose` | При закрытии |
| `BeforeWrite` | Перед записью |
| `BeforeWriteAtServer` | Перед записью на сервере |
| `OnWriteAtServer` | При записи на сервере |
| `AfterWriteAtServer` | После записи на сервере |
| `AfterWrite` | После записи |
| `OnReadAtServer` | При чтении объекта |
| `NotificationProcessing` | Обработка оповещений |
| `ChoiceProcessing` | Обработка выбора |
| `FillCheckProcessingAtServer` | Проверка заполнения |

---

## 4. Elements — дерево UI-элементов

Массив объектов. Тип элемента определяется ключом-идентификатором.

### 4.1. Общие свойства всех элементов

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя элемента (по умолчанию — из значения ключа типа) |
| `title` | string/object | Заголовок. **Нет ключа** → авто-вывод из имени (для page/popup/label и непривязанных полей/кнопок). **`""`** → подавить (заголовок не выводится). Строка → ru. Объект `{ "ru": "…", "en": "…" }` → мультиязычный (по `<v8:item>` на язык). Так же `tooltip`/`inputHint`/`title` команд/реквизитов/колонок |
| `titleDataPath` | string | Путь данных динамического заголовка (`<TitleDataPath>`) — у Page/UsualGroup (напр. `Объект.Товары.RowsCount` в заголовке страницы). Парный к `footerDataPath` (путь данных подвала поля) |
| `hidden` | bool | `true` → `<Visible>false</Visible>` |
| `disabled` | bool | `true` → `<Enabled>false</Enabled>` |
| `readOnly` | bool | `true` → `<ReadOnly>true</ReadOnly>` |
| `userVisible` | bool/object | Пользовательская видимость по ролям (`<UserVisible>`). См. §4.1c. Отсутствие = виден всем |
| `commandBar` | object/array | Командная панель элемента (companion `<AutoCommandBar>`) с контентом. См. §4.1d |
| `contextMenu` | object/array | Контекстное меню элемента (companion `<ContextMenu>`) с контентом. См. §4.1d |
| `events` | object | Обработчики событий: `{ "ИмяСобытия": "ИмяОбработчика" }` — тот же формат, что у событий формы (§3). Значение `null` → имя по конвенции (§4.2). См. §4.2 |
| `titleLocation` | string | Расположение заголовка: `none`/`left`/`right`/`top`/`bottom`/`auto`. Эмитится при наличии (input, labelField, picField, table, calendar). У `check`/`radio` — особая семантика с умным дефолтом (см. их разделы) |
| `tooltip` | string/object | Всплывающая подсказка элемента (`<ToolTip>`). Строка → ru, объект `{ "ru": …, "en": … }` → мультиязычный (как `title`). Эмитится сразу после `title` |
| `tooltipRepresentation` | string | Режим показа подсказки (`<ToolTipRepresentation>`): `None`, `Button`, `ShowBottom`, `ShowTop`, `ShowLeft`, `ShowRight`, `ShowAuto`, `Balloon`. Эмитится при наличии |
| `displayImportance` | string | Важность отображения (атрибут открывающего тега `DisplayImportance`): `VeryHigh`, `High`, `Usual`, `Low`, `VeryLow`. Адаптивная раскладка (моб./узкие формы). Применимо к любому элементу |
| `extendedTooltip` | string/object | Расширенная подсказка (companion `<ExtendedTooltip>`, по сути LabelDecoration). **Текст-форма**: строка / ML / `{text, formatted}`. **Own-content форма** (объект с layout/оформлением/флагами): `{ text?, formatted?, width?, autoMaxWidth?, maxWidth?, height?, horizontalStretch?, verticalAlign?, titleHeight?, hyperlink?, visible?, enabled?, textColor?, font?, … }` — own-content эмитится перед `Title`. (События компаньона пока не поддержаны.) Синоним: `extTooltip` |

#### Форма ML-текста и `formatted`

`title`/`tooltip`/`extendedTooltip` принимают:
- `"строка"` — ru-текст;
- `{ "ru": "…", "en": "…" }` — многоязычный;
- `{ "text": <строка|мапа>, "formatted": true }` — **форматированный** текст (атрибут `<Title formatted="true">`).

**`formatted`** включает интерпретацию inline-разметки в тексте (1С-формат, похож на BBCode): `<b>…</>`, `<i>`, `<u>`, `<color web:Red>…</>`, `<bgColor …>`, `<font …>`, `<fontSize …>`, `<link URL>…</>`, `<img …>`; закрывающий тег — `</>`. Текст несётся **raw** (разметка — часть строки), парсинг не требуется.

Флаг авто-детектится по наличию известной разметки/`</>`: для plain-строки объект не нужен. Явная форма `{text, formatted}` — только когда авто-детект неверен (formatted-текст без разметки, либо буквальные `<…>`-плейсхолдеры в неформатированном).

#### Русские синонимы ключей-свойств (прощающий ввод)

Скалярные свойства элементов можно писать русскими именами 1С (как в Конфигураторе) — компилятор молча нормализует их в канонические англ. ключи. Сопоставление **регистро- и пробело-независимое** (`Пометка` = `пометка`, `Быстрый выбор` = `быстрыйВыбор`). Англ. ключ работает всегда; если заданы оба — побеждает англ. Поддержаны (в т.ч.): `Пометка`→`checked`, `Заголовок`→`title`, `Ширина`→`width`, `Высота`→`height`, `КнопкаВыбора`→`choiceButton`, `КнопкаОчистки`→`clearButton`, `КнопкаВыпадающегоСписка`→`dropListButton`, `КнопкаСписковогоВыбора`→`choiceListButton`, `БыстрыйВыбор`→`quickChoice`, `ФормаВыбора`→`choiceForm`, `ИсторияВыбораПриВводе`→`choiceHistoryOnInput`, `ВыборГруппИЭлементов`→`choiceFoldersAndItems`, `ФиксацияВТаблице`→`fixingInTable`, `ПутьКДаннымПодвала`→`footerDataPath`, `МногострочныйРежим`→`multiLine`, `РежимПароля`→`passwordMode`, `РасположениеЗаголовка`→`titleLocation`. (`Видимость`/`Доступность` НЕ синонимы — у нас `hidden`/`disabled` с обратной полярностью.) Оформление имеет свой набор рус. синонимов (§4.1e).

### 4.1c. Доступ по ролям (`userVisible` / `view` / `edit` / `use`)

Единый механизм платформы (role-adjustable boolean): «общее значение + исключения по ролям».
Один и тот же грамматик-значения у разных ключей на разных владельцах:

| Ключ | Владелец | XML-тег | Смысл |
|------|----------|---------|-------|
| `userVisible` | элемент (§4.1) | `<UserVisible>` | пользовательская видимость |
| `view` | реквизит (§5) | `<View>` | просмотр |
| `edit` | реквизит (§5) | `<Edit>` | редактирование |
| `use` | команда (§7) | `<Use>` | доступность команды |

**Значение** (общее для всех четырёх):
- скаляр `false`/`true` → только `<xr:Common>`, без ролей (массовый случай, особенно `userVisible: false`);
- объект `{ "common": <bool>, "roles": { "ИмяРоли": <bool>, … } }` → `<xr:Common>` + по `<xr:Value name="Role.ИмяРоли">` на каждое исключение.

Семантика как в конфигураторе (три состояния флага роли): роль, **не указанная** в `roles`, наследует `common`; указанная — задаёт явный `true`/`false` (может совпадать с `common`).

**Имя роли** — forgiving: принимается без префикса (`ПолныеПрава`), с `Role.` или кириллическим `Роль.`; нормализуется в `Role.ИмяРоли`.

**Отсутствие ключа** = полный доступ (платформа тег не пишет) — дефолт не эмитим.

```jsonc
{ "inputField": "Поле", "userVisible": false }                                  // скрыт у всех
{ "name": "Реквизит", "view": false,                                            // не виден…
  "edit": { "common": false, "roles": { "ПолныеПрава": true } } }               // …и редактируем только Полными правами
{ "name": "Команда", "use": { "common": false, "roles": { "Роль.Бухгалтер": true } } }
```

### 4.1d. Companion-панели элемента (`commandBar` / `contextMenu`)

Командная панель (`<AutoCommandBar>`) и контекстное меню (`<ContextMenu>`) элемента — это
companion-панели с собственным контентом. Оба несут одну грамматику.

| Ключ | XML companion | Forgiving-синонимы (при объект/массив-значении) |
|------|---------------|--------------------------------------------------|
| `commandBar` | `<AutoCommandBar>` | `autoCommandBar`, `AutoCommandBar`, `autoCmdBar`, `cmdBar`, `КоманднаяПанель` |
| `contextMenu` | `<ContextMenu>` | `ContextMenu`, `КонтекстноеМеню` |

**Значение** (обе формы):
- массив `[ … ]` → shorthand для `{ "children": [ … ] }`;
- объект `{ "autofill"?: bool, "children": [ … ] }` (+ `horizontalAlign` у `commandBar`).

`children` — обычная грамматика кнопок: `button` (с `command`/`commandName`/`stdCommand`), `buttonGroup`, `popup`.

- `autofill`: `false` → подавить автозаполнение (тег `<Autofill>false</Autofill>`); `true` или отсутствие → автозаполнение (платформенный дефолт, тег **не пишется**). Платформа `Autofill=true` не эмитит никогда.
- Отсутствие свойства целиком → пустой companion (как обычно).
- **Дин-список-таблица**: компилятор по эвристике подавляет её панель (`autofill=false`), чтобы не дублировать командную панель формы. Чтобы оставить панель таблицы (она автозаполняется) — задайте явно `commandBar: { "autofill": true }`.

**Разведение тип-элемента и панель-свойства — по типу значения:** `cmdBar: "Имя"` (строка) — это
отдельный элемент-панель в дереве (§4.3); `commandBar: { … }` (объект/массив) — companion-панель *данного*
элемента. Поэтому модель может писать панель таблицы любым знакомым словом.

```jsonc
{ "table": "Список", "path": "Список",
  "commandBar": { "autofill": false, "children": [
    { "button": "Создать", "command": "СоздатьЭлемент" } ] },
  "contextMenu": { "children": [
    { "button": "Карта", "commandName": "CommonCommand.КартаМаршрута" } ] } }
```

### 4.1e. Оформление элемента (цвета / шрифты / граница)

Прямые свойства оформления элемента. Ключи — англ. camelCase 1:1 с тегами; **принимаются рус. синонимы** (forgiving). Применимо к полям (input/check/radio/labelField/picField/calendar), декорациям (label/picture), кнопкам (button), группам (group/columnGroup) и таблицам (table); порядок тегов в XML — по базовому типу (профиль), компилятор расставляет сам (1С толерантна к порядку оформления внутри элемента).

| Ключ | Тег | Рус. синоним |
|------|-----|--------------|
| `textColor` / `backColor` / `borderColor` | `<TextColor>`/`<BackColor>`/`<BorderColor>` | `ЦветТекста` / `ЦветФона` / `ЦветРамки` |
| `titleTextColor` / `titleBackColor` / `titleFont` | `<Title*>` (заголовок колонки) | `ЦветТекстаЗаголовка` / `ЦветФонаЗаголовка` / `ШрифтЗаголовка` |
| `footerTextColor` / `footerBackColor` / `footerFont` | `<Footer*>` (подвал колонки) | `ЦветТекстаПодвала` / `ЦветФонаПодвала` / `ШрифтПодвала` |
| `font` | `<Font>` | `Шрифт` |
| `border` | `<Border>` | `Рамка` |

**Цвет** — строка verbatim (компилятор не валидирует, эмитит как есть): `style:ИмяСтиля` (ссылка на элемент стиля конфигурации/платформы), `web:Имя` (web-палитра, напр. `web:FireBrick`), `win:Имя` (системная палитра Windows, напр. `win:MenuBar`, `win:ButtonText`, `win:DisabledText`), `#RRGGBB` (RGB-hex). Имя должно существовать в своей палитре (несуществующее, напр. `win:InactiveTitleBar`, или ссылка на отсутствующий `style:X` — приводит к ошибке загрузки). Префикс `sys:` в типовых выгрузках не встречается.

**Шрифт** (`font`/`titleFont`/`footerFont`):
- строка `"style:X"` → `<Font ref="style:X" kind="StyleItem"/>` (минимальная форма, платформа её принимает);
- объект — эмитятся **только указанные** атрибуты (дефолты не досочиняются): `{ ref?, faceName?, height?, bold?, italic?, underline?, strikeout?, kind?, scale? }`. Для `kind="Absolute"` задают `faceName`+`height`; для `WindowsFont` — `ref="sys:…"`.

**Граница** (`border`):
- строка `"style:X"` (или `{ ref }`) → `<Border ref="style:X"/>` (граница из стиля);
- объект `{ width, style }` → `<Border width="N"><v8ui:style…>СТИЛЬ</v8ui:style></Border>`. `style` — системное перечисление `ControlBorderType`: `Single`, `Double`, `Underline`, `DoubleUnderline`, `Overline`, `Embossed`, `Indented`, `WithoutBorder`.

```json
{ "label": "Внимание!", "textColor": "web:FireBrick",
  "font": { "faceName": "Arial", "height": 12, "bold": true, "kind": "Absolute", "scale": 100 },
  "border": { "width": 1, "style": "Single" } }
{ "input": "Цена", "path": "Объект.Цена", "textColor": "#FF0000", "borderColor": "style:BorderColor" }
{ "labelField": "Код", "цветТекстаЗаголовка": "web:HoneyDew", "border": "style:ControlBorder" }
```

### 4.1a. Общие layout-свойства

Применимы к любому элементу (размеры, растягивание, выравнивание внутри родителя). Эмитятся только при указании.

| Свойство | XML | Значения |
|----------|-----|----------|
| `width` | `<Width>` | число |
| `height` | `<Height>` | число (высота элемента; у `table` — тоже `<Height>`. Высота в строках таблицы — отдельный ключ `heightInTableRows`, см. §table) |
| `horizontalStretch` | `<HorizontalStretch>` | `true`/`false` (эмитится явное значение; отсутствие = дефолт) |
| `verticalStretch` | `<VerticalStretch>` | `true`/`false` (аналогично) |
| `autoMaxWidth` | `<AutoMaxWidth>` | `false` (у `input` при `multiLine` подставляется автоматически) |
| `autoMaxHeight` | `<AutoMaxHeight>` | `false` |
| `maxWidth` | `<MaxWidth>` | число |
| `maxHeight` | `<MaxHeight>` | число |
| `groupHorizontalAlign` | `<GroupHorizontalAlign>` | `Left`, `Center`, `Right` |
| `groupVerticalAlign` | `<GroupVerticalAlign>` | `Top`, `Center`, `Bottom` |
| `horizontalAlign` | `<HorizontalAlign>` | `Left`, `Center`, `Right` |
| `skipOnInput` | `<SkipOnInput>` | `true`/`false` (эмитится явное значение, в т.ч. `false`) |
| `defaultItem` | `<DefaultItem>` | `true` (элемент активируется по умолчанию) |
| `enableStartDrag` | `<EnableStartDrag>` | `true` (разрешить начало перетаскивания) |
| `fileDragMode` | `<FileDragMode>` | `AsFile`/… (режим drag-n-drop файлов) |
| `showInHeader` | `<ShowInHeader>` | bool — показывать в шапке таблицы (поле-колонка) |
| `showInFooter` | `<ShowInFooter>` | bool — показывать в подвале таблицы |
| `autoCellHeight` | `<AutoCellHeight>` | bool — авто-высота ячейки |
| `footerHorizontalAlign` | `<FooterHorizontalAlign>` | `Left`/`Right`/`Center` |
| `headerHorizontalAlign` | `<HeaderHorizontalAlign>` | `Left`/`Right`/`Center`/`Auto` |
| `headerPicture` | `<HeaderPicture>` | Картинка в шапке колонки. Формат — см. «Картинка-ссылка» ниже |
| `footerPicture` | `<FooterPicture>` | Картинка в подвале колонки. Формат — см. «Картинка-ссылка» ниже |
| `verticalAlign` | `<VerticalAlign>` | `Top`/`Center`/`Bottom` |
| `throughAlign` | `<ThroughAlign>` | `Use`/`DontUse` (сквозное выравнивание группы) |
| `enableContentChange` | `<EnableContentChange>` | bool (группа/страницы) |
| `pictureSize` | `<PictureSize>` | `AutoSize`/`Proportionally`/`ByFontSize`/… (декорация-картинка) |
| `titleHeight` | `<TitleHeight>` | число |
| `childItemsWidth` | `<ChildItemsWidth>` | `Equal`/`LeftWide`/… (ширины дочерних в группе) |
| `verticalSpacing` | `<VerticalSpacing>` | `None`/… (вертикальный интервал группы) |
| `showLeftMargin` | `<ShowLeftMargin>` | bool (группа) |
| `cellHyperlink` | `<CellHyperlink>` | bool |
| `mask` | `<Mask>` | строка маски ввода (input) |
| `createButton` | `<CreateButton>` | bool (input) |
| `viewMode` / `verticalScrollBar` / `rowInputMode` | `<ViewMode>`/… | свойства таблицы (pass-through) |

> Эти простые скаляры — pass-through (captured/emitted «как есть»), применимы там, где платформа их пишет.
> `defaultItem`/`enableStartDrag`/`fileDragMode`/`skipOnInput` + cell-свойства (`showInHeader`/`showInFooter`/`autoCellHeight`/`footerHorizontalAlign`/`headerHorizontalAlign`/`headerPicture`/`footerPicture`) — общие для любого поля-колонки (input, label, picField, check).

#### Картинка-ссылка (`headerPicture`/`footerPicture`/`valuesPicture`/`rowsPicture`/Page `picture`)

Картинка с флагом прозрачности. Два формата:

```json
"headerPicture": "CommonPicture.Важность"                       // loadTransparent = false (частый случай)
"headerPicture": { "src": "StdPicture.ExecuteTask", "loadTransparent": true }   // отклонение
"valuesPicture": { "src": "abs:Picture.png", "transparentPixel": { "x": 7, "y": 3 } }  // встроенная + прозрачный пиксель
```

- скаляр-строка — ссылка `StdPicture.*`/`CommonPicture.*`, `loadTransparent=false` (дефолт по корпусу: ~64% картинок);
- префикс `abs:` в `src` (напр. `"abs:Picture.png"`) → встроенная картинка `<xr:Abs>` (бинарь хранится в самой форме);
- объект `{ src, loadTransparent?, transparentPixel? }` — когда нужен `loadTransparent: true` и/или `transparentPixel: { x, y }` (координаты пикселя фона прозрачности).

> Не путать с `loadTransparent` у `<Picture>` кнопки/команды/попапа (§«button»/§7) — там обратная конвенция (дефолт `true`, отдельный скаляр-ключ на элементе).

### 4.2. События элемента и автоименование обработчиков

События элемента описываются мапой `events` (как у формы):

```json
{ "input": "Контрагент", "path": "Объект.Контрагент",
  "events": { "OnChange": "КонтрагентПриИзменении" } }
```

Значение — имя процедуры-обработчика. Если вместо имени указать **`null`**, имя
генерируется автоматически по конвенции 1С `<ИмяЭлемента><РусскийСуффикс>`:

```json
{ "input": "Контрагент", "path": "Объект.Контрагент",
  "events": { "OnChange": null } }   // → обработчик КонтрагентПриИзменении
```

Суффиксы для авто-имени:

| Событие | Суффикс |
|---------|---------|
| `OnChange` | `ПриИзменении` |
| `StartChoice` | `НачалоВыбора` |
| `ChoiceProcessing` | `ОбработкаВыбора` |
| `AutoComplete` | `АвтоПодбор` |
| `Clearing` | `Очистка` |
| `Opening` | `Открытие` |
| `Click` | `Нажатие` |
| `OnActivateRow` | `ПриАктивизацииСтроки` |
| `BeforeAddRow` | `ПередНачаломДобавления` |
| `BeforeDeleteRow` | `ПередУдалением` |
| `BeforeRowChange` | `ПередНачаломИзменения` |
| `OnStartEdit` | `ПриНачалеРедактирования` |
| `OnEndEdit` | `ПриОкончанииРедактирования` |
| `Selection` | `ВыборСтроки` |
| `OnCurrentPageChange` | `ПриСменеСтраницы` |
| `TextEditEnd` | `ОкончаниеВводаТекста` |

> **Legacy-формат (принимается, но устарел).** Ранее события элемента задавались парой
> `on` (массив имён событий) + `handlers` (переопределение имён): `{ "on": ["OnChange"], "handlers": { … } }`.
> Компилятор по-прежнему его принимает ради совместимости, но рекомендуемый и
> единственный эмитируемый формат — мапа `events`. Новые формы пишите через `events`.

### 4.3. Типы элементов

#### group — UsualGroup

```json
{ "group": "horizontal", "name": "ГруппаШапка", "children": [ ... ] }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `group` | string | Ориентация. **Для АВТОРИНГА** (что предлагает конфигуратор): страница/обычная группа — `vertical` / `horizontalIfPossible` / `alwaysHorizontal`; группа колонок таблицы (`columnGroup`) — `vertical` / `horizontal` / `inCell`. ⚠️ `horizontal`/`alwaysVertical` на странице/группе — **только раундтрип-совместимость** (встречаются в корпусе, но в UI конфигуратора отсутствуют; новые формы ими НЕ размечать). **`""`** → `<Group>` не эмитится (тег отсутствовал в исходнике; платформа сериализует «Группировку», только если она задана в конфигураторе — даже явный `Vertical` хранится, поэтому `""` ≠ `vertical`). Ключ обязателен как тип-маркер группы. (Legacy: `collapsible` = `vertical` + `behavior:'collapsible'`) |
| `behavior` | string | Поведение (`<Behavior>`): `usual`, `collapsible`, `popup`. **Отсутствие = Авто** (дефолт, не эмитится). Свёртываемая/всплывающая несут доп. свойства |
| `collapsed` | bool | Свёрнута (у `collapsible`/`popup`) |
| `collapsedTitle` | string/object | Заголовок свёрнутого представления (`<CollapsedRepresentationTitle>`), мультиязычный текст |
| `children` | array | Вложенные элементы |
| `showTitle` | bool | Показывать заголовок группы |
| `representation` | string | `none`, `normal`, `weak`, `strong` |
| `united` | bool | Объединение |

#### input — InputField

```json
{ "input": "Организация", "path": "Объект.Организация", "events": { "OnChange": "ОрганизацияПриИзменении" } }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `multiLine` | bool | Многострочный режим (`<MultiLine>`). Факт. значение: платформа эмитит и явный `false` (425 в корпусе) — захватываем true/false, отсутствие = дефолт (однострочный) |
| `passwordMode` | bool | Режим пароля |
| `titleLocation` | string | `none`, `left`, `right`, `top`, `bottom` |
| `choiceButton` | bool | Показывать кнопку выбора |
| `clearButton` | bool | Показывать кнопку очистки |
| `spinButton` | bool | Показывать кнопку прокрутки |
| `dropListButton` | bool | Показывать кнопку раскрытия |
| `markIncomplete` | bool | Автопометка незаполненных (`<AutoMarkIncomplete>`, факт. значение true/false) |
| `extendedEdit` | bool | Расширенное редактирование (`<ExtendedEdit>`) |
| `editTextUpdate` | string | Обновление текста при редактировании: `Always`, `OnValueChange`, `DontUse` |
| `warningOnEdit` | string/object | Предупреждение при редактировании (`<WarningOnEdit>`, мультиязычный текст). Доступно также на `check`/`radio`/`labelField` (не только `input`). Парный enum `warningOnEditRepresentation` (`Show`/`DontShow`) — generic-скаляр на любом поле |
| `footerText` | string/object | Текст подвала поля (`<FooterText>`, мультиязычный) |
| `editMode` | string | Режим редактирования: `EnterOnInput`, `Directly` |
| `skipOnInput` | bool | Пропускать при вводе |
| `inputHint` | string | Подсказка ввода (placeholder) |
| `choiceList` | array | Список выбора: массив `{ value, presentation?/title? }` — та же грамматика, что у `radio` (см. ниже) |
| `format` | string/object | Формат значения (`<Format>`). Строка форматной строки 1С (`ЧДЦ=2`, `ДЛФ=D`, `БЛ=Нет; БИ=Да`) или мультиязык `{ru, en}`. Так же у `labelField` и `check` |
| `editFormat` | string/object | Формат редактирования (`<EditFormat>`). Та же грамматика, что `format` |
| `wrap` | bool | Перенос по словам (`<Wrap>`) |
| `openButton` | bool | Кнопка открытия (`<OpenButton>`) |
| `listChoiceMode` | bool | Режим выбора из списка (`<ListChoiceMode>`) |
| `extendedEditMultipleValues` | bool | Расширенное редактирование нескольких значений |
| `chooseType` | bool | Выбор типа (`<ChooseType>`) |
| `choiceListButton` | bool | Кнопка списочного выбора (`<ChoiceListButton>`) |
| `quickChoice` | bool | Быстрый выбор (`<QuickChoice>`) |
| `autoChoiceIncomplete` | bool | Автоматический выбор незаполненного (`<AutoChoiceIncomplete>`) |
| `choiceForm` | string | Форма выбора (`<ChoiceForm>`), напр. `Catalog.X.Form.ФормаВыбора` |
| `choiceHistoryOnInput` | string | История выбора при вводе (`<ChoiceHistoryOnInput>`): `Auto`, `DontUse` |
| `choiceFoldersAndItems` | string | Выбор групп и элементов (`<ChoiceFoldersAndItems>`): `Items`, `Folders`, `FoldersAndItems` |
| `fixingInTable` | string | Фиксация колонки в таблице (`<FixingInTable>`): `Left`, `Right`, `None`. Так же у `labelField` и др. полей |
| `footerDataPath` | string | DataPath подвала колонки таблицы (`<FooterDataPath>`) |
| `choiceButtonRepresentation` | string | `ShowInInputField`, `ShowInDropList`, `ShowInDropListAndInInputField` |
| `minValue` / `maxValue` | number/string | Мин./макс. значение (`<MinValue>`/`<MaxValue>` с обязательным `xsi:type`). **JSON-число → `xs:decimal`, строка → `xs:string`** (тип сохраняется декомпилятором через тип JSON-значения) |
| `width` | int | Ширина |
| `height` | int | Высота |
| `horizontalStretch` | bool | Растягивание по горизонтали |
| `verticalStretch` | bool | Растягивание по вертикали |
| `autoMaxWidth` | bool | Автомаксимальная ширина |
| `autoMaxHeight` | bool | Автомаксимальная высота |
| `choiceParameters` | array | Параметры выбора — см. ниже |
| `choiceParameterLinks` | array | Связи параметров выбора — см. ниже |
| `typeLink` | object | Связь по типу — см. ниже |

##### Параметры выбора, связи параметров выбора, связь по типу

Свойства поля ввода, управляющие выбором значения и типом. Имена параметров (`"Отбор.Х"`) — строки 1С как есть.

```json
{ "input": "Контрагент", "path": "Объект.Контрагент",
  "choiceParameters": [
    { "name": "Отбор.Активный", "value": true },
    { "name": "Отбор.ВидПродукции", "value": ["Enum.Виды.Агрохимикат", "Enum.Виды.Пестицид"] }
  ],
  "choiceParameterLinks": [
    { "name": "Отбор.Организация", "dataPath": "Объект.Организация" },
    { "name": "Отбор.Тип", "dataPath": "Объект.Тип", "valueChange": "DontChange" }
  ],
  "typeLink": { "dataPath": "Объект.ЗначениеДата", "linkItem": 0 }
}
```

- **`choiceParameters`** — `[{ name, value }]`. `value` через ту же нормализацию, что `choiceList`: bool / число / строка / ISO-дата (`2020-01-01T00:00:00` → `xs:dateTime`) / ссылка-путь (`Enum.X.Y`, `Catalog.X` и синонимы `Перечисление.`/`Справочник.`). **Массив** значений → фиксированный массив (`FixedArray`). Синонимы ключей: `имя`/`значение`.
- **`choiceParameterLinks`** — `[{ name, dataPath, valueChange? }]`. `valueChange`: `Clear` (дефолт, опускается) / `DontChange`; forgiving `очистить`/`неизменять`. Синонимы: `имя`/`путь`/`режимИзменения`.
- **`typeLink`** — `{ dataPath, linkItem }`. `linkItem` — индекс (дефолт `0`). Синонимы: `путь`/`элементСвязи`.

**Короткая форма (shorthand)** — то же самое строками (эквивалентно объектной форме):

```json
{ "input": "Контрагент", "path": "Объект.Контрагент",
  "choiceParameters": [ "Отбор.Активный=true", "Отбор.ВидПродукции=Enum.Виды.Агрохимикат, Enum.Виды.Пестицид" ],
  "choiceParameterLinks": [ "Отбор.Организация=Объект.Организация", "Отбор.Тип=Объект.Тип:DontChange" ],
  "typeLink": "Объект.ЗначениеДата" }
```

- `choiceParameters`: `"name=value"`; значение с запятыми → массив; литералы коэрсятся (`true`/`false` → bool, число → number, остальное → строка/ref).
- `choiceParameterLinks`: `"name=dataPath"`, опц. хвост `:Clear`/`:DontChange` (по умолчанию Clear).
- `typeLink`: `"dataPath"` или `"dataPath#linkItem"`.

#### check — CheckBoxField

```json
{ "check": "ФлагАктивности", "path": "Активен", "events": { "OnChange": "ФлагАктивностиПриИзменении" } }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `checkBoxType` | string | Вид флажка. **Нет ключа** → умный дефолт `Auto`. **`""`** → не выводить тег (платформа применит своё умолчание). Значения: `auto`, `checkBox`, `switcher`, `tumbler` |
| `editMode` | string | Режим редактирования: `EnterOnInput`, `Directly` |
| `titleLocation` | string | Расположение заголовка. **Нет ключа** → умный дефолт `Right` (флажки почти всегда справа). **`""`** → не выводить тег (платформа применит своё умолчание, `Left`). Значение (`none`/`left`/`top`/…) → как указано |

#### radio — RadioButtonField

```json
{
  "radio": "СпособКурса",
  "path": "Объект.СпособУстановкиКурса",
  "radioButtonType": "Auto",
  "choiceList": [
    { "value": "Enum.СпособыКурса.EnumValue.Авто",   "presentation": "автоматически" },
    { "value": "Enum.СпособыКурса.EnumValue.Ручной", "presentation": { "ru": "вручную", "en": "manual" } }
  ]
}
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `radioButtonType` | string | `Auto` (по умолчанию), `RadioButtons`, `Tumbler` |
| `columnsCount` | int | Число колонок раскладки |
| `titleLocation` | string | Расположение заголовка. **Нет ключа** → умный дефолт `None`. **`""`** → не выводить тег (платформа применит своё умолчание). Значение → как указано |
| `choiceList` | array | Варианты выбора: массив `{ value, presentation }` |

`choiceList[*]`:

| Свойство | Тип | Описание |
|----------|-----|----------|
| `value` | string/number/bool | Значение варианта. Для перечисления — `"Enum.ИмяТипа.EnumValue.ИмяЗначения"` (xsi:type автоматически: `xr:DesignTimeRef` / `xs:string` / `xs:decimal` / `xs:boolean`) |
| `presentation` | string или object | Текст рядом с переключателем. Строка → ru; объект `{ru, en, ...}` → мультиязык. Если не задано — выводится из имени значения |

#### label — LabelDecoration

```json
{ "label": "Подсказка", "title": "Выберите параметры", "hyperlink": true }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `title` | string/object | Текст надписи. Единая ML-text форма (см. §4.1): строка / `{ru,en}` / `{text, formatted}`. У декораций `<Title>` всегда несёт атрибут `formatted` (авто-детект по разметке) |
| `hyperlink` | bool | Режим гиперссылки |
| `formatted` | bool | **Back-compat**: явный override авто-детекта formatted (раньше — отдельный ключ). Предпочтительно — форма `title: {text, formatted}` |
| `width` | int | Ширина |
| `height` | int | Высота |
| `autoMaxWidth` | bool | Автомаксимальная ширина |
| `autoMaxHeight` | bool | Автомаксимальная высота |

#### labelField — LabelField

```json
{ "labelField": "СтатусОбработки", "path": "Статус" }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `hyperlink` | bool | Режим гиперссылки (у LabelField платформенный тег `<Hiperlink>` — опечатка 1С, компилятор учитывает) |
| `editMode` | string | Режим редактирования: `EnterOnInput`, `Directly` |

#### table — Table

```json
{
  "table": "Товары", "path": "Объект.Товары",
  "columns": [
    { "input": "Номенклатура", "path": "Объект.Товары.Номенклатура" }
  ]
}
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `path` | string | DataPath |
| `columns` | array | Колонки (элементы input/check/labelField/picField, либо `columnGroup` для группировки) |
| `representation` | string | `List`, `Tree`, `HierarchicalList` |
| `changeRowSet` | bool | Разрешить добавление/удаление строк (эмитится явное значение, в т.ч. `false`) |
| `changeRowOrder` | bool | Разрешить перемещение строк (явное значение) |
| `autoInsertNewRow` | bool | Автодобавление новой строки |
| `enableDrag` | bool | Разрешить перетаскивание из таблицы |
| `rowFilter` | null | Отбор строк (nil-плейсхолдер `<RowFilter xsi:nil="true"/>`); значение всегда `null` |
| `choiceMode` | bool | Режим выбора |
| `autofill` | bool | Автозаполнение состава колонок из источника (`<Autofill>`). Своё свойство таблицы (≠ `tableAutofill` = autofill вложенной командной панели). Дефолт (нет тега) — колонки заданы явно; `true` — таблица генерирует колонки сама (ChildItems пуст). Встречается у вспомогательных таблиц динамического списка (отборы/параметры/настройки, привязанные к `КомпоновщикНастроек`); в палитре свойств не показывается — внутренний флаг конструктора. Редко (270 в корпусе, всегда `true`) |
| `multipleChoice` | bool | Множественный выбор (`<MultipleChoice>`) |
| `searchOnInput` | string | Поиск при вводе (`<SearchOnInput>`): `Auto`, `Use`, `DontUse` |
| `markIncomplete` | bool | Автоотметка незаполненного (`<AutoMarkIncomplete>`); общий ключ с `input` |
| `useAlternationRowColor` | bool | Чередование цвета строк |
| `selectionMode` | string | Режим выделения (`SingleRow`, …) |
| `rowSelectionMode` | string | Режим выделения строки (`Row`, …) |
| `verticalLines` / `horizontalLines` | bool | Линии сетки (эмитится явное `false`) |
| `initialTreeView` | string | `ExpandTopLevel`, `ExpandAllLevels`, `NoExpand` |
| `rowsPicture` | string \| object | Картинка строк (`<RowsPicture>`). Формат «картинка-ссылка» из §4.1 (скаляр-Ref/`abs:X` или объект `{ src, loadTransparent?, transparentPixel? }`, дефолт `loadTransparent=false`) |
| `height` | int | Высота элемента таблицы (`<Height>`, как у прочих элементов) |
| `heightInTableRows` | int | Высота в строках (`<HeightInTableRows>`) — отдельное свойство от `height`; таблица может нести оба |
| `header` | bool | Показывать шапку |
| `footer` | bool | Показывать подвал |
| `commandBarLocation` | string | `None`, `Top`, `Bottom`, `Auto` |
| `searchStringLocation` | string | `None`, `Top`, `Bottom`, `CommandBar`, `Auto` |
| `viewStatusLocation` | string | `None`, `Top`, `Bottom`, `Auto` |
| `searchControlLocation` | string | `None`, `Top`, `Bottom`, `Auto` |
| `excludedCommands` | string[] | Исключённые стандартные команды редактора → `<CommandSet><ExcludedCommand>X</ExcludedCommand>…`. **Общее свойство поля** — работает на любом поле (`input`/`label`/`check`/`spreadsheet`/`html`/`formattedDoc`/`picField`/таблица) и на форм-уровне. Значения зависят от типа поля: таблица — `Add`/`Delete`/`MoveUp`/`SortListAsc`; табличный документ — `AlignCenter`/`Bold`/`BorderAll`/`BackColor`… |
| `additions` | object | Отклонения стандартных дополнений командной панели (см. ниже) |

> `commandBarLocation` у **дин-список-таблицы** компилятор авто-подставляет `None`. Чтобы оставить тег пустым (платформа не написала его) — задайте `commandBarLocation: ""` (суппресс-маркер); декомпилятор так и делает.

##### Дополнения командной панели (поиск / состояние / управление)

Дополнения — «представления» встроенного поиска таблицы: `searchString` (отображение строки поиска), `viewStatus` (состояние просмотра), `searchControl` (управление поиском). Это полноценные элементы (полный набор свойств поля). Две позиции:

**(1) Стандартные** (платформа авто-генерит на уровне таблицы) — указываются ТОЛЬКО отклонения, через карту `additions` (ключ = тип):
```json
{ "table": "Список", "additions": { "viewStatus": { "horizontalLocation": "left" } } }
```

**(2) Кастомные** (размещённые в командной панели) — обычные элементы в `commandBar`:
```json
{ "table": "Список", "commandBar": [
  { "searchString": "ПоискСписка", "source": "Список", "width": 15, "horizontalStretch": true }
]}
```

- Тип-ключ: `searchString` / `viewStatus` / `searchControl` (forgiving: XML-тег `SearchStringAddition`, `<Type>` `SearchStringRepresentation`, рус. `строкаПоиска`/«Отображение строки поиска»).
- `source` → `AdditionSource.Item`; **дефолт = имя родительской таблицы**.
- `horizontalLocation`: `auto` (дефолт) / `left` / `right` (+ рус. `слева`/`справа`). Применимо и к обычным элементам командных панелей.
- Прочие свойства (`title`, `visible`, `userVisible`, `enabled`, `tooltip`, оформление, `width`/`maxWidth`/`autoMaxWidth`/`horizontalStretch`/`groupHorizontalAlign`/…) — как у поля.

##### Таблица динамического списка

Когда таблица привязана к реквизиту `type: "DynamicList"` (её `path` = имя такого реквизита), платформа эмитит блок специфичных свойств. Компилятор генерирует его автоматически с умолчаниями; в DSL указываются **только отличия** от умолчания (декомпилятор так и поступает). Чистые константы (`Period`, `TopLevelParent`) не настраиваются.

| Свойство | Тип | Умолчание | Описание |
|----------|-----|-----------|----------|
| `rowPictureDataPath` | string | `<Список>.DefaultPicture` (если есть осн. таблица) | Путь к картинке строки. `""` — подавить авто-вывод |
| `autoRefresh` | bool | `false` | Автообновление |
| `autoRefreshPeriod` | int | `60` | Период автообновления, сек |
| `choiceFoldersAndItems` | string | `Items` | `Items`, `Folders`, `FoldersAndItems` |
| `restoreCurrentRow` | bool | `false` | Восстанавливать текущую строку |
| `showRoot` | bool | `true` | Показывать корень |
| `allowRootChoice` | bool | `false` | Разрешить выбор корня |
| `updateOnDataChange` | string | `Auto` | `Auto`, `DontUpdate` |
| `allowGettingCurrentRowURL` | bool | `true` | Получение URL текущей строки |
| `userSettingsGroup` | string | — | Группа пользовательских настроек |
| `rowsPicture` | string | — | Картинка строк (`CommonPicture.X`) → `<RowsPicture>` |

#### columnGroup — ColumnGroup

Группа колонок таблицы. Используется только внутри `columns` таблицы. Допускается вложение `columnGroup` в `columnGroup`.

```json
{ "table": "Список", "path": "Список", "columns": [
    { "columnGroup": "horizontal", "name": "ГруппаДата", "title": "Срок", "children": [
        { "input": "ДатаНачала", "path": "Список.ДатаНачала" },
        { "input": "ДатаОкончания", "path": "Список.ДатаОкончания" }
    ]},
    { "columnGroup": "inCell", "name": "ГруппаИсполнитель", "showInHeader": true, "children": [
        { "input": "Исполнитель", "path": "Список.Исполнитель" }
    ]}
]}
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `columnGroup` | string | Ориентация: `horizontal`, `vertical`, `inCell` (склейка колонок в одной ячейке шапки). **`""`** → `<Group>` не эмитится (тега не было в исходнике). Ключ обязателен как тип-маркер |
| `name` | string | Имя элемента (рекомендуется задавать явно) |
| `title` | string/object | Заголовок группы |
| `showTitle` | bool | Показывать заголовок |
| `showInHeader` | bool | Показывать в шапке таблицы |
| `width` | int | Ширина |
| `horizontalStretch` | bool | Растягивание |
| `children` | array | Колонки внутри группы |

#### pages / page — Pages / Page

```json
{
  "pages": "Страницы", "children": [
    { "page": "Основное", "children": [ ... ] },
    { "page": "Дополнительно", "children": [ ... ] }
  ]
}
```

Page поддерживает `group` для задания ориентации содержимого и `children` для вложенных элементов.
Также `picture` — картинка-иконка вкладки (формат «картинка-ссылка» из §4.1: скаляр-Ref/`abs:X` или объект `{src, loadTransparent?, transparentPixel?}`, дефолт `loadTransparent=false`).

Pages поддерживает `pagesRepresentation`: `None`, `TabsOnTop`, `TabsOnBottom`, `TabsOnLeft`, `TabsOnRight`.

#### button — Button

```json
{ "button": "Загрузить", "command": "Загрузить", "defaultButton": true }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `command` | string | Имя команды формы (→ `Form.Command.<name>`) |
| `commandName` | string | Глобальная команда «как есть» (`CommonCommand.X`, `Catalog.X.Command.Y` …) — без обёртки `Form.` |
| `stdCommand` | string | Стандартная команда (→ `Form.StandardCommand.<name>`; `X.Y` → `Form.Item.X.StandardCommand.Y`) |
| `type` | string | `usual`, `hyperlink`, `commandBar` |
| `defaultButton` | bool | Кнопка по умолчанию |
| `checked` | bool | Пометка (нажатое состояние toggle-кнопки командной панели) → `<Check>true</Check>`. Платформа эмитит только `true`. Ключ `checked` (не `check` — `check` — тип-ключ ПоляФлажка) |
| `picture` | string \| object | Ссылка на картинку (`StdPicture.Name`; префикс `abs:` → встроенная `<xr:Abs>`). Скаляр-строка ИЛИ объект `{src, loadTransparent?, transparentPixel?}` (флаг и прозрачный пиксель `{x,y}` можно задать прямо в объекте) |
| `loadTransparent` | bool | Загружать картинку прозрачной (у `<Picture>` кнопки/команды/попапа). **Дефолт `true`** (эмитится всегда; `false` — явно). Элемент-уровневый ключ ИЛИ поле объекта `picture`. Также у `command` (§7) и `popup`. ⚠️ Полярность обратна `headerPicture`/`valuesPicture` (там дефолт `false`, см. §4.1) |
| `path` | string | DataPath кнопки общей команды (`Объект.Ref`, `Items.X.CurrentData.Поле`) — привязка к контексту |
| `representation` | string | `Auto`, `Picture`, `Text`, `PictureAndText` |
| `locationInCommandBar` | string | `InCommandBar`, `InAdditionalSubmenu` |

#### picture — PictureDecoration

```json
{ "picture": "Логотип", "src": "CommonPicture.Логотип" }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `src` (у `picture`-декорации — только `src`, не имя) | string | Ссылка на картинку: `StdPicture.X`/`CommonPicture.X`/`style:X` → `<xr:Ref>`. Префикс `abs:` (напр. `"abs:Picture.png"`) → встроенная картинка `<xr:Abs>` |
| `loadTransparent` | bool | `true` → загружать прозрачной. По умолчанию `false` |
| `hyperlink` | bool | Режим гиперссылки |
| `width` | int | Ширина |
| `height` | int | Высота |

#### picField — PictureField

```json
{ "picField": "Фото", "path": "Фотография" }
```

Для поля, привязанного к булеву/числу (иконка-индикатор в колонке), задайте картинку значения через `valuesPicture` — без неё иконка не отрисуется:

```json
{ "picField": "Картинка", "path": "Таблица.Картинка",
  "valuesPicture": "StdPicture.FilterCriterion" }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `valuesPicture` | string \| object | Картинка значения. Формат картинки-ссылки — см. §4.1 «Картинка-ссылка» |
| `editMode` | string | Режим редактирования колонки (`EnterOnInput` и т.п.) |
| `hyperlink` | bool | Картинка-гиперссылка (`<Hyperlink>true</Hyperlink>`) — кликабельная картинка |
| `shortcut` | string | Сочетание клавиш (`<Shortcut>`, напр. `Ctrl+S`). Общий generic-скаляр любого элемента (input/group/radio/page/picField/label/table/check), не только колонки-картинки |

#### calendar — CalendarField

```json
{ "calendar": "Дата", "path": "ДатаОтчета",
  "selectionMode": "Interval", "showCurrentDate": false, "widthInMonths": 2 }
```

| Свойство | XML | Значения |
|----------|-----|----------|
| `selectionMode` | `<SelectionMode>` | `Single`, `Multiple`, `Interval` |
| `showCurrentDate` | `<ShowCurrentDate>` | bool (выводится при наличии ключа) |
| `widthInMonths` | `<WidthInMonths>` | число месяцев по ширине |
| `heightInMonths` | `<HeightInMonths>` | число месяцев по высоте |
| `showMonthsPanel` | `<ShowMonthsPanel>` | bool |

Также поддерживается общий `titleLocation` (`none`/`left`/`right`/`top`/`bottom`/`auto`).

#### cmdBar — CommandBar

```json
{ "cmdBar": "КоманднаяПанель", "horizontalLocation": "right", "children": [ ... ] }
```

Свойства: `commandSource`, `autofill`, `horizontalLocation` (`<HorizontalLocation>`: `auto` дефолт / `left` / `right` / `center`, + рус. синонимы), `title`, `children` + общие флаги/layout.

#### popup — Popup

```json
{ "popup": "Печать", "picture": "StdPicture.Print", "children": [ ... ] }
```

#### buttonGroup — ButtonGroup

Группа кнопок внутри командной панели (`autoCmdBar`/`cmdBar`/`popup`). Значение ключа — имя элемента.

```json
{ "buttonGroup": "ГруппаПереместить", "title": "Переместить", "children": [
    { "button": "ПереместитьВверх", "command": "ПереместитьВверх" },
    { "button": "ПереместитьВниз", "command": "ПереместитьВниз" }
] }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `buttonGroup` | string | Имя элемента |
| `title` | string/object | Заголовок группы |
| `commandSource` | string | Источник команд группы (`<CommandSource>`): `Form`, `FormCommandPanelGlobalCommands`, `Item.<ИмяЭлемента>`. Также у `cmdBar`. Эмитится «как есть» |
| `representation` | string | `Auto`, `Picture`, `Text`, `PictureAndText` |
| `children` | array | Кнопки (`button`) внутри группы |

#### Спец-поля «документ/датчик»

Поля для отображения специальных данных. Структурно — обычные поля (скелет `path`/`title`/`titleLocation`/
flags/layout/оформление/companions/события общий), плюс собственные скаляры. Привязываются к реквизиту
соответствующего платформенного типа (см. §8 «Платформенные типы»).

| Ключ типа | XML-элемент | Тип реквизита | Спец. скаляры |
|-----------|-------------|---------------|----------------|
| `spreadsheet` | SpreadSheetDocumentField | `mxl:SpreadsheetDocument` | `output` (Disable/Enable), `protection`, `verticalScrollBar`/`horizontalScrollBar`, `viewScalingMode`, `selectionShowMode`, `pointerType`, `showGrid`/`showGroups`/`showHeaders`/`showRowAndColumnNames`/`showCellNames`, `edit`, `enableDrag`/`enableStartDrag` (фактическое значение) |
| `html` | HTMLDocumentField | `string` | `output`, `warningOnEditRepresentation` |
| `textDoc` | TextDocumentField | `d5p1:TextDocument` | `editMode` |
| `formattedDoc` | FormattedDocumentField | `fd:FormattedDocument` | `editMode` |
| `progressBar` | ProgressBarField | число | `showPercent`, `minValue`/`maxValue` (без `xsi:type`, ≠ типизированных у `input`) |
| `trackBar` | TrackBarField | число | `minValue`/`maxValue`/`largeStep`/`markingStep`/`step` (числовые), `markingAppearance` |
| `chart` | ChartField | `d5p1:Chart` (Диаграмма) | — (скелет; `TitleFont`/`MaxWidth` через общий механизм) |
| `ganttChart` | GanttChartField | `d5p1:GanttChart` (ДиаграммаГанта) | `ganttTable` — вложенная `<Table>` (полноценная таблица, та же грамматика) |
| `graphicalSchema` | GraphicalSchemaField | `d5p1:FlowchartContextType` (ГрафическаяСхема) | `edit`, `warningOnEditRepresentation` |
| `planner` | PlannerField | `pl:Planner` (Планировщик) | — |
| `periodField` | PeriodField | `v8:StandardPeriod` (Период) | — |
| `dendrogram` | DendrogramField | (Дендрограмма) | — |

```json
{ "spreadsheet": "ТаблицаОтчета", "path": "ТаблицаОтчета", "titleLocation": "none", "readOnly": true, "output": "Disable", "protection": true }
{ "trackBar": "Масштаб", "path": "Масштаб", "minValue": 20, "maxValue": 400, "markingStep": 20 }
{ "ganttChart": "Ганта", "path": "Ганта", "ganttTable": { "table": "ТаблицаГанта", "path": "Ганта", "height": 3 } }
```

Forgiving-синонимы типа: XML-имя (`SpreadSheetDocumentField`) и рус. (`ПолеТабличногоДокумента`, `ПолеИндикатора`, `ПолеДиаграммы`, `ПолеДиаграммыГанта`, …).
Скаляры `output`/`protection`/… — generic pass-through; bool как `true`/`false`, enum verbatim.

> **Design-time конфигурация диаграмм/планировщика.** Реквизит chart-типа может нести
> `<Settings xsi:type="d4p1:GanttChart"/"pl:Planner"/…>` — встроенный конфиг (серии/оси/цвета/планировщик).
> **Planner** (`pl:Planner`) — поддержан, см. ключ `planner` ниже. **Chart/GanttChart** (`d4p1:Chart`/`GanttChart`)
> при design-time настройке — пока НЕ воспроизводятся → декомпилятор делает честный fail-ring3 (не теряет молча).
> Поля без Settings (диаграмма, заполняемая в коде; график-схема; период; дендрограмма) роундтрипятся полностью.

#### autoCmdBar — командная панель формы

Командная панель самой формы (`<AutoCommandBar id="-1">`). Задаётся как элемент в `elements`; компилятор автоматически вынимает его из дерева. Нужен только если в панель помещаются **явные** кнопки/группы или меняется выравнивание/автозаполнение — иначе панель формируется автоматически.

```json
{ "autoCmdBar": "ФормаКоманднаяПанель", "horizontalAlign": "Right", "autofill": false, "children": [
    { "button": "ОК", "command": "ОК", "defaultButton": true },
    { "button": "Отмена", "command": "Отмена" }
] }
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `autoCmdBar` | string | Имя панели (обычно `ФормаКоманднаяПанель`) |
| `horizontalAlign` | string | `Right`, `Left`, `Center` |
| `autofill` | bool | `false` — отключить автозаполнение стандартными командами |
| `children` | array | Кнопки/группы кнопок панели |

---

## 5. Attributes — реквизиты формы

```json
"attributes": [
  { "name": "Объект", "type": "DocumentObject.Реализация", "main": true },
  { "name": "Итого", "type": "decimal(15,2)" },
  { "name": "Таблица", "type": "ValueTable", "columns": [
    { "name": "Номенклатура", "type": "CatalogRef.Номенклатура" },
    { "name": "Количество", "type": "decimal(10,3)" }
  ]}
]
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя реквизита (обязательно) |
| `type` | string | Тип (shorthand) |
| `main` | bool | Основной реквизит формы (`<MainAttribute>`). **`true`** → пометить главным. **`false`** → суппресс: подавить авто-вывод компилятора (эвристика «нет явного main + ровно 1 реквизит объектного типа → пометить его»). Нет ключа → авто-вывод |
| `title` | string/object | Заголовок. **Нет ключа** → авто-вывод из имени (как у элементов; кроме `main`). **`""`** → подавить (`<Title>` не эмитится — так платформа и хранит реквизит без синонима). Строка → ru; объект `{ru,en}` → мультиязычный. Декомпилятор опускает ключ, когда ru-заголовок совпадает с авто-выводом из имени |
| `view` | bool/object | Просмотр по ролям (`<View>`). См. §4.1c |
| `edit` | bool/object | Редактирование по ролям (`<Edit>`). См. §4.1c |
| `functionalOptions` | array | Функциональные опции (`<FunctionalOptions><Item>FunctionalOption.X</Item>…`). Массив имён; forgiving: `"X"`/`"FunctionalOption.X"`. Также у колонок (`columns[*]`) и команд (§7) |
| `useAlways` | array | Поля, всегда читаемые (`<UseAlways><Field>Имя.Поле</Field>…`). Массив коротких имён полей (forgiving: с/без префикса `Имя.`). **Маркер `~`** (query-поля дин-списка): `~Остановлен` → `<Field>~Список.Остановлен</Field>` (префикс ставится ПОСЛЕ `~`; полная форма `~Список.Остановлен` тоже принимается verbatim). **Две формы**: этот массив на реквизите ИЛИ `useAlways: true` на колонке (`columns[*]`) — компилятор сливает. Для дин-списка — только массив (колонки не эмитятся, но формируют `<UseAlways>`) |
| `valueType` | string | Тип значений у реквизита типа `ValueList` (`<Settings xsi:type="v8:TypeDescription">`). Грамматика — как у `type`, включая составной `A \| B`. **Три состояния**: нет ключа → нет `<Settings>`; `""` → пустой `<Settings…/>` (список без ограничения типа); тип → с типом. Forgiving-синонимы: `typeDescription` (≈1С «ОписаниеТипов» / XML), `описаниеТипов`, `типЗначений`. Пример: `"valueType": "CatalogRef.Контрагенты"` |
| `savedData` | bool | Сохраняемые данные (`<SavedData>`). **`false`** → суппресс авто-вывода компилятора (main-реквизит объектного типа Catalog/Document/ChartOf*/ExchangePlan/BusinessProcess/Task Object + RecordManager → `SavedData=true`). Нет ключа → авто-вывод |
| `save` | bool/string/array | Сохранение значения в пользовательских настройках (`<Save><Field>…`). `true` → `<Field>имя</Field>`; строка/массив строк → под-поля с авто-префиксом `имя.` (путь с точкой / UUID `1/0:…` / совпадающее с именем — берётся как есть). Нет ключа или `false` → не эмитится. Пример периода: `["Период","EndDate","StartDate","Variant"]` |
| `fillCheck` | bool/string | Проверка заполнения реквизита (`<FillCheck>`). `true` → `ShowError` (единственное значение в схеме); строка → verbatim. Синоним `fillChecking`. (`<FillChecking>` в схеме нет — был багом) |
| `columns` | array | Колонки для ValueTable/ValueTree (`{ name, type, title?, functionalOptions?, useAlways? }`) |
| `additionalColumns` | array | Доп. колонки табличных частей объекта: `[{ table: "Объект.ТабЧасть", columns: [<col>] }]`. У главного реквизита-объекта; `<col>` — та же грамматика, что у `columns`. Эмитятся в `<Columns>` после прямых колонок |
| `settings` | object | Настройки динамического списка (только `type: "DynamicList"`) |
| `planner` | object | Design-time конфигурация планировщика (только `type: "pl:Planner"`, `<Settings xsi:type="pl:Planner">`). См. ниже |
| `chart` | object | Design-time конфигурация диаграммы (`<Settings xsi:type="d4p1:Chart">`). См. ниже |

### chart — design-time конфигурация диаграммы

Объект `chart` описывает встроенный конфиг поля-диаграммы (~127 свойств: тип, серии, легенда, заголовок, шкалы, цвета/шрифты, оси). Движок **генерик** — ключи = локальные имена тегов `d4p1:`, порядок ключей = порядок эмиссии; типы значений распознаются по форме (скаляр/линия/граница/шрифт/ML/область/массив-серий). Раундтрип любой формы **бит-в-бит**.

**Авторинг диаграммы с нуля:** платформа пишет ВСЕ ~127 свойств всегда, поэтому удобнее всего взять рабочую диаграмму за основу — `form-decompile` существующей формы-диаграммы выдаёт готовый `chart`-объект, в котором правишь смысловое ядро: `chartType` (Line/Pie/Bar/Histogram/Column/Area/…), `realSeriesData` (серии: `text`/`color`/`line`/`marker`), `isShowTitle`+`title`, `isShowLegend`+`legendPlacement`, `paletteKind`, базовые цвета (`bkgColor`/`labelsColor`/…). Остальное — оформительские дефолты.

Формы значений: цвета verbatim (`auto`/`style:X`/`#hex`/`web:`); `line` = `{width, gap, style}` (`v8ui:ChartLineType`); `border` = `{width, style}` (`v8ui:ControlBorderType`); `font` = `{kind:"AutoFont"}`/атрибуты; ML-поля (`title`/`vsFormat`/`lbFormat`/`labelFormat`/серия `text`/…) — строка или `{ru,en}`; области (`elementsChart`/`elementsLegend`/`elementsTitle`) = `{left,right,top,bottom}`; серии (`realSeriesData`/`realExSeriesData`) — массивы объектов. **Расширяемость:** любое из ~127 свойств переопределяется по каноничному имени.

```json
{ "name": "Диаграмма", "type": "d5p1:Chart", "chart": {
  "chartType": "Line",
  "isSeriesDesign": true, "realSeriesCount": "2",
  "realSeriesData": [
    { "id": "1", "color": "auto", "line": {"width":2,"gap":false,"style":"Solid"},
      "marker": "Auto", "text": "Серия 1", "strIsChanged": false, "isExpand": false,
      "isIndicator": false, "colorPriority": false }
  ],
  "isShowTitle": true, "title": "Продажи", "isShowLegend": true, "legendPlacement": "Bottom",
  "paletteKind": "Auto"
} }
```

**Диаграмма Ганта** (`type: "d5p1:GanttChart"`, `<Settings xsi:type="d4p1:GanttChart">`) использует ТОТ ЖЕ ключ `chart` и генерик-движок: внутри несёт вложенный `chart` (полный Chart-блок) + gantt-специфику (`points`/`series`/`timeScale`/`drawEmpty`/…). Тип Settings выводится из типа реквизита автоматически. Все 16 форм Ганта корпуса 8.3.24 — раундтрип бит-в-бит.

> **Ограничение:** диаграммы (Chart/Gantt) с **точками/осями** (`realPointData`/`realDataItems`, заполненные `valuesAxis`/`pointsAxis`) несут типизированные значения (`xsi:type`), `xsi:nil` и ML с префиксом `d4p1:` — генерик-движок их не сохраняет → декомпилятор делает честный fail-ring3 на таких формах (редкий вариант). Частые дашборд-диаграммы и диаграммы Ганта (серии/легенда/оформление/шкалы) поддержаны полностью.

### planner — design-time конфигурация планировщика

Для реквизита `type: "pl:Planner"` объект `planner` описывает встроенный конфиг поля-планировщика (элементы расписания + оформление/поведение + шкала времени). Платформа эмитит блок **всегда** (даже дефолтный); компилятор подставляет умолчания для пропущенных ключей — авторинг может быть кратким (`{ "items": [{ "text": "Встреча", "begin": "...", "end": "..." }] }`), декомпилятор делает полный захват (раундтрип бит-в-бит). Цвета verbatim (`auto`/`style:X`/`web:Red`/`#hex`); шрифт `{ kind: "AutoFont" }` или ref-строка; граница `{ width, style }`; ML-форматы — строка или `{ "#": ..., "ru": ... }`.

```json
{ "name": "Планировщик", "type": "pl:Planner", "planner": {
  "items": [{ "text": "Встреча", "begin": "2026-06-09T01:00:00", "end": "2026-06-09T04:00:00",
              "borderColor": "auto", "backColor": "auto", "deleted": false, "editMode": "EnableEdit" }],
  "period": { "begin": "2026-06-09T00:00:00", "end": "2026-06-09T23:59:59" },
  "displayCurrentDate": true, "itemsTimeRepresentation": "BeginTime",
  "timeScale": { "placement": "Left", "levels": [{ "measure": "Hour", "interval": 1 }] }
} }
```

| Ключ planner | Тип | Назначение |
|---|---|---|
| `items` | array | Элементы планировщика (`<pl:item>`): `value`(nil по умолч.)/`text`/`tooltip`/`begin`/`end`/`borderColor`/`backColor`/`textColor`/`font`/`replacementDate`/`deleted`/`id`(авто-GUID)/`textFormatted`/`border`/`editMode` |
| `dimensions` | array | Измерения планировщика (`<pl:dimension>`, «Измерения» в конфигураторе): `value` (объект разреза — ссылка `Enum.X.EnumValue.Y`/`Справочник.X`, опускается → nil)/`text` (заголовок)/`borderColor`/`backColor`/`textColor`/`font`/`elements`/`textFormatted`. `elements` — элементы измерения (рекурсивны, могут нести вложенные `elements`): `value`/`text`/цвета/`font`/`showOnlySubordinatesAreas`(bool)/`textFormatted`. Тип `value` авто: ссылочный вид → `xsi:type="xr:DesignTimeRef"`, иначе `xs:string` |
| `borderColor`/`backColor`/`textColor`/`lineColor` | color | Цвета планировщика (умолч. `auto`) |
| `font` | font | Шрифт (умолч. `{kind:"AutoFont"}`) |
| `beginOfRepresentationPeriod`/`endOfRepresentationPeriod` | dateTime | Период представления |
| `alignElementsOfTimeScale`/`displayTimeScaleWrapHeaders`/`displayWrapHeaders`/`displayCurrentDate` | bool | Флаги отображения |
| `timeScaleWrapHeadersFormat` | ML | Формат перенесённых заголовков шкалы |
| `periodicVariantUnit`/`periodicVariantRepetition` | value/int | Единица/кратность периодического варианта |
| `timeScaleWrapBeginIndent`/`timeScaleWrapEndIndent` | int | Отступы переноса шкалы |
| `timeScale` | object | Шкала времени: `placement`, `levels:[{measure,interval,show,line:{width,gap,style},scaleColor,dayFormatRule,format(ML),labels:{ticks},backColor,textColor,showPereodicalLabels}]`, `transparent`, `backColor`, `textColor`, `currentLevel` |
| `period` | object | `{ begin, end }` — отображаемый период (опционально) |
| `itemsTimeRepresentation`/`itemsBehaviorWhenSpaceInsufficient`/`newItemsTextType`/`fixDimensionsHeader`/`fixTimeScaleHeader` | value | Поведение элементов/заголовков |
| `autoMinColumnWidth`/`autoMinRowHeight` | bool | Авто-минимум размеров |
| `minColumnWidth`/`minRowHeight` | int | Минимальные размеры |
| `border` | border | Рамка планировщика (`{ width, style }`) |

> **Ограничение Phase 1:** `item.dimensionValues` (привязка элемента расписания к элементам измерений) пока всегда пустой (захват только пустого блока). Сами измерения (`dimensions`) поддержаны. Конфиг Chart/GanttChart (`d4p1:*`) — отдельная фаза.

### settings — динамический список

Для реквизита `type: "DynamicList"` объект `settings` описывает источник данных и настройки компоновщика (`ListSettings`).

```json
{ "name": "Список", "type": "DynamicList", "main": true,
  "settings": {
    "mainTable": "Catalog.Контрагенты",
    "query": "@Список.sql",
    "dynamicDataRead": false,
    "fields": [ { "field": "Отложен", "title": "Отложен" } ]
  } }
```

| Ключ | Тип | Описание |
|------|-----|----------|
| `mainTable` | string | Основная таблица. Принимает рус-имена метаданных (`Справочник.X` → `Catalog.X`) |
| `autoSaveUserSettings` | bool | Авто-сохранение пользовательских настроек дин-списка (`<AutoSaveUserSettings>`, после `MainTable`). **Умолчание `true`** — указывать только для отключения (`false`) |
| `query` | string | Текст запроса (`ManualQuery=true`). Поддерживает `@file.sql` (путь относительно JSON) |
| `dynamicDataRead` | bool | Динамическое считывание. **Умолчание `true`** — указывать только для отключения (`false`) |
| `autoFillAvailableFields` | bool | Автозаполнение доступных полей (`<AutoFillAvailableFields>`). **Умолчание `true`** — указывать только для отключения (`false`; тогда поля берутся из явного запроса, не авто). Эмитится первым в `<Settings>` |
| `fields` | array | Явные поля набора (редко): `{ field, dataPath?, title? }` — для переопределения заголовка. Обычно поля выводятся из запроса автоматически |
| `parameters` | array | Параметры схемы запроса (`DataCompositionSchemaParameter`) — см. ниже |
| `order` | array | Сортировка списка (см. ниже) |
| `filter` | array | Отбор списка (грамматика как в СКД) |
| `conditionalAppearance` | array | Условное оформление списка (грамматика как в СКД) |

`ManualQuery` выводится из наличия `query` — отдельным ключом не задаётся.

Пустой блок настроек компоновщика (`ListSettings`) генерируется автоматически (каноничный полный скелет платформы — filter+order+conditionalAppearance+itemsViewMode+itemsUserSettingID, ~93% форм); указывать ничего не нужно.

| `listSettings` | object | **Дескриптор формы скелета `<ListSettings>`** — только для НЕ-каноничных (частичных/минимальных) форм. Ordered-карта present top-level элементов: контейнеры `filter`/`order`/`conditionalAppearance` → блок-мета (`"vu"`=viewMode+userSettingID, `"u"`=только userSettingID, `"v"`, `""`); `itemsViewMode`/`itemsUserSettingID` → `true`. Компилятор эмитит ТОЛЬКО указанные части (контент берёт из `filter`/`order`/`conditionalAppearance`). Нет ключа → полный каноничный скелет. Декомпилятор пишет дескриптор только для отклонений от канона |

#### parameters — параметры схемы дин-списка

Параметры запроса дин-списка — это та же сущность `DataCompositionSchemaParameter`, что и параметры СКД (`&Параметр` в тексте запроса). **Грамматика идентична параметрам СКД** (см. [skd-dsl-spec.md](skd-dsl-spec.md)): shorthand `"Имя [Заголовок]: Тип = Значение @valueList @hidden"` или объект. Используй те же ключи — модель переносит знание один-в-один.

```json
"settings": {
  "query": "ВЫБРАТЬ … ГДЕ Товары.Артикул = &Артикул И … ПОДОБНО &Маска",
  "parameters": [
    "Артикул",
    "Маска: string = %",
    { "name": "ВидЦен", "valueListAllowed": true },
    { "name": "Период", "type": "dateTime", "useRestriction": false }
  ]
}
```

Отличия контекста дин-списка от параметров отчёта СКД (видимы только в дефолтах — модель просто опускает ключ):

| Поведение | Дин-список |
|-----------|-----------|
| `title` | Авто из имени (camelCase → «Заполнена серия»); явный `title`/`[Заголовок]` — только для переопределения |
| `useRestriction` | Эмитится всегда, **умолчание `true`**; для выключения — объект `{ "useRestriction": false }` |
| `value` | Умолчание — пустое (`xsi:nil`), даже при заданном типе |

Объектные ключи (как в СКД): `name`, `title`, `type`/`valueType`, `value`, `valueListAllowed`, `useRestriction`, `availableAsField`, `expression`, `availableValues` (`[{ value, presentation }]`), `inputParameters`, `denyIncompleteValues`, `use`.

#### order / filter / conditionalAppearance

Грамматика этих ключей идентична настройкам СКД — см. [skd-dsl-spec.md](skd-dsl-spec.md) (разделы filter / order / conditionalAppearance). Кратко:

```json
"settings": {
  "mainTable": "Catalog.Контрагенты",
  "order": [ "Дата desc", "Наименование", "Auto" ],
  "filter": [ "Организация = _ @off @user", "Сумма > 1000" ],
  "conditionalAppearance": [
    { "filter": ["Просрочено = true"], "appearance": { "ЦветТекста": "web:Red" } }
  ]
}
```

- **order** — строка `"Поле"` (asc) / `"Поле desc"` (синонимы `убыв`/`desc`, `возр`/`asc`) / `"Auto"`, либо объект `{ field, direction?, use?, viewMode? }`.
- **filter** — shorthand `"Поле оператор значение @флаги"` (`@off`, `@user`, `@quickAccess`, `@normal`, `@inaccessible`; `_` = пусто) или объект `{ field, op, value?, use?, userSettingID? }` или группа `{ group: "And"|"Or"|"Not", items: [...] }`.
  - **Стандартная дата** (`valueType: "v8:StandardBeginningDate"`): значение — объект `{ variant, date? }`. `variant: "Custom"` несёт `date` (ISO-дата); именованные варианты (`BeginningOfThisDay`/`BeginningOfThisWeek`/`BeginningOfThisYear`/…) — без `date`. Эмитится структурно (`<v8:variant>`+`<v8:date>`), не плоской строкой.
- **conditionalAppearance** — объект `{ selection?, filter?, appearance?, presentation?, viewMode?, userSettingID?, use? }`. `appearance` — словарь «параметр: значение» платформы (`ЦветТекста`, `ЦветФона`, `Шрифт` и т.п.).
  - Значение текстовых параметров (`Текст`/`Заголовок`/`Формат`) ведётся **по форме значения**: голая строка → плоский `xs:string` (нелокализованный литерал; `""` → самозакрывающийся тег); объект `{ru,en}` → локализуемый `LocalStringType`; объект `{field:"путь"}` → ссылка на поле компоновки (`dcscor:Field`). (В отличие от `title`/`tooltip`, где голая строка = `LocalStringType` — здесь это намеренное scoped-различие: платформа хранит обе формы, и их надо различать.)

`userSettingID: "auto"` → платформа сгенерирует идентификатор пользовательской настройки. Пустые контейнеры (без правил) эмитируются автоматически.

---

## 6. Parameters — параметры формы

```json
"parameters": [
  { "name": "Ключ", "type": "DocumentRef.Реализация", "key": true },
  { "name": "Основание", "type": "DocumentRef.Реализация" }
]
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя параметра (обязательно) |
| `type` | string | Тип (shorthand) |
| `key` | bool | Ключевой параметр |

---

## 7. Commands — команды формы

```json
"commands": [
  { "name": "Печать", "action": "ПечатьОбработка", "shortcut": "Ctrl+P" },
  { "name": "Обновить", "action": "ОбновитьОбработка", "picture": "StdPicture.Refresh" }
]
```

| Свойство | Тип | Описание |
|----------|-----|----------|
| `name` | string | Имя команды (обязательно) |
| `action` | string | Имя процедуры-обработчика |
| `title` | string | Заголовок |
| `tooltip` | string/object | Всплывающая подсказка команды (`<ToolTip>`) |
| `use` | bool/object | Доступность команды по ролям (`<Use>`). См. §4.1c |
| `functionalOptions` | array | Функциональные опции команды (см. §5) |
| `currentRowUse` | string | Использование текущей строки: `Auto`, `DontUse`, `Use` |
| `table` | string | Используемая таблица — имя элемента-таблицы формы (`<AssociatedTableElementId xsi:type="xs:string">Имя</…>`). Команда работает в контексте этой таблицы (текущая строка). Forgiving-синонимы: `associatedTableElementId` (XML-тег), `ИспользуемаяТаблица` (рус., регистро-/пробело-независимо) |
| `modifiesSavedData` | bool | Команда изменяет сохраняемые данные (`<ModifiesSavedData>`); эмитится только `true` |
| `shortcut` | string | Клавиатурное сочетание |
| `picture` | string \| object | Ссылка на картинку (`StdPicture.Name`; `abs:X` → `<xr:Abs>`). Скаляр ИЛИ объект `{src, loadTransparent?, transparentPixel?}` (как у `button`, §«button») |
| `representation` | string | `Auto`, `Picture`, `Text`, `PictureAndText` |

---

## 7b. CommandInterface — командный интерфейс формы

Форменный ключ `commandInterface` (XML `<CommandInterface>`, последний дочерний `<Form>`). Две панели:
`commandBar` (командная панель) и `navigationPanel` (панель навигации). Платформа эмитит **только
переопределения** авто-расстановки (видимость/положение), поэтому в списке лишь изменённые команды.

```json
"commandInterface": {
  "commandBar": [
    { "command": "Form.Command.Печать", "defaultVisible": false, "group": "FormCommandBarImportant",
      "visible": { "common": false, "roles": { "Бухгалтер": true } } },
    "CommonCommand.История"
  ],
  "navigationPanel": {
    "important": [ { "command": "CommonCommand.СвязанныеДокументы", "defaultVisible": false, "visible": false } ],
    "seeAlso":   [ { "command": "CommonCommand.Заметки", "defaultVisible": false, "visible": false } ]
  }
}
```

**Элемент** (объект или строка-shorthand = голый `command` со всеми умолчаниями):

| Свойство | Тип | Описание |
|----------|-----|----------|
| `command` | string | Ссылка на команду verbatim: `CommonCommand.X`, `Document.X.StandardCommand.Y`, `Form.Command.X`, `Form.StandardCommand.OK`, `"0"` (пустой/разделитель) |
| `type` | string | `Auto` (дефолт, опускаем) / `Added` |
| `defaultVisible` | bool | Видимость по умолчанию (`<DefaultVisible>`; на практике всегда `false` — скрыть видимую команду) |
| `visible` | bool/object | Видимость с исключениями по ролям — **тот же xr-flag, что `userVisible`/`use`** (§4.1c): `bool` или `{common, roles:{Имя:bool}}` |
| `group` | string | `<CommandGroup>` verbatim: `FormCommandBarImportant`/`FormNavigationPanelGoTo`/…, `CommandGroup.X` (именованная), GUID (расширение) |
| `index` | int | Порядок в группе (`<Index>`) |
| `attribute` | string | Путь реквизита для элемента панели навигации (`<Attribute>`) |

**Две формы записи панели:**
- **Плоский массив** — каждый элемент опц. несёт `group` (полная общность; декомпилятор эмитит ЭТУ форму).
- **Дерево** (входной сахар) — объект `{группа: [команды]}`; `group` берётся из ключа, элементы его не дублируют. Дружелюбные алиасы (зависят от панели): navigation — `important`/`goTo`/`seeAlso` (рус. `важное`/`перейти`/`смТакже`), commandBar — `important`/`createBasedOn`; иной ключ (`CommandGroup.X`/GUID) — verbatim.

Синонимы ключей: `команда`/`тип`/`видимость`/`видимостьПоРолям`/`группа`/`индекс`/`реквизит`.

---

## 7c. conditionalAppearance — условное оформление формы

Форменный ключ `conditionalAppearance` (XML `<ConditionalAppearance>` — последний child `<Attributes>`).
**Грамматика идентична `settings.conditionalAppearance` дин-списка** (DCS — см. §«order/filter/conditionalAppearance»):
массив объектов `{ selection?, filter?, appearance?, presentation?, viewMode?, userSettingID?, use? }`.

```json
"conditionalAppearance": [
  { "selection": ["ОбычноеПоле"], "filter": ["ЧисловоеПоле > 100"],
    "appearance": { "ЦветФона": "style:FormBackColor" },
    "presentation": { "ru": "Подсветка", "en": "Highlight" } }
]
```

- `selection` — массив имён форматируемых полей (`<dcsset:field>`).
- `filter` — условие (filter-shorthand, как в СКД).
- `appearance` — словарь «параметр-DCS: значение» (рус. verbatim: `ЦветТекста`/`ЦветФона`/`Шрифт`/…). Цвет → `v8ui:Color`.
- `presentation` — мультиязык → `xsi:type="v8:LocalStringType"`.

Декомпилятор/компилятор переиспользуют `Build-ConditionalAppearance`/`Emit-ConditionalAppearance` настроек списка
(отличие — тег-обёртка `ConditionalAppearance` без `dcsset:` и без блок-мета). `scope` (привязка к области) в формах
не встречается; форма со `scope` → fail-ring3.

---

## 8. Система типов (shorthand)

### Примитивные типы

| DSL | XML |
|-----|-----|
| `"string"` | `xs:string` (неограниченная, AllowedLength=Variable) |
| `"string(100)"` | `xs:string` + Length=100 (AllowedLength=Variable, дефолт) |
| `"string(12,fixed)"` | `xs:string` + Length=12, AllowedLength=Fixed (строка фиксированной длины, напр. ИНН/КПП). Только с длиной > 0; `variable` принимается forgiving (= дефолт) |
| `"decimal(15,2)"` | `xs:decimal` + Digits=15, FractionDigits=2, AllowedSign=Any |
| `"decimal(10,0,nonneg)"` | `xs:decimal` + AllowedSign=Nonnegative |
| `"boolean"` | `xs:boolean` |
| `"date"` | `xs:dateTime` + DateFractions=Date |
| `"dateTime"` | `xs:dateTime` + DateFractions=DateTime |
| `"time"` | `xs:dateTime` + DateFractions=Time |

### Ссылочные типы

| DSL | XML |
|-----|-----|
| `"CatalogRef.Организации"` | `cfg:CatalogRef.Организации` |
| `"DocumentObject.Реализация"` | `cfg:DocumentObject.Реализация` |
| `"EnumRef.СтавкиНДС"` | `cfg:EnumRef.СтавкиНДС` |
| `"DataProcessorObject.ЗагрузкаДанных"` | `cfg:DataProcessorObject.ЗагрузкаДанных` |

### Платформенные типы

| DSL | XML |
|-----|-----|
| `"ValueTable"` | `v8:ValueTable` |
| `"ValueTree"` | `v8:ValueTree` |
| `"ValueList"` | `v8:ValueListType` (синоним `СписокЗначений`) |
| `"FormattedString"` | `v8ui:FormattedString` |
| `"Picture"` | `v8ui:Picture` |
| `"DynamicList"` | `cfg:DynamicList` |
| `"StandardPeriod"` | `v8:StandardPeriod` (forgiving: `СтандартныйПериод`, `v8:StandardPeriod`) |
| `"StandardBeginningDate"` | `v8:StandardBeginningDate` (синоним `СтандартнаяДатаНачала`) |
| `"UUID"` | `v8:UUID` (синоним `УникальныйИдентификатор`) |

> Платформенные `v8:`-типы можно писать без префикса или по-русски — компилятор приводит к каноничному `v8:X`. Уже-префиксованную форму (`v8:StandardPeriod`) принимает как есть.

**Спец-типы с собственным namespace** (для спец-полей). Хранятся verbatim с префиксом; компилятор объявляет
namespace **локально** на `<v8:Type>`. Префикс `d5p1` неоднозначен (несколько URI) — резолв по полному значению типа.

| DSL | XML (с локальным xmlns) |
|-----|-----|
| `"mxl:SpreadsheetDocument"` | `<v8:Type xmlns:mxl="http://v8.1c.ru/8.2/data/spreadsheet">mxl:SpreadsheetDocument</v8:Type>` |
| `"fd:FormattedDocument"` | `xmlns:fd="…/formatted-document"` |
| `"d5p1:TextDocument"` | `xmlns:d5p1="…/txtedt"` |
| `"d5p1:Chart"` / `"d5p1:GanttChart"` | `xmlns:d5p1="…/chart"` |
| `"d5p1:FlowchartContextType"` | `xmlns:d5p1="…/graphscheme"` |
| `"d5p1:GeographicalSchema"` | `xmlns:d5p1="…/geo"` |
| `"d5p1:DataAnalysisTimeIntervalUnitType"` | `xmlns:d5p1="…/data-analysis"` |
| `"pdfdoc:PDFDocument"` | `xmlns:pdfdoc="…/pdf"` |
| `"pl:Planner"` | `xmlns:pl="…/planner"` |

### Наборы типов (TypeSet → `<v8:TypeSet>`)

«Набор типов» вместо конкретного типа. Развязка с обычным типом — по наличию `.Имя`:

| DSL | XML | Смысл |
|-----|-----|-------|
| `"DefinedType.ДенежнаяСумма"` | `<v8:TypeSet>cfg:DefinedType.ДенежнаяСумма</v8:TypeSet>` | определяемый тип (синоним `ОпределяемыйТип.X`) |
| `"Characteristic.Номенклатура"` | `<v8:TypeSet>cfg:Characteristic.Номенклатура</v8:TypeSet>` | характеристика (синоним `Характеристика.X`) |
| `"AnyRef"` | `<v8:TypeSet>cfg:AnyRef</v8:TypeSet>` | любая ссылка (синоним `ЛюбаяСсылка`) |
| `"AnyIBRef"` | `<v8:TypeSet>cfg:AnyIBRef</v8:TypeSet>` | любая ссылка ИБ |
| `"CatalogRef"` (голый, без `.Имя`) | `<v8:TypeSet>cfg:CatalogRef</v8:TypeSet>` | любая ссылка справочника (аналогично `DocumentRef`, `EnumRef`, `ExchangePlanRef`, `TaskRef`, `BusinessProcessRef`, `ChartOf*Ref`) |

`CatalogRef.Валюты` (с `.Имя`) → обычный `<v8:Type>`; `CatalogRef` (голый) → `<v8:TypeSet>`.

### Составные типы

Разделитель `" | "` (или `+`). Каждая часть независимо роутится в `<v8:Type>` или `<v8:TypeSet>` (можно смешивать):

```json
"type": "CatalogRef.Организации | CatalogRef.ИндивидуальныеПредприниматели"
"type": "CatalogRef.Контрагенты | DefinedType.ДенежнаяСумма"
```

---

## 9. Автогенерация

### Companion-элементы

Для каждого элемента автоматически создаются служебные вложенные элементы:

| Тип элемента | Companions |
|---|---|
| UsualGroup | ExtendedTooltip |
| InputField | ContextMenu, ExtendedTooltip |
| CheckBoxField | ContextMenu, ExtendedTooltip |
| RadioButtonField | ContextMenu, ExtendedTooltip |
| LabelDecoration | ContextMenu, ExtendedTooltip |
| LabelField | ContextMenu, ExtendedTooltip |
| PictureDecoration | ContextMenu, ExtendedTooltip |
| PictureField | ContextMenu, ExtendedTooltip |
| CalendarField | ContextMenu, ExtendedTooltip |
| Table | ContextMenu, AutoCommandBar, SearchStringAddition, ViewStatusAddition, SearchControlAddition |
| Pages | ExtendedTooltip |
| Page | ExtendedTooltip |
| Button | ExtendedTooltip |

Именование: `<name>КонтекстноеМеню`, `<name>РасширеннаяПодсказка`, `<name>КоманднаяПанель`, `<name>СтрокаПоиска`, `<name>СостояниеПросмотра`, `<name>УправлениеПоиском`.

### ID

Последовательная нумерация начиная с 1. `AutoCommandBar` формы всегда имеет `id="-1"`.

### Namespace

Все 17 namespace-деклараций добавляются автоматически (version="2.17").

### Кодировка

UTF-8 с BOM (как в файлах конфигурации 1С).
