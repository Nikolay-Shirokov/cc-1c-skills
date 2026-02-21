# Спецификация формата выгрузки расширений конфигурации 1С (CFE)

Формат: XML-выгрузка расширения конфигурации 1С:Предприятие 8.3 (Конфигуратор → Конфигурация → Расширения → Выгрузить расширение в файлы).
Версия формата: `2.17` (платформа 8.3.17–8.3.24).

> **Связанные спецификации:**
> - Корневая структура конфигурации — [1c-configuration-spec.md](1c-configuration-spec.md)
> - Объекты метаданных — [1c-config-objects-spec.md](1c-config-objects-spec.md)
> - Подсистемы — [1c-subsystem-spec.md](1c-subsystem-spec.md)
> - Управляемые формы — [1c-form-spec.md](1c-form-spec.md)
> - Роли — [1c-role-spec.md](1c-role-spec.md)
> - Сводный индекс — [1c-specs-index.md](1c-specs-index.md)

---

## 1. Общая структура выгрузки расширения

```
Configuration.xml                  # Корневой файл — свойства и состав расширения
ConfigDumpInfo.xml                 # Служебный файл — версии объектов
Languages/                         # Языки (всегда заимствованные)
Roles/                             # Роли (собственные)
Subsystems/                        # Подсистемы (собственные или заимствованные)
CommonModules/                     # Общие модули
CommonPictures/                    # Общие картинки
CommonCommands/                    # Общие команды
Catalogs/                          # Справочники
Documents/                         # Документы
Enums/                             # Перечисления
...                                # Другие типы объектов
```

### Ключевые отличия от конфигурации

| Аспект | Конфигурация | Расширение |
|--------|-------------|------------|
| Корневой `Ext/` | Есть (модули, интерфейс, справка) | **Нет** |
| `ObjectBelonging` в Properties | Нет | `Adopted` (всегда) |
| `ConfigurationExtensionPurpose` | Нет | `Patch` / `Customization` / `AddOn` |
| `KeepMappingToExtendedConfigurationObjectsByIDs` | Нет | `true` / `false` |
| `NamePrefix` | Пустой или нет | Префикс для собственных объектов |
| `CompatibilityMode` | Да | Нет (используется `ConfigurationExtensionCompatibilityMode`) |
| Свойства режимов работы | Полный набор | Сокращённый набор |
| Объекты в ChildObjects | Только собственные | Собственные **и заимствованные** |

---

## 2. Configuration.xml — корневой файл расширения

### 2.1. Общая структура

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
    ... version="2.17">
  <Configuration uuid="...">
    <InternalInfo>...</InternalInfo>
    <Properties>...</Properties>
    <ChildObjects>...</ChildObjects>
  </Configuration>
</MetaDataObject>
```

Пространства имён и корневой элемент идентичны конфигурации. Атрибут `version` соответствует версии формата выгрузки.

### 2.2. InternalInfo

Содержит 7 записей `xr:ContainedObject` — аналогично конфигурации. ClassId фиксированные, ObjectId уникальны для каждого расширения.

### 2.3. Properties — свойства расширения

Свойства идут в фиксированном порядке. Набор свойств **отличается** от конфигурации — часть свойств специфична для расширений, часть свойств конфигурации отсутствует.

#### Специфичные свойства расширения

| Свойство | Тип | Описание |
|----------|-----|----------|
| `ObjectBelonging` | enum | Всегда `Adopted` — расширение «принято» к основной конфигурации |
| `ConfigurationExtensionPurpose` | enum | Назначение расширения: `Patch` (исправление), `Customization` (адаптация), `AddOn` (дополнение) |
| `KeepMappingToExtendedConfigurationObjectsByIDs` | `xs:boolean` | Сохранять привязку к объектам по идентификаторам |
| `NamePrefix` | `xs:string` | Префикс имён собственных объектов (напр. `Расш1_`, `МоёРасш_`) |
| `ConfigurationExtensionCompatibilityMode` | enum | Режим совместимости расширения (`Version8_3_17`, `Version8_3_24`, ...) |

#### Общие свойства (совпадают с конфигурацией)

| Свойство | Тип | Описание |
|----------|-----|----------|
| `Name` | `xs:string` | Имя расширения (идентификатор) |
| `Synonym` | `LocalString` | Отображаемое имя |
| `Comment` | `xs:string` | Комментарий |
| `DefaultRunMode` | enum | Режим запуска (`ManagedApplication`) |
| `UsePurposes` | list | Назначения (`PlatformApplication`) |
| `ScriptVariant` | enum | Язык скриптов (`Russian` / `English`) |
| `DefaultRoles` | list | Роли по умолчанию |
| `Vendor` | `xs:string` | Поставщик |
| `Version` | `xs:string` | Версия расширения |
| `DefaultLanguage` | ref | Язык по умолчанию (`Language.Русский`) |
| `BriefInformation` | `LocalString` | Краткая информация |
| `DetailedInformation` | `LocalString` | Подробная информация |
| `Copyright` | `LocalString` | Авторские права |
| `VendorInformationAddress` | `LocalString` | Адрес поставщика |
| `ConfigurationInformationAddress` | `LocalString` | Адрес информации |
| `InterfaceCompatibilityMode` | enum | Совместимость интерфейса |

> **Примечание:** Свойства `DefaultRunMode`, `UsePurposes`, `DefaultRoles`, `DefaultLanguage`, `InterfaceCompatibilityMode` **опциональны** — могут отсутствовать в расширении (в отличие от конфигурации, где они обязательны).

#### Свойства конфигурации, отсутствующие в расширении

В расширениях **нет** следующих свойств:
- `CompatibilityMode` (заменено на `ConfigurationExtensionCompatibilityMode`)
- `DataLockControlMode`
- `ObjectAutonumerationMode`
- `ModalityUseMode`
- `SynchronousPlatformExtensionAndAddInCallUseMode`
- `DatabaseTablespacesUseMode`
- `MainClientApplicationWindowMode`
- `UpdateCatalogAddress`
- `IncludeHelpInContents`
- `UseManagedFormInOrdinaryApplication`
- `UseOrdinaryFormInManagedApplication`
- `Content`
- `StandaloneConfigurationRestrictionRoles`

### 2.4. Порядок свойств

```xml
<Properties>
  <ObjectBelonging>Adopted</ObjectBelonging>
  <Name>ИмяРасширения</Name>
  <Synonym>...</Synonym>
  <Comment/>
  <ConfigurationExtensionPurpose>Patch</ConfigurationExtensionPurpose>
  <KeepMappingToExtendedConfigurationObjectsByIDs>true</KeepMappingToExtendedConfigurationObjectsByIDs>
  <NamePrefix>Расш1_</NamePrefix>
  <ConfigurationExtensionCompatibilityMode>Version8_3_17</ConfigurationExtensionCompatibilityMode>
  <DefaultRunMode>ManagedApplication</DefaultRunMode>          <!-- опционально -->
  <UsePurposes>...</UsePurposes>                                <!-- опционально -->
  <ScriptVariant>Russian</ScriptVariant>
  <DefaultRoles>...</DefaultRoles>                              <!-- опционально -->
  <Vendor/>
  <Version/>
  <DefaultLanguage>Language.Русский</DefaultLanguage>           <!-- опционально -->
  <BriefInformation/>
  <DetailedInformation/>
  <Copyright/>
  <VendorInformationAddress/>
  <ConfigurationInformationAddress/>
  <InterfaceCompatibilityMode>TaxiEnableVersion8_2</InterfaceCompatibilityMode>  <!-- опционально -->
