// web-test forms/file-dialog v1.0 — File selection after a click: 1C "Выбор файлов" dialog (browser file chooser) or the native dialog of the 1C file system extension.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { spawn } from 'child_process';
import { existsSync, statSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { page, resolveProjectPath } from '../core/state.mjs';
import { detectFormScript } from '../../dom.mjs';
import { waitForStable } from '../core/wait.mjs';
import { returnFormState } from '../core/helpers.mjs';

/** Page expression: 1C "Выбор файлов" dialog is open. */
export const HTML_FILE_DIALOG_VISIBLE = `(() => {
  const ok = document.querySelector('#fileSelectDialogOk');
  return ok && ok.offsetWidth > 0 ? true : false;
})()`;

const WIN_HELPER = join(dirname(fileURLToPath(import.meta.url)), '..', 'os', 'win-file-dialog.ps1');

/** In an open "Выбор файлов" dialog: "выберите с диска" → browser file chooser → file → OK. */
export async function selectFileInHtmlDialog(absPath, formBefore) {
  let fileChooser;
  try {
    [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser', { timeout: 5000 }),
      page.click('a.underline.pointer'),
    ]);
  } catch (e) {
    // Try closing the dialog before throwing
    await page.keyboard.press('Escape');
    throw new Error(`File chooser did not appear: ${e.message}`);
  }
  await fileChooser.setFiles(absPath);
  await page.waitForTimeout(500);
  await page.click('#fileSelectDialogOk');
  await waitForStable(formBefore);
}

// The native dialog lives in the extension's own process, out of Playwright's reach. A helper
// waits for it and fills it; started before the click, so its startup overlaps the click.
// Windows only for now — elsewhere null.
function startNativeHelper(path, timeoutMs) {
  if (process.platform !== 'win32') return null;
  const ps = spawn('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', WIN_HELPER,
    '-Path', path, '-TimeoutMs', String(timeoutMs),
  ], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let out = '', err = '';
  ps.stdout.on('data', d => { out += d; });
  ps.stderr.on('data', d => { err += d; });
  const done = new Promise(resolve => {
    ps.on('error', e => resolve(`FAILED ${e.message}`));
    ps.on('close', () => resolve(out.trim().split(/\r?\n/).pop()
      || `FAILED ${err.trim().split(/\r?\n/)[0] || 'helper exited without a result'}`));
  });
  return { done, kill: () => { try { ps.kill(); } catch {} } };
}

/**
 * Click (doClick), then answer the file selection dialog it opens with `file`.
 * Returns form state with { clicked, file: { path, via: 'html' | 'native' } }.
 */
export async function withFileSelection(file, doClick, { timeout } = {}) {
  const absPath = resolveProjectPath(String(file).replace(/\\/g, '/'));
  if (!existsSync(absPath)) throw new Error(`clickElement: file or folder not found: ${absPath}`);
  const waitMs = timeout ?? 10000;
  // The helper starts before the click, our deadline after it: give it slack, finally kills it anyway
  const native = startNativeHelper(absPath.replace(/\//g, '\\'), waitMs + 60000);
  try {
    const formBefore = await page.evaluate(detectFormScript());
    const clicked = (await doClick())?.clicked;
    let nativeResult = null;
    native?.done.then(r => { nativeResult = r; });

    const deadline = Date.now() + waitMs;
    while (Date.now() < deadline) {
      if (await page.evaluate(HTML_FILE_DIALOG_VISIBLE)) {
        if (statSync(absPath).isDirectory()) {
          await page.keyboard.press('Escape');
          throw new Error('clickElement: the 1C «Выбор файлов» dialog takes files only — a folder needs the 1C file system extension');
        }
        await selectFileInHtmlDialog(absPath, formBefore);
        return returnFormState({ clicked, file: { path: absPath, via: 'html' } });
      }
      if (nativeResult === 'FILLED') {
        // The extension hands the file to the web client asynchronously
        await page.waitForTimeout(500);
        await waitForStable(formBefore);
        return returnFormState({ clicked, file: { path: absPath, via: 'native' } });
      }
      if (nativeResult?.startsWith('FAILED')) {
        throw new Error(`clickElement: native file dialog: ${nativeResult.slice('FAILED '.length)}`);
      }
      await page.waitForTimeout(200);
    }
    const unsupported = process.platform === 'win32' ? ''
      : ` (native file dialogs of the 1C file system extension are not supported on ${process.platform} yet)`;
    throw new Error(`clickElement: no file selection dialog appeared after the click within ${waitMs} ms${unsupported}`);
  } finally {
    native?.kill();
  }
}
