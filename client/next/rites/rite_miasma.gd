extends DmRiteModule
## Miasma Circle: ground-targeted, 25 essence, 7 s, radius 3.8 x mods, a 6 s Withered cloud (+1 stack per second, slow 0.6). Numbers:
## DmAbilities.miasma + DmSimData (WITHERED, MIASMA_SLOW); visuals: DmRiteFx.miasma_land (shared with the original game).
## Runes: Creeping Rot (radius x0.85, the circle drifts 1.5 m/s toward the nearest enemy within 12 m, inside its area) and Contagion (a withered enemy of the
## circle that dies hands its stacks - 1 to its 2 nearest neighbours within 4.5 m). Legendary Plague Choir (`c.legend`): `miasmaSpreadsWithered` (a withered
## enemy that dies inside the circle spreads its stacks to the 3 nearest within 4 m) and `witheredBurstAt` (Chain Plague: an enemy reaching N stacks loses
## them and a fresh circle opens on it, at most 4 at once, 1 s apart per enemy). All of it is host state in `mem("miasma")`; the death hook is `withered_death`.
## On the combat core: the enemies are DmFoe snapshots from the core's radius query, Withered and the slow are the core's statuses (the hero is their
## source, so his kills and DoT lumps are his), the Shrouded ward is lifted through `core.cover_miasma`, and what the enemy nodes carried as meta (contagious, the Chain Plague gap)
## is kept by enemy id in `mem("miasma")`. The death hook runs from the core's event buffer: at the end of the tick that killed the enemy, not inside the kill.

const SPEED := 18.0        ## sim_caster._miasma projectile
const TARGET_Y := 0.2
const ARC := 12.0
const SLOW_HOLD_S := 0.3   ## the cloud keeps its slow on for this long after the last scan an enemy stood in it
const SCAN_S := 0.1        ## a cloud looks for enemies 10x/s (not every frame); the hold above covers the gap
const MOVE_EV_S := 0.4     ## a creeping cloud tells the other peers where it is this often
const FX_EV_S := 0.5       ## legend / contagion threads: at most FX_EV_MAX per window (a crowd dying in a cloud is one picture, not fifty)
const FX_EV_MAX := 4
const MARKS_MAX := 64      ## the per-enemy marks are swept for gone enemies when they pass this many


func _init() -> void:
	id = "miasma"
	steps = true


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var aim: Vector3 = intent["aim"]
	var rn := DmAbilities.rune(c.p, id)
	var m := DmAbilities.miasma(DmAbilities.sp(c.p, c.now_ms), c.mods, rn, float(intent.get("mult", 1.0)), {"x": c.p["x"], "z": c.p["z"]}, {"x": aim.x, "z": aim.z})
	m["creep"] = float(DmSimData.RUNE_TUNING["creepingRot"]["speed"]) if rn == "rune_creeping_rot" else 0.0
	m["contagion"] = rn == "rune_contagion"
	if float(c.legend.get("witheredBurstAt", 0.0)) > 0.0:
		c.mem(id)["last"] = m   # Chain Plague opens its circles like the last one cast (sim lastMiasma)
	var to := Vector3(m["x"], TARGET_Y, m["z"])
	var tip := c.tip()
	c.after(tip.distance_to(to) / SPEED * 1000.0, func() -> void: _land(c, m))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": tip, "to": to, "speed": SPEED, "arc": ARC})
	return ""


## A friendly Withered cloud (also what a toxic Corpse Explosion and a fallen plague bearer leave: sim kind "rot", same rules). Host.
func add_zone(c: DmRiteCaster, x: float, z: float, r: float, dps: float, duration_ms: float, cap: float, kind: String = "miasma") -> Dictionary:
	var mm := c.mem(id)
	var zones: Array = mm.get_or_add("zones", [])
	var zid := int(mm.get("zid", 0)) + 1
	mm["zid"] = zid
	var zone := {"zid": zid, "x": x, "z": z, "r": r, "dps": dps, "until": c.now_ms + duration_ms, "tick": 0.0, "scan": 0.0, "cap": cap, "creep": 0.0, "contagion": false, "plague": false,
		"acc": 0.0, "mv": 0.0, "kind": kind}
	zones.append(zone)
	return zone


