// web-test recording/captions v1.22 — Overlay primitives: captions, speak (a phrase with actions on its words); legacy title/image overlays over showSlide.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import {
  page, recorder, lastCaptions, ensureConnected,
} from '../core/state.mjs';
import { cachedSpeechSeconds, cachedWords, ttsCacheFile, synthesizeCached, mergeTtsOptions, unspokenWarning } from './tts.mjs';
import { showSlide, hideSlide, hold } from './slides/index.mjs';
import { anchorTimes, ON_TIME } from './anchors.mjs';
import { otherContextPages } from '../core/session.mjs';
import { softDeadline } from '../core/deadline.mjs';

// The caption is one for the session: a new one (or hideCaption) also takes the previous one off the other
// contexts' pages — it stays on the page it was shown on, and coming back there must not bring it back.
// Bounded: a closed or wedged page of another context must not hold the script.
async function clearCaptionElsewhere() {
  const pages = otherContextPages();
  if (!pages.length) return;
  await Promise.all(pages.map((pg) => softDeadline(pg.evaluate(() => document.getElementById('__web_test_caption')?.remove()), 1000, 'caption')));
}

/**
 * Show a text caption overlay on the page (visible in recording).
 * Calling again updates the text without creating a new element.
 * @param {string} text — caption text
 * @param {object} [opts]
 * @param {'top'|'bottom'} [opts.position='bottom'] — vertical position
 * @param {number} [opts.fontSize=24] — font size in pixels
 * @param {string} [opts.background='rgba(0,0,0,0.7)'] — background color
 * @param {string} [opts.color='#fff'] — text color
 * @param {string|false} [opts.speech] — TTS narration text. Omit to use displayed text,
 *   pass a string for custom narration, or false to skip narration for this caption.
 */
export async function showCaption(text, opts = {}) {
  ensureConnected();
  // before the narration's timestamp: a slow page of another context must not put the voice ahead of the plate
  await clearCaptionElsewhere();

  // Collect caption for TTS narration if recording
  let smartWaitMs = 0;
  if (recorder && (text.trim() || typeof opts.speech === 'string') && opts.speech !== false) {
    const speech = typeof opts.speech === 'string' ? opts.speech : text;
    // Use video timeline position (accounts for frame duplication) instead of wall-clock
    recorder.captions.push({ text: text || speech, speech, time: Math.round(recorder.videoTimeMs), ...(opts.voice ? { voice: opts.voice } : {}) });
    // Wait so the video has screen time for the voiceover: the phrase's real length when it is already
    // in the TTS cache (synthesized ahead, or a re-recording), otherwise an estimate
    const cached = cachedSpeechSeconds(speech, mergeTtsOptions(opts.voice ? { voice: opts.voice } : {}));
    smartWaitMs = cached != null ? Math.round(cached * 1000 + 500) : Math.max(2000, speech.length * (recorder.speechRate || 70));
    const unspoken = unspokenWarning(speech);
    if (unspoken) console.log(`[web-test] showCaption WARN ${unspoken}`);
  }
  const position = opts.position || 'bottom';
  const fontSize = opts.fontSize || 24;
  const bg = opts.background || 'rgba(0,0,0,0.7)';
  const color = opts.color || '#fff';

  await page.evaluate(({ text, position, fontSize, bg, color }) => {
    let el = document.getElementById('__web_test_caption');
    // no text — no plate (a voice-only caption): an empty one would still show its padding as a strip
    if (!text.trim()) { el?.remove(); return; }
    if (!el) {
      el = document.createElement('div');
      el.id = '__web_test_caption';
      el.style.cssText = `
        position: fixed; left: 0; right: 0; z-index: 99999;
        text-align: center; padding: 12px 24px;
        font-family: Arial, sans-serif; pointer-events: none;
      `;
      document.body.appendChild(el);
    }
    el.style[position === 'top' ? 'top' : 'bottom'] = '20px';
    el.style[position === 'top' ? 'bottom' : 'top'] = 'auto';
    el.style.fontSize = fontSize + 'px';
    el.style.background = bg;
    el.style.color = color;
    el.textContent = text;
  }, { text, position, fontSize, bg, color });

  // Smart TTS wait: pause for estimated speech duration so video has enough screen time.
  // Split into chunks and flush frames periodically — CDP doesn't send screencast frames
  // for static pages, so we must write duplicate frames to keep video timeline in sync.
  if (smartWaitMs > 0) {
    let remaining = smartWaitMs;
    while (remaining > 0) {
      const chunk = Math.min(remaining, 1000);
      await page.waitForTimeout(chunk);
      remaining -= chunk;
      if (recorder?._flushFrames) recorder._flushFrames();
    }
    recorder.captionCredit = { waitedMs: smartWaitMs, at: Date.now() };
  }
}

