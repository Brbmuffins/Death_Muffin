class_name DmHudReveal
extends RefCounted
## Port of src/ui/progressiveHud.ts: HudReveal (what the HUD has revealed / flagged NEW, per character), veteran_reveals, CueQueue.
## Storage = anything with get_item/set_item (DmCounselStore); key dm_hud_reveal_v1_<id>.

var _revealed: Dictionary = {}
var _unseen: Dictionary = {}
var _told: Dictionary = {}
var fresh := true
var _key := ""
var _store: Object


static func storage_key(character_id: int) -> String:
	return "dm_hud_reveal_v1_%d" % character_id


func _init(character_id: int = 0, store: Object = null) -> void:
	_key = storage_key(character_id)
	_store = store
	if _store == null:
		return
	var raw := str(_store.get_item(_key))
	if raw == "":
		return
	var s: Variant = JSON.parse_string(raw)
	if s is Dictionary:
		for pair in [["r", _revealed], ["u", _unseen], ["t", _told]]:
			var l: Variant = s.get(pair[0])
			if l is Array:
				for id in l:
					if id is String:
						pair[1][id] = true
		fresh = false


func has(id: String) -> bool:
	return _revealed.has(id)


func is_new(id: String) -> bool:
	return _unseen.has(id)


## Reveal for good; true the first time. `announce` also flags it new.
func reveal(id: String, announce: bool = true) -> bool:
	if _revealed.has(id):
		return false
	_revealed[id] = true
	if announce:
		_flag_new(id)
	_save()
	return true


## Flag new without revealing; true only the first time ever.
func flag(id: String) -> bool:
	if _told.has(id):
		return false
	_flag_new(id)
	_save()
	return true


func _flag_new(id: String) -> void:
	if _told.has(id):
		return
	_told[id] = true
	_unseen[id] = true


func clear(id: String) -> bool:
	if not _unseen.erase(id):
		return false
	_save()
	return true


func new_ids() -> Array:
	return _unseen.keys()


func revealed_ids() -> Array:
	return _revealed.keys()


func _save() -> void:
	if _store != null:
		_store.set_item(_key, JSON.stringify({"r": _revealed.keys(), "u": _unseen.keys(), "t": _told.keys()}))


## f: {level, gold, damage_tier, wave_owned, shards, knows_acre, swap_ready, has_gear, has_hunted}
static func veteran_reveals(f: Dictionary) -> Array:
	var out: Array = []
	if int(f.get("level", 1)) >= 2 or int(f.get("gold", 0)) > 0 or int(f.get("damage_tier", 0)) > 0 or int(f.get("wave_owned", 0)) > 0:
		out.append("hud.upgrades")
	if int(f.get("wave_owned", 0)) > 0:
		out.append("hud.dial")
	if int(f.get("shards", 0)) > 0:
		out.append("hud.shards")
	if f.get("swap_ready", false):
		out.append_array(["hud.spells", "menu.spells"])
	if f.get("has_gear", false):
		out.append("menu.atlas")
	if f.get("knows_acre", false) or int(f.get("level", 1)) >= 3:
		out.append("menu.skills")
	if f.get("has_hunted", false):
		out.append("hud.omen")
	return out


static func is_veteran(level: int) -> bool:
	return level >= 3


## CueQueue: one NEW toast at a time, each held `hold_ms`. Driven by tick(delta_s) (no timers).
class CueQueue:
	extends RefCounted
	var show_cb: Callable
	var blocked: Callable = Callable()
	var hold_ms := 6500.0
	var _queue: Array = []
	var _wait := 0.0
	var _busy := false

	func push(key: String, text: String) -> void:
		for q in _queue:
			if q["key"] == key:
				return
		_queue.append({"key": key, "text": text})
		_pump()

	func drop(key: String) -> void:
		_queue = _queue.filter(func(q: Dictionary) -> bool: return q["key"] != key)

	func pending() -> int:
		return _queue.size()

	func tick(delta_s: float) -> void:
		if not _busy:
			return
		_wait -= delta_s * 1000.0
		if _wait <= 0.0:
			_busy = false
			_pump()

	func _pump() -> void:
		if _busy or _queue.is_empty():
			return
		if blocked.is_valid() and blocked.call():
			_busy = true
			_wait = 2000.0
			return
		var nxt: Dictionary = _queue.pop_front()
		_busy = true
		_wait = hold_ms
		show_cb.call(nxt["text"], nxt["key"])
