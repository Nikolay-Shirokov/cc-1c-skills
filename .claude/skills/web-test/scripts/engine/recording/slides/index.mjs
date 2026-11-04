// web-test recording/slides v1.4 — animated step slides: showSlide / hideSlide / prepareSlides / setSlideTheme / loadSlides.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// A slide is a template spec ({ layout, ... }) or a custom page ({ html, css, steps }). Each step is a phrase
// plus what changes on screen; a spoken step becomes a caption, so addNarration voices it exactly where its
// change happens. Step length = the phrase's real TTS length (shared phrase cache, see tts.mjs).

import { readFileSync } from 'fs';
import { pathToFileURL } from 'url';
import { page, recorder, ensureConnected, resolveProjectPath } from '../../core/state.mjs';
import { synthesizeCached, cachedSpeechSeconds, mergeTtsOptions, readProjectConfig, unspokenWarning } from '../tts.mjs';
import { BASE_CSS, themeVars, pageMount, pageStep, pageHide, pageLint, pageScript } from './protocol.mjs';
import { ASSET_BASE, ensureAssetsRoute, releaseAssetsRoute, encodeAssetPath } from './assets.mjs';
import { buildSlide } from './templates.mjs';
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
const label = (spec, opts) => opts.label || spec.layout || 'page';

// Node-side rules on top of pageLint: little text, short steps, screen text ≠ narration (redundancy),
// speech written as spoken (no Latin words or abbreviations the voice would mispronounce).
const norm = (t) => t.toLowerCase().replace(/ё/g, 'е').match(/[a-zа-я0-9]+/g) || [];
async function lintStep(step, i, seconds) {
  const r = await page.evaluate(pageLint, { showSel: step.show || null });
  const w = [...r.overflow, ...r.small.map((x) => `small font: ${x}`), ...r.longLists.map((x) => `long list ${x}`)];
  if (r.words > 70) w.push(`a lot of text on screen: ~${r.words} words`);
  if (step.speech) {
    if (seconds > 16) w.push(`long step: ~${Math.round(seconds)} s of speech — split it into steps`);
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
  if (spec.music !== undefined) resolveMusic(spec.music);   // a wrong music spec fails before the slide
  const motion = (opts.motion ?? spec.motion) !== false;
  const tts = ttsOptions(opts);
  const rec = recorder;

  // step lengths
  const durs = [];
  let synthesized = 0;
  for (const s of built.steps) {
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
  const total = 0.6 + durs.reduce((a, d) => a + d, 0);

  // the first slide right after startRecording appears at once: the video must not open on the page under it
  const onScreen = await page.evaluate(() => !!document.getElementById('__ws_slide'));
  const first = rec && !onScreen && (rec.holdSince || rec.videoTimeMs < 1000);
  const instant = !motion || first;
  const vars = themeVars(themeFor(spec, opts));
  if (first) {
    // the slide's ground at once (a tiny payload), the content follows: mounting a slide with a big
    // picture takes a while, and the recording is already running
    // the video starts over once the ground is on screen: the page held since startRecording is dropped.
    // Hold from before the ground is mounted (its frame must not flush the page's one into the video);
    // a painted frame reaches the screencast with a lag — hence the pause (this time is not in the video).
    const held = rec._holdFrames?.();
    try {
      await page.evaluate(pageMount, { html: '', css: BASE_CSS, bg: built.bg, vars, instant: true, animated: { show: [], all: [] } });
      if (held) await page.waitForTimeout(300);
    } finally {
      if (held) rec._releaseFrames();   // a failed mount must not leave the recording holding (writing nothing)
    }
  }
  // project files (asset: in the page, slide.import/load/asset in its script) — served on this page
  // routing turns the browser cache off: on only while such a slide is up (the 1C client keeps its cache otherwise)
  const needsAssets = !!built.script || `${built.html}${built.css || ''}${built.bg || ''}`.includes(ASSET_BASE);
  if (needsAssets) await ensureAssetsRoute(page);
  await page.evaluate(pageMount, {
    html: built.html, css: BASE_CSS + (built.css || ''), bg: built.bg, vars,
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
  const built = specs.map((s) => buildSlide(s));
  for (const s of specs) if (s.music !== undefined) resolveMusic(s.music);
  const jobs = built.flatMap((b) => b.steps.filter((s) => s.speech).map((s) => [s.speech, s.voice ? { ...tts, voice: s.voice } : tts]));
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
