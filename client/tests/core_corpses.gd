extends SceneTree
## Corpses in the combat core against DmCorpseField (archive/old-game:godot/next/corpses/dm_corpse_field.gd, host logic): which kinds the roster leaves, where in
## a death they are laid, the extra "risen" corpses, the cap, the lifetime, the toxic rupture into a hostile pool, the nearest-first and
## two-stage pick queries and the atomic consume. Timings are computed the way today's clock adds them (a double that gains 1/60 per tick). The lifetime, the cap, the rupture
## and the pool are read from the core's own table (`DmCore.tuning()`, the sim constants plus the field's compiled-in ones); the corpse kinds, scales and counts from enemies.json.
## Run: godot --headless --path client --script res://tests/core_corpses.gd

const EV_STATE := 2
const EV_DAMAGED := 3
const EV_DIED := 4
const EV_HIT := 9
const EV_ZONE := 10
const EV_ZONE_PULSE := 11
const EV_ZONE_GONE := 12
const EV_STATUS_CHANGED := 14
const EV_WITHERED_DIED := 17
const EV_CORPSE_ADDED := 18
const EV_CORPSE_CONSUMED := 19
const EV_CORPSE_GONE := 20
const EV_CORPSE_RUPTURED := 21
const ZONE_TOXIC := 1
const HK_TOXIC := 1
const DEAD := 6
const DT := 1.0 / 60.0

var fails := 0
var checks := 0
var data_dir: String   ## this project's data/ (res://): the same files the game loads
var data := {}
var tun := {}   ## DmCore.tuning() of a core loaded from the data: the corpse field's numbers
var clock := 0.0   ## what the core's corpse clock reads: the sum of the steps taken so far
var tick_no := 0   ## the tick the last step was (events are tagged with it)


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL core_corpses: " + what)


func make(seed_: int = 21) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	DmCoreData.load_all(c, data_dir)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	clock = 0.0
	tick_no = 0
	return c


## damage_scale(level) of combat/enemies.json: base + per_level x (level - 1).
func dscale(level: int) -> float:
	var ds: Dictionary = data["combat"]["damage_scale"]
	return float(ds["base"]) + float(ds["per_level"]) * float(level - 1)


func events(c: RefCounted) -> Array:
	var raw: Array = c.take_events()
	var ints: PackedInt32Array = raw[0]
	var floats: PackedFloat32Array = raw[1]
	var out := []
	var i := 0
	var f := 0
	while i < ints.size():
		var ni := ints[i + 2]
		var nf := ints[i + 3]
		out.append({"type": ints[i], "id": ints[i + 1], "ints": ints.slice(i + 4, i + 4 + ni), "floats": floats.slice(f, f + nf)})
		i += 4 + ni
		f += nf
	return out


func of_type(log: Array, type: int) -> Array:
	return log.filter(func(e: Dictionary) -> bool: return e["type"] == type)


## Steps n ticks, appending every event with the tick it came in (counted from the core's first step).
func steps(c: RefCounted, n: int, log: Array) -> void:
	for i in n:
		c.step(DT)
		clock += DT
		tick_no += 1
		for e in events(c):
			e["tick"] = tick_no
			log.append(e)


## The tick count after which `value` has gained `amount` one 1/60 at a time, the way a timer accumulates (value + amount, compared with >=).
func ticks_until(start: float, amount: float) -> int:
	var t := start
	var n := 0
	while t < start + amount:
		t += DT
		n += 1
	return n


## Ticks of a countdown `x -= dt` from `x0` until it is <= 0.
func countdown(x0: float) -> int:
	var x := x0
	var n := 0
	while x > 0.0:
		x -= DT
		n += 1
	return n


func _init() -> void:
	data_dir = "res://"
	data["enemies"] = DmCoreData.json(data_dir.path_join("data/content/enemies.json"))
	data["combat"] = DmCoreData.json(data_dir.path_join("data/combat/enemies.json"))
	tun = make().tuning()
	kinds_and_order()
	extra_corpses()
	cap_and_lifetime()
	born_in_the_corpse_phase()
	toxic_rupture()
	queries()
	consume()
	if fails == 0:
		print("PASS core_corpses %d checks" % checks)
	quit(1 if fails > 0 else 0)


