class_name DmNecroBackdrop
extends SubViewportContainer
## src/graphics/NecroBackdrop.ts: the login / discipline-select vista. A real 3D scene in its own SubViewport, like the web's: the burning-graveyard matte
## (96 x 54 plane at z -48, tint e8dfe0) behind a camera that drifts with the pointer (parallax), a ritual sigil lying on the ground (additive, c26537, slowly
## turning, opacity 0.25 +- 0.05), drifting grave-mist banks and embers (62% orange on the left, violet on the right). `still` (Settings -> Reduce motion) keeps
## the camera fixed and spawns no mist or embers.

const MATTE_PATH := "res://front/art/login-backdrop-pyre.webp"
const SIGIL_PATH := "res://assets/fx/tex/sigil.png"
const SMOKE_PATH := "res://assets/fx/tex/smoke.png"
const GLOW_PATH := "res://assets/fx/tex/glow.png"

var still := false
var viewport: SubViewport
var camera: Camera3D
var matte: MeshInstance3D
var sigil: MeshInstance3D
var mist: CPUParticles3D
var embers_left: CPUParticles3D
var embers_right: CPUParticles3D
var _t := 0.0
var _mouse := Vector2.ZERO   # -1..1 like the web's pointer


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.handle_input_locally = false
	viewport.gui_disable_input = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("07060a")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	var we := WorldEnvironment.new()
	we.environment = env
	viewport.add_child(we)
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.near = 0.1
	camera.far = 200.0
	camera.position = Vector3(0, 1.6, 12)
	viewport.add_child(camera)
	matte = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(96, 54)
	matte.mesh = q
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_texture = load(MATTE_PATH)
	mm.albedo_color = Color("e8dfe0")
	matte.material_override = mm
	matte.position = Vector3(0, 6, -48)
	viewport.add_child(matte)
	sigil = MeshInstance3D.new()
	var sq := QuadMesh.new()
	sq.size = Vector2(9, 9)
	sigil.mesh = sq
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_texture = load(SIGIL_PATH)
	sm.albedo_color = Color(0.7608, 0.3961, 0.2157, 0.3)
	sm.disable_receive_shadows = true
	sigil.material_override = sm
	sigil.rotation = Vector3(-PI / 2.0, 0, 0)
	sigil.position = Vector3(0, -2.4, -4)
	viewport.add_child(sigil)
	mist = _make_mist()
	viewport.add_child(mist)
	embers_left = _make_embers(Color("f29a4d"), Vector3(-13.5, -2.5, -8.0), Vector3(4.5, 0.05, 6.0), 44, 1.25)
	embers_right = _make_embers(Color("9b5cff"), Vector3(7.0, -2.5, -8.0), Vector3(5.0, 0.05, 6.0), 27, 0.9)
	viewport.add_child(embers_left)
	viewport.add_child(embers_right)
	# warm the camera: look_at needs the camera inside the tree
	camera.look_at_from_position(camera.position, Vector3(0, 2, -20))
	set_process(true)


func _make_mist() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 54                       # 6 / s over a 9 s life
	p.lifetime = 9.0
	p.preprocess = 9.0                  # the banks are already there when the scene opens
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(20, 0.5, 7)
	p.position = Vector3(0, -1.5, -13)
	p.direction = Vector3(0, 0.1, 0)
	p.spread = 180.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = 0.1
	p.initial_velocity_max = 0.4
	p.damping_min = 0.1
	p.damping_max = 0.1
	p.scale_amount_min = 9.0
	p.scale_amount_max = 9.0
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.7))
	sc.add_point(Vector2(1, 1.3))
	p.scale_amount_curve = sc
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.75, 1.0])
	g.colors = PackedColorArray([Color(0.227, 0.188, 0.282, 0.0), Color(0.227, 0.188, 0.282, 0.9), Color(0.227, 0.188, 0.282, 0.9), Color(0.227, 0.188, 0.282, 0.0)])
	p.color_ramp = g
	var qm := QuadMesh.new()
	qm.size = Vector2(1, 1)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = load(SMOKE_PATH)
	m.disable_receive_shadows = true
	m.no_depth_test = false
	qm.material = m
	p.mesh = qm
	return p


func _make_embers(col: Color, center: Vector3, extents: Vector3, amount: int, up: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = 5.0
	p.preprocess = 5.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = extents
	p.position = center
	p.direction = Vector3(0, 1, 0)
	p.spread = 12.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = up * 0.85
	p.initial_velocity_max = up * 1.15
	p.damping_min = 0.2
	p.damping_max = 0.2
	p.scale_amount_min = 0.16
	p.scale_amount_max = 0.16
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	g.colors = PackedColorArray([Color(col, 0.0), Color(col, 1.0), Color(col, 0.0)])
	p.color_ramp = g
	var qm := QuadMesh.new()
	qm.size = Vector2(1, 1)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = load(GLOW_PATH)
	m.disable_receive_shadows = true
	qm.material = m
	p.mesh = qm
	return p


func set_still(on: bool) -> void:
	still = on
	for p in [mist, embers_left, embers_right]:
		(p as CPUParticles3D).emitting = not on


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var vs := get_viewport_rect().size
		if vs.x > 0.0 and vs.y > 0.0:
			_mouse = Vector2((event.position.x / vs.x) * 2.0 - 1.0, (event.position.y / vs.y) * 2.0 - 1.0)


## NecroBackdrop.update: the sigil turns and breathes, the camera eases toward the pointer (0.03 per frame at 60 fps).
func _process(dt: float) -> void:
	_t += dt
	sigil.rotation.z += dt * 0.05   # (the quad lies flat: its spin axis is the world Y)
	var sm := sigil.material_override as StandardMaterial3D
	sm.albedo_color.a = 0.25 + sin(_t * 0.9) * 0.05
	var tx := 0.0 if still else _mouse.x * 1.4 + sin(_t * 0.1) * 0.4
	var ty := 1.6 if still else 1.6 - _mouse.y * 0.6
	var k := 1.0 - pow(1.0 - 0.03, dt * 60.0)
	camera.position.x += (tx - camera.position.x) * k
	camera.position.y += (ty - camera.position.y) * k
	var narrow := get_viewport_rect().size.x < 640.0
	camera.look_at(Vector3(-9.0 if narrow else 0.0, 2.0, -20.0))
