// web-test engine/core/deadline v1.0 — wall-clock bounds for calls that can hang
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// Why this exists: `try { await x } catch {}` guards against a REJECTION, not against
// a promise that never settles. A Playwright call against a wedged renderer (page.evaluate
// has no timeout at all) does exactly that — it neither resolves nor rejects, and the runner
// waits forever. Every such call must be bounded by a wall-clock timer instead.
//
// Neither helper CANCELS the underlying work — that is impossible for a promise. They only
// stop *waiting* on it. Whoever breaks a deadline must also destroy the thing that hung
// (see session.abortContext) or the pending call keeps holding its resources.

export class DeadlineError extends Error {
  constructor(label, ms) {
    super(`${label} timed out after ${ms}ms`);
    this.name = 'DeadlineError';
    this.label = label;
    this.ms = ms;
  }
}

/**
 * Await `promise`, but give up after `ms`.
 * @throws {DeadlineError} when the deadline is reached first.
 */
export function withDeadline(promise, ms, label = 'operation') {
  let timer;
  return Promise.race([
    Promise.resolve(promise),
    new Promise((_, reject) => { timer = setTimeout(() => reject(new DeadlineError(label, ms)), ms); }),
  ]).finally(() => clearTimeout(timer));
}

/**
 * Best-effort variant: never throws, reports what happened instead.
 * Use it where the old code said `try { await x } catch {}` — the point is that a breach
 * becomes VISIBLE (callers are expected to log `err`) rather than silently swallowed.
 * @returns {Promise<{ok: boolean, value?: any, err?: Error, timedOut: boolean, ms: number}>}
 */
export async function softDeadline(promise, ms, label = 'operation') {
  const t0 = Date.now();
  try {
    const value = await withDeadline(promise, ms, label);
    return { ok: true, value, timedOut: false, ms: Date.now() - t0 };
  } catch (err) {
    return { ok: false, err, timedOut: err instanceof DeadlineError, ms: Date.now() - t0 };
  }
}