## Each def leaves its kind (or none); the corpse is laid after the statuses are cleared and before the died event, carrying everything the view needs.
func kinds_and_order() -> void:
	var defs: Dictionary = data["enemies"]["ENEMIES"]
	# A mix of the corpse kinds, picked here; each def's kind is its `corpse` key.
	var want := {}
	for k in ["robber", "hound", "penitent", "sac", "censer", "moth", "ghoul", "bat", "risen", "rat", "wraith"]:
		want[k] = String(defs[k]["corpse"])
	var c := make()
	var at := 0.0
	for k: String in want:
		at += 5.0
		var e: int = c.spawn_enemy(k, Vector2(at, 3.0), 1, 1.0, 1.0, false, "graves", false)
		events(c)
		var before: int = c.corpse_count()
		c.damage(e, 1.0e9, 7)
		var log := events(c)
		var added := of_type(log, EV_CORPSE_ADDED)
		if want[k] == "none":
			check(added.is_empty() and c.corpse_count() == before, "%s leaves no corpse" % k)
			continue
		check(added.size() == 1 and c.corpse_count() == before + 1, "%s leaves one corpse" % k)
		var a: Dictionary = added[0]
		var info: Dictionary = c.corpse_info(a["id"])
		check(info["kind"] == want[k] and info["enemy"] == k and info["area"] == "graves" and not info["elite"], "%s: corpse kind %s, its def and area" % [k, want[k]])
		check(is_equal_approx(info["scale"], float(defs[k].get("scale", 1.0))) and is_equal_approx(info["x"], at) and is_equal_approx(info["z"], 3.0), "%s: the corpse carries the node scale and the position" % k)
		check(c.def_name(a["ints"][1]) == k and c.area_name(a["ints"][3]) == "graves" and a["ints"][0] == ["normal", "swift", "resonant", "toxic"].find(want[k]) and a["ints"][2] == 0, "%s: the added event carries kind, def, elite, area" % k)
		check(is_equal_approx(a["floats"][0], at) and is_equal_approx(a["floats"][1], 3.0) and is_equal_approx(a["floats"][3], float(defs[k].get("scale", 1.0))), "%s: the added event carries x, z, scale" % k)
		var order := log.map(func(x: Dictionary) -> int: return x["type"])
		check(order.find(EV_CORPSE_ADDED) < order.find(EV_DIED) and order.find(EV_STATE) < order.find(EV_CORPSE_ADDED), "%s: dead, then the corpse, then died" % k)
	# An elite's corpse is flagged and carries its node scale (def scale x ELITE.scale).
	var el: int = c.spawn_enemy("penitent", Vector2(-20, 0), 1, 1.0, 1.0, true, "graves", false)
	events(c)
	c.damage(el, 1.0e9, 7)
	var ea := of_type(events(c), EV_CORPSE_ADDED)
	var ei: Dictionary = c.corpse_info(ea[0]["id"])
	check(ei["elite"] and ea[0]["ints"][2] == 1 and is_equal_approx(ei["scale"], float(defs["penitent"].get("scale", 1.0)) * float(data["enemies"]["ELITE"]["scale"])), "an elite's corpse: flagged, scale x ELITE.scale")
	# Statuses first: Withered is reported and the set cleared before the corpse, which comes before died.
	var w: int = c.spawn_enemy("robber", Vector2(-20, 10), 1, 1.0, 1.0, false, "graves", false)
	events(c)
	c.apply_status(w, "withered", 9, 3, -1.0, {"dps": 2.0})
	events(c)
	c.damage(w, 1.0e9, 7)
	var order2 := events(c).map(func(x: Dictionary) -> int: return x["type"])
	var wi := order2.find(EV_WITHERED_DIED)
	var ci := order2.find(EV_CORPSE_ADDED)
	check(wi >= 0 and order2.find(EV_STATUS_CHANGED) > wi and ci > order2.find(EV_STATUS_CHANGED) and order2.find(EV_DIED) > ci, "a death: withered reported, statuses cleared, corpse laid, died")


