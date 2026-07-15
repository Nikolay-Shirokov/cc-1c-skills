# Regression suite authoring

Use this when the user asks to cover a 1C solution with automated regression tests, build out a test suite, or run an existing suite and analyse failures. For ad-hoc single-script automation, stay with the `run`/`exec` modes from SKILL.md instead.

The runner is the same `run.mjs`. The mode is `test`:

```bash
node $RUN test <dir|file>... [flags]
```

Positional args are test paths (files and/or dirs, multiple allowed). URL is NOT positional — it comes from `webtest.config.mjs`; override with `--url=<url>`.

Tests live next to the project they cover (not inside the skill). Convention: `tests/` at the project root, with `_hooks.mjs` and `webtest.config.mjs` at the suite root. Tests are ES modules with `*.test.mjs` suffix.

## When to choose `test` over `exec`

| Goal | Mode |
|------|------|
| Explore a form, prototype a single step, debug one selector | `exec` (interactive session) |
| Reproduce a bug as a failing test before fixing it | `test` |
| Cover a feature so future changes are checked automatically | `test` |
| Run the project's regression on a new build | `test` |
| Generate a screencast walkthrough | `exec` with `startRecording` |

Don't write a `.test.mjs` for a one-shot user request. Don't drive a regression suite through chained `exec` calls.

## Before writing tests — recon

Two layers, in order.

**1. Static recon — metadata.** Never invent identifiers. For every metadata object the user mentions, run the matching info skill first: `/meta-info` (attributes/tabular sections), `/form-info` (form layout), `/skd-info` (DCS), `/mxl-info` (templates), `/role-info` (rights), `/subsystem-info` (composition / command interface). If the user names objects you can't find — stop and ask.

**2. Live recon — interactive walkthrough.** For any non-trivial scenario, walk the path live in `exec` mode before transcribing it. Metadata tells you what exists; the live walkthrough tells you what actually happens. Capture from `getFormState()`: exact button names (`'Провести и закрыть'`, not `'Сохранить'`), table section names for multi-grid forms, required fields, places where a real async wait is needed. Then transcribe the working sequence into `*.test.mjs`, wrapping logical chunks in `step('...', async () => { ... })`.

The mechanics of `exec` / `getFormState` / `fillFields` / `clickElement` are in [SKILL.md](SKILL.md) — read it before recon if you haven't already.

When live recon is overkill: trivial reads (`navigateSection` + `readTable` + assert non-empty), or scenarios you've already proven once in this session. When it's essential: confirmation dialogs, posting/cancellation flows, reports with custom filters, multi-grid forms, user-customised forms.

## Suite layout

**Each application gets its own subfolder under `tests/`.** A single repo may host several independent suites side by side — they must not share `_hooks.mjs` or `webtest.config.mjs`, because each suite restores a different DB, publishes to a different URL, and ships its own test data.

```
tests/
  <app-name>/                  # application regression — one per solution
    _hooks.mjs
    webtest.config.mjs
    _allure/                   # optional static Allure config
    01-login/
    02-counterparties/
    ...
  <another-app>/               # second solution, fully isolated
```

