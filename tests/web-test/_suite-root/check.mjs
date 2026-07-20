// web-test _suite-root/check v1.0 — offline verdict for the suite-root resolver
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// findSuiteRoot decides where `webtest.config.mjs` and `_hooks.mjs` are loaded from. Getting it
// wrong is silent: the run picks up someone else's hooks, or none at all, and still goes green.
// Every rule of the climb is pinned here on throw-away trees — no 1C stand, no browser.
//
//   node tests/web-test/_suite-root/check.mjs
//
// Exit codes: 0 — resolver behaves; 1 — a rule regressed.
import { mkdirSync, writeFileSync, rmSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { tmpdir } from 'os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(__dirname, '../../..');
const { findSuiteRoot } = await import(
  'file:///' + resolve(REPO, '.claude/skills/web-test/scripts/cli/test-runner/suite-root.mjs').replace(/\\/g, '/')
);

const BASE = resolve(tmpdir(), 'web-test-suite-root-check');
rmSync(BASE, { recursive: true, force: true });

/** Build a tree from a list of relative paths; a path ending in `/` is a dir, otherwise a file. */
function tree(name, entries) {
  const root = resolve(BASE, name);
  for (const e of entries) {
    const full = resolve(root, e);
    if (e.endsWith('/')) mkdirSync(full, { recursive: true });
    else { mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, '// fixture\n'); }
  }
  return root;
}

let failed = 0;
function check(label, actual, expected) {
  const a = actual === null ? 'null' : actual;
  const e = expected === null ? 'null' : expected;
  if (a === e) { console.log(`  ok   ${label}`); return; }
  console.log(`  FAIL ${label}\n         expected: ${e}\n         actual:   ${a}`);
  failed++;
}
const rootOf = (r) => (r ? r.root : null);

// 1. Config one level up — the IRG case: `test tests/irg/00-smoke/`.
{
  const t = tree('t1', ['suite/webtest.config.mjs', 'suite/00-smoke/x.test.mjs']);
  check('config one level up', rootOf(findSuiteRoot(resolve(t, 'suite/00-smoke'), { cwd: t })), resolve(t, 'suite'));
}

// 2. Two levels up, and the marker is _hooks.mjs only — a suite with no config still resolves,
//    otherwise its stand preparation would be silently skipped.
{
  const t = tree('t2', ['suite/_hooks.mjs', 'suite/a/b/x.test.mjs']);
  check('hooks-only marker, two levels up', rootOf(findSuiteRoot(resolve(t, 'suite/a/b'), { cwd: t })), resolve(t, 'suite'));
}

// 3. A file path resolves from its own directory.
{
  const t = tree('t3', ['suite/webtest.config.mjs', 'suite/a/x.test.mjs']);
  check('file path → its directory', rootOf(findSuiteRoot(resolve(t, 'suite/a/x.test.mjs'), { cwd: t })), resolve(t, 'suite'));
}

// 4. Nearest marker wins — a nested suite is not swallowed by its parent (the `_hang/` case).
{
  const t = tree('t4', ['suite/webtest.config.mjs', 'suite/inner/webtest.config.mjs', 'suite/inner/x.test.mjs']);
  check('nearest marker wins', rootOf(findSuiteRoot(resolve(t, 'suite/inner'), { cwd: t })), resolve(t, 'suite/inner'));
}

// 5-6. Boundaries stop the climb: a config above `.git` / `.v8-project.json` is NOT ours.
{
  const t = tree('t5', ['webtest.config.mjs', 'proj/.git/', 'proj/a/x.test.mjs']);
  check('.git bounds the climb', rootOf(findSuiteRoot(resolve(t, 'proj/a'), { cwd: t })), null);
}
{
  const t = tree('t6', ['webtest.config.mjs', 'proj/.v8-project.json', 'proj/a/x.test.mjs']);
  check('.v8-project.json bounds the climb', rootOf(findSuiteRoot(resolve(t, 'proj/a'), { cwd: t })), null);
}

// 7. The boundary directory is itself examined — a marker sitting next to `.git` is found.
{
  const t = tree('t7', ['proj/.git/', 'proj/webtest.config.mjs', 'proj/a/x.test.mjs']);
  check('boundary dir is inclusive', rootOf(findSuiteRoot(resolve(t, 'proj/a'), { cwd: t })), resolve(t, 'proj'));
}

// 8. With no repo marker, cwd bounds the climb — nothing above the working directory is picked up.
{
  const t = tree('t8', ['webtest.config.mjs', 'work/a/x.test.mjs']);
  check('cwd bounds the climb', rootOf(findSuiteRoot(resolve(t, 'work/a'), { cwd: resolve(t, 'work') })), null);
}

// 9. cwd is inclusive too.
{
  const t = tree('t9', ['work/webtest.config.mjs', 'work/a/x.test.mjs']);
  check('cwd is inclusive', rootOf(findSuiteRoot(resolve(t, 'work/a'), { cwd: resolve(t, 'work') })), resolve(t, 'work'));
}

// 10. No marker anywhere → null, and the caller falls back to the passed directory.
{
  const t = tree('t10', ['proj/.git/', 'proj/a/x.test.mjs']);
  check('no marker → null', rootOf(findSuiteRoot(resolve(t, 'proj/a'), { cwd: t })), null);
}

// 11. Real repo: this fixture's own directory carries the markers, so `nested/` climbs one level.
{
  const here = resolve(REPO, 'tests/web-test/_suite-root/nested');
  check('repo fixture: nested/ → _suite-root/', rootOf(findSuiteRoot(here, { cwd: REPO })), dirname(here));
}

// 12. Real repo: the flat suite resolves to itself.
{
  const suite = resolve(REPO, 'tests/web-test');
  check('repo: tests/web-test/ → itself', rootOf(findSuiteRoot(suite, { cwd: REPO })), suite);
}

rmSync(BASE, { recursive: true, force: true });
console.log(failed ? `\n${failed} check(s) FAILED\n` : '\nall checks passed\n');
process.exit(failed ? 1 : 0);
