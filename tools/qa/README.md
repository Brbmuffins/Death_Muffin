# AFK and ten-player browser checks

These tests use development debug hooks and temporary offline accounts. Install Playwright separately, or set `DM_PLAYWRIGHT_MODULE` to its installed module path and `DM_CHROMIUM_PATH` to a Chromium executable. Screenshots and measurements go to `DM_QA_ARTIFACT_DIR` (default: the system temporary directory).

For AFK, run `npm run dev -- --host 127.0.0.1 --port 5199 --strictPort`, then `node tools/qa/afk-smoke.cjs`. It verifies Skills controls, persisted background rewards without rendering, pause/resume and full-bag stopping. `DM_QA_URL` overrides the default offline preview URL.

For ten-player co-op, start an **isolated test server**, never a production service:

```sh
REALTIME_PORT=5291 REALTIME_HOST=127.0.0.1 DEV_TRUST_TOKENS=1 NODE_ENV=test CORS_ORIGIN=http://127.0.0.1:5201 node server/realtime/server.js
VITE_WS_BASE=http://127.0.0.1:5291 npm run dev -- --host 127.0.0.1 --port 5201 --strictPort
node tools/qa/coop-ten-smoke.cjs
```

`DM_QA_REALTIME` and `DM_QA_URL` override the isolated server and offline co-op preview URLs. The test joins nine socket clients to a rendered host, rejects an eleventh player, checks chat/shared nodes/combat and host migration, and compares CPU update time with 40 enemies. It also records draw calls and triangles; CPU results alone do not establish hardware FPS. Never enable `DEV_TRUST_TOKENS` in production.

The VPS public-site check is `node tools/qa/live-domain-smoke.cjs --gather-check --afk-check`. Set `DM_QA_OWNER_USER` and `DM_QA_OWNER_PASSWORD` privately for the existing-account login check. `DM_QA_BACKEND` defaults to `/home/ubuntu/death-muffin/backend`; the script reads that installation's private `.env` and mysql2/dotenv dependencies to remove only its generated test account in a `finally` block. It checks authentication, class changes, gathering authorization/persistence, background AFK saves, pause and reload stopping, redirects and other public routes. Credentials and database snapshots must remain outside Git.
