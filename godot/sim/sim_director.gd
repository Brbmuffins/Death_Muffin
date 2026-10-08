class_name DmSimDirector
extends RefCounted
## The wave director of WorldSim.ts: waves, breaches, Grave Surges, vacant-area crumbling, the Catacomb Depths run, gathering nodes.
## Static helpers taking the sim.

static func _h(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


# --- Waves ---

static func fair_breaches(sim: DmWorldSim, area: String) -> Array:
	var def: Dictionary = DmSimData.AREAS[area]
	var pl := sim.players_in(area)
	var ok: Array = []
	for b: Array in def["breaches"]:
		var good := true
		for p: DmSimPlayer in pl:
			var d := _h(p.x - float(b[0]), p.z - float(b[1]))
			if not (d >= DmSimConsts.SPAWN_MIN_DIST and d <= DmSimConsts.SPAWN_MAX_DIST):
				good = false
				break
		if good:
			ok.append(b)
	return ok if not ok.is_empty() else def["breaches"]


static func update_waves(sim: DmWorldSim, dt: float) -> void:
	crumble_vacant(sim, dt)
	for id: String in DmSimData.AREA_ORDER:
		if not sim.has_player_in(id):   # (pure checks, cheapest first: all but the hero's area stop here)
			continue
		var def: Dictionary = DmSimData.AREAS[id]
		if DmCombatData.truthy(def["safe"]) or DmCombatData.truthy(def.get("instance")) or not sim.nav.is_unlocked(id):
			continue
		if id == String(DmSimData.BOSSES[sim.bossId]["area"]) and sim.boss.state.active:
			continue
		if not sim.waveTimers.has(id):
			sim.arrivedAt[id] = sim.time
			spawn_wave(sim, id, true)
			sim.waveTimers[id] = (float(def["waveIntervalMs"]) / 1000.0) * float(DmWaveUpgrades.wave_modifiers(sim.ramp_tier(id))["intervalMult"])
			continue
		var t: float = float(sim.waveTimers[id]) - dt
		if t <= 0.0:
			spawn_wave(sim, id)
			t = (float(def["waveIntervalMs"]) / 1000.0) * float(DmWaveUpgrades.wave_modifiers(sim.ramp_tier(id))["intervalMult"])
		sim.waveTimers[id] = t


## An area with no living player for VACANT_CRUMBLE_S sinks back into its graves and greets the next arrival afresh.
static func crumble_vacant(sim: DmWorldSim, dt: float) -> void:
	for id: String in DmSimData.AREA_ORDER:
		if DmCombatData.truthy(DmSimData.AREAS[id]["safe"]):
			continue
		if sim.has_player_in(id):
			sim.vacantS.erase(id)
			continue
		var v: float = float(sim.vacantS.get(id, 0.0)) + dt
		sim.vacantS[id] = v
		if v < DmSimConsts.VACANT_CRUMBLE_S:
			continue
		for e: DmSimEnemy in sim.enemies.values():
			if e.area == id:
				sim.enemies.erase(e.id)
		if sim.surge != null and sim.surge["area"] == id:
			sim.emit({"t": "surgeFailed", "area": id, "x": sim.surge["x"], "z": sim.surge["z"]})
			end_surge(sim)
		sim.waveTimers.erase(id)


static func spawn_wave(sim: DmWorldSim, area: String, first: bool = false) -> void:
	var def: Dictionary = DmSimData.AREAS[area]
	var mods := DmWaveUpgrades.wave_modifiers(sim.ramp_tier(area))
	var cap := DmMath.js_round(float(def["cap"]) * float(mods["capMult"]))
	var room := mini(cap - sim.alive_in(area), int(DmSimData.GLOBAL_ENEMY_CAP) - sim.enemies.size())
	if room <= 0:
		return
	var omen_mult := 1.0
	var omen_elite := 0.0
	var omen_affix := ""
	if sim.omen != null:
		omen_mult = float(sim.omen.get("waveSizeMult", 1.0))
	var count: int
	if first:
		count = DmMath.js_round(float(def["waveSize"]) * 1.3)
	else:
		count = DmMath.js_round(float(def["waveSize"]) * float(mods["sizeMult"]) * omen_mult * float(sim.vowFx["waveSizeMult"]))
	count = mini(count, room)
	var pool := fair_breaches(sim, area)
	var breach_count := mini(pool.size(), 3 if count > 11 else (2 if count > 5 else 1))
	var chosen: Array = []
	for i in breach_count:
		chosen.append(pool[int(floorf(sim.rand() * pool.size()))])
	var n := 0 if first else int(sim.waveCounts.get(area, 0)) + 1
	if not first:
		sim.waveCounts[area] = n
	var vanguard := not first and n % 2 == 1 and DmWaveUpgrades.milestone_active("vanguard", sim.ramp_tier(area))
	var themes: Variant = DmSimData.WAVE_THEMES.get(area)
	var theme: Variant = null
	if not first and themes != null and not themes.is_empty() and n >= int(DmSimData.PROCESSION["minWave"]) and sim.rand() < float(DmSimData.PROCESSION["chance"]):
		theme = themes[int(floorf(sim.rand() * themes.size()))]
	if theme != null:
		count = maxi(1, mini(room, DmMath.js_round(float(count) * float(theme["sizeMult"]))))
	var has_elite := false
	var spawned := 0
	var i := 0
	while spawned < count:
		var bz: Array = chosen[i % chosen.size()]
		var lead: String = ""
		if i == 0 and theme != null and theme.has("lead") and theme["lead"] != null:
			lead = theme["lead"]
		var roster: Variant = theme["roster"] if (theme != null and theme.has("roster")) else null
		var band := spawn_at_breach(sim, area, float(bz[0]), float(bz[1]), vanguard and not has_elite and lead == "", roster, lead, count - spawned)
		if band.is_empty():
			break
		spawned += band.size()
		if band[0].elite:
			has_elite = true
		i += 1
	for b: Array in chosen:
		var ev := {"t": "wave", "area": area, "count": spawned, "x": b[0], "z": b[1]}
		if theme != null:
			ev["theme"] = theme["id"]
		sim.emit(ev)


## One wave pick climbing out beside a breach. Pack enemies bring their pack, never more than `room`. Returns every body spawned.
static func spawn_at_breach(sim: DmWorldSim, area: String, bx: float, bz: float, force_elite: bool = false, roster_in: Variant = null, lead: String = "", room: float = INF) -> Array:
	var def: Dictionary = DmSimData.AREAS[area]
	var mods := DmWaveUpgrades.wave_modifiers(sim.ramp_tier(area))
	var roster: Array = roster_in if roster_in != null else def["enemies"]
	var dm := float(sim.vowFx["deaconMult"])
	var id := ""
	if lead != "":
		id = lead
	else:
		var weighted: Array = roster
		if dm > 1.0:
			weighted = []
			for r: Dictionary in roster:
				if r["id"] == "deacon":
					var r2: Dictionary = r.duplicate()
					r2["weight"] = float(r["weight"]) * dm
					weighted.append(r2)
				else:
					weighted.append(r)
		var pick: Variant = DmRng.pick_weighted(weighted, sim.rand())
		if pick != null:
			id = pick["id"]
	if id == "" or room <= 0.0:
		return []
	var pack: Variant = DmSimData.ENEMIES[id].get("pack")
	var omen_elite := 0.0
	if sim.omen != null:
		omen_elite = float(sim.omen.get("eliteBonus", 0.0))
	var depth_bonus := DmSimDepthsRules.depth_elite_bonus(float(sim.depths["depth"])) if (area == "depths" and sim.depths != null) else 0.0
	var roll := sim.rand() < float(def["eliteChance"]) + float(mods["eliteBonus"]) + float(DmContent.difficulty(sim.difficulty)["eliteBonus"]) + omen_elite + float(sim.vowFx["eliteBonus"]) + depth_bonus
	var elite := id != "risen" and pack == null and (force_elite or roll)
	var shroud := ""
	if not elite and DmWaveUpgrades.milestone_active("nightfall", sim.ramp_tier(area)) and sim.rand() < DmSimData.NIGHTFALL_SHROUD_CHANCE:
		shroud = "shrouded"
	elif elite and sim.omen != null and sim.omen.get("affix") != null:
		shroud = sim.omen["affix"]
	var p := _at(sim, area, bx, bz)
	var band: Array = [sim.spawn_enemy(id, area, p[0], p[1], elite, true, shroud)]
	if pack != null:
		var size := mini(int(room) if room != INF else 1 << 30, int(pack[0]) + int(floorf(sim.rand() * (float(pack[1]) - float(pack[0]) + 1.0))))
		while band.size() < size:
			var q := _at(sim, area, bx, bz)
			band.append(sim.spawn_enemy(id, area, q[0], q[1], false, true))
	return band


static func _at(sim: DmWorldSim, area: String, bx: float, bz: float) -> Array:
	var ang := sim.rand() * PI * 2.0
	var rr := 0.5 + sim.rand() * 2.4
	return sim.nav.resolve_in_area(area, bx + DmFdlibm.cos_(ang) * rr, bz + DmFdlibm.sin_(ang) * rr, 0.5)


# --- Grave Surges ---

static func update_surge(sim: DmWorldSim, dt: float) -> void:
	var s: Variant = sim.surge
	var S: Dictionary = DmSimData.SURGE
	if s != null:
		var age: float = sim.time - float(s["startedAt"])
		var at: Array = S["waveAtS"]
		while int(s["wavesSpawned"]) < at.size() and age >= float(at[int(s["wavesSpawned"])]):
			s["wavesSpawned"] += 1
			spawn_surge_wave(sim, s)
		var all_out: bool = int(s["wavesSpawned"]) >= at.size()
		if all_out and int(s["spawned"]) > 0 and float(s["killed"]) >= float(s["spawned"]) * float(S["clearFrac"]):
			sim.emit({"t": "surgeCleared", "area": s["area"], "x": s["x"], "z": s["z"]})
			end_surge(sim)
		elif sim.time >= float(s["endsAt"]):
			sim.emit({"t": "surgeFailed", "area": s["area"], "x": s["x"], "z": s["z"]})
			end_surge(sim)
		return
	var eligible: Array = []
	for id: String in DmSimData.AREA_ORDER:
		if not sim.has_player_in(id):
			continue
		var def: Dictionary = DmSimData.AREAS[id]
		if not DmCombatData.truthy(def["safe"]) and def["breaches"].size() > 0 and sim.nav.is_unlocked(id) \
				and not (id == String(DmSimData.BOSSES[sim.bossId]["area"]) and sim.boss.state.active):
			eligible.append(id)
	if eligible.is_empty():
		return
	sim.surgeIn -= dt
	if sim.surgeIn > 0.0:
		return
	start_surge(sim, eligible[int(floorf(sim.rand() * eligible.size()))])


## Open a surge now (also the DEV/QA entry point).
static func start_surge(sim: DmWorldSim, area: String) -> void:
	var def: Dictionary = DmSimData.AREAS[area]
	if sim.surge != null or DmCombatData.truthy(def["safe"]) or def["breaches"].is_empty():
		return
	var pl := sim.players_in(area)
	var cr: Array = []
	for c: Dictionary in sim.crypts:
		if c["area"] != area:
			continue
		var good := true
		for p: DmSimPlayer in pl:
			var d := _h(p.x - float(c["x"]), p.z - float(c["z"]))
			if not (d >= DmSimConsts.SPAWN_MIN_DIST and d <= DmSimConsts.SPAWN_MAX_DIST):
				good = false
				break
		if good:
			cr.append(c)
	var crypt := not cr.is_empty()
	var pool: Array = []
	if crypt:
		for c: Dictionary in cr:
			pool.append([c["x"], c["z"]])
	else:
		pool = fair_breaches(sim, area)
	var pick: Array = pool[int(floorf(sim.rand() * pool.size()))]
	var S: Dictionary = DmSimData.SURGE
	sim.surge = {"area": area, "x": pick[0], "z": pick[1], "startedAt": sim.time, "endsAt": sim.time + float(S["durationS"]), "wavesSpawned": 0, "ids": {}, "spawned": 0, "killed": 0}
	var ev := {"t": "surge", "area": area, "x": pick[0], "z": pick[1], "durationMs": float(S["durationS"]) * 1000.0}
	if crypt:
		ev["crypt"] = true
	sim.emit(ev)


static func spawn_surge_wave(sim: DmWorldSim, s: Dictionary) -> void:
	var def: Dictionary = DmSimData.AREAS[s["area"]]
	var room := int(DmSimData.GLOBAL_ENEMY_CAP) - sim.enemies.size()
	var count := mini(room, DmMath.js_round(float(def["waveSize"]) * float(DmSimData.SURGE["waveSizeMult"]) * float(DmWaveUpgrades.wave_modifiers(sim.ramp_tier(s["area"]))["sizeMult"])))
	if count <= 0:
		return
	var spawned := 0
	while spawned < count:
		var band := spawn_at_breach(sim, s["area"], float(s["x"]), float(s["z"]), false, null, "", count - spawned)
		if band.is_empty():
			break
		for e: DmSimEnemy in band:
			s["ids"][e.id] = true
			s["spawned"] += 1
			spawned += 1
	sim.emit({"t": "wave", "area": s["area"], "count": spawned, "x": s["x"], "z": s["z"]})


static func end_surge(sim: DmWorldSim) -> void:
	sim.surge = null
	var restless: float = DmSimData.RESTLESS_SURGE_MULT if DmWaveUpgrades.milestone_active("restless", sim.waveTier) else 1.0
	var S: Dictionary = DmSimData.SURGE
	sim.surgeIn = (float(S["minIntervalS"]) + sim.rand() * (float(S["maxIntervalS"]) - float(S["minIntervalS"]))) * restless


# --- The Catacomb Depths ---

## Begin a run: open the instance's ground to walkers and build floor `depth`. Returns the floor Dictionary (DmDepthsFloor).
static func start_depths(sim: DmWorldSim, owner: String, seed_: int, depth: int = 1, hold: bool = false) -> Dictionary:
	sim.nav.open_instance("depths")
	sim.arrivedAt["depths"] = sim.time - DmSimConsts.RAMP_S
	sim.depths = {"owner": owner, "seed": seed_, "depth": depth, "need": 0.0, "kills": 0, "stairOpen": false, "floorT": 0.0, "waveT": 0.0, "waved": false, "hold": hold,
		"peak": depth, "floors": 0, "totalKills": 0}
	return load_depths_floor(sim)


## Go down one floor (the stair was taken).
static func descend_depths(sim: DmWorldSim) -> Variant:
	var run: Variant = sim.depths
	if run == null:
		return null
	if not run["hold"]:
		run["depth"] += 1
	run["peak"] = maxi(int(run["peak"]), int(run["depth"]))
	run["kills"] = 0
	run["stairOpen"] = false
	return load_depths_floor(sim)


## The run is over: the ground closes and the floor's dead sink away. Returns the run dict.
static func end_depths(sim: DmWorldSim) -> Variant:
	var run: Variant = sim.depths
	if run == null:
		return null
	wipe_depths_ground(sim)
	sim.nav.clear_depths_floor()
	sim.nav.close_instance("depths")
	sim.depths = null
	return run


static func load_depths_floor(sim: DmWorldSim) -> Dictionary:
	var run: Dictionary = sim.depths
	wipe_depths_ground(sim)
	var floor_ := DmDepthsFloor.generate_floor(DmDepthsFloor.floor_seed(int(run["seed"]), int(run["depth"])), int(run["depth"]), int(DmSimData.DEPTHS["chestEvery"]))
	sim.nav.load_depths_floor(floor_)
	run["need"] = DmSimDepthsRules.floor_kills(float(run["depth"]))
	run["floorT"] = 0.0
	run["waveT"] = 0.0
	run["waved"] = false
	sim.vacantS.erase("depths")
	sim.emit({"t": "depthsFloor", "depth": run["depth"], "need": run["need"], "chest": floor_["chest"] != null})
	return floor_


static func wipe_depths_ground(sim: DmWorldSim) -> void:
	for e: DmSimEnemy in sim.enemies.values():
		if e.area == "depths":
			sim.enemies.erase(e.id)
	for c: DmSimCorpse in sim.corpses.values():
		if c.area == "depths":
			sim.remove_corpse(c, "expired")
	var r: Dictionary = DmSimData.AREAS["depths"]["rect"]
	for z: DmSimZone in sim.zones.values():
		if z.x < float(r["x0"]) or z.x > float(r["x1"]) or z.z < float(r["z0"]) or z.z > float(r["z1"]):
			continue
		sim.zones.erase(z.id)
		sim.emit({"t": "zoneGone", "id": z.id})
	for id in sim.walls.keys():
		var w: Dictionary = sim.walls[id]
		if float(w["x0"]) >= float(r["x0"]) and float(w["x0"]) <= float(r["x1"]) and float(w["z0"]) >= float(r["z0"]) and float(w["z0"]) <= float(r["z1"]):
			sim.walls.erase(id)
	for id in sim.brands.keys():
		if sim.brands[id]["area"] == "depths":
			sim.brands.erase(id)
	var keep: Array = []
	for u: Dictionary in sim.unbinds:
		if u["area"] != "depths":
			keep.append(u)
	sim.unbinds = keep


## Quota bookkeeping on each death: the stair down opens when the floor's kills are in.
static func depths_kill(sim: DmWorldSim, e: DmSimEnemy) -> void:
	var run: Variant = sim.depths
	if run == null or e.area != "depths":
		return
	run["kills"] += 1
	run["totalKills"] += 1
	if run["stairOpen"] or float(run["kills"]) < float(run["need"]):
		return
	run["stairOpen"] = true
	run["floors"] += 1
	var f: Variant = sim.nav.depths_floor()
	sim.emit({"t": "depthsClear", "depth": run["depth"], "x": f["stairDown"]["x"] if f != null else 0.0, "z": f["stairDown"]["z"] if f != null else 0.0})


## The floor's own waves: only as many of the dead climb out as the quota still needs, never more than DEPTHS.cap alive.
static func update_depths(sim: DmWorldSim, dt: float) -> void:
	var run: Variant = sim.depths
	if run == null:
		return
	var floor_: Variant = sim.nav.depths_floor()
	var pl := sim.players_in("depths")
	if floor_ == null or pl.is_empty():
		return
	run["floorT"] = float(run["floorT"]) + dt
	var D: Dictionary = DmSimData.DEPTHS
	if run["stairOpen"] or float(run["floorT"]) < float(D["firstWaveDelayS"]):
		return
	var alive := sim.alive_in("depths")
	var wanted := float(run["need"]) - float(run["kills"]) - alive
	if wanted <= 0.0:
		return
	run["waveT"] = float(run["waveT"]) - dt
	if float(run["waveT"]) > 0.0:
		return
	var room := mini(int(D["cap"]) - alive, int(DmSimData.GLOBAL_ENEMY_CAP) - sim.enemies.size())
	if room <= 0:
		run["waveT"] = 0.5
		return
	var size := DmSimDepthsRules.depth_wave_size(float(run["depth"]))
	var count := mini(mini(int(wanted), room), int(size) if run["waved"] else int(maxf(size, 8.0)))
	var in_rooms: Dictionary = {}
	for p: DmSimPlayer in pl:
		in_rooms[DmDepthsFloor.room_at(floor_, p.x, p.z)] = true
	var hops := func(rm: int) -> int:
		var best := 1 << 30
		for r in in_rooms.keys():
			var hv := DmDepthsFloor.floor_hops(floor_, int(r), rm)
			if hv < 0:
				hv = 99
			best = mini(best, hv)
		return best
	var pool: Array = []
	for b: Dictionary in floor_["breaches"]:
		if in_rooms.has(int(b["room"])):
			continue
		var far_enough := true
		for p: DmSimPlayer in pl:
			if _h(p.x - float(b["x"]), p.z - float(b["z"])) < DmSimConsts.SPAWN_MIN_DIST:
				far_enough = false
				break
		if far_enough:
			pool.append(b)
	if pool.is_empty():
		for b: Dictionary in floor_["breaches"]:
			if not in_rooms.has(int(b["room"])):
				pool.append(b)
	if pool.is_empty():
		pool = floor_["breaches"].duplicate()
	var nearest := 1 << 30
	for b: Dictionary in pool:
		nearest = mini(nearest, hops.call(int(b["room"])))
	var pool2: Array = []
	for b: Dictionary in pool:
		if int(hops.call(int(b["room"]))) <= nearest + 1:
			pool2.append(b)
	pool = pool2
	var roster := DmSimDepthsRules.depth_roster(float(run["depth"]))
	var spawned := 0
	var picks := mini(pool.size(), 3 if count > 6 else (2 if count > 3 else 1))
	var chosen: Array = []
	for i in picks:
		var idx := int(floorf(sim.rand() * pool.size()))
		chosen.append(pool[idx])
		pool.remove_at(idx)
	var i := 0
	while spawned < count:
		var b: Dictionary = chosen[i % chosen.size()]
		var band := spawn_at_breach(sim, "depths", float(b["x"]), float(b["z"]), false, roster, "", count - spawned)
		if band.is_empty():
			break
		spawned += band.size()
		i += 1
	run["waved"] = true
	run["waveT"] = DmSimDepthsRules.depth_wave_gap_s(float(run["depth"]))
	if spawned != 0:
		for b: Dictionary in chosen:
			sim.emit({"t": "wave", "area": "depths", "count": spawned, "x": b["x"], "z": b["z"]})


# --- Gathering nodes ---

static func set_nodes(sim: DmWorldSim, placements: Array) -> void:
	sim.nodes.clear()
	for p: Dictionary in placements:
		var def: Variant = DmSimData.NODES.get(p["type"])
		if def == null:
			continue
		var rich: bool = DmCombatData.truthy(p.get("rich"))
		sim.nodes[p["id"]] = {"id": p["id"], "type": p["type"], "area": p["area"], "x": p["x"], "z": p["z"], "rich": rich, "remaining": roll_yield(sim, def, rich), "respawnAt": 0.0}


static func roll_yield(sim: DmWorldSim, def: Dictionary, rich: bool) -> float:
	var lo := float(def["yields"][0])
	var hi := float(def["yields"][1])
	var n := lo + floorf(sim.rand() * (hi - lo + 1.0))
	return maxf(1.0, DmMath.js_round_f(n * (DmSimData.RICH_YIELD if rich else 1.0)))


## Depleted nodes and the seconds until each returns: [[id, seconds]].
static func depleted_nodes(sim: DmWorldSim) -> Array:
	var out: Array = []
	for n: Dictionary in sim.nodes.values():
		if float(n["remaining"]) <= 0.0:
			out.append([n["id"], maxf(0.0, DmMath.js_round_f((float(n["respawnAt"]) - sim.time) * 10.0) / 10.0)])
	return out


static func apply_gather(sim: DmWorldSim, g: Dictionary) -> void:
	var n: Variant = sim.nodes.get(g["nodeId"])
	if n == null or float(n["remaining"]) <= 0.0:
		return
	var p: DmSimPlayer = sim.players.get(g["by"])
	var def: Dictionary = DmSimData.NODES[n["type"]]
	if p != null and _h(p.x - float(n["x"]), p.z - float(n["z"])) > float(DmSimData.NODE_REACH[def["kind"]]) + 2.0:
		return
	n["remaining"] = float(n["remaining"]) - minf(3.0, maxf(1.0, floorf(float(g["successes"]))))
	if float(n["remaining"]) > 0.0:
		return
	n["remaining"] = 0.0
	var respawn_s := float(def["respawnS"]) * (DmSimData.RICH_RESPAWN if n["rich"] else 1.0)
	n["respawnAt"] = sim.time + respawn_s
	sim.emit({"t": "nodeGone", "id": n["id"], "by": g["by"], "respawnS": respawn_s})


static func update_nodes(sim: DmWorldSim) -> void:
	for n: Dictionary in sim.nodes.values():
		if float(n["remaining"]) > 0.0 or sim.time < float(n["respawnAt"]):
			continue
		n["remaining"] = roll_yield(sim, DmSimData.NODES[n["type"]], n["rich"])
		sim.emit({"t": "nodeBack", "id": n["id"]})
