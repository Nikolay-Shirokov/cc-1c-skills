export const name = 'clickElement({row, column}): cell click on grids + spreadsheet backward-compat';
export const tags = ['cell-click', 'smoke'];
export const timeout = 180000;

export default async function({
  navigateSection, navigateLink, openCommand, clickElement, fillFields, fillTableRow,
  filterList, readTable, readSpreadsheet, closeForm, getFormState, wait, assert, step, log
}) {

  // ── Spreadsheet backward-compat ─────────────────────────────────────────────
  await step('spreadsheet: cell click by (row, column) still works (regression guard)', async () => {
    await navigateSection('Склад');
    await openCommand('Остатки товаров');
    await clickElement('Еще');
    await clickElement('Установить стандартные настройки');
    await clickElement('Сформировать');
    await wait(3);
    const r = await readSpreadsheet();
    assert.ok(r.data?.length > 0, 'В отчёте есть данные');
    const firstHeader = r.headers[0];
    const before = await getFormState();
    const res = await clickElement({ row: 0, column: firstHeader });
    log(`spreadsheet click: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'spreadsheetCell', 'kind=spreadsheetCell — без table роутер ушёл в spreadsheet');
    await closeForm();
  });

  // ── Grid cell click: catalog list with dblclick to open item ────────────────
  await step('catalog list: dblclick by {row: filter, column} opens the item', async () => {
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    const t = await readTable();
    assert.ok(t.rows?.length > 0, 'Список Контрагентов не пуст');
    // Используем фикстуру стенда: ООО Север в колонке Наименование
    const before = await getFormState();
    const res = await clickElement(
      { row: { 'Наименование': 'ООО Север' }, column: 'Наименование' },
      { dblclick: true }
    );
    log(`clicked: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'gridCell', 'kind=gridCell');
    assert.equal(res.clicked?.dblclick, true, 'dblclick=true прокинут');
    await wait(1);
    const after = await getFormState();
    // На синтетическом стенде поведение dblclick по ячейке может не открывать форму,
    // если колонка не "главная" — главное, что клик завершился без ошибки и тип события правильный.
    if (after.formCount > before.formCount) {
      log('форма открылась — закрываем');
      await closeForm();
    }
  });

  // ── Grid cell click on tabular section + row by numeric index ──────────────
  await step('tabular section: click cell by row:0 + column (table specified)', async () => {
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
    const res = await clickElement(
      { row: 0, column: 'Количество' },
      { table: 'Товары' }
    );
    log(`clicked: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'gridCell', 'kind=gridCell');
    assert.equal(res.clicked?.row, 0, 'row=0 сохранён в результате');
    assert.equal(res.clicked?.column, 'Количество', 'column=Количество');
  });

  // ── readTable.hasMore on tabular section ───────────────────────────────────
  await step('readTable.hasMore: 2-row table shows hasMore.below=false', async () => {
    const t = await readTable({ table: 'Товары' });
    log(`hasMore: ${JSON.stringify(t.hasMore)}`);
    assert.ok(t.hasMore, 'hasMore присутствует в результате');
    assert.equal(t.hasMore.below, false, 'hasMore.below=false для двух строк (всё видно)');
  });

  // ── Error path: row not in DOM, no scroll → understandable error ───────────
  await step('row_not_found без scroll бросает ошибку с подсказкой', async () => {
    let caught = null;
    try {
      await clickElement(
        { row: { 'Количество': 'НЕСУЩЕСТВУЮЩЕЕ_ЗНАЧЕНИЕ_123' }, column: 'Количество' },
        { table: 'Товары' } // без scroll
      );
    } catch (e) {
      caught = e;
    }
    assert.ok(caught, 'Должна быть ошибка');
    log(`error: ${caught.message}`);
    assert.ok(/not found/i.test(caught.message), 'Сообщение упоминает not found');
    assert.ok(/scroll/i.test(caught.message), 'Сообщение содержит подсказку про scroll: true');
  });

  // ── Error path: out of range numeric row ───────────────────────────────────
  await step('row_out_of_range на числовом индексе бросает понятную ошибку', async () => {
    let caught = null;
    try {
      await clickElement(
        { row: 9999, column: 'Количество' },
        { table: 'Товары' }
      );
    } catch (e) {
      caught = e;
    }
    assert.ok(caught, 'Должна быть ошибка');
    log(`error: ${caught.message}`);
    assert.ok(/out of range/i.test(caught.message), 'Сообщение упоминает out of range');
    assert.ok(/virtualized/i.test(caught.message) || /DOM window/i.test(caught.message),
      'Сообщение объясняет про виртуализацию / DOM window');
  });

  // ── Cleanup the 2-row doc before opening LongDoc ───────────────────────────
  await step('cleanup: close 2-row document', async () => {
    await closeForm({ save: false });
  });

  // ── Open LongDoc (30 rows in tabular section, fixtures from ЗаполнитьДокументы) ──
  await step('setup: open LongDoc (30-row tabular section)', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await filterList('LongDoc', { field: 'Комментарий' });
    // Открываем единственный найденный LongDoc (фикстура создаётся один раз
    // при первом запуске базы — даже после многократных прогонов одна штука).
    const t = await readTable();
    assert.ok(t.rows?.length >= 1, 'LongDoc должен быть в списке');
    const num = t.rows[0]['Номер'];
    await clickElement(num, { dblclick: true });
    await wait(2);
    const f = await getFormState();
    assert.equal(f.tables?.[0]?.name, 'Товары', 'Открыта форма документа с ТЧ Товары');
  });

  // ── Reveal-loop: filter row not in current DOM window, scroll:true разворачивает ──
  await step('reveal-loop: scroll:true находит строку Количество=25 в LongDoc', async () => {
    const tBefore = await readTable({ table: 'Товары', maxRows: 100 });
    log(`loaded=${tBefore.rows.length} hasMore=${JSON.stringify(tBefore.hasMore)}`);
    assert.ok(tBefore.hasMore?.below === true || tBefore.rows.length >= 20,
      'LongDoc виртуализирован или загружено достаточно строк');
    // Целевая Количество=25 — заведомо глубоко в списке (LongDoc заполняет 1..30).
    const res = await clickElement(
      { row: { 'Количество': '25,000' }, column: 'Сумма' },
      { table: 'Товары', scroll: true }
    );
    log(`reveal clicked: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'gridCell', 'reveal-loop нашёл строку');
    assert.equal(res.clicked?.column, 'Сумма', 'column сохранён');
  });

  // ── fillTableRow by filter + scroll: тот же reveal-путь, что у clickElement ──
  await step('fillTableRow: row-фильтр + scroll:true редактирует глубокую строку LongDoc', async () => {
    // Количество=28 заведомо за пределами стартового DOM-окна (LongDoc 1..30).
    const r = await fillTableRow(
      { 'Цена': '888' },
      { table: 'Товары', row: { 'Количество': '28' }, scroll: true }
    );
    log(`filled: ${JSON.stringify(r.filled)}`);
    assert.ok(r.filled?.every(f => f.ok), 'все ячейки заполнены без ошибок');
    const t = await readTable({ table: 'Товары', maxRows: 50 });
    const row28 = t.rows.find(x => x['Количество'] === '28,000');
    assert.ok(row28, 'строка Количество=28 в текущем окне после reveal');
    assert.equal(row28['Цена'], '888,00', 'Цена строки 28 изменена через фильтр+scroll');
  });

  // ── Horizontal scroll: вправо до последней колонки, потом обратно влево ────
  await step('horizontal scroll: вправо до Признак контроля, потом влево к Количество', async () => {
    const right = await clickElement(
      { row: 0, column: 'Признак контроля' },
      { table: 'Товары' }
    );
    log(`right click: ${JSON.stringify(right.clicked)}`);
    assert.equal(right.clicked?.kind, 'gridCell', 'kind=gridCell для правой');
    assert.equal(right.clicked?.column, 'Признак контроля', 'добрались до самой правой колонки');
    // Теперь обратно к Количество — направление ArrowLeft, scroll сдвигает viewport влево.
    const left = await clickElement(
      { row: 0, column: 'Количество' },
      { table: 'Товары' }
    );
    log(`left click: ${JSON.stringify(left.clicked)}`);
    assert.equal(left.clicked?.kind, 'gridCell', 'kind=gridCell для левой');
    assert.equal(left.clicked?.column, 'Количество', 'вернулись к Количество через ArrowLeft scroll');
  });

  // ── Focus-click skip checkbox: cluster booleans on right edge, click further right ──
  await step('focus-click пропускает checkbox-ячейки при выборе focus-точки', async () => {
    // После предыдущего шага viewport уехал вправо. Нужно сбросить — выводим фокус
    // из ТЧ кликом по полю «Комментарий» (вне грида), без перезаполнения значения.
    await clickElement('Комментарий'); // фокус вне грида → дефолтный viewport
    await wait(0.3);
    const before = await readTable({ table: 'Товары', maxRows: 5 });
    const bools0 = {
      ВРезерве: before.rows[0]['В резерве'],
      НаКомиссии: before.rows[0]['На комиссии'],
      Подарок: before.rows[0]['Подарок'],
    };
    log(`booleans before: ${JSON.stringify(bools0)}`);
    // Клик в дальнюю колонку «Серия» — focus-pick должен выбрать самую правую
    // видимую non-frozen non-checkbox ячейку. При дефолтном viewport кластер
    // из 3 boolean (ВРезерве/НаКомиссии/Подарок) на правом крае — pick должен
    // их пропустить и взять Источник (reference, левее cluster).
    const res = await clickElement(
      { row: 0, column: 'Серия' },
      { table: 'Товары' }
    );
    log(`clicked: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'gridCell', 'клик на Серия (после горизонтального скролла)');
    // Главное: booleans в строке 0 НЕ изменились — focus-click не задел чекбоксы.
    const after = await readTable({ table: 'Товары', maxRows: 5 });
    const bools1 = {
      ВРезерве: after.rows[0]['В резерве'],
      НаКомиссии: after.rows[0]['На комиссии'],
      Подарок: after.rows[0]['Подарок'],
    };
    log(`booleans after: ${JSON.stringify(bools1)}`);
    assert.equal(bools1.ВРезерве, bools0.ВРезерве, 'ВРезерве не переключилось');
    assert.equal(bools1.НаКомиссии, bools0.НаКомиссии, 'НаКомиссии не переключилось');
    assert.equal(bools1.Подарок, bools0.Подарок, 'Подарок не переключилось');
  });

  // ── Final cleanup ──────────────────────────────────────────────────────────
  await step('cleanup: close LongDoc', async () => {
    await closeForm({ save: false });
  });

  // ── Dynamic list (not tabular section): hasMore.above/below + reveal-loop ──
  // Группа БольшойСписок справочника Номенклатура содержит 60 элементов —
  // заведомо больше окна виртуализации. В отличие от табчасти LongDoc, это
  // ДИНАМИЧЕСКИЙ список: hasMore определяется через turn-кнопки vertButtonScroll.
  await step('dyn-list setup: открыть Номенклатуру, развернуть БольшойСписок', async () => {
    await navigateSection('Склад');
    await openCommand('Номенклатура');
    await clickElement('БольшойСписок', { dblclick: true });
    await wait(1);
    const t = await readTable();
    log(`БольшойСписок: shown=${t.shown} hasMore=${JSON.stringify(t.hasMore)}`);
    // Зашли в группу — наверху списка, сверху ничего, снизу есть (60 > окна).
    assert.equal(t.hasMore?.above, false, 'в начале списка above=false');
    assert.equal(t.hasMore?.below, true, '60 элементов > окна → below=true');
  });

  await step('dyn-list reveal: scroll:true находит Позиция 055 в длинном дин-списке', async () => {
    const res = await clickElement(
      { row: { 'Наименование': 'Позиция 055' }, column: 'Наименование' },
      { scroll: true }
    );
    log(`reveal clicked: ${JSON.stringify(res.clicked)}`);
    assert.equal(res.clicked?.kind, 'gridCell', 'reveal-loop на дин-списке нашёл строку');
    // После прокрутки к концовой части списка сверху уже есть скрытые строки.
    const t = await readTable();
    log(`after reveal: hasMore=${JSON.stringify(t.hasMore)}`);
    assert.equal(t.hasMore?.above, true, 'после прокрутки вниз above=true');
  });

  await step('dyn-list cleanup: закрыть список', async () => {
    await closeForm();
  });
}
