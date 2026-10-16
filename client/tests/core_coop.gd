extends SceneTree
## Co-op in the combat core (native/README.md "Co-op"): two DmCores in one process. The host runs a real fight (a Graves wave, heroes, a boss
## position, thralls of every kind, damage, deaths, statuses, a corpse that bursts, affix elites); every 3rd tick (20 Hz at 60 Hz) it sends one
## snapshot and the reliable events to puppet cores that step every tick. Checked: the bodies, states and health match after each snapshot, positions
## converge within the quantization and easing, the forwarded events arrive once and in order, the derived ones (state, attack, telegraph, damage, swing)
## match what the delivered snapshots show, a late guest is brought up by the baseline, a lost batch is noticed, a lost or late snapshot costs nothing,
## a version or data mismatch and every damaged message are refused, the host's commands are refused on a puppet, queries and DmCrowd work on one,
## and the Full Party fits the 2 KB snapshot budget (sizes and times are printed as INFO).
## Run: godot --headless --path client --script res://tests/core_coop.gd [-- --verbose]   (verbose lists every passing check)

const EV_SPAWNED := 1
const EV_STATE := 2
const EV_DAMAGED := 3
const EV_DIED := 4
const EV_REMOVED := 5
const EV_ATTACK := 6
const EV_TELEGRAPH := 7
const EV_CUE := 8
const EV_TARGET_HIT := 9
const EV_ZONE := 10
const EV_ZONE_PULSE := 11
const EV_ZONE_GONE := 12
const EV_STATUS_CHANGED := 14
const EV_STATUS_DOT := 15
const EV_WITHERED_DIED := 17
const EV_CORPSE_ADDED := 18
const EV_CORPSE_GONE := 20
const EV_RAISED := 22
const EV_T_STATE := 23
const EV_SWING := 24
const EV_T_DAMAGED := 25
const EV_T_DIED := 26
const EV_T_REMOVED := 27
const EV_BELL_HEAL := 29
const EV_PLAGUE_POOL := 30
const EV_HIT_BOSS := 31
const EV_AFFIX := 32
## The events a guest gets as they are (the bell's toll telegraph is the only telegraph among them); the rest are derived on the guest or host-only.
const FORWARDED := [1, 4, 5, 8, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 26, 27, 28, 32]
const HOST_ONLY := [9, 17, 29, 30, 31]
const DERIVED := [2, 3, 6, 23, 24, 25]
const TELL_TOLL := 4
const RISING := 0
const ATTACK := 3
const DEAD := 6
const BURROW := 8
const ERUPT := 9
const T_DEAD := 4
const DT := 1.0 / 60.0
const WAVE := ["robber", "hound", "robber", "penitent", "bat", "ghoul", "robber", "moth", "hound", "sac", "bat", "ghoul"]
const THRALL_BASE := {"warrior": [1.3, 1.0, 5.6], "shieldbearer": [1.3, 1.25, 5.2], "hound": [1.2, 0.7, 7.2], "wraith": [5.5, 1.1, 5.8],
	"archer": [7.5, 1.3, 5.4], "bonemage": [6.5, 1.8, 5.2], "plaguebearer": [1.3, 1.2, 4.8]}
const BUDGET_BYTES := 2048

var fails := 0
var checks := 0
var godot_dir: String
var runes: Dictionary
var enemies_json: Dictionary
var soft_n := {}
var soft_bad := {}
var keep := []
var verbose := false


func check(ok: bool, what: String) -> void:
	checks += 1
	if ok and verbose:
		print("ok   " + what)
	if not ok:
		fails += 1
		printerr("FAIL core_coop: " + what)


## A check made many times in a loop: counted per key, reported once by `settle_soft`.
func soft(ok: bool, key: String, detail: String = "") -> void:
	soft_n[key] = int(soft_n.get(key, 0)) + 1
	if not ok:
		var b: Array = soft_bad.get(key, [0, detail])
		b[0] += 1
		soft_bad[key] = b


func settle_soft(key: String, what: String) -> void:
	var bad: Array = soft_bad.get(key, [0, ""])
	var n := int(soft_n.get(key, 0))
	check(bad[0] == 0 and n > 0, "%s (%d compared%s)" % [what, n, "" if bad[0] == 0 else "; %d failed, first: %s" % [bad[0], bad[1]]])


func make_core(seed_: int) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	DmCoreData.load_all(c, godot_dir)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	return c


func make_puppet() -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	DmCoreData.load_all(c, godot_dir)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_puppet(true)
	return c


## The events of one take_events() as dictionaries.
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


func hero(c: RefCounted, at: Vector2) -> int:
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, at, true)
	return h


func thrall_stats(kind: String, hp: float = 160.0, dmg: float = 18.0) -> Dictionary:
	var b: Array = THRALL_BASE.get(kind, [])
	if kind == "colossus":
		var col: Dictionary = runes["RUNE_TUNING"]["colossus"]
		b = [col["range"], col["interval"], col["speed"]]
	return {"kind": kind, "hp": hp, "maxHp": hp, "damage": dmg, "attackInterval": b[1], "range": b[0], "speed": b[2], "empowered": false, "champion": false, "allyHeal": 0.0}


func spawn_wave(c: RefCounted, rng: RandomNumberGenerator, n: int, rmin: float, rmax: float, rising: bool) -> Array:
	var ids := []
	for i in n:
		var a := rng.randf() * TAU
		var r := rng.randf_range(rmin, rmax)
		ids.append(c.spawn_enemy(WAVE[i % WAVE.size()], Vector2(cos(a), sin(a)) * r, 1, 1.0, 1.0, false, "graves", rising and i % 3 == 0))
	return ids


func alive_enemies(c: RefCounted) -> Array:
	var ids: PackedInt32Array = c.enemy_ids()
	var states: PackedInt32Array = c.enemy_states()
	var out := []
	for i in ids.size():
		if states[i] != DEAD:
			out.append(ids[i])
	return out


func _init() -> void:
	verbose = "--verbose" in OS.get_cmdline_user_args()
	godot_dir = ProjectSettings.globalize_path("res://").path_join("../godot")
	runes = DmCoreData.json(godot_dir.path_join("data/content/runes.json"))
	enemies_json = DmCoreData.json(godot_dir.path_join("data/content/enemies.json"))
	check(ClassDB.class_exists("DmCore") and int(DmCore.wire_version()) >= 1, "the core has a wire version, callable on the class (%d)" % DmCore.wire_version())
	fight()
	wire_format()
	puppet_refuses_and_answers()
	silent_removal()
	full_party()
	snapshot_parts()
	keep.clear()
	if fails == 0:
		print("PASS core_coop %d checks" % checks)
	quit(1 if fails > 0 else 0)


# ============================================================================================ the fight

## What a send tick compares (host against one puppet). `exact`: after the final snapshot and the settle, positions are the quantized ones.
func compare(host: RefCounted, pup: RefCounted, key: String, exact: bool, speeds: Dictionary) -> void:
	var hid: PackedInt32Array = host.enemy_ids()
	var pid: PackedInt32Array = pup.enemy_ids()
	soft(hid == pid, key + ".enemy_ids", "host %d bodies, puppet %d" % [hid.size(), pid.size()])
	var htid: PackedInt32Array = host.thrall_ids()
	soft(htid == pup.thrall_ids(), key + ".thrall_ids", "host %d thralls, puppet %d" % [htid.size(), pup.thrall_ids().size()])
	soft(host.corpse_ids() == pup.corpse_ids(), key + ".corpse_ids")
	soft(host.corpse_positions() == pup.corpse_positions(), key + ".corpse_positions", "corpses lie where the host laid them (float32 on the wire)")
	if hid != pid:
		return
	var hs: PackedInt32Array = host.enemy_states()
	var ps: PackedInt32Array = pup.enemy_states()
	soft(hs == ps, key + ".enemy_states")
	for i in hid.size():
		var id := hid[i]
		var hi: Dictionary = host.enemy_info(id)
		var pi: Dictionary = pup.enemy_info(id)
		if hi.is_empty() or pi.is_empty():
			soft(false, key + ".info", "body %d has no info" % id)
			continue
		var tol := float(hi["max_hp"]) / 65535.0 * 1.01 + 1e-6
		soft(absf(float(hi["hp"]) - float(pi["hp"])) <= tol, key + ".enemy_hp", "%d: host %f puppet %f" % [id, hi["hp"], pi["hp"]])
		soft(hi["def"] == pi["def"] and hi["level"] == pi["level"] and hi["elite"] == pi["elite"] and hi["area"] == pi["area"] and is_equal_approx(float(hi["max_hp"]), float(pi["max_hp"])), key + ".enemy_facts", "%d spawn facts" % id)
		soft(Array(hi["affixes"]) == Array(pi["affixes"]), key + ".affixes", "%d: host %s puppet %s" % [id, hi["affixes"], pi["affixes"]])
		if hs[i] == DEAD:
			continue
		var hp2: Vector2 = hi["pos"]
		var net: Vector2 = pi["net_pos"]
		soft(hp2.distance_to(net) <= 0.0072, key + ".enemy_net_pos", "%d: host %s snapshot %s" % [id, hp2, net])
		var pp: Vector2 = pi["pos"]
		var v := float(speeds.get(id, 0.0))
		var bound := 0.0072 + 1e-3 if exact else 0.2 * v + 0.05
		soft(hp2.distance_to(pp) <= bound or exact_jump(speeds, id, hp2), key + ".enemy_pos", "%d: host %s puppet %s (bound %f, speed %f)" % [id, hp2, pp, bound, v])
	var hth: PackedFloat32Array = host.thrall_hp()
	var pth: PackedFloat32Array = pup.thrall_hp()
	var hst: PackedInt32Array = host.thrall_states()
	soft(hst == pup.thrall_states(), key + ".thrall_states")
	var hsw: PackedInt32Array = host.thrall_swings()
	var psw: PackedInt32Array = pup.thrall_swings()
	var sw_ok := hsw.size() == psw.size()
	if sw_ok:
		for i in hsw.size():
			sw_ok = sw_ok and (hst[i] == T_DEAD or hsw[i] == psw[i])   # a thrall that swung and fell between two snapshots is never shown swinging
	soft(sw_ok, key + ".thrall_swings", "host %s puppet %s" % [hsw, psw])
	soft(host.thrall_kinds() == pup.thrall_kinds() and host.thrall_owners() == pup.thrall_owners(), key + ".thrall_facts")
	if htid != pup.thrall_ids():
		return
	for i in htid.size():
		var mx := float(hth[i * 2 + 1])
		if hst[i] != T_DEAD:
			soft(absf(float(hth[i * 2]) - float(pth[i * 2])) <= mx / 65535.0 * 1.01 + 1e-6 and absf(mx - float(pth[i * 2 + 1])) < 1e-3, key + ".thrall_hp", "%d: host %f puppet %f of %f" % [htid[i], hth[i * 2], pth[i * 2], mx])
			var hti: Dictionary = host.thrall_info(htid[i])
			var pti: Dictionary = pup.thrall_info(htid[i])
			var hq: Vector2 = hti["pos"]
			var pq: Vector2 = pti["net_pos"]
			soft(hq.distance_to(pq) <= 0.0072, key + ".thrall_net_pos", "%d: host %s snapshot %s" % [htid[i], hq, pq])
			var pv := float(speeds.get(htid[i], 0.0))
			var tb := 0.0072 + 1e-3 if exact else 0.2 * pv + 0.05
			soft(hq.distance_to(pti["pos"]) <= tb or exact_jump(speeds, htid[i], hq), key + ".thrall_pos", "%d: host %s puppet %s (bound %f)" % [htid[i], hq, pti["pos"], tb])
			soft(bool(hti["rally_t"] > 0.0) == bool(pti["rally_t"] > 0.0), key + ".rally", "%d rally flag" % htid[i])


