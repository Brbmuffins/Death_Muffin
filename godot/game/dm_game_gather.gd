class_name DmGameGather
extends RefCounted
## Gathering wiring of WorldScene.ts: Skills + GatherLoop hooks, onGatherCycle / onGatherReply / onSkillsChanged, the node visuals tick
## (tool in hand, progress arc, gesture per cycle), nodeLive / node tips, the full-bag notice.

var g
var skills: DmSkills
var loop: DmGatherLoop
var views: DmNodeViews
var _prog := 0.0
var _last_sync := 0.0
var _levels: Dictionary = {}
var _hover_node: Variant = null


func _init(game) -> void:
	g = game
	skills = DmSkills.new()
	skills.changed.connect(_on_skills_changed)
	var hooks := {
		"now": func() -> float: return g.now_ms,
		"rand": func() -> float: return randf(),
		"nav": g.nav,
		"player": g.player,
		"nodes": func() -> Array: return live_nodes(),
		"live": func(id: String) -> bool: return node_live(id),
		"bagFits": func(item_id: String) -> bool: return DmLoot.add_to_slots(g.inventory.slots, {"item_id": item_id, "quantity": 1}) != null,
		"sendSuccess": func(node_id: String) -> void: g.send_intent({"t": "gather", "by": g.self_id, "nodeId": node_id, "successes": 1}),
		"post": func(node_type: String, actions: int, keepalive: bool, afk: bool) -> DmResult:
			if not keepalive:
				await g.inventory.flush()
			return await g.api.gather(g.hero_id, node_type, actions, afk),
		"onCycle": func(def: Dictionary, success: bool, node: Dictionary) -> void: on_cycle(def, success, node),
		"onReply": func(r: Dictionary) -> void: on_reply(r),
		"onStop": func(reason: String, message: String) -> void: on_stop(reason, message),
		"onError": func(msg: String) -> void: g.toast(msg, "err"),
		"autoEnabled": func() -> bool: return bool(g.settings["autoGather"]),
	}
	loop = DmGatherLoop.new(hooks, skills)
	if g.visual and g.builder != null:
		views = DmNodeViews.new()
		views.setup(g.builder)
		g.world_root.add_child(views)


var afk: bool:
	get: return loop.afk


func node_live(id: String) -> bool:
	var n: Variant = g.sim.nodes.get(id)
	return n != null and float(n["remaining"]) > 0.0


func live_nodes() -> Array:
	var out: Array = []
	for id in g.sim.nodes:
		var n: Dictionary = g.sim.nodes[id].duplicate()
		n["remaining"] = 1 if float(n["remaining"]) > 0.0 else 0
		out.append(n)
	return out


func load_professions() -> void:
	var r: DmResult = await g.api.get_professions(g.hero_id)
	if r.ok and r.data is Array:
		for row in r.data:
			_levels[row["profession_id"]] = int(row["skill_level"])
		skills.adopt(r.data)


func on_cycle(def: Dictionary, success: bool, node: Dictionary) -> void:
	var p: DmPlayer = g.player
	if g.visual:
		var pos := Vector2(float(node["x"]), float(node["z"]))
		if success and def["skill"] == "fishing":
			g.audio.play_sfx("reel", pos, 1.0)
		else:
			g.audio.gather(String(def["skill"]), String(def["kind"]), pos)
	if not success:
		return
	var sk: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")[def["skill"]]
	g.float_text(p.x, 2.3, p.z, "+%d %s XP" % [int(def["xp"]), sk["name"]], "skill")
	g.float_text(float(node["x"]), 0.7, float(node["z"]), "+1 %s" % DmContent.item(String(def["item"]))["name"], "info")
	if g.visual:
		g.vfx.emit({"x": node["x"], "y": 1.6 if def["kind"] == "tree" else 0.5, "z": node["z"], "count": 6, "color": Color.html(String(sk["color"])).to_rgba32() >> 8, "spread": 0.35, "speed": 1.4, "up": 1.0, "life": 0.5, "size": 0.14})


func on_reply(r: Dictionary) -> void:
	for it in r.get("items", []):
		g.inventory.add({"item_id": it["itemId"], "quantity": int(it["qty"])})
	var total := 0
	for it in r.get("items", []):
		total += int(it["qty"])
	g.chronicle.add("gathered.%s" % r["skill"], total)
	if float(r.get("gold", 0)) > 0.0:
		g.prog.add_gold(float(r["gold"]))
		g.float_text(g.player.x, 2.1, g.player.z, "+%dg" % int(r["gold"]), "gold")
	if not (r.get("rejected", []) as Array).is_empty():
		g.rewards.bag_full_notice()
		if loop.afk:
			loop.stop("bagFull")
	var nodes: Dictionary = DmContent.get_export("gameplay_gatheringRules", "NODES")
	var main_item: String = String(nodes[r["node"]]["item"]) if nodes.has(r["node"]) else ""
	for it in r.get("items", []):
		if it["itemId"] != main_item:
			g.toast("Found: %s%s" % [DmContent.item(String(it["itemId"]))["name"], (" ×%d" % int(it["qty"])) if int(it["qty"]) > 1 else ""], "good")
	g.emit_game_event("gather_reply", r)


