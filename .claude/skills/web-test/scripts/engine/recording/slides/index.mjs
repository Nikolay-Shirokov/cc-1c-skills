// web-test recording/slides v1.9 — animated step slides: showSlide / hideSlide / prepareSlides / setSlideTheme / loadSlides.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// A slide is a template spec ({ layout, ... }) or a custom page ({ html, css, steps }). Each step is a phrase
// plus what changes on screen; a spoken step becomes a caption, so addNarration voices it exactly where its
// change happens. Step length = the phrase's real TTS length (shared phrase cache, see tts.mjs).
// Or one phrase for the slide (spec.speech) and steps on its words (step.at) — anchors.mjs: one take, no seams.

import { readFileSync, existsSync, statSync } from 'fs';
import { pathToFileURL } from 'url';
import { page, recorder, ensureConnected, resolveProjectPath } from '../../core/state.mjs';
import { synthesizeCached, cachedSpeechSeconds, cachedWords, ttsCacheFile, mergeTtsOptions, readProjectConfig, unspokenWarning } from '../tts.mjs';
import { anchorTimes, locateAnchors, ON_TIME } from '../anchors.mjs';
import { BASE_CSS, themeVars, pageMount, pageStep, pageHide, pageLint, pageScript } from './protocol.mjs';
import { ASSET_BASE, ensureAssetsRoute, releaseAssetsRoute, encodeAssetPath, rewriteAssets } from './assets.mjs';
import { buildSlide, imageInfo, esc } from './templates.mjs';
import { resolveMusic, musicOpen, musicClose } from '../music.mjs';

// the music stretch of the slide on screen (spec.music): opened on mount, closed when the slide goes
let slideCue = null;

const LEAD = 0.35;   // the change starts, the voice follows
const GAP = 0.5;     // breath after a phrase

// ── theme ─────────────────────────────────────────────────────────────────
// Layers: defaults (protocol.mjs) < .v8-project.json "slides.theme" < setSlideTheme() < opts.theme < spec.theme.
let scenarioTheme = {};

/** Set the theme for the following slides: { primary, accent, ground, ink, line?, mark?, onAccent?, font? }. */
export function setSlideTheme(theme) { scenarioTheme = { ...(theme || {}) }; }

function projectSlidesTheme() {
  return readProjectConfig().slides?.theme || {};
}
const themeFor = (spec, opts) => ({ ...projectSlidesTheme(), ...scenarioTheme, ...(opts.theme || {}), ...(spec.theme || {}) });

// ── frame ─────────────────────────────────────────────────────────────────
// theme.frame: { logo, number, footer } — the brand's running elements on every slide, still under the camera.
// Places (`at`): the four corners; a footer also 'left' / 'right' (a vertical line along the edge). Several in
// one corner line up in the order declared, the first in the corner. title / closing / image go without it
// unless their spec gives a `frame` object; spec.frame false — none; a spec.frame object replaces its parts.
const CORNERS = ['bottom-left', 'bottom-right', 'top-left', 'top-right'];
const NO_FRAME = new Set(['title', 'closing', 'image']);
// fields: the least distance of content from a used edge (templates take max(own offset, field)). As in a
// corporate deck: content starts at ~128px past a vertical footer; above (below) a corner row 100px leave room
// for the slide's slow zoom, which carries its edges outward
const SAFE = { left: '128px', right: '128px', top: '100px', bottom: '100px' };
let frameRecorder, frameNo = 0;   // slide numbers: counted per recording and per script run
/** A new script run (exec / play / preview): slide numbers start over. */
export function resetSlideRun() { frameRecorder = recorder; frameNo = 0; }
// a logo is read once (path + mtime → data URL): a deck sends it with every slide
const logoCache = new Map();
function logoUrl(src) {
  const abs = resolveProjectPath(src);
  const key = existsSync(abs) ? `${abs}|${statSync(abs).mtimeMs}` : abs;
  if (!logoCache.has(key)) logoCache.set(key, imageInfo(src, 'frame').url);
  return logoCache.get(key);
}

