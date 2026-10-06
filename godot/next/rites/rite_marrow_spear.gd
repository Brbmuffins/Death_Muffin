extends DmRiteModule
## Marrow Spear (default loadout slot 1): a line of bone erupts toward the cursor (direction skillshot, 48 m/s bolt, range 12, half-width 0.9 + 0.2 + the
## enemy's radius, 18 essence, 2.2 s, power 2.1), piercing everything on the line, +1 Fracture each and a Hemorrhage bleed. Runes: Ossuary Ring (the cursor,
## pulled back to 12 m, erupts a r 3 ring for x0.8), Impaling (stops at the first enemy: x1.5, roots it 1.5 s). The legendary `spearRally` mod marks the
## nearest enemy hit: the legion turns on it and hits it harder for LEGEND.rallyS. Numbers: DmAbilities.spear + DmRunes; visuals: DmRiteFx.spear_*.
## Soul Harvest: a charged cast arrives with intent["mult"] 1.5 (longer, wider line; the caster spent souls, not essence).

const SPEED := 48.0
const Y := 0.3
const FRACTURE_STACKS := 1


func _init() -> void:
	id = "marrow_spear"
	steps = true


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var aim: Vector3 = intent["aim"]
	if Vector2(aim.x - float(c.p["x"]), aim.z - float(c.p["z"])).length() < 1e-4:
		return "no_target"   # a direction needs somewhere to point
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var aim: Vector3 = intent["aim"]
	var origin := c.pos()
	var sp := DmAbilities.spear(DmAbilities.sp(c.p, c.now_ms), DmAbilities.rune(c.p, id), float(intent.get("mult", 1.0)))
	var ring: Variant = sp["ring"]
	var centre: Variant = DmRunes.ring_center({"x": origin.x, "z": origin.z}, {"x": aim.x, "z": aim.z}, float(ring["maxCastRange"])) if ring != null else null
	var dx: float = (float(centre["x"]) if centre != null else aim.x) - origin.x
	var dz: float = (float(centre["z"]) if centre != null else aim.z) - origin.z
	var l := Vector2(dx, dz).length()
	if l == 0.0:
		l = 1.0
	dx /= l
	dz /= l
	var rng_m: float = sp["range"]
	var end := Vector3(float(centre["x"]), Y, float(centre["z"])) if centre != null else Vector3(origin.x + dx * rng_m, Y, origin.z + dz * rng_m)
	var tip := c.tip()
	var rn := DmAbilities.rune(c.p, id)
	c.after(tip.distance_to(end) / SPEED * 1000.0, func() -> void: _arrive(c, rn, sp, origin, dx, dz, centre, end))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": tip, "to": end, "speed": SPEED})
	return ""


