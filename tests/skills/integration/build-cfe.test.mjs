// build-cfe.test.mjs — Integration test: build a 1C extension (CFE) from scratch
// Steps: cfe-init → cfe-borrow (catalog) → cfe-patch-method (Before interceptor) → cfe-validate

export const name = 'Сборка расширения конфигурации (CFE)';
export const setup = 'base-config';

export const steps = [
  // ── 1. Init extension pointing at the base config ──
  {
    name: 'cfe-init: расширение ТестовоеРасширение',
    script: 'cfe-init/scripts/cfe-init',
    args: { '-Name': 'ТестовоеРасширение', '-OutputDir': '{workDir}/ext', '-ConfigPath': '{workDir}' },
    validate: { script: 'cfe-validate/scripts/cfe-validate', flag: '-ExtensionPath', path: 'ext' },
  },

  // ── 2. Borrow a catalog from the base config ──
  {
    name: 'cfe-borrow: заимствование Catalog.Контрагенты',
    script: 'cfe-borrow/scripts/cfe-borrow',
    args: { '-ExtensionPath': '{workDir}/ext', '-ConfigPath': '{workDir}', '-Object': 'Catalog.Контрагенты' },
    validate: { script: 'cfe-validate/scripts/cfe-validate', flag: '-ExtensionPath', path: 'ext' },
  },

  // ── 3. Add a Before interceptor for a method on the borrowed catalog ──
  {
    name: 'cfe-patch-method: перехватчик Перед для ПриЗаписи',
    script: 'cfe-patch-method/scripts/cfe-patch-method',
    args: {
      '-ExtensionPath': '{workDir}/ext',
      '-ModulePath': 'Catalog.Контрагенты.ObjectModule',
      '-MethodName': 'ПриЗаписи',
      '-InterceptorType': 'Before',
    },
    validate: { script: 'cfe-validate/scripts/cfe-validate', flag: '-ExtensionPath', path: 'ext' },
  },

  // ── 4. Final validation ──
  {
    name: 'cfe-validate: финальная валидация расширения',
    script: 'cfe-validate/scripts/cfe-validate',
    args: { '-ExtensionPath': '{workDir}/ext' },
  },
];
