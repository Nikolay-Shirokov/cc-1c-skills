import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const PYTHON = process.env.PYTHON || 'python3';

function hasPillow() {
  return spawnSync(PYTHON, ['-c', 'import PIL'], { encoding: 'utf8' }).status === 0;
}

function runPython(script, args, options = {}) {
  return spawnSync(PYTHON, [script, ...args], {
    cwd: ROOT,
    encoding: 'utf8',
    ...options,
  });
}

function readPngSize(path) {
  const data = readFileSync(path);
  assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  return {
    width: data.readUInt32BE(16),
    height: data.readUInt32BE(20),
  };
}

test('img-grid overlays a numbered grid and saves a PNG with label margins', { skip: hasPillow() ? false : 'Pillow is not installed' }, () => {
  const workDir = mkdtempSync(join(tmpdir(), 'skill-img-grid-'));
  const inputPath = join(workDir, 'input.png');
  const outputPath = join(workDir, 'output.png');

  try {
    writeFileSync(
      inputPath,
      Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=', 'base64'),
    );

    const result = runPython(
      join(ROOT, '.claude/skills/img-grid/scripts/overlay-grid.py'),
      [inputPath, '-c', '5', '-r', '4', '-o', outputPath],
    );

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(existsSync(outputPath), true);
    assert.match(result.stdout, /Grid: 5 x 4 cells/);
    assert.match(result.stdout, /Saved:/);
    assert.deepEqual(readPngSize(outputPath), { width: 25, height: 21 });
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});

test('img-grid rejects non-positive column count with a CLI error', { skip: hasPillow() ? false : 'Pillow is not installed' }, () => {
  const workDir = mkdtempSync(join(tmpdir(), 'skill-img-grid-invalid-'));
  const inputPath = join(workDir, 'input.png');
  const outputPath = join(workDir, 'output.png');

  try {
    writeFileSync(
      inputPath,
      Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=', 'base64'),
    );

    const result = runPython(
      join(ROOT, '.claude/skills/img-grid/scripts/overlay-grid.py'),
      [inputPath, '-c', '0', '-o', outputPath],
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /--cols must be greater than 0/);
    assert.doesNotMatch(result.stderr, /Traceback|ZeroDivisionError/);
    assert.equal(existsSync(outputPath), false);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});
