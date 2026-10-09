class_name DmNextInput
extends Node
## Local input for the slice. Click-to-move, WASD / arrows and the hotbar, with this feel: LMB on ground walks
## there, LMB on an enemy fires the primary (slot 0) at it, 1-5 / RMB are rite slots 1-4 / 5 (key 5 and RMB are the same slot), R is slot 6 (the discipline's signature), wheel zooms. Movement goes to the host as
## session intents (`DmSession.request_move_to / request_move_dir`), identical solo or online.
##
## The hotbar is an input SEAM: casters listen to `hotbar` (they never read InputEvents). Actions are registered at runtime in
## `ensure_actions()` (project.godot is not edited): dm_move_up/down/left/right, dm_primary (LMB), dm_secondary (RMB), dm_hotbar_1..6.

signal hotbar(slot: int, aim: Vector3, enemy_id: int)   ## slot 0 = LMB primary, 1..4 = keys, 5 = RMB, 6 = R (signature); enemy_id 0 = ground aim
signal clicked_move(point: Vector3)

const ACTIONS := {
	&"dm_move_up": [KEY_W, KEY_UP], &"dm_move_down": [KEY_S, KEY_DOWN], &"dm_move_left": [KEY_A, KEY_LEFT], &"dm_move_right": [KEY_D, KEY_RIGHT],
	&"dm_hotbar_1": [KEY_1], &"dm_hotbar_2": [KEY_2], &"dm_hotbar_3": [KEY_3], &"dm_hotbar_4": [KEY_4], &"dm_hotbar_5": [KEY_5], &"dm_hotbar_6": [KEY_R],
}
const PICK_PX := 46.0
const HOVER_S := 0.1                    ## the hover pick runs at 10 Hz, not every frame
const RESEND_S := 0.15                  ## held-key direction is re-sent this often (DmSession expires an intent after 0.25 s)

var game: Node                          ## DmNextGame
var enabled: bool = true
var _aim := Vector3.ZERO
var _hover_id: int = 0
var _dir_sent := Vector3.ZERO
var _resend: float = 0.0
var _hover_t: float = 0.0
var combat := DmCombatInput.new()       ## attack-target chase, hold repeat, queued casts, held keys (next/feel/)
var auto := DmNextAutoCombat.new()      ## Easy auto-combat (next/feel/dm_next_auto.gd): gated by the settings, one compare per frame when off
var _mouse_seen := false                ## the mouse has moved / clicked: standing aim follows the cursor (not the stale default point)


static func ensure_actions() -> void:
	for a in ACTIONS:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
			for k in ACTIONS[a]:
				var ev := InputEventKey.new()
				ev.physical_keycode = k
				InputMap.action_add_event(a, ev)
	# No rite_primary on LMB: _primary_click owns the left click (enemy = cast, ground = walk, as the original game); binding it made every
	# ground click also fire Bone Needle through the caster's hold poll.
	for pair in [[&"dm_primary", MOUSE_BUTTON_LEFT], [&"dm_secondary", MOUSE_BUTTON_RIGHT]]:
		if not InputMap.has_action(pair[0]):
			InputMap.add_action(pair[0])
			var m := InputEventMouseButton.new()
			m.button_index = pair[1]
			InputMap.action_add_event(pair[0], m)


func _ready() -> void:
	ensure_actions()


## The ground point under the cursor (updated every frame). Rites aim with this.
func aim_point() -> Vector3:
	return _aim


## The enemy under the cursor (0 = none).
func hovered_enemy_id() -> int:
	return _hover_id


func _process(dt: float) -> void:
	_hover_t -= dt
	if _hover_t > 0.0:
		return
	_hover_t = HOVER_S
	if game == null or game.camera == null or not enabled or DisplayServer.get_name() == "headless":
		return
	var vp := get_viewport()
	if vp == null or vp.get_camera_3d() != game.camera:
		return
	var mp := vp.get_mouse_position()
	var gp: Variant = game.camera.ground_point(mp)
	if gp != null:
		_aim = Vector3(gp.x, 0.0, gp.z)
	_hover_id = _pick_enemy(mp)
	if _mouse_seen:
		stand_face()
	if game.chapterhouse != null:
		game.chapterhouse.hover_at(mp)    # stations / NPCs under the cursor (prompt + highlight)
	if game.get("gather") != null:
		game.gather.hover_at(mp, game.chapterhouse != null and game.chapterhouse.hover != null)   # gathering nodes (ring + card) when no station is hovered


## Left click on an enemy: it becomes the attack target (`shift` = cast in place); the first step is taken now, not next frame.
func attack(enemy_id: int, shift: bool) -> void:
	if combat.game == null:
		combat.setup(game, self)
	combat.set_target(enemy_id, shift)
	combat.tick(float(Time.get_ticks_msec()))


## Standing aim: face the hovered enemy, else the ground point under the cursor (10 Hz, from the hover pick).
func stand_face() -> bool:
	if combat.game == null:
		combat.setup(game, self)
	var e: DmEnemy = game.enemy_by_id(_hover_id) if _hover_id != 0 else null
	return combat.stand_face(e.global_position if e != null else _aim, auto.aim_active)


