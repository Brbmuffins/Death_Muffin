class_name DmNextGather
extends Node
## Gathering on the rebuild (child "Gather" of DmNextGame, same path on every peer). The rules are the original game's, not re-implemented:
## DmGatherLoop (walk -> work -> batch -> adopt the server's answer), DmGathering (timings, yields, XP, blockers), DmSkills, DmNodeViews
## (hover / selected ring, progress arc, spent look), DmGatherSession (AFK report). What is new is the glue to the slice:
##   - HOST: runs the loop for its own hero, owns each node's yield (`remaining`, rolled like DmSimDirector.roll_yield) and respawn clock,
##     credits results through the backend API (DmApi / the offline backend, REBUILD D1/D4). Value never comes from node state.
##   - EVERY PEER: the set of depleted nodes, replicated as events (`_rpc_state`) plus a full list for a joiner (`_rpc_full`).
## Cost: a 10 Hz tick (per frame only while a gather loop runs, for the progress arc), one respawn check at 4 Hz only while a node is spent,
## picking is limited to the current area's nodes near the hero. Nothing scans all nodes per frame.

signal node_changed(id: String, live: bool)    ## every peer
signal gathered(reply: Dictionary)             ## host: a backend answer was applied (items, xp, gold)

const TICK_S := 0.1
const RESPAWN_S := 0.25
const PICK_PX := 52.0
const JOIN_DELAY_S := 1.0

var game: DmNextGame
var skills := DmSkills.new()
var loop: DmGatherLoop
var views: DmNodeViews
var nodes: Dictionary = {}                      ## id -> the world's node placement {id,type,x,z,area,rot,rich,kind,...}
var depleted: Dictionary = {}                   ## every peer: id -> true while spent
var hover: Variant = null                       ## the node under the cursor (a placement) or null
var session: DmGatherSession = null             ## the AFK report in progress
var bests: Dictionary = {}

var _by_area: Dictionary = {}
var _remaining: Dictionary = {}                 ## host: id -> yield left
var _respawn_at: Dictionary = {}                ## host: id -> clock s
var _clock := 0.0
var _acc := 0.0
var _resp_acc := 0.0
var _prog := 0.0
var _visual := false
var _vfx: Node
var _audio: Node
var _tip_on := false
var _levels: Dictionary = {}
var _pick_d := PICK_PX                          ## the winning screen distance of the last pick() (a laborer must beat it)


## The loop's walker: the host's own hero body, steered by the session's move intents (the same path a click takes).
class Actor extends RefCounted:
	var g: DmNextGame
	var x: float:
		get: return g.local_body().position.x
	var z: float:
		get: return g.local_body().position.z

	func has_path() -> bool:
		var b := g.local_body()
		return b.has_target or b.move_dir != Vector3.ZERO

	func move_along(path: Array) -> void:
		if not path.is_empty():
			g.session.request_move_to(Vector3(float(path[path.size() - 1][0]), 0.0, float(path[path.size() - 1][1])))

	func face(fx: float, fz: float) -> void:
		var b := g.local_body()
		b.yaw = atan2(fx - b.position.x, fz - b.position.z)

	func stop() -> void:
		g.local_body().stop()


## The loop's nav: a stand spot is free when the navmesh is walkable there; the walk itself is the body's own navmesh path.
class NavShim extends DmNav:
	var world: DmNextWorld

	func blocked(x: float, z: float, _r: float) -> bool:
		if world == null or not world.nav_ready():
			return false
		var c := world.nav_closest(Vector3(x, 0.0, z))
		return Vector2(c.x - x, c.z - z).length() > 0.25

	func find_path(_fx: float, _fz: float, tx: float, tz: float, _r: float = 0.45) -> Array:
		return [[tx, tz]]


## Called by DmNextGame.start once the session exists (before the HUD). Host: also loads the professions from the backend.
func setup(game_: DmNextGame) -> void:
	game = game_
	_visual = bool(game.opts.get("visual", true)) and DisplayServer.get_name() != "headless"
	_vfx = get_node_or_null("/root/Vfx") if _visual else null
	_audio = get_node_or_null("/root/AudioDirector") if _visual else null
	for n in DmData.world()["nodes"]:
		nodes[String(n["id"])] = n
		if not _by_area.has(n["area"]):
			_by_area[n["area"]] = []
		_by_area[n["area"]].append(n)
	var b := game.world.builder
	if b != null:
		views = DmNodeViews.new()
		views.setup(b)
		game.world.add_child(views)
	skills.changed.connect(_on_skills_changed)
	if game.session.is_host():
		DmSimData.ensure()
		for id in nodes:
			_remaining[id] = _roll_yield(nodes[id])
		game.session.player_joined.connect(_on_player_joined)
		_make_loop()
		game.input.clicked_move.connect(func(_p: Vector3) -> void: stop_gathering("moved"))
		await load_professions()
	set_process(true)


