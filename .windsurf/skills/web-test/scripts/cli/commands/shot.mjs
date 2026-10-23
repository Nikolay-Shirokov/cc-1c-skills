// web-test cli/commands/shot v1.0 — take screenshot via server
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import { writeFileSync } from 'fs';
import { out, die } from '../util.mjs';
import { loadSession } from '../session.mjs';

export async function cmdShot(file) {
  const sess = loadSession();
  const resp = await fetch(`http://127.0.0.1:${sess.port}/shot`);
  if (!resp.ok) {
    const err = await resp.text();
    die(`Screenshot failed: ${err}`);
  }
  const buf = Buffer.from(await resp.arrayBuffer());
  const outFile = file || 'shot.png';
  writeFileSync(outFile, buf);
  out({ ok: true, file: outFile });
}
