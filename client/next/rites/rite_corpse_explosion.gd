extends DmRiteModule
## Corpse Explosion, the RMB: burst the corpse nearest the cursor (3.2 m of the aim, 13 m range) in a blast. Numbers: DmAbilities.detonate_claim /
## detonate_blast (radius 3 m, x resonantRadiusMult for resonant; damage = power x spell power, capped, x eliteDamageMult for elite corpses; toxic
## corpses leave a friendly rot pool that is a Miasma cloud by the same rules). 15 essence, 600 ms. The corpse goes only through the field's atomic
## consume ("burst": the body shatters), damage through `c.deal`. Visuals: DmRiteFx.detonated / rot_pool.
## On the combat core (client/code.list "Ported"): the corpse field and the enemies are the core's; the blast reads the enemies' edge distance from the core's radius query.


func _init() -> void:
	id = "corpse_explosion"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	if field == null:
		return "no_corpse"
	var cp: DmCoreCorpse = field.pick_corpse(intent["aim"], float(DmSimData.ABILITIES["exhume"]["radius"]), float(DmAbilities.def(id)["range"]), c.pos(), c.area())
	if cp == null:
		return "no_corpse"
	intent["corpse_id"] = cp.id
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	var cp: DmCoreCorpse = field.get_corpse(int(intent["corpse_id"]))
	if cp == null:
		return "gone"
	var rec := {"kind": cp.kind, "elite": cp.elite, "scale": cp.scale}   # read before consuming
	var x := cp.x
	var z := cp.z
	if not field.consume(cp.id, c.peer_id, "burst"):
		return "gone"
	var blast := DmAbilities.detonate_blast(DmAbilities.detonate_claim(DmAbilities.sp(c.p, c.now_ms)), rec)
	var dmg: float = blast["dmg"]
	var targets := 0
	for e in c.foes_in_radius(Vector3(x, 0.0, z), float(blast["radius"])):
		var r := c.deal(e.id, dmg)
		targets += 1
		c.hit_resolved.emit(id, e.id, dmg, false, bool(r["killed"]))
	var D: Dictionary = DmSimData.DETONATE
	var ev := {"t": "blast", "rite": id, "by": c.peer_id, "x": x, "z": z, "r": float(blast["radius"]), "corpseKind": rec["kind"], "elite": rec["elite"],
		"targets": targets, "dmg": dmg}
	if rec["kind"] == "toxic":
		var secs := float(D["rotDurationMs"]) / 1000.0
		(DmRiteRegistry.module("miasma") as Object).call("add_zone", c, x, z, float(blast["rotRadius"]), float(blast["rotDps"]), float(D["rotDurationMs"]), float(D["rotWitheredCap"]), "rot")
		ev["rot_r"] = float(blast["rotRadius"])
		ev["rot_s"] = secs
	c.broadcast(ev)
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var mine := c.is_owner_peer()
	c.shake_requested.emit(c.fx.detonated(ev, mine))
	if ev.has("rot_r"):
		c.fx.rot_pool(float(ev["x"]), float(ev["z"]), float(ev["rot_r"]), float(ev["rot_s"]))
	if mine and int(ev["targets"]) > 0 and float(ev["dmg"]) > 0.0:
		c.hit_number.emit(Vector3(float(ev["x"]), 0.8, float(ev["z"])), float(ev["dmg"]), bool(ev["elite"]))