</Properties>
```

### 2.5. ChildObjects — состав расширения

Содержит как **собственные** объекты расширения, так и **заимствованные** из основной конфигурации. Порядок типов аналогичен конфигурации.

```xml
<ChildObjects>
  <Language>Русский</Language>                          <!-- заимствованный -->
  <Subsystem>Расш1_МояПодсистема</Subsystem>              <!-- собственный -->
  <CommonPicture>Расш1_МояКартинка</CommonPicture>       <!-- собственный -->
  <Role>Расш1_ОсновнаяРоль</Role>                        <!-- собственный -->
  <CommonModule>Расш1_МодульСервер</CommonModule>         <!-- собственный -->
  <CommonModule>ОбщийМодульКонфигурации</CommonModule>    <!-- заимствованный -->
  <Catalog>Контрагенты</Catalog>                         <!-- заимствованный -->
  <Catalog>Расш1_Проекты</Catalog>                       <!-- собственный -->
  <Enum>Расш1_ВидыДокументов</Enum>                      <!-- собственный -->
  <InformationRegister>Расш1_ДатыРабот</InformationRegister> <!-- собственный -->
</ChildObjects>
```

В `ChildObjects` не видно различие между собственными и заимствованными — оно определяется по содержимому XML-файла объекта (свойство `ObjectBelonging` и наличие `ExtendedConfigurationObject`).

**Правило именования:** собственные объекты расширения обычно имеют `NamePrefix` в начале имени (напр. `Расш1_Справочник1`, `Расш1_Проекты`), заимствованные — имя объекта из основной конфигурации без префикса (напр. `Контрагенты`, `Валюты`).

---

## 3. ConfigDumpInfo.xml

Формат идентичен конфигурации:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ConfigDumpInfo xmlns="http://v8.1c.ru/8.3/xcf/dumpinfo"
    xmlns:xen="http://v8.1c.ru/8.3/xcf/enums"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    format="Hierarchical" version="2.17">
  <ConfigVersions>
    <Metadata name="Configuration.ИмяРасширения" id="uuid" configVersion="sha1"/>
    <Metadata name="Language.Русский" id="uuid" configVersion="sha1"/>
    <Metadata name="Role.Расш1_ОсновнаяРоль" id="uuid" configVersion="sha1"/>
    <!-- ... все объекты расширения ... -->
  </ConfigVersions>
</ConfigDumpInfo>
```

Включает записи для **всех** объектов расширения (и собственных, и заимствованных). Атрибут `configVersion` — 40-символьный SHA1-хеш версии объекта.

---

## 4. Заимствованные и собственные объекты

Расширение может содержать два типа объектов:

### 4.1. Заимствованные объекты (Adopted)

Объекты, существующие в основной конфигурации, которые расширение модифицирует или дополняет.

**Признаки:**
- `<ObjectBelonging>Adopted</ObjectBelonging>` в Properties
- `<ExtendedConfigurationObject>uuid</ExtendedConfigurationObject>` — UUID объекта в основной конфигурации
- Минимальный набор свойств (только те, что изменяются)

