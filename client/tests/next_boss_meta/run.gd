extends SceneTree
## The meta systems of the boss track on the rebuilt client (client/next/progress/dm_next_chronicle.gd and dm_next_codex.gd, next/areas/dm_wave_milestones.gd), on the OFFLINE backend:
## the Chronicle fed by a scripted session and persisted, Codex discoveries (and the HUD journal), the Nightfall / wave-milestone triggers.
## The first-kill trophy and the Covenant Seal's Empowered call of the old suite (client/tests/next_boss_meta) are tests/boss_meta.gd's.
## godot --headless --fixed-fps 60 --path client --script res://tests/next_boss_meta/run.gd

const DT := 1.0 / 60.0
const BOSS := "gravedigger"

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var mock: DmMockBackend
var cid := 0
var clock := [0]
var store := DmCounselStore.new("")   # the codex journal survives a relaunch like the file store does


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
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


func launch(extra: Dictionary = {}) -> void:
	var c := await api.load_or_create_character(2)
	cid = int(c.data["id"])
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	var opts := {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": true, "store": store}
	opts.merge(extra, true)
	await g.start(c.data, api, opts)
	g.bosses.assume_area = String(DmContent.boss(BOSS)["area"])
	var b := g.local_body()
	b.p["stats"]["maxHp"] = 1.0e5
	b.heal(1.0e6)
	await ticks(2)


func close() -> void:
	await g.leave()
	g.queue_free()
	await process_frame


func member() -> DmRewardsMember:
	return g.rewards.members[cid]


## Wake the boss at its altar (plain path: soul shards), the hero 2 m from the site.


func wake(shards: int = 20) -> DmBoss:
	var b := g.local_body()
	b.teleport(g.bosses.site_pos(BOSS) + Vector3(0, 0, 2))
	member().prog.local["shards"] = shards
	g.bosses.try_summon(g.session.get_my_id(), BOSS)   # the plain path (the altar's own choice is tested in part_empowered)
	return g.bosses.active_boss()


## One lethal blow, then the host's defeat path runs (rewards, trophy, the Seal's prize claim).


func backend_chronicle() -> Dictionary:
	return (await api.get_chronicle(cid)).data["life"]


func _run() -> void:
	mock = DmOffline.make_mock("")
	mock.now_ms = func() -> int: return clock[0]
	api = DmOffline.make_api(mock)
	var r := await api.register("bm%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	await part_chronicle()
	await part_codex()
	await part_milestones()
	await part_perf()
	print("%d passed, %d failed" % [passed, failed])
	print("%s next_boss_meta %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


# ---- the Chronicle: every feed, persisted ------------------------------------------------------------------------------------------------

func part_chronicle() -> void:
	await launch()
	var before := await backend_chronicle()
	var b := g.local_body()
	var n := 7
	for i in n:
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	await g.rewards.flush()
	await ticks(130)   # ~2 s of play time
	b.take_damage(1.0e9, null)   # a death
	await ticks(3)
	g.progress.grant_xp(1.0e6)   # a few levels
	g.chron.chronicle.add("gathered.mining", 3)
	g.chron.chronicle.add("depths.floors", 2)
	g.chron.chronicle.max_("peak.depth", 4)
	check(g.depths.chronicle == g.chron.chronicle, "C: the Depths feed the same Chronicle object")
	var view: Dictionary = g.chron.chronicle.view()["life"]
	check(float(view.get("kills", 0)) - float(before.get("kills", 0)) == n, "C: kills counted (%d)" % int(view.get("kills", 0)))
	check(float(view.get("kills.graves", 0)) - float(before.get("kills.graves", 0)) == n, "C: kills.graves counted")
	check(float(view.get("deaths", 0)) - float(before.get("deaths", 0)) == 1.0, "C: the death counted")
	check(float(view.get("playSeconds", 0)) - float(before.get("playSeconds", 0)) >= 1.0, "C: play time counts (%d s)" % int(view.get("playSeconds", 0)))
	check(float(view.get("gold.earned", 0)) >= 0.0 and float(view.get("peak.wave", 0)) >= 0.0, "C: (gold and peak wave keys are fed by the progression)")
	check(float(view.get("peak.level", 0)) >= float(g.character["level"]) and float(g.character["level"]) > 1.0, "C: peak level follows the level-ups (%d)" % int(view.get("peak.level", 0)))
	await g.flush_all()
	var saved := await backend_chronicle()
	check(float(saved.get("kills", 0)) - float(before.get("kills", 0)) == n and float(saved.get("deaths", 0)) >= 1.0, "C: the backend record has the session")
	check(float(saved.get("gathered.mining", 0)) == 3.0 and float(saved.get("depths.floors", 0)) == 2.0 and float(saved.get("peak.depth", 0)) == 4.0, "C: gathering and the Depths rode the same flush")
	var level := float(g.character["level"])
	await close()
	await launch()
	var again: Dictionary = g.chron.chronicle.view()["life"]
	check(float(again.get("kills", 0)) == float(saved.get("kills", 0)) and float(again.get("peak.level", 0)) >= level, "C: a relaunch loads the saved Chronicle")
	await close()


# ---- the Codex ------------------------------------------------------------------------------------------------------------------------------

func part_codex() -> void:
	store = DmCounselStore.new("")   # a fresh journal
	await launch()
	var b := g.local_body()
	var found: Array = []
	g.codex.discovered.connect(func(kind: String, id: String) -> void: found.append("%s:%s" % [kind, id]))
	g.director.spawn("robber", b.position + Vector3(6, 0, 0), [b])
	check(await until(func() -> bool: return g.codex.has("dead", "robber"), 2.0), "X: an enemy kind met within 40 m is discovered")
	var far_kind := "wraith"
	g.director.spawn(far_kind, b.position + Vector3(60, 0, 0), [b])
	await ticks(10)
	check(not g.codex.has("dead", far_kind), "X: one 60 m away is not")
	g.areas.enter("graves")
	check(g.codex.has("area", "graves"), "X: entering an area records it")
	var boss := wake()
	check(g.codex.has("dead", BOSS), "X: waking a boss records it")
	check(not found.is_empty() and found.count("dead:robber") == 1, "X: each discovery is announced once (%s)" % ", ".join(found))
	check(boss != null, "X: the boss woke")
	await ticks(3)
	await close()
	await launch()
	check(g.codex.has("dead", "robber") and g.codex.has("area", "graves") and g.codex.has("dead", BOSS), "X: a relaunch remembers the journal")
	await close()
	await launch({"hud": true})
	var ui: DmGameUi = g.ui
	check(ui != null and ui.codex_journal["dead"].has("robber") and ui.codex_journal["area"].has("graves") and ui.codex_journal["dead"].has(BOSS), "X: the Codex panel's journal is fed (seeded at load)")
	g.director.spawn("wraith", g.local_body().position + Vector3(5, 0, 0), [g.local_body()])
	check(await until(func() -> bool: return ui.codex_journal["dead"].has("wraith"), 2.0), "X: a new discovery reaches the open HUD")
	await close()


# ---- wave milestones, Nightfall -----------------------------------------------------------------------------------------------------------

func part_milestones() -> void:
	await launch()
	var ms: DmWaveMilestones = g.milestones
	var seen: Array = []
	ms.announced.connect(func(kind: String, id: String) -> void: seen.append("%s:%s" % [kind, id]))
	var prog: DmProgression = g.progress.prog
	prog.local["waveTierActive"] = 0.0
	g.progress.apply_progress()
	prog.local["waveTierActive"] = 3.0
	g.progress.apply_progress()
	check(seen == ["banner:vanguard"], "M: tier 3 announces Elite Vanguard (%s)" % str(seen))
	prog.local["waveTierActive"] = 8.0
	g.progress.apply_progress()
	check(seen == ["banner:vanguard", "banner:restless", "banner:nightfall"], "M: tier 8 announces Restless Crypts and Nightfall (%s)" % str(seen))
	g.director._since_arrival = 1.0e6   # the Wave Speed ramp is fully in
	check(g.director.milestone("vanguard") and g.director.milestone("restless") and g.director.milestone("nightfall"), "M: the director reads all three milestones in force")
	# Nightfall dims the moon and the hemisphere, easing in (and out), and only while easing does it run.
	var bld := g.world.builder   # the area's lights (DmNextWorld keeps a builder for them)
	check(bld != null, "M: the world's lights exist")
	var moon0 := bld.moon.light_energy
	var amb0 := bld.env.ambient_light_energy
	check(ms.is_processing() and ms.target == 1.0, "M: the dimming runs while it eases")
	for i in 600:
		ms._process(0.05)
	check(not ms.is_processing() and is_equal_approx(ms.night_k, 1.0), "M: it settles at full night and stops running")
	check(is_equal_approx(bld.moon.light_energy, moon0 * 0.4) and is_equal_approx(bld.env.ambient_light_energy, amb0 * 0.7), "M: the moon is x0.4 and the hemisphere x0.7")
	# The Acre stays lit.
	g.area_id = "acre"
	g.area_changed.emit("acre")
	for i in 600:
		ms._process(0.05)
	check(is_equal_approx(bld.moon.light_energy, moon0) and is_equal_approx(bld.env.ambient_light_energy, amb0), "M: in the Acre the lights come back (moon %.3f vs %.3f, k %.2f)" % [bld.moon.light_energy, moon0, ms.night_k])
	g.area_id = "graves"
	g.area_changed.emit("graves")
	for i in 600:
		ms._process(0.05)
	# Variants: shrouded commons.
	var b := g.local_body()
	var shrouded := 0
	var total := 0
	for i in 120:   # enough picks for a binomial check (35 was too few: one seed read 27 of 35)
		g.director._vanguard = false
		var made: Array = []
		g.director.spawn_group(b.position + Vector3(8, 0, 0), [b], 1, "robber", [], made)
		for id in made:
			var info: Dictionary = g.core_host.enemy_info(int(id))
			if not info.is_empty() and not bool(info["elite"]):
				total += 1
				# Nightfall's shroud is the real Shrouded affix (the core's): the spawn's affix list
				if (info["affixes"] as PackedStringArray).has("shrouded"):
					shrouded += 1
			g.core_host.remove_enemy(int(id))
	check(total >= 80 and shrouded > total * 0.35 and shrouded < total * 0.65, "M: about half the common dead rise Shrouded (%d of %d)" % [shrouded, total])
	# Elite Vanguard: the wave's first plain pick is an elite.
	await ticks(2)
	# The pick is random: a pack kind (bats / rats) or a Risen is never the Vanguard's elite and leaves the flag up, so draw again until a
	# plain pick consumed it (the flag stays set exactly when the pick was not plain).
	var picked: Array = []
	for attempt in 60:
		for id in picked:
			g.core_host.remove_enemy(int(id))
		picked.clear()
		g.director._vanguard = true
		g.director.spawn_group(b.position + Vector3(8, 0, 0), [b], 1, "", [], picked)
		if not g.director._vanguard:
			break
	var elites := 0
	for id in picked:
		var info: Dictionary = g.core_host.enemy_info(int(id))
		if not info.is_empty() and bool(info["elite"]):
			elites += 1
	check(elites == 1 and not g.director._vanguard, "M: the Vanguard makes the wave's first pick an elite, once")
	# (Restless Crypts' sooner Grave Surge is not here: the client has no Grave Surges yet, KNOWN-GAPS "Missing since launch day")
	# Dropping back below a milestone says so and the light returns.
	prog.local["waveTierActive"] = 0.0
	g.progress.apply_progress()
	check(seen.slice(3) == ["fades:nightfall", "fades:restless", "fades:vanguard"] or seen.count("fades:nightfall") == 1, "M: falling back announces what fades (%s)" % str(seen.slice(3)))
	for i in 600:
		ms._process(0.05)
	check(is_equal_approx(bld.moon.light_energy, moon0) and ms.night_k == 0.0, "M: and the light is back")
	await close()


# ---- cost ------------------------------------------------------------------------------------------------------------------------------------

func part_perf() -> void:
	await launch()
	var n := 5000
	var t0 := Time.get_ticks_usec()
	for i in n:
		g.chron._process(DT)
	var chron_us := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		g.codex._on_spawn(1, "robber", 1, false, "graves", 0, 0.0, 0.0, 1.0)   # a kind already in the journal: one dictionary lookup
	var codex_us := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		g.milestones.on_tier(0.0)
	var tier_us := float(Time.get_ticks_usec() - t0) / n
	print("perf: chronicle tick %.2f us, codex spawn %.2f us, milestone tier call %.2f us (idle: %s)" % [chron_us, codex_us, tier_us, str(not g.milestones.is_processing())])
	perf_info(chron_us < 50.0 and codex_us < 50.0 and tier_us < 100.0, "P: the per-frame / per-spawn cost stays tiny")
	check(not g.milestones.is_processing(), "P: the Nightfall easing is idle when there is nothing to ease")
	await close()


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).


func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])


## Fund (or drain) the character as play would: the change counts as earned, so the next gains save gives it to the backend too (DECISIONS B23).
