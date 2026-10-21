class_name DmQaTune
extends RefCounted
## Data overrides for one QA run: `--tune=<abs json file>` (client/main/CLIPS.md). The boot (`DmMain._ready`) applies it where the QA tools start, before the game scene is built, so the
## combat rules, the combat core and every view read the tuned numbers: it is merged into the registry's own cache (`DmDb.raw`), and the core's tables (`DmCoreData`) come from that cache too.
## The file is {"<DmDb path, e.g. combat/abilities>": {<nested keys exactly as the data file has them>: <value>}}, e.g.
##   {"combat/abilities": {"abilities": {"haunting_wraith": {"speed": 5.5}}}}
## Only keys that exist can be set, to a value of the type the data has (number, text or true/false): an unknown file, an unknown key, a wrong type, a list or a null is REFUSED (the boot prints
## the line and exits with code 2) so a typo can never silently change nothing, and nothing at all is applied from a refused file. Every change prints a line:
##   QA tune: combat/abilities.abilities.haunting_wraith.speed = 5.5
## The caches the registry derives from its files (the loot and progression views, the composed progression table) are dropped so they are rebuilt from the tuned data.

const MAX_BYTES := 65536   ## the file's size
const MAX_VALUES := 100    ## values one tune may set
## Datasets the game does not take from the cache: the exact-sim world is parsed fresh on every use (`DmDb.sim_world`), so a change in the cache would reach nothing.
const FRESH := ["sim/world"]


## The tune file's text -> {ok, error, tune}: a JSON object of objects.
static func parse(text: String) -> Dictionary:
	var out := {"ok": false, "error": "", "tune": {}}
	var js := JSON.new()
	var raw: Variant = js.data if js.parse(text) == OK else null
	if not (raw is Dictionary):
		out["error"] = "the tune must be a JSON object: {\"<data file, e.g. combat/abilities>\": {<keys>: <value>}}"
		return out
	for rel in raw:
		if not (raw[rel] is Dictionary):
			out["error"] = "\"%s\" must be an object of the keys to change (not %s)" % [rel, _kind(raw[rel])]
			return out
	out["ok"] = true
	out["tune"] = raw
	return out


## Reads `path` (an absolute file) and applies it. Returns {ok, error, lines}: `lines` are the lines to print (one `QA tune: ...` per value set), `error` why it was refused.
static func apply_file(path: String) -> Dictionary:
	if not path.is_absolute_path():
		return _refused("the tune file must be an absolute path (%s)" % path)
	if not FileAccess.file_exists(path):
		return _refused("no tune file %s" % path)
	var text := FileAccess.get_file_as_string(path)
	if text.length() > MAX_BYTES:
		return _refused("the tune file is too big (more than %d bytes)" % MAX_BYTES)
	var parsed := parse(text)
	if not parsed["ok"]:
		return _refused(String(parsed["error"]))
	return apply(parsed["tune"])


## Checks every value against the data first, then sets them all, or none. {ok, error, lines}.
static func apply(tune: Dictionary) -> Dictionary:
	var changes: Array[Dictionary] = []
	var why := plan(tune, changes)
	if why != "":
		return _refused(why)
	var lines: Array[String] = []
	for c in changes:
		var node: Dictionary = DmDb.raw(String(c["rel"]))
		var keys: Array = c["keys"]
		for i in keys.size() - 1:
			node = node[keys[i]]
		node[keys[keys.size() - 1]] = c["value"]
		lines.append("QA tune: %s = %s" % [c["path"], fmt(c["value"])])
	if lines.is_empty():
		lines.append("QA tune: (nothing to change)")
	else:
		_drop_derived()
	return {"ok": true, "error": "", "lines": lines}


