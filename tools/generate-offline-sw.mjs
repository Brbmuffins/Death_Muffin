import { createHash } from 'node:crypto';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const dir = path.resolve(process.argv[2] || 'dist-offline');
const base = process.argv[3] || '/death-muffin/offline/';
if (!base.startsWith('/') || !base.endsWith('/')) throw new Error('Offline base must be an absolute path ending in /');

async function filesAt(folder, prefix = '') {
  const entries = await readdir(folder, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const relative = path.posix.join(prefix, entry.name);
    if (entry.isDirectory()) files.push(...await filesAt(path.join(folder, entry.name), relative));
    else if (entry.isFile()) files.push(relative);
  }
  return files;
}

const files = (await filesAt(dir)).filter((name) => name !== 'index.html' && name !== 'sw.js' && name !== 'offline-manifest.json');
const assets = files.sort().map((name) => base + name);
const index = await readFile(path.join(dir, 'index.html'), 'utf8');
const digest = createHash('sha256').update(index);
for (const name of files.sort()) digest.update(name).update(await readFile(path.join(dir, name)));
const version = digest.digest('hex').slice(0, 12);
const manifest = {
  id: base,
  name: 'Death Muffin Offline',
  short_name: 'Death Muffin',
  description: 'A standalone, single player Death Muffin edition saved on this device.',
  start_url: base,
  scope: base,
  display: 'standalone',
  background_color: '#07060a',
  theme_color: '#07060a',
  icons: [{ src: base + 'offline-icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' }],
};
await writeFile(path.join(dir, 'offline-manifest.json'), JSON.stringify(manifest));
await writeFile(path.join(dir, 'index.html'), index.replace('</head>', `  <link rel="manifest" href="${base}offline-manifest.json" />\n</head>`));

const sw = `/* Generated Death Muffin offline cache ${version}. */
const BASE = ${JSON.stringify(base)};
const CACHE = 'dm-offline-${version}';
const ASSETS = ${JSON.stringify(assets)};
const READY = BASE + 'offline-ready.txt';
let downloading = false;

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll([BASE, BASE + 'index.html', BASE + 'offline-manifest.json', BASE + 'offline-icon.svg'])));
  self.skipWaiting();
});
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(BASE)) return;
  if (event.request.method !== 'GET' && event.request.method !== 'HEAD') return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const target = event.request.mode === 'navigate' ? BASE + 'index.html' : event.request.url;
    const hit = await cache.match(target) || await caches.match(target);
    if (hit) return event.request.method === 'HEAD' ? new Response(null, { status: 200, headers: hit.headers }) : hit;
    if (event.request.method === 'HEAD') return fetch(event.request);
    try {
      const response = await fetch(event.request);
      if (response.ok) await cache.put(target, response.clone());
      return response;
    } catch {
      if (event.request.mode === 'navigate') return cache.match(BASE + 'index.html') || Response.error();
      return Response.error();
    }
  })());
});

self.addEventListener('message', (event) => {
  const port = event.ports[0];
  if (!port) return;
  if (event.data?.type === 'STATUS') {
    event.waitUntil(caches.open(CACHE).then(async (cache) => port.postMessage({ type: 'status', ready: !!(await cache.match(READY)), total: ASSETS.length })));
  }
  if (event.data?.type === 'DOWNLOAD') event.waitUntil(download(port));
});

async function download(port) {
  if (downloading) { port.postMessage({ type: 'error', message: 'Download already running' }); return; }
  downloading = true;
  const cache = await caches.open(CACHE);
  let done = 0;
  let next = 0;
  let failure = null;
  try {
    const workers = Array.from({ length: 6 }, async () => {
      while (next < ASSETS.length && !failure) {
        const url = ASSETS[next++];
        try {
          if (!(await cache.match(url))) {
            const response = await fetch(url, { cache: 'reload' });
            if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
            await cache.put(url, response);
          }
          done++;
          if (done % 10 === 0 || done === ASSETS.length) port.postMessage({ type: 'progress', done, total: ASSETS.length });
        } catch (error) { failure = error; }
      }
    });
    await Promise.all(workers);
    if (failure) throw failure;
    await cache.put(READY, new Response('ready'));
    const names = await caches.keys();
    await Promise.all(names.filter((name) => name.startsWith('dm-offline-') && name !== CACHE).map((name) => caches.delete(name)));
    port.postMessage({ type: 'ready', done, total: ASSETS.length });
  } catch (error) {
    port.postMessage({ type: 'error', message: error instanceof Error ? error.message : String(error), done, total: ASSETS.length });
  } finally { downloading = false; }
}
`;
await writeFile(path.join(dir, 'sw.js'), sw);
console.log(`Offline edition: ${assets.length} assets, cache ${version}, base ${base}`);