```xml
<Catalog uuid="81de7e56-...">
  <InternalInfo>
    <xr:GeneratedType name="CatalogObject.Валюты" category="Object">...</xr:GeneratedType>
    <!-- ... стандартные GeneratedType ... -->
  </InternalInfo>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>Валюты</Name>
    <Comment/>
    <ExtendedConfigurationObject>7aadbb67-...</ExtendedConfigurationObject>
  </Properties>
  <ChildObjects>
    <!-- заимствованные и собственные реквизиты, формы -->
  </ChildObjects>
</Catalog>
```

Заимствованные объекты **не содержат** полного набора свойств — только `ObjectBelonging`, `Name`, `Comment`, `ExtendedConfigurationObject` и те свойства, которые расширение изменяет (напр. `CodeLength`, `DefaultListForm`).

### 4.2. Собственные объекты (Own)

Объекты, созданные непосредственно в расширении.

**Признаки:**
- **Нет** элемента `ObjectBelonging`
- **Нет** элемента `ExtendedConfigurationObject`
- Полный набор свойств (как в объектах конфигурации)
- Имя обычно начинается с `NamePrefix` расширения

```xml
<Catalog uuid="7dcd4d14-...">
  <InternalInfo>
    <xr:GeneratedType name="CatalogObject.Расш5_Справочник1" category="Object">...</xr:GeneratedType>
    <!-- ... -->
  </InternalInfo>
  <Properties>
    <Name>Расш5_Справочник1</Name>
    <Synonym/>
    <Comment/>
    <Hierarchical>false</Hierarchical>
    <CodeLength>9</CodeLength>
    <!-- ... полный набор свойств как в конфигурации ... -->
  </Properties>
  <ChildObjects/>
</Catalog>
```

Формат полностью совпадает с форматом объектов конфигурации (см. [1c-config-objects-spec.md](1c-config-objects-spec.md)).

---

## 5. Заимствованные дочерние элементы

Дочерние элементы заимствованных объектов (реквизиты, табличные части, значения перечислений) также маркируются как заимствованные или собственные.

### 5.1. Заимствованные реквизиты

```xml
<Attribute uuid="259e5f94-...">
  <InternalInfo/>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ОсновнаяВалюта</Name>
    <Comment/>
    <ExtendedConfigurationObject>206abcd3-...</ExtendedConfigurationObject>
    <Type>
      <v8:Type>cfg:CatalogRef.Валюты</v8:Type>
    </Type>
  </Properties>
</Attribute>
```

Заимствованный реквизит содержит `ObjectBelonging: Adopted` и `ExtendedConfigurationObject`. Набор свойств минимальный (Name, Comment, ExtendedConfigurationObject, Type).

### 5.2. Собственные реквизиты в заимствованном объекте

```xml
<Attribute uuid="7fabdcb4-...">
  <Properties>
    <Name>Расш5_Реквизит1</Name>
    <Synonym/>
    <Comment/>
    <Type>
      <v8:Type>cfg:CatalogRef.Расш5_Справочник1</v8:Type>
    </Type>
    <PasswordMode>false</PasswordMode>
    <!-- ... полный набор свойств ... -->
  </Properties>
</Attribute>
```

Собственный реквизит **не имеет** `ObjectBelonging` и `ExtendedConfigurationObject`. Содержит полный набор свойств.

### 5.3. Заимствованные значения перечислений

```xml
<EnumValue uuid="9bc7380f-...">
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>НаценкаНаКурсДругойВалюты</Name>
    <ExtendedConfigurationObject>c9ab3890-...</ExtendedConfigurationObject>
    <Synonym>...</Synonym>
    <Comment/>
  </Properties>
</EnumValue>
```

### 5.4. Формы в расширениях

В расширении существуют **два принципиально разных сценария** работы с формами:

| Сценарий | Описание | `<BaseForm>` | ID элементов | `callType` |
|----------|----------|:------------:|:------------:|:----------:|
| **Собственная форма** на заимствованном объекте | Новая форма, не существующая в базовой конфигурации | Нет | Обычные (1+) | Нет |
| **Заимствованная форма** | Расширение существующей формы базовой конфигурации | Есть | Базовые + 1000000+ | Есть |

> **Как отличить:** Если файл метаданных формы (`.xml`) содержит `<ObjectBelonging>Adopted</ObjectBelonging>` — это заимствованная форма. Собственные формы не имеют `ObjectBelonging`.

#### 5.4.1. Метаданные заимствованной формы

Файл `.xml` в каталоге `Forms/`:

```xml
<Form uuid="8fcebcc1-...">
  <InternalInfo/>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ФормаСписка</Name>
    <Comment/>
    <ExtendedConfigurationObject>5f91b00f-...</ExtendedConfigurationObject>
    <FormType>Managed</FormType>
  </Properties>
</Form>
```

Содержимое формы хранится в `Forms/ФормаСписка/Ext/Form.xml`, модуль формы — в `Forms/ФормаСписка/Ext/Form/Module.bsl`.

#### 5.4.2. Структура Form.xml заимствованной формы

Form.xml заимствованной формы — **двухчастный файл**:

