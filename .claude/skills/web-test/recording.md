# Video Recording

Record browser automation sessions as MP4 video files. Uses CDP `Page.startScreencast` to capture JPEG frames and pipes them to ffmpeg for encoding.

## Prerequisites

**ffmpeg** must be installed. Choose один из вариантов:

### Вариант 1: в проект (рекомендуется)

Скачать essentials build с https://www.gyan.dev/ffmpeg/builds/, распаковать в `tools/ffmpeg/` проекта:

```
tools/ffmpeg/
├── bin/
│   ├── ffmpeg.exe      ← этот файл ищет startRecording()
│   ├── ffplay.exe
│   └── ffprobe.exe
└── ...
```

Код автоматически найдёт `tools/ffmpeg/bin/ffmpeg.exe` — ничего больше настраивать не нужно.

### Вариант 2: глобально (один раз на машину)

Скачать, распаковать в любой каталог (напр. `C:\tools\ffmpeg`), добавить `bin/` в системный PATH.
После этого ffmpeg доступен во всех проектах.

### Вариант 3: через .v8-project.json (общий путь)

Чтобы не копировать ffmpeg в каждый проект, указать путь в конфиге:

```json
{
  "ffmpegPath": "C:\\tools\\ffmpeg\\bin\\ffmpeg.exe"
}
```

Движок подхватит это поле сам (запись, озвучка, слайды).

### Порядок поиска ffmpeg

1. `opts.ffmpegPath` — явный путь в параметре
2. `ffmpegPath` из `.v8-project.json` (от корня проекта)
3. `FFMPEG_PATH` — переменная окружения
4. `ffmpeg` — в системном PATH
5. `tools/ffmpeg/bin/ffmpeg.exe` — относительно корня проекта

## API

### `startRecording(outputPath, opts?)`

Start recording the browser viewport to an MP4 file.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `outputPath` | string | required | Output .mp4 file path |
| `opts.fps` | number | 25 | Target framerate |
| `opts.quality` | number | 80 | JPEG quality (1-100) |
| `opts.ffmpegPath` | string | auto | Explicit path to ffmpeg binary |
| `opts.speechRate` | number | 70 | Ms per character for smart TTS wait. Increase for slower TTS providers (e.g. 85 for ElevenLabs) |

- `outputPath` is from the project root (or absolute); the output directory is created automatically
- The video has the browser window's size (a maximized window gives e.g. 1920×1042); slides are drawn at 1920×1080 and scaled to fit
- Throws if already recording or browser not connected
- Recording auto-stops when `disconnect()` is called

### `stopRecording()` → `{ file, duration, size, captions }`

Stop recording and finalize the MP4 file. Saves `.captions.json` next to the video if captions were collected.

| Return field | Type | Description |
|-------------|------|-------------|
| `file` | string | Absolute path to the MP4 file |
| `duration` | number | Recording duration in seconds |
| `size` | number | File size in bytes |
| `captions` | number | Number of captions collected during recording |

- Throws with ffmpeg's error message if encoding failed; recording is stopped either way

### `isRecording()` → boolean

Check if recording is active.

### `showCaption(text, opts?)`

Display a text overlay on the page (visible in recording). Calling again updates the text.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `text` | string | required | Caption text |
| `opts.position` | `'top'` \| `'bottom'` | `'bottom'` | Vertical position |
| `opts.fontSize` | number | 24 | Font size in px |
| `opts.background` | string | `'rgba(0,0,0,0.7)'` | Background color |
| `opts.color` | string | `'#fff'` | Text color |
| `opts.speech` | string \| false | - | TTS narration text. Omit = use displayed text, string = custom narration, false = skip narration. Write it as spoken: `'один эс'`, not `'1С'` (a warning names such words) |
| `opts.voice` | string | - | Per-caption voice override (provider-specific voice name/ID). Used by `addNarration` instead of the global voice |

When `text` is empty but `speech` is a string, the caption is still recorded for TTS (no visible overlay). Useful for narration-only captions (e.g. podcast mode).

The overlay uses `pointer-events: none` — does not interfere with clicking.

