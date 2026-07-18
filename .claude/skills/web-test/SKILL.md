---
name: web-test
description: Тестирование 1С через веб-клиент — автоматизация действий в браузере. Используй когда пользователь просит проверить, протестировать, автоматизировать действия в 1С через браузер
argument-hint: "сценарий на естественном языке"
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
---

# /web-test — Browser automation for 1C web client

Automates user interactions with 1C:Enterprise web client via Playwright — navigating sections, filling forms, reading tables and reports, filtering lists.

## Quick start

```bash
RUN="${CLAUDE_SKILL_DIR}/scripts/run.mjs"

# One-shot: opens browser → runs script → closes browser → exits
node $RUN run http://localhost:8081/bpdemo test-scenario.js

# Or pipe inline:
cat <<'SCRIPT' | node $RUN run http://localhost:8081/bpdemo -
await navigateSection('Продажи');
await openCommand('Заказы клиентов');
await clickElement('Создать');
await fillFields({ 'Клиент': 'Альфа' });
await clickElement('Провести и закрыть');
SCRIPT
```

## Setup (first time)

```bash
cd "${CLAUDE_SKILL_DIR}/scripts" && npm install
```

Requires Node.js 18+. `npm install` downloads Playwright and Chromium.

## URL resolution

Read `.v8-project.json` from project root. Each database has `id` and optional `webUrl`.
Construct URL as `http://localhost:8081/<id>` or use `webUrl` if set.
Use `/web-publish` first if the database is not published.

## Execution modes

### Autonomous mode (preferred for complete scenarios)

```bash
node $RUN run <url> script.js   # exits when done, no session
```

### Interactive mode (step-by-step development)

```bash
# 1. Start session in the background — `start` stays running as the server, so don't wait on
#    its stdout. Poll `status` instead: it exits 0 only once the session is loaded and live.
node $RUN start <url>            # run_in_background=true
until node $RUN status >/dev/null 2>&1; do sleep 2; done   # exit 0 = ready

# 2. Execute scripts against running session
cat <<'SCRIPT' | node $RUN exec -
const form = await getFormState();
console.log(JSON.stringify(form, null, 2));
SCRIPT

# 2b. Execute without video recording (for debugging/testing)
cat script.js | node $RUN exec - --no-record

# 2c. Override exec HTTP timeout (default 30 min). Use for long scripts
#     such as multi-block recordings + addNarration.
cat script.js | node $RUN exec - --timeout-min=120
cat script.js | node $RUN exec - --timeout=7200000
WEB_TEST_EXEC_TIMEOUT_MS=7200000 node $RUN exec script.js

# 3. Screenshot
node $RUN shot result.png

# 4. Stop (logout + close)
node $RUN stop
```

`start` runs an HTTP server in background. Use `exec`/`shot`/`stop` from other shells.

### Writing exec scripts

All browser.mjs exports are globals — no `import` needed.
`console.log()` output is captured in the JSON response.
`writeFileSync` / `readFileSync` also available.

## API reference

### Navigation

#### `navigateSection(name)` → `{ navigated, sections, commands }`
Go to a top-level section (fuzzy match). Returns list of commands in that section.
```js
await navigateSection('Продажи');
// { navigated: 'Продажи', sections: [...], commands: ['Заказы клиентов', ...] }
```

#### `openCommand(name)` → form state
Open a command from the function panel (fuzzy). Returns form state of the opened form.
```js
const form = await openCommand('Заказы клиентов');
```

#### `navigateLink(url)` → form state
Open any 1C object by metadata path (Shift+F11 dialog). Bypasses section/command navigation.
```js
await navigateLink('Документ.ЗаказКлиента');
await navigateLink('РегистрНакопления.ЗаказыКлиентов');
await navigateLink('Справочник.Контрагенты');
```

