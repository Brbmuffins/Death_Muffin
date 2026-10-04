class_name DmCounselStore
extends RefCounted
## Tiny string key/value store behind the counsel (the web's localStorage: `dm_tips_v1_<characterId>` = JSON array of seen tip ids,
## `dm_counsel_position_v1` = {x, y}). In-memory by default (tests); give it a `path` and it also persists as one JSON file (the game uses
## user://dm_counsel.json). Reads/writes never throw: a broken file just means the tips show again, like the web.

var _mem: Dictionary = {}
var path: String = ""


func _init(p: String = "") -> void:
	path = p
	if path != "" and FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var d: Variant = JSON.parse_string(f.get_as_text())
			if d is Dictionary:
				_mem = d


func get_item(key: String) -> String:
	return String(_mem.get(key, ""))


func has_item(key: String) -> bool:
	return _mem.has(key)


func set_item(key: String, value: String) -> void:
	_mem[key] = value
	if path != "":
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(_mem))
