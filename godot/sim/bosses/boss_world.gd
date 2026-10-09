class_name DmBossWorld
extends RefCounted
## The boss-world view: the ONLY thing a DmBossBrain knows about the world. Subclass it (the host is next/bosses/dm_boss_node_world.gd) and
## override every method. Entities are plain Dictionaries so a host is free to keep its own richer objects behind them.
## See godot/sim/bosses/README.md for the contract; defaults here only report the missing override.
##
## player dict:  { id: String, x, z: float, alive: bool, area: String }          (host order = the TS Map insertion order)
## enemy dict:   { id: int, def: String, area: String, x, z, hp, max_hp: float, state: String }
## thrall dict:  { id: int, x, z: float }
## corpse dict:  { id: int, area: String, x, z: float }
## cover box:    { x0, z0, x1, z1: float }
## zone dict:    { x, z, r: float }


func _missing(what: String) -> void:
	push_error("DmBossWorld.%s not implemented" % what)


## Seconds on the room clock (WorldSim.time). Pending attacks are due on this clock.
func now() -> float:
	_missing("now")
	return 0.0


## "easy" | "medium" | "hard" (WorldSim.difficulty)
func difficulty() -> String:
	_missing("difficulty")
	return "medium"


## vowFx.echoes (Prelate Echoes I-III), 0 if none.
func echoes() -> int:
	return 0


## The sim's seeded RNG: float in [0,1). Draw order matters (the brains call it in exactly the TS order).
func rand() -> float:
	_missing("rand")
	return 0.0


## WorldSim.areaLevel(area) (includes level scaling, vow levels).
func area_level(_area: String) -> int:
	_missing("area_level")
	return 1


## Push a SimEvent (Dictionary with the same keys as the TS: t, kind, x, z, phase, targets, r, ms, dir, boss, players, root ...).
func emit(_ev: Dictionary) -> void:
	_missing("emit")


## Every player in the world (any area, alive or not), in stable order.
func players() -> Array:
	_missing("players")
	return []


func player_count() -> int:
	return players().size()


## Drowned Congregation pews (WorldSim.cover).
func cover() -> Array:
	return []


## WorldSim.spawnEnemy(def, area, x, z, elite, rising): returns the new enemy's id.
func spawn_enemy(_def: String, _area: String, _x: float, _z: float, _elite: bool, _rising: bool = true) -> int:
	_missing("spawn_enemy")
	return -1


## {} when the id is unknown / already removed.
func enemy_get(_id: int) -> Dictionary:
	_missing("enemy_get")
	return {}


## All enemies in insertion order.
func enemies() -> Array:
	_missing("enemies")
	return []


func set_enemy_hp(_id: int, _hp: float, _max_hp: float) -> void:
	_missing("set_enemy_hp")


## Delete the enemy outright (adds / niches leave with the boss: no death event, no kill credit, no corpse).
func remove_enemy(_id: int) -> void:
	_missing("remove_enemy")


func thralls() -> Array:
	_missing("thralls")
	return []


## t.hp -= amount; t.flash = 1; if hp <= 0: killThrall(t, 'killed').
func damage_thrall(_id: int, _amount: float) -> void:
	_missing("damage_thrall")


func corpses() -> Array:
	_missing("corpses")
	return []


## reason: 'devoured' | 'raised'
func remove_corpse(_id: int, _reason: String) -> void:
	_missing("remove_corpse")


## Hostile zones of kind 'toxic' (the Saint's rot pools), live ones only.
func hostile_toxic_zones() -> Array:
	_missing("hostile_toxic_zones")
	return []


func add_hostile_pool(_x: float, _z: float, _r: float, _dps: float, _seconds: float) -> void:
	_missing("add_hostile_pool")


func ember_pool(_x: float, _z: float, _r: float, _seconds: float, _dps: float) -> void:
	_missing("ember_pool")