#### `openFile(path)` → form state
Open an external data processor or report (EPF/ERF) via File → Open. Handles the security confirmation dialog automatically.
```js
const form = await openFile('C:\\WS\\build\\МояОбработка.epf');
const form = await openFile('build/МояОбработка.epf'); // relative paths work too
```

#### `switchTab(name)` → form state
Switch to an already-open tab/window (fuzzy match).

### Reading form state

#### `getFormState()` → `{ form, formCount, openForms, fields, buttons, tabs, navigation?, table, tables, filters, reportSettings? }`
Returns current form structure. This is the primary way to understand what's on screen.

**form** — active form number, or `null` when no form is open (desktop).

**formCount** — number of open forms. Use this to know how many windows are stacked. `0` means desktop.

**openForms** — array of all open form numbers (e.g. `[0, 1]`). Works even when the open-windows tab bar is hidden in 1C settings.

**modal** — `true` when the active form is a modal dialog blocking the UI. Only present when modal is active.

**openTabs** — array of `{ name, active? }` from the open-windows tab bar. Only present when the tab bar is enabled in 1C settings. Do NOT rely on this — use `formCount`/`openForms` instead.

**fields** — each field has: `name`, `value`, `label?`, `actions?` (select, clear, open), `required?` (true for unfilled mandatory fields), `disabled?` (control is unavailable). `buttons[]` carry `disabled?` too.

**navigation** — form navigation panel links (for objects with subordinate catalogs): `[{ name, active? }]`. Clickable via `clickElement()`. Only present when the form has a navigation panel (e.g. "Основное", "Объекты метаданных", "Подсистемы").

**groups** — collapsible and pop-up form groups: `[{ name, title, collapsed, behavior? }]`. `collapsed: true` means the group's content is hidden — part of the form is not shown until you expand it (common on settings pages like "Администрирование → Интернет-поддержка и сервисы"). `behavior: 'popup'` marks a pop-up group (content shows in a floating panel); absent for ordinary collapsible groups. Expand/collapse (or open/close a pop-up) by the group title with `clickElement`, same vocabulary as tree nodes: `{ expand: true }` reveals (idempotent), `{ expand: false }` hides, `{ toggle: true }` flips. After expanding, the group's content becomes readable in the next `getFormState()` (its fields/hyperlinks/texts appear). Plain (non-collapsible) groups are not listed.
```js
const form = await getFormState();
// form.groups = [{ name: "ГруппаНовости", title: "Новости", collapsed: true }, ...]
await clickElement('Новости', { expand: true });   // reveal the group's content
```

**tables** — array of all visible grids: `[{ name, columns, rowCount, label? }]`. `label` is the visual group title shown on screen (e.g. "Входящие"), absent when grid has no visible title. Use `readTable()` for actual data.

**table** — backward-compatible alias for the first grid: `{ present, columns, rowCount }`.

**reportSettings** — for DCS reports: human-readable filter settings instead of raw technical names:
```js
const form = await getFormState();
// form.reportSettings = [
//   { name: "Склад", enabled: true, value: "Склад бытовой техники", actions: ["select"] },
//   { name: "Номенклатура", enabled: false, value: "" }
// ]
```

**errorModal** — if present, 1C showed an error dialog. Read the message and decide how to proceed.

**confirmation** — if present, a Yes/No dialog is shown. Call `clickElement('Да')` or `clickElement('Нет')`.

**errors.stateText** — array of SpreadsheetDocument state messages (e.g. `"Не установлено значение параметра \"X\""`, `"Отчет не сформирован..."`, `"Изменились настройки..."`). Present when the report area shows an info bar instead of data.

### Reading data

#### `readTable({ maxRows?, offset?, table? })` → `{ columns, rows, total, shown, offset, hasMore }`
Read actual grid data with pagination. Each row is `{ columnName: value }`.

| Option | Default | Description |
|--------|---------|-------------|
| `maxRows` | 20 | Max rows to return per call |
| `offset` | 0 | Skip first N rows |
| `table` | — | Grid name from `tables[]` (for multi-grid forms) |

