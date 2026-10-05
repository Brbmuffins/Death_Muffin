# godot/next/corpses: the necromancer's corpse resource

`DmCorpseField` (`dm_corpse_field.gd`) is a Node named `Corpses`, a child of the session/world root with the same NodePath on every peer
(RPCs resolve by path). Host is authoritative (REBUILD D1); every peer, host and solo included, holds the replicated record in
`corpses: Dictionary` (id -> `DmSimCorpse`, the sim's record: `id x z kind enemy elite facing scale area bornAt expiresAt ruptureAt echoOwner`)
and draws the view from it. Add it before peers join; the host connects `peer_connected` and sends a snapshot to late joiners.

## Host API (all return false/null on a client)

| call | |
|---|---|
| `track(enemy: DmEnemy, area := "")` | on `died` lay a corpse of `enemy.corpse_kind` (none: bat, risen, rat, wraith... -> nothing), at its position, with its def / elite / scale / facing. `deathCorpses` (golem 3, drowned_sexton 2) adds "risen" corpses on a 1.6 m ring; `echo_enabled` adds the Veil echo |
| `add_corpse(x, z, kind, enemy, elite, facing, scale, area, body := null)` | any other source (sacrificed thrall, Black Litany `leaveCorpses`). `kind "none"` -> null |
| `corpses_in_radius(pos, r, filter := Callable(), area := "", include_echo := false) -> Array[DmSimCorpse]` | nearest first, ties by id. Echoes are hidden unless asked. `filter(c) -> bool` |
| `pick_corpse(aim, pick_r, max_range, from_pos, area := "")` | sim `pick_corpse`: nearest to `aim` within `pick_r` AND within `max_range` of `from_pos`; else the nearest to `from_pos` within 7 m; else null. Exhume uses `DmSimData.ABILITIES.exhume` radius/range |
| `consume(id, by_peer, reason := "consumed") -> bool` | atomic: the first caller gets true, everyone after gets false (the corpse is erased in the same call). Reasons drive the wisps: `consumed` (exhume, grave_offering, bone_mantle, thralls), `litany`, `raised`, `devoured`, `burst` (corpse_explosion: body shatters) |
| `get_corpse(id)`, `count()` | |
| knobs | `life_mult` (lingering_dead 1.5, thin_graves 0.75), `echo_enabled`, `area_level: Callable(area) -> int` (toxic pool damage), `resolve_pos: Callable(area, x, z) -> Vector2`, `auto_step`, `visuals`, `vfx` / `audio` (default `/root/Vfx`) |

Thralls track: raising a thrall = `pick_corpse(...)` then `if field.consume(c.id, peer, "consumed"): spawn_thrall(c.kind, c.enemy, c.elite...)`; read `c`
before consuming (the record stays valid after). Mass Grave: `corpses_in_radius(...)` then consume each, skipping the `false` ones. Colossus likewise.

Signals: `corpse_added(c)` (every peer), `corpse_consumed(c, by_peer, reason)` (host, before gone), `corpse_gone(c, reason)` (every peer; reasons
above plus `expired`, `burst` = rupture), `ruptured(c, zone)` (host).

## Numbers (from the sim, asserted in the tests)

Lifetime `DmSimConsts.CORPSE_LIFETIME` 26 s x `life_mult`; cap `MAX_CORPSES` 45 (the oldest is evicted as `expired`, echoes count); echo 20 s, scale 0.65,
offset 0.45, `echoOwner "*"`; toxic ruptures at `TOXIC_RUPTURE` 5 s into a `DmHostileZone` (kind `toxic`, r 2.4 x scale, 5 s, pulse every 0.4 s for
6 x `damage_scale(level)`; `DmHostileZone.tick_s` was added for the 0.4 s pulse, default unchanged).

## Replication and visuals

Events by reliable RPC from the host: `_rpc_add` (compact array), `_rpc_gone(id, reason)`, `_rpc_snapshot` (late join). Clients are visual-only and
cannot consume. The view: the dying `DmEnemy` body (same def within 1.2 m, state DEAD; the host passes it directly) becomes the corpse, shadow off;
no body -> a `DmCreature` laid down in its death pose. Effects are the existing ones through the Vfx decal pool (pale ring capped at 8, violet resonant
ring, green toxic aura, wisps per reason). Gone: 0.9 s opacity fade then the body is freed; `burst` (not toxic) blows the body apart (0.8 s).

## Performance design

Expiry is event-driven: `step(dt)` only compares the clock with `_next_due` (the earliest expiry/rupture) and scans only when that is reached.
Queries scan the <= 45 records linearly (cheaper than bucketing at that size; measured in the test). `_process` runs only while a body is fading.
Marks are pooled by the Vfx decal layers; decal textures are warmed in `_ready`.

## Not done / for other tracks

Carrion Seed (`seed*` fields exist but nothing arms/expires them), Plague Bloom/`bloomed`, corpse-eating enemy AI (`raised`/`devoured` just need `consume`),
`corpseGone` sounds (no new audio; hook `corpse_gone`), the `DmEnemy` ->field wiring in DmNextGame (call `track` for each spawned enemy). Test harness:
`godot/tests/corpses/run.gd`.
