# Crossworlds Web

Browser client for Crossworlds BCE — Vite + TypeScript + Three.js.  
**Play now:** https://playcrossworlds.com/play/

Talks directly to the existing Node/Express auth server — no server changes required for login, character, inventory, professions, or crafting.

---

## What's Built

### Core flow
- **Login** — fantasy panel with animated crystal-shard backdrop, parallax mouse sway, shake-on-error, register mode ("Forge Your Legend")
- **Character Select** — class cards with hero portraits; 5 classes (Warden, Ironclad, Shadowblade, Cleric, Arcanist)
- **Hub** — inventory bag, professions panel, forge crafting, gold + stat HUD, live party slots, chat overlay
- **Arena** — portal transition, wave enemies, HP bar, floating damage numbers, loot drops → inventory save
- **Boss Scene** — Null Architect encounter (in progress)

### Gameplay
- **Click-to-move** (Diablo-style) — ground-plane raycast, hold to steer; WASD fallback
- **Ability bar** — 1/2/3/4 keys, per-class kits (basic / heavy / nova AoE / ultimate), radial cooldown sweeps, clickable
- **Enemies** — patrol waypoints, aggro range, chase, contact damage, leash + respawn
- **Loot** — DropTable (copper shard/bar/ring), stacks materials, POSTs to `/api/inventory/save` on pickup
- **Progression** — XP/level pills, kill XP banking, level-up toast, saved on hub return

### Multiplayer (local — VPS deploy pending)
- Socket.io realtime service (port 5000, JWT handshake)
- Rooms capped at 4; WASD position relay at ~10Hz with lerp interpolation
- Host-simulated enemies broadcast at 10Hz; non-hosts send hit events to host; host promotion on leave
- Party slots, chat, join/leave toasts

### Art
- **16 ability icons** (4 per class) — generated via Gemini
- **Item icons** — copper shard, bar, ring
- **Status effect icons** — 10 states (void-rot, burning, cursed, renewal, etc.)
- **Hit VFX sprites** — physical, void, holy, frost, fire
- **5 rigged 3D character models** — Tripo AI v1.0 biped rigs, idle/walk/run/attack clips, normalized to 1.8u height; wired in Hub + Arena via GLTFLoader + AnimationMixer

---

## Status

| System | Status |
|---|---|
| Auth / login / register | ✅ |
| Character select | ✅ |
| Hub (inventory, professions, forge) | ✅ |
| Arena (enemies, loot, XP) | ✅ |
| Diablo-style controls + ability bar | ✅ |
| Fantasy UI + art pass | ✅ |
| 3D character models | ✅ wired (Brandalf attack clip pending) |
| Multiplayer realtime | ✅ local · 🔶 VPS deploy pending |
| Static site deploy (`/play/`) | ✅ script ready · 🔶 needs SSH run on VPS |
| Boss scene | 🔶 in progress |
| Slime 3D model | 🔶 pending |

---

## Local Setup

```
npm install
npm run dev
```

Opens at http://localhost:5188. Override the API server with a `.env`:

```
VITE_API_BASE=http://localhost:3000
```

---

## Deploy

Two one-shot scripts — upload to VPS and run:

```bash
# Static web client → https://playcrossworlds.com/play/
sudo bash deploy-web.sh

# Realtime co-op service → wss://playcrossworlds.com/rt/socket.io
sudo bash server/realtime/deploy-realtime.sh
```

See `server/realtime/DEPLOY.md` for nginx config, verification steps, and rollback.

---

## Structure

```
src/
  net/          REST client + realtime Socket.io wrapper
  scenes/       Login, CharacterSelect, Hub, ArenaScene, BossScene, SceneManager
  gameplay/     classes, abilities, enemies, loot, movement, stats
  graphics/     renderer, CharacterModel (GLTFLoader + AnimationMixer), loginBackdrop
  ui/           InventoryPanel, ForgePanel, ProfessionsPanel

server/
  realtime/     Socket.io service (JWT auth, rooms, host simulation relay)
  web-deploy/   deploy-web.sh + production build artifact

tools/
  build-models.mjs   asset pipeline: Tripo raws → optimized rig.glb + per-clip GLBs

art-src/tripo/  raw Tripo outputs (gitignored — 1.7GB)
public/
  art/          ability icons, item icons, status icons, hit VFX sprites
  models/       optimized character GLBs (~13MB total)
```

---

## Unity Client

The desktop Unity client lives at [Crossworlds-BCE](https://github.com/Brbmuffins/Crossworlds-BCE) — same auth server, same API, separate codebase. This repo is linked as a submodule (`web/`) inside that repo.