```xml
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" ... version="2.17">

  <!-- ═══ ЧАСТЬ 1: Результирующая форма (база + изменения расширения) ═══ -->
  <AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
    <ChildItems>
      <!-- Элементы базовой формы -->
      <Popup name="ГруппаПараметры" id="154">...</Popup>
      <!-- Элементы, добавленные расширением -->
      <Button name="ФормаНоваяКоманда" id="159">
        <CommandName>Form.Command.НоваяКоманда</CommandName>
        ...
      </Button>
    </ChildItems>
  </AutoCommandBar>
  <Events>
    <Event name="OnCreateAtServer" callType="After">Расш1_ПриСозданииПосле</Event>
  </Events>
  <ChildItems>
    <!-- Все элементы: базовые + добавленные расширением -->
  </ChildItems>
  <Attributes>
    <Attribute name="РеквизитФормы" id="1000001">...</Attribute>
  </Attributes>
  <Commands>
    <Command name="НоваяКоманда" id="1000000">
      <Action callType="Override">Расш1_НоваяКомандаВместо</Action>
    </Command>
  </Commands>

  <!-- ═══ ЧАСТЬ 2: Оригинальная форма из базовой конфигурации ═══ -->
  <BaseForm version="2.17">
    <AutoCommandBar name="ФормаКоманднаяПанель" id="-1">...</AutoCommandBar>
    <ChildItems>
      <!-- Только оригинальные элементы базовой конфигурации -->
    </ChildItems>
    <Attributes/>
    <Commands>...</Commands>
  </BaseForm>

</Form>
```

**Ключевые правила:**

1. **Часть 1** (до `<BaseForm>`) — **результирующая форма**, содержит ВСЕ элементы: и базовые, и добавленные расширением. Именно эта часть определяет итоговую форму при запуске.

2. **Часть 2** (`<BaseForm>`) — **полная копия оригинальной формы** из базовой конфигурации. Используется платформой для контроля совместимости — при обновлении конфигурации платформа сравнивает `<BaseForm>` с текущей формой конфигурации и предупреждает о расхождениях.

3. Элемент `<BaseForm>` всегда идёт **последним** в `<Form>` и имеет атрибут `version`.

#### 5.4.3. Нумерация ID элементов

| Диапазон | Принадлежность |
|----------|---------------|
| `-1` | Авто-командная панель (`AutoCommandBar`) — фиксированный ID |
| `1` – `999999` | Элементы базовой формы (сохраняют оригинальные ID) |
| `1000000`+ | Реквизиты (`Attributes`) и команды (`Commands`), добавленные расширением |

> **Важно:** Визуальные элементы форм (элементы в `ChildItems`), добавленные расширением в тело базовой формы, могут использовать ID из обычного диапазона (продолжая нумерацию базовой формы). Диапазон 1000000+ гарантирован для `Attributes` и `Commands`.

#### 5.4.4. Атрибут callType — перехват событий и команд

В заимствованных формах события и действия команд используют атрибут `callType` для определения момента перехвата:

| Значение | Описание |
|----------|----------|
| `Before` | Обработчик расширения вызывается **до** оригинального обработчика |
| `After` | Обработчик расширения вызывается **после** оригинального обработчика |
| `Override` | Обработчик расширения **заменяет** оригинальный обработчик |

##### События формы (form-level)

```xml
<Events>
  <Event name="OnCreateAtServer" callType="After">Расш1_ПриСозданииНаСервереПосле</Event>
  <Event name="OnOpen" callType="Before">Расш1_ПриОткрытииПеред</Event>
  <Event name="BeforeWriteAtServer" callType="After">Расш1_ПередЗаписьюНаСервереПосле</Event>
  <Event name="NotificationProcessing" callType="After">Расш1_ОбработкаОповещенияПосле</Event>
</Events>
```

##### События элементов формы (element-level)

```xml
<InputField name="Банк" id="37">
  <Events>
    <Event name="OnChange" callType="Before">Расш1_БанкПриИзменении</Event>
    <Event name="Clearing" callType="Before">Расш1_БанкОчистка</Event>
  </Events>
  ...
</InputField>

<Table name="СписокСпецификаций" id="102">
  <Events>
    <Event name="Selection" callType="Before">Расш1_СписокВыборПеред</Event>
  </Events>
  ...
</Table>
```

##### Действия команд (Command Action)

Команда может иметь **несколько элементов `<Action>`** с разными `callType`:

```xml
<!-- Перехват существующей команды базовой формы: до + после -->
<Command name="ПодборИзКлассификатора" id="1000002">
  <Action callType="Before">Расш1_ПодборИзКлассификатораПеред</Action>
  <Action callType="After">Расш1_ПодборИзКлассификатораПосле</Action>
</Command>

<!-- Полная замена обработчика команды -->
<Command name="НоваяКоманда" id="1000000">
  <Action callType="Override">Расш1_НоваяКомандаВместо</Action>
</Command>

<!-- Один перехват (только после) -->
<Command name="ЗапросКорректировки" id="1000005">
  <Action callType="After">Расш1_ЗапросКорректировкиПосле</Action>
</Command>
```

> **Отличие от обычной формы:** В обычной форме (конфигурации или собственной форме расширения) у `<Event>` и `<Action>` **нет** атрибута `callType` — обработчик вызывается напрямую.

#### 5.4.5. Собственная форма на заимствованном объекте

Расширение может добавить к заимствованному объекту **собственную форму**, не существующую в базовой конфигурации. Такая форма:

- **Не имеет** `ObjectBelonging` и `ExtendedConfigurationObject` в метаданных формы
- **Не содержит** `<BaseForm>` в Form.xml
- **Не использует** атрибут `callType`
- Использует обычную нумерацию ID (1+)
- Формат полностью совпадает с форматом форм конфигурации (см. [1c-form-spec.md](1c-form-spec.md))

