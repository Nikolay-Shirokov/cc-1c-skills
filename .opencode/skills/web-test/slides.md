# Slides in recordings

Presentation inserts for video instructions: a slide is built step by step under the narration — each
phrase reveals or highlights its part. Title and closing cards are in [recording.md](recording.md); this
file covers the rest.

```js
const TTS = { provider: 'edge', voice: 'ru-RU-DmitryNeural' };
const S = await loadSlides('docs/video/overview-slides.mjs');   // specs live in a module (path from the project root)

await prepareSlides(S.default, TTS);   // before startRecording: validates every spec, synthesizes every phrase
await startRecording('docs/video/output/overview.mp4');
await showSlide(S.TITLE, TTS);
await showSlide(S.VALUE, TTS);          // the next slide crossfades over the previous one
await hideSlide();                      // back to the 1C page
// ... steps in 1C ...
```

A spoken step becomes a caption, so `addNarration` voices it exactly where its change happens. A step
lasts as long as its phrase really sounds. Write `speech` as it is spoken: `'один эс'`, `'опен эй ай'` —
the screen text keeps the written form (`1С`, `OpenAI`). Keep the specs in a module: the recording script, `play` and
`preview` share it.

Paths in specs (`src`, `image`, `qr`, `file`) and in `loadSlides`, `startRecording`, `addNarration`'s
`outputPath` are from the project root (or absolute). Slides are drawn at 1920×1080 and scaled to the
browser window; the video has the window's size.

## Templates

Pick by the meaning of the slide. `cards`, `columns`, `comparison`, `process`, `radial`, `summary` take a
slide `title`; `image` has none (the picture carries its own). All take `theme`, `background`, `outro`
(seconds held at the end), `music` (background music while the slide is up — [recording.md](recording.md)). Indexes (`show: 0`, `current`, `row`) count from 0.

| Layout | When | Fields | Steps (`steps: [{ ..., speech }]`) | Limits |
|---|---|---|---|---|
| `title` | opening card | see recording.md | one, built in (`speech`) | — |
| `agenda` | contents; section break | `items`, `current` (index of the lit section), `title`, `speech` | one, built in | 2–12; > 6 → two columns |
| `statement` | one idea, big; a key number | `value` (the big number on top), `text` (the line below it), `kicker` (small caps above), `caption` (small text at the bottom), `speech` | one, built in | — |
| `cards` | several parallel points | `cards: [{ title, text, items }]`, `lead: { title, text }`, `columns` (auto), `focus: false` | `show: i \| [i, j] \| 'all' \| 'lead'` | 1–12 |
| `columns` | groups side by side | `columns: [{ title, items }]` | `show: i \| 'all'` | 2–5 |
| `comparison` | before/after, A vs B | `left`, `right`: `{ title, items }` (rows aligned) | `show: 'left' \| 'right' \| 'all'`, `row: i` (lights a pair and its arrow); both in one step: `{ show: 'right', row: 0 }` | 1–8 rows |
| `process` | stages in order | `stages: [{ title, items, role, caption }]` (`role` — a person under the stage, `caption` — a line under the role), `wrap` | `show: i \| 'all'` | 2–10; > 5 → two rows: `wrap: 'snake'` (default) \| `'bend'` \| `'none'` |
| `radial` | a centre and who/what around it | `center: { title, items }`, `cards: [{ title, items }]` | `show: 'center' \| i \| 'all'` | 3–6 cards |
| `image` | a picture, screenshot or ready presentation slide | `src` (PNG/JPEG), `maxZoom` (1.8), `style` | `region: [x, y, w, h]` — camera on a part; `callout: { at: [x, y], label }` — numbered mark; neither — whole picture | — |
| `summary` | takeaways + what's next | `items`, `next`, `title` | `show: i \| 'next' \| 'all'` | 1–8 |
| `closing` | end card | see recording.md | one, built in | — |

- `cards`/`columns`/`process`/`radial` focus the item a step shows and dim the ones before; the slide ends with everything lit.
- Keys like `'center'`, `'all'`, `'next'` stand on their own (`show: 'center'`); only `cards` (`'lead'`, `'all'`) and `summary` (`'next'`, `'all'`) take them inside an array.
- `image` coordinates are pixels of the picture file. Do not zoom a small screenshot past ~1.8×: it blurs.
- A spec past a limit throws before anything is shown, with advice (`radial: 3–6 cards supported, got 8 — split the slide or use cards`). Within the limits long text is shrunk to fit.

```js
export const VALUE = {
  layout: 'radial', title: 'Кому помогает учёт заказов',
  center: { title: 'Заказ', items: ['Состав', 'Сроки', 'Оплата'] },
  cards: [{ title: 'Менеджер', items: ['…'] }, { title: 'Склад', items: ['…'] }, { title: 'Бухгалтерия', items: ['…'] }],
  steps: [
    { show: 'center', speech: 'В центре — заказ клиента.' },
    { show: 0, speech: 'Менеджер видит статус каждого заказа.' },
    { show: 1, speech: 'Склад заранее знает, что отгружать.' },
    { show: 2, speech: 'Бухгалтерия сверяет оплату.' },
  ],
};
export const SCHEME = {
  layout: 'image', src: 'docs/video/slides/scheme.png',
  steps: [
    { speech: 'Заказ проходит три этапа:' },
    { region: [120, 80, 420, 260], speech: 'оформление,' },
    { callout: { at: [760, 300], label: 'Согласование' }, speech: 'согласование и отгрузку.' },
  ],
};
```

## A page of your own

