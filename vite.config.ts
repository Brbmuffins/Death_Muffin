/// <reference types="vitest" />
import { defineConfig } from 'vite';
import { qaShots } from './tools/qa-shots-plugin';

// The live auth server has no CORS headers, so the dev server proxies all API
// routes same-origin. Old endpoints live at the root (/login, /character, ...),
// new ones under /api — proxy each prefix.
const API_TARGET =
  process.env.VITE_API_PROXY_TARGET ?? 'http://127.0.0.1:5190';

const apiPaths = ['/api', '/login', '/register', '/character', '/items'];

// Production deploy sets DEPLOY_BASE (e.g. /play/) so assets resolve under the
// subpath; dev leaves it relative. Sourcemaps only in dev — don't publish source.
const DEPLOY_BASE = process.env.DEPLOY_BASE ?? './';

export default defineConfig({
  base: DEPLOY_BASE,
  plugins: [qaShots()],
  // vitest: game-logic unit tests only (the realtime server uses node:test).
  test: { include: ['src/**/*.test.ts'] },
  server: {
    port: 5188,
    proxy: Object.fromEntries(
      apiPaths.map((p) => [p, { target: API_TARGET, changeOrigin: true }]),
    ),
  },
  build: {
    outDir: 'dist',
    sourcemap: DEPLOY_BASE === './',
    rollupOptions: {
      output: { manualChunks: { three: ['three'] } },
    },
  },
});
