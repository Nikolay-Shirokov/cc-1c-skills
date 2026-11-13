// web-test recording/anchors v1.0 — when a word of a phrase sounds: the provider's word timings, the audio's
// pauses, an estimate. Used by slides (steps `at`) and speak() (live pages).
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Sources, best first: 1) word timings the TTS service gave with the audio (Edge) — checked against the audio's
// pauses, dropped when they disagree; 2) the audio alone, any provider: sentence ends are the longest pauses,
// punctuation inside a sentence is matched to the pauses in order, each found pause anchors the estimate further on
// (measured: within 0.15 s for ~85% of anchors, nearly always right after a punctuation mark; mid-sentence ~0.3 s);
// 3) no audio at all (synth: false) — characters × speechRate, for the order of steps only.

import { spawnSync } from 'child_process';
import { statSync } from 'fs';
import { resolveFfmpeg } from './tts.mjs';

export const ON_TIME = 0.15;   // a step later than this past its word is reported

const norm = (w) => w.toLowerCase().replace(/ё/g, 'е').replace(/[^a-zа-я0-9]/g, '');
// How long a piece of text sounds, in letters: digits and capital abbreviations are spoken far longer than written
// («2024» — «две тысячи двадцать четвёртом», «XML» — «экс эм эль»)
function spoken(t) {
  let n = 0;
  for (const m of String(t).matchAll(/\d+|[A-ZА-ЯЁ]{2,}(?![a-zа-яё])|[A-Za-zА-Яа-яЁё]+/g)) {
    const x = m[0];
    n += /^\d/.test(x) ? x.length * 6 : /^[A-ZА-ЯЁ]{2,}$/.test(x) ? x.length * 2.2 : x.length;
  }
  return n;
}
// A sentence ends at . ! ? … before a capital (or a digit, a quote): «т.е. сценарий», «3,5 тысячи» go on
const SENTENCE_END = /[.!?…](?=\s+[«"„(]?[A-ZА-ЯЁ0-9])/g;
const sentenceEnds = (text) => [...text.matchAll(SENTENCE_END)].map((m) => m.index + 1);
// punctuation inside a sentence where a voice pauses (not a decimal comma)
const INNER_PAUSE = /[;:—)]|,(?!\d)/g;
// a pause's weight by punctuation, in letters (measured on Edge voices; rough on purpose)
const PW = { ',': 3, ';': 5, ':': 5, '—': 5, '.': 10, '!': 10, '?': 10, '…': 10, '(': 3, ')': 2 };
function weight(t) {
  const s = String(t).replace(/(\d)[.,](\d)/g, '$1$2');
  let n = spoken(s);
  for (const m of s.matchAll(/[,;:—()!?…]|\.(?=\s+[«"„(]?[A-ZА-ЯЁ0-9]|\s*$)/g)) n += PW[m[0]] || 0;
  return n;
}

/** Tokens of a phrase: [{ c (char index), w (normalized) }], punctuation-only tokens dropped. */
function tokens(text) {
  return [...String(text).matchAll(/\S+/g)].map((m) => ({ c: m.index, w: norm(m[0]) })).filter((t) => t.w);
}

/**
 * Normalize a step's `at`: a word (string), seconds from the phrase start (number), 'end', or { text, shift }.
 * @returns {{ text?: string, t?: number, end?: true, shift: number }}
 */
export function normalizeAt(at, where = 'at') {
  if (at === 'end') return { end: true, shift: 0 };
  if (typeof at === 'number') {
    if (!Number.isFinite(at) || at < 0) throw new Error(`${where}: seconds must be ≥ 0, got ${at}`);
    return { t: at, shift: 0 };
  }
  if (typeof at === 'string') {
    if (!tokens(at).length) throw new Error(`${where}: "${at}" has no words`);
    return { text: at, shift: 0 };
  }
  if (at && typeof at === 'object' && (typeof at.text === 'string' || at.text === undefined)) {
    const shift = at.shift ?? 0;
    if (typeof shift !== 'number' || !Number.isFinite(shift)) throw new Error(`${where}: shift must be a number of seconds`);
    if (at.text === undefined) throw new Error(`${where}: { text, shift } needs "text"`);
    const base = normalizeAt(at.text, where);
    return { ...base, shift };
  }
  throw new Error(`${where}: a word of the phrase, seconds (number), 'end' or { text, shift } — got ${JSON.stringify(at)}`);
}

/**
 * Find the anchors' words in the phrase, in order (each after the previous word anchor).
 * Throws when one is not found. @returns {Array<{ ...normalized, tok?: number, c?: number }>}
 */
export function locateAnchors(speech, ats, where = 'at', labels = null) {
  const toks = tokens(speech);
  const lab = (i) => labels?.[i] || `${where} ${i + 1}`;
  let from = 0, prev = null;   // prev: the previous word anchor — the same words again mean the same place (another shift)
  return ats.map((at, i) => {
    const a = normalizeAt(at, lab(i));
    if (a.text === undefined) return a;
    const want = tokens(a.text).map((t) => t.w);
    if (prev && want.join(' ') === prev.key) return { ...a, tok: prev.tok, c: prev.c };
    for (let k = from; k + want.length <= toks.length; k++) {
      if (want.every((w, j) => toks[k + j].w === w)) {
        from = k + 1; prev = { key: want.join(' '), tok: k, c: toks[k].c };
        return { ...a, tok: k, c: toks[k].c };
      }
    }
    throw new Error(`${lab(i)}: "${a.text}" is not in the phrase${from ? ' after the previous anchor' : ''}: "${speech.slice(0, 80)}${speech.length > 80 ? '…' : ''}"`);
  });
}

// ── the audio ─────────────────────────────────────────────────────────────
const _pauses = new Map();
/** Pauses of an audio file: { dur, s0 (sound starts), s1 (sound ends), ps: [{ s, e }] inner pauses }, seconds. */
export function audioPauses(file, ffmpegPath) {
  let key = file;
  try { key = `${file}|${statSync(file).mtimeMs}`; } catch { /* gone: the run below fails */ }
  if (_pauses.has(key)) return _pauses.get(key);
  const r = spawnSync(resolveFfmpeg(ffmpegPath), ['-hide_banner', '-nostats', '-i', file,
    '-af', 'silencedetect=n=-40dB:d=0.05', '-f', 'null', '-'], { encoding: 'utf8', timeout: 20000 });
  const t = String(r.stderr || '');
  const d = t.match(/Duration: (\d+):(\d+):([\d.]+)/);
  if (!d) throw new Error(`audio pauses: ffmpeg could not read ${file}`);
  const dur = +d[1] * 3600 + +d[2] * 60 + +d[3];
  const all = [];
  let s = null;
  for (const m of t.matchAll(/silence_(start|end): ([\d.]+)/g)) {
    if (m[1] === 'start') s = +m[2]; else { all.push({ s: s ?? 0, e: +m[2] }); s = null; }
  }
  if (s != null) all.push({ s, e: dur });
  const s0 = all[0] && all[0].s < 0.01 ? all[0].e : 0;
  const last = all[all.length - 1];
  const s1 = last && last.e >= dur - 0.01 && last.s > s0 ? last.s : dur;
  const res = { dur, s0, s1, ps: all.filter((p) => p.s > s0 && p.e < s1 + 0.01) };
  _pauses.set(key, res);
  return res;
}

/**
 * Times of the phrase's points from its audio: sentence ends = the longest pauses; punctuation inside a sentence,
 * in order, → the nearest pause (±0.5 s of the estimate from the last anchor). @returns {(c) => { t, snapped }}
 */
function audioClock(text, a) {
  const ends = sentenceEnds(text);
  const long = [...a.ps].sort((x, y) => (y.e - y.s) - (x.e - x.s)).slice(0, ends.length).sort((x, y) => x.s - y.s);
  const nextWord = (i) => { while (i < text.length && /\s/.test(text[i])) i++; return i; };
  const fixed = [{ c: 0, t: a.s0 }];
  const bounds = [0, ...ends.slice(0, long.length), text.length];
  for (let k = 0; k < bounds.length - 1; k++) {
    const cS = k ? nextWord(bounds[k]) : 0, cE = bounds[k + 1];
    const tS = k ? long[k - 1].e : a.s0, tE = k < long.length ? long[k].s : a.s1;
    if (k) fixed.push({ c: cS, t: tS, pause: true });
    let pc = cS, pt = tS;
    for (const m of text.slice(cS, cE).matchAll(INNER_PAUSE)) {
      const at = cS + m.index + 1;
      const rest = weight(text.slice(pc, cE));
      const t = pt + (rest ? weight(text.slice(pc, at)) / rest : 0) * (tE - pt);
      const c = a.ps.filter((p) => p.s > pt && p.e < tE).sort((x, y) => Math.abs(x.s - t) - Math.abs(y.s - t))[0];
      if (c && Math.abs(c.s - t) < 0.5) {
        fixed.push({ c: at, t: c.s }, { c: nextWord(at), t: c.e, pause: true });
        pc = nextWord(at); pt = c.e;
      }
    }
    fixed.push({ c: cE, t: tE });
  }
  return (pos) => {
    const hit = fixed.find((f) => f.pause && f.c === pos);
    if (hit) return { t: Math.max(0, hit.t - 0.1), snapped: true };   // a word's start ≈ 0.1 s before it is heard
    let lo = fixed[0], hi = fixed[fixed.length - 1];
    for (const f of fixed) { if (f.c <= pos && f.c >= lo.c) lo = f; if (f.c >= pos && f.c < hi.c) hi = f; }
    const w = weight(text.slice(lo.c, hi.c));
    return { t: lo.t + (w ? weight(text.slice(lo.c, pos)) / w : 0) * (hi.t - lo.t), snapped: false };
  };
}

/**
 * The provider's word timings matched to the phrase's tokens (in order; a token without a match stays null).
 * A mark may hold several words («2024 году», «отчёт —»): the first starts with the mark, the later ones are
 * counted back from its end; a word may come in pieces («т.» «е.» for «т.е.»).
 */
function markClock(text, words) {
  const toks = tokens(text);
  const units = [];
  for (const m of words) {
    const raw = String(m.w).split(/\s+/).filter((x) => norm(x));
    raw.forEach((x, k) => {
      let s = m.s;
      if (k) s = Math.max(m.s, m.e - raw.slice(k).reduce((a, y) => a + spoken(y), 0) * 0.06);
      units.push({ w: norm(x), s });
    });
  }
  const at = new Array(toks.length).fill(null);
  let m = 0;
  for (let i = 0; i < toks.length && m < units.length; i++) {
    search: for (let j = m; j < Math.min(units.length, m + 4); j++) {
      let w = '';
      for (let n = j; n < Math.min(units.length, j + 3); n++) {
        w += units[n].w;
        if (w === toks[i].w) { at[i] = units[j].s; m = n + 1; break search; }
        if (!toks[i].w.startsWith(w)) break;
      }
    }
  }
  return { at, end: words[words.length - 1].e };
}

// the marks agree with the audio: sentence starts (after the longest pauses) and the end of speech
function marksAgree(text, mk, a) {
  const toks = tokens(text);
  const ends = sentenceEnds(text);
  const long = [...a.ps].sort((x, y) => (y.e - y.s) - (x.e - x.s)).slice(0, ends.length).sort((x, y) => x.s - y.s);
  const checks = [Math.abs(mk.end - a.s1) <= 0.5];
  ends.slice(0, long.length).forEach((c, k) => {
    const i = toks.findIndex((t) => t.c >= c);
    if (i >= 0 && mk.at[i] != null) checks.push(Math.abs(mk.at[i] - (long[k].e - 0.1)) <= 0.3);
  });
  return checks.filter(Boolean).length * 2 > checks.length;
}

/**
 * Seconds from the phrase's start for each anchor.
 * @param {string} speech
 * @param {Array} ats — as in a step's `at`
 * @param {object} src — { words ([{ w, s, e }] or null), file (the phrase's mp3, or null), seconds (its length),
 *   rate (s per character, for no audio), ffmpegPath, where / labels (names in messages) }
 * @returns {{ times: Array<{ t, by: 'marks'|'audio'|'estimate'|'manual' }>, end: number, warnings: string[] }}
 */
export function anchorTimes(speech, ats, src = {}) {
  const where = src.where || 'at';
  const lab = (i) => src.labels?.[i] || `${where} ${i + 1}`;
  const located = locateAnchors(speech, ats, where, src.labels);
  const warnings = [];
  let audio = null;
  if (src.file) {
    try { audio = audioPauses(src.file, src.ffmpegPath); }
    catch (e) { warnings.push(`${e.message} — anchor times estimated`); }
  }
  let marks = src.words?.length ? markClock(speech, src.words) : null;
  if (marks && audio && !marksAgree(speech, marks, audio)) {
    warnings.push('the TTS word timings disagree with the audio — timed from the audio\'s pauses instead');
    marks = null;
  }
  const clock = audio ? audioClock(speech, audio) : null;
  const rate = src.rate || 0.07;
  const end = marks ? marks.end : audio ? audio.s1 : (src.seconds || Math.max(2, speech.length * rate));
  const times = located.map((a, i) => {
    let t, by;
    if (a.t !== undefined) { t = a.t; by = 'manual'; }
    else if (a.end) { t = end; by = marks ? 'marks' : audio ? 'audio' : 'estimate'; }
    else if (marks && marks.at[a.tok] != null) { t = marks.at[a.tok]; by = 'marks'; }
    else if (clock) {
      const r = clock(a.c);
      t = r.t; by = 'audio';
      if (!r.snapped) {
        warnings.push(`${lab(i)} "${a.text}": timed from the audio roughly (±0.3 s) — listen, or anchor a word right after a punctuation mark`);
      }
    } else { t = a.c * rate; by = 'estimate'; }
    t = Math.max(0, t + a.shift);
    if (t > end + 0.05) warnings.push(`${lab(i)}: ${t.toFixed(2)} s is past the phrase's end (${end.toFixed(2)} s) — the slide holds till then`);
    return { t: Math.round(t * 1000) / 1000, by };
  });
  times.forEach((x, i) => {
    if (i && x.t + 0.001 < times[i - 1].t) {
      throw new Error(`${lab(i)} (${x.t.toFixed(2)} s) comes before ${lab(i - 1)} (${times[i - 1].t.toFixed(2)} s) — anchors go in the order they are spoken`);
    }
  });
  return { times, end, warnings };
}
