// web-test recording/tts v1.21 — TTS providers (edge/openai/elevenlabs), phrase cache and ffmpeg/ffprobe helpers.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import { execFileSync, spawn } from 'child_process';
import { createHash } from 'crypto';
import { existsSync as fsExistsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join as pathJoin, resolve as pathResolve } from 'path';
import { pathToFileURL } from 'url';
import { projectRoot } from '../core/state.mjs';

/**
 * The project's .v8-project.json (parsed), {} when absent. Re-read only when the file changes — callers
 * on the recording path (every slide, every caption) must not hit the disk and the parser each time.
 */
let _cfgCache = { mtime: -1, value: {} };
export function readProjectConfig() {
  const file = pathJoin(projectRoot, '.v8-project.json');
  try {
    const mtime = statSync(file).mtimeMs;
    if (mtime !== _cfgCache.mtime) _cfgCache = { mtime, value: JSON.parse(readFileSync(file, 'utf8')) || {} };
  } catch { _cfgCache = { mtime: -1, value: {} }; }
  return _cfgCache.value;
}

/** Resolve ffmpeg binary path. */
let _autoFfmpeg = null;   // found without an explicit path: probing spawns processes, so once per process
export function resolveFfmpeg(explicit) {
  // 1. Explicit path
  if (explicit) {
    try { execFileSync(explicit, ['-version'], { stdio: 'ignore', timeout: 5000 }); return explicit; }
    catch { throw new Error(`ffmpeg not found at: ${explicit}`); }
  }
  if (_autoFfmpeg) return _autoFfmpeg;
  _autoFfmpeg = findFfmpeg();
  return _autoFfmpeg;
}

function findFfmpeg() {
  // 1b. .v8-project.json "ffmpegPath" (relative to the project root) — a configured path that does not
  //     work is an error, not a reason to pick some other ffmpeg silently
  const cfgPath = readProjectConfig().ffmpegPath;
  if (cfgPath) {
    const p = pathResolve(projectRoot, cfgPath);
    try { execFileSync(p, ['-version'], { stdio: 'ignore', timeout: 5000 }); return p; }
    catch { throw new Error(`ffmpeg not found at: ${p} (.v8-project.json "ffmpegPath")`); }
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

// A normal phrase takes 1–3 s; a stuck request (seen with OpenAI: 45–60 s at random) is better dropped
// and asked again — callers retry.
const TTS_REQUEST_TIMEOUT_MS = 30000;
async function ttsFetch(service, url, init) {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(TTS_REQUEST_TIMEOUT_MS) });
  } catch (e) {
    if (e?.name === 'TimeoutError') throw new Error(`${service} TTS timeout (${TTS_REQUEST_TIMEOUT_MS / 1000}s)`);
    throw e;
  }
}

/**
 * OpenAI-compatible TTS provider. Requires apiKey.
 * @param {string} text — text to synthesize
 * @param {string} outputPath — path for the output mp3 file
 * @param {object} opts — { apiKey, apiUrl, voice, model, instructions }
 */
