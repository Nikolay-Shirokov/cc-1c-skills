// web-test recording/slides/templates v1.3 — slide templates: spec → { html, css, steps, bg?, push?, maxZoom? }.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Every template is a generator for the step protocol (protocol.mjs): it builds a 1920×1080 page and
// turns its own short step form (`show: 2`, `region: [...]`, ...) into protocol steps. Names follow
// PowerPoint / Keynote / SmartArt. Specs are validated here: a wrong field or a count past the limit
// throws before anything is shown (prepareSlides calls this ahead of the recording).

import { existsSync, readFileSync } from 'fs';
import { extname } from 'path';
import { resolveProjectPath } from '../../core/state.mjs';
import { W, H, EASE } from './protocol.mjs';
import { rewriteAssets } from './assets.mjs';

export const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const r1 = (x) => Math.round(x * 10) / 10;
const list = (items) => (items?.length ? `<ul>${items.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>` : '');
const range = (n) => [...Array(n).keys()];

// ── validation ────────────────────────────────────────────────────────────
class SpecError extends Error {}
const fail = (layout, msg) => { throw new SpecError(`showSlide(${layout}): ${msg}`); };
function need(layout, ok, msg) { if (!ok) fail(layout, msg); }
const isStr = (x) => typeof x === 'string' && x.trim() !== '';
const isArr = (x) => Array.isArray(x);
function count(layout, field, arr, min, max, advice) {
  need(layout, isArr(arr), `"${field}" must be an array`);
  need(layout, arr.length >= min && arr.length <= max,
    `${min}–${max} ${field} supported, got ${arr.length}${advice ? ` — ${advice}` : ''}`);
}
function stepsOf(layout, spec, { required = true } = {}) {
  if (!required && (spec.steps === undefined || (isArr(spec.steps) && !spec.steps.length))) return [];
  need(layout, isArr(spec.steps) && spec.steps.length > 0, '"steps" must be a non-empty array');
  spec.steps.forEach((s, i) => need(layout, s && typeof s === 'object', `step ${i + 1} must be an object`));
  return spec.steps;
}
// index-like step.show values: a number in range, or one of the extra keys — inside an array only the
// keys the template expands there (arrayExtra); the rest are valid on their own only
function checkShow(layout, steps, n, extra = [], arrayExtra = []) {
  steps.forEach((s, i) => {
    if (s.show === undefined) return;
    const arr = Array.isArray(s.show);
    for (const v of [].concat(s.show)) {
      const ok = (Number.isInteger(v) && v >= 0 && v < n) || (arr ? arrayExtra.includes(v) : extra.includes(v));
      need(layout, ok, `step ${i + 1}: show ${JSON.stringify(v)} — expected 0..${n - 1}`
        + (extra.length ? ` or ${extra.map((x) => `'${x}'`).join(', ')}${arr && extra.some((x) => !arrayExtra.includes(x)) ? ' (on its own, not in an array)' : ''}` : ''));
    }
  });
}

// ── images ────────────────────────────────────────────────────────────────
/** Image file → { iw, ih, url } (PNG and JPEG sizes read from the header). */
export function imageInfo(src, layout = 'image') {
  need(layout, isStr(src), 'image path is required');
  const abs = resolveProjectPath(src);
  need(layout, existsSync(abs), `image not found: ${abs}`);
  const buf = readFileSync(abs), ext = extname(abs).toLowerCase();
  let iw, ih;
  if (ext === '.png') { iw = buf.readUInt32BE(16); ih = buf.readUInt32BE(20); }
  else if (ext === '.jpg' || ext === '.jpeg') {
    for (let i = 2; i + 9 < buf.length;) {
      const m = buf[i + 1], len = buf.readUInt16BE(i + 2);
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) { ih = buf.readUInt16BE(i + 5); iw = buf.readUInt16BE(i + 7); break; }
      i += 2 + len;
    }
  } else if (ext === '.webp' || ext === '.gif' || ext === '.svg') {
    iw = 1920; ih = 1080;   // size unknown: fitted by CSS; regions/callouts then assume 1920×1080
  }
  need(layout, iw && ih, `unsupported image (PNG/JPEG): ${abs}`);
  const mime = ext === '.png' ? 'png' : ext === '.svg' ? 'svg+xml' : ext === '.jpg' ? 'jpeg' : ext.slice(1);
  return { iw, ih, url: `data:image/${mime};base64,${buf.toString('base64')}` };
}

// ── shared pieces ─────────────────────────────────────────────────────────
const TITLE_CSS = `
.ws-title{position:absolute;left:96px;right:96px;top:52px;font-weight:800;font-size:48px;line-height:1.1;letter-spacing:-.01em;
  color:var(--ink);animation:tplIn .8s ${EASE} both}
.ws-title::after{content:'';display:block;width:120px;height:6px;margin-top:16px;border-radius:3px;background:var(--accent)}
@keyframes tplIn{from{opacity:0;transform:translateY(26px)}to{opacity:1;transform:none}}
`;
const titleHtml = (t) => (t ? `<div class="ws-title">${esc(t)}</div>` : '');
const CARD_SHADOW = '0 6px 24px color-mix(in srgb, var(--ink) 8%, transparent)';
const LIFT_SHADOW = '0 22px 60px color-mix(in srgb, var(--primary) 26%, transparent)';
const DARK_TEXT = `.ws-slide{color:var(--on-dark)}`;

