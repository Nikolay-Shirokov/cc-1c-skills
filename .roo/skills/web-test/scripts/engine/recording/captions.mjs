// web-test recording/captions v1.17 — Overlay primitives: captions, title slides, image overlays.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { existsSync as fsExistsSync, readFileSync } from 'fs';
import { extname } from 'path';
import {
  page, recorder, lastCaptions, ensureConnected, resolveProjectPath,
} from '../core/state.mjs';

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

  // Collect caption for TTS narration if recording
  let smartWaitMs = 0;
  if (recorder && (text.trim() || typeof opts.speech === 'string') && opts.speech !== false) {
    const speech = typeof opts.speech === 'string' ? opts.speech : text;
    // Use video timeline position (accounts for frame duplication) instead of wall-clock
    recorder.captions.push({ text: text || speech, speech, time: Math.round(recorder.videoTimeMs), ...(opts.voice ? { voice: opts.voice } : {}) });
    // Estimate TTS duration and wait so the video has enough screen time for voiceover
    smartWaitMs = Math.max(2000, speech.length * (recorder.speechRate || 70));
  }
  const position = opts.position || 'bottom';
  const fontSize = opts.fontSize || 24;
  const bg = opts.background || 'rgba(0,0,0,0.7)';
  const color = opts.color || '#fff';

  await page.evaluate(({ text, position, fontSize, bg, color }) => {
    let el = document.getElementById('__web_test_caption');
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

/** Remove the caption overlay from the page. */
export async function hideCaption() {
  ensureConnected();
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

/**
 * Show a full-screen title slide overlay (for video recordings).
 * Repeated calls update the content. Use hideTitleSlide() to remove.
 * @param {string} text  Title text (\n → line break)
 * @param {object} [opts]
 * @param {string} [opts.subtitle]    Smaller text below the title
 * @param {string} [opts.background]  CSS background (default: dark gradient)
 * @param {string} [opts.color]       Text color (default: '#fff')
 * @param {number} [opts.fontSize]    Title font size in px (default: 36)
 */
export async function showTitleSlide(text, opts = {}) {
  ensureConnected();
  const {
    subtitle = '',
    background = 'linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%)',
    color = '#fff',
    fontSize = 36,
    speech,
  } = opts;

  // Collect caption for TTS narration if recording
  let smartWaitMs = 0;
  if (recorder && speech && speech !== false) {
    const captionText = typeof speech === 'string' ? speech : text.replace(/\n/g, ' ');
    if (captionText) {
      recorder.captions.push({ text: captionText, speech: captionText, time: Math.round(recorder.videoTimeMs), ...(opts.voice ? { voice: opts.voice } : {}) });
      smartWaitMs = Math.max(2000, captionText.length * (recorder.speechRate || 70));
    }
  }

  await page.evaluate(({ text, subtitle, background, color, fontSize }) => {
    let div = document.getElementById('__web_test_title');
    if (!div) {
      div = document.createElement('div');
      div.id = '__web_test_title';
      document.body.appendChild(div);
    }
    div.style.cssText = [
      'position:fixed', 'top:0', 'left:0', 'width:100%', 'height:100%',
      `background:${background}`,
      'display:flex', 'align-items:center', 'justify-content:center',
      'z-index:999999', 'pointer-events:none',
    ].join(';');
    // Remove other overlays to prevent flash between slides
    const img = document.getElementById('__web_test_image');
    if (img) img.remove();
    const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/\n/g, '<br>');
    let html = `<div style="font-size:${fontSize}px;font-weight:600;line-height:1.4;">${esc(text)}</div>`;
    if (subtitle) {
      html += `<div style="font-size:${Math.round(fontSize * 0.5)}px;margin-top:16px;opacity:0.7;">${esc(subtitle)}</div>`;
    }
    div.innerHTML = `<div style="text-align:center;max-width:70%;color:${color};font-family:'Segoe UI',Arial,sans-serif;">${html}</div>`;
  }, { text, subtitle, background, color, fontSize });

  // Smart TTS wait (same pattern as showCaption/showImage)
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

/** Remove the title slide overlay. */
export async function hideTitleSlide() {
  ensureConnected();
  await page.evaluate(() => {
    const el = document.getElementById('__web_test_title');
    if (el) el.remove();
  });
}

/**
 * Show a full-screen image overlay (e.g. presentation slide screenshot).
 * Reads the image file, base64-encodes it, and renders as a fixed overlay
 * on the page — captured by CDP screencast automatically.
 *
 * Style presets:
 *   - 'blur'  (default) — blurred+dimmed copy as background, image centered with shadow
 *   - 'dark'  — dark background (#2a2a2a) with shadow
 *   - 'light' — white background with shadow
 *   - 'full'  — image covers entire screen, no padding/shadow
 *
 * Custom background overrides the preset (e.g. background: '#003366').
 *
 * @param {string} imagePath — path to the image file (PNG, JPG, etc.)
 * @param {object} [opts]
 * @param {'blur'|'dark'|'light'|'full'} [opts.style='blur'] — display style preset
 * @param {string} [opts.background] — custom background color/gradient (overrides style preset)
 * @param {boolean} [opts.shadow] — show drop shadow (default: true for blur/dark/light, false for full)
 * @param {string|false} [opts.speech] — TTS narration text while image is shown.
 *   Pass a string for narration, or false to skip. Omit to skip (no auto-text for images).
 */
export async function showImage(imagePath, opts = {}) {
  ensureConnected();
  const style = opts.style || 'blur';
  const speech = opts.speech;

  // Style presets
  const presets = {
    blur:  { bg: '#222',    fit: 'contain', shadow: true,  blur: true  },
    dark:  { bg: '#2a2a2a', fit: 'contain', shadow: true,  blur: false },
    light: { bg: '#ffffff', fit: 'contain', shadow: true,  blur: false },
    full:  { bg: '#000',    fit: 'contain', shadow: false, blur: false },
  };
  const preset = presets[style] || presets.blur;

  const bg      = opts.background || preset.bg;
  const fit     = preset.fit;
  const shadow  = opts.shadow !== undefined ? opts.shadow : preset.shadow;
  const useBlur = opts.background ? false : preset.blur;

  // Read image and base64-encode
  const absPath = resolveProjectPath(imagePath);
  if (!fsExistsSync(absPath)) {
    throw new Error(`showImage: file not found: ${absPath}`);
  }
  const buf = readFileSync(absPath);
  const ext = extname(absPath).toLowerCase().replace('.', '');
  const mime = ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg'
    : ext === 'png' ? 'image/png'
    : ext === 'gif' ? 'image/gif'
    : ext === 'webp' ? 'image/webp'
    : ext === 'svg' ? 'image/svg+xml'
    : 'image/png';
  const dataUrl = `data:${mime};base64,${buf.toString('base64')}`;

  // Collect caption for TTS narration if recording
  let smartWaitMs = 0;
  if (recorder && speech && speech !== false) {
    const captionText = typeof speech === 'string' ? speech : '';
    if (captionText) {
      recorder.captions.push({ text: captionText, speech: captionText, time: Math.round(recorder.videoTimeMs), ...(opts.voice ? { voice: opts.voice } : {}) });
      smartWaitMs = Math.max(2000, captionText.length * (recorder.speechRate || 70));
    }
  }

  // Padding: full style uses 100%, others use 92% for breathing room
  const isFull = style === 'full';
  const maxSize = isFull ? '100%' : '92%';

  await page.evaluate(({ dataUrl, fit, bg, useBlur, shadow, maxSize, isFull }) => {
    let div = document.getElementById('__web_test_image');
    if (!div) {
      div = document.createElement('div');
      div.id = '__web_test_image';
      document.body.appendChild(div);
    }
    // Remove other overlays to prevent flash between slides
    const title = document.getElementById('__web_test_title');
    if (title) title.remove();

    div.style.cssText = [
      'position:fixed', 'top:0', 'left:0', 'width:100%', 'height:100%',
      `background:${bg}`,
      'display:flex', 'align-items:center', 'justify-content:center',
      'z-index:999999', 'pointer-events:none', 'overflow:hidden'
    ].join(';');

    let html = '';

    // Blurred background layer: the same image stretched to cover, blurred and dimmed
    if (useBlur) {
      html += `<img src="${dataUrl}" style="position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover;filter:blur(30px) brightness(0.5);transform:scale(1.1);" />`;
    }

    // Main image
    const shadowCss = shadow ? 'box-shadow:0 4px 40px rgba(0,0,0,0.5);' : '';
    const sizeCss = isFull
      ? `width:100%;height:100%;object-fit:${fit};`
      : `max-width:${maxSize};max-height:${maxSize};min-width:50%;min-height:50%;object-fit:${fit};`;
    html += `<img src="${dataUrl}" style="position:relative;${sizeCss}${shadowCss}" />`;

    div.innerHTML = html;
  }, { dataUrl, fit, bg, useBlur, shadow, maxSize, isFull });

  // Smart TTS wait (same pattern as showCaption)
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

/** Remove the image overlay. */
export async function hideImage() {
  ensureConnected();
  await page.evaluate(() => {
    const el = document.getElementById('__web_test_image');
    if (el) el.remove();
  });
}
