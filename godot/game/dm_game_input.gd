class_name DmGameInput
extends RefCounted
## The input half of WorldScene.ts: bindInput (keys, mouse), updateCursor (ground point + screen-space picking), onPrimaryClick,
## castSlot, cursorTarget, tickCombat (queued casts, held number keys, Easy auto combat), the attack-target chase and the minimap travel.
## PC only: click-to-move, click an enemy to attack, 1-4 / RMB / R rites, Q / Z / X belt, T recall, G auto combat, WASD / arrows.

class KeyDir:
	var x = 0.0
	var z = 0.0

const AUTO_COMBAT := "res://game/dm_auto_combat.gd"
const STAND_PAD := 0.25

var g
var keys: Dictionary = {}
var mouse = {"x": 0.0, "y": 0.0, "shift": false, "aiming": false}
var ground = {"x": 0.0, "z": 0.0}
var hover: Variant = null
var attack_target: Variant = null
var pending_interact: Variant = null
var queued_cast: Variant = null
var auto_target_id: int = -1
var auto_aim: Variant = null
var auto_mem: Dictionary = {}
var next_auto_at = 0.0
var last_feedback = 0.0
var telegraphs: Variant = null
var _auto: Variant = null
var _dodge: Array = []
var _nodes: Array = []
var _last_beat = -1
var _flask_cd_until = 0.0


func _init(game) -> void:
	g = game
	_nodes = g._sim_world["nodes"]
	if ResourceLoader.exists(AUTO_COMBAT):
		_auto = load(AUTO_COMBAT)
	var t = "res://game/dm_boss_telegraphs.gd"
	if ResourceLoader.exists(t):
		telegraphs = load(t).new()


# ---- events --------------------------------------------------------------------------------------------------------------------

static func key_name(ev: InputEventKey) -> String:
	match ev.keycode:
		KEY_SPACE: return " "
		KEY_ESCAPE: return "escape"
		KEY_ENTER, KEY_KP_ENTER: return "enter"
		KEY_UP: return "arrowup"
		KEY_DOWN: return "arrowdown"
		KEY_LEFT: return "arrowleft"
		KEY_RIGHT: return "arrowright"
		KEY_PERIOD: return "."
		KEY_TAB: return "tab"
	if ev.unicode > 0 and ev.unicode < 128:
		return char(ev.unicode).to_lower()
	return OS.get_keycode_string(ev.keycode).to_lower()


func handle(ev: InputEvent) -> void:
	if ev is InputEventKey:
		_key(ev)
	elif ev is InputEventMouseMotion:
		mouse["aiming"] = true
		mouse["x"] = ev.position.x
		mouse["y"] = ev.position.y
		mouse["shift"] = ev.shift_pressed
	elif ev is InputEventMouseButton:
		_mouse_button(ev)


## Keys the UI track owns (panels, chat, Esc, auto combat, talk, loadout hotkeys: DmGameUi handles them; GAME_CONTRACT.md).
const UI_KEYS := ["i", "b", "j", "y", "c", "p", "o", "u", "h", "n", "v", "m", "k", ".", "l", "g", "e", "escape", "enter", "tab"]


func _key(ev: InputEventKey) -> void:
	if not ev.pressed:
		keys.erase(key_name(ev))
		mouse["shift"] = ev.shift_pressed
		return
	var k := key_name(ev)
	if k == "shift":
		mouse["shift"] = true
		return
	if k in UI_KEYS or DmKeybinds.action_for_key(g.keybinds, k) != "":
		return
	if k in ["1", "2", "3", "4"]:
		keys[k] = true
	var repeat_ok: bool = k in ["w", "a", "s", "d", "arrowup", "arrowdown", "arrowleft", "arrowright"]
	if ev.echo and not repeat_ok:
		return
	if k.length() == 1 and k >= "1" and k <= "6":
		cast_slot(int(k))
	elif k == "r":
		cast_slot(6)
	elif k == "q":
		g.actions.drink_flask()
	elif k == String(DmContent.get_export("brews", "BREW_KEYS")["elixir"]):
		g.actions.drink_belt("elixir")
	elif k == String(DmContent.get_export("brews", "BREW_KEYS")["tonic"]):
		g.actions.drink_belt("tonic")
	elif k == "t":
		g.actions.start_recall()
	else:
		keys[k] = true
	mouse["shift"] = ev.shift_pressed