**Picture columns.** Cells that render an icon (status/stage marks, the "ЭДО" mark, the attached-files paperclip) read as `'pic:<N>'` (`N` = icon frame/state) when shown, `''` when absent — so presence is truthy and icons differ by index. Icon-only columns (no header text) still appear, named by their tooltip or `'(picture)'`. These values are read-only — filter/select rows by a text column, not by `'pic:N'`.
```js
if (t.rows[0]['Присоединенные файлы']) { /* has an attached file */ }
t.rows[0]['ЭДО'] === 'pic:1';   // connected to 1С-ЭДО ('pic:0' = not)
```

Special row fields:
- `_kind: 'group'` — hierarchical group row
- `_kind: 'parent'` — parent row in hierarchy
- `_tree: 'expanded'|'collapsed'` — tree node state
- `_level: N` — nesting depth in tree view
- `_selected: true` — row is selected (highlighted). Use with `clickElement({ modifier: 'ctrl'|'shift' })` to verify multi-selection
- `hierarchical: true` — list has groups (on result object)
- `viewMode: 'tree'` — tree view active (on result object)

Row state — in object lists, decoded from the row's state icon (no need to add a column to the list):
- `_deleted: true|false` — marked for deletion (catalogs, documents, tasks, business processes, charts of accounts/calculation types)
- `_posted: true|false` — documents
- `_predefined: true|false` — catalogs, charts of accounts/calculation types
- `_completed: true|false` — tasks
- `_started`, `_finished` — business processes
- `_rowPic: '<icon>:<N>'` — raw icon id, for diagnostics

```js
const t = await readTable();
const doc = t.rows.find(r => r['Номер'] === 'ТД00-000005');
if (doc._deleted === true) { /* marked for deletion */ }
```

**A missing state field means "unknown", never `false`** — the property may not apply (documents have no `_predefined`), or the icon may be unrecognised. So `if (!row._deleted)` is unsafe: it reads "unknown" as "not deleted". Compare explicitly (`=== true` / `=== false`) and treat `undefined` as a third outcome. Rows outside object lists (form tabular sections, value lists) have no state fields at all. If `_rowPic` is present but the booleans aren't, report its value — that icon needs decoding support.

**`total` is misleading for long lists.** 1С virtualizes both dynamic lists and form tabular sections — the DOM holds only a window of visible rows. `total` / `shown` count what's *loaded right now*, not the size of the underlying collection. Use **`hasMore`** to know if there's more data outside the window:

```js
const t = await readTable();
// t.hasMore = { above: false, below: true }   ← form tabular section, scrollbar visible
// t.hasMore = { below: true }                 ← dynamic list (catalog/journal/register)
// t.hasMore = { below: false }                ← everything visible / end of list reached
```

