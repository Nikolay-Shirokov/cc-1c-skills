// support-state.mjs v1.0 — decode 1C support state (Ext/ParentConfigurations.bin) for Claude Code hooks
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Canonical port of the in-skill guard Assert-EditAllowed / assert_edit_allowed
// (reference: .claude/skills/meta-edit/scripts/meta-edit.ps1:160-261, meta-edit.py:22-148).
// See docs/1c-support-state-spec.md. Detects whether a target file lives under a
// vendor configuration on support and whether editing it is blocked. Never throws —
// any decode error degrades to "not blocked" (allow). configSrc / .v8-project.json
// are NOT used here (reaction lookup lives in project.mjs); the config root is found
// purely by walking up to Ext/ParentConfigurations.bin.

import { readFileSync, existsSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';

const GUID_RE = /\buuid="([0-9a-fA-F-]{36})"/;

// First uuid="..." in an object XML == root element uuid (the <MetaDataObject> wrapper
// carries none), matching the reference's "first element child uuid" semantics.
export function rootUuid(xmlPath) {
  try {
    if (!existsSync(xmlPath) || !statSync(xmlPath).isFile()) return null;
    const text = readFileSync(xmlPath, 'utf8');
    const m = GUID_RE.exec(text);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

// Walk up from startPath (a file or dir) to find the configuration root: the directory
// that holds Ext/ParentConfigurations.bin or Configuration.xml. Returns
// { cfgDir, binPath, isExtension } or nulls. isExtension is positive recognition via
// <ConfigurationExtensionPurpose> in Configuration.xml (spec §1) — distinguishes an
// extension (no real support) from "support fully removed" (bin also near-empty).
export function findConfigRoot(startPath) {
  let cfgDir = null, binPath = null, configXml = null;
  let d = startPath;
  try {
    d = existsSync(startPath) && statSync(startPath).isDirectory() ? startPath : dirname(startPath);
  } catch {
    d = dirname(startPath);
  }
  for (let i = 0; i < 12 && d; i++) {
    const cand = join(d, 'Ext', 'ParentConfigurations.bin');
    const cfgX = join(d, 'Configuration.xml');
    if (existsSync(cand) || existsSync(cfgX)) {
      cfgDir = d;
      binPath = cand;
      configXml = existsSync(cfgX) ? cfgX : null;
      break;
    }
    const parent = dirname(d);
    if (parent === d) break;
    d = parent;
  }
  let isExtension = false;
  if (configXml) {
    try {
      isExtension = readFileSync(configXml, 'utf8').includes('ConfigurationExtensionPurpose');
    } catch { /* ignore */ }
  }
  return { cfgDir, binPath, isExtension };
}

// Decode the bin header + per-object rules and apply the support rule for `require`
// ('editable' — blocked if locked f1=0; 'removed' — blocked unless f1=2).
// Returns { blocked, reason, code, cfgDir, targetPath }. `code` discriminates the cause
// ('capability-off' | 'locked' | 'not-removed') so callers can tailor the remedy.
// Never throws.
export function decideSupport(targetPath, require = 'editable') {
  const result = { blocked: false, reason: '', code: null, cfgDir: null, targetPath };
  try {
    let elemUuid = rootUuid(targetPath);
    // Walk up: collect elemUuid (from <dir>.xml of a sub-element) and the config root.
    let cfgDir = null, binPath = null;
    let d;
    try {
      d = existsSync(targetPath) && statSync(targetPath).isDirectory() ? targetPath : dirname(targetPath);
    } catch {
      d = dirname(targetPath);
    }
    for (let i = 0; i < 12 && d; i++) {
      if (!elemUuid) elemUuid = rootUuid(d + '.xml');
      if (!cfgDir) {
        const cand = join(d, 'Ext', 'ParentConfigurations.bin');
        if (existsSync(cand) || existsSync(join(d, 'Configuration.xml'))) {
          cfgDir = d;
          binPath = cand;
        }
      }
      if (elemUuid && cfgDir) break;
      const parent = dirname(d);
      if (parent === d) break;
      d = parent;
    }
    result.cfgDir = cfgDir;
    // New object (no element file): fall back to config root uuid.
    if (!elemUuid && cfgDir) elemUuid = rootUuid(join(cfgDir, 'Configuration.xml'));
    if (!binPath || !existsSync(binPath)) return result;

    let data = readFileSync(binPath);
    if (data.length <= 32) return result;
    if (data.length >= 3 && data[0] === 0xef && data[1] === 0xbb && data[2] === 0xbf) data = data.subarray(3);
    const text = data.toString('utf8');

    const h = /^\{6,(\d+),(\d+),/.exec(text);
    if (!h) return result;
    const G = parseInt(h[1], 10);
    const K = parseInt(h[2], 10);
    if (K === 0) return result;

    let best = null;
    if (elemUuid) {
      const re = new RegExp('([0-2]),0,' + escapeRe(elemUuid.toLowerCase()), 'g');
      let m;
      while ((m = re.exec(text)) !== null) {
        const f1 = parseInt(m[1], 10);
        if (best === null || f1 < best) best = f1;
      }
    }

    if (G === 1) {
      result.blocked = true;
      result.code = 'capability-off';
      result.reason = 'возможность изменения конфигурации выключена (вся конфигурация read-only)';
    } else if (require === 'removed') {
      if (best !== null && best !== 2) {
        result.blocked = true;
        result.code = 'not-removed';
        result.reason = 'объект на поддержке (не снят с поддержки) — удаление сломает обновления';
      }
    } else {
      if (best !== null && best === 0) {
        result.blocked = true;
        result.code = 'locked';
        result.reason = 'объект на замке (поддержка поставщика) — прямое редактирование сломает обновления';
      }
    }
    return result;
  } catch {
    return result;
  }
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
