extends SceneTree
## The core's enemy brain against today's rules (godot/enemies, combat map sections 2 and 12): chase and bite timing, the penitent's cone,
## the moth's dust cloud, the sac's slam, the bat's hit-and-run, the ghoul's tunnel and eruption, leash and return, stagger and stun.
## Seeded and without a navmesh (straight lines). Run: godot --headless --path client --script res://tests/core_enemies.gd

const EV_STATE := 2
const EV_DIED := 4
const EV_ATTACK := 6
const EV_TELEGRAPH := 7
const EV_CUE := 8
const EV_HIT := 9
const EV_ZONE := 10
const EV_ZONE_PULSE := 11
const EV_ZONE_GONE := 12
const IDLE := 1
const CHASE := 2
const ATTACK := 3
const HURT := 4
const RETURN := 5
const FLEE := 7
const BURROW := 8
const ERUPT := 9
const DIG := 10
const EMERGE := 11
const DT := 1.0 / 60.0

var fails := 0
var checks := 0
var content: Dictionary


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL core_enemies: " + what)


func make(seed_: int = 11) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	c.load_enemy_defs(content["ENEMIES"])
	c.load_tuning(content)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	return c


func hero(c: RefCounted, at: Vector2) -> int:
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, at, true)
	return h


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


## Steps until `pred(event)` matches an event or `max_ticks` pass; returns [tick, first matching event] or [-1, {}]. Every event of every
## tick stepped is appended to `log` (the matching tick's later events too).
func run_until(c: RefCounted, pred: Callable, max_ticks: int, log: Array = []) -> Array:
	for t in max_ticks:
		c.step(DT)
		var hit := {}
		for e in events(c):
			log.append(e)
			if hit.is_empty() and pred.call(e):
				hit = e
		if not hit.is_empty():
			return [t + 1, hit]
	return [-1, {}]


func states_of(log: Array, id: int) -> Array:
	return log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == id).map(func(e: Dictionary) -> int: return e["ints"][1])


func _init() -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path("res://").path_join("../godot/data/content/enemies.json"), FileAccess.READ)
	content = JSON.parse_string(f.get_as_text())
	robber()
	penitent()
	moth()
	sac()
	bat()
	ghoul()
	leash()
	stagger_and_stun()
	if fails == 0:
		print("PASS core_enemies %d checks" % checks)
	quit(1 if fails > 0 else 0)


## The robber walks in, bites for its damage at the end of the 0.42 s wind-up, then bites again one cooldown (1.3 s = 78 ticks) later.
func robber() -> void:
	var c := make()
	var h := hero(c, Vector2(10, 0))
	var r: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var log := []
	var first := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_HIT, 600, log)
	check(first[0] > 0, "robber: a bite lands")
	if first[0] < 0:
		return
	check(first[1]["id"] == r and first[1]["ints"][0] == h and first[1]["ints"][1] == 0 and is_equal_approx(first[1]["floats"][0], 11.0), "robber: bites the hero for 11, melee")
	check(states_of(log, r).slice(0, 2) == [CHASE, ATTACK], "robber: IDLE -> CHASE -> ATTACK")
	var swing: Array = log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_ATTACK)
	check(swing.size() == 1 and swing[0]["floats"][0] == 10.0, "robber: the swing aims at the hero")
	var travel_s: float = (10.0 - (1.3 + 0.35)) / float(c.enemy_info(r)["speed"])
	check(first[0] * DT > travel_s and first[0] * DT < travel_s + 0.42 + 0.5, "robber: first bite after the walk plus the wind-up (%.2f s)" % (first[0] * DT))
	var second := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_HIT, 300)
	# The cooldown (1.3 s, 78 ticks) starts at impact; the next swing's 0.42 s wind-up (26 ticks) follows it.
	check(second[0] >= 103 and second[0] <= 105, "robber: the next bite one cooldown plus one wind-up later (%d ticks, want 103-105)" % second[0])


