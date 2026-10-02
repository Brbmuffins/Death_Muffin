# AFK and ten-player browser checks

These tests use development debug hooks and temporary offline accounts. Install Playwright separately, or set `DM_PLAYWRIGHT_MODULE` to its installed module path and `DM_CHROMIUM_PATH` to a Chromium executable. Screenshots and measurements go to `DM_QA_ARTIFACT_DIR` (default: the system temporary directory).

For AFK, run `npm run dev -- --host 127.0.0.1 --port 5199 --strictPort`, then `node tools/qa/afk-smoke.cjs`. It verifies Skills controls, persisted background rewards without rendering, pause/resume and full-bag stopping. `DM_QA_URL` overrides the default offline preview URL.

For gathering visuals, run `node tools/qa/gather-tools-smoke.cjs` against the same offline preview. It starts all four AFK skills, checks each hand tool stays at a usable size, confirms the node circle stays visible while working, and verifies class gear returns when paused. Screenshots are written to `DM_QA_ARTIFACT_DIR` (or the system temporary directory). `DM_QA_CLASS='Hollow Knight' DM_QA_SKILL=woodcutting` checks a class with two weapon props.

For the gathering tool belt, run `node tools/qa/tool-belt-smoke.cjs` against an offline preview (it needs no live server). It tools up a new character, takes the one-time "Belt your best tools?" offer, checks the belt tools set the gathering tier, unbelts into the bag, starts AFK woodcutting and reads the hero's held tool and the Skills line, then fills the bag and checks the readable refusal. Screenshots go to `DM_QA_ARTIFACT_DIR`.

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

For the 2026-09-30 content, run these against the 5199 offline preview (`DM_QA_ARTIFACT_DIR=/tmp` saves screenshots). Run them one at a time on an idle machine: a leftover headless Chromium (or another heavy process) makes `page.screenshot` time out, which looks like a game hang and is not.

- `node tools/qa/pyre-smoke.cjs`: the Cinder Pyre zone, the four fire mobs, a live coal/slam/husk-death, and a perf comparison against the Cloister roster.
- `node tools/qa/regent-smoke.cjs`: wakes the Cinder Regent and screenshots the awake boss, the Conflagration windup (ash circles) and the eruption.
- `node tools/qa/levels-smoke.cjs`: Catacomb Warren, Bone Coliseum and Cinder Pyre screenshots after a couple of waves (`DM_QA_AREAS=coliseum` for one).
- `node tools/qa/fen-smoke.cjs` (port 5306 on this branch): the Mourning Fen landing and marsh, bog slow vs hummocks (moveMult 1 / 0.78), each mob at rest, the Bog Hag's hex landing on thralls, the wisp pulse and sexton hook telegraphs, and a perf comparison against the Graves roster.
- `node tools/qa/mire-mother-smoke.cjs`: wakes the Mire Mother and steps through the ripple ring and burst, phase 2 (hummocks shrink), and phase 3 (the Drowned Rite over corpses).
- `node tools/qa/chain-smoke.cjs`: 14 own kills build the Kill Chain readout (×14 Rampage), the weekly Omen chip is present, the chain breaks and hides, and the chain-10 milestone is paid.
- `node tools/qa/spell-swap-smoke.cjs`: five visible hotbar swap controls, level-gated rite choices, an equipped-rite swap and reload persistence. Use `DM_QA_URL` for the dev server URL; screenshots go to `DM_QA_ARTIFACT_DIR` or `/tmp/death-muffin-spell-swap`.
- `node tools/qa/necro-audit.cjs clips`: inspect one necromancer's cast clips with `DM_QA_DISC=Ossuary`. Other modes are `gear`, `thralls`, `hud`, `perf` and `all`; save its screenshots and report outside Git with `DM_QA_ARTIFACT_DIR`.
- Playwright is not installed in the repo. On this VPS it lives in the npx cache: `DM_PLAYWRIGHT_MODULE=/home/ubuntu/.npm/_npx/e41f203b7505f1fb/node_modules/playwright`.

For the visible Grave Laborers, run `node tools/qa/laborers-smoke.cjs` against `npm run dev -- --host 127.0.0.1 --port 5325 --strictPort` (`DM_QA_URL` overrides). It assigns all four laborers through the real H panel in the offline mock, checks placement, tools, ready/full states, hover cards, click-to-open and that nothing is shown outside the Acre, and writes close-up screenshots plus a wide shot to `DM_QA_ARTIFACT_DIR`. Vite may log 403s for font files when `node_modules` is a symlink; the script ignores those.

For gentle guidance (the Prior, the Sexton, the Apothecary and the "Next" line), run `node tools/qa/guidance-smoke.cjs` against an offline preview (dev server on port 5338 here). It uses a fresh character: a real mouse click opens the Sexton's conversation, **E** opens the Prior's and the Apothecary's, then it changes real state (kills, a broken seal, shards, a first-kill trophy through the same storage as a real boss kill, the Prelate, a full bag, ready laborers, contracts) and asserts the line each time. It also checks the dismiss button, both Settings toggles, the saved memory and the Codex People tab. 13 screenshots go to `DM_QA_ARTIFACT_DIR`.
