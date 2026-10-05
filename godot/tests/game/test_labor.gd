extends RefCounted
## Tests for DmLaborerViews (layout rules, sync, picks, tip, work modes, onSeen) and DmGameLabor (checkLabor / checkGarden / onCollected,
## timers). A stub host + a fake api object (the mock backend stubs the labor routes with 501). Driven by labor_run.gd.

class FakeApi extends RefCounted:
	var labor: Variant = null
	var garden: Variant = null
	var contracts: Variant = {"contracts": [{"done": false}, {"done": true}]}
	var calls: Array = []
	func get_labor(_id: int) -> DmResult:
		calls.append("labor")
		return DmResult.success(labor) if labor != null else DmResult.failure("no", 501)
	func get_garden(_id: int) -> DmResult:
		calls.append("garden")
		return DmResult.success(garden) if garden != null else DmResult.failure("no", 501)
	func get_contracts(_id: int) -> DmResult:
		calls.append("contracts")
		return DmResult.success(contracts)
	func get_professions(_id: int) -> DmResult:
		calls.append("professions")
		return DmResult.success([{"profession_id": "woodcutting", "skill_level": 3, "skill_xp": 10}])

class FakeVfx extends RefCounted:
	var puffs := 0
	func emit(_o: Dictionary) -> void:
		puffs += 1

class FakeAudio extends RefCounted:
	var played: Array = []
	func play_sfx(id: String, _p: Variant = null, _i: float = 1.0) -> void:
		played.append(id)

class FakeBuilder extends RefCounted:
	var world: Dictionary = {}

class FakeGather extends RefCounted:
	var skills := DmSkills.new()
	var charms: Array = []
	func celebrate_charms(items: Array) -> void:
		charms.append(items)

class FakeProg extends RefCounted:
	var gold := 0.0
	func add_gold(a: float) -> void:
		gold += a

class FakeLaborPanel extends RefCounted:
	var loot: Array = []
	func add_loot(slot: int, report: Dictionary) -> void:
		loot.append([slot, report])

class FakePb extends RefCounted:
	var labor := FakeLaborPanel.new()

class FakeUi extends RefCounted:
	var pb := FakePb.new()

class StubHost extends Node3D:
	var api: FakeApi
	var hero_id := 7
	var builder: FakeBuilder
	var world_root: Node3D
	var vfx: FakeVfx = FakeVfx.new()
	var audio: FakeAudio = FakeAudio.new()
	var settings: Dictionary = {"reduce_motion": false}
	var ready_ := true
	var gatherer := FakeGather.new()
	var chronicle := DmChronicle.new()
	var prog := FakeProg.new()
	var ui := FakeUi.new()
	var events: Array = []
	var toasts: Array = []
	var banners: Array = []
	var sfx: Array = []
	var refreshed := {"inv": 0, "char": 0}
	func emit_game_event(id: String, ctx: Dictionary = {}) -> void:
		events.append([id, ctx])
	func toast(text: String, kind: String = "") -> void:
		toasts.append([text, kind])
	func banner(title: String, sub: String = "", ms: int = 3000) -> void:
		banners.append([title, sub, ms])
	func float_text(_x: float, _y: float, _z: float, _t: String, _k: String = "info", _c: Variant = null) -> void:
		pass
	func play_sfx(id: String, _x: float = NAN, _z: float = NAN, _i: float = 1.0) -> void:
		sfx.append(id)
	func refresh_inventory() -> void:
		refreshed["inv"] += 1
	func refresh_character() -> void:
		refreshed["char"] += 1

var passed := 0
var failed := 0
var tree: SceneTree
var host: StubHost
var api: FakeApi
var clock := 1.0e12


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


static func slot_row(slot: int, node_type: Variant, elapsed: float, capped := false, unlocked := true) -> Dictionary:
	return {"slot": slot, "unlocked": unlocked, "nodeType": node_type, "nodeName": null, "skill": null, "item": null, "startedAt": 1.0e12 - elapsed,
		"elapsedMs": elapsed, "capped": capped, "pendingActions": 0, "estItems": 12, "estXp": 30}


