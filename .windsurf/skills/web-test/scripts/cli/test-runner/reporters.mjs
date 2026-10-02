// web-test cli/test-runner/reporters v1.0 — Allure/JUnit writers + extras sync
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { writeFileSync, existsSync, readdirSync, copyFileSync, statSync } from 'fs';
import { resolve, dirname, basename, relative } from 'path';
import { randomUUID } from 'crypto';
import { xmlEscape } from '../util.mjs';
import { resolveSeverity } from './severity.mjs';

/**
 * Copy any files from `<testDir>/_allure/` into `reportDir`. Convention for
 * Allure customization that doesn't fit inside per-test JSON:
 *   - `categories.json` — failure classification (regex → bucket)
 *   - `environment.properties` — values shown in the Environment widget
 *   - `executor.json` — CI/CD metadata
 * Underscored folder mirrors `_hooks.mjs` convention (infra, not a test).
 * Silent if folder absent.
 */
export function syncAllureExtras(testDir, reportDir) {
  const extrasDir = resolve(testDir, '_allure');
  if (!existsSync(extrasDir)) return;
  try {
    if (!statSync(extrasDir).isDirectory()) return;
  } catch { return; }
  for (const entry of readdirSync(extrasDir, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    try { copyFileSync(resolve(extrasDir, entry.name), resolve(reportDir, entry.name)); }
    catch { /* best-effort */ }
  }
}

export function writeAllure(results, reportDir, severityIndex) {
  for (const tr of results) {
    if (tr.status === 'skipped') continue; // Allure ignores skipped without start/stop
    const uuid = randomUUID();
    const suite = dirname(tr.file);
    const suiteLabel = (suite && suite !== '.') ? suite : 'root';
    const severity = resolveSeverity(tr, severityIndex);
    const out = {
      uuid,
      name: tr.name,
      fullName: tr.file,
      status: tr.status,
      stage: 'finished',
      start: tr.start,
      stop: tr.stop,
      labels: [
        ...(tr.tags || []).map(t => ({ name: 'tag', value: t })),
        { name: 'suite', value: suiteLabel },
        { name: 'severity', value: severity },
      ],
      steps: (tr.steps || []).map(allureStep),
      attachments: [
        ...(tr.screenshot ? [{ name: 'Screenshot on failure', source: basename(tr.screenshot), type: 'image/png' }] : []),
        ...(tr.video ? [{ name: 'Video', source: basename(tr.video), type: 'video/mp4' }] : []),
      ],
    };
    if (tr.status === 'failed' && tr.error) {
      const traceParts = [];
      if (tr.output) traceParts.push(tr.output);
      const onecStack = tr.error.onecError?.stack?.raw;
      if (onecStack) {
        if (traceParts.length) traceParts.push('\n--- 1C stack ---\n');
        traceParts.push(onecStack);
      }
      out.statusDetails = { message: tr.error.message || '', trace: traceParts.join('') };
    }
    writeFileSync(resolve(reportDir, `${uuid}-result.json`), JSON.stringify(out, null, 2));
  }
}

function allureStep(s) {
  const out = {
    name: s.name,
    status: s.status,
    stage: 'finished',
    start: s.start,
    stop: s.stop,
    steps: (s.steps || []).map(allureStep),
  };
  if (s.screenshot) {
    out.attachments = [{ name: 'Screenshot', source: basename(s.screenshot), type: 'image/png' }];
  }
  if (s.status === 'failed' && s.error) {
    out.statusDetails = { message: s.error, trace: s.error };
  }
  return out;
}

export function buildJUnit(report, testDir) {
  const { summary, duration, tests } = report;
  const suiteName = relative(process.cwd(), testDir).replace(/\\/g, '/') || '.';
  const lines = ['<?xml version="1.0" encoding="UTF-8"?>'];
  lines.push(`<testsuites name="web-test" tests="${summary.total}" failures="${summary.failed}" skipped="${summary.skipped}" time="${duration.toFixed(3)}">`);
  lines.push(`  <testsuite name="${xmlEscape(suiteName)}" tests="${summary.total}" failures="${summary.failed}" skipped="${summary.skipped}" time="${duration.toFixed(3)}">`);
  for (const t of tests) {
    const attrs = `name="${xmlEscape(t.name)}" classname="${xmlEscape(t.file)}" time="${(t.duration || 0).toFixed(3)}"`;
    if (t.status === 'passed') {
      lines.push(`    <testcase ${attrs}/>`);
    } else if (t.status === 'skipped') {
      lines.push(`    <testcase ${attrs}><skipped/></testcase>`);
    } else {
      lines.push(`    <testcase ${attrs}>`);
      const msg = t.error?.message || '';
      const trace = t.output || '';
      lines.push(`      <failure message="${xmlEscape(msg)}">${xmlEscape(trace)}</failure>`);
      if (t.screenshot) lines.push(`      <system-out>screenshot: ${xmlEscape(t.screenshot)}</system-out>`);
      lines.push(`    </testcase>`);
    }
  }
  lines.push(`  </testsuite>`);
  lines.push(`</testsuites>`);
  return lines.join('\n');
}
