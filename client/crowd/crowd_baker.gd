class_name CrowdBaker
extends RefCounted
## Bakes a creature model into vertex-animation textures for crowd drawing (client/crowd/README.md). Headless, CPU only: the model's skinned
## vertices are computed from the skeleton pose and the mesh's bone weights for every frame of every clip the game plays, written as
## position and normal textures, next to a mesh with an animation id per vertex and a table of clips. Run through tools/bake_crowd.gd.
##
## The creature is baked exactly as DmModels / DmCreature (godot/) put it in the world: the height normalisation of DmModels.analyze, the yaw
## of its model row, the clip preparation of DmModels._prep_anims and DmCreature._prep_clips. Feet at the origin, +Z forward.

const FLINCH_CLIP_SECONDS := 0.5 * 1.35   # DmCreature.flinch plays this much of a hurt clip
const STRIKE_MAX_SPEED := 2.2             # DmAnimator.strike_timing: the fastest a strike clip plays
const STRIKE_FOLLOW := 0.3                # and the follow-through every caller uses
## Frames a clip may have at most.
const MAX_FRAMES := 128
## A clip gets the fewest frames per second whose linear interpolation stays this close to the true pose (metres, worst vertex half-way between two
## frames), or MAX_FRAMES. Idle breathes slowly and needs a few frames a second, a run or a swing needs dozens.
const ERROR_TARGET := 0.025
const FPS_STEPS := [4.0, 6.0, 8.0, 12.0, 16.0, 20.0, 24.0, 30.0, 40.0, 50.0, 60.0]
## Texels per row at most (older phones guarantee 2048 or 4096); a frame wider than this takes several rows.
const MAX_WIDTH := 2048
## Crowd models at most this many triangles (ROADMAP "Performance rules").
const MAX_TRIANGLES := 5000
const LOOPS := ["idle", "walk", "run", "channel"]
const STRIKES := ["attack", "cast", "slam", "sweep", "flick", "summon", "chop"]
## DmCreature.FALLBACK: which clip plays a role when the model lacks the first choice.
const FALLBACK := {
	"idle": ["idle", "walk"], "walk": ["walk", "run", "idle"], "run": ["run", "walk", "idle"],
	"attack": ["attack", "cast", "hurt"], "cast": ["cast", "attack", "hurt"], "hurt": ["hurt"], "death": ["death"],
	"dig": ["dig", "cast", "attack"], "chop": ["chop", "attack", "dig"], "dive": ["dive", "attack", "cast"],
	"talk": ["talk", "idle"], "talk2": ["talk2", "talk", "idle"],
	"slam": ["slam", "attack", "cast"], "sweep": ["sweep", "attack", "cast"], "flick": ["flick", "cast", "attack"],
	"channel": ["channel", "cast", "attack"], "summon": ["summon", "dig", "cast"],
}


## The folder holding `slice/models/...`: the client's own assets once they are synced, else the live game's.
static func default_assets_dir() -> String:
	var own := ProjectSettings.globalize_path("res://assets")
	if DirAccess.dir_exists_absolute(own.path_join("slice/models")):
		return own
	return ProjectSettings.globalize_path("res://").path_join("../godot/assets").simplify_path()


static func default_rows_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../godot/game/view_models.json").simplify_path()


## The model an enemy id is drawn with (godot/data/content/enemies.json modelSlug; the robber's model when it names none), or `name` itself
## when it is already a model slug.
static func model_for(name: String, enemies_path := "") -> String:
	if enemies_path == "":
		enemies_path = ProjectSettings.globalize_path("res://").path_join("../godot/data/content/enemies.json").simplify_path()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(enemies_path))
	if parsed is Dictionary and (parsed as Dictionary).get("ENEMIES", {}).has(name):
		return String((parsed as Dictionary).ENEMIES[name].get("modelSlug", "grave_robber"))
	return name


# ---------------------------------------------------------------------------------------------------------------------------- the model

