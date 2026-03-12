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

Модель прочитает это поле и передаст в `startRecording({ ffmpegPath })`.

### Порядок поиска ffmpeg

1. `opts.ffmpegPath` — явный путь (из `.v8-project.json` или параметра)
2. `FFMPEG_PATH` — переменная окружения
3. `ffmpeg` — в системном PATH
4. `tools/ffmpeg/bin/ffmpeg.exe` — относительно корня проекта

## API

### `startRecording(outputPath, opts?)`

Start recording the browser viewport to an MP4 file.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `outputPath` | string | required | Output .mp4 file path |
| `opts.fps` | number | 25 | Target framerate |
| `opts.quality` | number | 80 | JPEG quality (1-100) |
| `opts.ffmpegPath` | string | auto | Explicit path to ffmpeg binary |

- Output directory is created automatically if it doesn't exist
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

The overlay uses `pointer-events: none` — does not interfere with clicking.

**Smart TTS wait** (during recording): `showCaption` automatically pauses for the estimated TTS speech duration (~100ms per character, min 2s). The next `wait()` call accounts for this — if the explicit pause is shorter than the TTS wait already done, no extra delay is added. If longer, only the remaining difference is waited. This means script authors don't need to calculate TTS timing manually.

### `hideCaption()`

Remove the caption overlay.

### `showTitleSlide(text, opts?)`

Display a full-screen title slide overlay (gradient background, centered text). Useful for intro/outro frames in video recordings. Calling again updates the content.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `text` | string | required | Title text (`\n` → line break) |
| `opts.subtitle` | string | `''` | Smaller text below the title |
| `opts.background` | string | dark gradient | CSS background |
| `opts.color` | string | `'#fff'` | Text color |
| `opts.fontSize` | number | 36 | Title font size in px |

The overlay covers the entire viewport with `z-index: 999999` and `pointer-events: none`.

### `hideTitleSlide()`

Remove the title slide overlay.

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
await startRecording('recordings/create-order.mp4');

// Title slide — 4 seconds
await showTitleSlide('Создание заказа клиента', { subtitle: 'Демонстрация' });
await wait(4);
await hideTitleSlide();
setHighlight(true); // enable auto-highlight for all actions

// Steps: caption → pause → action (highlight is automatic)
await showCaption('Шаг 1. Переходим в раздел «Продажи»');
await wait(1.5);
await navigateSection('Продажи');

await showCaption('Шаг 2. Открываем заказы клиентов');
await wait(1.5);
await openCommand('Заказы клиентов');

await showCaption('Шаг 3. Создаём новый заказ');
await wait(1.5);
await clickElement('Создать');
await wait(2); // wait for form to load

await showCaption('Шаг 4. Заполняем шапку');
await wait(1.5);
await fillFields({ 'Организация': 'Конфетпром', 'Контрагент': 'Альфа' });
await wait(1);

await hideCaption();
setHighlight(false);
const result = await stopRecording();
console.log(`Recorded ${result.duration}s, ${(result.size / 1024 / 1024).toFixed(1)} MB`);
```

**Caption timing**: show the caption *before* the action — `showCaption` auto-waits for estimated TTS duration during recording. The subsequent `wait()` is absorbed by the credit system (no double-waiting). Add `wait()` *after* the action only when the next step needs the result to load (e.g., form opening).

**Highlight timing**: `setHighlight(true)` enables auto-mode — each action function highlights the target for 500ms, then removes the highlight before performing the action. No manual `highlight()`/`unhighlight()` calls needed. Enable after title slide, disable before `stopRecording()`.

## TTS Narration

Add voiceover to recorded videos. Captions shown via `showCaption()` are automatically collected during recording and can be synthesized into speech.

### Prerequisites

- **ffmpeg** — same as for video recording (ffprobe must be next to ffmpeg)
- **node-edge-tts** — `npm install --prefix tools/tts node-edge-tts` (for Edge TTS provider, free, no API key). Also works if installed globally or at project level — the resolver tries multiple locations automatically

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
    "voice": "alloy"
  }
}
```

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
| `opts.captions` | `Array` | Explicit captions (default: from last recording or `.captions.json`) |
| `opts.provider` | `string` | `'edge'` (default), `'openai'`, or `'elevenlabs'` |
| `opts.voice` | `string` | Voice name (provider-specific) |
| `opts.apiKey` | `string` | API key (for openai) |
| `opts.apiUrl` | `string` | Endpoint (for openai) |
| `opts.model` | `string` | Model (for openai, default: `tts-1`) |
| `opts.ffmpegPath` | `string` | Path to ffmpeg binary |
| `opts.outputPath` | `string` | Output file (default: `video-narrated.mp4`) |

**Returns:** `{ file, duration, size, captions, warnings? }`

### `getCaptions()`

Returns captions from the current or last recording: `Array<{ text, speech, time }>`.

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
