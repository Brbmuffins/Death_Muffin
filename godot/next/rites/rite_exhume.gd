extends DmRiteModule
## Exhume: raise the corpse nearest the cursor (within 3.2 m of the aim and 13 m of you, else the nearest within 7 m) as a thrall. The raising is
## DmThrallHost.raise on the caster's own body (consumes through DmCorpseField's atomic consume, enforces the cap); the intent is the sim's exhume
## intent (sim_caster._exhume): kind / cap from the discipline mods, hp / damage from the stats, runes Mass Grave (count) and Bone Colossus.
## 12 essence, 500 ms; the Sickle refund and the Colossus cooldown come from DmAbilities.apply_cast_cost. Visuals: DmRiteFx.exhume_cast.


func _init() -> void:
	id = "exhume"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	var host := c.thralls()
	if field == null or host == null:
		return "no_corpse"
	var EX: Dictionary = DmSimData.ABILITIES["exhume"]
	var aim: Vector3 = intent["aim"]
	var cp: DmSimCorpse = field.pick_corpse(aim, float(EX["radius"]), float(EX["range"]), c.pos(), c.area())
	if cp == null:
		return "no_corpse"
	var RT: Dictionary = DmSimData.RUNE_TUNING
	var rn := DmAbilities.rune(c.p, id)
	var mass := rn == "rune_mass_grave"
	var at := Vector3(cp.x, 0.0, cp.z)
	var company: Array = []
	if rn == "rune_bone_colossus":
		company = field.corpses_in_radius(at, float(RT["colossus"]["pickRadius"]), Callable(), c.area()).slice(0, int(RT["colossus"]["corpses"]))
	var standing := false
	for t in host.list():
		if t.kind == "colossus" and t.state != DmThrall.S.DEAD:
			standing = true
			break
	var colossus := company.size() >= int(RT["colossus"]["minCorpses"]) and not standing
	var ex := {
		"t": "exhume", "kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"],
		"attackSpeedMult": c.mods["thrallAttackSpeedMult"],
		"r": float(RT["colossus"]["pickRadius"]) if colossus else (float(RT["massGrave"]["pickRadius"]) if mass else 0.8),
	}
	if float(c.p["loadout"]["bellAllyHeal"]) > 0.0:
		ex["allyHeal"] = c.p["loadout"]["bellAllyHeal"]
	var others: Array = []
	if mass:
		ex["count"] = RT["massGrave"]["count"]
		for o: DmSimCorpse in field.corpses_in_radius(at, float(RT["massGrave"]["pickRadius"]), Callable(), c.area()).slice(0, int(RT["massGrave"]["count"])):
			if o.id != cp.id:
				others.append([o.x, o.z])
	var seen: Array = []
	if colossus:
		ex["colossus"] = true
		for o: DmSimCorpse in company:
			seen.append([o.x, o.z])
		intent["colossus_cast"] = true
	intent["ex"] = ex
	intent["at"] = at
	intent["others"] = others
	intent["company"] = seen
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var r: Dictionary = c.thralls().raise(intent["ex"], intent["at"])
	if not bool(r["ok"]):
		return String(r["why"])   # no_corpse / gone (lost the race) / few (a Colossus needs more bodies) / owner_dead
	var at: Vector3 = intent["at"]
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": c.tip(), "x": at.x, "z": at.z, "others": intent["others"], "company": intent["company"],
		"raised": (r["thralls"] as Array).size()})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var tip: Vector3 = ev["from"]
	var shake := c.fx.exhume_cast(tip, float(ev["x"]), float(ev["z"]), ev["others"], ev["company"])
	if shake > 0.0:
		c.shake_requested.emit(shake)
