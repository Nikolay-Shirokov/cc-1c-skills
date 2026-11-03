// web-test recording/slides/protocol v1.0 — step-slide protocol: base CSS + theme, page-side mount/step/lint.
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

// Theme: base colours (primary, accent, ground, ink; optional line, mark, onAccent, font); the rest derived.
// Structure (headers, links, arrows, rules, tints) is shades of primary; the accent marks what is being
// said now (focus) plus title rules, numbers and callouts.
export const DEFAULT_THEME = { primary: '#16213e', accent: '#f0a202', ground: '#f4f6fa', ink: '#1a1a2e' };

export const BASE_CSS = `
.ws-slide{
  --primary:${DEFAULT_THEME.primary}; --accent:${DEFAULT_THEME.accent}; --ground:${DEFAULT_THEME.ground}; --ink:${DEFAULT_THEME.ink};
  --mark:var(--accent); --on-accent:var(--ink); --font:'Segoe UI',Arial,sans-serif;
  --line:color-mix(in oklab, var(--primary), #fff 45%);   /* structure: links, arrows, card rules, list markers */
  --primary-hi:color-mix(in oklab, var(--primary), #fff 18%);
  --primary-dk:color-mix(in oklab, var(--primary), #000 35%);
  --ink2:color-mix(in oklab, var(--ink) 85%, var(--ground));
  --muted:color-mix(in oklab, var(--ink) 55%, var(--ground));
  --soft:color-mix(in oklab, var(--primary) 7%, #fff);   /* quiet tint for item boxes and number badges */
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
.ws-links path.ws-t{transition:stroke-dashoffset .7s cubic-bezier(.4,0,.2,1),opacity .4s ease}
.ws-links path.ws-pending:not(.on){stroke-dashoffset:var(--len)}
.ws-links path.on{stroke-dashoffset:0}
.ws-links path.ws-focus{animation:none;stroke:var(--accent)}
.ws-links path.ws-t{transition:stroke-dashoffset .7s cubic-bezier(.4,0,.2,1),opacity .4s ease,stroke .5s ease}
.ws-static, .ws-static *{transition:none !important;animation:none !important}
`;

/** Theme object → CSS custom properties (camelCase keys → --kebab-case). */
export function themeVars(theme) {
  const out = {};
  for (const [k, v] of Object.entries(theme || {})) {
    if (v == null || v === '') continue;
    out[`--${k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())}`] = String(v);
  }
  return out;
}

// ── page side ─────────────────────────────────────────────────────────────

/**
 * Mount a slide (page side). Order matters: layout first (fit, links) on untransformed elements,
 * then pending states without transitions, then .ws-t — so nothing animates from the measuring state.
 */
export function pageMount({ html, css, bg, vars, pushSec, animated, instant, staticMode, hostId }) {
  const old = document.getElementById('__ws_slide');
  if (old) old.id = '__ws_slide_old';
  const host = document.createElement('div');
  host.id = '__ws_slide';
  if (hostId) host.dataset.kind = hostId;
  host.style.cssText = 'position:fixed;inset:0;z-index:999999;pointer-events:none;'
    + (instant ? 'opacity:1' : 'opacity:0;transition:opacity .5s ease');
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `<style>${css}</style><div class="ws-slide${staticMode ? ' ws-static' : ''}"><div class="ws-stage">`
    + `<div class="ws-push"><div class="ws-cam">${html}<div class="ws-spot"></div></div></div></div></div>`;
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
      const a = Math.atan2(ty - cy, tx - cx), sx = cx + R * Math.cos(a), sy = cy + R * Math.sin(a);
      const len = Math.hypot(tx - sx, ty - sy);
      p.setAttribute('d', `M${sx.toFixed(1)} ${sy.toFixed(1)} L${tx.toFixed(1)} ${ty.toFixed(1)}`);
      p.style.strokeDasharray = len.toFixed(1);
      p.style.setProperty('--len', len.toFixed(1));
    });
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
  // whatever was on screen goes away once the new slide has faded in (legacy overlays too)
  setTimeout(() => ['__ws_slide_old', '__web_test_image', '__web_test_title'].forEach((id) => document.getElementById(id)?.remove()),
    instant ? 0 : 650);
}

