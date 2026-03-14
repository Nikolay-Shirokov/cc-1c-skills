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
RUN=".claude/skills/web-test/scripts/run.mjs"

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
cd .claude/skills/web-test/scripts && npm install
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
# 1. Start session (run_in_background=true, prints JSON when ready)
node $RUN start <url>

# 2. Execute scripts against running session
cat <<'SCRIPT' | node $RUN exec -
const form = await getFormState();
console.log(JSON.stringify(form, null, 2));
SCRIPT

# 2b. Execute without video recording (for debugging/testing)
cat script.js | node $RUN exec - --no-record

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

#### `getFormState()` → `{ fields, buttons, tabs, table, tables, filters, reportSettings? }`
Returns current form structure. This is the primary way to understand what's on screen.

**fields** — each field has: `name`, `value`, `label?`, `actions?` (select, clear, open), `required?` (true for unfilled mandatory fields)

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

### Reading data

#### `readTable({ maxRows?, offset?, table? })` → `{ columns, rows, total, shown, offset }`
Read actual grid data with pagination. Each row is `{ columnName: value }`.

| Option | Default | Description |
|--------|---------|-------------|
| `maxRows` | 20 | Max rows to return per call |
| `offset` | 0 | Skip first N rows |
| `table` | — | Grid name from `tables[]` (for multi-grid forms) |

Special row fields:
- `_kind: 'group'` — hierarchical group row
- `_kind: 'parent'` — parent row in hierarchy
- `_tree: 'expanded'|'collapsed'` — tree node state
- `_level: N` — nesting depth in tree view
- `hierarchical: true` — list has groups (on result object)
- `viewMode: 'tree'` — tree view active (on result object)

```js
const t = await readTable({ maxRows: 50 });
console.log('Columns:', t.columns);
console.log('Rows:', t.rows.length, 'of', t.total);
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

#### `clickElement(text, { dblclick?, table?, toggle? })` → form state
Click button, hyperlink, tab, or grid row (fuzzy match).

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
- **Tree nodes**: default click = **select** (highlight row). Use `{ toggle: true }` to **expand/collapse**:
  ```js
  await clickElement('ИСУ ФХД');                     // select row
  await clickElement('ИСУ ФХД', { toggle: true });   // expand/collapse
  ```

#### `fillFields({ name: value })` → `{ filled, form }`
Fill form fields by label (fuzzy match). Auto-detects field type.

| Value | Field type | Method |
|-------|-----------|--------|
| `'Конфетпром'` | Reference | Clipboard paste + typeahead |
| `'5000'` | Plain text | Clipboard paste |
| `'true'` / `'да'` | Checkbox | Toggle |
| `'Оплата поставщику'` | Radio | Fuzzy label match |

**DCS report filters**: use human-readable label names. Checkbox is auto-enabled:
```js
await fillFields({
  'Склад': 'Склад бытовой техники',   // auto-enables "Склад" checkbox + fills value
  'Номенклатура': 'Вентилятор'          // same: enables checkbox + fills
});
```

Returns `{ filled: [{ field, ok, value, method }], form: {...} }`.
Method is one of: `'toggle'` | `'radio'` | `'paste'` | `'dropdown'` | `'form'` | `'typeahead'`

#### `selectValue(field, search, opts?)` → form state with `selected`
Select a value from reference field via dropdown or selection form. More reliable than `fillFields` for reference fields that need exact selection from a catalog.

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

#### `fillTableRow(fields, opts)` → form state
Fill table row cells via Tab navigation. Value is a plain string or `{ value, type }` for composite-type cells.

| Option | Description |
|--------|-------------|
| `tab` | Switch to tab before filling |
| `add` | Add new row before filling |
| `row` | Edit existing row by 0-based index |
| `table` | Grid name from `tables[]` (for multi-grid forms) |

```js
// Add new row:
await fillTableRow(
  { 'Номенклатура': 'Бумага', 'Количество': '10', 'Цена': '100' },
  { tab: 'Товары', add: true }
);
// Edit existing row:
await fillTableRow(
  { 'Количество': '20' },
  { tab: 'Товары', row: 0 }
);
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

#### `closeForm({ save? })` → form state
Close the current form via Escape.

| Argument | Behavior |
|----------|----------|
| `{ save: false }` | Auto-clicks "Нет" on confirmation |
| `{ save: true }` | Auto-clicks "Да" on confirmation |
| `{}` (omitted) | Returns `confirmation` field if dialog appears |

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
#### `startRecording(path, opts?)` / `stopRecording()` → MP4 video recording
#### `showCaption(text, opts?)` / `hideCaption()` → text overlay on page
#### `showTitleSlide(text, opts?)` / `hideTitleSlide()` → full-screen title card (intro/outro)
#### `isRecording()` → boolean
#### `setHighlight(on)` / `isHighlightMode()` → auto-highlight mode for video
#### `highlight(text)` / `unhighlight()` → manual element highlighting
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

### Keyboard shortcuts (via `page.keyboard.press`)

| Key | Context | Action |
|-----|---------|--------|
| `F8` | Reference field focused | Create new catalog item |
| `Shift+F4` | Reference field focused | Clear field value |
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
- **Clipboard paste** — all text fields filled via Ctrl+V (triggers 1C events properly)
- **Cyrillic in bash** — use `cat <<'SCRIPT' | node $RUN exec -` to avoid escaping issues
- **Non-breaking spaces** — 1C uses `\u00a0` instead of regular spaces. All matching is normalized internally
- **Section panel display** — `navigateSection()` works with any panel position (side, top) but requires "Picture and text" or "Text" display mode. Icon-only mode is not supported — API cannot read section names from icons alone
