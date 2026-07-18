export const name = 'decoration-form: форма без полей ввода (гиперссылки/группы) детектируется';
export const tags = ['formstate', 'smoke'];
export const timeout = 90000;

// Обработка СтраницаНастроек — форма-«страница настроек» БЕЗ единого input.editInput /
// textarea / a.press (commandBarLocation:None): только гиперссылка-декорация + сворачиваемая
// группа. Воспроизводит реальный кейс «Администрирование → Интернет-поддержка и сервисы».
// Регресс на расширенный селектор детекции формы (dom/_shared.mjs, DETECT_FORM_FN /
// DETECT_FORMS_FN): до фикса detectForm возвращал null → getFormState = «No form detected»
// (form:null, formCount:0), навык такую форму НЕ видел.
//
// Плюс: сворачиваемые группы формы в getFormState().groups (состояние collapsed) и их
// раскрытие/сворачивание через clickElement {expand}/{toggle}. Форма содержит оба варианта
// рендера контрола (заголовок-гиперссылка и картинка-каретка ControlRepresentation), негатив
// (обычная несворачиваемая группа — НЕ в groups[]) и стресс-привязку (свободный элемент между
// группами не путает определение состояния).

export default async function({ navigateSection, openCommand, navigateLink, getFormState, clickElement, closeForm, assert, step, log }) {

  const collapsedOf = (s, name) => (s.groups || []).find(x => x.name === name)?.collapsed;

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

  await step('groups: getFormState показывает сворачиваемые группы + состояние', async () => {
    const s = await navigateLink('Обработка.СтраницаНастроек');
    log(`groups=${JSON.stringify((s.groups || []).map(g => [g.name, g.collapsed]))}`);
    assert.ok(s.groups?.length, 'groups[] присутствует');
    assert.equal(collapsedOf(s, 'ГруппаКлассификаторы'), true, 'вариант A (гиперссылка) — свёрнута');
    assert.equal(collapsedOf(s, 'ГруппаРазвёрнутая'), false, 'развёрнутая — collapsed:false');
    assert.equal(collapsedOf(s, 'ГруппаКартинкой'), true, 'вариант B (картинка) — свёрнута');
    assert.ok(!s.groups.some(g => g.name === 'ГруппаОбычная'),
      'обычная несворачиваемая группа НЕ попадает в groups[] (негатив — не шумит)');
    // Стресс-привязка: свободный элемент между группами не путает определение состояния.
    assert.equal(collapsedOf(s, 'ГруппаСтрессСвёрнутая'), true, 'стресс: свёрнутая определена верно');
    assert.equal(collapsedOf(s, 'ГруппаСтрессРазвёрнутая'), false, 'стресс: развёрнутая определена верно');
  });

  await step('group toggle: clickElement {expand}/{toggle} по вариантам A и B', async () => {
    // Вариант A (заголовок-гиперссылка): раскрыть → идемпотентный повтор → свернуть.
    let r = await clickElement('Классификаторы и курсы валют', { expand: true });
    assert.equal(r.clicked.toggled, true, 'A expand:true — кликнул');
    assert.equal(collapsedOf(r, 'ГруппаКлассификаторы'), false, 'A раскрыта');
    r = await clickElement('Классификаторы и курсы валют', { expand: true });
    assert.equal(r.clicked.toggled, false, 'A expand:true повторно — идемпотентно (no-op)');
    r = await clickElement('Классификаторы и курсы валют', { expand: false });
    assert.equal(collapsedOf(r, 'ГруппаКлассификаторы'), true, 'A свёрнута обратно');
    // Вариант B (картинка-каретка #titleBtn): toggle.
    r = await clickElement('Свёрнута картинкой', { toggle: true });
    assert.equal(collapsedOf(r, 'ГруппаКартинкой'), false, 'B раскрыта тоглом');
    await closeForm();
  });

  await step('popup: всплывающая группа — behavior, открытие показывает содержимое', async () => {
    const s = await navigateLink('Обработка.СтраницаНастроек');
    const pg = (s.groups || []).find(g => g.name === 'ГруппаВсплывающая');
    assert.ok(pg, 'всплывающая группа в groups[]');
    assert.equal(pg.behavior, 'popup', 'помечена behavior:popup (отличима от collapsible)');
    assert.equal(pg.collapsed, true, 'закрыта — collapsed:true');
    assert.ok(!(s.texts || []).some(t => /всплывающей/.test(t.value)), 'содержимое скрыто, пока закрыта');
    // Открыть → содержимое панели становится видно в состоянии формы.
    let r = await clickElement('Всплывающая группа', { expand: true });
    assert.equal((r.groups || []).find(g => g.name === 'ГруппаВсплывающая')?.collapsed, false, 'открыта');
    assert.ok((r.texts || []).some(t => /всплывающей/.test(t.value)), 'после открытия содержимое видно');
    r = await clickElement('Всплывающая группа', { expand: true });
    assert.equal(r.clicked.toggled, false, 'expand идемпотентен для popup');
    r = await clickElement('Всплывающая группа', { expand: false });
    assert.equal((r.groups || []).find(g => g.name === 'ГруппаВсплывающая')?.collapsed, true, 'закрыта обратно');
    await closeForm();
  });
}
