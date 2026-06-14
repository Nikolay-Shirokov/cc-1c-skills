# cf-edit — справочник операций

## modify-property

Свойства для редактирования:

### Скалярные
`Name`, `Version`, `Vendor`, `Comment`, `NamePrefix`, `UpdateCatalogAddress`

### LocalString (многоязычные)
`Synonym`, `BriefInformation`, `DetailedInformation`, `Copyright`, `VendorInformationAddress`, `ConfigurationInformationAddress`

### Enum
| Свойство | Допустимые значения |
|----------|---------------------|
| `CompatibilityMode` | `Version8_3_20` ... `Version8_3_28`, `Version8_5_1`, `DontUse` |
| `ConfigurationExtensionCompatibilityMode` | то же |
| `DefaultRunMode` | `ManagedApplication`, `OrdinaryApplication`, `Auto` |
| `ScriptVariant` | `Russian`, `English` |
| `DataLockControlMode` | `Managed`, `Automatic`, `AutomaticAndManaged` |
| `ObjectAutonumerationMode` | `NotAutoFree`, `AutoFree` |
| `ModalityUseMode` | `DontUse`, `Use`, `UseWithWarnings` |
| `SynchronousPlatformExtensionAndAddInCallUseMode` | `DontUse`, `Use`, `UseWithWarnings` |
| `InterfaceCompatibilityMode` | `Version8_2`, `Version8_2EnableTaxi`, `Taxi`, `TaxiEnableVersion8_2`, `TaxiEnableVersion8_5`, `Version8_5EnableTaxi`, `Version8_5` |
| `DatabaseTablespacesUseMode` | `DontUse`, `Use` |
| `MainClientApplicationWindowMode` | `Normal`, `Fullscreen`, `Kiosk` |

### Ref
`DefaultLanguage` — значение вида `Language.Русский`

### Формат batch
`"Version=1.0.0.1 ;; Vendor=Фирма 1С ;; Synonym=Тестовая конфигурация"`

## add-childObject / remove-childObject

Формат: `Type.Name` — XML-тип и имя объекта через точку.

**Важно про `add-childObject`**: регистрирует в `<ChildObjects>` объект, **файл которого уже существует на диске**. Если файла нет — exit 1. Для создания нового объекта используй профильный навык — `/meta-compile` (Catalog, Document, Enum, Report, регистры и т.д.), `/role-compile` (Role), `/subsystem-compile` (Subsystem). Они создают файл И регистрируют его за один вызов.

Batch: `"Catalog.Товары ;; Document.Заказ ;; Enum.ВидыОплат"`

## add-defaultRole / remove-defaultRole / set-defaultRoles

Имя роли: `ПолныеПрава` или `Role.ПолныеПрава` (префикс `Role.` добавляется автоматически).

`set-defaultRoles` полностью заменяет список ролей.

## set-panels

Перезаписывает `Ext/ClientApplicationInterface.xml` — раскладку панелей рабочего пространства Taxi. Файл создаётся с нуля; то, что не упомянуто в `value`, отсутствует на экране.

`value` — объект с ключами `top`, `left`, `right`, `bottom`. Каждый ключ — массив записей. Ключ можно опустить (= пустая сторона).

**Запись** — одна из:
- Строка-алиас (одна панель в этом слоте)
- Объект `{"group": [...]}` (стек: панели/подгруппы внутри располагаются друг под другом)

**Алиасы панелей:**

| Алиас | Панель |
|-------|--------|
| `sections` | Панель разделов |
| `open` | Панель открытых |
| `favorites` | Панель избранного |
| `history` | Панель истории |
| `functions` | Панель функций текущего раздела |

**Семантика:**
- Несколько записей в одной стороне → отдельные слоты «рядом» (несколько тегов `<top>`/...)
- `{"group":[...]}` → один тег с `<group>`-обёрткой, элементы внутри идут стеком

**Пример** (DefinitionFile):
```json
[
  {
    "operation": "set-panels",
    "value": {
      "top":    ["open"],
      "left":   ["sections"],
      "right":  [{ "group": ["favorites", "history"] }],
      "bottom": ["functions"]
    }
  }
]
```

Через `-Value` (CLI): передай объект как JSON-строку — `... -Operation set-panels -Value '{"top":["open"]}'`.

## set-home-page

Перезаписывает `Ext/HomePageWorkArea.xml` — раскладка форм на начальной странице (рабочая область). Файл создаётся с нуля; то, что не упомянуто в `value`, отсутствует.

`value` — объект:

| Ключ | Канонич. (XML) | Описание |
|------|----------------|----------|
| `template` | `WorkingAreaTemplate` | `OneColumn` / `TwoColumnsEqualWidth` (дефолт) / `TwoColumnsVariableWidth` |
| `left` | `LeftColumn` | массив записей форм |
| `right` | `RightColumn` | массив записей форм (запрещён при `OneColumn`) |

Принимаются и короткие и канонич. ключи (XML-имена) — оба работают.

**Запись формы** — одна из:
- Строка `"<form>"` — только имя формы, дефолты `height=10`, `visibility=true`
- Объект `{form, height?, visibility?, roles?}`

| Поле | Канонич. | Дефолт | Описание |
|------|----------|--------|----------|
| `form` | `Form` | — | `CommonForm.X` или `Type.Object.Form.Name` (или UUID) |
| `height` | `Height` | `10` | Высота |
| `visibility` | `Visibility` | `true` | Общая видимость (`<xr:Common>`) |
| `roles` | — | — | `{"Role.Имя": true|false, ...}` — переопределения по ролям |

**Семантика visibility:** `visibility` = общее правило, `roles` — точечные исключения. Скрыть для всех кроме одной роли: `{"visibility": false, "roles": {"Role.Опер": true}}`.

**Пример:**
```json
[
  {
    "operation": "set-home-page",
    "value": {
      "template": "TwoColumnsVariableWidth",
      "left": [
        "CommonForm.НачалоРаботы",
        { "form": "CommonForm.СписокЗадач", "height": 100, "visibility": false },
        { "form": "Catalog.Контрагенты.Form.ФормаСписка", "height": 50 },
        {
          "form": "CommonForm.РабочийСтолОператора",
          "visibility": false,
          "roles": { "Role.Оператор": true, "Role.ПолныеПрава": false }
        }
      ],
      "right": [
        { "form": "DataProcessor.Поиск.Form.ФормаПоиска", "height": 30 }
      ]
    }
  }
]
```

## DefinitionFile (JSON)

```json
[
  { "operation": "modify-property", "value": "Version=2.0.0.1 ;; Vendor=Test" },
  { "operation": "add-childObject", "value": "Catalog.Товары ;; Document.Заказ" },
  { "operation": "add-defaultRole", "value": "ПолныеПрава" }
]
```

