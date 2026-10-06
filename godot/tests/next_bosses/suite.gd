extends SceneTree
## Shared base of the per-boss suites in tests/next_bosses (abbess_run.gd, congregation_run.gd, prelate_run.gd; the Gravedigger's run.gd is standalone).
## A subclass sets BOSS / hero spots and implements `_parts()`; this file holds what every boss test needs: the counting fx back-ends, a solo game,
## the by-hand boss stepping (set_physics_process(false) + _physics_process(1/60): exact timing), the event log, the generic summon / defeat /
## two-peer / frame-cost checks. Lines print as `N passed, M failed`; exit 1 on failure.

const DT := 1.0 / 60.0
var PORT := DmTestPorts.free_port()
var _trace := OS.get_environment("BOSS_TRACE") != ""   ## BOSS_TRACE=1 prints every check as it runs (to place an engine error)

var boss_id := ""
var passed := 0
var failed := 0
var log_ := ErrLog.new()
var api: DmApi
var character: Dictionary
var g: DmNextGame
var hb: DmHeroBody
var evs: Array = []          ## [{t: room clock, ev}] every brain event of the active boss
var hurts: Array = []
var boss: DmBoss
var after_kill := Callable()   ## check_defeat calls it right after the lethal hit
var stub := Stub.new()       ## the fx back-ends of the solo game
var astub := Stub.new()


class ErrLog extends Logger:
	var errors: Array = []
	var suite: Object
	func _frames(bt: Array) -> String:
		var out := ""
		for b: ScriptBacktrace in bt:
			for i in mini(4, b.get_frame_count()):
				out += " < %s:%d %s" % [b.get_frame_file(i).get_file(), b.get_frame_line(i), b.get_frame_function(i)]
		return out
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s [after check %d]%s" % [file.get_file(), line, code, rationale, suite.passed + suite.failed, _frames(bt)])


## Counting back-ends for the fx (every Vfx / AudioDirector call the router makes).
class Stub extends Node:
	var calls: Dictionary = {}
	var sfx: Array = []
	var particle_scale := 1.0
	var hitstop_scale := 1.0
	func _count(n: String) -> void:
		calls[n] = int(calls.get(n, 0)) + 1
	func danger(cb: Callable, _keep: bool = false) -> void:
		_count("danger")
		cb.call()
	func play_sfx(name_: String, _pos: Variant = null, _i: float = 1.0) -> bool:
		sfx.append(name_)
		return true
	class Handle extends RefCounted:
		var alive := true
		func kill() -> void:
			alive = false
	func decal(_o: Dictionary) -> Variant:
		_count("decal")
		return Handle.new()
	func emit(_o: Dictionary) -> void:
		_count("emit")
	func emit_smoke(_o: Dictionary) -> void:
		_count("emit")
	func light_flash(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void:
		_count("flash")
	func flash(_o: Dictionary) -> void:
		_count("flash")
	func spike_line(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null, _f: Variant = null) -> void:
		_count("spike")
	func beam(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null) -> void:
		_count("beam")
	func projectile(_o: Dictionary) -> void:
		_count("proj")
	func play(_id: String, _a: Variant = null, _b: Variant = null) -> Variant:
		_count("bb")
		return null
	func _get(_prop: StringName) -> Variant:
		return null


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if _trace:
		print("#%d %s" % [passed + failed + 1, what])
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func _run() -> void:
	log_.suite = self
	OS.add_logger(log_)
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("boss%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	await _parts()
	check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), ", ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _parts() -> void:
	pass


# ---- helpers -----------------------------------------------------------------------------------------------------------------------

func def() -> Dictionary:
	return DmContent.boss(boss_id)


func site() -> Vector3:
	return g.bosses.site_pos(boss_id)


## 2 m in front of the summoning site (inside the 4 m summon range), and the arena's centre.
func near_site() -> Vector3:
	return site() + Vector3(0.0, 0.0, 2.0)


func arena() -> Vector3:
	return Vector3(float(def()["arena"]["x"]), 0.0, float(def()["arena"]["z"]))


func _new_game(opts: Dictionary, host_root: Node = null) -> DmNextGame:
	var n: DmNextGame = load("res://next/next_game.tscn").instantiate()
	(host_root if host_root != null else root).add_child(n)
	await n.start(character, api, opts)
	return n


## A solo slice game with the counting fx back-ends and the event / hurt logs wired.
func new_solo() -> void:
	g = await _new_game({"dressing": false, "hud": false, "waves": false, "audio": false})
	hb = g.local_body()
	g.bosses.brain_event.connect(func(ev: Dictionary, b: DmBoss) -> void:
		evs.append({"t": b.world.t, "ev": ev.duplicate(true)})
		if ev["t"] == "hurt":
			hurts.append(ev))
	stub = Stub.new()
	astub = Stub.new()
	g.bosses.fx.set_backends(stub, astub)
	hb.p["stats"]["maxHp"] = 1.0e5   # the fight is about numbers, not about the hero surviving them
	hb.heal(1.0e6)
	await ticks(2)


## The member's soul shards, set outright: the progression syncs with the backend when the hero changes area (a reply restores the saved count), so a test
## sets what it needs right before the call that spends it.
func set_shards(n: int) -> void:
	member().prog.local["shards"] = n


func member() -> DmRewardsMember:
	return g.rewards.members[int(character.get("id", 0))]


## Step the boss `secs` of room time by hand, healing the hero so nothing kills it.
func step(secs: float) -> void:
	for i in int(round(secs / DT)):
		boss._physics_process(DT)
		if hb.hp < hb.max_hp * 0.5:
			hb.heal(1e6)


func events(kind: String, ms_gt: float = -1.0) -> Array:
	var out: Array = []
	for e in evs:
		var ev: Dictionary = e["ev"]
		if ev["t"] == "boss" and ev["kind"] == kind and (ms_gt < 0.0 or float(ev.get("ms", 0.0)) > ms_gt):
			out.append(e)
	return out


func telegraphs(kind: String) -> Array:
	return events(kind, 0.0)


func impacts(kind: String) -> Array:
	return events(kind).filter(func(e: Dictionary) -> bool: return float(e["ev"].get("ms", 0.0)) == 0.0)


func dmg_scale() -> float:
	return (1.0 + 0.15 * (float(boss.brain.state["level"]) - 1.0)) * float(DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]["enemyDamageMult"])


