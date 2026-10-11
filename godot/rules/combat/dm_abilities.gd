class_name DmAbilities
extends RefCounted
## Deterministic numbers of archive/legacy-web:src/content/abilities.ts + archive/legacy-web:src/gameplay/AbilitySystem.ts + NewBloodSystem.ts: ability definitions, unlock gates,
## spell power, cast checks and costs, cooldown / lock math, per-rite damage, Litany / Corpse Explosion / thrall-raise numbers, Mantle and Litany
## barriers, wisps, Black-Litany scaling, rune modifiers. Everything that needs the world (targeting, projectiles, AI) is left to the world sim.
## A "player" argument is the Dictionary from DmPlayerRules.new_state() with extra keys the scene sets: loadout (DmWeaponLine.resolve),
## runes {rite: rune_id}, cooldowns {id: until_ms}.

const NEEDLE_CRIT_CHANCE := 0.08
const NEEDLE_CRIT_MULT := 1.8


static func defs() -> Dictionary:
	return DmCombatData.abilities()["abilities"]


static func def(id: String) -> Dictionary:
	return defs()[id]


static func C(name: String) -> Variant:
	return DmCombatData.const_table(name)


static func tune() -> Dictionary:
	return DmCombatData.abilities()["rune_tuning"]


## Level a rite unlocks at (1 = from the start).
static func unlock_level(id: String) -> float:
	return float(DmCombatData.nn(def(id).get("unlockLevel"), 1))


## devAccess.active makes every gate pass; here `dev` carries it.
static func rite_level(level: float, dev: bool = false) -> float:
	return INF if dev else level


static func unlocked(id: String, level: float, dev: bool = false) -> bool:
	return rite_level(level, dev) >= unlock_level(id)


static func cast_flow(id: String) -> Dictionary:
	return DmCombatData.abilities()["cast_flow"][id]


static func kit_for(family: String) -> Dictionary:
	var kits: Dictionary = DmCombatData.abilities()["kits"]
	return kits.get(family, kits["necromancer"])


static func is_primary(id: String) -> bool:
	return (C("PRIMARIES") as Array).has(id)


## AbilitySystem.sp: spell power x Oath Unbroken x the active damage elixir (x the Reaper's soul bag: +2% a soul).
static func sp(p: Dictionary, now: float) -> float:
	var oath: float = C("OATH_UNBROKEN")["damageMult"] if now < p["unbreakableUntil"] else 1.0
	var flask := 1.0 + DmPlayerRules.brew_value(p, "damage", now)
	var bag := 1.0 + float(C("REAPER")["damagePerSoul"]) * float(p["souls"]) if p.get("family") == "reaper" else 1.0
	return float(p["stats"]["spellPower"]) * oath * flask * bag


## NewBloodSystem.power: spell power x 1.5, x0.7 while in Veil form outside the Between Worlds window.
static func new_blood_power(p: Dictionary, now: float) -> float:
	var nb: float = DmCombatData.progression()["new_blood"]["damage_mult"]
	return float(p["stats"]["spellPower"]) * nb * (0.7 if (p["veilForm"] and now >= p["betweenUntil"]) else 1.0)


static func empowered(p: Dictionary, id: String) -> bool:
	return DmPlayerRules.souls_charged(p) and (C("SOUL_HARVEST")["spells"] as Array).has(id)


## Everything that can refuse a cast before the rite itself runs: "ok", "dead", "locked", "busy", "cooldown", "essence".
static func cast_check(p: Dictionary, id: String, level: float, now: float, dev: bool = false) -> String:
	if not p["alive"]:
		return "dead"
	if not unlocked(id, level, dev):
		return "locked"
	if now < p["castUntil"]:
		return "busy"
	if DmPlayerRules.on_cooldown(p, id, now):
		return "cooldown"
	if not empowered(p, id) and p["resource"]["value"] < float(def(id)["essenceCost"]):
		return "essence"
	return "ok"


## AbilitySystem.ready(id, now)
static func ready(p: Dictionary, id: String, level: float, now: float, dev: bool = false) -> bool:
	return p["alive"] and unlocked(id, level, dev) and now >= p["castUntil"] and not DmPlayerRules.on_cooldown(p, id, now) \
		and (empowered(p, id) or p["resource"]["value"] >= float(def(id)["essenceCost"]))