Inside the application subfolder, organize by **feature**, not by metadata kind. Numeric prefixes on both folder and file enforce run order — discovery walks recursively and sorts files by full relative path; entries starting with `_` or `.` are skipped (so `_hooks.mjs`, `_allure/` won't be picked up as tests).

```
tests/<app-name>/
  01-login/
    01-open-base.test.mjs
    02-section-navigation.test.mjs
  02-counterparties/
    01-create.test.mjs
    02-edit-phone.test.mjs
  03-goods-receipt/
    01-fill.test.mjs
    02-post.test.mjs
  05-approval-process/
    01-end-to-end.test.mjs     # multi-user
```

Per-folder `_hooks.mjs` / `webtest.config.mjs` inside the application subfolder are NOT supported — only the application-root copies are loaded.

## Test file anatomy

```js
export const name = 'Создание контрагента';       // required
export const tags = ['catalog', 'create'];        // optional, used for filtering + Allure
export const timeout = 60000;                     // optional, default 30000
// export const skip = 'pending fix #123';        // optional: true | string
// export const only = true;                      // debug-only — never commit
// export const context = 'manager';              // optional, single non-default context
// export const contexts = ['clerk', 'manager'];  // optional, multi-user test
// export const severity = 'critical';            // optional, overrides config severity

export async function setup(ctx) {
  // per-test prep — runs before default. Skip if not needed.
}

export async function teardown(ctx) {
  // per-test cleanup — runs after default, always (even on failure).
}

export default async function(ctx) {
  const { navigateSection, openCommand, clickElement, fillFields,
          readTable, closeForm, getFormState,
          assert, step, log } = ctx;

  await step('Открыть список контрагентов', async () => {
    await navigateSection('Продажи');
    await openCommand('Контрагенты');
  });

  await step('Создать нового контрагента', async () => {
    await clickElement('Создать');
    await fillFields({ 'Наименование': 'Тест ' + Date.now() });
    await clickElement('Записать и закрыть');
  });

  await step('Убедиться, что элемент появился в списке', async () => {
    const t = await readTable();
    assert.tableHasRow(t, r => r['Наименование']?.startsWith('Тест '));
  });
}
```

**Step names — in Russian, descriptive.** Step labels surface in the console output, in JSON/JUnit, and as Allure step nodes. Russian-speaking QA reads them. Use a full action phrase (`'Создать нового контрагента'`), not a tag (`'create'`) and not a transliteration. Same applies to `export const name` and `displayName` in `webtest.config.mjs`.

## `ctx` contract

The runner injects every `browser.mjs` export into `ctx` (all 1C action functions auto-detect platform errors — see SKILL.md), plus the test utilities below.

### Test utilities

```js
step(name, fn)             // async wrapper. Records start/stop. Nested calls supported.
                           // On throw: marks the step failed, re-throws.
                           // On screenshot='every-step': captures after fn().
log(...args)               // adds a line to ctx.testInfo's output (goes into JSON / Allure
                           // attachment). Use instead of console.log inside tests.
assert.*                   // see "Assertions" below
```

### `ctx.testInfo` (always set, read-only)

```js
{
  name,             // 'Навигация по разделам' (with params substituted)
  file,             // '01-navigation.test.mjs' (basename)
  filePath,         // relative path inside testDir
  tags,             // ['nav', 'smoke']
  timeout,          // ms
  attempt,          // 1..maxAttempts (1-based)
  maxAttempts,      // 1 + retry
  param,            // { ... } | undefined (only when export const params is set)
  contexts: {       // mirrors config.contexts; includes custom fields like displayName
    clerk:   { url, isolation, displayName, ... },
    manager: { ... },
  },
  primaryContext,   // 'clerk' — name of the context active at test entry
                    // (= t.context for single, t.contexts[0] for multi)
}
```

### `ctx.testResult` (only in `afterEach`)

```js
{
  status,      // 'passed' | 'failed'
  duration,    // ms
  attempts,    // attempts actually executed
  error,       // { message, step?, screenshot? } | null
  steps,       // array of step results (each: { name, start, stop, status, error?, steps[] })
}
```

### Context shape

- **Single-context (default or `export const context = 'manager'`):** all API on `ctx` top-level — `ctx.clickElement(...)`, `ctx.getFormState()`, etc.
- **Multi-context (`export const contexts = ['clerk', 'manager']`):** each name is its own scoped namespace — `ctx.clerk.clickElement(...)`, `ctx.manager.fillFields(...)`. `step`, `assert`, `log`, `testInfo` stay top-level. Scoped methods auto-switch the active page before each call.

## Assertions

All on `ctx.assert`. Throw `AssertionError` with `.message`, `.actual`, `.expected`. No dependencies.

```js
// generic
assert.ok(value, msg?)                    // truthy
assert.equal(actual, expected, msg?)      // ===
assert.notEqual(actual, expected, msg?)   // !==
assert.deepEqual(actual, expected, msg?)  // JSON-compare
assert.includes(haystack, needle, msg?)   // string.includes / array.includes
assert.match(string, regex, msg?)         // regex.test(string)
await assert.throws(asyncFn, msg?)        // passes if fn throws (use await)

// 1C-specific — operate on getFormState() / readTable() output
assert.formHasField(state, 'Контрагент', msg?)        // state.fields[name] exists
assert.formTitle(state, expected, msg?)               // state.title includes expected
assert.tableHasRow(table, predicate, msg?)            // predicate: object (partial match) or fn(row) => bool
                                                      //   object form: { 'Наименование': 'Тест' }
                                                      //   fn form:     r => r['Сумма'] > 100
assert.tableRowCount(table, expected, msg?)           // table.rows.length === expected
assert.noErrors(state, msg?)                          // !state.errors
```

Beyond these, just use plain JS (`throw new Error(...)`) — there's no custom matcher extension API. The 1C-specific helpers are the ones worth preferring over hand-rolled equivalents because their error messages name the actual fields/rows present, which speeds up triage.

## webtest.config.mjs

```js
export default {
  // Single-context shorthand:
  url: 'http://localhost:9191/myapp/ru_RU',

  // OR multi-context:
  // contexts: {
  //   clerk:   { url: 'http://localhost:9191/myapp-clerk/ru_RU',   displayName: 'Кладовщик' },
  //   manager: { url: 'http://localhost:9191/myapp-manager/ru_RU', displayName: 'Менеджер' },
  // },
  // defaultContext: 'clerk',

  // Context-pool / 1C license management (all optional; omit = no cap, default stays open).
  // maxContexts: 2,            // cap on simultaneous 1C sessions; omit for unlimited
  // contextPolicy: 'reuse',    // 'reuse' (keep open within cap) | 'strict' (close after each test)
  // pinnedContexts: [],        // never evicted; defaults to [defaultContext], [] makes default evictable

  timeout: 30000,
  retries: 0,
  screenshot: 'on-failure',  // 'every-step' | 'off'
  record: false,

  // Severity → tags mapping for Allure. Each tag at most one bucket.
  severity: {
    critical: ['smoke', 'crud'],
    minor:    ['recording'],
  },
  defaultSeverity: 'normal',
};
```

CLI flags override config. Use latin context IDs + Russian `displayName` for ergonomics — `ctx.testInfo.contexts.clerk.displayName` is friendlier than mixed-case Cyrillic keys.

## _hooks.mjs

Two layers. Infra hooks run without a browser; testlevel hooks receive `ctx`.

```js
import { execSync } from 'child_process';

// Infra — runs once around the whole suite.
export async function prepare({ hookArgs, log, config }) {
  // hookArgs: everything after `--` on the CLI, as a string[]. Parse yourself.
  const force = hookArgs.includes('--rebuild-stand');
  const dataArg = hookArgs.find(a => a.startsWith('--data='))?.slice('--data='.length);
  log('preparing stand, force=', force, 'data=', dataArg);
  // Idempotent hash-locks on inputs (config sources, EPF spec, DB dump) keep
  // warm starts to a liveness probe.
}

export async function cleanup({ log, config }) { /* optional */ }

// Testlevel — runs with browser ctx.
export async function beforeAll(ctx) { /* once after first context opens */ }
export async function afterAll(ctx)  { /* once before final teardown */ }
export async function beforeEach(ctx) { /* ctx.testInfo is set */ }
export async function afterEach(ctx)  { /* ctx.testInfo + ctx.testResult set */ }

// Per-context — runs whenever a context is created/closed.
export async function afterOpenContext(ctx, name, spec)   { /* spec = config.contexts[name] */ }
export async function beforeCloseContext(ctx, name, spec) { }
```

Built-in state reset (`dismissPendingErrors` + close all forms) runs after `afterEach` automatically. Don't reimplement it in `afterEach`.

Pass hook args after `--`:

```bash
node $RUN test tests/<app-name>/ --bail -- --rebuild-stand --data=demo
                                 └─runner─┘ └────── hookArgs ─────────┘
```

**Where to put data setup:**
- DB restore, publication, EPF build → `prepare()`. Make it idempotent (hash-locks).
- Test-specific seed data → per-test `setup`.
- Shared session-wide warmup → `beforeAll`.

## Ready-to-paste patterns

A minimal CRUD shape is in *Test file anatomy* above — use it as the rhythm for catalog/document tests, swapping in the right section/command/fields. The patterns below cover what's specific to the regression engine, not the browser API (those live in SKILL.md).

### DCS report

```js
await openCommand('Остатки товаров');
// Reset user settings — 1C persists them between sessions.
await clickElement('Ещё');
await clickElement('Установить стандартные настройки');

await selectValue('Номенклатура', 'Товар 02');   // auto-enables the filter checkbox
await clickElement('Сформировать');
await wait(3);
const r = await readSpreadsheet();
assert.deepEqual(r.headers, ['Номенклатура', 'Количество', 'Сумма']);
assert.ok(r.data.length >= 1);
assert.ok(r.totals?.['Сумма']);
```

### Multi-user process

```js
export const contexts = ['clerk', 'manager'];

export default async function({ clerk, manager, step, assert }) {
  await step('Кладовщик создаёт накладную', async () => {
    await clerk.navigateSection('Склад');
    await clerk.openCommand('Приходные накладные');
    await clerk.clickElement('Создать');
    await clerk.fillFields({ 'Контрагент': 'ООО Север' });
    await clerk.clickElement('Записать');
  });
  await step('Менеджер утверждает накладную', async () => {
    await manager.navigateSection('Согласование');
    await manager.openCommand('На утверждении');
    await manager.clickElement('ООО Север', { dblclick: true });
    await manager.clickElement('Утвердить');
  });
  await step('Кладовщик видит новый статус', async () => {
    const s = await clerk.getFormState();
    assert.equal(s.fields['Статус']?.value, 'Утверждён');
  });
  await step('Освободить сессию кладовщика', async () => {
    await manager.closeContext('clerk');   // free a 1C license for the next test
  });
}
```

Close contexts you no longer need (`manager.closeContext('clerk')`) before the next multi-user test starts — frees a 1C web-client license and stops the previous role from holding state. On tight-license stands prefer configuring the pool (`maxContexts` + `contextPolicy` + `pinnedContexts`) over manual per-test closing — the runner then evicts and reuses sessions automatically.

**Context pool (1C licenses).** With `maxContexts` set, the runner caps simultaneous 1C sessions: before each test it evicts least-recently-used contexts that are neither pinned nor needed, reusing already-open ones. `contextPolicy: 'reuse'` (default) keeps sessions for speed; `'strict'` closes a test's non-pinned contexts right after it. `pinnedContexts` are never evicted (default `[defaultContext]`; set `[]` to make the default context evictable on a tight stand). If the pool can't fit even after eviction, the test fails with a clear `context pool exhausted` error instead of an opaque connection failure.

### Failing-test repro

```js
export const name = 'Bug #123: накладная без контрагента не должна проводиться';
export const tags = ['bug', 'validation'];

export default async function({ openCommand, clickElement, getFormState, assert, step }) {
  await openCommand('Приходные накладные');
  await clickElement('Создать');
  await clickElement('Провести');
  const s = await getFormState();
  assert.ok(s.errorModal || s.fields['Контрагент']?.required,
    'Должна быть ошибка валидации или поле помечено обязательным');
}
```

Write it red first, hand it to the user, fix the underlying issue, re-run green.

### Parameterised test

```js
export const name = 'Заполнение поля {type}';
export const params = [
  { type: 'String', field: 'Наименование', value: 'Тест' },
  { type: 'Number', field: 'Цена', value: '100.50' },
  { type: 'Date',   field: 'ДатаПоступления', value: '01.01.2024' },
];

export default async function({ fillFields, getFormState, assert }, { type, field, value }) {
  await fillFields({ [field]: value });
  const state = await getFormState();
  assert.equal(state.fields[field]?.value, String(value));
}
```

Each `params` entry becomes its own test in the report. `{key}` placeholders in `name` get substituted; without placeholders, a `[index]` suffix is added. `ctx.testInfo.param` carries the current row.

## Running

```bash
node $RUN test tests/<app-name>/                                       # full app suite
node $RUN test tests/<app-name>/03-goods-receipt/                      # one feature folder
node $RUN test tests/<app-name>/02-counterparties/01-create.test.mjs   # one file
node $RUN test tests/<app-name>/02-x.test.mjs tests/<app-name>/05-y.test.mjs  # several files
node $RUN test tests/<app-name>/ --tags=smoke                          # by tag (intersection)
node $RUN test tests/<app-name>/ --grep='накладн'                      # by name regex
node $RUN test tests/<app-name>/ --bail --retry=1                      # stop on first fail, allow 1 retry
node $RUN test tests/<app-name>/ --report=allure-results --format=allure --report-dir=allure-results
node $RUN test tests/<app-name>/ --report=-                            # machine JSON to stdout, progress to stderr
node $RUN test tests/<app-name>/ --global-timeout=3600000              # ceiling for the whole run (exit 2)
node $RUN test tests/<app-name>/ -- --rebuild-stand                    # after `--` → hookArgs
```

**Timeouts and hangs.** A test's `timeout` is a contract, not a wish: when it expires the runner probes the
context and destroys whatever is wedged, so the run always moves on. The failure carries a verdict — `hang`
(browser alive, renderer's JS thread blocked; the context is aborted, its 1C seance released from Node, and
the next test recreates it) versus `slow`/`slow-network` (nothing is broken — raise `export const timeout`).
A `hang` is never retried. Exit codes: `1` red tests, `2` `--global-timeout` fired (report written, seances
released), `3` the shutdown itself wedged. Allure results are written per test as it finishes, so a hang
cannot destroy the results collected before it — no external watchdog needed.

**Output contract.** `test` behaves like a test runner: by default the human report (with the summary as the last line) goes to **stdout** — read the tail of stdout + exit code. The machine report is opt-in via `--report`: `--report=path` writes it to a file (default JSON; XML for `--format=junit`), `--report=-` writes it to stdout while progress moves to stderr. Allure needs `--format=allure` + a directory (`-` is invalid for allure). For detailed triage use `--report=path` or `--report=-`. **In `--report=-` mode never use `2>&1`** — it merges stderr progress into the stdout JSON. (In the default mode there is no JSON in stdout, so `… | tail` is safe.)

### Allure static config — `_allure/`

The runner copies `<testDir>/_allure/` into the report directory before generating Allure output. Drop in `categories.json` (regex-based failure classification — useful for 1C-specific buckets: license pool exhaustion, platform exceptions, runner timeouts, assertion failures), `environment.properties` (optional, often emitted dynamically by `prepare()`), `executor.json` (CI metadata, skip locally). The underscore prefix keeps the directory out of test discovery.

## Severity guidance

When the user doesn't dictate, default to:

| Test kind | Severity |
|-----------|----------|
| Login + section navigation, basic CRUD on covered entities | `critical` (also tag `smoke`) |
| Documents posting, report generation, end-to-end processes | `critical` |
| Field-level edge cases, formatting, optional flows | `normal` |
| Cosmetic / recording / non-functional | `minor` |
| Reserved for show-stopper protections | `blocker` (use sparingly) |

Don't promote everything to `critical` — it loses signal in the Allure dashboard.

## Anti-patterns

- **Sleeps as a substitute for assertions.** `wait(5)` after `openCommand` is fine; `wait(30)` because something flakes is a bug — wait on `getFormState` instead.
- **Retry as a substitute for understanding.** "Not found" twice means the data isn't there or the label is wrong. Don't loop.
- **Position-based row identification** (`rows[0]`) when the DB has shared seed data. Filter by a unique marker (`Date.now()` suffix) instead.
- **Hand-writing reset code in `afterEach`.** The runner already closes forms and dismisses errors after the hook.
- **Cross-test state assumptions.** Each test must start from the desktop and seed its own data. Order-of-execution coupling is a regression-suite trap.
- **`tags: ['smoke']` on a 90-second test.** Smoke means fast.
- **Skipping recon** because "I know what this catalog looks like." The project's customisation almost certainly differs from stock.

(General browser-API anti-patterns — raw DOM, `clickElement('Закрыть')` instead of `closeForm()` — live in SKILL.md.)

## After a run — failure triage

1. Scan the JSON or Allure summary for `failed`.
2. For each failure, read `error.message` + `error.step` + screenshot.
3. If `error.onecError.stack` is present — it's a 1C exception, look at the platform trace.
4. Classify:
   - **Test bug** — selector wrong, expectation wrong, race with no anchor → fix the test.
   - **Application bug** — actual misbehaviour reproduced → report to the user with the failing step name and the platform stack.
   - **Stand flake** — Apache timeout, login form not loading, license shortage → fix the hook idempotency or session-cleanup logic, not the test.
5. After fixes, re-run only the affected files before the full suite.

Report back to the user with the classification, not raw failure dumps.

## Reference

- Browser API: [SKILL.md](SKILL.md)
- Video and narration: [recording.md](recording.md)
