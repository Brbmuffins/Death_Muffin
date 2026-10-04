class_name DmSampleBank
extends RefCounted
## Port of src/audio/samples.ts: the recorded-sample layer. Event -> clip table is the audio map; clips are imported OGG files under
## res://assets/audio/. Loaded lazily by pack (see DmAudioPacks) and released two areas later. Every clip is optional: a failed
## load leaves the sound silent (the web's synthesised stand-in is not ported, see README).

const ESM_DIR := "res://assets/audio/esm/"
const AMBIENCE_DIR := "res://assets/audio/ambience/"
const WORLD_DIR := "res://assets/audio/world/"
const COMBAT_DIR := "res://assets/audio/combat/"
const MUSIC_DIR := "res://assets/audio/music/"

## Older clips that stay (Kenney bells, generated accents). files: stems; gain; rate; jitter; synthMix (unused: no synth layer).
const LEGACY := {
	"bossToll": {"files": ["boss_toll_1", "boss_toll_2"], "gain": 0.85, "synthMix": 0.45},
	"distantBell": {"files": ["amb_bell_1", "amb_bell_2", "amb_bell_3"], "gain": 0.5, "synthMix": 0.4},
	"windGust": {"files": ["amb_gust_1", "amb_gust_2"], "gain": 0.3, "synthMix": 0.0},
	"emberCrackle": {"files": ["amb_ember_1", "amb_ember_2", "amb_ember_3"], "gain": 0.35, "synthMix": 0.0},
	"crowCaw": {"files": ["amb_crow_1", "amb_crow_2"], "gain": 0.34, "synthMix": 0.35},
	"crow": {"files": ["amb_crow_1", "amb_crow_2"], "gain": 0.4, "synthMix": 0.35},
	"crowdMoan": {"files": ["amb_moan_1", "amb_moan_2"], "gain": 0.5, "synthMix": 0.0},
}

var _streams: Dictionary = {}  # clip name -> AudioStream
var _last_pick: Dictionary = {}
var _owners: Dictionary = {}  # clip name -> {pack/legacy: true}
var _packs: Dictionary = {}
var _queue: Array = []  # [name, owner, path]
var failed := 0


## Resource path of a map clip (`Folder/name` -> flat `Folder__name.ogg`, as encoded by tools/godot/sync-audio-assets.sh).
static func clip_path(clip: String) -> String:
	return ESM_DIR + clip.replace("/", "__") + ".ogg"


## Where an older clip lives: loops in ambience/, amb_* in world/, the rest in combat/.
static func legacy_path(stem: String) -> String:
	if stem.begins_with("bed_"):
		return AMBIENCE_DIR + stem + ".ogg"
	if stem.begins_with("amb_"):
		return WORLD_DIR + stem + ".ogg"
	return COMBAT_DIR + stem + ".ogg"


static func legacy_names() -> Array[String]:
	var seen := {}
	var out: Array[String] = []
	for b in DmAudioAmbience.BED_FILES:
		seen[b] = true
		out.append(b)
	for k in LEGACY:
		for f in LEGACY[k]["files"]:
			if not seen.has(f):
				seen[f] = true
				out.append(f)
	return out


## True when the map has no pack clip for this id (status keep): the older sound stays as it is.
static func is_kept(sfx_name: String) -> bool:
	return not DmAudioMap.has_def(sfx_name) or DmAudioPacks.is_keep(sfx_name)


## True when a pack clip is used but the fit is imperfect: the older sound stays underneath.
static func is_partial(sfx_name: String) -> bool:
	return DmAudioMap.defn(sfx_name).get("status", "") == "partial"


func loaded() -> int:
	return _streams.size()


func has(clip: String) -> bool:
	return _streams.has(clip)


func stream(clip: String) -> AudioStream:
	return _streams.get(clip)


func has_pack(pack: String) -> bool:
	return _packs.has(pack)


