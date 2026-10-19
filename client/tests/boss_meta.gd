extends "res://tests/boss_base.gd"
## The Covenant Seal's Empowered call and the first-kill trophies on the combat core (DmBossMeta, the HUD's boss-key prompt; archive/old-game:godot/tests/next_boss_meta/run.gd on today's game), on the local mock
## backend (its `/api/boss-key/*` routes): nothing here talks to a real server.
##   - the first-kill trophy: the King's first kill pays the first-kill bonus once and is the Chronicle's `boss.gravedigger` (the backend has it after a flush), a second kill is no first kill and
##     the counter says 2; the Abbess's trophy likewise (+2 shards, her own area's drop);
##   - the altar's choice: with a Covenant Seal in the bag a boss that can be Empowered offers it (`boss_key_offer`: the HUD's prompt opens, its two buttons answer for the host), a Seal-less
##     hero and the Prelate (not in DmGoldSink.EMPOWERABLE) are woken with shards at once;
##   - the Empowered call: the backend takes exactly the price in gold and one Seal, a boss the hero could not wake is refused before anything is spent, the awake boss is Empowered (+6 levels +15 %,
##     hp x1.4, the red-gold glow flag), a second call while it is awake is refused (busy) and spends nothing, the kill's report carries the backend's summon id, the Seal's prize is claimed
##     from the backend after the report (the mock wants the fight to have lasted 10 s) and dropped at the corpse;
##   - a lost Empowered fight stays bound on the backend: the next call is free (no gold), and the altar offers the choice again ("your summon is bound: free").
## Run: godot --headless --path client --script res://tests/boss_meta.gd [--fixed-fps 60 before --path runs it faster than real time]

const BOSS := "gravedigger"

var clock: Array = [0]
var report_bosses: Array = []        ## every boss entry of every session report the backend received
var cid := 0


func _config() -> void:
	boss_id = BOSS
	load_areas = ["graves", "ossuary"]
	bakes = ["thrall_legionnaire", "grave_robber", "bone_hound"]
	start_opts = {"hud": true, "persist": false}
	mock_clock = clock


func before_start() -> void:
	cid = int(character["id"])
	await api.save_inventory(cid, [{"slot_index": 0, "item_id": DmGoldSink.COVENANT_SEAL, "quantity": 2}])
	api.transport = func(req: Dictionary) -> Dictionary:   # a window on what the host reports
		if String(req["url"]).contains("/report"):
			var body: Variant = JSON.parse_string(String(req.get("body", "")))
			if body is Dictionary:
				for e in body.get("members", body.get("entries", [])):
					report_bosses.append_array(e.get("bosses", []))
		return mock.transport(req)


func set_gold(n: int) -> void:
	var p: DmProgression = g.progress.prog
	p.gold_unsent += n - int(p.character.get("gold", 0))
	p.character["gold"] = n


func bag_count(item_id: String) -> int:
	var n := 0
	for r in (await api.get_inventory(cid)).data:
		if String(r.get("item_id", "")) == item_id:
			n += int(r.get("quantity", 1))
	return n


func backend_chronicle() -> Dictionary:
	return (await api.get_chronicle(cid)).data["life"]


func slay() -> void:
	boss.take_damage(boss.max_hp * 2.0, hb)
	await ticks(2)


func run_suite() -> void:
	await t_trophies()
	await t_altar()
	await t_empowered()
	await t_bound()


func t_trophies() -> void:
	clear_logs()
	check(wake() == "", "the King is woken")
	check(not g.chron.has_trophy(BOSS), "no trophy yet")
	await slay()
	check(earned == [[BOSS, true]], "the first kill pays the first-kill bonus (%s)" % str(earned))
	check(g.chron.has_trophy(BOSS) and g.chron.life("boss." + BOSS) == 1.0, "the trophy is the chronicle's boss.gravedigger counter")
	await g.chron.flush()
	check(float((await backend_chronicle()).get("boss." + BOSS, 0)) == 1.0, "and it reached the backend")
	await dismiss()
	clear_logs()
	check(wake() == "", "woken again")
	await slay()
	check(earned == [[BOSS, false]], "a second kill grants no trophy again (%s)" % str(earned))
	await g.chron.flush()
	check(float((await backend_chronicle()).get("boss." + BOSS, 0)) == 2.0, "the kill counter says 2")
	await dismiss()
	# the Abbess: her own trophy, her own shards (3), the first-kill bonus
	boss_id = "abbess"
	clear_logs()
	check(wake() == "", "the Abbess is woken at the Ossuary's Reliquary")
	check(not g.chron.has_trophy("abbess"), "(no trophy of hers yet)")
	await slay()
	check(earned == [["abbess", true]] and g.chron.has_trophy("abbess") and g.chron.life("boss.abbess") == 1.0, "her first kill pays the bonus and is hers (%s)" % str(earned))
	await dismiss()
	boss_id = BOSS