## Host: the rot pool a fallen plague bearer of this caster's legion leaves (the core's `thrall_plague_pool`, told by DmLegionEvents): a friendly rot cloud by the rules of
## the toxic Corpse Explosion's (kind "rot", the rot's Withered cap), `r` wide for `seconds`, its `dps` the bearer's damage x PLAGUE_BURST.poolDpsShare. Every peer draws it.
func plague_pool(c: DmRiteCaster, x: float, z: float, r: float, dps: float, seconds: float) -> void:
	add_zone(c, x, z, r, dps, seconds * 1000.0, float(DmSimData.DETONATE["rotWitheredCap"]), "rot")
	c.broadcast({"t": "pool", "rite": id, "by": c.peer_id, "x": x, "z": z, "r": r, "life": seconds})


func _land(c: DmRiteCaster, m: Dictionary) -> void:
	var z := add_zone(c, float(m["x"]), float(m["z"]), float(m["r"]), float(m["dps"]), float(m["durationMs"]), float(m["witheredCap"]))
	z["creep"] = float(m.get("creep", 0.0))
	z["contagion"] = bool(m.get("contagion", false))
	c.broadcast({"t": "land", "rite": id, "by": c.peer_id, "x": float(m["x"]), "z": float(m["z"]), "r": float(m["r"]), "zid": int(z["zid"]), "creep": float(z["creep"]),
		"contagion": bool(z["contagion"]), "life": float(m["durationMs"])})


## The cloud, sim_zones.update_zones for a friendly miasma: every 1 s pulse each enemy inside gets +1 Withered stack (capped) and the
## strongest dps; enemies inside are slowed (MIASMA_SLOW) while they stand in it.
func step(c: DmRiteCaster, dt: float) -> void:
	var zones: Array = c.mem(id).get("zones", [])
	var burst_at := float(c.legend.get("witheredBurstAt", 0.0))
	var i := 0
	while i < zones.size():
		var z: Dictionary = zones[i]
		if c.now_ms >= float(z["until"]):
			zones.remove_at(i)
			continue
		i += 1
		z["acc"] = float(z["acc"]) + dt
		z["tick"] = float(z["tick"]) - dt
		var pulse: bool = z["tick"] <= 0.0
		if pulse:
			z["tick"] = 1.0
		z["scan"] = float(z["scan"]) - dt
		if z["scan"] > 0.0 and not pulse:
			continue
		z["scan"] = SCAN_S
		var adt := float(z["acc"])
		z["acc"] = 0.0
		var creep := float(z["creep"])
		var r := float(z["r"])
		var best_d := float(DmSimData.RUNE_TUNING["creepingRot"]["seekReach"])
		var best: DmFoe = null
		for e in c.foes_in_radius(Vector3(z["x"], 0.0, z["z"]), maxf(r + 2.0, best_d) if creep > 0.0 else r + 2.0):
			var d := Vector2(e.x - float(z["x"]), e.z - float(z["z"])).length()
			if creep > 0.0 and d < best_d:
				best_d = d
				best = e
			if d > r + e.radius:
				continue
			c.apply_status(e.id, &"slow", 1, SLOW_HOLD_S)
			c.host().core.cover_miasma(e.id)   # lifts the Shrouded affix's ward while it stands in the cloud (the core ignores a body without one)
			if pulse:
				c.apply_status(e.id, &"withered", 1, -1.0, {"dps": float(z["dps"]), "cap": float(z["cap"])})
				if z["contagion"]:
					_marks(c, "contagious")[e.id] = true
				if burst_at > 0.0 and c.status_stacks(e.id, &"withered") >= int(burst_at):
					_plague(c, e, burst_at)
		if best != null:
			_creep(c, z, best, best_d, creep * adt)


## Creeping Rot: the circle walks `step_m` toward the nearest enemy (not onto it, not out of its area); the others hear where it is 2.5x a second.
func _creep(c: DmRiteCaster, z: Dictionary, best: DmFoe, best_d: float, step_m: float) -> void:
	if best_d < 0.6:
		return
	var step := minf(step_m, best_d)
	var nx := float(z["x"]) + (best.x - float(z["x"])) / best_d * step
	var nz := float(z["z"]) + (best.z - float(z["z"])) / best_d * step
	if c.world.has_method("area_at"):
		var a := String(c.world.area_at(float(z["x"]), float(z["z"])))
		if a != "" and String(c.world.area_at(nx, nz)) != a:
			return
	z["x"] = nx
	z["z"] = nz
	if c.now_ms >= float(z["mv"]):
		z["mv"] = c.now_ms + MOVE_EV_S * 1000.0
		c.broadcast({"t": "move", "rite": id, "by": c.peer_id, "zid": int(z["zid"]), "x": nx, "z": nz})


