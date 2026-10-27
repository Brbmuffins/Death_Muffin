extends SceneTree
## The crowd baker and its shader (client/crowd/README.md), proven without a GPU: bakes the robber and the hound, then checks the textures against
## an independent skinning of the model, the metadata, the budgets, the mesh, the instance packing, and that the shader is Mobile-safe. The shader's
## vertex function is mirrored in shader_pose() below and held against true skeleton poses at random clip times, with blends.
## Run: godot --headless --path client --script res://tests/crowd_bake.gd   (the first rendered check is tests/crowd_smoke.gd)

const Baker := preload("res://crowd/crowd_baker.gd")
const OUT := "user://crowd_bake_test"
## Largest tolerated errors, creature space (metres) and degrees. The textures hold positions as three integer codes over the model's bounds (half a step per axis:
## 0.5 to 1.5 mm for these models, `step` below) and normals as 8-bit octahedral pairs; the hand props' track holds full floats.
const POS_TOLERANCE := 0.002
const PROP_TOLERANCE := 0.0002
const NORMAL_TOLERANCE_DEG := 2.0
## Linear interpolation between baked frames against the true pose in between: the baker's own target, with room for the one clip a model may
## have that reaches the frame cap, and for random times that fall near fast moments.
const INTERPOLATION_TOLERANCE := 0.06
const FORBIDDEN_IN_SHADER := ["hint_screen_texture", "hint_depth_texture", "hint_normal_roughness_texture", "SCREEN_TEXTURE", "DEPTH_TEXTURE",
	"SCREEN_UV", "SSS_", "BENT_NORMAL_MAP", "ANISOTROPY", "CLEARCOAT", "SDFGI", "textureLod(vat"]