## The penitent holds range and tolls a cone: a hero inside the cone at the end of the 1.1 s wind-up is hit, one who steps out is not.
func penitent() -> void:
	var c := make()
	var h := hero(c, Vector2(6, 0))
	var p: int = c.spawn_enemy("penitent", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var log := []
	var tell := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_TELEGRAPH, 300, log)
	check(tell[0] > 0 and tell[1]["ints"][0] == 0 and is_equal_approx(tell[1]["floats"][5], 1.1), "penitent: a cone telegraph with the 1.1 s wind-up")
	var hit := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_HIT, 80)
	check(hit[0] >= 65 and hit[0] <= 67 and is_equal_approx(hit[1]["floats"][0], 18.0), "penitent: the toll lands 1.1 s later for 18 (%d ticks)" % hit[0])
	# Next swing: the hero walks out of the cone during the wind-up.
	var tell2 := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_TELEGRAPH, 400)
	check(tell2[0] > 0, "penitent: casts again after its cooldown")
	c.set_external(h, Vector2(0, 6), true)   # 90 degrees off the aim
	var miss := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_HIT, 70)
	check(miss[0] < 0, "penitent: stepping out of the cone dodges the toll")


## The moth dusts where the hero stood: a burst of its damage, then a 3.5 s cloud that pulses 3.5 a second (damage x 0.35) at 1, 2 and 3 s.
func moth() -> void:
	var c := make()
	var h := hero(c, Vector2(5, 0))
	c.spawn_enemy("moth", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var log := []
	run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_ZONE, 400, log)
	var burst: Array = log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_HIT)
	check(burst.size() == 1 and is_equal_approx(burst[0]["floats"][0], 10.0) and burst[0]["ints"][1] == 4, "moth: the burst hits for 10, kind dust")
	var zlog := []
	run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_ZONE_GONE, 300, zlog)
	var pulses: Array = zlog.filter(func(e: Dictionary) -> bool: return e["type"] == EV_ZONE_PULSE)
	var cloud_hits: Array = zlog.filter(func(e: Dictionary) -> bool: return e["type"] == EV_HIT and is_equal_approx(e["floats"][0], 3.5))
	check(pulses.size() == 3 and cloud_hits.size() == 3, "moth: the cloud pulses 3 times for 3.5 (pulses %d, hits %d)" % [pulses.size(), cloud_hits.size()])
	c.set_external(h, Vector2(30, 30), true)


## The sac slams the ground at the aim: everything within 1.9 m of it.
func sac() -> void:
	var c := make()
	hero(c, Vector2(4, 0))
	c.spawn_enemy("sac", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var log := []
	var hit := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_HIT, 900, log)
	check(hit[0] > 0 and is_equal_approx(hit[1]["floats"][0], 15.0), "sac: the slam lands for 15")
	var tells: Array = log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_TELEGRAPH and e["ints"][0] == 1)
	var cues: Array = log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_CUE and e["ints"][0] == 0)
	check(tells.size() == 1 and is_equal_approx(tells[0]["floats"][4], 1.9) and cues.size() == 1, "sac: a slam telegraph (r 1.9) and a slam cue")


## The bat bites and flits off for 0.8 s (FLEE), then comes back (CHASE).
func bat() -> void:
	var c := make()
	hero(c, Vector2(6, 0))
	var b: int = c.spawn_enemy("bat", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var log := []
	run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == b and e["ints"][1] == FLEE, 600, log)
	var flee := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == b, 120)
	check(log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_HIT).size() == 1, "bat: one bite before it flees")
	check(flee[0] >= 48 and flee[0] <= 50 and flee[1]["ints"][1] == CHASE, "bat: flees 0.8 s, then chases (%d ticks)" % flee[0])


