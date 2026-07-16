# Регресс-тесты web-test

E2E-тесты движка `web-test` (Playwright + изолированная синтетическая БД 1С), запускаются через `node .claude/skills/web-test/scripts/run.mjs test`.

## Запуск

```bash
# Полный регресс (фикстура _hang/ в него не входит — см. ниже)
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/

# Один файл
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/02-crud.test.mjs

# Несколько файлов (позиционные = пути к тестам, можно сколько угодно)
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/04-selectvalue.test.mjs tests/web-test/11-report.test.mjs

# Несколько по фильтру тегов
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/ --tags=table,smoke

# По regex имени теста
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/ --grep=multi
```

URL не передаём позиционно — берётся из `webtest.config.mjs` (`contexts.a.url` = `http://localhost:9191/webtest-runner/ru_RU`). Переопределить можно флагом `--url=<url>`.

Exit code: 0 = все прошли, 1 = есть падения, 2 = сработал `--global-timeout` (отчёт записан, сеансы освобождены), 3 = зависло само сворачивание.

## CLI флаги runner'а

| Флаг | Описание |
|---|---|
| `--url=URL` | Переопределить базовый URL (по умолчанию — из `webtest.config.mjs`) |
| `--tags=A,B` | Запустить только тесты с одним из тегов |
| `--grep=regex` | Фильтр по имени теста |
| `--bail` | Остановиться на первой ошибке |
| `--retry=N` | Перепрогон упавших тестов N раз |
| `--timeout=ms` | Таймаут одного теста (default 30000) |
| `--global-timeout=ms` | Потолок на весь прогон; по истечении — отчёт, освобождение сеансов, выход с кодом 2 |
| `--report=path` | Сохранить машинный отчёт в файл |
| `--report=-` | Машинный отчёт в stdout (прогресс → stderr) |
| `--format=json\|allure\|junit` | Формат отчёта |
| `--report-dir=path` | Корень для Allure/JUnit артефактов |
| `--screenshot=on-failure\|every-step\|off` | Когда снимать скриншоты |
| `--record` | Включить запись MP4 (CDP screencast → ffmpeg) |

## Опции стенда (после `--`)

`_hooks.mjs` поднимает изолированный стенд (Apache на `:9191`, своя БД, отдельный набор EPF). По умолчанию работает в smart-режиме: пересборка только когда поменялся `config-hash` / `epf-hash`. Принудительно — через флаги после `--`:

```bash
# Принудительно пересобрать XML + БД + EPF
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/ -- --rebuild-stand

# Точечно — только пересобрать БД из существующего XML (свежая синтетика)
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/ -- --reload-data

# Только пересобрать XML (когда хочется новой конфигурации)
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/ -- --rebuild-config

# Только EPF (внешние обработки для openFile)
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/ -- --rebuild-epf
```

| Флаг | Что делает |
|---|---|
| `--rebuild-stand` | Эквивалент всех трёх ниже |
| `--rebuild-config` | XML-исходники + БД |
| `--reload-data` | Только БД (drop+create+load+update) |
| `--rebuild-epf` | Только EPF-обработки |

## Когда пересобирать стенд

**Warm-старт (~200 ms):** lockfile + probe Apache, БД жива, EPF на диске — ничего не делаем.

**Триггеры авто-пересборки** (без флагов):
- Изменился `config-hash` синтетической XML — пересобирается конфигурация + БД.
- Изменился `epf-hash` исходников EPF — пересобираются EPF.

**Когда нужен `--rebuild-stand` вручную:**
- БД накопила «мусорных» данных от write-сценариев. `15-multi-context-handover` создаёт нового Контрагента каждый прогон с unique-именем — со временем `02-crud` начнёт падать (Контрагент `ООО Север` уезжает за `maxRows=20`).
- Подозрение что Apache держит зависший процесс — `--rebuild-stand` делает `web-stop` + `web-publish`.

## Конфигурация

`tests/web-test/webtest.config.mjs` задаёт:
- **`contexts.a` / `contexts.b` / `contexts.c`** — независимые 1C-сеансы (разные cookies) на той же URL. `a`,`b` — два «пользователя» мультиконтекст-тестов; `c` задействован только `14-multi-context-routing` и служит топливом для проверки вытеснения пула.
- **`defaultContext: 'a'`** — большинство тестов работают в одном контексте.
- **`isolation: 'tab'`** — вкладки в одном окне (default). Альтернатива `'window'` — отдельный BrowserContext (полная изоляция cookies).
- **`deadlines: {...}`** — бюджеты служебных операций (сброс состояния, закрытие контекста, скриншот…).
  Дефолты рассчитаны на лёгкий стенд; здесь не переопределяются. Если в выводе появились строки
  `! resetState(a): timed out after Nms` — стенд стал тяжелее бюджета, поднимай ключ, а не терпи:
  пробой сброса прерывает контекст (следующий тест получит чистый ценой перезапуска).