/** Apply one step (page side). */
export function pageStep({ step, maxZoom }) {
  const root = document.getElementById('__ws_slide')?.shadowRoot;
  if (!root) return;
  const q = (sel) => (sel ? [...root.querySelectorAll(sel)] : []);
  if (step.clear) root.querySelectorAll('.ws-focus, .ws-dim').forEach((e) => e.classList.remove('ws-focus', 'ws-dim'));
  q(step.undim).forEach((e) => e.classList.remove('ws-dim'));
  q(step.hide).forEach((e) => { e.style.setProperty('--si', 0); e.classList.remove('on', 'ws-focus'); });
  q(step.show).forEach((e, i) => { e.style.setProperty('--si', i); e.classList.add('on'); });
  q(step.dim).forEach((e) => e.classList.add('ws-dim'));
  if (step.focus !== undefined) {
    root.querySelectorAll('.ws-focus').forEach((e) => e.classList.remove('ws-focus'));
    q(step.focus).forEach((e, i) => { e.style.setProperty('--fi', i); e.classList.remove('ws-dim'); e.classList.add('ws-focus'); });
  }
  if (step.camera !== undefined) {
    const cam = root.querySelector('.ws-cam'), spot = root.querySelector('.ws-spot');
    let rect = step.camera;
    if (typeof rect === 'string') {
      // element box in stage coordinates, undoing the stage scale and the current camera
      const el = root.querySelector(rect);
      if (!el) return;
      const st = root.querySelector('.ws-stage').getBoundingClientRect();
      const k = st.width / 1920, m = new DOMMatrix(getComputedStyle(cam).transform);
      const r = el.getBoundingClientRect();
      rect = [((r.left - st.left) / k - m.e) / m.a, ((r.top - st.top) / k - m.f) / m.a, r.width / k / m.a, r.height / k / m.a];
    }
    if (!rect) { cam.style.transform = 'none'; spot.style.opacity = 0; return; }
    const pad = 14, [X, Y, RW, RH] = [rect[0] - pad, rect[1] - pad, rect[2] + 2 * pad, rect[3] + 2 * pad];
    const s = Math.max(1, Math.min((1920 * 0.84) / RW, (1080 * 0.78) / RH, maxZoom));
    const tx = Math.min(0, Math.max(1920 - 1920 * s, 960 - s * (X + RW / 2)));
    const ty = Math.min(0, Math.max(1080 - 1080 * s, 540 - s * (Y + RH / 2)));
    cam.style.transform = `translate(${tx}px,${ty}px) scale(${s})`;
    if (step.spot) Object.assign(spot.style, { left: X + 'px', top: Y + 'px', width: RW + 'px', height: RH + 'px', opacity: 1 });
    else spot.style.opacity = 0;
  }
}

/** Fade out (or drop at once) and remove the slide (page side). */
export function pageHide({ instant }) {
  const host = document.getElementById('__ws_slide');
  if (!host) return false;
  if (instant) { host.remove(); return false; }
  host.style.transition = 'opacity .5s ease';
  host.style.opacity = 0;
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
  const name = (el) => {
    const cls = typeof el.className === 'string' ? el.className.split(' ').find((c) => c && !c.startsWith('ws-')) : null;
    return cls ? '.' + cls : el.tagName.toLowerCase();
  };
  const els = [...root.querySelectorAll('.ws-cam *')].filter((e) => !e.matches('.ws-spot, style') && visible(e));
  for (const el of els) {
    const r = el.getBoundingClientRect();
    if (camIdle && r.width && (r.left < sr.left - tx || r.right > sr.right + tx || r.top < sr.top - ty || r.bottom > sr.bottom + ty)) {
      out.overflow.push(`${name(el)} is outside the frame`);
    }
    const hasText = !!el.textContent.trim();
    const ov = getComputedStyle(el).overflow !== 'visible';
    if (hasText && ov && el.scrollWidth > el.clientWidth + 2) out.overflow.push(`${name(el)} text does not fit (width)`);
    if (hasText && ov && el.scrollHeight > el.clientHeight + 2) out.overflow.push(`${name(el)} text does not fit (height)`);
    const own = [...el.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim());
    if (own.length) {
      out.words += own.map((n) => n.textContent.trim().split(/\s+/).length).reduce((a, b) => a + b, 0);
      // effective size on the 1920-wide stage, zoom of fitted boxes included
      const fs = parseFloat(getComputedStyle(el).fontSize) * (r.height && el.offsetHeight ? r.height / k / el.offsetHeight : 1);
      if (fs < 21.5) out.small.push(`${name(el)} ${Math.round(fs)}px`);
    }
    if (/^(UL|OL)$/.test(el.tagName) && el.children.length > 6) out.longLists.push(`${name(el)}: ${el.children.length} items`);
  }
  if (showSel) out.shown = [...root.querySelectorAll(showSel)].map((e) => (e.innerText ?? e.textContent ?? '').trim()).filter(Boolean);
  out.overflow = [...new Set(out.overflow)];
  out.small = [...new Set(out.small)];
  return out;
}