func _make_loop() -> void:
	var actor := Actor.new()
	actor.g = game
	var nav := NavShim.new()
	nav.world = game.world
	var hooks := {
		"now": func() -> float: return float(Time.get_ticks_msec()),
		"rand": func() -> float: return randf(),
		"nav": nav,
		"player": actor,
		"nodes": func() -> Array: return live_nodes(),
		"live": func(id: String) -> bool: return node_live(id),
		"bagFits": func(item_id: String) -> bool: return _bag_fits(item_id),
		"sendSuccess": func(node_id: String) -> void: _apply_success(node_id),
		"post": func(node_type: String, actions: int, keepalive: bool, afk_: bool) -> DmResult:
			if not keepalive and game.ui_host != null and game.ui_host.inventory != null:
				await game.ui_host.inventory.flush()
			return await game.api.gather(_cid(), node_type, actions, afk_),
		"onCycle": func(def: Dictionary, success: bool, node: Dictionary) -> void: _on_cycle(def, success, node),
		"onReply": func(r: Dictionary) -> void: _on_reply(r),
		"onStop": func(reason: String, message: String) -> void: _on_stop(reason, message),
		"onError": func(msg: String) -> void: _toast(msg, "err"),
		"autoEnabled": func() -> bool: return game.ui_host != null and bool(game.ui_host.settings["auto_gather"]),
	}
	loop = DmGatherLoop.new(hooks, skills)


func _cid() -> int:
	return int(game.character.get("id", 0))


func load_professions() -> void:
	var r: DmResult = await game.api.get_professions(_cid())
	if r.ok and r.data is Array:
		for row in r.data:
			_levels[row["profession_id"]] = int(row["skill_level"])
		skills.adopt(r.data)


# ---- node state (host owns it; every peer mirrors the depleted set) --------------------------------------------------------------

func node_live(id: String) -> bool:
	return nodes.has(id) and not depleted.has(id)


## The loop's `nodes` hook: placements with a 0 / 1 `remaining` (only used on depletion for the Auto "next node of this kind" pick).
func live_nodes() -> Array:
	var out: Array = []
	for id in nodes:
		var n: Dictionary = (nodes[id] as Dictionary).duplicate()
		n["remaining"] = 0 if depleted.has(id) else 1
		out.append(n)
	return out


static func _roll_yield(n: Dictionary) -> float:
	var def: Dictionary = DmSimData.NODES[n["type"]]
	var lo := float(def["yields"][0])
	var hi := float(def["yields"][1])
	var v := lo + floorf(randf() * (hi - lo + 1.0))
	return maxf(1.0, DmMath.js_round_f(v * (DmSimData.RICH_YIELD if DmCombatData.truthy(n.get("rich")) else 1.0)))


## Host: one confirmed success on a node (DmSimDirector.apply_gather): within reach, takes 1 off its yield; at 0 it is spent and respawns
## after the node's respawnS (halved for a rich node).
func _apply_success(id: String) -> void:
	if not multiplayer.is_server() or depleted.has(id) or not nodes.has(id):
		return
	var n: Dictionary = nodes[id]
	var b := game.local_body()
	var def: Dictionary = DmSimData.NODES[n["type"]]
	if b != null and DmSimMath.hypot(b.position.x - float(n["x"]), b.position.z - float(n["z"])) > float(DmSimData.NODE_REACH[def["kind"]]) + 2.0:
		return
	_remaining[id] = float(_remaining[id]) - 1.0
	if float(_remaining[id]) > 0.0:
		return
	_remaining[id] = 0.0
	var respawn_s := float(def["respawnS"]) * (DmSimData.RICH_RESPAWN if DmCombatData.truthy(n.get("rich")) else 1.0)
	_respawn_at[id] = _clock + respawn_s
	_set_state(id, false)


func _set_state(id: String, live: bool) -> void:
	_apply_state(id, live)
	if multiplayer.has_multiplayer_peer() and game.session.is_host() and not multiplayer.get_peers().is_empty():
		_rpc_state.rpc(id, live)