func _mouse_button(ev: InputEventMouseButton) -> void:
	if ev.button_index == MOUSE_BUTTON_WHEEL_UP and ev.pressed:
		if g.camera != null:
			g.camera.zoom_step(-1.0)
	elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN and ev.pressed:
		if g.camera != null:
			g.camera.zoom_step(1.0)
	elif ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
		mouse["aiming"] = true
		mouse["x"] = ev.position.x
		mouse["y"] = ev.position.y
		cast_slot(5)
	elif ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
		mouse["aiming"] = true
		mouse["x"] = ev.position.x
		mouse["y"] = ev.position.y
		mouse["shift"] = ev.shift_pressed
		on_primary_click()


func toggle_auto_combat() -> void:
	if not g.settings_store.can_use_auto_combat():
		return
	g.set_auto_combat(not bool(g.settings["auto_combat"]))


# ---- cursor --------------------------------------------------------------------------------------------------------------------

func set_ground(x: float, z: float) -> void:
	ground["x"] = x
	ground["z"] = z


## Interactables within the screen of the hero, plus a Depths floor's own stairs and chest.
func interactables_near() -> Array:
	var out: Array = []
	for id in DmContent.area_order():
		for it in DmContent.area(id)["interactables"]:
			if absf(float(it["x"]) - g.player.x) < 26.0 and absf(float(it["z"]) - g.player.z) < 22.0:
				out.append(it)
	if g.depths != null:
		out.append_array(g.depths.interactables())
	return out


func update_cursor() -> void:
	var cam: DmCameraRig = g.camera
	if cam != null and g.is_inside_tree():
		var vp = g.get_viewport()
		var mp = vp.get_mouse_position()
		mouse["x"] = mp.x
		mouse["y"] = mp.y
		var gp: Variant = cam.ground_point(mp)
		if gp != null:
			ground["x"] = gp.x
			ground["z"] = gp.z
		_pick(cam)
	if g.abilities != null:
		g.abilities.aim = {"x": ground["x"], "z": ground["z"]}
	if g.views != null and "hover_id" in g.views:
		g.views.hover_id = int(hover["id"]) if (hover != null and hover["kind"] == "enemy") else -1


func _pick(cam: DmCameraRig) -> void:
	var best: Variant = null
	var best_d = 46.0
	var mx: float = mouse["x"]
	var my: float = mouse["y"]
	var test = func(x: float, y: float, z: float, h: Dictionary, radius_px: float) -> void:
		var v = Vector3(x, y, z)
		if cam.is_position_behind(v):
			return
		var s = cam.unproject_position(v)
		var d = Vector2(s.x - mx, s.y - my).length() - radius_px
		if d < best_d:
			best_d = d
			best = h
	for e in g.sim.enemies.values():
		if e.state == "dead" or e.state == "rising" or e.state == "burrow":
			continue
		test.call(e.x, 0.9 * e.scale, e.z, {"kind": "enemy", "id": e.id}, 10.0 if e.elite else 0.0)
	var b = g.sim.boss.state
	if b.active:
		test.call(b.x, 2.4, b.z, {"kind": "boss"}, 40.0)
	if best == null:
		best_d = 60.0
		for it in interactables_near():
			test.call(float(it["x"]), 1.2, float(it["z"]), {"kind": "interact", "it": it}, 0.0)
	if best == null:
		best_d = 52.0
		for n in _nodes:
			if absf(float(n["x"]) - g.player.x) > 26.0 or absf(float(n["z"]) - g.player.z) > 22.0:
				continue
			var kind: String = String(DmGathering.node_def(String(n["type"]))["kind"])
			test.call(float(n["x"]), 1.6 if kind == "tree" else (0.1 if kind == "pool" else 0.5), float(n["z"]), {"kind": "node", "node": n}, 14.0 if kind == "tree" else 6.0)
	hover = best
	if g.gather != null and g.has_method("node_hover"):
		g.node_hover(hover)


func cursor_target() -> Dictionary:
	var h: Variant = hover
	if h != null and h["kind"] == "enemy":
		var e: DmSimEnemy = g.sim.enemies.get(int(h["id"]))
		if e != null:
			return {"x": e.x, "z": e.z, "enemyId": e.id}
	if h != null and h["kind"] == "boss":
		var b = g.sim.boss.state
		return {"x": b.x, "z": b.z, "boss": true}
	return {"x": ground["x"], "z": ground["z"]}


# ---- clicks --------------------------------------------------------------------------------------------------------------------

