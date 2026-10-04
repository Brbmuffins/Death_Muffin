class_name DmSimSnapshot
extends RefCounted
## Port of src/gameplay/sim/snapshot.ts makeSnapshot: the host's wire snapshot (compact enemy/thrall rows) that the realtime relay carries
## (godot/net/dm_realtime_client.gd snapshot_received delivers the same shape). Also `wire_event`: sim events with their Corpse/Zone objects
## flattened to plain dictionaries for the relay.

const E_STATES: Array = ["rising", "move", "windup", "recover", "channel", "dead", "burrow"]
const T_STATES: Array = ["rising", "idle", "move", "attack", "dead"]


static func r2(n: float) -> float:
	return DmMath.js_round_f(n * 100.0) / 100.0


static func affix_code(a: String) -> int:
	if a == "":
		return 0
	return DmSimData.AFFIX_ORDER.find(a) + 1


static func make(sim: DmWorldSim, full: bool) -> Dictionary:
	var enemies: Array = []
	for e: DmSimEnemy in sim.enemies.values():
		var flags := (1 if e.elite else 0) | (2 if e.moving else 0) | (4 if (e.slowT > 0.0 or e.wardSlowT > 0.0) else 0) | (8 if e.chillT > 0.0 else 0) \
			| (4096 if e.bleedT > 0.0 else 0) | (8192 if e.sanctT > 0.0 else 0) | (16384 if e.hexT > 0.0 else 0) | (32768 if e.silenceT > 0.0 else 0) \
			| (65536 if e.incenseT > 0.0 else 0) | (131072 if e.stunT > 0.0 else 0) | (262144 if e.rootT > 0.0 else 0) | (524288 if e.diving else 0)
		enemies.append([e.id, e.def, r2(e.x), r2(e.z), r2(e.facing), DmMath.js_round(e.hp), DmMath.js_round(e.maxHp), E_STATES.find(e.state),
			flags | (int(e.fracture) << 4) | (int(e.withered) << 8), r2(e.stateT), r2(e.speed), r2(e.scale), e.area, affix_code(e.affix), e.level])
	var thralls: Array = []
	for t: DmSimThrall in sim.thralls.values():
		thralls.append([t.id, t.owner, t.kind, r2(t.x), r2(t.z), r2(t.facing), DmMath.js_round(t.hp), DmMath.js_round(t.maxHp),
			T_STATES.find(t.state) | (16 if t.moving else 0), r2(t.stateT),
			(1 if t.empowered else 0) | (2 if t.rallyT > 0.0 else 0) | (4 if t.cursedT > 0.0 else 0) | (8 if t.champion else 0), t.speed, r2(t.damage), r2(t.attackInterval)])
	var zpos: Array = []
	for z: DmSimZone in sim.zones.values():
		if z.creep != 0.0:
			zpos.append([z.id, r2(z.x), r2(z.z)])
	var out := {"t": sim.time, "waveTier": sim.waveTier, "difficulty": sim.difficulty, "ascension": sim.ascension}
	if sim.ascension != 0.0:
		out["vows"] = sim.vows
	out["enemies"] = enemies
	out["thralls"] = thralls
	out["boss"] = sim.boss_state().to_dict()
	out["depleted"] = sim.depleted_nodes()
	if not zpos.is_empty():
		out["zpos"] = zpos
	if full:
		var cs: Array = []
		for c: DmSimCorpse in sim.corpses.values():
			cs.append(c.to_dict())
		var zs: Array = []
		for z: DmSimZone in sim.zones.values():
			zs.append(z.to_dict())
		out["corpses"] = cs
		out["zones"] = zs
	return out


## An event with its Corpse/Zone objects flattened (the form the relay carries and DmSimMirror.apply_events reads).
static func wire_event(ev: Dictionary) -> Dictionary:
	if ev["t"] == "corpse":
		return {"t": "corpse", "corpse": ev["corpse"].to_dict()}
	if ev["t"] == "zone":
		return {"t": "zone", "zone": ev["zone"].to_dict()}
	return ev
