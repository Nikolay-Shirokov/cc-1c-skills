// Config for the suite-root fixture only. Its whole job is to sit HERE, one level above
// `nested/`, so that `run.mjs test tests/web-test/_suite-root/nested/` has to climb to find it.
// The stand must already be published (this fixture exercises path resolution, not the stand).
export default {
  contexts: {
    a: { url: 'http://localhost:9191/webtest-runner/ru_RU' },
  },
  defaultContext: 'a',
  timeout: 60000,
};
