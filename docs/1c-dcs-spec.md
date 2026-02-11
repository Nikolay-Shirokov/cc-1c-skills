# Спецификация XML-формата схемы компоновки данных 1С (DCS)

Спецификация формата `DataCompositionSchema` — макетов типа «Схема компоновки данных» в конфигурации 1С:Предприятие 8.3.
Составлена на основе анализа 930 схем конфигурации «Бухгалтерия предприятия 3.0.180» (платформа 8.3.24).

---

## 0. Файловая структура

### Два файла на каждую схему

```
<Объект>/Templates/
  ИмяМакета.xml                  ← метаданные (UUID, имя, TemplateType)
  ИмяМакета/
    Ext/
      Template.xml               ← тело схемы (DataCompositionSchema)
```

Типичные имена макетов: `ОсновнаяСхемаКомпоновкиДанных`, `СхемаКомпоновкиДанных`, произвольные.

### Метаданные макета — шаблон

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    version="2.17">
  <Template uuid="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX">
    <Properties>
      <Name>ОсновнаяСхемаКомпоновкиДанных</Name>
      <Synonym>
        <v8:item>
          <v8:lang>ru</v8:lang>
          <v8:content>Основная схема компоновки данных</v8:content>
        </v8:item>
      </Synonym>
      <Comment/>
      <TemplateType>DataCompositionSchema</TemplateType>
    </Properties>
  </Template>
</MetaDataObject>
```

Значение `TemplateType` для DCS всегда: **`DataCompositionSchema`**.

### Где встречаются DCS-макеты

| Тип объекта метаданных | Частота | Примечание |
|---|---|---|
| Reports (Отчёты) | ~420 | Основное место — каждый отчёт СКД |
| DataProcessors (Обработки) | ~11 | Обработки с отчётными функциями |
| Enums (Перечисления) | ~20 | Дополнительные ссылки |
| Catalogs (Справочники) | ~5 | Запросы к справочным данным |
| DocumentJournals | ~4 | Журналы документов |
| CommonTemplates | ~3 | Общие макеты |
| InformationRegisters | ~2 | Регистры сведений |
| Documents (Документы) | ~1 | Редко |

---

## 1. Пространства имён

Корневой элемент — `<DataCompositionSchema>`.

```xml
<DataCompositionSchema
    xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"
    xmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"
    xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
    xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
```

| Префикс | URI | Назначение |
|---|---|---|
| *(default)* | `.../data-composition-system/schema` | Элементы схемы (dataSource, dataSet, field, parameter, ...) |
| `dcscom` | `.../data-composition-system/common` | Общие типы СКД (dimension, account, role, ...) |
| `dcscor` | `.../data-composition-system/core` | Ядро СКД (Field, SettingsParameterValue, ChoiceParameterLinks, ...) |
| `dcsset` | `.../data-composition-system/settings` | Настройки варианта (selection, filter, order, group, ...) |
| `v8` | `.../data/core` | Типы данных ядра (LocalStringType, Type, StandardPeriod, ...) |
| `v8ui` | `.../data/ui` | UI-типы (HorizontalAlign, ...) |
| `xs` | `.../XMLSchema` | Стандартные XSD-типы (string, dateTime, boolean, decimal, ...) |
| `xsi` | `.../XMLSchema-instance` | Атрибуты экземпляра (xsi:type, xsi:nil) |

Дополнительные пространства имён (появляются в `settingsVariant`):

| Префикс | URI | Где |
|---|---|---|
| `style` | `http://v8.1c.ru/8.1/data/ui/style` | В settings — стили оформления |
| `sys` | `http://v8.1c.ru/8.1/data/ui/fonts/system` | В settings — системные шрифты |
| `web` | `http://v8.1c.ru/8.1/data/ui/colors/web` | В settings — веб-цвета |
| `win` | `http://v8.1c.ru/8.1/data/ui/colors/windows` | В settings — цвета Windows |

---

## 2. Общая структура DataCompositionSchema

Элементы верхнего уровня (порядок фиксирован):

```
DataCompositionSchema
├── dataSource*              — источники данных (раздел 3)
├── dataSet*                 — наборы данных (раздел 4)
├── dataSetLink*             — связи между наборами (раздел 5)
├── calculatedField*         — вычисляемые поля (раздел 6)
├── totalField*              — итоговые поля (раздел 7)
├── parameter*               — параметры схемы (раздел 8)
├── template*                — макеты областей (раздел 9)
├── groupTemplate*           — привязки макетов группировок (раздел 10)
├── settingsVariant*         — варианты настроек (раздел 11)
```

`*` — 0..N элементов.

Минимальная DCS содержит: 1 dataSource + 1 dataSet + 1 settingsVariant.

---

## 3. Источники данных (dataSource)

