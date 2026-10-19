class_name DmWraithGhost
extends Node3D
## The look of Haunting Wraith's wraith: a barrow ghoul (a stand-in until the wraith has its own model) drawn large, pale and see-through, striding along
## the wraith's path for `life` seconds and then fading out. Picture only: the damage runs on the host (rite_haunting_wraith.gd).

const FADE_S := 0.4
const SCALE := 1.9      ## times the ghoul's own height

var _cr: DmCreature
var _dir := Vector2.ZERO
var _speed := 0.0
var _left := 0.0


static func spawn(parent: Node, x: float, z: float, dx: float, dz: float, speed: float, life: float, node_name: String) -> DmWraithGhost:
	var g := DmWraithGhost.new()
	g.name = node_name
	g._dir = Vector2(dx, dz)
	g._speed = speed
	g._left = life
	g._cr = DmCreature.new("barrow_ghoul", {"scale": SCALE, "spectral": true, "cast_shadow": false, "tint": 0xb8f5d0,
		"emissive": 0x4cff9a, "emissive_intensity": 0.6})
	g.add_child(g._cr.root)
	g._cr.root.rotation.y = atan2(dx, dz)
	g._cr.set_ground_speed(speed)
	parent.add_child(g)
	g.position = Vector3(x, 0.0, z)
	return g


func _process(dt: float) -> void:
	_left -= dt
	if _left <= -FADE_S:
		queue_free()
		return
	if _left > 0.0:
		position.x += _dir.x * _speed * dt
		position.z += _dir.y * _speed * dt
	else:
		_cr.set_opacity(clampf(1.0 + _left / FADE_S, 0.0, 1.0))
	_cr.update(dt)