## Distance a target is beyond the ability's reach (0 if in range). t = {x, z, boss?}; boss radius BOSS_RADIUS is passed in (world constant).
static func shortfall(p: Dictionary, id: String, t: Dictionary, boss_radius: float) -> float:
	var d := def(id)
	if d["targeting"] != "enemy":
		return 0.0
	var pad: float = boss_radius if t.get("boss", false) else 0.4
	var dist := DmWeaponLine.hypot2(t["x"] - p["x"], t["z"] - p["z"])
	return maxf(0.0, dist - (DmWeaponLine.ability_range(id, float(d["range"]), p["loadout"], bool(t.get("boss", false))) + pad))


## The bookkeeping AbilitySystem.cast does after a rite returned "ok": cast lock, root, resource spend, sickle refund, cooldown.
## `colossus_cast` = this Exhume raised a Bone Colossus. Mutates p. (Soul release / wraith nova side effects are the caller's.)
static func apply_cast_cost(p: Dictionary, id: String, now: float, was_empowered: bool, colossus_cast: bool = false) -> void:
	var d := def(id)
	var lo: Dictionary = p["loadout"]
	p["castUntil"] = now + DmWeaponLine.ability_lock_ms(id, float(cast_flow(id)["lockMs"]), lo)
	p["rootedUntil"] = maxf(p["rootedUntil"], p["castUntil"])
	if was_empowered:
		DmPlayerRules.spend_souls(p)
	else:
		p["resource"]["value"] -= float(d["essenceCost"])
	if id == "exhume" and not was_empowered and float(lo["exhumeRefund"]) > 0.0:
		p["resource"]["value"] = minf(float(p["stats"]["maxEssence"]), p["resource"]["value"] + float(d["essenceCost"]) * float(lo["exhumeRefund"]))
	var rune_cool: float = float(tune()["colossus"]["cooldownMult"]) if (id == "exhume" and colossus_cast) else 1.0
	p["cooldowns"][id] = now + (DmWeaponLine.ability_cooldown_ms(id, float(d["cooldownMs"]), lo, is_primary(id)) * rune_cool) / (1.0 + DmPlayerRules.brew_value(p, "haste", now))


## The rune socketed in a rite, "" when none (or it does not fit).
static func rune(p: Dictionary, rite: String) -> String:
	var id: Variant = p.get("runes", {}).get(rite)
	if id != null and id != "" and DmCombatData.abilities()["runes"].has(id) and DmCombatData.abilities()["runes"][id]["rite"] == rite:
		return id
	return ""


# --- Bone Needle / scythe ------------------------------------------------------------------------------------------

## One needle's damage. `needle_cast_index` is the 1-based count of needle casts so far (the Volley rune fires on every 4th);
## `jitter` is the 0..1 random roll behind (0.9 + r * 0.2). Returns {volley, runeMult, dmg, essence}.
static func needle_cast(sp_value: float, loadout: Dictionary, rune_id: String, needle_cast_index: int, jitter: float) -> Dictionary:
	var T := tune()
	var volley: bool = rune_id == "rune_volley" and needle_cast_index % int(T["volley"]["every"]) == 0
	var rune_mult := 1.0
	if rune_id == "rune_marrow_tap":
		rune_mult = T["marrowTap"]["damageMult"]
	elif volley:
		rune_mult = T["volley"]["damageFrac"]
	var dmg: float = sp_value * float(def("bone_needle")["power"]) * float(loadout["needleDamageMult"]) * rune_mult * (0.9 + jitter * 0.2)
	var essence: float = float(C("NEEDLE_ESSENCE")) + (float(T["marrowTap"]["essenceBonus"]) if rune_id == "rune_marrow_tap" else 0.0)
	return {"volley": volley, "runeMult": rune_mult, "dmg": dmg, "essence": essence}


## Volley needles each return an even share of the essence.
static func volley_essence_each(essence: float) -> float:
	return essence / float(tune()["volley"]["needles"])


