# AFK and ten-player browser checks

These tests use development debug hooks and temporary offline accounts. Install Playwright separately, or set `DM_PLAYWRIGHT_MODULE` to its installed module path and `DM_CHROMIUM_PATH` to a Chromium executable. Screenshots and measurements go to `DM_QA_ARTIFACT_DIR` (default: the system temporary directory).

For AFK, run `npm run dev -- --host 127.0.0.1 --port 5199 --strictPort`, then `node tools/qa/afk-smoke.cjs`. It verifies Skills controls, persisted background rewards without rendering, pause/resume and full-bag stopping. `DM_QA_URL` overrides the default offline preview URL.

For gathering visuals, run `node tools/qa/gather-tools-smoke.cjs` against the same offline preview. It starts all four AFK skills, checks each hand tool stays at a usable size, confirms the node circle stays visible while working, and verifies class gear returns when paused. Screenshots are written to `DM_QA_ARTIFACT_DIR` (or the system temporary directory). `DM_QA_CLASS='Hollow Knight' DM_QA_SKILL=woodcutting` checks a class with two weapon props.

For the five Release 0.3 classes, use the same dev server and run `node tools/qa/new-blood-smoke.cjs`.
It checks class selection at 1280×800, world entry, resource orbs, hero models, hotbars and a
primary hit. It also casts Warden Lantern Cone, Witch Harvest and Veil Tear in their class runs.
`DM_QA_CLASS=Veilwalker` limits the check to one class; `DM_QA_ARTIFACT_DIR=/tmp` saves screenshots.

For an actual Easy auto balance sample, run `node tools/qa/easy-auto-balance.cjs` against the offline preview. It creates a fresh character, enters the Graves, and advances three minutes with auto combat on, recording kills, deaths, health and flask use. `DM_QA_CLASS='Hollow Knight'`, `DM_QA_SECONDS=60`, and `DM_QA_SEED=43` narrow or repeat a run. The browser random seed helps comparison, but the run still depends on scene timing and is a sample, not a deterministic balance proof.

For ten-player co-op, start an **isolated test server**, never a production service:

```sh
REALTIME_PORT=5291 REALTIME_HOST=127.0.0.1 DEV_TRUST_TOKENS=1 NODE_ENV=test CORS_ORIGIN=http://127.0.0.1:5201 node server/realtime/server.js
VITE_WS_BASE=http://127.0.0.1:5291 npm run dev -- --host 127.0.0.1 --port 5201 --strictPort
node tools/qa/coop-ten-smoke.cjs
```

`DM_QA_REALTIME` and `DM_QA_URL` override the isolated server and offline co-op preview URLs. The test joins nine socket clients to a rendered host, rejects an eleventh player, checks chat/shared nodes/combat and host migration, and compares CPU update time with 40 enemies. It also records draw calls and triangles; CPU results alone do not establish hardware FPS. Never enable `DEV_TRUST_TOKENS` in production.

The VPS public-site check is `node tools/qa/live-domain-smoke.cjs --gather-check --afk-check`. Set `DM_QA_OWNER_USER` and `DM_QA_OWNER_PASSWORD` privately for the existing-account login check. `DM_QA_BACKEND` defaults to `/home/ubuntu/death-muffin/backend`; the script reads that installation's private `.env` and mysql2/dotenv dependencies to remove only its generated test account in a `finally` block. It checks authentication, class changes, gathering authorization/persistence, background AFK saves, pause and reload stopping, redirects and other public routes. Credentials and database snapshots must remain outside Git.

For starter-area visuals, run `node tools/qa/acre-smoke.cjs` against the offline preview on 5199 (or set `DM_QA_URL`). It checks low/high graphics, real mouse clicks on a beginner oak and grave from the entrance, compact hover cards, anchored fishing batches and renderer errors. Each interaction begins at the entrance to avoid AFK or ordinary Auto gathering moving the test character away between screenshots.

For counsel and lighting, run `node tools/qa/counsel-lighting-smoke.cjs` against the 5199 offline preview. It checks pointer/keyboard movement without hero movement, position persistence across queued cards and reloads, resize clamping, dismissal, initial Acre lighting, the sawpit beacon, and the unchanged combat lighting/light count. Add `--counsel-check` to the public domain smoke for production drag/reload verification.
