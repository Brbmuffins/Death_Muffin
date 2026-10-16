class_name DmBossNodeWorld
extends DmBossWorld
## The world a DmBossBrain sees, answered from the live nodes of the slice (REBUILD D1: host only). One per DmBoss. Entities are plain
## Dictionaries as the brain expects; the player dictionaries are reused between ticks (`refresh()` once per tick, no per-tick allocation
## except for the brain's own events). Brain events go to `DmBossHost.on_brain_event`.
## Ported to the combat core (client/code.list "Ported"): the adds a boss spawns are core bodies (`spawn_enemy` is the director's spawn through the core, the area set), they
## leave with the boss through `DmCore.remove_enemy` (no death, no corpse, no credit), the thralls are the core's (`thrall_*`, a blow on one is `core.damage` with the boss as
## the source) and the corpses are the core's field. Pools (the Saint's rot, the Regent's coals) wait for those bosses: the core makes no zone for a boss yet.

var host: DmBossHost
var boss: DmBoss
var t: float = 0.0                   ## room clock: the boss advances it by its own physics delta
const WALK_SNAP_M := 2.5            ## a step more than this from the navmesh is not on it at all: leave the boss where the brain put it

var _players: Array = []
var _by_peer: Dictionary = {}        ## peer id -> reused player dict
var _heroes: Array = []   ## the session's hero bodies this tick (the level the arena scales to is worked out when a brain asks)


func _init(host_: DmBossHost, boss_: DmBoss) -> void:
	host = host_
	boss = boss_


## The game scene's combat core host (null in a harness without one).
func core() -> DmCoreHost:
	return host.game.get("core_host") as DmCoreHost if host.game != null else null


## Rebuild the cached player list from the session's bodies (call once per tick, before the brain runs).
func refresh() -> void:
	_players.clear()
	_heroes.clear()
	var g := host.game
	if g == null:
		return
	for b in g.session.get_bodies():
		var hb := b as DmHeroBody
		if hb == null:
			continue
		var d: Dictionary = _by_peer.get(hb.owner_peer, {})
		if d.is_empty():
			d["id"] = str(hb.owner_peer)
			_by_peer[hb.owner_peer] = d
		d["x"] = hb.position.x
		d["z"] = hb.position.z
		d["alive"] = hb.alive
		var a: String = g.area_of(hb.owner_peer)
		d["area"] = a if a != "" else host.assume_area
		_players.append(d)
		_heroes.append(hb)


func now() -> float:
	return t


func difficulty() -> String:
	return host.difficulty


func rand() -> float:
	return host.rng.randf()


func area_level(area: String) -> int:
	return int(DmEnemyStats.area_level(area, host.game.director.scaling_levels(_heroes), float(host.vow_fx.get("levels", 0.0))))


func party_hp_per_extra() -> float:
	return DmEnemyStats.BOSS_PARTY_HP_PER_EXTRA


## The arenas sit on the area navmeshes: a walking boss stays on walkable ground (a wall slides it) and can plan a route round an obstacle.
func nav_active() -> bool:
	return host.game != null and host.game.world != null and host.game.world.nav_ready()


## The step kept on walkable ground; a point far from any mesh (an arena the mesh does not cover) is left alone.
func walk(x: float, z: float) -> Vector2:
	var p := Vector3(x, 0.0, z)
	var c: Vector3 = host.game.world.nav_closest(p)
	var off := Vector2(c.x - x, c.z - z)
	return Vector2(c.x, c.z) if off.length_squared() > 0.0004 and off.length_squared() < WALK_SNAP_M * WALK_SNAP_M else Vector2(x, z)


