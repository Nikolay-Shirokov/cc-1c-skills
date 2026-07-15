// Fixture — NOT part of the normal suite. `_`-prefixed dirs are skipped by discoverTests'
// walk(), so `test tests/web-test/` never picks this up; `test tests/web-test/_hang` does,
// because the explicitly-passed root is not filtered, only its children are.
//
// Reproduces the reported failure mode: a wedged renderer JS thread. page.evaluate has no
// timeout in Playwright at all, so before the abort work this test hung the whole run forever
// (the reported incident: ~29 min, no progress, report lost).
//
// Expected with the fix: fails at its own timeout with `verdict: hang`, the context is
// aborted (seance released from Node), and 02 below still passes on a fresh context.
export const name = 'hang: заблокированный JS-поток рендерера';
export const tags = ['hang'];
export const timeout = 10000;

export default async function({ getPage, log }) {
  const page = await getPage();
  log('wedging the renderer main thread — nothing after this line can ever run');
  await page.evaluate(() => { while (true) {} });
  log('UNREACHABLE');
}
