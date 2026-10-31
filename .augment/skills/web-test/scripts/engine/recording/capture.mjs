// web-test recording/capture v1.18 — Recording lifecycle (CDP screencast + ffmpeg pipe), screenshot, wait helpers.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { spawn } from 'child_process';
import { mkdirSync, statSync, writeFileSync } from 'fs';
import { dirname } from 'path';
import {
  page, recorder, lastCaptions,
  setRecorder, setLastCaptions, setLastRecordingDuration,
  resolveProjectPath, ensureConnected,
} from '../core/state.mjs';
import { resolveFfmpeg } from './tts.mjs';
// Imported lazily inside wait() to avoid initialization-time circular deps.

/** Take a screenshot. Returns PNG buffer. */
export async function screenshot() {
  ensureConnected();
  return await page.screenshot({ type: 'png' });
}

/** Wait for a specified number of seconds. */
export async function wait(seconds) {
  ensureConnected();
  let ms = seconds * 1000;
  // Credit system: if showCaption already waited for TTS, subtract that time
  if (recorder && recorder.captionCredit) {
    const elapsed = Date.now() - recorder.captionCredit.at;
    const credit = Math.max(0, recorder.captionCredit.waitedMs - elapsed);
    ms = Math.max(0, ms - credit);
    recorder.captionCredit = null;
  }
  if (ms > 0) {
    // During recording, split long waits into chunks and flush frames
    // to keep video timeline in sync (CDP may not send frames for static pages)
    if (recorder?._flushFrames && ms > 1000) {
      let remaining = ms;
      while (remaining > 0) {
        const chunk = Math.min(remaining, 1000);
        await page.waitForTimeout(chunk);
        remaining -= chunk;
        recorder._flushFrames();
      }
    } else {
      await page.waitForTimeout(ms);
    }
  }
  const { getFormState } = await import('../forms/state.mjs');
  return await getFormState();
}

// ============================================================
// Video recording — CDP screencast + ffmpeg
// ============================================================

/** ffmpeg arguments: JPEG frames on stdin → H.264 MP4 at outputPath. */
export function ffmpegEncodeArgs(fps, outputPath) {
  return [
    '-y',                          // overwrite output
    '-hide_banner', '-loglevel', 'error', // stderr carries only errors (it becomes the error message)
    '-f', 'image2pipe',            // input: piped images
    '-framerate', String(fps),     // input framerate
    '-i', '-',                     // read from stdin
    '-c:v', 'libx264',            // H.264 codec
    '-preset', 'fast',             // good quality/speed balance
    '-crf', '23',                  // default quality (good for screen content)
    // libx264 + yuv420p reject odd sizes, and a maximized window can give one (1920x945):
    // crop to even width/height first (drops at most one pixel row/column).
    '-vf', 'crop=trunc(iw/2)*2:trunc(ih/2)*2,scale=in_range=full:out_range=limited', // JPEG full→H.264 limited range
    '-pix_fmt', 'yuv420p',        // broad compatibility
    '-color_range', 'tv',          // limited range (16-235) — standard for H.264 players
    '-movflags', '+faststart',     // web-friendly MP4
    outputPath
  ];
}

/** Check if video recording is active. */
export function isRecording() {
  return recorder !== null;
}

/**
 * Start video recording via CDP screencast + ffmpeg.
 * Frames are captured as JPEG and piped to ffmpeg for MP4 encoding.
 * @param {string} outputPath — output .mp4 file path
 * @param {object} [opts]
 * @param {number} [opts.fps=25] — target framerate
 * @param {number} [opts.quality=80] — JPEG quality (1-100)
 * @param {string} [opts.ffmpegPath] — explicit path to ffmpeg binary
 */
