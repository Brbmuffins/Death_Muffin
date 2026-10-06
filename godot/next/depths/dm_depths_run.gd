class_name DmDepthsRun
extends RefCounted
## One descent, as pure state and rules (no nodes): the current game's sim run (DmSimDirector.start_depths / descend_depths / depths_kill /
## update_depths) without the sim. The floor of a depth is DmDepthsFloor.generate_floor(floor_seed(seed, depth)), the quota DmSimDepthsRules
## .floor_kills, the roster DmSimDepthsRules.depth_roster, the pacing the sim's (first wave 1.4 s, 8 on the first wave, then depth_wave_size,
## a gap of depth_wave_gap_s, never more than DEPTHS.cap alive, only as many as the quota still needs). `plan_wave` returns what to spawn;
## DmDepths turns the orders into DmEnemy scenes.

var seed: int = 0
var depth: int = 1
var need: float = 0.0
var kills: int = 0
var stair_open: bool = false
var floor_t: float = 0.0
var wave_t: float = 0.0
var waved: bool = false
var peak: int = 1
var floors: int = 0           ## floors whose quota was met
var total_kills: int = 0
var floor_data: Dictionary = {}


static func create(seed_: int, depth_: int = 1) -> DmDepthsRun:
	DmSimData.ensure()
	var r := DmDepthsRun.new()
	r.seed = seed_
	r.depth = maxi(1, depth_)
	r.peak = r.depth
	r.load_floor()
	return r


static func generate(seed_: int, depth_: int) -> Dictionary:
	DmSimData.ensure()
	return DmDepthsFloor.generate_floor(DmDepthsFloor.floor_seed(seed_, depth_), depth_, int(DmSimData.DEPTHS["chestEvery"]))


## Generate the floor of the current depth and reset the floor's counters.
func load_floor() -> Dictionary:
	floor_data = generate(seed, depth)
	need = DmSimDepthsRules.floor_kills(float(depth))
	kills = 0
	stair_open = false
	floor_t = 0.0
	wave_t = 0.0
	waved = false
	return floor_data


## The stair down was taken: one deeper, a new floor.
func descend() -> Dictionary:
	depth += 1
	peak = maxi(peak, depth)
	return load_floor()


## One death on the floor. True when this kill met the quota (the stair opens, the floor pays).
func record_kill() -> bool:
	kills += 1
	total_kills += 1
	if stair_open or float(kills) < need:
		return false
	stair_open = true
	floors += 1
	return true


func still_needed() -> int:
	return int(maxf(0.0, need - float(kills)))


## Enemy level on this floor for a hero of `hero_level` (DmEnemyStats.depth_enemy_level: max(minLevel, hero) + depth x levelsPerDepth).
func enemy_level(hero_level: float) -> float:
	return DmEnemyStats.area_level("depths", [hero_level], 0.0, float(depth))


func summary() -> String:
	return "The descent ends at depth %d · %d slain · %d floor%s cleared. What you looted is yours." % [peak, total_kills, floors, "" if floors == 1 else "s"]