- **`maxContexts: 2` / `contextPolicy: 'reuse'` / `pinnedContexts: []`** — дай-фуд управления пулом лицензий. Лимит 2 одновременных сеанса: на границе `14 (c) → 15 (a,b)` раннер автоматически вытесняет LRU-контекст `c` (проверяется первым шагом `15-multi-context-handover`). Благодаря лимиту 3 контекста никогда не живут одновременно.

## Env переменные

| Переменная | Значение |
|---|---|
| `WEB_TEST_PRESERVE_CLIPBOARD=0` | Отключить save/restore буфера обмена вокруг `pasteText` |
| `WEBTEST_HOOKS_RUNTIME=python` | Использовать py-версии скиллов вместо ps1 (для не-Windows) |

## Фикстура зависания — `_hang/`

Не часть регресса, а **ручная проверка прерывания зависшего теста**. `_`-префикс держит её вне обычного
прогона: `walk()` в `discover.mjs` пропускает `_`-записи внутри каталога, но явно переданный корневой путь
не фильтрует — поэтому `test tests/web-test/` её не видит, а `test tests/web-test/_hang` находит.

```bash
# стенд должен быть уже опубликован — своих _hooks.mjs у фикстуры нет
node .claude/skills/web-test/scripts/run.mjs test tests/web-test/_hang
```

Состав: `01-renderer-block` вешает JS-поток рендерера (`page.evaluate(() => { while(true) {} })`) —
до появления abort-механики такой тест вешал прогон навсегда; `02-survivor` идёт следом и доказывает,
что прогон поехал дальше, а контекст пересоздан со свежим сеансом (то есть лицензия вернулась).

**Ожидаемый результат — `1 passed, 1 failed` и exit code 1. Красный `01` здесь означает успех.**
Читать глазами два условия:

1. `01` упал со строкой `verdict: hang (renderer unresponsive, browser alive)` и
   `recovery: context aborted (logout: node, closed: page)` — а не завис;
2. `02` зелёный — прогон продолжился и лицензия освободилась.

Автоматической обвязки (spawn раннера + проверка этих условий → 0/1) пока нет, поэтому в CI фикстуру
как обычный набор класть нельзя — код выхода 1 тут штатный.

**Когда гонять:**
- правки пути очистки в `cli/commands/test.mjs` (дедлайны, ветка таймаута) и жизненного цикла в
  `engine/core/session.mjs` (`abortContext`, `probeContext`, `disconnect`, `createContext`);
- **обновление Playwright** — механика стоит на замеренном поведении библиотеки: `page.close({runBeforeUnload:false})`
  возвращается поверх зависшего `evaluate`, тот отваливается «Target closed», а `cookies()` отвечает при
  мёртвом рендерере (пробник). Новая версия может это поменять;
- перед вливанием движковых правок web-test в `dev`.

**Цена:** ~18 с чистого таймаута, намеренное уничтожение контекста, а в `tab`-режиме — ещё и перезапуск
браузера (закрывается последняя вкладка persistent-контекста).

**Слепая зона:** каскад logout считает успехом ответ 2xx. Если 1С однажды начнёт держать сеанс на куке,
а не на `seanceId` в URL, Node-logout продолжит получать 200, фикстура покажет `logout: node` — и поломка
всплывёт только когда утёкшие сеансы упрутся в лимит лицензий. Фикстура этого не ловит.

**Воспроизводит один режим** — заблокированный рендерер. Полумёртвый CDP (сокет жив, браузер не отвечает)
ловится дедлайнами, а не `abortContext`, и здесь не покрыт.

## Артефакты

- `tests/web-test/error-*.png` — скриншоты упавших шагов (auto на `--screenshot=on-failure`)
- `tests/web-test/_allure/` — Allure-результаты (на `--format=allure`)
- `tests/skills/.cache/webtest-stand/` — lockfiles стенда (config-hash, epf-hash, data-hash)

## Известные нюансы

- **`15-multi-context-handover`** создаёт `unique`-Контрагента и **сохраняет** — за серию прогонов накапливаются «лишние» записи. Если `02-crud` начал падать на «`ООО Север` должен быть в списке» — это симптом, лечится `-- --rebuild-stand`.
- **`04-selectvalue` auto-history шаг** — в изоляции делает warm-up через двойной `selectValue('Менеджер', 'ООО Юг')` чтобы наполнить history, иначе первый вызов идёт через `method:form`, а тест ожидает `method:dropdown`. Не зависит от других файлов.
- **Скриншот ошибки только на последнем падении** — `--screenshot=on-failure` (default) делает один кадр в момент исключения. Для full-trace используй `--screenshot=every-step`.
