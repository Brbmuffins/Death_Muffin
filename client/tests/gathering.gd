extends SceneTree
## Gathering and the Acre on the core (client/README.md "Gathering and the Acre"): the whole world as a player gets it (every area but the
## Depths), offline on the local mock backend (never a real server), headless, with a game clock the mock follows. Checks:
##   - the nodes: every node of world.json is in the area scenes under `GatherNodes`, each registered with the gathering views; the spent models load; the game scene made the
##     gather node (and the Acre's glue with the real HUD) and the panels this build warms include the Acre ledger's;
##   - hover and click, end to end in the Graves: the node under the cursor gets its ring and its card (needs, XP, what it gives, spent) and a click walks the hero there and works it
##     (a click on a station or an enemy still wins; a refused node says why in the rules' words: a level, a full bag);
##   - gathering through the server: a cycle takes `ticks x DmGathering.TICK_MS`, the successes are batched to the backend (the 8 s batch and the stop), whose answer decides the finds, the XP and
##     the level (the bag, the professions and the chronicle count follow it, not the client's rolls), a rich node's yield, the node going spent (its model swaps, the card says so),
##     the hero waiting and working again when it comes back (half the respawn time for a rich node);
##   - the stops (a walk, a panel, a cast, death), Auto off ("The X is spent."), the skills' level-up banner and counsel events;
##   - the Acre: AFK from the Skills tab (only in the Acre, the report on stopping), the Grave Laborers (pooled models, one per post, built on the first visit, none outside the Acre), their
##     hover card and the click that opens the Laborers, a collection (gold, the chronicle, the report under the laborer), the garden (plant, harvest, the notices), a contract, and the
##     guidance feeds the Sexton and the Next box read;
##   - the rest of the loop and the Acre: every node has parts, a yield from its type's range and a free stand spot; each skill's find and XP; a success from out of reach is ignored; the
##     Sawpit's plank from gathered logs; the notices of a full laborer and a ready plot; a relaunch keeps the results; the Next box's state and its full-bag suggestion;
##   - ZERO script errors or engine errors in the log.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/gathering.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## A backend answer the test controls (the notice rules read the labor / garden / contract views through the Acre's `api`).
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


const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://gathering_test"
const BAKE := ["grave_robber", "bone_hound"]
const START_MS := 1_800_000_000_000      ## the game clock's origin (ms)

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var hero: DmHeroBody
var mock: DmMockBackend
var api: DmApi
var username := ""
var events: Array = []          ## [id, ctx] of the HUD's game events
var jump_ms := 0                ## time the test lets pass at once (labor and the garden take hours)
var server_rolls_default: Callable   ## the mock's seeded dice
var seed_id := ""             ## the seed the oak's extras hold (the garden plants it)
var laborer_slots := 0        ## the slots the laborer rules give the skills the test sets
const POSTS := {0: "coffin_oak", 1: "seam_copper", 2: "grave_pauper"}   ## the posts the test gives its laborers (slot -> node type): the last is the gravedigger


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL gathering: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_ticks: int) -> bool:
	var end := Engine.get_physics_frames() + limit_ticks
	while not bool(cond.call()) and Engine.get_physics_frames() < end:
		await physics_frame
	return bool(cond.call())


## The game's clock in ms: physics ticks at 60 Hz (a run under --fixed-fps outruns the wall clock) plus what the test let pass at once.
func game_ms() -> int:
	return START_MS + int(float(Engine.get_physics_frames()) * 1000.0 / 60.0) + jump_ms


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
	DmSimData.ensure()
	mock = DmOffline.make_mock("")
	mock.now_ms = game_ms
	api = DmOffline.make_api(mock)
	username = "gather%d" % (Time.get_ticks_usec() % 100000)
	var reg := await api.register(username, "g@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 12)
	var heard := DmUiConfig.guidance_path(int(ch.data["id"]))   # (what the people have said to this character id in an earlier run of this test)
	if FileAccess.file_exists(heard):
		DirAccess.remove_absolute(heard)
	await _launch(ch.data)
	_the_nodes()
	await _hover_and_click()
	await _every_node()
	await _refusals()
	await _gathering_through_the_server()
	await _the_stops()
	await _the_server_decides()
	await _laborers_outside_the_acre()
	await _afk()
	await _the_laborers()
	await _the_garden_and_contracts()
	await _host_rules()
	await _the_notices()
	await _relaunch()
	await _guidance()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s gathering %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ helpers

## Starts the game for this character (the first launch, and the relaunch that proves the results were kept).
func _launch(character: Dictionary) -> void:
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(character, api, {"name": "tester", "hud": true, "audio": false, "seed": 20261017, "waves": false, "wander": false, "persist": false, "baked_dir": OUT})
	hero = g.local_body()
	events.clear()
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append([id, ctx]))
	g.gather.loop.hooks["now"] = func() -> float: return float(game_ms())   # the loop's 8 s batches and backoffs follow the game's clock too


func _acc() -> Dictionary:
	return mock.db["accounts"][username]


## The mock's (the server's) profession row.
func _prof(skill: String) -> Dictionary:
	for p: Dictionary in _acc()["professions"]:
		if String(p["profession_id"]) == skill:
			return p
	return {}


func _bag_qty(item_id: String) -> int:
	var n := 0
	for s: Dictionary in g.loot.slots():
		if String(s.get("item_id", "")) == item_id and int(s["slot_index"]) < DmLootData.bag_size():
			n += int(s["quantity"])
	return n


func _server_qty(item_id: String) -> int:
	var n := 0
	for s: Dictionary in _acc()["slots"]:
		if String(s["item_id"]) == item_id and int(s["slot_index"]) < DmLootData.bag_size():
			n += int(s["quantity"])
	return n


func _node(id: String) -> Dictionary:
	return g.gather.nodes[id]


## The rules of the node type the test works (the Graves' oak).
func _oak_def() -> Dictionary:
	return DmGathering.node_def(String(_node("graves_0")["type"]))


## The yield a node of this type is rolled with: its range, times RICH_YIELD for a rich one.
func _yield_range(def: Dictionary, rich: bool) -> Array:
	var yl: Array = def["yields"]
	return [roundf(float(yl[0]) * DmGathering.RICH_YIELD) if rich else float(yl[0]), roundf(float(yl[1]) * DmGathering.RICH_YIELD) if rich else float(yl[1])]


func _node_pos(n: Dictionary) -> Vector3:
	return Vector3(float(n["x"]), 0.0, float(n["z"]))


## Where the cursor must be to hover a node (the point `pick` projects).
func _screen_of(n: Dictionary) -> Vector2:
	var tree: bool = n["kind"] == "tree"
	return g.camera.unproject_position(Vector3(float(n["x"]), 1.6 if tree else (0.1 if n["kind"] == "pool" else 0.5), float(n["z"])))


func _go(pos: Vector3) -> void:
	g.chapterhouse.teleport_to(pos.x, pos.z)
	await ticks(6)


func _event_ids() -> Array:
	return events.map(func(e: Array) -> String: return String(e[0]))


# ------------------------------------------------------------------------------------------------------------------ the nodes

func _the_nodes() -> void:
	var data: Array = DmData.world()["nodes"]
	check(g.gather != null and g.gather.loop != null and g.gather.nodes.size() == data.size() and not data.is_empty(), "the gather node is up on the host with its loop and all %d nodes of world.json" % data.size())
	var missing: Array = []
	var misplaced: Array = []
	for n: Dictionary in data:
		var holder := g.world.get_node("area_%s/GatherNodes" % n["area"]).get_node_or_null(String(n["id"])) as Node3D
		if holder == null:
			missing.append(n["id"])
		elif Vector2(holder.position.x - float(n["x"]), holder.position.z - float(n["z"])).length() > 0.001 or absf(angle_difference(holder.rotation.y, float(n["rot"]))) > 0.001:
			misplaced.append(n["id"])
	check(missing.is_empty() and misplaced.is_empty(), "every node is in its area scene where world.json puts it (missing %s, misplaced %s)" % [str(missing), str(misplaced)])
	var b := g.world.builder
	check(b.node_views.size() == data.size() and b.area_nodes.size() == DmData.world()["order"].size() and g.gather.views != null, "the views hold every node's prop (%d) and every area's root (%d)" % [b.node_views.size(), b.area_nodes.size()])
	var spent: Dictionary = {}
	for n: Dictionary in data:
		if n["spentModel"] != null:
			spent[String(n["spentModel"])] = float(n["spentHeight"])
	var parts_ok := true
	for m: String in spent:
		parts_ok = parts_ok and not DmModels.prop_parts(m, float(spent[m])).is_empty()
	check(not spent.is_empty() and parts_ok, "the %d spent models (stump, ore, dug grave...) load" % spent.size())
	var rules_nodes: Dictionary = DmGatherData.nodes()
	var bare: Array = []
	var bad_yield: Array = []
	for n: Dictionary in data:
		var prop: Node3D = b.node_views.get(String(n["id"]))
		if prop == null or prop.get_child_count() == 0 or not rules_nodes.has(n["type"]):
			bare.append(n["id"])
		var range_ := _yield_range(DmGathering.node_def(String(n["type"])), DmCombatData.truthy(n.get("rich")))
		var lo: float = range_[0]
		var hi: float = range_[1]
		var left := float(g.gather._remaining[n["id"]])
		if left < lo or left > hi:
			bad_yield.append("%s %d not in %d..%d" % [n["id"], int(left), int(lo), int(hi)])
	check(bare.is_empty(), "every node has its model parts in the world and a type the rules know (not: %s)" % str(bare))
	check(bad_yield.is_empty(), "every node holds a yield rolled from its type's range (a rich one x1.5) (not: %s)" % str(bad_yield))
	var no_spot: Array = []
	for skill: String in DmGathering.GATHER_SKILLS:
		for nd in DmGathering.nodes_for_skill(skill):
			if not g.gather.nodes.values().any(func(n: Dictionary) -> bool: return n["type"] == nd["id"] and n["area"] == "acre"):
				no_spot.append("%s %s (level %d)" % [skill, nd["id"], int(nd["level"])])
	check(no_spot.is_empty(), "every node type the Skills tab offers for AFK has a spot in the Acre, the only AFK area (not: %s)" % str(no_spot))
	check(g.acre != null and g.acre.views != null and g.acre.labor != null, "the Acre's glue is up on the host with the real HUD (laborers, notices)")
	for p in ["professions", "garden", "labor", "contracts"]:
		check(g.ui.warm_panels.has(p) and g.ui.window_for(p) != null, "the %s panel is built and warmed" % p)
	check(g.ui_host.afk_status() == {"active": false, "text": "Paused", "allowed": false}, "the Skills tab's AFK status answers (%s)" % str(g.ui_host.afk_status()))


