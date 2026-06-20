// support-guard.mjs v1.0 — PreToolUse hook (§1A): block raw Edit/Write/MultiEdit of
// vendor objects "на замке" / read-only configs that bypass the in-skill guard (§1B).
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// stdin: PreToolUse JSON { tool_name, tool_input, cwd, ... }.
// Decision via stdout JSON hookSpecificOutput.permissionDecision (deny) — see
// docs/1c-support-state-spec.md. Reaction (deny|warn|off) from .v8-project.json
// editingAllowedCheck, identical to §1B. Never blocks on its own errors.

import { decideSupport } from './common/support-state.mjs';
import { getEditMode } from './common/project.mjs';
import { resolve, isAbsolute } from 'node:path';

// Collect candidate file paths from an Edit/Write/MultiEdit tool_input. Handles the
// single-file form ({ file_path }) and the array form ({ file_edits: [{ file_path }] }).
function candidatePaths(toolInput) {
  const out = [];
  if (!toolInput || typeof toolInput !== 'object') return out;
  if (typeof toolInput.file_path === 'string') out.push(toolInput.file_path);
  if (Array.isArray(toolInput.file_edits)) {
    for (const e of toolInput.file_edits) {
      if (e && typeof e.file_path === 'string') out.push(e.file_path);
    }
  }
  return out;
}

// Tailored, model-actionable diagnostic per block cause (see decideSupport `code`).
// Fills in the real target/config paths so the suggested commands are ready to run.
function diagnostic(code, target, cfgDir) {
  const head =
    '[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, ' +
    'прямое редактирование молча сломает будущие обновления.';
  const cfe =
    'Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — ' +
    'состояние поддержки менять не нужно, обновления вендора сохраняются.';
  const offNote = 'Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json.';
  const root = cfgDir || '<каталог дампа>';

  if (code === 'capability-off') {
    return [
      head,
      `Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — ` +
        `поэтому объект «${target}» редактировать нельзя.`,
      cfe,
      `Либо снять защиту явно (навык support-edit, два шага):`,
      `  1. support-edit -Path "${root}" -Capability on   — включить возможность изменения (объекты пока остаются на замке);`,
      `  2. support-edit -Path "${target}" -Set editable   — открыть этот объект для редактирования.`,
      `Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора.`,
      offNote,
    ].join('\n');
  }
  if (code === 'not-removed') {
    return [
      head,
      `Состояние: объект «${target}» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора.`,
      cfe,
      `Либо сначала снять объект с поддержки, затем удалять:`,
      `  support-edit -Path "${target}" -Set off-support   — объект уходит из-под обновлений, после этого удаление безопасно.`,
      offNote,
    ].join('\n');
  }
  // locked (G=0, f1=0)
  return [
    head,
    `Состояние: объект «${target}» на замке (возможность изменения конфигурации включена, но сам объект не редактируется).`,
    cfe,
    `Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`,
    `  • support-edit -Path "${target}" -Set editable      — редактировать и дальше получать обновления вендора (при обновлении возможны конфликты слияния);`,
    `  • support-edit -Path "${target}" -Set off-support   — снять с поддержки: редактирование свободно, обновления по объекту больше не приходят.`,
    offNote,
  ].join('\n');
}

// Core decision. Returns { stdout, stderr, exitCode }. Pure (no I/O) for testability.
export function processInput(input) {
  const empty = { stdout: '', stderr: '', exitCode: 0 };
  try {
    const cwd = typeof input.cwd === 'string' ? input.cwd : process.cwd();
    const paths = candidatePaths(input.tool_input);
    for (const p of paths) {
      const target = isAbsolute(p) ? p : resolve(cwd, p);
      const r = decideSupport(target, 'editable');
      if (!r.blocked) continue;
      const mode = getEditMode(r.cfgDir, cwd);
      if (mode === 'off') continue;
      if (mode === 'warn') {
        return { stdout: '', stderr: `[support-guard] ПРЕДУПРЕЖДЕНИЕ: ${r.reason}. Цель: ${target}`, exitCode: 0 };
      }
      // deny (default): structured PreToolUse decision.
      const decision = {
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: diagnostic(r.code, target, r.cfgDir),
        },
      };
      return { stdout: JSON.stringify(decision), stderr: '', exitCode: 0 };
    }
    return empty;
  } catch {
    return empty; // guard errors must never block
  }
}

async function readStdin() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString('utf8');
}

// Run only when executed directly (not when imported by tests).
if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('support-guard.mjs')) {
  const raw = await readStdin();
  let input = {};
  try { input = raw.trim() ? JSON.parse(raw) : {}; } catch { input = {}; }
  const { stdout, stderr, exitCode } = processInput(input);
  if (stdout) process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr + '\n');
  process.exit(exitCode);
}