```xml
<dataSource>
  <name>ИсточникДанных1</name>
  <dataSourceType>Local</dataSourceType>
</dataSource>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `name` | да | Уникальное имя, на которое ссылаются наборы данных |
| `dataSourceType` | да | Тип: `Local` (текущая информационная база) или `External` (внешний) |

В подавляющем большинстве случаев — один источник `Local`. Имя произвольное: `ИсточникДанных1`, `ИнформационнаяБаза` и т.п.

---

## 4. Наборы данных (dataSet)

Тип набора определяется атрибутом `xsi:type`. Три типа:

### 4.1. DataSetQuery — запрос

Самый распространённый тип. Содержит SQL-подобный запрос на языке 1С.

```xml
<dataSet xsi:type="DataSetQuery">
  <name>НаборДанных1</name>
  <field xsi:type="DataSetFieldField">...</field>   <!-- 0..N полей -->
  <dataSource>ИсточникДанных1</dataSource>
  <query>ВЫБРАТЬ ... ИЗ ...</query>
  <autoFillFields>false</autoFillFields>             <!-- опционально -->
</dataSet>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `name` | да | Уникальное имя набора |
| `field` | нет | Описания полей (раздел 4.4) |
| `dataSource` | да | Ссылка на имя dataSource |
| `query` | да | Текст запроса на языке 1С (XML-экранирование: `&amp;` для `&`, `&gt;` для `>`) |
| `autoFillFields` | нет | `false` — отключить автозаполнение полей из запроса (по умолчанию `true`) |

#### Особенности запросов в DCS

- Параметры: `&ИмяПараметра` (в XML: `&amp;ИмяПараметра`)
- Авторазметка полей в фигурных скобках: `{ВЫБРАТЬ ...}`, `{ГДЕ ...}`, `{ЛЕВОЕ СОЕДИНЕНИЕ ...}` — позволяют СКД автоматически модифицировать запрос
- Пакетные запросы: несколько запросов через `; ////////////////`
- Временные таблицы: `ПОМЕСТИТЬ ИмяВТ`, `ИНДЕКСИРОВАТЬ ПО`

### 4.2. DataSetObject — объект

Данные берутся из программно заполненной таблицы значений.

```xml
<dataSet xsi:type="DataSetObject">
  <name>НаборДанных1</name>
  <field xsi:type="DataSetFieldField">...</field>
  <dataSource>ИсточникДанных1</dataSource>
  <objectName>ТаблицаПроверки</objectName>
</dataSet>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `objectName` | да | Имя объекта (таблицы значений), передаваемого программно |

### 4.3. DataSetUnion — объединение

Объединяет поля из нескольких наборов. Сам не содержит запросов — объединяет подчинённые наборы.

```xml
<dataSet xsi:type="DataSetUnion">
  <name>РасчетНалога</name>
  <field xsi:type="DataSetFieldField">...</field>   <!-- агрегированные поля -->
  <item xsi:type="DataSetQuery">                     <!-- вложенные наборы -->
    <name>ДанныеПоСтоимости</name>
    ...
  </item>
  <item xsi:type="DataSetQuery">
    <name>ДанныеПоКадастру</name>
    ...
  </item>
</dataSet>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `field` | нет | Поля объединения (описывают результирующие колонки) |
| `item` | да | Вложенные наборы (DataSetQuery или другие) |

### 4.4. Поля набора данных (field)

Каждое поле — элемент `<field xsi:type="DataSetFieldField">`:

```xml
<field xsi:type="DataSetFieldField">
  <dataPath>ОстаточнаяСтоимость</dataPath>
  <field>ОстаточнаяСтоимость</field>
  <title xsi:type="v8:LocalStringType">
    <v8:item>
      <v8:lang>ru</v8:lang>
      <v8:content>Остаточная стоимость</v8:content>
    </v8:item>
  </title>
  <useRestriction>
    <condition>true</condition>
  </useRestriction>
  <role>
    <dcscom:dimension>true</dcscom:dimension>
  </role>
  <valueType>
    <v8:Type>xs:string</v8:Type>
    <v8:StringQualifiers>
      <v8:Length>11</v8:Length>
      <v8:AllowedLength>Variable</v8:AllowedLength>
    </v8:StringQualifiers>
  </valueType>
  <appearance>
    <dcscor:item xsi:type="dcsset:SettingsParameterValue">
      <dcscor:parameter>Формат</dcscor:parameter>
      <dcscor:value xsi:type="xs:string">ЧДЦ=2</dcscor:value>
    </dcscor:item>
  </appearance>
  <inputParameters>...</inputParameters>
  <presentationExpression>...</presentationExpression>
</field>
```

#### Элементы поля

