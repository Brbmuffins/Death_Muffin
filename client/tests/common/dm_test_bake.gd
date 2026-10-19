extends RefCounted
## Test helper: a crowd model for a suite's own scratch folder, without baking it again when the checkout's setup (tools/check/prep.sh) baked it already.
## `bake(host, slug, out_dir, opts)` is CrowdBaker.bake with the same arguments and result (`ok`, `error`). When res://assets/crowd/baked holds the slug and was
## baked from the current inputs, it only copies that model's small `model.tres` (it points at the prepared meshes and textures by their res:// paths) into
## `out_dir`, so the suite's folder still holds exactly the models the suite asked for (a model it did not ask for stays unbaked there: the fallbacks and
## warnings its checks read are the same). Otherwise (no prep, a stale bake, a missing model) it bakes into `out_dir` as before. `reused` in the result says which.
## "Baked from the current inputs": prep.sh writes `.prep-bake` only after a bake from clean inputs and removes it when they are dirty; on top of that the file
## must be newer than every file the baker reads that is a plain file under client/ (the combat core, which the baker also poses through, is not checked here:
## a changed core is prep's business, and it rebuilds the bake with it). Not written for crowd_bake (it tests the baker itself) or any suite that checks a fresh bake.

const PREPARED := "res://assets/crowd/baked"
const INPUTS := ["res://crowd/crowd_baker.gd", "res://crowd/crowd_vat_data.gd", "res://crowd/crowd_looks.json", "res://tools/bake_crowd.gd", "res://game/dm_creature.gd",
	"res://game/dm_creature_mat.gd", "res://game/dm_gear_props.gd", "res://world/dm_models.gd", "res://world/dm_animator.gd", "res://game/view_models.json",
	"res://data/content/enemies.json"]
static var _current := -1   ## -1 unknown, 0 no, 1 yes (one answer per process)


## True when the prepared bake exists and is newer than the baker's inputs.
static func prepared_is_current() -> bool:
	if _current < 0:
		_current = 1 if _check_current() else 0
	return _current == 1


static func _check_current() -> bool:
	var stamp := PREPARED.path_join(".prep-bake")
	if not FileAccess.file_exists(stamp):
		return false
	var made := FileAccess.get_modified_time(stamp)
	for p in INPUTS:
		if not FileAccess.file_exists(p) or FileAccess.get_modified_time(p) > made:
			return false
	return true


static func bake(host: Node, slug: String, out_dir: String, opts := {}) -> Dictionary:
	var src := PREPARED.path_join(slug).path_join("model.tres")
	if prepared_is_current() and FileAccess.file_exists(src):
		DirAccess.make_dir_recursive_absolute(out_dir)
		if DirAccess.copy_absolute(src, out_dir.path_join("model.tres")) == OK:
			return {"ok": true, "reused": true}
	var baker: GDScript = load("res://crowd/crowd_baker.gd")
	var r: Dictionary = baker.bake(host, slug, out_dir, opts)
	r["reused"] = false
	return r
