// platform-webtest-config.test.mjs — Platform verification of synthetic web-test config
// Reuses the build steps from build-webtest-config and adds db-create/load/update tail.
// Goal: confirm that the synthetic configuration is actually accepted by the 1C platform.

import { steps as buildSteps } from './build-webtest-config.test.mjs';

export const name = 'Загрузка синтетической конфигурации web-test в платформу';
export const setup = 'none';
export const cache = 'webtest-config-platform';
export const requiresPlatform = true;

export const steps = [
  ...buildSteps,

  // ── Platform load ──
  {
    name: 'db-create: создание файловой ИБ',
    script: 'db-create/scripts/db-create',
    args: {
      '-V8Path': '{v8path}',
      '-InfoBasePath': '{workDir}/testdb',
    },
  },
  {
    name: 'db-load-xml: загрузка конфигурации',
    script: 'db-load-xml/scripts/db-load-xml',
    args: {
      '-V8Path': '{v8path}',
      '-InfoBasePath': '{workDir}/testdb',
      '-ConfigDir': '{workDir}',
    },
  },
  {
    name: 'db-update: обновление БД',
    script: 'db-update/scripts/db-update',
    args: {
      '-V8Path': '{v8path}',
      '-InfoBasePath': '{workDir}/testdb',
    },
  },
];