func t_altar() -> void:
	clear_logs()
	var offers: Array = []
	g.boss_meta.offered.connect(func(ctx: Dictionary) -> void: offers.append(ctx))
	hb.teleport(near_site())
	await ticks(2)
	var seals := g.boss_meta.seals()
	check(seals == 2, "the bag holds the two Covenant Seals the account was given (%d)" % seals)
	# a Seal and the soul shards: the altar offers the choice, the HUD's prompt opens with both prices
	set_shards(30)
	set_gold(DmGoldSink.empower_gold(int(def()["shards"])) + 500)
	g.bosses.request_summon(BOSS)   # E at the altar
	check(offers.size() == 1 and not bool(offers[0]["bound"]) and int(offers[0]["seals"]) == 2 and offers[0]["boss"] == BOSS and g.bosses.active_boss() == null, "the altar offers the choice instead of waking it")
	var kp: DmBossKeyPrompt = g.ui.boss_key
	check(kp.visible and kp.boss == BOSS and not kp.normal_button.disabled and not kp.emp_button.disabled, "the HUD's boss-key prompt is open with both choices open")
	check(kp.normal_button.text.contains("%d soul shards" % int(def()["shards"])) and kp.emp_button.text.contains("1 Covenant Seal"), "it names the soul shards and the Seal")
	# the shards button answers for the host: the plain summon
	kp.normal_button.pressed.emit()
	boss = g.bosses.active_boss()
	check(boss != null and not boss.empowered and int(member().prog.local["shards"]) == 30 - int(def()["shards"]), "the shards choice wakes it plain and takes its shards")
	boss.set_physics_process(false)
	await dismiss()
	# no gold: the Empowered choice is shown but closed, with why
	set_shards(30)
	set_gold(10)
	hb.teleport(near_site())
	g.bosses.request_summon(BOSS)
	check(offers.size() == 2 and kp.visible and kp.emp_button.disabled and kp.emp_button.text.contains("You need"), "short of gold the Empowered choice is closed and says what is missing (%s)" % kp.emp_button.text)
	kp.close()
	# the Prelate cannot be Empowered: the bell wakes it with shards at once, whatever is in the bag
	check(not DmGoldSink.can_empower("prelate") and DmGoldSink.can_empower(BOSS) and DmGoldSink.can_empower("abbess"), "(the Prelate is not on the Seal's list)")
	# no Seal: plain
	await api.save_inventory(cid, [])
	g.loot.inventory.replace([])
	check(g.boss_meta.seals() == 0, "(the bag is empty of Seals)")
	var n_off := offers.size()
	g.bosses.request_summon(BOSS)
	boss = g.bosses.active_boss()
	check(offers.size() == n_off and boss != null and not boss.empowered, "without a Seal the altar wakes it with shards at once, no prompt")
	boss.set_physics_process(false)
	await dismiss()
	await api.save_inventory(cid, [{"slot_index": 0, "item_id": DmGoldSink.COVENANT_SEAL, "quantity": 2}])
	g.loot.inventory.replace((await api.get_inventory(cid)).data)
	check(g.boss_meta.seals() == 2, "(the Seals are back)")