# ------------------------------------------------------------------------------------------------------------------ hover and click

func _hover_and_click() -> void:
	var oak := _node("graves_0")
	await _go(_node_pos(oak) + Vector3(7.0, 0.0, 0.0))
	check(g.area_id == "graves", "the hero stands in the Graves")
	var at := _screen_of(oak)
	g.gather.hover_at(at, false)
	check(g.gather.hover != null and String(g.gather.hover["id"]) == "graves_0", "the node under the cursor is the hovered one (%s)" % str(g.gather.hover.get("id") if g.gather.hover != null else null))
	check(g.gather.views._hover.visible and g.gather.views._hover.position.distance_to(Vector3(float(oak["x"]), 0.04, float(oak["z"]))) < 0.001, "its ring stands on it")
	var card: String = g.gather.node_tip_text(oak)
	var oak_def := DmGathering.node_def(String(oak["type"]))
	var skill_name := String(DmGatherData.get_data()["skills"][oak_def["skill"]]["name"])
	check(card.contains(String(oak_def["name"])) and card.contains("rich") == DmCombatData.truthy(oak.get("rich")) and card.contains(skill_name) and card.contains("%d XP per success" % int(oak_def["xp"])), "its card says what it is, whether it is rich, what it needs and the XP (%s)" % card)
	check(g.ui.hud.node_tip_box.visible, "the HUD shows the card")
	g.gather.hover_at(Vector2(2.0, 2.0), false)
	check(g.gather.hover == null and not g.gather.views._hover.visible and not g.ui.hud.node_tip_box.visible, "the cursor away: no ring, no card")
	g.gather.hover_at(at, true)
	check(g.gather.hover == null, "a station or person under the cursor wins the hover")
	# nothing is built by hovering
	var nodes0 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	for i in 200:
		g.gather.hover_at(at if i % 2 == 0 else Vector2(2.0, 2.0), false)
	check(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) == nodes0, "hovering builds no node (%d nodes)" % nodes0)


# ------------------------------------------------------------------------------------------------------------------ every node

## Every node of the areas that have them, hovered and clicked: the ring and the card of the node under the cursor, and the click either starts the work or refuses in
## the rules' words (a level, a spot nobody can stand on). Every area's navmesh is on for it (the seals are put back).
func _every_node() -> void:
	var unlocked0: int = g.world.unlocked.size()
	g.world.set_unlocked(DmNextWorld.every_area())
	await ticks(3)
	var loop: DmGatherLoop = g.gather.loop
	var bad_hover: Array = []
	var bad_card: Array = []
	var bad_click: Array = []
	var started := 0
	var refused := 0
	var by_area := {}
	for n: Dictionary in DmData.world()["nodes"]:
		by_area[String(n["area"])] = int(by_area.get(String(n["area"]), 0)) + 1
		var def := DmGathering.node_def(String(n["type"]))
		var mid := _area_mid(String(n["area"]))
		var off := (mid - _node_pos(n)).normalized() * 3.5
		g.chapterhouse.teleport_to(float(n["x"]) + off.x, float(n["z"]) + off.z)
		await ticks(3)
		var at := _screen_of(n)
		g.gather.hover_at(at, false)
		var hover_ok: bool = g.gather.hover != null and String(g.gather.hover["id"]) == String(n["id"]) and g.gather.views._hover.visible
		if not hover_ok:
			bad_hover.append(n["id"])
		var card: String = g.gather.node_tip_text(n)
		if not (card.contains(String(def["name"])) and card.contains("%d XP per success" % int(def["xp"])) and card.contains(String(DmContent.item(String(def["item"]))["name"]))):
			bad_card.append(n["id"])
		var gate := DmGathering.gather_blocker(String(n["type"]), g.gather.skills.gate_level(String(def["skill"])))
		var red: Color = Color.html("#c0504d")
		var ring: Color = g.gather.views._hover_mat.albedo_color
		if (gate != "") != (absf(ring.r - red.r) < 0.01 and absf(ring.g - red.g) < 0.01 and absf(ring.b - red.b) < 0.01):
			bad_hover.append("%s ring colour" % n["id"])
		if gate != "" and not card.contains("Requires"):
			bad_card.append("%s should say what it requires" % n["id"])
		events.clear()
		loop.stop("moved")
		g.gather.click_at(at)
		if gate != "":
			refused += 1
			if loop.active or not events.any(func(e: Array) -> bool: return e[0] == "float" and String(e[1]["text"]) == gate):
				bad_click.append("%s should be refused: %s" % [n["id"], gate])
		else:
			started += 1
			if not loop.active or String(loop.node.get("id", "")) != String(n["id"]):
				var said := events.filter(func(e: Array) -> bool: return e[0] == "float").map(func(e: Array) -> String: return String(e[1]["text"]))
				bad_click.append("%s did not start (%s)" % [n["id"], str(said)])
		loop.stop("moved")
	check(bad_hover.is_empty(), "every node's ring shows when its place is under the cursor (not: %s)" % str(bad_hover))
	check(bad_card.is_empty(), "every node's card names it, its XP and what it gives (not: %s)" % str(bad_card))
	check(bad_click.is_empty() and started > 0 and refused > 0, "a click starts the work or is refused in the rules' words: %d started, %d refused by level, in %s (not: %s)" % [started, refused, str(by_area), str(bad_click)])
	var nav := DmNextGather.NavShim.new()
	nav.world = g.world
	var unreachable: Array = []
	for n: Dictionary in DmData.world()["nodes"]:
		if DmGathering.stand_spot(nav.blocked, n, 0.0, 0.0).is_empty():
			unreachable.append(n["id"])
	check(unreachable.is_empty(), "every node has a free stand spot on the navmesh of its area (without: %s)" % str(unreachable))
	g.chapterhouse.apply_seals()
	await ticks(3)
	check(g.world.unlocked.size() == unlocked0, "(the seals are back)")


