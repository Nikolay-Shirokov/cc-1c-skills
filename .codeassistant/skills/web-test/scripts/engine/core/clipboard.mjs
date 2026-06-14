// web-test engine/core/clipboard v1.17 — OS-clipboard preservation around trusted paste.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// pasteText() — the only path 1C respects for autocomplete and Cyrillic input.
// saveClipboard/restoreClipboard preserve full clipboard contents (all MIME
// types) around the writeText+Ctrl+V pair so a user's concurrent Ctrl+C isn't
// clobbered. Blobs are stashed on `window` to avoid CDP serialization.

import {
  page, preserveClipboard, clipboardWarnLogged, setClipboardWarnLogged,
} from './state.mjs';

export async function saveClipboard() {
  if (!page) return;
  try {
    await page.evaluate(async () => {
      try {
        const items = await navigator.clipboard.read();
        const saved = [];
        for (const item of items) {
          const types = {};
          for (const t of item.types) types[t] = await item.getType(t);
          saved.push(types);
        }
        window.__webTestSavedClipboard = saved;
        delete window.__webTestClipboardError;
      } catch (e) {
        window.__webTestSavedClipboard = null;
        window.__webTestClipboardError = e?.name || String(e);
      }
    });
  } catch {
    // page.evaluate itself failed (closed page, navigation in flight) — skip.
  }
}

export async function restoreClipboard() {
  if (!page) return;
  let err = null;
  try {
    err = await page.evaluate(async () => {
      const saved = window.__webTestSavedClipboard;
      const captured = window.__webTestClipboardError || null;
      delete window.__webTestSavedClipboard;
      delete window.__webTestClipboardError;
      try {
        if (!saved || saved.length === 0) {
          // Save failed (e.g. CF_HDROP from Explorer not readable via Clipboard API)
          // or buffer was empty. Either way, the test's writeText already destroyed
          // any prior native formats in the OS clipboard, so explicitly clear here
          // to avoid leaking the test value into the user's clipboard.
          await navigator.clipboard.writeText('');
          return captured;
        }
        const items = saved.map(types => new ClipboardItem(types));
        await navigator.clipboard.write(items);
        return null;
      } catch (e) {
        return e?.name || String(e);
      }
    });
  } catch {
    return;
  }
  if (err && !clipboardWarnLogged) {
    setClipboardWarnLogged(true);
    console.error(`[web-test] clipboard preserve skipped: ${err} (logged once per session)`);
  }
}

/**
 * Paste `text` via OS clipboard (the only trusted-paste path that 1C respects
 * for autocomplete and Cyrillic). Wraps the writeText+confirm-key pair in a
 * narrow save/restore so a user's clipboard survives the test run — the window
 * between save and restore is microseconds.
 *
 * - `confirm` — key (string) or sequence (array) to press after writeText.
 *   Defaults to 'Control+V'. Use ['Control+a', 'Control+v'] for select-all-then-paste,
 *   or 'Shift+F11' for the goto-link dialog.
 * - `postDelay` — ms to wait between confirm-press and restore, for dialogs
 *   that read clipboard asynchronously (e.g. Shift+F11). Default 0.
 */
export async function pasteText(text, { confirm = 'Control+V', postDelay = 0 } = {}) {
  if (!page) return;
  if (preserveClipboard) await saveClipboard();
  try {
    await page.evaluate(`navigator.clipboard.writeText(${JSON.stringify(String(text))})`);
    if (Array.isArray(confirm)) {
      for (const key of confirm) await page.keyboard.press(key);
    } else if (confirm) {
      await page.keyboard.press(confirm);
    }
    if (postDelay) await page.waitForTimeout(postDelay);
  } finally {
    if (preserveClipboard) await restoreClipboard();
  }
}
