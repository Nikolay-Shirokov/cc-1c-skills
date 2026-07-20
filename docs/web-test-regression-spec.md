# Регрессионное тестирование — спецификация

Техническое описание движка регрессионных тестов: инструмент исполняет описанные кодом пользовательские сценарии в веб-клиенте прикладного решения на платформе 1С и сверяет результат с ожиданиями.

Смежные документы:
- [web-test-regression-guide.md](web-test-regression-guide.md) — пользовательский гайд с быстрым стартом.
- [web-test-guide.md](web-test-guide.md) — справочник по browser-API (`clickElement`, `getFormState`, `readTable`, …), который используется внутри тестов.
- [web-test-recording-guide.md](web-test-recording-guide.md) — видеозапись, озвучка, overlays.

---

## 1. Командная строка

```
node run.mjs test <dir|file>... [флаги]
```

Позиционные аргументы — это пути к тестам (файлы `*.test.mjs` и/или каталоги), можно указать несколько: `node run.mjs test a.test.mjs b.test.mjs dir/`. Файлы из каталогов обходятся рекурсивно; итоговый набор дедуплицируется и сортируется (порядок по числовым префиксам `00-`, `01-`, … сохраняется независимо от порядка аргументов). Путь, которого нет на диске, → ранняя понятная ошибка (аргумент, похожий на URL, подскажет про `--url=`).

| Флаг | По умолчанию | Описание |
|------|-------------|----------|
| `--url=URL` | (из конфига) | Переопределить базовый URL дефолтного контекста |
| `--tags=smoke,crud` | (все) | Фильтр тестов по тегам (пересечение) |
| `--grep=pattern` | (все) | Фильтр тестов по имени (регулярное выражение) |
| `--bail` | false | Остановиться при первом падении |
| `--retry=N` | 0 | Повторить упавшие тесты N раз |
| `--timeout=ms` | 30000 | Таймаут на тест (мс) |
| `--global-timeout=ms` | 0 (выкл) | Потолок на весь прогон (мс). По истечении — отчёт, освобождение сеансов, выход с кодом 2 |
| `--report=path` | (нет) | Записать машинный отчёт в файл (JSON или XML для `--format=junit`) |
| `--report=-` | (нет) | Машинный отчёт в stdout (`-` = stdout); человеческий прогресс уходит в stderr |
| `--format=fmt` | json | Формат отчёта: `json` / `allure` / `junit` |
| `--report-dir=path` | dirname(report) / корень сьюта | Каталог для скриншотов, видео, Allure-результатов |
| `--screenshot=strategy` | on-failure | `on-failure` / `every-step` / `off` |
| `--record` | false | Записывать видео для каждого теста (mp4 в `--report-dir`) |
| `-- <hookArgs…>` | — | Всё после `--` пробрасывается в `_hooks.mjs` как `hookArgs` (см. §6.1) |

URL не передаётся позиционно — он берётся из `webtest.config.mjs`, а флаг `--url=` переопределяет URL дефолтного контекста.

### Резолв корня сьюта

`webtest.config.mjs` и `_hooks.mjs` резолвятся не от переданного пути, а от **корня сьюта**: от каталога пути движок поднимается вверх до первого каталога, где лежит `webtest.config.mjs` или `_hooks.mjs`. Именно поэтому запуск подкаталога (`test tests/myapp/sales/`) и отдельного файла работает без `--url=`. Подъём ограничен каталогом с `.git` или `.v8-project.json` (сам каталог проверяется), а если их нет — текущим рабочим каталогом; выше поиск не идёт. Не нашли маркер — корнем считается переданный каталог (тогда хуков нет, и движок пишет об этом предупреждение в stderr).

Маркером служат **оба** файла, а не только конфиг: конфиг необязателен (§7), и сьют, у которого есть только `_hooks.mjs`, иначе молча остался бы без подготовки стенда.

Если переданные пути принадлежат разным сьютам (корни не совпали) — прогон не стартует: конфиг и хуки были бы взяты от первого пути, то есть чужие. Запускайте сьюты отдельно.

Найденный корень печатается в шапке прогона, рядом — переданные пути, если они от него отличаются.

### Валидация CLI

- `--screenshot=<v>` принимается только `on-failure | every-step | off`; при невалидном значении движок выводит ошибку и завершается с ненулевым кодом до старта прогона.
- `--format=<v>` принимается только `json | allure | junit`; иначе — завершение с ошибкой.
- `--format=junit` требует `--report=<path>` (иначе некуда писать XML); иначе — завершение с ошибкой. Значение `-` (stdout) для junit допустимо.
- `--report=-` (stdout) несовместимо с `--format=allure`: allure пишет каталог, а не поток; иначе — завершение с ошибкой.

### Коды выхода

| Код | Значение |
|-----|----------|
| `0` | Все тесты прошли |
| `1` | Есть упавшие тесты |
| `2` | Сработал `--global-timeout`: отчёт записан, сеансы освобождены, прогон свёрнут |
| `3` | Сработал `--global-timeout`, но зависло само сворачивание — процесс убит принудительно |

Коды `2`/`3` отличают «тесты красные» от «стенд не отвечает» — по ним CI может принимать разные решения.

### Потоки вывода (stdout / stderr)

`test` ведёт себя как тест-раннер (jest/pytest/playwright): человеческий отчёт со сводкой в конце идёт в **stdout**. Машинный отчёт (JSON/JUnit) включается отдельно флагом `--report`.

| Запуск | stdout | stderr | Файл |
|--------|--------|--------|------|
| `test …` (дефолт) | человеческий отчёт, **сводка последней строкой** | — | — |
| `test … --report=file` | человеческий отчёт (виден прогресс + сводка) | — | JSON/JUnit в файл |
| `test … --report=-` | **чистый машинный отчёт** (JSON или JUnit-XML) | человеческий прогресс | — |
| `--format=allure …` | человеческий отчёт | — | артефакты allure в каталоге |
| любой | — | — | exit code **0/1** всегда |

### Режим выполнения

1. Загружается `webtest.config.mjs` (если есть).
2. Обнаруживаются файлы `*.test.mjs`, читается каждый, извлекаются метаданные.
3. Применяются фильтры `--tags` / `--grep` / `only`. Параметризованные тесты разворачиваются.
4. Запускается браузер и default-контекст (`chromium.launch()` либо `launchPersistentContext` в зависимости от `isolation`).
5. Тесты выполняются последовательно **в алфавитном порядке относительного пути файла** (внутри файла — в порядке экспорта).
6. Для каждого теста: лениво создаются нужные `BrowserContext`-ы (`ensureContext`), переключается активный, прогоняются хуки и тело, выполняется встроенный сброс состояния.
7. По завершении: финальная очистка контекстов с `beforeCloseContext`-хуками, закрытие браузера, `cleanup()`.

---

## 2. Формат тест-модуля

Каждый файл `*.test.mjs` — ES-модуль.

### Экспорты

| Экспорт | Тип | Обязателен | По умолчанию | Описание |
|---------|-----|-----------|-------------|----------|
| `name` | `string` | да | — | Читаемое имя теста |
| `default` | `async function(ctx, param?)` | да | — | Тело теста |
| `tags` | `string[]` | нет | `[]` | Теги для фильтрации |
| `timeout` | `number` | нет | 30000 | Таймаут теста (мс) |
| `skip` | `boolean \| string` | нет | false | Пропустить тест (строка = причина) |
| `only` | `boolean` | нет | false | Запустить только этот тест (отладка) |
| `context` | `string` | нет | defaultContext | Имя контекста из файла конфигурации |
| `contexts` | `string[]` | нет | — | Мульти-пользовательский процессный тест |
| `severity` | `string` | нет | — | `blocker` / `critical` / `normal` / `minor` / `trivial` |
| `params` | `object[]` | нет | — | Параметризация (см. §13) |
| `setup` | `async function(ctx)` | нет | — | Подготовка перед тестом |
| `teardown` | `async function(ctx)` | нет | — | Очистка после теста (выполняется всегда) |

### Пример: тест с одним контекстом