| Элемент | Обязат. | Описание |
|---|---|---|
| `dataPath` | да | Путь к данным (имя поля в результате СКД). Через точку — реквизиты: `Номенклатура.Артикул` |
| `field` | да | Имя поля в запросе (может отличаться от dataPath) |
| `title` | нет | Локализованный заголовок (`v8:LocalStringType`) |
| `useRestriction` | нет | Ограничения использования поля (раздел 4.5) |
| `attributeUseRestriction` | нет | Ограничения использования реквизитов поля (раздел 4.5) |
| `role` | нет | Роль поля в СКД (раздел 4.6) |
| `valueType` | нет | Тип значения поля (раздел 4.7) |
| `appearance` | нет | Оформление — список параметров `dcscor:item` (раздел 4.8) |
| `inputParameters` | нет | Параметры ввода / связи параметров выбора (раздел 4.9) |
| `presentationExpression` | нет | Выражение для формирования представления (на языке 1С) |

### 4.5. Ограничения использования поля (useRestriction / attributeUseRestriction)

```xml
<useRestriction>
  <field>true</field>         <!-- запрет использования как поле в выборке -->
  <condition>true</condition>  <!-- запрет в условиях отбора -->
  <group>true</group>          <!-- запрет в группировках -->
  <order>true</order>          <!-- запрет в сортировке -->
</useRestriction>
```

Каждый подэлемент — `true`/`false` (по умолчанию `false` = разрешено). Можно указывать подмножество.

`attributeUseRestriction` — аналогичная структура, применяется к реквизитам (дочерним полям) поля.

### 4.6. Роли полей (role)

```xml
<role>
  <dcscom:dimension>true</dcscom:dimension>          <!-- поле — измерение -->
  <dcscom:account>true</dcscom:account>               <!-- поле — счёт -->
  <dcscom:accountTypeExpression>Счет.Вид</dcscom:accountTypeExpression>  <!-- выражение типа счёта -->
</role>
```

| Подэлемент | Описание |
|---|---|
| `dcscom:dimension` | Поле является измерением (`true`/`false`) |
| `dcscom:account` | Поле является счётом |
| `dcscom:accountTypeExpression` | Выражение для определения типа счёта |
| `dcscom:balance` | Поле является остатком |
| `dcscom:balanceGroup` | Группа остатка |
| `dcscom:period` | Поле — период |

### 4.7. Тип значения (valueType)

```xml
<valueType>
  <v8:Type>xs:string</v8:Type>
  <v8:StringQualifiers>
    <v8:Length>11</v8:Length>
    <v8:AllowedLength>Variable</v8:AllowedLength>
  </v8:StringQualifiers>
</valueType>
```

Типы: `xs:string`, `xs:dateTime`, `xs:decimal`, `xs:boolean`, ссылочные типы конфигурации.

Ссылочные типы объявляются с inline namespace на элементе `<v8:Type>`:

```xml
<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:CatalogRef.Номенклатура</v8:Type>
```

Префикс (`d5p1`, `d4p1` и т.д.) — автогенерируемый, суть в URI `http://v8.1c.ru/8.1/data/enterprise/current-config`. Поддерживаются: `CatalogRef`, `DocumentRef`, `EnumRef`, `ChartOfAccountsRef`, `ChartOfCharacteristicTypesRef` и др.

Квалификаторы:
- `v8:StringQualifiers` → `v8:Length`, `v8:AllowedLength` (Fixed/Variable)
- `v8:DateQualifiers` → `v8:DateFractions` (Date/Time/DateTime)
- `v8:NumberQualifiers` → `v8:Digits`, `v8:FractionDigits`, `v8:AllowedSign` (Any/Nonnegative)

### 4.8. Оформление полей (appearance)

Список параметров оформления:

```xml
<appearance>
  <dcscor:item xsi:type="dcsset:SettingsParameterValue">
    <dcscor:parameter>Формат</dcscor:parameter>
    <dcscor:value xsi:type="xs:string">ЧДЦ=2</dcscor:value>
  </dcscor:item>
  <dcscor:item xsi:type="dcsset:SettingsParameterValue">
    <dcscor:parameter>ГоризонтальноеПоложение</dcscor:parameter>
    <dcscor:value xsi:type="v8ui:HorizontalAlign">Center</dcscor:value>
  </dcscor:item>
</appearance>
```

Типичные параметры оформления:

| Параметр | Тип значения | Пример |
|---|---|---|
| `Формат` | `xs:string` | `ЧДЦ=2`, `ЧГ=0`, `ЧН=0`, `ДФ=dd.MM.yyyy`, `Л=ru; ДФ=ММММ` |
| `ГоризонтальноеПоложение` | `v8ui:HorizontalAlign` | `Left`, `Center`, `Right` |

### 4.9. Параметры ввода (inputParameters)

Связи параметров выбора для интерактивных полей:

