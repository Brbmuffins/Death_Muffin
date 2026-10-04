class_name DmEnemyStats
extends RefCounted
## Enemy stat scaling and kill rewards: WorldSim.spawnEnemy / adoptEnemy / areaLevel / rampTier / damageEnemy numerics, difficulty, elite
## multipliers, Depths level, killRules XP/gold, new-blood XP catch-up, hit-number scale. Spawn placement/AI is the world sim's.

const RAMP_S := 30.0


static func E() -> Dictionary:
	return DmCombatData.enemies()


static func hp_scale(level: float) -> float:
	return 1.0 + 0.22 * (level - 1.0)


static func damage_scale(level: float) -> float:
	return 1.0 + 0.15 * (level - 1.0)


static func difficulty(id: String) -> Dictionary:
	return E()["difficulties"][id]


static func depth_enemy_level(depth: float, hero_level: float) -> float:
	var D: Dictionary = E()["depths"]
	var hl := floorf(hero_level) if hero_level == hero_level else 0.0
	if hl == 0.0:
		hl = 1.0
	return maxf(float(D["minLevel"]), hl) + floorf(maxf(1.0, depth) * float(D["levelsPerDepth"]))


## WorldSim.areaLevel. `hero_levels` = levels of living players in the area; `vow_levels` = vowEffects.levels; depth = current Depths depth.
static func area_level(area: String, hero_levels: Array, vow_levels: float, depth: float = 1.0) -> float:
	var def: Dictionary = E()["areas"][area]
	if area == "depths":
		var top := 0.0
		for l in hero_levels:
			if float(l) > top:
				top = minf(999.0, float(l))
		return depth_enemy_level(depth, top) + vow_levels
	var level := float(def["level"])
	if def["scaling"] != null:
		level = float(def["scaling"]["minLevel"])
		for l in hero_levels:
			if float(l) > level:
				level = minf(999.0, float(l))
	return level + vow_levels


## Wave Speed builds over the first RAMP_S seconds of a visit.
static func ramp_tier(wave_tier: float, since_arrival_s: float) -> float:
	return wave_tier * maxf(0.0, minf(1.0, since_arrival_s / RAMP_S))


static func party_hp_scale(players: float) -> float:
	return 1.0 + 0.5 * (maxf(1.0, players) - 1.0)


## spawnEnemy numbers: {level, hp, damage, radius, scale}. ctx = {area_level, ramp_tier, difficulty, vow_hp_mult, players}.
static func spawn_stats(def_id: String, elite: bool, ctx: Dictionary) -> Dictionary:
	var d: Dictionary = E()["enemies"][def_id]
	var EL: Dictionary = E()["constants"]["ELITE"]
	var level: float = ctx["level"]
	var wave := DmWaveUpgrades.wave_modifiers(ctx["rampTier"])
	var diff := difficulty(ctx["difficulty"])
	var hp: float = float(d["hp"]) * hp_scale(level) * wave["enemyHpMult"] * float(diff["enemyHpMult"]) * float(ctx["vowHpMult"]) \
		* (float(EL["hpMult"]) if elite else 1.0) * party_hp_scale(float(ctx["players"]))
	return {
		"level": level, "hp": hp,
		"damage": float(d["damage"]) * damage_scale(level) * wave["enemyDamageMult"] * float(diff["enemyDamageMult"]) * (float(EL["damageMult"]) if elite else 1.0),
		"radius": float(d["radius"]) * (1.25 if elite else 1.0),
		"scale": float(d["scale"]) * (float(EL["scale"]) if elite else 1.0),
	}


## adoptEnemy (host migration): damage recomputed from level, wave tier and difficulty.
static func adopt_damage(def_id: String, elite: bool, level: float, wave_tier: float, difficulty_id: String) -> float:
	var d: Dictionary = E()["enemies"][def_id]
	var EL: Dictionary = E()["constants"]["ELITE"]
	return float(d["damage"]) * damage_scale(level) * DmWaveUpgrades.wave_modifiers(wave_tier)["enemyDamageMult"] * float(difficulty(difficulty_id)["enemyDamageMult"]) * (float(EL["damageMult"]) if elite else 1.0)


## What an enemy's blow is worth right now (Bone Hex softens it).
static func blow(e_damage: float, hexed: bool) -> float:
	return e_damage * (float(DmCombatData.statuses()["BONE_HEX"]["damageMult"]) if hexed else 1.0)


