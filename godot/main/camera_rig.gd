class_name DmCameraRig
extends Camera3D
## The web's fixed three-quarter ARPG camera (CameraRig.ts): fov 40, dist 22*zoom, ~55deg pitch, eased follow, wheel zoom.

var cfg: Dictionary
var focus := Vector3.ZERO
var zoom := 1.0
var target_zoom := 1.0

func setup(c: Dictionary) -> void:
	cfg = c
	fov = float(c.fov)
	near = float(c.near)
	far = float(c.far)
	current = true

func zoom_step(sign_: float) -> void:
	target_zoom = clampf(target_zoom + sign_ * 0.12, float(cfg.zoomMin), float(cfg.zoomMax))

func snap(p: Vector3) -> void:
	focus = Vector3(p.x, 0, p.z)
	update_rig(0.0, p)

func update_rig(dt: float, p: Vector3) -> void:
	var k := 1.0 if dt == 0.0 else 1.0 - exp(-dt * float(cfg.followRate))
	focus.x += (p.x - focus.x) * k
	focus.z += (p.z - focus.z) * k
	zoom += (target_zoom - zoom) * (1.0 if dt == 0.0 else 1.0 - exp(-dt * 8.0))
	var dist: float = float(cfg.dist) * zoom
	global_position = Vector3(focus.x, dist * float(cfg.heightFactor), focus.z + dist * float(cfg.backFactor))
	look_at(Vector3(focus.x, float(cfg.lookAtY), focus.z + float(cfg.lookAheadZ)), Vector3.UP)

func ground_point(screen: Vector2) -> Variant:
	var o := project_ray_origin(screen)
	var d := project_ray_normal(screen)
	if absf(d.y) < 0.0001:
		return null
	var t := -o.y / d.y
	if t < 0.0:
		return null
	return o + d * t
