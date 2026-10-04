# godot/sim: the headless world simulation

A bit-exact GDScript port of `src/gameplay/sim/WorldSim.ts` (+ `types.ts`, `snapshot.ts`, `nav.ts`, `depthsFloor.ts`) and of the world-dependent half of
`AbilitySystem.ts` / `NewBloodSystem.ts`. No nodes, no rendering: plain classes over floats on the XZ plane. The web game is the spec; every number comes from
`godot/data/content/*.json`. Bosses plug in through `BOSS_HOOK.md`.

Verified against the real TS (all at tolerance 0, i.e. identical doubles): `godot --headless --path godot --script res://tests/sim/run.gd` (after
`tools/godot/gen-fixtures.sh`; add `-- tol=0 rel=0` for the strict mode, `-- only=<fixture>` for one file).

## Driving it from world/

```gdscript
var nav := DmNav.new()
var w: Dictionary = DmSimExact.load_json("res://data/sim/world.json")        # always load sim data through DmSimExact (see below)
for o in w["obstacles"]:     nav.add_obstacle(DmNavObstacle.from_dict(o))
for s in w["sightBlockers"]: nav.add_sight_blocker(DmNavObstacle.from_dict(s))
nav.set_unlocked(open_areas)                                                  # call again whenever a seal opens (Array of area ids)
var sim := DmWorldSim.new(nav, DmRng.new(seed))                               # same seed + same inputs = same world
sim.set_crypts(w["crypts"]); sim.set_cover(w["cover"]); sim.set_nodes(w["nodes"])
sim.waveTier = 0.0; sim.difficulty = "medium"; sim.omen = null; sim.vows = {}   # world dials
```
Per frame (the TS host steps whatever dt the frame has; fixtures use 0.05):
1. `sim.set_player(DmSimPlayer.make(id, x, z, area, alive, level, family))` for every player body (players are simulated by their own client).
2. Caster inputs: `caster.cast(ability_id, {"x":, "z":, "enemyId"?, "boss"?}, now_ms)`; or raw intents: `sim.apply({"t": "hit"|"miasma"|"exhume"|"litany"|"detonate"|"signature"|"summonBoss"|"recallThralls"|"refreshThralls"|"legend"|"gather", ...})` (keys exactly the TS `Intent`).
3. `var events := sim.step(dt)` then `caster.handle_event(ev)` for each event, and route the rest (`hurt` -> `DmPlayerRules.take_damage`, `death` -> loot/XP, `wave`/`telegraph`/`zone`/... -> VFX). Events are the TS dictionaries (`t`, ...); `corpse`/`zone` events carry the `DmSimCorpse`/`DmSimZone` object (`DmSimSnapshot.wire_event(ev)` flattens them for the relay).
4. `caster.update(now_ms, dt)` every frame (projectiles, timed rites, wisps, dashes, mantle shards).
5. Read state straight from `sim.enemies` (id -> `DmSimEnemy`), `sim.thralls`, `sim.corpses`, `sim.zones`, `sim.walls`, `sim.boss.state`, `sim.surge`, `sim.depths`; or `DmSimSnapshot.make(sim, full)` for the relay form. Entity fields use the TS names (`maxHp`, `stateT`, ...).

Caster: `DmSimCaster.new(sim, p, self_id, discipline_id, family, mods)`; `p` = `DmPlayerRules.new_state(stats, family)` plus `p["loadout"]` (DmWeaponLine.resolve), `p["runes"]` {rite: rune}, `p["area"]`, and the hero's `p["x"]`, `p["z"]` kept current by the scene. Optional: `tip_fn` (staff tip `[x, y, z]`), `dash_fn`, `aim`, `send_fn` (co-op guest: relay instead of `sim.apply`), `random` (default `randf`). Drain `caster.popups` (damage numbers) and `caster.notes` each frame.

Other APIs: `sim.start_depths(owner, seed, depth, hold)` / `descend_depths()` / `end_depths()` (returns the floor Dictionary), `sim.start_surge(area)`, `sim.clear_area(area)`, `sim.mark_visited(area)`, `sim.retag_player(old, new)`, `sim.remove_player(id)`, `sim.depleted_nodes()`. Multiplayer: `DmSimMirror` (WorldMirror: `apply_snapshot`, `apply_events`, `update(dt)`, `seed(new_sim)` for host migration). Navigation for the hero: `nav.find_path`, `nav.resolve`, `nav.area_at`, `nav.depths_hop`.

## Files
`world_sim.gd` (state, intents, damage, thralls/corpses, step) | `sim_enemy_ai.gd` | `sim_thrall_ai.gd` | `sim_signatures.gd` (signature + New Blood rites on the host) | `sim_director.gd` (waves, surges, Depths run, nodes) |
`sim_zones.gd` | `sim_caster.gd` | `sim_snapshot.gd`, `sim_mirror.gd` | `nav.gd`, `depths_floor.gd` | `fdlibm.gd`, `sim_math.gd`, `sim_exact.gd` | entity classes `sim_enemy/thrall/corpse/zone/player.gd`, `boss_state.gd`, `boss_controller.gd`, `boss_stub.gd`.
Data: `godot/data/sim/world.json` (`tools/godot/export-sim.ts`: nav colliders, crypts, nodes, pew cover).

## Why the odd numerics (read before "simplifying")
- **V8-exact trig and hypot.** `Math.hypot` differs from sqrt(a*a+b*b) in the last bit for 38% of inputs, and libm sin/cos/atan2 differ from V8's fdlibm for a few percent. The sim compares distances and picks nearest/equal targets (a Rend leaves thralls on a ring of equal distances), so one ulp flips ties and a replay drifts. `DmSimMath.hypot` and `DmFdlibm` reproduce V8 exactly (verified on 12k+12k random inputs per function).
- **Never use `Vector2` for sim data**: it is float32 in Godot. Points are `[x, z]` Arrays.
- **GDScript float literals and Godot's JSON parser are not correctly rounded** beyond 12 significant digits (13% of random 17-digit doubles are an ulp off). Long constants are built from their IEEE words (`DmFdlibm._w`), and sim data/fixtures store such doubles as `"d:<hex bits>"` strings that `DmSimExact.decode` restores. Load `godot/data/sim/*.json` with `DmSimExact.load_json`, never `JSON.parse_string` directly.
- **JS Map iteration semantics**: `update_enemies` visits enemies spawned during the loop (a Deacon raising a Risen) like a JS Map does; other loops iterate copies, as the TS does.

## Divergences from the TS
- Bosses: `DmBossStub` (shared machinery, no attacks) until the bosses track's factory exists; fixtures compare the stub against a TS `BossBrain` subclass with the same behaviour.
- `DmSimCaster.handle_event` does not route `vigil`: the web scene never calls `AbilitySystem.onVigil`, so Corpse Vigil's regeneration never starts there (web bug, ported as is; `route_vigil = true` wires it).
- Visual-only code (effects, audio, Binbun, avatar gestures) is dropped; `Math.random` in the caster is the injectable `random` Callable. Player defence (`hurt` events, Bone Ward reflect/shatter triggers) stays in `DmPlayerRules` + the scene; the caster exposes `reflect_ward` / `litany_shatter`.
