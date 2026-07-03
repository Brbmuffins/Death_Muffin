# Crossworlds Web

Browser client for Crossworlds BCE — Vite + TypeScript + Three.js, replacing the Unity client.
Talks directly to the existing Node/Express auth server (`playcrossworlds.com:3000`) — no server changes required for login, character, inventory, professions, or crafting.

## Setup (run locally — this sandbox has no npm registry access)

```
npm install
npm run dev
```

Opens at http://localhost:5188. Point it at a different auth server with a `.env`:

```
VITE_API_BASE=http://localhost:3000
```

## Status

Phase 0/1 scaffold: Login -> Character Select -> Hub, wired to the real auth API.
See `ACTION_PLAN.md` (project root) for the full phased roadmap, including the
Phase 3 realtime co-op layer (WebSocket, 4-player parties — Mirror/UDP has no
browser equivalent, so this is new additive server work).

## Structure

```
src/net/        REST client (existing endpoints) + realtime config stub
src/scenes/     Login, CharacterSelect, Hub (SceneManager routes between them)
src/gameplay/   class data, entity/combat logic (grows in Phase 2+)
src/graphics/   renderer, lighting, materials, VFX (AAA polish pass, Phase 6)
src/ui/         HUD/menu CSS, panels
```