func _unhandled_input(ev: InputEvent) -> void:
	if not enabled or game == null or game.local_body() == null:
		return
	if ev is InputEventMouseMotion or ev is InputEventMouseButton:
		_mouse_seen = true
	if ev is InputEventMouseButton and ev.pressed:
		var mb := ev as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP: game.camera.zoom_step(-1.0)
			MOUSE_BUTTON_WHEEL_DOWN: game.camera.zoom_step(1.0)
			MOUSE_BUTTON_LEFT: _primary_click(mb.position)
			MOUSE_BUTTON_RIGHT: press_hotbar(5)
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		if (ev as InputEventKey).keycode == KEY_F9 and game.ui_host != null:
			game.ui_host.dev_break_seals()   # dev tool; a no-op unless the host's Dev access is on
			return
		for i in range(1, 7):
			if ev.is_action_pressed(&"dm_hotbar_%d" % i):
				press_hotbar(i)
				combat.key_down(i, float(Time.get_ticks_msec()))


func _physics_process(delta: float) -> void:
	if not enabled or game == null or game.local_body() == null:
		return
	if combat.game == null:
		combat.setup(game, self)
	if auto.game == null:
		auto.setup(game, self)
	var d := held_direction()
	if d != Vector3.ZERO:
		combat.clear()                      # walking by hand ends the chase and the queue (old: key_dir cancels attack_target)
	var now := float(Time.get_ticks_msec())
	combat.tick(now)
	auto.tick(now)
	_resend -= delta
	if d != _dir_sent or (d != Vector3.ZERO and _resend <= 0.0):
		_resend = RESEND_S
		_dir_sent = d
		game.session.request_move_dir(d)


## WASD as a world direction (W = -z, like the web); zero when nothing is held.
func held_direction() -> Vector3:
	return Vector3(Input.get_axis(&"dm_move_left", &"dm_move_right"), 0.0, Input.get_axis(&"dm_move_up", &"dm_move_down"))


func _primary_click(screen: Vector2) -> void:
	var gp: Variant = game.camera.ground_point(screen)
	if gp != null:
		_aim = Vector3(gp.x, 0.0, gp.z)
	_hover_id = _pick_enemy(screen)
	var shift := Input.is_key_pressed(KEY_SHIFT)
	if _hover_id != 0:
		attack(_hover_id, shift)              # walk into range and cast the primary; hold = repeat (Shift: in place)
		return
	combat.clear()
	if shift:
		game.session.request_move_dir(Vector3.ZERO)   # Shift on the ground stands still (old: player.stop())
	elif game.chapterhouse != null and game.chapterhouse.click_at(screen):
		pass                                  # walks to the station / NPC and uses it on arrival
	elif game.get("gather") != null and game.gather.click_at(screen):
		pass                                  # walks to the gathering node and works it
	elif gp != null:
		click_move(_aim)


## Walk to a ground point (also the entry point tests and a future minimap use).
func click_move(point: Vector3) -> void:
	game.session.request_move_to(point)
	clicked_move.emit(point)
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null and DisplayServer.get_name() != "headless":
		vfx.decal({"tex": "ring", "color": 0xb6a9c8, "x": point.x, "z": point.z, "r": 0.45, "duration": 0.35, "opacity": 0.62, "growFrom": 1.6})


## Slot 0 = LMB primary, 1..4 = keys, 5 = RMB, 6 = R (the signature). The aim is the hovered enemy's position when there is one, else the ground point.
func press_hotbar(slot: int) -> void:
	cast_slot(slot, true)


## `manual`: a deliberate press (a refused one is queued for a short window); false = a repeat / the chase / a queued retry.
func cast_slot(slot: int, manual: bool) -> void:
	var b: DmHeroBody = game.local_body()
	if b == null or not b.alive:
		return
	var e: DmEnemy = game.enemy_by_id(_hover_id) if _hover_id != 0 else null
	cast_at(slot, e.global_position if e != null else _aim, _hover_id if e != null else 0, manual)


func cast_at(slot: int, aim: Vector3, enemy_id: int, manual: bool) -> void:
	if combat.game == null:
		combat.setup(game, self)
	combat.note_cast(slot, String(game.rite_for_slot(slot)), aim, enemy_id, manual)
	hotbar.emit(slot, aim, enemy_id)


func _pick_enemy(screen: Vector2) -> int:
	var cam: DmCameraRig = game.camera
	var best := 0
	var best_d := PICK_PX
	var cands: Array = game.director.enemies.values()
	cands.append_array(game.bosses.living())   # bosses are pickable too
	for e in cands:
		var en := e as DmEnemy
		if en == null or not is_instance_valid(en) or en.sm == null:
			continue
		var sid := en.sm.id()
		if sid == DmEnemyState.Id.DEAD or sid == DmEnemyState.Id.RISING:
			continue
		var v := en.global_position + Vector3(0.0, (1.7 if en is DmBoss else 0.9 * en.scale.y), 0.0)
		if cam.is_position_behind(v):
			continue
		var d := cam.unproject_position(v).distance_to(screen)
		if d < best_d:
			best_d = d
			best = int(en.get_meta(&"dm_id", 0))
	return best
