export const name = 'getFormState: базовая структура — fields, buttons, tables, openForms';
export const tags = ['formstate', 'smoke'];
export const timeout = 60000;

export default async function({ navigateSection, openCommand, clickElement, closeForm, getFormState, getPage, assert, step, log }) {

  await step('basic: getFormState на форме списка возвращает таблицу и команды', async () => {
    await navigateSection('Склад');
    const s = await openCommand('Контрагенты');
    log(`form=${s.form} formCount=${s.formCount} tables=${s.tables?.length} buttons=${s.buttons?.length}`);
    assert.ok(s.form != null, 'state.form задан');
    assert.equal(s.formCount, 1, 'Открыта одна форма');
    assert.ok(Array.isArray(s.openForms) && s.openForms.length === 1, 'openForms — массив с одной записью');
    assert.ok(s.tables?.length >= 1, 'На форме списка есть таблица');
    assert.ok(s.tables[0].columns?.length >= 2, 'У таблицы есть колонки');
    assert.ok(s.buttons?.length >= 1, 'На форме есть кнопки');
    // title читается из шапки формы (атрибут .toplineBoxTitle), а не из панели открытых окон —
    // она отключаема в настройках 1С. Панель остаётся запасным источником.
    assert.formTitle(s, 'Контрагенты', 'Заголовок формы списка');
    assert.noErrors(s, 'На только что открытой форме списка ошибок быть не должно');
    await closeForm();
  });

  await step('basic: getFormState на форме элемента возвращает fields с label и value', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await clickElement('ООО Север', { dblclick: true });
    const s = await getFormState();
    log(`fields count=${s.fields?.length}`);
    assert.ok(s.fields?.length >= 1, 'На форме элемента есть поля');
    const named = s.fields.find(f => f.name === 'Наименование');
    log(`Наименование: label='${named?.label}' value='${named?.value}'`);
    assert.formHasField(s, 'Наименование', 'formHasField ищет по массиву fields, а не по ключу');
    assert.formTitle(s, 'Контрагент', 'Заголовок формы элемента');
    assert.ok(named, 'Должно быть поле Наименование');
    assert.equal(named.value, 'ООО Север', 'value поля Наименование');
    assert.ok(named.label, 'У поля есть label');
    await closeForm();
  });

  await step('modal: форма выбора Контрагентов открыта как модальная', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');
    const page = await getPage();
    // Найти input Контрагент и фокус, затем F4 → откроется модальная форма выбора
    const focused = await page.evaluate(`(() => {
      const inputs = [...document.querySelectorAll('input')];
      const target = inputs.find(i => /Контрагент/i.test(i.id || '') && i.offsetWidth > 0);
      if (target) { target.focus(); return target.id; }
      return null;
    })()`);
    log(`focused input id=${focused}`);
    await page.keyboard.press('F4');
    await page.waitForTimeout(1500);

    const s = await getFormState();
    log(`after F4: form=${s.form} formCount=${s.formCount} modal=${s.modal}`);
    assert.equal(s.modal, true, 'state.modal=true для модальной формы выбора');
    assert.ok(s.formCount >= 2, 'formCount >= 2 (родитель + модальная)');
    // Заголовок берётся у всплывающего окна, а не у родителя: видимы обе шапки, а панель
    // открытых окон в этот момент показывает родителя ('Приходная накладная').
    assert.formTitle(s, 'Выбор контрагента', 'title всплывающего окна, а не родительской формы');

    await closeForm();
    await closeForm({ save: false });
  });

  await step('tabs: на форме элемента Номенклатуры присутствует tabs[]', async () => {
    await navigateSection('Склад');
    await openCommand('Номенклатура');
    await clickElement('Товары', { dblclick: true });
    await clickElement('Товар 01', { dblclick: true });
    const s = await getFormState();
    log(`tabs: ${JSON.stringify(s.tabs)}`);
    assert.ok(Array.isArray(s.tabs), 'state.tabs должен быть массивом');
    assert.ok(s.tabs.length >= 2, `На форме Номенклатуры >= 2 табов (got ${s.tabs.length})`);
    await closeForm();
  });

  await step('subordinate-nav: форма элемента Контрагент возвращает state.navigation с КонтактнымиЛицами', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await clickElement('ООО Север', { dblclick: true });
    const s = await getFormState();
    log(`navigation: ${JSON.stringify(s.navigation)}`);
    assert.ok(Array.isArray(s.navigation), 'state.navigation — массив');
    assert.ok(s.navigation.length >= 2, 'минимум Основное + один подчинённый');
    const main = s.navigation.find(n => n.active);
    assert.ok(main && main.name === 'Основное', 'активная ссылка — Основное');
    const sub = s.navigation.find(n => /Контактные/.test(n.name));
    assert.ok(sub, 'есть ссылка на Контактные лица');
    await closeForm();
  });

  await step('platform-dialogs: открытый «О программе» виден в state.platformDialogs', async () => {
    const page = await getPage();
    await page.click('#captionbarMore');
    await page.waitForTimeout(800);
    await page.getByText('О программе...', { exact: true }).click();
    await page.waitForTimeout(1500);
    const s = await getFormState();
    log(`platformDialogs: ${JSON.stringify(s.platformDialogs)}`);
    assert.ok(Array.isArray(s.platformDialogs) && s.platformDialogs.length === 1,
      'state.platformDialogs — массив с одним элементом');
    assert.equal(s.platformDialogs[0].type, 'about', 'type=about');
    assert.equal(s.platformDialogs[0].title, 'О программе', 'title');
  });

  await step('platform-dialog-close: closeForm закрывает платформенный диалог', async () => {
    // About остался открыт с предыдущего шага
    await closeForm();
    const s = await getFormState();
    log(`platformDialogs after closeForm: ${s.platformDialogs?.length || 0}`);
    assert.ok(!s.platformDialogs?.length, 'после closeForm нет platformDialogs');
  });
}
