extends DmRiteModule
## Carrion Seed: plant a seed in the corpse nearest the cursor (2.5 m of the aim, 13 m range). It arms after armS, withers after lifeS (or with its corpse),
## and when a living enemy steps within triggerR it bursts: the corpse goes through the field's atomic consume ("burst"), everything within burstR takes
## the seed's damage (power x spell power at planting) and `withered` stacks (DmStatusSet). One seed per caster: planting another ends the old one.
## 18 essence, 6 s, unlocks at level 8. The seed fields live on the corpse's notes (`c.corpses().notes(id)`: seedOwner, seedDmg, seedCap, seedArmedAt, seedExpires, the
## last two on the caster's clock in ms); the scan runs at 10 Hz only while armed. Visuals: DmRiteFx.seeded / seed_burst. Events: `seeded`, `seedGone`, `seedBurst`
## (all carry corpseId). On the combat core (client/code.list "Ported"): the corpse field, the enemies and the blows are the core's; a seed ends with its corpse.

const SCAN_S := 0.1


func _init() -> void:
	id = "carrion_seed"
	steps = true


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	if field == null:
		return "no_corpse"
	var cp: DmCoreCorpse = field.pick_corpse(intent["aim"], 2.5, float(DmAbilities.def(id)["range"]), c.pos(), c.area())
	if cp == null:
		return "no_corpse"
	intent["corpse_id"] = cp.id
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	var cp: DmCoreCorpse = field.get_corpse(int(intent["corpse_id"]))
	if cp == null:
		return "gone"
	var CS: Dictionary = DmSimData.CARRION_SEED
	var cap := float(CS["witheredCap"])
	if DmCombatData.truthy(c.mods.get("miasmaBurstsCorpses")):
		cap = maxf(cap, DmLegend.effective_withered_cap(c.mods))
	var m := c.mem(id)
	var old := int(m.get("seed", 0))
	if old != 0 and old != cp.id:
		_clear(c, field, old)
	var note := field.notes(cp.id)
	note["seedOwner"] = str(c.peer_id)
	note["seedDmg"] = DmAbilities.sp(c.p, c.now_ms) * float(DmAbilities.def(id)["power"])
	note["seedCap"] = minf(12.0, maxf(1.0, floorf(cap)))
	note["seedArmedAt"] = c.now_ms + float(CS["armS"]) * 1000.0
	note["seedExpires"] = c.now_ms + float(CS["lifeS"]) * 1000.0   # and it ends with its corpse
	m["seed"] = cp.id
	m["scan"] = 0.0
	c.broadcast({"t": "seeded", "rite": id, "by": c.peer_id, "corpseId": cp.id, "x": cp.x, "z": cp.z, "armMs": float(CS["armS"]) * 1000.0})
	return ""


## Host: end a seed (withered, its corpse was used by another rite, or replaced).
func _clear(c: DmRiteCaster, field: DmCoreCorpses, corpse_id: int) -> void:
	if field != null and field.has_notes(corpse_id) and field.get_corpse(corpse_id) != null and str(field.notes(corpse_id).get("seedOwner", "")) == str(c.peer_id):
		field.notes(corpse_id).clear()
	var m := c.mem(id)
	if int(m.get("seed", 0)) == corpse_id:
		m["seed"] = 0
	c.broadcast({"t": "seedGone", "rite": id, "by": c.peer_id, "corpseId": corpse_id})


func step(c: DmRiteCaster, dt: float) -> void:
	var m := c.mem(id)
	var sid := int(m.get("seed", 0))
	if sid == 0:
		return
	var field := c.corpses()
	var cp: DmCoreCorpse = field.get_corpse(sid) if field != null else null
	if cp == null:
		_clear(c, field, sid)   # its corpse is gone (expired / consumed elsewhere)
		return
	var note := field.notes(sid)
	if str(note.get("seedOwner", "")) != str(c.peer_id):
		m["seed"] = 0           # another caster planted over it
		return
	if c.now_ms >= float(note["seedExpires"]):
		_clear(c, field, sid)
		return
	if c.now_ms < float(note["seedArmedAt"]):
		return
	m["scan"] = float(m["scan"]) - dt
	if float(m["scan"]) > 0.0:
		return
	m["scan"] = SCAN_S
	var CS: Dictionary = DmSimData.CARRION_SEED
	var at := Vector3(cp.x, 0.0, cp.z)
	if c.foes_in_radius(at, float(CS["triggerR"])).is_empty():
		return
	var dmg := minf(1e5, float(note["seedDmg"]))
	var cap := float(note["seedCap"])
	if not field.consume(cp.id, c.peer_id, "burst"):
		_clear(c, field, sid)
		return
	m["seed"] = 0
	var targets := 0
	for e in c.foes_in_radius(at, float(CS["burstR"])):
		var r := c.deal(e.id, dmg)
		c.apply_status(e.id, &"withered", int(CS["withered"]), -1.0, {"dps": dmg * float(DmSimData.WITHERED["dpsPerStack"]), "cap": cap})
		c.hit_resolved.emit(id, e.id, dmg, false, bool(r["killed"]))
		targets += 1
	c.broadcast({"t": "seedBurst", "rite": id, "by": c.peer_id, "corpseId": sid, "x": cp.x, "z": cp.z, "r": float(CS["burstR"]), "targets": targets})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var st := c.mem(id)
	var fxs: Dictionary = st.get_or_add("fx", {})
	var cid := int(ev["corpseId"])
	match String(ev["t"]):
		"seeded":
			_end_fx(fxs, cid)
			fxs[cid] = c.fx.seeded(ev)
			c.fx.sfx("carrionSeed", float(ev["x"]), float(ev["z"]), 1.2)
		"seedGone":
			_end_fx(fxs, cid)
		"seedBurst":
			_end_fx(fxs, cid)
			c.shake_requested.emit(c.fx.seed_burst(ev))


static func _end_fx(fxs: Dictionary, cid: int) -> void:
	for h in fxs.get(cid, []):
		DmRiteFx.kill(h)
	fxs.erase(cid)
