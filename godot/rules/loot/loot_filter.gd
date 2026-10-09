class_name DmLootFilter
extends RefCounted
## Port of archive/legacy-web:src/gameplay/lootFilter.ts: Settings -> Loot, one rule per gear rarity. 'ground' (walk over it), 'auto' (straight into the
## bag as it drops), 'gold' (sell value paid at once). Only gear follows the rules; set pieces, legendaries, a rolled necromancer affix and
## anything the `keep` callback protects are never turned into gold (a 'gold' rule leaves them on the ground).

const TIERS: Array[String] = ["common", "uncommon", "rare", "epic", "legendary"]
const ACTIONS: Array[String] = ["ground", "auto", "gold"]
const TIER_LABELS := {"common": "Common", "uncommon": "Uncommon", "rare": "Rare", "epic": "Epic", "legendary": "Legendary"}
const ACTION_LABELS := {"ground": "On the ground", "auto": "Auto-loot", "gold": "Sell for gold"}

static func default_rules() -> Dictionary:
	return {"common": "ground", "uncommon": "ground", "rare": "ground", "epic": "ground", "legendary": "ground"}

## Legendaries cannot be sold off by a rule.
static func actions_for(tier: String) -> Array:
	var out: Array = []
	for a in ACTIONS:
		if tier != "legendary" or a != "gold":
			out.append(a)
	return out

## Saved rules, cleaned; `legacy_filter` is the single "Loot filter" of the first release (tiers below it became gold).
static func read_loot_rules(saved: Variant, legacy_filter: Variant = null) -> Dictionary:
	var out := default_rules()
	var order: Array = ["common", "uncommon", "rare", "epic"]
	var cut := order.find(legacy_filter)
	if cut > 0:
		for t in order.slice(0, cut):
			out[t] = "gold"
	if saved is Dictionary:
		for id in TIERS:
			var a: Variant = saved.get(id)
			if actions_for(id).has(a):
				out[id] = a
	return out

## What happens to this freshly rolled drop (a slot row) under the player's rules. `keep(slot)->bool` is optional.
static func loot_action(slot: Dictionary, rules: Dictionary, keep: Callable = Callable()) -> String:
	if not DmAffixRules.is_affix_gear(str(slot.get("item_type", ""))):
		return "ground"
	var inst: Variant = slot.get("inst")
	var affixes: Array = inst["affixes"] if inst != null else []
	var r := DmAffixRules.effective_rarity(str(slot["rarity"]), affixes.size())
	var tier := "legendary" if r == "relic" else (r if TIERS.has(r) else "common")
	var action: String = rules[tier]
	if action != "gold":
		return action
	var protected_piece := tier == "legendary" or DmLootData.is_armor(str(slot["item_id"]))
	if not protected_piece:
		for a in affixes:
			if DmAffixRules.affix_is_necro(a):
				protected_piece = true
				break
	if not protected_piece and not keep.is_null():
		protected_piece = bool(keep.call(slot))
	return "ground" if protected_piece else "gold"
