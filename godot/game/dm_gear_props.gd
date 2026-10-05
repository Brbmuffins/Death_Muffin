class_name DmGearProps
extends RefCounted
## Code-built props for worn gear and the thralls' hand props (port of src/graphics/gearProps.ts + the gear.ts look helpers
## gearTier / weaponKind / offhandKind, plus EntityViews' boneSword / boneBow / boneStaff / roundShield). Every prop's +Y is its long
## axis with the grip at the origin, in world units. Weapons carry `meta("tip")` (a Node3D, the spell origin).
## The baked `gear_*` / `gear_thrall_bow` / `gear_bone_staff` GLBs are NOT in godot/assets/slice (the slice sync never copied them):
## the code-built stand-ins (the web's own fallback while a GLB loads, or if it fails) are what shows.

const TIERS := {
	"wood": {"color": 0x4a3626, "metal": 0.05, "rough": 0.85},
	"leather": {"color": 0x6b4f34, "metal": 0.05, "rough": 0.9},
	"bone": {"color": 0xd8cfbd, "metal": 0.05, "rough": 0.7},
	"copper": {"color": 0xb87333, "metal": 0.75, "rough": 0.4},
	"iron": {"color": 0x7a7d86, "metal": 0.8, "rough": 0.42},
	"steel": {"color": 0xb9c2d0, "metal": 0.9, "rough": 0.3},
	"gold": {"color": 0xd9a441, "metal": 0.9, "rough": 0.28, "glow": 0x6b4a10},
	"hell": {"color": 0x8a2a1a, "metal": 0.7, "rough": 0.4, "glow": 0xa02510},
	"moon": {"color": 0xaab8e8, "metal": 0.85, "rough": 0.3, "glow": 0x3a4a9a},
}
const THRALL_BOW_FILE := "gear_thrall_bow"

static var _glow_tex: Texture2D

static func col(hex: int) -> Color:
	return Color(float((hex >> 16) & 255) / 255.0, float((hex >> 8) & 255) / 255.0, float(hex & 255) / 255.0)

static func _dim(hex: int, k: float) -> int:
	var r := roundi(((hex >> 16) & 255) * k)
	var g := roundi(((hex >> 8) & 255) * k)
	var b := roundi((hex & 255) * k)
	return (r << 16) | (g << 8) | b

static func armor_by_id(id: String) -> Dictionary:
	var d: Variant = DmContent.get_export("armorSets", "ARMOR_BY_ID")
	return d.get(id, {}) if d is Dictionary else {}

static func necro_by_id(id: String) -> Dictionary:
	var d: Variant = DmContent.get_export("necroWeapons", "NECRO_WEAPON_BY_ID")
	return d.get(id, {}) if d is Dictionary else {}

## gearTier: a material tier guessed from the item id. {color, metal, rough, glow (-1 = none)}
static func tier(item_id: String, rarity: String = "") -> Dictionary:
	var armor := armor_by_id(item_id)
	if not armor.is_empty():
		var coll := int(armor.collection)
		var glow := -1
		if coll == 3:
			glow = _dim(int(armor.accent), 0.3)
		elif coll == 2 or armor.rarity == "epic":
			glow = _dim(int(armor.accent), 0.22 if coll == 2 else 0.14)
		var did := String(armor.disciplineId)
		return {"color": int(armor.color), "metal": 0.75 if (did == "knight" or did == "warden") else 0.24,
			"rough": 0.3 if coll == 3 else (0.38 if coll == 2 else 0.55), "glow": glow}
	for key in ["moon", "hell", "gold", "steel", "iron", "copper", "bone"]:
		if item_id.contains(key):
			return _t(TIERS[key])
	var re := RegEx.new()
	re.compile("oak|wood|apprentice|spike")
	if re.search(item_id) != null:
		return _t(TIERS.wood)
	match rarity:
		"epic": return _t(TIERS.gold)
		"rare": return _t(TIERS.steel)
		"uncommon": return _t(TIERS.iron)
	return _t(TIERS.leather)

