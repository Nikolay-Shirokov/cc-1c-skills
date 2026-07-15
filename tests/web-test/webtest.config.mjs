// Default config for tests/web-test. CLI URL still overrides defaultContext URL.
// Two contexts pointing at the same webtest publication — represent two independent
// 1C sessions (different cookies), used by multi-context tests to simulate two users.
//
// AppName `webtest-runner` отличается от интерактивной публикации `webtest` на :8081 —
// автономный стенд (см. tests/web-test/_hooks.mjs) использует свой URL, чтобы не
// конфликтовать с ручной разведкой и работать поверх отдельного Apache на :9191.
export default {
  contexts: {
    // `displayName` — человекочитаемое имя контекста, видно хукам через
    // testInfo.contexts[name].displayName (например для showTitleSlide).
    // Custom-поля любого типа пробрасываются как есть.
    a: { url: 'http://localhost:9191/webtest-runner/ru_RU', displayName: 'Пользователь A' },
    b: { url: 'http://localhost:9191/webtest-runner/ru_RU', displayName: 'Пользователь B' },
    // c — третий контекст, задействован только 14-multi-context-routing. Под maxContexts:2
    // он вытесняется на границе 14→15 (см. проверку пула в 15-multi-context-handover).
    c: { url: 'http://localhost:9191/webtest-runner/ru_RU', displayName: 'Пользователь C' },
  },
  defaultContext: 'a',

  // Пул 1С-лицензий (дай-фудим фичу на собственном регрессе). Одновременно живых сеансов —
  // не больше maxContexts; LRU-вытеснение освобождает слот под нужды следующего теста.
  // pinnedContexts:[] делает default `a` вытесняемым (здесь он всё равно нужен почти всем тестам,
  // так что не вытесняется — но снимает жёсткий пин). Благодаря лимиту 3 контекста a/b/c
  // никогда не живут одновременно: c закрывается до открытия b.
  maxContexts: 2,
  contextPolicy: 'reuse',
  pinnedContexts: [],
  // isolation: 'tab' (default) — persistent context, tabs in one window, 1С extension loads.
  //   Cookies are shared between tabs but scope by URL path, so different vrd-publications
  //   give independent auth without extra isolation.
  // isolation: 'window' — separate BrowserContext per slot, full cookie isolation,
  //   extension may not load (Playwright limitation). Use only when really needed.
  timeout: 60000,

  // OS clipboard preservation: default `true`. Around every action call the engine
  // saves the full clipboard contents (any MIME types via `navigator.clipboard.read()`)
  // and restores them after, so a local user can copy/paste in parallel with a test run.
  // Set to `false` to disable for this suite. CLI flag `--no-preserve-clipboard` overrides.
  preserveClipboard: true,

  // Allure severity policy: inverted map "уровень → теги, попадающие в этот уровень".
  // Резолв (run.mjs:resolveSeverity):
  //   1. explicit `export const severity` в тесте — выигрывает всегда;
  //   2. иначе max-rank среди тегов теста (стандартное имя severity или маппинг ниже);
  //   3. иначе `defaultSeverity`.
  // Тег не может быть в двух bucket'ах одновременно — валидация при загрузке конфига.
  severity: {
    critical: ['smoke', 'multi-context'],
    minor:    ['recording'],
    // blocker / trivial — пустые, не используем
  },
  defaultSeverity: 'normal',
};