## A body the host teleported (a thrall too far from its owner, a burrower surfacing) is allowed to differ while the puppet catches up or snaps.
func exact_jump(speeds: Dictionary, id: int, at: Vector2) -> bool:
	return speeds.has(-id) and Vector2(speeds[-id]).distance_to(at) > 1.0


## Per body, at each send: how fast the host moved it since the last send (metres per second, with half of the earlier value kept: a stopped body
## leaves its lag behind), and where it was at the last send (a jump of more than a metre is a teleport).
func track(host: RefCounted, speeds: Dictionary, last_at: Dictionary) -> void:
	var ids: PackedInt32Array = host.enemy_ids()
	var pos: PackedFloat32Array = host.enemy_positions()
	for i in ids.size():
		var p := Vector2(pos[i * 3], pos[i * 3 + 1])
		var before: Vector2 = last_at.get(ids[i], p)
		speeds[ids[i]] = maxf(p.distance_to(before) / 0.05, float(speeds.get(ids[i], 0.0)) * 0.5)
		speeds[-ids[i]] = before
		last_at[ids[i]] = p
	var tids: PackedInt32Array = host.thrall_ids()
	var tpos: PackedFloat32Array = host.thrall_positions()
	for i in tids.size():
		var p := Vector2(tpos[i * 3], tpos[i * 3 + 1])
		var before: Vector2 = last_at.get(tids[i], p)
		speeds[tids[i]] = maxf(p.distance_to(before) / 0.05, float(speeds.get(tids[i], 0.0)) * 0.5)
		speeds[-tids[i]] = before
		last_at[tids[i]] = p


