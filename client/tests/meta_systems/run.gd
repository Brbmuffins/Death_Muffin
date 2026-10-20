extends SceneTree
## The meta systems of the rebuilt client (client/next/meta): difficulty, the weekly Omen, the Kill Chain, Soul Harvest and the Reaper's soul bag, on the OFFLINE backend.
## The Altar of Ascension, vows and boons of the old suite are not in the client (DECISIONS B36: saved vows and boons do nothing, tests/value.gd holds that).
## godot --headless --fixed-fps 60 --path client --script res://tests/meta_systems/run.gd

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
	# a relaunch loads the character as the game does (GET /character); a card pick (load_or_create) would switch its discipline
	var c := await api.get_character()
	if not c.ok:
		c = await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	events.clear()
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": true, "store": store, "omen": NEUTRAL if neutral else null})
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


## A fresh robber of the director (a body of the core), its numbers read and the body removed.
func spawn_stats() -> Dictionary:
	var b := g.local_body()
	var id: int = g.director.spawn("robber", b.position + Vector3(40, 0, 0), [b])
	var info: Dictionary = g.core_host.enemy_info(id)
	var out := {"hp": float(info["max_hp"]), "dmg": float(info["damage"]), "level": float(info["level"])}
	g.core_host.remove_enemy(id)
	await ticks(2)
	return out


## The shard amounts six elite kills drop under the Omen in force. The kills roll from the drop roll pinned low, not from the drop tape (its seeds differ from
## one event to the next), so every call rolls the same six drops and the amounts differ only by the Omen.
func elite_shards() -> Array:
	var b := g.local_body()
	var tape := member().tape
	member().tape = null
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
	member().tape = tape
	return drops


func event_ids() -> Array:
	return events.map(func(e: Dictionary) -> String: return String(e["id"]))