## Shrouded elites shrug off half unless in friendly rot; Sanctified x0.7.
static func damage_taken_mult(shrouded: bool, in_friendly_rot: bool, sanctified: bool) -> float:
	var shroud: float = float(E()["constants"]["AFFIX_TUNING"]["shrouded"]["damageTakenMult"]) if (shrouded and not in_friendly_rot) else 1.0
	return shroud * (float(DmCombatData.statuses()["SANCTIFIED"]["damageTakenMult"]) if sanctified else 1.0)


## Bell Templar shield: `angle_diff` = |atan2(from.x-e.x, from.z-e.z) - e.facing| (the sim folds it into 0..PI). Returns pass-through (1 = unshielded).
static func shield_mult(has_shield: bool, has_from: bool, fracture: float, atan_diff: float) -> float:
	if not (has_shield and has_from and fracture == 0.0):
		return 1.0
	var d := fposmod(absf(atan_diff), PI * 2.0)
	if d > PI:
		d = PI * 2.0 - d
	var T: Dictionary = E()["constants"]["TEMPLAR_SHIELD"]
	return float(T["passThrough"]) if d <= (float(T["halfArcDeg"]) * PI) / 180.0 else 1.0


## damageEnemy: damage dealt = amount x (1 + Fracture stacks) x damageTaken x shield.
static func damage_dealt(amount: float, fracture: float, taken_mult: float, shield: float) -> float:
	return amount * (1.0 + float(DmCombatData.const_table("FRACTURE")["perStack"]) * fracture) * taken_mult * shield


## hitNumber.damageTakenScale
static func hit_number_scale(fracture: float, sanct: bool, shrouded: bool, in_friendly_rot: bool) -> float:
	var m := 1.0 + float(DmCombatData.const_table("FRACTURE")["perStack"]) * fracture
	if sanct:
		m *= float(DmCombatData.statuses()["SANCTIFIED"]["damageTakenMult"])
	if shrouded and not in_friendly_rot:
		m *= float(E()["constants"]["AFFIX_TUNING"]["shrouded"]["damageTakenMult"])
	return m


## Host clamp on a claimed Hemorrhage bleed: min(claimed, dmg x maxFrac).
static func bleed_dps(claimed: float, dmg: float) -> float:
	return minf(claimed, dmg * float(DmCombatData.statuses()["HEMORRHAGE"]["maxFrac"]))


## Rot Lance / sickle Withered stacks the host will apply: clamp(cap, 1..12) (default Corpse Explosion's).
static func withered_cap_clamped(claimed_cap: Variant) -> float:
	var d := float(DmCombatData.const_table("DETONATE")["rotWitheredCap"])
	var c: float = float(claimed_cap) if (claimed_cap is float or claimed_cap is int) else d
	return minf(12.0, maxf(1.0, floorf(c if is_finite(c) else d)))


# --- Rewards (killRules.ts) ---------------------------------------------------------------------------------------

static func kill_xp_base(def_id: String, level: float, elite: bool, tier: float, diff_id: String) -> float:
	var d: Dictionary = E()["enemies"][def_id]
	return float(d["xp"]) * (1.0 + 0.25 * (level - 1.0)) * DmWaveUpgrades.wave_modifiers(tier)["xpMult"] * float(difficulty(diff_id)["rewardMult"]) * (float(E()["constants"]["ELITE"]["xpMult"]) if elite else 1.0)


static func kill_gold_max(def_id: String, level: float, elite: bool, tier: float, diff_id: String) -> float:
	var d: Dictionary = E()["enemies"][def_id]
	return float(d["gold"][1]) * (1.0 + 0.15 * (level - 1.0)) * DmWaveUpgrades.wave_modifiers(tier)["rewardMult"] * float(difficulty(diff_id)["rewardMult"]) * (float(E()["constants"]["ELITE"]["goldMult"]) if elite else 1.0)


static func is_new_blood(family: String) -> bool:
	return family != "necromancer"


static func new_blood_damage_mult(family: String) -> float:
	return float(DmCombatData.progression()["new_blood"]["damage_mult"]) if is_new_blood(family) else 1.0


static func new_blood_xp_mult(family: String, level: float) -> float:
	if not is_new_blood(family):
		return 1.0
	var c: Dictionary = DmCombatData.progression()["new_blood"]["xp_catchup"]
	var l := maxf(1.0, float(int(level)))
	if l >= float(c["fadeLevel"]):
		return 1.0
	return float(c["startMult"]) + ((1.0 - float(c["startMult"])) * (l - 1.0)) / (float(c["fadeLevel"]) - 1.0)