**Smart TTS wait** (during recording): `showCaption` automatically pauses for the speech duration — the phrase's real length when it is already in the TTS cache (synthesized ahead or recorded before; cache key: the `.v8-project.json` `tts` settings + `opts.voice`), otherwise an estimate (default ~70ms per character, min 2s; configurable via `startRecording({ speechRate })`). The next `wait()` call accounts for this — if the explicit pause is shorter than the TTS wait already done, no extra delay is added. If longer, only the remaining difference is waited. This means script authors don't need to calculate TTS timing manually.

### `hideCaption()`

Remove the caption overlay.

### Title and closing — `showSlide(spec, tts?)`

Almost every video opens with a title card and many end with a closing one. Both are animated slides:

```js
const TTS = { provider: 'edge', voice: 'ru-RU-DmitryNeural' };   // or the "tts" object of .v8-project.json
const TITLE = {
  layout: 'title', kicker: 'Видеоинструкция', title: 'Создание заказа\nклиента',
  subtitle: 'Демонстрация', image: 'docs/video/cover.png', speech: 'Создание заказа клиента.',
};
const CLOSING = {
  layout: 'closing', title: 'Спасибо за внимание', subtitle: 'Компания',
  contacts: ['site.ru', 'info@site.ru'], qr: 'docs/video/qr.png', speech: 'Спасибо за внимание!',
};

await prepareSlides([TITLE, CLOSING], TTS);  // before startRecording: checks the specs, synthesizes the phrases
await startRecording('recordings/order.mp4');
await showSlide(TITLE, TTS);                 // the video opens on the title, not on the 1C page
await hideSlide();                           // fades to the 1C page
// ... steps in 1C ...
await showSlide(CLOSING, TTS);
const video = await stopRecording();         // stop while the closing card is still on screen
await hideSlide();
```

| `title` field | | `closing` field | |
|---|---|---|---|
| `title` | required; `\n` — line break | `title` | required |
| `kicker` | small line above (series, product) | `subtitle` | accent line below |
| `subtitle` | line below the rule | `contacts` | array of lines |
| `image` | picture in a circle on the right | `image`, `qr` | picture on the right; QR image below the contacts |
| `speech` | narration | `speech` | narration |

Both take `voice` (per-slide voice override), `background` (CSS) and `outro` (seconds held after the phrase).

