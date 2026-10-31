# XSD ↔ XDTO — справочник

## Соответствия

| XML Schema | Модель XDTO |
|---|---|
| `xs:schema/@targetNamespace` | пространство имён пакета |
| `elementFormDefault` / `attributeFormDefault` | `elementFormQualified` / `attributeFormQualified` |
| `xs:import/@namespace` | зависимость от другого пакета (разрешается по namespace) |
| `xs:complexType` | объектный тип |
| `xs:simpleType` | тип значения |
| `xs:element` / `xs:attribute` на верхнем уровне | глобальное свойство пакета |
| `xs:element` / `xs:attribute` внутри типа | свойство типа |
| `@minOccurs` / `@maxOccurs="unbounded"` | `lowerBound` / `upperBound="-1"` |
| `@nillable`, `@default`, `@fixed`, `@ref` | те же по смыслу |
| анонимный `xs:simpleType`/`xs:complexType` в объявлении | встроенный тип свойства |
| `xs:complexContent/xs:extension/@base` | наследование типа |
| `@abstract`, `@mixed` | те же |
| `xs:choice` | тип-выбор одного из вариантов |
| `xs:any` + `xs:anyAttribute` | открытый тип |
| `xs:simpleContent/xs:extension/@base` | свойство собственного значения элемента |
| `xs:restriction` + фасеты | базовый тип + ограничения |
| `xs:pattern`, `xs:enumeration` | те же |
| `xs:list/@itemType` | список |
| `xs:union/@memberTypes` | объединение |

Порядок объявлений верхнего уровня в XSD произвольный — навык сам расставит их
в порядке, который требует модель.

## Аннотации `xdto:`

Пространство имён — `http://v8.1c.ru/8.1/xdto`. Нужны только там, где XML Schema
не может выразить то, что умеет модель. В большинстве схем не нужны вовсе.

Правило: **чего XSD сказать не может — пиши атрибутом `xdto:` с тем же именем,
что и в модели**.

| Аннотация | Где | Назначение |
|---|---|---|
| `xdto:nillable` | `xs:attribute` | `nillable` у свойства-атрибута (XSD допускает только у элементов) |
| `xdto:lowerBound`, `xdto:upperBound` | `xs:attribute` | кратность свойства-атрибута |
| `xdto:qualified` | объявление | переопределение `*FormQualified` для одного свойства |
| `xdto:name` | объявление | имя свойства, если XML-имя не годится как идентификатор 1С; XML-имя уйдёт в `localName` |
| `xdto:form` | `xs:element` | записать `form` явно |
| `xdto:variety` | `xs:restriction`, `xs:list`, `xs:union` | записать разновидность типа явно |
| `xdto:open`, `xdto:abstract`, `xdto:mixed`, `xdto:ordered`, `xdto:sequenced` | `xs:complexType` | флаги типа, не выводимые из модели содержимого |
| `xdto:order` | `xs:complexType` | исходный порядок свойств, если он не «атрибуты первыми»; имена через `\|` |
| `xdto:textName`, `xdto:textlowerBound`, `xdto:textupperBound`, `xdto:textnillable` | `xs:extension` в `xs:simpleContent` | параметры свойства собственного значения |
| `xdto:type` | `xs:enumeration` | тип литерала перечисления |
| `xdto:prefix` | объявление | осмысленный префикс пространства имён вместо генерируемого |
| `xdto:memberTypesForm="prefixed"` | `xs:union` | записать состав объединения префиксами, а не `{ns}имя` |
| `xdto:declareNs` | `xs:union` | объявить префикс пространства имён на узле |
| `xdto:elementFormQualified`, `xdto:attributeFormQualified` | `xs:schema` | записать флаги явно |

Пример:

```xml
<xs:complexType name="КонтактнаяИнформация" xdto:sequenced="true">
    <xs:sequence>
        <xs:element name="Комментарий" type="xs:string" minOccurs="0"/>
        <xs:element name="Адрес по документу" type="xs:string"
                    xdto:name="Адрес_по_документу" minOccurs="0"/>
    </xs:sequence>
    <xs:attribute name="Представление" type="xs:string"
                  xdto:nillable="true" xdto:lowerBound="0"/>
</xs:complexType>
```

Аннотации, которые проставляет `/xdto-decompile` при выгрузке существующего пакета,
писать вручную не нужно — они нужны, чтобы обратная сборка вернула ровно тот же файл.

## Свойства объекта метаданных

```xml
<xs:annotation>
    <xs:appinfo>
        <xdto:package xmlns:xdto="http://v8.1c.ru/8.1/xdto">
            <xdto:name>ОбменСБанком</xdto:name>
            <xdto:synonym lang="ru">Обмен с банком</xdto:synonym>
            <xdto:synonym lang="en">Bank exchange</xdto:synonym>
            <xdto:comment>Формат 1С:Предприятие — Клиент банка</xdto:comment>
        </xdto:package>
    </xs:appinfo>
</xs:annotation>
```

Пространство имён пакета берётся из `targetNamespace` и здесь не дублируется.
Параметры `-Name`, `-Synonym`, `-Comment` имеют приоритет над этим блоком.
