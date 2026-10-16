extends DmRiteModule
## Unleash Souls (the Reaper, R): needs 1 soul and lets the whole bag go at once (up to 30), 8 s. The wisps burst outward in an even 360 degree ring and fly
## straight for OUT_T seconds; only then does each hunt a target (the nearest to it, but enemies already chosen count as farther, so the wisps spread
## out instead of overkilling one weak mob) and strike it once for power 0.45 (spell power read before the bag is emptied, so a full bag also hits harder). With nothing to hunt the wisps circle her until an enemy
## comes within reach (no time limit; they go when she dies). Host: `mem(id).wisps` ({a, x, z, eid, dmg}), looked after in `step`; every peer draws the wisps
## from the events: `release` (the burst and the circling wisps), `sync` (wisps that found a target fly off, the circle shrinks or grows), `hit`, `end`.
## Soul Harbinger's Raiment (DmReaperSet): 4 pieces turn the damage the wisps do into her barrier (`mem.shield` is what a cast gave; the next release takes it
## back first, so it refreshes instead of stacking); 5 pieces leave a Scythe Throw where each wisp lands (at most `soulScythes` at once).
## On the combat core (client/code.list "Ported"): a wisp's prey is a DmFoe snapshot (the core's radius query, `c.foe` by id), a blow is `c.deal`.

const SPEED := 16.0       ## m/s a hunting soul flies
const OUT_SPEED := 13.0   ## m/s the ring flies outward before any wisp locks on
const OUT_T := 0.7        ## s of straight flight
const LOAD_PAD := 5.0     ## m of extra distance per wisp already sent at an enemy, when picking prey
const SEEK_R := 30.0     ## m from her that a soul looks for prey
const SEEK_EVERY := 0.25  ## s between searches (hunting souls steer every tick; only the search is spaced)
const ORBIT_R := 1.6
const ORBIT_SPEED := 2.2  ## rad/s
const HIT_PAD := 0.5      ## m added to an enemy's radius for a soul to land
const REFRESH_S := 50.0   ## a peer's circling sprites last 60 s; the host renews them while souls linger
const Y := 1.2
const _THROW := preload("res://next/rites/rite_scythe_throw.gd")


func _init() -> void:
	id = "unleash_souls"
	steps = true


func resolve(c: DmRiteCaster, _intent: Dictionary) -> String:
	var m := c.mem(id)
	var wisps: Array = m.get_or_add("wisps", [])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var n := DmAbilities.soul_cost(c.p, id) + DmPlayerRules.bag_spend(c.p, int(c.p["souls"]))   # the price (paid by the cast) plus the rest of the bag
	var origin := c.pos()
	if bool(c.mods.get("soulShield", false)):   # Soul Harbinger's Raiment: a shield still standing from the last release is refreshed, never stacked
		c.p["barrier"] = maxf(0.0, float(c.p["barrier"]) - float(m.get("shield", 0.0)))
		m["shield"] = 0.0
	for i in n:
		wisps.append({"a": float(i) / float(n) * TAU, "x": origin.x, "z": origin.z, "eid": -1, "dmg": dmg, "t": OUT_T})
	m["seek"] = 0.0
	m["refresh"] = REFRESH_S
	m["shown"] = 0
	c.broadcast({"t": "release", "rite": id, "by": c.peer_id, "x": origin.x, "z": origin.z, "n": n, "orbit": 0})
	c.push_state()
	return ""


