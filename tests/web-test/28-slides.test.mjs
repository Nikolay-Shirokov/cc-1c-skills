export const name = 'slides: showSlide templates, steps, captions, theme, layouts, legacy, --no-record, play/preview (no TTS service)';
export const tags = ['recording'];
export const timeout = 240000;

// Read-only on the stand: slides are overlays over the current page, nothing is written to 1C.
export default async function({
  showSlide, hideSlide, prepareSlides, setSlideTheme, showTitleSlide, hideTitleSlide,
  startRecording, stopRecording, getCaptions, screenshot, getPage, withMusic, addNarration,
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
    const keyInArray = { layout: 'radial', center: { title: 'Ц' }, cards: [{ title: 'А' }, { title: 'Б' }, { title: 'В' }], steps: [{ show: ['center', 0] }] };
    await rejectsWith(() => prepareSlides([keyInArray], { validateOnly: true }), /on its own, not in an array/, 'a key inside a show array');
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
      const bg = getComputedStyle(r.querySelector('.ws-slide')).backgroundImage;
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
}
