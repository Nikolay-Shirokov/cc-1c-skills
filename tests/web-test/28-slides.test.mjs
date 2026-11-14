export const name = 'slides: showSlide templates, steps, captions, theme, layouts, legacy, --no-record, play/preview (no TTS service)';
export const tags = ['recording'];
export const timeout = 240000;

// Read-only on the stand: slides are overlays over the current page, nothing is written to 1C.
export default async function({
  showSlide, hideSlide, prepareSlides, setSlideTheme, showTitleSlide, hideTitleSlide,
  startRecording, stopRecording, getCaptions, screenshot, getPage, withMusic, addNarration, speak, showCaption,
  assert, step, log,
}) {
  const fs = await import('fs');
  const path = await import('path');
  const { execFileSync } = await import('child_process');
  const { pathToFileURL } = await import('url');

  const dir = 'test-tmp/slides';
  fs.mkdirSync(dir, { recursive: true });
  const shadow = async (fn, arg) => (await getPage()).evaluate(fn, arg);
  const slideState = () => shadow(() => {
    const host = document.getElementById('__ws_slide');
    if (!host) return null;
    const r = host.shadowRoot;
    return {
      kind: host.dataset.kind || null,
      static: !!r.querySelector('.ws-static'),
      accent: getComputedStyle(r.querySelector('.ws-slide')).getPropertyValue('--accent').trim(),
      on: [...r.querySelectorAll('.on')].flatMap((e) => [...e.classList].filter((c) => !c.startsWith('ws-') && c !== 'on')),
      focus: r.querySelectorAll('.ws-focus').length,
      dim: r.querySelectorAll('.ws-dim').length,
    };
  });
  const fast = { fast: 0.15, lint: 'collect' };
  const rejectsWith = async (fn, re, msg) => {
    let err = null;
    try { await fn(); } catch (e) { err = e; }
    assert.ok(err, `${msg}: expected an error`);
    assert.match(err.message, re, msg);
  };

  await step('validation: a wrong spec throws before anything is shown', async () => {
    const tooMany = { layout: 'radial', center: { title: 'Ц' }, cards: [...Array(8)].map((_, i) => ({ title: `К${i}` })), steps: [{ show: 'center' }] };
    await rejectsWith(() => prepareSlides([tooMany], { validateOnly: true }), /3–6 cards supported, got 8/, 'radial: limit with advice');
    await rejectsWith(() => prepareSlides([{ layout: 'nope' }], { validateOnly: true }), /unknown layout "nope".*title/, 'unknown layout lists the layouts');
    const badShow = { layout: 'cards', cards: [{ title: 'А' }], steps: [{ show: 3 }] };
    await rejectsWith(() => showSlide(badShow, fast), /step 1: show 3 — no such element; addresses: 0 «А»/, 'show index out of range, the addresses listed');
    const keyInArray = { layout: 'radial', center: { title: 'Ц' }, cards: [{ title: 'А' }, { title: 'Б' }, { title: 'В' }], steps: [{ show: ['center', 0] }] };
    await prepareSlides([keyInArray], { validateOnly: true });   // a key and an index together: two addresses
    assert.equal(await slideState(), null, 'nothing was mounted');
  });

  await step('cards: shadow-DOM host, steps reveal and focus, final clear, theme from spec', async () => {
    const r = await showSlide({
      layout: 'cards', title: 'Карточки', theme: { accent: '#123456' },
      cards: [{ title: 'Первая', items: ['а'] }, { title: 'Вторая', items: ['б'] }, { title: 'Третья', items: ['в'] }],
      steps: [{ show: 0 }, { show: [1, 2] }],
    }, fast);
    const st = await slideState();
    log(`state: ${JSON.stringify(st)} result: ${JSON.stringify(r)}`);
    assert.equal(r.steps, 3, 'two steps + closing clear');
    assert.deepEqual(['cd-0', 'cd-1', 'cd-2'].every((c) => st.on.includes(c)), true, 'all three cards revealed');
    assert.equal(st.focus, 0, 'focus cleared at the end');
    assert.equal(st.accent, '#123456', 'spec.theme reaches the slide');
    assert.equal(st.static, false, 'animated by default');
  });

  await step('theme layers: setSlideTheme applies, spec.theme wins', async () => {
    setSlideTheme({ accent: '#abcdef' });
    await showSlide({ layout: 'statement', text: 'Одна мысль' }, fast);
    assert.equal((await slideState()).accent, '#abcdef', 'scenario theme');
    await showSlide({ layout: 'statement', text: 'Одна мысль', theme: { accent: '#fedcba' } }, fast);
    assert.equal((await slideState()).accent, '#fedcba', 'spec.theme over setSlideTheme');
    setSlideTheme(null);
  });

  await step('own page: a dimmed element hidden later is gone (no ghost); closing keeps title line breaks', async () => {
    await showSlide({
      html: '<div class="pa">А</div><div class="pb">Б</div>', css: '.pa,.pb{position:absolute;top:300px;font-size:60px}.pb{left:900px}',
      steps: [{ show: '.pa, .pb' }, { dim: '.pa' }, { hide: '.pa' }],
    }, fast);
    const pa = await shadow(() => [...document.getElementById('__ws_slide').shadowRoot.querySelector('.pa').classList]);
    log(`.pa classes after dim → hide: ${pa.join(' ')}`);
    assert.ok(!pa.includes('ws-dim') && !pa.includes('on'), 'hide drops the dim along with the reveal');
    await showSlide({ layout: 'closing', title: 'Строка один\nСтрока два' }, fast);
    const br = await shadow(() => document.getElementById('__ws_slide').shadowRoot.querySelectorAll('.cl-title br').length);
    assert.equal(br, 1, 'closing title: \\n → line break');
  });

  await step('own page checks: text past the edge is flagged, a drawn shape and a ws-nolint bubble are not', async () => {
    const r = await showSlide({
      html: '<svg class="fig" viewBox="0 0 100 100" style="position:absolute;left:1700px;top:700px;width:500px;height:500px">'
        + '<circle cx="50" cy="50" r="50"/></svg>'
        + '<div class="edge" style="position:absolute;left:1800px;top:100px;font-size:40px;white-space:nowrap">Текст за краем кадра</div>'
        + '<div class="bub ws-nolint" style="position:absolute;left:200px;top:400px;font-size:40px">Привет я покажу что теперь умеет запись видео</div>',
      steps: [{ show: '.fig, .edge, .bub', speech: 'Привет я покажу что теперь умеет запись видео' }],
    }, fast);
    const w = r.warnings || [];
    log(`warnings: ${JSON.stringify(w)}`);
    assert.ok(w.some((x) => x.includes('.edge is outside the frame')), 'text past the edge is flagged');
    assert.ok(!w.some((x) => /fig|circle|svg/.test(x)), 'a drawn shape past the edge is not flagged');
    assert.ok(!w.some((x) => /repeats the narration/.test(x)), 'a ws-nolint bubble may repeat the phrase');
  });

  await step("templates: show 'all' lights everything with no focus and no dim; background reaches every template", async () => {
    const counts = async (spec) => {
      const all = spec.steps.findIndex((s) => [].concat(s.show).includes('all'));
      let at = null;
      await showSlide(spec, { ...fast, onStep: async (i) => { if (i === all) at = await slideState(); } });
      return [at.focus, at.dim];
    };
    const three = [{ title: 'А', items: ['а'] }, { title: 'Б', items: ['б'] }, { title: 'В', items: ['в'] }];
    const seq = [{ show: 0 }, { show: 1 }, { show: 'all' }];
    const specs = {
      cards: { layout: 'cards', cards: three, steps: seq },
      columns: { layout: 'columns', columns: three, steps: seq },
      comparison: { layout: 'comparison', left: { title: 'Л', items: ['а'] }, right: { title: 'П', items: ['б'] },
        steps: [{ show: 'left' }, { show: 'right', row: 0 }, { show: 'all' }] },
      process: { layout: 'process', stages: three, steps: seq },
      radial: { layout: 'radial', center: { title: 'Ц' }, cards: three, steps: [{ show: 'center' }, ...seq] },
      summary: { layout: 'summary', items: ['а', 'б', 'в'], steps: seq },
      'summary [all, next]': { layout: 'summary', items: ['а', 'б', 'в'], next: 'Дальше', steps: [{ show: 0 }, { show: 1 }, { show: ['all', 'next'] }] },
    };
    for (const [name, spec] of Object.entries(specs)) assert.deepEqual(await counts(spec), [0, 0], `${name}: 'all' — no focus, no dim`);
    for (const layout of ['cards', 'process', 'radial']) {
      await showSlide({ ...specs[layout], background: 'rgb(18, 49, 35)' }, fast);
      const bg = await shadow(() => getComputedStyle(document.getElementById('__ws_slide').shadowRoot.querySelector('.ws-bg')).backgroundColor);
      assert.equal(bg, 'rgb(18, 49, 35)', `${layout}: background applied`);
    }
    const ground = () => shadow(() => getComputedStyle(document.getElementById('__ws_slide').shadowRoot.querySelector('.ws-bg')).backgroundColor);
    setSlideTheme({ background: 'rgb(1, 2, 3)' });
    await showSlide(specs.cards, fast);
    const themed = await ground();
    await showSlide({ layout: 'title', title: 'Титул' }, fast);
    const title = await ground();
    setSlideTheme(null);
    assert.equal(themed, 'rgb(1, 2, 3)', 'theme.background on a slide without its own');
    assert.notEqual(title, 'rgb(1, 2, 3)', 'title keeps its own ground');
  });

  await step('theme: light ground keeps white cards; dark ground derives dark cards with readable text', async () => {
    // computed colours (color-mix gives oklab()/color()) → rgb through a canvas pixel
    const card = () => shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot;
      const g = Object.assign(document.createElement('canvas'), { width: 1, height: 1 }).getContext('2d');
      const rgb = (c) => { g.clearRect(0, 0, 1, 1); g.fillStyle = c; g.fillRect(0, 0, 1, 1); return `rgb(${[...g.getImageData(0, 0, 1, 1).data].slice(0, 3).join(', ')})`; };
      const cs = (sel, p) => rgb(getComputedStyle(r.querySelector(sel))[p]);
      return { ground: cs('.ws-slide', 'backgroundColor'), card: cs('.cd-0', 'backgroundColor'), text: cs('.cd-0 p', 'color'), head: cs('.cd-lead b', 'color') };
    });
    const { luminance } = await import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/engine/recording/slides/protocol.mjs')).href);
    const ratio = (a, b) => { const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
    const spec = { layout: 'cards', lead: { title: 'Вводная', text: 'текст' }, cards: [{ title: 'А', text: 'Текст карточки' }], steps: [{ show: 'all' }] };
    await showSlide(spec, fast);
    const light = await card();
    log(`light: ${JSON.stringify(light)}`);
    assert.equal(light.card, 'rgb(255, 255, 255)', 'light ground: white cards as before');
    setSlideTheme({ primary: '#14213d', accent: '#3fb68b', ground: '#14213d', ink: '#FFFFFF' });
    await showSlide(spec, fast);
    const dark = await card();
    setSlideTheme(null);
    log(`dark: ${JSON.stringify(dark)} text/card ${ratio(dark.text, dark.card).toFixed(1)} head/ground ${ratio(dark.head, dark.ground).toFixed(1)}`);
    assert.notEqual(dark.card, 'rgb(255, 255, 255)', 'dark ground: no white cards');
    assert.notEqual(dark.card, dark.ground, 'cards stand apart from the ground');
    assert.ok(ratio(dark.text, dark.card) >= 4.5, 'card text readable on the card');
    assert.ok(ratio(dark.head, dark.ground) >= 4.5, 'a heading on the ground readable');
    // header bands (shades of primary on a light ground) stand apart from a dark ground of the same depth
    setSlideTheme({ primary: '#14213d', accent: '#3fb68b', ground: '#14213d', ink: '#FFFFFF' });
    await showSlide({ layout: 'columns', columns: [{ title: 'А', items: ['а'] }, { title: 'Б', items: ['б'] }], steps: [{ show: 'all' }] }, fast);
    const band = await shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot;
      const g = Object.assign(document.createElement('canvas'), { width: 1, height: 1 }).getContext('2d');
      const rgb = (c) => { g.clearRect(0, 0, 1, 1); g.fillStyle = c; g.fillRect(0, 0, 1, 1); return `rgb(${[...g.getImageData(0, 0, 1, 1).data].slice(0, 3).join(', ')})`; };
      const h = getComputedStyle(r.querySelector('.co-0 h3'));
      return { band: rgb(h.backgroundColor), text: rgb(h.color), ground: rgb(getComputedStyle(r.querySelector('.ws-slide')).backgroundColor) };
    });
    setSlideTheme(null);
    log(`band: ${JSON.stringify(band)} band/ground ${ratio(band.band, band.ground).toFixed(2)} text/band ${ratio(band.text, band.band).toFixed(1)}`);
    assert.ok(ratio(band.band, band.ground) >= 1.3, 'a header band stands apart from the dark ground');
    assert.ok(ratio(band.text, band.band) >= 4.5, 'its title readable');
    // a bright primary on a dark ground: the cards still come from the ground, their text stays readable
    setSlideTheme({ primary: '#f0a202', ground: '#111111', ink: '#FFFFFF' });
    await showSlide(spec, fast);
    const bright = await card();
    // a light grey ground is not dark: white cards as on the default
    setSlideTheme({ ground: '#a0a0a0' });
    await showSlide(spec, fast);
    const grey = await card();
    setSlideTheme(null);
    log(`bright primary: ${JSON.stringify(bright)} ${ratio(bright.text, bright.card).toFixed(1)}; grey: ${grey.card}`);
    assert.ok(ratio(bright.text, bright.card) >= 4.5, 'bright primary: card text readable');
    assert.equal(grey.card, 'rgb(255, 255, 255)', 'a light grey ground keeps white cards');
  });

  await step('statuses: ok/warn/off/optional on cards, columns, process, radial, comparison cells; a wrong one is a spec error', async () => {
    const st = (sel) => shadow((sel) => {
      const r = document.getElementById('__ws_slide').shadowRoot;
      return { cls: [...r.querySelectorAll(sel)].map((e) => (e.className.match(/ws-st-\w+/) || [''])[0]),
        marks: [...r.querySelectorAll('.ws-st-ic')].filter((e) => getComputedStyle(e).display !== 'none').length };
    }, sel);
    const four = ['ok', 'warn', 'off', 'optional'];
    await showSlide({ layout: 'cards', cards: [...four.map((s) => ({ title: s, status: s })), { title: 'без статуса' }], steps: [{ show: 'all' }] }, fast);
    let r = await st('.cd-card');
    assert.deepEqual(r.cls, ['ws-st-ok', 'ws-st-warn', 'ws-st-off', 'ws-st-optional', ''], 'cards: a class per status, none without');
    assert.equal(r.marks, 2, 'cards: marks for ok and warn only');
    await showSlide({ layout: 'columns', columns: four.slice(0, 2).map((s) => ({ title: s, status: s })), steps: [{ show: 'all' }] }, fast);
    assert.equal((await st('.co-col h3 .ws-st-ic')).marks, 2, 'columns: the mark sits in the header band');
    await showSlide({ layout: 'process', stages: [{ title: 'А', status: 'off' }, { title: 'Б' }], steps: [{ show: 'all' }] }, fast);
    assert.deepEqual((await st('.pr-card')).cls, ['ws-st-off', ''], 'process: status on the stage card');
    await showSlide({ layout: 'radial', center: { title: 'Ц' }, cards: [{ title: 'А', status: 'warn' }, { title: 'Б' }, { title: 'В' }], steps: [{ show: 'all' }] }, fast);
    assert.deepEqual((await st('.hb-card')).cls, ['ws-st-warn', '', ''], 'radial: status on the card');
    await showSlide({ layout: 'comparison', left: { title: 'Л', items: ['а', 'б'] }, right: { title: 'П', items: [{ text: 'в', status: 'ok' }, 'г'] }, steps: [{ show: 'all' }] }, fast);
    assert.deepEqual((await st('.cp-r')).cls, ['ws-st-ok', ''], 'comparison: a cell { text, status }');
    await rejectsWith(() => prepareSlides([{ layout: 'cards', cards: [{ title: 'А', status: 'done' }], steps: [{ show: 0 }] }], { validateOnly: true }),
      /card 1: status must be ok, warn, off or optional/, 'a wrong status');
  });

  await step("flow: inputs → centre → outputs, steps by column, links laid out, circle shape; radial 'all' lights at once", async () => {
    await rejectsWith(() => prepareSlides([{ layout: 'flow', inputs: [...Array(7)].map((_, i) => ({ title: `${i}` })), center: { title: 'Ц' },
      outputs: [{ title: 'Р' }], steps: [{ show: 'center' }] }], { validateOnly: true }), /1–5 inputs supported, got 7/, 'inputs limit with advice');
    await rejectsWith(() => prepareSlides([{ layout: 'flow', inputs: [{ title: 'А' }], center: { title: 'Ц' }, outputs: [{ title: 'Р' }],
      steps: [{ out: 3 }] }], { validateOnly: true }), /step 1: show \{"out":3\} — no such element/, 'out index in range');
    const spec = { layout: 'flow', title: 'Поток', inputs: [{ title: 'А' }, { title: 'Б', status: 'optional' }], center: { title: 'Узел', items: ['раз'] },
      outputs: [{ title: 'Итог', status: 'ok' }], steps: [{ show: 'center' }, { in: 0 }, { in: 1 }, { out: 'all' }, { show: 'all' }] };
    const states = [];
    let optFocus = null;   // the optional input in focus: no plate, so it must not grow past its link's end
    await showSlide(spec, { ...fast, onStep: async (i) => {
      if (i < 5) states.push(await slideState());
      if (i === 2) optFocus = await shadow(async () => {
        const el = document.getElementById('__ws_slide').shadowRoot.querySelector('.fl-i1');
        await Promise.all(el.getAnimations().map((a) => a.finished.catch(() => {})));   // past its entry
        return getComputedStyle(el).transform;
      });
    } });
    assert.equal(optFocus, 'none', `an optional item in focus does not grow (${optFocus})`);
    log(`flow steps: ${JSON.stringify(states.map((s) => s.on.filter((c) => /^fl-(center|i\d|o\d)$/.test(c))))}`);
    assert.ok(states[0].on.includes('fl-center') && !states[0].on.includes('fl-i0'), 'centre first');
    assert.ok(states[1].on.includes('fl-i0') && states[1].on.includes('fl-li0') && !states[1].on.includes('fl-i1'), 'an input with its link');
    assert.ok(states[3].on.includes('fl-o0') && states[3].on.includes('fl-lo0'), "out: 'all'");
    assert.deepEqual([states[4].focus, states[4].dim], [0, 0], "show 'all': no focus, no dim");
    const links = await shadow(() => [...document.getElementById('__ws_slide').shadowRoot.querySelectorAll('.ws-links path')].map((p) => p.getAttribute('d') || ''));
    assert.equal(links.length, 3, 'a link per input and output');
    assert.ok(links.every((d) => /^M[\d.]+ [\d.]+ L[\d.]+ [\d.]+$/.test(d)), 'links laid out');
    await showSlide({ ...spec, center: { ...spec.center, shape: 'circle' }, steps: [{ show: 'all' }] }, fast);
    assert.equal(await shadow(() => !!document.getElementById('__ws_slide').shadowRoot.querySelector('.fl-circle')), true, "shape: 'circle'");
    // radial: cards shown before are lit at once on 'all' (no cascade delay from their place in the list)
    const si = [];
    await showSlide({ layout: 'radial', center: { title: 'Ц' }, cards: [{ title: 'А' }, { title: 'Б' }, { title: 'В' }],
      steps: [{ show: 'center' }, { show: 0 }, { show: 1 }, { show: 2 }, { show: 'all' }] }, { ...fast, onStep: async (i) => {
      if (i === 4) si.push(...await shadow(() => [...document.getElementById('__ws_slide').shadowRoot.querySelectorAll('.hb-card')].map((e) => e.style.getPropertyValue('--si'))));
    } });
    assert.deepEqual(si, ['0', '0', '0'], "radial 'all': no cascade on cards already shown");
  });

  await step('frame: logo/number/footer from the theme, places and order, numbering, safe field, exceptions, overlap check', async () => {
    const logo = path.join(dir, 'frame-logo.png');
    fs.writeFileSync(logo, await screenshot());
    const fr = () => shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot, f = r.querySelector('.ws-frame');
      const x = (sel) => { const e = f?.querySelector(sel); return e ? Math.round(e.getBoundingClientRect().left) : null; };
      return { on: !!f, corners: f ? [...f.querySelectorAll('.wf-c')].map((c) => c.className.replace('wf-c ', '')) : [],
        num: f?.querySelector('.wf-num')?.textContent ?? null, edge: f?.querySelector('.wf-edge')?.textContent ?? null,
        logoX: x('.wf-logo'), numX: x('.wf-num'), safeLeft: getComputedStyle(r.querySelector('.ws-slide')).getPropertyValue('--safe-left').trim() };
    });
    const cards = { layout: 'cards', title: 'Рамка', cards: [{ title: 'А' }, { title: 'Б' }], steps: [{ show: 'all' }] };
    setSlideTheme({ frame: { logo: logo, number: true, footer: { text: 'Колонтитул', at: 'left' } } });
    await showSlide(cards, fast);
    let s = await fr();
    log(`frame: ${JSON.stringify(s)}`);
    assert.deepEqual(s.corners, ['wf-bottom-left', 'wf-bottom-right'], 'defaults: logo bottom-left, number bottom-right');
    assert.equal(s.edge, 'Колонтитул', 'footer along the left edge');
    assert.equal(s.safeLeft, '128px', 'the left edge keeps a field');
    const wrapLeft = await shadow(() => document.getElementById('__ws_slide').shadowRoot.querySelector('.cd-wrap').getBoundingClientRect().left);
    const edgeRight = await shadow(() => document.getElementById('__ws_slide').shadowRoot.querySelector('.wf-edge').getBoundingClientRect().right);
    assert.ok(wrapLeft > edgeRight, 'content starts right of the footer');
    const titleLeft = await shadow(() => document.getElementById('__ws_slide').shadowRoot.querySelector('.ws-title').getBoundingClientRect().left);
    assert.ok(titleLeft < wrapLeft, 'the title stays in place (the footer runs along the middle of the edge)');
    const n1 = Number(s.num);
    await showSlide({ ...cards, frame: { footer: 'Раздел 2' } }, fast);
    s = await fr();
    assert.equal(Number(s.num), n1 + 1, 'numbers go on');
    assert.equal(s.edge, 'Раздел 2', 'a spec replaces a part of the frame');
    await showSlide({ layout: 'title', title: 'Титул' }, fast);
    assert.equal((await fr()).on, false, 'title: no frame');
    await showSlide({ ...cards, frame: false }, fast);
    assert.equal((await fr()).on, false, 'frame: false');
    await showSlide({ ...cards, number: 10 }, fast);
    assert.equal((await fr()).num, '10', 'spec.number sets the number');
    await showSlide(cards, fast);
    assert.equal((await fr()).num, '11', 'and the count goes on from it (slides without a frame are not counted)');
    // one corner: in the order declared, the first in the corner
    setSlideTheme({ frame: { number: { at: 'bottom-right' }, logo: { src: logo, at: 'bottom-right' } } });
    await showSlide(cards, fast);
    s = await fr();
    assert.ok(s.numX > s.logoX, 'number declared first sits in the corner, the logo next to it');
    setSlideTheme({ frame: { logo: { src: logo, at: 'bottom-right' }, number: { at: 'bottom-right' } } });
    await showSlide(cards, fast);
    s = await fr();
    assert.ok(s.logoX > s.numX, 'logo declared first sits in the corner');
    setSlideTheme(null);
    await rejectsWith(() => prepareSlides([{ ...cards, theme: { frame: { logo: { src: logo, at: 'left' } } } }], { validateOnly: true }),
      /logo — at must be bottom-left/, 'an edge place is for the footer only');
    await rejectsWith(() => prepareSlides([{ ...cards, theme: { frame: { badge: true } } }], { validateOnly: true }),
      /unknown "badge" — logo, number, footer/, 'an unknown frame element');
    // a scenario drops the frame: theme frame false is "off", not an error
    setSlideTheme({ frame: false });
    await showSlide(cards, fast);
    assert.equal((await fr()).on, false, 'theme frame: false — no frame');
    setSlideTheme(null);
    // geometry under a frame: title vs content with a top corner; summary list vs its "next" card; a status mark on a card without a title
    const rect = (sel) => shadow((sel) => { const b = document.getElementById('__ws_slide').shadowRoot.querySelector(sel).getBoundingClientRect(); return { l: b.left, r: b.right, t: b.top, b: b.bottom }; }, sel);
    await showSlide({ ...cards, title: 'Заголовок в две строки, чтобы проверить, что содержимое уходит ниже вместе с ним',
      theme: { frame: { logo: { src: logo, at: 'top-left' } } } }, fast);
    await (await getPage()).waitForTimeout(900);   // a new title rises once the old one has gone
    assert.ok((await rect('.ws-title')).b <= (await rect('.cd-wrap')).t + 1, 'content starts below the title moved by a top-corner frame');
    await showSlide({ layout: 'summary', items: ['а', 'б', 'в', 'г', 'д', 'е'], next: 'Дальше по плану', steps: [{ show: 'all' }],
      theme: { frame: { logo: logo, number: true } } }, fast);
    assert.ok((await rect('.sm-box')).b <= (await rect('.sm-next')).t + 1, 'summary: the list ends above the next card');
    await showSlide({ layout: 'cards', cards: [{ text: 'Карточка без заголовка с длинным текстом, который тянется до правого края', status: 'ok' }], steps: [{ show: 'all' }] }, fast);
    assert.ok((await rect('.cd-card p')).r <= (await rect('.cd-card .ws-st-ic')).l + 1, 'a status mark does not cover a card text');
    // a backdrop under the frame is meant: not flagged
    const back = await showSlide({ html: '<div class="bg" style="position:absolute;inset:0;background:#223"></div><div class="mid" style="position:absolute;left:600px;top:500px;font-size:40px">Середина</div>',
      theme: { frame: { logo: logo, number: true } }, steps: [{ show: '.mid' }] }, fast);
    assert.ok(!(back.warnings || []).some((w) => w.includes('overlaps the frame')), `a full-bleed backdrop is not flagged (${JSON.stringify(back.warnings || [])})`);
    // an own page drawing under the frame is flagged
    const own = await showSlide({ html: '<div class="low" style="position:absolute;left:40px;bottom:30px;font-size:30px">Низ кадра</div>',
      theme: { frame: { number: { at: 'bottom-left' } } }, steps: [{ show: '.low' }] }, fast);
    assert.ok((own.warnings || []).some((w) => w.includes('.low overlaps the frame')), 'overlap flagged');
    await hideSlide({ motion: false });
  });

  await step('checks: a long radial centre fits its circle; text spilling out of a card is flagged', async () => {
    const r = await showSlide({
      layout: 'radial', center: { title: 'Учёт заказов клиентов и оплат', items: ['Статусы', 'Сроки'] },
      cards: [{ title: 'А' }, { title: 'Б' }, { title: 'В' }], steps: [{ show: 'all' }],
    }, fast);
    assert.ok(!(r.warnings || []).some((x) => x.includes('hb-in')), `radial centre fits (${JSON.stringify(r.warnings || [])})`);
    const s = await showSlide({
      html: '<div class="box" style="position:absolute;left:200px;top:300px;width:220px;padding:16px;background:#fff;border-radius:12px;font-size:40px">Специализированная</div>',
      steps: [{ show: '.box' }],
    }, fast);
    log(`spill: ${JSON.stringify(s.warnings || [])}`);
    assert.ok((s.warnings || []).some((x) => x.includes('.box text spills out of its box')), 'spill flagged');
  });

  await step('theme fonts: files from the project load into the page once; a missing file fails before the recording', async () => {
    const sys = ['C:/Windows/Fonts/arial.ttf', '/System/Library/Fonts/Supplemental/Arial.ttf', '/Library/Fonts/Arial.ttf'].find((f) => fs.existsSync(f));
    if (!sys) { log('no system TTF to copy — skipped'); return; }
    fs.copyFileSync(sys, `${dir}/test-font.ttf`);
    const theme = { fonts: [{ family: 'WsTestFont', src: `${dir}/test-font.ttf`, weight: 400 }] };
    await showSlide({ layout: 'statement', text: 'Шрифт из файла', theme }, fast);
    const st = await shadow(() => ({
      loaded: document.fonts.check('40px WsTestFont'),
      font: getComputedStyle(document.getElementById('__ws_slide').shadowRoot.querySelector('.st-text')).fontFamily,
      keys: Object.keys(document.__wsFonts || {}).length,
    }));
    log(`fonts: ${JSON.stringify(st)}`);
    assert.ok(st.loaded, 'the face is registered on the document');
    assert.ok(st.font.includes('WsTestFont'), 'the theme font stack starts with it');
    await showSlide({ layout: 'statement', text: 'Ещё раз', theme }, fast);
    assert.equal(await shadow(() => Object.keys(document.__wsFonts || {}).length), st.keys, 'sent once per page');
    await rejectsWith(() => prepareSlides([{ layout: 'statement', text: 'А', theme: { fonts: [{ family: 'X', src: `${dir}/none.ttf` }] } }], { validateOnly: true }),
      /font file not found/, 'a missing font file');
    const { ttsCacheFile, DEFAULT_VOICE } = await import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/engine/recording/tts.mjs')).href);
    assert.equal(ttsCacheFile('фраза', {}), ttsCacheFile('фраза', { provider: 'edge', voice: DEFAULT_VOICE.edge }),
      'TTS cache: no voice and the default voice are one phrase');
    await hideSlide({ motion: false });
  });

  await step('headingWeight: the big headings take the theme weight (default 800); a wrong one fails before the recording', async () => {
    const weights = () => shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot, w = (sel) => getComputedStyle(r.querySelector(sel)).fontWeight;
      return { title: w('.ws-title'), card: w('.cd-card h3') };
    });
    const spec = { layout: 'cards', title: 'Заголовок', cards: [{ title: 'А' }, { title: 'Б' }], steps: [{ show: 'all' }] };
    await showSlide(spec, fast);
    const def = await weights();
    await showSlide({ ...spec, theme: { headingWeight: 700 } }, fast);
    const bold = await weights();
    log(`heading weights: default ${JSON.stringify(def)}, 700 ${JSON.stringify(bold)}`);
    assert.equal(def.title, '800', 'default 800');
    assert.equal(bold.title, '700', 'headingWeight: 700');
    assert.equal(bold.card, def.card, 'card headings keep their weight');
    await rejectsWith(() => prepareSlides([{ ...spec, theme: { headingWeight: 750 } }], { validateOnly: true }),
      /headingWeight.*100\.\.900/, 'a weight off the scale');
    await hideSlide({ motion: false });
  });

  await step("the slide takes nothing from the page: its language (a font's local letter forms) and its text styles", async () => {
    const was = await shadow(() => {
      const h = document.documentElement, was = { lang: h.getAttribute('lang'), style: h.getAttribute('style') };
      h.lang = 'bg';   // Montserrat draws Bulgarian Cyrillic under lang="bg"
      h.style.cssText += ';font-feature-settings:"smcp";letter-spacing:7px;color:rgb(255, 0, 0)';
      return was;
    });
    try {
      await showSlide({ layout: 'statement', text: 'Какие сведения использует анализ' }, fast);
      const st = await shadow(() => {
        const t = document.getElementById('__ws_slide').shadowRoot.querySelector('.st-text'), cs = getComputedStyle(t);
        return { bg: t.matches(':lang(bg)'), features: cs.fontFeatureSettings, spacing: cs.letterSpacing, color: cs.color };
      });
      log(`on a lang=bg page: ${JSON.stringify(st)}`);
      assert.equal(st.bg, false, 'not in the page language');
      assert.equal(st.features, 'normal', 'no font features of the page');
      assert.notEqual(st.spacing, '7px', 'no letter spacing of the page');
      assert.notEqual(st.color, 'rgb(255, 0, 0)', 'no colour of the page');
    } finally {
      await hideSlide({ motion: false });
      await shadow((was) => {
        const h = document.documentElement;
        if (was.lang === null) h.removeAttribute('lang'); else h.lang = was.lang;
        if (was.style === null) h.removeAttribute('style'); else h.setAttribute('style', was.style);
      }, was);
    }
  });

  await step('page script: ready before the first step, hears steps, loads project files, cleans up', async () => {
    fs.writeFileSync(`${dir}/mod-b.mjs`, "export const b = 'B';\n");
    fs.writeFileSync(`${dir}/mod-a.mjs`, "import { b } from './mod-b.mjs';\nexport const a = 'A' + b;\n");
    fs.writeFileSync(`${dir}/lib.js`, "window.__wsTestLib = 'L';\n");
    fs.writeFileSync(`${dir}/dep.mjs`, "export const d = 'D';\n");
    fs.writeFileSync(`${dir}/bare.mjs`, "import { d } from 'wsdep';\nexport const v = d;\n");
    fs.writeFileSync(`${dir}/pic.png`, await screenshot());
    await shadow(() => { window.__wsDisposed = 0; });
    await showSlide({
      html: '<div class="out" style="position:absolute;left:200px;top:200px;font-size:40px"></div>'
        + '<img class="pic" src="asset:test-tmp/slides/pic.png" style="position:absolute;left:900px;top:300px;width:400px">',
      background: 'url(asset:test-tmp/slides/pic.png) center/cover',
      // written without a space after async: must not be taken for method shorthand
      script: async(slide)=>{
        const out = slide.$('.out');
        const { a } = await slide.import('test-tmp/slides/mod-a.mjs');   // its relative import is served too
        await slide.load('test-tmp/slides/lib.js');
        slide.importMap({ wsdep: 'test-tmp/slides/dep.mjs' });
        const { v } = await slide.import('test-tmp/slides/bare.mjs');   // a bare name through the import map
        out.dataset.mod = a + window.__wsTestLib + v;
        out.dataset.accent = slide.theme.accent;
        slide.on('step', (i) => { out.textContent += i; });
        return () => { window.__wsDisposed++; };
      },
      steps: [{ hold: 0 }, { hold: 0 }, { hold: 0 }],
    }, fast);
    const st = await shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot, out = r.querySelector('.out'), img = r.querySelector('.pic');
      const bg = getComputedStyle(r.querySelector('.ws-bg')).backgroundImage;
      return { text: out.textContent, mod: out.dataset.mod, accent: out.dataset.accent, src: img.src, w: img.naturalWidth, bg };
    });
    log(`script state: ${JSON.stringify({ ...st, src: st.src.slice(0, 60), bg: st.bg.slice(0, 60) })}`);
    assert.equal(st.text, '012', 'every step heard, from the first');
    assert.equal(st.mod, 'ABLD', 'slide.import (relative and bare imports) and slide.load');
    assert.equal(st.accent, '#f0a202', 'slide.theme');
    assert.ok(st.src.startsWith('https://ws-assets.invalid/') && st.w > 0, 'asset: in html is served');
    assert.ok(st.bg.includes('ws-assets.invalid'), 'asset: in background');
    const probe = await shadow(async () => {
      const status = async (u) => (await fetch('https://ws-assets.invalid/' + u)).status;
      const part = await fetch('https://ws-assets.invalid/test-tmp/slides/lib.js', { headers: { Range: 'bytes=0-9' } });
      return {
        up: await status('%2E%2E%2Fpackage.json'), drive: await status('C%3A%2FWindows%2Fwin.ini'),
        hidden: await status('.v8-project.json'), git: await status('.git%2FHEAD'),
        range: [part.status, (await part.text()).length],
      };
    });
    log(`asset probes: ${JSON.stringify(probe)}`);
    assert.deepEqual([probe.up, probe.drive, probe.hidden, probe.git], [404, 404, 404, 404],
      'nothing outside the project root, on another drive, or hidden');
    assert.deepEqual(probe.range, [206, 10], 'a Range request is answered with a part');
    await hideSlide();
    assert.equal(await shadow(() => window.__wsDisposed), 1, 'cleanup on hideSlide');
    const after = await shadow(async () => {
      try { await fetch('https://ws-assets.invalid/test-tmp/slides/lib.js'); return 'served'; } catch { return 'off'; }
    });
    assert.equal(after, 'off', 'project files are not served once the slide is gone (browser cache back on)');
  });

  await step('page script: an error stops the slide with a clear message; a wrong script field is a spec error', async () => {
    await rejectsWith(() => showSlide({ html: '<div></div>', script: () => { throw new Error('boom'); } }, fast),
      /slide script failed: .*boom/, 'script error');
    await hideSlide({ motion: false });
    await rejectsWith(() => prepareSlides([{ html: '<div></div>', script: 42 }], { validateOnly: true }), /"script" must be/, 'type');
    await rejectsWith(() => prepareSlides([{ html: '<div></div>', script: 'test-tmp/slides/none.js' }], { validateOnly: true }),
      /script not found/, 'missing file');
  });

  await step('speech check: Latin words and abbreviations are flagged, speech written as spoken is not', async () => {
    const bad = await showSlide({ layout: 'statement', text: 'Живая 1С', speech: 'Живая 1С и голос OpenAI' }, fast);
    const w = (bad.warnings || []).find((x) => /speech has/.test(x)) || '';
    log(`warning: ${w}`);
    assert.ok(w.includes('"1С"') && w.includes('"OpenAI"'), 'both words named');
    const good = await showSlide({ layout: 'statement', text: 'Живая 1С', speech: 'Живая один эс и голос опен эй ай' }, fast);
    assert.ok(!(good.warnings || []).some((x) => /speech has/.test(x)), 'no warning for speech written as spoken (screen text is not checked)');
  });

  await step('recording: one caption per spoken step, at increasing times; the first slide starts at once', async () => {
    const video = path.join(dir, 'slides.mp4');
    const agenda = { layout: 'agenda', items: ['Раз', 'Два', 'Три'], current: 1, speech: 'Второй раздел.' };
    const cards = { layout: 'cards', cards: [{ title: 'А' }, { title: 'Б' }], steps: [{ show: 0, speech: 'Первая.' }, { show: 1, speech: 'Вторая.' }] };
    // no TTS service in the regress: phrase lengths are estimated (synth: false), narration is not built
    const tts = { synth: false };
    const prep = await prepareSlides([agenda, cards], { validateOnly: true });
    assert.equal(prep.slides, 2, 'both specs valid');
    await hideSlide({ motion: false });
    await startRecording(video, { fps: 15 });
    await showSlide(agenda, tts);
    const firstFade = await shadow(() => document.getElementById('__ws_slide').style.transition);
    await showSlide(cards, tts);
    const res = await stopRecording();
    const caps = getCaptions();
    log(`captions: ${JSON.stringify(caps.map((c) => [c.text, c.time]))}`);
    assert.equal(firstFade, '', 'first slide after startRecording is mounted without a fade-in');
    assert.equal(caps.length, 3, 'one caption per spoken step');
    assert.deepEqual(caps.map((c) => c.text), ['Второй раздел.', 'Первая.', 'Вторая.']);
    assert.ok(caps[1].time > caps[0].time && caps[2].time > caps[1].time, 'times increase');
    assert.ok(caps[2].time - caps[1].time >= 1000, 'a step lasts at least its phrase');
    assert.ok(fs.existsSync(res.file) && res.size > 10000, 'video written');
  });

  await step('music: stretches and seams; slide music and withMusic are recorded; mixed without speech', async () => {
    const lib = (f) => import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/engine/recording', f)).href);
    const M = await lib('music.mjs');
    const c = (s, e, music, depth = 0) => ({ start: s * 1000, end: e * 1000, music, mode: 'duck', depth });
    const segs = (cues, base) => M.musicIntervals(cues, base, 30)
      .map((x) => [x.music, x.mode, x.segs.map(([a, b]) => [Math.round(a), Math.round(b)])]);
    assert.deepEqual(segs([c(0, 10, 'bright'), c(10, 20, 'bright')]), [['bright', 'duck', [[0, 20]]]], 'one music in a row flows on');
    assert.deepEqual(segs([c(0, 10, 'bright'), c(12, 20, 'bright')]), [['bright', 'duck', [[0, 20]]]], 'a short gap is bridged');
    assert.deepEqual(segs([c(0, 10, 'bright'), c(15, 20, 'bright')]), [['bright', 'duck', [[0, 10], [15, 20]]]], 'a long gap is kept');
    assert.deepEqual(segs([c(0, 10, 'bright'), c(10, 20, 'calm')]),
      [['bright', 'duck', [[0, 10]]], ['calm', 'duck', [[10, 20]]]], 'different music: two tracks (cross-fade)');
    assert.deepEqual(segs([c(0, 30, 'bright'), c(10, 20, 'focus', 1)]),
      [['bright', 'duck', [[0, 10], [20, 30]]], ['focus', 'duck', [[10, 20]]]], 'the inner stretch wins');
    assert.deepEqual(segs([c(0, 30, 'bright'), c(10, 12, 'focus', 1)]),
      [['bright', 'duck', [[0, 10], [12, 30]]], ['focus', 'duck', [[10, 12]]]], 'no bridge over a short inner stretch of other music');
    const edges = M.trapezoids([[0, 10]], 2, { D: 10 });
    assert.ok(edges.includes('(t-(0.000))') && edges.includes('(10.000-t)'), 'at the video start and end the music fades from/to silence');
    assert.deepEqual(segs([c(10, 20, 'bright')], 'warm'),
      [['warm', 'gaps', [[0, 10], [20, 30]]], ['bright', 'duck', [[10, 20]]]], 'whole-video music around a slide with its own');
    assert.deepEqual(M.speechGaps([[1, 4], [5, 9], [15, 18]], 25), [[0, 1], [9, 15], [18, 25]], 'pauses of 3 s and more, start and end');
    assert.deepEqual(M.speechGaps([[1, 4], [5, 9]], 12), [[0, 1]], 'a short closing pause does not open the music');
    assert.deepEqual(M.speechGaps([], 4), [[0, 4]], 'no speech: the music plays throughout');
    const tailEnv = M.trackEnvelope({ mode: 'gaps', segs: [[0, 12]] }, [[0, 1]], 12, 3);
    assert.ok(tailEnv.includes('(12.000-t)/3)'), `it fades out over the closing pause (${tailEnv})`);
    assert.ok(M.trackEnvelope({ mode: 'duck', segs: [[0, 30]] }, [], 30, 20).includes('(30.000-t)/3)'), 'after a long closing pause: a 3 s fade-out');
    const loop = M.renderPreset('bright');
    assert.ok(Math.abs(loop.seconds - 19.2) < 0.01 && Math.abs(loop.pcm[0] - loop.pcm[loop.pcm.length - 2]) < 300, 'a seamless loop');
    await rejectsWith(() => showSlide({ layout: 'statement', text: 'А', music: 'no-such-preset' }, fast), /music:/, 'a wrong music spec');

    const video = path.join(dir, 'music.mp4');
    await hideSlide({ motion: false });
    await startRecording(video, { fps: 15 });
    await showSlide({ layout: 'statement', text: 'С музыкой', music: 'bright' }, { ...fast, fast: 1.5 });
    await showSlide({ layout: 'statement', text: 'Без музыки' }, { ...fast, fast: 1.5 });
    await withMusic('focus', async () => { await (await getPage()).waitForTimeout(1500); });
    const res = await stopRecording();
    await hideSlide({ motion: false });
    const saved = JSON.parse(fs.readFileSync(video.replace(/\.mp4$/, '.captions.json'), 'utf8')).music;
    log(`music stretches: ${JSON.stringify(saved)}`);
    assert.equal(res.music, 2, 'two stretches recorded');
    assert.deepEqual(saved.map((m) => m.music), ['bright', 'focus']);
    assert.ok(saved.every((m) => m.end > m.start) && saved[1].start >= saved[0].end, 'the slide stretch ends where the next slide begins');

    // music alone (no speech, no TTS service): it sounds inside its stretch
    const out = path.join(dir, 'music-mixed.mp4');
    await addNarration(video, { captions: [], outputPath: out });
    const { resolveFfmpeg } = await lib('tts.mjs');
    const { spawnSync } = await import('child_process');
    const peak = (from, to) => {
      const r = spawnSync(resolveFfmpeg(), ['-hide_banner', '-ss', String(from), '-to', String(to), '-i', out,
        '-af', 'volumedetect', '-f', 'null', '-'], { encoding: 'utf8' });
      const m = /max_volume: (-?[\d.]+|-inf) dB/.exec(r.stderr || '');
      return !m || m[1] === '-inf' ? -99 : +m[1];
    };
    const mid = (saved[0].start + saved[0].end) / 2000;
    const inSlide = peak(mid - 0.3, mid + 0.3);
    log(`mixed: peak in the slide stretch ${inSlide} dB`);
    assert.ok(inSlide > -50, 'music sounds in the slide stretch');
    // another video does not get this recording's music stretches (slides.mp4: no music, no speech asked)
    await rejectsWith(() => addNarration(path.join(dir, 'slides.mp4'), { captions: [], outputPath: path.join(dir, 'other.mp4') }),
      /No captions available/, 'music of the last recording stays with its own video');
    // the whole-video music is remembered next to the video for a later re-narration
    await addNarration(video, { captions: [], outputPath: out, music: 'calm' });
    const kept = JSON.parse(fs.readFileSync(video.replace(/\.mp4$/, '.captions.json'), 'utf8'));
    assert.equal(kept.musicBase, 'calm', 'musicBase saved in .captions.json');
    assert.equal(kept.music.length, 2, 'stretches kept');
  });

  await step('legacy: showTitleSlide({ speech: true }) narrates the title text (line breaks → spaces)', async () => {
    await startRecording(path.join(dir, 'legacy.mp4'), { fps: 15 });
    await showTitleSlide('Титул\nвторая строка', { speech: true });
    await hideTitleSlide();
    await stopRecording();
    assert.deepEqual(getCaptions().map((c) => c.speech), ['Титул вторая строка']);
  });

  await step('--no-record: showSlide draws the slide quickly, no TTS; prepareSlides only validates', async () => {
    const { buildContext } = await import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/cli/exec-context.mjs')).href);
    const ctx = buildContext({ noRecord: true });
    const spec = { layout: 'cards', cards: [{ title: 'А' }, { title: 'Б' }],
      steps: [{ show: 0, speech: 'Фраза, которую никто не синтезирует.' }, { show: 1, speech: 'И эту тоже.' }] };
    const prep = await ctx.prepareSlides([spec]);
    assert.equal(prep.phrases, 0, 'nothing synthesized');
    const t0 = Date.now();
    await ctx.showSlide(spec);
    const ms = Date.now() - t0;
    log(`no-record showSlide: ${ms} ms`);
    assert.ok(ms < 4000, `quick (${ms} ms)`);
    assert.ok((await slideState()).on.includes('cd-1'), 'slide drawn to the end');
    await hideSlide({ motion: false });
  });

  await step('image: camera on a region, numbered callouts; motion:false is static; hideSlide removes', async () => {
    const img = path.join(dir, 'shot.png');
    fs.writeFileSync(img, await screenshot());
    await showSlide({
      layout: 'image', src: img,
      steps: [{ region: [0, 0, 300, 200] }, { callout: { at: [100, 100], label: 'Метка' } }],
    }, { ...fast, onStep: async (i) => {
      if (i === 0) {
        const cam = await shadow(() => document.getElementById('__ws_slide').shadowRoot.querySelector('.ws-cam').style.transform);
        assert.ok(/scale\(/.test(cam), `camera zoomed on the region (${cam})`);
      }
    } });
    const st = await slideState();
    assert.ok(st.on.includes('im-co'), 'callout shown');
    await showSlide({ layout: 'statement', text: 'Статично' }, { ...fast, motion: false });
    assert.equal((await slideState()).static, true, 'motion:false → static slide');
    await hideSlide({ motion: false });
    assert.equal(await slideState(), null, 'hideSlide removed the slide');
  });

  await step('addresses: verbs by address, points one by one, status on the way, marks and a banner, camera fill; errors list the addresses', async () => {
    const look = () => shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot;
      const cls = (sel) => [...(r.querySelector(sel)?.classList || [])];
      const box = (sel) => { const b = r.querySelector(sel)?.getBoundingClientRect(); return b ? { l: b.left, t: b.top, r: b.right, b: b.bottom } : null; };
      return {
        i0: cls('.cd-0 .ws-i0'), i1: cls('.cd-0 .ws-i1'), c0: cls('.cd-0'), c1: cls('.cd-1'), c2: cls('.cd-2'),
        ic2: getComputedStyle(r.querySelector('.cd-2 .ws-st-ic'), '::before').content,
        grp: box('.mk-grp'), note: box('.mk-note'), foot: box('.mk-foot'), b0: box('.cd-0'), b1: box('.cd-1'), b2: box('.cd-2'), wrap: box('.cd-wrap'),
      };
    });
    const states = [];
    const spec = {
      layout: 'cards', title: 'Адреса', columns: 3,
      cards: [{ title: 'А', items: ['а1', 'а2', 'а3'] }, { title: 'Б' }, { title: 'В', status: 'ok' }],
      marks: { grp: { frame: [0, 1], label: 'Группа' }, note: { callout: 2, label: 'Выноска' }, foot: { banner: 'Баннер внизу кадра' } },
      steps: [
        { show: 0 },                                        // the card, its points not yet
        { show: { block: 0, item: 0 } },                    // a point, lit
        { show: [1, 2], dim: { block: 0, item: 0 } },       // two cards; a point dimmed by address
        { status: { off: 1, warn: 2 } },                    // statuses on the way
        { show: { mark: 'grp' } },
        { show: { mark: 'note' }, focus: null },
      ],
    };
    const r = await showSlide(spec, { ...fast, onStep: async (i) => { states[i] = await look(); } });
    const end = await look();
    log(`addresses: ${JSON.stringify(r.addresses)} warnings: ${JSON.stringify(r.warnings || [])}`);
    assert.ok(states[0].c0.includes('on') && states[0].i0.includes('ws-pending') && !states[0].i0.includes('on'), 'a card shown first, its points wait');
    assert.ok(states[1].i0.includes('on') && states[1].i0.includes('ws-focus') && !states[1].i1.includes('on'), 'a point by address: shown and lit, the next waits');
    assert.ok(states[2].i0.includes('ws-dim'), 'dim by address');
    assert.ok(states[3].c1.includes('ws-st-off') && states[3].c2.includes('ws-st-warn') && !states[3].c2.includes('ws-st-ok'), 'status changed on the way');
    assert.equal(states[3].ic2, '"?"', 'the mark follows the new status');
    assert.ok(end.i1.includes('on') && end.c1.includes('ws-st-off'), 'the end shows the points left; statuses stay');
    const inside = (a, b) => a.l <= b.l && a.t <= b.t && a.r >= b.r && a.b >= b.b;
    assert.ok(inside(end.grp, end.b0) && inside(end.grp, end.b1) && !inside(end.grp, end.b2), 'the frame goes round its two cards');
    assert.ok(end.note.b <= end.b2.t + 1 && end.note.l < end.b2.r && end.note.r > end.b2.l, 'the callout stands above its card');
    assert.ok(end.wrap.b <= end.foot.t + 1, 'the content lays out above the banner');
    assert.ok(!(r.warnings || []).some((w) => /outside|spills|does not fit/.test(w)), 'no layout warnings');
    for (const a of ["0 «А»", "{ block: 0, item: 2 } «а3»", "{ mark: 'grp' } «Группа»"]) assert.ok(r.addresses.includes(a), `address listed: ${a}`);

    // camera fill: a card's picture takes the whole frame, the push stops
    const img = path.join(dir, 'fill.png');
    fs.writeFileSync(img, await screenshot());
    await showSlide({ layout: 'cards', title: 'Экран', lead: { title: 'Платформа', text: 'Работа с ИИ' }, cards: [{ title: 'Окно', image: img }],
      steps: [{ show: 'lead' }, { show: 0 }, { camera: { to: 0, fill: true } }] }, fast);
    await (await getPage()).waitForTimeout(3200);   // the card settles, then the camera moves (1.4 s)
    const fill = await shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot;
      const st = r.querySelector('.ws-stage').getBoundingClientRect(), im = r.querySelector('.cd-0 .ws-img').getBoundingClientRect();
      return { filled: r.querySelector('.ws-slide').classList.contains('ws-filled'), dl: im.left - st.left, dt: im.top - st.top, dr: im.right - st.right, db: im.bottom - st.bottom,
        radius: getComputedStyle(r.querySelector('.cd-0 .ws-img')).borderTopLeftRadius,
        titleOut: !r.querySelector('.ws-push .ws-title') && !!r.querySelector('.ws-head .ws-title'), head: getComputedStyle(r.querySelector('.ws-head')).opacity };
    });
    log(`fill: ${JSON.stringify(fill)}`);
    assert.ok(fill.filled, 'the slide is marked filled (the frame fades)');
    assert.ok(fill.dl <= 2 && fill.dt <= 2 && fill.dr >= -2 && fill.db >= -2, `the picture covers the frame (${JSON.stringify(fill)})`);
    assert.equal(fill.radius, '0px', 'no rounding at full size');
    assert.ok(fill.titleOut, 'the title stands outside the push and the camera');
    assert.equal(fill.head, '0', 'a zoom puts the title aside');

    // the background: the whole window, in the slide's pixels (scaled with the slide)
    await showSlide({ layout: 'cards', title: 'Фон', cards: [{ title: 'А' }], steps: [{ show: 0 }], background: '#eef url(asset:test-tmp/slides/pic.png) no-repeat right 0 bottom 0 / 192px 108px' }, fast);
    const bgl = await shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot, b = r.querySelector('.ws-bg').getBoundingClientRect(), st = r.querySelector('.ws-stage').getBoundingClientRect();
      return { l: b.left, t: b.top, r: b.right - innerWidth, b: b.bottom - innerHeight, k: st.width / 1920, size: getComputedStyle(r.querySelector('.ws-bg')).backgroundSize };
    });
    log(`background: ${JSON.stringify(bgl)}`);
    assert.ok(Math.abs(bgl.l) < 1 && Math.abs(bgl.t) < 1 && Math.abs(bgl.r) < 1 && Math.abs(bgl.b) < 1, 'the background covers the window');
    assert.equal(bgl.size, '192px 108px', 'its sizes are in the slide\'s pixels (the layer scales with the slide)');

    // a slide change: the same title stays; another fades in on its place after the old one goes (no rise)
    const tt = () => shadow(() => {
      const t = document.getElementById('__ws_slide').shadowRoot.querySelector('.ws-head .ws-title');
      return { anim: t.style.animationName || t.style.animation, delay: getComputedStyle(t).transitionDelay };
    });
    await showSlide({ layout: 'cards', title: 'Один', cards: [{ title: 'А' }], steps: [{ show: 0 }] }, fast);
    await showSlide({ layout: 'cards', title: 'Один', cards: [{ title: 'Б' }], steps: [{ show: 0 }] }, fast);
    const same = await tt();
    await showSlide({ layout: 'cards', title: 'Два', cards: [{ title: 'В' }], steps: [{ show: 0 }] }, fast);
    const other = await tt();
    log(`titles: ${JSON.stringify({ same, other })}`);
    assert.equal(same.anim, 'none', 'the same title stays put');
    assert.ok(other.anim === 'none' && /0\.3s/.test(other.delay), `another title fades in after the old one goes, no rise (${JSON.stringify(other)})`);
    // a page of your own: the same
    await showSlide({ html: '<div class="ttl ws-title">Свой</div>', css: '.ttl{position:absolute;left:96px;top:52px;font-size:48px}', steps: [{ hold: 0.2 }] }, fast);
    const own = await shadow(() => getComputedStyle(document.getElementById('__ws_slide').shadowRoot.querySelector('.ws-head .ws-title')).transitionDelay);
    assert.ok(/0\.3s/.test(own), `an own page's title waits too (${own})`);

    // errors: the addresses come with them
    const v = (st) => prepareSlides([st], { validateOnly: true });
    await rejectsWith(() => v({ layout: 'cards', cards: [{ title: 'А' }], steps: [{ show: { block: 0, item: 0 } }] }), /0 has no items; addresses: 0 «А»/, 'a point of a block without points');
    await rejectsWith(() => v({ layout: 'cards', cards: [{ title: 'А', items: ['а'] }], steps: [{ status: { off: { block: 0, item: 0 } } }] }), /a status is a block's, not an item's/, 'no status on a point');
    await rejectsWith(() => v({ layout: 'flow', inputs: [{ title: 'А' }], center: { title: 'Ц' }, outputs: [{ title: 'Р' }], steps: [{ show: 'centre' }] }),
      /show "centre" — no such element; addresses: 'center' «Ц», \{ in: 0 \} «А», \{ out: 0 \} «Р»/, 'a typo in a key');
    await rejectsWith(() => v({ layout: 'cards', cards: [{ title: 'А' }], steps: [{ status: { done: 0 } }] }), /"done" — a status is ok, warn, off, optional, none/, 'a wrong status value');
    await rejectsWith(() => v({ layout: 'statement', text: 'Т', marks: { a: { banner: 'Б' } } }), /"marks" need a template with addresses/, 'marks on a template without addresses');
    await rejectsWith(() => v({ layout: 'cards', cards: [{ title: 'А' }], marks: { a: { callout: 0 } }, steps: [{ show: 0 }] }), /a callout needs a label/, 'a callout without a label');
    await rejectsWith(() => v({ layout: 'cards', cards: [{ title: 'А' }, { title: 'Б' }], steps: [{ show: 'all' }, { camera: { to: [0, 1], fill: true } }] }),
      /fill takes one element/, 'fill: one element');

    // a card hidden and shown again gets its line to the hub back; 'all' next to a named address keeps its light
    await showSlide({ layout: 'radial', center: { title: 'Ц' }, cards: [{ title: 'А' }, { title: 'Б' }, { title: 'В' }],
      steps: [{ show: ['center', 0] }, { hide: 0 }, { show: 0 }, { show: ['all', 1] }] }, { ...fast, onStep: async (i) => {
      if (i === 3) {
        const st = await shadow(() => {
          const r = document.getElementById('__ws_slide').shadowRoot;
          return { line: r.querySelector('.hb-l0').classList.contains('on'), lit: r.querySelector('.hb-c1').classList.contains('ws-focus') };
        });
        assert.ok(st.line, 'the line comes back with its card');
        assert.ok(st.lit, "show ['all', 1]: card 1 is lit");
      }
    } });
  });

  await step('layouts: process wraps into two rows (snake/bend), radial links 5 cards', async () => {
    const stages = [...Array(7)].map((_, i) => ({ title: `Этап ${i + 1}` }));
    await showSlide({ layout: 'process', stages, steps: [{ show: 'all' }] }, fast);
    const snake = await shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot;
      return { rows: r.querySelectorAll('.pr-row').length, rev: r.querySelectorAll('.pr-row.rev').length, turn: !!r.querySelector('.pr-turn') };
    });
    assert.deepEqual(snake, { rows: 2, rev: 1, turn: true }, 'snake: two rows, second reversed, turn arrow');
    await showSlide({ layout: 'process', stages, wrap: 'bend', steps: [{ show: 'all' }] }, fast);
    const bend = await shadow(() => {
      const r = document.getElementById('__ws_slide').shadowRoot;
      return { rev: r.querySelectorAll('.pr-row.rev').length, bend: !!r.querySelector('.pr-bend') };
    });
    assert.deepEqual(bend, { rev: 0, bend: true }, 'bend: both rows forward, bent arrow');
    await showSlide({
      layout: 'radial', center: { title: 'Ц' }, cards: [...Array(5)].map((_, i) => ({ title: `К${i + 1}` })), steps: [{ show: 'all' }],
    }, fast);
    const links = await shadow(() => [...document.getElementById('__ws_slide').shadowRoot.querySelectorAll('.ws-links path')]
      .map((p) => p.getAttribute('d') || ''));
    assert.equal(links.length, 5, 'a link per card');
    assert.ok(links.every((d) => /^M[\d.]+ [\d.]+ L[\d.]+ [\d.]+$/.test(d)), 'links laid out');
    await hideSlide({ motion: false });
  });

  await step('CLI: preview (PNG per step) and play (narrated video) without 1C', async () => {
    const run = (args) => JSON.parse(execFileSync(process.execPath, ['.claude/skills/web-test/scripts/run.mjs', ...args],
      { encoding: 'utf8', timeout: 180000 }));
    const pv = run(['preview', 'tests/web-test/_slides/fixture.mjs', `--out-dir=${dir}/preview`]);
    log(`preview: ${JSON.stringify(pv)}`);
    assert.equal(pv.ok, true);
    assert.equal(pv.shots, 5, 'title: 2 steps, cards: 2 + clear');
    assert.ok(fs.existsSync(path.join(dir, 'preview', '2-2.png')), 'step PNGs written');
    // --no-narration: no TTS service in the regress; the video and its captions are what play records
    const play = run(['play', 'tests/web-test/_slides/fixture.mjs', `--out=${dir}/play.mp4`, '--no-narration']);
    log(`play: ${JSON.stringify(play)}`);
    assert.equal(play.ok, true);
    assert.equal(play.captions, 3, 'a caption per spoken step');
    assert.ok(fs.existsSync(play.file) && play.duration > 3, 'video written');
    assert.ok(fs.existsSync(play.file.replace(/\.mp4$/, '.captions.json')), 'captions.json for a later addNarration');
    // --no-narration --music: the music alone — no speech synthesized for the spoken steps
    const withMusicOut = run(['play', 'tests/web-test/_slides/fixture.mjs', `--out=${dir}/play-music.mp4`, '--no-narration', '--music=calm']);
    assert.equal(withMusicOut.ok, true);
    const { resolveFfmpeg } = await import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/engine/recording/tts.mjs')).href);
    const { spawnSync } = await import('child_process');
    const det = spawnSync(resolveFfmpeg(), ['-hide_banner', '-i', withMusicOut.file, '-af', 'volumedetect', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
    const max = +(/max_volume: (-?[\d.]+) dB/.exec(det) || [0, -99])[1];
    log(`play --no-narration --music: max ${max} dB`);
    assert.ok(max > -40 && max < -15, 'music at its level, no voice (a voice peaks far louder)');
  });

  await step('one phrase, steps on its words (at): TTS word timings, the audio\'s pauses, an estimate; speak() on a live page', async () => {
    const { ttsCacheFile, wordsFileOf, resolveFfmpeg } = await import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/engine/recording/tts.mjs')).href);
    // a phrase in the TTS cache, made here (no TTS service in the regress): tones where words are, pauses between —
    // a comma pause 1.4–1.7 s, a sentence pause 2.6–3.4 s, sound ends at 4.6 s
    const speech = 'Раз два три, четыре пять. Шесть семь восемь.';
    const voiceMarks = 'ru-RU-WsAnchorMarksNeural', voiceAudio = 'ru-RU-WsAnchorAudioNeural', voiceNone = 'ru-RU-WsAnchorNoneNeural';
    const tone = (file) => execFileSync(resolveFfmpeg(), ['-y', '-v', 'error', '-f', 'lavfi', '-i',
      "aevalsrc='if(between(t,0.2,1.4)+between(t,1.7,2.6)+between(t,3.4,4.6),0.5*sin(2*PI*440*t),0)':s=24000:d=5",
      '-c:a', 'libmp3lame', '-b:a', '48k', file], { stdio: 'pipe' });
    const marksFile = ttsCacheFile(speech, { provider: 'edge', voice: voiceMarks });
    const audioFile = ttsCacheFile(speech, { provider: 'edge', voice: voiceAudio });
    fs.mkdirSync(path.dirname(marksFile), { recursive: true });
    tone(marksFile); tone(audioFile);
    for (const f of [audioFile, ttsCacheFile(speech, { provider: 'edge', voice: voiceNone })]) { try { fs.unlinkSync(wordsFileOf(f)); } catch { /* none */ } }
    try { fs.unlinkSync(ttsCacheFile(speech, { provider: 'edge', voice: voiceNone })); } catch { /* none */ }
    const W = [['Раз', 0.2], ['два', 0.6], ['три,', 1.0], ['четыре', 1.6], ['пять.', 2.1], ['Шесть', 3.3], ['семь', 3.7], ['восемь.', 4.1]];
    fs.writeFileSync(wordsFileOf(marksFile), JSON.stringify(W.map(([w, s], i) => ({ w, s, e: W[i + 1]?.[1] ?? 4.6 }))));

    const page = { html: '<div class="a">А</div><div class="b">Б</div><div class="c">В</div>',
      css: '.a,.b,.c{position:absolute;top:400px;font-size:60px}.a{left:300px}.b{left:900px}.c{left:1500px}', speech };
    // when each block really appears: the page polled while the slide plays (onStep reports a step once it settled)
    const play = async (steps, opts) => {
      await hideSlide({ motion: false });
      const seen = {}, reported = [];
      let stop = false;
      const watch = (async () => {
        while (!stop) {
          const st = await slideState().catch(() => null);
          const now = performance.now() / 1000;
          for (const c of st?.on || []) if (!(c in seen)) seen[c] = now;
          await new Promise((res) => setTimeout(res, 20));
        }
      })();
      const r = await showSlide({ ...page, steps }, { lint: 'collect', ...opts, onStep: (i) => { reported.push(i); } });
      stop = true;
      await watch;
      return { r, seen, reported };
    };
    const steps = [{ at: 'четыре', show: '.a' }, { at: 'Шесть', show: '.b' }, { at: 'end', show: '.c' }];

    // (a) the provider's word timings: the steps keep the marks' spacing
    const m = await play(steps, { provider: 'edge', voice: voiceMarks });
    const gap1 = m.seen.b - m.seen.a, gap2 = m.seen.c - m.seen.b;
    log(`marks: ${JSON.stringify(m.r.anchors)} gaps ${gap1.toFixed(2)} / ${gap2.toFixed(2)}`);
    assert.deepEqual(m.r.anchors.map((x) => x.by), ['marks', 'marks', 'marks'], 'times from the word timings');
    assert.deepEqual(m.r.anchors.map((x) => x.t), [1.6, 3.3, 4.6], 'the words\' starts, end = the last word\'s end');
    assert.ok(Math.abs(gap1 - 1.7) <= 0.15 && Math.abs(gap2 - 1.3) <= 0.15, 'each step on its word (±0.15 s)');
    assert.deepEqual(m.reported, [0, 1, 2], 'every step reported once it is over');
    assert.deepEqual((await slideState()).on.sort(), ['a', 'b', 'c'], 'all three shown');

    // (b) no word timings: the audio's pauses (a comma's pause, the sentence's pause)
    const a = await play([...steps.slice(0, 2), { at: 'семь', show: '.c' }], { provider: 'edge', voice: voiceAudio, synth: false });
    log(`audio: ${JSON.stringify(a.r.anchors)} ${JSON.stringify(a.r.warnings || [])}`);
    assert.deepEqual(a.r.anchors.map((x) => x.by), ['audio', 'audio', 'audio'], 'times from the audio');
    assert.ok(Math.abs(a.r.anchors[0].t - 1.6) <= 0.1 && Math.abs(a.r.anchors[1].t - 3.3) <= 0.1, 'after a comma / a full stop: the pause\'s end');
    assert.ok((a.r.warnings || []).some((w) => /"семь": timed from the audio roughly/.test(w)), 'a word mid-sentence: told it is rough');

    // (c) no audio at all (synth: false, not cached): an estimate, in order
    const e = await play(steps, { provider: 'edge', voice: voiceNone, synth: false, motion: false });
    assert.deepEqual(e.r.anchors.map((x) => x.by), ['estimate', 'estimate', 'estimate'], 'estimated');
    assert.ok(e.r.anchors[0].t < e.r.anchors[1].t && e.r.anchors[1].t <= e.r.anchors[2].t, 'in order');

    // (d) seconds and a shift; past the end — a warning
    const n = await play([{ at: 1, show: '.a' }, { at: { text: 'Шесть', shift: -0.2 }, show: '.b' }, { at: 6, show: '.c' }], { provider: 'edge', voice: voiceMarks, motion: false });
    assert.deepEqual(n.r.anchors.map((x) => [x.t, x.by]), [[1, 'manual'], [3.1, 'marks'], [6, 'manual']]);
    assert.ok((n.r.warnings || []).some((w) => /past the phrase's end/.test(w)), 'seconds past the end: a warning');
    await hideSlide({ motion: false });

    // (e) wrong specs fail before the recording
    const v = { validateOnly: true };
    await rejectsWith(() => prepareSlides([{ ...page, steps: [{ at: 'девять', show: '.a' }] }], v), /"девять" is not in the phrase/, 'a word not in the phrase');
    await rejectsWith(() => prepareSlides([{ ...page, steps: [{ at: 'Шесть', show: '.a' }, { at: 'четыре', show: '.b' }] }], v), /after the previous anchor/, 'anchors out of order');
    await rejectsWith(() => prepareSlides([{ ...page, steps: [{ at: 'Шесть', show: '.a', speech: 'ещё' }] }], v), /has its own "speech"/, 'a step\'s own speech');
    await rejectsWith(() => prepareSlides([{ ...page, speech: undefined, steps: [{ at: 'Шесть', show: '.a' }] }], v), /need the slide's "speech"/, 'no phrase');
    await rejectsWith(() => prepareSlides([{ layout: 'statement', text: 'А', speech, steps: [{ at: 'Шесть' }] }], v), /takes no steps/, 'a layout without steps');
    const ok = await prepareSlides([{ ...page, steps }, 'Фраза для speak.'], v);
    assert.equal(ok.slides, 1, 'a plain string is a phrase, not a slide');

    // (e2) marks as Edge gives them: a number glued to its word («2024 году,»), a word in pieces («т.» «е.»);
    // «т.е.» and a decimal comma do not end a sentence
    const { anchorTimes } = await import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/engine/recording/anchors.mjs')).href);
    const glued = anchorTimes('В 2024 году, т.е. сейчас, 3,5 тысячи.', ['году', 'т.е.', 'сейчас', 'тысячи'], {
      words: [{ w: 'В', s: 0.05, e: 0.2 }, { w: '2024 году,', s: 0.2, e: 1.8 }, { w: 'т.', s: 2.0, e: 2.1 }, { w: 'е.', s: 2.1, e: 2.2 },
        { w: 'сейчас,', s: 2.3, e: 2.9 }, { w: '3,5', s: 3.1, e: 4.2 }, { w: 'тысячи.', s: 4.25, e: 4.8 }],
    });
    log(`glued marks: ${JSON.stringify(glued.times)}`);
    assert.deepEqual(glued.times.map((x) => x.by), ['marks', 'marks', 'marks', 'marks'], 'every anchor from the marks');
    assert.ok(glued.times[0].t > 1.2 && glued.times[0].t < 1.8, 'a word inside a glued mark: counted back from its end');
    assert.deepEqual(glued.times.slice(1).map((x) => x.t), [2.0, 2.3, 4.25], 'a word in pieces — its first piece');

    // (f) speak on a live page: actions on the words (lead — before the word)
    const sp = await speak(speech, { provider: 'edge', voice: voiceMarks });
    const t0 = performance.now() / 1000;
    const r1 = await sp.at('четыре', { lead: 0.5 });
    const t1 = performance.now() / 1000;
    const r2 = await sp.at('end');
    const t2 = performance.now() / 1000;
    log(`speak: ${JSON.stringify([r1, r2])} at ${(t1 - t0).toFixed(2)} / ${(t2 - t0).toFixed(2)} s`);
    assert.equal(r1.by, 'marks');
    assert.ok(Math.abs((t1 - t0) - 1.1) <= 0.15 && Math.abs((t2 - t0) - 4.6) <= 0.15, 'waits for the word (minus lead) and for the end');
    let err = null;
    try { await sp.at('два'); } catch (x) { err = x; }
    assert.ok(err && /not in the phrase after the previous anchor/.test(err.message), 'speak: words in order');

    // (g) a word repeated in the phrase: each anchor its own occurrence; same: true — the word of the anchor before
    const { locateAnchors } = await import(pathToFileURL(path.resolve('.claude/skills/web-test/scripts/engine/recording/anchors.mjs')).href);
    const rep = 'Нажмите Далее, затем снова Далее.';
    assert.deepEqual(locateAnchors(rep, ['Далее', 'Далее']).map((x) => x.c), [8, 27], 'the next occurrence each time');
    assert.deepEqual(locateAnchors(rep, ['Далее', { text: 'Далее', same: true, shift: 0.2 }, 'Далее']).map((x) => x.c), [8, 8, 27], 'same: true — the same place');
    assert.throws(() => locateAnchors(rep, ['Нажмите', { text: 'Далее', same: true }]), /not the word of the anchor before/);

    // (h) a phrase the service gave no word timings for ([] kept): timed from its audio, not synthesized again
    const voiceEmpty = 'ru-RU-WsAnchorEmptyNeural';
    const emptyFile = ttsCacheFile(speech, { provider: 'edge', voice: voiceEmpty });
    tone(emptyFile);
    fs.writeFileSync(wordsFileOf(emptyFile), '[]');
    const em = await play(steps.slice(0, 2), { provider: 'edge', voice: voiceEmpty });   // synth allowed: a fake voice would fail
    assert.deepEqual(em.r.anchors.map((x) => x.by), ['audio', 'audio'], 'no timings — the audio, no new synthesis');
    await hideSlide({ motion: false });

    // (i) a speak() phrase not ended: the next voice waits for it (two voices never overlap)
    await startRecording(`${dir}/overlap.mp4`);
    const tS = performance.now() / 1000;
    await speak(speech, { provider: 'edge', voice: voiceMarks });
    await showCaption('', { speech: 'Дальше.' });
    const waited = performance.now() / 1000 - tS;
    const caps = getCaptions();
    await stopRecording();
    log(`overlap: waited ${waited.toFixed(2)} s, captions at ${caps.map((c) => c.time).join(', ')}`);
    assert.ok(caps.length === 2 && caps[1].time - caps[0].time >= 4600, 'the next caption after the phrase\'s end (4.6 s)');
  });
}
