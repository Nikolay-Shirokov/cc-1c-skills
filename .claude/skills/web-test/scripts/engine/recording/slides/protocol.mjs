// web-test recording/slides/protocol v1.10 — step-slide protocol: base CSS + theme, page-side mount/step/lint.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// A slide is a 1920×1080 page inside a shadow root (its CSS cannot touch a neighbour slide or the
// host page, and the host page's CSS cannot leak in). Steps change state classes; the motion is CSS:
//   ws-pending → .on   reveal (opacity + transform from --dx/--dy/--from-scale; cascade by --stagger)
//   ws-focus           emphasis (pulse by default; templates restyle it; cascade by --focus-stagger)
//   ws-dim             fade into the background (opacity — a filter would re-rasterize mid-step)
// Animated elements get .ws-t (transitions + will-change: own layer from the start, so no one-frame
// re-raster jump when a transition begins).
//
// Page-side functions below run in the browser via page.evaluate — they must stay self-contained.

export const W = 1920, H = 1080;
const EASE = 'cubic-bezier(.2,.8,.2,1)';
const CAM = 'cubic-bezier(.65,0,.35,1)';
const SOFT = 'cubic-bezier(.33,0,.2,1)';   // gentle start, soft landing (EASE front-loads → reads as a jerk)
export { EASE };

// Theme: base colours (primary, accent, ground, ink; optional line, mark, onAccent, surface, onSurface, font,
// fonts); the rest derived. Structure (headers, links, arrows, rules, tints) is shades of primary; the accent
// marks what is being said now (focus) plus title rules, numbers and callouts.
// Two families of text colours: on the slide's ground (ink, ink2, muted, heading) and on cards and plates —
// the surface (on-surface, surface-ink2, surface-muted, surface-heading). A light ground keeps white cards;
// a dark one derives dark cards a shade lighter than the ground (themeVars).
export const DEFAULT_THEME = { primary: '#16213e', accent: '#f0a202', ground: '#f4f6fa', ink: '#1a1a2e' };