export async function openaiTtsProvider(text, outputPath, opts = {}) {
  const apiUrl = opts.apiUrl || 'https://api.openai.com/v1/audio/speech';
  if (!opts.apiKey) throw new Error('OpenAI TTS requires apiKey');
  const resp = await ttsFetch('OpenAI', apiUrl, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${opts.apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: opts.model || 'tts-1',
      input: text,
      voice: opts.voice || 'alloy',
      response_format: 'mp3',
      // speaking style for gpt-4o-mini-tts (tts-1/tts-1-hd do not support it): sent only when set
      ...(opts.instructions ? { instructions: opts.instructions } : {}),
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
  const resp = await ttsFetch('ElevenLabs', apiUrl, {
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

// ── Phrase cache ───────────────────────────────────────────────────────────
// One synthesis per phrase: slides synthesize ahead to learn exact step lengths, and addNarration
// takes the same files instead of synthesizing again. Keyed by everything that changes the audio.

const TTS_CACHE_DIR = pathResolve(tmpdir(), 'web-test-tts-cache');
const CACHE_TTL_MS = 30 * 24 * 3600 * 1000;   // phrases unused for 30 days are dropped
const _durations = new Map();
const _inflight = new Map();                   // one synthesis per phrase at a time (parallel batches)
let _pruned = false;

// A cache hit refreshes the file's time, so the 30 days count from the last use, not from synthesis.
function touch(file) {
  const now = new Date();
  try { utimesSync(file, now, now); } catch { /* read-only or gone: harmless */ }
}

function pruneCache() {
  if (_pruned) return;
  _pruned = true;
  try {
    const now = Date.now();
    for (const f of readdirSync(TTS_CACHE_DIR)) {
      const p = pathJoin(TTS_CACHE_DIR, f);
      try { if (now - statSync(p).mtimeMs > CACHE_TTL_MS) unlinkSync(p); } catch { /* in use or gone */ }
    }
  } catch { /* no cache yet */ }
}

function ttsCacheFile(text, opts = {}) {
  const key = JSON.stringify([opts.provider || 'edge', opts.voice || '', opts.model || '', opts.instructions || '', opts.apiUrl || '', text]);
  return pathJoin(TTS_CACHE_DIR, createHash('sha1').update(key).digest('hex') + '.mp3');
}

function durationOf(file, ffmpegPath) {
  if (!_durations.has(file)) _durations.set(file, getAudioDuration(file, resolveFfmpeg(ffmpegPath)));
  return _durations.get(file);
}

/**
 * Synthesize a phrase once (cached) and, unless { measure: false }, measure it.
 * @param {string} text
 * @param {object} [opts] — { provider, voice, apiKey, apiUrl, model, instructions, ffmpegPath,
 *   cache (false — bypass the cache: a one-off file in opts.tempDir), tempDir, measure (false — no ffprobe) }
 * @returns {Promise<{ file: string, seconds?: number }>}
 */
export async function synthesizeCached(text, opts = {}) {
  const measure = opts.measure !== false;
  if (opts.cache === false) {
    // no cache: a one-off file (tests with a fake provider must not leave audio under a real phrase's key)
    const dir = opts.tempDir || TTS_CACHE_DIR;
    mkdirSync(dir, { recursive: true });
    const file = pathJoin(dir, `nocache-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.mp3`);
    await getTtsProvider(opts.provider || 'edge')(text, file, opts);
    return measure ? { file, seconds: getAudioDuration(file, resolveFfmpeg(opts.ffmpegPath)) } : { file };
  }
  pruneCache();
  const file = ttsCacheFile(text, opts);
  if (!fsExistsSync(file) || statSync(file).size === 0) {
    // the same phrase twice in one parallel batch: the second waits for the first
    if (!_inflight.has(file)) {
      _inflight.set(file, (async () => {
        mkdirSync(TTS_CACHE_DIR, { recursive: true });
        const part = `${file}.${process.pid}.${Math.random().toString(36).slice(2)}.part.mp3`;
        try {
          await getTtsProvider(opts.provider || 'edge')(text, part, opts);
          renameSync(part, file);
        } finally {
          try { unlinkSync(part); } catch { /* renamed */ }
        }
      })().finally(() => _inflight.delete(file)));
    }
    await _inflight.get(file);
  } else touch(file);
  return measure ? { file, seconds: durationOf(file, opts.ffmpegPath) } : { file };
}

/** The project's TTS settings (`.v8-project.json` → `tts`), {} when absent. */
/**
 * Words a TTS voice is likely to mispronounce: Latin words, digits glued to letters (1С), capital-letter
 * abbreviations (СКД). Speech should spell them as spoken ("один эс"); the screen text keeps the written form.
 * @returns {string[]} distinct tokens, at most 5
 */
export function unspokenTokens(text) {
  const re = /[A-Za-z][A-Za-z0-9]*(?:[.+\-][A-Za-z0-9]+)*|\d+[A-Za-zА-Яа-яЁё]+|(?<![А-Яа-яЁё])[А-ЯЁ]{2,}(?![А-Яа-яЁё])/g;
  return [...new Set(String(text || '').match(re) || [])].slice(0, 5);
}

/** The warning text for unspokenTokens, or null. */
export function unspokenWarning(text) {
  const t = unspokenTokens(text);
  return t.length ? `speech has ${t.map((x) => `"${x}"`).join(', ')} — write it as spoken (1С → "один эс")` : null;
}

export function projectTtsOptions() {
  const cfg = readProjectConfig();
  return cfg.tts && typeof cfg.tts === 'object' ? { ...cfg.tts } : {};
}

/**
 * Caller's TTS options over the project's ones. The project's voice/model/key belong to its provider:
 * they are taken only when the caller names no provider or the same one (an Edge call must not get an
 * OpenAI voice).
 */
export function mergeTtsOptions(opts = {}) {
  const own = Object.fromEntries(Object.entries(opts).filter(([, v]) => v !== undefined));
  const project = projectTtsOptions();
  const provider = (p) => p || 'edge';
  if (own.provider && provider(own.provider) !== provider(project.provider)) return own;
  return { ...project, ...own };
}

/** Length of an already cached phrase in seconds, or null (no synthesis). */
export function cachedSpeechSeconds(text, opts = {}) {
  const file = ttsCacheFile(text, opts);
  if (!fsExistsSync(file) || statSync(file).size === 0) return null;
  touch(file);
  try { return durationOf(file, opts.ffmpegPath); } catch { return null; }
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
