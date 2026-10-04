class_name DmWorldSim
extends RefCounted
## Headless, deterministic port of src/gameplay/sim/WorldSim.ts (see godot/sim/README.md for how to drive it).
## Entity field names, event/intent dictionary keys and tuning tables are the TS ones; methods are snake_case.
## The helper modules (sim_enemy_ai.gd, sim_thrall_ai.gd, sim_signatures.gd, sim_director.gd, sim_zones.gd) hold the other halves of the TS class
## as static functions taking the sim. Nothing here renders: positions are plain floats on the XZ plane.

var nav: DmNav
var rng: DmRng
var enemies: Dictionary = {}
var thralls: Dictionary = {}
var corpses: Dictionary = {}
var zones: Dictionary = {}
var players: Dictionary = {}
var nodes: Dictionary = {}
var bosses: Dictionary = {}
var bossId: String = "prelate"
var boss: DmBossController:
	get:
		return bosses[bossId]
var cover: Array = []
var waveTier: float = 0.0
## The week's Omen dict (content/omens) or null.
var omen: Variant = null
var difficulty: String = "medium"
var _vows: Dictionary = {}
var vowFx: Dictionary = {}
var vows: Dictionary:
	get:
		return _vows
	set(v):
		_vows = v.duplicate()
		vowFx = DmVowsBoons.vow_effects(_vows)
var ascension: float:
	get:
		return DmVowsBoons.vow_heat(_vows)
	set(n):
		vows = DmVowsBoons.legacy_vows(n)
var corpseLifeMult: float = 1.0
var time: float = 0.0
var surge: Variant = null
var depths: Variant = null
var surgeIn: float = 0.0

var unbinds: Array = []
var events: Array = []
var _next_id: int = 1
var waveTimers: Dictionary = {}
var vacantS: Dictionary = {}
var arrivedAt: Dictionary = {}
var waveCounts: Dictionary = {}
var walls: Dictionary = {}
var brands: Dictionary = {}
var crypts: Array = []
var dotAccum: Dictionary = {}
var bloomed: Dictionary = {}
var legends: Dictionary = {}
var raised: Dictionary = {}
var lastMiasma: Dictionary = {}
var plagueZones: Dictionary = {}
var bossMark: Variant = null
var anyPlague: bool = false
var pendingLitanies: Array = []
var dotPruneAt: float = 0.0


## `p_rng`: a DmRng (seeded mulberry32), or null for a fresh one seeded from the clock (non-deterministic).
func _init(p_nav: DmNav, p_rng: DmRng = null) -> void:
	DmSimData.ensure()
	nav = p_nav
	rng = p_rng if p_rng != null else DmRng.new(int(Time.get_ticks_usec()))
	vowFx = DmVowsBoons.vow_effects(_vows)
	surgeIn = float(DmSimData.SURGE["firstDelayS"])
	var factory: Variant = null
	if ResourceLoader.exists("res://sim/bosses/boss_factory.gd"):
		factory = load("res://sim/bosses/boss_factory.gd")
	if factory != null:
		bosses = factory.make_all(self)
	else:
		for id in DmContent.bosses().keys():
			var c := DmBossStub.new()
			c.setup(self, id)
			bosses[id] = c


## Number of random draws so far (the fixtures compare it: a differing count pinpoints the first divergence).
var rng_calls: int = 0


func rand() -> float:
	rng_calls += 1
	return rng.next()


func next_id() -> int:
	_next_id += 1
	return _next_id - 1


## After seeding from a mirror keep new ids above the old ones.
func reserve_ids(max_used: int) -> void:
	_next_id = maxi(_next_id, max_used + 1)


func emit(ev: Dictionary) -> void:
	events.append(ev)


func drain() -> Array:
	var out := events
	events = []
	return out


func boss_state() -> DmBossState:
	return boss.state


func set_cover(boxes: Array) -> void:
	cover = boxes


## Gathering nodes: [{id, type, area, x, z, rich?}] (godot/data/sim/world.json has the generated layout's).
func set_nodes(placements: Array) -> void:
	DmSimDirector.set_nodes(self, placements)


func depleted_nodes() -> Array:
	return DmSimDirector.depleted_nodes(self)


## The Catacomb Depths run API (see README): returns the floor Dictionary.
func start_depths(owner: String, seed_: int, depth: int = 1, hold: bool = false) -> Dictionary:
	return DmSimDirector.start_depths(self, owner, seed_, depth, hold)


func descend_depths() -> Variant:
	return DmSimDirector.descend_depths(self)


func end_depths() -> Variant:
	return DmSimDirector.end_depths(self)


## Open a Grave Surge now (DEV/QA entry point).
func start_surge(area: String) -> void:
	DmSimDirector.start_surge(self, area)


func set_crypts(list: Array) -> void:
	crypts = []
	for c in list:
		crypts.append({"area": c["area"], "x": c["x"], "z": c["z"]})


static func hyp(a: float, b: float) -> float:
	return DmSimMath.hypot(a, b)


## An area's enemy level (see TS areaLevel).
func area_level(area: String) -> float:
	var def: Dictionary = DmSimData.AREAS[area]
	if area == "depths":
		var top := 0.0
		for p: DmSimPlayer in players.values():
			if p.alive and p.area == area and p.level > top:
				top = minf(999.0, p.level)
		return DmEnemyStats.depth_enemy_level(float(depths["depth"]) if depths != null else 1.0, top) + float(vowFx["levels"])
	var level := float(def["level"])
	if DmCombatData.truthy(def.get("scaling")):
		level = float(def["scaling"]["minLevel"])
		for p: DmSimPlayer in players.values():
			if p.alive and p.area == area and p.level > level:
				level = minf(999.0, p.level)
	return level + float(vowFx["levels"])


## A boss's rot pool: a hostile toxic zone (the Plague Saint heals while she stands in one).
func add_hostile_pool(x: float, z: float, r: float, dps: float, seconds: float) -> DmSimZone:
	var zone := DmSimZone.new()
	zone.id = next_id()
	zone.kind = "toxic"
	zone.owner = ""
	zone.x = x
	zone.z = z
	zone.r = r
	zone.until = time + seconds
	zone.bornAt = time
	zone.tick = 1.0
	zone.dps = dps
	zone.slow = 1.0
	zone.witheredCap = 0.0
	zone.bloom = false
	zone.hostile = true
	zones[zone.id] = zone
	emit({"t": "zone", "zone": zone})
	return zone


## Host migration: continue the awake boss on its own brain.
func adopt_boss(state: DmBossState) -> void:
	bossId = state.id if bosses.has(state.id) else "prelate"
	boss.state.from_dict(state.to_dict())
	boss.state.id = bossId
	boss.resume()