func on_primary_click() -> void:
	if not g.ready_ or not g.player.alive:
		return
	update_cursor()
	g.actions.cancel_recall()
	queued_cast = null
	var h: Variant = hover
	var shift: bool = mouse["shift"]
	if h != null and h["kind"] == "laborer" and not shift:
		g.open_panel("labor")
		return
	if h != null and h["kind"] == "node" and not shift:
		attack_target = null
		pending_interact = null
		if g.gather != null:
			g.gather.stop("moved")
			var refusal: Variant = g.gather.start(h["node"])
			if refusal != null and String(refusal) != "":
				g.float_text(g.player.x, 2.4, g.player.z, String(refusal), "info")
				g.play_sfx("error")
			else:
				g.play_sfx("click")
				g.emit_game_event("gather_started", {"rich": h["node"].get("rich", false) == true})
		return
	if g.gather != null:
		g.gather.stop("moved")
	var target = cursor_target()
	if DmSimMath.hypot(target["x"] - g.player.x, target["z"] - g.player.z) > STAND_PAD:
		g.player.face(target["x"], target["z"])
	if shift:
		if h != null and (h["kind"] == "enemy" or h["kind"] == "boss"):
			attack_target = h
		g.player.stop()
		return
	if h != null and (h["kind"] == "enemy" or h["kind"] == "boss"):
		attack_target = h
		pending_interact = null
		g.player.stop()
		return
	attack_target = null
	if h != null and h["kind"] == "interact":
		pending_interact = h["it"]
		g.player.move_to(float(h["it"]["x"]), float(h["it"]["z"]) + 1.4)
		return
	pending_interact = null
	g.player.move_to(ground["x"], ground["z"])
	if g.visual:
		g.vfx.decal({"tex": "ring", "color": 0xb6a9c8, "x": ground["x"], "z": ground["z"], "r": 0.45, "duration": 0.35, "opacity": 0.62, "growFrom": 1.6})


## The minimap's click: walk there if it is walkable ground. Returns true when a path exists.
func navigate_from_minimap(x: float, z: float) -> bool:
	if not g.ready_ or not g.player.alive or g.panel_open:
		return false
	var area: String = g.nav.area_at(x, z)
	var corridor = false
	for d in DmContent.doors():
		if g.nav.is_door_open(d) and x >= float(d["rect"]["x0"]) and x <= float(d["rect"]["x1"]) and z >= float(d["rect"]["z0"]) and z <= float(d["rect"]["z1"]):
			corridor = true
			break
	if (not g.nav.is_unlocked(area)) if area != "" else (not corridor):
		return false
	var r: Array = g.nav.resolve(x, z, 0.45)
	g.actions.cancel_recall()
	if g.gather != null:
		g.gather.stop("moved")
	attack_target = null
	pending_interact = null
	queued_cast = null
	auto_target_id = -1
	auto_aim = null
	if DmSimMath.hypot(r[0] - g.player.x, r[1] - g.player.z) > 0.25:
		g.player.face(r[0], r[1])
	g.player.move_to(r[0], r[1])
	g.emit_game_event("minimap_travel")
	return g.player.has_path()


# ---- casting -------------------------------------------------------------------------------------------------------------------

func cast_slot(slot: int) -> void:
	if not g.ready_ or not g.player.alive:
		return
	if g.gather != null:
		g.gather.stop("moved")
	update_cursor()
	g.actions.cancel_recall()
	auto_target_id = -1
	auto_aim = null
	var id: String = String(g.hotbar[slot - 1]) if slot - 1 < g.hotbar.size() else ""
	if id == "":
		return
	# Corpse Explosion and Grave Step pick from the exact ground point, not a hovered enemy's position.
	var target: Dictionary = {"x": ground["x"], "z": ground["z"]} if (id == "corpse_explosion" or id == "grave_step") else cursor_target()
	var res: String = g.do_cast(id, target, g.now_ms)
	if res == "busy" or (res == "cooldown" and DmPlayerRules.cooldown_left(g.p, id, g.now_ms) <= 220.0):
		queued_cast = {"slot": slot, "target": target, "until": g.now_ms + 220.0}
		return
	feedback(res, id)
	if res == "ok":
		g.emit_game_event("slot_flash", {"slot": slot})


func cast_slot_primary() -> void:
	if g.ready_ and g.player.alive:
		update_cursor()
		g.do_cast(g.primary, cursor_target(), g.now_ms)


