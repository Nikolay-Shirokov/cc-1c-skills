export const name = 'selectValue: dropdown vs форма выбора';
export const tags = ['selectvalue', 'smoke'];
export const timeout = 90000;

const findField = (state, name) => state.fields?.find(f => f.name === name || f.label === name);

export default async function({ navigateSection, openCommand, clickElement, selectValue, closeForm, assert, step, log }) {

  await step('dropdown: Организация → CatalogRef.Организации (quickChoice=true)', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');

    const result = await selectValue('Организация', 'Альфа');
    log(`method=${result.selected?.method}, search=${result.selected?.search}`);
    assert.equal(result.selected?.method, 'dropdown', 'Должен быть метод dropdown (быстрый выбор)');

    const field = findField(result, 'Организация');
    log(`Организация value='${field?.value}'`);
    assert.includes(field?.value || '', 'Альфа', 'Организация должна показать выбранное значение');

    await closeForm({ save: false });
  });

  await step('direct-form: Контрагент → форма выбора (ШИРОКАЯ — регресс центр-X + exact-preference)', async () => {
    // Форма выбора Контрагентов намеренно широкая (14 колонок) — строка шире окна.
    // Старый scanGridRows целился в ЦЕНТР строки → клик в оверлей за вьюпортом →
    // не та строка / not_selectable. Новый — в первую видимую ячейку.
    // В справочнике есть и «ООО Север», и ровно «Север»; поиск «Север» даёт 2
    // вхождения, «ООО Север» сортируется раньше. Багованный путь выбрал бы «ООО
    // Север»; фикс (exact-preference + клик в видимую ячейку) обязан выбрать «Север».
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');

    const result = await selectValue('Контрагент', 'Север');
    log(`method=${result.selected?.method}, search=${result.selected?.search}, err=${result.selected?.error || ''}`);
    assert.equal(result.selected?.method, 'form', 'Должен быть метод form (через форму выбора)');
    assert.ok(!result.selected?.error, `выбор без ошибки (было not_selectable): ${result.selected?.message || ''}`);

    const field = findField(result, 'Контрагент');
    log(`Контрагент value='${field?.value}'`);
    assert.equal((field?.value || '').trim(), 'Север',
      'exact-preference + клик в видимую ячейку: выбран точный «Север», не «ООО Север»');

    await closeForm({ save: false });
  });

  await step('auto-history: choiceHistoryOnInput=Auto → method=dropdown даже на ссылке без quickChoice', async () => {
    // Менеджер и Контрагент оба ссылаются на CatalogRef.Контрагенты (quickChoice=false).
    // Отличие — choiceHistoryOnInput:
    //   Контрагент: 'DontUse' → typeahead-dropdown подавлен → selectValue идёт в form
    //   Менеджер:   'Auto' (дефолт) → typeahead активен → selectValue остаётся в dropdown
    // Шаг подтверждает, что флаг управляет path внутри selectValue.
    //
    // history наполняется per-value при выборе. Делаем warm-up через form, чтобы
    // second pick шёл из истории — иначе isolation-прогон зависит от того,
    // выбирали ли 'ООО Юг' в предыдущих тестах (06-document и т.д.).
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');

    // Warm-up: первый выбор может пойти через form (если history пустая).
    // Не делаем assertions — только наполняем историю.
    await selectValue('Менеджер', 'ООО Юг');
    await selectValue('Менеджер', '');  // clear, оставляем форму открытой

    // Второй выбор того же значения — должен взяться из history через typeahead.
    const r = await selectValue('Менеджер', 'ООО Юг');
    log(`Менеджер (Auto): method=${r.selected?.method}`);
    assert.equal(r.selected?.method, 'dropdown',
      'Auto-история включена → typeahead-dropdown → method=dropdown (vs form у Контрагент)');

    const field = findField(r, 'Менеджер');
    assert.includes(field?.value || '', 'Юг', 'значение установилось из dropdown');

    await closeForm({ save: false });
  });

  await step('object-search: selectValue({ Наименование }) выбирает через форму выбора', async () => {
    // Регрессия объектного поиска { field: value }:
    //   1) dropdown-путь 3A падал на searchText.toLowerCase() (объект, не строка);
    //   2) pickFromSelectionForm (Шаг 2) вызывал filterList без импорта —
    //      ReferenceError тихо глотался catch'ем, поиск по полю не отрабатывал.
    // Теперь объектный search уходит в форму выбора и фильтрует per-field.
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');

    const r = await selectValue('Контрагент', { 'Наименование': 'Север' });
    log(`object-search: method=${r.selected?.method} errors=${JSON.stringify(r.errors)}`);
    assert.equal(r.selected?.method, 'form', 'объектный поиск идёт через форму выбора');
    assert.ok(!r.errors, 'без ошибок 1С');

    const field = findField(r, 'Контрагент');
    log(`Контрагент value='${field?.value}'`);
    assert.includes(field?.value || '', 'Север', 'выбран контрагент с Наименование=Север');

    await closeForm({ save: false });
  });

  await step('clear: selectValue с пустым search → Shift+F4', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');

    await selectValue('Организация', 'Альфа');
    const before = await selectValue('Организация', '');  // empty → clear
    const field = findField(before, 'Организация');
    log(`Организация after clear value='${field?.value}'`);
    assert.equal(field?.value, '', 'Организация должна быть очищена');

    await closeForm({ save: false });
  });

}
// show-all-form ветка (P1 в матрице) требует quickChoice=true каталога с
// количеством > порога dropdown, чтобы появилась ссылка "Показать все".
// В текущей синтетике такого каталога нет (Организации ~2 элемента, остальные
// quickChoice=false). Откладывается до расширения синтетики.
