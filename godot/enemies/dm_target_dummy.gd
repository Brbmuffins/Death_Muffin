class_name DmTargetDummy
extends CharacterBody3D
## Player stand-in for the enemy arena: honours the DmEnemy target contract (group "dm_target", dm_alive, dm_take_enemy_hit), has an HP pool
## and a floating HP label. In the editor, WASD / arrow keys move it (physical keys, no input-map entry needed); Space heals it.

signal hit(damage: float, from: Node)

@export var max_hp: float = 1000.0
@export var controllable: bool = true
@export var move_speed: float = 5.0
var hp: float = 0.0
var hits_taken: int = 0

func _ready() -> void:
	hp = max_hp
	add_to_group(&"dm_target")
	collision_layer = DmEnemy.LAYER_PLAYER
	collision_mask = DmEnemy.LAYER_WORLD
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_label()

func dm_alive() -> bool:
	return hp > 0.0

func dm_take_enemy_hit(damage: float, from: Node) -> void:
	hp = maxf(0.0, hp - damage)
	hits_taken += 1
	hit.emit(damage, from)
	_label()

func _label() -> void:
	var l: Label3D = get_node_or_null("Label")
	if l != null:
		l.text = "%d / %d" % [int(hp), int(max_hp)]

func _physics_process(_delta: float) -> void:
	if not controllable or not DisplayServer.window_is_focused():
		return
	var v := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		v.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		v.z += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		v.x += 1.0
	if Input.is_physical_key_pressed(KEY_SPACE):
		hp = max_hp
		_label()
	velocity = v.normalized() * move_speed
	move_and_slide()
