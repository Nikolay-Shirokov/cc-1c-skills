// web-test cli/test-runner/context-pool v1.0 — pure context-pool planner (LRU eviction).
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Decides which already-open contexts (each = one live 1C session = one license) to evict
// so the next test's declared contexts fit within `maxContexts` simultaneous sessions.
// Pure functions, no browser — unit-tested in context-pool.test.mjs.

/**
 * @param {object} p
 * @param {string[]} p.open      currently open context names (live 1C sessions)
 * @param {string[]} p.needed    context names the next test declares
 * @param {Set<string>|string[]} [p.pinned] never-evict context names
 * @param {number|null} [p.max]  simultaneous-session cap; null/undefined = unlimited
 * @param {string[]} [p.lruOrder] usage order, oldest first / freshest last
 * @returns {{ toEvict: string[], error: string|null }}
 */
export function planEviction({ open = [], needed = [], pinned = [], max = null, lruOrder = [] }) {
  const pinnedSet = pinned instanceof Set ? pinned : new Set(pinned);
  const neededSet = new Set(needed);
  const openSet = new Set(open);

  // Unlimited pool → never evict (back-compat: behaves like the pre-pool runner).
  if (max == null) return { toEvict: [], error: null };

  // Lower bound that must stay live regardless of eviction: this test's needed contexts, plus
  // pinned contexts that are ALREADY open (pinned = "don't evict while open", NOT "always open" —
  // a pinned context that is currently closed does not count against this test's budget).
  const mustStay = new Set(needed);
  for (const p of pinnedSet) if (openSet.has(p)) mustStay.add(p);
  if (mustStay.size > max) {
    return {
      toEvict: [],
      error: `context pool exhausted: this test needs ${mustStay.size} simultaneous 1C sessions `
        + `(declared contexts + already-open pinned) but maxContexts=${max}. `
        + `Raise maxContexts, reduce declared contexts, or shrink pinnedContexts.`,
    };
  }

  // projected = everything live once we open `needed`. If it already fits, nothing to evict.
  const projected = new Set([...open, ...needed]);
  if (projected.size <= max) return { toEvict: [], error: null };

  // Evictable = open, not pinned, not needed — oldest first by lruOrder.
  const evictable = [];
  for (const name of lruOrder) {
    if (openSet.has(name) && !pinnedSet.has(name) && !neededSet.has(name)) evictable.push(name);
  }
  // Any open evictable missing from lruOrder → treat as oldest (evict first).
  for (const name of open) {
    if (!lruOrder.includes(name) && !pinnedSet.has(name) && !neededSet.has(name)) {
      evictable.unshift(name);
    }
  }

  const toEvict = [];
  let size = projected.size;
  for (const name of evictable) {
    if (size <= max) break;
    toEvict.push(name);
    size--;
  }
  // Guaranteed size <= max here: after removing all evictable, projected collapses to
  // (open ∩ pinned) ∪ needed == mustStay, and mustStay.size <= max passed the guard above.
  return { toEvict, error: null };
}

/**
 * Move `names` to the fresh end of the LRU order (most-recently-used last). Mutates and returns
 * `lruOrder`. Idempotent per name — existing entries are relocated, not duplicated.
 */
export function touchLru(lruOrder, names) {
  for (const n of (Array.isArray(names) ? names : [names])) {
    const i = lruOrder.indexOf(n);
    if (i >= 0) lruOrder.splice(i, 1);
    lruOrder.push(n);
  }
  return lruOrder;
}

/** Remove `names` from the LRU order (e.g. after a context is closed). Mutates and returns it. */
export function dropLru(lruOrder, names) {
  for (const n of (Array.isArray(names) ? names : [names])) {
    const i = lruOrder.indexOf(n);
    if (i >= 0) lruOrder.splice(i, 1);
  }
  return lruOrder;
}