- `hasMore.below` — always present. `true` ⇒ scrolling down (PageDown / `clickElement` with `scroll:true`) will reveal more rows.
- `hasMore.above` — usually present too. Detected via the dynamic-list page-turn buttons (#vertButtonScroll) or the tabular-section scrollbar. Absent only for rare grids that have neither widget — treat absence as unknown.

```js
const t = await readTable({ maxRows: 50 });
console.log('Columns:', t.columns);
console.log('Loaded:', t.shown, 'rows; more below:', t.hasMore.below);
// Pagination:
const page2 = await readTable({ maxRows: 50, offset: 50 });
```

#### `readSpreadsheet()` → `{ title?, headers?, data?, totals?, rows?, total }`
Read report output (SpreadsheetDocument) after clicking "Сформировать".

Returns structured data when header row is detected:
```js
await clickElement('Сформировать');
await wait(5);
const report = await readSpreadsheet();
// { title: "Остатки товаров", headers: ["Номенклатура", "Склад", "Количество"],
//   data: [{ "Номенклатура": "Бумага", "Склад": "Основной", "Количество": "150" }, ...],
//   totals: { "Количество": "1250" }, total: 42 }
```

Falls back to `{ rows: string[][], total }` when headers can't be detected.

#### `getSections()` → `{ activeSection, sections, commands }`
Read section panel and commands without navigating.

#### `getCommands()` → `string[]`
Commands of the current section.

#### `getPageState()` → `{ activeSection, activeTab, sections, tabs }`
Sections + all open tabs.

### Actions

**Return shape convention.** All action functions return a **flat form state** (same shape as `getFormState()`) with action-specific extras: `clicked`, `focused`, `selected`, `filled`, `notFilled`, `closed`, `opened`, `navigated`, `deleted`, `filtered`, `unfiltered`. Errors always sit at the top level under `.errors` (when present) — the exec-wrapper automatically throws on `.errors.modal` / `.errors.balloon`.

#### `clickElement(text, { dblclick?, table?, expand?, modifier?, scroll? })` → form state
Click button, hyperlink, tab, navigation panel link, or grid row (fuzzy match).

**Disabled controls throw.** `clickElement`, `fillFields`, and `selectValue` throw `"X" is disabled` on an unavailable control instead of reporting a fake success — check `getFormState().buttons[].disabled` / `fields[].disabled` first.

- `table` — scope button search to a specific grid's command panel (by name from `tables[]`):
  ```js
  await clickElement('Добавить', { table: 'Исходящие' }); // clicks "Добавить" near "Исходящие" grid
  ```
- Single click selects a row in a list. **Double-click opens** the item:
  ```js
  await clickElement('0000-000227', { dblclick: true }); // opens document
  ```
- Returns `submenu[]` when a menu opens — click again with item name:
  ```js
  const r = await clickElement('Ещё');
  // r.submenu = ['Расширенный поиск', 'Настройки', ...]
  await clickElement('Расширенный поиск');
  ```
- **Tree nodes**: default click = **select** (highlight row). Use `{ expand: true }` to **expand/collapse**:
  ```js
  await clickElement('ИСУ ФХД');                      // select row
  await clickElement('ИСУ ФХД', { expand: true });    // expand/collapse
  ```
- **Focus a field** (last resort, when no `table` given): if `text` matches no clickable control but matches a form field's name/label, clicks the input to focus it **without changing its value**. Returns `focused: { field, id, ok }` (`ok: false` if the field couldn't take focus). Use it to drive focus-dependent keys:
  ```js
  await clickElement('Контрагент');          // focus the reference field
  await getPage().keyboard.press('F4');      // open its selection form
  ```
- **Multi-select rows** with `modifier: 'ctrl'` (add to selection) or `modifier: 'shift'` (select range):
  ```js
  await clickElement('Номенклатура 1');                          // select first row
  await clickElement('Номенклатура 2', { modifier: 'ctrl' });   // add to selection
  await clickElement('Номенклатура 5', { modifier: 'shift' });  // select range 2..5
  // Verify selection:
  const t = await readTable();
  t.rows.filter(r => r._selected);  // rows with _selected: true
  ```
