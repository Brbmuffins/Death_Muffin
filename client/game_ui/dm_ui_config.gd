class_name DmUiConfig
extends RefCounted
## Where the UI keeps its per-device conveniences (the web's localStorage): one JSON key/value file shared by counsel, reveal cues, locks, belt,
## loadout rites and keybinds. Tests set `dir` to "" for in-memory stores.

static var dir := "user://"


static func store_path() -> String:
	return "" if dir == "" else dir + "dm_ui.json"


static func guidance_path(character_id: int) -> String:
	return "" if dir == "" else dir + "dm_guidance_%d.json" % character_id


static func parse(text: Variant) -> Variant:
	var t := str(text)
	return null if t == "" else JSON.parse_string(t)
