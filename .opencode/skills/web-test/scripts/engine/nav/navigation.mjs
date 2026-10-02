// web-test nav/navigation v1.17 — Section navigation, openCommand, switchTab, navigateLink (Shift+F11), openFile.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import {
  page, ensureConnected, highlightMode, resolveProjectPath,
} from '../core/state.mjs';
import {
  readSectionsScript, readTabsScript, readCommandsScript,
  navigateSectionScript, openCommandScript, switchTabScript,
  detectFormScript,
} from '../../dom.mjs';
import { dismissPendingErrors, checkForErrors } from '../core/errors.mjs';
import { waitForStable, waitForCondition } from '../core/wait.mjs';
import { highlight, unhighlight } from '../recording/highlight.mjs';
import { returnFormState } from '../core/helpers.mjs';
// Static import — ESM cycle that resolves at call time.
import { pasteText } from '../core/clipboard.mjs';
import { getFormState } from '../forms/state.mjs';

/**
 * Get current page state: active section, tabs.
 * Combined into a single evaluate call.
 */
export async function getPageState() {
  ensureConnected();
  const { sections, tabs } = await page.evaluate(`({
    sections: ${readSectionsScript()},
    tabs: ${readTabsScript()}
  })`);
  const activeSection = sections.find(s => s.active)?.name || null;
  const activeTab = tabs.find(t => t.active)?.name || null;
  return { activeSection, activeTab, sections, tabs };
}

/** Read section panel + commands in a single evaluate call. */
export async function getSections() {
  ensureConnected();
  const { sections, commands } = await page.evaluate(`({
    sections: ${readSectionsScript()},
    commands: ${readCommandsScript()}
  })`);
  const activeSection = sections.find(s => s.active)?.name || null;
  return { activeSection, sections, commands };
}

/** Navigate to a section by name. Returns new state with commands. */
export async function navigateSection(name) {
  ensureConnected();
  await dismissPendingErrors();
  if (highlightMode) try { await highlight(name); await page.waitForTimeout(500); await unhighlight(); } catch {}
  const result = await page.evaluate(navigateSectionScript(name));
  if (result?.error) {
    const avail = result.available?.filter(Boolean);
    if (avail?.length === 0) throw new Error(`navigateSection: "${name}" not found. Section panel is in icon-only mode — text labels are hidden. Switch to "Text" or "Picture and text" display mode in 1C settings (View → Section Panel → Display Mode)`);
    throw new Error(`navigateSection: "${name}" not found. Available: ${avail?.join(', ') || 'none'}`);
  }

  await waitForStable();
  const { sections, commands } = await page.evaluate(`({
    sections: ${readSectionsScript()},
    commands: ${readCommandsScript()}
  })`);
  return returnFormState({ navigated: result, sections, commands });
}

/** Read commands of the current section. */
export async function getCommands() {
  ensureConnected();
  return await page.evaluate(readCommandsScript());
}

/** Open a command from function panel by name. Returns new form state. */
export async function openCommand(name) {
  ensureConnected();
  await dismissPendingErrors();
  if (highlightMode) try { await highlight(name); await page.waitForTimeout(500); await unhighlight(); } catch {}
  const formBefore = await page.evaluate(detectFormScript());
  const result = await page.evaluate(openCommandScript(name));
  if (result?.error) throw new Error(`openCommand: "${name}" not found. Available: ${result.available?.join(', ') || 'none'}`);

  await waitForStable(formBefore);
  return await returnFormState();
}

/** Switch to an open tab by name (fuzzy match). Returns updated form state. */
export async function switchTab(name) {
  ensureConnected();
  const result = await page.evaluate(switchTabScript(name));
  if (result?.error) throw new Error(`switchTab: "${name}" not found. Available: ${result.available?.join(', ') || 'none'}`);
  await waitForStable();
  return returnFormState();
}

// English → Russian metadata type mapping for e1cib navigation links
const E1CIB_TYPE_MAP = {
  'catalog': 'Справочник', 'catalogs': 'Справочник',
  'document': 'Документ', 'documents': 'Документ',
  'commonmodule': 'ОбщийМодуль',
  'enum': 'Перечисление', 'enums': 'Перечисление',
  'dataprocessor': 'Обработка', 'dataprocessors': 'Обработка',
  'report': 'Отчет', 'reports': 'Отчет',
  'accumulationregister': 'РегистрНакопления',
  'informationregister': 'РегистрСведений',
  'accountingregister': 'РегистрБухгалтерии',
  'calculationregister': 'РегистрРасчета',
  'chartofaccounts': 'ПланСчетов',
  'chartofcharacteristictypes': 'ПланВидовХарактеристик',
  'chartofcalculationtypes': 'ПланВидовРасчета',
  'businessprocess': 'БизнесПроцесс',
  'task': 'Задача',
  'exchangeplan': 'ПланОбмена',
  'constant': 'Константа',
};

// Types that open via e1cib/app/ (reports and data processors have their own app forms)
const E1CIB_APP_TYPES = new Set(['Отчет', 'Обработка']);

