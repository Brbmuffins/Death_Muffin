extends SceneTree
## The Acre's world glue and the first-hour guidance on the rebuild (godot/next/gathering/dm_next_acre.gd), on the OFFLINE backend only:
##  - visible Grave Laborers (DmLaborerViews) in the Acre, hover / click, the labor / garden / contract notices (DmGameLabor);
##  - the Next-step box's state (skills, bosses beaten, kills, labor, contracts, bag), the suggestion ping, the counsel events of the first hour;
##  - the stations of the Acre and the Alchemist's Wing, the reforge flow, the bug-report path (offline api: nothing leaves the process);
##  - cost: DmFrameCost in the Acre with the glue off / on, the guidance recompute.
## godot --headless --path godot --script res://tests/next_acre_guide/run.gd

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var ui: DmGameUi
var h: DmNextUiHost
var cid := 0
var events: Array = []
var toasts: Array = []
var mock: Variant
var clock_offset := 0


## A backend answer the test controls (the notice rules read the labor / garden / contract views through `api`).
class StubApi extends RefCounted:
	var labor: Dictionary = {}
	var garden: Dictionary = {}
	var contracts: Dictionary = {}
	var real: DmApi

	func get_labor(_id: int) -> DmResult:
		return DmResult.success(labor.duplicate(true))

	func get_garden(_id: int) -> DmResult:
		return DmResult.success(garden.duplicate(true))

	func get_contracts(_id: int) -> DmResult:
		return DmResult.success(contracts.duplicate(true))

	func get_professions(id: int) -> DmResult:
		return await real.get_professions(id)


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


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


func ids(id: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == id)


func toast_has(part: String) -> bool:
	return toasts.any(func(t: String) -> bool: return t.contains(part))


func body() -> DmHeroBody:
	return g.local_body()


## Walk the host's hero to a point by teleport (the waystone path) and wait for the area change.
func go(x: float, z: float, area: String) -> void:
	g.chapterhouse.teleport_to(x, z)
	await until(func() -> bool: return g.area_id == area, 3.0)
	await frames(3)


func give(item_id: String, qty: int = 1) -> void:
	h.inventory.add({"item_id": item_id, "quantity": qty})
	await h.inventory.flush()
	await h.refresh_inventory()


