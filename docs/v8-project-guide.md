# Конфигурация проекта (.v8-project.json)

Файл `.v8-project.json` — единый конфиг проекта для всех навыков Claude Code. Хранит пути к платформе 1С, список баз данных и настройки инструментов (Apache, ffmpeg, TTS).

Размещается в корне проекта (рядом с `.git/`). Создаётся навыком `/db-list add` или вручную.

> **Безопасность**: файл содержит секреты (пароли баз данных, API-ключи TTS) и добавлен в `.gitignore` — он не попадает в репозиторий. Каждый разработчик заводит свой `.v8-project.json` локально.

## Полная схема

```jsonc
{
  // === Платформа ===
  "v8path": "C:\\Program Files\\1cv8\\8.3.25.1257\\bin",

  // === Базы данных ===
  "databases": [
    {
      "id": "dev",                          // уникальный идентификатор
      "name": "Разработка",                 // отображаемое имя
      "type": "file",                       // "file" или "server"
      "path": "C:\\Bases\\MyApp_Dev",       // каталог (для file)
      "user": "Admin",                      // пользователь 1С
      "password": "",                       // пароль
      "aliases": ["dev", "разработка"],     // альтернативные имена
      "branches": ["dev", "feature/*"],     // привязка к Git-веткам
      "configSrc": "C:\\WS\\myapp\\cfsrc",  // каталог XML-выгрузки конфигурации
      "webUrl": "http://localhost:8081/dev"  // URL веб-клиента (для /web-test)
    },
    {
      "id": "test",
      "name": "Тестовая",
      "type": "server",                     // серверная база
      "server": "srv01",                    // адрес сервера 1С
      "ref": "MyApp_Test",                  // имя базы на сервере
      "user": "Admin",
      "password": "123",
      "aliases": ["test", "тест"]
    }
  ],
  "default": "dev",

  // === Инструменты ===
  "webPath": "C:\\tools\\apache24",                  // каталог Apache
  "ffmpegPath": "C:\\tools\\ffmpeg\\bin\\ffmpeg.exe", // путь к ffmpeg
  "tts": {                                            // настройки озвучки
    "provider": "edge",
    "voice": "ru-RU-DmitryNeural"
  }
}
```

## Корневые поля

| Поле | Тип | Обяз. | По умолчанию | Описание | Кто заполняет |
|------|-----|:-----:|-------------|----------|---------------|
| `v8path` | string | да | — | Путь к каталогу `bin` платформы 1С | `/db-list add` или руками |
| `databases` | array | да | — | Список баз данных | `/db-list add` |
| `default` | string | нет | — | `id` базы по умолчанию | `/db-list` |
| `editingAllowedCheck` | `"deny"`/`"warn"`/`"off"` | нет | `deny` | Глобальная реакция support-guard на правку объектов на замке (см. ниже) | Руками |
| `webPath` | string | нет | `tools/apache24` | Каталог Apache HTTP Server | Руками |
| `ffmpegPath` | string | нет | `tools/ffmpeg/bin/ffmpeg.exe` | Путь к ffmpeg | Руками |
| `tts` | object | нет | Edge TTS, DmitryNeural | Настройки озвучки видео | Руками |

## Базы данных (`databases[]`)

| Поле | Тип | Обяз. | Описание | Кто заполняет |
|------|-----|:-----:|----------|---------------|
| `id` | string | да | Уникальный идентификатор | `/db-list add` |
| `name` | string | да | Отображаемое имя | `/db-list add` |
| `type` | `"file"` / `"server"` | да | Тип подключения | `/db-list add` |
| `path` | string | для file | Каталог файловой базы | `/db-list add` |
| `server` | string | для server | Адрес сервера 1С | `/db-list add` |
| `ref` | string | для server | Имя базы на сервере | `/db-list add` |
| `user` | string | нет | Пользователь 1С | `/db-list add` или руками |
| `password` | string | нет | Пароль | `/db-list add` или руками |
| `aliases` | string[] | нет | Альтернативные имена для обращения к базе | `/db-list add` или руками |
| `branches` | string[] | нет | Git-ветки или glob-паттерны (`release/*`, `feature/*`) | Руками |
| `configSrc` | string | нет | Каталог XML-выгрузки конфигурации | Руками |
| `editingAllowedCheck` | `"deny"`/`"warn"`/`"off"` | нет | Override реакции support-guard для этой базы (см. ниже) | Руками |
| `webUrl` | string | нет | URL веб-клиента для `/web-test` | Руками |

### Support-guard и `editingAllowedCheck`

Навыки-мутаторы (`meta-edit`, `meta-compile`, `meta-remove` и др.) перед изменением исходников проверяют состояние поддержки конфигурации (`Ext/ParentConfigurations.bin`, см. [1c-support-state-spec.md](1c-support-state-spec.md)). Если объект «на замке» поставщика (или вся конфигурация read-only, или удаляется не снятый с поддержки объект), правка по умолчанию **блокируется** — прямое изменение сломало бы обновления.