// ── templates ─────────────────────────────────────────────────────────────
export const templates = {
  // Title card: kicker, multi-line title (\n), subtitle, a rule that draws, optional picture on the right.
  title(spec) {
    const L = 'title';
    need(L, isStr(spec.title), '"title" is required');
    const img = spec.image ? `<div class="tt-img"><img src="${imageInfo(spec.image, L).url}"/></div>` : '';
    const lines = String(spec.title).split('\n').map((l) => `<span>${esc(l)}</span>`).join('');
    return {
      bg: spec.background || 'var(--dark-bg)',
      push: true,
      html: img + '<div class="tt-box">'
        + (spec.kicker ? `<div class="tt-kicker">${esc(spec.kicker)}</div>` : '')
        + `<h1 class="tt-title">${lines}</h1><div class="tt-rule"></div>`
        + (spec.subtitle ? `<div class="tt-sub">${esc(spec.subtitle)}</div>` : '') + '</div>',
      css: DARK_TEXT + `
.tt-box{position:absolute;left:140px;top:0;bottom:0;width:${spec.image ? 1000 : 1640}px;display:flex;flex-direction:column;justify-content:center}
.tt-kicker{font-size:28px;font-weight:700;letter-spacing:.18em;text-transform:uppercase;color:var(--accent-hi);margin-bottom:28px;--dy:12px}
.tt-title{margin:0;font-size:${spec.image ? 80 : 96}px;line-height:1.08;font-weight:800;letter-spacing:-.02em}
.tt-title span{display:block;--dy:36px;--stagger:.18s}
.tt-rule{width:220px;height:8px;margin:40px 0 0;border-radius:4px;background:var(--accent);transform-origin:left center}
.tt-rule.ws-pending:not(.on){transform:scaleX(0)}
.tt-rule.ws-t{transition:opacity .4s ease,transform 1s cubic-bezier(.65,0,.35,1) .5s}
.tt-sub{margin-top:34px;font-size:38px;line-height:1.3;color:var(--on-dark-muted);max-width:1000px;--dy:16px}
.tt-sub.ws-t{transition-delay:.8s,.8s,0s}
.tt-img{position:absolute;right:110px;top:50%;width:640px;height:640px;margin-top:-320px;border-radius:50%;overflow:hidden;
  box-shadow:0 30px 90px rgba(0,0,0,.45);--dy:0px;--from-scale:.9}
.tt-img img{width:100%;height:100%;object-fit:cover;animation:ttDrift 14s linear both}
@keyframes ttDrift{from{transform:scale(1.12) rotate(-3deg)}to{transform:scale(1) rotate(0)}}`,
      steps: [
        { show: '.tt-img, .tt-kicker, .tt-title span, .tt-rule, .tt-sub', speech: spec.speech, text: spec.text, voice: spec.voice },
        { hold: spec.outro ?? 1 },
      ],
    };
  },

  // Table of contents. Opening: sections cascade in. Section break: `current` lit, the rest dimmed.
  agenda(spec) {
    const L = 'agenda';
    count(L, 'items', spec.items, 2, 12, 'split the video into parts');
    const n = spec.items.length, cur = spec.current;
    need(L, cur === undefined || (Number.isInteger(cur) && cur >= 0 && cur < n), `"current" must be 0..${n - 1}`);
    const items = spec.items.map((x, i) => `<li class="ag-${i}"><b>${i + 1}</b><span>${esc(x)}</span></li>`).join('');
    const step = { show: '.ag-head, ' + range(n).map((i) => `.ag-${i}`).join(', '), speech: spec.speech, text: spec.text, voice: spec.voice };
    if (cur !== undefined) {
      step.focus = `.ag-${cur}`;
      step.dim = range(n).filter((i) => i !== cur).map((i) => `.ag-${i}`).join(', ');
    }
    const two = n > 6, rows = two ? Math.ceil(n / 2) : n;
    return {
      push: true,
      html: `<div class="ag-head">${esc(spec.title || 'Содержание')}</div><div class="ag-box ws-fit"><ol class="ag-list">${items}</ol></div>`,
      css: `
.ag-head{position:absolute;left:120px;top:0;bottom:0;width:${two ? 420 : 520}px;display:flex;align-items:center;font-size:${two ? 64 : 76}px;
  font-weight:800;line-height:1.05;letter-spacing:-.02em;color:var(--primary);--dx:-30px;--dy:0px}
.ag-box{position:absolute;left:${two ? 600 : 720}px;right:100px;top:60px;bottom:60px;display:flex;align-items:center}
.ag-list{width:100%;margin:0;padding:0;list-style:none;display:grid;grid-template-rows:repeat(${rows},auto);grid-auto-flow:column;
  grid-auto-columns:1fr;gap:${two ? 18 : 22}px ${two ? 28 : 0}px}
.ag-list li{display:flex;align-items:center;gap:26px;padding:${two ? 16 : 20}px 28px;border-radius:16px;background:#fff;
  box-shadow:${CARD_SHADOW};font-size:${two ? 32 : 38}px;font-weight:600;color:var(--ink);--stagger:.1s;--dx:30px;--dy:0px}
.ag-list b{flex:none;width:60px;height:60px;border-radius:50%;display:flex;align-items:center;justify-content:center;
  background:var(--soft);color:var(--accent-text);font-size:30px;font-weight:800}
.ag-list li.ws-focus{animation:none;transform:scale(1.04);background:var(--accent);color:var(--on-accent);
  box-shadow:0 20px 50px color-mix(in srgb, var(--accent) 35%, transparent)}
.ag-list li.ws-focus b{background:#fff;color:var(--primary)}`,
      steps: [step, { hold: spec.outro ?? 1 }],
    };
  },

  // One idea, big. Optional `value` (a number or short fact) above the text.
  statement(spec) {
    const L = 'statement';
    need(L, isStr(spec.text), '"text" is required');
    const show = [spec.kicker && '.st-kick', spec.value && '.st-val', '.st-text', spec.caption && '.st-cap'].filter(Boolean).join(', ');
    return {
      push: true,
      bg: spec.background,
      html: '<div class="st-box">' + (spec.kicker ? `<div class="st-kick">${esc(spec.kicker)}</div>` : '')
        + (spec.value ? `<div class="st-val">${esc(spec.value)}</div>` : '')
        + `<div class="st-text">${esc(spec.text)}</div>` + (spec.caption ? `<div class="st-cap">${esc(spec.caption)}</div>` : '') + '</div>',
      css: `
.st-box{position:absolute;inset:0 160px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}
.st-box>*{--stagger:.35s}
.st-kick{font-size:28px;font-weight:700;letter-spacing:.18em;text-transform:uppercase;color:var(--accent-text);margin-bottom:24px}
.st-val{font-size:240px;font-weight:800;line-height:1;letter-spacing:-.04em;color:var(--accent);--from-scale:.85;--dy:0px;
  -webkit-text-stroke:2px color-mix(in srgb, var(--accent-text) 40%, transparent)}
.st-text{font-size:${spec.value ? 56 : 76}px;font-weight:700;line-height:1.2;letter-spacing:-.01em;color:var(--ink);max-width:1400px;
  margin-top:${spec.value ? 30 : 0}px}
.st-cap{margin-top:32px;font-size:32px;color:var(--muted);max-width:1300px}`,
      steps: [{ show, speech: spec.speech, text: spec.text, voice: spec.voice }, { hold: spec.outro ?? 1 }],
    };
  },

  // Optional lead block on the left + a grid of cards. step.show: index | [indices] | 'all' | 'lead'.
  cards(spec) {
    const L = 'cards';
    count(L, 'cards', spec.cards, 1, 12, 'split the slide');
    const n = spec.cards.length;
    spec.cards.forEach((c, i) => need(L, c && (isStr(c.title) || isStr(c.text) || isArr(c.items)), `card ${i + 1} needs title, text or items`));
    const steps0 = stepsOf(L, spec);
    checkShow(L, steps0, n, ['all', 'lead'], ['all', 'lead']);
    if (steps0.some((s) => [].concat(s.show).includes('lead'))) need(L, spec.lead, 'show "lead" without a "lead" block');
    const cols = spec.columns || (spec.lead ? (n <= 4 ? 2 : 3) : n <= 3 ? n : n <= 4 ? 2 : n <= 6 ? 3 : 4);
    const lead = spec.lead ? `<div class="cd-lead"><b>${esc(spec.lead.title)}</b><p>${esc(spec.lead.text)}</p></div>` : '';
    const cards = spec.cards.map((c, i) => `<div class="cd-card cd-${i}">`
      + (c.title ? `<h3>${esc(c.title)}</h3>` : '') + (c.text ? `<p>${esc(c.text)}</p>` : '') + list(c.items) + '</div>');
    const sel = (i) => (i === 'lead' ? '.cd-lead' : `.cd-${i}`);
    const steps = steps0.map(({ show, ...s }) => {
      if (show === undefined) return s;
      const keys = [].concat(show).flatMap((x) => (x === 'all' ? range(n) : [x]));
      const st = { ...s, show: keys.map(sel).join(', ') };
      const focus = keys.filter((x) => x !== 'lead');
      if (spec.focus !== false && show !== 'all' && focus.length) st.focus = focus.map(sel).join(', ');
      return st;
    });
    steps.push({ clear: true, focus: null, hold: spec.outro ?? 1.2 });
    return {
      push: true,
      html: titleHtml(spec.title) + `<div class="cd-wrap">${lead}<div class="cd-box ws-fit"><div class="cd-grid">${cards.join('')}</div></div></div>`,
      css: TITLE_CSS + `
.cd-wrap{position:absolute;left:96px;right:80px;top:${spec.title ? 180 : 60}px;bottom:40px;display:flex;align-items:center;gap:56px}
.cd-lead{flex:0 0 460px;--dx:-28px;--dy:0px}
.cd-lead b{display:block;font-size:72px;font-weight:800;color:var(--primary);letter-spacing:.02em}
.cd-lead b::after{content:'';display:block;width:90px;height:6px;margin-top:14px;border-radius:3px;background:var(--accent)}
.cd-lead p{margin:18px 0 0;font-size:30px;line-height:1.4;color:var(--ink2)}
.cd-box{flex:1;align-self:stretch;display:flex;flex-direction:column;min-width:0}
.cd-box::before{content:'';flex:1}.cd-box::after{content:'';flex:2}
.cd-grid{width:100%;display:grid;grid-template-columns:repeat(${cols},1fr);gap:28px}
.cd-card{background:#fff;border-radius:16px;border-left:8px solid var(--line);padding:26px 30px;box-shadow:${CARD_SHADOW};--stagger:.12s}
.cd-card.ws-focus{animation:none;transform:scale(1.03);box-shadow:${LIFT_SHADOW};border-left-color:var(--accent)}
.cd-card h3{margin:0 0 10px;font-size:34px;font-weight:700;color:var(--primary);line-height:1.15}
.cd-card p{margin:0;font-size:${spec.textSize || 29}px;line-height:1.35;color:var(--ink2)}
.cd-card ul{margin:0;padding-left:28px;font-size:27px;line-height:1.35;color:var(--ink2)}
.cd-card li::marker{color:var(--line)}`,
      steps,
    };
  },

  // Columns with a header band each. step.show: column index | 'all'.
  columns(spec) {
    const L = 'columns';
    count(L, 'columns', spec.columns, 2, 5, 'use cards for more');
    const n = spec.columns.length;
    spec.columns.forEach((c, i) => need(L, c && isStr(c.title), `column ${i + 1} needs a title`));
    const steps0 = stepsOf(L, spec);
    checkShow(L, steps0, n, ['all']);
    const colors = ['var(--c1)', 'var(--c2)', 'var(--c4)', 'var(--c5)', 'var(--c3)'];
    const cols = spec.columns.map((c, i) => `<div class="co-col co-${i}" style="--c:${c.color || colors[i % colors.length]}">`
      + `<h3>${esc(c.title)}</h3>${(c.items || []).map((x) => `<div class="co-it">${esc(x)}</div>`).join('')}</div>`).join('');
    const sel = (i) => `.co-${i}`;
    const steps = steps0.map(({ show, ...s }) => (show === undefined ? s
      : show === 'all' ? { ...s, show: range(n).map(sel).join(', ') } : { ...s, show: [].concat(show).map(sel).join(', '), focus: [].concat(show).map(sel).join(', ') }));
    steps.push({ clear: true, focus: null, hold: spec.outro ?? 1.2 });
    return {
      push: true,
      html: titleHtml(spec.title) + `<div class="co-box ws-fit"><div class="co-row">${cols}</div></div>`,
      css: TITLE_CSS + `
.co-box{position:absolute;left:96px;right:96px;top:${spec.title ? 180 : 60}px;bottom:44px;display:flex;flex-direction:column}
.co-box::before{content:'';flex:1}.co-box::after{content:'';flex:2}
.co-row{width:100%;display:grid;grid-template-columns:repeat(${n},1fr);gap:32px;align-items:center}
.co-col{background:#fff;border-radius:18px;overflow:hidden;box-shadow:${CARD_SHADOW};--stagger:.15s}
.co-col.ws-focus{animation:none;transform:scale(1.025);box-shadow:${LIFT_SHADOW}}
.co-col h3{margin:0;padding:20px 26px;background:var(--c);color:#fff;font-size:34px;font-weight:700;line-height:1.15}
.co-it{margin:14px 18px;padding:14px 20px;border-radius:10px;background:var(--soft);font-size:27px;line-height:1.3;color:var(--ink2)}`,
      steps,
    };
  },

  // Two sides, rows aligned. step.show: 'left' | 'right' | 'all'; step.row: i lights row i on both sides.
  comparison(spec) {
    const L = 'comparison';
    for (const side of ['left', 'right']) {
      need(L, spec[side] && isStr(spec[side].title) && isArr(spec[side].items), `"${side}" needs { title, items }`);
    }
    const n = Math.max(spec.left.items.length, spec.right.items.length);
    need(L, n >= 1 && n <= 8, `1–8 rows supported, got ${n} — split the slide`);
    const steps0 = stepsOf(L, spec);
    steps0.forEach((s, i) => {
      need(L, s.show === undefined || ['left', 'right', 'all'].includes(s.show), `step ${i + 1}: show must be 'left', 'right' or 'all'`);
      need(L, s.row === undefined || (Number.isInteger(s.row) && s.row >= 0 && s.row < n), `step ${i + 1}: row must be 0..${n - 1}`);
    });
    const { left: Lf, right: R } = spec;
    const cell = (side, i, x) => `<div class="cp-cell cp-${side} cp-${side}${i}" style="grid-row:${i + 2}">${x === undefined ? '' : esc(x)}</div>`;
    // an arrow only between two filled cells (a row with one side empty has none)
    const arrow = (i) => (Lf.items[i] !== undefined && R.items[i] !== undefined
      ? `<div class="cp-vs cp-a${i}" style="grid-row:${i + 2}">→</div>` : '');
    const cells = range(n).map((i) => cell('l', i, Lf.items[i]) + arrow(i) + cell('r', i, R.items[i])).join('');
    const sideSel = (side) => [`.cp-h${side}`, ...range(n).map((i) => `.cp-${side}${i}`)].join(', ');
    const arrows = range(n).filter((i) => Lf.items[i] !== undefined && R.items[i] !== undefined).map((i) => `.cp-a${i}`).join(', ') || '.cp-none';
    // arrows come with the right side ("became"); a lit row lights its arrow too
    const steps = steps0.map(({ show, row, ...s }) => {
      const st = { ...s };
      if (show) st.show = show === 'all' ? `${sideSel('l')}, ${sideSel('r')}, ${arrows}` : show === 'right' ? `${sideSel('r')}, ${arrows}` : sideSel('l');
      if (row !== undefined) {
        st.show = [st.show, `.cp-l${row}, .cp-a${row}, .cp-r${row}`].filter(Boolean).join(', ');
        st.focus = `.cp-l${row}, .cp-a${row}, .cp-r${row}`;
      }
      return st;
    });
    steps.push({ clear: true, focus: null, hold: spec.outro ?? 1.2 });
    return {
      push: true,
      html: titleHtml(spec.title) + `<div class="cp-box ws-fit"><div class="cp-grid"><div class="cp-head cp-hl">${esc(Lf.title)}</div>`
        + `<div class="cp-head cp-hr">${esc(R.title)}</div>${cells}</div></div>`,
      css: TITLE_CSS + `
.cp-box{position:absolute;left:96px;right:96px;top:${spec.title ? 180 : 60}px;bottom:44px;display:flex;flex-direction:column}
.cp-box::before{content:'';flex:1}.cp-box::after{content:'';flex:2}
.cp-grid{width:100%;display:grid;grid-template-columns:1fr 90px 1fr;grid-auto-rows:auto;row-gap:18px}
.cp-head{grid-row:1;padding:18px 30px;border-radius:14px;font-size:38px;font-weight:800;margin-bottom:8px}
.cp-hl{grid-column:1;background:var(--c3);color:#fff}
.cp-hr{grid-column:3;background:var(--primary);color:#fff;box-shadow:inset 0 -6px 0 var(--accent)}
.cp-vs{grid-column:2;align-self:center;justify-self:center;font-size:44px;font-weight:800;color:var(--line);--dx:-14px;--dy:0px}
.cp-vs.ws-focus{animation:none;color:var(--accent)}
.cp-cell{padding:18px 26px;border-radius:12px;background:#fff;font-size:30px;line-height:1.3;color:var(--ink2);box-shadow:${CARD_SHADOW};--stagger:.1s}
.cp-cell:empty{visibility:hidden}
.cp-l{grid-column:1;color:var(--muted)}
.cp-r{grid-column:3;border-left:6px solid var(--line)}
.cp-cell.ws-focus{animation:none;transform:scale(1.03);box-shadow:${LIFT_SHADOW}}
.cp-r.ws-focus{border-left-color:var(--accent)}`,
      steps,
    };
  },

  // Stages in order, each a card with an optional role below. More than 5 stages wrap into two rows:
  // wrap 'snake' (default: second row right-to-left, arrow down) | 'bend' (both rows left-to-right,
  // the arrow bends back) | 'none' (one row). step.show: stage index | 'all'.
  process(spec) {
    const L = 'process';
    count(L, 'stages', spec.stages, 2, 10, 'split the process');
    const n = spec.stages.length;
    spec.stages.forEach((s, i) => need(L, s && isStr(s.title), `stage ${i + 1} needs a title`));
    const wrap = spec.wrap ?? 'snake';
    need(L, ['snake', 'bend', 'none'].includes(wrap), `wrap must be 'snake', 'bend' or 'none'`);
    const steps0 = stepsOf(L, spec);
    checkShow(L, steps0, n, ['all']);
    const twoRows = n > 5 && wrap !== 'none';
    const k = twoRows ? Math.ceil(n / 2) : n;                 // stages in the first (widest) row
    const ARW = 64, GAPX = 14;
    const w = Math.floor((1800 - (k - 1) * (ARW + 2 * GAPX)) / k);
    const hasRole = spec.stages.some((s) => s.role), hasItems = spec.stages.some((s) => s.items?.length);
    const person = '<svg viewBox="0 0 64 64" class="pr-ico"><circle cx="32" cy="20" r="12"/><path d="M8 60c0-14 11-22 24-22s24 8 24 22"/></svg>';
    const arrow = (i, rev) => `<svg class="pr-arr pr-${i}a${rev ? ' rev' : ''}" viewBox="0 0 64 40"><path d="M4 20H54M42 8l14 12-14 12"/></svg>`;
    const colors = ['var(--c1)', 'var(--c2)', 'var(--c4)', 'var(--c5)'];
    const stage = (st, i) => `<div class="pr-st pr-${i}" style="--c:${st.color || colors[i % colors.length]}">`
      + `<div class="pr-card pr-c${i}"><h3>${esc(st.title)}</h3>${list(st.items)}</div>`
      + (st.role ? `<div class="pr-role">${person}<b>${esc(st.role)}</b>${st.caption ? `<span>${esc(st.caption)}</span>` : ''}</div>`
        : hasRole ? '<div class="pr-role"></div>' : '') + '</div>';
    const row = (from, to, rev) => `<div class="pr-row${rev ? ' rev' : ''}">`
      + range(to - from).map((j) => { const i = from + j; return (j ? arrow(i, rev) : '') + stage(spec.stages[i], i); }).join('') + '</div>';
    let body;
    if (!twoRows) body = row(0, n, false);
    else {
      const rev = wrap === 'snake';
      // the turn between rows belongs to stage k (revealed with it)
      const xEnd = (k - 1) * (w + ARW + 2 * GAPX) + w / 2;
      const turn = rev
        ? `<div class="pr-turn pr-${k}a" style="padding-right:${r1(w / 2 - 20)}px"><svg viewBox="0 0 40 64"><path d="M20 4V54M8 42l12 14 12-14"/></svg></div>`
        : `<svg class="pr-turn pr-bend pr-${k}a" viewBox="0 0 1800 70"><path d="M${r1(xEnd)} 4 V35 H${r1(w / 2)} V62 M${r1(w / 2 - 12)} 50 L${r1(w / 2)} 64 L${r1(w / 2 + 12)} 50"/></svg>`;
      body = row(0, k, false) + turn + row(k, n, rev);
    }
    const sel = (i) => `.pr-${i}` + (i ? `, .pr-${i}a` : '');
    const steps = steps0.map(({ show, ...s }) => (show === undefined ? s
      : show === 'all' ? { ...s, show: range(n).map(sel).join(', ') }
        : { ...s, show: [].concat(show).map(sel).join(', '), focus: [].concat(show).map((i) => `.pr-c${i}` + (i ? `, .pr-${i}a` : '')).join(', ') }));
    steps.push({ clear: true, focus: null, hold: spec.outro ?? 1.2 });
    return {
      push: true,
      html: titleHtml(spec.title) + `<div class="pr-box ws-fit"><div class="pr-flow">${body}</div></div>`,
      css: TITLE_CSS + `
.pr-box{position:absolute;left:60px;right:60px;top:${spec.title ? 170 : 50}px;bottom:36px;display:flex;flex-direction:column}
.pr-box::before{content:'';flex:1}.pr-box::after{content:'';flex:2}
.pr-flow{width:100%;display:flex;flex-direction:column;gap:${twoRows ? 10 : 0}px}
.pr-row{display:flex;align-items:${hasItems ? 'stretch' : 'center'};gap:${GAPX}px}
.pr-row.rev{flex-direction:row-reverse}
.pr-st{flex:0 0 ${w}px;display:flex;flex-direction:column;gap:${twoRows ? 16 : 30}px;--dy:30px}
.pr-card{flex:${hasItems ? 1 : 'none'};background:#fff;border-radius:16px;overflow:hidden;box-shadow:${CARD_SHADOW};
  min-height:${hasItems ? (twoRows ? 0 : 300) : 0}px}
.pr-card.ws-focus{animation:none;transform:translateY(-8px);box-shadow:${LIFT_SHADOW}}
.pr-card h3{margin:0;padding:20px 24px;background:var(--c);color:#fff;font-size:${w < 300 ? 28 : 32}px;font-weight:700;line-height:1.15
  ${hasItems ? '' : ';min-height:130px;display:flex;align-items:center;justify-content:center;text-align:center'}}
.pr-card ul{margin:0;padding:16px 22px 20px 44px;font-size:${w < 300 ? 24 : 27}px;line-height:1.35;color:var(--ink2)}
.pr-card li{margin:4px 0}
.pr-card li::marker{color:var(--line)}
.pr-role{display:flex;flex-direction:column;align-items:center;text-align:center;min-height:${twoRows ? 0 : 150}px}
.pr-ico{width:${twoRows ? 56 : 84}px;height:${twoRows ? 56 : 84}px;fill:none;stroke:var(--primary);stroke-width:3.5}
.pr-role b{margin-top:10px;font-size:${twoRows ? 26 : 32}px;font-weight:700;color:var(--ink)}
.pr-role span{margin-top:6px;font-size:22px;font-weight:600;color:var(--accent-text);text-transform:uppercase;letter-spacing:.06em}
.pr-arr{flex:0 0 ${ARW}px;width:${ARW}px;height:40px;align-self:${hasItems || hasRole ? 'flex-start' : 'center'};margin-top:${hasItems || hasRole ? 34 : 0}px;
  fill:none;stroke:var(--line);stroke-width:4;stroke-linecap:round;stroke-linejoin:round;--dx:-14px;--dy:0px}
.pr-arr.rev{transform:scaleX(-1)}
.pr-arr.rev.ws-pending:not(.on){transform:translateX(14px) scaleX(-1)}
.pr-arr.rev.on{transform:scaleX(-1)}
.pr-turn{display:flex;justify-content:flex-end;--dy:-10px}
.pr-turn svg{width:40px;height:64px}
.pr-turn path, .pr-bend path{fill:none;stroke:var(--line);stroke-width:4;stroke-linecap:round;stroke-linejoin:round}
.pr-bend{width:100%;height:70px}
.pr-arr.ws-focus, .pr-turn.ws-focus{animation:none}
.pr-arr.ws-focus, .pr-turn.ws-focus path, .pr-bend.ws-focus path{stroke:var(--accent)}`,
      steps,
    };
  },

  // Centre and 3–6 cards around it (SmartArt "Radial"), linked by lines. step.show: 'center' | card index.
  // Cards go left, right, left, right... in reading order.
  radial(spec) {
    const L = 'radial';
    need(L, spec.center && isStr(spec.center.title), '"center" needs a title');
    count(L, 'cards', spec.cards, 3, 6, 'split the slide or use cards');
    const n = spec.cards.length;
    spec.cards.forEach((c, i) => need(L, c && isStr(c.title), `card ${i + 1} needs a title`));
    const steps0 = stepsOf(L, spec);
    checkShow(L, steps0, n, ['center', 'all']);
    const colors = ['var(--c1)', 'var(--c2)', 'var(--c4)', 'var(--c3)', 'var(--c5)', 'var(--c2)'];
    const card = (c, i) => `<div class="hb-card hb-c${i} ${i % 2 ? 'right' : 'left'}" style="--c:${c.color || colors[i]}">`
      + `<h3>${esc(c.title)}</h3>${list(c.items)}</div>`;
    const leftCol = range(n).filter((i) => i % 2 === 0).map((i) => card(spec.cards[i], i)).join('');
    const rightCol = range(n).filter((i) => i % 2 === 1).map((i) => card(spec.cards[i], i)).join('');
    const links = range(n).map((i) => `<path class="hb-l${i}" data-to=".hb-c${i}"/>`).join('');
    const hub = `<div class="hb-hub"><b>${esc(spec.center.title)}</b>${list(spec.center.items)}</div>`;
    // step { show: 'center' | i } → show the card and its line, focus it, dim the ones before
    const shown = [];
    const steps = steps0.map(({ show, ...rest }) => {
      if (show === undefined) return rest;
      if (show === 'center') return { ...rest, show: '.hb-hub' };
      if (show === 'all') return { ...rest, show: '.hb-hub, ' + range(n).map((i) => `.hb-c${i}, .hb-l${i}`).join(', ') };
      const idx = [].concat(show);
      const st = { ...rest, show: idx.map((i) => `.hb-c${i}, .hb-l${i}`).join(', '), focus: idx.map((i) => `.hb-c${i}, .hb-l${i}`).join(', ') };
      if (shown.length) st.dim = shown.map((j) => `.hb-c${j}, .hb-l${j}`).join(', ');
      shown.push(...idx);
      return st;
    });
    steps.push({ clear: true, focus: null, hold: spec.outro ?? 1.2 });
    const top = spec.title ? 170 : 50, cy = (top + H - 36) / 2;
    return {
      push: true,
      html: titleHtml(spec.title)
        + `<svg class="ws-links" data-from=".hb-hub" data-round viewBox="0 0 ${W} ${H}">${links}</svg>${hub}`
        + `<div class="hb-col hb-left ws-fit">${leftCol}</div><div class="hb-col hb-right ws-fit">${rightCol}</div>`,
      css: TITLE_CSS + `
.hb-col{position:absolute;top:${top}px;bottom:36px;width:640px;display:flex;flex-direction:column;justify-content:space-around;gap:18px}
.hb-left{left:80px}
.hb-right{right:80px}
.hb-card{background:#fff;border-radius:18px;overflow:hidden;box-shadow:${CARD_SHADOW};--stagger:.4s}
.hb-card.left{--dx:-32px;--dy:0px}
.hb-card.right{--dx:32px;--dy:0px}
.hb-card.ws-focus{animation:none;transform:scale(1.025);box-shadow:${LIFT_SHADOW}}
.hb-card h3{margin:0;padding:18px 28px;color:#fff;background:var(--c);font-weight:700;font-size:32px;line-height:1.15}
.hb-card ul{margin:0;padding:14px 28px 18px 50px;color:var(--ink2);font-size:23px;line-height:1.32}
.hb-card li{margin:3px 0}
.hb-card li::marker{color:var(--line)}
.hb-hub{position:absolute;left:770px;top:${r1(cy - 190)}px;width:380px;height:380px;border-radius:50%;color:#fff;--dy:0px;--from-scale:.8;
  background:radial-gradient(circle at 35% 30%,var(--primary-hi),var(--primary));box-shadow:0 20px 60px color-mix(in srgb, var(--primary) 35%, transparent);
  display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:30px}
.hb-hub b{font-size:62px;font-weight:800;letter-spacing:.02em}
.hb-hub b::after{content:'';display:block;width:60px;height:5px;margin:10px auto 0;border-radius:3px;background:var(--accent)}
.hb-hub ul{list-style:none;margin:10px 0 0;padding:0;font-size:22px;font-weight:600;line-height:1.45;opacity:.92}`,
      steps,
    };
  },

  // A picture with camera focus (`region`) and numbered callouts (`callout: { at: [x, y], label }`), both in
  // image pixels; a step with neither returns to the whole picture. `style` keeps the old showImage
  // presets: full (default) | blur | dark | light.
  image(spec) {
    const L = 'image';
    const { iw, ih, url } = imageInfo(spec.src, L);
    const style = spec.style || 'full';
    need(L, ['full', 'blur', 'dark', 'light'].includes(style), `style must be full, blur, dark or light`);
    const steps0 = stepsOf(L, spec, { required: false });
    steps0.forEach((s, i) => {
      need(L, s.region === undefined || (isArr(s.region) && s.region.length === 4 && s.region.every(Number.isFinite)),
        `step ${i + 1}: region must be [x, y, width, height] in image pixels`);
      need(L, s.callout === undefined || (s.callout && isArr(s.callout.at) && s.callout.at.length === 2 && s.callout.at.every(Number.isFinite)),
        `step ${i + 1}: callout must be { at: [x, y], label? } in image pixels`);
    });
    const framed = style !== 'full', f = framed ? 0.92 : 1;
    const k = Math.min((W * f) / iw, (H * f) / ih), dw = iw * k, dh = ih * k, ox = (W - dw) / 2, oy = (H - dh) / 2;
    const P = (x, y) => [ox + x * k, oy + y * k];
    let c = 0;
    const marks = [];
    const steps = steps0.map(({ region, callout, ...s }) => {
      const st = { ...s };
      if (region) { st.camera = [...P(region[0], region[1]), region[2] * k, region[3] * k]; st.spot = true; }
      else if (!callout) st.camera = null;
      if (callout) {
        const i = c++, [x, y] = P(...callout.at), left = callout.at[0] > iw * 0.6;
        marks.push(`<div class="im-co im-co${i}${left ? ' im-left' : ''}" style="left:${r1(x)}px;top:${r1(y)}px">`
          + `<b>${i + 1}</b>${callout.label ? `<span>${esc(callout.label)}</span>` : ''}</div>`);
        st.show = [st.show, `.im-co${i}`].filter(Boolean).join(', ');
        st.focus = `.im-co${i}`;
      }
      return st;
    });
    if (steps.some((s) => s.camera || s.focus)) steps.push({ camera: null, focus: null, hold: spec.outro ?? 1.2 });
    const bg = spec.background || { full: '#ffffff', blur: '#222', dark: '#2a2a2a', light: '#ffffff' }[style];
    const blurLayer = style === 'blur' && !spec.background
      ? `<img src="${url}" style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;filter:blur(30px) brightness(.5);transform:scale(1.1)"/>` : '';
    // fit 'natural' (legacy showImage): natural size in page pixels, kept within 50–92% of the frame
    const main = spec.fit === 'natural' && style !== 'full'
      ? `<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center">`
        + `<img class="im-main" src="${url}" style="position:relative;width:calc(${iw}px / var(--k, 1));height:auto;`
        + `max-width:92%;max-height:92%;min-width:50%;min-height:50%;object-fit:contain"/></div>`
      : `<img class="im-main" src="${url}" style="position:absolute;left:${r1(ox)}px;top:${r1(oy)}px;width:${r1(dw)}px;height:${r1(dh)}px"/>`;
    return {
      bg,
      maxZoom: spec.maxZoom ?? 1.8,
      html: blurLayer + main + marks.join(''),
      css: `
${(spec.shadow ?? framed) ? '.im-main{box-shadow:0 4px 40px rgba(0,0,0,.5)}' : ''}
.im-co{position:absolute;width:0;height:0;--dy:0px;--from-scale:.5}
.im-co b{position:absolute;left:-26px;top:-26px;width:52px;height:52px;border-radius:50%;background:var(--mark);color:var(--ink);
  font-size:28px;font-weight:800;display:flex;align-items:center;justify-content:center;
  box-shadow:0 0 0 5px color-mix(in srgb, var(--mark) 35%, transparent),0 8px 20px rgba(0,0,0,.3)}
.im-co span{position:absolute;left:40px;top:-26px;white-space:nowrap;padding:8px 18px;border-radius:10px;background:var(--primary);color:#fff;
  font-size:28px;font-weight:600;box-shadow:0 8px 24px rgba(0,0,0,.3)}
.im-co.im-left span{left:auto;right:40px}
.im-co.ws-focus{--pulse:1.15}`,
      steps,
    };
  },

  // Takeaways one by one, then an optional "next" card. step.show: item index | 'next' | 'all'.
  summary(spec) {
    const L = 'summary';
    count(L, 'items', spec.items, 1, 8, 'keep 3–5 takeaways');
    const n = spec.items.length;
    const steps0 = stepsOf(L, spec);
    checkShow(L, steps0, n, ['all', 'next'], ['all', 'next']);
    if (steps0.some((s) => [].concat(s.show).includes('next'))) need(L, isStr(spec.next), 'show "next" without a "next" text');
    const items = spec.items.map((x, i) => `<li class="sm-${i}"><i>✓</i><span>${esc(x)}</span></li>`).join('');
    const sel = (i) => (i === 'next' ? '.sm-next' : `.sm-${i}`);
    // the takeaway being spoken gets the accent tick; the rest stay in the structure colour
    const steps = steps0.map(({ show, ...s }) => {
      if (show === undefined) return s;
      const keys = [].concat(show).flatMap((x) => (x === 'all' ? range(n) : [x]));
      const items = keys.filter((x) => x !== 'next');
      return { ...s, show: keys.map(sel).join(', '), focus: show === 'all' || !items.length ? null : items.map(sel).join(', ') };
    });
    steps.push({ clear: true, focus: null, hold: spec.outro ?? 1.2 });
    return {
      push: true,
      html: titleHtml(spec.title || 'Итоги') + `<div class="sm-box ws-fit"><ul class="sm-list">${items}</ul></div>`
        + (spec.next ? `<div class="sm-next"><small>${esc(spec.nextLabel || 'Дальше')}</small>${esc(spec.next)}</div>` : ''),
      css: TITLE_CSS + `
.sm-box{position:absolute;left:96px;right:96px;top:180px;bottom:${spec.next ? 230 : 50}px;display:flex;flex-direction:column}
.sm-box::before{content:'';flex:1}.sm-box::after{content:'';flex:2}
.sm-list{width:100%;margin:0;padding:0;list-style:none;display:flex;flex-direction:column;gap:24px}
.sm-list li{display:flex;align-items:center;gap:28px;font-size:40px;font-weight:600;color:var(--ink);--stagger:.15s}
.sm-list i{flex:none;width:60px;height:60px;border-radius:50%;background:var(--line);color:#fff;font-style:normal;font-size:34px;
  display:flex;align-items:center;justify-content:center;transition:background .5s ease,color .5s ease}
.sm-list li.ws-focus{animation:none}
.sm-list li.ws-focus i{background:var(--accent);color:var(--on-accent)}
.sm-next{position:absolute;left:96px;right:96px;bottom:60px;padding:28px 36px;border-radius:18px;background:var(--primary);color:#fff;
  font-size:36px;font-weight:600;line-height:1.3}
.sm-next small{display:block;font-size:22px;font-weight:700;letter-spacing:.18em;text-transform:uppercase;color:var(--accent-hi);margin-bottom:8px}`,
      steps,
    };
  },

  // End card: optional picture, a line, contacts, optional QR.
  closing(spec) {
    const L = 'closing';
    need(L, isStr(spec.title), '"title" is required');
    const img = spec.image ? `<div class="cl-img"><img src="${imageInfo(spec.image, L).url}"/></div>` : '';
    const qr = spec.qr ? `<img class="cl-qr" src="${imageInfo(spec.qr, L).url}"/>` : '';
    const contacts = (spec.contacts || []).map((c) => `<div>${esc(c)}</div>`).join('');
    return {
      bg: spec.background || 'var(--dark-bg)',
      push: true,
      html: img + `<div class="cl-box"><h1 class="cl-title">${esc(spec.title).replace(/\n/g, '<br>')}</h1>`
        + (spec.subtitle ? `<div class="cl-sub">${esc(spec.subtitle)}</div>` : '')
        + (contacts ? `<div class="cl-contacts">${contacts}</div>` : '') + qr + '</div>',
      css: DARK_TEXT + `
.cl-box{position:absolute;left:140px;top:0;bottom:0;width:${spec.image ? 1000 : 1640}px;display:flex;flex-direction:column;justify-content:center}
.cl-box>*{--stagger:.3s}
.cl-title{margin:0;font-size:84px;font-weight:800;line-height:1.1;letter-spacing:-.02em}
.cl-sub{margin-top:24px;font-size:40px;font-weight:600;color:var(--accent-hi)}
.cl-contacts{margin-top:48px;font-size:32px;line-height:1.6;color:var(--on-dark-muted)}
.cl-qr{margin-top:36px;width:200px;height:200px;border-radius:12px;background:#fff;padding:10px}
.cl-img{position:absolute;right:110px;top:50%;width:640px;height:640px;margin-top:-320px;border-radius:50%;overflow:hidden;
  box-shadow:0 30px 90px rgba(0,0,0,.45);--dy:0px;--from-scale:.9}
.cl-img img{width:100%;height:100%;object-fit:cover}`,
      steps: [{ show: '.cl-img, .cl-title, .cl-sub, .cl-contacts, .cl-qr', speech: spec.speech, text: spec.text, voice: spec.voice },
        { hold: spec.outro ?? 2 }],
    };
  },
};