```js
export const name = 'CRUD справочника Контрагенты';
export const tags = ['smoke', 'crud', 'catalog'];
export const timeout = 45000;

export default async function({ navigateSection, openCommand, clickElement,
  fillFields, readTable, closeForm, getFormState, assert, step, log }) {

  await step('Открыть список', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
  });

  await step('Создать элемент', async () => {
    await clickElement('Создать');
    await fillFields({ 'Наименование': 'Тест-' + Date.now() });
    await clickElement('Записать и закрыть');
  });

  await step('Проверить в списке', async () => {
    const table = await readTable();
    assert.tableHasRow(table, r => r['Наименование']?.startsWith('Тест-'));
    log('Элемент найден в списке');
  });
}
```

### Пример: мульти-контекстный процессный тест

Рекомендация: латинский ID контекста + кириллический `displayName` в `webtest.config.mjs.contexts.<id>.displayName` (см. §7).

```js
export const name = 'Согласование приходной накладной';
export const contexts = ['clerk', 'manager'];
export const tags = ['process'];

export default async function({ clerk, manager, step }) {
  await step('Кладовщик создаёт накладную', async () => {
    await clerk.navigateSection('Склад');
    await clerk.openCommand('Приходные накладные');
    await clerk.clickElement('Создать');
    await clerk.fillFields({ 'Контрагент': 'ООО Поставщик' });
    await clerk.clickElement('Записать');
  });

  await step('Менеджер утверждает', async () => {
    await manager.navigateSection('Согласование');
    await manager.openCommand('На утверждении');
    await manager.clickElement('ООО Поставщик', { dblclick: true });
    await manager.clickElement('Утвердить');
  });

  await step('Освобождаем контекст clerk', async () => {
    await manager.closeContext('clerk');  // освободить лицензию 1С
  });
}
```

---

## 3. Объект контекста

Каждая тестовая функция получает объект контекста `ctx`.

### API браузера (все экспорты browser.mjs)

Все функции обёрнуты авто-обнаружением 1С-ошибок (как в `executeScript`):
- При модальной/всплывающей ошибке 1С: скриншот → `fetchErrorStack` → исключение с заполненным `err.onecError`.
- Обёрнутые ACTION_FNS: `clickElement`, `fillFields`, `fillField`, `selectValue`, `fillTableRow`, `deleteTableRow`, `openCommand`, `navigateSection`, `navigateLink`, `openFile`, `closeForm`, `filterList`, `unfilterList`.

Полный список доступных функций (по группам, детальное описание — в [web-test-guide.md](web-test-guide.md)):

**Навигация:** `navigateSection`, `openCommand`, `switchTab`, `navigateLink`, `openFile`
**Состояние:** `getFormState`, `getPageState`, `getSections`, `getCommands`
**Таблицы:** `readTable`, `readSpreadsheet`, `fillTableRow`, `deleteTableRow`
**Поля:** `fillFields`, `fillField`, `selectValue`
**Действия:** `clickElement`, `closeForm`, `filterList`, `unfilterList`
**Ошибки:** `fetchErrorStack`
**Контексты:** `createContext`, `setActiveContext`, `closeContext`, `listContexts`, `hasContext`, `getActiveContext`
**Запись:** `startRecording`, `stopRecording`, `isRecording`, `addNarration`, `getCaptions`
**Презентация:** `showCaption`, `hideCaption`, `showTitleSlide`, `hideTitleSlide`, `showImage`, `hideImage`, `highlight`, `unhighlight`, `setHighlight`, `isHighlightMode`
**Утилиты:** `screenshot`, `wait`, `getPage`, `getSession`, `readFileSync`, `writeFileSync`

> `dismissPendingErrors` — внутренняя функция (browser.mjs), на `ctx` не публикуется. Тест её не вызывает напрямую: она срабатывает автоматически перед каждым ACTION_FN и внутри встроенного сброса.

### Тестовые утилиты

- `step(name, fn)` — обёртка шага (см. §4)
- `assert.*` — хелперы утверждений (см. §5)
- `log(...args)` — добавить строку в вывод теста. Строки накапливаются в массив, склеиваются и попадают в JSON `tests[].output`. В Allure-отчёте `output` пишется в `statusDetails.trace` **только для упавших тестов**; для успешных теряется (отдельного вложения не создаётся).

### Метаданные теста (`ctx.testInfo`)

Декларативная информация о текущем тесте. Движок выставляет `ctx.testInfo` перед каждой попыткой (до `beforeEach`); хук и тело теста могут читать. Изменять не следует — объект используется самим движком при сборке отчёта.

```js
ctx.testInfo = {
  name,             // 'Навигация по разделам' (с подставленными params)
  file,             // '01-navigation.test.mjs' (basename)
  filePath,         // '01-navigation.test.mjs' (relative к корню сьюта, разделитель '/')
  tags,             // ['nav', 'smoke']
  timeout,          // 60000 (ms)
  attempt,          // 1..maxAttempts (1-based)
  maxAttempts,      // 1 + retry
  param,            // { ... } | undefined (для export const params)
  contexts: {       // объект, всегда 1+ ключей; зеркалит config.contexts
    a: { url, isolation, ...customFields },
    b: { ... },
  },
  primaryContext,   // 'a' — имя контекста, активного на входе в тест
                    //       (= t.context для single, t.contexts[0] для multi)
}
```

Доступ к специфике контекста: `testInfo.contexts[testInfo.primaryContext].displayName`. `primaryContext` — декларация теста; не зависит от текущего значения `getActiveContext()` (которое может меняться внутри теста).

### Результат теста в afterEach (`ctx.testResult`)

Только в `afterEach`. До запуска теста — `null`. После — заполняется движком перед вызовом хука:

```js
ctx.testResult = {
  status,      // 'passed' | 'failed'
  duration,    // ms
  attempts,    // фактически выполнено попыток (1..maxAttempts)
  error,       // { message, step?, screenshot?, onecError? } | null
  steps,       // массив step-результатов (структура — см. §4)
}
```

В итоговый JSON-отчёт (`tests[]`) добавляются ещё `name`, `file`, `tags`, `contexts`, `severity`, `start`, `stop`, `output`, `screenshot`, `video` (см. §9). В `afterEach` они недоступны — движок собирает финальную запись после хука.

### Мульти-контекст

При `export const contexts = ['a', 'b']`:
- `ctx.a` и `ctx.b` — отдельные scoped-объекты, каждый с полным API браузера. Перед каждым вызовом scoped-обёртка переключает активный контекст через `setActiveContext`.
- `ctx.step`, `ctx.assert`, `ctx.log`, `ctx.testInfo`, `ctx.testResult` остаются на верхнем уровне.

При single-context (`export const context = 'X'` или дефолт) API публикуется плоско на `ctx`.

---

## 4. step(name, fn) — обёртка шага

```js
await step('Имя шага', async () => {
  // тело шага
});
```

Поведение:
- Записывает метку `start` перед `fn()`.
- Записывает метку `stop` после `fn()` (успех или ошибка).
- При ошибке: устанавливает `status: 'failed'`, прикрепляет сообщение, пробрасывает исключение.
- При успехе: устанавливает `status: 'passed'`.
- Если стратегия скриншотов `every-step` — делает скриншот после `fn()`.
- Вложенные шаги поддерживаются (шаг внутри шага).
- Напрямую маппится на шаги Allure.

Структура данных шага (для отчётов):

```js
{
  name: 'Имя шага',
  start: 1712345678000,   // мс от эпохи
  stop:  1712345679200,
  status: 'passed' | 'failed',
  error: 'сообщение' | undefined,
  screenshot: 'путь' | undefined,
  steps: []               // вложенные шаги
}
```

---

## 5. Утверждения (assertions)

Простые хелперы без зависимостей. Бросают `AssertionError` со свойствами `.message`, `.actual`, `.expected`.

### Общие

