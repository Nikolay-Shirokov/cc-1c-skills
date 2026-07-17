export const name = 'row-state: ведущая иконка состояния строки (_rowPic + булевы)';
export const tags = ['row-state', 'table'];
export const timeout = 90000;

export default async function({ navigateSection, openCommand, clickElement, closeForm, readTable, getPage, assert, step, log }) {

  await step('документы: _posted / _deleted по заданным состояниям', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    const t = await readTable({ maxRows: 50 });
    const byComment = (c) => t.rows.find(r => r['Комментарий'] === c);

    const posted = byComment('StatePosted');
    const deleted = byComment('StateDeleted');
    const written = byComment('StateWritten');
    log(`posted=${JSON.stringify(posted?._rowPic)} deleted=${JSON.stringify(deleted?._rowPic)} written=${JSON.stringify(written?._rowPic)}`);
    assert.ok(posted && deleted && written, 'три документа-фикстуры состояний видны в списке');

    // Проведён: _posted true, пометки нет
    assert.equal(posted._posted, true, 'StatePosted → _posted true');
    assert.equal(posted._deleted, false, 'StatePosted → _deleted false');

    // Помечен на удаление. Пометка проведённого его распроводит, поэтому _posted здесь false.
    assert.equal(deleted._deleted, true, 'StateDeleted → _deleted true');

    // Записан, но не проведён — обе оси явный false, а не отсутствие ключа
    assert.equal(written._posted, false, 'StateWritten → _posted false');
    assert.equal(written._deleted, false, 'StateWritten → _deleted false');

    // Сырьё указывает на платформенный спрайт документов
    assert.ok(/^e1csys\/basic\/docList\.zip:\d+$/.test(posted._rowPic), `_rowPic формата docList.zip:<gx> (got ${posted._rowPic})`);
  });

  await step('ловушка: произвольная картинка ПЕРЕД значком состояния не подменяет его', async () => {
    // Безымянная колонка «Метка» (picField над Posted) рисует pictureCollection в colindex 0,
    // а платформенный значок состояния идёт ПОСЛЕ неё. Экстрактор, берущий
    // line.querySelector('.gridBoxImg') вместо перебора всех .dIB, схватит картинку колонки
    // и потеряет состояние. Гард ниже — через DOM: колонка безымянная и в columns не
    // попадает (её наличие readTable определяет по первой строке, а там Posted=false →
    // картинки нет), поэтому проверить её через публичный API нельзя.
    // Колонка безымянная (titleLocation:none) → readTable называет её '(picture)'. Её наличие
    // определяется сэмплированием НЕСКОЛЬКИХ строк: picField над Posted не рисует картинку при
    // Ложь, а первая строка списка — непроведённый документ. По одной первой строке колонка
    // выпадала из columns целиком.
    const tt = await readTable({ maxRows: 50 });
    assert.includes(tt.columns, '(picture)', 'безымянная picture-колонка есть в columns');
    const postedRow = tt.rows.find(r => r['Комментарий'] === 'StatePosted');
    assert.equal(postedRow['(picture)'], 'pic:0', 'у проведённого документа картинка нарисована');

    const page = await getPage();
    const icons = await page.evaluate(() => {
      const grid = [...document.querySelectorAll('.grid')].find(g => g.offsetWidth > 0 && g.offsetHeight > 0);
      const line = [...grid.querySelectorAll('.gridBody .gridLine')].find(l => (l.innerText || '').includes('StatePosted'));
      if (!line) return null;
      return [...line.querySelectorAll('.gridBoxImg .dIB')]
        .map(d => d.style.backgroundImage || '')
        .filter(Boolean)
        .map(bg => bg.includes('convertPicture') ? 'state' : (bg.includes('pictureCollection') ? 'arbitrary' : 'other'));
    });
    log(`icons in row: ${JSON.stringify(icons)}`);
    assert.ok(icons, 'строка StatePosted найдена в DOM');
    assert.includes(icons, 'arbitrary', 'ловушка на месте: в строке есть произвольная картинка');
    assert.includes(icons, 'state', 'в строке есть платформенный значок состояния');
    assert.equal(icons[0], 'arbitrary', 'произвольная картинка идёт ПЕРВОЙ — первый .gridBoxImg не тот');

    const t = await readTable({ maxRows: 50 });
    const posted = t.rows.find(r => r['Комментарий'] === 'StatePosted');
    assert.ok(posted, 'документ StatePosted виден');
    assert.ok(posted._rowPic?.startsWith('e1csys/basic/docList.zip:'),
      `_rowPic должен указывать на спрайт состояния, а не на картинку колонки (got ${posted._rowPic})`);
    assert.equal(posted._posted, true, 'состояние разобрано несмотря на картинку перед ним');
  });

  await step('справочник: _deleted / _predefined на элементах Номенклатуры', async () => {
    await navigateSection('Склад');
    await openCommand('Номенклатура');
    await clickElement('Ещё');
    await clickElement('Установить стандартные настройки');
    // Список показывает группы верхнего уровня — элементы прячутся внутри Товары.
    await clickElement('Товары', { expand: true });
    const t = await readTable({ maxRows: 50 });

    const marked = t.rows.find(r => r['Наименование'] === 'Товар помеченный');
    const normal = t.rows.find(r => r['Наименование'] === 'Товар 01');
    log(`marked=${JSON.stringify(marked?._rowPic)} normal=${JSON.stringify(normal?._rowPic)}`);
    assert.ok(marked && normal, 'помеченный и обычный товары видны');

    assert.equal(marked._deleted, true, 'Товар помеченный → _deleted true');
    assert.equal(normal._deleted, false, 'Товар 01 → _deleted false');
    assert.equal(normal._predefined, false, 'Товар 01 → _predefined false');
    assert.ok(/^e1csys\/basic\/folder\.zip:\d+$/.test(normal._rowPic), `_rowPic формата folder.zip:<gx> (got ${normal._rowPic})`);
  });

  await step('негатив: у табчасти формы ведущей иконки нет — полей не появляется', async () => {
    await navigateSection('Склад');
    await openCommand('Приходная накладная');
    await clickElement('Создать');
    const t = await readTable({ table: 'Товары' });
    // Табчасть — не список объектов, состояния у строки нет. Отсутствие ключа значит
    // «не знаю», и это правильный ответ, а не _deleted:false.
    assert.ok(t.rows.every(r => r._rowPic === undefined), 'ни у одной строки нет _rowPic');
    assert.ok(t.rows.every(r => r._deleted === undefined), 'ни у одной строки нет _deleted');
    await closeForm();
  });
}
