// The only test of the suite-root fixture. Kept as light as possible — it is not here to test
// the application, it is here to be run as `test tests/web-test/_suite-root/nested/` and prove
// that config (URL) and hooks were resolved one level up. Before v1.9 that invocation died with
// "No URL provided and no webtest.config.mjs found".
import { existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const SUITE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export const name = 'suite-root: конфиг и хуки подхвачены на уровень выше';
export const tags = ['suite-root'];
export const timeout = 60000;

export default async function({ getPageState, assert, log }) {
  const state = await getPageState();
  const names = (state.sections || []).map(s => s.name);
  log('sections: ' + names.join(', '));
  assert.ok(names.length >= 1, 'сеанс открыт → URL взят из конфига в корне сюиты');
  assert.ok(existsSync(resolve(SUITE_ROOT, 'prepare-ran.txt')),
    'prepare() отработал → _hooks.mjs взят из корня сюиты, а не потерян');
}