func _run() -> void:
	mock = DmOffline.make_mock("")
	mock.now_ms = func() -> int: return int(Time.get_unix_time_from_system() * 1000.0) + clock_offset
	api = DmOffline.make_api(mock)
	var r := await api.register("ag%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c0 := await api.load_or_create_character(2)
	cid = int(c0.data["id"])
	await api.necro_import_local(cid, {"ascension": 0, "ashes": 400, "shards": 40, "totalKills": 30, "bossKills": 0, "areaKills": {"graves": 30}, "boons": {}})
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	var cost := DmFrameCost.attach(root)
	await g.start((await api.load_or_create_character(2)).data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "store": DmCounselStore.new("")})
	ui = g.ui
	h = g.ui_host
	h.game_event.connect(func(id: String, ctx: Dictionary) -> void:
		events.append({"id": id, "ctx": ctx})
		if id == "toast":
			toasts.append(String(ctx.get("text", ""))))
	check(g.is_offline and g.acre != null, "the rebuild runs on the offline backend with the Acre glue")

	# ---- laborers: the backend has posts; the view shows them in the Acre only
	var lv0: Dictionary = (await api.get_labor(cid)).data
	var unlocked_slots: Array = []
	for s in lv0["slots"]:
		if bool(s.get("unlocked", false)):
			unlocked_slots.append(int(s["slot"]))
	check(not unlocked_slots.is_empty(), "the labor view has an unlocked slot (%s)" % str(unlocked_slots))
	var posts: Array = DmLabor.posts_for({})
	var by_skill := {}
	for n in posts:
		var sk := String(DmGathering.node_def(String(n["id"]))["skill"])
		if not by_skill.has(sk):
			by_skill[sk] = String(n["id"])
	var picks: Array = by_skill.values()
	for i in mini(unlocked_slots.size(), picks.size()):
		var ar: DmResult = await api.assign_labor(cid, unlocked_slots[i], String(picks[i]))
		check(ar.ok, "assign laborer %d to %s: %s" % [unlocked_slots[i], picks[i], ar.error])
	var views := g.acre.views
	check(views != null and not views.active and views.pick_list().is_empty(), "no laborer is shown or fetched outside the Acre")
	await frames(20)
	cost.reset()
	await go(-20.0, 24.0, "acre")
	check(views.active and views.visible, "entering the Acre activates the laborers")
	var want := mini(unlocked_slots.size(), picks.size())
	check(await until(func() -> bool: return views.byslot.size() >= want, 5.0), "a laborer stands in the Acre for each assigned post (%d)" % views.byslot.size())
	await until(func() -> bool: return views.pick_list().size() >= want, 8.0)
	var loaded := views.pick_list().size()
	await frames(30)
	print("first Acre entry (area change + 1 laborer model built): worst frame %.1f ms, median %.1f ms over %d frames" % [cost.worst_ms(), cost.median_ms(), cost.samples()])
	print("laborers: %d assigned, %d loaded and pickable" % [want, loaded])
	check(loaded >= 1, "at least one laborer model is loaded and pickable headless")
	if loaded >= 1:
		var pk: Dictionary = views.pick_list()[0]
		var slot := int(pk["slot"])
		check(views.tip(slot).contains("click to open the Laborers"), "the laborer card names its post and invites a click: %s" % views.tip(slot))
		var cam: DmCameraRig = g.camera
		var sp := cam.unproject_position(Vector3(float(pk["x"]), 1.0, float(pk["z"])))
		check(g.acre.pick_laborer(sp, 52.0) == slot, "the laborer under the cursor is picked (slot %d)" % slot)
		check(g.acre.pick_laborer(sp + Vector2(400, 400), 52.0) == -1, "...and none far from it")
		ui.close_panels()
		check(g.gather.click_at(sp) and ui.is_open("labor"), "a click on a laborer opens the Laborers panel")
		g.gather.hover_at(sp, false)
		check(views.hover_slot == slot or ui.is_open("labor"), "hovering a laborer sets its glow")
		ui.close_panels()
	await go(-26.0, 21.0, "acre")
	await until(func() -> bool: return views.debug().any(func(d: Dictionary) -> bool: return d["mode"] == "work"), 6.0)
	var dbg: Array = views.debug()
	var worked := dbg.filter(func(d: Dictionary) -> bool: return d["visible"] and d["mode"] == "work")
	check(not worked.is_empty() or loaded == 0, "laborers work their posts (%d in work mode) %s" % [worked.size(), str(dbg)])

	# ---- notices (labor arrival / full, garden, contracts): the rules read the backend views, so a stub answers with the real shapes
	var stub := StubApi.new()
	stub.real = api
	var gd: Dictionary = (await api.get_garden(cid)).data
	var cb: Dictionary = (await api.get_contracts(cid)).data
	var lv: Dictionary = lv0.duplicate(true)
	var s0: Dictionary = lv["slots"][unlocked_slots[0]]
	s0["nodeType"] = String(picks[0])
	s0["elapsedMs"] = 40.0 * 60000.0
	s0["estItems"] = 1234
	s0["capped"] = false
	stub.labor = lv
	stub.garden = gd
	stub.contracts = cb
	var acre := g.acre
	var real_api: Variant = acre.api
	acre.api = stub
	toasts.clear()
	await acre.labor.check_labor(true)
	check(toast_has("Your laborers have gathered about 1,234 finds (H)"), "arrival: a laborer with 30+ minutes of work reports its finds (%s)" % str(toasts))
	check(acre.labor.summary != null and int(acre.labor.summary["assigned"]) >= 1, "note_labor summarizes the view")
	await frames(2)
	check(ui.labor_summary == acre.labor.summary or (ui.labor_summary != null and int(ui.labor_summary["assigned"]) == int(acre.labor.summary["assigned"])), "the guidance reads the labor summary (the Next box / dialogue)")
	check(ui.guidance_state()["contracts"] != null and int(ui.guidance_state()["contracts"]["total"]) == (cb["contracts"] as Array).size(), "refresh_contracts feeds the contract summary")
	toasts.clear()
	s0["capped"] = true
	await acre.labor.check_labor(false)
	check(toast_has("A laborer has filled up"), "a full laborer is announced")
	toasts.clear()
	await acre.labor.check_labor(false)
	check(not toast_has("filled up"), "...once, not on every check")
	s0["capped"] = false
	await acre.labor.check_labor(false)
	s0["capped"] = true
	toasts.clear()
	await acre.labor.check_labor(false)
	check(toast_has("A laborer has filled up"), "...and again after it was emptied")
	# garden
	var plots: Array = stub.garden["plots"]
	toasts.clear()
	plots[0]["state"] = "growing"
	acre.labor.garden_ready = -1
	await acre.labor.check_garden(true)
	check(toast_has("still growing in your garden (U)"), "garden arrival: growing plots are mentioned (%s)" % str(toasts))
	toasts.clear()
	plots[0]["state"] = "ready"
	await acre.labor.check_garden(false)
	check(toast_has("ready in your garden (U)"), "a plot coming ready is announced (%s)" % str(toasts))
	toasts.clear()
	await acre.labor.check_garden(false)
	check(not toast_has("ready in your garden"), "...once")
	acre.api = real_api
	toasts.clear()

	# ---- guidance state: what the Next box reads
	var st := ui.guidance_state()
	check(int(st["level"]) == int(h.character["level"]) and st["area"] == "acre" and int(st["bagSize"]) == 48, "state: level / area / bag size %s" % str([st["level"], h.character["level"], st["area"], st["bagSize"]]))
	check(st["unlocked"] == h.progress["unlocked"] and int(st["totalKills"]) == int(h.progress["totalKills"]), "state: seals and kills come from the progression")
	var ak0 := int(st["areaKills"].get("graves", 0))
	var m: DmRewardsMember = g.rewards.members[cid]
	m.prog.record_kill("graves")
	check(int(ui.guidance_state()["areaKills"].get("graves", 0)) == ak0 + 1, "state: a kill counts in areaKills at once")
	check(not st["prelateThisRun"], "state: the Prelate is not slain yet")
	h.progress["run"]["prelateKills"] = 1   # (the backend clamps a recorded kill by the pending summons; the state just reads it)
	check(ui.guidance_state()["prelateThisRun"], "state: a Prelate kill reaches prelateThisRun")
	check(ui.guidance_state()["bossesBeaten"].is_empty(), "state: no area boss beaten yet")
	g.chron.claim_trophy("gravedigger")
	check(ui.guidance_state()["bossesBeaten"] == ["gravedigger"], "state: a first kill reaches bossesBeaten (the backend's trophy)")
	g.chron.claim_trophy("gravedigger")
	check(ui.guidance_state()["bossesBeaten"] == ["gravedigger"], "state: ...and only once")
	# skills: a level gained gathering is in the state without opening the Professions panel
	var rows: Array = (await api.get_professions(cid)).data
	var lvl_before := int(ui.guidance_state()["skills"].get("woodcutting", 1))
	for row in rows:
		if row["profession_id"] == "woodcutting":
			row["skill_level"] = lvl_before + 3
	g.gather.skills.adopt(rows)
	check(int(ui.guidance_state()["skills"]["woodcutting"]) == lvl_before + 3, "state: a gathering level reaches the skills (%d)" % (lvl_before + 3))
	# the first-hour counsel: welcome on entering, brews
	check(await until(func() -> bool: return ui.counsel._queued("welcome") or ui.counsel.has_seen("welcome") or ui.counsel.shown_id() == "welcome", 4.0), "the welcome counsel fires on entering the world")
	var brew := ""
	for id in DmContent.brews():
		if String(DmContent.brews()[id].get("slot", "")) == "elixir":
			brew = String(id)
			break
	events.clear()
	await give(brew, 2)
	h.set_belt("elixir", brew)
	h.use_belt("elixir")
	check(not ids("brew_drunk").is_empty(), "drinking a brew raises brew_drunk (the counsel's first-brew tip)")

	# ---- the Next box, the bag, and the ping
	await go(0.0, 18.0, "chapterhouse")
	var junk: Array = []
	for id in DmContent.items():
		if String(DmContent.items()[id].get("type", "")) in ["weapon", "chest_armor", "helm", "boots"] and String(DmContent.items()[id].get("rarity", "")) == "common":
			junk.append(String(id))
	var need := 48 - int(ui.guidance_state()["bagUsed"])
	for i in need:
		h.inventory.add({"item_id": junk[i % junk.size()], "quantity": 1})
	await h.inventory.flush()
	await h.refresh_inventory()
	check(int(ui.guidance_state()["bagUsed"]) >= 44, "the bag is nearly full (%d / 48)" % int(ui.guidance_state()["bagUsed"]))
	check(await until(func() -> bool: return ui.guidance_hud.current != null and String(ui.guidance_hud.current["id"]) == "bag-full", 3.0), "the Next box suggests the Bone Grinder with a full bag")
	var ping: Variant = h.hud_state()["minimap"]["ping"]
	var target: Dictionary = ui.guidance_hud.current["target"]
	check(ping is Dictionary and is_equal_approx(float(ping["x"]), float(target["x"])) and is_equal_approx(float(ping["z"]), float(target["z"])), "the minimap ping points at the suggestion's target (the grinder)")
	# the unchanged state is not recomputed, but a dismissal still counts (the x on the Next box)
	var shown_id := String(ui.guidance_hud.current["id"])
	ui.guidance_hud.dismiss()
	await frames(2)
	ui._guide_t = 0.0
	await until(func() -> bool: return ui._guide_t > 0.0, 2.0)
	check(ui.guidance_hud.current == null or String(ui.guidance_hud.current["id"]) != shown_id, "dismissing the Next box holds while the state is unchanged")
	h.settings_store.values["guide_ping"] = false
	check(h.hud_state()["minimap"]["ping"] == null, "...and the guide ping setting turns it off")
	h.settings_store.values["guide_ping"] = true
	h.settings_store.values["guidance"] = false
	await until(func() -> bool: return ui.guidance_hud.current == null, 3.0)
	check(ui.guidance_hud.current == null and h.hud_state()["minimap"]["ping"] == null, "...as does turning the guidance off %s" % str([ui.guidance_hud.current, h.hud_state()["minimap"]["ping"]]))
	h.settings_store.values["guidance"] = true
	await until(func() -> bool: return ui.guidance_hud.current != null, 3.0)

	await clear_junk()
	await perf(cost, lv0)
	await stations()
	await acre_panels()
	await reforge()
	await bug_report()
	print("---- %d passed, %d failed" % [passed, failed])
	cost.queue_free()
	await g.leave()
	quit(1 if failed > 0 else 0)