## Walks the tune against the loaded data and lists what it would set into `changes` ({rel, keys, path, value}). "" = all of it is valid, else the first problem in plain words.
static func plan(tune: Dictionary, changes: Array[Dictionary]) -> String:
	var files := DmDb.all_files()
	for rel in tune:
		if not files.has(rel):
			return "unknown data file \"%s\" (%s)" % [rel, _near_files(String(rel), files)]
		if FRESH.has(rel):
			return "\"%s\" is read fresh by the game, so a tune cannot reach it" % rel
		var data: Variant = DmDb.raw(String(rel))
		if not (data is Dictionary):
			return "\"%s\" is not an object of keys" % rel
		var why := _walk(data, tune[rel], String(rel), String(rel), [], changes)
		if why != "":
			return why
	return ""


static func _walk(node: Dictionary, over: Dictionary, rel: String, trail: String, keys: Array, changes: Array[Dictionary]) -> String:
	for k in over:
		var key := String(k)
		var here := "%s.%s" % [trail, key]
		if not node.has(key):
			return "%s is not a key of %s (it has: %s)" % [here, trail, _some_keys(node)]
		var want: Variant = over[k]
		var have: Variant = node[key]
		if want is Dictionary:
			if not (have is Dictionary):
				return "%s is %s, not an object of keys" % [here, _kind(have)]
			var why := _walk(have, want, rel, here, keys + [key], changes)
			if why != "":
				return why
			continue
		if not (want is float or want is int or want is String or want is bool):
			return "%s: a tune value is a number, text or true/false, not %s" % [here, _kind(want)]
		if (want is float and not is_finite(want)):
			return "%s: the number is not finite" % here
		if have is Dictionary or have is Array:
			return "%s is %s: name the key inside it that changes" % [here, _kind(have)]
		if have != null and _kind(have) != _kind(want):
			return "%s is %s, the tune gives %s" % [here, _kind(have), _kind(want)]
		if changes.size() >= MAX_VALUES:
			return "more than %d values in one tune" % MAX_VALUES
		changes.append({"rel": rel, "keys": keys + [key], "path": here, "value": want})
	return ""


## A value as the tune line shows it: whole numbers without ".0", text in quotes.
static func fmt(v: Variant) -> String:
	if v is float or v is int:
		return str(int(v)) if is_equal_approx(float(v), roundf(float(v))) and absf(float(v)) < 1e15 else String.num(float(v))
	if v is String:
		return JSON.stringify(v)
	return str(v)


## What a value is, in the words of the refusals: numbers (int or float) are one kind.
static func _kind(v: Variant) -> String:
	if v is float or v is int:
		return "a number"
	if v is String or v is StringName:
		return "text"
	if v is bool:
		return "true/false"
	if v is Dictionary:
		return "an object"
	if v is Array:
		return "a list"
	return "empty"


static func _some_keys(node: Dictionary) -> String:
	var names: Array[String] = []
	for k in node:
		names.append(String(k))
		if names.size() == 14:
			names.append("...")
			break
	return ", ".join(names)


## The files of the data file's domain ("combat/abilties" -> the combat ones), else the domains.
static func _near_files(rel: String, files: PackedStringArray) -> String:
	var domain := rel.get_base_dir() if rel.contains("/") else rel
	var same: Array[String] = []
	var domains := {}
	for f in files:
		domains[f.get_base_dir()] = true
		if f.get_base_dir() == domain:
			same.append(f)
	if not same.is_empty() and same.size() <= 40:
		return "the %s files are: %s" % [domain, ", ".join(same)]
	return "a data file is <domain>/<name> under client/data, the domains are: %s" % ", ".join(PackedStringArray(domains.keys()))


## The registry's derived caches (the loot and progression views, the composed progression table: anything cached that is not a dataset's own file) are rebuilt from the tuned data on first use.
static func _drop_derived() -> void:
	var files := DmDb.all_files()
	for k in DmDb._cache.keys():
		if not files.has(k):
			DmDb._cache.erase(k)
	DmAbilities._unlock_memo = {}


static func _refused(why: String) -> Dictionary:
	return {"ok": false, "error": why, "lines": ["QA tune refused: " + why]}
