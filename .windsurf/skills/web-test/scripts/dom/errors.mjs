// web-test dom/errors v1.0 — error/diagnostic detection (balloon, messages, modal, stateWindow)
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

/**
 * Check for validation errors / diagnostics after an action.
 * Detects three patterns:
 *   1. Inline balloon tooltip (div.balloon with .balloonMessage)
 *   2. Messages panel (div.messages with msg0, msg1... grid rows)
 *   3. Modal error dialog (high-numbered form with pressDefault + static texts)
 * Returns { balloon, messages[], modal } or null if no errors.
 */
export function checkErrorsScript() {
  return `(() => {
    const result = {};

    // 1. Inline balloon tooltip
    const balloon = document.querySelector('.balloon');
    if (balloon && balloon.offsetWidth > 0) {
      const msg = balloon.querySelector('.balloonMessage');
      const title = balloon.querySelector('.balloonTitle');
      if (msg) {
        result.balloon = {
          title: title?.innerText?.trim() || 'Ошибка',
          message: msg.innerText?.trim() || ''
        };
        // Count navigation arrows to indicate total errors
        const fwd = balloon.querySelector('.balloonJumpFwd');
        const back = balloon.querySelector('.balloonJumpBack');
        const fwdDisabled = fwd?.classList.contains('disabled');
        const backDisabled = back?.classList.contains('disabled');
        if (fwd && !fwdDisabled) result.balloon.hasNext = true;
        if (back && !backDisabled) result.balloon.hasPrev = true;
      }
    }

    // 2. Messages panel (div.messages — pick visible one, multiple may exist across tabs)
    const msgPanels = [...document.querySelectorAll('.messages')].filter(el => el.offsetWidth > 0);
    for (const msgPanel of msgPanels) {
      const msgs = [];
      msgPanel.querySelectorAll('[id^="msg"]').forEach(line => {
        if (line.offsetWidth === 0) return;
        const textEl = line.querySelector('.gridBoxText');
        const text = (textEl || line).innerText?.trim();
        if (text) msgs.push(text);
      });
      if (msgs.length > 0) { result.messages = msgs; break; }
    }

    // 3+4. Modal dialogs: confirmation (multiple buttons) or error (single pressDefault)
    // Uses form container ancestry to group buttons — pressButton elements often lack form-prefixed IDs
    // Note: 1C shows some modals WITHOUT #modalSurface (e.g. "Не удалось записать" uses ps*win floating window)
    // so we always scan for small forms with button patterns, regardless of modalSurface state
    const formButtons = {};
    [...document.querySelectorAll('a.press.pressButton')].forEach(btn => {
      if (btn.offsetWidth === 0) return;
      const container = btn.closest('[id$="_container"]');
      const m = container?.id?.match(/^form(\\d+)_/);
      if (!m) return;
      const fn = m[1];
      if (!formButtons[fn]) formButtons[fn] = [];
      formButtons[fn].push(btn);
    });

    for (const [fn, buttons] of Object.entries(formButtons)) {
      const p = 'form' + fn + '_';
      const elCount = document.querySelectorAll('[id^="' + p + '"]').length;
      if (elCount > 100) continue; // Skip large content forms
      if (buttons.length > 1) {
        // Confirmation dialog (multiple buttons: Да/Нет, OK/Отмена, etc.)
        // Must have a Message element — real 1C confirmations always have form{N}_Message.
        // Without it, this is just a regular form with multiple buttons (e.g. EPF form).
        const msgEl = document.getElementById(p + 'Message');
        if (!msgEl || msgEl.offsetWidth === 0) continue;
        const message = msgEl.innerText?.trim() || '';
        const btnNames = buttons.map(el => {
          const b = { name: el.innerText?.trim() || '' };
          if (el.classList.contains('pressDefault')) b.default = true;
          return b;
        }).filter(b => b.name);
        result.confirmation = { message, buttons: btnNames.map(b => b.name), formNum: parseInt(fn) };
        break;
      }
    }

    // Single-button modal: error dialog with pressDefault + staticText
    // Skip forms with input fields — those are data entry forms (e.g. register record),
    // not error dialogs. Real error modals only have staticText + buttons.
    if (!result.confirmation) {
      for (const [fn, buttons] of Object.entries(formButtons)) {
        const p = 'form' + fn + '_';
        const elCount = document.querySelectorAll('[id^="' + p + '"]').length;
        if (elCount > 100) continue;
        if (buttons.length !== 1 || !buttons[0].classList.contains('pressDefault')) continue;
        const hasInputs = document.querySelectorAll('input.editInput[id^="' + p + '"], textarea[id^="' + p + '"]').length > 0;
        if (hasInputs) continue;
        const texts = [...document.querySelectorAll('[id^="' + p + '"].staticText')]
          .filter(el => el.offsetWidth > 0)
          .map(el => el.innerText?.trim())
          .filter(Boolean);
        if (texts.length > 0) {
          result.modal = { message: texts.join(' '), formNum: parseInt(fn), button: buttons[0].innerText?.trim() || '' };
          // Check if OpenReport link is available (platform exceptions have visible link text)
          const reportLink = document.getElementById(p + 'OpenReport#text');
          if (reportLink && reportLink.offsetWidth > 2 && reportLink.textContent.trim()) {
            result.modal.hasReport = true;
          }
          // Grab AdditionalInfo/ServerText if filled (may contain extra error details)
          const addInfo = document.getElementById(p + 'AdditionalInfo');
          if (addInfo && addInfo.textContent && addInfo.textContent.trim()) result.modal.additionalInfo = addInfo.textContent.trim();
          const srvText = document.getElementById(p + 'ServerText');
          if (srvText && srvText.textContent && srvText.textContent.trim()) result.modal.serverText = srvText.textContent.trim();
          break;
        }
      }
    }

    // 5. SpreadsheetDocument state window (info bar inside moxelContainer)
    // Shows messages like "Не установлено значение параметра X" or "Отчет не сформирован"
    const stateWins = [...document.querySelectorAll('.stateWindowSupportSurface')].filter(el => el.offsetWidth > 0);
    if (stateWins.length) {
      const texts = stateWins.map(el => el.innerText?.trim()).filter(Boolean);
      if (texts.length) result.stateText = texts;
    }

    return (result.balloon || result.messages || result.modal || result.confirmation || result.stateText) ? result : null;
  })()`;
}
