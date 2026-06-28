import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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

test('subsystem-compile python port validates via python, not powershell.exe', { skip: process.platform === 'win32' }, () => {
  const workDir = mkdtempSync(join(tmpdir(), 'skill-subsystem-'));
  const inputFile = join(workDir, 'subsystem.json');
  writeFileSync(inputFile, JSON.stringify({ name: 'Тест' }), 'utf8');

  try {
    const result = runPython(
      join(ROOT, '.claude/skills/subsystem-compile/scripts/subsystem-compile.py'),
      ['-DefinitionFile', inputFile, '-OutputDir', workDir],
    );

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.doesNotMatch(result.stderr, /powershell\.exe/i);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test('db-update accepts a macOS platform directory containing 1cv8', { skip: process.platform === 'win32' }, () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'skill-v8path-'));
  const binDir = join(tempDir, 'platform');
  const fake1cv8 = join(binDir, '1cv8');
  const infoBaseDir = join(tempDir, 'ib');
  const markerFile = join(tempDir, 'called');

  try {
    mkdirSync(binDir, { recursive: true });
    mkdirSync(infoBaseDir, { recursive: true });
    writeFileSync(fake1cv8, `#!/bin/sh\ntouch "${markerFile}"\nexit 0\n`, 'utf8');
    chmodSync(fake1cv8, 0o755);

    const result = runPython(
      join(ROOT, '.claude/skills/db-update/scripts/db-update.py'),
      ['-V8Path', binDir, '-InfoBasePath', infoBaseDir],
    );

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(existsSync(markerFile), true);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});
