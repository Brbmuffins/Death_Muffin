extends DmRiteModule
## Grave Frost: a cold bolt (40 m/s) runs the 7 m centre line toward the cursor and the 35 degree half-angle cone resolves when it lands. Every enemy it
## touches takes spell power x 1.4 and is Chilled (3 s: -30% move, -25% attack speed, DmStatusSet `chill`); an enemy that was ALREADY Chilled shatters
## for x1.5. 20 essence, 4.5 s, level 7. Numbers: DmAbilities.rite_damage + DmSimData.GRAVE_FROST. Visuals: DmRiteFx.frost_cast / frost_hits.
## Deviation: a cursor on top of the caster casts along the body's facing (the sim's zero-length direction hits nothing).

const MAX_HITS := 64
const SEEN_MAX := 14   ## the fx draw at most this many


func _init() -> void:
	id = "grave_frost"


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var G: Dictionary = DmSimData.GRAVE_FROST
	var o := c.pos()
	var aim: Vector3 = intent["aim"]
	var d := Vector2(aim.x - o.x, aim.z - o.z)
	if d.length() < 0.01:
		var yaw := float(c.body.get("yaw")) if c.body.get("yaw") != null else 0.0
		d = Vector2(sin(yaw), cos(yaw))
	d = d.normalized()
	DmRiteModule.face(c, o.x + d.x, o.z + d.y)
	var ln := float(DmAbilities.def(id)["range"])
	var dmg := DmAbilities.rite_damage(DmAbilities.sp(c.p, c.now_ms), id)
	var end := Vector3(o.x + d.x * ln, 0.9, o.z + d.y * ln)
	var tip := c.tip()
	var speed := float(G["speed"])
	c.after(tip.distance_to(end) / speed * 1000.0, func() -> void: _arrive(c, o, d.x, d.y, ln, dmg, end))
	c.broadcast({"t": "cast", "rite": id, "by": c.peer_id, "from": tip, "to": end, "speed": speed, "ox": o.x, "oz": o.z, "dx": d.x, "dz": d.y, "ln": ln})
	return ""


## The cone, read when the bolt lands (sim_caster._frost_arrive). Host.
func _arrive(c: DmRiteCaster, o: Vector3, dx: float, dz: float, ln: float, dmg: float, end: Vector3) -> void:
	var G: Dictionary = DmSimData.GRAVE_FROST
	var slope := tan(deg_to_rad(float(G["halfAngleDeg"])))
	var seen: Array = []
	var n := 0
	for ne in c.world.enemies_in_radius(o, ln + 3.0):
		var e := ne as DmEnemy
		if e == null or not DmRiteCaster.alive_enemy(e) or not e.is_hittable():
			continue
		var rad := e.radius
		var rx := e.global_position.x - o.x
		var rz := e.global_position.z - o.z
		var along := rx * dx + rz * dz
		if along < -rad or along > ln + rad or absf(rx * dz - rz * dx) > slope * maxf(0.0, along) + rad:
			continue
		var ss := DmStatusSet.ensure(e)
		var shatter := ss.has(&"chill")
		var amount := dmg * float(G["shatterMult"]) if shatter else dmg
		DmStatusSet.hit(e, amount, c.body)
		var dead := float(e.get("hp")) <= 0.0
		if not dead:
			ss.apply(&"chill", c.body, 1, float(G["chillS"]))
		c.hit_resolved.emit(id, int(c.world.enemy_id(e)), amount, shatter, dead)
		if seen.size() < SEEN_MAX:
			seen.append({"x": e.global_position.x, "z": e.global_position.z, "scale": e.scale.x, "shatter": shatter, "dmg": amount})
		n += 1
		if n >= MAX_HITS:
			break
	c.broadcast({"t": "land", "rite": id, "by": c.peer_id, "ox": o.x, "oz": o.z, "dx": dx, "dz": dz, "ln": ln, "px": end.x, "pz": end.z, "seen": seen, "n": n})


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	var mine := c.is_owner_peer()
	match String(ev["t"]):
		"cast":
			var to: Vector3 = ev["to"]
			var from: Vector3 = ev["from"]
			c.fx.frost_cast([from.x, from.y, from.z], float(ev["ox"]), float(ev["oz"]), float(ev["dx"]), float(ev["dz"]), float(ev["ln"]))
			c.fx.shot(from, to, float(ev["speed"]), 0.0, "orb", DmFxData.spell("frost", "pale"))
		"land":
			c.fx.frost_hits(ev["seen"], float(ev["ox"]), float(ev["oz"]), float(ev["dx"]), float(ev["dz"]), float(ev["ln"]), float(ev["px"]), float(ev["pz"]))
			if mine:
				for s: Dictionary in ev["seen"]:
					c.hit_number.emit(Vector3(s["x"], 1.0, s["z"]), float(s["dmg"]), bool(s["shatter"]))
				c.shake_requested.emit(0.04)