## The sim's update_depths. `heroes` = [Vector2(x, z)] of the living heroes on the floor; `alive` = enemies alive on it; `total` = every enemy
## in the world (DmSimData.GLOBAL_ENEMY_CAP); `elite_base` = the elite chance before the depth bonus (area + difficulty).
## Returns orders [{def, x, z, elite, affix, extras}] (positions around a breach, not yet snapped to the navmesh); [] = nothing this tick.
func plan_wave(dt: float, alive: int, total: int, heroes: Array, rng: RandomNumberGenerator, elite_base: float) -> Array:
	var f := floor_data
	if f.is_empty() or heroes.is_empty():
		return []
	floor_t += dt
	var D: Dictionary = DmSimData.DEPTHS
	if stair_open or floor_t < float(D["firstWaveDelayS"]):
		return []
	var wanted := need - float(kills) - float(alive)
	if wanted <= 0.0:
		return []
	wave_t -= dt
	if wave_t > 0.0:
		return []
	var room := mini(int(D["cap"]) - alive, int(DmSimData.GLOBAL_ENEMY_CAP) - total)
	if room <= 0:
		wave_t = 0.5
		return []
	var size := DmSimDepthsRules.depth_wave_size(float(depth))
	var count := mini(mini(int(wanted), room), int(size) if waved else int(maxf(size, 8.0)))
	var in_rooms: Dictionary = {}
	for p: Vector2 in heroes:
		in_rooms[DmDepthsFloor.room_at(f, p.x, p.y)] = true
	var hop_cache: Dictionary = {}
	var hops := func(rm: int) -> int:
		if hop_cache.has(rm):
			return hop_cache[rm]
		var best := 1 << 30
		for r in in_rooms.keys():
			var hv := DmDepthsFloor.floor_hops(f, int(r), rm)
			if hv < 0:
				hv = 99
			best = mini(best, hv)
		hop_cache[rm] = best
		return best
	var pool: Array = []
	for b: Dictionary in f["breaches"]:
		if in_rooms.has(int(b["room"])):
			continue
		var far_enough := true
		for p: Vector2 in heroes:
			if Vector2(p.x - float(b["x"]), p.y - float(b["z"])).length() < DmSimConsts.SPAWN_MIN_DIST:
				far_enough = false
				break
		if far_enough:
			pool.append(b)
	if pool.is_empty():
		for b: Dictionary in f["breaches"]:
			if not in_rooms.has(int(b["room"])):
				pool.append(b)
	if pool.is_empty():
		pool = f["breaches"].duplicate()
	if pool.is_empty():
		return []
	var nearest := 1 << 30
	for b: Dictionary in pool:
		nearest = mini(nearest, int(hops.call(int(b["room"]))))
	pool = pool.filter(func(b: Dictionary) -> bool: return int(hops.call(int(b["room"]))) <= nearest + 1)
	var roster := DmSimDepthsRules.depth_roster(float(depth))
	var picks := mini(pool.size(), 3 if count > 6 else (2 if count > 3 else 1))
	var chosen: Array = []
	for _i in picks:
		var idx := rng.randi() % pool.size()
		chosen.append(pool[idx])
		pool.remove_at(idx)
	var orders: Array = []
	var i := 0
	while orders.size() < count:
		var b: Dictionary = chosen[i % chosen.size()]
		var band := _band(float(b["x"]), float(b["z"]), roster, count - orders.size(), rng, elite_base)
		if band.is_empty():
			break
		orders.append_array(band)
		i += 1
	waved = true
	wave_t = DmSimDepthsRules.depth_wave_gap_s(float(depth))
	return orders


## One pick climbing out beside a breach (sim spawn_at_breach): a pack brings its pack (never more than `room`), anything else may be elite.
func _band(bx: float, bz: float, roster: Array, room: int, rng: RandomNumberGenerator, elite_base: float) -> Array:
	var pick: Variant = DmRng.pick_weighted(roster, rng.randf())
	if pick == null or room <= 0:
		return []
	var id := String(pick["id"])
	var pack: Variant = DmSimData.ENEMIES[id].get("pack")
	var elite := id != "risen" and pack == null and rng.randf() < elite_base + DmSimDepthsRules.depth_elite_bonus(float(depth))
	var n := 1
	if pack is Array:
		n = mini(room, int(pack[0]) + int(floorf(rng.randf() * (float(pack[1]) - float(pack[0]) + 1.0))))
	var out: Array = []
	for k in maxi(1, n):
		var ang := rng.randf() * TAU
		var rr := 0.5 + rng.randf() * 2.4
		var o := {"def": id, "x": bx + cos(ang) * rr, "z": bz + sin(ang) * rr, "elite": elite and k == 0, "affix": "", "extras": []}
		if o["elite"]:
			o["affix"] = String(DmSimData.AFFIX_ORDER[rng.randi() % DmSimData.AFFIX_ORDER.size()])
			o["extras"] = DmSimDepthsRules.pick_extra_affixes(float(depth), String(o["affix"]), func() -> float: return rng.randf())
		out.append(o)
	return out
