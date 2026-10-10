extends DmRiteModule
## Grave Step: blood-mist blink onto the corpse nearest the cursor (3.2 m of the aim, 12 m of you, in your own area); the corpse stays for your next
## rite. Enemies within 2.6 m of where you re-form take spell power x 1.3 and bleed (HEMORRHAGE dpsFrac, strongest wins). 10 essence, 5 s, level 5.
## Numbers: DmAbilities.rite_damage + DmSimData.GRAVE_STEP / HEMORRHAGE. The move is host-authoritative: the body teleports (`body.teleport`, the point
## resolved onto the navmesh by `body.resolve_point`) and the position replicates through the session snapshots; clients snap (DmSessionBody.SNAP_JUMP)
## instead of gliding. Visuals: DmRiteFx.step_depart / step_arrive, both from the one event.

const MAX_HITS := 64
const MAX_POPUPS := 12


func _init() -> void:
	id = "grave_step"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var field := c.corpses()
	if field == null:
		return "no_corpse"
	var def := DmAbilities.def(id)
	var cp: DmSimCorpse = field.pick_corpse(intent["aim"], float(DmSimData.ABILITIES["exhume"]["radius"]), float(def["range"]), c.pos(), c.area())
	if cp == null or Vector2(cp.x - c.pos().x, cp.z - c.pos().z).length() > float(def["range"]):
		return "no_corpse"
	intent["corpse_at"] = Vector3(cp.x, 0.0, cp.z)
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var b: Node3D = c.body
	var from := c.pos()
	var want: Vector3 = intent["corpse_at"]
	var to := (b.call("resolve_point", want) as Vector3) if b.has_method("resolve_point") else want
	if b.has_method("teleport"):
		b.call("teleport", to)
	else:
		b.position = Vector3(to.x, b.position.y, to.z)
		b.reset_physics_interpolation()
	if from.distance_squared_to(to) > 0.0001 and b.get("yaw") != null:
		b.set("yaw", atan2(to.x - from.x, to.z - from.z))
		b.rotation.y = float(b.get("yaw"))
	c.p["x"] = to.x
	c.p["z"] = to.z
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var bleed := minf(dmg * float(DmSimData.HEMORRHAGE["dpsFrac"]), dmg * float(DmSimData.HEMORRHAGE["maxFrac"]))
	var hits: Array = []
	var n := 0
	for e: DmEnemy in DmRiteModule.enemies_in_circle(c, to.x, to.z, float(DmCombatData.const_table("GRAVE_STEP")["burstRadius"]), MAX_HITS):
		DmStatusSet.hit(e, dmg, c.body)
		var dead := float(e.get("hp")) <= 0.0
		if not dead:
			DmStatusSet.ensure(e).apply(&"bleed", c.body, 1, -1.0, {"dps": bleed})
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), dmg, false, dead)
		if hits.size() < MAX_POPUPS:
			hits.append([e.global_position.x, e.global_position.z])
		n += 1
	c.broadcast({"t": "step", "rite": id, "by": c.peer_id, "ox": from.x, "oz": from.z, "x": to.x, "z": to.z, "hits": hits, "n": n, "dmg": dmg})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var mine := c.is_owner_peer()
	var b: Node3D = c.body
	var follow := func() -> Variant:
		return Vector3(b.global_position.x, 1.0, b.global_position.z) if is_instance_valid(b) else null
	c.fx.step_depart(float(ev["ox"]), float(ev["oz"]))
	c.fx.step_arrive(float(ev["ox"]), float(ev["oz"]), float(ev["x"]), float(ev["z"]), follow, ev["hits"])
	if mine:
		for h: Array in ev["hits"]:
			c.hit_number.emit(Vector3(h[0], 0.9, h[1]), float(ev["dmg"]), false)
		c.shake_requested.emit(0.05)
