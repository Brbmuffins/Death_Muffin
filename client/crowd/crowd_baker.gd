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
const FLAP_FRAMES := 24   ## frames per wing beat of an unrigged winged model (a sine through 24 points: under 3 mm off the true beat)
## A clip gets the fewest frames per second whose linear interpolation stays this close to the true pose (metres, worst vertex half-way between two
## frames), or MAX_FRAMES. Idle breathes slowly and needs a few frames a second, a run or a swing needs dozens.
const ERROR_TARGET := 0.025
const FPS_STEPS := [4.0, 6.0, 8.0, 12.0, 16.0, 20.0, 24.0, 30.0, 40.0, 50.0, 60.0]
## Texels per row at most (older phones guarantee 2048 or 4096); a frame wider than this takes several rows.
const MAX_WIDTH := 2048
## Crowd models at most this many triangles (ROADMAP "Performance rules").
const MAX_TRIANGLES := 5000
const PROP_CALIBRATE_S := 0.25 + 4.0 / 60.0   ## DmCreature: props calibrate once the body has stood 0.25 s, 4 frames later
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


## The model an enemy id is drawn with: the crowd's own table (crowd/crowd_looks.json enemy_model, today's DmEntityViews.ENEMY_SLUG: what CrowdView draws),
## then godot/data/content/enemies.json modelSlug (the robber's model when it names none); `name` itself when it is already a model slug.
## A variant name "<model>+<thrall kind>" -> [model slug, kind]; a plain slug -> [slug, ""].
static func split_variant(name: String) -> Array:
	var i := name.find("+")
	return [name, ""] if i < 0 else [name.substr(0, i), name.substr(i + 1)]


## The hand props a thrall kind carries (DmEntityViews._make_thrall, crowd_looks.json `thrall_props`): [{build, arg?, bone, dir, follow}].
static func props_for(kind: String) -> Array:
	var looks: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://crowd/crowd_looks.json"))
	return ((looks as Dictionary).get("thrall_props", {}) as Dictionary).get(kind, []) if looks is Dictionary else []


static func model_for(name: String, enemies_path := "") -> String:
	var looks: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://crowd/crowd_looks.json"))
	if looks is Dictionary and (looks as Dictionary).get("enemy_model", {}).has(name):
		return String((looks as Dictionary).enemy_model[name])
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
	if skeletons.is_empty() and aps.is_empty() and meshes.size() == 1:
		return _load_static(root, meshes[0], row, slug, rel_url)
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


## An unrigged model (a prop the game animates in its shader: the moth, the bat, the choir wraith, the seraph): one mesh, no skeleton. Scaled to
## the row's height with its feet at the origin, as DmModels does for any model. Returns the same keys as load_model plus `static`.
static func _load_static(root: Node3D, mi: MeshInstance3D, row: Dictionary, slug: String, rel_url: String) -> Dictionary:
	if mi.mesh == null or mi.mesh.get_surface_count() != 1:
		root.free()
		return {"ok": false, "error": "%s: the mesh must be one surface" % slug}
	var local := relative_to(root, mi)
	var bb: AABB = local * mi.mesh.get_aabb()
	var s := float(row.height) / maxf(bb.size.y, 0.0001)
	var c := bb.get_center()
	var offset := Vector3(-c.x * s, -bb.position.y * s, -c.z * s)
	var yaw := float(row.yaw)
	var rot := Basis(Vector3.UP, yaw)
	var place := Transform3D(rot * Basis.from_scale(Vector3.ONE * s), rot * offset) * local
	return {"ok": true, "static": true, "root": root, "mesh_instance": mi, "row": row, "slug": slug, "scale": s, "offset": offset,
		"yaw": yaw, "height": float(row.height), "place": place, "url": rel_url}


## The wing beat of an unrigged model by its slug (crowd/crowd_looks.json `wings`, today's DmEntityViews.WINGS: speed, amp, body), {} = none.
static func wings_for(slug: String) -> Dictionary:
	var looks: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://crowd/crowd_looks.json"))
	if looks is Dictionary:
		return ((looks as Dictionary).get("wings", {}) as Dictionary).get(slug, {})
	return {}