func _apply_state(id: String, live: bool) -> void:
	if not nodes.has(id) or (live != depleted.has(id)):
		return
	if live:
		depleted.erase(id)
	else:
		depleted[id] = true
	if views != null:
		views.set_live(id, live)
	if _vfx != null and not live:
		var b := game.local_body()
		var n: Dictionary = nodes[id]
		if b != null and absf(float(n["x"]) - b.position.x) < 30.0 and absf(float(n["z"]) - b.position.z) < 30.0:
			_vfx.emit({"x": n["x"], "y": 0.4, "z": n["z"], "count": 14, "color": 0x8a7a60, "spread": 0.6, "speed": 1.6, "up": 1.2, "life": 0.7, "size": 0.2})
	node_changed.emit(id, live)


@rpc("authority", "call_remote", "reliable")
func _rpc_state(id: String, live: bool) -> void:
	_apply_state(id, live)


@rpc("authority", "call_remote", "reliable")
func _rpc_full(spent: PackedStringArray) -> void:
	for id in nodes:
		_apply_state(String(id), not spent.has(id))


func _on_player_joined(peer_id: int) -> void:
	if peer_id == game.session.get_my_id():
		return
	await get_tree().create_timer(JOIN_DELAY_S).timeout
	if is_inside_tree() and multiplayer.get_peers().has(peer_id):
		_rpc_full.rpc_id(peer_id, PackedStringArray(depleted.keys()))


# ---- frame / tick ---------------------------------------------------------------------------------------------------------------

func _process(dt: float) -> void:
	_clock += dt
	if not _respawn_at.is_empty():
		_resp_acc += dt
		if _resp_acc >= RESPAWN_S:
			_resp_acc = 0.0
			_respawn_due()
	_acc += dt
	if _acc < TICK_S and not (loop != null and loop.active):
		return
	var step := _acc
	_acc = 0.0
	_tick(step)


func _respawn_due() -> void:
	for id in _respawn_at.keys():
		if _clock >= float(_respawn_at[id]):
			_respawn_at.erase(id)
			_remaining[id] = _roll_yield(nodes[id])
			_set_state(id, true)


func _tick(dt: float) -> void:
	var b := game.local_body()
	if b == null:
		return
	if loop != null:
		if loop.active:
			if not b.alive:
				loop.stop("dead")
			elif game.input.held_direction() != Vector3.ZERO:
				loop.stop("moved")
		loop.update(dt)
		_tick_visuals(b, dt)
	elif views != null:
		views.update(dt)


## Gesture per work cycle, the tool in hand and the progress arc under the hero (DmGameGather.tick_visuals).
func _tick_visuals(b: DmHeroBody, dt: float) -> void:
	var skill := ""
	if loop.active:
		skill = String(DmGathering.node_def(String(loop.node["type"]))["skill"])
	if b.avatar != null and (skill != "" or _prog != 0.0 or _holding):
		var held: Array = []
		if game.ui_host != null:
			for s in game.ui_host.slots:
				held.append(s["item_id"])
		b.avatar.set_gathering_tool(skill, DmGathering.tool_tier_for(skill, held) if skill != "" else 0)
		_holding = skill != ""
	if views == null:
		return
	var prog: float = loop.progress
	views.selected(loop.node if loop.active else null)
	if loop.working and (prog < _prog or _prog == 0.0) and prog < 0.5 and b.avatar != null:
		var def: Dictionary = DmGathering.node_def(String(loop.node["type"]))
		var cycle_s := float(def["ticks"]) * 0.6
		var sk: Dictionary = DmGatherData.get_data()["skills"][def["skill"]]
		var gesture := "attack" if (skill == "woodcutting" or skill == "mining") else String(sk["gesture"])
		var gesture_s := minf(1.6, cycle_s * 0.85) if skill == "fishing" else minf(1.15, cycle_s * 0.7)
		b.avatar.cast(gesture, 1.0, atan2(float(loop.node["x"]) - b.position.x, float(loop.node["z"]) - b.position.z), gesture_s)
	_prog = prog if loop.working else 0.0
	var color := "#ffffff"
	if loop.active:
		color = String(DmGatherData.get_data()["skills"][DmGathering.node_def(String(loop.node["type"]))["skill"]]["color"])
	views.progress(b.position.x, b.position.z, maxf(0.02, prog) if loop.working else 0.0, color)
	views.update(dt)

