class_name DmSettings
extends RefCounted
## Port of src/app/settings.ts: the per-viewer settings store (web keys, web defaults), persisted to a JSON file
## (the desktop stand-in for localStorage). Difficulty / auto-combat are per character (setActiveCharacter).
## `values` is the live Dictionary DmGame exposes as `settings`.

signal changed(values: Dictionary)

const FILE := "user://dm_settings_v1.json"
const PLAY_FILE := "user://dm_play_settings_v1_%d.json"
const VOLUME_KEYS: Array[String] = ["volume", "combatVolume", "ambienceVolume", "musicVolume", "interfaceVolume"]

var values: Dictionary = {}
var path: String = FILE
var character_id: int = -1
var auto_combat_allowed: bool = false
## false in tests: nothing is written to disk.
var persist: bool = true


static func defaults() -> Dictionary:
	return {
		"quality": "high", "fps": 0, "graphicsChosen": false, "autoResolution": true, "reducedMotion": false,
		"damageNumbers": true, "hideHelm": false, "volume": 0.6, "combatVolume": 1.0, "ambienceVolume": 1.0,
		"musicVolume": 0.85, "interfaceVolume": 1.0, "tips": true, "guidance": true, "guidancePing": true,
		"difficulty": "medium", "autoCombat": false, "autoGather": true, "lootRules": DmLootFilter.default_rules(),
	}


func _init(p: String = FILE, do_persist: bool = true) -> void:
	path = p
	persist = do_persist
	values = defaults()
	_load()


func _load() -> void:
	if not persist or not FileAccess.file_exists(path):
		return
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for k in raw:
		if values.has(k):
			values[k] = raw[k]
	for k in VOLUME_KEYS:
		var v: Variant = values[k]
		values[k] = clampf(float(v), 0.0, 1.0) if typeof(v) in [TYPE_INT, TYPE_FLOAT] else defaults()[k]
	values["graphicsChosen"] = values["graphicsChosen"] == true
	values["autoResolution"] = values["autoResolution"] != false
	if not values["graphicsChosen"]:
		values["fps"] = 0
	if not (str(values["difficulty"]) in ["easy", "medium", "hard"]):
		values["difficulty"] = "medium"
	values["lootRules"] = DmLootFilter.read_loot_rules(values["lootRules"], raw.get("lootFilter"))
	# Old settings cannot be attributed to a character: each starts on Medium until its own preference loads.
	values["difficulty"] = "medium"
	values["autoCombat"] = false


func can_use_auto_combat() -> bool:
	return auto_combat_allowed


## Called after the authenticated character response, before the world mounts (setActiveCharacter).
func set_active_character(id: int, allowed: bool = false) -> void:
	character_id = id
	auto_combat_allowed = allowed
	var difficulty := "medium"
	var auto := false
	var f := PLAY_FILE % id
	if persist and id >= 0 and FileAccess.file_exists(f):
		var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(f))
		if typeof(saved) == TYPE_DICTIONARY:
			if str(saved.get("difficulty", "")) in ["easy", "medium", "hard"]:
				difficulty = saved["difficulty"]
			auto = saved.get("autoCombat", false) == true
	values["difficulty"] = difficulty
	values["autoCombat"] = allowed and difficulty == "easy" and auto
	changed.emit(values)


func update(patch: Dictionary) -> void:
	patch = patch.duplicate()
	if patch.has("difficulty") and not patch.has("autoCombat"):
		patch["autoCombat"] = auto_combat_allowed and patch["difficulty"] == "easy"
	var diff: String = str(patch.get("difficulty", values["difficulty"]))
	if not auto_combat_allowed or diff != "easy":
		patch["autoCombat"] = false
	if patch.has("quality") or patch.has("fps"):
		patch["graphicsChosen"] = true
	for k in patch:
		values[k] = patch[k]
	_save()
	changed.emit(values)


func _save() -> void:
	if not persist:
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(values))
	if character_id >= 0:
		var g := FileAccess.open(PLAY_FILE % character_id, FileAccess.WRITE)
		if g:
			g.store_string(JSON.stringify({"difficulty": values["difficulty"], "autoCombat": values["autoCombat"]}))


## The AudioDirector / panel key map (web keys <-> the panel's vol_* keys).
func audio_dict() -> Dictionary:
	var d := {}
	for k in VOLUME_KEYS:
		d[k] = values[k]
	return d