func detour(x0: float, z0: float, x1: float, z1: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for pt in host.game.world.nav_path(Vector3(x0, 0.0, z0), Vector3(x1, 0.0, z1)):
		out.append(Vector2(pt.x, pt.z))
	return out


func emit(ev: Dictionary) -> void:
	host.on_brain_event(ev, boss)


func players() -> Array:
	return _players


func player_count() -> int:
	return _players.size()


## Adds leave with the boss (no kill credit / corpse): `remove_enemy` takes them out of the core. The director's spawn through the core: the body belongs to the boss's area.
func spawn_enemy(def: String, area: String, x: float, z: float, elite: bool, _rising: bool = true) -> int:
	var id: int = host.game.director.spawn(def, Vector3(x, 0.0, z), host.heroes(), elite, {}, {"area": area})
	return id if id > 0 else -1


## One body of the core's enemy table as the brains read it ({} when it is gone).
func enemy_get(id: int) -> Dictionary:
	var info: Dictionary = core().enemy_info(id)
	if info.is_empty():
		return {}
	var p: Vector2 = info["pos"]
	return {"id": id, "def": String(info["def"]), "area": host.area_at(p.x, p.y), "x": p.x, "z": p.y, "hp": float(info["hp"]), "max_hp": float(info["max_hp"]), "state": DmCoreEvents.STATE_NAMES[int(info["state"])]}


func enemies() -> Array:
	var out: Array = []
	for id in core().core.enemy_ids():
		out.append(enemy_get(int(id)))
	return out


## The core has no call that sets a body's health (only the Abbess's niches use it, with the niche kind the core does not run yet).
func set_enemy_hp(_id: int, _hp: float, _max_hp: float) -> void:
	push_warning("DmBossNodeWorld.set_enemy_hp: the core cannot set a body's health yet (the Abbess's niches come with the Abbess)")


func remove_enemy(id: int) -> void:
	core().remove_enemy(id)


## The living thralls of every legion: {id, x, z}, in raise order. A thrall that is falling is not one (DmThrall.S.DEAD).
func thralls() -> Array:
	var out: Array = []
	var c := core().core
	var ids: PackedInt32Array = c.thrall_ids()
	var pos: PackedFloat32Array = c.thrall_positions()
	var states: PackedInt32Array = c.thrall_states()
	for i in ids.size():
		if states[i] != DmCoreEvents.ThrallState.DEAD:
			out.append({"id": ids[i], "x": pos[i * 3], "z": pos[i * 3 + 1]})
	return out


## A blow of the boss on a thrall: the core's damage on its id (damage taken, barrier, the fall), the boss as the source.
func damage_thrall(id: int, amount: float) -> void:
	core().damage(id, amount, boss.core_id)


# ---- hooks of the Abbess / Mire Mother (corpses), Congregation (cover), Prelate (echoes) and the Saint / Regent (pools). Each is its own function. -----

static var _cover: Array = []

## Corpses lying in the world, as {id, area, x, z}. The Mire Mother's rite wants the Fen's. (The Veilwalker's echo corpses are not in the core.)
func corpses() -> Array:
	var out: Array = []
	var c := core().core
	for id in c.corpse_ids():
		var info: Dictionary = c.corpse_info(id)
		if not info.is_empty():
			out.append({"id": int(id), "area": String(info["area"]), "x": float(info["x"]), "z": float(info["z"])})
	return out


## `reason`: "devoured" | "raised" (the view's wisp / fade for it). Host only.
func remove_corpse(id: int, reason: String) -> void:
	core().corpses.consume(id, 0, reason)


## The Congregation's pews: the same boxes the sim world uses (sim/world.json `cover`), decoded once.
func cover() -> Array:
	if _cover.is_empty():
		for b in DmDb.sim_world()["cover"]:
			_cover.append({"x0": float(b["x0"]), "z0": float(b["z0"]), "x1": float(b["x1"]), "z1": float(b["z1"])})
	return _cover


## The Prelate's Echoes (vow `prelate_echo`, 0-3) of whoever rang the bell: the summoner's own progression.
## (No summoner member -> the world's sworn vows, DmNextMeta's vow_fx.)
func echoes() -> int:
	var m: DmRewardsMember = host.member_of(boss.summoner) if boss != null else null
	return int(m.prog.vow_fx().get("echoes", 0)) if m != null else int(host.vow_fx.get("echoes", 0))


# ---- hooks of the Saint / Regent / Mire Mother: rot pools, ember pools (the core makes no zone for a boss yet: they come with those bosses) -------------

func hostile_toxic_zones() -> Array:
	return []


func add_hostile_pool(_x: float, _z: float, _r: float, _dps: float, _seconds: float) -> void:
	push_warning("DmBossNodeWorld.add_hostile_pool: the core makes no zone for a boss yet (the Saint's rot comes with the Saint)")


func ember_pool(_x: float, _z: float, _r: float, _seconds: float, _dps: float) -> void:
	push_warning("DmBossNodeWorld.ember_pool: the core makes no zone for a boss yet (the Regent's coals come with the Regent)")
