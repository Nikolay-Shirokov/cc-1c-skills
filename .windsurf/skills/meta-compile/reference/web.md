# HTTPService, WebService (Веб-сервисы)

Модуль обоих — `Ext/Module.bsl`, в нём реализуются обработчики.

## HTTPService (HTTP-сервис)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `rootURL` | `= name` (в нижнем регистре) | корневой URL |
| `reuseSessions` | `DontUse` | `DontUse` / `Use` / `AutoUse` |
| `sessionMaxAge` | `20` | время жизни сессии, сек |
| `urlTemplates` | `{}` | шаблоны URL (см. ниже) |

`urlTemplates` — объект `{ "ИмяШаблона": def }`, где `def`:
- строка — URL-путь без методов: `"/health"`;
- объект: `template` (путь с параметрами `{id}`, по умолчанию `/имяшаблона`), `synonym`, `comment`,
  `methods` — `{ "ИмяМетода": def }`.

`methods` — значение либо строка (только HTTP-метод), либо объект: `httpMethod`, `handler`,
`synonym`, `comment`.

HTTP-методы: `GET`, `POST`, `PUT`, `DELETE`, `PATCH`, `HEAD`, `OPTIONS`, `CONNECT`, `TRACE`, `MERGE`.
Обработчик по умолчанию именуется `{ИмяШаблона}{ИмяМетода}`; в типовых конфигурациях он часто
произвольный — тогда задавайте `handler` явно.

```json
{ "type": "HTTPService", "name": "API", "rootURL": "api",
  "urlTemplates": {
    "Users": { "template": "/v1/users/{id}", "methods": { "Get": "GET", "Create": "POST", "Delete": "DELETE" } },
    "Health": "/health"
  } }
```

## WebService (Веб-сервис, SOAP)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `namespace` | пусто | URI пространства имён WSDL |
| `xdtoPackages` | пусто | список пакетов (см. ниже) |
| `descriptorFileName` | `= name` + `.1cws` | имя файла дескриптора |
| `reuseSessions` | `DontUse` | `DontUse` / `Use` / `AutoUse` |
| `sessionMaxAge` | `20` | время жизни сессии, сек |
| `operations` | `{}` | операции (см. ниже) |

`xdtoPackages` — **массив** значений: `"XDTOPackage.Имя"` — пакет конфигурации, любое другое
значение — URI внешнего пространства имён (например `"http://v8.1c.ru/8.3/data/ext"`).

`operations` — объект `{ "ИмяОперации": def }`, где `def`:
- строка — XDTO-тип возврата без параметров: `"xs:string"`;
- объект: `returnType` (по умолчанию `xs:string`), `nillable` (bool), `transactioned` (bool),
  `procedureName` (имя процедуры, по умолчанию = имя операции; синоним ключа — `handler`),
  `dataLockControlMode` (по умолчанию `Managed`), `synonym`, `comment`, `parameters`.

`parameters` — объект `{ "ИмяПараметра": def }`, где `def`:
- строка — XDTO-тип (`direction` = `In`);
- объект: `type` (по умолчанию `xs:string`), `nillable` (bool, по умолчанию `true`),
  `direction` (`In` / `Out` / `InOut`), `synonym`, `comment`.

XDTO-типы: `xs:string`, `xs:boolean`, `xs:int`, `xs:long`, `xs:decimal`, `xs:dateTime`, `xs:base64Binary`.
Тип из собственного пространства имён задаётся в нотации Кларка — `"{http://ваш.uri}ИмяТипа"`;
компилятор сам объявит локальный `xmlns` в теге, как это делает платформа.

```json
{ "type": "WebService", "name": "DataExchange", "namespace": "http://www.1c.ru/DataExchange",
  "operations": {
    "TestConnection": { "returnType": "xs:boolean", "handler": "ПроверкаПодключения",
                        "parameters": { "ErrorMessage": { "type": "xs:string", "direction": "Out" } } },
    "GetVersion": "xs:string"
  } }
```
