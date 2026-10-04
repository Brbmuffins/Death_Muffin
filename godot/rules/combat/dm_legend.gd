class_name DmLegend
extends RefCounted
## Port of src/gameplay/legendary.ts: legendary-set mechanics numbers + the damage-reduction maths. Constants come from statuses.json (LEGEND).

static func L() -> Dictionary:
	return DmCombatData.statuses()["LEGEND"]


const NO_SIM_LEGEND := {"thrallDeathBurst": 0.0, "championEvery": 0.0, "spearRally": 0.0, "miasmaSpreadsWithered": 0.0, "witheredBurstAt": 0.0}


static func sim_legend_of(m: Dictionary) -> Dictionary:
	return {
		"thrallDeathBurst": float(DmCombatData.nn(m.get("thrallDeathBurst"), 0)),
		"championEvery": float(DmCombatData.nn(m.get("championEvery"), 0)),
		"spearRally": float(DmCombatData.nn(m.get("spearRally"), 0)),
		"miasmaSpreadsWithered": float(DmCombatData.nn(m.get("miasmaSpreadsWithered"), 0)),
		"witheredBurstAt": float(DmCombatData.nn(m.get("witheredBurstAt"), 0)),
	}


static func sim_legend_active(l: Dictionary) -> bool:
	return l["thrallDeathBurst"] > 0.0 or l["championEvery"] > 0.0 or l["spearRally"] > 0.0 or l["miasmaSpreadsWithered"] > 0.0 or l["witheredBurstAt"] > 0.0


static func _fin(v: Variant) -> float:
	if (v is float or v is int) and is_finite(float(v)):
		return float(v)
	return 0.0


static func _clamp(v: Variant, lo: float, hi: float) -> float:
	return minf(hi, maxf(lo, _fin(v)))


## The host never trusts a claim: every field clamped to what a legendary set could ever grant.
static func clamp_sim_legend(raw: Variant) -> Dictionary:
	if raw == null:
		return NO_SIM_LEGEND.duplicate()
	return {
		"thrallDeathBurst": _clamp(raw.get("thrallDeathBurst"), 0.0, 2.0),
		"championEvery": floorf(_clamp(raw.get("championEvery"), 0.0, 20.0)),
		"spearRally": _clamp(raw.get("spearRally"), 0.0, 3.0),
		"miasmaSpreadsWithered": 1.0 if _clamp(raw.get("miasmaSpreadsWithered"), 0.0, 1.0) > 0.0 else 0.0,
		"witheredBurstAt": floorf(_clamp(raw.get("witheredBurstAt"), 0.0, 12.0)),
	}


## Withered stack cap, lifted to Chain Plague's burst threshold.
static func effective_withered_cap(m: Dictionary) -> float:
	return maxf(float(m["witheredMaxStacks"]), float(DmCombatData.nn(m.get("witheredBurstAt"), 0)))


static func colossus_active(m: Dictionary, thralls: float) -> bool:
	return float(m["colossusGuard"]) > 0.0 and thralls >= float(L()["colossusThralls"])


## Damage multiplier for an incoming blow (before Bulwark and the barrier).
static func damage_taken_mult(ward: float, guard: float) -> float:
	var l := L()
	var m := (1.0 - minf(float(l["wardCap"]), ward)) * (1.0 - minf(0.9, maxf(0.0, guard)))
	return maxf(1.0 - float(l["totalCap"]), m)


static func ward_reflect_damage(raw: float, bone_ward: float, reflect: float) -> float:
	if reflect <= 0.0 or raw <= 0.0 or bone_ward <= 0.0:
		return 0.0
	return raw * minf(float(L()["wardCap"]), bone_ward) * reflect


static func shatter_damage(barrier_size: float, mult: float) -> float:
	return barrier_size * mult if (barrier_size > 0.0 and mult > 0.0) else 0.0
