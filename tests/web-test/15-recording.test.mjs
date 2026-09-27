export const name = 'recording: video, captions, TTS narration, overlays (title/image/highlight)';
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
    const overlays = await p.evaluate(() => [...document.body.children]
      .filter(c => c.id && c.id.startsWith('__web_test_title'))
      .map(c => ({ id: c.id, w: c.offsetWidth, h: c.offsetHeight })));
    log(`title overlays: ${JSON.stringify(overlays)}`);
    assert.equal(overlays.length, 1, 'один title overlay');
    assert.equal(overlays[0].w, view.w, 'overlay перекрывает всю ширину viewport');
    assert.equal(overlays[0].h, view.h, 'overlay перекрывает всю высоту viewport');
    await hideTitleSlide();
    const after = await overlayIds();
    assert.ok(!after.includes('__web_test_title'), 'title overlay удалён');
  });

  await step('image-overlay: showImage создаёт overlay, hideImage убирает', async () => {
    // используем свежий screenshot как тестовую картинку
    const imgPath = path.join(dir, 'sample.png');
    const png = await screenshot();
    fs.writeFileSync(imgPath, png);
    await showImage(imgPath, { style: 'dark' });
    const p = await getPage();
    const overlays = await p.evaluate(() => [...document.body.children]
      .filter(c => c.id && c.id.startsWith('__web_test_image'))
      .map(c => ({ id: c.id, w: c.offsetWidth, h: c.offsetHeight })));
    log(`image overlays: ${JSON.stringify(overlays)}`);
    assert.equal(overlays.length, 1, 'один image overlay');
    assert.ok(overlays[0].w > 0 && overlays[0].h > 0, 'overlay имеет размер');
    await hideImage();
    const after = await overlayIds();
    assert.ok(!after.includes('__web_test_image'), 'image overlay удалён');
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

  await step('odd viewport: окно нечетной высоты пишется, ffmpeg не падает', async () => {
    const p = await getPage();
    const oddPath = path.join(dir, 'odd.mp4');
    try { fs.unlinkSync(oddPath); } catch {}
    // Нечетная высота через CDP-эмуляцию: так ее потом можно снять без следа для следующих тестов.
    const cdp = await p.context().newCDPSession(p);
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 721, deviceScaleFactor: 1, mobile: false });
    try {
      await startRecording(oddPath, { fps: 15 });
      await wait(2);
      const result = await stopRecording();
      log(`odd viewport: size=${result.size}B video=${videoSeconds(result.file)}s`);
      assert.ok(result.size > 10000, `mp4 при высоте 721 > 10KB (got ${result.size})`);
    } finally {
      await cdp.send('Emulation.clearDeviceMetricsOverride').catch(() => {});
      await cdp.detach().catch(() => {});
    }
  });

  await step('frame grid: на странице с анимацией видео не длиннее реального времени', async () => {
    const p = await getPage();
    const animPath = path.join(dir, 'animated.mp4');
    try { fs.unlinkSync(animPath); } catch {}
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
    // Четный размер через эмуляцию: шаг проверяет только сетку кадров, независимо от окна.
    const cdp = await p.context().newCDPSession(p);
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 720, deviceScaleFactor: 1, mobile: false });
    try {
      const t0 = Date.now();
      await startRecording(animPath, { fps: 10 });
      await p.waitForTimeout(6000);
      const result = await stopRecording();
      const wall = (Date.now() - t0) / 1000;
      const video = videoSeconds(result.file);
      log(`animated: video=${video}s wall=${wall.toFixed(1)}s`);
      assert.ok(video <= wall + 0.5, `видео не длиннее реального времени (video ${video}s, wall ${wall.toFixed(1)}s)`);
      assert.ok(video >= wall - 1.5, `видео не короче реального времени (video ${video}s, wall ${wall.toFixed(1)}s)`);
    } finally {
      await p.evaluate(() => document.getElementById('__web_test_anim_probe')?.remove());
      await cdp.send('Emulation.clearDeviceMetricsOverride').catch(() => {});
      await cdp.detach().catch(() => {});
    }
  });
}
