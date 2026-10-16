extends SceneTree
## The crowd baker and its shader (client/crowd/README.md), proven without a GPU: bakes the robber and the hound, then checks the textures against
## an independent skinning of the model, the metadata, the budgets, the mesh, the instance packing, and that the shader is Mobile-safe. The shader's
## vertex function is mirrored in shader_pose() below and held against true skeleton poses at random clip times, with blends.
## Run: godot --headless --path client --script res://tests/crowd_bake.gd   (the first rendered check is tests/crowd_smoke.gd)

const Baker := preload("res://crowd/crowd_baker.gd")
const OUT := "user://crowd_bake_test"
## Largest tolerated errors, creature space (metres) and degrees. The textures hold positions as half floats (1 mm at 1.7 m) and normals as 8-bit octahedral pairs.
const POS_TOLERANCE := 0.0025
const NORMAL_TOLERANCE_DEG := 2.0
## Linear interpolation between baked frames against the true pose in between: the baker's own target, with room for the one clip a model may
## have that reaches the frame cap, and for random times that fall near fast moments.
const INTERPOLATION_TOLERANCE := 0.06
const FORBIDDEN_IN_SHADER := ["hint_screen_texture", "hint_depth_texture", "hint_normal_roughness_texture", "SCREEN_TEXTURE", "DEPTH_TEXTURE",
	"SCREEN_UV", "SSS_", "BENT_NORMAL_MAP", "ANISOTROPY", "CLEARCOAT", "SDFGI", "textureLod(vat"]

var _failed := 0
var _assets := Baker.default_assets_dir()
var _rows := Baker.default_rows_path()


func check(ok: bool, msg: String) -> void:
	if not ok:
		printerr("FAIL crowd_bake: ", msg)
		_failed += 1


func _initialize() -> void:
	await process_frame   # the scene tree is live from the first frame; animation players need it
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in ["grave_robber", "bone_hound"]:
		_test_model(slug)
	for slug in ["shroud_moth", "tithe_bat"]:
		_test_unrigged(slug)
	_test_props("thrall_legionnaire+warrior")
	_test_decimation()
	_test_shader()
	_test_packing()
	_remove_dir(OUT)
	if _failed > 0:
		printerr("FAIL crowd_bake: %d check(s) failed" % _failed)
		quit(1)
		return
	print("PASS crowd_bake")
	quit(0)