func _area_mid(id: String) -> Vector3:
	var r: Dictionary = DmContent.area(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


# ------------------------------------------------------------------------------------------------------------------ refusals

func _refusals() -> void:
	var oak := _node("graves_0")
	# a level: the rules' own words, nothing starts
	var high: Dictionary = {}
	for n: Dictionary in g.gather.nodes.values():
		if int(DmGathering.node_def(String(n["type"]))["level"]) > g.gather.skills.level("gravedigging") and String(DmGathering.node_def(String(n["type"]))["skill"]) == "gravedigging":
			high = n
			break
	events.clear()
	g.gather.click_node(high)
	var words := DmGathering.gather_blocker(String(high["type"]), g.gather.skills.level("gravedigging"))
	check(not g.gather.loop.active and events.any(func(e: Array) -> bool: return e[0] == "float" and String(e[1]["text"]) == words) and words.begins_with("Requires"),
		"a node above the skill's level is refused in the rules' words and nothing starts (%s)" % words)
	# a full bag
	var saved: Array = g.loot.inventory.slots.duplicate(true)
	var full: Array = saved.duplicate(true)
	var used := {}
	for r: Dictionary in full:
		used[int(r["slot_index"])] = true
	for i in DmLootData.bag_size():
		if not used.has(i):
			full.append({"slot_index": i, "item_id": "ring_copper", "quantity": 1, "equipped": 0})
	g.loot.inventory.slots = full
	events.clear()
	g.gather.click_node(oak)
	check(not g.gather.loop.active and events.any(func(e: Array) -> bool: return e[0] == "float" and String(e[1]["text"]) == "Your bag is full."), "a full bag refuses a node whose find would not fit: \"Your bag is full.\"")
	g.loot.inventory.slots = saved
	check(g.gather._bag_fits("log_oak"), "(the bag is back)")
	# GM mode opens the gathering tiers on the client (the host adapter hands it to the skills; the server follows only for a staff account)
	check(g.gather.skills.gate_level("gravedigging") == g.gather.skills.level("gravedigging"), "a normal player is gated by his level")
	g.ui_host.dev_access = true
	g.ui_host._push_dev_access()
	check(g.gather.skills.gate_level("gravedigging") == DmGathering.LEVEL_CAP and g.gather.loop.start(high) == "", "GM mode opens every tier to the client's gate (the server's own check stays)")
	g.gather.loop.stop("moved")
	g.ui_host.dev_access = false
	g.ui_host._push_dev_access()
	check(g.gather.skills.gate_level("gravedigging") == g.gather.skills.level("gravedigging"), "...and closes again")


# ------------------------------------------------------------------------------------------------------------------ gathering through the server

func _gathering_through_the_server() -> void:
	var oak := _node("graves_0")
	var loop: DmGatherLoop = g.gather.loop
	var lands := minf(0.5, DmGathering.success_chance(_oak_def(), 1) * 0.9)   # under the first-tier node's chance and over its extras' (tiny) chances
	server_rolls_default = func() -> float: return lands   # the server's dice: every cycle it rolls lands and no rare extra drops
	mock.rng = server_rolls_default
	# the client rolls each cycle for feel: the first fails, the rest succeed (so the node's yield is what ends the gathering)
	var cycle_log: Array = []     # [physics frame, success]
	var first := [true]
	loop.hooks["rand"] = func() -> float:
		if first[0]:
			first[0] = false
			return 0.999
		return 0.0
	var on_cycle: Callable = loop.hooks["onCycle"]
	loop.hooks["onCycle"] = func(def: Dictionary, success: bool, node: Dictionary) -> void:
		cycle_log.append([Engine.get_physics_frames(), success])
		on_cycle.call(def, success, node)
	var replies: Array = []
	g.gather.gathered.connect(func(r: Dictionary) -> void: replies.append(r))
	var wood0 := _prof("woodcutting")
	var xp0 := int(wood0["skill_xp"])
	var level0 := int(wood0["skill_level"])
	var initial := float(g.gather._remaining["graves_0"])
	var oak_range := _yield_range(_oak_def(), DmCombatData.truthy(oak.get("rich")))
	check(initial >= oak_range[0] and initial <= oak_range[1], "a rich %s holds its type's range times the rich factor (%d, %d to %d)" % [_oak_def()["name"], int(initial), int(oak_range[0]), int(oak_range[1])])
	await _go(_node_pos(oak) + Vector3(7.0, 0.0, 0.0))
	events.clear()
	g.input._primary_click(_screen_of(oak))
	check(loop.active and loop.phase == "walk" and String(loop.node["id"]) == "graves_0", "a click on the node starts walking to it (%s)" % loop.status)
	check(events.any(func(e: Array) -> bool: return e[0] == "gather_started" and bool(e[1].get("rich", false))), "the counsel hears gather_started, rich")
	await ticks(8)   # the gather node's own 10 Hz tick draws the ring
	check(g.gather.views._selected.visible, "the selected ring marks it")
	var arrived := await until(func() -> bool: return loop.working, 60 * 20)
	var reach: float = float(DmSimData.NODE_REACH["tree"])
	check(arrived and DmSimMath.hypot(hero.position.x - float(oak["x"]), hero.position.z - float(oak["z"])) <= reach + 0.5, "the hero walks to the ring and starts working (%.2f m from the tree, reach %.1f)" % [DmSimMath.hypot(hero.position.x - float(oak["x"]), hero.position.z - float(oak["z"])), reach])
	var started := Engine.get_physics_frames()
	var cycle_s := float(_oak_def()["ticks"]) * float(DmGathering.TICK_MS) / 1000.0
	await until(func() -> bool: return cycle_log.size() >= 1, 60 * int(cycle_s + 6.0))
	var frames: int = cycle_log[0][0] - started
	check(absi(frames - int(round(cycle_s * 60.0))) <= 2, "a work cycle takes ticks x the tick: %d frames for %.1f s" % [frames, cycle_s])
	check(not bool(cycle_log[0][1]), "(the first cycle failed for feel)")
	await until(func() -> bool: return loop.working and loop.progress > 0.3, 60 * int(cycle_s + 3.0))
	await ticks(2)
	check(g.gather.views._arc.visible and g.gather.views._arc.position.distance_to(Vector3(hero.position.x, 0.05, hero.position.z)) < 0.01, "the progress arc runs under the hero (%.0f %% of the cycle)" % (loop.progress * 100.0))
	# on until the node is spent: every later cycle succeeds, one off the yield each
	var spent := await until(func() -> bool: return g.gather.depleted.has("graves_0"), 60 * int(cycle_s * (initial + 2.0) + 10.0))
	var successes := cycle_log.filter(func(c: Array) -> bool: return bool(c[1])).size()
	check(spent and successes == int(initial), "the node is spent after exactly its yield in successes (%d of %d)" % [successes, int(initial)])
	check(not g.gather.node_live("graves_0") and g.gather.node_tip_text(oak).contains("Spent. It will return soon."), "its card says it is spent")
	var holder: Node3D = g.gather.views._props["graves_0"]
	var live_hidden := true
	for k in g.gather.views._live_kids["graves_0"]:
		live_hidden = live_hidden and not (k as Node3D).visible
	var spent_shown: Node3D = g.gather.views._spent.get("graves_0")
	check(live_hidden and spent_shown != null and spent_shown.visible and spent_shown.get_child_count() > 0, "its model swaps to the spent stump (%d parts)" % (spent_shown.get_child_count() if spent_shown != null else -1))
	check(holder.get_parent().get_parent().name == "area_graves" and holder.scale.is_equal_approx(Vector3.ONE * 1.12), "(the prop is the area scene's own, a rich node a little bigger)")
	await until(func() -> bool: return loop.phase == "wait", 30)
	check(loop.active and loop.phase == "wait", "Auto waits beside it for the respawn (%s)" % loop.status)
	var respawn_s := float(DmSimData.NODES[String(oak["type"])]["respawnS"]) * DmSimData.RICH_RESPAWN
	var gone_at := Engine.get_physics_frames()
	var back := await until(func() -> bool: return g.gather.node_live("graves_0"), 60 * int(respawn_s + 20.0))
	var gone_frames := Engine.get_physics_frames() - gone_at
	check(back and absi(gone_frames - int(round(respawn_s * 60.0))) <= 30, "a rich node comes back after half its respawn time (%d frames for %.0f s)" % [gone_frames, respawn_s])
	var kids_back := true
	for k in g.gather.views._live_kids["graves_0"]:
		kids_back = kids_back and (k as Node3D).visible
	check(kids_back and not spent_shown.visible, "its model is back and the stump gone")
	check(float(g.gather._remaining["graves_0"]) >= oak_range[0] and float(g.gather._remaining["graves_0"]) <= oak_range[1], "it holds a new yield (%d)" % int(g.gather._remaining["graves_0"]))
	await until(func() -> bool: return loop.working, 60 * 5)
	check(loop.working, "the hero is working it again")
	# stop: the last cycles go to the server, which answers
	g.gather.stop_gathering("moved")
	check(not loop.active and not g.gather.views._selected.visible, "stopping clears the selection")
	await until(func() -> bool: return not loop._in_flight and not loop._pending and loop._queue.is_empty(), 60 * 5)
	var cycles := cycle_log.size()
	var accepted := 0
	for r: Dictionary in replies:
		accepted += int(r["accepted"])
	check(not replies.is_empty() and accepted == cycles, "the server accepted every cycle sent: %d of %d, in %d batches" % [accepted, cycles, replies.size()])
	var found := 0
	var xp_total := 0
	for r: Dictionary in replies:
		xp_total += int(r["xp"])
		for it: Dictionary in r["items"]:
			if String(it["itemId"]) == String(_oak_def()["item"]):
				found += int(it["qty"])
	check(found == cycles and found == _server_qty(String(_oak_def()["item"])) and found == _bag_qty(String(_oak_def()["item"])), "the logs are the server's finds, one for each cycle it rolled (%d), in the server's bag and in the client's" % found)
	var wood := _prof("woodcutting")
	var gained := _xp_between(level0, xp0, int(wood["skill_level"]), int(wood["skill_xp"]))
	check(gained == xp_total and xp_total == int(_oak_def()["xp"]) * int(replies.map(func(r: Dictionary) -> int: return int(r["successes"])).reduce(func(a: int, b: int) -> int: return a + b, 0)), "the XP is the server's: %d per success it rolled (%d)" % [int(_oak_def()["xp"]), xp_total])
	check(g.gather.skills.level("woodcutting") == int(wood["skill_level"]) and int(g.ui.skills["woodcutting"]) == int(wood["skill_level"]), "the client's skill follows the server's row (level %d)" % int(wood["skill_level"]))
	check(int(g.ui_host.prog.chronicle.view()["life"].get("gathered.woodcutting", 0)) == found, "the Chronicle counted the finds (gathered.woodcutting %d)" % found)
	check(events.any(func(e: Array) -> bool: return e[0] == "float" and String(e[1].get("kind", "")) == "skill" and String(e[1]["text"]).contains("%s XP" % DmGatherData.get_data()["skills"]["woodcutting"]["name"])), "the XP floats over the hero")


## The XP a profession gained between two (level, xp) states, under the level x 50 rule.
func _xp_between(l0: int, x0: int, l1: int, x1: int) -> int:
	var total := x1 - x0
	for l in range(l0, l1):
		total += DmGathering.xp_to_next(l)
	return total


# ------------------------------------------------------------------------------------------------------------------ the stops

## Starts the oak and waits until the loop has the hero in hand (working or waiting), so a stop has something to stop.
func _start_oak() -> void:
	g.gather.click_node(_node("graves_0"))
	await until(func() -> bool: return g.gather.loop.phase != "walk" or not g.gather.loop.active, 60 * 15)


func _the_stops() -> void:
	var loop: DmGatherLoop = g.gather.loop
	var oak := _node("graves_0")
	await _go(_node_pos(oak) + Vector3(2.5, 0.0, 0.0))
	await _start_oak()
	check(loop.active, "(gathering again)")
	Input.action_press(&"dm_move_left")
	await ticks(8)
	Input.action_release(&"dm_move_left")
	check(not loop.active, "a walk by hand (WASD) stops the work")
	await _start_oak()
	g.input.click_move(hero.position + Vector3(0.0, 0.0, 4.0))
	check(not loop.active, "a click on the ground stops it")
	await _go(_node_pos(oak) + Vector3(2.5, 0.0, 0.0))
	await _start_oak()
	g.ui.toggle_panel("inventory")
	check(not loop.active, "opening a panel stops it")
	g.ui.close_panels()
	await _start_oak()
	g.ui_host._on_hotbar(1, hero.position + Vector3(4.0, 0.0, 0.0), 0)
	check(not loop.active, "casting a rite stops it")
	await _start_oak()
	hero.take_damage(1.0e7, 0, "melee")
	await ticks(8)
	check(not hero.alive and not loop.active, "death stops it")
	await until(func() -> bool: return hero.alive, 60 * 8)
	await ticks(3)
	# Auto off: a spent node ends the work with the rules' words
	var s: Dictionary = g.ui_host.settings.duplicate()
	s["auto_gather"] = false
	g.ui_host.apply_settings(s)
	await _go(_node_pos(oak) + Vector3(2.5, 0.0, 0.0))
	await until(func() -> bool: return g.gather.node_live("graves_0"), 60 * 10)
	g.gather._remaining["graves_0"] = 2.0   # (a short yield, so the test does not wait on the roll)
	loop.hooks["rand"] = func() -> float: return 0.0
	events.clear()
	await _start_oak()
	var spent := await until(func() -> bool: return not loop.active, 60 * 30)
	check(spent and events.any(func(e: Array) -> bool: return e[0] == "float" and String(e[1]["text"]) == "The %s is spent." % _oak_def()["name"]), "Auto off: the work ends with \"The %s is spent.\"" % _oak_def()["name"])
	s["auto_gather"] = true
	g.ui_host.apply_settings(s)
	await until(func() -> bool: return not loop._in_flight and loop._queue.is_empty(), 60 * 5)


# ------------------------------------------------------------------------------------------------------------------ the server decides

## A batch sent by hand (the loop's own flush), so the test chooses the server's dice.
func _send(type: String, cycles: int) -> void:
	g.gather.loop._queue[type] = cycles
	await g.gather.loop.flush()


func _the_server_decides() -> void:
	var loop: DmGatherLoop = g.gather.loop
	# the client never mints: cycles the client rolled as failures, none confirmed, still pay what the server rolls
	jump_ms += 60_000
	var extras: Array = _oak_def()["extras"]
	var charms: Array = []   # the extras a pet is adopted with
	for pet in DmContent.get_export("cosmetics", "PETS"):
		charms.append(pet["charm"])
	seed_id = ""
	var charm_found := false
	for ex: Dictionary in extras:
		if seed_id == "" and String(ex["item"]).begins_with("seed_"):
			seed_id = String(ex["item"])
		charm_found = charm_found or charms.has(ex["item"])
	check(seed_id != "" and charm_found, "the oak's extras hold a seed and a pet's charm (%s)" % seed_id)
	var seed_name := String(DmContent.item(seed_id)["name"])
	var logs0 := _server_qty("log_oak")
	var moss0 := _server_qty(seed_id)
	events.clear()
	mock.rng = func() -> float: return 0.0   # every server roll lands, every extra drops
	var few := mini(3, DmGathering.GATHER_BURST)   # (cycles the server's burst takes whole)
	await _send("coffin_oak", few)
	check(_server_qty("log_oak") == logs0 + few and _bag_qty("log_oak") == _server_qty("log_oak"), "%d cycles, the server's dice: %d logs in its bag and in ours (%d)" % [few, few, _bag_qty("log_oak")])
	check(_server_qty(seed_id) == moss0 + few, "and the extras it rolled (a seed each)")
	var toasts := events.filter(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]).begins_with("Found: "))
	check(toasts.any(func(e: Array) -> bool: return String(e[1]["text"]) == "Found: %s%s" % [seed_name, (" ×%d" % few) if few > 1 else ""]), "the extras are announced (Found: ...)")
	check(events.any(func(e: Array) -> bool: return e[0] == "banner" and String(e[1].get("title", "")) == "A rare find!"), "a charm raises the rare-find banner")
	# a level: one XP short of the next, one more success
	var wood_name := String(DmGatherData.get_data()["skills"]["woodcutting"]["name"])
	var wood := _prof("woodcutting")
	wood["skill_level"] = 1
	wood["skill_xp"] = DmGathering.xp_to_next(1) - 1
	g.gather.skills.adopt([wood.duplicate()])
	events.clear()
	jump_ms += 60_000
	mock.rng = func() -> float: return 0.0
	await _send("coffin_oak", 1)
	var up := _event_ids()
	check(int(_prof("woodcutting")["skill_level"]) == 2 and g.gather.skills.level("woodcutting") == 2 and int(g.ui.skills["woodcutting"]) == 2, "the server's level-up reaches the client (level 2)")
	check(events.any(func(e: Array) -> bool: return e[0] == "banner" and String(e[1].get("title", "")) == "%s 2" % wood_name) and up.has("skill_up"), "the banner \"%s 2\" and the counsel's skill_up" % wood_name)
	# the burst: a full batch of cycles at once, the burst accepted (the server's time budget); a spent hour is refused in the server's words and nothing is paid
	var replies: Array = []
	var on_reply := func(r: Dictionary) -> void: replies.append(r)
	g.gather.gathered.connect(on_reply)
	jump_ms += 1
	var logs1 := _server_qty("log_oak")
	await _send("coffin_oak", DmGathering.GATHER_MAX_BATCH)
	g.gather.gathered.disconnect(on_reply)
	check(replies.size() == 1 and int(replies[0]["accepted"]) == DmGathering.GATHER_BURST and _server_qty("log_oak") == logs1 + DmGathering.GATHER_BURST, "%d cycles in one go: the server accepts the burst of %d and pays for those" % [DmGathering.GATHER_MAX_BATCH, DmGathering.GATHER_BURST])
	var ledger: Dictionary = _acc()["gatherLedger"]
	ledger["hourStart"] = game_ms()
	ledger["hourActions"] = DmGathering.GATHER_MAX_ACTIONS_PER_HOUR
	jump_ms += 60_000
	events.clear()
	var logs2 := _server_qty("log_oak")
	await _send("coffin_oak", 3)
	var hands := events.filter(func(e: Array) -> bool: return e[0] == "toast" and String(e[1].get("kind", "")) == "err")
	check(not hands.is_empty() and String(hands[-1][1]["text"]) == "Your hands are spent for this hour. Rest, then gather again." and _server_qty("log_oak") == logs2 and loop._queue.is_empty(),
		"a spent hour is refused in the server's words, nothing is paid and the cycles are dropped (%s)" % (str(hands[-1][1]["text"]) if not hands.is_empty() else ""))
	ledger["hourActions"] = 0
	jump_ms += 60_000
	var cid := int(g.character["id"])
	var none: DmResult = await api.gather(cid, "coffin_oak", 0, false)
	check(not none.ok and none.error == "Nothing to gather", "no cycles: refused in the server's words (%s)" % none.error)
	var gated_type := ""
	for n: Dictionary in g.gather.nodes.values():
		var nd := DmGathering.node_def(String(n["type"]))
		if int(nd["level"]) > int(_prof("gravedigging").get("skill_level", 1)) and String(nd["skill"]) == "gravedigging":
			gated_type = String(n["type"])
			break
	var row_level := int(_prof("gravedigging").get("skill_level", 1))
	var words := DmGathering.gather_blocker(gated_type, row_level)
	var gated: DmResult = await api.gather(cid, gated_type, 3, false)
	check(words != "" and not gated.ok and gated.error == words, "the level gate also holds on the server: '%s'" % gated.error)
	mock.rng = server_rolls_default
	jump_ms += 60_000