func feedback(res: String, id: String) -> void:
	if res == "ok" or res == "range" or res == "no_target":
		return
	var now: float = g.now_ms
	if now - last_feedback < 600.0:
		return
	last_feedback = now
	var name: String = String(DmAbilities.def(id)["name"])
	var text = ""
	match res:
		"essence":
			g.emit_game_event("essence_short")
			text = "Not enough Grave Essence"
		"cooldown": text = "%s is not ready" % name
		"no_corpse": text = "No corpse in reach"
		"locked": text = "%s unlocks at level %d" % [name, int(DmAbilities.unlock_level(id))]
		"no_thralls": text = "You command no thralls"
	if text != "":
		g.float_text(g.player.x, 2.4, g.player.z, text, "info")
		g.play_sfx("error")


func primary_range() -> float:
	return DmWeaponLine.ability_range(g.primary, float(DmAbilities.def(g.primary)["range"]), g.p["loadout"])


func panel_gate() -> bool:
	return g.panel_open


func tick_combat(now: float) -> void:
	var player: DmPlayer = g.player
	if not player.alive or g.recall_at > 0.0:
		return
	if g.panel_open:
		queued_cast = null
		auto_target_id = -1
		auto_aim = null
		return
	if queued_cast != null:
		var q: Dictionary = queued_cast
		if now > float(q["until"]):
			queued_cast = null
		elif g.abilities.ready(String(g.hotbar[int(q["slot"]) - 1]), now):
			queued_cast = null
			var id: String = String(g.hotbar[int(q["slot"]) - 1])
			if g.do_cast(id, q["target"], now) == "ok":
				g.emit_game_event("slot_flash", {"slot": int(q["slot"])})
			return
	# Held number keys repeat only when the selected spell is ready.
	for slot in range(1, 6):
		if keys.has(str(slot)):
			if g.abilities.ready(String(g.hotbar[slot - 1]), now):
				cast_slot(slot)
			return
	# Easy auto yields to deliberate movement, menus, gathering and manual targets.
	if not g.settings_store.can_use_auto_combat() or not bool(g.settings["auto_combat"]) or player.has_path() or attack_target != null or not keys.is_empty() or (g.gather != null and g.gather.get("active") == true):
		auto_target_id = -1
		auto_aim = null
		return
	if now < next_auto_at or _auto == null:
		return
	next_auto_at = now + 180.0
	var thralls: int = g.actions.legion_places()
	if float(g.p["hp"]) < player.max_hp() * 0.42 and now >= g.actions.flask_cd_until and not bool(g.prog.vow_fx().get("noFlasks", false)) and (g.inventory.count("flask_hp_grand") > 0 or g.inventory.count("flask_hp_major") > 0 or g.inventory.count("flask_hp_minor") > 0):
		g.actions.drink_flask()
	var res: Dictionary = g.p["resource"]
	var act: Variant = _auto.select_action({
		"player": {"x": player.x, "z": player.z, "area": player.area, "essence": res["value"], "maxEssence": res["max"], "hp": g.p["hp"], "maxHp": player.max_hp(),
			"veilForm": g.p["veilForm"], "bulwarkUntil": g.p["bulwarkUntil"], "betweenUntil": g.p["betweenUntil"], "unbreakableUntil": g.p["unbreakableUntil"]},
		"enemies": g.sim.enemies.values(), "corpses": g.sim.corpses.values(), "boss": g.sim.boss.state,
		"thrallCount": thralls, "thrallCap": g.discipline["mods"]["thrallCap"],
		"ready": func(id: String) -> bool: return (id == g.primary or g.hotbar.has(id)) and g.abilities.ready(id, now),
		"primary": g.primary, "primaryRange": primary_range(), "selfId": g.self_id, "family": g.discipline["family"],
		"signature": g.hotbar[5], "now": now})
	var previous: DmSimEnemy = g.sim.enemies.get(auto_target_id) if auto_target_id >= 0 else null
	if act != null and act["target"].get("enemyId") != null:
		auto_target_id = int(act["target"]["enemyId"])
	elif previous != null and previous.hp > 0.0 and previous.state != "dead" and DmSimMath.hypot(previous.x - player.x, previous.z - player.z) <= primary_range():
		auto_target_id = previous.id
	else:
		auto_target_id = -1
	if act != null:
		auto_aim = act["target"]
	elif auto_target_id < 0 and not (auto_aim != null and auto_aim.get("boss", false) and g.sim.boss.state.active and g.sim.boss.state.hp > 0.0):
		auto_aim = null
	if act != null and act["target"].get("enemyId") != null:
		auto_mem["targetId"] = act["target"]["enemyId"]
	if act != null and g.do_cast(act["id"], act["target"], now) == "ok":
		g.emit_game_event("auto_combat_cast")
		var slot: int = g.hotbar.find(act["id"]) + 1
		if slot > 0:
			g.emit_game_event("slot_flash", {"slot": slot})


