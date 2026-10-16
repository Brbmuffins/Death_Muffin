class_name DmWfxQuads
extends RefCounted
## One ArrayMesh holding N camera-facing quads, one draw call. Per particle the shader gets everything through the vertex arrays
## (the web's Points attributes): CUSTOM0..3 = four vec4 of attributes. The corner offset (-0.5..0.5) rides in UV - 0.5.

static func build(n: int, custom0: PackedFloat32Array, custom1: PackedFloat32Array, custom2: PackedFloat32Array, custom3: PackedFloat32Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	var c3 := PackedFloat32Array()
	verts.resize(n * 4)
	uvs.resize(n * 4)
	idx.resize(n * 6)
	c0.resize(n * 16)
	c1.resize(n * 16)
	c2.resize(n * 16)
	c3.resize(n * 16)
	var corner := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for i in n:
		for k in 4:
			var v := i * 4 + k
			verts[v] = Vector3.ZERO
			uvs[v] = corner[k]
			for j in 4:
				c0[v * 4 + j] = custom0[i * 4 + j] if custom0.size() > i * 4 + j else 0.0
				c1[v * 4 + j] = custom1[i * 4 + j] if custom1.size() > i * 4 + j else 0.0
				c2[v * 4 + j] = custom2[i * 4 + j] if custom2.size() > i * 4 + j else 0.0
				c3[v * 4 + j] = custom3[i * 4 + j] if custom3.size() > i * 4 + j else 0.0
		var o := i * 6
		var b := i * 4
		idx[o] = b
		idx[o + 1] = b + 1
		idx[o + 2] = b + 2
		idx[o + 3] = b
		idx[o + 4] = b + 2
		idx[o + 5] = b + 3
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_CUSTOM0] = c0
	arr[Mesh.ARRAY_CUSTOM1] = c1
	arr[Mesh.ARRAY_CUSTOM2] = c2
	arr[Mesh.ARRAY_CUSTOM3] = c3
	arr[Mesh.ARRAY_INDEX] = idx
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, fmt)
	m.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	return m