func fight() -> void:
	var host := make_core(4242)
	host.set_replication(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var h1 := hero(host, Vector2(-3, 0))
	var h2 := hero(host, Vector2(3, 0))
	var boss: int = host.add_external(1, 1.6, 1.0)
	host.set_external(boss, Vector2(0, -9), true)
	var pups := {}
	var plog := {}
	for n in ["main", "lossy", "swapped", "gap"]:
		pups[n] = make_puppet()
	var host_log := []
	var late_from := 0
	var late_tick := 0
	# the party: h1 has five thralls of different kinds, h2 four more
	for k in ["warrior", "shieldbearer", "hound", "wraith", "archer"]:
		host.raise_thrall(thrall_stats(k), h1, Vector2(-3, 2), 0.0, 8.0)
	for k in ["bonemage", "plaguebearer", "colossus", "warrior"]:
		host.raise_thrall(thrall_stats(k, 260.0), h2, Vector2(3, 2), 0.0, 8.0)
	spawn_wave(host, rng, 36, 9.0, 20.0, true)
	var elites := [
		host.spawn_enemy("robber", Vector2(-10, -8), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["bellTolled", "hungering"])),
		host.spawn_enemy("robber", Vector2(11, -9), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["shrouded", "vengeful"])),
		host.spawn_enemy("hound", Vector2(0, 12), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["bellTolled", "vengeful"])),
	]
	var bytes_snap := 0
	var bytes_rel := 0
	var snaps := 0
	var tick := 0
	var speeds := {}
	var last_at := {}
	var samples := {}      # send tick -> {enemy id: state}
	var hp_samples := {}   # send tick -> {enemy id: hp}
	var tail := {}         # enemy id -> its state at the end of the tick it appeared (what the spawn record tells)
	var tail_hp := {}      # and its health
	var swing_samples := {}
	var delivered := []    # send ticks whose snapshot "main" got (all of them)
	var gap_stage := 0
	var prev_snap := PackedByteArray()
	var lossy_n := 0
	for n in ["main", "lossy", "swapped", "gap", "late"]:
		plog[n] = []
	for t in 1500:
		tick += 1
		# the script of the fight
		var a := float(tick) / 60.0 * 0.35
		host.set_external(h1, Vector2(cos(a), sin(a)) * 5.0 + Vector2(-2, 0), true)
		host.set_external(h2, Vector2(cos(a + PI), sin(a + PI)) * 5.0 + Vector2(2, 0), true)
		if tick % 90 == 0 and tick < 1300:
			var alive := alive_enemies(host)
			if not alive.is_empty():
				host.damage(alive[rng.randi() % alive.size()], rng.randf_range(15.0, 45.0), h1)
		if tick == 200:
			var alive := alive_enemies(host)
			for i in 3:
				host.apply_status(alive[i * 5 % alive.size()], "chill", h1)
			for i in 2:
				host.apply_status(alive[(i * 7 + 1) % alive.size()], "bleed", h1, 1.0, -1.0, {"dps": 8.0})
				host.apply_status(alive[(i * 9 + 2) % alive.size()], "withered", h2, 3.0, -1.0, {"dps": 6.0})
			host.apply_status(alive[4], "hex", h1)
			var tids: PackedInt32Array = host.thrall_ids()
			host.apply_status(tids[0], "barrier", h1, 1.0, -1.0, {"amount": 60.0, "cap": 120.0})
			host.apply_status(tids[3], "barrier", h1, 1.0, -1.0, {"amount": 60.0, "cap": 120.0})
		if tick == 330:
			host.rally_thralls(h1, 6.0, 0)
		if tick == 420:
			host.raise_thrall(thrall_stats("warrior", 200.0), h1, Vector2(-3, 3), 0.0, 5.0)  # over the cap: the oldest crumbles
			host.raise_thrall(thrall_stats("hound", 200.0), h1, Vector2(-3, 3), 0.0, 5.0)
		if tick == 480:
			var tids: PackedInt32Array = host.thrall_ids()
			host.set_thrall_stats(tids[tids.size() - 1], {"hp": 300.0, "maxHp": 400.0})  # a purchase refresh: a maximum changes
		if tick == 600:
			spawn_wave(host, rng, 24, 10.0, 22.0, true)
		if tick == 700:
			host.strip_shroud(elites[1])
		if tick == 900:
			var alive := alive_enemies(host)
			for i in 4:
				host.damage(alive[i * 3 % alive.size()], 1.0e6, h1)   # kills inside a call
		if tick == 950:
			for e in [elites[1], elites[2]]:   # Vengeful: the Risen are born inside the kill
				if host.enemy_info(e).get("state", DEAD) != DEAD:
					host.damage(e, 1.0e6, h2)
		host.step(DT)
		var forwardable := false
		for e in events(host):
			e["tick"] = tick
			host_log.append(e)
			forwardable = forwardable or e["type"] in FORWARDED
		var ids: PackedInt32Array = host.enemy_ids()
		var st: PackedInt32Array = host.enemy_states()
		for i in ids.size():
			if not tail.has(ids[i]):
				tail[ids[i]] = st[i]
				var born: Dictionary = host.enemy_info(ids[i])
				tail_hp[ids[i]] = born["hp"] if st[i] != DEAD else born["max_hp"]
		for n in pups:
			pups[n].step(DT)
		if tick % 3 == 0:
			# ---- a send tick: one snapshot and the reliable batch. The late guest's baseline is taken first, while this tick's events are still waiting:
			# they are sealed into the batch the baseline's number covers, which the other guests get as usual.
			var join_now := tick >= 600 and late_tick == 0 and forwardable
			var base_now := PackedByteArray()
			if join_now:
				base_now = host.baseline()
			var snap: PackedByteArray = host.snapshot(tick)
			var rel: PackedByteArray = host.take_reliable()
			bytes_snap += snap.size()
			bytes_rel += rel.size()
			snaps += 1
			track(host, speeds, last_at)
			var states_now := {}
			var hp_now := {}
			for i in ids.size():
				states_now[ids[i]] = st[i]
				if st[i] != DEAD:
					hp_now[ids[i]] = host.enemy_info(ids[i])["hp"]
			samples[tick] = states_now
			hp_samples[tick] = hp_now
			var swing_now := {}
			var tids2: PackedInt32Array = host.thrall_ids()
			var tsw: PackedInt32Array = host.thrall_swings()
			var tst: PackedInt32Array = host.thrall_states()
			for i in tids2.size():
				swing_now[tids2[i]] = [tsw[i], tst[i]]
			swing_samples[tick] = swing_now
			delivered.append(tick)
			# main: the batch, then the snapshot (the usual order)
			if rel.size() > 0:
				soft(pups["main"].apply_reliable(rel), "main.reliable_ok", pups["main"].replication_error())
			soft(pups["main"].apply_snapshot(snap), "main.snapshot_ok", pups["main"].replication_error())
			compare(host, pups["main"], "main", false, speeds)
			# lossy: every second snapshot is lost, the batches arrive
			if rel.size() > 0:
				soft(pups["lossy"].apply_reliable(rel), "lossy.reliable_ok", pups["lossy"].replication_error())
			lossy_n += 1
			if lossy_n % 2 == 1:
				soft(pups["lossy"].apply_snapshot(snap), "lossy.snapshot_ok")
				compare(host, pups["lossy"], "lossy", false, speeds)
			# swapped: the snapshot overtakes the batch, and the previous snapshot arrives again after this one
			soft(pups["swapped"].apply_snapshot(snap), "swapped.snapshot_ok")
			if rel.size() > 0:
				soft(pups["swapped"].apply_reliable(rel), "swapped.reliable_ok", pups["swapped"].replication_error())
			if prev_snap.size() > 0:
				soft(pups["swapped"].apply_snapshot(prev_snap), "swapped.late_snapshot_ok")
			prev_snap = snap
			# gap: one batch is lost; the next is refused; a baseline repairs it and the batch it covered is a harmless repeat
			var gp: RefCounted = pups["gap"]
			if gap_stage == 0 and tick >= 750 and rel.size() > 0:
				gap_stage = 1
			elif gap_stage == 1 and rel.size() > 0:
				var refused: bool = not gp.apply_reliable(rel)
				check(refused and "baseline" in str(gp.replication_error()) and bool(gp.replication_stats()["need_baseline"]), "a lost batch is noticed by the next one and a baseline asked for (%s)" % gp.replication_error())
				gap_stage = 2
			elif gap_stage == 2 and rel.size() > 0:
				var rebase: PackedByteArray = host.baseline()
				check(not gp.apply_reliable(rel) and "baseline" in str(gp.replication_error()), "until the baseline comes, later batches are refused (%s)" % gp.replication_error())
				check(gp.apply_reliable(rebase), "a baseline repairs the gap (%s)" % gp.replication_error())
				check(not bool(gp.replication_stats()["need_baseline"]), "and the guest no longer waits for one")
				check(gp.apply_reliable(rel), "the batch the baseline already covered is a harmless repeat")
				gap_stage = 3
			elif rel.size() > 0:
				soft(gp.apply_reliable(rel), "gap.reliable_ok", gp.replication_error())
			gp.apply_snapshot(snap)
			# the late guest: brought up by the baseline, then it follows the stream
			if join_now:
				late_tick = tick
				late_from = host_log.size()
				pups["late"] = make_puppet()
				check(pups["late"].apply_reliable(base_now), "a late guest takes the baseline (%s)" % pups["late"].replication_error())
				check(rel.size() > 0 and pups["late"].apply_reliable(rel) and int(pups["late"].replication_stats()["batches_duplicate"]) == 1, "the batch sealed by the baseline, which the late guest already has, is a harmless repeat")
				soft(pups["late"].apply_snapshot(snap), "late.snapshot_ok")
			elif late_tick > 0:
				if rel.size() > 0:
					soft(pups["late"].apply_reliable(rel), "late.reliable_ok", pups["late"].replication_error())
				soft(pups["late"].apply_snapshot(snap), "late.snapshot_ok")
		for n in plog:
			if pups.has(n):
				for e in events(pups[n]):
					e["tick"] = tick
					plog[n].append(e)
	print("INFO the fight: %d ticks, %d snapshots (%d B each on average), %d B of reliable events (%d B/s)" % [tick, snaps, bytes_snap / snaps, bytes_rel, int(float(bytes_rel) / (float(tick) / 60.0))])
	# ---- the last snapshot goes to everyone, then the guests catch up for a second
	var final: PackedByteArray = host.snapshot(tick + 1)
	var final_rel: PackedByteArray = host.take_reliable()
	for n in pups:
		if final_rel.size() > 0:
			pups[n].apply_reliable(final_rel)
		check(pups[n].apply_snapshot(final), "%s takes the final snapshot" % n)
	for i in 120:
		for n in pups:
			pups[n].step(DT)
	for n in plog:
		for e in events(pups[n]):
			e["tick"] = tick + 1
			plog[n].append(e)
	for e in events(host):
		e["tick"] = tick + 1
		host_log.append(e)
	track(host, speeds, last_at)
	for n in pups:
		compare(host, pups[n], "final." + n, true, speeds)
	settle_soft("main.reliable_ok", "main: every reliable batch is accepted")
	settle_soft("main.snapshot_ok", "main: every snapshot is accepted")
	settle_soft("main.enemy_ids", "after each snapshot the guest's enemies are the host's, in spawn order")
	settle_soft("main.thrall_ids", "after each snapshot the guest's thralls are the host's")
	settle_soft("main.corpse_ids", "after each snapshot the guest's corpses are the host's")
	settle_soft("main.corpse_positions", "corpses lie where the host laid them")
	settle_soft("main.enemy_states", "after each snapshot every enemy is in the host's state")
	settle_soft("main.enemy_hp", "after each snapshot every enemy has the host's health (within 1/65535 of its maximum)")
	settle_soft("main.enemy_facts", "the spawn facts (def, level, elite, area, maximum health) arrived with the spawn")
	settle_soft("main.affixes", "the affixes match, a stripped shroud included")
	settle_soft("main.enemy_net_pos", "each snapshot puts every enemy within the quantization (0.5 cm per axis) of the host's position")
	settle_soft("main.enemy_pos", "the eased enemy follows the host within the easing lag (0.2 x speed + 5 cm)")
	settle_soft("main.thrall_states", "thrall states match after each snapshot")
	settle_soft("main.thrall_swings", "thrall swing counters match after each snapshot")
	settle_soft("main.thrall_facts", "thrall kinds and owners match")
	settle_soft("main.thrall_hp", "thrall health matches (and a changed maximum arrived)")
	settle_soft("main.thrall_net_pos", "each snapshot puts every thrall within the quantization of the host's position")
	settle_soft("main.thrall_pos", "the eased thrall follows the host within the easing lag")
	settle_soft("main.rally", "the rally flag matches")
	settle_soft("lossy.reliable_ok", "lossy: every reliable batch is accepted")
	settle_soft("lossy.snapshot_ok", "lossy: the snapshots that arrive are accepted")
	settle_soft("swapped.snapshot_ok", "swapped: a snapshot ahead of its batch is accepted")
	settle_soft("swapped.reliable_ok", "swapped: the batch behind its snapshot is accepted")
	settle_soft("swapped.late_snapshot_ok", "swapped: a late old snapshot is ignored without an error")
	settle_soft("late.reliable_ok", "late: the batches after the baseline are accepted")
	settle_soft("late.snapshot_ok", "late: the snapshots after the baseline are accepted")
	for n in pups:
		var failed := []
		for key in ["enemy_ids", "thrall_ids", "corpse_ids", "corpse_positions", "enemy_states", "enemy_hp", "enemy_facts", "affixes", "enemy_net_pos", "enemy_pos", "thrall_states", "thrall_swings", "thrall_facts", "thrall_hp", "thrall_net_pos", "thrall_pos", "rally"]:
			var k := "final.%s.%s" % [n, key]
			if int(soft_n.get(k, 0)) == 0 or (soft_bad.get(k, [0])[0] != 0):
				failed.append("%s %s" % [key, soft_bad.get(k, "never compared")])
		check(failed.is_empty(), "after the last snapshot and a second of easing, %s holds the host's enemies, thralls and corpses: ids, states, health, spawn facts, affixes, swings, rally, places to 8 mm %s" % [n, "" if failed.is_empty() else str(failed)])
	# the lossy guest converged on every snapshot it got
	for key in ["enemy_states", "enemy_hp", "enemy_net_pos"]:
		settle_soft("lossy." + key, "lossy: " + key + " matches on the snapshots that arrived")
	# ---- the forwarded events arrive once, in the host's order; the host-only ones never
	var fwd_host := forwarded(host_log, 0)
	for n in ["main", "lossy", "swapped"]:
		var got := forwarded(plog[n], 0)
		var same: bool = got == fwd_host
		check(same, "%s: the %d forwarded events are the host's, once each, in order (%d arrived)" % [n, fwd_host.size(), got.size()])
	var tolls := fwd_host.filter(func(e: Array) -> bool: return e[0] == EV_TELEGRAPH)
	check(tolls.size() > 0, "the bell's toll telegraph is the one telegraph on the wire (%d)" % tolls.size())
	var only := host_log.filter(func(e: Dictionary) -> bool: return e["type"] in HOST_ONLY)
	check(only.size() > 0, "the fight made host-only events too (%d: blows on heroes, hits on the boss ...)" % only.size())
	for n in plog:
		check(plog[n].filter(func(e: Dictionary) -> bool: return e["type"] in HOST_ONLY).is_empty(), "%s never sees a host-only event (a blow on a hero is applied once, by the host)" % n)
	var counts := {}
	for e in host_log:
		counts[e["type"]] = int(counts.get(e["type"], 0)) + 1
	for ty in [EV_SPAWNED, EV_DIED, EV_REMOVED, EV_CORPSE_ADDED, EV_CORPSE_GONE, EV_RAISED, EV_T_DIED, EV_T_REMOVED, EV_STATUS_CHANGED, EV_ZONE, EV_AFFIX, EV_CUE, EV_TELEGRAPH, EV_ATTACK, EV_SWING, EV_DAMAGED, EV_T_DAMAGED, EV_STATUS_DOT]:
		check(int(counts.get(ty, 0)) > 0, "the fight produced event type %d (%d)" % [ty, int(counts.get(ty, 0))])
	print("INFO the fight's host events by type: %s" % str(counts))
	# spawns and removals arrive exactly once per body
	for pair in [[EV_SPAWNED, "enemy spawns"], [EV_REMOVED, "enemy removals"], [EV_DIED, "enemy deaths"], [EV_RAISED, "thrall raises"], [EV_T_DIED, "thrall deaths"], [EV_T_REMOVED, "thrall removals"], [EV_CORPSE_ADDED, "corpses laid"], [EV_CORPSE_GONE, "corpses gone"]]:
		var per_host := per_id(host_log, pair[0])
		var per_pup := per_id(plog["main"], pair[0])
		var once := true
		for id in per_pup:
			once = once and per_pup[id] == 1
		check(once and per_pup == per_host and per_host.size() > 0, "%s: %d bodies, each told once (the host's %d)" % [pair[1], per_pup.size(), per_host.size()])
	# ---- derived events against what the delivered snapshots showed
	derived_checks(host_log, plog["main"], samples, hp_samples, swing_samples, tail, tail_hp, delivered)
	# ---- the late guest: the baseline built its world, the stream after it matches
	var late_log: Array = plog["late"]
	var base_events := late_log.filter(func(e: Dictionary) -> bool: return int(e["tick"]) == late_tick)
	check(base_events.filter(func(e: Dictionary) -> bool: return e["type"] == EV_SPAWNED).size() > 20, "the baseline told the late guest every live enemy (%d spawns)" % base_events.filter(func(e: Dictionary) -> bool: return e["type"] == EV_SPAWNED).size())
	var after_host := forwarded(host_log.slice(late_from), 0)
	var after_late := forwarded(late_log.filter(func(e: Dictionary) -> bool: return int(e["tick"]) > late_tick), 0)
	check(after_host == after_late, "after its baseline the late guest receives the host's forwarded events exactly (%d)" % after_host.size())
	# ---- the stats
	var ms: Dictionary = pups["main"].replication_stats()
	check(ms["desync"] == 0 and ms["records_dead"] >= 0 and ms["batches_refused"] == 0 and ms["snapshots_refused"] == 0, "the main guest never fell out of step (%s)" % str(ms))
	var sws: Dictionary = pups["swapped"].replication_stats()
	check(sws["records_unknown"] > 0 and sws["snapshots_stale"] > 0 and sws["desync"] == 0, "the swapped guest met snapshots ahead of their spawns (%d) and old ones (%d) without harm" % [sws["records_unknown"], sws["snapshots_stale"]])
	check(gap_stage == 3 and int(pups["gap"].replication_stats()["baselines_applied"]) == 1 and int(pups["gap"].replication_stats()["batches_duplicate"]) >= 1, "the gap guest took one baseline and ignored the repeat")
	# ---- the draw: DmCrowd reads a puppet like a host. A new wave is fought for 4 s, then the guest settles on a last snapshot.
	spawn_wave(host, rng, 48, 8.0, 18.0, false)
	var t2 := lockstep(host, [pups["main"]], tick + 1, 240)
	pups["main"].apply_reliable(host.take_reliable())
	pups["main"].apply_snapshot(host.snapshot(t2 + 1))
	for i in 120:
		pups["main"].step(DT)
	events(pups["main"])
	crowd_on_puppet(host, pups["main"])