## Hurts of exactly `base` x scale since index `from`.
func hurts_of(base: float, from: int = 0) -> Array:
	return hurts.slice(from).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - base * dmg_scale()) < 1e-6)


## Step until `cond` (by hand), at most `limit` seconds; true if it held.
func step_until(cond: Callable, limit: float) -> bool:
	for i in int(limit / 0.05):
		if cond.call():
			return true
		step(0.05)
	return cond.call()


## One tick at a time until `cond` (exact event times); true if it held within `limit` seconds.
func tick_until(cond: Callable, limit: float) -> bool:
	for i in int(limit / DT):
		if cond.call():
			return true
		step(DT)
	return cond.call()


## Wake the boss with the hero at its site: shards are added, the area is assumed, the body is stepped by hand. Returns the refusal ("" = woken).
func summon(shards: int = 20) -> String:
	g.bosses.assume_area = String(def()["area"])
	hb.teleport(near_site())
	set_shards(shards)
	evs.clear()
	hurts.clear()
	var why := g.bosses.try_summon(g.session.get_my_id(), boss_id)
	if why == "":
		boss = g.bosses.active_boss()
		boss.set_physics_process(false)
		boss.world.refresh()
	return why


## Put the hero at `p` and refresh the brain's view of it.
func put(p: Vector3) -> void:
	hb.teleport(p)
	boss.world.refresh()


## Set the brain's hp (a plain `boss.hp = ` is only the body's mirror) as a fraction of max.
func set_hp(frac: float) -> void:
	boss.brain.state["hp"] = boss.max_hp * frac
	boss.hp = boss.max_hp * frac


## Drop the boss to `frac` of its max hp (through take_damage, like a hit) and run one tick so the phase change fires.
func wound(frac: float) -> void:
	boss.take_damage(boss.hp - boss.max_hp * frac, hb)
	step(0.1)


func end_fight() -> void:
	if boss != null and is_instance_valid(boss):
		boss.queue_free()
	await ticks(3)
	boss = null


func awaken_hp_ok(base_hp: float) -> bool:
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want: float = base_hp * (1.0 + 0.22 * (float(boss.brain.state["level"]) - 1.0)) * float(diff["enemyHpMult"])
	return is_equal_approx(boss.max_hp, want) and boss.hp == boss.max_hp