## Host migration: re-derive what a snapshot does not carry (damage, radius, level).
func adopt_enemy(e: DmSimEnemy) -> DmSimEnemy:
	var d: Dictionary = DmSimData.ENEMIES[e.def]
	var level := e.level if e.level > 1.0 else area_level(e.area)
	var wave := DmWaveUpgrades.wave_modifiers(waveTier)
	e.damage = float(d["damage"]) * DmEnemyStats.damage_scale(level) * float(wave["enemyDamageMult"]) * float(DmContent.difficulty(difficulty)["enemyDamageMult"]) * (float(DmSimData.ELITE["damageMult"]) if e.elite else 1.0)
	e.level = level
	e.radius = float(d["radius"]) * (1.25 if e.elite else 1.0)
	return e


# --- Players ---

func set_player(body: DmSimPlayer) -> void:
	players[body.id] = body


func remove_player(id: String) -> void:
	players.erase(id)
	for t: DmSimThrall in thralls.values():
		if t.owner == id:
			kill_thrall(t, "crumbled")
	legends.erase(id)
	raised.erase(id)
	lastMiasma.erase(id)
	_recompute_any_plague()


func _recompute_any_plague() -> void:
	anyPlague = false
	for v: Dictionary in legends.values():
		if float(v["witheredBurstAt"]) > 0.0:
			anyPlague = true
			break


## A player's id changed: everything that remembers the old id moves to the new one (does not crumble the legion).
func retag_player(old_id: String, new_id: String) -> void:
	if old_id == new_id:
		return
	players.erase(old_id)
	for t: DmSimThrall in thralls.values():
		if t.owner == old_id:
			t.owner = new_id
	for z: DmSimZone in zones.values():
		if z.owner == old_id:
			z.owner = new_id
	for w: Dictionary in walls.values():
		if w["owner"] == old_id:
			w["owner"] = new_id
	for b: Dictionary in brands.values():
		if b["owner"] == old_id:
			b["owner"] = new_id
	for c: DmSimCorpse in corpses.values():
		if c.seedOwner == old_id:
			c.seedOwner = new_id
		if c.echoOwner == old_id:
			c.echoOwner = new_id
	for e: DmSimEnemy in enemies.values():
		if e.lastHitBy == old_id:
			e.lastHitBy = new_id
		if e.witheredOwner == old_id:
			e.witheredOwner = new_id
		if e.bleedOwner == old_id:
			e.bleedOwner = new_id
		if e.markBy == old_id:
			e.markBy = new_id
		if e.knellOwner == old_id:
			e.knellOwner = new_id
		if e.hexOwner == old_id:
			e.hexOwner = new_id
	for m: Dictionary in [legends, raised, lastMiasma]:
		if not m.has(old_id):
			continue
		m[new_id] = m[old_id]
		m.erase(old_id)


func players_in(area: String) -> Array:
	var out: Array = []
	for p: DmSimPlayer in players.values():
		if p.alive and p.area == area:
			out.append(p)
	return out


# --- Intents ---

func apply(intent: Dictionary) -> void:
	match intent["t"]:
		"hit":
			_apply_hit(intent)
		"miasma":
			_apply_miasma(intent)
		"exhume":
			_apply_exhume(intent)
		"litany":
			_apply_litany(intent)
		"summonBoss":
			if boss.state.active:
				var wanted: String = intent.get("boss", "prelate") if (intent.get("boss") is String and bosses.has(intent.get("boss"))) else "prelate"
				emit({"t": "bossBusy", "by": intent["by"], "boss": wanted, "awake": bossId})
				return
			bossId = intent["boss"] if (intent.get("boss") is String and bosses.has(intent["boss"])) else "prelate"
			boss.awaken(intent["by"], intent.get("empowered", false) == true and DmGoldSink.can_empower(bossId))
		"detonate":
			_apply_detonate(intent)
		"signature":
			DmSimSignatures.apply_signature(self, intent)
		"gather":
			DmSimDirector.apply_gather(self, intent)
		"legend":
			var l := DmLegend.clamp_sim_legend(intent["mods"])
			if DmLegend.sim_legend_active(l):
				legends[intent["by"]] = l
			else:
				legends.erase(intent["by"])
			_recompute_any_plague()
		"refreshThralls":
			_apply_refresh_thralls(intent)
		"recallThralls":
			if not is_finite(float(intent["x"])) or not is_finite(float(intent["z"])):
				return
			for t: DmSimThrall in thralls.values():
				if t.owner != intent["by"]:
					continue
				t.x = float(intent["x"]) + (rand() - 0.5) * 2.0
				t.z = float(intent["z"]) + (rand() - 0.5) * 2.0
				t.target = -1


## `from` = [x, z] of a directed blow (the caster or the thrall that struck), or null; only directed blows can glance off a Bell Templar's shield.
func damage_enemy(e: DmSimEnemy, amount: float, by: String, from: Variant = null) -> float:
	if e.state == "dead" or e.hp <= 0.0:
		return 0.0
	if e.state == "burrow" or (e.erupting != null and e.state == "windup"):
		return 0.0
	var def: Dictionary = DmSimData.ENEMIES[e.def]
	var shield := 1.0
	if DmCombatData.truthy(def.get("shield")) and from != null and e.fracture == 0.0:
		var d := fmod(absf(DmFdlibm.atan2_(float(from[0]) - e.x, float(from[1]) - e.z) - e.facing), PI * 2.0)
		if d > PI:
			d = PI * 2.0 - d
		if d <= (float(DmSimData.TEMPLAR_SHIELD["halfArcDeg"]) * PI) / 180.0:
			shield = float(DmSimData.TEMPLAR_SHIELD["passThrough"])
			if time >= e.blockFxAt:
				e.blockFxAt = time + 0.25
				emit({"t": "shieldBlock", "id": e.id, "x": e.x, "z": e.z})
	var dmg := amount * (1.0 + float(DmSimData.FRACTURE["perStack"]) * e.fracture) * damage_taken_mult(e) * shield
	e.hp -= dmg
	e.flash = 1.0
	e.lastHitBy = by
	if DmCombatData.truthy(def.get("burrow")) and not e.dugIn and e.hp > 0.0 and e.hp < e.maxHp * float(DmSimData.BURROW["digAtFrac"]):
		e.dugIn = true
		e.digPending = true
		e.state = "recover"
		e.stateT = 0.0
		e.groundT = maxf(0.0, float(DmSimData.BURROW["digS"]) - 0.3)
		emit({"t": "digIn", "id": e.id, "x": e.x, "z": e.z})
	return dmg


## Shrouded elites shrug off half of everything unless they stand in a player's rot.
func damage_taken_mult(e: DmSimEnemy) -> float:
	var shroud := float(DmSimData.AFFIX_TUNING["shrouded"]["damageTakenMult"]) if (has_affix(e, "shrouded") and not in_friendly_miasma(e.x, e.z, e.radius)) else 1.0
	return shroud * (float(DmSimData.SANCTIFIED["damageTakenMult"]) if e.sanctT > 0.0 else 1.0)