```js
assert.ok(value, msg?)                    // истинность
assert.equal(actual, expected, msg?)      // ===
assert.notEqual(actual, expected, msg?)   // !==
assert.deepEqual(actual, expected, msg?)  // сравнение через JSON
assert.includes(haystack, needle, msg?)   // string/array .includes()
assert.match(string, regex, msg?)         // regex.test(string)
await assert.throws(asyncFn, msg?)        // ожидает исключение из async fn
```

### Специфичные для 1С

```js
assert.formHasField(state, fieldName, msg?)
// проверяет, что в массиве state.fields есть поле с таким name;
// в сообщении об ошибке перечисляются доступные поля для быстрой диагностики

assert.formTitle(state, expected, msg?)
// проверяет, что state.title СОДЕРЖИТ expected (подстрока, не строгое равенство).
// state.title — заголовок активной формы: сначала из шапки формы, при её отсутствии —
// из панели открытых окон; null, если недоступны оба (тогда ассерт падает с этим фактом)

assert.tableHasRow(table, predicate, msg?)
// predicate: объект (частичное совпадение по ===) или функция row => bool
//   объект:  assert.tableHasRow(table, { 'Наименование': 'Тест' })
//   функция: assert.tableHasRow(table, r => r['Сумма'] > 100)

assert.tableRowCount(table, expected, msg?)
// проверяет table.rows.length === expected

assert.noErrors(state, msg?)
// проверяет !state.errors
```

Расширения assert API нет. Для нестандартных проверок — `throw new Error(...)` или комбинация существующих хелперов.

---

## 6. Хуки

Все хуки определяются в `_hooks.mjs` в корне сьюта (§1 «Резолв корня сьюта»).

### Три уровня

**Инфраструктурный уровень** (без браузера):
- `prepare({ hookArgs, log, config })` — до подключения (восстановление БД, публикация, загрузка данных).
- `cleanup({ hookArgs, log, config })` — после отключения (удаление публикации, очистка).

Поля параметра:
- `hookArgs: string[]` — всё, что в командной строке передано после разделителя `--`, без интерпретации со стороны движка. Хук парсит сам (см. §6.1).
- `log: (...args) => void` — функция логирования движка (структурированный вывод с префиксом `[hooks]`). Использовать вместо `console.log`, чтобы не ломать формат отчёта.
- `config: object` — разобранный `webtest.config.mjs` (URL контекстов, режим изоляции, правила severity и т.д.).

**Тестовый уровень** (с контекстом браузера):
- `beforeAll(ctx)` — после подключения, перед первым тестом.
- `afterAll(ctx)` — после последнего теста, до отключения.
- `beforeEach(ctx)` — перед каждым тестом. На входе уже доступен `ctx.testInfo` (см. §3).
- `afterEach(ctx)` — после каждого теста. Дополнительно доступен `ctx.testResult` с результатом завершившегося теста.

**Контекстный уровень** (на каждый browser-контекст, жизненный цикл = создан → удалён):
- `afterOpenContext(ctx, name, spec)` — сразу после успешного `createContext`. `spec` — запись из `config.contexts[name]` со всеми пользовательскими полями (`displayName`, `url`, `isolation`, …). Полезно: вставка постоянного DOM-оверлея/бейджа, предварительная навигация в контексте, регистрация телеметрии.
- `beforeCloseContext(ctx, name, spec)` — перед `closeContext` (контекст ещё активен и работает). Полезно: сохранение остатков буферов, сбор метрик, последний скриншот. Срабатывает и при явном `ctx.closeContext(name)` из теста, и в финальной очистке движка перед `disconnect`.

`closeContext(name)` валиден только когда `name !== getActiveContext()` — иначе бросается исключение. В scoped API (`ctx.a.closeContext('b')`) это естественно: scoped-обёртка сначала вызывает `setActiveContext('a')`, потом закрывает `'b'` — целевой контекст всегда неактивен.

### Подавление ошибок в хуках

Ошибки в `afterEach`, `teardown`, `afterAll` и `cleanup` ловятся и логируются движком, но не прерывают прогон и не помечают тест/прогон как failed. Логика: пост-хуки очистки должны быть устойчивы к собственным сбоям, чтобы один сломанный `teardown` не приводил к падению остальных тестов по цепочке. Если в этих хуках произошла фатальная для регресса проблема — бросайте отдельный `Error` в `beforeAll`/`beforeEach`, чтобы он прервал прогон, либо проверяйте состояние в самом тесте.

### Порядок выполнения

```
prepare()                          // без браузера (восстановление БД, публикация)
  browser.launch()                 // запуск процесса браузера
  createContext(default)           // первый контекст создан
    afterOpenContext(ctx, default) // hook: контекст готов
    beforeAll(ctx)                 // браузер готов, default-контекст создан
      [lazy ensureContext(name)]   // для multi-context тестов
        afterOpenContext(ctx, name)
      beforeEach(ctx)
        test.setup(ctx)            // подготовка теста
          test.default(ctx)        // тело теста (может вызвать ctx.closeContext)
            [при ctx.closeContext(x)]: beforeCloseContext(ctx, x) → close(x)
        test.teardown(ctx)         // очистка теста (всегда)
      afterEach(ctx)               // всегда
      [встроенный сброс]           // всегда (для каждого живого контекста теста)
      …следующий тест…
    afterAll(ctx)
  [для каждого оставшегося контекста]: beforeCloseContext(ctx, name, spec)
  browser.close()                  // финальный disconnect (без явных closeContext —
                                   // контексты умирают вместе с браузером)
cleanup()                          // без браузера (удаление публикации)
```

### Встроенный сброс состояния

После каждого теста (после `afterEach`) движок гарантирует чистое состояние:

```js
async function resetState(ctx) {
  try { await ctx.dismissPendingErrors(); } catch {}   // no-op на ctx (не экспортируется);
                                                       // внутренний dismiss всё равно отработает
                                                       // через ACTION_FN-обёртки ниже

  for (let i = 0; i < 10; i++) {
    const state = await ctx.getFormState();
    if (state.form == null) break;     // важно: == null, не !state.form —
                                        // form может быть 0 (валидный idx фоновой формы)
    try { await ctx.closeForm({ save: false }); } catch { break; }
  }
}
```

Гарантирует, что каждый тест стартует с чистого рабочего стола, независимо от того, как завершился предыдущий (падение, таймаут, ошибка утверждения). Реимплементировать это в пользовательском `afterEach` не нужно.

### Пример _hooks.mjs

```js
import { execSync } from 'child_process';

export async function prepare({ hookArgs, log, config }) {
  const force = hookArgs.includes('--rebuild-stand');
  const dataArg = hookArgs.find(a => a.startsWith('--data='))?.slice('--data='.length);
  log('preparing stand, force=', force, 'data=', dataArg);
  execSync('powershell.exe -File scripts/restore-db.ps1');
  execSync('powershell.exe -File scripts/publish.ps1');
}

export async function cleanup({ log }) {
  log('cleaning up stand');
  execSync('powershell.exe -File scripts/unpublish.ps1');
}

export async function beforeAll(ctx) {
  // По умолчанию 1С после входа уже показывает дефолтную секцию — навигация
  // в beforeAll обычно не нужна. Хук удобен для общего setup'а который
  // должен случиться один раз для всего прогона.
}

export async function afterEach(ctx) {
  // Доступен ctx.testResult — { status, duration, attempts, error, steps }.
  // Встроенный сброс состояния выполняется ПОСЛЕ afterEach автоматически.
}

export async function afterOpenContext(ctx, name, spec) {
  // Удобно для persistent DOM-overlay'я с displayName (видно в видео,
  // какая вкладка к какому пользователю относится).
}

export async function beforeCloseContext(ctx, name, spec) {
  // Срабатывает и при ctx.closeContext из теста, и в финальной очистке.
}
```

### 6.1. Проброс пользовательских флагов через `--`

Движок не знает о пользовательских флагах хуков. Чтобы хуки получили разовые параметры без правки `webtest.config.mjs` или окружения, используется стандартная shell-конвенция `--` (как у `npm`, `cargo`, `pytest`): всё, что идёт после `--` в CLI движка, передаётся в `prepare` / `cleanup` через поле `hookArgs: string[]` без интерпретации.