```xml
<!-- Метаданные: Forms/МояФорма.xml — без ObjectBelonging -->
<Form uuid="...">
  <Properties>
    <Name>Расш1_МояФорма</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <FormType>Managed</FormType>
    <UsePurposes>...</UsePurposes>
  </Properties>
</Form>
```

```xml
<!-- Содержимое: Forms/МояФорма/Ext/Form.xml — обычная форма без BaseForm -->
<Form ... version="2.17">
  <Events>
    <Event name="OnCreateAtServer">ПриСозданииНаСервере</Event>
  </Events>
  <ChildItems>...</ChildItems>
  <Attributes>...</Attributes>
</Form>
```

#### 5.4.6. Модуль заимствованной формы

Модуль формы (`Forms/Имя/Ext/Form/Module.bsl`) в заимствованной форме использует те же декораторы перехвата, что и другие модули расширений (см. раздел 7.2):

```bsl
&НаСервере
&Вместо("ЗаполнитьПодменюПараметры")
Процедура Расш1_ЗаполнитьПодменюПараметры()
    ПродолжитьВызов();
КонецПроцедуры

&НаКлиенте
&ИзменениеИКонтроль("ПараметрыНаЯзыке")
Функция Расш1_ПараметрыНаЯзыке(КодЯзыка)
    // ... тело с #Вставка / #Удаление маркерами ...
КонецФункции

// Обработчик собственной команды расширения (без декоратора)
&НаКлиенте
Процедура Расш1_НоваяКомандаВместо(Команда)
    // ...
КонецПроцедуры
```

> **Обработчики событий с `callType`** (определённые в Form.xml секции Events/Action) реализуются в модуле как обычные процедуры **без** аннотаций-декораторов — привязка к событию уже задана в XML через `callType`.

---

## 6. Расширение свойств (xr:PropertyState и xr:ExtendedProperty)

Расширения могут изменять свойства заимствованных реквизитов. Для этого используются специальные XML-конструкции.

### 6.1. PropertyState — уведомление об изменении

Элемент `xr:PropertyState` в `InternalInfo` реквизита указывает, что свойство было изменено расширением.

```xml
<Attribute uuid="a1752169-...">
  <InternalInfo>
    <xr:PropertyState>
      <xr:Property>Type</xr:Property>
      <xr:State>Notify</xr:State>
    </xr:PropertyState>
  </InternalInfo>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>Наценка</Name>
    <ExtendedConfigurationObject>87429f11-...</ExtendedConfigurationObject>
    <Type>
      <v8:Type>xs:decimal</v8:Type>
      <v8:NumberQualifiers>
        <v8:Digits>10</v8:Digits>
        <v8:FractionDigits>2</v8:FractionDigits>
        <v8:AllowedSign>Any</v8:AllowedSign>
      </v8:NumberQualifiers>
    </Type>
  </Properties>
</Attribute>
```

Значения `xr:State`:
| Значение | Описание |
|----------|----------|
| `Notify` | Свойство изменено расширением, платформа выводит предупреждение |
| `MultiState` | Свойство расширено (тип отличается от основной конфигурации) |

### 6.2. ExtendedProperty — расширение типа

Когда расширение изменяет тип реквизита, используется конструкция `xr:ExtendedProperty`:

```xml
<Type xsi:type="xr:ExtendedProperty">
  <xr:ExtendValue xsi:type="v8:TypeDescription">
    <v8:Type>xs:string</v8:Type>
    <v8:StringQualifiers>
      <v8:Length>60</v8:Length>
      <v8:AllowedLength>Variable</v8:AllowedLength>
    </v8:StringQualifiers>
  </xr:ExtendValue>
</Type>
```

Свойство `Type` получает атрибут `xsi:type="xr:ExtendedProperty"`, а значение оборачивается в `xr:ExtendValue`. При этом в `InternalInfo` указывается `<xr:State>MultiState</xr:State>`.

---

## 7. Модули в расширениях

### 7.1. Типы модулей

Расширения поддерживают те же типы модулей, что и конфигурация:

| Модуль | Файл | Для каких объектов |
|--------|------|--------------------|
| Модуль объекта | `Ext/ObjectModule.bsl` | Справочники, документы, обработки |
| Модуль менеджера | `Ext/ManagerModule.bsl` | Справочники, документы, регистры |
| Модуль набора записей | `Ext/RecordSetModule.bsl` | Регистры |
| Модуль формы | `Forms/Имя/Ext/Form/Module.bsl` | Формы |
| Общий модуль | `CommonModules/Имя/Ext/Module.bsl` | Общие модули |
| Модуль команды | `Commands/Имя/Ext/CommandModule.bsl` | Команды |

### 7.2. Декораторы перехвата

Модули расширений используют специальные **аннотации-декораторы** для перехвата вызовов процедур основной конфигурации:

| Декоратор | Описание |
|-----------|----------|
| `&Перед("ИмяПроцедуры")` | Выполняется **до** оригинальной процедуры |
| `&После("ИмяПроцедуры")` | Выполняется **после** оригинальной процедуры |
| `&Вместо("ИмяПроцедуры")` | **Заменяет** оригинальную процедуру |
| `&ИзменениеИКонтроль("ИмяПроцедуры")` | Копия с контролем изменений (diff-маркеры) |

#### Пример &Перед / &После

