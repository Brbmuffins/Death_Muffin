class_name DmPotionBelt
extends RefCounted
## Port of the pure parts of src/gameplay/beltRules.ts: the HUD potion belt (Q heal + two brew slots). Not the tool belt
## (that is DmGathering.BELT_*). Hint strings are UI copy owned by the ui track; only the rules are ported.

const SLOT_IDS: Array = ["heal", "elixir", "tonic"]
const HEAL_ORDER: Array = ["flask_hp_grand", "flask_hp_major", "flask_hp_minor"]
const HEAL_COOLDOWN_S := 1.5


## The flask Q drinks now: first of HEAL_ORDER the bag holds ("" = none). count = Callable(item_id) -> int.
static func heal_pick(count: Callable) -> String:
	for id in HEAL_ORDER:
		if int(count.call(id)) > 0:
			return id
	return ""


## "empty" | "ready" | "active" | "cooling".
static func belt_state(has_item: bool, active: bool = false, cooling: bool = false) -> String:
	if active:
		return "active"
	if cooling and has_item:
		return "cooling"
	return "ready" if has_item else "empty"
