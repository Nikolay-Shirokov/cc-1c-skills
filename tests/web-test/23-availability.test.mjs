export const name = 'Доступность элементов: getFormState помечает disabled, clickElement/fillFields/selectValue бросают';
export const tags = ['availability', 'disabled', 'click', 'fill', 'smoke'];
export const timeout = 120000;

const findBtn = (s, name) => s.buttons?.find(b => b.name === name);
const findField = (s, name) => s.fields?.find(f => f.name === name || f.label === name);

export default async function({ navigateLink, clickElement, fillFields, selectValue, getFormState, closeForm, assert, step, log }) {

  // Один раз открываем форму обработки; disabled-гарды бросают ДО действия и состояние
  // не портят, поэтому переиспользуем её между шагами, закрываем в конце.
  await step('getFormState помечает disabled по всем типам контролов', async () => {
    const s = await navigateLink('Обработка.ПроверкаДоступности');
    log('buttons: ' + JSON.stringify(s.buttons));

    // Кнопка командной панели (a.press)
    assert.ok(!findBtn(s, 'Доступная команда')?.disabled, 'доступная команда — без disabled');
    assert.equal(findBtn(s, 'Недоступная команда')?.disabled, true, 'недоступная команда — disabled');

    // Обычная кнопка (frameButton)
    assert.ok(!findBtn(s, 'Доступная кнопка')?.disabled, 'доступная кнопка — без disabled');
    assert.equal(findBtn(s, 'Недоступная кнопка')?.disabled, true, 'недоступная кнопка (frameButton) — disabled');

    // Поле ввода (нативный disabled)
    assert.ok(!findField(s, 'СтрокаДоступная')?.disabled, 'доступное поле — без disabled');
    assert.equal(findField(s, 'СтрокаНедоступная')?.disabled, true, 'недоступное поле — disabled');

    // Флажок (checkboxDisabled)
    assert.ok(!findField(s, 'ФлажокДоступный')?.disabled, 'доступный флажок — без disabled');
    assert.equal(findField(s, 'ФлажокНедоступный')?.disabled, true, 'недоступный флажок — disabled');

    // Переключатель RadioButtons (radioDisabled)
    assert.ok(!findField(s, 'ВидДоступный')?.disabled, 'доступный переключатель — без disabled');
    assert.equal(findField(s, 'ВидНедоступный')?.disabled, true, 'недоступный переключатель — disabled');

    // Ссылочное поле (нативный disabled на input)
    assert.ok(!findField(s, 'КонтрагентДоступный')?.disabled, 'доступное ссыл. поле — без disabled');
    assert.equal(findField(s, 'КонтрагентНедоступный')?.disabled, true, 'недоступное ссыл. поле — disabled');

    // Тумблер (tumblerDisabled на группе .frameTumbler) — сегменты идут в buttons[] с tumbler:true;
    // у недоступного тумблера оба сегмента помечены disabled.
    const disabledTumblers = (s.buttons || []).filter(b => b.tumbler && b.disabled);
    assert.equal(disabledTumblers.length, 2, 'оба сегмента недоступного тумблера помечены disabled');
    const enabledTumblers = (s.buttons || []).filter(b => b.tumbler && !b.disabled);
    assert.equal(enabledTumblers.length, 2, 'сегменты доступного тумблера — без disabled');
  });

  await step('clickElement бросает на недоступной кнопке/frameButton/флажке, проходит на доступной', async () => {
    let err = null;
    try { await clickElement('Недоступная команда'); } catch (e) { err = e; }
    assert.ok(err, 'клик по недоступной команде панели должен бросить');
    assert.includes(err.message, 'is disabled', 'сообщение "is disabled"');

    err = null;
    try { await clickElement('Недоступная кнопка'); } catch (e) { err = e; }
    assert.ok(err, 'клик по недоступной обычной кнопке (frameButton) должен бросить');
    assert.includes(err.message, 'is disabled', 'сообщение "is disabled"');

    err = null;
    try { await clickElement('Флажок недоступный'); } catch (e) { err = e; }
    assert.ok(err, 'клик по недоступному флажку должен бросить');
    assert.includes(err.message, 'is disabled', 'сообщение "is disabled"');

    // Позитив: доступная кнопка кликается штатно (регресс — гард не ложно-срабатывает).
    const r = await clickElement('Доступная команда');
    assert.ok(r.clicked, 'доступная команда → clicked без ошибки');
  });

  await step('fillFields бросает на недоступном поле и флажке, проходит на доступном', async () => {
    let err = null;
    try { await fillFields({ 'Строка недоступная': 'тест' }); } catch (e) { err = e; }
    assert.ok(err, 'заполнение недоступного поля должно бросить');
    assert.includes(err.message, 'is disabled', 'сообщение "is disabled"');

    err = null;
    try { await fillFields({ 'Флажок недоступный': 'true' }); } catch (e) { err = e; }
    assert.ok(err, 'toggle недоступного флажка должен бросить');
    assert.includes(err.message, 'is disabled', 'сообщение "is disabled"');

    // Позитив: доступное поле заполняется штатно.
    const r = await fillFields({ 'Строка доступная': 'привет' });
    assert.ok(r.filled?.some(f => f.ok), 'доступное поле заполнено');
  });

  await step('selectValue бросает на недоступном ссылочном поле, проходит на доступном', async () => {
    let err = null;
    try { await selectValue('Контрагент недоступный', 'ООО Север'); } catch (e) { err = e; }
    assert.ok(err, 'selectValue по недоступному ссыл. полю должен бросить');
    assert.includes(err.message, 'is disabled', 'сообщение "is disabled"');

    // Позитив: доступное ссылочное поле выбирается штатно.
    const r = await selectValue('Контрагент доступный', 'ООО Север');
    assert.ok(r.selected, 'доступное ссыл. поле — selected');

    await closeForm({ save: false });
  });
}
