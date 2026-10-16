// web-test cli/test-runner/severity v1.0 — Allure severity policy resolver
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { die } from '../util.mjs';

export const SEVERITY_RANK = { blocker: 5, critical: 4, normal: 3, minor: 2, trivial: 1 };
export const SEVERITY_LEVELS = Object.keys(SEVERITY_RANK);

/**
 * Validate config.severity (inverted map: severity → [tags]) at config load time.
 * Returns:
 *   - tagToSeverity: Map<tag, severity>  (precomputed lookup for the resolver)
 *   - defaultSeverity: string (validated, defaults to 'normal')
 * Throws (via die) on invalid keys, invalid default, or duplicate tag across buckets.
 */
export function buildSeverityIndex(config) {
  const tagToSeverity = new Map();
  const sev = config.severity || {};
  if (typeof sev !== 'object' || Array.isArray(sev)) {
    die(`config.severity must be an object, got ${typeof sev}`);
  }
  for (const [level, tags] of Object.entries(sev)) {
    if (!SEVERITY_LEVELS.includes(level)) {
      die(`config.severity: unknown level "${level}". Allowed: ${SEVERITY_LEVELS.join('|')}`);
    }
    if (!Array.isArray(tags)) {
      die(`config.severity.${level} must be an array of tag names, got ${typeof tags}`);
    }
    for (const tag of tags) {
      if (tagToSeverity.has(tag)) {
        die(`config.severity: tag "${tag}" listed under both "${tagToSeverity.get(tag)}" and "${level}" — pick one`);
      }
      tagToSeverity.set(tag, level);
    }
  }
  const def = config.defaultSeverity || 'normal';
  if (!SEVERITY_LEVELS.includes(def)) {
    die(`config.defaultSeverity: "${def}" is not a valid level. Allowed: ${SEVERITY_LEVELS.join('|')}`);
  }
  return { tagToSeverity, defaultSeverity: def };
}

/**
 * Resolve a test's severity. Precedence:
 *   1. explicit `export const severity` from the test module
 *   2. max-rank severity found among tags (either standard severity name, or mapped via config)
 *   3. defaultSeverity from config (or 'normal' if not set)
 * Returns one of SEVERITY_LEVELS.
 */
export function resolveSeverity(t, severityIndex) {
  if (t.severity) {
    if (!SEVERITY_LEVELS.includes(t.severity)) {
      return severityIndex.defaultSeverity;
    }
    return t.severity;
  }
  let best = null;
  for (const tag of t.tags || []) {
    let candidate = null;
    if (SEVERITY_LEVELS.includes(tag)) candidate = tag;
    else if (severityIndex.tagToSeverity.has(tag)) candidate = severityIndex.tagToSeverity.get(tag);
    if (candidate && (best === null || SEVERITY_RANK[candidate] > SEVERITY_RANK[best])) {
      best = candidate;
    }
  }
  return best || severityIndex.defaultSeverity;
}
