---
name: role-compile
description: Создание роли 1С — метаданные и Rights.xml из описания прав
argument-hint: <RoleName> <RolesDir>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /role-compile — создание роли 1С

Создаёт файлы роли (метаданные + Rights.xml) по описанию прав. Скрипта нет — агент генерирует XML по шаблонам ниже.

## Использование

```
/role-compile <RoleName> <RolesDir>
```

- **RoleName** — программное имя роли (например, `ВыполнениеРегламентныхЗаданий`)
- **RolesDir** — каталог `Roles/` в исходниках конфигурации или обработки

## Что создать

### 1. Файл метаданных: `Roles/<RoleName>.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"
        xmlns:v8="http://v8.1c.ru/8.1/data/core"
        xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
        xmlns:xs="http://www.w3.org/2001/XMLSchema"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        version="2.17">
    <Role uuid="GENERATE-UUID-HERE">
        <Properties>
            <Name>ИмяРоли</Name>
            <Synonym>
                <v8:item>
                    <v8:lang>ru</v8:lang>
                    <v8:content>Отображаемое имя роли</v8:content>
                </v8:item>
            </Synonym>
            <Comment/>
        </Properties>
    </Role>
</MetaDataObject>
```

**UUID:** Сгенерируй через PowerShell: `[guid]::NewGuid().ToString()`

**Namespace:** Минимальный набор — достаточно `xmlns`, `v8`, `xr`, `xs`, `xsi`. Полный набор из спецификации тоже корректен.

### 2. Файл прав: `Roles/<RoleName>/Ext/Rights.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Rights xmlns="http://v8.1c.ru/8.2/roles"
        xmlns:xs="http://www.w3.org/2001/XMLSchema"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xsi:type="Rights" version="2.17">
    <setForNewObjects>false</setForNewObjects>
    <setForAttributesByDefault>true</setForAttributesByDefault>
    <independentRightsOfChildObjects>false</independentRightsOfChildObjects>
    <!-- объекты с правами -->
</Rights>
```

### 3. Регистрация в Configuration.xml

Добавь `<Role>ИмяРоли</Role>` в секцию `<ChildObjects>` файла `Configuration.xml`.

## Формат блока прав

Каждый объект — отдельный блок `<object>`:

```xml
<object>
    <name>ТипОбъекта.ИмяОбъекта</name>
    <right>
        <name>ИмяПрава</name>
        <value>true</value>
    </right>
</object>
```

Несколько прав — несколько `<right>` внутри одного `<object>`.

## Права по типам объектов (краткая справка)

### Ссылочные объекты данных

| Тип | Типичные права |
|-----|---------------|
| `Catalog` | Read, Insert, Update, Delete, View, Edit, InputByString, InteractiveInsert, InteractiveSetDeletionMark, InteractiveClearDeletionMark, InteractiveDelete |
| `Document` | (все Catalog) + Posting, UndoPosting, InteractivePosting, InteractivePostingRegular, InteractiveUndoPosting, InteractiveChangeOfPosted |
| `ChartOfAccounts` | (как Catalog) + предопределённые: InteractiveDeletePredefinedData и др. |
| `ChartOfCharacteristicTypes` | (как ChartOfAccounts) |
| `ChartOfCalculationTypes` | (как ChartOfAccounts) |
| `ExchangePlan` | (как Catalog) |
| `BusinessProcess` | (как Catalog) + Start, InteractiveStart, InteractiveActivate |
| `Task` | (как Catalog) + Execute, InteractiveExecute, InteractiveActivate |

### Регистры

| Тип | Права |
|-----|-------|
| `InformationRegister` | Read, Update, View, Edit, TotalsControl |
| `AccumulationRegister` | Read, Update, View, Edit, TotalsControl |
| `AccountingRegister` | Read, Update, View, Edit, TotalsControl |
| `CalculationRegister` | Read, View |

### Простые типы

| Тип | Права |
|-----|-------|
| `DataProcessor` | Use, View |
| `Report` | Use, View |
| `Constant` | Read, Update, View, Edit |
| `CommonForm` | View |
| `CommonCommand` | View |
| `Subsystem` | View |
| `DocumentJournal` | Read, View |
| `Sequence` | Read, Update |
| `SessionParameter` | Get, Set |
| `CommonAttribute` | View, Edit |
| `WebService` / `HTTPService` / `IntegrationService` | Use |

### Вложенные объекты

| Вложенный тип | Права | Пример |
|--------------|-------|--------|
| `*.StandardAttribute.*` | View, Edit | `Document.Реализация.StandardAttribute.Posted` |
| `*.Attribute.*` | View, Edit | `Catalog.Контрагенты.Attribute.ИНН` |
| `*.TabularSection.*` | View, Edit | `Document.Реализация.TabularSection.Товары` |
| `*Register.*.Dimension.*` | View, Edit | `InformationRegister.Цены.Dimension.Номенклатура` |
| `*Register.*.Resource.*` | View, Edit | `InformationRegister.Цены.Resource.Цена` |
| `*.Command.*` | View | `Catalog.Контрагенты.Command.Открыть` |

### Configuration

Права на конфигурацию в целом: `Configuration.ИмяКонфигурации`

Ключевые: Administration, DataAdministration, ThinClient, WebClient, ThickClient, ExternalConnection, Output, SaveUserData, InteractiveOpenExtDataProcessors, InteractiveOpenExtReports

## Типичные наборы прав

### Чтение справочника

```xml
<object>
    <name>Catalog.Номенклатура</name>
    <right><name>Read</name><value>true</value></right>
    <right><name>View</name><value>true</value></right>
    <right><name>InputByString</name><value>true</value></right>
</object>
```

### Полные права на документ

```xml
<object>
    <name>Document.РеализацияТоваровУслуг</name>
    <right><name>Read</name><value>true</value></right>
    <right><name>Insert</name><value>true</value></right>
    <right><name>Update</name><value>true</value></right>
    <right><name>Delete</name><value>true</value></right>
    <right><name>Posting</name><value>true</value></right>
    <right><name>UndoPosting</name><value>true</value></right>
    <right><name>View</name><value>true</value></right>
    <right><name>InteractiveInsert</name><value>true</value></right>
    <right><name>Edit</name><value>true</value></right>
    <right><name>InteractiveSetDeletionMark</name><value>true</value></right>
    <right><name>InteractiveClearDeletionMark</name><value>true</value></right>
    <right><name>InteractivePosting</name><value>true</value></right>
    <right><name>InteractivePostingRegular</name><value>true</value></right>
    <right><name>InteractiveUndoPosting</name><value>true</value></right>
    <right><name>InteractiveChangeOfPosted</name><value>true</value></right>
    <right><name>InputByString</name><value>true</value></right>
</object>
```

### Использование обработки

```xml
<object>
    <name>DataProcessor.ОбновлениеЦен</name>
    <right><name>Use</name><value>true</value></right>
    <right><name>View</name><value>true</value></right>
</object>
```

### Чтение/запись регистра

```xml
<object>
    <name>InformationRegister.ЦеныНоменклатуры</name>
    <right><name>Read</name><value>true</value></right>
    <right><name>Update</name><value>true</value></right>
    <right><name>View</name><value>true</value></right>
    <right><name>Edit</name><value>true</value></right>
</object>
```

## Полная спецификация

См. [1c-role-spec.md](../../docs/1c-role-spec.md) — полный каталог прав, RLS, шаблоны ограничений, версии формата.
