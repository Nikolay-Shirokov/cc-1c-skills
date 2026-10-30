// _hooks.mjs v1.0 — связка раннера web-test со стендом (_stand.mjs). Раннер вызывает prepare()
// один раз до старта браузера; всё после `--` в командной строке приходит в hookArgs.

import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadStandConfig, runStages, parseFlags } from './_stand.mjs';

export async function prepare({ hookArgs, log }) {
  await runStages(loadStandConfig(), parseFlags(hookArgs), log);
}

export async function cleanup({ log }) {
  const stand = relative(process.cwd(), fileURLToPath(new URL('./_stand.mjs', import.meta.url)));
  log(`стенд оставлен поднятым (погасить — node ${stand} down; полный сброс — прогон с \`-- --rebuild-stand\`)`);
}

// Закрывать контексты в хуках не нужно: пул 1С-лицензий держит раннер — вытесняет лишние сеансы
// перед тестом и переиспользует открытые (maxContexts / contextPolicy / pinnedContexts в
// webtest.config.mjs). Ручное закрытие вслепую стоит повторного входа (~10–15 с) соседним тестам.

// Конфигурации на БСП после восстановления из .dt на первом входе показывают диалог
// «Информационная база перемещена / Это копия информационной базы». В мини-решении примера БСП
// нет и диалога нет; в своём проекте ответьте на него один раз — остальные сеансы его не увидят:
//
// export async function beforeAll(ctx) {
//   try {
//     if (typeof ctx.getFormState !== 'function') return; // мультиконтекстный ctx — пропускаем
//     const s = await ctx.getFormState();
//     const moved = (s.buttons || []).some((b) => (b?.name || b) === 'Информационная база перемещена');
//     if (s.modal && moved) await ctx.clickElement('Информационная база перемещена');
//   } catch { /* диалога нет */ }
// }