func step(c: DmRiteCaster, dt: float) -> void:
	var m := c.mem(id)
	var wisps: Array = m.get("wisps", [])
	if wisps.is_empty():
		return
	if not bool(c.p["alive"]):
		wisps.clear()
		c.broadcast({"t": "end", "rite": id, "by": c.peer_id})
		return
	var origin := c.pos()
	var go: Array = []
	m["seek"] = float(m["seek"]) - dt
	var seeking: bool = float(m["seek"]) <= 0.0
	var prey: Array = []
	if seeking:
		m["seek"] = SEEK_EVERY
		prey = _prey(c, origin)
	var load := {}   # enemy id -> wisps already sent at it
	if seeking and not prey.is_empty():
		for w: Dictionary in wisps:
			if int(w["eid"]) >= 0:
				load[int(w["eid"])] = int(load.get(int(w["eid"]), 0)) + 1
	var hits: Array = []
	var dmg_each := 0.0
	var shield := bool(c.mods.get("soulShield", false))
	var scythe_cap := int(c.mods.get("soulScythes", 0.0))
	var i := wisps.size() - 1
	while i >= 0:
		var w: Dictionary = wisps[i]
		if float(w["t"]) > 0.0:   # still flying outward in the ring
			w["t"] = float(w["t"]) - dt
			w["x"] = float(w["x"]) + cos(float(w["a"])) * OUT_SPEED * dt
			w["z"] = float(w["z"]) + sin(float(w["a"])) * OUT_SPEED * dt
			if float(w["t"]) <= 0.0:
				m["seek"] = 0.0   # the ring is done: hunt on the very next tick, from where the ring ended (not from her)
			i -= 1
			continue
		var e: DmFoe = null
		if int(w["eid"]) >= 0:
			e = c.foe(int(w["eid"]))
			if e == null or not e.alive():
				e = null
				w["eid"] = -1
		if e == null and seeking and not prey.is_empty():
			e = _pick(c, prey, float(w["x"]), float(w["z"]), load)
			if e != null:
				w["eid"] = e.id
				load[w["eid"]] = int(load.get(w["eid"], 0)) + 1
				go.append([float(w["x"]), float(w["z"]), int(w["eid"])])
		if e == null:   # circling her
			w["a"] = float(w["a"]) + ORBIT_SPEED * dt
			w["x"] = origin.x + cos(float(w["a"])) * ORBIT_R
			w["z"] = origin.z + sin(float(w["a"])) * ORBIT_R
		else:
			var gp := Vector3(e.x, 0.0, e.z)
			var dx := gp.x - float(w["x"])
			var dz := gp.z - float(w["z"])
			var d := sqrt(dx * dx + dz * dz)
			var reach := e.radius + HIT_PAD
			if d <= reach + SPEED * dt:
				var dmg := float(w["dmg"])
				var r := c.deal(e.id, dmg)
				if float(r["dealt"]) > 0.0:
					c.hit_resolved.emit(id, int(w["eid"]), dmg, false, bool(r["killed"]))
					hits.append(Vector3(gp.x, 0.9, gp.z))
					dmg_each = dmg
					if shield:   # Soul Harbinger's Raiment, 4 pieces: the damage the souls do becomes her barrier
						c.add_barrier(dmg)
						m["shield"] = float(m.get("shield", 0.0)) + dmg
					if scythe_cap > 0 and _THROW.soul_scythes(c) < scythe_cap:   # 5 pieces: a Scythe Throw is left where the soul landed
						_THROW.spawn(c, gp.x, gp.z, true)
				wisps.remove_at(i)
			else:
				w["x"] = float(w["x"]) + dx / d * SPEED * dt
				w["z"] = float(w["z"]) + dz / d * SPEED * dt
		i -= 1
	var orbiting := 0
	for w: Dictionary in wisps:
		if int(w["eid"]) < 0 and float(w["t"]) <= 0.0:
			orbiting += 1
	m["refresh"] = float(m["refresh"]) - dt
	if not go.is_empty() or orbiting != int(m["shown"]) or (float(m["refresh"]) <= 0.0 and orbiting > 0):
		m["shown"] = orbiting
		m["refresh"] = REFRESH_S
		c.broadcast({"t": "sync", "rite": id, "by": c.peer_id, "go": go, "orbit": orbiting})
	if not hits.is_empty():
		c.broadcast({"t": "hit", "rite": id, "by": c.peer_id, "hits": hits, "amount": dmg_each})
		c.push_state()
	if wisps.is_empty():
		c.broadcast({"t": "end", "rite": id, "by": c.peer_id})


