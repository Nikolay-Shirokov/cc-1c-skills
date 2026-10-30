// Конфигурация набора регресса. Контекст = пользователь (роль). Латинские id — для кода,
// русские displayName — для отчётов и хуков (testInfo.contexts[id].displayName).
import { readFileSync } from 'node:fs';

// Порт и публикации задаются один раз — в stand.config.json; здесь только ссылаемся на них по
// appName. Опечатка или публикация, которой нет в стенде, — ошибка сразу при загрузке набора.
const stand = JSON.parse(readFileSync(new URL('./stand.config.json', import.meta.url), 'utf8'));
const published = (appName) => {
  if (!stand.publications.some((p) => p.appName === appName))
    throw new Error(`webtest.config.mjs: публикации «${appName}» нет в stand.config.json → publications`);
  return `http://localhost:${stand.port}/${appName}/ru_RU`;
};

export default {
  contexts: {
    // Основной путь: каждая роль — своя публикация под своим пользователем (stand.config.json →
    // publications). Адрес сам определяет, под кем вход, — удобно и для ручной проверки по ссылке.
    admin: { url: published('app-admin'), displayName: 'Администратор' },
    init:  { url: published('app-init'),  displayName: 'Инициатор' },
    appr:  { url: published('app-appr'),  displayName: 'Согласующий' },

    // Альтернатива: одна публикация без пользователя, пользователь — у контекста. Подходит, когда
    // состав пользователей меняется и перепубликовывать ради каждого неудобно. Пароль — не открытым
    // текстом: password: process.env.AUDITOR_PWD (у пользователя примера пароль пустой).
    auditor: { url: published('app'), user: 'Аудитор', displayName: 'Аудитор' },
  },
  defaultContext: 'admin',

  // Пул 1С-лицензий: одновременно живых сеансов не больше maxContexts; лишние раннер вытесняет
  // перед тестом (LRU) и переиспользует уже открытые. pinnedContexts: [] — default тоже вытесняем.
  maxContexts: 2,
  contextPolicy: 'reuse',
  pinnedContexts: [],

  // Вход под ролью на холодном стенде бывает долгим — запас на него.
  timeout: 120000,
  // Повторы вредны мутирующим тестам: второй заход идёт по уже изменённым данным и прячет
  // настоящую точку падения.
  retries: 0,

  screenshot: 'on-failure',
  severity: { critical: ['smoke'] },
  defaultSeverity: 'normal',
};