export const BASE_CSS = `
.ws-slide{all:initial}   /* nothing inherited from the page: font features, spacing, colour */
.ws-slide{
  --primary:${DEFAULT_THEME.primary}; --accent:${DEFAULT_THEME.accent}; --ground:${DEFAULT_THEME.ground}; --ink:${DEFAULT_THEME.ink};
  --mark:var(--accent); --on-accent:var(--ink); --font:'Segoe UI',Arial,sans-serif; --heading-weight:800;
  --line:color-mix(in oklab, var(--primary), #fff 45%);   /* structure: links, arrows, card rules, list markers */
  --primary-hi:color-mix(in oklab, var(--primary), #fff 18%);
  --primary-dk:color-mix(in oklab, var(--primary), #000 35%);
  --ink2:color-mix(in oklab, var(--ink) 85%, var(--ground));
  --muted:color-mix(in oklab, var(--ink) 55%, var(--ground));
  --heading:var(--primary);   /* big headings on the ground */
  --surface:#fff; --on-surface:var(--ink);   /* cards, plates, cells */
  --surface-ink2:color-mix(in oklab, var(--on-surface) 85%, var(--ground));
  --surface-muted:color-mix(in oklab, var(--on-surface) 55%, var(--ground));
  --surface-heading:var(--primary);
  --surface-soft:color-mix(in oklab, var(--primary) 7%, var(--surface));   /* quiet tint inside a card */
  --surface-edge:transparent;   /* card outline (a dark ground draws it) */
  --shadow:var(--ink);
  --soft:var(--surface-soft);   /* quiet tint for item boxes and number badges */
  --status-ok:#2fb36a; --status-warn:#e8a317;   /* element statuses (templates' status field) */
  --safe-top:0px; --safe-right:0px; --safe-bottom:0px; --safe-left:0px;   /* fields kept for the frame (theme.frame) */
  --accent-hi:color-mix(in oklab, var(--accent), #fff 25%);
  --accent-text:color-mix(in oklab, var(--accent), #000 30%);
  --on-dark:#f4f4f6; --on-dark-muted:color-mix(in oklab, var(--on-dark) 70%, var(--primary));
  --c1:var(--primary);
  --c2:color-mix(in oklab, var(--primary), #fff 20%);
  --c3:color-mix(in oklab, var(--primary), #fff 40%);
  --c4:color-mix(in oklab, var(--primary), #000 25%);
  --c5:color-mix(in oklab, var(--primary), #fff 10%);
  --dark-bg:radial-gradient(120% 120% at 20% 30%, var(--primary-hi) 0%, var(--primary) 55%, var(--primary-dk) 100%);
  position:absolute;inset:0;overflow:hidden;background:var(--ground);font-family:var(--font);color:var(--ink)}
.ws-slide *{box-sizing:border-box}
.ws-stage{position:absolute;left:50%;top:50%;width:${W}px;height:${H}px;transform-origin:center}
.ws-push{position:absolute;inset:0;transform:scale(1);transition-property:transform;transition-timing-function:linear}
.ws-push.go{transform:scale(1.025)}
.ws-cam{position:absolute;left:0;top:0;width:${W}px;height:${H}px;transform-origin:0 0;transition:transform 1.4s ${CAM}}
.ws-spot{position:absolute;border-radius:12px;opacity:0;box-shadow:0 0 0 6000px color-mix(in srgb, var(--primary-dk) 55%, transparent),0 0 0 3px var(--mark);
  transition:left 1.4s ${CAM},top 1.4s ${CAM},width 1.4s ${CAM},height 1.4s ${CAM},opacity .6s ease}
.ws-t{will-change:transform,opacity;
  transition:opacity .9s ease-in-out,transform 1.1s ${SOFT},box-shadow .8s ease;
  transition-delay:calc(var(--si,0) * var(--stagger,0s)),calc(var(--si,0) * var(--stagger,0s)),0s}
.ws-pending{opacity:0;transform:translate(var(--dx,0px),var(--dy,24px)) scale(var(--from-scale,.98))}
.ws-pending.on{opacity:1;transform:none}
.ws-dim,.ws-pending.on.ws-dim{opacity:.32}
@keyframes wsPulse{0%,100%{scale:1}50%{scale:var(--pulse,1.05)}}
.ws-focus{animation:wsPulse .5s ease-in-out calc(var(--fi,0) * var(--focus-stagger,0s)) 1 both}
.ws-links{position:absolute;inset:0;overflow:visible;pointer-events:none}
.ws-links path{fill:none;stroke:var(--line);stroke-width:3;stroke-linecap:round;--dy:0px;--from-scale:1}
.ws-links path.ws-pending:not(.on){stroke-dashoffset:var(--len)}
.ws-links path.on{stroke-dashoffset:0}
.ws-links path.ws-focus{animation:none;stroke:var(--accent)}
.ws-links path.ws-t{transition:stroke-dashoffset .7s cubic-bezier(.4,0,.2,1),opacity .4s ease,stroke .5s ease}
.ws-static, .ws-static *{transition:none !important;animation:none !important}
/* camera fill: the element takes the whole frame — no rounding, no shadow; the frame (logo, number) fades */
.ws-fill-el, .ws-fill-el *{border-radius:0 !important;box-shadow:none !important}
.ws-frame{transition:opacity .6s ease}
.ws-filled .ws-frame{opacity:0}
/* the frame: logo, slide number, footer — outside the push and the camera, it stands still */
.ws-frame{position:absolute;inset:0;pointer-events:none;font-size:22px;color:var(--muted)}
.wf-c{position:absolute;display:flex;align-items:center;gap:28px}
.wf-top-left{top:40px;left:54px} .wf-top-right{top:40px;right:54px;flex-direction:row-reverse}
.wf-bottom-left{bottom:40px;left:54px} .wf-bottom-right{bottom:40px;right:54px;flex-direction:row-reverse}
.wf-logo{display:block;height:30px;width:auto;max-width:320px;object-fit:contain}
.wf-num{font-weight:700;letter-spacing:.04em}
.wf-text{white-space:nowrap;letter-spacing:.04em}
.wf-edge{position:absolute;top:50%;white-space:nowrap;letter-spacing:.06em;max-width:800px;overflow:hidden;text-overflow:ellipsis}
.wf-edge.wf-left{left:64px;transform:translate(-50%,-50%) rotate(-90deg)}
.wf-edge.wf-right{right:64px;transform:translate(50%,-50%) rotate(90deg)}
`;

/** Relative luminance of a #rgb / #rrggbb / rgb() colour, or null for anything else (a name, a gradient). */
export function luminance(c) {
  const s = String(c ?? '').trim();
  let m = s.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i), rgb;
  if (m) {
    const h = m[1].length === 3 ? [...m[1]].map((x) => x + x).join('') : m[1];
    rgb = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  } else if ((m = s.match(/^rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/i))) rgb = m.slice(1, 4).map(Number);
  else return null;
  const [r, g, b] = rgb.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
const isDark = (c) => { const l = luminance(c); return l != null && l < 0.18; };   // white text reads better below ~0.18