```
node run.mjs test tests/myapp/ --bail -- --rebuild-stand --reload-data
                               └─ runner ─┘ └────── hookArgs ────────┘
```

В этом примере движок получает `--bail`, а `hookArgs` хуков становится `['--rebuild-stand', '--reload-data']`. Парсинг этого массива — ответственность хуков.

Если разделитель `--` не указан, `hookArgs` — пустой массив. Это позволяет движку и хукам развиваться независимо: новый встроенный флаг движка никогда не пересечётся с пользовательским.

---

## 7. Файл конфигурации

`webtest.config.mjs` в корне сьюта (§1 «Резолв корня сьюта»). Необязателен — если отсутствует, URL должен быть передан через CLI.

```js
export default {
  // Контексты: именованные URL для разных пользователей/ролей.
  // Рекомендация: латинский ID контекста (`clerk`, `manager`) + кириллический
  // `displayName` для UI/слайдов. Любые пользовательские поля пробрасываются как есть
  // и доступны хукам через `ctx.testInfo.contexts[name]` (см. §3).
  contexts: {
    clerk:   { url: 'http://localhost/app-clerk/ru_RU',   displayName: 'Кладовщик' },
    manager: { url: 'http://localhost/app-manager/ru_RU', displayName: 'Менеджер' },
    admin:   { url: 'http://localhost/app-admin/ru_RU',   displayName: 'Админ' },
  },
  defaultContext: 'clerk',

  // Значения по умолчанию (переопределяются флагами CLI)
  timeout: 30000,
  globalTimeout: 0,          // потолок на весь прогон (мс); 0 = выключен
  retries: 0,
  screenshot: 'on-failure',  // 'every-step' | 'off'
  record: false,

  // Бюджеты служебных операций (мс). Дефолты рассчитаны на лёгкий стенд; тяжёлому
  // прикладному решению честно нужно больше — переопределяются поштучно.
  deadlines: {
    resetState: 60000,       // встроенный сброс на тяжёлых формах
    closeContext: 30000,
  },

  // Дефолтный тег-фильтр. Применяется только если CLI не передал --tags.
  // Удобно для сценариев «прогон по умолчанию = smoke», при этом --tags=full
  // (или --tags=) с CLI прозрачно перекрывает.
  tags: ['smoke'],

  // Дефолтный режим изоляции для контекстов, которые сами его не указали
  // (config.contexts.<name>.isolation). См. §8.
  isolation: 'tab',          // 'tab' | 'window'

  // Управление пулом 1С-лицензий (см. §8 «Пул контекстов и лицензии»). Все три поля
  // необязательны; без них поведение прежнее (лимита нет, контексты копятся, default живёт весь прогон).
  maxContexts: 2,            // потолок одновременно живых 1С-сеансов; опустить = без лимита
  contextPolicy: 'reuse',    // 'reuse' (держать открытыми в пределах лимита) | 'strict' (закрывать сразу после теста)
  pinnedContexts: ['admin'], // никогда не вытесняются LRU; по умолчанию = [defaultContext], [] делает default вытесняемым

  // Allure severity policy (опционально). Маппинг наоборот: уровень → [теги].
  // Резолв см. §9 «Авто-эмиссия label-ов».
  severity: {
    critical: ['smoke', 'multi-context'],
    minor:    ['recording'],
    // blocker / trivial — необязательны, можно опустить
  },
  defaultSeverity: 'normal',
};
```

**Упрощённая форма** (один контекст, без именованных):

```js
export default {
  url: 'http://localhost/app/ru_RU',
  timeout: 30000,
};
```

### Валидация файла конфигурации

`severity` валидируется при загрузке:
- ключи — только из `blocker | critical | normal | minor | trivial`;
- значение каждого ключа — массив тегов;
- тег не может одновременно состоять в двух уровнях severity (явная ошибка с указанием конфликта);
- `defaultSeverity` — из стандартного набора.

При нарушении любого правила движок выводит сообщение с указанием конфликта и завершается с ненулевым кодом до запуска тестов.

Пул контекстов валидируется при загрузке: `maxContexts` — положительное целое или опущено; `contextPolicy` — `'reuse'` либо `'strict'`; каждый элемент `pinnedContexts` должен присутствовать в `contexts`. Нарушение — явная ошибка до запуска.

Кириллица в ID контекстов работает, но смешанный регистр снижает читаемость кода (`testInfo.contexts.кладовщик.displayName` рядом с `testInfo.contexts.clerk.displayName`). Рекомендуем разделять технический ID и человекочитаемое имя.

Флаги CLI всегда переопределяют значения из файла конфигурации.

---

## 8. Контексты

### Механизм: Playwright BrowserContext

Один процесс браузера (`chromium.launch()`), несколько изолированных контекстов. Каждый контекст — отдельная сессия (куки, авторизация, состояние страницы).

```
browser (один процесс chromium)
  ├─ BrowserContext "кладовщик" → page → http://localhost/app-clerk/ru_RU
  ├─ BrowserContext "менеджер"  → page → http://localhost/app-mgr/ru_RU
  └─ BrowserContext "админ"     → page → http://localhost/app-admin/ru_RU
```

Преимущества:
- **Мгновенное переключение** между пользователями (смена активного `page`).
- **Состояние сохраняется** — переключились на менеджера и обратно, у кладовщика все формы остались открытыми.
- **Нет переподключений** — каждая сессия живёт независимо.
- **Один процесс** — экономия ресурсов по сравнению с несколькими браузерами.

### Одиночный контекст (по умолчанию)

Большинство тестов. Один BrowserContext, один пользователь. Тест получает плоский `ctx` со всем API.

```js
export const context = 'manager';   // необязательно, иначе defaultContext
export default async function({ clickElement, fillFields, … }) { }
```

### Порядок выполнения и переключение контекста

Движок НЕ группирует тесты по контексту. Порядок выполнения — алфавитный по полному относительному пути файла (плюс порядок экспорта внутри файла). Для каждого теста:

1. **(при заданном `maxContexts`)** Освобождение пула: если `union(открытые, нужные)` превышает лимит, движок вытесняет LRU-старейшие контексты, не входящие в `pinned` и не нужные этому тесту (см. §8 «Пул контекстов и лицензии»).
2. Через `ensureContext(name)` создаются BrowserContext-ы, упомянутые в `t.context` / `t.contexts` (уже открытые переиспользуются — повторного входа в 1С нет).
3. `setActiveContext(primaryContext)` — активный контекст = первый объявленный (для single — `t.context || defaultContext`, для multi — `t.contexts[0]`).
4. После теста встроенный сброс пробегает по всем использованным контекстам.
5. **(при `contextPolicy: 'strict'`)** Non-pinned контексты теста закрываются сразу после него.

Контексты живут между тестами (при `contextPolicy: 'reuse'` — по умолчанию): переключение через `setActiveContext` — дешёвое, повторный вход в 1С не требуется. Закрываются явно (`closeContext`), LRU-вытеснением под лимит, `strict`-политикой либо финальной очисткой движка перед закрытием браузера.

### Мульти-контекст (процессные тесты)

```js
export const contexts = ['clerk', 'manager'];
export default async function({ clerk, manager, step, assert }) { … }
```

Каждый именованный контекст — полноценный scoped-объект API со своим `page`. Тест оркестрирует переключение между пользователями. Состояние каждого пользователя сохраняется между переключениями:

```js
await step('Кладовщик создаёт документ', async () => {
  await clerk.openCommand('Приходные накладные');
  await clerk.clickElement('Создать');
  await clerk.fillFields({ 'Контрагент': 'ООО Поставщик' });
  await clerk.clickElement('Записать');
  // кладовщик стоит на форме документа
});

await step('Менеджер утверждает', async () => {
  await manager.navigateSection('Согласование');
  await manager.clickElement('Утвердить');
});

await step('Кладовщик проверяет статус', async () => {
  // страница кладовщика ТА ЖЕ — форма открыта, навигация не нужна
  const state = await clerk.getFormState();
  assert.equal(state.fields.find(f => f.name === 'Статус')?.value, 'Утверждён');
});
```

