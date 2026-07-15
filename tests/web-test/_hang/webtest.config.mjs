// Config for the hang fixtures only. Deliberately minimal: one context, no _hooks.mjs
// (the stand must already be published — these fixtures exercise the runner, not the stand).
export default {
  contexts: {
    a: { url: 'http://localhost:9191/webtest-runner/ru_RU' },
  },
  defaultContext: 'a',
  timeout: 60000,
};