```xml
<inputParameters>
  <dcscor:item>
    <dcscor:parameter>СвязиПараметровВыбора</dcscor:parameter>
    <dcscor:value xsi:type="dcscor:ChoiceParameterLinks">
      <dcscor:item>
        <dcscor:choiceParameter>Отбор.Владелец</dcscor:choiceParameter>
        <dcscor:value>Организация</dcscor:value>
        <dcscor:mode xmlns:d8p1="http://v8.1c.ru/8.1/data/enterprise"
                     xsi:type="d8p1:LinkedValueChangeMode">Clear</dcscor:mode>
      </dcscor:item>
    </dcscor:value>
  </dcscor:item>
</inputParameters>
```

Используется для каскадных зависимостей в пользовательских настройках (например, подразделение зависит от организации).

---

## 5. Связи между наборами данных (dataSetLink)

Позволяют передавать параметры из одного набора в другой:

```xml
<dataSetLink>
  <sourceDataSet>Периоды</sourceDataSet>
  <destinationDataSet>ДанныеТ13</destinationDataSet>
  <sourceExpression>НачалоМесяца</sourceExpression>
  <destinationExpression>Месяц</destinationExpression>
  <parameter>НачалоМесяца</parameter>
  <parameterListAllowed>false</parameterListAllowed>
</dataSetLink>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `sourceDataSet` | да | Имя набора-источника |
| `destinationDataSet` | да | Имя целевого набора |
| `sourceExpression` | да | Выражение из источника (поле или формула) |
| `destinationExpression` | да | Выражение для сопоставления в целевом наборе |
| `parameter` | нет | Имя параметра для передачи значения |
| `parameterListAllowed` | нет | Допустим ли список значений (`true`/`false`) |

---

## 6. Вычисляемые поля (calculatedField)

Поля, вычисляемые выражением на языке 1С (не из запроса):

```xml
<calculatedField>
  <dataPath>УИД</dataPath>
  <expression>БухгалтерскиеОтчеты.ПолучитьУИДСсылкиСтрокой(Номенклатура)</expression>
  <title xsi:type="v8:LocalStringType">
    <v8:item>
      <v8:lang>ru</v8:lang>
      <v8:content>Уникальный идентификатор</v8:content>
    </v8:item>
  </title>
  <useRestriction>
    <condition>true</condition>
    <group>true</group>
    <order>true</order>
  </useRestriction>
</calculatedField>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `dataPath` | да | Путь к полю в результате |
| `expression` | да | Выражение на языке 1С (может вызывать методы общих модулей) |
| `title` | нет | Локализованный заголовок |
| `useRestriction` | нет | Ограничения использования (аналогично полям) |
| `valueType` | нет | Тип значения |
| `appearance` | нет | Оформление |

---

## 7. Итоговые поля (totalField)

Агрегатные функции для подведения итогов:

```xml
<totalField>
  <dataPath>Количество</dataPath>
  <expression>Сумма(Количество)</expression>
</totalField>
<totalField>
  <dataPath>Цена</dataPath>
  <expression>Максимум(Цена)</expression>
</totalField>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `dataPath` | да | Путь к полю |
| `expression` | да | Агрегатная функция: `Сумма(...)`, `Количество(...)`, `Максимум(...)`, `Минимум(...)`, `Среднее(...)` |
| `group` | нет | Имя группировки, для которой считать итоги. Без `group` — для всех группировок |

### Разные формулы для разных группировок

Одно поле может иметь несколько записей `totalField` с разными формулами для разных группировок:

```xml
<!-- Для группировки "ОбъектМетаданных" — агрегация самого поля -->
<totalField>
  <dataPath>ПравоИнтерактивное</dataPath>
  <expression>Максимум(ПравоИнтерактивное)</expression>
  <group>ОбъектМетаданных</group>
</totalField>
<!-- Для группировки "Отчет" — агрегация другого поля -->
<totalField>
  <dataPath>ПравоИнтерактивное</dataPath>
  <expression>Максимум(ПравоОтчета)</expression>
  <group>Отчет</group>
</totalField>
```

Это позволяет вычислять ресурс по-разному в зависимости от контекста группировки.

---

## 8. Параметры схемы (parameter)

Параметры, доступные для задания пользователем или программно:

```xml
<parameter>
  <name>Период</name>
  <title xsi:type="v8:LocalStringType">
    <v8:item>
      <v8:lang>ru</v8:lang>
      <v8:content>Период</v8:content>
    </v8:item>
  </title>
  <valueType>
    <v8:Type>v8:StandardPeriod</v8:Type>
  </valueType>
  <value xsi:type="v8:StandardPeriod">
    <v8:variant xsi:type="v8:StandardPeriodVariant">LastMonth</v8:variant>
  </value>
  <useRestriction>false</useRestriction>
  <expression>&amp;Период.ДатаНачала</expression>
  <availableAsField>false</availableAsField>
  <use>Always</use>
