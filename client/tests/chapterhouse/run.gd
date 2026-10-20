extends SceneTree
## Chapterhouse suite (client/next/chapterhouse): NPCs, stations, waystone travel / recall, seals, prompts, idle cost, on the offline backend.
## godot --headless --path client --script res://tests/chapterhouse/run.gd

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var h: DmChapterhouse
var api: DmApi
var mock: DmMockBackend
var character: Dictionary
var events: Array = []
var stations: Array = []


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


func ev(id: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == id)


func at(x: float, z: float) -> void:
	g.local_body().teleport(Vector3(x, 0.0, z))


func interactable(id: String) -> Dictionary:
	for it in h.interactables:
		if it["id"] == id:
			return it
	return {}


## Ticks the hub as the frame loop would (the 10 Hz tick + the 5 Hz NPC refresh), without waiting for real frames.
func settle() -> void:
	h._npc_acc = 1.0
	h._tick(0.1)


func _run() -> void:
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var uname := "ch%d" % (Time.get_ticks_usec() % 100000)
	var r := await api.register(uname, "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"dressing": false, "persist": false, "waves": false, "hud": true, "audio": false})
	h = g.chapterhouse
	check(h != null and g.ui != null and g.ui_host != null, "boots with the Chapterhouse node and the real HUD")
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	g.ui_host.station_interact.connect(func(id: String) -> void: stations.append(id))
	var b := g.local_body()
	var prior := interactable("npc_prior")
	check(not prior.is_empty() and interactable("reliquary")["area"] == "chapterhouse", "interactables come from the content (areas.json): %d" % h.interactables.size())

	# ---- NPCs: present with their models and plates, talkable with the existing dialogue
	var ids: Array = DmContent.get_export("npcs", "NPC_IDS")
	var spots: Dictionary = DmContent.get_export("npcs", "NPCS")
	check(not ids.is_empty() and h.npcs.npcs.size() == ids.size(), "every NPC of the data is in the hub (%s)" % [ids])
	var prior_x := float(spots["prior"]["x"])   # where the Prior stands
	var prior_z := float(spots["prior"]["z"])
	var prior_name := String(spots["prior"]["name"])
	for id in ids:
		var n: Dictionary = h.npcs.npcs[id]
		var def: Dictionary = spots[id]
		check(n["c"] != null and n["c"].loaded, "%s: model loaded at start (never mid-play)" % id)
		check((n["plate"] as Label3D).text == "%s\n%s" % [String(def["name"]).to_upper(), def["title"]], "%s: nameplate '%s'" % [id, def["name"]])
		check(((n["root"] as Node3D).position - Vector3(float(def["x"]), 0.0, float(def["z"]))).length() < 0.01, "%s: stands at its spot" % id)
		# the E key: only within talk range
		at(float(def["x"]), float(def["z"]) - 6.0)
		check(h.nearest_npc() == "", "%s: out of talk range, E does nothing" % id)
		h.talk_key()
		check(not g.ui.dialogue.visible, "%s: E far away opens nothing" % id)
		at(float(def["x"]), float(def["z"]) - 2.0)
		check(h.nearest_npc() == id, "%s: nearest within range" % id)
		var expect: String = g.ui.dialogue.source.greeting_lines(id)[0]
		events.clear()
		h.talk_key()
		check(g.ui.dialogue.visible and g.ui.dialogue.npc == id, "%s: E opens the dialogue" % id)
		check(String(g.ui.dialogue.lines[0]) == expect and expect != "", "%s: first line is the covenant greeting" % id)
		check(g.ui.memory.met(id), "%s: the guidance memory marks them met (counsel hook)" % id)
		h.talk_key()
		check(not g.ui.dialogue.visible, "%s: E again closes it" % id)
	check(String(g.ui.dialogue.source.greeting_lines("prior")[0]).length() > 0, "prior greeting follows the memory afterwards (no crash)")
	# Stand at the Prior first: the hub closes a conversation once the hero is out of talk range (+3.5 m), and the last NPC of the loop above
	# is elsewhere, so whether the check below saw the dialogue still open depended on where the 0.2 s NPC refresh phase fell.
	at(float(spots["prior"]["x"]), float(spots["prior"]["z"]) - 2.0)
	h.talk_to("prior")
	check(String(g.ui.dialogue.lines[0]) != "", "talk_to opens a conversation")
	await ticks(20)
	check(h.talking == "prior" and h.npcs.npcs["prior"]["talking"], "the Prior is told they are talking (turns, talk clip)")
	at(prior_x, prior_z + 30.0)    # walk away: the world closes the conversation past talk range + 3.5
	await until(func() -> bool: return not g.ui.dialogue.visible, 2.0)
	check(not g.ui.dialogue.visible and h.talking == "", "walking away closes the dialogue")
	# a click on an NPC walks over and talks
	at(prior_x, prior_z - 8.0)
	g.ui.close_panels()
	h.click_interactable(prior)
	check(h.pending == prior, "clicking an NPC queues the interaction")
	at(prior_x, prior_z - 1.4)
	await until(func() -> bool: return g.ui.dialogue.visible, 1.5)
	check(g.ui.dialogue.visible and g.ui.dialogue.npc == "prior" and h.pending == null, "arriving within range talks")
	g.ui.close_panels()

	# ---- stations: each opens its existing panel
	var checks := [
		["reliquary", "reliquary", func() -> bool: return g.ui.is_open("inventory")],
		["workbench", "workbench", func() -> bool: return g.ui.pb.forges.has("") and g.ui.pb.forges[""].visible],
		["altar", "altar", func() -> bool: return g.ui.is_open("ascension")],
		["ossuary_vault", "vault", func() -> bool: return g.ui.pb.vault.window.visible],
		["waystone_chapterhouse", "waystone", func() -> bool: return g.ui.is_open("map")],
		["niches", "professions", func() -> bool: return g.ui.pa.acre_win.visible],
		["bone_kiln", "kiln", func() -> bool: return g.ui.pb.forges.has("kiln") and g.ui.pb.forges["kiln"].visible],
		["sawpit", "sawpit", func() -> bool: return g.ui.pb.forges.has("sawpit") and g.ui.pb.forges["sawpit"].visible],
		["cooking_fire", "fire", func() -> bool: return g.ui.pb.forges.has("fire") and g.ui.pb.forges["fire"].visible],
		["wing_cauldron", "cauldron", func() -> bool: return g.ui.pb.forges.has("cauldron") and g.ui.pb.forges["cauldron"].visible],
		["wing_alembic", "alembic", func() -> bool: return g.ui.pb.forges.has("cauldron") and g.ui.pb.forges["cauldron"].visible],   # (the alembic is the cauldron's window)
		["bone_grinder", "grinder", func() -> bool: return g.ui.is_open("salvage")],
		["wing_reagent_shelf", "shelf", func() -> bool: return g.ui.is_open("shelf")],
		["lectern", "lectern", func() -> bool: return g.ui.is_open("codex")],
	]
	for row in checks:
		var it := interactable(row[0])
		g.ui.close_panels()
		stations.clear()
		await ticks(1)
		at(float(it["x"]), float(it["z"]) + 1.4)
		h.click_interactable(it)
		await ticks(3)
		check(stations.has(row[1]), "%s: station_interact('%s') emitted (%s)" % [row[0], row[1], stations])
		check(await until(row[2], 2.0), "%s: its panel is open" % row[0])
	g.ui.close_panels()
	check(not ev("cauldron_opened").is_empty() and not ev("station_opened").is_empty() and not ev("lectern_used").is_empty(), "station counsel events fire (cauldron / station / lectern)")
	check(h.interactables.any(func(i: Dictionary) -> bool: return i["kind"] == "boss") and not h.interactables.is_empty(), "boss altars are listed (the bosses track hooks `interacted`)")
	var boss_it: Dictionary = {}
	for it in h.interactables:
		if it["kind"] == "boss":
			boss_it = it
	var heard: Array = []
	h.interacted.connect(func(it: Dictionary) -> void: heard.append(it["id"]))
	h.interact(boss_it)
	check(heard == [boss_it["id"]], "a boss altar is passed to `interacted` (not handled by the hub)")

	# ---- Reliquary: the bag works through the real panel
	var reliq := interactable("reliquary")
	at(float(reliq["x"]), float(reliq["z"]) + 1.4)
	h.interact(reliq)
	await ticks(2)
	check(g.ui.is_open("inventory") and g.ui_host.slots.size() >= 2, "Reliquary shows the bag (%d slots)" % g.ui_host.slots.size())
	g.ui.close_panels()

	# ---- Vault: deposit then take through the panel -> DmApi (offline backend)
	var vault_it := interactable("ossuary_vault")
	at(float(vault_it["x"]), float(vault_it["z"]) + 1.4)
	h.interact(vault_it)
	await ticks(5)
	var cid: int = int(character["id"])
	var bag_before := g.ui_host.slots.size()
	g.ui.pb.vault.deposit_requested.emit(0)    # slot 0: the Oak Staff
	await until(func() -> bool: return g.ui_host.slots.size() < bag_before, 3.0)
	check(g.ui_host.slots.size() == bag_before - 1, "vault deposit takes the staff out of the bag (%d -> %d)" % [bag_before, g.ui_host.slots.size()])
	var vr := await api.get_vault(cid)
	var vslots: Array = vr.data.get("slots", vr.data.get("vault", [])) if vr.data is Dictionary else []
	check(vr.ok and JSON.stringify(vr.data).find("staff_oak") >= 0, "the backend vault holds it")
	var vault_slot := 0
	if vslots.size() > 0:
		vault_slot = int((vslots[0] as Dictionary).get("slot_index", 0))
	g.ui.pb.vault.withdraw_requested.emit(vault_slot)
	await until(func() -> bool: return g.ui_host.slots.size() == bag_before, 3.0)
	check(g.ui_host.slots.size() == bag_before and g.ui_host.slots.any(func(s: Dictionary) -> bool: return s["item_id"] == "staff_oak"), "vault take returns it to the bag")
	g.ui.close_panels()

	# ---- Workbench: craft refusal and success, reforge refusal
	var wb := interactable("workbench")
	at(float(wb["x"]), float(wb["z"]) + 1.4)
	h.interact(wb)
	await ticks(5)
	var fp: DmForgePanel = g.ui.pb.forges[""]
	var recipe: Dictionary = {}
	for rr in mock._recipes():
		if int(rr["skill_level_required"]) <= 1 and (recipe.is_empty() or (rr["ingredients"] as Array).size() < (recipe["ingredients"] as Array).size()):
			recipe = rr
	check(not recipe.is_empty(), "a level-1 recipe exists (%s)" % recipe.get("id", "?"))
	fp.craft_requested.emit(recipe["id"], 1)
	await until(func() -> bool: return not fp.busy and fp.errors.get(fp.active, "") != "", 3.0)
	check(String(fp.errors.get(fp.active, "")).find("not enough") >= 0, "craft without materials is refused: '%s'" % fp.errors.get(fp.active, ""))
	var acc: Dictionary = mock.db["accounts"][uname]
	for ing in recipe["ingredients"]:
		mock._grant(acc, ing["item_id"], int(ing["quantity"]))
	await g.ui_host.refresh_inventory()
	var have_before := g.ui_host.inventory.count(recipe["result_item_id"])
	fp.craft_requested.emit(recipe["id"], 1)
	await until(func() -> bool: return g.ui_host.inventory.count(recipe["result_item_id"]) > have_before, 3.0)
	check(g.ui_host.inventory.count(recipe["result_item_id"]) > have_before, "craft with materials succeeds: %s x%d -> x%d" % [recipe["result_item_id"], have_before, g.ui_host.inventory.count(recipe["result_item_id"])])
	if fp.reforge != null:
		var gold0 := int(mock._gold_now(acc))
		fp.reforge.reforge_requested.emit(0, 0, 0)    # the Oak Staff has no rolled affixes
		await until(func() -> bool: return fp.reforge.result_text != "" or not fp.reforge.busy, 2.0)
		await ticks(5)
		check(int(mock._gold_now(acc)) == gold0, "reforge of an unrolled piece is refused, gold untouched (%d)" % gold0)
	else:
		check(false, "the Workbench has a reforge view")
	g.ui.close_panels()

	# ---- Altar: opens with the backend's state; an ascension attempt before the Prelate is refused by the same API
	var altar := interactable("altar")
	at(float(altar["x"]), float(altar["z"]) + 1.4)
	h.interact(altar)
	await ticks(3)
	check(g.ui.is_open("ascension"), "Altar opens the Ascension panel")
	at(float(altar["x"]) + 2.0, float(altar["z"]) + 1.4)
	settle()
	check(g.ui.is_open("ascension"), "a couple of steps from the Altar its window stays open")
	at(float(altar["x"]) + 8.0, float(altar["z"]) + 1.4)
	settle()
	check(not g.ui.is_open("ascension"), "walking away from the Altar closes its window")
	at(float(altar["x"]), float(altar["z"]) + 1.4)
	h.interact(altar)
	await ticks(3)
	var ar := await api.necro_ascend(cid)
	check(not ar.ok, "ascension is refused until it is earned (same DmApi): '%s'" % ar.error)
	await g.ui_host.refresh_progress()
	check(int(g.ui_host.progress["ascension"]) == 0, "refresh_progress adopts the backend's necro state")
	g.ui.close_panels()

	# ---- waystone travel / recall
	var way_c := interactable("waystone_chapterhouse")
	var way_g := interactable("waystone_graves")
	at(float(way_c["x"]), float(way_c["z"]) + 1.6)
	await ticks(3)
	events.clear()
	h.travel("ossuary")
	check(g.local_body().position.distance_to(Vector3(float(way_c["x"]), 0, float(way_c["z"]) + 1.6)) < 0.5 and not ev("toast").is_empty(), "a locked area (not in the slice) refuses with a toast and does not move")
	h.travel("graves")
	var pos := g.local_body().position
	check(Vector2(pos.x - float(way_g["x"]), pos.z - float(way_g["z"]) - 1.6).length() < 0.5, "travel(graves) puts you at the Graves waystone")
	await until(func() -> bool: return g.area_id == "graves", 2.0)
	check(g.area_id == "graves", "area changes to the Graves")
	at(-5.5, -20.0)
	await ticks(3)
	events.clear()
	h.travel("chapterhouse")
	check(g.local_body().position.z < -10.0 and not ev("toast").is_empty(), "far from a waystone, outside the Chapterhouse: refused")
	at(float(way_g["x"]), float(way_g["z"]) + 1.6)
	h.travel("chapterhouse")
	pos = g.local_body().position
	check(Vector2(pos.x - float(way_c["x"]), pos.z - float(way_c["z"]) - 1.6).length() < 0.5, "waystone to waystone: back in the Chapterhouse")
	await until(func() -> bool: return g.area_id == "chapterhouse", 2.0)
	# recall
	at(-5.5, -20.0)
	await until(func() -> bool: return g.area_id == "graves", 2.0)
	h.start_recall()
	check(h.recall_active, "T starts a recall in the Graves")
	g.input.clicked_move.emit(Vector3(0, 0, -20))
	check(not h.recall_active, "moving cancels the recall")
	h.start_recall()
	var back := await until(func() -> bool:
		h._tick(0.1)
		return not h.recall_active, 4.0)
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	check(back and g.local_body().position.distance_to(Vector3(float(ret["x"]), 0, float(ret["z"]))) < 0.5, "recall brings you to the Chapterhouse return point")
	await until(func() -> bool: return g.area_id == "chapterhouse", 2.0)
	events.clear()
	h.start_recall()
	check(not h.recall_active and g.ui_host != null, "recall in the Chapterhouse is a no-op (float, no timer)")

	# ---- doors and seals
	check(h.door_open("chapter_graves"), "the Chapterhouse <-> Graves door is open")
	check(not h.door_open("graves_warren"), "the Warren door starts sealed")
	var prog := h._prog()
	var need := prog.unlock_kills(float(DmContent.area("warren")["unlock"]["kills"]))
	var seal_area := String(DmContent.area("warren")["unlock"]["area"])
	check(need == int(DmContent.area("warren")["unlock"]["kills"]), "the Warren asks %d kills in %s" % [need, seal_area])
	for i in need - 1:
		prog.record_kill(seal_area)
	events.clear()
	check(h.check_seals().is_empty() and not h.door_open("graves_warren"), "%d kills: the seal holds" % (need - 1))
	prog.record_kill(seal_area)
	g.rewards.member_credited.emit(cid, {"kills": 1})     # an accepted report lands -> the hub checks the seals
	check(h.door_open("graves_warren") and prog.really_unlocked("warren"), "%d kills: the Warren seal breaks and its door opens" % need)
	var banner := ev("banner")
	check(banner.size() == 1 and banner[0]["ctx"]["title"] == "A seal breaks" and String(banner[0]["ctx"]["sub"]).find("Warren") >= 0, "the 'A seal breaks' banner: %s" % [banner.map(func(e: Dictionary) -> Variant: return e["ctx"].get("sub"))])
	check(h.check_seals().is_empty() and ev("banner").size() == 1, "a broken seal is not announced twice")
	check(DmContent.area_order().all(func(a: String) -> bool: return prog.is_unlocked(a) == g.world.unlocked.has(a) or DmContent.area(a).get("instance", false)), "the world's unlocked halls follow the progress")   # the seal state is DmNextWorld's (the builder of today's game held it)
	check(g.world.nav_path(Vector3(-20, 0, -28), Vector3(-45, 0, -28)).size() > 1, "the navmesh runs through the opened Warren door")

	# ---- prompts show / hide by distance, hover prompt
	at(prior_x, prior_z - 1.8)
	settle()
	check(String(h.prompt_text) == "<kbd>E</kbd> Talk to %s" % prior_name, "near the Prior: '%s'" % h.prompt_text)
	await until(func() -> bool: return g.ui.hud.prompt.visible, 1.0)
	check(g.ui.hud.prompt.visible and String(g.ui.hud.prompt_rt.get_parsed_text()).find("Talk to %s" % prior_name) >= 0, "the HUD prompt is visible")
	at(prior_x, prior_z - 12.0)
	settle()
	check(h.prompt_text == null, "far from everyone: no prompt")
	await until(func() -> bool: return not g.ui.hud.prompt.visible, 1.0)
	check(not g.ui.hud.prompt.visible, "the HUD prompt hides")
	var cam: DmCameraRig = g.camera
	var wb_screen := cam.unproject_position(Vector3(float(wb["x"]), 1.2, float(wb["z"])))
	at(float(wb["x"]), float(wb["z"]) - 4.0)
	cam.snap(g.local_body().position)
	await ticks(2)
	wb_screen = cam.unproject_position(Vector3(float(wb["x"]), 1.2, float(wb["z"])))
	var vp_size := root.get_visible_rect().size
	if cam.is_position_behind(Vector3(float(wb["x"]), 1.2, float(wb["z"]))):
		check(false, "the workbench is in front of the camera")
	var picked: Variant = h.pick(wb_screen)
	check(picked != null and picked["id"] == "workbench", "pick(): the cursor over the Workbench finds it")
	check(h.pick(wb_screen + Vector2(300, 300)) == null, "pick(): a cursor far from any station finds nothing (viewport %s)" % vp_size)
	h.hover_at(wb_screen)
	settle()
	check(String(h.prompt_text) == "<kbd>Click</kbd> Open the Workbench", "hover prompt: '%s'" % h.prompt_text)
	h.hover = null
	settle()
	check(h.prompt_text == null, "hover gone: prompt gone")
	# the hovered NPC is highlighted
	h.hover_at(cam.unproject_position(Vector3(prior_x, 1.2, prior_z)))
	check(h.hover != null and h.hover["kind"] == "npc" and h.hover["npc"] == "prior", "hovering the Prior picks the NPC (highlight)")
	h.hover = null

	# ---- the forges, the reforge and the bug report (after the Workbench and Vault parts above, which count on the bag as it was)
	await _forge_crafts()
	await _reforge()
	await _bug_report()

	# ---- the idle hub with every NPC
	at(-5.5, -20.0)     # in the Graves: all NPCs far
	await until(func() -> bool: return g.area_id == "graves", 2.0)
	await ticks(30)
	settle()
	check(h.npcs._near.is_empty() and h.npcs._mid.is_empty(), "far from every NPC nothing is animated per frame")
	at(prior_x, prior_z + 2.5)    # beside the Prior, in the Chapterhouse hall
	await ticks(10)
	settle()
	var near_ids := h.npcs._near.size() + h.npcs._mid.size()
	check(near_ids >= 1, "the Prior animates when you stand beside them")

	print("%d passed, %d failed" % [passed, failed])
	g.queue_free()
	await process_frame
	print("%s chapterhouse %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


func go(x: float, z: float, area: String) -> void:
	at(x, z)
	await until(func() -> bool: return g.area_id == area, 3.0)
	await ticks(3)


func give(item_id: String, qty: int = 1) -> void:
	var uh := g.ui_host
	await DmTestBag.give(uh.inventory, {"item_id": item_id, "quantity": qty})
	await uh.inventory.flush()
	await uh.refresh_inventory()


## Each forge station's panel crafts one thing through the API: the first level-1 recipe of its first tab (the ingredients are given).
func _forge_crafts() -> void:
	for row in [["bone_kiln", "kiln"], ["sawpit", "sawpit"], ["cooking_fire", "fire"], ["wing_cauldron", "cauldron"], ["wing_alembic", "alembic"]]:
		var it := interactable(row[0])
		g.ui.close_panels()
		await go(float(it["x"]), float(it["z"]) + 1.6, String(it["area"]))
		h.click_interactable(it)
		await ticks(4)
		await _craft_at(String(row[1]))
	g.ui.close_panels()


func _craft_at(kind: String) -> void:
	var key := "cauldron" if kind == "alembic" else kind
	var f: DmForgePanel = g.ui.pb.forges[key]
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
	check(not recipe.is_empty(), "%s: %s has a level-1 recipe" % [kind, prof])
	if recipe.is_empty():
		return
	var rid := String(recipe["id"])
	var result_id := String(recipe["result_item_id"])
	for ing in recipe["ingredients"]:
		await give(String(ing["item_id"]), int(ing["quantity"]) * 2)
	var before := g.ui_host.inventory.count(result_id)
	f.craft_requested.emit(rid, 1)
	check(await until(func() -> bool: return g.ui_host.inventory.count(result_id) > before, 5.0), "%s: crafting %s through the panel yields %s" % [kind, rid, result_id])


## The first affix of a rolled piece the Workbench will accept (it refuses one-value or already-maxed rolls), or -1.
func reforgeable_index(roll: Dictionary) -> int:
	var inst := {"affixes": roll["affixes"], "ilvl": roll["ilvl"]}
	for i in (roll["affixes"] as Array).size():
		if DmGoldSink.reforge_problem(inst, i, Callable(DmAffixRules, "affix_range")) == "":
			return i
	return -1


## Fund (or drain) the character as play would: the change counts as earned, so the next gains save gives it to the backend too (DECISIONS B23).
func set_gold(n: int) -> void:
	var p: DmProgression = g.progress.prog
	p.gold_unsent += n - int(p.character.get("gold", 0))
	p.character["gold"] = n


## A rolled, affixed piece in the bag: the Workbench's Reforge tab lists it, takes exactly the quoted gold, keeps the backend's purse equal to ours, and a stale price is refused.
func _reforge() -> void:
	var uh := g.ui_host
	var cid := int(character["id"])
	g.ui.close_panels()
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
	for s in uh.slots.duplicate():
		if int(s["slot_index"]) >= DmLootData.bag_size() - 8 and int(s["slot_index"]) < DmLootData.bag_size():
			uh.inventory.consume(String(s["item_id"]))
	await uh.inventory.flush()
	await uh.refresh_inventory()
	var drop := {"item_id": piece, "quantity": 1, "instance": {"id": rolled.data[0]["instance_id"], "ilvl": rolled.data[0]["ilvl"], "affixes": rolled.data[0]["affixes"]}}
	check(await DmTestBag.give(uh.inventory, drop), "the rolled piece goes into the bag")
	await uh.inventory.flush()
	await uh.refresh_inventory()
	set_gold(1000000)
	uh.prog.save_dirty = true
	g.progress.psync.tick(0.0)
	await g.progress.psync.flush()
	var wb := interactable("workbench")
	check(h.click_interactable(wb), "the Workbench is used")
	await ticks(4)
	var forge: DmForgePanel = g.ui.pb.forges[""]
	check(forge.visible and forge.reforge != null, "the Workbench opens with its Reforge tab")
	forge.quote_requested.emit()
	await ticks(10)
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
	var gold0 := int(uh.character["gold"])
	var ai := reforgeable_index({"affixes": pc["inst"]["affixes"], "ilvl": pc["inst"]["ilvl"]})
	forge.reforge.reforge_requested.emit(int(pc["slot_index"]), ai, cost_g)
	check(await until(func() -> bool: return int(uh.character["gold"]) < gold0, 5.0), "reforging an affix takes gold (%d -> %d) %s" % [gold0, int(uh.character["gold"]), str(forge.reforge.error_text)])
	check(int(uh.character["gold"]) == gold0 - cost_g, "...exactly the quoted %d" % cost_g)
	var after: Dictionary = {}
	for s in uh.slots:
		if s.get("inst") != null and String(s["item_id"]) == piece:
			after = s
	check(not after.is_empty(), "the reforged piece is still in the bag")
	# the server's purse and ours agree: the reforge went through the progress sync (else the next save would hand the gold back)
	g.progress.psync.tick(0.0)
	await g.progress.psync.flush()
	var srv: DmResult = await api.get_character()
	check(srv.ok and int(srv.data["gold"]) == int(uh.character["gold"]), "the backend's gold equals ours after the reforge (%s vs %d)" % [str(srv.data.get("gold")), int(uh.character["gold"])])
	# a wrong price is refused, never charged
	var gold1 := int(uh.character["gold"])
	var bad: DmResult = await api.reforge_affix(cid, int(pc["slot_index"]), ai, 1)
	check(not bad.ok and int(uh.character["gold"]) == gold1, "a stale price is refused by the backend (%s)" % bad.error)
	g.ui.close_panels()


## Report a bug inside Settings (the OFFLINE api only: the report stays in the local mock).
func _bug_report() -> void:
	g.ui.close_panels()
	g.ui.open_bug_report()
	await ticks(4)
	check(g.ui.is_open("settings") and g.ui.set_ui.bug_report_open(), "Report a bug opens inside Settings")
	var view: DmBugReportView = g.ui.set_ui.report
	view.category.select(2)
	view.message.text = "Test report: the Acre laborers stand in the right place."
	view._sync()
	check(not view.send_button.disabled, "a 10+ character message enables Send")
	var ctx := view.context()
	check(String(ctx["release"]).begins_with("godot-next-") and ctx["area"] == g.area_id and int(ctx["level"]) == int(g.ui_host.character["level"]), "the context names the rebuild's release, area and level (%s)" % str(ctx["release"]))
	await view.send()
	check(view.result_label.text.begins_with("Thank you"), "Send reports success (%s)" % view.result_label.text)
	var mine: DmResult = await api.get_my_bug_reports()
	check(mine.ok and (mine.data as Array).size() == 1 and mine.data[0]["category"] == "ui" and String(mine.data[0]["message"]).begins_with("Test report"), "the report is in the (offline) backend's list")
	g.ui.set_ui.close_bug_report()
	g.ui.close_panels()
