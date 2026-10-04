class_name DmSimBossWorld
extends "res://sim/bosses/boss_world.gd"
## Adapts the real world sim (DmWorldSim, see godot/sim/BOSS_HOOK.md) to the boss-world view. Only the sim's documented members are
## used: time, difficulty, vowFx, players, enemies, thralls, corpses, zones, cover, rand(), emit(), spawn_enemy(), area_level(),
## remove_corpse(), kill_thrall(), add_hostile_pool(), ember_pool(). Entities are converted to the small Dictionaries the brains read.

var sim  # DmWorldSim


func _init(p_sim) -> void:
	sim = p_sim


func now() -> float:
	return float(sim.time)


func difficulty() -> String:
	return String(sim.difficulty)


func echoes() -> int:
	return int(sim.vowFx.get("echoes", 0))


func rand() -> float:
	return sim.rand()


func area_level(area: String) -> int:
	return int(sim.area_level(area))


func emit(ev: Dictionary) -> void:
	sim.emit(ev)


func players() -> Array:
	var out: Array = []
	for p in sim.players.values():
		out.append({"id": p.id, "x": p.x, "z": p.z, "alive": p.alive, "area": p.area})
	return out


func player_count() -> int:
	return sim.players.size()


func cover() -> Array:
	return sim.cover


func spawn_enemy(def: String, area: String, x: float, z: float, elite: bool, rising: bool = true) -> int:
	return int(sim.spawn_enemy(def, area, x, z, elite, rising).id)


func _enemy_dict(e) -> Dictionary:
	return {"id": e.id, "def": e.def, "area": e.area, "x": e.x, "z": e.z, "hp": e.hp, "max_hp": e.maxHp, "state": e.state}


func enemy_get(id: int) -> Dictionary:
	var e = sim.enemies.get(id)
	return {} if e == null else _enemy_dict(e)


func enemies() -> Array:
	var out: Array = []
	for e in sim.enemies.values():
		out.append(_enemy_dict(e))
	return out


func set_enemy_hp(id: int, hp: float, max_hp: float) -> void:
	var e = sim.enemies.get(id)
	if e != null:
		e.maxHp = max_hp
		e.hp = hp


func remove_enemy(id: int) -> void:
	sim.enemies.erase(id)


func thralls() -> Array:
	var out: Array = []
	for t in sim.thralls.values():
		out.append({"id": t.id, "x": t.x, "z": t.z})
	return out


func damage_thrall(id: int, amount: float) -> void:
	var t = sim.thralls.get(id)
	if t == null:
		return
	t.hp -= amount
	t.flash = 1.0
	if t.hp <= 0.0:
		sim.kill_thrall(t, "killed")


func corpses() -> Array:
	var out: Array = []
	for c in sim.corpses.values():
		out.append({"id": c.id, "area": c.area, "x": c.x, "z": c.z})
	return out


func remove_corpse(id: int, reason: String) -> void:
	var c = sim.corpses.get(id)
	if c != null:
		sim.remove_corpse(c, reason)


func hostile_toxic_zones() -> Array:
	var out: Array = []
	for z in sim.zones.values():
		if z.hostile and z.kind == "toxic":
			out.append({"x": z.x, "z": z.z, "r": z.r})
	return out


func add_hostile_pool(x: float, z: float, r: float, dps: float, seconds: float) -> void:
	sim.add_hostile_pool(x, z, r, dps, seconds)


func ember_pool(x: float, z: float, r: float, seconds: float, dps: float) -> void:
	sim.ember_pool(x, z, r, seconds, dps)