# ---- generic checks every boss shares

## The summon prompt is the hub's (no fading toast): near the site "<kbd>E</kbd> Summon X · N shards", gone away from it and while a boss is awake (also
## for a hover over the site); key E wakes it; clicking the site (the hub's `interacted`) asks the same host. Ends with the boss gone again.
func check_prompt_and_key() -> void:
	var toasts: Array = []
	g.bosses.fx.host.sink = func(id: String, _ctx: Dictionary) -> void: toasts.append(id)
	var ch: DmChapterhouse = g.chapterhouse
	g.bosses.assume_area = String(def()["area"])
	hb.teleport(near_site())
	await ticks(45)   # past the host's 0.5 s tick, where the old "press E" toast fired
	ch._update_prompt(hb)
	check(ch.prompt_text == "<kbd>E</kbd> Summon %s · %d shards" % [def()["name"], int(def()["shards"])], "A: at the site the hub prompt reads '%s'" % ch.prompt_text)
	check(not toasts.has("toast"), "A: no fading toast any more")
	var it: Dictionary = {}
	for x in ch.interactables:
		if String(x["id"]) == String(def()["summonId"]):
			it = x
	ch.hover = it
	ch._update_prompt(hb)
	check(ch.prompt_text == "<kbd>Click</kbd> Summon %s · %d shards" % [def()["name"], int(def()["shards"])], "A: hovering the site shows the click prompt")
	ch.hover = null
	hb.teleport(Vector3(0, 0, 20))
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "A: away from the site: no prompt")
	hb.teleport(near_site())
	set_shards(int(def()["shards"]))
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_E
	ev.pressed = true
	g.bosses._unhandled_input(ev)
	check(g.bosses.active_boss() != null and g.bosses.active_boss().boss_id == boss_id and int(member().prog.local["shards"]) == 0, "A: key E at the site wakes it (its shards spent)")
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "A: the prompt hides while a boss is awake")
	ch.hover = it
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "A: ...and the hover prompt of its site too")
	ch.hover = null
	g.bosses.fx.host.sink = Callable()
	hb.teleport(Vector3(0, 0, 20))   # leaving the area: it goes back to sleep (its adds leave with it)
	g.bosses.assume_area = ""
	await ticks(4)
	check(g.bosses.active_boss() == null and g.director.enemies.is_empty(), "A: (the prompt test's boss went back to sleep, nothing left behind)")

## Summon rules: far, not live, shards (none spent), the boss's own cost, busy, dead. Leaves the boss awake (`boss` set).
func check_summon_rules(cost: int, not_live: String) -> void:
	var peer := g.session.get_my_id()
	g.bosses.assume_area = String(def()["area"])
	hb.teleport(Vector3(0, 0, 20))
	check(g.bosses.try_summon(peer, boss_id) == "far", "A: summon refused away from the site (far)")
	check(g.bosses.try_summon(peer, not_live) == "unknown", "A: an id that is no boss is not summonable (%s)" % not_live)
	hb.teleport(near_site())
	await ticks(2)
	check(g.bosses.site_pos(boss_id).distance_to(site()) < 0.01 and site() != Vector3.INF, "A: the site is the area's %s interactable" % def()["summonId"])
	check(g.bosses.site_near(near_site(), 4.0) == boss_id, "A: site_near names the boss at its site")
	var m := member()
	set_shards(0)
	check(g.bosses.try_summon(peer, boss_id) == "shards" and g.bosses.active_boss() == null, "A: no shards -> refused, nothing woken")
	set_shards(cost - 1)
	check(g.bosses.try_summon(peer, boss_id) == "shards" and int(m.prog.local["shards"]) == cost - 1, "A: %d of %d shards is not enough and none are spent" % [cost - 1, cost])
	check(g.bosses.why_text("shards", boss_id, peer).contains(String(def()["summonLabel"])) and g.bosses.why_text("shards", boss_id, peer).contains("(you have %d)" % (cost - 1)), "A: the refusal names the site and the count")
	set_shards(cost + 2)
	var summoned: Array = []
	g.bosses.summoned.connect(func(b: String, p: int) -> void: summoned.append([b, p]))
	var spawned: Array = []
	g.bosses.boss_spawned.connect(func(b: DmBoss) -> void: spawned.append(b))
	var before := int(m.prog.local["shards"])
	evs.clear()
	check(g.bosses.try_summon(peer, boss_id) == "", "A: %d shards wake it" % (cost + 2))
	boss = g.bosses.active_boss()
	boss.set_physics_process(false)
	boss.world.refresh()
	check(int(m.prog.local["shards"]) == before - cost and summoned == [[boss_id, peer]], "A: the boss's own cost (%d shards) is spent, `summoned` fires" % cost)
	check(spawned.size() == 1 and boss.is_in_group(&"dm_boss") and boss.is_in_group(&"dm_enemy"), "A: DmBoss spawned (boss_spawned, group dm_boss + dm_enemy)")
	check(g.bosses.try_summon(peer, boss_id) == "busy" and int(m.prog.local["shards"]) == before - cost, "A: a second summon while it is awake is refused (busy), no shards taken")
	check(g.bosses.try_summon(999, boss_id) == "dead", "A: an unknown/dead summoner is refused")
	check(g.bosses.site_near(near_site(), 4.0) == boss_id, "A: (the prompt asks the hub: site_near still names it, the hub hides the prompt while awake)")