```bsl
&НаКлиенте
&Перед("ПодборИзКлассификатора")
Процедура Расш5_ПодборИзКлассификатораПеред(Команда)
    // Код выполняется ДО оригинальной процедуры
КонецПроцедуры

&НаКлиенте
&После("ПодборИзКлассификатора")
Процедура Расш5_ПодборИзКлассификатораПосле(Команда)
    // Код выполняется ПОСЛЕ оригинальной процедуры
КонецПроцедуры
```

#### Пример &Вместо

```bsl
&НаСервере
&Вместо("ЗаполнитьПодменюПараметрыПрописиВалюты")
Процедура Расш5_ЗаполнитьПодменюПараметрыПрописиВалюты()
    // Полная замена оригинальной процедуры
    // ПродолжитьВызов() — вызов оригинальной реализации
    ПродолжитьВызов();
КонецПроцедуры
```

#### Пример &ИзменениеИКонтроль

```bsl
&ИзменениеИКонтроль("РеквизитыРедактируемыеВГрупповойОбработке")
Функция Расш5_РеквизитыРедактируемыеВГрупповойОбработке()
    Результат = Новый Массив;
    Результат.Добавить("СпособУстановкиКурса");
#Удаление
    Результат.Добавить("ФормулаРасчетаКурса");
#КонецУдаления
#Вставка
    Результат.Добавить("НоваяФормулаРасчетаКурса");
#КонецВставки
    Возврат Результат;
КонецФункции
```

### 7.3. Diff-маркеры в коде

Внутри процедур с декоратором `&ИзменениеИКонтроль` используются diff-маркеры для отслеживания изменений:

| Маркер | Описание |
|--------|----------|
| `#Удаление` | Начало блока удалённого кода |
| `#КонецУдаления` | Конец блока удалённого кода |
| `#Вставка` | Начало блока вставленного кода |
| `#КонецВставки` | Конец блока вставленного кода |

Маркеры могут быть вложенными и чередующимися — типичный паттерн «удалить → вставить»:

```bsl
#Удаление
    ИначеЕсли Выборка.Дата > Дата Тогда
#КонецУдаления
#Вставка
    ИначеЕсли Выборка.Дата < Дата Тогда
#КонецВставки
```

### 7.4. Именование процедур расширения

Собственные процедуры расширения именуются с `NamePrefix`:
- `Расш5_ПрочитатьАрхивВнутр()` — при `NamePrefix = Расш5_`
- `МоёРасш_ПроверитьДату()` — при `NamePrefix = МоёРасш_`
- `Расш1_ПриОпределенииНастроек()` — при `NamePrefix = Расш1_`

---

## 8. Предопределённые элементы в расширениях

Расширения могут добавлять предопределённые элементы к заимствованным справочникам. Файл: `Каталог/Ext/Predefined.xml`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PredefinedData xmlns="http://v8.1c.ru/8.3/xcf/predef"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:type="CatalogPredefinedItems" version="2.17">
  <Item id="9b751d8b-...">
    <Name>НовыйЭлемент</Name>
    <Code>000000001</Code>
    <Description>Новый элемент</Description>
    <IsFolder>false</IsFolder>
    <ExtensionState>Native</ExtensionState>
  </Item>
</PredefinedData>
```

### Отличие от Predefined.xml конфигурации

| Аспект | Конфигурация | Расширение |
|--------|-------------|------------|
| Пространство имён | `http://v8.1c.ru/8.3/xcf/predef` (то же) | То же |
| `ExtensionState` | Нет | `Native` — элемент создан расширением |

---

## 9. Языки (Languages/)

Язык в расширении **всегда** заимствованный:

```xml
<Language uuid="9453bb96-...">
  <InternalInfo/>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>Русский</Name>
    <Comment/>
    <ExtendedConfigurationObject>0663bf5b-...</ExtendedConfigurationObject>
    <LanguageCode>ru</LanguageCode>
  </Properties>
</Language>
```

UUID в `ExtendedConfigurationObject` одинаков для всех расширений одной конфигурации — это UUID языка в основной конфигурации.

---

## 10. Роли (Roles/)

### 10.1. Собственная роль расширения (без прав)

Минимальная роль без `Ext/Rights.xml`:

```xml
<Role uuid="c630865b-...">
  <Properties>
    <Name>Расш1_ОсновнаяРоль</Name>
    <Synonym/>
    <Comment/>
  </Properties>
</Role>
```

Собственные роли расширений в изученных примерах **не имеют** каталога `Ext/` с `Rights.xml`. Права могут задаваться через конфигуратор.

### 10.2. DefaultRoles

Ссылки на роли по умолчанию в Configuration.xml:

```xml
<DefaultRoles>
  <xr:Item xsi:type="xr:MDObjectRef">Role.Расш1_ОсновнаяРоль</xr:Item>
</DefaultRoles>
```

---

## 11. Подсистемы (Subsystems/)

### 11.1. Собственная подсистема расширения

```xml
<Subsystem uuid="...">
  <Properties>
    <Name>Расш1_МояПодсистема</Name>
    <Synonym>...</Synonym>
    <Comment/>
    <Picture>
      <xr:Ref>CommonPicture.Расш1_МояКартинка</xr:Ref>
    </Picture>
    <IncludeHelpInContents>false</IncludeHelpInContents>
    <IncludeInCommandInterface>true</IncludeInCommandInterface>
    <Content>
      <xr:Item xsi:type="xr:MDObjectRef">Catalog.Расш1_Проекты</xr:Item>
      <xr:Item xsi:type="xr:MDObjectRef">Catalog.Расш1_Задачи</xr:Item>
      <xr:Item xsi:type="xr:MDObjectRef">DataProcessor.Расш1_Обработка1</xr:Item>
      <!-- ... -->
    </Content>
  </Properties>
  <ChildObjects/>
</Subsystem>
```