export async function startRecording(outputPath, opts = {}) {
  ensureConnected();
  if (recorder) {
    if (opts.force) {
      try { await stopRecording(); } catch {}
    } else {
      throw new Error('Already recording. Call stopRecording() first, or use { force: true }.');
    }
  }
  setLastCaptions([]);
  setLastRecordingDuration(null);

  const fps = opts.fps || 25;
  const quality = opts.quality || 80;
  const ffmpegPath = resolveFfmpeg(opts.ffmpegPath);

  // Ensure output directory exists
  const resolvedPath = resolveProjectPath(outputPath);
  mkdirSync(dirname(resolvedPath), { recursive: true });

  // Spawn ffmpeg process — single output file across context switches
  const ffmpeg = spawn(ffmpegPath, ffmpegEncodeArgs(fps, resolvedPath), { stdio: ['pipe', 'ignore', 'pipe'] });

  const frameDuration = 1000 / fps;
  const speechRate = opts.speechRate || 70; // ms per character for smart TTS wait

  // This recording's own state. The closures below use `rec`, not the module-global
  // `recorder`, so a late event of a finished recording cannot touch the next one.
  const rec = {
    cdp: null,
    activePage: null,
    ffmpeg,
    startTime: Date.now(),
    clockStart: performance.now(), // monotonic: the frame grid must not follow wall-clock jumps
    outputPath: resolvedPath,
    ffmpegError: '',
    captions: [],
    framesWritten: 0,
    frameDuration,
    lastFrameBuf: null,
    speechRate,
    // Video time of "now". Slots are filled lazily (next frame or flush), so this is exact
    // without a flush, even before the first screencast frame arrives.
    get videoTimeMs() { return slotNow() * frameDuration; },
  };

  // Subscribed at spawn: an ffmpeg that dies during recording (odd size, codec error) has
  // already emitted 'close' by the time stopRecording runs. 'close' also means stderr is drained.
  rec.closed = new Promise(resolve => ffmpeg.once('close', (code, signal) => resolve(code ?? signal)));
  const appendError = (msg) => { rec.ffmpegError += msg; };
  ffmpeg.on('error', err => appendError(err.message));
  // A frame written while ffmpeg is dying fails with EPIPE; unhandled, it would crash the process.
  // Not appended to the error: ffmpeg's own stderr says why it died.
  ffmpeg.stdin.on('error', () => {});
  ffmpeg.stderr.on('data', d => appendError(d.toString()));

  // Frames sit on a grid of 1/fps slots from the start of recording: a page that repaints
  // faster than fps (animation) must not stretch the video, or narration drifts from the picture.
  // A slot is written once it is over, with the newest frame received by then (lastFrameBuf).
  const slotNow = () => Math.floor((performance.now() - rec.clockStart) / frameDuration);
  const fillUpTo = (slot, buf) => {
    while (rec.framesWritten < slot) { ffmpeg.stdin.write(buf); rec.framesWritten++; }
  };

  // Frame handler shared across CDP sessions: when the active context switches, we attach
  // a new CDP session and route its frames to the same ffmpeg pipe — one continuous timeline.
  const frameHandler = async ({ data, sessionId }, cdp) => {
    const buf = Buffer.from(data, 'base64');
    // Close the slots before this frame's one; the very first frame also covers the start.
    if (ffmpeg.stdin.writable) fillUpTo(slotNow(), rec.lastFrameBuf || buf);
    rec.lastFrameBuf = buf;
    try { await cdp.send('Page.screencastFrameAck', { sessionId }); } catch {}
  };

  // Write the slots that are over (static periods, context switches); `final` also writes
  // the current, partly elapsed one.
  rec._flushFrames = (final = false) => {
    if (!rec.lastFrameBuf || !ffmpeg.stdin.writable) return;
    fillUpTo(slotNow() + (final ? 1 : 0), rec.lastFrameBuf);
  };

  // Attach screencast to a specific page. Stops the old CDP first (if any).
  // Called by startRecording for the initial page, and by setActiveContext when
  // the active context changes mid-recording.
  rec._attachPage = async (targetPage) => {
    if (rec.cdp) {
      rec._flushFrames(); // freeze the last frame of the outgoing page up to "now"
      try { await rec.cdp.send('Page.stopScreencast'); } catch {}
      try { await rec.cdp.detach(); } catch {}
      rec.cdp = null;
    }
    const cdp = await targetPage.context().newCDPSession(targetPage);
    cdp.on('Page.screencastFrame', (ev) => frameHandler(ev, cdp));
    await cdp.send('Page.startScreencast', { format: 'jpeg', quality, everyNthFrame: 1 });
    rec.cdp = cdp;
    rec.activePage = targetPage;
  };

  setRecorder(rec);
  try {
    await rec._attachPage(page);
  } catch (err) {
    setRecorder(null); // no screencast — do not leave a recording that nothing feeds
    ffmpeg.kill();
    throw err;
  }
}

/**
 * Stop video recording. Finalizes the MP4 file.
 * @returns {{ file: string, duration: number, size: number }}
 */
export async function stopRecording() {
  if (!recorder) return { file: null, duration: 0, size: 0 };

  const rec = recorder;
  const { cdp, ffmpeg, outputPath } = rec;

  // Final frame flush, current slot included; the video ends here, so does the duration
  rec._flushFrames(true);
  const duration = rec.framesWritten * rec.frameDuration / 1000;

  // Stop CDP screencast
  try { await cdp.send('Page.stopScreencast'); } catch {}
  try { await cdp.detach(); } catch {}

  // Close ffmpeg stdin and wait for encoding to finish. An ffmpeg that already died
  // resolves rec.closed at once, so its own error is reported instead of a timeout.
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      ffmpeg.kill('SIGKILL');
      reject(new Error('ffmpeg timed out after 30s'));
    }, 30000);

    rec.closed.then((code) => {
      clearTimeout(timeout);
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg failed (${code}): ${rec.ffmpegError}`));
    });

    ffmpeg.stdin.end();
  }).catch((err) => {
    setRecorder(null); // a failed recording must not block the next startRecording()
    throw err;
  });

  const stats = statSync(outputPath);

  // Preserve captions for addNarration()
  setLastCaptions(rec.captions);
  setLastRecordingDuration(duration);
  if (lastCaptions.length) {
    const captionsPath = outputPath.replace(/\.[^.]+$/, '.captions.json');
    const captionsData = { recordingDuration: duration, videoTimestamps: true, captions: lastCaptions };
    writeFileSync(captionsPath, JSON.stringify(captionsData, null, 2), 'utf-8');
  }

  setRecorder(null);

  return {
    file: outputPath,
    duration: Math.round(duration * 10) / 10,
    size: stats.size,
    captions: lastCaptions.length
  };
}