## Today's wing flap (DmCreatureMat's vertex shader, wingFlap.ts) on mesh-local points and normals at `t` seconds (phase 0): the parts past the
## body's half-width swing about the hinge by amp x sin(t x speed), more toward the tips. `ax` 2 = along z, 0 = along x (the longer side).
static func flap(verts: PackedVector3Array, normals: PackedVector3Array, t: float, w: Dictionary, ax: int, center: float, half: float,
		out_p: PackedVector3Array, out_n: PackedVector3Array) -> void:
	var speed := float(w.speed)
	var amp := float(w.amp)
	var body := half * float(w.get("body", 0.3))
	for i in verts.size():
		var v := verts[i]
		var n := normals[i]
		var ws := v[ax] - center
		var wd := absf(ws) - body
		if wd > 0.0:
			var wf := smoothstep(0.0, maxf(0.001, half - body), wd)
			var wa := amp * sin(t * speed) * (0.35 + 0.65 * wf)
			v[ax] = center + signf(ws) * (body + wd * cos(wa))
			v.y += wd * sin(wa)
			var th := signf(ws) * wa   # the wing part turns by this in the (side, up) plane
			var nh := n[ax]
			var nyv := n.y
			n[ax] = nh * cos(th) - nyv * sin(th)
			n.y = nh * sin(th) + nyv * cos(th)
		out_p[i] = v
		out_n[i] = n


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
## Returns {ok, error, slug, triangles (per level), frames, anim_vertices, vertices, pos_bytes, nrm_bytes, bytes, clips: [plan], seconds, over_budget}.
## `slug` may name a variant, "<model>+<thrall kind>": the plain model carrying that kind's hand props (`thrall_props` in crowd_looks.json). The variant shares the
## plain body's textures (`<out_dir>/../<model>`, baked first when it is not there or is of another format) and adds its props' mesh and a transform track: `_bake_variant`.
static func bake(host: Node, slug: String, out_dir: String, opts := {}) -> Dictionary:
	var started := Time.get_ticks_msec()
	var assets_dir: String = opts.get("assets_dir", default_assets_dir())
	var parts := split_variant(slug)
	var result: Dictionary
	if String(parts[1]) != "":
		result = _bake_variant(host, slug, String(parts[0]), String(parts[1]), out_dir, opts, assets_dir)
	else:
		var m := load_model(host, String(parts[0]), assets_dir, opts.get("rows_path", default_rows_path()))
		if not m.ok:
			return m
		result = _bake_static(m, out_dir, opts, assets_dir) if m.get("static", false) else _bake_loaded(m, out_dir, opts, assets_dir)
		(m.root as Node).free()
	result["seconds"] = float(Time.get_ticks_msec() - started) / 1000.0
	return result


## Animation ids: vertices that move alike (same place, normal and, for a rigged model, bones and weights; they differ only by UV seams) share one baked
## column. Returns {ids (per vertex), rep (id -> first vertex with it)}; `per` 0 for an unrigged model.
static func _unique_ids(verts: PackedVector3Array, normals: PackedVector3Array, bones: PackedInt32Array, weights: PackedFloat32Array, per: int) -> Dictionary:
	var ids := PackedInt32Array()
	ids.resize(verts.size())
	var rep := PackedInt32Array()   # id -> first vertex with it
	var seen := {}
	for i in verts.size():
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
	return {"ids": ids, "rep": rep}


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

	var unique := _unique_ids(verts, normals, bones, weights, per)
	var ids: PackedInt32Array = unique.ids
	var rep: PackedInt32Array = unique.rep
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

	# The rest pose in creature space and each clip's source timing, then the writer the unrigged path shares.
	var rest_p := PackedVector3Array()
	var rest_n := PackedVector3Array()
	rest_p.resize(vc)
	rest_n.resize(vc)
	skin(rest_matrices(m), verts, normals, bones, weights, per, rest_p, rest_n)
	var meta: Array = []
	for plan in plans:
		var src := ap.get_animation(plan.name)
		var timing: Variant = timings.get(plan.name)
		meta.append({"source_length": src.length, "impact": float(timing[1]) if timing is Array and timing.size() > 1 else -1.0,
			"landing": landing_time(src) if String(plan.name).rstrip("0123456789") == "death" else -1.0})
	return _write(m, out_dir, opts, assets_dir, {"plans": plans, "sampled": sampled, "total": total, "uc": uc, "width": width, "rpf": rpf,
		"ids": ids, "vc": vc, "rest_p": rest_p, "rest_n": rest_n, "uvs": uvs, "arrays": arrays, "roles": roles, "meta": meta,
		"source_triangles": indices.size() / 3})

