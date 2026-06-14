// web-test recording/tts v1.17 — TTS providers (edge/openai/elevenlabs) and ffmpeg/ffprobe helpers.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { execFileSync, spawn } from 'child_process';
import { existsSync as fsExistsSync, writeFileSync } from 'fs';
import { resolve as pathResolve } from 'path';
import { pathToFileURL } from 'url';
import { projectRoot } from '../core/state.mjs';

/** Resolve ffmpeg binary path. */
export function resolveFfmpeg(explicit) {
  // 1. Explicit path
  if (explicit) {
    try { execFileSync(explicit, ['-version'], { stdio: 'ignore', timeout: 5000 }); return explicit; }
    catch { throw new Error(`ffmpeg not found at: ${explicit}`); }
  }

  // 2. FFMPEG_PATH env var
  const envPath = process.env.FFMPEG_PATH;
  if (envPath) {
    try { execFileSync(envPath, ['-version'], { stdio: 'ignore', timeout: 5000 }); return envPath; }
    catch { /* fall through */ }
  }

  // 3. System PATH
  try { execFileSync('ffmpeg', ['-version'], { stdio: 'ignore', timeout: 5000 }); return 'ffmpeg'; }
  catch { /* fall through */ }

  // 4. tools/ffmpeg/bin/ffmpeg.exe relative to project root
  const localPath = pathResolve(projectRoot, 'tools', 'ffmpeg', 'bin', 'ffmpeg.exe');
  if (fsExistsSync(localPath)) {
    try { execFileSync(localPath, ['-version'], { stdio: 'ignore', timeout: 5000 }); return localPath; }
    catch { /* fall through */ }
  }

  // 5. Error with instructions
  throw new Error(
    'ffmpeg not found. Install it:\n' +
    '  - Download from https://www.gyan.dev/ffmpeg/builds/ (essentials build)\n' +
    '  - Add to PATH, or set FFMPEG_PATH env var, or place in tools/ffmpeg/bin/\n' +
    '  - Or pass ffmpegPath option to startRecording()'
  );
}

// ── TTS providers ──────────────────────────────────────────────────────────

/** Resolve node-edge-tts module: global install → tools/tts/ → error with instructions. */
let _edgeTtsModule = null;
export async function resolveEdgeTts() {
  if (_edgeTtsModule) return _edgeTtsModule;

  // 1. Global/project-level install (standard Node resolution)
  try {
    _edgeTtsModule = await import('node-edge-tts');
    return _edgeTtsModule;
  } catch { /* fall through */ }

  // 2. tools/tts/ relative to project root
  const localPath = pathResolve(projectRoot, 'tools', 'tts', 'node_modules', 'node-edge-tts', 'dist', 'edge-tts.js');
  if (fsExistsSync(localPath)) {
    try {
      _edgeTtsModule = await import(pathToFileURL(localPath).href);
      return _edgeTtsModule;
    } catch { /* fall through */ }
  }

  // 3. Error with instructions
  throw new Error(
    'node-edge-tts not found. Install it:\n' +
    '  - npm install --prefix tools/tts node-edge-tts\n' +
    '  - or: npm install node-edge-tts (global/project-level)'
  );
}

/**
 * Edge TTS provider (free, no API key). Uses node-edge-tts package.
 * @param {string} text — text to synthesize
 * @param {string} outputPath — path for the output mp3 file
 * @param {object} opts — { voice }
 */
export async function edgeTtsProvider(text, outputPath, opts = {}) {
  const { EdgeTTS } = await resolveEdgeTts();
  const voice = opts.voice || 'ru-RU-DmitryNeural';
  const tts = new EdgeTTS({ voice });
  await Promise.race([
    tts.ttsPromise(text, outputPath),
    new Promise((_, reject) => setTimeout(() => reject(new Error('Edge TTS timeout (30s)')), 30000)),
  ]);
}

/**
 * OpenAI-compatible TTS provider. Requires apiKey.
 * @param {string} text — text to synthesize
 * @param {string} outputPath — path for the output mp3 file
 * @param {object} opts — { apiKey, apiUrl, voice, model }
 */
export async function openaiTtsProvider(text, outputPath, opts = {}) {
  const apiUrl = opts.apiUrl || 'https://api.openai.com/v1/audio/speech';
  if (!opts.apiKey) throw new Error('OpenAI TTS requires apiKey');
  const resp = await fetch(apiUrl, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${opts.apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: opts.model || 'tts-1',
      input: text,
      voice: opts.voice || 'alloy',
      response_format: 'mp3',
    }),
  });
  if (!resp.ok) throw new Error(`OpenAI TTS error ${resp.status}: ${await resp.text()}`);
  const buf = Buffer.from(await resp.arrayBuffer());
  writeFileSync(outputPath, buf);
}

/**
 * ElevenLabs TTS provider. Requires apiKey.
 * @param {string} text — text to synthesize
 * @param {string} outputPath — path for the output mp3 file
 * @param {object} opts — { apiKey, apiUrl, voice, model }
 */
export async function elevenlabsTtsProvider(text, outputPath, opts = {}) {
  const voiceId = opts.voice || 'JBFqnCBsd6RMkjVDRZzb'; // George
  const apiUrl = opts.apiUrl || `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`;
  if (!opts.apiKey) throw new Error('ElevenLabs TTS requires apiKey');
  const resp = await fetch(apiUrl, {
    method: 'POST',
    headers: { 'xi-api-key': opts.apiKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      text,
      model_id: opts.model || 'eleven_multilingual_v2',
    }),
  });
  if (!resp.ok) throw new Error(`ElevenLabs TTS error ${resp.status}: ${await resp.text()}`);
  const buf = Buffer.from(await resp.arrayBuffer());
  writeFileSync(outputPath, buf);
}

/** Get TTS provider function by name. */
export function getTtsProvider(name) {
  switch (name) {
    case 'openai': return openaiTtsProvider;
    case 'elevenlabs': return elevenlabsTtsProvider;
    case 'edge': default: return edgeTtsProvider;
  }
}

// ── TTS audio helpers ──────────────────────────────────────────────────────

/**
 * Get audio duration in seconds using ffprobe.
 * @param {string} filePath — path to audio file
 * @param {string} ffmpegPath — path to ffmpeg binary (ffprobe is found next to it)
 * @returns {number} duration in seconds
 */
export function getAudioDuration(filePath, ffmpegPath) {
  const ffprobePath = ffmpegPath.replace(/ffmpeg(\.exe)?$/i, 'ffprobe$1');
  const out = execFileSync(ffprobePath, [
    '-v', 'error', '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1', filePath,
  ], { encoding: 'utf8', timeout: 10000 }).trim();
  return parseFloat(out) || 0;
}

/**
 * Generate a silence mp3 file of given duration.
 * @param {string} outputPath — path for the output mp3 file
 * @param {number} seconds — duration in seconds
 * @param {string} ffmpegPath — path to ffmpeg binary
 */
export function generateSilence(outputPath, seconds, ffmpegPath) {
  execFileSync(ffmpegPath, [
    '-y', '-f', 'lavfi', '-i', `anullsrc=r=24000:cl=mono`,
    '-t', String(seconds), '-c:a', 'libmp3lame', '-b:a', '32k', outputPath,
  ], { stdio: 'pipe', timeout: 10000 });
}