## Steps the host and its guests as the fight does (a batch and a snapshot every 3rd tick); returns the tick reached.
func lockstep(host: RefCounted, guests: Array, tick: int, n: int) -> int:
	for i in n:
		tick += 1
		host.step(DT)
		events(host)
		for g: RefCounted in guests:
			g.step(DT)
		if tick % 3 == 0:
			var snap: PackedByteArray = host.snapshot(tick)
			var rel: PackedByteArray = host.take_reliable()
			for g: RefCounted in guests:
				if rel.size() > 0:
					g.apply_reliable(rel)
				g.apply_snapshot(snap)
		for g: RefCounted in guests:
			events(g)
	return tick


## The forwarded events as plain arrays, in order, from tick `after` on.
func forwarded(log: Array, after: int) -> Array:
	var out := []
	for e in log:
		if int(e["tick"]) < after:
			continue
		var ty: int = e["type"]
		if ty in FORWARDED or (ty == EV_TELEGRAPH and e["ints"][0] == TELL_TOLL):
			out.append([ty, e["id"], e["ints"], e["floats"]])
	return out


func per_id(log: Array, type: int) -> Dictionary:
	var out := {}
	for e in log:
		if e["type"] == type:
			out[e["id"]] = int(out.get(e["id"], 0)) + 1
	return out


func ceil3(t: int) -> int:
	return ((t + 2) / 3) * 3