func in_friendly_miasma(x: float, z: float, radius: float) -> bool:
	for zn: DmSimZone in zones.values():
		if zn.hostile or (zn.kind != "miasma" and zn.kind != "rot"):
			continue
		if hyp(x - zn.x, z - zn.z) <= zn.r + radius:
			return true
	return false


func has_affix(e: DmSimEnemy, a: String) -> bool:
	if e.affix == a:
		return true
	for x: Dictionary in e.extra:
		if x["affix"] == a:
			return true
	return false


func _apply_hit(h: Dictionary) -> void:
	if DmCombatData.truthy(h.get("boss")):
		boss.damage(float(h["dmg"]), h["by"], float(h.get("fracture", 0.0)))
		return
	var caster: DmSimPlayer = players.get(h["by"])
	var from: Variant = [caster.x, caster.z] if caster != null else null
	if DmCombatData.truthy(h.get("spear")):
		_spear_rally(h, caster)
	for id in h["ids"]:
		var e: DmSimEnemy = enemies.get(int(id))
		if e == null or e.state == "burrow" or (e.erupting != null and e.state == "windup"):
			continue
		damage_enemy(e, float(h["dmg"]), h["by"], from)
		var bleed := float(h.get("bleed", 0.0))
		if bleed > 0.0:
			var dps := minf(bleed, float(h["dmg"]) * float(DmSimData.HEMORRHAGE["maxFrac"]))
			if dps >= e.bleedDps or e.bleedT <= 0.0:
				e.bleedDps = dps
				e.bleedOwner = h["by"]
			e.bleedT = float(DmSimData.HEMORRHAGE["durationS"])
		var fr := float(h.get("fracture", 0.0))
		if fr != 0.0:
			e.fracture = minf(float(DmSimData.FRACTURE["maxStacks"]), e.fracture + fr)
			e.fractureT = float(DmSimData.FRACTURE["durationMs"]) / 1000.0
		if DmCombatData.truthy(h.get("chill")):
			e.chillT = maxf(e.chillT, float(DmSimData.GRAVE_FROST["chillS"]))
		if DmCombatData.truthy(h.get("root")):
			var rs: Variant = h.get("rootS")
			var rv: float = float(DmSimData.BONE_PRISON["rootS"])
			if (rs is float or rs is int) and float(rs) > 0.0:
				rv = minf(float(DmSimData.RUNE_TUNING["impale"]["rootS"]), float(rs))
			e.rootT = maxf(e.rootT, rv)
		if DmCombatData.truthy(h.get("slow")):
			e.slowT = maxf(e.slowT, float(DmSimData.GRAVE_HANDS["tickS"]) + 0.2)
		var wd := float(h.get("withered", 0.0))
		if wd > 0.0:
			var cap_raw: Variant = h.get("witheredCap")
			var cap_v: float = float(cap_raw) if (cap_raw is float or cap_raw is int) else float(DmSimData.DETONATE["rotWitheredCap"])
			wither(e, 1.0, minf(12.0, maxf(1.0, floorf(cap_v))), float(h["dmg"]) * float(DmSimData.WITHERED["dpsPerStack"]), h["by"])


## Legion Champion 5: a Marrow Spear hit marks its nearest target; the owner's thralls turn on it and hit it harder for a few seconds.
func _spear_rally(h: Dictionary, caster: DmSimPlayer) -> void:
	var leg: Variant = legends.get(h["by"])
	if leg == null or float(leg["spearRally"]) <= 0.0:
		return
	var mark: DmSimEnemy = null
	var best_d := INF
	for id in h["ids"]:
		var e: DmSimEnemy = enemies.get(int(id))
		if e == null or e.state == "dead" or e.state == "burrow":
			continue
		var d := hyp(e.x - caster.x, e.z - caster.z) if caster != null else 0.0
		if d < best_d:
			mark = e
			best_d = d
	if mark == null:
		return
	mark.markT = float(DmSimData.LEGEND["rallyS"])
	mark.markBonus = float(leg["spearRally"])
	mark.markBy = h["by"]
	emit({"t": "legend", "kind": "rally", "by": h["by"], "x": mark.x, "z": mark.z, "id": mark.id})
	for t: DmSimThrall in owned_thralls(h["by"]):
		if t.state == "rising":
			continue
		t.target = mark.id


## The legion's extra damage on whatever the owner's Marrow Spear marked (1 when nothing is).
func rally_mult(t: DmSimThrall, e: DmSimEnemy) -> float:
	if e != null:
		return 1.0 + e.markBonus if (e.markT > 0.0 and e.markBy == t.owner) else 1.0
	var m: Variant = bossMark
	return 1.0 + float(m["bonus"]) if (m != null and m["by"] == t.owner and time < float(m["until"])) else 1.0


## Add Withered stacks the way zones do (the strongest dps wins, the stacker owns the kill).
func wither(e: DmSimEnemy, stacks: float, cap: float, dps: float, by: String) -> void:
	e.withered = minf(cap, e.withered + stacks)
	e.witheredT = float(DmSimData.WITHERED["durationMs"]) / 1000.0
	e.witheredDps = maxf(e.witheredDps, dps)
	e.witheredOwner = by


func corpse_at(x: float, z: float, r: float, area: String = "") -> DmSimCorpse:
	var best: DmSimCorpse = null
	var best_d := r
	for c: DmSimCorpse in corpses.values():
		if area != "" and c.area != area:
			continue
		if c.echoOwner != "":
			continue
		var d := hyp(c.x - x, c.z - z)
		if d <= best_d:
			best = c
			best_d = d
	return best


func _apply_miasma(m: Dictionary) -> void:
	var leg: Variant = legends.get(m["by"])
	if leg != null and float(leg["witheredBurstAt"]) != 0.0:
		lastMiasma[m["by"]] = {"r": m["r"], "dps": m["dps"], "durationMs": m["durationMs"], "cap": m["witheredCap"], "bloom": m["bloom"]}
	var zone := DmSimZone.new()
	zone.id = next_id()
	zone.kind = "miasma"
	zone.owner = m["by"]
	zone.x = float(m["x"])
	zone.z = float(m["z"])
	zone.r = float(m["r"])
	zone.until = time + float(m["durationMs"]) / 1000.0
	zone.bornAt = time
	zone.tick = 0.0
	zone.dps = float(m["dps"])
	zone.slow = DmSimData.MIASMA_SLOW
	zone.witheredCap = float(m["witheredCap"])
	zone.bloom = DmCombatData.truthy(m["bloom"])
	zone.hostile = false
	var creep: Variant = m.get("creep")
	if (creep is float or creep is int) and float(creep) > 0.0:
		zone.creep = minf(float(DmSimData.RUNE_TUNING["creepingRot"]["speed"]), float(creep))
	if DmCombatData.truthy(m.get("contagion")):
		zone.contagion = true
	zones[zone.id] = zone
	emit({"t": "zone", "zone": zone})


