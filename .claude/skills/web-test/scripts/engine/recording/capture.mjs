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
  const ffmpeg = spawn(ffmpegPath, [
    '-y',                          // overwrite output
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
    resolvedPath
  ], { stdio: ['pipe', 'ignore', 'pipe'] });

  ffmpeg.on('error', err => { if (recorder) recorder.ffmpegError += err.message; });

  const frameDuration = 1000 / fps;
  const speechRate = opts.speechRate || 70; // ms per character for smart TTS wait

  // Frame handler shared across CDP sessions (lives in recorder, not closure):
  // when the active context switches, we attach a new CDP session and route its
  // frames to the same ffmpeg pipe — preserving a single continuous timeline.
  // Frames sit on a wall-clock grid of 1/fps slots counted from startTime. A page that repaints
  // faster than fps (animated background) used to turn every screencast frame into a video frame,
  // so the video ran in slow motion and narration drifted from the picture: 159 s of wall time
  // became 183 s of video. Now extra frames within one slot are dropped (the newest is kept as
  // lastFrameBuf) and gaps are filled with the last frame.
  const writeFrame = (b) => {
    ffmpeg.stdin.write(b);
    recorder.framesWritten++;
    recorder.videoTimeMs = recorder.framesWritten * frameDuration;
  };
  const dueFrames = () => Math.floor((Date.now() - recorder.startTime) / frameDuration);

  const frameHandler = async ({ data, sessionId }, cdp) => {
    if (!recorder) return;
    const buf = Buffer.from(data, 'base64');
    if (!ffmpeg.stdin.destroyed) {
      const due = dueFrames();
      while (recorder.framesWritten < due - 1) writeFrame(recorder.lastFrameBuf || buf);
      if (recorder.framesWritten < due) writeFrame(buf);
    }
    recorder.lastFrameTime = Date.now();
    recorder.lastFrameBuf = buf;
    try { await cdp.send('Page.screencastFrameAck', { sessionId }); } catch {}
  };

  // Fill the grid up to "now" with the last frame (static periods, context switches, before a
  // caption timestamp is taken).
  const _flushFrames = () => {
    if (!recorder || !recorder.lastFrameBuf || ffmpeg.stdin.destroyed) return;
    const due = dueFrames();
    while (recorder.framesWritten < due) writeFrame(recorder.lastFrameBuf);
    recorder.lastFrameTime = Date.now();
  };

  // Attach screencast to a specific page. Stops the old CDP first (if any).
  // Called by startRecording for the initial page, and by setActiveContext when
  // the active context changes mid-recording.
  const _attachPage = async (targetPage) => {
    if (recorder.cdp) {
      _flushFrames(); // freeze the last frame of the outgoing page up to "now"
      try { await recorder.cdp.send('Page.stopScreencast'); } catch {}
      try { await recorder.cdp.detach(); } catch {}
      recorder.cdp = null;
    }
    const cdp = await targetPage.context().newCDPSession(targetPage);
    cdp.on('Page.screencastFrame', (ev) => frameHandler(ev, cdp));
    await cdp.send('Page.startScreencast', { format: 'jpeg', quality, everyNthFrame: 1 });
    recorder.cdp = cdp;
    recorder.activePage = targetPage;
  };

  setRecorder({
    cdp: null,
    activePage: null,
    ffmpeg,
    startTime: Date.now(),
    outputPath: resolvedPath,
    ffmpegError: '',
    captions: [],
    videoTimeMs: 0,
    framesWritten: 0,
    frameDuration,
    lastFrameTime: null,
    lastFrameBuf: null,
    _flushFrames,
    _attachPage,
    speechRate,
  });
  ffmpeg.stderr.on('data', d => { recorder.ffmpegError += d.toString(); });

  await _attachPage(page);
}

/**
 * Stop video recording. Finalizes the MP4 file.
 * @returns {{ file: string, duration: number, size: number }}
 */
export async function stopRecording() {
  if (!recorder) return { file: null, duration: 0, size: 0 };

  const { cdp, ffmpeg, startTime, outputPath } = recorder;

  // Final frame flush: write remaining frames to cover the gap since the last screencast frame
  if (recorder._flushFrames) recorder._flushFrames();

  // Stop CDP screencast
  try { await cdp.send('Page.stopScreencast'); } catch {}
  try { await cdp.detach(); } catch {}

  // Close ffmpeg stdin and wait for encoding to finish
  await new Promise((resolve, reject) => {
    // ffmpeg that already died (bad input size, codec error) never emits 'close' again:
    // report its own error instead of waiting 30s for a misleading timeout.
    if (ffmpeg.exitCode !== null) {
      reject(new Error(`ffmpeg exited early with code ${ffmpeg.exitCode}: ${recorder?.ffmpegError || ''}`));
      return;
    }

    const timeout = setTimeout(() => {
      ffmpeg.kill('SIGKILL');
      reject(new Error('ffmpeg timed out after 30s'));
    }, 30000);

    ffmpeg.on('close', (code) => {
      clearTimeout(timeout);
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg exited with code ${code}: ${recorder?.ffmpegError || ''}`));
    });
    ffmpeg.on('error', (err) => {
      clearTimeout(timeout);
      reject(err);
    });

    ffmpeg.stdin.end();
  });

  const duration = (Date.now() - startTime) / 1000;
  const stats = statSync(outputPath);

  // Preserve captions for addNarration()
  setLastCaptions(recorder.captions || []);
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
