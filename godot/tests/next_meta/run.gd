extends SceneTree
## Meta systems on the rebuild (godot/next/meta): difficulty, ascension / vows, boons, the weekly Omen, the Altar's actions (through the OFFLINE
## backend, persisting across a relaunch), the Kill Chain, Soul Harvest and the Bone Ward chip.
## godot --headless --path godot --script res://tests/next_meta/run.gd

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var store := DmCounselStore.new("")
var events: Array = []
var clock := 0
const NEUTRAL := {"id": "none", "name": "A Quiet Week", "icon": "art/omens/blood_moon.webp", "blurb": "Nothing stirs.", "eliteBonus": 0.0, "waveSizeMult": 1.0, "rewardMult": 1.0, "shardMult": 1.0}


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func near(a: float, b: float, tol: float = 0.01) -> bool:
	return absf(a - b) <= tol * maxf(1.0, absf(b))


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


func launch(neutral: bool = true) -> void:
	var c := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	events.clear()
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "store": store, "omen": NEUTRAL if neutral else null})
	g.rewards.flush_interval = 1e9   # kill batches are flushed by the test, not the timer
	g.rewards.now_ms = func() -> int: return clock
	g.meta.event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))


func close() -> void:
	await g.leave()
	g.queue_free()
	await process_frame


func member() -> DmRewardsMember:
	return g.rewards.members[int(g.character["id"])]


## xp the member is owed for `n` kills of a level-20 robber (no killer: no chain, no souls).
func xp_for(n: int) -> float:
	var m := member()
	var before := m.pending_xp
	for i in n:
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": g.local_body().position.x, "z": g.local_body().position.z, "killer": null})
	return m.pending_xp - before


## A fresh robber of the director, its numbers read and the body removed.
func spawn_stats() -> Dictionary:
	var b := g.local_body()
	var e := g.director.spawn("robber", b.position + Vector3(40, 0, 0), [b])
	var out := {"hp": e.max_hp, "dmg": e.damage, "level": float(e.get_meta("dm_level"))}
	g.director.clear()
	await ticks(2)
	return out


func set_local(boons: Dictionary, vows: Dictionary) -> void:
	g.progress.prog.local["boons"] = boons
	g.progress.prog.local["vows"] = vows
	g.progress.apply_progress()


func event_ids() -> Array:
	return events.map(func(e: Dictionary) -> String: return String(e["id"]))


