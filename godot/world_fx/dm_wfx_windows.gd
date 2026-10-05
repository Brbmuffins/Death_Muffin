class_name DmWfxWindows
extends RefCounted
## Stained-glass windows (WorldView.buildWindows): an unshaded, untonemapped glass pane on the wall plus a slanted additive shaft of
## coloured light down to the floor. Counts, sizes, colours and offsets are the web's; they come from layout.windows.

const GLASS_TEX := "res://world_fx/assets/stained_glass.webp"
static var _glass: Texture2D

static func glass_texture() -> Texture2D:
	if _glass == null and ResourceLoader.exists(GLASS_TEX):
		_glass = load(GLASS_TEX)
	return _glass

## Returns the two nodes for one window: [pane, shaft].
static func build(parent: Node3D, w: Dictionary) -> Array:
	var tex := glass_texture()
	var pane := MeshInstance3D.new()
	pane.name = "GlassPane"
	var qm := QuadMesh.new()
	qm.size = Vector2(float(w.w), float(w.h))
	pane.mesh = qm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_BACK   # a three PlaneGeometry is front-side only
	m.albedo_texture = tex
	m.albedo_color = DmWfxData.hex(0xcfb8ff)
	m.disable_fog = true
	pane.material_override = m
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(pane)
	pane.position = Vector3(float(w.x), float(w.y), float(w.z))
	pane.rotation.y = float(w.facing)
	pane.translate_object_local(Vector3(0, 0, 0.5))

	var shaft := MeshInstance3D.new()
	shaft.name = "GlassShaft"
	var sq := QuadMesh.new()
	sq.size = Vector2(float(w.w) * 0.9, 14.0)
	shaft.mesh = sq
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_texture = DmFxTex.get_tex("glow")
	sm.albedo_color = Color(DmWfxData.hex(0x6d4bd6), 0.16)
	shaft.material_override = sm
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(shaft)
	shaft.position = Vector3(float(w.x), float(w.y) * 0.45, float(w.z))
	shaft.rotation.y = float(w.facing)
	shaft.translate_object_local(Vector3(0, 0, 5))
	shaft.rotate_object_local(Vector3.RIGHT, -0.55)
	return [pane, shaft]