static func _t(t: Dictionary) -> Dictionary:
	return {"color": t.color, "metal": t.metal, "rough": t.rough, "glow": t.get("glow", -1)}

static func weapon_kind(id: String) -> String:
	for pair in [["scythe", "scythe"], ["sickle", "sickle"], ["wand", "wand"], ["staff|focus", "staff"], ["bow", "bow"], ["dagger|knife", "dagger"], ["mace|hammer|club|flail", "mace"], ["tome|book", "tome"]]:
		var re := RegEx.new()
		re.compile(pair[0])
		if re.search(id) != null:
			return pair[1]
	return "sword"

static func offhand_kind(id: String) -> String:
	if id.contains("skull_focus"):
		return "skull"
	if id.contains("mourning_bell"):
		return "bell"
	var re := RegEx.new()
	re.compile("tome|book|lantern|grimoire")
	return "tome" if re.search(id) != null else "shield"

# ----------------------------------------------------------------------------------------------------------------- primitives

static func _mat(color: int, metal := 0.0, rough := 0.8, glow := -1, glow_k := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col(color)
	m.metallic = metal
	m.roughness = rough
	if glow >= 0:
		m.emission_enabled = true
		m.emission = col(glow)
		m.emission_energy_multiplier = glow_k
	return m

static func _metal(t: Dictionary) -> StandardMaterial3D:
	return _mat(t.color, t.metal, t.rough, t.glow, 0.5)

static func _leather() -> StandardMaterial3D:
	return _mat(0x2b211c, 0.0, 0.9)

static func _mi(mesh: Mesh, mat: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.position = pos
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return m

static func _box(w: float, h: float, d: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(w, h, d)
	return b

static func _cyl(rt: float, rb: float, h: float, seg := 8) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = rt
	c.bottom_radius = rb
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

static func _sph(r: float, sy := 1.0) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0 * sy
	s.radial_segments = 12
	s.rings = 8
	return s

static func _torus(r: float, tube: float) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = maxf(0.001, r - tube)
	t.outer_radius = r + tube
	t.rings = 18
	t.ring_segments = 6
	return t

static func _tip(g: Node3D, y: float) -> Node3D:
	var t := Node3D.new()
	t.position.y = y
	g.add_child(t)
	g.set_meta("tip", t)
	return t

static func glow_texture() -> Texture2D:
	if _glow_tex == null:
		var gt := GradientTexture2D.new()
		var gr := Gradient.new()
		gr.set_color(0, Color(1, 1, 1, 1))
		gr.set_color(1, Color(1, 1, 1, 0))
		gt.gradient = gr
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.5)
		gt.fill_to = Vector2(1.0, 0.5)
		gt.width = 64
		gt.height = 64
		_glow_tex = gt
	return _glow_tex

static func glow_sprite(color: int, size: float, opacity := 1.0) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = glow_texture()
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.shaded = false
	s.transparent = true
	s.modulate = Color(col(color), opacity)
	s.pixel_size = size / 64.0
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = glow_texture()
	mat.albedo_color = Color(col(color), opacity)
	mat.no_depth_test = false
	s.material_override = mat
	return s

# ----------------------------------------------------------------------------------------------------------------- weapons

static func _sword(t: Dictionary, length: float, width: float) -> Node3D:
	var g := Node3D.new()
	var metal := _metal(t)
	g.add_child(_mi(_box(width, length, 0.02), metal, Vector3(0, 0.12 + length / 2.0, 0)))
	g.add_child(_mi(_box(width * 3.6, 0.045, 0.05), metal, Vector3(0, 0.1, 0)))
	g.add_child(_mi(_cyl(0.02, 0.02, 0.2, 6), _leather()))
	g.add_child(_mi(_sph(0.03), metal, Vector3(0, -0.11, 0)))
	_tip(g, 0.12 + length)
	return g

static func _staff(t: Dictionary) -> Node3D:
	var g := Node3D.new()
	g.add_child(_mi(_cyl(0.025, 0.035, 1.8, 6), _mat(0x3a2b20, 0.0, 0.85), Vector3(0, 0.4, 0)))
	g.add_child(_mi(_sph(0.075), _metal(t), Vector3(0, 1.32, 0)))
	var gem := glow_sprite(int(t.glow) if int(t.glow) >= 0 else 0xb6a9c8, 0.4, 0.7)
	gem.position.y = 1.36
	g.add_child(gem)
	g.set_meta("tip", gem)
	return g

static func _bow(t: Dictionary) -> Node3D:
	var g := Node3D.new()
	var limb := _mi(_arc(0.45, 0.025, PI * 0.85), _mat(t.color, t.metal * 0.3, 0.7))
	limb.rotation.z = PI / 2.0 + PI * 0.075
	g.add_child(limb)
	var s := _mi(_cyl(0.006, 0.006, 0.8, 3), _unshaded(0x9a8a70), Vector3(-0.1, 0, 0))
	g.add_child(s)
	_tip(g, 0.4)
	return g

static func _unshaded(color: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col(color)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

## TorusGeometry(radius, tube, 5, 14, arc): an arc of a torus in the XY plane, starting at +X, built as a swept tube.
static func _arc(r: float, tube: float, arc: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 14
	var sides := 5
	for i in segs:
		for j in sides:
			var pts := []
			for di in [[0, 0], [1, 0], [1, 1], [0, 1]]:
				var u := float(i + di[0]) / segs * arc
				var v := float(j + di[1]) / sides * TAU
				var c := Vector3(cos(u) * r, sin(u) * r, 0)
				var n := Vector3(cos(u) * cos(v), sin(u) * cos(v), sin(v))
				pts.append(c + n * tube)
			st.add_vertex(pts[0]); st.add_vertex(pts[2]); st.add_vertex(pts[1])
			st.add_vertex(pts[0]); st.add_vertex(pts[3]); st.add_vertex(pts[2])
	st.generate_normals()
	return st.commit()

static func _mace(t: Dictionary) -> Node3D:
	var g := Node3D.new()
	g.add_child(_mi(_cyl(0.025, 0.03, 0.85, 6), _leather(), Vector3(0, 0.25, 0)))
	var metal := _metal(t)
	g.add_child(_mi(_sph(0.11), metal, Vector3(0, 0.72, 0)))
	for i in 6:
		var a := float(i) / 6.0 * TAU
		var spike := _mi(_cyl(0.0, 0.03, 0.09, 5), metal, Vector3(cos(a) * 0.11, 0.72, sin(a) * 0.11))
		spike.rotation.z = -cos(a) * PI / 2.0
		spike.rotation.x = sin(a) * PI / 2.0
		g.add_child(spike)
	_tip(g, 0.78)
	return g

static func _tome(t: Dictionary) -> Node3D:
	var g := Node3D.new()
	g.add_child(_mi(_box(0.26, 0.34, 0.07), _mat(0x3a2432, 0.0, 0.8), Vector3(0, 0.18, 0)))
	g.add_child(_mi(_box(0.05, 0.08, 0.085), _metal(t), Vector3(0.13, 0.18, 0)))
	_tip(g, 0.36)
	return g

static func _necro_fallback(kind: String, t: Dictionary) -> Node3D:
	var g := Node3D.new()
	var metal := _metal(t)
	match kind:
		"staff":
			return _staff(t)
		"scythe":
			g.add_child(_mi(_cyl(0.022, 0.028, 1.95, 7), _mat(0x2a211b, 0.0, 0.85), Vector3(0, 0.36, 0)))
			var blade := _mi(_blade(0.72, 0.16, 0.07, 0.018), metal, Vector3(0.01, 1.28, 0))
			blade.rotation.y = PI / 2.0
			g.add_child(blade)
			g.add_child(_mi(_sph(0.05), metal, Vector3(0, 1.29, 0)))
			_tip(g, 1.3)
		"wand":
			g.add_child(_mi(_cyl(0.014, 0.02, 0.24, 7), _leather()))
			g.add_child(_mi(_cyl(0.008, 0.014, 0.26, 7), metal, Vector3(0, 0.19, 0)))
			var shard := _mi(_sph(0.035), metal, Vector3(0, 0.36, 0))
			shard.scale = Vector3(0.8, 1.7, 0.8)
			g.add_child(shard)
			var guard := _mi(_torus(0.03, 0.006), metal, Vector3(0, 0.07, 0))
			g.add_child(guard)
			_tip(g, 0.4)
		"sickle":
			g.add_child(_mi(_cyl(0.018, 0.022, 0.26, 7), _leather(), Vector3(0, -0.02, 0)))
			var b2 := _mi(_blade(0.3, 0.1, 0.05, 0.012), metal, Vector3(0, 0.22, 0))
			b2.rotation = Vector3(0, PI / 2.0, PI / 2.0)
			g.add_child(b2)
			g.add_child(_mi(_torus(0.022, 0.006), metal, Vector3(0, -0.17, 0)))
			_tip(g, 0.42)
		"skull_focus":
			var bone := _mat(t.color, t.metal * 0.4, maxf(0.45, t.rough), t.glow, 0.4)
			var cr := _mi(_sph(0.11), bone, Vector3(0, 0.26, 0))
			cr.scale = Vector3(1, 1.05, 1.1)
			g.add_child(cr)
			g.add_child(_mi(_box(0.11, 0.05, 0.12), bone, Vector3(0, 0.155, 0.02)))
			for x in [-0.04, 0.04]:
				g.add_child(_mi(_sph(0.026), _unshaded(0x0b0810), Vector3(x, 0.27, 0.09)))
			g.add_child(_mi(_cyl(0.018, 0.024, 0.2, 7), _leather(), Vector3(0, 0.05, 0)))
			_tip(g, 0.3)
		"mourning_bell":
			var body := _mi(_bell_body(), metal)
			g.add_child(body)
			g.add_child(_mi(_cyl(0.014, 0.018, 0.1, 6), _leather(), Vector3(0, 0.04, 0)))
			g.add_child(_mi(_sph(0.026), metal, Vector3(0, -0.3, 0)))
			_tip(g, -0.12)
		_:
			return _tome(t)
	return g

static func _blade(len: float, bulge: float, thick: float, depth: float) -> ArrayMesh:
	# Crescent in the XY plane (extrudeFlat of crescent()): root at the origin, sweeping +X and curling back to the point.
	var top := PackedVector2Array()
	var bot := PackedVector2Array()
	var n := 10
	for i in n + 1:
		var u := float(i) / n
		# cubic bezier (0,0) -> (len*.25, bulge) (len*.75, bulge*.7) (len, -bulge*1.5)
		var p := _bez(Vector2(0, 0), Vector2(len * 0.25, bulge), Vector2(len * 0.75, bulge * 0.7), Vector2(len, -bulge * 1.5), u)
		top.append(p)
		var q := _bez(Vector2(len, -bulge * 1.5), Vector2(len * 0.7, bulge * 0.1), Vector2(len * 0.3, bulge * 0.05 - thick), Vector2(0, -thick), u)
		bot.append(q)
	var outline := PackedVector2Array()
	outline.append_array(top)
	outline.append_array(bot)
	var idx := Geometry2D.triangulate_polygon(outline)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in [depth / 2.0, -depth / 2.0]:
		for k in range(0, idx.size(), 3):
			var tri := [idx[k], idx[k + 1], idx[k + 2]]
			if face < 0:
				tri = [idx[k], idx[k + 2], idx[k + 1]]
			for vi in tri:
				st.add_vertex(Vector3(outline[vi].x, outline[vi].y, face))
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		st.add_vertex(Vector3(a.x, a.y, depth / 2.0)); st.add_vertex(Vector3(b.x, b.y, depth / 2.0)); st.add_vertex(Vector3(b.x, b.y, -depth / 2.0))
		st.add_vertex(Vector3(a.x, a.y, depth / 2.0)); st.add_vertex(Vector3(b.x, b.y, -depth / 2.0)); st.add_vertex(Vector3(a.x, a.y, -depth / 2.0))
	st.generate_normals()
	return st.commit()

static func _bez(a: Vector2, b: Vector2, c: Vector2, d: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return a * u * u * u + b * 3.0 * u * u * t + c * 3.0 * u * t * t + d * t * t * t

static func _bell_body() -> ArrayMesh:
	var pts := [[0.0, 0.0], [0.05, -0.01], [0.075, -0.06], [0.085, -0.15], [0.12, -0.26], [0.135, -0.3], [0.125, -0.315], [0.0, -0.28]]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 18
	for i in pts.size() - 1:
		for s in seg:
			var a0 := float(s) / seg * TAU
			var a1 := float(s + 1) / seg * TAU
			var p00 := Vector3(pts[i][0] * cos(a0), pts[i][1], pts[i][0] * sin(a0))
			var p01 := Vector3(pts[i][0] * cos(a1), pts[i][1], pts[i][0] * sin(a1))
			var p10 := Vector3(pts[i + 1][0] * cos(a0), pts[i + 1][1], pts[i + 1][0] * sin(a0))
			var p11 := Vector3(pts[i + 1][0] * cos(a1), pts[i + 1][1], pts[i + 1][0] * sin(a1))
			st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
			st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)
	st.generate_normals()
	return st.commit()

## A main-hand weapon for the given item id.
static func build_weapon(item_id: String, rarity: String = "") -> Node3D:
	var t := tier(item_id, rarity)
	var necro := necro_by_id(item_id)
	if not necro.is_empty():
		return _necro_fallback(String(necro.kind), t)
	match weapon_kind(item_id):
		"staff": return _staff(t)
		"bow": return _bow(t)
		"mace": return _mace(t)
		"tome": return _tome(t)
		"dagger": return _sword(t, 0.42, 0.045)
	return _sword(t, 0.95, 0.08)

## An off-hand piece: a round shield (disc axis along X) or a tome.
static func build_offhand(item_id: String, rarity: String = "") -> Node3D:
	var t := tier(item_id, rarity)
	var necro := necro_by_id(item_id)
	if not necro.is_empty():
		return _necro_fallback(String(necro.kind), t)
	if offhand_kind(item_id) == "tome":
		return _tome(t)
	var g := Node3D.new()
	var r := 0.27
	var disc := _mi(_cyl(r, r, 0.05, 20), _metal(t))
	disc.rotation.z = PI / 2.0
	g.add_child(disc)
	var rim := _mi(_torus(r, 0.02), _metal(t))
	rim.rotation.z = PI / 2.0
	g.add_child(rim)
	var bt := t.duplicate()
	bt.color = 0x3a2f55
	bt.glow = int(t.glow) if int(t.glow) >= 0 else 0x7c3aed
	g.add_child(_mi(_sph(r * 0.24), _metal(bt), Vector3(0.05, 0, 0)))
	return g

## A helm that sits on the Head bone: dome, brim and (for the noble tiers) a crest.
static func build_helm(item_id: String, rarity: String = "", scale := 1.0) -> Node3D:
	var t := tier(item_id, rarity)
	var set := armor_by_id(item_id)
	var g := Node3D.new()
	g.scale = Vector3.ONE * scale
	var metal := _metal(t)
	var dome := SphereMesh.new()
	dome.radius = 0.15
	dome.height = 0.3
	dome.is_hemisphere = true
	var seat := Node3D.new()
	seat.position.y = 0.04
	g.add_child(seat)
	seat.add_child(_mi(dome, metal))
	var brim := _mi(_torus(0.15, 0.015), metal, Vector3(0, -0.02, 0))
	seat.add_child(brim)
	if not set.is_empty():
		var acc := int(set.accent)
		var emissive := acc if (set.rarity == "epic" or int(set.collection) == 3) else -1
		var accent := _mat(acc, 0.65, 0.35, emissive, 0.32)
		var jewel := _mi(_sph(0.04), accent, Vector3(0, 0.08, 0.145))
		seat.add_child(jewel)
		var did := String(set.disciplineId)
		if did == "witch" or did == "rotweaver":
			for x in [-0.105, 0.105]:
				var thorn := _mi(_cyl(0.0, 0.025, 0.18, 5), accent, Vector3(x, 0.14, 0))
				thorn.rotation.z = -0.28 if x > 0 else 0.28
				seat.add_child(thorn)
		elif did == "knight" or did == "warden":
			seat.add_child(_mi(_box(0.22, 0.055, 0.025), accent, Vector3(0, 0.035, 0.145)))
			seat.add_child(_mi(_box(0.035, 0.11, 0.19), accent, Vector3(0, 0.18, 0)))
		elif did == "monk" or did == "mourner" or did == "veil":
			seat.add_child(_mi(_torus(0.17, 0.012), accent, Vector3(0, 0.13, 0)))
		else:
			seat.add_child(_mi(_cyl(0.0, 0.055, 0.15, 5), accent, Vector3(0, 0.19, 0)))
		if int(set.collection) >= 2:
			seat.add_child(_mi(_torus(0.165, 0.014), accent, Vector3(0, 0.16, 0)))
			for x in [-0.12, 0.12]:
				seat.add_child(_mi(_cyl(0.0, 0.024, 0.12, 5), accent, Vector3(x, 0.2, -0.02)))
	if int(t.glow) >= 0:
		seat.add_child(_mi(_box(0.025, 0.07, 0.22), metal, Vector3(0, 0.15, 0)))
	return g

## A mastery cape hung from the shoulders (Spine02): cloth arc behind the spine, hem and collar trim, clasp, faint emblem.
static func build_cape(color: int, trim: int) -> Node3D:
	var g := Node3D.new()
	g.position = Vector3(0, 0.16, 0)
	var back := Node3D.new()
	g.add_child(back)
	var cloth := _mat(color, 0.02, 0.92)
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	var edge := _mat(trim, 0.35, 0.5, trim, 0.18)
	edge.cull_mode = BaseMaterial3D.CULL_DISABLED
	var arc := 1.45
	var height := 0.78
	var top := 0.25
	var bottom := 0.37
	back.add_child(_mi(_cape_arc(top, bottom, height, 4, arc), cloth, Vector3(0, -height / 2.0, 0)))
	back.add_child(_mi(_cape_arc(bottom - 0.002, bottom + 0.004, 0.045, 1, arc), edge, Vector3(0, -height + 0.022, 0)))
	back.add_child(_mi(_cape_arc(top + 0.002, top + 0.002, 0.035, 1, arc), edge, Vector3(0, -0.018, 0)))
	back.add_child(_mi(_sph(0.032), edge, Vector3(0, -0.02, -top + 0.005)))
	var emblem := glow_sprite(trim, 0.2, 0.5)
	emblem.position = Vector3(0, -0.3, top + 0.06)
	back.add_child(emblem)
	return g

## CylinderGeometry(top, bottom, h, 16, rows, openEnded, thetaStart = -arc/2, thetaLength = arc), centred on y.
static func _cape_arc(rt: float, rb: float, h: float, rows: int, arc: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 16
	var start := -arc / 2.0
	for y in rows:
		for s in segs:
			var pts := []
			for d in [[0, 0], [1, 0], [1, 1], [0, 1]]:
				var v := float(y + d[1]) / rows
				var th := start + float(s + d[0]) / segs * arc
				var rad := lerpf(rt, rb, v)
				pts.append(Vector3(rad * sin(th), h / 2.0 - v * h, rad * cos(th)))
			st.add_vertex(pts[0]); st.add_vertex(pts[1]); st.add_vertex(pts[2])
			st.add_vertex(pts[0]); st.add_vertex(pts[2]); st.add_vertex(pts[3])
	st.generate_normals()
	return st.commit()

# ----------------------------------------------------------------------------------------------------------------- grips

const BASE_GRIP := {"lean": [0.0, 0.1], "follow": 0.8}
const GRIPS := {
	"staff": {"lean": [0.06, 0.1], "follow": 0.8}, "scythe": {"lean": [0.06, 0.1], "follow": 0.8},
	"wand": {"lean": [0.35, 0.3], "follow": 0.8}, "sickle": {"lean": [0.35, 0.3], "follow": 0.8},
	"skull_focus": {"lean": [0.25, 0.1], "follow": 0.8},
	"grimoire": {"lean": [0.45, 0.15], "offset": [0.04, 0.02, 0.06], "follow": 0.8},
	"mourning_bell": {"lean": [-0.5, 0.2], "offset": [0.05, 0.0, 0.06], "follow": 0.8},
}

## gripFor: how a prop sits in the hand. Right hand = the character's -X side, left +X. -> {dir: Vector3, follow, fit: {roll?, offset?}}
static func grip_for(slot: String, item_id: String, has_tip: bool) -> Dictionary:
	var side := -1.0 if slot == "main_hand" else 1.0
	var necro := necro_by_id(item_id)
	var kind: String = String(necro.kind) if not necro.is_empty() else (weapon_kind(item_id) if slot == "main_hand" else offhand_kind(item_id))
	var spec: Dictionary = GRIPS.get(kind, {"lean": BASE_GRIP.lean, "follow": 0.3 if (slot == "main_hand" and has_tip) else BASE_GRIP.follow})
	var fit := {}
	if spec.has("roll"):
		fit["roll"] = spec.roll
	if spec.has("offset"):
		var o: Array = spec.offset
		fit["offset"] = Vector3(side * o[0], o[1], o[2])
	return {"dir": Vector3(side * spec.lean[0], 1.0, spec.lean[1]), "follow": spec.follow, "fit": fit}

# ----------------------------------------------------------------------------------------------------------------- thrall props (EntityViews.ts)

static func bone_sword(color: int = 0x6f6a74) -> Node3D:
	var g := Node3D.new()
	var metal := _mat(color, 0.7, 0.45)
	g.add_child(_mi(_box(0.06, 0.95, 0.02), metal, Vector3(0, 0.55, 0)))
	g.add_child(_mi(_box(0.26, 0.05, 0.05), metal, Vector3(0, 0.08, 0)))
	return g

static func bone_bow() -> Node3D:
	var g := Node3D.new()
	var limb := _mi(_arc(0.42, 0.025, PI * 0.85), _mat(0xd8cfbd, 0.0, 0.7))
	limb.rotation.z = PI / 2.0 + PI * 0.075
	g.add_child(limb)
	g.add_child(_mi(_cyl(0.006, 0.006, 0.76, 3), _unshaded(0x9a8a70), Vector3(-0.1, 0, 0)))
	return g

static func bone_staff() -> Node3D:
	var g := Node3D.new()
	g.add_child(_mi(_cyl(0.025, 0.035, 1.3, 6), _mat(0xcfc3ad, 0.0, 0.75), Vector3(0, 0.45, 0)))
	g.add_child(_mi(_sph(0.08), _mat(0x5a3a14, 0.0, 0.5, 0xd9a66b, 1.2), Vector3(0, 1.15, 0)))
	return g

static func round_shield(r: float) -> Node3D:
	var g := Node3D.new()
	var disc := _mi(_cyl(r, r, 0.06, 18), _mat(0x4d4033, 0.5, 0.55))
	disc.rotation.z = PI / 2.0
	g.add_child(disc)
	g.add_child(_mi(_sph(r * 0.22), _mat(0x3a2f55, 0.0, 0.5, 0x7c3aed, 0.9), Vector3(0.05, 0, 0)))
	return g

## The legion kit's bow / staff (upgradeThrallProp): the baked GLB is not shipped in the slice, so the stand-in stays, with the
## kit piece's metal washed lightly over it like the web's GLB version does.
static func upgrade_thrall_prop(g: Node3D, _kind: String, item_id: String, rarity: String = "") -> Node3D:
	var t := tier(item_id, rarity)
	for mi in g.find_children("*", "MeshInstance3D", true, false):
		var m := (mi as MeshInstance3D).material_override
		if m is StandardMaterial3D and not (m as StandardMaterial3D).emission_enabled:
			(m as StandardMaterial3D).albedo_color = (m as StandardMaterial3D).albedo_color.lerp(col(t.color), 0.3)
	return g

static func dispose_prop(obj: Node) -> void:
	if obj != null and is_instance_valid(obj):
		obj.queue_free()
