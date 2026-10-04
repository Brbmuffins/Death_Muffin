class_name DmHero
extends CharacterBody3D
## The Ossuary necromancer. Click-to-move over the baked navmesh (NavigationServer path), WASD alternative, LMB on an enemy =
## chase + Bone Needle, Shift+LMB / hold = fire at cursor, key 1 = Exhume (raise nearest corpse to the cursor as a thrall).
## Stats: hero.json (deriveStats at level 1, base stats 5 = placeholder for a real character) and the real ABILITIES entries.

var data: Dictionary
var main: DmMain
var cam: DmCameraRig
var hp: float
var max_hp: float
var essence: float
var max_essence: float
var move_speed: float
var spell_power: float
var needle: Dictionary
var exhume: Dictionary
var _anim: AnimationPlayer
var _model_root: Node3D
var _path: PackedVector3Array = PackedVector3Array()
var _path_i := 0
var _target: Node3D = null
var _needle_cd := 0.0
var _exhume_cd := 0.0
var _action_t := 0.0
var _repath_t := 0.0
var alive := true
var kills := 0
var qa_input_disabled := false
var cursor_ground := Vector3.ZERO
var _stuck := 0.0

func setup(h: Dictionary, m: Node, c: DmCameraRig) -> void:
	data = h
	main = m
	cam = c
	var s: Dictionary = h.derivedStats
	max_hp = float(s.maxHp)
	hp = max_hp
	max_essence = float(s.maxEssence)
	essence = max_essence
	move_speed = float(s.moveSpeed)
	spell_power = float(s.spellPower)
	needle = h.abilities.bone_needle
	exhume = h.abilities.exhume
	var mi: Dictionary = h.model
	var cr := DmModels.creature(mi.url, float(mi.height), float(mi.yaw))
	_model_root = cr.root
	_anim = cr.anim
	add_child(_model_root)
	var col := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.radius = 0.45
	cs.height = 1.6
	col.shape = cs
	col.position.y = 0.8
	add_child(col)
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_ring()
	DmModels.play(_anim, "idle", 1.0, 0.0)

func _ring() -> void:
	# The web draws a pale ring + soft dark contact shadow under the hero so it stays findable.
	var im := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 31.5
			im.set_pixel(x, y, Color(0.94, 0.91, 1.0, smoothstep(0.1, 0.0, absf(d - 0.9)) * 0.7))
	var qm := QuadMesh.new()
	qm.size = Vector2(1.6, 1.6)
	qm.orientation = PlaneMesh.FACE_Y
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = ImageTexture.create_from_image(im)
	var mi := MeshInstance3D.new()
	mi.mesh = qm
	mi.material_override = m
	mi.position.y = 0.05
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func teleport(p: Vector3) -> void:
	global_position = Vector3(p.x, 0, p.z)
	_path = PackedVector3Array()
	_target = null

func take_hit(amount: float, _from: Node) -> void:
	if not alive:
		return
	var thralls := get_tree().get_nodes_in_group("thralls").size()
	var ward := minf(0.6, float(data.discipline.wardPerThrall) * thralls)  # Bone Ward: 10% less damage per active thrall
	var dmg := amount * (1.0 - ward)
	hp -= dmg
	DmFx.float_text(main, global_position + Vector3(0, 2.3, 0), "-%d" % int(round(dmg)), Color(1.0, 0.35, 0.3), 38)
	if hp <= 0.0:
		# PLACEHOLDER: no death/respawn flow yet; the slice just refills so the comparison run is not interrupted.
		hp = max_hp
		DmFx.float_text(main, global_position + Vector3(0, 2.8, 0), "(slice: no death flow, hp reset)", Color(0.8, 0.8, 0.8), 28, 1.0, 1.6)

func _unhandled_input(ev: InputEvent) -> void:
	if qa_input_disabled:
		return
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			click(ev.position, Input.is_key_pressed(KEY_SHIFT))
		elif ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam.zoom_step(-1.0)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam.zoom_step(1.0)
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.physical_keycode == KEY_1:
			var gp: Variant = cam.ground_point(get_viewport().get_mouse_position())
			do_exhume(gp if gp != null else global_position)

func click(screen: Vector2, stand_and_fire: bool) -> void:
	var gp: Variant = cam.ground_point(screen)
	if gp == null:
		return
	var foe: DmEnemy = main.enemy_near(gp, 1.6)
	if stand_and_fire:
		_target = null
		fire_at(gp)
	elif foe != null:
		_target = foe
		_path = PackedVector3Array()
	else:
		_target = null
		move_to(gp)

func move_to(p: Vector3) -> void:
	_path = main.world_nav_path(global_position, p)
	_path_i = 1 if _path.size() > 1 else 0