## Defeat: lethal hit -> DEAD at once, `defeated` names the killer, the member is paid (first kill unless `first` false), the report entry rides the
## next batch, sounds. Returns the shard total dropped.
func check_defeat(first: bool, bonus_shards: int) -> int:
	var drops: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _p: Vector3) -> void: drops.append(d))
	var earned: Array = []
	g.rewards.boss_earned.connect(func(_c: int, id: String, f: bool, _p: Vector3) -> void: earned.append([id, f]))
	var reported: Array = []
	g.rewards.batch_reported.connect(func(b: int, r: Variant) -> void: reported.append([b, r]))
	var died: Array = []
	boss.died.connect(func(_e: DmEnemy) -> void: died.append(1))
	var defeated: Array = []
	g.bosses.defeated.connect(func(id: String, killer: int, _p: Vector3) -> void: defeated.append([id, killer]))
	put(arena() + Vector3(3.0, 0.0, 0.0))
	g.rewards.rng = func() -> float: return 0.5
	var m := member()
	var xp0: float = float(m.prog.character["experience"])
	var bosses0 := int(m.stats["bosses"])
	boss.take_damage(boss.hp + 1.0, hb)
	if after_kill.is_valid():
		after_kill.call()   # progression state straight after the kill (the backend sync that follows may restore the saved one)
	check(boss.hp == 0.0 and boss.sm.id() == DmEnemyState.Id.DEAD and not boss.is_hittable() and died.size() == 1, "A: lethal hit -> DEAD at once, died emitted")
	check(events("defeated").size() == 1 and str(events("defeated")[0]["ev"]["killer"]) == str(g.session.get_my_id()) and defeated == [[boss_id, g.session.get_my_id()]], "A: defeated event names the killer")
	check("bossDefeat" in astub.sfx, "A: bossDefeat sound")
	check(earned == [[boss_id, first]], "A: the member is paid (first kill: %s)" % first)
	var shards := 0
	for d in drops:
		if d.get("kind") == "shard":
			shards += int(d["amount"])
	check(drops.size() >= 2 and shards >= bonus_shards, "A: gold + shards + items dropped (%d drops, %d shards)" % [drops.size(), shards])
	check(float(m.prog.character["experience"]) > xp0 or int(m.stats["levels"]) > 0, "A: boss XP applied")
	check(int(m.stats["bosses"]) == bosses0 + 1 and m.reporter._bosses.size() == 1, "A: boss kill queued for the backend report {boss, tier, diff, first}")
	var key: String = m.reporter._bosses.keys()[0]
	check(key.begins_with("%s|" % boss_id) and key.contains("|%d|" % (1 if first else 0)), "A: reported with first=%s (%s)" % [first, key])
	await g.rewards.flush()
	check(reported.size() >= 1 and not m.reporter.has_pending() and reported[0][1] is Dictionary and not (reported[0][1] as Dictionary).has("error"), "A: batch sent through the party session, backend answered, nothing pending")
	return shards