### 11.2. Заимствованная подсистема

```xml
<Subsystem uuid="...">
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>Закупки</Name>
    <ExtendedConfigurationObject>f230c0c7-...</ExtendedConfigurationObject>
    <Content>
      <!-- пустой или с добавленными объектами -->
    </Content>
  </Properties>
  <ChildObjects>
    <Subsystem>Расш1_Документы</Subsystem>   <!-- дочерняя подсистема -->
  </ChildObjects>
</Subsystem>
```

Заимствованная подсистема может содержать элементы `Content` (добавленные расширением команды/объекты) и дочерние подсистемы в `ChildObjects`.

### 11.3. CommandInterface в расширении

Командный интерфейс подсистемы в расширении: `Subsystems/Имя/Ext/CommandInterface.xml`.

```xml
<CommandInterface version="2.17">
  <CommandsVisibility>
    <xr:Command>
      <xr:CommandID>Document.ЗаказНаПеремещение.StandardCommand.OpenList</xr:CommandID>
      <xr:Visibility>
        <xr:Common>false</xr:Common>
        <xr:Value name="Role.Расш1_ОсновнаяРоль">true</xr:Value>
      </xr:Visibility>
    </xr:Command>
  </CommandsVisibility>
  <CommandsOrder>
    <xr:Group name="NavigationPanelOrdinary">
      <xr:CommandID>...</xr:CommandID>
    </xr:Group>
  </CommandsOrder>
</CommandInterface>
```

---

## 12. Общие модули (CommonModules/)

### 12.1. Заимствованный общий модуль

```xml
<CommonModule uuid="a32b77fa-...">
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ZipАрхивы</Name>
    <ExtendedConfigurationObject>b92e2bb8-...</ExtendedConfigurationObject>
  </Properties>
</CommonModule>
```

Модуль расширения: `CommonModules/ZipАрхивы/Ext/Module.bsl` — содержит процедуры с декораторами перехвата.

### 12.2. Собственный общий модуль

Формат аналогичен конфигурации (без `ObjectBelonging` и `ExtendedConfigurationObject`), со всеми свойствами (Server, ExternalConnection, ClientManagedApplication и т.д.).

---

## 13. Другие типы заимствованных объектов

### 13.1. Константы

```xml
<Constant uuid="...">
  <InternalInfo>
    <xr:GeneratedType name="ConstantManager.ИмяКонстанты" category="ConstantManager">...</xr:GeneratedType>
    <xr:GeneratedType name="ConstantValueManager.ИмяКонстанты" category="ConstantValueManager">...</xr:GeneratedType>
    <xr:GeneratedType name="ConstantValueKey.ИмяКонстанты" category="ConstantValueKey">...</xr:GeneratedType>
  </InternalInfo>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяКонстанты</Name>
    <ExtendedConfigurationObject>81d26b82-...</ExtendedConfigurationObject>
    <Type>
      <v8:Type>xs:boolean</v8:Type>
    </Type>
  </Properties>
</Constant>
```

### 13.2. Функциональные опции

```xml
<FunctionalOption uuid="...">
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяФункциональнойОпции</Name>
    <ExtendedConfigurationObject>d2699502-...</ExtendedConfigurationObject>
    <Location>Constant.ИмяКонстанты</Location>
  </Properties>
</FunctionalOption>
```

### 13.3. Определяемые типы

Заимствованный (минимальный):
```xml
<DefinedType uuid="...">
  <InternalInfo>
    <xr:GeneratedType name="DefinedType.ИмяОпределяемогоТипа" category="DefinedType">...</xr:GeneratedType>
  </InternalInfo>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяОпределяемогоТипа</Name>
  </Properties>
</DefinedType>
```

Собственный (с полным описанием типа):
```xml
<DefinedType uuid="...">
  <Properties>
    <Name>Расш1_Координата</Name>
    <Synonym>...</Synonym>
    <Type>
      <v8:Type>xs:decimal</v8:Type>
      <v8:NumberQualifiers>
        <v8:Digits>15</v8:Digits>
        <v8:FractionDigits>10</v8:FractionDigits>
        <v8:AllowedSign>Any</v8:AllowedSign>
      </v8:NumberQualifiers>
    </Type>
  </Properties>
</DefinedType>
```

### 13.4. Элементы стиля

```xml
<StyleItem uuid="...">
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяЭлементаСтиля</Name>
    <ExtendedConfigurationObject>3d428bdf-...</ExtendedConfigurationObject>
    <Type>Font</Type>
  </Properties>
</StyleItem>
```

Тип: `Color`, `Font`, `Border`.

### 13.5. Общие картинки

```xml
<CommonPicture uuid="...">
  <InternalInfo/>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяКартинки</Name>
  </Properties>
</CommonPicture>
```

Собственные картинки могут иметь каталог `Ext/` с `Picture.xml` и файлом изображения:

```
CommonPictures/Расш1_МояКартинка/
  Ext/
    Picture.xml          # <Picture><xr:Abs>Picture.png</xr:Abs>...</Picture>
    Picture/
      Picture.png        # Файл изображения
```

