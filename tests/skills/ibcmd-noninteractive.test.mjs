import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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

test('db-update reports a diagnostic timeout when ibcmd does not exit', { skip: process.platform === 'win32' }, () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'skill-ibcmd-timeout-'));
  const fakeIbcmd = join(tempDir, 'ibcmd');
  const infoBaseDir = join(tempDir, 'ib');

  try {
    mkdirSync(infoBaseDir, { recursive: true });
    writeFileSync(fakeIbcmd, '#!/bin/sh\nsleep 5\nexit 0\n', 'utf8');
    chmodSync(fakeIbcmd, 0o755);

    const result = runPython(
      join(ROOT, '.claude/skills/db-update/scripts/db-update.py'),
      ['-V8Path', fakeIbcmd, '-InfoBasePath', infoBaseDir],
      {
        env: { ...process.env, CC_1C_IBCMD_TIMEOUT: '0.5' },
        timeout: 2500,
      },
    );

    assert.notEqual(result.error?.code, 'ETIMEDOUT', 'wrapper must stop hung ibcmd itself');
    assert.equal(result.status, 124, result.stderr || result.stdout);
    assert.match(result.stderr, /ibcmd/i);
    assert.match(result.stderr, /timeout/i);
    assert.match(result.stderr, /-UserName|-Password/);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});
