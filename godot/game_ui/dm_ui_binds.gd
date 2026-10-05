class_name DmUiBinds
extends RefCounted
## Port of src/gameplay/keybinds.ts: the rebindable loadout hotkeys (unbound until chosen; a key the game already uses is refused).

const STORAGE_KEY := "dm_keybinds_v1"
const ACTIONS := ["loadout_next", "loadout_1", "loadout_2", "loadout_3", "loadout_4", "loadout_5", "loadout_6"]
const ACTION_LABEL := {"loadout_next": "Next loadout", "loadout_1": "Loadout 1", "loadout_2": "Loadout 2", "loadout_3": "Loadout 3", "loadout_4": "Loadout 4", "loadout_5": "Loadout 5", "loadout_6": "Loadout 6"}
const RESERVED := {
	"1": "rite slot 1", "2": "rite slot 2", "3": "rite slot 3", "4": "rite slot 4", "5": "rite slot 5", "6": "the signature rite", "r": "the signature rite",
	"q": "the healing flask", "t": "Recall", "i": "the Reliquary", "b": "the Reliquary", "j": "the character sheet", "y": "the Legion", "c": "the Workbench",
	"p": "Skills", "o": "Contracts", "u": "the Garden", "h": "the Laborers", "n": "Capes and Pets", "v": "the Vault", "m": "the Waystones", "k": "the Codex",
	".": "the Gear Atlas", "l": "the Grimoire", "g": "auto combat", "e": "talking to someone nearby", "escape": "Settings and closing panels", "enter": "chat",
	"w": "walking", "a": "walking", "s": "walking", "d": "walking", "arrowup": "walking", "arrowdown": "walking", "arrowleft": "walking", "arrowright": "walking",
	" ": "the game", "z": "the elixir on your belt", "x": "the tonic on your belt",
}
const NOT_A_KEY := ["shift", "control", "alt", "meta", "altgraph", "capslock", "tab", "dead", "unidentified", "contextmenu", "os", "fn"]


## A key event as the web's lowercase `KeyboardEvent.key`: "a", "f7", "arrowup", " ".
static func key_name(e: InputEventKey) -> String:
	var kc := e.keycode
	match kc:
		KEY_SHIFT: return "shift"
		KEY_CTRL: return "control"
		KEY_ALT: return "alt"
		KEY_META: return "meta"
		KEY_ESCAPE: return "escape"
		KEY_ENTER, KEY_KP_ENTER: return "enter"
		KEY_SPACE: return " "
		KEY_TAB: return "tab"
		KEY_UP: return "arrowup"
		KEY_DOWN: return "arrowdown"
		KEY_LEFT: return "arrowleft"
		KEY_RIGHT: return "arrowright"
		KEY_PAGEUP: return "pageup"
		KEY_PAGEDOWN: return "pagedown"
		KEY_HOME: return "home"
		KEY_END: return "end"
		KEY_INSERT: return "insert"
		KEY_DELETE: return "delete"
		KEY_BACKSPACE: return "backspace"
		KEY_CAPSLOCK: return "capslock"
	if kc >= KEY_F1 and kc <= KEY_F12:
		return "f%d" % (kc - KEY_F1 + 1)
	var s := OS.get_keycode_string(kc).to_lower()
	return s


static func label(key: String) -> String:
	if key.length() == 1:
		return key.to_upper()
	if key.length() <= 3 and key.begins_with("f") and key.substr(1).is_valid_int():
		return key.to_upper()
	var s := key.replace("arrow", "Arrow ").replace("page", "Page ")
	return s.substr(0, 1).to_upper() + s.substr(1)


## {"ok": true, "key"} or {"ok": false, "error"}.
static func check_bind(binds: Dictionary, action: String, raw_key: String) -> Dictionary:
	var key := raw_key.to_lower()
	var fkey := RegEx.create_from_string("^f([1-9]|1[0-2])$")
	var named := RegEx.create_from_string("^(arrow|page|home|end|insert|delete|backspace)")
	if NOT_A_KEY.has(key) or key.length() == 0 or (key.length() > 1 and fkey.search(key) == null and named.search(key) == null):
		return {"ok": false, "error": "That key cannot be used. Pick a letter, number or function key."}
	if key == "f5" or key == "f11" or key == "f12":
		return {"ok": false, "error": "%s is used by your browser. Pick another key." % label(key)}
	if RESERVED.has(key):
		return {"ok": false, "error": "%s is already used for %s. Pick another key." % [label(key), RESERVED[key]]}
	for a in ACTIONS:
		if a != action and binds.get(a, "") == key:
			return {"ok": false, "error": "%s is already %s. Clear that one first." % [label(key), ACTION_LABEL[a]]}
	return {"ok": true, "key": key}


static func load(store: Object) -> Dictionary:
	var out := {}
	if store == null:
		return out
	var raw: Variant = DmUiConfig.parse(store.get_item(STORAGE_KEY))
	if raw is Dictionary:
		for a in ACTIONS:
			var k: Variant = raw.get(a)
			if k is String and check_bind(out, a, k)["ok"]:
				out[a] = k.to_lower()
	return out


static func save(store: Object, binds: Dictionary) -> void:
	if store != null:
		store.set_item(STORAGE_KEY, JSON.stringify(binds))


static func action_for_key(binds: Dictionary, raw_key: String) -> String:
	var key := raw_key.to_lower()
	for a in ACTIONS:
		if binds.get(a, "") == key:
			return a
	return ""


## Which saved slot a "next loadout" press applies: after the active one (or the last used), wrapping; -1 = none saved.
static func next_slot(saved: Array, active: int, last_used: int) -> int:
	if saved.is_empty():
		return -1
	var from := active if active >= 0 else last_used
	if from < 0:
		return int(saved[0])
	for s in saved:
		if int(s) > from:
			return int(s)
	return int(saved[0])
