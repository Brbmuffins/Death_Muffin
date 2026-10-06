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
	var dmg: float = nc["dmg"]
	var ess: float = nc["essence"]
	var splinters := rn == "rune_splinter"
	var from := c.tip()
	if not nc["volley"]:
		_launch(c, foe, from, dmg, ess, splinters, c.rand(), true, false)
		return ""
	# Volley rune: every 4th needle is 3, at the target and the enemies nearest it within reach of the caster (all at one target when it stands alone),
	# each for the volley fraction, the essence of one needle between them, 50 ms apart.
	var V: Dictionary = DmSimData.RUNE_TUNING["volley"]
	var foes: Array = []
	var first := {"id": int(c.world.enemy_id(foe)), "x": foe.global_position.x, "z": foe.global_position.z, "e": foe}
	for n in c.world.enemies_in_radius(Vector3(float(c.p["x"]), 0.0, float(c.p["z"])), float(V["reach"]) + 3.0):
		if DmRiteCaster.alive_enemy(n):
			foes.append({"id": int(c.world.enemy_id(n)), "x": n.global_position.x, "z": n.global_position.z, "e": n})
	var aims: Array = DmRunes.volley_targets({"x": float(c.p["x"]), "z": float(c.p["z"])}, first, foes)
	while aims.size() < int(V["needles"]):
		aims.append(first)
	var each := DmAbilities.volley_essence_each(ess)
	for i in aims.size():
		var tgt: Node3D = aims[i]["e"]
		var f := Vector3(from.x + (i - 1) * 0.12, from.y, from.z)
		var crit := c.rand()
		if i == 0:
			_launch(c, tgt, f, dmg, each, false, crit, true, true)
		else:
			c.after(i * 50.0, func() -> void: _launch(c, tgt, f, dmg, each, false, crit, false, true))
	return ""


## One needle in flight: damage and essence on arrival, and (Splinters) a shard to the nearest other enemy. `lead` = it carries the cast's muzzle fx.
func _launch(c: DmRiteCaster, foe: Node3D, from: Vector3, dmg: float, ess: float, splinters: bool, crit_roll: float, lead: bool, volley: bool) -> void:
	if not DmRiteCaster.alive_enemy(foe):
		return
	var fp := foe.global_position
	var to := Vector3(fp.x, TARGET_Y, fp.z)
	var eid := int(c.world.enemy_id(foe))
	c.after(from.distance_to(to) / SPEED * 1000.0, func() -> void: _arrive(c, eid, dmg, ess, crit_roll, splinters))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": from, "to": to, "enemy_id": eid, "speed": SPEED, "volley": volley and lead, "lead": lead})


func _arrive(c: DmRiteCaster, eid: int, dmg: float, essence: float, crit_roll: float, splinters: bool = false) -> void:
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
	if splinters:
		_splinter(c, e, dmg)
	c.push_state()


## Splinters rune: a shard flies to the nearest OTHER enemy within reach for 30 % of the needle's (uncritted) damage.
func _splinter(c: DmRiteCaster, first: Node3D, dmg: float) -> void:
	var fp := first.global_position
	var fd := {"id": int(c.world.enemy_id(first)), "x": fp.x, "z": fp.z}
	var pool: Array = []
	for n in c.world.enemies_in_radius(fp, float(DmSimData.RUNE_TUNING["splinter"]["reach"]) + 3.0):
		if n != first and DmRiteCaster.alive_enemy(n):
			pool.append({"id": int(c.world.enemy_id(n)), "x": n.global_position.x, "z": n.global_position.z, "e": n})
	var tg: Variant = DmRunes.splinter_target(fd, pool)
	if tg == null:
		return
	var o: Node3D = tg["e"]
	var amount := DmAbilities.splinter_damage(dmg)
	if not DmStatusSet.hit(o, amount, c.body):
		return
	c.hit_resolved.emit(id, int(tg["id"]), amount, false, float(o.get("hp")) <= 0.0)
	c.broadcast({"t": "splinter", "rite": id, "by": c.peer_id, "from": Vector3(fp.x, 1.0, fp.z), "pos": Vector3(o.global_position.x, 1.0, o.global_position.z), "amount": amount})


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
			if bool(ev.get("lead", true)):   # a volley's other needles are shots only
				c.fx.needle_cast([from.x, from.y, from.z], from.x, from.z, bool(ev.get("volley", false)))
			var eid := int(ev["enemy_id"])
			var last := [to]
			# The shot may outlive the world (teardown, area change). A lambda that captures a freed Object logs "Lambda capture at index 0 was
			# freed" on every call, even when its body guards with is_instance_valid, so it captures a WeakRef instead.
			var w: WeakRef = weakref(c.world) if c.world is Object else null
			var follow := func() -> Variant:
				var wo: Object = w.get_ref() if w != null else null
				var e: Node3D = wo.enemy_by_id(eid) as Node3D if wo != null else null
				if e != null and is_instance_valid(e):
					last[0] = Vector3(e.global_position.x, TARGET_Y, e.global_position.z)
				return last[0]
			c.fx.shot(from, follow, float(ev["speed"]), 0.0, "needle", DmFxData.spell("needle", "trail"))
		"hit":
			var pos: Vector3 = ev["pos"]
			c.fx.needle_hit([pos.x, pos.y, pos.z], bool(ev["crit"]))
			c.hit_number.emit(pos, float(ev["amount"]), bool(ev["crit"]))
		"splinter":
			var to: Vector3 = ev["pos"]
			c.fx.splinter_shard(ev["from"], to)
			c.hit_number.emit(to, float(ev["amount"]), false)
