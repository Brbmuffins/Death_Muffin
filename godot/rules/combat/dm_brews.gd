class_name DmBrews
extends RefCounted
## Port of the numeric half of src/content/brews.ts + healing flasks / meals / heal cooldown. Brews state is
## {elixir: {id, until}|null, tonic: {id, until}|null}; `now` and `until` are scene milliseconds.

const SLOTS: Array[String] = ["elixir", "tonic"]


static func _d() -> Dictionary:
	return DmCombatData.load_json("brews")


static func empty_brews() -> Dictionary:
	return {"elixir": null, "tonic": null}


## Sum of one effect kind across the active (unexpired) brews.
static func brew_value(brews: Dictionary, kind: String, now: float) -> float:
	var sum := 0.0
	var defs: Dictionary = _d()["brews"]
	for slot in SLOTS:
		var a: Variant = brews.get(slot)
		if a == null or now >= float(a["until"]):
			continue
		var def: Variant = defs.get(a["id"])
		if def == null:
			continue
		for e: Dictionary in def["effects"]:
			if e["kind"] == kind:
				sum += float(e["value"])
	return sum


## The brew-derived damage reduction for one incoming blow (`from` = the hurt event's source).
static func brew_ward(brews: Dictionary, from: String, now: float) -> float:
	var w := brew_value(brews, "ward", now)
	if (_d()["fire_sources"] as Array).has(from):
		w += brew_value(brews, "resist_fire", now)
	if (_d()["rot_sources"] as Array).has(from):
		w += brew_value(brews, "resist_rot", now)
	return w


## Drink a brew (mutates `brews`): a different brew in the slot is replaced, the same one extended (capped).
## Returns {replaced: id|null, extended: bool, until}.
static func apply_brew(brews: Dictionary, id: String, now: float) -> Dictionary:
	var d := _d()
	var def: Dictionary = d["brews"][id]
	var slot: String = def["slot"]
	var cur: Variant = brews.get(slot)
	var live: Variant = cur if (cur != null and now < float(cur["until"])) else null
	var ms: float = float(def["seconds"]) * 1000.0
	if live != null and live["id"] == id:
		var until := minf(float(live["until"]) + ms, now + ms * float(d["extend_cap"]))
		brews[slot] = {"id": id, "until": until}
		return {"replaced": null, "extended": true, "until": until}
	brews[slot] = {"id": id, "until": now + ms}
	return {"replaced": live["id"] if live != null else null, "extended": false, "until": now + ms}


## Heal from lifesteal for one hit intent: % of damage over at most LIFESTEAL_TARGET_CAP targets, capped per hit.
static func lifesteal_heal(dmg: float, targets: float, frac: float, max_hp: float) -> float:
	if frac <= 0.0 or dmg <= 0.0 or targets <= 0.0:
		return 0.0
	var d := _d()
	return minf(dmg * minf(targets, float(d["lifesteal_target_cap"])) * frac, max_hp * float(d["lifesteal_hit_cap"]))


## Healing flask: fraction of max HP restored (0 if not a flask).
static func flask_heal_frac(item_id: String) -> float:
	return float(_d()["healing_flasks"].get(item_id, 0.0))


## Amount a healing flask restores (maxHp x fraction); the Dry Cellar vow forbids flasks (-1 = refused).
static func flask_heal_amount(item_id: String, max_hp: float, vow_fx: Dictionary) -> float:
	if vow_fx.get("noFlasks", false):
		return -1.0
	return max_hp * flask_heal_frac(item_id)


static func heal_cooldown_ms() -> float:
	return float(_d()["heal_cooldown_s"]) * 1000.0


## Meals: heal-over-time {healFrac, seconds}.
static func meal(item_id: String) -> Variant:
	return _d()["meals"].get(item_id)


## BUFF_FLASKS entry for a brew id: {kind, value, seconds, label} from its first effect.
static func buff_flask(id: String) -> Variant:
	var def: Variant = _d()["brews"].get(id)
	if def == null:
		return null
	var e: Dictionary = def["effects"][0]
	return {"kind": e["kind"], "value": e["value"], "seconds": def["seconds"], "label": def["label"]}