/**
 * Say a phrase in one take and act on its words: the phrase goes to the narration at this moment of the
 * recording; `at(word)` waits till that word sounds. For a live page (clicks while the voice goes on).
 *   const v = await speak('… функциональные блоки, бизнес-процессы …');
 *   await v.at('функциональные блоки', { lead: 0.7 }); await click(...);
 *   await v.at('end');
 * @param {string} text — the phrase, written as spoken
 * @param {object} [opts] — TTS options (voice, provider, …; default: .v8-project.json "tts"); synth: false — no TTS
 * @returns {Promise<{ seconds: number, at: (x, o?: { lead?: number }) => Promise<{ t: number, by: string, late: number }> }>}
 *   x — a word of the phrase (after the previous one), seconds from its start, 'end', or { text, shift };
 *   lead — start that many seconds before the word (a highlight first, the click on the word)
 */
export async function speak(text, opts = {}) {
  ensureConnected();
  if (typeof text !== 'string' || !text.trim()) throw new Error('speak: the phrase to say (a non-empty string)');
  const { synth, ...rest } = opts;
  const tts = mergeTtsOptions(rest);
  let seconds = cachedSpeechSeconds(text, tts);
  if (synth !== false && (seconds == null || ((tts.provider || 'edge') === 'edge' && !cachedWords(text, tts)))) {
    if (recorder) console.log('[web-test] speak WARN the phrase is synthesized during the recording (the page waits) — prepareSlides([..., phrase]) before startRecording()');
    try { seconds = (await synthesizeCached(text, { ...tts, words: true })).seconds; }
    catch (e) { console.log(`[web-test] speak WARN TTS failed, word times estimated: ${e.message}`); }
  }
  const cached = seconds != null;
  const rate = (recorder?.speechRate || 70) / 1000;
  const src = {
    words: cached ? cachedWords(text, tts) : null, file: cached ? ttsCacheFile(text, tts) : null,
    seconds: seconds ?? Math.max(2, text.length * rate), rate, ffmpegPath: tts.ffmpegPath, where: 'speak at',
  };
  const unspoken = unspokenWarning(text);
  if (unspoken) console.log(`[web-test] speak WARN ${unspoken}`);
  await clearCaptionElsewhere();
  if (recorder) recorder.captions.push({ text, speech: text, time: Math.round(recorder.videoTimeMs), ...(opts.voice ? { voice: opts.voice } : {}) });
  const clock = () => (recorder ? recorder.videoTimeMs : performance.now()) / 1000;
  const t0 = clock();
  const ats = [], warned = new Set();
  return {
    seconds: src.seconds,
    async at(x, o = {}) {
      const lead = o.lead ?? 0;
      if (typeof lead !== 'number' || !Number.isFinite(lead) || lead < 0) throw new Error('speak at: lead must be seconds ≥ 0');
      const res = anchorTimes(text, [...ats, x], src);   // words in order, after the previous ones
      ats.push(x);
      for (const w of res.warnings) if (!warned.has(w)) { warned.add(w); console.log(`[web-test] speak WARN ${w}`); }
      const { t, by } = res.times[res.times.length - 1];
      const target = t0 + t - lead;
      const ms = (target - clock()) * 1000;
      if (ms > 0) await hold(ms);
      const late = Math.max(0, clock() - target);
      if (late > ON_TIME) console.log(`[web-test] speak WARN at ${JSON.stringify(x)}: ${late.toFixed(2)} s late (the action before took longer — a bigger lead, or a later word)`);
      return { t, by, late: Math.round(late * 1000) / 1000 };
    },
  };
}

/** Remove the caption overlay from the page. */
export async function hideCaption() {
  ensureConnected();
  await clearCaptionElsewhere();
  await page.evaluate(() => {
    const el = document.getElementById('__web_test_caption');
    if (el) el.remove();
  });
}

