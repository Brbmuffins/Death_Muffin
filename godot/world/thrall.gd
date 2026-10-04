class_name DmThrall
extends Node3D
## A raised thrall (Ossuary: shieldbearer kind -> thrall_sentinel model). hp / damage / speed / range / interval come from hero.json
## (derived stats + WorldSim THRALL_BASE.shieldbearer). PLACEHOLDER: follow slots and target choice are simpler than the web's.

var data: Dictionary
var main: DmMain
var hero: Node3D
var hp: float
var max_hp: float
var alive := true
var slot := 0
var born := 0.0
var _anim: AnimationPlayer
var _animator: DmAnimator
var _model_root: Node3D
var _atk_cd := 0.4
var _path: PackedVector3Array = PackedVector3Array()
var _path_i := 0
var _repath := 0.0
var _rise := 0.9
var radius := 0.45

func setup(t: Dictionary, m: Node, h: Node3D, model: Dictionary, slot_i: int) -> void:
	data = t
	main = m
	hero = h
	slot = slot_i
	max_hp = float(t.hp)
	hp = max_hp
	var c := DmModels.creature_from(model)
	_model_root = c.root
	_anim = c.anim
	_animator = c.animator
	add_child(_model_root)
	_model_root.scale = Vector3.ONE * 0.3
	add_to_group("thralls")
	_animator.loco(0.0)

func take_hit(amount: float, _from: Node) -> void:
	if not alive:
		return
	hp -= amount
	DmFx.float_text(main, global_position + Vector3(0, 2.0, 0), str(int(round(amount))), Color(0.6, 0.8, 1.0), 30)
	if hp <= 0.0:
		crumble()

func crumble() -> void:
	if not alive:
		return
	alive = false
	remove_from_group("thralls")
	var tw := create_tween()
	tw.tween_property(_model_root, "scale", Vector3.ONE * 0.05, 0.5)
	tw.tween_callback(queue_free)
	main.on_thrall_gone(self)

func _nearest_enemy(maxd: float) -> Node3D:
	var best: Node3D = null
	var bd := maxd
	for e in get_tree().get_nodes_in_group("enemies"):
		if not e.alive:
			continue
		var d: float = e.global_position.distance_to(global_position)
		if d < bd:
			bd = d
			best = e
	return best

func _process(dt: float) -> void:
	if _rise > 0.0:
		_rise -= dt
		_model_root.scale = Vector3.ONE * lerpf(0.3, 1.0, clampf(1.0 - _rise / 0.9, 0.0, 1.0))
		return
	if not alive:
		return
	_animator.tick(dt)
	_atk_cd -= dt
	var foe := _nearest_enemy(11.0)
	# Leash: stay near the hero; fight what comes within reach of the pair.
	if foe != null and foe.global_position.distance_to(hero.global_position) > 13.0:
		foe = null
	var speed: float = float(data.speed)
	if foe != null:
		var d := foe.global_position.distance_to(global_position)
		var reach: float = float(data.range)
		if d <= reach + foe.radius:
			_face(foe.global_position - global_position, dt)
			if _atk_cd <= 0.0:
				_atk_cd = float(data.interval)
				foe.take_damage(float(data.damage))
				_animator.strike("attack", 0.2)
			else:
				_animator.loco(0.0)
		else:
			_go(foe.global_position, speed, dt)
	else:
		var ang := float(slot) * TAU / 3.0 + 0.6
		var home := hero.global_position + Vector3(cos(ang), 0, sin(ang)) * 2.6
		if home.distance_to(global_position) > 1.0:
			_go(home, speed * (1.35 if home.distance_to(global_position) > 6.0 else 1.0), dt)
		else:
			_animator.loco(0.0)

func _go(goal: Vector3, speed: float, dt: float) -> void:
	_repath -= dt
	if _repath <= 0.0 or _path.is_empty():
		_repath = 0.4
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

func _face(dir: Vector3, dt: float) -> void:
	if dir.length() < 0.01:
		return
	rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), clampf(dt * 12.0, 0.0, 1.0))
