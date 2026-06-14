// web-test dom/form-state v1.0 — combined detectForm + readForm + open tabs
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { DETECT_FORM_FN, DETECT_FORMS_FN, READ_FORM_FN } from './_shared.mjs';

/**
 * Combined: detect form + read form + read open tabs.
 * Single evaluate call instead of 3. Used by browser.getFormState().
 */
export function getFormStateScript() {
  return `(() => {
    ${DETECT_FORM_FN}
    ${DETECT_FORMS_FN}
    ${READ_FORM_FN}
    const formNum = detectForm();
    const meta = detectForms();
    if (formNum === null) return { form: null, formCount: 0, message: 'No form detected' };
    const p = 'form' + formNum + '_';
    const formData = readForm(p);
    // Open tabs bar (present only when tab panel is enabled in 1C settings)
    const openTabs = [];
    document.querySelectorAll('[id^="openedCell_cmd_"]').forEach(el => {
      const text = el.innerText?.trim();
      if (!text) return;
      const entry = { name: text };
      if (el.classList.contains('select')) entry.active = true;
      openTabs.push(entry);
    });
    const activeTab = openTabs.find(t => t.active)?.name || null;
    const result = { form: formNum, activeTab, openForms: meta.allForms, formCount: meta.formCount, ...formData };
    if (meta.modal) result.modal = true;
    if (openTabs.length) result.openTabs = openTabs;
    return result;
  })()`;
}
