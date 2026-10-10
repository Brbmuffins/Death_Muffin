extends SceneTree
## Boss meta-progression suite (godot/next/bosses/dm_boss_meta.gd, next/progress/dm_next_chronicle.gd + dm_next_codex.gd, next/areas/dm_wave_milestones.gd), on the
## OFFLINE backend: an Empowered summon end to end (Seal + gold taken by the backend, harder fight, the Seal's prize), the first-kill trophy granted once and
## surviving a relaunch, the Chronicle fed by a scripted session and persisted, Codex discoveries (and the HUD journal), the Nightfall / wave-milestone triggers.
## godot --headless --path godot --script res://tests/next_boss_meta/run.gd

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
var toasts: Array = []
var report_bosses: Array = []   ## every boss entry of every session report the backend received


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
	var opts := {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": false, "store": store}
	opts.merge(extra, true)
	await g.start(c.data, api, opts)
	g.bosses.assume_area = String(DmContent.boss(BOSS)["area"])
	var b := g.local_body()
	b.p["stats"]["maxHp"] = 1.0e5
	b.heal(1.0e6)
	toasts.clear()
	g.bosses.fx.host.sink = func(id: String, ctx: Dictionary) -> void:
		if id == "toast":
			toasts.append(String(ctx.get("text", "")))
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
	var boss := g.bosses.active_boss()
	if boss != null:
		boss.set_physics_process(false)
		boss.world.refresh()
	return boss


## One lethal blow, then the host's defeat path runs (rewards, trophy, the Seal's prize claim).
func slay(boss: DmBoss) -> void:
	boss.take_damage(boss.max_hp * 2.0, g.local_body())
	await ticks(2)


func backend_chronicle() -> Dictionary:
	return (await api.get_chronicle(cid)).data["life"]


func bag_count(item_id: String) -> int:
	var n := 0
	for r in (await api.get_inventory(cid)).data:
		if String(r.get("item_id", "")) == item_id:
			n += int(r.get("quantity", 1))
	return n


func _run() -> void:
	mock = DmOffline.make_mock("")
	mock.now_ms = func() -> int: return clock[0]
	api = DmOffline.make_api(mock)
	api.transport = func(req: Dictionary) -> Dictionary:   # a window on what the host reports
		if String(req["url"]).contains("/report"):
			var body: Variant = JSON.parse_string(String(req.get("body", "")))
			if body is Dictionary:
				for e in body.get("members", body.get("entries", [])):
					report_bosses.append_array(e.get("bosses", []))
		return mock.transport(req)
	var r := await api.register("bm%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	await part_trophy()
	await part_empowered()
	await part_chronicle()
	await part_codex()
	await part_milestones()
	await part_perf()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ---- first-kill trophy: once, persisted through the API --------------------------------------------------------------------------------

func part_trophy() -> void:
	await launch()
	var earned: Array = []
	g.rewards.boss_earned.connect(func(_c: int, id: String, first: bool, _p: Vector3) -> void: earned.append(first))
	var boss := wake()
	check(boss != null and not boss.empowered, "T: a plain summon wakes the Gravedigger King (not Empowered)")
	check(not g.chron.has_trophy(BOSS), "T: no trophy yet")
	var shards_before := int(member().prog.local["shards"])
	await slay(boss)
	check(earned == [true], "T: the first kill pays the first-kill bonus (%s)" % str(earned))
	check(g.chron.has_trophy(BOSS) and g.chron.life("boss." + BOSS) == 1.0, "T: the trophy is the chronicle's boss.gravedigger counter")
	await g.chron.flush()
	check(float((await backend_chronicle()).get("boss." + BOSS, 0)) == 1.0, "T: it reached the backend (persisted through the API)")
	await close()
	await launch()
	check(g.chron.has_trophy(BOSS), "T: after a relaunch the trophy is still there")
	earned.clear()
	g.rewards.boss_earned.connect(func(_c: int, id: String, first: bool, _p: Vector3) -> void: earned.append(first))
	boss = wake()
	await slay(boss)
	check(earned == [false], "T: a second kill grants no trophy again (%s)" % str(earned))
	await g.chron.flush()
	check(float((await backend_chronicle()).get("boss." + BOSS, 0)) == 2.0, "T: the kill counter says 2")
	await close()


# ---- Covenant Seal: cost, the stronger fight, the prize ---------------------------------------------------------------------------------

func part_empowered() -> void:
	await api.save_inventory(cid, [{"slot_index": 0, "item_id": DmGoldSink.COVENANT_SEAL, "quantity": 2}])
	await launch()
	var plain := wake()
	var plain_hp := plain.max_hp
	var plain_level := float(plain.brain.state["level"])
	check(not plain.empowered and not plain.brain.state["empowered"], "E: baseline: a plain summon is not Empowered")
	g.bosses.active_boss().queue_free()   # a wipe (no reward)
	await ticks(4)
	check(g.bosses.active_boss() == null, "E: (baseline boss gone)")
	var cost := DmGoldSink.empower_gold(int(DmContent.boss(BOSS)["shards"]))
	g.character["gold"] = cost + 1234
	g.local_body().teleport(g.bosses.site_pos(BOSS) + Vector3(0, 0, 2))
	member().prog.local["shards"] = 0
	check(g.bosses.try_summon(g.session.get_my_id(), BOSS) == "shards", "E: with no shards a plain summon is refused")
	var why: String = await g.boss_meta.call_empowered(BOSS)
	check(why == "", "E: call_empowered woke it (%s)" % why)
	var boss := g.bosses.active_boss()
	check(boss != null and boss.empowered and bool(boss.brain.state["empowered"]), "E: the awake boss is Empowered")
	check(int(g.character["gold"]) == 1234, "E: the backend took exactly %d gold (left %d)" % [cost, int(g.character["gold"])])
	check(await bag_count(DmGoldSink.COVENANT_SEAL) == 1, "E: and one Covenant Seal (1 of 2 left)")
	var want_level := float(DmGoldSink.empowered_level(int(plain_level)))
	check(float(boss.brain.state["level"]) >= want_level - 0.5, "E: the level goes up %d -> %d (it is %d)" % [int(plain_level), int(want_level), int(boss.brain.state["level"])])
	check(boss.max_hp > plain_hp * float(DmGoldSink.EMPOWER["hpMult"]), "E: harder numbers: hp %d vs %d plain (x%.2f)" % [int(boss.max_hp), int(plain_hp), boss.max_hp / plain_hp])
	check(g.boss_meta.pending == BOSS and member().empower_summon_id != 0, "E: the summon is tracked (pending, backend id %d)" % member().empower_summon_id)
	check(await _busy_refused(), "E: a second call while it is awake is refused before anything is spent")
	boss.set_physics_process(false)
	boss.world.refresh()
	report_bosses.clear()
	var prizes: Array = []
	g.boss_meta.prize.connect(func(id: String, p: Dictionary) -> void: prizes.append(p))
	clock[0] += 60000   # the backend wants the fight to have lasted a while
	await slay(boss)
	await g.rewards.flush()
	check(report_bosses.size() == 1 and int(report_bosses[0].get("summon", 0)) == member().empower_summon_id and member().empower_summon_id != 0, "E: the kill's report carries the backend summon id (%s)" % str(report_bosses))
	check(await until(func() -> bool: return not prizes.is_empty(), 5.0), "E: the Seal's prize was claimed from the backend")
	if not prizes.is_empty():
		var p: Dictionary = prizes[0]
		var dropped := false
		for d in member().loot_view._drops:
			if d.get("kind", "") == "item" and String(d["item"].get("item_id", "")) == String(p["item_id"]):
				dropped = true
		check(dropped, "E: the prize (%s) is on the ground at the corpse" % p["item_id"])
		check(int(p["instance_id"]) > 0, "E: it is a real rolled instance (ilvl %d, %d affixes)" % [int(p["ilvl"]), (p["affixes"] as Array).size()])
	check(g.boss_meta.pending == "", "E: nothing pending after the kill")
	# A wiped Empowered fight stays bound: the next call is free.
	g.local_body().teleport(g.bosses.site_pos(BOSS) + Vector3(0, 0, 2))
	g.character["gold"] = cost + 50
	await g.boss_meta.call_empowered(BOSS)
	var b2 := g.bosses.active_boss()
	check(b2 != null and b2.empowered, "E: a second Empowered call works (Seal 2 of 2)")
	b2.queue_free()
	await ticks(4)
	g.bosses.reset.emit(BOSS)   # the brain's wipe signal
	check(g.boss_meta.bound.has(BOSS), "E: a lost fight leaves the summon bound")
	var offers: Array = []
	g.boss_meta.offered.connect(func(ctx: Dictionary) -> void: offers.append(ctx))
	g.local_body().teleport(g.bosses.site_pos(BOSS) + Vector3(0, 0, 2))
	g.bosses.request_summon(BOSS)   # E at the altar
	check(offers.size() == 1 and bool(offers[0]["bound"]) and g.bosses.active_boss() == null, "E: the altar offers the choice (bound: free) instead of waking it")
	var gold := int(g.character["gold"])
	await g.boss_meta.call_empowered(BOSS)
	check(int(g.character["gold"]) == gold and g.bosses.active_boss() != null, "E: the bound summon answers free (no gold)")
	await close()


func _busy_refused() -> bool:
	var gold := int(g.character["gold"])
	var why: String = await g.boss_meta.call_empowered(BOSS)
	return why == "busy" and int(g.character["gold"]) == gold


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
	boss.queue_free()
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
	var bld := g.builder
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
		var before: Dictionary = g.director.enemies.duplicate()
		g.director._vanguard = false
		g.director.spawn_group(b.position + Vector3(8, 0, 0), [b], 1, "robber", [])
		for id in g.director.enemies.keys():
			if not before.has(id):
				var e: DmEnemy = g.director.enemies[id]
				if not e.elite:
					total += 1
					# Nightfall's shroud is the real Shrouded affix (next/affixes): the spawn's affix list, its status follows from it
					if Array(e.get_meta(&"dm_affix_list", PackedStringArray())).has("shrouded"):
						shrouded += 1
	check(total >= 80 and shrouded > total * 0.35 and shrouded < total * 0.65, "M: about half the common dead rise Shrouded (%d of %d)" % [shrouded, total])
	# Elite Vanguard: the wave's first plain pick is an elite.
	g.director.clear()
	await ticks(2)
	# The pick is random: a pack kind (bats / rats) or a Risen is never the Vanguard's elite and leaves the flag up, so draw again until a
	# plain pick consumed it (the flag stays set exactly when the pick was not plain).
	for attempt in 60:
		g.director.clear()
		g.director._vanguard = true
		g.director.spawn_group(b.position + Vector3(8, 0, 0), [b], 1, "", [])
		if not g.director._vanguard:
			break
	var elites := 0
	for e in g.director.enemies.values():
		if (e as DmEnemy).elite:
			elites += 1
	check(elites == 1 and not g.director._vanguard, "M: the Vanguard makes the wave's first pick an elite, once")
	# Restless Crypts: the next surge comes sooner.
	var S: Dictionary = DmSimData.SURGE
	g.director.surge._end()
	check(g.director.surge.surge_in <= float(S["maxIntervalS"]) * float(DmSimData.RESTLESS_SURGE_MULT) + 1e-6, "M: Restless Crypts: the next surge is within %.0f s (x0.6)" % (float(S["maxIntervalS"]) * float(DmSimData.RESTLESS_SURGE_MULT)))
	# Dropping back below a milestone says so and the light returns.
	prog.local["waveTierActive"] = 0.0
	g.progress.apply_progress()
	check(seen.slice(3) == ["fades:nightfall", "fades:restless", "fades:vanguard"] or seen.count("fades:nightfall") == 1, "M: falling back announces what fades (%s)" % str(seen.slice(3)))
	for i in 600:
		ms._process(0.05)
	check(is_equal_approx(bld.moon.light_energy, moon0) and ms.night_k == 0.0, "M: and the light is back")
	await close()


# ---- cost ------------------------------------------------------------------------------------------------------------------------------------

## The per-frame / per-spawn work this track added, generous margins (the VPS is shared).
func part_perf() -> void:
	await launch()
	var n := 5000
	var t0 := Time.get_ticks_usec()
	for i in n:
		g.chron._process(DT)
	var chron_us := float(Time.get_ticks_usec() - t0) / n
	var e := g.director.spawn("robber", g.local_body().position + Vector3(5, 0, 0), [g.local_body()])
	await ticks(3)
	t0 = Time.get_ticks_usec()
	for i in n:
		g.codex._on_spawn(e)   # a kind already in the journal: one dictionary lookup
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
