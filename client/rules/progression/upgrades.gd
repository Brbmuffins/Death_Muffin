class_name DmUpgrades
extends RefCounted
## Port of server/rules/content/upgrades.ts: Damage / Wave Speed / Legion tiers and costs, wave modifiers, wave milestones.


static func damage_cost(tier: int) -> int:
	var u: Dictionary = DmProgContent.upgrades()["damage"]
	return DmProgUtil.js_round(float(u["costBase"]) * pow(float(u["costGrowth"]), tier))


static func wave_cost(tier: int) -> int:
	var u: Dictionary = DmProgContent.upgrades()["wave"]
	return DmProgUtil.js_round(float(u["costBase"]) * pow(float(u["costGrowth"]), tier))


static func legion_cost(tier: int) -> int:
	var u: Dictionary = DmProgContent.upgrades()["legion"]
	return DmProgUtil.js_round(float(u["costBase"]) * pow(float(u["costGrowth"]), tier))


static func max_tier(which: String) -> int:
	return int(DmProgContent.upgrades()[which]["maxTier"])


static func milestone_active(id: String, tier: float) -> bool:
	for m in DmProgContent.upgrades()["waveMilestones"]:
		if m["id"] == id:
			return tier >= float(m["tier"])
	return false


## Density terms climb at full rate to tier 3 and at DENSITY_TAIL after.
static func density_tier(tier: float) -> float:
	return minf(tier, 3.0) + 0.55 * maxf(0.0, tier - 3.0)


static func wave_modifiers(tier: float) -> Dictionary:
	var nightfall: bool = milestone_active("nightfall", tier)
	var d: float = density_tier(tier)
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
		"speedPct": DmProgUtil.js_round(12.0 * d),
	}


static func damage_bonus_pct(tier: float) -> int:
	var u: Dictionary = DmProgContent.upgrades()["damage"]
	return DmProgUtil.js_round(float(u["perTier"]) * tier * 100.0)


## Milestone diamonds on an upgrade bar (three).
static func milestones(tier: float, max_tier_: float) -> Array:
	var out: Array = []
	for f in [1.0 / 3.0, 2.0 / 3.0, 1.0]:
		out.append(tier >= ceilf(max_tier_ * f))
	return out
