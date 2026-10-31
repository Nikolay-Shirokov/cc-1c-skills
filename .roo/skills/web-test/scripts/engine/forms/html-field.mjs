// web-test forms/html-field v1.0 — entry into an HTML document field's frame
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { page, ensureConnected } from '../core/state.mjs';
import { resolveHtmlFieldScript } from '../../dom.mjs';

/**
 * Playwright FrameLocator for an HTML document field of the active form.
 * Inside the frame the page is the application's own HTML — work with it in plain Playwright.
 *
 * @param {string} [name] field name or title; may be omitted when the form shows one HTML field
 * @returns {Promise<import('playwright').FrameLocator>}
 */
export async function getHtmlFrame(name) {
  ensureConnected();
  const r = await page.evaluate(resolveHtmlFieldScript(name));
  if (r.error) throw new Error(r.message);
  return page.locator(`[id="form${r.formNum}_${r.name}"].htmlDocContainer > iframe`).contentFrame();
}
