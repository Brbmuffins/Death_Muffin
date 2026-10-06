extends DmRiteModule
## Grave Offering: burn the corpse nearest the cursor (2.5 m of the aim, 13 m range) into your own reserves. Free, 2 s, unlocks at level 2. The corpse goes
## through the field's atomic consume; an orb flies to you (14 m/s) and on arrival you gain DmSimData.GRAVE_OFFERING essence (+ resonant bonus, x elite)
## and maxHp x (healFrac + the corpseHeal mod). Paid once, on the host. Visuals: DmRiteFx.offering_*.

const SPEED := 14.0   ## sim_caster._offering projectile


func _init() -> void:
	id = "grave_offering"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	if field == null:
		return "no_corpse"
	var d := DmAbilities.def(id)
	var cp: DmSimCorpse = field.pick_corpse(intent["aim"], float(d["radius"]), float(d["range"]), c.pos(), c.area())
	if cp == null:
		return "no_corpse"
	intent["corpse_id"] = cp.id
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	var cp: DmSimCorpse = field.get_corpse(int(intent["corpse_id"]))
	if cp == null:
		return "gone"
	var x := cp.x
	var z := cp.z
	var resonant := cp.kind == "resonant"
	var elite := cp.elite
	if not field.consume(cp.id, c.peer_id, "consumed"):
		return "gone"
	var G: Dictionary = DmSimData.GRAVE_OFFERING
	var essence := (float(G["essence"]) + (float(G["resonantBonus"]) if resonant else 0.0)) * (float(G["eliteMult"]) if elite else 1.0)
	var heal := c.max_hp() * (float(G["healFrac"]) + float(c.mods.get("corpseHeal", 0.0)))
	var flight_ms := Vector2(x - float(c.p["x"]), z - float(c.p["z"])).length() / SPEED * 1000.0
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "x": x, "z": z, "speed": SPEED})
	c.after(flight_ms, func() -> void:
		c.gain_essence(essence)
		c.heal(heal)
		c.broadcast({"t": "land", "rite": id, "by": c.peer_id, "x": float(c.p["x"]), "z": float(c.p["z"]), "essence": essence, "heal": heal})
		c.push_state())
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			var x := float(ev["x"])
			var z := float(ev["z"])
			c.fx.offering_start(x, z)
			var b: Node3D = c.body
			c.fx.offering_orb(x, z, func() -> Variant:
				return Vector3(b.global_position.x, 1.2, b.global_position.z) if is_instance_valid(b) else null, float(ev["speed"]))
		"land":
			c.fx.offering_arrive([float(ev["x"]), 1.2, float(ev["z"])], c.is_owner_peer())