## The boss's hit by a rite (Bone Needle at it) and a thrall engaging it from its edge, crediting the owner.
func check_thralls_and_rites() -> void:
	g.world.builder.set_unlocked([String(def()["area"])])   # the area's navmesh (thralls walk it) is what a broken seal switches on
	await ticks(45)
	var caster: DmRiteCaster = hb.get_node("Rites")
	put(arena() + Vector3(-5.0, 0.0, 2.0))
	check(g.enemies_in_radius(boss.global_position, 0.5).has(boss) and g.enemy_by_id(int(boss.get_meta(&"dm_id"))) == boss, "A: the rite world sees the boss (enemies_in_radius / enemy_by_id)")
	var hp_r := boss.hp
	caster.request_cast("bone_needle", boss.global_position, int(boss.get_meta(&"dm_id")))
	await until(func() -> bool: return boss.hp < hp_r, 3.0)
	check(boss.hp < hp_r, "A: Bone Needle damages the boss (%.1f)" % (hp_r - boss.hp))
	hb.heal(1e6)
	var th: DmThrallHost = hb.get_node("Thralls")
	th.clear()
	var rr: Dictionary = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 40.0, "attackSpeedMult": 1.0})
	check(bool(rr["ok"]), "A: a thrall is raised")
	var t1: DmThrall = rr["thralls"][0]
	t1.global_position = arena() + Vector3(-7.0, 0.0, 2.0)
	boss.set_physics_process(true)
	var hp_t := boss.hp
	var engaged := await until(func() -> bool: return t1.target == boss, 6.0)
	check(engaged, "A: the thrall engages the boss (edge rule)")
	await until(func() -> bool: return boss.hp < hp_t - 1.0, 8.0)
	check(boss.hp < hp_t and boss.brain.last_hit_by == str(g.session.get_my_id()), "A: thrall blows hurt the boss and credit the owner")
	boss.set_physics_process(false)
	th.clear()
	hb.heal(1e6)
	boss.stun(5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "A: a stun staggers the boss at most 0.5 s")
	var st0: float = boss.brain.stagger_t
	boss.stun(5.0)
	check(is_equal_approx(boss.brain.stagger_t, st0), "A: stun has a cooldown (no stun-lock)")


## Wipe: the hero leaves the area, the boss resets (no reward) and can be woken again.
func check_wipe() -> void:
	var resets: Array = []
	g.bosses.reset.connect(func(id: String) -> void: resets.append(id))
	var earned0 := int(member().stats["bosses"])
	hb.teleport(Vector3(0, 0, 20))
	g.bosses.assume_area = ""
	boss.world.refresh()
	step(0.1)
	check(resets == [boss_id] and not boss.is_hittable() and boss.sm.id() != DmEnemyState.Id.DEAD, "A: everyone gone -> the boss resets (can be woken again)")
	check(int(member().stats["bosses"]) == earned0, "A: a reset pays nothing")


## Whole-frame cost (DmFrameCost) with the boss engine-driven vs not, plus the by-hand brain tick.
func check_perf(extra_note: String) -> void:
	hb.heal(1e6)
	g.director.enabled = false
	boss.world.refresh()
	var samples: Array = []
	for i in 400:
		var u0 := Time.get_ticks_usec()
		boss._physics_process(DT)
		samples.append(Time.get_ticks_usec() - u0)
	samples.sort()
	var med: float = samples[samples.size() / 2]
	print("perf: %s brain tick median %.0f us, p95 %.0f us (%s)" % [boss_id, med, samples[int(samples.size() * 0.95)], extra_note])
	check(med < 400.0, "C: boss tick median %.0f us < 400 us (budget)" % med)
	var fc := DmFrameCost.attach(root)
	await ticks(5)
	var offs: Array = []
	var ons: Array = []
	var worsts: Array = []   ## worst frame of each boss-ticking block; the cap is on their median (one block can catch a stall of the shared VPS)
	for round_ in 3:   # interleaved blocks: the shared VPS drifts
		boss.set_physics_process(false)
		fc.reset()
		for i in 60:
			await physics_frame
			hb.heal(1e6)
		offs.append(fc.median_ms())
		boss.set_physics_process(true)
		fc.reset()
		for i in 60:
			await physics_frame
			hb.heal(1e6)
		ons.append(fc.median_ms())
		worsts.append(fc.worst_ms())
	boss.set_physics_process(false)
	offs.sort()
	ons.sort()
	worsts.sort()
	if not fc.stalls.is_empty():
		print("perf: stalls (wall ms, cpu ms, load): ", fc.stalls)
	print("perf: %s whole frame median %.2f ms without the boss ticking, %.2f ms with it (worst frame per block %s ms)" % [boss_id, offs[1], ons[1], str(worsts)])
	check(ons[1] < 14.0 and worsts[1] < 150.0, "C: frame median %.2f ms under 14, typical worst %.1f ms under 150" % [ons[1], worsts[1]])
	check(ons[1] - offs[1] < 2.0, "C: the boss adds < 2 ms per frame (%.2f ms)" % (ons[1] - offs[1]))
	fc.queue_free()


