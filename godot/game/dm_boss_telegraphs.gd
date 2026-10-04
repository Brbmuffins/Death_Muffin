class_name DmBossTelegraphs
extends RefCounted
## Port of `BossTelegraphs` (src/gameplay/autoDodge.ts): the scene's record of live boss telegraphs, fed from the same events that draw them.
## Hazards are the Dictionaries of dm_auto_dodge.gd; boss events are Dictionaries with the TS keys (kind, boss, x, z, ms, r, dir, targets).

var _list: Array = []


static func _src(ev: Dictionary) -> String:
	var b: Variant = ev.get("boss")
	return "%s:%s:%s:%s" % [str(b if b != null else "prelate"), str(ev.get("kind", "")), str(DmMath.js_round(float(ev.get("x", 0.0)) * 10.0)), str(DmMath.js_round(float(ev.get("z", 0.0)) * 10.0))]


func on_event(ev: Dictionary, now: float) -> void:
	var kind: String = ev.get("kind", "")
	if kind == "defeated" or kind == "awaken":
		_list = []
		return
	var ms: Variant = ev.get("ms")
	if (ms != null and float(ms) > 0.0) or kind == "pits":
		_list.append_array(DmAutoDodge.hazards_from_boss_event(ev, now))
		return
	# The blow landed: forget the telegraph it came from (one per matching kind and centre; a second sweep at another angle stays).
	var src := _src(ev)
	var dir: Variant = ev.get("dir")
	var at := -1
	for i in _list.size():
		var h: Dictionary = _list[i]
		if h.get("src") == src and (dir == null or h.get("dir0") == null or absf(DmAutoDodge.angle_diff(float(h["dir0"]), float(dir))) < 1e-6):
			at = i
			break
	if at < 0:
		return
	var dir0: Variant = (_list[at] as Dictionary).get("dir0")
	var kept: Array = []
	for h in _list:
		if not (h.get("src") == src and h.get("dir0") == dir0):
			kept.append(h)
	_list = kept


## What is live now (expired shapes dropped). The array is reused between calls: do not keep it.
func active(now: float) -> Array:
	var any_expired := false
	for h in _list:
		if float(h["until"]) < now:
			any_expired = true
			break
	if any_expired:
		var kept: Array = []
		for h in _list:
			if float(h["until"]) >= now:
				kept.append(h)
		_list = kept
	return _list


func clear() -> void:
	_list = []
