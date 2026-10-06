extends DmRiteModule
## Veil Step: slip toward the cursor, up to 5.5 m, no essence, 7 s, level 4. It stops at the last valid point (the sim's veil_target: 0.25 m steps, never
## through a wall or a sealed door, never out of the hall you stand in) and is a short glide (0.16 s, quadratic ease-out), not a teleport. Host-
## authoritative: `body.dash_point` validates (refused `no_target` when the cursor is closer than 0.3 m or the way is blocked inside the first step),
## `body.dash` glides the body, the position replicates through the session snapshots and clients interpolate it. Visuals: DmRiteFx.veil.


func _init() -> void:
	id = "veil_step"


func validate(c: DmRiteCaster, intent: Dictionary) -> String:
	var from := c.pos()
	var aim: Vector3 = intent["aim"]
	var d := Vector2(aim.x - from.x, aim.z - from.z)
	var l := d.length()
	if l < 0.3:
		return "no_target"
	var reach := minf(float(DmAbilities.def(id)["range"]), l)
	var goal := Vector3(from.x + d.x / l * reach, 0.0, from.z + d.y / l * reach)
	var b: Node3D = c.body
	var to := (b.call("dash_point", goal) as Vector3) if b.has_method("dash_point") else goal
	if Vector2(to.x - from.x, to.z - from.z).length() < float(DmCombatData.const_table("VEIL_STEP")["stepM"]):
		return "no_target"
	intent["to"] = to
	return ""


func resolve(c: DmRiteCaster, intent: Dictionary) -> String:
	var to: Vector3 = intent["to"]
	var from := c.pos()
	var secs := float(DmCombatData.const_table("VEIL_STEP")["durationS"])
	if c.body.has_method("dash"):
		c.body.call("dash", to, secs)
	else:
		c.body.position = Vector3(to.x, c.body.position.y, to.z)
	c.broadcast({"t": "veil", "rite": id, "by": c.peer_id, "fx": from.x, "fz": from.z, "tx": to.x, "tz": to.z})
	return ""


func play(c: DmRiteCaster, ev: Dictionary) -> void:
	c.fx.veil(float(ev["fx"]), float(ev["fz"]), float(ev["tx"]), float(ev["tz"]))