## A needle that lands: crit roll result -> damage dealt. `crit_roll` is the 0..1 random (crit when < 8%).
static func needle_hit(dmg: float, crit_roll: float) -> Dictionary:
	var crit := crit_roll < NEEDLE_CRIT_CHANCE
	return {"crit": crit, "amount": dmg * NEEDLE_CRIT_MULT if crit else dmg}


## Staff pierce: damage the pierced enemies take.
static func pierce_damage(dmg: float) -> float:
	return dmg * float(DmCombatData.load_json("necro_weapons")["tuning"]["staff"]["pierceDamageMult"])


## Splinters rune: shard damage.
static func splinter_damage(dmg: float) -> float:
	return dmg * float(tune()["splinter"]["damageFrac"])


## Scythe swing: {dmg, essenceOnLand}; `landed` = enemies struck (+boss). Marrow-Tap adds its bonus once per swing that lands.
static func reap_cast(sp_value: float, rune_id: String, jitter: float, landed: int) -> Dictionary:
	var T: Dictionary = DmCombatData.load_json("necro_weapons")["tuning"]["scythe"]
	var mt: float = tune()["marrowTap"]["damageMult"] if rune_id == "rune_marrow_tap" else 1.0
	var dmg: float = sp_value * float(def("bone_needle")["power"]) * float(T["damageMult"]) * mt * (0.9 + jitter * 0.2)
	var essence := 0.0
	if landed > 0:
		essence = float(T["essencePerHit"]) * float(landed) + (float(tune()["marrowTap"]["essenceBonus"]) if rune_id == "rune_marrow_tap" else 0.0)
	return {"dmg": dmg, "essence": essence}


# --- Spear / Miasma / Litany / Corpse Explosion --------------------------------------------------------------------

## Marrow Spear: {range, radius, dmg, ring: {radius, dmg, maxCastRange}|null, impaleDmg}. `mult` = 1.5 when Soul Harvest empowers the cast.
static func spear(sp_value: float, rune_id: String, mult: float) -> Dictionary:
	var d := def("marrow_spear")
	var T := tune()
	var dmg: float = sp_value * float(d["power"])
	var out := {"range": float(d["range"]) * mult, "radius": float(d["radius"]) * mult, "dmg": dmg, "ring": null, "impaleDmg": dmg * float(T["impale"]["damageMult"])}
	if rune_id == "rune_ossuary_ring":
		out["ring"] = {"radius": float(T["ring"]["radius"]) * mult, "dmg": dmg * float(T["ring"]["damageMult"]), "maxCastRange": float(T["ring"]["maxCastRange"]) * mult}
	return out


## Miasma Circle: the aim point clamped to its range, radius, dps and duration. mods = discipline.mods.
static func miasma(sp_value: float, mods: Dictionary, rune_id: String, mult: float, caster: Dictionary, aim: Dictionary) -> Dictionary:
	var d := def("miasma")
	var x: float = aim["x"]
	var z: float = aim["z"]
	var dist := DmWeaponLine.hypot2(x - caster["x"], z - caster["z"])
	if dist > float(d["range"]):
		x = caster["x"] + ((x - caster["x"]) / dist) * float(d["range"])
		z = caster["z"] + ((z - caster["z"]) / dist) * float(d["range"])
	var r: float = float(d["radius"]) * float(mods["miasmaRadiusMult"]) * mult * (float(tune()["creepingRot"]["radiusMult"]) if rune_id == "rune_creeping_rot" else 1.0)
	return {"x": x, "z": z, "r": r, "dps": sp_value * float(d["power"]), "durationMs": 6000.0, "witheredCap": DmLegend.effective_withered_cap(mods), "bloom": bool(mods["miasmaBurstsCorpses"])}


## Black Litany: spell-power multiple from what it consumes (host side: WorldSim.applyLitany).
static func litany_mult(corpses: float, resonant: float, thralls: float) -> float:
	return minf(float(C("LITANY_MAX_MULT")),
		float(def("black_litany")["power"]) + float(C("LITANY_PER_CORPSE")) * corpses + float(C("LITANY_PER_RESONANT")) * resonant + float(C("LITANY_PER_THRALL")) * thralls)


static func litany_damage(spell_power: float, corpses: float, resonant: float, thralls: float) -> float:
	return spell_power * litany_mult(corpses, resonant, thralls)