## Easy auto's dodge list: live boss telegraphs plus hostile ground pools near the hero.
func dodge_hazards() -> Array:
	_dodge.clear()
	if not g.sim.boss.state.active and telegraphs != null:
		telegraphs.clear()
	if telegraphs != null:
		_dodge.append_array(telegraphs.active(g.now_ms))
	for z in g.sim.zones.values():
		if z.hostile and z.dps > 0.0 and DmSimMath.hypot(z.x - g.player.x, z.z - g.player.z) < 40.0 and _auto != null:
			_dodge.append(load("res://game/dm_auto_dodge.gd").pool_hazard(z, g.PLAYER_RADIUS))
	return _dodge


func auto_movement(dt: float, now: float) -> Variant:
	var player: DmPlayer = g.player
	if _auto == null or not g.settings_store.can_use_auto_combat() or not bool(g.settings["auto_combat"]) or not player.alive or g.panel_open or g.recall_at > 0.0 or player.has_path() or attack_target != null or pending_interact != null or (g.gather != null and g.gather.get("active") == true) or not keys.is_empty():
		auto_mem["dir"] = null
		return null
	var res: Dictionary = g.p["resource"]
	var d: Variant = _auto.select_movement({
		"player": {"x": player.x, "z": player.z, "area": player.area, "essence": res["value"], "maxEssence": res["max"], "hp": g.p["hp"], "maxHp": player.max_hp()},
		"enemies": g.sim.enemies.values(), "primary": g.primary, "primaryRange": primary_range(), "family": g.discipline["family"], "nav": g.nav, "hazards": dodge_hazards()}, auto_mem, now, dt)
	if d == null:
		auto_mem["dir"] = null
	return d


func key_dir() -> KeyDir:
	var kd = KeyDir.new()
	kd.x = (1.0 if (keys.has("d") or keys.has("arrowright")) else 0.0) - (1.0 if (keys.has("a") or keys.has("arrowleft")) else 0.0)
	kd.z = (1.0 if (keys.has("s") or keys.has("arrowdown")) else 0.0) - (1.0 if (keys.has("w") or keys.has("arrowup")) else 0.0)
	return kd


func attack_target_pos() -> Variant:
	var t: Variant = attack_target
	if t == null:
		return null
	if t["kind"] == "boss":
		var b = g.sim.boss.state
		return {"x": b.x, "z": b.z} if b.active else null
	var e: DmSimEnemy = g.sim.enemies.get(int(t["id"]))
	return {"x": e.x, "z": e.z} if (e != null and e.state != "dead") else null


## Auto-attack: chase into range, then the primary.
func update_attack_target(now: float) -> void:
	if attack_target == null or not g.player.alive:
		return
	var tgt: Variant = attack_target_pos()
	if tgt == null:
		attack_target = null
		return
	var t: Dictionary = {"x": tgt["x"], "z": tgt["z"]}
	if attack_target["kind"] == "boss":
		t["boss"] = true
	else:
		t["enemyId"] = int(attack_target["id"])
	var short: float = g.abilities.shortfall(g.primary, t)
	if short > 0.0 and not bool(mouse["shift"]):
		g.player.move_to(tgt["x"], tgt["z"])
	else:
		g.player.stop()
		if g.abilities.ready(g.primary, now):
			g.do_cast(g.primary, t, now)


## Standing: the mouse turns the hero to aim without changing position.
func aim_when_standing(now: float) -> void:
	var player: DmPlayer = g.player
	if player.alive and bool(mouse["aiming"]) and not player.moving and not player.has_path() and attack_target == null and auto_aim == null and now >= float(g.p["castUntil"]) and not (g.gather != null and g.gather.get("active") == true):
		var target = cursor_target()
		if DmSimMath.hypot(target["x"] - player.x, target["z"] - player.z) > STAND_PAD:
			player.face(target["x"], target["z"])


## The Kill Chain break and the monk's bell beat tick every frame.
func tick_chain_and_beat(now: float) -> void:
	var broke: int = g.rewards.chain.tick(now)
	if broke >= int(DmProgContent.get_data()["chain"]["reportAt"]):
		g.play_sfx("chainBreak")
		g.float_text(g.player.x, 2.6, g.player.z, "Chain broken: %d" % broke, "info")
	if g.discipline["family"] == "monk" and g.player.alive:
		var beat = int(floor(now / 1200.0))
		if beat != _last_beat:
			_last_beat = beat
			g.play_sfx("tollSmall", g.player.x, g.player.z, 0.18)