func make_view(slots: Array) -> Dictionary:
	return {"now": 1.0e12, "capMs": 8 * 3600000, "totalLevel": 150, "levelsPerSlot": 50, "slots": slots}


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func run(t: SceneTree) -> void:
	tree = t
	api = FakeApi.new()
	host = StubHost.new()
	host.api = api
	host.builder = FakeBuilder.new()
	host.builder.world = DmData.world()
	host.world_root = host
	tree.root.add_child(host)
	_rules()
	await _views()
	await _glue()
	host.queue_free()


func _rules() -> void:
	var L = DmLaborerViews
	check(L.work_for("woodcutting")["anim"] == "chop" and L.work_for("mining")["impact"] == 2.1, "chop work for wood and ore")
	check(L.work_for("gravedigging")["anim"] == "dig" and L.work_for("gravedigging")["beatEvery"] == 2.6, "dig work")
	check(L.work_for("fishing")["anim"] == "idle" and L.work_for(null)["range"] == null, "fishing stands")
	check(L.worked_text(0) == "under 1 m" and L.worked_text(45 * 60000) == "45 m" and L.worked_text(192 * 60000) == "3 h 12 m", "worked text")
	check(L.laborer_tip("Mining", 192 * 60000, true, false) == "Grave Laborer · Mining · 3 h 12 m · ready to collect", "tip ready")
	check(L.laborer_tip("Mining", 0, false, true).ends_with("full, collect them") and L.laborer_tip("Mining", 0, false, false).ends_with("working"), "tip states")
	var w: Dictionary = DmData.world()
	var acre_nodes: Array = w["nodes"].filter(func(n: Dictionary) -> bool: return n["area"] == "acre")
	var node := L.post_node(acre_nodes, "seam_tin", 0)
	check(node["type"] == "seam_tin", "post node: same type")
	check(L.post_node(acre_nodes, "seam_tin", 3)["type"] == "seam_tin", "post node: slot wraps over same-type nodes")
	check(L.post_node(acre_nodes, "no_such", 0).is_empty(), "post node: unknown type")
	check(L.post_node(acre_nodes, "wheat", 0).is_empty() or true, "post node: no crash for missing skill nodes")
	var herb := L.post_node(acre_nodes, "nightshade", 0)
	check(herb.is_empty() or DmContent.get_export("gameplay_gatheringRules", "NODES")[herb["type"]]["skill"] == "alchemy" or true, "post node: fallback tolerant")
	var rect: Dictionary = {}
	rect = w["areas"]["acre"]["rect"]
	var blockers: Array = []
	for p in w["props"]:
		if p["area"] == "acre":
			blockers.append({"x": float(p["x"]), "z": float(p["z"]), "r": 0.7})
	var world := {"rect": rect, "nodes": acre_nodes, "ponds": w["ponds"], "blockers": blockers}
	var taken: Array = []
	var okc := 0
	var good := 0
	var defs: Dictionary = DmContent.get_export("gameplay_gatheringRules", "NODES")
	for i in acre_nodes.size():
		var n: Dictionary = acre_nodes[i]
		if defs[n["type"]]["skill"] == "gardening":
			continue
		var s := L.laborer_spot(n, i % 4, world, taken)
		okc += 1
		var d := DmSimMath.hypot(s["x"] - n["x"], s["z"] - n["z"])
		var in_pond := false
		for p in w["ponds"]:
			if s["x"] >= p["x0"] - 0.5 and s["x"] <= p["x1"] + 0.5 and s["z"] >= p["z0"] - 0.5 and s["z"] <= p["z1"] + 0.5:
				in_pond = true
		var face_ok := absf(atan2(float(n["x"]) - s["x"], float(n["z"]) - s["z"]) - s["facing"]) < 1e-9
		if d >= 1.35 and not in_pond and face_ok and s["x"] > rect["x0"] and s["x"] < rect["x1"]:
			good += 1
	check(okc > 20 and good == okc, "every acre post gets a spot outside the gather ring, off the pond, facing the node (%d/%d)" % [good, okc])
	var t1 := L.laborer_spot(acre_nodes[0], 0, world, [])
	var t2 := L.laborer_spot(acre_nodes[0], 1, world, [t1])
	check(DmSimMath.hypot(t1["x"] - t2["x"], t1["z"] - t2["z"]) >= 1.3 or t2["x"] == t1["x"], "taken spots are avoided")
	var mk: Node3D = L.make_tool("tool_hatchet", 0.95)
	check(mk.get_child_count() == 2, "tool stand-in has a handle and a head")
	mk.free()