## Spell power the Litany intent carries (Hollow Choir rune: x0.6).
static func litany_spell_power(sp_value: float, rune_id: String) -> float:
	return sp_value * (float(tune()["hollowChoir"]["powerMult"]) if rune_id == "rune_hollow_choir" else 1.0)


## What the caster's client gains from a Litany: {barrier, heal}. mods = discipline.mods; ev = {corpses, resonant, thralls}.
static func litany_gains(max_hp: float, mods: Dictionary, ev: Dictionary) -> Dictionary:
	var consumed: float = float(ev["corpses"]) + float(ev["resonant"]) + float(ev["thralls"])
	var barrier := 0.0
	var heal := 0.0
	if float(mods["litanyBarrier"]) != 0.0:
		barrier = max_hp * float(mods["litanyBarrier"]) * consumed
	if float(mods["corpseHeal"]) != 0.0:
		heal = max_hp * float(mods["corpseHeal"]) * (float(ev["corpses"]) + float(ev["resonant"])) * 0.5
	return {"barrier": barrier, "heal": heal}


## Add a Litany/Mantle barrier to the player state (barrier only ever grows the peak).
static func add_barrier(p: Dictionary, barrier: float) -> void:
	p["barrier"] += barrier
	if barrier > 0.0:
		p["barrierPeak"] = maxf(p["barrierPeak"], p["barrier"])


## Corpse Explosion: the caster's claim, and the host's blast numbers for a corpse ({kind, elite}).
static func detonate_claim(sp_value: float) -> float:
	return sp_value * float(def("corpse_explosion")["power"])


static func detonate_blast(claim: float, corpse: Dictionary) -> Dictionary:
	var D: Dictionary = C("DETONATE")
	var base := minf(float(D["maxDamage"]), maxf(0.0, claim if is_finite(claim) else 0.0))
	return {
		"radius": float(D["radius"]) * (float(D["resonantRadiusMult"]) if corpse.get("kind") == "resonant" else 1.0),
		"dmg": base * (float(D["eliteDamageMult"]) if corpse.get("elite", false) else 1.0),
		# toxic corpses leave a friendly rot pool: radius grows with the body's scale (never below 1x), dps is a share of the unboosted blast
		"rotRadius": float(D["rotRadius"]) * maxf(1.0, float(corpse.get("scale", 1.0))),
		"rotDps": base * float(D["rotDpsShare"]),
	}


## Bone Mantle (onMantle, caster's client): the host consumed `corpses`; the barrier jumps to maxHp x frac (never lowers), held for 6 s.
## Mutates p; returns the mantle's end time (scene ms).
static func mantle_apply(p: Dictionary, corpses: float, now: float) -> float:
	var M: Dictionary = C("BONE_MANTLE")
	var frac := minf(float(M["barrierCap"]), float(M["barrierBase"]) + float(M["barrierPerCorpse"]) * corpses)
	p["barrier"] = maxf(p["barrier"], float(p["stats"]["maxHp"]) * frac)
	p["barrierHoldUntil"] = now + float(M["durationS"]) * 1000.0
	return now + float(M["durationS"]) * 1000.0


static func mantle_shard_damage(sp_value: float) -> float:
	return sp_value * float(def("bone_mantle")["power"])


## Grave Hands (corpses found in the field are capped at GRAVE_HANDS.maxCorpses): {corpses, hands, dmg}.
static func grave_hands(sp_value: float, corpses_found: float) -> Dictionary:
	var G: Dictionary = C("GRAVE_HANDS")
	var corpses := minf(float(G["maxCorpses"]), corpses_found)
	return {
		"corpses": corpses,
		"hands": minf(float(G["maxHands"]), float(G["hands"]) + corpses * float(G["handsPerCorpse"])),
		"dmg": sp_value * float(def("grave_hands")["power"]) * (1.0 + float(G["perCorpse"]) * corpses),
	}


## Bone Storm: lifetime in seconds (corpses under it extend it).
static func bone_storm_life_s(corpses_found: float) -> float:
	var B: Dictionary = C("BONE_STORM")
	return float(B["durationS"]) + minf(float(B["maxExtraS"]), corpses_found * float(B["perCorpseS"]))