## Loads a model the way the game sees it: scene, skeleton, mesh, prepared clips, and the normalisation DmModels.creature applies.
## `host` must be in the tree (the AnimationPlayer needs it). Returns {ok, error, root, ap, skeleton, mesh_instance, scale, offset, yaw,
## height, row, binds, mats_rest ...}; free `root` when done.
static func load_model(host: Node, slug: String, assets_dir: String, rows_path: String) -> Dictionary:
	var rows: Variant = JSON.parse_string(FileAccess.get_file_as_string(rows_path))
	if not (rows is Dictionary) or not (rows as Dictionary).has(slug):
		return {"ok": false, "error": "no model row for '%s' in %s" % [slug, rows_path]}
	var row: Dictionary = rows[slug]
	var rel_url := "slice/" + String(row.url)
	var glb := assets_dir.path_join(rel_url)
	if not FileAccess.file_exists(glb):
		return {"ok": false, "error": "missing %s" % glb}
	var state := GLTFState.new()
	var doc := GLTFDocument.new()
	if doc.append_from_file(glb, state, 0) != OK:
		return {"ok": false, "error": "cannot read %s" % glb}
	var root: Node3D = doc.generate_scene(state)
	host.add_child(root)
	var skeletons := root.find_children("*", "Skeleton3D", true, false)
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	var aps := root.find_children("*", "AnimationPlayer", true, false)
	if skeletons.size() != 1 or meshes.size() != 1 or aps.size() != 1:
		root.free()
		return {"ok": false, "error": "%s: needs exactly one skeleton, mesh and animation player (has %d, %d, %d)" % [slug, skeletons.size(), meshes.size(), aps.size()]}
	var skeleton: Skeleton3D = skeletons[0]
	var mi: MeshInstance3D = meshes[0]
	var ap: AnimationPlayer = aps[0]
	if mi.skin == null or mi.skin.get_bind_count() == 0 or mi.mesh.get_surface_count() != 1:
		root.free()
		return {"ok": false, "error": "%s: the mesh must be one skinned surface" % slug}
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	prep_clips(ap)
	# DmModels.analyze: the rest-pose box of the skinned mesh decides the scale (to the row's height) and where the feet stand.
	var skin := mi.skin
	var bone0 := skin.get_bind_bone(0)
	if bone0 < 0:
		bone0 = skeleton.find_bone(skin.get_bind_name(0))
	var xf := relative_to(root, skeleton) * skeleton.get_bone_global_rest(bone0) * skin.get_bind_pose(0)
	var bb: AABB = xf * mi.mesh.get_aabb()
	var s := float(row.height) / maxf(bb.size.y, 0.0001)
	var c := bb.get_center()
	var offset := Vector3(-c.x * s, -bb.position.y * s, -c.z * s)
	var yaw := float(row.yaw)
	var rot := Basis(Vector3.UP, yaw)
	# creature space = holder(yaw) * model(scale, offset) * the mesh's place in the scene
	var place := Transform3D(rot * Basis.from_scale(Vector3.ONE * s), rot * offset) * relative_to(root, mi)
	var binds: Array[Transform3D] = []
	var bones := PackedInt32Array()
	for i in skin.get_bind_count():
		binds.append(skin.get_bind_pose(i))
		var b := skin.get_bind_bone(i)
		bones.append(b if b >= 0 else skeleton.find_bone(skin.get_bind_name(i)))
	return {"ok": true, "root": root, "ap": ap, "skeleton": skeleton, "mesh_instance": mi, "row": row, "slug": slug, "scale": s, "offset": offset,
		"yaw": yaw, "height": float(row.height), "place": place, "binds": binds, "bind_bones": bones, "url": rel_url}