### Публичный контекстный API

| Метод | Назначение |
|-------|-----------|
| `createContext(name, url, { isolation, extensionPath })` | Создаёт BrowserContext и переходит по URL. |
| `setActiveContext(name)` | Переключает активный слот; при активной записи дописывает последние кадры старой страницы и переподключает screencast. |
| `closeContext(name)` | Выход из 1С + закрытие (`page` для `tab`, `BrowserContext` для `window`), удаляет из реестра. Бросает исключение, если `name === active`. |
| `listContexts()` / `hasContext(name)` / `getActiveContext()` | Только для чтения. |

### Режимы изоляции

Поле `isolation` задаётся в двух местах:

- **На уровне контекста:** `config.contexts.<name>.isolation` — приоритет 1.
- **На уровне файла конфигурации:** `config.isolation` — применяется к контекстам, у которых своего значения нет. По умолчанию `'tab'`.

| Режим | Реализация | Окна | Cookies | 1С-расширение |
|-------|-----------|------|---------|---------------|
| `'tab'` (default) | `launchPersistentContext` + `newPage()` per context | 1 окно, N вкладок | общие по path | загружается надёжно |
| `'window'` | `chromium.launch()` + `newContext()` per context | N окон | полная изоляция | может не загружаться |

Смешивать режимы в одном прогоне нельзя — `createContext` бросает явную ошибку. То есть `config.isolation` фактически становится режимом всего прогона, если хотя бы один контекст явно не переопределил его на тот же режим.

### Закрытие неактивных контекстов

`closeContext(name)` нельзя вызвать на активном контексте — будет исключение. В scoped API это естественно: вызывать `manager.closeContext('clerk')` (scoped-обёртка сначала переключает активный на `manager`, потом закрывает `clerk`). Если контекст лишний (роль больше не нужна в рамках теста / прогона) — закрывайте его сразу: освобождает лицензию платформы и снимает нагрузку со следующих тестов.

### Пул контекстов и лицензии

Каждый живой контекст — отдельный 1С-сеанс, то есть отдельная лицензия (в режиме `'tab'` каждая вкладка = свой `seanceId`). На стендах с малым пулом лицензий бесконтрольное накопление контекстов между тестами рано или поздно пробивает лимит, и тест падает в setup. Три поля конфигурации переносят управление пулом в движок:

| Поле | Значение | По умолчанию |
|------|----------|--------------|
| `maxContexts` | Потолок одновременно живых 1С-сеансов. `null`/опущено — без лимита, вытеснения нет (прежнее поведение). | `null` |
| `contextPolicy` | `'reuse'` — держать контексты открытыми в пределах лимита ради скорости (соседние тесты под тем же контекстом не переоткрывают сеанс). `'strict'` — закрывать non-pinned контексты теста сразу после него ради экономии лицензий. | `'reuse'` |
| `pinnedContexts` | Контексты, которые НЕ вытесняются LRU. По умолчанию `[defaultContext]` — сохраняет прежнее «default живёт весь прогон». `[]` делает default обычным вытесняемым контекстом. | `[defaultContext]` |

**Вытеснение (LRU).** При заданном `maxContexts` перед setup каждого теста движок проверяет `union(открытые, нужные_тесту)`. Если он превышает лимит — закрывает контексты в порядке давности использования (старейшие первыми), пропуская `pinned` и нужные текущему тесту, пока не влезет в лимит. Уже открытый нужный контекст переиспользуется. Вытесненный при следующей надобности переоткрывается штатным `ensureContext`.

**default вытесняем.** `defaultContext` (на нём исполняется `beforeAll` и хуки) больше не «вечный» — под лимитом он такой же кандидат на вытеснение, если не входит в `pinnedContexts`. Это осознанно: обычно default не держит состояния, нужного между тестами. Если ваши хуки требуют постоянного admin-сеанса — оставьте его в `pinnedContexts`.

**Исчерпание пула.** Если даже после вытеснения всего допустимого `pinned ∪ нужные` не влезает в `maxContexts`, движок валит тест с внятной ошибкой `context pool exhausted: …` (а не маскирующим «Browser not connected») и подсказкой — поднять `maxContexts`, сократить объявленные контексты или уменьшить `pinnedContexts`.

**Рецепт тесного пула.** Стенд на 2 лицензии, процессные тесты на 2 контекста: `maxContexts: 2`, `pinnedContexts: []` (чтобы default вытеснялся и освобождал слот). `contextPolicy: 'reuse'` даёт переиспользование соседних тестов; `'strict'` — максимально быстрое освобождение лицензий на шаренном стенде.

---

## 9. Отчёты

### Момент записи (инкрементальность)

Отчёт пишется **по мере прохождения**, а не только в конце: зависание или аварийное сворачивание не должны
уничтожать уже собранные результаты.

| Формат | Когда пишется |
|--------|---------------|
| `allure` | Файл `<uuid>-result.json` на каждый тест — сразу по его завершении |
| `json` с `--report=<path>` | Файл перезаписывается целиком после каждого теста (поле `state: 'partial'`) |
| `json` с `--report=-`, `junit` | **Не инкрементальны** — поток/файл пишется один раз в конце; при срабатывании `--global-timeout` пишутся из аварийного обработчика с тем, что успело завершиться |

Поле `state` в JSON-отчёте: `complete` — прогон дошёл до конца, `partial` — промежуточная запись,
`aborted` — прогон свёрнут по `--global-timeout`. Зависший тест попадает в отчёт как обычное падение
с вердиктом (см. §«Таймауты»).

### JSON (нативный, по умолчанию)

```json
{
  "runner": "web-test",
  "url": "http://localhost/app/ru_RU",
  "startedAt": "2026-04-05T10:00:00.000Z",
  "finishedAt": "2026-04-05T10:05:30.000Z",
  "duration": 330.0,
  "summary": {
    "total": 25,
    "passed": 23,
    "failed": 1,
    "skipped": 1
  },
  "tests": [
    {
      "name": "CRUD справочника Контрагенты",
      "file": "02-catalog-crud.test.mjs",
      "tags": ["smoke", "crud"],
      "contexts": ["clerk"],
      "severity": "critical",
      "status": "passed",
      "start": 1712345678000,
      "stop":  1712345690300,
      "duration": 12.3,
      "attempts": 1,
      "steps": [
        {
          "name": "Открыть список",
          "start": 1712345678000,
          "stop": 1712345679200,
          "status": "passed",
          "steps": []
        }
      ],
      "output": "Элемент найден в списке",
      "error": null,
      "screenshot": null,
      "video": null
    },
    {
      "name": "Обязательное поле",
      "file": "10-validation.test.mjs",
      "tags": ["validation"],
      "contexts": ["clerk"],
      "status": "failed",
      "duration": 8.1,
      "attempts": 2,
      "steps": [
        {
          "name": "Сохранить пустую форму",
          "start": 1712345700000,
          "stop": 1712345708100,
          "status": "failed",
          "error": "Ожидалось модальное окно ошибки, но форма сохранилась"
        }
      ],
      "output": "",
      "error": {
        "message": "Ожидалось модальное окно ошибки, но форма сохранилась",
        "step": "Сохранить пустую форму",
        "screenshot": "error-shot-10.png"
      },
      "screenshot": "error-shot-10.png"
    }
  ]
}
```

### Allure (`--format=allure --report-dir=allure-results/`)

Отдельные JSON-файлы для каждого теста в каталоге `allure-results/`:

```json
{
  "uuid": "сгенерированный-uuid",
  "name": "CRUD справочника",
  "fullName": "02-catalog-crud.test.mjs",
  "status": "passed",
  "stage": "finished",
  "start": 1712345678000,
  "stop": 1712345690300,
  "labels": [
    { "name": "tag", "value": "smoke" },
    { "name": "tag", "value": "crud" },
    { "name": "suite", "value": "root" },
    { "name": "severity", "value": "critical" }
  ],
  "steps": [
    {
      "name": "Открыть список",
      "status": "passed",
      "start": 1712345678000,
      "stop": 1712345679200,
      "steps": []
    }
  ],
  "attachments": [
    {
      "name": "Скриншот при падении",
      "source": "uuid-attachment.png",
      "type": "image/png"
    }
  ]
}
```

