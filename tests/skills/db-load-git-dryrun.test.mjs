import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const PYTHON = process.env.PYTHON || 'python3';

function runPython(script, args, options = {}) {
  return spawnSync(PYTHON, [script, ...args], {
    cwd: ROOT,
    encoding: 'utf8',
    ...options,
  });
}

test('db-load-git dry-run maps changed git files without resolving 1C platform', () => {
  const workDir = mkdtempSync(join(tmpdir(), 'skill-db-load-git-'));
  const configDir = join(workDir, 'config');

  try {
    mkdirSync(join(configDir, 'Catalogs', 'Товары', 'Ext'), { recursive: true });
    spawnSync('git', ['init'], { cwd: configDir, encoding: 'utf8' });
    writeFileSync(join(configDir, 'Catalogs', 'Товары.xml'), '<MetaDataObject/>', 'utf8');
    writeFileSync(join(configDir, 'Catalogs', 'Товары', 'Ext', 'ManagerModule.bsl'), '// test', 'utf8');

    const result = runPython(
      join(ROOT, '.claude/skills/db-load-git/scripts/db-load-git.py'),
      ['-ConfigDir', configDir, '-Source', 'All', '-DryRun'],
    );

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /Git changes detected:/);
    assert.match(result.stdout, /Files for loading:/);
    assert.match(result.stdout, /Catalogs\/Товары\.xml/);
    assert.match(result.stdout, /Catalogs\/Товары\/Ext\/ManagerModule\.bsl/);
    assert.match(result.stdout, /DryRun mode - no changes applied/);
    assert.doesNotMatch(result.stderr, /1C executable not found|Specify -V8Path/);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});