## An unrigged model's bake: one baked loop, the wing beat for a winged model (FLAP_FRAMES frames over 2 pi / speed seconds) or a still pose
## for the rest, playing every role (today the shader keeps beating through a fall, and the body layer does the rest).
static func _bake_static(m: Dictionary, out_dir: String, opts: Dictionary, assets_dir: String) -> Dictionary:
	var slug: String = m.slug
	var mi: MeshInstance3D = m.mesh_instance
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var vc := verts.size()
	if vc == 0 or normals.size() != vc or uvs.size() != vc or indices.is_empty():
		return {"ok": false, "error": "%s: the mesh needs normals, UVs and indices" % slug}
	var unique := _unique_ids(verts, normals, PackedInt32Array(), PackedFloat32Array(), 0)   # vertices at the same place with the same normal move alike
	var ids: PackedInt32Array = unique.ids
	var rep: PackedInt32Array = unique.rep
	var uc := rep.size()
	var rv := PackedVector3Array()
	var rn := PackedVector3Array()
	for i in uc:
		rv.append(verts[rep[i]])
		rn.append(normals[rep[i]])
	var rpf := ceili(float(uc) / MAX_WIDTH)
	var width := ceili(float(uc) / rpf)
	var place: Transform3D = m.place
	var nbasis := place.basis.inverse().transposed()
	var wing: Dictionary = opts.get("wings", wings_for(slug))
	var bb := mi.mesh.get_aabb()   # the shader's frame: the mesh's own
	var ax := 2 if bb.size.z > bb.size.x else 0
	var half := bb.size[ax] / 2.0
	var center := bb.position[ax] + half
	var clip := "fly" if not wing.is_empty() else "rest"
	var seconds := TAU / float(wing.speed) if not wing.is_empty() else 1.0
	var frames := FLAP_FRAMES if not wing.is_empty() else 2
	var plan := {"name": clip, "seconds": seconds, "loop": not wing.is_empty(), "frames": frames, "first": 0, "seam": 0.0,
		"fps": float(frames) / seconds if not wing.is_empty() else float(frames - 1) / seconds}
	var lp := PackedVector3Array()
	var ln := PackedVector3Array()
	lp.resize(uc)
	ln.resize(uc)
	var mid_p := PackedVector3Array()
	var mid_n := PackedVector3Array()
	mid_p.resize(uc)
	mid_n.resize(uc)
	var frames_p: Array = []
	var frames_n: Array = []
	var error := 0.0
	for f in frames:
		var t := frame_time(plan, f) if not wing.is_empty() else 0.0
		if wing.is_empty():
			lp = rv.duplicate()
			ln = rn.duplicate()
		else:
			flap(rv, rn, t, wing, ax, center, half, lp, ln)
		var out_p := PackedVector3Array()
		var out_n := PackedVector3Array()
		out_p.resize(uc)
		out_n.resize(uc)
		for i in uc:
			out_p[i] = place * lp[i]
			out_n[i] = (nbasis * ln[i]).normalized()
		if f > 0 and not wing.is_empty():   # the straight line between two frames against the true beat half-way between them
			flap(rv, rn, (frame_time(plan, f - 1) + t) * 0.5, wing, ax, center, half, mid_p, mid_n)
			var prev: PackedVector3Array = frames_p[f - 1]
			for i in uc:
				error = maxf(error, (place * mid_p[i] - (prev[i] + out_p[i]) * 0.5).length())
		frames_p.append(out_p)
		frames_n.append(out_n)
	plan["error"] = error
	var roles := {}
	for role in FALLBACK:
		roles[role] = [clip]
	var rest_p := PackedVector3Array()
	var rest_n := PackedVector3Array()
	rest_p.resize(vc)
	rest_n.resize(vc)
	for i in vc:
		rest_p[i] = place * verts[i]
		rest_n[i] = (nbasis * normals[i]).normalized()
	return _write(m, out_dir, opts, assets_dir, {"plans": [plan], "sampled": [{"plan": plan, "pos": frames_p, "nrm": frames_n}], "total": frames,
		"uc": uc, "width": width, "rpf": rpf, "ids": ids, "vc": vc, "rest_p": rest_p, "rest_n": rest_n, "uvs": uvs, "arrays": arrays,
		"roles": roles, "meta": [{"source_length": seconds, "impact": -1.0, "landing": -1.0}], "source_triangles": indices.size() / 3})