function normalizeE1cibUrl(url) {
  // Already a full e1cib link
  if (url.startsWith('e1cib/')) return url;
  // "ТипОбъекта.Имя" or "EnglishType.Имя" — translate type, pick list/ or app/ prefix
  const dot = url.indexOf('.');
  if (dot > 0) {
    const typePart = url.substring(0, dot);
    const namePart = url.substring(dot + 1);
    const ruType = E1CIB_TYPE_MAP[typePart.toLowerCase()] || typePart;
    const prefix = E1CIB_APP_TYPES.has(ruType) ? 'e1cib/app' : 'e1cib/list';
    return `${prefix}/${ruType}.${namePart}`;
  }
  return `e1cib/list/${url}`;
}

/**
 * Open an external data processor or report (EPF/ERF) via File → Open menu.
 * Handles the security confirmation dialog on first open.
 * @param {string} filePath - path to EPF/ERF file (absolute or relative to cwd)
 * @returns {Promise<object>} form state of the opened processor/report
 */
export async function openFile(filePath) {
  ensureConnected();
  await dismissPendingErrors();
  const absPath = resolveProjectPath(filePath.replace(/\\/g, '/'));

  const MAX_ATTEMPTS = 2; // 1st may trigger security dialog, 2nd is the real open
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const formBefore = await page.evaluate(detectFormScript());

    // 1. Ctrl+O opens 1C's "Выбор файлов" dialog
    await page.keyboard.press('Control+o');

    // 2. Wait for the file selection dialog
    const dialogOk = await waitForCondition(`(() => {
      const ok = document.querySelector('#fileSelectDialogOk');
      return ok && ok.offsetWidth > 0 ? true : false;
    })()`, 3000);
    if (!dialogOk) throw new Error("File selection dialog did not open (Ctrl+O)");

    // 3. Click "выберите с диска" to trigger the native OS file picker
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

    // 4. Set the file path and click OK
    await fileChooser.setFiles(absPath);
    await page.waitForTimeout(500);
    await page.click('#fileSelectDialogOk');
    await waitForStable(formBefore);

    // 5. Check for security dialog
    const err = await checkForErrors();
    if (err?.confirmation) {
      // Security confirmation — click the positive button (Продолжить/Да/OK)
      const positiveBtn = err.confirmation.buttons.find(b =>
        /продолжить|да|ok|yes|открыть/i.test(b)
      ) || err.confirmation.buttons[0];
      if (positiveBtn) {
        const btns = await page.$$(`#form${err.confirmation.formNum}_container a.press.pressButton`);
        for (const b of btns) {
          const txt = (await b.textContent())?.trim();
          if (txt === positiveBtn) { await b.click(); break; }
        }
        await waitForStable(formBefore);
      }
      // After confirmation, check if EPF form appeared or a follow-up dialog showed.
      // Check form change FIRST — avoids confusing a small EPF form with a modal dialog.
      const formAfter = await page.evaluate(detectFormScript());
      if (formAfter != null && formAfter !== formBefore) {
        // New form appeared — but is it the EPF or an informational dialog?
        // Informational "re-open" dialogs are tiny (< 20 elements).
        const elCount = await page.evaluate(`document.querySelectorAll('[id^="form${formAfter}_"]').length`);
        if (elCount < 20) {
          // Likely an info dialog — check and dismiss
          const err2 = await checkForErrors();
          if (err2?.modal) {
            await dismissPendingErrors();
            await waitForStable(formBefore);
            continue; // retry open cycle
          }
        }
        // It's the real EPF form
        return returnFormState({ opened: { file: absPath, attempt: attempt + 1 } });
      }
      // Form didn't appear — retry
      continue;
    }

    // No security dialog — check if form appeared
    if (err?.modal) {
      throw new Error(`Error opening file: ${err.modal.message}`);
    }
    const formAfter = await page.evaluate(detectFormScript());
    if (formAfter != null && formAfter !== formBefore) {
      const state = await getFormState();
      state.opened = { file: absPath, attempt: attempt + 1 };
      return state;
    }
  }

  throw new Error(`Form did not open after ${MAX_ATTEMPTS} attempts for: ${absPath}`);
}

/** Navigate to a 1C navigation link via Shift+F11 dialog. Returns new form state. */
export async function navigateLink(url) {
  ensureConnected();
  await dismissPendingErrors();
  const link = normalizeE1cibUrl(url);
  const formBefore = await page.evaluate(detectFormScript());

  // Copy link to clipboard, press Shift+F11 (opens "Go to link" dialog with clipboard content)
  await pasteText(link, { confirm: 'Shift+F11', postDelay: 200 });
  await waitForStable();

  // Click "Перейти" in the navigation dialog
  const dialog = await page.evaluate(detectFormScript());
  if (dialog != null && dialog !== formBefore) {
    const btns = await page.$$(`#form${dialog}_container a.press`);
    for (const b of btns) {
      const txt = (await b.textContent())?.trim();
      if (txt === 'Перейти') { await b.click(); break; }
    }
  }

  await waitForStable(formBefore);
  return await returnFormState();
}
