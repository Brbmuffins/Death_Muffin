class_name DmCombatData
extends RefCounted
## Loader for godot/data/combat/*.json (originally exported from the web game's TS; now edited by hand).
## Every rules file in godot/rules/combat reads its tables through here so the JSON is parsed once.




## Parsed JSON for `name` (without extension). Numbers arrive as floats; integer-valued ones are fine for every formula here.
static func load_json(name: String) -> Variant:
	var v: Variant = DmDb.combat(name)
	if v == null:
		push_error("DmCombatData: cannot load combat/%s" % name)
		return {}
	return v


static func disciplines() -> Dictionary:
	return load_json("disciplines")


static func abilities() -> Dictionary:
	return load_json("abilities")


## abilities.json -> constants (BONE_FAN, FRACTURE, WITHERED, SOUL_HARVEST ...)
static func const_table(name: String) -> Variant:
	return (load_json("abilities") as Dictionary)["constants"][name]


static func statuses() -> Dictionary:
	return load_json("statuses")


static func progression() -> Dictionary:
	return load_json("progression")


static func enemies() -> Dictionary:
	return load_json("enemies")


## JS truthiness for values that came out of JSON (null/0/false/"" are falsy).
static func truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is float or v is int:
		return v != 0 and not is_nan(float(v))
	if v is String:
		return v != ""
	return true


## `a ?? b`
static func nn(a: Variant, b: Variant) -> Variant:
	return b if a == null else a