func t_empowered() -> void:
	clear_logs()
	set_shards(0)
	hb.teleport(near_site())
	check(wake(0) == "shards", "baseline: with no shards a plain summon is refused")
	var plain_level := 0.0
	var plain_hp := 0.0
	set_shards(30)
	check(wake() == "" and not boss.empowered and not bool(boss.brain.state["empowered"]), "baseline: a plain summon is not Empowered")
	plain_hp = boss.max_hp
	plain_level = float(boss.brain.state["level"])
	await dismiss()
	var cost := DmGoldSink.empower_gold(int(def()["shards"]))
	set_gold(cost + 1234)
	hb.teleport(near_site())
	set_shards(0)
	check(g.bosses.try_summon(me, BOSS) == "shards", "with no shards a plain summon is refused")
	var why: String = await g.boss_meta.call_empowered(BOSS)
	check(why == "", "call_empowered woke it (%s)" % why)
	boss = g.bosses.active_boss()
	check(boss != null and boss.empowered and bool(boss.brain.state["empowered"]) and bool(boss.bstate.empowered), "the awake boss is Empowered (its view burns red-gold)")
	boss.set_physics_process(false)
	boss.world.refresh()
	check(int(g.character["gold"]) == 1234, "the backend took exactly %d gold (left %d)" % [cost, int(g.character["gold"])])
	check(await bag_count(DmGoldSink.COVENANT_SEAL) == 1, "and one Covenant Seal (1 of 2 left)")
	var want_level := float(DmGoldSink.empowered_level(int(plain_level)))
	check(float(boss.brain.state["level"]) >= want_level - 0.5, "the level goes up %d -> %d (it is %d)" % [int(plain_level), int(want_level), int(boss.brain.state["level"])])
	check(boss.max_hp > plain_hp * float(DmGoldSink.EMPOWER["hpMult"]), "harder numbers: hp %d vs %d plain (x%.2f)" % [int(boss.max_hp), int(plain_hp), boss.max_hp / plain_hp])
	check(g.boss_meta.pending == BOSS and member().empower_summon_id != 0, "the summon is tracked (pending, backend id %d)" % member().empower_summon_id)
	var gold := int(g.character["gold"])
	var again: String = await g.boss_meta.call_empowered(BOSS)
	check(again == "busy" and int(g.character["gold"]) == gold, "a second call while it is awake is refused before anything is spent (%s)" % again)
	await g.rewards.flush()   # (the earlier kills are reported already)
	report_bosses.clear()
	var prizes: Array = []
	g.boss_meta.prize.connect(func(id: String, p: Dictionary) -> void: prizes.append([id, p]))
	clock[0] += 60000   # the backend wants the fight to have lasted a while
	put(arena() + Vector3(3.0, 0.0, 0.0))
	await slay()
	await g.rewards.flush()
	check(report_bosses.size() == 1 and int(report_bosses[0].get("summon", 0)) == member().empower_summon_id and member().empower_summon_id != 0, "the kill's report carries the backend summon id (%s)" % str(report_bosses))
	check(await until(func() -> bool: return not prizes.is_empty(), 5.0), "the Seal's prize was claimed from the backend")
	if not prizes.is_empty():
		var p: Dictionary = prizes[0][1]
		var dropped := false
		for d in member().loot_view._drops:
			if d.get("kind", "") == "item" and String(d["item"].get("item_id", "")) == String(p["item_id"]):
				dropped = true
		check(dropped, "the prize (%s) is on the ground at the corpse" % p["item_id"])
		check(int(p["instance_id"]) > 0, "it is a real rolled instance (ilvl %d, %d affixes)" % [int(p["ilvl"]), (p["affixes"] as Array).size()])
	check(g.boss_meta.pending == "", "nothing pending after the kill")
	await dismiss()


func t_bound() -> void:
	clear_logs()
	var cost := DmGoldSink.empower_gold(int(def()["shards"]))
	hb.teleport(near_site())
	set_gold(cost + 50)
	await g.boss_meta.call_empowered(BOSS)
	var b2 := g.bosses.active_boss()
	check(b2 != null and b2.empowered, "a second Empowered call works (Seal 2 of 2)")
	boss = b2
	boss.set_physics_process(false)
	await dismiss()   # the party left: the fight is lost (the host's reset)
	check(g.boss_meta.bound.has(BOSS), "a lost fight leaves the summon bound")
	var offers: Array = []
	g.boss_meta.offered.connect(func(ctx: Dictionary) -> void: offers.append(ctx))
	hb.teleport(near_site())
	g.bosses.request_summon(BOSS)   # E at the altar
	check(offers.size() == 1 and bool(offers[0]["bound"]) and g.bosses.active_boss() == null, "the altar offers the choice (bound: free) instead of waking it")
	check(g.ui.boss_key.visible and g.ui.boss_key.emp_button.text.contains("bound: free") and not g.ui.boss_key.emp_button.disabled, "the prompt says the bound summon is free")
	var gold := int(g.character["gold"])
	g.ui.boss_key.emp_button.pressed.emit()   # the HUD's button answers for the host
	await ticks(4)
	check(int(g.character["gold"]) == gold and g.bosses.active_boss() != null and g.bosses.active_boss().empowered, "the bound summon answers free (no gold)")
	boss = g.bosses.active_boss()
	boss.set_physics_process(false)
	await dismiss()