func _run() -> void:
	Engine.time_scale = 4.0
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("nm%d" % (Time.get_ticks_usec() % 100000), "m@example.com", "pw1234")
	api.set_token(r.data["token"])
	var ch0 := await api.load_or_create_character(2)
	var cid := int(ch0.data["id"])
	await launch()
	var b := g.local_body()
	var p := g.progress
	var d := g.director
	var caster := b.get_node("Rites") as DmRiteCaster
	check(g.meta != null and g.meta.member == member() and g.ui_host != null, "the Meta node exists on the host with the real HUD")
	var gr: Dictionary = DmContent.area("graves")["rect"]
	var graves_at := Vector3((float(gr["x0"]) + float(gr["x1"])) * 0.5, 0.0, (float(gr["z0"]) + float(gr["z1"])) * 0.5)

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


	# ================================================================ the weekly Omen
	var order: Array = DmContent.get_export("omens", "OMEN_ORDER")
	# The rotation: a week starts on a Monday (UTC) and the Omens step through OMEN_ORDER one per week, wrapping, before and after any date.
	var week_ms := 7.0 * 24.0 * 3600.0 * 1000.0
	var monday := 1791763200000.0   # Monday 12 Oct 2026, 00:00 UTC
	var start_ix := order.find(String(DmNextMeta.omen_for(monday)["id"]))
	var rotation := start_ix >= 0
	for k in range(-order.size(), order.size() * 2 + 1):
		var week_start := monday + float(k) * week_ms
		var want_id := String(order[posmod(start_ix + k, order.size())]) if start_ix >= 0 else ""
		rotation = rotation and DmNextMeta.omen_for(week_start)["id"] == want_id and DmNextMeta.omen_for(week_start + week_ms - 1.0)["id"] == want_id
	check(rotation, "the weekly rotation: one Omen per Monday-to-Sunday week, in the order of OMEN_ORDER (%d weeks either side)" % order.size())
	var omens: Dictionary = DmContent.get_export("omens", "OMENS")
	var xp_plain := xp_for(20)
	var base_shards := elite_shards()   # under the neutral week: the shards six elite kills drop with no Omen
	var shards := {}
	for oid in order:
		var o: Dictionary = omens[oid]
		g.meta.omen = o
		g.meta.sync()
		check(near(d.size_extra, float(o["waveSizeMult"])) and near(d.elite_chance(), float(DmContent.area("graves")["eliteChance"]) + float(o["eliteBonus"]), 0.0001), "%s: wave size x%s, elite chance +%s" % [o["name"], o["waveSizeMult"], o["eliteBonus"]])
		check(near(member().omen_reward, float(o["rewardMult"])) and near(member().omen_shard, float(o["shardMult"])), "%s: rewards x%s, shards x%s on the member" % [o["name"], o["rewardMult"], o["shardMult"]])
		check(near(xp_for(20) / xp_plain, float(o["rewardMult"]), 0.02), "%s: kills pay x%s xp and gold" % [o["name"], o["rewardMult"]])
		shards[oid] = elite_shards()
		var shards_ok: bool = shards[oid].size() == base_shards.size()
		for i in mini(shards[oid].size(), base_shards.size()):
			var scaled := float(base_shards[i]) * float(o["shardMult"])   # (each drop rounds up to a whole shard)
			shards_ok = shards_ok and float(shards[oid][i]) >= scaled - 0.0001 and float(shards[oid][i]) < scaled + 1.0
		check(shards_ok, "%s: the shards elites drop are x%s of the plain week's (%s vs %s)" % [o["name"], o["shardMult"], shards[oid], base_shards])
		var hud: Variant = g.ui_host.hud_state()["omen"]
		check(hud != null and hud["name"] == o["name"] and hud["blurb"] == o["blurb"] and bool(hud["visible"]) == (g.area_id != "chapterhouse"), "%s: the HUD chip shows its name and blurb (visible in hunting grounds)" % o["name"])
	var base_sum := 0
	for v in base_shards:
		base_sum += v
	check(base_sum > 0, "elite kills drop shards in a plain week (%d)" % base_sum)
	g.meta.omen = NEUTRAL
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
	var cdata: Dictionary = DmProgContent.get_data()["chain"]
	var tiers: Array = cdata["tiers"]
	var window_ms := int(cdata["windowMs"])
	var gap_ms := window_ms / 8   # kills this far apart keep one chain going
	var first_at := int(tiers[0]["at"])
	var second_at := int(tiers[1]["at"])
	chain.reset()
	for i in first_at - 1:
		clock += gap_ms
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	var c4: Variant = g.ui_host.hud_state()["chain"]
	check(c4 != null and int(c4["count"]) == first_at - 1 and int(c4["tier"]) == 0 and not events.any(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["kind"] == "big"), "%d quick kills: a chain of %d, no tier yet" % [first_at - 1, first_at - 1])
	var pending := member().pending_xp
	clock += gap_ms
	g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	var tier_xp := member().pending_xp - pending
	check(events.any(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["kind"] == "big" and String(e["ctx"]["text"]).begins_with(String(tiers[0]["name"]).to_upper())), "kill %d crosses into %s: the tier banner" % [first_at, tiers[0]["name"]])
	var c5: Variant = g.ui_host.hud_state()["chain"]
	check(int(c5["count"]) == first_at and int(c5["tier"]) == 1 and c5["name"] == tiers[0]["name"] and near(float(c5["bonus"]), float(tiers[0]["bonus"])) and float(c5["frac"]) > 0.8, "the chain meter shows x%d %s +%d%% with its window (%.2f)" % [first_at, tiers[0]["name"], roundi(float(tiers[0]["bonus"]) * 100.0), float(c5["frac"])])
	var xp_no_chain := xp_for(1)
	check(near(tier_xp / xp_no_chain, 1.0 + float(tiers[0]["bonus"]), 0.03), "the tier's +%d%% pays (xp %.0f vs %.0f for the same kill)" % [roundi(float(tiers[0]["bonus"]) * 100.0), tier_xp, xp_no_chain])
	# the chain runs on to the second tier and past the length the break is reported from
	var long_chain := maxi(second_at, int(cdata["reportAt"]))
	for i in second_at - first_at:
		clock += gap_ms
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	var c12: Variant = g.ui_host.hud_state()["chain"]
	check(int(c12["count"]) == second_at and c12["name"] == tiers[1]["name"] and int(c12["tier"]) == 2, "%d kills: %s (tier 2)" % [second_at, tiers[1]["name"]])
	for i in long_chain - second_at:
		clock += gap_ms
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	events.clear()
	clock += window_ms + gap_ms
	await until(func() -> bool: return chain.count == 0, 2.0)   # the Meta node ticks the chain on the next rendered frame
	check(g.ui_host.hud_state()["chain"] == null and events.any(func(e: Dictionary) -> bool: return e["id"] == "float" and String(e["ctx"]["text"]) == "Chain broken: %d" % long_chain), "the chain breaks after its %.0f s window: the meter clears, 'Chain broken: %d'" % [window_ms / 1000.0, long_chain])
	for i in 3:
		clock += gap_ms
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 60.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	check(chain.count == 3, "a new chain starts at 1 after a break")
	b.take_damage(1e9, null)
	await until(func() -> bool: return chain.count == 0, 2.0)
	check(chain.count == 0 and not b.alive, "dying ends the chain")
	check(await until(func() -> bool: return b.alive, 8.0), "the hero rises again in the Chapterhouse")


	# ================================================================ Soul Harvest
	b.teleport(graves_at)
	await until(func() -> bool: return g.area_id == "graves", 3.0)
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
	# The next Marrow Spear is free and its Soul Harvest times as long; the meter empties.
	var area_mult := float(DmCombatData.const_table("SOUL_HARVEST")["areaMult"])
	var plays: Array = []
	caster.event_played.connect(func(ev: Dictionary) -> void: plays.append(ev))
	var foe: int = d.spawn("robber", b.position + Vector3(6, 0, 0), [b])   # a body of the core: an id
	await ticks(3)
	var spear_range := float(DmAbilities.def("marrow_spear")["range"])
	b.p["cooldowns"].clear()
	var ess0 := float(b.p["resource"]["value"])
	caster.request_cast("marrow_spear", g.core_host.enemy_position(foe), foe)
	await until(func() -> bool: return plays.any(func(ev: Dictionary) -> bool: return ev.get("t") == "line"), 3.0)
	var line: Dictionary = plays.filter(func(ev: Dictionary) -> bool: return ev.get("t") == "line")[0] if not plays.is_empty() else {}
	check(not line.is_empty() and near(float(line["rng"]), spear_range * area_mult) and near(float(line["mult"]), area_mult), "the charged Marrow Spear reaches %.1f m (%.1f x %.2f)" % [float(line.get("rng", 0.0)), spear_range, area_mult])
	check(float(b.p["souls"]) == 0.0 and float(b.p["resource"]["value"]) >= ess0 - 0.5, "it costs the souls, not essence (essence %.1f -> %.1f)" % [ess0, b.p["resource"]["value"]])
	check(not DmPlayerRules.souls_charged(b.p) and float(g.ui_host.hud_state()["souls"]) == 0.0, "the meter is empty again")
	b.p["cooldowns"].clear()
	caster.request_cast("marrow_spear", g.core_host.enemy_position(foe), foe)
	await ticks(3)
	check(float(b.p["resource"]["value"]) < ess0 - float(DmAbilities.def("marrow_spear")["essenceCost"]) * 0.5, "an uncharged Marrow Spear costs essence again (%.1f)" % float(b.p["resource"]["value"]))
	g.core_host.remove_enemy(foe)
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
		check(not evx.is_empty() and near(float(evx[0]["r"]), def_r2 * area_mult), "the charged %s is %.2fx wider (r %.2f)" % [id, area_mult, float(evx[0]["r"]) if not evx.is_empty() else 0.0])
		check(float(b.p["souls"]) == 0.0, "%s spent the souls" % id)


	# ================================================================ The Reaper (class 11): her own kills fill the soul bag, never Soul Harvest
	var rc := await api.change_discipline(cid, 11)
	check(rc.ok, "the backend takes the Reaper (%s)" % rc.error)
	await launch()
	b = g.local_body()
	var bag_max := int(DmCombatData.const_table("REAPER")["soulBagMax"])
	check(b.family == "reaper" and float(b.p["soulsMax"]) == float(bag_max) and b.p["resource"]["kind"] == "reaper", "a Reaper character plays the reaper family with a %d-soul bag" % bag_max)
	b.teleport(graves_at)
	await ticks(2)
	b.p["souls"] = 0
	events.clear()
	g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": null})
	for _i in 900:   # a soul is banked when its wisp reaches her (it loops round the corpse first)
		if int(b.p["souls"]) >= 2:
			break
		await g.get_tree().process_frame
	var rhs: Dictionary = g.ui_host.hud_state()
	check(int(b.p["souls"]) == 2 and int(rhs["souls"]) == 2 and bool(rhs["soul_bag"]) and int(rhs["souls_max"]) == bag_max, "every enemy that dies near her banks one soul, whoever struck it, and the HUD reads the bag 2 / %d" % bag_max)
	check(String(rhs["resource_label"]) == DmResources.label_for("reaper") and String(rhs["resource_color"]) == DmResources.color_for("reaper"), "the HUD names her resource and colours it as the Reaper's")
	check(float(rhs["essence"]) == 2.0 and float(rhs["max_essence"]) == float(bag_max), "the energy orb reads the bag (2 / %d)" % bag_max)
	var rslots: Array = rhs["slots"]
	var second_rite := String(DmContent.kit("reaper")["defaultLoadout"][1])
	var second_cost := int(DmAbilities.def(second_rite)["soulCost"])
	check(int(rslots[1]["cost"]) == second_cost and bool(rslots[1]["affordable"]) == (int(b.p["souls"]) >= second_cost), "a slot's cost is in souls (%s %d) and dims below it" % [second_rite, second_cost])
	b.p["souls"] = bag_max - 1
	for i in 3:
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": 5.0, "elite": false, "x": b.position.x, "z": b.position.z, "killer": b})
	for _i in 900:
		if int(b.p["souls"]) >= 30:
			break
		await g.get_tree().process_frame
	check(int(b.p["souls"]) == bag_max and not event_ids().has("souls_charged"), "the bag holds %d and a full bag never charges Soul Harvest" % bag_max)
	await close()
	print("%d passed, %d failed" % [passed, failed])
	print("%s meta_systems %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)