## The shared second half of a bake: writes the frames into the position and normal textures, the meshes (rest pose in creature space, the
## animation id in CUSTOM0, one index list per level of detail) and the CrowdVatData. `w`: plans, sampled frames, the rest pose and per-clip
## source timings, from the rigged path (_bake_loaded) or the unrigged one (_bake_static).
static func _write(m: Dictionary, out_dir: String, opts: Dictionary, assets_dir: String, w: Dictionary) -> Dictionary:
	var slug: String = m.slug
	var plans: Array = w.plans
	var sampled: Array = w.sampled
	var total: int = w.total
	var uc: int = w.uc
	var width: int = w.width
	var rpf: int = w.rpf
	var ids: PackedInt32Array = w.ids
	var vc: int = w.vc
	var uvs: PackedVector2Array = w.uvs
	var arrays: Array = w.arrays
	var roles: Dictionary = w.roles
	var height := total * rpf
	# The bounds of every pose, the radices of the position codes over them, then every frame into the textures.
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for c in plans.size():
		for f in int(plans[c].frames):
			for p: Vector3 in sampled[c].pos[f]:
				lo = lo.min(p)
				hi = hi.max(p)
	var aabb := AABB(lo, hi - lo)
	var radix := position_radix(aabb.size)
	var step := position_step(aabb.size, radix)
	var inv := Vector3.ONE / step
	var pos := PackedByteArray()
	pos.resize(height * width * 4)
	var nrm := PackedByteArray()
	nrm.resize(height * width * 2)
	var worst := 0.0   # the largest distance of a decoded position from the baked one
	for c in plans.size():
		for f in int(plans[c].frames):
			var out_p: PackedVector3Array = sampled[c].pos[f]
			var out_n: PackedVector3Array = sampled[c].nrm[f]
			var base := (int(plans[c].first) + f) * rpf * width
			for i in uc:
				var p := out_p[i]
				var code := position_code(p, lo, inv, radix)
				var o := (base + i) * 4
				pos[o] = code & 255
				pos[o + 1] = (code >> 8) & 255
				pos[o + 2] = (code >> 16) & 255
				pos[o + 3] = (code >> 24) & 255
				worst = maxf(worst, (lo + Vector3(code % radix.x, (code / radix.x) % radix.y, code / (radix.x * radix.y)) * step - p).length())
				var e := oct_encode(out_n[i])
				nrm[(base + i) * 2] = roundi(e.x * 255.0)
				nrm[(base + i) * 2 + 1] = roundi(e.y * 255.0)
	var pos_img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pos)
	var nrm_img := Image.create_from_data(width, height, false, Image.FORMAT_RG8, nrm)

	# The mesh: the rest pose in creature space, the animation id of every vertex in CUSTOM0 (y, the material part, 0 for the body), one index list per level.
	var rest_p: PackedVector3Array = w.rest_p
	var rest_n: PackedVector3Array = w.rest_n
	var ids_f := PackedFloat32Array()
	ids_f.resize(vc * 2)
	for i in vc:
		ids_f[i * 2] = float(ids[i])
	var levels := _levels(arrays, int(opts.get("max_triangles", MAX_TRIANGLES)))
	var made := _make_meshes(levels, rest_p, rest_n, uvs, ids_f, aabb)

	# Write: textures and meshes as binary resources, the clip table and the links as one small text resource.
	var dir := ProjectSettings.globalize_path(out_dir) if out_dir.begins_with("res://") else out_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var saved := {}
	saved["pos"] = _save(ImageTexture.create_from_image(pos_img), out_dir.path_join("pos.res"))
	saved["nrm"] = _save(ImageTexture.create_from_image(nrm_img), out_dir.path_join("nrm.res"))
	var data := CrowdVatData.new()
	data.format = CrowdVatData.FORMAT
	data.slug = slug
	var found := _texture_paths(assets_dir, m.url)
	data.albedo_path = found.albedo
	data.orm_path = found.orm
	data.normal_path = found.normal
	data.height = m.height
	data.yaw = m.yaw
	data.anim_vertex_count = uc
	data.tex_width = width
	data.tex_rows = rpf
	data.total_frames = total
	for c in plans.size():
		var plan: Dictionary = plans[c]
		data.clip_names.append(plan.name)
		data.clip_table.append(Vector4(plan.first, plan.frames, plan.fps, 1.0 if plan.loop else 0.0))
		data.clip_seconds.append(plan.seconds)
		data.clip_source_length.append(float(w.meta[c].source_length))
		data.clip_impact.append(float(w.meta[c].impact))
		data.clip_landing.append(float(w.meta[c].landing))
	var stride: Variant = (m.row as Dictionary).get("stride")
	if stride is Dictionary:
		data.stride_walk = float((stride as Dictionary).get("walk", 0.0))
		data.stride_run = float((stride as Dictionary).get("run", 0.0))
	data.roles = roles
	data.aabb = aabb
	data.pos_tex = saved.pos
	data.pos_lo = lo
	data.pos_step = step
	data.pos_radix = radix
	data.nrm_tex = saved.nrm
	data.meshes = _save_meshes(made.meshes, out_dir)
	data.lod_triangles = made.tris
	var err := ResourceSaver.save(data, out_dir.path_join("model.tres"))
	if err != OK:
		return {"ok": false, "error": "%s: cannot write %s (%d)" % [slug, out_dir, err]}
	return {"ok": true, "slug": data.slug, "dir": dir, "triangles": made.tris, "source_triangles": w.source_triangles, "over_budget": levels.over_budget,
		"frames": total, "anim_vertices": uc, "vertices": vc, "texture": Vector2i(width, height), "clips": plans, "roles": roles,
		"pos_bytes": width * height * 4, "nrm_bytes": width * height * 2, "bytes": width * height * 6, "aabb": aabb, "pos_error": worst, "pos_radix": radix}


