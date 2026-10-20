extends SceneTree
## Thralls in the combat core against DmThrall and DmThrallHost (archive/old-game:godot/next/thralls): the rise, the owner leash and teleport, the 0.25 s
## scan and the targets it accepts (the boss edge rule), engage and the instant swing with Rally / Hag's curse / the Spear mark / damage dealt,
## the kinds' extras, the formation ring (1.9 m), make_room by cap and weight, enemies choosing thralls by weight and hurting them, deaths with
## their reasons, bursts, statuses on thralls, rally, separation and the tick order. Timers are computed the way today's clock adds them: a double
## that gains 1/60 per tick, so a timer's ticks are counted, not seconds x 60. Seeded and without a navmesh (straight lines).
## What the data holds is read: the sim constants, the corpse field's and the thralls' from the core's own table (`DmCore.tuning()`), the enemies' numbers from enemies.json, the statuses', Rally's,
## the plague burst's and the colossus' from their content files. What stays typed: the test's own stats and positions, and the thrall brain's compiled-in rules (radius 0.4, the 6 m / 1.35x pace, the 0.25 s scan).
## Run: godot --headless --path client --script res://tests/core_thralls.gd

const EV_SPAWNED := 1
const EV_STATE := 2
const EV_DAMAGED := 3
const EV_DIED := 4
const EV_ATTACK := 6
const EV_TELEGRAPH := 7
const EV_HIT := 9
const EV_STATUS_CHANGED := 14
const EV_STATUS_DOT := 15
const EV_CORPSE_ADDED := 18
const EV_RAISED := 22
const EV_T_STATE := 23
const EV_SWING := 24
const EV_T_DAMAGED := 25
const EV_T_DIED := 26
const EV_T_REMOVED := 27
const EV_T_STATUS := 28
const EV_BELL_HEAL := 29
const EV_PLAGUE_POOL := 30
const EV_HIT_BOSS := 31
const RISING := 0
const IDLE := 1
const MOVE := 2
const ATTACK := 3
const T_DEAD := 4
const CHASE := 2
const KILLED := 0
const CRUMBLED := 1
const SACRIFICED := 2
const DECAYED := 3
const HK_MELEE := 0
const DT := 1.0 / 60.0
## DmThralls.base_of: range, attack interval, speed per kind (inputs to raise; the colossus's come from runes.json).
const BASE := {"warrior": [1.3, 1.0, 5.6], "shieldbearer": [1.3, 1.25, 5.2], "hound": [1.2, 0.7, 7.2], "wraith": [5.5, 1.1, 5.8],
	"archer": [7.5, 1.3, 5.4], "bonemage": [6.5, 1.8, 5.2], "plaguebearer": [1.3, 1.2, 4.8]}
const SEAT_R := 1.9   ## DmThrall._follow: the formation ring
const BOSS_R := 1.6   ## the radius the scenarios give a boss (their own input)
const WIDE := 1.0e3   ## a limit a scenario sets out of the way
## The old game's scripts whose `const` lines the core's constants are checked against, kept as text (a ".txt" added, so Godot never parses them): the corpse field's and
## the thralls' (sim_consts.gd is this project's own). The game keeps the numbers compiled into the core; `tuning_matches_data` checks they are these.
const OLD := "res://tests/fixtures/old_game/"
const OLD_CONSTS: Array = ["next/corpses/dm_corpse_field.gd.txt", "next/thralls/dm_thrall.gd.txt"]

var fails := 0
var checks := 0
var data_dir: String   ## this project's data/ (res://): the same files the game loads
var data := {}
var tick_no := 0
var K := {}       ## DmCore.tuning() of a core made like the scenarios' (sim constants, corpse field, Rally, the plague burst, the colossus ...)
var RR := 0.0     ## the robber's radius (enemies.json): what the dummies and victims stand at
var BITE := 0.0   ## the robber's damage
var SAC := 0.0    ## the sac's damage


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL core_thralls: " + what)


## `consts` are the scenario's own overrides of the core's sim constants (a probe of the owner's limit sets the thrall's own limit wide, and the reverse).
func make(seed_: int = 31, consts: Dictionary = {}) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	DmCoreData.load_all(c, data_dir)
	c.load_sim_consts(DmCoreData.consts(OLD, OLD_CONSTS))
	if not consts.is_empty():
		c.load_sim_consts(consts)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	tick_no = 0
	return c


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


## Steps n ticks; every event is appended with the tick it came in.
func steps(c: RefCounted, n: int, log: Array = []) -> void:
	for i in n:
		c.step(DT)
		tick_no += 1
		for e in events(c):
			e["tick"] = tick_no
			log.append(e)


## Steps until pred(event) matches (returns that event, with its tick) or max ticks pass (returns {}).
func run_until(c: RefCounted, pred: Callable, max_ticks: int, log: Array = []) -> Dictionary:
	for i in max_ticks:
		var hit := {}
		c.step(DT)
		tick_no += 1
		for e in events(c):
			e["tick"] = tick_no
			log.append(e)
			if hit.is_empty() and pred.call(e):
				hit = e
		if not hit.is_empty():
			return hit
	return {}


## Ticks for a timer that gains 1/60 per tick to reach `amount` (>=), and for a countdown that loses `rate` x 1/60 to reach <= 0.
func ticks_until(amount: float) -> int:
	var t := 0.0
	var n := 0
	while t < amount:
		t += DT
		n += 1
	return n


func countdown(x0: float, rate: float = 1.0) -> int:
	var x := x0
	var n := 0
	while x > 0.0:
		x -= DT * 1.0 * rate
		n += 1
	return n


func rise_ticks() -> int:
	return ticks_until(K["THRALL_RISE_TIME"])


## The status table's index of a status (the wire id), the rule table in DmStatusRules order.
func sid(name: String) -> int:
	return DmStatusRules.IDS.find(name)


## A status's rule (the table the core is given, DmStatusRules): dur, move, atk, taken ...
func rule(name: String) -> Dictionary:
	return DmStatusRules.build(data["abilities"], data["statuses"], data["enemies"])[sid(name)]


## damage_scale(level) of combat/enemies.json: base + per_level x (level - 1).
func dscale(level: int) -> float:
	var ds: Dictionary = data["combat"]["damage_scale"]
	return float(ds["base"]) + float(ds["per_level"]) * float(level - 1)


## Damage taken with `stacks` of Fracture on the body: 1 + stacks x perStack, the stacks held to maxStacks.
func fracture_taken(stacks: int) -> float:
	var f: Dictionary = data["abilities"]["FRACTURE"]
	return 1.0 + minf(float(stacks), float(f["maxStacks"])) * float(f["perStack"])


## How far (on the thrall's side of an enemy) a dummy robber stands to be just in reach of a thrall whose range is `range_`: its radius counts.
func in_reach(range_: float = 1.3) -> float:
	return range_ + RR - 0.05


func hero(c: RefCounted, at: Vector2) -> int:
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, at, true)
	return h


func boss(c: RefCounted, at: Vector2) -> int:
	var b: int = c.add_external(1, BOSS_R, 1.0)
	c.set_external(b, at, true)
	return b


func stats(kind: String, extra: Dictionary = {}) -> Dictionary:
	var b: Array = BASE.get(kind, [])
	if kind == "colossus":
		var col: Dictionary = data["runes"]["RUNE_TUNING"]["colossus"]
		b = [col["range"], col["interval"], col["speed"]]
	var d := {"kind": kind, "hp": 40.0, "maxHp": 40.0, "damage": 10.0, "attackInterval": b[1], "range": b[0], "speed": b[2], "empowered": false, "champion": false, "allyHeal": 0.0}
	d.merge(extra, true)
	return d


func raise(c: RefCounted, owner: int, kind: String, at: Vector2, cap: float = 6.0, extra: Dictionary = {}) -> int:
	return c.raise_thrall(stats(kind, extra), owner, at, 0.0, cap)


## Where rank r of n sits around the owner (DmThrall._follow).
func seat(at: Vector2, rank: int, count: int) -> Vector2:
	var ang := float(rank) / float(maxi(3, count)) * TAU + PI
	return Vector2(at.x + sin(ang) * SEAT_R, at.y + cos(ang) * SEAT_R)


## A still enemy to hit: stunned for good, a lot of health, no damage.
func dummy(c: RefCounted, at: Vector2, def: String = "robber") -> int:
	var e: int = c.spawn_enemy(def, at, 1, 1000.0, 0.0, false, "graves", false)
	c.stun(e, 1.0e6)
	return e


func pos_of(c: RefCounted, id: int) -> Vector2:
	return c.thrall_info(id)["pos"]


func _init() -> void:
	data_dir = "res://"
	for n in ["enemies", "runes", "abilities", "statuses", "fen", "gameplay_legendary"]:
		data[n] = DmCoreData.json(data_dir.path_join("data/content/%s.json" % n))
	data["combat"] = DmCoreData.json(data_dir.path_join("data/combat/enemies.json"))
	K = make().tuning()
	RR = float(data["enemies"]["ENEMIES"]["robber"]["radius"])
	BITE = float(data["enemies"]["ENEMIES"]["robber"]["damage"])
	SAC = float(data["enemies"]["ENEMIES"]["sac"]["damage"])
	tuning_matches_data()
	raise_and_rise()
	caps_and_room()
	formation_and_leash()
	scan_and_leash()
	bosses_and_edges()
	swing_numbers()
	kinds()
	enemies_choose_thralls()
	enemy_blows()
	deaths_and_bursts()
	statuses_on_thralls()
	rally()
	separation()
	legion_queries()
	tick_order()
	if fails == 0:
		print("PASS core_thralls %d checks" % checks)
	quit(1 if fails > 0 else 0)