</parameter>
```

| Элемент | Обязат. | Описание |
|---|---|---|
| `name` | да | Имя параметра (используется в запросах как `&ИмяПараметра`) |
| `title` | нет | Локализованный заголовок |
| `valueType` | нет | Тип значения (раздел 4.7) |
| `value` | нет | Значение по умолчанию |
| `useRestriction` | нет | `true` — параметр скрыт от пользователя, `false` — доступен |
| `expression` | нет | Выражение для автоматического вычисления (например, `&Период.ДатаНачала`) |
| `availableAsField` | нет | `false` — параметр недоступен как поле в отчёте |
| `use` | нет | Режим: `Always` (всегда), `Auto` (автоматически) |

### Типы значений параметров

| Тип | XML-тип | Пример value |
|---|---|---|
| Дата | `xs:dateTime` | `0001-01-01T00:00:00` |
| Строка | `xs:string` | `Т13` |
| Стандартный период | `v8:StandardPeriod` | `<v8:variant>LastMonth</v8:variant>` |
| Ссылка | `d5p1:CatalogRef.ИмяСправочника` (с `xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config"`) | `xsi:nil="true"` |
| null | — | `xsi:nil="true"` |

Стандартные варианты периодов (`v8:StandardPeriodVariant`): `Custom`, `Today`, `ThisWeek`, `ThisMonth`, `ThisQuarter`, `ThisYear`, `LastMonth`, `LastQuarter`, `LastYear` и др.

---

## 9. Макеты областей (template)

Пользовательские шаблоны вывода (макеты ячеек):

```xml
<template>
  <name>Макет1</name>
  <template xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template"
            xsi:type="dcsat:AreaTemplate">
    <dcsat:item xsi:type="dcsat:TableRow">
      <dcsat:tableCell>
        <dcsat:item xsi:type="dcsat:Field">
          <dcsat:value xsi:type="dcscor:Parameter">ТипЦены</dcsat:value>
        </dcsat:item>
      </dcsat:tableCell>
    </dcsat:item>
  </template>
  <parameter xmlns:dcsat="http://v8.1c.ru/8.1/data-composition-system/area-template"
             xsi:type="dcsat:ExpressionAreaTemplateParameter">
    <dcsat:name>ТипЦены</dcsat:name>
    <dcsat:expression>Представление(ТипЦен)</dcsat:expression>
  </parameter>
</template>
```

Пространство имён `dcsat`: `http://v8.1c.ru/8.1/data-composition-system/area-template`.

| Элемент | Описание |
|---|---|
| `name` | Имя макета (ссылаются groupTemplate) |
| `template` (вложенный) | Описание строк/ячеек (`dcsat:AreaTemplate`) |
| `parameter` | Параметры макета (`dcsat:ExpressionAreaTemplateParameter`) — выражения для подстановки |

---

## 10. Привязки макетов группировок (groupTemplate)

Связывают группировку с пользовательским макетом:

```xml
<groupTemplate>
  <groupField>ТипЦен</groupField>
  <templateType>Header</templateType>
  <template>Макет1</template>
</groupTemplate>
```

| Элемент | Описание |
|---|---|
| `groupField` | Имя поля группировки |
| `templateType` | Тип: `Header` (заголовок), `Footer` (подвал), `Overall` (общий) |
| `template` | Ссылка на имя template из раздела 9 |

---

## 11. Варианты настроек (settingsVariant)

Каждый вариант — именованная конфигурация отчёта. Отчёт может иметь несколько вариантов.

```xml
<settingsVariant>
  <dcsset:name>Основной</dcsset:name>
  <dcsset:presentation xsi:type="v8:LocalStringType">
    <v8:item>
      <v8:lang>ru</v8:lang>
      <v8:content>Основной вариант отчёта</v8:content>
    </v8:item>
  </dcsset:presentation>
  <dcsset:settings xmlns:style="..." xmlns:sys="..." xmlns:web="..." xmlns:win="...">
    <!-- содержимое настроек -->
  </dcsset:settings>
</settingsVariant>
```

### 11.1. Структура settings

```
dcsset:settings
├── dcsset:selection              — выбранные поля (раздел 11.2)
├── dcsset:filter                 — отборы (раздел 11.3)
├── dcsset:order                  — сортировка (раздел 11.4)
├── dcsset:conditionalAppearance  — условное оформление (раздел 11.5)
├── dcsset:outputParameters       — параметры вывода (раздел 11.6)
├── dcsset:dataParameters         — значения параметров данных (раздел 11.7)
├── dcsset:item*                  — элементы структуры (раздел 11.8)
```

### 11.2. Выборка полей (selection)

