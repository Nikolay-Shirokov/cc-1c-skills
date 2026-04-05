export const name = 'Навигация по разделам';
export const tags = ['nav', 'smoke'];
export const timeout = 60000;

export default async function({ navigateSection, getPageState, openCommand, closeForm, assert, step, log }) {

  await step('Чтение начального состояния', async () => {
    const state = await getPageState();
    const names = (state.sections || []).map(s => s.name);
    log('Sections: ' + names.join(', '));
    assert.ok(names.length >= 2, 'Минимум 2 раздела');
    assert.includes(names, 'Склад', 'Раздел Склад должен быть');
    assert.includes(names, 'Администрирование', 'Раздел Администрирование должен быть');
  });

  await step('Переход в раздел Склад', async () => {
    const result = await navigateSection('Склад');
    log('Commands: ' + (result.commands || []).map(c => c.name).join(', '));
    assert.ok(result.commands?.length > 0, 'Должны быть команды в разделе Склад');
  });

  await step('Открыть справочник Контрагенты', async () => {
    const state = await openCommand('Контрагенты');
    assert.ok(state.form, 'Форма списка Контрагентов должна открыться');
    log('Opened: ' + state.title);
    await closeForm();
  });

  await step('Переход в раздел Администрирование', async () => {
    const result = await navigateSection('Администрирование');
    log('Commands: ' + (result.commands || []).map(c => c.name).join(', '));
    assert.ok(result.commands?.length > 0, 'Должны быть команды в разделе Администрирование');
  });

  await step('Открыть Номенклатуру из раздела Склад', async () => {
    await navigateSection('Склад');
    const state = await openCommand('Номенклатура');
    assert.ok(state.form, 'Форма списка Номенклатуры должна открыться');
    log('Opened: ' + state.title);
    await closeForm();
  });
}
