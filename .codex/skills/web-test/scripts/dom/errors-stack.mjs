// web-test dom/errors-stack v1.0 — DOM scripts for fetching error stack via OpenReport link.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Path-1 flow for platform exceptions: click "Сформировать отчет об ошибке" link,
// open detailed error dialog, read textarea, close cleanup dialogs.

/** Find OpenReport link coordinates on the error modal for given formNum. */
export function getOpenReportCoordsScript(formNum) {
  return `(() => {
    const el = document.getElementById('form${formNum}_OpenReport#text');
    if (!el || el.offsetWidth <= 2) return null;
    const rect = el.getBoundingClientRect();
    return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  })()`;
}

/** Check whether the "подробный текст ошибки" link is visible (signals report dialog ready). */
export function isErrorDetailLinkVisibleScript() {
  return `(() => {
    const links = document.querySelectorAll('a, [class*="hyper"], span');
    for (const el of links) {
      if (el.offsetWidth > 0 && el.textContent.includes('подробный текст ошибки')) return true;
    }
    return false;
  })()`;
}

/** Read the largest visible non-empty textarea — contains the detailed error stack. */
export function readLargestVisibleTextareaScript() {
  return `(() => {
    let best = null;
    document.querySelectorAll('textarea').forEach(ta => {
      if (ta.offsetWidth > 0 && ta.value.length > 0) {
        if (!best || ta.value.length > best.value.length) best = ta;
      }
    });
    return best?.value || null;
  })()`;
}

/** Click the OK button in the topmost cloud window (closes "Подробный текст ошибки"). */
export function clickTopCloudOkButtonScript() {
  return `(() => {
    const psWins = [...document.querySelectorAll('[id^="ps"][id$="win"]')]
      .filter(w => w.offsetWidth > 0)
      .sort((a, b) => parseInt(b.style?.zIndex || '0') - parseInt(a.style?.zIndex || '0'));
    for (const w of psWins) {
      const ok = w.querySelector('button.webBtn, .pressDefault');
      if (ok && ok.textContent.trim() === 'OK') { ok.click(); return true; }
    }
    return false;
  })()`;
}

/** Click the × CloseButton in the topmost visible cloud window (closes "Отчет об ошибке"). */
export function clickReportCloseButtonScript() {
  return `(() => {
    const psWins = [...document.querySelectorAll('[id^="ps"][id$="win"]')]
      .filter(w => w.offsetWidth > 0);
    for (const w of psWins) {
      const closeBtn = w.querySelector('[id$="_cmd_CloseButton"]');
      if (closeBtn && closeBtn.offsetWidth > 0) { closeBtn.click(); break; }
    }
  })()`;
}
