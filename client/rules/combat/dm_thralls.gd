class_name DmThralls
extends RefCounted
## The pure numbers of the legion (WorldSim.raiseFrom / raiseColossus / makeRoom / applyRefreshThralls / thrall blows / deathBurst / plagueBurst).
## Thrall = {kind, hp, maxHp, damage, attackInterval, range, speed, bornAt, owner, state, rallyT?, cursedT?}.
## Placement, AI, targeting and movement are the world sim's.

const KINDS: Array[String] = ["warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage", "plaguebearer", "colossus"]


static func base_of(kind: String) -> Dictionary:
	if kind == "colossus":
		var c: Dictionary = DmRunes.T()["colossus"]
		return {"range": c["range"], "interval": c["interval"], "speed": c["speed"]}
	match kind:
		"warrior": return {"range": 1.3, "interval": 1.0, "speed": 5.6}
		"shieldbearer": return {"range": 1.3, "interval": 1.25, "speed": 5.2}
		"hound": return {"range": 1.2, "interval": 0.7, "speed": 7.2}
		"wraith": return {"range": 5.5, "interval": 1.1, "speed": 5.8}
		"archer": return {"range": 7.5, "interval": 1.3, "speed": 5.4}
		"bonemage": return {"range": 6.5, "interval": 1.8, "speed": 5.2}
		"plaguebearer": return {"range": 1.3, "interval": 1.2, "speed": 4.8}
	return {}


static func is_known_kind(kind: Variant) -> bool:
	return kind is String and KINDS.has(kind)


## How far a thrall of this kind strikes from (default 1.3).
static func reach(kind: String) -> float:
	var b := base_of(kind)
	return float(b["range"]) if not b.is_empty() else 1.3


## Legion places a thrall fills against the cap (the Bone Colossus takes more than one).
static func weight(kind: String) -> float:
	return float(DmRunes.T()["colossus"]["slots"]) if kind == "colossus" else 1.0


## Relative hp / hit of each kind against the caster's base thrall stats.
static func scale_of(kind: String) -> Dictionary:
	match kind:
		"hound": return {"hp": 0.75, "dmg": 1.0}
		"archer": return {"hp": 0.7, "dmg": 0.85}
		"bonemage": return {"hp": 0.7, "dmg": 0.7}
		"plaguebearer": return {"hp": 1.1, "dmg": 0.8}
	return {"hp": 1.0, "dmg": 1.0}


## Which specialist a corpse ({kind, enemy}) rises as (the discipline's own kind otherwise).
static func thrall_from_corpse(c: Dictionary, discipline_kind: String) -> String:
	if discipline_kind == "wraith":
		return "wraith"
	if c.get("kind") == "swift":
		return "hound"
	match c.get("enemy"):
		"penitent": return "archer"
		"deacon": return "bonemage"
		"sac": return "plaguebearer"
	return discipline_kind


## Corpses an exhume intent {x, z, r, count?} picks: nearest first, at most `count` (Mass Grave), within r (widened for count > 1).
## `hall` = the caster's area or "" . Returns {picks, statMult}.
static func exhume_picks(intent: Dictionary, corpses: Array, hall: String = "") -> Dictionary:
	var M: Dictionary = DmRunes.T()["massGrave"]
	var cnt_raw: Variant = intent.get("count")
	var cnt_f := float(cnt_raw) if (cnt_raw is float or cnt_raw is int) else 1.0
	var count := int(maxf(1.0, minf(float(M["count"]), floorf(cnt_f if is_finite(cnt_f) else 1.0))))
	var r: float = maxf(float(intent["r"]), float(M["pickRadius"])) if count > 1 else float(intent["r"])
	var cand: Array = []
	var i := 0
	for c: Dictionary in corpses:
		i += 1
		if DmCombatData.truthy(c.get("echoOwner")):
			continue
		if hall != "" and c.get("area") != hall:
			continue
		var d := DmWeaponLine.hypot2(c["x"] - intent["x"], c["z"] - intent["z"])
		if d <= r:
			cand.append({"c": c, "d": d, "i": i})
	cand.sort_custom(func(a, b): return a["d"] < b["d"] if a["d"] != b["d"] else a["i"] < b["i"])
	var picks: Array = []
	for o in cand.slice(0, count):
		picks.append(o["c"])
	return {"picks": picks, "statMult": float(M["statMult"]) if picks.size() > 1 else 1.0}