function frameSpec(spec, theme) {
  if (spec.frame === false) return null;
  const own = spec.frame && typeof spec.frame === 'object' ? spec.frame : null;
  if (spec.frame !== undefined && spec.frame !== false && !own) throw new Error('slides frame: spec "frame" must be false or an object');
  if (NO_FRAME.has(spec.layout) && !own) return null;
  // theme frame false / null — off (a scenario can drop the project's frame)
  const base = theme.frame && typeof theme.frame === 'object' ? theme.frame : null;
  if (theme.frame !== undefined && theme.frame !== null && theme.frame !== false && !base) throw new Error('slides theme: "frame" must be an object { logo, number, footer }, or false');
  if (!base && !own) return null;
  const merged = { ...(base || {}), ...(own || {}) };   // key order: the theme's, then new ones — the order in a corner
  const out = [];
  for (const [key, v] of Object.entries(merged)) {
    if (v === false || v == null) continue;
    const bad = (msg) => { throw new Error(`slides frame: ${key} — ${msg}`); };
    const at = (v && typeof v === 'object' && v.at) || { logo: 'bottom-left', number: 'bottom-right', footer: 'left' }[key];
    if (key === 'logo') {
      const src = typeof v === 'string' ? v : v?.src;
      if (typeof src !== 'string' || !src.trim()) bad('a picture path, or { src, at, height }');
      if (!CORNERS.includes(at)) bad(`at must be ${CORNERS.join(', ')}`);
      out.push({ key, at, src, height: Number(v.height) || 30 });
    } else if (key === 'number') {
      if (v !== true && typeof v !== 'object') bad('true or { at }');
      if (!CORNERS.includes(at)) bad(`at must be ${CORNERS.join(', ')}`);
      out.push({ key, at });
    } else if (key === 'footer') {
      const text = typeof v === 'string' ? v : v?.text;
      if (typeof text !== 'string' || !text.trim()) bad('a text, or { text, at }');
      if (!CORNERS.includes(at) && at !== 'left' && at !== 'right') bad(`at must be ${CORNERS.join(', ')}, left or right`);
      out.push({ key, at, text });
    } else throw new Error(`slides frame: unknown "${key}" — logo, number, footer`);
  }
  return out.length ? out : null;
}

/** The frame's html and the fields it keeps (CSS vars); the slide number is counted here, at the mount. */
function frameFor(spec, items) {
  if (!items) return { html: '', vars: {} };
  if (frameRecorder !== recorder) { frameRecorder = recorder; frameNo = 0; }
  frameNo = Number.isInteger(spec.number) ? spec.number : frameNo + 1;
  const piece = (x) => (x.key === 'logo' ? `<img class="wf-logo" style="height:${x.height}px" src="${logoUrl(x.src)}"/>`
    : x.key === 'number' ? `<span class="wf-num">${frameNo}</span>` : `<span class="wf-text">${esc(x.text)}</span>`);
  let html = '';
  const vars = {};
  for (const c of CORNERS) {
    const here = items.filter((x) => x.at === c);
    if (!here.length) continue;
    html += `<div class="wf-c wf-${c}">${here.map(piece).join('')}</div>`;
    vars[c.startsWith('top') ? '--safe-top' : '--safe-bottom'] = c.startsWith('top') ? SAFE.top : SAFE.bottom;
  }
  for (const x of items.filter((i) => i.at === 'left' || i.at === 'right')) {
    html += `<div class="wf-edge wf-${x.at}">${esc(x.text)}</div>`;
    vars[`--safe-${x.at}`] = SAFE[x.at];
  }
  return { html, vars };
}

