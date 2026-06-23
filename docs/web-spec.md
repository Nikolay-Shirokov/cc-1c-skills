# Веб-публикация 1С — техническая спецификация

Описание артефактов, необходимых для публикации информационной базы 1С через Apache HTTP Server.

## default.vrd

Дескриптор виртуального ресурса. XML-файл, описывающий подключение к информационной базе.

### Формат

```xml
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system"
       xmlns:xs="http://www.w3.org/2001/XMLSchema"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       base="/appname"
       ib="connection-string">
    <standardOdata enable="true"/>
    <ws pointEnableCommon="true"/>
    <httpServices publishByDefault="true"/>
</point>
```

### Атрибут `base`

URL-путь публикации. Должен начинаться с `/`, совпадает с `Alias` в httpd.conf.

### Атрибут `ib`

Строка подключения к информационной базе.

**Файловая база:**
```
File=&quot;C:\Bases\MyDB&quot;;
```

**Серверная база:**
```
Srvr=&quot;server01&quot;;Ref=&quot;MyDB&quot;;
```

**С авторизацией:**
```
File=&quot;C:\Bases\MyDB&quot;;Usr=&quot;Admin&quot;;Pwd=&quot;123&quot;;
```

> Кавычки внутри значения `ib` экранируются как `&quot;` (XML-сущность).

### Дочерние элементы

#### `<standardOdata>`
Стандартный OData-интерфейс платформы. `<standardOdata enable="true"/>` открывает REST-доступ к опубликованным объектам (состав настраивается в «Настройка автоматического REST-сервиса» → вкладка «Состав»; при пустом составе сервис-документ отдаёт HTTP 404).
URL: `/{AppName}/odata/standard.odata`

> **Регистр важен.** Рабочая форма — строчная `<standardOdata enable="true"/>` (проверено E2E на 8.3.24 и 8.3.27: отдаёт HTTP 200). Заглавная `<standardOData>` из «Руководства администратора» парсером vrd **не распознаётся** → OData 404. Старый атрибут `enableStandardOdata="true"` на `<point>` (до 8.3.9) также не работает.

#### `<ws>`
Публикация SOAP web-сервисов. `pointEnableCommon="true"` публикует все сервисы из конфигурации.
URL: `/{AppName}/ws/{WebServiceName}?wsdl`

#### `<httpServices>`
Публикация HTTP-сервисов. `publishByDefault="true"` публикует все сервисы из конфигурации.
URL: `/{AppName}/hs/{RootUrl}/...`

### Расположение

`{ApachePath}/publish/{AppName}/default.vrd`

## httpd.conf для 1С

### LoadModule

Apache загружает модуль расширения 1С:

```apache
LoadModule _1cws_module "C:/Program Files/1cv8/8.3.24.1691/bin/wsap24.dll"
```

- Модуль `wsap24.dll` — 64-разрядный, требует x64-версию Apache
- Путь использует forward slashes

### Listen

```apache
Listen 8081
```

Порт для веб-клиента. По умолчанию `8081` (стандартный `80` может быть занят).

### Alias + Directory

Для каждой публикации добавляется блок:

```apache
Alias "/appname" "C:/path/to/apache/publish/appname"
<Directory "C:/path/to/apache/publish/appname">
    AllowOverride All
    Require all granted
    SetHandler 1c-application
    ManagedApplicationDescriptor "C:/path/to/apache/publish/appname/default.vrd"
</Directory>
```

- `Alias` — URL-путь → физический каталог
- `SetHandler 1c-application` — делегирование обработки запросов модулю wsap24
- `ManagedApplicationDescriptor` — путь к default.vrd

### Маркерный подход

Скрипты используют маркерные комментарии для идемпотентного управления блоками:

```apache
# --- 1C: global ---
Listen 8081
LoadModule _1cws_module "C:/Program Files/1cv8/8.3.24.1691/bin/wsap24.dll"
# --- End: global ---

# --- 1C Publication: mydb ---
Alias "/mydb" "C:/tools/apache24/publish/mydb"
<Directory "C:/tools/apache24/publish/mydb">
    AllowOverride All
    Require all granted
    SetHandler 1c-application
    ManagedApplicationDescriptor "C:/tools/apache24/publish/mydb/default.vrd"
</Directory>
# --- End: mydb ---
```

При повторном запуске блок между маркерами заменяется целиком.

## wsap24.dll

Модуль расширения Apache для 1С:Предприятие 8.3.

- Расположение: `{V8Path}/wsap24.dll` (в каталоге `bin` платформы)
- Архитектура: x64 (Apache тоже должен быть x64)
- Имя модуля: `_1cws_module`

## Portable Apache

### Дистрибутив

Apache Lounge — Windows-сборка Apache HTTP Server (x64):
- Сайт: `https://www.apachelounge.com/download/`
- Прямая ссылка (2.4.62, VS17): `https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-240904-win64-VS17.zip`
- Внутри ZIP: каталог `Apache24/` с полной структурой

### Структура после установки

```
tools/apache24/
├── bin/
│   ├── httpd.exe
│   └── ...
├── conf/
│   ├── httpd.conf
│   └── ...
├── logs/
│   ├── error.log
│   └── access.log
├── modules/
│   └── ...
└── publish/
    └── {appname}/
        └── default.vrd
```

### Пост-распаковка

1. `Expand-Archive` распаковывает ZIP во временный каталог
2. Содержимое `Apache24/` перемещается в `{ApachePath}`
3. В `httpd.conf` патчится `ServerRoot`:

```apache
Define SRVROOT "C:/path/to/apache24"
ServerRoot "${SRVROOT}"
```

Путь `SRVROOT` — абсолютный, с forward slashes.

### Запуск

```
httpd.exe                  # foreground (для отладки)
httpd.exe -k start         # фоновый запуск (не работает без установки сервиса)
```

> Portable Apache запускается напрямую через `Start-Process httpd.exe` без установки Windows-сервиса.

### Остановка

```
httpd.exe -k stop           # graceful shutdown (требует сервис)
Stop-Process -Name httpd    # принудительная остановка (portable)
```

### Перезагрузка

```
httpd.exe -k restart        # graceful restart (требует сервис)
```

Для portable варианта: остановка + запуск.