static func relative_to(root: Node, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


static func _track_of(a: Animation, bone: String, type: int) -> int:
	for i in a.get_track_count():
		if a.track_get_type(i) == type and String(a.track_get_path(i)).get_slice(":", 1) == bone:
			return i
	return -1


## DmModels._prep_anims (loops, walk and run drift) then DmCreature._prep_clips (an enemy's Hip pinned to the idle's ground position).
static func prep_clips(ap: AnimationPlayer) -> void:
	for nm in ap.get_animation_list():
		var a := ap.get_animation(nm)
		a.loop_mode = Animation.LOOP_LINEAR if String(nm) in LOOPS else Animation.LOOP_NONE
		if not (String(nm) in ["walk", "run"]):
			continue
		for i in a.get_track_count():
			if a.track_get_type(i) != Animation.TYPE_POSITION_3D or a.track_get_key_count(i) < 2:
				continue
			var bone := String(a.track_get_path(i)).get_slice(":", 1)
			if not (bone == "Hip" or bone.ends_with("Root")):
				continue
			var n := a.track_get_key_count(i)
			var v0: Vector3 = a.track_get_key_value(i, 0)
			var v1: Vector3 = a.track_get_key_value(i, n - 1)
			var t1 := a.track_get_key_time(i, n - 1)
			if t1 <= 0.0:
				continue
			for k in n:
				var v: Vector3 = a.track_get_key_value(i, k)
				a.track_set_key_value(i, k, v - (v1 - v0) * (a.track_get_key_time(i, k) / t1))
	var idle: Animation = ap.get_animation("idle") if ap.has_animation("idle") else null
	var anchor: Variant = null
	if idle != null:
		var it := _track_of(idle, "Hip", Animation.TYPE_POSITION_3D)
		if it >= 0 and idle.track_get_key_count(it) > 0:
			anchor = idle.track_get_key_value(it, 0)
	for nm in ap.get_animation_list():
		if String(nm).rstrip("0123456789") in ["death", "dive", "dig"]:
			continue
		var a := ap.get_animation(nm)
		var ht := _track_of(a, "Hip", Animation.TYPE_POSITION_3D)
		if ht < 0 or a.track_get_key_count(ht) == 0:
			continue
		var first: Vector3 = a.track_get_key_value(ht, 0)
		var ax: float = anchor.x if anchor != null else first.x
		var ay: float = anchor.y if anchor != null else first.y
		for k in a.track_get_key_count(ht):
			var v2: Vector3 = a.track_get_key_value(ht, k)
			a.track_set_key_value(ht, k, Vector3(ax, ay, v2.z))


## Skinning matrices of the pose the animation player and skeleton hold right now, into creature space.
static func pose_matrices(m: Dictionary) -> Array[Transform3D]:
	var skeleton: Skeleton3D = m.skeleton
	var binds: Array[Transform3D] = m.binds
	var bones: PackedInt32Array = m.bind_bones
	var out: Array[Transform3D] = []
	for i in binds.size():
		out.append((m.place as Transform3D) * skeleton.get_bone_global_pose(bones[i]) * binds[i])
	return out


static func rest_matrices(m: Dictionary) -> Array[Transform3D]:
	var skeleton: Skeleton3D = m.skeleton
	var binds: Array[Transform3D] = m.binds
	var bones: PackedInt32Array = m.bind_bones
	var out: Array[Transform3D] = []
	for i in binds.size():
		out.append((m.place as Transform3D) * skeleton.get_bone_global_rest(bones[i]) * binds[i])
	return out


## Puts a clip at `seconds` on the skeleton.
static func pose_at(m: Dictionary, clip: String, seconds: float) -> void:
	var ap: AnimationPlayer = m.ap
	(m.skeleton as Skeleton3D).reset_bone_poses()
	ap.assigned_animation = clip
	ap.seek(seconds, true)
	(m.skeleton as Skeleton3D).force_update_all_bone_transforms()


## Linear blend skinning of every vertex (rest positions and normals, `per` bone indices and weights per vertex) into out_p / out_n.
static func skin(mats: Array[Transform3D], verts: PackedVector3Array, normals: PackedVector3Array, bones: PackedInt32Array, weights: PackedFloat32Array,
		per: int, out_p: PackedVector3Array, out_n: PackedVector3Array) -> void:
	for i in verts.size():
		var p := Vector3.ZERO
		var n := Vector3.ZERO
		var v := verts[i]
		var nv := normals[i]
		for k in per:
			var w := weights[i * per + k]
			if w > 0.0:
				var mat := mats[bones[i * per + k]]
				p += (mat * v) * w
				n += (mat.basis * nv) * w
		out_p[i] = p
		out_n[i] = n.normalized()


# ------------------------------------------------------------------------------------------------------------------------------ clips

## Which clips play which role (DmCreature._resolve): role -> clip names. Variants (attack2, hurt3, death2) join their role's pool.
static func resolve_roles(have: Array) -> Dictionary:
	var out := {}
	for role in FALLBACK:
		for nm in FALLBACK[role]:
			if not have.has(nm):
				continue
			var pool := [nm]
			if role == nm and (role == "attack" or role == "hurt" or role == "death"):
				for i in range(2, 4):
					if have.has("%s%d" % [nm, i]):
						pool.append("%s%d" % [nm, i])
			out[role] = pool
			break
	return out


## What of a clip is baked: the seconds it covers and whether it loops. A strike is cut after the follow-through of its latest impact
## (DmAnimator.strike_timing), a hurt after the flinch; a death holds its last frame.
static func clip_range(nm: String, length: float, timings: Dictionary) -> Dictionary:
	var base := nm.rstrip("0123456789")
	var cover := length
	if base == "hurt":
		cover = minf(length, FLINCH_CLIP_SECONDS + 0.05)
	elif base in STRIKES:
		var t: Variant = timings.get(nm)
		var peak := float(t[1]) if t is Array and t.size() > 1 else length * 0.35
		cover = minf(length, minf(length, peak) + STRIKE_FOLLOW * STRIKE_MAX_SPEED + 0.05)
	return {"name": nm, "seconds": cover, "loop": base in LOOPS}


## DmCreature.landing_time: the second a death clip has come to rest, the first moment the Hip's height (local Z) is within 10% of its lowest point;
## 70% of the clip when it has no Hip track. Death clips are not pinned by prep_clips, so this reads the true track.
static func landing_time(a: Animation) -> float:
	var t := a.length * 0.7
	var tr := _track_of(a, "Hip", Animation.TYPE_POSITION_3D)
	if tr >= 0 and a.track_get_key_count(tr) > 2:
		var lo := INF
		var hi := -INF
		for k in a.track_get_key_count(tr):
			var z: float = (a.track_get_key_value(tr, k) as Vector3).z
			lo = minf(lo, z)
			hi = maxf(hi, z)
		if hi - lo > 1e-4:
			for k in a.track_get_key_count(tr):
				if (a.track_get_key_value(tr, k) as Vector3).z <= lo + 0.1 * (hi - lo):
					t = a.track_get_key_time(tr, k)
					break
	return t


## A plan for `frames` frames over the range: a loop's frames start at 0 and the last blends into the first, a one-shot's last frame is its end.
static func with_frames(range_: Dictionary, frames: int) -> Dictionary:
	var plan := range_.duplicate()
	plan["frames"] = frames
	plan["fps"] = float(frames) / range_.seconds if range_.loop else float(frames - 1) / range_.seconds
	return plan


## Seconds into the source clip of frame `i` of a plan.
static func frame_time(plan: Dictionary, i: int) -> float:
	return float(i) / float(plan.fps)


# ------------------------------------------------------------------------------------------------------------------------------ encoding

## Octahedral normal -> two 0..1 numbers (what the shader's vat_decode_normal undoes).
static func oct_encode(n: Vector3) -> Vector2:
	var l := absf(n.x) + absf(n.y) + absf(n.z)
	var p := Vector2(n.x, n.y) / l
	if n.z < 0.0:
		p = Vector2((1.0 - absf(p.y)) * (1.0 if p.x >= 0.0 else -1.0), (1.0 - absf(p.x)) * (1.0 if p.y >= 0.0 else -1.0))
	return p * 0.5 + Vector2(0.5, 0.5)


static func oct_decode(r: float, g: float) -> Vector3:
	var e := Vector2(r, g) * 2.0 - Vector2.ONE
	var n := Vector3(e.x, e.y, 1.0 - absf(e.x) - absf(e.y))
	var t := maxf(-n.z, 0.0)
	n.x += -t if n.x >= 0.0 else t
	n.y += -t if n.y >= 0.0 else t
	return n.normalized()


# --------------------------------------------------------------------------------------------------------------------------------- bake

## Bakes model `slug` into `out_dir` (res:// or user://). `opts`: assets_dir, rows_path, clips (only these, for tests), max_triangles.
## Returns {ok, error, slug, triangles (per level), frames, anim_vertices, vertices, pos_bytes, nrm_bytes, clips: [plan], seconds, over_budget}.
static func bake(host: Node, slug: String, out_dir: String, opts := {}) -> Dictionary:
	var started := Time.get_ticks_msec()
	var assets_dir: String = opts.get("assets_dir", default_assets_dir())
	var m := load_model(host, slug, assets_dir, opts.get("rows_path", default_rows_path()))
	if not m.ok:
		return m
	var result := _bake_loaded(m, out_dir, opts, assets_dir)
	(m.root as Node).free()
	result["seconds"] = float(Time.get_ticks_msec() - started) / 1000.0
	return result


static func _bake_loaded(m: Dictionary, out_dir: String, opts: Dictionary, assets_dir: String) -> Dictionary:
	var slug: String = m.slug
	var ap: AnimationPlayer = m.ap
	var mi: MeshInstance3D = m.mesh_instance
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var vc := verts.size()
	if vc == 0 or normals.size() != vc or uvs.size() != vc or bones.is_empty() or indices.is_empty():
		return {"ok": false, "error": "%s: the mesh needs normals, UVs, bone weights and indices" % slug}
	var per := bones.size() / vc
	var bind_count := (m.binds as Array).size()

	# Animation ids: vertices that move alike (same place, bones, weights and normal; they differ only by UV seams) share one baked column.
	var ids := PackedInt32Array()
	ids.resize(vc)
	var rep := PackedInt32Array()   # id -> first vertex with it
	var seen := {}
	for i in vc:
		var key := "%d,%d,%d,%d,%d,%d" % [roundi(verts[i].x * 1e5), roundi(verts[i].y * 1e5), roundi(verts[i].z * 1e5),
			roundi(normals[i].x * 100.0), roundi(normals[i].y * 100.0), roundi(normals[i].z * 100.0)]
		for k in per:
			key += ",%d,%d" % [bones[i * per + k], roundi(weights[i * per + k] * 1e4)]
		var id: int = seen.get(key, -1)
		if id < 0:
			id = rep.size()
			seen[key] = id
			rep.append(i)
		ids[i] = id
	var uc := rep.size()
	var rv := PackedVector3Array()
	var rn := PackedVector3Array()
	var rb := PackedInt32Array()
	var rw := PackedFloat32Array()
	for i in uc:
		var v := rep[i]
		rv.append(verts[v])
		rn.append(normals[v])
		for k in per:
			rb.append(bones[v * per + k])
			rw.append(weights[v * per + k])
	var rpf := ceili(float(uc) / MAX_WIDTH)
	var width := ceili(float(uc) / rpf)

	# Which clips, and how many frames.
	var have: Array = []
	for nm in ap.get_animation_list():
		have.append(String(nm))
	var roles := resolve_roles(have)
	var used := []
	for role in roles:
		for nm in roles[role]:
			if not used.has(nm) and (not opts.has("clips") or (opts.clips as Array).has(nm)):
				used.append(nm)
	used.sort()
	if used.is_empty() or used.size() > CrowdVatData.MAX_CLIPS:
		return {"ok": false, "error": "%s: %d clips to bake (1..%d allowed)" % [slug, used.size(), CrowdVatData.MAX_CLIPS]}
	var timings: Dictionary = (m.row as Dictionary).get("timings", {})
	var plans: Array = []
	var sampled: Array = []   # per plan: {pos: [PackedVector3Array per frame], nrm: [...]}
	var total := 0
	for nm in used:
		var range_ := clip_range(nm, ap.get_animation(nm).length, timings)
		var got := _sample_clip(m, range_, rv, rn, rb, rw, per)
		got.plan["first"] = total
		total += int(got.plan.frames)
		plans.append(got.plan)
		sampled.append(got)
	var height := total * rpf
	if height > 4096:
		return {"ok": false, "error": "%s: %d rows of baked frames (4096 at most)" % [slug, height]}

	# Write every frame into the textures.
	var pos := PackedFloat32Array()
	pos.resize(height * width * 4)
	var nrm := PackedByteArray()
	nrm.resize(height * width * 2)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for c in plans.size():
		for f in int(plans[c].frames):
			var out_p: PackedVector3Array = sampled[c].pos[f]
			var out_n: PackedVector3Array = sampled[c].nrm[f]
			var base := (int(plans[c].first) + f) * rpf * width
			for i in uc:
				var p := out_p[i]
				var o := (base + i) * 4
				pos[o] = p.x
				pos[o + 1] = p.y
				pos[o + 2] = p.z
				pos[o + 3] = 1.0
				lo = lo.min(p)
				hi = hi.max(p)
				var e := oct_encode(out_n[i])
				nrm[(base + i) * 2] = roundi(e.x * 255.0)
				nrm[(base + i) * 2 + 1] = roundi(e.y * 255.0)
	var aabb := AABB(lo, hi - lo)
	var pos_img := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, pos.to_byte_array())
	pos_img.convert(Image.FORMAT_RGBAH)
	var nrm_img := Image.create_from_data(width, height, false, Image.FORMAT_RG8, nrm)

	# The mesh: the rest pose in creature space, the animation id of every vertex in CUSTOM0, one index list per level of detail.
	var rest_p := PackedVector3Array()
	var rest_n := PackedVector3Array()
	rest_p.resize(vc)
	rest_n.resize(vc)
	skin(rest_matrices(m), verts, normals, bones, weights, per, rest_p, rest_n)
	var ids_f := PackedFloat32Array()
	ids_f.resize(vc)
	for i in vc:
		ids_f[i] = float(ids[i])
	var levels := _levels(arrays, int(opts.get("max_triangles", MAX_TRIANGLES)))
	var meshes: Array[Mesh] = []
	var tris := PackedInt32Array()
	for idx in levels.indices:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = rest_p
		a[Mesh.ARRAY_NORMAL] = rest_n
		a[Mesh.ARRAY_TEX_UV] = uvs
		a[Mesh.ARRAY_CUSTOM0] = ids_f
		a[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		mesh.custom_aabb = aabb
		meshes.append(mesh)
		tris.append((idx as PackedInt32Array).size() / 3)

	# Write: textures and meshes as binary resources, the clip table and the links as one small text resource.
	var dir := ProjectSettings.globalize_path(out_dir) if out_dir.begins_with("res://") else out_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var pos_tex := ImageTexture.create_from_image(pos_img)
	var nrm_tex := ImageTexture.create_from_image(nrm_img)
	var saved := {}
	saved["pos"] = _save(pos_tex, out_dir.path_join("pos.res"))
	saved["nrm"] = _save(nrm_tex, out_dir.path_join("nrm.res"))
	var saved_meshes: Array[Mesh] = []
	for l in meshes.size():
		saved_meshes.append(_save(meshes[l], out_dir.path_join("mesh_lod%d.res" % l)))
	var data := CrowdVatData.new()
	data.slug = slug
	var found := _texture_paths(assets_dir, m.url)
	data.albedo_path = found.albedo
	data.orm_path = found.orm
	data.height = m.height
	data.yaw = m.yaw
	data.anim_vertex_count = uc
	data.tex_width = width
	data.tex_rows = rpf
	data.total_frames = total
	for plan in plans:
		var src := ap.get_animation(plan.name)
		var timing: Variant = timings.get(plan.name)
		data.clip_names.append(plan.name)
		data.clip_table.append(Vector4(plan.first, plan.frames, plan.fps, 1.0 if plan.loop else 0.0))
		data.clip_seconds.append(plan.seconds)
		data.clip_source_length.append(src.length)
		data.clip_impact.append(float(timing[1]) if timing is Array and timing.size() > 1 else -1.0)
		data.clip_landing.append(landing_time(src) if String(plan.name).rstrip("0123456789") == "death" else -1.0)
	var stride: Variant = (m.row as Dictionary).get("stride")
	if stride is Dictionary:
		data.stride_walk = float((stride as Dictionary).get("walk", 0.0))
		data.stride_run = float((stride as Dictionary).get("run", 0.0))
	data.roles = roles
	data.aabb = aabb
	data.pos_tex = saved.pos
	data.nrm_tex = saved.nrm
	data.meshes = saved_meshes
	data.lod_triangles = tris
	var err := ResourceSaver.save(data, out_dir.path_join("model.tres"))
	if err != OK:
		return {"ok": false, "error": "%s: cannot write %s (%d)" % [slug, out_dir, err]}
	return {"ok": true, "slug": slug, "dir": dir, "triangles": tris, "source_triangles": indices.size() / 3, "over_budget": levels.over_budget,
		"frames": total, "anim_vertices": uc, "vertices": vc, "texture": Vector2i(width, height), "clips": plans, "roles": roles,
		"pos_bytes": width * height * 8, "nrm_bytes": width * height * 2, "aabb": aabb}


## Skins a clip at the fewest frames per second (FPS_STEPS) that keep interpolation within ERROR_TARGET, or at MAX_FRAMES.
## Returns {plan (frames, fps, error, seam), pos, nrm} with the skinned positions and normals of every frame.
static func _sample_clip(m: Dictionary, range_: Dictionary, rv: PackedVector3Array, rn: PackedVector3Array, rb: PackedInt32Array, rw: PackedFloat32Array,
		per: int) -> Dictionary:
	var tried := 0
	var got := {}
	for fps in FPS_STEPS:
		var frames := clampi(ceili(range_.seconds * fps) + (0 if range_.loop else 1), 2, MAX_FRAMES)
		if frames == tried:
			continue
		tried = frames
		got = _skin_frames(m, with_frames(range_, frames), rv, rn, rb, rw, per)
		if got.plan.error <= ERROR_TARGET or frames == MAX_FRAMES:
			break
	return got


static func _skin_frames(m: Dictionary, plan: Dictionary, rv: PackedVector3Array, rn: PackedVector3Array, rb: PackedInt32Array, rw: PackedFloat32Array,
		per: int) -> Dictionary:
	var uc := rv.size()
	var frames_p: Array = []
	var frames_n: Array = []
	var mid_p := PackedVector3Array()
	var mid_n := PackedVector3Array()
	mid_p.resize(uc)
	mid_n.resize(uc)
	var error := 0.0
	for f in int(plan.frames):
		var out_p := PackedVector3Array()
		var out_n := PackedVector3Array()
		out_p.resize(uc)
		out_n.resize(uc)
		pose_at(m, plan.name, frame_time(plan, f))
		skin(pose_matrices(m), rv, rn, rb, rw, per, out_p, out_n)
		frames_p.append(out_p)
		frames_n.append(out_n)
		if f > 0:   # how far the straight line between this frame and the last strays from the true pose half-way between them
			pose_at(m, plan.name, (frame_time(plan, f - 1) + frame_time(plan, f)) * 0.5)
			skin(pose_matrices(m), rv, rn, rb, rw, per, mid_p, mid_n)
			var prev: PackedVector3Array = frames_p[f - 1]
			for i in uc:
				error = maxf(error, (mid_p[i] - (prev[i] + out_p[i]) * 0.5).length())
	var seam := 0.0
	if plan.loop:   # a loop's last frame blends into its first; a clip whose last key differs from its first shows that jump (the game pops at it)
		pose_at(m, plan.name, plan.seconds - 1e-4)
		skin(pose_matrices(m), rv, rn, rb, rw, per, mid_p, mid_n)
		var first: PackedVector3Array = frames_p[0]
		for i in uc:
			seam = maxf(seam, (mid_p[i] - first[i]).length())
	var out := plan.duplicate()
	out["error"] = error
	out["seam"] = seam
	return {"plan": out, "pos": frames_p, "nrm": frames_n}


## Index lists of the levels of detail: the mesh itself if it fits the triangle budget, else Godot's own simplification (ImporterMesh).
## Levels share the vertex array. Returns {indices: [PackedInt32Array, ...] biggest first, over_budget}.
static func _levels(arrays: Array, max_triangles: int) -> Dictionary:
	var all: Array = [arrays[Mesh.ARRAY_INDEX]]
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, null, "s", 0)
	im.generate_lods(25.0, 25.0, [])
	for l in im.get_surface_lod_count(0):
		all.append(im.get_surface_lod_indices(0, l))
	all.sort_custom(func(a: PackedInt32Array, b: PackedInt32Array) -> bool: return a.size() > b.size())
	var first := 0
	while first < all.size() - 1 and (all[first] as PackedInt32Array).size() / 3 > max_triangles:
		first += 1
	return {"indices": all.slice(first), "over_budget": (all[first] as PackedInt32Array).size() / 3 > max_triangles}


static func _save(res: Resource, path: String) -> Resource:
	ResourceSaver.save(res, path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


## The colour and ORM textures next to a model's glb (the sync keeps glTF's own file names), relative to the assets folder.
static func _texture_paths(assets_dir: String, url: String) -> Dictionary:
	var out := {"albedo": "", "orm": ""}
	var rel_dir := url.get_base_dir()
	var files := DirAccess.get_files_at(assets_dir.path_join(rel_dir))
	files.sort()
	for f in files:
		if f.ends_with(".webp") or f.ends_with(".png"):
			if f.contains("_Color_") and out.albedo == "":
				out.albedo = rel_dir.path_join(f)
			elif f.contains("_ORM_") and out.orm == "":
				out.orm = rel_dir.path_join(f)
	return out
