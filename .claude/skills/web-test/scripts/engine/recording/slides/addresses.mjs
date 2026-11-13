// web-test recording/slides/addresses v1.0 — addresses of a template's elements and the step verbs on them.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// A template registers its elements (a block, a flow input, a comparison cell, the centre, a mark) with the
// selectors the protocol needs; a step then names them by address instead of CSS:
//   2 · 'lead' · 'center' · 'all' · { in: 1 } · { out: [0, 1] } · { row: 2 } · { left: 0 } · { block: 2, item: 1 }
//   · { center: true, item: 0 } · { mark: 'src' } · [several of these]
// Verbs: show (and the template's own focus on what appears), focus, dim, undim, hide, status, camera.
// A string that is not a plain word stays a CSS selector (an own page's habit; a template's inner classes).

export const STATUSES = ['ok', 'warn', 'off', 'optional'];   // protocol.mjs pageStep repeats them (page side)
const J = (v) => JSON.stringify(v);
const range = (n) => [...Array(n).keys()];
// address kinds: object key → element key prefix
const KINDS = { block: 'b', in: 'in', out: 'out', row: 'row', left: 'l', right: 'r' };
const NAMED = ['center', 'lead', 'next', 'left', 'right'];

/**
 * The element table of one slide. el: { key, label, text, show, focus, box, st, items, img, inAll }
 * show — what appears (a card and its link), focus — what lights up (null: nothing), box — the element itself
 * (items, marks, camera), st — the element carrying the status class (null: no status), items — how many
 * points inside, img — its picture (camera fill), inAll — shown by 'all', link — its line to the hub (linkTo:
 * the hub's key): the line appears once both ends are on screen.
 */
export class Addr {
  constructor(layout, fail) {
    this.L = layout;
    this.fail = fail;
    this.els = new Map();
    this.count = {};
  }

  add(key, el) {
    const m = key.match(/^(b|in|out|row|l|r)(\d+)$/);
    if (m) this.count[m[1]] = Math.max(this.count[m[1]] || 0, Number(m[2]) + 1);
    const label = m
      ? (m[1] === 'b' ? m[2] : `{ ${{ in: 'in', out: 'out', row: 'row', l: 'left', r: 'right' }[m[1]]}: ${m[2]} }`)
      : key.startsWith('mark:') ? `{ mark: '${key.slice(5)}' }` : `'${key}'`;
    this.els.set(key, { key, label, text: '', show: null, focus: null, box: null, st: null, items: 0, img: null, inAll: false, link: null, linkTo: null, ...el });
  }

  /** Address lines for preview and errors: `{ in: 1 } «Данные»`, `{ block: 2, item: 0 } «…»`. */
  list() {
    const out = [];
    for (const el of this.els.values()) {
      out.push(`${el.label}${el.text ? ` «${el.text}»` : ''}`);
      for (const [j, t] of (el.itemTexts || []).entries()) out.push(`${this.itemLabel(el, j)}${t ? ` «${t}»` : ''}`);
    }
    return out;
  }

  itemLabel(el, j) {
    const m = el.key.match(/^(b|in|out)(\d+)$/);
    if (m) return `{ ${m[1] === 'b' ? 'block' : m[1]}: ${m[2]}, item: ${j} }`;
    return `{ ${el.key}: true, item: ${j} }`;
  }

  err(where, v, why) {
    const list = this.list();
    const shown = list.length > 40 ? [...list.slice(0, 40), `… ${list.length - 40} more`] : list;
    this.fail(`${where} ${J(v)} — ${why}; addresses: ${shown.join(', ')}`);
  }

  one(key, item, raw, where) {
    const el = this.els.get(key);
    if (!el) this.err(where, raw, 'no such element');
    if (item === undefined) return [{ el }];
    if (!el.items) this.err(where, raw, `${el.label} has no items`);
    const js = item === 'all' ? range(el.items) : [].concat(item);
    for (const j of js) if (!(Number.isInteger(j) && j >= 0 && j < el.items)) this.err(where, raw, `item must be 0..${el.items - 1} or 'all'`);
    return js.map((j) => ({ el, item: j }));
  }