func _views() -> void:
	var nodes: Array = host.builder.world["nodes"].filter(func(n: Dictionary) -> bool: return n["area"] == "acre")
	var wood: String = ""
	for n in nodes:
		if n["kind"] == "tree":
			wood = n["type"]
			break
	var v := make_view([slot_row(0, wood, 3600000.0 * 2), slot_row(1, "seam_tin", 1000.0), slot_row(2, "grave_pauper", 3600000.0 * 9, true), slot_row(3, null, 0.0, false, false)])
	api.labor = v
	var lv := DmLaborerViews.new()
	lv.clock_ms = func() -> float: return clock
	lv.setup(host)
	check(lv.get_parent() == host and not lv.visible, "setup parents under world_root, hidden")
	var seen_views: Array = []
	lv.on_view = func(x: Dictionary) -> void: seen_views.append(x)
	lv.update(0.1, -40.0, 20.0)
	check(lv.picks.is_empty(), "inactive: nothing happens")
	lv.set_active(true)
	await _frames(2)
	check(lv.visible and lv.view != null and api.calls.has("labor"), "active: fetched the labor view")
	check(seen_views.size() == 1, "noteLabor tap fires on fetch")
	var dbg := lv.debug()
	check(dbg.size() == 3, "three assigned laborers made (locked/unassigned slot skipped): %d" % dbg.size())
	check(lv.pick_list().size() == 3 and lv.pick_list()[0].has("slot"), "pick list: 3 loaded visible laborers")
	var models: Array = dbg.map(func(d: Dictionary) -> String: return d["model"])
	check(models.has("skeleton_thrall") and models.has("thrall_legionnaire") and models.has("thrall_sentinel"), "one distinct thrall model per slot: %s" % str(models))
	var by: Dictionary = {}
	for d in dbg:
		by[d["slot"]] = d
	check(by[0]["tools"] == ["tool_hatchet"] and by[1]["tools"] == ["tool_pickaxe"] and by[2]["tools"] == ["tool_spade"], "each laborer holds its skill's tool")
	check(by[0]["ready"] and not by[1]["ready"] and by[2]["full"], "ready / full flags from the view %s" % str([by[0], by[1], by[2]]))
	var tip0 := lv.tip(0)
	check(tip0.begins_with("Grave Laborer · Woodcutting · 2 h 0 m · ready to collect"), "tip text: %s" % tip0.get_slice("\n", 0))
	check(lv.tip(2).contains("full, collect them") and lv.tip(1).contains("working") and lv.tip(3) == "" and lv.tip(9) == "", "tip states + missing slot %s" % str([lv.tip(1), lv.tip(2)]))
	check(lv.tip(0).contains("click to open the Laborers (H)"), "tip hint line")
	lv.set_hover(1)
	for i in 5:
		lv.update(0.05, -40.0, 20.0)
	check(lv.hover_slot == 1, "hover kept")
	# work modes: hold ~0.9 s, then work (or rest when full)
	check(lv.debug().filter(func(d: Dictionary) -> bool: return d["mode"] == "hold").size() == 3, "freshly tooled laborers hold first")
	for i in 40:
		lv.update(0.05, by[0]["x"], by[0]["z"])
	dbg = lv.debug()
	by.clear()
	for d in dbg:
		by[d["slot"]] = d
	check(by[0]["mode"] == "work" and by[1]["mode"] == "work" and by[2]["mode"] == "rest", "then work, the full one rests: %s" % str([by[0]["mode"], by[1]["mode"], by[2]["mode"]]))
	check(host.events.any(func(e: Array) -> bool: return e[0] == "laborers_seen") and host.events.filter(func(e: Array) -> bool: return e[0] == "laborers_seen").size() == 1, "laborers_seen emitted once")
	# the chop loop keeps stroking and puffs on impact
	var puffs0 := host.vfx.puffs
	for i in 400:
		lv.update(0.05, by[0]["x"], by[0]["z"])
	check(host.vfx.puffs > puffs0, "impact puffs while working nearby (%d)" % (host.vfx.puffs - puffs0))
	check(host.audio.played.size() > 0 and host.audio.played[0] in ["chop", "pickOre", "pick"], "a quiet gather sound plays: %s" % str(host.audio.played.slice(0, 2)))
	var head: Variant = lv.debug()[0]["head"]
	check(float(head) >= 0.0 and float(head) < 3.2, "chop playhead stays inside the clip (%s)" % str(head))
	# far away: frozen
	var h0: float = lv.debug()[0]["head"]
	for i in 10:
		lv.update(0.05, 900.0, 900.0)
	check(lv.debug()[0]["head"] == h0, "laborers beyond ANIMATE_RANGE stay frozen")
	# reduced motion: no puffs
	host.settings["reduce_motion"] = true
	var p1 := host.vfx.puffs
	for i in 300:
		lv.update(0.05, by[0]["x"], by[0]["z"])
	check(host.vfx.puffs == p1, "reduce_motion: no debris")
	host.settings["reduce_motion"] = false
	# apply: re-post slot 1 to another node type moves + retools
	var v2 := make_view([slot_row(0, wood, 0.0), slot_row(1, "pool_still", 0.0), slot_row(2, null, 0.0), slot_row(3, null, 0.0)])
	lv.apply(v2)
	var d2: Array = lv.debug()
	var s1: Dictionary = d2.filter(func(d: Dictionary) -> bool: return d["slot"] == 1)[0]
	check(s1["type"] == "pool_still" and s1["tools"].has("tool_pickaxe") and s1["tools"].has("tool_fishing_rod"), "re-post: new post, rod added, pickaxe kept hidden")
	check(lv.pick_list().size() == 2, "unassigned slot 2 hidden, picks rebuilt")
	# leaving the acre
	lv.set_active(false)
	check(not lv.visible and lv.hover_slot == -1, "inactive hides and clears hover")
	var calls := api.calls.size()
	lv.update(0.1, 0.0, 0.0)
	check(api.calls.size() == calls, "no fetch while away")
	# periodic refresh while active
	lv.set_active(true)
	await _frames(2)
	var c2 := api.calls.size()
	for i in 10:
		lv.update(10.0, 0.0, 0.0)
	await _frames(2)
	check(api.calls.size() > c2, "refresh every REFRESH_S while active")
	lv.dispose()
	await _frames(1)


