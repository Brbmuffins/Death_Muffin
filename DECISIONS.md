# Decisions

Owner decisions that shape the code. D1-D13 are the 2026-10-05 and 2026-10-07 rebuild decisions; B1-B10 the 2026-10-09 (B11: 2026-10-10)
baseline decisions; B12 the 2026-10-10 Phase B rollback. Where a later decision overrode one, the entry says so.

## Rebuild decisions

**D1. Trust model (default).** The host's Godot game is authoritative for its session: combat, enemies, corpses, thralls,
waves, bosses. Clients send intents (move, cast, interact) as RPCs to the host. The backend stays authoritative for anything
that persists or has value: accounts, characters, inventory, gold and shards, loot rolls (server-rolled), progression saves,
and the kill ledger with its sanity caps. A cheating host can ruin its own session but cannot mint items or gold beyond what
the backend's caps accept.

**D2. Party size: 4 players** (owner, 2026-10-05). One constant, `DmSession.MAX_PLAYERS := 4`.

**D3. Connectivity (default).** Listen-server host, connected through a relay on the VPS: the lobby service lists and creates
sessions and forwards opaque packets between host and clients over WebSocket, so no port forwarding is needed. Client side is
`DmRelayPeer`, a `MultiplayerPeerExtension`, so session code is plain Godot high-level multiplayer; `ENetMultiplayerPeer` is
used for LAN and tests.

**D4. No offline edition (reversed by B1).** The local GDScript backend (`DmMockBackend`, `net/offline/`) is the dev/test
backend behind `-- --dev-offline` only.

**D5. Solo first, online in the back seat** (owner, 2026-10-05). The game is built on the session structure so online works,
and solo play is polished first. Still the working order: necromancer combat, loot and first hour before more party features.

**D6. Host quits = session ends** for everyone; each member keeps what the backend already credited. No host migration.
Hosting on the VPS (headless Godot) is a future option, not planned.

**D7. Branches.** The Godot line ships from `main`, the only branch. Old work is in `archive/*` tags; the web game is `archive/legacy-web`.

**D8. Characters.** Existing online characters carry into the Godot game unchanged (same backend). Offline characters are not carried over (B1).

**D9. Web retirement.** The three.js game is retired; its code lives in git history and tag `archive/legacy-web` only (see B2).

**D10. Online gate.** Online was staff-first, then opened to everyone (B5). The gate code (`front/dm_online_gate.gd`, the
manifest's `online` block, `set-online.sh`) stays as the emergency off switch.

**D11. Lobby = private codes plus a public list of open sessions** (`deathmuffin-lobby`, :5192; it follows the manifest gate).

**D12. Party-session tables (migration 041)** are part of the backend schema.

**D13. Disconnects get a rejoin window** (not built, see KNOWN-GAPS.md). D6 still holds for the host.

## Rules the owner set during the rebuild

- **Performance first** (2026-10-05, 2026-10-02): anything added must perform; every change is measured before and after or
  it is not merged; event-driven over per-frame work; no per-frame allocations in hot paths; first-use work (shaders,
  effects, fonts) is warmed during loading, never mid-play; tests never assert wall-clock time (see below).
- **Assets: reuse first** (2026-10-05): reuse the existing audio, models, animations and VFX (the Binbun effects, the `Vfx`
  autoload, spell colours). A different effect is fine if it saves real time and performs at least as well. Generate (Tripo
  models, ElevenLabs audio, Gemini concepts) only when something needed does not exist or is unusable.
- **Polish over new content; necromancer focus; immersive but capped, not overwhelming** (2026-10-02/03).
- **Loot never vacuums** (2026-10-04): loot does not fly to the player; walk over it or it expires (gold and shards pull in
  from a few steps).
- **No Godot-vs-web parity target** (2026-10-05): the rebuild is Godot-idiomatic; bit-exact web simulation math was dropped.

## Baseline decisions, 2026-10-09

- **B1. Online only for players.** The game starts online by default. Offline launch is a testing flag (`-- --dev-offline`) with
  its own save; the "offline:" token is wiped on an online start.
- **B2. One game.** The web game, offline and mobile web builds, Socket.IO realtime (:5191), the old `DmGame` path, WorldSim and
  co-op code are retired. The Godot line is `main`; tag `archive/legacy-web` keeps the web game.
- **B3. Necromancer-only baseline.** Four necromancer disciplines are playable (`DmCharacterBuild.is_playable`, backend
  `MAX_DISCIPLINE_INDEX` 4). The other five are greyed out as "Coming later" and rebuilt later. Online characters of a
  non-necro discipline switch to a necro discipline.
- **B4. One launcher button.** Launcher 0.7.0: a single online Play/Update button; the site's play page is replaced by the
  launcher download page.
- **B5. Online open to everyone** (`set-online.sh on`); the staff gate is off.
- **B6. Repository.** No fresh repo: `Brbmuffins/Death_Muffin` is cleaned in place, because installed launchers self-update from
  its releases. Default branch `main`; old branches became `archive/*` tags.
- **B7. Rule sources live in `server/rules/`** (moved out of `src/`); `tools/build-server-rules.mjs` compiles them to the
  `.cjs` files the backend loads. Nothing live depends on a client source tree.
- **B8. Test fixtures are committed** (trimmed golden fixtures under `godot/tests/*/fixtures/`), so the suites run without the
  deleted TypeScript game.
- **B9. `deploy-release.sh` is backend plus release notes only.** The client goes out with `publish-godot-client.sh`.
- **B10. Docs: a small truthful set.** README, ROADMAP, DECISIONS, KNOWN-GAPS, CLAUDE, plus short per-system READMEs. Web-era
  docs are deleted, not bannered; they stay in git history and in tag `archive/legacy-web`.
- **B11. Tests never assert wall-clock time** (owner, 2026-10-10): timings print as `INFO perf:` lines only; FPS is judged on real hardware (F3 overlay). Deterministic counters (cold loads, node, draw-call and query counts) stay real checks.
- **B12. Performance Phase B is pulled from `main`** (owner, 2026-10-10). In combat it crashed real players' GPUs to the desktop (NVIDIA and AMD, Compatibility renderer, no trace in the log); the build before it was confirmed stable. The ground-loot icons and a bad import were ruled out. The work (shared creature materials with instance uniforms, GPU-simulated motes, prop MultiMesh, prop lights capped at 8, opt-in Mobile renderer, GPU-time resolution governor, threading options) is kept in tag `archive/perf-phase-b`. It comes back one part at a time in owner-approved test builds; creature instance uniforms are the first suspect.