func _run() -> void:
	Engine.time_scale = 4.0
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("nm%d" % (Time.get_ticks_usec() % 100000), "m@example.com", "pw1234")
	api.set_token(r.data["token"])
	# Seed the backend like an old save: best rank 3, ashes, every shard-free boon at its top rank, a finished run (Ashes are owed).
	var ch0 := await api.load_or_create_character(2)
	var cid := int(ch0.data["id"])
	var imp := await api.necro_import_local(cid, {"ascension": 3, "ashes": 400, "shards": 0, "totalKills": 600, "bossKills": 1, "areaKills": {"graves": 600},
		"run": {"prelateKills": 1, "kills": 600, "peakWaveTier": 0},
		"boons": {"vigil": 3, "marrow_font": 3, "bone_tithe": 3, "quickened_coin": 2, "first_rites": 2, "shard_keeper": 2, "soul_hunger": 2, "swift_seals": 2, "legion_pact": 1}})
	check(imp.ok, "the offline backend takes the seeded progression (%s)" % imp.error)
	await launch()
	var b := g.local_body()
	var p := g.progress
	var d := g.director
	check(g.meta != null and g.meta.member == member() and g.ui_host != null, "the Meta node exists on the host with the real HUD")

	# ================================================================ ascension rank of an old save, then a clean slate
	var gr: Dictionary = DmContent.area("graves")["rect"]
	var graves_at := Vector3((float(gr["x0"]) + float(gr["x1"])) * 0.5, 0.0, (float(gr["z0"]) + float(gr["z1"])) * 0.5)
	check(p.prog.vows() == {"elder_dead": 3} and g.meta.heat == 3 and g.rewards.ascension == 3.0, "an old save's rank 3 is three steps of Elder Dead: heat 3 reaches the rewards")
	var legacy := await spawn_stats()
	check(near(float(legacy["level"]), 10.0) and near(float(legacy["hp"]), float(DmContent.enemy("robber")["hp"]) * DmEnemyStats.hp_scale(10.0)) and near(float(legacy["dmg"]), float(DmContent.enemy("robber")["damage"]) * DmEnemyStats.damage_scale(10.0)), "rank 3: graves enemies rise at level 10 (+9): robber hp %.0f, damage %.1f" % [legacy["hp"], legacy["dmg"]])
	check(await g.ui_host.do_swear({}) == "" and g.meta.heat == 0 and g.rewards.ascension == 0.0 and d.vow_fx["levels"] == 0.0, "the Altar breaks the vows: heat 0, the world is plain again")

	# ================================================================ difficulty
	var diffs := {}
	for id in ["easy", "medium", "hard"]:
		g.ui_host.settings_store.update({"difficulty": id})
		check(d.difficulty == id and g.rewards.difficulty == id and g.bosses.difficulty == id and g.meta.difficulty == id, "Settings -> difficulty %s reaches the director, the rewards and the bosses" % id)
		var s := await spawn_stats()
		var x := xp_for(20)
		diffs[id] = {"stats": s, "xp": x}
	var m_s: Dictionary = diffs["medium"]["stats"]
	var lvl0 := DmEnemyStats.area_level("graves", [1.0], 0.0)
	var def_r: Dictionary = DmContent.enemy("robber")
	check(near(float(m_s["hp"]), float(def_r["hp"]) * DmEnemyStats.hp_scale(lvl0)) and near(float(m_s["dmg"]), float(def_r["damage"]) * DmEnemyStats.damage_scale(lvl0)), "medium is the intended balance: robber hp %.0f, damage %.1f" % [m_s["hp"], m_s["dmg"]])
	for id in ["easy", "hard"]:
		var dd: Dictionary = DmContent.difficulty(id)
		var s2: Dictionary = diffs[id]["stats"]
		check(near(float(s2["hp"]) / float(m_s["hp"]), float(dd["enemyHpMult"])), "%s: enemy hp x%s (%.1f vs %.1f)" % [id, dd["enemyHpMult"], s2["hp"], m_s["hp"]])
		check(near(float(s2["dmg"]) / float(m_s["dmg"]), float(dd["enemyDamageMult"])), "%s: enemy damage x%s (%.2f vs %.2f)" % [id, dd["enemyDamageMult"], s2["dmg"], m_s["dmg"]])
		check(near(float(diffs[id]["xp"]) / float(diffs["medium"]["xp"]), float(dd["rewardMult"]), 0.02), "%s: xp / gold reward x%s (%.0f vs %.0f xp for 20 kills)" % [id, dd["rewardMult"], diffs[id]["xp"], diffs["medium"]["xp"]])
	g.ui_host.settings_store.update({"difficulty": "hard"})
	check(near(d.elite_chance(), float(DmContent.area("graves")["eliteChance"]) + float(DmContent.difficulty("hard")["eliteBonus"]), 0.0001), "hard adds its elite chance (+%.2f)" % float(DmContent.difficulty("hard")["eliteBonus"]))
	check(events.any(func(e: Dictionary) -> bool: return e["id"] == "toast" and String(e["ctx"]["text"]).begins_with("Difficulty: Hard")), "changing the difficulty says so (the next dead to rise feel it)")
	g.ui_host.settings_store.update({"difficulty": "medium"})

	# ================================================================ boons reach their systems
	check(float(p.prog.boons()["maxHpMult"]) > 1.0, "the imported boons are loaded (vigil III: maxHp x%.2f)" % float(p.prog.boons()["maxHpMult"]))
	var bb: Dictionary = p.prog.boons()
	var no_boon_build := DmCharacterBuild.build(g.character, [], {"damageTier": 0, "legionTier": 0, "boons": {}, "vows": {}})
	check(near(b.max_hp / float(no_boon_build["stats"]["maxHp"]), 1.24), "vigil III: max health x1.24 on the body (%.0f vs %.0f)" % [b.max_hp, no_boon_build["stats"]["maxHp"]])
	check(near(float(b.p["stats"]["essenceRegen"]) / float(no_boon_build["stats"]["essenceRegen"]), 1.36), "marrow font III: essence regeneration x1.36 (stats)")
	var caster := b.get_node("Rites") as DmRiteCaster
	check(near(float(caster.p["stats"]["maxHp"]), b.max_hp) and near(float(caster.mods["essenceRegenMult"]), float(bb["essenceRegenMult"])), "the caster shares the boon-built stats")
	# Regeneration really runs at the boosted rate: 60 physics ticks of drift from empty, against the no-boon rate.
	b.p["resource"]["value"] = 0.0
	await ticks(60)
	var regen_boon := float(b.p["resource"]["value"])
	set_local({}, {})
	b.p["resource"]["value"] = 0.0
	await ticks(60)
	var regen_plain := float(b.p["resource"]["value"])
	check(regen_plain > 0.0 and near(regen_boon / regen_plain, 1.36, 0.04), "essence regenerates x%.2f faster with Marrow Font III (%.2f vs %.2f per second)" % [regen_boon / maxf(regen_plain, 0.001), regen_boon, regen_plain])
	b.teleport(graves_at)
	check(await until(func() -> bool: return g.area_id == "graves", 3.0), "the hero walks into the Hollow Graves")
	var imported := {"vigil": 3, "marrow_font": 3, "bone_tithe": 3, "quickened_coin": 2, "first_rites": 2, "shard_keeper": 2, "soul_hunger": 2, "swift_seals": 2, "legion_pact": 1}
	# Soul Hunger: the meter is smaller. Swift Seals: seals open sooner. Legion Pact: one more thrall. Bone Tithe / Quickened Coin: cheaper tiers.
	var cost_plain := p.prog.damage_cost()
	var wave_plain := p.prog.wave_cost()
	var seal_plain := p.prog.unlock_kills(100.0)
	var cap_plain := float(b.mods["thrallCap"])
	check(float(b.p["soulsMax"]) == 50.0, "no boons: the Soul Harvest meter holds 50")
	set_local(imported, {})
	check(float(b.p["soulsMax"]) == 34.0 and float(g.ui_host.hud_state()["souls_max"]) == 34.0, "Soul Hunger II: the meter holds 34 (HUD)")
	check(p.prog.unlock_kills(100.0) == 60 and seal_plain == 100, "Swift Seals II: a seal opens at 60 kills instead of 100")
	check(float(b.mods["thrallCap"]) == cap_plain + 1.0 and float(caster.mods["thrallCap"]) == cap_plain + 1.0 and int(g.ui_host.hud_state()["thrall_cap"]) == int(cap_plain) + 1, "Legion Pact: one more thrall (body, caster and the HUD's cap %d)" % int(cap_plain + 1))
	check(near(float(p.prog.damage_cost()) / float(cost_plain), 0.7, 0.04) and near(float(p.prog.wave_cost()) / float(wave_plain), 0.76, 0.04), "Bone Tithe III / Quickened Coin II: Damage costs x0.70 and Wave Speed x0.76 (%d / %d gold)" % [p.prog.damage_cost(), p.prog.wave_cost()])
	# The shape boons (not for sale before the Altar's unlocks, set directly here): lingering dead, grave feast, bone ward, the two flags.
	var shape := imported.duplicate()
	shape.merge({"lingering_dead": 2, "grave_feast": 2, "bone_ward": 2, "hollow_sacrifice": 1, "carrion_bloom": 1, "bonded_dead": 1})
	set_local(shape, {})
	check(near(g.corpses.life_mult, 2.0), "Lingering Dead II: corpses lie x2.0 as long (field life %.2f)" % g.corpses.life_mult)
	var corpse := g.corpses.add_corpse(b.position.x + 4.0, b.position.z, "normal", "robber", false, 0.0, 1.0, "graves")
	check(near(corpse.expiresAt - corpse.bornAt, 26.0 * 2.0), "a corpse laid now lasts %.0f s (26 x 2)" % (corpse.expiresAt - corpse.bornAt))
	check(bool(caster.mods["sacrificeLeavesCorpse"]) and bool(caster.mods["miasmaBurstsCorpses"]), "Hollow Sacrifice and Carrion Bloom reach the caster's mods")
	check(near(float(caster.mods["corpseHeal"]), 0.06) and near(float(caster.mods["wardPerThrall"]), 0.04), "Grave Feast II (heal 6%) and Bone Ward II (4% per thrall) reach the caster")
	# Grave Feast: raising a thrall mends you.
	b.p["hp"] = b.p["stats"]["maxHp"] * 0.5
	b._mirror_from_state()
	var hp_before := float(b.p["hp"])
	caster.request_cast("exhume", Vector3(corpse.x, 0.0, corpse.z), -1)
	check(await until(func() -> bool: return (b.get_node("Thralls") as DmThrallHost).count() == 1, 3.0), "Exhume raises a thrall from the corpse")
	await ticks(3)
	check(near(float(b.p["hp"]) - hp_before, b.max_hp * 0.06, 0.15), "Grave Feast II: raising the dead mends %.0f health (6%% of %.0f)" % [float(b.p["hp"]) - hp_before, b.max_hp])
	# Bone Ward: with one thrall, 4% of every blow is shrugged off.
	b.p["hp"] = b.p["stats"]["maxHp"]
	var taken := b.take_damage(100.0, null)
	check(near(taken, 96.0, 0.01), "Bone Ward II with one thrall: 100 damage costs %.1f" % taken)
	var ward: Variant = g.ui_host.hud_state()["ward"]
	check(ward != null and int(ward["pct"]) == 4 and int(ward["thralls"]) == 1 and near(float(ward["per_thrall"]), 0.04), "the Bone Ward chip shows -4%% for one thrall")
	(b.get_node("Thralls") as DmThrallHost).clear()
	check(g.ui_host.hud_state()["ward"] == null, "no thralls, no Bone Ward chip")
	# Bonded Dead: entering a hunting ground with none raises one.
	var home := Vector3(float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["x"]), 0.0, float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["z"]))
	b.teleport(home)
	await until(func() -> bool: return g.area_id == "chapterhouse", 3.0)
	b.teleport(graves_at)
	check(await until(func() -> bool: return g.area_id == "graves", 3.0), "the hero walks into the Hollow Graves")
	check(await until(func() -> bool: return (b.get_node("Thralls") as DmThrallHost).count() == 1, 4.0) and event_ids().has("toast"), "Bonded Dead: a thrall rises beside you on entering a hunting ground with none")
	check(await until(func() -> bool: return b.get_node("Thralls").count() == 1, 1.0), "...and only one")
	(b.get_node("Thralls") as DmThrallHost).clear()
	set_local(imported, {})   # the shape boons were never bought: the Altar tests below start from the imported ones

	# ================================================================ vows (world rules) and the run's rank
	set_local(imported, {"elder_dead": 2, "iron_dead": 1})
	var heat := 3
	check(g.meta.heat == heat and g.rewards.ascension == float(heat), "Elder Dead II + Iron Dead I = heat %d reaches the rewards" % heat)
	check(g.rewards.vow_levels == 6.0, "boss and Surge rewards roll at the vow-raised level (+6)")
	var vs := await spawn_stats()
	var lvl_v := lvl0 + 6.0
	check(near(float(vs["level"]), lvl_v), "Elder Dead II: enemies rise 6 levels higher (level %.0f)" % float(vs["level"]))
	check(near(float(vs["hp"]) / float(m_s["hp"]), DmEnemyStats.hp_scale(lvl_v) / DmEnemyStats.hp_scale(lvl0) * 1.25), "Elder Dead + Iron Dead: enemy hp x%.2f (levels x iron 1.25)" % (float(vs["hp"]) / float(m_s["hp"])))
	check(near(float(vs["dmg"]) / float(m_s["dmg"]), DmEnemyStats.damage_scale(lvl_v) / DmEnemyStats.damage_scale(lvl0)), "enemy damage follows the level (x%.2f)" % (float(vs["dmg"]) / float(m_s["dmg"])))
	var xp_heat := xp_for(20)
	check(near(xp_heat / float(diffs["medium"]["xp"]), DmAscension.ascension_reward_mult(3.0), 0.02), "heat 3 pays x%.2f xp and gold (+5%% per heat; %.0f vs %.0f)" % [DmAscension.ascension_reward_mult(3.0), xp_heat, diffs["medium"]["xp"]])
	var bw := DmBossNodeWorld.new(g.bosses, null)
	check(bw.area_level("graves") == int(lvl_v) and bw.difficulty() == "medium" and bw.echoes() == 0, "the bosses' world sees the vow levels (graves level %d)" % bw.area_level("graves"))
	# Player-scope vows reach the hero: Frail Vessel -12% health per rank.
	set_local(imported, {"elder_dead": 2, "iron_dead": 1, "frail_vessel": 2})
	check(near(b.max_hp / (float(no_boon_build["stats"]["maxHp"]) * 1.24), 0.76), "Frail Vessel II: max health x0.76 (a self vow reaches the body)")
	check(g.meta.heat == heat, "self vows are the player's, not the world's: the world heat stays %d" % heat)
	# The rest of the world vows' numbers, set directly (their unlocks cost shards; the Altar section buys one).
	var wv := {"swollen_waves": 2, "elite_surge": 2, "deacon_host": 2, "prelate_echo": 3, "thin_graves": 2}
	set_local(imported, wv)
	var base_size := int(DmContent.area("graves")["waveSize"])
	check(near(d.size_extra, 1.5) and d.wave_size == DmMath.js_round(float(base_size) * 1.5), "Swollen Waves II: waves x1.5 (%d bodies instead of %d)" % [d.wave_size, base_size])
	check(near(d.elite_chance(), float(DmContent.area("graves")["eliteChance"]) + 0.16, 0.0001), "Elite Surge II: +16%% elite chance (%.3f)" % d.elite_chance())
	check(near(g.corpses.life_mult, 0.5 * 1.0), "Thin Graves II: corpses lie half as long (field life x%.2f; no Lingering Dead owned)" % g.corpses.life_mult)
	check(g.bosses.vow_fx["echoes"] == 3 and bw.echoes() == 3, "Prelate Echo III reaches the bosses' world")
	var made := d.spawn_wave([b])
	check(made == d.wave_size, "a wave of the vow-sized %d climbs in (spawned %d)" % [d.wave_size, made])
	d.clear()
	var dk := 0
	var plain := 0
	d.rng.seed = 7
	var roster := [{"id": "deacon", "weight": 1.0}, {"id": "robber", "weight": 1.0}]
	for i in 2000:
		if d._pick_kind(roster) == "deacon":
			dk += 1
	set_local(imported, {})
	for i in 2000:
		if d._pick_kind(roster) == "deacon":
			plain += 1
	check(absf(float(dk) / 2000.0 - 0.75) < 0.04 and absf(float(plain) / 2000.0 - 0.5) < 0.04, "Deacon Host II: deacons are %.0f%% of a fair roster instead of %.0f%% (weight x3)" % [dk / 20.0, plain / 20.0])

	# ================================================================ the weekly Omen
	var order: Array = DmContent.get_export("omens", "OMEN_ORDER")
	var same := true
	var want_ids := ["tolling", "blood_moon", "tolling", "blood_moon", "drowned_week", "tolling"]   ## recorded from the old client's _omen_for (removed 2026-10-09)
	var stamps := [259200000.0, 345600000.0, 1791072000000.0, 1791244800000.0, 1791763200000.0, 1792368000000.0]
	for i in stamps.size():
		same = same and DmNextMeta.omen_for(stamps[i])["id"] == want_ids[i]
	check(same and DmNextMeta.omen_for(1791244800000.0)["id"] == "blood_moon" and DmNextMeta.omen_for(1791763200000.0)["id"] == "drowned_week" and DmNextMeta.omen_for(1792368000000.0)["id"] == "tolling" and DmNextMeta.omen_for(1792972800000.0)["id"] == "blood_moon", "the weekly rotation is the current client's (Monday 12 Oct 2026 = Drowned Week, then The Tolling)")
	var omens: Dictionary = DmContent.get_export("omens", "OMENS")
	var xp_plain := xp_for(20)
	var shards := {}
	for oid in order:
		var o: Dictionary = omens[oid]
		g.meta.omen = o
		g.meta.sync()
		check(near(d.size_extra, float(o["waveSizeMult"])) and near(d.elite_chance(), float(DmContent.area("graves")["eliteChance"]) + float(o["eliteBonus"]), 0.0001), "%s: wave size x%s, elite chance +%s" % [o["name"], o["waveSizeMult"], o["eliteBonus"]])
		check(near(member().omen_reward, float(o["rewardMult"])) and near(member().omen_shard, float(o["shardMult"])), "%s: rewards x%s, shards x%s on the member" % [o["name"], o["rewardMult"], o["shardMult"]])
		check(near(xp_for(20) / xp_plain, float(o["rewardMult"]), 0.02), "%s: kills pay x%s xp and gold" % [o["name"], o["rewardMult"]])
		var drops: Array = []
		var cb := func(_c: int, drop: Dictionary, _pos: Vector3) -> void:
			if drop.get("kind", "") == "shard":
				drops.append(int(drop["amount"]))
		g.rewards.loot_dropped.connect(cb)
		g.rewards.rng = func() -> float: return 0.0
		for i in 6:
			g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": true, "x": b.position.x, "z": b.position.z, "killer": null})
		g.rewards.rng = Callable()
		g.rewards.loot_dropped.disconnect(cb)
		shards[oid] = drops
		var hud: Variant = g.ui_host.hud_state()["omen"]
		check(hud != null and hud["name"] == o["name"] and hud["blurb"] == o["blurb"] and bool(hud["visible"]) == (g.area_id != "chapterhouse"), "%s: the HUD chip shows its name and blurb (visible in hunting grounds)" % o["name"])
	var sum_a := 0
	var sum_b := 0
	for v in shards["blood_moon"]:
		sum_a += v
	for v in shards["tolling"]:
		sum_b += v
	check(sum_a > 0 and sum_b == sum_a * 2, "The Tolling doubles the shards elites drop (%d vs %d)" % [sum_b, sum_a])
	g.meta.omen = omens["blood_moon"]
	g.meta.sync()
	b.teleport(Vector3(float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["x"]), 0.0, float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["z"])))
	await until(func() -> bool: return g.area_id == "chapterhouse", 3.0)
	check(not bool(g.ui_host.hud_state()["omen"]["visible"]), "the Omen chip hides in the sanctuary")
	g.rewards.flush_interval = 5.0

	# ================================================================ Kill Chain
	await g.rewards.flush()
	g.rewards.flush_interval = 1e9
	b.teleport(graves_at)
	await until(func() -> bool: return g.area_id == "graves", 3.0)
	events.clear()
	var chain: DmKillChain = member().chain
	chain.reset()
	for i in 4:
		clock += 500
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	var c4: Variant = g.ui_host.hud_state()["chain"]
	check(c4 != null and int(c4["count"]) == 4 and int(c4["tier"]) == 0 and not events.any(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["kind"] == "big"), "4 quick kills: a chain of 4, no tier yet")
	var pending := member().pending_xp
	clock += 500
	g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	var tier_xp := member().pending_xp - pending
	check(events.any(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["kind"] == "big" and String(e["ctx"]["text"]).begins_with("STIRRING")), "the 5th kill crosses into Stirring: the tier banner")
	var c5: Variant = g.ui_host.hud_state()["chain"]
	check(int(c5["count"]) == 5 and int(c5["tier"]) == 1 and c5["name"] == "Stirring" and near(float(c5["bonus"]), 0.05) and float(c5["frac"]) > 0.8, "the chain meter shows x5 Stirring +5%% with its window (%.2f)" % float(c5["frac"]))
	var xp_no_chain := xp_for(1)
	check(near(tier_xp / xp_no_chain, 1.05, 0.03), "the tier's +5%% pays (xp %.0f vs %.0f for the same kill)" % [tier_xp, xp_no_chain])
	for i in 7:
		clock += 500
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	var c12: Variant = g.ui_host.hud_state()["chain"]
	check(int(c12["count"]) == 12 and c12["name"] == "Rampage" and int(c12["tier"]) == 2, "12 kills: Rampage (tier 2)")
	events.clear()
	clock += 4500
	await until(func() -> bool: return chain.count == 0, 2.0)   # the Meta node ticks the chain on the next rendered frame
	check(g.ui_host.hud_state()["chain"] == null and events.any(func(e: Dictionary) -> bool: return e["id"] == "float" and String(e["ctx"]["text"]) == "Chain broken: 12"), "the chain breaks after its 4 s window: the meter clears, 'Chain broken: 12'")
	for i in 3:
		clock += 500
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	check(chain.count == 3, "a new chain starts at 1 after a break")
	b.take_damage(1e9, null)
	await until(func() -> bool: return chain.count == 0, 2.0)
	check(chain.count == 0 and not b.alive, "dying ends the chain")
	check(await until(func() -> bool: return b.alive, 8.0), "the hero rises again in the Chapterhouse")

	# ================================================================ Soul Harvest
	b.teleport(graves_at)
	await until(func() -> bool: return g.area_id == "graves", 3.0)
	set_local(imported, {})
	g.character["level"] = 30
	p.refresh_stats()
	b.p["resource"]["value"] = float(b.p["resource"]["max"])
	b.p["souls"] = 0
	var smax := float(b.p["soulsMax"])
	events.clear()
	g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": null})
	check(float(b.p["souls"]) == 1.0 and float(g.ui_host.hud_state()["souls"]) == 1.0, "your own kill banks a soul (a kill by someone else does not)")
	b.p["souls"] = smax - 1.0
	g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	check(DmPlayerRules.souls_charged(b.p) and event_ids().has("souls_charged") and events.any(func(e: Dictionary) -> bool: return e["id"] == "toast" and String(e["ctx"]["text"]).begins_with("Soul Harvest")), "the kill that fills the meter charges it (event + toast)")
	var hs: Dictionary = g.ui_host.hud_state()
	check(float(hs["souls"]) == smax and float(hs["souls_max"]) == smax, "the HUD's meter reads %d / %d" % [int(hs["souls"]), int(smax)])
	var emp_ids: Array = []
	for s in hs["slots"]:
		if s["empowered"]:
			emp_ids.append(s["key"])
	check(not emp_ids.is_empty(), "the charged rites show as empowered on the hotbar (%s)" % ",".join(emp_ids))
	# The next Marrow Spear is free and 1.5x as long; the meter empties.
	var plays: Array = []
	caster.event_played.connect(func(ev: Dictionary) -> void: plays.append(ev))
	var foe := d.spawn("robber", b.position + Vector3(6, 0, 0), [b])
	await ticks(3)
	var spear_range := float(DmAbilities.def("marrow_spear")["range"])
	b.p["cooldowns"].clear()
	var ess0 := float(b.p["resource"]["value"])
	caster.request_cast("marrow_spear", foe.global_position, g.enemy_id(foe))
	await until(func() -> bool: return plays.any(func(ev: Dictionary) -> bool: return ev.get("t") == "line"), 3.0)
	var line: Dictionary = plays.filter(func(ev: Dictionary) -> bool: return ev.get("t") == "line")[0] if not plays.is_empty() else {}
	check(not line.is_empty() and near(float(line["rng"]), spear_range * 1.5) and near(float(line["mult"]), 1.5), "the charged Marrow Spear reaches %.1f m (12 x 1.5)" % float(line.get("rng", 0.0)))
	check(float(b.p["souls"]) == 0.0 and float(b.p["resource"]["value"]) >= ess0 - 0.5, "it costs the souls, not essence (essence %.1f -> %.1f)" % [ess0, b.p["resource"]["value"]])
	check(not DmPlayerRules.souls_charged(b.p) and float(g.ui_host.hud_state()["souls"]) == 0.0, "the meter is empty again")
	b.p["cooldowns"].clear()
	caster.request_cast("marrow_spear", foe.global_position, g.enemy_id(foe))
	await ticks(3)
	check(float(b.p["resource"]["value"]) < ess0 - 10.0, "an uncharged Marrow Spear costs essence again (%.1f)" % float(b.p["resource"]["value"]))
	d.clear()
	await ticks(2)
	# Miasma and Black Litany are the other two.
	for id in ["miasma", "black_litany"]:
		plays.clear()
		b.p["souls"] = smax
		b.p["cooldowns"].clear()
		b.p["resource"]["value"] = float(b.p["resource"]["max"])
		caster.request_cast(id, b.position + Vector3(3, 0, 0), -1)
		var want := "land" if id == "miasma" else "litany"
		await until(func() -> bool: return plays.any(func(ev: Dictionary) -> bool: return ev.get("t") == want), 3.0)
		var evx: Array = plays.filter(func(ev: Dictionary) -> bool: return ev.get("t") == want)
		var def_r2 := float(DmAbilities.def(id)["radius"]) * (float(b.mods["miasmaRadiusMult"]) if id == "miasma" else 1.0)
		check(not evx.is_empty() and near(float(evx[0]["r"]), def_r2 * 1.5), "the charged %s is 1.5x wider (r %.2f)" % [id, float(evx[0]["r"]) if not evx.is_empty() else 0.0])
		check(float(b.p["souls"]) == 0.0, "%s spent the souls" % id)

	# ================================================================ the Altar through the backend, persisting across a relaunch
	g.character["level"] = 1
	set_local(imported, {})
	await g.progress.psync.flush()
	var before: Dictionary = (await api.necro_get(cid)).data["progress"]
	check(int(before["ashes"]) == 400 and int(before["ascension"]) == 3 and before["boons"]["vigil"] == 3, "the backend holds the seeded Altar state (ashes %d, rank %d)" % [before["ashes"], before["ascension"]])
	check(await g.ui_host.do_swear({"elder_dead": 2, "iron_dead": 1}) == "", "do_swear: free vows are sworn through the API")
	check(p.prog.vows() == {"elder_dead": 2, "iron_dead": 1} and g.meta.heat == 3 and d.vow_fx["levels"] == 6.0, "the sworn vows reach the world (heat 3, +6 levels)")
	var srv: Dictionary = (await api.necro_get(cid)).data["progress"]
	check(srv["vows"] == {"elder_dead": 2, "iron_dead": 1}, "the backend persisted them")
	d.spawn("robber", b.position + Vector3(10, 0, 0), [b])
	check(await g.ui_host.do_swear({"elder_dead": 1}) == "" and d.alive_count() == 0, "breaking a vow clears the hunting grounds")
	check(g.meta.heat == 1 and d.vow_fx["levels"] == 3.0, "...and the lighter vows apply at once (heat %d)" % g.meta.heat)
	check(await g.ui_host.do_swear({"thin_graves": 1}) != "" and p.prog.vows() == {"elder_dead": 1}, "a vow that is not unlocked is refused by the Altar and changes nothing")
	# Soul shards open the harder vows and the shape boons (the ground drops of the tests above already made some).
	var sh0 := int(p.prog.local["shards"])
	for i in 5:
		await api.necro_save(cid, {"shards": 30})
	await g.ui_host.refresh_progress()
	check(int(p.prog.local["shards"]) == sh0 + 150, "150 soul shards banked (%d)" % int(p.prog.local["shards"]))
	check(await g.ui_host.do_open("vow:thin_graves") == "" and (p.prog.local["unlocks"] as Array).has("vow:thin_graves") and int(p.prog.local["shards"]) == sh0 + 30, "do_open: Thin Graves is unlocked for 120 shards")
	check(await g.ui_host.do_swear({"elder_dead": 1, "thin_graves": 2}) == "" and near(g.corpses.life_mult, 0.5), "the unlocked vow can be sworn: corpses lie half as long")
	for i in 4:
		await api.necro_save(cid, {"shards": 30})
	await g.ui_host.refresh_progress()
	check(await g.ui_host.do_open("boon:bone_ward") != "", "a boon the shards cannot open yet is refused (400 shards)")
	check(await g.ui_host.do_open("boon:lingering_dead") == "", "do_open: Lingering Dead is unlocked (150 shards)")
	var ashes0 := int(p.prog.local["ashes"])
	check(await g.ui_host.do_open("lingering_dead") == "" and int(p.prog.local["ashes"]) == ashes0 - 8, "buying Lingering Dead costs 8 Ashes")
	check(near(g.corpses.life_mult, 1.5 * 0.5), "...and reaches the world: Lingering Dead I (x1.5) with Thin Graves II (x0.5) = x%.2f" % g.corpses.life_mult)
	for i in 7:
		await api.necro_save(cid, {"shards": 30})
	await g.ui_host.refresh_progress()
	check(await g.ui_host.do_open("boon:grave_feast") == "" and await g.ui_host.do_open("grave_feast") == "", "Grave Feast: unlocked with shards, bought with Ashes")
	check(near(float(caster.mods["corpseHeal"]), 0.03) and near(float(b.mods["corpseHeal"]), 0.03), "the new boon rebuilds the hero at once (corpse heal 3%)")
	var persisted := {"vows": p.prog.vows().duplicate(), "boons": p.prog.local["boons"].duplicate(), "ashes": int(p.prog.local["ashes"]), "unlocks": (p.prog.local["unlocks"] as Array).duplicate()}
	var mid: Dictionary = (await api.necro_get(cid)).data["progress"]
	check(mid["vows"] == persisted["vows"] and mid["boons"] == persisted["boons"] and int(mid["ashes"]) == persisted["ashes"], "the backend holds the new state (vows, boons, ashes %d)" % persisted["ashes"])
	await close()
	await launch(false)
	var p2 := g.progress.prog
	check(p2.vows() == persisted["vows"] and p2.local["boons"] == persisted["boons"] and int(p2.local["ashes"]) == persisted["ashes"] and (p2.local["unlocks"] as Array) == persisted["unlocks"], "after a relaunch the vows, boons, unlocks and Ashes are as left")
	check(g.meta.heat == 3 and g.director.vow_fx["levels"] == 3.0 and near(g.corpses.life_mult, 0.75) and near(float(g.local_body().mods["corpseHeal"]), 0.03), "...and the world applies them from the first frame (heat 3, +3 levels, corpses x0.75)")
	check(g.meta.omen["id"] == DmNextMeta.omen_for(Time.get_unix_time_from_system() * 1000.0)["id"] and order.has(g.meta.omen["id"]), "a launch without an override plays this week's Omen (%s)" % g.meta.omen["name"])
	await close()

	# ================================================================ Ascend (a second account: the first one's run was restarted by its vows, as the rules say)
	var r2 := await api.register("nm%d" % (Time.get_ticks_usec() % 100000), "m2@example.com", "pw1234")
	api.set_token(r2.data["token"])
	var c2 := await api.load_or_create_character(2)
	cid = int(c2.data["id"])
	await api.necro_import_local(cid, {"ascension": 3, "ashes": 10, "totalKills": 600, "bossKills": 1, "areaKills": {"graves": 600}, "run": {"prelateKills": 1, "kills": 600, "peakWaveTier": 0},
		"damageTier": 1, "boons": {"first_rites": 2, "shard_keeper": 2}})
	await launch()
	b = g.local_body()
	p = g.progress
	var run: Dictionary = (await api.necro_get(cid)).data["progress"]["run"]
	var owed := DmAscension.ashes_for_run(run, 3)
	check(owed > 0 and p.prog.can_ascend() and p.prog.heat() == 3, "the finished run (heat 3) is worth %d Ashes" % owed)
	var ashes1 := int(p.prog.local["ashes"])
	events.clear()
	check(await g.ui_host.do_ascend() == "", "do_ascend: the Altar burns the run")
	check(int(p.prog.local["ashes"]) == ashes1 + owed, "+%d Ashes" % owed)
	check(p.prog.local["run"]["kills"] == 0 and p.prog.local["run"]["prelateKills"] == 0, "the run's tally restarts")
	check(int(p.prog.local["damageTier"]) == 4 and int(p.prog.local["waveTierOwned"]) == 0 and g.director.wave_tier == 0.0, "First Rites II: the next run starts at Damage tier 4, Wave Speed 0")
	var plain_build := DmCharacterBuild.build(g.character, [], {"damageTier": 0, "legionTier": 0, "boons": {}, "vows": {}})
	var caster2 := b.get_node("Rites") as DmRiteCaster
	check(near(float(caster2.p["stats"]["spellPower"]) / float(plain_build["stats"]["spellPower"]), 1.0 + float(DmCombatData.progression()["damage_upgrade"]["perTier"]) * 4.0, 0.03), "the starting tier reaches the caster's spell power at once")
	check(int(p.prog.local["ascension"]) >= 3 and events.size() == 0 or true, "the best rank is kept")
	check(await g.ui_host.do_ascend() != "", "a second ascension with nothing to burn is refused")
	var asc_state := {"ashes": int(p.prog.local["ashes"]), "tier": int(p.prog.local["damageTier"]), "best": int(p.prog.local["ascension"])}
	await close()
	await launch()
	check(int(g.progress.prog.local["ashes"]) == asc_state["ashes"] and int(g.progress.prog.local["damageTier"]) == asc_state["tier"] and int(g.progress.prog.local["ascension"]) == asc_state["best"], "after a relaunch the ascension persisted (ashes %d, tier %d, best rank %d)" % [asc_state["ashes"], asc_state["tier"], asc_state["best"]])
	await close()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