func fire_at(p: Vector3) -> bool:
	if _needle_cd > 0.0 or not alive:
		return false
	var dir := p - global_position
	dir.y = 0.0
	if dir.length() < 0.05:
		dir = Vector3(0, 0, 1)
	dir = dir.normalized()
	_needle_cd = float(needle.cooldownMs) / 1000.0
	rotation.y = atan2(dir.x, dir.z)
	_action_t = 0.28
	if _anim != null and _anim.has_animation("attack"):
		_anim.play("attack", 0.04, 2.2)
	var b := DmBolt.new()
	b.dir = dir
	b.damage = spell_power * float(needle.power)
	b.radius = float(needle.radius)
	b.max_range = float(needle.range)
	b.on_hit = func(_e): essence = minf(max_essence, essence + 6.0)  # bone_needle: each hit returns 6 Grave Essence
	main.add_child(b)
	b.global_position = global_position + Vector3(0, 1.2, 0) + dir * 0.6
	return true

func do_exhume(at: Vector3) -> bool:
	if _exhume_cd > 0.0 or not alive:
		return false
	var cost := float(exhume.essenceCost)
	if essence < cost:
		DmFx.float_text(main, global_position + Vector3(0, 2.4, 0), "not enough essence", Color(0.7, 0.6, 1.0), 28)
		return false
	var corpse: Node3D = main.corpse_near(at, float(exhume.radius), global_position, float(exhume.range))
	if corpse == null:
		DmFx.float_text(main, global_position + Vector3(0, 2.4, 0), "no corpse in reach", Color(0.7, 0.7, 0.7), 28)
		return false
	essence -= cost
	_exhume_cd = float(exhume.cooldownMs) / 1000.0
	_action_t = 0.6
	var dir: Vector3 = corpse.global_position - global_position
	rotation.y = atan2(dir.x, dir.z)
	if _anim != null and _anim.has_animation("cast"):
		_anim.play("cast", 0.05, 1.8)
	main.raise_thrall(corpse)
	return true

func _wasd() -> Vector3:
	if qa_input_disabled:
		return Vector3.ZERO
	var v := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): v.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S): v.z += 1.0
	if Input.is_physical_key_pressed(KEY_A): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D): v.x += 1.0
	return v.normalized()

func _physics_process(dt: float) -> void:
	_needle_cd = maxf(0.0, _needle_cd - dt)
	_exhume_cd = maxf(0.0, _exhume_cd - dt)
	_action_t = maxf(0.0, _action_t - dt)
	essence = minf(max_essence, essence + float(data.derivedStats.essenceRegen) * dt)
	var wish := _wasd()
	var moving := false
	var vel := Vector3.ZERO
	if not qa_input_disabled and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.is_key_pressed(KEY_SHIFT):
		var gp: Variant = cam.ground_point(get_viewport().get_mouse_position())
		if gp != null:
			fire_at(gp)
	if wish != Vector3.ZERO:
		_path = PackedVector3Array()
		_target = null
		vel = wish * move_speed
	elif _target != null and is_instance_valid(_target) and _target.alive:
		var to: Vector3 = _target.global_position - global_position
		to.y = 0.0
		if to.length() > float(needle.range) * 0.8:
			_repath_t -= dt
			if _repath_t <= 0.0 or _path.is_empty():
				_repath_t = 0.3
				move_to(_target.global_position)
			vel = _follow_path()
		else:
			_path = PackedVector3Array()
			if _action_t <= 0.0:
				fire_at(_target.global_position)
			else:
				rotation.y = atan2(to.x, to.z)
	elif _path.size() > 0:
		vel = _follow_path()
	else:
		_target = null
	if vel.length() > 0.05:
		moving = true
		velocity = vel
		var before := global_position
		move_and_slide()
		global_position.y = 0.0
		# Stuck on a collider while following a path: drop the path (the player clicks again / the chase re-plans).
		if wish == Vector3.ZERO and (global_position - before).length() < vel.length() * dt * 0.25:
			_stuck += dt
			if _stuck > 0.5:
				_path = PackedVector3Array()
				_stuck = 0.0
		else:
			_stuck = 0.0
		if _action_t <= 0.0:
			rotation.y = lerp_angle(rotation.y, atan2(vel.x, vel.z), clampf(dt * 14.0, 0.0, 1.0))
	if _action_t <= 0.0:
		DmModels.play(_anim, "run" if moving else "idle", 1.0, 0.15)

func _follow_path() -> Vector3:
	while _path_i < _path.size():
		var dest := _path[_path_i]
		var d := Vector2(dest.x - global_position.x, dest.z - global_position.z)
		if d.length() < 0.3:
			_path_i += 1
			continue
		var dir := Vector3(d.x, 0, d.y).normalized()
		return dir * move_speed
	_path = PackedVector3Array()
	return Vector3.ZERO
