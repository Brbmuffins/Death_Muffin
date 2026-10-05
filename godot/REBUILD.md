# Godot rebuild: decisions and plan

Owner direction, 2026-10-05: Godot **replaces** the three.js client (not a parity port any more), the server side and relay can change as
needed, and Godot-idiomatic rebuilds are welcome where they pay off. This file supersedes the "reproduce the web exactly" rule in
`PORTING.md` for the systems listed below; everything not listed here keeps the PORTING.md conventions.

## Decisions (D1-D4; D2 + D4 confirmed by the owner 2026-10-05, D1/D3 defaults)

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
2. **Vertical slice**: Chapterhouse + Hollow Graves as a hosted session: move, cast 2 rites, one enemy kind as a scene with a state machine
   and navigation, kills reported to the backend, server-rolled loot picked up by the right player.
3. **Port systems** onto the foundation: enemy scenes (one kind at a time), combat and rites over RPC, loot and progression.
4. **Backend integration**: cloud characters online, server-rolled loot, session-end report; solo as a 1-player session (online via the
   VPS backend, offline via the local backend, D4).
5. **Content migration**: remaining areas, bosses, the Depths. Retire the web build and its TS exporters.
6. **Hardening**: disconnects, host migration (or clean session end), desync checks, cheating review.

## Status

| Phase | State |
|---|---|
| 0 Decisions | D2 + D4 confirmed by owner 2026-10-05; D1/D3 defaults |
| 1 Foundation | wave 1 started 2026-10-05 (session, relay, data) |
