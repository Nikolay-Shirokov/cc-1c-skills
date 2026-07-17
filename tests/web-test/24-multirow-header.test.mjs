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

export default async function({ navigateSection, openCommand, clickElement, closeForm, readTable, fillTableRow, assert, step, log }) {

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

  await step('click: clickElement({row, column}) попадает в нужную колонку', async () => {
    const res = await clickElement({ row: { 'Код': 'К2' }, column: 'Срок' });
    log(`clicked: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'gridCell', 'kind=gridCell');
    assert.equal(res.clicked?.column, 'Срок', 'column=Срок');
  });

  await step('click: имя колонки из readTable пригодно для клика (единство именования)', async () => {
    const t = await readTable();
    assert.includes(t.columns, 'Субконто 2', 'имя развёрнутой колонки из readTable');
    const res = await clickElement({ row: { 'Код': 'К2' }, column: 'Субконто 2' });
    log(`clicked: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'gridCell', 'по имени из readTable клик находит ячейку');
  });

  await step('fill: fillTableRow пишет значение в нужную колонку', async () => {
    // Путь записи ищет ячейку по colindex (grid-edit.mjs), поэтому ожидается зелёным
    // и до правки резолверов чтения/клика — это замер, а не регресс.
    await fillTableRow({ 'Срок': 'Срок изменён' }, { row: { 'Код': 'К3' } });
    const t = await readTable();
    const row = t.rows.find(r => r['Код'] === 'К3');
    log(`after fill: ${JSON.stringify(row)}`);
    assert.equal(row['Срок'], 'Срок изменён', 'значение попало в «Срок»');
    assert.equal(row['Исполнитель'], 'Исполнитель 3', 'соседняя широкая колонка не задета');
    assert.equal(row['Выполнена'], 'Выполнена 3', 'соседняя узкая колонка не задета');
  });

  await step('cleanup: закрыть форму', async () => {
    await closeForm();
  });
}
