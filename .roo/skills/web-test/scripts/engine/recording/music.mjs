// web-test recording/music v1.1 — background music: own presets (synthesized, no licence), cues in the
// recording, intervals with seams, volume envelopes for addNarration.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Model: every preset (or file) in use is one continuous loop over the whole video; slides and withMusic blocks
// only open its volume on their stretch. Seams are interval arithmetic: one preset in a row flows on, a gap
// under BRIDGE s between music stretches is filled, different presets cross-fade, nested — the inner wins.
// Modes under speech: 'duck' (a slide / block: lowered under the voice) and 'gaps' (the whole video: plays in
// pauses ≥ MIN_GAP s, at the start and the end; nearly silent under speech — no "breathing" in a dialogue).
// Rules from listening: no rare standing-out events (a lone bell, a tick) — a steady even texture; major, no bass.

import { existsSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { recorder, resolveProjectPath } from '../core/state.mjs';

export const BRIDGE = 3;       // s: a gap shorter than this between music stretches is filled
export const FADE = 1.5;       // s: an edge of a stretch
export const XFADE = 2;        // s: different presets next to each other
export const MIN_GAP = 3;      // s: a pause in speech the whole-video music plays in
export const UNDER_SPEECH = 0.08;   // 'gaps': level under speech (of the full level)
export const LEVEL = -22;      // dB: music under the voice

// ── presets: synthesis in Node → WAV, a seamless loop ─────────────────────
const SR = 44100;
const VERSION = 1;   // bump when presets change: rendered files are named by it
const hz = (n) => 440 * 2 ** ((n - 69) / 12);
function add(buf, N, t0, secs, fn) {
  const start = Math.round(t0 * SR), dur = Math.round(secs * SR);
  for (let i = 0; i < dur; i++) buf[(start + i) % N] += fn(i / SR);   // the tail wraps into the loop start
}
const INST = {
  marimba: (b, N, t0, f, a) => add(b, N, t0, 1.2, (t) => a * Math.min(1, t / 0.004) * Math.exp(-5.5 * t)
    * (Math.sin(2 * Math.PI * f * t) + 0.25 * Math.sin(8 * Math.PI * f * t) * Math.exp(-14 * t))),
  softmarimba: (b, N, t0, f, a) => add(b, N, t0, 1.4, (t) => a * Math.min(1, t / 0.012) * Math.exp(-4.5 * t)
    * (Math.sin(2 * Math.PI * f * t) + 0.12 * Math.sin(4 * Math.PI * f * t) * Math.exp(-8 * t))),
  musicbox: (b, N, t0, f, a) => add(b, N, t0, 2.2, (t) => a * Math.min(1, t / 0.002) * Math.exp(-2.6 * t)
    * (Math.sin(2 * Math.PI * f * t) + 0.18 * Math.sin(6 * Math.PI * f * t) * Math.exp(-6 * t))),
  pluck: (b, N, t0, f, a) => add(b, N, t0, 0.9, (t) => a * Math.min(1, t / 0.003) * Math.exp(-7 * t)
    * (Math.sin(2 * Math.PI * f * t) + 0.4 * Math.sin(4 * Math.PI * f * t) * Math.exp(-10 * t)
      + 0.2 * Math.sin(6 * Math.PI * f * t) * Math.exp(-16 * t))),
  tick: (b, N, t0, _f, a) => {
    let s = Math.round(t0 * 1000) + 12345;   // deterministic noise
    const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff) * 2 - 1;
    add(b, N, t0, 0.08, (t) => a * rnd() * Math.exp(-60 * t));
  },
};
// pattern: per grid step — the chord tone (0..3), +12 an octave up, null — rest
export const PRESETS = {
  bright: { bpm: 100, grid: 2, reps: 2, room: 0.3, lowpass: 5200,
    chords: [[60, 64, 67, 72], [59, 62, 67, 71], [60, 64, 69, 72], [60, 65, 69, 72]],
    voices: [{ inst: 'marimba', amp: 0.16, pattern: [0, 1, 2, 3, 2, 1, 2, 3], accent: 4 }] },
  warm: { bpm: 92, grid: 2, reps: 2, room: 0.35, lowpass: 3600,
    chords: [[60, 64, 67, 72], [57, 60, 64, 69], [53, 60, 65, 69], [55, 59, 62, 67]],
    voices: [{ inst: 'softmarimba', amp: 0.15, pattern: [0, 1, 2, 3, 2, 3, 2, 1], accent: 4 }] },
  calm: { bpm: 80, grid: 2, reps: 2, room: 0.42, lowpass: 4200,
    chords: [[67, 72, 76, 79], [64, 69, 72, 76], [65, 69, 72, 77], [67, 71, 74, 79]],
    voices: [{ inst: 'musicbox', amp: 0.10, pattern: [0, 1, 2, 3, 2, 1, 2, 1], accent: 4 }] },
  focus: { bpm: 92, grid: 2, reps: 2, room: 0.3, lowpass: 3000,
    chords: [[60, 64, 67, 72], [60, 64, 67, 72], [60, 65, 69, 72], [60, 65, 69, 72]],
    voices: [{ inst: 'pluck', amp: 0.08, pattern: [0, 2, 1, 2, 0, 2, 1, 2] },
      { inst: 'pluck', amp: 0.05, pattern: [3, 3, 3, 3, 3, 3, 3, 3] }] },
  uplift: { bpm: 112, grid: 4, reps: 2, room: 0.28, lowpass: 5600,
    chords: [[60, 64, 67, 72], [62, 67, 71, 74], [64, 69, 72, 76], [65, 69, 72, 77]],
    voices: [{ inst: 'pluck', amp: 0.11, pattern: [0, 1, 2, 3, 2, 1, 2, 3, 0, 1, 2, 3, 2, 3, 2, 1], accent: 4 },
      { inst: 'marimba', amp: 0.08, pattern: [15, null, null, null, null, null, 14, null, null, null, null, null, null, null, null, null] },
      { inst: 'tick', amp: 0.035, pattern: [null, null, 0, null, null, null, 0, null, null, null, 0, null, null, null, 0, null] }] },
  'uplift-soft': { bpm: 108, grid: 4, reps: 2, room: 0.3, lowpass: 5000,
    chords: [[60, 64, 67, 72], [62, 67, 71, 74], [64, 69, 72, 76], [65, 69, 72, 77]],
    voices: [{ inst: 'pluck', amp: 0.10, pattern: [0, 1, 2, 3, 2, 1, 2, 3, 0, 1, 2, 3, 2, 3, 2, 1], accent: 4 }] },
};
export const PRESET_NAMES = Object.keys(PRESETS);