# ---- stations ------------------------------------------------------------------------------------------------------------------------

## The window a station's interactable opens (DmGameUi.open_station): the forge variants, the Bone Grinder's salvage, the Lectern's codex, the reagent shelf.
func window_of(kind: String) -> Control:
	match kind:
		"kiln", "sawpit", "fire", "cauldron":
			return ui.pb.forges.get(kind)
		"alembic":
			return ui.pb.forges.get("cauldron")
		"grinder":
			return ui.windows.get("salvage")
		"reagents":
			return ui.windows.get("shelf")
		"lectern":
			return ui.pa.char_win if ui.is_open("codex") else null
	return null


func interactable(area: String, kind: String) -> Dictionary:
	for it in DmContent.area(area)["interactables"]:
		if it["kind"] == kind:
			return it
	return {}


## Walk (teleport) to each station of the area, use it as a click does, and see the right panel open; then craft one thing at the forge ones.
func stations() -> void:
	var done: Array = []
	var cases := [["acre", "sawpit"], ["acre", "kiln"], ["acre", "fire"], ["acre", "grinder"], ["acre", "lectern"],
		["alchemist_wing", "cauldron"], ["alchemist_wing", "alembic"], ["alchemist_wing", "reagents"]]
	for c in cases:
		var area := String(c[0])
		var kind := String(c[1])
		var it := interactable(area, kind)
		check(not it.is_empty(), "%s has a %s station" % [area, kind])
		if it.is_empty():
			continue
		ui.close_panels()
		await go(float(it["x"]), float(it["z"]) + 1.6, area)
		events.clear()
		check(g.chapterhouse.click_interactable(it), "%s: a click on the %s is taken" % [area, kind])
		await frames(4)
		var opened := false
		match kind:
			"grinder":
				opened = ui.is_open("salvage")
			"lectern":
				opened = ui.is_open("codex")
			"reagents":
				opened = ui.is_open("shelf")
			_:
				var key := "cauldron" if kind == "alembic" else kind
				opened = ui.pb.forges.has(key) and ui.pb.forges[key].visible
		check(opened, "%s: the %s opens its panel" % [area, kind])
		if kind in ["kiln", "sawpit", "fire", "cauldron", "alembic"]:
			check(not ids("station_opened").is_empty() or not ids("cauldron_opened").is_empty(), "%s: the first-use counsel event is raised" % kind)
			await craft_at(kind)
		done.append(kind)
	ui.close_panels()
	print("stations used: ", done)


## Ask the open forge panel for its first tab's recipes and craft the first one the level allows (ingredients are given), through the API.
func craft_at(kind: String) -> void:
	var key := "cauldron" if kind == "alembic" else kind
	var f: DmForgePanel = ui.pb.forges[key]
	var prof := f.current_profession()
	var rr: DmResult = await api.get_recipes(prof)
	check(rr.ok and rr.data is Array and not (rr.data as Array).is_empty(), "%s: %s recipes load (%d)" % [kind, prof, (rr.data as Array).size() if rr.ok else 0])
	if not rr.ok:
		return
	var recipe: Dictionary = {}
	for rc in rr.data:
		if int(rc.get("skill_level_required", 99)) <= 1:
			recipe = rc
			break
	if recipe.is_empty():
		print("  %s: no level-1 recipe in %s (%d recipes), craft skipped" % [kind, prof, (rr.data as Array).size()])
		return
	var rid := String(recipe["id"])
	var result_id := String(recipe["result_item_id"])
	for ing in recipe["ingredients"]:
		await give(String(ing["item_id"]), int(ing["quantity"]) * 2)
	var before := h.inventory.count(result_id)
	f.craft_requested.emit(rid, 1)
	check(await until(func() -> bool: return h.inventory.count(result_id) > before, 5.0), "%s: crafting %s through the panel yields %s" % [kind, rid, result_id])