func owned_thralls(owner: String) -> Array:
	var out: Array = []
	for t: DmSimThrall in thralls.values():
		if t.owner == owner and t.state != "dead":
			out.append(t)
	return out


func _apply_exhume(x: Dictionary) -> void:
	if DmCombatData.truthy(x.get("bond")):
		return _bond_thrall(x)
	if DmCombatData.truthy(x.get("colossus")):
		return _raise_colossus(x)
	var MG: Dictionary = DmSimData.RUNE_TUNING["massGrave"]
	var cnt_raw: Variant = x.get("count")
	var cnt := 1.0
	if (cnt_raw is float or cnt_raw is int) and is_finite(float(cnt_raw)):
		cnt = float(cnt_raw)
	var count := int(maxf(1.0, minf(float(MG["count"]), floorf(cnt))))
	var r := maxf(float(x["r"]), float(MG["pickRadius"])) if count > 1 else float(x["r"])
	var p: DmSimPlayer = players.get(x["by"])
	var hall: String = p.area if p != null else ""
	var xx := float(x["x"])
	var zz := float(x["z"])
	var cand: Array = []
	for c: DmSimCorpse in corpses.values():
		if c.echoOwner == "" and (hall == "" or c.area == hall) and hyp(c.x - xx, c.z - zz) <= r:
			cand.append(c)
	var picks: Array = DmStableSort.sorted(cand, func(a: DmSimCorpse, b: DmSimCorpse) -> bool: return hyp(a.x - xx, a.z - zz) < hyp(b.x - xx, b.z - zz))
	picks = picks.slice(0, count)
	if picks.is_empty():
		emit({"t": "exhumed", "by": x["by"], "ok": false, "x": x["x"], "z": x["z"]})
		return
	var stat_mult := float(MG["statMult"]) if picks.size() > 1 else 1.0
	for c: DmSimCorpse in picks:
		_raise_from(x, c, stat_mult)


## Bonded Dead boon: a thrall rises at the owner's feet when the legion is empty (no corpse is needed or spent).
func _bond_thrall(x: Dictionary) -> void:
	var body: DmSimPlayer = players.get(x["by"])
	if body == null or not body.alive or not owned_thralls(x["by"]).is_empty():
		return
	var c := DmSimCorpse.new()
	c.id = 0
	c.x = float(x["x"])
	c.z = float(x["z"])
	c.kind = "normal"
	c.enemy = "risen"
	c.elite = false
	c.facing = 0.0
	c.scale = 1.0
	c.area = body.area if body.area != "" else "graves"
	c.bornAt = time
	c.expiresAt = time
	c.ruptureAt = INF
	_raise_from(x, c, 1.0)


## Make room for `weight` more legion places: the oldest ordinary thrall crumbles first, a Colossus last. Returns the first crumbled id (or -1).
func _make_room(owner: String, cap: float, weight: float) -> int:
	var crumbled := -1
	var owned: Array = DmStableSort.sorted(owned_thralls(owner), func(a: DmSimThrall, b: DmSimThrall) -> bool:
		var ka := 1 if a.kind == "colossus" else 0
		var kb := 1 if b.kind == "colossus" else 0
		if ka != kb:
			return ka < kb
		return a.bornAt < b.bornAt)
	var used := 0.0
	for t: DmSimThrall in owned:
		used += DmThralls.weight(t.kind)
	while not owned.is_empty() and used + weight > cap:
		var o: DmSimThrall = owned.pop_front()
		used -= DmThralls.weight(o.kind)
		if crumbled < 0:
			crumbled = o.id
		kill_thrall(o, "crumbled")
	return crumbled


## A purchase refreshes the owner's standing thralls. Nothing is healed: current health keeps its fraction.
func _apply_refresh_thralls(x: Dictionary) -> void:
	var cl := func(v: Variant) -> float:
		var f: float = float(v) if (v is float or v is int) else NAN
		return minf(DmSimData.THRALL_REFRESH_MAX, maxf(1.0, f)) if is_finite(f) else 1.0
	var hp: float = cl.call(x["hpMult"])
	var dmg: float = cl.call(x["damageMult"])
	var speed: float = cl.call(x["speedMult"])
	if hp == 1.0 and dmg == 1.0 and speed == 1.0:
		return
	for t: DmSimThrall in owned_thralls(x["by"]):
		if t.state == "dead":
			continue
		t.hp *= hp
		t.maxHp *= hp
		t.damage *= dmg
		t.attackInterval /= speed


func _next_free_slot(owner: String) -> int:
	var used: Dictionary = {}
	for t: DmSimThrall in owned_thralls(owner):
		used[t.slot] = true
	var slot := 0
	while used.has(slot):
		slot += 1
	return slot


func _thrall_from_corpse(c: DmSimCorpse, discipline: String) -> String:
	if discipline == "wraith":
		return "wraith"
	if c.kind == "swift":
		return "hound"
	if c.enemy == "penitent":
		return "archer"
	if c.enemy == "deacon":
		return "bonemage"
	if c.enemy == "sac":
		return "plaguebearer"
	return discipline


## One ordinary exhume: this corpse becomes a thrall for the intent's owner.
func _raise_from(x: Dictionary, best: DmSimCorpse, stat_mult: float) -> void:
	remove_corpse(best, "consumed", x["by"])
	var crumbled := _make_room(x["by"], float(x["cap"]), 1.0)
	var k: Variant = x.get("kind")
	var kind := _thrall_from_corpse(best, k if (k is String and DmThralls.is_known_kind(k)) else "warrior")
	var sc := DmThralls.scale_of(kind)
	var empowered := best.kind == "resonant" or best.elite
	var base := DmThralls.base_of(kind)
	var raised_n: int = int(raised.get(x["by"], 0)) + 1
	raised[x["by"]] = raised_n
	var leg: Variant = legends.get(x["by"])
	var every := int(leg["championEvery"]) if leg != null else 0
	var champion := every > 0 and raised_n % every == 0
	var t := DmSimThrall.new()
	t.id = next_id()
	t.owner = x["by"]
	t.kind = kind
	t.x = best.x
	t.z = best.z
	t.facing = best.facing
	var hp: float = float(x["hp"]) * (1.5 if empowered else 1.0) * float(sc["hp"]) * stat_mult * (float(DmSimData.LEGEND["championHp"]) if champion else 1.0)
	t.hp = hp
	t.maxHp = hp
	t.damage = float(x["damage"]) * (1.5 if empowered else 1.0) * float(sc["dmg"]) * stat_mult * (float(DmSimData.LEGEND["championDamage"]) if champion else 1.0)
	t.attackInterval = float(base["interval"]) / float(x["attackSpeedMult"])
	t.range = float(base["range"])
	t.speed = float(base["speed"])
	t.state = "rising"
	t.stateT = 0.0
	t.attackCd = 0.4
	t.target = -1
	t.slot = _next_free_slot(x["by"])
	t.bornAt = time
	t.empowered = empowered
	if champion:
		t.champion = true
	var ah: Variant = x.get("allyHeal")
	if kind == "wraith" and (ah is float or ah is int) and float(ah) > 0.0:
		t.allyHeal = minf(float(DmSimData.NECRO_WEAPON_TUNING["mourning_bell"]["allyHealFrac"]) * 1.5, float(ah))
	thralls[t.id] = t
	emit({"t": "thrall", "id": t.id, "owner": t.owner, "kind": kind, "x": t.x, "z": t.z, "empowered": empowered})
	var ev := {"t": "exhumed", "by": x["by"], "ok": true, "corpseKind": best.kind, "x": best.x, "z": best.z}
	if crumbled >= 0:
		ev["crumbled"] = crumbled
	emit(ev)


