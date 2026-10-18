class_name DmWarmup
extends RefCounted
## First-use hitch removal, shared by the warm-up (DmNextWarmup): what stays resident, which hero kits to drop, and the model list.

const MODELS := "res://assets/slice/models/"
const COVER_TEXT := "Waking the dead..."

## Keeps the loaded resources referenced (ResourceLoader's cache drops what nobody holds): path -> resource.
static var _held: Dictionary = {}
static var last_ms := 0
## Hero kits freed after the warm-up (tests, F3 diagnostics).
static var released_heroes := 0


static func hold(path: String, res: Resource) -> void:
	if res != null:
		_held[path] = res


## The hero model slugs this session can show: every playable discipline's (DmCharacterBuild.is_playable: the local hero, a joiner, a
## class change) plus the avatar's fallback body. The greyed-out disciplines cannot be picked, so their kits (~17 MB of raw texture each)
## never need to be resident.
static func hero_slugs_in_play() -> Array:
	var out: Array = ["necromancer"]
	for d in DmContent.file("disciplines").get("PLAYABLE_DISCIPLINES", []):
		var s := String((d as Dictionary).get("modelSlug", ""))
		var folder := String(DmCreature.model_entry(s).get("url", "")).get_slice("/", 1)   # a row can point at another model folder (the Reaper's hero_reaper_v2a)
		if folder != "":
			s = folder
		if s != "" and DmCharacterBuild.is_playable(float((d as Dictionary).get("classIndex", 0))) and not out.has(s):
			out.append(s)
	return out


## Drop the warm-up's reference to every hero kit the session cannot show. The shader variants are compiled by then; the cache frees a kit
## once nothing else holds it (a kit that can appear stays held, so DmModels.cold_loads stays 0 for it).
static func release_unused_heroes(also_keep: Array = []) -> int:
	var keep := hero_slugs_in_play()
	keep.append_array(also_keep)
	var n := 0
	for p in _held.keys():
		var rest := String(p).trim_prefix(MODELS)
		var slug := rest.get_slice("/", 0)
		if rest != p and slug.begins_with("hero_") and not keep.has(slug):
			_held.erase(p)
			n += 1
	released_heroes = n
	return n


static func _model_paths() -> Array:
	var out: Array = []
	for d in ResourceLoader.list_directory(MODELS):
		if not d.ends_with("/"):
			continue
		for f in ResourceLoader.list_directory(MODELS + d):
			if f.ends_with(".glb") or f.ends_with(".gltf"):
				out.append(MODELS + d + f)
	return out
