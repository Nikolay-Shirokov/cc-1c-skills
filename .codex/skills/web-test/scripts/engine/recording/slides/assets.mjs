// web-test recording/slides/assets v1.0 — project files for slide pages: a service address served by page.route.
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
//
// A slide page cannot load file:// (neither over the 1C page nor over the blank page of `play`), so project files
// (ES modules with their relative imports, scripts, video clips, 3D models, pictures) are served at
// ASSET_BASE + <path from the project root>, while a slide that needs them is on screen (routing turns the
// browser cache off — the 1C client must not run without it after the slide). Only files inside the project
// root and not hidden ones (no `.`-segments: .v8-project.json, .git); CORS open (modules are fetched from
// http://localhost:… and about:blank); Range requests for video.

import { promises as fsp } from 'fs';
import { extname, isAbsolute, relative, resolve } from 'path';
import { projectRoot } from '../../core/state.mjs';

export const ASSET_BASE = 'https://ws-assets.invalid/';

const MIME = {
  '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm',
  '.mp4': 'video/mp4', '.webm': 'video/webm', '.mp3': 'audio/mpeg', '.wav': 'audio/wav',
  '.glb': 'model/gltf-binary', '.gltf': 'model/gltf+json', '.bin': 'application/octet-stream',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.svg': 'image/svg+xml', '.webp': 'image/webp',
  '.gif': 'image/gif', '.css': 'text/css', '.html': 'text/html', '.txt': 'text/plain', '.ktx2': 'image/ktx2',
};
const CHUNK = 4 * 1024 * 1024;   // a Range answer at most this big (video asks for the rest itself)

/** Path → service address. The same function runs in the page (slide.asset/import/load): keep it self-contained. */
export function encodeAssetPath(base, path) {
  return base + String(path).replace(/\\/g, '/').replace(/^\.?\/+/, '').split('/').map(encodeURIComponent).join('/');
}
export const assetUrl = (path) => encodeAssetPath(ASSET_BASE, path);

/** `asset:<path>` in a page's html/css/background → the service address (src="asset:…", url(asset:…)). */
export const rewriteAssets = (text) => (typeof text === 'string'
  ? text.replace(/asset:([^"'()\s>]+)/g, (_, p) => assetUrl(p)) : text);

/** The file a service address points to (inside the project root, no hidden segment), or null. */
export function assetPath(url) {
  if (!url.startsWith(ASSET_BASE)) return null;
  let rel;
  try { rel = decodeURIComponent(new URL(url).pathname.slice(1)); } catch { return null; }
  const abs = resolve(projectRoot, rel);
  const inside = relative(projectRoot, abs);
  // another drive (D:/…) or a UNC path gives an absolute `relative`; `..` leaves the root
  if (!inside || isAbsolute(inside) || inside.split(/[\\/]/).some((seg) => seg === '..' || seg.startsWith('.'))) return null;
  return abs;
}

const routes = new Map();   // page → handler

async function serve(route) {
  const req = route.request();
  const cors = { 'Access-Control-Allow-Origin': '*' };
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: { ...cors, 'Access-Control-Allow-Headers': '*' } });
  const abs = assetPath(req.url());
  let st = null;
  if (abs) { try { st = await fsp.stat(abs); } catch { st = null; } }
  if (!st?.isFile()) return route.fulfill({ status: 404, headers: cors, body: 'not found (project files only)' });
  const type = MIME[extname(abs).toLowerCase()] || 'application/octet-stream';
  const range = /bytes=(\d*)-(\d*)/.exec(req.headers().range || '');
  if (range && st.size) {
    const start = range[1] ? +range[1] : Math.max(0, st.size - +range[2]);
    const end = Math.min(st.size - 1, range[1] && range[2] ? +range[2] : start + CHUNK - 1);
    if (start >= st.size || end < start) {
      return route.fulfill({ status: 416, headers: { ...cors, 'Content-Range': `bytes */${st.size}` } });
    }
    const fh = await fsp.open(abs, 'r');
    try {
      const body = Buffer.alloc(end - start + 1);
      await fh.read(body, 0, body.length, start);
      return route.fulfill({ status: 206, body, headers: {
        ...cors, 'Content-Type': type, 'Accept-Ranges': 'bytes', 'Content-Range': `bytes ${start}-${end}/${st.size}`,
      } });
    } finally { await fh.close(); }
  }
  return route.fulfill({ status: 200, body: await fsp.readFile(abs), headers: { ...cors, 'Content-Type': type, 'Accept-Ranges': 'bytes' } });
}

/** Serve ASSET_BASE on this page (until releaseAssetsRoute). */
export async function ensureAssetsRoute(page) {
  if (!page || routes.has(page)) return;
  const handler = (route) => serve(route).catch(() => route.fulfill({ status: 500 }).catch(() => {}));
  routes.set(page, handler);
  await page.route(ASSET_BASE + '**', handler);
}

/** Stop serving (the browser cache is back on): when no slide that needs project files is on screen. */
export async function releaseAssetsRoute(page) {
  const handler = page && routes.get(page);
  if (!handler) return;
  routes.delete(page);
  await page.unroute(ASSET_BASE + '**', handler).catch(() => {});
}