## Plague Choir 5 (Chain Plague): `e` reached the owner's `witheredBurstAt` stacks. They go and a fresh circle opens on it, like the last one cast.
func _plague(c: DmRiteCaster, e: DmFoe, at: float) -> void:
	var gap := _marks(c, "plague_at")
	if c.now_ms < float(gap.get(e.id, 0.0)):
		return
	var L: Dictionary = DmSimData.LEGEND
	var zones: Array = c.mem(id).get("zones", [])
	var open := 0
	for z: Dictionary in zones:
		if z["plague"]:
			open += 1
	if open >= int(L["burstClouds"]):
		return
	var last: Dictionary = c.mem(id).get("last", {})
	var def := DmAbilities.def(id)
	var r: float = float(last["r"]) if last.has("r") else float(def["radius"])
	var dps: float = float(last["dps"]) if last.has("dps") else DmAbilities.sp(c.p, c.now_ms) * float(def["power"])
	var dur: float = float(last["durationMs"]) if last.has("durationMs") else 6000.0
	var cap := maxf(float(last["witheredCap"]) if last.has("witheredCap") else 5.0, at)
	gap[e.id] = c.now_ms + float(L["burstCdS"]) * 1000.0
	c.remove_status(e.id, &"withered")
	var z := add_zone(c, e.x, e.z, r, dps, dur, cap)
	z["plague"] = true
	c.broadcast({"t": "land", "rite": id, "by": c.peer_id, "x": e.x, "z": e.z, "r": r, "zid": int(z["zid"]), "creep": 0.0, "contagion": false, "life": dur})
	_fx_event(c, {"t": "legend", "rite": id, "by": c.peer_id, "kind": "plague", "x": e.x, "z": e.z, "r": r})


## The per-enemy marks the nodes carried as meta ("contagious", "plague_at"), by enemy id; ids of enemies that are gone are dropped once the table grows.
func _marks(c: DmRiteCaster, kind: String) -> Dictionary:
	var m := c.mem(id)
	var marks: Dictionary = m.get_or_add(kind, {})
	if marks.size() > MARKS_MAX:
		for k in marks.keys():
			if c.host().foe(int(k)) == null:   # gone from the core's table (a dead body stays 4 s, long enough for its death to be handled)
				marks.erase(k)
	return marks


## HOST, from the caster: an enemy this caster withered died with `stacks` on it (its status set has not cleared yet). Plague Choir 1 hands them to the
## nearest enemies when it died inside a circle of the caster's; the Contagion rune hands stacks - 1 on when a Contagion circle withered it.
func withered_death(c: DmRiteCaster, stacks: float, dps: float, target_id: int) -> void:
	var e := c.host().foe(target_id) if c.world != null else null   # the dead body is still in the core's table: its place, radius and area are known
	if e == null:
		return
	if float(c.legend.get("miasmaSpreadsWithered", 0.0)) > 0.0:
		var cap := 0.0
		for z: Dictionary in c.mem(id).get("zones", []):
			if z["kind"] == "miasma" and Vector2(e.x - float(z["x"]), e.z - float(z["z"])).length() <= float(z["r"]) + e.radius:
				cap = maxf(cap, float(z["cap"]))
		if cap > 0.0:
			var L: Dictionary = DmSimData.LEGEND
			var near := _nearest(c, e, float(L["spreadR"]), int(L["spreadMax"]))
			for o in near:
				c.apply_status(o.id, &"withered", int(stacks), -1.0, {"dps": dps, "cap": cap})
			if not near.is_empty():
				_fx_event(c, {"t": "legend", "rite": id, "by": c.peer_id, "kind": "spread", "x": e.x, "z": e.z, "r": float(L["spreadR"])})
	var C: Dictionary = DmSimData.RUNE_TUNING["contagion"]
	var contagious := _marks(c, "contagious")
	if contagious.has(e.id) and stacks >= float(C["minStacks"]):
		var carry := stacks - 1.0
		for o in _nearest(c, e, float(C["reach"]), int(C["neighbours"])):
			c.apply_status(o.id, &"withered", maxi(0, int(carry) - c.status_stacks(o.id, &"withered")), -1.0, {"dps": dps})
			contagious[o.id] = true
			_fx_event(c, {"t": "contagion", "rite": id, "by": c.peer_id, "x": e.x, "z": e.z, "tx": o.x, "tz": o.z})
	contagious.erase(e.id)