var _holding := false


# ---- hover / click ----------------------------------------------------------------------------------------------------------------

## The node nearest the cursor within PICK_PX (current area only, near the hero). Pass the cursor's screen position.
func pick(screen: Vector2) -> Variant:
	_pick_d = PICK_PX
	var b := game.local_body()
	if b == null or not _by_area.has(game.area_id):
		return null
	var cam: DmCameraRig = game.camera
	var best: Variant = null
	var best_d := PICK_PX
	for n in _by_area[game.area_id]:
		if absf(float(n["x"]) - b.position.x) > 26.0 or absf(float(n["z"]) - b.position.z) > 22.0:
			continue
		var tree: bool = n["kind"] == "tree"
		var v := Vector3(float(n["x"]), 1.6 if tree else (0.1 if n["kind"] == "pool" else 0.5), float(n["z"]))
		if cam.is_position_behind(v):
			continue
		var d := cam.unproject_position(v).distance_to(screen) - (14.0 if tree else 6.0)
		if d < best_d:
			best_d = d
			best = n
	_pick_d = best_d
	return best


## 10 Hz from DmNextInput: the node under the cursor (when no station / NPC is), its ring and its card.
func hover_at(screen: Vector2, blocked: bool = false) -> void:
	hover = null if blocked or _panel_open() else pick(screen)
	var slot := -1
	if game.acre != null and not blocked and not _panel_open():
		slot = game.acre.pick_laborer(screen, _pick_d if hover != null else PICK_PX)   # a Grave Laborer nearer than the node wins the hover
		if slot >= 0:
			hover = null
			if views != null:
				views.hover(null, true)
	if game.acre != null:
		game.acre.set_hover(slot)
	if slot >= 0:
		var hud0: Variant = game.ui.get("hud") if game.ui != null else null
		if hud0 != null:
			_tip_on = true
			var mp0 := get_viewport().get_mouse_position()
			hud0.node_tip(game.acre.tip(slot), mp0.x, mp0.y)
		return
	if views != null:
		var ok := true
		if hover != null:
			var def := DmGathering.node_def(String(hover["type"]))
			ok = skills.gate_level(String(def["skill"])) >= int(def["level"])
		views.hover(hover, ok)
	var hud: Variant = game.ui.get("hud") if game.ui != null else null
	if hud != null and (hover != null or _tip_on):
		_tip_on = hover != null
		var mp := get_viewport().get_mouse_position()
		hud.node_tip(node_tip_text(hover) if hover != null else null, mp.x, mp.y)


## Left click on the ground view (after enemies / stations): walk to the node and work it. True = the click was consumed.
func click_at(screen: Vector2) -> bool:
	var n: Variant = pick(screen)
	if game.acre != null and not _panel_open():
		var slot: int = game.acre.pick_laborer(screen, _pick_d if n != null else PICK_PX)
		if slot >= 0:
			game.acre.open_labor()   # the original game: a click on a laborer opens the Laborers (H)
			return true
	if n == null or loop == null:
		return false
	var b := game.local_body()
	if b == null or not b.alive:
		return false
	return click_node(n)


func click_node(n: Dictionary) -> bool:
	if loop == null:
		return false
	loop.stop("moved")
	var refusal := loop.start(n)
	if refusal != "":
		_float(refusal)
		_sfx("error")
	else:
		_sfx("click")
		_event("gather_started", {"rich": DmCombatData.truthy(n.get("rich"))})
	return true


## The hover card (DmGameGather.node_tip_text): what it needs, XP per success, what it gives, whether it is spent.
func node_tip_text(n: Dictionary) -> String:
	var def := DmGathering.node_def(String(n["type"]))
	var sk: Dictionary = DmGatherData.get_data()["skills"][def["skill"]]
	var lvl := skills.gate_level(String(def["skill"]))
	var need: String
	if lvl < int(def["level"]):
		need = '<div class="req missing">Requires %s level %d · use %s</div>' % [sk["name"], int(def["level"]), "Coffin-Oak near the entrance" if String(sk["name"]) == "Woodcutting" else "a beginner node near the entrance"]
	else:
		need = '<div class="req ok">%s · level %d%s</div>' % [sk["name"], int(def["level"]), " · Beginner" if int(def["level"]) == 1 else ""]
	var spent := "" if node_live(String(n["id"])) else '<div class="spent">Spent. It will return soon.</div>'
	return "<b>%s</b>%s%s<div>%d XP per success · %s</div>%s" % [def["name"], ' <span class="rich">rich</span>' if DmCombatData.truthy(n.get("rich")) else "", need, int(def["xp"]), DmGatherData.item_meta(String(def["item"]))["name"], spent]


