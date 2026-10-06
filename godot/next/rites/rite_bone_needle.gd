extends DmRiteModule
## Bone Needle, the Gravecaller primary: targeting enemy, 380 ms, free, +6 essence per hit, range 11, projectile 26 m/s. Numbers: DmAbilities
## (needle_cast / needle_hit / shortfall); visuals: DmRiteFx.needle_cast / needle_hit (shared with the current game).

const SPEED := 26.0        ## sim_caster._fire_needle
const TARGET_Y := 1.0
const PICK_RADIUS := 1.5   ## aim point -> enemy when the client names no target (input tolerance, not a game number)


func _init() -> void:
	id = "bone_needle"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe := _pick_enemy(c, intent["aim"], int(intent["target_id"]))
	if foe == null:
		return "no_target"
	var fp := foe.global_position
	if DmAbilities.shortfall(c.p, id, {"x": fp.x, "z": fp.z}, DmSimConsts.BOSS_RADIUS) > 0.0:
		return "range"
	intent["foe"] = foe
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var foe: Node3D = intent["foe"]
	var m := c.mem(id)
	var rn := DmAbilities.rune(c.p, id)
	if rn == "rune_volley":
		m["casts"] = int(m.get("casts", 0)) + 1
	var nc := DmAbilities.needle_cast(DmAbilities.sp(c.p, c.now_ms), c.p["loadout"], rn, int(m.get("casts", 0)), c.rand())
	var crit_roll := c.rand()
	var from := c.tip()
	var fp := foe.global_position
	var to := Vector3(fp.x, TARGET_Y, fp.z)
	var eid := int(c.world.enemy_id(foe))
	var dmg: float = nc["dmg"]
	var ess: float = nc["essence"]
	c.after(from.distance_to(to) / SPEED * 1000.0, func() -> void: _arrive(c, eid, dmg, ess, crit_roll))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": from, "to": to, "enemy_id": eid, "speed": SPEED, "volley": nc["volley"]})
	return ""


func _arrive(c: DmRiteCaster, eid: int, dmg: float, essence: float, crit_roll: float) -> void:
	var e := c.world.enemy_by_id(eid) as Node3D
	if e == null or not DmRiteCaster.alive_enemy(e):
		return
	var hit := DmAbilities.needle_hit(dmg, crit_roll)
	var amount: float = hit["amount"]
	if not e.take_damage(amount, c.body):
		return
	c.gain_essence(essence)
	var gp := e.global_position
	c.broadcast({"t": "hit", "rite": id, "by": c.peer_id, "enemy_id": eid, "pos": Vector3(gp.x, TARGET_Y, gp.z), "amount": amount, "crit": bool(hit["crit"])})
	c.hit_resolved.emit(id, eid, amount, bool(hit["crit"]), float(e.get("hp")) <= 0.0)
	c.push_state()


## The enemy a needle is aimed at: the named one if it is a live enemy, else the nearest to the aim point within PICK_RADIUS.
func _pick_enemy(c: DmRiteCaster, aim: Vector3, target_id: int) -> Node3D:
	if c.world == null:
		return null
	if target_id >= 0:
		var e := c.world.enemy_by_id(target_id) as Node3D
		if e != null and DmRiteCaster.alive_enemy(e):
			return e
	var best: Node3D = null
	var best_d := INF
	for n in c.world.enemies_in_radius(aim, PICK_RADIUS):
		var e2 := n as Node3D
		if e2 == null or not DmRiteCaster.alive_enemy(e2):
			continue
		var d := Vector2(e2.global_position.x - aim.x, e2.global_position.z - aim.z).length()
		if d < best_d:
			best_d = d
			best = e2
	return best


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	match String(ev["t"]):
		"cast":
			var from: Vector3 = ev["from"]
			var to: Vector3 = ev["to"]
			c.fx.needle_cast([from.x, from.y, from.z], from.x, from.z, bool(ev.get("volley", false)))
			var eid := int(ev["enemy_id"])
			var last := [to]
			var w := c.world   # captured by value: the shot may outlive this node
			var follow := func() -> Variant:
				var e := w.enemy_by_id(eid) as Node3D if w != null else null
				if e != null and is_instance_valid(e):
					last[0] = Vector3(e.global_position.x, TARGET_Y, e.global_position.z)
				return last[0]
			c.fx.shot(from, follow, float(ev["speed"]), 0.0, "needle", DmFxData.spell("needle", "trail"))
		"hit":
			var pos: Vector3 = ev["pos"]
			c.fx.needle_hit([pos.x, pos.y, pos.z], bool(ev["crit"]))
			c.hit_number.emit(pos, float(ev["amount"]), bool(ev["crit"]))
