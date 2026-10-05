class_name DmWfxSilhouettes
extends RefCounted
## Far scenery (WorldView.buildSilhouettes / silhouetteGeometry): spires, dead trees and fallen walls, merged into ONE flat-shaded mesh,
## fog-coloured so they read as shapes in the murk. Primitives come pre-resolved from the export (same rand order as the TS); this builds
## the three.js geometry call for call (box = 12 tris, 5-sided cylinder = 20, 4-sided cone = 8) so triangle counts match the web.

## Triangle soup in three.js winding (CCW from outside); the builder flips to Godot's clockwise.
static func _box(w: float, h: float, d: float) -> Array:
	var x := w / 2.0
	var y := h / 2.0
	var z := d / 2.0
	var c := [Vector3(-x, -y, -z), Vector3(x, -y, -z), Vector3(x, y, -z), Vector3(-x, y, -z), Vector3(-x, -y, z), Vector3(x, -y, z), Vector3(x, y, z), Vector3(-x, y, z)]
	# faces, CCW seen from outside
	var f := [[1, 0, 3, 2], [4, 5, 6, 7], [0, 4, 7, 3], [5, 1, 2, 6], [3, 7, 6, 2], [0, 1, 5, 4]]
	var t: Array = []
	for q in f:
		t.append([c[q[0]], c[q[1]], c[q[2]]])
		t.append([c[q[0]], c[q[2]], c[q[3]]])
	return t

## three CylinderGeometry(rt, rb, h, radial, 1, false) triangle list (centred on y=0).
static func _cyl(rt: float, rb: float, h: float, radial: int) -> Array:
	var t: Array = []
	var top: Array = []
	var bot: Array = []
	for i in radial + 1:
		var th := float(i) / float(radial) * TAU
		top.append(Vector3(rt * sin(th), h / 2.0, rt * cos(th)))
		bot.append(Vector3(rb * sin(th), -h / 2.0, rb * cos(th)))
	for i in radial:
		# three: a = top[i], b = bot[i], c = bot[i+1], d = top[i+1]; (a,b,d) when rt>0, (b,c,d) when rb>0
		if rt > 0.0:
			t.append([top[i], bot[i], top[i + 1]])
		if rb > 0.0:
			t.append([bot[i], bot[i + 1], top[i + 1]])
	if rt > 0.0:
		for i in radial:
			t.append([Vector3(0, h / 2.0, 0), top[i], top[i + 1]])
	if rb > 0.0:
		for i in radial:
			t.append([Vector3(0, -h / 2.0, 0), bot[i + 1], bot[i]])
	return t

static func _xf(tris: Array, f: Callable) -> Array:
	var out: Array = []
	for tr in tris:
		out.append([f.call(tr[0]), f.call(tr[1]), f.call(tr[2])])
	return out

## One silhouette's triangles in world space (three winding).
static func silhouette_tris(sil: Dictionary) -> Array:
	var all: Array = []
	for p in sil.prims:
		var tris: Array
		if p.t == "box":
			var a: Array = p.a
			var h := float(a[1])
			var rz := Basis(Vector3.BACK, float(p.rz))
			var off := Vector3(float(p.x), float(p.y), float(p.z))
			tris = _xf(_box(a[0], h, a[2]), func(v: Vector3) -> Vector3: return rz * (v + Vector3(0, h / 2.0, 0)) + off)
		elif p.t == "cyl":
			var a: Array = p.a
			var h := float(a[2])
			var rot := Basis(Vector3.BACK, float(p.rz)) * Basis(Vector3.RIGHT, float(p.rx))
			var off := Vector3(float(p.x), float(p.y), float(p.z))
			tris = _xf(_cyl(a[0], a[1], h, 5), func(v: Vector3) -> Vector3: return rot * (v + Vector3(0, h / 2.0, 0)) + off)
		else:
			var a: Array = p.a   # ConeGeometry(radius, height, 4): CylinderGeometry(0, radius, height, 4), rotateY(pi/4), translate(0, y, 0)
			var ry := Basis(Vector3.UP, PI / 4.0)
			var oy := float(p.y)
			tris = _xf(_cyl(0.0, a[0], a[1], 4), func(v: Vector3) -> Vector3: return ry * v + Vector3(0, oy, 0))
		all.append_array(tris)
	var s := float(sil.scale)
	var rot2 := Basis(Vector3.UP, float(sil.rot))
	var at := Vector3(float(sil.x), -0.1, float(sil.z))
	return _xf(all, func(v: Vector3) -> Vector3: return rot2 * (v * s) + at)

## All silhouettes merged into one ArrayMesh (flat normals). Returns {mesh, tris, aabb}.
static func build_mesh(list: Array) -> Dictionary:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var tri_n := 0
	for sil in list:
		for tr in silhouette_tris(sil):
			var a: Vector3 = tr[0]
			var b: Vector3 = tr[1]
			var c: Vector3 = tr[2]
			var n := (b - a).cross(c - a)
			n = n.normalized() if n.length_squared() > 1e-18 else Vector3.UP
			# Godot front faces are clockwise: emit (a, c, b)
			verts.append(a)
			verts.append(c)
			verts.append(b)
			norms.append(n)
			norms.append(n)
			norms.append(n)
			tri_n += 1
	var mesh := ArrayMesh.new()
	if tri_n == 0:
		return {"mesh": mesh, "tris": 0}
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return {"mesh": mesh, "tris": tri_n}

## Nearly the fog colour (MeshLambertMaterial 0x2a2436, emissive 0x0b0912).
static func material() -> Material:
	var m := StandardMaterial3D.new()
	m.albedo_color = DmWfxData.hex(0x2a2436)
	m.emission_enabled = true
	m.emission = DmWfxData.hex(0x0b0912)
	m.roughness = 1.0
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return m

static func attach(parent: Node3D, list: Array) -> MeshInstance3D:
	var r := build_mesh(list)
	if int(r.tris) == 0:
		return null
	var mi := MeshInstance3D.new()
	mi.name = "Silhouettes"
	mi.mesh = r.mesh
	mi.material_override = material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi
