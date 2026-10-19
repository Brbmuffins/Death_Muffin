extends SceneTree
## HUD feeds, the Legion purchase and panel verification on the rebuilt client (client/next/hud): the save chip, wave dial, forwarded sounds, and the panels' basic actions
## working through the (offline) API. (The counsel's facts and busy flags are tests/counsel.gd's.)
## godot --headless --fixed-fps 60 --path client --script res://tests/hud_actions/run.gd

const DT := 1.0 / 60.0
var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var ui: DmGameUi
var h: DmNextUiHost
var sounds: Array = []
var baseline: Array = []


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


func frames(n: int) -> void:
	for i in n:
		await process_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func count_sound(name: String) -> int:
	return sounds.count(name)


## Visible text under the UI (labels, rich labels, buttons).
func texts() -> Array:
	var out: Array = []
	for c in ui.find_children("*", "", true, false):
		if c is CanvasItem and not (c as CanvasItem).is_visible_in_tree():
			continue
		if c is Label and (c as Label).text != "":
			out.append((c as Label).text)
		elif c is RichTextLabel and (c as RichTextLabel).get_parsed_text() != "":
			out.append((c as RichTextLabel).get_parsed_text())
		elif c is Button and (c as Button).text != "":
			out.append((c as Button).text)
	return out


## What a panel adds on screen over the closed HUD (lower-cased, joined).
func shown() -> String:
	var out := PackedStringArray()
	for t: String in texts():
		if not baseline.has(t):
			out.append(t.to_lower())
	return " | ".join(out)


## Opens a panel (closing the others).
func open(p: String) -> void:
	ui.close_panels()
	await frames(2)
	ui.toggle_panel(p)
	await frames(4)


## Writes the character's state to the backend now (the backend prices purchases from ITS purse).
func save_now() -> void:
	h.prog.save_dirty = true
	g.progress.psync.tick(0.0)
	await g.progress.psync.flush()


func item_of_type(types: Array, rarity: String = "") -> String:
	for id in DmContent.items():
		var m: Dictionary = DmContent.items()[id]
		if String(m.get("type", "")) in types and (rarity == "" or String(m.get("rarity", "")) == rarity):
			return String(id)
	return ""


func body() -> DmHeroBody:
	return g.local_body()


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("hc%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c0 := await api.load_or_create_character(2)
	var cid := int(c0.data["id"])
	await api.necro_import_local(cid, {"ascension": 0, "ashes": 400, "shards": 40, "totalKills": 30, "bossKills": 0, "areaKills": {"graves": 30}, "boons": {}})
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start((await api.load_or_create_character(2)).data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": true, "store": DmCounselStore.new("")})
	ui = g.ui
	h = g.ui_host
	h.sfx.connect(func(n: String) -> void: sounds.append(n))
	var ch := h.character
	var prog := h.prog
	var m: DmRewardsMember = g.rewards.members[cid]
	await frames(30)
	baseline = texts()

	# ---- the full panel set is pre-built under the loading cover, like the current client
	check(ui.warm_panels == DmNextGame.WARM_PANELS, "all %d panels are warmed during start (today's list less the Altar, DECISIONS B36)" % ui.warm_panels.size())
	# ---- save chip: saved -> dirty -> saving -> saved, retrying warns
	var chip := h.hud_state()["save"] as Dictionary
	check(chip["text"] == "Saved ✓" and not chip["warn"] and ui.hud.save_lbl.text == "Saved ✓", "save chip starts at Saved")
	await until(func() -> bool: return g.progress.psync.state == "saved", 3.0)
	prog.save_dirty = true
	g.progress.psync.tick(0.0)
	check(g.progress.psync.state == "dirty" and h.hud_state()["save"]["text"] == "Unsaved changes", "save chip shows the dirty state")
	var seen: Array = []
	g.progress.psync.save_state_changed.connect(func(st: String) -> void: seen.append(st))
	await g.progress.psync.flush()
	check(seen == ["saving", "saved"], "the sync goes saving -> saved around a flush (%s)" % str(seen))
	g.progress.psync.state = "saving"
	check(h.hud_state()["save"]["text"] == "Saving…" and not h.hud_state()["save"]["warn"], "save chip shows Saving while the write is in flight")
	g.progress.psync.state = "saved"
	check(await until(func() -> bool: return g.progress.psync.state == "saved", 3.0) and h.hud_state()["save"]["text"] == "Saved ✓", "save chip returns to Saved")
	h.inventory.state = "retrying"
	var vm := h.hud_state()
	check(vm["save"]["warn"] and String(vm["save"]["text"]).begins_with("Save failed"), "a failing bag save warns on the chip")
	h.inventory.state = "saved"
	ui.hud.apply(h.hud_state())
	check(ui.hud.save_lbl.text == "Saved ✓", "the chip text reaches the HUD label")

	# ---- wave dial: Wave Speed active tier down / up through the HUD buttons
	set_gold(1000000)
	h.buy_upgrade("wave")
	await until(func() -> bool: return int(prog.local["waveTierOwned"]) >= 1, 3.0)
	await until(func() -> bool: return not g.progress.psync._pumping and prog.outbox.is_empty(), 3.0)
	h.buy_upgrade("wave")
	await until(func() -> bool: return int(prog.local["waveTierOwned"]) >= 2, 3.0)
	await until(func() -> bool: return not g.progress.psync._pumping and prog.outbox.is_empty(), 3.0)
	check(int(prog.local["waveTierActive"]) == 2 and g.director.wave_tier == 2.0, "owning 2 wave tiers has tier 2 active")
	ui.hud.dial_wave.emit(-1)
	check(int(prog.local["waveTierActive"]) == 1 and g.director.wave_tier == 1.0 and g.rewards.wave_tier == 1.0, "the dial's minus lowers the active tier and the director follows")
	check(h.hud_state()["wave"]["active"] == 1 and h.hud_state()["wave"]["owned"] == 2, "vm: wave active 1 of 2 owned")
	ui.hud.dial_wave.emit(1)
	ui.hud.dial_wave.emit(1)
	check(int(prog.local["waveTierActive"]) == 2, "the dial's plus is capped at the owned tier")
	ui.hud.dial_wave.emit(-5)
	check(int(prog.local["waveTierActive"]) == 0 and g.director.wave_tier == 0.0, "the dial cannot go below 0")
	set_gold(0)

	# ---- sounds: forwarded once each (loot drop by rarity, coin, shard, pickup, hero hurt, low health)
	var b := body()
	b.heal(1e6)
	sounds.clear()
	var drop_item := item_of_type(["weapon", "chest_armor"], "common")
	m.loot_view.item(b.position + Vector3(3, 0, 0), {"item_id": drop_item, "quantity": 1})
	# (the drop, coin and shard sounds are the loot node's own calls into the AudioDirector, not the adapter's `sfx` signal, and the director reports only the sounds it
	# synthesizes: they are not counted here; the floats of a fight are tests/loot's)
	sounds.clear()
	m.loot_view.gold(b.position, 25)
	m.loot_view.shard(b.position, 1)
	await until(func() -> bool: return count_sound("coin") >= 1 and count_sound("shard") >= 1, 4.0)
	await frames(10)
	sounds.clear()
	b.take_damage(b.max_hp * 0.2, null)
	await frames(2)
	check(count_sound("hurt") == 1 and count_sound("lowHealth") == 0, "a hurt hero plays hurt once")
	b.take_damage(b.max_hp * 0.55, null)
	await frames(2)
	check(count_sound("hurt") == 2 and count_sound("lowHealth") == 1, "under 30 % health adds lowHealth (once)")
	b.heal(1e6)

	# ---- Legion: tier bought through the same API; thrall hp / damage follow (the cap comes from boons and weapons, not the tier), standing thralls get the bump
	set_gold(1000000)
	await save_now()   # the backend prices from ITS purse
	var caster := b.get_node("Rites") as DmRiteCaster
	var th := caster.thralls()   # the legion is the core's (DmCoreLegion)
	var cap0 := int(h.hud_state()["thrall_cap"])
	var st0: Dictionary = h.build_cache()["stats"]
	var hp0 := float(st0["thrallHp"])
	var dmg0 := float(st0["thrallDamage"])
	h.shell.core_host.corpses.add_corpse(b.position.x + 3.0, b.position.z, "normal", "robber", false, 0.0, 1.0, g.area_id)
	var spec := {"kind": b.mods["thrallKind"], "cap": b.mods["thrallCap"], "hp": caster.p["stats"]["thrallHp"], "damage": caster.p["stats"]["thrallDamage"], "attackSpeedMult": b.mods["thrallAttackSpeedMult"], "r": 0.8}
	var rr: Dictionary = th.raise(spec, b.position + Vector3(3.0, 0.0, 0.0))
	await ticks(3)
	var standing := int((rr["thralls"] as Array)[0]) if bool(rr["ok"]) and not (rr["thralls"] as Array).is_empty() else 0
	var t_hp0 := float(th.info(standing)["max_hp"]) if standing != 0 else 0.0
	var tier0 := int(prog.local["legionTier"])
	check(DmUpgrades.legion_cost(tier0) > 0 and tier0 < DmUpgrades.max_tier("legion"), "legion tier %d has a price (%dg)" % [tier0, DmUpgrades.legion_cost(tier0)])
	var gold_b := int(ch["gold"])
	var err := await h.buy_legion()
	check(err == "" and int(prog.local["legionTier"]) == tier0 + 1, "buy_legion: the backend takes the gold and raises the tier (%d -> %d)" % [tier0, int(prog.local["legionTier"])])
	check(int(ch["gold"]) == gold_b - DmUpgrades.legion_cost(tier0), "...and the character's gold follows (%d)" % int(ch["gold"]))
	var st1: Dictionary = h.build_cache()["stats"]
	check(float(st1["thrallHp"]) > hp0 and float(st1["thrallDamage"]) > dmg0, "the tier raises thrall hp (%.0f -> %.0f) and damage (%.1f -> %.1f) in the build" % [hp0, float(st1["thrallHp"]), dmg0, float(st1["thrallDamage"])])
	check(float(caster.p["stats"]["thrallHp"]) == float(st1["thrallHp"]), "the caster's stats follow, so new thralls are raised stronger")
	var t_hp1 := float(th.info(standing)["max_hp"]) if standing != 0 else 0.0
	check(standing != 0 and t_hp1 > t_hp0, "a thrall already standing gets the one-time bump (%.0f -> %.0f)" % [t_hp0, t_hp1])
	check(int(h.hud_state()["thrall_cap"]) == cap0 and int(caster.mods["thrallCap"]) == cap0, "the cap is the build's (tiers do not move it; boons and weapons do): HUD, caster agree at %d" % cap0)
	set_gold(0)
	await save_now()
	var broke := await h.buy_legion()
	check(broke != "" and int(prog.local["legionTier"]) == tier0 + 1, "buy_legion refuses without the gold (%s)" % broke)
	set_gold(1000000)
	await save_now()
	var pre := int(prog.local["legionTier"])
	h.buy_upgrade("legion")
	await until(func() -> bool: return int(prog.local["legionTier"]) == pre + 1, 3.0)
	check(int(prog.local["legionTier"]) == pre + 1, "buy_upgrade('legion') (the DmGame entry) buys one tier")
	set_gold(0)
	for id in g.core_host.core.thrall_ids():
		g.core_host.core.kill_thrall(id, "crumbled")

	# ---- panels
	await panels(cid)
	print("---- %d passed, %d failed" % [passed, failed])
	await g.leave()
	print("%s hud_actions %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


func panels(cid: int) -> void:
	ui.close_panels()
	await frames(2)
	# seed the bag through the adapter's bag (it flushes to the backend like the game)
	var weapon := item_of_type(["weapon"])
	var seeded: Array = (await api.get_inventory(cid)).data.filter(func(r: Dictionary) -> bool: return int(r["slot_index"]) < 48)
	seeded.append({"slot_index": 47, "item_id": weapon, "quantity": 1})   # the bag is the server's (DECISIONS B25): seeded on the mock, as a GM would
	await api.save_inventory(cid, seeded.map(func(r: Dictionary) -> Dictionary: return {"slot_index": int(r["slot_index"]), "item_id": r["item_id"], "quantity": int(r["quantity"]), "instance_id": r.get("instance_id")}), 48)
	await h.refresh_inventory()
	var meta := DmContent.item(weapon)

	# Bag
	await open("inventory")
	check(ui.is_open("inventory") and shown().contains("bag"), "Bag opens")
	var n0 := h.slots.size()
	check((await h.bag_sort()) == "", "Bag: the server sorts it")
	check(h.slots.size() == n0 and (await api.get_inventory(cid)).data.size() == n0, "Bag: sorted on the backend (%d rows)" % n0)

	# Sheet
	await open("sheet")
	var s := shown()
	check(ui.is_open("sheet") and s.contains("level 1") or s.contains("gravecaller"), "Sheet opens with the character")
	check(s.contains("health") or s.contains("spell power") or s.contains("str"), "Sheet shows stats from the build (%s)" % s.substr(0, 80))

	# Capes & Pets
	await open("cosmetics")
	await frames(10)
	var view: Dictionary = ui.pa.char_win.cosmetics.view
	check(ui.is_open("cosmetics") and not (view.get("pets", []) as Array).is_empty() and not (view.get("capes", []) as Array).is_empty(), "Capes & Pets opens with the backend's capes and pets")
	var pet: Dictionary = (view["pets"] as Array)[0]
	await DmTestBag.give(h.inventory, {"item_id": String(pet["charm"]), "quantity": 1})
	await h.inventory.flush()
	await h.refresh_inventory()
	ui.pa.char_win.cosmetics.adopt_requested.emit(String(pet["id"]))
	check(await until(func() -> bool: return (ui.pa.char_win.cosmetics.view.get("selected", {}) as Dictionary).get("pet") == pet["id"], 4.0), "Capes & Pets: adopting a companion works through the API")

	# Legion
	await open("legion")
	var tier := int(h.progress["legionTier"])
	set_gold(1000000)
	await save_now()
	ui.pa.grim_win.legion.reinforce_requested.emit()
	check(await until(func() -> bool: return int(h.progress["legionTier"]) == tier + 1, 4.0), "Legion panel: Reinforce buys a tier through the API (%d -> %d)" % [tier, int(h.progress["legionTier"])])
	set_gold(0)

	# Forge: craft
	await open("forge")
	var forge: DmForgePanel = ui.pb.forges[""]
	check(ui.is_open("forge") and forge.visible, "Forge opens")
	var recipe: Dictionary = {}
	for rc in DmRecipes.all():
		if int(rc["skill_level_required"]) <= 1 and (rc["ingredients"] as Array).size() <= 2 and String(DmContent.item(String(rc["result_item_id"])).get("type", "")) != "":
			recipe = rc
			break
	for ing in recipe["ingredients"]:
		await DmTestBag.give(h.inventory, {"item_id": String(ing["item_id"]), "quantity": int(ing["quantity"]) * 2})
	await h.inventory.flush()
	await h.refresh_inventory()
	var before := h.inventory.count(String(recipe["result_item_id"]))
	forge.craft_requested.emit(String(recipe["id"]), 1)
	check(await until(func() -> bool: return h.inventory.count(String(recipe["result_item_id"])) > before, 4.0), "Forge: crafting %s consumes ingredients and yields the result" % String(recipe["id"]))
	# reforge quote reads the backend
	var qr: DmResult = await api.reforge_quote(cid)
	check(qr.ok or qr.error != "", "Forge: the reforge quote answers (%s)" % ("ok" if qr.ok else qr.error))

	# Salvage (the Bone Grinder)
	var junk := item_of_type(["weapon", "chest_armor"], "common")
	await DmTestBag.give(h.inventory, {"item_id": junk, "quantity": 1})
	await h.inventory.flush()
	await h.refresh_inventory()
	await open("salvage")
	var slot_idx := -1
	for sl in h.slots:
		if sl["item_id"] == junk and int(sl.get("equipped", 0)) == 0:
			slot_idx = int(sl["slot_index"])
	var held0 := h.inventory.count(junk)
	ui.pb.salvage.salvage_requested.emit([slot_idx])
	check(await until(func() -> bool: return h.inventory.count(junk) < held0, 4.0), "Salvage: the grinder takes the piece through the API")

	# Reagent shelf
	await open("shelf")
	check(ui.is_open("shelf"), "Reagent shelf opens")

	# Vault (Chapterhouse is safe)
	var vault_item := item_of_type(["weapon"])
	await DmTestBag.give(h.inventory, {"item_id": vault_item, "quantity": 1})
	await h.inventory.flush()
	await h.refresh_inventory()
	await open("vault")
	await until(func() -> bool: return not ui.pb.vault.state.is_empty() if "state" in ui.pb.vault else true, 3.0)
	check(ui.is_open("vault"), "Vault opens in the Chapterhouse")
	var vs := -1
	for sl in h.slots:
		if sl["item_id"] == vault_item and int(sl.get("equipped", 0)) == 0 and int(sl["slot_index"]) < DmLoot.bag_size():
			vs = int(sl["slot_index"])
	var vbag0 := h.slots.size()
	ui.pb.vault.deposit_requested.emit(vs)
	check(await until(func() -> bool: return h.slots.size() < vbag0, 4.0), "Vault: depositing moves the piece out of the bag through the API")
	var vr: DmResult = await api.get_vault(cid)
	check(vr.ok and JSON.stringify(vr.data).contains(vault_item), "Vault: the backend holds it")

	# Contracts
	await open("contracts")
	await until(func() -> bool: return not ui.pb.contracts.board.is_empty() if "board" in ui.pb.contracts else true, 3.0)
	var cr: DmResult = await api.get_contracts(cid)
	check(ui.is_open("contracts") and cr.ok, "Contracts opens with the board")
	var order: Dictionary = (cr.data["contracts"] as Array)[0]
	await DmTestBag.give(h.inventory, {"item_id": String(order["itemId"]), "quantity": int(order["qty"])})
	await h.inventory.flush()
	await h.refresh_inventory()
	var gold0 := int(h.character["gold"])
	ui.pb.contracts.deliver_requested.emit(int(order["slot"]))
	check(await until(func() -> bool: return h.inventory.count(String(order["itemId"])) == 0 or h.inventory.count(String(order["itemId"])) < int(order["qty"]), 4.0), "Contracts: delivering an order takes the goods through the API")
	var cr2: DmResult = await api.get_contracts(cid)
	var done_slot := false
	for o in cr2.data["contracts"]:
		if int(o["slot"]) == int(order["slot"]) and o["done"]:
			done_slot = true
	check(done_slot, "Contracts: the backend marks the order filled")
	await until(func() -> bool: return int(h.character["gold"]) > gold0, 3.0)
	check(int(h.character["gold"]) >= gold0, "Contracts: the character was refreshed after the reward")

	# Professions
	await open("professions")
	var pr: DmResult = await api.get_professions(cid)
	check(ui.is_open("professions") and pr.ok and not shown().is_empty(), "Professions opens with the skills")
	check(shown().contains("mining") or shown().contains("woodcut") or shown().contains("fishing") or shown().contains("skill"), "Professions shows the skill list")

	# Garden
	var seed_def: Dictionary = DmGarden.seeds()[0]
	await DmTestBag.give(h.inventory, {"item_id": String(seed_def["id"]), "quantity": 2})
	await h.inventory.flush()
	await h.refresh_inventory()
	await open("garden")
	await until(func() -> bool: return not ui.pb.garden.view.is_empty(), 3.0)
	check(ui.is_open("garden") and not (ui.pb.garden.view.get("plots", []) as Array).is_empty(), "Garden opens with the plots")
	var plot := ""
	for pl in ui.pb.garden.view["plots"]:
		if pl["state"] == "empty" and DmGarden.plant_blocker(DmGarden.plot_def(String(pl["plot"])), String(seed_def["id"]), int(ui.pb.garden.view["level"]), null, 0) == "":
			plot = String(pl["plot"])
			break
	check(plot != "", "Garden has a plot the seed can go in")
	ui.pb.garden.plant_requested.emit(plot, String(seed_def["id"]), false)
	check(await until(func() -> bool: return (ui.pb.garden.view["plots"] as Array).any(func(pl: Dictionary) -> bool: return pl["plot"] == plot and pl["state"] != "empty"), 4.0), "Garden: planting works through the API")

	# Labor
	await open("labor")
	await until(func() -> bool: return not ui.pb.labor.view.is_empty(), 3.0)
	check(ui.is_open("labor") and not (ui.pb.labor.view.get("slots", []) as Array).is_empty(), "Labor opens with the laborer slots")
	var node := ""
	for n in DmLabor.posts_for({}):
		node = String(n["id"])
		break
	ui.pb.labor.assign_requested.emit(0, node)
	check(await until(func() -> bool: return ui.pb.labor.view["slots"][0]["nodeType"] == node, 4.0), "Labor: assigning a laborer works through the API (%s)" % node)

	# (Ascension: the Altar and its boons are not in the client, DECISIONS B36)

	# Codex / Atlas / Map
	await open("codex")
	check(ui.is_open("codex") and shown().contains("the dead") and shown().contains("gear atlas"), "Codex opens with its sections")
	await open("atlas")
	check(ui.is_open("atlas") and shown().length() > 20, "Atlas opens with the gear data")
	# its verdicts are worked out again in the background after the bag changes, but never during a fight (a core stays the game's)
	var fight := [true]
	ui.pa.in_fight = func() -> bool: return fight[0]
	ui.pa._atlas_key = -1   # (the gear "changed": a recompute is due)
	ui.pa.atlas_dirty()
	var t_end := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < t_end:
		await process_frame
	check(not ui.pa.atlas_idle() and ui.pa._atlas_task < 0, "in a fight the Atlas's verdicts wait: no worker started (%d)" % ui.pa._atlas_task)
	fight[0] = false
	check(await until(func() -> bool: return ui.pa.atlas_idle() and ui.pa._atlas_task >= 0, 5.0), "after the fight they are worked out")
	await open("map")
	check(ui.is_open("map") and (shown().contains("hollow graves") or shown().contains("chapterhouse")), "Waystone map opens with the unlocked areas")

	ui.close_panels()


## Fund (or drain) the character as play would: the change counts as earned, so the next gains save gives it to the backend too (DECISIONS B23).
func set_gold(n: int) -> void:
	var p: DmProgression = g.progress.prog
	p.gold_unsent += n - int(p.character.get("gold", 0))
	p.character["gold"] = n