- `showSlide` returns when its narration is over; the slide stays until the next `showSlide` (crossfade) or `hideSlide()`.
- The slide lasts as long as its phrase really sounds. `prepareSlides` synthesizes the phrases ahead; without it `showSlide` synthesizes itself and the video stands still meanwhile (a warning says so).
- `{ motion: false }` in the options — a static slide, no animation.
- Colours: `.v8-project.json` → `"slides": { "theme": { "primary": "#16213e", "accent": "#f0a202" } }` or `setSlideTheme({...})` — see [slides.md](slides.md#theme).
- Checks run on every step; problems come to the exec output as `[web-test] showSlide(...) WARN ...` (text off the frame, too much text, screen text repeating the narration).
- `showTitleSlide` / `hideTitleSlide`, `showImage` / `hideImage` — the former static forms; they still work as before.

**A picture or a presentation slide** with camera focus and numbered callouts, other slide layouts
(agenda, statement, cards, columns, comparison, process, radial, summary), a page of your own, slide videos
without 1C (`run.mjs play` / `preview`) — **[slides.md](slides.md)**.

### `setHighlight(on)`

Enable or disable auto-highlight mode. When enabled, action functions (`navigateSection`, `openCommand`, `clickElement`, `selectValue`, `fillFields`) automatically highlight the target element for 500ms before performing the action.

| Parameter | Type | Description |
|-----------|------|-------------|
| `on` | boolean | `true` to enable, `false` to disable |

**How it works**: each action highlights the element → waits 500ms (viewer reads) → removes highlight → performs the action. This prevents the highlight overlay from interfering with modals, dropdowns, or focus changes caused by the action.

**Search priority**: form elements (buttons, links, fields, grid rows) are searched first. Sections and commands are used as fallback only if the element is not found in the current form. This avoids false matches (e.g., "ОК" matching section "Покупки" via substring).

### `isHighlightMode()` → boolean

Check if auto-highlight mode is active.

### `highlight(text)`

Manually highlight a UI element by name (fuzzy match). Places a semi-transparent blue overlay (`rgba(0,100,255,0.25)`) with a border on the element. The overlay tracks element position via `requestAnimationFrame`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `text` | string | Element name — button, link, field, group/panel, section, or command |

- Fuzzy match order: exact → startsWith → includes
- Search priority: popup items → commands → **form groups/panels** → form elements (buttons, fields) → sections
- Groups are matched by visible title or internal name (e.g., `highlight('Оргструктура')` finds the group panel)
- `pointer-events: none` — does not block clicks

### `unhighlight()`

Remove the highlight overlay.

## Example: Record a workflow with highlight, title slide, and captions

```js
const TTS = { provider: 'edge', voice: 'ru-RU-DmitryNeural' };
const TITLE = { layout: 'title', title: 'Создание заказа клиента', subtitle: 'Демонстрация',
  speech: 'Создание заказа клиента. Демонстрация.' };
await prepareSlides([TITLE], TTS);

await startRecording('recordings/create-order.mp4');

// Title slide with narration
await showSlide(TITLE, TTS);
await hideSlide();

// A presentation slide with focus on its parts, if needed — see slides.md

setHighlight(true); // enable auto-highlight for all actions

// Steps: action → caption (highlight is automatic)
await navigateSection('Продажи');
await showCaption('Шаг 1. Раздел «Продажи»');

await openCommand('Заказы клиентов');
await showCaption('Шаг 2. Заказы клиентов');

await clickElement('Создать');
await showCaption('Шаг 3. Новый заказ');

await fillFields({ 'Организация': 'Конфетпром', 'Контрагент': 'Альфа' });
await showCaption('Шаг 4. Заполняем шапку');

await hideCaption();
setHighlight(false);
const result = await stopRecording();
console.log(`Recorded ${result.duration}s, ${(result.size / 1024 / 1024).toFixed(1)} MB`);
```

**Caption timing**: do the action first, then show its caption. A narrated `showCaption` holds the script while its phrase sounds, so the next step starts only when the voice stops: caption-then-action would narrate a form that is not on screen yet. Actions wait for their result themselves, and the caption waits for its speech — no extra `wait()` needed.

**Highlight timing**: `setHighlight(true)` enables auto-mode — each action function highlights the target for 500ms, then removes the highlight before performing the action; the caption follows the action. No manual `highlight()`/`unhighlight()` calls needed. Enable after the title slide, disable before `stopRecording()`.

## TTS Narration

Add voiceover to recorded videos. Captions shown via `showCaption()` are automatically collected during recording and can be synthesized into speech.

### Prerequisites

- **ffmpeg** — same as for video recording (ffprobe must be next to ffmpeg)
- **node-edge-tts** — `npm install --prefix tools/tts node-edge-tts` (for Edge TTS provider, free, no API key). Also works if installed globally or at project level — the resolver tries multiple locations automatically
  - version 1.2.12 or newer — older ones get HTTP 403 from the service
- Phrases are cached (`<temp>/web-test-tts-cache`): `addNarration` reuses what `prepareSlides`/`showSlide` already synthesized and re-recordings do not synthesize again

### Configuration in `.v8-project.json`

```json
{
  "tts": {
    "provider": "edge",
    "voice": "ru-RU-DmitryNeural"
  }
}
```

For OpenAI-compatible provider:
```json
{
  "tts": {
    "provider": "openai",
    "apiKey": "sk-...",
    "model": "gpt-4o-mini-tts",
    "voice": "cedar",
    "instructions": "Говори по-русски без акцента"
  }
}
```
If the model supports `instructions` (e.g. `gpt-4o-mini-tts`), a short one softens the English accent in Russian speech but does not remove it — for Russian, Edge TTS sounds more native. Some OpenAI requests answer slowly (30–60 s): a request is dropped after 30 s and retried automatically.

For ElevenLabs:
```json
{
  "tts": {
    "provider": "elevenlabs",
    "apiKey": "sk_...",
    "voice": "JBFqnCBsd6RMkjVDRZzb"
  }
}
```
Note: `voice` is the ElevenLabs voice ID (not a name). Default model: `eleven_multilingual_v2` (supports Russian and other languages).

### `showCaption()` speech parameter

The `speech` option controls what text is narrated (vs displayed):

```js
await showCaption('Дт 60.02 — Кт 51');                           // narrates the displayed text
await showCaption('Дт 60.02 — Кт 51', { speech: 'Проводка: дебет шестьдесят ноль два, кредит пятьдесят один' }); // custom narration
await showCaption('Техническая информация', { speech: false });   // no narration for this caption
```

### `addNarration(videoPath, opts?)`

Generate TTS and merge audio with video. Call after `stopRecording()`.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `videoPath` | `string` | Path to the recorded MP4 file |
| `opts.captions` | `Array` | Explicit captions (default: from last recording or `.captions.json`). Each caption may include a `voice` field to override the global voice for that segment |
| `opts.provider` | `string` | `'edge'` (default), `'openai'`, or `'elevenlabs'` |
| `opts.voice` | `string` | Voice name (provider-specific; openai `cedar`/`marin` are not available on `tts-1`/`tts-1-hd`) |
| `opts.apiKey` | `string` | API key (for openai) |
| `opts.apiUrl` | `string` | Endpoint (for openai) |
| `opts.model` | `string` | Model (for openai, default: `tts-1`) |
| `opts.instructions` | `string` | Speaking style, for models that support it (openai, e.g. `gpt-4o-mini-tts`) |
| `opts.ffmpegPath` | `string` | Path to ffmpeg binary |
| `opts.outputPath` | `string` | Output file (default: `video-narrated.mp4`) |
| `opts.music` | `string | object` | Background music over the whole video, in speech pauses — see Background music; remembered in `.captions.json` for re-narration, `false` drops all music |

**Returns:** `{ file, duration, size, captions, warnings? }`

### `getCaptions()`

Returns captions from the current or last recording: `Array<{ text, speech, time, voice? }>`.

### Example: Record and narrate

```js
await startRecording('recordings/demo.mp4');
await showCaption('Переходим в раздел Банк и касса');
await wait(1.5);
await navigateSection('Банк и касса');
await showCaption('Открываем банковские выписки');
await wait(1.5);
await openCommand('Банковские выписки');
await hideCaption();
const video = await stopRecording();

// Add narration (reads tts config from .v8-project.json)
const narrated = await addNarration(video.file, { voice: 'ru-RU-DmitryNeural' });
console.log(`Narrated: ${narrated.file}, ${narrated.duration}s`);
```

### Re-narration

After recording, a `.captions.json` file is saved next to the video. You can re-narrate with a different voice without re-recording:

```js
const result = await addNarration('recordings/demo.mp4', { voice: 'ru-RU-SvetlanaNeural' });
```

### Background music

```js
await addNarration(video.file, { music: 'bright' });   // the whole video: plays in pauses, fades out under speech
await showSlide({ ...spec, music: 'bright' }, TTS);      // while this slide is up (a showcase, a 3D scene, the title)
await withMusic('focus', async () => { /* long actions in 1C without speech */ });
```

Presets (generated, no licence needed): `bright`, `warm`, `calm`, `focus`, `uplift`, `uplift-soft` — or a file path
(`'audio/track.mp3'`, its licence is yours to check); `{ preset | file, level }` sets the level (dB, default −22).
`play` takes `--music=bright`. Seams are handled: one music in a row flows on, short gaps are bridged, different
music cross-fades. Music helps on titles, showcases and silent stretches; under a dialogue or a dense explanation it
distracts — keep one preset per video.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "ffmpeg not found" | Install ffmpeg and ensure it's discoverable (see Prerequisites) |
| Recording file is 0 bytes | Check that output path is writable. ffmpeg may have crashed |
| Video is choppy | Add `wait()` between steps. Reduce `quality` for faster capture |
| "Already recording" | Call `stopRecording()` before starting a new recording |
| Recording stops on disconnect | Expected — auto-stop prevents orphaned ffmpeg processes |
| "No captions available" | Use `showCaption()` during recording, or pass `opts.captions` |
| TTS timeout | Check internet connection. Edge TTS requires network access |
| Audio cuts off between captions | Smart TTS wait should handle this automatically. If warnings appear, add longer `wait()` after `showCaption` |
