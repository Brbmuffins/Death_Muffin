class_name DmGoldSink
extends RefCounted
## Port of the pure parts of src/gameplay/goldSinkRules.ts: Reforge pricing/validation/roll, and the Empowered-summon constants
## and formulas. Server-authoritative (reforge.cjs / boss-key.cjs roll and charge).
##
## Dependencies injected as Callables (they belong to the loot track's affix rules):
##   affix_range: Callable(affix_id: String, ilvl: int) -> Array[2] ([lo, hi]) or null
## NOT ported here (they need boss/area/legendary tables owned by other tracks): rollEmpoweredPrize, rollEmpoweredInstance,
## empoweredLegendaryChance. Use empower_gold / empowered_level with the boss's `shards` and level.

const M := preload("res://rules/core/math.gd")

const REFORGE := {
	"goldPerIlvl": 40,
	"growth": 1.25,
	"maxSteps": 20,
	"cap": 2000000,
	"rarityMult": {"common": 1.0, "uncommon": 1.0, "rare": 1.5, "epic": 2.5, "legendary": 4.0, "relic": 4.0},
}

const RARITY_RANK: Array = ["common", "uncommon", "rare", "epic", "legendary", "relic"]

const COVENANT_SEAL := "covenant_seal"
const EMPOWER := {
	"goldPerShardSq": 7500,
	"levelsFlat": 6,
	"levelsShare": 0.15,
	"hpMult": 1.4,
	"legendaryMult": 2.5,
	"legendaryCap": 0.6,
	"claimWindowMs": 3 * 60 * 60 * 1000,
	"refundWindowMs": 2 * 60 * 1000,
	"prizeAffixes": 3,
}
const EMPOWERABLE: Array = ["gravedigger", "abbess", "congregation", "saint", "regent", "mire"]


## affixRules.effectiveRarity: the affix count lifts the shown rarity (1 uncommon, 2 rare, 3 epic); a base never loses rarity.
static func effective_rarity(base_rarity: String, affix_count: int) -> String:
	var floor_r: String = RARITY_RANK[maxi(0, mini(3, affix_count))]
	return floor_r if RARITY_RANK.find(floor_r) > RARITY_RANK.find(base_rarity) else base_rarity


static func reforge_cost(ilvl: float, base_rarity: String, affix_count: int, rerolls: Variant) -> int:
	var shown := effective_rarity(base_rarity, affix_count)
	var mult: float = float(REFORGE["rarityMult"].get(shown, 1.0))
	var step := 0
	if rerolls is int or rerolls is float:
		step = maxi(0, mini(int(REFORGE["maxSteps"]), int(floor(float(rerolls)))))
	var raw: float = float(REFORGE["goldPerIlvl"]) * float(maxi(1, int(floor(ilvl)))) * mult * pow(float(REFORGE["growth"]), step)
	return mini(int(REFORGE["cap"]), maxi(1, M.js_round(raw)))


## Why this affix cannot be reforged ("" = fine). inst = {ilvl, affixes:[{id, v}]}.
static func reforge_problem(inst: Dictionary, index: int, affix_range: Callable) -> String:
	var affixes: Array = inst["affixes"]
	if index < 0 or index >= affixes.size():
		return "Choose one of the affixes."
	var a: Dictionary = affixes[index]
	var r: Variant = affix_range.call(a["id"], inst["ilvl"])
	if r == null:
		return "That affix cannot be reforged."
	if int(r[0]) == int(r[1]):
		return "That affix has only one possible value."
	if float(a["v"]) >= float(r[1]):
		return "That roll is already as high as this item level allows."
	return ""


## A fresh value for the affix: uniform over today's range. `rand` returns [0,1).
static func reforge_value(affix_id: String, ilvl: int, rand: Callable, affix_range: Callable) -> int:
	var r: Variant = affix_range.call(affix_id, ilvl)
	if r == null:
		push_error("unknown affix " + affix_id)
		return 0
	var lo := int(r[0])
	var hi := int(r[1])
	return lo + mini(hi - lo, int(floor(float(rand.call()) * float(hi - lo + 1))))


static func can_empower(boss: String) -> bool:
	return EMPOWERABLE.has(boss)


## Gold for an Empowered summon from the boss's shard count (BOSSES[boss].shards).
static func empower_gold(shards: int) -> int:
	return int(EMPOWER["goldPerShardSq"]) * shards * shards


## The level an Empowered boss fights at.
static func empowered_level(level: int) -> int:
	return M.js_round(float(level) + float(EMPOWER["levelsFlat"]) + float(level) * float(EMPOWER["levelsShare"]))