/** A preset as 16-bit stereo PCM samples (a seamless loop). */
export function renderPreset(name) {
  const p = PRESETS[name];
  const BEAT = 60 / p.bpm, BAR = 4 * BEAT, STEP = BEAT / p.grid;
  const bars = p.chords.length * p.reps, N = Math.round(bars * BAR * SR);
  const dry = new Float32Array(N);
  for (let bar = 0; bar < bars; bar++) {
    const ch = p.chords[bar % p.chords.length];
    for (const v of p.voices) {
      v.pattern.forEach((x, j) => {
        if (x == null) return;
        const tone = ch[x % 12 % 4] + (x >= 12 ? 12 : 0);
        const accent = v.accent ? (j % v.accent === 0 ? 1 : 0.72) : 1;
        INST[v.inst](dry, N, bar * BAR + j * STEP + (j % 2 ? 0.005 : 0), hz(tone), v.amp * accent);
      });
    }
  }
  // a room: uneven reflections (even short ones ring metallic on dense attacks)
  const out = new Float32Array(N);
  const taps = [[0.029, 0.7], [0.047, 0.85], [0.083, 0.62], [0.131, 0.47], [0.179, 0.33], [0.257, 0.22], [0.349, 0.14], [0.463, 0.08]];
  for (let i = 0; i < N; i++) {
    let s = dry[i];
    for (const [d, g] of taps) s += p.room * g * dry[(i - Math.round(d * SR) + N) % N];
    out[i] = s;
  }
  let y = 0;
  const a = Math.exp(-2 * Math.PI * p.lowpass / SR);
  for (let pass = 0; pass < 2; pass++) for (let i = 0; i < N; i++) { y = (1 - a) * out[i] + a * y; if (pass) out[i] = y; }
  let peak = 0;
  for (const v of out) peak = Math.max(peak, Math.abs(v));
  const g = 0.89 / peak, pcm = new Int16Array(N * 2);
  for (let i = 0; i < N; i++) {
    pcm[2 * i] = Math.round(Math.max(-1, Math.min(1, out[i] * g)) * 32767);
    pcm[2 * i + 1] = Math.round(Math.max(-1, Math.min(1, out[(i - 220 + N) % N] * g)) * 32767);   // a touch of width
  }
  return { pcm, sampleRate: SR, seconds: N / SR };
}