# ---- loop callbacks ---------------------------------------------------------------------------------------------------------------

func _on_cycle(def: Dictionary, success: bool, node: Dictionary) -> void:
	var b := game.local_body()
	if _audio != null:
		var pos := Vector2(float(node["x"]), float(node["z"]))
		if success and def["skill"] == "fishing":
			_audio.play_sfx("reel", pos, 1.0)
		else:
			_audio.gather(String(def["skill"]), String(def["kind"]), pos)
	if not success:
		return
	var sk: Dictionary = DmGatherData.get_data()["skills"][def["skill"]]
	if game.ui_host != null and b != null:
		game.ui_host.float_text(b.position + Vector3(0, 2.3, 0), "+%d %s XP" % [int(def["xp"]), sk["name"]], "skill")
		game.ui_host.float_text(Vector3(float(node["x"]), 0.7, float(node["z"])), "+1 %s" % DmContent.item(String(def["item"]))["name"], "info")
	if _vfx != null:
		_vfx.emit({"x": node["x"], "y": 1.6 if def["kind"] == "tree" else 0.5, "z": node["z"], "count": 6, "color": Color.html(String(sk["color"])).to_rgba32() >> 8, "spread": 0.35, "speed": 1.4, "up": 1.0, "life": 0.5, "size": 0.14})


func _on_reply(r: Dictionary) -> void:
	if session != null:
		session.record(r)
	_celebrate_charms(r.get("items", []))
	var inv: DmInventory = game.ui_host.inventory if game.ui_host != null else null
	var total := 0
	for it in r.get("items", []):
		total += int(it["qty"])
		if inv != null:
			inv.add({"item_id": it["itemId"], "quantity": int(it["qty"])})
	var prog: DmProgression = game.ui_host.prog if game.ui_host != null else null
	if prog != null and prog.chronicle != null:
		prog.chronicle.add("gathered.%s" % r["skill"], total)
	if float(r.get("gold", 0)) > 0.0 and prog != null:
		prog.add_gold(float(r["gold"]))
		var b := game.local_body()
		if b != null:
			game.ui_host.float_text(b.position + Vector3(0, 2.1, 0), "+%dg" % int(r["gold"]), "gold")
	if not (r.get("rejected", []) as Array).is_empty():
		_toast("Reliquary full", "err")
		if loop.afk:
			loop.stop("bagFull")
	var node_defs: Dictionary = DmContent.get_export("gameplay_gatheringRules", "NODES")
	var main_item: String = String(node_defs[r["node"]]["item"]) if node_defs.has(r["node"]) else ""
	for it in r.get("items", []):
		if it["itemId"] != main_item:
			_toast("Found: %s%s" % [DmContent.item(String(it["itemId"]))["name"], (" ×%d" % int(it["qty"])) if int(it["qty"]) > 1 else ""], "good")
	gathered.emit(r)


func celebrate_charms(items: Array) -> void:   ## DmGameLabor's hook (laborers and the garden funnel through the same banner)
	_celebrate_charms(items)


func _celebrate_charms(items: Array) -> void:
	for it in items:
		for pet in DmContent.get_export("cosmetics", "PETS"):
			if pet["charm"] == it["itemId"]:
				_event("banner", {"title": "A rare find!", "sub": "%s: adopt it in Character → Capes & Pets (N)" % DmContent.item(String(it["itemId"]))["name"], "ms": 4200})
				_sfx("skillUp")


func _on_stop(reason: String, message: String) -> void:
	if views != null:
		views.selected(null)
		views.progress(0.0, 0.0, 0.0, "#ffffff")
	var text := message
	if text == "":
		var st: Variant = DmGathering.STOP_TEXT.get(reason)
		text = String(st) if st != null else ""
	if text != "":
		_float(text)
	if reason == "bagFull":
		_event("bag_full")
	var b := game.local_body()
	if b != null and b.avatar != null:
		b.avatar.set_gathering_tool("", 0)
		b.avatar.release_gesture()
	_holding = false
	_prog = 0.0
	_end_session(reason)