// theme.fonts: [{ family, src, weight?, style? }] — font files from the project, registered on the page's document
// (document.fonts reaches into the slides' shadow roots; an @font-face inside a shadow root does not). Sent once
// per page: a registry on the document says what is there already (a 1C page keeps it across slides).
// theme.headingWeight: the weight of the big headings (slide titles, hub and plate titles, big values) — a brand
// that sets its headings in Bold gives 700; default 800
function checkHeadingWeight(theme) {
  const w = theme?.headingWeight;
  if (w !== undefined && !(Number.isInteger(w) && w >= 100 && w <= 900 && w % 100 === 0)) {
    throw new Error(`slides theme: "headingWeight" must be 100..900 in steps of 100 (700 — Bold), got ${JSON.stringify(w)}`);
  }
}
function fontList(fonts) {
  if (fonts === undefined) return [];
  if (!Array.isArray(fonts)) throw new Error('slides theme: "fonts" must be an array of { family, src, weight?, style? }');
  return fonts.map((f, i) => {
    if (!f || typeof f.family !== 'string' || !f.family.trim() || typeof f.src !== 'string' || !f.src.trim()) {
      throw new Error(`slides theme: fonts[${i}] needs "family" and "src" (a font file from the project root)`);
    }
    const abs = resolveProjectPath(f.src);
    if (!existsSync(abs)) throw new Error(`slides theme: font file not found: ${abs}`);
    const weight = String(f.weight ?? 400), style = f.style || 'normal';
    return { family: f.family.trim(), weight, style, abs, key: `${f.family.trim()}|${weight}|${style}|${abs}` };
  });
}
async function ensureFonts(fonts) {
  const list = fontList(fonts);
  if (!list.length) return;
  const have = await page.evaluate((keys) => keys.filter((k) => document.__wsFonts?.[k]), list.map((f) => f.key));
  for (const f of list.filter((x) => !have.includes(x.key))) {
    const b64 = readFileSync(f.abs).toString('base64');
    try {
      await page.evaluate(async ({ family, weight, style, b64, key }) => {
        const bin = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
        const face = new FontFace(family, bin.buffer, { weight, style });
        await face.load();
        document.fonts.add(face);
        (document.__wsFonts ||= {})[key] = true;
      }, { family: f.family, weight: f.weight, style: f.style, b64, key: f.key });
    } catch (e) {
      throw new Error(`slides theme: font ${f.abs} did not load: ${String(e.message).replace(/^page\.evaluate:\s*/, '').split('\n')[0]}`);
    }
  }
}

// ── helpers ───────────────────────────────────────────────────────────────
const SLIDE_OPTS = new Set(['theme', 'motion', 'fast', 'synth', 'legacy', 'lint', 'onStep', 'label']);
function ttsOptions(opts) {
  return mergeTtsOptions(Object.fromEntries(Object.entries(opts).filter(([k]) => !SLIDE_OPTS.has(k))));
}

export async function hold(ms) {
  let left = ms;
  while (left > 0) {
    const c = Math.min(left, 500);
    await page.waitForTimeout(c);
    left -= c;
    recorder?._flushFrames?.();
  }
}

function animatedSelectors(steps) {
  const of = (k) => steps.flatMap((s) => (s[k] ? [s[k]] : []));
  return { show: of('show'), all: [...of('show'), ...of('hide'), ...of('focus'), ...of('dim')] };
}