## The derived events (state edges, attacks and their telegraphs, health drops, thrall swings and states) against the host's own events and the
## states the delivered snapshots showed.
func derived_checks(host_log: Array, pup_log: Array, samples: Dictionary, hp_samples: Dictionary, swing_samples: Dictionary, tail: Dictionary, tail_hp: Dictionary, delivered: Array) -> void:
	# attacks and telegraphs: every attack the host started that a snapshot saw (it was still in ATTACK or ERUPT at the next send) is announced once, with the host's aim
	var exp_attack := {}
	var exp_tell := {}
	var seen_attacks := 0
	var host_attacks := 0
	var tells := {}
	for e in host_log:
		if e["type"] == EV_ATTACK or (e["type"] == EV_TELEGRAPH and int(e["ints"][0]) != TELL_TOLL):
			var s := ceil3(int(e["tick"]))
			var state_then: int = (samples.get(s, {}) as Dictionary).get(e["id"], -1)
			var is_erupt: bool = e["type"] == EV_TELEGRAPH and int(e["ints"][0]) == 3
			var visible: bool = state_then == (ERUPT if is_erupt else ATTACK)
			if e["type"] == EV_ATTACK:
				host_attacks += 1
				seen_attacks += 1 if visible else 0
				if visible:
					exp_attack[e["id"]] = (exp_attack.get(e["id"], []) as Array) + [[int(e["ints"][0]), e["floats"]]]
			elif visible:
				exp_tell[e["id"]] = (exp_tell.get(e["id"], []) as Array) + [[int(e["ints"][0]), e["floats"], int(e["tick"])]]
				tells[int(e["ints"][0])] = int(tells.get(int(e["ints"][0]), 0)) + 1
	var got_attack := {}
	var got_tell := {}
	for e in pup_log:
		if e["type"] == EV_ATTACK:
			got_attack[e["id"]] = (got_attack.get(e["id"], []) as Array) + [[int(e["ints"][0]), e["floats"]]]
		elif e["type"] == EV_TELEGRAPH and int(e["ints"][0]) != TELL_TOLL:
			got_tell[e["id"]] = (got_tell.get(e["id"], []) as Array) + [[int(e["ints"][0]), e["floats"], int(e["tick"])]]
	var attack_ok := got_attack.size() == exp_attack.size() and seen_attacks > 20
	for id in exp_attack:
		var a: Array = exp_attack[id]
		var b: Array = got_attack.get(id, [])
		attack_ok = attack_ok and a.size() == b.size()
		if a.size() == b.size():
			for i in a.size():
				var fa: PackedFloat32Array = a[i][1]
				var fb: PackedFloat32Array = b[i][1]
				attack_ok = attack_ok and a[i][0] == b[i][0] and Vector2(fa[0], fa[1]).distance_to(Vector2(fb[0], fb[1])) <= 0.0072 and absf(fa[2] - fb[2]) < 1e-6
	check(attack_ok, "each attack a snapshot saw begins on the guest too, with the host's blow, aim and wind-up (%d of the host's %d were seen)" % [seen_attacks, host_attacks])
	var tell_ok := got_tell.size() == exp_tell.size()
	var tell_total := 0
	for id in exp_tell:
		var a: Array = exp_tell[id]
		var b: Array = got_tell.get(id, [])
		tell_ok = tell_ok and a.size() == b.size()
		tell_total += a.size()
		if a.size() == b.size():
			for i in a.size():
				var fa: PackedFloat32Array = a[i][1]
				var fb: PackedFloat32Array = b[i][1]
				# from and aim within the quantization; the radius is the same number; the seconds left are the wind-up less the age the snapshot showed
				tell_ok = tell_ok and a[i][0] == b[i][0] and Vector2(fa[0], fa[1]).distance_to(Vector2(fb[0], fb[1])) <= 0.0072 and Vector2(fa[2], fa[3]).distance_to(Vector2(fb[2], fb[3])) <= 0.0072 \
						and absf(fa[4] - fb[4]) < 1e-6 and fb[5] <= fa[5] + 1e-6 and fb[5] >= fa[5] - 0.17 - 1e-6 and fb[5] >= 0.05 - 1e-6
	check(tell_ok and tell_total > 10, "each telegraph a snapshot saw (cone, slam, dust, erupt) is announced once with the host's place, aim and radius and the time left (%d: %s)" % [tell_total, str(tells)])
	check(tells.size() >= 3, "the fight showed at least three kinds of telegraph (%s)" % str(tells.keys()))
	# health: a drop between two delivered snapshots (and the last one to nothing at death) is one damaged event of that size
	var exp_dmg := {}
	var terms := {}
	var guest_hp := tail_hp.duplicate()   # the health the guest holds for each body: the spawn's, then what each delivered snapshot said
	for s in delivered:
		var hs: Dictionary = hp_samples[s]
		for id in hs:
			var now := float(hs[id])
			if guest_hp.has(id) and now < float(guest_hp[id]) - 1e-3:
				exp_dmg[id] = float(exp_dmg.get(id, 0.0)) + float(guest_hp[id]) - now
				terms[id] = int(terms.get(id, 0)) + 1
			guest_hp[id] = now
	for e in host_log:
		if e["type"] == EV_DIED and guest_hp.has(e["id"]):
			exp_dmg[e["id"]] = float(exp_dmg.get(e["id"], 0.0)) + float(guest_hp[e["id"]])
			terms[e["id"]] = int(terms.get(e["id"], 0)) + 1
			guest_hp[e["id"]] = 0.0
	var got_dmg := {}
	for e in pup_log:
		if e["type"] == EV_DAMAGED:
			got_dmg[e["id"]] = float(got_dmg.get(e["id"], 0.0)) + float(e["floats"][0])
	var dmg_ok := true
	var worst := 0.0
	for id in exp_dmg:
		var d := absf(float(exp_dmg[id]) - float(got_dmg.get(id, 0.0)))
		worst = maxf(worst, d)
		dmg_ok = dmg_ok and d <= 0.005 * (1 + int(terms[id]))
	for id in got_dmg:
		dmg_ok = dmg_ok and exp_dmg.has(id)
	check(dmg_ok and exp_dmg.size() > 15, "the guest's damaged events add up to the hp the delivered snapshots lost, the killing blow included (%d bodies, worst gap %.4f hp)" % [exp_dmg.size(), worst])
	# state edges: from the state the spawn told through every change the snapshots showed, to dead
	var exp_states := {}
	var prev_state := {}
	for s in delivered:
		var ss: Dictionary = samples[s]
		for id in ss:
			if int(ss[id]) == DEAD:
				continue
			var was: int = prev_state.get(id, tail.get(id, -1))
			if was != int(ss[id]):
				exp_states[id] = (exp_states.get(id, []) as Array) + [[was, int(ss[id])]]
			prev_state[id] = int(ss[id])
	for e in host_log:
		if e["type"] == EV_DIED:
			exp_states[e["id"]] = (exp_states.get(e["id"], []) as Array) + [[int(prev_state.get(e["id"], tail.get(e["id"], -1))), DEAD]]
	var got_states := {}
	for e in pup_log:
		if e["type"] == EV_STATE:
			got_states[e["id"]] = (got_states.get(e["id"], []) as Array) + [[int(e["ints"][0]), int(e["ints"][1])]]
	check(got_states == exp_states and exp_states.size() > 30, "state edges are re-derived as the snapshots show them: %d bodies, %d edges" % [exp_states.size(), exp_states.values().map(func(a: Array) -> int: return a.size()).reduce(func(x: int, y: int) -> int: return x + y, 0)])
	# thralls: a swing event for each change of the counter, a state event for each change of state, a damaged event for each drop
	var swings_exp := 0
	var swings_got := 0
	var t_states_exp := 0
	var prev_t := {}
	for s in delivered:
		var sw: Dictionary = swing_samples[s]
		for id in sw:
			if prev_t.has(id) and sw[id][1] != T_DEAD:
				swings_exp += 1 if sw[id][0] != prev_t[id][0] else 0
				t_states_exp += 1 if sw[id][1] != prev_t[id][1] else 0
			prev_t[id] = sw[id]
	var t_states_got := 0
	var t_damaged := 0
	for e in pup_log:
		if e["type"] == EV_SWING:
			swings_got += 1
		elif e["type"] == EV_T_STATE and int(e["ints"][1]) != T_DEAD:
			t_states_got += 1
		elif e["type"] == EV_T_DAMAGED:
			t_damaged += 1
	check(swings_got == swings_exp and swings_exp > 10, "a thrall swing event for each change of the swing counter between snapshots (%d)" % swings_exp)
	check(t_damaged > 0, "thrall hp drops became damaged events (%d)" % t_damaged)
	check(t_states_got >= t_states_exp, "thrall state edges are re-derived (%d, with the first ones after a raise: at least the %d between snapshots)" % [t_states_got, t_states_exp])


## The crowd draws a puppet core exactly as it draws the host's: the same rows (ids, kinds, states, flags, swings, defs, corpses), positions within the
## quantization, and instances written.
func crowd_on_puppet(host: RefCounted, pup: RefCounted) -> void:
	var ch := fake_crowd()
	var cp := fake_crowd()
	ch.sync(host)
	cp.sync(pup)
	var a: Dictionary = ch.last_feed()
	var b: Dictionary = cp.last_feed()
	var ai: PackedInt32Array = a["body_ints"]
	var bi: PackedInt32Array = b["body_ints"]
	check(ai == bi and ai.size() > 7 * 40, "DmCrowd reads the same body rows from a puppet as from the host: ids, kinds, models, states, flags, swings, defs (%d rows)" % (ai.size() / 7))
	var af: PackedFloat32Array = a["body_floats"]
	var bf: PackedFloat32Array = b["body_floats"]
	var worst := 0.0
	var yaw_worst := 0.0
	var same := af.size() == bf.size()
	if same:
		for i in range(0, af.size(), 11):
			worst = maxf(worst, Vector2(af[i], af[i + 1]).distance_to(Vector2(bf[i], bf[i + 1])))
			yaw_worst = maxf(yaw_worst, absf(angle_difference(af[i + 2], bf[i + 2])))
			same = same and is_equal_approx(af[i + 5], bf[i + 5]) and is_equal_approx(af[i + 6], bf[i + 6]) and is_equal_approx(af[i + 7], bf[i + 7])
	check(same and worst <= 0.0072 + 1e-3 and yaw_worst <= 0.02, "the rows' places are within the quantization (%.4f m, %.4f rad), their action time, scale and hover the same" % [worst, yaw_worst])
	check(a["corpse_ints"] == b["corpse_ints"] and a["corpse_floats"] == b["corpse_floats"] and a["corpse_ints"].size() > 0, "and the corpse rows are the same (%d corpses)" % (a["corpse_ints"].size() / 3))
	ch.draw(DT, 0.5, Vector3(0, 20, 20))
	cp.draw(DT, 0.5, Vector3(0, 20, 20))
	var nh: int = ch.instance_count(0, 0, false) + ch.instance_count(0, 0, true)
	var np: int = cp.instance_count(0, 0, false) + cp.instance_count(0, 0, true)
	check(nh == np and nh > 20, "both draw the same number of instances (%d)" % nh)
	# a hit the guest derived reaches the crowd like the host's own event: the same body, the same damage, the health left
	var ch2 := fake_crowd()
	var cp2 := fake_crowd()
	var victim := 0
	for id in alive_enemies(host):
		var vi: Dictionary = host.enemy_info(id)
		if float(vi["hp"]) > 40.0 and int(vi["state"]) != BURROW and int(vi["state"]) != ERUPT:
			victim = id
			break
	var hp0: float = host.enemy_info(victim)["hp"]
	host.damage(victim, 12.0, 0)
	host.step(DT)
	ch2.sync(host)
	events(host)
	pup.apply_reliable(host.take_reliable())
	pup.apply_snapshot(host.snapshot(100000))
	pup.step(DT)
	cp2.sync(pup)
	var hh: PackedFloat32Array = ch2.last_feed()["hits"]
	var ph: PackedFloat32Array = cp2.last_feed()["hits"]
	check(victim != 0 and hh.size() >= 4 and ph.size() >= 4 and int(hh[0]) == victim and int(ph[0]) == victim, "the damage reaches the crowd's hit rows on both sides, for the same body")
	if hh.size() >= 4 and ph.size() >= 4:
		check(absf(hh[1] - 12.0) < 1e-3 and absf(ph[1] - 12.0) < 0.01 and absf(hh[2] - (hp0 - 12.0)) < 1e-3 and absf(ph[2] - (hp0 - 12.0)) < 0.01 and hh[3] == ph[3], "with the damage (12 vs %.3f) and the health left (%.3f vs %.3f)" % [ph[1], hh[2], ph[2]])


