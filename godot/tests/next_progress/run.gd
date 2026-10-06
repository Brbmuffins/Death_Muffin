extends SceneTree
## Slice progression suite (godot/next/progress): the character persists through the OFFLINE backend and a relaunched DmNextGame restores
## it; level-ups save at once; the Damage / Wave Speed tiers reach the rites and the wave director by the current formulas; the belt
## (Q flask + cooldown, Z / X brews); death takes nothing; the save cadence and its cost.
## godot --headless --path godot --script res://tests/next_progress/run.gd

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var store := DmCounselStore.new("")   # milestone claims survive a relaunch like the file store does
var events: Array = []


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


## A fresh DmNextGame for the account's character, loaded from the backend like a relaunch.
func launch() -> void:
	var c := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	events.clear()
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "store": store})
	g.progress.event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))


func close() -> void:
	await g.leave()
	g.queue_free()
	await process_frame


func backend_char() -> Dictionary:
	return (await api.get_character()).data


func kill(n: int, level: float = 5.0) -> void:
	var b := g.local_body()
	for i in n:
		g.rewards.on_kill({"def": "robber", "area": "graves", "level": level, "elite": i % 5 == 0, "x": b.position.x, "z": b.position.z, "killer": b})
	await g.rewards.flush()


## One hit of the primary rite on a fresh robber: the host's resolved amount.
func rite_hit() -> float:
	var b := g.local_body()
	var c := b.get_node("Rites") as DmRiteCaster
	c.random = func() -> float: return 0.999
	var amounts: Array = []
	c.hit_resolved.connect(func(_r: String, _e: int, amount: float, _crit: bool, _k: bool) -> void: amounts.append(amount), CONNECT_ONE_SHOT)
	g.director.spawn("robber", b.position + Vector3(3, 0, 0), [b])
	await ticks(150)
	var e: DmEnemy = null
	for x in g.director.enemies.values():
		e = x
	var id := String(DmContent.kit("necromancer")["defaultPrimary"])
	await until(func() -> bool: return c.cooldown_left(id) <= 0.0, 5.0)
	c.request_cast(id, e.global_position, g.enemy_id(e))
	await until(func() -> bool: return not amounts.is_empty(), 3.0)
	g.director.clear()
	await ticks(5)
	return float(amounts[0]) if not amounts.is_empty() else -1.0


