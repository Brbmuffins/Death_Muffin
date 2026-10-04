# Death Muffin realtime co-op protocol (Socket.IO)

Source of truth: `server/realtime/server.js` (service, port 5191 in production) and `src/net/realtime.ts`, `src/net/contracts.ts`,
`src/net/reconnect.ts`, `src/net/perfBeacon.ts`. The Godot client (`dm_realtime_client.gd`) is an interface stub for now; solo play never
depends on it (the service being down just means "playing solo").

## Transport
- Socket.IO v4 (Engine.IO v4). Production URL `https://muffindevelopment.com`, path `/death-muffin/rt/socket.io` (nginx -> `127.0.0.1:5191`,
  WebSocket upgrade, 3600 s read timeout). Local dev: `http://127.0.0.1:5000`, default path `/socket.io`.
- Reconnection is OFF in the client; the game runs its own policy (below). `perMessageDeflate` is on (threshold 1 KiB), `maxHttpBufferSize` 256 KiB.
- For a native client: raw WebSocket `wss://host/death-muffin/rt/socket.io/?EIO=4&transport=websocket`; packets are text frames: `0{...}` open,
  `2`/`3` ping/pong (answer the server's `2` with `3`), `40{"token":"<jwt>"}` = Socket.IO CONNECT with the auth payload (reply `40{"sid":...}`,
  or `44{"message":...}` = connect_error), `42["event",payload]` event, `42<id>["event",payload]` event expecting an ack, `43<id>[ack]` ack.

## Handshake / auth
`auth: { token }` where token is the JWT from `POST /login` (same token the REST API uses). Rejection = `connect_error` with a player-readable
message: `Not authenticated`, or `Not authenticated: this account was opened somewhere else` (a newer login exists).
One active session per account: when a newer login's socket connects, older sockets of that account receive `session:replaced`
`{ message }` and are disconnected. The client treats it like the REST 409 `session_replaced` (stop saving, offer "Play here").
The JWT's `sid` claim starts with its mint time in ms; the relay compares those, no database involved.

## Worlds
Instanced, at most 10 players (`MAX_PARTY_SIZE`). No `instance` code = a private SOLO world of your own (`s:` prefix); a code
(`[a-z0-9-]`, first 12 chars, lower-cased) joins/creates that party world (`w:` prefix). `match: true` = public matchmaking pool
(no shipped client sends it). The oldest member is the **host**: it simulates enemies and is the only socket allowed to publish snapshots
and events. When the host leaves the next-oldest is promoted (`room:host`). One socket per account per world.

## Client -> server events
| Event | Payload | Notes |
|---|---|---|
| `world:join` (ack) | `JoinRequest` `{instance?, characterId, classIndex, level?, x, z, facing, gear?, match?}` | ack `{success:true,data:JoinResult}` or `{success:false,error}`. Errors: `Already in a world`, `That world is full (10 players)`, `You are already in this world`. classIndex clamped 0-9, level 1-999. Client waits 8 s for the ack, then gives up as unreachable. |
| `player:move` (volatile) | `{x, z, facing, moving, hpFrac, level?}` | max 256 B, 30/s. |x|,|z| <= 400, else dropped. hpFrac clamped 0-1. |
| `player:gear` | `{head,chest,legs,feet,hands,main_hand,off_hand,cape,pet: item_id}` | ids `^[a-z0-9_]{1,48}$`, 512 B, 2/s. |
| `world:intent` | `Intent` (below) | any member; validated + clamped, stamped `by = socket.id`, delivered to the HOST only. 2 KiB, 40/s. |
| `world:snapshot` (volatile) | `WorldSnapshot` | HOST only. 96 KiB, 15/s. Relayed to others, trimmed per recipient to a 64 m interest radius (own thralls always kept). |
| `world:events` | `SimEvent[]` | HOST only. <= 400 events, 64 KiB, 60/s. Relayed to others (not echoed). |
| `chat:send` | `string` | trimmed, 240 chars, 3/s. |
| `perf:report` (volatile) | perf beacon object (see perfBeacon.ts) | one per >= 5 s, 2 KiB; server logs it. Optional. |

## Server -> client events
| Event | Payload |
|---|---|
| `player:join` | `RemotePlayer` `{id, characterId, name, classIndex, level, x, z, facing, moving, hpFrac, gear}` (id = socket id) |
| `player:leave` | `{id}` |
| `player:move` (volatile) | `{id, x, z, facing, moving, hpFrac, level}` |
| `player:gear` | `{id, gear}` |
| `chat:message` | `{id, name, text}` (also echoed to the sender) |
| `world:intent` | `{from, intent}` (host only) |
| `world:snapshot` (volatile) | `WorldSnapshot` |
| `world:events` | `SimEvent[]` |
| `room:host` | `{hostId, snapshot|null}` (new host takes over from this snapshot) |
| `session:replaced` | `{message}` |
| `disconnect` | built-in |

