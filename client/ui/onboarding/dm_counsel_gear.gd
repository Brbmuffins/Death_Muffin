class_name DmCounselGear
extends RefCounted
## The counsel's two gear moments, read from the bag after each change (DmGameUi._on_inventory_changed; WorldScene.refreshStats in the web game):
## the worn main-hand weapon line changed (`necro_weapon_changed {main, was_main}`, DmCounselEvents) and an armor set bonus switched on (`set_bonus_gained {gained}`).
## The first bag it sees is only remembered: a hero who logs in wearing a Scythe or a set is not told about it, only about a change from then on.
## Cheap by design: the worn rows are keyed first and nothing is resolved while they are the same as last time (a pickup or a sale never touches the worn rows).

var _known := false
var _worn := ""
var _main := ""
var _bonuses := PackedStringArray()


## The counsel events this bag makes: [[event_id, ctx], ...] (none the first time). `discipline_id`: the hero's discipline (only a necromancer's weapons make a line).
func observe(slots: Array, discipline_id: String) -> Array:
	var worn := DmGear.equipped_by_slot(slots)
	var key := _key_of(worn)
	if _known and key == _worn:
		return []
	var main := _main_line(worn, discipline_id)
	var bonuses := DmSetBonuses.set_signature(slots).split("|", false)
	var out: Array = []
	if _known:
		if main != _main:
			out.append(["necro_weapon_changed", {"main": main, "was_main": _main}])
		var gained := PackedStringArray()
		for b in bonuses:
			if not _bonuses.has(b):
				gained.append(b)
		if not gained.is_empty():
			out.append(["set_bonus_gained", {"gained": gained}])
	_known = true
	_worn = key
	_main = main
	_bonuses = bonuses
	return out


## The worn rows as one string: slot and item of each, in slot order.
static func _key_of(worn: Dictionary) -> String:
	var parts := PackedStringArray()
	for slot: String in worn:
		parts.append("%s=%s" % [slot, String((worn[slot] as Dictionary).get("item_id", ""))])
	parts.sort()
	return "|".join(parts)


## The kind of the worn main-hand weapon for this discipline ("scythe", "staff", "wand", "sickle"), "" for none or for a discipline without a weapon line.
static func _main_line(worn: Dictionary, discipline_id: String) -> String:
	var line: Dictionary = DmWeaponLine.resolve(worn, discipline_id)
	return "" if line["main"] == null else String(line["main"])