# ------------------------------------------------------------------------------------------------------------------ the laborers, outside the Acre

## Laborers on posts (the server's rows), the hero away from the Acre: no model exists, nothing is built, fetched or updated. The skills are raised from 30 / 30 / 30 / 20 only as far as the
## rules need for a slot to every post.
func _laborers_outside_the_acre() -> void:
	var cid := int(g.character["id"])
	var rows: Array = _acc()["professions"]
	var levels := {"woodcutting": 30, "mining": 30, "gravedigging": 30, "fishing": 20}
	while DmLabor.labor_slots(DmLabor.total_gather_level(levels)) < POSTS.size() and int(levels["woodcutting"]) < DmGathering.LEVEL_CAP - 1:
		for skill: String in levels:
			levels[skill] = int(levels[skill]) + 1
	for skill: String in levels:
		var row := _prof(skill)
		if row.is_empty():
			row = {"profession_id": skill, "skill_level": 1, "skill_xp": 0}
			rows.append(row)
		row["skill_level"] = levels[skill]
		row["skill_xp"] = 0
	var got: DmResult = await api.get_professions(cid)
	g.gather.skills.adopt(got.data)
	laborer_slots = DmLabor.labor_slots(DmLabor.total_gather_level(levels))
	check(laborer_slots >= POSTS.size(), "(levels %s command %d laborers, a slot for each of the %d posts)" % [str(levels.values()), laborer_slots, POSTS.size()])
	for slot: int in POSTS:
		g.ui.pb.labor.assign_requested.emit(slot, POSTS[slot])
	await until(func() -> bool: return String(_acc().get("labor", {}).get(str(POSTS.size() - 1), {}).get("nodeType", "")) == String(POSTS[POSTS.size() - 1]), 60 * 3)
	check(_acc()["labor"].size() == POSTS.size(), "%d laborers hold posts on the server (%s)" % [POSTS.size(), str(POSTS.values())])
	var views: DmLaborerViews = g.acre.views
	await _go(_node_pos(_node("graves_0")))
	g.acre.labor.check_labor(false)   # (the 5 min check, run now: it hands the view to the laborer views)
	await ticks(10)
	check(views.view != null and not views.active and not views.visible and views.byslot.is_empty() and views.get_child_count() == 0 and views.list.is_empty(),
		"outside the Acre the laborers have a view of the server's rows and no model, node or update at all")
	check(g.ui.labor_summary != null and int(g.ui.labor_summary["assigned"]) == POSTS.size() and int(g.ui.labor_summary["unlocked"]) == laborer_slots, "the guidance has the labor summary (%s)" % str(g.ui.labor_summary))


