// web-test dom v1.20 — facade re-exporting injectable DOM scripts from dom/
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * Facade: re-exports DOM selector & semantic mapping script generators.
 * Внутренности живут в dom/*. Публичный набор имён неизменен.
 *
 * All functions return JavaScript strings for page.evaluate().
 * They produce clean semantic structures — no DOM IDs or CSS classes leak out.
 * Only non-default property values are included to minimize response size.
 */

export {
  detectFormScript,
  closeCrossScript,
  readFormScript,
  findClickTargetScript,
  findFieldButtonScript,
  resolveFieldsScript,
  detectNewFormScript,
  findSearchInputScript,
  findNamedButtonScript,
  findCompareTypeRadioScript,
  isFormVisibleScript,
  findPatternInputIdScript,
  isTypeDialogScript,
  isNotInListCloudVisibleScript,
  clickShowAllInNotInListCloudScript,
  findChildFormByButtonScript,
  readTypeDialogVisibleRowsScript,
} from './dom/forms.mjs';

export {
  findFirstGridCellCoordsScript,
  findColumnFirstCellCoordsScript,
  readFieldSelectorInfoScript,
  pickFieldInSelectorDropdownScript,
  readFilterDialogInfoScript,
  findFilterBadgeCloseScript,
  findFirstFilterBadgeCloseScript,
} from './dom/filter.mjs';

export {
  isInputFocusedScript,
  isInputFocusedInGridScript,
  findOpenPopupScript,
} from './dom/edit-state.mjs';

export {
  readEddScript,
  isEddVisibleScript,
  clickEddItemViaDispatchScript,
  clickShowAllInEddScript,
} from './dom/edd.mjs';

export { getFormStateScript } from './dom/form-state.mjs';

export {
  resolveGridScript,
  readTableScript,
  countGridRowsScript,
  isTreeGridScript,
  findGridHeadCenterCoordsScript,
  getSelectedOrLastRowIndexScript,
  findGridCellScript,
  findFocusCellScript,
  snapshotGridScript,
  resolveCellTargetScript,
} from './dom/grid.mjs';

export {
  sortFieldKeysByColindexScript,
  findCellCoordsByFieldsScript,
  findNextCellCoordsByKeyScript,
  findCheckboxAtPointScript,
  findRowCommitClickCoordsScript,
  getGridEditCheckScript,
  readActiveGridCellScript,
  getElementCenterCoordsByIdScript,
} from './dom/grid-edit.mjs';

export {
  readSectionsScript,
  readTabsScript,
  switchTabScript,
  readCommandsScript,
  navigateSectionScript,
  openCommandScript,
} from './dom/nav.mjs';

export {
  readSubmenuScript,
  clickPopupItemScript,
  readCloudDDScript,
} from './dom/submenu.mjs';

export { checkErrorsScript } from './dom/errors.mjs';
