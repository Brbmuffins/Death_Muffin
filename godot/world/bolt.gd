class_name DmBolt
extends Node3D
## The hero's primary: a Bone Needle (bone_needle: range 11, radius 0.35, power 1.0). PLACEHOLDER visuals: a small bone-white glow.

var dir := Vector3.FORWARD
var speed := 24.0
var damage := 10.0
var radius := 0.35
var traveled := 0.0
var max_range := 11.0
var on_hit: Callable

func _ready() -> void:
	var sm := SphereMesh.new()
	sm.radius = 0.14
	sm.height = 0.28
	sm.radial_segments = 8
	sm.rings = 4
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.95, 0.92, 0.8)
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _process(dt: float) -> void:
	var step := speed * dt
	global_position += dir * step
	traveled += step
	for e in get_tree().get_nodes_in_group("enemies"):
		if not e.alive:
			continue
		var d := Vector2(e.global_position.x - global_position.x, e.global_position.z - global_position.z).length()
		if d < radius + e.radius:
			e.take_damage(damage)
			if on_hit.is_valid():
				on_hit.call(e)
			queue_free()
			return
	if traveled >= max_range:
		queue_free()