```xml
<dcsset:selection>
  <dcsset:item xsi:type="dcsset:SelectedItemField">
    <dcsset:field>ТипОбъекта</dcsset:field>
    <dcsset:lwsTitle>                          <!-- опциональный заголовок -->
      <v8:item>
        <v8:lang>ru</v8:lang>
        <v8:content>Наименование</v8:content>
      </v8:item>
    </dcsset:lwsTitle>
  </dcsset:item>
  <dcsset:item xsi:type="dcsset:SelectedItemAuto"/>   <!-- авто-выбор -->
</dcsset:selection>
```

Типы элементов выборки:
- `dcsset:SelectedItemField` — конкретное поле (элемент `dcsset:field`)
- `dcsset:SelectedItemAuto` — автоматический подбор полей

### 11.3. Отборы (filter)

```xml
<dcsset:filter>
  <dcsset:item xsi:type="dcsset:FilterItemComparison">
    <dcsset:use>false</dcsset:use>                    <!-- включён/выключен -->
    <dcsset:left xsi:type="dcscor:Field">Организация</dcsset:left>
    <dcsset:comparisonType>Equal</dcsset:comparisonType>
    <dcsset:right xsi:type="xs:boolean">false</dcsset:right>
    <dcsset:presentation xsi:type="v8:LocalStringType">
      <v8:item>
        <v8:lang>ru</v8:lang>
        <v8:content>Описание фильтра</v8:content>
      </v8:item>
    </dcsset:presentation>
    <dcsset:viewMode>Normal</dcsset:viewMode>
    <dcsset:userSettingID>GUID</dcsset:userSettingID>
  </dcsset:item>
</dcsset:filter>
```

Типы элементов фильтра:
- `dcsset:FilterItemComparison` — сравнение поля с значением
- `dcsset:FilterItemGroup` — группа условий (И/ИЛИ)

Типы сравнения (`comparisonType`):

| Значение | Описание |
|---|---|
| `Equal` | Равно |
| `NotEqual` | Не равно |
| `Greater` | Больше |
| `GreaterOrEqual` | Больше или равно |
| `Less` | Меньше |
| `LessOrEqual` | Меньше или равно |
| `InList` | В списке |
| `NotInList` | Не в списке |
| `InHierarchy` | В иерархии |
| `InListByHierarchy` | В списке по иерархии |
| `Contains` | Содержит |
| `NotContains` | Не содержит |
| `BeginsWith` | Начинается с |
| `NotBeginsWith` | Не начинается с |
| `Filled` | Заполнено |
| `NotFilled` | Не заполнено |

Значение правой части (`right`) — может содержать списки:
```xml
<dcsset:right xsi:type="v8:ValueListType">
  <v8:valueType/>
  <v8:lastId xsi:type="xs:decimal">-1</v8:lastId>
</dcsset:right>
```

### 11.4. Сортировка (order)

```xml
<dcsset:order>
  <dcsset:item xsi:type="dcsset:OrderItemField">
    <dcsset:field>РазмерДанных</dcsset:field>
    <dcsset:orderType>Desc</dcsset:orderType>
  </dcsset:item>
  <dcsset:item xsi:type="dcsset:OrderItemAuto"/>
</dcsset:order>
```

Типы элементов сортировки:
- `dcsset:OrderItemField` — по полю (`dcsset:field` + `dcsset:orderType`: `Asc`/`Desc`)
- `dcsset:OrderItemAuto` — автоматическая сортировка

### 11.5. Условное оформление (conditionalAppearance)

```xml
<dcsset:conditionalAppearance>
  <dcsset:item>
    <dcsset:selection>
      <dcsset:item>
        <dcsset:field>ИмяПоля</dcsset:field>
      </dcsset:item>
    </dcsset:selection>
    <dcsset:filter>
      <dcsset:item xsi:type="dcsset:FilterItemComparison">
        <dcsset:left xsi:type="dcscor:Field">ИмяПоля</dcsset:left>
        <dcsset:comparisonType>Equal</dcsset:comparisonType>
        <dcsset:right xsi:type="xs:decimal">0</dcsset:right>
      </dcsset:item>
    </dcsset:filter>
    <dcsset:appearance>
      <dcscor:item xsi:type="dcsset:SettingsParameterValue">
        <dcscor:parameter>Текст</dcscor:parameter>
        <dcscor:value xsi:type="xs:string"/>
      </dcscor:item>
    </dcsset:appearance>
  </dcsset:item>
</dcsset:conditionalAppearance>
```

### 11.6. Параметры вывода (outputParameters)

```xml
<dcsset:outputParameters>
  <dcscor:item xsi:type="dcsset:SettingsParameterValue">
    <dcscor:use>false</dcscor:use>                     <!-- опционально -->
    <dcscor:parameter>Заголовок</dcscor:parameter>
    <dcscor:value xsi:type="v8:LocalStringType">
      <v8:item>
        <v8:lang>ru</v8:lang>
        <v8:content>Текст заголовка</v8:content>
      </v8:item>
    </dcscor:value>
  </dcscor:item>
</dcsset:outputParameters>
```

