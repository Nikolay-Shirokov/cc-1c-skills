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

### `stopRecording()` → `{ file, duration, size }`

Stop recording and finalize the MP4 file.

| Return field | Type | Description |
|-------------|------|-------------|
| `file` | string | Absolute path to the MP4 file |
| `duration` | number | Recording duration in seconds |
| `size` | number | File size in bytes |

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

## Example: Record a workflow with title slide and captions

```js
await startRecording('recordings/create-order.mp4');

// Title slide — 4 seconds
await showTitleSlide('Создание заказа клиента', { subtitle: 'Демонстрация' });
await wait(4);
await hideTitleSlide();

// Steps: caption → pause → action
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
const result = await stopRecording();
console.log(`Recorded ${result.duration}s, ${(result.size / 1024 / 1024).toFixed(1)} MB`);
```

**Caption timing**: show the caption *before* the action with a `wait(1.5)` pause — the viewer reads what will happen, then sees it happen. Add `wait()` *after* the action only when the next step needs the result to load (e.g., form opening).

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "ffmpeg not found" | Install ffmpeg and ensure it's discoverable (see Prerequisites) |
| Recording file is 0 bytes | Check that output path is writable. ffmpeg may have crashed |
| Video is choppy | Add `wait()` between steps. Reduce `quality` for faster capture |
| "Already recording" | Call `stopRecording()` before starting a new recording |
| Recording stops on disconnect | Expected — auto-stop prevents orphaned ffmpeg processes |