## One mesh per level of detail from `levels` (`_levels`): the vertex arrays every level shares (CUSTOM0: x the animation id or the prop, y the material part)
## and its own index list; `custom_aabb` = the bounds of every baked pose. Returns {meshes, tris (per level)}.
static func _make_meshes(levels: Dictionary, verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, custom: PackedFloat32Array, aabb: AABB) -> Dictionary:
	var meshes: Array[Mesh] = []
	var tris := PackedInt32Array()
	for idx in levels.indices:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_NORMAL] = normals
		a[Mesh.ARRAY_TEX_UV] = uvs
		a[Mesh.ARRAY_CUSTOM0] = custom
		a[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		mesh.custom_aabb = aabb
		meshes.append(mesh)
		tris.append((idx as PackedInt32Array).size() / 3)
	return {"meshes": meshes, "tris": tris}


static func _save_meshes(meshes: Array[Mesh], out_dir: String) -> Array[Mesh]:
	var saved: Array[Mesh] = []
	for l in meshes.size():
		saved.append(_save(meshes[l], out_dir.path_join("mesh_lod%d.res" % l)))
	return saved


# ----------------------------------------------------------------------------------------------------------------------- position codes

## Levels per axis of the position codes over a box of size `extent`: three integer codes in one 32-bit texel (`n = x + rx * (y + ry * z)`, rx * ry * rz at most
## 2^32). The shader splits the 32 bits in two halves and divides by rx, so rx is a power of two; the baker picks the one, and the finest common step for y and
## z within the rest of the 32 bits, whose largest step over the three axes is smallest. A position is then within half a step of its code, per axis.
static func position_radix(extent: Vector3) -> Vector3i:
	var best := Vector3i(2, 2, 2)
	var best_step := INF
	for k in range(4, 17):
		var rx := 1 << k
		var budget := (1 << 32) / rx
		var lo_s := 1e-7
		var hi_s := 1e4
		for _i in 80:   # the finest common step for y and z whose levels fit the budget
			var s := sqrt(lo_s * hi_s)
			if _levels_at(extent.y, s) * _levels_at(extent.z, s) <= budget:
				hi_s = s
			else:
				lo_s = s
		var ry := _levels_at(extent.y, hi_s)
		var rz := _levels_at(extent.z, hi_s)
		var worst_step := maxf(extent.x / float(rx - 1), maxf(extent.y / float(ry - 1), extent.z / float(rz - 1)))
		if worst_step < best_step:
			best_step = worst_step
			best = Vector3i(rx, ry, rz)
	return best


static func _levels_at(extent: float, step: float) -> int:
	return maxi(2, ceili(extent / step) + 1)


## The code of a position: `n = x + rx * (y + ry * z)` for the nearest code on each axis (`inv` = 1 / `position_step`, `lo` the box's corner).
static func position_code(p: Vector3, lo: Vector3, inv: Vector3, radix: Vector3i) -> int:
	var qx := clampi(roundi((p.x - lo.x) * inv.x), 0, radix.x - 1)
	var qy := clampi(roundi((p.y - lo.y) * inv.y), 0, radix.y - 1)
	var qz := clampi(roundi((p.z - lo.z) * inv.z), 0, radix.z - 1)
	return qx + radix.x * (qy + radix.y * qz)


## The size of one code step per axis (1 for an axis with no extent: every code is 0).
static func position_step(extent: Vector3, radix: Vector3i) -> Vector3:
	return Vector3(extent.x / float(radix.x - 1) if extent.x > 0.0 else 1.0, extent.y / float(radix.y - 1) if extent.y > 0.0 else 1.0,
		extent.z / float(radix.z - 1) if extent.z > 0.0 else 1.0)

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

# ------------------------------------------------------------------------------------------------------------------------- hand props

## A thrall variant, "<model>+<kind>" (`bake`): the plain model `model_slug` carrying the hand props of `kind`. It shares the plain body's position and normal
## textures and clip table (the plain model is baked first when `<out_dir>/../<model>` has none of this format); the props are rigid meshes in their own space,
## drawn through a track of the hand's transform for every frame of every clip (`track.res`, a few KB). The variant's own files: `model.tres`, the meshes
## (the body's vertices and the props') and the track.
static func _bake_variant(host: Node, slug: String, model_slug: String, kind: String, out_dir: String, opts: Dictionary, assets_dir: String) -> Dictionary:
	var specs := props_for(kind)
	if specs.is_empty():
		return {"ok": false, "error": "%s: no hand props for the thrall kind '%s' (crowd_looks.json thrall_props)" % [slug, kind]}
	var base_dir: String = opts.get("base_dir", out_dir.get_base_dir().path_join(model_slug))
	var base := _load_baked(base_dir)
	if base == null or base.format != CrowdVatData.FORMAT:
		var plain := bake(host, model_slug, base_dir, opts)
		if not plain.ok:
			return plain
		base = _load_baked(base_dir)
	var m := load_model(host, model_slug, assets_dir, opts.get("rows_path", default_rows_path()))
	if not m.ok:
		return m
	var result := _write_variant(m, slug, specs, base, out_dir, opts, assets_dir)
	(m.root as Node).free()
	return result


static func _load_baked(dir: String) -> CrowdVatData:
	var path := dir.path_join("model.tres")
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as CrowdVatData


static func _write_variant(m: Dictionary, slug: String, specs: Array, base: CrowdVatData, out_dir: String, opts: Dictionary, assets_dir: String) -> Dictionary:
	if m.get("static", false):
		return {"ok": false, "error": "%s: hand props need a rigged model" % slug}
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
	var unique := _unique_ids(verts, normals, bones, weights, per)
	var ids: PackedInt32Array = unique.ids
	if (unique.rep as PackedInt32Array).size() != base.anim_vertex_count:
		return {"ok": false, "error": "%s: the plain body has %d animation ids, this model %d (bake it again)" % [slug, base.anim_vertex_count, (unique.rep as PackedInt32Array).size()]}
	var g := _prop_geometry(specs)
	var up: int = (g.verts as PackedVector3Array).size()
	var idle: Array = base.roles.get("idle", [])
	var rig := _prop_rig(m, specs, String(idle[0]) if not idle.is_empty() else String(base.clip_names[0]))

	# The track: every clip the plain body bakes, at least as many frames per second as the body (the props swing wider than any vertex of the body: more when
	# a blade's tip needs them), one row per frame, three texels per prop.
	var plans: Array = []
	var sampled: Array = []   # per plan: the props' transforms of every frame
	var total := 0
	for c in base.clip_names.size():
		var tb := base.clip_table[c]
		var range_ := {"name": String(base.clip_names[c]), "seconds": base.clip_seconds[c], "loop": tb.w > 0.5}
		var got := _sample_track(m, range_, int(tb.y), g, rig)
		got.plan["first"] = total
		total += int(got.plan.frames)
		plans.append(got.plan)
		sampled.append(got.xforms)
	if total > 4096:
		return {"ok": false, "error": "%s: %d rows of track (4096 at most)" % [slug, total]}
	var width := 3 * specs.size()
	var trk := PackedFloat32Array()
	trk.resize(total * width * 4)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var pv: PackedVector3Array = g.verts
	var ow: PackedInt32Array = g.owner
	for c in plans.size():
		for f in int(plans[c].frames):
			var xs: Array = sampled[c][f]
			var row := int(plans[c].first) + f
			for s in specs.size():
				var x: Transform3D = xs[s]
				for i in 3:   # the rows of the 3x4 matrix, the translation in w
					var o := (row * width + s * 3 + i) * 4
					trk[o] = x.basis.x[i]
					trk[o + 1] = x.basis.y[i]
					trk[o + 2] = x.basis.z[i]
					trk[o + 3] = x.origin[i]
			for j in up:
				var p: Vector3 = (xs[ow[j]] as Transform3D) * pv[j]
				lo = lo.min(p)
				hi = hi.max(p)
	var trk_img := Image.create_from_data(width, total, false, Image.FORMAT_RGBAF, trk.to_byte_array())   # full floats: a few KB, and a hand's reach is exact

	# The mesh: the body's vertices at the rest pose and the props' in their own space; the idle pose holds the props where today's calibration does, for the levels of detail.
	var rest_p := PackedVector3Array()
	var rest_n := PackedVector3Array()
	rest_p.resize(vc)
	rest_n.resize(vc)
	skin(rest_matrices(m), verts, normals, bones, weights, per, rest_p, rest_n)
	var idle_p := PackedVector3Array()
	var idle_n := PackedVector3Array()
	idle_p.resize(up)
	idle_n.resize(up)
	pose_at(m, String((rig as Array)[0].idle), PROP_CALIBRATE_S)
	_place_props(m, {"g": g, "rig": rig}, idle_p, idle_n, 0)
	var lod_p := rest_p.duplicate()
	var lod_n := rest_n.duplicate()
	lod_p.append_array(idle_p)
	lod_n.append_array(idle_n)
	var lod_uv := uvs.duplicate()
	var idx := indices.duplicate()
	for k in (g.indices as PackedInt32Array):
		idx.append(vc + k)
	for j in up:
		lod_uv.append(Vector2.ZERO)
	var lod_arrays := []
	lod_arrays.resize(Mesh.ARRAY_MAX)
	lod_arrays[Mesh.ARRAY_VERTEX] = lod_p
	lod_arrays[Mesh.ARRAY_NORMAL] = lod_n
	lod_arrays[Mesh.ARRAY_TEX_UV] = lod_uv
	lod_arrays[Mesh.ARRAY_INDEX] = idx
	var prop_triangles := (g.indices as PackedInt32Array).size() / 3
	# The budget is the body's: the props' few hundred triangles come on top, so an armed body keeps the detail its bare one has.
	var levels := _levels(lod_arrays, int(opts.get("max_triangles", MAX_TRIANGLES)) + prop_triangles)
	var all_p := rest_p.duplicate()
	var all_n := rest_n.duplicate()
	all_p.append_array(pv)
	all_n.append_array(g.normals)
	var custom := PackedFloat32Array()   # CUSTOM0: x the animation id (a prop: which prop), y the material part (0 the body)
	custom.resize((vc + up) * 2)
	for i in vc:
		custom[i * 2] = float(ids[i])
	for j in up:
		custom[(vc + j) * 2] = float(ow[j])
		custom[(vc + j) * 2 + 1] = (g.part as PackedFloat32Array)[j]
	var aabb := base.aabb.merge(AABB(lo, hi - lo))
	var made := _make_meshes(levels, all_p, all_n, lod_uv, custom, aabb)

	var dir := ProjectSettings.globalize_path(out_dir) if out_dir.begins_with("res://") else out_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var data := CrowdVatData.new()
	data.format = CrowdVatData.FORMAT
	data.slug = slug
	var found := _texture_paths(assets_dir, m.url)
	data.albedo_path = found.albedo
	data.orm_path = found.orm
	data.normal_path = found.normal
	data.height = base.height
	data.yaw = base.yaw
	data.anim_vertex_count = base.anim_vertex_count
	data.tex_width = base.tex_width
	data.tex_rows = base.tex_rows
	data.total_frames = base.total_frames
	data.clip_names = base.clip_names
	data.clip_table = base.clip_table
	data.clip_seconds = base.clip_seconds
	data.clip_source_length = base.clip_source_length
	data.clip_impact = base.clip_impact
	data.clip_landing = base.clip_landing
	data.stride_walk = base.stride_walk
	data.stride_run = base.stride_run
	data.roles = base.roles
	data.aabb = aabb
	data.pos_tex = base.pos_tex
	data.pos_lo = base.pos_lo
	data.pos_step = base.pos_step
	data.pos_radix = base.pos_radix
	data.nrm_tex = base.nrm_tex
	data.prop_count = specs.size()
	data.track_tex = _save(ImageTexture.create_from_image(trk_img), out_dir.path_join("track.res"))
	for plan in plans:
		data.track_table.append(Vector4(plan.first, plan.frames, plan.fps, 1.0 if plan.loop else 0.0))
	for pm: Dictionary in g.parts:
		data.part_albedo.append(pm.albedo)
		data.part_pbr.append(Vector4(pm.metal, pm.rough, 0.0, 0.0))
		data.part_emission.append(pm.emis)
	data.meshes = _save_meshes(made.meshes, out_dir)
	data.lod_triangles = made.tris
	var err := ResourceSaver.save(data, out_dir.path_join("model.tres"))
	if err != OK:
		return {"ok": false, "error": "%s: cannot write %s (%d)" % [slug, out_dir, err]}
	return {"ok": true, "slug": slug, "variant": true, "prop_parts": data.part_albedo.size(), "dir": dir, "triangles": made.tris, "source_triangles": indices.size() / 3,
		"over_budget": levels.over_budget, "frames": total, "anim_vertices": base.anim_vertex_count, "vertices": vc + up, "texture": Vector2i(width, total), "clips": plans,
		"roles": base.roles, "pos_bytes": 0, "nrm_bytes": 0, "bytes": width * total * 16, "aabb": aabb}


## The hand props' transforms over a clip: the fewest frames per second (FPS_STEPS) that keep the linear blend of two frames' matrices within ERROR_TARGET
## of the true pose half-way between them (worst prop vertex), and at least `min_frames` (the plain body's), or MAX_FRAMES.
## Returns {plan (frames, fps, error), xforms: per frame, each prop's Transform3D}.
static func _sample_track(m: Dictionary, range_: Dictionary, min_frames: int, g: Dictionary, rig: Array) -> Dictionary:
	var tried := 0
	var got := {}
	for fps in FPS_STEPS:
		var frames := clampi(ceili(range_.seconds * fps) + (0 if range_.loop else 1), 2, MAX_FRAMES)
		if frames == tried or frames < min_frames:
			continue
		tried = frames
		got = _track_frames(m, with_frames(range_, frames), g, rig)
		if got.plan.error <= ERROR_TARGET or frames == MAX_FRAMES:
			break
	if got.is_empty():   # the body's frames are no step of ours: take them as they are
		got = _track_frames(m, with_frames(range_, min_frames), g, rig)
	return got


static func _track_frames(m: Dictionary, plan: Dictionary, g: Dictionary, rig: Array) -> Dictionary:
	var pv: PackedVector3Array = g.verts
	var ow: PackedInt32Array = g.owner
	var frames: Array = []
	var error := 0.0
	for f in int(plan.frames):
		pose_at(m, plan.name, frame_time(plan, f))
		frames.append(_prop_xforms(m, rig))
		if f > 0:   # how far the blend of this frame's matrices and the last one's strays from the true pose half-way between them
			pose_at(m, plan.name, (frame_time(plan, f - 1) + frame_time(plan, f)) * 0.5)
			var mid := _prop_xforms(m, rig)
			var a: Array = frames[f - 1]
			var b: Array = frames[f]
			for j in pv.size():
				var s := ow[j]
				error = maxf(error, ((mid[s] as Transform3D) * pv[j] - ((a[s] as Transform3D) * pv[j] + (b[s] as Transform3D) * pv[j]) * 0.5).length())
	var out := plan.duplicate()
	out["error"] = error
	out["seam"] = 0.0
	return {"plan": out, "xforms": frames}


## Today's prop builders (DmGearProps.bone_sword, round_shield, bone_bow, bone_staff) as geometry in the prop's own space: every MeshInstance3D's
## triangles moved by its transform in the prop, the spec each vertex belongs to, and its material part (1-based; the parts list the distinct
## materials: linear albedo, metallic, roughness, linear emission x energy; an unshaded part glows its own colour).
static func _prop_geometry(specs: Array) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var part := PackedFloat32Array()
	var owner := PackedInt32Array()
	var indices := PackedInt32Array()
	var parts: Array = []
	for s in specs.size():
		var spec: Dictionary = specs[s]
		var node: Node3D = Callable(DmGearProps, String(spec.build)).callv([float(spec.arg)] if spec.has("arg") else [])
		for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
			var xf := Transform3D.IDENTITY
			var n: Node = mi
			while n != node:
				xf = (n as Node3D).transform * xf
				n = n.get_parent()
			var a := mi.mesh.surface_get_arrays(0)
			var mv: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var mn: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			var mx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if mx.is_empty():
				for i in mv.size():
					mx.append(i)
			var k := _part_of(parts, mi.material_override as BaseMaterial3D)
			var base := verts.size()
			for i in mv.size():
				verts.append(xf * mv[i])
				normals.append((xf.basis * mn[i]).normalized())
				part.append(float(k + 1))
				owner.append(s)
			for i in mx:
				indices.append(base + i)
		node.free()
	return {"verts": verts, "normals": normals, "part": part, "owner": owner, "indices": indices, "parts": parts}


static func _part_of(parts: Array, mat: BaseMaterial3D) -> int:
	var albedo := Color(0.8, 0.8, 0.8)
	var metal := 0.0
	var rough := 1.0
	var emis := Color(0, 0, 0)
	if mat != null:
		albedo = mat.albedo_color.srgb_to_linear()
		metal = mat.metallic
		rough = mat.roughness
		if mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
			emis = albedo
		elif mat.emission_enabled:
			emis = mat.emission.srgb_to_linear() * mat.emission_energy_multiplier
	var rec := {"albedo": albedo, "metal": metal, "rough": rough, "emis": emis}
	for i in parts.size():
		if parts[i] == rec:
			return i
	parts.append(rec)
	return parts.size() - 1


## The props' calibration (DmCreature._calibrate) on the idle pose where today's runs: a body settled for 0.25 s, then 4 frames (`_tick_props`), so
## PROP_CALIBRATE_S into the idle loop: each prop's up turned onto its `dir` in creature space. Per spec: {bone, base_q, dir, follow, idle}. A bone the model
## lacks is the hip, as DmCreature.attach does.
static func _prop_rig(m: Dictionary, specs: Array, idle: String) -> Array:
	var sk: Skeleton3D = m.skeleton
	pose_at(m, idle, PROP_CALIBRATE_S)
	var out: Array = []
	for spec: Dictionary in specs:
		var b := sk.find_bone(String(spec.bone))
		if b < 0:
			b = maxi(0, sk.find_bone("Hip"))
		var h := (m.place as Transform3D) * sk.get_bone_global_pose(b)
		var pq := h.basis.orthonormalized().get_rotation_quaternion()
		var d: Array = spec.dir
		var dir := Vector3(float(d[0]), float(d[1]), float(d[2])).normalized()
		out.append({"bone": b, "base_q": Quaternion(Vector3.UP, (pq.inverse() * dir).normalized()), "dir": dir, "follow": float(spec.get("follow", 1.0)), "idle": idle})
	return out


## Each prop's transform in the pose the skeleton holds (DmCreature._tick_props): the hand's rotation times the calibrated one, its up pulled toward `dir` by
## 1 - follow, at the bone's origin; props are authored in world units, so no scale. One per spec of the rig.
static func _prop_xforms(m: Dictionary, rig: Array) -> Array[Transform3D]:
	var sk: Skeleton3D = m.skeleton
	var xs: Array[Transform3D] = []
	for r: Dictionary in rig:
		var h := (m.place as Transform3D) * sk.get_bone_global_pose(int(r.bone))
		var pq := h.basis.orthonormalized().get_rotation_quaternion()
		var driven: Quaternion = pq * (r.base_q as Quaternion)
		var up := driven * Vector3.UP
		var locked := Quaternion(up.normalized(), r.dir as Vector3) * driven
		xs.append(Transform3D(Basis(driven.slerp(locked, 1.0 - float(r.follow))), h.origin))
	return xs


## Every prop vertex where the current pose puts it (`_prop_xforms` on the prop's geometry): the fully placed prop the track is held against. Writes from `at` on.
static func _place_props(m: Dictionary, pr: Dictionary, out_p: PackedVector3Array, out_n: PackedVector3Array, at: int) -> void:
	var xs := _prop_xforms(m, pr.rig)
	var g: Dictionary = pr.g
	var pv: PackedVector3Array = g.verts
	var pn: PackedVector3Array = g.normals
	var ow: PackedInt32Array = g.owner
	for j in pv.size():
		var x := xs[ow[j]]
		out_p[at + j] = x * pv[j]
		out_n[at + j] = (x.basis * pn[j]).normalized()


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


## The colour, ORM and normal textures next to a model's glb (the sync keeps glTF's own file names), relative to the assets folder.
static func _texture_paths(assets_dir: String, url: String) -> Dictionary:
	var out := {"albedo": "", "orm": "", "normal": ""}
	var rel_dir := url.get_base_dir()
	var files := DirAccess.get_files_at(assets_dir.path_join(rel_dir))
	files.sort()
	for f in files:
		if f.ends_with(".webp") or f.ends_with(".png"):
			if f.contains("_Color_") and out.albedo == "":
				out.albedo = rel_dir.path_join(f)
			elif f.contains("_ORM_") and out.orm == "":
				out.orm = rel_dir.path_join(f)
			elif f.contains("_Normal") and out.normal == "":
				out.normal = rel_dir.path_join(f)
	return out