## The `n` living enemies nearest to `e` (centre to centre within `reach`, same area), nearest first. No sort, no allocation beyond the result.
func _nearest(c: DmRiteCaster, e: DmFoe, reach: float, n: int) -> Array[DmFoe]:
	var out: Array[DmFoe] = []
	var ds: Array = []
	for f in c.foes_in_radius(e.pos(), reach):
		if f.id == e.id or f.area != e.area:
			continue
		var d := Vector2(f.x - e.x, f.z - e.z).length()
		if d > reach:
			continue
		var k := out.size()
		while k > 0 and float(ds[k - 1]) > d:
			k -= 1
		if k < n:
			out.insert(k, f)
			ds.insert(k, d)
			if out.size() > n:
				out.pop_back()
				ds.pop_back()
	return out


## A legend / contagion picture: at most FX_EV_MAX per FX_EV_S (a crowd dying in a cloud is one picture, not fifty).
func _fx_event(c: DmRiteCaster, ev: Dictionary) -> void:
	var m := c.mem(id)
	if c.now_ms >= float(m.get("fx_until", 0.0)):
		m["fx_until"] = c.now_ms + FX_EV_S * 1000.0
		m["fx_n"] = 0
	m["fx_n"] = int(m.get("fx_n", 0)) + 1
	if int(m["fx_n"]) <= FX_EV_MAX:
		c.broadcast(ev)


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			c.fx.shot(ev["from"], ev["to"], float(ev["speed"]), float(ev["arc"]), "orb", DmFxData.spell("miasma", "rot"))
		"land":
			var creep := float(ev.get("creep", 0.0))
			var follow := Callable()
			if creep > 0.0:
				var vis: Dictionary = c.mem(id).get_or_add("vis", {})   # per peer: the creeping circles this peer is drawing
				var now := Time.get_ticks_msec()
				for k in vis.keys():
					if now >= int(vis[k]["until"]):
						vis.erase(k)
				var v := {"pos": Vector2(float(ev["x"]), float(ev["z"])), "target": Vector2(float(ev["x"]), float(ev["z"])), "last": now, "until": now + int(float(ev["life"])), "speed": creep}
				vis[int(ev["zid"])] = v
				follow = func() -> Variant: return _follow(v)
			c.fx.miasma_land(float(ev["x"]), float(ev["z"]), float(ev["r"]), creep > 0.0, follow, bool(ev.get("contagion", false)))
		"pool":
			c.fx.rot_pool(float(ev["x"]), float(ev["z"]), float(ev["r"]), float(ev["life"]))
		"move":
			var vs: Dictionary = c.mem(id).get("vis", {})
			if vs.has(int(ev["zid"])):
				vs[int(ev["zid"])]["target"] = Vector2(float(ev["x"]), float(ev["z"]))
		"legend":
			c.fx.legend_burst(String(ev["kind"]), float(ev["x"]), float(ev["z"]), float(ev["r"]))
		"contagion":
			c.fx.contagion_thread(float(ev["x"]), float(ev["z"]), float(ev["tx"]), float(ev["tz"]))


## A creeping circle's ground point: eases toward the host's last position at its own speed; null once it is over.
func _follow(v: Dictionary) -> Variant:
	var now := Time.get_ticks_msec()
	if now >= int(v["until"]):
		return null
	if now != int(v["last"]):
		var p: Vector2 = v["pos"]
		v["pos"] = p.move_toward(v["target"], float(v["speed"]) * float(now - int(v["last"])) / 1000.0)
		v["last"] = now
	var q: Vector2 = v["pos"]
	return Vector3(q.x, 0.0, q.y)
