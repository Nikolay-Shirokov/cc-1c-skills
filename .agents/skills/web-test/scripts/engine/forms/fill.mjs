// web-test forms/fill v1.21 — Fill form fields by name (text/checkbox/date/number/dropdown/reference; array → multi-select via selectValue). Delegates references to selectValue / fillReferenceField.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import {
  page, ensureConnected, ACTION_WAIT, highlightMode, normYo,
} from '../core/state.mjs';
import {
  detectFormScript, resolveFieldsScript,
} from '../../dom.mjs';
import { dismissPendingErrors, checkForErrors } from '../core/errors.mjs';
import { waitForStable, startNetworkMonitor } from '../core/wait.mjs';
import { highlight, unhighlight } from '../recording/highlight.mjs';
import {
  fillReferenceField, selectValue, pickFromSelectionForm,
  isTypeDialog, pickFromTypeDialog,
} from './select-value.mjs';
import { pasteText } from '../core/clipboard.mjs';
import { returnFormState } from '../core/helpers.mjs';

/** Fill fields on the current form via Playwright page.fill(). Returns fill results + updated form. */
export async function fillFields(fields) {
  ensureConnected();
  await dismissPendingErrors();
  const formNum = await page.evaluate(detectFormScript());
  if (formNum === null) throw new Error('fillFields: no form found');

  // Resolve field names to element IDs
  const resolved = await page.evaluate(resolveFieldsScript(formNum, fields));
  const results = [];

  for (const r of resolved) {
    if (r.error) {
      results.push(r);
      continue;
    }
    // Disabled field: filling/toggling it is a silent no-op in 1C. Fail loud via the
    // standard failure aggregation below instead of reporting a fake success.
    if (r.disabled) {
      results.push({ field: r.field, error: 'disabled', message: `field "${r.field}" is disabled` });
      continue;
    }
    // Array value → multi-select. Delegate to selectValue's array branch (auto-detects
    // the surface) so fillFields({field:[...]}) works the same as selectValue(field,[...]).
    if (Array.isArray(fields[r.field])) {
      const sv = await selectValue(r.field, fields[r.field]);
      const sel = sv.selected || {};
      if (sel.error) {
        results.push({ field: r.field, error: sel.error });
      } else {
        const res = { field: r.field, ok: true, values: sel.values || [], method: 'multi-select' };
        if (sel.notSelected?.length) res.notSelected = sel.notSelected;
        results.push(res);
      }
      continue;
    }
    // Auto-highlight the field input before filling
    if (highlightMode && r.inputId) {
      try {
        await page.evaluate(({ id }) => {
          const target = document.getElementById(id);
          if (!target) return;
          let div = document.getElementById('__web_test_highlight');
          if (!div) { div = document.createElement('div'); div.id = '__web_test_highlight'; document.body.appendChild(div); }
          const r = target.getBoundingClientRect();
          div.style.cssText = 'position:fixed;pointer-events:none;z-index:999998;top:' + (r.y-4) + 'px;left:' + (r.x-4) + 'px;width:' + (r.width+8) + 'px;height:' + (r.height+8) + 'px;outline:3px solid #e74c3c;border-radius:4px;box-shadow:0 0 16px #e74c3c80';
        }, { id: r.inputId });
        await page.waitForTimeout(500);
        await unhighlight();
      } catch {}
    }
    try {
      // Auto-enable DCS checkbox if resolved via label
      if (r.dcsCheckbox && !r.dcsCheckbox.checked) {
        await page.click(`[id="${r.dcsCheckbox.inputId}"]`);
        await waitForStable();
      }
      const selector = `[id="${r.inputId}"]`;
      // Clear field via Shift+F4 if value is empty (not applicable to checkbox/radio)
      const rawValue = fields[r.field];
      const isEmpty = rawValue === '' || rawValue === null || rawValue === undefined;
      if (isEmpty && !r.isCheckbox && !r.isRadio) {
        await page.click(selector);
        await page.waitForTimeout(200);
        await page.keyboard.press('Shift+F4');
        await page.waitForTimeout(300);
        await page.keyboard.press('Tab');
        await waitForStable();
        results.push({ field: r.field, ok: true, value: '', method: 'clear' });
        continue;
      }
      if (r.isCheckbox) {
        // Checkbox: compare desired with current, toggle if mismatch
        const desired = String(fields[r.field]).toLowerCase();
        const wantChecked = ['true', '1', 'да', 'yes', 'on'].includes(desired);
        if (wantChecked !== r.checked) {
          await page.click(selector);
          await waitForStable();
        }
        results.push({ field: r.field, ok: true, value: String(wantChecked), method: 'toggle' });
      } else if (r.isRadio) {
        // Radio button: find option by label (fuzzy match) and click it
        const desired = normYo(String(fields[r.field]).toLowerCase());
        const opt = r.options.find(o => normYo(o.label.toLowerCase()) === desired)
          || r.options.find(o => normYo(o.label.toLowerCase()).includes(desired));
        if (opt) {
          // Option 0 = base element (no suffix), options 1+ = #N#radio
          const radioId = opt.index === 0 ? r.inputId : `${r.inputId}#${opt.index}#radio`;
          await page.click(`[id="${radioId}"]`);
          await waitForStable();
          results.push({ field: r.field, ok: true, value: opt.label, method: 'radio' });
        } else {
          results.push({ field: r.field, error: 'option_not_found', available: r.options.map(o => o.label) });
        }
      } else if (r.hasSelect) {
        // Combobox/reference with DLB: DLB-first, then paste fallback
        const refResult = await fillReferenceField(selector, r.field, fields[r.field], formNum);
        results.push(refResult);
      } else if (r.hasPick && (r.isDate || r.isCalc)) {
        // Date/time (calendar CB) or numeric (calculator CB) field — use paste:
        // the pick button is a calendar/calculator widget, not a selection form.
        await page.click(selector);
        await page.waitForTimeout(200);
        await page.keyboard.press('Control+A');
        await pasteText(fields[r.field]);
        await page.waitForTimeout(300);
        await page.keyboard.press('Tab');
        await waitForStable();
        results.push({ field: r.field, ok: true, value: String(fields[r.field]), method: 'paste' });
      } else if (r.hasPick) {
        // Reference field with CB (non-editable or editable ref): delegate to selectValue (F4 → selection form)
        const svResult = await selectValue(r.field, String(fields[r.field]));
        if (svResult?.error) {
          results.push({ field: r.field, error: svResult.error, message: svResult.message });
        } else {
          results.push({ field: r.field, ok: true, value: svResult.value || String(fields[r.field]), method: svResult.method || 'form' });
        }
      } else {
        // Plain field: clipboard paste + Tab to commit
        // page.fill() sets DOM value but doesn't trigger 1C input events;
        // clipboard paste (Ctrl+V) is a trusted event that 1C processes correctly.
        await page.click(selector);
        await page.waitForTimeout(200);
        await page.keyboard.press('Control+A');
        await pasteText(fields[r.field]);
        await page.waitForTimeout(300);
        await page.keyboard.press('Tab');
        await waitForStable();
        results.push({ field: r.field, ok: true, value: String(fields[r.field]), method: 'paste' });
      }
    } catch (e) {
      results.push({ field: r.field, error: e.message });
    }
    if (highlightMode) try { await unhighlight(); } catch {}
  }

  const failed = results.filter(r => r.error);
  if (failed.length > 0) {
    const details = failed.map(f => `  ${f.field}: ${f.message || f.error}${f.available ? ' (available: ' + f.available.join(', ') + ')' : ''}`).join('\n');
    throw new Error(`fillFields: ${failed.length} of ${results.length} field(s) failed:\n${details}`);
  }
  return returnFormState({ filled: results });
}

/** Convenience alias: fill a single field. Same as fillFields({ name: value }). */
export async function fillField(name, value) {
  return fillFields({ [name]: value });
}
