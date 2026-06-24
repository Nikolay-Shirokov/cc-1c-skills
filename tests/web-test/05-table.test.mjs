export const name = 'Табличная часть: add, edit, delete на Товары накладной';
export const tags = ['table', 'smoke'];
export const timeout = 90000;

export default async function({ navigateSection, openCommand, clickElement, fillFields, fillTableRow, deleteTableRow, readTable, closeForm, getFormState, assert, step, log }) {

  await step('add: добавить две строки в Товары через fillTableRow add:true', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');
    await fillFields({ 'Контрагент': 'ООО Север' });

    await fillTableRow(
      { 'Номенклатура': 'Товар 01', 'Количество': '5', 'Цена': '100' },
      { table: 'Товары', add: true }
    );
    await fillTableRow(
      { 'Номенклатура': 'Товар 02', 'Количество': '3', 'Цена': '200' },
      { table: 'Товары', add: true }
    );

    const t = await readTable({ table: 'Товары' });
    log(`rows after add: ${t.rows?.length}, hasMore: ${JSON.stringify(t.hasMore)}`);
    assert.equal(t.rows?.length, 2, 'Должно быть 2 строки');
    assert.equal(t.rows[0]['Номенклатура'], 'Товар 01', 'Строка 0 = Товар 01');
    assert.equal(t.rows[1]['Номенклатура'], 'Товар 02', 'Строка 1 = Товар 02');
    // hasMore: две строки точно помещаются в табчасть — both false
    assert.ok(t.hasMore, 'hasMore должен быть в результате readTable');
    assert.equal(t.hasMore.below, false, 'hasMore.below должно быть false (всё видно)');
    // above либо false (видимый scrollbar), либо undefined (дин-список) — но для табчасти ждём false
    if (t.hasMore.above !== undefined) {
      assert.equal(t.hasMore.above, false, 'hasMore.above должно быть false (мы на первой странице)');
    }
  });

  await step('edit: изменить количество в строке 0 через fillTableRow row:0', async () => {
    await fillTableRow(
      { 'Количество': '10' },
      { table: 'Товары', row: 0 }
    );
    const t = await readTable({ table: 'Товары' });
    log(`row 0 after edit: ${JSON.stringify(t.rows[0])}`);
    assert.equal(t.rows[0]['Количество'], '10,000', 'Количество строки 0 = 10');
  });

  await step('edit by filter: найти строку по значению ячейки { Номенклатура: Товар 02 } и изменить Цену', async () => {
    const r = await fillTableRow(
      { 'Цена': '250' },
      { table: 'Товары', row: { 'Номенклатура': 'Товар 02' } }
    );
    log(`filter-edit result: ${JSON.stringify(r.filled)}`);
    const t = await readTable({ table: 'Товары' });
    log(`rows after filter-edit: ${JSON.stringify(t.rows)}`);
    // Должна измениться именно строка Товар 02 (индекс 1), а не Товар 01 (индекс 0).
    assert.equal(t.rows[1]['Номенклатура'], 'Товар 02', 'Фильтр нашёл строку Товар 02');
    assert.equal(t.rows[1]['Цена'], '250,00', 'Цена строки Товар 02 = 250');
    assert.equal(t.rows[0]['Номенклатура'], 'Товар 01', 'Строка Товар 01 не тронута');
  });

  await step('tab-loop: изменить два числовых поля в строке 1 одним вызовом', async () => {
    const r = await fillTableRow(
      { 'Количество': '7', 'Цена': '150' },
      { table: 'Товары', row: 1 }
    );
    log(`tab-loop result: ${JSON.stringify(r)}`);
    const t = await readTable({ table: 'Товары' });
    log(`row 1 after tab-loop: ${JSON.stringify(t.rows[1])}`);
    assert.equal(t.rows[1]['Количество'], '7,000', 'Количество строки 1 = 7');
    assert.equal(t.rows[1]['Цена'], '150,00', 'Цена строки 1 = 150');
  });

  await step('checkbox: переключить Согласовано в строке 1 через fillTableRow', async () => {
    const r = await fillTableRow(
      { 'Согласовано': true },
      { table: 'Товары', row: 1 }
    );
    log(`checkbox result: ${JSON.stringify(r.filled)}`);
    const t = await readTable({ table: 'Товары' });
    log(`row 1 Согласовано='${t.rows[1]['Согласовано']}'`);
    assert.equal(t.rows[1]['Согласовано'], 'true', 'Согласовано должно стать true');
  });

  await step('clear: очистить ссылочную ячейку Номенклатура через fillTableRow с пустым значением', async () => {
    // Используем строку 0 (Товар 01)
    const r = await fillTableRow(
      { 'Номенклатура': '' },
      { table: 'Товары', row: 0 }
    );
    log(`clear result: ${JSON.stringify(r.filled)}`);
    const t = await readTable({ table: 'Товары' });
    log(`row 0 Номенклатура after clear='${t.rows[0]['Номенклатура']}'`);
    assert.equal(t.rows[0]['Номенклатура'], '', 'Номенклатура должна быть очищена (Shift+F4)');

    // Восстанавливаем Товар 01 чтобы последующий delete мог работать с предсказуемым состоянием
    await fillTableRow(
      { 'Номенклатура': 'Товар 01' },
      { table: 'Товары', row: 0 }
    );
  });

  await step('delete: удалить первую строку', async () => {
    await deleteTableRow(0, { table: 'Товары' });
    const t = await readTable({ table: 'Товары' });
    log(`rows after delete: ${t.rows?.length}, [0]=${t.rows[0]?.['Номенклатура']}`);
    assert.equal(t.rows?.length, 1, 'Должна остаться 1 строка');
    assert.equal(t.rows[0]['Номенклатура'], 'Товар 02', 'Осталась строка Товар 02');
  });

  await step('delete: фокус вне грида (Комментарий) — delete всё равно должен работать', async () => {
    // Воспроизводит сценарий, когда последнее действие было НЕ в табчасти.
    // deleteTableRow должен корректно перехватить фокус и удалить строку
    // несмотря на то, что click на Number-ячейку входит в edit-mode (post-click Escape).
    await fillTableRow({ 'Номенклатура': 'Товар 03', 'Количество': '8' }, { table: 'Товары', add: true });
    // Перевести фокус на Комментарий (вне грида).
    await fillFields({ 'Комментарий': 'focus-outside-grid' });
    await deleteTableRow(0, { table: 'Товары' });
    const t = await readTable({ table: 'Товары' });
    log(`rows after delete: ${t.rows?.length}, names=${t.rows.map(r => r['Номенклатура']).join(',')}`);
    assert.equal(t.rows?.length, 1, 'Должна остаться 1 строка');
    assert.equal(t.rows[0]['Номенклатура'], 'Товар 03', 'Удалена первая (Товар 02), осталась Товар 03');
    await closeForm({ save: false });
  });

  await step('composite-wide-form: ИсточникТЧ {value,type} через ШИРОКУЮ форму выбора', async () => {
    // Прямой регресс исходного симптома: fillTableRow в составную ячейку → диалог
    // типа → широкая форма выбора Контрагентов (14 колонок, строка шире окна).
    // Старый scanGridRows целился в центр строки → клик в оверлей → not_selectable.
    // Детерминированность: «ООО Север» сортируется раньше точного «Север»; багованный
    // путь выбрал бы «ООО Север», фикс (exact-preference + клик в видимую ячейку) — «Север».
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');

    const r = await fillTableRow(
      { 'Источник': { value: 'Север', type: 'Контрагент' } },
      { table: 'Товары', add: true }
    );
    log(`composite fill: ${JSON.stringify(r.filled)}`);
    const item = (r.filled || []).find(f => /сточник/.test(f.field || ''));
    assert.ok(item?.ok, `ячейка Источник заполнена без ошибки: ${item?.error || ''} ${item?.message || ''}`);

    const t = await readTable({ table: 'Товары' });
    log(`Источник cell='${t.rows[0]?.['Источник']}' rows=${t.rows.length}`);
    assert.equal(t.rows[0]?.['Источник'], 'Север',
      'exact-preference + клик в видимую ячейку: выбран точный «Север», не «ООО Север»');
    // Guard: после составного фила цикл не должен табать дальше до создания лишней
    // строки (раньше ветка type→форма не выходила по «всё заполнено»).
    assert.equal(t.rows.length, 1, 'ровно одна строка — лишние табы не создали пустую');

    await closeForm({ save: false });
  });
}