Скриншоты/видео копируются в `allure-results/` с уникальными именами.

#### Авто-эмиссия меток

Движок всегда заполняет следующие метки (`labels`):

- **`tag`** — по одному на каждый элемент `mod.tags[]`. Готовая фильтрация в Allure-отчёте без дополнительной разметки.
- **`suite`** — `dirname(t.filePath)`. Тесты в корне сьюта идут под `'root'`, тесты в подкаталоге `sales/` — под `'sales'`. Это даёт левую группировку отчёта без ручной разметки.
- **`severity`** — резолв в порядке приоритета:
  1. `export const severity = 'critical'` в самом тесте, **если значение валидное** (одно из `blocker | critical | normal | minor | trivial`). Если экспорт задан, но значение невалидное — пункт пропускается и идём в (3); резолв через теги (пункт 2) при этом **не выполняется** (хотел бы автор иначе — он бы не объявлял `severity`).
  2. Иначе **максимальный ранг** среди тегов теста (стандартные имена `blocker | critical | normal | minor | trivial` напрямую, либо через `config.severity`-маппинг).
  3. Иначе `config.defaultSeverity` или `'normal'`.

  Ранги: `blocker(5) > critical(4) > normal(3) > minor(2) > trivial(1)`. Выбор по максимуму не зависит от порядка тегов в `mod.tags`.

Пример: `tags: ['smoke', 'recording']` + `severity: { critical: ['smoke'], minor: ['recording'] }` → severity = `critical` (5 > 2).

#### Доп. файлы Allure через `<корень сьюта>/_allure/`

Движок ищет каталог `_allure/` в корне сьюта и копирует все его файлы в `reportDir` перед генерацией отчёта. Конвенция для статичной настройки Allure, для которой нет места внутри JSON-файла теста:

| Файл | Назначение |
|------|-----------|
| `categories.json` | Классификация падений по regex (группировка failed-тестов в виджете Categories — «timeout», «license-flake», «1C modal» и т.п.). |
| `environment.properties` | `key=value` строки в виджет Environment (URL, версия 1С, ветка git, номер сборки). Часто формируется динамически из `prepare()`. |
| `executor.json` | CI/CD-метаданные (Jenkins URL, GitHub run-id и т.п.). |

Подчёркивание в имени — параллель `_hooks.mjs` (инфраструктура, не тест). Сборщик тестов пропускает каталог `_allure/` по общему правилу (`startsWith('_')`). Если каталога нет — ничего не происходит, отчёт собирается обычным образом.

Пример `categories.json` (минимальный):
```json
[
  { "name": "Timeout", "messageRegex": "Timeout \\(\\d+ms\\)" },
  { "name": "Assertion", "messageRegex": "(Expected|AssertionError).*" }
]
```

### JUnit XML (`--format=junit`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="web-test" tests="25" failures="1" skipped="1" time="330.0">
  <testsuite name="tests/myapp" tests="25" failures="1" skipped="1">
    <testcase name="CRUD справочника" classname="02-catalog-crud.test.mjs" time="12.3"/>
    <testcase name="Обязательное поле" classname="10-validation.test.mjs" time="8.1">
      <failure message="Ожидалось модальное окно ошибки, но форма сохранилась">
        Стек вызовов…
      </failure>
      <system-out>Скриншот: error-shot-10.png</system-out>
    </testcase>
  </testsuite>
</testsuites>
```

---

## 10. Консольный вывод

Вывод — на английском (статусы `passed/failed/skipped` зеркалят ключи JSON-отчёта и Allure/JUnit):

```
web-test -- http://localhost/app/ru_RU
Running 25 tests from tests/myapp/

  ✓ Навигация по разделам (2.1s)
  ✓ CRUD справочника Контрагенты (12.3s)
    ├ Открыть список (1.2s)
    ├ Создать элемент (8.0s)
    └ Проверить в списке (3.1s)
  ✗ Обязательное поле (8.1s)
    ├ Открыть форму (2.0s)
    └ ✗ Сохранить пустую форму (6.1s)
      Ожидалось модальное окно ошибки, но форма сохранилась
      screenshot: error-shot-10.png
  ○ Составной тип (skip: не реализовано)

23 passed, 1 failed, 1 skipped (2m 0.5s)
```

Для passed-тестов выводится одна строка `✓ name (duration)`. Шаги печатаются только для упавших — после строки `✗`, с отступом, плюс сообщение ошибки и путь к скриншоту (`screenshot:`). Полная картина по шагам — в машинном отчёте (`--report=…` или `--report=-`).

По умолчанию этот отчёт идёт в **stdout** и заканчивается строкой сводки (`N passed, M failed, K skipped (Xs)`) — модель читает хвост stdout + exit code. В режиме `--report=-` (Unix-конвенция `-` = stdout) stdout занимает чистый машинный отчёт (JSON/JUnit), а человеческий прогресс уходит в stderr.

---

## 11. Скриншоты и видео

### Стратегия скриншотов

| Стратегия | Поведение |
|-----------|----------|
| `on-failure` (по умолчанию) | Скриншот при падении теста, прикрепляется к ошибке. |
| `every-step` | Скриншот в конце каждого `step()`, плюс при падении. |
| `off` | Без автоматических скриншотов. |

Скриншоты сохраняются в каталог отчёта по шаблону `{индекс-теста}-{имя-шага}.png`. В JSON-отчёте — путь относительно каталога отчёта.

### Видеозапись

При включённом `--record`:
- `startRecording()` перед каждым тестом.
- `stopRecording()` после каждого теста.
- Видео сохраняется как `{индекс-теста}-{имя-теста}.mp4`.
- Прикрепляется к отчёту (Allure: вложение видео).

Подробности по записи (overlays, captions, narration) — см. [web-test-recording-guide.md](web-test-recording-guide.md).

---

## 12. Сброс состояния

Встроенный механизм, выполняется после `afterEach` (и `teardown`) каждого теста. Псевдокод и условие выхода — в §6 «Встроенный сброс состояния».

Для мульти-контекстных тестов сброс пробегает по всем живым контекстам, использованным тестом.

Гарантирует, что каждый тест стартует с чистого рабочего стола, независимо от того, как завершился предыдущий (падение, таймаут, ошибка утверждения).

---

## 13. Параметризация

```js
export const name = 'Заполнение поля {type}';
export const params = [
  { type: 'String', field: 'Наименование', value: 'Тест' },
  { type: 'Number', field: 'Цена', value: '100.50' },
  { type: 'Date',   field: 'ДатаПоступления', value: '01.01.2024' },
  { type: 'Boolean',field: 'Активен', value: true },
];

export default async function({ fillFields, getFormState, assert }, { type, field, value }) {
  await fillFields({ [field]: value });
  const state = await getFormState();
  assert.equal(state.fields.find(f => f.name === field)?.value, String(value));
}
```

Параметры разворачиваются в отдельные тесты на этапе discovery:
- Имя теста формируется подстановкой через шаблон `{key}` в `mod.name`; если шаблона нет — суффикс `[index]`.
- Тест получает `param` вторым аргументом (`default(ctx, param)`).
- В отчётах каждый набор — отдельная запись со своим `name` и `param` в `testInfo`.
- `ctx.testInfo.param` доступен в теле теста и хуках.

---

## 14. Обнаружение тестов

Позиционные аргументы — пути к тестам; каталог, от которого считаются относительные пути в отчёте, — корень сьюта (§1 «Резолв корня сьюта»). Сборщик рекурсивно обходит дерево и собирает файлы по правилам ниже.

```
tests/myapp/
  _hooks.mjs                # пропускается (префикс '_')
  _allure/                  # пропускается (префикс '_')
  webtest.config.mjs        # пропускается (не *.test.mjs)
  sales/
    01-order-create.test.mjs
    02-order-post.test.mjs
  warehouse/
    01-receipt.test.mjs