## The numbers compiled into the core equal what the data files and the GDScript constants say today.
func tuning_matches_data() -> void:
	var bare: RefCounted = ClassDB.instantiate("DmCore")
	var before: Dictionary = bare.tuning()
	var c := make()
	var after: Dictionary = c.tuning()
	var bad := []
	for k: String in after:
		if not before.has(k) or not is_equal_approx(float(before[k]), float(after[k])):
			bad.append(k)
	check(bad.is_empty(), "the defaults compiled into the core equal the data (%s)" % str(bad))
	var cs := DmCoreData.consts(data_dir)
	cs.merge(DmCoreData.consts(OLD, OLD_CONSTS), true)
	check(after["THRALL_LEASH"] == cs["THRALL_LEASH"] and after["CORPSE_S"] == cs["CORPSE_S"] and after["TOXIC_TICK"] == cs["TOXIC_TICK"] and after["MAX_CORPSES"] == int(cs["MAX_CORPSES"]), "the constants come from sim_consts.gd, dm_corpse_field.gd and dm_thrall.gd")
	check(after["RALLY.damageMult"] == float(data["abilities"]["RALLY"]["damageMult"]) and after["colossus.slots"] == float(data["runes"]["RUNE_TUNING"]["colossus"]["slots"]), "Rally and the Colossus come from the content files")


## Raising: the stats go in as given, the thrall rises for THRALL_RISE_TIME (not a target, no brain), then is IDLE; a missing or dead owner raises nothing.
func raise_and_rise() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	events(c)
	var t := raise(c, h, "warrior", Vector2(2, 0))
	check(t > h, "a thrall gets an id after the hero's")
	var info: Dictionary = c.thrall_info(t)
	check(info["kind"] == "warrior" and info["owner"] == h and info["state"] == RISING and info["hp"] == 40.0 and info["damage"] == 10.0 and info["interval"] == 1.0 and info["range"] == 1.3 and info["speed"] == 5.6, "the stats are the dictionary's")
	check(is_equal_approx(info["attack_cd"], 0.4) and info["radius"] == 0.4 and info["swing_n"] == 0 and info["target"] == 0, "first swing cooldown 0.4 s, radius 0.4")
	var ev := events(c)
	check(ev.size() == 1 and ev[0]["type"] == EV_RAISED and ev[0]["id"] == t and Array(ev[0]["ints"]) == [0, h, 0, 0, 0] and ev[0]["floats"][0] == 2.0 and ev[0]["floats"][3] == 40.0, "a raised event: kind, owner, slot, flags; x, z, yaw, max hp")
	check(raise(c, 9999, "warrior", Vector2(2, 0)) == 0, "no owner, no thrall")
	var big: int = raise(c, h, "colossus", Vector2(0, 5))
	check(c.thrall_info(big)["radius"] == 0.8 and c.thrall_info(big)["kind_id"] == 7, "a colossus is wider (0.8, compiled in)")
	var n := rise_ticks()
	var log := []
	steps(c, n - 1, log)
	check(c.thrall_info(t)["state"] == RISING and of_type(log, EV_T_STATE).is_empty(), "still rising one tick before its rise ends")
	steps(c, 1, log)
	var st := of_type(log, EV_T_STATE).filter(func(e: Dictionary) -> bool: return e["id"] == t)
	check(st.size() == 1 and st[0]["tick"] == n and Array(st[0]["ints"]) == [RISING, IDLE], "RISING -> IDLE on tick %d (THRALL_RISE_TIME)" % n)
	# A dead owner raises nothing.
	c.set_external(h, Vector2(0, 0), false)
	check(raise(c, h, "warrior", Vector2(2, 0)) == 0, "a dead owner raises nothing")
	# Rising bodies are not enemy targets and do not act; the enemy takes the thrall once it is up.
	var d := make()
	var far := hero(d, Vector2(minf(20.0, K["THRALL_TELEPORT"] - 0.5), 0))   # beyond the enemy's aggro range (15, compiled in) and inside the teleport
	var th := raise(d, far, "warrior", Vector2(0, 0))
	var e: int = d.spawn_enemy("robber", Vector2(0, 2), 1, 1.0, 1.0, false, "graves", false)
	var l2 := []
	steps(d, n - 1, l2)
	check(of_type(l2, EV_STATE).filter(func(x: Dictionary) -> bool: return x["id"] == e).is_empty(), "a rising thrall is not a target: the enemy beside it stays idle")
	var chase := run_until(d, func(x: Dictionary) -> bool: return x["type"] == EV_STATE and x["id"] == e and x["ints"][1] == CHASE, 30, l2)
	check(not chase.is_empty() and chase["tick"] <= n + 16 and d.enemy_info(e)["target"] == th, "once up, the thrall is chosen within a scan (tick %d)" % chase.get("tick", -1))


## make_room: over the cap the oldest ordinary thrall crumbles first, a Colossus last (it takes `colossus.slots` places); a new Colossus replaces the old one.
func caps_and_room() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var ids := []
	for i in 5:
		events(c)
		ids.append(raise(c, h, "warrior", Vector2(i, 8), 3.0))
		if i == 3:
			check(Array(c.last_crumbled()) == [ids[0]], "the 4th under cap 3 crumbles the oldest")
			var ev := events(c)
			check(ev.size() == 3 and ev[0]["type"] == EV_T_STATE and ev[1]["type"] == EV_T_DIED and ev[1]["id"] == ids[0] and ev[1]["ints"][0] == CRUMBLED and ev[2]["type"] == EV_RAISED, "dead and crumbled first, then the newcomer is raised")
	check(c.thrall_count(h) == 3 and not c.thrall_info(ids[0])["alive"] and not c.thrall_info(ids[1])["alive"] and ids.slice(2).all(func(i: int) -> bool: return c.thrall_info(i)["alive"]), "cap 3 holds, the oldest two crumbled, the newest kept")
	# A Colossus (K slots places) under a cap of slots + 1: ordinary ones crumble, oldest first, until it fits.
	var slots := int(K["colossus.slots"])
	var cap := float(slots + 1)
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var w := []
	for i in slots + 1:
		w.append(raise(d, h2, "warrior", Vector2(i, 8), cap))
	var col := raise(d, h2, "colossus", Vector2(0, 9), cap)
	check(Array(d.last_crumbled()) == w.slice(0, slots) and d.thrall_count(h2) == 2 and d.thrall_places(h2) == cap, "a colossus crumbles the %d oldest to fit cap %d (places %s)" % [slots, cap, str(d.thrall_places(h2))])
	# A Colossus goes last: a warrior raised into [colossus, warrior] at the cap takes the warrior, not the colossus.
	var again := raise(d, h2, "warrior", Vector2(slots + 1, 8), cap)
	check(Array(d.last_crumbled()) == [w[slots]] and d.thrall_info(col)["alive"] and d.thrall_info(again)["alive"], "an ordinary thrall crumbles before a colossus")
	var third := raise(d, h2, "warrior", Vector2(slots + 2, 8), float(slots))
	check(not d.thrall_info(col)["alive"] and d.thrall_count(h2) == 1 and third > 0, "when nothing ordinary is left, the colossus goes")
	# A new Colossus replaces the old one even with room (and the old one is not in `crumbled`).
	var e := make()
	var h3 := hero(e, Vector2(0, 0))
	var c1 := raise(e, h3, "colossus", Vector2(0, 8), 9.0)
	var c2 := raise(e, h3, "colossus", Vector2(0, 9), 9.0)
	check(not e.thrall_info(c1)["alive"] and e.thrall_info(c2)["alive"] and e.last_crumbled().is_empty() and e.thrall_count(h3) == 1, "a new colossus replaces the old one")
	# Another owner's legion is untouched; no cap (cap < 0) never crumbles.
	var h4 := hero(e, Vector2(30, 0))
	var other := raise(e, h4, "warrior", Vector2(30, 5), 1.0)
	var free := raise(e, h3, "warrior", Vector2(0, 10), -1.0)
	check(e.thrall_info(other)["alive"] and e.thrall_info(free)["alive"] and e.thrall_count() == 3, "caps are per owner; cap < 0 means none")


