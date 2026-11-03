export const name = 'recording: video, captions, TTS narration, overlays (legacy title/image, highlight)';
export const tags = ['recording'];
export const timeout = 120000;

export default async function({
  navigateSection, openCommand, closeForm,
  startRecording, stopRecording, showCaption, hideCaption, getCaptions, addNarration,
  isRecording,
  showTitleSlide, hideTitleSlide, showImage, hideImage,
  setHighlight, isHighlightMode, highlight, unhighlight,
  screenshot, getPage,
  wait, assert, step, log
}) {
  const fs = await import('fs');
  const path = await import('path');

  const overlayIds = async () => {
    const p = await getPage();
    return p.evaluate(() => [...document.body.children]
      .filter(c => c.id && c.id.startsWith('__web_test')).map(c => c.id));
  };

  const dir = 'test-tmp/recording-smoke';
  const videoPath = path.join(dir, 'smoke.mp4');
  const captionsJson = path.join(dir, 'smoke.captions.json');
  const narratedPath = path.join(dir, 'smoke-narrated.mp4');

  // Idempotent: убрать артефакты прошлого прогона
  for (const f of [videoPath, captionsJson, narratedPath]) {
    try { fs.unlinkSync(f); } catch {}
  }

  await step('record + captions: startRecording → showCaption ×2 → stopRecording', async () => {
    await startRecording(videoPath, { fps: 15 });
    assert.equal(isRecording(), true, 'isRecording=true пока идёт запись');

    await showCaption('Открываем Контрагентов');
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await wait(1);
    await hideCaption();

    await showCaption('Закрываем форму');
    await closeForm();
    await wait(1);
    await hideCaption();

    const result = await stopRecording();
    log(`stop result: file=${path.basename(result.file)} duration=${result.duration}s size=${result.size}B captions=${result.captions}`);
    assert.equal(isRecording(), false, 'isRecording=false после stopRecording');
    assert.equal(result.captions, 2, 'два collected caption');
    assert.ok(result.duration >= 3, `duration >= 3s (got ${result.duration})`);
    assert.ok(result.size > 10000, `mp4 размер > 10KB (got ${result.size})`);
    assert.ok(fs.existsSync(result.file), 'mp4 файл создан на диске');
    assert.ok(fs.existsSync(captionsJson), '.captions.json создан рядом с mp4');

    const captions = getCaptions();
    assert.equal(captions.length, 2, 'getCaptions() возвращает 2 записи');
    assert.equal(captions[0].text, 'Открываем Контрагентов', 'текст первой подписи');
    assert.equal(captions[1].text, 'Закрываем форму', 'текст второй подписи');
    assert.ok(captions[1].time > captions[0].time, 'time второй подписи > первой');
  });

  await step('narration: addNarration генерирует mp4 со звуковой дорожкой через edge TTS', async () => {
    assert.ok(fs.existsSync(videoPath), 'исходный mp4 должен существовать');
    const result = await addNarration(videoPath, { provider: 'edge', voice: 'ru-RU-DmitryNeural' });
    log(`narration: file=${path.basename(result.file)} duration=${result.duration}s size=${result.size}B captions=${result.captions}`);
    assert.equal(result.captions, 2, 'narration использовал 2 подписи');
    assert.ok(result.size > 10000, `narrated mp4 > 10KB (got ${result.size})`);
    assert.ok(fs.existsSync(result.file), 'narrated mp4 создан');
    // narrated.mp4 должен быть больше исходного (добавлен аудио-трек)
    const origSize = fs.statSync(videoPath).size;
    assert.ok(result.size > origSize, `narrated (${result.size}) > original (${origSize}) — добавлен аудио-трек`);
  });

  await step('title-slide: showTitleSlide создаёт fullscreen overlay, hideTitleSlide убирает', async () => {
    await showTitleSlide('Заголовок', { subtitle: 'подзаголовок' });
    const p = await getPage();
    const view = await p.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }));
    // legacy overlays are now static slides (showSlide host, marked with their kind)
    const overlays = await p.evaluate(() => [...document.querySelectorAll('#__ws_slide[data-kind="title"]')]
      .map(c => ({ id: c.id, w: c.offsetWidth, h: c.offsetHeight, text: c.shadowRoot.textContent })));
    log(`title overlays: ${JSON.stringify(overlays)}`);
    assert.equal(overlays.length, 1, 'один title overlay');
    assert.equal(overlays[0].w, view.w, 'overlay перекрывает всю ширину viewport');
    assert.equal(overlays[0].h, view.h, 'overlay перекрывает всю высоту viewport');
    assert.ok(overlays[0].text.includes('Заголовок') && overlays[0].text.includes('подзаголовок'), 'текст титула на месте');
    await hideTitleSlide();
    const after = await p.evaluate(() => !!document.getElementById('__ws_slide'));
    assert.equal(after, false, 'title overlay удалён');
  });

  await step('image-overlay: showImage создаёт overlay, hideImage убирает', async () => {
    // используем свежий screenshot как тестовую картинку
    const imgPath = path.join(dir, 'sample.png');
    const png = await screenshot();
    fs.writeFileSync(imgPath, png);
    await showImage(imgPath, { style: 'dark' });
    const p = await getPage();
    const overlays = await p.evaluate(() => [...document.querySelectorAll('#__ws_slide[data-kind="image"]')]
      .map(c => ({ id: c.id, w: c.offsetWidth, h: c.offsetHeight, imgs: c.shadowRoot.querySelectorAll('img').length })));
    log(`image overlays: ${JSON.stringify(overlays)}`);
    assert.equal(overlays.length, 1, 'один image overlay');
    assert.ok(overlays[0].w > 0 && overlays[0].h > 0, 'overlay имеет размер');
    assert.equal(overlays[0].imgs, 1, 'картинка без размытой подложки (style: dark)');
    await hideImage();
    const after = await p.evaluate(() => !!document.getElementById('__ws_slide'));
    assert.equal(after, false, 'image overlay удалён');
  });

  await step('highlight: setHighlight toggles isHighlightMode; manual highlight/unhighlight создают и убирают overlay', async () => {
    assert.equal(isHighlightMode(), false, 'highlight mode выключен по умолчанию');
    setHighlight(true);
    assert.equal(isHighlightMode(), true, 'после setHighlight(true) — включён');
    setHighlight(false);
    assert.equal(isHighlightMode(), false, 'после setHighlight(false) — выключен');

    // Manual highlight требует элемент на форме — откроем список
    await navigateSection('Склад');
    await openCommand('Контрагенты');
    await highlight('Создать');
    const p = await getPage();
    const overlays = await p.evaluate(() => [...document.body.children]
      .filter(c => c.id && c.id.startsWith('__web_test_highlight'))
      .map(c => ({ id: c.id, w: c.offsetWidth, h: c.offsetHeight })));
    log(`highlight overlays: ${JSON.stringify(overlays)}`);
    assert.equal(overlays.length, 1, 'один highlight overlay');
    assert.ok(overlays[0].w > 0 && overlays[0].h > 0, 'overlay позиционирован на элементе');
    await unhighlight();
    const after = await overlayIds();
    assert.ok(!after.includes('__web_test_highlight'), 'highlight overlay удалён');
    await closeForm();
  });

  // Длительность самого видео (ffprobe), а не stopRecording().duration: та считается по часам
  // и замедления видео не видит.
  const { resolveFfmpeg, getAudioDuration } = await import(
    new URL('../../.claude/skills/web-test/scripts/engine/recording/tts.mjs', import.meta.url));
  const videoSeconds = (file) => getAudioDuration(file, resolveFfmpeg());

  // Кадр нечетного размера (развернутое окно дает, например, 1920x945) гоним через тот же
  // конвейер ffmpeg без браузера: размер кадра screencast зависит от масштаба экрана, и
  // эмуляция окна на 125% дает четный кадр — такой шаг ничего бы не проверял.
  await step('odd frame: кадр нечетного размера кодируется, ffmpeg не падает', async () => {
    const { execFileSync, spawnSync } = await import('child_process');
    const { ffmpegEncodeArgs } = await import(
      new URL('../../.claude/skills/web-test/scripts/engine/recording/capture.mjs', import.meta.url));
    const ffmpegPath = resolveFfmpeg();
    const oddPath = path.resolve(dir, 'odd.mp4');
    try { fs.unlinkSync(oddPath); } catch {}
    // testsrc, а не однотонный color: крошечный однотонный JPEG image2pipe не распознает как mjpeg
    const jpeg = execFileSync(ffmpegPath, ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=101x51',
      '-frames:v', '1', '-f', 'image2pipe', '-c:v', 'mjpeg', '-']);
    const enc = spawnSync(ffmpegPath, ffmpegEncodeArgs(10, oddPath),
      { input: Buffer.concat(Array(20).fill(jpeg)), timeout: 30000 });
    const stderr = (enc.stderr?.toString() || '').split(/\r?\n/);
    const why = stderr.find(l => /divisible/i.test(l)) || stderr.filter(Boolean).slice(-3).join(' | ');
    assert.equal(enc.status, 0, `ffmpeg на кадре 101x51: ${why}`);
    const size = execFileSync(ffmpegPath.replace(/ffmpeg(\.exe)?$/i, 'ffprobe$1'), ['-v', 'error',
      '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', oddPath],
      { encoding: 'utf8' }).trim();
    log(`odd frame: ${size}, video=${videoSeconds(oddPath)}s`);
    assert.equal(size, '100,50', 'кадр обрезан до четного размера');
  });

  await step('frame grid: на странице с анимацией видео не длиннее реального времени', async () => {
    const p = await getPage();
    const animPath = path.join(dir, 'animated.mp4');
    try { fs.unlinkSync(animPath); } catch {}
    try {
      // Элемент перекрашивается на каждом кадре браузера: screencast шлет кадры чаще fps.
      await p.evaluate(() => {
        const d = document.createElement('div');
        d.id = '__web_test_anim_probe';
        d.style.cssText = 'position:fixed;left:0;top:0;width:40px;height:40px;z-index:999999';
        document.body.appendChild(d);
        let i = 0;
        const tick = () => {
          if (!d.isConnected) return;
          d.style.background = i++ % 2 ? '#f00' : '#00f';
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      });
      // wall — от вызова startRecording до вызова stopRecording: финализация mp4 в видео не попадает,
      // а поиск ffmpeg и его запуск — попадают в wall, но не в видео (отсюда нижний допуск)
      const t0 = Date.now();
      await startRecording(animPath, { fps: 10 });
      await p.waitForTimeout(6000);
      const wall = (Date.now() - t0) / 1000;
      const result = await stopRecording();
      const video = videoSeconds(result.file);
      log(`animated: video=${video}s wall=${wall.toFixed(1)}s duration=${result.duration}s`);
      assert.ok(video <= wall + 0.5, `видео не длиннее реального времени (video ${video}s, wall ${wall.toFixed(1)}s)`);
      assert.ok(video >= wall - 1, `видео не короче реального времени (video ${video}s, wall ${wall.toFixed(1)}s)`);
      assert.ok(Math.abs(result.duration - video) < 0.2, `duration = длина видео (${result.duration}s vs ${video}s)`);
    } finally {
      await p.evaluate(() => document.getElementById('__web_test_anim_probe')?.remove()).catch(() => {});
    }
  });

  // Ключа OpenAI в стенде нет: fetch подменяется, проверяется тело запроса, а mp3-ответ —
  // секунда тишины, чтобы addNarration довел склейку до конца.
  await step('openai instructions: addNarration передает instructions в тело запроса OpenAI', async () => {
    const { execFileSync } = await import('child_process');
    const mp3 = execFileSync(resolveFfmpeg(), ['-v', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=24000:cl=mono',
      '-t', '1', '-c:a', 'libmp3lame', '-f', 'mp3', '-']);
    const bodies = [];
    const realFetch = globalThis.fetch;
    globalThis.fetch = async (url, init) => { bodies.push(JSON.parse(init.body)); return new Response(mp3); };
    try {
      const narrate = (extra) => addNarration(videoPath, {
        provider: 'openai', apiKey: 'test', model: 'gpt-4o-mini-tts', cache: false, ...extra,   // fake server: keep it out of the TTS cache
        captions: [{ text: 'a', speech: 'Проверка', time: 0 }],
        outputPath: path.join(dir, 'openai-narrated.mp4'),
      });
      const withInstr = await narrate({ instructions: 'Говори по-русски без акцента' });
      assert.ok(!withInstr.warnings?.length, `озвучка без предупреждений: ${withInstr.warnings}`);
      assert.equal(bodies.length, 1, 'один запрос на одну подпись');
      assert.equal(bodies[0].instructions, 'Говори по-русски без акцента', 'instructions в теле запроса');
      assert.equal(bodies[0].model, 'gpt-4o-mini-tts', 'model в теле запроса');
      await narrate({});
      assert.ok(!('instructions' in bodies[1]), 'без opts.instructions поля в запросе нет');
    } finally {
      globalThis.fetch = realFetch;
    }
  });
}