export const LAYOUTS = Object.keys(templates);

/**
 * Spec → built slide { html, css, steps, bg, push, maxZoom }. Templates by `layout`; a custom page by
 * `html` (or `file`) + `css` + protocol `steps`.
 */
export function buildSlide(spec) {
  if (!spec || typeof spec !== 'object') throw new SpecError('showSlide: spec must be an object');
  if (spec.layout !== undefined) {
    const t = templates[spec.layout];
    if (!t) throw new SpecError(`showSlide: unknown layout "${spec.layout}" — one of: ${LAYOUTS.join(', ')}`);
    return t(spec);
  }
  let html = spec.html;
  if (html === undefined && spec.file) {
    const abs = resolveProjectPath(spec.file);
    if (!existsSync(abs)) throw new SpecError(`showSlide: page file not found: ${abs}`);
    html = readFileSync(abs, 'utf8');
  }
  if (typeof html !== 'string') throw new SpecError(`showSlide: need "layout" (${LAYOUTS.join(', ')}) or "html" / "file"`);
  if (spec.steps !== undefined && !isArr(spec.steps)) throw new SpecError('showSlide(page): "steps" must be an array');
  // script: a function (runs in the page) or a .js file from the project root (its body, `slide` in scope)
  let script;
  if (typeof spec.script === 'function') script = { fn: spec.script };
  else if (isStr(spec.script)) {
    const abs = resolveProjectPath(spec.script);
    if (!existsSync(abs)) throw new SpecError(`showSlide(page): script not found: ${abs}`);
    script = { file: abs };
  } else if (spec.script !== undefined) throw new SpecError('showSlide(page): "script" must be a function or a .js path');
  return {
    html: rewriteAssets(html), css: rewriteAssets(spec.css || ''), steps: spec.steps || [],
    bg: rewriteAssets(spec.background), push: spec.push, maxZoom: spec.maxZoom, script,
  };
}