  /** Address (or a list of them) → [{ el, item? }]. 'all' — the template's 'all' set. */
  targets(v, where) {
    if (Array.isArray(v)) return v.flatMap((x) => this.targets(x, where));
    if (Number.isInteger(v)) return this.one(`b${v}`, undefined, v, where);
    if (typeof v === 'string') {
      if (v === 'all') return [...this.els.values()].filter((e) => e.inAll).map((el) => ({ el }));
      return this.one(v, undefined, v, where);
    }
    if (v && typeof v === 'object') {
      const keys = Object.keys(v).filter((k) => k !== 'item');
      if (keys.length !== 1) this.err(where, v, `one of ${[...Object.keys(KINDS), 'center', 'lead', 'next', 'mark'].join(', ')} (and item)`);
      const k = keys[0], val = v[k];
      if (KINDS[k]) {
        // { left: true } / { right: true } — the whole side, like 'left'
        if (val === true && (k === 'left' || k === 'right')) return this.one(k, v.item, v, where);
        const pre = KINDS[k];
        const idx = val === 'all' ? range(this.count[pre] || 0).filter((i) => this.els.has(`${pre}${i}`)) : [].concat(val);
        if (!idx.length || !idx.every(Number.isInteger)) this.err(where, v, `${k}: an index, a list or 'all'`);
        return idx.flatMap((i) => this.one(`${pre}${i}`, v.item, v, where));
      }
      if (NAMED.includes(k)) {
        if (val !== true) this.err(where, v, `${k}: true`);
        return this.one(k, v.item, v, where);
      }
      if (k === 'mark') return [].concat(val).flatMap((n) => this.one(`mark:${n}`, v.item, v, where));
      this.err(where, v, 'unknown address');
    }
    this.err(where, v, 'an index, a key or an address object');
    return [];
  }
}

const itemSel = (el, j) => `${el.box} .ws-i${j}`;
const sel = (t, f) => (t.item === undefined ? t.el[f] : itemSel(t.el, t.item));
const join = (xs) => [...new Set(xs.filter(Boolean))].join(', ');
// a plain word is a key (or a typo of one); anything else is a CSS selector
const isCss = (v) => typeof v === 'string' && !/^[\w-]+$/.test(v);
const hasAll = (v) => [].concat(v).includes('all');

/**
 * Template steps → protocol steps, one to one. opts: autoFocus (default true) — what a step shows is lit;
 * dimBefore — earlier shown blocks dim (radial); clearFocus — a step showing nothing to light drops the focus
 * (summary). Returns { steps, items } — items: the points still to show at the end (blocks shown point by point).
 */
export function mapSteps(A, steps0, opts = {}) {
  const { autoFocus = true, dimBefore = false, clearFocus = false, legacy } = opts;
  const src = steps0.map((s) => (legacy ? legacy({ ...s }) : { ...s }));
  // pass 1: what each show names; blocks whose points are shown one by one
  const shows = src.map((s, i) => (s.show === undefined || isCss(s.show) ? null : A.targets(s.show, `step ${i + 1}: show`)));
  const byItem = new Map();
  for (const T of shows) for (const t of T || []) if (t.item !== undefined) byItem.set(t.el.key, t.el);
  const allItems = join([...byItem.values()].map((el) => `${el.box} .ws-i`));
  const verb = (v, where, f) => {
    if (v === null) return null;
    if (isCss(v)) return v;
    return join(A.targets(v, where).map((t) => sel(t, f)));
  };
  const shownB = [];
  // a link to the hub: on screen once both its ends are — an item shown before the hub gets its line with the hub
  const visible = new Set(), linked = new Set();
  const linksNow = () => {
    const out = [];
    for (const el of A.els.values()) {
      if (el.link && !linked.has(el.key) && visible.has(el.key) && visible.has(el.linkTo)) { linked.add(el.key); out.push(el.link); }
    }
    return out;
  };
  const steps = src.map((s, i) => {
    const n = i + 1;
    const { show, focus, dim, undim, hide, status, camera, ...st } = s;
    if (show !== undefined) {
      if (isCss(show)) st.show = show;
      else {
        const T = shows[i];
        const parts = T.map((t) => sel(t, 'show'));
        if (hasAll(show) && allItems) parts.push(allItems);
        for (const t of T) if (t.item === undefined) visible.add(t.el.key);
        parts.push(...linksNow());
        st.show = join(parts);
        // what the step names besides 'all' is lit ('all' alone lights nothing: everything is lit at the end)
        const named = hasAll(show) ? A.targets([].concat(show).filter((x) => x !== 'all'), `step ${n}: show`) : T;
        if (focus === undefined && autoFocus && named.length) {
          const f = join(named.map((t) => (t.item === undefined ? join([t.el.focus, linked.has(t.el.key) && t.el.link]) : itemSel(t.el, t.item))));
          if (f) st.focus = f;
          else if (clearFocus) st.focus = null;
        }
        if (dimBefore && dim === undefined && !hasAll(show)) {
          const blocks = T.filter((t) => t.item === undefined && t.el.key.startsWith('b'));
          if (blocks.length) {
            if (shownB.length) st.dim = join(shownB);
            shownB.push(...blocks.map((t) => join([t.el.show, t.el.link])));
          }
        }
      }
    }
    if (focus !== undefined) st.focus = verb(focus, `step ${n}: focus`, 'focus') ?? null;
    if (st.focus === '') st.focus = null;
    if (dim !== undefined) st.dim = verb(dim, `step ${n}: dim`, 'box');
    if (undim !== undefined) st.undim = verb(undim, `step ${n}: undim`, 'box');
    if (hide !== undefined) {
      if (isCss(hide) || hide === null) st.hide = hide;
      else {
        const T = A.targets(hide, `step ${n}: hide`);
        st.hide = join(T.map((t) => (t.item === undefined ? join([t.el.show, t.el.link]) : itemSel(t.el, t.item))));
        for (const t of T) {
          if (t.item !== undefined) continue;
          visible.delete(t.el.key);
          linked.delete(t.el.key);
          // the hub hidden: every line to it goes too
          for (const e of A.els.values()) if (e.linkTo === t.el.key) linked.delete(e.key);
        }
      }
    }
    if (status !== undefined) st.status = statusOf(A, status, `step ${n}: status`);
    if (camera !== undefined) Object.assign(st, cameraOf(A, camera, `step ${n}: camera`));
    return st;
  });
  return { steps, items: allItems };
}