func _test_model(slug: String) -> void:
	var dir := OUT.path_join(slug)
	var r: Dictionary = Baker.bake(root, slug, dir)
	check(r.ok, "%s: bake: %s" % [slug, r.get("error", "")])
	if not r.ok:
		return
	var data: CrowdVatData = ResourceLoader.load(dir.path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REPLACE)
	check(data != null and data.slug == slug, "%s: model.tres loads" % slug)
	if data == null:
		return
	print("INFO %s: %d triangles %s, %d vertices -> %d animation ids, %d frames, %d clips, textures %s %.1f MB, baked in %.1f s" % [
		slug, r.source_triangles, str(r.triangles), r.vertices, r.anim_vertices, r.frames, data.clip_names.size(), str(r.texture),
		float(r.pos_bytes + r.nrm_bytes) / 1048576.0, r.seconds])

	# Budgets (ROADMAP "Performance rules"): crowd models at most 5,000 triangles and 1024-pixel textures.
	check(data.lod_triangles.size() >= 1 and data.lod_triangles[0] <= Baker.MAX_TRIANGLES and not r.over_budget, "%s: level 0 within %d triangles" % [slug, Baker.MAX_TRIANGLES])
	for l in range(1, data.lod_triangles.size()):
		check(data.lod_triangles[l] < data.lod_triangles[l - 1], "%s: levels of detail shrink" % slug)
	check(data.meshes.size() == data.lod_triangles.size(), "%s: one mesh per level" % slug)
	var albedo := Image.load_from_file(_assets.path_join(data.albedo_path))
	check(albedo != null and maxi(albedo.get_width(), albedo.get_height()) <= 1024, "%s: albedo texture found and at most 1024 px" % slug)
	check(data.orm_path != "" and FileAccess.file_exists(_assets.path_join(data.orm_path)), "%s: ORM texture found" % slug)

	# Textures and the clip table.
	var pos_img := data.pos_tex.get_image()
	var nrm_img := data.nrm_tex.get_image()
	check(pos_img != null and nrm_img != null, "%s: texture images readable" % slug)
	if pos_img == null or nrm_img == null:
		return
	check(pos_img.get_format() == Image.FORMAT_RGBAH, "%s: positions are RGBAH" % slug)
	check(nrm_img.get_format() == Image.FORMAT_RG8, "%s: normals are RG8" % slug)
	check(pos_img.get_width() == data.tex_width and pos_img.get_height() == data.total_frames * data.tex_rows, "%s: position texture is %d x %d" % [slug, data.tex_width, data.total_frames * data.tex_rows])
	check(nrm_img.get_width() == pos_img.get_width() and nrm_img.get_height() == pos_img.get_height(), "%s: normal texture matches the position texture" % slug)
	check(data.tex_width <= Baker.MAX_WIDTH and pos_img.get_height() <= 4096, "%s: textures within the phone limits" % slug)
	check(data.tex_width * data.tex_rows >= data.anim_vertex_count, "%s: a frame holds every animation id" % slug)
	check(not pos_img.has_mipmaps() and not nrm_img.has_mipmaps(), "%s: no mipmaps on baked data" % slug)
	var next_frame := 0
	check(data.clip_table.size() == data.clip_names.size() and data.clip_seconds.size() == data.clip_names.size(), "%s: one table row per clip" % slug)
	for c in data.clip_names.size():
		var row := data.clip_table[c]
		check(int(row.x) == next_frame and row.y >= 2.0 and row.z > 0.0, "%s: clip %s rows are contiguous with frames and fps" % [slug, data.clip_names[c]])
		var covered := row.y / row.z if row.w > 0.5 else (row.y - 1.0) / row.z
		check(data.clip_seconds[c] > 0.0 and absf(covered - data.clip_seconds[c]) < 1e-3, "%s: clip %s frames and fps cover its seconds" % [slug, data.clip_names[c]])
		next_frame += int(row.y)
	check(next_frame == data.total_frames, "%s: frames add up" % slug)
	for plan in r.clips:
		check(plan.error <= Baker.ERROR_TARGET or int(plan.frames) == Baker.MAX_FRAMES, "%s: clip %s interpolates within %.0f mm (got %.0f mm at %d frames)" % [slug, plan.name, Baker.ERROR_TARGET * 1000.0, plan.error * 1000.0, plan.frames])
		check(plan.error <= INTERPOLATION_TOLERANCE, "%s: clip %s interpolation error %.0f mm" % [slug, plan.name, plan.error * 1000.0])
	check(data.clip_index("idle") >= 0 and data.clip_table[data.clip_index("idle")].w == 1.0 and data.clip_table[data.clip_index("walk")].w == 1.0, "%s: idle and walk loop" % slug)
	for role in ["idle", "walk", "run"] if slug == "bone_hound" else ["idle", "walk", "run", "attack", "hurt", "death"]:
		check(data.roles.has(role), "%s: role %s is played by a clip" % [slug, role])
	for role in data.roles:
		for nm in data.roles[role]:
			check(data.clip_index(nm) >= 0, "%s: role %s names baked clip %s" % [slug, role, nm])
	if slug == "grave_robber":
		check(data.roles.attack == ["attack", "attack2"] and data.roles.death == ["death", "death2"] and data.roles.hurt == ["hurt", "hurt2", "hurt3"], "%s: clip variants join their role" % slug)
	if slug == "bone_hound":
		check(not data.roles.has("hurt") and not data.roles.has("death"), "%s: no hurt or death clip to bake" % slug)

	# The mesh: one vertex array for every level, an animation id per vertex, bounds that hold every pose.
	var m: Dictionary = Baker.load_model(root, slug, _assets, _rows)
	check(m.ok, "%s: model loads again" % slug)
	if not m.ok:
		return
	var src := (m.mesh_instance as MeshInstance3D).mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = src[Mesh.ARRAY_NORMAL]
	var bones: PackedInt32Array = src[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = src[Mesh.ARRAY_WEIGHTS]
	var per := bones.size() / verts.size()
	var ids := PackedInt32Array()
	for l in data.meshes.size():
		var a := data.meshes[l].surface_get_arrays(0)
		var custom: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM0]
		check(a[Mesh.ARRAY_VERTEX].size() == verts.size() and custom.size() == verts.size() * 2, "%s: level %d keeps the vertex array (CUSTOM0: id, part)" % [slug, l])
		check((a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 == data.lod_triangles[l], "%s: level %d triangle count" % [slug, l])
		check(_extent(a[Mesh.ARRAY_INDEX]).y < verts.size(), "%s: level %d indexes the vertex array" % [slug, l])
		check(a[Mesh.ARRAY_TEX_UV] == src[Mesh.ARRAY_TEX_UV], "%s: level %d keeps the UVs" % [slug, l])
		check(data.meshes[l].custom_aabb == data.aabb, "%s: level %d bounds are the baked poses'" % [slug, l])
		if l == 0:
			var body := true
			for i in verts.size():
				ids.append(int(custom[i * 2]))
				body = body and custom[i * 2 + 1] == 0.0
			check(body, "%s: every vertex is the body's (part 0)" % slug)
	check(ids.size() == verts.size() and _extent(ids) == Vector2i(0, data.anim_vertex_count - 1), "%s: animation ids cover 0..%d" % [slug, data.anim_vertex_count - 1])

	# Rest pose: the glTF's inverse binds undo the rest skeleton up to one common transform (the dequantised GLBs carry a scale there), so the
	# rest skin of every bone is the same matrix, and skinning the rest skeleton gives that matrix applied to the modelled mesh.
	var rest_mats: Array[Transform3D] = Baker.rest_matrices(m)
	var common := rest_mats[0]
	var spread := 0.0
	for mat in rest_mats:
		spread = maxf(spread, (mat.origin - common.origin).length() + (mat.basis.x - common.basis.x).length() + (mat.basis.y - common.basis.y).length() + (mat.basis.z - common.basis.z).length())
	check(spread < 1e-3, "%s: every bind belongs to its bone (rest skin of all %d bones is one matrix, spread %.6f)" % [slug, rest_mats.size(), spread])
	var rest := _blend_skin(rest_mats, verts, normals, bones, weights, per)
	var rest_err := 0.0
	for i in verts.size():
		rest_err = maxf(rest_err, (rest[0][i] - common * verts[i]).length())
	var low := INF
	var high := -INF
	for p in rest[0]:
		low = minf(low, p.y)
		high = maxf(high, p.y)
	print("INFO %s: rest pose vs modelled mesh max error %.6f m, rest height %.3f (row %.3f), lowest point %.3f" % [slug, rest_err, high - low, m.height, low])
	check(rest_err < 1e-4, "%s: the rest pose skins back to the modelled mesh" % slug)
	check(absf((high - low) - float(m.height)) < 0.15 * float(m.height) and absf(low) < 0.1, "%s: standing on the origin at about the row's height" % slug)

	# Every clip, first / middle / last frame, every vertex: the texture against the skinned model.
	var max_pos := 0.0
	var max_nrm := 0.0
	var checked := 0
	var walk_motion := 0.0
	var first_pose: Array = []
	var inside := true
	for c in data.clip_names.size():
		var row := data.clip_table[c]
		var frames := [0, int(row.y) / 2, int(row.y) - 1]
		for f in frames:
			var t := float(f) / row.z
			var ref := _reference(m, data.clip_names[c], t, verts, normals, bones, weights, per)
			if data.clip_names[c] == "walk":
				if f == 0:
					first_pose = ref
				else:
					for i in verts.size():
						walk_motion = maxf(walk_motion, (ref[0][i] - first_pose[0][i]).length())
			for p in ref[0]:
				inside = inside and data.aabb.grow(0.003).has_point(p)
			var e := _compare(data, pos_img, nrm_img, ids, int(row.x) + f, ref)
			max_pos = maxf(max_pos, e.x)
			max_nrm = maxf(max_nrm, e.y)
			checked += 1
	print("INFO %s: %d baked frames checked, max position error %.5f m, max normal error %.3f deg" % [slug, checked, max_pos, max_nrm])
	check(inside and data.aabb.size.y > 0.5, "%s: bounds hold every checked pose" % slug)
	check(walk_motion > 0.1, "%s: the walk clip really moves the body (%.3f m), the animation player was live" % [slug, walk_motion])
	check(max_pos <= POS_TOLERANCE, "%s: baked positions within %.4f m (got %.5f)" % [slug, POS_TOLERANCE, max_pos])
	check(max_nrm <= NORMAL_TOLERANCE_DEG, "%s: baked normals within %.1f deg (got %.3f)" % [slug, NORMAL_TOLERANCE_DEG, max_nrm])

	# The shader's vertex function (shader_pose) at random clip times against the true pose: looping, holding, interpolating, blending.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261016
	var sample_ids: Array[int] = []
	for i in 300:
		sample_ids.append(rng.randi_range(0, verts.size() - 1))
	var worst := 0.0
	var worst_blend := 0.0
	for round_ in 24:
		var c := rng.randi_range(0, data.clip_names.size() - 1)
		var c2 := rng.randi_range(0, data.clip_names.size() - 1)
		var t := rng.randf_range(0.0, data.clip_seconds[c] * 1.4)
		var t2 := rng.randf_range(0.0, data.clip_seconds[c2] * 1.4)
		var w := rng.randf_range(0.0, 0.999)
		var truth1 := _reference(m, data.clip_names[c], _true_time(data, c, t), verts, normals, bones, weights, per)
		var truth2 := _reference(m, data.clip_names[c2], _true_time(data, c2, t2), verts, normals, bones, weights, per)
		var custom := CrowdVatData.pack_custom(c, t)
		var custom_blend := CrowdVatData.pack_custom(c, t, c2, t2, w)
		for i in sample_ids:
			var got := _shader_vertex(data, pos_img, nrm_img, ids[i], custom)
			worst = maxf(worst, (got[0] - truth1[0][i]).length())
			var got_b := _shader_vertex(data, pos_img, nrm_img, ids[i], custom_blend)
			worst_blend = maxf(worst_blend, (got_b[0] - (truth1[0][i] as Vector3).lerp(truth2[0][i], w)).length())
			check((got_b[1] as Vector3).is_normalized(), "%s: blended normal stays unit length" % slug)
	print("INFO %s: shader vertex function vs true pose at random times: max error %.4f m, with blends %.4f m" % [slug, worst, worst_blend])
	check(worst <= INTERPOLATION_TOLERANCE and worst_blend <= INTERPOLATION_TOLERANCE, "%s: playback within %.2f m of the true pose" % [slug, INTERPOLATION_TOLERANCE])

	# The material and a MultiMesh come out whole.
	var mat := data.make_material(ImageTexture.create_from_image(albedo))
	check(mat.shader != null and mat.get_shader_parameter("vat_width") == data.tex_width and (mat.get_shader_parameter("vat_clips") as PackedVector4Array).size() == CrowdVatData.MAX_CLIPS,
		"%s: material carries the textures and a 16-row clip table" % slug)
	var mm := data.make_multimesh(7, 0)
	check(mm.instance_count == 7 and mm.use_colors and mm.use_custom_data and mm.mesh == data.meshes[0], "%s: multimesh has instances, colours and custom data" % slug)
	(m.root as Node).free()


## The pose a clip holds at `t`, as the skeleton gives it: loops wrap, one-shots hold their last baked second.
func _true_time(data: CrowdVatData, c: int, t: float) -> float:
	var length := data.clip_seconds[c]
	return fposmod(t, length) if data.clip_table[c].w > 0.5 else minf(t, length)


## The skinned vertices of a clip at `t`: positions and normals in creature space. Blends the bone matrices itself, not through Baker.skin.
func _reference(m: Dictionary, clip: String, t: float, verts: PackedVector3Array, normals: PackedVector3Array, bones: PackedInt32Array,
		weights: PackedFloat32Array, per: int) -> Array:
	Baker.pose_at(m, clip, t)
	return _blend_skin(Baker.pose_matrices(m), verts, normals, bones, weights, per)


func _blend_skin(mats: Array[Transform3D], verts: PackedVector3Array, normals: PackedVector3Array, bones: PackedInt32Array, weights: PackedFloat32Array, per: int) -> Array:
	var ps := PackedVector3Array()
	var ns := PackedVector3Array()
	ps.resize(verts.size())
	ns.resize(verts.size())
	for i in verts.size():
		var x := Vector3.ZERO
		var y := Vector3.ZERO
		var z := Vector3.ZERO
		var o := Vector3.ZERO
		for k in per:
			var w := weights[i * per + k]
			if w > 0.0:
				var mat := mats[bones[i * per + k]]
				x += mat.basis.x * w
				y += mat.basis.y * w
				z += mat.basis.z * w
				o += mat.origin * w
		var blended := Basis(x, y, z)
		ps[i] = blended * verts[i] + o
		ns[i] = (blended * normals[i]).normalized()
	return [ps, ns]


## Largest position error (m) and normal error (deg) of one baked frame against a reference, over every mesh vertex.
func _compare(data: CrowdVatData, pos_img: Image, nrm_img: Image, ids: PackedInt32Array, frame: int, ref: Array) -> Vector2:
	var worst_p := 0.0
	var worst_n := 0.0
	for i in ids.size():
		var texel := _texel(data, frame, ids[i])
		var p := pos_img.get_pixel(texel.x, texel.y)
		var e := nrm_img.get_pixel(texel.x, texel.y)
		worst_p = maxf(worst_p, (Vector3(p.r, p.g, p.b) - ref[0][i]).length())
		worst_n = maxf(worst_n, rad_to_deg(Baker.oct_decode(e.r, e.g).angle_to(ref[1][i])))
	return Vector2(worst_p, worst_n)


func _texel(data: CrowdVatData, frame: int, id: int) -> Vector2i:
	var r := id / data.tex_width
	return Vector2i(id - r * data.tex_width, frame * data.tex_rows + r)


# ---- crowd_vat.gdshader's vertex(), line by line, reading the baked images ---------------------------------------------------------------

func _shader_pose(data: CrowdVatData, pos_img: Image, nrm_img: Image, clip: int, time: float, id: int) -> Array:
	var c := data.clip_table[clip]
	var count := int(c.y + 0.5)
	var f := maxf(time, 0.0) * c.z
	var i0: int
	var i1: int
	if c.w > 0.5:
		f = fposmod(f, float(count))
		i0 = mini(int(floorf(f)), count - 1)
		i1 = 0 if i0 + 1 >= count else i0 + 1
	else:
		f = clampf(f, 0.0, float(count - 1))
		i0 = int(floorf(f))
		i1 = mini(i0 + 1, count - 1)
	var k := f - float(i0)
	var base := int(c.x + 0.5)
	var a := _texel(data, base + i0, id)
	var b := _texel(data, base + i1, id)
	var pa := pos_img.get_pixel(a.x, a.y)
	var pb := pos_img.get_pixel(b.x, b.y)
	var na := nrm_img.get_pixel(a.x, a.y)
	var nb := nrm_img.get_pixel(b.x, b.y)
	var p := Vector3(pa.r, pa.g, pa.b).lerp(Vector3(pb.r, pb.g, pb.b), k)
	var n := Baker.oct_decode(na.r, na.g).lerp(Baker.oct_decode(nb.r, nb.g), k)
	return [p, n]


func _shader_vertex(data: CrowdVatData, pos_img: Image, nrm_img: Image, id: int, d: Color) -> Array:
	var pn := _shader_pose(data, pos_img, nrm_img, clampi(int(d.r + 0.5), 0, 15), d.g, id)
	var prev := floorf(d.b)
	var weight := d.b - prev
	if weight > 0.0:
		var pn2 := _shader_pose(data, pos_img, nrm_img, clampi(int(prev), 0, 15), d.a, id)
		pn = [(pn[0] as Vector3).lerp(pn2[0], weight), (pn[1] as Vector3).lerp(pn2[1], weight)]
	return [pn[0], (pn[1] as Vector3).normalized()]


# ---- the other checks ---------------------------------------------------------------------------------------------------------------------

## A model over the triangle budget falls back to Godot's own simplified level; with none small enough it is reported.
func _test_decimation() -> void:
	var dir := OUT.path_join("decimated")
	var r: Dictionary = Baker.bake(root, "grave_robber", dir, {"max_triangles": 3000, "clips": ["idle", "walk"]})
	check(r.ok and r.triangles.size() == 1 and r.triangles[0] <= 3000 and not r.over_budget, "over budget: level 0 is the simplified mesh (got %s)" % str(r.get("triangles")))
	var r2: Dictionary = Baker.bake(root, "grave_robber", dir, {"max_triangles": 100, "clips": ["idle"]})
	check(r2.ok and r2.over_budget, "over budget with no small enough level is reported")


func _test_shader() -> void:
	var sh := load(CrowdVatData.SHADER_PATH) as Shader
	check(sh != null and sh.get_mode() == Shader.MODE_SPATIAL and sh.code.length() > 500, "crowd_vat.gdshader loads as a spatial shader")
	if sh == null:
		return
	for token in FORBIDDEN_IN_SHADER:
		check(not sh.code.contains(token), "shader avoids %s (Forward+-only or screen-dependent)" % token)
	check(sh.code.contains("texelFetch") and sh.code.contains("INSTANCE_CUSTOM") and sh.code.contains("CUSTOM0"), "shader reads the baked textures and the instance and vertex data")
	check(sh.code.contains("vat_clips[%d]" % CrowdVatData.MAX_CLIPS), "shader clip table matches MAX_CLIPS")
	var uniforms := {}
	var re := RegEx.new()
	re.compile("(?m)^uniform\\s+\\w+\\s+(\\w+)")
	for mt in re.search_all(sh.code):
		uniforms[mt.get_string(1)] = true
	for u in ["albedo_tex", "orm_tex", "use_orm", "vat_pos", "vat_nrm", "vat_width", "vat_rows", "vat_clips"]:
		check(uniforms.has(u), "shader declares uniform %s that CrowdVatData sets" % u)


func _test_packing() -> void:
	var c := CrowdVatData.pack_custom(3, 1.25, 7, 0.5, 0.25)
	check(c.r == 3.0 and c.g == 1.25 and c.b == 7.25 and c.a == 0.5, "pack_custom puts clip, time, previous clip + blend, previous time in x y z w")
	check(CrowdVatData.pack_custom(3, 1.0).b == 0.0, "no blend packs a zero")
	check(CrowdVatData.pack_custom(0, 1.0, 5, 0.0, 5.0).b < 6.0, "a blend never reaches 1")
	var col := CrowdVatData.pack_color(Color(0.5, 0.25, 1.0), 0.75)
	check(col.r == 0.5 and col.g == 0.25 and col.b == 1.0 and col.a == 0.75, "pack_color puts tint in rgb and the flash in a")


## Smallest and largest value of an integer array.
func _extent(values: PackedInt32Array) -> Vector2i:
	var lo := 1 << 30
	var hi := -1
	for v in values:
		lo = mini(lo, v)
		hi = maxi(hi, v)
	return Vector2i(lo, hi)


func _remove_dir(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)


## An unrigged model (a prop today's shader flaps: DmCreatureMat, wingFlap.ts): one looping "fly" clip that every role plays, whose frames are
## the shader's wing formula, mirrored here line by line from DmCreatureMat (not the baker's own function), on the placed mesh.
func _test_unrigged(slug: String) -> void:
	var dir := OUT.path_join(slug)
	var r: Dictionary = Baker.bake(root, slug, dir)
	check(r.ok, "%s: bake: %s" % [slug, r.get("error", "")])
	if not r.ok:
		return
	var data: CrowdVatData = ResourceLoader.load(dir.path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REPLACE)
	check(data != null and data.clip_names == PackedStringArray(["fly"]), "%s: one baked clip, fly" % slug)
	if data == null:
		return
	var roles_ok := true
	for role in Baker.FALLBACK:
		roles_ok = roles_ok and data.roles.get(role, []) == ["fly"]
	check(roles_ok, "%s: every role plays the fly loop" % slug)
	var w := Baker.wings_for(slug)
	var period := TAU / float(w.speed)
	check(data.clip_table[0].y == float(Baker.FLAP_FRAMES) and data.clip_table[0].w == 1.0 and absf(data.clip_seconds[0] - period) < 1e-5,
		"%s: %d frames over one beat (%.3f s), looping" % [slug, Baker.FLAP_FRAMES, period])
	check(data.lod_triangles[0] <= Baker.MAX_TRIANGLES and not r.over_budget, "%s: level 0 within %d triangles" % [slug, Baker.MAX_TRIANGLES])
	var albedo := Image.load_from_file(_assets.path_join(data.albedo_path))
	check(albedo != null and maxi(albedo.get_width(), albedo.get_height()) <= 1024, "%s: albedo found and at most 1024 px" % slug)
	var m: Dictionary = Baker.load_model(root, slug, _assets, _rows)
	check(m.ok and m.get("static", false), "%s: loads as an unrigged model" % slug)
	if not m.ok:
		return
	var mesh: Mesh = (m.mesh_instance as MeshInstance3D).mesh
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var place: Transform3D = m.place
	var baked: Array = data.meshes[0].surface_get_arrays(0)
	var custom: PackedFloat32Array = baked[Mesh.ARRAY_CUSTOM0]
	var ids := PackedInt32Array()
	for i in verts.size():
		ids.append(int(custom[i * 2]))
	var pos_img := data.pos_tex.get_image()
	var nrm_img := data.nrm_tex.get_image()
	# The shader's frame (DmCreature: wing_vec, wing_root, wing_axis from the mesh's own box).
	var bb := mesh.get_aabb()
	var axis_z := bb.size.z > bb.size.x
	var half := (bb.size.z if axis_z else bb.size.x) / 2.0
	var centre := (bb.position.z + bb.size.z / 2.0) if axis_z else (bb.position.x + bb.size.x / 2.0)
	var wing := Vector4(float(w.speed), float(w.amp), half * float(w.get("body", 0.3)), half)
	var worst := 0.0
	for f in [0, 3, 6, 12, 18]:
		var t := float(f) * period / float(Baker.FLAP_FRAMES)
		var ref := PackedVector3Array()
		for i in verts.size():
			var v := verts[i]
			var ws := (v.z if axis_z else v.x) - centre                       # float ws = (wing_z > 0.5 ? VERTEX.z : VERTEX.x) - wing_root.x;
			var wd := absf(ws) - wing.z                                         # float wd = abs(ws) - wing.z;
			if wd > 0.0:
				var wf := smoothstep(0.0, maxf(0.001, wing.w - wing.z), wd)     # float wf = smoothstep(0.0, max(0.001, wing.w - wing.z), wd);
				var wa := wing.y * sin(t * wing.x) * (0.35 + 0.65 * wf)         # float wa = wing.y * sin(TIME * wing.x + wing_root.y) * (...);  phase 0
				var nv := centre + signf(ws) * (wing.z + wd * cos(wa))          # float nv = wing_root.x + sign(ws) * (wing.z + wd * cos(wa));
				if axis_z:
					v.z = nv
				else:
					v.x = nv
				v.y += wd * sin(wa)                                             # VERTEX.y += wd * sin(wa);
			ref.append(place * v)
		var nr := PackedVector3Array()
		for i in normals.size():
			nr.append((place.basis.inverse().transposed() * normals[i]).normalized())
		var got := _compare(data, pos_img, nrm_img, ids, f, [ref, nr])
		worst = maxf(worst, got.x)
		if f == 0:
			check(got.x <= POS_TOLERANCE and got.y <= NORMAL_TOLERANCE_DEG, "%s: frame 0 is the rest pose (%.1f mm, %.1f deg)" % [slug, got.x * 1000.0, got.y])
	print("INFO %s: unrigged, %d frames of one %.3f s wing beat, worst %.2f mm off today's shader formula" % [slug, Baker.FLAP_FRAMES, period, worst * 1000.0])
	check(worst <= POS_TOLERANCE, "%s: every frame is today's wing beat (worst %.1f mm)" % [slug, worst * 1000.0])
	(m.root as Node).free()



## A thrall variant: the warrior's sword and shield baked onto its hands (DmEntityViews._make_thrall, DmCreature.attach / _calibrate / _tick_props).
## The body is the plain model's, the props are extra vertices with their own animation ids and material parts; at the calibration pose (PROP_CALIBRATE_S
## into the idle loop) each prop's up is exactly its `dir` in creature space and its origin is the hand's, and every baked frame holds the props where
## today's formula puts them for that frame's pose.
func _test_props(variant: String) -> void:
	var r: Dictionary = Baker.bake(root, variant, OUT.path_join(variant))
	check(r.ok, "%s: bakes (%s)" % [variant, r.get("error", "")])
	if not r.ok:
		return
	var data: CrowdVatData = ResourceLoader.load(OUT.path_join(variant).path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REPLACE)
	var plain: Dictionary = Baker.load_model(root, "thrall_legionnaire", Baker.default_assets_dir(), Baker.default_rows_path())
	var src_vc: int = ((plain.mesh_instance as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var specs := Baker.props_for("warrior")
	var g := Baker._prop_geometry(specs)
	var up: int = (g.verts as PackedVector3Array).size()
	check(data.slug == variant and data.part_albedo.size() == 3 and data.part_pbr.size() == 3 and data.part_emission.size() == 3,
		"%s: the sword's metal, the shield's wood and its glowing boss are its prop parts (%d)" % [variant, data.part_albedo.size()])
	check(data.part_emission[2].v > 0.1 and data.part_emission[0].v == 0.0, "%s: only the shield boss glows, as today's" % variant)
	var a := data.meshes[0].surface_get_arrays(0)
	var custom: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM0]
	var vc: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var parts_ok := vc == src_vc + up
	for i in vc:
		parts_ok = parts_ok and ((custom[i * 2 + 1] == 0.0) if i < src_vc else (custom[i * 2 + 1] >= 1.0 and custom[i * 2 + 1] <= 3.0))
	check(parts_ok, "%s: the body's %d vertices are part 0, the props' %d follow with parts 1..3" % [variant, src_vc, up])
	# the calibration pose: each prop's up is its dir, its origin the hand bone's
	var rig := Baker._prop_rig(plain, specs, "idle")
	var at := PackedVector3Array()
	var an := PackedVector3Array()
	at.resize(up)
	an.resize(up)
	Baker.pose_at(plain, "idle", Baker.PROP_CALIBRATE_S)
	Baker._place_props(plain, {"g": g, "rig": rig}, at, an, 0)
	var sk: Skeleton3D = plain.skeleton
	for s in specs.size():
		var spec: Dictionary = specs[s]
		var hand := ((plain.place as Transform3D) * sk.get_bone_global_pose(int(rig[s].bone))).origin
		var d: Array = spec.dir
		var dir := Vector3(float(d[0]), float(d[1]), float(d[2])).normalized()
		# the prop's own up: a vertex at prop-space (0, y, 0) lands at hand + y * up
		var lo := INF
		var hi := -INF
		var v_lo := Vector3.ZERO
		var v_hi := Vector3.ZERO
		for j in up:
			if (g.owner as PackedInt32Array)[j] != s:
				continue
			var y := ((g.verts as PackedVector3Array)[j]).y
			if y < lo:
				lo = y
				v_lo = at[j]
			if y > hi:
				hi = y
				v_hi = at[j]
		var axis := (v_hi - v_lo).normalized()
		check(rad_to_deg(axis.angle_to(dir)) < 25.0, "%s: %s stands along its dir at calibration (%.1f deg; the prop is not a stick, so its extremes only sketch the up)" % [variant, spec.build, rad_to_deg(axis.angle_to(dir))])
		var near_hand := INF
		for j in up:
			if (g.owner as PackedInt32Array)[j] == s:
				near_hand = minf(near_hand, at[j].distance_to(hand))
		check(near_hand < 0.6, "%s: %s is held at the hand (nearest vertex %.2f m)" % [variant, spec.build, near_hand])
	# every frame of the texture holds the props where the formula puts them for that frame's pose
	var pos_img := data.pos_tex.get_image()
	var worst := 0.0
	for c in data.clip_names.size():
		var tb: Vector4 = data.clip_table[c]
		for f in [0, int(tb.y) - 1]:
			Baker.pose_at(plain, data.clip_names[c], minf(float(f) / maxf(tb.z, 0.001), data.clip_seconds[c]))
			Baker._place_props(plain, {"g": g, "rig": rig}, at, an, 0)
			for j in range(0, up, 7):
				var t := _texel(data, int(tb.x) + f, data.anim_vertex_count - up + j)
				var p := pos_img.get_pixel(t.x, t.y)
				worst = maxf(worst, (Vector3(p.r, p.g, p.b) - at[j]).length())
	check(worst < POS_TOLERANCE * 2.0, "%s: the baked frames hold the props where the formula puts them (worst %.1f mm)" % [variant, worst * 1000.0])
	print("INFO %s: %d body + %d prop vertices, %d animation ids, worst prop texel %.1f mm" % [variant, src_vc, up, data.anim_vertex_count, worst * 1000.0])
	(plain.root as Node).free()