func fake_crowd() -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCrowd")
	var mm := MultiMesh.new()
	var mm2 := MultiMesh.new()
	keep.append(mm)
	keep.append(mm2)
	var data := {"slug": "fake", "height": 1.0, "stride_walk": 0.7, "stride_run": 0.0,
		"clip_names": PackedStringArray(["idle", "walk", "run", "attack", "hurt", "death", "dig"]),
		"clip_seconds": PackedFloat32Array([2.0, 1.0, 0.7, 0.8, 0.5, 1.5, 1.0]), "clip_length": PackedFloat32Array([2.0, 1.0, 0.7, 0.8, 0.5, 1.5, 1.0]),
		"clip_impact": PackedFloat32Array([-1, -1, -1, 0.4, -1, -1, -1]), "clip_landing": PackedFloat32Array([-1, -1, -1, -1, -1, 1.0, -1]),
		"clip_loop": PackedInt32Array([1, 1, 1, 0, 0, 0, 0]),
		"roles": {"idle": ["idle"], "walk": ["walk"], "run": ["run"], "attack": ["attack"], "cast": ["attack"], "hurt": ["hurt"], "death": ["death"], "dig": ["dig"]}}
	var slot: int = c.add_model("fake", data, [mm.get_rid()], [mm2.get_rid()], PackedFloat32Array())
	for def in enemies_json["ENEMIES"]:
		c.set_enemy_look(def, {"model": slot, "hover": 0.0, "scale": 1.0})
	for kind in THRALL_BASE:
		c.set_thrall_look(kind, -1, {"model": slot})
	c.set_thrall_look("colossus", -1, {"model": slot})
	c.reserve(128)
	return c


# ============================================================================================ the wire