/**
 * Get captions collected during the current or last recording.
 * @returns {Array<{text: string, speech: string, time: number}>}
 */
export function getCaptions() {
  if (recorder) return [...recorder.captions];
  return [...lastCaptions];
}


// ── Legacy full-screen overlays ────────────────────────────────────────────
// showTitleSlide / showImage keep their old look and timing, but are now special cases of showSlide
// (static, no TTS synthesis mid-recording, no checks). The animated forms: showSlide({ layout: 'title' })
// and showSlide({ layout: 'image' }) — see recording.md / slides.md.

let legacyHinted = false;
function legacyHint(name, layout) {
  if (legacyHinted) return;
  legacyHinted = true;
  console.log(`[web-test] ${name} is the legacy static form; animated: showSlide({ layout: '${layout}', ... }) — see recording.md`);
}
const escHtml = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\n/g, '<br>');

/**
 * @deprecated Legacy static title card; prefer showSlide({ layout: 'title', ... }).
 * Show a full-screen title slide overlay. Repeated calls replace the content. hideTitleSlide() removes it.
 * @param {string} text  Title text (\n → line break)
 * @param {object} [opts]
 * @param {string} [opts.subtitle]    Smaller text below the title
 * @param {string} [opts.background]  CSS background (default: dark gradient)
 * @param {string} [opts.color]       Text color (default: '#fff')
 * @param {number} [opts.fontSize]    Title font size in px (default: 36)
 * @param {string|boolean} [opts.speech] — narration (true — read the title)
 */
export async function showTitleSlide(text, opts = {}) {
  ensureConnected();
  legacyHint('showTitleSlide', 'title');
  const {
    subtitle = '',
    background = 'linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%)',
    color = '#fff',
    fontSize = 36,
    speech,
  } = opts;
  const captionText = speech && speech !== false ? (typeof speech === 'string' ? speech : text.replace(/\n/g, ' ')) : '';
  const html = `<div class="lg-box"><div class="lg-in"><div class="lg-t">${escHtml(text)}</div>`
    + (subtitle ? `<div class="lg-s">${escHtml(subtitle)}</div>` : '') + '</div></div>';
  const css = `.lg-box{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}
.lg-in{text-align:center;max-width:70%;color:${color};font-family:'Segoe UI',Arial,sans-serif}
.lg-t{font-size:calc(${fontSize}px / var(--k, 1));font-weight:600;line-height:1.4}
.lg-s{font-size:calc(${Math.round(fontSize * 0.5)}px / var(--k, 1));margin-top:calc(16px / var(--k, 1));opacity:.7}`;   // page px, as before
  await showSlide({ html, css, background, steps: captionText ? [{ speech: captionText, voice: opts.voice }] : [] },
    { motion: false, legacy: 'title', synth: false, lint: false });
}

/** @deprecated Remove the title slide (legacy pair of showTitleSlide); same as hideSlide({ motion: false }). */
export async function hideTitleSlide() {
  await hideSlide({ motion: false });
}

/**
 * @deprecated Legacy static picture; prefer showSlide({ layout: 'image', src, steps }) — it adds camera focus
 * and callouts.
 * Show a full-screen image overlay (e.g. a presentation slide screenshot).
 * Style presets: 'blur' (default) | 'dark' | 'light' | 'full'; custom `background` overrides the preset.
 * @param {string} imagePath — PNG/JPEG
 * @param {object} [opts] — { style, background, speech }
 */
export async function showImage(imagePath, opts = {}) {
  ensureConnected();
  legacyHint('showImage', 'image');
  const speech = typeof opts.speech === 'string' && opts.speech ? opts.speech : '';
  await showSlide({
    layout: 'image', src: imagePath, style: opts.style || 'blur', shadow: opts.shadow, fit: 'natural',
    background: opts.background || (opts.style === 'full' ? '#000' : undefined),
    steps: speech ? [{ speech, voice: opts.voice }] : [],
  }, { motion: false, legacy: 'image', synth: false, lint: false });
}

/** @deprecated Remove the image overlay (legacy pair of showImage); same as hideSlide({ motion: false }). */
export async function hideImage() {
  await hideSlide({ motion: false });
}