Реакцию задаёт `editingAllowedCheck`:
- `deny` (по умолчанию, в т.ч. когда поле не задано) — блокировать с диагностикой;
- `warn` — пропускать, но писать предупреждение;
- `off` — проверку не выполнять.

Триггер проверки — наличие `ParentConfigurations.bin` (конфигурация на поддержке), а не регистрация в `.v8-project.json`. Поле лишь меняет реакцию. Берётся `databases[].editingAllowedCheck` базы, чей `configSrc` охватывает редактируемый путь; иначе — корневое `editingAllowedCheck`; иначе `deny`.

### Разрешение базы

Все навыки `/db-*`, `/epf-build`, `/epf-dump`, `/erf-build`, `/erf-dump`, `/web-publish` используют единый алгоритм:

1. Если пользователь указал **параметры подключения** (путь, сервер) — используются напрямую
2. Если указал **базу по имени** — поиск: `id` → `aliases` (с учётом морфологии) → `name` (нечёткое)
3. Если **не указал** — сопоставление текущей ветки Git с `branches` (точно или по glob-паттерну)
4. Fallback на `default`
5. Если не найдено — Claude спросит пользователя
6. Если база не зарегистрирована — Claude предложит `/db-list add`

## Настройки инструментов

### `webPath` — Apache HTTP Server

Путь к каталогу Apache. Используется навыками `/web-publish`, `/web-info`, `/web-stop`, `/web-unpublish`.

Если не задан — ищется в `tools/apache24` от корня проекта. При первом вызове `/web-publish` Apache скачивается автоматически.

Подробнее — в [гайде по веб-публикации](web-guide.md).

### `ffmpegPath` — ffmpeg

Путь к исполняемому файлу ffmpeg. Используется навыком `/web-test` для записи видео.

Если не задан — ищется по порядку:
1. `tools/ffmpeg/bin/ffmpeg.exe` (от корня проекта)
2. `ffmpeg` в системном PATH

Подробнее — в [гайде по записи видео](web-test-recording-guide.md).

### `tts` — озвучка видеоинструкций

| Поле | Тип | По умолчанию | Описание |
|------|-----|-------------|----------|
| `provider` | string | `"edge"` | Провайдер: `"edge"`, `"elevenlabs"`, `"openai"` |
| `voice` | string | `"ru-RU-DmitryNeural"` | Голос (имя или ID в зависимости от провайдера) |
| `apiKey` | string | — | API-ключ (для elevenlabs, openai) |
| `apiUrl` | string | — | URL сервиса (для openai-совместимых) |
| `model` | string | — | Модель (для openai) |

Подробнее о выборе провайдера и голосов — в [гайде по записи видео](web-test-recording-guide.md#доступные-голоса-и-провайдеры).

### `webUrl` — URL веб-клиента (per-database)

URL для открытия базы в браузере через `/web-test`. Задаётся в записи конкретной базы.

Если не задан — `/web-test` берёт URL из активной веб-публикации (`/web-publish`).

Полезно, если веб-клиент доступен по нестандартному адресу (другой порт, внешний сервер, reverse proxy).

## Минимальный пример

```json
{
  "v8path": "C:\\Program Files\\1cv8\\8.3.25.1257\\bin",
  "databases": [
    {
      "id": "dev",
      "name": "Разработка",
      "type": "file",
      "path": "C:\\Bases\\MyApp"
    }
  ]
}
```

## Полный пример

```json
{
  "v8path": "C:\\Program Files\\1cv8\\8.3.25.1257\\bin",
  "databases": [
    {
      "id": "dev",
      "name": "Разработка",
      "type": "file",
      "path": "C:\\Bases\\MyApp_Dev",
      "user": "Admin",
      "password": "",
      "aliases": ["dev", "разработка"],
      "branches": ["dev", "develop", "feature/*"],
      "configSrc": "C:\\WS\\myapp\\cfsrc",
      "webUrl": "http://localhost:8081/dev"
    },
    {
      "id": "prod",
      "name": "Рабочая",
      "type": "server",
      "server": "srv01",
      "ref": "MyApp_Prod",
      "user": "Admin",
      "password": "secret",
      "aliases": ["prod", "рабочая", "боевая"],
      "branches": ["main", "release/*"]
    }
  ],
  "default": "dev",
  "webPath": "C:\\tools\\apache24",
  "ffmpegPath": "C:\\tools\\ffmpeg\\bin\\ffmpeg.exe",
  "tts": {
    "provider": "edge",
    "voice": "ru-RU-DmitryNeural"
  }
}
```

## Связанные навыки

- [Базы данных](db-guide.md) — `/db-list`, `/db-create`, `/db-load-xml`, `/db-dump-xml` и другие
- [Веб-публикация](web-guide.md) — `/web-publish`, `/web-info`, `/web-stop`
- [Тестирование в браузере](web-test-guide.md) — `/web-test`
- [Запись видеоинструкций](web-test-recording-guide.md) — запись видео, субтитры, озвучка