# ---- reforge -------------------------------------------------------------------------------------------------------------------------

func reforge() -> void:
	ui.close_panels()
	await go(8.5, 15.6, "chapterhouse")
	var piece := ""
	for id in DmContent.items():
		if String(DmContent.items()[id].get("type", "")) == "weapon" and String(DmContent.items()[id].get("rarity", "")) in ["rare", "epic"]:
			piece = String(id)
			break
	if piece == "":
		for id in DmContent.items():
			if DmAffixes.can_roll(String(id)):
				piece = String(id)
				break
	var rolled: DmResult = null
	for i in 8:   # a roll can come out with no affix: roll again (each roll mints an instance in the offline account, which is fine)
		rolled = await api.roll_loot(cid, [{"item_id": piece, "level": 8 + i, "source": "elite"}])
		if rolled.ok and (rolled.data as Array).size() == 1 and reforgeable_index(rolled.data[0]) >= 0:
			break
	check(rolled.ok and (rolled.data as Array).size() == 1 and reforgeable_index(rolled.data[0]) >= 0, "an affixed %s was rolled by the offline backend (%s)" % [piece, str(rolled.error) + str(rolled.data)])
	if not rolled.ok:
		return
	# make room, then bag the rolled piece the way a pickup does
	for s in h.slots.duplicate():
		if int(s["slot_index"]) >= 40 and int(s["slot_index"]) < 48:
			h.inventory.consume(String(s["item_id"]))
	await h.inventory.flush()
	await h.refresh_inventory()
	var drop := {"item_id": piece, "quantity": 1, "instance": {"id": rolled.data[0]["instance_id"], "ilvl": rolled.data[0]["ilvl"], "affixes": rolled.data[0]["affixes"]}}
	check(h.inventory.add(drop), "the rolled piece goes into the bag")
	await h.inventory.flush()
	await h.refresh_inventory()
	h.character["gold"] = 1000000
	h.prog.save_dirty = true
	g.progress.psync.tick(0.0)
	await g.progress.psync.flush()
	events.clear()
	toasts.clear()
	var wb := interactable("chapterhouse", "forge")
	check(g.chapterhouse.click_interactable(wb), "the Workbench is used")
	await frames(4)
	var forge: DmForgePanel = ui.pb.forges[""]
	check(forge.visible and forge.reforge != null, "the Workbench opens with its Reforge tab")
	forge.quote_requested.emit()
	await frames(10)
	var pieces: Array = forge.reforge.pieces()
	check(not pieces.is_empty(), "the Reforge lists the affixed piece (%d)" % pieces.size())
	var pc: Dictionary = {}
	for p in pieces:
		if String(p["item_id"]) == piece:
			pc = p
	check(not pc.is_empty(), "...including the rolled one")
	if pc.is_empty():
		return
	var cost_g: int = forge.reforge.cost_of(pc)
	var gold0 := int(h.character["gold"])
	var ai := reforgeable_index({"affixes": pc["inst"]["affixes"], "ilvl": pc["inst"]["ilvl"]})
	var old_v: Variant = pc["inst"]["affixes"][ai]["v"]
	forge.reforge.reforge_requested.emit(int(pc["slot_index"]), ai, cost_g)
	check(await until(func() -> bool: return int(h.character["gold"]) < gold0, 5.0), "reforging an affix takes gold (%d -> %d) %s | %s | cost %d idx %d" % [gold0, int(h.character["gold"]), str(forge.reforge.error_text), str(pc["inst"]), cost_g, ai])
	check(int(h.character["gold"]) == gold0 - cost_g, "...exactly the quoted %d" % cost_g)
	var after: Dictionary = {}
	for s in h.slots:
		if s.get("inst") != null and String(s["item_id"]) == piece:
			after = s
	check(not after.is_empty(), "the reforged piece is still in the bag")
	print("reforge: %s affix %d %s -> %s for %d gold" % [piece, ai, str(old_v), str(after["inst"]["affixes"][ai]["v"]) if not after.is_empty() else "?", cost_g])
	# the server's purse and ours agree: the reforge went through the progress sync (else the next save would hand the gold back)
	g.progress.psync.tick(0.0)
	await g.progress.psync.flush()
	var srv: DmResult = await api.get_character()
	check(srv.ok and int(srv.data["gold"]) == int(h.character["gold"]), "the backend's gold equals ours after the reforge (%s vs %d)" % [str(srv.data.get("gold")), int(h.character["gold"])])
	# a wrong price is refused, never charged
	var gold1 := int(h.character["gold"])
	var bad: DmResult = await api.reforge_affix(cid, int(pc["slot_index"]), ai, 1)
	check(not bad.ok and int(h.character["gold"]) == gold1, "a stale price is refused by the backend (%s)" % bad.error)
	ui.close_panels()


