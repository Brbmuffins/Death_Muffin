class_name DmLegion
extends RefCounted
## Port of src/gameplay/legionRules.ts + the numeric parts of legionKit.ts: the Legion kit (thrall gear) -> thrall bonuses.
## A kit piece is {itemType, statBonus, affixes:[{id,v}]}; the kit is {weapon: piece|null, armor: piece|null}.

const KIT_IDS: Array[String] = ["weapon", "armor"]
const KIT_WEAPON_TYPES: Array[String] = ["weapon", "offhand"]
const KIT_ARMOR_TYPES: Array[String] = ["armor_head", "armor_chest", "armor_legs", "armor_feet", "armor_hands"]
const STATS: Array[String] = ["stat_str", "stat_agi", "stat_int", "stat_vit"]


static func _rates() -> Dictionary:
	return DmCombatData.progression()["kit"]["rates"]


static func _round4(x: float) -> float:
	return DmMath.js_round_f(x * 10000.0) / 10000.0


static func kit_slot_id(slot: float) -> Variant:
	return KIT_IDS[int(slot) - DmGear.KIT_BASE] if DmGear.is_kit_slot(slot) else null


static func kit_id_for_type(item_type: Variant) -> Variant:
	var t: String = item_type if item_type is String else ""
	if KIT_WEAPON_TYPES.has(t):
		return "weapon"
	if KIT_ARMOR_TYPES.has(t):
		return "armor"
	return null


static func stat_points(piece: Dictionary) -> float:
	var pts := 0.0
	var sb: Variant = piece.get("statBonus")
	for k in STATS:
		pts += maxf(0.0, float(DmCombatData.nn(sb.get(k) if sb != null else null, 0)))
	for a: Dictionary in (piece.get("affixes") if piece.get("affixes") != null else []):
		var e := DmAffixTotals.effect(a)
		for k in (e.get("stats", {}) as Dictionary):
			if STATS.has(k):
				pts += maxf(0.0, float(e["stats"][k]))
	return pts


static func _none() -> Dictionary:
	return {"points": 0.0, "hp": 0.0, "damage": 0.0, "speed": 0.0, "ward": 0.0}


## What one kit piece gives the legion when it sits in kit slot `kit` (a piece in the wrong slot gives nothing).
static func piece_bonus(kit: String, piece: Variant) -> Dictionary:
	var none := _none()
	if piece == null or kit_id_for_type(piece.get("itemType")) != kit:
		return none
	var R := _rates()
	var points := stat_points(piece)
	var out := none.duplicate()
	out["points"] = points
	if kit == "weapon":
		out["damage"] = minf(R["weaponDamageCap"], points * R["weaponDamagePerPoint"])
		out["speed"] = minf(R["weaponSpeedCap"], points * R["weaponSpeedPerPoint"])
	else:
		out["hp"] = minf(R["armorHpCap"], points * R["armorHpPerPoint"])
	for a: Dictionary in (piece.get("affixes") if piece.get("affixes") != null else []):
		var e := DmAffixTotals.effect(a)
		out["damage"] += (float(DmCombatData.nn((e.get("mult", {}) as Dictionary).get("thrallDamageMult"), 1)) - 1.0) * R["affixShare"]
		out["hp"] += (float(DmCombatData.nn((e.get("mult", {}) as Dictionary).get("thrallHpMult"), 1)) - 1.0) * R["affixShare"]
		out["ward"] += float(DmCombatData.nn((e.get("add", {}) as Dictionary).get("wardPerThrall"), 0)) * R["affixShare"]
	return {"points": points, "hp": _round4(out["hp"]), "damage": _round4(out["damage"]), "speed": _round4(out["speed"]), "ward": _round4(out["ward"])}


static func reinforce_bonus(tier: float) -> Dictionary:
	var L: Dictionary = DmCombatData.progression()["legion_upgrade"]
	var t := clampf(floorf(tier) if not is_nan(tier) else 0.0, 0.0, float(L["maxTier"]))
	return {"tier": t, "hp": _round4(t * L["perTier"]), "damage": _round4(t * L["perTier"]), "speed": _round4(t * L["speedPerTier"])}


static func no_legion() -> Dictionary:
	return {
		"hpMult": 1.0, "damageMult": 1.0, "speedMult": 1.0, "wardAdd": 0.0,
		"kit": {"hp": 0.0, "damage": 0.0, "speed": 0.0, "ward": 0.0}, "reinforce": {"tier": 0.0, "hp": 0.0, "damage": 0.0, "speed": 0.0},
	}