```

### Правила

| Аспект | Поведение |
|--------|-----------|
| Обход | Рекурсивный; файлы и каталоги, имя которых начинается на `_` или `.`, пропускаются |
| Шаблон имени | Только `*.test.mjs` |
| Несколько путей | `node run.mjs test a.test.mjs b.test.mjs dir/` — наборы объединяются, дублируются и сортируются |
| Порядок | Сортировка по полному относительному пути (`sales/01` идёт до `warehouse/01`) |
| `file` в отчёте | `relative(<корень сьюта>, file)` с разделителем `/`, например `sales/01-order-create.test.mjs` |
| Фильтр по пути с CLI | `node run.mjs test tests/myapp/sales/` запустит только подкаталог |
| Конкретный файл | `node run.mjs test tests/myapp/sales/01-order-create.test.mjs` |

### Чего НЕТ (сознательное упрощение)

- **`_hooks.mjs` / `webtest.config.mjs` на уровне подкаталога.** Оба берутся только из корня сьюта — того каталога, где лежит ближайший из них (§1 «Резолв корня сьюта»). Подкаталоги своих копий не получают; вложенный каталог со своим `webtest.config.mjs` — это уже отдельный сьют.
- **Многоуровневой Suite-разметки из дерева каталогов.** Allure-метка `suite` строится только по первому уровню (`dirname(filePath)`); более глубокую группировку делайте через `tags`.
- **Контекста по умолчанию на уровне подкаталога.** Каждый тест объявляет `context` / `contexts` сам; от пути контексты не наследуются.

### Конвенции

1. **Папки — для организации**, не для механики. Общая подготовка — в глобальном `_hooks.mjs.beforeAll` или в `setup` / `teardown` конкретного теста.
2. **Группировку в отчётах** делайте через `tags: ['sales']`, не через путь. Это даёт фильтрацию (`--tags=sales`) и работает в Allure/JUnit без дополнительной разметки.
3. **«Запустить только sales»** — двумя путями: `tests/myapp/sales/` (по каталогу) или `--tags=sales` (по тегу).
4. **Сортировка по полному пути** означает, что `warehouse/01-x` запустится ПОСЛЕ `sales/02-y`. Для строгого глобального порядка используйте 3-значные префиксы (`010-`/`020-`/…) либо явные теги-фазы.

---

## 15. Ошибки и трассировка

### Авто-обнаружение 1С-ошибок

Все ACTION_FNS (`clickElement`, `fillFields`, `fillField`, `selectValue`, `fillTableRow`, `deleteTableRow`, `openCommand`, `navigateSection`, `navigateLink`, `openFile`, `closeForm`, `filterList`, `unfilterList`) обёрнуты. После каждого вызова:

1. Проверяется `state.errors.modal` / `balloon`.
2. Если есть — делается скриншот (до того, как `fetchErrorStack` закроет модалку).
3. Для модальных ошибок вызывается `fetchErrorStack` (две стратегии — Path 1 для платформенных исключений с кнопкой «Открыть отчёт», Path 2 для `ВызватьИсключение` через гамбургер-меню → О программе → Информация для тех. поддержки; см. [web-test-guide.md](web-test-guide.md)).
4. Бросается исключение со структурированным `err.onecError`:
   ```js
   err.onecError = {
     step,        // имя действия (например 'clickElement')
     args,        // аргументы, с которыми вызывалось
     errors,      // { modal?, balloon? }
     formState,   // снапшот getFormState
     stack,       // { raw, entries: [{ location, code }], timestamp } | null
     screenshot,  // путь к скриншоту
   };
   ```

В отчёте это превращается в `error.onecError.stack` для упавшего теста. Разбор причин падения и категории — см. §16.

### Платформенные модальные диалоги

`getFormState()` возвращает `platformDialogs` — массив платформенных диалогов (About, Support Info, Error Report). `closeForm()` закрывает их. `dismissPendingErrors()` чистит ожидающие модалки автоматически (вызывается перед каждым ACTION_FN, плюс в встроенном сбросе после теста).

Модальное окно платформенной ошибки сначала рендерится в переходном состоянии (~1 с), затем перерисовывается в стабильное. `fetchErrorStack` ждёт 1.5 с и перепроверяет `hasReport` перед выбором стратегии.

### Таймауты

- Таймаут теста: `mod.timeout` или `config.timeout` или CLI `--timeout=ms`.
- Таймаут срабатывает на уровне теста (`testFn()` + `setup` + `teardown`), не на уровне отдельного `step` или action.
- При таймауте: текущий step помечается failed, бросается ошибка с сообщением `Timeout (<N>ms)`, далее запускается `afterEach` и встроенный сброс.
- Таймаут **безусловен**: `export const timeout` — это контракт теста, а не пожелание. Если действие ещё
  выполняется, оно всё равно прерывается; чтобы разрешить долгую операцию, поднимают `timeout` теста.

#### Диагноз при таймауте (вердикт)

Таймаут не просто помечает тест красным — движок выясняет, **почему** тест не уложился, и кладёт вердикт
в сообщение об ошибке и в trace Allure. Разделитель — асимметрия двух пробников: вызов в browser-процесс
(`cookies()`) отвечает даже тогда, когда JS-поток страницы заблокирован, а `page.evaluate` — нет.

| Вердикт | Что означает | Что делать |
|---------|--------------|------------|
| `hang` | Браузер жив, рендерер не отвечает — JS-поток страницы заблокирован. Ничто, что идёт через рендерер (клики, `evaluate`, скриншот), уже не вернётся | Смотреть, что подвесило клиента; тест прерван, контекст пересоздан |
| `slow` / `slow-network` | Всё живо, тест просто не уложился в свой таймаут (`slow-network` — есть незавершённые запросы) | Поднять `export const timeout` |
| `browser-dead` | Браузер не отвечает целиком | Стенд/окружение |

Пример вывода:

```
Timeout (30000ms) — verdict: hang (renderer unresponsive, browser alive)
  context "a" [tab] · renderer probe: timed out at 2000ms · browser probe: ok in 14ms
  network: 0 in flight, last event 27.4s ago (312 req / 312 resp)
  recovery: context aborted (logout: node, closed: page) — next test recreates it