- **Cell click by (row, column)** — first argument as `{ row, column }`. Routes: spreadsheet on form → spreadsheet drill-down; otherwise → grid cell. Pass `table: 'GridName'` to force a specific grid when both are present.

  Spreadsheet report drill-down:
  ```js
  const report = await readSpreadsheet();
  // report.data[0] = { 'К1': 'Материалы строительные', 'К6': '150 000', ... }
  await clickElement({ row: 0, column: 'К6' }, { dblclick: true });                      // by index
  await clickElement({ row: { 'К1': 'Материалы' }, column: 'К6' }, { dblclick: true });  // by filter
  await clickElement({ row: 'totals', column: 'К6' }, { dblclick: true });               // totals row
  await clickElement('150 000', { dblclick: true });                                     // fallback: by text
  ```

  Form grid cell (catalog list, journal, table part). Off-viewport columns auto-scroll horizontally (works around frozen columns). Use `scroll: true | number` for filter-based rows outside the current DOM window:
  ```js
  await clickElement({ row: 0, column: 'Количество' }, { table: 'Товары', dblclick: true });
  await clickElement({ row: { 'Номенклатура': 'Бумага' }, column: 'Цена' }, { table: 'Товары' });
  await clickElement({ row: { 'Номер': '0000-000601' }, column: 'Сумма' },
                     { table: 'Реализации', scroll: true });  // PageDown loop, max 50
  ```

  Gotchas:
  - `row: <number>` is the index in the **current DOM window**, not absolute — 1С virtualizes long lists. `row: 0` is the topmost loaded row after any prior scroll. For arbitrary rows in a long list use `row: { col: val }` + `scroll: true`.
  - `scroll: true` walks **down only** (PageDown). For going up first press `Home` via `getPage().keyboard` or narrow with `filterList`.
  - First matching row wins on duplicate filter matches — refine the filter to disambiguate.

#### `fillFields({ name: value })` → form state with `filled`
Fill form fields by label (fuzzy match). Auto-detects field type.

| Value | Field type | Method |
|-------|-----------|--------|
| `'Конфетпром'` | Reference | Clipboard paste + typeahead |
| `'5000'` | Plain text | Clipboard paste |
| `'true'` / `'да'` | Checkbox | Toggle |
| `'Оплата поставщику'` | Radio | Fuzzy label match |
| `''` / `null` | Any (except checkbox/radio) | Clear via Shift+F4 |

**DCS report filters**: use human-readable label names. Checkbox is auto-enabled:
```js
await fillFields({
  'Склад': 'Склад бытовой техники',   // auto-enables "Склад" checkbox + fills value
  'Номенклатура': 'Вентилятор'          // same: enables checkbox + fills
});
```

Returns form state with `filled: [{ field, ok: true, value, method }]` (method: `clear`|`toggle`|`radio`|`paste`|`dropdown`|`form`|`typeahead`). **Throws on any per-field failure** with a detailed message listing problematic fields and available options — if the call returned, all fields were filled, no per-item check needed.

#### `selectValue(field, search, opts?)` → form state with `selected`
Select a value from reference field via dropdown or selection form. More reliable than `fillFields` for reference fields that need exact selection from a catalog. Pass empty `search` (`''` or `null`) to clear the field (Shift+F4).

`search` — string for simple search, or `{ field: value }` object for per-field advanced search:
```js
await selectValue('Организация', 'Конфетпром');
// result.selected = { field: 'Организация', search: 'Конфетпром', method: 'dropdown'|'form' }

// Per-field search (disambiguate by multiple columns):
await selectValue('Документ', { 'Номер': '0000-000601', 'Дата': '29.12.2016' }, { type: 'Реализация (акт' });
```

For **composite-type fields** (accepting multiple types), specify `type` to first select the type, then the value:
```js
await selectValue('Документ', '0000-000601', { type: 'Реализация (акт' });
// Clears field → opens type dialog → picks type via Ctrl+F → picks value from selection form
// result.selected = { field: 'Документ', search: '0000-000601', type: 'Реализация (акт', method: 'form' }
```

Also supports DCS labels — auto-enables the paired checkbox.