### 13.6. Общие команды

```xml
<CommonCommand uuid="...">
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяКоманды</Name>
    <Group>FormCommandBarImportant</Group>
  </Properties>
</CommonCommand>
```

### 13.7. Планы обмена

```xml
<ExchangePlan uuid="...">
  <InternalInfo>
    <xr:ThisNode>c335c2b8-...</xr:ThisNode>
    <xr:GeneratedType .../>
  </InternalInfo>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяПланаОбмена</Name>
    <ExtendedConfigurationObject>0c01b26a-...</ExtendedConfigurationObject>
  </Properties>
  <ChildObjects/>
</ExchangePlan>
```

### 13.8. Планы счетов

```xml
<ChartOfAccounts uuid="...">
  <InternalInfo>
    <xr:GeneratedType .../>
  </InternalInfo>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>Хозрасчетный</Name>
    <ExtendedConfigurationObject>3796bdf5-...</ExtendedConfigurationObject>
  </Properties>
  <ChildObjects/>
</ChartOfAccounts>
```

### 13.9. Регистры сведений

Заимствованный (минимальный):
```xml
<InformationRegister uuid="...">
  <InternalInfo>...</InternalInfo>
  <Properties>
    <ObjectBelonging>Adopted</ObjectBelonging>
    <Name>ИмяРегистра</Name>
    <ExtendedConfigurationObject>...</ExtendedConfigurationObject>
    <InformationRegisterPeriodicity>Quarter</InformationRegisterPeriodicity>
    <WriteMode>Independent</WriteMode>
  </Properties>
  <ChildObjects>
    <Resource uuid="...">
      <Properties>
        <ObjectBelonging>Adopted</ObjectBelonging>
        <Name>ИмяРесурса</Name>
        <ExtendedConfigurationObject>...</ExtendedConfigurationObject>
        <Type>...</Type>
      </Properties>
    </Resource>
  </ChildObjects>
</InformationRegister>
```

Собственный регистр — полный набор свойств, аналогично конфигурации.

---

## 14. Назначения расширений (ConfigurationExtensionPurpose)

| Значение | Русское название | Описание |
|----------|-----------------|----------|
| `Patch` | Исправление | Минимальные исправления ошибок. Наибольшие ограничения |
| `Customization` | Адаптация | Доработка под требования заказчика. Средний уровень ограничений |
| `AddOn` | Дополнение | Добавление новой функциональности. Минимальные ограничения |

Назначение влияет на то, какие модификации допускает платформа при подключении расширения.

---

## 15. Структура каталогов (сводка)

### 15.1. Собственный объект (полная структура)

```
Catalogs/Расш1_Проекты.xml                       # Метаданные (полные)
Catalogs/Расш1_Проекты/
  Ext/
    ObjectModule.bsl                             # Модуль объекта
    ManagerModule.bsl                            # Модуль менеджера
    Predefined.xml                               # Предопределённые (опц.)
  Forms/
    ФормаЭлемента.xml                            # Метаданные формы
    ФормаЭлемента/
      Ext/
        Form.xml                                 # Содержимое формы
        Form/
          Module.bsl                             # Модуль формы
    ФормаСписка.xml
    ФормаСписка/
      Ext/
        Form.xml
        Form/
          Module.bsl
  Templates/
    ПФ_MXL_Акт.xml                               # Метаданные макета
    ПФ_MXL_Акт/
      Ext/
        Template.xml                             # Содержимое макета
  Commands/
    ИмяКоманды.xml                               # Метаданные команды
    ИмяКоманды/
      Ext/
        CommandModule.bsl                        # Модуль команды
```

### 15.2. Заимствованный объект (минимальная структура)

```
Catalogs/Валюты.xml                              # Метаданные (сокращённые)
Catalogs/Валюты/
  Ext/
    ManagerModule.bsl                            # Расширение модуля менеджера
    Predefined.xml                               # Предопред. элементы (опц.)
  Forms/
    ФормаСписка.xml                              # Метаданные (сокращённые)
    ФормаСписка/
      Ext/
        Form.xml                                 # Расширение формы
        Form/
          Module.bsl                             # Расширение модуля формы
```

### 15.3. Минимальное расширение (пустое)

```
Configuration.xml                                # Корневой файл
ConfigDumpInfo.xml                               # Версии объектов
Languages/
  Русский.xml                                    # Язык (заимствованный)
```

### 15.4. Типичное расширение с ролью

```
Configuration.xml
ConfigDumpInfo.xml
Languages/
  Русский.xml
Roles/
  Расш1_ОсновнаяРоль.xml
```

---

## 16. Отличия заимствованного объекта от обычного (сводная таблица)

| Аспект | Обычный (конфигурация) | Заимствованный (расширение) | Собственный (расширение) |
|--------|----------------------|--------------------------|------------------------|
| `ObjectBelonging` | Нет | `Adopted` | Нет |
| `ExtendedConfigurationObject` | Нет | UUID объекта конфигурации | Нет |
| Набор Properties | Полный | Минимальный + изменённые | Полный |
| InternalInfo | GeneratedType | GeneratedType + PropertyState | GeneratedType |
| Реквизиты в ChildObjects | Полные | Заимствованные + собственные | Полные |
| Модули | Полные | С декораторами перехвата | Полные |
| Формы | Полные | С расширениями (Ext/) | Полные |