/**
 * Theme object → CSS custom properties (camelCase keys → --kebab-case). Only scalar keys become properties
 * (`fonts` is loaded and `background` laid by index.mjs). A dark ground (or a dark `surface`) derives what the light defaults
 * cannot: dark cards a shade lighter than the ground, light text on them, headings in ink, an outline
 * instead of a shadow. Explicit keys always win; a light ground keeps the defaults as they are.
 */
export function themeVars(theme) {
  const t = theme || {};
  const out = {};
  const set = (k, v) => { if (!(k in out)) out[k] = v; };
  for (const [k, v] of Object.entries(t)) {
    if (v == null || v === '' || typeof v === 'object' || k === 'background') continue;   // background: the slide's ground, not a colour
    out[`--${k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())}`] = String(v);
  }
  const family = Array.isArray(t.fonts) && typeof t.fonts[0]?.family === 'string' ? t.fonts[0].family.trim() : '';
  if (family && !t.font) out['--font'] = `'${family.replace(/['\\]/g, '\\$&')}','Segoe UI',Arial,sans-serif`;
  const groundDark = isDark(t.ground ?? DEFAULT_THEME.ground);
  const surfaceDark = t.surface !== undefined ? isDark(t.surface) : groundDark;
  const inkDark = isDark(t.ink ?? DEFAULT_THEME.ink);
  if (groundDark) {
    set('--heading', 'var(--ink)');
    set('--accent-text', 'var(--accent-hi)');
    set('--shadow', '#000');
    set('--surface-edge', 'color-mix(in oklab, var(--line) 45%, transparent)');
    set('--surface', 'color-mix(in oklab, var(--ground), #fff 8%)');   // a shade lighter than the ground, whatever primary is
    // header bands: shades of primary vanish on a ground of the same depth — the accent tinted into the card
    // instead, at different strengths (distinct from the ground and the card body, white text stays readable)
    [['--c1', 26], ['--c2', 38], ['--c3', 18], ['--c4', 32], ['--c5', 44]]
      .forEach(([k, p]) => set(k, `color-mix(in oklab, var(--accent) ${p}%, var(--surface))`));
  }
  if (surfaceDark && inkDark) set('--on-surface', '#f4f4f6');
  if (!surfaceDark && !inkDark) set('--on-surface', DEFAULT_THEME.ink);
  if (surfaceDark) {
    set('--surface-heading', 'var(--on-surface)');
    set('--surface-soft', 'color-mix(in oklab, var(--on-surface) 9%, var(--surface))');
  }
  if (groundDark || surfaceDark) {
    set('--surface-ink2', 'color-mix(in oklab, var(--on-surface) 85%, var(--surface))');
    set('--surface-muted', 'color-mix(in oklab, var(--on-surface) 62%, var(--surface))');
  }
  return out;
}

// ── page side ─────────────────────────────────────────────────────────────

/**
 * Mount a slide (page side). Order matters: layout first (fit, links) on untransformed elements,
 * then pending states without transitions, then .ws-t — so nothing animates from the measuring state.
 */