func on_stop(reason: String, message: String) -> void:
	if views != null:
		views.selected(null)
	var text: String = message
	if text == "":
		var st: Variant = DmGathering.STOP_TEXT.get(reason)
		text = String(st) if st != null else ""
	if text != "":
		g.float_text(g.player.x, 2.4, g.player.z, text, "info")
	if reason == "bagFull":
		g.emit_game_event("bag_full")
	if g.avatar != null:
		g.avatar.set_gathering_tool("", 0)
		g.avatar.release_gesture()
	g.emit_game_event("gather_stopped", {"reason": reason})


func on_skills_changed() -> void:
	_on_skills_changed()


func _on_skills_changed() -> void:
	for s in DmGathering.SKILL_IDS:
		var lvl := skills.level(s)
		var before: int = int(_levels.get(s, 1))
		_levels[s] = lvl
		if lvl <= before:
			continue
		var sk: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")[s]
		g.banner("%s %d" % [sk["name"], lvl], String(sk.get("rite", "")), 3200)
		g.play_sfx("skillUp")
		g.emit_game_event("skill_up")


func node_hover(hover: Variant) -> void:
	_hover_node = hover["node"] if (hover != null and hover["kind"] == "node") else null
	if views != null:
		var ok := true
		if _hover_node != null:
			var def: Dictionary = DmGathering.node_def(String(_hover_node["type"]))
			ok = skills.gate_level(String(def["skill"])) >= int(def["level"])
		views.hover(_hover_node if not g.panel_open else null, ok)


## Gesture per work cycle, the progress arc, and a periodic resync of node looks.
func tick_visuals(dt: float) -> void:
	var prog: float = loop.progress
	var skill := ""
	if loop.active:
		skill = String(DmGathering.node_def(String(loop.node["type"]))["skill"])
	if g.avatar != null:
		var held: Array = []
		for s in g.inventory.slots:
			held.append(s["item_id"])
		g.avatar.set_gathering_tool(skill, DmGathering.tool_tier_for(skill, held) if skill != "" else 0)
	if views == null:
		return
	views.selected(loop.node if loop.active else null)
	if loop.working and (prog < _prog or _prog == 0.0) and prog < 0.5 and g.avatar != null:
		var def: Dictionary = DmGathering.node_def(String(loop.node["type"]))
		var cycle_s: float = float(def["ticks"]) * 600.0 / 1000.0
		var sk: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")[def["skill"]]
		var gesture: String = "attack" if ((skill == "woodcutting" or skill == "mining")) else String(sk["gesture"])
		var gesture_s := minf(1.6, cycle_s * 0.85) if skill == "fishing" else minf(1.15, cycle_s * 0.7)
		g.avatar.cast(gesture, 1.0, atan2(float(loop.node["x"]) - g.player.x, float(loop.node["z"]) - g.player.z), gesture_s)
	_prog = prog if loop.working else 0.0
	var color := "#ffffff"
	if loop.active:
		color = String(DmContent.get_export("gameplay_gatheringRules", "SKILLS")[DmGathering.node_def(String(loop.node["type"]))["skill"]]["color"])
	views.progress(g.player.x, g.player.z, maxf(0.02, prog) if loop.working else 0.0, color)
	views.update(dt)
	if g.now_ms - _last_sync > 1000.0:
		_last_sync = g.now_ms
		for id in g.sim.nodes:
			views.set_live(String(id), node_live(String(id)))


func on_node_gone(id: String) -> void:
	if views != null:
		views.set_live(id, false)
	var n: Variant = null
	for p in g._sim_world["nodes"]:
		if p["id"] == id:
			n = p
			break
	if n != null and loop.node.get("id") == id and g.visual:
		g.vfx.emit({"x": n["x"], "y": 0.4, "z": n["z"], "count": 14, "color": 0x8a7a60, "spread": 0.6, "speed": 1.6, "up": 1.2, "life": 0.7, "size": 0.2})


func on_node_back(id: String) -> void:
	if views != null:
		views.set_live(id, true)