## The formation: seats on a 1.9 m ring by rank among the living (angle rank/max(3, n) x TAU + PI), speeds 1.35x beyond 6 m, a catch-up pace near a moving
## seat, a teleport to the owner beyond THRALL_TELEPORT.
func formation_and_leash() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var ts := []
	for i in 4:
		ts.append(raise(c, h, "warrior", Vector2(-6 + i, 7), 6.0))
	var slots := ts.map(func(t: int) -> int: return c.thrall_info(t)["formation_slot"])
	check(slots == [0, 1, 2, 3] and ts.all(func(t: int) -> bool: return c.thrall_info(t)["formation_count"] == 4), "slots 0..3 dealt in order, count 4")
	steps(c, 480)
	var ok := true
	for i in 4:
		var info: Dictionary = c.thrall_info(ts[i])
		ok = ok and info["formation_rank"] == i and pos_of(c, ts[i]).distance_to(seat(Vector2(0, 0), i, 4)) <= float(K["FOLLOW_ARRIVE"]) + 0.005   # it stops once within FOLLOW_ARRIVE of the seat
	check(ok, "four thralls settle on the 1.9 m ring, rank by slot")
	# One falls: the seats are dealt again among the living, and a newcomer takes the free slot.
	events(c)
	c.kill_thrall(ts[1], "sacrificed")
	var rest := [ts[0], ts[2], ts[3]]
	check(rest.map(func(t: int) -> int: return c.thrall_info(t)["formation_rank"]) == [0, 1, 2] and rest.all(func(t: int) -> bool: return c.thrall_info(t)["formation_count"] == 3), "ranks are dealt again among the living")
	steps(c, 420)
	ok = true
	for i in 3:
		ok = ok and pos_of(c, rest[i]).distance_to(seat(Vector2(0, 0), i, 3)) <= float(K["FOLLOW_ARRIVE"]) + 0.005
	check(ok, "and they walk to the new seats")
	var n4 := raise(c, h, "warrior", Vector2(0, 9), 6.0)
	check(c.thrall_info(n4)["formation_slot"] == 1 and c.thrall_info(n4)["formation_rank"] == 1 and c.thrall_info(ts[2])["formation_rank"] == 2, "a newcomer takes the lowest free slot (1) and its rank")
	# Pace: beyond 6 m of its seat a thrall walks at 1.35x, within it at 1.0x; a settled one stands still.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var t := raise(d, h2, "warrior", Vector2(0, -12))
	steps(d, rise_ticks() + 1)
	check(is_equal_approx(d.thrall_ground_speeds()[0], 5.6 * 1.35), "10 m from its seat: 1.35x pace (%.3f)" % d.thrall_ground_speeds()[0])
	d.set_thrall_pos(t, Vector2(0, -5))
	steps(d, 1)
	check(is_equal_approx(d.thrall_ground_speeds()[0], 5.6), "3 m from its seat: 1.0x pace (%.3f)" % d.thrall_ground_speeds()[0])
	var e := make()
	var h3 := hero(e, Vector2(0, 0))
	var s := raise(e, h3, "warrior", seat(Vector2(0, 0), 0, 1))
	steps(e, rise_ticks() + 30)
	check(e.thrall_info(s)["state"] == IDLE and e.thrall_ground_speeds()[0] == 0.0, "on its seat it idles")
	# Following a walking owner: the seat's own velocity feeds a catch-up pace, so the thrall keeps pace instead of trailing or overshooting.
	var walk := 0.05
	for i in 90:
		e.set_external(h3, Vector2(walk * float(i + 1), 0), true)
		steps(e, 1)
	var gap := pos_of(e, s).distance_to(seat(Vector2(walk * 90.0, 0), 0, 1))
	var v: float = e.thrall_ground_speeds()[0]
	check(gap < 0.3 and v > 2.5 and v < 4.0, "keeps pace with an owner walking 3 m/s: %.2f m behind its seat at %.2f m/s" % [gap, v])
	# Leash: THRALL_TELEPORT and under it walks, beyond it jumps next to the owner and drops its target.
	var tp: float = K["THRALL_TELEPORT"]
	var f := make()
	var h4 := hero(f, Vector2(0, 0))
	var u := raise(f, h4, "warrior", Vector2(0, -1.9))
	steps(f, rise_ticks() + 1)
	var u_at := pos_of(f, u)
	f.set_external(h4, u_at + Vector2(tp - 0.1, 0), true)
	steps(f, 1)
	check(pos_of(f, u).distance_to(u_at + Vector2(tp - 0.1, 0)) > tp - 4.0, "%.1f m from its owner it walks (%.1f m)" % [tp - 0.1, pos_of(f, u).distance_to(u_at + Vector2(tp - 0.1, 0))])
	f.set_thrall_pos(u, Vector2(0, 0))
	f.set_external(h4, Vector2(tp + 0.1, 0), true)
	steps(f, 1)
	var close := pos_of(f, u).distance_to(Vector2(tp + 0.1, 0))
	check(close < 1.6, "%.1f m away it teleports next to its owner (%.2f m, the offset is within +-1 per axis)" % [tp + 0.1, close])


## Probes whether a thrall (alone, owner at the origin, seat (0, -1.9)) takes an enemy at `at` within a scan of getting up, with the scenario's own `consts`.
func acquires(at: Vector2, consts: Dictionary = {}, def: String = "robber") -> bool:
	var c := make(31, consts)
	var h := hero(c, Vector2(0, 0))
	var t := raise(c, h, "warrior", seat(Vector2(0, 0), 0, 1))
	var e := dummy(c, at, def)
	steps(c, rise_ticks() + 40)
	return c.thrall_info(t)["target"] == e


## The scan: the nearest enemy within ENGAGE_RANGE of the thrall AND leash - 2 of the owner, taken within 0.25 s; kept while within the leash of the owner.
func scan_and_leash() -> void:
	var leash: float = K["THRALL_LEASH"]
	var reach_o := leash - 2.0   # from the owner
	var engage: float = K["ENGAGE_RANGE"]
	var owner_only := {"ENGAGE_RANGE": WIDE}   # only the owner's limit counts
	check(acquires(Vector2(0, -(reach_o - 0.1)), owner_only), "an enemy %.1f m from the owner (< leash - 2) is taken" % (reach_o - 0.1))
	check(not acquires(Vector2(0, -(reach_o + 0.2)), owner_only), "%.1f m from the owner (> leash - 2): ignored" % (reach_o + 0.2))
	var thrall_only := {"THRALL_LEASH": WIDE}   # only the thrall's own limit counts
	check(acquires(Vector2(0, -(engage + SEAT_R - 0.1)), thrall_only), "an enemy %.1f m from the thrall (< ENGAGE_RANGE) is taken" % (engage - 0.1))
	check(not acquires(Vector2(0, engage - SEAT_R + 0.9), thrall_only), "%.1f m from the owner but %.1f m from the thrall (> ENGAGE_RANGE): ignored" % [engage - SEAT_R + 0.9, engage + 0.9])
	# Acquisition within one scan period of getting up; the scan runs again after a loss.
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var t := raise(c, h, "warrior", seat(Vector2(0, 0), 0, 1))
	var e := dummy(c, Vector2(0, -5))
	var log := []
	steps(c, rise_ticks() - 1, log)
	var first := 0
	for i in 40:
		steps(c, 1, log)
		if c.thrall_info(t)["target"] == e:
			first = i + 1
			break
	check(first >= 1 and first <= ticks_until(0.25) + 1, "taken within a scan (0.25 s) of getting up (%d ticks)" % first)
	# Kept while within the leash of the OWNER: 0.1 m inside holds, 0.1 m outside lets go at once (no scan needed).
	c.set_external(h, Vector2(0, leash - 0.1 - 5.0), true)   # the dummy at (0, -5) is leash - 0.1 away
	steps(c, 1)
	check(c.thrall_info(t)["target"] == e, "%.1f m from the owner: kept" % (leash - 0.1))
	c.set_external(h, Vector2(0, leash + 0.1 - 5.0), true)
	steps(c, 1)
	check(c.thrall_info(t)["target"] == 0, "%.1f m from the owner: dropped on the next tick" % (leash + 0.1))
	# After a loss it scans again within the period once the enemy is back in reach.
	c.set_external(h, Vector2(0, 0), true)
	var back := 0
	for i in 120:
		steps(c, 1)
		if c.thrall_info(t)["target"] == e:
			back = i + 1
			break
	check(back > 0 and back <= 120, "taken again once it is within reach (%d ticks)" % back)
	# A dead or burrowed enemy is not a target; a dead one is dropped at once.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var t2 := raise(d, h2, "warrior", seat(Vector2(0, 0), 0, 1))
	var v := dummy(d, Vector2(0, -3))
	steps(d, rise_ticks() + 30)
	check(d.thrall_info(t2)["target"] == v, "engaged with the dummy")
	d.damage(v, 1.0e9, h2)
	steps(d, 1)
	check(d.thrall_info(t2)["target"] == 0, "a dead target is dropped on the next tick")
	var g: int = d.spawn_enemy("ghoul", Vector2(0, -9), 1, 1.0, 0.0, false, "graves", true)   # rising ghouls start underground
	var taken := false
	var under := 0
	for i in 40:
		steps(d, 1)
		if d.enemy_info(g)["state"] == 8:   # BURROW
			under += 1
			taken = taken or d.thrall_info(t2)["target"] == g
	check(under > 20 and not taken, "a burrowed enemy is not taken (%d ticks underground)" % under)


