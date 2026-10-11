class_name DmPlayerRules
extends RefCounted
## Port of the rules inside archive/legacy-web:src/gameplay/Player.ts: defence (Bone Ward + Colossus guard, barrier, Bulwark, Oath Unbroken), regeneration,
## resource drift, Rage gain, soul-harvest meter, move speed. Pure functions over a state Dictionary `p` (mutated in place); no movement/pathing
## (that is world-sim). Create with new_state().

const OUT_OF_COMBAT_MS := 5000.0


static func new_state(stats: Dictionary, family: String = "necromancer") -> Dictionary:
	var mx := DmResources.max_for(family, stats)
	return {
		"family": family, "stats": stats,
		"hp": float(stats["maxHp"]),
		"resource": {"kind": DmResources.kind_for(family), "value": DmResources.initial(family, mx), "max": mx},
		"veilForm": false, "betweenUntil": 0.0, "lastResourceGainAt": 0.0, "clockNow": 0.0,
		"barrier": 0.0, "barrierPeak": 0.0, "barrierBroke": 0.0, "barrierHoldUntil": 0.0,
		"soulRateMult": 1.0, "soulAcc": 0.0, "souls": 0, "soulsMax": DmCombatData.const_table("SOUL_HARVEST")["souls"],
		"bulwarkUntil": 0.0, "bulwarkPerfectUntil": 0.0, "unbreakableUntil": 0.0, "lastBlock": "none",
		"alive": true, "lastHurtAt": -1e9, "rootedUntil": 0.0, "chilledUntil": 0.0, "castUntil": 0.0, "god": false,
		"moveMult": 1.0, "facing": PI, "x": 0.0, "z": 0.0,
		"brews": DmBrews.empty_brews(), "cooldowns": {},
	}


static func add_resource(p: Dictionary, amount: float) -> void:
	if amount > 0.0 and p["resource"]["kind"] == "resonance":
		p["lastResourceGainAt"] = p["clockNow"]
	p["resource"]["value"] = maxf(0.0, minf(p["resource"]["max"], p["resource"]["value"] + amount))


static func set_stats(p: Dictionary, stats: Dictionary) -> void:
	var hp_frac: float = p["hp"] / float(p["stats"]["maxHp"])
	p["stats"] = stats
	p["hp"] = minf(float(stats["maxHp"]), maxf(1.0, float(DmMath.js_round(float(stats["maxHp"]) * hp_frac))))
	p["resource"]["max"] = DmResources.max_for(p["family"], stats)
	p["resource"]["value"] = minf(p["resource"]["max"], p["resource"]["value"])


static func souls_charged(p: Dictionary) -> bool:
	return p["souls"] >= p["soulsMax"]


## Add harvested souls; true on the kill that fills the meter.
static func add_souls(p: Dictionary, n: float = 1.0) -> bool:
	if souls_charged(p):
		return false
	var gain := n
	if p["soulRateMult"] != 1.0:
		p["soulAcc"] += n * p["soulRateMult"]
		gain = floorf(p["soulAcc"])
		p["soulAcc"] -= gain
	p["souls"] = minf(float(p["soulsMax"]), float(p["souls"]) + gain)
	return souls_charged(p)


static func spend_souls(p: Dictionary) -> void:
	p["souls"] = 0


## The Reaper's soul bag (`p["souls"]` counts it, `p["soulsMax"]` is its size): bank up to `n` souls, returns how many fitted.
static func bag_add(p: Dictionary, n: int = 1) -> int:
	var room := maxi(0, int(p["soulsMax"]) - int(p["souls"]))
	var took := mini(n, room)
	p["souls"] = int(p["souls"]) + took
	return took


## Take up to `most` souls out of the bag, returns how many were taken.
static func bag_spend(p: Dictionary, most: int) -> int:
	var took := mini(maxi(most, 0), int(p["souls"]))
	p["souls"] = int(p["souls"]) - took
	return took


static func on_cooldown(p: Dictionary, id: String, now: float) -> bool:
	return float(p["cooldowns"].get(id, 0.0)) > now


static func cooldown_left(p: Dictionary, id: String, now: float) -> float:
	return maxf(0.0, float(p["cooldowns"].get(id, 0.0)) - now)


static func brew_value(p: Dictionary, kind: String, now: float) -> float:
	return DmBrews.brew_value(p["brews"], kind, now)