Типичные параметры вывода:

| Параметр | Тип значения | Описание |
|---|---|---|
| `Заголовок` | `v8:LocalStringType` | Заголовок отчёта |
| `МакетОформления` | `xs:string` | Имя макета оформления: `ОформлениеОтчетовЧерноБелый`, `Зеленый` и др. |
| `РасположениеПолейГруппировки` | `dcsset:DataCompositionGroupFieldsPlacement` | `Together`, `Separately`, `SeparatelyAndInGroups` |
| `РасположениеРеквизитов` | `dcsset:DataCompositionAttributesPlacement` | `Together`, `Separately`, `SeparatelyAndInGroups` |
| `ГоризонтальноеРасположениеОбщихИтогов` | `dcscor:DataCompositionTotalPlacement` | `None`, `Begin`, `End`, `Auto` |
| `ВертикальноеРасположениеОбщихИтогов` | `dcscor:DataCompositionTotalPlacement` | `None`, `Begin`, `End`, `Auto` |
| `ВыводитьЗаголовок` | `dcsset:DataCompositionTextOutputType` | `Auto`, `DontOutput`, `Output` |
| `ВыводитьПараметрыДанных` | `dcsset:DataCompositionTextOutputType` | То же |
| `ВыводитьОтбор` | `dcsset:DataCompositionTextOutputType` | То же |

### 11.7. Параметры данных (dataParameters)

Значения параметров схемы в конкретном варианте:

```xml
<dcsset:dataParameters>
  <dcscor:item xsi:type="dcsset:SettingsParameterValue">
    <dcscor:use>false</dcscor:use>
    <dcscor:parameter>Период</dcscor:parameter>
    <dcscor:value xsi:type="v8:StandardPeriod">
      <v8:variant xsi:type="v8:StandardPeriodVariant">LastMonth</v8:variant>
    </dcscor:value>
    <dcsset:viewMode>Normal</dcsset:viewMode>
    <dcsset:userSettingID>GUID</dcsset:userSettingID>
  </dcscor:item>
</dcsset:dataParameters>
```

| Элемент | Описание |
|---|---|
| `dcscor:use` | `true`/`false` — использовать значение или нет |
| `dcscor:parameter` | Имя параметра из раздела 8 |
| `dcscor:value` | Значение параметра |
| `dcsset:viewMode` | Режим отображения: `Normal`, `QuickAccess`, `Inaccessible` |
| `dcsset:userSettingID` | GUID пользовательской настройки |

### 11.8. Элементы структуры (structure items)

Структура отчёта — иерархия группировок, таблиц, диаграмм.

#### StructureItemGroup — группировка

```xml
<dcsset:item xsi:type="dcsset:StructureItemGroup">
  <dcsset:name>Группировка</dcsset:name>
  <dcsset:groupItems>
    <dcsset:item xsi:type="dcsset:GroupItemField">
      <dcsset:field>Организация</dcsset:field>
      <dcsset:groupType>Items</dcsset:groupType>
      <dcsset:periodAdditionType>None</dcsset:periodAdditionType>
      <dcsset:periodAdditionBegin xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionBegin>
      <dcsset:periodAdditionEnd xsi:type="xs:dateTime">0001-01-01T00:00:00</dcsset:periodAdditionEnd>
    </dcsset:item>
  </dcsset:groupItems>
  <dcsset:order>
    <dcsset:item xsi:type="dcsset:OrderItemAuto"/>
  </dcsset:order>
  <dcsset:selection>
    <dcsset:item xsi:type="dcsset:SelectedItemAuto"/>
  </dcsset:selection>
  <dcsset:outputParameters>...</dcsset:outputParameters>
  <dcsset:item xsi:type="dcsset:StructureItemGroup">  <!-- вложенная группировка -->
    ...
  </dcsset:item>
</dcsset:item>
```

Типы группировки (`groupType`): `Items`, `Hierarchy`, `HierarchyOnly`.

Типы дополнения периодом (`periodAdditionType`): `None`, `Year`, `HalfYear`, `Quarter`, `Month`, `TenDays`, `Week`, `Day`.

Пустая группировка (без `groupItems`) = детальные записи.

#### StructureItemTable — таблица (кросс-таблица)