# ------------------------------------------------------------------------------------------------------------------ AFK

func _afk() -> void:
	var host := g.ui_host
	events.clear()
	var why: String = await host.start_afk("seam_copper")
	check(why == "Visit the Sexton’s Acre for safe AFK gathering." and not host.afk_active(), "AFK outside the Acre is refused in the rules' words (%s)" % why)
	await _go(_area_mid("acre"))
	await until(func() -> bool: return g.area_id == "acre", 60 * 3)
	check(g.area_id == "acre" and g.acre.views.active and g.acre.views.visible, "the hero is in the Acre and the laborers wake")
	var loop: DmGatherLoop = g.gather.loop
	var replies: Array = []
	g.gather.gathered.connect(func(r: Dictionary) -> void: replies.append(r))
	# a first session, from the Skills tab's button; any panel but the Skills tab ends it
	events.clear()
	var copper_before := _server_qty("ore_copper")
	g.ui.pb.professions.start_afk_requested.emit("seam_copper")
	await until(func() -> bool: return host.afk_active(), 60 * 5)
	check(host.afk_active() and host.afk_status()["allowed"] and String(loop.node["type"]) == "seam_copper" and String(loop.node["area"]) == "acre", "AFK from the Skills tab works the nearest copper seam of the Acre (%s)" % loop.status)
	check(events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]).begins_with("AFK gathering started")) and g.gather.session != null, "and says so; the report starts")
	g.gather.session.started_at -= 120_000.0   # (the report counts wall seconds; a run at --fixed-fps has fewer, so a session starts two minutes earlier)
	var worked := await until(func() -> bool: return replies.size() >= 2, 60 * 90)
	check(worked and loop.afk, "AFK goes on across batches and nodes (%d answers)" % replies.size())
	g.ui.toggle_panel("professions")
	await ticks(10)
	var prof_panel: DmProfessionsPanel = g.ui.pb.professions
	check(g.ui.is_open("professions") and host.afk_active() and int(prof_panel.skills["mining"]["level"]) == int(_prof("mining")["skill_level"]), "the Skills tab opens without ending AFK, with the server's levels (mining %d)" % int(_prof("mining")["skill_level"]))
	g.ui.close_panels()
	events.clear()
	g.ui.toggle_panel("inventory")
	check(not host.afk_active(), "any other panel ends it")
	await until(func() -> bool: return g.gather.session == null, 60 * 5)
	_afk_report(copper_before, "panel")
	g.ui.close_panels()
	# a second session ended by the Skills tab's pause button
	events.clear()
	copper_before = _server_qty("ore_copper")
	why = await host.start_afk("seam_copper")
	check(why == "" and host.afk_active() and g.gather.session != null, "(AFK again)")
	g.gather.session.started_at -= 120_000.0
	var more := replies.size()
	await until(func() -> bool: return replies.size() >= more + 2, 60 * 90)
	check(_server_qty("ore_copper") > copper_before and _server_qty("ore_copper") == _bag_qty("ore_copper"), "the copper is the server's finds, in both bags (%d)" % (_server_qty("ore_copper") - copper_before))
	events.clear()
	g.ui.pb.professions.pause_afk_requested.emit()
	await until(func() -> bool: return g.gather.session == null, 60 * 5)
	_afk_report(copper_before, "moved")
	check(not host.afk_active() and not loop.afk, "AFK is over")
	g.ui.close_panels()
	var key := "dm_gather_best_v1:%d" % int(g.character["id"])
	check(g.progress.store.get_item(key) != "" and g.gather.bests.has("mining"), "the best session is kept under the original key")


## The report an AFK session ended with (`events` holds it): why it ended, how long it worked, and that its finds add up to what the server paid since `copper_before`.
func _afk_report(copper_before: int, reason: String) -> void:
	var rep: Array = events.filter(func(e: Array) -> bool: return e[0] == "gather_report")
	check(not rep.is_empty() and String(rep[0][1]["report"]["reason"]) == reason and int(rep[0][1]["report"]["seconds"]) >= 20, "ending it (%s) shows the AFK report" % reason)
	if rep.is_empty():
		return
	var r: Dictionary = rep[0][1]["report"]
	var total := 0
	var copper := 0
	for it: Dictionary in r["items"]:
		total += int(it["qty"])
		if String(it["itemId"]) == "ore_copper":
			copper += int(it["qty"])
	check(total == int(r["totalItems"]) and total > 0 and String(r["skills"][0]["skill"]) == "mining" and copper == _server_qty("ore_copper") - copper_before, "the report adds up what the server paid (%d copper of %d finds)" % [copper, total])
	check(g.ui.pb.report.window.visible, "and the report window is open")


# ------------------------------------------------------------------------------------------------------------------ the laborers, in the Acre