## The ghoul spawns underground (untouchable), tunnels at the hero, erupts under it after the 1.0 s Graves wind-up, recovers 0.3 s, fights;
## the first fall below half health digs it back in (0.8 s) for another tunnel run.
func ghoul() -> void:
	var c := make()
	var h := hero(c, Vector2(9, 0))
	var g: int = c.spawn_enemy("ghoul", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", true)
	c.step(DT)
	check(c.enemy_info(g)["state"] == BURROW, "ghoul: a rising ghoul starts underground")
	check(c.damage(g, 5.0, h)["dealt"] == 0.0, "ghoul: untouchable underground")
	var log := []
	var erupt := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == g and e["ints"][1] == ERUPT, 300, log)
	check(erupt[0] > 0, "ghoul: erupts near the hero")
	var tell: Array = log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_TELEGRAPH)
	check(tell.size() == 1 and tell[0]["ints"][0] == 3 and is_equal_approx(tell[0]["floats"][5], 1.0), "ghoul: an erupt telegraph with the 1.0 s Graves wind-up")
	var hit := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_HIT, 80)
	check(hit[0] >= 59 and hit[0] <= 61 and is_equal_approx(hit[1]["floats"][0], 12.0), "ghoul: the eruption hits for 12 (x1.0 in the Graves) after 1.0 s (%d ticks)" % hit[0])
	var p: Vector2 = c.enemy_info(g)["pos"]
	check(p.distance_to(Vector2(9, 0)) < 0.01, "ghoul: surfaces at the aim")
	var emerge := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == g, 30)
	check(emerge[1].get("ints", [0, 0])[1] == CHASE and emerge[0] >= 18 and emerge[0] <= 20, "ghoul: EMERGE 0.3 s, then CHASE")
	var dlog := []
	c.damage(g, 35.0, h)   # 60 hp -> 25, below half
	dlog.append_array(events(c))
	check(states_of(dlog, g).has(DIG), "ghoul: below half health it digs in")
	var back := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == g and e["ints"][1] == BURROW, 70)
	check(back[0] >= 47 and back[0] <= 50, "ghoul: dig 0.8 s, then underground again (%d ticks)" % back[0])


## A target that runs past aggro x 1.5 (22.5 m) is dropped; the body walks home and idles.
func leash() -> void:
	var c := make()
	var h := hero(c, Vector2(8, 0))
	var r: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == r and e["ints"][1] == CHASE, 60)
	c.set_external(h, Vector2(45, 0), true)
	var ret := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == r and e["ints"][1] == RETURN, 10)
	check(ret[0] > 0, "leash: a target beyond 22.5 m is dropped")
	var home := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == r and e["ints"][1] == IDLE, 600)
	check(home[0] > 0 and (c.enemy_info(r)["pos"] as Vector2).length() <= 1.0, "leash: walks home, then idles")


## A plain hit staggers an idle/chasing body for 0.3 s at most once per 0.9 s; a stun mid-swing cancels the blow.
func stagger_and_stun() -> void:
	var c := make()
	var h := hero(c, Vector2(30, 0))
	var r: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	c.damage(r, 1.0, 0)
	check(c.enemy_info(r)["state"] == HURT, "stagger: the first hit flinches")
	events(c)
	var out := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == r, 30)
	check(out[0] >= 18 and out[0] <= 19, "stagger: 0.3 s flinch (%d ticks)" % out[0])
	c.damage(r, 1.0, 0)
	check(c.enemy_info(r)["state"] != HURT, "stagger: no second flinch inside the 0.9 s window")
	c.damage(r, 1.0, h)
	check(c.enemy_info(r)["target"] == h, "aggro: a hit from the hero makes it the target")
	c.set_external(h, Vector2(1.2, 0), true)
	run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_ATTACK and e["id"] == r, 300)
	c.stun(r, 2.0)
	check(c.enemy_info(r)["state"] == HURT, "stun: forces HURT mid-swing")
	var hit := run_until(c, func(e: Dictionary) -> bool: return e["type"] == EV_HIT, 60)
	check(hit[0] < 0, "stun: the cancelled swing never lands")