## Bone Colossus rune: the corpses nearest the point are consumed and one giant thrall rises where they lay.
func _raise_colossus(x: Dictionary) -> void:
	var T: Dictionary = DmSimData.RUNE_TUNING["colossus"]
	var r := minf(float(T["pickRadius"]), maxf(0.2, float(x["r"])))
	var xx := float(x["x"])
	var zz := float(x["z"])
	var cand: Array = []
	for c: DmSimCorpse in corpses.values():
		if c.echoOwner == "" and hyp(c.x - xx, c.z - zz) <= r:
			cand.append(c)
	var near: Array = DmStableSort.sorted(cand, func(a: DmSimCorpse, b: DmSimCorpse) -> bool: return hyp(a.x - xx, a.z - zz) < hyp(b.x - xx, b.z - zz))
	near = near.slice(0, int(T["corpses"]))
	if near.size() < int(T["minCorpses"]):
		emit({"t": "exhumed", "by": x["by"], "ok": false, "x": x["x"], "z": x["z"], "why": "few"})
		return
	var n := near.size()
	var sx := 0.0
	var sz := 0.0
	for c: DmSimCorpse in near:
		sx += c.x
		sz += c.z
	var cx := sx / n
	var cz := sz / n
	var empowered := false
	for c: DmSimCorpse in near:
		if c.kind == "resonant" or c.elite:
			empowered = true
	for c: DmSimCorpse in near:
		remove_corpse(c, "consumed", x["by"])
	for old: DmSimThrall in owned_thralls(x["by"]):
		if old.kind == "colossus":
			kill_thrall(old, "crumbled")
	var crumbled := _make_room(x["by"], float(x["cap"]), float(T["slots"]))
	var t := DmSimThrall.new()
	t.id = next_id()
	t.owner = x["by"]
	t.kind = "colossus"
	t.x = cx
	t.z = cz
	t.facing = near[0].facing
	var hp: float = float(x["hp"]) * float(T["hpPerCorpse"]) * n
	t.hp = hp
	t.maxHp = hp
	t.damage = float(x["damage"]) * float(T["damagePerCorpse"]) * n
	t.attackInterval = float(T["interval"]) / float(x["attackSpeedMult"])
	t.range = float(T["range"])
	t.speed = float(T["speed"])
	t.state = "rising"
	t.attackCd = 0.8
	t.slot = _next_free_slot(x["by"])
	t.bornAt = time
	t.empowered = empowered
	thralls[t.id] = t
	emit({"t": "thrall", "id": t.id, "owner": t.owner, "kind": "colossus", "x": t.x, "z": t.z, "empowered": empowered})
	var ev := {"t": "exhumed", "by": x["by"], "ok": true, "corpseKind": near[0].kind, "x": cx, "z": cz}
	if crumbled >= 0:
		ev["crumbled"] = crumbled
	emit(ev)


func _apply_litany(l: Dictionary) -> void:
	var dly: Variant = l.get("delayMs")
	var dv: float = float(dly) if ((dly is float or dly is int) and is_finite(float(dly))) else 0.0
	var delay := minf(float(DmSimData.RUNE_TUNING["requiem"]["delayMs"]), maxf(0.0, dv))
	if delay > 0.0:
		var l2 := l.duplicate()
		l2["delayMs"] = 0.0
		pendingLitanies.append({"at": time + delay / 1000.0, "l": l2})
		emit({"t": "requiem", "by": l["by"], "x": l["x"], "z": l["z"], "r": l["r"], "ms": delay})
		return
	var corpses_n := 0
	var resonant := 0
	var tethers: Array = []
	var p: DmSimPlayer = players.get(l["by"])
	var hall: String = p.area if p != null else ""
	var lx := float(l["x"])
	var lz := float(l["z"])
	var lr := float(l["r"])
	var spare := DmCombatData.truthy(l.get("spare"))
	for c: DmSimCorpse in corpses.values():
		if c.echoOwner != "" or (hall != "" and c.area != hall):
			continue
		if hyp(c.x - lx, c.z - lz) > lr:
			continue
		if c.kind == "resonant":
			resonant += 1
		else:
			corpses_n += 1
		tethers.append([c.x, c.z])
		remove_corpse(c, "litany", l["by"])
	var thr := 0
	for t: DmSimThrall in owned_thralls(l["by"]):
		if hyp(t.x - lx, t.z - lz) > lr:
			continue
		thr += 1
		tethers.append([t.x, t.z])
		if spare:
			continue
		kill_thrall(t, "sacrificed")
		if DmCombatData.truthy(l.get("leaveCorpses")):
			var ar := nav.area_at(t.x, t.z)
			add_corpse(t.x, t.z, "normal", "risen", false, t.facing, 1.0, ar if ar != "" else "graves")
	var mult := minf(DmSimData.LITANY_MAX_MULT, float(DmSimData.ABILITIES["black_litany"]["power"]) + DmSimData.LITANY_PER_CORPSE * corpses_n + DmSimData.LITANY_PER_RESONANT * resonant + DmSimData.LITANY_PER_THRALL * thr)
	var dmg := float(l["spellPower"]) * mult
	var targets := 0
	for e: DmSimEnemy in enemies.values():
		if e.state == "dead" or hyp(e.x - lx, e.z - lz) > lr + e.radius:
			continue
		damage_enemy(e, dmg, l["by"])
		targets += 1
	var bs := boss.state
	if bs.active and hyp(bs.x - lx, bs.z - lz) <= lr + DmSimConsts.BOSS_RADIUS:
		boss.damage(dmg, l["by"], 0.0)
		targets += 1
	var ev := {"t": "litanyResult", "by": l["by"], "x": l["x"], "z": l["z"], "r": l["r"], "corpses": corpses_n, "resonant": resonant, "thralls": 0 if spare else thr}
	if spare:
		ev["spared"] = thr
	ev["targets"] = targets
	ev["tethers"] = tethers
	emit(ev)
	if targets != 0:
		emit({"t": "dmg", "x": l["x"], "z": l["z"], "amount": DmMath.js_round(dmg), "kind": "litany", "by": l["by"]})