When the meaning is in a layout no template has, give the slide your own 1920×1080 page and protocol steps:

```js
await showSlide({
  html: '<div class="lane l1">…</div><div class="lane l2">…</div><div class="total">…</div>',
  css: '.lane{position:absolute;top:200px;width:560px;--stagger:.1s} .l1{left:100px} .l2{left:700px}',
  background: '#12161c',
  steps: [
    { show: '.lane', speech: '…' },                         // reveal (cascade by --stagger)
    { dim: '.lane:not(.l2)', focus: '.l2', speech: '…' },   // fade the rest, emphasize one
    { show: '.total', camera: '.total', speech: '…' },      // reveal and zoom the camera on it
    { clear: true, camera: null, hold: 1.5 },               // everything lit, camera back, hold 1.5 s
  ],
}, TTS);
```

Step actions (CSS selectors inside the page): `show`, `hide`, `focus` (`null` — none), `dim`, `undim`,
`clear` (drop focus and dim), `camera` (selector, `[x, y, w, h]` or `null`), `spot` (darken around the
camera box), `hold` (seconds, for a step without speech). Elements to `show` start hidden. The motion is CSS
on the state classes `.ws-pending` / `.on`, `.ws-focus`, `.ws-dim`; tune it with `--dx`, `--dy`,
`--from-scale` (where an element comes from), `--stagger`, `--focus-stagger`, `--pulse`. A `ws-fit` box
shrinks its children until they fit. Lines from a centre to items: `<svg class="ws-links" data-from=".hub"
data-round><path data-to=".item1"/></svg>`. The page lives in a shadow root: its CSS touches nothing else.
`file: 'path.html'` instead of `html` reads the page from a file. Mark a deliberate element `ws-nolint` (a
speech bubble that repeats the phrase): the checks skip it. Drawn shapes may cross the frame edge; text may not.
3D, Lottie, an animation from data, a video clip — a page with a script: [slide-scripts.md](slide-scripts.md).

## Theme

Four base colours, the rest is derived (header shades and quiet tints from `primary`):
`primary` (dark: title/closing ground, headers), `accent` (what is being said now: the focused card's rule,
link and arrow, the lit section, the current takeaway; title rules, numbers, callouts), `ground` (light
slide ground), `ink` (text); optional `line` (structure: links, arrows, card rules, list markers; default a
slate shade of `primary`), `mark` (callouts/spot, default accent), `onAccent` (text on accent), `font`.
Default: `#16213e` / `#f0a202` / `#f4f6fa` / `#1a1a2e`.

Layers, each overriding the previous: `.v8-project.json` → `"slides": { "theme": {...} }` (project brand) →
`setSlideTheme({...})` (scenario) → `showSlide(spec, { theme })` → `spec.theme`.

On a page of your own the theme is CSS variables: `var(--primary)`, `--accent`, `--ground`, `--ink`, `--line`,
`--muted` (secondary text), `--soft` (quiet tint), `--on-dark` (text on `primary`).

## Slide videos without 1C, preview

```bash
node $RUN preview docs/video/overview-slides.mjs [--out-dir=dir]   # a PNG per step + checks; no TTS, ~seconds
node $RUN play docs/video/overview-slides.mjs --out=docs/video/overview.mp4 [--no-narration]
```

The module (its path from the current directory; paths inside the specs — from the project root):
`export default [spec, ...]`, optional `export const tts = {...}` and `export const theme = {...}`.

- `preview` writes `<slide>-<step>.png` (both from 1; a template's extra last step is the final all-lit
  state) into `--out-dir`, by default `<module name>-preview/` next to the module. Steps run short (~1.6 s,
  no speech) and the picture is taken at the end of each: motion tied to steps and finished within ~1 s looks
  as in the video; motion driven by the clock does not.
- `play` records on a blank page, starting and ending on a slide; `--out` is the final narrated video,
  `<name>.captions.json` is written next to it (re-narrate later with `addNarration`). `--no-narration` —
  a silent video, no TTS calls.
- Both print JSON; `warnings` is always there (empty when the checks found nothing).

Run `preview` before recording over 1C: it catches layout problems and wrong `region`/`callout`
coordinates in a minute instead of a re-recording.

## Checks

Every step is checked; warnings go to the output (`exec`) or to `warnings` (`play`/`preview`):
text off the frame or not fitting its box, font under 22px, more than ~70 words on screen, a list over 6
items, a step over ~16 s of speech, screen text repeating the narration word for word, speech with Latin
words or abbreviations the voice may mispronounce (`1С`, `OpenAI`, `СКД`).

## How to present

- One idea per slide; a step per phrase; 3–6 steps per slide.
- On screen — key words; the details are in the narration. Text that is read and heard at once is understood worse.
- Up to ~70 words on screen and up to ~15 s per step: a longer phrase is better split into steps.
- A ready presentation slide (picture) — `image` with `region` on the parts in the order they are spoken, not a static picture under a long monologue.
- A long video — `agenda` at the start and `agenda` with `current` at section breaks; `summary` at the end.

## Former calls

`showTitleSlide(text, { subtitle, speech })` ≈ `showSlide({ layout: 'title', title: text, subtitle, speech }, { motion: false })`;
`showImage(path, { style, speech })` ≈ `showSlide({ layout: 'image', src: path, style, steps: [{ speech }] }, { motion: false })`;
`hideTitleSlide()` / `hideImage()` ≈ `hideSlide({ motion: false })`. The former calls keep their old look and
timing. When editing an existing script, leave them unless asked to change; add new slides with `showSlide`.