func wire_format() -> void:
	var host := make_core(7)
	host.set_replication(true)
	var h := hero(host, Vector2(0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	host.raise_thrall(thrall_stats("warrior"), h, Vector2(1, 1), 0.0, 8.0)
	spawn_wave(host, rng, 10, 5.0, 9.0, false)
	for i in 70:
		host.step(DT)
		events(host)
	var snap: PackedByteArray = host.snapshot(70)
	var rel: PackedByteArray = host.take_reliable()
	var base: PackedByteArray = host.baseline()
	check(snap.size() > 40 and rel.size() > 40 and base.size() > 40, "a snapshot (%d B), a batch (%d B) and a baseline (%d B) came out" % [snap.size(), rel.size(), base.size()])
	check(snap[0] == 0x44 and snap[1] == 0x4D and rel[0] == 0x44 and base[0] == 0x44, "every message starts with the magic DM")
	var ver: int = host.wire_version()
	check(snap[2] == 1 and rel[2] == 2 and base[2] == 3 and snap[3] == ver and rel[3] == ver and base[3] == ver, "then its kind (snapshot 1, batch 2, baseline 3) and the format version (%d)" % ver)
	# a fresh guest takes them
	var g := make_puppet()
	check(g.apply_reliable(rel) and g.apply_snapshot(snap), "a guest takes a batch and a snapshot (%s)" % g.replication_error())
	check(g.replication_error() == "", "and has no error to report")
	check(g.enemy_count() == host.enemy_count() and g.thrall_total() == host.thrall_total(), "the bodies are there (%d enemies, %d thralls)" % [g.enemy_count(), g.thrall_total()])
	# baselines taken while events wait: each seals them into the batch its number covers, and the batches go out in order
	var h3 := make_core(9)
	h3.set_replication(true)
	var hh3 := hero(h3, Vector2(0, 0))
	spawn_wave(h3, rng, 4, 4.0, 8.0, false)
	h3.step(DT)
	events(h3)
	var b1: PackedByteArray = h3.baseline()
	spawn_wave(h3, rng, 3, 4.0, 8.0, false)
	h3.step(DT)
	events(h3)
	var b2: PackedByteArray = h3.baseline()
	var r1: PackedByteArray = h3.take_reliable()
	var r2: PackedByteArray = h3.take_reliable()
	check(not r1.is_empty() and not r2.is_empty() and h3.take_reliable().is_empty(), "two baselines sealed two batches, handed out one per call, then nothing")
	var ga := make_puppet()
	var gb := make_puppet()
	check(ga.apply_reliable(b1) and ga.apply_reliable(r1) and ga.apply_reliable(r2), "a guest that took the first baseline ignores its batch and takes the next (%s)" % ga.replication_error())
	check(gb.apply_reliable(b2) and gb.apply_reliable(r1) and gb.apply_reliable(r2) and int(gb.replication_stats()["batches_duplicate"]) == 2, "one that took the second ignores both")
	check(ga.enemy_ids() == h3.enemy_ids() and gb.enemy_ids() == h3.enemy_ids() and h3.enemy_count() == 7 and hh3 > 0, "and both hold the host's seven enemies")
	# a repeated snapshot and an older one are ignored without a complaint
	check(g.apply_snapshot(snap) and int(g.replication_stats()["snapshots_stale"]) == 1, "the same snapshot again is ignored, not an error")
	host.step(DT)
	var older: PackedByteArray = host.snapshot(60)
	check(g.apply_snapshot(older) and int(g.replication_stats()["snapshots_stale"]) == 2, "an older tick is ignored, not an error")
	# version mismatch (B40): refused, the reason says which side is behind, and nothing changes
	var before: PackedInt32Array = g.enemy_ids()
	for field in [["snapshot", snap, true], ["batch", rel, false]]:
		var bytes: PackedByteArray = (field[1] as PackedByteArray).duplicate()
		bytes[3] = ver + 1
		var g2 := make_puppet()
		var ok: bool = g2.apply_snapshot(bytes) if field[2] else g2.apply_reliable(bytes)
		var why: String = g2.replication_error()
		check(not ok and "version" in why and "restart" in why and "older" in why, "a newer %s is refused, the reason names the side that must restart (%s)" % [field[0], why])
		bytes[3] = ver - 1 if ver > 1 else 0
		ok = g2.apply_snapshot(bytes) if field[2] else g2.apply_reliable(bytes)
		check(not ok and "version" in g2.replication_error() and "host" in g2.replication_error(), "an older %s is refused too (%s)" % [field[0], g2.replication_error()])
		check(g2.enemy_count() == 0, "and a refused %s changes nothing" % field[0])
	var bad_magic := snap.duplicate()
	bad_magic[0] = 0x58
	check(not g.apply_snapshot(bad_magic) and "magic" in g.replication_error(), "a message without the magic is refused (%s)" % g.replication_error())
	check(not g.apply_snapshot(rel) and "snapshot" in g.replication_error(), "a batch is not a snapshot (%s)" % g.replication_error())
	check(not g.apply_reliable(snap) and "reliable" in g.replication_error(), "and a snapshot is not a batch (%s)" % g.replication_error())
	check(g.enemy_ids() == before, "refusals left the guest's world alone")
	check(not g.apply_snapshot(PackedByteArray()) and not g.apply_reliable(PackedByteArray([1, 2, 3])), "empty and tiny messages are refused")
	# other game data: the tables the numbers index into differ
	var odd: RefCounted = ClassDB.instantiate("DmCore")
	odd.set_puppet(true)
	var half: Dictionary = {"robber": enemies_json["ENEMIES"]["robber"]}
	odd.load_enemy_defs(half)
	check(not odd.apply_snapshot(snap) and "data" in odd.replication_error(), "a guest with other enemy tables refuses (%s)" % odd.replication_error())
	# the host is not a puppet
	check(not host.apply_snapshot(snap) and "puppet" in host.replication_error(), "a host core does not apply messages (%s)" % host.replication_error())
	check(g.snapshot(1).is_empty() and g.take_reliable().is_empty() and g.baseline().is_empty(), "and a puppet builds none")
	# every cut of every message is refused, none crashes (one guest, reset between tries)
	var gg := make_puppet()
	var cuts := 0
	var accepted := 0
	for m in 3:
		var msg: PackedByteArray = [snap, rel, base][m]
		for n in msg.size():
			gg.set_puppet(true)
			var part: PackedByteArray = msg.slice(0, n)
			var ok: bool = gg.apply_snapshot(part) if m == 0 else gg.apply_reliable(part)
			cuts += 1
			accepted += 1 if ok else 0
	check(accepted == 0, "%d cut messages were all refused (%d accepted)" % [cuts, accepted])
	# damaged bytes: whatever the guest does, it does not crash and its world stays consistent
	var fuzz := RandomNumberGenerator.new()
	fuzz.seed = 3
	var survived := 0
	for k in 600:
		gg.set_puppet(true)
		gg.apply_reliable(base)
		var msg: PackedByteArray = [snap, rel, base][k % 3].duplicate()
		for flips in 1 + k % 3:
			msg[fuzz.randi() % msg.size()] = fuzz.randi() % 256
		if k % 3 == 0:
			gg.apply_snapshot(msg)
		else:
			gg.apply_reliable(msg)
		var ok := true
		for id in gg.enemy_ids():
			ok = ok and not gg.enemy_info(id).is_empty()
		for id in gg.thrall_ids():
			ok = ok and not gg.thrall_info(id).is_empty()
		gg.step(DT)
		survived += 1 if ok else 0
	check(survived == 600, "600 damaged messages: no crash, every body still answers (%d)" % survived)


# ============================================================================================ commands and queries on a puppet

## A living enemy the host removes without a death (a boss's adds leave with the boss) is gone from the guest too, by the reliable batch: the removed event.
func silent_removal() -> void:
	var host := make_core(31)
	host.set_replication(true)
	var h := hero(host, Vector2(0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	spawn_wave(host, rng, 6, 4.0, 14.0, false)
	for i in 30:
		host.step(DT)
		events(host)
	var g := make_puppet()
	g.apply_reliable(host.take_reliable())
	g.apply_snapshot(host.snapshot(30))
	var live: Array = alive_enemies(host)
	var gone: int = live[2]
	var keep_ids: Array = live.filter(func(i: int) -> bool: return i != gone)
	check(Array(g.enemy_ids()) == Array(host.enemy_ids()) and h > 0, "the guest knows the host's bodies before the removal")
	check(host.remove_enemy(gone), "the host removes a living body")
	check(g.apply_reliable(host.take_reliable()), "the batch with the removal is accepted")
	check(g.enemy_info(gone).is_empty() and g.enemy_count() == host.enemy_count() and keep_ids.all(func(i: int) -> bool: return not g.enemy_info(i).is_empty()),
		"the guest dropped exactly that body and kept the others (%d left)" % g.enemy_count())
	check(Array(g.enemy_ids()) == Array(host.enemy_ids()), "and its table is the host's, in the same order")


func puppet_refuses_and_answers() -> void:
	print("INFO the ERROR lines below, one per command, are the refusals this test provokes on a puppet core")
	var host := make_core(21)
	host.set_replication(true)
	var h := hero(host, Vector2(0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	for k in ["warrior", "wraith", "archer"]:
		host.raise_thrall(thrall_stats(k), h, Vector2(1, 1), 0.0, 8.0)
	spawn_wave(host, rng, 16, 4.0, 14.0, false)
	for i in 240:
		host.step(DT)
		events(host)
		if i == 100:
			host.apply_status(alive_enemies(host)[0], "chill", h)
			host.apply_status(alive_enemies(host)[1], "withered", h, 2.0, -1.0, {"dps": 3.0})
	var g := make_puppet()
	g.apply_reliable(host.take_reliable())
	g.apply_snapshot(host.snapshot(240))
	for i in 90:
		g.step(DT)
	events(g)
	# commands the host owns
	var victim: int = alive_enemies(g)[2]
	var hp0: float = g.enemy_info(victim)["hp"]
	var r: Dictionary = g.damage(victim, 1000.0, h)
	check(r["dealt"] == 0.0 and r["killed"] == false and r.get("refused", false) == true and is_equal_approx(g.enemy_info(victim)["hp"], hp0), "damage on a puppet is refused (reply: %s) and changes nothing" % str(r))
	var st_before: PackedByteArray = g.statuses(victim)
	g.stun(victim, 5.0)
	g.apply_status(victim, "chill", h)
	g.apply_status(victim, "withered", h, 2.0, -1.0, {"dps": 5.0})
	check(not g.remove_status(victim, "chill") and g.statuses(victim) == st_before and g.enemy_info(victim)["state"] == host.enemy_info(victim)["state"], "stun and the status commands are refused and change nothing")
	check(not g.remove_enemy(victim) and not g.enemy_info(victim).is_empty(), "remove_enemy is refused on a puppet (the host owns it) and changes nothing")
	check(g.spawn_enemy("robber", Vector2(1, 1), 1, 1.0, 1.0, false, "graves", false) == 0 and g.raise_thrall(thrall_stats("warrior"), h, Vector2(1, 1), 0.0, 8.0) == 0, "spawn_enemy and raise_thrall return 0")
	check(not g.kill_thrall(g.thrall_ids()[0], "killed") and g.sacrifice_thralls(h, -1).is_empty() and g.corpse_add(Vector2(0, 0), "normal", "robber", false, 0.0, 1.0, "graves") == 0, "kill_thrall, sacrifice_thralls and corpse_add are refused")
	if g.corpse_count() > 0:
		check(not g.corpse_consume(g.corpse_ids()[0], h), "corpse_consume is refused (the host's corpse stays)")
	g.rally_thralls(h, 6.0, 0)
	g.recall_thralls(h)
	g.set_thrall_pos(g.thrall_ids()[0], Vector2(50, 50))
	g.set_thrall_stats(g.thrall_ids()[0], {"hp": 1.0, "maxHp": 1.0})
	check(g.add_external(0, 0.4, 1.0) == 0, "heroes and bosses are brain input: a puppet takes no externals")
	check(int(g.replication_stats()["commands_refused"]) >= 10, "every refusal is counted (%d)" % int(g.replication_stats()["commands_refused"]))
	check(g.enemy_count() == host.enemy_count() and is_equal_approx(g.thrall_info(g.thrall_ids()[0])["max_hp"], host.thrall_info(host.thrall_ids()[0])["max_hp"]), "nothing the refused commands asked for happened")
	# queries: the host's answers (a body within a few millimetres of the circle's edge may fall either side)
	var diffs := 0
	var queries := 0
	for centre in [Vector2(0, 0), Vector2(6, -4), Vector2(-8, 5), Vector2(3, 10)]:
		for rad in [3.0, 6.0, 12.0]:
			queries += 1
			var a: PackedInt32Array = host.enemies_in_radius(centre, rad)
			var b: PackedInt32Array = g.enemies_in_radius(centre, rad)
			for id in a:
				if not (id in b) and absf(Vector2(host.enemy_info(id)["pos"]).distance_to(centre) - float(host.enemy_info(id)["radius"]) - rad) >= 0.05:
					diffs += 1
			for id in b:
				if not (id in a) and absf(Vector2(host.enemy_info(id)["pos"]).distance_to(centre) - float(host.enemy_info(id)["radius"]) - rad) >= 0.05:
					diffs += 1
			var ta: PackedInt32Array = host.thralls_in_radius(centre, rad, 0)
			var tb: PackedInt32Array = g.thralls_in_radius(centre, rad, 0)
			for id in ta:
				if not (id in tb) and absf(Vector2(host.thrall_info(id)["pos"]).distance_to(centre) - rad) >= 0.05:
					diffs += 1
			for id in tb:
				if not (id in ta) and absf(Vector2(host.thrall_info(id)["pos"]).distance_to(centre) - rad) >= 0.05:
					diffs += 1
	check(diffs == 0, "enemies_in_radius and thralls_in_radius answer as the host does (%d queries)" % queries)
	check(g.thrall_count(h) == host.thrall_count(h) and is_equal_approx(g.thrall_places(h), host.thrall_places(h)), "thrall_count and thrall_places match")
	var info_ok := true
	for id in g.enemy_ids():
		var i: Dictionary = g.enemy_info(id)
		var j: Dictionary = host.enemy_info(id)
		info_ok = info_ok and i["def"] == j["def"] and i["state"] == j["state"] and i["elite"] == j["elite"] and i["level"] == j["level"] and i["radius"] == j["radius"] and i["windup_s"] == j["windup_s"]
	check(info_ok, "enemy_info carries the host's def, state, level, elite flag, radius and wind-up for hover and aim")
	var st_ok := true
	for id in g.enemy_ids():
		var gs: PackedByteArray = g.statuses(id)
		var hs: PackedByteArray = host.statuses(id)
		st_ok = st_ok and gs.size() == hs.size()
		if gs.size() == hs.size():
			for k in range(0, gs.size(), 4):
				st_ok = st_ok and gs[k] == hs[k] and gs[k + 1] == hs[k + 1]
	check(st_ok, "statuses(id) lists the host's statuses (ids and stacks) on a puppet")
	check(host.statuses(alive_enemies(host)[0]).size() > 0 or host.statuses(alive_enemies(host)[1]).size() > 0, "(the host had statuses to compare)")
	check(g.status_stacks(alive_enemies(g)[1], "withered") == host.status_stacks(alive_enemies(host)[1], "withered"), "status_stacks answers")
	var cp: PackedInt32Array = g.corpse_ids()
	check(cp == host.corpse_ids(), "corpse queries have the host's corpses (%d)" % cp.size())
	if cp.size() > 0:
		var ci: Dictionary = g.corpse_info(cp[0])
		var hi2: Dictionary = host.corpse_info(cp[0])
		check(ci["kind"] == hi2["kind"] and ci["enemy"] == hi2["enemy"] and ci["x"] == hi2["x"], "corpse_info is the host's")
		var at := Vector2(float(hi2["x"]), float(hi2["z"]))
		check(g.corpse_pick(at, 1.0, 30.0, at) == host.corpse_pick(at, 1.0, 30.0, at), "corpse_pick finds the same corpse")


# ============================================================================================ the Full Party

func full_party() -> void:
	var host := make_core(77)
	host.set_replication(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var heroes := []
	for k in 4:
		heroes.append(hero(host, Vector2(-6.0 + 4.0 * k, 0.0)))
	var kinds := ["warrior", "warrior", "warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage"]
	for k in 4:
		for j in 8:
			host.raise_thrall(thrall_stats(kinds[j], 900.0, 14.0), heroes[k], Vector2(-6.0 + 4.0 * k + float(j) - 3.0, 3.0), 0.0, 20.0)
	var pup := make_puppet()
	var snap_sizes := PackedInt32Array()
	var rel_total := 0
	var t_snap := PackedFloat64Array()
	var t_rel := PackedFloat64Array()
	var t_apply_snap := PackedFloat64Array()
	var t_apply_rel := PackedFloat64Array()
	var speeds := {}
	var last_at := {}
	var party_ticks := 0
	var held_host := 0
	var held_pup := 0
	var maxed := 0
	var log: Array = []
	for tick in range(1, 1801):
		var a := float(tick) / 60.0 * 0.3
		for k in 4:
			host.set_external(heroes[k], Vector2(-6.0 + 4.0 * k, 0.0) + Vector2(cos(a + k), sin(a + k)) * 2.5, true)
		# the director keeps 72 enemies on the field and the legions at 32 (the party's thralls are sturdy; fallen ones are raised again)
		if tick % 6 == 0:
			var live := alive_enemies(host).size()
			for i in maxi(0, 72 - live):
				var ang := rng.randf() * TAU
				var rad := rng.randf_range(10.0, 24.0)
				host.spawn_enemy(WAVE[rng.randi() % WAVE.size()], Vector2(cos(ang), sin(ang)) * rad, 1, 1.0, 1.0, tick % 12 == 0 and i == 0, "graves", false)
			for k in 4:
				for j in maxi(0, 8 - host.thrall_count(heroes[k])):
					host.raise_thrall(thrall_stats(kinds[rng.randi() % 8], 900.0, 14.0), heroes[k], Vector2(-6.0 + 4.0 * k, 3.0), 0.0, 20.0)
		host.step(DT)
		events(host)
		pup.step(DT)
		if tick == 900:
			held_host = message_buffers(host)
			held_pup = message_buffers(pup)
		if tick % 3 == 0:
			var t0 := Time.get_ticks_usec()
			var snap: PackedByteArray = host.snapshot(tick)
			var t1 := Time.get_ticks_usec()
			var rel: PackedByteArray = host.take_reliable()
			var t2 := Time.get_ticks_usec()
			if rel.size() > 0:
				pup.apply_reliable(rel)
			var t3 := Time.get_ticks_usec()
			pup.apply_snapshot(snap)
			var t4 := Time.get_ticks_usec()
			events(pup)
			if tick > 300:
				t_snap.append(t1 - t0)
				t_rel.append(t2 - t1)
				if rel.size() > 0:
					t_apply_rel.append(t3 - t2)
				t_apply_snap.append(t4 - t3)
				rel_total += rel.size()
				snap_sizes.append(snap.size())
				var live_e := alive_enemies(host).size()
				if live_e == 72 and host.thrall_count(0) == 32:
					maxed += 1
				party_ticks += 1
	var biggest := 0
	var smallest := 1 << 30
	var total := 0
	for s in snap_sizes:
		biggest = maxi(biggest, s)
		smallest = mini(smallest, s)
		total += s
	var secs := float(party_ticks) / 20.0
	print("INFO Full Party (72 enemies, 32 thralls, a continuous fight): snapshot %d B on average, %d B smallest, %d B largest; budget %d B" % [total / snap_sizes.size(), smallest, biggest, BUDGET_BYTES])
	print("INFO Full Party bandwidth at 20 Hz: snapshots %.1f KB/s, reliable events %.2f KB/s (%d B in %.0f s), together %.1f KB/s" % [float(total) / secs / 1024.0, float(rel_total) / secs / 1024.0, rel_total, secs, float(total + rel_total) / secs / 1024.0])
	print("INFO Full Party times (per send, 104 bodies): build snapshot %s, take_reliable %s, apply batch %s, apply snapshot %s" % [timing(t_snap), timing(t_rel), timing(t_apply_rel), timing(t_apply_snap)])
	check(maxed > 40, "the fight held the Full Party for %d sends" % maxed)
	check(held_host > 0 and held_pup >= 0 and message_buffers(host) == held_host and message_buffers(pup) == held_pup, "the message and event buffers did not grow over the last 900 ticks of the fight: nothing allocated per tick (host %d B, guest %d B held)" % [held_host, held_pup])
	check(biggest < BUDGET_BYTES, "every Full Party snapshot fits the budget: largest %d B < %d B" % [biggest, BUDGET_BYTES])
	check(pup.enemy_ids() == host.enemy_ids() and pup.thrall_ids() == host.thrall_ids(), "and the guest holds the same %d enemies and %d thralls" % [host.enemy_count(), host.thrall_total()])
	var st: Dictionary = pup.replication_stats()
	check(st["desync"] == 0 and st["batches_refused"] == 0 and st["snapshots_refused"] == 0, "no desync in %d batches and %d snapshots" % [st["batches_applied"], st["snapshots_applied"]])


## `snapshot_parts` (the transport's packet limit, native/README.md "Co-op"): the Full Party's snapshot cut into messages of at most N bytes. Every part is a snapshot message of its
## own bodies; a puppet that applies all of them ends where one that applied the whole snapshot ends, a stale or repeated part costs nothing, an empty world is one part.
func snapshot_parts() -> void:
	var host := make_core(91)
	host.set_replication(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var heroes := []
	for k in 4:
		heroes.append(hero(host, Vector2(-6.0 + 4.0 * k, 0.0)))
	var kinds := ["warrior", "warrior", "warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage"]
	for k in 4:
		for j in 8:
			host.raise_thrall(thrall_stats(kinds[j], 900.0, 14.0), heroes[k], Vector2(-6.0 + 4.0 * k + float(j) - 3.0, 3.0), 0.0, 20.0)
	spawn_wave(host, rng, 72, 8.0, 22.0, false)
	for t in 240:   # a few seconds of fighting: states, aims, affixes and health all over the place
		host.step(DT)
		events(host)
	var whole: PackedByteArray = host.snapshot(500)
	var limits := [900, 700, 100, 1]
	var made := {}
	for limit in limits:
		var parts: Array = host.snapshot_parts(1000, limit)
		var biggest := 0
		var bodies := 0
		var ok_ticks := true
		var seen := {}
		var pup := make_puppet()
		pup.apply_reliable(host.baseline())
		for i in parts.size():
			var part: PackedByteArray = parts[i]
			biggest = maxi(biggest, part.size())
			ok_ticks = ok_ticks and part.decode_u32(8) == 1000 + i
			check(pup.apply_snapshot(part), "a part of %d bytes is accepted (limit %d): %s" % [part.size(), limit, pup.replication_error()])
		made[limit] = parts
		for id in host.enemy_ids():
			seen[id] = true
		check(ok_ticks, "the parts' ticks count up from the first one (limit %d)" % limit)
		check(biggest <= maxi(limit, 48), "no part is longer than the limit %d (largest %d B, %d parts)" % [limit, biggest, parts.size()])
		var ref := make_puppet()
		ref.apply_reliable(host.baseline())
		ref.apply_snapshot(whole)
		var diff := 0
		for id in host.enemy_ids():
			var a: Dictionary = ref.enemy_info(id)
			var b: Dictionary = pup.enemy_info(id)
			if a.is_empty() != b.is_empty() or (not a.is_empty() and (a["net_pos"] != b["net_pos"] or a["hp"] != b["hp"] or a["state"] != b["state"] or a["yaw"] != b["yaw"])):
				diff += 1
		for id in host.thrall_ids():
			var a2: Dictionary = ref.thrall_info(id)
			var b2: Dictionary = pup.thrall_info(id)
			if a2.is_empty() != b2.is_empty() or (not a2.is_empty() and (a2["net_pos"] != b2["net_pos"] or a2["hp"] != b2["hp"] or a2["state"] != b2["state"])):
				diff += 1
		check(diff == 0, "applying the %d parts of limit %d gives the same enemies and thralls as the whole snapshot (%d differ)" % [parts.size(), limit, diff])
		var st: Dictionary = pup.replication_stats()
		bodies = int(st["snapshots_applied"])
		check(bodies == parts.size() and st["snapshots_refused"] == 0 and st["snapshots_stale"] == 0, "a puppet applied %d snapshot messages, none refused or stale" % bodies)
	var live := 0
	for st_e in host.enemy_states():
		live += 1 if st_e != DEAD else 0
	for st_t in host.thrall_states():
		live += 1 if st_t != T_DEAD else 0
	check(made[900].size() >= 2 and made[1].size() == live, "the Full Party needs %d parts at 900 B, one body per part at 1 B (%d parts for about %d bodies)" % [made[900].size(), made[1].size(), live])
	print("INFO snapshot_parts: the Full Party (%d bodies) as %d parts at 900 B (whole snapshot %d B), %d at 700 B" % [live, made[900].size(), whole.size(), made[700].size()])
	# stale and repeated parts: only a newer tick is applied; the rest of a lost part's bodies catch up with the next snapshot
	var pup2 := make_puppet()
	pup2.apply_reliable(host.baseline())
	var ps: Array = host.snapshot_parts(2000, 700)
	check(pup2.apply_snapshot(ps[1]) and pup2.apply_snapshot(ps[0]) and pup2.apply_snapshot(ps[1]), "parts that arrive out of order or twice are not an error")
	var st2: Dictionary = pup2.replication_stats()
	check(st2["snapshots_applied"] == 1 and st2["snapshots_stale"] == 2, "only the newest tick applied (applied %d, stale %d): the older part waits for the next snapshot" % [st2["snapshots_applied"], st2["snapshots_stale"]])
	# an empty world is one part that still carries the clock
	var empty := make_core(5)
	var ep: Array = empty.snapshot_parts(1, 1300)
	check(ep.size() == 1 and ep[0].size() <= 40, "an empty world is one small part (%d B)" % (ep[0].size() if ep.size() > 0 else -1))
	# a guest may not build them
	var pp := make_puppet()
	var refused: Array = pp.snapshot_parts(1, 1300)
	check(refused.is_empty() and pp.replication_stats()["commands_refused"] > 0, "a puppet refuses to build parts")
	keep.append(host)


## What the buffers of the wire and the event buffer hold (the first six parts of buffer_parts; the body tables double at a new peak, as they always did).
func message_buffers(c: RefCounted) -> int:
	var parts: Array = c.replication_stats()["buffer_parts"]
	var sum := 0
	for i in 6:
		sum += int(parts[i])
	return sum


func timing(v: PackedFloat64Array) -> String:
	if v.is_empty():
		return "-"
	var s := v.duplicate()
	s.sort()
	var sum := 0.0
	for x in s:
		sum += x
	return "mean %.0f us, p95 %.0f us, max %.0f us" % [sum / s.size(), s[int(s.size() * 0.95)], s[s.size() - 1]]