func _the_laborers() -> void:
	var views: DmLaborerViews = g.acre.views
	var n_posts := POSTS.size()
	await until(func() -> bool: return views.byslot.size() == n_posts and views.picks.size() == n_posts, 60 * 20)
	check(views.byslot.size() == n_posts and views.picks.size() == n_posts, "in the Acre the laborers stand at their %d posts, models loaded (%d, %d pickable)" % [n_posts, views.byslot.size(), views.picks.size()])
	check(views.get_child_count() <= DmLabor.MAX_SLOTS and views.get_child_count() == n_posts, "the laborers are pooled models, one per post and the rules' most at most (%d)" % views.get_child_count())
	var acre_rect: Dictionary = DmContent.area("acre")["rect"]
	var placed := true
	for l: DmLaborerViews.Laborer in views.list:
		placed = placed and g.world.area_at(float(l.spot["x"]), float(l.spot["z"])) == "acre" and l.c.root.visible
	check(placed, "each stands in the Acre")
	# the Sexton is met once, while no work waits
	g.chapterhouse.talk_to("sexton")
	var met_lines: Array = g.ui.dialogue.lines.duplicate()
	g.ui.dialogue.close()
	check(met_lines.size() == 2 and String(met_lines[0]).begins_with("Mind the graves, they are tended."), "(the Sexton introduces himself: %s)" % str(met_lines))
	# hover a laborer: his card, and a click opens the Laborers
	await ticks(30)
	var l: DmLaborerViews.Laborer = views.byslot[0]
	var at: Vector2 = g.camera.unproject_position(Vector3(float(l.spot["x"]), 1.0, float(l.spot["z"])))
	check(g.acre.pick_laborer(at, 52.0) == 0, "the laborer under the cursor is found by the screen pick")
	check(g.acre.pick_laborer(at + Vector2(400, 400), 52.0) == -1, "...and none far from it")
	await until(func() -> bool: return views.debug().any(func(d: Dictionary) -> bool: return d["mode"] == "work"), 60 * 6)
	check(views.debug().any(func(d: Dictionary) -> bool: return d["visible"] and d["mode"] == "work"), "laborers work their posts (%s)" % str(views.debug().map(func(d: Dictionary) -> String: return str(d["mode"]))))
	g.gather.hover_at(at, false)
	check(g.gather.hover == null and views.hover_slot == 0 and g.ui.hud.node_tip_box.visible, "a laborer nearer than a node wins the hover: no node ring, his card shows")
	var tip := views.tip(0)
	check(tip.contains("Grave Laborer") and tip.contains("Woodcutting") and tip.contains("click to open the Laborers (H)") and tip.contains("Coffin-Oak"), "his card: skill, how long, state, post (%s)" % tip.replace("<b>", "").replace("</b>", " ").replace("<div>", "").replace("</div>", ""))
	g.gather.hover_at(Vector2(2.0, 2.0), false)
	check(views.hover_slot == -1, "the cursor away: his glow goes")
	g.input._primary_click(at)
	check(g.ui.is_open("labor"), "a click on a laborer opens the Laborers (H)")
	g.ui.close_panels()
	# away: his models stay, nothing runs
	await _go(_node_pos(_node("graves_0")))
	await ticks(5)
	check(not views.active and not views.visible and views.hover_slot == -1, "leaving the Acre puts the laborers to sleep (hidden, no update)")
	# hours of work: well past the time a laborer counts as ready, short of the cap
	jump_ms += mini(int(DmGuidance.LABOR_READY_MS * 6.0), DmLabor.CAP_MS / 2)
	await _go(_area_mid("acre"))
	await until(func() -> bool: return views.active and views.view != null and views.list.all(func(x: DmLaborerViews.Laborer) -> bool: return x.ready), 60 * 5)
	check(views.list.all(func(x: DmLaborerViews.Laborer) -> bool: return x.ready) and views.list.all(func(x: DmLaborerViews.Laborer) -> bool: return x.marker.visible), "back in the Acre the view is read again: every laborer has work waiting, a badge over each")
	events.clear()
	g.acre.labor.check_labor(true)
	await until(func() -> bool: return events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]).begins_with("Your laborers have gathered about")), 60 * 3)
	check(events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]).begins_with("Your laborers have gathered about") and String(e[1]["text"]).ends_with("finds (H)")), "on arrival: \"Your laborers have gathered about N finds (H)\"")
	check(int(g.ui.labor_summary["ready"]) == n_posts, "the guidance knows all %d are ready" % n_posts)
	# the Sexton says so
	g.chapterhouse.talk_to("sexton")
	var lines: Array = g.ui.dialogue.lines
	check(g.ui.dialogue.is_open() and lines.size() == 1 and String(lines[0]) == "Your laborers have been busy. There is work waiting on them: press H and collect it.", "the Sexton: \"Your laborers have been busy...\" (%s)" % str(lines))
	g.ui.dialogue.close()
	# collecting: the gravedigger pays gold, the finds go in the bag and the Chronicle, the report hangs under the laborer
	var gold0 := int(_acc()["character"]["gold"])
	var life0 := int(g.ui_host.prog.chronicle.view()["life"].get("gathered.gravedigging", 0))
	var bones0 := _server_qty("bones_old")
	var xp0 := _xp_total("gravedigging")
	g.ui.toggle_panel("labor")
	await ticks(5)
	events.clear()
	g.ui.pb.labor.collect_requested.emit(n_posts - 1)
	await until(func() -> bool: return not g.ui.pb.labor.loot.is_empty(), 60 * 5)
	var rep: Dictionary = g.ui.pb.labor.loot[0]["report"] if not g.ui.pb.labor.loot.is_empty() else {}
	var found := _server_qty("bones_old") - bones0
	check(not rep.is_empty() and int(rep["slot"] if rep.has("slot") else n_posts - 1) == n_posts - 1 and found > 0 and int(rep["totalItems"]) >= found, "the finds are in the server's bag and in the report under the laborer (%d bones, %d finds)" % [found, int(rep.get("totalItems", -1))])
	var gold_paid := int(_acc()["character"]["gold"]) - gold0
	check(gold_paid > 0 and int(g.character["gold"]) == int(_acc()["character"]["gold"]) and float(rep["gold"]) == float(gold_paid), "the server paid the gold (%d) and the client's purse is the server's" % gold_paid)
	check(int(g.ui_host.prog.chronicle.view()["life"].get("gathered.gravedigging", 0)) - life0 == int(rep["totalItems"]), "the Chronicle counted the finds (gathered.gravedigging +%d)" % int(rep["totalItems"]))
	check(_xp_total("gravedigging") - xp0 == int(rep["skills"][0]["xp"]) and _bag_qty("bones_old") == _server_qty("bones_old"), "the XP is the server's (+%d), and the bag follows the server" % int(rep["skills"][0]["xp"]))
	await ticks(60 * 1)
	check(views.list.any(func(x: DmLaborerViews.Laborer) -> bool: return x.slot == n_posts - 1 and not x.ready), "after the panel collected, the posts refresh: his badge is gone (the others still wait)")
	g.ui.close_panels()


## Total XP a profession holds on the server, counted from level 1.
func _xp_total(skill: String) -> int:
	var row := _prof(skill)
	return 0 if row.is_empty() else _xp_between(1, 0, int(row["skill_level"]), int(row["skill_xp"]))


# ------------------------------------------------------------------------------------------------------------------ the garden and the contracts