```

#### Прерывание и восстановление

- `Promise.race` **не отменяет** зависший вызов — промис отменить нельзя. Поэтому при вердиктах
  `hang`/`browser-dead` движок **уничтожает** зависшее: `abortContext` закрывает страницу
  (`runBeforeUnload:false` — браузер сносит вкладку, не спрашивая её JS), и повисший `await` отваливается
  с «Target closed». Следующий тест поднимает контекст заново лениво (`ensureContext`).
- **Освобождение лицензии.** Штатный logout идёт `fetch`-ем изнутри страницы и на зависшей странице
  невозможен. Поэтому `abortContext` шлёт `POST /e1cib/logout?seanceId=…` **из Node** — сеанс 1С опознаётся
  `seanceId`-ом в URL, кук у клиента нет, так что запрос равносилен «страничному». Каскад: Node → страница →
  живая соседняя страница; если все три не удались, в отчёт пишется предупреждение об утечке сеанса.
- На `hang` пропускаются скриншот, `teardown` и встроенный сброс: на мёртвой странице они не могут
  преуспеть, а слот всё равно уничтожается. По той же причине зависший тест **не ретраится** (`--retry`
  игнорируется для него): заблокированный рендерер — не флейк.
- Весь путь очистки (скриншот, `teardown`, `afterEach`, сброс, запись/остановка видео, закрытие контекстов,
  `disconnect`) ограничен дедлайнами. Пробой дедлайна печатается строкой `! <операция>: timed out after Nms`
  и прогон едет дальше — молча зависнуть путь очистки больше не может.

#### Бюджеты служебных операций (`deadlines`)

Дефолты рассчитаны на лёгкий стенд и переопределяются поштучно ключом `deadlines` в `webtest.config.mjs`
(см. §7). Неизвестный ключ или неположительное значение — ошибка до старта прогона (опечатка в имени ключа
означала бы, что переопределение молча не действует).

| Ключ | Default | Что ограничивает |
|------|---------|------------------|
| `screenshot` | 10000 | Скриншот при падении |
| `teardown` / `afterEach` | 15000 | `teardown` теста / хук `afterEach` |
| `setActive` | 5000 | Переключение активного контекста |
| `resetState` | 20000 | Встроенный сброс состояния (до 10 итераций `getFormState` + `closeForm`) |
| `startRecording` / `stopRecording` | 15000 / 40000 | Видео (у ffmpeg внутри свои 30 с) |
| `closeContext` | 20000 | Закрытие/прерывание контекста |
| `disconnect` | 30000 | Финальное закрытие браузера |
| `hooks` | 120000 | `afterAll` / `cleanup` |
| `abortAll` | 30000 | Весь блок прерывания одного зависшего теста |
| `probe` | 2000 | Пробники рендерера/браузера при таймауте |

`prepare` и `beforeAll` **не ограничены сознательно**: `prepare` пересобирает стенд, и его честная
длительность зависит от размера прикладного решения; его падение обязано оставаться фатальным.

**Пробой `resetState` прерывает контекст** (а не просто пишет строку): состояние UI после неудавшегося
сброса неизвестно, и переиспользование слота утекло бы грязным состоянием в следующий тест — худший исход
для плохо подобранного бюджета. Вместо этого слот уничтожается, следующий тест получает чистый через
`ensureContext`. Слишком тесный бюджет стоит перезапуска контекста, но никогда — неверного результата теста.
- Тело прерванного теста продолжает жить (промис не отменяем). Его поздние вызовы к движку блокируются
  с ошибкой `test abandoned (timeout)` — иначе `finally` упавшего теста кликал бы в окне следующего.

#### Глобальный потолок прогона

`--global-timeout=ms` (или `globalTimeout` в конфиге) — потолок на весь прогон. Работает даже когда прогон
стоит внутри зависшего теста: неразрешённый промис не блокирует event loop. По срабатыванию: пишется отчёт,
затем принудительно освобождаются все контексты (лицензии) и закрывается браузер, затем выход с кодом `2`.
Если зависло само сворачивание — выход с кодом `3`. Внешний watchdog для прогона не нужен.

### Повторы

При `--retry=N` (или `config.retries`) упавший тест повторяется до `1 + N` раз. Для каждой попытки:
- `beforeEach` / `setup` / `default` / `teardown` / `afterEach` + встроенный сброс выполняются заново.
- `ctx.testInfo.attempt` инкрементируется.
- В отчёте фиксируется `attempts` — фактически выполнено попыток.
- Считается passed, если последняя попытка зелёная; иначе failed.

`beforeAll` / `afterAll` / `prepare` / `cleanup` / `afterOpenContext` / `beforeCloseContext` не повторяются (это жизненный цикл всего прогона или контекста, не теста).

---

## 16. Анализ результатов

### Что лежит в записи об упавшем тесте

JSON-отчёт (`tests[]`, полная структура — §9) для каждого падения содержит:

- `error.message` — текст исключения.
- `error.step` — имя шага, на котором упало.
- `error.screenshot` — путь к скриншоту падения (если стратегия скриншотов не `off`).
- `error.onecError` (только для 1С-исключений) — структура с полями: `step` (имя действия, например `clickElement`), `args` (аргументы вызова), `errors` (модальное окно или balloon), `formState` (снимок формы на момент ошибки), `stack` — платформенный стек вызовов 1С с `entries[{location, code}]`.
- `steps[]` — пошаговая разбивка с метками времени, у каждого шага свой `status` и `error`.

В Allure-отчёте те же данные лежат в `statusDetails` (текст ошибки и трассировка), скриншоты и видео — во вложениях, автоматическая группировка по причинам — через `categories.json` (§9).

### Типовые причины падений

Большинство падений на 1С-стенде сводится к трём причинам, и их полезно различать при разборе отчёта:

- **Ошибка в тесте** — селектор не нашёл элемент, ожидание не сошлось, гонка без точки синхронизации. Признаки: падение стабильно повторяется на одном и том же шаге; после правки теста воспроизводимость исчезает. Действие — изменить тест.
- **Ошибка в прикладном решении** — реально воспроизведённое некорректное поведение конфигурации. Признаки: упал шаг, имитирующий пользовательскую операцию; в `error.onecError.stack` есть платформенный стек вызовов 1С с указанием на код решения. Действие — передать разработчику конфигурации, тест править не нужно.
- **Сбой стенда** — таймаут Apache, форма входа не загрузилась, не хватило веб-лицензий. Признаки: падение на навигации или входе; от прогона к прогону падает «то одно, то другое», без связи с содержанием теста. Действие — править инфраструктуру (`prepare()`, очистка сессий, идемпотентность хуков), не тесты.

`categories.json` Allure (§9) удобно настраивать именно под эти три категории — regex по `error.message` уже даёт первичную классификацию в виджете Categories.

---

## 17. Глоссарий

| Термин | Определение |
|--------|-------------|
| **Test path** | Путь к тесту или каталогу тестов, переданный позиционным аргументом. Корень только для discovery — что именно запускать. |
| **Suite root (корень сьюта)** | Каталог, найденный подъёмом от test path до первого `webtest.config.mjs` / `_hooks.mjs` (§1). От него берутся конфиг, хуки, `_allure/`, каталог отчёта по умолчанию и относительные пути `file` в отчёте. Не зависит от того, запустили сьют целиком или один его подкаталог, — поэтому ID теста в отчёте стабилен. |
| **Context (BrowserContext)** | Изолированная сессия Playwright. Куки/состояние/страница независимы. В рамках одного теста используется один или несколько контекстов. |
| **Active context** | Контекст, на котором сейчас оперируют функции browser-API. Переключается `setActiveContext`. |
| **Primary context** | Контекст, активный на входе в тест. Декларация (`mod.context` или `mod.contexts[0]`). Зафиксирован в `testInfo.primaryContext`. |
| **Default context** | Контекст из `config.defaultContext` (или единственный URL в упрощённой конфигурации). Используется, если тест не указал `context` / `contexts`. Под лимитом `maxContexts` — вытесняем, если не входит в `pinnedContexts` (см. §8 «Пул контекстов и лицензии»). |
| **Pinned context** | Контекст из `config.pinnedContexts`, не подлежащий LRU-вытеснению. По умолчанию = `[defaultContext]`. |
| **Scoped API** | Объект на `ctx.<name>` в мульти-контекстных тестах — обёртки browser-функций, авто-переключающие контекст перед каждым вызовом. |
| **Action function (ACTION_FN)** | Browser-функция, обёрнутая авто-обнаружением 1С-ошибок. Список — в §3. |
| **Step** | Логический блок внутри теста, обёрнутый `step(name, fn)`. Маппится на Allure-step, попадает в `report.tests[].steps[]`. |
| **Reset state** | Встроенная пост-тестовая очистка: `dismissPendingErrors` + закрытие всех открытых форм до рабочего стола. Выполняется после `afterEach`. |
| **hookArgs** | Массив строк, переданных в `prepare` / `cleanup` после CLI-разделителя `--`. Движком не интерпретируются. |
| **Severity** | Уровень критичности теста (`blocker / critical / normal / minor / trivial`) для Allure. Резолвится из `mod.severity`, тегов, `config.severity`, `config.defaultSeverity`. |

---

## См. также

- [web-test-guide.md](web-test-guide.md) — browser API (`clickElement`, `getFormState`, `readTable`, …) и интерактивный режим.
- [web-test-recording-guide.md](web-test-recording-guide.md) — видеозапись, captions, narration, overlays.
- [web-test-regression-guide.md](web-test-regression-guide.md) — пользовательский гайд (на русском, с быстрым стартом).
- `/web-test` skill — `.claude/skills/web-test/SKILL.md`, `regress.md` (рабочая шпаргалка для модели).