## A boss is an external of kind 1: it counts from its edge (its radius) in the scan limit and the leash, is engaged at attack_range + its radius, and a blow
## on it is an event for GDScript to route to the brain.
func bosses_and_edges() -> void:
	var leash: float = K["THRALL_LEASH"]
	var reach_o := leash - 2.0
	var engage: float = K["ENGAGE_RANGE"]
	var probe := func(at: Vector2, consts: Dictionary) -> bool:
		var c := make(31, consts)
		var h := hero(c, Vector2(0, 0))
		var t := raise(c, h, "warrior", seat(Vector2(0, 0), 0, 1))
		var b := boss(c, at)
		steps(c, rise_ticks() + 40)
		return c.thrall_info(t)["target"] == b
	var owner_only := {"ENGAGE_RANGE": WIDE}
	check(probe.call(Vector2(0, -(reach_o + BOSS_R - 0.2)), owner_only), "a boss %.1f m from the owner is taken (its edge is %.1f <= leash - 2)" % [reach_o + BOSS_R - 0.2, reach_o - 0.2])
	check(not probe.call(Vector2(0, -(reach_o + BOSS_R + 0.1)), owner_only), "a boss %.1f m from the owner is not (its edge is %.1f > leash - 2)" % [reach_o + BOSS_R + 0.1, reach_o + 0.1])
	var thrall_only := {"THRALL_LEASH": WIDE}
	check(probe.call(Vector2(0, -(engage + BOSS_R - 0.3 + SEAT_R)), thrall_only), "a boss whose centre is %.1f m from the thrall (its edge %.1f <= ENGAGE_RANGE) is taken: the thrall's own limit is edge-counted too" % [engage + BOSS_R - 0.3, engage - 0.3])
	check(not probe.call(Vector2(0, -(engage + BOSS_R + 0.3 + SEAT_R)), thrall_only), "and one whose edge is %.1f from the thrall is not" % (engage + 0.3))
	var c := make(31, owner_only)
	var h := hero(c, Vector2(0, 0))
	var t := raise(c, h, "warrior", seat(Vector2(0, 0), 0, 1))
	var at_z := -(leash - 1.8)   # the boss: inside the owner's limit
	var b := boss(c, Vector2(0, at_z))
	steps(c, rise_ticks() + 30)
	check(c.thrall_info(t)["target"] == b, "taken: %.1f m from the owner" % -at_z)
	# Kept until its edge is the leash from the owner: 0.1 m inside keeps, 0.3 m outside lets go.
	c.set_external(h, Vector2(0, at_z + leash + BOSS_R - 0.1), true)
	steps(c, 1)
	check(c.thrall_info(t)["target"] == b, "a boss %.1f m from the owner (%.1f from its edge): kept" % [leash + BOSS_R - 0.1, leash - 0.1])
	c.set_external(h, Vector2(0, at_z + leash + BOSS_R + 0.3), true)
	steps(c, 1)
	check(c.thrall_info(t)["target"] == 0, "a boss %.1f m from the owner (%.1f from its edge): dropped" % [leash + BOSS_R + 0.3, leash + 0.3])
	# An unhittable boss (alive = false) is neither taken nor kept.
	c.set_external(h, Vector2(0, 0), true)
	c.set_external(b, Vector2(0, at_z), false)
	steps(c, 60)
	check(c.thrall_info(t)["target"] == 0, "an unhittable boss is not a target")
	# Engaging: close in to attack_range + the boss's radius from its centre, then swing; the blow is an event, not core damage.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var t2 := raise(d, h2, "warrior", seat(Vector2(0, 0), 0, 1))
	var b2 := boss(d, Vector2(0, -6))
	var log := []
	steps(d, rise_ticks() + 200, log)
	var gap := pos_of(d, t2).distance_to(Vector2(0, -6))
	check(gap <= 1.3 + BOSS_R and gap > 1.3 + BOSS_R - 0.2, "it stops at attack_range + the boss's radius from its centre (%.2f m)" % gap)
	var hits := of_type(log, EV_HIT_BOSS)
	check(hits.size() >= 2 and hits[0]["id"] == t2 and hits[0]["ints"][0] == b2 and hits[0]["ints"][1] == 0 and hits[0]["floats"][0] == 10.0, "swings on the boss come out as events (boss, thrall kind; damage 10)")
	check(of_type(log, EV_DAMAGED).is_empty(), "and no core damage was dealt to anything")


## The swing: instant, the same tick as the target is taken, damage x Rally x Hag's curse x the Spear mark x the thrall's damage dealt, on a cadence of
## interval / attack rate; the struck enemy turns on the thrall and the thrall gets the kill.
func swing_numbers() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var t := raise(c, h, "warrior", seat(Vector2(0, 0), 0, 1))
	var e_z := -(SEAT_R + in_reach())   # in reach without walking (range 1.3 + the robber's radius)
	var e := dummy(c, Vector2(0, e_z))
	var log := []
	steps(c, rise_ticks() + 200, log)
	var swings := of_type(log, EV_SWING)
	check(swings.size() >= 3 and swings[0]["tick"] <= rise_ticks() + 16, "the first swing comes with the first scan (tick %d)" % (swings[0]["tick"] if not swings.is_empty() else -1))
	var dmg0 := of_type(log, EV_DAMAGED).filter(func(x: Dictionary) -> bool: return x["id"] == e)
	check(dmg0[0]["tick"] == swings[0]["tick"] and dmg0[0]["ints"][0] == t and dmg0[0]["floats"][0] == 10.0, "the blow lands in the same tick: the thrall is the source, 10 damage")
	var types := log.filter(func(x: Dictionary) -> bool: return x["tick"] == swings[0]["tick"]).map(func(x: Dictionary) -> int: return x["type"])
	check(types.find(EV_T_STATE) < types.find(EV_DAMAGED) and types.find(EV_DAMAGED) < types.find(EV_SWING), "order in the tick: the thrall turns to ATTACK, the enemy is hurt, then hit_dealt")
	check(swings[0]["ints"][0] == 1 and swings[0]["ints"][1] == e and swings[0]["floats"][2] == 10.0 and is_equal_approx(swings[0]["floats"][1], e_z), "swing event: counter 1, the target, aim at it, damage 10")
	check(swings[1]["tick"] - swings[0]["tick"] == countdown(1.0), "cadence: one interval (%d ticks)" % (swings[1]["tick"] - swings[0]["tick"]))
	check(c.enemy_info(e)["target"] == t, "the struck enemy turns on the thrall")
	# State machine: ATTACK for 0.5 s between swings, then IDLE.
	var states := of_type(log, EV_T_STATE).filter(func(x: Dictionary) -> bool: return x["tick"] > swings[0]["tick"] and x["tick"] <= swings[1]["tick"])
	check(states.size() == 2 and states[0]["ints"][1] == IDLE and states[1]["ints"][1] == ATTACK and states[0]["tick"] - swings[0]["tick"] >= ticks_until(0.5), "ATTACK relaxes to IDLE once state_t > 0.5 s, and the next swing is ATTACK again")
	# Rally right after a swing: + RALLY.damageMult damage, the cooldown runs RALLY.attackSpeedMult faster, + RALLY.healFrac health; it lasts RALLY.durationS.
	var rally_s: float = K["RALLY.durationS"]
	var rally_dmg: float = K["RALLY.damageMult"]
	var rally_rate: float = K["RALLY.attackSpeedMult"]
	var heal: float = K["RALLY.healFrac"]
	c.set_thrall_stats(t, {"hp": 10.0})
	var l2 := []
	run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_SWING, 200, l2)
	c.rally_thralls(h, rally_s)
	check(is_equal_approx(c.thrall_info(t)["hp"], 10.0 + 40.0 * heal) and is_equal_approx(c.thrall_info(t)["rally_t"], rally_s), "rally: + healFrac of max health, RALLY.durationS")
	var l3 := []
	var sw1 := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_SWING, 200, l3)
	var rallied_gap: int = sw1["tick"] - (l2.back()["tick"] if not l2.is_empty() else 0)
	check(is_equal_approx(sw1["floats"][2], 10.0 * rally_dmg) and rallied_gap == countdown(1.0, rally_rate), "rallied: %s damage after %d ticks (1.0 s at x%s)" % [10.0 * rally_dmg, rallied_gap, rally_rate])
	steps(c, ticks_until(rally_s) + 60)
	var l4 := []
	var sw2 := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_SWING, 200, l4)
	check(sw2["floats"][2] == 10.0 and c.thrall_info(t)["rally_t"] == 0.0, "after its time the rally is over: 10 damage again")
	# Hag's curse, the Spear mark x1.5, the hex on the thrall (damage dealt x BONE_HEX.damageMult), all together with Rally.
	var curse: float = K["HAG_HEX.thrallDamageMult"]
	var hex: float = data["statuses"]["BONE_HEX"]["damageMult"]
	var all_mults := 10.0 * rally_dmg * curse * 1.5 * hex
	c.curse_thrall(t, rally_s)
	c.set_thrall_mark(t, 1.5)
	c.apply_status(t, "hex", e, 1)
	c.rally_thralls(h, rally_s)
	var l5 := []
	var sw3 := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_SWING, 200, l5)
	check(absf(sw3["floats"][2] - all_mults) < 1.0e-3, "Rally x curse x mark x hex = %.4f (%.4f)" % [all_mults, sw3["floats"][2]])
	check(is_equal_approx(c.damage_dealt_mult(t), hex), "the thrall's own status set holds the hex")
	# The kill is the thrall's: died carries it as the source, and a corpse is laid.
	var k := make()
	var hk := hero(k, Vector2(0, 0))
	var tk := raise(k, hk, "warrior", seat(Vector2(0, 0), 0, 1))
	var ek: int = k.spawn_enemy("robber", Vector2(0, e_z), 1, 1.0 / float(data["enemies"]["ENEMIES"]["robber"]["hp"]), 0.0, false, "graves", false)   # 1 hp
	k.stun(ek, 1.0e6)
	var lk := []
	steps(k, rise_ticks() + 60, lk)
	var died := of_type(lk, EV_DIED)
	check(died.size() == 1 and died[0]["ints"][4] == tk and of_type(lk, EV_CORPSE_ADDED).size() == 1, "a thrall's kill credits the thrall and leaves a corpse")
	check(k.thrall_info(tk)["target"] == 0, "and the dead target is let go")
	# Archer: an instant ranged blow from 6.9 m, no closing in.
	var a := make()
	var ha := hero(a, Vector2(0, 0))
	var ta := raise(a, ha, "archer", seat(Vector2(0, 0), 0, 1))
	var ea := dummy(a, Vector2(0, -minf(SEAT_R + 6.9, K["THRALL_LEASH"] - 2.3)))   # within the owner's limit and the archer's range from its seat
	var la := []
	steps(a, rise_ticks() + 200, la)
	var shots := of_type(la, EV_SWING)
	check(shots.size() >= 2 and a.thrall_info(ta)["range"] == 7.5 and pos_of(a, ta).distance_to(seat(Vector2(0, 0), 0, 1)) < 0.01, "archer: shoots from range 7.5 without moving (%d shots)" % shots.size())
	check(of_type(la, EV_DAMAGED).filter(func(x: Dictionary) -> bool: return x["id"] == ea).size() == shots.size(), "each shot lands instantly (no projectile)")