**Multi-select** — pass an **array** to select several values at once; the field is set to exactly
that set (replace). Returns `selected: { field, values, notSelected? }` — `values` are the ones
actually selected; any value the field doesn't offer goes to `notSelected: [{ value, reason }]`
(the call doesn't throw). Elements take the same forms as `search` (string, or `{ col: value }`).
```js
await selectValue('Наименование компании', ['Альфа ООО', 'Бета АО']);
// selected: { field: 'Наименование компании', values: ['Альфа ООО', 'Бета АО'] }
```

#### `fillTableRow(fields, opts)` → form state with `filled` (+ optional `notFilled`)
Fill table row cells via Tab navigation. Value is a plain string, `{ value, type }` for composite-type cells, or `''`/`null` to clear (Shift+F4).

Returns form state with `filled: [{ field, ok, ...}]`. Items are `{ field, ok: true, method, value }` on success (method: `direct`|`paste`|`dropdown`|`form`|`type-direct`|`skip`|`clear`|`toggle`) or `{ field, ok: false, error, message }` on per-field failure. Unmatched fields → `notFilled: [...]`.

**Unlike `fillFields`, `fillTableRow` does NOT throw on per-field failures** — errors appear as `ok: false` items in `filled[]` so the caller can react selectively (e.g. retry one cell while the rest of the row stays filled). Check via `r.filled.filter(f => !f.ok)`. Error codes: `composite_type`/`type_required`/`type_dialog_failed` (retry with `{value, type}`); `column_not_found` (check column name via `readTable`); `no_selection_form`/`no_selection_after_type` (retry or fall back to `selectValue`); `not_found`/`no_match`/`ambiguous` (refine search text); `still_open` (picked a group — pick a leaf row). Soft validation errors from 1C (`balloon`, `modal`) still throw via the exec-wrapper.

| Option | Description |
|--------|-------------|
| `tab` | Switch to tab before filling |
| `add` | Add new row before filling |
| `row` | Edit existing row: 0-based index, **or** a `{ col: value }` filter (one or more columns) to locate the row by its cell values |
| `scroll` | With a `row` filter — scan beyond the current DOM window (`true` = up to 50 PageDowns, number = limit) |
| `table` | Grid name from `tables[]` (for multi-grid forms) |

```js
// Add new row:
await fillTableRow(
  { 'Номенклатура': 'Бумага', 'Количество': '10', 'Цена': '100' },
  { tab: 'Товары', add: true }
);
// Edit existing row by index:
await fillTableRow(
  { 'Количество': '20' },
  { tab: 'Товары', row: 0 }
);
// Edit existing row located by cell values (одна или несколько колонок):
await fillTableRow({ 'Цена': '120' }, { table: 'Товары', row: { 'Номенклатура': 'Бумага' } });
await fillTableRow({ 'Сумма': '500' }, { row: { 'Номер': '0000-000601', 'Дата': '29.12.2016' }, scroll: true });
// Multi-grid form — add row to specific table:
await fillTableRow(
  { 'Объект': 'БДДС' },
  { table: 'Исходящие', add: true }
);
// Composite-type cell (e.g. SubConto accepting multiple types):
await fillTableRow(
  { 'СубконтоКт1': { value: 'Голованов', type: 'Физическое лицо' } },
  { tab: 'Проводки' }
);
```

- Tab-based sequential navigation — field order set by 1C form config
- Fuzzy cell match: "Количество" matches "ТоварыКоличество"
- Reference cells auto-detected by autocomplete popup

#### `deleteTableRow(row, { tab?, table? })` → form state
Delete row by 0-based index. `table` targets a specific grid on multi-grid forms.

#### `closeForm({ save? })` → form state with `closed`
Close the current form via Escape. Returns form state with `closed: true/false` indicating whether the form actually closed.

| Argument | Behavior |
|----------|----------|
| `{ save: false }` | Auto-clicks "Нет" on confirmation |
| `{ save: true }` | Auto-clicks "Да" on confirmation |
| `{}` (omitted) | Returns `confirmation` field if dialog appears |

**`closed`** — `true` if the form was closed (form number changed), `false` if it stayed open (e.g. Escape was ignored). Always check this to confirm the form actually closed. After closing, check `formCount` to see how many forms remain.

Preferred over `clickElement('×')` — close buttons on tabs are ambiguous.

#### `filterList(text, opts?)` → form state
Filter list. Simple mode searches all columns, advanced mode targets a specific field.

```js
await filterList('КП00-000018');                          // simple — all columns
await filterList('Мишка', { field: 'Наименование' });     // advanced — specific column
await filterList('Мишка', { field: 'Наименование', exact: true }); // exact match
```

Works on hierarchical catalogs too (flattens the view).

#### `unfilterList({ field? })` → form state
Clear filters. Without arguments clears all, with `{ field }` clears specific badge.

### Utility

#### `screenshot()` → PNG Buffer
#### `wait(seconds)` → form state
#### `getPage()` → Playwright Page (raw, for advanced scripting)
#### `startRecording(path, opts?)` / `stopRecording()` → MP4 video recording (`{ force: true }` to restart if already recording)
#### `showCaption(text, opts?)` / `hideCaption()` → text overlay on page
#### `showTitleSlide(text, opts?)` / `hideTitleSlide()` → full-screen title card (intro/outro)
#### `isRecording()` → boolean
#### `setHighlight(on)` / `isHighlightMode()` → auto-highlight mode for video
#### `highlight(text)` / `unhighlight()` → manual element highlighting (error lists available elements)
#### `addNarration(videoPath, opts?)` → narrated MP4 with TTS voiceover
#### `getCaptions()` → caption timestamps from last recording

See [recording.md](recording.md) for setup (ffmpeg), highlight mode, TTS narration, API details, and examples.
If `.v8-project.json` has `ffmpegPath`, pass it to `startRecording({ ffmpegPath })`.
If `.v8-project.json` has `tts` config, pass it to `addNarration()` (provider, voice, apiKey).

## Common patterns

### Create and save a document

```js
await navigateSection('Продажи');
await openCommand('Заказы клиентов');
await clickElement('Создать');
await fillFields({ 'Организация': 'Конфетпром', 'Контрагент': 'Альфа' });
await fillTableRow({ 'Номенклатура': 'Бумага', 'Количество': '10' }, { tab: 'Товары', add: true });
await clickElement('Провести и закрыть');
```

### Open item from list

```js
await clickElement('КП00-000227', { dblclick: true });
// Always use { dblclick: true } — single click only selects the row
```

### Work with hierarchical lists

```js
await filterList('Конфетпром');                               // flatten + search
await clickElement('Конфетпром ООО', { dblclick: true });     // open
await closeForm();
await unfilterList();                                          // restore hierarchy
```

### Generate and read a report

```js
// Fill report filters using readable labels
await fillFields({ 'Склад': 'Основной склад' });
await clickElement('Сформировать');
await wait(5);
const report = await readSpreadsheet();
console.log('Title:', report.title);
console.log('Data rows:', report.data?.length);
```

### Drill-down report cells

```js
// Generate report
await clickElement('Сформировать');
await wait(5);
const report = await readSpreadsheet();

// Double-click cell to open drill-down (uses coordinates from readSpreadsheet)
await clickElement({ row: 0, column: 'К6' }, { dblclick: true });
// Modal dialog "Выбор поля" opens
await clickElement('Регистратор');
await clickElement('Выбрать');
await wait(10);
const drilldown = await readSpreadsheet();
```

### Work with multi-grid forms

Some forms have multiple grids (e.g. "Входящие" and "Исходящие" tables on a single form). Without `table`, buttons like "Добавить" hit the first match and `readTable` reads the first grid — which may not be the one you need.

**Step 1 — discover tables** via `getFormState()`:
```js
const form = await getFormState();
// form.tables = [
//   { name: "ДеревоБизнесПроцессов", columns: ["Полный код", "Бизнес-процесс"], rowCount: 21 },
//   { name: "Входящие", label: "Входящие", columns: ["Объект", "Бизнес-процесс источник", ...], rowCount: 1 },
//   { name: "Исходящие", label: "Исходящие", columns: ["Объект", "Бизнес-процесс приемник", ...], rowCount: 1 }
// ]
```

**Step 2 — use `table` name** in any grid operation:
```js
// Read specific table
const t = await readTable({ table: 'Исходящие' });

// Add row — fillTableRow with add:true already clicks the right "Добавить" button
await fillTableRow({ 'Объект': 'БДДС' }, { table: 'Исходящие', add: true });

// Or click buttons separately
await clickElement('Добавить', { table: 'Входящие' });

// Delete from specific table
await deleteTableRow(0, { table: 'Исходящие' });
```

Table matching accepts both technical name (`tables[].name`) and visual label (`tables[].label`). Label is the group title shown on screen — useful when working from screenshots. Name match takes priority over label match.

### Keyboard shortcuts

```js
const page = await getPage();
await page.keyboard.press('F8');  // example: create new item in focused reference field
```

| Key | Context | Action |
|-----|---------|--------|
| `F8` | Reference field focused | Create new catalog item |
| `Shift+F4` | Any input field focused | Clear field value (auto via `''`/`null` in fillFields/selectValue/fillTableRow) |
| `F4` | Reference field focused | Open selection form |
| `Alt+F` | List/table form | Open advanced search dialog |

### Closing forms — which method to use

| Goal | Method |
|------|--------|
| Post & close document | `clickElement('Провести и закрыть')` |
| Save & close catalog | `clickElement('Записать и закрыть')` |
| Close without saving | `closeForm({ save: false })` |
| Close and save | `closeForm({ save: true })` |
| Close (manual confirm) | `closeForm()` — returns `confirmation` if dialog appears |

## Exec response format

```json
{ "ok": true, "output": "...console.log output...", "elapsed": 3.2 }
```

On error (auto-screenshot taken):
```json
{ "ok": false, "error": "Element not found", "output": "...", "screenshot": "error-shot.png", "elapsed": 1.5 }
```

## Avoiding loops

- **Max 2 attempts per operation.** If an action fails twice with the same approach — stop and report to the user
- **Not found = not found.** If `filterList` returns 0 rows or `readTable` is empty after filtering — the item likely doesn't exist in this database. Don't retry the same search 5 times with slight variations
- **Try a different approach, not the same one.** Couldn't find via section navigation? Try `navigateLink`. Couldn't find via simple search? Try advanced search with a specific field. But don't repeat the same method
- **Report partial results.** If you found the list but not the specific item — say so. Show what IS available instead of silently retrying

## Important notes

- **Headed mode** — 1C requires visible browser, no headless
- **Startup time** — 1C loads 30-60s on initial connect (built into `start`)
- **Fuzzy matching** — all name lookups: exact > startsWith > includes
- **Clipboard paste** — all text fields filled via Ctrl+V (triggers 1C events properly). The OS clipboard is automatically saved before each action and restored after, so a local user's clipboard survives a test run. Opt out with `--no-preserve-clipboard` (any command), `WEB_TEST_PRESERVE_CLIPBOARD=0` env, or `preserveClipboard: false` in `webtest.config.mjs`
- **Cyrillic in bash** — use `cat <<'SCRIPT' | node $RUN exec -` to avoid escaping issues
- **Non-breaking spaces** — 1C uses `\u00a0` instead of regular spaces. All matching is normalized internally
- **Section panel display** — `navigateSection()` works with any panel position (side, top) but requires "Picture and text" or "Text" display mode. Icon-only mode is not supported — API cannot read section names from icons alone

## Regression suites

When the user asks to cover a 1C solution with automated regression — multi-file test suites with assertions, hooks, tags, retries, Allure/JUnit reports, multi-user process tests — switch to the `test` mode. See [regress.md](regress.md) for authoring discipline, recon flow (metadata + live walkthrough via `exec`), per-application folder layout, ready-to-paste templates, and failure triage. Default to ad-hoc `run`/`exec` for single-script automation — `test` is the specialised mode for project-wide coverage.
