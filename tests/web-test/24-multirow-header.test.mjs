export const name = 'multirow-header: резолвинг колонок на двухэтажной шапке (чтение/клик/заполнение)';
export const tags = ['table', 'columns'];
export const timeout = 120000;

// Стенд «Многострочная шапка» воспроизводит два паттерна, снятых живьём с ERP:
//
//  1. паттерн «Задачи» — широкая колонка «Исполнитель» (x 705…1206) над парой узких
//     «Срок» (705…956) и «Выполнена» (956…1206). У КАЖДОЙ ячейки есть шапка со своим
//     colindex, поэтому верный ответ однозначен. Матчинг по центру x его не находит:
//     центр широкой ячейки падает в диапазон одной из узких шапок.
//
//  2. паттерн «Операция» — шапка только у группы «Субконто», а ячеек под ней три и своих
//     шапок у них НЕТ. Здесь разворот в «Субконто 1/2/3» — правильное поведение, его
//     обязана сохранить любая правка.

export default async function({ navigateSection, openCommand, clickElement, closeForm, readTable, fillTableRow, getPage, assert, step, log }) {

  // Куда клик попал НА САМОМ ДЕЛЕ. Результат clickElement возвращает запрошенное имя колонки
  // (эхо), а не разрешённую ячейку, — по нему промах неотличим от попадания. Нажатая ячейка
  // помечается в DOM классами select+focus.
  const focusedCell = async () => {
    const page = await getPage();
    return page.evaluate(() => {
      const grid = [...document.querySelectorAll('.grid')].find(g => g.offsetWidth > 0 && g.offsetHeight > 0);
      const box = [...grid.querySelectorAll('.gridBody [colindex]')]
        .find(b => b.classList.contains('select') && b.classList.contains('focus'));
      return box ? { ci: box.getAttribute('colindex'), text: (box.innerText || '').trim() } : null;
    });
  };

  await step('setup: открыть обработку', async () => {
    await navigateSection('Склад');
    await openCommand('Многострочная шапка');
  });

  await step('read: значения лежат в своих колонках, фантомных «Исполнитель N» нет', async () => {
    const t = await readTable();
    log(`columns=${JSON.stringify(t.columns)}`);
    log(`row0=${JSON.stringify(t.rows[0])}`);

    // Своя шапка у каждой ячейки → колонка называется ровно как в шапке, без нумерации.
    assert.includes(t.columns, 'Исполнитель', 'колонка «Исполнитель» есть');
    assert.includes(t.columns, 'Срок', 'колонка «Срок» есть');
    assert.includes(t.columns, 'Выполнена', 'колонка «Выполнена» есть');
    assert.ok(!t.columns.includes('Исполнитель 1'),
      `фантомной «Исполнитель 1» быть не должно — шапка не объединённая (columns=${JSON.stringify(t.columns)})`);

    const r = t.rows[0];
    assert.equal(r['Код'], 'К1', 'Код');
    assert.equal(r['Задача'], 'Задача 1', 'Задача');
    assert.equal(r['Автор'], 'Автор 1', 'Автор');
    assert.equal(r['Исполнитель'], 'Исполнитель 1', 'Исполнитель — своё значение, не склейка');
    assert.equal(r['Срок'], 'Срок 1', 'Срок — своё значение, а не пусто');
    assert.equal(r['Выполнена'], 'Выполнена 1', 'Выполнена — своё значение, а не пусто');
  });

  await step('read: разворот объединённой шапки сохранён (паттерн «Операция»)', async () => {
    const t = await readTable();
    // У «Субконто» шапка одна, ячеек три, своих шапок у них нет → нумерация обязана остаться.
    assert.includes(t.columns, 'Субконто 1', 'колонка «Субконто 1»');
    assert.includes(t.columns, 'Субконто 2', 'колонка «Субконто 2»');
    assert.includes(t.columns, 'Субконто 3', 'колонка «Субконто 3»');
    const r = t.rows[0];
    assert.equal(r['Субконто 1'], 'Субконто1 1', 'Субконто 1');
    assert.equal(r['Субконто 2'], 'Субконто2 1', 'Субконто 2');
    assert.equal(r['Субконто 3'], 'Субконто3 1', 'Субконто 3');
  });

  await step('click: clickElement({row, column}) попадает в нужную ячейку', async () => {
    const res = await clickElement({ row: { 'Код': 'К2' }, column: 'Срок' });
    assert.equal(res.clicked?.kind, 'gridCell', 'kind=gridCell');
    // Проверяем факт, а не эхо: до правки клик молча уходил в «Исполнитель 2» и рапортовал успех.
    const cell = await focusedCell();
    log(`focused: ${JSON.stringify(cell)}`);
    assert.ok(cell, 'нажатая ячейка помечена в DOM');
    assert.equal(cell.text, 'Срок 2', `клик попал в ячейку «Срок» строки К2, а не в соседнюю (got «${cell.text}»)`);
  });

  await step('click: имя колонки из readTable пригодно для клика (единство именования)', async () => {
    const t = await readTable();
    assert.includes(t.columns, 'Субконто 2', 'имя развёрнутой колонки из readTable');
    const res = await clickElement({ row: { 'Код': 'К2' }, column: 'Субконто 2' });
    assert.equal(res.clicked?.kind, 'gridCell', 'по имени из readTable клик находит ячейку');
    const cell = await focusedCell();
    log(`focused: ${JSON.stringify(cell)}`);
    assert.equal(cell?.text, 'Субконто2 2', `клик попал во второй под-ряд «Субконто» (got «${cell?.text}»)`);
  });

  await step('row-filter: строка ищется по «украденной» колонке', async () => {
    // Фильтр строки идёт через свой резолвер (findRowInGridScript) — тоже геометрия по x,
    // причём без Y-логики. Ищем строку по «Срок», чью ячейку ворует широкий «Исполнитель».
    const res = await clickElement({ row: { 'Срок': 'Срок 2' }, column: 'Код' });
    assert.equal(res.clicked?.kind, 'gridCell', 'строка найдена по значению узкой колонки');
    const cell = await focusedCell();
    log(`focused: ${JSON.stringify(cell)}`);
    assert.equal(cell?.text, 'К2', `найдена именно строка К2 (got «${cell?.text}»)`);
  });

  await step('fill: fillTableRow пишет в колонку со своей шапкой', async () => {
    // Путь записи ищет ячейку по colindex (grid-edit.mjs) — ожидается зелёным и до правки
    // резолверов чтения/клика. Это замер, а не регресс.
    await fillTableRow({ 'Срок': 'Срок изменён' }, { row: { 'Код': 'К3' } });
    const t = await readTable();
    const row = t.rows.find(r => r['Код'] === 'К3');
    log(`after fill: ${JSON.stringify(row)}`);
    assert.equal(row['Срок'], 'Срок изменён', 'значение попало в «Срок»');
    assert.equal(row['Исполнитель'], 'Исполнитель 3', 'соседняя широкая колонка не задета');
    assert.equal(row['Выполнена'], 'Выполнена 3', 'соседняя узкая колонка не задета');
  });

  await step('fill: fillTableRow пишет в РАЗВЁРНУТУЮ колонку (шапки у ячейки нет)', async () => {
    // «Субконто 2» — под-ряд объединённой шапки: своей шапки у ячейки нет, у группы ci=6,
    // а ячейки идут ci=7/8/9. Проверяем, что запись попадает во второй под-ряд, а не в
    // первый и не в соседа.
    await fillTableRow({ 'Субконто 2': 'СК2 изменён' }, { row: { 'Код': 'К1' } });
    const t = await readTable();
    const row = t.rows.find(r => r['Код'] === 'К1');
    log(`after fill: ${JSON.stringify(row)}`);
    assert.equal(row['Субконто 2'], 'СК2 изменён', 'значение попало в «Субконто 2»');
    assert.equal(row['Субконто 1'], 'Субконто1 1', '«Субконто 1» не задета');
    assert.equal(row['Субконто 3'], 'Субконто3 1', '«Субконто 3» не задета');
  });

  await step('cleanup: закрыть форму', async () => {
    await closeForm();
  });
}