## legionBonus(kit, reinforceTier)
static func legion_bonus(kit: Dictionary, reinforce_tier: float) -> Dictionary:
	var w := piece_bonus("weapon", kit.get("weapon"))
	var a := piece_bonus("armor", kit.get("armor"))
	var k := {"hp": _round4(w["hp"] + a["hp"]), "damage": _round4(w["damage"] + a["damage"]), "speed": _round4(w["speed"] + a["speed"]), "ward": _round4(w["ward"] + a["ward"])}
	var r := reinforce_bonus(reinforce_tier)
	return {
		"hpMult": (1.0 + k["hp"]) * (1.0 + r["hp"]),
		"damageMult": (1.0 + k["damage"]) * (1.0 + r["damage"]),
		"speedMult": (1.0 + k["speed"]) * (1.0 + r["speed"]),
		"wardAdd": k["ward"],
		"kit": k,
		"reinforce": r,
	}


static func is_no_legion(b: Dictionary) -> bool:
	return b["hpMult"] == 1.0 and b["damageMult"] == 1.0 and b["speedMult"] == 1.0 and b["wardAdd"] == 0.0


# --- legionKit.ts: reading the kit out of inventory rows -----------------------------------------------------------

static func piece_of(slot: Dictionary) -> Dictionary:
	var inst: Variant = slot.get("inst")
	return {"itemType": slot.get("item_type"), "statBonus": slot.get("stat_bonus"), "affixes": inst["affixes"] if inst != null else null}


## The two pieces on the legion, by kit slot id -> slot row.
static func kit_pieces(slots: Array) -> Dictionary:
	var out := {}
	for s: Dictionary in slots:
		var id: Variant = kit_slot_id(float(DmCombatData.nn(s.get("slot_index"), -1)))
		if id != null and float(DmCombatData.nn(s.get("quantity"), 0)) > 0.0:
			out[id] = s
	return out


## The bonus the legion has with these inventory rows and this many reinforcement tiers.
static func legion_of(slots: Array, tier: float) -> Dictionary:
	var worn := kit_pieces(slots)
	return legion_bonus(
		{"weapon": piece_of(worn["weapon"]) if worn.has("weapon") else null, "armor": piece_of(worn["armor"]) if worn.has("armor") else null}, tier)


## The mods with the legion folded in (a new Dictionary). Fold BEFORE the armour set bonuses.
static func apply_legion_mods(mods: Dictionary, b: Dictionary) -> Dictionary:
	if is_no_legion(b):
		return mods
	var out := mods.duplicate(true)
	out.erase(DmSetBonuses.APPLIED_KEY)
	out["thrallHpMult"] = float(mods["thrallHpMult"]) * b["hpMult"]
	out["thrallDamageMult"] = float(mods["thrallDamageMult"]) * b["damageMult"]
	out["thrallAttackSpeedMult"] = float(mods["thrallAttackSpeedMult"]) * b["speedMult"]
	out["wardPerThrall"] = float(mods["wardPerThrall"]) + b["wardAdd"]
	return out


static func legion_signature(slots: Array, tier: float) -> String:
	var w := kit_pieces(slots)
	var roll := func(s: Variant) -> String:
		if s == null:
			return "-"
		var inst: Variant = s.get("inst")
		var rolls: Array[String] = []
		if inst != null:
			for a: Dictionary in inst["affixes"]:
				rolls.append("%s=%s" % [a["id"], DmAffixTotals._num(a["v"])])
		return "%s~%s" % [s["item_id"], ",".join(rolls)]
	return "%s|%s|%s" % [roll.call(w.get("weapon")), roll.call(w.get("armor")), DmAffixTotals._num(tier)]


## The one-time bump a purchase gives thralls already standing: new/old of each number, clamped to [1, THRALL_REFRESH_MAX].
## `before`/`after` = {hp, damage, speedMult}. Returns {} (JS null) when nothing a thrall carries changed.
static func thrall_refresh(before: Dictionary, after: Dictionary) -> Dictionary:
	var mx: float = DmCombatData.progression()["thrall_refresh_max"]
	var ratio := func(a: float, b: float) -> float:
		return minf(mx, maxf(1.0, b / a)) if (a > 0.0 and b > 0.0) else 1.0
	var r := {
		"hpMult": ratio.call(before["hp"], after["hp"]),
		"damageMult": ratio.call(before["damage"], after["damage"]),
		"speedMult": ratio.call(before["speedMult"], after["speedMult"]),
	}
	if r["hpMult"] > 1.0005 or r["damageMult"] > 1.0005 or r["speedMult"] > 1.0005:
		return r
	return {}


## How much better a piece is than another, as one number.
static func piece_value(p: Dictionary) -> float:
	return p["hp"] + p["damage"] + 1.5 * p["speed"] + 2.0 * p["ward"]