func _arrive(c: DmRiteCaster, rn: String, sp: Dictionary, origin: Vector3, dx: float, dz: float, centre: Variant, end: Vector3) -> void:
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var rng_m: float = sp["range"]
	var half_w := float(sp["radius"]) + 0.2
	var hits: Array = []   # [Node3D]
	var ev := {"t": "line", "rite": id, "by": c.peer_id}
	var dmg: float = sp["dmg"]
	var root_s := 0.0
	if centre != null:
		var r := float(sp["ring"]["radius"])
		dmg = float(sp["ring"]["dmg"])
		var foes: Array = []
		for n in c.world.enemies_in_radius(Vector3(float(centre["x"]), 0.0, float(centre["z"])), r + 3.0):
			if DmRiteCaster.alive_enemy(n):
				foes.append({"id": 0, "x": n.global_position.x, "z": n.global_position.z, "radius": float(n.get("radius")), "e": n})
		for f: Dictionary in DmRunes.ring_hits(centre, r, foes):
			hits.append(f["e"])
		ev.merge({"t": "ring", "cx": float(centre["x"]), "cz": float(centre["z"]), "r": r}, true)
	elif rn == "rune_impale":
		dmg = float(sp["impaleDmg"])
		root_s = float(RT["impale"]["rootS"])
		var foes: Array = []
		for n in c.world.enemies_in_radius(Vector3(origin.x, 0.0, origin.z), rng_m + 3.0):
			if DmRiteCaster.alive_enemy(n):
				foes.append({"id": 0, "x": n.global_position.x, "z": n.global_position.z, "radius": float(n.get("radius")), "e": n})
		var found: Variant = DmRunes.impale_target({"x": origin.x, "z": origin.z}, dx, dz, rng_m, half_w, foes)
		var fe: Node3D = found["foe"]["e"] if found != null else null
		if fe != null:
			hits.append(fe)
		ev.merge({"t": "impale", "ox": origin.x, "oz": origin.z, "dx": dx, "dz": dz, "rng": rng_m, "hit": fe != null, "root_s": root_s,
			"tx": fe.global_position.x if fe != null else 0.0, "tz": fe.global_position.z if fe != null else 0.0, "along": float(found["along"]) if found != null else 0.0}, true)
	else:
		for row: Dictionary in lane(c, origin.x, origin.z, dx, dz, rng_m, half_w, false):
			hits.append(row["e"])
		ev.merge({"ox": origin.x, "oz": origin.z, "dx": dx, "dz": dz, "rng": rng_m, "radius": float(sp["radius"]), "mult": rng_m / float(DmAbilities.def(id)["range"]), "end": end}, true)
	var struck: Array = []
	var pos: Array = []
	for e: Node3D in hits:
		if not DmStatusSet.hit(e, dmg, c.body):
			continue
		var ss := DmStatusSet.ensure(e)
		c.watch_dots(ss)
		ss.apply(&"fracture", c.body, FRACTURE_STACKS)
		var H: Dictionary = DmSimData.HEMORRHAGE
		ss.apply(&"bleed", c.body, 1, -1.0, {"dps": minf(dmg * float(H["dpsFrac"]), dmg * float(H["maxFrac"]))})
		if root_s > 0.0:
			ss.apply(&"root", c.body, 1, root_s)
		struck.append(e)
		pos.append(Vector3(e.global_position.x, 0.8, e.global_position.z))
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
	_rally(c, struck)
	ev["hits"] = pos
	ev["amount"] = dmg
	c.broadcast(ev)


## Legion Champion 5 (`spearRally`): the nearest enemy hit is marked; the legion turns on it and hits it harder until the mark runs out. Host.
func _rally(c: DmRiteCaster, struck: Array) -> void:
	var bonus := float(c.mods.get("spearRally", 0.0))
	if bonus <= 0.0 or struck.is_empty():
		return
	var best: Node3D = null
	var best_d := INF
	for e: Node3D in struck:
		var d := Vector2(e.global_position.x - float(c.p["x"]), e.global_position.z - float(c.p["z"])).length()
		if d < best_d:
			best_d = d
			best = e
	var m := c.mem(id)
	m["mark"] = best
	m["bonus"] = bonus
	m["until"] = c.now_ms + float(DmSimData.LEGEND["rallyS"]) * 1000.0
	var thr := c.thralls()
	if thr != null:
		for t in thr.list():
			if t.state != DmThrall.S.RISING and t.state != DmThrall.S.DEAD:
				t.target = best


## The mark's bookkeeping: `mark_mult` on each thrall is the bonus only while it fights the marked enemy; gone with the mark.
func step(c: DmRiteCaster, _dt: float) -> void:
	var m := c.mem(id)
	if not m.has("mark"):
		return
	var mark: Variant = m["mark"]
	var live: bool = is_instance_valid(mark) and DmRiteCaster.alive_enemy(mark) and c.now_ms < float(m["until"])
	var thr := c.thralls()
	if thr != null:
		for t in thr.list():
			t.mark_mult = 1.0 + float(m["bonus"]) if (live and t.target == mark) else 1.0
	if not live:
		m.erase("mark")


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			var from: Vector3 = ev["from"]
			var to: Vector3 = ev["to"]
			c.fx.spear_cast(from, to)
			c.fx.shot(from, to, float(ev["speed"]), 0.0, "needle", DmFxData.spell("spear", "bone"))
			return
		"line":
			c.shake_requested.emit(c.fx.spear_line(ev))
		"ring":
			c.shake_requested.emit(c.fx.spear_ring(ev))
		"impale":
			c.shake_requested.emit(c.fx.spear_impale(ev))
	for h: Vector3 in ev["hits"]:
		c.hit_number.emit(h, float(ev["amount"]), false)
