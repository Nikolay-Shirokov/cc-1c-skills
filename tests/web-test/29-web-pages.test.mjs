export const name = 'web pages: web.open next to 1C, switching, recording, web.highlight, web.mask, web.saveLogin, start --web';
export const tags = ['recording'];
export const timeout = 180000;

// Read-only on the stand: a local page served by the test itself; 1C is only looked at.
export default async function({
  web, getPage, getActiveContext, setActiveContext, closeContext, getFormState, showCaption, hideCaption,
  startRecording, stopRecording, assert, step, log,
}) {
  const fs = await import('fs');
  const path = await import('path');
  const http = await import('http');
  const { execFileSync } = await import('child_process');

  const dir = 'test-tmp/web-pages';
  fs.mkdirSync(dir, { recursive: true });
  // a small site: a page counting keydowns, a "secret" to mask, a login setting a cookie
  const html = `<!doctype html><html><head><title>Смежная система</title></head><body style="font:24px sans-serif">
<h1>Заказы</h1><div class="order" style="margin:40px;padding:10px">Заказ 000123</div>
<div class="secret">Пользователь: Иванов Иван</div><div id="keys">0</div>
<span class="mixed">Петров П.П. <i>▾</i></span>
<style>.menu .name{visibility:visible}</style><div class="menu"><b class="name">Сидоров</b></div>
<div class="other" style="margin:20px">Склад</div>
<script>let n=0;addEventListener('keydown',()=>{document.getElementById('keys').textContent=++n})</script></body></html>`;
  const server = http.createServer((req, res) => {
    // sid — the site's login; base1c — a cookie of another publication on the same host (its own path)
    if (req.url === '/login') { res.writeHead(302, { 'Set-Cookie': ['sid=abc123; Path=/', 'base1c=x; Path=/base1c'], Location: '/' }); return res.end(); }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  // the 1C page: the runner's context, or 'main' — web.open registers a single connect() page under that name
  let home = getActiveContext();

  try {
    await step('web.open: a tab without 1C steps — quick, no Escape pressed', async () => {
      const t0 = Date.now();
      const r = await web.open('site', base + '/', { ready: '.order' });
      home = home || 'main';
      const ms = Date.now() - t0;
      log(`web.open: ${ms} ms ${JSON.stringify(r)} contexts home=${home}`);
      assert.ok(ms < 10000, `quick (${ms} ms), no 1C client wait`);
      assert.equal(r.title, 'Смежная система');
      assert.equal(getActiveContext(), 'site', 'the new page is active');
      assert.equal(await getPage().locator('#keys').textContent(), '0', 'no key pressed on the page (no Escape)');
      let err = null;
      try { await web.open(home, base + '/'); } catch (e) { err = e; }
      assert.ok(err && /is a 1C context/.test(err.message), `the 1C context's name is taken (${err?.message})`);
      assert.equal(getActiveContext(), 'site', 'nothing switched');
    });

    await step('what web analytics sends is cut on a web page at once; the site itself is not', async () => {
      const pg = getPage();
      const res = await pg.evaluate(async (base) => {
        const t = async (u) => { const t0 = Date.now(); try { await fetch(u, { mode: 'no-cors' }); return ['ok', Date.now() - t0]; } catch { return ['cut', Date.now() - t0]; } };
        return { beacon: await t('https://mc.yandex.ru/watch/1?x=1'), site: await t(base + '/') };
      }, base);
      log(`analytics ${JSON.stringify(res)}`);
      assert.equal(res.beacon[0], 'cut', 'the beacon is cut');
      assert.ok(res.beacon[1] < 2000, 'at once');
      assert.equal(res.site[0], 'ok', 'the site answers');
    });

    await step('web.highlight(locator) frames an element; web.unhighlight removes it; a text is refused', async () => {
      const pg = getPage();
      await web.highlight(pg.locator('.order'));
      const [frame, el] = await Promise.all([
        pg.locator('#__web_test_highlight').boundingBox(), pg.locator('.order').boundingBox(),
      ]);
      log(`frame ${JSON.stringify(frame)} element ${JSON.stringify(el)}`);
      assert.ok(frame && frame.x <= el.x && frame.y <= el.y && frame.x + frame.width >= el.x + el.width, 'the frame surrounds the element');
      await web.highlight(pg.locator('.other'));   // a second frame replaces the first
      await pg.waitForTimeout(200);
      const [f2, el2] = await Promise.all([pg.locator('#__web_test_highlight').boundingBox(), pg.locator('.other').boundingBox()]);
      assert.equal(await pg.locator('#__web_test_highlight').count(), 1, 'one frame');
      assert.ok(Math.abs(f2.y - (el2.y - 4)) < 2, `the frame is on the second element (${f2.y} vs ${el2.y})`);
      await web.unhighlight();
      assert.equal(await pg.locator('#__web_test_highlight').count(), 0, 'removed');
      let err = null;
      try { await web.highlight('Заказ'); } catch (e) { err = e; }
      assert.ok(err && /Playwright Locator/.test(err.message), 'a text points to highlight(text) for 1C');
    });

    await step('web.mask hides by selector and by text, also after a reload', async () => {
      const pg = getPage();
      await web.mask(['.order', { text: 'Иванов' }]);
      await web.mask(['.menu', { text: 'Петров' }]);   // a second call adds to the first
      const sel = ['.order', '.secret', '.mixed', '.menu .name', '.other'];
      const vis = () => pg.evaluate((sel) => sel.map((x) => getComputedStyle(document.querySelector(x)).visibility), sel);
      const want = ['hidden', 'hidden', 'hidden', 'hidden', 'visible'];
      assert.deepEqual(await vis(), want, 'hidden at once: selector, text, mixed content, a visible descendant; the rest stays');
      await pg.reload();
      await pg.waitForTimeout(100);
      assert.deepEqual(await vis(), want, 'still hidden after a reload');
    });

    await step('recording follows the switch: 1C → site → 1C in one file; 1C still answers', async () => {
      const video = path.join(dir, 'switch.mp4');
      await setActiveContext(home);
      await startRecording(video, { fps: 10 });
      await getPage().waitForTimeout(700);
      await setActiveContext('site');
      await getPage().waitForTimeout(700);
      await setActiveContext(home);
      await getPage().waitForTimeout(700);
      const res = await stopRecording();
      log(`video ${res.duration}s ${res.size}B`);
      assert.ok(fs.existsSync(res.file) && res.duration >= 1.5, 'one video across the switches');
      const st = await getFormState();
      assert.ok(st && typeof st === 'object', '1C answers after coming back');
    });

    await step('one caption for the session: a new one takes the old off the other page', async () => {
      const cap = () => getPage().evaluate(() => document.getElementById('__web_test_caption')?.textContent || null);
      await setActiveContext(home);
      await showCaption('В 1С');
      await setActiveContext('site');
      assert.equal(await cap(), null, 'the site has no caption yet');
      await showCaption('На сайте');
      await setActiveContext(home);
      assert.equal(await cap(), null, 'coming back to 1C: the old caption is gone');
      await setActiveContext('site');
      assert.equal(await cap(), 'На сайте', 'the current caption stays where it was shown');
      await setActiveContext(home);
      await hideCaption();
      await setActiveContext('site');
      assert.equal(await cap(), null, 'hideCaption takes it off the other page too');
    });

    await step('web.saveLogin keeps only the active site; a saved login is applied to a new page', async () => {
      await setActiveContext('site');
      await getPage().goto(base + '/login');
      const file = path.join(dir, 'login.json');
      const r = await web.saveLogin(file);
      const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
      log(`saveLogin ${JSON.stringify(r)} cookies ${JSON.stringify(saved.cookies.map((c) => c.domain))}`);
      assert.ok(saved.cookies.some((c) => c.name === 'sid'), 'the site login is saved');
      assert.ok(saved.cookies.every((c) => c.domain.replace(/^\./, '') === '127.0.0.1'), 'nothing of other sites (the 1C seance stays out)');
      assert.ok(!saved.cookies.some((c) => c.name === 'base1c'), 'nothing of another publication on the same host');
      await web.open('site2', base + '/', { login: file });
      assert.ok((await getPage().context().cookies(base)).some((c) => c.name === 'sid'), 'the login cookie is there');
    });

    await step('a saved login puts localStorage once: what the site stores later survives a reload', async () => {
      await setActiveContext('site');
      await getPage().evaluate(() => localStorage.setItem('token', 'saved'));
      const file = path.join(dir, 'login-ls.json');
      await web.saveLogin(file);
      await getPage().evaluate(() => localStorage.removeItem('token'));
      await web.open('site3', base + '/', { login: file });
      const pg = getPage();
      assert.equal(await pg.evaluate(() => localStorage.getItem('token')), 'saved', 'the saved value is put');
      await pg.evaluate(() => localStorage.setItem('token', 'refreshed'));   // the site refreshes its token
      await pg.reload();
      assert.equal(await pg.evaluate(() => localStorage.getItem('token')), 'refreshed', 'not overwritten by the file on reload');
    });

    await step('start --web refuses --user; --login without --web is refused', async () => {
      const run = (args) => { try { execFileSync(process.execPath, ['.claude/skills/web-test/scripts/run.mjs', ...args], { encoding: 'utf8', timeout: 20000, stdio: 'pipe' }); return ''; } catch (e) { return String(e.stdout) + String(e.stderr); } };
      assert.match(run(['start', base + '/', '--web', '--user=x']), /--user= is for 1C/, '--web with --user');
      assert.match(run(['start', base + '/', '--login=x.json']), /go with --web/, '--login without --web');
    });
  } finally {
    if (home) await setActiveContext(home);
    for (const n of ['site', 'site2', 'site3']) { try { await closeContext(n); } catch {} }
    server.close();
  }
}
