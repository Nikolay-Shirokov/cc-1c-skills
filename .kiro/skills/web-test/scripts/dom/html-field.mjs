// web-test dom/html-field v1.0 — resolve an HTML document field of the active form
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { DETECT_FORM_FN, HTML_FIELDS_FN } from './_shared.mjs';

/**
 * Resolve an HTML document field (ПолеHTMLДокумента) of the ACTIVE form by name or title.
 *
 * Only the active form: a second instance of the same form keeps its hidden copy (with a live
 * iframe) in the DOM, and a field under a modal dialog still looks visible — a click into it
 * lands on the dialog. With a modal on top the active form is the dialog, so nothing resolves.
 *
 * Match order mirrors resolveGridScript: exact name → exact title → name contains → title
 * contains (case-insensitive, ё→е). Without a name the single visible field is taken.
 * The iframe is created lazily — not before the field is first shown (inactive page, collapsed
 * group, Видимость=Ложь), so a matched but hidden field is an error, not a silent wait.
 *
 * @returns {{ formNum, name } | { error, message, available? }}
 */
export function resolveHtmlFieldScript(name) {
  return `(() => {
    ${DETECT_FORM_FN}
    ${HTML_FIELDS_FN}
    const formNum = detectForm();
    if (formNum === null) return { error: 'no_form', message: 'No form is open' };
    const all = htmlFields('form' + formNum + '_');
    const visible = all.filter(f => f.visible);
    const list = fs => fs.map(f => f.label ? f.name + ' (' + f.label + ')' : f.name).join(', ');
    const hint = 'its page is not open, its group is collapsed, or the form hides it';
    if (!all.length) return { error: 'no_html_fields', message: 'The active form has no HTML fields' };
    const raw = ${JSON.stringify(name ?? null)};
    if (raw === null || raw === '') {
      if (visible.length === 1) return { formNum, name: visible[0].name };
      if (!visible.length) return { error: 'not_visible', message: 'No HTML field of the active form is visible (' + hint + '): ' + list(all) };
      return { error: 'ambiguous', message: 'The active form has ' + visible.length + ' HTML fields — pass a name: ' + list(visible) };
    }
    const norm = s => (s || '').toLowerCase().replace(/ё/g, 'е');
    const target = norm(raw);
    const found = all.find(f => norm(f.name) === target)
      || all.find(f => f.label && norm(f.label) === target)
      || all.find(f => norm(f.name).includes(target))
      || all.find(f => f.label && norm(f.label).includes(target));
    if (!found) return { error: 'not_found', message: 'HTML field "' + raw + '" not found. Available: ' + list(all) };
    if (!found.visible) return { error: 'not_visible', message: 'HTML field "' + found.name + '" is not visible (' + hint + ')' };
    return { formNum, name: found.name };
  })()`;
}
