# Crossworlds Web — Claude Context

Browser client for Crossworlds BCE (Vite + TypeScript + Three.js), replacing the Unity
client. Talks to the existing Node/Express auth server — **never modify server endpoints
from this repo**; the REST API and MySQL schema are owned by the VPS
(see `D:\Crossworlds\_CONTEXT\CLAUDE.md` for the server side).

## Read before working

| Doc | When |
|---|---|
| `ACTION_PLAN.md` | phase roadmap + what stays/changes vs Unity |
| `PHASE_REPORTS.md` | what's already built and QA'd — **check before rebuilding anything** |
| `ASSET_PIPELINE.md` | generating/optimizing/wiring 3D models — **read before any Tripo work** |
| `SERVER_OPERATIONS.md` | realtime service + deploy scripts |
| `TEST_ACCOUNTS.local.md` | live-server QA logins (gitignored) |

## Ground rules

- API keys are in `.ai-keys.local` (gitignored) — load into env per-invocation, never
  commit, never bake into client code.
- Raw AI-generated assets go in `art-src/` (gitignored). Only optimized output
  (via `tools/build-models.mjs`) ships in `public/models/` (~2.5MB per character budget).
- Server class indices: 0=Engineer, 1=Guardian, 2=Shadowblade (Bo-Gar),
  3=Cleric (Brandolf), 4=Arcanist. Mirrors of this table exist in
  `src/gameplay/classes.ts` and `src/graphics/modelPaths.ts` — keep in sync.
- Realtime = Socket.io on port 5000 locally (`server/realtime/`); the client must keep
  working solo when it's down.
- Server `error` strings are player-readable — show them verbatim in UI.
- Desktop web game first; narrow viewport only needs sanity checks.
- Commits go through the user's GitHub Desktop flow — stage, don't commit.

## Layout

```
src/net/        REST client (existing endpoints) + Socket.io realtime client
src/scenes/     Login, CharacterSelect, Hub, Arena, Boss (SceneManager routes)
src/gameplay/   classes, movement, abilities, enemies, loot, stats, boss
src/graphics/   renderer, CharacterModel (GLB rig + clip loader), modelPaths, backdrop
src/ui/         HTML/CSS overlay panels (inventory, forge, professions) + ui.css
tools/          build-models.mjs — raw Tripo → shippable GLBs (see ASSET_PIPELINE.md)
art-src/        RAW AI asset outputs + Tripo task JSONs (gitignored, 1.7GB)
public/models/  optimized shipped models   public/art/  2D art (icons, portraits, vfx)
server/         realtime service + deploy packages (VPS deploy pending, SSH denied here)
```

## Verification

`npx tsc --noEmit`, then dev server on port 5188 and QA against the LIVE auth server
(proxied via vite.config.ts). Preview screenshots time out on this app — use the
`window.__cwDebug` hook (DEV-only, HubScene) + WebGL readPixels; details in
ASSET_PIPELINE.md §4.