func _on_skills_changed() -> void:
	for s in DmGathering.SKILL_IDS:
		var lvl := skills.level(s)
		var before := int(_levels.get(s, 1))
		_levels[s] = lvl
		if lvl <= before:
			continue
		var sk: Dictionary = DmGatherData.get_data()["skills"][s]
		_event("banner", {"title": "%s %d" % [sk["name"], lvl], "sub": String(sk.get("rite", "")), "ms": 3200})
		_sfx("skillUp")
		_event("skill_up")


func _bag_fits(item_id: String) -> bool:
	if game.ui_host == null or game.ui_host.inventory == null:
		return true
	return DmLoot.add_to_slots(game.ui_host.inventory.slots, {"item_id": item_id, "quantity": 1}) != null


# ---- AFK (the Acre ledger's Skills tab; DmNextUiHost forwards start_afk / stop_gathering / afk_status / afk_active) ------------------

func start_afk(node_id: String) -> String:
	if loop == null:
		return "Gathering is the host's."
	var node: Dictionary = {}
	for id in nodes:
		if id == node_id:
			node = nodes[id]
	if node.is_empty():
		# The panel's picker names a node TYPE; take the nearest placed node of that type in the Acre.
		var b := game.local_body()
		var best := INF
		for id in nodes:
			var n: Dictionary = nodes[id]
			if n["type"] == node_id and n["area"] == "acre" and b != null:
				var d := DmSimMath.hypot(float(n["x"]) - b.position.x, float(n["z"]) - b.position.z)
				if d < best:
					best = d
					node = n
	if node.is_empty():
		return "Choose a gathering node."
	if game.area_id != "acre":
		return "Visit the Sexton’s Acre for safe AFK gathering."
	loop.stop("moved")
	await loop.flush()
	var r: DmResult = await game.api.begin_afk_gather(_cid(), String(node["type"]))
	if not r.ok:
		return r.error
	var refusal := loop.start_afk(node)
	if refusal != "":
		return refusal
	_toast("AFK gathering started — keep the game open. It pauses when your bag fills.", "good")
	var prog: DmProgression = game.ui_host.prog if game.ui_host != null else null
	session = DmGatherSession.new(float(Time.get_ticks_msec()),
		func(id: String) -> Dictionary:
			var m := DmContent.item(id)
			return {"name": m["name"], "rarity": m.get("rarity", "common"), "sell": m.get("sell", 0)},
		func(skill: String) -> int: return skills.level(skill),
		func(skill: String) -> float: return float(prog.chronicle.view()["life"].get("gathered." + skill, 0)) if prog != null and prog.chronicle != null else 0.0)
	return ""


func afk_status() -> Dictionary:
	return {"active": loop != null and loop.afk, "text": loop.status if loop != null else "", "allowed": game.area_id == "acre"}


func stop_gathering(reason: String) -> void:
	if loop != null:
		loop.stop(reason)


func _end_session(reason: String) -> void:
	var s := session
	if s == null:
		return
	await loop.flush()
	if session != s:
		return
	session = null
	var store: DmCounselStore = game.progress.store if game.progress != null else null   # the original game's key + shape (DmGameGather._end_session)
	var key := "dm_gather_best_v1:%d" % _cid()
	if store != null and bests.is_empty():
		var raw: String = store.get_item(key)
		var parsed: Variant = JSON.parse_string(raw) if raw != "" else null
		bests = parsed if parsed is Dictionary else {}
	var out: Variant = s.finish(float(Time.get_ticks_msec()), reason, bests)
	if out == null:
		return
	bests = out["bests"]
	if store != null:
		store.set_item(key, JSON.stringify(bests))
	_event("gather_report", {"report": out["report"]})
	_sfx("skillUp" if not (out["report"]["milestones"] as Array).is_empty() else "coin")


# ---- plumbing ---------------------------------------------------------------------------------------------------------------------

func _panel_open() -> bool:
	return game.ui != null and bool(game.ui.panel_open())


func _event(id: String, ctx: Dictionary = {}) -> void:
	if game.ui_host != null:
		game.ui_host.game_event.emit(id, ctx)


func _toast(text: String, kind: String = "") -> void:
	_event("toast", {"text": text, "kind": kind})


func _float(text: String) -> void:
	var b := game.local_body()
	if game.ui_host != null and b != null:
		game.ui_host.float_text(b.position + Vector3(0, 2.4, 0), text, "info")


func _sfx(id: String) -> void:
	if _audio != null:
		_audio.play_sfx(id)
