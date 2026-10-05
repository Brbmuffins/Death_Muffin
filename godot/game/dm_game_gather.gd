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
var session: DmGatherSession = null


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
		"autoEnabled": func() -> bool: return bool(g.settings["auto_gather"]),
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


## A charm turned up: a rare moment worth a banner (gathering, laborers and the garden all funnel through here).
func celebrate_charms(items: Array) -> void:
	for it in items:
		for pet in DmContent.get_export("cosmetics", "PETS"):
			if pet["charm"] == it["itemId"]:
				g.banner("A rare find!", "%s: adopt it in Character → Capes & Pets (N)" % DmContent.item(String(it["itemId"]))["name"], 4200)
				g.play_sfx("skillUp")


func on_reply(r: Dictionary) -> void:
	if session != null:
		session.record(r)
	celebrate_charms(r.get("items", []))
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
	_end_session(reason)


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


## nodeTipText: the hover card HTML for a gathering node (trusted markup built from the gathering rules; DmHud.node_tip renders it).
func node_tip_text(n: Dictionary) -> String:
	var def: Dictionary = DmGathering.node_def(String(n["type"]))
	var sk: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")[def["skill"]]
	var lvl: int = skills.gate_level(String(def["skill"]))
	var need: String
	if lvl < int(def["level"]):
		need = '<div class="req missing">Requires %s level %d · use %s</div>' % [sk["name"], int(def["level"]), "Coffin-Oak near the entrance" if String(sk["name"]) == "Woodcutting" else "a beginner node near the entrance"]
	else:
		need = '<div class="req ok">%s · level %d%s</div>' % [sk["name"], int(def["level"]), " · Beginner" if int(def["level"]) == 1 else ""]
	var spent := "" if node_live(String(n["id"])) else '<div class="spent">Spent. It will return soon.</div>'
	return "<b>%s</b>%s%s<div>%d XP per success · %s</div>%s" % [def["name"], ' <span class="rich">rich</span>' if bool(n.get("rich", false)) else "", need, int(def["xp"]), preload("res://rules/gathering/gather_data.gd").item_meta(String(def["item"]))["name"], spent]


## WorldScene's per-frame `hud.nodeTip(hn ? nodeTipText(hn) : hl >= 0 ? laborers.tip(hl) : null, mouse.x, mouse.y)`: only a gathering node or a
## Grave Laborer under the cursor (and no panel open) gets a card; stations and NPCs have none in the web either.
func update_node_tip(hover: Variant, mx: float, my: float) -> void:
	var ui: Variant = g.ui
	if ui == null or ui.get("hud") == null:
		return
	var html: Variant = null
	if hover != null and not g.panel_open:
		if hover["kind"] == "node":
			html = node_tip_text(hover["node"])
		elif hover["kind"] == "laborer" and g.laborer_views != null:
			var t: String = g.laborer_views.tip(int(hover["slot"]))
			html = t if t != "" else null
	ui.hud.node_tip(html, mx, my)


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


## AFK in the Sexton's Acre (startAfkGathering): walk to the nearest node of that kind and keep working; a report follows when work stops.
func start_afk(node_id: String) -> String:
	var node: Dictionary = {}
	for n in g._sim_world["nodes"]:
		if n["id"] == node_id:
			node = n
	if node.is_empty():
		return "Choose a gathering node."
	if g.player.area != "acre":
		return "Visit the Sexton’s Acre for safe AFK gathering."
	loop.stop("moved")
	await loop.flush()
	var r: DmResult = await g.api.begin_afk_gather(g.hero_id, String(node["type"]))
	if not r.ok:
		return r.error
	g.input.attack_target = null
	g.input.pending_interact = null
	g.actions.cancel_recall()
	g.input.keys.clear()
	var refusal: String = loop.start_afk(node)
	if refusal != "":
		return refusal
	g.toast("AFK gathering started — keep the game open. It pauses when your bag fills.", "good")
	session = DmGatherSession.new(g.now_ms,
		func(id: String) -> Dictionary:
			var m := DmContent.item(id)
			return {"name": m["name"], "rarity": m.get("rarity", "common"), "sell": m.get("sell", 0)},
		func(skill: String) -> int: return skills.level(skill),
		func(skill: String) -> float: return float(g.chronicle.view()["life"].get("gathered." + skill, 0)))
	return ""


func afk_status() -> Dictionary:
	return {"active": loop.afk, "text": loop.status, "allowed": g.player.area == "acre"}


func _end_session(reason: String) -> void:
	var s := session
	if s == null:
		return
	await loop.flush()
	if session != s:
		return
	session = null
	var bests_key := "dm_gather_best_v1:%d" % g.hero_id
	var raw: String = g.store.get_item(bests_key)
	var bests: Dictionary = JSON.parse_string(raw) if raw != "" else {}
	var out: Variant = s.finish(g.now_ms, reason, bests if bests is Dictionary else {})
	if out == null:
		return
	g.store.set_item(bests_key, JSON.stringify(out["bests"]))
	g.emit_game_event("gather_report", {"report": out["report"]})
	g.play_sfx("skillUp" if not (out["report"]["milestones"] as Array).is_empty() else "coin")