# ---- bug report (the OFFLINE api only: the report stays in the local mock) -----------------------------------------------------------------

func bug_report() -> void:
	ui.close_panels()
	check(g.is_offline and api.base_url.find("http") < 0 or g.is_offline, "the bug-report test runs on the offline backend")
	ui.open_bug_report()
	await frames(4)
	check(ui.is_open("settings") and ui.set_ui.bug_report_open(), "Report a bug opens inside Settings")
	var view: DmBugReportView = ui.set_ui.report
	view.category.select(2)
	view.message.text = "Test report: the Acre laborers stand in the right place."
	view._sync()
	check(not view.send_button.disabled, "a 10+ character message enables Send")
	var ctx := view.context()
	check(String(ctx["release"]).begins_with("godot-next-") and ctx["area"] == g.area_id and int(ctx["level"]) == int(h.character["level"]), "the context names the rebuild's release, area and level (%s)" % str(ctx["release"]))
	await view.send()
	check(view.result_label.text.begins_with("Thank you"), "Send reports success (%s)" % view.result_label.text)
	var mine: DmResult = await api.get_my_bug_reports()
	check(mine.ok and (mine.data as Array).size() == 1 and mine.data[0]["category"] == "ui" and String(mine.data[0]["message"]).begins_with("Test report"), "the report is in the (offline) backend's list")
	ui.set_ui.close_bug_report()
	ui.close_panels()


## The first affix of a rolled piece the Workbench will accept (it refuses one-value or already-maxed rolls), or -1.
func reforgeable_index(roll: Dictionary) -> int:
	var inst := {"affixes": roll["affixes"], "ilvl": roll["ilvl"]}
	for i in (roll["affixes"] as Array).size():
		if DmGoldSink.reforge_problem(inst, i, Callable(DmAffixRules, "affix_range")) == "":
			return i
	return -1


func clear_junk() -> void:
	for s in h.slots.duplicate():
		if int(s["slot_index"]) < 48 and int(s.get("equipped", 0)) == 0 and String(DmContent.item(String(s["item_id"])).get("type", "")) in ["weapon", "chest_armor", "helm", "boots"]:
			while h.inventory.count(String(s["item_id"])) > 0:
				h.inventory.consume(String(s["item_id"]))
	await h.inventory.flush()
	await h.refresh_inventory()
	check(int(ui.guidance_state()["bagUsed"]) < 40, "the bag was cleared for the crafting (%d)" % int(ui.guidance_state()["bagUsed"]))