## Kind extras: the wraith chills (and tells the allies to heal), the bone mage hexes, the colossus cleaves cleaveFrac of the blow within cleaveRadius (+ radius) of its target.
func kinds() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var t := raise(c, h, "wraith", seat(Vector2(0, 0), 0, 1), 6.0, {"allyHeal": 0.1})
	var e := dummy(c, Vector2(0, -6))
	var log := []
	steps(c, rise_ticks() + 40, log)
	var chill := sid("chill")
	var applied := of_type(log, EV_T_STATUS)
	check(not applied.is_empty() and applied[0]["id"] == t and applied[0]["ints"][0] == e and applied[0]["ints"][1] == chill and is_equal_approx(applied[0]["floats"][0], float(data["statuses"]["CHILL"]["durationS"])), "wraith: a status_applied event for chill, CHILL.durationS")
	check(c.statuses(e)[0] == chill and is_equal_approx(c.enemy_info(e)["speed_mult"], float(data["statuses"]["CHILL"]["moveMult"])), "wraith: the enemy is chilled in the core")
	var heal := of_type(log, EV_BELL_HEAL)
	check(not heal.is_empty() and is_equal_approx(heal[0]["floats"][2], 0.1) and of_type(log, EV_SWING).size() == heal.size(), "wraith with a Mourning Bell: a bell_heal each blow")
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var m := raise(d, h2, "bonemage", seat(Vector2(0, 0), 0, 1))
	var e2 := dummy(d, Vector2(0, -6))
	var l2 := []
	steps(d, rise_ticks() + 40, l2)
	var hexed := of_type(l2, EV_T_STATUS)
	check(not hexed.is_empty() and hexed[0]["ints"][1] == sid("hex") and is_equal_approx(hexed[0]["floats"][0], float(data["statuses"]["BONE_HEX"]["durationS"])) and d.statuses(e2)[0] == sid("hex"), "bone mage: hex (BONE_HEX.durationS) on the enemy; a plain wraith heals no one" if of_type(l2, EV_BELL_HEAL).is_empty() else "bone mage hexes")
	# Colossus cleave: 0.6 x the blow on others within 2.4 + radius of the struck one.
	var f := make()
	var h3 := hero(f, Vector2(0, 0))
	var cleave_r: float = K["colossus.cleaveRadius"]
	var cleave: float = K["colossus.cleaveFrac"]
	var col := raise(f, h3, "colossus", seat(Vector2(0, 0), 0, 1), 9.0, {"damage": 50.0})
	var main := dummy(f, Vector2(0, -3.8))
	var near := dummy(f, Vector2(cleave_r - 0.4, -3.8))                 # 0.4 inside the radius of the main one
	var edge_in := dummy(f, Vector2(-(cleave_r + RR - 0.01), -3.8))     # just inside radius + its own radius
	var edge_out := dummy(f, Vector2(0, -3.8 - (cleave_r + RR + 0.05)))  # just outside it
	var bs := boss(f, Vector2(cleave_r - 0.4, -5.8))   # a boss within the radius + its own radius of the main one
	var l3 := []
	steps(f, rise_ticks() + 40, l3)
	var first_swing: Dictionary = of_type(l3, EV_SWING)[0]
	var hp := func(id: int) -> float: return f.enemy_info(id)["max_hp"] - f.enemy_info(id)["hp"]
	var main_hits := of_type(l3, EV_DAMAGED).filter(func(x: Dictionary) -> bool: return x["id"] == main)
	var near_hits := of_type(l3, EV_DAMAGED).filter(func(x: Dictionary) -> bool: return x["id"] == near)
	check(first_swing["ints"][1] == main and main_hits[0]["floats"][0] == 50.0, "colossus: the target takes the whole blow (50)")
	check(is_equal_approx(near_hits[0]["floats"][0], 50.0 * cleave) and not of_type(l3, EV_DAMAGED).filter(func(x: Dictionary) -> bool: return x["id"] == edge_in).is_empty(), "colossus: neighbours within cleaveRadius + radius take cleaveFrac x the blow (%s)" % (50.0 * cleave))
	check(of_type(l3, EV_DAMAGED).filter(func(x: Dictionary) -> bool: return x["id"] == edge_out).is_empty(), "colossus: one beyond cleaveRadius + radius is spared")
	var bh := of_type(l3, EV_HIT_BOSS)
	check(not bh.is_empty() and bh[0]["ints"][0] == bs and is_equal_approx(bh[0]["floats"][0], 50.0 * cleave), "colossus: a boss in the cleave comes out as an event for cleaveFrac x the blow")
	check(of_type(l3, EV_SWING).size() >= 1 and hp.call(main) >= 50.0, "colossus: one swing event per blow")


## Enemies pick thralls by weight: distance^2 x weight^2 (thrall WEIGHT_OTHER, shieldbearer WEIGHT_SHIELD), heroes first on a tie, strict <; a thrall within 15 / weight m counts (the aggro range is compiled in).
func enemies_choose_thralls() -> void:
	var w_other: float = K["WEIGHT_OTHER"]
	var w_shield: float = K["WEIGHT_SHIELD"]
	# `setup`: a lone thrall frozen where it stands, the hero where given, a robber (spawned idle) at the origin; returns what the robber targets
	# the tick it turns on something.
	var pick := func(kind: String, thrall_at: Vector2, hero_at: Vector2) -> int:
		var c := make()
		var h := hero(c, hero_at)
		var t := raise(c, h, kind, thrall_at)
		steps(c, rise_ticks())   # a stun before the rise ends would keep it rising for good (the stun branch skips _think)
		c.stun(t, 1.0e6)
		var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 0.0, false, "graves", false)
		var chase := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_STATE and x["id"] == e and x["ints"][1] == CHASE, 20)
		if chase.is_empty():
			return 0
		var who: int = c.enemy_info(e)["target"]
		return -1 if who == h else (1 if who == t else 2)
	check(pick.call("warrior", Vector2(0, 10.0 / w_other + 0.4), Vector2(0, 10)) == -1, "a warrior at %.2f m (x%s) loses to the hero at 10 m" % [10.0 / w_other + 0.4, w_other])
	check(pick.call("warrior", Vector2(0, 10.0 / w_other - 0.1), Vector2(0, 10)) == 1, "a warrior at %.2f m beats the hero at 10 m" % (10.0 / w_other - 0.1))
	check(pick.call("warrior", Vector2(0, 15.0 / w_other + 0.4), Vector2(0, 40)) == 0, "a thrall at %.2f m counts as more than 15: outside aggro 15" % (15.0 / w_other + 0.4))
	check(pick.call("warrior", Vector2(0, 15.0 / w_other - 0.1), Vector2(0, 40)) == 1, "a thrall at %.2f m is inside" % (15.0 / w_other - 0.1))
	check(pick.call("shieldbearer", Vector2(0, 8.0 / w_shield - 1.5), Vector2(0, 8)) == 1, "a shieldbearer draws aggro from further than the hero (%.2f m x%s < 8)" % [8.0 / w_shield - 1.5, w_shield])
	# Ties go to raise order: two warriors the same distance away, the first raised wins; a hero beats a thrall that ties.
	var c := make()
	var h := hero(c, Vector2(0, 60))
	var t1 := raise(c, h, "warrior", Vector2(6, 0))
	var t2 := raise(c, h, "warrior", Vector2(-6, 0))
	steps(c, rise_ticks())
	c.stun(t1, 1.0e6)
	c.stun(t2, 1.0e6)
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 0.0, false, "graves", false)
	run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_STATE and x["id"] == e and x["ints"][1] == CHASE, 20)
	check(c.enemy_info(e)["target"] == t1, "two thralls at the same distance: the one raised first (strict <)")
	# The enemy follows a better target: when the first one dies the next scan moves it to the other.
	c.kill_thrall(t1, "killed")
	run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_STATE, 60)
	steps(c, 20)
	check(c.enemy_info(e)["target"] == t2 or c.enemy_info(e)["target"] == 0, "a dead thrall is dropped from its target")


