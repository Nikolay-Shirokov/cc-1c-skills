---
name: form-info
description: Анализ структуры управляемой формы 1С (Form.xml) — элементы, реквизиты, команды, события
argument-hint: <FormPath>
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /form-info — Компактная сводка формы

Читает Form.xml управляемой формы и выводит компактную сводку: дерево элементов, реквизиты с типами, команды, события. Заменяет необходимость читать тысячи строк XML.

## Использование

```
/form-info <FormPath>
```

## Параметры

| Параметр  | Обязательный | По умолчанию | Описание                                    |
|-----------|:------------:|--------------|---------------------------------------------|
| FormPath  | да           | —            | Путь к файлу Form.xml                       |
| Limit     | нет          | `150`        | Макс. строк вывода (защита от переполнения) |
| Offset    | нет          | `0`          | Пропустить N строк (для пагинации)          |

## Команда

```powershell
powershell.exe -NoProfile -File .claude\skills\form-info\scripts\form-info.ps1 -FormPath "<путь к Form.xml>"
```

С пагинацией:
```powershell
powershell.exe -NoProfile -File .claude\skills\form-info\scripts\form-info.ps1 -FormPath "<путь>" -Offset 150
```

## Чтение вывода

### Заголовок

```
=== Form: ФормаДокумента (Documents.РеализацияТоваровУслуг) ===
```

Имя формы и контекст объекта определяются из пути к файлу.

### Properties — свойства формы

Только нестандартные свойства (отличающиеся от умолчания):

```
Properties: AutoTitle=false, WindowOpeningMode=LockOwnerWindow, CommandBarLocation=Bottom
```

### Events — обработчики событий формы

```
Events:
  OnCreateAtServer -> ПриСозданииНаСервере
  OnOpen -> ПриОткрытии
```

### Elements — дерево UI-элементов

Компактное дерево с типами, привязками к данным, флагами и событиями:

```
Elements:
  ├─ [Group:AH] ГруппаШапка
  │  ├─ [Input] Организация -> Объект.Организация {OnChange}
  │  └─ [Input] Договор -> Объект.Договор [hidden] {StartChoice}
  ├─ [Table] Товары -> Объект.Товары
  │  ├─ [Input] Номенклатура -> Объект.Товары.Номенклатура {OnChange}
  │  └─ [Input] Сумма -> Объект.Товары.Сумма [ro]
  └─ [Pages] Страницы
     ├─ [Page] Основное (5 items)
     └─ [Page] Печать (2 items)
```

**Сокращения типов элементов:**

| Сокращение | Элемент |
|---|---|
| `[Group:V]` | UsualGroup Vertical |
| `[Group:H]` | UsualGroup Horizontal |
| `[Group:AH]` | UsualGroup AlwaysHorizontal |
| `[Group:AV]` | UsualGroup AlwaysVertical |
| `[Group]` | UsualGroup (ориентация по умолчанию) |
| `[Input]` | InputField |
| `[Check]` | CheckBoxField |
| `[Label]` | LabelDecoration |
| `[LabelField]` | LabelField |
| `[Picture]` | PictureDecoration |
| `[PicField]` | PictureField |
| `[Calendar]` | CalendarField |
| `[Table]` | Table |
| `[Button]` | Button |
| `[CmdBar]` | CommandBar |
| `[Pages]` | Pages |
| `[Page]` | Page (показывает кол-во элементов вместо раскрытия) |
| `[Popup]` | Popup |
| `[BtnGroup]` | ButtonGroup |

**Флаги** (только при отклонении от умолчания):
- `[hidden]` — Visible=false
- `[disabled]` — Enabled=false
- `[ro]` — ReadOnly=true
- `,collapse` — Behavior=Collapsible (для групп)

**Привязка**: `-> Объект.Поле` — DataPath или CommandName

**События**: `{OnChange, StartChoice}` — имена обработчиков

**Заголовок**: `[title:Текст]` — только если отличается от имени элемента

### Attributes — реквизиты формы

```
Attributes:
  *Объект: DocumentObject.РеализацияТоваров (main)
  Валюта: CatalogRef.Валюты
  Итого: decimal(15,2)
  Таблица: ValueTable [Номенклатура: CatalogRef.Номенклатура, Кол: decimal(10,3)]
  Список: DynamicList -> Catalog.Пользователи
```

- `*` и `(main)` — основной реквизит формы (MainAttribute)
- Типы ValueTable/ValueTree раскрывают колонки в `[...]`
- DynamicList показывает MainTable через `->`

### Parameters — параметры формы

```
Parameters:
  Ключ: DocumentRef.ЗакупкаТоваров (key)
  Основание: DocumentRef.*
```

- `(key)` — ключевой параметр (KeyParameter)

### Commands — команды формы

```
Commands:
  Печать -> ПечатьДокумента [Ctrl+P]
  Заполнить -> ЗаполнитьОбработка
```

Формат: `Имя -> Обработчик [Сочетание]`

## Что пропускается

Скрипт убирает 80%+ XML-объёма:
- Визуальные свойства (Width, Height, Color, Font, Border, Align, Stretch)
- Автогенерированные ExtendedTooltip и ContextMenu
- Мультиязычные обёртки (v8:item/v8:lang/v8:content)
- Namespace-декларации
- Атрибуты id

Для точечного изучения деталей — используйте grep по имени элемента из сводки.

## Когда использовать

- **Перед модификацией формы**: понять структуру, найти нужную группу для вставки элемента
- **Анализ формы**: какие реквизиты, команды, обработчики задействованы
- **Навигация по большим формам**: 28K строк XML → 50-100 строк контекста

## Защита от переполнения

Вывод ограничен 150 строками по умолчанию. При превышении:
```
[TRUNCATED] Shown 150 of 220 lines. Use -Offset 150 to continue.
```

Используйте `-Offset N` и `-Limit N` для постраничного просмотра.