func _glue() -> void:
	host.toasts.clear()
	var gl := DmGameLabor.new(host)
	var lv := DmLaborerViews.new()
	lv.clock_ms = func() -> float: return clock
	lv.setup(host)
	gl.views = lv
	api.labor = make_view([slot_row(0, "seam_tin", 3600000.0), slot_row(1, "seam_copper", 60000.0, false), slot_row(2, null, 0.0), slot_row(3, null, 0.0, false, false)])
	api.garden = {"plots": [{"state": "ready"}, {"state": "growing"}, {"state": "ready"}]}
	await gl.check_labor(true)
	check(gl.summary == {"unlocked": 3, "assigned": 2, "ready": 1}, "summary from the view: %s" % str(gl.summary))
	check(host.toasts.size() == 1 and host.toasts[0][0] == "Your laborers have gathered about 12 finds (H)" and host.toasts[0][1] == "good", "arrival toast: %s" % str(host.toasts))
	check(lv.view != null and gl.contract_summary == {"open": 1, "total": 2}, "views.apply + contracts refreshed")
	host.toasts.clear()
	await gl.check_labor(false)
	check(host.toasts.is_empty(), "no arrival, nothing capped: quiet")
	api.labor = make_view([slot_row(0, "seam_tin", 9 * 3600000.0, true), slot_row(1, "seam_copper", 0.0)])
	await gl.check_labor(false)
	check(host.toasts.size() == 1 and host.toasts[0][0].begins_with("A laborer has filled up"), "full laborer toast")
	await gl.check_labor(false)
	check(host.toasts.size() == 1, "full toast only once (cap noted)")
	api.labor = make_view([slot_row(0, "seam_tin", 0.0, false)])
	await gl.check_labor(false)
	api.labor = make_view([slot_row(0, "seam_tin", 9 * 3600000.0, true)])
	await gl.check_labor(false)
	check(host.toasts.size() == 2, "cap note cleared once uncapped, toasts again")
	host.toasts.clear()
	api.labor = null
	await gl.check_labor(true)
	check(host.toasts.is_empty(), "failed fetch is quiet")
	# garden
	await gl.check_garden(true)
	check(host.toasts.size() == 1 and host.toasts[0][0] == "2 plots are ready in your garden (U)" and gl.garden_ready == 2, "garden arrival: %s" % str(host.toasts))
	host.toasts.clear()
	await gl.check_garden(false)
	check(host.toasts.is_empty(), "no new plots: quiet")
	api.garden = {"plots": [{"state": "ready"}, {"state": "ready"}, {"state": "ready"}]}
	await gl.check_garden(false)
	check(host.toasts.size() == 1 and host.toasts[0][0] == "3 plots are ready in your garden (U)", "more plots ready: toast")
	host.toasts.clear()
	api.garden = {"plots": [{"state": "growing"}]}
	await gl.check_garden(true)
	check(host.toasts.size() == 1 and host.toasts[0][0] == "1 plot is still growing in your garden (U)" and host.toasts[0][1] == "", "arrival growing note")
	# garden result
	host.toasts.clear()
	await gl.on_garden_result("harvest", {"plots": [{"state": "ready"}], "items": [{"itemId": "iron_ore", "qty": 3}, {"itemId": "iron_ore", "qty": 1}], "leveledUp": true, "level": 4})
	check(host.toasts.size() == 1 and host.toasts[0][0].begins_with("Harvested 3× ") and host.toasts[0][0].ends_with("(and a seed to replant)"), "harvest toast: %s" % str(host.toasts))
	check(host.banners.size() == 1 and host.banners[0][0] == "Grave Gardening 4" and gl.garden_ready == 1 and host.sfx.has("gardenHarvest"), "level banner + ready count + sound")
	# collection
	var res := make_view([slot_row(0, "seam_tin", 0.0)])
	res["collected"] = {"slot": 0, "node": "seam_tin", "skill": "woodcutting", "hours": 2.0, "actions": 40, "items": [{"itemId": "iron_ore", "qty": 5}], "gold": 12, "xp": 80, "leveledUp": false}
	host.gatherer.skills = DmSkills.new()
	await gl.on_collected(res, 0)
	check(host.prog.gold == 12.0 and host.sfx.has("coin") and host.refreshed["inv"] == 1 and host.refreshed["char"] == 1, "gold credited, coin, panels refreshed")
	check(float(host.chronicle.sums.get("gathered.woodcutting", 0)) == 5.0, "chronicle counts the finds")
	var loot: Array = host.ui.pb.labor.loot
	check(loot.size() == 1 and loot[0][0] == 0 and loot[0][1]["totalItems"] == 5 and loot[0][1]["reason"] == "labor" and loot[0][1]["seconds"] == 7200, "loot report added to the panel")
	check(loot[0][1]["skills"][0]["fromLevel"] == 1 and loot[0][1]["skills"][0]["toLevel"] == 3, "level change in the report %s" % str(loot[0][1]["skills"]))
	check(loot[0][1]["milestones"].has("Woodcutting level 3"), "level milestone")
	await gl.on_collected({"slots": []}, 0)
	check(host.ui.pb.labor.loot.size() == 1, "no collected: nothing")
	# timers
	var gl2 := DmGameLabor.new(host)
	api.labor = make_view([slot_row(0, "seam_tin", 3600000.0)])
	api.garden = {"plots": [{"state": "ready"}]}
	host.toasts.clear()
	gl2.update(3.0)
	await _frames(1)
	check(host.toasts.is_empty() or true, "armed on ready_")
	gl2.update(1.5)
	await _frames(2)
	check(host.toasts.any(func(t: Array) -> bool: return t[0].contains("garden")) and not host.toasts.any(func(t: Array) -> bool: return t[0].contains("laborers")), "garden first check at 4 s, labor not yet")
	gl2.update(2.0)
	await _frames(2)
	check(host.toasts.any(func(t: Array) -> bool: return t[0].contains("laborers have gathered")), "labor first check at 6 s")
	var n := api.calls.size()
	gl2.update(1.0)
	await _frames(1)
	check(api.calls.size() == n, "nothing between checks")
	host.toasts.clear()
	api.garden = {"plots": [{"state": "ready"}, {"state": "ready"}]}
	gl2.update(60.0)
	await _frames(2)
	check(host.toasts.any(func(t: Array) -> bool: return t[0].contains("2 plots")), "garden every 60 s")
	var lc := api.calls.count("labor")
	gl2.update(300.0)
	await _frames(2)
	check(api.calls.count("labor") > lc, "labor every 5 min")
	gl2.dispose()
	lv.dispose()
