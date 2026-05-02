export const name = 'CRUD: открытие, чтение, закрытие с подтверждением';
export const tags = ['crud', 'smoke'];
export const timeout = 60000;

export default async function({ navigateSection, openCommand, clickElement, closeForm, readTable, fillField, getFormState, assert, step, log }) {

  await step('read: список Контрагентов отдаёт колонки/строки/total', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    const t = await readTable();
    log(`columns=${t.columns?.length} rows=${t.rows?.length} total=${t.total}`);
    assert.ok(t.total >= 4, `Должно быть >= 4 контрагента (got ${t.total})`);
    assert.ok(t.rows?.length >= 4, 'rows должен содержать заполненные строки');
    const names = t.rows.map(r => r['Наименование']);
    assert.includes(names, 'ООО Север', 'ООО Север должен быть в списке');
    await closeForm();
  });

  await step('open-item: dblclick открывает форму элемента', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await clickElement('ООО Север', { dblclick: true });
    const state = await getFormState();
    const nameField = state.fields?.find(f => f.name === 'Наименование' || f.label === 'Наименование');
    log(`Opened form=${state.form} Наименование='${nameField?.value}'`);
    assert.ok(state.form, 'Форма элемента должна открыться (state.form задан)');
    assert.equal(nameField?.value, 'ООО Север', 'В открытой форме должен быть указан выбранный контрагент');
    await closeForm();
  });

  await step('close-clean: закрытие без изменений не показывает confirmation', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await clickElement('ООО Юг', { dblclick: true });
    const before = await getFormState();
    const after = await closeForm();
    assert.ok(after.closed, 'Форма должна закрыться без диалога');
    assert.ok(!after.confirmation, 'Confirmation dialog не должен появиться');
    log(`closed=${after.closed} form-was=${before.form}`);
  });

  await step('save-via-button: fillField + "Записать и закрыть" → значение сохранилось', async () => {
    // NB: closeForm({save:true}) ожидает confirmation dialog, но fillField через
    // paste не выставляет 1C "modified" флаг → диалог не появляется и Escape
    // просто закрывает форму без сохранения. Save-flow покрываем через явную
    // кнопку «Записать и закрыть»; confirm-save-yes отложен как баг движка.
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await clickElement('ООО Восток', { dblclick: true });
    const newPhone = '+7 (999) 111-22-33';
    await fillField('Телефон', newPhone);
    await clickElement('Записать и закрыть');

    // Verify persisted
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await clickElement('ООО Восток', { dblclick: true });
    const state = await getFormState();
    const phoneField = state.fields?.find(f => f.name === 'Телефон' || f.label === 'Телефон');
    log(`Re-opened phone='${phoneField?.value}'`);
    assert.equal(phoneField?.value, newPhone, 'Телефон должен сохраниться');
    await closeForm();
  });
}