export function pageMount({ html, css, bg, vars, pushSec, animated, instant, staticMode, hostId, frame }) {
  const old = document.getElementById('__ws_slide');
  if (old) old.id = '__ws_slide_old';
  const host = document.createElement('div');
  host.id = '__ws_slide';
  if (hostId) host.dataset.kind = hostId;
  // not in the page's language: it picks a font's local letter forms (lang="bg" — the Bulgarian Cyrillic of
  // Montserrat); the page's text styles stop at .ws-slide (BASE_CSS)
  host.lang = '';
  host.style.cssText = 'position:fixed;inset:0;z-index:999999;pointer-events:none;'
    + (instant ? 'opacity:1' : 'opacity:0;transition:opacity .5s ease');
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `<style>${css}</style><div class="ws-slide${staticMode ? ' ws-static' : ''}"><div class="ws-stage">`
    + `<div class="ws-push"><div class="ws-cam">${html}<div class="ws-spot"></div></div></div>`
    + (frame ? `<div class="ws-frame">${frame}</div>` : '') + '</div></div>';
  const slide = root.querySelector('.ws-slide');
  for (const [k, v] of Object.entries(vars || {})) slide.style.setProperty(k, v);
  if (bg) slide.style.background = bg;
  document.body.appendChild(host);
  const stage = root.querySelector('.ws-stage');
  const scale = Math.min(innerWidth / 1920, innerHeight / 1080);
  stage.style.transform = `translate(-50%,-50%) scale(${scale})`;
  stage.style.setProperty('--k', scale);   // stage px per page px — for sizes given in page pixels (legacy overlays)

  // 1. fit: shrink the children of .ws-fit boxes until they stop overflowing — but no text below 22px
  //    on the stage (past that the box overflows and the check says so: split the slide)
  root.querySelectorAll('.ws-fit').forEach((box) => {
    let minFs = Infinity;
    box.querySelectorAll('*').forEach((el) => {
      if ([...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) minFs = Math.min(minFs, parseFloat(getComputedStyle(el).fontSize));
    });
    const min = Math.min(1, Math.max(Number(box.dataset.minZoom || 0.6), minFs === Infinity ? 0.6 : 22 / minFs));
    let z = 1;
    const over = () => box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1;
    while (over() && z > min) {
      z = Math.max(min, Math.round((z - 0.04) * 100) / 100);
      for (const c of box.children) c.style.zoom = z;
    }
  });

  // 2. links: <svg class="ws-links" data-from="sel" data-round> with <path data-to="sel">, drawn from the
  //    "from" box (or its circle edge) to the nearest vertical edge of the target
  const sr = stage.getBoundingClientRect(), k = sr.width / 1920;
  const box = (el) => { const r = el.getBoundingClientRect(); return { x: (r.left - sr.left) / k, y: (r.top - sr.top) / k, w: r.width / k, h: r.height / k }; };
  root.querySelectorAll('svg.ws-links').forEach((svg) => {
    const fromEl = root.querySelector(svg.dataset.from);
    if (!fromEl) return;
    const f = box(fromEl), cx = f.x + f.w / 2, cy = f.y + f.h / 2, R = svg.dataset.round !== undefined ? f.w / 2 : 0;
    svg.querySelectorAll('path[data-to]').forEach((p) => {
      const t = root.querySelector(p.dataset.to);
      if (!t) return;
      const r = box(t), tx = r.x + r.w / 2 < cx ? r.x + r.w : r.x, ty = r.y + r.h / 2;
      const a = Math.atan2(ty - cy, tx - cx), ca = Math.cos(a), sa = Math.sin(a);
      // from the rim of a circle, from the edge of a plate — a line from the middle shows through it while it fades in
      const d = R || Math.min(Math.abs(ca) > 1e-6 ? f.w / 2 / Math.abs(ca) : Infinity, Math.abs(sa) > 1e-6 ? f.h / 2 / Math.abs(sa) : Infinity);
      const sx = cx + d * ca, sy = cy + d * sa;
      const len = Math.hypot(tx - sx, ty - sy);
      p.setAttribute('d', `M${sx.toFixed(1)} ${sy.toFixed(1)} L${tx.toFixed(1)} ${ty.toFixed(1)}`);
      p.style.strokeDasharray = len.toFixed(1);
      p.style.setProperty('--len', len.toFixed(1));
    });
  });

  // 2b. marks (addresses.mjs): a frame round all its elements, a callout at the side of its element (stage px)
  const union = (sel) => {
    const rs = [...root.querySelectorAll(sel)].map(box).filter((r) => r.w && r.h);
    if (!rs.length) return null;
    const x = Math.min(...rs.map((r) => r.x)), y = Math.min(...rs.map((r) => r.y));
    return { x, y, w: Math.max(...rs.map((r) => r.x + r.w)) - x, h: Math.max(...rs.map((r) => r.y + r.h)) - y };
  };
  root.querySelectorAll('.ws-mk[data-around]').forEach((m) => {
    const u = union(m.dataset.around), pad = 18;
    if (u) Object.assign(m.style, { left: `${u.x - pad}px`, top: `${u.y - pad}px`, width: `${u.w + 2 * pad}px`, height: `${u.h + 2 * pad}px` });
  });
  root.querySelectorAll('.ws-mk[data-at]').forEach((m) => {
    const u = union(m.dataset.at);
    if (!u) return;
    const mw = m.offsetWidth, mh = m.offsetHeight, gap = 16, side = m.dataset.side;
    let x, y;
    if (side === 'left' || side === 'right') {
      x = side === 'left' ? u.x - gap - mw : u.x + u.w + gap;
      y = u.y + u.h / 2 - mh / 2;
    } else {
      x = u.x + u.w / 2 - mw / 2;
      y = side === 'bottom' ? u.y + u.h + gap : u.y - gap - mh;
    }
    const cx = Math.min(Math.max(x, 24), 1920 - 24 - mw), cy = Math.min(Math.max(y, 24), 1080 - 24 - mh);
    // the pointer stays at the element when the box is pushed back into the frame
    if (side === 'top' || side === 'bottom') m.style.setProperty('--px', `${Math.min(Math.max(u.x + u.w / 2 - cx, 20), mw - 20)}px`);
    Object.assign(m.style, { left: `${cx}px`, top: `${cy}px` });
  });

  // 3. pending states without transitions, then transitions
  for (const sel of animated.show) root.querySelectorAll(sel).forEach((e) => e.classList.add('ws-pending'));
  void slide.offsetHeight;
  for (const sel of animated.all) root.querySelectorAll(sel).forEach((e) => e.classList.add('ws-t'));

  const start = () => {
    host.style.opacity = 1;
    if (pushSec) {
      const p = root.querySelector('.ws-push');
      p.style.transitionDuration = pushSec + 's';
      p.classList.add('go');
    }
  };
  if (instant) { if (pushSec) requestAnimationFrame(() => requestAnimationFrame(start)); }
  else requestAnimationFrame(() => requestAnimationFrame(start));
  // whatever was on screen goes away once the new slide is up (legacy overlays too). Not at once even for an
  // instant swap: a slide with a big picture paints a moment later, and the page under it must not show through.
  // a slide's script cleans up (ws-dispose) before its host goes
  const drop = (id) => document.querySelectorAll('#' + id).forEach((h) => {
    try { h.shadowRoot?.querySelector('.ws-stage')?.dispatchEvent(new Event('ws-dispose')); } catch {}
    h.remove();
  });
  setTimeout(() => ['__ws_slide_old', '__web_test_image', '__web_test_title'].forEach(drop), 650);
}

/** Apply one step (page side); the slide's script hears it as `ws-step` on the stage. */
export function pageStep({ step, index, maxZoom }) {
  const root = document.getElementById('__ws_slide')?.shadowRoot;
  if (!root) return;
  const q = (sel) => (sel ? [...root.querySelectorAll(sel)] : []);
  // the cascade (--stagger) is for appearing: lighting up again is at once, or a long card list takes seconds
  if (step.clear) root.querySelectorAll('.ws-focus, .ws-dim').forEach((e) => { e.style.setProperty('--si', 0); e.classList.remove('ws-focus', 'ws-dim'); });
  q(step.undim).forEach((e) => { e.style.setProperty('--si', 0); e.classList.remove('ws-dim'); });
  // a hidden element drops its dim too: .ws-dim would otherwise keep it on screen at a third of its opacity
  q(step.hide).forEach((e) => { e.style.setProperty('--si', 0); e.classList.remove('on', 'ws-focus', 'ws-dim'); });
  // the cascade counts what appears now; an element already on screen (a step that shows 'all' again) is not
  // re-queued — or lighting it up waits for its place in the list
  let si = 0;
  q(step.show).forEach((e) => { e.style.setProperty('--si', e.classList.contains('on') ? 0 : si++); e.classList.add('on'); });
  q(step.dim).forEach((e) => e.classList.add('ws-dim'));
  // a status set or changed on the way (addresses.mjs: status { off: … }): the class carries stripe, mark and fade
  for (const { sel, to } of step.status || []) {
    q(sel).forEach((e) => {
      [...e.classList].filter((c) => /^ws-st-(ok|warn|off|optional)$/.test(c)).forEach((c) => e.classList.remove(c));
      if (to) e.classList.add(`ws-st-${to}`);
    });
  }
  if (step.focus !== undefined) {
    root.querySelectorAll('.ws-focus').forEach((e) => e.classList.remove('ws-focus'));
    q(step.focus).forEach((e, i) => { e.style.setProperty('--fi', i); e.classList.remove('ws-dim'); e.classList.add('ws-focus'); });
  }
  root.querySelector('.ws-stage')?.dispatchEvent(new CustomEvent('ws-step', { detail: { index, step } }));
  if (step.camera === undefined) return;
  // an element is aimed at once its own entry (and its block's) has settled — measured mid-motion it is off
  // by its rise; a later camera step wins over one still waiting
  const seq = (root.__wsCam = (root.__wsCam || 0) + 1);
  const aim = () => {
    if (root.__wsCam !== seq) return;
    const cam = root.querySelector('.ws-cam'), spot = root.querySelector('.ws-spot');
    const slideEl = root.querySelector('.ws-slide'), push = root.querySelector('.ws-push');
    root.querySelectorAll('.ws-fill-el').forEach((e) => e.classList.remove('ws-fill-el'));
    if (!step.fill) {
      root.querySelectorAll('[data-ws-pinned]').forEach((x) => { x.style.transform = ''; delete x.dataset.wsPinned; });
      if (push.dataset.wsHeld !== undefined) { push.style.transform = ''; delete push.dataset.wsHeld; }
    }
    slideEl.classList.remove('ws-filled');
    let rect = step.camera, els = [];
    if (typeof rect === 'string') {
      // the elements' box in stage coordinates (their union), undoing the stage scale, the push and the camera
      els = [...root.querySelectorAll(rect)];
      if (!els.length) return;
      const st = root.querySelector('.ws-stage').getBoundingClientRect();
      const k = st.width / 1920, m = new DOMMatrix(getComputedStyle(cam).transform), pm = new DOMMatrix(getComputedStyle(push).transform);
      const rs = els.map((e) => e.getBoundingClientRect());
      const L = Math.min(...rs.map((r) => r.left)), T = Math.min(...rs.map((r) => r.top));
      const R = Math.max(...rs.map((r) => r.right)), B = Math.max(...rs.map((r) => r.bottom));
      // stage px → push layer (scaled about the centre) → camera layer
      const un = (x, y) => [((x - 960) - pm.e) / pm.a + 960, ((y - 540) - pm.f) / pm.d + 540];
      const [x0, y0] = un((L - st.left) / k, (T - st.top) / k), [x1, y1] = un((R - st.left) / k, (B - st.top) / k);
      rect = [(x0 - m.e) / m.a, (y0 - m.f) / m.a, (x1 - x0) / m.a, (y1 - y0) / m.a];
    }
    if (!rect) { cam.style.transform = 'none'; spot.style.opacity = 0; return; }
    if (step.fill) {
      // the element covers the whole frame (cropped to 16:9 if its proportions differ); the push stops and
      // returns to 1 with the camera — the frame then matches the page the slide hands over to
      const [X, Y, RW, RH] = rect, s = Math.max(1920 / RW, 1080 / RH);
      cam.style.transform = `translate(${960 - s * (X + RW / 2)}px,${540 - s * (Y + RH / 2)}px) scale(${s})`;
      const now = getComputedStyle(push).transform;
      push.style.transitionDuration = '0s';
      push.style.transform = now;
      void push.offsetHeight;
      push.style.transition = `transform 1.4s ${getComputedStyle(cam).transitionTimingFunction}`;
      push.style.transform = 'none';
      push.dataset.wsHeld = '';
      els.forEach((e) => e.classList.add('ws-fill-el'));
      slideEl.classList.add('ws-filled');
      spot.style.opacity = 0;
      return;
    }
    const pad = 14, [X, Y, RW, RH] = [rect[0] - pad, rect[1] - pad, rect[2] + 2 * pad, rect[3] + 2 * pad];
    const s = Math.max(1, Math.min((1920 * 0.84) / RW, (1080 * 0.78) / RH, maxZoom));
    const tx = Math.min(0, Math.max(1920 - 1920 * s, 960 - s * (X + RW / 2)));
    const ty = Math.min(0, Math.max(1080 - 1080 * s, 540 - s * (Y + RH / 2)));
    cam.style.transform = `translate(${tx}px,${ty}px) scale(${s})`;
    if (step.spot) Object.assign(spot.style, { left: X + 'px', top: Y + 'px', width: RW + 'px', height: RH + 'px', opacity: 1 });
    else spot.style.opacity = 0;
  };
  if (typeof step.camera !== 'string') { aim(); return; }
  const cam0 = root.querySelector('.ws-cam');
  // fill: the transforms on the element's way up are pinned where they are heading (a lit card stays scaled up) —
  // the end's clear would otherwise shrink it under the camera, and dropping the focus first makes it pulse
  if (step.fill) {
    for (const e of root.querySelectorAll(step.camera)) {
      for (let x = e; x && x !== cam0; x = x.parentElement) {
        const tr = x.getAnimations().find((an) => an.transitionProperty === 'transform');
        const kf = tr?.effect?.getKeyframes?.() || [];
        x.style.transform = kf.length ? kf[kf.length - 1].transform : getComputedStyle(x).transform;
        x.dataset.wsPinned = '';
      }
    }
  }
  const moving = [...root.querySelectorAll(step.camera)].flatMap((e) => {
    const a = [];
    for (let x = e; x && x !== cam0; x = x.parentElement) a.push(...x.getAnimations().filter((an) => an.effect?.getTiming?.().iterations !== Infinity));
    return a;
  });
  if (!moving.length) { aim(); return; }
  Promise.race([Promise.all(moving.map((an) => an.finished.catch(() => {}))), new Promise((r) => setTimeout(r, 1600))]).then(aim);
}

/** Fade out (or drop at once) and remove the slide (page side). */
export function pageHide({ instant }) {
  // a slide swapped out a moment ago (removed after 650 ms) and legacy overlays go now: none may resurface
  const drop = (h) => {
    try { h.shadowRoot?.querySelector('.ws-stage')?.dispatchEvent(new Event('ws-dispose')); } catch {}
    h.remove();
  };
  ['__ws_slide_old', '__web_test_image', '__web_test_title'].forEach((id) => document.querySelectorAll('#' + id).forEach(drop));
  const host = document.getElementById('__ws_slide');
  if (!host) return false;
  if (instant) { drop(host); return false; }
  host.style.transition = 'opacity .5s ease';
  host.style.opacity = 0;
  return true;
}

/**
 * Run a slide's script (page side). Called as `(pageScript)(opts, userFn, encode)` — an expression built by
 * showSlide, so the user function and the path encoder (assets.mjs encodeAssetPath) arrive as code. `slide`: the
 * stage, lookups in the shadow root, theme colours, step events, project files (service address), cleanup.
 * Resolves when the script is ready.
 */
export async function pageScript({ base, timeoutMs }, fn, encode) {
  const host = document.getElementById('__ws_slide');
  const root = host.shadowRoot, stage = root.querySelector('.ws-stage');
  const disposers = [];
  let disposed = false;
  const dispose = () => {
    disposed = true;
    for (const f of disposers.splice(0)) { try { f(); } catch { /* cleanup must not break the swap */ } }
  };
  const url = (p) => encode(base, p);
  const loaded = (window.__wsLoadedScripts ||= {});
  const css = getComputedStyle(root.querySelector('.ws-slide'));
  const theme = Object.fromEntries(['primary', 'accent', 'ground', 'ink'].map((k) => [k, css.getPropertyValue('--' + k).trim()]));
  const slide = {
    stage, root, theme,
    $: (sel) => root.querySelector(sel),
    $$: (sel) => [...root.querySelectorAll(sel)],
    on(event, cb) {
      if (event !== 'step') throw new Error(`slide.on: unknown event "${event}" — "step"`);
      stage.addEventListener('ws-step', (e) => cb(e.detail.index, e.detail.step));
    },
    onDispose: (f) => { if (disposed) f(); else disposers.push(f); },
    asset: url,
    import: (p) => import(url(p)),
    // bare names in modules (import 'three' inside an add-on) → project files; before the first such import
    importMap(map) {
      const imports = {};
      for (const [k, v] of Object.entries(map || {})) imports[k] = url(v);   // a trailing / stays (a prefix)
      const s = document.createElement('script');
      s.type = 'importmap'; s.textContent = JSON.stringify({ imports });
      document.head.appendChild(s);
    },
    load: (p) => (loaded[p] ||= new Promise((ok, fail) => {
      const s = document.createElement('script');
      s.src = url(p); s.onload = ok; s.onerror = () => { delete loaded[p]; fail(new Error(`cannot load ${p}`)); };
      document.head.appendChild(s);
    })),
  };
  stage.addEventListener('ws-dispose', dispose, { once: true });
  // the cleanup the script returns is kept even when it answers after the time-out (or the slide went meanwhile)
  const run = Promise.resolve().then(() => fn(slide));
  run.then((ret) => { if (typeof ret === 'function') slide.onDispose(ret); }, () => {});
  let timer;
  await Promise.race([
    run,
    new Promise((_, fail) => { timer = setTimeout(() => fail(new Error(`not ready in ${timeoutMs / 1000} s`)), timeoutMs); }),
  ]).finally(() => clearTimeout(timer));
  return true;
}

/**
 * Checks on the current screen (page side, stage pixels). Text inside pictures is not seen.
 * Tolerance on the frame edge = the slow push-in (a full-frame box legitimately grows past the edge).
 */
export function pageLint({ showSel }) {
  const host = document.getElementById('__ws_slide');
  const root = host?.shadowRoot;
  const out = { overflow: [], small: [], words: 0, longLists: [], shown: [] };
  if (!root) return out;
  const stage = root.querySelector('.ws-stage'), sr = stage.getBoundingClientRect(), k = sr.width / 1920;
  const tx = sr.width * 0.015 + 2, ty = sr.height * 0.015 + 2;
  const camIdle = getComputedStyle(root.querySelector('.ws-cam')).transform === 'none';
  const visible = (el) => !el.closest('.ws-pending:not(.on)') && getComputedStyle(el).visibility !== 'hidden';
  // the nearest element that draws a box: a background, a border or a shadow (up to the camera layer)
  const paintedBox = (el) => {
    for (let a = el; a && !a.classList.contains('ws-cam'); a = a.parentElement) {
      const cs = getComputedStyle(a);
      const bg = cs.backgroundImage !== 'none' || !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor);
      const border = ['Top', 'Right', 'Bottom', 'Left'].some((s) => parseFloat(cs[`border${s}Width`]) > 0 && cs[`border${s}Style`] !== 'none');
      if (bg || border || cs.boxShadow !== 'none') return a;
    }
    return null;
  };
  const name = (el) => {
    const cls = typeof el.className === 'string' ? el.className.split(' ').find((c) => c && !c.startsWith('ws-')) : null;
    return cls ? '.' + cls : el.tagName.toLowerCase();
  };
  // .ws-nolint — a deliberate element (a speech bubble that repeats the phrase, a figure past the edge): not checked
  const els = [...root.querySelectorAll('.ws-cam *')].filter((e) => !e.matches('.ws-spot, style') && !e.closest('.ws-nolint') && visible(e));
  // the frame's elements (logo, number, footer): content drawn under them is flagged
  const frameRects = [...root.querySelectorAll('.ws-frame .wf-logo, .ws-frame .wf-num, .ws-frame .wf-text, .ws-frame .wf-edge')]
    .map((e) => e.getBoundingClientRect()).filter((r) => r.width && r.height);
  const hits = (r) => frameRects.some((f) => r.left < f.right - 2 && r.right > f.left + 2 && r.top < f.bottom - 2 && r.bottom > f.top + 2);
  for (const el of els) {
    const r = el.getBoundingClientRect();
    const hasText = !!el.textContent.trim();
    // only text and pictures must stay in the frame; drawn shapes may bleed past the edge
    if (camIdle && r.width && (hasText || el.tagName === 'IMG')
      && (r.left < sr.left - tx || r.right > sr.right + tx || r.top < sr.top - ty || r.bottom > sr.bottom + ty)) {
      out.overflow.push(`${name(el)} is outside the frame`);
    }
    const ov = getComputedStyle(el).overflow !== 'visible';
    if (hasText && ov && el.scrollWidth > el.clientWidth + 2) out.overflow.push(`${name(el)} text does not fit (width)`);
    if (hasText && ov && el.scrollHeight > el.clientHeight + 2) out.overflow.push(`${name(el)} text does not fit (height)`);
    const own = [...el.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim());
    // text that runs out of its visible box (a card, a plate) without clipping: overflow stays visible, so the
    // scroll check above is blind to it — measure the text itself against the nearest painted ancestor
    if (own.length && camIdle && !ov) {
      const box = paintedBox(el);
      if (box) {
        const b = box.getBoundingClientRect(), tol = 3 * k;
        const spills = own.some((n) => {
          const rg = document.createRange();
          rg.selectNodeContents(n);
          const t = rg.getBoundingClientRect();
          return t.width && (t.left < b.left - tol || t.right > b.right + tol || t.top < b.top - tol || t.bottom > b.bottom + tol);
        });
        if (spills) out.overflow.push(`${name(el)} text spills out of its box`);
      }
    }
    if (own.length) {
      out.words += own.map((n) => n.textContent.trim().split(/\s+/).length).reduce((a, b) => a + b, 0);
      // effective size on the 1920-wide stage, zoom of fitted boxes included
      const fs = parseFloat(getComputedStyle(el).fontSize) * (r.height && el.offsetHeight ? r.height / k / el.offsetHeight : 1);
      if (fs < 21.5) out.small.push(`${name(el)} ${Math.round(fs)}px`);
    }
    if (/^(UL|OL)$/.test(el.tagName) && el.children.length > 6) out.longLists.push(`${name(el)}: ${el.children.length} items`);
    // text or a picture under the frame (camera at rest: a zoom brings anything under it). A backdrop, a plate or
    // a picture filling most of the slide is meant to lie under it
    if (frameRects.length && camIdle && r.width) {
      const textUnder = own.some((n) => { const rg = document.createRange(); rg.selectNodeContents(n); return hits(rg.getBoundingClientRect()); });
      const smallPic = el.tagName === 'IMG' && r.width * r.height < sr.width * sr.height * 0.5;
      if (textUnder || (smallPic && hits(r))) out.overflow.push(`${name(el)} overlaps the frame`);
    }
  }
  if (showSel) out.shown = [...root.querySelectorAll(showSel)].filter((e) => !e.closest('.ws-nolint')).map((e) => (e.innerText ?? e.textContent ?? '').trim()).filter(Boolean);
  out.overflow = [...new Set(out.overflow)];
  out.small = [...new Set(out.small)];
  return out;
}