## One ordinary exhume raising `corpse` ({kind, elite, enemy}) for intent {hp, damage, attackSpeedMult, kind, allyHeal?}.
## `raised_n` = this owner's raise count INCLUDING this one; `champion_every` from the owner's legend mods.
## Returns the thrall stats {kind, hp, maxHp, damage, attackInterval, range, speed, empowered, champion, allyHeal}.
static func raise_stats(intent: Dictionary, corpse: Dictionary, stat_mult: float, raised_n: int, champion_every: float) -> Dictionary:
	var kind_in: String = intent["kind"] if is_known_kind(intent.get("kind")) else "warrior"
	var kind := thrall_from_corpse(corpse, kind_in)
	var sc := scale_of(kind)
	var empowered: bool = corpse.get("kind") == "resonant" or DmCombatData.truthy(corpse.get("elite"))
	var base := base_of(kind)
	var champion := champion_every > 0.0 and fmod(float(raised_n), champion_every) == 0.0
	var L: Dictionary = DmLegend.L()
	var hp: float = float(intent["hp"]) * (1.5 if empowered else 1.0) * float(sc["hp"]) * stat_mult * (float(L["championHp"]) if champion else 1.0)
	var out := {
		"kind": kind,
		"hp": hp, "maxHp": hp,
		"damage": float(intent["damage"]) * (1.5 if empowered else 1.0) * float(sc["dmg"]) * stat_mult * (float(L["championDamage"]) if champion else 1.0),
		"attackInterval": float(base["interval"]) / float(intent["attackSpeedMult"]),
		"range": base["range"], "speed": base["speed"],
		"empowered": empowered, "champion": champion, "allyHeal": 0.0,
	}
	var ah: Variant = intent.get("allyHeal")
	if kind == "wraith" and ah != null and float(ah) > 0.0:
		out["allyHeal"] = minf(float(DmCombatData.load_json("necro_weapons")["tuning"]["mourning_bell"]["allyHealFrac"]) * 1.5, float(ah))
	return out


## Bone Colossus: n corpses (3..5) spent; returns {hp, damage, attackInterval, range, speed, empowered}.
static func colossus_stats(intent: Dictionary, corpses: Array) -> Dictionary:
	var C: Dictionary = DmRunes.T()["colossus"]
	var n := float(corpses.size())
	var empowered := false
	for c: Dictionary in corpses:
		if c.get("kind") == "resonant" or DmCombatData.truthy(c.get("elite")):
			empowered = true
	var hp: float = float(intent["hp"]) * float(C["hpPerCorpse"]) * n
	return {
		"hp": hp, "maxHp": hp, "damage": float(intent["damage"]) * float(C["damagePerCorpse"]) * n,
		"attackInterval": float(C["interval"]) / float(intent["attackSpeedMult"]), "range": C["range"], "speed": C["speed"], "empowered": empowered,
	}


## The corpses a Colossus draws in: nearest `corpses` (<=5) within min(pickRadius, max(0.2, r)) of the point, or [] when fewer than minCorpses.
static func colossus_picks(intent: Dictionary, corpses: Array) -> Array:
	var C: Dictionary = DmRunes.T()["colossus"]
	var r := minf(float(C["pickRadius"]), maxf(0.2, float(intent["r"])))
	var near := DmRunes.corpses_within({"x": intent["x"], "z": intent["z"]}, r, corpses).slice(0, int(C["corpses"]))
	return near if near.size() >= int(C["minCorpses"]) else []


