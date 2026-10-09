class_name DmWaveUpgrades
extends RefCounted
## Port of the numeric half of server/rules/content/upgrades.ts (Damage / Wave Speed / Legion tiers, waveModifiers) and the cost functions
## from necroRules.ts (damageCost, waveCost, legionCost). Costs take the owned tier(s) + boon ranks.

const DENSITY_FULL_TIERS := 3.0
const DENSITY_TAIL := 0.55


static func damage_cost_base(tier: float) -> float:
	return float(DmMath.js_round(40.0 * pow(1.5, tier)))


static func wave_cost_base(tier: float) -> float:
	return float(DmMath.js_round(120.0 * pow(1.75, tier)))


static func legion_cost_base(tier: float) -> float:
	return float(DmMath.js_round(120.0 * pow(1.65, tier)))


## Gold for the next Damage tier, or -1.0 (JS null) at the cap.
static func damage_cost(damage_tier: float, boons: Dictionary) -> float:
	var P := DmCombatData.progression()
	if damage_tier >= float(P["damage_upgrade"]["maxTier"]):
		return -1.0
	return float(DmMath.js_round(damage_cost_base(damage_tier) * float(DmVowsBoons.boon_effects(boons)["damageCostMult"])))


static func wave_cost(wave_tier_owned: float, boons: Dictionary) -> float:
	var P := DmCombatData.progression()
	if wave_tier_owned >= float(P["wave_upgrade"]["maxTier"]):
		return -1.0
	return float(DmMath.js_round(wave_cost_base(wave_tier_owned) * float(DmVowsBoons.boon_effects(boons)["waveCostMult"])))


static func legion_cost(legion_tier: float) -> float:
	var P := DmCombatData.progression()
	if legion_tier >= float(P["legion_upgrade"]["maxTier"]):
		return -1.0
	return legion_cost_base(legion_tier)


static func damage_bonus_pct(tier: float) -> float:
	return float(DmMath.js_round(float(DmCombatData.progression()["damage_upgrade"]["perTier"]) * tier * 100.0))


static func milestone_active(id: String, tier: float) -> bool:
	for m: Dictionary in DmCombatData.progression()["wave_milestones"]:
		if m["id"] == id:
			return tier >= float(m["tier"])
	return false


static func density_tier(tier: float) -> float:
	return minf(tier, DENSITY_FULL_TIERS) + DENSITY_TAIL * maxf(0.0, tier - DENSITY_FULL_TIERS)


static func wave_modifiers(tier: float) -> Dictionary:
	var nightfall := milestone_active("nightfall", tier)
	var d := density_tier(tier)
	return {
		"intervalMult": 1.0 / (1.0 + 0.12 * d),
		"capMult": 1.0 + 0.09 * d,
		"sizeMult": 1.0 + 0.06 * d,
		"rewardMult": 1.0 + 0.1 * tier + (0.25 if nightfall else 0.0),
		"xpMult": 1.0 + 0.05 * tier + (0.15 if nightfall else 0.0),
		"itemChanceMult": 1.0 + 0.06 * tier + (0.2 if nightfall else 0.0),
		"eliteBonus": 0.004 * tier,
		"enemyHpMult": 1.0 + 0.018 * tier,
		"enemyDamageMult": 1.0 + 0.026 * tier,
		"speedPct": float(DmMath.js_round(12.0 * d)),
	}


## Milestone diamonds on each upgrade bar (reference HUD shows three).
static func milestones(tier: float, max_tier: float) -> Array:
	var out: Array = []
	for f in [1.0 / 3.0, 2.0 / 3.0, 1.0]:
		out.append(tier >= ceilf(max_tier * f))
	return out
