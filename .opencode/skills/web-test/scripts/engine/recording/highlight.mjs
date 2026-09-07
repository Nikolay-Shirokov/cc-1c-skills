// web-test recording/highlight v1.17 — Visual highlight overlay (single + auto-mode for clickElement/fillFields/selectValue).
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import {
  page, highlightMode, ensureConnected, normYo,
  setHighlightMode,
} from '../core/state.mjs';
import {
  readSubmenuScript, detectFormScript, resolveGridScript,
  findClickTargetScript, resolveFieldsScript,
} from '../../dom.mjs';

/**
 * Highlight an element on the page (visual accent for video recordings).
 * Uses overlay div for visibility (not clipped by overflow:hidden), with
 * requestAnimationFrame tracking so it follows layout shifts (async banners etc).
 * @param {string} text  Element text/label (fuzzy match, same as clickElement/fillFields)
 * @param {object} [opts]
 * @param {string} [opts.color]    Outline color (default: '#e74c3c')
 * @param {number} [opts.padding]  Extra padding around element (default: 4)
 */
export async function highlight(text, opts = {}) {
  ensureConnected();
  const { color = '#e74c3c', padding = 4, table } = opts;

  // Remove previous highlight first
  await unhighlight();

  let elId = null;

  // 0. Open submenu/popup — highest priority (submenu overlays the form,
  // so form search would match grid rows behind the popup)
  const popupItems = await page.evaluate(readSubmenuScript());
  if (Array.isArray(popupItems) && popupItems.length > 0) {
    const target = normYo(text.toLowerCase());
    let found = popupItems.find(i => normYo(i.name.toLowerCase()) === target);
    if (!found) found = popupItems.find(i => normYo(i.name.toLowerCase()).startsWith(target));
    if (!found) found = popupItems.find(i => normYo(i.name.toLowerCase()).includes(target));
    if (found) {
      // 1C duplicates IDs in clouds — getElementById returns the hidden copy.
      // Use elementFromPoint to find the visible element and get its actual rect.
      await page.evaluate(({ x, y, color, padding }) => {
        const el = document.elementFromPoint(x, y);
        if (!el) return;
        const block = el.closest('.submenuBlock') || el.closest('a.press') || el;
        const r = block.getBoundingClientRect();
        let div = document.getElementById('__web_test_highlight');
        if (!div) {
          div = document.createElement('div');
          div.id = '__web_test_highlight';
          document.body.appendChild(div);
        }
        div.style.cssText = [
          'position:fixed', 'pointer-events:none', 'z-index:999998',
          `top:${r.y - padding}px`, `left:${r.x - padding}px`,
          `width:${r.width + padding * 2}px`, `height:${r.height + padding * 2}px`,
          `outline:3px solid ${color}`, 'border-radius:4px',
          `box-shadow:0 0 16px ${color}80`,
        ].join(';');
      }, { x: found.x, y: found.y, color, padding });
      return; // overlay placed, done
    }
  }

  // 1. Visible commands on the function panel (cmd_XXX_txt elements)
  // Must be checked BEFORE form search: when the section content panel
  // is showing, the form behind it is hidden but detectFormScript still
  // finds it, and form buttons match before commands.
  if (!elId) {
    elId = await page.evaluate(`(() => {
      const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
      const target = ${JSON.stringify(normYo(text.toLowerCase()))};
      const cmds = [...document.querySelectorAll('[id^="cmd_"][id$="_txt"]')].filter(e => e.offsetWidth > 0);
      if (cmds.length === 0) return null;
      let el = cmds.find(e => norm(e.innerText).toLowerCase() === target);
      if (!el) el = cmds.find(e => norm(e.innerText).toLowerCase().startsWith(target));
      if (!el) el = cmds.find(e => norm(e.innerText).toLowerCase().includes(target));
      return el ? el.id : null;
    })()`);
  }

  // 1b. Command group headers on the function panel (eAccentColor labels).
  //     Match header text, then highlight the header + commands below it
  //     until the next spacer/header/end.
  if (!elId) {
    const groupDone = await page.evaluate(({ target, color, padding }) => {
      const container = document.querySelector('#funcPanel_container');
      if (!container) return false;
      const norm = s => (s?.trim().replace(/\u00a0/g, ' ') || '').replace(/ё/gi, 'е').toLowerCase();
      const headers = [...container.querySelectorAll('.eAccentColor')].filter(e => e.offsetWidth > 0);
      if (!headers.length) return false;

      let headerEl = headers.find(h => norm(h.textContent) === target);
      if (!headerEl) headerEl = headers.find(h => norm(h.textContent).startsWith(target));
      if (!headerEl) headerEl = headers.find(h => norm(h.textContent).includes(target));
      if (!headerEl) return false;

      // Collect header + following cmd siblings until next spacer/header
      const parent = headerEl.parentElement;
      const children = [...parent.children];
      const startIdx = children.indexOf(headerEl);
      const groupEls = [headerEl];
      for (let i = startIdx + 1; i < children.length; i++) {
        const el = children[i];
        if (el.classList.contains('eAccentColor')) break;
        if (!el.id && !el.classList.contains('functionItem') && el.getBoundingClientRect().width < 10) break;
        groupEls.push(el);
      }

      // Bounding box
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (const el of groupEls) {
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        minX = Math.min(minX, r.left);  minY = Math.min(minY, r.top);
        maxX = Math.max(maxX, r.right); maxY = Math.max(maxY, r.bottom);
      }
      if (minX === Infinity) return false;

      let div = document.getElementById('__web_test_highlight');
      if (!div) { div = document.createElement('div'); div.id = '__web_test_highlight'; document.body.appendChild(div); }
      div.style.cssText = [
        'position:fixed', 'pointer-events:none', 'z-index:999998',
        `top:${minY - padding}px`, `left:${minX - padding}px`,
        `width:${maxX - minX + padding * 2}px`, `height:${maxY - minY + padding * 2}px`,
        `outline:3px solid ${color}`, 'border-radius:4px',
        `box-shadow:0 0 16px ${color}80`,
      ].join(';');
      return true;
    }, { target: normYo(text.toLowerCase()), color, padding });
    if (groupDone) return;
  }

  // 2. Form groups/panels — checked BEFORE buttons/fields because group names
  //    often collide with command bar buttons (e.g. "БизнесПроцессы" is both a
  //    panel and a command bar element). Includes _container and _div elements
  //    but skips logicGroupContainer (Representation=None, height=0).
  if (!elId) {
    const formNum = await page.evaluate(detectFormScript());
    if (formNum !== null) {
      elId = await page.evaluate(`(() => {
        const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
        const target = ${JSON.stringify(normYo(text.toLowerCase()))};
        const p = 'form' + ${formNum} + '_';
        // Group containers: _container or _div, but skip logicGroupContainer (invisible groups)
        const groups = [...document.querySelectorAll('[id^="' + p + '"][id$="_container"], [id^="' + p + '"][id$="_div"]')]
          .filter(el => el.offsetWidth > 0 && el.offsetHeight > 0 && !el.classList.contains('logicGroupContainer'));
        const items = groups.map(el => {
          const idName = el.id.replace(p, '').replace(/_(container|div)$/, '');
          const titleEl = document.getElementById(p + idName + '#title_text')
            || document.getElementById(p + idName + '_title_text');
          const label = norm(titleEl?.innerText || '').toLowerCase();
          const name = norm(idName).toLowerCase();
          const big = el.offsetWidth >= 100 && el.offsetHeight >= 50;
          return { id: el.id, name, label, big };
        });
        let found = items.find(i => i.label === target);
        if (!found) found = items.find(i => i.name === target);
        // Fuzzy match: only large groups (min 100x50) to avoid matching command bars
        if (!found) found = items.filter(i => i.big).find(i => i.label.startsWith(target) || i.name.startsWith(target));
        if (!found && target.length >= 4) found = items.filter(i => i.big).find(i => i.label.includes(target) || i.name.includes(target));
        return found ? found.id : null;
      })()`);
    }
  }

  // 3. Form-scoped search (buttons, links, fields, grid rows)
  if (!elId) {
    const formNum = await page.evaluate(detectFormScript());
    if (formNum !== null) {
      // 3a. Try button/link/tab/gridRow via findClickTargetScript
      let gridSelector;
      if (table) {
        const resolved = await page.evaluate(resolveGridScript(formNum, table));
        if (!resolved.error) gridSelector = resolved.gridSelector;
      }
      const target = await page.evaluate(findClickTargetScript(formNum, text, table ? { tableName: table, gridSelector } : undefined));
      if (target && !target.error) {
        if (target.id) {
          elId = target.id;
        } else if (target.x && target.y) {
          // Grid row — find the gridLine element and tag it
          elId = await page.evaluate(`(() => {
            const p = ${JSON.stringify(`form${formNum}_`)};
            const grid = document.querySelector('[id^="' + p + '"].grid');
            if (!grid) return null;
            const body = grid.querySelector('.gridBody');
            if (!body) return null;
            const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
            const target = ${JSON.stringify(normYo(text.toLowerCase()))};
            for (const line of body.querySelectorAll('.gridLine')) {
              const cells = [...line.querySelectorAll('.gridBoxText')].filter(b => b.offsetWidth > 0);
              const rowText = cells.map(b => b.innerText?.trim() || '').join(' ').toLowerCase().replace(/ё/gi, 'е');
              if (rowText.includes(target)) {
                if (!line.id) line.id = '__wt_hl_tmp';
                return line.id;
              }
            }
            return null;
          })()`);
        }
      }

      // 3b. If not found as button — try as field via resolveFieldsScript
      if (!elId) {
        const dummyFields = { [text]: '' };
        const resolved = await page.evaluate(resolveFieldsScript(formNum, dummyFields));
        if (resolved?.length > 0 && !resolved[0].error && resolved[0].inputId) {
          elId = resolved[0].inputId;
        }
      }
    }
  }

  // 4. Fallback: sections (sidebar navigation)
  if (!elId) {
    elId = await page.evaluate(`(() => {
      const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
      const target = ${JSON.stringify(normYo(text.toLowerCase()))};
      const secs = [...document.querySelectorAll('[id^="themesCell_theme_"]')];
      let el = secs.find(e => norm(e.innerText).toLowerCase() === target);
      if (!el) el = secs.find(e => norm(e.innerText).toLowerCase().startsWith(target));
      if (!el) el = secs.find(e => norm(e.innerText).toLowerCase().includes(target));
      return el ? el.id : null;
    })()`);
  }

  if (!elId) {
    // Collect available elements to help the caller fix the name
    const available = await page.evaluate(`(() => {
      const norm = s => (s?.trim().replace(/\\u00a0/g, ' ') || '').replace(/ё/gi, 'е');
      const result = {};
      // Commands
      const cmds = [...document.querySelectorAll('[id^="cmd_"][id$="_txt"]')].filter(e => e.offsetWidth > 0).map(e => norm(e.innerText));
      if (cmds.length) result.commands = cmds;
      // Command group headers
      const fp = document.querySelector('#funcPanel_container');
      if (fp) {
        const gh = [...fp.querySelectorAll('.eAccentColor')].filter(e => e.offsetWidth > 0).map(e => norm(e.textContent));
        if (gh.length) result.commandGroups = gh;
      }
      // Sections
      const secs = [...document.querySelectorAll('[id^="themesCell_theme_"]')].map(e => norm(e.innerText)).filter(Boolean);
      if (secs.length) result.sections = secs;
      // Form elements
      ${(() => {
        // Detect form inline to avoid extra evaluate round-trip
        return `
        const forms = {};
        document.querySelectorAll('[id^="form"]').forEach(el => {
          const m = el.id.match(/^form(\\d+)_/);
          if (m) forms[m[1]] = (forms[m[1]] || 0) + 1;
        });
        let formNum = null, maxCount = 0;
        for (const [n, c] of Object.entries(forms)) {
          if (parseInt(n) > 0 && c > maxCount) { maxCount = c; formNum = n; }
        }
        if (formNum !== null) {
          const p = 'form' + formNum + '_';
          // Groups (_container or _div, skip logicGroupContainer, min 100x50)
          const groups = [...document.querySelectorAll('[id^="' + p + '"][id$="_container"], [id^="' + p + '"][id$="_div"]')]
            .filter(el => el.offsetWidth >= 100 && el.offsetHeight >= 50 && !el.classList.contains('logicGroupContainer'))
            .map(el => {
              const idName = el.id.replace(p, '').replace(/_(container|div)$/, '');
              const titleEl = document.getElementById(p + idName + '#title_text') || document.getElementById(p + idName + '_title_text');
              return norm(titleEl?.innerText || '') || idName;
            }).filter(Boolean);
          if (groups.length) result.groups = groups;
          // Buttons/links
          const btns = [...document.querySelectorAll('[id^="' + p + '"].btnText, [id^="' + p + '"] .btnText, [id^="' + p + '"].hplnk')]
            .filter(el => el.offsetWidth > 0).map(el => norm(el.innerText)).filter(Boolean);
          if (btns.length) result.buttons = [...new Set(btns)];
        }`;
      })()}
      return result;
    })()`);
    const parts = [];
    for (const [cat, items] of Object.entries(available)) {
      parts.push(`  ${cat}: ${items.join(', ')}`);
    }
    const hint = parts.length ? `\nAvailable:\n${parts.join('\n')}` : '';
    throw new Error(`highlight: "${text}" not found${hint}`);
  }

  // Overlay div + rAF tracking loop (not clipped by overflow:hidden, follows layout shifts)
  await page.evaluate(({ elId, color, padding }) => {
    const target = document.getElementById(elId);
    if (!target) return;
    let div = document.getElementById('__web_test_highlight');
    if (!div) {
      div = document.createElement('div');
      div.id = '__web_test_highlight';
      document.body.appendChild(div);
    }
    function sync() {
      const r = target.getBoundingClientRect();
      div.style.cssText = [
        'position:fixed', 'pointer-events:none', 'z-index:999998',
        `top:${r.y - padding}px`, `left:${r.x - padding}px`,
        `width:${r.width + padding * 2}px`, `height:${r.height + padding * 2}px`,
        `outline:3px solid ${color}`, 'border-radius:4px',
        `box-shadow:0 0 16px ${color}80`,
      ].join(';');
    }
    sync();
    // Track position changes via rAF
    function tick() {
      if (!document.getElementById('__web_test_highlight')) return; // stopped
      sync();
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }, { elId, color, padding });
}

/** Remove the highlight overlay. */
export async function unhighlight() {
  ensureConnected();
  await page.evaluate(() => {
    const el = document.getElementById('__web_test_highlight');
    if (el) el.remove(); // also stops rAF loop (id check)
    // Clean up temp ID from grid rows
    const tmp = document.getElementById('__wt_hl_tmp');
    if (tmp) tmp.removeAttribute('id');
  });
}

/**
 * Toggle auto-highlight mode. When enabled, clickElement/fillFields/selectValue
 * automatically highlight the target element before acting.
 * @param {boolean} on  true to enable, false to disable
 */
export function setHighlight(on) {
  setHighlightMode(!!on);
}

/** @returns {boolean} Whether auto-highlight mode is active. */
export function isHighlightMode() {
  return highlightMode;
}
