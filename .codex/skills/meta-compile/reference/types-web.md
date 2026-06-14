# Веб-сервисы: HTTPService, WebService

## HTTPService

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `rootURL` | `= name.toLower()` | RootURL |
| `reuseSessions` | `DontUse` | ReuseSessions |
| `sessionMaxAge` | `20` | SessionMaxAge |
| `urlTemplates` | `{}` | → URLTemplate |

Модули: `Ext/Module.bsl`.

### urlTemplates — вложенная структура

`urlTemplates` — объект `{ "TemplateName": templateDef, ... }`.

Каждый `templateDef`:
- Строка — URL-шаблон: `"/v1/users"` (без методов)
- Объект:

| Поле | Умолчание | Описание |
|------|----------|----------|
| `template` | `"/templatename"` | URL-путь (с параметрами `{id}`) |
| `methods` | `{}` | Методы: `{ "MethodName": "HTTPMethod" }` |

Допустимые HTTPMethod: `GET`, `POST`, `PUT`, `DELETE`, `PATCH`, `HEAD`, `OPTIONS`, `CONNECT`, `TRACE`, `MERGE`.

Обработчик метода генерируется автоматически: `{TemplateName}{MethodName}` — должен быть реализован в `Ext/Module.bsl`.

```json
{
  "type": "HTTPService", "name": "API", "rootURL": "api",
  "urlTemplates": {
    "Users": {
      "template": "/v1/users/{id}",
      "methods": { "Get": "GET", "Create": "POST", "Update": "PUT", "Delete": "DELETE" }
    },
    "Health": "/health"
  }
}
```

## WebService

| Поле JSON | Умолчание | XML элемент |
|-----------|----------|-------------|
| `namespace` | `""` | Namespace (URI пространства имён WSDL) |
| `xdtoPackages` | `""` | XDTOPackages |
| `reuseSessions` | `DontUse` | ReuseSessions |
| `sessionMaxAge` | `20` | SessionMaxAge |
| `operations` | `{}` | → Operation |

Модули: `Ext/Module.bsl`.

### operations — вложенная структура

`operations` — объект `{ "OperationName": operationDef, ... }`.

Каждый `operationDef`:
- Строка — тип возврата: `"xs:boolean"` (параметров нет, обработчик = имя операции)
- Объект:

| Поле | Умолчание | Описание |
|------|----------|----------|
| `returnType` | `xs:string` | XDTO-тип возврата |
| `nillable` | `false` | Может ли вернуть null |
| `transactioned` | `false` | Выполнять в транзакции |
| `handler` | `= operationName` | Имя процедуры в модуле |
| `parameters` | `{}` | Параметры операции |

### parameters — параметры операции

`parameters` — объект `{ "ParamName": paramDef, ... }`.

Каждый `paramDef`:
- Строка — XDTO-тип: `"xs:string"` (direction = In, nillable = true)
- Объект:

| Поле | Умолчание | Описание |
|------|----------|----------|
| `type` | `xs:string` | XDTO-тип параметра |
| `nillable` | `true` | Может ли быть null |
| `direction` | `In` | Направление: `In`, `Out`, `InOut` |

Стандартные XDTO-типы: `xs:string`, `xs:boolean`, `xs:int`, `xs:long`, `xs:decimal`, `xs:dateTime`, `xs:base64Binary`.

```json
{
  "type": "WebService", "name": "DataExchange",
  "namespace": "http://www.1c.ru/DataExchange",
  "operations": {
    "TestConnection": {
      "returnType": "xs:boolean",
      "handler": "ПроверкаПодключения",
      "parameters": {
        "ErrorMessage": { "type": "xs:string", "direction": "Out" }
      }
    },
    "GetVersion": "xs:string"
  }
}
```
