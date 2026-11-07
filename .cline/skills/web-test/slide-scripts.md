# Scripted slides

A page of your own ([slides.md](slides.md)) may run a script: a 3D scene, a Lottie animation, an animation
computed from data. Appearing, focus, camera, CSS keyframes and SVG need no script. A ready-made video clip
needs none either — see the end of this page.

```js
await showSlide({
  html: '<div class="scene"></div><div class="tag t1">Погрузка</div>',
  css: '.scene{position:absolute;inset:0} .tag{position:absolute;left:80px;bottom:70px;font-size:32px}',
  script: 'docs/video/scene.js',   // any .js from the project root, or a function: async (slide) => { … }
  steps: [{ speech: '…' }, { show: '.t1', speech: '…' }],
}, TTS);
```

The file (here `docs/video/scene.js`, an example path) is the body of the script, `slide` in scope:

```js
const THREE = await slide.import('node_modules/three/build/three.module.js');
const r = new THREE.WebGLRenderer({ antialias: true });
r.setSize(1920, 1080, false);
slide.$('.scene').appendChild(r.domElement);
const scene = new THREE.Scene(), cam = new THREE.PerspectiveCamera(35, 1920 / 1080, 0.1, 100);
// … build the scene …
let phase = 0;
slide.on('step', (i) => { phase = i; });   // step i has begun: start its part of the animation
let raf;
(function loop() { /* animate by phase */ r.render(scene, cam); raf = requestAnimationFrame(loop); })();
return () => { cancelAnimationFrame(raf); r.dispose(); };   // cleanup when the slide goes
```

| `slide.` | |
|---|---|
| `stage`, `$(sel)`, `$(sel)` | the 1920×1080 stage; lookups in the slide's page |
| `theme` | `{ primary, accent, ground, ink }` — the slide's colours (`new THREE.Color(slide.theme.accent)`) |
| `on('step', (i, step) => …)` | each step, from the first (`i` from 0) |
| `import(path)` | an ES module from the project (its relative imports load too) |
| `importMap({ name: path })` | bare names in modules → project files, before the first such import: add-ons import `'three'` by name — `slide.importMap({ three: 'node_modules/three/build/three.module.js', 'three/addons/': 'node_modules/three/examples/jsm/' })`; then `await import('three/addons/loaders/GLTFLoader.js')` works too |
| `load(path)` | a classic script (UMD: `lottie.min.js`, …), once per page |
| `asset(path)` | the address of a project file (a model, JSON, a texture) for `fetch` or a loader |
| return a function / `onDispose(fn)` | cleanup: stop `requestAnimationFrame`, dispose WebGL |

- The script runs **in the page**. A function is sent as its source: module variables do not reach it — put
  data into the page (`data-` attributes) or a JSON file read with `fetch(slide.asset(...))`.
- It runs once the slide is on screen, before its first step; the steps wait for it (up to 20 s). The loading
  time is in the video — keep libraries in the project (`npm i three`), not on a CDN. An error stops
  `showSlide`: `slide script failed: …`.
- Paths are from the project root; only files inside it are served, hidden ones (`.v8-project.json`, `.git`) never.
  They are served while such a slide is on screen.
- Without cleanup the scene keeps running behind the next slide.
- What appears later is hidden (`visible = false`) until its step, not squashed to zero on a surface: faces
  lying in one plane flicker in the video.
- `preview` shows the scene at the end of each short step (~1.6 s, no speech): tie the motion to the steps and
  let it finish within ~1 s; the checks do not look inside a canvas.

**Smoothness.** WebGL needs the graphics card. A 1C session (a browser window) has it; `play` and `preview`
start Chromium with `--enable-gpu`. Without a card Chromium draws in software and a heavy 3D scene stutters
in the video — keep the scene light or render a clip beforehand.

**A video clip** — no script: `<video autoplay muted src="asset:video/clip.mp4"></video>` in `html` (mp4 H.264 or
WebM); `asset:` works in `html`, `css` (`url(asset:…)`) and `background` of a page of your own.