## HOST. The living, hittable enemies within SEEK_R of her.
func _prey(c: DmRiteCaster, origin: Vector3) -> Array:
	var out: Array = []
	for e: DmFoe in c.foes_in_radius(origin, SEEK_R):
		if e.alive() and e.hittable():
			out.append(e)
	return out


## The enemy a wisp at (x, z) hunts: the nearest, with LOAD_PAD metres added per wisp already sent at it, so a crowd is shared out.
func _pick(_c: DmRiteCaster, prey: Array, x: float, z: float, load: Dictionary) -> DmFoe:
	var best: DmFoe = null
	var best_d := INF
	for e: DmFoe in prey:
		var d := Vector2(e.x - x, e.z - z).length() + LOAD_PAD * float(load.get(e.id, 0))
		if d < best_d:
			best_d = d
			best = e
	return best


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var vis: Dictionary = c.mem(id).get_or_add("vis", {})
	match String(ev["t"]):
		"release":
			var x := float(ev["x"])
			var z := float(ev["z"])
			c.fx.decal("ring", DmReaperRites.GREEN, x, z, 3.0, 0.5, 0.9, {"growFrom": 0.2, "fadeOut": 0.3})
			c.fx.emit(x, 1.1, z, 10 + int(ev["n"]), DmReaperRites.PALE, 1.0, 3.0, 1.6, 0.8, 0.18, {"gravity": -0.3})
			c.fx.lf(x, 1.2, z, DmReaperRites.GREEN, 12.0, 0.3)
			c.fx.sfx("wail", x, z, 0.8)
			c.shake_requested.emit(0.03 + 0.001 * float(ev["n"]))
			var n := int(ev["n"])
			var from := Vector3(x, Y, z)
			for k in n:   # the ring: one sprite per soul, flying straight out
				var a := float(k) / float(n) * TAU
				c.fx.shot(from, from + Vector3(cos(a), 0.0, sin(a)) * OUT_SPEED * OUT_T, OUT_SPEED, 0.0, "sprite", DmReaperRites.GREEN, {"tex": "wisp", "size": 0.9})
			_circle(c, vis, int(ev["orbit"]))
		"sync":
			_circle(c, vis, int(ev["orbit"]))
			for g: Array in ev["go"]:
				var from := Vector3(float(g[0]), Y, float(g[1]))
				c.fx.shot(from, DmRiteModule.follow_enemy(c, int(g[2]), from, 0.9), SPEED, 0.0, "sprite", DmReaperRites.GREEN, {"tex": "wisp", "size": 0.9})
		"hit":
			var amount := float(ev["amount"])
			for h: Vector3 in ev["hits"]:
				c.fx.emit(h.x, h.y, h.z, 5, DmReaperRites.GREEN, 0.2, 2.4, 1.1, 0.35, 0.12, {"gravity": 8.0})
				c.fx.hit_flash(h.x, 1.0, h.z, DmReaperRites.GREEN, 0.8, 0.16, "hit_flash", 1.4, 0.16)
				c.hit_number.emit(h, amount, false)
			var first: Vector3 = ev["hits"][0]
			c.fx.sfx("boneHit", first.x, first.z, 0.9)
		"end":
			_circle(c, vis, 0)


## EVERY PEER: the sprites circling her, `n` of them (0 = none). One group at a time; it is rebuilt when the count changes.
func _circle(c: DmRiteCaster, vis: Dictionary, n: int) -> void:
	if vis.has("h"):
		DmRiteFx.kill(vis["h"])
		vis.erase("h")
	if n <= 0 or c.body == null:
		return
	var body := c.body
	vis["h"] = c.fx.soul_circle(n, REFRESH_S + 10.0, ORBIT_SPEED, ORBIT_R, func() -> Variant:
		return Vector3(body.global_position.x, 0.0, body.global_position.z) if is_instance_valid(body) else null)