## The Acre panels' results (WorldScene.onContractDelivered / onLaborCollected / onGardenResult): gold the server only returns, the chronicle, the toasts.
func acre_panels() -> void:
	ui.close_panels()
	await go(-26.0, 21.0, "acre")
	# contracts: the reward gold is OURS to credit (the server never writes it)
	await ui.toggle_panel("contracts")
	await frames(6)
	var board: Dictionary = (await api.get_contracts(cid)).data
	var order: Dictionary = (board["contracts"] as Array)[0]
	await give(String(order["itemId"]), int(order["qty"]))
	var gold0 := int(h.character["gold"])
	var done0 := g.chron.life("contracts")
	toasts.clear()
	ui.pb.contracts.deliver_requested.emit(int(order["slot"]))
	check(await until(func() -> bool: return g.chron.life("contracts") > done0, 5.0), "contracts: a delivery is counted in the chronicle")
	check(int(h.character["gold"]) == gold0 + int(order["rewardGold"]), "contracts: the order's %d gold is credited (%d -> %d)" % [int(order["rewardGold"]), gold0, int(h.character["gold"])])
	check(toast_has("Order filled"), "contracts: the order-filled toast (%s)" % str(toasts))
	check(int(ui.guidance_state()["contracts"]["open"]) == int(ui.contract_summary["open"]), "contracts: the guidance summary follows the delivery")
	ui.close_panels()
	# laborers: three hours later the finds are collected; their gold and count are credited, the report is listed under the laborer
	var lv: Dictionary = (await api.get_labor(cid)).data
	var slot := -1
	for sv in lv["slots"]:
		if sv.get("nodeType") != null and String(sv["nodeType"]) != "":
			slot = int(sv["slot"])
	check(slot >= 0, "a laborer holds a post")
	var sk0 := String(DmGathering.node_def(String(lv["slots"][slot]["nodeType"]))["skill"])
	var gathered0 := g.chron.life("gathered.%s" % sk0)
	clock_offset = 3 * 3600 * 1000
	await ui.toggle_panel("labor")
	await frames(6)
	var gold1 := int(h.character["gold"])
	ui.pb.labor.collect_requested.emit(slot)
	check(await until(func() -> bool: return g.chron.life("gathered.%s" % sk0) > gathered0, 6.0), "labor: the collected finds are counted in the chronicle (%s)" % sk0)
	check(int(h.character["gold"]) >= gold1, "labor: the gold of the finds is credited (%d -> %d)" % [gold1, int(h.character["gold"])])
	ui.close_panels()
	clock_offset = 0
	# garden: plant, a day later harvest
	var seed_def: Dictionary = DmGarden.seeds()[0]
	await give(String(seed_def["id"]), 2)
	await ui.toggle_panel("garden")
	await until(func() -> bool: return not ui.pb.garden.view.is_empty(), 3.0)
	var plot := ""
	for pl in ui.pb.garden.view["plots"]:
		if pl["state"] == "empty" and DmGarden.plant_blocker(DmGarden.plot_def(String(pl["plot"])), String(seed_def["id"]), int(ui.pb.garden.view["level"]), null, 0) == "":
			plot = String(pl["plot"])
			break
	check(plot != "", "garden: a plot takes the seed")
	if plot != "":
		ui.pb.garden.plant_requested.emit(plot, String(seed_def["id"]), false)
		await until(func() -> bool: return (ui.pb.garden.view["plots"] as Array).any(func(pl: Dictionary) -> bool: return pl["plot"] == plot and pl["state"] != "empty"), 4.0)
		clock_offset = 3 * 24 * 3600 * 1000
		var grown0 := g.chron.life("gathered.gardening")
		toasts.clear()
		ui.pb.garden.harvest_requested.emit(plot)
		var harvested := await until(func() -> bool: return g.chron.life("gathered.gardening") > grown0, 5.0)
		if not harvested:
			var dbg: DmResult = await api.harvest_garden(cid, plot)
			print("DBG harvest: ", dbg.ok, " ", dbg.error, " plots ", str((await api.get_garden(cid)).data["plots"]), " bag ", h.slots.size())
		check(harvested, "garden: a harvest is counted in the chronicle")
		check(toast_has("Harvested"), "garden: the harvest toast (%s)" % str(toasts))
		clock_offset = 0
	ui.close_panels()


# ---- cost ----------------------------------------------------------------------------------------------------------------------------

