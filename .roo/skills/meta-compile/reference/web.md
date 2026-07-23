# HTTPService, WebService (Веб-сервисы)

Модуль обоих — `Ext/Module.bsl`, в нём реализуются обработчики.

## HTTPService (HTTP-сервис)

| Ключ | Умолчание | Значения |
|------|-----------|----------|
| `rootURL` | `= name` (в нижнем регистре) | корневой URL |
| `reuseSessions` | `DontUse` | `DontUse` / `AutoUse` |
| `sessionMaxAge` | `20` | время жизни сессии, сек |
| `urlTemplates` | `{}` | шаблоны URL (см. ниже) |

`urlTemplates` — объект `{ "ИмяШаблона": def }`, где `def`:
- строка — URL-путь без методов: `"/health"`;
- объект: `template` (путь с параметрами `{id}`, по умолчанию `/имяшаблона`), `methods` — `{ "ИмяМетода": "HTTPMethod" }`.

HTTP-методы: `GET`, `POST`, `PUT`, `DELETE`, `PATCH`, `HEAD`, `OPTIONS`, `CONNECT`, `TRACE`, `MERGE`.
Обработчик метода в модуле именуется `{ИмяШаблона}{ИмяМетода}`.

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
| `xdtoPackages` | пусто | XDTO-пакеты |
| `reuseSessions` | `DontUse` | `DontUse` / `AutoUse` |
| `sessionMaxAge` | `20` | время жизни сессии, сек |
| `operations` | `{}` | операции (см. ниже) |

`operations` — объект `{ "ИмяОперации": def }`, где `def`:
- строка — XDTO-тип возврата без параметров: `"xs:string"`;
- объект: `returnType` (по умолчанию `xs:string`), `nillable` (bool), `transactioned` (bool),
  `handler` (имя процедуры, по умолчанию = имя операции), `parameters`.

`parameters` — объект `{ "ИмяПараметра": def }`, где `def`:
- строка — XDTO-тип (`direction` = `In`);
- объект: `type` (по умолчанию `xs:string`), `nillable` (bool, по умолчанию `true`), `direction` (`In` / `Out` / `InOut`).

XDTO-типы: `xs:string`, `xs:boolean`, `xs:int`, `xs:long`, `xs:decimal`, `xs:dateTime`, `xs:base64Binary`.

```json
{ "type": "WebService", "name": "DataExchange", "namespace": "http://www.1c.ru/DataExchange",
  "operations": {
    "TestConnection": { "returnType": "xs:boolean", "handler": "ПроверкаПодключения",
                        "parameters": { "ErrorMessage": { "type": "xs:string", "direction": "Out" } } },
    "GetVersion": "xs:string"
  } }
```