func tick_pending_litanies() -> void:
	if pendingLitanies.is_empty():
		return
	var due: Array = []
	var rest: Array = []
	for p: Dictionary in pendingLitanies:
		if time >= float(p["at"]):
			due.append(p)
		else:
			rest.append(p)
	if due.is_empty():
		return
	pendingLitanies = rest
	for p: Dictionary in due:
		_apply_litany(p["l"])


## Corpse Explosion. The host owns the blast radius and the corpse modifiers; the client only names the corpse and its own damage (clamped).
func _apply_detonate(d: Dictionary) -> void:
	var c: DmSimCorpse = corpses.get(int(d["corpseId"]))
	var p: DmSimPlayer = players.get(d["by"])
	var hall: String = p.area if p != null else ""
	if c == null or c.echoOwner != "" or (hall != "" and c.area != hall):
		emit({"t": "detonated", "by": d["by"], "ok": false, "corpseId": d["corpseId"], "x": 0.0, "z": 0.0, "r": 0.0})
		return
	var dd: Variant = d.get("dmg")
	var dv: float = float(dd) if ((dd is float or dd is int) and is_finite(float(dd))) else 0.0
	var base := minf(float(DmSimData.DETONATE["maxDamage"]), maxf(0.0, dv))
	var r := float(DmSimData.DETONATE["radius"]) * (float(DmSimData.DETONATE["resonantRadiusMult"]) if c.kind == "resonant" else 1.0)
	var dmg := base * (float(DmSimData.DETONATE["eliteDamageMult"]) if c.elite else 1.0)
	var targets := 0
	for e: DmSimEnemy in enemies.values():
		if e.state == "dead" or hyp(e.x - c.x, e.z - c.z) > r + e.radius:
			continue
		damage_enemy(e, dmg, d["by"])
		targets += 1
	var b := boss.state
	if b.active and hyp(b.x - c.x, b.z - c.z) <= r + DmSimConsts.BOSS_RADIUS:
		boss.damage(dmg, d["by"], 0.0)
		targets += 1
	emit({"t": "detonated", "by": d["by"], "ok": true, "corpseId": c.id, "x": c.x, "z": c.z, "r": r, "corpseKind": c.kind, "elite": c.elite, "targets": targets, "dmg": DmMath.js_round(dmg)})
	remove_corpse(c, "burst", d["by"])
	if c.kind == "toxic":
		var zone := DmSimZone.new()
		zone.id = next_id()
		zone.kind = "rot"
		zone.owner = d["by"]
		zone.x = c.x
		zone.z = c.z
		zone.r = float(DmSimData.DETONATE["rotRadius"]) * maxf(1.0, c.scale)
		zone.until = time + float(DmSimData.DETONATE["rotDurationMs"]) / 1000.0
		zone.bornAt = time
		zone.tick = 0.0
		zone.dps = base * float(DmSimData.DETONATE["rotDpsShare"])
		zone.slow = DmSimData.MIASMA_SLOW
		zone.witheredCap = float(DmSimData.DETONATE["rotWitheredCap"])
		zone.bloom = false
		zone.hostile = false
		zones[zone.id] = zone
		emit({"t": "zone", "zone": zone})


# --- Corpses / thralls ---

func add_corpse(x: float, z: float, kind: String, enemy: String, elite: bool, facing: float, scale: float, area: String) -> DmSimCorpse:
	if kind == "none":
		return null
	if corpses.size() >= DmSimConsts.MAX_CORPSES:
		var oldest: DmSimCorpse = null
		for c: DmSimCorpse in corpses.values():
			if oldest == null or c.bornAt < oldest.bornAt:
				oldest = c
		if oldest != null:
			remove_corpse(oldest, "expired")
	var c := DmSimCorpse.new()
	c.id = next_id()
	c.x = x
	c.z = z
	c.kind = kind
	c.enemy = enemy
	c.elite = elite
	c.facing = facing
	c.scale = scale
	c.area = area
	c.bornAt = time
	c.expiresAt = time + DmSimConsts.CORPSE_LIFETIME * corpseLifeMult * float(vowFx["corpseLifeMult"])
	c.ruptureAt = time + DmSimConsts.TOXIC_RUPTURE if kind == "toxic" else INF
	corpses[c.id] = c
	emit({"t": "corpse", "corpse": c})
	return c


func remove_corpse(c: DmSimCorpse, reason: String, by: String = "") -> void:
	if not corpses.erase(c.id):
		return
	bloomed.erase(c.id)
	var ev := {"t": "corpseGone", "id": c.id, "reason": reason}
	if by != "":
		ev["by"] = by
	emit(ev)


func kill_thrall(t: DmSimThrall, reason: String) -> void:
	if not thralls.erase(t.id):
		return
	t.state = "dead"
	emit({"t": "thrallGone", "id": t.id, "owner": t.owner, "x": t.x, "z": t.z, "reason": reason})
	if t.kind == "plaguebearer" and reason != "crumbled":
		_plague_burst(t)
	if reason == "killed":
		_death_burst(t)
	if reason == "killed":
		_try_unbind(t)


func _death_burst(t: DmSimThrall) -> void:
	var leg: Variant = legends.get(t.owner)
	var frac := float(leg["thrallDeathBurst"]) if leg != null else 0.0
	if frac <= 0.0:
		return
	var dmg := frac * t.maxHp
	var r := float(DmSimData.LEGEND["deathBurstR"])
	var hit := 0
	for e: DmSimEnemy in enemies.values():
		if e.state == "dead" or hyp(e.x - t.x, e.z - t.z) > r + e.radius:
			continue
		damage_enemy(e, dmg, t.owner)
		hit += 1
	var b := boss.state
	if b.active and hyp(b.x - t.x, b.z - t.z) <= r + DmSimConsts.BOSS_RADIUS:
		boss.damage(dmg, t.owner, 0.0)
		hit += 1
	emit({"t": "legend", "kind": "deathBurst", "by": t.owner, "x": t.x, "z": t.z, "r": r})
	if hit != 0:
		emit({"t": "dmg", "x": t.x, "z": t.z, "amount": DmMath.js_round(dmg), "kind": "burst", "by": t.owner})