func _run() -> void:
	Engine.time_scale = 4.0
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("np%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	await launch()
	var ch := g.character
	var b := g.local_body()
	var p := g.progress
	check(p != null and p.prog == g.rewards.members[int(ch["id"])].prog and p.prog.character == ch, "progress node exists; the rewards member shares its DmProgression with the character")
	check(int(ch["level"]) == 1 and int(ch["experience"]) == 0 and int(ch["gold"]) == 0 and p.prog.local["totalKills"] == 0, "a new character starts at level 1, 0 xp, 0 gold, no kills")

	# ---- earn: kills -> accepted batch -> xp / kills; ground gold + shards picked up
	await kill(8)
	check(int(g.rewards.members[int(ch["id"])].stats["kills_accepted"]) == 8 and p.prog.local["totalKills"] == 8 and p.prog.kills("graves") == 8, "8 kills accepted by the backend and counted (totalKills, graves)")
	check(int(ch["experience"]) > 0 or int(ch["level"]) > 1, "xp credited (level %d, xp %d)" % [int(ch["level"]), int(ch["experience"])])
	var m: DmRewardsMember = g.rewards.members[int(ch["id"])]
	m.loot_view.gold(b.position, 120)
	m.loot_view.shard(b.position, 3)
	check(await until(func() -> bool: return int(ch["gold"]) >= 120 and int(p.prog.local["shards"]) >= 3, 5.0), "ground gold and shards are picked up into the character")

	# ---- level-up: banner, sound hook, stats, full vitals, saved at once
	var lvl0 := int(ch["level"])
	var tries := 0
	while int(ch["level"]) == lvl0 and tries < 12:
		await kill(10, 8.0)
		tries += 1
	var lvl := int(ch["level"])
	check(lvl > lvl0, "enough kills level the character up (%d -> %d)" % [lvl0, lvl])
	check(events.any(func(e: Dictionary) -> bool: return e["id"] == "banner" and String(e["ctx"]["title"]) == "Level %d" % lvl) and events.any(func(e: Dictionary) -> bool: return e["id"] == "level_up"), "level-up banner + level_up event")
	var caster := b.get_node("Rites") as DmRiteCaster
	check(float(caster.p["stats"]["level"]) == float(lvl) and float(b.p["stats"]["level"]) == float(lvl), "stats refreshed on level-up (caster + body at level %d)" % lvl)
	check(b.hp == b.max_hp and is_equal_approx(b.resource, b.resource_max), "a level-up restores health and essence")
	check(await until(func() -> bool: return int((await backend_char())["level"]) == lvl, 3.0), "a level-up is saved to the backend at once (no 45 s wait)")
	var unlocks_ok := true
	for id in DmContent.kit("necromancer")["grimoire"]:
		if DmAbilities.unlock_level(id) > 1 and DmAbilities.unlock_level(id) <= float(lvl) and DmAbilities.unlock_level(id) > float(lvl0):
			unlocks_ok = unlocks_ok and events.any(func(e: Dictionary) -> bool: return e["id"] == "toast" and String(e["ctx"]["text"]).find("Grimoire") >= 0)
	check(unlocks_ok, "newly learned rites toast the Grimoire")

	# ---- save cadence: gold alone is dirty-and-waiting; an area change saves it
	var ps := p.psync
	var bg_gold0 := int((await backend_char())["gold"])
	m.loot_view.gold(b.position, 77)
	await until(func() -> bool: return int(ch["gold"]) >= 120 + 77, 3.0)
	await ticks(30)
	check(ps.state == "dirty" and int((await backend_char())["gold"]) == bg_gold0, "gold alone leaves the save dirty and waiting (periodic 45 s timer), not written per pickup")
	g.area_changed.emit("chapterhouse")
	check(await until(func() -> bool: return int((await backend_char())["gold"]) == int(ch["gold"]), 3.0), "an area change flushes the dirty save")

	# ---- upgrades: the Damage tier reaches the rites, the Wave tier the wave director (current formulas)
	var before_hit := await rite_hit()
	var sp0 := float(caster.p["stats"]["spellPower"])
	ch["gold"] = 100000
	check(g.ui_host != null and p.prog.damage_cost() > 0, "damage upgrade has a price")
	var cost := p.prog.damage_cost()
	g.ui_host.buy_upgrade("damage")
	check(p.prog.local["damageTier"] == 1 and int(ch["gold"]) == 100000 - cost, "buying Damage takes its priced gold and raises the tier")
	var expect_ratio := (1.0 + float(DmCombatData.progression()["damage_upgrade"]["perTier"]) * 1.0)
	check(absf(float(caster.p["stats"]["spellPower"]) / sp0 - expect_ratio) < 0.001, "tier 1 raises the caster's spell power by the current formula (x%.3f)" % expect_ratio)
	var after_hit := await rite_hit()
	check(before_hit > 0.0 and after_hit > before_hit * 1.01 and absf(after_hit / before_hit - expect_ratio) < 0.06, "the rite's damage follows the tier (%.1f -> %.1f)" % [before_hit, after_hit])
	check(g.ui_host.hud_state()["damage"]["tier"] == 1, "the HUD's upgrades box shows tier 1")
	var base_interval := g.director.wave_interval
	var base_size := g.director.wave_size
	var base_cap := g.director.cap
	g.ui_host.buy_upgrade("wave")
	await until(func() -> bool: return not ps._pumping and ps._queue.is_empty() and p.prog.outbox.is_empty(), 3.0)   # the backend answers a purchase before the next is made
	g.ui_host.buy_upgrade("wave")
	await until(func() -> bool: return not ps._pumping and ps._queue.is_empty() and p.prog.outbox.is_empty(), 3.0)
	var wm := DmWaveUpgrades.wave_modifiers(2.0)
	check(p.prog.local["waveTierActive"] == 2 and g.director.wave_tier == 2.0 and g.rewards.wave_tier == 2.0, "buying Wave Speed twice: active tier 2 reaches the director and the rewards")
	check(absf(g.director.wave_interval - base_interval * float(wm["intervalMult"])) < 1e-6 and g.director.wave_size == DmMath.js_round(float(base_size) * float(wm["sizeMult"])) and g.director.cap == DmMath.js_round(float(base_cap) * float(wm["capMult"])), "wave interval / size / cap follow wave_modifiers(2) (%.2f s, %d, %d)" % [g.director.wave_interval, g.director.wave_size, g.director.cap])
	check(g.director.wave_interval < base_interval and g.director.cap > base_cap, "waves come faster and the area holds more")
	ch["gold"] = 0

	# ---- belt: Q flask (cooldown), Z / X brews
	var inv := g.ui_host.inventory
	var f0 := inv.count("flask_hp_minor")   # kills may have dropped some
	inv.add({"item_id": "flask_hp_minor", "quantity": 3})
	inv.add({"item_id": "flask_damage", "quantity": 2})
	inv.add({"item_id": "flask_speed", "quantity": 1})
	inv.add({"item_id": "meal_crypt_eel", "quantity": 1})
	b.p["hp"] = b.p["stats"]["maxHp"] * 0.2
	b._mirror_from_state()
	var hp0 := b.hp
	g.ui_host.use_belt("heal")
	var heal := float(DmContent.healing_flasks()["flask_hp_minor"]) * b.max_hp
	check(inv.count("flask_hp_minor") == f0 + 2 and absf(b.hp - (hp0 + heal)) < 0.5, "Q drinks a healing flask: +%d%% of max health, one consumed" % int(DmContent.healing_flasks()["flask_hp_minor"] * 100))
	g.ui_host.use_belt("heal")
	check(inv.count("flask_hp_minor") == f0 + 2, "the sip cooldown blocks a second flask (%.1f s)" % (DmBrews.heal_cooldown_ms() / 1000.0))
	var row: Dictionary = g.ui_host.hud_state()["brews"][0]
	check(float(row["frac"]) > 0.0 and int(row["count"]) == f0 + 2 and not row["empty"], "the heal chip shows the cooldown sweep and the count")
	await ticks(int(DmBrews.heal_cooldown_ms() / 1000.0 * 60.0) + 20)
	b.p["hp"] = b.p["stats"]["maxHp"] * 0.2
	g.ui_host.use_belt("heal")
	check(inv.count("flask_hp_minor") == f0 + 1, "after the cooldown a flask can be drunk again")
	var dmg_plain := await rite_hit()
	g.ui_host.use_belt("elixir")
	check(inv.count("flask_damage") == 1 and b.p["brews"]["elixir"] != null and caster.p["brews"]["elixir"] != null, "Z drinks the elixir on the body and its caster")
	var dmg_brewed := await rite_hit()
	check(absf(dmg_brewed / dmg_plain - 1.15) < 0.06, "an elixir of damage (+15%%) raises the rite's damage (%.1f -> %.1f)" % [dmg_plain, dmg_brewed])
	var belt_rows: Array = g.ui_host.hud_state()["brews"]
	check(belt_rows[1]["active"] and int(belt_rows[1]["left"]) > 0 and belt_rows[1]["key"] == "Z", "the elixir chip shows it active with seconds left")
	g.ui_host.use_belt("tonic")
	await ticks(3)
	var sp := DmPlayerRules.move_speed(b.p, b.clock_ms())
	check(absf(sp / float(b.p["stats"]["moveSpeed"]) - 1.2) < 0.01, "X drinks the tonic of speed: +20%% move speed")
	g.ui_host.use_item("meal_crypt_eel")
	check(inv.count("meal_crypt_eel") == 0 and b.hp > 0.0, "a meal is eaten from the bag (heal over time)")
	g.ui_host.use_belt("elixir")
	check(inv.count("flask_damage") == 0, "the last elixir is drunk (extends the running one)")
	var bag_before := inv.count("flask_hp_minor")
	g.ui_host.use_belt("tonic")
	check(inv.count("flask_speed") == 0 and inv.count("flask_hp_minor") == bag_before, "an empty slot drinks nothing")

	# ---- death takes nothing
	var snap := {"level": ch["level"], "xp": ch["experience"], "gold": ch["gold"], "shards": p.prog.local["shards"], "kills": p.prog.local["totalKills"], "bag": JSON.stringify(inv.slots.map(func(s: Dictionary) -> String: return "%s:%s" % [s["item_id"], s["quantity"]]))}
	b.take_damage(1e9, null)
	check(not b.alive, "the hero dies")
	check(await until(func() -> bool: return b.alive, 8.0), "and is called back to the Chapterhouse")
	check(snap["level"] == ch["level"] and snap["xp"] == ch["experience"] and snap["gold"] == ch["gold"] and snap["shards"] == p.prog.local["shards"] and snap["kills"] == p.prog.local["totalKills"], "death takes no xp, gold, shards or kills")
	check(snap["bag"] == JSON.stringify(inv.slots.map(func(s: Dictionary) -> String: return "%s:%s" % [s["item_id"], s["quantity"]])), "death takes nothing from the bag")

	# ---- milestones go through the rewards path (a ground drop of gold)
	var drops: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _pos: Vector3) -> void: drops.append(d))
	await kill(30, 6.0)
	await ticks(5)
	check(not p._claimed.is_empty() and events.any(func(e: Dictionary) -> bool: return e["id"] == "toast" and String(e["ctx"]["text"]).begins_with("Milestone")), "kill milestones fire (%d claimed)" % p._claimed.size())
	var claimed_n: int = p._claimed.size()
	check(drops.any(func(d: Dictionary) -> bool: return d["kind"] == "gold"), "milestone gold arrives as a ground drop (the rewards path), not a direct credit")
	await ticks(60)
	check(await until(func() -> bool: return p.psync.state == "saved" or p.psync.state == "dirty", 3.0), "save state is sane")

	# ---- save cost (write-behind: no frame is blocked on the backend)
	var t0 := Time.get_ticks_usec()
	for i in 200:
		p.prog.add_gold(1.0)
	var add_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	p.psync.flush()   # returns at its first await: what the calling frame pays for a save
	var flush_us := Time.get_ticks_usec() - t0
	await until(func() -> bool: return p.psync.state == "saved", 3.0)
	print("save cost: 200 add_gold %d us (%.1f us each), flush call %d us" % [add_us, add_us / 200.0, flush_us])
	check(add_us < 50000 and flush_us < 20000, "a pickup is ~free and a save call returns at once (write-behind): %d us per 200 pickups, %d us per flush" % [add_us, flush_us])

	# ---- relaunch: the same character comes back
	await p.flush_all()
	var want := {"level": int(ch["level"]), "xp": int(ch["experience"]), "gold": int(ch["gold"]), "shards": int(p.prog.local["shards"]),
		"kills": int(p.prog.local["totalKills"]), "areas": JSON.stringify(p.prog.local["areaKills"]), "dmg": int(p.prog.local["damageTier"]),
		"wave": int(p.prog.local["waveTierOwned"]), "unlocked": JSON.stringify(p.prog.local["unlocked"]), "bag": JSON.stringify(inv.slots.map(func(s: Dictionary) -> String: return "%s:%s" % [s["item_id"], s["quantity"]]))}
	var sp_before := float(caster.p["stats"]["spellPower"])
	await close()
	await launch()
	ch = g.character
	p = g.progress
	b = g.local_body()
	caster = b.get_node("Rites") as DmRiteCaster
	check(int(ch["level"]) == want["level"] and int(ch["experience"]) == want["xp"] and int(ch["gold"]) == want["gold"], "relaunch: level %d, xp %d, gold %d restored" % [want["level"], want["xp"], want["gold"]])
	check(int(p.prog.local["shards"]) == want["shards"] and int(p.prog.local["totalKills"]) == want["kills"] and JSON.stringify(p.prog.local["areaKills"]) == want["areas"], "relaunch: shards, total and area kills restored")
	check(int(p.prog.local["damageTier"]) == want["dmg"] and int(p.prog.local["waveTierOwned"]) == want["wave"] and JSON.stringify(p.prog.local["unlocked"]) == want["unlocked"], "relaunch: upgrade tiers and unlocked areas restored")
	check(JSON.stringify(g.ui_host.inventory.slots.map(func(s: Dictionary) -> String: return "%s:%s" % [s["item_id"], s["quantity"]])) == want["bag"], "relaunch: the bag is restored")
	check(absf(float(caster.p["stats"]["spellPower"]) - sp_before) < 0.001 and float(caster.p["stats"]["level"]) == float(want["level"]), "relaunch: the rites' stats carry the restored level and damage tier")
	check(g.director.wave_tier == 2.0 and g.rewards.wave_tier == 2.0 and g.director.cap > base_cap, "relaunch: the wave director runs at the restored Wave Speed tier")
	check(p._claimed.size() == claimed_n, "relaunch: milestone claims are kept (%d)" % claimed_n)
	await kill(1)
	await ticks(5)
	check(p._claimed.size() == claimed_n, "a milestone is not paid twice after a relaunch")
	check(int((await backend_char())["level"]) == want["level"], "the backend holds the same level")
	await close()
	Engine.time_scale = 1.0
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