## deathCorpses: the golem and the drowned sexton leave the corpse plus "risen" ones (as many as their deathCorpses say) on a ring (EXTRA_RING) at yaw + k/(n-1) x TAU.
func extra_corpses() -> void:
	var defs: Dictionary = data["enemies"]["ENEMIES"]
	var ring: float = tun["EXTRA_RING"]
	var n_golem := int(defs["golem"]["deathCorpses"])
	var n_sexton := int(defs["drowned_sexton"]["deathCorpses"])
	var c := make()
	var hero: int = c.add_external(0, 0.4, 1.0)
	c.set_external(hero, Vector2(10, 5), true)
	var g: int = c.spawn_enemy("golem", Vector2(0, 0), 1, 1.0, 1.0, true, "graves", false)
	for i in 20:
		c.step(DT)   # it turns toward the hero
	var gi: Dictionary = c.enemy_info(g)
	events(c)
	c.damage(g, 1.0e9, 7)
	var added := of_type(events(c), EV_CORPSE_ADDED)
	check(added.size() == n_golem, "golem (deathCorpses %d): that many corpses (%d)" % [n_golem, added.size()])
	if added.size() != n_golem:
		return
	var yaw: float = gi["yaw"]
	var first: Dictionary = c.corpse_info(added[0]["id"])
	check(first["enemy"] == "golem" and first["elite"] and first["kind"] == "normal", "the first is the golem's own, elite flagged")
	for k in range(1, n_golem):
		var r: Dictionary = c.corpse_info(added[k]["id"])
		var a: float = yaw + float(k) / float(n_golem - 1) * TAU
		var p: Vector2 = gi["pos"]
		check(r["enemy"] == "risen" and not r["elite"] and r["kind"] == "normal" and r["scale"] == 1.0, "extra %d: a normal, non-elite 'risen' corpse at scale 1" % k)
		check(absf(r["facing"] - a) < 1.0e-4, "extra %d: facing yaw + %d/%d x TAU (%.4f vs %.4f)" % [k, k, n_golem - 1, r["facing"], a])
		check(absf(Vector2(r["x"], r["z"]).distance_to(p) - ring) < 2.0e-3 and absf(r["x"] - (p.x + sin(a) * ring)) < 2.0e-3 and absf(r["z"] - (p.y + cos(a) * ring)) < 2.0e-3, "extra %d: on the %s m ring at (sin a, cos a)" % [k, ring])
	var s: int = c.spawn_enemy("drowned_sexton", Vector2(-30, -30), 1, 1.0, 1.0, false, "graves", false)
	var s_yaw: float = c.enemy_info(s)["yaw"]
	events(c)
	c.damage(s, 1.0e9, 7)
	var sx := of_type(events(c), EV_CORPSE_ADDED)
	check(sx.size() == n_sexton, "sexton (deathCorpses %d): that many corpses (%d)" % [n_sexton, sx.size()])
	for k in range(1, mini(n_sexton, sx.size())):
		var sk: Dictionary = c.corpse_info(sx[k]["id"])
		check(absf(sk["facing"] - (s_yaw + float(k) / float(n_sexton - 1) * TAU)) < 1.0e-4, "sexton: extra %d at yaw + %d/%d x TAU" % [k, k, n_sexton - 1])


