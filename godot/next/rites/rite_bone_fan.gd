extends DmRiteModule
## Bone Fan, an LMB primary (level 2): three slivers, each homing on a distinct enemy in a 15 degree half-cone around the one clicked (the clicked one
## first, then the nearest to the aim line), 24 m/s, range 8, free, 520 ms, power 0.55. Each landing gives +3 essence, up to 6 a cast. Numbers:
## DmAbilities (def, shortfall, sp) + the BONE_FAN table; visuals: DmRiteFx.fan_cast / fan_hit. The boss does not exist in the rebuild's world yet.

const TARGET_Y := 1.0


func _init() -> void:
	id = "bone_fan"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe := pick_enemy(c, intent["aim"], int(intent["target_id"]))
	if foe == null:
		return "no_target"
	var fp := foe.global_position
	if DmAbilities.shortfall(c.p, id, {"x": fp.x, "z": fp.z}, DmSimConsts.BOSS_RADIUS) > 0.0:
		return "range"
	intent["foe"] = foe
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var BF: Dictionary = DmCombatData.const_table("BONE_FAN")
	var def := DmAbilities.def(id)
	var foe: Node3D = intent["foe"]
	var origin := c.pos()
	var aim_a := atan2(foe.global_position.x - origin.x, foe.global_position.z - origin.z)
	var cone := deg_to_rad(float(BF["coneHalfDeg"]))
	var reach := float(def["range"]) + 0.4
	var others: Array = []
	for n in c.world.enemies_in_radius(origin, reach):
		var e := n as Node3D
		if e == null or e == foe or not DmRiteCaster.alive_enemy(e):
			continue
		var d := Vector2(e.global_position.x - origin.x, e.global_position.z - origin.z).length()
		var off := wrapf(atan2(e.global_position.x - origin.x, e.global_position.z - origin.z) - aim_a, -PI, PI)
		if d <= reach and absf(off) <= cone:
			others.append({"e": e, "off": absf(off), "d": d})
	others.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["d"] < b["d"] if a["off"] == b["off"] else a["off"] < b["off"])
	var picks: Array = [foe]
	for i in mini(others.size(), int(BF["slivers"]) - 1):
		picks.append(others[i]["e"])
	var tip := c.tip()
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var spread := deg_to_rad(float(BF["spreadDeg"]))
	var angles := [0.0, -spread, spread]
	var speed := float(BF["speed"])
	var refund := {"n": 0.0}
	var slivers: Array = []
	for k in int(BF["slivers"]):
		if k >= picks.size():   # no enemy for this sliver: it flies out along its spread angle and dies
			var a: float = aim_a + angles[k % angles.size()]
			slivers.append({"to": Vector3(origin.x + sin(a) * float(def["range"]), TARGET_Y, origin.z + cos(a) * float(def["range"])), "eid": -1})
			continue
		var e: Node3D = picks[k]
		var eid := int(c.world.enemy_id(e))
		var to := Vector3(e.global_position.x, TARGET_Y, e.global_position.z)
		slivers.append({"to": to, "eid": eid})
		c.after(tip.distance_to(to) / speed * 1000.0, func() -> void: _arrive(c, eid, dmg, refund))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": tip, "speed": speed, "slivers": slivers})
	return ""


func _arrive(c: DmRiteCaster, eid: int, dmg: float, refund: Dictionary) -> void:
	var e := c.world.enemy_by_id(eid) as Node3D
	if e == null or not DmRiteCaster.alive_enemy(e) or not DmStatusSet.hit(e, dmg, c.body):
		return
	var BF: Dictionary = DmCombatData.const_table("BONE_FAN")
	if float(refund["n"]) < float(BF["essenceCap"]):
		var add := minf(float(BF["essencePerHit"]), float(BF["essenceCap"]) - float(refund["n"]))
		refund["n"] = float(refund["n"]) + add
		c.gain_essence(add)
	var gp := e.global_position
	c.broadcast({"t": "hit", "rite": id, "by": c.peer_id, "enemy_id": eid, "pos": Vector3(gp.x, TARGET_Y, gp.z), "amount": dmg})
	c.hit_resolved.emit(id, eid, dmg, false, float(e.get("hp")) <= 0.0)
	c.push_state()


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			var from: Vector3 = ev["from"]
			c.fx.fan_cast(from, from.x, from.z)
			var color := DmFxData.spell("needle", "trail")
			for s: Dictionary in ev["slivers"]:
				var to: Vector3 = s["to"]
				var eid := int(s["eid"])
				c.fx.shot(from, follow_enemy(c, eid, to, TARGET_Y) if eid >= 0 else to, float(ev["speed"]), 0.0, "needle", color)
		"hit":
			var pos: Vector3 = ev["pos"]
			c.fx.fan_hit(pos)
			c.hit_number.emit(pos, float(ev["amount"]), false)