// status: { off: [1, 3] } · { warn: { out: 0 } } · { none: 2 } — the status by its value, the elements by address
function statusOf(A, v, where) {
  if (!v || typeof v !== 'object' || Array.isArray(v)) A.fail(`${where} must be { <status>: address } — ${[...STATUSES, 'none'].join(', ')}`);
  const out = [];
  for (const [to, addr] of Object.entries(v)) {
    if (![...STATUSES, 'none'].includes(to)) A.fail(`${where}: "${to}" — a status is ${[...STATUSES, 'none'].join(', ')}`);
    for (const t of A.targets(addr, `${where}.${to}`)) {
      if (t.item !== undefined) A.err(`${where}.${to}`, addr, 'a status is a block\'s, not an item\'s');
      if (!t.el.st) A.err(`${where}.${to}`, addr, `${t.el.label} takes no status`);
      out.push({ sel: t.el.st, to: to === 'none' ? null : to });
    }
  }
  return out;
}

// camera: address · { to: address, fill: true } · null
function cameraOf(A, v, where) {
  if (v === null) return { camera: null };
  if (isCss(v)) return { camera: v };
  // [x, y, w, h] in stage pixels (as on a page of your own): four numbers that are not all indexes of blocks
  if (Array.isArray(v) && v.length === 4 && v.every((x) => typeof x === 'number')
    && !v.every((x) => A.els.has(`b${x}`))) return { camera: v };
  if (v && typeof v === 'object' && !Array.isArray(v) && 'to' in v) {
    const T = A.targets(v.to, `${where}.to`);
    if (v.fill) {
      // a block with a picture fills the frame with the picture, not with the card around it
      if (T.length !== 1) A.err(`${where}.to`, v.to, 'fill takes one element');
      const t = T[0];
      return { camera: (t.item === undefined && t.el.img) || sel(t, 'box'), fill: true };
    }
    return { camera: join(T.map((t) => sel(t, 'box'))) };
  }
  return { camera: join(A.targets(v, where).map((t) => sel(t, 'box'))) };
}

