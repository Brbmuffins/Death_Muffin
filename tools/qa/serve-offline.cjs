/** Static preview matching the deployed /death-muffin/offline/ path. */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const base = '/death-muffin/offline/';
const root = path.resolve(__dirname, '../../dist-offline');
const port = Number(process.env.DM_OFFLINE_PREVIEW_PORT || 5397);
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp', '.glb': 'model/gltf-binary', '.ogg': 'audio/ogg', '.woff': 'font/woff', '.woff2': 'font/woff2' };

http.createServer((req, res) => {
  let pathname;
  try { pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); }
  catch { res.writeHead(400).end(); return; }
  if (!pathname.startsWith(base)) { res.writeHead(404).end(); return; }
  const relative = pathname.slice(base.length) || 'index.html';
  const file = path.resolve(root, relative);
  if (!file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
  fs.stat(file, (error, info) => {
    if (error || !info.isFile()) { res.writeHead(404).end(); return; }
    res.setHeader('Content-Type', mime[path.extname(file)] || 'application/octet-stream');
    res.setHeader('Content-Length', info.size);
    res.setHeader('Cache-Control', 'no-cache');
    if (req.method === 'HEAD') { res.writeHead(200).end(); return; }
    if (req.method !== 'GET') { res.writeHead(405).end(); return; }
    fs.createReadStream(file).pipe(res);
  });
}).listen(port, '127.0.0.1', () => console.log(`Death Muffin offline preview: http://127.0.0.1:${port}${base}`));
