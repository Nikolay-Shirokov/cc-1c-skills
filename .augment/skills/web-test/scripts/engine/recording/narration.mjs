// web-test recording/narration v1.17 — Post-process: generate TTS audio for captions and merge with recorded video.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { execFileSync } from 'child_process';
import { existsSync as fsExistsSync, mkdirSync, readFileSync, rmSync, statSync } from 'fs';
import { extname, join as pathJoin } from 'path';
import { tmpdir } from 'os';
import {
  lastCaptions, lastRecordingDuration, resolveProjectPath,
} from '../core/state.mjs';
import {
  resolveFfmpeg, getTtsProvider, getAudioDuration, generateSilence,
} from './tts.mjs';

/**
 * Add TTS narration to a recorded video.
 * Generates speech from captions and merges audio with the video.
 * @param {string} videoPath — path to the recorded MP4 file
 * @param {object} [opts]
 * @param {Array<{text: string, speech: string, time: number, voice?: string}>} [opts.captions] — explicit captions (default: from last recording or .captions.json). Each caption may include a `voice` field to override the global voice for that segment
 * @param {string} [opts.provider='edge'] — TTS provider: 'edge' or 'openai'
 * @param {string} [opts.voice] — voice name (provider-specific)
 * @param {string} [opts.apiKey] — API key (for openai provider)
 * @param {string} [opts.apiUrl] — API endpoint (for openai provider)
 * @param {string} [opts.model] — model name (for openai provider, default: 'tts-1')
 * @param {string} [opts.ffmpegPath] — path to ffmpeg binary
 * @param {string} [opts.outputPath] — output file path (default: video-narrated.mp4)
 * @returns {{ file: string, duration: number, size: number, captions: number, warnings?: string[] }}
 */
export async function addNarration(videoPath, opts = {}) {
  if (!videoPath) return { file: null, duration: 0, size: 0, captions: 0 };
  videoPath = resolveProjectPath(videoPath);
  const ffmpegPath = resolveFfmpeg(opts.ffmpegPath);
  const ttsProvider = getTtsProvider(opts.provider || 'edge');
  const ttsOpts = { voice: opts.voice, apiKey: opts.apiKey, apiUrl: opts.apiUrl, model: opts.model };

  // Resolve captions: explicit > lastCaptions > .captions.json
  let captions = opts.captions;
  let videoTimestamps = true; // new recordings use video-time timestamps (no scaling needed)
  let recordingDuration = null; // wall-clock duration (for legacy scaling fallback)
  if (!captions || !captions.length) {
    if (lastCaptions.length) {
      captions = [...lastCaptions];
      recordingDuration = lastRecordingDuration;
      // Runtime captions always use video timestamps (set in showCaption)
    }
  }
  if (!captions || !captions.length) {
    const captionsJsonPath = videoPath.replace(/\.[^.]+$/, '.captions.json');
    if (fsExistsSync(captionsJsonPath)) {
      const raw = JSON.parse(readFileSync(captionsJsonPath, 'utf-8'));
      // Support formats: array (old), { recordingDuration, captions } (v2), { videoTimestamps, captions } (v3)
      if (Array.isArray(raw)) {
        captions = raw;
        videoTimestamps = false;
      } else {
        captions = raw.captions;
        videoTimestamps = !!raw.videoTimestamps;
        recordingDuration = raw.recordingDuration || null;
      }
    }
  }
  if (!captions || !captions.length) {
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
  const outputPath = opts.outputPath || `${base}-narrated${ext}`;

  // Temp directory
  const tempDir = pathJoin(tmpdir(), `web-test-tts-${Date.now()}`);
  mkdirSync(tempDir, { recursive: true });

  const warnings = [];

  try {
    // Phase 1: Generate TTS audio for each caption
    const ttsFiles = [];
    const BATCH_SIZE = (opts.provider === 'elevenlabs') ? 2 : 5;
    for (let batchStart = 0; batchStart < captions.length; batchStart += BATCH_SIZE) {
      const batch = captions.slice(batchStart, batchStart + BATCH_SIZE);
      const promises = batch.map(async (cap, batchIdx) => {
        const idx = batchStart + batchIdx;
        const ttsFile = pathJoin(tempDir, `tts_${idx}.mp3`);
        const capTtsOpts = cap.voice ? { ...ttsOpts, voice: cap.voice } : ttsOpts;
        try {
          await ttsProvider(cap.speech, ttsFile, capTtsOpts);
        } catch (err) {
          // Retry once
          try {
            await ttsProvider(cap.speech, ttsFile, capTtsOpts);
          } catch (retryErr) {
            warnings.push(`TTS failed for caption ${idx}: ${retryErr.message || retryErr.cause?.message || String(retryErr)}`);
            // Generate 1s silence as placeholder
            generateSilence(ttsFile, 1, ffmpegPath);
          }
        }
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

    const narrationPath = pathJoin(tempDir, 'narration.mp3');
    execFileSync(ffmpegPath, [
      '-y', '-i', silencePath, ...ffmpegInputs,
      '-filter_complex', filterComplex,
      '-t', String(Math.ceil(videoDuration)),
      '-c:a', 'libmp3lame', '-b:a', '128k', narrationPath,
    ], { stdio: 'pipe', timeout: 120000 });

    // Phase 4: Merge video + narration audio
    execFileSync(ffmpegPath, [
      '-y', '-i', videoPath, '-i', narrationPath,
      '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
      '-map', '0:v:0', '-map', '1:a:0',
      '-t', String(Math.ceil(videoDuration)),
      '-movflags', '+faststart', outputPath,
    ], { stdio: 'pipe', timeout: 120000 });

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
    try { rmSync(tempDir, { recursive: true, force: true }); } catch {}
  }
}