function wavBuffer({ pcm, sampleRate }) {
  const n = pcm.length / 2, b = Buffer.alloc(44 + n * 4);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 4, 4); b.write('WAVE', 8); b.write('fmt ', 12);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(2, 22); b.writeUInt32LE(sampleRate, 24);
  b.writeUInt32LE(sampleRate * 4, 28); b.writeUInt16LE(4, 32); b.writeUInt16LE(16, 34); b.write('data', 36);
  b.writeUInt32LE(n * 4, 40);
  Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength).copy(b, 44);
  return b;
}

/** The loop file of a preset (rendered once into the temp folder). */
export function presetFile(name) {
  const dir = join(tmpdir(), 'web-test-music');
  const file = join(dir, `${name}-v${VERSION}.wav`);
  if (!existsSync(file)) {
    // a temp name + rename: a parallel run or a killed process never leaves a truncated loop behind
    mkdirSync(dir, { recursive: true });
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
    writeFileSync(tmp, wavBuffer(renderPreset(name)));
    try { renameSync(tmp, file); } catch { try { unlinkSync(tmp); } catch { /* another run won the race */ } }
  }
  return file;
}

// ── a music spec: 'bright' | 'audio/track.mp3' | { preset|file, level } ───
/** Normalized { key, preset?, file?, level } — throws on an unknown preset / missing file. */
export function resolveMusic(spec) {
  const o = typeof spec === 'string' ? (PRESETS[spec] ? { preset: spec } : { file: spec })
    : spec && typeof spec === 'object' ? spec : null;
  if (!o || (!o.preset && !o.file)) {
    throw new Error(`music: a preset name (${PRESET_NAMES.join(', ')}), a file path or { preset|file, level }`);
  }
  if (o.preset && !PRESETS[o.preset]) throw new Error(`music: unknown preset "${o.preset}" — ${PRESET_NAMES.join(', ')}`);
  let file;
  if (o.file) {
    file = resolveProjectPath(o.file);
    if (!existsSync(file)) throw new Error(`music: file not found: ${file} (presets: ${PRESET_NAMES.join(', ')})`);
  }
  const level = o.level ?? LEVEL;
  if (typeof level !== 'number') throw new Error('music: "level" is a number of dB');
  return { key: `${o.preset || file}@${level}`, preset: o.preset, file, level };
}
const sourceFile = (m) => m.file || presetFile(m.preset);

// ── cues in a recording ───────────────────────────────────────────────────
/** Open a music stretch at the current video time; returns a handle for musicClose (null when not recording). */
export function musicOpen(spec, mode = 'duck') {
  if (!recorder) return null;
  const m = resolveMusic(spec);
  recorder.music ||= [];
  const depth = recorder.music.filter((c) => c.end == null).length;
  const cue = { start: Math.round(recorder.videoTimeMs), end: null, music: spec, mode, depth };
  recorder.music.push(cue);
  cue.key = m.key;
  return cue;
}
export function musicClose(cue) {
  if (cue && recorder && cue.end == null) cue.end = Math.round(recorder.videoTimeMs);
}

/**
 * Music over a stretch of the recording: on while `fn` runs (long actions in 1C without speech).
 * Outside a recording just runs `fn`.
 */
export async function withMusic(spec, fn) {
  resolveMusic(spec);   // a wrong spec fails before the actions
  const cue = musicOpen(spec, 'duck');
  try { return await fn(); } finally { musicClose(cue); }
}

