'use strict';
// Loopback-only HTTP front for the Discord bot adapter. Shared secret in x-dm-secret. Usage: node server.cjs [config.json]
const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const { loadConfig } = require('./lib/config.cjs');
const { createRunner } = require('./core.cjs');
const { setKnownSecrets } = require('./lib/redact.cjs');

function startServer(cfg, runner, secret) {
  const eq = (a, b) => { const x = Buffer.from(String(a || '')), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };
  const srv = http.createServer(async (req, res) => {
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    try {
      if (!eq(req.headers['x-dm-secret'], secret)) return send(401, { error: 'unauthorized' });
      const url = new URL(req.url, 'http://x');
      if (req.method === 'GET' && url.pathname === '/health') return send(200, { ok: true });
      if (req.method === 'GET' && url.pathname === '/config') return send(200, { channelId: cfg.channelId, guildId: cfg.guildId });
      if (req.method === 'GET' && url.pathname === '/poll') return send(200, { ops: await runner.poll(Math.min(30000, Number(url.searchParams.get('wait')) * 1000 || 0)) });
      if (req.method !== 'POST') return send(404, { error: 'not found' });
      // 1 MB everywhere, except /event which may carry up to 4 images of 8 MB as base64 (4 x 8 MB x 4/3 ~ 43 MB, so 48 MB).
      const limit = url.pathname === '/event' ? 48e6 : 1e6; const chunks = []; let n = 0;
      for await (const c of req) { n += c.length; if (n > limit) return send(413, { error: 'too big' }); chunks.push(c); }
      const body = Buffer.concat(chunks).toString('utf8');
      const j = body ? JSON.parse(body) : {};
      if (url.pathname === '/event') return send(200, await runner.handleEvent(j));
      if (url.pathname === '/bind') return send(200, await runner.bind(j));
      if (url.pathname === '/ack') { runner.ack(j.id, j.result); return send(200, { ok: true }); }
      return send(404, { error: 'not found' });
    } catch (e) { console.error('request failed', e); send(500, { error: 'internal' }); }
  });
  return srv;
}
module.exports = { startServer };

if (require.main === module) {
  const file = process.argv[2] || '/home/ubuntu/death-muffin/discord-agent/config.json';
  const cfg = loadConfig(file); cfg.__file = file;
  const secret = fs.readFileSync(cfg.secretFile, 'utf8').trim();
  setKnownSecrets([secret]);
  if (!cfg.ownerIds.length) { console.error('config.ownerIds is empty; refusing to start'); process.exit(1); }
  const runner = createRunner(cfg);
  const srv = startServer(cfg, runner, secret);
  srv.listen(cfg.runnerPort, '127.0.0.1', () => console.log(`dm-agent runner on 127.0.0.1:${cfg.runnerPort}`));
  setInterval(() => runner.sweep().catch(() => {}), 6 * 3600e3).unref();
}