func loaded_packs() -> Array[String]:
	var out: Array[String] = []
	for k in _packs.keys():
		out.append(k)
	return out


func pending() -> int:
	return _queue.size()


func _own(clip: String, owner: String) -> void:
	if not _owners.has(clip):
		_owners[clip] = {}
	_owners[clip][owner] = true


func _load_one(clip: String, path: String) -> void:
	if _streams.has(clip):
		return
	if ResourceLoader.exists(path):
		var s := ResourceLoader.load(path) as AudioStream
		if s != null:
			_streams[clip] = s
			return
	failed += 1


## Queue the older kept clips and the zone beds (small, always wanted). `pump` loads them.
func queue_legacy() -> void:
	for stem in legacy_names():
		_own(stem, "legacy")
		_queue.append([stem, legacy_path(stem)])


## Queue every clip of a pack (a no-op when already queued/loaded).
func queue_pack(pack: String) -> void:
	if _packs.has(pack):
		return
	_packs[pack] = true
	for c in DmAudioPacks.pack_clips(pack):
		_own(c, pack)
		_queue.append([c, clip_path(c)])


## Load up to `budget` queued clips (call each frame so a pack never stalls one frame). Returns clips still queued.
func pump(budget: int = 6) -> int:
	while budget > 0 and _queue.size() > 0:
		var item: Array = _queue.pop_front()
		_load_one(item[0], item[1])
		budget -= 1
	return _queue.size()


func load_legacy_now() -> void:
	queue_legacy()
	pump(1 << 20)


func load_pack_now(pack: String) -> void:
	queue_pack(pack)
	pump(1 << 20)


## Drop a pack's clips (clips another loaded pack still owns stay).
func release_pack(pack: String) -> void:
	if not _packs.erase(pack):
		return
	_queue = _queue.filter(func(it: Array) -> bool: return not (_owners.has(it[0]) and _owners[it[0]].size() == 1 and _owners[it[0]].has(pack)))
	for c in DmAudioPacks.pack_clips(pack):
		if _owners.has(c):
			_owners[c].erase(pack)
			if _owners[c].is_empty():
				_owners.erase(c)
				_streams.erase(c)


## A random loaded variant of a sound, never the same twice in a row when there is a choice. {} when none loaded.
func pick(sfx_name: String, rnd: float) -> Dictionary:
	var d := DmAudioMap.defn(sfx_name)
	if d.is_empty() or d["files"].size() == 0:
		return {}
	var have: Array = d["files"].filter(func(f: String) -> bool: return _streams.has(f))
	if have.is_empty():
		return {}
	var last: int = _last_pick.get(sfx_name, -1)
	var i := DmAudioMixer.pick_variant(have.size(), last, rnd)
	_last_pick[sfx_name] = i
	return {"stream": _streams[have[i]], "clip": have[i], "def": d}


func pick_layer(sfx_name: String, rnd: float) -> AudioStream:
	var d := DmAudioMap.defn(sfx_name)
	if not d.has("layer"):
		return null
	var files: Array = d["layer"]["files"].filter(func(f: String) -> bool: return _streams.has(f))
	if files.is_empty():
		return null
	return _streams[files[mini(files.size() - 1, int(floorf(rnd * float(files.size()))))]]


## A random loaded older clip for a sound that keeps one. {stream, spec} or {}.
func pick_legacy(sfx_name: String, rnd: float) -> Dictionary:
	if not LEGACY.has(sfx_name):
		return {}
	var spec: Dictionary = LEGACY[sfx_name]
	var have: Array = spec["files"].filter(func(f: String) -> bool: return _streams.has(f))
	if have.is_empty():
		return {}
	var key := "legacy:" + sfx_name
	var i := DmAudioMixer.pick_variant(have.size(), _last_pick.get(key, -1), rnd)
	_last_pick[key] = i
	return {"stream": _streams[have[i]], "spec": spec}