// ── intervals → envelopes ─────────────────────────────────────────────────
/**
 * Cues (+ an optional whole-video base) → per-track stretches. Pure: { start, end (ms), music, mode, depth }.
 * @returns {Array<{ music, mode, segs: Array<[number, number]> }>} seconds; one entry per (music, mode)
 */
export function musicIntervals(cues, base, durationSec) {
  const D = durationSec;
  const all = (cues || []).map((c) => ({ ...c, s: c.start / 1000, e: (c.end ?? D * 1000) / 1000, key: resolveMusic(c.music).key }));
  if (base) all.push({ s: 0, e: D, music: base, mode: 'gaps', depth: -1, key: resolveMusic(base).key });
  // elementary spans: the innermost (deepest, then latest) cue covering each wins
  const cuts = [...new Set(all.flatMap((c) => [Math.max(0, c.s), Math.min(D, c.e)]))].sort((a, b) => a - b);
  const spans = [];
  for (let i = 0; i + 1 < cuts.length; i++) {
    const a = cuts[i], b = cuts[i + 1];
    if (b - a < 1e-6) continue;
    const top = all.filter((c) => c.s <= a + 1e-6 && c.e >= b - 1e-6)
      .sort((x, y) => x.depth - y.depth || x.s - y.s).at(-1);
    if (top) spans.push({ a, b, key: top.key + '|' + top.mode, music: top.music, mode: top.mode });
  }
  // per track: merge touching spans; bridge a gap under BRIDGE only when no other music plays in it
  // (an inner stretch of another music must not get the outer one bridged over it)
  const tracks = new Map();
  for (const sp of spans) {
    if (!tracks.has(sp.key)) tracks.set(sp.key, { music: sp.music, mode: sp.mode, segs: [] });
    const segs = tracks.get(sp.key).segs, last = segs.at(-1);
    const free = last && !spans.some((o) => o.key !== sp.key && o.a < sp.a - 1e-6 && o.b > last[1] + 1e-6);
    if (last && sp.a - last[1] < BRIDGE && free) last[1] = sp.b;
    else segs.push([sp.a, sp.b]);
  }
  return [...tracks.values()];
}

/** Check every music spec of the cues (and the whole-video one) — before any synthesis. */
export function checkMusic(cues, base) {
  if (base !== undefined) resolveMusic(base);
  for (const c of cues || []) resolveMusic(c.music);
}

/** Speech spans [start, end] (s) → pauses ≥ MIN_GAP the whole-video music plays in (start and end included). */
export function speechGaps(spans, D) {
  const s = [...spans].sort((x, y) => x[0] - y[0]);
  const gaps = [];
  let t = 0;
  for (const [a, b] of s) {
    if (a - t >= MIN_GAP || (t === 0 && a > 0.5)) gaps.push([t, a]);
    t = Math.max(t, b);
  }
  if (D - t > 0.5) gaps.push([t, D]);
  return gaps;
}

/**
 * ffmpeg volume expression (of t): a sum of trapezoids. `center` — edges straddle the bounds (cross-fades);
 * at the video's start and end an edge lies inside (fades from / to silence, no half-level onset or chop).
 */
export function trapezoids(segs, fade, { center = true, D = Infinity } = {}) {
  if (!segs.length) return '0';
  return segs.map(([a, b]) => {
    const s = a <= 0.05 ? 0 : center ? a - fade / 2 : a;
    const e = b >= D - 0.05 ? D : center ? b + fade / 2 : b;
    return `clip(min((t-(${s.toFixed(3)}))/${fade},(${e.toFixed(3)}-t)/${fade}),0,1)`;
  }).join('+');
}

/** The volume expression of one track: duck stretches, or gaps stretches opened only in speech pauses. */
export function trackEnvelope(track, gaps, D = Infinity) {
  const edge = track.mode === 'gaps' ? FADE : XFADE;
  const on = trapezoids(track.segs, edge, { D });
  if (track.mode !== 'gaps') return on;
  const pauses = trapezoids(gaps, FADE, { center: false, D });
  return `(${on})*(${UNDER_SPEECH}+${(1 - UNDER_SPEECH).toFixed(2)}*min(1,${pauses}))`;
}

export { sourceFile };
