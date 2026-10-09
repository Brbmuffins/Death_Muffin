# Crossworlds Web — Action Plan

> **OBSOLETE (archived 2026-10-09).** The original plan for the web client (Unity replacement, Vite + Three.js). The web client is frozen and the project is now the Godot rebuild. History only; see [docs/ARCHIVE.md](docs/ARCHIVE.md).

Goal: replace the Unity client with a browser client (Vite + TypeScript + Three.js), reusing the existing Node/MySQL auth server as-is, built to the visual/workflow standard of `threejs-game-skills` (director → gameplay systems → AAA graphics → UI → debug → QA).

## What stays the same

- Auth server: Node/Express on port 3000, `/opt/rod-auth/server.js` — untouched
- MySQL schema (`rod_online`) — untouched
- JWT auth flow, `/login`, `/character`, `/api/inventory/*`, `/api/professions/*`, `/api/craft`, `/api/character/save-progress` — called directly from the browser via `fetch`, same request/response shapes as Unity uses today
- Dashboard (port 4000) — untouched, keeps working as GM tooling regardless of client
- 5 classes, scene order (Login → CharacterSelect → Hub → Portal/Arena), loot/inventory/crafting data model

## What has to change

- **Rendering engine**: Unity/URP → Three.js scene graph, glTF models, WebGL materials/postprocessing instead of URP shaders
- **Input/UI**: Unity uGUI → HTML/CSS overlay + Three.js canvas (the UI skill's territory)
- **Real-time multiplayer**: this is the one substitution with no free lunch. Unity used **Mirror over raw UDP (KCP) on port 7777** — browsers cannot open raw UDP or arbitrary TCP sockets. This needs a **WebSocket layer** (Socket.io or plain `ws`) for position sync, combat events, and chat. This is new server code, additive to the existing auth server — it does not touch the REST endpoints or schema. Treat it as its own milestone, not a detail.
- **Builds/deploy**: `Build/CrossworldsBCE.x86_64` → static Vite build served from Nginx (`/var/www/rod/`, same box, same SSL) — actually simpler than the current Unity deploy.

## Stack

- Vite + TypeScript + Three.js (matches `threejs-game-skills` scaffold exactly)
- `src/net/` — REST client (existing endpoints) + WebSocket client (new realtime layer)
- `src/scenes/` — Login, CharacterSelect, Hub, Arena
- `src/gameplay/` — entity/component structure, movement, combat, camera
- `src/graphics/` — models, materials, lighting, VFX, postprocessing
- `src/ui/` — HUD, inventory grid, crafting panel, login/char-select forms
- Playwright for QA screenshots + canvas pixel checks (mirrors the `threejs-qa-release` skill's evidence bar)

## Phased roadmap

**Phase 0 — Scaffold (today)**
Vite+TS+Three.js project structure, git repo in `Cross Worlds Web`, base HTML/CSS shell, empty Three.js scene rendering and resizing correctly.

**Phase 1 — Login → Character Select (thin vertical slice)**
Real `POST /login` call against the live auth server, JWT stored client-side, `POST/GET /character` to create/load a character, a simple 3-model character-select carousel. This proves the whole chain end-to-end before any gameplay work.

**Phase 2 — Hub scene + inventory/professions**
`GET /api/inventory/:characterId`, `GET /api/professions/:characterId`, render a hub environment, bag UI (4×6 grid to match Unity's), equip/unequip calling `/api/inventory/equip`, stat recalculation from `stat_bonus` JSON.

**Phase 3 — Realtime layer**
Stand up the WebSocket service (new, additive), broadcast position/state between connected players in a hub/arena, replacing what Mirror/KCP did for Unity.

**Phase 4 — Arena/combat**
Enemy spawns, aggro, hit confirm, death, `DropTable`-equivalent loot drops, `POST /api/inventory/save` on pickup — parity with the Unity Week 4 tasks already scoped in Phase 1 server work.

**Phase 5 — Crafting + progression polish**
Forge UI, `GET /api/recipes`, `POST /api/craft`, level-up flow, `POST /api/character/save-progress` on level-up/hub-return.

**Phase 6 — AAA polish + QA pass**
Lighting/materials/VFX pass, HUD/UI responsive + mobile pass, Playwright screenshot + canvas-pixel + perf checks before calling anything "done," matching the evidence bar `threejs-qa-release` expects.

## Skill mapping (their repo → this project)

| Their skill | Applied here as |
|---|---|
| `threejs-game-director` | overall build orchestration across phases above |
| `threejs-gameplay-systems` | scaffold, movement/camera/combat architecture, entity structure |
| `threejs-aaa-graphics-builder` | hub/arena environment art, lighting, materials, VFX |
| `threejs-game-ui-designer` | HUD, inventory/crafting panels, login/char-select forms, mobile safe areas |
| `threejs-debug-profiler` | perf/draw-call/mobile debugging once scenes get heavier |
| `threejs-qa-release` | Playwright screenshot + canvas + build verification before marking phases done |
| `threejs-3d-generator` / `threejs-image-generator` / `threejs-audio-generator` | optional — only if you want AI-generated models/art/SFX instead of sourced/procedural assets (needs API keys, none set up yet) |

Note: their package installs as Claude Code/Codex skill files (`npx skills add ...`), which isn't how Cowork loads skills. I'm using their scaffold and workflow structure directly rather than the skill files themselves — same result, no install step needed.

## Open decisions for you

1. Realtime transport: Socket.io (simpler, more overhead) vs raw `ws` (leaner, more manual). Recommend Socket.io to start — matches Mirror's "just works" feel.
2. Asset source: procedural/primitive placeholder art now, or pull in AI-generated models/textures (Tripo/Gemini/ElevenLabs) once we're past the vertical slice — needs API keys.
3. Do you want the Unity client kept running in parallel during the web build-out, or is this a hard cutover once the web client reaches feature parity?