## makeRoom: ids of the thralls that crumble to fit `weight` more places under `cap`. owned = [{id, kind, bornAt}].
## Oldest ordinary thrall first, a Colossus last.
static func make_room(owned_in: Array, cap: float, w: float) -> Array:
	var owned: Array = []
	var i := 0
	for t: Dictionary in owned_in:
		owned.append({"t": t, "i": i})
		i += 1
	owned.sort_custom(func(a, b):
		var ka := 1 if a["t"]["kind"] == "colossus" else 0
		var kb := 1 if b["t"]["kind"] == "colossus" else 0
		if ka != kb:
			return ka < kb
		if a["t"]["bornAt"] != b["t"]["bornAt"]:
			return a["t"]["bornAt"] < b["t"]["bornAt"]
		return a["i"] < b["i"])
	var used := 0.0
	for o in owned:
		used += weight(o["t"]["kind"])
	var crumbled: Array = []
	var idx := 0
	while idx < owned.size() and used + w > cap:
		var o: Dictionary = owned[idx]["t"]
		idx += 1
		used -= weight(o["kind"])
		crumbled.append(o["id"])
	return crumbled


## A purchase refreshes standing thralls: hp/maxHp x hp, damage x dmg, attackInterval / speed (each clamped to [1, THRALL_REFRESH_MAX]).
static func apply_refresh(t: Dictionary, hp_mult: float, damage_mult: float, speed_mult: float) -> Dictionary:
	var mx: float = DmCombatData.progression()["thrall_refresh_max"]
	var clamp := func(v: float) -> float: return minf(mx, maxf(1.0, v)) if is_finite(v) else 1.0
	var hp: float = clamp.call(hp_mult)
	var dmg: float = clamp.call(damage_mult)
	var sp: float = clamp.call(speed_mult)
	var out := t.duplicate()
	if hp == 1.0 and dmg == 1.0 and sp == 1.0:
		return out
	out["hp"] = float(t["hp"]) * hp
	out["maxHp"] = float(t["maxHp"]) * hp
	out["damage"] = float(t["damage"]) * dmg
	out["attackInterval"] = float(t["attackInterval"]) / sp
	return out


## Damage multiplier on a thrall's blow: Rally the Dead (+40%), Bog Hag's hex (x0.7).
static func blow_mult(t: Dictionary) -> float:
	var r: float = float(DmCombatData.const_table("RALLY")["damageMult"]) if float(DmCombatData.nn(t.get("rallyT"), 0)) > 0.0 else 1.0
	var h: float = float(DmCombatData.statuses()["HAG_HEX"]["thrallDamageMult"]) if float(DmCombatData.nn(t.get("cursedT"), 0)) > 0.0 else 1.0
	return r * h


## Spear-rally mark: the legion's extra damage on a marked target (1 when none). mark = {bonus} or null.
static func rally_mark_mult(t: Dictionary, mark_active: bool, mark_by: String, mark_bonus: float) -> float:
	return 1.0 + mark_bonus if (mark_active and mark_by == t.get("owner")) else 1.0


## The raw damage of one thrall blow on an enemy before the enemy's own scaling (damageEnemy applies Fracture etc.).
static func blow_damage(t: Dictionary, mark_mult: float = 1.0) -> float:
	return float(t["damage"]) * blow_mult(t) * mark_mult


## Bone Colossus cleave: damage dealt to each other enemy near its target.
static func colossus_cleave_damage(t: Dictionary) -> float:
	var r: float = float(DmCombatData.const_table("RALLY")["damageMult"]) if float(DmCombatData.nn(t.get("rallyT"), 0)) > 0.0 else 1.0
	var h: float = float(DmCombatData.statuses()["HAG_HEX"]["thrallDamageMult"]) if float(DmCombatData.nn(t.get("cursedT"), 0)) > 0.0 else 1.0
	return float(t["damage"]) * r * h * float(DmRunes.T()["colossus"]["cleaveFrac"])


## Legion of the Unburied: a KILLED thrall bursts for frac x its max HP within deathBurstR.
static func death_burst_damage(frac: float, max_hp: float) -> float:
	return frac * max_hp if frac > 0.0 else 0.0


## A fallen plague bearer ruptures: {dmg, poolDps}.
static func plague_burst(t_damage: float) -> Dictionary:
	var P: Dictionary = DmCombatData.statuses()["PLAGUE_BURST"]
	return {"dmg": t_damage * float(P["damageMult"]), "poolDps": t_damage * float(P["poolDpsShare"])}


## Boss/enemy "worth" of a thrall blow against a Fractured boss.
static func worth_vs_fracture(raw: float, fracture: float) -> float:
	return raw * (1.0 + float(DmCombatData.const_table("FRACTURE")["perStack"]) * fracture)