## Enemy blows on thralls: applied in the core with damage taken and the barrier, kill with reason killed, the body stays CORPSE_S; the area blows (cone,
## slam) and the hostile pools hurt thralls too; heroes still get events.
func enemy_blows() -> void:
	var c := make()
	var h := hero(c, Vector2(40, 40))
	var t := raise(c, h, "warrior", Vector2(0, 0), 6.0, {"hp": 200.0, "maxHp": 200.0})
	steps(c, rise_ticks())
	c.stun(t, 1.0e6)
	var r: int = c.spawn_enemy("robber", Vector2(0, 1.0), 1, 1.0, 1.0, false, "graves", false)
	var log := []
	var bite := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_T_DAMAGED, 300, log)
	check(not bite.is_empty() and bite["id"] == t and bite["ints"][0] == r and bite["floats"][0] == BITE and bite["floats"][1] == 200.0 - BITE, "a robber bite lands on the thrall for its damage (hp 200 -> %s)" % (200.0 - BITE))
	check(of_type(log, EV_HIT).is_empty() and c.thrall_info(t)["hp"] == 200.0 - BITE, "no event for GDScript: the core applied it")
	# Damage taken: Fracture x2 stacks.
	c.apply_status(t, "fracture", r, 2)
	var l2 := []
	var bite2 := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_T_DAMAGED, 300, l2)
	check(absf(bite2["floats"][0] - BITE * fracture_taken(2)) < 1.0e-4, "fracture (2 stacks) raises the damage taken to %.2f (%.3f)" % [BITE * fracture_taken(2), bite2["floats"][0]])
	c.remove_status(t, "fracture")
	# A barrier soaks first: one and a half bites absorbs the first bite and half of the second.
	c.apply_status(t, "barrier", 0, 1, -1.0, {"amount": BITE * 1.5, "cap": 1000.0})
	var hp0: float = c.thrall_info(t)["hp"]
	var l3 := []
	var b1 := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_T_DAMAGED, 300, l3)
	var b2 := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_T_DAMAGED, 300, l3)
	check(b1["floats"][0] == 0.0 and absf(b2["floats"][0] - BITE * 0.5) < 1.0e-4 and absf(c.thrall_info(t)["hp"] - (hp0 - BITE * 0.5)) < 1.0e-4, "a barrier of one and a half bites soaks the first bite (0) and half of the second (%s gets through)" % (BITE * 0.5))
	check(c.statuses(t).is_empty(), "and is used up")
	# The killing blow: reason killed, the source is the enemy, the legion shrinks, the body lingers CORPSE_S and then goes; the enemy lets go.
	c.set_thrall_stats(t, {"hp": 1.0})
	var l4 := []
	var fall := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_T_DIED, 300, l4)
	check(not fall.is_empty() and fall["id"] == t and fall["ints"][0] == KILLED and fall["ints"][1] == h and fall["ints"][2] == 0 and fall["ints"][3] == r, "died: reason killed, owner, kind, the enemy as the source")
	check(c.thrall_info(t)["state"] == T_DEAD and c.thrall_count(h) == 0 and c.thrall_info(t)["dead_reason"] == "killed", "dead, and the legion is empty")
	var order := l4.filter(func(x: Dictionary) -> bool: return x["tick"] == fall["tick"]).map(func(x: Dictionary) -> int: return x["type"])
	check(order.find(EV_T_DAMAGED) < order.find(EV_T_STATE) and order.find(EV_T_STATE) < order.find(EV_T_DIED), "order: damaged, state DEAD, died")
	var gone := run_until(c, func(x: Dictionary) -> bool: return x["type"] == EV_T_REMOVED, 200, l4)
	check(not gone.is_empty() and gone["id"] == t and gone["tick"] - fall["tick"] == ticks_until(K["CORPSE_S"]) - 1, "the body is freed CORPSE_S after it fell (tick %d)" % (gone["tick"] - fall["tick"]))
	check(c.thrall_info(t).is_empty() and c.thrall_total() == 0, "and leaves the table")
	# The damage API on a thrall: {dealt, killed}, usable by bosses.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var t2 := raise(d, h2, "warrior", Vector2(0, -1.9))
	var bsid := boss(d, Vector2(20, 20))
	var res: Dictionary = d.damage(t2, 15.0, bsid)
	check(res["dealt"] == 15.0 and not res["killed"] and d.thrall_info(t2)["hp"] == 25.0, "damage(): a rising thrall can be hurt")
	var res2: Dictionary = d.damage(t2, 100.0, bsid)
	check(res2["killed"] and d.thrall_info(t2)["dead_reason"] == "killed" and not d.damage(t2, 1.0, bsid)["killed"], "damage(): a lethal blow kills, a dead one takes none")
	# Area blows hit thralls with the heroes: the sac's slam (r 1.9 at the aim) and the penitent's cone.
	var s := make()
	var hs := hero(s, Vector2(4, 0))
	var ts := raise(s, hs, "warrior", Vector2(4.5, 0.4))
	steps(s, rise_ticks())
	s.stun(ts, 1.0e6)
	var sac: int = s.spawn_enemy("sac", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var ls := []
	run_until(s, func(x: Dictionary) -> bool: return x["type"] == EV_T_DAMAGED or (x["type"] == EV_HIT), 900, ls)
	steps(s, 2, ls)
	var th := of_type(ls, EV_T_DAMAGED)
	var hh := of_type(ls, EV_HIT)
	check(th.size() == 1 and hh.size() == 1 and th[0]["floats"][0] == SAC and hh[0]["floats"][0] == SAC and th[0]["tick"] == hh[0]["tick"], "the sac's slam hits the hero (event) and the thrall (applied), both for its damage")
	var p := make()
	var hp_ := hero(p, Vector2(6, 0))
	var tp := raise(p, hp_, "warrior", Vector2(5, 0.5))
	steps(p, rise_ticks())
	p.stun(tp, 1.0e6)
	var pen: int = p.spawn_enemy("penitent", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var lp := []
	run_until(p, func(x: Dictionary) -> bool: return x["type"] == EV_T_DAMAGED, 900, lp)
	var cone := of_type(lp, EV_T_DAMAGED)
	check(not cone.is_empty() and cone[0]["floats"][0] == float(data["enemies"]["ENEMIES"]["penitent"]["damage"]) and cone[0]["ints"][0] == pen, "the penitent's cone tolls the thrall standing in it for its damage")
	# A toxic pool (a burst corpse) hurts a thrall standing in it like anyone: TOXIC_DMG per pulse.
	var q := make()
	var hq := hero(q, Vector2(40, 40))
	var tq := raise(q, hq, "warrior", Vector2(0.5, 0))
	steps(q, rise_ticks())
	q.stun(tq, 1.0e6)
	q.corpse_add(Vector2(0, 0), "toxic", "sac", false, 0.0, 1.0, "graves")
	var lq := []
	steps(q, ticks_until(K["TOXIC_RUPTURE"]) + 40, lq)
	var pool := of_type(lq, EV_T_DAMAGED)
	check(not pool.is_empty() and pool[0]["ints"][0] == 0 and is_equal_approx(pool[0]["floats"][0], float(K["TOXIC_DMG"]) * dscale(1)), "a toxic pool pulses TOXIC_DMG on a thrall in it (source: the pool)")


## Deaths and their reasons: decays at its lifetime, crumbles when the owner dies or is gone (rising ones too), a plague bearer ruptures unless it
## crumbled, the Legion of the Unburied bursts only when it was killed; sacrifice kills with reason sacrificed.
func deaths_and_bursts() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var t := raise(c, h, "warrior", seat(Vector2(0, 0), 0, 1), 6.0, {"lifetimeS": 2.0})
	var log := []
	steps(c, 130, log)
	var n := ticks_until(2.0)
	var died := of_type(log, EV_T_DIED)
	check(died.size() == 1 and died[0]["ints"][0] == DECAYED and died[0]["tick"] == n, "a lifetime thrall decays on tick %d (2.0 s)" % n)
	# Owner dies: the whole legion crumbles on the next tick, a rising one included; a removed owner does the same.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var a := raise(d, h2, "warrior", Vector2(0, -1.9))
	steps(d, rise_ticks() + 5)
	var b := raise(d, h2, "warrior", Vector2(0, 5))
	d.set_external(h2, Vector2(0, 0), false)
	var l2 := []
	steps(d, 1, l2)
	var crumbled := of_type(l2, EV_T_DIED)
	check(crumbled.size() == 2 and crumbled.all(func(x: Dictionary) -> bool: return x["ints"][0] == CRUMBLED) and d.thrall_count() == 0, "the owner dies: the legion crumbles, the rising one too")
	var e := make()
	var h3 := hero(e, Vector2(0, 0))
	var c3 := raise(e, h3, "warrior", Vector2(0, -1.9))
	steps(e, 3)
	e.remove_external(h3)
	var l3 := []
	steps(e, 1, l3)
	check(of_type(l3, EV_T_DIED).size() == 1 and of_type(l3, EV_T_DIED)[0]["ints"][0] == CRUMBLED, "the owner is gone: crumbles")
	# Plague bearer: ruptures for PLAGUE_BURST.damageMult x its damage within PLAGUE_BURST.radius (+ radius) and leaves a pool signal; not when it crumbled.
	var burst_r: float = K["PLAGUE_BURST.radius"]
	var f := make()
	var h4 := hero(f, Vector2(0, 0))
	var pb := raise(f, h4, "plaguebearer", Vector2(10, 0), 6.0, {"damage": 20.0})
	var near := dummy(f, Vector2(10.0 + burst_r * 0.5, 0))
	var edge_in := dummy(f, Vector2(10, burst_r + RR - 0.05))     # just inside the radius + its own
	var edge_out := dummy(f, Vector2(10, -(burst_r + RR + 0.05)))   # just outside
	steps(f, 3)
	events(f)
	f.kill_thrall(pb, "killed")
	var lf := events(f)
	var dm := of_type(lf, EV_DAMAGED)
	var ids_hit := dm.map(func(x: Dictionary) -> int: return x["id"])
	check(ids_hit.has(near) and ids_hit.has(edge_in) and not ids_hit.has(edge_out) and dm.all(func(x: Dictionary) -> bool: return is_equal_approx(x["floats"][0], 20.0 * float(K["PLAGUE_BURST.damageMult"])) and x["ints"][0] == pb), "plague bearer: damageMult x 20 to each within the burst radius + radius")
	var pool := of_type(lf, EV_PLAGUE_POOL)
	check(pool.size() == 1 and is_equal_approx(pool[0]["floats"][2], float(K["PLAGUE_BURST.poolRadius"])) and is_equal_approx(pool[0]["floats"][3], float(K["PLAGUE_BURST.poolS"])) and is_equal_approx(pool[0]["floats"][4], 20.0 * float(K["PLAGUE_BURST.poolDpsShare"])), "and a pool signal: the pool's radius, seconds and share of its damage per second")
	var order := lf.map(func(x: Dictionary) -> int: return x["type"])
	check(order.find(EV_T_DIED) < order.find(EV_DAMAGED) and order.find(EV_DAMAGED) < order.find(EV_PLAGUE_POOL), "order: died, the burst, the pool")
	var g := make()
	var h5 := hero(g, Vector2(0, 0))
	var pb2 := raise(g, h5, "plaguebearer", Vector2(10, 0), 6.0, {"damage": 20.0})
	dummy(g, Vector2(10.0 + burst_r * 0.5, 0))
	steps(g, 3)
	events(g)
	g.kill_thrall(pb2, "crumbled")
	check(of_type(events(g), EV_PLAGUE_POOL).is_empty(), "a crumbled plague bearer does not rupture")
	var g2 := make()
	var h6 := hero(g2, Vector2(0, 0))
	var pb3 := raise(g2, h6, "plaguebearer", Vector2(10, 0), 6.0, {"damage": 20.0})
	dummy(g2, Vector2(10.0 + burst_r * 0.5, 0))
	steps(g2, 3)
	events(g2)
	g2.sacrifice_thralls(h6)
	check(of_type(events(g2), EV_PLAGUE_POOL).size() == 1, "a sacrificed one does")
	# Legion of the Unburied: killed -> frac x max hp to those within LEGEND.deathBurstR (+ radius); crumbled or sacrificed -> nothing; set for the living and the next.
	var death_r: float = K["LEGEND.deathBurstR"]
	var k := make()
	var hk := hero(k, Vector2(0, 0))
	var w1 := raise(k, hk, "warrior", Vector2(10, 0), 6.0, {"maxHp": 60.0, "hp": 60.0})
	var victim := dummy(k, Vector2(10.0 + death_r * 0.5, 0))
	k.set_legion_burst(hk, 0.5)
	var w2 := raise(k, hk, "warrior", Vector2(10, 1), 6.0, {"maxHp": 80.0, "hp": 80.0})
	check(k.thrall_info(w1)["death_burst_frac"] == 0.5 and k.thrall_info(w2)["death_burst_frac"] == 0.5, "the burst fraction reaches the living and the next thrall")
	steps(k, 3)
	events(k)
	k.kill_thrall(w1, "crumbled")
	k.kill_thrall(w2, "sacrificed")
	check(of_type(events(k), EV_DAMAGED).is_empty(), "crumbled or sacrificed: no burst")
	var w3 := raise(k, hk, "warrior", Vector2(10, 0), 6.0, {"maxHp": 80.0, "hp": 80.0})
	var bs := boss(k, Vector2(10.0, death_r + 0.8))   # its edge is 0.8 from the radius' edge
	events(k)
	k.kill_thrall(w3, "killed")
	var kb := events(k)
	var bd := of_type(kb, EV_DAMAGED)
	check(bd.size() == 1 and bd[0]["id"] == victim and bd[0]["floats"][0] == 40.0, "killed: 0.5 x max hp (80) = 40 to those within the burst radius")
	check(of_type(kb, EV_HIT_BOSS).size() == 1 and of_type(kb, EV_HIT_BOSS)[0]["ints"][0] == bs and of_type(kb, EV_HIT_BOSS)[0]["floats"][0] == 40.0, "and to a boss within reach, as an event")
	# Sacrifice returns each thrall's stats; kill_thrall refuses the dead.
	var s := make()
	var hs := hero(s, Vector2(0, 0))
	var s1 := raise(s, hs, "warrior", Vector2(3, 3))
	var s2 := raise(s, hs, "archer", Vector2(-3, 3))
	var sac: Array = s.sacrifice_thralls(hs, 1)
	check(sac.size() == 1 and sac[0]["kind"] == "warrior" and sac[0]["maxHp"] == 40.0 and sac[0]["damage"] == 10.0 and sac[0]["pos"] == Vector2(3, 3), "sacrifice(1) takes the oldest and reports its stats and place")
	check(s.thrall_info(s1)["dead_reason"] == "sacrificed" and s.thrall_count(hs) == 1 and not s.kill_thrall(s1, "killed"), "reason sacrificed; a dead thrall cannot die again")
	check(s.sacrifice_thralls(hs).size() == 1 and s.thrall_count(hs) == 0, "sacrifice(all) takes the rest")


## Statuses on a thrall are the same status set as an enemy's: stun freezes it, root stops its walk (not its swing), chill slows both, a DoT is paid in
## lumps and can kill it.
func statuses_on_thralls() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var t := raise(c, h, "warrior", Vector2(0, -9.0))
	steps(c, rise_ticks() + 2)
	var before := pos_of(c, t)
	c.apply_status(t, "stun", 0, 1)
	var stun_s := float(rule("stun")["dur"])
	var n := countdown(stun_s)
	check(c.thrall_info(t)["stun_t"] == stun_s, "the stun status stuns the thrall for its rule's duration (%s s)" % stun_s)
	var still := true
	for i in n:
		steps(c, 1)
		still = still and pos_of(c, t) == before
	check(still, "stunned for %d ticks: it does not move" % n)
	steps(c, 1)
	check(pos_of(c, t) != before, "and moves again the tick after")
	# Root: no walking, speed 0 -- but it still swings.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var t2 := raise(d, h2, "warrior", seat(Vector2(0, 0), 0, 1))
	var e := dummy(d, Vector2(0, -(SEAT_R + in_reach())))
	d.apply_status(t2, "root", 0, 1, 30.0)
	var l2 := []
	steps(d, rise_ticks() + 40, l2)
	check(d.thrall_info(t2)["speed_mult"] == 0.0 and not of_type(l2, EV_SWING).is_empty(), "rooted: speed 0, and it still swings")
	# Chill: speed x CHILL.moveMult, cadence x CHILL.attackRateMult.
	var chill: Dictionary = data["statuses"]["CHILL"]
	var f := make()
	var h3 := hero(f, Vector2(0, 0))
	var t3 := raise(f, h3, "warrior", seat(Vector2(0, 0), 0, 1))
	dummy(f, Vector2(0, -(SEAT_R + in_reach())))
	f.apply_status(t3, "chill", 0, 1, 1000.0)
	var l3 := []
	steps(f, rise_ticks() + countdown(1.0, float(chill["attackRateMult"])) * 4, l3)
	var sw := of_type(l3, EV_SWING)
	check(is_equal_approx(f.thrall_info(t3)["speed_mult"], float(chill["moveMult"])) and is_equal_approx(f.thrall_info(t3)["attack_rate_mult"], float(chill["attackRateMult"])) and sw[2]["tick"] - sw[1]["tick"] == countdown(1.0, float(chill["attackRateMult"])), "chilled: move x moveMult, cadence x attackRateMult (%d ticks)" % (sw[2]["tick"] - sw[1]["tick"]))
	# DoT: a lump through the thrall's own damage, credited to the stacker; lethal ones kill it (reason killed).
	var g := make()
	var h4 := hero(g, Vector2(0, 0))
	var t4 := raise(g, h4, "warrior", seat(Vector2(0, 0), 0, 1))
	var src := boss(g, Vector2(30, 30))
	g.apply_status(t4, "bleed", src, 1, 30.0, {"dps": 8.0})
	var l4 := []
	steps(g, 60, l4)
	var dots := of_type(l4, EV_STATUS_DOT)
	check(not dots.is_empty() and dots[0]["id"] == t4 and dots[0]["ints"][1] == src and g.thrall_info(t4)["hp"] < 40.0, "a bleed on a thrall pays in lumps, credited to its source")
	var lost: float = 40.0 - g.thrall_info(t4)["hp"]
	var paid := 0.0
	for x in dots:
		paid += x["floats"][0]
	check(absf(lost - paid) < 0.01, "the lumps are the health lost (%.3f)" % lost)
	g.apply_status(t4, "bleed", src, 1, 30.0, {"dps": 1.0e5})
	var l5 := []
	steps(g, 60, l5)
	var fall := of_type(l5, EV_T_DIED)
	check(fall.size() == 1 and fall[0]["ints"][0] == KILLED and fall[0]["ints"][3] == src, "a lethal DoT kills the thrall (reason killed, source the stacker)")
	# Fracture on a thrall raises its damage taken for every source (the status multiplier lives in one place).
	var k := make()
	var h5 := hero(k, Vector2(0, 0))
	var t5 := raise(k, h5, "warrior", Vector2(0, -1.9))
	k.apply_status(t5, "fracture", 0, 3)
	check(is_equal_approx(k.thrall_info(t5)["taken_mult"], fracture_taken(3)), "fracture x3 stacks: damage taken x%s" % fracture_taken(3))
	k.damage(t5, 10.0, 0)
	check(is_equal_approx(k.thrall_info(t5)["hp"], 40.0 - 10.0 * fracture_taken(3)), "and it applies to a direct hit")


## Rally the Dead: the time (RALLY.durationS, plus gravecallerBonusS for a Gravecaller, capped there), + healFrac health, not the rising, the focus taken within the leash of the thrall.
func rally() -> void:
	var rally_s: float = K["RALLY.durationS"]
	var top: float = rally_s + float(K["RALLY.gravecallerBonusS"])
	var leash: float = K["THRALL_LEASH"]
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var up := raise(c, h, "warrior", seat(Vector2(0, 0), 0, 2))
	steps(c, rise_ticks() + 2)
	var rising := raise(c, h, "warrior", Vector2(0, 8))
	var out := {}
	var asked := [rally_s, top, top + 12.0, rally_s * 0.5]
	for secs in asked:
		c.rally_thralls(h, secs)
		out[secs] = c.thrall_info(up)["rally_t"]
	check(out[asked[0]] == rally_s and out[asked[1]] == top and out[asked[2]] == top and out[asked[3]] == rally_s, "rally time: RALLY.durationS, up to that + the Gravecaller's bonus, never less than RALLY.durationS (%s)" % str(out))
	check(c.thrall_info(rising)["rally_t"] == 0.0, "a rising thrall is not rallied")
	var f := dummy(c, Vector2(-leash * 0.7, 0))   # inside the leash of the thrall's seat... a focus beyond it is not forced
	var far := dummy(c, Vector2(0, leash + 1.5))
	c.rally_thralls(h, rally_s, far)
	check(c.thrall_info(up)["target"] != far, "a focus beyond the leash of the thrall is not forced on it")
	c.rally_thralls(h, rally_s, f)
	check(c.thrall_info(up)["target"] == f, "a focus within reach becomes the target")
	# The rally counts down: `rally_t = max(0, rally_t - dt)` per tick.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var t := raise(d, h2, "warrior", seat(Vector2(0, 0), 0, 1))
	steps(d, rise_ticks() + 1)
	d.rally_thralls(h2, rally_s)
	var n := 0
	var x := rally_s
	while x > 0.0:
		x = maxf(0.0, x - DT)
		n += 1
	steps(d, n - 1)
	check(d.thrall_info(t)["rally_t"] > 0.0, "still rallied one tick before it ends")
	steps(d, 1)
	check(d.thrall_info(t)["rally_t"] == 0.0, "over after %d ticks" % n)


## Thralls of one legion push each other apart (radius 0.4 each, k = 6 per metre of overlap), another owner's do not, rising ones neither push nor are pushed.
func separation() -> void:
	var c := make()
	var h := hero(c, Vector2(40, 40))
	var a := raise(c, h, "warrior", Vector2(0, 0))
	var b := raise(c, h, "warrior", Vector2(0.3, 0))
	steps(c, rise_ticks() - 1)
	check(pos_of(c, a) == Vector2(0, 0) and pos_of(c, b) == Vector2(0.3, 0), "rising thralls neither push nor are pushed")
	steps(c, 1)
	c.stun(a, 1.0e6)
	c.stun(b, 1.0e6)
	steps(c, 120)
	var gap := pos_of(c, a).distance_to(pos_of(c, b))
	check(gap > 0.78 and gap < 0.9, "a legion's thralls settle just apart (%.2f m)" % gap)
	var d := make()
	var h1 := hero(d, Vector2(40, 40))
	var h2 := hero(d, Vector2(-40, 40))
	var p := raise(d, h1, "warrior", Vector2(0, 0))
	var q := raise(d, h2, "warrior", Vector2(0.3, 0))
	steps(d, rise_ticks())
	d.stun(p, 1.0e6)
	d.stun(q, 1.0e6)
	steps(d, 120)
	check(pos_of(d, p).distance_to(pos_of(d, q)) < 0.31, "another owner's thralls do not push (%.2f m)" % pos_of(d, p).distance_to(pos_of(d, q)))


## Queries and bulk reads for the HUD, minimap and drawing, in raise order.
func legion_queries() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var h2 := hero(c, Vector2(30, 0))
	var a := raise(c, h, "warrior", Vector2(2, 0))
	var b := raise(c, h, "archer", Vector2(5, 0))
	var o := raise(c, h2, "colossus", Vector2(31, 0), 9.0)
	var ids: PackedInt32Array = c.thrall_ids()
	check(Array(ids) == [a, b, o] and c.thrall_total() == 3, "ids in raise order")
	check(Array(c.thrall_kinds()) == [0, 4, 7] and Array(c.thrall_owners()) == [h, h, h2] and Array(c.thrall_states()) == [RISING, RISING, RISING], "kinds, owners, states")
	var pos: PackedFloat32Array = c.thrall_positions()
	check(pos.size() == 9 and pos[0] == 2.0 and pos[3] == 5.0 and pos[6] == 31.0, "x, z, yaw per thrall")
	var hp: PackedFloat32Array = c.thrall_hp()
	check(hp.size() == 6 and hp[0] == 40.0 and hp[1] == 40.0, "hp and max hp per thrall")
	check(Array(c.thralls_in_radius(Vector2(3, 0), 2.0)) == [a, b] and Array(c.thralls_in_radius(Vector2(3, 0), 1.99)) == [a] and Array(c.thralls_in_radius(Vector2(3, 0), 2.1, h2)).is_empty(), "thralls_in_radius: raise order, per owner, the edge included")
	var slots: float = K["colossus.slots"]
	check(c.thrall_count() == 3 and c.thrall_count(h) == 2 and c.thrall_places(h2) == slots and c.thrall_places(h) == 2.0 and c.thrall_places() == 2.0 + slots, "counts and legion places (a colossus is colossus.slots)")
	c.recall_thralls(h)
	var ap := pos_of(c, a)
	var slot_a: int = c.thrall_info(a)["formation_slot"]
	check(is_equal_approx(ap.x, sin(float(slot_a))) and is_equal_approx(ap.y, cos(float(slot_a))), "recall puts each thrall by the owner at (sin slot, cos slot)")
	steps(c, 200)
	var swings: PackedInt32Array = c.thrall_swings()
	check(swings.size() == 3 and swings[0] == 0, "swing counters")


## Tick order (combat map section 1): in a busy fight, every enemy-phase event of a tick comes before the first thrall-phase event.
func tick_order() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	for i in 3:
		raise(c, h, "warrior", seat(Vector2(0, 0), i, 3), 6.0, {"hp": 400.0, "maxHp": 400.0})
	for i in 8:
		c.spawn_enemy("robber" if i % 2 == 0 else "penitent", Vector2(-6 + i * 1.7, -9 + (i % 3)), 1, 1.0, 1.0, false, "graves", false)
	var log := []
	steps(c, 900, log)
	var ticks := {}
	for e in log:
		if not ticks.has(e["tick"]):
			ticks[e["tick"]] = []
		ticks[e["tick"]].append(e["type"])
	var enemy_phase := [EV_ATTACK, EV_TELEGRAPH, EV_HIT]
	var thrall_phase := [EV_SWING]
	var bad := 0
	var swings := 0
	for t in ticks:
		var seen_swing := false
		for ty: int in ticks[t]:
			if ty in thrall_phase:
				seen_swing = true
				swings += 1
			elif seen_swing and ty in enemy_phase:
				bad += 1
	check(swings > 5 and bad == 0, "no enemy swing or telegraph after a thrall's swing in a tick (%d swings seen, %d out of order)" % [swings, bad])
	# A thrall can kill an enemy that already acted this tick: the enemy's blow and its death share a tick, the blow first.
	var d := make()
	var h2 := hero(d, Vector2(0, 0))
	var t := raise(d, h2, "warrior", seat(Vector2(0, 0), 0, 1), 6.0, {"damage": 1000.0})
	var r: int = d.spawn_enemy("robber", Vector2(0, -2.6), 1, 1.0, 1.0, false, "graves", false)
	var l2 := []
	steps(d, 400, l2)
	var kill := of_type(l2, EV_DIED)
	check(kill.size() == 1 and kill[0]["ints"][4] == t, "the thrall killed the robber (id %d)" % r)