```xml
<dcsset:item xsi:type="dcsset:StructureItemTable">
  <dcsset:name>Таблица</dcsset:name>
  <dcsset:column>                               <!-- группировки колонок -->
    <dcsset:groupItems>...</dcsset:groupItems>
    <dcsset:order>...</dcsset:order>
    <dcsset:selection>...</dcsset:selection>
  </dcsset:column>
  <dcsset:row>                                  <!-- группировки строк -->
    <dcsset:name>Группировка</dcsset:name>
    <dcsset:groupItems>...</dcsset:groupItems>
    <dcsset:order>...</dcsset:order>
    <dcsset:selection>...</dcsset:selection>
  </dcsset:row>
</dcsset:item>
```

#### StructureItemChart — диаграмма

```xml
<dcsset:item xsi:type="dcsset:StructureItemChart">
  <dcsset:point>                                <!-- точки (ось X) -->
    <dcsset:groupItems>...</dcsset:groupItems>
    <dcsset:order>...</dcsset:order>
    <dcsset:selection>...</dcsset:selection>
  </dcsset:point>
  <dcsset:series>                               <!-- серии (необязательно) -->
    <dcsset:groupItems>...</dcsset:groupItems>
    ...
  </dcsset:series>
  <dcsset:selection>                            <!-- значения для отображения -->
    <dcsset:item xsi:type="dcsset:SelectedItemField">
      <dcsset:field>РазмерДанных</dcsset:field>
    </dcsset:item>
  </dcsset:selection>
  <dcsset:outputParameters>...</dcsset:outputParameters>
</dcsset:item>
```

---

## 12. Типы данных — сводка

### v8:LocalStringType — локализованная строка

```xml
<title xsi:type="v8:LocalStringType">
  <v8:item>
    <v8:lang>ru</v8:lang>
    <v8:content>Текст на русском</v8:content>
  </v8:item>
</title>
```

Также можно задать как простую строку: `xsi:type="xs:string"`.

### dcscor:SettingsParameterValue — параметр настройки

```xml
<dcscor:item xsi:type="dcsset:SettingsParameterValue">
  <dcscor:use>true</dcscor:use>                <!-- опционально -->
  <dcscor:parameter>ИмяПараметра</dcscor:parameter>
  <dcscor:value xsi:type="ТипЗначения">Значение</dcscor:value>
</dcscor:item>
```

### dcscor:Field — ссылка на поле

```xml
<dcsset:left xsi:type="dcscor:Field">ИмяПоля</dcsset:left>
```

---

## 13. Полный минимальный пример

Простая DCS: один запрос, два поля, один итог, один вариант:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"
    xmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"
    xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
    xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dataSource>
    <name>ИсточникДанных1</name>
    <dataSourceType>Local</dataSourceType>
  </dataSource>
  <dataSet xsi:type="DataSetQuery">
    <name>НаборДанных1</name>
    <field xsi:type="DataSetFieldField">
      <dataPath>Наименование</dataPath>
      <field>Наименование</field>
      <title xsi:type="v8:LocalStringType">
        <v8:item>
          <v8:lang>ru</v8:lang>
          <v8:content>Наименование</v8:content>
        </v8:item>
      </title>
    </field>
    <field xsi:type="DataSetFieldField">
      <dataPath>Количество</dataPath>
      <field>Количество</field>
    </field>
    <dataSource>ИсточникДанных1</dataSource>
    <query>ВЫБРАТЬ
	Номенклатура.Наименование КАК Наименование,
	КОЛИЧЕСТВО(1) КАК Количество
ИЗ
	Справочник.Номенклатура КАК Номенклатура
СГРУППИРОВАТЬ ПО
	Номенклатура.Наименование</query>
  </dataSet>
  <totalField>
    <dataPath>Количество</dataPath>
    <expression>Сумма(Количество)</expression>
  </totalField>
  <settingsVariant>
    <dcsset:name>Основной</dcsset:name>
    <dcsset:presentation xsi:type="v8:LocalStringType">
      <v8:item>
        <v8:lang>ru</v8:lang>
        <v8:content>Основной</v8:content>
      </v8:item>
    </dcsset:presentation>
    <dcsset:settings xmlns:style="http://v8.1c.ru/8.1/data/ui/style"
        xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"
        xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"
        xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows">
      <dcsset:selection>
        <dcsset:item xsi:type="dcsset:SelectedItemField">
          <dcsset:field>Наименование</dcsset:field>
        </dcsset:item>
        <dcsset:item xsi:type="dcsset:SelectedItemField">
          <dcsset:field>Количество</dcsset:field>
        </dcsset:item>
      </dcsset:selection>
      <dcsset:item xsi:type="dcsset:StructureItemGroup">
        <dcsset:order>
          <dcsset:item xsi:type="dcsset:OrderItemAuto"/>
        </dcsset:order>
        <dcsset:selection>
          <dcsset:item xsi:type="dcsset:SelectedItemAuto"/>
        </dcsset:selection>
      </dcsset:item>
    </dcsset:settings>
  </settingsVariant>
</DataCompositionSchema>
```
