export const name = 'decoration-form: форма без полей ввода (гиперссылки/группы) детектируется';
export const tags = ['formstate', 'smoke'];
export const timeout = 90000;

// Обработка СтраницаНастроек — форма-«страница настроек» БЕЗ единого input.editInput /
// textarea / a.press (commandBarLocation:None): только гиперссылка-декорация + сворачиваемая
// группа. Воспроизводит реальный кейс «Администрирование → Интернет-поддержка и сервисы».
// Регресс на расширенный селектор детекции формы (dom/_shared.mjs, DETECT_FORM_FN /
// DETECT_FORMS_FN): до фикса detectForm возвращал null → getFormState = «No form detected»
// (form:null, formCount:0), навык такую форму НЕ видел.

export default async function({ navigateSection, openCommand, navigateLink, getFormState, closeForm, assert, step, log }) {

  await step('раздел: открыть «Страница настроек» командой из «Администрирование»', async () => {
    await navigateSection('Администрирование');
    const r = await openCommand('Страница настроек');
    log(`form=${r.form} formCount=${r.formCount} activeTab=${r.activeTab}`);
    assert.ok(r.form != null, 'форма распознана (form != null) — до фикса тут был null');
    assert.ok(r.formCount >= 1, 'formCount >= 1');
    const hy = (r.hyperlinks || []).map(h => h.name);
    assert.includes(hy, 'Техническая информация', 'гиперссылка-декорация видна в состоянии');
    assert.equal((r.fields || []).length, 0, 'полей ввода на форме нет (декорации-only)');
    await closeForm();
  });

  await step('navigateLink: та же форма через «Обработка.СтраницаНастроек»', async () => {
    const r = await navigateLink('Обработка.СтраницаНастроек');
    log(`form=${r.form} formCount=${r.formCount} activeTab=${r.activeTab}`);
    assert.ok(r.form != null, 'форма распознана через navigateLink');
    assert.ok(r.formCount >= 1, 'formCount >= 1');
    const state = await getFormState();
    const hy = (state.hyperlinks || []).map(h => h.name);
    assert.includes(hy, 'Техническая информация', 'гиперссылка видна и в getFormState');
    await closeForm();
  });
}
