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


## Writes behind: the first change after a quiet spell goes to disk at once, later ones within WRITE_GAP_MS are saved together
## by one timer (the game's store is touched on every kill during a chain; a synchronous rewrite of the whole file each time was
## a per-kill disk stall). flush() saves now; owners call it on exit.
const WRITE_GAP_MS := 2000
var _dirty := false
var _timer_armed := false
var _last_write := -WRITE_GAP_MS


func set_item(key: String, value: String) -> void:
	if _mem.has(key) and String(_mem[key]) == value:
		return
	_mem[key] = value
	if path == "":
		return
	_dirty = true
	var now := Time.get_ticks_msec()
	if now - _last_write >= WRITE_GAP_MS:
		flush()
	elif not _timer_armed:
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null:
			flush()
			return
		_timer_armed = true
		tree.create_timer(float(WRITE_GAP_MS - (now - _last_write)) / 1000.0, true, false, true).timeout.connect(_on_timer)


func _on_timer() -> void:
	_timer_armed = false
	flush()


func flush() -> void:
	if not _dirty or path == "":
		return
	_dirty = false
	_last_write = Time.get_ticks_msec()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_mem))