## Lich Acolyte: the nearest ready acolyte in reach claims a fallen thrall; a Risen climbs out shortly after.
func _try_unbind(t: DmSimThrall) -> void:
	var U: Dictionary = DmSimData.UNBIND
	for e: DmSimEnemy in enemies.values():
		if not DmCombatData.truthy(DmSimData.ENEMIES[e.def].get("unbind")) or e.state == "dead" or e.state == "rising" or e.state == "burrow" or e.hp <= 0.0:
			continue
		if e.unbindCd > 0.0 or hyp(e.x - t.x, e.z - t.z) > float(U["range"]):
			continue
		var alive := 0
		for u: Dictionary in unbinds:
			if u["by"] == e.id:
				alive += 1
		for o: DmSimEnemy in enemies.values():
			if o.unboundBy == e.id and o.state != "dead":
				alive += 1
		if alive >= int(U["maxAlive"]):
			continue
		e.unbindCd = float(U["cooldownS"])
		unbinds.append({"at": time + float(U["delayS"]), "by": e.id, "x": t.x, "z": t.z, "area": e.area})
		emit({"t": "unbind", "id": e.id, "x": e.x, "z": e.z, "tx": t.x, "tz": t.z})
		return


## A fallen plague bearer ruptures: rot damage around it and a friendly withering pool.
func _plague_burst(t: DmSimThrall) -> void:
	var P: Dictionary = DmSimData.PLAGUE_BURST
	var dmg := t.damage * float(P["damageMult"])
	for e: DmSimEnemy in enemies.values():
		if e.state == "dead" or hyp(e.x - t.x, e.z - t.z) > float(P["radius"]) + e.radius:
			continue
		damage_enemy(e, dmg, t.owner)
	var b := boss.state
	if b.active and hyp(b.x - t.x, b.z - t.z) <= float(P["radius"]) + DmSimConsts.BOSS_RADIUS:
		boss.damage(dmg, t.owner, 0.0)
	emit({"t": "burst", "kind": "bloom", "x": t.x, "z": t.z, "r": P["radius"]})
	var zone := DmSimZone.new()
	zone.id = next_id()
	zone.kind = "rot"
	zone.owner = t.owner
	zone.x = t.x
	zone.z = t.z
	zone.r = float(P["poolRadius"])
	zone.until = time + float(P["poolMs"]) / 1000.0
	zone.bornAt = time
	zone.tick = 0.0
	zone.dps = t.damage * float(P["poolDpsShare"])
	zone.slow = DmSimData.MIASMA_SLOW
	zone.witheredCap = float(DmSimData.DETONATE["rotWitheredCap"])
	zone.bloom = false
	zone.hostile = false
	zones[zone.id] = zone
	emit({"t": "zone", "zone": zone})


## A Bog Hag's hex: the thrall deals less while it lasts.
func cursed_mult(t: DmSimThrall) -> float:
	return float(DmSimData.HAG_HEX["thrallDamageMult"]) if t.cursedT > 0.0 else 1.0


## What an enemy's blow is worth right now (Bone Hex softens it).
func blow(e: DmSimEnemy) -> float:
	return e.damage * (float(DmSimData.BONE_HEX["damageMult"]) if e.hexT > 0.0 else 1.0)


func hurt_thrall(t: DmSimThrall, dmg: float) -> void:
	t.hp -= dmg
	t.flash = 1.0
	if t.hp <= 0.0:
		kill_thrall(t, "killed")


# --- Walls / brands ---

func update_walls() -> void:
	for w: Dictionary in walls.values():
		if time < float(w["until"]):
			continue
		walls.erase(w["id"])
		emit({"t": "wallGone", "id": w["id"]})
	_tick_brands()


## Grave Brands: expire quietly, or root the first body that walks onto one.
func _tick_brands() -> void:
	for id in brands.keys():
		var b: Dictionary = brands[id]
		if time >= float(b["until"]):
			brands.erase(id)
			continue
		for e: DmSimEnemy in enemies.values():
			if e.state == "dead" or e.state == "rising" or e.state == "burrow" or e.area != b["area"]:
				continue
			if hyp(e.x - float(b["x"]), e.z - float(b["z"])) > float(DmSimData.GRAVE_BRAND["triggerR"]) + e.radius:
				continue
			e.rootT = maxf(e.rootT, float(DmSimData.GRAVE_BRAND["rootS"]))
			brands.erase(id)
			emit({"t": "brand", "by": b["owner"], "ok": true, "sprung": true, "x": b["x"], "z": b["z"]})
			break


