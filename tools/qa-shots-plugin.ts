import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Plugin } from 'vite';

/**
 * DEV-only: POST /__qa/shot?name=<slug> with a data URL body saves a README /
 * QA screenshot to docs/screenshots/<slug>.<ext>. Never part of production
 * builds (apply: 'serve').
 */
export function qaShots(): Plugin {
  return {
    name: 'cw-qa-shots',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/__qa/shot', (req, res) => {
        if (req.method !== 'POST') {
          res.statusCode = 405;
          return res.end();
        }
        const url = new URL(req.url ?? '', 'http://localhost');
        const name = (url.searchParams.get('name') ?? 'shot').replace(/[^a-z0-9-_]/gi, '').slice(0, 60) || 'shot';
        const chunks: Buffer[] = [];
        req.on('data', (c: Buffer) => chunks.push(c));
        req.on('end', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          const m = body.match(/^data:image\/(png|webp|jpeg);base64,(.+)$/);
          if (!m) {
            res.statusCode = 400;
            return res.end('expected an image data URL');
          }
          const dir = join(server.config.root, 'docs', 'screenshots');
          mkdirSync(dir, { recursive: true });
          const file = join(dir, `${name}.${m[1] === 'jpeg' ? 'jpg' : m[1]}`);
          writeFileSync(file, Buffer.from(m[2], 'base64'));
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ saved: file }));
        });
      });
    },
  };
}
