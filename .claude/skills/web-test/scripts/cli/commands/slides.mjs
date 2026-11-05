// web-test cli/commands/slides v1.4 — play / preview: slides without 1C (blank Chromium page 1920×1080)
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// A slides module: `export default [spec, ...]`, optional `export const tts = {...}` and `export const theme = {...}`.
//   play <slides.mjs> --out=<file.mp4> [--no-narration] [--music=<preset|file>]   record + narrate into --out (starts and ends on a slide);
//                                             <file>.captions.json next to it; --no-narration: silent video
//   preview <slides.mjs> [--out-dir=<dir>]    a PNG per step + checks, no TTS, no video
import { mkdirSync, renameSync } from 'fs';
import { basename, dirname, join, resolve } from 'path';
import { pathToFileURL } from 'url';
import { chromium } from 'playwright';
import * as browser from '../../browser.mjs';
import { setBrowser, setPage } from '../../engine/core/state.mjs';
import { projectTtsOptions } from '../../engine/recording/tts.mjs';
import { resolveMusic, PRESETS } from '../../engine/recording/music.mjs';
import { out, die } from '../util.mjs';

async function loadModule(file) {
  if (!file) die('Usage: run.mjs play <slides.mjs> --out=<file.mp4> | run.mjs preview <slides.mjs> [--out-dir=<dir>]');
  const abs = resolve(file);
  let mod;
  try { mod = await import(pathToFileURL(abs).href); }
  catch (e) { die(`Cannot load slides module ${abs}: ${e.message}`); }
  const slides = mod.default;
  if (!Array.isArray(slides) || !slides.length) die(`${abs}: default export must be a non-empty array of slide specs`);
  return { abs, slides, tts: { ...projectTtsOptions(), ...(mod.tts || {}) }, theme: mod.theme };
}

async function withBlankPage(fn) {
  // --enable-gpu: WebGL on the graphics card (3D in a page script); without one Chromium falls back to software
  const b = await chromium.launch({ headless: true, args: ['--enable-gpu'] });
  try {
    const ctx = await b.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    await page.setContent('<!doctype html><html><body style="margin:0;background:#000"></body></html>');
    setBrowser(b);
    setPage(page);
    return await fn(page);
  } finally {
    setPage(null);
    setBrowser(null);
    await b.close().catch(() => {});
  }
}

const fail = (e) => die(e?.message || String(e));

export async function cmdPlay(file, outFile, { narrate = true, music } = {}) {
  const { slides, tts, theme } = await loadModule(file);
  if (!outFile) die('play: --out=<file.mp4> is required');
  try {
    // a file in --music is from the current directory, like --out and the module (specs' paths are from the project root)
    if (music !== undefined && !PRESETS[music]) music = resolve(music);
    if (music !== undefined) resolveMusic(music);
    if (theme) browser.setSlideTheme(theme);
    await browser.prepareSlides(slides, { ...tts, validateOnly: !narrate });   // validate (+ synthesize ahead)
    const res = await withBlankPage(async () => {
      const warnings = [];
      const target = resolve(outFile);
      await browser.startRecording(target);
      let video, failure = null;
      try {
        for (let n = 0; n < slides.length; n++) {
          const r = await browser.showSlide(slides[n], { ...tts, lint: 'collect', ...(narrate ? {} : { synth: false }) });
          warnings.push(...(r.warnings || []).map((w) => `slide ${n + 1} (${slides[n].layout || 'page'}) ${w}`));
        }
      } catch (e) { failure = e; }
      // stopped on a failure too (ends on the last slide); the slide's error, not ffmpeg's, is the one to report
      try { video = await browser.stopRecording(); } catch (e) { if (!failure) throw e; }
      if (failure) throw failure;
      const withMusic = music !== undefined || !!video.music;
      if (narrate && !video.captions) warnings.push('no spoken steps — the video has no narration');
      if ((!narrate || !video.captions) && !withMusic) {
        return { ok: true, file: video.file, duration: video.duration, captions: video.captions, warnings };
      }
      // --out is the final narrated video; the silent recording is replaced, its captions.json stays next to it
      const tmp = target.replace(/(\.[^.\\/]+)?$/, '.narrating$1');
      // --no-narration with music: the music alone (no TTS calls)
      const narrated = await browser.addNarration(video.file, {
        ...tts, outputPath: tmp, ...(music !== undefined ? { music } : {}), ...(narrate ? {} : { captions: [] }),
      });
      let file = target;
      try { renameSync(tmp, target); }
      catch (e) {
        file = tmp;
        warnings.push(`could not replace ${target} (${e.code || e.message}) — the narrated video is ${tmp}`);
      }
      return { ok: true, file, duration: narrated.duration, captions: video.captions,
        warnings: [...warnings, ...(narrated.warnings || [])] };
    });
    out(res);
  } catch (e) { fail(e); }
}

export async function cmdPreview(file, outDir) {
  const { abs, slides, tts, theme } = await loadModule(file);
  const dir = resolve(outDir || join(dirname(abs), basename(abs).replace(/\.[^.]+$/, '') + '-preview'));
  try {
    if (theme) browser.setSlideTheme(theme);
    await browser.prepareSlides(slides, { validateOnly: true });
    mkdirSync(dir, { recursive: true });
    const res = await withBlankPage(async (page) => {
      const warnings = [], shots = [];
      for (let n = 0; n < slides.length; n++) {
        const r = await browser.showSlide(slides[n], {
          ...tts, fast: 1.6, lint: 'collect',
          onStep: async (i) => { const f = join(dir, `${n + 1}-${i + 1}.png`); await page.screenshot({ path: f }); shots.push(f); },
        });
        warnings.push(...(r.warnings || []).map((w) => `slide ${n + 1} (${slides[n].layout || 'page'}) ${w}`));
      }
      return { ok: true, dir, shots: shots.length, warnings };
    });
    out(res);
  } catch (e) { fail(e); }
}
