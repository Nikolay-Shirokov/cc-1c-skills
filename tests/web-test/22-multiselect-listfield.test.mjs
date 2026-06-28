export const name = 'multi-select: selectValue(field, [v1,v2]) across 5 value-list surfaces';
export const tags = ['multiselect', 'selectvalue', 'smoke'];
export const timeout = 420000;

// selectValue с массивом значений → мультивыбор в полях типа «список значений».
// Стенд: обработка МножественныйВыбор, 5 поверхностей:
//   ЧерезФлажки → checkbox-form, ЧерезПодбор → pool+Подбор, ОрганизацииСписок → cloudDD,
//   КонтрагентыСписок → catalog multi-row (Ctrl), СписокПлатформенный → platform pool+Подбор.

const sortq = a => [...a].sort();

export default async function({ navigateLink, selectValue, getFormState, wait, assert, step, log }) {

  const fieldValue = async (name) => {
    const fs = await getFormState();
    return (fs.fields || []).find(f => f.name === name)?.value || '';
  };

  await step('setup: открыть обработку МножественныйВыбор', async () => {
    await navigateLink('Обработка.МножественныйВыбор');
    await wait(1);
  });

  // ── A: custom checkbox form (all candidates) ────────────────────────────────
  await step('A (checkbox-form): выбрать [Альфа, Бета]', async () => {
    const r = await selectValue('Через флажки', ['Альфа', 'Бета']);
    log(`A selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(sortq(r.selected.values), sortq(['Альфа', 'Бета']), 'оба значения выбраны');
    assert.ok(!r.selected.notSelected, 'notSelected отсутствует');
    assert.equal(await fieldValue('ЧерезФлажки'), 'Альфа, Бета', 'значение поля = набор');
  });

  await step('A: replace на подмножество + несуществующее [Бета, Гамма]', async () => {
    const r = await selectValue('Через флажки', ['Бета', 'Гамма']);
    log(`A2 selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(r.selected.values, ['Бета'], 'осталась только Бета (Альфа снята)');
    assert.ok(r.selected.notSelected?.some(n => n.value === 'Гамма'), 'Гамма → notSelected');
    assert.equal(await fieldValue('ЧерезФлажки'), 'Бета', 'replace: поле = Бета');
  });

  // ── B: custom pool + Подбор (catalog Номенклатура) ──────────────────────────
  await step('B (pool+Подбор): выбрать [Товар 01, Товар 02]', async () => {
    const r = await selectValue('Через подбор', ['Товар 01', 'Товар 02']);
    log(`B selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(sortq(r.selected.values), sortq(['Товар 01', 'Товар 02']), 'оба товара подобраны');
    assert.ok(!r.selected.notSelected, 'notSelected отсутствует');
  });

  await step('B: replace на [Товар 02] (очистка пула Ctrl+A+Delete)', async () => {
    const r = await selectValue('Через подбор', ['Товар 02']);
    log(`B2 selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(r.selected.values, ['Товар 02'], 'остался только Товар 02');
    assert.equal(await fieldValue('ЧерезПодбор'), 'Товар 02', 'replace: поле = Товар 02');
  });

  // ── C: platform cloudDD checkbox dropdown ───────────────────────────────────
  await step('C (cloudDD): выбрать [Альфа, Бета]', async () => {
    const r = await selectValue('Организации (список)', ['Альфа', 'Бета']);
    log(`C selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(sortq(r.selected.values), sortq(['Альфа', 'Бета']), 'оба выбраны в дропдауне');
    assert.equal(await fieldValue('ОрганизацииСписок'), 'Альфа, Бета', 'значение поля = набор');
  });

  await step('C: replace на [Бета] (снятие + клик-вне)', async () => {
    const r = await selectValue('Организации (список)', ['Бета']);
    log(`C2 selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(r.selected.values, ['Бета'], 'осталась только Бета');
    assert.equal(await fieldValue('ОрганизацииСписок'), 'Бета', 'replace в cloudDD');
  });

  // ── D: platform catalog multi-row select (Ctrl) ─────────────────────────────
  await step('D (catalog multi-row): выбрать [АО Запад, ООО Восток]', async () => {
    const r = await selectValue('Контрагенты (список)', ['АО Запад', 'ООО Восток']);
    log(`D selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(sortq(r.selected.values), sortq(['АО Запад', 'ООО Восток']), 'обе строки выбраны Ctrl-кликом');
    assert.equal(await fieldValue('КонтрагентыСписок'), 'АО Запад, ООО Восток', 'значение поля = набор');
  });

  // ── E: platform pool + Подбор (catalog Контрагенты) ─────────────────────────
  await step('E (platform pool+Подбор): выбрать [ООО Север, ООО Юг]', async () => {
    const r = await selectValue('Без расширенного', ['ООО Север', 'ООО Юг']);
    log(`E selected: ${JSON.stringify(r.selected)}`);
    assert.deepEqual(sortq(r.selected.values), sortq(['ООО Север', 'ООО Юг']), 'оба контрагента подобраны');
    assert.ok(!r.selected.notSelected, 'notSelected отсутствует');
  });
}
