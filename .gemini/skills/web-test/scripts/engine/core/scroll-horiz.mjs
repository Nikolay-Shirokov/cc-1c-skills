// web-test core/scroll-horiz v1.0 — horizontal scroll loop helper for grids and spreadsheets.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// 1С scrolls horizontally by shifting absolute X coordinates of cells (not via
// scrollLeft). The only reliable way to drive this from outside is to press
// ArrowRight / ArrowLeft on a focused cell. Both SpreadsheetDocument and form
// grids share this mechanic, so the loop body is identical: press an arrow,
// wait, check visibility, bail when the cell stops moving (lost focus / hit edge).
//
// Callers handle their own focus setup (clicking a visible cell to put keyboard
// focus on the grid/spreadsheet), direction selection, and visibility queries.

/**
 * Press {direction} key in a loop until the target cell is fully visible or
 * progress stalls.
 *
 * @param {object} opts
 * @param {import('playwright').Page} opts.page
 * @param {'ArrowRight'|'ArrowLeft'} opts.direction
 * @param {() => Promise<boolean>} opts.isFullyVisible — true when target inside viewport
 * @param {() => Promise<number|null>} opts.getCenterX — current target center X (page coords); null if cell vanished
 * @param {number} [opts.maxPresses=100]
 * @param {number} [opts.staleMax=5] — bail when center hasn't moved this many presses in a row
 * @param {number} [opts.delayMs=50] — wait after each key press
 * @param {number} [opts.finalDelayMs=200] — wait after the loop completes
 */
export async function scrollHorizontallyByKey({
  page, direction,
  isFullyVisible, getCenterX,
  maxPresses = 100, staleMax = 5,
  delayMs = 50, finalDelayMs = 200,
}) {
  let prevCx = await getCenterX();
  if (prevCx == null) return;
  let stale = 0;
  for (let i = 0; i < maxPresses; i++) {
    await page.keyboard.press(direction);
    await page.waitForTimeout(delayMs);
    if (await isFullyVisible()) break;
    const cx = await getCenterX();
    if (cx == null) break;
    if (Math.abs(cx - prevCx) >= 1) stale = 0;
    else { stale++; if (stale >= staleMax) break; }
    prevCx = cx;
  }
  await page.waitForTimeout(finalDelayMs);
}