func _the_garden_and_contracts() -> void:
	var cid := int(g.character["id"])
	var garden: DmGardenPanel = g.ui.pb.garden
	check(_server_qty(seed_id) > 0, "(a seed in the bag)")
	var seed_row: Dictionary = {}   # the seed's growing rules, and the first plot of its kind
	for sr: Dictionary in DmContent.get_export("gardening", "SEEDS"):
		if sr["id"] == seed_id:
			seed_row = sr
	var plot_id := ""
	for pl: Dictionary in DmContent.get_export("gardening", "PLOTS"):
		if plot_id == "" and pl["kind"] == seed_row["kind"]:
			plot_id = String(pl["id"])
	g.ui.toggle_panel("garden")
	await ticks(5)
	events.clear()
	var xp0 := _xp_total("gardening")
	garden.plant_requested.emit(plot_id, seed_id, false)
	await until(func() -> bool: return _acc().get("garden", {}).has(plot_id), 60 * 3)
	await ticks(5)
	var row: Dictionary = _acc()["garden"][plot_id]
	var grow_ms := int(seed_row["growMin"]) * 60000
	check(String(row["seedId"]) == seed_id and int(row["readyAt"]) - int(row["plantedAt"]) == grow_ms, "planting is the server's: the plot grows for %d minutes" % int(seed_row["growMin"]))
	check(_xp_total("gardening") - xp0 == int(seed_row["plantXp"]) and g.gather.skills.level("gardening") == 1, "the server paid the planting XP (+%d)" % int(seed_row["plantXp"]))
	events.clear()
	g.acre.labor.check_garden(true)
	await until(func() -> bool: return events.any(func(e: Array) -> bool: return e[0] == "toast"), 60 * 3)
	check(events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]) == "1 plot is still growing in your garden (U)"), "on arrival: \"1 plot is still growing in your garden (U)\"")
	# a little over the growing time later: ready, the notice, the harvest
	jump_ms += grow_ms + 5 * 60_000
	events.clear()
	g.acre.labor.check_garden(false)
	await until(func() -> bool: return events.any(func(e: Array) -> bool: return e[0] == "toast"), 60 * 3)
	check(events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]) == "1 plot is ready in your garden (U)"), "as plots come ready: \"1 plot is ready in your garden (U)\"")
	var gardening := _prof("gardening")
	gardening["skill_xp"] = DmGathering.xp_to_next(int(gardening["skill_level"])) - 1   # (so the harvest's XP is a level)
	var harvest_id := String(seed_row["harvest"])
	var harvest_name := String(DmGatherData.item_meta(harvest_id)["name"])
	var garden_name := String(DmGatherData.get_data()["skills"]["gardening"]["name"])
	var moss0 := _server_qty(harvest_id)
	events.clear()
	garden.harvest_requested.emit(plot_id)
	await until(func() -> bool: return _server_qty(harvest_id) > moss0 and events.any(func(e: Array) -> bool: return e[0] == "banner"), 60 * 5)
	var crop := _server_qty(harvest_id) - moss0
	check(crop >= int(seed_row["yields"][0]) and crop <= int(seed_row["yields"][1]) and events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]).begins_with("Harvested %d× %s" % [crop, harvest_name])), "the harvest is the server's roll (%d x %s) and is announced" % [crop, harvest_name])
	check(events.any(func(e: Array) -> bool: return e[0] == "banner" and String(e[1].get("title", "")) == "%s 2" % garden_name), "the level: \"%s 2\"" % garden_name)
	check(g.gather.skills.level("gardening") == 2 and int(g.ui_host.prog.chronicle.view()["life"].get("gathered.gardening", 0)) == crop, "the client's gardening is the server's (level 2) and the Chronicle counted the crop")
	g.ui.close_panels()
	# a contract of the Sexton's board
	var board: DmResult = await api.get_contracts(cid)
	var c: Dictionary = board.data["contracts"][0]
	var free := 0
	var used := {}
	for sl: Dictionary in _acc()["slots"]:
		used[int(sl["slot_index"])] = true
	while used.has(free):
		free += 1
	_acc()["slots"].append({"slot_index": free, "item_id": c["itemId"], "quantity": int(c["qty"]), "equipped": 0})
	await g.ui_host.refresh_inventory()
	g.ui.toggle_panel("contracts")
	await ticks(5)
	var open0 := int(g.ui.contract_summary["open"])
	var gold0 := int(_acc()["character"]["gold"])
	events.clear()
	g.ui.pb.contracts.deliver_requested.emit(0)
	await until(func() -> bool: return events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]).begins_with("Order filled")), 60 * 5)
	var paid := int(_acc()["character"]["gold"]) - gold0
	check(paid == int(c["rewardGold"]) and int(g.character["gold"]) == int(_acc()["character"]["gold"]), "the order is filled: the server paid %dg and the purse is the server's" % paid)
	check(int(g.ui.contract_summary["open"]) == open0 - 1 and int(g.ui_host.prog.chronicle.view()["life"].get("contracts", 0)) == 1, "one order fewer on the board, one in the Chronicle")
	check(int(g.ui.guidance_state()["contracts"]["open"]) == int(g.ui.contract_summary["open"]), "the guidance's summary follows the delivery")
	g.ui.close_panels()
	# the Next box's feeds
	for sk in DmGathering.SKILL_IDS:
		check(int(g.ui.skills.get(sk, 1)) == g.gather.skills.level(sk), "the guidance's %s level is the client's (%d)" % [sk, g.gather.skills.level(sk)])


# ------------------------------------------------------------------------------------------------------------------ the host's rules, the skills and the Sawpit

func _toast_has(part: String) -> bool:
	return events.any(func(e: Array) -> bool: return e[0] == "toast" and String(e[1]["text"]).contains(part))


## The host spends a node only for a hero in reach; a plain node comes back after its own respawn time; each gathering skill pays its own find and XP through the server; and the
## logs gathered here go into the Sawpit's plank.
func _host_rules() -> void:
	var gt := g.gather
	var plain: Dictionary = {}
	for n: Dictionary in gt.nodes.values():
		if n["type"] == "coffin_oak" and n["area"] == "acre" and not DmCombatData.truthy(n.get("rich")):
			plain = n
			break
	var id := String(plain["id"])
	gt.loop.stop("moved")
	await _go(_node_pos(plain))
	gt._remaining[id] = 1.0
	hero.teleport(g.world.nav_clamp(Vector3(float(plain["x"]) + 20.0, 0.0, float(plain["z"]))))
	await ticks(3)
	gt._apply_success(id)
	check(gt.node_live(id), "a success from out of reach is ignored (the host's check)")
	await _go(_node_pos(plain))
	gt._remaining[id] = 1.0
	gt._apply_success(id)
	var respawn_s := float(DmGathering.node_def("coffin_oak")["respawnS"])
	check(gt.depleted.has(id) and absf(float(gt._respawn_at[id]) - gt._clock - respawn_s) < 0.5, "a plain node respawns in its own %d s (respawnS)" % int(respawn_s))
	gt._respawn_at[id] = 0.0
	gt._respawn_due()
	# one success of each other gathering skill, through the server's batch: its find in both bags and the node's XP
	mock.rng = func() -> float: return 0.0
	for ty in ["seam_copper", "pool_still", "grave_pauper"]:
		var dd := DmGathering.node_def(ty)
		var item := String(dd["item"])
		var q0 := _server_qty(item)
		var x0 := _xp_total(String(dd["skill"]))
		jump_ms += 60_000
		await _send(ty, 1)
		check(_server_qty(item) > q0 and _bag_qty(item) == _server_qty(item), "%s: its %s is in the server's bag and in ours" % [ty, item])
		check(_xp_total(String(dd["skill"])) - x0 == int(dd["xp"]), "%s: %s XP +%d" % [ty, dd["skill"], int(dd["xp"])])
	# gather -> craft: the logs of the server's one plank takes, the Sawpit's panel, one plank
	var plank: Dictionary = DmContent.recipe("mill_oak_plank")
	var plank_logs := int(plank["inputs"][0]["qty"])
	jump_ms += 60_000
	await _send("coffin_oak", plank_logs)
	g.ui.close_panels()
	var sawpit: Dictionary = g.chapterhouse.interactables.filter(func(it: Dictionary) -> bool: return it["kind"] == "sawpit")[0]
	await _go(Vector3(float(sawpit["x"]) + 1.2, 0.0, float(sawpit["z"])))   # a station window closes when the hero is a few steps away from it
	g.chapterhouse.interact(sawpit)
	await ticks(3)
	var forge: DmForgePanel = g.ui.pb.forges.get("sawpit")
	check(forge != null and forge.visible, "the Sawpit panel opens")
	var planks0: int = g.ui_host.inventory.count("plank_oak")
	var logs0: int = g.ui_host.inventory.count("log_oak")
	forge.craft_requested.emit("mill_oak_plank", 1)
	await until(func() -> bool: return g.ui_host.inventory.count("plank_oak") > planks0, 60 * 4)
	check(g.ui_host.inventory.count("plank_oak") == planks0 + int(plank["qty"]) and g.ui_host.inventory.count("log_oak") == logs0 - plank_logs, "craft: %d gathered logs -> %d plank (the bag shows %d planks, %d logs)" % [plank_logs, int(plank["qty"]), g.ui_host.inventory.count("plank_oak"), g.ui_host.inventory.count("log_oak")])
	g.ui.close_panels()
	mock.rng = server_rolls_default


# ------------------------------------------------------------------------------------------------------------------ the notices

## The labor and garden notices read the backend's views: a stub answers with the real shapes (a full laborer is announced once until it is emptied; a ready plot once).
func _the_notices() -> void:
	var cid := int(g.character["id"])
	await _go(_area_mid("acre"))
	var stub := StubApi.new()
	stub.real = api
	var lv: Dictionary = (await api.get_labor(cid)).data.duplicate(true)
	var s0: Dictionary = {}
	for sv: Dictionary in lv["slots"]:
		if sv.get("nodeType") != null and String(sv["nodeType"]) != "":
			s0 = sv
			break
	check(not s0.is_empty(), "a laborer holds a post")
	for sv: Dictionary in lv["slots"]:
		sv["capped"] = false
		sv["estItems"] = 0
		sv["elapsedMs"] = 0.0
	s0["elapsedMs"] = 40.0 * 60000.0
	s0["estItems"] = 1234
	s0["capped"] = false
	stub.labor = lv
	stub.garden = (await api.get_garden(cid)).data.duplicate(true)
	stub.contracts = (await api.get_contracts(cid)).data.duplicate(true)
	var acre := g.acre
	var real_api: Variant = acre.api
	acre.api = stub
	events.clear()
	await acre.labor.check_labor(true)
	check(_toast_has("Your laborers have gathered about 1,234 finds (H)"), "arrival: a laborer with 30+ minutes of work reports its finds")
	await ticks(2)
	check(g.ui.guidance_state()["contracts"] != null and int(g.ui.guidance_state()["contracts"]["total"]) == (stub.contracts["contracts"] as Array).size(), "the contract summary feeds the guidance")
	events.clear()
	s0["capped"] = true
	await acre.labor.check_labor(false)
	check(_toast_has("A laborer has filled up"), "a full laborer is announced")
	events.clear()
	await acre.labor.check_labor(false)
	check(not _toast_has("filled up"), "...once, not on every check")
	s0["capped"] = false
	await acre.labor.check_labor(false)
	s0["capped"] = true
	events.clear()
	await acre.labor.check_labor(false)
	check(_toast_has("A laborer has filled up"), "...and again after it was emptied")
	var plots: Array = stub.garden["plots"]
	plots[0]["state"] = "ready"
	events.clear()
	await acre.labor.check_garden(false)
	check(_toast_has("ready in your garden (U)"), "a plot coming ready is announced")
	events.clear()
	await acre.labor.check_garden(false)
	check(not _toast_has("ready in your garden"), "...once")
	acre.api = real_api


