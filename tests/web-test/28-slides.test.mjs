export const name = 'slides: showSlide templates, steps, captions, theme, layouts, legacy, --no-record, play/preview (no TTS service)';
export const tags = ['recording'];
export const timeout = 240000;

// Read-only on the stand: slides are overlays over the current page, nothing is written to 1C.
export default async function({
  showSlide, hideSlide, prepareSlides, setSlideTheme, showTitleSlide, hideTitleSlide,
  startRecording, stopRecording, getCaptions, screenshot, getPage,
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
    await rejectsWith(() => showSlide(badShow, fast), /step 1: show 3/, 'show index out of range');
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
  });
}