// A page's script runs in the page: built as one expression `(pageScript)(opts, userFn)` — a function is passed as
// its source (closures of the module do not travel), a file as the body of `async (slide) => { … }`.
const SCRIPT_TIMEOUT = 20000;
function scriptExpr(script) {
  let fn;
  if (script.fn) {
    fn = script.fn.toString().trim();
    // method shorthand `run(slide) { … }` is not an expression: make it a function
    if (!/^(async\s*)?(function\b|\(|[\w$]+\s*=>)/.test(fn)) fn = fn.replace(/^(async\s+)?/, (m) => `${m}function `);
  } else fn = `async (slide) => {\n${readFileSync(script.file, 'utf8')}\n}`;
  return `(${pageScript.toString()})(${JSON.stringify({ base: ASSET_BASE, timeoutMs: SCRIPT_TIMEOUT })}, ${fn}, ${encodeAssetPath.toString()})`;
}
async function runScript(script) {
  try { await page.evaluate(scriptExpr(script)); }
  catch (e) { throw new Error(`slide script failed: ${String(e.message).replace(/^page\.evaluate:\s*/, '').split('\n')[0]}`); }
}

const estimate = (text) => Math.max(2, text.length * ((recorder?.speechRate || 70) / 1000));

// One phrase for the slide, steps on its words: some step has `at`. The slide's `speech` is the phrase; a step's
// own speech is an error then (two voices at once). Template steps follow spec.steps one to one, so the first
// spec.steps.length built steps are the user's; the template's extras (the outro) go after the phrase.
function speechPlan(spec, built, name) {
  const user = Array.isArray(spec.steps) ? spec.steps : [];
  const anchoredUser = user.some((s) => s && typeof s === 'object' && s.at !== undefined);
  if (!anchoredUser) return null;
  const where = `showSlide(${name})`;
  if (!built.steps.some((s) => s.at !== undefined)) throw new Error(`${where}: layout "${spec.layout}" takes no steps — "at" needs a layout with steps`);
  if (typeof spec.speech !== 'string' || !spec.speech.trim()) {
    throw new Error(`${where}: steps with "at" need the slide's "speech" — one phrase, the steps on its words`);
  }
  user.forEach((s, i) => {
    if (s.speech !== undefined) throw new Error(`${where}: step ${i + 1} has its own "speech" — with "at" the slide speaks one phrase (the slide's "speech")`);
  });
  const userCount = spec.layout !== undefined ? user.length : built.steps.length;
  const idx = built.steps.map((s, i) => (s.at !== undefined ? i : -1)).filter((i) => i >= 0);
  const labels = idx.map((i) => `${where} step ${i + 1} at`);
  locateAnchors(spec.speech, idx.map((i) => built.steps[i].at), 'at', labels);   // words found, in order
  return { speech: spec.speech, voice: spec.voice, userCount, idx, labels };
}
const label = (spec, opts) => opts.label || spec.layout || 'page';

// Node-side rules on top of pageLint: little text, short steps, screen text ≠ narration (redundancy),
// speech written as spoken (no Latin words or abbreviations the voice would mispronounce).
const norm = (t) => t.toLowerCase().replace(/ё/g, 'е').match(/[a-zа-я0-9]+/g) || [];
async function lintStep(step, i, seconds) {
  const r = await page.evaluate(pageLint, { showSel: step.show || null });
  const w = [...r.overflow, ...r.small.map((x) => `small font: ${x}`), ...r.longLists.map((x) => `long list ${x}`)];
  if (r.words > 70) w.push(`a lot of text on screen: ~${r.words} words`);
  if (step.speech) {
    if (seconds > 15) w.push(`long step: ~${Math.round(seconds)} s of speech — split it into steps`);
    const unspoken = unspokenWarning(step.speech);
    if (unspoken) w.push(unspoken);
    const sp = new Set(norm(step.speech));
    for (const t of r.shown) {
      const words = norm(t);
      if (words.length >= 8 && words.filter((x) => sp.has(x)).length / words.length > 0.8) {
        w.push(`screen text repeats the narration: "${t.replace(/\s+/g, ' ').slice(0, 50)}…"`);
      }
    }
  }
  return w.map((x) => `step ${i + 1}: ${x}`);
}

// ── one phrase, steps on its words ───────────────────────────────────────
// The phrase is synthesized (cached, with word timings when the provider gives them); each anchor gets its time
// from the phrase's start (anchors.mjs). fast (no-record, play --fast): every step `fast` seconds, no phrase.
async function anchoredTimes(plan, built, tts, opts, rec, motion) {
  const vo = plan.voice ? { ...tts, voice: plan.voice } : tts;
  const ats = plan.idx.map((i) => built.steps[i].at);
  const preHold = (s) => s.hold ?? (motion ? 0.8 : 0);
  const pre = built.steps.slice(0, plan.idx[0]).reduce((a, s) => a + preHold(s), 0);
  const tail = built.steps.slice(plan.userCount).reduce((a, s) => a + (s.hold ?? 0), 0);
  if (opts.fast !== undefined) {
    return { fast: true, times: ats.map(() => null), seconds: 0, end: 0, total: 0.6 + built.steps.length * opts.fast, synthesized: 0, warnings: [] };
  }
  let seconds = cachedSpeechSeconds(plan.speech, vo), synthesized = 0;
  const fresh = opts.synth !== false && (seconds == null || ((vo.provider || 'edge') === 'edge' && !cachedWords(plan.speech, vo)));
  if (fresh) {
    try { seconds = (await synthesizeCached(plan.speech, { ...vo, words: true })).seconds; synthesized = 1; }
    catch (e) { console.log(`[web-test] showSlide: TTS failed, anchor times estimated: ${e.message}`); }
  }
  const cached = seconds != null;
  const res = anchorTimes(plan.speech, ats, {
    words: cached ? cachedWords(plan.speech, vo) : null,
    file: cached ? ttsCacheFile(plan.speech, vo) : null,
    seconds: seconds ?? estimate(plan.speech),
    rate: (rec?.speechRate || 70) / 1000, ffmpegPath: vo.ffmpegPath, labels: plan.labels,
  });
  seconds ??= estimate(plan.speech);
  // the phrase ends with its last word (the file has a tail of silence after it)
  const last = res.times.length ? res.times[res.times.length - 1].t : 0;
  const end = Math.max(res.end, last);
  const after = tail ? tail : GAP;   // an outro is the pause after the phrase; without one — a breath
  return { times: res.times, seconds, end, warnings: res.warnings, synthesized, preHold, total: 0.6 + pre + LEAD + end + after };
}

async function playAnchored(plan, anch, built, opts, tts, warnings) {
  warnings.push(...anch.warnings);
  const unspoken = unspokenWarning(plan.speech);
  if (unspoken) warnings.push(unspoken);
  const clock = () => (recorder ? recorder.videoTimeMs : performance.now()) / 1000;
  const until = async (t) => { const ms = (t - clock()) * 1000; if (ms > 0) await hold(ms); };
  const run = async (s, i) => {
    await page.evaluate(pageStep, { step: s, index: i, maxZoom: built.maxZoom ?? 2 });
    if (opts.lint !== false) {
      // the screen against the whole phrase; the phrase's length is fine here (one take)
      const w = await lintStep({ ...s, speech: plan.speech }, i, 0);
      warnings.push(...w.filter((x) => !/write it as spoken/.test(x)));
    }
    if (opts.onStep) await opts.onStep(i, s);
  };
  if (anch.fast) {
    for (let i = 0; i < built.steps.length; i++) { await run(built.steps[i], i); await hold(opts.fast * 1000); }
    return;
  }
  let t0 = null;
  const start = async () => {
    await hold(LEAD * 1000);
    if (recorder) {
      const voice = plan.voice && plan.voice !== tts.voice ? { voice: plan.voice } : {};
      recorder.captions.push({ text: plan.speech, speech: plan.speech, time: Math.round(recorder.videoTimeMs), ...voice });
    }
    t0 = clock();
  };
  let k = 0;   // the next anchor
  for (let i = 0; i < built.steps.length; i++) {
    const s = built.steps[i];
    if (i < plan.idx[0]) { await run(s, i); await hold(anch.preHold(s) * 1000); continue; }   // before the phrase
    if (t0 == null) await start();
    if (i >= plan.userCount) {
      // the template's outro (all lit): from the phrase's last word — it is the pause before the next slide
      if (i === plan.userCount) await until(t0 + anch.end);
      await run(s, i);
      await hold((s.hold ?? 0) * 1000);
      continue;
    }
    if (s.at !== undefined) {
      const target = t0 + anch.times[k++].t;
      await until(target);
      const late = clock() - target;
      if (late > ON_TIME) warnings.push(`step ${i + 1}: ${late.toFixed(2)} s late for its word (the step before took longer)`);
    }
    await run(s, i);
    if (s.hold) await hold(s.hold * 1000);
  }
  if (t0 == null) await start();
  await until(t0 + anch.end + GAP);
  // like showCaption: a wait() right after a spoken slide is absorbed by the time already waited
  if (recorder) recorder.captionCredit = { waitedMs: (anch.end + GAP) * 1000, at: Date.now() };
}

// ── API ───────────────────────────────────────────────────────────────────

/**
 * Show a slide and play its steps; returns when the last step is over. The slide stays on screen until
 * the next showSlide crossfades over it, or hideSlide().
 * @param {object} spec — template { layout: 'title'|'agenda'|'statement'|'cards'|'columns'|'comparison'|
 *   'process'|'radial'|'image'|'summary'|'closing', ... } or page { html|file, css?, steps, background?, push? }
 * @param {object} [opts] — TTS options (provider, voice, ...; default: .v8-project.json "tts"),
 *   theme, motion (false — no transitions), label (name in warnings)
 * @returns {{ steps: number, seconds: number, warnings?: string[] }}
 */
export async function showSlide(spec, opts = {}) {
  ensureConnected();
  const built = buildSlide(spec);
  // the theme and its frame first: a wrong frame (a missing logo) fails before any speech is synthesized
  const theme = themeFor(spec, opts);
  const frameItems = opts.legacy ? null : frameSpec(spec, theme);
  for (const x of frameItems || []) if (x.src) logoUrl(x.src);
  if (spec.music !== undefined) resolveMusic(spec.music);   // a wrong music spec fails before the slide
  const motion = (opts.motion ?? spec.motion) !== false;
  const tts = ttsOptions(opts);
  const rec = recorder;

  // one phrase for the slide, steps on its words
  const plan = speechPlan(spec, built, label(spec, opts));
  let anch = null;
  if (plan) anch = await anchoredTimes(plan, built, tts, opts, rec, motion);

  // step lengths
  const durs = [];
  let synthesized = anch?.synthesized || 0;
  for (const s of (anch ? [] : built.steps)) {
    if (opts.fast !== undefined) { durs.push(opts.fast); continue; }
    if (!s.speech) { durs.push(s.hold ?? (motion ? 0.8 : 0)); continue; }
    if (opts.legacy && !rec) { durs.push(0); continue; }   // the former overlays waited for speech only while recording
    const vo = s.voice ? { ...tts, voice: s.voice } : tts;
    let secs = cachedSpeechSeconds(s.speech, vo);
    if (secs == null) {
      if (opts.synth === false) secs = estimate(s.speech);
      else {
        try { secs = (await synthesizeCached(s.speech, vo)).seconds; synthesized++; }
        catch (e) { secs = estimate(s.speech); console.log(`[web-test] showSlide: TTS failed, length estimated: ${e.message}`); }
      }
    }
    durs.push(opts.legacy ? secs : LEAD + secs + GAP);
  }
  if (synthesized && rec) {
    console.log(`[web-test] showSlide(${label(spec, opts)}): synthesized ${synthesized} phrase(s) during the recording — `
      + 'the video held still meanwhile; call prepareSlides([...]) before startRecording()');
  }
  const total = anch ? anch.total : 0.6 + durs.reduce((a, d) => a + d, 0);

  // the first slide right after startRecording appears at once: the video must not open on the page under it
  const onScreen = await page.evaluate(() => !!document.getElementById('__ws_slide'));
  const first = rec && !onScreen && (rec.holdSince || rec.videoTimeMs < 1000);
  const instant = !motion || first;
  // the brand's frame (legacy overlays never have one) and the fields it keeps clear
  const frame = frameFor(spec, frameItems);
  checkHeadingWeight(theme);
  const vars = { ...themeVars(theme), ...frame.vars };
  // theme.background (the brand's ground, a logo in a corner) — on slides without their own (spec or template)
  const bg = built.bg ?? (theme.background !== undefined ? rewriteAssets(theme.background) : undefined);
  // project files (asset: in the page or its ground, slide.import/load/asset in its script) — served on this page,
  // before the first mount: a logo in the ground is requested at once. Routing turns the browser cache off:
  // on only while such a slide is up (the 1C client keeps its cache otherwise)
  const needsAssets = !!built.script || `${built.html}${built.css || ''}${bg || ''}`.includes(ASSET_BASE);
  if (needsAssets) await ensureAssetsRoute(page);
  if (first) {
    // the slide's ground at once (a tiny payload), the content follows: mounting a slide with a big
    // picture takes a while, and the recording is already running
    // the video starts over once the ground is on screen: the page held since startRecording is dropped.
    // Hold from before the ground is mounted (its frame must not flush the page's one into the video);
    // a painted frame reaches the screencast with a lag — hence the pause (this time is not in the video).
    const held = rec._holdFrames?.();
    try {
      await page.evaluate(pageMount, { html: '', css: BASE_CSS, bg, vars, instant: true, animated: { show: [], all: [] } });
      if (held) await page.waitForTimeout(300);
    } finally {
      if (held) rec._releaseFrames();   // a failed mount must not leave the recording holding (writing nothing)
    }
  }
  await ensureFonts(theme.fonts);   // before the content (the first slide's ground above has no text)
  await page.evaluate(pageMount, {
    html: built.html, css: BASE_CSS + (built.css || ''), bg, vars, frame: frame.html,
    pushSec: motion && built.push ? total : 0, animated: animatedSelectors(built.steps), instant, staticMode: !motion,
    hostId: opts.legacy || null,
  });
  // music follows the slides: the previous slide's stretch ends where this one begins (one preset in a row flows on)
  musicClose(slideCue);
  slideCue = spec.music !== undefined ? musicOpen(spec.music, 'duck') : null;
  if (built.script) await runScript(built.script);   // ready before the first step: no race with the steps
  else if (!needsAssets) await releaseAssetsRoute(page);
  await hold(instant ? 60 : 600);

  const warnings = [];
  if (anch) {
    await playAnchored(plan, anch, built, opts, tts, warnings);
    const unique = [...new Set(warnings)];
    if (unique.length && opts.lint !== 'collect') for (const w of unique) console.log(`[web-test] showSlide(${label(spec, opts)}) WARN ${w}`);
    return { steps: built.steps.length, seconds: Math.round(total * 10) / 10, anchors: anch.times, ...(unique.length ? { warnings: unique } : {}) };
  }
  let lastSpoken = false;
  for (let i = 0; i < built.steps.length; i++) {
    const s = built.steps[i];
    await page.evaluate(pageStep, { step: s, index: i, maxZoom: built.maxZoom ?? 2 });
    if (s.speech && opts.fast === undefined) {
      const lead = opts.legacy ? 0 : LEAD;
      if (lead) await hold(lead * 1000);
      if (recorder) {
        const voice = s.voice && s.voice !== tts.voice ? { voice: s.voice } : {};
        recorder.captions.push({ text: s.text || s.speech, speech: s.speech, time: Math.round(recorder.videoTimeMs), ...voice });
      }
      await hold((durs[i] - lead) * 1000);
      lastSpoken = true;
    } else {
      await hold(durs[i] * 1000);
      lastSpoken = false;
    }
    if (opts.lint !== false) warnings.push(...(await lintStep(s, i, durs[i] - LEAD - GAP)));
    if (opts.onStep) await opts.onStep(i, s);
  }
  // like showCaption: a wait() right after a spoken slide is absorbed by the time already waited
  if (recorder && lastSpoken) recorder.captionCredit = { waitedMs: durs[durs.length - 1] * 1000, at: Date.now() };

  const unique = [...new Set(warnings)];
  if (unique.length && opts.lint !== 'collect') {
    for (const w of unique) console.log(`[web-test] showSlide(${label(spec, opts)}) WARN ${w}`);
  }
  return { steps: built.steps.length, seconds: Math.round(total * 10) / 10, ...(unique.length ? { warnings: unique } : {}) };
}

/** Fade the slide out and remove it ({ motion: false } — at once). */
export async function hideSlide(opts = {}) {
  ensureConnected();
  musicClose(slideCue);
  slideCue = null;
  const fading = await page.evaluate(pageHide, { instant: opts.motion === false });
  if (fading) {
    await hold(550);
    await page.evaluate(pageHide, { instant: true });   // removes it, the slide's script cleaning up first
  }
  await releaseAssetsRoute(page);
}

/**
 * Check slide specs and synthesize all their phrases ahead — call before startRecording(), so the
 * recording never waits for TTS. Throws on a wrong spec (field, count past a template's limit).
 * @param {object[]} specs
 * @param {object} [opts] — TTS options as in showSlide; { validateOnly: true } — no synthesis
 * @returns {{ slides: number, phrases: number }}
 */
export async function prepareSlides(specs, opts = {}) {
  if (!Array.isArray(specs)) specs = [specs];
  const { validateOnly, ...rest } = opts;
  const tts = ttsOptions(rest);
  // a plain string — a phrase for speak() on a live page: synthesized ahead with the slides
  const phrases = specs.filter((s) => typeof s === 'string' && s.trim());
  specs = specs.filter((s) => typeof s !== 'string');
  const built = specs.map((s) => buildSlide(s));
  const plans = specs.map((s, i) => speechPlan(s, built[i], label(s, {})));   // anchors: words found, in order
  for (const s of specs) if (s.music !== undefined) resolveMusic(s.music);
  for (const s of specs) { const t = themeFor(s, rest); fontList(t.fonts); checkHeadingWeight(t); }   // a missing font file, a wrong weight fail before the recording
  for (const s of specs) for (const x of frameSpec(s, themeFor(s, rest)) || []) if (x.src) logoUrl(x.src);   // and a wrong frame
  const jobs = built.flatMap((b) => b.steps.filter((s) => s.speech).map((s) => [s.speech, s.voice ? { ...tts, voice: s.voice } : tts]));
  // a slide's one phrase and speak() phrases — with word timings (an Edge phrase cached without them is redone)
  plans.forEach((p) => { if (p) jobs.push([p.speech, { ...(p.voice ? { ...tts, voice: p.voice } : tts), words: true }]); });
  for (const t of phrases) jobs.push([t, { ...tts, words: true }]);
  if (!validateOnly) {
    // several phrases at a time (like addNarration; ElevenLabs allows fewer parallel requests), two retries each
    const width = tts.provider === 'elevenlabs' ? 2 : 5;
    let next = 0, failed = false;
    const worker = async () => {
      while (next < jobs.length && !failed) {
        const [text, o] = jobs[next++];
        for (let attempt = 0; ; attempt++) {
          try { await synthesizeCached(text, o); break; }
          catch (e) { if (attempt === 2 || failed) { failed = true; throw e; } }   // one failure stops the rest (a bad key)
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(width, jobs.length) }, worker));
  }
  return { slides: specs.length, phrases: validateOnly ? 0 : jobs.length };
}

/**
 * Import a module of slide specs (path from the project root). The same module serves the recording
 * script, `run.mjs play` and `run.mjs preview`. Re-imported on every call (edits are picked up).
 */
export async function loadSlides(path) {
  return await import(pathToFileURL(resolveProjectPath(path)).href + `?t=${Date.now()}`);
}
