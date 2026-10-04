class_name DmStats
extends RefCounted
## Port of src/gameplay/stats.ts + src/gameplay/characterStats.ts (deriveStats, STAT_EFFECTS, xpToNext).

const STAT_KEYS: Array[String] = ["stat_str", "stat_agi", "stat_int", "stat_vit"]

## STAT_EFFECTS: the per-stat coefficients behind every derived number (also exported in progression.json).
const HEALTH_BASE := 60.0
const HEALTH_PER_VIT := 8.0
const HEALTH_PER_LEVEL := 14.0
const SPELL_BASE := 6.0
const SPELL_PER_INT := 1.3
const SPELL_PER_STR := 0.4
const SPELL_PER_AGI := 0.2
const SPELL_PER_LEVEL := 1.6
const ESSENCE_BASE := 100.0
const ESSENCE_PER_INT := 2.0
const ESSENCE_PER_LEVEL := 2.0
const REGEN_BASE := 5.0
const REGEN_PER_INT := 0.1
const MOVE_BASE := 5.4
const MOVE_PER_AGI := 0.003
const THRALL_HP_SHARE := 0.45
const THRALL_DAMAGE_SHARE := 0.4


## {base, bonus, total}: each a Dictionary stat_key -> float.
static func compute_stats(character: Dictionary, slots: Array) -> Dictionary:
	var base := {}
	var bonus := {}
	for k in STAT_KEYS:
		base[k] = float(DmCombatData.nn(character.get(k), 0))
		bonus[k] = 0.0
	for slot: Dictionary in slots:
		# Legion kit pieces (slots 120+) are worn by the thralls: their stats never reach you.
		var sb: Variant = slot.get("stat_bonus")
		if not DmCombatData.truthy(slot.get("equipped")) or sb == null or DmGear.is_kit_slot(slot.get("slot_index")):
			continue
		for k in STAT_KEYS:
			bonus[k] += float(DmCombatData.nn((sb as Dictionary).get(k), 0))
	var from_sets := DmSetBonuses.set_stat_totals(slots)
	var total := {}
	for k in STAT_KEYS:
		bonus[k] += float(DmCombatData.nn(from_sets.get(k), 0))
		total[k] = base[k] + bonus[k]
	return {"base": base, "bonus": bonus, "total": total}


## deriveStats(character, slots, discipline, damageTier) -> DerivedStats Dictionary.
## `discipline` is a Dictionary {id, family, mods:{...}} (already boon/set adjusted by the caller, exactly as in TS).
static func derive_stats(character: Dictionary, slots: Array, discipline: Dictionary, damage_tier: float) -> Dictionary:
	var total: Dictionary = compute_stats(character, slots)["total"]
	var level: float = maxf(1.0, float(DmCombatData.nn(character.get("level"), 1)))
	var mods: Dictionary = discipline["mods"]
	var per_tier: float = DmCombatData.progression()["damage_upgrade"]["perTier"]
	var dmg_mult := 1.0 + per_tier * damage_tier
	var max_hp := float(DmMath.js_round(
		(HEALTH_BASE + total["stat_vit"] * HEALTH_PER_VIT + (level - 1.0) * HEALTH_PER_LEVEL) * mods["maxHpMult"]))
	var base_spell_power: float = (SPELL_BASE + total["stat_int"] * SPELL_PER_INT + total["stat_str"] * SPELL_PER_STR
		+ total["stat_agi"] * SPELL_PER_AGI + (level - 1.0) * SPELL_PER_LEVEL) * dmg_mult
	# A line staff's passive (+10% spell damage) raises Spell power; thralls keep the unboosted figure.
	var loadout := DmWeaponLine.resolve(DmGear.equipped_by_slot(slots), discipline["id"])
	var spell_power: float = base_spell_power * float(loadout["spellMult"])
	return {
		"level": level,
		"maxHp": max_hp,
		"spellPower": spell_power,
		"maxEssence": float(DmMath.js_round(ESSENCE_BASE + total["stat_int"] * ESSENCE_PER_INT + level * ESSENCE_PER_LEVEL)),
		"essenceRegen": (REGEN_BASE + total["stat_int"] * REGEN_PER_INT) * mods["essenceRegenMult"],
		"moveSpeed": MOVE_BASE * (1.0 + total["stat_agi"] * MOVE_PER_AGI),
		"thrallHp": float(DmMath.js_round(max_hp * THRALL_HP_SHARE * mods["thrallHpMult"])),
		"thrallDamage": base_spell_power * THRALL_DAMAGE_SHARE * mods["thrallDamageMult"],
		"damageBonusPct": float(DmMath.js_round((dmg_mult - 1.0) * 100.0)),
	}


## XP needed to advance from `level` (server rule: level x 100).
static func xp_to_next(level: float) -> float:
	return level * 100.0


# --- Plain-language deltas (UI helpers kept so ui tracks need not re-derive) -----------------------------------------

const DERIVED_KEYS: Array[String] = ["maxHp", "spellPower", "maxEssence", "essenceRegen", "moveSpeed", "thrallHp", "thrallDamage"]


static func format_derived(key: String, v: float) -> String:
	match key:
		"maxHp", "maxEssence", "thrallHp":
			return str(DmMath.js_round(v))
		"moveSpeed":
			return "%.2f" % v
		_:
			return "%.1f" % v


## The change in one number, formatted; "" when it rounds to nothing.
static func delta_text(key: String, before: float, after: float) -> String:
	if key == "moveSpeed":
		var pct := ((after - before) / before) * 100.0 if before != 0.0 else 0.0
		var r := DmMath.js_round_f(pct * 10.0) / 10.0
		if r == 0.0:
			return ""
		return ("+" if r > 0.0 else "-") + ("%.1f" % absf(r)) + "%"
	var digits := 0 if (key == "maxHp" or key == "maxEssence" or key == "thrallHp") else 1
	var f := pow(10.0, digits)
	var r2 := DmMath.js_round_f((after - before) * f) / f
	if r2 == 0.0:
		return ""
	return ("+" if r2 > 0.0 else "-") + (("%." + str(digits) + "f") % absf(r2))