# ------------------------------------------------------------------------------------------------------------------ a relaunch

## What was gathered and made is the server's: the next launch of the same character has the levels, the XP and the items again, and every node fresh.
func _relaunch() -> void:
	# leaving or closing mid-gather: a cycle the loop has not sent yet goes with the game's flush (no stop() first; the server may still refuse it on its budget)
	var posts: Array = []
	var post: Callable = g.gather.loop.hooks["post"]
	g.gather.loop.hooks["post"] = func(type: String, actions: int, keepalive: bool, afk_now: bool) -> DmResult:
		posts.append([type, actions])
		return await post.call(type, actions, keepalive, afk_now)
	g.gather.loop._queue["coffin_oak"] = int(g.gather.loop._queue.get("coffin_oak", 0)) + 1
	await g.flush_all()
	g.gather.loop.hooks["post"] = post
	check(g.gather.loop._queued_total() == 0 and posts.has(["coffin_oak", 1]), "leaving mid-gather: the cycle not yet sent goes to the server with the game's flush (%s)" % str(posts))
	g.gather.loop.stop("moved")
	await g.flush_all()
	await g.gather.load_professions()
	var want_wood: Dictionary = g.gather.skills.get_skill("woodcutting")
	var want_mining := int(g.gather.skills.get_skill("mining")["xp"])
	var want_planks: int = g.ui_host.inventory.count("plank_oak")
	await g.leave()
	g.queue_free()
	await process_frame
	await _launch((await api.load_or_create_character(2)).data)
	var back_prof := {}
	for row: Dictionary in (await api.get_professions(int(g.character["id"]))).data:
		back_prof[row["profession_id"]] = row
	check(g.gather.skills.get_skill("woodcutting") == want_wood and int(back_prof["woodcutting"]["skill_level"]) == int(want_wood["level"]), "relaunch: Woodcutting level %d + XP %d kept" % [int(want_wood["level"]), int(want_wood["xp"])])
	check(int(g.gather.skills.get_skill("mining")["xp"]) == want_mining, "relaunch: Mining XP kept")
	check(want_planks >= 1 and g.ui_host.inventory.count("plank_oak") == want_planks and g.ui_host.inventory.count("ore_copper") >= 1, "relaunch: gathered / crafted items are in the bag")
	check(g.gather.depleted.is_empty() and g.gather.nodes.size() == DmData.world()["nodes"].size(), "relaunch: nodes are fresh (state is a session thing)")


# ------------------------------------------------------------------------------------------------------------------ the Next box

## What the first-hour guidance reads (DmGameUi.guidance_state), and the Next box on a full bag.
func _guidance() -> void:
	var ui := g.ui
	var h := g.ui_host
	var cid := int(g.character["id"])
	await _go(_area_mid("acre"))
	var st := ui.guidance_state()
	check(int(st["level"]) == int(h.character["level"]) and st["area"] == "acre" and int(st["bagSize"]) == DmLootData.bag_size(), "state: level / area / bag size %s" % str([st["level"], h.character["level"], st["area"], st["bagSize"]]))
	check(st["unlocked"] == h.progress["unlocked"] and int(st["totalKills"]) == int(h.progress["totalKills"]), "state: seals and kills come from the progression")
	var ak0 := int(st["areaKills"].get("graves", 0))
	var m: DmRewardsMember = g.rewards.members[cid]
	for i in 30:   # (a hero past the first steps)
		m.prog.record_kill("graves")
	check(int(ui.guidance_state()["areaKills"].get("graves", 0)) == ak0 + 30, "state: kills count in areaKills at once")
	check(not st["prelateThisRun"], "state: the Prelate is not slain yet")
	h.progress["run"]["prelateKills"] = 1   # (the backend clamps a recorded kill by the pending summons; the state just reads it)
	check(ui.guidance_state()["prelateThisRun"], "state: a Prelate kill reaches prelateThisRun")
	check(ui.guidance_state()["bossesBeaten"].is_empty(), "state: no area boss beaten yet")
	g.chron.claim_trophy("gravedigger")
	check(ui.guidance_state()["bossesBeaten"] == ["gravedigger"], "state: a first kill reaches bossesBeaten (the backend's trophy)")
	g.chron.claim_trophy("gravedigger")
	check(ui.guidance_state()["bossesBeaten"] == ["gravedigger"], "state: ...and only once")
	# a level gained gathering is in the state without opening the Professions panel
	var rows: Array = (await api.get_professions(cid)).data.duplicate(true)
	var lvl_before := int(ui.guidance_state()["skills"].get("woodcutting", 1))
	for row: Dictionary in rows:
		if row["profession_id"] == "woodcutting":
			row["skill_level"] = lvl_before + 3
	g.gather.skills.adopt(rows)
	check(int(ui.guidance_state()["skills"]["woodcutting"]) == lvl_before + 3, "state: a gathering level reaches the skills (%d)" % (lvl_before + 3))
	# the first brew
	var brew := ""
	for bid in DmContent.brews():
		if String(DmContent.brews()[bid].get("slot", "")) == "elixir":
			brew = String(bid)
			break
	events.clear()
	await DmTestBag.give(h.inventory, {"item_id": brew, "quantity": 2})
	await h.inventory.flush()
	await h.refresh_inventory()
	h.set_belt("elixir", brew)
	h.use_belt("elixir")
	check(_event_ids().has("brew_drunk"), "drinking a brew raises brew_drunk (the counsel's first-brew tip)")
	# a full bag: the Next box suggests the Bone Grinder; a dismissal holds while the state is unchanged; the setting clears the box
	await _go(Vector3(0.0, 0.0, 18.0))
	var junk: Array = []
	for iid in DmContent.items():
		if String(DmContent.items()[iid].get("type", "")) in ["weapon", "chest_armor", "helm", "boots"] and String(DmContent.items()[iid].get("rarity", "")) == "common":
			junk.append(String(iid))
	var bag_size := DmLootData.bag_size()
	var need := bag_size - int(ui.guidance_state()["bagUsed"])
	for i in need:
		await DmTestBag.give(h.inventory, {"item_id": junk[i % junk.size()], "quantity": 1})
	await h.inventory.flush()
	await h.refresh_inventory()
	check(int(ui.guidance_state()["bagUsed"]) >= bag_size - 4, "the bag is nearly full (%d / %d)" % [int(ui.guidance_state()["bagUsed"]), bag_size])
	check(await until(func() -> bool: return ui.guidance_hud.current != null and String(ui.guidance_hud.current["id"]) == "bag-full", 60 * 3), "the Next box suggests the Bone Grinder with a full bag")
	var shown_id := String(ui.guidance_hud.current["id"]) if ui.guidance_hud.current != null else ""
	ui.guidance_hud.dismiss()
	await ticks(2)
	ui._guide_t = 0.0
	await until(func() -> bool: return ui._guide_t > 0.0, 60 * 2)
	check(ui.guidance_hud.current == null or String(ui.guidance_hud.current["id"]) != shown_id, "dismissing the Next box holds while the state is unchanged")
	h.settings_store.values["guidance"] = false
	await until(func() -> bool: return ui.guidance_hud.current == null, 60 * 3)
	check(ui.guidance_hud.current == null, "...and turning the guidance off clears the Next box")
	h.settings_store.values["guidance"] = true
	# the junk is sold by the server (a client never takes items out of its bag on its own, DECISIONS B25)
	var lines: Array = []
	for s in h.slots:
		if int(s["slot_index"]) < bag_size and int(s.get("equipped", 0)) == 0 and String(DmContent.item(String(s["item_id"])).get("type", "")) in ["weapon", "chest_armor", "helm", "boots"]:
			lines.append({"slot_index": int(s["slot_index"]), "quantity": int(s["quantity"])})
	var sold: DmResult = await h.sell_items(lines)
	check(sold.ok, "the junk is sold (%s)" % sold.error)
	await h.refresh_inventory()
	var left := 0
	for s in h.slots:
		if int(s["slot_index"]) < bag_size and int(s.get("equipped", 0)) == 0 and String(DmContent.item(String(s["item_id"])).get("type", "")) in ["weapon", "chest_armor", "helm", "boots"]:
			left += 1
	check(left == 0 and int(ui.guidance_state()["bagUsed"]) <= bag_size - lines.size(), "the bag was cleared of the junk (%d left, %d of %d used)" % [left, int(ui.guidance_state()["bagUsed"]), bag_size])
