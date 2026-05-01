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

**Важно про `add-childObject`**: операция регистрирует в `<ChildObjects>` Configuration.xml только объект, **файл которого уже существует на диске** (например `Catalogs/Товары.xml`). Если файла нет — скрипт падает с exit 1 и подсказкой. Для создания нового объекта используй профильный навык — `/meta-compile` (Catalog, Document, Enum, Report, регистры и т.д.), `/role-compile` (Role), `/subsystem-compile` (Subsystem). Они создают файл И регистрируют его в Configuration.xml за один вызов.

Когда `add-childObject` всё-таки нужен: откатили Configuration.xml (или перезаписали из выгрузки БД), а файлы объектов остались — нужно восстановить ссылки в `<ChildObjects>`.

При добавлении объект вставляется в каноническую позицию:
1. Находит последний элемент того же типа → вставляет после
2. Если тип отсутствует → находит последний элемент предшествующего типа → вставляет после
3. Внутри одного типа — алфавитный порядок

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

**Через `-Value`** (CLI): передавай тот же объект как JSON-строку:
```powershell
... -Operation set-panels -Value '{"top":["open"],"left":["sections"]}'
```

`<panelDef>` для всех 5 панелей пишется автоматически — они всегда доступны пользователю через «Вид → Настройка панелей», даже если не размещены по умолчанию.

## DefinitionFile (JSON)

```json
[
  { "operation": "modify-property", "value": "Version=2.0.0.1 ;; Vendor=Test" },
  { "operation": "add-childObject", "value": "Catalog.Товары ;; Document.Заказ" },
  { "operation": "add-defaultRole", "value": "ПолныеПрава" }
]
```

## Авто-валидация

После сохранения автоматически запускается `cf-validate` (если не указан `-NoValidate`).
