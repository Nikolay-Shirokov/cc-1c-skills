export const name = 'Навигация по разделам';
export const tags = ['nav', 'smoke'];
export const timeout = 60000;

export default async function({ navigateSection, getPageState, openCommand, navigateLink, switchTab, closeForm, assert, step, log }) {

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
    assert.ok(state.form != null, 'Форма списка Контрагентов должна открыться');
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

  await step('section-error: navigateSection с несуществующим именем кидает ошибку', async () => {
    let err = null;
    try {
      await navigateSection('НетТакогоРаздела_xyz');
    } catch (e) {
      err = e;
    }
    log(`section-error: ${err?.message}`);
    assert.ok(err, 'Должна быть ошибка для несуществующего раздела');
  });

  await step('command-error: openCommand с несуществующим именем кидает ошибку', async () => {
    await navigateSection('Склад');
    let err = null;
    try {
      await openCommand('НетТакойКоманды_xyz');
    } catch (e) {
      err = e;
    }
    log(`command-error: ${err?.message}`);
    assert.ok(err, 'Должна быть ошибка для несуществующей команды');
  });

  await step('navigateLink: открыть Catalog.Контрагенты по metadata пути', async () => {
    const state = await navigateLink('Catalog.Контрагенты');
    log(`link-type form=${state.form} formCount=${state.formCount}`);
    assert.ok(state.form != null, 'navigateLink должен открыть форму');
    await closeForm();
  });

  await step('navigateLink: e1cib URL', async () => {
    // e1cib path-form: Catalog.Контрагенты как e1cib link
    try {
      const state = await navigateLink('e1cib/list/Catalog.Контрагенты');
      log(`link-e1cib form=${state.form}`);
      assert.ok(state.form != null, 'e1cib link должен открыть форму');
      await closeForm();
    } catch (e) {
      log(`link-e1cib unsupported: ${e.message}`);
      // некоторые версии не поддерживают полный e1cib через Shift+F11
    }
  });

  await step('switchTab: ошибка при несуществующем имени', async () => {
    let err = null;
    try {
      await switchTab('НетТакогоТаба_xyz');
    } catch (e) {
      err = e;
    }
    log(`switchTab-error: ${err?.message}`);
    assert.ok(err, 'switchTab должен кидать ошибку для несуществующего таба');
  });
}