## Proper segment intersection (touching endpoints don't count).
static func segments_cross(ax: float, az: float, bx: float, bz: float, cx: float, cz: float, dx: float, dz: float) -> bool:
	var d1 := (dx - cx) * (az - cz) - (dz - cz) * (ax - cx)
	var d2 := (dx - cx) * (bz - cz) - (dz - cz) * (bx - cx)
	var d3 := (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
	var d4 := (bx - ax) * (dz - az) - (bz - az) * (dx - ax)
	return d1 * d2 < 0.0 and d3 * d4 < 0.0


## Does the segment a->b cross a standing wall (or a tall dungeon wall)?
func wall_between(ax: float, az: float, bx: float, bz: float) -> bool:
	for w: Dictionary in walls.values():
		if segments_cross(ax, az, bx, bz, float(w["x0"]), float(w["z0"]), float(w["x1"]), float(w["z1"])):
			return true
	return nav.sight_blocked(ax, az, bx, bz)


## Keep a mover on the side of every wall it started on. Returns [x, z].
func push_off_walls(px: float, pz: float, x: float, z: float, radius: float) -> Array:
	var half := float(DmSimData.SIGNATURE["wall"]["thickness"]) / 2.0 + radius
	for w: Dictionary in walls.values():
		var wx := float(w["x1"]) - float(w["x0"])
		var wz := float(w["z1"]) - float(w["z0"])
		var len2 := wx * wx + wz * wz
		var t := maxf(0.0, minf(1.0, ((x - float(w["x0"])) * wx + (z - float(w["z0"])) * wz) / len2))
		var cx := float(w["x0"]) + wx * t
		var cz := float(w["z0"]) + wz * t
		var d := hyp(x - cx, z - cz)
		var crossed := segments_cross(px, pz, x, z, float(w["x0"]), float(w["z0"]), float(w["x1"]), float(w["z1"]))
		if d >= half and not crossed:
			continue
		var ln := sqrt(len2)
		var nx := -wz / ln
		var nz := wx / ln
		if (px - cx) * nx + (pz - cz) * nz < 0.0:
			nx = -nx
			nz = -nz
		x = cx + nx * half
		z = cz + nz * half
	return [x, z]


# --- Spawning ---

func party_hp_scale() -> float:
	var n := maxf(1.0, float(players.size()))
	return 1.0 + 0.5 * (n - 1.0)


func alive_in(area: String) -> int:
	var n := 0
	for e: DmSimEnemy in enemies.values():
		if e.area == area and e.state != "dead":
			n += 1
	return n


## Wave Speed builds over the first RAMP_S seconds of a visit.
func ramp_tier(area: String) -> float:
	var since: float = INF if not arrivedAt.has(area) else time - float(arrivedAt[area])
	return DmEnemyStats.ramp_tier(waveTier, since)


## `affix` forces an elite affix (tests / debug); otherwise elites roll one.
func spawn_enemy(def: String, area: String, x: float, z: float, elite: bool, rising: bool = true, affix: String = "") -> DmSimEnemy:
	var d: Dictionary = DmSimData.ENEMIES[def]
	var level := area_level(area)
	var wave := DmWaveUpgrades.wave_modifiers(ramp_tier(area))
	var diff := DmContent.difficulty(difficulty)
	var hp := float(d["hp"]) * DmEnemyStats.hp_scale(level) * float(wave["enemyHpMult"]) * float(diff["enemyHpMult"]) * float(vowFx["enemyHpMult"]) * (float(DmSimData.ELITE["hpMult"]) if elite else 1.0) * party_hp_scale()
	var e := DmSimEnemy.new()
	e.id = next_id()
	e.def = def
	e.area = area
	e.level = level
	e.elite = elite
	e.x = x
	e.z = z
	e.facing = rand() * PI * 2.0
	e.hp = hp
	e.maxHp = hp
	e.damage = float(d["damage"]) * DmEnemyStats.damage_scale(level) * float(wave["enemyDamageMult"]) * float(diff["enemyDamageMult"]) * (float(DmSimData.ELITE["damageMult"]) if elite else 1.0)
	e.speed = float(d["speed"]) * (0.92 + rand() * 0.16)
	e.radius = float(d["radius"]) * (1.25 if elite else 1.0)
	e.scale = float(d["scale"]) * (float(DmSimData.ELITE["scale"]) if elite else 1.0)
	e.state = ("burrow" if DmCombatData.truthy(d.get("burrow")) else "rising") if rising else "move"
	e.stateT = 0.0
	e.attackCd = 0.5 + rand()
	e.aimX = x
	e.aimZ = z
	e.flankSide = -1.0 if rand() < 0.5 else 1.0
	e.gait = rand() * 10.0
	if elite:
		if affix != "":
			e.affix = affix
		else:
			e.affix = DmSimData.AFFIX_ORDER[int(floorf(rand() * DmSimData.AFFIX_ORDER.size()))]
	if elite and area == "depths" and depths != null:
		var more := DmSimDepthsRules.pick_extra_affixes(float(depths["depth"]), e.affix, Callable(self, "rand"))
		if not more.is_empty():
			for a in more:
				e.extra.append({"affix": a, "affixCd": null, "tollAt": null})
	elif affix != "":
		e.affix = affix
	enemies[e.id] = e
	var ev := {"t": "spawn", "id": e.id, "def": def, "x": x, "z": z, "elite": elite}
	if e.affix != "":
		ev["affix"] = e.affix
	emit(ev)
	return e


## A hostile burning pool (Pyre Priest coals, a Husk's last embers, a Slag Brute's slam).
func ember_pool(x: float, z: float, r: float, seconds: float, dps: float) -> DmSimZone:
	var zone := DmSimZone.new()
	zone.id = next_id()
	zone.kind = "ember"
	zone.owner = ""
	zone.x = x
	zone.z = z
	zone.r = r
	zone.until = time + seconds
	zone.bornAt = time
	zone.tick = 1.0
	zone.dps = dps
	zone.slow = 1.0
	zone.hostile = true
	zones[zone.id] = zone
	emit({"t": "zone", "zone": zone})
	return zone


func add_zone(o: Dictionary) -> DmSimZone:
	var zone := DmSimZone.new()
	zone.id = next_id()
	zone.kind = o["kind"]
	zone.owner = o["owner"]
	zone.x = float(o["x"])
	zone.z = float(o["z"])
	zone.r = float(o["r"])
	zone.until = time + float(o["durationS"])
	zone.bornAt = time
	zone.tick = 0.0
	zone.dps = float(o["dps"])
	zone.slow = DmSimData.MIASMA_SLOW
	zone.witheredCap = float(o["witheredCap"])
	zone.bloom = false
	zone.hostile = false
	if o["kind"] == "flower":
		zone.gen = int(o.get("gen", 0))
		zone.spreadT = float(DmSimData.SIGNATURE["bloom"]["spreadEveryS"])
	elif o.has("gen"):
		zone.gen = int(o["gen"])
	zones[zone.id] = zone
	emit({"t": "zone", "zone": zone})
	return zone


func nearest_corpse(x: float, z: float, r: float) -> DmSimCorpse:
	var best: DmSimCorpse = null
	var best_d := r
	for c: DmSimCorpse in corpses.values():
		var d := hyp(c.x - x, c.z - z)
		if d < best_d:
			best_d = d
			best = c
	return best


## Treat an area as already visited (host migration: no opening wave).
func mark_visited(area: String) -> void:
	if not waveTimers.has(area):
		waveTimers[area] = (float(DmSimData.AREAS[area]["waveIntervalMs"]) / 1000.0) * float(DmWaveUpgrades.wave_modifiers(waveTier)["intervalMult"])


## Development helper: clear an area and reset its wave timer.
func clear_area(area: String) -> void:
	for e: DmSimEnemy in enemies.values():
		if e.area == area:
			enemies.erase(e.id)
	waveTimers.erase(area)
	if surge != null and surge["area"] == area:
		emit({"t": "surgeFailed", "area": area, "x": surge["x"], "z": surge["z"]})
		DmSimDirector.end_surge(self)


func arena_center() -> Dictionary:
	return DmSimData.BOSSES[bossId]["arena"]


# --- Step ---

## Advance the world by dt seconds; returns the events produced (also available via drain()).
func step(dt: float) -> Array:
	time += dt
	DmSimDirector.update_waves(self, dt)
	DmSimDirector.update_depths(self, dt)
	DmSimDirector.update_surge(self, dt)
	tick_pending_litanies()
	DmSimZones.update_zones(self, dt)
	if anyPlague:
		DmSimZones.update_plague(self)
	update_walls()
	DmSimEnemyAI.update_enemies(self, dt)
	DmSimThrallAI.update_thralls(self, dt)
	DmSimThrallAI.separate(self)
	boss.update(dt)
	DmSimZones.update_corpses(self)
	DmSimDirector.update_nodes(self)
	DmSimZones.collect_dead(self)
	_prune_dot_accum()
	return drain()


## Enemies that leave without dying used to leave their damage-number accumulator behind for good.
func _prune_dot_accum() -> void:
	if time < dotPruneAt:
		return
	dotPruneAt = time + 5.0
	for id in dotAccum.keys():
		if not enemies.has(id):
			dotAccum.erase(id)
