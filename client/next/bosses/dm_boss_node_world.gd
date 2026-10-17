class_name DmBossNodeWorld
extends DmBossWorld
## The world a DmBossBrain sees, answered from the live nodes of the slice (REBUILD D1: host only). One per DmBoss. Entities are plain
## Dictionaries as the brain expects; the player dictionaries are reused between ticks (`refresh()` once per tick, no per-tick allocation
## except for the brain's own events). Brain events go to `DmBossHost.on_brain_event`.
## Ported to the combat core (client/code.list "Ported"): the adds a boss spawns are core bodies (`spawn_enemy` is the director's spawn through the core, the area set; a kind the
## core does not run yet is skipped, as a kind without a scene was), they leave with the boss through `DmCore.remove_enemy` (no death, no corpse, no credit), the thralls are the
## core's (`thrall_*`, a blow on one is `core.damage` with the boss as the source), the corpses are the core's field, a body's health is `DmCore.set_enemy_hp` (the Abbess's niches)
## and the pools (the Saint's rot, the Regent's coals) are core zones with the boss as their source (`DmCore.add_zone`, `DmCore.zones`).

var host: DmBossHost
var boss: DmBoss
var t: float = 0.0                   ## room clock: the boss advances it by its own physics delta
const WALK_SNAP_M := 2.5            ## a step more than this from the navmesh is not on it at all: leave the boss where the brain put it

var _rows: Array = []                ## enemies(): the brain's list of the core's bodies, reused
var _def_names := PackedStringArray()
var _zone_rows: Array = []           ## hostile_toxic_zones(): reused
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
## A kind the core does not run yet (the Cloister's, the Pyre's and the Fen's, until their items) is skipped as a kind without a scene was: -1, and the boss goes on without it.
func spawn_enemy(def: String, area: String, x: float, z: float, elite: bool, _rising: bool = true) -> int:
	if not DmWaveDirector.runs_on_core(def):
		return -1
	var id: int = host.game.director.spawn(def, Vector3(x, 0.0, z), host.heroes(), elite, {}, {"area": area})
	return id if id > 0 else -1


## One body of the core's enemy table as the brains read it ({} when it is gone).
func enemy_get(id: int) -> Dictionary:
	var info: Dictionary = core().enemy_info(id)
	if info.is_empty():
		return {}
	var p: Vector2 = info["pos"]
	return {"id": id, "def": String(info["def"]), "area": host.area_at(p.x, p.y), "x": p.x, "z": p.y, "hp": float(info["hp"]), "max_hp": float(info["max_hp"]), "state": DmCoreEvents.STATE_NAMES[int(info["state"])]}


## Every body of the core's table, in spawn order (the dead ones until they are removed): the Plague Saint reads it every tick to find her doctors. One call of the core gives seven numbers
## a body, and the dictionaries are reused from call to call (their fields are overwritten): a brain reads them at once and keeps nothing.
func enemies() -> Array:
	var f: PackedFloat32Array = core().core.enemy_rows()
	var n := f.size() / 7
	if _rows.size() > n:
		_rows.resize(n)
	while _rows.size() < n:
		_rows.append({"id": 0, "def": "", "area": "", "x": 0.0, "z": 0.0, "hp": 0.0, "max_hp": 0.0, "state": ""})
	for i in n:
		var d: Dictionary = _rows[i]
		var k := i * 7
		d["id"] = int(f[k])
		d["def"] = _def_name(int(f[k + 1]))
		d["x"] = f[k + 2]
		d["z"] = f[k + 3]
		d["area"] = host.area_at(f[k + 2], f[k + 3])
		d["hp"] = f[k + 4]
		d["max_hp"] = f[k + 5]
		d["state"] = DmCoreEvents.STATE_NAMES[int(f[k + 6])]
	return _rows


## The core's def number as its name, fetched once.
func _def_name(i: int) -> String:
	if _def_names.size() <= i:
		_def_names.resize(i + 1)
	if _def_names[i] == "":
		_def_names[i] = String(core().core.def_name(i))
	return _def_names[i]


## A boss gives a body its health: the Abbess's niche gets a share of her own maximum (the core also tells its guests the new maximum).
func set_enemy_hp(id: int, hp: float, max_hp: float) -> void:
	core().core.set_enemy_hp(id, hp, max_hp)


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


## The Prelate's Echoes (Prelate Echoes I-III) are a vow of Ascension, which the rebuild does not have (DECISIONS B36): the world's vows are the neutral ones (DmNextMeta's `vow_fx`, no
## `echoes`), so this is 0 whoever rang the bell. Today's reads the summoner's own saved vows; here a character who swore them on the account does not play them. The brain's Echoes code is
## today's and replays (client/tests/boss_prelate.gd), ready for the redesigned Ascension.
func echoes() -> int:
	return int(host.vow_fx.get("echoes", 0))


# ---- hooks of the Saint / Regent: rot pools, ember pools (core zones with the boss as their source) --------------------------------------------------

## Rot the Saint stands in: every live toxic pool of the core (hers, a sac's burst corpse, a flask), as {x, z, r}. The core lists them, three floats each; the dictionaries are reused.
func hostile_toxic_zones() -> Array:
	var f: PackedFloat32Array = core().core.zones("toxic")
	var n := f.size() / 3
	if _zone_rows.size() > n:
		_zone_rows.resize(n)
	while _zone_rows.size() < n:
		_zone_rows.append({"x": 0.0, "z": 0.0, "r": 0.0})
	for i in n:
		var d: Dictionary = _zone_rows[i]
		d["x"] = f[i * 3]
		d["z"] = f[i * 3 + 1]
		d["r"] = f[i * 3 + 2]
	return _zone_rows


## The Saint's Rot Rain pool: a toxic core zone (dps already scaled by the brain), `seconds` long, the boss its source.
func add_hostile_pool(x: float, z: float, r: float, dps: float, seconds: float) -> void:
	core().core.add_zone("toxic", Vector2(x, z), r, seconds, dps, boss.core_id)


## The Regent's coals / firebreak / ember pool: burning ground, a core zone.
func ember_pool(x: float, z: float, r: float, seconds: float, dps: float) -> void:
	core().core.add_zone("ember", Vector2(x, z), r, seconds, dps, boss.core_id)
