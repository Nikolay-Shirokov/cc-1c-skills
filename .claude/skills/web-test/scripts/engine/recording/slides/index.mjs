// web-test recording/slides v1.0 — animated step slides: showSlide / hideSlide / prepareSlides / setSlideTheme / loadSlides.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// A slide is a template spec ({ layout, ... }) or a custom page ({ html, css, steps }). Each step is a phrase
// plus what changes on screen; a spoken step becomes a caption, so addNarration voices it exactly where its
// change happens. Step length = the phrase's real TTS length (shared phrase cache, see tts.mjs).

import { readFileSync } from 'fs';
import { join } from 'path';
import { pathToFileURL } from 'url';
import { page, recorder, ensureConnected, resolveProjectPath, projectRoot } from '../../core/state.mjs';
import { synthesizeCached, cachedSpeechSeconds, projectTtsOptions } from '../tts.mjs';
import { BASE_CSS, themeVars, pageMount, pageStep, pageHide, pageLint } from './protocol.mjs';
import { buildSlide } from './templates.mjs';

const LEAD = 0.35;   // the change starts, the voice follows
const GAP = 0.5;     // breath after a phrase

// ── theme ─────────────────────────────────────────────────────────────────
// Layers: defaults (protocol.mjs) < .v8-project.json "slides.theme" < setSlideTheme() < opts.theme < spec.theme.
let scenarioTheme = {};

/** Set the theme for the following slides: { primary, accent, ground, ink, line?, mark?, onAccent?, font? }. */
export function setSlideTheme(theme) { scenarioTheme = { ...(theme || {}) }; }

function projectSlidesTheme() {
  try {
    const cfg = JSON.parse(readFileSync(join(projectRoot, '.v8-project.json'), 'utf8'));
    return cfg.slides?.theme || {};
  } catch { return {}; }
}
const themeFor = (spec, opts) => ({ ...projectSlidesTheme(), ...scenarioTheme, ...(opts.theme || {}), ...(spec.theme || {}) });

// ── helpers ───────────────────────────────────────────────────────────────
const SLIDE_OPTS = new Set(['theme', 'motion', 'fast', 'synth', 'legacy', 'lint', 'onStep', 'label']);
function ttsOptions(opts) {
  const tts = projectTtsOptions();
  for (const [k, v] of Object.entries(opts)) if (!SLIDE_OPTS.has(k) && v !== undefined) tts[k] = v;
  return tts;
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

const estimate = (text) => Math.max(2, text.length * ((recorder?.speechRate || 70) / 1000));
const label = (spec, opts) => opts.label || spec.layout || 'page';

// Node-side rules on top of pageLint: little text, short steps, screen text ≠ narration (redundancy).
const norm = (t) => t.toLowerCase().replace(/ё/g, 'е').match(/[a-zа-я0-9]+/g) || [];
async function lintStep(step, i, seconds) {
  const r = await page.evaluate(pageLint, { showSel: step.show || null });
  const w = [...r.overflow, ...r.small.map((x) => `small font: ${x}`), ...r.longLists.map((x) => `long list ${x}`)];
  if (r.words > 70) w.push(`a lot of text on screen: ~${r.words} words`);
  if (step.speech) {
    if (seconds > 16) w.push(`long step: ~${Math.round(seconds)} s of speech — split it into steps`);
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
  const motion = (opts.motion ?? spec.motion) !== false;
  const tts = ttsOptions(opts);
  const rec = recorder;

  // step lengths
  const durs = [];
  let synthesized = 0;
  for (const s of built.steps) {
    if (opts.fast !== undefined) { durs.push(opts.fast); continue; }
    if (!s.speech) { durs.push(s.hold ?? (motion ? 0.8 : 0)); continue; }
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
  const first = rec && rec.videoTimeMs < 1000 && !onScreen;
  const instant = !motion || first;
  const vars = themeVars(themeFor(spec, opts));
  if (first) {
    // the slide's ground at once (a tiny payload), the content follows: mounting a slide with a big
    // picture takes a while, and the recording is already running
    await page.evaluate(pageMount, { html: '', css: BASE_CSS, bg: built.bg, vars, instant: true, animated: { show: [], all: [] } });
  }
  await page.evaluate(pageMount, {
    html: built.html, css: BASE_CSS + (built.css || ''), bg: built.bg, vars,
    pushSec: motion && built.push ? total : 0, animated: animatedSelectors(built.steps), instant, staticMode: !motion,
    hostId: opts.legacy || null,
  });
  await hold(instant ? 60 : 600);

  const warnings = [];
  let lastSpoken = false;
  for (let i = 0; i < built.steps.length; i++) {
    const s = built.steps[i];
    await page.evaluate(pageStep, { step: s, maxZoom: built.maxZoom ?? 2 });
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
  const fading = await page.evaluate(pageHide, { instant: opts.motion === false });
  if (fading) {
    await hold(550);
    await page.evaluate(() => document.getElementById('__ws_slide')?.remove());
  }
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
  let phrases = 0;
  const built = specs.map((s) => buildSlide(s));
  if (!validateOnly) {
    for (const b of built) {
      for (const s of b.steps) {
        if (!s.speech) continue;
        await synthesizeCached(s.speech, s.voice ? { ...tts, voice: s.voice } : tts);
        phrases++;
      }
    }
  }
  return { slides: specs.length, phrases };
}

/**
 * Import a module of slide specs (path from the project root). The same module serves the recording
 * script, `run.mjs play` and `run.mjs preview`. Re-imported on every call (edits are picked up).
 */
export async function loadSlides(path) {
  return await import(pathToFileURL(resolveProjectPath(path)).href + `?t=${Date.now()}`);
}
