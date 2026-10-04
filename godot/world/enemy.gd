class_name DmEnemy
extends Node3D
## A Graves enemy. Stats (hp, speed, damage, attackRange, windup, cooldown, radius, scale, corpse kind) come from enemies.json
## (the real ENEMIES table). Behaviour is a simplified take on the web AI: PLACEHOLDER = every behaviour walks toward the
## nearest target and strikes in melee/cone range after its windup; flanking, the Ghoul's burrow, the Sac's hazard and the Penitent's
## exact cone are not ported yet.

var def: Dictionary
var main: DmMain
var hp: float
var max_hp: float
var alive := true
var rising := 0.6
var state := "chase"  # chase | windup | cooldown | dead
var state_t := 0.0
var _path: PackedVector3Array = PackedVector3Array()
var _path_i := 0
var _repath := 0.0
var _anim: AnimationPlayer
var _animator: DmAnimator
var _model_root: Node3D
var corpse_kind := "normal"
var radius := 0.45
var speed := 2.0
var _spawn_scale := 1.0

func setup(d: Dictionary, m: Node, model: Dictionary) -> void:
	def = d
	main = m
	max_hp = float(d.hp)
	hp = max_hp
	radius = float(d.radius) * float(d.scale)
	speed = float(d.speed)
	corpse_kind = d.corpse
	var c := DmModels.creature_from(model, float(d.scale))
	_model_root = c.root
	_anim = c.anim
	_animator = c.animator
	add_child(_model_root)
	_model_root.scale = Vector3.ONE * 0.2
	_repath = randf() * 0.4
	add_to_group("enemies")
	_animator.loco(0.0)
	if float(d.get("hover", 0.0)) > 0.0:
		_model_root.position.y = float(d.hover)

func take_damage(amount: float, from_dir: Vector3 = Vector3.ZERO) -> void:
	if not alive:
		return
	hp -= amount
	DmFx.float_text(main, global_position + Vector3(0, 2.0, 0), str(int(round(amount))), Color(1.0, 0.92, 0.6), 34)
	if hp <= 0.0:
		_die()
	else:
		_animator.hurt()

func _die() -> void:
	alive = false
	state = "dead"
	remove_from_group("enemies")
	add_to_group("corpses")
	if _animator.death():
		pass
	else:
		# Models without a death clip tip over (as in the web).
		var tw := create_tween()
		tw.tween_property(_model_root, "rotation:z", PI / 2.0, 0.4)
		_model_root.position.y = 0.0
	main.on_enemy_killed(self)

func _target() -> Node3D:
	return main.pick_target(global_position)

func _process(dt: float) -> void:
	if rising > 0.0:
		rising -= dt
		var k := clampf(1.0 - rising / 0.6, 0.0, 1.0)
		_model_root.scale = Vector3.ONE * lerpf(0.2, 1.0, k)
		if rising > 0.0:
			return
	if not alive:
		return
	_animator.tick(dt)
	var t := _target()
	if t == null:
		_animator.loco(0.0)
		return
	var to := t.global_position - global_position
	to.y = 0.0
	var dist := to.length()
	var reach: float = float(def.attackRange)
	var stop_at: float = reach * 0.85
	if def.behavior == "caster":
		stop_at = reach * 0.8
	match state:
		"chase":
			if dist <= reach + radius * 0.5:
				state = "windup"
				state_t = float(def.windupMs) / 1000.0
				_play_attack()
			else:
				_move_toward(t.global_position, dt)
		"windup":
			_face(to, dt)
			state_t -= dt
			if state_t <= 0.0:
				_strike(t, dist)
				state = "cooldown"
				state_t = float(def.cooldownMs) / 1000.0
		"cooldown":
			_face(to, dt)
			state_t -= dt
			if def.behavior != "caster" and dist > reach * 1.4:
				state = "chase"
			elif state_t <= 0.0:
				state = "chase"
			else:
				_animator.loco(0.0)
	_separate(dt)

func _play_attack() -> void:
	var nm := "cast" if def.get("caster", false) and _anim != null and _anim.has_animation("cast") else "attack"
	_animator.strike(nm, float(def.windupMs) / 1000.0)

func _strike(t: Node3D, dist: float) -> void:
	var reach: float = float(def.attackRange)
	if dist <= reach + 0.8 + (radius if def.behavior != "caster" else 0.0):
		if t.has_method("take_hit"):
			t.take_hit(float(def.damage), self)
	_anim_after_strike()

func _anim_after_strike() -> void:
	pass

func _face(dir: Vector3, dt: float) -> void:
	if dir.length() < 0.01:
		return
	var want := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, want, clampf(dt * 12.0, 0.0, 1.0))

func _move_toward(goal: Vector3, dt: float) -> void:
	_repath -= dt
	if _repath <= 0.0 or _path.is_empty():
		_repath = 0.45 + randf() * 0.15
		_path = main.world_nav_path(global_position, goal)
		_path_i = 1 if _path.size() > 1 else 0
	var dest := goal
	if _path_i < _path.size():
		dest = _path[_path_i]
		if Vector2(dest.x - global_position.x, dest.z - global_position.z).length() < 0.35 and _path_i < _path.size() - 1:
			_path_i += 1
			dest = _path[_path_i]
	var dir := dest - global_position
	dir.y = 0.0
	if dir.length() > 0.01:
		dir = dir.normalized()
		global_position += dir * speed * dt
		global_position.y = 0.0
		_face(dir, dt)
	_animator.loco(speed)

func _separate(dt: float) -> void:
	for o in get_tree().get_nodes_in_group("enemies"):
		if o == self:
			continue
		var d: Vector3 = global_position - o.global_position
		d.y = 0.0
		var min_d: float = radius + o.radius
		var l := d.length()
		if l < min_d and l > 0.001:
			global_position += d / l * (min_d - l) * 0.5 * minf(1.0, dt * 12.0)