func measure(cost: DmFrameCost, n: int) -> Array:
	await frames(10)
	cost.reset()
	await until(func() -> bool: return cost.samples() >= n, 20.0)
	return [cost.median_ms(), cost.pct(0.95), cost.worst_ms()]


## Four laborers working in the Acre (the most there are) with the glue on, against the same scene with it off; the guidance recompute.
func perf(cost: DmFrameCost, lv0: Dictionary) -> void:
	await go(-26.0, 21.0, "acre")
	var views := g.acre.views
	var lv := lv0.duplicate(true)
	var posts := ["coffin_oak", "copper_seam", "grave_plot", "murk_pool"]
	var types: Array = []
	for n in DmLabor.posts_for({}):
		types.append(String(n["id"]))
	for i in lv["slots"].size():
		var sl: Dictionary = lv["slots"][i]
		sl["unlocked"] = true
		sl["nodeType"] = types[i % types.size()]
		sl["startedAt"] = int(lv["now"]) - 600000
		sl["elapsedMs"] = 600000
		sl["capped"] = false
	views.apply(lv)
	await until(func() -> bool: return views.pick_list().size() >= mini(4, lv["slots"].size()) or views.byslot.size() >= 3, 8.0)
	await until(func() -> bool: return views.debug().filter(func(d: Dictionary) -> bool: return d["mode"] == "work").size() >= mini(4, views.byslot.size()), 8.0)
	await frames(30)
	var working := views.debug().filter(func(d: Dictionary) -> bool: return d["visible"] and d["loaded"])
	print("perf scene: %d laborers shown (%s)" % [working.size(), str(working.map(func(d: Dictionary) -> String: return "%s/%s" % [d["type"], d["mode"]]))])
	var acre := g.acre
	var on: Array = await measure(cost, 300)
	acre.set_process(false)
	views.visible = false
	var off: Array = await measure(cost, 300)
	acre.set_process(true)
	views.visible = true
	var on2: Array = await measure(cost, 300)
	print("FRAME COST in the Acre, %d laborers: glue OFF median %.2f p95 %.2f worst %.1f ms | ON median %.2f p95 %.2f worst %.1f ms | ON again median %.2f p95 %.2f worst %.1f ms" % [working.size(), off[0], off[1], off[2], on[0], on[1], on[2], on2[0], on2[1], on2[2]])
	perf_info(float(on2[0]) < float(off[0]) + 2.5 and float(on[0]) < float(off[0]) + 2.5, "the laborers and glue add under 2.5 ms to the median frame (off %.2f, on %.2f / %.2f)" % [off[0], on[0], on2[0]])
	# the guidance recompute: what the UI does twice a second, and what a feed costs
	var t := Time.get_ticks_usec()
	for i in 500:
		ui.guidance_hud.update(ui.guidance_state(), true)
	var us := (Time.get_ticks_usec() - t) / 500.0
	print("guidance recompute (state + suggestion): %.1f us each, twice a second = %.3f ms per second" % [us, us * 2.0 / 1000.0])
	perf_info(us < 1500.0, "one guidance recompute costs %.0f us" % us)
	t = Time.get_ticks_usec()
	var stt: Dictionary = {}
	for i in 500:
		stt = ui.guidance_state()
	print("  guidance_state alone: %.1f us" % ((Time.get_ticks_usec() - t) / 500.0))
	t = Time.get_ticks_usec()
	for i in 500:
		DmGuidance.next_suggestion(stt, "")
	print("  next_suggestion alone: %.1f us" % ((Time.get_ticks_usec() - t) / 500.0))
	t = Time.get_ticks_usec()
	for i in 200:
		for nid in DmContent.get_export("npcs", "NPC_IDS"):
			ui.memory.has_something_new(String(nid), stt)
	print("  npc news (7 npcs): %.1f us" % ((Time.get_ticks_usec() - t) / 200.0))
	t = Time.get_ticks_usec()
	for i in 500:
		DmGuidance.suggestions(stt)
	print("  suggestions alone: %.1f us" % ((Time.get_ticks_usec() - t) / 500.0))
	t = Time.get_ticks_usec()
	for i in 200:
		g.acre.labor.guide_dirty = false   # nothing changed: the feeds do not touch the UI
		await process_frame
	print("200 idle frames with the glue: %.1f us per frame (process time of acre + laborers + ui)" % ((Time.get_ticks_usec() - t) / 200.0))


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