## Corpse Vigil heal this frame (Hollow Knight).
static func vigil_heal(max_hp: float, dt_s: float) -> float:
	return max_hp * float(C("CORPSE_VIGIL")["regenFracPerS"]) * dt_s


## Generic rite hit: spell power x def.power (most rites: skull, step, frost, fan, lance, cleave, siphon, storm, ...).
static func rite_damage(sp_value: float, id: String) -> float:
	return sp_value * float(def(id)["power"])


## Wailing Skull: damage on leap `hop` (1-based) from the first-hit `dmg`.
static func skull_leap_damage(dmg: float, hop: int) -> float:
	return dmg * pow(float(C("WAILING_SKULL")["falloff"]), float(hop - 1))


## Requiem 5 nova: damage each wraith / wisp releases.
static func wraith_nova_damage(sp_value: float, k: float) -> float:
	return sp_value * k


## Colossus Mantle: Litany barrier shatter damage / Bone Ward reflect.
static func litany_shatter(barrier_size: float, mods: Dictionary) -> float:
	return DmLegend.shatter_damage(barrier_size, float(mods["litanyShatter"]))


## Wisps: heal per second-tick for `n` wisp-seconds, and how a wisp orbits.
static func wisp_heal(max_hp: float, wisp_seconds: float) -> float:
	return max_hp * float(DmLegend.L()["wispHealFrac"]) * wisp_seconds


## Soul Harvest empowered (Marrow Spear / Miasma / Litany): free and 50% larger.
static func soul_area_mult(was_empowered: bool) -> float:
	return float(C("SOUL_HARVEST")["areaMult"]) if was_empowered else 1.0


# --- onHurt: the ward / guard pipeline (WorldScene.onHurt) ---------------------------------------------------------

## {ward, guard} for one incoming blow. mods = discipline.mods; auto_guard = Easy-auto knight/veil softening; lantern = standing in a Warden ward.
static func incoming_ward(mods: Dictionary, my_thralls: float, lantern: bool, auto_guard: bool, brews: Dictionary, from: String, now: float) -> Dictionary:
	var lantern_ward := 0.2 if lantern else 0.0
	var auto := 0.3 if auto_guard else 0.0
	var flask_ward := DmBrews.brew_ward(brews, from, now)
	var ward: float = float(mods["wardPerThrall"]) * my_thralls + lantern_ward + auto + flask_ward
	var guard: float = float(mods["colossusGuard"]) if DmLegend.colossus_active(mods, my_thralls) else 0.0
	return {"ward": ward, "guard": guard}


# --- Hollow Knight / New Blood rites (NewBloodSystem.cast) ---------------------------------------------------------

## Palm Strike: on the 1200 ms bell beat (phase <= 150 or >= 1050) it hits 1.4x and builds more Resonance. {beat, damage, resonance}
static func palm_strike(p: Dictionary, now: float) -> Dictionary:
	var phase := fposmod(now, 1200.0)
	var beat := phase <= 150.0 or phase >= 1050.0
	return {"beat": beat, "damage": new_blood_power(p, now) * float(def("palm_strike")["power"]) * (1.4 if beat else 1.0), "resonance": 12.0 if beat else 8.0}


## Toll / Last Light / Great Toll: the resource spent and the signature's spell power. Returns {spend, power, duration?}
static func toll_cast(p: Dictionary, id: String, now: float) -> Dictionary:
	var value: float = p["resource"]["value"]
	var spend := 0.0
	if id == "toll" and value >= 25.0:
		spend = 25.0
	elif id == "great_toll":
		spend = value
	return {"spend": spend, "power": new_blood_power(p, now) * (1.0 + spend / 100.0), "duration": 0.6 if (id == "toll" and spend != 0.0) else -1.0}


static func hook_throw(p: Dictionary, now: float) -> Dictionary:
	var pw := new_blood_power(p, now)
	return {"damage": pw * float(def("hook_throw")["power"]), "bleed": pw * 0.14}


## Choir of One beat (every 1200 ms for 6 s, half power) and crow peck (every 500 ms, 35% power).
static func choir_beat_power(p: Dictionary, now: float) -> float:
	return new_blood_power(p, now) * 0.5


static func crow_peck_damage(p: Dictionary, now: float) -> float:
	return new_blood_power(p, now) * 0.35
