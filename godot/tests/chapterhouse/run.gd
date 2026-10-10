extends SceneTree
## Chapterhouse suite (godot/next/chapterhouse): NPCs, stations, waystone travel / recall, seals, prompts, idle cost, on the offline backend.
## godot --headless --path godot --script res://tests/chapterhouse/run.gd

const DT := 1.0 / 60.0
const IDLE_BUDGET_US := 600.0       ## median per-frame cost of the hub node with every NPC (generous: a shared VPS; measured ~10-60 us)

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
	await g.start(character, api, {"dressing": false, "persist": false, "waves": false})
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
	check(ids.size() == 3 and h.npcs.npcs.size() == 3, "all three NPCs are in the hub (%s)" % [ids])
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
	at(-3.4, 15.8 + 30.0)    # walk away: the world closes the conversation past talk range + 3.5
	await until(func() -> bool: return not g.ui.dialogue.visible, 2.0)
	check(not g.ui.dialogue.visible and h.talking == "", "walking away closes the dialogue")
	# a click on an NPC walks over and talks
	at(-3.4, 15.8 - 8.0)
	g.ui.close_panels()
	h.click_interactable(prior)
	check(h.pending == prior, "clicking an NPC queues the interaction")
	at(-3.4, 15.8 - 1.4)
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
	check(need == 150, "the Warren asks %d kills in the Graves" % need)
	for i in need - 1:
		prog.record_kill("graves")
	events.clear()
	check(h.check_seals().is_empty() and not h.door_open("graves_warren"), "%d kills: the seal holds" % (need - 1))
	prog.record_kill("graves")
	g.rewards.member_credited.emit(cid, {"kills": 1})     # an accepted report lands -> the hub checks the seals
	check(h.door_open("graves_warren") and prog.really_unlocked("warren"), "%d kills: the Warren seal breaks and its door opens" % need)
	var banner := ev("banner")
	check(banner.size() == 1 and banner[0]["ctx"]["title"] == "A seal breaks" and String(banner[0]["ctx"]["sub"]).find("Warren") >= 0, "the 'A seal breaks' banner: %s" % [banner.map(func(e: Dictionary) -> Variant: return e["ctx"].get("sub"))])
	check(h.check_seals().is_empty() and ev("banner").size() == 1, "a broken seal is not announced twice")
	check(DmContent.area_order().all(func(a: String) -> bool: return prog.is_unlocked(a) == g.world.builder.unlocked.has(a) or DmContent.area(a).get("instance", false)), "the world's unlocked halls follow the progress")
	check(g.world.nav_path(Vector3(-20, 0, -28), Vector3(-45, 0, -28)).size() > 1, "the navmesh runs through the opened Warren door")

	# ---- prompts show / hide by distance, hover prompt
	at(-3.4, 15.8 - 1.8)
	settle()
	check(String(h.prompt_text) == "<kbd>E</kbd> Talk to The Prior", "near the Prior: '%s'" % h.prompt_text)
	await until(func() -> bool: return g.ui.hud.prompt.visible, 1.0)
	check(g.ui.hud.prompt.visible and String(g.ui.hud.prompt_rt.get_parsed_text()).find("Talk to The Prior") >= 0, "the HUD prompt is visible")
	at(-3.4, 15.8 - 12.0)
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
	h.hover_at(cam.unproject_position(Vector3(-3.4, 1.2, 15.8)))
	check(h.hover != null and h.hover["kind"] == "npc" and h.hover["npc"] == "prior", "hovering the Prior picks the NPC (highlight)")
	h.hover = null

	# ---- performance: the idle hub with every NPC
	at(-5.5, -20.0)     # in the Graves: all NPCs far
	await until(func() -> bool: return g.area_id == "graves", 2.0)
	await ticks(30)
	settle()
	check(h.npcs._near.is_empty() and h.npcs._mid.is_empty(), "far from every NPC nothing is animated per frame")
	var far := _median_us(300)
	at(-3.4, 15.8 + 2.5)    # beside the Prior, in the Chapterhouse hall
	await ticks(10)
	settle()
	var near_ids := h.npcs._near.size() + h.npcs._mid.size()
	var near := _median_us(300)
	print("hub node per-frame cost (median of 300): far from NPCs %.1f us, with %d NPC(s) animating %.1f us" % [far, near_ids, near])
	perf_info(far < IDLE_BUDGET_US and near < IDLE_BUDGET_US * 3.0, "idle hub frame cost within budget (%.1f / %.1f us)" % [far, near])
	check(near_ids >= 1, "the Prior animates when you stand beside them")

	print("%d passed, %d failed" % [passed, failed])
	g.queue_free()
	await process_frame
	quit(1 if failed > 0 else 0)


## Median wall time of one DmChapterhouse._process(dt) over `n` calls (the 10 Hz tick included in the average frames).
func _median_us(n: int) -> float:
	var s: Array = []
	for i in n:
		var t0 := Time.get_ticks_usec()
		h._process(DT)
		s.append(float(Time.get_ticks_usec() - t0))
	s.sort()
	return s[n / 2]


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