## JoinResult
`{ self: RemotePlayer, players: RemotePlayer[], hostId, instance, solo?, snapshot: WorldSnapshot|null }`

## WorldSnapshot
`{ t, waveTier, difficulty?, ascension?, vows?, enemies: EnemyRow[], thralls: ThrallRow[], corpses?, zones?, zpos?, boss, depleted? }`
- `EnemyRow` = `[id, def, x, z, facing, hp, maxHp, stateIdx, flags, stateT, speed, scale, area, affix?]` (affix = AFFIX_ORDER index + 1, 0 = none; 13-field rows from older hosts still parse)
- `ThrallRow` = `[id, owner, kind, x, z, facing, hp, maxHp, stateIdx, stateT, empowered, speed, damage?, attackInterval?]`
- `corpses`/`zones` ride along every Nth snapshot (resync); `zpos` = `[zoneId, x, z][]` for drifting Creeping Rot circles; `depleted` = `[nodeId, secondsUntilBack][]`.
- A new snapshot without `corpses` is merged server-side onto the last full one (kept for host migration / late joiners).

## Intents (`world:intent`, field `t`)
Allowed `t`: `hit`, `miasma`, `exhume`, `litany`, `summonBoss`, `recallThralls`, `detonate`, `signature`, `gather`, `legend`, `refreshThralls`.
Anything else is dropped. Point intents (`recallThralls`, `miasma`, `litany`, `exhume`) require numeric `x`,`z` (|v| <= 400). Server clamps (the host clamps again):
- `hit` `{ids: int[] (<= 72), dmg (0..100000), fracture (0..3), boss, bleed (<= dmg/4), chill, withered (0..1), witheredCap (1..12), root, slow, rootS (<= 1.5), spear}`
- `miasma` `{x,z, r 0.5..8, dps 0..20000, durationMs 500..10000, witheredCap 1..10, bloom, creep 0..1.5, contagion}`
- `exhume` `{x,z, colossus, kind (warrior|shieldbearer|hound|wraith|archer|bonemage|plaguebearer|colossus, else warrior), r, count 1..3, cap 1..8, hp, damage, attackSpeedMult 0.2..3}`
- `litany` `{x,z, r (<= 11, or <= 22 with delayMs>0), delayMs 0..2000, spellPower, leaveCorpses, spare}`
- `summonBoss` `{boss: prelate|gravedigger|abbess|congregation|saint|regent|mire (default prelate), empowered?}`
- `signature` `{sig (one of the discipline rites list in server.js SIGNATURES), x,z, dx,dz (+-1000), sp, cap 1..12, dur 0..10}`
- `gather` `{nodeId ^[a-z]{1,16}_\d{1,4}$, successes 1..3}` (depletes a node on the host; rewards come from REST `/api/gather`, never from here)
- `detonate` `{corpseId: int >= 0, dmg}`; `legend` `{mods:{thrallDeathBurst, championEvery, spearRally, miasmaSpreadsWithered, witheredBurstAt}}`;
  `recallThralls` `{x,z}`; `refreshThralls` `{hpMult, damageMult, speedMult}` (each 1..1.25).

## SimEvent
The host's event vocabulary (`spawn`, `death`, `corpse`, `thrall`, `telegraph`, `hurt`, `zone`, `wall`, `rend`, ... ) is defined by `SimEvent` in
`src/gameplay/sim/types.ts`; the server only checks it is an array within the size limits and relays it. The Godot sim port decides the shapes.

## Reconnection policy (client side, src/net/reconnect.ts; ported in dm_realtime_client.gd)
- After a dropped link: retry after 1, 2, 4, 8 s, then every 15 s while the scene is mounted (`rejoin_delay_ms`).
- First connect found the service down: look again after 10, 20, then every 30 s (`first_connect_delay_ms`).
- Retryable: unreachable / timeout / xhr poll error / websocket error / transport / network / ECONNREFUSED / failed to fetch; when rejoining also "already in this world".
  Final: "not configured", "not authenticated", and join rejections written for the player ("That world is full").
- Rejoin state is remembered locally (rejoinStore.ts: instance code) so a reload returns to the same party.
