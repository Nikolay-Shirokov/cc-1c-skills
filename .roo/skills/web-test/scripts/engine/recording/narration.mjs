// web-test recording/narration v1.22 — Post-process: generate TTS audio for captions and merge with recorded video.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { execFileSync } from 'child_process';
import { existsSync as fsExistsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'fs';
import { extname, join as pathJoin } from 'path';
import { removePathSync } from '../core/fsutil.mjs';
import { tmpdir } from 'os';
import {
  lastCaptions, lastMusic, lastRecordingDuration, resolveProjectPath,
} from '../core/state.mjs';
import { musicIntervals, speechGaps, trackEnvelope, sourceFile, resolveMusic, checkMusic } from './music.mjs';
import {
  resolveFfmpeg, getAudioDuration, generateSilence, synthesizeCached, mergeTtsOptions,
} from './tts.mjs';

/**
 * Add TTS narration to a recorded video.
 * Generates speech from captions and merges audio with the video.
 * @param {string} videoPath — path to the recorded MP4 file
 * @param {object} [opts]
 * @param {Array<{text: string, speech: string, time: number, voice?: string}>} [opts.captions] — explicit captions (default: from last recording or .captions.json). Each caption may include a `voice` field to override the global voice for that segment
 * Options default to the project's .v8-project.json "tts" settings (the ones slides and captions are timed with).
 * @param {string} [opts.provider='edge'] — TTS provider: 'edge', 'openai' or 'elevenlabs'
 * @param {string} [opts.voice] — voice name (provider-specific)
 * @param {string} [opts.apiKey] — API key (for openai provider)
 * @param {string} [opts.apiUrl] — API endpoint (for openai provider)
 * @param {string} [opts.model] — model name (for openai provider, default: 'tts-1')
 * @param {string} [opts.instructions] — speaking style (openai gpt-4o-mini-tts)
 * @param {string} [opts.ffmpegPath] — path to ffmpeg binary
 * @param {string} [opts.outputPath] — output file path (default: video-narrated.mp4)
 * @param {boolean} [opts.cache=true] — reuse/keep phrases in the shared TTS cache (false — synthesize afresh)
 * @param {string|object} [opts.music] — background music over the whole video, in speech pauses: a preset
 *   (bright, warm, calm, focus, uplift, uplift-soft), a file path or { preset|file, level }. Music stretches of
 *   the recording (slides with `music`, withMusic) are mixed in anyway
 * @param {Array} [opts.musicCues] — explicit music stretches (default: from the last recording or .captions.json)
 * @returns {{ file: string, duration: number, size: number, captions: number, warnings?: string[] }}
 */
export async function addNarration(videoPath, opts = {}) {
  if (!videoPath) return { file: null, duration: 0, size: 0, captions: 0 };
  videoPath = resolveProjectPath(videoPath);
  const ffmpegPath = resolveFfmpeg(opts.ffmpegPath);
  const tts = mergeTtsOptions(opts);
  const ttsOpts = {
    provider: tts.provider || 'edge', voice: tts.voice, apiKey: tts.apiKey, apiUrl: tts.apiUrl,
    model: tts.model, instructions: tts.instructions, ffmpegPath, cache: tts.cache, measure: false,
  };

  const captionsJsonPath = videoPath.replace(/\.[^.]+$/, '.captions.json');
  let raw = null;
  if (fsExistsSync(captionsJsonPath)) raw = JSON.parse(readFileSync(captionsJsonPath, 'utf-8'));
  const meta = raw && !Array.isArray(raw) ? raw : {};

  // Music of THIS video: the stretches of its recording (the last one if it wrote this file, else its
  // .captions.json) and the whole-video music (opts.music, or the one remembered there). music: false — none.
  const sameFile = (a, b) => !!a && (process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b);
  const noMusic = opts.music === false;
  const musicCues = noMusic ? [] : opts.musicCues ?? (sameFile(lastMusic.file, videoPath) ? lastMusic.cues : meta.music) ?? [];
  const musicBase = noMusic ? undefined : opts.music ?? meta.musicBase;
  checkMusic(musicCues, musicBase);   // every music spec before any synthesis (a moved file must not cost the TTS calls)

  // Resolve captions: explicit > lastCaptions > .captions.json; an explicit [] means "no speech" (music only)
  let captions = opts.captions;
  const explicit = Array.isArray(captions);
  let videoTimestamps = true; // new recordings use video-time timestamps (no scaling needed)
  let recordingDuration = null; // wall-clock duration (for legacy scaling fallback)
  if (!explicit && lastCaptions.length) {
    captions = [...lastCaptions];
    recordingDuration = lastRecordingDuration;
    // Runtime captions always use video timestamps (set in showCaption)
  }
  if (!explicit && !captions?.length && raw) {
    // Support formats: array (old), { recordingDuration, captions } (v2), { videoTimestamps, captions } (v3)
    if (Array.isArray(raw)) {
      captions = raw;
      videoTimestamps = false;
    } else {
      captions = raw.captions || [];
      videoTimestamps = !!raw.videoTimestamps;
      recordingDuration = raw.recordingDuration || null;
    }
  }
  captions ||= [];
  const hasMusic = musicBase !== undefined || musicCues.length > 0;
  if (!captions.length && !hasMusic) {
    throw new Error('No captions available. Record with showCaption() first, or pass opts.captions.');
  }

  const videoDuration = getAudioDuration(videoPath, ffmpegPath);

  // Legacy fallback: scale wall-clock timestamps to video duration
  // (only for old captions without videoTimestamps flag)
  if (!videoTimestamps && recordingDuration && recordingDuration > 0) {
    const timeScale = videoDuration / recordingDuration;
    if (Math.abs(timeScale - 1) > 0.005) {
      captions = captions.map(c => ({ ...c, time: Math.round(c.time * timeScale) }));
    }
  }

  // Output path
  const ext = extname(videoPath);
  const base = videoPath.slice(0, -ext.length);
  const outputPath = opts.outputPath ? resolveProjectPath(opts.outputPath) : `${base}-narrated${ext}`;

  // Temp directory (silence, mix, one-off phrases of cache:false — all removed at the end)
  const tempDir = pathJoin(tmpdir(), `web-test-tts-${Date.now()}`);
  mkdirSync(tempDir, { recursive: true });
  ttsOpts.tempDir = tempDir;

  const warnings = [];

  try {
    // Phase 1: Generate TTS audio for each caption
    const ttsFiles = [];
    const BATCH_SIZE = (ttsOpts.provider === 'elevenlabs') ? 2 : 5;
    for (let batchStart = 0; batchStart < captions.length; batchStart += BATCH_SIZE) {
      const batch = captions.slice(batchStart, batchStart + BATCH_SIZE);
      const promises = batch.map(async (cap, batchIdx) => {
        const idx = batchStart + batchIdx;
        const capTtsOpts = cap.voice ? { ...ttsOpts, voice: cap.voice } : ttsOpts;
        // Shared phrase cache: phrases synthesized ahead (slides) are not synthesized again
        for (let attempt = 0; attempt < 3; attempt++) {
          try {
            return (await synthesizeCached(cap.speech, capTtsOpts)).file;
          } catch (err) {
            if (attempt === 2) warnings.push(`TTS failed for caption ${idx}: ${err.message || err.cause?.message || String(err)}`);
          }
        }
        const ttsFile = pathJoin(tempDir, `tts_${idx}.mp3`);
        generateSilence(ttsFile, 1, ffmpegPath);   // 1s placeholder
        return ttsFile;
      });
      const results = await Promise.all(promises);
      ttsFiles.push(...results);
    }

    // Phase 2+3: Place each TTS at its exact timestamp using adelay + amix
    // This avoids MP3 frame quantization drift from silence-file concatenation
    const ffmpegInputs = [];
    const filterParts = [];
    const mixLabels = [];
    const speech = [];   // [start, end] s of each phrase as placed (for music in pauses)

    for (let i = 0; i < captions.length; i++) {
      const captionTimeMs = Math.round(captions[i].time);
      const ttsFile = ttsFiles[i];
      const ttsDuration = getAudioDuration(ttsFile, ffmpegPath);

      ffmpegInputs.push('-i', ttsFile);
      const filters = [];

      // Speed up TTS slightly if it's longer than gap to next caption (max 1.3x)
      if (i < captions.length - 1) {
        const maxDuration = (captions[i + 1].time - captions[i].time) / 1000;
        if (ttsDuration > maxDuration && maxDuration > 0.1) {
          const tempo = ttsDuration / maxDuration;
          if (tempo <= 1.3) {
            filters.push(`atempo=${tempo.toFixed(4)}`);
          } else {
            // Too fast — let audio overlap instead of distorting
            warnings.push(`Caption ${i + 1}/${captions.length}: TTS ${ttsDuration.toFixed(1)}s > gap ${maxDuration.toFixed(1)}s (need ${Math.round(ttsDuration - maxDuration)}s more pause)`);
          }
        }
      }

      const tempoUsed = filters.length && filters[0].startsWith('atempo=') ? +filters[0].slice(7) : 1;
      speech.push([captionTimeMs / 1000, captionTimeMs / 1000 + ttsDuration / tempoUsed]);

      // Delay to exact caption timestamp (milliseconds)
      if (captionTimeMs > 0) {
        filters.push(`adelay=${captionTimeMs}|${captionTimeMs}`);
      }

      const label = `a${i}`;
      mixLabels.push(`[${label}]`);
      // Input indices are shifted by 1 because silence reference is input [0]
      filterParts.push(`[${i + 1}]${filters.length ? filters.join(',') : 'acopy'}[${label}]`);
    }

    // Generate a silence reference track as input [0] so amix runs for full video duration
    const silencePath = pathJoin(tempDir, 'silence.mp3');
    generateSilence(silencePath, Math.ceil(videoDuration), ffmpegPath);

    const filterComplex = filterParts.join(';') + ';' +
      `[0]${mixLabels.join('')}amix=inputs=${captions.length + 1}:normalize=0:duration=first`;

    let narrationPath = pathJoin(tempDir, 'narration.mp3');
    if (captions.length) {
      execFileSync(ffmpegPath, [
        '-y', '-i', silencePath, ...ffmpegInputs,
        '-filter_complex', filterComplex,
        '-t', String(Math.ceil(videoDuration)),
        '-c:a', 'libmp3lame', '-b:a', '128k', narrationPath,
      ], { stdio: 'pipe', timeout: 120000 });
    } else narrationPath = silencePath;   // music only

    if (hasMusic) narrationPath = mixMusic(narrationPath, speech, musicCues, musicBase, videoDuration, tempDir, ffmpegPath);

    // Phase 4: Merge video + narration audio
    execFileSync(ffmpegPath, [
      '-y', '-i', videoPath, '-i', narrationPath,
      '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
      '-map', '0:v:0', '-map', '1:a:0',
      '-t', String(Math.ceil(videoDuration)),
      '-movflags', '+faststart', outputPath,
    ], { stdio: 'pipe', timeout: 120000 });

    // the whole-video music is remembered next to the video: a later re-narration keeps it (music: false drops it)
    if (opts.music !== undefined && !Array.isArray(raw)) {
      const data = { videoTimestamps: true, captions: [], ...(raw || {}) };
      if (opts.music === false) delete data.musicBase; else data.musicBase = opts.music;
      try { writeFileSync(captionsJsonPath, JSON.stringify(data, null, 2), 'utf-8'); } catch { /* the video is made anyway */ }
    }

    const stats = statSync(outputPath);
    const duration = getAudioDuration(outputPath, ffmpegPath);

    const result = {
      file: outputPath,
      duration: Math.round(duration * 10) / 10,
      size: stats.size,
      captions: captions.length,
    };
    if (warnings.length) result.warnings = warnings;
    return result;

  } finally {
    // Cleanup temp directory
    try { removePathSync(tempDir); } catch {}
  }
}

/**
 * Mix background music under the narration. Every music in use is one loop over the whole video; its volume
 * opens on its stretches (music.mjs: seams, cross-fades) — 'gaps' (the whole video) only in speech pauses.
 * The music bus: no lows (< 250 Hz), a dip in the speech band (2 kHz), its level; then lowered under the voice.
 */
function mixMusic(speechPath, speech, cues, base, D, tempDir, ffmpegPath) {
  const tracks = musicIntervals(cues, base, D).filter((t) => t.segs.length);
  if (!tracks.length) return speechPath;
  const gaps = speechGaps(speech, D);
  const inputs = ['-i', speechPath], parts = [], labels = [];
  const fmt = 'aformat=sample_rates=44100:channel_layouts=stereo';
  tracks.forEach((t, i) => {
    const m = resolveMusic(t.music);
    inputs.push('-stream_loop', '-1', '-i', sourceFile(m));
    parts.push(`[${i + 1}:a]${fmt},atrim=0:${D},asetpts=PTS-STARTPTS,volume=${m.level}dB,volume='${trackEnvelope(t, gaps, D)}':eval=frame[m${i}]`);
    labels.push(`[m${i}]`);
  });
  const bus = labels.length > 1 ? `${labels.join('')}amix=inputs=${labels.length}:normalize=0,` : `${labels[0]}`;
  parts.push(`${bus}${labels.length > 1 ? '' : 'acopy,'}highpass=f=250,equalizer=f=2000:t=q:w=1.2:g=-4[mus]`);
  parts.push(`[0:a]${fmt},asplit=2[sp][key]`);
  parts.push('[mus][key]sidechaincompress=threshold=0.02:ratio=8:attack=25:release=700:knee=4[duck]');
  parts.push('[sp][duck]amix=inputs=2:normalize=0:duration=first[a]');
  const out = pathJoin(tempDir, 'narration-music.mp3');
  // the graph goes in a file: envelopes of a long video would pass the command-line limit (32 KB on Windows)
  const graph = pathJoin(tempDir, 'music-graph.txt');
  writeFileSync(graph, parts.join(';\n'));
  execFileSync(ffmpegPath, ['-y', ...inputs, '-filter_complex_script', graph, '-map', '[a]',
    '-t', String(Math.ceil(D)), '-c:a', 'libmp3lame', '-b:a', '160k', out], { stdio: 'pipe', timeout: 300000 });
  return out;
}
