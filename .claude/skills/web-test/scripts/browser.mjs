// web-test browser v1.19 — engine facade: re-exports the public API from engine/*
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * Public API of the web-test engine. Pure re-export facade — no logic here.
 * Implementation lives in `./engine/*`. External callers (run.mjs, exec scripts,
 * tests) import from this file; engine internals import each other directly.
 */

// ── core ──────────────────────────────────────────────────────────────────
export {
  isConnected, getPage, ensureConnected, setPreserveClipboard,
} from './engine/core/state.mjs';
export {
  pasteText, saveClipboard, restoreClipboard,
} from './engine/core/clipboard.mjs';
export { getFormState } from './engine/forms/state.mjs';
export { fetchErrorStack } from './engine/core/errors.mjs';
export { clickElement } from './engine/core/click.mjs';

// ── session ───────────────────────────────────────────────────────────────
export {
  connect, disconnect, attach, detach, getSession,
  createContext, setActiveContext, listContexts, getActiveContext,
  hasContext, closeContext,
  // Unresponsive-context handling (test runner). abortContext is the sanctioned way to
  // mutate the registry from outside — the `contexts` Map itself stays private.
  abortContext, probeContext, getContextDiagnostics,
} from './engine/core/session.mjs';

// ── navigation ────────────────────────────────────────────────────────────
export {
  getPageState, getSections, navigateSection, getCommands,
  openCommand, switchTab, openFile, navigateLink,
} from './engine/nav/navigation.mjs';

// ── forms ─────────────────────────────────────────────────────────────────
export { selectValue } from './engine/forms/select-value.mjs';
export { fillFields, fillField } from './engine/forms/fill.mjs';
export { closeForm } from './engine/forms/close.mjs';

// ── tables ────────────────────────────────────────────────────────────────
export { readTable, deleteTableRow } from './engine/table/grid.mjs';
export { readSpreadsheet } from './engine/spreadsheet/spreadsheet.mjs';
export { fillTableRow } from './engine/table/row-fill.mjs';
export { filterList, unfilterList } from './engine/table/filter.mjs';

// ── recording / overlays ──────────────────────────────────────────────────
export {
  screenshot, wait, isRecording, startRecording, stopRecording,
} from './engine/recording/capture.mjs';
export {
  showCaption, hideCaption, getCaptions,
  showTitleSlide, hideTitleSlide,
  showImage, hideImage,
} from './engine/recording/captions.mjs';
export {
  highlight, unhighlight, setHighlight, isHighlightMode,
} from './engine/recording/highlight.mjs';
export { addNarration } from './engine/recording/narration.mjs';