## The vitals half of Player.update(dt, now): regeneration, resource drift, barrier decay (everything before movement).
static func tick_vitals(p: Dictionary, dt: float, now: float) -> void:
	p["clockNow"] = now
	if not p["alive"]:
		return
	var stats: Dictionary = p["stats"]
	var ooc: bool = now - float(p["lastHurtAt"]) > OUT_OF_COMBAT_MS
	p["hp"] = minf(float(stats["maxHp"]), p["hp"] + float(stats["maxHp"]) * (0.045 if ooc else 0.004) * dt)
	var essence_boost: float = DmBrews.brew_value(p["brews"], "essence", now) if p["brews"].get("tonic") != null else 0.0
	var drift: float
	if p["resource"]["kind"] == "veil" and p["veilForm"]:
		drift = -12.0
	else:
		var st: Dictionary = stats
		if essence_boost != 0.0:
			st = stats.duplicate()
			st["essenceRegen"] = float(stats["essenceRegen"]) * (1.0 + essence_boost)
		drift = DmResources.passive(p["family"], {
			"stats": st, "value": p["resource"]["value"], "max": p["resource"]["max"],
			"sinceHurtMs": now - float(p["lastHurtAt"]), "sinceResourceGainMs": now - float(p["lastResourceGainAt"]),
		})
	add_resource(p, drift * dt)
	if p["resource"]["kind"] == "veil" and p["resource"]["value"] <= 0.0:
		p["veilForm"] = false
	if now >= p["barrierHoldUntil"]:
		p["barrier"] = maxf(0.0, p["barrier"] - float(stats["maxHp"]) * 0.04 * dt)
	if p["barrier"] <= 0.0:
		p["barrierPeak"] = 0.0


## Walking speed this instant (Veil form / Between Worlds +20%, scene move multiplier, Chill).
static func move_speed(p: Dictionary, now: float) -> float:
	var chill: float = DmCombatData.statuses()["CHILL"]["moveMult"]
	var fleet: float = float(DmCombatData.const_table("REAPER")["moveMult"]) if p.get("family") == "reaper" else 1.0   # the Reaper runs faster
	return float(p["stats"]["moveSpeed"]) * (1.2 if (p["veilForm"] or now < p["betweenUntil"]) else 1.0) * fleet * p["moveMult"] * (chill if now < p["chilledUntil"] else 1.0)


## Inside Bulwark's frontal cover? `from` = {x, z} or null.
static func blow_is_frontal(p: Dictionary, from: Variant) -> bool:
	if from == null:
		return false
	var dx: float = from["x"] - p["x"]
	var dz: float = from["z"] - p["z"]
	var l := DmWeaponLine.hypot2(dx, dz)
	if l < 1e-6:
		return true
	var dot := (sin(p["facing"]) * dx + cos(p["facing"]) * dz) / l
	var B: Dictionary = DmCombatData.const_table("BULWARK")
	return dot >= cos((float(B["frontHalfDeg"]) * PI) / 180.0)


## Apply incoming damage through Bone Ward + Colossus guard, Bulwark, barrier; returns damage taken. `from` = {x,z}|null, `source` = hurt source.
static func take_damage(p: Dictionary, raw: float, ward_pct: float, now: float, from: Variant = null, source: String = "", guard: float = 0.0) -> float:
	p["lastBlock"] = "none"
	if not p["alive"] or p["god"]:
		return 0.0
	if p["resource"]["kind"] == "veil" and source != "toxic" and source != "burn" and (p["veilForm"] or now < p["betweenUntil"]):
		return 0.0
	var dmg := raw * DmLegend.damage_taken_mult(ward_pct, guard)
	var B: Dictionary = DmCombatData.const_table("BULWARK")
	if now < p["bulwarkUntil"] and blow_is_frontal(p, from):
		p["lastBlock"] = "perfect" if now < p["bulwarkPerfectUntil"] else "front"
		dmg *= 1.0 - float(B["damageCut"])
	var absorbed := minf(p["barrier"], dmg)
	var barrier_before: float = p["barrier"]
	p["barrier"] -= absorbed
	if barrier_before > 0.0 and p["barrier"] <= 0.0 and p["barrierPeak"] > 0.0:
		p["barrierBroke"] = p["barrierPeak"]
		p["barrierPeak"] = 0.0
	dmg -= absorbed
	p["hp"] -= dmg
	p["lastHurtAt"] = now
	var R: Dictionary = DmCombatData.const_table("KNIGHT_RAGE")
	if p["resource"]["kind"] == "rage" and dmg > 0.0:
		add_resource(p, (dmg / float(p["stats"]["maxHp"])) * 100.0 * float(R["perHpPercentLost"]))
	if p["lastBlock"] == "perfect":
		add_resource(p, float(R["perPerfectBlock"]))
	if p["hp"] <= 0.0:
		# Oath Unbroken: the oath holds at a sliver rather than breaking.
		if now < p["unbreakableUntil"]:
			p["hp"] = 1.0
		else:
			p["hp"] = 0.0
			p["alive"] = false
	return dmg


static func heal(p: Dictionary, amount: float) -> void:
	if not p["alive"]:
		return
	p["hp"] = minf(float(p["stats"]["maxHp"]), p["hp"] + amount)


static func revive(p: Dictionary) -> void:
	p["alive"] = true
	p["veilForm"] = false
	p["betweenUntil"] = 0.0
	p["rootedUntil"] = 0.0
	p["castUntil"] = 0.0
	p["bulwarkUntil"] = 0.0
	p["bulwarkPerfectUntil"] = 0.0
	p["unbreakableUntil"] = 0.0
	p["chilledUntil"] = 0.0
	p["hp"] = float(p["stats"]["maxHp"])
	p["resource"]["value"] = DmResources.on_revive(p["family"], p["resource"]["max"])
	p["barrier"] = 0.0
