// web-test dom/form-state v1.1 — combined detectForm + readForm + open tabs + form caption
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
    // Caption of the ACTIVE form. Lives in an attribute, not in text — the div itself is empty:
    //   <div class="toplineBox" data-title="Контрагенты">
    //     <div id="VW_page1headerTopLine_title" class="toplineBoxTitle" title="Контрагенты"></div>
    // Header numbering (VW_page<M>) does not match form numbering (form<N>), so the header cannot
    // be picked by form number. Several headers can be visible at once — with a selection form up,
    // BOTH the parent form's header and the pop-up's are visible — so "first visible" would report
    // the parent's caption for the pop-up: a plausible, wrong answer.
    // Priority is therefore the one already measured for the close cross (dom/forms.mjs
    // closeCrossScript): floating window (ps<N>, highest index = topmost) → the form's own header →
    // and only then the open-windows tab, which the user can switch off in 1C settings.
    // Anchored on ids, not on the visible text, so a non-Russian locale keeps working.
    const heads = [...document.querySelectorAll('[id*="headerTopLine_title"]')]
      .filter(e => e.offsetWidth > 0 && e.offsetHeight > 0);
    const floating = heads.filter(e => /ps\\d+headerTopLine_title$/.test(e.id));
    const own = heads.filter(e => /^VW_page\\d+headerTopLine_title$/.test(e.id));
    const head = floating.pop() || own.pop() || null;
    let title = head
      ? (head.getAttribute('title') || head.parentElement?.getAttribute('data-title') || null)
      : null;
    if (!title) title = activeTab;
    const result = { form: formNum, activeTab, title, openForms: meta.allForms, formCount: meta.formCount, ...formData };
    if (meta.modal) result.modal = true;
    if (openTabs.length) result.openTabs = openTabs;
    return result;
  })()`;
}