var _failed := 0
var _assets := ProjectSettings.globalize_path("res://assets")                    ## this project's models
var _rows := ProjectSettings.globalize_path("res://game/view_models.json")      ## this project's model rows


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
	_test_codes()
	_test_decimation()
	_test_shader()
	_test_look()
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
	var r: Dictionary = Baker.bake(root, slug, dir, {"assets_dir": _assets, "rows_path": _rows})
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

	# Budgets (DECISIONS B71, B39): crowd models at most 5,000 triangles (Baker.MAX_TRIANGLES_OF: the Bone Colossus 6,000) and 1024-pixel textures.
	check(data.lod_triangles.size() >= 1 and data.lod_triangles[0] <= Baker.max_triangles_of(slug) and not r.over_budget, "%s: level 0 within %d triangles" % [slug, Baker.max_triangles_of(slug)])
	for l in range(1, data.lod_triangles.size()):
		check(data.lod_triangles[l] < data.lod_triangles[l - 1], "%s: levels of detail shrink" % slug)
	check(data.meshes.size() == data.lod_triangles.size(), "%s: one mesh per level" % slug)
	var albedo := Image.load_from_file(_assets.path_join(data.albedo_path))
	check(albedo != null and maxi(albedo.get_width(), albedo.get_height()) <= 1024, "%s: albedo texture found and at most 1024 px" % slug)
	check(data.orm_path != "" and FileAccess.file_exists(_assets.path_join(data.orm_path)), "%s: ORM texture found" % slug)
	check(data.normal_path != "" and FileAccess.file_exists(_assets.path_join(data.normal_path)), "%s: normal texture found" % slug)

	# Textures and the clip table.
	var pos_img := data.pos_tex.get_image()
	var nrm_img := data.nrm_tex.get_image()
	check(pos_img != null and nrm_img != null, "%s: texture images readable" % slug)
	if pos_img == null or nrm_img == null:
		return
	check(pos_img.get_format() == Image.FORMAT_RGBA8, "%s: positions are RGBA8 (three codes in 32 bits)" % slug)
	check(data.format == CrowdVatData.FORMAT, "%s: baked in the current format" % slug)
	_check_codes(data, slug, data.aabb)
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
	# a role is baked exactly when the model row lists a clip that can play it; the others are left to the body (lunge, recoil, tip-over)
	var have: Array = (JSON.parse_string(FileAccess.get_file_as_string(_rows)) as Dictionary)[slug].clips
	for role in Baker.FALLBACK:
		var plays: bool = (Baker.FALLBACK[role] as Array).any(func(nm: String) -> bool: return have.has(nm))
		check(data.roles.has(role) == plays, "%s: role %s is %s" % [slug, role, "played by a clip" if plays else "left to the body"])
	for role in data.roles:
		for nm in data.roles[role]:
			check(data.clip_index(nm) >= 0, "%s: role %s names baked clip %s" % [slug, role, nm])
	if slug == "grave_robber":
		check(data.roles.attack == ["attack", "attack2"] and data.roles.death == ["death", "death2"] and data.roles.hurt == ["hurt", "hurt2", "hurt3"], "%s: clip variants join their role" % slug)

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
		check(a[Mesh.ARRAY_VERTEX].size() == verts.size() and custom.size() == verts.size() * Baker.CUSTOM_STRIDE, "%s: level %d keeps the vertex array (CUSTOM0: id, part, chest and hands weights)" % [slug, l])
		check((a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 == data.lod_triangles[l], "%s: level %d triangle count" % [slug, l])
		check(_extent(a[Mesh.ARRAY_INDEX]).y < verts.size(), "%s: level %d indexes the vertex array" % [slug, l])
		check(a[Mesh.ARRAY_TEX_UV] == src[Mesh.ARRAY_TEX_UV], "%s: level %d keeps the UVs" % [slug, l])
		check(data.meshes[l].custom_aabb == data.aabb, "%s: level %d bounds are the baked poses'" % [slug, l])
		if l == 0:
			var body := true
			for i in verts.size():
				ids.append(int(custom[i * Baker.CUSTOM_STRIDE]))
				body = body and custom[i * Baker.CUSTOM_STRIDE + 1] == 0.0
			check(body, "%s: every vertex is the body's (part 0)" % slug)
			# the Legion kit's regions: the chest and hands weights are the creature's own gear masks (DmCreatureMat.baked_mesh: COLOR r = chest, b = hands)
			var masks: PackedColorArray = DmCreatureMat.baked_mesh(m.mesh_instance as MeshInstance3D).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
			var same := masks.size() == verts.size()
			var chest := 0
			var hands := 0
			for i in mini(masks.size(), verts.size()):
				var cw := custom[i * Baker.CUSTOM_STRIDE + 2]
				var hw := custom[i * Baker.CUSTOM_STRIDE + 3]
				same = same and absf(cw - masks[i].r) < 1e-5 and absf(hw - masks[i].b) < 1e-5
				chest += 1 if cw > 0.5 else 0
				hands += 1 if hw > 0.5 else 0
			check(same, "%s: the chest and hands weights of every vertex are the creature's gear masks" % slug)
			if slug == "skeleton_thrall":
				check(chest > 0 and hands > 0, "%s: a humanoid has a chest (%d vertices) and hands (%d) for the kit to paint" % [slug, chest, hands])
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
	check(max_pos <= 0.5 * data.pos_step.length() + 2e-4, "%s: baked positions within half a code step (%.5f of %.5f m)" % [slug, max_pos, 0.5 * data.pos_step.length()])
	check(r.pos_error <= 0.5 * data.pos_step.length() + 1e-6, "%s: the baker's own measure of the quantisation error holds (%.5f m)" % [slug, r.pos_error])
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
	check(mat.get_shader_parameter("vat_rx") == data.pos_radix.x and mat.get_shader_parameter("vat_ry") == data.pos_radix.y and mat.get_shader_parameter("vat_hi") == 65536 / data.pos_radix.x
		and mat.get_shader_parameter("vat_lo") == data.pos_lo and mat.get_shader_parameter("vat_step") == data.pos_step, "%s: material carries the position codes' bounds and radices" % slug)
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
		var e := nrm_img.get_pixel(texel.x, texel.y)
		worst_p = maxf(worst_p, (_decode_pos(data, pos_img.get_pixel(texel.x, texel.y)) - ref[0][i]).length())
		worst_n = maxf(worst_n, rad_to_deg(Baker.oct_decode(e.r, e.g).angle_to(ref[1][i])))
	return Vector2(worst_p, worst_n)


func _texel(data: CrowdVatData, frame: int, id: int) -> Vector2i:
	var r := id / data.tex_width
	return Vector2i(id - r * data.tex_width, frame * data.tex_rows + r)


# ---- crowd_vat.gdshader's vertex(), line by line, reading the baked images ---------------------------------------------------------------

## vat_frames(): the two frames of a clip row around `time` and how far toward the second.
func _frames(c: Vector4, time: float) -> Array:
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
	return [i0, i1, f - float(i0)]


## vat_decode_pos(): the four bytes of a texel (RGBA8 reads back as byte / 255) -> two halves -> the three codes -> a position.
func _decode_pos(data: CrowdVatData, t: Color) -> Vector3:
	var lo := int(t.r * 255.0 + 0.5) + int(t.g * 255.0 + 0.5) * 256
	var hi := int(t.b * 255.0 + 0.5) + int(t.a * 255.0 + 0.5) * 256
	var rx := data.pos_radix.x
	var w := lo / rx + hi * (65536 / rx)
	return data.pos_lo + Vector3(float(lo % rx), float(w % data.pos_radix.y), float(w / data.pos_radix.y)) * data.pos_step


func _shader_pose(data: CrowdVatData, pos_img: Image, nrm_img: Image, clip: int, time: float, id: int) -> Array:
	var c := data.clip_table[clip]
	var fr := _frames(c, time)
	var base := int(c.x + 0.5)
	var a := _texel(data, base + int(fr[0]), id)
	var b := _texel(data, base + int(fr[1]), id)
	var pa := _decode_pos(data, pos_img.get_pixel(a.x, a.y))
	var pb := _decode_pos(data, pos_img.get_pixel(b.x, b.y))
	var na := nrm_img.get_pixel(a.x, a.y)
	var nb := nrm_img.get_pixel(b.x, b.y)
	var p := pa.lerp(pb, float(fr[2]))
	var n := Baker.oct_decode(na.r, na.g).lerp(Baker.oct_decode(nb.r, nb.g), float(fr[2]))
	return [p, n]


func _shader_vertex(data: CrowdVatData, pos_img: Image, nrm_img: Image, id: int, d: Color) -> Array:
	var pn := _shader_pose(data, pos_img, nrm_img, clampi(int(d.r + 0.5), 0, 15), d.g, id)
	var prev := floorf(d.b)
	var weight := d.b - prev
	if weight > 0.0:
		var pn2 := _shader_pose(data, pos_img, nrm_img, clampi(int(prev), 0, 15), d.a, id)
		pn = [(pn[0] as Vector3).lerp(pn2[0], weight), (pn[1] as Vector3).lerp(pn2[1], weight)]
	return [pn[0], (pn[1] as Vector3).normalized()]


## trk_pose(): the three rows of hand prop `slot` at `time` of a clip, blended between the frames.
func _shader_track(data: CrowdVatData, trk_img: Image, clip: int, time: float, slot: int) -> Array:
	var c := data.track_table[clip]
	var fr := _frames(c, time)
	var base := int(c.x + 0.5)
	var rows := []
	for i in 3:
		var ra := trk_img.get_pixel(slot * 3 + i, base + int(fr[0]))
		var rb := trk_img.get_pixel(slot * 3 + i, base + int(fr[1]))
		rows.append(Vector4(ra.r, ra.g, ra.b, ra.a).lerp(Vector4(rb.r, rb.g, rb.b, rb.a), float(fr[2])))
	return rows


## The hand-prop branch of vertex(): a prop vertex (`v`, `nrm` in the prop's space, of hand prop `slot`) through the blended rows of the clip and of the previous clip.
func _shader_prop_vertex(data: CrowdVatData, trk_img: Image, v: Vector3, nrm: Vector3, slot: int, d: Color) -> Array:
	var rows := _shader_track(data, trk_img, clampi(int(d.r + 0.5), 0, 15), d.g, slot)
	var prev := floorf(d.b)
	var weight := d.b - prev
	if weight > 0.0:
		var other := _shader_track(data, trk_img, clampi(int(prev), 0, 15), d.a, slot)
		for i in 3:
			rows[i] = (rows[i] as Vector4).lerp(other[i], weight)
	var r0: Vector4 = rows[0]
	var r1: Vector4 = rows[1]
	var r2: Vector4 = rows[2]
	var p := Vector3(Vector3(r0.x, r0.y, r0.z).dot(v) + r0.w, Vector3(r1.x, r1.y, r1.z).dot(v) + r1.w, Vector3(r2.x, r2.y, r2.z).dot(v) + r2.w)
	var n := Vector3(Vector3(r0.x, r0.y, r0.z).dot(nrm), Vector3(r1.x, r1.y, r1.z).dot(nrm), Vector3(r2.x, r2.y, r2.z).dot(nrm))
	return [p, n.normalized()]


## The position codes of a baked model: radices that pack in 32 bits with a power-of-two x, and the first and last code are `bounds`' corners (the baked poses' box).
func _check_codes(data: CrowdVatData, label: String, bounds: AABB) -> void:
	var r := data.pos_radix
	check(r.x >= 16 and r.x <= 65536 and (r.x & (r.x - 1)) == 0 and r.y >= 2 and r.z >= 2, "%s: position radices %s: x a power of two, y and z at least 2" % [label, str(r)])
	check(r.x * r.y * r.z <= (1 << 32) and r.y * r.z < (1 << 30), "%s: the three codes fit 32 bits (%d levels) and the shader's signed ints (%d)" % [label, r.x * r.y * r.z, r.y * r.z])
	var top := data.pos_lo + Vector3(r.x - 1, r.y - 1, r.z - 1) * data.pos_step
	var corners := true
	for i in 3:
		corners = corners and absf(data.pos_lo[i] - bounds.position[i]) < 1e-6 and (bounds.size[i] <= 0.0 or absf(top[i] - (bounds.position[i] + bounds.size[i])) < 1e-4)
	check(corners, "%s: the first and last code are the bounds' corners (%s .. %s vs %s)" % [label, str(data.pos_lo), str(top), str(bounds)])


# ---- the other checks ---------------------------------------------------------------------------------------------------------------------

## A model over the triangle budget falls back to Godot's own simplified level; with none small enough it is reported.
func _test_decimation() -> void:
	var dir := OUT.path_join("decimated")
	var r: Dictionary = Baker.bake(root, "grave_robber", dir, {"max_triangles": 3000, "clips": ["idle", "walk"], "assets_dir": _assets, "rows_path": _rows})
	check(r.ok and r.triangles.size() == 1 and r.triangles[0] <= 3000 and not r.over_budget, "over budget: level 0 is the simplified mesh (got %s)" % str(r.get("triangles")))
	var r2: Dictionary = Baker.bake(root, "grave_robber", dir, {"max_triangles": 100, "clips": ["idle"], "assets_dir": _assets, "rows_path": _rows})
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
	for u in ["albedo_tex", "orm_tex", "normal_tex", "use_orm", "use_normal", "rough_f", "metal_f", "glow_palette", "rim_palette", "vat_pos", "vat_nrm", "vat_width", "vat_rows", "vat_clips",
			"vat_lo", "vat_step", "vat_rx", "vat_ry", "vat_hi", "vat_track", "trk_clips", "kit_slot", "kit_pal", "part_kit"]:
		check(uniforms.has(u), "shader declares uniform %s that CrowdVatData sets" % u)
	check(sh.code.contains("trk_clips[%d]" % CrowdVatData.MAX_CLIPS), "shader track clip table matches MAX_CLIPS")
	# the integer maths of the position codes stays in signed 32 bits and needs no shifts or unsigned types (Godot's shader language, Compatibility, Mobile)
	check(not sh.code.contains("uint") and not sh.code.contains("<<") and not sh.code.contains(">>"), "shader decodes the position codes with plain ints")
	_test_fade(sh)


## The alpha path (client/crowd/README.md "The alpha path"): the solid shader is untouched, the fade shader is DmCreatureMat's fade variant (blend_mix, no depth write) and reads an
## instance's opacity from the fraction over the clip index in INSTANCE_CUSTOM.x, the spectral one multiplies its own 0.55 by it; and the packing survives a half float (what a
## MultiMesh may keep an instance's custom data in): every clip index with every opacity step reads back as itself.
func _test_fade(sh: Shader) -> void:
	var solid := sh.code
	check(not solid.contains("blend_mix") or solid.contains("#ifdef FADE"), "the solid shader draws opaque: its blend_mix sits behind FADE")
	var fade := CrowdVatData.fade_shader()
	check(fade.code.begins_with("shader_type spatial;\n#define FADE") and fade.code.length() > solid.length(), "fade_shader is the same code with FADE defined")
	check(CrowdVatData.fade_shader() == fade and CrowdVatData.spectral_shader() != fade, "made once, and not the spectral one")
	check(CrowdVatData.spectral_shader().code.contains("#define SPECTRAL") and solid.contains("#ifdef SPECTRAL\n#define FADE\n#endif"), "a ghost's shader is the fade shader with its own 0.55")
	check(solid.contains("render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, blend_mix, depth_draw_never;") and solid.contains("ALPHA = v_alpha;") and solid.contains("ALPHA = SPECTRAL_OPACITY * v_alpha;"),
		"the fade variant is DmCreatureMat's: blend_mix, depth_draw_never, ALPHA from the instance (a ghost's times 0.55)")
	var back := CrowdVatData.fade_shader(true)
	check(back != fade and back.code.contains("#define FADE\n#define CULL_BACK") and solid.contains("render_mode cull_back, diffuse_burley, specular_schlick_ggx, blend_mix, depth_draw_never;") and CrowdVatData.fade_shader(true) == back,
		"a closed body's fade shader culls back faces, as DmCreatureMat's fade variant does for CULL_BACK_SLUGS (made once)")
	check(CrowdView.fade_cull_back("thrall_sentinel") and CrowdView.fade_cull_back("thrall_sentinel+warrior") and CrowdView.fade_cull_back("bone_colossus") and not CrowdView.fade_cull_back("grave_robber") and not CrowdView.fade_cull_back("skeleton_thrall+archer"),
		"the cull-back bodies are DmCreatureMat's, a thrall's hand-prop variant its body's")
	check(solid.contains("float clip_f = floor(d.x + 0.001);") and solid.contains("v_alpha = clamp(1.0 - (d.x - clip_f) * (64.0 / 63.0), 0.0, 1.0);"), "and reads the opacity back from the fraction over the clip index")
	var img := Image.create(1, 1, false, Image.FORMAT_RH)   # a half float, as a MultiMesh may keep custom data
	var wrong := 0
	var worst := 0.0
	for clip in CrowdVatData.MAX_CLIPS:
		for q in 64:
			var x := CrowdVatData.pack_clip(clip, 1.0 - float(q) / 63.0)
			img.set_pixel(0, 0, Color(x, 0, 0))
			var h := img.get_pixel(0, 0).r   # the shader's decode, line by line (clip_f, v_alpha), on what the half float kept
			var clip_f := floorf(h + 0.001)
			var alpha := clampf(1.0 - (h - clip_f) * (64.0 / 63.0), 0.0, 1.0)
			wrong += 0 if int(clip_f) == clip and absf(alpha - (1.0 - float(q) / 63.0)) < 1e-6 else 1
			worst = maxf(worst, absf(alpha - (1.0 - float(q) / 63.0)))
	check(wrong == 0, "every clip index with every opacity step survives a half float (%d of %d wrong, worst %s)" % [wrong, CrowdVatData.MAX_CLIPS * 64, str(worst)])
	check(CrowdVatData.pack_clip(5, 1.0) == 5.0 and CrowdVatData.pack_clip(5, 0.0) == 5.0 + 63.0 / 64.0 and CrowdVatData.pack_clip(5, 1.4) == 5.0, "a solid body's x is the clip index alone, none is brighter than solid, see-through is 63/64 over it")
	check(CrowdVatData.pack_clip(5, 0.5) == 5.0 + 32.0 / 64.0 and CrowdVatData.pack_clip(5, 0.38) == 5.0 + 39.0 / 64.0, "opacity 0.5 is step 32 (31.5 rounds up) and the ward's 0.38 is step 39 of 63")


## What the crowd material takes from the glTF material and what it makes of the thrall's look, as DmCreatureMat does (client/crowd/README.md "Differences from the creature material").
func _test_look() -> void:
	var sh := load(CrowdVatData.SHADER_PATH) as Shader
	var today := DmCreatureMat.shader(false, false, false).code
	# the factors: every model's glTF material leaves metallic and roughness at the glTF default 1 (the ORM texture scales them) and has no base colour factor, as the shader's defaults say
	check(sh.code.contains("uniform float metal_f = 1.0;") and sh.code.contains("uniform float rough_f = 1.0;") and today.contains("uniform float metal_f = 1.0;"),
		"the crowd's metallic and roughness factors default to 1, as DmCreatureMat's (and the glTF's)")
	var looks: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://crowd/crowd_looks.json"))
	var slugs := {}
	for d in looks.enemy_model:
		slugs[looks.enemy_model[d]] = true
	for k in looks.thrall_model:
		slugs[looks.thrall_model[k]] = true
	for l in looks.legion:
		slugs[looks.legion[l].slug] = true
	var checked := 0
	var read := 0
	for slug: String in slugs:
		var base := _assets.path_join("slice/models")
		var path := base.path_join(slug).path_join("character.glb")
		if not FileAccess.file_exists(path):
			path = base.path_join("props").path_join(slug + ".glb")
		if not FileAccess.file_exists(path):
			print("INFO no model file for %s" % slug)
			continue
		read += 1
		var gltf := Baker.glb_json(path)
		for mat: Dictionary in gltf.get("materials", []):
			var pbr: Dictionary = mat.get("pbrMetallicRoughness", {})
			check(not pbr.has("metallicFactor") and not pbr.has("roughnessFactor") and not pbr.has("baseColorFactor") and not mat.has("emissiveFactor"),
				"%s: the glTF material has the default factors (metallic and roughness 1, white, no emissive): %s" % [slug, str(mat.keys())])
			checked += 1
	check(checked >= read and read > 0, "the factors of %d materials of %d crowd models (of the %d the looks name) were read" % [checked, read, slugs.size()])
	# the friend rim: DmCreatureMat's `rim.rgb * rim.a * smoothstep(.35, .95, fres) * .9`, the crowd's `v_rim * smoothstep(.35, .95, fres)` with v_rim = rgb * (a * .9) from the palette
	check(today.contains("rim.rgb * rim.a * smoothstep(0.35, 0.95, fres) * 0.9") and sh.code.contains("rim_palette[slot].a * 0.9") and sh.code.contains("v_rim * smoothstep(0.35, 0.95, fres)"),
		"both shaders have the rim's formula (smoothstep(.35, .95, fres) at .9 of the strength)")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst := 0.0
	for i in 200:
		var rgb := Vector3(rng.randf(), rng.randf(), rng.randf())
		var k := rng.randf_range(0.0, 1.5)
		var f := rng.randf()
		var ss := smoothstep(0.35, 0.95, f)
		worst = maxf(worst, (rgb * k * ss * 0.9 - (rgb * (k * 0.9)) * ss).length())
	check(worst < 1e-6, "the palette's pre-multiplied rim is DmCreatureMat's (%s)" % worst)
	# the normal map's frame (no tangents on the crowd mesh): tangent along +U, bitangent along -V (Godot's own, the glTF's with V down), z rebuilt from xy
	var n := Vector3(0, 0, 1)
	var map := Vector3(0.7, 0.2, 0.0)   # the texel: x +0.4, y -0.6
	var want := Vector3(0.4, -0.6, sqrt(1.0 - 0.16 - 0.36)).normalized()
	var got := bumped(n, Vector3(0.01, 0, 0), Vector3(0, 0.01, 0), Vector2(0.02, 0), Vector2(0, -0.02), map)
	check(got.distance_to(want) < 1e-5, "the normal map leans a surface the way its texel says: U to the right, V down the image (%s)" % got)
	got = bumped(n, Vector3(0.01, 0, 0), Vector3(0, 0.01, 0), Vector2(-0.02, 0), Vector2(0, -0.02), map)
	check(got.distance_to(Vector3(-0.4, -0.6, want.z).normalized()) < 1e-5, "a mirrored U mirrors the lean (%s)" % got)
	var rot := Basis(Vector3(1, 2, 3).normalized(), 1.1)   # the same surface turned about: the frame turns with it
	got = bumped(rot * n, rot * Vector3(0.01, 0, 0), rot * Vector3(0, 0.01, 0), Vector2(0.02, 0), Vector2(0, -0.02), map)
	check(got.distance_to(rot * want) < 1e-5, "and in any orientation (%s)" % got)
	got = bumped(n, Vector3(0.01, 0, 0), Vector3(0.02, 0, 0), Vector2.ZERO, Vector2.ZERO, map)   # UVs that do not change over the pixel: no frame, the surface keeps its normal, no NaN
	check(is_finite(got.x) and is_finite(got.y) and is_finite(got.z) and got.distance_to(n) < 1e-5, "a degenerate frame leaves the normal as it is (%s)" % got)


## crowd_vat.gdshader's bumped(), line by line (`dp1`, `dp2`: dFdx and dFdy of the view-space position; `du1`, `du2`: of the UV).
func bumped(n: Vector3, dp1: Vector3, dp2: Vector3, du1: Vector2, du2: Vector2, map: Vector3) -> Vector3:
	var m := Vector3(map.x * 2.0 - 1.0, map.y * 2.0 - 1.0, 0.0)
	m.z = sqrt(maxf(0.0, 1.0 - (m.x * m.x + m.y * m.y)))
	var p2 := dp2.cross(n)
	var p1 := n.cross(dp1)
	var t := p2 * du1.x + p1 * du2.x
	var b := -(p2 * du1.y + p1 * du2.y)
	var inv := 1.0 / sqrt(maxf(maxf(t.dot(t), b.dot(b)), 1e-20))
	return (t * (inv * m.x) + b * (inv * m.y) + n * m.z).normalized()


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
	var r: Dictionary = Baker.bake(root, slug, dir, {"assets_dir": _assets, "rows_path": _rows})
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
	check(data.lod_triangles[0] <= Baker.max_triangles_of(slug) and not r.over_budget, "%s: level 0 within %d triangles" % [slug, Baker.max_triangles_of(slug)])
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
		ids.append(int(custom[i * Baker.CUSTOM_STRIDE]))
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



## A thrall variant: the warrior's sword and shield on its hands (DmEntityViews._make_thrall, DmCreature.attach / _calibrate / _tick_props). The variant shares the
## plain body's textures (baked next to it first) and holds only its props: rigid meshes in their own space and a track of the hand's transform. Held against the
## fully placed props (Baker._place_props, today's formula on the true pose): at every kind of frame, between frames as the old baked columns interpolated, and
## with blends.
func _test_props(variant: String) -> void:
	var model: String = Baker.split_variant(variant)[0]
	var base_dir := OUT.path_join(model)
	if DirAccess.dir_exists_absolute(base_dir):
		_remove_dir(base_dir)   # the variant bakes the plain body it shares first
	var r: Dictionary = Baker.bake(root, variant, OUT.path_join(variant), {"assets_dir": _assets, "rows_path": _rows})
	check(r.ok, "%s: bakes (%s)" % [variant, r.get("error", "")])
	if not r.ok:
		return
	var data: CrowdVatData = ResourceLoader.load(OUT.path_join(variant).path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REPLACE)
	var base: CrowdVatData = ResourceLoader.load(base_dir.path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REPLACE)
	check(base != null and base.format == CrowdVatData.FORMAT and base.prop_count == 0 and base.track_tex == null, "%s: the plain body was baked first, in its own folder" % variant)
	if base == null or data == null:
		return
	check(data.format == CrowdVatData.FORMAT and data.slug == variant and r.get("variant", false), "%s: a variant of the current format" % variant)
	var own := DirAccess.get_files_at(OUT.path_join(variant))
	check(not own.has("pos.res") and not own.has("nrm.res") and own.has("track.res") and own.has("model.tres") and own.has("mesh_lod0.res"),
		"%s: the variant holds no position or normal texture, only its track, meshes and model (%s)" % [variant, str(own)])
	check(data.pos_tex.resource_path == base_dir.path_join("pos.res") and data.nrm_tex.resource_path == base_dir.path_join("nrm.res"),
		"%s: it draws with the plain body's textures (%s)" % [variant, data.pos_tex.resource_path])
	check(data.clip_names == base.clip_names and data.clip_seconds == base.clip_seconds and data.roles == base.roles and data.tex_width == base.tex_width and data.tex_rows == base.tex_rows
		and data.total_frames == base.total_frames and data.pos_lo == base.pos_lo and data.pos_step == base.pos_step and data.pos_radix == base.pos_radix, "%s: clips, roles and position codes are the body's" % variant)
	check(data.clip_table == base.clip_table, "%s: the body's frames are the plain body's" % variant)
	var trk_img := data.track_tex.get_image()
	check(trk_img.get_format() == Image.FORMAT_RGBAF and trk_img.get_width() == 3 * data.prop_count and data.prop_count == 2 and trk_img.get_height() < 4096 and not trk_img.has_mipmaps(),
		"%s: the track is RGBAF, three texels for each of its %d props, a row a frame (%d x %d)" % [variant, data.prop_count, trk_img.get_width(), trk_img.get_height()])
	check(data.track_table.size() == data.clip_names.size(), "%s: a track row per clip" % variant)
	var next_row := 0
	for c in data.clip_names.size():
		var row := data.track_table[c]
		check(int(row.x) == next_row and row.y >= base.clip_table[c].y and row.z >= base.clip_table[c].z - 1e-3 and row.w == base.clip_table[c].w,
			"%s: track of %s has the body's frames or finer (%d at %.1f, the body's %d at %.1f)" % [variant, data.clip_names[c], row.y, row.z, base.clip_table[c].y, base.clip_table[c].z])
		var covered := row.y / row.z if row.w > 0.5 else (row.y - 1.0) / row.z
		check(absf(covered - data.clip_seconds[c]) < 1e-3, "%s: track of %s covers the clip's %.3f s" % [variant, data.clip_names[c], data.clip_seconds[c]])
		next_row += int(row.y)
	check(next_row == trk_img.get_height(), "%s: track rows add up" % variant)
	for plan in r.clips:
		check(plan.error <= Baker.ERROR_TARGET or int(plan.frames) == Baker.MAX_FRAMES, "%s: props of %s interpolate within %.0f mm (got %.0f mm at %d rows)" % [variant, plan.name, Baker.ERROR_TARGET * 1000.0, plan.error * 1000.0, plan.frames])
	var own_bytes := 0
	for f in own:
		own_bytes += FileAccess.get_file_as_bytes(OUT.path_join(variant).path_join(f)).size()
	var base_bytes := 0
	for f in DirAccess.get_files_at(base_dir):
		base_bytes += FileAccess.get_file_as_bytes(base_dir.path_join(f)).size()
	print("INFO %s: %d KB of its own (track %d KB) next to the plain body's %d KB" % [variant, own_bytes / 1024, FileAccess.get_file_as_bytes(OUT.path_join(variant).path_join("track.res")).size() / 1024, base_bytes / 1024])
	check(own_bytes < 2 * 1024 * 1024 and own_bytes < base_bytes / 4, "%s: a variant costs a mesh and a track, not a body (%d KB against %d KB)" % [variant, own_bytes / 1024, base_bytes / 1024])

	var plain: Dictionary = Baker.load_model(root, model, _assets, _rows)
	var src_vc: int = ((plain.mesh_instance as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var specs := Baker.props_for("warrior")
	var g := Baker._prop_geometry(specs)
	var up: int = (g.verts as PackedVector3Array).size()
	check(data.part_albedo.size() == 3 and data.part_pbr.size() == 3 and data.part_emission.size() == 3,
		"%s: the sword's metal, the shield's wood and its glowing boss are its prop parts (%d)" % [variant, data.part_albedo.size()])
	check(data.part_emission[2].v > 0.1 and data.part_emission[0].v == 0.0, "%s: only the shield boss glows, as today's" % variant)
	# the Legion weapon's colour reaches the sword (crowd_looks.json thrall_props `kit`) and nothing else: not the shield, not the lit boss
	var kit_parts := 0
	for k in data.part_kit.size():
		kit_parts += 1 if data.part_kit[k] > 0.0 else 0
	check(data.part_kit.size() == data.part_albedo.size() and kit_parts == 1 and data.part_kit[0] > 0.0, "%s: the sword's metal takes the kit weapon's colour, the shield and its boss keep theirs (%s)" % [variant, str(data.part_kit)])
	# the mesh: the body's vertices as the plain body has them (same animation ids), the props' in their own space with their prop and part
	var a := data.meshes[0].surface_get_arrays(0)
	var custom: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM0]
	var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var base_a := base.meshes[0].surface_get_arrays(0)
	var base_custom: PackedFloat32Array = base_a[Mesh.ARRAY_CUSTOM0]
	var parts_ok := verts.size() == src_vc + up
	var body_ok := true
	var props_ok := true
	for i in verts.size():
		if i < src_vc:
			var S := Baker.CUSTOM_STRIDE
			body_ok = body_ok and custom[i * S] == base_custom[i * S] and custom[i * S + 1] == 0.0 and custom[i * S + 2] == base_custom[i * S + 2] and custom[i * S + 3] == base_custom[i * S + 3] \
				and verts[i] == (base_a[Mesh.ARRAY_VERTEX] as PackedVector3Array)[i]
		else:
			var j := i - src_vc
			props_ok = props_ok and verts[i] == (g.verts as PackedVector3Array)[j] and norms[i].distance_to((g.normals as PackedVector3Array)[j]) < 1e-3 \
				and int(custom[i * Baker.CUSTOM_STRIDE]) == (g.owner as PackedInt32Array)[j] and custom[i * Baker.CUSTOM_STRIDE + 1] == (g.part as PackedFloat32Array)[j] and custom[i * Baker.CUSTOM_STRIDE + 1] >= 1.0 \
				and custom[i * Baker.CUSTOM_STRIDE + 1] <= 3.0 and custom[i * Baker.CUSTOM_STRIDE + 2] == 0.0 and custom[i * Baker.CUSTOM_STRIDE + 3] == 0.0
	check(parts_ok and body_ok, "%s: the body's %d vertices are the plain body's (part 0, its animation ids and rest pose)" % [variant, src_vc])
	check(props_ok, "%s: the props' %d vertices follow in their own space, each with its prop (0 or 1) and part (1..3)" % [variant, up])
	check(data.aabb.encloses(base.aabb) and data.meshes[0].custom_aabb == data.aabb, "%s: bounds hold the body's and the props'" % variant)

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

	# 1. the track at the frames it holds (first, middle, last of every clip): the shader's prop branch against the fully placed props
	var pv: PackedVector3Array = g.verts
	var pn: PackedVector3Array = g.normals
	var ow: PackedInt32Array = g.owner
	var worst := 0.0
	var worst_n := 0.0
	var inside := true
	for c in data.clip_names.size():
		var tb := data.track_table[c]
		for f in [0, int(tb.y) / 2, int(tb.y) - 1]:
			var t := minf(float(f) / tb.z, data.clip_seconds[c])
			Baker.pose_at(plain, data.clip_names[c], t)
			Baker._place_props(plain, {"g": g, "rig": rig}, at, an, 0)
			var custom_c := CrowdVatData.pack_custom(c, t)
			for j in up:
				var got := _shader_prop_vertex(data, trk_img, pv[j], pn[j], ow[j], custom_c)
				worst = maxf(worst, (got[0] - at[j]).length())
				worst_n = maxf(worst_n, rad_to_deg((got[1] as Vector3).angle_to(an[j])))
				inside = inside and data.aabb.grow(0.003).has_point(at[j])
	print("INFO %s: props from the track vs the fully placed props at %d clips x 3 frames: worst %.3f mm, normals %.3f deg" % [variant, data.clip_names.size(), worst * 1000.0, worst_n])
	check(worst <= PROP_TOLERANCE, "%s: the track holds the props where the formula puts them at its frames (worst %.3f mm, within %.1f mm)" % [variant, worst * 1000.0, PROP_TOLERANCE * 1000.0])
	check(worst_n <= 0.5, "%s: the props' normals through the track within half a degree (%.3f)" % [variant, worst_n])
	check(inside, "%s: the bounds hold the props at every checked frame" % variant)

	# 2. random times and blends: where the old columns would have put them (the straight line between the two frames' placed props: a convex blend, as
	# the shader's blend of matrices), and within the interpolation tolerance of the true pose
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261017
	var worst_old := 0.0
	var worst_true := 0.0
	var worst_blend := 0.0
	var scratch_a := PackedVector3Array()
	var scratch_b := PackedVector3Array()
	var scratch_n := PackedVector3Array()
	scratch_a.resize(up)
	scratch_b.resize(up)
	scratch_n.resize(up)
	for round_ in 24:
		var c := rng.randi_range(0, data.clip_names.size() - 1)
		var c2 := rng.randi_range(0, data.clip_names.size() - 1)
		var t := rng.randf_range(0.0, data.clip_seconds[c] * 1.4)
		var t2 := rng.randf_range(0.0, data.clip_seconds[c2] * 1.4)
		var w := rng.randf_range(0.0, 0.999)
		var tb := data.track_table[c]
		var fr := _frames(tb, t)
		var plan := {"fps": tb.z}
		var name_c := String(data.clip_names[c])
		Baker.pose_at(plain, name_c, Baker.frame_time(plan, int(fr[0])))
		Baker._place_props(plain, {"g": g, "rig": rig}, scratch_a, scratch_n, 0)
		Baker.pose_at(plain, name_c, Baker.frame_time(plan, int(fr[1])))   # a loop's last frame blends into frame 0, a one-shot holds its last
		Baker._place_props(plain, {"g": g, "rig": rig}, scratch_b, scratch_n, 0)
		var truth1 := _placed(plain, rig, g, name_c, _true_time(data, c, t))
		var truth2 := _placed(plain, rig, g, String(data.clip_names[c2]), _true_time(data, c2, t2))
		var custom_c := CrowdVatData.pack_custom(c, t)
		var custom_b := CrowdVatData.pack_custom(c, t, c2, t2, w)
		for j in up:
			var got := _shader_prop_vertex(data, trk_img, pv[j], pn[j], ow[j], custom_c)
			worst_old = maxf(worst_old, (got[0] - scratch_a[j].lerp(scratch_b[j], float(fr[2]))).length())
			worst_true = maxf(worst_true, (got[0] - truth1[j]).length())
			var gb := _shader_prop_vertex(data, trk_img, pv[j], pn[j], ow[j], custom_b)
			worst_blend = maxf(worst_blend, (gb[0] - (truth1[j] as Vector3).lerp(truth2[j], w)).length())
			check((gb[1] as Vector3).is_normalized(), "%s: a blended prop normal stays unit length" % variant)
	print("INFO %s: props at random times: %.3f mm from the old straight line between frames, %.1f mm from the true pose, %.1f mm blended" % [variant, worst_old * 1000.0, worst_true * 1000.0, worst_blend * 1000.0])
	check(worst_old <= PROP_TOLERANCE, "%s: between frames the props are where the baked columns interpolated them (worst %.3f mm)" % [variant, worst_old * 1000.0])
	check(worst_true <= INTERPOLATION_TOLERANCE and worst_blend <= INTERPOLATION_TOLERANCE, "%s: props within %.2f m of the true pose at any time, blended too (%.3f, %.3f)" % [variant, INTERPOLATION_TOLERANCE, worst_true, worst_blend])
	(plain.root as Node).free()


## The fully placed prop vertices (today's formula on the true pose of `clip` at `t`).
func _placed(m: Dictionary, rig: Array, g: Dictionary, clip: String, t: float) -> PackedVector3Array:
	var out_p := PackedVector3Array()
	var out_n := PackedVector3Array()
	out_p.resize((g.verts as PackedVector3Array).size())
	out_n.resize(out_p.size())
	Baker.pose_at(m, clip, t)
	Baker._place_props(m, {"g": g, "rig": rig}, out_p, out_n, 0)
	return out_p


## The position codes: radices for boxes of every size fit 32 bits and keep the step as fine as the box allows, and a position survives the baker's code and the shader's
## decoding within half a step (an exact code comes back exactly).
func _test_codes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var shown := []
	for extent in [Vector3(1.4, 1.9, 1.5), Vector3(3.4, 2.7, 2.7), Vector3(6.0, 7.0, 5.0), Vector3(0.9, 0.5, 0.0), Vector3(0.3, 0.3, 0.3), Vector3(12.0, 2.0, 20.0)]:
		var radix := Baker.position_radix(extent)
		var step := Baker.position_step(extent, radix)
		var data := CrowdVatData.new()
		data.pos_radix = radix
		data.pos_lo = Vector3(-0.5, 0.0, -1.0)
		data.pos_step = step
		_check_codes(data, "box %s" % str(extent), AABB(data.pos_lo, extent))
		var ideal_product := 1.0   # the finest common step the 32 bits allow with no power-of-two constraint (an axis with no extent costs 2 levels)
		var live := 0
		var coarsest := 0.0
		for i in 3:
			if extent[i] > 0.0:
				ideal_product *= extent[i]
				live += 1
				coarsest = maxf(coarsest, step[i])
		var ideal := pow(ideal_product / pow(2.0, 32.0 - (3 - live)), 1.0 / float(live))
		check(coarsest <= 1.5 * ideal, "box %s: the finest step %.3f mm is within 1.5 x the ideal %.3f mm" % [str(extent), coarsest * 1000.0, ideal * 1000.0])
		var worst := 0.0
		var inv := Vector3.ONE / step
		for i in 400:
			var p := data.pos_lo + Vector3(rng.randf() * extent.x, rng.randf() * extent.y, rng.randf() * extent.z)
			var code := Baker.position_code(p, data.pos_lo, inv, radix)
			check(code >= 0 and code < (1 << 32), "box %s: a code is 32 bits" % str(extent))
			var t := Color(float(code & 255) / 255.0, float((code >> 8) & 255) / 255.0, float((code >> 16) & 255) / 255.0, float((code >> 24) & 255) / 255.0)
			worst = maxf(worst, (_decode_pos(data, t) - p).length())
		check(worst <= 0.5 * step.length() + 1e-6, "box %s: positions come back within half a step (%.3f of %.3f mm)" % [str(extent), worst * 1000.0, 0.5 * step.length() * 1000.0])
		shown.append("%s: %s levels, step %.2f mm, worst %.2f mm" % [str(extent), str(radix), coarsest * 1000.0, worst * 1000.0])
	print("INFO position codes: ", " | ".join(shown))
