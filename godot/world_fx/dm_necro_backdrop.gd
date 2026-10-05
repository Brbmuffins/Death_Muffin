class_name DmNecroBackdrop
extends Node3D
## Login / discipline-select backdrop (src/graphics/NecroBackdrop.ts): the burning-graveyard vista as a deep matte, with parallax, drifting
## grave-mist, embers and a ritual sigil. Camera fov 40 at (0, 1.6, 12), eased toward the mouse, looking at (0 | -9 on a narrow window, 2, -20).
## Bloom {strength 0.75, radius 0.6, threshold 0.78}. `DmNecroBackdrop.make_layer()` returns a SubViewportContainer to put behind the UI
## (stretches with its parent); the node itself can also be added to any 3D tree with its own Camera3D (`camera`).

const MATTE_TEX := "res://front/art/login-backdrop-pyre.webp"
const BLOOM := {"strength": 0.75, "radius": 0.6, "threshold": 0.78}

var camera: Camera3D
var matte: MeshInstance3D
var sigil: MeshInstance3D
var mist: DmWfxParticles
var embers: DmWfxParticles
var env: Environment
var t := 0.0
var reduced_motion := false
var mouse := Vector2.ZERO   # -1..1, set from the pointer by the host (make_layer wires it)
var narrow := false
var rng := RandomNumberGenerator.new()

static func make_layer() -> SubViewportContainer:
	var c := SubViewportContainer.new()
	c.name = "NecroBackdropLayer"
	c.stretch = true
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.handle_input_locally = false
	c.add_child(vp)
	var b := DmNecroBackdrop.new()
	vp.add_child(b)
	c.set_meta("backdrop", b)
	return c

func _ready() -> void:
	build()

func build() -> void:
	name = "NecroBackdrop"
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.hex(0x07060aff)
	DmWfxBloom.apply(env, true, BLOOM)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.near = 0.1
	camera.far = 200.0
	camera.current = true
	add_child(camera)
	camera.position = Vector3(0, 1.6, 12)
	# the matte: 96 x 54 at (0, 6, -48), never fogged
	matte = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(96, 54)
	matte.mesh = qm
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_color = DmWfxData.hex(0xe8dfe0)
	if ResourceLoader.exists(MATTE_TEX):
		mm.albedo_texture = load(MATTE_TEX)
	mm.disable_fog = true
	matte.material_override = mm
	matte.position = Vector3(0, 6, -48)
	add_child(matte)
	# the ritual sigil: 9 x 9 flat additive plane at (0, -2.4, -4), colour 0xc26537, opacity 0.3
	sigil = MeshInstance3D.new()
	var sq := QuadMesh.new()
	sq.size = Vector2(9, 9)
	sq.orientation = PlaneMesh.FACE_Y
	sigil.mesh = sq
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_texture = DmFxTex.get_tex("sigil")
	sm.albedo_color = Color(DmWfxData.hex(0xc26537), 0.3)
	sigil.material_override = sm
	sigil.position = Vector3(0, -2.4, -4)
	add_child(sigil)
	# Effects' smoke (normal blend) and glow (additive) systems
	mist = DmWfxParticles.new()
	add_child(mist)
	mist.configure(256, DmFxTex.get_tex("smoke"), false)
	embers = DmWfxParticles.new()
	add_child(embers)
	embers.configure(256, DmFxTex.get_tex("glow"), true)
	_aim(1.0)

## One web frame (NecroBackdrop.update). `dt` seconds; the camera ease is per frame (0.03), like the web.
func tick(dt: float) -> void:
	t += dt
	var still := reduced_motion
	# mist banks and motes
	if not still and rng.randf() < dt * 6.0:
		mist.emit((rng.randf() - 0.5) * 40.0, -2.0 + rng.randf(), -6.0 - rng.randf() * 14.0, DmWfxData.hex(0x3a3048), 2.0, 0.4, 0.05, 9.0, 9.0, 0.0, 0.1, -0.6)
	if not still and rng.randf() < dt * 14.0:
		var left := rng.randf() < 0.62
		var x := -9.0 - rng.randf() * 9.0 if left else 2.0 + rng.randf() * 10.0
		embers.emit(x, -2.5, -2.0 - rng.randf() * 12.0, DmWfxData.hex(0xf29a4d) if left else DmWfxData.hex(0x9b5cff), 0.5, 0.15, 1.25 if left else 0.9, 5.0, 0.16, 0.0, 0.2)
	sigil.rotation.y += dt * 0.05
	(sigil.material_override as StandardMaterial3D).albedo_color.a = 0.25 + sin(t * 0.9) * 0.05
	_aim(0.03)
	mist._update(dt)
	embers._update(dt)

func _aim(k: float) -> void:
	var still := reduced_motion
	var tx := 0.0 if still else mouse.x * 1.4 + sin(t * 0.1) * 0.4
	var ty := 1.6 if still else 1.6 - mouse.y * 0.6
	camera.position.x += (tx - camera.position.x) * k
	camera.position.y += (ty - camera.position.y) * k
	camera.look_at(Vector3(-9.0 if narrow else 0.0, 2.0, -20.0), Vector3.UP)

func _process(dt: float) -> void:
	var vp := get_viewport()
	if vp != null:
		var s := vp.get_visible_rect().size
		narrow = s.x < 640.0
		var host := vp.get_parent()
		var m := vp.get_mouse_position() if not (host is SubViewportContainer) else (host as SubViewportContainer).get_local_mouse_position()
		mouse = Vector2(m.x / maxf(s.x, 1.0) * 2.0 - 1.0, m.y / maxf(s.y, 1.0) * 2.0 - 1.0)
	tick(dt)
