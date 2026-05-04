export const name = 'fillFields: text, checkbox, date, dropdown, reference';
export const tags = ['fillfields', 'smoke'];
export const timeout = 60000;

const findField = (state, name) => state.fields?.find(f => f.name === name || f.label === name);

export default async function({ navigateSection, openCommand, clickElement, fillFields, filterList, closeForm, getFormState, assert, step, log }) {

  await step('text+checkbox+date+dropdown: fillFields на Номенклатура', async () => {
    await navigateSection('Склад');
    await openCommand('Номенклатура');
    await clickElement('Товары', { dblclick: true });   // войти в папку
    await clickElement('Товар 01', { dblclick: true });

    const result = await fillFields({
      'Артикул': 'TEST-001',
      'Активен': false,                       // Boolean → CheckBoxField, toggle
      'ДатаПоступления': '15.05.2026',        // date
      'ВидНоменклатуры': 'Услуга',            // EnumRef dropdown
    });

    log('methods: ' + result.filled.map(f => `${f.field}=${f.method}`).join(', '));
    for (const f of result.filled) {
      assert.ok(f.ok, `fillField "${f.field}" должен вернуть ok=true`);
    }

    const state = await getFormState();
    assert.equal(findField(state, 'Артикул')?.value, 'TEST-001', 'Артикул text');
    assert.equal(findField(state, 'Активен')?.value, false, 'Активен checkbox=false');
    assert.equal(findField(state, 'ДатаПоступления')?.value, '15.05.2026', 'ДатаПоступления');
    assert.equal(findField(state, 'ВидНоменклатуры')?.value, 'Услуга', 'ВидНоменклатуры dropdown');

    await closeForm({ save: false });
  });

  await step('reference-dropdown: Организация → CatalogRef.Организации (quickChoice=true)', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');

    const fillRes = await fillFields({
      'Организация': 'Альфа',
    });
    log('reference method: ' + fillRes.filled[0]?.method);
    assert.ok(fillRes.filled[0]?.ok, 'Организация fillField должна сработать');

    const state = await getFormState();
    const org = findField(state, 'Организация');
    log(`Организация value='${org?.value}'`);
    assert.includes(org?.value || '', 'Альфа', 'Организация должна показать выбранное значение');

    await closeForm({ save: false });
  });

  await step('radio: КатегорияЦены (RadioButtons) через fillFields, СпособУчёта (Tumbler) через clickElement', async () => {
    // Tumbler-представление не парсится fillFields как radio-поле (см.
    // upload/web-test-bugs.md пункт 5). Но варианты тумблера видны в
    // state.buttons и кликаются через clickElement — покрываем через него.
    await navigateSection('Склад');
    await openCommand('Номенклатура');
    await filterList('Товар 02');
    await clickElement('Товар 02', { dblclick: true });

    // RadioButtons — fillFields с method=radio
    const result = await fillFields({ 'Категория цены': 'Оптовая' });
    log('RadioButtons method: ' + result.filled[0]?.method + ', value: ' + result.filled[0]?.value);
    assert.ok(result.filled[0]?.ok, 'КатегорияЦены fillField должна сработать');
    assert.equal(result.filled[0]?.method, 'radio', 'КатегорияЦены должна использовать method=radio');
    assert.includes(result.filled[0]?.value || '', 'Оптовая', 'КатегорияЦены = Оптовая');

    // Tumbler — варианты «По среднему» / «ФИФО» доступны как buttons
    const before = await getFormState();
    const tumblerButtons = (before.buttons || [])
      .map(b => b.name || b)
      .filter(n => n === 'По среднему' || n === 'ФИФО');
    log('Tumbler buttons: ' + tumblerButtons.join(', '));
    assert.equal(tumblerButtons.length, 2, 'Tumbler должен показывать оба варианта в buttons[]');

    await clickElement('ФИФО');
    log('Tumbler clicked: ФИФО');

    await closeForm({ save: false });
  });
}
