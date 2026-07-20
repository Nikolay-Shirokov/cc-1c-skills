// Hooks for the suite-root fixture. They prepare nothing — the point is that they RUN at all
// when the runner was pointed at `nested/`. Losing hooks is the silent half of the bug this
// fixture guards: without them a run proceeds against an unprepared stand and still goes green.
// `prepare` writes a marker file the caller can assert on.
import { writeFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const MARKER = resolve(HERE, 'prepare-ran.txt');

export async function prepare({ log }) {
  writeFileSync(MARKER, new Date().toISOString() + '\n');
  log('suite-root fixture: prepare() ran — hooks were resolved from the suite root');
}
