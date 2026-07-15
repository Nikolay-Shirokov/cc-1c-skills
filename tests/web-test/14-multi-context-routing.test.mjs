export const name = 'Multi-context: routing single test to non-default context';
export const tags = ['multi-context', 'smoke'];
export const context = 'c';
export const timeout = 60000;

export default async function({ getPageState, navigateSection, openCommand, closeForm, assert, step, log }) {

  await step('Active context is c', async () => {
    // Sanity check — ensure we are routed into c's session (a third, non-default context).
    // Leaving c open here is intentional: it becomes the LRU eviction candidate at the
    // 14→15 boundary under maxContexts:2 (asserted in 15-multi-context-handover).
    const state = await getPageState();
    assert.ok(Array.isArray(state.sections) && state.sections.length, 'Sections should be visible');
    log('Sections in c: ' + state.sections.map(s => s.name).join(', '));
  });

  await step('Open Контрагенты in context c', async () => {
    await navigateSection('Склад');
    const state = await openCommand('Контрагенты');
    assert.ok(state.form != null, 'List form should open');
    log('Opened in c: ' + state.title);
    await closeForm();
  });
}
