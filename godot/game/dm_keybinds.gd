class_name DmKeybinds
extends RefCounted
## Port of src/gameplay/keybinds.ts: rebindable loadout hotkeys (all unbound by default), a per-machine key preference.
## A key the game already uses cannot be bound. Keys are lowercase names as DmGameInput.key_name() returns them.

const FILE := "user://dm_keybinds_v1.json"
const MAX_PRESETS := 6
const ACTION_LABEL := {"loadout_next": "Next loadout", "loadout_1": "Loadout 1", "loadout_2": "Loadout 2", "loadout_3": "Loadout 3", "loadout_4": "Loadout 4", "loadout_5": "Loadout 5", "loadout_6": "Loadout 6"}
const NOT_A_KEY := ["shift", "control", "alt", "meta", "altgraph", "capslock", "tab", "dead", "unidentified", "contextmenu", "os", "fn"]


static func loadout_actions() -> Array:
	var out: Array = ["loadout_next"]
	for i in MAX_PRESETS:
		out.append("loadout_%d" % (i + 1))
	return out


static func reserved() -> Dictionary:
	var keys: Dictionary = DmContent.get_export("brews", "BREW_KEYS")
	return {
		"1": "rite slot 1", "2": "rite slot 2", "3": "rite slot 3", "4": "rite slot 4", "5": "rite slot 5", "6": "the signature rite",
		"r": "the signature rite", "q": "the healing flask", "t": "Recall", "i": "the Reliquary", "b": "the Reliquary", "j": "the character sheet", "y": "the Legion",
		"c": "the Workbench", "p": "Skills", "o": "Contracts", "u": "the Garden", "h": "the Laborers", "n": "Capes and Pets", "v": "the Vault", "m": "the Waystones",
		"k": "the Codex", ".": "the Gear Atlas", "l": "the Grimoire", "g": "auto combat", "e": "talking to someone nearby", "escape": "Settings and closing panels",
		"enter": "chat", "w": "walking", "a": "walking", "s": "walking", "d": "walking", "arrowup": "walking", "arrowdown": "walking", "arrowleft": "walking", "arrowright": "walking",
		" ": "the game", String(keys["elixir"]): "the elixir on your belt", String(keys["tonic"]): "the tonic on your belt",
	}


## {ok: bool, key?: String, error?: String}
static func check_bind(binds: Dictionary, action: String, raw_key: String) -> Dictionary:
	var key := raw_key.to_lower()
	var fkey := RegEx.create_from_string("^f([1-9]|1[0-2])$")
	var navkey := RegEx.create_from_string("^(arrow|page|home|end|insert|delete|backspace)")
	if key in NOT_A_KEY or key.length() == 0 or (key.length() > 1 and fkey.search(key) == null and navkey.search(key) == null):
		return {"ok": false, "error": "That key cannot be used. Pick a letter, number or function key."}
	var res := reserved()
	if res.has(key):
		return {"ok": false, "error": "%s is already used for %s. Pick another key." % [label(key), res[key]]}
	for a in loadout_actions():
		if a != action and binds.get(a, "") == key:
			return {"ok": false, "error": "%s is already %s. Clear that one first." % [label(key), ACTION_LABEL[a]]}
	return {"ok": true, "key": key}


static func label(key: String) -> String:
	if key.length() == 1:
		return key.to_upper()
	if RegEx.create_from_string("^f\\d+$").search(key) != null:
		return key.to_upper()
	var s := key.replace("arrow", "Arrow ").replace("page", "Page ")
	return s.left(1).to_upper() + s.substr(1)


static func action_for_key(binds: Dictionary, raw_key: String) -> String:
	var key := raw_key.to_lower()
	for a in loadout_actions():
		if binds.get(a, "") == key:
			return a
	return ""


static func load_binds(path: String = FILE) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for a in loadout_actions():
		var k: Variant = raw.get(a)
		if k is String and check_bind(out, a, k)["ok"]:
			out[a] = String(k).to_lower()
	return out


static func save_binds(binds: Dictionary, path: String = FILE) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(binds))


## Which saved slot a "next loadout" press applies (-1 = none).
static func next_slot(saved: Array, active_slot: int, last_used: int) -> int:
	if saved.is_empty():
		return -1
	var from := active_slot if active_slot >= 0 else last_used
	if from < 0:
		return int(saved[0])
	for s in saved:
		if int(s) > from:
			return int(s)
	return int(saved[0])
