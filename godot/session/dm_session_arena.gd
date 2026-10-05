class_name DmSessionArena
extends Node3D
## Minimal playable test arena: flat ground, light, camera, a DmSession child named "Session". Right-click on the ground = move there.
## Self-contained; not wired into DmGame. Host/join by calling `session.host(peer)` / `session.join(peer)`.

@onready var session: DmSession = $Session


func _ready() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(DmSession.ARENA_HALF * 2.0, DmSession.ARENA_HALF * 2.0)
	ground.mesh = pm
	add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.position = Vector3(0, 18, 14)
	add_child(cam)
	cam.look_at(Vector3.ZERO)


func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT):
		return
	var cam := $Camera as Camera3D
	var o := cam.project_ray_origin(ev.position)
	var d := cam.project_ray_normal(ev.position)
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(o, d)
	if hit != null:
		session.request_move_to(hit)
