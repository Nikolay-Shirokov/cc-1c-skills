// web-test cli/test-runner/assertions v1.1 — ctx.assert API
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

export function createAssertions() {
  class AssertionError extends Error {
    constructor(msg, actual, expected) {
      super(msg);
      this.name = 'AssertionError';
      this.actual = actual;
      this.expected = expected;
    }
  }

  return {
    ok(value, msg) {
      if (!value) throw new AssertionError(msg || `Expected truthy, got ${JSON.stringify(value)}`, value, true);
    },
    equal(actual, expected, msg) {
      if (actual !== expected) throw new AssertionError(msg || `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`, actual, expected);
    },
    notEqual(actual, expected, msg) {
      if (actual === expected) throw new AssertionError(msg || `Expected not ${JSON.stringify(expected)}`, actual, expected);
    },
    deepEqual(actual, expected, msg) {
      const a = JSON.stringify(actual), b = JSON.stringify(expected);
      if (a !== b) throw new AssertionError(msg || `Deep equal failed:\n  actual:   ${a}\n  expected: ${b}`, actual, expected);
    },
    includes(haystack, needle, msg) {
      const h = Array.isArray(haystack) ? haystack : String(haystack);
      if (!h.includes(needle)) throw new AssertionError(msg || `Expected ${JSON.stringify(h)} to include ${JSON.stringify(needle)}`, haystack, needle);
    },
    match(string, regex, msg) {
      if (!regex.test(string)) throw new AssertionError(msg || `Expected ${JSON.stringify(string)} to match ${regex}`, string, regex);
    },
    async throws(fn, msg) {
      try { await fn(); } catch { return; }
      throw new AssertionError(msg || 'Expected function to throw');
    },
    // 1C-specific
    // `fields` is an ARRAY of { name, value, ... } — indexing it by field name yields undefined,
    // which used to make this assertion throw on every call, including the valid ones.
    formHasField(state, fieldName, msg) {
      const names = (state?.fields || []).map(f => f.name);
      if (!names.includes(fieldName)) {
        throw new AssertionError(msg || `Field "${fieldName}" not found in form. Available: ${names.join(', ')}`, null, fieldName);
      }
    },
    formTitle(state, expected, msg) {
      // `title` is null when the form exposes no caption and the open-windows panel is off —
      // say so instead of reporting a mismatch against "null".
      if (state?.title == null) {
        throw new AssertionError(msg || `Form title is not available (state.title is null), expected it to contain "${expected}"`, null, expected);
      }
      if (!state.title.includes(expected)) {
        throw new AssertionError(msg || `Form title "${state.title}" does not contain "${expected}"`, state.title, expected);
      }
    },
    tableHasRow(table, predicate, msg) {
      const rows = table?.rows || [];
      let found;
      if (typeof predicate === 'function') {
        found = rows.some(predicate);
      } else {
        found = rows.some(r => Object.entries(predicate).every(([k, v]) => r[k] === v));
      }
      if (!found) throw new AssertionError(msg || `No row matching predicate in table (${rows.length} rows)`, null, predicate);
    },
    tableRowCount(table, expected, msg) {
      const actual = table?.rows?.length ?? 0;
      if (actual !== expected) throw new AssertionError(msg || `Expected ${expected} rows, got ${actual}`, actual, expected);
    },
    noErrors(state, msg) {
      if (state?.errors) throw new AssertionError(msg || `Form has errors: ${JSON.stringify(state.errors)}`, state.errors, null);
    },
  };
}