// ── marks: a frame round elements, a callout at one, a banner at the bottom ─
const BANNER_H = 88;
// the room a banner takes at the bottom (its height + a gap): templates lay out above it (--safe-bottom)
export const BANNER_ROOM = BANNER_H + 24;
export const MARK_CSS = `
.ws-mk{position:absolute;pointer-events:none}
.ws-mk-frame{border:3px solid color-mix(in srgb, var(--line) 55%, transparent);border-radius:22px;--dy:0px;--from-scale:.97}
.ws-mk-frame>span{position:absolute;left:26px;top:-19px;padding:5px 16px;border-radius:999px;background:var(--primary);color:#fff;
  font-size:22px;font-weight:700;letter-spacing:.04em;line-height:1.2;white-space:nowrap}
.ws-mk-frame.ws-focus{animation:none;border-color:var(--accent);box-shadow:0 0 0 6px color-mix(in srgb, var(--accent) 18%, transparent)}
.ws-mk-frame.ws-focus>span{background:var(--accent);color:var(--on-accent)}
.ws-mk-call{padding:10px 20px;border-radius:14px;background:var(--primary);color:#fff;font-size:24px;font-weight:600;line-height:1.25;
  max-width:560px;box-shadow:0 10px 30px color-mix(in srgb, var(--primary) 30%, transparent);--dy:10px}
.ws-mk-call::after{content:'';position:absolute;border:11px solid transparent}
.ws-mk-call.ws-mk-top::after{left:var(--px,50%);top:100%;margin-left:-11px;border-top-color:var(--primary)}
.ws-mk-call.ws-mk-bottom::after{left:var(--px,50%);bottom:100%;margin-left:-11px;border-bottom-color:var(--primary)}
.ws-mk-call.ws-mk-left::after{top:50%;left:100%;margin-top:-11px;border-left-color:var(--primary)}
.ws-mk-call.ws-mk-right::after{top:50%;right:100%;margin-top:-11px;border-right-color:var(--primary)}
.ws-mk-call.ws-focus{animation:none;background:var(--accent);color:var(--on-accent)}
.ws-mk-call.ws-focus::after{border-top-color:transparent;border-bottom-color:transparent;border-left-color:transparent;border-right-color:transparent}
.ws-mk-call.ws-focus.ws-mk-top::after{border-top-color:var(--accent)} .ws-mk-call.ws-focus.ws-mk-bottom::after{border-bottom-color:var(--accent)}
.ws-mk-call.ws-focus.ws-mk-left::after{border-left-color:var(--accent)} .ws-mk-call.ws-focus.ws-mk-right::after{border-right-color:var(--accent)}
.ws-mk-banner{left:max(96px, var(--safe-left));right:max(96px, var(--safe-right));bottom:max(40px, var(--ws-frame-bottom, 0px));height:${BANNER_H}px;
  display:flex;align-items:center;justify-content:center;padding:0 36px;border-radius:16px;background:var(--primary);color:#fff;
  font-size:32px;font-weight:600;line-height:1.2;text-align:center;--dy:16px}
.ws-mk-banner.ws-focus{animation:none;box-shadow:inset 0 -6px 0 var(--accent)}
`;
const SIDES = ['top', 'bottom', 'left', 'right'];

/**
 * spec.marks { name: { frame: address(es), label } | { callout: address, label, side } | { banner: 'text' } }
 * → { html, banner } and { mark: name } elements in the table. Positions are laid out on the page (pageMount)
 * from the elements' boxes: data-around (a frame round all of them), data-at (a callout at the first).
 */
export function marksOf(A, spec, esc) {
  const marks = spec.marks;
  if (marks === undefined) return { html: '', banner: false };
  if (!marks || typeof marks !== 'object' || Array.isArray(marks)) A.fail('"marks" must be an object { name: { frame | callout | banner } }');
  let html = '', banner = false;
  for (const [name, m] of Object.entries(marks)) {
    const where = `marks.${name}`;
    if (!/^[\w-]+$/.test(name)) A.fail(`${where}: a name of letters, digits, - and _`);
    if (!m || typeof m !== 'object') A.fail(`${where} must be { frame | callout | banner }`);
    const kind = ['frame', 'callout', 'banner'].filter((k) => m[k] !== undefined);
    if (kind.length !== 1) A.fail(`${where}: one of frame, callout, banner`);
    const cls = `mk-${name}`;
    if (kind[0] === 'banner') {
      if (typeof m.banner !== 'string' || !m.banner.trim()) A.fail(`${where}.banner must be text`);
      if (banner) A.fail(`${where}: one banner per slide`);
      banner = true;
      html += `<div class="${cls} ws-mk ws-mk-banner">${esc(m.banner)}</div>`;
      A.add(`mark:${name}`, { text: m.banner, show: `.${cls}`, focus: `.${cls}`, box: `.${cls}` });
      continue;
    }
    if (m.label !== undefined && typeof m.label !== 'string') A.fail(`${where}.label must be text`);
    const T = A.targets(m[kind[0]], `${where}.${kind[0]}`);
    const around = join(T.map((t) => sel(t, 'box')));
    if (kind[0] === 'frame') {
      html += `<div class="${cls} ws-mk ws-mk-frame" data-around="${esc(around)}">${m.label ? `<span>${esc(m.label)}</span>` : ''}</div>`;
    } else {
      if (!m.label) A.fail(`${where}: a callout needs a label`);
      const side = m.side ?? 'top';
      if (!SIDES.includes(side)) A.fail(`${where}.side must be ${SIDES.join(', ')}`);
      html += `<div class="${cls} ws-mk ws-mk-call ws-mk-${side}" data-at="${esc(around)}" data-side="${side}">${esc(m.label)}</div>`;
    }
    A.add(`mark:${name}`, { text: m.label || '', show: `.${cls}`, focus: `.${cls}`, box: `.${cls}` });
  }
  return { html, banner };
}

// points inside blocks: appear one by one, lit with a soft accent plate
export const ITEM_CSS = `
.ws-i{--dy:10px;--dx:0px;--stagger:.12s}
.ws-i.ws-focus{animation:none;border-radius:8px;background:color-mix(in srgb, var(--accent) 16%, transparent)}
`;
