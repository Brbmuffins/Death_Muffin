# Godot rebuild: decisions and plan

Owner direction, 2026-10-05: Godot **replaces** the three.js client (not a parity port any more), the server side and relay can change as
needed, and Godot-idiomatic rebuilds are welcome where they pay off. This file supersedes the "reproduce the web exactly" rule in
`PORTING.md` for the systems listed below; everything not listed here keeps the PORTING.md conventions.

## Decisions (D1-D13; D2 + D4-D9 confirmed by the owner 2026-10-05, D10-D13 on 2026-10-07, D1/D3 defaults)

**D1. Trust model.** The host's Godot game is authoritative for its session (combat, enemies, corpses, thralls, waves, bosses). Clients
send intents (move, cast, interact) as RPCs to the host. The **backend** stays authoritative for anything that persists or has value:
accounts, characters, inventory, gold/shards, loot rolls (server-rolled, as today), progression saves, and the kill ledger with its
sanity caps. A cheating host can ruin its own session, but cannot mint items or gold beyond what the backend's caps accept.

**D2. Party size.** 4 players per session (was 10 in the web realtime). Owner confirmed 2026-10-05. One constant: `DmSession.MAX_PLAYERS := 4`.

**D3. Connectivity.** Listen-server host (the host's game is the session), connected through a **relay on the VPS**: the lobby service
lists/creates sessions and forwards opaque game packets between host and clients over WebSocket, so it works behind any NAT with no port
forwarding. Godot side: a `MultiplayerPeerExtension` (`DmRelayPeer`) that tunnels through the relay, so the session code is plain Godot
high-level multiplayer (RPCs, `MultiplayerSpawner`/`MultiplayerSynchronizer`) and also runs on `ENetMultiplayerPeer` for LAN and tests.
The Socket.IO protocol (`godot/net/realtime/`, `server/realtime/`) is retired once the new path carries a full session.

**D4. Offline stays** (owner, 2026-10-05: "keep offline"). Solo offline is a 1-player session hosted locally with no relay, backed by the
local GDScript backend (`godot/net/offline/`, `DmMockBackend`) instead of the VPS backend. The offline backend is production code: it keeps
working, it implements the same backend API the online game uses (including loot rolls), and the "server-rolled loot / kill ledger" rules
run inside it for offline characters. Offline and online characters stay separate (no offline -> cloud sync of value).

Owner answers, 2026-10-05:
- **D5. Priorities: solo first, online in the back seat.** The rebuild is built on the session structure (so online stays possible), but
  phases prove and polish **solo/offline play first**; lobby UI, relay deployment and multi-player testing come later.
- **D6. Host quits = session ends** for everyone (each member keeps what the backend already credited). No host migration.
  VPS-hosted (headless Godot) sessions are a future option, not planned now.
- **D7. Branches.** The rebuild lives on **`godot-next`**, which is now the single line (owner, 2026-10-09): fixes, perf and features ship from it, and
  the launcher client is published from it (`server/death-muffin/publish-godot-client.sh`). `godot-port` was merged into it and is only fast-forwarded to it.
- **D8. Characters.** Existing online characters carry into Godot online unchanged (same backend). Offline characters stay offline-only.
- **D9. Web retirement.** The three.js game is retired once the Godot game is complete: taken offline (not publicly reachable), its code kept
  in git history only.

Owner decisions, 2026-10-07:
- **D10. Online unlock = staff/GM accounts first.** Other accounts see "Online opens soon". Live since 2026-10-07: the client gate (after sign-in:
  the manifest's `online` block, then `GET /api/me` staff flag; fails closed), launcher 0.6.1 and the manifest's `online.staff`.
- **D11. Lobby = private codes + a public list of open sessions.** Built; deployed as the staff-gated systemd service `deathmuffin-lobby` on :5192.
- **D12. Migration 041 approved and applied** (the sessions tables). Back up first; verify with `qa_offline_sync` only.
- **D13. Disconnects get a rejoin window.** Reverses the earlier "reconnect not planned" (D6 still holds for the host: host quits = session ends).
  NOT built yet; tracked under Phase 7.

## Performance rule (owner, 2026-10-05: "performance continues to be my main focus. anything that gets added needs to perform well too, no bloat")

Every track and every merge: (1) measured cost of what was added (frame/tick, load, memory) with before/after numbers, or it is not
merged; (2) event-driven or throttled over per-frame work, no per-frame allocations in hot paths, pool what spawns often; (3) lean code:
no speculative abstractions, layers, config or files; reuse instead of duplicating; temporary code removed; (4) first-use work
(shaders, scenes, effects, fonts) warmed during loading, never mid-play; (5) perf budgets in tests use generous margins (the VPS is
shared) but must catch real regressions.

## Assets rule (owner, 2026-10-05)

Reuse the existing audio, music, models, animations and **VFX** (the owner likes the current vibe): the Binbun effects already in the
project, the `Vfx` autoload (emit/smoke/decal/beam/light flash/motifs), the telegraph and spell looks (`SPELL_FX` colours) as they are now.
This is the default, not a hard rule (owner): a different effect is fine when it saves real time, as long as it performs at
least as well and keeps the same readability. Generation is a backup, used only when
something needed doesn't exist or is unusable: **ElevenLabs** for sound effects/music/ambience (`tools/audio/generate-eleven-*.mjs`,
key in `~/death-muffin/private/elevenlabs-api-key`), **Tripo** for models (`tools/ai/tripo.mjs`, `ASSET_PIPELINE.md`; budget per
the autonomy grant). Focus is getting the rebuild working; polish passes can use these later.

## Classification (from the owner's architecture review)

| Area | Verdict | Notes |
|---|---|---|
| Client architecture | REFACTOR | keep UI panels, HUD, VFX; scene-first structure; shrink the `DmGame` hub; drop web settings keys |
| Enemies, AI, navigation | REFACTOR -> REBUILD | enemy scenes + state machines + NavigationServer3D, one kind at a time; drop bit-exact math |
| Combat | REFACTOR | keep rite data and numbers; intents/events become client->host RPCs |
| Multiplayer / networking | REBUILD | Godot multiplayer, listen-server host, relay (D3), party of 4 (D2) |
| Server / backend | REFACTOR | keep accounts/characters/inventory/economy + kill ledger + server-rolled loot; realtime becomes lobby + relay; drop the TS-rules bundle |
| Saves / accounts | REFACTOR | keep JWT + cloud characters; keep the offline edition (D4) on the local GDScript backend; solo = a 1-player session, online or offline |
| Data / items / loot / progression | KEEP content, REFACTOR format | one source of truth in `godot/data`; drop the TS exporters when the web retires; loot rolls from the backend |

## Target

```
Godot client  <->  Host's Godot game (authoritative sim, 1-4 players)
      \                |
       +--- Lobby/relay service (find a game, relay packets) ---+
       +--- Backend (accounts, characters, inventory, loot rolls, persistence) ---+
```

## Phases

0. **Decisions**: D1-D3 above.
1. **Foundation** (wave 1, parallel tracks):
   - `godot/session` (branch `godot/session`): `DmSession` host/join/leave on Godot high-level multiplayer, peer roster (cap 4), player
     spawn/despawn, movement-only replication test (two headless instances over ENet on 127.0.0.1).
   - `godot/relay` (branch `godot/relay`): lobby + relay service in `server/death-muffin/lobby/` (Node, its own tests) and the
     `DmRelayPeer` MultiplayerPeerExtension client in `godot/net/relay/`, proven with the session movement test over the relay.
   - `godot/data` (branch `godot/data-registry`): one content registry (`DmData`) over `godot/data`, merging the duplicate loot and
     progression content files; every rules suite still passes.
2. **Vertical slice** (a small, complete piece of the game on the new structure, to prove it before converting everything; solo first,
   D5): Chapterhouse + Hollow Graves as a 1-player session (online and offline backends): move, cast 2 Gravecaller rites, robbers as
   enemy scenes with state machines and navigation, kills reported through session reports, server-rolled loot picked up. A second
   player joining over the relay is the last step of the slice, not the first.
3. **Port systems** onto the foundation: enemy scenes (one kind at a time), combat and rites over RPC, loot and progression.
4. **Backend integration**: cloud characters online, server-rolled loot, session-end report; solo as a 1-player session (online via the
   VPS backend, offline via the local backend, D4).
5. **Content migration**: bosses, then the Depths, then the remaining areas. Then retire the web build (D9) and its TS exporters.
6. **Quality pass (DONE on the live client, synced into the rebuild 2026-10-08; originally planned for after gameplay is stable; owner 2026-10-06: ground markings / overall image look reduced, more pixelated).**
   Known causes: the auto-resolution governor drops the 3D view to as low as 60% (`DmResolutionGovernor.MIN = 0.6`) with bilinear
   upscaling; MSAA is off (`msaa_3d=0`). Plan: quality presets (Low/Medium/High/Ultra; High on a real GPU = full resolution + AA,
   governor only on lower presets, floor ~0.85); sharper decals/ground markings (texture size, mipmaps, anisotropic filtering);
   evaluate Forward+ for PC (better lighting, FSR upscaling) vs Compatibility on the owner's and Helix's PCs. Every change measured
   (Performance rule).
   - **Graphics quality pass** (owner 2026-10-06: ground markings and the overall image look reduced/pixelated). BUILT on `godot/quality`
     (renderer stays gl_compatibility):
     - Presets Low / Medium / High / Ultra (`game/dm_graphics_preset.gd`, one table; the saved `graphics` value is the preset id, old
       "high"/"low" load unchanged, new players = High). MSAA (2/4/8x) and anisotropic level are set on the viewport at runtime by
       `DmGame._apply_graphics`, plus shadow atlas size / reach / PSSM splits / soft-shadow filter, prop-light count, prop shadow range and mesh LOD (High and Ultra are
       genuinely richer than the old High: 10 / 14 lights, 4096 shadows reaching 55 / 80 m, Ultra = 8x MSAA, 16x aniso, soft-shadow HIGH, LOD 0.5);
       `project.godot` is untouched. Glow upscale quality is a project setting (not per-viewport) and was left alone.
       (Follow-up 973880ea: MSAA is Ultra-only, 4x; Medium and High keep the 0.85 floor + anisotropic textures until real-GPU numbers exist. The table in the code is authoritative.)
     - Resolution governor floor is per preset (`DmResolutionGovernor.set_floor`): Low 0.6, Medium/High/Ultra 0.85. Behaviour is still timid.
     - Sharper ground markings: sigil ring texture 128 -> 256 px with mipmaps, ground/wall materials use trilinear + anisotropic filtering,
       floor/wall + decal textures import with mipmaps, the fx decal shader samples `filter_linear_mipmap_anisotropic`.
     - Tests: `tests/game/graphics_run.gd`; shots: `tests/perf/quality_shot.gd`; `combat_perf.gd --graphics=`.
   - **Forward+ evaluation (NOT done, needs real PCs).** Would buy: FSR 1/2 upscaling (a far better "Auto resolution" than bilinear, so the governor
     could go lower without the pixel look), TAA, SSAO/SSIL-class effects, clustered lights (no 8-light prop cap, no per-object light
     limit on floors), better shadows, decals as real projected `Decal` nodes instead of quads, better glow.
     Costs: needs Vulkan/D3D12 (older iGPUs and some laptops fall back or fail; the VPS has none), heavier baseline GPU cost and VRAM,
     longer shader compile / first-frame stutter, the web/mobile exports stay Compatibility so we would carry two render paths (the
     MultiMesh COLOR handling, shader `render_mode`s and the light caps are Compatibility-specific), and every fx shader and perf budget
     would need re-measuring. Must be tested on the owner's and Helix's real PCs before any switch: frame time (avg/p99) in the Hollow
     Graves with 20+ enemies and a boss at 1080p/1440p on Low/High, FSR quality modes vs native + MSAA, first-frame / shader-compile hitch,
     VRAM, driver failures, and a Compatibility fallback (`renderer/rendering_method.fallback`). Do it on a separate branch behind a
     project/launcher flag, not as a preset.
7. **Hardening**: disconnects, host migration (or clean session end), desync checks, cheating review.

## Status

Updated 2026-10-09 (branches unified: `godot-port` merged into `godot-next`, which is now the single line and the default client; earlier 2026-10-08 sync: spawn-outside-aggro fix included). Feature-by-feature detail is `godot/PARITY.md`.

| Phase | State |
|---|---|
| 0 Decisions | D1-D13 recorded (D10-D13 from the owner 2026-10-07); D1/D3 defaults |
| 1 Foundation (session, relay, data registry) | DONE: `DmSession` (cap 4), `DmRelayPeer` + lobby/relay service, `DmData` registry; suites green |
| 2 Vertical slice | DONE, superseded by the full rebuild (`DmNextGame`, `next/`) |
| 3 Port systems | DONE: enemy scenes, combat and rites over RPC, statuses, thralls, loot and progression; non-necromancer disciplines are not built (PARITY gap 10) |
| 4 Backend integration | DONE solo, online (verified against the live backend, `tests/online_live`, opt-in) and offline (D4); session open/report/end, kill-ledger fallback, server-rolled loot |
| 5 Content migration | DONE: all 12 areas, seven bosses, the Depths, gathering/professions, meta layer. Web retirement (D9) NOT done: the web game is frozen (2026-10-04), not removed |
| Lobby (D11) | DEPLOYED: systemd `deathmuffin-lobby` on :5192, staff-gated; private codes + public list of open sessions; Party window on the rebuild (`next/party/README.md`) |
| 6 Quality pass | DONE on the live client (`godot-port`: presets Low/Medium/High/Ultra, lighting pass + Brightness, UI scaling) and SYNCED into the rebuild 2026-10-08 (`DmNextPerf` applies preset, lift, Brightness, Interface size; `DmWorldBuilder` is shared). Forward+ evaluation still needs real PCs (owner's and Helix's); no GPU-measured frame budget of the rebuilt scene exists |
| 7 Hardening | OPEN: disconnects (D13: rejoin window, not built), desync checks, cheating review |
| Default client | `DmMain.USE_NEXT := true` since 2026-10-09 (f10c2d1f): the rebuild is the default, `-- --old` forces `DmGame`. Characters of the 5 non-necromancer disciplines still enter `DmGame` until their kits are built on the rebuild (`DmMain.next_supports`) |
| Branches | `godot-port` was unified into `godot-next` 2026-10-09 (merge 7752a55b + df7a4113); `godot-next` is the single line, `godot-port` only fast-forwards to it. The launcher client is published from `godot-next` |
| Online unlock (D10) | LIVE since 2026-10-07: client gate (`front/dm_online_gate.gd`, one implementation in both clients) + launcher 0.6.1 + manifest `online.staff` |
