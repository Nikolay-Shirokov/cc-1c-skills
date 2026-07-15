// Runs right after the hang: proves the run KEEPS GOING and the aborted context is
// recreated lazily with a fresh 1C seance (i.e. the license came back — otherwise the
// fix would only trade a hang for "no free license").
export const name = 'hang: следующий тест работает после прерывания';
export const tags = ['hang'];
export const timeout = 60000;

export default async function({ navigateSection, getPageState, assert, log }) {
  const state = await getPageState();
  const names = (state.sections || []).map(s => s.name);
  log('sections after abort: ' + names.join(', '));
  assert.ok(names.length >= 2, 'разделы доступны → сеанс живой, лицензия получена');
  const r = await navigateSection('Склад');
  assert.ok(r.commands?.length > 0, 'команды раздела читаются');
}