# ---- two peers (B) ----------------------------------------------------------------------------------------------------------------------

var hg: DmNextGame
var cg: DmNextGame
var hstub := Stub.new()
var cstub := Stub.new()
var hast := Stub.new()
var cast_ := Stub.new()
var hboss: DmBoss
var cboss: DmBoss


## A host and a client over ENet on a free port; the boss is summoned on the host with the host's hero at its site; `cboss` is the client's puppet.
func two_peers_summon() -> void:
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	hg = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	cg = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(PORT, 4) == OK, "B: ENet server on a free port")
	await hg.start(character, api, {"peer": sp, "dressing": false, "hud": false, "waves": false, "audio": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", PORT)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "hud": false, "audio": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "B: client joined")
	hg.bosses.fx.set_backends(hstub, hast)
	cg.bosses.fx.set_backends(cstub, cast_)
	var hh := hg.local_body()
	hg.bosses.assume_area = String(def()["area"])
	hh.teleport(hg.bosses.site_pos(boss_id) + Vector3(0.0, 0.0, 2.0))
	await ticks(3)
	var hm: DmRewardsMember = hg.rewards.members[int(character.get("id", 0))]
	hm.prog.local["shards"] = int(def()["shards"])
	check(hg.bosses.try_summon(hg.session.get_my_id(), boss_id) == "", "B: host summons")
	hboss = hg.bosses.active_boss()
	hboss.set_physics_process(false)
	var bid := int(hboss.get_meta(&"dm_id"))
	check(await until(func() -> bool: return cg.bosses.boss_by_id(bid) != null and cg.bosses.boss_by_id(bid).is_inside_tree(), 6.0), "B: the boss body spawns on the client (same dm_id)")
	cboss = cg.bosses.boss_by_id(bid)
	check(cboss != null and not cboss.is_multiplayer_authority() and cboss.brain == null and cboss.boss_id == boss_id, "B: client body is a brainless puppet")
	check(await until(func() -> bool: return cboss.bstate.active and absf(cboss.max_hp - hboss.max_hp) < 0.01, 4.0), "B: state replicates (active, max hp)")
	hh.teleport(Vector3(float(def()["arena"]["x"]) + 3.0, 0.0, float(def()["arena"]["z"])))
	hboss.world.refresh()


func two_peers_end() -> void:
	hg.queue_free()
	cg.queue_free()
	await ticks(3)


## B's generic tail: events once per peer, the awaken sound once on each, phase + hp + position replicate, defeat reaches the client.
func two_peers_common_tail() -> void:
	var hh := hg.local_body()
	check(await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events, 3.0), "B: every event is played exactly once per peer (host %d, client %d)" % [hg.bosses.fx.events, cg.bosses.fx.events])
	check(hast.sfx.count("bossAwaken") == 1 and cast_.sfx.count("bossAwaken") == 1, "B: the awaken sound plays once on each peer")
	check(await until(func() -> bool: return cstub.calls.get("decal", 0) > 0, 3.0), "B: the client played the telegraph decals")
	hboss.take_damage(hboss.hp - hboss.max_hp * 0.55, hh)
	for i in 10:
		hboss._physics_process(DT)
	check(await until(func() -> bool: return cboss.phase == 2 and absf(cboss.hp - hboss.hp) < 1.0, 3.0), "B: phase and hp replicate (client phase %d, hp %.0f / %.0f)" % [cboss.phase, cboss.hp, hboss.hp])
	check(await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events, 2.0), "B: the phase event reached the client once")
	check(cboss.global_position.distance_to(hboss.global_position) < 1.5, "B: the client's boss follows the host's position")
	hboss.take_damage(hboss.hp + 1.0, hh)
	check(await until(func() -> bool: return cboss.sm.id() == DmEnemyState.Id.DEAD, 3.0), "B: the client sees the boss die")
	check(await until(func() -> bool: return cast_.sfx.has("bossDefeat"), 3.0), "B: the defeat sound plays on the client too")
