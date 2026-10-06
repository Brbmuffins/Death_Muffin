class_name DmBossNodeWorld
extends DmBossWorld
## The world a DmBossBrain sees, answered from the live nodes of the slice (REBUILD D1: host only). One per DmBoss. Entities are plain
## Dictionaries as the brain expects; the player dictionaries are reused between ticks (`refresh()` once per tick, no per-tick allocation
## except for the brain's own events). Brain events go to `DmBossHost.on_brain_event`.

var host: DmBossHost
var boss: DmBoss
var t: float = 0.0                   ## room clock: the boss advances it by its own physics delta
var _players: Array = []
var _by_peer: Dictionary = {}        ## peer id -> reused player dict
var _levels: Array = []


func _init(host_: DmBossHost, boss_: DmBoss) -> void:
	host = host_
	boss = boss_


## Rebuild the cached player list from the session's bodies (call once per tick, before the brain runs).
func refresh() -> void:
	_players.clear()
	_levels.clear()
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
		_levels.append(float(hb.character.get("level", 1)))


func now() -> float:
	return t


func difficulty() -> String:
	return host.difficulty


func rand() -> float:
	return host.rng.randf()


func area_level(area: String) -> int:
	return int(DmEnemyStats.area_level(area, _levels, 0.0))


func emit(ev: Dictionary) -> void:
	host.on_brain_event(ev, boss)


func players() -> Array:
	return _players


func player_count() -> int:
	return _players.size()


## Adds leave with the boss (no kill credit / corpse): the director removes them.
func spawn_enemy(def: String, area: String, x: float, z: float, elite: bool, _rising: bool = true) -> int:
	var e: DmEnemy = host.game.director.spawn(def, Vector3(x, 0.0, z), host.heroes(), elite, {}, area)   # (spawn returns the enemy; brains track ids)
	return DmWaveDirector.id_of(e) if e != null else -1


func enemy_get(id: int) -> Dictionary:
	var e: DmEnemy = host.game.director.enemy_by_id(id)
	if e == null:
		return {}
	return {"id": id, "def": e.def_id, "area": host.area_at(e.global_position.x, e.global_position.z), "x": e.global_position.x, "z": e.global_position.z, "hp": e.hp, "max_hp": e.max_hp, "state": DmEnemyState.NAMES[e.sm.id()]}


func enemies() -> Array:
	var out: Array = []
	for id in host.game.director.enemies:
		out.append(enemy_get(int(id)))
	return out


func set_enemy_hp(id: int, hp: float, max_hp: float) -> void:
	var e: DmEnemy = host.game.director.enemy_by_id(id)
	if e != null:
		e.hp = hp
		e.max_hp = max_hp


func remove_enemy(id: int) -> void:
	var e: DmEnemy = host.game.director.enemy_by_id(id)
	if e != null:
		e.queue_free()


func thralls() -> Array:
	var out: Array = []
	for b in host.game.session.get_bodies():
		var th := b.get_node_or_null("Thralls") as DmThrallHost
		if th == null:
			continue
		for t_ in th.list():
			if t_.state != DmThrall.S.DEAD:
				out.append({"id": t_.get_instance_id(), "x": t_.global_position.x, "z": t_.global_position.z})
	return out


func damage_thrall(id: int, amount: float) -> void:
	var th := instance_from_id(id) as DmThrall
	if th != null and th.state != DmThrall.S.DEAD:
		th.take_damage(amount, boss)


# ---- hooks of the Abbess / Mire Mother (corpses), Congregation (cover), Prelate (echoes) and the Saint / Regent (pools). Each is its own function. -----

static var _cover: Array = []

## Corpses lying in the world (echoes excluded), as {id, area, x, z}. The Mire Mother's rite wants the Fen's.
func corpses() -> Array:
	var out: Array = []
	var cf: DmCorpseField = host.game.corpses
	if cf == null:
		return out
	for c: DmSimCorpse in cf.corpses.values():
		if c.echoOwner == "":
			out.append({"id": c.id, "area": c.area, "x": c.x, "z": c.z})
	return out


## `reason`: "devoured" | "raised" (the view's wisp / fade for it). Host only.
func remove_corpse(id: int, reason: String) -> void:
	host.game.corpses.consume(id, 0, reason)


## The Congregation's pews: the same boxes the sim world uses (sim/world.json `cover`), decoded once.
func cover() -> Array:
	if _cover.is_empty():
		for b in DmDb.sim_world()["cover"]:
			_cover.append({"x0": float(b["x0"]), "z0": float(b["z0"]), "x1": float(b["x1"]), "z1": float(b["z1"])})
	return _cover


## The Prelate's Echoes (vow `prelate_echo`, 0-3) of whoever rang the bell: the summoner's own progression.
func echoes() -> int:
	var m := host.member_of(boss.summoner)
	return int(m.prog.vow_fx().get("echoes", 0)) if m != null else 0


# ---- hooks of the Saint / Regent / Mire Mother: rot pools, ember pools ---------------------------------------------------

## Rot the Saint stands in: every live damaging toxic pool (hers, a sac's, a doctor's flask).
func hostile_toxic_zones() -> Array:
	return host.toxic_zones()


## The Saint's Rot Rain pool: a toxic DmHostileZone (dps already scaled by the brain), `seconds` long.
func add_hostile_pool(x: float, z: float, r: float, dps: float, seconds: float) -> void:
	host.spawn_pool(&"toxic", x, z, r, dps, seconds, boss)


## The Regent's coals / firebreak / ember pool.
func ember_pool(x: float, z: float, r: float, seconds: float, dps: float) -> void:
	host.spawn_pool(&"ember", x, z, r, dps, seconds, boss)