## Lifetime (CORPSE_LIFETIME) x the life multiplier, the cap (MAX_CORPSES) with the oldest evicted first ("expired", before the new one is added).
func cap_and_lifetime() -> void:
	var life_s: float = tun["CORPSE_LIFETIME"]
	var cap: int = tun["MAX_CORPSES"]
	check(life_s == DmSimConsts.CORPSE_LIFETIME and cap == DmSimConsts.MAX_CORPSES and tun["TOXIC_RUPTURE"] == DmSimConsts.TOXIC_RUPTURE, "the core's lifetime, cap and rupture are sim_consts.gd's")
	var c := make()
	var log := []
	var a: int = c.corpse_add(Vector2(0, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var info: Dictionary = c.corpse_info(a)
	check(is_equal_approx(info["expiresAt"] - info["bornAt"], life_s) and info["ruptureAt"] == INF, "a corpse lives CORPSE_LIFETIME and a normal one never ruptures")
	var n := ticks_until(0.0, life_s)
	steps(c, n - 1, log)
	check(c.corpse_count() == 1 and of_type(log, EV_CORPSE_GONE).is_empty(), "still there one tick before its lifetime")
	steps(c, 1, log)
	var gone := of_type(log, EV_CORPSE_GONE)
	check(gone.size() == 1 and gone[0]["tick"] == n and gone[0]["id"] == a and c.reason_name(gone[0]["ints"][0]) == "expired" and c.corpse_count() == 0, "expired on tick %d (%s s accumulated), reason expired" % [n, life_s])
	# The life multiplier (corpseLifeMult x the vow multiplier) scales it: Lingering Dead x1.5, Thin Graves x0.75.
	for m in [1.5, 0.75, 2.0, 0.5]:
		var d := make()
		d.set_corpse_life_mult(m)
		var id: int = d.corpse_add(Vector2(1, 1), "normal", "robber", false, 0.0, 1.0, "graves")
		var want := ticks_until(0.0, life_s * m)
		var l2 := []
		steps(d, want, l2)
		var g2 := of_type(l2, EV_CORPSE_GONE)
		check(g2.size() == 1 and g2[0]["tick"] == want and g2[0]["id"] == id, "life x%.2f: gone on tick %d (%.1f s)" % [m, want, life_s * m])
	# The cap: four more corpses than it allows, a step between each; the first 4 go out oldest first.
	var h := make()
	var cl := []
	var ids := []
	for i in cap + 4:
		ids.append(h.corpse_add(Vector2(i, 0), "normal", "robber", false, 0.0, 1.0, "graves"))
		steps(h, 1, cl)
	var gones := of_type(cl, EV_CORPSE_GONE)
	check(h.corpse_count() == cap and gones.size() == 4, "capped at %d (got %d, %d evicted)" % [cap, h.corpse_count(), gones.size()])
	check(gones.map(func(x: Dictionary) -> int: return x["id"]) == ids.slice(0, 4) and gones.all(func(x: Dictionary) -> bool: return h.reason_name(x["ints"][0]) == "expired"), "the oldest four went first, reason expired")
	var seq := cl.filter(func(x: Dictionary) -> bool: return x["type"] == EV_CORPSE_GONE or x["type"] == EV_CORPSE_ADDED)
	var k := seq.find(gones[0])
	check(k > 0 and seq[k + 1]["type"] == EV_CORPSE_ADDED and seq[k + 1]["id"] == ids[cap], "the eviction comes before the corpse that took its place")
	# Corpses laid in the same instant: the first laid is the oldest (strict <).
	var t := make()
	var same := []
	for i in cap + 1:
		same.append(t.corpse_add(Vector2(i, 0), "normal", "robber", false, 0.0, 1.0, "graves"))
	check(t.corpse_count() == cap and t.corpse_info(same[0]).is_empty() and not t.corpse_info(same[1]).is_empty(), "equal birth times: the one laid first goes first")
	# Eviction lets the id counter run on (ids are never reused).
	check(same[cap] == same[0] + cap, "ids keep counting")


## A kill inside step() lays its corpse before the corpse clock gains that tick; a call between ticks lays it at the clock as it stands.
func born_in_the_corpse_phase() -> void:
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	c.apply_status(e, "bleed", 4, 1, 5.0, {"dps": 1.0e6})   # the first DoT lump kills it inside a step
	var log := []
	steps(c, 60, log)
	var died := of_type(log, EV_DIED)
	var added := of_type(log, EV_CORPSE_ADDED)
	check(died.size() == 1 and added.size() == 1 and added[0]["tick"] == died[0]["tick"], "the DoT kill and its corpse come in the same tick (%d)" % died[0]["tick"] if died.size() == 1 else "no DoT kill")
	if died.size() == 1 and added.size() == 1:
		var born_clock := 0.0
		for i in died[0]["tick"] - 1:
			born_clock += DT
		check(c.corpse_info(added[0]["id"])["bornAt"] == born_clock, "born at the corpse clock of the tick before (enemies run before corpses)")
	var d := make()
	var steps_taken := 10
	var l := []
	steps(d, steps_taken, l)
	var id: int = d.corpse_add(Vector2(0, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	check(d.corpse_info(id)["bornAt"] == clock, "laid between ticks: born at the clock as it stands")


## The sac's corpse is toxic: after TOXIC_RUPTURE it bursts into a hostile pool (TOXIC_R x scale, TOXIC_S long, a pulse every TOXIC_TICK for TOXIC_DMG x damage_scale(level)).
func toxic_rupture() -> void:
	var rupture_s: float = tun["TOXIC_RUPTURE"]
	var pool_s: float = tun["TOXIC_S"]
	var pulse_s: float = tun["TOXIC_TICK"]
	var pulse_dmg: float = float(tun["TOXIC_DMG"]) * dscale(1)   # the first area level, as nothing sets one here
	var c := make()
	var hero: int = c.add_external(0, 0.4, 1.0)
	c.set_external(hero, Vector2(20.5, 20), true)
	var s: int = c.spawn_enemy("sac", Vector2(20, 20), 1, 1.0, 1.0, false, "graves", false)
	events(c)
	c.damage(s, 1.0e9, 7)
	var cid: int = of_type(events(c), EV_CORPSE_ADDED)[0]["id"]
	var info: Dictionary = c.corpse_info(cid)
	check(info["kind"] == "toxic" and is_equal_approx(info["ruptureAt"] - info["bornAt"], rupture_s), "the sac corpse is toxic and ruptures TOXIC_RUPTURE after it was laid")
	var rupture_tick := ticks_until(0.0, rupture_s)
	var log := []
	steps(c, rupture_tick - 1, log)
	check(c.corpse_count() == 1 and of_type(log, EV_ZONE).is_empty(), "intact one tick before the rupture")
	steps(c, 1, log)
	var gone := of_type(log, EV_CORPSE_GONE)
	var zone := of_type(log, EV_ZONE)
	var rup := of_type(log, EV_CORPSE_RUPTURED)
	check(gone.size() == 1 and c.reason_name(gone[0]["ints"][0]) == "burst" and gone[0]["tick"] == rupture_tick and c.corpse_count() == 0, "burst on tick %d" % rupture_tick)
	check(zone.size() == 1 and rup.size() == 1 and rup[0]["id"] == cid and rup[0]["ints"][0] == zone[0]["id"], "a zone and a ruptured event naming it")
	var order := log.filter(func(x: Dictionary) -> bool: return x["tick"] == rupture_tick).map(func(x: Dictionary) -> int: return x["type"])
	check(order == [EV_CORPSE_GONE, EV_ZONE, EV_CORPSE_RUPTURED], "order: gone (burst), the pool, ruptured")
	var z: Dictionary = zone[0]
	check(z["ints"][0] == ZONE_TOXIC and z["ints"][1] == 0 and is_equal_approx(z["floats"][2], float(tun["TOXIC_R"]) * info["scale"]) and is_equal_approx(z["floats"][3], pool_s), "a toxic pool: r TOXIC_R x scale (%.2f), TOXIC_S long, no enemy source" % z["floats"][2])
	check(is_equal_approx(z["floats"][0], 20.0) and is_equal_approx(z["floats"][1], 20.0), "where the corpse lay")
	# The pool pulses every TOXIC_TICK (a countdown) from the tick after it was made, for TOXIC_DMG x damage_scale(1) = TOXIC_DMG (nothing sets an area level here).
	var n := countdown(pulse_s)
	var life := ticks_until(0.0, pool_s)   # the zone's age is a sum like the corpse clock
	var more := []
	steps(c, life + 5, more)
	var r0: int = rupture_tick
	var hits := of_type(more, EV_HIT)
	var pulses := of_type(more, EV_ZONE_PULSE)
	var ended := of_type(more, EV_ZONE_GONE)
	check(ended.size() == 1 and ended[0]["tick"] == r0 + life, "the pool ends on its %dth tick (TOXIC_S)" % life)
	check(pulses.size() == (life - 1) / n and pulses[0]["tick"] == r0 + n and pulses[1]["tick"] == r0 + 2 * n, "a pulse every %d ticks (TOXIC_TICK), the first %d ticks after the pool: %d pulses" % [n, n, pulses.size()])
	check(hits.size() == pulses.size() and hits.all(func(h: Dictionary) -> bool: return h["id"] == 0 and h["ints"][0] == hero and h["ints"][1] == HK_TOXIC and is_equal_approx(h["floats"][0], pulse_dmg)), "each pulse hurts the hero in it for TOXIC_DMG x damage_scale(1), kind toxic")
	# The level hook: TOXIC_DMG x damage_scale(5).
	var d := make()
	d.set_area_level("graves", 5)
	var h2: int = d.add_external(0, 0.4, 1.0)
	d.set_external(h2, Vector2(0.5, 0), true)
	d.corpse_add(Vector2(0, 0), "toxic", "sac", false, 0.0, 1.0, "graves")
	var l3 := []
	steps(d, ticks_until(0.0, rupture_s) + n + 1, l3)
	var h3 := of_type(l3, EV_HIT)
	check(not h3.is_empty() and is_equal_approx(h3[0]["floats"][0], float(tun["TOXIC_DMG"]) * dscale(5)), "area level 5: TOXIC_DMG x damage_scale(5) per pulse")
	# A toxic corpse consumed before 5 s never ruptures; a hero outside the pool is not hit.
	var q := make()
	var far: int = q.add_external(0, 0.4, 1.0)
	q.set_external(far, Vector2(10, 10), true)
	var tc: int = q.corpse_add(Vector2(0, 0), "toxic", "sac", false, 0.0, 1.0, "graves")
	var l4 := []
	steps(q, ticks_until(0.0, rupture_s) / 2, l4)
	check(q.corpse_consume(tc, 1, "consumed"), "consumed while it still lies")
	steps(q, ticks_until(0.0, rupture_s), l4)
	check(of_type(l4, EV_ZONE).is_empty() and of_type(l4, EV_CORPSE_RUPTURED).is_empty(), "a consumed toxic corpse never ruptures")


## corpses_in_radius: nearest first, the id breaking ties, the area filter; pick_corpse: the two-stage rule (the nearest to the aim within pick_r AND the
## cast range, else the nearest to the caster within 7 m), another area skipped.
func queries() -> void:
	var c := make()
	var a: int = c.corpse_add(Vector2(3, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var b: int = c.corpse_add(Vector2(5, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var far: int = c.corpse_add(Vector2(30, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var other: int = c.corpse_add(Vector2(4, 0), "normal", "robber", false, 0.0, 1.0, "fen")
	var from := Vector2(0, 0)
	check(Array(c.corpses_in_radius(from, 6.0, "graves")) == [a, b], "radius query: nearest first")
	check(Array(c.corpses_in_radius(from, 6.0)) == [a, other, b], "no area: every area, still nearest first")
	check(Array(c.corpses_in_radius(from, 5.0, "graves")) == [a, b] and Array(c.corpses_in_radius(from, 4.999, "graves")) == [a], "the radius is inclusive")
	check(c.corpses_in_radius(from, 6.0, "nowhere").is_empty() and Array(c.corpses_in_radius(from, 100.0)).size() == 4, "an area nobody named holds nothing; a huge radius holds all")
	# Equal distances: the lower id first.
	var t1: int = c.corpse_add(Vector2(0, 8), "normal", "robber", false, 0.0, 1.0, "graves")
	var t2: int = c.corpse_add(Vector2(-8, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var t3: int = c.corpse_add(Vector2(8, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	check(Array(c.corpses_in_radius(from, 9.0, "graves")) == [a, b, t1, t2, t3], "a tie in distance goes to the lower id")
	# pick_corpse
	check(c.corpse_pick(Vector2(5.2, 0), 2.5, 11.0, from, "graves") == b, "pick: the nearest to the aim wins")
	check(c.corpse_pick(Vector2(30, 0), 2.5, 11.0, from, "graves") == a, "pick: the aim is out of cast range -> the nearest to the caster")
	check(c.corpse_pick(Vector2(30, 40), 2.5, 11.0, from, "graves") == a, "pick: nothing under the cursor -> the nearest to the caster")
	check(c.corpse_pick(Vector2(4, 0), 0.5, 11.0, from, "graves") == a, "pick: another area is ignored (the fen corpse at 4 m is not it)")
	check(c.corpse_pick(Vector2(4, 0), 0.5, 11.0, from, "") == other, "pick: with no area, every area counts")
	check(c.corpse_pick(Vector2(0, 25), 2.0, 11.0, Vector2(0, 25), "graves") == 0, "pick: nothing within 7 m of the caster -> none")
	check(c.corpse_pick(Vector2(30, 0), 2.5, 40.0, Vector2(10, 0), "graves") == far, "pick: in range of the cast it is the aim's")
	var blank: int = c.corpse_add(Vector2(60, 60), "normal", "robber", false, 0.0, 1.0, "")
	check(c.corpse_pick(Vector2(60, 60), 2.0, 11.0, Vector2(60, 58), "graves") == blank, "pick: a corpse with no area is never skipped")
	# Bulk reads.
	var ids: PackedInt32Array = c.corpse_ids()
	var pos: PackedFloat32Array = c.corpse_positions()
	check(ids.size() == c.corpse_count() and pos.size() == ids.size() * 4 and ids[0] == a and pos[0] == 3.0 and pos[3] == 1.0, "bulk reads: ids and x, z, facing, scale per corpse, oldest first")


## consume is atomic: one winner, the consumed event before the gone event, the reason passed through; a consumed corpse can no longer be picked.
func consume() -> void:
	var c := make()
	var a: int = c.corpse_add(Vector2(3, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var b: int = c.corpse_add(Vector2(5, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var far: int = c.corpse_add(Vector2(30, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	events(c)
	var r1: bool = c.corpse_consume(b, 7)
	var r2: bool = c.corpse_consume(b, 8)
	check(r1 and not r2, "two casters, one corpse: the first wins, the second gets false")
	var log := events(c)
	check(log.size() == 2 and log[0]["type"] == EV_CORPSE_CONSUMED and log[1]["type"] == EV_CORPSE_GONE and log[0]["id"] == b and log[1]["id"] == b, "one consumed event, then one gone event")
	check(log[0]["ints"][0] == 7 and c.reason_name(log[0]["ints"][1]) == "consumed" and c.reason_name(log[1]["ints"][0]) == "consumed", "by the first caster, reason consumed")
	check(c.corpse_info(b).is_empty() and c.corpse_pick(Vector2(5, 0), 2.5, 11.0, Vector2(0, 0), "graves") == a, "a consumed corpse can no longer be picked")
	check(not c.corpse_consume(9999, 1), "an unknown id is refused")
	check(c.corpse_consume(far, 1, "litany") and c.reason_name(events(c).back()["ints"][0]) == "litany", "the reason passes through (litany)")
	var wins := 0
	for k in 10:
		if c.corpse_consume(a, k):
			wins += 1
	check(wins == 1, "ten consumers, one winner")
	events(c)
	var d: int = c.corpse_add(Vector2(1, 1), "normal", "robber", false, 0.0, 1.0, "graves")
	check(c.corpse_consume(d, 1, "devoured") and c.reason_name(events(c).back()["ints"][0]) == "devoured", "devoured, the Hungering affix's reason")
	var e: int = c.corpse_add(Vector2(1, 1), "normal", "robber", false, 0.0, 1.0, "graves")
	check(c.corpse_consume(e, 0, "sacrificed_elsewhere") and c.reason_name(events(c).back()["ints"][0]) == "sacrificed_elsewhere", "a reason the core has not seen is kept as given")
