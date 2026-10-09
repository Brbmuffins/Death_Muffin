class_name DmSettings
extends RefCounted
## Port of archive/legacy-web:src/app/settings.ts: the per-viewer settings store, persisted to a JSON file (the desktop stand-in for localStorage). Difficulty and
## auto combat are per character (setActiveCharacter). Keys are the Settings panel's (godot/ui/panels/dm_settings_panel.gd `values`), with the
## web's defaults: difficulty, auto_combat, auto_gather, loot_<tier> ("ground"|"auto"|"gold"), graphics ("low"|"medium"|"high"|"ultra", DmGraphicsPreset), brightness (0.8..1.3), fps, auto_res, vol_master,
## vol_combat, vol_amb, vol_music, vol_ui (= web volume, combatVolume, ambienceVolume, musicVolume, interfaceVolume), reduce_motion, damage_numbers,
## hide_helm, no_tips, guidance, guide_ping, dev_access.

signal changed(values: Dictionary)

const FILE := "user://dm_settings_v2.json"
const PLAY_FILE := "user://dm_play_settings_v1_%d.json"
## Settings -> Brightness: a tonemap-exposure multiplier on the world (1.0 = the shipped look).
const BRIGHTNESS_MIN := 0.8
const BRIGHTNESS_MAX := 1.3
const VOLUME_KEYS: Array[String] = ["vol_master", "vol_combat", "vol_amb", "vol_music", "vol_ui"]
const WEB_VOLUME := {"vol_master": "volume", "vol_combat": "combatVolume", "vol_amb": "ambienceVolume", "vol_music": "musicVolume", "vol_ui": "interfaceVolume"}
const TIERS := ["common", "uncommon", "rare", "epic", "legendary"]

var values: Dictionary = {}
var path: String = FILE
var character_id: int = -1
var auto_combat_allowed: bool = false
## false in tests: nothing is written to disk.
var persist: bool = true


static func defaults() -> Dictionary:
	var d := {
		"difficulty": "medium", "auto_combat": false, "auto_gather": true,
		"graphics": "high", "fps": 0, "graphics_chosen": false, "auto_res": true, "brightness": 1.0, "ui_scale": 1.0, "hud_scale": 1.0,
		"vol_master": 0.6, "vol_combat": 1.0, "vol_amb": 1.0, "vol_music": 0.85, "vol_ui": 1.0,
		"reduce_motion": false, "damage_numbers": true, "hide_helm": false, "no_tips": false, "guidance": true, "guide_ping": true, "dev_access": true,
	}
	for t in TIERS:
		d["loot_" + t] = "ground"
	return d


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
	values["graphics"] = DmGraphicsPreset.normalize(values["graphics"])   # the old "high"/"low" are presets; anything else is High
	if not values["graphics_chosen"]:
		values["fps"] = 0
	values["auto_res"] = values["auto_res"] != false
	var br: Variant = values["brightness"]
	values["brightness"] = clampf(float(br), BRIGHTNESS_MIN, BRIGHTNESS_MAX) if typeof(br) in [TYPE_INT, TYPE_FLOAT] else 1.0
	values["ui_scale"] = clamp_ui_scale(values["ui_scale"])
	values["hud_scale"] = clamp_hud_scale(values["hud_scale"])
	# Old settings cannot be attributed to a character: each starts on Medium until its own preference loads.
	values["difficulty"] = "medium"
	values["auto_combat"] = false
	var rules := {}
	for t in TIERS:
		rules[t] = values["loot_" + t]
	var clean := DmLootFilter.read_loot_rules(rules)
	for t in TIERS:
		values["loot_" + t] = clean[t]


## Settings -> Interface size: 80..125 %, snapped to the offered steps; anything else is 100 %.
static func clamp_ui_scale(v: Variant) -> float:
	if typeof(v) not in [TYPE_INT, TYPE_FLOAT]:
		return 1.0
	return clampf(snappedf(float(v), 0.05), 0.8, 1.25)


## Settings -> HUD size: 75..130 %, snapped to 5 %; anything else is 100 %. Scales only the in-world HUD (DmHud.set_hud_scale), on top of Interface size.
static func clamp_hud_scale(v: Variant) -> float:
	if typeof(v) not in [TYPE_INT, TYPE_FLOAT]:
		return 1.0
	return clampf(snappedf(float(v), 0.05), 0.75, 1.3)


func can_use_auto_combat() -> bool:
	return auto_combat_allowed


## Settings -> Loot as the loot-rule Dictionary {tier: action} (DmLootFilter shape).
func loot_rules() -> Dictionary:
	var out := {}
	for t in TIERS:
		out[t] = values["loot_" + t]
	return DmLootFilter.read_loot_rules(out)


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
			auto = saved.get("auto_combat", false) == true
	values["difficulty"] = difficulty
	values["auto_combat"] = allowed and difficulty == "easy" and auto
	changed.emit(values)


func update(patch: Dictionary) -> void:
	patch = patch.duplicate()
	if patch.has("difficulty") and not patch.has("auto_combat"):
		patch["auto_combat"] = auto_combat_allowed and patch["difficulty"] == "easy"
	var diff: String = str(patch.get("difficulty", values["difficulty"]))
	if not auto_combat_allowed or diff != "easy":
		patch["auto_combat"] = false
	if patch.has("graphics") or patch.has("fps"):
		patch["graphics_chosen"] = true
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
			g.store_string(JSON.stringify({"difficulty": values["difficulty"], "auto_combat": values["auto_combat"]}))


## The AudioDirector keys (it accepts the panel's vol_* keys directly).
func audio_dict() -> Dictionary:
	var d := {}
	for k in VOLUME_KEYS:
		d[k] = values[k]
	return d
